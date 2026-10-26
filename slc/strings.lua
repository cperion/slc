-- slc.strings: text.
--
--   Str        a read-only view of bytes (a Slice U8 with text words)
--   Text       Grow U8 with text words: owned text, built in place
--   Chars(n)   short text as a value: a length and n bytes
--
-- A Str literal is known while compiling, and so are its bytes: the text
-- words (lib/str.slc, written in slc) run while compiling over known text and
-- unroll over known parts. Text:write is formatted while specializing: known
-- pieces become one literal, each runtime value the conversion its type needs.

local S = require 'slc.stage'
local types = require 'slc.types'
local Mem = require 'slc.memory'

local Str = {}
local T = types.Str
local U8, U32 = types.U8, types.U32
local u8p = types.ptr(U8)

local function fail(msg, level) S.fail(msg, (level or 2) + 1) end

-- literals ---------------------------------------------------------------------------------------

function S.str_literal(s)
    local e = { op = 'conv', a = { op = 'const', T = types.CString, v = s }, T = u8p, str_lit = s }
    return S.make_slice(T, S.dyn(u8p, e), S.known(U32, #s))
end

-- the text of a Str known while compiling, or nil: a literal, or a part of one
local function lit_of(e)
    if type(e) ~= 'table' then return nil end
    if e.str_lit then return e.str_lit, 0 end
    if e.op == 'addr' and e.place and e.place.pk == 'index' then
        local base, idx = rawget(e.place, 'base'), rawget(e.place, 'idx')
        local t, o = lit_of(base)
        if t and type(idx) == 'table' and idx.op == 'const' then return t, o + tonumber(idx.v) end
    end
    return nil
end

function Str.known_text(x)
    local ptr, len = S.slice_parts(x)
    if not (S.is_value(len) and len.k == 'known') then return nil end
    if ptr.k == 'array_ptr' then return S.array_pointer_text(ptr, len) end
    local t, o = lit_of(S.ex(ptr))
    if not t then return nil end
    return t:sub(o + 1, o + tonumber(len.v))
end
S.known_text = Str.known_text

local function as_str(x, what)
    if type(x) == 'string' then return S.str_literal(x) end
    local v = S.value_of(x, nil, what)
    if S.is_value(v) and v.T == T then return v end
    if S.is_value(v) and v.T == types.CString then return Str.of(v) end
    if S.is_value(v) and rawget(v.T, 'chars_cap') then
        fail(what .. ': a Chars(n) is viewed as text with c:str()', 3)
    end
    fail(('%s: expected text (a Str or a string), got %s'):format(what, S.describe and S.describe(x) or tostring(x)), 3)
end
Str.as_str = as_str

-- require caches this vocabulary for the current compilation, not the host
-- lifetime of slc.strings (which would retain staged words across resets).
local function L()
    return require 'slc.str'
end

-- Str's members ----------------------------------------------------------------------------------

local methods = {}

-- with one side known while compiling, the words that unroll over it
local function pick(name, known_second, a, b)
    if known_second and not Str.known_text(a) then return L()[name .. '_known'](a, known_second) end
    return L()[name](a, b)
end
function methods.equals(self, other)
    local a, b = as_str(self, 'equals'), as_str(other, 'equals')
    if Str.known_text(a) and not Str.known_text(b) then a, b = b, a end
    return pick('equals', Str.known_text(b), a, b)
end
function methods.starts_with(self, t)
    local s, p = as_str(self, 'starts_with'), as_str(t, 'starts_with')
    return pick('starts_with', Str.known_text(p), s, p)
end
function methods.ends_with(self, t)
    local s, p = as_str(self, 'ends_with'), as_str(t, 'ends_with')
    return pick('ends_with', Str.known_text(p), s, p)
end
function methods.find(self, t)
    local s, n = as_str(self, 'find'), as_str(t, 'find')
    return pick('find', Str.known_text(n), s, n)
end
function methods.compare(self, t) return L().compare(as_str(self, 'compare'), as_str(t, 'compare')) end
function methods.trim(self) return L().trim(as_str(self, 'trim')) end

local function separator(sep)
    if type(sep) == 'string' then
        if #sep ~= 1 then fail('split: the separator is one byte, such as ","', 3) end
        return S.known(U8, sep:byte())
    end
    local s = S.is_staged(sep) and S.value_of(sep, nil, 'split')
    if s and s.T == U8 then return s end
    local kt = s and s.T == T and Str.known_text(s)
    if kt and #kt == 1 then return S.known(U8, kt:byte()) end
    fail('split: the separator is one byte, such as ","', 3)
end
function methods.split(self, sep, body) return L().split(as_str(self, 'split'), separator(sep), body) end
function methods.lines(self, body) return L().lines(as_str(self, 'lines'), body) end

function methods.runes(self, body) return L().runes(as_str(self, 'runes'), body) end

function methods.parse(self, t)
    if not types.is_type(t) or (t.kind ~= 'int' and t ~= types.F64) then
        fail('parse(T) reads an integer type or F64: s:parse(U32)', 3)
    end
    return L()['parse_' .. t.name](as_str(self, 'parse'))
end

-- a NUL-terminated copy for C, lent to body
function methods.cstring(self, body)
    local s = as_str(self, 'cstring')
    local kt = Str.known_text(s)
    if kt then
        if kt:find('\0', 1, true) then fail('cstring: the text holds a NUL byte', 3) end
        return body(S.known(types.CString, kt))
    end
    -- runtime text: copy it to a Text on the data stack, NUL-terminate, lend the
    -- bytes to body. Appending and pushing are the storage words.
    local TextType = Str.Text
    local text = S.decl(TextType, TextType({}), 'cstring_text')
    local p = S.resolve_checked(text)
    local api = Mem.storage_library(TextType)
    api.append(S.Ref(p), s)
    api.push(S.Ref(p), S.known(U8, 0))
    S.bump_checked()
    return S.mcall(text, 'view', function(xs)
        local ptr = S.slice_parts(xs)
        return body(S.dyn(types.CString, { op = 'conv', a = S.ex(ptr), T = types.CString }))
    end)
end

local arities = { equals = 2, starts_with = 2, ends_with = 2, find = 2, compare = 2, trim = 1, split = 3,
                  lines = 2, runes = 2, parse = 2, cstring = 2 }
for k, f in pairs(methods) do S.arity[f] = arities[k] end

function S.member_str(x, key)
    if key == 'length' then
        local _, len = S.slice_parts(x)
        return len
    end
    if type(key) == 'number' or S.is_staged(key) then
        -- a byte of known text at a known index is known
        local kt = Str.known_text(x)
        local iv = type(key) == 'number' and S.known(U32, key) or S.value_of(key, nil, 'index')
        if kt and S.is_value(iv) and iv.k == 'known' then
            local i = tonumber(iv.v)
            if i < 0 or i >= #kt then
                fail(('index-range: index %d is outside text of length %d'):format(i, #kt), 3)
            end
            return S.known(U8, kt:byte(i + 1))
        end
        return S.member_slice(x, key)
    end
    if key == 'sub' then return S.member_slice(x, key) end
    local m = methods[key]
    if m then return m end
    fail(("Str offers length, s[i], sub, equals, starts_with, ends_with, find, compare, trim, split, lines, "
        .. "parse and cstring; not '%s'"):format(tostring(key)), 3)
end

-- Str.of: a view of a Slice U8, an Array of bytes, or a C string
function Str.of(x)
    local v = S.is_staged(x) and S.value_of(x, nil, 'Str.of') or nil
    if not v then
        if type(x) == 'string' then return S.str_literal(x) end
        fail('Str.of takes a Slice U8, a CString or a string', 2)
    end
    if v.T == T then return v end
    if rawget(v.T, 'slice_elem') == U8 then
        local ptr, len = S.slice_parts(v)
        return S.make_slice(T, ptr, len, rawget(v, 'view'))
    end
    if v.T == types.CString then
        if v.k == 'known' then return S.str_literal(v.v) end
        local b = S.cur()
        if b.fn then b.fn.uses_rt = true end
        local ptr = S.dyn(u8p, { op = 'conv', a = S.ex(v), T = u8p })
        local len = require('slc.str').c_length(ptr)
        return S.make_slice(T, b:bind(ptr), len)
    end
    fail('Str.of takes a Slice U8, a CString or a string, got ' .. v.T.display, 2)
end
rawset(T, 'of', Str.of)

-- Chars(n) ---------------------------------------------------------------------------------------

function Str.Chars(n)
    local ok, t = pcall(types.chars, n)
    if not ok then fail((tostring(t):gsub('^[^:]+:%d+: ', '')), 2) end
    if not rawget(t, 'construct_text') then
        rawset(t, 'construct_text', true)
        -- Chars(n) "text" or Chars(n)(s): filled from text; Chars(n)() is empty
        rawset(t, 'construct', function(x)
            if x == nil or (type(x) == 'table' and not S.is_staged(x) and next(x) == nil) then
                return S.zero_value(t)
            end
            local s = as_str(x, t.display)
            local kt = Str.known_text(s)
            if kt and #kt > n then
                fail(('%s holds %d bytes; this text has %d'):format(t.display, n, #kt), 3)
            end
            if not kt and not S.cur().fn then
                fail(t.display .. ' from unknown text needs runtime storage', 3)
            end
            return require('slc.chars').from(t)(s)
        end)
    end
    return t
end

-- c:str() views the text; c.length is its length
function S.member_chars(x, key)
    local t = S.value_of(x, nil, 'Chars').T
    if key == 'length' then
        if S.is_place(x) then return S.cur():read(S.field_place(x, 'len')) end
        local value = S.value_of(x, t, 'Chars.length')
        if value.k == 'agg' then return value.f.len end
        return S.dyn(U32, { op = 'field', a = S.ex(value), name = 'len', T = U32 })
    end
    if key == 'str' then
        return function(self)
            if not S.is_place(self) then fail(t.display .. ':str() views storage: call it on a typed local or a field', 2) end
            local ptr = S.array_pointer(S.field_place(self, 'bytes'))
            local len = S.cur():bind(S.cur():read(S.field_place(self, 'len')))
            return S.make_slice(T, ptr, len)
        end
    end
    return nil
end

-- Text: Grow U8 with text words --------------------------------------------------------------------

local Text = Mem.Grow(U8)
Str.Text = Text

-- A float known while compiling folds to its shortest round-tripping text. The
-- decimal conversion itself is the SLC word in lib/format.slc; only the fold is
-- here, because it must happen while compiling.
function S.float_is_known(value)
    local v = S.value_of(value, nil, 'float')
    return (v.T == types.F64 and S.is_known(v)) and true or false
end
S.arity[S.float_is_known] = 1

function S.float_text(value)
    local v = S.value_of(value, nil, 'float')
    local x = tonumber(v.v)
    for precision = 1, 17 do
        local text = ('%.' .. precision .. 'g'):format(x)
        if tonumber(text) == x or precision == 17 then return S.str_literal(text) end
    end
end
S.arity[S.float_text] = 1

local function show(v)
    if v.T.kind == 'cstr' then return v.v end
end

local text_methods = rawget(Text, 'builtin_methods')
local function append_text(p, text)
    if not S.is_known(text) then
        text = Mem.capture(text, 'capturing text metadata')
    end
    return Mem.storage_library(Text).append(S.Ref(p), text)
end

-- Decimal text known while compiling parses with Lua's number reader; the
-- grammar is the library's (no hex, no inf/nan), and the runtime path is
-- lib/str.slc's strtod call.
local function valid_decimal(text)
    local i, n = 1, #text
    if i <= n and (text:sub(i, i) == '+' or text:sub(i, i) == '-') then i = i + 1 end
    local digits = 0
    while i <= n and text:sub(i, i):match('%d') do digits = digits + 1; i = i + 1 end
    if i <= n and text:sub(i, i) == '.' then
        i = i + 1
        while i <= n and text:sub(i, i):match('%d') do digits = digits + 1; i = i + 1 end
    end
    if digits == 0 then return false end
    if i <= n and (text:sub(i, i) == 'e' or text:sub(i, i) == 'E') then
        i = i + 1
        if i <= n and (text:sub(i, i) == '+' or text:sub(i, i) == '-') then i = i + 1 end
        local exponent = 0
        while i <= n and text:sub(i, i):match('%d') do exponent = exponent + 1; i = i + 1 end
        if exponent == 0 then return false end
    end
    return i > n
end

function S.parse_float_known_p(v)
    local vv = S.value_of(v, nil, 'parse')
    return (vv.T == T and Str.known_text(vv) ~= nil) and true or false
end
S.arity[S.parse_float_known_p] = 1

function S.parse_float_known(v)
    local vv = S.value_of(v, nil, 'parse')
    local text = Str.known_text(vv)
    local P = require('slc.str').parsed(types.F64)
    if text == nil or not valid_decimal(text) then return P.bad() end
    local n = tonumber(text)
    if n == nil then return P.bad() end
    return P.value(types.F64(n))
end
S.arity[S.parse_float_known] = 1

-- t:write(a, b, ...): each value as text, known pieces joined while compiling
text_methods.write = function(self, ...)
    local p = Mem.receiver(self, 'Text:write')
    Mem.check_structural(p, 'writing to a Text')
    local b = S.cur()
    if not b.fn then fail('a Text is runtime storage: it is written where it runs', 2) end
    b.fn.uses_rt = true
    local pending = {}
    local function flush()
        if #pending == 0 then return end
        local s = table.concat(pending)
        pending = {}
        local lit = S.str_literal(s)
        S.bump_checked()
        append_text(p, lit)
    end
    local n = select('#', ...)
    for i = 1, n do
        local x = select(i, ...)
        -- Host literals enter the same SLC formatting words as typed operands.
        -- Preserve floating negative zero rather than coercing it to integer 0.
        if type(x) == 'boolean' then x = S.known(types.Bool, x)
        elseif type(x) == 'number' and x == math.floor(x) and math.abs(x) < 2 ^ 53
            and not (x == 0 and 1 / x == -math.huge) then x = types.I64(x)
        elseif type(x) == 'number' then x = types.F64(x) end
        if type(x) == 'string' then
            pending[#pending + 1] = x
        elseif type(x) == 'number' then
            pending[#pending + 1] = show(S.known(types.F64, x))
        else
            local v = S.value_of(x, nil, 'write')
            if v.T.kind == 'int' or v.T.kind == 'bool' then
                local format = require('slc.format')
                if v.T.kind == 'bool' then v = format.boolean(v)
                else
                    local result = v.T.signed and format.i64(types.I64(v)) or format.u64(types.U64(v))
                    local digits = S.decl(result.T, result, 'formatted')
                    v = S.mcall(digits, 'str')
                end
            end
            local kt = v.T == T and Str.known_text(v)
            if kt then
                pending[#pending + 1] = kt
            elseif v.T.kind == 'float' then
                flush()
                local result = require('slc.format').f64(types.F64(v))
                local digits = S.decl(result.T, result, 'formatted_float')
                S.bump_checked()
                append_text(p, S.mcall(digits, 'str'))
            elseif v.k == 'known' and show(v) then
                pending[#pending + 1] = show(v)
            else
                flush()
                S.bump_checked()
                local tk = v.T.kind
                if v.T == T then
                    append_text(p, v)

                elseif tk == 'cstr' then
                    local s = Str.of(v)
                    append_text(p, s)
                else
                    fail(('write: cannot write a %s as text (numbers, Bool, Str, CString)'):format(v.T.display), 2)
                end
            end
        end
    end
    flush()
end

text_methods.clear = function(self)
    local p = Mem.receiver(self, 'Text:clear')
    Mem.check_structural(p, 'clearing a Text')
    S.bump_checked()
    local b = S.cur()
    if b.fn then b.fn.uses_rt = true end
    Mem.storage_library(Text).clear(S.Ref(p))
end

-- t:str() do(s) ... end: the text as a Str, while it cannot change
text_methods.str = function(self, body)
    return text_methods.view(self, function(xs)
        local ptr, len = S.slice_parts(xs)
        return body(S.make_slice(T, ptr, len, rawget(xs, 'view')))
    end)
end
S.arity[text_methods.write] = nil
S.arity[text_methods.clear] = 1
S.arity[text_methods.str] = 2

-- names for programs
function Str.prelude(env)
    env.Str = T
    env.Text = Text
    env.Chars = Str.Chars
end

return Str
