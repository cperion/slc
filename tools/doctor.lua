-- Dependency checks only: no downloads or system package changes.
print(jit and jit.version or _VERSION)
assert(jit, 'SLC requires LuaJIT')
local ok, lpeg = pcall(require, 'lpeg')
assert(ok, 'LPeg for Lua 5.1 is missing; install with luarocks --lua-version=5.1 install lpeg, or set LUA_CPATH')
print('LPeg: ' .. (type(lpeg.version) == 'function' and lpeg.version() or tostring(lpeg.version)))
assert(require('macro'), 'project macro source is missing')
assert(package.preload.macro == nil, 'macro must load from source, not a bundle')
print('LuaMacro: project source modules')
local c = require 'slc.cjit'
local available, lib = pcall(c.lib)
if available then
    print(('libgccjit: %d.%d.%d'):format(lib.gcc_jit_version_major(), lib.gcc_jit_version_minor(), lib.gcc_jit_version_patchlevel()))
else
    print('libgccjit: unavailable (optional for C output; required for JIT)')
    print('Set SLC_GCCJIT to its shared library path, or install libgccjit 13+.')
end
print('Test workers: ' .. (os.getenv('SLC_WORKERS') or 'runtime default'))
print('Generated files: ' .. (os.getenv('TMPDIR') or '/tmp'))
