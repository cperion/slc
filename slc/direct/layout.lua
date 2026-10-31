-- Native SLC type descriptions -> host C layouts. The FFI lays out the same
-- declarations as C, and supplies sizeof/alignof/offsetof. Foreign views require
-- authoritative header metadata; their declared field list is never guessed.
local ffi = require 'ffi'
local G = require 'slc.cgen'
local types = require 'slc.types'
local M = {}; M.__index = M
local serial = 0
local function align(n,a) return math.floor((n+a-1)/a)*a end
local function name()
    serial = serial + 1; return 'slc_direct_type_' .. serial
end
local function finish(d)
    d.size, d.align = ffi.sizeof(d.ctype), ffi.alignof(d.ctype)
    assert(d.align <= 16, 'direct: native alignment above 16 is unsupported')
    return d
end
function M.new(meta) return setmetatable({cache={}, c_cache={}, meta=meta},M) end
function M:c_type(t)
    if self.c_cache[t] then return self.c_cache[t] end
    local d = {}
    if t.k == 'int' then d.kind,d.ctype='int',(t.signed and 'int' or 'uint')..(t.size*8)..'_t'
    elseif t.k == 'float' then d.kind,d.ctype='float',t.size==4 and 'float' or 'double'
    elseif t.k == 'bool' then d.kind,d.ctype='bool','bool'
    elseif t.k == 'ptr' or t.k == 'fn' then d.kind,d.ctype='pointer','void *'
    elseif t.k == 'array' then
        d.kind,d.ctype,d.array,d.length,d.array_offset='array',name(),self:c_type(t.of),t.n,0
        ffi.cdef('typedef '..d.array.ctype..' '..d.ctype..'['..t.n..'];')
    elseif t.k == 'struct' or t.k == 'union' then
        assert(t.fields,'direct: incomplete native record '..tostring(t.name))
        d.kind,d.ctype,d.fields=t.k=='struct' and 'record' or 'union',name(),{}
        self.c_cache[t]=d
        local fields={}
        for _,f in ipairs(t.fields) do
            local ft=self:c_type(f[2])
            fields[#fields+1]=ft.ctype..' '..f[1]..';'
            d.fields[#d.fields+1]={name=f[1],type=ft}
        end
        ffi.cdef('typedef '..t.k..' '..d.ctype..' {'..table.concat(fields)..'} '..d.ctype..';')
        for _,f in ipairs(d.fields) do f.offset=ffi.offsetof(d.ctype,f.name) end
    else error('direct: unsupported C layout '..tostring(t.k),0) end
    finish(d); self.c_cache[t]=d; return d
end
function M:foreign(t)
    assert(self.meta,'direct: foreign layout metadata required for '..tostring(t.display))
    local native, proof=self.meta:record(assert(t.cname))
    local d=self:c_type(native)
    assert(d.size==proof.size and d.align==proof.align,'direct: FFI/native layout mismatch for '..t.cname)
    for _,f in ipairs(d.fields) do
        local p=assert(proof.fields[f.name])
        assert(f.offset==p.offset and f.type.size==p.size,'direct: FFI/native member mismatch for '..t.cname..'.'..f.name)
    end
    self.cache[t]=d
    for _,f in ipairs(t.fields) do
        local _,actual=self:member(t,f.name)
        assert(actual.size==self:of(f.type).size,'direct: foreign view field width mismatch for '..t.cname..'.'..f.name)
    end
    return d
end
function M:of(t)
    if t.kind == 'atomic' then return self:of(t.elem) end
    if t.kind == 'chan' or t.kind == 'pool' or t.kind == 'slot' then
        if self.cache[t] then return self.cache[t] end
        local d = self:foreign({cname=G.ctype(t), fields={}}); self.cache[t]=d; return d
    end
    if t.kind == 'group' then return finish({kind='pointer',ctype='void *'}) end
    local old = self.cache[t]; if old then return old end
    local k = t.kind
    local native = t.native_layout and t.native_layout() or t.representation
    if native then local d=self:of(native); self.cache[t]=d; return d end
    local d = {type=t}
    if k == 'unit' then d.kind, d.ctype, d.size, d.align = 'unit','void',0,1
    elseif k == 'int' or k == 'float' or k == 'bool' then
        d.kind, d.ctype = k, t.cname; finish(d)
    elseif k == 'ptr' or k == 'ref' or k == 'fn' or k == 'cstr' then
        -- Native pointer representation is independent of its referent. Opaque
        -- referents need no fabricated layout merely to cross a C boundary.
        d.kind, d.ctype = 'pointer', k == 'cstr' and 'const char *' or 'void *'; finish(d)
    elseif k == 'struct' or k == 'sum' or k == 'array' then
        if rawget(t,'foreign') then return self:foreign(t) end
        d.kind, d.ctype, d.fields = 'record', name(), {}
        self.cache[t] = d
        ffi.cdef('typedef struct '..d.ctype..' '..d.ctype..';')
        local fields = {}
        local function field(n, ft, suffix)
            fields[#fields+1]=ft.ctype..' '..n..(suffix or '')..';'
            d.fields[#d.fields+1]={name=n,type=ft}
        end
        if k == 'struct' then
            for _, f in ipairs(t.fields) do field(f.name,self:of(f.type)) end
        elseif k == 'array' then
            local elem=self:of(t.elem)
            fields[1]=elem.ctype..' e['..t.length..'];'
            d.array, d.length = elem,t.length
        else
            field('tag',self:of(types.U32))
            local union = {kind='union',ctype=name(),fields={}}
            local members = {}
            for _, a in ipairs(t.alts) do
                if a.type.kind ~= 'unit' then
                    local ft=self:of(a.type)
                    members[#members+1]=ft.ctype..' '..a.name..';'
                    union.fields[#union.fields+1]={name=a.name,type=ft,offset=0}
                end
            end
            if #members>0 then
                ffi.cdef('typedef union '..union.ctype..' {'..table.concat(members)..'} '..union.ctype..';')
                finish(union); field('as',union)
            end
        end
        ffi.cdef('struct '..d.ctype..' {'..table.concat(fields)..'};')
        finish(d)
        for _, f in ipairs(d.fields) do f.offset=ffi.offsetof(d.ctype,f.name) end
        if d.array then d.array_offset=ffi.offsetof(d.ctype,'e') end
        assert(d.size>0, 'direct: zero-sized native aggregates are unsupported')
    else error('direct: unsupported native layout '..tostring(t.display or k),0) end
    self.cache[t]=d; return d
end
function M:member_desc(d, member)
    local offset = 0
    for part in member:gmatch('[^.]+') do
        local found
        for _, f in ipairs(d.fields or {}) do if f.name==part then found=f; break end end
        assert(found,'direct: no native member '..part)
        offset,d=offset+found.offset,found.type
    end
    return offset,d
end
function M:member(t, member) return self:member_desc(self:of(t), G.cfield(t, member)) end
function M:expression(e)
    if e.T then return self:of(e.T) end
    assert(e.op == 'field', 'direct: missing expression layout')
    local _, d = self:expression_field(e); return d
end
function M:expression_field(e)
    return self:member_desc(self:expression(e.a), e.a.T and G.cfield(e.a.T, e.name) or e.name)
end
function M:params(params)
    local layout,bytes={},0
    for i,p in ipairs(params) do
        local d=self:of(p.T)
        bytes=align(bytes,math.max(8,d.align))
        layout[i]={offset=bytes,type=d}
        bytes=bytes+align(math.max(1,d.size),8)
    end
    layout.bytes=bytes; return layout
end
local function classify(d)
    if d.kind=='unit' then return {} end
    if d.size>16 then return {'memory'} end
    local classes={}
    local function merge(at,c)
        local n=math.floor(at/8)+1
        local old=classes[n]
        classes[n]=(old=='integer' or c=='integer') and 'integer' or c
    end
    local function visit(v,offset)
        if offset%v.align~=0 then return false end
        if v.array then
            for i=0,v.length-1 do if not visit(v.array,offset+v.array_offset+i*v.array.size) then return false end end
        elseif v.fields then
            for _,f in ipairs(v.fields) do if not visit(f.type,offset+f.offset) then return false end end
        else
            local c=v.kind=='float' and 'sse' or 'integer'
            for at=offset,offset+v.size-1,8 do merge(at,c) end
        end
        return true
    end
    if not visit(d,0) then return {'memory'} end
    for i=1,math.ceil(d.size/8) do classes[i]=classes[i] or 'none' end
    return classes
end
M.classify = classify
function M:classes(t) return classify(self:of(t)) end
function M:signature(params,ret)
    local rc=self:classes(ret)
    local hidden=rc[1]=='memory'
    local ni,nf,bytes=hidden and 1 or 0,0,0
    local layout={hidden=hidden,returns={},return_type=self:of(ret)}
    local ri,rf=0,0
    if not hidden then
        for i,c in ipairs(rc) do
            if c~='none' then
                local field,index=c=='integer' and 'ret_gpr' or 'ret_xmm',c=='integer' and ri or rf
                layout.returns[#layout.returns+1]={field=field,offset=index*(c=='integer' and 8 or 16),source=(i-1)*8,
                    bytes=math.min(8,layout.return_type.size-(i-1)*8)}
                if c=='integer' then ri=ri+1 else rf=rf+1 end
            end
        end
    end
    for i,p in ipairs(params) do
        local d,classes=self:of(p.T),self:classes(p.T)
        local need_i,need_f=0,0
        for _,c in ipairs(classes) do
            if c=='integer' then need_i=need_i+1 elseif c=='sse' then need_f=need_f+1 end
        end
        local where={T=p.T,type=d,parts={}}
        if classes[1]=='memory' or ni+need_i>6 or nf+need_f>8 then
            bytes=align(bytes,math.max(8,d.align)); where.stack=bytes
            bytes=bytes+align(d.size,8)
        else
            for j,c in ipairs(classes) do
                if c~='none' then
                    local field,index=c=='integer' and 'gpr' or 'xmm',c=='integer' and ni or nf
                    where.parts[#where.parts+1]={field=field,offset=index*(c=='integer' and 8 or 16),source=(j-1)*8,
                        bytes=math.min(8,d.size-(j-1)*8)}
                    if c=='integer' then ni=ni+1 else nf=nf+1 end
                end
            end
        end
        layout[i]=where
    end
    layout.stack_bytes,layout.nf=align(bytes,8),nf
    return layout
end
return M
