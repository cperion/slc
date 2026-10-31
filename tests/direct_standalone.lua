-- A fresh process must run direct code using only offline artifacts. Neither
-- a warm gccjit/runtime cache nor an available compiler may hide a fallback.
package.loaded['slc.driver_loaded'] = true
arg = {[0]='slc.lua'}
local slc = dofile('slc.lua')
local ffi = require 'ffi'
os.execute = function() error('direct execution started a process', 0) end
io.popen = os.execute
require('slc.cjit').lib = function() error('direct execution loaded gccjit', 0) end
local module = slc.load('tests/direct_program.slc', {backend='direct', libs={'build/direct/libdirect_fixture.so'}})
assert(module.affine(0ULL) == 1442695040888963407ULL)
assert(module.native_large_callback(12, 9) == 42)
assert(module.native_record_callback(12, 1.5) == 22)
assert(module.recursive_record_callback(12, 1.5) == 24)
assert(module.native_varargs(0.25, 0.125) == 0.875)
assert(module.array_read(1) == 22)
local ok, message = pcall(module.checked_callback, 0)
assert(not ok and tostring(message):find('direct callback failure', 1, true), tostring(message))
assert(module.checked_callback(1) == 110)
ffi.cdef [[int cp_fixture_parallel_bump(void (*entry)(void *,uint32_t),void *,uint32_t,uint32_t);]]
local fixture = ffi.load('build/direct/libdirect_fixture.so')
local errors = ffi.new('uint64_t[1]')
for _=1,2 do
    assert(fixture.cp_fixture_parallel_bump(ffi.cast('void (*)(void *,uint32_t)',module.raw.tls_probe),errors,4,1000)==0)
    assert(errors[0]==0 and module.tls_value()==7, 'native TLS crossed threads or failed to reinitialize')
end
local hook=ffi.cast('void (*)(const char *)',function(text)
    collectgarbage(); assert(ffi.string(text):sub(1,4)=='live')
end)
for i=1,200 do
    assert(module.after_text_hook(hook,'live'..string.rep('x',i))==i+4)
end
hook:free()
local pointer = module.callback_pointer()
module = nil; collectgarbage(); collectgarbage()
assert(ffi.cast('uint64_t (*)(uint64_t,uint64_t)', pointer)(7,9) == 23)
print('direct standalone: prebuilt-only execution, real trap recovery, and escaped callback passed')
