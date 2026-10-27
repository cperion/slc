-- slc.syntax: the typed-body language, parsed and translated to staged Lua.
--
-- LuaMacro hands this module the token stream at a typed lambda (`do(...): T`),
-- a typed `function` statement, a `struct { ... }` or an `export`. Ordinary Lua
-- metamethods cannot stage comparisons, `and`/`or`, conditions, local
-- assignment or `return`, so typed bodies are parsed properly (a recursive
-- descent parser with Lua's precedence) and every such construct becomes a call
-- into slc.stage with delayed closures where evaluation must be deferred.
--
-- Application is juxtaposition, as in macro.let:
--   * a literal (number, string, true, false), a table constructor or a `do`
--     lambda after a callable expression is its argument, on any line;
--   * a name directly after a name (or after such an argument) is an argument
--     too, but only on the same line: a newline ends an application chain
--     before any token that can begin a statement.
-- An argument is a primary expression with its postfix chain (`.x`, `[i]`,
-- `:m(...)`, `(...)`); juxtaposition is left-associative, so `f a b` is f(a)(b).

local M = {}

local KEYWORDS = {}
for w in ([[and break do else elseif end false for function if in local nil not or
repeat return then true until while]]):gmatch '%S+' do KEYWORDS[w] = true end

local APPLY = '__let_apply'

-- the token reader -------------------------------------------------------------------------

local Reader = {}
Reader.__index = Reader

-- `get` returns raw LuaMacro tokens (type, value); `prefix` holds tokens already
-- read by the caller; `line_of` reports the source line of the last token got
function M.reader(get, prefix, line_of, filename, start_line)
    return setmetatable({
        get = get, prefix = prefix or {}, pi = 1, buf = {}, line_of = line_of,
        filename = filename or '?', last_line = start_line or 0, start_line = start_line or 0,
    }, Reader)
end

function Reader:raw()
    if self.rawback and #self.rawback > 0 then
        local tk = table.remove(self.rawback)
        return tk[1], tk[2], tk[3]
    end
    if self.pi <= #self.prefix then
        local tk = self.prefix[self.pi]
        self.pi = self.pi + 1
        return tk[1], tk[2], nil
    end
    local t, v = self.get()
    return t, v, self.line_of and self.line_of() or nil
end

-- read the next significant token from the source
function Reader:fetch()
    local ws = {}
    local nl = false
    while true do
        local t, v, line = self:raw()
        if t == nil then
            return { t = 'eof', v = '<eof>', ws = table.concat(ws), nl = nl, line = self.last_line }
        end
        if t == 'space' or t == 'comment' then
            ws[#ws + 1] = v
            if v:find '\n' then nl = true end
        elseif t == 'iden' and v == APPLY then
            -- macro.let's application mark: this parser sees application itself
        else
            if t == '.' then
                -- the LuaMacro lexer splits `..` and `...` into single dots
                local t2, v2, l2 = self:raw()
                if t2 == '.' then
                    local t3, v3, l3 = self:raw()
                    if t3 == '.' then t, v = '...', '...'
                    else
                        self.rawback = self.rawback or {}
                        table.insert(self.rawback, { t3, v3, l3 })
                        t, v = '..', '..'
                    end
                elseif t2 ~= nil then
                    self.rawback = self.rawback or {}
                    table.insert(self.rawback, { t2, v2, l2 })
                end
            end
            local tk = { t = t, v = v, ws = table.concat(ws), nl = nl, line = line or self.last_line }
            if line then self.last_line = line end
            if t == 'iden' and (v == 'do' or v == '__typed_function') then
                tk.t = 'keyword'
                tk.v = v == 'do' and 'do' or 'function'
                tk.raw_v = v
            end
            if t == 'keyword' or (tk.t == 'keyword') then tk.kw = tk.v end
            return tk
        end
    end
end

function Reader:peek(n)
    n = n or 1
    while #self.buf < n do self.buf[#self.buf + 1] = self:fetch() end
    return self.buf[n]
end

function Reader:next()
    local tk = self:peek(1)
    table.remove(self.buf, 1)
    self.cur_line = tk.line
    return tk
end

function Reader:error(msg, tk)
    tk = tk or self:peek(1)
    error(('%s:%s: %s'):format(self.filename, tostring(tk.line or self.last_line), msg), 0)
end

local function show(tk)
    if tk.t == 'eof' then return 'end of input' end
    return "'" .. tostring(tk.v) .. "'"
end

function Reader:is(v)
    local tk = self:peek(1)
    if tk.kw then return tk.kw == v end
    return tk.t == v and tk.t ~= 'iden' and tk.t ~= 'string' and tk.t ~= 'number'
end

function Reader:accept(v)
    if self:is(v) then return self:next() end
end

function Reader:expect(v, what)
    if not self:is(v) then
        self:error(("expected '%s'%s, got %s"):format(v, what and (' ' .. what) or '', show(self:peek(1))))
    end
    return self:next()
end

function Reader:name(what)
    local tk = self:peek(1)
    if tk.t ~= 'iden' then
        self:error(('expected a name%s, got %s'):format(what and (' ' .. what) or '', show(tk)))
    end
    return self:next()
end

-- tokens read ahead but not consumed go back to LuaMacro unchanged
function Reader:leftovers()
    local out = {}
    for _, tk in ipairs(self.buf) do
        if tk.ws ~= '' then out[#out + 1] = { 'space', tk.ws } end
        if tk.t ~= 'eof' then
            local t = tk.t
            if tk.raw_v then t, tk.v = 'iden', tk.raw_v end
            if t == '..' or t == '...' then
                for _ = 1, #t do out[#out + 1] = { '.', '.' } end
            else
                out[#out + 1] = { t, tk.v }
            end
        end
    end
    self.buf = {}
    return out
end

-- the parser -------------------------------------------------------------------------------

local P = {}
P.__index = P

local BINARY = {
    ['or'] = { 1, 1 }, ['and'] = { 2, 2 },
    ['<'] = { 3, 3 }, ['>'] = { 3, 3 }, ['<='] = { 3, 3 }, ['>='] = { 3, 3 },
    ['~='] = { 3, 3 }, ['=='] = { 3, 3 },
    ['..'] = { 5, 4 },
    ['+'] = { 6, 6 }, ['-'] = { 6, 6 },
    ['*'] = { 7, 7 }, ['/'] = { 7, 7 }, ['%'] = { 7, 7 },
    ['^'] = { 10, 9 },
}
local UNARY_PRIORITY = 8

local function binop_of(tk)
    if tk.kw == 'and' or tk.kw == 'or' then return tk.kw end
    if tk.t ~= 'iden' and tk.t ~= 'string' and tk.t ~= 'number' and BINARY[tk.t] then return tk.t end
end

function M.parser(reader)
    return setmetatable({ r = reader, kinds = {} }, P)
end

-- a loop header: its `do` ends it, unless inside brackets
function P:header(f)
    local saved = self.in_header
    self.in_header = true
    local a, b, c = f()
    self.in_header = saved
    return a, b, c
end

function P:bracketed(f)
    local saved = self.in_header
    self.in_header = false
    local a, b, c = f()
    self.in_header = saved
    return a, b, c
end

-- block := { stat [';'] } [return]
local BLOCK_END = { ['end'] = true, ['else'] = true, ['elseif'] = true, ['until'] = true }
local function is_endall(tk) return tk.t == 'iden' and tk.v == 'endall' end

function P:block(kind)
    self.kinds[#self.kinds + 1] = kind or 'other'
    local stats = self:block_items()
    self.kinds[#self.kinds] = nil
    return stats
end

function P:block_items()
    local r = self.r
    local stats = {}
    while true do
        local tk = r:peek(1)
        if tk.t == 'eof' or (tk.kw and BLOCK_END[tk.kw]) or is_endall(tk) then break end
        if tk.kw == 'return' then
            stats[#stats + 1] = self:retstat()
            break
        end
        local s = self:statement()
        if s then stats[#stats + 1] = s end
    end
    return stats
end

function P:retstat()
    local r = self.r
    local tk = r:next()
    local exprs = {}
    local nt = r:peek(1)
    if not (nt.t == 'eof' or (nt.kw and BLOCK_END[nt.kw]) or nt.t == ';' or is_endall(nt)) then
        exprs = self:exprlist()
    end
    r:accept(';')
    return { k = 'return', exprs = exprs, line = tk.line }
end

function P:statement()
    local r = self.r
    local tk = r:peek(1)
    local line = tk.line
    if tk.t == ';' then r:next() return nil end
    local kw = tk.kw
    if kw == 'local' then
        r:next()
        if r:is('function') then
            local ftk = r:next()
            local name = r:name('after local function').v
            local fn = self:funcbody(name, ftk)
            return { k = 'localfunction', name = name, fn = fn, line = line }
        end
        local names = {}
        local first = r:name('in local declaration')
        if r:is('...') then
            -- `local ctx...` opens an existing binding; `local ctx... = e` binds, then opens
            r:next()
            local init
            if r:accept('=') then init = self:expr(first.v) end
            return { k = 'open', name = first.v, init = init, line = line }
        end
        local n = first
        repeat
            if n == nil then n = r:name('in local declaration') end
            local ty
            if r:accept(':') then ty = self:typeexpr() end
            names[#names + 1] = { name = n.v, type = ty }
            n = nil
        until not r:accept(',')
        local exprs = {}
        if r:accept('=') then
            exprs = self:exprlist(names[1] and names[1].name)
        end
        return { k = 'local', names = names, exprs = exprs, line = line }
    elseif kw == 'if' then
        r:next()
        local clauses = {}
        local cond = self:expr()
        r:expect('then', 'after if condition')
        clauses[1] = { cond = cond, body = self:block() }
        local els
        while true do
            if r:accept('elseif') then
                local c = self:expr()
                r:expect('then', 'after elseif condition')
                clauses[#clauses + 1] = { cond = c, body = self:block() }
            elseif r:accept('else') then
                els = self:block()
                r:expect('end', 'to close if')
                break
            else
                r:expect('end', 'to close if')
                break
            end
        end
        return { k = 'if', clauses = clauses, els = els, line = line }
    elseif kw == 'while' then
        r:next()
        local cond = self:header(function() return self:expr() end)
        r:expect('do', 'after while condition')
        local body = self:block()
        r:expect('end', 'to close while')
        return { k = 'while', cond = cond, body = body, line = line }
    elseif kw == 'for' then
        r:next()
        local n1 = r:name('after for')
        if r:is(':') or r:is('=') then
            local ty
            if r:accept(':') then ty = self:typeexpr() end
            r:expect('=', 'in numeric for')
            local lo, hi, step = self:header(function()
                local lo = self:expr()
                r:expect(',', 'in numeric for')
                local hi = self:expr()
                local step
                if r:accept(',') then step = self:expr() end
                return lo, hi, step
            end)
            r:expect('do', 'after for range')
            local body = self:block()
            r:expect('end', 'to close for')
            return { k = 'numfor', var = n1.v, type = ty, lo = lo, hi = hi, step = step,
                     body = body, line = line }
        end
        local names = { n1.v }
        while r:accept(',') do names[#names + 1] = r:name('in for').v end
        r:expect('in', 'in generic for')
        local exprs = self:header(function() return self:exprlist() end)
        r:expect('do', 'after for header')
        local body = self:block()
        r:expect('end', 'to close for')
        return { k = 'genfor', names = names, exprs = exprs, body = body, line = line }
    elseif kw == 'repeat' then
        r:next()
        local body = self:block()
        r:expect('until', 'to close repeat')
        local cond = self:expr()
        return { k = 'repeat', body = body, cond = cond, line = line }
    elseif kw == 'break' then
        r:next()
        return { k = 'break', line = line }
    elseif kw == 'do' then
        r:next()
        local body = self:block()
        r:expect('end', 'to close do')
        return { k = 'do', body = body, line = line }
    elseif kw == 'function' then
        local ftk = r:next()
        local path = { r:name('after function').v }
        local method
        while true do
            if r:accept('.') then path[#path + 1] = r:name('in function name').v
            elseif r:accept(':') then method = r:name('in method name').v break
            else break end
        end
        local fn = self:funcbody(method or path[#path], ftk)
        return { k = 'function', path = path, method = method, fn = fn, line = line }
    elseif kw == 'return' then
        return self:retstat()
    end
    if tk.t == 'iden' and tk.v == 'continue' then
        local nt = r:peek(2)
        if not (nt.t == '(' or nt.t == '=' or nt.t == '.' or nt.t == ':' or nt.t == '['
            or nt.t == 'string' or nt.t == '{' or nt.t == ',') then
            r:next()
            return { k = 'continue', line = line }
        end
    end
    if tk.t == 'iden' and tk.v == 'export' then
        r:next()
        local n = r:name('after export')
        return { k = 'export', name = n.v, line = line }
    end
    -- expression statement: call or assignment
    local e = self:suffixed()
    if r:is('=') or r:is(',') then
        local targets = { e }
        while r:accept(',') do targets[#targets + 1] = self:suffixed() end
        r:expect('=', 'in assignment')
        local exprs = self:exprlist()
        for _, t in ipairs(targets) do
            if t.k ~= 'name' and t.k ~= 'index' and t.k ~= 'field' then
                r:error('cannot assign to this expression')
            end
        end
        return { k = 'assign', targets = targets, exprs = exprs, line = line }
    end
    if e.k ~= 'call' and e.k ~= 'method' then
        r:error('syntax error: an expression statement must be a call or an assignment', tk)
    end
    return { k = 'callstat', e = e, line = line }
end

-- parameters and bodies --------------------------------------------------------------------

-- `( params ) [: result] (= expr | block end)` after `function` or `do`
function P:funcbody(name, at, opts)
    local r = self.r
    opts = opts or {}
    local params, vararg, rest = {}, false, nil
    if not opts.params_open then r:expect('(', 'to open parameters') end
    if not r:is(')') then
        repeat
            if rest then r:error('rest-position: the rest requirement ...' .. rest .. ' must be last', at) end
            if r:is('...') then
                local dots = r:next()
                local nt = r:peek(1)
                if nt.t == 'iden' and not nt.kw then
                    -- `...args`: the rest requirement
                    rest = r:next().v
                else
                    -- `...` or `...: T`: one unnamed home, opened
                    local ty
                    if r:accept(':') then ty = self:typeexpr() end
                    params[#params + 1] = { name = '__home', type = ty, opened = true, unnamed = true,
                                            line = dots.line }
                end
            else
                local n = r:name('in parameters')
                local opened = false
                if r:is('...') then r:next(); opened = true end      -- `ctx...`
                local ty
                if r:accept(':') then ty = self:typeexpr() end
                params[#params + 1] = { name = n.v, type = ty, line = n.line, opened = opened }
            end
        until not r:accept(',')
    end
    r:expect(')', 'to close parameters')
    local nopen = 0
    for _, p in ipairs(params) do if p.opened then nopen = nopen + 1 end end
    if nopen > 1 then r:error('one parameter may be opened', at) end
    local result
    if opts.result_colon_read or r:accept(':') then
        result = self:typeexpr()
    end
    local typed = result ~= nil
    for _, p in ipairs(params) do
        if p.type and not typed then
            r:error(("parameter '%s' is typed, but %s declares no result type; "
                .. "native words declare it: (...): T"):format(p.unnamed and '...' or p.name, name or 'the lambda'), at)
        end
    end
    local fn = { params = params, vararg = vararg, rest = rest, result = result, name = name,
                 line = at and at.line }
    if opts.allow_expr ~= false and r:accept('=') then
        fn.expr = self:expr()
        fn.end_line = r.last_line
        return fn
    end
    if opts.expr_only then r:error("expected '=' after the handler's parameters", at) end
    fn.body = self:block(opts.lambda and 'lambda' or 'other')
    local e
    if opts.lambda then e = self:close_lambda(name)
    else e = r:expect('end', 'to close ' .. (name and ("'" .. name .. "'") or 'the body')) end
    fn.end_line = e.line
    return fn
end

-- a type annotation is an ordinary expression evaluated at compile time; it
-- ends where an expression must end (`,` `)` `=` a keyword, or a new line
-- before a name)
function P:typeexpr()
    return self:expr(nil, true)
end

-- expressions ------------------------------------------------------------------------------

-- `...e` in an ordered supply (arguments, returns, binding initializers)
function P:item(hint)
    local r = self.r
    if r:is('...') then
        local nt = r:peek(2)
        if nt.t == ',' or nt.t == ')' or nt.t == 'eof' or nt.t == ']' or nt.t == '}'
            or (nt.kw and (BLOCK_END[nt.kw] or nt.kw == 'then' or nt.kw == 'do')) then
            return self:expr(hint)                     -- `...` alone: the home
        end
        local d = r:next()
        return { k = 'spread', e = self:expr(), line = d.line }
    end
    return self:expr(hint)
end

function P:exprlist(hint)
    local list = { self:item(hint) }
    while self.r:accept(',') do list[#list + 1] = self:item() end
    return list
end

function P:expr(hint, in_type)
    return self:subexpr(0, hint, in_type)
end

function P:subexpr(limit, hint, in_type)
    local r = self.r
    local tk = r:peek(1)
    local left
    if tk.kw == 'not' or tk.t == '-' or tk.t == '#' then
        r:next()
        local op = tk.kw or tk.t
        local a = self:subexpr(UNARY_PRIORITY, nil, in_type)
        left = { k = 'unop', op = op, a = a, line = tk.line }
    else
        left = self:simple(hint, in_type)
    end
    while true do
        local nt = r:peek(1)
        local op = binop_of(nt)
        if not op or BINARY[op][1] <= limit then break end
        r:next()
        local right = self:subexpr(BINARY[op][2], nil, in_type)
        left = { k = 'binop', op = op, a = left, b = right, line = nt.line }
    end
    return left
end

function P:simple(hint, in_type)
    local r = self.r
    local tk = r:peek(1)
    if tk.t == 'number' then r:next() return self:postfix_literal({ k = 'num', text = tk.v, line = tk.line }) end
    if tk.t == 'string' then r:next() return self:postfix_literal({ k = 'str', text = tk.v, line = tk.line }) end
    if tk.kw == 'nil' then r:next() return { k = 'nil' } end
    if tk.kw == 'true' then r:next() return { k = 'true' } end
    if tk.kw == 'false' then r:next() return { k = 'false' } end
    if tk.t == '...' then r:next() return { k = 'home', line = tk.line } end
    if tk.t == '{' then return self:table() end
    if tk.kw == 'function' then
        local ftk = r:next()
        return { k = 'lambda', fn = self:funcbody(hint, ftk, { allow_expr = false }), line = tk.line }
    end
    if tk.kw == 'do' then return self:lambda(hint) end
    return self:suffixed(hint, in_type)
end

-- a literal followed by a postfix chain: ("x"):rep(3)
function P:postfix_literal(e)
    local r = self.r
    local nt = r:peek(1)
    if nt.t == '.' or nt.t == ':' or nt.t == '[' then
        return self:suffixed_from({ k = 'paren', e = e }, nil, true)
    end
    return e
end

-- `do` lambdas: `do(params) = expr`, `do(params) ... end`, `do ... end`
-- `endall` closes a spine of trailing block lambdas: the innermost one, and each
-- enclosing block lambda whose body ends there; it stops at any other block
function P:close_lambda(name)
    local r = self.r
    local tk = r:peek(1)
    if is_endall(tk) then
        -- consume it unless the enclosing block is itself a lambda block
        if self.kinds[#self.kinds] ~= 'lambda' then r:next() end
        return tk
    end
    return r:expect('end', 'to close ' .. (name and ("'" .. name .. "'") or 'the lambda'))
end

function P:lambda(hint)
    local r = self.r
    local dtk = r:next()
    if r:is('(') then
        return { k = 'lambda', fn = self:funcbody(hint, dtk, { lambda = true }), line = dtk.line }
    end
    local body = self:block('lambda')
    local e = self:close_lambda()
    return { k = 'lambda', fn = { params = {}, body = body, name = hint, line = dtk.line, end_line = e.line },
             line = dtk.line }
end

-- after `name (`: does a balanced parameter list end in `=` or `:`?
function P:handler_ahead()
    local r = self.r
    local depth, i = 0, 2
    while true do
        local tk = r:peek(i)
        if tk.t == 'eof' then return false end
        if tk.t == '(' then depth = depth + 1
        elseif tk.t == ')' then
            depth = depth - 1
            if depth == 0 then
                local nt = r:peek(i + 1)
                return nt.t == '=' or nt.t == ':'
            end
        end
        i = i + 1
    end
end

function P:table()
    return self:bracketed(function() return self:table_body() end)
end

function P:table_body()
    local r = self.r
    local open = r:expect('{')
    local items = {}
    while not r:is('}') do
        local tk = r:peek(1)
        if tk.t == '...' then
            r:next()
            items[#items + 1] = { kind = 'spread', e = self:expr() }
        elseif tk.t == '[' then
            r:next()
            local key = self:expr()
            r:expect(']')
            r:expect('=')
            items[#items + 1] = { kind = 'keyed', key = key, e = self:expr() }
        elseif tk.t == '.' and r:peek(2).t == 'iden' and not r:peek(2).kw
            and (r:peek(3).t == ',' or r:peek(3).t == ';' or r:peek(3).t == '}') then
            -- `.name` is `name = name`
            r:next()
            local n = r:next()
            items[#items + 1] = { kind = 'named', name = n.v, e = { k = 'name', name = n.v, line = n.line } }
        elseif tk.t == 'iden' and r:peek(2).t == '=' then
            local n = r:next()
            r:next()
            items[#items + 1] = { kind = 'named', name = n.v, e = self:expr(n.v) }
        elseif tk.t == 'iden' and r:peek(2).t == '(' and self:handler_ahead() then
            -- `name(params) = body` is `name = do(params) = body`
            local n = r:next()
            local fn = self:funcbody(n.v, n, { expr_only = true })
            items[#items + 1] = { kind = 'named', name = n.v, e = { k = 'lambda', fn = fn, line = n.line } }
        else
            items[#items + 1] = { kind = 'pos', e = self:expr() }
        end
        if not (r:accept(',') or r:accept(';')) then break end
    end
    r:expect('}', 'to close the table')
    return { k = 'table', items = items, line = open.line }
end

-- `struct { name: Type, ... }`
-- `struct { name: Type, ... }` and `oneof { name: Type, ... }`
function P:struct(hint)
    local r = self.r
    local s = r:next()
    local kind = s.v
    local what = kind == 'oneof' and 'alternative' or 'field'
    r:expect('{', 'after ' .. kind)
    local fields = {}
    while not r:is('}') do
        local n = r:name('as a ' .. what)
        r:expect(':', ("after %s '%s' (%ss are declared name: Type)"):format(what, n.v, what))
        local ty = self:typeexpr()
        fields[#fields + 1] = { name = n.v, type = ty }
        if not (r:accept(',') or r:accept(';')) then break end
    end
    r:expect('}', 'to close the ' .. kind)
    return { k = 'struct', sum = kind == 'oneof', fields = fields, name = hint, line = s.line }
end

function P:primary(hint, in_type)
    local r = self.r
    local tk = r:peek(1)
    if tk.t == 'iden' then
        if (tk.v == 'struct' or tk.v == 'oneof') and r:peek(2).t == '{' then return self:struct(hint), 'struct' end
        r:next()
        return { k = 'name', name = tk.v, line = tk.line }, 'name'
    end
    if tk.t == '(' then
        r:next()
        local e = self:bracketed(function() return self:expr() end)
        r:expect(')', 'to close the parenthesis')
        return { k = 'paren', e = e }, 'paren'
    end
    r:error('unexpected ' .. show(tk))
end

function P:suffixed(hint, in_type)
    local e, kind = self:primary(hint, in_type)
    return self:suffixed_from(e, kind, false, in_type)
end

-- can the next token start a juxtaposed argument after an expression that
-- ended with `last` ('name', 'call', 'index', ...)?
function P:starts_argument(last)
    local tk = self.r:peek(1)
    if tk.t == 'number' then return true end
    if tk.kw == 'true' or tk.kw == 'false' then return true end
    if tk.kw == 'do' then return not self.in_header end
    if tk.t == 'iden' and not KEYWORDS[tk.v] then
        -- a name argument: only directly after a name, and on the same line
        return (last == 'name' or last == 'arg') and not tk.nl
    end
    return false
end

-- an argument: a primary with its postfix chain, without further juxtaposition
function P:argument()
    local r = self.r
    local tk = r:peek(1)
    if tk.kw == 'do' then return self:lambda() end
    if tk.t == 'number' then
        r:next()
        return self:suffixed_from({ k = 'paren', e = { k = 'num', text = tk.v } }, 'literal', true)
    end
    if tk.kw == 'true' or tk.kw == 'false' then
        r:next()
        return self:suffixed_from({ k = tk.kw }, 'literal', true)
    end
    local e = self:primary()
    return self:postfix_only(e)
end

function P:postfix_only(e)
    return self:suffixed_from(e, 'name', true)
end

function P:args()
    local r = self.r
    local tk = r:peek(1)
    if tk.t == 'string' then r:next() return { { k = 'str', text = tk.v } } end
    if tk.t == '{' then return { self:table() } end
    r:expect('(')
    local args = {}
    if not r:is(')') then args = self:bracketed(function() return self:exprlist() end) end
    r:expect(')', 'to close the arguments')
    return args
end

function P:suffixed_from(e, last, no_juxta, in_type)
    local r = self.r
    while true do
        local tk = r:peek(1)
        if tk.t == '.' then
            r:next()
            local n = r:name('after .')
            e = { k = 'field', obj = e, name = n.v, line = n.line }
            last = 'name'
        elseif tk.t == '[' then
            r:next()
            local key = self:bracketed(function() return self:expr() end)
            r:expect(']')
            e = { k = 'index', obj = e, key = key }
            last = 'index'
        elseif tk.t == ':' then
            -- `a:m args`; in a type annotation a ':' cannot be a method call
            if in_type then break end
            local nt = r:peek(2)
            if nt.t ~= 'iden' then break end
            r:next(); r:next()
            local args
            local at = r:peek(1)
            if at.t == '(' or at.t == 'string' or at.t == '{' then
                args = self:args()
            elseif self:starts_argument('name') then
                args = { self:argument() }
            else
                r:error(("method call '%s' needs arguments"):format(nt.v))
            end
            e = { k = 'method', obj = e, name = nt.v, args = args, line = nt.line }
            last = 'call'
        elseif tk.t == '(' and tk.nl then
            -- `(` can begin a statement: a newline before it ends the expression
            break
        elseif tk.t == '(' or ((tk.t == 'string' or tk.t == '{') and last ~= 'literal') then
            -- a literal argument's chain stops at a table or string: `f 21 {}` is f(21)({})
            e = { k = 'call', fn = e, args = self:args(), line = tk.line }
            last = 'call'
        elseif not no_juxta and self:starts_argument(last) then
            e = { k = 'call', fn = e, args = { self:argument() }, line = tk.line, juxta = true }
            last = 'arg'
        else
            break
        end
    end
    return e
end

-- code generation ---------------------------------------------------------------------------

local G = {}
G.__index = G

-- body kinds: 'word' (native semantics: staged control flow and return),
-- 'host' (a Lua function inside a typed body: plain control flow, staged
-- operators)
local function new_body(kind, parent)
    return { kind = kind, scopes = { {} }, region = 0, loops = {}, parent = parent }
end

function M.codegen(filename, start_line)
    return setmetatable({ out = {}, line = start_line or 0, filename = filename,
                          body = nil }, G)
end

function G:emit(s) self.out[#self.out + 1] = s end

-- keep generated code on the source lines it came from
function G:at(line)
    if line and line > self.line then
        self:emit(('\n'):rep(line - self.line))
        self.line = line
    end
end

function G:err(msg, line)
    error(('%s:%s: %s'):format(self.filename, tostring(line or self.line), msg), 0)
end

function G:push_scope() local b = self.body; b.scopes[#b.scopes + 1] = {} end
function G:pop_scope() local b = self.body; b.scopes[#b.scopes] = nil end

function G:declare(name, info)
    local b = self.body
    info.region = b.region
    b.scopes[#b.scopes][name] = info
end

function G:lookup(name)
    local b = self.body
    if not b then return nil end
    for i = #b.scopes, 1, -1 do
        local v = b.scopes[i][name]
        if v then return v, b end
    end
    local p = b.parent
    while p do
        for i = #p.scopes, 1, -1 do
            local v = p.scopes[i][name]
            if v then return v, p end
        end
        p = p.parent
    end
    return nil
end

local function str(s) return ('%q'):format(s) end

-- expressions --------------------------------------------------------------------------------

local CMP = { ['=='] = 'eq', ['~='] = 'ne', ['<'] = 'lt', ['<='] = 'le', ['>'] = 'gt', ['>='] = 'ge' }

function G:expr(e)
    local k = e.k
    if k == 'name' then
        if e.name == '__S' or e.name == '__ENV' then self:err("'" .. e.name .. "' is reserved", e.line) end
        if not self:lookup(e.name) and #self:opens() > 0 then
            -- a free name inside an opened region: an introduced name, or the binding outside
            return ('__S.oname(%s, %s, function() return %s end)'):format(self:open_list(), str(e.name), e.name)
        end
        local v = self:lookup(e.name)
        if v and v.loop_slot then
            return '__S.inferred_state(' .. v.loop_slot .. ', ' .. e.name .. ')'
        end
        return e.name
    elseif k == 'home' then
        local v = self:lookup('__home')
        if not v then self:err('context-required: `...` reads an unnamed opened home, and there is none here', e.line) end
        return '__home'
    elseif k == 'spread' then
        self:err('spread-context: `...e` belongs in an argument, return or initializer list', e.line)
    elseif k == 'num' then return e.text
    elseif k == 'str' then return e.text
    elseif k == 'nil' or k == 'true' or k == 'false' then return k
    elseif k == 'vararg' then return '...'
    elseif k == 'paren' then return '(' .. self:expr(e.e) .. ')'
    elseif k == 'field' then
        -- through __S.dot: a native value's fields never meet the evaluator's own keys
        return '__S.dot(' .. self:expr(e.obj) .. ', ' .. str(e.name) .. ')'
    elseif k == 'index' then return '__S.index(' .. self:expr(e.obj) .. ', ' .. self:expr(e.key) .. ')'
    elseif k == 'call' and (e.fn.k == 'call' or e.fn.k == 'method') then
        -- a saturating chain: f(a)(b) do ... end accumulates arguments until f is saturated
        local groups = {}
        local node = e
        while node.k == 'call' and (node.fn.k == 'call' or node.fn.k == 'method') do
            table.insert(groups, 1, '__S.args(' .. self:list(node.args) .. ')')
            node = node.fn
        end
        if node.k == 'method' then
            return ('__S.mchain(%s, %s, __S.args(%s), %s)'):format(self:prefix(node.obj), str(node.name),
                self:list(node.args), table.concat(groups, ', '))
        end
        if node.fn.k == 'name' and not self:lookup(node.fn.name) and #self:opens() > 0 then
            -- a chain headed by a free name in an opened region
            return ('__S.ochain(%s, %s, function() return %s end, __S.args(%s), %s)'):format(self:open_list(),
                str(node.fn.name), node.fn.name, self:list(node.args), table.concat(groups, ', '))
        end
        return ('__S.chain(%s, __S.args(%s), %s)'):format(self:prefix(node.fn), self:list(node.args),
            table.concat(groups, ', '))
    elseif k == 'call' then
        if e.fn.k == 'name' and not self:lookup(e.fn.name) and #self:opens() > 0 then
            -- a bare call inside an opened region: the receiver's member wins
            local args = self:list(e.args)
            return ('__S.ocall(%s, %s, function() return %s end%s)'):format(self:open_list(),
                str(e.fn.name), e.fn.name, args ~= '' and (', ' .. args) or '')
        end
        return self:prefix(e.fn) .. '(' .. self:list(e.args) .. ')'
    elseif k == 'method' then
        local args = self:list(e.args)
        return '__S.mcall(' .. self:expr(e.obj) .. ', ' .. str(e.name) .. (args ~= '' and (', ' .. args) or '') .. ')'
    elseif k == 'table' then
        local spread = false
        for _, it in ipairs(e.items) do if it.kind == 'spread' then spread = true end end
        if spread then
            -- keyed spread: T { ...p, x = 5 }
            local parts = {}
            for _, it in ipairs(e.items) do
                if it.kind == 'spread' then
                    parts[#parts + 1] = "{ 'spread', " .. self:expr(it.e) .. ' }'
                elseif it.kind == 'named' then
                    parts[#parts + 1] = "{ 'field', " .. str(it.name) .. ', ' .. self:expr(it.e) .. ' }'
                else
                    self:err('spread-context: a keyed spread admits only `name = value` items and spreads', e.line)
                end
            end
            return '__S.keyed({ ' .. table.concat(parts, ', ') .. ' })'
        end
        local parts, keys = {}, {}
        for _, it in ipairs(e.items) do
            if it.kind == 'named' then
                if keys[it.name] then self:err(("duplicate key '%s'"):format(it.name), e.line) end
                keys[it.name] = true
            end
        end
        for _, it in ipairs(e.items) do
            if it.kind == 'pos' then parts[#parts + 1] = self:expr(it.e)
            elseif it.kind == 'named' then parts[#parts + 1] = it.name .. ' = ' .. self:expr(it.e)
            else parts[#parts + 1] = '[' .. self:expr(it.key) .. '] = ' .. self:expr(it.e) end
        end
        return '{ ' .. table.concat(parts, ', ') .. ' }'
    elseif k == 'binop' then
        local op = e.op
        if CMP[op] then
            return '__S.' .. CMP[op] .. '(' .. self:expr(e.a) .. ', ' .. self:expr(e.b) .. ')'
        elseif op == 'and' or op == 'or' then
            local a = self:expr(e.a)
            self.body.region = self.body.region + 1
            local b = self:expr(e.b)
            self.body.region = self.body.region - 1
            return '__S.' .. op .. '_(' .. a .. ', function() return ' .. b .. ' end)'
        end
        return '(' .. self:expr(e.a) .. ' ' .. op .. ' ' .. self:expr(e.b) .. ')'
    elseif k == 'unop' then
        if e.op == 'not' then return '__S.not_(' .. self:expr(e.a) .. ')' end
        if e.op == '#' then return '__S.len(' .. self:expr(e.a) .. ')' end
        return '(- ' .. self:expr(e.a) .. ')'
    elseif k == 'lambda' then
        return self:lambda(e.fn)
    elseif k == 'struct' then
        return self:struct(e)
    end
    self:err('internal: unknown expression ' .. tostring(k))
end

-- an expression used as the prefix of a call or index needs brackets unless it
-- is already a name, call or index
function G:prefix(e)
    local s = self:expr(e)
    if e.k == 'name' or e.k == 'field' or e.k == 'index' or e.k == 'call' or e.k == 'method'
        or e.k == 'paren' then
        return s
    end
    return '(' .. s .. ')'
end

function G:list(es)
    local parts, spread = {}, false
    for i, e in ipairs(es) do
        if e.k == 'spread' then
            spread = true
            parts[i] = '__S.sp(' .. self:expr(e.e) .. ')'
        else
            parts[i] = self:expr(e)
        end
    end
    if spread then return '__S.expand(' .. table.concat(parts, ', ') .. ')' end
    return table.concat(parts, ', ')
end

local function has_spread(es)
    for _, e in ipairs(es) do if e.k == 'spread' then return true end end
    return false
end

function G:struct(e)
    local parts = {}
    for _, f in ipairs(e.fields) do
        parts[#parts + 1] = '{ ' .. str(f.name) .. ', ' .. self:expr(f.type) .. ' }'
    end
    return (e.sum and '__S.oneof(' or '__S.struct(') .. str(e.name or (e.sum and 'Sum' or 'S')) .. ', { '
        .. table.concat(parts, ', ') .. ' })'
end

-- a lambda: a native word when it declares a result type, else a host function
function G:lambda(fn, method_of)
    local names = {}
    for i, p in ipairs(fn.params) do names[i] = p.name end
    if fn.rest then names[#names + 1] = '...' end
    local loc = str(self.filename .. ':' .. tostring(fn.line or self.line))
    if fn.result then
        local ps = {}
        for i, p in ipairs(fn.params) do
            if p.type then
                ps[i] = '{ ' .. str(p.name) .. ', ' .. self:expr(p.type) .. ' }'
            else
                ps[i] = '{ ' .. str(p.name) .. ' }'          -- a compile-time parameter
            end
        end
        local spec_head = 'name = ' .. str(fn.name or 'word') .. ', loc = ' .. loc
            .. ', params = { ' .. table.concat(ps, ', ') .. ' }, result = ' .. self:expr(fn.result)
            .. (fn.rest and (', rest = ' .. str(fn.rest)) or '')
            .. ', body = function('
        local fparams = {}
        if method_of then fparams[1] = 'self' end
        for i, p in ipairs(fn.params) do fparams[#fparams + 1] = p.name end
        if fn.rest then fparams[#fparams + 1] = fn.rest end   -- the pack, built by S.word
        local head = spec_head .. table.concat(fparams, ', ') .. ') '
        local body = self:function_body(fn, 'word', method_of)
        local spec = '{ ' .. head .. body .. ' end }'
        if method_of then return spec end
        return '__S.word' .. spec
    end
    -- an untyped lambda is a callback
    local body = self:function_body(fn, 'callback')
    if fn.rest then body = 'local ' .. fn.rest .. ' = __S.pack({ ... }) ' .. body end
    return '__S.callback(' .. str(fn.name or 'callback') .. ', ' .. loc .. ', function('
        .. table.concat(names, ', ') .. ') ' .. body .. ' end)'
end

function G:function_body(fn, kind, method_of)
    local saved = self.body
    self.body = new_body(kind, saved)
    if method_of then self:declare('self', { immutable = true, param = true }) end
    for _, p in ipairs(fn.params) do
        if not p.unnamed then self:no_shadow_check(p.name) end
        self:declare(p.name, { immutable = kind == 'word', param = true, context = p.opened })
    end
    if fn.rest then self:declare(fn.rest, { immutable = true, pack = true }) end
    local o = self.out
    self.out = {}
    for _, p in ipairs(fn.params) do
        if p.opened then self:open_context(p.name, p.unnamed and '...' or p.name) end
    end
    if fn.expr then
        if kind ~= 'host' then
            self:emit(' __S.ret(' .. self:expr(fn.expr) .. ')')
        else
            self:emit(' return ' .. self:expr(fn.expr))
        end
    else
        self:block(fn.body)
        if fn.end_line then self:at(fn.end_line) end
    end
    local parts = table.concat(self.out)
    self.out = o
    self.body = saved
    return parts
end

-- opening ----------------------------------------------------------------------------------------

-- the opened contexts visible here, innermost first (Lua expressions)
function G:opens()
    local out = {}
    local b = self.body
    while b do
        for i = #b.scopes, 1, -1 do
            local sc = b.scopes[i]
            if sc.__opens then
                for k = #sc.__opens, 1, -1 do out[#out + 1] = sc.__opens[k] end
            end
        end
        b = b.parent
    end
    return out
end

function G:open_list()
    return '{ ' .. table.concat(self:opens(), ', ') .. ' }'
end

-- every declared name visible here
function G:visible_names()
    local seen, out = {}, {}
    local b = self.body
    while b do
        for i = #b.scopes, 1, -1 do
            for name in pairs(b.scopes[i]) do
                if type(name) == 'string' and not name:match '^__' and not seen[name] then
                    seen[name] = true
                    out[#out + 1] = str(name)
                end
            end
        end
        b = b.parent
    end
    table.sort(out)
    return '{ ' .. table.concat(out, ', ') .. ' }'
end

-- open the context held by Lua variable `var` for the rest of the current scope
function G:open_context(var, label)
    local outer = self:open_list()
    self:emit((' __S.open(%s, %s, %s, __ENV, %s)'):format(var, outer, self:visible_names(), str(label)))
    local sc = self.body.scopes[#self.body.scopes]
    sc.__opens = sc.__opens or {}
    table.insert(sc.__opens, var)
end

-- a declaration inside an opened region must not shadow an introduced name
function G:no_shadow_check(name)
    if #self:opens() > 0 then
        self:emit((' __S.no_shadow(%s, %s)'):format(self:open_list(), str(name)))
    end
end

-- statements ---------------------------------------------------------------------------------

function G:block(stats)
    self:push_scope()
    for _, s in ipairs(stats) do self:stat(s) end
    self:pop_scope()
end

function G:dead_check()
    if self.body.kind ~= 'host' then self:emit(' if __S.dead() then return end') end
end

-- a closure boundary for staged control flow
function G:closure(params, stats, extra)
    local o = self.out
    self.out = {}
    self.body.region = self.body.region + 1
    local nloops = #self.body.loops
    self:push_scope()
    if extra then extra() end
    for _, s in ipairs(stats) do self:stat(s) end
    self:pop_scope()
    for i = #self.body.loops, nloops + 1, -1 do self.body.loops[i] = nil end
    self.body.region = self.body.region - 1
    local text = table.concat(self.out)
    self.out = o
    return 'function(' .. params .. ') ' .. text .. ' end'
end

function G:assign_target(t, value)
    if t.k == 'name' then
        local v, owner = self:lookup(t.name)
        if not v and #self:opens() > 0 then
            -- an introduced field name: a store to its place
            return ('__S.oset(%s, %s, %s)'):format(self:open_list(), str(t.name), value)
        end
        if v and v.inferred then
            local host
            if owner ~= self.body then
                host = 'error(' .. str("cannot assign '" .. t.name .. "': a typed body can only assign bindings it declares") .. ')'
            else
                host = t.name .. ' = __S.assign_name(' .. t.name .. ', __value, '
                    .. (self.body.region - v.region) .. ')'
            end
            return '__S.assign_inferred(' .. self:expr(t) .. ', ' .. value
                .. ', function(__value) ' .. host .. ' end)'
        end
        if v and v.typed then
            -- a typed local is a place, also from a callback inside its word
            return '__S.set(' .. t.name .. ', ' .. value .. ')'
        end
        if not v or owner ~= self.body then
            self:err(("cannot assign '%s': a typed body can only assign bindings it declares"):format(t.name), t.line)
        end
        if v.context then
            self:err(("context-use: '%s' is an opened context; the whole context cannot be assigned"):format(t.name), t.line)
        end
        if v.pack then
            self:err(("pack-use: '%s' is a pack; it cannot be assigned"):format(t.name), t.line)
        end
        if v.loopvar then
            self:err(("'%s' is a loop variable; it cannot be assigned"):format(t.name), t.line)
        end
        if v.typed then
            return '__S.set(' .. t.name .. ', ' .. value .. ')'
        end
        if v.immutable then
            -- a parameter: assignment writes through it if it is a reference
            return '__S.assign_param(' .. t.name .. ', ' .. value .. ', ' .. str(t.name) .. ')'
        end
        -- an untyped binding: writes through a reference, otherwise rebinds
        local k = self.body.region - v.region
        return t.name .. ' = __S.assign_name(' .. t.name .. ', ' .. value .. ', ' .. k .. ')'
    elseif t.k == 'field' then
        return '__S.setindex(' .. self:prefix(t.obj) .. ', ' .. str(t.name) .. ', ' .. value .. ')'
    elseif t.k == 'index' then
        return '__S.setindex(' .. self:prefix(t.obj) .. ', ' .. self:expr(t.key) .. ', ' .. value .. ', true)'
    end
    self:err('cannot assign to this expression', t.line)
end

-- the typed locals of this body that a loop mentions: its explicit state
local function names_in(node, out)
    if type(node) ~= 'table' then return end
    if node.k == 'name' then out[node.name] = true end
    for k, v in pairs(node) do
        if type(v) == 'table' and k ~= 'type' then names_in(v, out) end
    end
end

function G:loop_state(nodes)
    local seen = {}
    for _, n in ipairs(nodes) do names_in(n, seen) end
    local list = {}
    for name in pairs(seen) do
        local v, owner = self:lookup(name)
        if v and (v.typed or v.inferred) and owner == self.body then list[#list + 1] = name end
    end
    table.sort(list)
    return list
end

function G:state_list(state)
    local q, values = {}, {}
    for i, n in ipairs(state) do
        q[i] = str(n)
        values[i] = '(' .. self:expr({ k = 'name', name = n }) .. ' or false)'
    end
    return '{ ' .. table.concat(values, ', ') .. ' }, { ' .. table.concat(q, ', ') .. ' }'
end

function G:loop_bindings(state)
    local params, bindings = {}, {}
    for i, n in ipairs(state) do
        local v = self:lookup(n)
        if v.inferred then
            self.loop_id = (self.loop_id or 0) + 1
            params[i] = '__inferred_loop_' .. self.loop_id
            bindings[n] = { inferred = true, loop_slot = params[i], region = v.region }
        else
            params[i] = n
            bindings[n] = { typed = true, region = v.region }
        end
    end
    return table.concat(params, ', '), function()
        for n, v in pairs(bindings) do self.body.scopes[#self.body.scopes][n] = v end
    end
end

function G:cond(e)
    -- in a host function a condition is host truth; native Bool values decide
    -- only when known
    if self.body.kind == 'host' then return '__S.truth(' .. self:expr(e) .. ')' end
    return self:expr(e)
end

function G:stat(s)
    self:at(s.line)
    local k = s.k
    local word = self.body.kind ~= 'host'
    if k == 'open' then
        if s.init then
            -- bind once, then open; a place stays a place, so its fields are live
            self:no_shadow_check(s.name)
            self:emit(' local ' .. s.name .. ' = __S.open_bind(' .. self:expr(s.init) .. ')')
            self:declare(s.name, { immutable = true, context = true })
        elseif not self:lookup(s.name) and #self:opens() > 0 then
            self:err(("cannot open '%s' here: it would be resolved through another opening; "
                .. "bind it first"):format(s.name), s.line)
        end
        self:open_context(s.name, s.name)
        return
    end
    if k == 'local' then
        for _, n in ipairs(s.names) do self:no_shadow_check(n.name) end
        local has_type = false
        for _, n in ipairs(s.names) do if n.type then has_type = true end end
        if has_type then
            if #s.exprs > #s.names then self:err('too many values in local declaration', s.line) end
            for i, n in ipairs(s.names) do
                if s.exprs[i] and s.exprs[i].k == 'spread' then
                    self:err('spread-context: a typed local takes one value; bind the spread to untyped locals', s.line)
                end
                local init = s.exprs[i] and self:expr(s.exprs[i]) or 'nil'
                if n.type then
                    self:emit(' local ' .. n.name .. ' = __S.decl(' .. self:expr(n.type) .. ', ' .. init
                        .. ', ' .. str(n.name) .. ')')
                    self:declare(n.name, { typed = true })
                else
                    self:emit(' local ' .. n.name .. ' = __S.infer(' .. init .. ', ' .. str(n.name) .. ')')
                    self:declare(n.name, { inferred = true })
                end
            end
            return
        end
        local names = {}
        for i, n in ipairs(s.names) do names[i] = n.name end
        if #s.exprs == 0 then
            self:emit(' local ' .. table.concat(names, ', '))
        elseif #s.names == 1 and #s.exprs == 1 and s.exprs[1].k ~= 'spread' then
            self:emit(' local ' .. names[1] .. ' = __S.infer(' .. self:expr(s.exprs[1]) .. ', ' .. str(names[1]) .. ')')
        else
            local quoted = {}
            for i, name in ipairs(names) do quoted[i] = str(name) end
            self:emit(' local ' .. table.concat(names, ', ') .. ' = __S.infern({ '
                .. table.concat(quoted, ', ') .. ' }, ' .. self:list(s.exprs) .. ')')
        end
        for _, n in ipairs(s.names) do self:declare(n.name, { inferred = true }) end
    elseif k == 'localfunction' then
        self:no_shadow_check(s.name)
        self:declare(s.name, {})
        local fn = s.fn
        self:emit(' local ' .. s.name .. '; ' .. s.name .. ' = ' .. self:lambda(fn))
    elseif k == 'assign' then
        local vals = {}
        if #s.targets == 1 then
            self:emit(' ' .. self:assign_target(s.targets[1], self:expr(s.exprs[1])))
            return
        end
        -- several targets: evaluate all values first, as Lua does
        local tmps = {}
        for i = 1, #s.targets do tmps[i] = '__a' .. i end
        self:emit(' do local ' .. table.concat(tmps, ', ') .. ' = ' .. self:list(s.exprs))
        for i, t in ipairs(s.targets) do
            self:emit(' ' .. self:assign_target(t, tmps[i]))
        end
        self:emit(' end')
    elseif k == 'callstat' then
        local text = self:expr(s.e)
        -- Lua 5.1 would read a leading '(' as a call of the previous line
        if text:sub(1, 1) == '(' then text = ';' .. text end
        self:emit(' ' .. text)
    elseif k == 'if' then
        if not word then
            for i, c in ipairs(s.clauses) do
                self:emit((i == 1 and ' if ' or ' elseif ') .. self:cond(c.cond) .. ' then')
                self:block(c.body)
            end
            if s.els then self:emit(' else'); self:block(s.els) end
            self:emit(' end')
            return
        end
        local function chain(i)
            local c = s.clauses[i]
            local cond = self:expr(c.cond)
            local tf = self:closure('', c.body)
            local ef
            if s.clauses[i + 1] then
                local o = self.out
                self.out = {}
                self.body.region = self.body.region + 1
                local inner = chain(i + 1)
                self.body.region = self.body.region - 1
                self.out = o
                ef = 'function() ' .. inner .. ' end'
            elseif s.els then
                ef = self:closure('', s.els)
            end
            return '__S.if_(' .. cond .. ', ' .. tf .. (ef and (', ' .. ef) or '') .. ')'
        end
        self:emit(' ' .. chain(1))
        self:dead_check()
    elseif k == 'while' then
        if not word then
            self:emit(' while ' .. self:cond(s.cond) .. ' do')
            self.body.loops[#self.body.loops + 1] = { region = self.body.region }
            self:block(s.body)
            self.body.loops[#self.body.loops] = nil
            self:emit(' end')
            return
        end
        -- the loop's state: typed locals it mentions become its parameters
        local state = self:loop_state({ s.cond, s.body })
        local params, bind_state = self:loop_bindings(state)
        self.body.region = self.body.region + 1
        self:push_scope()
        bind_state()
        local cond = self:expr(s.cond)
        self:pop_scope()
        self.body.region = self.body.region - 1
        local body = self:closure(params, s.body, function()
            bind_state()
            self.body.loops[#self.body.loops + 1] = { native = true, region = self.body.region }
        end)
        self:emit(' __S.while_(function(' .. params .. ') return ' .. cond .. ' end, ' .. body
            .. ', ' .. self:state_list(state) .. ')')
        self:dead_check()
    elseif k == 'numfor' then
        if s.type then
            if not word then
                self:err('a typed for loop is native; it belongs in a native word, not a host function', s.line)
            end
            local ty = self:expr(s.type)
            local lo, hi = self:expr(s.lo), self:expr(s.hi)
            local step = s.step and self:expr(s.step) or 'nil'
            local state = self:loop_state({ s.body })
            local state_params, bind_state = self:loop_bindings(state)
            local params = s.var .. (#state > 0 and (', ' .. state_params) or '')
            local body = self:closure(params, s.body, function()
                self:declare(s.var, { immutable = true, loopvar = true })
                bind_state()
                self.body.loops[#self.body.loops + 1] = { native = true, region = self.body.region }
            end)
            self:emit((' __S.for_(%s, %s, %s, %s, %s, %s)'):format(ty, lo, hi, step, body,
                self:state_list(state)))
            self:dead_check()
            return
        end
        -- a generation-time loop: plain Lua, bounds must be known
        local step = s.step and (', __S.num(' .. self:expr(s.step) .. ')') or ''
        self:emit((' for %s = __S.num(%s), __S.num(%s)%s do'):format(s.var, self:expr(s.lo),
            self:expr(s.hi), step))
        self:push_scope()
        self:declare(s.var, {})
        self.body.loops[#self.body.loops + 1] = { region = self.body.region }
        for _, st in ipairs(s.body) do self:stat(st) end
        self.body.loops[#self.body.loops] = nil
        self:pop_scope()
        self:emit(' end')
    elseif k == 'genfor' then
        self:emit(' for ' .. table.concat(s.names, ', ') .. ' in ' .. self:list(s.exprs) .. ' do')
        self:push_scope()
        for _, n in ipairs(s.names) do self:declare(n, {}) end
        self.body.loops[#self.body.loops + 1] = { region = self.body.region }
        for _, st in ipairs(s.body) do self:stat(st) end
        self.body.loops[#self.body.loops] = nil
        self:pop_scope()
        self:emit(' end')
    elseif k == 'repeat' then
        self:emit(' repeat')
        self:push_scope()
        self.body.loops[#self.body.loops + 1] = { region = self.body.region }
        for _, st in ipairs(s.body) do self:stat(st) end
        self.body.loops[#self.body.loops] = nil
        self:emit(' until __S.truth(' .. self:expr(s.cond) .. ')')
        self:pop_scope()
    elseif k == 'break' then
        local loop = self.body.loops[#self.body.loops]
        if not loop then self:err('break outside a loop', s.line) end
        if loop.native then
            self:emit(' do __S.loop_break() return end')
            return
        end
        if loop.region ~= self.body.region then
            self:err('break cannot leave a native branch; restructure the loop condition', s.line)
        end
        self:emit(' break')
    elseif k == 'continue' then
        local loop = self.body.loops[#self.body.loops]
        if not loop then self:err('continue outside a loop', s.line) end
        if not loop.native then
            self:err('continue is supported in native loops (typed for, while), not in generation-time loops', s.line)
        end
        self:emit(' do __S.loop_continue() return end')
    elseif k == 'do' then
        self:emit(' do')
        self:block(s.body)
        self:emit(' end')
    elseif k == 'return' then
        if #s.exprs > 1 and word and not has_spread(s.exprs) then
            self:err('a native word returns one value', s.line)
        end
        if word then
            local e = s.exprs[1]
            if has_spread(s.exprs) then
                -- `return ...args`: the components, which must be exactly one value
                self:emit(' do __S.ret_one(' .. self:list(s.exprs) .. ') return end')
            elseif #s.exprs == 0 then
                self:emit(' do __S.ret() return end')
            elseif e.k == 'call' and e.fn.k ~= 'call' and e.fn.k ~= 'method'
                and not (e.fn.k == 'name' and not self:lookup(e.fn.name) and #self:opens() > 0) then
                -- a tail call
                local args = self:list(e.args)
                self:emit(' do __S.tail(' .. self:prefix(e.fn) .. (args ~= '' and (', ' .. args) or '') .. ') return end')
            elseif e.k == 'method' then
                local args = self:list(e.args)
                self:emit(' do local __o = ' .. self:prefix(e.obj) .. '; __S.tail(__o.' .. e.name .. ', __o'
                    .. (args ~= '' and (', ' .. args) or '') .. ') return end')
            else
                self:emit(' do __S.ret(' .. self:expr(e) .. ') return end')
            end
        else
            self:emit(' do return ' .. self:list(s.exprs) .. ' end')
        end
    elseif k == 'function' then
        self:err('a function statement cannot appear inside a typed body; use local function', s.line)
    elseif k == 'export' then
        self:err('export belongs at the top level', s.line)
    else
        self:err('internal: unknown statement ' .. tostring(k), s.line)
    end
end

-- entry points used by the macros ---------------------------------------------------------------

-- translate a typed lambda whose `(` was consumed. Returns the Lua text, and
-- the tokens read ahead, which go back to the macro processor.
function M.translate_lambda(reader, name, start_line)
    local p = M.parser(reader)
    local fn = p:funcbody(name, { line = start_line }, { params_open = true })
    if not fn.result then reader:error('internal: translate_lambda without a result type') end
    local g = M.codegen(reader.filename, start_line)
    local text = g:lambda(fn)
    return text, reader:leftovers()
end

-- `function a.b:m(params): T ... end` (the `function` token was consumed);
-- `is_local` when it follows `local`
function M.translate_function(reader, is_local, start_line)
    local p = M.parser(reader)
    local r = reader
    local path = { r:name('after function').v }
    local method
    while true do
        if r:accept('.') then path[#path + 1] = r:name('in function name').v
        elseif r:accept(':') then method = r:name('in method name').v break
        else break end
    end
    local hint = method and (path[#path] .. '_' .. method) or path[#path]
    local fn = p:funcbody(hint, { line = start_line })
    local g = M.codegen(reader.filename, start_line)
    local text
    if method then
        local target = table.concat(path, '.')
        text = '__S.method(' .. target .. ', ' .. str(method) .. ', ' .. g:lambda(fn, true) .. ')'
    elseif is_local then
        if #path > 1 then reader:error('local function names cannot contain dots') end
        text = path[1] .. '; ' .. path[1] .. ' = ' .. g:lambda(fn)
    else
        text = table.concat(path, '.') .. ' = ' .. g:lambda(fn)
    end
    return text, reader:leftovers()
end

-- `struct { ... }` (the struct token is next)
function M.translate_struct(reader, name, start_line, kind)
    local p = M.parser(reader)
    local e = p:struct(name)
    local g = M.codegen(reader.filename, start_line)
    g.body = new_body('host')
    local text = g:struct(e)
    return text, reader:leftovers()
end

M.Reader = Reader
return M
