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
end
Mem.cname_of = cname_of

-- the data stack expression for local index k
local function gs_expr(k) return k == 0 and 'gs_sp' or ('gs_sp + ' .. k) end

-- data-stack indices ------------------------------------------------------------------------

function Builder:gs_alloc(p)
    if not self.fn then
        fail('a ' .. p.T.display .. ' is runtime storage; it cannot be created at compile time')
    end
    self.gs_live = self.gs_live or {}
    local k = 0
    while self.gs_live[k] do k = k + 1 end
    self.gs_live[k] = p
    self.gs_owned = self.gs_owned or {}
    local owned = self.gs_owned[self.block]
    if not owned then owned = {}; self.gs_owned[self.block] = owned end
    owned[#owned + 1] = { place = p, k = k }
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
            blk[#blk + 1] = { op = 'rt', text = 'slc_release($P.stack, $P.base);', place = o.place }
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
    local k = self:gs_alloc(p)
    rawset(p, 'gs_k', k)
    self:emit { op = 'rt', place = p, what = 'creating a ' .. p.T.display,
                text = '$P = ' .. cname_of(p.T) .. '_new(' .. gs_expr(k) .. ');' }
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

-- an operation with effects: emitted where it happens; a result goes through a
-- temporary so its order relative to other effects is fixed
local function effect(t, text, args, what, place)
    local b = S.cur()
    local e = { op = 'rt', text = text, args = args, T = t, place = place }
    if t.kind == 'unit' then
        b:emit { op = 'expr', e = e, what = what }
        return nil
    end
    local tmp = b:new_temp(t)
    b:emit { op = 'let', place = tmp, e = e, what = what }
    return dyn(t, S.read_expr(tmp))
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

local function store_methods(t)
    local n = cname_of(t)
    local elem, id = t.elem, types.id(t.elem)
    local function arg_id(x, what)
        return S.ex(S.coerce(x, id, what))
    end
    return {
        add = function(self, v)
            local p = receiver(self, n .. ':add')
            check_structural(p, 'adding to a store')
            S.bump_checked()
            local val = S.coerce(v, elem, 'value added to ' .. t.display)
            return effect(id, n .. '_add($1, $2)', { addr(p), S.ex(val) }, 'a store insertion')
        end,
        remove = function(self, i)
            local p = receiver(self, n .. ':remove')
            check_structural(p, 'removing from a store')
            S.bump_checked()
            return effect(types.Bool, n .. '_remove($1, $2)', { addr(p), arg_id(i, 'Id to remove') },
                'a store removal')
        end,
        has = function(self, i)
            local p = receiver(self, n .. ':has')
            return effect(types.Bool, n .. '_has($1, $2)', { addr(p), arg_id(i, 'Id') }, 'a store lookup')
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
            local ptr = S.dyn(pt, { op = 'rt', text = n .. '_at($1, 0)', args = { addr(p) }, T = pt, pure = true })
            -- the length cannot change while the view lasts (pushing is rejected)
            local len = S.dyn(types.U32, { op = 'rt', text = '$P.len', place = p, T = types.U32, pure = true,
                                           stable = true })
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
            return effect(types.Unit, n .. '_push($1, $2)', { addr(p), S.ex(val) }, 'a push')
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
        local k
        if t.kind == 'store' then
            k = S.ex(S.coerce(key, types.id(t.elem), 'Id'))
        else
            k = S.ex(S.coerce(key, types.U32, 'index'))
        end
        local pt = types.ptr(t.elem)
        local fn = t.kind == 'store' and n .. '_borrow($1, $2)' or n .. '_elem($1, $2)'
        local b = S.cur()
        if b.fn then b.fn.uses_rt = true end
        return S.checked_place(t.elem, { op = 'rt', text = fn, args = { addr(p), k }, T = pt })
    end
end

local function length(x)
    local p = receiver(x, 'length')
    local field = p.T.kind == 'store' and 'live' or 'len'
    return effect(types.U32, '$P.' .. field, {}, 'reading a length', p)
end

-- C declarations ----------------------------------------------------------------------------

local function store_decl(t)
    local n, e = cname_of(t), require('slc.cgen').ctype(t.elem)
    local id = cname_of(types.id(t.elem))
    return (([[
typedef slc_store NAME;
typedef struct NAME_slot { uint32_t gen; uint32_t next; ELEM value; } NAME_slot;
SLC_HELPER NAME NAME_new(size_t stack) { return slc_store_new(stack); }
SLC_HELPER NAME_slot *NAME_at(const NAME *s, uint32_t i) {
    return (NAME_slot *)(void *)(slc_gs(s->stack)->data + s->base) + i;
}
SLC_HELPER ID NAME_add(NAME *s, ELEM v) {
    uint32_t i;
    NAME_slot *slot;
    if (s->free_head != SLC_NONE) {
        i = s->free_head;
        slot = NAME_at(s, i);
        s->free_head = slot->next;
    } else {
        if (slc_gs_top(s->stack) != s->base + (size_t)s->len * sizeof(NAME_slot))
            slc_trap("NAME grew while it was not at the top of its data stack");
        if (s->len >= SLC_RETIRED) slc_trap("NAME is full");
        slc_gs_push(s->stack, sizeof(NAME_slot));
        i = s->len++;
        slot = NAME_at(s, i);
        slot->gen = 1;
    }
    slot->next = SLC_OCCUPIED;
    slot->value = v;
    s->live++;
    ID id;
    id.token = s->token;
    id.slot = i;
    id.gen = slot->gen;
    return id;
}
SLC_HELPER NAME_slot *NAME_find(const NAME *s, ID id) {
    if (id.token != s->token || id.slot >= s->len) return NULL;
    NAME_slot *slot = NAME_at(s, id.slot);
    if (slot->gen != id.gen || slot->next != SLC_OCCUPIED) return NULL;
    return slot;
}
SLC_HELPER bool NAME_has(const NAME *s, ID id) { return NAME_find(s, id) != NULL; }
SLC_HELPER ELEM *NAME_borrow(NAME *s, ID id) {
    NAME_slot *slot = NAME_find(s, id);
    if (!slot) slc_trap("stale or foreign Id in NAME");
    return &slot->value;
}
SLC_HELPER bool NAME_remove(NAME *s, ID id) {
    NAME_slot *slot = NAME_find(s, id);
    if (!slot) return false;
    s->live--;
    if (slot->gen == UINT32_MAX) { slot->next = SLC_RETIRED; return true; } /* never wrap */
    slot->gen++;
    slot->next = s->free_head;
    s->free_head = id.slot;
    return true;
}]]):gsub('NAME', n):gsub('ELEM', e):gsub('ID', id))
end

local function grow_decl(t)
    local n, e = cname_of(t), require('slc.cgen').ctype(t.elem)
    return (([[
typedef slc_grow NAME;
SLC_HELPER NAME NAME_new(size_t stack) { return slc_grow_new(stack); }
SLC_HELPER ELEM *NAME_at(const NAME *g, uint32_t i) {
    return (ELEM *)(void *)(slc_gs(g->stack)->data + g->base) + i;
}
SLC_HELPER void NAME_push(NAME *g, ELEM v) {
    if (slc_gs_top(g->stack) != g->base + (size_t)g->len * sizeof(ELEM))
        slc_trap("NAME grew while it was not at the top of its data stack");
    if (g->len == UINT32_MAX) slc_trap("NAME is full");
    slc_gs_push(g->stack, sizeof(ELEM));
    *NAME_at(g, g->len++) = v;
}
SLC_HELPER ELEM *NAME_elem(NAME *g, uint32_t i) {
    if (i >= g->len) slc_trap("NAME index out of range");
    return NAME_at(g, i);
}
]]):gsub('NAME', n):gsub('ELEM', e))
end

-- type constructors ----------------------------------------------------------------------------

local function decorate(t)
    if rawget(t, 'decorated') then return t end
    rawset(t, 'decorated', true)
    rawset(t, 'ctype', function() return cname_of(t) end)
    if t.kind == 'store' then
        local ms = store_methods(t)
        local ar = { add = 2, remove = 2, has = 2 }
        for k, f in pairs(ms) do S.arity[f] = ar[k] end
        rawset(t, 'builtin_methods', ms)
        rawset(t, 'index_place', index_place(t))
        rawset(t, 'properties', { length = length })
        rawset(t, 'cdecl', function() return store_decl(t) end)
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
        rawset(t, 'builtin_methods', ms)
        rawset(t, 'index_place', index_place(t))
        rawset(t, 'properties', { length = length })
        rawset(t, 'cdecl', function() return grow_decl(t) end)
        rawset(t, 'construct', function(x)
            if type(x) ~= 'table' or S.is_staged(x) or next(x) ~= nil then
                fail(t.display .. ' {} takes no fields')
            end
            return fresh(t)
        end)
    elseif t.kind == 'id' then
        rawset(t, 'cdecl', function() return 'typedef slc_id ' .. cname_of(t) .. ';' end)
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

Mem.Store = checked(types.store, 'Store')
Mem.Grow = checked(types.grow, 'Grow')
Mem.Id = checked(types.id, 'Id')

function Mem.prelude(env)
    env.Store, env.Grow, env.Id = Mem.Store, Mem.Grow, Mem.Id
end

return Mem
