-- Header metadata for runtime calls and foreign views. This uses the existing
-- declaration reader, never gccjit or a compiler process. Offline C evidence
-- must agree with that reader before any layout is used.
local C = require 'slc.cjit'
local types = require 'slc.types'
local M = {}; M.__index = M
function M.signature(t)
    if t.k == 'fn' then
        local ps={}; for i,p in ipairs(t.params) do ps[i]=M.signature(p) end
        return M.signature(t.ret)..' ('..table.concat(ps,',')..(t.variadic and ',...' or '')..')'
    elseif t.k == 'ptr' then return M.signature(t.to)..'*'
    else return C.show(t) end
end
function M.new(path, runtime_dir)
    local chunk,why=loadfile(path)
    if not chunk then error('direct: prebuilt runtime metadata unavailable; run make direct\n'..tostring(why),0) end
    local proof=chunk()
    assert(proof.abi==1 and proof.target=='linux-x64','direct: incompatible runtime metadata')
    local scope=C.runtime_scope(runtime_dir)
    for name,r in pairs(proof.records) do
        local d=assert(scope:find('types',name),'direct: runtime header changed: '..name)
        assert(C.sizeof(d)==r.size and C.alignof(d)==r.align,'direct: runtime layout mismatch: '..name)
        local count=0; for _ in pairs(r.fields) do count=count+1 end
        assert(count==#d.fields,'direct: runtime fields changed: '..name)
        for _,f in ipairs(d.fields) do
            local actual=assert(r.fields[f[1]],'direct: missing native field evidence')
            assert(actual.offset==C.offsetof(d,f[1]) and actual.size==C.sizeof(f[2]),
                'direct: runtime field layout mismatch: '..name..'.'..f[1])
        end
    end
    for name,signature in pairs(proof.functions) do
        local d=assert(scope:find('names',name),'direct: runtime declaration changed: '..name)
        assert(d.fn and M.signature(d.fn.t)==signature,'direct: runtime signature changed: '..name)
    end
    return setmetatable({scope=scope,proof=proof},M)
end
function M:record(name)
    name=name:gsub('^const%s+',''):gsub('^struct%s+','')
    assert(self.proof.records[name],'direct: foreign layout metadata required for '..name)
    return assert(self.scope:find('types',name)),self.proof.records[name]
end
function M:function_type(name)
    assert(self.proof.functions[name],'direct: runtime signature metadata required for '..name)
    return assert(self.scope:find('names',name)).fn.t
end
function M.scalar(t)
    if t.k=='void' then return types.Unit end
    if t.k=='bool' then return types.Bool end
    if t.k=='int' then return assert(types[(t.signed and 'I' or 'U')..t.size*8]) end
    if t.k=='float' then return assert(types['F'..t.size*8]) end
    if t.k=='ptr' then return types.ptr(types.opaque('void')) end
end
return M
