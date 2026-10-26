-- Toolchain: the host pieces slc drives. `make dist` links slc's own runtime into
-- the binary; a development tree builds the same archive on demand. Executables
-- and the probe use the host C compiler and binutils.
local T = {}

local root = rawget(_G, 'slc_root') or (debug.getinfo(1, 'S').source:match('^@(.*)/slc/[^/]*$') or '.')
local RT = root .. '/runtime'

local function sh(cmd)
    local p = assert(io.popen('(' .. cmd .. ') 2>&1; echo "__rc=$?"'))
    local out = p:read '*a'
    p:close()
    local rc = tonumber(out:match('__rc=(%d+)%s*$'))
    return rc == 0, (out:gsub('__rc=%d+%s*$', ''))
end
T.sh = sh

function T.cc()
    return os.getenv('CC') or 'cc'
end

local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function read(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read '*a'
    f:close()
    return s
end

local function fnv(s)
    local h = 2166136261
    for i = 1, #s do h = bit.band(bit.bxor(h, s:byte(i)) * 16777619, 0xffffffff) end
    return bit.tohex(h)
end

function T.cache_dir()
    local d = os.getenv('SLC_CACHE')
    if not d then
        local xdg = os.getenv('XDG_CACHE_HOME')
        d = (xdg or ((os.getenv('HOME') or '/tmp') .. '/.cache')) .. '/slc'
    end
    os.execute('mkdir -p ' .. quote(d))
    return d
end

-- The runtime as a static archive: the one the binary carries (`SLC_RT`), or one
-- built here from the runtime C and the SLC policy, cached by content.
local archive
function T.runtime_archive()
    if archive then return archive end
    local in_process = os.getenv('SLC_RT')
    if in_process and read(in_process) then archive = in_process; return archive end
    local names = { 'slc_rt.c', 'slc_tasks.c', 'slc_io_posix.c', 'slc_io_poll.c' }
    local text = {}
    for _, n in ipairs(names) do text[#text + 1] = read(RT .. '/' .. n) or '' end
    for _, n in ipairs { 'slc_rt.h', 'slc_io.h', 'slc_io_posix.h', 'slc_scheduler.h', 'slc_io_poll.h' } do
        text[#text + 1] = read(RT .. '/' .. n) or ''
    end
    local policy = require('slc.runtime_build').source()
    text[#text + 1] = read(policy) or ''
    local dir = T.cache_dir() .. '/runtime-' .. fnv(table.concat(text))
    local path = dir .. '/libslc_rt.a'
    if read(path) then archive = path; return archive end
    os.execute('mkdir -p ' .. quote(dir))
    local objs = {}
    for i, n in ipairs(names) do
        objs[i] = ('%s/%s.o'):format(dir, n:gsub('%.c$', ''))
        local ok, out = sh(('%s -std=c99 -O2 -pthread -I%s -c %s -o %s'):format(
            T.cc(), quote(RT), quote(RT .. '/' .. n), quote(objs[i])))
        if not ok then error('building the runtime failed:\n' .. out, 0) end
    end
    local policy_obj = dir .. '/policy.o'
    local ok, out = sh(('%s -std=c99 -O2 -pthread -I%s -c %s -o %s'):format(
        T.cc(), quote(RT), quote(policy), quote(policy_obj)))
    if not ok then error('building the runtime policy failed:\n' .. out, 0) end
    objs[#objs + 1] = policy_obj
    ok, out = sh(('ar rcs %s %s'):format(quote(path), table.concat((function()
        local q = {}
        for i, o in ipairs(objs) do q[i] = quote(o) end
        return q
    end)(), ' ')))
    if not ok then error('archiving the runtime failed:\n' .. out, 0) end
    archive = path
    return archive
end

-- Link an object (and the probe's, when it has one) into an executable with the
-- runtime archive. The host `cc` does the work; nothing is embedded here.
function T.link_executable(obj, out, opts)
    opts = opts or {}
    local parts = {
        T.cc(), '-std=c99', '-' .. (opts.opt or 'O2'), '-pthread',
        '-o', quote(out), quote(obj),
    }
    if opts.debug then table.insert(parts, '-g') end
    if opts.probe_object then parts[#parts + 1] = quote(opts.probe_object) end
    for _, o in ipairs(opts.extra_objects or {}) do parts[#parts + 1] = quote(o) end
    parts[#parts + 1] = '-Wl,--whole-archive'
    parts[#parts + 1] = quote(T.runtime_archive())
    parts[#parts + 1] = '-Wl,--no-whole-archive'
    parts[#parts + 1] = '-lm'
    parts[#parts + 1] = '-ldl'
    return sh(table.concat(parts, ' '))
end

return T
