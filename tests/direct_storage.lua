-- Exercise the existing SLC storage algorithms, not a backend-specific copy.
package.loaded['slc.driver_loaded'] = true
arg = {[0]='slc.lua'}
local slc = dofile('slc.lua')
local ffi = require 'ffi'
local checks = 0
local function compare(path, names, failures)
    local baseline = slc.load(path)
    local execute, popen = os.execute, io.popen
    os.execute = function() error('direct storage started a process', 0) end
    io.popen = os.execute
    local ok, actual = pcall(slc.load, path, {backend='direct'})
    os.execute, io.popen = execute, popen
    assert(ok, actual)
    local c=require('tests.direct_support').c_baseline(slc,path,actual,'c-'..path:match('([^/]+)%.slc$'))
    for _,n in ipairs{0,1,2,7,31,100} do
        for _,name in ipairs(names) do
            local expected = baseline[name](n)
            assert(c[name](n) == expected, path..': C '..name)
            assert(actual[name](n) == expected, path..': '..name)
            assert(actual.raw[name](n) == expected, path..': native '..name)
            checks = checks + 3
        end
    end
    for _,name in ipairs(failures or {}) do
        local good, message = pcall(actual[name], 3)
        assert(not good and tostring(message):find('runtime check failed',1,true), tostring(message))
        checks = checks + 1
        assert(actual[names[1]](7) == baseline[names[1]](7), 'storage recovery after trap')
    end
    collectgarbage()
end
compare('examples/stores.slc', {'run','churn','digits','sum_depths'})
compare('examples/maps.slc', {'map_tally','edit_counts','record_keys','sum_keys','id_keys','map_field','map_task_each'}, {'absent'})
ffi.cdef [[int cp_fixture_parallel_bump(void (*entry)(void *,uint32_t),void *,uint32_t,uint32_t);]]
local fixture = ffi.load('build/direct/libdirect_fixture.so')
local atomics = slc.load('examples/atomics.slc', {backend='direct'})
for _,name in ipairs{'bump','add_locked'} do
    local counter = ffi.new('uint64_t[2]')
    local entry = ffi.cast('void (*)(void *,uint32_t)', atomics.raw[name])
    assert(fixture.cp_fixture_parallel_bump(entry,counter,4,1000)==0,'thread creation failed')
    assert(counter[name=='bump' and 0 or 1]==4000,name..': native concurrent updates lost')
    checks = checks + 1
end
print(('direct storage: %d gccjit/direct/native checks plus concurrent atomics passed'):format(checks))
