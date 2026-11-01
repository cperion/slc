-- Non-executing application facts shared by staged code generation and formatting.
-- S.chain collects every group for a Word; a function with a declared arity takes
-- whole groups until that arity; any other callable applies each group in turn.
-- Preserve expansion, explicit boundaries and possible immediate-match boundaries.
local M = {}

-- Prelude functions with a declared arity (S.arity). stage.lua declares these
-- same arities, so the compiler and the formatter cannot disagree.
M.prelude_arity = { band = 2, bor = 2, bxor = 2, shl = 2, shr = 2 }

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

-- A fact describes a callable: a word ({ word, arity, rest }), a function with
-- a declared arity ({ arity }), or a module table ({ fields }).
local function word(fn)
    if fn.result then return { word = true, arity = #fn.params, rest = fn.rest ~= nil } end
end

-- Regrouping f(a, b) as f a b is the same application exactly when the chain
-- would take every group into one call: a word without a handler boundary, or
-- a declared arity that the arguments do not exceed.
function M.regroups(fact, count)
    if fact.word then return M.without_handler(fact.arity, fact.rest, count) end
    return fact.arity ~= nil and count <= fact.arity
end

-- Calls and spreads may expand differently at the end of each argument group.
-- An operator expression is one value. A call matches its regrouped spelling
-- when it is the last argument of the whole supply, when it is not last in its
-- group (truncated in both spellings), or when `single` proves it one value.
-- Spreads and varargs always keep their groups.
local EXPANDS = { call = true, method = true }
local NEVER = { vararg = true, spread = true }
local function chain(e, single)
    local groups, head = {}, e
    while head.k == 'call' do
        if head.boundary then return end
        table.insert(groups, 1, head.args)
        head = head.fn
    end
    if head.k == 'method' then return end
    for gi, group in ipairs(groups) do
        for i, arg in ipairs(group) do
            if NEVER[arg.k] then return end
            if EXPANDS[arg.k] and i == #group and gi < #groups and not (single and single(arg)) then return end
        end
    end
    return head, M.word_arguments(groups)
end
M.chain = chain

local function unquote(text)
    local q = text:sub(1, 1)
    if (q == '"' or q == "'") and text:sub(-1) == q and not text:find('\\', 1, true) then
        return text:sub(2, -2)
    end
end

-- `extern("name", { A, B }, R [, opts])`: a declared parameter list is a declared
-- arity, unless the options might make it variadic.
local function extern_fact(args)
    local params, opts = args[2], args[4]
    if #args < 3 or #args > 4 or not params or params.k ~= 'table' then return end
    for _, item in ipairs(params.items) do
        if item.kind ~= 'pos' or item.e.k == 'spread' then return end
    end
    if opts then
        if opts.k ~= 'table' then return end
        for _, item in ipairs(opts.items) do
            if item.kind ~= 'named' or item.name == 'variadic' then return end
        end
    end
    return { arity = #params.items }
end

-- env (optional) describes the environment of a whole chunk:
--   env.globals = true        prelude names are known where nothing shadows them
--   env.module(name)          the exported facts of an SLC module, or nil
-- Without env only lexical bindings inside the analysed tree are known: the
-- compiler analyses one typed body at a time and cannot see what shadows a global.
function M.analyze(ast, env)
    env = env or {}
    local scopes, refs, calls = {}, {}, {}
    local global_writes, returns = {}, {}
    local function push() scopes[#scopes + 1] = { names = {} } end
    local function pop() scopes[#scopes] = nil end
    local function bind(name, init, fact)
        local binding = { init = init, fact = fact, fields = {} }
        scopes[#scopes].names[name] = binding
        return binding
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
    local top = 0
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
        local saved, saved_top = native, top
        native = native or f.result ~= nil
        top = top + 1
        push()
        for _, p in ipairs(f.params) do
            bind(p.name)
            if p.opened then scopes[#scopes].opened = true end
        end
        if f.rest then bind(f.rest) end
        if f.expr then visit(f.expr) else block(f.body) end
        pop()
        native, top = saved, saved_top
    end
    -- A field assigned once at the top of the chunk is a module export; any
    -- other write to it (or a computed key) makes the field unknown.
    local function write_field(target, init)
        local obj = target.obj
        if target.k ~= 'field' or obj.k ~= 'name' then return end
        local binding = lookup(obj.name)
        if not binding then return end
        local field = binding.fields[target.name]
        if field or top > 0 or #scopes > 1 or not init then binding.fields[target.name] = { written = true }
        else binding.fields[target.name] = { init = init } end
    end
    function visit(node)
        if type(node) ~= 'table' then return end
        local k = node.k
        if k == 'name' then
            refs[node] = not opened() and (lookup(node.name) or (env.globals and { global = node.name })) or false
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
            for i, target in ipairs(node.targets) do
                if target.k == 'name' then
                    local binding = lookup(target.name)
                    if binding then binding.written = true else global_writes[target.name] = true end
                elseif target.k == 'field' then
                    write_field(target, #node.targets == #node.exprs and node.exprs[i] or nil)
                elseif target.k == 'index' and target.obj.k == 'name' then
                    local binding = lookup(target.obj.name)
                    if binding then binding.written = true end
                end
                visit(target)
            end
            for _, e in ipairs(node.exprs) do visit(e) end
        elseif k == 'function' then
            if #node.path == 1 and not node.method then
                local binding = lookup(node.path[1])
                if binding then binding.written = true else global_writes[node.path[1]] = true end
            elseif #node.path == 2 and not node.method then
                write_field({ k = 'field', obj = { k = 'name', name = node.path[1] }, name = node.path[2] },
                    { k = 'lambda', fn = node.fn })
            end
            -- A method's implicit self is a parameter, never an outer alias.
            push()
            if node.method then bind('self') end
            fn(node.fn)
            pop()
        elseif k == 'return' then
            if top == 0 and #scopes == 1 and #node.exprs == 1 then returns[#returns + 1] = node.exprs[1] end
            for _, e in ipairs(node.exprs) do visit(e) end
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
    local function table_fact(binding, constructor)
        local fact = { fields = {} }
        local function field(name, init)
            local resolved = init and resolve(init)
            if resolved then fact.fields[name] = resolved end
        end
        if constructor then
            for _, item in ipairs(constructor.items) do
                if item.kind == 'named' then field(item.name, item.e)
                elseif item.kind ~= 'pos' then return end
            end
        end
        for name, slot in pairs(binding and binding.fields or {}) do
            fact.fields[name] = nil
            if not slot.written then field(name, slot.init) end
        end
        return fact
    end
    function resolve(e)
        if not e then return end
        if e.k == 'paren' then return resolve(e.e) end
        if e.k == 'lambda' then return word(e.fn) end
        if e.k == 'table' then return table_fact(nil, e) end
        if e.k == 'name' then
            local binding = refs[e]
            if not binding then return end
            if binding.global then
                local arity = not global_writes[binding.global] and M.prelude_arity[binding.global]
                return arity and { arity = arity } or nil
            end
            if binding.written or binding.resolving then return end
            if binding.fact ~= nil then return binding.fact or nil end
            binding.resolving = true
            if binding.init and binding.init.k == 'table' then
                binding.fact = table_fact(binding, binding.init)
            else
                binding.fact = resolve(binding.init) or false
            end
            binding.resolving = nil
            return binding.fact or nil
        end
        if e.k == 'field' then
            local owner = resolve(e.obj)
            return owner and owner.fields and owner.fields[e.name]
        end
        if e.k == 'call' and e.fn.k == 'name' and not e.boundary then
            local binding = refs[e.fn]
            local global = binding and binding.global and not global_writes[binding.global] and binding.global
            if global == 'extern' then return extern_fact(e.args) end
            if global == 'require' and env.module and #e.args == 1 and e.args[1].k == 'str' then
                local name = unquote(e.args[1].text)
                return name and env.module(name) or nil
            end
        end
        if e.k == 'call' then
            local head, args = chain(e)
            local fact = head and resolve(head)
            -- Only an unsaturated application of a word is provably another
            -- word. Do not infer the callable returned by a saturated or
            -- overapplied word, nor by any function with a declared arity.
            if fact and fact.word and #args < fact.arity then
                return { word = true, arity = fact.arity - #args, rest = fact.rest }
            end
        end
    end
    -- only a word is known to return one value
    local function single(e)
        if e.k ~= 'call' then return false end
        local head = chain(e, single)
        local fact = head and resolve(head)
        return fact ~= nil and fact.word == true
    end
    local result = { normal = {}, arguments = {}, resolve = resolve, single = single }
    for _, call in ipairs(calls) do
        local head, args = chain(call, single)
        local fact = head and resolve(head)
        -- Overapplication can introduce a trailing immediate-match handler.
        -- Rest words consume all arguments and have no such handler boundary.
        if fact and fact.arity and M.regroups(fact, #args) then
            local normal = {}
            for key, value in pairs(call) do normal[key] = value end
            normal.fn, normal.args, normal.juxta = head, args, nil
            result.normal[call] = normal
            result.arguments[call.args] = true
        end
    end
    -- A chunk that returns one table exports its known callables.
    if #returns == 1 then
        local exported = resolve(returns[1])
        result.exports = exported and exported.fields and exported or nil
    end
    return result
end

return M
