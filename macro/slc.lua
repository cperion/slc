--[==[
macro.slc: the staged Lua -> C language as LuaMacro macros, on top of macro.let.

    do(x: U32): U32 = x + 1         a native word (it declares a result type)
    function T:m(n: U32): Unit ...  a method: a native word attached to struct T
    local function f(...): T ...    a recursive native word
    struct { x: F32, y: F32 }       a struct type (annotations live only here,
                                    in parameter lists, typed locals and typed for)
    export name                     materialize a word as an exported C function

Typed bodies are parsed by slc.syntax, which turns comparisons, `and`/`or`,
conditions, typed assignment, loops and `return` into staged operations.
]==]

local M = require 'macro'
require 'macro.let'
local lexer = require 'macro.lexer'
local TokenList = require 'macro.TokenList'
local syntax = require 'slc.syntax'

local function line_of() return lexer.line end

-- raw generated text, followed by the tokens the parser read ahead
local function result(text, leftovers)
    local put = TokenList.new { { 'string', text } }
    for _, tk in ipairs(leftovers) do put[#put + 1] = tk end
    return put
end

-- pad generated text to the number of source lines it replaces
local function pad(text, reader, start_line)
    local consumed = (reader.cur_line or start_line) - start_line
    local _, have = text:gsub('\n', '')
    if consumed > have then text = text .. ('\n'):rep(consumed - have) end
    return text
end

-- the significant token before the macro name, and the offset before it
local function before(get, k)
    local t, v = get:peek(k, true)
    while t == 'space' or t == 'comment' do
        k = k - 1
        t, v = get:peek(k, true)
    end
    return t, v, k
end

-- a typed lambda: macro.let read `do(` params `)` and the ':' of the result
M.let_typed = function (get, ptoks, info)
    local prefix = {}
    for i, tk in ipairs(ptoks) do prefix[i] = tk end
    prefix[#prefix + 1] = { ')', ')' }
    prefix[#prefix + 1] = { ':', ':' }
    local reader = syntax.reader(function () return get() end, prefix, line_of, M.filename, info.line)
    local text, left = syntax.translate_lambda(reader, info.name, info.line)
    if info.argument then text = text .. ')' end
    return result(pad(text, reader, info.line), left)
end

M.define('__typed_function', function (get)
    local start = lexer.line
    local t, v = before(get, -3)
    local is_local = t == 'keyword' and v == 'local'
    local reader = syntax.reader(function () return get() end, {}, line_of, M.filename, start)
    local text, left = syntax.translate_function(reader, is_local, start)
    return result(pad(text, reader, start), left)
end)

-- `t.struct`, `t:export(...)`: a field or method name, not the macro
local function member_name(get)
    local t = before(get, -3)
    return t == '.' or t == ':'
end

local function type_macro(kind)
    return function (get)
        if member_name(get) then return nil, true end
        local start = lexer.line
        local name
        local t, v, k = before(get, -3)
        if t == '=' then
            local t2, v2 = before(get, k - 1)
            if t2 == 'iden' then name = v2 end
        end
        local reader = syntax.reader(function () return get() end, { { 'iden', kind } }, line_of,
            M.filename, start)
        local text, left = syntax.translate_struct(reader, name, start)
        return result(pad(text, reader, start), left)
    end
end

M.define('struct', type_macro('struct'))
M.define('oneof', type_macro('oneof'))

-- `export name` or `export name as "cname"`
M.define('export', function (get)
    if member_name(get) then return nil, true end
    local start = lexer.line
    local reader = syntax.reader(function () return get() end, {}, line_of, M.filename, start)
    local name = reader:name('after export').v
    local cname = name
    while reader:accept('.') do
        local part = reader:name('in export').v
        name = name .. '.' .. part
        cname = cname .. '_' .. part
    end
    local tk = reader:peek(1)
    if tk.t == 'iden' and tk.v == 'as' and not tk.nl then
        reader:next()
        local s = reader:next()
        if s.t ~= 'string' then reader:error('export ... as expects a string naming the C function', s) end
        cname = assert(loadstring('return ' .. s.v))()
    end
    local text = ('__S.export_word(%s, %q)'):format(name, cname)
    return result(pad(text, reader, start), reader:leftovers())
end)

-- `.name` in a table constructor is `name = name`. A `.` never follows `{`, `,`
-- or `;` in valid Lua, so no existing program changes. It is rewritten in the
-- token list, so typed bodies, macros and plain Lua code around them all see
-- the long form. Source tools (slc fmt) read the raw tokens and keep `.name`.
local ENTRY_START = { ['{'] = true, [','] = true, [';'] = true }
local ENTRY_END = { [','] = true, [';'] = true, ['}'] = true }

local function significant_before(tokens, i)
    i = i - 1
    while i >= 1 and (tokens[i][1] == 'space' or tokens[i][1] == 'comment') do i = i - 1 end
    return i >= 1 and tokens[i][1] or nil
end

local function significant_after(tokens, i)
    i = i + 1
    while tokens[i] and (tokens[i][1] == 'space' or tokens[i][1] == 'comment') do i = i + 1 end
    return tokens[i] and tokens[i][1] or nil
end

local scan_lua_tokenlist = lexer.scan_lua_tokenlist
function lexer.scan_lua_tokenlist(input)
    local tokens = scan_lua_tokenlist(input)
    local out, i = {}, 1
    while i <= #tokens do
        local tk, nx = tokens[i], tokens[i + 1]
        if tk[1] == '.' and nx and nx[1] == 'iden'
            and ENTRY_START[significant_before(tokens, i)]
            and ENTRY_END[significant_after(tokens, i + 1)] then
            local line = tk[3]
            out[#out + 1] = { 'iden', nx[2], line }
            out[#out + 1] = { 'space', ' ', line }
            out[#out + 1] = { '=', '=', line }
            out[#out + 1] = { 'space', ' ', line }
            out[#out + 1] = { 'iden', nx[2], line }
            i = i + 2
        else
            out[#out + 1] = tk
            i = i + 1
        end
    end
    return out
end

return M
