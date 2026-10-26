-- slc.jitgen: residual IR -> libgccjit.
--
-- The same prepared IR slc.cgen prints, built with gccjit calls instead: this
-- file mirrors cgen's Fn method by method (place, expr, stmt, wait), and the
-- C the compiler itself contains (the runtime header, per-type helpers, the
-- runtime-call templates) is read once by slc.cjit and lowered through the
-- same rules. One IR, one runtime, two ways to machine code.

local C = require 'slc.cjit'
local G = require 'slc.cgen'
local S = require 'slc.stage'
local fold = require 'slc.fold'
local types = require 'slc.types'

local JG = {}
local fail = C.fail

local function rawp(p, k) return rawget(p, k) end
local function root(p)
    local q = rawp(p, 'parent')
    while q do p = q; q = rawp(p, 'parent') end
    return p
end
local function memory(r) return r.pk == 'deref' or r.pk == 'index' end

local dist_root = rawget(_G, 'slc_root')
local here = dist_root or (debug.getinfo(1, 'S').source:match('^@(.*)/slc/[^/]*$') or '.')
JG.runtime_dir = here .. '/runtime'

-- a unit: one module in one gccjit context ---------------------------------------------------------

local U = {}
U.__index = U

-- slc type -> C type descriptor
function U:ct(t)
    local d = self.cts[t]
    if d then return d end
    local k = t.kind
    local native = t.native_layout and t.native_layout() or t.representation
    if native then
        d = self:ct(native)
        self.cts[t] = d
        self.scope.types[G.ctype(t)] = d
        return d
    end
    if k == 'int' then d = C.int(t.bits / 8, t.signed)
    elseif k == 'float' then d = C.float(t.bits / 8)
    elseif k == 'bool' then d = C.BOOL
    elseif k == 'unit' then d = C.VOID
    elseif k == 'cstr' then d = C.CHARP
    elseif k == 'ref' or k == 'ptr' then d = C.ptr(self:ct(t.elem))
    elseif k == 'atomic' then d = self:ct(t.elem)
    elseif k == 'opaque' then
        d = self.scope:find('types', t.cname)
        if not d then
            d = C.record('struct', t.cname)
            self.scope.types[t.cname] = d
        end
    elseif k == 'chan' then d = self.scope:find('types', 'slc_chan')
    elseif k == 'pool' then d = self.scope:find('types', 'slc_pool')
    elseif k == 'slot' then d = self.scope:find('types', 'slc_slot')
    elseif k == 'group' then d = C.ptr(self.scope:find('types', 'slc_scope'))
    elseif k == 'struct' and rawget(t, 'foreign') then
        d = self:foreign_struct(t)
    elseif k == 'struct' then
        local name = G.ctype(t)
        d = C.record('struct', 'slc_' .. name)
        self.cts[t] = d
        local fs = {}
        for i, f in ipairs(t.fields) do fs[i] = { f.name, self:ct(f.type) } end
        d:set_fields(fs)
        self.scope.types[name] = d
        return d
    elseif k == 'sum' then
        local name = G.ctype(t)
        d = C.record('struct', 'slc_' .. name)
        self.cts[t] = d
        local members = {}
        for _, a in ipairs(t.alts) do
            if a.type.kind ~= 'unit' then members[#members + 1] = { a.name, self:ct(a.type) } end
            self.scope.names[name .. '_' .. a.name] = { const = a.tag, t = C.INT }
        end
        local fs = { { 'tag', C.UINT } }
        if #members > 0 then
            local u = C.record('union', 'slc_' .. name .. '_as')
            u:set_fields(members)
            fs[2] = { 'as', u }
        end
        d:set_fields(fs)
        self.scope.types[name] = d
        return d
    elseif k == 'array' then
        local name = G.ctype(t)
        d = C.record('struct', 'slc_' .. name)
        self.cts[t] = d
        d:set_fields { { 'e', C.array(self:ct(t.elem), t.length) } }
        self.scope.types[name] = d
        return d
    end
    if not d then fail('no C type for ' .. tostring(t.display or k)) end
    self.cts[t] = d
    return d
end

-- a struct whose layout a header gives: its declared fields at the header's offsets
function U:foreign_struct(t)
    -- A record the runtime header declares, whose named fields have exactly the
    -- C types this SLC view gives them, is that definition: no second probed
    -- copy. Anything else (a forward declaration, a partial or retyped view)
    -- keeps its own probed record.
    local cname = rawget(t, 'cname')
    local declared = cname and self.scope:find('types', (cname:gsub('^const%s+', '')))
    if declared and declared.fields then
        local same = true
        local paths = rawget(t, 'cpath') or {}
        for _, f in ipairs(t.fields) do
            local index = declared.byname[paths[f.name] or f.name]
            local have = index and declared.fields[index][2]
            -- A pointer is compared by its element's C name: building the
            -- element's record here would recurse (a task points back at its op).
            local ok
            if not have then ok = false
            elseif f.type.kind == 'ptr' then
                local et = f.type.elem
                local want = (et.kind == 'struct' or et.kind == 'opaque') and et.cname
                    or (et.kind == 'struct' and ('slc_' .. G.ctype(et)))
                ok = have.k == 'ptr' and (et.kind == 'struct' or et.kind == 'opaque')
                    and have.to.fields ~= nil and have.to.name == want
                if not ok and et.kind ~= 'struct' and et.kind ~= 'opaque' then
                    ok = have.k == 'ptr' and self:ct(et) == have.to
                end
            else
                ok = self:ct(f.type) == have
            end
            if not ok then same = false break end
        end
        if same then
            self.cts[t] = declared
            return declared
        end
    end
    local probe = require('slc.probe')
    local lay = probe.layout(self, t)
    local fs, off, pad = {}, 0, 0
    local order = {}
    for i, f in ipairs(t.fields) do order[i] = { f = f, off = lay.offsets[f.name] } end
    table.sort(order, function(a, b) return a.off < b.off end)
    local d = C.record('struct', 'slc_foreign_' .. (t.display:gsub('[^%w_]', '_')))
    self.cts[t] = d
    for _, o in ipairs(order) do
        if o.off > off then
            pad = pad + 1
            fs[#fs + 1] = { '__pad' .. pad, C.array(C.U8, o.off - off) }
            off = o.off
        end
        local ft = self:ct(o.f.type)
        local real = lay.offsets[o.f.name .. '#size']
        if real and real ~= C.sizeof(ft) then
            fail(('%s.%s is %d bytes in its header, declared as %s (%d bytes)'):format(t.display, o.f.name, real,
                o.f.type.display, C.sizeof(ft)))
        end
        fs[#fs + 1] = { o.f.name, ft }
        off = off + C.sizeof(ft)
    end
    if lay.size > off then
        pad = pad + 1
        fs[#fs + 1] = { '__pad' .. pad, C.array(C.U8, lay.size - off) }
    end
    d:set_fields(fs)
    d.packed_check = lay
    d.foreign = true
    return d
end

local function fntype_of(u, fn)
    local ps = {}
    if fn.gs then ps[1] = C.SIZE end
    for _, p in ipairs(fn.params) do ps[#ps + 1] = u:ct(p.T) end
    return C.fntype(u:ct(fn.ret), ps, false)
end

-- an extern's descriptor, one per C name
function U:extern(x)
    local d = self.externs[x.cname]
    if d then return d end
    local ps = {}
    for i, t in ipairs(x.params) do ps[i] = self:ct(t) end
    d = C.fn(x.cname, C.fntype(self:ct(x.ret), ps, x.variadic), 'imported')
    self.externs[x.cname] = d
    return d
end

function U:rt_fn(name)
    local d = self.scope:find('names', name)
    if not d or not d.fn then fail('no runtime function ' .. name) end
    if d.fn.ast and not d.fn.define then C.define_from_ast(d.fn, self.scope) end
    return { fn = d.fn, t = d.fn.t }
end

-- the emitter for one function ---------------------------------------------------------------------

local Fn = {}
Fn.__index = Fn

function Fn:pname(p)
    local v = self.names[p]
    if v then return v end
    if self.task_mode then
        local name = self.frame_fields[p]
        if not name then fail('a task local missing from its frame: ' .. tostring(p.name)) end
        v = function() return self.ctx:arrow(self.frame, name) end
    else
        local l = self.fb:var(self.u:ct(p.T), S.sanitize(p.pk == 'temp' and (rawget(p, 'hint') or 't') or p.name))
        v = function() return l end
    end
    self.names[p] = v
    return v
end

function Fn:param_lv(name)
    if self.task_mode then return self.ctx:arrow(self.frame, name) end
    local i = self.param_index[name]
    if not i then fail('no parameter ' .. name) end
    return self.ctx:param(self.desc, i)
end

-- a member, or a path of members (foreign structs name nested members)
local function member_path(ctx, v, path)
    for part in path:gmatch('[^%.]+') do v = ctx:member(v, part) end
    return v
end

function Fn:place(p)
    local ctx = self.ctx
    if p.pk == 'index' then
        return ctx:index(self:expr(rawp(p, 'base')), self:expr(rawp(p, 'idx')))
    end
    if p.pk == 'deref' then
        return ctx:deref(self:expr(rawp(p, 'ptr')))
    end
    if p.pk == 'field' then
        local parent = rawp(p, 'parent')
        -- a foreign struct is laid out here by its declared names, at the header's offsets
        local member = rawget(parent.T, 'foreign') and rawp(p, 'fname') or G.cfield(parent.T, rawp(p, 'fname'))
        if parent.pk == 'deref' then
            local first, rest = member:match('^([^%.]+)%.?(.*)$')
            local v = ctx:arrow(self:expr(rawp(parent, 'ptr')), first)
            if rest ~= '' then v = member_path(ctx, v, rest) end
            return v
        end
        return member_path(ctx, self:place(parent), member)
    end
    if p.pk == 'param' then return self:param_lv(p.name) end
    return self:pname(p)()
end

-- small integer types compute in 32 bits, as in cgen
function Fn:operand(e, t)
    local v = self:expr(e)
    if t.small then return self.ctx:conv(v, C.int(4, t.signed)) end
    return v
end

local BIN = { add = '+', sub = '-', mul = '*', div = '/', mod = '%', band = '&', bor = '|', bxor = '^',
              shl = '<<', shr = '>>' }
local CMP = { eq = '==', ne = '!=', lt = '<', le = '<=', gt = '>', ge = '>=' }

function Fn:const(t, v)
    local ctx = self.ctx
    if t.kind == 'cstr' then return ctx:string(v) end
    if t.kind == 'bool' then return ctx:int_const(C.BOOL, v and 1 or 0) end
    if t.kind == 'int' then return ctx:int_const(self.u:ct(t), v) end
    if t.kind == 'float' then return ctx:float_const(self.u:ct(t), v) end
    fail('no constant of type ' .. tostring(t.display))
end

function Fn:expr(e)
    local ctx, u = self.ctx, self.u
    local op = e.op
    if op == 'const' then
        return self:const(e.T, e.v)
    elseif op == 'param' then
        return self:param_lv(e.name)
    elseif op == 'read' then
        return self:place(e.place)
    elseif op == 'addr' then
        local p = e.place
        if p.pk == 'deref' then return self:expr(rawp(p, 'ptr')) end
        return ctx:addr(self:place(p))
    elseif op == 'bin' then
        local t = e.T
        local a, b = self:operand(e.a, t), self:operand(e.b, t)
        return ctx:conv(ctx:binop(BIN[e.o], a, b), u:ct(t))
    elseif op == 'cmp' then
        return ctx:cmp(CMP[e.o], self:expr(e.a), self:expr(e.b))
    elseif op == 'and' or op == 'or' then
        return ctx:logic(op == 'and' and '&&' or '||', self:expr(e.a), self:expr(e.b))
    elseif op == 'un' then
        local t = e.T
        if e.o == 'not' then return ctx:unop('!', self:expr(e.a)) end
        if t.small then
            local wide = C.int(4, t.signed)
            local x = ctx:conv(self:expr(e.a), wide)
            local r
            if e.o == 'neg' then
                if t.signed then r = ctx:unop('-', x)
                else r = ctx:binop('-', ctx:int_const(C.UINT, 0), x) end
            else
                r = ctx:unop('~', x)
            end
            return ctx:conv(r, u:ct(t))
        end
        return ctx:conv(ctx:unop(e.o == 'neg' and '-' or '~', self:expr(e.a)), u:ct(t))
    elseif op == 'cconst' then
        local v = require('slc.probe').constant(u, e.cconst)
        if not v then fail('no value probed for ' .. e.cconst) end
        return v
    elseif op == 'stack_index' then
        if e.offset == 0 then return self:gs_sp() end
        return ctx:binop('+', self:gs_sp(), ctx:int_const(C.SIZE, e.offset))
    elseif op == 'conv' then
        return ctx:conv(self:expr(e.a), u:ct(e.T))
    elseif op == 'field' then
        local member = e.a.T and not rawget(e.a.T, 'foreign') and G.cfield(e.a.T, e.name) or e.name
        return member_path(ctx, self:expr(e.a), member)
    elseif op == 'zero' then
        return ctx:zero(u:ct(e.T))
    elseif op == 'array' then
        local t = u:ct(e.T)
        local tmp = self.fb:var(t, 'array')
        self.fb:assign(tmp, ctx:zero(t))
        local data, indices = member_path(ctx, tmp, 'e'), {}
        for i in pairs(e.fields) do indices[#indices + 1] = i end
        table.sort(indices)
        for _, i in ipairs(indices) do
            self.fb:assign(ctx:index(data, ctx:int_const(C.SIZE, i)), self:expr(e.fields[i]))
        end
        return tmp
    elseif op == 'agg' then
        local t = u:ct(e.T)
        if rawget(e.T, 'cpath') and next(rawget(e.T, 'cpath')) or t.foreign then
            -- a foreign struct: field by field into a zeroed temporary
            local tmp = self.fb:var(t, 'agg')
            self.fb:assign(tmp, ctx:zero(t))
            for _, f in ipairs((e.T.native_layout and e.T.native_layout() or e.T).fields) do
                self.fb:assign(member_path(ctx, tmp, f.name), self:expr(e.fields[f.name]))
            end
            return tmp
        end
        return self:construct(t, e.T, e.fields)
    elseif op == 'sum' then
        local t = u:ct(e.T)
        local tag
        for _, a in ipairs(e.T.alts) do if a.name == e.alt then tag = a.tag end end
        local tagv = ctx:int_const(C.UINT, tag)
        local J = C.lib()
        local ffi = require 'ffi'
        if e.e then
            local ut = t.fields[2][2]
            local fi = ut.byname[e.alt]
            ctx:jt(t)
            local uv = J.gcc_jit_context_new_union_constructor(ctx.c, nil, ctx:jt(ut), ctx:field(ut, fi),
                ctx:rv(ctx:conv(self:expr(e.e), ut.fields[fi][2])))
            local fs = ffi.new('gcc_jit_field*[2]', ctx:field(t, 1), ctx:field(t, 2))
            local vs = ffi.new('gcc_jit_rvalue*[2]', ctx:rv(tagv), uv)
            return C.val(t, J.gcc_jit_context_new_struct_constructor(ctx.c, nil, ctx:jt(t), 2, fs, vs))
        end
        local fs = ffi.new('gcc_jit_field*[1]', ctx:field(t, 1))
        local vs = ffi.new('gcc_jit_rvalue*[1]', ctx:rv(tagv))
        return C.val(t, J.gcc_jit_context_new_struct_constructor(ctx.c, nil, ctx:jt(t), 1, fs, vs))
    elseif op == 'null' then
        return ctx:zero(u:ct(e.T))
    elseif op == 'tagname' then
        for _, a in ipairs(e.sum.alts) do
            if a.name == e.alt then return ctx:int_const(C.UINT, a.tag) end
        end
        fail('no alternative ' .. e.alt)
    elseif op == 'call' then
        if e.ext and e.ext.variable then return require('slc.probe').read_variable(self, e.ext) end
        local args = {}
        if e.fn and e.fn.gs then
            local off = e.gs_off or 0
            local gs = self:gs_sp()
            args[1] = off == 0 and gs or ctx:binop('+', gs, ctx:int_const(C.SIZE, off))
        end
        for _, a in ipairs(e.args) do args[#args + 1] = self:expr(a) end
        local target = e.fn and { fn = u.fns[e.fn] } or { fn = u:extern(e.ext) }
        if not target.fn then fail('no function for ' .. tostring(e.fn and e.fn.cname)) end
        return ctx:call(target, args)
    elseif op == 'atomic' then
        local ptr = self:expr(e.ptr)
        if e.o == 'cas' then
            -- gcc's compare_exchange takes the expected pointer, then the desired value
            return ctx:atomic('compare_exchange', {
                ptr, ctx:addr(self:place(e.expected_place)), self:expr(e.args[1]),
                ctx:int_const(C.BOOL, 0),
                ctx:int_const(C.INT, C.MEMORY_ORDERS[e.order]),
                ctx:int_const(C.INT, C.MEMORY_ORDERS[e.fail_order]),
            })
        end
        local args = { ptr }
        for i, a in ipairs(e.args or {}) do args[#args + 1] = self:expr(a) end
        args[#args + 1] = ctx:int_const(C.INT, C.MEMORY_ORDERS[e.order])
        return ctx:atomic(e.o, args)
    elseif op == 'vaconv' then
        local VACONV = { int = C.INT, uint = C.UINT, llong = C.int(8, true), ullong = C.int(8, false),
                         double = C.float(8) }
        return ctx:conv(self:expr(e.a), VACONV[e.abi])
    elseif op == 'sizeof' then
        -- The prepared native descriptor, not a textual C name that may also
        -- name an opaque runtime declaration (e.g. slc_scope).
        return ctx:int_const(u:ct(e.T), C.sizeof(u:ct(e.sizeof)))
    elseif op == 'array_index' then
        local data = member_path(ctx, self:expr(e.a), 'e')
        return ctx:index(data, self:expr(e.idx))
    elseif op == 'slot_at' then
        local raw = ctx:call(u:rt_fn('slc_slot_at'), { self:task_value(), self:expr(e.slot) })
        return ctx:conv(raw, u:ct(e.T))
    elseif op == 'case_array' then
        -- the first_of case list: an array of slc_case, passed as its address
        local case_t = u.scope:find('types', 'slc_case')
        if not case_t then fail('no slc_case declared in the runtime header') end
        local n = #e.items
        local arr = self.fb:var(C.array(case_t, math.max(n, 1)), 'cases' .. n)
        self.fb:assign(arr, ctx:zero(C.array(case_t, math.max(n, 1))))
        for i, c in ipairs(e.items) do
            local at = ctx:addr(ctx:index(arr, ctx:int_const(C.SIZE, i - 1)))
            self.fb:assign(ctx:arrow(at, 'kind'), self:expr(c.kind))
            if c.chan then self.fb:assign(ctx:arrow(at, 'chan'), self:expr(c.chan)) end
            if c.buf then self.fb:assign(ctx:arrow(at, 'buf'), self:expr(c.buf)) end
            if c.ns then self.fb:assign(ctx:arrow(at, 'ns'), self:expr(c.ns)) end
        end
        return ctx:addr(arr)
    elseif op == 'rtcall' then
        -- a runtime call: the header's declaration and converted arguments
        local target = u:rt_fn(e.cname)
        local vals = {}
        for i, a in ipairs(e.args or {}) do
            local v = self:expr(a)
            local pt = target.t.params[i]
            vals[i] = pt and ctx:conv(v, pt) or v
        end
        return ctx:call(target, vals)
    elseif op == 'task' then
        return self:task_value()
    elseif op == 'ops' then
        return self:ops_value()
    end
    fail('unknown expression ' .. tostring(op))
end

-- a struct value from its fields, in declaration order
function Fn:construct(t, st, fields)
    local ctx = self.ctx
    local J = C.lib()
    local ffi = require 'ffi'
    ctx:jt(t)
    -- The C record is authoritative: a storage/id representation may be a
    -- header struct whose fields are shared with several SLC types.
    local list = t.fields or st.fields
    local n = #list
    local fs = ffi.new('gcc_jit_field*[?]', math.max(n, 1))
    local vs = ffi.new('gcc_jit_rvalue*[?]', math.max(n, 1))
    for i, f in ipairs(list) do
        fs[i - 1] = ctx:field(t, i)
        vs[i - 1] = ctx:rv(ctx:conv(self:expr(fields[f[1]]), f[2]))
    end
    return C.val(t, J.gcc_jit_context_new_struct_constructor(ctx.c, nil, ctx:jt(t), n, fs, vs))
end

function Fn:gs_sp()
    if not self.gs_sp_v then fail('no data stack base here') end
    return self.gs_sp_v
end

-- the waiting party ($T): the task, or the plain thread's slc_tk
function Fn:task_value()
    if self.task_mode then return self.ctx:addr(self.ctx:arrow(self.frame, 'task')) end
    if not self.slc_tk then fail('no waiting party here') end
    return self.slc_tk
end

function Fn:ops_value()
    if self.task_mode then return self.ctx:arrow(self.frame, 'ops') end
    return self.slc_ops
end

-- statements -------------------------------------------------------------------------------------------

function Fn:label_block(l)
    local b = self.labels[l]
    if not b then b = self.fb:block('L'); self.labels[l] = b end
    return b
end

function Fn:block(blk)
    for _, s in ipairs(blk) do self:stmt(s) end
end

function Fn:stmt(s)
    local ctx, fb = self.ctx, self.fb
    local op = s.op
    if op == 'store' or op == 'let' then
        fb:assign(self:place(s.place), self:expr(s.e))
    elseif op == 'expr' then
        fb:eval(self:expr(s.e))
    elseif op == 'ret' then
        if self.task_mode then fb:ret(ctx:int_const(C.INT, 0))
        elseif s.e then fb:ret(self:expr(s.e))
        else fb:ret() end
    elseif op == 'if' then
        local yes, no, done = fb:block('then'), fb:block('else'), fb:block('fi')
        fb:branch(self:expr(s.c), yes, no)
        fb:at(yes); self:block(s.a); fb:jump(done)
        fb:at(no); self:block(s.b); fb:jump(done)
        fb:at(done)
    elseif op == 'for' then
        -- if (lo <= hi) for (iv = lo;; ++iv) { body; if (iv == hi) break; }
        local t = self.u:ct(s.T)
        local iv = self:place(s.iv)
        local lo, hi = self:expr(s.lo), self:expr(s.hi)
        local step = s.step
        local start, body, test, done = fb:block('init'), fb:block('for'), fb:block('next'), fb:block('rof')
        fb:branch(ctx:cmp(step > 0 and '<=' or '>=', lo, hi), start, done)
        fb:at(start)
        fb:assign(iv, lo)
        fb:jump(body)
        fb:at(body)
        self.loops[#self.loops + 1] = { exit = done }
        self:block(s.body)
        self.loops[#self.loops] = nil
        fb:jump(test)
        fb:at(test)
        local stop
        if math.abs(step) == 1 then
            stop = ctx:cmp('==', iv, hi)
        else
            local ut = C.int(t.size, false)
            local left = step > 0 and ctx:binop('-', ctx:conv(hi, ut), ctx:conv(iv, ut))
                or ctx:binop('-', ctx:conv(iv, ut), ctx:conv(hi, ut))
            stop = ctx:cmp('<', left, ctx:int_const(C.UINT, math.abs(step)))
        end
        local incr = fb:block('incr')
        fb:branch(stop, done, incr)
        fb:at(incr)
        fb:assign(iv, ctx:conv(ctx:binop('+', iv, ctx:int_const(C.int(8, true), step)), t))
        fb:jump(body)
        fb:at(done)
    elseif op == 'loop' then
        local top = s.top and self:label_block(s.top) or fb:block('loop')
        local done = fb:block('pool')
        fb:jump(top)
        fb:at(top)
        self.loops[#self.loops + 1] = { exit = done }
        self:block(s.body)
        self.loops[#self.loops] = nil
        fb:jump(top)
        fb:at(done)
    elseif op == 'break' then
        fb:jump(self.loops[#self.loops].exit)
    elseif op == 'goto' then
        fb:jump(self:label_block(s.label))
    elseif op == 'setparam' then
        fb:assign(self:param_lv(s.name), self:expr(s.e))
    elseif op == 'wait' then
        self:wait(s)
    elseif op == 'spawn' then
        self:spawn(s)
    elseif op == 'label' then
        local b = self:label_block(s.label)
        fb:jump(b)
        fb:at(b)
    elseif op == 'nop' then
        return
    elseif op == 'fence' then
        self:check(s)
    elseif op == 'trap' then
        fb:eval(ctx:call(self.u:rt_fn('slc_trap'), { self:expr(s.msg) }))
    elseif op == 'gs_reset' then
        -- give a data stack back: its base for this function, its saved top
        local k = s.k
        local at = k == 0 and self.gs_sp_v or ctx:binop('+', self.gs_sp_v, ctx:int_const(C.SIZE, k))
        local top = self.task_mode and ctx:arrow(self.frame, 'gs_top' .. k) or self.gs_tops[k]
        fb:eval(ctx:call(self.u:rt_fn('slc_gs_reset'), { at, top }))
    else
        fail('unknown statement ' .. tostring(op))
    end
end

-- an atomic fence: the memory order the stage chose
function Fn:check(s)
    local ctx, fb = self.ctx, self.fb
    fb:eval(ctx:atomic('thread_fence', { ctx:int_const(C.INT, C.MEMORY_ORDERS[s.order]) }))
end

-- a spawn: a zeroed frame, the copies, then the task may run
function Fn:spawn(s)
    local ctx, fb, u = self.ctx, self.fb, self.u
    local task = u.tasks[s.task]
    local args = {}
    for i, a in ipairs(s.args) do args[i] = self:expr(a) end
    local fp = C.ptr(task.frame)
    local raw = ctx:call(u:rt_fn('slc_spawn'), { args[1], ctx:int_const(C.SIZE, C.sizeof(task.frame)),
        ctx:addr({ fn = task.step, t = task.step.t }) })
    local t = fb:var(fp, 'slc_t')
    fb:assign(t, ctx:conv(raw, fp))
    for i, p in ipairs(s.task.params) do fb:assign(ctx:arrow(t, p.name), args[i + 1]) end
    fb:eval(ctx:call(u:rt_fn('slc_start'), { ctx:addr(ctx:arrow(t, 'task')) }))
end

-- a wait: in a task, suspend and resume here; in plain code, block
function Fn:wait(s)
    local ctx, fb, u = self.ctx, self.fb, self.u
    local INT = C.INT
    if s.yield then
        local yes, resume = fb:block('yield'), fb:block('resume')
        local due = ctx:call(u:rt_fn('slc_budget'), { self:task_value() })
        fb:branch(due, yes, resume)
        fb:at(yes)
        fb:assign(ctx:member(ctx:arrow(self.frame, 'task'), 'state'), ctx:int_const(INT, #self.resumes + 1))
        fb:ret(ctx:int_const(INT, 2))
        self.resumes[#self.resumes + 1] = resume
        fb:at(resume)
        return
    end
    local extra = {}
    if s.body then
        -- a blocking block: its statements become a function over the frame
        self.blocking_n = (self.blocking_n or 0) + 1
        extra.F = self:blocking_fn(s.body)
    end
    local args = s.args
    -- the callee is the runtime header's own declaration, so its parameter
    -- types (and the conversions to them) come from there
    local target = u:rt_fn(s.callee.cname)
    local vals = {}
    for i, a in ipairs(args) do
        local v
        if a.op == 'block_fn' then
            v = ctx:addr({ fn = extra.F.fn, t = extra.F.t })
        elseif a.op == 'block_env' then
            v = ctx:conv(self.frame, C.VOIDP)
        else
            v = self:expr(a)
        end
        local pt = target.t.params[i]
        vals[i] = pt and ctx:conv(v, pt) or v
    end
    local call = ctx:call(target, vals)
    local used = self.reads[s.result]
    local pending = ctx:cmp('==', call, ctx:int_const(INT, 1))
    if self.task_mode then
        local yes, resume = fb:block('wait'), fb:block('resume')
        fb:branch(pending, yes, resume)
        fb:at(yes)
        fb:assign(ctx:member(ctx:arrow(self.frame, 'task'), 'state'), ctx:int_const(INT, #self.resumes + 1))
        fb:ret(ctx:int_const(INT, 1))
        self.resumes[#self.resumes + 1] = resume
        fb:at(resume)
        if used then fb:assign(self:place(s.result), ctx:member(ctx:arrow(self.frame, 'task'), 'result')) end
    else
        local yes, go = fb:block('block'), fb:block('go')
        fb:branch(pending, yes, go)
        fb:at(yes)
        fb:eval(ctx:call(u:rt_fn('slc_block'), { self.slc_tk }))
        fb:jump(go)
        fb:at(go)
        if used then fb:assign(self:place(s.result), ctx:arrow(self.slc_tk, 'result')) end
    end
end

-- the body of a blocking block, as a function over the task's frame
function Fn:blocking_fn(body)
    local ctx, u = self.ctx, self.u
    local name = self.step_name .. '_blocking' .. self.blocking_n
    local d = C.fn(name, C.fntype(C.VOID, { C.VOIDP }, false), 'internal', { 'slc_frame' })
    local saved = { fb = self.fb, frame = self.frame, gs = self.gs_sp_v, loops = self.loops, labels = self.labels }
    self.fb = ctx:body(d)
    self.loops, self.labels = {}, {}
    local fv = self.fb:var(C.ptr(self.task_frame), 'f')
    self.fb:assign(fv, ctx:conv(ctx:param(d, 1), C.ptr(self.task_frame)))
    self.frame = fv
    if self.fn.needs_gs then self.gs_sp_v = ctx:int_const(C.SIZE, 0) end
    self:block(body)
    self.fb:finish()
    self.fb, self.frame, self.gs_sp_v, self.loops, self.labels = saved.fb, saved.frame, saved.gs, saved.loops,
        saved.labels
    return { fn = d, t = d.t }
end

-- functions ---------------------------------------------------------------------------------------------

local function read_places(fn)
    local reads = {}
    G.walk_block(fn.body, nil, function(e) if e.op == 'read' and e.place then reads[root(e.place)] = true end end)
    return reads
end

local function new_fn(u, fn, desc)
    return setmetatable({ u = u, ctx = u.ctx, fn = fn, desc = desc, names = {}, labels = {}, loops = {},
                          resumes = {}, reads = read_places(fn), gs_tops = {}, param_index = {} }, Fn)
end

function U:emit_function(fn)
    local ctx = self.ctx
    local d = self.fns[fn]
    local f = new_fn(self, fn, d)
    f.fb = ctx:body(d)
    local base = fn.gs and 1 or 0
    for i, p in ipairs(fn.params) do f.param_index[p.name] = i + base end
    if fn.gs then f.gs_sp_v = ctx:param(d, 1)
    elseif fn.needs_gs then f.gs_sp_v = ctx:int_const(C.SIZE, 0) end
    if fn.waits or fn.needs_self then
        local tk = f.fb:var(C.ptr(self.scope:find('types', 'slc_task')), 'slc_tk')
        f.fb:assign(tk, ctx:call(self:rt_fn('slc_self'), {}))
        f.slc_tk = tk
    end
    if fn.waits then
        f.slc_ops = f.fb:var(C.array(self.scope:find('types', 'slc_op'), fn.waits), 'slc_ops')
    end
    for k = 0, (fn.gs_count or 0) - 1 do
        local top = f.fb:var(C.SIZE, 'gs_top' .. k)
        local at = k == 0 and f.gs_sp_v or ctx:binop('+', f.gs_sp_v, ctx:int_const(C.SIZE, k))
        f.fb:assign(top, ctx:call(self:rt_fn('slc_gs_top'), { at }))
        f.gs_tops[k] = top
    end
    f:block(fn.body)
    f.fb:finish()
end

-- a task's frame: the task, its operations, its parameters, its data-stack
-- tops and every local its body names (cgen collects these as it prints)
function U:plan_task(fn)
    local fields = { { 'task', self.scope:find('types', 'slc_task') } }
    if fn.waits then fields[#fields + 1] = { 'ops', C.array(self.scope:find('types', 'slc_op'), fn.waits) } end
    local used = { task = true, ops = true }
    for _, p in ipairs(fn.params) do
        fields[#fields + 1] = { p.name, self:ct(p.T) }
        used[p.name] = true
    end
    for k = 0, (fn.gs_count or 0) - 1 do
        fields[#fields + 1] = { 'gs_top' .. k, C.SIZE }
        used['gs_top' .. k] = true
    end
    local names, order = {}, {}
    local function note(p)
        p = root(p)
        if memory(p) or p.pk == 'param' or names[p] then return end
        local base = S.sanitize(p.pk == 'temp' and (rawget(p, 'hint') or 't') or p.name)
        local cand, k = base, 1
        while used[cand] do k = k + 1; cand = base .. k end
        used[cand] = true
        names[p] = cand
        order[#order + 1] = p
    end
    G.walk_block(fn.body, function(s)
        if s.op == 'wait' and s.result then note(s.result) end
        if s.iv then note(s.iv) end
        if (s.op == 'store' or s.op == 'let') and s.place then note(s.place) end
    end, function(e) if e.place then note(e.place) end end)
    for _, p in ipairs(order) do fields[#fields + 1] = { names[p], self:ct(p.T) } end
    local frame = C.record('struct', 'slc_' .. fn.cname .. '_frame')
    frame:set_fields(fields)
    local step = C.fn(fn.cname .. '_step', C.fntype(C.INT, { C.ptr(self.scope:find('types', 'slc_task')) }, false),
        'internal', { 'slc_task_' })
    self.tasks[fn] = { frame = frame, step = step, fields = names }
end

function U:emit_task(fn)
    local ctx = self.ctx
    local task = self.tasks[fn]
    local f = new_fn(self, fn, task.step)
    f.task_mode, f.frame_fields, f.task_frame = true, task.fields, task.frame
    f.step_name = fn.cname .. '_step'
    f.fb = ctx:body(task.step)
    local fv = f.fb:var(C.ptr(task.frame), 'f')
    f.fb:assign(fv, ctx:conv(ctx:param(task.step, 1), C.ptr(task.frame)))
    f.frame = fv
    if fn.needs_gs then f.gs_sp_v = ctx:int_const(C.SIZE, 0) end
    local entry = f.fb.cur
    local start = f.fb:block('start')
    f.fb:at(start)
    for k = 0, (fn.gs_count or 0) - 1 do
        local at = k == 0 and f.gs_sp_v or ctx:binop('+', f.gs_sp_v, ctx:int_const(C.SIZE, k))
        f.fb:assign(ctx:arrow(fv, 'gs_top' .. k), ctx:call(self:rt_fn('slc_gs_top'), { at }))
    end
    f:block(fn.body)
    if not f.fb.cur.term then f.fb:ret(ctx:int_const(C.INT, 0)) end
    -- resume where the last wait left off
    local cases = {}
    for k, b in ipairs(f.resumes) do cases[k] = { k, b } end
    f.fb:at(entry)
    if #cases > 0 then
        f.fb:switch(ctx:member(ctx:arrow(fv, 'task'), 'state'), start, cases)
    else
        f.fb:jump(start)
    end
    f.fb:finish()
end

-- a module, built ----------------------------------------------------------------------------------------

function JG.build(mod, opts)
    opts = opts or {}
    local fns = G.prepare(mod)
    -- Code generation belongs to this module: per-compilation caches (layout
    -- representations) must be looked up for the module being emitted, even if
    -- another compilation (the runtime policy) ran after it. Staging of the
    -- caller may still be in progress, so the previous module is restored.
    local saved_module = S.module
    S.module = mod
    local ok, result = pcall(function()
    local ctx = C.context(opts)
    local scope = C.scope(C.runtime_scope(opts.runtime_dir or JG.runtime_dir))
    local u = setmetatable({ ctx = ctx, scope = scope, cts = {}, fns = {}, externs = {}, tasks = {},
                             exports = {}, mod = mod }, U)
    local structs = G.collect_structs(fns)
    u.probe = require('slc.probe').run(mod, fns, structs, { opts.runtime_dir or JG.runtime_dir })
    u.getter_fns = {}
    for _, t in ipairs(structs) do u:ct(t) end
    for _, fn in ipairs(fns) do
        if fn.task then
            u:plan_task(fn)
        else
            local pnames = {}
            if fn.gs then pnames[1] = 'gs_sp' end
            for _, p in ipairs(fn.params) do pnames[#pnames + 1] = p.name end
            u.fns[fn] = C.fn(fn.cname, fntype_of(u, fn), fn.exported and 'exported' or 'internal', pnames)
            if fn.exported then u.exports[#u.exports + 1] = fn end
        end
    end
    for _, fn in ipairs(fns) do
        if fn.task then u:emit_task(fn) else u:emit_function(fn) end
    end
    ctx:check()
    return u
    end)
    S.module = saved_module
    if not ok then error(result, 0) end
    return result
end

-- for in-process calls: per export, an argument block and a thunk over it, so
-- slc_try can run the export and catch its traps
function U:thunks()
    local ctx = self.ctx
    for _, fn in ipairs(self.exports) do
        local d = self.fns[fn]
        local fields = {}
        for i, pt in ipairs(d.t.params) do fields[i] = { 'a' .. i, pt } end
        if d.t.ret.k ~= 'void' then fields[#fields + 1] = { 'r', d.t.ret } end
        if #fields == 0 then fields[1] = { 'unused', C.INT } end
        local env = C.record('struct', 'slc_' .. fn.cname .. '_args'):set_fields(fields)
        local th = C.fn(fn.cname .. '__slc_thunk', C.fntype(C.VOID, { C.VOIDP }, false), 'exported', { 'env' })
        local fb = ctx:body(th)
        local ep = fb:var(C.ptr(env), 'e')
        fb:assign(ep, ctx:conv(ctx:param(th, 1), C.ptr(env)))
        local args = {}
        for i = 1, #d.t.params do args[i] = ctx:arrow(ep, 'a' .. i) end
        local r = ctx:call({ fn = d }, args)
        if d.t.ret.k ~= 'void' then fb:assign(ctx:arrow(ep, 'r'), r) else fb:eval(r) end
        fb:ret()
        fb:finish()
        self.thunk_of = self.thunk_of or {}
        self.thunk_of[fn] = { env = env, name = th.name }
    end
    ctx:check()
end

-- the C declarations of the exports, for LuaJIT's FFI (prefix keeps units apart)
function U:ffi_decls(prefix, everything)
    local out, done = {}, {}
    local defined_names = {}
    local function cname(t)
        if t.k == 'int' then return (t.signed and 'int' or 'uint') .. (t.size * 8) .. '_t' end
        if t.k == 'float' then return t.size == 4 and 'float' or 'double' end
        if t.k == 'bool' then return 'bool' end
        if t.k == 'void' then return 'void' end
        if t.k == 'ptr' then
            if t.to.k == 'fn' then return 'void *' end
            return cname(t.to) .. ' *'
        end
        if t.k == 'struct' or t.k == 'union' then return t.k .. ' ' .. prefix .. t.name end
        error('no FFI name for ' .. C.show(t))
    end
    local function define(t)
        if done[t] then return end
        done[t] = true
        -- Two SLC views of one C struct are two descriptors with one name: the
        -- FFI declaration unit holds one of them (a complete form wins).
        local named = t.k == 'struct' or t.k == 'union'
        if named and t.name then
            local have = defined_names[t.name]
            if have == 'full' or (have and not t.fields) then return end
            defined_names[t.name] = t.fields and 'full' or 'forward'
        end
        if t.k == 'ptr' then
            if t.to.k == 'struct' and not t.to.fields then
                out[#out + 1] = 'struct ' .. prefix .. t.to.name .. ';'
                return
            end
            return define(t.to)
        end
        if t.k == 'array' then return define(t.of) end
        if t.k ~= 'struct' and t.k ~= 'union' then return end
        if not t.fields then out[#out + 1] = t.k .. ' ' .. prefix .. t.name .. ';' return end
        for _, f in ipairs(t.fields) do
            local ft = f[2]
            while ft.k == 'array' do ft = ft.of end
            if ft.k == 'ptr' and (ft.to.k == 'struct' or ft.to.k == 'union') then
                if not done[ft.to] then out[#out + 1] = ft.to.k .. ' ' .. prefix .. ft.to.name .. ';' end
            else
                define(ft)
            end
        end
        local lines = { t.k .. ' ' .. prefix .. t.name .. ' {' }
        for _, f in ipairs(t.fields) do
            local ft, dims = f[2], ''
            while ft.k == 'array' do dims = dims .. '[' .. ft.n .. ']'; ft = ft.of end
            lines[#lines + 1] = '    ' .. cname(ft) .. ' ' .. f[1] .. dims .. ';'
        end
        lines[#lines + 1] = '};'
        out[#out + 1] = table.concat(lines, '\n')
    end
    local sigs = {}
    -- every module type with a C name, so callers can make arguments
    for cname, t in pairs(self.scope.types) do
        if (t.k == 'struct' or t.k == 'union') and t.fields and not t.foreign then define(t) end
    end
    if everything then
        for t in pairs(self.ctx.jts) do
            if (t.k == 'struct' or t.k == 'union') and t.fields then define(t) end
        end
    end
    for _, fn in ipairs(self.exports) do
        local d = self.fns[fn]
        if self.thunk_of and self.thunk_of[fn] then define(self.thunk_of[fn].env) end
        define(d.t.ret)
        local ps = {}
        for i, p in ipairs(d.t.params) do define(p); ps[i] = cname(p) end
        sigs[fn.cname] = cname(d.t.ret) .. ' (*)(' .. (#ps > 0 and table.concat(ps, ', ') or 'void') .. ')'
    end
    return table.concat(out, '\n'), sigs
end

-- every record this unit made, laid out by LuaJIT's C parser and compared with
-- the layout this backend assumed (sizeof in slc_spawn, foreign padding)
local checks = 0
function U:check_layouts()
    local ffi = require 'ffi'
    checks = checks + 1
    local prefix = 'slcchk' .. checks .. '_'
    local decls = self:ffi_decls(prefix, true)
    ffi.cdef(decls)
    local bad = {}
    for t in pairs(self.ctx.jts) do
        if (t.k == 'struct' or t.k == 'union') and t.fields then
            local real = ffi.sizeof(t.k .. ' ' .. prefix .. t.name)
            if real ~= C.sizeof(t) then bad[#bad + 1] = ('%s: %d, assumed %d'):format(t.name, real, C.sizeof(t)) end
        end
    end
    return bad
end

return JG
