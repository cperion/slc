-- slc.fold: compile-time evaluation of native scalar operations.
--
-- A Known value must equal what the corresponding C operation produces on the
-- target. LuaJIT's own arithmetic is never used where it differs:
--   * integers of 32 bits or less are Lua numbers, computed exactly (64-bit
--     cdata for products) and wrapped to the type's width;
--   * 64-bit integers are int64_t/uint64_t cdata, which wrap like C;
--   * F32 results are rounded through a C float after every operation;
--   * an operation whose C behaviour is undefined (signed overflow, division
--     by zero, oversized shifts, out-of-range float-to-int) is rejected.
--
-- Small integer types (8/16 bits) follow the language's rule, which the C
-- backend makes explicit with casts: compute in 32 bits, then wrap.

local ffi = require 'ffi'
local bit = require 'bit'
local types = require 'slc.types'

local F = {}

local u64 = ffi.typeof 'uint64_t'
local i64 = ffi.typeof 'int64_t'
local TWO32 = 4294967296

local function is_cdata(x) return type(x) == 'cdata' end

-- the canonical range of an integer type, as Lua numbers or cdata
local function limits(t)
    if t.bits == 64 then
        if t.signed then
            return i64(-9223372036854775807LL - 1), i64(9223372036854775807LL)
        end
        return u64(0), u64(18446744073709551615ULL)
    end
    if t.signed then
        local h = 2 ^ (t.bits - 1)
        return -h, h - 1
    end
    return 0, 2 ^ t.bits - 1
end
F.limits = limits

-- wrap an exact Lua integer (|x| < 2^63 in spirit, exact below 2^53) to a width
local function wrap_small(t, x)
    local m = 2 ^ t.bits
    x = x % m
    if t.signed and x >= m / 2 then x = x - m end
    return x
end

-- wrap any integer-like (number or 64-bit cdata) into t
local function wrap(t, x)
    if t.bits == 64 then
        if t.signed then return ffi.cast(i64, x) end
        -- a negative Lua number goes through int64_t: converting a negative double
        -- straight to uint64_t is not modular (it gives 2^63 on x86-64)
        if type(x) == 'number' and x < 0 then return ffi.cast(u64, ffi.cast(i64, x)) end
        return ffi.cast(u64, x)
    end
    if is_cdata(x) then
        -- reduce a 64-bit cdata modulo 2^bits exactly, through unsigned bits
        local m = ffi.cast(u64, x) % u64(2 ^ t.bits)
        return wrap_small(t, tonumber(m))
    end
    return wrap_small(t, x)
end
F.wrap = wrap

local function round_f32(x) return tonumber(ffi.cast('float', x)) end

-- host numbers: Lua literals in programs ------------------------------------------------

-- Turn a host value into the Known representation of t, or nil + reason.
function F.from_host(t, x)
    if t.kind == 'cstr' then
        if type(x) == 'string' then return x end
        return nil, ('expected a CString (a Lua string), got %s'):format(tostring(x))
    end
    if t.kind == 'bool' then
        if type(x) == 'boolean' then return x end
        return nil, ('expected a Bool, got %s'):format(tostring(x))
    end
    if t.kind == 'int' then
        if is_cdata(x) then
            local ok, v = pcall(tonumber, x)
            if not ok then return nil, 'not a number' end
            -- 64-bit cdata literals: range-check against the target
            local lo, hi = limits(t)
            if t.bits == 64 then
                if (t.signed and ffi.istype(u64, x) and x > u64(hi))
                    or (not t.signed and ffi.istype(i64, x) and x < 0) then
                    return nil, ('%s does not fit in %s'):format(tostring(x), t.display)
                end
                return wrap(t, x)
            end
            x = v
        end
        if type(x) ~= 'number' then
            return nil, ('expected %s, got %s'):format(t.display, tostring(x))
        end
        if x ~= math.floor(x) then
            return nil, ('%s is not an integer, so it cannot be %s'):format(tostring(x), t.display)
        end
        if math.abs(x) > 2 ^ 53 then
            return nil, ('%s is beyond exact Lua integers; build it from %s operations'):format(
                tostring(x), t.display)
        end
        local lo, hi = limits(t)
        if t.bits == 64 then
            if (not t.signed and x < 0) then
                return nil, ('%s does not fit in %s'):format(tostring(x), t.display)
            end
            return t.signed and i64(x) or u64(x)
        end
        if x < lo or x > hi then
            return nil, ('%s does not fit in %s'):format(tostring(x), t.display)
        end
        return x
    end
    if t.kind == 'float' then
        if is_cdata(x) then x = tonumber(x) end
        if type(x) ~= 'number' then
            return nil, ('expected %s, got %s'):format(t.display, tostring(x))
        end
        return t.bits == 32 and round_f32(x) or x
    end
    return nil, ('%s values cannot be written as Lua literals'):format(t.display)
end

-- arithmetic ------------------------------------------------------------------------------

local function ub(msg) error({ slc_ub = msg }, 0) end

local function int_binary(op, t, a, b)
    if t.bits == 64 then
        local zero = t.signed and i64(0) or u64(0)
        if (op == 'div' or op == 'mod') and b == zero then ub('division by zero') end
        if t.signed then
            local lo, hi = limits(t)
            if (op == 'div' or op == 'mod') and a == lo and b == i64(-1) then
                ub(('%s %s -1 overflows'):format(tostring(lo), op == 'div' and '/' or '%'))
            end
            local r
            if op == 'add' then
                r = a + b
                if (b > 0 and r < a) or (b < 0 and r > a) then ub('signed overflow in +') end
            elseif op == 'sub' then
                r = a - b
                if (b < 0 and r < a) or (b > 0 and r > a) then ub('signed overflow in -') end
            elseif op == 'mul' then
                r = a * b
                if a ~= zero and (r / a ~= b or (a == i64(-1) and b == lo)) then
                    ub('signed overflow in *')
                end
            elseif op == 'div' then r = a / b       -- int64 cdata division truncates
            elseif op == 'mod' then r = a % b
                -- LuaJIT % on int64 follows Lua's floor rule; C truncates
                if r ~= zero and ((r < 0) ~= (a < 0)) then r = r - b end
            end
            return r
        end
        local r
        if op == 'add' then r = a + b
        elseif op == 'sub' then r = a - b
        elseif op == 'mul' then r = a * b
        elseif op == 'div' then r = a / b
        elseif op == 'mod' then r = a % b end
        return r
    end

    -- 32 bits or less: exact arithmetic in doubles (products in 64-bit cdata)
    if (op == 'div' or op == 'mod') and b == 0 then ub('division by zero') end
    local r
    if op == 'add' then r = a + b
    elseif op == 'sub' then r = a - b
    elseif op == 'mul' then
        r = a * b
        if math.abs(r) >= 2 ^ 53 then        -- only unsigned 32-bit gets here
            r = tonumber(ffi.cast(u64, a) * ffi.cast(u64, b) % u64(TWO32))
        end
    elseif op == 'div' then
        r = a / b
        r = r < 0 and math.ceil(r) or math.floor(r)   -- C truncates toward zero
    elseif op == 'mod' then
        local q = a / b
        q = q < 0 and math.ceil(q) or math.floor(q)
        r = a - q * b
    end
    if t.signed and t.bits == 32 then
        local lo, hi = limits(t)
        if r < lo or r > hi then ub(('signed overflow in %s'):format(op)) end
        return r
    end
    return wrap_small(t, r)
end

local function bit_binary(op, t, a, b)
    if op == 'shl' or op == 'shr' then
        local n = is_cdata(b) and tonumber(b) or b
        if n < 0 or n >= t.bits then
            ub(('shift by %d is undefined for %s'):format(n, t.display))
        end
        if t.bits == 64 then
            if op == 'shl' then
                if t.signed and (a < 0 or bit.rshift(a, 63 - n) ~= i64(0)) then
                    ub('signed left shift overflows')
                end
                return wrap(t, bit.lshift(a, n))
            end
            return t.signed and bit.arshift(a, n) or bit.rshift(a, n)
        end
        if op == 'shl' then
            local r = a * 2 ^ n
            if t.signed then
                local lo, hi = limits(t)
                if a < 0 or (t.bits == 32 and r > hi) then ub('signed left shift overflows') end
            end
            return wrap(t, r)
        end
        if t.signed then return math.floor(a / 2 ^ n) end   -- arithmetic shift
        return math.floor(a / 2 ^ n)
    end
    if t.bits == 64 then
        local r
        if op == 'band' then r = bit.band(a, b)
        elseif op == 'bor' then r = bit.bor(a, b)
        else r = bit.bxor(a, b) end
        return wrap(t, r)
    end
    local f = op == 'band' and bit.band or op == 'bor' and bit.bor or bit.bxor
    return wrap(t, f(a, b) % TWO32)
end

-- Compute `a op b` in type t. Returns the Known value, or raises {slc_ub=msg}.
function F.binary(op, t, a, b)
    if t.kind == 'int' then
        if op == 'band' or op == 'bor' or op == 'bxor' or op == 'shl' or op == 'shr' then
            return bit_binary(op, t, a, b)
        end
        return int_binary(op, t, a, b)
    end
    if t.kind == 'float' then
        local r
        if op == 'add' then r = a + b
        elseif op == 'sub' then r = a - b
        elseif op == 'mul' then r = a * b
        elseif op == 'div' then r = a / b
        else error(('operator %s is not defined for %s'):format(op, t.display), 0) end
        return t.bits == 32 and round_f32(r) or r
    end
    error(('operator %s is not defined for %s'):format(op, t.display), 0)
end

function F.unary(op, t, a)
    if op == 'neg' then
        if t.kind == 'float' then return t.bits == 32 and round_f32(-a) or -a end
        if t.kind ~= 'int' then error('negation is not defined for ' .. t.display, 0) end
        if not t.signed then return wrap(t, (t.bits == 64 and u64(0) or 0) - a) end
        local lo = limits(t)
        if t.bits >= 32 and a == lo then ub('negating the minimum value overflows') end
        return wrap(t, -a)
    elseif op == 'bnot' then
        if t.kind ~= 'int' then error('~ is not defined for ' .. t.display, 0) end
        if t.bits == 64 then return wrap(t, bit.bnot(a)) end
        return wrap(t, bit.bnot(a) % TWO32)
    elseif op == 'not' then
        return not a
    end
    error('unknown unary ' .. op, 0)
end

function F.compare(op, t, a, b)
    if t.kind == 'bool' and op ~= 'eq' and op ~= 'ne' then
        error('Bool values are only compared with == and ~=', 0)
    end
    if op == 'eq' then return a == b
    elseif op == 'ne' then return a ~= b
    elseif op == 'lt' then return a < b
    elseif op == 'le' then return a <= b
    elseif op == 'gt' then return a > b
    elseif op == 'ge' then return a >= b end
    error('unknown comparison ' .. op, 0)
end

-- C conversion semantics between scalars.
function F.convert(to, from, v)
    if to == from then return v end
    if to.kind == 'bool' then
        if from.kind == 'bool' then return v end
        if is_cdata(v) then return v ~= 0 end
        return v ~= 0
    end
    if from.kind == 'bool' then v = v and 1 or 0; from = types.U8 end
    if to.kind == 'int' then
        if from.kind == 'int' then return wrap(to, v) end
        -- float to int: truncate; out of range is undefined in C
        if v ~= v then ub('converting NaN to ' .. to.display) end
        local tr = v < 0 and math.ceil(v) or math.floor(v)
        local lo, hi = limits(to)
        if to.bits == 64 then
            local flo, fhi = tonumber(lo), tonumber(hi)
            if tr < flo or tr >= fhi + 1 then ub(('%s is out of range for %s'):format(v, to.display)) end
            return to.signed and i64(tr) or u64(tr)
        end
        if tr < lo or tr > hi then ub(('%s is out of range for %s'):format(v, to.display)) end
        return tr
    end
    if to.kind == 'float' then
        local x = tonumber(v)
        return to.bits == 32 and round_f32(x) or x
    end
    error(('cannot convert %s to %s'):format(from.display, to.display), 0)
end

-- C spelling of a constant --------------------------------------------------------------

local function int_text(t, v)
    local s
    if is_cdata(v) then
        s = tostring(v):gsub('U?LL$', '')
    else
        s = ('%.0f'):format(v)
    end
    if t.bits == 64 then
        if t.signed then
            if s == '-9223372036854775808' then return '(-9223372036854775807ll - 1)' end
            return s .. 'll'
        end
        return s .. 'ull'
    end
    if t.signed then
        if t.bits == 32 and s == '-2147483648' then return '(-2147483647 - 1)' end
        return s
    end
    return s .. 'u'
end

local function c_string(v)
    return '"' .. v:gsub('[%c"\\\128-\255]', function(c)
        if c == '"' then return '\\"' end
        if c == '\\' then return '\\\\' end
        if c == '\n' then return '\\n' end
        if c == '\t' then return '\\t' end
        return ('\\%03o'):format(c:byte())
    end) .. '"'
end

function F.c_literal(t, v)
    if t.kind == 'cstr' then return c_string(v) end
    if t.kind == 'bool' then return v and 'true' or 'false' end
    if t.kind == 'int' then return int_text(t, v) end
    if t.kind == 'float' then
        if v ~= v then return t.bits == 32 and 'NAN' or '((double)NAN)' end
        if v == math.huge then return t.bits == 32 and 'INFINITY' or '((double)INFINITY)' end
        if v == -math.huge then return t.bits == 32 and '(-INFINITY)' or '(-(double)INFINITY)' end
        local s = ('%.17g'):format(v)
        if t.bits == 32 then s = ('%.9g'):format(v) end
        if not s:find '[%.eE]' then s = s .. '.0' end
        return t.bits == 32 and (s .. 'f') or s
    end
    error('no C literal for ' .. t.display)
end

-- a string that identifies a Known scalar in specialization keys and diagnostics
function F.show(t, v)
    if t.kind == 'cstr' then return ('%q'):format(v) end
    if t.kind == 'bool' then return tostring(v) end
    if t.kind == 'int' then
        if is_cdata(v) then return (tostring(v):gsub('U?LL$', '')) end
        return ('%.0f'):format(v)
    end
    if t.kind == 'float' then return ('%.17g'):format(v) end
    return tostring(v)
end

-- convert a Known scalar back to a host value (for Lua code that inspects results)
function F.to_host(t, v)
    if t.kind == 'int' and is_cdata(v) then return v end
    return v
end

return F
