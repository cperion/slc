-- SLC source formatter. Parsing never evaluates the source being formatted.
-- Keep the compiler's grammar authoritative; retain tokens for comments/spelling.
local lexer = require 'macro.lexer'
local syntax = require 'slc.syntax'
local application = require 'slc.application'
local loader = require 'slc.loader'
local M = {}
-- the word facts of the chunk being formatted (see module_environment)
local environment
M.defaults = { indent_width = 4, column_width = 100, call_style = 'minimal', spine_style = 'pure',
               type_style = 'inferred', table_style = 'shorthand', opening_style = 'anonymous' }

function M.options(options)
    local out = {}
    for k, v in pairs(M.defaults) do out[k] = v end
    if options ~= nil and type(options) ~= 'table' then error('fmt: configuration must return a table', 0) end
    for k, v in pairs(options or {}) do
        if out[k] == nil then error('fmt: unknown setting ' .. tostring(k), 0) end
        out[k] = v
    end
    for _, k in ipairs { 'indent_width', 'column_width' } do
        local v = out[k]
        local lo, hi = k == 'indent_width' and 1 or 20, k == 'indent_width' and 8 or 240
        if type(v) ~= 'number' or v ~= math.floor(v) or v < lo or v > hi then
            error(('fmt: %s must be an integer from %d to %d'):format(k, lo, hi), 0)
        end
    end
    if out.call_style ~= 'minimal' and out.call_style ~= 'preserve' then
        error('fmt: call_style must be "minimal" or "preserve"', 0)
    end
    if out.type_style ~= 'inferred' and out.type_style ~= 'preserve' then
        error('fmt: type_style must be "inferred" or "preserve"', 0)
    end
    if out.table_style ~= 'preserve' and out.table_style ~= 'shorthand' then
        error('fmt: table_style must be "preserve" or "shorthand"', 0)
    end
    if out.opening_style ~= 'anonymous' and out.opening_style ~= 'preserve' then
        error('fmt: opening_style must be "anonymous" or "preserve"', 0)
    end
    if out.spine_style ~= 'pure' and out.spine_style ~= 'all' and out.spine_style ~= 'none' then
        error('fmt: spine_style must be "pure", "all" or "none"', 0)
    end
    return out
end

local function tokens(source)
    local raw = lexer.scan_raw_tokenlist(source)
    local out, pos = {}, 1
    local i = 1
    while i <= #raw do
        local t, v, line = unpack(raw[i])
        if t == 'number' and raw[i + 1] and raw[i + 1][1] == 'iden'
            and raw[i + 1][2]:match('^[uU]?[lL][lL]$') then
            v = v .. raw[i + 1][2]; i = i + 1
        elseif t == '.' then
            while raw[i + 1] and raw[i + 1][1] == '.' and #v < 3 do
                v = v .. '.'; i = i + 1
            end
            t = v
        end
        out[#out + 1] = { t = t, v = v, line = line, first = pos, last = pos + #v - 1 }
        pos = pos + #v
        i = i + 1
    end
    return out
end

-- The lambda a spine link applies in tail position: its last statement is a
-- call whose last argument is a block lambda.
local function applied_lambda(stat)
    if type(stat) ~= 'table' or stat.k ~= 'callstat' then return nil end
    local e = stat.e
    if type(e) ~= 'table' or (e.k ~= 'call' and e.k ~= 'method') then return nil end
    local arg = e.args and e.args[#e.args]
    if type(arg) == 'table' and arg.k == 'lambda' and arg.fn and arg.fn.body then return arg.fn end
    return nil
end

local function is_block_lambda(fn)
    return type(fn) == 'table' and fn.body ~= nil and fn.result == nil
end

-- Parse the whole source, including the two forms normally owned by macros:
-- top-level export paths/aliases and a top-level typed lambda's end boundary.
local function parse(source, filename)
    local ts = tokens(source)
    local cursor, line = 0, 1
    local r = syntax.reader(function()
        cursor = cursor + 1
        local tk = ts[cursor]
        if tk then line = tk.line; return tk.t, tk.v end
    end, nil, function() return line end, filename)
    local fetch, next_token = r.fetch, r.next
    local mapped, last = 1, 0
    function r:fetch()
        local tk = fetch(self)
        while ts[mapped] and (ts[mapped].t == 'space' or ts[mapped].t == 'comment') do mapped = mapped + 1 end
        tk.index = mapped
        if tk.t ~= 'eof' then mapped = mapped + 1 end
        return tk
    end
    function r:next()
        local tk = next_token(self); last = tk.index; return tk
    end
    local p = syntax.parser(r)
    local ranges, groups, group_of, colons, unary, chains = {}, {}, {}, {}, {}, {}
    local lambdas, body_ranges = {}, {}
    local typespans, locals, parameter_names = {}, {}, {}
    local suffixed_from = p.suffixed_from
    function p:suffixed_from(...)
        local result = suffixed_from(self, ...)
        chains[#chains + 1] = result
        return result
    end
    local block, args, typeexpr, funcbody, statement = p.block, p.args, p.typeexpr, p.funcbody, p.statement
    local subexpr = p.subexpr
    function p:subexpr(...)
        local tk = r:peek()
        if tk.t == '-' or tk.t == '#' then unary[tk.index] = true end
        return subexpr(self, ...)
    end
    -- The same token opens/expands in prefix or suffix position and concatenates
    -- in infix position. Use the parser's decision, not whitespace, to format it.
    local binop = p.binop
    function p:binop(tk)
        local op = binop(self, tk)
        if op == '..' then ts[tk.index].concat = true end
        return op
    end
    local depth, native_depth, host_argument_depth = 0, 0, 0
    local argument = p.argument
    function p:argument()
        local host = native_depth == 0
        if host then host_argument_depth = host_argument_depth + 1 end
        local result = argument(self)
        if host then host_argument_depth = host_argument_depth - 1 end
        return result
    end
    function p:block(kind)
        local start = last + 1
        depth = depth + 1
        local result = block(self, kind)
        if depth > 1 then
            local closer = r:peek(1)
            local range = { start, closer.index - 1 }
            if kind == 'lambda' then
                range.endall = (closer.t == 'iden' and closer.v == 'endall') or nil
                if applied_lambda(result[#result]) then
                    range.link = true
                    if #result == 1 then range.pure = true end
                end
                body_ranges[result] = range
            end
            ranges[#ranges + 1] = range
        end
        depth = depth - 1
        return result
    end
    local lambda = p.lambda
    function p:lambda(hint)
        local native = native_depth > 0
        local node = lambda(self, hint)
        local closer
        if ts[last] and (ts[last].v == 'end' or ts[last].v == 'endall') then
            closer = last
        else
            closer = r:peek(1).index
        end
        lambdas[#lambdas + 1] = { fn = node.fn, closer = closer, native = native }
        return node
    end
    local item, item_ends = p.item, {}
    function p:item(...)
        local result = item(self, ...)
        item_ends[result] = last
        return result
    end
    function p:args()
        local start = r:peek().index
        local result = args(self)
        if ts[start].v == '(' then
            -- Every delimited group, with the token span of each argument and
            -- separator; spelling is decided once the whole tree is known.
            local firsts, lasts, separators = {}, {}, {}
            local at = start + 1
            for i, item in ipairs(result) do
                while ts[at].t == 'space' or ts[at].t == 'comment' do at = at + 1 end
                firsts[i], lasts[i] = at, item_ends[item]
                if i < #result then
                    local sep = item_ends[item] + 1
                    while ts[sep].t == 'space' or ts[sep].t == 'comment' do sep = sep + 1 end
                    assert(ts[sep].t == ',')
                    separators[i] = sep
                    at = sep + 1
                end
            end
            local group = { open = start, close = last, args = result, firsts = firsts, lasts = lasts,
                            separators = separators, native = native_depth > 0,
                            host_argument = host_argument_depth > 0 }
            groups[#groups + 1] = group
            group_of[result] = group
        end
        return result
    end
    function p:typeexpr()
        local colon = last
        if ts[last] and ts[last].v == ':' then colons[last] = true end
        local result = typeexpr(self)
        typespans[result] = { colon, last }
        return result
    end
    function p:funcbody(name, at, opts)
        local nesting, j, names = 0, 1, {}
        repeat
            local tk = r:peek(j)
            if tk.t == 'eof' then break end
            if tk.t == '(' then nesting = nesting + 1 end
            if tk.t == ')' then nesting = nesting - 1 end
            if nesting == 1 and tk.t == 'iden' and r:peek(j + 1).t == '..'
                and j > 1 and (r:peek(j - 1).t == '(' or r:peek(j - 1).t == ',') then
                names[tk.v] = tk.index
            end
            j = j + 1
        until nesting == 0
        local typed = r:peek(j).t == ':'
        if typed and native_depth == 0 and opts and opts.lambda then
            local copy = {}; for k, v in pairs(opts) do copy[k] = v end
            copy.lambda = false; opts = copy
        end
        if typed then native_depth = native_depth + 1 end
        local result = funcbody(self, name, at, opts)
        for _, prm in ipairs(result.params) do
            if prm.opened and not prm.unnamed then parameter_names[prm] = names[prm.name] end
        end
        if typed then native_depth = native_depth - 1 end
        return result
    end
    function p:statement()
        if r:peek().t == 'iden' and r:peek().v == 'goto' then
            r:next(); return { k = 'goto', name = r:name('after goto').v }
        end
        if r:peek().t == ':' and r:peek(2).t == ':' then
            r:next(); r:next()
            local name = r:name('in label').v
            r:expect(':'); r:expect(':')
            return { k = 'label', name = name }
        end
        if depth == 1 and r:peek().v == 'export' then
            r:next()
            local path = { r:name('after export').v }
            while r:accept('.') do path[#path + 1] = r:name('in export path').v end
            local alias
            if r:peek().t == 'iden' and r:peek().v == 'as' and not r:peek().nl then
                r:next()
                if r:peek().t ~= 'string' then r:error('expected a string after export as') end
                alias = r:next().v
            end
            return { k = 'export', path = path, alias = alias }
        end
        local result = statement(self)
        -- annotations are only meaningful in native (typed) bodies
        if native_depth > 0 and type(result) == 'table' and result.k == 'local' then
            locals[#locals + 1] = result
        end
        return result
    end
    local ast = p:block()
    r:expect('eof')
    -- A link flattens only when its applied lambda is closed by the same
    -- `endall`: that is the chain which shares one closer token.
    local meta = {}
    for _, item in ipairs(lambdas) do meta[item.fn] = item end
    for _, item in ipairs(lambdas) do
        local range = item.fn.body and body_ranges[item.fn.body]
        if range then
            if item.fn.result ~= nil then
                -- a typed word is a word body, not a trailing block lambda
                range.endall, range.link, range.pure, range.child_same = nil, nil, nil, nil
            else
                local child = applied_lambda(item.fn.body[#item.fn.body])
                range.child_same = (child ~= nil and meta[child] ~= nil
                    and meta[child].closer == item.closer) or nil
            end
        end
    end
    -- Delimited lists can wrap after commas; application chains cannot.
    local stack, commas = {}, {}
    for i, tk in ipairs(ts) do
        if tk.t == '(' or tk.t == '[' or tk.t == '{' then
            stack[#stack + 1] = { start = i, kind = tk.t, commas = {} }
        elseif tk.t == ')' or tk.t == ']' or tk.t == '}' then
            local open = table.remove(stack)
            if open then
                ranges[#ranges + 1] = { open.start + 1, i - 1 }
                if open.kind ~= '[' then
                    for _, index in ipairs(open.commas) do commas[index] = { open.start, i } end
                end
            end
        elseif tk.t == ',' and #stack > 0 then
            local open = stack[#stack]; open.commas[#open.commas + 1] = i
        end
    end
    local facts = application.analyze(ast, environment)
    return { ast = ast, tokens = ts, ranges = ranges, groups = groups, group_of = group_of, facts = facts,
             colons = colons, commas = commas, unary = unary, chains = chains, lambdas = lambdas,
             typespans = typespans, locals = locals, parameter_names = parameter_names }
end

-- Compare the compiler's proven application normal forms, not just spelling.
-- Unknown argument groups and expression grouping retain their exact structure.
local function fingerprint(root)
    local facts = application.analyze(root, environment)
    local function encode(node)
        if type(node) ~= 'table' then
            local value = tostring(node)
            return type(node) .. ':' .. #value .. ':' .. value
        end
        node = facts.normal[node] or node
        -- Only the parser's synthetic literal parentheses are erased.
        if node.k == 'paren' and (node.e.k == 'num' or node.e.k == 'str') then return encode(node.e) end
        local keys = {}
        for k in pairs(node) do
            if k ~= 'line' and k ~= 'end_line' and k ~= 'juxta' then keys[#keys + 1] = k end
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local out = { '{' }
        for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. '=' .. encode(node[k]) .. ';' end
        out[#out + 1] = '}'
        return table.concat(out)
    end
    return encode(root)
end

-- The environment of a chunk's word facts: prelude names, and the exports of
-- the SLC modules it requires, found the way compilation finds them and read
-- (never run) with this parser. A Lua module on the path takes precedence.
local root = (debug.getinfo(1, 'S').source:match('^@(.*)/slc/[^/]*$')) or '.'
local function module_environment(filename)
    local dir = filename and filename:match('^(.*)/[^/]*$') or '.'
    local path = dir .. '/?.lua;' .. dir .. '/?/init.lua;' .. package.path
    local cache, env = {}, { globals = true }
    function env.module(name)
        if cache[name] ~= nil then return cache[name] or nil end
        cache[name] = false -- a cycle resolves to unknown
        if package.preload[name] or package.searchpath(name, path) then return nil end
        for _, file in ipairs(loader.candidates(root, name, path)) do
            local f = io.open(file, 'rb')
            if f then
                local source = f:read('*a'); f:close()
                local saved = environment
                environment = env
                local ok, info = pcall(parse, source, file)
                environment = saved
                cache[name] = ok and info.facts.exports or false
                return cache[name] or nil
            end
        end
    end
    return env
end

-- A spine is a maximal chain of trailing block lambdas whose bodies end at the
-- same closer: each link's last statement is the call that takes the next. When
-- the chain sits in a typed body and each link closes with `end`, the run folds
-- into one `endall`; the calls stay, the closers become one.
local function fold_spines(source, info, filename, signature)
    local ts = info.tokens
    local meta = {}
    for _, item in ipairs(info.lambdas) do meta[item.fn] = item end
    local children = {}
    for fn in pairs(meta) do
        if is_block_lambda(fn) then
            local child = applied_lambda(fn.body[#fn.body])
            if child and child ~= fn and meta[child] and is_block_lambda(child) then
                children[fn] = child
                meta[child].parent = fn
            end
        end
    end
    local edits = {}
    for fn, item in pairs(meta) do
        if is_block_lambda(fn) and not item.parent then
            local chain = { item }
            local cursor = fn
            while children[cursor] do
                cursor = children[cursor]
                chain[#chain + 1] = meta[cursor]
            end
            if #chain >= 2 then
                local foldable = true
                for _, part in ipairs(chain) do
                    if not part.native then foldable = false end
                end
                local closers = {}
                for i = #chain, 1, -1 do closers[#closers + 1] = chain[i].closer end
                for i = 2, #closers do
                    if closers[i] <= closers[i - 1] then foldable = false end
                    if foldable then
                        for j = closers[i - 1] + 1, closers[i] - 1 do
                            if ts[j].t ~= 'space' then foldable = false; break end
                        end
                    end
                    if not foldable then break end
                end
                if foldable then
                    edits[#edits + 1] = { ts[closers[1]].first, ts[closers[#closers]].last }
                end
            end
        end
    end
    if #edits == 0 then return source end
    table.sort(edits, function(a, b) return a[1] > b[1] end)
    local candidate = source
    for _, edit in ipairs(edits) do
        candidate = candidate:sub(1, edit[1] - 1) .. 'endall' .. candidate:sub(edit[2] + 1)
    end
    local ok, reparsed = pcall(parse, candidate, filename)
    if ok and fingerprint(reparsed.ast) == signature then return candidate end
    return source
end

-- A native local takes its type from its initializer (spec 8.1), so an
-- annotation can repeat what the syntax already shows. Two cases are decided
-- here, and nothing else, because the formatter does not know what any other
-- initializer evaluates to:
--   * the initializer is exactly an application of the annotated type
--     expression: `local p: Point = Point { ... }`
--   * the initializer is a name whose declared type is the same bare type
--     name: `local i: U32 = n` with `n: U32` a parameter or earlier local
local function unparen(e)
    while type(e) == 'table' and e.k == 'paren' do e = e.e end
    return e
end

-- text views stay explicit: inference does not copy a borrowed view
local KEEP_TYPES = { Str = true, Text = true }

local function drop_inferred(source, info, filename)
    local native = {}
    for _, stat in ipairs(info.locals) do native[stat] = true end
    local edits, dropped = {}, {}
    local scopes = {}
    local function declare(name, fact) scopes[#scopes].names[name] = fact end
    local function lookup(name)
        for i = #scopes, 1, -1 do
            local fact = scopes[i].names[name]
            if fact ~= nil then return fact end
        end
    end
    local function push() scopes[#scopes + 1] = { names = {} } end
    local function pop() scopes[#scopes] = nil end
    local function typefp(t) return fingerprint(unparen(t)) end

    local walk
    local function walk_children(node)
        local keys = {}
        for k in pairs(node) do
            if k ~= 'line' and k ~= 'end_line' then keys[#keys + 1] = k end
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do walk(node[k]) end
    end
    function walk(node)
        if type(node) ~= 'table' then return end
        local k = node.k
        if k == 'local' then
            for _, e in ipairs(node.exprs) do walk(e) end
            local pairwise = #node.exprs == #node.names
            for i, entry in ipairs(node.names) do
                local init = pairwise and node.exprs[i] or nil
                local span = entry.type and info.typespans[entry.type]
                local fact = false
                if entry.type then fact = typefp(entry.type) end
                if native[node] and span and type(init) == 'table' then
                    local same = false
                    if init.k == 'call' and typefp(init.fn) == fact then same = true end
                    local t = unparen(entry.type)
                    if init.k == 'name' and t.k == 'name' and not KEEP_TYPES[t.name]
                        and lookup(init.name) == fact then same = true end
                    if same then
                        edits[#edits + 1] = { info.tokens[span[1]].first, info.tokens[span[2]].last }
                        dropped[#dropped + 1] = entry
                    end
                elseif not entry.type and type(init) == 'table' and init.k == 'call' then
                    fact = typefp(init.fn)
                end
                declare(entry.name, fact)
            end
        elseif k == 'localfunction' then
            declare(node.name, false)
            walk(node.fn)
        elseif k == 'open' then
            walk(node.init)
            declare(node.name, false)
        elseif k == 'numfor' then
            walk(node.lo); walk(node.hi); walk(node.step)
            push()
            declare(node.var, node.type and typefp(node.type) or false)
            walk(node.body)
            pop()
        elseif k == 'genfor' then
            for _, e in ipairs(node.exprs) do walk(e) end
            push()
            for _, n in ipairs(node.names) do declare(n, false) end
            walk(node.body)
            pop()
        elseif k == nil and node.params and node.body then
            push()
            for _, prm in ipairs(node.params) do
                declare(prm.name, (prm.type and not prm.opened) and typefp(prm.type) or false)
            end
            walk(node.body)
            pop()
        elseif k == nil and #node > 0 then
            push()
            for _, child in ipairs(node) do walk(child) end
            pop()
        else
            walk_children(node)
        end
    end
    push()
    walk(info.ast)
    if #edits == 0 then return source end
    table.sort(edits, function(a, b) return a[1] > b[1] end)
    local candidate = source
    for _, edit in ipairs(edits) do
        candidate = candidate:sub(1, edit[1] - 1) .. candidate:sub(edit[2] + 1)
    end
    local types = {}
    for i, entry in ipairs(dropped) do types[i] = entry.type; entry.type = nil end
    local expected = fingerprint(info.ast)
    for i, entry in ipairs(dropped) do entry.type = types[i] end
    local ok, reparsed = pcall(parse, candidate, filename)
    if ok and fingerprint(reparsed.ast) == expected then return candidate end
    return source
end

-- A named opening whose name is never mentioned needs only its anonymous home.
-- Be conservative: nested mentions count even if a later binding might shadow
-- the parameter. Opening can introduce unknown names, so this is syntax analysis,
-- not a claim about which dynamic vocabulary supplies a reference.
local function drop_opening_names(source, info, filename)
    local function mentions(node, name)
        if type(node) ~= 'table' then return false end
        local function matches(n) return n == name or n == '__home' end
        -- Introducing a home must not capture an enclosing anonymous home.
        if node.k == 'home' or node.k == 'name' and matches(node.name) then return true end
        if node.k == 'open' and not node.init and matches(node.name) then return true end
        if (node.k == 'function' or node.k == 'export')
            and matches(node.path and node.path[1] or node.name) then return true end
        for _, child in pairs(node) do
            if mentions(child, name) then return true end
        end
        return false
    end
    local edits, changed = {}, {}
    for _, item in ipairs(info.lambdas) do
        local fn = item.fn
        local has_home = fn.rest == '__home'
        for _, prm in ipairs(fn.params) do
            if prm.name == '__home' then has_home = true end
        end
        if not has_home then
            for _, prm in ipairs(fn.params) do
                local index = info.parameter_names[prm]
                local repeated = fn.rest == prm.name
                for _, other in ipairs(fn.params) do
                    if other ~= prm and other.name == prm.name then repeated = true end
                end
                if index and not repeated and not mentions(fn.body or fn.expr, prm.name) then
                    local tk = info.tokens[index]
                    edits[#edits + 1] = { tk.first, tk.last }
                    changed[#changed + 1] = { param = prm, name = prm.name, unnamed = prm.unnamed }
                end
            end
        end
    end
    if #edits == 0 then return source end
    table.sort(edits, function(a, b) return a[1] > b[1] end)
    local candidate = source
    for _, edit in ipairs(edits) do
        candidate = candidate:sub(1, edit[1] - 1) .. candidate:sub(edit[2] + 1)
    end
    for _, change in ipairs(changed) do
        change.param.name, change.param.unnamed = '__home', true
    end
    local expected = fingerprint(info.ast)
    for _, change in ipairs(changed) do
        change.param.name, change.param.unnamed = change.name, change.unnamed
    end
    local ok, reparsed = pcall(parse, candidate, filename)
    if ok and fingerprint(reparsed.ast) == expected then return candidate end
    return source
end

-- `{ x = x }` is `{ .x }`: the same parsed program, so this is only spelling.
-- Only entries directly inside a table constructor qualify (`a, x = x, y` as a
-- statement is not one).
local function shorthand(source, info, filename)
    local ts = info.tokens
    local function significant(i, step)
        i = i + step
        while ts[i] and (ts[i].t == 'space' or ts[i].t == 'comment') do i = i + step end
        return i
    end
    local stack, edits = {}, {}
    for i, tk in ipairs(ts) do
        if tk.t == '(' or tk.t == '[' or tk.t == '{' then
            stack[#stack + 1] = tk.t
        elseif tk.t == ')' or tk.t == ']' or tk.t == '}' then
            stack[#stack] = nil
        elseif tk.t == 'iden' and stack[#stack] == '{' then
            local eq = significant(i, 1)
            local value = significant(eq, 1)
            local before, after = ts[significant(i, -1)], ts[significant(value, 1)]
            if ts[eq] and ts[eq].t == '=' and ts[value] and ts[value].t == 'iden' and ts[value].v == tk.v
                and before and (before.t == '{' or before.t == ',' or before.t == ';')
                and after and (after.t == ',' or after.t == ';' or after.t == '}') then
                local clean = true
                for j = i + 1, value - 1 do
                    if ts[j].t == 'comment' or ts[j].t == 'space' and ts[j].v:find('\n', 1, true) then clean = false end
                end
                if clean then edits[#edits + 1] = { tk.first, ts[value].last, tk.v } end
            end
        end
    end
    if #edits == 0 then return source end
    table.sort(edits, function(a, b) return a[1] > b[1] end)
    local candidate = source
    for _, edit in ipairs(edits) do
        candidate = candidate:sub(1, edit[1] - 1) .. '.' .. edit[3] .. candidate:sub(edit[2] + 1)
    end
    local ok, reparsed = pcall(parse, candidate, filename)
    if ok and fingerprint(reparsed.ast) == fingerprint(info.ast) then return candidate end
    return source
end

-- Call spelling. Each '(' group is decided once, innermost first, from the tree
-- and the word facts: a group loses its delimiters when its arguments can be
-- juxtaposed (syntax 2.4), and a compound argument becomes a spaced group.
-- Edits replace or surround whole tokens, so nested decisions compose and
-- comments stay where they are. Decisions are grouped by application chain,
-- the unit a fallback can accept or refuse on its own.
local KEYWORDS = {}
for w in ([[and break do else elseif end false for function if in local nil not or
repeat return then true until while goto]]):gmatch '%S+' do KEYWORDS[w] = true end

local function line_comment(tk) return tk.t == 'comment' and not tk.v:match('^%-%-%[=*%[') end

local function name_headed(e)
    while e.k == 'field' or e.k == 'index' or e.k == 'call' or e.k == 'method' do
        e = e.k == 'call' and e.fn or e.obj
    end
    return e.k == 'name'
end

local HOST_SAFE = { name = true, num = true, str = true, ['true'] = true, ['false'] = true, table = true }

local function decide_calls(info, column_width)
    local ts, facts, group_of = info.tokens, info.facts, info.group_of
    local parent, order = {}, {}
    local function walk(node, up, key)
        local here = up
        if node.k then parent[node] = { node = up, key = key }; here = node end
        for k, child in pairs(node) do
            if type(child) == 'table' then walk(child, here, node.k and k or key) end
        end
        local group = (node.k == 'call' or node.k == 'method') and node.args and group_of[node.args]
        if group then group.call = node; order[#order + 1] = group end
    end
    walk(info.ast, nil, nil)
    local function after(i)
        local j, newline = i + 1, false
        while ts[j] and (ts[j].t == 'space' or ts[j].t == 'comment') do
            if ts[j].v:find('\n', 1, true) then newline = true end
            j = j + 1
        end
        return ts[j], newline
    end
    local function decided(node)
        local group = group_of[node.args]
        return node.juxta or (group and (group.bare or group.spaced))
    end
    -- 'primary' and 'call' can be juxtaposed as they are; 'compound' needs a
    -- spaced group; 'group' already is one; 'never' cannot be regrouped
    local function form(e)
        local k = e.k
        if k == 'name' or k == 'num' or k == 'str' or k == 'true' or k == 'false' or k == 'table' then return 'primary' end
        if k == 'paren' then return (e.e.k == 'num' or e.e.k == 'str') and 'primary' or 'group' end
        if k == 'lambda' then return e.fn.body and 'primary' or 'compound' end
        if k == 'field' or k == 'index' then
            local base = form(e.obj)
            return (base == 'primary' or base == 'call') and 'primary' or 'compound'
        end
        if k == 'call' or k == 'method' then
            local base = form(k == 'method' and e.obj or e.fn)
            if (base ~= 'primary' and base ~= 'call') or decided(e) then return 'compound call' end
            return 'call'
        end
        if k == 'vararg' or k == 'spread' or k == 'home' then return 'never' end
        return 'compound'
    end
    local function callee_end(C)
        if C.k == 'method' then return 'name' end
        local f = C.fn
        if f.k == 'name' or f.k == 'field' then return 'name' end
        if f.k == 'call' or f.k == 'method' then
            if decided(f) then return 'arg' end
            return 'call', group_of[f.args]
        end
        return 'other'
    end
    -- only a word is known to return one value; any other call may expand
    local function single_valued(e)
        if e.k ~= 'call' then return e.k ~= 'method' end
        return facts.single(e)
    end
    local function decide(G)
        local C = G.call
        local up = parent[C] or {}
        local P = up.node
        -- a postfix on the result would attach to the last argument instead
        if P and (P.k == 'field' or P.k == 'index' or P.k == 'method') and up.key == 'obj' then return end
        local outer = P and P.k == 'call' and up.key == 'fn' and P or nil
        local n = #G.args
        local next_tk, newline = after(G.close)
        if n == 0 then
            -- only a named call statement omits empty parentheses; a following
            -- '(' would be read as an argument in host Lua
            if not (P and P.k == 'callstat') then return end
            if C.k == 'call' and C.fn.k ~= 'name' and C.fn.k ~= 'field' then return end
            if next_tk and next_tk.t == '(' then return end
            G.bare = true
            return
        end
        -- a name after the call would become one more argument
        if not outer and next_tk and not newline and next_tk.t == 'iden' and not KEYWORDS[next_tk.v] then return end
        local wraps = {}
        if n == 1 then
            local a = G.args[1]
            local f = form(a)
            if f ~= 'primary' and f ~= 'call' then return end
            if not G.native and (G.host_argument or not (HOST_SAFE[a.k] or (a.k == 'lambda' and a.fn.body))) then
                return
            end
        else
            if not G.native or not facts.arguments[G.args] then return end
            -- Arguments on several lines are joined only when the call then fits
            -- the column width: an application chain cannot be wrapped later.
            local gaps = { { G.open, G.firsts[1] }, { G.lasts[n], G.close } }
            for i = 1, n - 1 do gaps[#gaps + 1] = { G.lasts[i], G.firsts[i + 1] } end
            local split = false
            for _, range in ipairs(gaps) do
                for k = range[1] + 1, range[2] - 1 do
                    if ts[k].t == 'space' and ts[k].v:find('\n', 1, true) then split = true end
                end
            end
            if split then
                local width = 0
                local k = G.open - 1
                while k > 0 and not (ts[k].t == 'space' and ts[k].v:find('\n', 1, true)) do
                    width = width + #ts[k].v; k = k - 1
                end
                for i = 1, n do
                    for j = G.firsts[i], G.lasts[i] do
                        if ts[j].v:find('\n', 1, true) then return end
                        width = width + #ts[j].v
                    end
                    width = width + 3 -- a separating space, or a spaced group's brackets
                end
                if width > column_width then return end
            end
            for i, a in ipairs(G.args) do
                local f = form(a)
                if f == 'never' then return end
                -- a group expands its last call; only a word is one value elsewhere
                if (f == 'call' or f == 'compound call') and i < n and not single_valued(a) then return end
                if f == 'compound' or f == 'compound call' then wraps[i] = true end
                -- a name argument's chain would take a string or table after it
                if i > 1 and (a.k == 'str' or a.k == 'table') and not wraps[i - 1] and name_headed(G.args[i - 1]) then
                    wraps[i] = true
                end
            end
        end
        -- the same holds across groups: `f(a)("x")` keeps its second group
        if n == 1 and (G.args[1].k == 'str' or G.args[1].k == 'table') and C.k == 'call'
            and (C.fn.k == 'call' or C.fn.k == 'method') then
            local inner = group_of[C.fn.args]
            local last = inner and inner.bare and inner.args[#inner.args]
            if (last and name_headed(last) and not inner.wraps[#inner.args]) or C.fn.juxta then return end
        end
        -- a name argument needs a name, an argument or a spaced group before it
        local ends, inner = callee_end(C)
        if name_headed(G.args[1]) and not wraps[1] and ends ~= 'name' and ends ~= 'arg' then
            if ends == 'call' and inner and G.native then inner.spaced = true else return end
        end
        -- a name argument's chain would take a following string or table
        if outer and not group_of[outer.args] and not outer.juxta and name_headed(G.args[n]) and not wraps[n] then
            return
        end
        G.bare, G.wraps = true, wraps
        if outer and group_of[outer.args] then group_of[outer.args].after_bare = true end
    end
    for _, G in ipairs(order) do
        decide(G)
        -- a kept group right after a bare one is spaced, so it stays an argument
        if G.after_bare and not G.bare then G.spaced = true end
    end
    -- the application chain each group belongs to
    for _, G in ipairs(order) do
        local node = G.call
        while parent[node] and parent[node].node and parent[node].node.k == 'call' and parent[node].key == 'fn' do
            node = parent[node].node
        end
        G.unit = node
    end
    return order
end

local function render_calls(info, order, accept)
    local ts = info.tokens
    local replace, before, behind = {}, {}, {}
    local function blank(i, j)
        for k = i, j do
            if ts[k].t == 'space' then
                -- the newline ending a line comment stays
                replace[k] = (line_comment(ts[k - 1]) and ts[k].v:find('\n', 1, true)) and '\n' or ''
            end
        end
    end
    local changed = false
    for _, G in ipairs(order) do
        if accept(G.unit) and G.bare then
            changed = true
            local n = #G.args
            if n == 0 then
                replace[G.open], replace[G.close] = '', ''
                blank(G.open + 1, G.close - 1)
            else
                replace[G.open], replace[G.close] = ' ', ''
                blank(G.open + 1, G.firsts[1] - 1)
                for i = 1, n do
                    local stop = G.lasts[i]
                    if i < n then
                        blank(stop + 1, G.separators[i] - 1)
                        replace[G.separators[i]] = ' '
                        blank(G.separators[i] + 1, G.firsts[i + 1] - 1)
                    else
                        blank(stop + 1, G.close - 1)
                    end
                    if G.wraps[i] then
                        before[G.firsts[i]] = '(' .. (before[G.firsts[i]] or '')
                        behind[stop] = (behind[stop] or '') .. ')'
                    end
                end
            end
        elseif accept(G.unit) and G.spaced and ts[G.open - 1].t ~= 'space' then
            changed = true
            before[G.open] = ' ' .. (before[G.open] or '')
        end
    end
    if not changed then return end
    local out = {}
    for i, tk in ipairs(ts) do out[i] = (before[i] or '') .. (replace[i] or tk.v) .. (behind[i] or '') end
    return table.concat(out)
end

-- One round: decide every group, render, and verify once. If the whole round
-- does not verify, accept the chains that verify on their own.
local function spell(source, info, filename, signature, column_width)
    local order = decide_calls(info, column_width)
    local function verified(candidate)
        if not candidate then return end
        local ok, reparsed = pcall(parse, candidate, filename)
        if ok and fingerprint(reparsed.ast) == signature then return candidate end
    end
    local all = render_calls(info, order, function() return true end)
    if not all then return source end
    if verified(all) then return all end
    local units, seen, accepted = {}, {}, {}
    for _, G in ipairs(order) do
        if (G.bare or G.spaced) and not seen[G.unit] then seen[G.unit] = true; units[#units + 1] = G.unit end
    end
    for _, unit in ipairs(units) do
        if verified(render_calls(info, order, function(u) return u == unit end)) then accepted[unit] = true end
    end
    return verified(render_calls(info, order, function(u) return accepted[u] end)) or source
end

local function gap(prev, tk, colon, unary, spaced)
    if not prev then return '' end
    local a, b = prev.v, tk.v
    if tk.t == 'comment' then return '  ' end
    if prev.t == 'comment' then return ' ' end
    -- `.name` shorthand entries: a dot never follows these in other code
    if b == '.' and (a == '{' or a == ',' or a == ';') then return ' ' end
    if b == ',' or b == ';' or b == ')' or b == ']' or b == '.' or b == ':' or a == '.' then return '' end
    if a == ':' then return colon and ' ' or '' end
    if unary and not (a == '-' and b == '-') then return '' end
    if a == '(' or a == '[' or b == '[' then return '' end
    if b == '(' then
        if a == 'do' or a == 'function' then return '' end
        -- whether a `(` is spaced is syntax: a spaced one is the next argument
        -- group (syntax 2.4, rule 3), so keep the source's choice
        if prev.t == 'iden' or prev.t == 'string' or prev.t == 'number' or a == ')' or a == ']' or a == '}' then
            return spaced and ' ' or ''
        end
    end
    if a == '{' and b == '}' then return '' end
    if (a == '..' and prev.concat) or (b == '..' and tk.concat) then return ' ' end
    if b == '..' and (prev.t == 'iden' or a == ')') then return '' end
    if a == '..' and tk.t == 'iden' then return '' end
    return ' '
end

local function layout(info, options)
    local ts, events, deltas = info.tokens, {}, {}
    for i, range in ipairs(info.ranges) do
        local delta = 1
        if range.endall and range.link and range.child_same then
            if options.spine_style == 'all' then delta = 0
            elseif options.spine_style == 'pure' and range.pure then delta = 0 end
        end
        deltas[i] = delta
        if range[1] <= range[2] and delta > 0 then
            events[range[1]] = (events[range[1]] or 0) + delta
            events[range[2] + 1] = (events[range[2] + 1] or 0) - delta
        end
    end
    -- `endall` sits where the innermost `end` of the chain would: aligned with
    -- the last opener, not with the base of the whole chain.
    local extra = {}
    for i, range in ipairs(info.ranges) do
        if range.endall then
            local at = range[2] + 1
            local record = extra[at]
            if not record then record = { levels = 0 }; extra[at] = record end
            if deltas[i] == 1 then record.levels = record.levels + 1 end
        end
    end
    for _, record in pairs(extra) do record.levels = math.max(0, record.levels - 1) end
    local out, depth, prev, prev_index, pending = {}, 0, nil, nil, ''
    local column = 0
    local function emit(text)
        out[#out + 1] = text
        local tail = text:match('\n([^\n]*)$')
        column = tail and #tail or column + #text
    end
    for i, tk in ipairs(ts) do
        depth = depth + (events[i] or 0)
        if tk.t == 'space' then
            pending = pending .. tk.v
        else
            local _, lines = pending:gsub('\n', '')
            local wrap = false
            if prev_index and info.commas[prev_index] and lines == 0 then
                local last_on_line = tk
                for j = i + 1, info.commas[prev_index][2] do
                    if ts[j].line > tk.line or ts[j].v:find('\n', 1, true) then break end
                    last_on_line = ts[j]
                end
                local remaining = last_on_line.last - tk.first + 1
                wrap = column + remaining + 1 > options.column_width
            end
            if #out > 0 and (lines > 0 or wrap) then
                emit(string.rep('\n', math.min(math.max(lines, 1), 2)))
                local levels = math.max(depth, 0)
                if tk.t == 'iden' and tk.v == 'endall' then
                    levels = levels + (extra[i] and extra[i].levels or 0)
                end
                emit(string.rep(' ', levels * options.indent_width))
            elseif #out > 0 then
                emit(gap(prev, tk, prev_index and info.colons[prev_index], prev_index and info.unary[prev_index],
                    pending ~= ''))
            end
            emit(tk.v)
            prev, prev_index, pending = tk, i, ''
        end
    end
    if #out == 0 then return '' end
    return table.concat(out) .. '\n'
end

local format
function M.format(source, options, filename)
    local saved = environment
    environment = module_environment(filename)
    local ok, result = pcall(format, source, options, filename)
    environment = saved
    if not ok then error(result, 0) end
    return result
end

function format(source, options, filename)
    options = M.options(options)
    filename = filename or '<stdin>'
    local prefix = ''
    if source:sub(1, 2) == '#!' then
        prefix = source:match('^[^\n]*') .. '\n'
        source = source:sub(#prefix + 1)
    end
    local info = parse(source, filename)
    if options.type_style == 'inferred' then
        source = drop_inferred(source, info, filename)
        info = parse(source, filename)
    end
    if options.table_style == 'shorthand' then
        source = shorthand(source, info, filename)
        info = parse(source, filename)
    end
    if options.opening_style == 'anonymous' then
        source = drop_opening_names(source, info, filename)
        info = parse(source, filename)
    end
    local signature = fingerprint(info.ast)
    if options.call_style == 'minimal' then
        -- Remove call parentheses first: a sole `do` block argument carries no
        -- parentheses, and only then are the spine's closers adjacent.
        -- A successful removal can unlock another candidate or chain. Reparse
        -- and reach a fixed point so a second formatting is a no-op.
        for _ = 1, 8 do
            local previous = source
            source = spell(source, info, filename, signature, options.column_width)
            if source == previous then break end
            info = parse(source, filename)
        end
        source = fold_spines(source, info, filename, signature)
        info = parse(source, filename)
    end
    local result = layout(info, options)
    if fingerprint(parse(result, filename).ast) ~= signature then
        error(filename .. ': fmt: formatting would change the parsed program; source left unchanged', 0)
    end
    return prefix .. result
end

return M
