-- Build ordinary SLC runtime policy without entering/resetting the caller's
-- compiler session. Both native loading and external C harnesses use this path.
local B = {}
local dist_root = rawget(_G, 'slc_root')
local here = dist_root or (debug.getinfo(1, 'S').source:match('^@(.*)/slc/[^/]*$') or '.')
local cached = {}
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function command(cmd)
    local p = assert(io.popen('(' .. cmd .. '); echo "__rc=$?"'))
    local out = p:read '*a'; p:close()
    local rc = tonumber(out:match('__rc=(%d+)%s*$'))
    assert(rc == 0, 'building SLC runtime policy failed (exit ' .. tostring(rc) .. ')')
    return (out:gsub('__rc=%d+%s*$', ''))
end
function B.source(backend)
    backend = backend or os.getenv('SLC_IO') or 'poll'
    assert(backend == 'poll' or backend == 'kqueue' or backend == 'uring', 'unknown I/O backend ' .. backend)
    if cached[backend] then return cached[backend] end
    local text = command('SLC_IO=' .. quote(backend) .. ' ' .. quote(os.getenv('LUA') or 'luajit') .. ' ' .. quote(here .. '/slc.lua')
        .. ' --shared-runtime ' .. quote(here .. '/runtime/scheduler.slc'))
    -- The runtime uses POSIX pread/pwrite and close-on-exec flags. Keep feature
    -- selection before every system header, including generated stdint.h.
    text = '#define _POSIX_C_SOURCE 200809L\n#define _DEFAULT_SOURCE 1\n' .. text
    local hash = 2166136261
    for i = 1, #text do hash = bit.band(bit.bxor(hash, text:byte(i)) * 16777619, 0xffffffff) end
    local dir = os.getenv('SLC_CACHE') or (here .. '/build/runtime')
    command('mkdir -p ' .. quote(dir))
    local path = dir .. '/scheduler-' .. bit.tohex(hash) .. '.c'
    local old = io.open(path)
    if old then
        local same = old:read '*a' == text; old:close()
        assert(same, 'SLC runtime source cache collision: ' .. path)
    else
        -- Publish complete files; simultaneous compiler processes may build the
        -- same policy, but never expose a partially written translation unit.
        local ffi = require 'ffi'
        ffi.cdef 'int getpid(void);'
        local tmp = path .. '.' .. tonumber(ffi.C.getpid()) .. '.tmp'
        local f = assert(io.open(tmp, 'w')); assert(f:write(text)); assert(f:close())
        assert(os.rename(tmp, path))
    end
    cached[backend] = path
    return path
end
return B
