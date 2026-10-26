-- slc.types: native types are compile-time Lua values.
--
-- Every type is a table with a `kind`. Scalars carry their C semantics (width,
-- signedness); constructed types are memoized so `Ref(T) == Ref(T)`.

local T = {}

local Type = {}
Type.__index = Type
T.Type = Type

function Type:__tostring() return self.display end
function T.is_type(x) return getmetatable(x) == Type end

local function new(t)
    return setmetatable(t, Type)
end

-- scalars -----------------------------------------------------------------------------

local function int(bits, signed)
    local name = (signed and 'I' or 'U') .. bits
    return new {
        kind = 'int', bits = bits, signed = signed, display = name, name = name,
        cname = (signed and 'int' or 'uint') .. bits .. '_t',
        wide = bits == 64,                 -- Known values held as 64-bit cdata
        small = bits < 32,                 -- promoted by C: arithmetic needs casts
    }
end

T.U8, T.U16, T.U32, T.U64 = int(8, false), int(16, false), int(32, false), int(64, false)
T.I8, T.I16, T.I32, T.I64 = int(8, true), int(16, true), int(32, true), int(64, true)
-- a span of time in nanoseconds: its own type, so it does not mix with plain counts
T.Duration = int(64, false)
T.Duration.display, T.Duration.name = 'Duration', 'Duration'
T.F32 = new { kind = 'float', bits = 32, display = 'F32', name = 'F32', cname = 'float' }
T.F64 = new { kind = 'float', bits = 64, display = 'F64', name = 'F64', cname = 'double' }
T.Bool = new { kind = 'bool', display = 'Bool', name = 'Bool', cname = 'bool' }
T.Unit = new { kind = 'unit', display = 'Unit', name = 'Unit', cname = 'void' }
-- a C string: `const char *`; a Lua string literal is a known CString
T.CString = new { kind = 'cstr', display = 'CString', name = 'CString', cname = 'const char *' }

-- an opaque C type, usable only behind a Ptr (FILE, DIR, ...)
local opaques = {}
function T.opaque(cname)
    if type(cname) ~= 'string' or not cname:match '^[%a_][%w_]*$' then
        error('opaque expects a C type name, got ' .. tostring(cname), 2)
    end
    if not opaques[cname] then
        opaques[cname] = new { kind = 'opaque', display = cname, name = cname, cname = cname }
    end
    return opaques[cname]
end

T.scalars = { 'U8', 'U16', 'U32', 'U64', 'I8', 'I16', 'I32', 'I64', 'F32', 'F64', 'Bool', 'Unit', 'CString' }

function T.is_int(t) return t.kind == 'int' end
function T.is_float(t) return t.kind == 'float' end
function T.is_numeric(t) return t.kind == 'int' or t.kind == 'float' end
function T.is_scalar(t)
    return t.kind == 'int' or t.kind == 'float' or t.kind == 'bool'
end

-- constructed types -------------------------------------------------------------------

local memo = {}
local function memoized(kind, elem, make)
    memo[kind] = memo[kind] or setmetatable({}, { __mode = 'k' })
    local t = memo[kind][elem]
    if not t then t = new(make()); memo[kind][elem] = t end
    return t
end

local function check_type(x, what)
    if not T.is_type(x) then
        error(what .. ' expects a type, got ' .. tostring(x), 3)
    end
    return x
end

function T.ref(elem)
    check_type(elem, 'Ref')
    return memoized('ref', elem, function()
        return { kind = 'ref', elem = elem, display = 'Ref ' .. elem.display }
    end)
end

function T.ptr(elem)
    check_type(elem, 'Ptr')
    return memoized('ptr', elem, function()
        return { kind = 'ptr', elem = elem, display = 'Ptr ' .. elem.display }
    end)
end

function T.store(elem)
    check_type(elem, 'Store')
    if elem.kind ~= 'struct' and elem.kind ~= 'sum' and not T.is_scalar(elem) then
        error('Store holds fixed-size values, not ' .. elem.display, 2)
    end
    return memoized('store', elem, function()
        return { kind = 'store', elem = elem, display = 'Store ' .. elem.display,
                 resizable = true }
    end)
end

function T.id(elem)
    check_type(elem, 'Id')
    return memoized('id', elem, function()
        return { kind = 'id', elem = elem, display = 'Id ' .. elem.display }
    end)
end

function T.grow(elem)
    check_type(elem, 'Grow')
    if not (T.is_scalar(elem) or elem.kind == 'struct' or elem.kind == 'sum') then
        error('Grow holds fixed-size values, not ' .. elem.display, 2)
    end
    return memoized('grow', elem, function()
        return { kind = 'grow', elem = elem, display = 'Grow ' .. elem.display,
                 resizable = true }
    end)
end

-- structs -----------------------------------------------------------------------------
-- Fields are ordered. At most one resizable field, and it must be last (Goose).

function T.struct(name, fields)
    local t = new { kind = 'struct', name = name, display = name, fields = {},
                    index = {}, methods = {} }
    local resizable
    for i, f in ipairs(fields) do
        local fname, ftype = f[1], f[2]
        if not T.is_type(ftype) then
            error(("field '%s' of struct %s: expected a type, got %s"):format(
                fname, name, tostring(ftype)), 2)
        end
        if t.index[fname] then error(("struct %s: duplicate field '%s'"):format(name, fname), 2) end
        if ftype.kind == 'unit' then error(("struct %s: field '%s' cannot be Unit"):format(name, fname), 2) end
        if ftype.kind == 'opaque' then
            error(("struct %s: field '%s' is the opaque type %s; hold it as Ptr %s"):format(name, fname,
                ftype.display, ftype.display), 2)
        end
        if ftype.kind == 'ref' or rawget(ftype, 'slice_elem') then
            error(("struct %s: field '%s' is a %s; borrows cannot be stored in "
                .. "aggregates (use an Id, or a Ptr at a foreign boundary)"):format(name, fname,
                ftype.kind == 'ref' and 'reference' or 'slice'), 2)
        end
        if resizable then
            error(("struct %s: the resizable field '%s' must be the last field"):format(name, resizable), 2)
        end
        if ftype.resizable or (ftype.kind == 'struct' and ftype.resizable) then
            resizable = fname
        end
        t.fields[i] = { name = fname, type = ftype }
        t.index[fname] = t.fields[i]
    end
    t.resizable = resizable and true or nil
    return t
end

-- atomics ----------------------------------------------------------------------------------------
-- Atomic T: accessed only by atomic operations. In C it is a plain T accessed
-- with the __atomic builtins, so layouts stay the same as C's and the kernel's.

local atomics = {}
function T.atomic(elem)
    if not T.is_type(elem) then error('Atomic expects a type, got ' .. tostring(elem), 2) end
    if not (elem.kind == 'int' or elem.kind == 'bool' or elem.kind == 'ptr') then
        error('Atomic holds an integer, a Bool or a pointer, not ' .. elem.display, 2)
    end
    if not atomics[elem] then
        atomics[elem] = new { kind = 'atomic', elem = elem, display = 'Atomic ' .. elem.display,
                              name = 'Atomic' .. (elem.name or 'Ptr') }
    end
    return atomics[elem]
end

-- fixed-length arrays -----------------------------------------------------------------------------
-- Array(T, n): n elements of a fixed-size T, a value. In C a struct wrapping
-- T e[n], so arrays copy and pass by value as structs do.

local arrays = {}
function T.array(elem, n)
    if not T.is_type(elem) then error('Array expects an element type, got ' .. tostring(elem), 2) end
    if type(n) ~= 'number' or n ~= math.floor(n) or n < 1 or n > 0x7fffffff then
        error(('Array(%s, n): n must be a positive integer known while compiling, got %s'):format(
            elem.display, tostring(n)), 2)
    end
    local k = elem.kind
    if not (k == 'int' or k == 'float' or k == 'bool' or k == 'struct' or k == 'sum' or k == 'array' or k == 'chan')
        or elem.resizable or rawget(elem, 'slice_elem') then
        error(('Array holds fixed-size values, not %s'):format(elem.display), 2)
    end
    arrays[elem] = arrays[elem] or {}
    if not arrays[elem][n] then
        local base = (elem.name or 'T'):gsub('[^%w_]', '_')
        arrays[elem][n] = new { kind = 'array', elem = elem, length = n,
                                display = ('Array(%s, %d)'):format(elem.display, n),
                                name = base .. 'x' .. n }
    end
    return arrays[elem][n]
end

-- channels -------------------------------------------------------------------------------------
-- Chan T: a handle to a channel. What crosses a channel is a copy, so T holds
-- no reference to anyone's memory: no Ref, Ptr, Slice, CString, Id or Atomic.

-- why t cannot cross between tasks, or nil when it can
function T.unsendable(t)
    local k = t.kind
    if k == 'int' or k == 'float' or k == 'bool' or k == 'unit' or k == 'chan' or k == 'pool' or k == 'slot' then
        return nil
    end
    if rawget(t, 'slice_elem') then return 'a slice is a view of memory someone else owns' end
    if k == 'struct' then
        for _, f in ipairs(t.fields) do
            local why = T.unsendable(f.type)
            if why then return ("its field '%s' is a %s: %s"):format(f.name, f.type.display, why) end
        end
        return nil
    end
    if k == 'array' then
        local why = T.unsendable(t.elem)
        if why then return ('its elements are %s: %s'):format(t.elem.display, why) end
        return nil
    end
    if k == 'sum' then
        for _, a in ipairs(t.alts) do
            local why = T.unsendable(a.type)
            if why then return ("its alternative '%s' holds a %s: %s"):format(a.name, a.type.display, why) end
        end
        return nil
    end
    if k == 'ref' then return 'a reference points into memory someone else owns' end
    if k == 'ptr' then return 'a pointer points into memory someone else owns' end
    if k == 'cstr' then return 'a CString points into memory someone else owns' end
    if k == 'atomic' then return 'atomics are shared memory, which tasks do not have' end
    if k == 'id' then return 'an Id names a slot of a store someone else owns' end
    return 'it is not a plain value'
end

local chans = {}
function T.chan(elem)
    if not T.is_type(elem) then error('Chan expects a type, got ' .. tostring(elem), 2) end
    if elem.kind == 'unit' then error('Chan Unit carries nothing; use Chan Bool for a signal', 2) end
    local why = T.unsendable(elem)
    if why then error(('Chan %s: values crossing a channel are copies, and %s'):format(elem.display, why), 2) end
    local where = T.slot_misplaced(elem)
    if where then
        error(('Chan %s: a Slot inside %s cannot move (its ownership would depend on a runtime choice)'):format(
            elem.display, where), 2)
    end
    if not chans[elem] then
        chans[elem] = new { kind = 'chan', elem = elem, display = 'Chan ' .. elem.display,
                            name = 'Chan' .. (elem.name or 'T'), cname = 'slc_chan' }
    end
    return chans[elem]
end

-- pools: slots of T whose ownership moves between tasks (§36.6)
local function holds_slot_inside(t, inside)
    if t.kind == 'slot' then return inside end
    if t.kind == 'struct' then
        for _, f in ipairs(t.fields) do
            local w = holds_slot_inside(f.type, inside)
            if w then return w end
        end
    elseif t.kind == 'sum' then
        for _, a in ipairs(t.alts) do
            local w = holds_slot_inside(a.type, 'a oneof')
            if w then return w end
        end
    elseif t.kind == 'array' then
        return holds_slot_inside(t.elem, 'an array')
    end
    return nil
end
T.slot_misplaced = function(t) return holds_slot_inside(t, nil) end

local pools, slots = {}, {}
function T.pool(elem)
    if not T.is_type(elem) then error('Pool expects a type, got ' .. tostring(elem), 2) end
    local why = T.unsendable(elem)
    if why then error(('Pool %s: slots move between tasks, and %s'):format(elem.display, why), 2) end
    local k = elem.kind
    if not (k == 'int' or k == 'float' or k == 'bool' or k == 'struct' or k == 'sum' or k == 'array')
        or elem.resizable then
        error(('a Pool holds fixed-size values, not %s'):format(elem.display), 2)
    end
    if not pools[elem] then
        pools[elem] = new { kind = 'pool', elem = elem, display = 'Pool ' .. elem.display,
                            name = 'Pool' .. (elem.name or 'T'), cname = 'slc_pool' }
    end
    return pools[elem]
end
function T.slot(elem)
    if not T.is_type(elem) then error('Slot expects a type, got ' .. tostring(elem), 2) end
    if not slots[elem] then
        T.pool(elem)
        slots[elem] = new { kind = 'slot', elem = elem, display = 'Slot ' .. elem.display,
                            name = 'Slot' .. (elem.name or 'T'), cname = 'slc_slot' }
    end
    return slots[elem]
end

-- a tasks scope, as the runtime sees it; never a value of the language
T.Group = new { kind = 'group', display = 'tasks scope', name = 'Group', cname = 'slc_scope *' }

-- slices --------------------------------------------------------------------------------------
-- A read-only view: a pointer and a U32 length. Internally a two-field struct,
-- so the evaluator tracks the length apart from the pointer.

local slices = {}
function T.slice(elem)
    if not T.is_type(elem) then error('Slice expects a type, got ' .. tostring(elem), 2) end
    if elem.kind == 'unit' or elem.kind == 'ref' or elem.resizable then
        error('Slice holds fixed-size values, not ' .. elem.display, 2)
    end
    if slices[elem] then return slices[elem] end
    local base = (elem.kind == 'struct' or elem.kind == 'sum') and elem.name or elem.name or 'T'
    local t = T.struct(base .. 'Slice', { { 'ptr', T.ptr(elem) }, { 'len', T.U32 } })
    t.display = 'Slice ' .. elem.display
    t.slice_elem = elem
    slices[elem] = t
    return t
end

-- sums -------------------------------------------------------------------------------------
-- A finite set of named alternatives, each with a payload type (Unit for none).
-- Alternative order is canonical (by name), so two spellings of the same
-- alternatives are the same type.

local sums = {}

function T.sum(name, alts)
    if #alts == 0 then error('oneof needs at least one named alternative', 2) end
    local list, seen = {}, {}
    for _, a in ipairs(alts) do
        local an, at = a[1], a[2]
        if seen[an] then error(("oneof: duplicate alternative '%s'"):format(an), 2) end
        seen[an] = true
        if not T.is_type(at) then
            error(("oneof: alternative '%s' needs a type, got %s"):format(an, tostring(at)), 2)
        end
        if at.kind == 'ref' then
            error(("oneof: alternative '%s' holds a reference; references cannot be stored in "
                .. "aggregates (use an Id)"):format(an), 2)
        end
        if at.resizable then
            error(("oneof: alternative '%s' is resizable storage; payloads are fixed-size"):format(an), 2)
        end
        list[#list + 1] = { name = an, type = at }
    end
    table.sort(list, function(x, y) return x.name < y.name end)
    local key = {}
    for i, a in ipairs(list) do key[i] = a.name .. '=' .. tostring(a.type) end
    key = table.concat(key, ';')
    if sums[key] then return sums[key] end
    local t = new { kind = 'sum', name = name, display = name, alts = list, index = {} }
    for i, a in ipairs(list) do
        a.tag = i - 1
        t.index[a.name] = a
    end
    sums[key] = t
    return t
end

-- C sizes for the default target (LP64). Used only for diagnostics; layout is
-- left to the C compiler.
function T.fixed(t)
    return not t.resizable
end

return T
