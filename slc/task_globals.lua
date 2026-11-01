-- Compiler-visible global-address effects, shared by every residual backend.
-- Two contexts keep calls made by tasks separate from ordinary callers. Pointer
-- origins and memory contents grow monotonically; recursion and blocking bodies
-- participate in the same fixed point. Aggregate/array cells are conservative:
-- fields may alias, but storing an address is not itself a write to its pointee.
local M = {}

function M.check(fns, walk_block)
    local has_task = false
    for _, fn in ipairs(fns) do if fn.task then has_task = true; break end end
    if not has_task then return end
    local changed = false
    local unknown = { values = {} } -- opaque memory/function target; may alias other opaque memory
    local function merge(dst, src, growing)
        for x in pairs(src or {}) do
            if not dst[x] then dst[x] = true; if growing then changed = true end end
        end
        return dst
    end
    local pointer_cache = {}
    local function pointers(t)
        if not t then return false end
        if pointer_cache[t] ~= nil then return pointer_cache[t] end
        local k = t.kind
        if k == 'ptr' or k == 'ref' or k == 'fn' or k == 'cstr' then return true end
        pointer_cache[t] = false
        if k == 'struct' then
            for _, f in ipairs(t.fields) do if pointers(f.type) then pointer_cache[t] = true end end
        elseif k == 'sum' then
            for _, a in ipairs(t.alts) do if pointers(a.type) then pointer_cache[t] = true end end
        elseif k == 'array' then pointer_cache[t] = pointers(t.elem) end
        return pointer_cache[t]
    end
    local globals, external, functions, contexts, instances = {}, {}, {}, {}, {}
    local function global(g)
        local cell = globals[g]
        if not cell then
            local key = (g.exported or g.imported) and g.name
            cell = key and external[key]
            if cell then
                local old = cell.global
                if old.shared ~= g.shared or old.tls ~= g.tls then
                    error("global '" .. g.name .. "' has inconsistent shared/thread_local declarations", 0)
                end
            else cell = { global = g, T = g.T, values = {} } end
            if g.imported and pointers(g.T) then cell.values[unknown] = true end
            globals[g] = cell
            if key then external[key] = cell end
        end
        return cell
    end
    local function function_address(fn)
        functions[fn] = functions[fn] or { fn = fn }
        return functions[fn]
    end
    local function context(fn, task)
        local pair = contexts[fn]
        if not pair then pair = {}; contexts[fn] = pair end
        local key = task and 'task' or 'plain'
        if not pair[key] then
            pair[key] = { fn = fn, task = task, params = {}, locals = {}, returns = {} }
            instances[#instances + 1] = pair[key]
            changed = true
        end
        return pair[key]
    end
    -- Include ordinary code to discover addresses stored before tasks start.
    -- Its parameter/local cells never contaminate task-call instances.
    for _, fn in ipairs(fns) do
        local inst = context(fn, false)
        if fn.exported then
            for _, p in ipairs(fn.params) do
                if pointers(p.T) then inst.params[p.name] = { [unknown] = true } end
            end
        end
        if fn.task then context(fn, true) end
    end
    local function closure(origins)
        local out = {}
        local function visit(x)
            if out[x] then return end
            out[x] = true
            for y in pairs(x.values or {}) do visit(y) end
        end
        for x in pairs(origins) do visit(x) end
        return out
    end
    local violations = {}
    local function write_origins(inst, origins, opaque)
        if not inst.task then return end
        for cell in pairs(origins) do
            local g = cell.global
            if g and not g.tls and not g.shared then
                -- Passing an Atomic address to opaque code does not prove that
                -- code uses atomic operations. Actual atomic IR is handled below.
                violations[g] = violations[g] or { fn = inst.fn, opaque = opaque }
            end
        end
    end
    local function analyze(inst)
        local points, address, call
        function address(p)
            local parent = rawget(p, 'parent')
            if parent then return address(parent) end
            local ptr = rawget(p, 'ptr') or rawget(p, 'base')
            if ptr then return points(ptr) end
            local cell = inst.locals[p]
            if not cell then cell = { T = p.T, values = {} }; inst.locals[p] = cell end
            return { [cell] = true }
        end
        local function bind(target, args)
            for i, p in ipairs(target.fn.params) do
                if pointers(p.T) then
                    target.params[p.name] = target.params[p.name] or {}
                    merge(target.params[p.name], points(args[i]), true)
                end
            end
            return target.returns
        end
        local function opaque(e)
            local exposed = {}
            for _, a in ipairs(e.args or {}) do merge(exposed, points(a)) end
            exposed = closure(exposed)
            write_origins(inst, exposed, true)
            -- An opaque function may invoke a supplied native callback. Its
            -- compiler-visible global effects remain subject to the task rule.
            for cell in pairs(exposed) do
                if cell.fn then
                    local target = context(cell.fn, inst.task)
                    for _, p in ipairs(cell.fn.params) do
                        if pointers(p.T) then
                            target.params[p.name] = target.params[p.name] or {}
                            merge(target.params[p.name], { [unknown] = true }, true)
                        end
                    end
                elseif cell.values and pointers(cell.T) then
                    merge(cell.values, { [unknown] = true }, true)
                end
            end
            if pointers(e.T) then exposed[unknown] = true end
            return exposed -- opaque code can return one of the supplied addresses
        end
        function call(e)
            if e.op == 'call' and e.fn then return bind(context(e.fn, inst.task), e.args or {}) end
            if e.op == 'calli' then
                local out, uncertain = {}, false
                for cell in pairs(points(e.a)) do
                    if cell.fn then
                        merge(out, bind(context(cell.fn, inst.task), e.args or {}))
                    else uncertain = true end
                end
                if uncertain then merge(out, opaque(e)) end
                return out
            end
            return opaque(e)
        end
        function points(e)
            if not e or (e.T and not pointers(e.T)) then return {} end
            -- The intermediate `.as` union projection of a sum has no T;
            -- traverse it rather than dropping the payload's pointer origins.
            local op = e.op
            if op == 'gaddr' then return { [global(e.global)] = true } end
            if op == 'fnaddr' then return { [function_address(e.fn)] = true } end
            if op == 'param' then return inst.params[e.name] or {} end
            if op == 'addr' then return address(e.place) end
            if op == 'read' then
                local out = {}
                for cell in pairs(address(e.place)) do
                    merge(out, cell.values)
                    if cell == unknown then out[unknown] = true end
                end
                return out
            end
            if op == 'call' or op == 'calli' or op == 'rtcall' then return call(e) end
            local out = {}
            -- Conversions, projections, aggregates, and pointer views preserve
            -- their compiler-visible origins. Scalars cannot manufacture Ptr.
            for _, k in ipairs { 'a', 'b', 'e', 'ptr', 'i', 'n', 'idx', 'slot' } do
                local child = e[k]
                if type(child) == 'table' and child.op then merge(out, points(child)) end
            end
            for _, child in pairs(e.fields or {}) do merge(out, points(child)) end
            return out
        end
        walk_block(inst.fn.body, function(s)
            if (s.op == 'store' or s.op == 'let') and s.place then
                local targets = address(s.place)
                if s.op == 'store' then write_origins(inst, targets) end
                if pointers(s.place.T) then
                    local value = points(s.e)
                    for cell in pairs(targets) do
                        if cell.values then merge(cell.values, value, true) end
                    end
                end
            elseif s.op == 'setparam' then
                -- Root tail calls are parallel parameter assignments, not call
                -- nodes; their pointer origins still reach subsequent rounds.
                inst.params[s.name] = inst.params[s.name] or {}
                merge(inst.params[s.name], points(s.e), true)
            elseif s.op == 'ret' then merge(inst.returns, points(s.e), true) end
        end, function(e)
            if e.op == 'call' or e.op == 'calli' or e.op == 'rtcall' then call(e) end
            if e.op == 'atomic' and e.expected_place then
                -- Compare-exchange may also write its non-atomic expected slot.
                write_origins(inst, address(e.expected_place))
            end
            if e.op == 'gaddr' then global(e.global) end
        end)
    end
    repeat
        changed = false
        for _, inst in ipairs(instances) do analyze(inst) end
    until not changed
    local bad = {}
    for g in pairs(violations) do bad[#bad + 1] = g end
    table.sort(bad, function(a, b) return a.name < b.name end)
    if bad[1] then
        local g, v = bad[1], violations[bad[1]]
        local name = not v.fn.task and (v.fn.word and v.fn.word.name or v.fn.cname)
        error(("a task shares no memory: %s global '%s'%s; use atomic operations, thread_local storage, "
            .. "or shared = true under the program's own synchronization"):format(
            v.opaque and 'opaque code may write' or 'it writes', g.name,
            name and (' (in ' .. name .. ')') or ''), 0)
    end
end

return M
