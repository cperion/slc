-- Non-executing application facts shared by staged code generation and formatting.
-- S.chain collects every group for a Word, but not for an ordinary Lua function.
-- Preserve expansion, explicit boundaries and possible immediate-match boundaries.
local M = {}

-- Used with both syntax argument lists and S.args value groups (whose explicit
-- n preserves nil arguments). Native words consume the concatenated supply.
function M.word_arguments(groups)
    local args, n = {}, 0
    for _, group in ipairs(groups) do
        for i = 1, group.n or #group do n = n + 1; args[n] = group[i] end
    end
    return args, n
end

function M.without_handler(arity, rest, count)
    return rest or count <= arity
end

local function word(fn)
    if fn.result then return { arity = #fn.params, rest = fn.rest ~= nil } end
end

local SCALAR = { name = true, num = true, str = true, ['nil'] = true,
    ['true'] = true, ['false'] = true, field = true, index = true,
    paren = true, table = true, lambda = true, struct = true, home = true }

-- Calls and spreads may expand differently at the end of each argument group.
-- Keep them grouped even when their callee is known; parentheses force one value.
local function chain(e)
    local groups, head = {}, e
    while head.k == 'call' do
        if head.boundary then return end
        table.insert(groups, 1, head.args)
        head = head.fn
    end
    if head.k == 'method' then return end
    for _, group in ipairs(groups) do
        for _, arg in ipairs(group) do
            if not SCALAR[arg.k] then return end
        end
    end
    return head, M.word_arguments(groups)
end

function M.analyze(ast)
    local scopes, refs, calls = {}, {}, {}
    local function push() scopes[#scopes + 1] = { names = {} } end
    local function pop() scopes[#scopes] = nil end
    local function bind(name, init, fact)
        scopes[#scopes].names[name] = { init = init, fact = fact }
    end
    local function lookup(name)
        for i = #scopes, 1, -1 do
            local binding = scopes[i].names[name]
            if binding then return binding end
        end
    end
    local function opened()
        for _, scope in ipairs(scopes) do if scope.opened then return true end end
        return false
    end
    local visit, block, fn
    function block(body)
        push()
        for _, stat in ipairs(body or {}) do visit(stat) end
        pop()
    end
    local native = false
    function fn(f)
        -- Header expressions are evaluated in the enclosing environment.
        for _, p in ipairs(f.params) do visit(p.type) end
        visit(f.result)
        local saved = native
        native = native or f.result ~= nil
        push()
        for _, p in ipairs(f.params) do
            bind(p.name)
            if p.opened then scopes[#scopes].opened = true end
        end
        if f.rest then bind(f.rest) end
        if f.expr then visit(f.expr) else block(f.body) end
        pop()
        native = saved
    end
    function visit(node)
        if type(node) ~= 'table' then return end
        local k = node.k
        if k == 'name' then
            refs[node] = not opened() and lookup(node.name) or false
        elseif k == 'lambda' then
            fn(node.fn)
        elseif k == 'local' then
            local typed = false
            for _, n in ipairs(node.names) do if n.type then typed = true end end
            if typed then
                -- G:stat emits annotated declarations sequentially, including
                -- the unannotated entries in the same declaration.
                for i, n in ipairs(node.names) do
                    visit(n.type); visit(node.exprs[i]); bind(n.name)
                end
            else
                for _, e in ipairs(node.exprs) do visit(e) end
                for i, n in ipairs(node.names) do
                    -- Do not infer through list expansion.
                    local init = #node.exprs == #node.names and node.exprs[i] or nil
                    bind(n.name, init)
                end
            end
        elseif k == 'localfunction' then
            bind(node.name, nil, word(node.fn))
            fn(node.fn)
        elseif k == 'assign' then
            for _, target in ipairs(node.targets) do
                if target.k == 'name' then
                    local binding = lookup(target.name)
                    if binding then binding.written = true end
                end
                visit(target)
            end
            for _, e in ipairs(node.exprs) do visit(e) end
        elseif k == 'function' then
            if #node.path == 1 and not node.method then
                local binding = lookup(node.path[1])
                if binding then binding.written = true end
            end
            -- A method's implicit self is a parameter, never an outer alias.
            push()
            if node.method then bind('self') end
            fn(node.fn)
            pop()
        elseif k == 'open' then
            visit(node.init)
            if node.init then bind(node.name) end
            scopes[#scopes].opened = true
        elseif k == 'if' then
            for _, clause in ipairs(node.clauses) do
                visit(clause.cond); block(clause.body)
            end
            block(node.els)
        elseif k == 'do' then
            block(node.body)
        elseif k == 'while' then
            visit(node.cond); block(node.body)
        elseif k == 'repeat' then
            push()
            for _, stat in ipairs(node.body) do visit(stat) end
            visit(node.cond)
            pop()
        elseif k == 'numfor' then
            visit(node.type); visit(node.lo); visit(node.hi); visit(node.step)
            push(); bind(node.var); block(node.body); pop()
        elseif k == 'genfor' then
            for _, e in ipairs(node.exprs) do visit(e) end
            push()
            for _, name in ipairs(node.names) do bind(name) end
            block(node.body)
            pop()
        else
            if k == 'call' and native then calls[#calls + 1] = node end
            -- Lists retain source order; expression children introduce no bindings.
            if not k and #node > 0 then
                for _, child in ipairs(node) do visit(child) end
            else
                for _, child in pairs(node) do visit(child) end
            end
        end
    end
    push(); visit(ast); pop()

    -- Resolve after the complete walk: even a later assignment or a write in a
    -- captured closure invalidates a binding. Alias cycles remain unknown.
    local resolve
    function resolve(e)
        if not e then return end
        if e.k == 'paren' then return resolve(e.e) end
        if e.k == 'lambda' then return word(e.fn) end
        if e.k == 'name' then
            local binding = refs[e]
            if not binding or binding.written or binding.resolving then return end
            if binding.fact ~= nil then return binding.fact or nil end
            binding.resolving = true
            binding.fact = resolve(binding.init) or false
            binding.resolving = nil
            return binding.fact or nil
        end
        if e.k == 'call' then
            local head, args = chain(e)
            local fact = head and resolve(head)
            -- Only an unsaturated application is provably another Word. Do not
            -- infer the callable returned by a saturated or overapplied word.
            if fact and #args < fact.arity then
                return { arity = fact.arity - #args, rest = fact.rest }
            end
        end
    end
    local result = { normal = {}, arguments = {} }
    for _, call in ipairs(calls) do
        local head, args = chain(call)
        local fact = head and resolve(head)
        -- Overapplication can introduce a trailing immediate-match handler.
        -- Rest words consume all arguments and have no such handler boundary.
        if fact and M.without_handler(fact.arity, fact.rest, #args) then
            local normal = {}
            for key, value in pairs(call) do normal[key] = value end
            normal.fn, normal.args, normal.juxta = head, args, nil
            result.normal[call] = normal
            result.arguments[call.args] = true
        end
    end
    return result
end

return M
