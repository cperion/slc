-- Prepared residual IR -> fixed-bank stencil graph. No physical registers are
-- chosen here: the integer operand stack follows the pack's fixed convention.
local ffi = require 'ffi'
local types = require 'slc.types'
local Layout = require 'slc.direct.layout'
local S = require 'slc.stage'
local RuntimeMeta = require 'slc.direct.runtime_meta'
local M = {}
local Fn = {}; Fn.__index = Fn
local function fail(fn, message)
    error('direct: ' .. (fn and fn.cname or 'module') .. ': ' .. message, 0)
end
local function key(t, fn)
    if t.kind == 'atomic' then return key(t.elem, fn) end
    if t.kind == 'chan' or t.kind == 'pool' or t.kind == 'slot' then return 'blob' end
    if t.kind == 'group' then return 'u64' end
    if t.kind == 'struct' or t.kind == 'sum' or t.kind == 'array' or t.native_layout or t.representation then return 'blob' end
    if t.kind == 'bool' then return 'bool' end
    if t.kind == 'unit' then return 'unit' end
    if t.kind == 'float' and (t.bits == 32 or t.bits == 64) then return 'f' .. t.bits end
    if t.kind == 'ptr' or t.kind == 'ref' or t.kind == 'fn' or t.kind == 'cstr' then return 'u64' end
    if t.kind == 'int' and (t.bits == 8 or t.bits == 16 or t.bits == 32 or t.bits == 64) then
        return (t.signed and 'i' or 'u') .. t.bits
    end
    fail(fn, 'unsupported native type ' .. tostring(t.display or t.kind))
end
M.key = key
function M.ctype(t)
    if t.kind == 'atomic' then return M.ctype(t.elem) end
    if t.kind == 'ptr' or t.kind == 'ref' or t.kind == 'fn' then return 'void *' end
    return t.cname
end
local function raw(p, k) return rawget(p, k) end
function Fn:emit(op, fields)
    fields = fields or {}; fields.op = 'cp_' .. op
    assert(self.pack.stencils[fields.op], 'direct: missing prebuilt stencil ' .. fields.op)
    self.nodes[#self.nodes + 1] = fields
    return fields
end
function Fn:label() return {} end
function Fn:bind(label)
    assert(not self.labels[label] or self.labels[label] == #self.nodes + 1, 'direct: conflicting label')
    self.labels[label] = #self.nodes + 1
end
function Fn:jump(label) self:emit('jump', {NEXT=label}) end
function Fn:slot(p)
    key(p.T, self.fn)
    if p.pk == 'param' then return assert(self.params[p.name], 'direct: missing parameter') end
    if p.pk == 'field' or p.pk == 'deref' or p.pk == 'index' then
        fail(self.fn, 'unsupported place ' .. p.pk)
    end
    local at = self.slots[p]
    if not at then
        local d = self.layout:of(p.T)
        at = self:allocate(math.max(8, d.size), math.max(8, d.align)); self.slots[p] = at
    end
    return at
end
function Fn:temporary(t)
    local p = {pk='temp', T=t}; self:slot(p); return p
end
function Fn:push()
    if self.depth >= 11 then
        local slot = self.depth - 11
        self:emit('spill', {OVERFLOW=slot})
        self.overflow = math.max(self.overflow, slot + 1)
    end
    self.depth = self.depth + 1
end
function Fn:pop()
    assert(self.depth > 0, 'direct: empty operand stack')
    self.depth = self.depth - 1
    if self.depth >= 11 then self:emit('refill', {OVERFLOW=self.depth - 11}) end
end
function Fn:push_f()
    if self.fdepth >= 8 then
        local slot = self.fdepth - 8
        self:emit('spill_f', {FOVERFLOW=slot}); self.foverflow = math.max(self.foverflow, slot + 1)
    end
    self.fdepth = self.fdepth + 1
end
function Fn:pop_f()
    assert(self.fdepth > 0, 'direct: empty SIMD operand stack')
    self.fdepth = self.fdepth - 1
    if self.fdepth >= 8 then self:emit('refill_f', {FOVERFLOW=self.fdepth - 8}) end
end
function Fn:push_t(t) if t.kind == 'float' then self:push_f() else self:push() end end
function Fn:pop_t(t) if t.kind == 'float' then self:pop_f() else self:pop() end end
function Fn:branch(yes, no)
    assert(self.depth > 0)
    self.depth = self.depth - 1
    if self.depth >= 11 then
        self:emit('branch_refill', {NEXT=yes, ZERO=no, OVERFLOW=self.depth - 11})
    else self:emit('branch', {NEXT=yes, ZERO=no}) end
end
function Fn:literal(t, value)
    if t.kind == 'atomic' then t = t.elem end
    local k = key(t, self.fn)
    local bits
    if t.kind == 'float' then
        local scalar = ffi.new(t.cname .. '[1]', value)
        bits = ffi.new('uint64_t[1]'); ffi.copy(bits, scalar, ffi.sizeof(scalar))
        self:push_f(); self:emit('literal_' .. k, {LITERAL=ffi.string(bits, 8)}); return
    end
    if t.kind == 'cstr' then
        bits = ffi.new('uint64_t[1]', ffi.cast('uintptr_t', ffi.cast('const char *', value)))
        self:push(); self:emit('literal', {LITERAL=ffi.string(bits, 8), KEEP=value}); return
    end
    if k == 'bool' then bits = ffi.new('uint64_t[1]', value and 1 or 0)
    else
        local v = ffi.new(t.cname .. '[1]', value)[0]
        -- Convert through the signed source representation, not a Lua double
        -- for a wide integer. This retains every bit of U64/I64 constants.
        if t.signed then v = ffi.cast('int64_t', v) end
        bits = ffi.new('uint64_t[1]', ffi.cast('uint64_t', v))
    end
    self:push(); self:emit('literal', {LITERAL=ffi.string(bits, 8)})
end
function Fn:memory(p) return p.pk == 'deref' or p.pk == 'index' or p.pk == 'field' end
function Fn:address(p)
    if p.pk == 'deref' then self:expr(raw(p, 'ptr'))
    elseif p.pk == 'index' then
        self:expr(raw(p, 'base')); self:expr(raw(p, 'idx'))
        local size = self.layout:of(p.T).size
        self:literal(types.U64, size); self:emit('bin_mul_u64'); self:pop()
        self:emit('bin_add_u64'); self:pop()
    elseif p.pk == 'field' then
        local parent = raw(p, 'parent')
        self:address(parent); self:add_offset(self.layout:member(parent.T, raw(p, 'fname')))
    else self:push(); self:emit('address', {OFFSET=self:slot(p)}) end
end
function Fn:add_offset(n)
    if n ~= 0 then self:literal(types.U64, n); self:emit('bin_add_u64'); self:pop() end
end
function Fn:copy_bytes(bytes, reversed)
    self:emit(reversed and 'copy_reversed' or 'copy', {IMM=bytes})
    self:emit('drop'); self:pop(); self:emit('drop'); self:pop()
end
function Fn:read_address(t)
    if key(t, self.fn) == 'blob' then return end
    if t.kind == 'float' then self:push_f() end
    self:emit('read_' .. key(t, self.fn))
    if t.kind == 'float' then self:pop() end
end
function Fn:load(p)
    if key(p.T, self.fn) == 'blob' then
        local snapshot = self:temporary(p.T)
        self:offset_address(self:slot(snapshot)); self:address(p)
        self:copy_bytes(self.layout:of(p.T).size)
        self:offset_address(self:slot(snapshot))
    elseif self:memory(p) then
        self:address(p)
        if p.T.kind == 'float' then self:push_f() end
        self:emit('read_' .. key(p.T, self.fn))
        if p.T.kind == 'float' then self:pop() end
    else self:push_t(p.T); self:emit('load_' .. key(p.T, self.fn), {OFFSET=self:slot(p)}) end
end
function Fn:store(p)
    assert(not self:memory(p), 'direct: memory store requires its prepared address')
    if key(p.T, self.fn) == 'blob' then
        self:offset_address(self:slot(p)); self:copy_bytes(self.layout:of(p.T).size, true)
    else self:emit('store_' .. key(p.T, self.fn), {OFFSET=self:slot(p)}); self:pop_t(p.T) end
end
function Fn:assign(p, e)
    if self:memory(p) then
        self:address(p); self:expr(e)
        if key(p.T, self.fn) == 'blob' then self:copy_bytes(self.layout:of(p.T).size)
        else
            self:emit('write_' .. key(p.T, self.fn)); self:pop_t(p.T)
            self:emit('drop'); self:pop()
        end
    else self:expr(e); self:store(p) end
end
function Fn:allocate(bytes, alignment)
    alignment = alignment or 8
    local at = math.floor((self.bytes + alignment - 1) / alignment) * alignment
    self.bytes = at + bytes; return at
end
function Fn:at(t, offset)
    local p = {pk='temp', T=t}; self.slots[p] = offset; return p
end
function Fn:offset_address(offset)
    self:push(); self:emit('address', {OFFSET=offset})
end
function Fn:link_literal(fields)
    self:push(); self:emit('literal', fields)
end
local function abi_type(e)
    if e.op == 'vaconv' then
        local ts = {int=types.I32, uint=types.U32, llong=types.I64, ullong=types.U64, double=types.F64}
        return assert(ts[e.abi], 'direct: unsupported variadic promotion')
    end
    return e.T
end
function Fn:user_address(offset)
    self:push(); self:emit('user'); self:add_offset(offset)
end
function Fn:native_inputs()
    local layout = self.layout:signature(self.fn.params, self.fn.ret)
    self.native_signature = layout
    if key(self.fn.ret, self.fn) == 'blob' then
        if layout.hidden then
            self:user_address(ffi.offsetof('cp_call_image', 'ret_gpr'))
            self:user_address(ffi.offsetof('cp_call_image', 'gpr')); self:copy_bytes(8)
            self:user_address(ffi.offsetof('cp_call_image', 'gpr')); self:emit('read_u64')
        else
            self.native_result = self:temporary(self.fn.ret)
            self:offset_address(self:slot(self.native_result))
        end
        self:emit('set_result'); self:pop()
    end
    for i, p in ipairs(self.fn.params) do
        local where = layout[i]
        if where.stack ~= nil then
            self:offset_address(self.params[p.name])
            self:user_address(ffi.offsetof('cp_call_image', 'stack_data')); self:emit('read_u64'); self:add_offset(where.stack)
            self:copy_bytes(where.type.size)
        else
            for _, part in ipairs(where.parts) do
                self:offset_address(self.params[p.name] + part.source)
                self:user_address(ffi.offsetof('cp_call_image', part.field) + part.offset)
                self:copy_bytes(part.bytes)
            end
        end
    end
end
function Fn:init_stacks()
    if not self.fn.needs_gs then return end
    if not self.fn.gs or self.fn.task then self:literal(types.U64, 0); self:store(self.gs_slot) end
    self.gs_tops = {}
    for k = 0, (self.fn.gs_count or 0) - 1 do
        local top = self:temporary(types.U64); self.gs_tops[k + 1] = top
        self:call({op='call', ext={cname='slc_gs_top'}, T=types.U64,
            args={{op='stack_index', offset=k, T=types.U64}}})
        self:store(top)
    end
end
function Fn:native_outputs()
    if not self.native_result then return end
    self.native_finish = #self.nodes + 1
    for _, part in ipairs(self.native_signature.returns) do
        self:user_address(ffi.offsetof('cp_call_image', part.field) + part.offset)
        self:offset_address(self:slot(self.native_result) + part.source); self:copy_bytes(part.bytes)
    end
    self:emit('ret_unit')
end
function Fn:call(e)
    if e.ext and e.ext.variable then
        assert(#(e.args or {})==0,'direct: a native variable takes no arguments')
        local proof=self.layout.meta.proof
        local constant=proof.constants[e.ext.cname]
        if constant~=nil then
            if key(e.T,self.fn)=='bool' then constant=constant~=0 end
            self:literal(e.T,constant)
        else
            local getter=assert(proof.globals[e.ext.cname],
                'direct: prebuilt variable/macro metadata required for '..e.ext.cname)
            self:load({pk='deref',T=e.T,ptr={op='call',ext={cname=getter},args={},T=types.ptr(e.T)}})
        end
        return
    end
    local args = e.args or {}
    if e.ext and e.ext.variadic then
        local promoted = {}
        for i, a in ipairs(args) do
            local target
            if i > #e.ext.params then
                if a.T.kind == 'float' and a.T.bits == 32 then target = types.F64
                elseif a.T.kind == 'bool' or (a.T.kind == 'int' and a.T.bits < 32) then target = types.I32 end
            end
            promoted[i] = target and {op='conv', T=target, e=a} or a
        end
        args = promoted
    end
    local result = self:temporary(e.T.kind == 'unit' and types.U64 or e.T)
    if e.fn then
        if e.fn.task then fail(self.fn, 'task call frame not yet supported') end
        local homes = self.layout:params(e.fn.params)
        assert(#homes == #args, 'direct: internal call arity')
        local arg_bytes = homes.bytes + (e.fn.gs and 8 or 0)
        local packet = self:allocate(arg_bytes, 16)
        for i, a in ipairs(args) do self:expr(a); self:store(self:at(e.fn.params[i].T, packet + homes[i].offset)) end
        if e.fn.gs then
            self:load(assert(self.gs_slot, 'direct: missing data-stack base')); self:add_offset(e.gs_off or 0)
            self:store(self:at(types.U64, packet + homes.bytes))
        end
        local base = self:allocate(ffi.sizeof('cp_vm_call'))
        local function field(name) return self:at(types.U64, base + ffi.offsetof('cp_vm_call', name)) end
        self:link_literal({ENTRY=e.fn}); self:store(field('entry'))
        self:link_literal({FRAME=e.fn}); self:store(field('frame_bytes'))
        self:offset_address(packet); self:store(field('args'))
        self:literal(types.U64, arg_bytes); self:store(field('arg_bytes'))
        self:offset_address(self:slot(result)); self:store(field('result'))
        self:emit('invoke_vm', {OFFSET=base})
    else
        if e.ext and e.ext.variable then fail(self.fn, 'foreign variable accessor not yet supported') end
        local abi_params = {}; for i, a in ipairs(args) do abi_params[i] = {T=abi_type(a)} end
        local layout = self.layout:signature(abi_params, e.T)
        local base = self:allocate(ffi.sizeof('cp_call_image'), 16)
        local stack = self:allocate(layout.stack_bytes, 16)
        local function field(name) return self:at(types.U64, base + ffi.offsetof('cp_call_image', name)) end
        self:emit('prepare_call', {OFFSET=base})
        if e.op == 'calli' then self:expr(e.a)
        else
            local name = e.ext and e.ext.cname or e.cname
            if not name then fail(self.fn, 'native call has no symbol') end
            self:link_literal({SYMBOL=name})
        end
        self:store(field('target'))
        self:offset_address(stack); self:store(field('stack_data'))
        self:literal(types.U64, layout.stack_bytes); self:store(field('stack_size'))
        self:literal(types.U8, layout.nf)
        self:store(self:at(types.U8, base + ffi.offsetof('cp_call_image', 'vector_count')))
        if layout.hidden then
            self:offset_address(self:slot(result)); self:store(field('gpr'))
        end
        for i, a in ipairs(args) do
            self:expr(a)
            local where = layout[i]
            if key(where.T, self.fn) == 'blob' then
                local pointer = self:temporary(types.U64); self:store(pointer)
                if where.stack ~= nil then
                    self:offset_address(stack + where.stack); self:load(pointer); self:copy_bytes(where.type.size)
                else
                    for _, part in ipairs(where.parts) do
                        self:offset_address(base + ffi.offsetof('cp_call_image', part.field) + part.offset)
                        self:load(pointer); self:add_offset(part.source); self:copy_bytes(part.bytes)
                    end
                end
            else
                local part = where.parts[1]
                local at = where.stack ~= nil and (stack + where.stack)
                    or (base + ffi.offsetof('cp_call_image', part.field) + part.offset)
                self:store(self:at(where.T.kind == 'float' and where.T or types.U64, at))
            end
        end
        self:emit('invoke_native', {OFFSET=base})
        if key(e.T, self.fn) == 'blob' then
            if not layout.hidden then
                for _, part in ipairs(layout.returns) do
                    self:offset_address(self:slot(result) + part.source)
                    self:offset_address(base + ffi.offsetof('cp_call_image', part.field) + part.offset)
                    self:copy_bytes(part.bytes)
                end
            end
        elseif e.T.kind ~= 'unit' then
            local field = e.T.kind == 'float' and 'ret_xmm' or 'ret_gpr'
            self:load(self:at(e.T, base + ffi.offsetof('cp_call_image', field))); self:store(result)
        end
    end
    if e.T.kind ~= 'unit' then self:load(result) end
end
function Fn:convert(from, to)
    local crossing = (from.kind == 'float') ~= (to.kind == 'float')
    if crossing then self:push_t(to) end
    self:emit('conv_' .. key(from, self.fn) .. '_' .. key(to, self.fn))
    if crossing then self:pop_t(from) end
end
function Fn:runtime_call(e)
    local signature = self.layout.meta:function_type(e.cname)
    assert(#signature.params == #e.args, 'direct: runtime call arity mismatch')
    local function aggregate_type(t, native)
        local have, want = self.layout:of(t), self.layout:c_type(native)
        assert(have.size == want.size and have.align == want.align
            and table.concat(Layout.classify(have), ',') == table.concat(Layout.classify(want), ','),
            'direct: runtime aggregate ABI mismatch')
    end
    local args = {}
    for i, a in ipairs(e.args) do
        local target = RuntimeMeta.scalar(signature.params[i])
        if target then
            if not a.T then a = setmetatable({T=target}, {__index=a}) end
            args[i] = key(a.T, self.fn) == key(target, self.fn) and a or {op='conv', T=target, a=a}
        else aggregate_type(a.T, signature.params[i]); args[i] = a end
    end
    local ret = RuntimeMeta.scalar(signature.ret)
    if not ret then aggregate_type(e.T, signature.ret); ret = e.T end
    self:call({op='call', ext={cname=e.cname}, args=args, T=ret})
    if e.T.kind == 'unit' then
        if ret.kind ~= 'unit' then self:emit(ret.kind == 'float' and 'drop_f' or 'drop'); self:pop_t(ret) end
    elseif key(ret, self.fn) ~= key(e.T, self.fn) then self:convert(ret, e.T) end
end
function M.task_homes(fn, layout)
    local proof = layout.meta.proof.records
    local ops = proof.slc_task.size
    local base = math.ceil((ops + (fn.waits or 0) * proof.slc_op.size) / 16) * 16
    local homes = layout:params(fn.params)
    for _,home in ipairs(homes) do home.offset = home.offset + base end
    homes.bytes = homes.bytes + base
    return homes, ops
end
function Fn:task_expression() return {op='task', T=types.ptr(types.opaque('slc_task'))} end
function Fn:step_return(name)
    self:literal(types.I32, assert(self.layout.meta.proof.constants[name]))
    self:emit('ret_i32'); self.depth, self.fdepth = 0, 0
end
function Fn:frame_entry()
    self:user_address(ffi.offsetof('cp_call_image','gpr')); self:emit('read_u64')
    self:emit('set_locals'); self:pop()
end
function Fn:wait(s)
    local resume, suspend = self:label(), self:label()
    if s.yield then
        assert(self.fn.task, 'direct: yield outside a task')
        self:runtime_call({cname='slc_budget', args={self:task_expression()}, T=types.I32})
    else
        local args={}
        local block
        if s.body then
            block={body=s.body}; self.blocks[#self.blocks+1]=block
        end
        for i,a in ipairs(s.args) do
            if a.op=='block_fn' then args[i]={op='fnaddr',fn=assert(block),T=types.ptr(types.opaque('void'))}
            elseif a.op=='block_env' then args[i]={op='frame_address',T=types.ptr(types.opaque('void'))}
            else args[i]=a end
        end
        self:runtime_call({cname=s.callee.cname,args=args,T=types.I32})
        self:literal(types.I32,assert(self.layout.meta.proof.constants.SLC_PENDING))
        self:emit('cmp_eq_i32'); self:pop()
    end
    self:branch(suspend,resume); self:bind(suspend)
    if self.fn.task then
        local state=#self.resumes+1; self.resumes[state]=resume
        self:literal(types.U32,state)
        self:store(self:at(types.U32,self.layout.meta.proof.records.slc_task.fields.state.offset))
        self:step_return(s.yield and 'SLC_YIELD' or 'SLC_WAIT')
    else self:runtime_call({cname='slc_block',args={self:task_expression()},T=types.Unit}) end
    self:bind(resume)
    if s.result then
        self:expr(self:task_expression())
        self:add_offset(self.layout.meta.proof.records.slc_task.fields.result.offset)
        self:emit('read_i32'); self:store(s.result)
    end
end
function Fn:spawn(s)
    local target=s.task
    local pointer=types.ptr(types.opaque('void'))
    self:runtime_call({cname='slc_spawn',T=pointer,args={s.args[1],
        {op='frame_size',fn=target,T=types.U64},{op='fnaddr',fn=target,T=pointer}}})
    local frame=self:temporary(pointer); self:store(frame)
    local homes=M.task_homes(target,self.layout)
    for i,p in ipairs(target.params) do
        self:load(frame); self:add_offset(homes[i].offset)
        self:expr(s.args[i+1])
        if key(p.T,self.fn)=='blob' then self:copy_bytes(self.layout:of(p.T).size)
        else
            self:emit('write_'..key(p.T,self.fn)); self:pop_t(p.T)
            self:emit('drop'); self:pop()
        end
    end
    self:runtime_call({cname='slc_start',args={self:read(frame)},T=types.Unit})
end
function Fn:construct(e)
    local value = self:temporary(e.T)
    local base = self:slot(value)
    self:offset_address(base); self:emit('zero_memory', {IMM=self.layout:of(e.T).size})
    self:emit('drop'); self:pop()
    local function put(at, child)
        self:expr(child); self:store(self:at(child.T, base + at))
    end
    if e.op == 'agg' then
        local t = e.T.native_layout and e.T.native_layout() or e.T.representation or e.T
        for _, f in ipairs(t.fields) do put(self.layout:member(e.T, f.name), e.fields[f.name]) end
    elseif e.op == 'array' then
        local layout, indices = self.layout:of(e.T), {}
        for i in pairs(e.fields) do indices[#indices + 1] = i end
        table.sort(indices)
        for _, i in ipairs(indices) do put(layout.array_offset + i * layout.array.size, e.fields[i]) end
    elseif e.op == 'sum' then
        local tag
        for _, a in ipairs(e.T.alts) do if a.name == e.alt then tag = a.tag end end
        assert(tag, 'direct: missing sum alternative')
        put(self.layout:member(e.T, 'tag'), {op='const', T=types.U32, v=tag})
        if e.e then put(self.layout:member(e.T, 'as.' .. e.alt), e.e) end
    end
    self:offset_address(base)
end
function Fn:expr(e)
    local op = e.op
    if op == 'const' then self:literal(e.T, e.v)
    elseif op == 'zero' then
        if key(e.T, self.fn) == 'blob' then self:construct(e)
        else
            local value = 0; if key(e.T, self.fn) == 'bool' then value = false end
            self:literal(e.T, value)
        end
    elseif op == 'agg' or op == 'array' or op == 'sum' then self:construct(e)
    elseif op == 'field' then
        if e.a.T and e.a.T.kind == 'array' and e.name == 'e' then
            -- This IR form denotes C array-to-pointer decay, not an aggregate
            -- value read. Preserve the original address for mutable views.
            if e.a.op == 'read' then self:address(e.a.place)
            elseif e.a.op == 'param' then self:offset_address(assert(self.params[e.a.name]))
            else self:expr(e.a) end
            self:add_offset(self.layout:of(e.a.T).array_offset)
        else
            self:expr(e.a); self:add_offset(self.layout:expression_field(e))
            if e.T then self:read_address(e.T) end
        end
    elseif op == 'array_index' then
        local layout = self.layout:of(e.a.T)
        self:expr(e.a); self:add_offset(layout.array_offset); self:expr(e.idx)
        self:literal(types.U64, layout.array.size); self:emit('bin_mul_u64'); self:pop()
        self:emit('bin_add_u64'); self:pop(); self:read_address(e.T)
    elseif op == 'sizeof' then self:literal(e.T, self.layout:of(e.sizeof).size)
    elseif op == 'tagname' then
        local tag; for _, a in ipairs(e.sum.alts) do if a.name == e.alt then tag = a.tag end end
        assert(tag, 'direct: missing sum tag'); self:literal(e.T, tag)
    elseif op == 'param' then
        self:load(self:at(e.T, assert(self.params[e.name])))
    elseif op == 'read' then self:load(e.place)
    elseif op == 'addr' then self:address(e.place)
    elseif op == 'null' then self:literal(types.U64, 0)
    elseif op == 'call' or op == 'calli' then self:call(e)
    elseif op == 'rtcall' then self:runtime_call(e)
    elseif op == 'atomic' then
        local element = e.ptr.T.elem.elem
        self:expr(e.ptr)
        for _, a in ipairs(e.args or {}) do self:expr(a) end
        if e.o == 'cas' then
            local failure = e.order == '__ATOMIC_RELEASE' and '__ATOMIC_RELAXED'
                or e.order == '__ATOMIC_ACQ_REL' and '__ATOMIC_ACQUIRE' or e.order
            assert(e.fail_order == failure, 'direct: unsupported CAS failure order')
            self:address(e.expected_place)
        end
        self:emit('atomic_' .. e.o .. '_' .. key(element, self.fn) .. '_' .. e.order:gsub('^__ATOMIC_', ''))
        if e.o ~= 'load' then self:pop() end
        if e.o == 'store' or e.o == 'cas' then self:emit('drop'); self:pop() end
    elseif op == 'fnaddr' then self:link_literal({FUNCTION=e.fn})
    elseif op == 'task' then
        if self.fn.task then self:offset_address(0)
        else self:load(assert(self.self_slot, 'direct: missing waiting party')) end
    elseif op == 'ops' then self:offset_address(assert(self.ops_offset, 'direct: missing operation records'))
    elseif op == 'frame_address' then self:offset_address(0)
    elseif op == 'frame_size' then self:link_literal({FRAME=e.fn})
    elseif op == 'slot_at' then
        self:runtime_call({cname='slc_slot_at',args={self:task_expression(),e.slot},T=e.T})
    elseif op == 'stack_index' then
        self:load(assert(self.gs_slot, 'direct: missing data-stack base')); self:add_offset(e.offset or 0)
    elseif op == 'gaddr' then
        local g, name = e.global, S.global_cname(e.global)
        if g.imported and g.tls then
            local getter = assert(self.layout.meta.proof.globals[name], 'direct: prebuilt TLS accessor required for ' .. name)
            self:call({op='call', ext={cname=getter}, args={}, T=e.T})
        elseif g.imported then self:link_literal({SYMBOL=name})
        elseif g.exported then fail(self.fn, 'exported C global definitions require a prebuilt object')
        elseif g.tls then
            self:call({op='call',ext={cname='cp_tls_get'},T=e.T,args={
                {op='tls_descriptor',T=types.ptr(types.opaque('void'))}, {op='tls_offset',global=g,T=types.U64}}})
            local value=self:temporary(e.T); self:store(value)
            self:load(value); self:literal(types.U64,0); self:emit('cmp_ne_u64'); self:pop()
            local valid,failed=self:label(),self:label(); self:branch(valid,failed); self:bind(failed)
            self:call({op='call',ext={cname='slc_trap'},T=types.Unit,args={
                {op='const',T=types.CString,v='out of memory for native TLS'}}})
            self:emit('unreachable'); self:bind(valid); self:load(value)
        else self:link_literal({GLOBAL=g}) end
    elseif op == 'tls_descriptor' then self:link_literal({TLS_DESCRIPTOR=true})
    elseif op == 'tls_offset' then self:link_literal({TLS_GLOBAL=e.global})
    elseif op == 'cconst' then
        local value = self.layout.meta.proof.constants[e.cconst]
        assert(value ~= nil, 'direct: prebuilt constant metadata required for ' .. e.cconst)
        if e.T.kind == 'bool' then value = value ~= 0 end
        self:literal(e.T, value)
    elseif op == 'bin' then
        self:expr(e.a); self:expr(e.b)
        self:emit('bin_' .. e.o .. '_' .. key(e.T, self.fn)); self:pop_t(e.T)
    elseif op == 'cmp' then
        self:expr(e.a); self:expr(e.b)
        if e.a.T.kind == 'float' then self:push() end
        self:emit('cmp_' .. e.o .. '_' .. key(e.a.T, self.fn))
        if e.a.T.kind == 'float' then
            self:pop_f(); self:emit('drop_f'); self:pop_f()
        else self:pop() end
    elseif op == 'un' then
        self:expr(e.a)
        local crossing = e.o == 'not' and e.a.T.kind == 'float'
        if crossing then self:push() end
        self:emit('un_' .. e.o .. '_' .. key(e.a.T, self.fn))
        if crossing then self:pop_f() end
    elseif op == 'conv' or op == 'vaconv' then
        local a, dst = e.e or e.a, abi_type(e)
        self:expr(a)
        self:convert(a.T, dst)
    elseif op == 'and' or op == 'or' then
        local base = self.depth
        local rhs, constant, done = self:label(), self:label(), self:label()
        self:expr(e.a)
        if op == 'and' then self:branch(rhs, constant) else self:branch(constant, rhs) end
        self:bind(rhs); self:expr(e.b); self:jump(done)
        assert(self.depth == base + 1)
        self.depth = base; self:bind(constant); self:literal(types.Bool, op == 'or')
        self:bind(done)
    else fail(self.fn, 'unsupported expression ' .. tostring(op)) end
end
function Fn:condition(e, yes, no) self:expr(e); self:branch(yes, no) end
function Fn:read(p) return {op='read', T=p.T, place=p} end
function Fn:numeric_for(s)
    local t, step = s.T, s.step
    key(t, self.fn)
    assert(type(step) == 'number' and step ~= 0, 'direct: invalid loop step')
    local hi = self:temporary(t)
    self:expr(s.lo); self:store(s.iv)
    self:expr(s.hi); self:store(hi)
    local body, done = self:label(), self:label()
    self:condition({op='cmp', o=step > 0 and 'le' or 'ge', T=types.Bool,
        a=self:read(s.iv), b=self:read(hi)}, body, done)
    self:bind(body)
    self.loops[#self.loops + 1] = done; self:block(s.body); self.loops[#self.loops] = nil
    local more = self:label()
    if math.abs(step) == 1 then
        self:condition({op='cmp', o='eq', T=types.Bool, a=self:read(s.iv), b=self:read(hi)}, done, more)
    else
        local ut = types['U' .. t.bits]
        local a = {op='conv', T=ut, e=self:read(step > 0 and hi or s.iv)}
        local b = {op='conv', T=ut, e=self:read(step > 0 and s.iv or hi)}
        self:condition({op='cmp', o='lt', T=types.Bool, a={op='bin', o='sub', T=ut, a=a, b=b},
            b={op='const', T=ut, v=math.abs(step)}}, done, more)
    end
    self:bind(more)
    self:expr({op='bin', o=step > 0 and 'add' or 'sub', T=t, a=self:read(s.iv),
        b={op='const', T=t, v=math.abs(step)}})
    self:store(s.iv); self:jump(body); self:bind(done)
end
function Fn:block(block)
    for _, s in ipairs(block) do
        assert(self.depth == 0 and self.fdepth == 0, 'direct: statement begins with live operands')
        local op = s.op
        if op == 'store' or op == 'let' then self:assign(s.place, s.e)
        elseif op == 'expr' then
            self:expr(s.e)
            if s.e.T.kind ~= 'unit' then
                self:emit(s.e.T.kind == 'float' and 'drop_f' or 'drop'); self:pop_t(s.e.T)
            end
        elseif op == 'ret' then
            if self.blocking_mode then self:emit('ret_unit')
            elseif self.fn.task then self:step_return('SLC_DONE')
            else
                if s.e then self:expr(s.e) end
                self:emit('ret_' .. key(self.fn.ret, self.fn), {IMM=self.layout:of(self.fn.ret).size})
            end
            self.depth, self.fdepth = 0, 0
        elseif op == 'wait' then self:wait(s)
        elseif op == 'spawn' then self:spawn(s)
        elseif op == 'fence' then self:emit('fence_' .. s.order:gsub('^__ATOMIC_', ''))
        elseif op == 'if' then
            local yes, no, done = self:label(), self:label(), self:label()
            self:condition(s.c, yes, no)
            self:bind(yes); self:block(s.a); self:jump(done)
            self:bind(no); self:block(s.b); self:bind(done)
        elseif op == 'loop' then
            local top, done = s.top or self:label(), s.ends or self:label()
            self:bind(top); self.loops[#self.loops + 1] = done
            self:block(s.body); self.loops[#self.loops] = nil
            self:jump(top); self:bind(done)
        elseif op == 'for' then self:numeric_for(s)
        elseif op == 'break' then self:jump(assert(self.loops[#self.loops], 'direct: break outside loop'))
        elseif op == 'goto' then self:jump(s.label)
        elseif op == 'label' then self:bind(s.label)
        elseif op == 'setparam' then
            self:expr(s.e); self:store(self:at(s.e.T, assert(self.params[s.name])))
        elseif op == 'gs_reset' then
            self:call({op='call', ext={cname='slc_gs_reset'}, T=types.Unit, args={
                {op='stack_index', offset=s.k, T=types.U64},
                self:read(assert(self.gs_tops[s.k + 1], 'direct: missing data-stack watermark'))}})
        elseif op == 'trap' then
            self:call({op='call', ext={cname='slc_trap', params={types.CString}}, args={s.msg}, T=types.Unit})
            self:emit('unreachable')
        elseif op ~= 'nop' then fail(self.fn, 'unsupported statement ' .. tostring(op)) end
        assert(self.depth == 0 and self.fdepth == 0, 'direct: statement leaves live operands')
    end
end
function M.plan(fn, pack, layout)
    key(fn.ret, fn)
    local self = setmetatable({fn=fn, pack=pack, nodes={}, labels={}, params={}, slots={},
        bytes=0, depth=0, fdepth=0, overflow=0, foverflow=0, loops={}, blocks={}, resumes={}, layout=layout or Layout.new()}, Fn)
    local homes
    if fn.task then homes,self.ops_offset=M.task_homes(fn,self.layout)
    else homes=self.layout:params(fn.params) end
    for i, p in ipairs(fn.params) do key(p.T, fn); self.params[p.name] = homes[i].offset end
    self.bytes, self.arg_bytes = homes.bytes, homes.bytes
    if fn.needs_gs then
        self.gs_slot = self:temporary(types.U64)
        if fn.gs and not fn.task then self.arg_bytes = self.bytes end
    end
    if not fn.task then
        if fn.waits then self.ops_offset=self:allocate(fn.waits*self.layout.meta.proof.records.slc_op.size,8) end
        if fn.waits or fn.needs_self then self.self_slot=self:temporary(types.ptr(types.opaque('void'))) end
    end
    self.native_entry = 1
    local dispatch,start=self:label(),self:label()
    if fn.task then self:frame_entry(); self:jump(dispatch)
    else
        self:native_inputs()
        if fn.gs then self:literal(types.U64, 0); self:store(self.gs_slot) end
    end
    self.body_entry = #self.nodes + 1; self:bind(start)
    if self.self_slot then
        self:runtime_call({cname='slc_self',args={},T=self.self_slot.T}); self:store(self.self_slot)
    end
    self:init_stacks()
    self:block(fn.body)
    if fn.task then
        self:step_return('SLC_DONE')
        self:bind(dispatch)
        for state,resume in ipairs(self.resumes) do
            self:load(self:at(types.U32,self.layout.meta.proof.records.slc_task.fields.state.offset))
            self:literal(types.U32,state); self:emit('cmp_eq_u32'); self:pop()
            local next_state=self:label(); self:branch(resume,next_state); self:bind(next_state)
        end
        self:jump(start)
    else
        self:emit('ret_unit'); self:native_outputs()
    end
    for _,block in ipairs(self.blocks) do
        block.native_entry=#self.nodes+1
        self:frame_entry(); self.blocking_mode=true
        self:block(block.body); self:emit('ret_unit'); self.blocking_mode=false
        block.last_node=#self.nodes
    end
    local fbase = math.floor((self.bytes + self.overflow * 8 + 15) / 16) * 16
    for i, node in ipairs(self.nodes) do
        if node.OVERFLOW ~= nil then node.OFFSET = self.bytes + node.OVERFLOW * 8 end
        if node.FOVERFLOW ~= nil then node.OFFSET = fbase + node.FOVERFLOW * 16 end
        if node.NEXT == nil then node.NEXT = i + 1 end
        for _, edge in ipairs {'NEXT', 'ZERO'} do
            local v = node[edge]
            if v ~= nil and type(v) ~= 'number' then
                node[edge] = assert(self.labels[v], 'direct: unbound label')
            end
        end
    end
    for _,block in ipairs(self.blocks) do
        for i=block.native_entry,block.last_node do
            local node=self.nodes[i]
            if node.op~='cp_ret_unit' and node.op~='cp_unreachable' then
                for _,edge in ipairs{'NEXT','ZERO'} do
                    local target=node[edge]
                    assert(not target or (target>=block.native_entry and target<=block.last_node),
                        'direct: control flow escapes a blocking callback')
                end
            end
        end
    end
    self.frame_bytes = fbase + self.foverflow * 16
    assert(self.frame_bytes <= 2147483647, 'direct: frame exceeds offset range')
    return self
end
return M
