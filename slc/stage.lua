-- slc.stage: online partial evaluation of native words.
--
-- Values are Known (a typed compile-time value), Dynamic (a residual expression),
-- aggregates of either (struct values, tracked field by field), or references
-- to places. Smart constructors fold Known operands and build residual
-- expressions otherwise; control flow runs delayed Lua closures against
-- isolated abstract states; word application inlines by evaluation, and a
-- C function boundary appears only for exports and for re-entry of a
-- specialization key during its own evaluation.

local ffi = require 'ffi'
local types = require 'slc.types'
local fold = require 'slc.fold'
local Arrays = require 'slc.array_value'

local S = {}

-- metatables -------------------------------------------------------------------------------

local V = { __name = 'Value' }        -- known / dyn / agg / ref
local P = { __name = 'Place' }        -- addressable native storage
local W = { __name = 'Word' }         -- a native word (possibly partially applied)
local X = { __name = 'Extern' }       -- a foreign C function
S.V, S.P, S.W, S.X = V, P, W, X

local function is_value(x) return getmetatable(x) == V end
local function is_place(x) return getmetatable(x) == P end
local function is_word(x) return getmetatable(x) == W end
local function is_staged(x)
    local m = getmetatable(x)
    return m == V or m == P
end
S.is_value, S.is_place, S.is_word, S.is_staged = is_value, is_place, is_word, is_staged

local Type = types.Type
local is_type = types.is_type

-- errors carry a clean message located at the innermost line of the program
-- being compiled (the driver sets S.user_source); evaluation rethrows errors
-- across pcalls, so the location is fixed where the error is raised
local current               -- the active builder (declared here for the trail)
local function active_trail()
    local b = current
    if not b or not b.frames or #b.frames == 0 then return '' end
    local out = {}
    for i = 1, #b.frames do                 -- outermost first, deepest last
        local f = b.frames[i]
        local w = f.word
        local name = (w and (w.name or w.cname)) or f.kind or '?'
        local loc = (w and w.loc) or f.loc
        out[#out + 1] = ('\n    in %s%s'):format(tostring(name), loc and (' (' .. tostring(loc) .. ')') or '')
    end
    return table.concat(out)
end

local function fail(msg, level)
    msg = msg .. active_trail()
    if S.user_source then
        for l = 2, 60 do
            local info = debug.getinfo(l, 'Sl')
            if not info then break end
            if info.source == S.user_source and info.currentline and info.currentline > 0 then
                error(S.user_path .. ':' .. info.currentline .. ': ' .. msg, 0)
            end
        end
    end
    error(msg, (level or 1) + 1)
end
S.fail = fail

-- the module being compiled ------------------------------------------------------------

local module
local reset_hooks = {}
-- a host-lifetime type may cache work that belongs to one compilation
function S.on_reset(f) reset_hooks[#reset_hooks + 1] = f end

function S.reset()
    module = {
        functions = {},          -- in creation order
        by_key = {},
        exports = {},
        externs = {},
        names = {},              -- C names in use at file scope
        memo = {},               -- pure Known calls: key -> Value
        uid = 0,
        version = 0,
    }
    S.module = module
    for _, f in ipairs(reset_hooks) do f() end
end
S.reset()

local function uid() module.uid = module.uid + 1; return module.uid end
local function new_version() module.version = module.version + 1; return module.version end

local C_KEYWORDS = {}
for w in ([[auto break case char const continue default do double else enum extern float
for goto if inline int long register restrict return short signed sizeof static struct
switch typedef union unsigned void volatile while bool true false NULL main]]):gmatch '%S+' do
    C_KEYWORDS[w] = true
end

local function sanitize(name)
    name = tostring(name or 'v'):gsub('[^%w_]', '_')
    if name == '' or name:match '^%d' then name = '_' .. name end
    if C_KEYWORDS[name] or name:match '^__' or name:match '^gs_' then name = name .. '_' end
    return name
end
S.sanitize = sanitize

local function unique(set, base)
    base = sanitize(base)
    local name, n = base, 1
    while set[name] do n = n + 1; name = base .. '_' .. n end
    set[name] = true
    return name
end
S.unique_global = function(base) return unique(module.names, base) end

-- values -----------------------------------------------------------------------------------

local function known(t, v) return setmetatable({ T = t, k = 'known', v = v }, V) end
local function dyn(t, e) return setmetatable({ T = t, k = 'dyn', e = e }, V) end
local function agg(t, f) return setmetatable({ T = t, k = 'agg', f = f }, V) end
local function ref(place) return setmetatable({ T = types.ref(place.T), k = 'ref', place = place }, V) end
-- a sum value whose tag is known; its payload has any binding time (nil for Unit)
local function sumv(t, tag, p) return setmetatable({ T = t, k = 'sumv', tag = tag, p = p }, V) end
S.sumv = sumv
S.known, S.dyn, S.agg, S.ref = known, dyn, agg, ref
local function array_value(t, contents)
    return setmetatable({ T = t, k = 'array', contents = contents }, V)
end
S.array_value = array_value

local function is_known(v)
    if not is_value(v) then return false end
    if v.k == 'known' then return true end
    if v.k == 'agg' then
        -- text known while compiling: a literal or a part of one
        if rawget(v.T, 'is_str') then return S.known_text(v) ~= nil end
        for _, f in ipairs(v.T.fields) do
            if not is_known(v.f[f.name]) then return false end
        end
        return true
    end
    if v.k == 'array' then return Arrays.all(v.contents, is_known) end
    if v.k == 'sumv' then local q = rawget(v, 'p'); return q == nil or is_known(q) end
    return false
end
S.is_known = is_known

local function same_value(a, b)
    if a == b then return true end
    if not a or not b or a.T ~= b.T or a.k ~= b.k then return false end
    if a.k == 'known' then return fold.identical(a.T, a.v, b.v) end
    if a.k == 'array' then return Arrays.equal(a.contents, b.contents, same_value) end
    if a.k == 'agg' then
        for _, f in ipairs(a.T.fields) do if not same_value(a.f[f.name], b.f[f.name]) then return false end end
        return true
    end
    if a.k == 'sumv' then return a.tag == b.tag and same_value(rawget(a, 'p'), rawget(b, 'p')) end
    if a.k == 'dyn' then return a.e == b.e end
    return false
end
S.same_value = same_value

local function const(t, v) return { op = 'const', T = t, v = v } end

-- expression size and freedom from mutable storage -------------------------------------------

local function size(e)
    local n = 1
    for k, c in pairs(e) do
        if type(c) == 'table' and k ~= 'T' and k ~= 'place' and k ~= 'fn' and k ~= 'ext'
            and rawget(c, 'op') then n = n + size(c) end
    end
    if e.args then for _, a in ipairs(e.args) do n = n + size(a) end end
    if e.fields then for _, a in pairs(e.fields) do n = n + size(a) end end
    return n
end

-- a pure expression is "free" when it reads no storage that can change under it:
-- constants, parameters, temporaries, loop variables and result variables only
local IMMUTABLE = { temp = true, iv = true, rvar = true, lv = true }
local function free(e)
    if e.op == 'read' then
        return IMMUTABLE[e.place.pk] or e.lv or false
    end
    for k, c in pairs(e) do
        if type(c) == 'table' and k ~= 'T' and k ~= 'place' and k ~= 'fn' and k ~= 'ext'
            and rawget(c, 'op') and not free(c) then return false end
    end
    if e.args then for _, a in ipairs(e.args) do if not free(a) then return false end end end
    if e.fields then for _, a in pairs(e.fields) do if not free(a) then return false end end end
    return true
end
S.free = free

-- builders ---------------------------------------------------------------------------------
-- A builder evaluates native code into one residual C function (fn), or, with
-- fn == nil, purely at compile time (any residual statement is then an error).

local Builder = {}
Builder.__index = Builder

local builders = {}         -- stack, for nested function construction

function S.builder() return current end

local function new_builder(fn)
    return setmetatable({
        fn = fn,
        block = fn and fn.body or {},
        state = {},
        dead = false,
        frames = {},
        regions = {},
        active = {},
        escapes = {},
        lazy = {},
        recursive = {},
        memo = {},
        depth = 0,
    }, Builder)
end

local function push_builder(b)
    builders[#builders + 1] = current
    current = b
end
local function pop_builder()
    current = builders[#builders]
    builders[#builders] = nil
end

local function cur()
    if not current then
        fail('this operation needs a native context (inside a typed word body)', 3)
    end
    return current
end

-- statements, with a check that no read of a place survives a write to it
function Builder:check_reads(e)
    if type(e) ~= 'table' then return end
    if e.op == 'read' and e.ver then
        local en = self.state[e.place]
        if not (en and en.mat and en.ver == e.ver) then
            fail(("'%s' was read and then changed before the read was used; "
                .. "bind the read to a local first"):format(e.place.name), 4)
        end
        return
    end
    for k, c in pairs(e) do
        if type(c) == 'table' and k ~= 'T' and k ~= 'place' and k ~= 'fn' and k ~= 'ext'
            and rawget(c, 'op') then
            self:check_reads(c)
        end
    end
    if e.args then for _, a in ipairs(e.args) do self:check_reads(a) end end
    if e.fields then for _, a in pairs(e.fields) do self:check_reads(a) end end
end

-- expressions are trees of plain tables sharing places, types and functions
local function copy_expr(e, on_read)
    if type(e) ~= 'table' or not rawget(e, 'op') then return e end
    local c = {}
    for k, v in pairs(e) do
        if k == 'args' then
            local a = {}
            for i, x in ipairs(v) do a[i] = copy_expr(x, on_read) end
            c.args = a
        elseif k == 'fields' then
            local f = {}
            for n, x in pairs(v) do f[n] = copy_expr(x, on_read) end
            c.fields = f
        elseif type(v) == 'table' and k ~= 'T' and k ~= 'place' and k ~= 'fn' and k ~= 'ext'
            and rawget(v, 'op') then
            c[k] = copy_expr(v, on_read)
        else
            c[k] = v
        end
    end
    if c.op == 'read' and on_read then on_read(c) end
    return c
end
S.copy_expr = copy_expr

-- statements emitted so far (all builders): the measure `slc size` attributes
local emitted_total = 0
function S.emitted() return emitted_total end

function Builder:emit(stmt)
    emitted_total = emitted_total + 1
    if not self.fn then
        local what = stmt.what or 'a runtime effect'
        fail(('cannot evaluate at compile time: it performs %s'):format(what), 3)
    end
    if self.dead then return end
    for _, k in ipairs { 'e', 'c', 'lo', 'hi' } do
        if stmt[k] then
            self:check_reads(stmt[k])
            -- an emitted statement owns its expressions: later rewrites of
            -- floating values (lazy snapshots) must not reach back into it
            stmt[k] = copy_expr(stmt[k])
        end
    end
    if stmt.args then
        for i, a in ipairs(stmt.args) do self:check_reads(a); stmt.args[i] = copy_expr(a) end
    end
    self.block[#self.block + 1] = stmt
end

-- run fn in a fresh block against a given state; returns the block, end state,
-- whether the path died, and fn's result
function Builder:sub(fn, state, kind)
    local block, st, dead = self.block, self.state, self.dead
    local blk = {}
    self.block, self.state, self.dead = blk, state, false
    self.regions[#self.regions + 1] = kind
    -- each branch arm has its own path (for marks that hold on one path only)
    local path = self.path
    self.path = (path or '') .. '/' .. uid()
    local ok, res = pcall(fn)
    self.path = path
    self.regions[#self.regions] = nil
    local rstate, rdead = self.state, self.dead
    self.block, self.state, self.dead = block, st, dead
    if not ok then error(res, 0) end
    return blk, rstate, rdead, res
end

local function copy(t)
    local r = {}
    for k, v in pairs(t) do r[k] = v end
    return r
end

-- places -----------------------------------------------------------------------------------
-- local / field places of locals are tracked: their abstract value lives in the
-- builder state. Each tracked leaf has an entry:
--     { val = Value, mat = false }    pending: storage need not hold it yet
--     { mat = true, ver = n }          storage holds the value (read it)
--     { uninit = true }                declared, not yet written

local function new_place(t)
    return setmetatable(t, P)
end

local function root_of(p)
    local q = rawget(p, 'parent')
    while q do p = q; q = rawget(p, 'parent') end
    return p
end

local function tracked(p)
    if p.pk == 'temp' or p.pk == 'iv' or p.pk == 'rvar' or p.pk == 'lv' then return false end
    if p.T.kind == 'atomic' then return false end
    -- Indexed children are projections of the whole array state, not separate
    -- tracked cells. Their reads/writes are handled before ordinary storage.
    local q = p
    while q do
        if rawget(q, 'array_owner') then return false end
        q = rawget(q, 'parent')
    end
    if p.T.resizable then return false end
    local r = root_of(p)
    return r.pk == 'local' and not rawget(r, 'escaped')
end
S.tracked = tracked

local function field_place(p, name)
    local ch = rawget(p, 'children')
    if not ch then ch = {}; rawset(p, 'children', ch) end
    local c = ch[name]
    if not c then
        local f = p.T.index[name]
        c = new_place { pk = 'field', T = f.type, parent = p, fname = name,
                        name = p.name .. '.' .. name, id = uid() }
        ch[name] = c
    end
    return c
end
S.field_place = field_place

-- A fixed-index projection can be evaluated against an immutable array value.
-- Keep the actual C place too, for the point where storage becomes observable.
local function array_path(p)
    local owner = rawget(p, 'array_owner')
    if owner then
        local root, path = array_path(owner)
        root, path = root or owner, path or {}
        path[#path + 1] = { index = rawget(p, 'array_index'), kind = 'index' }
        return root, path
    end
    local parent = rawget(p, 'parent')
    if p.pk == 'field' and parent then
        local root, path = array_path(parent)
        if root then
            path[#path + 1] = { name = p.fname, kind = 'field' }
            return root, path
        end
    end
end

local function array_project(value, path, at)
    at = at or 1
    if at > #path then return value end
    local part = path[at]
    if part.kind == 'index' and part.index ~= nil and value.k == 'array' then
        return array_project(Arrays.get(value.contents, part.index), path, at + 1)
    end
    if part.kind == 'field' and value.k == 'agg' then
        return array_project(value.f[part.name], path, at + 1)
    end
end

local function array_replace(value, path, replacement, at)
    at = at or 1
    if at > #path then return replacement end
    local part = path[at]
    if part.kind == 'index' and part.index ~= nil and value.k == 'array' then
        local child = array_replace(Arrays.get(value.contents, part.index), path, replacement, at + 1)
        if child then return array_value(value.T, Arrays.set(value.contents, part.index, child)) end
    elseif part.kind == 'field' and value.k == 'agg' then
        local child = array_replace(value.f[part.name], path, replacement, at + 1)
        if child then
            local fields = copy(value.f)
            fields[part.name] = child
            return agg(value.T, fields)
        end
    end
end

-- every scalar leaf under a place
local function leaves(p, out)
    out = out or {}
    if p.T.kind == 'struct' then
        for _, f in ipairs(p.T.fields) do leaves(field_place(p, f.name), out) end
    else
        out[#out + 1] = p
    end
    return out
end

function Builder:new_local(t, name)
    local fn = self.fn
    local p = new_place { pk = 'local', T = t, name = name or 'v', id = uid(),
                          frame = self.frames[#self.frames], owner = self.fn }
    if fn then fn.locals[#fn.locals + 1] = p end
    for _, l in ipairs(leaves(p)) do self.state[l] = { uninit = true } end
    return p
end

function Builder:new_temp(t, name)
    local p = new_place { pk = 'temp', T = t, name = name or 't', id = uid(), owner = self.fn }
    if self.fn then self.fn.locals[#self.fn.locals + 1] = p end
    return p
end

function Builder:new_var(t, pk, name)
    local p = new_place { pk = pk, T = t, name = name, id = uid(), owner = self.fn }
    if self.fn then self.fn.locals[#self.fn.locals + 1] = p end
    return p
end

-- value -> expression (Known values become constants)
local ex

local function read_expr(p, ver) return { op = 'read', place = p, T = p.T, ver = ver } end

-- a place of another C function: a task, or a word compiled as its own
-- function, reaching into the code around it
local function foreign_place(b, p)
    local o = rawget(root_of(p), 'owner')
    if o and b.fn and o ~= b.fn then
        -- a spawned block sees the outside through copies taken at spawn
        if b.fn.capture then return true end
        if b.fn.task then
            fail(("a task shares no memory: '%s' is a runtime local of the code that spawns it; "
                .. "pass it to spawn, or send it on a channel"):format(root_of(p).name), 4)
        end
        fail(("'%s' is a runtime local of another function; a word compiled as its own C function "
            .. "cannot reach it (pass it as an argument)"):format(root_of(p).name), 4)
    end
end

-- checked places (store[id], g[i], pool[slot]): the lookup is emitted once
-- into a temporary and reused on the same path until something could change
-- what it found (cepoch counts those events)
function Builder:bump_checked() self.cepoch = (self.cepoch or 0) + 1 end
S.bump_checked = function() if current then current:bump_checked() end end

local function checked_root(p)
    local r = root_of(p)
    return rawget(r, 'checked') and r
end

function Builder:resolve_checked(p)
    local r = checked_root(p)
    if not r or not self.fn then return p end
    local c = rawget(r, 'checked')
    self.ccache = self.ccache or {}
    local here = self.path or ''
    local e = self.ccache[c.key]
    if not (c.cache and e and e.epoch == (self.cepoch or 0) and here:sub(1, #e.path) == e.path) then
        -- Library-defined lookup may stage control flow before yielding its
        -- pointer. Resolve it at use, not when a checked reference is captured.
        local call = c.resolve and c.resolve() or c.call
        local t = self:new_temp(call.T)
        rawset(t, 'hint', 'at')
        self:emit { op = 'let', place = t, e = copy_expr(call), what = 'a checked lookup' }
        e = { epoch = self.cepoch or 0, path = here,
              root = new_place { pk = 'deref', T = r.T, name = r.name, ptr = read_expr(t), id = uid() } }
        self.ccache[c.key] = e
    end
    local names, q = {}, p
    while q ~= r do names[#names + 1] = rawget(q, 'fname'); q = rawget(q, 'parent') end
    local out = e.root
    for i = #names, 1, -1 do out = field_place(out, names[i]) end
    return out
end
S.resolve_checked = function(p) return current and current:resolve_checked(p) or p end

-- a structural key for an expression: equal keys compute the same value here
local function expr_key(e)
    if type(e) ~= 'table' then return tostring(e) end
    local op = e.op
    if op == 'const' then return 'k' .. e.T.display .. '=' .. tostring(e.v) end
    if op == 'param' then return 'p' .. e.name .. '@' .. tostring(rawget(e, 'fn')) end
    if op == 'read' or op == 'addr' then
        return op .. rawget(e.place, 'id') .. '#' .. tostring(e.ver)
    end
    local parts = { op, tostring(e.o or e.name or e.text or '') }
    for _, k in ipairs { 'a', 'b', 'e' } do if e[k] then parts[#parts + 1] = expr_key(e[k]) end end
    for _, a in ipairs(e.args or {}) do parts[#parts + 1] = expr_key(a) end
    if e.fields then
        local ks = {}
        for k in pairs(e.fields) do ks[#ks + 1] = k end
        table.sort(ks)
        for _, k in ipairs(ks) do parts[#parts + 1] = k .. '=' .. expr_key(e.fields[k]) end
    end
    return '(' .. table.concat(parts, ' ') .. ')'
end
S.expr_key = expr_key

-- a place found by a checked lookup
function S.checked_place(t, call, name, cache, resolve, key)
    assert(call or (resolve and key), 'a deferred checked place needs its semantic key')
    local p = new_place { pk = 'deref', T = t, name = name or 'element', ptr = call, id = uid() }
    rawset(p, 'checked', { key = key or expr_key(call), call = call, cache = cache ~= false, resolve = resolve })
    return p
end

function Builder:read(p)
    if checked_root(p) then p = self:resolve_checked(p) end
    if foreign_place(self, p) then return S.capture_read(self, p) end
    local array_root, path = array_path(p)
    if array_root then
        local projected = array_project(self:read(array_root), path)
        if projected then return projected end
        self:materialize(array_root)
    end
    if p.T.kind == 'struct' then
        local f = {}
        for _, fd in ipairs(p.T.fields) do f[fd.name] = self:read(field_place(p, fd.name)) end
        return agg(p.T, f)
    end
    if p.T.resizable then
        fail(("'%s' is a %s: it cannot be read or copied as a value; use its operations "
            .. "or pass Ref(...)"):format(p.name, p.T.display), 3)
    end
    if p.T.kind == 'atomic' then
        fail(("'%s' is %s: it is read with :load() (atomics are never read plainly or copied)"):format(
            p.name, p.T.display), 3)
    end
    if tracked(p) then
        local en = self.state[p]
        if not en or en.uninit then
            fail(("'%s' is read before it is written"):format(p.name), 3)
        end
        if en.mat then return dyn(p.T, read_expr(p, en.ver)) end
        return en.val
    end
    return dyn(p.T, read_expr(p))
end

local PENDING_LIMIT = 24

local function pendable(v)
    if v.k == 'known' or v.k == 'array_ptr' then return true end
    if v.k == 'array' then return is_known(v) end
    if v.k == 'sumv' then local q = rawget(v, 'p'); return q == nil or pendable(q) end
    if v.k == 'dyn' then return free(v.e) and size(v.e) <= PENDING_LIMIT end
    return false
end

local h = {}
h.reads_under = function(e, p)
    local found = false
    local function walk(x)
        if type(x) ~= 'table' or found then return end
        if x.op == 'read' and x.place then
            local q = x.place
            while q do if q == p then found = true return end q = rawget(q, 'parent') end
        end
        for k, c in pairs(x) do
            if type(c) == 'table' and k ~= 'T' and k ~= 'place' and k ~= 'fn' and k ~= 'ext'
                and rawget(c, 'op') then walk(c) end
        end
        if x.args then for _, a in ipairs(x.args) do walk(a) end end
        if x.fields then for _, a in pairs(x.fields) do walk(a) end end
    end
    walk(e)
    return found
end

function Builder:store(p, v)
    if checked_root(p) then p = self:resolve_checked(p) end
    if foreign_place(self, p) then
        fail(("'%s' is a copy taken at spawn; a task cannot assign it (declare a local to change it)"):format(
            root_of(p).name), 3)
    end
    if is_value(v) and rawget(v, 'view') then
        fail("a view of a Grow cannot be stored; use it inside its view", 3)
    end
    local array_root, path = array_path(p)
    if array_root then
        if self.dead then return end
        local old = self:read(array_root)
        if is_known(v) then
            local updated = array_replace(old, path, v)
            if updated and is_known(updated) then return self:store(array_root, updated) end
        end
        -- Snapshot the RHS before any overlapping array fields are changed.
        v = self:bind(v)
        self:materialize(array_root)
        self:loop_write(array_root)
        self:invalidate(array_root)
        if tracked(array_root) then self.state[array_root] = { mat = true, ver = new_version() } end
    end
    if p.T.kind == 'struct' and v.k == 'agg' and tracked(p) and not p.T.resizable then
        -- a new value computed from the old one: assign it whole, so every field
        -- reads the old value (C evaluates the compound literal first)
        local selfref = false
        for _, f in ipairs(p.T.fields) do
            local fv = v.f[f.name]
            if fv.k ~= 'known' and not pendable(fv) and h.reads_under(ex(fv), p) then selfref = true break end
        end
        if selfref and not self.dead then
            local e = ex(v)
            for _, l in ipairs(leaves(p)) do self:loop_write(l); self:invalidate(l) end
            self:emit { op = 'store', place = p, e = e, what = 'a store' }
            for _, l in ipairs(leaves(p)) do self.state[l] = { mat = true, ver = new_version() } end
            return
        end
    end
    if p.T.kind == 'struct' then
        if v.k == 'agg' then
            for _, f in ipairs(p.T.fields) do self:store(field_place(p, f.name), v.f[f.name]) end
        else
            v = self:bind(v)
            for _, f in ipairs(p.T.fields) do
                self:store(field_place(p, f.name),
                    dyn(f.type, { op = 'field', a = v.e, name = f.name, T = f.type }))
            end
        end
        return
    end
    if self.dead then return end
    if p.T.resizable then return self:init_resizable(p, v) end
    if p.T.kind == 'atomic' then
        if not self.initializing then
            fail(("'%s' is %s: it is written with :store(v) (only its initialization is a plain store)"):format(
                p.name, p.T.display), 3)
        end
        v = coerce(v, p.T.elem, 'initial value of ' .. p.name)
        self:emit { op = 'store', place = p, e = ex(v), what = 'initializing an atomic' }
        return
    end
    if tracked(p) then
        self:loop_write(p)
        self:invalidate(p)
        if pendable(v) then
            self.state[p] = { val = v, mat = false }
            return
        end
        self:emit { op = 'store', place = p, e = ex(v), what = 'a store' }
        self.state[p] = { mat = true, ver = new_version() }
        return
    end
    self:emit { op = 'store', place = p, e = ex(v), what = 'a store' }
end

-- place p is about to get a new version: values bound lazily from its current
-- contents get their snapshot, written at the point where they were bound
function Builder:invalidate(p)
    local regs = self.lazy[p]
    if not regs then return end
    local en = self.state[p]
    for _, reg in ipairs(regs) do
        if not reg.done and en and en.mat and en.ver == reg.ver then
            reg.done = true
            local t = self:new_temp(p.T)
            reg.hole.op = 'let'
            reg.hole.place = t
            reg.hole.e = read_expr(p)
            for _, node in ipairs(reg.nodes) do node.place = t; node.ver = nil end
        end
    end
end

function Builder:expire(frame)
    if not frame.lazy then return end
    for _, reg in ipairs(frame.lazy) do
        reg.done = true
        local regs = self.lazy[reg.place]
        if regs then
            for i = #regs, 1, -1 do if regs[i] == reg then table.remove(regs, i) end end
            if #regs == 0 then self.lazy[reg.place] = nil end
        end
    end
end

-- write a pending value to storage (into `block`, default the current one)
function Builder:materialize(p, block, state)
    state = state or self.state
    local en = state[p]
    if en and not en.mat and not en.uninit then
        local v = en.val
        if v.k == 'dyn' and v.e.op == 'read' and v.e.place == p then
            -- it already holds that value
            state[p] = { mat = true, ver = new_version() }
            return
        end
        -- Converting an abstract owner address can flush its owner too. Those
        -- writes belong to the same path as this materialization, not the join.
        local saved_block, saved_state = self.block, self.state
        self.block, self.state = block or self.block, state
        local ok, expression = pcall(ex, v)
        self.block, self.state = saved_block, saved_state
        if not ok then error(expression, 0) end
        local stmt = { op = 'store', place = p, e = expression }
        if block then block[#block + 1] = stmt else self:emit(stmt) end
        state[p] = { mat = true, ver = new_version() }
    end
end

function Builder:materialize_all(block, state)
    state = state or self.state
    local ps = {}
    for p, en in pairs(state) do
        if not en.mat and not en.uninit then ps[#ps + 1] = p end
    end
    table.sort(ps, function(a, b) return a.id < b.id end)
    for _, p in ipairs(ps) do self:materialize(p, block, state) end
end

-- a tracked local whose address leaves the evaluator becomes ordinary storage
function Builder:escape(p)
    local r = root_of(p)
    if r.pk ~= 'local' then return end
    -- Escaped is shared across speculative paths; pending stores are not.
    -- A replayed branch must flush its own owner state before taking an address.
    for _, l in ipairs(leaves(r)) do self:materialize(l) end
    for _, l in ipairs(leaves(r)) do self:invalidate(l) end
    if not rawget(r, 'escaped') then
        rawset(r, 'escaped', true)
        self.escapes[#self.escapes + 1] = r
    end
    -- Replayed paths must drop tracking too, or a later loop repeatedly tries
    -- to escape an owner whose global escaped flag was set by an earlier path.
    for _, l in ipairs(leaves(r)) do self.state[l] = nil end
end

-- bind a value that will outlive the current expression: anything reading
-- mutable storage, or too large to duplicate, goes through a temporary
local function eager_temp(self, v)
    local t = self:new_temp(v.T)
    self:emit { op = 'let', place = t, e = v.e }
    return dyn(v.T, read_expr(t))
end

function Builder:bind(v)
    if not is_value(v) then return v end
    if v.k == 'dyn' and not self.fn then return v end
    if v.k == 'dyn' and size(v.e) > PENDING_LIMIT then return eager_temp(self, v) end
    if v.k == 'dyn' and not free(v.e) then
        -- the value reads mutable storage. Reads of tracked places are bound
        -- lazily: a placeholder marks this point, and only if the place is
        -- written while the value is still alive does a snapshot get written
        -- there. Untracked storage (through pointers) is snapshotted now.
        local by_place, untracked = {}, false
        local e = copy_expr(v.e, function(node)
            local p = node.place
            if IMMUTABLE[p.pk] or node.lv then return end
            if not tracked(p) or not node.ver then untracked = true return end
            by_place[p] = by_place[p] or {}
            table.insert(by_place[p], node)
        end)
        if untracked or self.dead then return eager_temp(self, v) end
        local frame = self.frames[#self.frames]
        local ps = {}
        for p in pairs(by_place) do ps[#ps + 1] = p end
        table.sort(ps, function(a, b) return a.id < b.id end)
        for _, p in ipairs(ps) do
            local hole = { op = 'nop' }
            self.block[#self.block + 1] = hole
            local reg = { place = p, nodes = by_place[p], hole = hole, ver = by_place[p][1].ver }
            self.lazy[p] = self.lazy[p] or {}
            table.insert(self.lazy[p], reg)
            if frame then
                frame.lazy = frame.lazy or {}
                frame.lazy[#frame.lazy + 1] = reg
            end
        end
        return dyn(v.T, e)
    end
    if v.k == 'agg' then
        local f = {}
        for k, fv in pairs(v.f) do f[k] = self:bind(fv) end
        local r = agg(v.T, f)
        local view = rawget(v, 'view')
        if view then rawset(r, 'view', view) end     -- a view stays a view
        return r
    end
    return v
end

-- expressions from values ------------------------------------------------------------------

-- an aggregate that is exactly the current contents of one place reads as that place
local function whole_place(v)
    local p
    for _, f in ipairs(v.T.fields) do
        local fv = v.f[f.name]
        local e = fv.k == 'dyn' and fv.e
        if fv.k == 'agg' then
            local q = whole_place(fv)
            if not q or not rawget(q, 'parent') or rawget(q, 'fname') ~= f.name then return nil end
            e = { op = 'read', place = q }
        end
        if not (e and e.op == 'read' and rawget(e.place, 'parent')
            and rawget(e.place, 'fname') == f.name) then return nil end
        local parent = rawget(e.place, 'parent')
        if p and p ~= parent then return nil end
        p = parent
    end
    return p
end

function ex(v)
    if v.k == 'known' then return const(v.T, v.v) end
    if v.k == 'dyn' then return v.e end
    if v.k == 'array_ptr' then
        if foreign_place(cur(), v.place) then fail('a task cannot capture a view of another frame\'s array', 3) end
        v.builder:escape(v.place)
        local base = { op = 'field', a = read_expr(v.place), name = 'e', T = v.place.T }
        local element = new_place { pk = 'index', T = v.place.T.elem, base = base,
                                    idx = ex(v.offset), name = 'element', id = uid() }
        return { op = 'addr', place = element, T = v.T }
    end
    if v.k == 'array' then
        local fields = {}
        for i, value in pairs(v.contents.items) do fields[i] = ex(value) end
        return { op = 'array', T = v.T, fields = fields }
    end
    if v.k == 'agg' then
        local p = whole_place(v)
        if p and not tracked(p) then return read_expr(p) end
        if p and current then
            local ok = true
            for _, l in ipairs(leaves(p)) do
                local en = current.state[l]
                if not (en and en.mat) then ok = false break end
            end
            if ok then return read_expr(p) end
        end
        local f = {}
        for _, fd in ipairs(v.T.fields) do f[fd.name] = ex(v.f[fd.name]) end
        return { op = 'agg', T = v.T, fields = f }
    end
    if v.k == 'ref' then return { op = 'addr', place = v.place, T = v.T } end
    if v.k == 'sumv' then
        local q = rawget(v, 'p')
        return { op = 'sum', T = v.T, alt = v.tag, e = q ~= nil and ex(q) or nil }
    end
    fail('internal: no expression for ' .. tostring(v.k))
end
S.ex = ex

-- coercion ---------------------------------------------------------------------------------

local function type_of(x)
    if is_value(x) or is_place(x) then return x.T end
    return nil
end

-- Library-defined type hooks (__member, __index, __cast, operators) are Lua
-- functions run while specializing. While a type's hook runs, the same type's
-- hooks are not consulted again, so a hook reads its own representation with
-- ordinary field access.
local in_hook = {}
local function run_hook(t, h, ...)
    local saved = in_hook[t]
    in_hook[t] = true
    local ok, a = pcall(h, ...)
    in_hook[t] = saved
    if not ok then error(a, 0) end
    return a
end
-- Built-in kinds are served by the same hooks, registered per family below.
local family_hooks = {}
S.family_hooks = family_hooks
-- hooks whose first argument is the receiver may also be written as methods
local receiver_hooks = { __index = true, __newindex = true }
S.receiver_hooks = receiver_hooks
local function type_hook(x, name)
    local t = type_of(x)
    if t and t.kind == 'ref' then t = t.elem end
    if is_value(x) and x.k == 'ref' then t = x.T.elem end
    if not t then return end
    if not in_hook[t] then
        local h = rawget(t, name)
        if not h and receiver_hooks[name] then
            local m = rawget(t, 'methods')
            h = m and m[name]
        end
        if h then return h, t end
    end
    local fh = family_hooks[rawget(t, 'slice_elem') and 'slice' or t.kind]
    if fh and fh[name] then return fh[name], t, true end
end

local function describe(x)
    if is_value(x) then return x.T.display .. ' value' end
    if is_place(x) then return x.T.display .. ' place' end
    if is_word(x) then return 'word ' .. tostring(x.name) end
    if is_type(x) then return 'the type ' .. x.display end
    return type(x) .. ' ' .. tostring(x)
end

-- the value of anything usable as an operand of type t (t may be nil: infer)
local function value_of(x, t, what)
    -- a Lua string where text is expected: a Str literal
    if t and t.kind == 'struct' and not in_hook[t] then
        local hc = rawget(t, '__cast')
        if hc and type_of(x) ~= t and not (is_value(x) and x.k == 'ref' and x.T.elem == t) then
            local r = run_hook(t, hc, x, t)
            if r ~= nil then x = r end
        end
    end
    if is_place(x) then
        x = cur():read(x)
    end
    if is_value(x) then
        if x.k == 'ref' and (t == nil or t.kind ~= 'ref') then
            if t == nil or t == x.T.elem then return cur():read(x.place) end
        end
        if t and x.T ~= t then
            fail(('%s: expected %s, got %s'):format(what or 'type mismatch', t.display, x.T.display), 3)
        end
        return x
    end
    if t == nil then fail(('%s: cannot use %s here'):format(what or 'operand', describe(x)), 3) end
    if t.kind == 'unit' then
        if x == nil then return nil end
        fail(('%s: expected no value, got %s'):format(what or 'value', describe(x)), 3)
    end
    local v, err = fold.from_host(t, x)
    if v == nil then fail(('%s: %s'):format(what or 'value', err), 3) end
    return known(t, v)
end

-- coerce for binding into a requirement / storage of type t
local function coerce(x, t, what)
    if t.kind == 'ref' then
        if is_place(x) then
            if x.T ~= t.elem then
                fail(('%s: expected a reference to %s, got a %s place'):format(what, t.elem.display, x.T.display), 3)
            end
            return ref(x)
        end
        if is_value(x) and x.k == 'ref' then
            if x.T ~= t then fail(('%s: expected %s, got %s'):format(what, t.display, x.T.display), 3) end
            return x
        end
        fail(('%s: %s needs an addressable place, got %s'):format(what, t.display, describe(x)), 3)
    end
    if t.kind == 'unit' then
        if x ~= nil then fail(('%s: a Unit word returns no value'):format(what), 3) end
        return nil
    end
    if t.kind == 'atomic' then
        -- an atomic is initialized from a value of its element type
        return value_of(x, t.elem, what)
    end
    if t.resizable then
        -- only a constructor, building the storage in place
        if is_value(x) and (x.k == 'fresh' or x.k == 'agg') and x.T == t then return x end
        fail(('%s: a %s moves only by reference; pass Ref(...)'):format(what, t.display), 3)
    end
    return value_of(x, t, what)
end
S.coerce = coerce
S.value_of = value_of
S.describe = describe

-- smart constructors -----------------------------------------------------------------------

local function operand_type(a, b, opname)
    local ta, tb = type_of(a), type_of(b)
    if ta and ta.kind == 'ref' then ta = ta.elem end
    if tb and tb.kind == 'ref' then tb = tb.elem end
    if is_value(a) and a.k == 'ref' then ta = a.T.elem end
    if is_value(b) and b.k == 'ref' then tb = b.T.elem end
    local t = ta or tb
    if ta and tb and ta ~= tb then
        fail(('%s: operands are %s and %s; convert one explicitly'):format(opname, ta.display, tb.display), 4)
    end
    if not t then fail(opname .. ': no native operand', 4) end
    return t
end

local function ub_guard(f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
    if type(r) == 'table' and r.slc_ub then
        fail('compile-time evaluation: ' .. r.slc_ub .. ' (undefined behaviour in C)', 4)
    end
    error(r, 0)
end

local OPSYM = { add = '+', sub = '-', mul = '*', div = '/', mod = '%', band = '&', bor = '|',
                bxor = '^', shl = '<<', shr = '>>' }

local function is_zero(v) return v.k == 'known' and v.v == 0 end
local function is_one(v) return v.k == 'known' and v.v == 1 end

-- operator hooks (__add, __mul, ...): the other operand is converted to the
-- hooked type through its __cast
local function operator_hook(name, a, b, swap)
    local h, t = type_hook(a, name)
    if not h then h, t = type_hook(b, name) end
    if not h then return nil end
    local av = value_of(a, t, 'left operand of ' .. name)
    local bv = value_of(b, t, 'right operand of ' .. name)
    if swap then av, bv = bv, av end
    return true, run_hook(t, h, av, bv)
end

local function binary(op, a, b)
    do
        local ok, r = operator_hook('__' .. op, a, b)
        if ok then return r end
    end
    -- A shift's result type comes from its left operand; the independently
    -- checked integer count must not first pass ordinary operand unification.
    local shift = op == 'shl' or op == 'shr'
    local t = (shift and is_staged(a)) and a.T or operand_type(a, b, OPSYM[op] or op)
    if not types.is_numeric(t) then
        fail(("operator %s is not defined for %s"):format(OPSYM[op] or op, t.display), 3)
    end
    if t.kind == 'float' and (op == 'mod' or op == 'band' or op == 'bor' or op == 'bxor'
        or op == 'shl' or op == 'shr') then
        fail(("operator %s is not defined for %s"):format(OPSYM[op], t.display), 3)
    end
    local bt = t
    if op == 'shl' or op == 'shr' then
        -- the shift count may be any integer type; it is checked, not unified
        bt = (is_staged(b) and b.T.kind == 'int') and b.T or t
    end
    local av = value_of(a, t, 'left operand of ' .. OPSYM[op])
    local bv = value_of(b, bt, 'right operand of ' .. OPSYM[op])
    if av.k == 'known' and bv.k == 'known' then
        local bval = bv.v
        return known(t, ub_guard(fold.binary, op, t, av.v, bval))
    end
    if t.kind == 'int' then
        if op == 'add' then
            if is_zero(av) then return bv end
            if is_zero(bv) then return av end
        elseif op == 'sub' then
            if is_zero(bv) then return av end
        elseif op == 'mul' then
            if is_one(av) then return bv end
            if is_one(bv) then return av end
            if is_zero(av) or is_zero(bv) then return known(t, t.wide and fold.wrap(t, 0) or 0) end
        elseif op == 'div' then
            if is_one(bv) then return av end
            if is_zero(bv) then fail('division by zero (undefined behaviour in C)', 3) end
        elseif op == 'shl' or op == 'shr' then
            if is_zero(bv) then return av end
            if bv.k == 'known' then
                local n = tonumber(bv.v)
                if n < 0 or n >= t.bits then
                    fail(('shift by %d is undefined for %s'):format(n, t.display), 3)
                end
            end
        end
    end
    return dyn(t, { op = 'bin', o = op, a = ex(av), b = ex(bv), T = t })
end
S.binary = binary

local function unary(op, a)
    do
        local h, ht = type_hook(a, op == 'neg' and '__unm' or '__' .. op)
        if h then return run_hook(ht, h, a) end
    end
    local t = type_of(a)
    if is_value(a) and a.k == 'ref' then t = a.T.elem end
    local av = value_of(a, t, 'operand')
    if av.k == 'known' then return known(t, ub_guard(fold.unary, op, t, av.v)) end
    if op == 'neg' and not types.is_numeric(t) then fail('negation is not defined for ' .. t.display, 3) end
    if op == 'not' and t.kind ~= 'bool' then fail("'not' needs a Bool, got " .. t.display, 3) end
    if op == 'not' and av.e.op == 'not' then return dyn(t, av.e.a) end
    return dyn(t, { op = 'un', o = op, a = av.e, T = t })
end
S.unary = unary

local function compare(op, a, b)
    if not (is_staged(a) or is_staged(b)) then
        if op == 'eq' then return a == b elseif op == 'ne' then return a ~= b
        elseif op == 'lt' then return a < b elseif op == 'le' then return a <= b
        elseif op == 'gt' then return a > b else return a >= b end
    end
    do
        -- __eq, __lt, __le; ~=, > and >= derive from them
        local ok, r
        if op == 'eq' or op == 'lt' or op == 'le' then
            ok, r = operator_hook('__' .. op, a, b)
        elseif op == 'ne' then
            ok, r = operator_hook('__eq', a, b)
            if ok then return unary('not', r) end
        elseif op == 'gt' then
            ok, r = operator_hook('__lt', a, b, true)
        elseif op == 'ge' then
            ok, r = operator_hook('__le', a, b, true)
        end
        if ok then return r end
    end
    local t = operand_type(a, b, 'comparison')
    if t.kind == 'id' and (op == 'eq' or op == 'ne') then
        -- IDs compare by token, slot and generation
        local av = value_of(a, t, 'comparison')
        local bv = value_of(b, t, 'comparison')
        local equal = require('slc.key').equal(t)(av, bv)
        if op == 'ne' then return unary('not', equal) end
        return equal
    end
    if (t.kind == 'ptr' or t.kind == 'fn') and (op == 'eq' or op == 'ne') then
        local av = value_of(a, t, 'comparison')
        local bv = value_of(b, t, 'comparison')
        return dyn(types.Bool, { op = 'cmp', o = op, a = ex(av), b = ex(bv), T = types.Bool })
    end
    if t.kind == 'ptr' then fail('pointers are compared only with == and ~=; ordering is not offered', 3) end
    if rawget(t, 'is_str') then fail('text is compared with words, not operators: s:equals(t), s:compare(t)', 3) end
    if rawget(t, 'slice_elem') then fail('slices cannot be compared: two views may name overlapping storage', 3) end
    if not types.is_scalar(t) then fail('cannot compare ' .. t.display .. ' values', 3) end
    local av = value_of(a, t, 'comparison')
    local bv = value_of(b, t, 'comparison')
    if av.k == 'known' and bv.k == 'known' then
        return known(types.Bool, fold.compare(op, t, av.v, bv.v))
    end
    -- comparisons against the edge of the type are tautologies (C warns of them)
    if t.kind == 'int' and (av.k == 'known' or bv.k == 'known') then
        local lo, hi = fold.limits(t)
        local function is(v, lim) return v.k == 'known' and fold.compare('eq', t, v.v, lim) end
        if (is(av, lo) and op == 'le') or (is(bv, lo) and op == 'ge')
            or (is(av, hi) and op == 'ge') or (is(bv, hi) and op == 'le') then
            return known(types.Bool, true)
        end
        if (is(av, lo) and op == 'gt') or (is(bv, lo) and op == 'lt')
            or (is(av, hi) and op == 'lt') or (is(bv, hi) and op == 'gt') then
            return known(types.Bool, false)
        end
    end
    return dyn(types.Bool, { op = 'cmp', o = op, a = ex(av), b = ex(bv), T = types.Bool })
end

function S.eq(a, b) return compare('eq', a, b) end
function S.ne(a, b) return compare('ne', a, b) end
function S.lt(a, b) return compare('lt', a, b) end
function S.le(a, b) return compare('le', a, b) end
function S.gt(a, b) return compare('gt', a, b) end
function S.ge(a, b) return compare('ge', a, b) end

-- bitwise operations are functions: Lua 5.1 has no operators for them
for _, op in ipairs { 'band', 'bor', 'bxor', 'shl', 'shr' } do
    S[op] = function(a, b)
        if not (is_staged(a) or is_staged(b)) then
            local bit = require 'bit'
            local f = ({ band = bit.band, bor = bit.bor, bxor = bit.bxor,
                         shl = bit.lshift, shr = bit.rshift })[op]
            return f(a, b)
        end
        return binary(op, a, b)
    end
end
function S.bnot(a)
    if not is_staged(a) then return require('bit').bnot(a) end
    return unary('bnot', a)
end

-- operators on values and places
for mm, op in pairs { __add = 'add', __sub = 'sub', __mul = 'mul', __div = 'div', __mod = 'mod' } do
    V[mm] = function(a, b) return binary(op, a, b) end
    P[mm] = V[mm]
end
V.__unm = function(a) return unary('neg', a) end
P.__unm = V.__unm
V.__pow = function() fail('^ is not defined for native values; use a foreign pow', 2) end
P.__pow = V.__pow
V.__concat = function(a, b)
    fail('.. is a host operation; native values cannot be concatenated', 2)
end
P.__concat = V.__concat
V.__len = function() fail('# is not defined for native values', 2) end

function V:__tostring()
    if self.k == 'known' then return fold.show(self.T, self.v) end
    if self.k == 'agg' then
        local parts = {}
        for _, f in ipairs(self.T.fields) do parts[#parts + 1] = f.name .. ' = ' .. tostring(self.f[f.name]) end
        return self.T.display .. ' { ' .. table.concat(parts, ', ') .. ' }'
    end
    if self.k == 'ref' then return 'Ref(' .. self.place.name .. ')' end
    if self.k == 'sumv' then
        local q = rawget(self, 'p')
        return self.T.display .. '.' .. self.tag .. (q ~= nil and ('(' .. tostring(q) .. ')') or '()')
    end
    return '<dynamic ' .. self.T.display .. '>'
end
function P:__tostring() return '<place ' .. self.name .. ': ' .. self.T.display .. '>' end

-- member access on values, places and references ----------------------------------------------

local function struct_of(x)
    local t = x.T
    if t.kind == 'ref' then t = t.elem end
    return t
end

local member_ptr, member_slice

local raw_member
local function member(x, key)
    local h, t, family = type_hook(x, '__member')
    if h then
        local r
        if family then r = h(x, key) else r = run_hook(t, h, x, key) end
        if r ~= nil then return r end
    end
    return raw_member(x, key)
end
S.rawmember = function(x, key) return raw_member(x, key) end

function raw_member(x, key)
    local t = struct_of(x)
    local ip = rawget(t, '__index')
    if ip and (type(key) == 'number' or is_staged(key)) then return ip(x, key) end
    if t.kind == 'sum' then
        fail(("%s is a sum: its payload is reached by matching (s { %s = do(p) ... end, ... }), "
            .. "not by selecting '%s'"):format(t.display, t.alts[1].name, tostring(key)), 3)
    end
    if t.kind == 'struct' then
        if t.index[key] then
            if is_place(x) then return field_place(x, key) end
            if x.k == 'ref' then return field_place(x.place, key) end
            if x.k == 'agg' then return x.f[key] end
            if x.k == 'known' then return x.v[key] end
            local ft = t.index[key].type
            return dyn(ft, { op = 'field', a = x.e, name = key, T = ft })
        end
        local m = t.methods[key]
        if m then return m end
    end
    local m = rawget(t, 'methods') and t.methods[key]
    if m then return m end
    fail(("%s has no field or method '%s'"):format(t.display, tostring(key)), 3)
end

-- A type with `properties` (computed members) and `builtin_methods` serves them
-- through __member; the tables stay live so a later decoration can extend them.
function S.member_tables(t)
    rawset(t, '__member', function(x, key)
        local props = rawget(t, 'properties')
        if props and props[key] then return props[key](x) end
        local bm = rawget(t, 'builtin_methods')
        if bm and bm[key] then return bm[key] end
    end)
end

family_hooks.ptr = { __member = function(x, key) return member_ptr(x, key) end }
family_hooks.slice = { __member = function(x, key) return member_slice(x, key) end }
family_hooks.atomic = { __member = function(x, key) return S.atomic_method(x, key) end }
family_hooks.chan = { __member = function(x, key) return S.chan_method(x, key) end }
family_hooks.array = { __member = function(x, key) return S.array_member(x, key) end }
family_hooks.pool = { __member = function(x, key)
    if is_staged(key) then return S.pool_index(x, key) end
    return S.pool_method(x, key)
end }
family_hooks.slot = { __member = function(x)
    fail(("%s is a handle: its contents are addressed through its pool, pool[slot]"):format(struct_of(x).display), 3)
end }

-- obj.key and obj:key(...) in typed bodies: a native value's members (whatever
-- their names), or an ordinary Lua index
function S.dot(obj, key)
    if is_staged(obj) then return member(obj, key) end
    return obj[key]
end
-- Brackets are distinct from member selection: a StrMap key may be "length",
-- "put", or any internal evaluator field name, without shadowing the API.
function S.index(obj, key)
    if is_staged(obj) then
        local h, t = type_hook(obj, '__index')
        if h then return run_hook(t, h, obj, key) end
    end
    -- Host descriptions can distinguish checked indexing from API members,
    -- including when a native key is still dynamic. No native storage is implied.
    local mt = getmetatable(obj)
    local index = type(mt) == 'table' and rawget(mt, '__slc_index')
    if index then return index(obj, key) end
    return obj[key]
end
function S.mcall(obj, key, ...)
    local f = S.dot(obj, key)
    if f == nil then fail(("no method '%s' on %s"):format(tostring(key), describe(obj)), 2) end
    return f(obj, ...)
end

-- `call f(x)`: the same word, marked so that applying it makes a function
-- boundary (Builder:apply). It keeps the word's identity, so its specialization
-- keys are the ones an ordinary application would use.
function S.boundary(f)
    if is_word(f) then
        local w = setmetatable({}, W)
        for k, v in pairs(f) do rawset(w, k, v) end
        w.boundary = true
        return w
    end
    if getmetatable(f) == X then return f end          -- a foreign call is always a call
    if type(f) == 'function' then
        fail('call needs a native word, got a Lua function (an untyped lambda is evaluated in place)', 2)
    end
    fail(('call needs a native word, got %s'):format(describe(f)), 2)
end

function S.bmcall(obj, key, ...)
    local f = S.dot(obj, key)
    if f == nil then fail(("no method '%s' on %s"):format(tostring(key), describe(obj)), 2) end
    return S.boundary(f)(obj, ...)
end

V.__index = function(x, key) return member(x, key) end
P.__index = function(x, key) return member(x, key) end

-- An assignment in plain Lua code (an untyped word, a hook) to a native field
-- or element stores to the place instead of setting a field of the Lua object.
-- Evaluator-internal keys stay ordinary Lua fields.
P.__newindex = function(x, key, v)
    local t = struct_of(x)
    if type(key) == 'number' or is_staged(key) or (t.kind == 'struct' and t.index[key]) then
        return S.setindex(x, key, v, type(key) ~= 'string')
    end
    rawset(x, key, v)
end
V.__newindex = function(x, key, v)
    local t = struct_of(x)
    if type(key) == 'number' or is_staged(key) or (t.kind == 'struct' and t.index[key]) then
        fail(('cannot assign to a field of a %s value; assign to a place'):format(t.display), 2)
    end
    rawset(x, key, v)
end

function S.setindex(obj, key, v, bracket)
    if is_staged(obj) then
        local t = struct_of(obj)
        local hn = bracket and type_hook(obj, '__newindex')
        if hn then
            run_hook(t, hn, obj, key, v)
            return
        end
        local h = bracket and type_hook(obj, '__index')
        if h then
            -- a word that returns a Ref names the place it borrowed
            local target = run_hook(t, h, obj, key)
            if is_value(target) and target.k == 'ref' then target = target.place end
            S.set(target, v)
            return
        end
        if (t.kind == 'pool' or rawget(t, '__index')) and is_staged(key) or (rawget(t, '__index') and type(key) == 'number') then
            S.set(member(obj, key), v)
            return
        end
        if t.kind == 'array' and (type(key) == 'number' or is_staged(key)) then
            local p = S.array_member(obj, key, true)
            S.set(p, v)
            return
        end
        if t.kind == 'ptr' then
            local p = member_ptr(obj, key)
            S.set(p, v)
            return
        end
        if rawget(t, 'slice_elem') then
            fail('not-a-place: a slice is a read-only view; write through a Ptr or the storage itself', 2)
        end
    end
    if is_place(obj) or (is_value(obj) and obj.k == 'ref') then
        local p = member(obj, key)
        if not is_place(p) then fail(("cannot assign to '%s'"):format(tostring(key)), 2) end
        S.set(p, v)
        return
    end
    if is_value(obj) then
        fail(("cannot assign to field '%s' of a value; values are immutable, store it in a typed local"):format(tostring(key)), 2)
    end
    local b = current
    if b then
        for i = #b.regions, 1, -1 do
            local k = b.regions[i]
            if k == 'dyn' or k == 'loop' then
                fail('a typed body cannot mutate host tables inside a native branch with a dynamic condition or a native loop', 2)
            end
        end
    end
    obj[key] = v
end

-- types are callable: conversions, struct construction --------------------------------------

Type.__index = function(t, k)
    local m = rawget(Type, k)
    if m ~= nil then return m end
    if rawget(t, 'kind') == 'sum' and rawget(t, 'index')[k] then return S.constructor(t, k) end
    local methods = rawget(t, 'methods')
    if methods and methods[k] then return methods[k] end
    return nil
end

Type.__call = function(t, x)
    if t.kind == 'cstr' then
        if type(x) == 'string' then return known(t, x) end
        if is_staged(x) and x.T == t then return value_of(x, t) end
        if is_staged(x) then
            local v = value_of(x, nil, 'CString(...)')
            if v.T.kind == 'ptr' then return dyn(t, { op = 'conv', a = ex(v), T = t }) end
        end
        fail('CString(...) takes a Lua string, got ' .. describe(x), 2)
    end
    if t.kind == 'opaque' then
        fail(('%s is an opaque C type: it exists only behind a Ptr'):format(t.display), 2)
    end
    if t.kind == 'struct' and rawget(t, 'chars_cap') and (x == nil or type(x) == 'string' or is_staged(x)
        or (type(x) == 'table' and next(x) == nil)) then
        -- Chars(n) from text (slc.strings)
        return rawget(t, 'construct')(x)
    end
    if t.kind == 'struct' and rawget(t, '__cast') and type(x) ~= 'table' and not in_hook[t] then
        return value_of(x, t, t.display)
    end
    if t.kind == 'struct' then
        if getmetatable(x) == S.Keyed then
            -- unknown fields reject, even ones an explicit field overrides
            for name in pairs(x.names) do
                if not t.index[name] then fail(("%s has no field '%s'"):format(t.display, tostring(name)), 2) end
            end
            x = x.fields
        end
        if type(x) ~= 'table' or is_staged(x) then
            fail(('%s { ... } expects a table of fields'):format(t.display), 2)
        end
        local f, all = {}, true
        for _, fd in ipairs(t.fields) do
            local fv = x[fd.name]
            if fv == nil then fail(("%s { ... }: field '%s' is missing"):format(t.display, fd.name), 2) end
            if fd.type.kind == 'store' or fd.type.kind == 'grow' then
                f[fd.name] = coerce(fv, fd.type, ("field '%s'"):format(fd.name))
            else
                f[fd.name] = coerce(fv, fd.type, ("field '%s'"):format(fd.name))
            end
        end
        for k in pairs(x) do
            if not t.index[k] then fail(("%s has no field '%s'"):format(t.display, tostring(k)), 2) end
        end
        return agg(t, f)
    end
    if t.kind == 'ptr' then
        local v = is_staged(x) and value_of(x, nil, t.display .. '(...)')
        -- a C string is a pointer to characters: converting between the two
        -- reinterprets an address, never an integer
        if not v or (v.T.kind ~= 'ptr' and v.T.kind ~= 'cstr') then
            fail(t.display .. '(...) requires a pointer; integer-pointer conversion is not offered', 2)
        end
        if v.T == t then return v end
        return dyn(t, { op = 'conv', a = ex(v), T = t })
    end
    if types.is_scalar(t) then
        -- conversion with C semantics
        if not is_staged(x) then
            if type(x) == 'number' or type(x) == 'boolean' or type(x) == 'cdata' then
                if t.kind == 'float' or type(x) == 'boolean' then return value_of(x, t, t.display) end
                local v, err = fold.from_host(t, x)
                if v == nil then fail(t.display .. '(...): ' .. err, 2) end
                return known(t, v)
            end
            fail(('%s(...) expects a number, got %s'):format(t.display, describe(x)), 2)
        end
        local v = value_of(x, nil, t.display .. '(...)')
        if not types.is_scalar(v.T) then fail(('cannot convert %s to %s'):format(v.T.display, t.display), 2) end
        if v.T == t then return v end
        if v.k == 'known' then return known(t, ub_guard(fold.convert, t, v.T, v.v)) end
        return dyn(t, { op = 'conv', a = v.e, T = t })
    end
    if t.construct then return t.construct(x) end
    fail(('%s is not callable'):format(t.display), 2)
end

function S.struct(name, fields)
    local ok, t = pcall(types.struct, name, fields)
    if not ok then fail(t, 2) end
    t.cname = nil
    return t
end

-- Ref doubles as the type constructor and as "take a reference to this place"
function S.Ref(x)
    if is_type(x) then return types.ref(x) end
    if is_staged(x) and x.T.kind == 'ptr' then
        fail('Ref(p) rejects a pointer: an unchecked address cannot become a checked borrow', 2)
    end
    if is_place(x) then return ref(x) end
    if is_value(x) and x.k == 'ref' then return x end
    fail('Ref(...) needs a type or an addressable place, got ' .. describe(x), 2)
end

-- force a value dynamic: the caller decides its binding time, not the evaluator
function S.dynamic(x)
    if not is_staged(x) then
        fail(('dynamic(...) needs a native value; give it a type, as in dynamic(U32(%s))'):format(tostring(x)), 2)
    end
    local v = value_of(x, nil, 'dynamic(...)')
    if v.k == 'sumv' then local q = rawget(v, 'p'); return sumv(v.T, v.tag, q ~= nil and S.dynamic(q) or nil) end
    if v.k == 'known' then return dyn(v.T, const(v.T, v.v)) end
    if v.k == 'array' then return dyn(v.T, ex(v)) end
    if v.k == 'agg' then
        local f = {}
        for k, fv in pairs(v.f) do f[k] = S.dynamic(fv) end
        return agg(v.T, f)
    end
    return v
end

-- the host value of a Known result (for Lua code inspecting compile-time results)
function S.host(x)
    if is_place(x) then x = cur():read(x) end
    if is_value(x) and x.k == 'known' then return fold.to_host(x.T, x.v) end
    if is_value(x) and x.k == 'array' then
        local r = {}
        for i = 0, x.T.length - 1 do r[i + 1] = S.host(Arrays.get(x.contents, i)) end
        return r
    end
    if is_value(x) and x.k == 'agg' then
        local r = {}
        for k, fv in pairs(x.f) do r[k] = S.host(fv) end
        return r
    end
    if is_value(x) then fail('S.host: value is not known at compile time', 2) end
    return x
end

-- typed locals and assignment ----------------------------------------------------------------

function S.decl(t, init, name)
    local b = cur()
    if not is_type(t) then fail(("local '%s': annotation is not a type (%s)"):format(name or '?', describe(t)), 2) end
    if t.kind == 'unit' or t.kind == 'ref' or t.kind == 'opaque' then
        fail(("local '%s': a typed local cannot have type %s"):format(name or '?', t.display), 2)
    end
    local p = b:new_local(t, name)
    if init == nil and t.resizable then
        fail(("local '%s': a %s is created where it is declared: local %s: %s = ..."):format(
            name or '?', t.display, name or 'x', t.display), 2)
    end
    if init == nil and t.kind == 'array' then init = t() end     -- arrays start zeroed
    local unreachable = b.dead
    if init ~= nil then
        if t.resizable and t.kind ~= 'struct' then
            S.init_resizable(p, init)
        else
            local was = b.initializing
            b.initializing = true
            local ok, err = pcall(function()
                b:store(p, coerce(init, t, ("local '%s'"):format(name or '?')))
            end)
            b.initializing = was
            if not ok then error(err, 0) end
        end
    end
    if unreachable then
        -- A declaration in unreachable code stores nothing. Give it a zero of
        -- its type: the value is discarded, but a later walk still type-checks.
        for _, l in ipairs(leaves(p)) do
            local en = b.state[l]
            if not en or en.uninit then b.state[l] = { val = S.zero_value(l.T), mat = false } end
        end
    end
    return p
end

function S.set(p, v)
    local b = cur()
    if not is_place(p) then fail('assignment target is not a native place', 2) end
    if p.T.resizable and p.T.kind ~= 'struct' then
        fail(("'%s' is resizable storage; it cannot be reassigned"):format(p.name), 2)
    end
    b:store(p, coerce(v, p.T, ("assignment to '%s'"):format(p.name)))
end

-- an untyped local names a value: binding a typed place takes its current
-- value (resizable storage, which has no value, stays a name for the place)
-- `local ctx... = e`: the context is retained; a place stays a place (§30.5)
function S.open_bind(v)
    if is_place(v) then return v end
    return S.bind(v)
end

-- Infer storage only for native values that can inhabit a local. References
-- retain write-through semantics; borrowed views and existing resizable places
-- remain aliases, never implicitly stored or copied.
function S.infer(v, name)
    if current and (is_value(v) or is_place(v)) and v.T.kind ~= 'ref'
        and v.T.kind ~= 'unit' and v.T.kind ~= 'opaque'
        and not rawget(v, 'view')
        and not (is_place(v) and v.T.resizable) then
        return S.decl(v.T, v, name)
    end
    return S.bind(v)
end

function S.infern(names, ...)
    local values = { ... }
    for i, name in ipairs(names) do values[i] = S.infer(values[i], name) end
    return unpack(values, 1, #names)
end

-- Loop parameters replace only native places, not host bindings. Host names
-- still refer to their lexical binding, including generation-time rebinding.
function S.inferred_state(slot, host)
    if is_place(slot) then return slot end
    return host
end

function S.assign_inferred(slot, value, host_assign)
    if is_place(slot) then S.set(slot, value) else host_assign(value) end
end

function S.bind(v)
    if not current then return v end
    if is_place(v) and not v.T.resizable then v = current:read(v) end
    if is_value(v) then return current:bind(v) end
    return v
end

-- a host binding declared outside k staged regions is being rebound
-- a reference denotes its place: assigning to a name that holds one writes the
-- target; references are never re-pointed
local function write_through(r, v)
    S.set(r.place, v)
end

function S.assign_param(cur_v, v, name)
    if is_value(cur_v) and cur_v.k == 'ref' then return write_through(cur_v, v) end
    fail(("'%s' is a parameter; parameters are immutable (copy it into a typed local)"):format(name), 2)
end

function S.assign_name(cur_v, v, k)
    if is_value(cur_v) and cur_v.k == 'ref' then
        write_through(cur_v, v)
        return cur_v
    end
    if k > 0 then S.rebind(k) end
    return v
end

function S.rebind(k)
    local b = current
    if not b then return end
    local n = #b.regions
    for i = n, math.max(1, n - k + 1), -1 do
        local kind = b.regions[i]
        if kind == 'dyn' then
            fail('a host binding declared outside this branch cannot be rebound here: the branch condition is dynamic, so both branches are evaluated. Use a typed local', 2)
        elseif kind == 'loop' then
            fail('a host binding declared outside a native loop cannot be rebound in its body. Use a typed local', 2)
        end
    end
end

-- several untyped locals at once
function S.bindn(...)
    local n = select('#', ...)
    local t = { ... }
    for i = 1, n do t[i] = S.bind(t[i]) end
    return unpack(t, 1, n)
end

-- host truth for conditions in host functions: native Bool values must be known
function S.truth(c)
    if is_staged(c) then
        local v = value_of(c, nil, 'condition')
        if v.T.kind ~= 'bool' then fail('a condition must be Bool, got ' .. v.T.display, 2) end
        if v.k ~= 'known' then
            fail('a host function decides only known conditions; this one is dynamic '
                .. '(move it into the native word, or make the function a word)', 2)
        end
        return v.v
    end
    return c
end

-- bounds of a generation-time (untyped) for loop
function S.num(x)
    if is_staged(x) then
        local v = value_of(x, nil, 'loop bound')
        if v.k ~= 'known' or v.T.kind ~= 'int' then
            fail('an untyped for loop runs at compile time, so its bounds must be known integers; '
                .. 'a dynamic bound needs a native loop: for i: T = a, b do', 2)
        end
        return tonumber(v.v)
    end
    return x
end

function S.len(x)
    if is_staged(x) then
        local t = struct_of(x)
        if t.builtin_methods and t.builtin_methods.length then return t.builtin_methods.length(x) end
        fail('# is not defined for ' .. t.display, 2)
    end
    return #x
end

-- conditions -------------------------------------------------------------------------------

-- classify a condition: 'host' (any Lua value, truthiness), or a Bool Value
local function condition(c)
    if is_staged(c) then
        local v = value_of(c, nil, 'condition')
        if v.T.kind ~= 'bool' then
            fail(('a native condition must be Bool, got %s'):format(v.T.display), 3)
        end
        return v
    end
    return nil
end

local function same_entry(a, b)
    if a == b then return true end
    if not a or not b then return false end
    if a.uninit or b.uninit then return a.uninit and b.uninit end
    if a.mat and b.mat then return a.ver == b.ver end
    if not a.mat and not b.mat then
        local va, vb = a.val, b.val
        if va.k == 'known' and vb.k == 'known' then return fold.identical(va.T, va.v, vb.v) end
        if va.k == 'dyn' and vb.k == 'dyn' then return va.e == vb.e end
        if va.k == 'array' and vb.k == 'array' then return same_value(va, vb) end
    end
    return false
end

-- places in creation order: generated code must not depend on hash order
local function sorted_places(set)
    local list = {}
    for p in pairs(set) do list[#list + 1] = p end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

-- join the states of the paths that continue; materialize what differs in each
function Builder:join(paths, base)
    local live = {}
    for _, p in ipairs(paths) do if not p.dead then live[#live + 1] = p end end
    if #live == 0 then self.dead = true; return base end
    if #live == 1 then return live[1].state end
    local out = {}
    for _, place in ipairs(sorted_places(base)) do
        if not tracked(place) then
            -- it became memory on some path: every path stores its pending value
            for _, p in ipairs(live) do
                local en = p.state[place]
                if en and not en.mat and not en.uninit then
                    self:materialize(place, p.block, p.state)
                end
            end
            goto continue
        end
        do
        local first = live[1].state[place]
        local all_same = true
        for i = 2, #live do
            if not same_entry(first, live[i].state[place]) then all_same = false break end
        end
        if all_same then
            out[place] = first
        else
            local any_uninit = false
            for _, p in ipairs(live) do
                local en = p.state[place]
                if not en or en.uninit then any_uninit = true end
            end
            if any_uninit then
                out[place] = { uninit = true }
            else
                for _, p in ipairs(live) do self:materialize(place, p.block, p.state) end
                out[place] = { mat = true, ver = new_version() }
            end
        end
        end
        ::continue::
    end
    return out
end

-- range facts: on each arm of a dynamic branch, what its integer condition
-- proves (lo < hi), over values that cannot change behind our back. A value
-- that changes gets a new version, so an old fact stops matching.
local STABLE_PK = { temp = true, lv = true, rvar = true, iv = true }
local function stable_key(e)
    local ok = true
    local function walk(x)
        if not ok or type(x) ~= 'table' then return end
        local op = x.op
        if op == 'const' or op == 'param' then return end
        if op == 'read' then
            local pk = x.place.pk
            if not (x.ver or STABLE_PK[pk]) then ok = false end
            return
        end
        if op == 'field' or op == 'conv' then return walk(x.a) end
        if op == 'rt' and x.stable then
            for _, a in ipairs(x.args or {}) do walk(a) end
            return
        end
        if op == 'bin' and (x.o == 'add' or x.o == 'sub' or x.o == 'mul') then walk(x.a); walk(x.b); return end
        ok = false
    end
    walk(e)
    return ok and S.expr_key(e) or nil
end

local INVERT = { lt = 'ge', ge = 'lt', gt = 'le', le = 'gt', eq = 'ne', ne = 'eq' }
local function facts_of(e, positive, out)
    out = out or {}
    if type(e) ~= 'table' then return out end
    if e.op == 'cmp' and e.a.T and e.a.T.kind == 'int' then
        local o = positive and e.o or INVERT[e.o]
        local lo, hi
        if o == 'lt' then lo, hi = e.a, e.b elseif o == 'gt' then lo, hi = e.b, e.a end
        if lo then
            local kl, kh = stable_key(lo), stable_key(hi)
            if kl and kh then out[#out + 1] = { lo = kl, hi = kh } end
        end
        -- a lower bound by a constant: x == c, x >= c, x > c (either way round)
        local x, c, rel = nil, nil, o
        if e.b.op == 'const' and type(e.b.v) == 'number' then x, c = e.a, e.b.v
        elseif e.a.op == 'const' and type(e.a.v) == 'number' then
            x, c = e.b, e.a.v
            rel = ({ lt = 'gt', gt = 'lt', le = 'ge', ge = 'le', eq = 'eq', ne = 'ne' })[o]
        end
        if x then
            local min = (rel == 'eq' or rel == 'ge') and c or (rel == 'gt' and c + 1) or nil
            local kx = min and stable_key(x)
            if kx then out[#out + 1] = { hi = kx, min = min } end
        end
    elseif e.op == 'un' and e.o == 'not' then
        facts_of(e.a, not positive, out)
    elseif (e.op == 'and' and positive) or (e.op == 'or' and not positive) then
        facts_of(e.a, positive, out)
        facts_of(e.b, positive, out)
    end
    return out
end

function Builder:add_facts(fs)
    self.facts = self.facts or {}
    for _, f in ipairs(fs) do
        self.facts[#self.facts + 1] = { lo = f.lo, hi = f.hi, min = f.min, path = self.path or '' }
    end
end

-- is lo < hi known on this path?
function Builder:proves_less(lo, hi)
    local kh = stable_key(hi)
    if not kh then return false end
    local here = self.path or ''
    -- a constant below a known lower bound
    if lo.op == 'const' and type(lo.v) == 'number' then
        for i = #(self.facts or {}), 1, -1 do
            local f = self.facts[i]
            if f.min and f.hi == kh and lo.v < f.min and here:sub(1, #f.path) == f.path then return true end
        end
    end
    local kl = stable_key(lo)
    if not kl then return false end
    for i = #(self.facts or {}), 1, -1 do
        local f = self.facts[i]
        if f.lo == kl and f.hi == kh and here:sub(1, #f.path) == f.path then return true end
    end
    return false
end

function S.if_(c, tf, ef)
    local b = current
    local cv = condition(c)
    if not b or not cv then
        -- host condition: plain Lua control flow, nothing speculative
        if b then b.regions[#b.regions + 1] = 'host' end
        local ok, err = pcall(function()
            if c then tf() elseif ef then ef() end
        end)
        if b then b.regions[#b.regions] = nil end
        if not ok then error(err, 0) end
        return
    end
    if cv.k == 'known' then
        b.regions[#b.regions + 1] = 'known'
        local ok, err = pcall(function()
            if cv.v then tf() elseif ef then ef() end
        end)
        b.regions[#b.regions] = nil
        if not ok then error(err, 0) end
        return
    end
    -- dynamic: both branches, each against its own copy of the state
    local s0 = b.state
    local fa, fb = facts_of(cv.e, true), facts_of(cv.e, false)
    local ablk, ast, adead = b:sub(function() b:add_facts(fa); tf() end, copy(s0), 'dyn')
    local bblk, bst, bdead = b:sub(function() b:add_facts(fb); if ef then ef() end end, copy(s0), 'dyn')
    local stmt = { op = 'if', c = cv.e, a = ablk, b = bblk }
    b:emit(stmt)
    b.state = b:join({ { state = ast, dead = adead, block = ablk },
                       { state = bst, dead = bdead, block = bblk } }, s0)
    -- when one arm cannot fall through, what follows is reached only through the
    -- other: its facts hold for the rest of this block (`if n ~= 5 then return end`)
    if adead and not bdead then b:add_facts(fb) elseif bdead and not adead then b:add_facts(fa) end
    if #ablk == 0 and #bblk == 0 then
        -- nothing residual: drop the empty conditional
        for i = #b.block, 1, -1 do
            if b.block[i] == stmt then table.remove(b.block, i) break end
        end
    end
end

-- short-circuit operators: the right side is a delayed closure
local function short(kind, a, rf)
    local b = current
    local av = condition(a)
    if not b or not av then
        if b then b.regions[#b.regions + 1] = 'host' end
        local ok, r
        if kind == 'and' then
            if not a then r = a; ok = true else ok, r = pcall(rf) end
        else
            if a then r = a; ok = true else ok, r = pcall(rf) end
        end
        if b then b.regions[#b.regions] = nil end
        if not ok then error(r, 0) end
        return r
    end
    local function rhs()
        local rv = rf()
        local v = condition(rv)
        if not v then
            local hv, err = fold.from_host(types.Bool, rv)
            if hv == nil then fail("right operand of '" .. kind .. "': " .. err, 4) end
            v = known(types.Bool, hv)
        end
        return v
    end
    if av.k == 'known' then
        if (kind == 'and') ~= av.v then return av end
        b.regions[#b.regions + 1] = 'known'
        local ok, r = pcall(rhs)
        b.regions[#b.regions] = nil
        if not ok then error(r, 0) end
        return r
    end
    -- dynamic left side: try the right side as a pure expression first
    local s0 = b.state
    local blk, st, dead, rv = b:sub(rhs, copy(s0), 'dyn')
    local pure = #blk == 0 and not dead
    if pure then
        for p, en in pairs(st) do if s0[p] ~= en then pure = false break end end
    end
    if pure then
        if rv.k == 'known' then
            if kind == 'and' then return rv.v and av or rv end      -- x and true = x
            return rv.v and rv or av                                   -- x or false = x
        end
        return dyn(types.Bool, { op = kind, a = av.e, b = rv.e, T = types.Bool })
    end
    -- effects on the right: a real conditional into a Bool local
    local r = b:new_local(types.Bool, kind == 'and' and 'both' or 'either')
    S.if_(av, function()
        if kind == 'and' then b:store(r, rhs()) else b:store(r, known(types.Bool, true)) end
    end, function()
        if kind == 'and' then b:store(r, known(types.Bool, false)) else b:store(r, rhs()) end
    end)
    return b:read(r)
end

function S.and_(a, rf) return short('and', a, rf) end
function S.or_(a, rf) return short('or', a, rf) end
function S.not_(a)
    if not is_staged(a) then return not a end
    local v = condition(a)
    return unary('not', v)
end


-- frames, snapshots and signals ------------------------------------------------------------
-- Words and loops run in frames. A frame evaluates in one of four modes:
--   inline    unfolding at compile time / in place (the default)
--   loop      a residual loop in place: dynamic parameters are loop variables,
--             tail re-entry assigns them and jumps back
--   root      the body of a materialized C function
--   comptime  host code applying a word: everything known
-- A tail re-entry of the same word and shape trampolines while each round is
-- entirely known; otherwise the frame restarts its round with the changed known
-- arguments generalized, in loop mode. Typed bodies are deterministic and
-- stage-safe, so restarting (rolling back residual code and state) is sound.

local LOOP_FUEL = 100000

local function frame_name(f)
    return f.word and f.word.name or (f.desc and f.desc.name) or 'callback'
end
local function frame_loc(f)
    return f.word and f.word.loc or (f.desc and f.desc.loc) or '?'
end

local function push_frame(b, f)
    f.region_base = #b.regions
    b.frames[#b.frames + 1] = f
end
local function pop_frame(b)
    b.frames[#b.frames] = nil
end

function Builder:snapshot()
    local owned = self.gs_owned and self.gs_owned[self.block]
    return { block = self.block, n = #self.block, state = copy(self.state), dead = self.dead,
             gs_live = self.gs_live and copy(self.gs_live), owned_n = owned and #owned or 0,
             escapes = #self.escapes }
end

function Builder:rollback(snap)
    self:bump_checked()
    for k = #snap.block, snap.n + 1, -1 do snap.block[k] = nil end
    self.block = snap.block
    self.state = copy(snap.state)
    self.dead = snap.dead
    if self.gs_live then self.gs_live = snap.gs_live and copy(snap.gs_live) or {} end
    local owned = self.gs_owned and self.gs_owned[snap.block]
    if owned then for k = #owned, snap.owned_n + 1, -1 do owned[k] = nil end end
    for k = #self.escapes, snap.escapes + 1, -1 do
        rawset(self.escapes[k], 'escaped', nil)
        self.escapes[k] = nil
    end
end

local function signal(kind, frame, fields)
    fields = fields or {}
    fields.slc_signal, fields.frame = kind, frame
    error(fields, 0)
end

-- structural equality of residual expressions
local function same_e(x, y)
    if x == y then return true end
    if type(x) ~= 'table' or type(y) ~= 'table' or x.op ~= y.op then return false end
    if x.op == 'const' then return x.T == y.T and x.v == y.v end
    if x.op == 'param' then return x.name == y.name end
    if x.op == 'read' then return x.place == y.place and x.ver == y.ver end
    if x.op == 'call' or x.op == 'rt' then return false end
    for _, k in ipairs { 'o', 'name', 'T' } do if x[k] ~= y[k] then return false end end
    for _, k in ipairs { 'a', 'b' } do
        if (x[k] == nil) ~= (y[k] == nil) or (x[k] and not same_e(x[k], y[k])) then return false end
    end
    if x.fields then
        for k, v in pairs(x.fields) do if not same_e(v, y.fields[k]) then return false end end
    end
    return true
end

-- did the current round of a frame stay entirely known? Its dynamic arguments
-- must pass through unchanged: a changing dynamic value is state to loop over
local function round_known(b, frame, args)
    if b.block ~= frame.base_block or #b.block ~= frame.iter_n then return false end
    if args then
        for i, a in ipairs(args) do
            local o = frame.args[i]
            if is_value(a) and not is_known(a) and a.k ~= 'ref' then
                if is_known(o) or not same_e(ex(a), ex(o)) then return false end
            end
        end
    end
    for p, en in pairs(b.state) do
        local before = frame.iter_state[p]
        if before ~= en and before ~= nil then
            if en.mat then return false end
            if not en.uninit and en.val.k ~= 'known' then return false end
        end
    end
    return true
end

-- is the code since a frame began under dynamic control?
h.under_dynamic = function(b, frame)
    for i = frame.region_base + 1, #b.regions do
        local k = b.regions[i]
        if k == 'dyn' or k == 'loop' then return true end
    end
    return false
end

local function innermost(b, kind)
    for i = #b.frames, 1, -1 do
        local f = b.frames[i]
        if f.kind == kind then return f end
    end
end

S.dead = function() return current ~= nil and current.dead end

-- words ------------------------------------------------------------------------------------

local word_ids = 0

function S.word(spec)
    word_ids = word_ids + 1
    local params = {}
    for i, p in ipairs(spec.params) do
        if p[2] == nil then
            -- an untyped parameter of a native word is a compile-time parameter
            params[i] = { name = p[1], static = true }
            goto next_param
        end
        if not is_type(p[2]) then
            fail(("word %s: parameter '%s' annotation is not a type (%s)"):format(
                spec.name or '?', p[1], describe(p[2])), 2)
        end
        if p[2].kind == 'unit' then fail(("word %s: parameter '%s' cannot be Unit"):format(spec.name or '?', p[1]), 2) end
        if p[2].kind == 'atomic' then
            fail(("word %s: parameter '%s' is %s; atomics are shared through Ref, never copied"):format(
                spec.name or '?', p[1], p[2].display), 2)
        end
        if p[2].kind == 'opaque' then
            fail(("word %s: parameter '%s' is the opaque type %s; take a Ptr %s"):format(spec.name or '?',
                p[1], p[2].display, p[2].display), 2)
        end
        if p[2].resizable then
            fail(("word %s: parameter '%s' is a %s; resizable values are passed as Ref %s"):format(
                spec.name or '?', p[1], p[2].display, p[2].display), 2)
        end
        params[i] = { name = p[1], T = p[2] }
        ::next_param::
    end
    if not is_type(spec.result) then
        fail(('word %s: result annotation is not a type (%s)'):format(spec.name or '?', describe(spec.result)), 2)
    end
    if spec.result.resizable then
        fail(('word %s: a %s cannot be returned; create it in the caller and pass a Ref'):format(
            spec.name or '?', spec.result.display), 2)
    end
    local body = spec.body
    if spec.rest then
        -- the body receives its fixed parameters, then the pack
        local np, inner = #params, spec.body
        body = function(...)
            local all, n = { ... }, select('#', ...)
            local comps = {}
            for i = np + 1, n do comps[#comps + 1] = all[i] end
            return inner(unpack(all, 1, np), S.pack(comps))
        end
        if np == 0 then
            body = function(...) return inner(S.pack({ ... })) end
        end
    end
    return setmetatable({
        id = word_ids, name = spec.name or ('w' .. word_ids), params = params,
        ret = spec.result, body = body, supplied = {}, loc = spec.loc, rest = spec.rest,
    }, W)
end

function W:__tostring()
    local ps = {}
    for i, p in ipairs(self.params) do
        if i > #self.supplied then ps[#ps + 1] = p.name .. (p.T and (': ' .. p.T.display) or '') end
    end
    if self.rest then ps[#ps + 1] = '...' .. self.rest end
    return ('<word %s(%s): %s>'):format(self.name, table.concat(ps, ', '), self.ret.display)
end

W.__index = function(w, k)
    if k == 'arity' then return #w.params - #w.supplied end
    return nil
end

-- static values may be bound into partial applications and specialization keys:
-- known native values, and host values (compile-time Lua data)
local function is_host(v)
    return not is_value(v) and not is_place(v)
end
S.is_host = is_host

local function static(v)
    if is_host(v) then return true end
    if not is_value(v) then return false end
    if v.k == 'known' then return true end
    if v.k == 'agg' or v.k == 'sumv' or v.k == 'array' then return is_known(v) end
    return false
end
S.static = static

h.host_key = function(v)
    local t = type(v)
    if t == 'number' or t == 'boolean' or t == 'nil' then return 'h' .. tostring(v) end
    if t == 'string' then return 'h' .. ('%q'):format(v) end
    return 'h' .. tostring(v)            -- an object: its identity
end

local function arg_key(v)
    if is_host(v) then return h.host_key(v) end
    if v.k == 'sumv' and is_known(v) then
        local q = rawget(v, 'p')
        return v.T.display .. '.' .. v.tag .. '(' .. (q ~= nil and arg_key(q) or '') .. ')'
    end
    if v.k == 'known' then return v.T.display .. '=' .. fold.show(v.T, v.v) end
    if v.k == 'agg' and rawget(v.T, 'is_str') and is_known(v) then return 'Str' .. ('%q'):format(S.known_text(v)) end
    if v.k == 'agg' and is_known(v) then
        local parts = {}
        for _, f in ipairs(v.T.fields) do parts[#parts + 1] = arg_key(v.f[f.name]) end
        return v.T.display .. '{' .. table.concat(parts, ',') .. '}'
    end
    if v.k == 'array' and is_known(v) then
        local parts = { arg_key(v.contents.zero) }
        for _, i in ipairs(Arrays.indices(v.contents)) do
            parts[#parts + 1] = i .. ':' .. arg_key(v.contents.items[i])
        end
        return v.T.display .. '[' .. table.concat(parts, ',') .. ']'
    end
    if v.k == 'ref' then return '&' .. v.T.elem.display end
    return '?' .. v.T.display
end

local function spec_key(w, args)
    local parts = {}
    for i, a in ipairs(args) do parts[i] = arg_key(a) end
    return w.id .. '(' .. table.concat(parts, ',') .. ')'
end
S.spec_key = spec_key

local invoke

local function static_arg(x, p, w)
    if is_place(x) then x = cur():read(x) end
    if not static(x) then
        fail(("argument '%s' of %s is a compile-time parameter (it has no type), but the "
            .. "value is not known at compile time"):format(p.name, w.name), 4)
    end
    return x
end

function W:__call(...)
    local n = select('#', ...)
    local new = { ... }
    for i = 1, n do S.no_pack(new[i]) end
    local need = #self.params
    local all = {}
    for i = 1, #self.supplied do all[i] = self.supplied[i] end
    local have = #self.supplied
    for i = 1, n do
        local idx = have + i
        if idx > need then
            if self.rest then
                -- the rest requirement takes every remaining component
                local x = new[i]
                if is_place(x) then x = cur():read(x) end
                if x == nil then fail(('component %d of %s\'s pack is nil'):format(idx - need, self.name), 2) end
                all[idx] = x
            else
                break
            end
        else
            local p = self.params[idx]
            if p.static then
                all[idx] = static_arg(new[i], p, self)
            else
                all[idx] = coerce(new[i], p.T, ("argument '%s' of %s"):format(p.name, self.name))
            end
        end
    end
    if self.rest and have + n >= need then
        -- saturated: no surplus to apply to the result
        return invoke(self, all)
    end
    if have + n < need then
        -- partial application binds static values only
        for i = have + 1, have + n do
            if not static(all[i]) then
                fail(("partial application of %s: argument '%s' is not static (only compile-time "
                    .. "values can be bound into an incomplete word)"):format(self.name, self.params[i].name), 2)
            end
        end
        local w = setmetatable({}, W)
        for k, v in pairs(self) do rawset(w, k, v) end
        w.supplied = {}
        for i = 1, have + n do w.supplied[i] = all[i] end
        return w
    end
    local r = invoke(self, all)
    if have + n > need then
        local rest = {}
        for i = need - have + 1, n do rest[#rest + 1] = new[i] end
        if not (is_word(r) or (type(r) == 'table' and getmetatable(r) and getmetatable(r).__call)
            or type(r) == 'function') then
            fail(('%s takes %d arguments; the result (%s) cannot take more'):format(
                self.name, need, describe(r)), 2)
        end
        return r(unpack(rest))
    end
    return r
end

-- the shape of a specialization key: knownness and types, not known values
h.arg_shape = function(v)
    -- a place passed on to a handler is read like any other argument
    if is_place(v) then v = cur():read(v) end
    if is_host(v) then return 'H' end
    if static(v) then return 'K' .. v.T.display end
    if v.k == 'ref' then return '&' .. v.T.elem.display end
    return '?' .. v.T.display
end

local function shape_of(args)
    local parts = {}
    for i, a in ipairs(args) do parts[i] = h.arg_shape(a) end
    return table.concat(parts, ',')
end

-- positions where a known argument changed: to another value, or to dynamic
local function changed(a, b)
    local out = {}
    for i = 1, #a do
        if static(a[i]) and (not static(b[i]) or arg_key(a[i]) ~= arg_key(b[i])) then out[i] = true end
    end
    return out
end

-- can new arguments take the place of a frame's arguments after generalizing?
-- (same types; a known position may become dynamic, never the reverse)
h.compatible = function(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        local x, y = a[i], b[i]
        if is_host(x) or is_host(y) then
            if not (is_host(x) and is_host(y)) then return false end
            goto ok
        end
        if x.T ~= y.T then return false end
        if (x.k == 'ref') ~= (y.k == 'ref') then return false end
        ::ok::
    end
    return true
end

h.widened = function(args, positions)
    local out = {}
    for i, a in ipairs(args) do
        if positions[i] and is_host(a) then
            fail(('a compile-time argument (%s) changes on every recursion under a dynamic condition; '
                .. 'it cannot become a runtime value'):format(tostring(a)), 3)
        end
        out[i] = positions[i] and static(a) and S.dynamic(a) or a
    end
    return out
end

local INLINE_FUEL = 400

local build_function

-- resizable values created since a frame's round began give their space back
-- before a jump
function Builder:release_since(frame)
    local mark = frame.gs_mark or {}
    local ks = {}
    for k in pairs(self.gs_live or {}) do if not mark[k] then ks[#ks + 1] = k end end
    table.sort(ks, function(a, b) return a > b end)
    for _, k in ipairs(ks) do
        local owned = self.gs_live[k]
        owned.release()
    end
end

-- run a word or loop frame to completion, trampolining known tail rounds and
-- restarting rounds in a more general mode when asked
function Builder:run_frame(desc, args, opts)
    opts = opts or {}
    if self.dead then
        -- Unreachable code is still written, but applying a word there must not
        -- run its body: the result is discarded, so a null value of its type
        -- keeps the enclosing expression well typed.
        local ret = desc.ret
        if not ret or ret.kind == 'unit' then return nil end
        return dyn(ret, { op = 'zero', T = ret })
    end
    local mode = opts.mode or 'inline'
    local widen, escapes = {}, {}
    local rounds = 0
    while true do
        local frame = {
            kind = desc.kind, mode = mode, word = desc.word, desc = desc, args = args,
            key = desc.word and spec_key(desc.word, args), shape = shape_of(args),
            ret = desc.ret, base_block = self.block, sites = {}, rounds = rounds,
            tail_parent = opts.tail_parent, widen = widen, escape_list = escapes,
            infer = desc.infer,
        }
        frame.snap = self:snapshot()
        frame.iter_n, frame.iter_state = #self.block, copy(self.state)
        frame.gs_mark = copy(self.gs_live or {})
        local ok, res
        if mode == 'loop' then
            ok, res = pcall(self.run_loop, self, frame)
        else
            ok, res = pcall(self.run_inline, self, frame)
        end
        if ok then
            if frame.recursive and desc.word and self.fn and not self.active[frame.key] then
                -- re-entered with the same key: undo this round, call the function
                self:rollback(frame.snap)
                return self:call_materialized(desc.word, args, frame.key)
            end
            return res
        end
        local sig = type(res) == 'table' and res.slc_signal and res.frame == frame and res
        if not sig then error(res, 0) end
        if sig.slc_signal == 'tail' then
            -- a known round: the next one continues in place
            rounds = rounds + 1
            args = sig.args
        elseif sig.slc_signal == 'restart' then
            self:rollback(frame.snap)
            if sig.escape then escapes[#escapes + 1] = sig.escape end
            for i in pairs(sig.widen or {}) do widen[i] = true end
            args = h.widened(args, widen)
            mode = sig.mode
            if mode == 'function' then
                return self:call_materialized(desc.word, args, spec_key(desc.word, args))
            end
        end
    end
end

-- inline (and comptime) evaluation of one round
function Builder:run_inline(frame)
    local desc = frame.desc
    local bound = {}
    for i, a in ipairs(frame.args) do bound[i] = self:bind(a) end
    local dead_before = self.dead
    local key = frame.key
    if key then self.active[key] = (self.active[key] or 0) + 1 end
    self.depth = self.depth + 1
    push_frame(self, frame)
    local regions_before = #self.regions
    -- a loop round is a closure boundary for the translator too
    if frame.kind == 'loop' then self.regions[#self.regions + 1] = 'known' end
    local ok, err = pcall(desc.body, unpack(bound, 1, #frame.args))
    for k = #self.regions, regions_before + 1, -1 do self.regions[k] = nil end
    self:expire(frame)
    pop_frame(self)
    self.depth = self.depth - 1
    if key then
        self.active[key] = self.active[key] - 1
        if self.active[key] == 0 then self.active[key] = nil end
    end
    if not ok then error(err, 0) end
    if frame.kind == 'loop' then
        -- the loop ended at base level: exited, or left by a return
        if frame.exited then self.dead = dead_before end
        if not self.dead then self.dead = dead_before end
        return nil
    end
    local result = self:finish_frame(frame)
    self.dead = dead_before
    return result
end

-- a residual loop in place
local run_loop_body
function Builder:run_loop(frame)
    -- a residual loop: lookups from before do not hold across its rounds, nor
    -- lookups from its body after it
    self:bump_checked()
    local ok, r = pcall(run_loop_body, self, frame)
    self:bump_checked()
    if not ok then error(r, 0) end
    return r
end
function run_loop_body(self, frame)
    if not self.fn then
        fail(('%s needs a runtime loop, so it cannot be evaluated at compile time'):format(
            frame.kind == 'loop' and 'this loop' or frame_name(frame)), 3)
    end
    local desc = frame.desc
    -- places written behind the loop's back (through a reference, or by a word
    -- that captured them) are plain memory from here on
    for _, p in ipairs(frame.escape_list or {}) do self:escape(p) end
    local vals, lvs = {}, {}
    -- a loop's state variable is its own place: during the loop nothing else
    -- reads it (the body works on its round copy), so it carries the state
    local own = {}
    for _, sl in ipairs(desc.slots or {}) do
        if sl.idx then own[sl.idx] = sl.place end
    end
    for i, a in ipairs(frame.args) do
        if static(a) or a.k == 'ref' then
            vals[i] = a
        else
            local lv = own[i] and not rawget(own[i], 'escaped') and own[i]
                or self:new_var(a.T, 'lv', desc.params[i].name)
            lvs[i] = lv
            local e = read_expr(lv)
            if lv.pk == 'lv' then e.lv = true end
            vals[i] = dyn(a.T, e)
        end
    end
    frame.lvs = lvs
    frame.top, frame.ends = 'L' .. uid(), 'L' .. uid()
    if frame.kind == 'word' and frame.ret.kind ~= 'unit' then
        frame.rvar = self:new_var(frame.ret, 'rvar', 'r')
    end
    local s0 = self.state
    frame.s0 = s0
    frame.exit_states = {}
    -- loop variables start from the arguments
    for i, lv in pairs(lvs) do
        local e = ex(frame.args[i])
        if not (e.op == 'read' and e.place == lv) then
            self:emit { op = 'store', place = lv, e = e }
        end
    end
    local inside = copy(s0)
    frame.own = {}
    for i, lv in pairs(lvs) do
        -- its storage holds the live value from here on
        for _, l in ipairs(leaves(lv)) do
            frame.own[l] = true
            if inside[l] then inside[l] = { mat = true, ver = new_version() } end
        end
    end
    local key = frame.key
    local dead_before = self.dead
    if key then self.active[key] = (self.active[key] or 0) + 1 end
    self.depth = self.depth + 1
    push_frame(self, frame)
    local ok, err
    local blk = self:sub(function()
        frame.base_block = self.block
        frame.gs_mark = copy(self.gs_live or {})
        ok, err = pcall(desc.body, unpack(vals, 1, #frame.args))
        if ok and not self.dead then
            -- falling off the end leaves the loop / returns Unit
            if frame.kind == 'word' then
                if frame.ret.kind ~= 'unit' then
                    ok, err = false, ('word %s (%s) can reach its end without returning a %s'):format(
                        frame_name(frame), frame_loc(frame), frame.ret.display)
                else
                    self:return_value(frame, nil)
                end
            else
                ok, err = pcall(S.loop_exit)
            end
        end
    end, inside, 'loop')
    self:expire(frame)
    pop_frame(self)
    self.depth = self.depth - 1
    if key then
        self.active[key] = self.active[key] - 1
        if self.active[key] == 0 then self.active[key] = nil end
    end
    self.dead = dead_before
    if not ok then error(err, 0) end
    self:emit { op = 'loop', body = blk, top = frame.top, ends = frame.ends }
    self.block[#self.block + 1] = { op = 'label', label = frame.ends }
    -- after the loop: the join of its exits
    local paths = {}
    for _, st in ipairs(frame.exit_states) do paths[#paths + 1] = { state = st } end
    if #paths == 0 then
        self.dead = true
    else
        local out = {}
        for _, place in ipairs(sorted_places(s0)) do
            local first = paths[1].state[place]
            local same = true
            for i = 2, #paths do if not same_entry(first, paths[i].state[place]) then same = false break end end
            out[place] = same and first or { mat = true, ver = new_version() }
        end
        self.state = out
    end
    if frame.rvar then return dyn(frame.ret, read_expr(frame.rvar)) end
    return nil
end

-- a store to a tracked place that existed before a residual loop, from inside
-- it: the outermost such loop restarts its round with the place made memory
function Builder:loop_write(p)
    if self.storeback then return end
    for i = 1, #self.frames do
        local f = self.frames[i]
        if f.mode == 'loop' and f.s0 and f.s0[p] ~= nil and not (f.own and f.own[p]) then
            signal('restart', f, { escape = root_of(p), mode = 'loop' })
        end
    end
end

-- jump back to the top of a loop-mode frame with new arguments
function Builder:jump_next(frame, args)
    local diff = changed(frame.args, args)
    if next(diff) then signal('restart', frame, { widen = diff, mode = 'loop' }) end
    for i, a in ipairs(args) do
        if a.k == 'ref' and frame.args[i].k == 'ref' and a.place ~= frame.args[i].place then
            if frame.kind == 'word' then signal('restart', frame, { mode = 'function' }) end
            fail('a loop parameter must refer to the same place on every round', 3)
        end
    end
    self:release_since(frame)
    local moves = {}
    -- state (the later positions) first: the update an exit shares then leads both paths
    for i = #frame.args, 1, -1 do
        local lv = frame.lvs[i]
        if lv then
            local e = ex(value_of(args[i], lv.T, 'loop argument'))
            if not (e.op == 'read' and e.place == lv) then moves[#moves + 1] = { var = lv, e = e } end
        end
    end
    self:parallel_assign(moves, function(m, e) return { op = 'store', place = m.var, e = e } end,
        function(m) return m.var end)
    self:emit { op = 'goto', label = frame.top }
    self.dead = true
end

-- assign several variables at once: a move goes directly unless another
-- pending move still reads its variable; a cycle (a swap) goes through a temporary
local function reads_place(e, p)
    local found = false
    local function walk(x)
        if type(x) ~= 'table' or found then return end
        if x.op == 'read' and x.place == p then found = true return end
        if x.op == 'param' and type(p) == 'string' and x.name == p then found = true return end
        for k, c in pairs(x) do
            if type(c) == 'table' and k ~= 'T' and k ~= 'place' and k ~= 'fn' and k ~= 'ext'
                and rawget(c, 'op') then walk(c) end
        end
        if x.args then for _, a in ipairs(x.args) do walk(a) end end
        if x.fields then for _, a in pairs(x.fields) do walk(a) end end
    end
    walk(e)
    return found
end

function Builder:parallel_assign(moves, make, target)
    local pending = {}
    for i, m in ipairs(moves) do pending[i] = m end
    while #pending > 0 do
        local pick
        for i, m in ipairs(pending) do
            local blocked = false
            for j, o in ipairs(pending) do
                if j ~= i and reads_place(o.e, target(m)) then blocked = true break end
            end
            if not blocked then pick = i break end
        end
        if not pick then
            -- a cycle: save one variable's old value first
            local m = pending[1]
            local tv = target(m)
            local t = self:new_temp(m.T or (type(tv) == 'table' and tv.T) or m.e.T)
            local old = type(tv) == 'string' and { op = 'param', name = tv, T = m.e.T } or read_expr(tv)
            self:emit { op = 'let', place = t, e = old }
            local function subst(x)
                if type(x) ~= 'table' or not rawget(x, 'op') then return x end
                if (x.op == 'read' and x.place == tv) or (x.op == 'param' and x.name == tv) then
                    return read_expr(t)
                end
                local c = {}
                for k, v in pairs(x) do
                    if k == 'args' then
                        c.args = {}
                        for n, a in ipairs(v) do c.args[n] = subst(a) end
                    elseif type(v) == 'table' and k ~= 'T' and k ~= 'place' and k ~= 'fn' and k ~= 'ext'
                        and rawget(v, 'op') then c[k] = subst(v)
                    else c[k] = v end
                end
                return c
            end
            for j = 2, #pending do pending[j].e = subst(pending[j].e) end
            pick = 1
            local first = table.remove(pending, 1)
            table.insert(pending, first)
            pick = #pending
            -- now the saved variable can be overwritten last; retry selection
            local p2
            for i2, m2 in ipairs(pending) do
                local blocked = false
                for j, o in ipairs(pending) do
                    if j ~= i2 and reads_place(o.e, target(m2)) then blocked = true break end
                end
                if not blocked then p2 = i2 break end
            end
            pick = p2 or 1
        end
        local m = table.remove(pending, pick)
        self:emit(make(m, m.e))
    end
end

-- leave a loop-mode frame (a loop's exit, or a word's return)
function Builder:exit_loop(frame)
    self:release_since(frame)
    self:materialize_all()
    self:emit { op = 'goto', label = frame.ends }
    frame.exit_states[#frame.exit_states + 1] = copy(self.state)
    self.dead = true
end

-- apply a saturated word inside builder b
function Builder:apply(w, args, opts)
    local key = spec_key(w, args)
    local all_static = true
    for _, a in ipairs(args) do if not static(a) then all_static = false break end end
    if all_static and self.memo[key] ~= nil then return self.memo[key] end

    -- `call f(x)`: a function boundary here. The residual function is the word
    -- specialized on this key (its compile-time parameters, the types of its
    -- other arguments and the typed values known here), shared by every `call`
    -- with the same key. It is always a call: the programmer asked for one.
    -- (When evaluating at compile time there is no function to call from, and
    -- the application runs in place, as every application does there.)
    if rawget(w, 'boundary') and self.fn then
        local crossing
        for i, a in ipairs(args) do
            -- A known view of a caller's local array (a Str over a Chars local)
            -- reads that local, which the callee cannot name: it crosses as a
            -- runtime address and length.
            if is_value(a) and a.k == 'agg' and static(a) then
                local fields, changed = {}, false
                for name, fv in pairs(a.f) do
                    if is_value(fv) and fv.k == 'array_ptr' then
                        fields[name] = dyn(fv.T, ex(fv))
                        changed = true
                    else
                        fields[name] = fv
                    end
                end
                if changed then
                    crossing = crossing or { unpack(args) }
                    crossing[i] = agg(a.T, fields)
                end
            end
        end
        if crossing then args = crossing; key = spec_key(w, args) end
        return self:call_materialized(w, args, key)
    end

    if self.active[key] then
        -- re-entry with the same key: this key becomes a C function
        self.recursive[key] = true
        for i = #self.frames, 1, -1 do
            local f = self.frames[i]
            if f.key == key then f.recursive = true break end
        end
        return self:call_materialized(w, args, key)
    end
    -- re-entry of the same word and shape with other known arguments, under
    -- dynamic control: unfolding further cannot be decided statically, so the
    -- arguments that changed are generalized
    local shape = shape_of(args)
    for i = #self.frames, 1, -1 do
        local f = self.frames[i]
        if f.kind == 'word' and f.word == w and f.shape == shape
            and (f.mode == 'inline' or f.mode == 'loop') and h.under_dynamic(self, f) then
            signal('restart', f, { widen = changed(f.args, args), mode = f.mode })
        end
    end
    if self.depth >= INLINE_FUEL then
        local trail = {}
        for i = math.max(1, #self.frames - 5), #self.frames do trail[#trail + 1] = self.frames[i].key end
        fail(('specialization of %s does not terminate (over %d nested applications). Recent keys: %s. '
            .. 'A known argument that changes on every recursion under known control never repeats a key; '
            .. 'wrap it in dynamic(...) to make it a runtime parameter'):format(
            w.name, INLINE_FUEL, table.concat(trail, '  ')), 3)
    end
    local n_before = #self.block
    -- `slc size`: what this application, evaluated in place, adds to the program
    local profile = S.size_profile
    local entry = profile and profile:enter(w, key)
    local result = self:run_frame({ kind = 'word', word = w, params = w.params, body = w.body, ret = w.ret },
        args, opts)
    if entry then profile:leave(entry) end
    if all_static and #self.block == n_before and (result == nil or is_known(result)) then
        self.memo[key] = result
    end
    return result
end

-- the end of an inlined application: reconcile its returns
function Builder:finish_frame(frame)
    if not self.dead then
        if frame.infer and frame.ret == nil then frame.ret = types.Unit end
        if frame.ret.kind ~= 'unit' then
            fail(('%s %s (%s) can reach its end without returning a %s'):format(
                frame.infer and 'callback' or 'word', frame_name(frame), frame_loc(frame), frame.ret.display), 3)
        end
        self:return_value(frame, nil)
    end
    if not frame.label then
        self.state = frame.direct_state
        return frame.direct
    end
    -- some returns jumped here: join their states with the base-level one
    local paths = {}
    for _, s in ipairs(frame.sites) do paths[#paths + 1] = { state = s } end
    if frame.base_state then
        self.dead = false
        self:materialize_all(nil, frame.base_state)
        paths[#paths + 1] = { state = frame.base_state }
    end
    local base = {}
    for _, p in ipairs(paths) do for k in pairs(p.state) do base[k] = true end end
    self.dead = false
    local out = {}
    for _, place in ipairs(sorted_places(base)) do
        local first = paths[1].state[place]
        local same = true
        for i = 2, #paths do if not same_entry(first, paths[i].state[place]) then same = false break end end
        if same then out[place] = first
        else
            local un = false
            for _, p in ipairs(paths) do local e = p.state[place]; if not e or e.uninit then un = true end end
            out[place] = un and { uninit = true } or { mat = true, ver = new_version() }
        end
    end
    self.block[#self.block + 1] = { op = 'label', label = frame.label }
    self.state = out
    if frame.rvar then return dyn(frame.ret, read_expr(frame.rvar)) end
    if frame.deferred then
        -- every return was a Lua number: one value is a compile-time result
        local v0 = frame.deferred[1].v
        for _, d in ipairs(frame.deferred) do
            if d.v ~= v0 then
                fail(('%s returns different Lua numbers on runtime paths; give one a type, '
                    .. 'e.g. U32(%s)'):format(frame_name(frame), tostring(v0)), 3)
            end
        end
        if frame.base_state and frame.direct ~= nil and frame.direct ~= v0 then
            fail(('%s returns different Lua numbers on runtime paths; give one a type'):format(frame_name(frame)), 3)
        end
        return v0
    end
    return nil
end

-- `return v` from a word frame
function Builder:return_value(frame, v)
    if v and is_value(v) and v.k == 'ref' then
        local r = root_of(v.place)
        if r.pk == 'local' and rawget(r, 'frame') == frame then
            fail(("word %s returns a reference to its own local '%s', which ends with it"):format(
                frame_name(frame), r.name), 3)
        end
    end
    if frame.mode == 'root' then
        self:emit { op = 'ret', e = v and ex(v) or nil, T = frame.ret }
        self.dead = true
        return
    end
    if frame.mode == 'comptime' then
        frame.direct = v
        frame.direct_state = self.state
        self.dead = true
        return
    end
    if frame.mode == 'loop' then
        if frame.rvar then self:emit { op = 'store', place = frame.rvar, e = ex(v) } end
        self:exit_loop(frame)
        return
    end
    local at_base = self.block == frame.base_block
    if at_base and not frame.label then
        frame.direct = v
        frame.direct_state = self.state
        self.dead = true
        return
    end
    local defer
    if frame.infer and frame.ret == nil then
        -- a callback's result type comes from the first return that needs storage
        if v == nil then frame.ret = types.Unit
        elseif is_value(v) and v.k ~= 'ref' then frame.ret = v.T
        elseif type(v) == 'boolean' then frame.ret = types.Bool
        elseif type(v) == 'number' then
            -- a Lua number takes its type from another return: store it later
            defer = true
        else
            fail(('%s returns %s from inside a dynamic branch; only native values '
                .. 'can be returned there'):format(frame_name(frame), describe(v)), 3)
        end
    end
    if frame.infer and frame.ret and frame.ret.kind ~= 'unit' and v ~= nil then
        v = coerce(v, frame.ret, 'return value of ' .. frame_name(frame))
    end
    if frame.ret and frame.ret.kind ~= 'unit' and not frame.rvar then
        frame.rvar = self:new_var(frame.ret, 'rvar', 'r')
        -- the deferred Lua numbers now have a type
        for _, d in ipairs(frame.deferred or {}) do
            local kv = coerce(d.v, frame.ret, 'return value of ' .. frame_name(frame))
            d.hole.op, d.hole.place, d.hole.e = 'store', frame.rvar, ex(kv)
        end
    end
    if not self.fn then
        fail(('%s returns from inside a dynamic branch at compile time'):format(frame_name(frame)), 3)
    end
    if defer then
        local hole = { op = 'nop' }
        self:emit(hole)
        frame.deferred = frame.deferred or {}
        table.insert(frame.deferred, { hole = hole, v = v })
    elseif frame.rvar then
        self:emit { op = 'store', place = frame.rvar, e = ex(v) }
    end
    if at_base then
        frame.base_state = self.state
        self.dead = true
        return
    end
    frame.label = frame.label or ('L' .. uid())
    self:materialize_all()
    self:emit { op = 'goto', label = frame.label }
    frame.sites[#frame.sites + 1] = self.state
    self.dead = true
end

function S.ret(...)
    local b = cur()
    if b.dead then return end
    local frame = innermost(b, 'word')
    if not frame then fail('return outside a word', 2) end
    local v = (...)
    if select('#', ...) == 0 then v = nil end
    S.no_pack(v)
    if frame.infer then
        if is_place(v) and not v.T.resizable then v = b:read(v) end
        if frame.ret and frame.ret.kind ~= 'unit' and v ~= nil then
            v = coerce(v, frame.ret, 'return value of callback ' .. frame_name(frame))
        end
    else
        v = coerce(v, frame.ret, ('return value of %s'):format(frame_name(frame)))
    end
    b:return_value(frame, v)
end

-- `return ...xs` in a word: exactly one component (words return one value)
function S.ret_one(...)
    local n = select('#', ...)
    if n ~= 1 then
        fail(('a word returns one value; this return supplies %d'):format(n), 2)
    end
    return S.ret(...)
end

-- `return f(args)`: a tail call
h.saturate = function(w, n, ...)
    if not is_word(w) then return nil end
    local need = #w.params
    if #w.supplied + n ~= need then return nil end
    local new = { ... }
    local all = {}
    for i, v in ipairs(w.supplied) do all[i] = v end
    for i = 1, n do
        local idx = #w.supplied + i
        local p = w.params[idx]
        all[idx] = coerce(new[i], p.T, ("argument '%s' of %s"):format(p.name, w.name))
    end
    return all
end

function S.tail(f, ...)
    local b = cur()
    if b.dead then return end
    if is_word(f) and f.receiver and #f.supplied == 0 then
        -- a method on a value (not a place) gets its temporary place in W.__call
        local recv = (...)
        if is_value(recv) and recv.k ~= 'ref' then return S.ret(f(...)) end
    end
    local args = h.saturate(f, select('#', ...), ...)
    if not args then return S.ret(f(...)) end
    local wf = innermost(b, 'word')
    if not wf then fail('return outside a word', 2) end
    local shape = shape_of(args)
    local target
    local F = wf
    while F do
        if F.word == f and h.compatible(F.args, args) then target = F break end
        F = F.tail_parent
    end
    if not target then
        local r = b:apply(f, args, { tail_parent = wf })
        return S.ret(r)
    end
    if target.mode == 'inline' then
        if round_known(b, target, args) and target.rounds < LOOP_FUEL then
            signal('tail', target, { args = args })
        end
        signal('restart', target, { widen = changed(target.args, args), mode = 'loop' })
    elseif target.mode == 'loop' then
        b:jump_next(target, args)
    elseif target.mode == 'root' and spec_key(f, args) == target.key then
        b:root_tail(target, args)
    else
        local r = b:apply(f, args, { tail_parent = wf })
        return S.ret(r)
    end
end

-- a tail self-call in a materialized function: reassign parameters, jump to the top
function Builder:root_tail(frame, args)
    local fn = self.fn
    for _, owned in pairs(self.gs_live or {}) do
        owned.release()
    end
    fn.top_label = fn.top_label or ('L' .. uid())
    local moves = {}
    for i, a in ipairs(args) do
        if fn.dynamic_pos[i] then
            local e = self:call_arg(a)
            local name = fn.param_of[i]
            if not (e.op == 'param' and e.name == name) then
                moves[#moves + 1] = { name = name, e = e, T = a.T }
            end
        end
    end
    self:parallel_assign(moves, function(m, e) return { op = 'setparam', name = m.name, e = e } end,
        function(m) return m.name end)
    self:emit { op = 'goto', label = fn.top_label }
    self.dead = true
end

-- loops: anonymous tail-recursive frames -----------------------------------------------------
-- `next` is a tail call of the loop, `exit` leaves it; a `return` inside a loop
-- returns from the enclosing word, as a loop is a join point, not a word.

-- A loop's state is explicit. The tracked typed locals of the enclosing word
-- that the loop mentions (`state`) are extra parameters: each round works on its
-- own copies, `next` passes them on, and leaving the loop stores them back.
function S.loop(params, args, body, opts)
    opts = opts or {}
    local b = cur()
    local state, names = opts.state or {}, opts.names or {}
    local all_params, vals, slots = {}, {}, {}
    for i, p in ipairs(params) do
        all_params[i] = p
        vals[i] = coerce(args[i], p.T, 'loop ' .. p.name)
    end
    for j, pl in ipairs(state) do
        if is_place(pl) and not pl.T.resizable and tracked(pl) then
            all_params[#all_params + 1] = { name = names[j] or pl.name, T = pl.T }
            vals[#vals + 1] = b:read(pl)
            slots[j] = { place = pl, idx = #all_params }
        else
            slots[j] = { place = pl }        -- memory, or not a place: used as it is
        end
    end
    local nfixed = #params
    local desc = { kind = 'loop', params = all_params, ret = types.Unit, slots = slots, nfixed = nfixed,
                   on_continue = opts.on_continue }
    desc.body = function(...)
        local frame = b.frames[#b.frames]
        local a = { ... }
        local call = {}
        for i = 1, nfixed do call[i] = a[i] end
        frame.fixed = call
        local round = {}
        for j, sl in ipairs(slots) do
            if sl.idx and frame.mode == 'loop' and frame.lvs and frame.lvs[sl.idx] == sl.place then
                -- a residual round works on the loop's own variable
                round[j] = sl.place
            elseif sl.idx then
                local l = b:new_local(sl.place.T, all_params[sl.idx].name)
                b:store(l, a[sl.idx])
                round[j] = l
            else
                round[j] = sl.place
            end
            call[nfixed + j] = round[j]
        end
        frame.round = round
        body(unpack(call, 1, nfixed + #slots))
    end
    return b:run_frame(desc, vals, {})
end

-- the full arguments of the next round: the loop's own, then its state
h.round_args = function(b, frame, fixed)
    local args = {}
    for i = 1, frame.desc.nfixed do
        local p = frame.desc.params[i]
        args[i] = coerce(fixed[i], p.T, 'loop ' .. p.name)
    end
    for j, sl in ipairs(frame.desc.slots) do
        if sl.idx then args[sl.idx] = b:read(frame.round[j]) end
    end
    return args
end

local function loop_frame(b, what)
    for i = #b.frames, 1, -1 do
        local f = b.frames[i]
        if f.kind == 'loop' then return f end
        if f.kind == 'word' then break end
    end
    fail(what .. ' outside a loop', 3)
end

function S.loop_next(...)
    local b = cur()
    if b.dead then return end
    local frame = loop_frame(b, 'next')
    local args = h.round_args(b, frame, { ... })
    if frame.mode == 'inline' then
        if round_known(b, frame, args) and frame.rounds < LOOP_FUEL then
            signal('tail', frame, { args = args })
        end
        signal('restart', frame, { widen = changed(frame.args, args), mode = 'loop' })
    end
    b:jump_next(frame, args)
end

function S.loop_exit()
    local b = cur()
    if b.dead then return end
    local frame = loop_frame(b, 'break')
    if frame.mode == 'inline' and b.block ~= frame.base_block then
        signal('restart', frame, { mode = 'loop' })
    end
    -- the state goes back where it came from
    if frame.mode == 'loop' then
        -- all at once: a state place may be its own loop variable, and the
        -- new values can read the old ones
        local moves = {}
        for j, sl in ipairs(frame.desc.slots) do
            if sl.idx then
                local e = ex(b:read(frame.round[j]))
                if not (e.op == 'read' and e.place == sl.place) then
                    moves[#moves + 1] = { var = sl.place, e = e }
                end
            end
        end
        for _, m in ipairs(moves) do
            for _, l in ipairs(leaves(m.var)) do b:invalidate(l) end
        end
        b:parallel_assign(moves, function(m, e) return { op = 'store', place = m.var, e = e } end,
            function(m) return m.var end)
        for _, m in ipairs(moves) do
            for _, l in ipairs(leaves(m.var)) do
                if tracked(l) then b.state[l] = { mat = true, ver = new_version() } end
            end
        end
    else
        b.storeback = true
        local ok, err = pcall(function()
            for j, sl in ipairs(frame.desc.slots) do
                if sl.idx then S.set(sl.place, b:read(frame.round[j])) end
            end
        end)
        b.storeback = false
        if not ok then error(err, 0) end
    end
    if frame.mode == 'inline' then
        if b.block ~= frame.base_block then signal('restart', frame, { mode = 'loop' }) end
        frame.exited = true
        b.dead = true
        return
    end
    b:exit_loop(frame)
end
S.loop_break = S.loop_exit

function S.loop_continue()
    local b = cur()
    if b.dead then return end
    local frame = loop_frame(b, 'continue')
    frame.desc.on_continue(frame)
end

-- `for i: T = lo, hi, step do body end`
function S.for_(t, lo, hi, step, body, state, names)
    local b = cur()
    if not is_type(t) or t.kind ~= 'int' then
        fail('a native for loop needs an integer induction type', 2)
    end
    local lv = value_of(lo, t, 'for start')
    local hv = value_of(hi, t, 'for limit')
    step = step or 1
    if type(step) ~= 'number' or step == 0 or step ~= math.floor(step) then
        fail('a native for loop step must be a nonzero integer literal', 2)
    end
    if hv.k == 'dyn' and hv.e.op ~= 'param' and hv.e.op ~= 'read' then
        -- the limit is evaluated once
        local tmp = b:new_temp(t, 'limit')
        b:emit { op = 'let', place = tmp, e = hv.e }
        hv = dyn(t, read_expr(tmp))
    elseif hv.k == 'dyn' then
        hv = b:bind(hv)
    end
    -- the limit is tested after the body, so the variable never steps past it
    local unsigned = t.signed and types['U' .. t.bits] or t
    local function last(i)
        if step == 1 or step == -1 then return S.eq(i, hv) end
        if step > 0 then return S.lt(unsigned(hv) - unsigned(i), step) end
        return S.lt(unsigned(i) - unsigned(hv), -step)
    end
    local function step_or_exit(i)
        S.if_(last(i), function() S.loop_exit() end, function()
            S.loop_next(step > 0 and (i + step) or (i - (-step)))
        end)
    end
    local guard = step > 0 and S.le(lv, hv) or S.ge(lv, hv)
    S.if_(guard, function()
        S.loop({ { name = 'i', T = t } }, { lv }, function(i, ...)
            body(i, ...)
            if b.dead then return end
            step_or_exit(i)
        end, { state = state, names = names, on_continue = function(frame)
            step_or_exit(frame.fixed[1])
        end })
    end)
end

-- `while c do body end`. With a host condition it still runs at compile time
-- while its rounds stay known (a generation-time loop)
function S.while_(cf, body, state, names)
    local b = current
    if not b then
        while cf() do body() end
        return
    end
    S.loop({}, {}, function(...)
        local round = { ... }
        local n = select('#', ...)
        S.if_(cf(...), function()
            body(unpack(round, 1, n))
            if not b.dead then S.loop_next() end
        end, function() S.loop_exit() end)
    end, { state = state, names = names, on_continue = function() S.loop_next() end })
end

-- functions ----------------------------------------------------------------------------------

h.new_fn = function(name, w, key)
    return { name = name, cname = nil, word = w, key = key, params = {}, ret = w.ret,
             locals = {}, body = {}, status = 'building' }
end

-- the argument expression passed to a materialized function for value v
function Builder:call_arg(v)
    if v.k == 'ref' then
        local p = v.place
        if p.pk == 'deref' then return { op = 'addr', place = p, T = v.T } end
        self:escape(p)
        return { op = 'addr', place = p, T = v.T }
    end
    return ex(v)
end

function Builder:call_materialized(w, args, key)
    local fn = module.by_key[key] or build_function(w, args, key)
    self:bump_checked()          -- the callee may change any storage it reaches
    local cargs = {}
    for i, a in ipairs(args) do
        if fn.dynamic_pos[i] then cargs[#cargs + 1] = self:call_arg(a) end
    end
    local call = { op = 'call', fn = fn, args = cargs, T = w.ret,
                   gs_off = self.gs_offset and self:gs_offset() or 0 }
    if w.ret.kind == 'unit' then
        self:emit { op = 'expr', e = call, what = 'a call to ' .. w.name }
        return nil
    end
    local t = self:new_temp(w.ret)
    self:emit { op = 'let', place = t, e = call, what = 'a call to ' .. w.name }
    return dyn(w.ret, read_expr(t))
end

-- construct the residual C function for a specialization key
function build_function(w, args, key, cname, opts)
    local fn = h.new_fn(w.name, w, key)
    fn.task = opts and opts.task
    fn.capture = opts and opts.capture
    fn.cname = cname and unique(module.names, cname) or unique(module.names, w.name)
    fn.exported = cname ~= nil
    fn.dynamic_pos = {}
    module.by_key[key] = fn
    module.functions[#module.functions + 1] = fn

    local b = new_builder(fn)
    local names = {}
    local vals = {}
    fn.param_of = {}
    for i, a in ipairs(args) do
        local p = w.params[i] or { name = (w.rest or 'arg') .. (i - #w.params) }
        if static(a) then
            vals[i] = a
        else
            fn.dynamic_pos[i] = true
            local base = p.name
            if base == '__home' then
                -- an unnamed home is named after its type in C
                local t = a.T.kind == 'ref' and a.T.elem or a.T
                base = (t.name or 'home'):gsub('(%l)(%u)', '%1_%2'):lower()
            end
            local pname = unique(names, base)
            fn.param_of[i] = pname
            if a.k == 'ref' then
                local cp = { name = pname, T = a.T }
                fn.params[#fn.params + 1] = cp
                local target = new_place { pk = 'deref', T = a.T.elem, name = p.name,
                    ptr = { op = 'param', name = pname, T = a.T, fn = fn }, id = uid() }
                vals[i] = ref(target)
            else
                local cp = { name = pname, T = a.T }
                fn.params[#fn.params + 1] = cp
                vals[i] = dyn(a.T, { op = 'param', name = pname, T = a.T, fn = fn })
            end
        end
    end
    fn.param_names = names

    push_builder(b)
    local frame = { kind = 'word', mode = 'root', word = w, key = key, ret = w.ret, base_block = fn.body,
                    sites = {}, args = vals, shape = shape_of(vals) }
    b.active[key] = 1
    push_frame(b, frame)
    local ok, err = pcall(w.body, unpack(vals, 1, #args))
    pop_frame(b)
    pop_builder()
    if not ok then error(err, 0) end
    if fn.top_label then
        -- tail self-calls jump to the top: the body is a loop
        local body = fn.body
        fn.body = { { op = 'loop', body = body, top = fn.top_label } }
    end
    if not b.dead then
        if w.ret.kind ~= 'unit' then
            fail(('word %s (%s) can reach its end without returning a %s'):format(w.name, w.loc or '?',
                w.ret.display), 2)
        end
        fn.body[#fn.body + 1] = { op = 'ret' }
    end
    if fn.capture then S.capture_leaves(fn) end
    S.check_isolated(fn)
    if fn.task then S.check_task_waits(fn) end
    fn.status = 'done'
    return fn
end

-- evaluate an application entirely at compile time (host code calling a word)
local function comptime(w, args)
    for i, a in ipairs(args) do
        if not static(a) then
            fail(("%s applied at compile time with argument '%s' not known"):format(w.name,
                w.params[i] and w.params[i].name or ((w.rest or 'arg') .. (i - #w.params))), 3)
        end
    end
    local key = spec_key(w, args)
    local b = new_builder(nil)
    push_builder(b)
    local frame = { kind = 'word', mode = 'comptime', word = w, key = key, ret = w.ret, args = args,
                    shape = shape_of(args) }
    b.active[key] = 1
    push_frame(b, frame)
    local ok, err = pcall(w.body, unpack(args, 1, #args))
    pop_frame(b)
    pop_builder()
    if not ok then error(err, 0) end
    if not b.dead and w.ret.kind ~= 'unit' then
        fail(('word %s can reach its end without returning a %s'):format(w.name, w.ret.display), 3)
    end
    local r = frame.direct
    if r ~= nil and not is_known(r) then
        fail(('%s does not produce a compile-time value'):format(w.name), 3)
    end
    return r
end

function invoke(w, args)
    if not current then return comptime(w, args) end
    return current:apply(w, args)
end

-- export a word as a C function; its remaining requirements become parameters
-- The runtime's exports are lazy while a program is built with it: `export`
-- only records the word, and the function is made when something in the program
-- names it (S.resolve_runtime), so a program carries the runtime words it reaches.
function S.runtime_exports(on) module.lazy_mode = on and true or nil end

local function export_args(w, cname)
    local args = {}
    for i, p in ipairs(w.params) do
        if w.supplied[i] then
            args[i] = w.supplied[i]
        elseif p.static then
            fail(("export %s: compile-time parameter '%s' must be supplied first"):format(cname, p.name), 2)
        elseif p.T.kind == 'ref' then
            args[i] = setmetatable({ T = p.T, k = 'ref', place = { pk = 'deref' } }, V)
        else
            args[i] = dyn(p.T, { op = 'param', name = p.name, T = p.T })
        end
    end
    return args
end

function S.resolve_runtime(cname)
    local words = module.lazy
    local w = words and words[cname]
    if not w then return nil end
    module.lazy_fns = module.lazy_fns or {}
    local fn = module.lazy_fns[cname]
    if fn then return fn end
    local args = export_args(w, cname)
    fn = build_function(w, args, spec_key(w, args) .. '@' .. cname, cname)
    fn.export_name = cname
    module.lazy_fns[cname] = fn
    return fn
end

function S.export_word(w, cname)
    if not is_word(w) then fail(('export %s: not a native word (%s)'):format(cname, describe(w)), 2) end
    if module.lazy_mode then
        module.lazy = module.lazy or {}
        module.lazy[cname] = w
        return
    end
    local args = {}
    for i, p in ipairs(w.params) do
        if w.supplied[i] then
            args[i] = w.supplied[i]
        elseif p.static then
            fail(("export %s: compile-time parameter '%s' must be supplied first"):format(cname, p.name), 2)
        elseif p.T.kind == 'ref' then
            args[i] = setmetatable({ T = p.T, k = 'ref', place = { pk = 'deref' } }, V)
        else
            args[i] = dyn(p.T, { op = 'param', name = p.name, T = p.T })
        end
    end
    local key = spec_key(w, args)
    local fn = module.by_key[key]
    if fn and not fn.exported then
        -- already materialized internally: the same function, now exported
        fn.exported = true
        fn.cname = unique(module.names, cname)
    elseif fn then
        fn = build_function(w, args, key .. '@' .. cname, cname)
    else
        fn = build_function(w, args, key, cname)
    end
    fn.export_name = fn.export_name or cname
    module.exports[#module.exports + 1] = fn
    return fn
end

S.export = S.export_word

-- test "name" do ... end: a word with no parameters, materialized so `slc test`
-- can call it; its body runs under the runtime's trap recovery.
local test_ids = 0
function S.test(name, body)
    local nm = type(name) == 'string' and name or (is_value(name) and name.k == 'known' and name.v) or nil
    if type(nm) ~= 'string' then
        fail('test "name" do ... end: the name must be text known while compiling', 2)
    end
    if body == nil then
        -- `test "name" do ... end` reaches the macro as test("name")(function ...):
        -- the declaration hands back what the block is applied to
        return function(block) return S.test(nm, block) end
    end
    if type(body) ~= 'function' and not (getmetatable(body) and getmetatable(body).__call) then
        fail('test "name" do ... end takes a block, got ' .. describe(body), 2)
    end
    test_ids = test_ids + 1
    local w = S.word { name = 'test ' .. nm, params = {}, result = types.Unit,
                       loc = S.site('test'), body = function() body() end }
    local fn = build_function(w, {}, 'test#' .. test_ids, nil, {})
    fn.test_name = nm
    fn.exported = true
    fn.cname = fn.cname or unique(module.names, 'slc_test_' .. test_ids)
    fn.export_name = nm
    module.tests = module.tests or {}
    module.tests[#module.tests + 1] = fn
    module.exports[#module.exports + 1] = fn
    return fn
end

-- check(cond): a test's assertion; a known false one fails while compiling, a
-- dynamic one traps where it runs, naming the site
function S.check(cond)
    -- a host boolean (a plain block's comparison) is decided now
    if type(cond) == 'boolean' then
        if not cond then fail(('check failed: %s'):format(S.site('check')), 3) end
        return
    end
    local cv = condition(cond)
    if not cv then fail('check(cond) takes a Bool', 2) end
    if cv.k == 'known' then
        if not cv.v then fail(('check failed: %s'):format(S.site('check')), 3) end
        return
    end
    S.if_(cond, nil, function()
        S.trap(known(types.CString, 'check failed: ' .. S.site('check')))
    end)
end

-- materialize a word to call now (the in-process backend): like an export, but
-- a function of its own that the module's C does not include
local natives = 0
function S.native_word(w)
    if not is_word(w) then fail(('native: not a native word (%s)'):format(describe(w)), 3) end
    local args = {}
    for i, p in ipairs(w.params) do
        if w.supplied[i] then
            args[i] = w.supplied[i]
        elseif p.static then
            fail(("native: compile-time parameter '%s' must be supplied first"):format(p.name), 3)
        elseif p.T.kind == 'ref' then
            args[i] = setmetatable({ T = p.T, k = 'ref', place = { pk = 'deref' } }, V)
        else
            args[i] = dyn(p.T, { op = 'param', name = p.name, T = p.T })
        end
    end
    natives = natives + 1
    local fn = build_function(w, args, spec_key(w, args) .. '@native' .. natives, 'native_' .. natives)
    fn.exported = true
    return fn
end

-- methods: words attached to struct types, receiving the receiver by reference
function S.method(t, name, spec)
    if not is_type(t) or t.kind ~= 'struct' then
        fail(('method %s: %s is not a struct type'):format(name, describe(t)), 2)
    end
    if t.index[name] then fail(("%s already has a field '%s'"):format(t.display, name), 2) end
    if name:sub(1, 2) == '__' and not S.receiver_hooks[name] then
        fail(("%s is a hook, not a method: write function %s.%s(...) with explicit operands")
            :format(name, t.display, name), 2)
    end
    local params = { { 'self', types.ref(t) } }
    for _, p in ipairs(spec.params) do params[#params + 1] = p end
    spec.params = params
    spec.name = spec.name or (t.display .. '_' .. name)
    local w = S.word(spec)
    w.receiver = t
    rawget(t, 'methods')[name] = w
    return w
end

-- a receiver that is a value rather than a place gets a temporary place
local W_call = W.__call
W.__call = function(w, ...)
    if w.receiver and #w.supplied == 0 and select('#', ...) > 0 then
        local self_arg = (...)
        if is_value(self_arg) and self_arg.k ~= 'ref' and self_arg.T == w.receiver and current then
            local tmp = current:new_local(w.receiver, 'self')
            current:store(tmp, self_arg)
            return W_call(w, tmp, select(2, ...))
        end
    end
    return W_call(w, ...)
end

-- foreign C functions: always residual effects ------------------------------------------------

function S.extern(cname, param_types, result, opts)
    for i, t in ipairs(param_types) do
        if not is_type(t) then fail(('extern %s: parameter %d is not a type'):format(cname, i), 2) end
        if t.kind == 'opaque' then fail(('extern %s: parameter %d is opaque; take a Ptr'):format(cname, i), 2) end
    end
    if not is_type(result) then fail(('extern %s: result is not a type'):format(cname), 2) end
    if result.kind == 'opaque' then fail(('extern %s: an opaque result must be a Ptr'):format(cname), 2) end
    local x = setmetatable({ cname = cname, params = param_types, ret = result,
                             header = opts and opts.header, variadic = opts and opts.variadic }, X)
    module.externs[#module.externs + 1] = x
    return x
end

function X:__call(...)
    local b = cur()
    local n = select('#', ...)
    if n ~= #self.params and not (self.variadic and n >= #self.params) then
        fail(('extern %s takes %s%d arguments, got %d'):format(self.cname, self.variadic and 'at least ' or '',
            #self.params, n), 2)
    end
    local args = { ... }
    local cargs = {}
    for i, t in ipairs(self.params) do
        local v = coerce(args[i], t, ('argument %d of %s'):format(i, self.cname))
        cargs[i] = b:call_arg(v)
    end
    for i = #self.params + 1, n do
        -- variadic arguments: native values only, so their C types are known
        local v = args[i]
        if is_place(v) then v = b:read(v) end
        if type(v) == 'string' then v = known(types.CString, v) end
        if not is_value(v) or v.k == 'ref' or v.k == 'agg' or v.k == 'sumv' or v.k == 'array' then
            fail(('variadic argument %d of %s must be a native scalar, a CString or a pointer, got %s'):format(
                i, self.cname, describe(v)), 2)
        end
        cargs[i] = ex(v)
    end
    local call = { op = 'call', ext = self, args = cargs, T = self.ret }
    b:bump_checked()                 -- C may change any storage it reaches
    if self.ret.kind == 'unit' then
        b:emit { op = 'expr', e = call, what = 'a foreign call to ' .. self.cname }
        return nil
    end
    local t = b:new_temp(self.ret)
    b:emit { op = 'let', place = t, e = call, what = 'a foreign call to ' .. self.cname }
    return dyn(self.ret, read_expr(t))
end
function X:__tostring() return '<extern ' .. self.cname .. '>' end

-- callbacks ------------------------------------------------------------------------------------
-- An untyped lambda inside a typed body is a callback: evaluated in place like a
-- word, with staged control flow, and its `return` leaves only the callback.
-- Its result type comes from its returns.

function S.callback(name, loc, f)
    local body = function(...)
        local t, n = { ... }, select('#', ...)
        for i = 1, n do if t[i] == S.NIL then t[i] = nil end end
        return f(unpack(t, 1, n))
    end
    local desc = { kind = 'word', name = name, loc = loc, body = body, infer = true }
    return function(...)
        local args = { ... }
        local n = select('#', ...)
        for i = 1, n do
            if args[i] == nil then args[i] = S.NIL end
        end
        local b = current
        local fresh = not b
        if fresh then b = new_builder(nil); push_builder(b) end
        local mode = fresh and 'comptime' or (b.fn and 'inline' or 'comptime')
        local ok, r = pcall(b.run_frame, b, desc, args, { mode = mode })
        if fresh then pop_builder() end
        if not ok then error(r, 0) end
        return r
    end
end

-- a placeholder for a nil argument, so argument lists keep their length
S.NIL = setmetatable({}, { __tostring = function() return 'nil' end })

-- packs ----------------------------------------------------------------------------------------
-- A rest requirement collects the remaining components into a pack: a static
-- length and components, second-class. `...args` contributes them, `args.length`
-- is the length, `args[i]` a component (a static index, from 1).

local Pack = { __name = 'Pack' }
Pack.__index = function(p, k)
    if k == 'length' then return #rawget(p, 'c') end
    if type(k) == 'number' then
        if k ~= math.floor(k) or k < 1 or k > #rawget(p, 'c') then
            fail(('pack-index: %s is not a component index of a pack of %d'):format(tostring(k), #rawget(p, 'c')), 2)
        end
        return rawget(p, 'c')[k]
    end
    if is_value(k) then
        if k.k ~= 'known' then fail('pack-index: a pack index must be known at compile time', 2) end
        return Pack.__index(p, tonumber(k.v))
    end
    fail(("pack-use: a pack has a length and components, not '%s'"):format(tostring(k)), 2)
end
Pack.__newindex = function() fail('pack-use: a pack cannot be modified', 2) end
Pack.__tostring = function(p) return '<pack of ' .. #rawget(p, 'c') .. '>' end
for _, mm in ipairs { '__add', '__sub', '__mul', '__div', '__mod', '__unm', '__concat', '__len', '__call' } do
    Pack[mm] = function() fail('pack-use: a pack is not a value; spread it with ...', 2) end
end

function S.pack(comps)
    for i, c in ipairs(comps) do if c == S.NIL then comps[i] = nil end end
    return setmetatable({ c = comps }, Pack)
end
local function is_pack(x) return getmetatable(x) == Pack end
S.is_pack = is_pack

function S.no_pack(x)
    if is_pack(x) then
        fail('pack-use: a pack is not a value: it cannot be passed, stored or returned whole; '
            .. 'spread it with ...args', 3)
    end
end

-- ordered spread ---------------------------------------------------------------------------------
-- f(a, ...p, b): each item is evaluated once, left to right. A spread item
-- contributes a pack's components or a host call's results; records do not
-- expand positionally.

local Spread = { __name = 'Spread' }
function S.sp(...)
    local n = select('#', ...)
    if n == 1 then
        local x = (...)
        if is_pack(x) then return setmetatable({ c = rawget(x, 'c'), n = #rawget(x, 'c') }, Spread) end
        if is_staged(x) then
            local t = x.T
            if t.kind == 'ref' then t = t.elem end
            if t.kind == 'struct' then
                fail(('spread-source: a %s record expands only by key (%s { ...r }), not into an '
                    .. 'ordered list'):format(t.display, t.display), 2)
            end
            fail(('spread-source: a %s value has no components to spread'):format(t.display), 2)
        end
        if type(x) == 'table' and not getmetatable(x) then
            fail('spread-source: Lua tables do not expand into ordered supplies (runtime-length '
                .. 'expansion is deferred); spread a pack or several results', 2)
        end
        fail(('spread-source: %s has no components to spread'):format(tostring(x)), 2)
    end
    -- several results of a host call contribute directly
    return setmetatable({ c = { ... }, n = n }, Spread)
end

function S.expand(...)
    local out, k = {}, 0
    local n = select('#', ...)
    local items = { ... }
    for i = 1, n do
        local x = items[i]
        if getmetatable(x) == Spread then
            for j = 1, x.n do k = k + 1; out[k] = x.c[j] end
        else
            k = k + 1; out[k] = x
        end
    end
    return unpack(out, 1, k)
end

-- saturating chains --------------------------------------------------------------------------------
-- f(a)(b) do ... end: on a word, the arguments accumulate until it is saturated
-- (surplus applies to the result); on a Lua function with a declared arity the
-- same; on any other function each group is its own application.

S.arity = setmetatable({}, { __mode = 'k' })
for _, name in ipairs { 'band', 'bor', 'bxor', 'shl', 'shr' } do S.arity[S[name]] = 2 end

function S.args(...)
    return { n = select('#', ...), ... }
end

function S.chain(f, ...)
    local groups = { ... }
    local all, k = {}, 0
    local function take(g) for i = 1, g.n do k = k + 1; all[k] = g[i] end end
    if is_word(f) then
        for _, g in ipairs(groups) do take(g) end
        return f(unpack(all, 1, k))
    end
    local arity = S.arity[f]
    if arity then
        local gi = 1
        while gi <= #groups and k < arity do take(groups[gi]); gi = gi + 1 end
        local r = f(unpack(all, 1, k))
        if gi <= #groups then return S.chain(r, unpack(groups, gi)) end
        return r
    end
    local r = f
    for _, g in ipairs(groups) do r = r(unpack(g, 1, g.n)) end
    return r
end

-- obj:m(a)(b) do ... end
function S.mchain(obj, name, first, ...)
    local f = obj[name]
    if f == nil then fail(("%s has no method '%s'"):format(describe(obj), name), 2) end
    local g = { n = first.n + 1, obj }
    for i = 1, first.n do g[i + 1] = first[i] end
    return S.chain(f, g, ...)
end

function S.bmchain(obj, name, first, ...)
    local f = obj[name]
    if f == nil then fail(("%s has no method '%s'"):format(describe(obj), name), 2) end
    local g = { n = first.n + 1, obj }
    for i = 1, first.n do g[i + 1] = first[i] end
    return S.chain(S.boundary(f), g, ...)
end

-- keyed spread: T { ...p, x = 5 } ---------------------------------------------------------------

local Keyed = { __name = 'Keyed' }
S.Keyed = Keyed

-- the data fields of a record source, as values
h.record_fields = function(x)
    local t = is_staged(x) and x.T
    if t and t.kind == 'ref' then t = t.elem end
    if not t or t.kind ~= 'struct' then
        fail(('spread-source: keyed spread takes a record, got %s'):format(describe(x)), 3)
    end
    local out = {}
    for _, f in ipairs(t.fields) do
        local m = member(x, f.name)
        if is_place(m) and not m.T.resizable then m = cur():read(m) end
        out[#out + 1] = { f.name, m }
    end
    return out
end

-- items: { 'spread', source } or { 'field', name, value }, in source order
function S.keyed(items)
    local spread_from, explicit, names = {}, {}, {}
    local fields = {}
    for _, it in ipairs(items) do
        if it[1] == 'field' then
            if explicit[it[2]] then fail(("duplicate field '%s'"):format(it[2]), 2) end
            explicit[it[2]] = true
            names[it[2]] = true
            fields[it[2]] = it[3]
        end
    end
    for n, it in ipairs(items) do
        if it[1] == 'spread' then
            for _, fv in ipairs(h.record_fields(it[2])) do
                local name = fv[1]
                if spread_from[name] then
                    fail(("spread-overlap: field '%s' comes from two spreads"):format(name), 2)
                end
                spread_from[name] = n
                names[name] = true
                if not explicit[name] then fields[name] = fv[2] end
            end
        end
    end
    return setmetatable({ fields = fields, names = names }, Keyed)
end

-- opening: names introduced by a context -----------------------------------------------------------
-- A record (or reference to one) introduces its field names as live places of
-- the retained receiver; methods stay attached to it (bare calls use it); a Lua
-- table (a vocabulary) introduces its string keys.

local LUA_GLOBALS = {}
for k in pairs(_G) do LUA_GLOBALS[k] = true end

local function record_type(x)
    if is_staged(x) then
        local t = x.T
        if t.kind == 'ref' then t = t.elem end
        if t.kind == 'struct' then return t end
    end
end

h.names_of = function(ctx)
    local out = {}
    local t = record_type(ctx)
    if t then
        for _, f in ipairs(t.fields) do out[#out + 1] = f.name end
        return out
    end
    if type(ctx) == 'table' and not is_staged(ctx) and not is_pack(ctx) then
        for k in pairs(ctx) do if type(k) == 'string' then out[#out + 1] = k end end
        table.sort(out)
        return out
    end
    fail(('spread-source: %s introduces no names (open a record, a reference to one, or a table)'):format(describe(ctx)), 3)
end

local function has_name(ctx, name)
    local t = record_type(ctx)
    if t then return t.index[name] ~= nil end
    if type(ctx) == 'table' and not is_staged(ctx) then return rawget(ctx, name) ~= nil end
    return false
end

-- the program's own names, as opposed to Lua's standard library globals
h.visible_global = function(env, name)
    local v = env and env[name]
    if v == nil then return false end
    if LUA_GLOBALS[name] and rawget(env, name) == nil and v == _G[name] then return false end
    return true
end

-- check an opening when it happens: its names against the visible declared
-- names, the names earlier openings introduced, and the program's globals
function S.open(ctx, outer, declared, env, label)
    if is_pack(ctx) then fail('spread-source: packs cannot introduce names', 2) end
    for _, name in ipairs(h.names_of(ctx)) do
        for _, d in ipairs(declared) do
            if d == name then
                fail(("spread-shadow: opening %s introduces '%s', which is already a visible name"):format(label, name), 2)
            end
        end
        for _, o in ipairs(outer) do
            if has_name(o, name) then
                fail(("spread-shadow: opening %s introduces '%s', which an enclosing opening already introduced"):format(label, name), 2)
            end
        end
        if h.visible_global(env, name) then
            fail(("spread-shadow: opening %s introduces '%s', which is already a visible name"):format(label, name), 2)
        end
    end
    return ctx
end

-- a declaration inside an opened region must not shadow an introduced name
function S.no_shadow(ctxs, name)
    for _, c in ipairs(ctxs) do
        if has_name(c, name) then
            fail(("spread-shadow: '%s' is a name introduced by an opening; it cannot be declared again"):format(name), 2)
        end
    end
end

local function introduced(ctxs, name)
    for _, c in ipairs(ctxs) do
        if has_name(c, name) then
            local t = record_type(c)
            if t then return member(c, name) end
            return rawget(c, name)
        end
    end
    return nil
end

-- a free name read inside opened regions (innermost context first)
function S.oname(ctxs, name, lexical)
    local found = false
    for _, c in ipairs(ctxs) do if has_name(c, name) then found = true break end end
    if found then
        local lv = lexical()
        if lv ~= nil and not (LUA_GLOBALS[name] and lv == _G[name]) then
            fail(("spread-shadow: '%s' is both an introduced name and a visible binding"):format(name), 2)
        end
        return introduced(ctxs, name)
    end
    return lexical()
end

-- a bare call: an actual member of the innermost receiver that has one wins
function S.ocall(ctxs, name, lexical, ...)
    for _, c in ipairs(ctxs) do
        local t = record_type(c)
        if t and rawget(t, 'methods')[name] then
            return t.methods[name](c, ...)
        end
        if has_name(c, name) then
            local f = introduced(ctxs, name)
            return f(...)
        end
    end
    local f = lexical()
    if f == nil then fail(("'%s' is not defined"):format(name), 2) end
    return f(...)
end

-- a saturating chain headed by a free name: a receiver's member, an introduced
-- name, or the binding outside
function S.ochain(ctxs, name, lexical, first, ...)
    for _, c in ipairs(ctxs) do
        local t = record_type(c)
        if t and rawget(t, 'methods')[name] then
            local g = { n = first.n + 1, c }
            for i = 1, first.n do g[i + 1] = first[i] end
            return S.chain(t.methods[name], g, ...)
        end
        if has_name(c, name) then return S.chain(introduced(ctxs, name), first, ...) end
    end
    local f = lexical()
    if f == nil then fail(("'%s' is not defined"):format(name), 2) end
    return S.chain(f, first, ...)
end

-- assignment to a free name inside opened regions: a field place
function S.oset(ctxs, name, v)
    for _, c in ipairs(ctxs) do
        if has_name(c, name) then
            local t = record_type(c)
            if not t then
                fail(("'%s' comes from an opened table; introduced names cannot be rebound"):format(name), 2)
            end
            local m = member(c, name)
            if not is_place(m) then
                fail(("'%s' is a field of a value (not a place); it cannot be assigned"):format(name), 2)
            end
            S.set(m, v)
            return
        end
    end
    fail(("cannot assign '%s': a typed body can only assign bindings it declares"):format(name), 2)
end

-- sums ---------------------------------------------------------------------------------------------

function S.oneof(name, alts)
    local ok, t = pcall(types.sum, name, alts)
    if not ok then fail((tostring(t):gsub('^[^:]+:%d+: ', '')), 2) end
    return t
end

-- Shape.circle: the constructor of one alternative. A record payload is built
-- by keyed supply, another payload is applied to one value, Unit to nothing.
local constructors = setmetatable({}, { __mode = 'k' })
function S.constructor(t, name)
    local alt = t.index[name]
    if not alt then
        fail(("%s has no alternative '%s'"):format(t.display, tostring(name)), 3)
    end
    constructors[t] = constructors[t] or {}
    local c = constructors[t][name]
    if c then return c end
    local pt = alt.type
    if pt.kind == 'unit' then
        c = function(...)
            if select('#', ...) > 0 then
                fail(('%s.%s takes no payload: %s.%s()'):format(t.display, name, t.display, name), 2)
            end
            return sumv(t, name, nil)
        end
    elseif pt.kind == 'struct' then
        c = function(x)
            local payload = is_staged(x) and coerce(x, pt, 'sum payload') or pt(x)
            return sumv(t, name, payload)
        end
    else
        c = function(x)
            if is_place(x) then x = cur():read(x) end
            return sumv(t, name, coerce(x, pt, ('payload of %s.%s'):format(t.display, name)))
        end
    end
    S.arity[c] = pt.kind == 'unit' and 0 or 1
    constructors[t][name] = c
    return c
end

h.tag_of = function(e) return { op = 'field', a = e, name = 'tag', T = types.U32 } end
h.payload_of = function(e, alt)
    return { op = 'field', a = { op = 'field', a = e, name = 'as' }, name = alt.name, T = alt.type }
end

-- matching is keyed application of a sum value: one handler per alternative
local function match(s, handlers)
    if is_place(s) then s = cur():read(s) end
    local t = s.T
    if type(handlers) ~= 'table' or is_staged(handlers) or getmetatable(handlers) then
        fail(('matching a %s takes one handler per alternative: s { %s = do(p) ... end, ... }'):format(
            t.display, t.alts[1].name), 3)
    end
    for k in pairs(handlers) do
        if type(k) ~= 'string' or not t.index[k] then
            fail(("%s has no alternative '%s' to handle"):format(t.display, tostring(k)), 3)
        end
    end
    for _, alt in ipairs(t.alts) do
        if handlers[alt.name] == nil then
            fail(("matching a %s: alternative '%s' has no handler"):format(t.display, alt.name), 3)
        end
    end
    local function call(alt, payload)
        local h = handlers[alt.name]
        local mt = getmetatable(h)
        if type(h) ~= 'function' and not (mt and mt.__call) then
            fail(("the handler for '%s' is not callable"):format(alt.name), 4)
        end
        if alt.type.kind == 'unit' then return h() end
        return h(payload)
    end
    if s.k == 'sumv' then
        -- a known tag: only the selected handler runs
        return call(t.index[rawget(s, 'tag')], rawget(s, 'p'))
    end
    -- a runtime tag: a test per alternative, the payload projected in its arm
    local b = cur()
    local v = b:bind(s)
    local e = ex(v)
    local desc = { kind = 'word', name = 'match on ' .. t.display, infer = true, body = function()
        local function arm(i)
            local alt = t.alts[i]
            local function run()
                local payload = alt.type.kind ~= 'unit' and dyn(alt.type, h.payload_of(e, alt)) or nil
                S.ret(call(alt, payload))
            end
            if i == #t.alts then return run() end
            S.if_(dyn(types.Bool, { op = 'cmp', o = 'eq', a = h.tag_of(e), T = types.Bool,
                                    b = { op = 'tagname', sum = t, alt = alt.name, T = types.U32 } }),
                run, function() arm(i + 1) end)
        end
        arm(1)
    end }
    return b:run_frame(desc, {}, {})
end
S.match = match

-- Fn values: C function pointers --------------------------------------------------------
-- fnptr(word) materializes the word as a residual function and is its address.
-- Calling an Fn value is a call through it; when the value is a known function
-- the call is direct. A function whose address is taken starts its data stacks
-- at 0, as an export does.

function S.fnptr(w)
    if not is_word(w) then fail('fnptr(word) takes a native word, got ' .. describe(w), 2) end
    local args, ptypes = {}, {}
    for i, p in ipairs(w.params) do
        if w.supplied[i] then
            args[i] = w.supplied[i]
        elseif p.static then
            fail(("fnptr: compile-time parameter '%s' must be supplied first"):format(p.name), 2)
        else
            if p.T.kind == 'ref' then
                args[i] = setmetatable({ T = p.T, k = 'ref', place = { pk = 'deref' } }, V)
            else
                args[i] = dyn(p.T, { op = 'param', name = p.name, T = p.T })
            end
            ptypes[#ptypes + 1] = p.T
        end
    end
    local key = spec_key(w, args)
    local fn = module.by_key[key] or build_function(w, args, key)
    fn.addr_taken = true
    local ft = types.fn(ptypes, w.ret)
    return dyn(ft, { op = 'fnaddr', fn = fn, T = ft })
end

-- null(Fn(...)) is the null function pointer
local function call_fn(x, ...)
    local ft = x.T
    local n = select('#', ...)
    if n ~= #ft.params then
        fail(('%s takes %d arguments, got %d'):format(ft.display, #ft.params, n), 3)
    end
    local b = cur()
    local cargs = {}
    for i, t in ipairs(ft.params) do
        cargs[i] = b:call_arg(coerce((select(i, ...)), t, ('argument %d of %s'):format(i, ft.display)))
    end
    local call = { op = 'calli', a = ex(x), args = cargs, T = ft.ret }
    b:bump_checked()
    if ft.ret.kind == 'unit' then
        b:emit { op = 'expr', e = call, what = 'a call through a function pointer' }
        return nil
    end
    local t = b:new_temp(ft.ret)
    b:emit { op = 'let', place = t, e = call, what = 'a call through a function pointer' }
    return dyn(ft.ret, read_expr(t))
end

V.__call = function(x, ...)
    if x.T.kind == 'sum' then return match(x, ...) end
    if x.T.kind == 'fn' then return call_fn(x, ...) end
    fail(('a %s value is not callable'):format(x.T.display), 2)
end
P.__call = function(x, ...)
    if x.T.kind == 'sum' then return match(x, ...) end
    if x.T.kind == 'fn' then return call_fn(cur():read(x), ...) end
    fail(('a %s place is not callable'):format(x.T.display), 2)
end

-- Native globals ---------------------------------------------------------------------------
-- global(T, { name, thread_local, exported, imported, init }) is static storage
-- for the whole program; `imported` names an object another unit defines (a
-- header declares it). It is the Ptr T of a C object: g[0] (or g.field) is the place,
-- so reads and writes are memory operations in source order. `exported` gives the C
-- object external linkage under `name` (a header may declare it); `init` is a
-- scalar the object starts with, otherwise it is zero.

function S.global(t, opts)
    if not is_type(t) then fail('global(T, opts) takes a type, got ' .. describe(t), 2) end
    if t.resizable or t.kind == 'unit' or t.kind == 'opaque' or t.kind == 'ref' or t.kind == 'chan'
        or rawget(t, 'slice_elem') then
        fail('global: a ' .. t.display .. ' cannot be static storage', 2)
    end
    opts = opts or {}
    if (opts.exported or opts.imported) and not opts.name then fail('global: an exported or imported global needs a name', 2) end
    if opts.exported and opts.imported then fail('global: a global is exported or imported, not both', 2) end
    if opts.init ~= nil and not (types.is_scalar(t) and type(opts.init) == 'number') then
        fail('global: init is a number for an integer or float global', 2)
    end
    local g = { T = t, name = opts.name or 'global', exported = opts.exported and true or nil,
                imported = opts.imported and true or nil, header = opts.header,
                tls = opts.thread_local and true or nil, init = opts.init }
    local pt = types.ptr(t)
    return dyn(pt, { op = 'gaddr', global = g, T = pt })
end

local global_names = setmetatable({}, { __mode = 'k' })
-- the C name of a global in the module being emitted
function S.global_cname(g)
    local names = global_names[g]
    if not names then names = setmetatable({}, { __mode = 'k' }); global_names[g] = names end
    local name = names[module]
    if not name then
        if g.exported or g.imported then
            -- the same C object may be defined once and declared by several users
            local seen = module.global_names and module.global_names[g.name]
            if seen == nil then
                if module.names[g.name] then error('global ' .. g.name .. ': the C name is already in use', 0) end
                module.names[g.name] = true
                module.global_names = module.global_names or {}
                module.global_names[g.name] = { exported = g.exported }
            elseif g.exported then
                if seen.exported then error('global ' .. g.name .. ': defined twice', 0) end
                seen.exported = true
            end
            name = g.name
        else
            name = unique(module.names, g.name)
        end
        names[module] = name
    end
    return name
end

-- raw pointers -------------------------------------------------------------------------------------
-- Ptr T is an address the compiler does not track (Let syntax §8.5): p[i] is an
-- unchecked element place, p.field a field of a record target, Ptr(place) the
-- only place a lifetime is dropped, null(T) the null pointer, == and ~= compare
-- addresses. No other arithmetic, ordering or integer conversion exists.

local function ptr_value(x)
    if is_place(x) then return cur():read(x) end
    return x
end

-- an index operand: an unsigned integer value, U32 for a Lua number
local function index_value(i)
    if is_place(i) then i = cur():read(i) end
    if is_value(i) then
        if i.T.kind ~= 'int' or i.T.signed then
            fail(('an index must be an unsigned integer, got %s'):format(i.T.display), 4)
        end
        return i
    end
    return value_of(i, types.U32, 'index')
end

local function __index(pv, iv, elem)
    local base = ex(pv)
    local idx = iv
    -- an element of `&p[a]` is an element of p: the offsets add
    if base.op == 'addr' and base.place.pk == 'index' and base.place.T == elem then
        local inner = base.place
        local ie = rawget(inner, 'idx')
        local ia = ie.op == 'const' and known(ie.T, ie.v) or dyn(ie.T, ie)
        if ia.T ~= idx.T then idx = ia.T(idx) end
        idx = binary('add', ia, idx)
        base = rawget(inner, 'base')
    elseif base.op == 'addr' and base.place.T == elem and base.place.pk ~= 'index'
        and idx.k == 'known' and tonumber(idx.v) == 0 then
        -- Ptr(place)[0] is the place itself only without a retyped view.
        -- atomic_ptr(Ptr(place))[0] must retain its Atomic element type.
        return base.place
    end
    return new_place { pk = 'index', T = elem, base = base, idx = ex(idx),
                       name = 'element', id = uid() }
end

function member_ptr(x, key)
    local pv = ptr_value(x)
    local elem = pv.T.elem
    if type(key) == 'number' or is_staged(key) then
        return __index(pv, index_value(key), elem)
    end
    if elem.kind == 'struct' and elem.index[key] then
        local e = ex(pv)
        if e.op == 'addr' then return field_place(e.place, key) end   -- Ptr(s).f is s.f
        local target = new_place { pk = 'deref', T = elem, name = 'target', ptr = ex(pv), id = uid() }
        return field_place(target, key)
    end
    fail(("%s: '%s' is not a field of the target; pointers offer p[i] and p.field only"):format(
        pv.T.display, tostring(key)), 3)
end

-- Ptr(T) is the type; Ptr(place) the address of a place, its lifetime dropped
function S.Ptr(x)
    if is_type(x) then return types.ptr(x) end
    local place
    if is_place(x) then place = x
    elseif is_value(x) and x.k == 'ref' then place = x.place
    else
        fail('Ptr(...) takes a type or a place (a typed local, a field, an element), got ' .. describe(x), 2)
    end
    if place.T.resizable then
        fail(('Ptr(...) of a %s: resizable storage moves only by reference'):format(place.T.display), 2)
    end
    local b = cur()
    if place.pk ~= 'deref' and place.pk ~= 'index' then b:escape(place) end
    if place.pk == 'deref' and not rawget(place, 'parent') then
        return dyn(types.ptr(place.T), rawget(place, 'ptr'))
    end
    return dyn(types.ptr(place.T), { op = 'addr', place = place, T = types.ptr(place.T) })
end

function S.null(t)
    if not is_type(t) then fail('null(T) takes a type', 2) end
    if t.kind == 'fn' then return dyn(t, { op = 'null', T = t }) end
    local pt = types.ptr(t)
    return dyn(pt, { op = 'null', T = pt })
end

-- slices -------------------------------------------------------------------------------------------
-- A read-only view with a U32 length. s[i] is checked: at compile time when the
-- index and the length are both known (index-range), otherwise when it runs.

local function slice_parts(s)
    local t = struct_of(s)
    local function part(name)
        local m
        if is_place(s) then m = cur():read(field_place(s, name))
        elseif s.k == 'agg' then m = s.f[name]
        elseif s.k == 'ref' then m = cur():read(field_place(s.place, name))
        else
            local ft = t.index[name].type
            m = dyn(ft, { op = 'field', a = s.e, name = name, T = ft })
        end
        return m
    end
    return part('ptr'), part('len'), t
end

local function check_view(s)
    local v = is_value(s) and rawget(s, 'view')
    if v and v.ended then
        fail('a view of a Grow cannot be used after its view ends', 4)
    end
    return v
end

-- the checked-access words: the bounds and the trap text are library policy
local slice_checks
local function checks()
    if not slice_checks then slice_checks = require('slc.slice') end
    return slice_checks
end

local function bound_check(i, n, what, thing)
    if i.k == 'known' and n.k == 'known' then
        if tonumber(i.v) >= tonumber(n.v) then
            fail(('index-range: %s %s is outside %s of length %s'):format(what, fold.show(i.T, i.v),
                thing or 'a slice', fold.show(n.T, n.v)), 4)
        end
        return
    end
    local b = cur()
    -- a branch on this path already proved i < n
    if b:proves_less(ex(i), ex(n)) then return end
    checks().index(types.U64(i), types.U64(n))
end

-- A read-only view can retain an abstract address while its owner is tracked.
-- The address is materialized only by ex(), never by a content query.
function S.array_pointer(place, offset, builder)
    assert(is_place(place) and place.T.kind == 'array')
    place = S.resolve_checked(place)
    if foreign_place(cur(), place) then
        place = S.capture_place(cur(), place)
        builder = cur()
    end
    return setmetatable({ T = types.ptr(place.T.elem), k = 'array_ptr', place = place,
                          offset = cur():bind(offset or known(types.U32, 0)), builder = builder or cur() }, V)
end

h.array_pointer_read = function(ptr, index)
    if ptr.k ~= 'array_ptr' or ptr.offset.k ~= 'known' or index.k ~= 'known' then return nil end
    local value = ptr.builder:read(ptr.place)
    if value.k ~= 'array' then return nil end
    local i = tonumber(ptr.offset.v) + tonumber(index.v)
    if i < 0 or i >= value.T.length then return nil end
    return Arrays.get(value.contents, i)
end

function S.array_pointer_text(ptr, len)
    if ptr.k ~= 'array_ptr' or ptr.T.elem ~= types.U8 or len.k ~= 'known' or ptr.offset.k ~= 'known' then return nil end
    local value = ptr.builder:read(ptr.place)
    if value.k ~= 'array' then return nil end
    local start, count = tonumber(ptr.offset.v), tonumber(len.v)
    if start < 0 or start + count > value.T.length then return nil end
    local bytes = {}
    for i = start, start + count - 1 do
        local byte = Arrays.get(value.contents, i)
        if byte.k ~= 'known' then return nil end
        bytes[#bytes + 1] = string.char(tonumber(byte.v))
    end
    return table.concat(bytes)
end

local function make_slice(t, ptr, len, view)
    local v = agg(t, { ptr = ptr, len = len })
    if view then rawset(v, 'view', view) end
    return v
end

h.slice_get = function(s, key)
    check_view(s)
    local ptr, len = slice_parts(s)
    local iv = index_value(key)
    if iv.T ~= types.U32 then iv = types.U32(iv) end
    bound_check(iv, len, 'index')
    local value = h.array_pointer_read(ptr, iv)
    if value then return value end
    return cur():read(__index(ptr, iv, ptr.T.elem))
end

h.slice_sub = function(s, a, b_)
    local view = check_view(s)
    local ptr, len, t = slice_parts(s)
    local av, bv = index_value(a), index_value(b_)
    if av.T ~= types.U32 then av = types.U32(av) end
    if bv.T ~= types.U32 then bv = types.U32(bv) end
    if av.k == 'known' and bv.k == 'known' and len.k == 'known' then
        if av.v > bv.v or bv.v > len.v then
            fail(('index-range: sub(%s, %s) is outside a slice of length %s'):format(
                fold.show(av.T, av.v), fold.show(bv.T, bv.v), fold.show(len.T, len.v)), 3)
        end
    elseif av.k == 'known' and bv.k == 'known' and av.v > bv.v then
        fail(('index-range: sub(%s, %s) is empty backwards'):format(fold.show(av.T, av.v), fold.show(bv.T, bv.v)), 3)
    else
        -- All indices are unsigned: 0 <= b is already true. Dropping it keeps
        -- newly propagated constants out of a redundant comparison.
        if av.k == 'known' and av.v == 0 then checks().high(types.U64(bv), types.U64(len))
        elseif bv.k == 'known' and bv.v == 0 then checks().nonempty(types.U64(av))
        else checks().range(types.U64(av), types.U64(bv), types.U64(len)) end
    end
    local p2 = ptr
    if ptr.k == 'array_ptr' then
        p2 = S.array_pointer(ptr.place, binary('add', ptr.offset, av), ptr.builder)
    elseif not (av.k == 'known' and av.v == 0) then
        local pt = ptr.T
        p2 = dyn(pt, { op = 'addr', place = __index(ptr, av, pt.elem), T = pt })
    end
    return make_slice(t, p2, cur():bind(bv - av), view)
end

function member_slice(x, key)
    if key == 'length' then
        check_view(x)
        local _, len = slice_parts(x)
        return len
    end
    if key == 'sub' then
        return function(self, a, b_) return h.slice_sub(self, a, b_) end
    end
    if type(key) == 'number' or is_staged(key) then return h.slice_get(x, key) end
    fail(("%s: a slice offers s[i], s.length and s:sub(a, b), not '%s'"):format(
        struct_of(x).display, tostring(key)), 3)
end

-- Slice(T) is the type; Slice(p, n) a view of n elements at a pointer
function S.Slice(x, n)
    if is_type(x) then
        local ok, t = pcall(types.slice, x)
        if not ok then fail((tostring(t):gsub('^[^:]+:%d+: ', '')), 2) end
        return t
    end
    local pv = is_staged(x) and ptr_value(x)
    if pv and pv.T.kind == 'ptr' and n ~= nil then
        local t = types.slice(pv.T.elem)
        return make_slice(t, pv, coerce(n, types.U32, 'slice length'))
    end
    fail('Slice(T) is a type; Slice(p, n) views n elements at pointer p (a view of a Grow is g:view() do(xs) ... end)', 2)
end
S.make_slice = make_slice
S.slice_parts, S.member_slice, S.bound_check = slice_parts, member_slice, bound_check

-- fixed-length arrays ------------------------------------------------------------------------------
-- a[i] is checked like a slice's (at compile time when the index is known),
-- a.length is known, a:slice() views the elements read-only.

local function array_storage(x, defer)
    -- the C array inside the wrapping struct, as an expression
    local t = struct_of(x)
    if is_place(x) then x = S.resolve_checked(x) end
    if is_value(x) and x.k == 'ref' and checked_root(x.place) then x = S.resolve_checked(x.place) end
    local place = is_place(x) and x or x.k == 'ref' and x.place
    if place then
        if not defer then
            local root = array_path(place)
            cur():materialize(root or place)
        end
        return { op = 'field', a = read_expr(place), name = 'e', T = t }, place
    end
    return nil
end

function S.array_member(x, key, want_place)
    local t = struct_of(x)
    local n = known(types.U32, t.length)
    if key == 'length' then return n end
    if key == 'slice' then
        return function(self)
            local place = is_place(self) and self or self.k == 'ref' and self.place
            if not place then fail('a:slice() needs the array itself (a typed local, a field), not a copy', 2) end
            return make_slice(types.slice(t.elem), S.array_pointer(place), n)
        end
    end
    if type(key) == 'number' or is_staged(key) then
        local iv = index_value(key)
        if iv.T ~= types.U32 then iv = types.U32(iv) end
        bound_check(iv, n, 'index', 'an array')
        local aggregate_place = (is_place(x) or x.k == 'ref')
            and (t.elem.kind == 'struct' or t.elem.kind == 'array')
        if not want_place and not aggregate_place and iv.k == 'known' then
            local value = value_of(x, t, 'array')
            if value.k == 'array' then return Arrays.get(value.contents, tonumber(iv.v)) end
        end
        local base, owner = array_storage(x, aggregate_place or want_place and iv.k == 'known')
        if base then
            local p = new_place { pk = 'index', T = t.elem, base = base, idx = ex(iv), name = 'element', id = uid(),
                                  parent = owner, array_owner = owner,
                                  array_index = iv.k == 'known' and tonumber(iv.v) or nil }
            if want_place or aggregate_place then return p end
            return cur():read(p)
        end
        if want_place then fail('cannot assign to an element of an array value; store it in a typed local first', 3) end
        local xv = value_of(x, t, 'array')
        return dyn(t.elem, { op = 'array_index', a = ex(xv), idx = ex(iv), T = t.elem })
    end
    fail(("%s offers a[i], a.length and a:slice(), not '%s'"):format(t.display, tostring(key)), 3)
end

-- Zero values remain data, including nested aggregates. Unsupported scalar
-- handles stay residual rather than inventing a host representation for them.
local function zero_value(t)
    if t.kind == 'int' or t.kind == 'float' then return known(t, 0) end
    if t.kind == 'bool' then return known(t, false) end
    if t.kind == 'struct' then
        local fields = {}
        for _, f in ipairs(t.fields) do fields[f.name] = S.zero_value(f.type) end
        return agg(t, fields)
    end
    if t.kind == 'array' then return array_value(t, Arrays.new(t, S.zero_value(t.elem))) end
    if t.kind == 'sum' then
        local a = t.alts[1]
        return sumv(t, a.name, a.type.kind ~= 'unit' and S.zero_value(a.type) or nil)
    end
    return dyn(t, { op = 'zero', T = t })
end
S.zero_value = zero_value

function S.array_from_bytes(t, text)
    assert(t.kind == 'array' and t.elem == types.U8 and #text <= t.length)
    local items = {}
    for i = 1, #text do
        local byte = text:byte(i)
        if byte ~= 0 then items[i - 1] = known(types.U8, byte) end
    end
    return array_value(t, Arrays.new(t, known(types.U8, 0), items))
end

function S.Array(elem, n)
    local ok, t = pcall(types.array, elem, n)
    if not ok then fail((tostring(t):gsub('^[^:]+:%d+: ', '')), 2) end
    if not rawget(t, 'construct') then
        -- Array(T, n)() is zeroed; Array(T, n) { a, b, ... } lists every element
        rawset(t, 'construct', function(x)
            if x == nil or (type(x) == 'table' and not is_staged(x) and next(x) == nil) then
                local value = zero_value(t)
                if is_known(value) then return value end
                return dyn(t, { op = 'zero', T = t })
            end
            if type(x) ~= 'table' or is_staged(x) then
                fail(('%s { ... } lists its elements, or %s() is zeroed'):format(t.display, t.display), 3)
            end
            if #x ~= t.length then
                fail(('%s { ... } lists %d elements, got %d'):format(t.display, t.length, #x), 3)
            end
            local fields, items, all_known = {}, {}, true
            for i = 1, t.length do
                local value = coerce(x[i], t.elem, ('element %d of %s'):format(i, t.display))
                items[i - 1] = value
                all_known = all_known and is_known(value)
                fields[i - 1] = ex(value)
            end
            if all_known then return array_value(t, Arrays.new(t, zero_value(t.elem), items)) end
            return dyn(t, { op = 'array', fields = fields, T = t })
        end)
    end
    return t
end


-- formatted output built while specializing ---------------------------------------------------------
-- cformat("n = ", n, "\n") returns a format CString and the arguments, each cast
-- to the C type its conversion expects: the format always matches the values.

local FORMATS = {
    -- the conversion, and the ABI type its argument is promoted to: a varargs
    -- call carries the promoted value, and the format matches that type
    U8 = { '%u', 'uint' }, U16 = { '%u', 'uint' }, U32 = { '%u', 'uint' },
    U64 = { '%llu', 'ullong' },
    I8 = { '%d', 'int' }, I16 = { '%d', 'int' }, I32 = { '%d', 'int' }, I64 = { '%lld', 'llong' },
    F32 = { '%g', 'double' }, F64 = { '%g', 'double' }, Bool = { '%d', 'int' },
}

function S.cformat(...)
    local fmt, args = {}, {}
    for i = 1, select('#', ...) do
        local x = select(i, ...)
        if is_place(x) then x = cur():read(x) end
        if type(x) == 'string' then
            fmt[#fmt + 1] = (x:gsub('%%', '%%%%'))
        elseif type(x) == 'number' then
            fmt[#fmt + 1] = (x == math.floor(x) and ('%.0f'):format(x) or tostring(x))
        elseif type(x) == 'boolean' then
            fmt[#fmt + 1] = tostring(x)
        elseif is_value(x) and x.k == 'known' and x.T.kind == 'cstr' then
            fmt[#fmt + 1] = (x.v:gsub('%%', '%%%%'))
        elseif is_value(x) and x.T.kind == 'cstr' then
            fmt[#fmt + 1] = '%s'
            args[#args + 1] = x
        elseif is_value(x) and x.k == 'known' and FORMATS[x.T.name] then
            -- a known value is printed into the format itself
            fmt[#fmt + 1] = (fold.show(x.T, x.v):gsub('%%', '%%%%'))
        elseif is_value(x) and FORMATS[x.T.name] then
            local f = FORMATS[x.T.name]
            fmt[#fmt + 1] = f[1]
            args[#args + 1] = dyn(x.T, { op = 'vaconv', abi = f[2], a = ex(x), T = x.T })
        else
            fail(('cformat: cannot format %s'):format(describe(x)), 2)
        end
    end
    return known(types.CString, table.concat(fmt)), unpack(args)
end

-- C from headers ---------------------------------------------------------------------------------

local function needs_header(name, header)
    if type(header) ~= 'string' then fail(name .. ': a header such as "<stdio.h>" is required', 3) end
    module.externs[#module.externs + 1] = { cname = name, header = header, params = {}, ret = types.Unit,
                                            declared_only = true }
end

-- a struct whose layout comes from a C header; only the named fields are seen,
-- each optionally mapped to a C member path: { "fd", I32, "data.fd" }
function S.cstruct(cname, header, fields)
    needs_header(cname, header)
    local paths = {}
    local function describe_fields(self)
        local source = type(fields) == 'function' and fields(self) or fields
        if type(source) ~= 'table' then fail('cstruct: fields must be a table or a function returning a table', 2) end
        local list = {}
        for i, f in ipairs(source) do
            list[i] = { f[1], f[2] }
            if f[3] then paths[f[1]] = f[3] end
        end
        return list
    end
    local display = cname:gsub('^struct ', '')
    local ok, t = pcall(types.struct, display, describe_fields)
    if not ok then fail((tostring(t):gsub('^[^:]+:%d+: ', '')), 2) end
    rawset(t, 'cname', cname)
    rawset(t, 'foreign', header)
    rawset(t, 'cpath', paths)
    t.display = cname
    return t
end

-- a constant from a C header: a runtime value C supplies (its platform value)
function S.cconst(name, t, header)
    needs_header(name, header)
    if not is_type(t) then fail('cconst: ' .. name .. ' needs a type', 2) end
    return dyn(t, { op = 'cconst', T = t, cconst = name })
end

-- a C variable or macro read where it is called: cread("errno", I32, "<errno.h>")()
function S.cread(name, t, header)
    if type(header) ~= 'string' then fail('cread: a header is required', 2) end
    local x = setmetatable({ cname = name, params = {}, ret = t, header = header, variable = true }, X)
    module.externs[#module.externs + 1] = x
    return x
end

-- the storage of a place as bytes: a Ptr U8, its lifetime dropped like Ptr(place)
function S.bytes(x)
    local p = S.Ptr(x)
    local u8 = types.ptr(types.U8)
    if p.T == u8 then return p end
    return dyn(u8, { op = 'conv', a = p.e, T = u8 })
end

-- the C size of a type
function S.size_of(t)
    if not is_type(t) then fail('size_of(T) takes a type', 2) end
    return dyn(types.U64, { op = 'sizeof', sizeof = t, T = types.U64, pure = true })
end

-- a scoped read-only view of n elements at p, for library activities
function S.view_of(p, n, body)
    local pv = is_place(p) and cur():read(p) or p
    if not (is_value(pv) and pv.T.kind == 'ptr') then fail('view_of(p, n, body) takes a pointer', 2) end
    local token = {}
    local xs = S.make_slice(types.slice(pv.T.elem), cur():bind(pv), coerce(n, types.U32, 'view length'), token)
    local ok, r = pcall(body, xs)
    token.ended = true
    if not ok then error(r, 0) end
    if is_value(r) and rawget(r, 'view') then fail('a view cannot outlive its activity', 2) end
    return r
end

-- atomics ----------------------------------------------------------------------------------------
-- Atomic operations are effects: never folded, never pending, emitted in source
-- order. Memory orders are compile-time arguments, checked here as C requires.

local ORDERS = { relaxed = '__ATOMIC_RELAXED', consume = '__ATOMIC_ACQUIRE', acquire = '__ATOMIC_ACQUIRE',
                 release = '__ATOMIC_RELEASE', acq_rel = '__ATOMIC_ACQ_REL', seq_cst = '__ATOMIC_SEQ_CST' }
local LOAD_ORDERS = { relaxed = true, consume = true, acquire = true, seq_cst = true }
local STORE_ORDERS = { relaxed = true, release = true, seq_cst = true }

local function order_of(o, allowed, what)
    o = o or 'seq_cst'
    if is_staged(o) then fail(what .. ': a memory order is a compile-time string', 4) end
    if not ORDERS[o] then
        fail(("%s: unknown memory order '%s' (relaxed, acquire, release, acq_rel, seq_cst)"):format(what, tostring(o)), 4)
    end
    if allowed and not allowed[o] then
        fail(("%s: memory order '%s' is not valid for this operation"):format(what, o), 4)
    end
    return ORDERS[o]
end

-- the failure order of a compare-exchange, derived from its success order
local CAS_FAIL = { relaxed = 'relaxed', consume = 'acquire', acquire = 'acquire', release = 'relaxed',
                   acq_rel = 'acquire', seq_cst = 'seq_cst' }

-- An atomic operation is one IR op: the memory order is part of it, so no
-- backend reads a C template for it.
local function atomic_effect(t, o, ptr, args, what, place)
    local e = { op = 'atomic', o = o, ptr = ptr, args = args.values or {}, T = t, place = place,
                order = args.order, fail_order = args.fail_order, expected_place = args.expected }
    local b = cur()
    if t.kind == 'unit' then
        b:emit { op = 'expr', e = e, what = what }
        return nil
    end
    local tmp = b:new_temp(t)
    b:emit { op = 'let', place = tmp, e = e, what = what }
    return dyn(t, read_expr(tmp))
end

function S.atomic_method(x, key)
    if not is_place(x) then fail('atomic operations need the atomic place itself', 3) end
    local t = x.T
    local et = t.elem
    local function addr() return { op = 'addr', place = x, T = types.ptr(t) } end
    local function operand(v, what) return ex(coerce(v, et, what)) end
    local methods = {
        load = function(self, order)
            return atomic_effect(et, 'load', addr(), { values = {}, order = order_of(order, LOAD_ORDERS, 'load') },
                'an atomic load')
        end,
        store = function(self, v, order)
            atomic_effect(types.Unit, 'store', addr(),
                { values = { operand(v, 'value stored') }, order = order_of(order, STORE_ORDERS, 'store') },
                'an atomic store')
        end,
        exchange = function(self, v, order)
            return atomic_effect(et, 'exchange', addr(),
                { values = { operand(v, 'value exchanged') }, order = order_of(order, nil, 'exchange') },
                'an atomic exchange')
        end,
        -- compare-and-swap: true when the value was `expected` and is now `desired`
        cas = function(self, expected, desired, order)
            local o = order or 'seq_cst'
            local succ = order_of(o, nil, 'cas')
            local fail_o = ORDERS[CAS_FAIL[o]]
            local b = cur()
            local slot = b:new_temp(et, 'expected')
            b:emit { op = 'let', place = slot, e = operand(expected, 'expected value') }
            return atomic_effect(types.Bool, 'cas', addr(),
                { values = { operand(desired, 'desired value') }, expected = slot, order = succ,
                  fail_order = fail_o }, 'an atomic compare-exchange', slot)
        end,
    }
    if et.kind == 'int' then
        -- read-modify-write: the result is the value before
        methods.add = function(self, v, order)
            return atomic_effect(et, 'fetch_add', addr(),
                { values = { operand(v, 'addend') }, order = order_of(order, nil, 'add') }, 'an atomic add')
        end
        methods.sub = function(self, v, order)
            return atomic_effect(et, 'fetch_sub', addr(),
                { operand(v, 'subtrahend'), order = order_of(order, nil, 'sub') }, 'an atomic sub')
        end
    end
    local m = methods[key]
    if not m then
        fail(("%s offers load, store, exchange, cas%s; not '%s'"):format(t.display,
            et.kind == 'int' and ', add, sub' or '', tostring(key)), 3)
    end
    S.arity[m] = nil
    return m
end

-- a memory fence
function S.fence(order)
    local o = order_of(order, nil, 'fence')
    cur():emit { op = 'fence', order = o, what = 'a fence' }
end

-- trap(message): stop the program. The message is a known CString, and the
-- statement has no memory effect, so a check around it cannot invalidate the
-- values the checked code goes on to use.
function S.trap(msg)
    local mv = is_place(msg) and cur():read(msg) or msg
    local ev = ex(coerce(mv, types.CString, 'trap'))
    if not (ev.op == 'const' and ev.T.kind == 'cstr') then
        fail('trap(message): message must be text known while compiling', 2)
    end
    local b = cur()
    b.fn.uses_rt = true
    b:emit { op = 'trap', msg = ev, what = 'a trap' }
end

-- Ptr T viewed as Ptr (Atomic T): the same address, accessed atomically from here
function S.atomic_ptr(p)
    local pv = is_place(p) and cur():read(p) or p
    if not (is_value(pv) and pv.T.kind == 'ptr') then fail('atomic_ptr(p) takes a pointer', 2) end
    local ok, at = pcall(types.atomic, pv.T.elem)
    if not ok then fail((tostring(at):gsub('^[^:]+:%d+: ', '')), 2) end
    return dyn(types.ptr(at), ex(pv))
end


-- tasks, channels and waits (§36) ---------------------------------------------------------------
-- Go's model: tasks share no memory; what reaches a task is a copy, and what
-- crosses a channel is a copy. A task compiles to a resumable C function; each
-- wait is an operation: in a task it suspends, in plain code it blocks. A tasks
-- scope owns its tasks and channels and ends when all its tasks have.

-- a function compiled on its own reaches no other function's locals or parameters
function S.check_isolated(fn)
    local G = require 'slc.cgen'
    local function bad(name)
        if fn.task then
            fail(("a task shares no memory: '%s' belongs to the code that spawns it, and a task gets only "
                .. "copies of values; send values, or pass them to spawn"):format(name), 3)
        end
        fail(("'%s' belongs to another function; a word compiled as its own C function cannot reach "
            .. "it (pass it as an argument)"):format(name), 3)
    end
    G.walk_block(fn.body, nil, function(e)
        if e.op == 'param' and rawget(e, 'fn') and e.fn ~= fn then bad(e.name) end
        if e.op ~= 'call' and e.place then
            local r = root_of(e.place)
            local o = rawget(r, 'owner')
            if o and o ~= fn then bad(r.name) end
        end
    end)
end

-- the user's line, for naming a wait in a deadlock report
function S.site(what)
    for level = 2, 80 do
        local info = debug.getinfo(level, 'Sl')
        if not info then break end
        if info.source == S.user_source and info.currentline and info.currentline > 0 then
            return (S.user_path or '?'):match('[^/]*$') .. ':' .. info.currentline .. ': ' .. what
        end
    end
    return what
end

local function hinted(b, t, hint)
    local p = b:new_temp(t)
    rawset(p, 'hint', hint)
    return p
end

-- A runtime call: the header's declaration and its arguments. `args` may hold
-- the `task` node and `sizeof` expressions; no backend parses call text.
local function rt_value(t, cname, args, what, place, hint)
    local b = cur()
    if b.fn then
        b.fn.uses_rt = true
        for _, a in ipairs(args) do
            if type(a) == 'table' and a.op == 'task' then b.fn.needs_self = true end
        end
    end
    local e = { op = 'rtcall', cname = cname, args = args, T = t, place = place }
    if t.kind == 'unit' then
        b:emit { op = 'expr', e = e, what = what }
        return nil
    end
    local tmp = hinted(b, t, hint)
    b:emit { op = 'let', place = tmp, e = e, what = what }
    return dyn(t, read_expr(tmp))
end

-- The command line a program's main sees (§3.7): count and NUL-terminated
-- argument strings. `args.length` counts them; `args[i]` is a Str view of one.
local args_type
function S.args_type()
    -- the header is requested for every compilation, not just the first: the
    -- probe is built per module and must see the record
    needs_header('slc_args', '"slc_rt.h"')
    if args_type then return args_type end
    local t = S.cstruct('slc_args', '"slc_rt.h"',
        { { 'count', types.U32 }, { 'argv', types.ptr(types.CString) } })
    local strlen = S.extern('strlen', { types.CString }, types.U32, { header = '<string.h>' })
    t.properties = t.properties or {}
    t.properties.length = function(x) return S.dot(x, 'count') end
    S.member_tables(t)
    t.__index = function(x, key)
        local i = index_value(key)
        if i.T ~= types.U32 then i = types.U32(i) end
        local argv = S.dot(x, 'argv')
        local element = new_place { pk = 'index', T = types.CString, base = ex(argv), idx = ex(i),
                                     name = 'element', id = uid() }
        local cstr = cur():read(element)
        local len = strlen(cstr)
        local ptr = dyn(types.ptr(types.U8), { op = 'conv', a = ex(cstr), T = types.ptr(types.U8) })
        return S.make_slice(types.Str, ptr, len)
    end
    args_type = t
    return t
end

-- A runtime wait names a C function and its arguments. The waiting party and
-- its operation records are IR nodes (`task`, `ops`); the callee is the runtime
-- header's own declaration, so no backend parses a call template.
local TASK, OPS = { op = 'task' }, { op = 'ops' }
local function rt_call(name) return { cname = name } end
local RT = {
    Recv = rt_call('slc_recv'), Send = rt_call('slc_send'), Sleep = rt_call('slc_sleep'),
    Take = rt_call('slc_take'), ScopeEnd = rt_call('slc_scope_end'),
    Read = rt_call('slc_io_read'), Write = rt_call('slc_io_write'),
    Open = rt_call('slc_io_open'), Close = rt_call('slc_io_close'),
    Accept = rt_call('slc_io_accept'), Connect = rt_call('slc_io_connect'), Arm = rt_call('slc_select_arm'),
    Blocking = rt_call('slc_blocking'),
}

-- a wait: the callee, its arguments (task and ops included), and how many
-- operation records it uses; the result is the runtime's I32. `extra` adds
-- statement fields, such as a blocking block's body.
local function wait_op(callee, args, nops, what, extra)
    local b = cur()
    if not b.fn then fail(('cannot evaluate at compile time: it performs %s'):format(what), 3) end
    if b.in_blocking then
        fail(('a blocking block runs outside the scheduler: it cannot wait (%s); wait after it'):format(what), 3)
    end
    b.fn.uses_rt = true
    b.fn.waits = math.max(b.fn.waits or 0, nops)
    args[#args + 1] = { op = 'const', T = types.CString, v = S.site(what) }
    local res = hinted(b, types.I32, 'r')
    local stmt = { op = 'wait', callee = callee, args = args, nops = nops, result = res, what = what }
    for k, v in pairs(extra or {}) do stmt[k] = v end
    b:emit(stmt)
    return dyn(types.I32, read_expr(res))
end

local function addr_of(p) return { op = 'addr', place = p, T = types.ptr(p.T) } end

local function chan_value(x, what)
    if is_place(x) then x = cur():read(x) end
    if not (is_value(x) and x.T.kind == 'chan') then
        fail(('%s expects a channel, got %s'):format(what, describe(x)), 4)
    end
    return x
end

-- the sum a receive produces
local received = setmetatable({}, { __mode = 'k' })
local function received_type(et)
    if not received[et] then
        received[et] = types.sum('Received' .. (et.name or ''), { { 'closed', types.Unit }, { 'value', et } })
    end
    return received[et]
end
S.received_type = received_type

local function call_handler(h, what, ...)
    local mt = getmetatable(h)
    if type(h) ~= 'function' and not (mt and mt.__call) then fail(what .. ' is not callable', 5) end
    return h(...)
end

h.check_handlers = function(R, handlers)
    if type(handlers) ~= 'table' or getmetatable(handlers) then
        fail('a receive is matched with handlers: ch:recv() { value = do(v) ... end, closed = do ... end }', 4)
    end
    for k in pairs(handlers) do
        if k ~= 'value' and k ~= 'closed' then
            fail(("%s has no alternative '%s' to handle"):format(R.display, tostring(k)), 4)
        end
    end
    for _, k in ipairs { 'closed', 'value' } do
        if handlers[k] == nil then fail(("matching a %s: alternative '%s' has no handler"):format(R.display, k), 4) end
    end
end

-- receive into a fresh slot: the value's place and the wait's result (1 value, 0 closed)
local function receive(ch)
    local b = cur()
    local buf = hinted(b, ch.T.elem, 'got')
    local r = wait_op(RT.Recv, { TASK, OPS, ex(ch), addr_of(buf) }, 1, 'recv')
    return buf, S.eq(r, known(types.I32, 1))
end

-- the slot leaves of a type, as field paths
local function slot_paths(t, prefix, out)
    out = out or {}
    prefix = prefix or {}
    if t.kind == 'slot' then out[#out + 1] = prefix
    elseif t.kind == 'struct' then
        for _, f in ipairs(t.fields) do
            local p2 = { unpack(prefix) }
            p2[#p2 + 1] = f.name
            slot_paths(f.type, p2, out)
        end
    end
    return out
end

local function path_expr(place, path)
    local q = place
    for _, name in ipairs(path) do q = field_place(q, name) end
    return read_expr(q)
end

-- ownership of every slot in the value at `place`: given before a send, adopted after a receive
local function slot_moves(place, fn_name)
    local paths = slot_paths(place.T)
    if #paths == 0 then return end
    for _, path in ipairs(paths) do
        rt_value(types.Unit, fn_name, { TASK, path_expr(place, path) }, 'moving a slot')
    end
    cur():bump_checked()
end
S.slot_moves = slot_moves

-- a slot value that was sent or released: the plain mistake, caught here
-- (a mark made in one branch arm says nothing about another, or after the join)
local function check_gone(v)
    local g = is_value(v) and rawget(v, 'gone')
    if not g then return end
    local here = cur().path or ''
    if here:sub(1, #g.path) == g.path then
        fail(('this slot was %s; it no longer belongs to this task'):format(g.what), 4)
    end
end
S.check_gone = check_gone

local function mark_gone(v, what)
    if not is_value(v) then return end
    if type(what) == 'string' then what = { what = what, path = cur().path or '' } end
    if v.T.kind == 'slot' then rawset(v, 'gone', what) return end
    if v.k == 'agg' then for _, f in pairs(v.f) do mark_gone(f, what) end end
end

local function each_slot_value(v, f)
    if not is_value(v) then return end
    if v.T.kind == 'slot' then f(v) return end
    if v.k == 'agg' then for _, x in pairs(v.f) do each_slot_value(x, f) end end
end

local function send_value(ch, v, tentative)
    local b = cur()
    local et = ch.T.elem
    if is_place(v) then v = b:read(v) end
    local cv = coerce(v, et, 'the value sent on a ' .. ch.T.display)
    each_slot_value(cv, check_gone)
    local msg = hinted(b, et, 'msg')
    b:emit { op = 'let', place = msg, e = ex(cv) }
    slot_moves(msg, 'slc_slot_give')
    if not tentative then mark_gone(cv, 'sent at ' .. S.site('send')) end
    return msg
end

function S.chan_method(x, key)
    local ch = chan_value(x, 'a channel operation')
    local et = ch.T.elem
    local methods = {}
    -- send a copy; waits while the channel is full (unbuffered: until taken)
    methods.send = function(self, v)
        local msg = send_value(ch, v)
        wait_op(RT.Send, { TASK, OPS, ex(ch), addr_of(msg) }, 1, 'send')
    end
    -- receive: a Received T, or matched straight away with its handlers
    methods.recv = function(self, handlers)
        local b = cur()
        local R = received_type(et)
        if handlers ~= nil then h.check_handlers(R, handlers) end
        local buf, ok = receive(ch)
        local function read_owned()
            slot_moves(buf, 'slc_slot_adopt')
            return dyn(et, read_expr(buf))
        end
        local result = require('slc.completion').receive(R, read_owned)(ok)
        if handlers then return match(result, handlers) end
        return result
    end
    S.arity[methods.recv] = 2
    methods.close = function(self)
        rt_value(types.Unit, 'slc_chan_close', { ex(ch) }, 'closing a channel')
    end
    -- Iteration is library control flow, not a compiler-built loop. recv owns
    -- the primitive wait and slot-adoption rules on both backends.
    methods.each = function(self, body)
        return require('slc.channel').each(et, body)(ch)
    end
    local m = methods[key]
    if not m then
        fail(("%s offers send, recv, close, each; not '%s'"):format(ch.T.display, tostring(key)), 3)
    end
    return m
end

-- durations ---------------------------------------------------------------------------------------

S.ns = function(x) return require('slc.duration').ns(types.Duration(x)) end
S.us = function(x) return require('slc.duration').us(types.Duration(x)) end
S.ms = function(x) return require('slc.duration').ms(types.Duration(x)) end
S.seconds = function(x) return require('slc.duration').seconds(types.Duration(x)) end

function S.sleep(d)
    d = coerce(d, types.Duration, 'sleep(d)')
    wait_op(RT.Sleep, { TASK, OPS, ex(d) }, 1, 'sleep')
end

-- first_of ----------------------------------------------------------------------------------------

local Case = { __name = 'first_of case' }

function S.recv_case(ch, handler)
    ch = chan_value(ch, 'recv(ch) do(v) ... end')
    if handler == nil then fail('recv(ch) do(v) ... end: the handler is missing', 2) end
    return setmetatable({ kind = 'recv', ch = ch, handler = handler }, Case)
end
S.arity[S.recv_case] = 2

function S.send_case(ch, v, handler)
    ch = chan_value(ch, 'send(ch, v) do ... end')
    if handler == nil then fail('send(ch, v) do ... end: the handler is missing', 2) end
    return setmetatable({ kind = 'send', ch = ch, v = v, handler = handler }, Case)
end
S.arity[S.send_case] = 3

function S.take_case(p, handler)
    if is_place(p) then p = cur():read(p) end
    if not (is_value(p) and p.T.kind == 'pool') then fail('take(pool) do(slot) ... end expects a pool, got ' .. describe(p), 2) end
    if handler == nil then fail('take(pool) do(slot) ... end: the handler is missing', 2) end
    return setmetatable({ kind = 'take', pool = p, handler = handler }, Case)
end
S.arity[S.take_case] = 2

function S.after_case(d, handler)
    if handler == nil then fail('after(d) do ... end: the handler is missing', 2) end
    return setmetatable({ kind = 'after', d = coerce(d, types.Duration, 'after(d)'), handler = handler }, Case)
end
S.arity[S.after_case] = 2

-- first_of { recv(a) do(v) ... end, send(b, x) do ... end, after(d) do ... end,
--            closed = do ... end, default = do ... end }
function S.first_of(cases)
    local b = cur()
    if type(cases) ~= 'table' or getmetatable(cases) then
        fail('first_of takes a table of cases: first_of { recv(ch) do(v) ... end, ... }', 2)
    end
    for k, v in pairs(cases) do
        if type(k) == 'number' then
            if getmetatable(v) ~= Case then
                fail('first_of: every listed case is recv(ch) do(v) ... end, send(ch, v) do ... end, '
                    .. 'take(pool) do(slot) ... end or after(d) do ... end', 2)
            end
        elseif k ~= 'default' and k ~= 'closed' then
            fail(("first_of: unknown key '%s' (cases, closed =, default =)"):format(tostring(k)), 2)
        end
    end
    local list = {}
    for i = 1, #cases do list[i] = cases[i] end
    if #list == 0 then fail('first_of needs at least one case', 2) end
    local nrecv = 0
    for _, c in ipairs(list) do if c.kind == 'recv' then nrecv = nrecv + 1 end end
    if nrecv > 0 and cases.default == nil and cases.closed == nil then
        fail('first_of: when every channel is closed it runs `closed = do ... end`; give it one (or a default)', 2)
    end
    if nrecv == 0 and cases.closed ~= nil then
        fail('first_of: `closed` runs when every received channel is closed, but no case receives', 2)
    end
    -- The program fills the operation records itself and sequences the attempts
    -- (lib/select.slc); nothing is built to be interpreted.
    local sel = require 'slc.select'
    local HandleT = sel.Handle
    local bufs, kinds = {}, {}
    local ops_v = dyn(types.ptr(sel.Op), OPS)
    local task_v = dyn(types.ptr(sel.Task), TASK)
    local U8P = types.ptr(types.U8)
    local function field(v, name, T) return { op = 'field', a = v, name = name, T = T } end
    local function bytes_at(p) return dyn(U8P, { op = 'conv', a = addr_of(p), T = U8P }) end
    local function i32(v) return known(types.I32, v) end
    local has_after = false
    for _, c in ipairs(list) do if c.kind == 'after' then has_after = true end end
    local time = has_after and sel.now() or known(types.U64, 0)
    S.set(member(task_v, 'ops'), ops_v)
    S.set(member(task_v, 'nops'), i32(#list))
    S.set(member(task_v, 'site'), known(types.CString, S.site('first_of')))
    for i, c in ipairs(list) do
        local chan = dyn(HandleT, { op = 'agg', T = HandleT, fields = {
            idx = ex(known(types.U32, 0)), gen = ex(known(types.U32, 0)) } })
        local buf = dyn(U8P, { op = 'null', T = U8P })
        local deadline = known(types.U64, 0)
        kinds[i] = c.kind
        local code
        if c.kind == 'recv' then
            bufs[i] = hinted(b, c.ch.T.elem, 'got')
            code, chan, buf = 1, dyn(HandleT, ex(c.ch)), bytes_at(bufs[i])
        elseif c.kind == 'send' then
            c.msg = send_value(c.ch, c.v, true)
            code, chan, buf = 2, dyn(HandleT, ex(c.ch)), bytes_at(c.msg)
        elseif c.kind == 'take' then
            bufs[i] = hinted(b, types.slot(c.pool.T.elem), 'slot')
            -- a pool and a channel name the same pair: { idx, gen }
            local pool = ex(c.pool)
            code, buf = 4, bytes_at(bufs[i])
            chan = dyn(HandleT, { op = 'agg', T = HandleT, fields = {
                idx = field(pool, 'idx', types.U32), gen = field(pool, 'gen', types.U32) } })
        else
            code = 3
            deadline = dyn(types.U64, { op = 'bin', o = 'add', a = ex(time), b = ex(c.d), T = types.U64 })
        end
        -- one function fills every record: its kind and index are arguments, not keys
        S.boundary(sel.fill)(task_v, S.Ptr(ops_v[i - 1]), S.dynamic(i32(code)), chan, buf,
            S.dynamic(i32(i - 1)), S.dynamic(deadline))
    end
    local pick = S.boundary(sel.scan(kinds, cases.default ~= nil))(task_v, ops_v, time)
    -- nothing ready and no default: wait on every record. Otherwise the answer is
    -- already known and no record stays pending.
    local result = b:new_local(types.I32, 'r')
    S.if_(S.eq(pick, i32(-100)), function()
        S.set(result, wait_op(RT.Arm, { TASK, OPS, ex(i32(#list)) }, #list, 'first_of'))
    end, function()
        S.set(member(task_v, 'result'), pick)
        S.set(member(task_v, 'nops'), i32(0))
        S.set(result, pick)
    end)
    local k = dyn(types.I32, read_expr(result))
    local arms = {}
    -- a send case that loses keeps its slots: they come back in every other arm
    local function take_back(except)
        for j, c in ipairs(list) do
            if c.kind == 'send' and j ~= except then slot_moves(c.msg, 'slc_slot_adopt') end
        end
    end
    for i, c in ipairs(list) do
        arms[#arms + 1] = { at = i - 1, run = function()
            take_back(i)
            if c.kind == 'recv' then
                slot_moves(bufs[i], 'slc_slot_adopt')
                return call_handler(c.handler, 'the handler of case ' .. i, dyn(c.ch.T.elem, read_expr(bufs[i])))
            end
            if c.kind == 'take' then
                return call_handler(c.handler, 'the handler of case ' .. i, dyn(bufs[i].T, read_expr(bufs[i])))
            end
            return call_handler(c.handler, 'the handler of case ' .. i)
        end }
    end
    if cases.default ~= nil then
        arms[#arms + 1] = { at = -1, run = function() take_back(nil); return call_handler(cases.default, 'the default of first_of') end }
    end
    if cases.closed ~= nil then
        arms[#arms + 1] = { at = -2, run = function() take_back(nil); return call_handler(cases.closed, 'the closed of first_of') end }
    end
    local desc = { kind = 'word', name = 'first_of', infer = true, body = function()
        local function arm(i)
            local a = arms[i]
            local function run() S.ret(a.run()) end
            if i == #arms then return run() end
            S.if_(S.eq(k, known(types.I32, a.at)), run, function() arm(i + 1) end)
        end
        arm(1)
    end }
    return b:run_frame(desc, {}, {})
end

-- pools ------------------------------------------------------------------------------------------------

local function slot_value(p, s, what)
    if is_place(s) then s = cur():read(s) end
    local st = types.slot(p.T.elem)
    if not (is_value(s) and s.T == st) then
        fail(('%s expects a %s, got %s'):format(what, st.display, describe(s)), 4)
    end
    check_gone(s)
    return s
end

function S.pool_method(x, key)
    local p = is_place(x) and cur():read(x) or x
    local et = p.T.elem
    local st = types.slot(et)
    local methods = {}
    -- wait for a free slot, owned by this task from now on
    methods.take = function(self)
        local b = cur()
        local buf = hinted(b, st, 'slot')
        wait_op(RT.Take, { TASK, OPS, ex(p), addr_of(buf) }, 1, 'take')
        return dyn(st, read_expr(buf))
    end
    methods.release = function(self, s)
        local sv = slot_value(p, s, 'pool:release(slot)')
        rt_value(types.Unit, 'slc_slot_release', { TASK, ex(sv) }, 'releasing a slot')
        cur():bump_checked()
        mark_gone(sv, 'released at ' .. S.site('release'))
    end
    local m = methods[key]
    if not m then fail(("%s offers take, release and pool[slot]; not '%s'"):format(p.T.display, tostring(key)), 3) end
    return m
end

-- pool[slot]: the slot's contents, a place whose address is computed (and the
-- slot's ownership checked) at every use
function S.pool_index(x, s)
    local p = is_place(x) and cur():read(x) or x
    local et = p.T.elem
    local sv = slot_value(p, s, 'pool[slot]')
    local b = cur()
    if b.fn then b.fn.uses_rt, b.fn.needs_self = true, true end
    local ptr = { op = 'slot_at', slot = ex(sv), T = types.ptr(et) }
    return S.checked_place(et, ptr, 'slot')
end

-- spawning ----------------------------------------------------------------------------------------

local function sendable(t, name, what)
    if t.kind == 'group' then return end         -- a task carries its scope's handle
    local why = types.unsendable(t)
    if why then
        fail(("a task shares no memory: %s '%s' is a %s, and %s; send values, or pass them to spawn"):format(
            what, name, t.display, why), 5)
    end
end

local function new_capture(fn, name, T, value)
    local cap = fn.capture
    local pname = unique(fn.param_names, name)
    fn.params[#fn.params + 1] = { name = pname, T = T }
    cap.values[#cap.values + 1] = value
    return dyn(T, { op = 'param', name = pname, T = T, fn = fn })
end

-- a spawned block reads a runtime name from outside: a copy taken at spawn
function S.capture_read(b, p)
    local fn = b.fn
    local cap = fn.capture
    local r = root_of(p)
    local v = cap.places[r]
    if v == nil then
        local pv = cap.parent:read(r)
        if static(pv) then
            v = pv                                 -- a fact: baked into the task
        else
            sendable(r.T, r.name, 'the outside name')
            v = new_capture(fn, r.name, r.T, pv)
        end
        cap.places[r] = v
    end
    local path, q = {}, p
    while q ~= r do
        if rawget(q, 'array_owner') then
            local idx = rawget(q, 'idx')
            path[#path + 1] = idx.op == 'const' and known(idx.T, idx.v) or dyn(idx.T, idx)
        else
            path[#path + 1] = rawget(q, 'fname')
        end
        q = rawget(q, 'parent')
    end
    for i = #path, 1, -1 do v = member(v, path[i]) end
    return v
end

-- Views of captured arrays address the task's by-value parameter, never the
-- parent's local. Even a baked-in value needs owned storage once it is viewed.
function S.capture_place(b, p)
    local fn, root = b.fn, root_of(p)
    local cap = fn.capture
    local value = cap.places[root]
    if not (value and value.k == 'dyn' and value.e.op == 'param' and value.e.fn == fn) then
        local copied = value or cap.parent:read(root)
        sendable(root.T, root.name, 'the outside name')
        value = new_capture(fn, root.name, root.T, copied)
        cap.places[root] = value
    end
    cap.owned_roots = cap.owned_roots or {}
    local owned = cap.owned_roots[root]
    if not owned then
        owned = new_place { pk = 'param', T = root.T, name = value.e.name, owner = fn, id = uid() }
        cap.owned_roots[root] = owned
    end
    local function rebase(q)
        if q == root then return owned end
        if rawget(q, 'array_owner') then
            local idx = rawget(q, 'idx')
            local key = idx.op == 'const' and known(idx.T, idx.v) or dyn(idx.T, idx)
            return S.array_member(rebase(q.array_owner), key, true)
        end
        if q.pk == 'field' then return field_place(rebase(q.parent), q.fname) end
        fail('a captured array view requires a field or indexed place', 3)
    end
    return rebase(p)
end

-- expressions from outside held in Lua values (a call's result, a parameter)
-- become copies too
function S.capture_leaves(fn)
    local G = require 'slc.cgen'
    local cap = fn.capture
    local parent_fn = cap.parent.fn
    local function value_in_parent(e)
        local owner = e.op == 'param' and rawget(e, 'fn') or rawget(root_of(e.place), 'owner')
        if owner == parent_fn then
            local c = copy_expr(e)
            c.fn = e.fn
            return dyn(e.T, c)
        end
        if parent_fn and parent_fn.capture then
            return S.capture_leaf(parent_fn, e)
        end
        return nil
    end
    G.walk_block(fn.body, nil, function(e)
        local foreign = (e.op == 'param' and rawget(e, 'fn') and e.fn ~= fn)
            or (e.op == 'read' and rawget(root_of(e.place), 'owner') and rawget(root_of(e.place), 'owner') ~= fn)
        if not foreign then return end
        local repl = S.capture_leaf(fn, e, value_in_parent)
        if repl then
            for k in pairs(e) do e[k] = nil end
            for k, v in pairs(ex(repl)) do e[k] = v end
        end
    end)
end

function S.capture_leaf(fn, e, value_in_parent)
    local cap = fn.capture
    local key = e.op == 'param' and ('p:' .. tostring(e.fn) .. ':' .. e.name) or e.place
    local v = cap.leaves[key]
    if v ~= nil then return v end
    local pv
    if value_in_parent then
        pv = value_in_parent(e)
    else
        -- asked by a nested task: produce the value in this (capturing) task
        local inner = e
        local owner = inner.op == 'param' and rawget(inner, 'fn') or rawget(root_of(inner.place), 'owner')
        if owner == cap.parent.fn then
            local c = copy_expr(inner); c.fn = inner.fn
            pv = dyn(inner.T, c)
        elseif cap.parent.fn and cap.parent.fn.capture then
            pv = S.capture_leaf(cap.parent.fn, inner)
        end
    end
    if pv == nil then return nil end
    local name = cap.names[key]
        or (e.op == 'param' and e.name or (rawget(root_of(e.place), 'hint') or root_of(e.place).name))
    sendable(e.T, name, 'the outside value')
    v = new_capture(fn, name, e.T, pv)
    cap.leaves[key] = v
    return v
end

-- a wait inside a function compiled on its own cannot suspend a task
function S.check_task_waits(fn)
    local G = require 'slc.cgen'
    local seen = {}
    local function visit(f)
        if seen[f] then return end
        seen[f] = true
        G.walk_block(f.body, nil, function(e)
            if e.op == 'call' and e.fn and not e.fn.task then
                if e.fn.waits then
                    fail(("a wait inside %s, which is compiled as its own C function (a recursion "
                        .. "re-entered in non-tail position); a task cannot suspend inside it: loop by tail "
                        .. "call, or keep an explicit stack"):format(e.fn.word and e.fn.word.name or e.fn.cname), 4)
                end
                visit(e.fn)
            end
        end)
    end
    visit(fn)
end

-- blocking do ... end: in a task, the block runs on a blocking thread while the
-- task waits (so a call into C that blocks does not hold a worker); the task's
-- locals are its frame, and the task is not running, so the block uses them
-- as they are. In plain code the thread may block anyway: the block runs here.
function S.blocking(body)
    local b = cur()
    local mt = getmetatable(body)
    if type(body) ~= 'function' and not (mt and mt.__call) then
        fail('blocking takes a body: blocking do ... end', 2)
    end
    if not (b.fn and b.fn.task) then return body() end
    if b.in_blocking then return body() end
    local block, outer = {}, b.block
    b.block, b.in_blocking = block, true
    b:bump_checked()
    local ok, r = pcall(body)
    b.block, b.in_blocking = outer, nil
    b:bump_checked()
    if not ok then error(r, 0) end
    -- the callee's blocked function and its frame are IR nodes: the backends
    -- name the function they emit and pass the frame as its argument
    wait_op(RT.Blocking, { TASK, OPS, { op = 'block_fn' }, { op = 'block_env' } }, 1,
        'a blocking block', { body = block })
    return r
end

-- does t contain a channel?
local function holds_chan(t)
    if t.kind == 'chan' then return true end
    if t.kind == 'struct' then
        for _, f in ipairs(t.fields) do if holds_chan(f.type) then return true end end
    elseif t.kind == 'sum' then
        for _, a in ipairs(t.alts) do if holds_chan(a.type) then return true end end
    end
    return false
end

local task_ids = 0

-- start a task running `block`: compiled as its own resumable function, with
-- copies of every runtime name it mentions from outside
local function spawn_block(scope, block, name, names)
    local b = cur()
    if not b.fn then fail('spawn needs a native context', 4) end
    task_ids = task_ids + 1
    local w = S.word { name = name, params = {}, result = types.Unit, loc = S.site('spawn'),
                       body = function() block() end }
    local cap = { parent = b, scope = scope, places = {}, leaves = {}, values = {}, names = names or {} }
    local fn = build_function(w, {}, 'task#' .. task_ids, nil, { task = true, capture = cap })
    local args = { ex(scope.group) }
    for _, v in ipairs(cap.values) do args[#args + 1] = ex(v) end
    b.fn.uses_rt = true
    b:emit { op = 'spawn', args = args, task = fn, what = 'starting a task' }
end

local function spawn(scope, f, ...)
    if scope.ended then fail('spawn: its tasks scope has ended', 3) end
    if not is_word(f) then
        local mt = getmetatable(f)
        if type(f) == 'function' or (mt and mt.__call and not is_staged(f)) then
            if select('#', ...) > 0 then fail('spawn do ... end takes no arguments; spawn(f, args...) does', 3) end
            return spawn_block(scope, f, 'task')
        end
        fail(('spawn: expects a block (spawn do ... end) or a typed word (spawn(f, args...)), got %s'):format(
            describe(f)), 3)
    end
    if f.rest then fail(('spawn: %s takes ...%s; a task takes a fixed list of values'):format(f.name, f.rest), 3) end
    if f.ret.kind ~= 'unit' then
        fail(('spawn: %s returns a %s, but a task\'s result goes nowhere; send it on a channel'):format(
            f.name, f.ret.display), 3)
    end
    local n = select('#', ...)
    local new = { ... }
    local all = {}
    for i = 1, #f.supplied do all[i] = f.supplied[i] end
    if #f.supplied + n ~= #f.params then
        fail(('spawn: %s takes %d arguments, got %d'):format(f.name, #f.params - #f.supplied, n), 3)
    end
    for i = 1, n do
        local idx = #f.supplied + i
        local p = f.params[idx]
        if p.static then
            all[idx] = static_arg(new[i], p, f)
        else
            local why = types.unsendable(p.T)
            if why then
                fail(("spawn: parameter '%s' of %s is a %s; a task shares no memory, and %s (pass values, "
                    .. "or send them on a channel)"):format(p.name, f.name, p.T.display, why), 3)
            end
            all[idx] = coerce(new[i], p.T, ("argument '%s' of %s"):format(p.name, f.name))
        end
    end
    -- spawn(f, a, b) is spawn do f(a, b) end, with a and b evaluated here
    local base = setmetatable({}, W)
    for k, v in pairs(f) do rawset(base, k, v) end
    base.supplied = {}
    -- the copies are named after the word's parameters
    local names = {}
    for i, a in ipairs(all) do
        if is_value(a) and a.k == 'dyn' then
            local e = a.e
            if e.op == 'read' then names[e.place] = f.params[i].name
            elseif e.op == 'param' then names['p:' .. tostring(e.fn) .. ':' .. e.name] = f.params[i].name end
        end
    end
    return spawn_block(scope, function() base(unpack(all, 1, #f.params)) end, f.name, names)
end

-- tasks do(scope...) ... end
function S.tasks(body)
    local b = cur()
    local mt = getmetatable(body)
    if type(body) ~= 'function' and not (mt and mt.__call) then
        fail('tasks takes a body: tasks do(scope...) ... end', 2)
    end
    local group = rt_value(types.Group, 'slc_scope_new', { TASK }, 'opening a tasks scope', nil, 'scope')
    local scope = { group = group }
    local vocab = {}
    vocab.spawn = function(f, ...)
        if f == vocab then return spawn(scope, ...) end
        return spawn(scope, f, ...)
    end
    vocab.channel = function(t, n, ...)
        if t == vocab then t, n = n, ... end
        if scope.ended then fail('channel: its tasks scope has ended', 2) end
        if not is_type(t) then fail('channel(T, n): T must be a type, got ' .. describe(t), 2) end
        local ok, ct = pcall(types.chan, t)
        if not ok then fail((tostring(ct):gsub('^[^:]+:%d+: ', '')), 2) end
        local cap = coerce(n == nil and 0 or n, types.U32, 'channel capacity')
        return rt_value(ct, 'slc_chan_new', { ex(group), ex(S.size_of(t)), ex(cap) }, 'making a channel',
            nil, 'ch')
    end
    vocab.pool = function(t, n, ...)
        if t == vocab then t, n = n, ... end
        if scope.ended then fail('pool: its tasks scope has ended', 2) end
        if not is_type(t) then fail('pool(T, n): T must be a type, got ' .. describe(t), 2) end
        local ok, pt = pcall(types.pool, t)
        if not ok then fail((tostring(pt):gsub('^[^:]+:%d+: ', '')), 2) end
        local cap = coerce(n, types.U32, 'pool size')
        return rt_value(pt, 'slc_pool_new', { ex(group), ex(S.size_of(t)), ex(cap) }, 'making a pool',
            nil, 'pool')
    end
    local ok, r = pcall(body, vocab)
    scope.ended = true
    if not ok then error(r, 0) end
    wait_op(RT.ScopeEnd, { TASK, OPS, ex(group) }, 1, 'the end of a tasks scope')
    if is_value(r) and holds_chan(r.T) then
        fail('a channel cannot leave its tasks scope: it retires when the scope ends', 2)
    end
    return r
end

-- I/O by completion (§36.7) ---------------------------------------------------------------------------
-- Every operation is a wait (a task suspends, plain code blocks) whose result
-- is a sum: done, failed (the system's error code), and timed_out when the
-- operation has a deadline. I/O is never a case of first_of: the kernel's
-- work cannot be taken back.

local io_types
local function io_t()
    if io_types then return io_types end
    local File = types.struct('File', { { 'fd', types.I32 } })
    local Pipe = types.struct('Pipe', { { 'reader', File }, { 'writer', File } })
    local function result(name, done, timed)
        local alts = { { 'done', done }, { 'failed', types.I32 } }
        if timed then alts[#alts + 1] = { 'timed_out', types.Unit } end
        return types.sum(name, alts)
    end
    io_types = {
        File = File, Pipe = Pipe,
        count = result('IoCount', types.U32), count_t = result('IoCountOrTimeout', types.U32, true),
        file = result('IoFile', File), file_t = result('IoFileOrTimeout', File, true),
        unit = result('IoDone', types.Unit), pipe = result('IoPipe', Pipe),
    }
    return io_types
end

local IO_KEYS = { at = true, deadline = true }
local HANDLER_KEYS = { done = true, failed = true, timed_out = true }

-- split an operation's arguments: positional, options, handlers
local function io_args(name, ...)
    local pos, opts, handlers = {}, {}, nil
    local n = select('#', ...)
    for i = 1, n do
        local a = select(i, ...)
        local mt = getmetatable(a)
        if type(a) == 'function' or (mt and mt.__call and not is_staged(a) and not is_word(a)) then
            fail(('I/O cannot lose a first_of: give io.%s a deadline ({ deadline = d }), or spawn a task that '
                .. 'does it and receive its result'):format(name), 4)
        elseif type(a) == 'table' and not is_staged(a) and mt == nil and i > 1 then
            local k = next(a)
            if k ~= nil and HANDLER_KEYS[k] then
                handlers = a
            else
                for key in pairs(a) do
                    if not IO_KEYS[key] then
                        fail(("io.%s: unknown option '%s' (at = offset, deadline = d)"):format(name, tostring(key)), 4)
                    end
                end
                opts = a
            end
        else
            pos[#pos + 1] = a
        end
    end
    return pos, opts, handlers
end

-- wait for an operation, then its result as a sum (or straight into handlers)
local function io_wait(name, callee, args, sum, done_of, handlers)
    local b = cur()
    local val = hinted(b, types.I64, 'io')
    local all = { TASK, OPS }
    for i, a in ipairs(args) do all[#all + 1] = a end
    all[#all + 1] = addr_of(val)
    local st = wait_op(callee, all, 1, name)
    if handlers then
        for k in pairs(handlers) do
            if not sum.index[k] then fail(("%s has no alternative '%s' to handle"):format(sum.display, tostring(k)), 4) end
        end
        for _, a in ipairs(sum.alts) do
            if handlers[a.name] == nil then
                fail(("matching a %s: alternative '%s' has no handler"):format(sum.display, a.name), 4)
            end
        end
    end
    local v = dyn(types.I64, read_expr(val))
    local result = require('slc.completion').io(sum, done_of)(st, v)
    if handlers then return match(result, handlers) end
    return result
end

local function file_of(f, what)
    local T = io_t()
    if is_place(f) then f = cur():read(f) end
    if not (is_value(f) and f.T == T.File) then fail(('%s expects a File, got %s'):format(what, describe(f)), 4) end
    return f
end

local function file_value(v)
    return agg(io_t().File, { fd = types.I32(v) })
end

-- a writable byte buffer: an Array(U8, N) itself (a local, a field, a borrowed slot)
local function byte_buffer(x, what)
    local t = is_staged(x) and struct_of(x)
    if not (t and t.kind == 'array' and t.elem == types.U8) then
        fail(('%s needs an Array(U8, N) to fill, got %s'):format(what, describe(x)), 4)
    end
    local base, place = array_storage(x)
    if not base then fail(('%s needs the array itself (a typed local, a field), not a copy'):format(what), 4) end
    if place.pk ~= 'deref' and place.pk ~= 'index' then cur():escape(root_of(place)) end
    local first = new_place { pk = 'index', T = types.U8, base = base, idx = ex(known(types.U32, 0)),
                              name = 'element', id = uid() }
    return { op = 'addr', place = first, T = types.ptr(types.U8) }, t.length
end

local function count_arg(n, cap, what)
    if n == nil then return known(types.U32, cap) end
    local nv = coerce(n, types.U32, what .. ' count')
    if nv.k == 'known' then
        if tonumber(nv.v) > cap then
            fail(('%s: %s bytes do not fit a buffer of %d'):format(what, fold.show(types.U32, nv.v), cap), 4)
        end
    else
        checks().high(types.U64(nv), types.U64(known(types.U32, cap)))
    end
    return nv
end

local function io_opts(opts, name)
    local at = opts.at ~= nil and coerce(opts.at, types.I64, 'io.' .. name .. ' at') or known(types.I64, -1)
    local dl = opts.deadline ~= nil and coerce(opts.deadline, types.Duration, 'io.' .. name .. ' deadline') or nil
    return at, dl
end

function S.io_vocabulary()
    local T = io_t()
    local io = { File = T.File, Pipe = T.Pipe }
    io.stdin = agg(T.File, { fd = known(types.I32, 0) })
    io.stdout = agg(T.File, { fd = known(types.I32, 1) })
    io.stderr = agg(T.File, { fd = known(types.I32, 2) })

    -- read(f, buf [, n] [, { at = offset, deadline = d }]): fills up to n bytes of an Array(U8, N)
    io.read = function(...)
        local pos, opts, handlers = io_args('read', ...)
        local f = file_of(pos[1], 'io.read')
        local ptr, cap = byte_buffer(pos[2], 'io.read')
        local n = count_arg(pos[3], cap, 'io.read')
        local at, dl = io_opts(opts, 'read')
        local sum = dl and T.count_t or T.count
        return io_wait('read', RT.Read,
            { ex(f.fd), ptr, ex(n), ex(at), ex(dl or known(types.Duration, 0)) }, sum,
            function(v) return types.U32(v) end, handlers)
    end
    S.arity[io.read] = 6

    -- write(f, data [, n] [, options]): data is an Array(U8, N), a Slice U8, or a string known while compiling
    io.write = function(...)
        local pos, opts, handlers = io_args('write', ...)
        local f = file_of(pos[1], 'io.write')
        local data, ptr, n = pos[2], nil, nil
        if type(data) == 'string' then
            ptr = ex(known(types.CString, data))
            n = pos[3] ~= nil and count_arg(pos[3], #data, 'io.write') or known(types.U32, #data)
        elseif is_staged(data) and rawget(struct_of(data), 'slice_elem') == types.U8 then
            local sv = is_place(data) and cur():read(data) or data
            local sp, sl = slice_parts(sv)
            ptr, n = ex(sp), pos[3] ~= nil and coerce(pos[3], types.U32, 'io.write count') or sl
        else
            local p, cap = byte_buffer(data, 'io.write')
            ptr, n = p, count_arg(pos[3], cap, 'io.write')
        end
        local at, dl = io_opts(opts, 'write')
        local sum = dl and T.count_t or T.count
        return io_wait('write', RT.Write,
            { ex(f.fd), ptr, ex(n), ex(at), ex(dl or known(types.Duration, 0)) }, sum,
            function(v) return types.U32(v) end, handlers)
    end
    S.arity[io.write] = 6

    -- open(path, flags [, mode]): a File
    io.open = function(...)
        local pos, _, handlers = io_args('open', ...)
        local path = pos[1]
        if type(path) == 'string' then path = known(types.CString, path) end
        path = coerce(path, types.CString, 'io.open path')
        local flags = coerce(pos[2] or 0, types.I32, 'io.open flags')
        local mode = coerce(pos[3] or 420, types.U32, 'io.open mode')
        return io_wait('open', RT.Open, { ex(path), ex(flags), ex(mode) },
            T.file, file_value, handlers)
    end
    S.arity[io.open] = 4

    io.close = function(...)
        local pos, _, handlers = io_args('close', ...)
        local f = file_of(pos[1], 'io.close')
        return io_wait('close', RT.Close, { ex(f.fd) }, T.unit, nil, handlers)
    end
    S.arity[io.close] = 2

    -- accept(listener [, options]): the next connection
    io.accept = function(...)
        local pos, opts, handlers = io_args('accept', ...)
        local l = file_of(pos[1], 'io.accept')
        local _, dl = io_opts(opts, 'accept')
        return io_wait('accept', RT.Accept,
            { ex(l.fd), ex(dl or known(types.Duration, 0)) }, dl and T.file_t or T.file, file_value, handlers)
    end
    S.arity[io.accept] = 3

    -- connect(host, port [, options]): an IPv4 TCP connection
    io.connect = function(...)
        local pos, opts, handlers = io_args('connect', ...)
        local host = coerce(pos[1], types.U32, 'io.connect host')
        local port = coerce(pos[2], types.U32, 'io.connect port')
        local _, dl = io_opts(opts, 'connect')
        return io_wait('connect', RT.Connect,
            { ex(host), ex(port), ex(dl or known(types.Duration, 0)) }, dl and T.file_t or T.file, file_value, handlers)
    end
    S.arity[io.connect] = 4

    -- setup that never waits: a pipe, a listening socket
    local function immediate(name, callee, args, sum, done_of, handlers)
        local b = cur()
        local val = hinted(b, types.I64, 'io')
        args[#args + 1] = addr_of(val)
        local st = rt_value(types.I32, callee, args, 'io.' .. name, nil, 'st')
        local v = dyn(types.I64, read_expr(val))
        local result = require('slc.completion').io(sum, done_of)(st, v)
        if handlers then return match(result, handlers) end
        return result
    end

    io.pipe = function(handlers)
        local b = cur()
        local r, w = hinted(b, types.I32, 'reader'), hinted(b, types.I32, 'writer')
        return immediate('pipe', 'slc_io_pipe', { addr_of(r), addr_of(w) }, T.pipe, function()
            return agg(T.Pipe, { reader = agg(T.File, { fd = dyn(types.I32, read_expr(r)) }),
                                 writer = agg(T.File, { fd = dyn(types.I32, read_expr(w)) }) })
        end, handlers)
    end
    S.arity[io.pipe] = 1

    io.listen = function(...)
        local pos, _, handlers = io_args('listen', ...)
        local host = coerce(pos[1], types.U32, 'io.listen host')
        local port = coerce(pos[2], types.U32, 'io.listen port')
        return immediate('listen', 'slc_io_listen', { ex(host), ex(port) }, T.file, file_value, handlers)
    end
    S.arity[io.listen] = 3

    io.local_port = function(f)
        f = file_of(f, 'io.local_port')
        return rt_value(types.U32, 'slc_io_local_port', { ex(f.fd) }, 'io.local_port', nil, 'port')
    end
    return io
end

S.read_expr = read_expr
S.new_place = new_place
S.uid = uid
S.new_version = new_version
S.cur = cur
S.Builder = Builder

return S
