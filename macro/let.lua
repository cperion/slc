--[==[
macro.let: Let's lambdas and literal arguments as LuaMacro macros, for Lua 5.1 and LuaJIT.

    luajit luam -lmacro.let program.lua       run
    luajit luam -lmacro.let -d program.lua    print the Lua it becomes

The forms, as in Let (syntax.md §4 and the application sugar):

    do(x) = x + 1            an expression lambda: the body runs to the end of its
                             expression, across lines, up to its delimiter
    do(x: U32): U32 = x + 1  parameter and result types are read and dropped
    do(x) ... end            a block lambda
    do ... end               a nullary block lambda; `do() ... end` is the same
    do(...) ... end          the argument is opened: its members are in scope by
    do(ctx...) ... end       name, for reads and writes; `ctx...` also names it
    do(x) = do(y) = x + y    currying needs no grouping

Application, as in Let: a lambda after an expression is that expression's argument,
and every suffix is its own application.

    f do(p) ... end          f(do(p) ... end)
    f(x) do(p) ... end       f(x)(do(p) ... end), not an appended argument
    f "x" do ... end         f("x")(do ... end)

A literal after an expression is its argument too, with the literal's postfix chain
(member selection, `:method`, indexing, bracketed application):

    f 21                     f(21)
    f true                   f(true)
    f "%d":format(n) .. "!"  f(("%d"):format(n)) .. "!"
    f 1 2                    f(1)(2)
    f 21 do ... end          f(21)(do ... end)

Newlines are whitespace, as in Let: a literal's whole postfix chain attaches whatever
the spacing, so `f 21 (2)` is f(21(2)) and `f "x" [1]` is f(("x")[1]); write
`f(21)(2)` or `(f 21)(2)` to apply the call's result instead. A chain `(` that would
start a line is written at the end of the previous line, so Lua 5.1 never sees a line
that starts with '(' after an expression ("ambiguous syntax"). A lambda on the line
after its call is still the call's argument, and an expression body goes on to the
next line when it can.

Lua's own `do` stays Lua's in two places: the `do` of a `while` or `for` header, and
`do ... end` where a statement starts (after `then`, `else`, `end`, `do`, `repeat`,
`;`, a complete operand that cannot be called, a function header, or the top).
A string or table constructor only counts as callable when it is itself a call's
argument (`f "x"`, `f {1}`); after `=`, `return` or a comma a following `do ... end`
is Lua's. Let has no such block: there a standalone `do ... end` is a lambda that is
built and thrown away, so nothing Let means is lost. In a loop header, put a lambda
inside brackets: `for x in each(xs, do(x) = x > 0) do`.
]==]

local M = require 'macro'
require 'macro.builtin'
local lexer = require 'macro.lexer'
local TokenList = require 'macro.TokenList'

-- the lexer --------------------------------------------------------------------------
-- Two rules. Every `do` is a name, so the `do` macro sees it. And a literal right
-- after an operand it can apply to is marked, so the APPLY macro below sees it.

local APPLY = '__let_apply'
local LITERAL = { number = true, string = true }
local CALLABLE = { iden = true, string = true, [')'] = true, [']'] = true, ['}'] = true }

-- A third rule: a name directly after a name, on the same line, is its argument
-- (`Grow U32`, `transform x`, `f a b`). A newline ends an application chain
-- before a name, because a name can begin a statement; literals, tables and
-- lambdas cannot, so they still attach across lines.

-- a name that cannot take part in name application
local function plain_name (v)
    return v ~= 'do' and v ~= APPLY and v ~= 'goto' and not M.macro_table[v]
end

-- does the `function` keyword at index i begin a typed function statement,
-- `function a.b:c(params): Type`?  (only when a handler for those exists)
local function typed_function (tokens, i)
    if not M.macro_table.__typed_function then return false end
    local n = #tokens
    local function sig (j)
        j = j + 1
        while j <= n and (tokens[j][1] == 'space' or tokens[j][1] == 'comment') do j = j + 1 end
        return j
    end
    local j = sig(i)
    if j > n or tokens[j][1] ~= 'iden' then return false end
    j = sig(j)
    while j <= n and (tokens[j][1] == '.' or tokens[j][1] == ':') do
        local sep = tokens[j][1]
        j = sig(j)
        if j > n or tokens[j][1] ~= 'iden' then return false end
        j = sig(j)
        if sep == ':' then break end
    end
    if j > n or tokens[j][1] ~= '(' then return false end
    local depth = 0
    while j <= n do
        local t = tokens[j][1]
        if t == '(' then depth = depth + 1 elseif t == ')' then depth = depth - 1 end
        if depth == 0 then break end
        j = j + 1
    end
    j = sig(j)
    return j <= n and tokens[j][1] == ':'
end

local INT64_SUFFIX = { ULL = true, LL = true, ull = true, ll = true }

local scan = lexer.scan_lua_tokenlist
function lexer.scan_lua_tokenlist (input)
    local tokens = scan(input)
    -- LuaJIT's 64-bit integer literals (42ULL, 7LL) are one number token
    for i = #tokens - 1, 1, -1 do
        local a, b = tokens[i], tokens[i + 1]
        if a[1] == 'number' and b[1] == 'iden' and INT64_SUFFIX[b[2]] and a[2]:match '^%d+$' then
            a[2] = a[2] .. b[2]
            table.remove(tokens, i + 1)
        end
    end
    local out, prev = {}, nil                    -- prev: index in out of the last significant token
    local newline = false                        -- a line break since prev
    for i, token in ipairs(tokens) do
        local t, v = token[1], token[2]
        if t == 'keyword' and v == 'do' then t = 'iden'; token[1] = 'iden' end
        if t == 'keyword' and v == 'function' and typed_function(tokens, i) then
            t, v = 'iden', '__typed_function'
            token[1], token[2] = t, v
        end
        if t ~= 'space' and t ~= 'comment' then
            local literal = LITERAL[t] or (t == 'keyword' and (v == 'true' or v == 'false'))
            local p = prev and out[prev]
            local mark = literal and p and (p.applied or CALLABLE[p[1]]
               and not (p[1] == 'iden' and (p[2] == 'do' or p[2] == APPLY or M.macro_table[p[2]])))
            if not mark and t == 'iden' and plain_name(v) and p and not newline then
                mark = p.applied or (p[1] == 'iden' and plain_name(p[2]))
            end
            if mark then
                -- `f 1 2` is f(1)(2): a marked argument's call can take the next one
                table.insert(out, prev + 1, { 'iden', APPLY, p[3] })
                token.applied = true
            end
            out[#out + 1] = token
            prev = #out
            newline = false
        else
            if t == 'space' and v:find '\n' then newline = true end
            out[#out + 1] = token
        end
    end
    return out
end

-- loop headers: each `while` and `for` waits for its own `do` -------------------------

local loops = 0
M.keyword_handler('while', function () loops = loops + 1 end)
M.keyword_handler('for', function () loops = loops + 1 end)

-- token classes ---------------------------------------------------------------------------

local function is_do (t, v) return t == 'iden' and v == 'do' end

-- tokens that end an operand
local ENDS = { iden = true, number = true, string = true, [')'] = true, [']'] = true, ['}'] = true }
local ENDS_WORD = { ['true'] = true, ['false'] = true, ['nil'] = true, ['end'] = true }
local function ends_operand (t, v)
    return (ENDS[t] and not is_do(t, v)) or (t == 'keyword' and ENDS_WORD[v]) or false
end

-- operands a lambda can be the argument of: names, calls and indexes. A literal
-- is only callable when the lexer marked it as a call's argument (`f 21`, `f "x"`),
-- and a table constructor only when it is one too (`f {1}`); `callable` decides.
local CALLED = { iden = true, [')'] = true, [']'] = true }
local function called (t, v) return CALLED[t] and not is_do(t, v) or false end

-- what can follow a complete operand and go on with the expression
local GOES_ON = { ['+'] = true, ['-'] = true, ['*'] = true, ['/'] = true, ['%'] = true,
                  ['^'] = true, ['=='] = true, ['~='] = true, ['<'] = true, ['>'] = true,
                  ['<='] = true, ['>='] = true, ['.'] = true, [':'] = true, ['['] = true,
                  ['('] = true, ['{'] = true, string = true }
local function goes_on (t, v)
    if t == 'keyword' then return v == 'and' or v == 'or' end
    return GOES_ON[t] or is_do(t, v) or false            -- `do` here: a lambda argument
end

-- where a statement starts
local STATEMENT_WORDS = { ['then'] = true, ['else'] = true, ['end'] = true, ['repeat'] = true }

-- reading forward -------------------------------------------------------------------------

-- read a balanced group after its opener was read; `keep` collects the text
local function balanced (get, open, close, keep)
    local depth = 1
    repeat
        local t, v = get()
        if not t then M.error("'" .. open .. "' is not closed") end
        if keep then keep[#keep + 1] = v end
        if t == open then depth = depth + 1 elseif t == close then depth = depth - 1 end
    until depth == 0
end

local function significant (get)
    local skipped = {}
    local t, v = get()
    while t == 'space' or t == 'comment' do
        skipped[#skipped + 1] = v
        t, v = get()
    end
    return t, v, table.concat(skipped)
end

-- read a balanced bracket group after its '(' was read; `keep` collects the text
local function group (get, keep)
    local depth = 1
    repeat
        local t, v = get()
        if not t then M.error 'a bracket is not closed' end
        if keep then keep[#keep + 1] = v end
        if t == '(' then depth = depth + 1 elseif t == ')' then depth = depth - 1 end
    until depth == 0
end

-- read a type: Name ('.' Name)* ['(' ... ')'] [':' type], or a bracketed signature
-- ['(' ... ')' ':' type]. Returns the token after it. `keep` collects the text.
local function read_type (get, keep)
    local function take (t, v, skipped)
        if keep then keep[#keep + 1] = skipped; keep[#keep + 1] = v end
    end
    local t, v, skipped = significant(get)
    take(t, v, skipped)
    if t == '(' then
        group(get, keep)
    elseif t == 'iden' then
        t, v, skipped = significant(get)
        while t == '.' do
            take(t, v, skipped)
            t, v, skipped = significant(get); take(t, v, skipped)
            t, v, skipped = significant(get)
        end
        if t ~= '(' then
            if t == ':' then take(t, v, skipped); return read_type(get, keep) end
            return t, v, skipped
        end
        take(t, v, skipped)
        group(get, keep)
    else
        M.error("a type cannot start with '" .. tostring(v) .. "'")
    end
    t, v, skipped = significant(get)
    if t == ':' then take(t, v, skipped); return read_type(get, keep) end
    return t, v, skipped
end

-- `( params )` after the '(' was read. Returns the Lua names and the opened one.
local function parameters (get)
    local names, opened = {}, nil
    local t, v = significant(get)
    while t ~= ')' do
        if not t then M.error 'a lambda parameter list is not closed' end
        if t == 'iden' then
            names[#names + 1] = v
            t, v = significant(get)
            if t == '.' then                              -- `ctx...`: lexed as three dots
                get(); get(); opened = names[#names]; t, v = significant(get)
            end
        elseif t == '.' then                              -- `...`
            get(); get()
            names[#names + 1] = '__home'; opened = '__home'
            t, v = significant(get)
        else
            M.error("'" .. tostring(v) .. "' in a lambda's parameters")
        end
        if t == ':' then t, v = read_type(get) end
        if t == ',' then t, v = significant(get)
        elseif t ~= ')' then M.error("'" .. tostring(v) .. "' in a lambda's parameters") end
    end
    return table.concat(names, ', '), opened
end

-- An opened home: its members are in scope by name, for reads and writes; other names
-- still come from the enclosing environment. One line, so line numbers stay put.
local function opening (home)
    return (' local __outer = getfenv and getfenv(1) or _ENV'
        .. ' local _ENV = setmetatable({}, { __newindex = %s, __index = function (_, k)'
        .. ' local v = %s[k] if v == nil then v = __outer[k] end return v end })'
        .. ' if setfenv then setfenv(1, _ENV) end'):format(home, home)
end

-- An expression body: everything up to the first token at its own level that cannot
-- go on with it. Returns the body and the text that stopped it, to be read again.
local function expression (get)
    local parts = {}
    local brackets, blocks, inner_loops = 0, 0, 0
    local ended = false                                  -- the last token ended an operand
    local function put (s) parts[#parts + 1] = s end
    local back                                           -- a token to read again
    while true do
        local t, v, skipped
        if back then t, v, skipped = back[1], back[2], back[3]; back = nil
        else t, v, skipped = significant(get) end
        if not t then return table.concat(parts), skipped end

        if brackets == 0 and blocks == 0 then
            local stop
            if t == ',' or t == ';' or t == ')' or t == ']' or t == '}' then stop = true
            elseif t == 'iden' and v == APPLY then stop = false  -- a literal argument follows
            elseif is_do(t, v) then stop = loops > 0 and ended   -- the `do` of a loop header
            elseif t == 'keyword' then
                if v == 'and' or v == 'or' then stop = false
                elseif v == 'not' or v == 'function' or v == 'true' or v == 'false' or v == 'nil' then
                    stop = ended                          -- a new operand after a complete one
                else stop = true end                      -- end, then, local, return, ...
            else
                stop = ended and not goes_on(t, v)
            end
            if stop then return table.concat(parts), skipped .. v end
        end

        if t == '(' and ended and skipped:find '\n' then
            put ' ('; put(skipped)                       -- keep the call's '(' on its line
        elseif v == APPLY then
            put(skipped); put(' '); put(v)              -- the mark has no space of its own
        else
            put(skipped); put(v)
        end

        if is_do(t, v) then
            -- a nested lambda: copy its head, then see whether it has a block body
            local nt, nv, gap = significant(get)
            local block = true
            if nt == '(' then
                put(gap); put(nv)
                group(get, parts)
                nt, nv, gap = significant(get)
                if nt == ':' then
                    put(gap); put(nv)
                    nt, nv, gap = read_type(get, parts)
                end
                if nt == '=' then block = false; put(gap); put(nv)
                else back = { nt, nv, gap } end
            else
                if blocks > 0 and inner_loops > 0 and ended then
                    inner_loops = inner_loops - 1; block = false   -- a loop's own `do`
                end
                back = { nt, nv, gap }
            end
            if block then blocks = blocks + 1 end
            ended = false
        else
            if t == '(' or t == '[' or t == '{' then brackets = brackets + 1
            elseif t == ')' or t == ']' or t == '}' then brackets = brackets - 1
            elseif t == 'keyword' then
                if v == 'function' or v == 'if' or v == 'repeat' then blocks = blocks + 1
                elseif v == 'while' or v == 'for' then blocks = blocks + 1; inner_loops = inner_loops + 1
                elseif v == 'end' or v == 'until' then blocks = blocks - 1 end
            end
            ended = ends_operand(t, v) and v ~= APPLY   -- after the mark comes its literal
        end
    end
end

-- reading back ----------------------------------------------------------------------------

-- the significant token at or before peek offset k (peek(-2) is the `do` itself)
local function back_from (get, k)
    local gap = 0
    local t, v = get:peek(k, true)
    while t == 'space' or t == 'comment' do
        gap = gap + 1; k = k - 1; t, v = get:peek(k, true)
    end
    return t, v, k, gap
end

-- does the ')' at offset k close a function header's parameter list?
local function closes_header (get, k)
    local depth = 0
    repeat
        local t = get:peek(k, true)
        if not t then return false end
        if t == ')' then depth = depth + 1 elseif t == '(' then depth = depth - 1 end
        k = k - 1
    until depth == 0
    local t, v
    t, v, k = back_from(get, k)
    while true do
        if t == 'keyword' and v == 'function' then return true end
        if t ~= 'iden' then return false end
        t, v, k = back_from(get, k - 1)                  -- before a name: function, '.' or ':'
        if t == '.' or t == ':' then t, v, k = back_from(get, k - 1)
        elseif not (t == 'keyword' and v == 'function') then return false end
    end
end

-- The lambda is an argument: write its '(' right after the expression it applies.
-- With spaces or comments between, the '(' goes into the output just after the
-- expression, so it stays on that expression's line.
local function open_call (get, gap)
    if gap == 0 then return '(' end
    local next_out = get:placeholder(TokenList.new())   -- the next output index; writes nothing
    local first = next_out - gap
    local text = get:copy_from(first):sub(1, -1 - #get:copy_from(first + 1))
    get:patch(first, ' (' .. text)
    return ''
end

-- is the literal at offset k a marked argument, so `f 21 do ... end` is f(21)(lambda)?
local function applied (get, k)
    local t, v = back_from(get, k - 1)
    return t == 'iden' and v == APPLY
end

-- is the '}' at offset k the end of a table constructor that is a call's argument?
-- A table constructor can only be followed by '(' when it is itself an argument of
-- a call (`f {1}`, `f "x" {1}`); after '=', 'return', a comma or a bracket it cannot.
local function table_argument (get, k)
    local depth = 1
    local t, v
    repeat
        t, v, k = back_from(get, k - 1)
        if not t then return false end
        if t == '}' then depth = depth + 1
        elseif t == '{' then depth = depth - 1 end
    until depth == 0
    local bt, bv, bk = back_from(get, k - 1)
    if bt == 'iden' or bt == ')' or bt == ']' or bt == '}' then return true end
    return applied(get, bk)                    -- `f 21 {}`, `f "x" {}`
end

-- can a '(' in Lua follow the previous expression?  A name, call or index can; so
-- can a literal or table constructor that is itself a call's argument.
local function callable (get, t, v, k)
    if called(t, v) then return true end
    if t == '}' then return table_argument(get, k) end
    return applied(get, k)
end

-- the literal-led argument ----------------------------------------------------------------
-- `f 21`, `f true`, `f "x"`: one literal and its postfix chain is one argument, as in
-- Let's application sugar. The chain holds member selection (`.name`, `:name`),
-- indexing and parenthesized application; it stops at an infix operator, another bare
-- literal or a lambda. So `print "{}":format(n) .. "!"` is print("{}":format(n)) .. "!".
-- The whole chain attaches whatever the spacing: a newline before a chain bracket does
-- not end it. The mark sits right after the operand, so the '(' stays on its line.

local argument_text
function argument_text (get)
    local t, v, skipped = significant(get)
    local lead = skipped:find '\n' and skipped or ''   -- keep line breaks, drop plain spaces
    local chain = {}
    local named = t == 'iden'                          -- `add Node {...}`: a name's chain
    while true do                                      -- takes Lua's call suffixes too
        local next_t = get:peek(1)
        if named and next_t == '{' then
            local _, b, gap = significant(get)
            chain[#chain + 1] = gap; chain[#chain + 1] = b
            balanced(get, '{', '}', chain)
            goto continue
        elseif named and next_t == 'string' then
            local _, b, gap = significant(get)
            chain[#chain + 1] = gap; chain[#chain + 1] = b
            goto continue
        end
        if next_t == '.' and get:peek(2) == 'iden' or next_t == ':' then
            -- `.name` or `:name`; `..` (two dots) is concatenation and ends the chain
            local method = next_t == ':'
            for _ = 1, 2 do
                local _, b, gap = significant(get)
                chain[#chain + 1] = gap; chain[#chain + 1] = b
            end
            if method and get:peek(1) == 'iden' and select(2, get:peek(1)) == APPLY then
                significant(get)                       -- `"x":rep 3`: a method takes its literal
                chain[#chain + 1] = argument_text(get)
            end
        elseif next_t == '[' then
            -- indexing belongs to the literal whatever the spacing; a new line may
            -- start with '[' (Lua only guards '(')
            local _, b, gap = significant(get)
            chain[#chain + 1] = gap; chain[#chain + 1] = b
            balanced(get, '[', ']', chain)
        elseif next_t == '(' then
            local _, b, gap = significant(get)
            if gap:find '\n' then
                -- write the '(' on the line of the expression it applies to
                chain[#chain + 1] = ' ('; chain[#chain + 1] = gap
            else
                chain[#chain + 1] = gap; chain[#chain + 1] = b
            end
            balanced(get, '(', ')', chain)
        else
            break
        end
        ::continue::
    end
    if #chain == 0 then return '(' .. lead .. v .. ')' end
    if named then return '(' .. lead .. v .. table.concat(chain) .. ')' end
    -- Lua needs a literal receiver in brackets: ("x"):upper(), not "x":upper()
    return '(' .. lead .. '(' .. v .. ')' .. table.concat(chain) .. ')'
end

M.set_macro(APPLY, function (get) return argument_text(get) end)

-- the macro -------------------------------------------------------------------------------

-- a getter over collected tokens
local function token_stream (toks)
    local i = 0
    return function ()
        i = i + 1
        local tk = toks[i]
        if tk then return tk[1], tk[2] end
    end
end

M.set_macro('do', function (get, put)
    local do_line = lexer.line
    local pt, pv, k, gap = back_from(get, -3)
    local name_hint                                      -- `name = do(...)`
    if pt == '=' then
        local nt2, nv2 = back_from(get, k - 1)
        if nt2 == 'iden' then name_hint = nv2 end
    end
    local header = pt == ')' and closes_header(get, k)
    local operand = ends_operand(pt, pv) and not header

    -- Lua's own `do`: a loop's, or a block where a statement starts
    if loops > 0 and operand then
        loops = loops - 1
        return put:keyword 'do'
    end
    local can_call = operand and callable(get, pt, pv, k)
    local nt = get:peek(1)
    if nt ~= '(' then
        local statement = pt == nil or pt == ';' or is_do(pt, pv) or header
            or (pt == 'keyword' and STATEMENT_WORDS[pv])
            or (operand and not can_call)
        if statement then return put:keyword 'do' end
    end

    -- a lambda
    local argument = can_call
    local paren = argument and open_call(get, gap) or ''

    local names, opened = '', nil
    local parens = nt == '('
    local after                                          -- the token after ')'
    if parens then
        significant(get)                                 -- the '('
        local ptoks, depth, typed = {}, 1, false
        while true do
            local tt, tv = get()
            if not tt then M.error 'a lambda parameter list is not closed' end
            if tt == '(' then depth = depth + 1 elseif tt == ')' then depth = depth - 1 end
            if depth == 0 then break end
            if tt == ':' and depth == 1 then typed = true end
            ptoks[#ptoks + 1] = { tt, tv }
        end
        local t2, v2, s2 = significant(get)
        if t2 == ':' and M.let_typed then
            -- a result type: a native word, translated by the typed-body language
            return M.let_typed(get, ptoks, { argument = argument, name = name_hint, line = do_line })
        end
        if typed and M.let_typed then
            M.error "typed parameters need a result type: native words are written do(x: T): R"
        end
        ptoks[#ptoks + 1] = { ')', ')' }
        names, opened = parameters(token_stream(ptoks))
        after = { t2, v2, s2 }
    end
    local head = paren .. 'function (' .. names .. ')'
    if opened then head = head .. opening(opened) end

    local t, v, skipped
    if parens then
        t, v, skipped = after[1], after[2], after[3]
        if t == ':' then t, v, skipped = read_type(get) end   -- a result type
        if t == '=' then
            local body, stop = expression(get)
            if stop:match '^%w' then stop = ' ' .. stop end
            return head .. ' return' .. skipped .. body .. ' end' .. (argument and ')' or '') .. stop
        end
    end

    -- a block: Lua's own `end` closes the function, and an argument's call needs ')'
    if argument then
        M.block_handler(0, function (_, word)
            if word ~= 'end' then return nil, true end
            return ')'
        end)
    end
    if t then return head .. skipped .. v end
    return head
end)

return M
