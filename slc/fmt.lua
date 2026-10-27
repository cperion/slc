-- SLC source formatter. Parsing never evaluates the source being formatted.
-- Keep the compiler's grammar authoritative; retain tokens for comments/spelling.
local lexer = require 'macro.lexer'
local syntax = require 'slc.syntax'
local M = {}
M.defaults = { indent_width = 4, column_width = 100, call_style = 'minimal', spine_style = 'pure',
               type_style = 'inferred', table_style = 'shorthand' }

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
    local ranges, calls, colons, unary, chains = {}, {}, {}, {}, {}
    local lambdas, body_ranges = {}, {}
    local typespans, locals = {}, {}
    local suffixed_from = p.suffixed_from
    function p:suffixed_from(...)
        local first = #calls + 1
        local result = suffixed_from(self, ...)
        if #calls >= first + 1 then
            local chain = {}
            for i = first, #calls do chain[#chain + 1] = calls[i] end
            chains[#chains + 1] = chain
        end
        return result
    end
    local block, args, typeexpr, funcbody, statement = p.block, p.args, p.typeexpr, p.funcbody, p.statement
    local subexpr = p.subexpr
    function p:subexpr(...)
        local tk = r:peek()
        if tk.t == '-' or tk.t == '#' then unary[tk.index] = true end
        return subexpr(self, ...)
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
    function p:args()
        local callee = last
        local start = r:peek().index
        local result = args(self)
        if ts[start].v == '(' and #result == 1 then
            local first = start + 1
            while ts[first] and ts[first].t == 'space' do first = first + 1 end
            -- Only the opening do must share the owning call's line. The body
            -- and closing end may span lines; their comments remain untouched.
            local lambda_block = result[1].k == 'lambda' and result[1].fn.body ~= nil
                and ts[first].v == 'do'
            local do_block = lambda_block and ts[callee] ~= nil
                and ts[first].line == lexer.sync(ts[callee].line, ts[callee].v)
            local arg = result[1]
            while arg.k == 'field' do arg = arg.obj end
            -- The outer LuaMacro layer and native-body parser differ for a
            -- bare argument containing another application in its postfix.
            -- Keep such host calls delimited rather than relying on native
            -- AST equivalence to justify a host-macro rewrite.
            local host_safe = arg.k == 'name' or arg.k == 'num' or arg.k == 'str'
                or arg.k == 'true' or arg.k == 'false' or arg.k == 'table' or do_block
            if (not lambda_block or do_block)
                and (native_depth > 0 or (host_safe and host_argument_depth == 0)) then
                calls[#calls + 1] = { start, last, do_block = do_block }
            end
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
        local nesting, j = 0, 1
        repeat
            local tk = r:peek(j)
            if tk.t == 'eof' then break end
            if tk.t == '(' then nesting = nesting + 1 end
            if tk.t == ')' then nesting = nesting - 1 end
            j = j + 1
        until nesting == 0
        local typed = r:peek(j).t == ':'
        if typed and native_depth == 0 and opts and opts.lambda then
            local copy = {}; for k, v in pairs(opts) do copy[k] = v end
            copy.lambda = false; opts = copy
        end
        if typed then native_depth = native_depth + 1 end
        local result = funcbody(self, name, at, opts)
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
    return { ast = ast, tokens = ts, ranges = ranges, calls = calls, colons = colons, commas = commas,
             unary = unary, chains = chains, lambdas = lambdas, typespans = typespans, locals = locals }
end

-- Source locations and application spelling do not affect the parsed program.
-- Only the parser's synthetic literal parentheses are erased, not expression
-- grouping (which can also affect Lua's multiple-result adjustment).
local function fingerprint(node)
    if type(node) ~= 'table' then
        local value = tostring(node)
        return type(node) .. ':' .. #value .. ':' .. value
    end
    if node.k == 'paren' and (node.e.k == 'num' or node.e.k == 'str') then return fingerprint(node.e) end
    local keys = {}
    for k in pairs(node) do
        if k ~= 'line' and k ~= 'end_line' and k ~= 'juxta' then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = { '{' }
    for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. '=' .. fingerprint(node[k]) .. ';' end
    out[#out + 1] = '}'
    return table.concat(out)
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

local function minimal(source, info, filename, signature)
    -- Same-length replacements keep token offsets valid even for nested calls.
    table.sort(info.calls, function(a, b) return a[1] > b[1] end)
    local function attempt(calls)
        local candidate = source
        for _, call in ipairs(calls) do
            local a, b = info.tokens[call[1]], info.tokens[call[2]]
            if not call.do_block then
                if a.line ~= b.line then return end
                for i = call[1] + 1, call[2] - 1 do
                    if info.tokens[i].t == 'comment' then return end
                end
            end
            candidate = candidate:sub(1, a.first - 1) .. ' ' .. candidate:sub(a.last + 1, b.first - 1)
                .. ' ' .. candidate:sub(b.last + 1)
        end
        local ok, result = pcall(parse, candidate, filename)
        if ok and fingerprint(result.ast) == signature then source = candidate end
    end
    -- f(a)(b) needs both pairs removed together; removing either alone can
    -- attach b to a or end the application chain. Never split f(a, b).
    for _, chain in ipairs(info.chains) do attempt(chain) end
    for _, call in ipairs(info.calls) do attempt { call } end
    return source
end

local function gap(prev, tk, colon, unary)
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
        if prev.t == 'iden' or a == ')' or a == ']' or a == '}' or a == 'do' or a == 'function' then return '' end
    end
    if a == '{' and b == '}' then return '' end
    if a == '...' or b == '...' then
        if a == '...' or tk.t == '...' and (prev.t == 'iden' or a == ')') then return '' end
    end
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
                emit(gap(prev, tk, prev_index and info.colons[prev_index], prev_index and info.unary[prev_index]))
            end
            emit(tk.v)
            prev, prev_index, pending = tk, i, ''
        end
    end
    if #out == 0 then return '' end
    return table.concat(out) .. '\n'
end

function M.format(source, options, filename)
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
    local signature = fingerprint(info.ast)
    if options.call_style == 'minimal' then
        -- Remove call parentheses first: a sole `do` block argument carries no
        -- parentheses, and only then are the spine's closers adjacent.
        source = minimal(source, info, filename, signature)
        info = parse(source, filename)
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
