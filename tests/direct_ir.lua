-- Differential real-source checks. Baselines may compile; the direct path must
-- use only the explicitly prebuilt pack/bridge, never a subprocess fallback.
local saved_arg = arg
package.loaded['slc.driver_loaded'] = true
arg = {[0]='slc.lua'}
local slc = dofile('slc.lua')
arg = saved_arg
local ffi = require 'ffi'
local native = require 'slc.native'
local direct = require 'slc.direct'
local checks = 0
local function check(ok, what)
    assert(ok, what); checks = checks + 1
end
local function without_processes(body)
    local execute, popen = os.execute, io.popen
    os.execute = function() error('direct started a process', 0) end
    io.popen = os.execute
    local ok, result = pcall(body)
    os.execute, io.popen = execute, popen
    if not ok then error(result, 0) end
    return result
end
ffi.cdef [[void *dlopen(const char *, int); int dlclose(void *); const char *dlerror(void);]]
local c_handles = {}
local function c_baseline(text, path, module, name)
    local code = slc.compile(text, path, {runtime='shared'})
    local cpath, sopath = 'build/direct/'..name..'.c', 'build/direct/'..name..'.so'
    local file = assert(io.open(cpath, 'wb')); file:write(code); file:close()
    local command = ('%s -std=c99 -O2 -fPIC -shared -Wl,-Bsymbolic -Iruntime %q -o %q'):format(os.getenv('CC') or 'cc', cpath, sopath)
    check(os.execute(command) == 0, 'C baseline compilation failed')
    local handle = ffi.C.dlopen(sopath, 2)
    if handle == nil then error(ffi.string(ffi.C.dlerror()), 0) end
    c_handles[#c_handles+1] = handle
    local result = {}
    for name, ptr in pairs(module.raw) do
        local address = ffi.C.dlsym(handle, name)
        assert(address ~= nil, 'C baseline missing '..name)
        result[name] = ffi.cast(ffi.typeof(ptr), address)
    end
    return result
end
local libraries = {'build/direct/libdirect_fixture.so'}
local baseline = slc.load('tests/direct_program.slc', {libs=libraries})
local actual = without_processes(function()
    return slc.load('tests/direct_program.slc', {backend='direct', libs=libraries})
end)
check(actual.backend == 'direct', 'wrong selected backend')
local file = assert(io.open('tests/direct_program.slc', 'rb'))
local original = file:read('*a'); file:close()
local c = c_baseline(original, 'tests/direct_program.slc', actual, 'c-program')
local function same(name, ...)
    local expected = baseline[name](...)
    local got = actual[name](...)
    check(c[name](...) == expected, name .. ': C/gccjit baseline mismatch')
    check(got == expected, name .. ': ' .. tostring(got) .. ' ~= ' .. tostring(expected))
    if actual.raw[name] then
        local raw = actual.raw[name](...)
        check(raw == expected, name .. ' native entry: ' .. tostring(raw) .. ' ~= ' .. tostring(expected))
    end
end
for n=0,100 do
    same('affine', n); same('narrow', n*521, 65535-n)
    same('signed_math', -n*987, n+1); same('converted', -n*101)
    same('choice', n%2==0, n*91, n+1)
    same('triangular', n); same('nested', n); same('descending', n)
    same('snapshots', n)
    same('float_math', n/4, -3.25); same('double_math', n*1.25, n+1)
    same('float_compare', n/7, 8.5); same('float_convert', -n*999)
    same('float_to_int', -n*1.5); same('native_float', n+0.5)
    same('native_varargs', n+0.25, n/8)
    same('native_record', n, n+0.25); same('native_large', n, n+7)
    same('native_rollback', n); same('native_record_callback', n, n+0.25)
    same('native_large_callback', n, n+7); same('recursive_record_callback', n, n/4)
    same('checked', n+1); same('checked_callback', n+1); same('sum_value', n%2==0, n)
end
for _, x in ipairs {0ULL, 18446744073709551615ULL, 9223372036854775808ULL, 6364136223846793005ULL} do
    same('affine', x)
end
for _, a in ipairs {false,true} do
    for _, b in ipairs {false,true} do
        for _, c in ipairs {false,true} do same('logic', a,b,c) end
    end
end
same('edge', 250); same('edge', 255); same('empty', 7)
for n=0,15 do same('fibonacci', n); same('native_sum', n); same('nested_callback', n, n+1) end
local p, q = ffi.new('uint32_t[1]', 42), ffi.new('uint32_t[1]', 42)
check(actual.mutate(p, 7) == baseline.mutate(q, 7) and p[0] == q[0], 'pointer mutation')
p[0], q[0] = 42,42
check(actual.raw.mutate(p, 7) == baseline.mutate(q, 7) and p[0] == q[0], 'native pointer mutation')
local pointer = actual.callback_pointer()
check(actual.apply(pointer, 7, 9) == 23, 'indirect compiled function pointer')
check(actual.raw.apply(pointer, 7, 9) == 23, 'native indirect compiled function pointer')

local fp, fq = ffi.new('float[1]', 1.5), ffi.new('float[1]', 1.5)
check(actual.float_pointer(fp, 0.25) == baseline.float_pointer(fq, 0.25) and fp[0] == fq[0], 'floating pointer mutation')
for _, value in ipairs {0/0, math.huge, -math.huge, -0.0} do same('float_compare', value, 0) end

for n=0,2 do same('array_read', n) end
for _, case in ipairs {{'checked',0,'direct checked failure'}, {'checked_callback',0,'direct callback failure'},
    {'array_read',3,'slice index out of range'}} do
    local ok, message = pcall(actual[case[1]], case[2])
    check(not ok and tostring(message):find(case[3],1,true), tostring(message))
    same('checked', 10) -- a fresh invocation after longjmp must remain sound
end

local source = {}
local names = {'U8','U16','U32','U64','I8','I16','I32','I64'}
for _, T in ipairs(names) do
    for name, expr in pairs {add='a+b',sub='a-b',mul='a*b',div='a/b',mod='a%b',
        band='band a b',bor='bor a b',bxor='bxor a b',shl='shl a b',shr='shr a b'} do
        local n = name .. '_' .. T
        source[#source+1] = ('local %s = do(a: %s, b: %s): %s = %s\nexport %s'):format(n,T,T,T,expr,n)
    end
    for _, D in ipairs(names) do
        local n = 'to_' .. D .. '_' .. T
        source[#source+1] = ('local %s = do(a: %s): %s = %s a\nexport %s'):format(n,T,D,D,n)
    end
end
local expression = 'x'
for _=1,30 do expression = 'x + (' .. expression .. ')' end
source[#source+1] = 'local deep = do(x: U64): U64 = ' .. expression .. '\nexport deep'
source[#source+1] = 'local deep_float = do(x: F64): F64 = ' .. expression .. '\nexport deep_float'
local mixed_params, mixed_terms = {}, {}
for i=1,9 do
    if i<=7 then mixed_params[#mixed_params+1]='i'..i..': I64'; mixed_terms[#mixed_terms+1]='F64 i'..i end
    mixed_params[#mixed_params+1]='f'..i..': F64'; mixed_terms[#mixed_terms+1]='f'..i
end
source[#source+1] = 'local many_mixed = do('..table.concat(mixed_params,',')..'): F64 = '
    ..table.concat(mixed_terms,' + ')..'\nexport many_mixed'
local text = table.concat(source, '\n')
local _, mod = slc.compile(text, 'build/direct/matrix.slc', {no_c=true})
baseline = native.compile(mod)
local _, direct_mod = slc.compile(text, 'build/direct/matrix.slc', {no_c=true})
actual = without_processes(function() return direct.compile(direct_mod) end)
c = c_baseline(text, 'build/direct/matrix.slc', actual, 'c-matrix')
for _, T in ipairs(names) do
    for _, name in ipairs {'add','sub','mul','div','mod','band','bor','bxor','shl','shr'} do
        same(name .. '_' .. T, 7, 2)
    end
    for _, D in ipairs(names) do same('to_' .. D .. '_' .. T, 123) end
end
same('deep', 123); same('deep', 18446744073709551615ULL); same('deep_float', 1.25)
same('many_mixed', 1,1.5,2,2.5,3,3.5,4,4.5,5,5.5,6,6.5,7,7.5,8.5,9.5)
-- Missing native dependencies must be diagnosed, never compiled on demand.
local _, unsupported = slc.compile('local missing = extern("slc_direct_missing_fixture", { U32 }, U32)\nlocal f = do(x: U32): U32 = missing x\nexport f',
    'build/direct/unsupported.slc', {no_c=true})
local ok, err = pcall(direct.compile, unsupported)
check(not ok and tostring(err):find('unresolved native symbol slc_direct_missing_fixture',1,true), tostring(err))
check(not pcall(actual.deep), 'arity mismatch was accepted')
for _, handle in ipairs(c_handles) do check(ffi.C.dlclose(handle) == 0, 'C baseline unload') end
checks = checks + require('tests.storage_boundaries')(slc, true)
print(('direct prepared IR: %d differential/diagnostic checks passed (C/gccjit/direct)'):format(checks))
