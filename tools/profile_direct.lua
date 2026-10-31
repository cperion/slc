-- Flat-PC profiling of generated code; outputs stay under build/direct.
-- perf script IPs can be joined with the emitted regions without /tmp perf maps.
local arguments=arg
package.loaded['slc.driver_loaded']=true
arg={[0]='slc.lua'}
local slc=dofile('slc.lua')
arg=arguments
local ffi=require 'ffi'
ffi.cdef [[struct timespec {long tv_sec; long tv_nsec;}; int clock_gettime(int,struct timespec *); int usleep(unsigned int);]]
local backend,path,name,n,prefix=arg[1],arg[2],arg[3],assert(tonumber(arg[4])),assert(arg[5])
local module=slc.load(path,{backend=backend,opt=2})
if backend=='direct' then
    local unit=module.direct.unit
    local regions=assert(io.open(prefix..'-regions.csv','w'))
    local info=assert(io.open(prefix..'-plans.txt','w'))
    regions:write('start,end,function,stencil,native,imm\n')
    for fn,plan in pairs(module.direct.plans) do
        local base
        for i,node in ipairs(plan.nodes) do
            if node.op~='cp_jump' and not node.op:match('^cp_branch') then
                base=node.NEXT-i-1; break
            end
        end
        assert(base and base>=0)
        local native_targets,counts={},{}
        for i,node in ipairs(plan.nodes) do
            if node.SYMBOL and plan.nodes[i+1] and plan.nodes[i+1].op=='cp_store_u64' then
                native_targets[plan.nodes[i+1].OFFSET-ffi.offsetof('cp_call_image','target')]=node.SYMBOL
            end
            counts[node.op]=(counts[node.op] or 0)+1
        end
        info:write(('%s nodes=%d frame=%d bytes\n'):format(fn.cname,#plan.nodes,plan.frame_bytes))
        local names={}; for op in pairs(counts) do names[#names+1]=op end; table.sort(names)
        for _,op in ipairs(names) do info:write(('  %s %d\n'):format(op,counts[op])) end
        for i,node in ipairs(plan.nodes) do
            local index=base+i
            local offset=assert(unit.offsets[index])
            local size=math.min(#plan.pack.stencils[node.op].code,(unit.offsets[index+1] or unit.size)-offset)
            local address=tonumber(ffi.cast('uintptr_t',unit.memory+offset))
            if size>0 then
                regions:write(('%x,%x,%s,%s,%s,%s\n'):format(address,address+size,fn.cname,node.op,
                    node.op=='cp_invoke_native' and (native_targets[node.OFFSET] or 'indirect') or '',tostring(node.IMM or '')))
            end
        end
    end
    regions:close(); info:close()
end
local fn=assert(module.raw[name])
local expected=fn(n)
-- perf record -D 2000 excludes compilation; this sleep leaves a margin.
ffi.C.usleep(2500000)
local ts=ffi.new('struct timespec[1]')
local function now()
    assert(ffi.C.clock_gettime(1,ts)==0)
    return tonumber(ts[0].tv_sec)+tonumber(ts[0].tv_nsec)*1e-9
end
local start=now(); local calls=0
repeat
    assert(fn(n)==expected)
    calls=calls+1
until now()-start>=5
local finish=now()
print(('%s %s n=%d calls=%d elapsed=%.6f begin=%.9f end=%.9f result=%s'):format(backend,name,n,calls,finish-start,start,finish,tostring(expected)))
