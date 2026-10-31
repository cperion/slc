-- Run from the repository root, after make direct. No compiler/build time for
-- the prebuilt runtime or stencil pack is charged to either online backend.
local original_arg=arg
package.loaded['slc.driver_loaded']=true
arg={[0]='slc.lua'}
local slc=dofile('slc.lua')
arg=original_arg
local ffi=require 'ffi'
local native=require 'slc.native'
local G=require 'slc.cgen'
ffi.cdef [[struct timespec { long tv_sec; long tv_nsec; }; int clock_gettime(int,struct timespec *);]]
local stamp=ffi.new('struct timespec[1]')
local function now()
    assert(ffi.C.clock_gettime(1,stamp)==0)
    return tonumber(stamp[0].tv_sec)+tonumber(stamp[0].tv_nsec)*1e-9
end
local rounds=tonumber(arg[1]) or 7
assert(rounds>=3 and rounds%2==1,'use an odd sample count >=3')
local csv=assert(io.open('build/direct/benchmark.csv','w'))
csv:write('phase,module,function,backend,round,iterations,seconds_per_iteration\n')
local function row(phase,path,name,backend,r,n,seconds)
    csv:write(('%s,%s,%s,%s,%d,%d,%.12g\n'):format(phase,path,name or '',backend,r,n,seconds))
    csv:flush()
end
local function median(xs)
    table.sort(xs); return xs[math.floor(#xs/2)+1]
end
-- Explicitly warm the shared runtime and load the GCC library outside timings.
native.runtime(); require('slc.cjit').lib()
local cases={
    {path='tests/direct_bench.slc',runs={{'integer_loop',1000000},{'float_loop',1000000}}},
    {path='examples/stores.slc',runs={{'run',10000}}},
    {path='examples/maps.slc',runs={{'map_tally',10000}}},
    {path='examples/channels.slc',runs={{'sum_squares',1000}}},
}
local outputs={}
for _,case in ipairs(cases) do
    local file=assert(io.open(case.path,'rb')); local source=file:read('*a'); file:close()
    local compiled={gccjit={},direct={}}
    local fronts={gccjit={},direct={}}
    local modules={}
    for r=0,rounds do
        local order=r%2==0 and {'gccjit','direct'} or {'direct','gccjit'}
        for _,backend in ipairs(order) do
            collectgarbage('collect')
            local start=now()
            local _,mod=slc.compile(source,case.path,{no_c=true})
            G.prepare(mod)
            local prepared=now()
            local result=native.compile(mod,{backend=backend,opt=2})
            local done=now()
            row(r==0 and 'first_frontend' or 'frontend',case.path,'',backend,r,1,prepared-start)
            row(r==0 and 'first_backend' or 'backend',case.path,'',backend,r,1,done-prepared)
            if r>0 then
                fronts[backend][#fronts[backend]+1]=prepared-start
                compiled[backend][#compiled[backend]+1]=done-prepared
            end
            modules[backend]=result
        end
    end
    local gm,dm=median(compiled.gccjit),median(compiled.direct)
    print(('COMPILE %-26s gccjit=%9.3f ms direct=%9.3f ms speedup=%6.2fx frontend=%7.3f/%7.3f ms')
        :format(case.path,gm*1000,dm*1000,gm/dm,median(fronts.gccjit)*1000,median(fronts.direct)*1000))
    for _,run in ipairs(case.runs) do
        local name,n=run[1],run[2]
        local expected=modules.gccjit.raw[name](n)
        assert(modules.direct.raw[name](n)==expected,'result mismatch: '..name)
        local repetitions,times={}, {gccjit={},direct={}}
        local function batch(backend,count)
            local fn=modules[backend].raw[name]
            local result
            local start=now()
            for _=1,count do result=fn(n) end
            local elapsed=now()-start
            assert(result==expected,'unstable result: '..name)
            return elapsed
        end
        for _,backend in ipairs{'gccjit','direct'} do
            batch(backend,3)
            local count=1
            while true do
                local duration=batch(backend,count)
                if duration>=0.025 or count>=65536 then break end
                count=count*2
            end
            repetitions[backend]=count
        end
        for r=1,rounds do
            local order=r%2==0 and {'gccjit','direct'} or {'direct','gccjit'}
            for _,backend in ipairs(order) do
                collectgarbage('collect')
                local count=repetitions[backend]
                local elapsed=batch(backend,count)/count
                times[backend][r]=elapsed
                row('execute',case.path,name,backend,r,count,elapsed)
            end
        end
        local g,d=median(times.gccjit),median(times.direct)
        print(('EXECUTE %-16s n=%-8d gccjit=%9.3f ms direct=%9.3f ms slowdown=%6.2fx ranges=[%.3f,%.3f]/[%.3f,%.3f] ms')
            :format(name,n,g*1000,d*1000,d/g,times.gccjit[1]*1000,times.gccjit[#times.gccjit]*1000,
                times.direct[1]*1000,times.direct[#times.direct]*1000))
        outputs[#outputs+1]={module=case.path,name=name,gccjit=g,direct=d}
    end
end
csv:close()
print(('All results matched; %d samples per measurement. CSV: build/direct/benchmark.csv'):format(rounds))
