-- Native layout/ownership hooks. All collection algorithms are SLC words.
local S = require 'slc.stage'
local types = require 'slc.types'
local Mem = require 'slc.memory'
local G = require 'slc.cgen'
local Maps = {}
local function fail(s) S.fail(s, 2) end

-- Map types are interned across compilations; their methods and entry structs
-- belong to one, so decorate again for each compilation.
local function decorate(t)
    if rawget(t, 'map_decorated_for') == S.module then return t end
    t.map_decorated_for = S.module
    t.map_decorated = true
    local is_str = t.kind == 'strmap'
    local prefix = is_str and 'StrMap' or ('Map_' .. G.ctype(t.key):gsub('[^%w_]', '_'))
    local n = S.unique_global(prefix .. '_' .. G.ctype(t.elem):gsub('[^%w_]', '_'))
    t.ctype = function() return n end
    local stored_key = is_str and S.struct(n .. 'Bytes', { { 'offset', types.U64 }, { 'len', types.U32 } }) or t.key
    t.entry = S.struct(n .. 'Entry', { { 'hash', types.U64 }, { 'key', stored_key }, { 'value', t.elem } })
    t.lookup = S.oneof(n .. 'Lookup', { { 'found', t.elem }, { 'missing', types.Unit } })
    local layouts = Mem.layouts_module()
    t.representation = is_str and layouts.StrMap or layouts.Map
    t.cdecl = function() return 'typedef ' .. t.representation.cname .. ' ' .. n .. ';' end
    local storage
    t.init_storage = function(b, p)
        local table_stack = b:gs_alloc(p, is_str and { 'entries.stack', 'entries.base' } or nil)
        local arena_stack = is_str and b:gs_alloc(p, { 'arena_stack', 'arena_base' }) or table_stack
        rawset(p, 'gs_k', table_stack)
        local function index(k) return S.dyn(types.U64, { op = 'stack_index', offset = k, T = types.U64 }) end
        storage.init(S.Ref(p), index(table_stack), index(arena_stack))
    end
    t.construct = function(x)
        if type(x) ~= 'table' or S.is_staged(x) or next(x) then fail(t.display .. ' {} takes no fields') end
        return setmetatable({ T = t, k = 'fresh' }, S.V)
    end
    local function receiver(x) return Mem.receiver(x, t.display) end
    local function ex(x) return S.ex(S.value_of(x)) end
    local function key(x)
        return is_str and require('slc.strings').as_str(x, 'StrMap key') or S.coerce(x, t.key, 'Map key')
    end
    local function capture_key(kv)
        if S.is_known(kv) then return kv end
        local view = rawget(kv, 'view')
        kv = Mem.capture(kv, 'capturing a map key')
        if view then rawset(kv, 'view', view) end
        return kv
    end
    storage = layouts.maps(t, t.entry, function(x) return Mem.view(receiver(x), t.representation) end)
    local function library() return require('slc.map').library(t, storage, t.entry, t.lookup, is_str) end
    local ms = {}
    for _, method in ipairs { 'has', 'find', 'remove' } do
        ms[method] = function(self, k)
            if method == 'remove' then S.bump_checked() end
            return library()[method](S.Ref(receiver(self)), key(k))
        end
    end
    for _, method in ipairs { 'put', 'ensure' } do
        ms[method] = function(self, k, value)
            local p, kv = receiver(self), capture_key(key(k))
            -- Eager by-value capture, including ensure's unused replacement.
            local v = Mem.capture(S.coerce(value, t.elem, 'Map value'), 'capturing a map value')
            S.bump_checked()
            return library().put(S.Ref(p), kv, v, method == 'ensure')
        end
    end
    storage.visit = function(self, slot, body)
        local entry = storage.read(self, storage.get(self, 'base'), slot)
        local k, v = storage.key(self, entry), S.dot(entry, 'value')
        if is_str then
            local ptr, len = S.slice_parts(k)
            local token = {}
            k = S.make_slice(types.Str, ptr, len, token)
            local ok, err = pcall(body, k, v)
            token.ended = true
            if not ok then error(err, 0) end
        else body(k, v) end
    end
    S.arity[storage.capacity], S.arity[storage.occupied], S.arity[storage.visit] = 1, 2, 3
    ms.each = function(self, body)
        if type(body) ~= 'function' and not S.is_word(body) then fail(t.display .. ':each needs an activity') end
        local b, p = S.cur(), receiver(self)
        local state = {}; for k, v in pairs(b.state) do state[k] = v end
        local block, after, dead = b:sub(function()
            local guard = b:new_local(Mem.Grow(types.U8), 'map_iter')
            local stack = b:gs_alloc(guard)
            storage.iter(S.Ref(p), Mem.view(guard, layouts.Grow),
                S.dyn(types.U64, { op = 'stack_index', offset = stack, T = types.U64 }))
            require('slc.map').each(t, storage, body)(S.Ref(p))
        end, state, 'known')
        for _, statement in ipairs(block) do b.block[#b.block + 1] = statement end
        b.state, b.dead = after, dead
        S.bump_checked()
    end
    for name, fn in pairs(ms) do S.arity[fn] = (name == 'put' or name == 'ensure') and 3 or 2 end
    t.builtin_methods = ms
    t.properties = { length = function(self) return storage.get(self, 'len') end }
    t.index_place = function(self, k)
        local p, kv = receiver(self), capture_key(key(k))
        local function resolve()
            local slot = library().borrow(S.Ref(p), kv)
            return ex(storage.address(S.Ref(p), slot))
        end
        return S.checked_place(t.elem, nil, nil, not is_str, resolve,
            n .. '/' .. S.expr_key(Mem.addr(p)) .. '/' .. S.expr_key(ex(kv)))
    end
    return t
end
function Maps.Map(k, v)
    local ok, t = pcall(types.map, k, v)
    if not ok then fail(tostring(t):gsub('^[^:]+:%d+: ', '')) end
    return decorate(t)
end
function Maps.StrMap(v)
    local ok, t = pcall(types.strmap, v)
    if not ok then fail(tostring(t):gsub('^[^:]+:%d+: ', '')) end
    return decorate(t)
end
local function known_description(t, entries)
    if type(entries) ~= 'table' or S.is_staged(entries) then fail('known map needs an entry list') end
    local count = #entries
    if count > 0xffffffff then fail('known map is full') end
    for index in pairs(entries) do
        if type(index) ~= 'number' or index % 1 ~= 0 or index < 1 or index > count then
            fail('known map needs a dense entry list')
        end
    end
    local str = t.kind == 'strmap'
    local strings = require 'slc.strings'
    local function key(x)
        return str and strings.as_str(x, 'known StrMap key') or S.coerce(x, t.key, 'known Map key')
    end
    local copied = {}
    local equal = require('slc.key').equal(t.key)
    for i = 1, count do
        local pair = entries[i]
        if type(pair) ~= 'table' or S.is_staged(pair) or pair[1] == nil or pair[2] == nil then
            fail('known map entry ' .. i .. ' needs a key and value')
        end
        local k, v = key(pair[1]), S.coerce(pair[2], t.elem, 'known map value')
        if not S.is_known(k) or not S.is_known(v) then fail('known map keys and values must be known') end
        -- A known owner-backed text view must become immutable bytes, not a
        -- retained view of a local that may subsequently change.
        if str then k = strings.as_str(S.known_text(k), 'known StrMap key') end
        for j = 1, i - 1 do
            if S.host(equal(k, copied[j][1])) then fail('duplicate semantic key in known map at entry ' .. i) end
        end
        copied[i] = { k, v }
    end
    local api = require('slc.map').known(t.key, t.elem, t.lookup, copied)
    local object = newproxy(true)
    local function checked(_, k)
        k = key(k)
        if S.is_known(k) and not S.host(api.has(k)) then fail('map-key: missing key in known map') end
        return api.get(k)
    end
    local methods = {}
    methods.find = function(_, k) return api.find(key(k)) end
    methods.has = function(_, k) return api.has(key(k)) end
    methods.each = function(_, body) return api.each(body) end
    for _, fn in pairs(methods) do S.arity[fn] = 2 end
    local mt = getmetatable(object)
    mt.__slc_index = checked
    mt.__index = function(_, name)
        if name == 'length' then return S.known(types.U32, count) end
        if methods[name] then return methods[name] end
        if name == 'put' or name == 'ensure' or name == 'remove' then fail('known maps are immutable') end
        return checked(object, name)
    end
    mt.__newindex = function() fail('known maps are immutable; indexing yields a value, not a place') end
    mt.__tostring = function() return 'known ' .. t.display end
    return object
end
function Maps.prelude(env)
    local map = setmetatable({ known = function(k, v, entries)
        return known_description(Maps.Map(k, v), entries)
    end }, { __call = function(_, k, v) return Maps.Map(k, v) end })
    local strmap = setmetatable({ known = function(v, entries)
        return known_description(Maps.StrMap(v), entries)
    end }, { __call = function(_, v) return Maps.StrMap(v) end })
    S.arity[map], S.arity[strmap] = 2, 1
    S.arity[map.known], S.arity[strmap.known] = 3, 2
    env.Map, env.StrMap = map, strmap
end
return Maps
