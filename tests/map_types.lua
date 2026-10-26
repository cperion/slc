-- Recursive map key/value admissibility, independent of stage initialization.
local T = require 'slc.types'
local function rejects(f, message)
    local ok, err = pcall(f)
    assert(not ok and tostring(err):find(message, 1, true), tostring(err))
end
local Node = T.struct('MapTypeNode', { { 'n', T.U32 } })
local Key = T.struct('MapTypeKey', { { 'label', T.chars(8) }, { 'id', T.id(Node) } })
local Choice = T.sum('MapTypeChoice', { { 'none', T.Unit }, { 'some', Key } })
local Value = T.struct('MapTypeValue', { { 'samples', T.array(T.F64, 4) }, { 'tag', Choice } })
assert(T.map(Key, Value) == T.map(Key, Value))
assert(T.map(Choice, T.U32).resizable)
assert(T.strmap(Value) == T.strmap(Value))
assert(T.map(T.U32, T.U32) ~= T.map(T.U64, T.U32))
assert(T.map_key(T.Duration) and T.map_key(T.Bool))
for _, ty in ipairs { T.F32, T.F64, T.array(T.U8, 4), T.Str, T.CString,
    T.ptr(T.U8), T.ref(Node), T.atomic(T.U32), T.Unit, T.grow(T.U32), T.map(T.U32, T.U32) } do
    rejects(function() T.map(ty, T.U32) end, 'Map key')
end
for _, ty in ipairs { T.Str, T.CString, T.ptr(T.U8), T.ref(Node), T.atomic(T.U32),
    T.Unit, T.grow(T.U32), T.map(T.U32, T.U32) } do
    rejects(function() T.map(T.U32, ty) end, 'Map value')
    rejects(function() T.strmap(ty) end, 'StrMap value')
end
local Borrowed = T.struct('MapTypeBorrowed', { { 'p', T.ptr(T.U8) } })
local Hidden = T.sum('MapTypeHidden', { { 'none', T.Unit }, { 'some', Borrowed } })
assert(not T.map_key(Hidden) and not T.map_value(Hidden))
assert(not T.map_value(T.array(Borrowed, 2)))
local Owner = T.struct('MapTypeOwner', { { 'n', T.U32 }, { 'entries', T.strmap(Value) } })
assert(Owner.resizable and not T.map_value(Owner))
rejects(function() T.struct('MapTypeBadOrder', { { 'entries', T.map(Key, Value) }, { 'n', T.U32 } }) end,
    'must be the last field')
-- Repeated module loads may reuse display names, not native type identity.
local A = T.struct('MapPayloadAgain', { { 'n', T.U32 } })
local B = T.struct('MapPayloadAgain', { { 'n', T.U32 } })
local SA = T.sum('FirstLookup', { { 'found', A }, { 'missing', T.Unit } })
local SB = T.sum('SecondLookup', { { 'found', B }, { 'missing', T.Unit } })
assert(SA ~= SB)
assert(SA == T.sum('AliasLookup', { { 'missing', T.Unit }, { 'found', A } }))
print('map types: recursive key/value rules passed')
