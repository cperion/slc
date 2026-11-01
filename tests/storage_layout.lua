-- Layout proofs concern the residual program, not source-level constness.
local T = require 'slc.types'
local G = require 'slc.cgen'
local L = require 'slc.layout'
local R = T.struct('LayoutRecord', { { 'config', T.U32 }, { 'count', T.U32 } })
local Outer = T.struct('LayoutOuter', { { 'inner', R }, { 'config', T.U32 } })
local function local_place(t) return { pk = 'local', T = t } end
local function field(p, name)
    return { pk = 'field', T = p.T.index[name].type, parent = p, fname = name }
end
local r = local_place(R)
local count, config = field(r, 'count'), field(r, 'config')
local function read(p) return { op = 'read', T = p.T, place = p } end
local function expr(e) return { op = 'expr', e = e } end
local function store(p) return { op = 'store', place = p, e = { op = 'zero', T = p.T } } end
local function fn(body, params, ret)
    return { body = body, params = params or {}, ret = ret or T.Unit }
end
local function analyze(...)
    return L.analyze({ ... }, G.walk_block)
end
local function compact(layouts, t, names)
    local fs = assert(layouts[t], 'expected a compact layout for ' .. tostring(t))
    assert(#fs == #names)
    for i, name in ipairs(names) do assert(fs[i].name == name) end
end
local base = fn { store(count), expr(read(count)) }
compact(analyze(base), R, { 'count' })
assert(not analyze(base, fn { store(config) })[R], 'a write in another instance/function retains storage')
assert(not analyze(base, fn { expr(read(config)) })[R], 'unknown reads retain storage')
assert(not analyze(base, fn { store(r) })[R], 'whole-record writes retain storage')
assert(not analyze(base, fn { expr(read(r)) })[R], 'whole-record reads retain storage')
assert(not analyze(base, fn { expr { op = 'agg', T = R, fields = {} } })[R])
assert(not analyze(base, fn { expr { op = 'const', T = R, v = {} } })[R])
local o = local_place(Outer)
compact(analyze(fn { store(field(field(o, 'inner'), 'count')) }), Outer, { 'inner' })
compact(analyze(fn { store(field(field(o, 'inner'), 'count')) }), R, { 'count' })
local exported = fn({}, { { T = Outer } }); exported.exported = true
assert(not analyze(base, exported)[R], 'exported containment preserves nested layouts')
local callback = fn({}, {}, R); callback.addr_taken = true
assert(not analyze(base, callback)[R], 'callbacks preserve return layouts')
for _, ptr in ipairs { T.ptr(R), T.ref(R), T.ptr(T.array(R, 2)) } do
    assert(not analyze(base, fn({}, { { T = ptr } }))[R], 'pointer reachability preserves layout')
end
assert(not analyze(base, fn { expr { op = 'addr', T = T.ref(T.U32), place = config } })[R],
    'a field address preserves its containing record')
assert(not analyze(base, fn { expr { op = 'sizeof', T = T.U64, sizeof = R } })[R])
assert(not analyze(base, fn { expr { op = 'gaddr', global = { T = R } } })[R])
assert(not analyze(base, fn { expr { op = 'call', T = T.Unit,
    ext = { ret = T.Unit, params = { Outer } }, args = {} } })[R], 'foreign by-value ABI')
local foreign = T.struct('LayoutForeign', { { 'inner', R } }); foreign.foreign = '<test.h>'
assert(not analyze(base, fn({}, { { T = foreign } }))[R])
local recursive = T.struct('LayoutRecursive', {})
recursive.fields = { { name = 'next', type = T.ptr(recursive) } }
analyze(fn({}, { { T = recursive } })) -- recursive pointer graphs terminate
-- Sum payload projections include an untyped synthetic union member.
local sum = T.sum('LayoutSum', { { 'record', R }, { 'empty', T.Unit } })
local payload = { op = 'field', name = 'record', T = R,
    a = { op = 'field', name = 'as', a = { op = 'param', T = sum, name = 'value' } } }
assert(not analyze(base, fn { expr(payload) })[R])
-- Shared source types remain unchanged when modules disagree about visibility.
local small = { storage_layouts = analyze(base) }
local full = { storage_layouts = analyze(base, exported) }
assert(#R.fields == 2 and #L.fields(small, R) == 1 and L.fields(full, R) == R.fields)
compact(analyze(base), R, { 'count' })
print('storage layouts: residual uses, nested ABI reachability and module isolation passed')
