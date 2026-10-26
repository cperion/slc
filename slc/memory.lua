-- slc.memory: Goose-style native storage for the residual program.
--
--   Store T   a managed store of fixed-size T objects; insertion returns an Id T
--   Id T      a generational ID: store token, slot, generation; it never owns
--   Grow T    a resizable array of fixed-size T
--
-- Stores and Grow arrays are resizable: each is created in place in the
-- storage it will live in (`local s: Store T = Store T {}` or a struct field),
-- gets the lowest free data-stack index of its function, and gives its space
-- back when its residual block ends. Resizable values are never copied: they
-- move only by reference (Ref), cannot be assigned, returned or read as values.
-- Their operations are runtime effects: they always stay in the residual code.

local types = require 'slc.types'
local S = require 'slc.stage'

local Mem = {}
local Builder = S.Builder
local dyn, known = S.dyn, S.known
local storage_library

local function fail(msg) S.fail(msg, 2) end

-- C names supplied by the backend: NodeStore, NodeId, U8Grow
local function elem_name(t)
    if t.kind == 'struct' then return require('slc.cgen').ctype(t) end
    return t.name
end

local function cname_of(t)
    if t.kind == 'store' then return elem_name(t.elem) .. 'Store' end
    if t.kind == 'id' then return elem_name(t.elem) .. 'Id' end
    if t.kind == 'grow' then return elem_name(t.elem) .. 'Grow' end
    if rawget(t, 'ctype') then return t.ctype() end
end
Mem.cname_of = cname_of

-- A representation is SLC code, so it belongs to one compilation: a type that
-- outlives a compilation (Text is Grow U8) must not pin a stale descriptor.
-- One layout module serves a whole build, so its records are never duplicated.
local derived = setmetatable({}, { __mode = 'k' })   -- module -> { type -> layout }
local layouts_for = setmetatable({}, { __mode = 'k' })  -- module -> layout instance
local fallback, fallback_externs

-- A build that reuses the module loaded by an earlier compilation must emit the
-- same declarations it would have loaded itself.
local function carry_externs()
    if not fallback_externs then return end
    local have = {}
    for _, x in ipairs(S.module.externs) do have[x] = true end
    for _, x in ipairs(fallback_externs) do
        if not have[x] then
            S.module.externs[#S.module.externs + 1] = x
            have[x] = true
        end
    end
end

local function layouts_module()
    local module = S.module
    local inst = layouts_for[module]
    if inst then return inst end
    local before = #module.externs
    local ok, loaded = pcall(require, 'slc.storage_layout')
    -- Code generation runs after the compilation closes: reuse what staging had.
    if ok then
        fallback, fallback_externs = loaded, { unpack(module.externs, before + 1) }
    else
        carry_externs()
    end
    inst = ok and loaded or fallback
    if not inst then error('no SLC storage layout module is available', 0) end
    layouts_for[module] = inst
    return inst
end
-- every consumer in a build shares one layout module instance
Mem.layouts_module = layouts_module

local function layout_of(t)
    if t.representation then return { layout = t.representation } end
    local cache = derived[S.module]
    if not cache then cache = {}; derived[S.module] = cache end
    local r = cache[t]
    if r then return r end
    local layouts = layouts_module()
    r = { layout = t.kind == 'store' and layouts.Store or t.kind == 'grow' and layouts.Grow or layouts.Id }
    if t.kind == 'store' then
        r.slot = S.struct(cname_of(t) .. 'Slot', { { 'gen', types.U32 }, { 'next', types.U32 }, { 'value', t.elem } })
    end
    cache[t] = r
    return r
end

-- the native representation of a storage type in this compilation
function Mem.representation(t)
    return layout_of(t).layout
end

-- the data stack expression for local index k
local function gs_expr(k) return k == 0 and 'gs_sp' or ('gs_sp + ' .. k) end

-- data-stack indices ------------------------------------------------------------------------

function Builder:gs_alloc(p, release)
    if not self.fn then
        fail('a ' .. p.T.display .. ' is runtime storage; it cannot be created at compile time')
    end
    self.gs_live = self.gs_live or {}
    local k = 0
    while self.gs_live[k] do k = k + 1 end
    local representation = layout_of(p.T).layout
    local fields = release or { 'stack', 'base' }
    local cleanup = require('slc.storage_layout').releaser(representation, fields[1], fields[2])
    local owned_slot = { place = p, k = k, release = function() cleanup(Mem.view(p, representation)) end }
    self.gs_live[k] = owned_slot
    self.gs_owned = self.gs_owned or {}
    local owned = self.gs_owned[self.block]
    if not owned then owned = {}; self.gs_owned[self.block] = owned end
    owned[#owned + 1] = owned_slot
    self.fn.gs_count = math.max(self.fn.gs_count or 0, k + 1)
    return k
end

-- the offset a callee's base takes at this point: past every live index
function Builder:gs_offset()
    local top = -1
    for k in pairs(self.gs_live or {}) do if k > top then top = k end end
    return top + 1
end

-- a residual block ends: its resizable values give their space back
function Builder:gs_close(blk)
    local owned = self.gs_owned and self.gs_owned[blk]
    if not owned then return end
    local last = blk[#blk]
    local reachable_end = not (last and (last.op == 'ret' or last.op == 'goto' or last.op == 'break'))
    for i = #owned, 1, -1 do
        local o = owned[i]
        if reachable_end then
            o.release()
        end
        self.gs_live[o.k] = nil
    end
    self.gs_owned[blk] = nil
end

-- the stage hook: a sub-block finished
local sub = Builder.sub
function Builder:sub(fn, state, kind)
    local blk, st, dead, res = sub(self, function()
        local r = fn()
        self:gs_close(self.block)
        return r
    end, state, kind)
    return blk, st, dead, res
end

-- creating resizable values in place --------------------------------------------------------

local function fresh(t) return setmetatable({ T = t, k = 'fresh' }, S.V) end

function Builder:init_resizable(p, v)
    if not (S.is_value(v) and v.k == 'fresh' and v.T == p.T) then
        fail(("'%s' is a %s: it is created in place, as %s {}"):format(p.name, p.T.display, p.T.display))
    end
    if rawget(p, 'gs_k') then
        fail(("'%s' is a %s; it cannot be assigned again"):format(p.name, p.T.display))
    end
    if rawget(p.T, 'init_storage') then return p.T.init_storage(self, p) end
    local k = self:gs_alloc(p)
    rawset(p, 'gs_k', k)
    storage_library(p.T).layout.init(S.Ref(p), dyn(types.U64, { op = 'stack_index', offset = k, T = types.U64 }))
end

function S.init_resizable(p, v)
    S.cur():init_resizable(p, v)
end

-- operations ---------------------------------------------------------------------------------

-- the place a method receiver denotes (a place, or a reference to one)
local function receiver(x, what)
    if S.is_place(x) then return x end
    if S.is_value(x) and x.k == 'ref' then return x.place end
    fail(what .. ' needs the storage itself (a place or a Ref), got a value')
end

local function addr(p) return { op = 'addr', place = p, T = types.ref(p.T) } end

-- Internal native representation projection: no owner checks or algorithms.
-- Public Ptr still rejects resizable owners; library adapters use this only
-- inside the compiler's existing ownership/checked-place integration.
function Mem.view(x, representation)
    local p = receiver(x, 'native representation')
    local pt = types.ptr(representation)
    return dyn(pt, { op = 'conv', a = addr(p), T = pt })
end
function Mem.record(t, fields)
    local values = {}
    for _, f in ipairs(layout_of(t).layout.fields) do
        values[f.name] = S.ex(S.coerce(fields[f.name], f.type, 'native representation field'))
    end
    return dyn(t, { op = 'agg', T = t, fields = values })
end

-- an operation with effects: emitted where it happens; a result goes through a
-- temporary so its order relative to other effects is fixed
local function capture(value, what)
    local b = S.cur()
    value = S.value_of(value)
    local tmp = b:new_temp(value.T)
    b:emit { op = 'let', place = tmp, e = S.ex(value), what = what }
    return dyn(value.T, S.read_expr(tmp))
end

-- slot borrows: while an activity borrows a slot of a store, nothing may change
-- the store's structure (its slots could move)
local function root(p)
    local q = rawget(p, 'parent')
    while q do p = q; q = rawget(p, 'parent') end
    return p
end

local function check_structural(p, what)
    local b = S.cur()
    for _, q in ipairs(b.slot_borrows or {}) do
        if q == p or root(q).pk == 'deref' or root(p).pk == 'deref' then
            fail(('%s while %s is borrowed (inside :view); its storage could move. '
                .. 'Finish the borrow first'):format(what, q == p and ("'" .. p.name .. "'") or 'resizable storage'))
        end
    end
end

local function contains_store(t, seen)
    seen = seen or {}
    if seen[t] then return false end
    seen[t] = true
    if t.kind == 'store' or t.kind == 'grow' then return true end
    if t.kind == 'ref' then return contains_store(t.elem, seen) end
    if t.kind == 'struct' then
        for _, f in ipairs(t.fields) do if contains_store(f.type, seen) then return true end end
    end
    return false
end

-- a materialized call could reach any store passed to it by reference
local call_materialized = Builder.call_materialized
function Builder:call_materialized(w, args, key)
    if self.slot_borrows and #self.slot_borrows > 0 then
        for _, a in ipairs(args) do
            if S.is_value(a) and a.k == 'ref' and contains_store(a.T) then
                fail(('calling %s with a reference that reaches resizable storage while it is borrowed '
                    .. '(inside :view)'):format(w.name))
            end
        end
    end
    return call_materialized(self, w, args, key)
end

local storage_libraries, storage_module = {}, nil
storage_library = function(t)
    if storage_module ~= S.module then storage_libraries, storage_module = {}, S.module end
    if storage_libraries[t] then return storage_libraries[t] end
    local layout = require('slc.storage_layout')
    layout_of(t)
    local id = t.kind == 'store' and Mem.Id(t.elem)
    if id then layout_of(id) end
    local representation = layout_of(t)
    local p = layout.storage(t, representation.layout, t.elem, representation.slot,
        function(x) return Mem.view(x, representation.layout) end,
        function(fields) return Mem.record(id, fields) end, S.id_components)
    local library = require('slc.storage')
    local api = t.kind == 'store' and library.store(t, id, p) or library.grow(t, p)
    api.layout = p
    storage_libraries[t] = api
    return api
end

Mem.storage_library = storage_library

local function store_methods(t)
    local n = cname_of(t)
    local elem, id = t.elem, types.id(t.elem)
    return {
        add = function(self, v)
            local p = receiver(self, n .. ':add')
            check_structural(p, 'adding to a store')
            S.bump_checked()
            local val = S.coerce(v, elem, 'value added to ' .. t.display)
            val = capture(val, 'capturing a store value')
            return storage_library(t).add(S.Ref(p), val)
        end,
        remove = function(self, i)
            local p = receiver(self, n .. ':remove')
            check_structural(p, 'removing from a store')
            S.bump_checked()
            return storage_library(t).remove(S.Ref(p), S.coerce(i, id, 'Id to remove'))
        end,
        has = function(self, i)
            local p = receiver(self, n .. ':has')
            return storage_library(t).has(S.Ref(p), S.coerce(i, id, 'Id'))
        end,
    }
end

local function grow_methods(t)
    local n = cname_of(t)
    local elem = t.elem
    return {
        -- an activity: the body sees the elements as a read-only slice, and the
        -- Grow cannot grow meanwhile; the slice ends with the view
        view = function(self, body)
            local p = receiver(self, n .. ':view')
            if type(body) ~= 'function' and not S.is_word(body) then
                fail(n .. ':view() needs a body: g:view() do(xs) ... end')
            end
            local st = types.slice(elem)
            local pt = types.ptr(elem)
            local b = S.cur()
            local ptr = storage_library(t).layout.address(S.Ref(p), 0)
            -- the length cannot change while the view lasts (pushing is rejected)
            local len = storage_library(t).layout.get(S.Ref(p), 'len')
            local token = {}
            local xs = S.make_slice(st, b:bind(ptr), b:bind(len), token)
            b.slot_borrows = b.slot_borrows or {}
            table.insert(b.slot_borrows, p)
            local ok, r = pcall(body, xs)
            table.remove(b.slot_borrows)
            token.ended = true
            if not ok then error(r, 0) end
            if S.is_value(r) and rawget(r, 'view') then
                fail('a view of a Grow cannot outlive its view')
            end
            return r
        end,
        push = function(self, v)
            local p = receiver(self, n .. ':push')
            check_structural(p, 'pushing onto a Grow')
            S.bump_checked()
            local val = S.coerce(v, elem, 'value pushed onto ' .. t.display)
            val = capture(val, 'capturing a Grow value')
            return storage_library(t).push(S.Ref(p), val)
        end,
    }
end

-- s[id] and g[i]: an element as a place whose address is computed (and checked:
-- the Id is current, the index in range) at every use, so storage that moves
-- when it grows is found again each time
local function index_place(t)
    local n = cname_of(t)
    return function(x, key)
        local p = receiver(x, t.kind == 'store' and n .. '[id]' or n .. '[i]')
        local kt = t.kind == 'store' and types.id(t.elem) or types.U32
        local k = S.coerce(key, kt, t.kind == 'store' and 'Id' or 'index')
        if not S.is_known(k) then k = capture(k, 'capturing a storage index') end
        local pt = types.ptr(t.elem)
        local function resolve()
            local slot = storage_library(t).borrow(S.Ref(p), k)
            return S.ex(storage_library(t).layout.address(S.Ref(p), slot))
        end
        local b = S.cur()
        if b.fn then b.fn.uses_rt = true end
        return S.checked_place(t.elem, nil, nil, true, resolve,
            n .. '/' .. S.expr_key(addr(p)) .. '/' .. S.expr_key(S.ex(k)))
    end
end

local function length(x)
    local p = receiver(x, 'length')
    local field = p.T.kind == 'store' and 'live' or 'len'
    return storage_library(p.T).layout.get(S.Ref(p), field)
end

-- type constructors ----------------------------------------------------------------------------

-- Text is Grow U8 with text methods of its own: decorating again must add the
-- storage methods to what the type already offers, not replace them.
local function merge_methods(t, methods)
    local have = rawget(t, 'builtin_methods')
    if not have then return methods end
    for k, f in pairs(methods) do have[k] = f end
    return have
end
local function merge_properties(t, properties)
    local have = rawget(t, 'properties')
    if not have then return properties end
    for k, f in pairs(properties) do have[k] = f end
    return have
end

-- Storage types are interned across compilations, but their methods close over
-- SLC words of one compilation: decorate again for each one.
local function decorate(t)
    if rawget(t, 'decorated_for') == S.module then return t end
    rawset(t, 'decorated_for', S.module)
    rawset(t, 'decorated', true)
    rawset(t, 'ctype', function() return cname_of(t) end)
    rawset(t, 'native_layout', function() return layout_of(t).layout end)
    rawset(t, 'cdecl', function() return 'typedef ' .. layout_of(t).layout.cname .. ' ' .. cname_of(t) .. ';' end)
    if t.kind == 'store' then
        local ms = store_methods(t)
        local ar = { add = 2, remove = 2, has = 2 }
        for k, f in pairs(ms) do S.arity[f] = ar[k] end
        rawset(t, 'builtin_methods', merge_methods(t, ms))
        rawset(t, 'index_place', index_place(t))
        rawset(t, 'properties', merge_properties(t, { length = length }))
        rawset(t, 'construct', function(x)
            if type(x) ~= 'table' or S.is_staged(x) or next(x) ~= nil then
                fail(t.display .. ' {} takes no fields')
            end
            return fresh(t)
        end)
    elseif t.kind == 'grow' then
        local ms = grow_methods(t)
        local ar = { push = 2, view = 2 }
        for k, f in pairs(ms) do S.arity[f] = ar[k] end
        rawset(t, 'builtin_methods', merge_methods(t, ms))
        rawset(t, 'index_place', index_place(t))
        rawset(t, 'properties', merge_properties(t, { length = length }))
        rawset(t, 'construct', function(x)
            if type(x) ~= 'table' or S.is_staged(x) or next(x) ~= nil then
                fail(t.display .. ' {} takes no fields')
            end
            return fresh(t)
        end)

    end
    return t
end

local function checked(make, what)
    return function(elem)
        local ok, t = pcall(make, elem)
        if not ok then fail(tostring(t):gsub('^[^:]+:%d+: ', '')) end
        if t.elem.kind == 'struct' and t.elem.resizable then
            fail(what .. ' holds fixed-size values; ' .. t.elem.display .. ' contains resizable storage')
        end
        return decorate(t)
    end
end

-- for slc.strings: Text is Grow U8 with text methods
Mem.receiver, Mem.check_structural, Mem.capture, Mem.addr = receiver, check_structural, capture, addr

Mem.Store = checked(types.store, 'Store')
Mem.Grow = checked(types.grow, 'Grow')
Mem.Id = checked(types.id, 'Id')

-- Private representation projection for library words over opaque handles.
-- No encoding, comparison or hashing policy belongs in this compiler hook.
function S.id_components(x)
    local v = S.value_of(x, nil, 'Id components')
    if v.T.kind ~= 'id' then fail('Id components require an Id') end
    local e = S.ex(v)
    local function field(name, t)
        return S.dyn(t, { op = 'field', a = e, name = name, T = t })
    end
    return field('token', types.U64), field('slot', types.U32), field('gen', types.U32)
end

function Mem.prelude(env)
    env.Store, env.Grow, env.Id = Mem.Store, Mem.Grow, Mem.Id
end

return Mem
