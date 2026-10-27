-- slc.native: run it now.
--
-- A module, or a single word, compiled by libgccjit into executable memory in
-- this process and called from Lua through the FFI. The runtime is the same C
-- library every backend links (built once, cached, loaded with its symbols
-- global so the generated code binds to it). Each export is called through a
-- thunk under slc_try, so a failed check in plain code raises a Lua error
-- instead of ending the process.

local ffi = require 'ffi'
local C = require 'slc.cjit'
local JG = require 'slc.jitgen'

local N = {}

-- the command-line record the runtime header declares (Args in slc). It is a
-- foreign C type here, not a type of any one compiled unit.
ffi.cdef [[
typedef struct slc_args { uint32_t count; const char **argv; } slc_args;
]]

local dist_root = rawget(_G, 'slc_root')
local here = dist_root or (debug.getinfo(1, 'S').source:match('^@(.*)/slc/[^/]*$') or '.')
local RT = here .. '/runtime'

local function sh(cmd)
    local p = io.popen('(' .. cmd .. ') 2>&1; echo "__rc=$?"')
    local out = p:read '*a'
    p:close()
    local rc = tonumber(out:match('__rc=(%d+)%s*$'))
    return rc == 0, (out:gsub('__rc=%d+%s*$', ''))
end

local function read(path)
    local f = io.open(path)
    if not f then return nil end
    local s = f:read '*a'
    f:close()
    return s
end

local function fnv(s)
    local h = 2166136261
    for i = 1, #s do
        h = bit.bxor(h, s:byte(i))
        h = bit.band(h * 16777619, 0xffffffff)
    end
    return bit.tohex(h)
end

local function cache_dir()
    local d = os.getenv('SLC_CACHE')
    if not d then
        local xdg = os.getenv('XDG_CACHE_HOME')
        d = (xdg or ((os.getenv('HOME') or '/tmp') .. '/.cache')) .. '/slc'
    end
    os.execute(('mkdir -p %q'):format(d))
    return d
end

-- the runtime library, built once per source text and I/O backend
local rt
function N.runtime()
    if rt then return rt end
    ffi.cdef [[
        int slc_try(void (*body)(void *), void *env);
        const char *slc_trap_message(void);
        const char *slc_io_backend(void);
    ]]
    -- the single binary links the runtime and exports it: gccjit'd code binds to
    -- these symbols in the process, so there is no library to build or load
    if os.getenv('SLC_RUNTIME_IN_PROCESS') == '1' then
        rt = ffi.C
        return rt
    end
    local backend = os.getenv('SLC_IO') or 'poll'
    -- poll and kqueue are SLC; only io_uring has C (the kernel's integer ABI)
    local files = { 'slc_rt.c' }
    if backend == 'uring' then files[#files + 1] = 'slc_io_uring.c' end
    local text = {}
    for _, f in ipairs { 'slc_rt.h', 'slc_io.h', 'slc_io_posix.h', 'slc_scheduler.h', 'slc_io_poll.h', 'slc_io_kqueue.h', 'slc_io_uring.h' } do text[#text + 1] = read(RT .. '/' .. f) or '' end
    local srcs = {}
    for _, f in ipairs(files) do
        local s = read(RT .. '/' .. f)
        if not s then C.fail('no runtime source ' .. f .. ' (SLC_IO=' .. backend .. ')') end
        text[#text + 1] = s
        srcs[#srcs + 1] = RT .. '/' .. f
    end
    local policy = require('slc.runtime_build').source(backend)
    text[#text + 1] = assert(read(policy))
    srcs[#srcs + 1] = policy
    local extra = backend == 'kqueue' and ' -I/usr/include/kqueue -lkqueue' or ''
    local path = ('%s/libslc_rt-%s-%s.so'):format(cache_dir(), backend, fnv(table.concat(text)))
    if not read(path) then
        local cc = os.getenv('CC') or 'cc'
        local ok, out = sh(('%s -std=c99 -O2 -fPIC -shared -pthread -I%s -o %s.tmp %s%s && mv %s.tmp %s'):format(
            cc, RT, path, table.concat(srcs, ' '), extra, path, path))
        if not ok then C.fail('building the runtime library failed:\n' .. out) end
    end
    rt = ffi.load(path, true)
    return rt
end

local units = 0
N.results = {}     -- compiled code lives as long as the process

-- compile a module's exports (or the given functions) into this process
function N.compile(mod, opts)
    opts = opts or {}
    local runtime = N.runtime()
    local u = JG.build(mod, { opt = opts.opt or 2, debug = opts.debug })
    u:thunks()
    if opts.check_layouts then
        local bad = u:check_layouts()
        if #bad > 0 then C.fail('layouts differ: ' .. table.concat(bad, '; ')) end
    end
    if u.probe.shared then ffi.load(u.probe.shared, true) end
    -- C the program's externs need, if it is not part of this process already
    for _, lib in ipairs(opts.libs or {}) do ffi.load(lib, true) end
    local okc, result = pcall(u.ctx.compile, u.ctx)
    if not okc then
        local sym = tostring(result):match('undefined symbol: ([%w_]+)')
        if sym then
            C.fail(("extern '%s' is not defined in this process: load the library that defines it first "
                .. "(slc.load(path, { libs = { 'libx.so' } }), or ffi.load(path, true))"):format(sym))
        end
        error(result, 0)
    end
    N.results[#N.results + 1] = result
    units = units + 1
    local prefix = 'slcjit' .. units .. '_'
    local decls, sigs = u:ffi_decls(prefix)
    if decls ~= '' then ffi.cdef(decls) end
    local out = { raw = {}, types = {} }
    for cname, t in pairs(u.scope.types) do
        if (t.k == 'struct' or t.k == 'union') and t.fields and not t.foreign then
            out.types[cname] = ffi.typeof(t.k .. ' ' .. prefix .. t.name)
        end
    end
    for _, fn in ipairs(u.exports) do
        local d = u.fns[fn]
        local th = u.thunk_of[fn]
        local envt = ffi.typeof('struct ' .. prefix .. th.env.name)
        local thunk = ffi.cast('void (*)(void *)', C.code(result, th.name))
        local n = #d.t.params
        local ret = d.t.ret
        local copy
        if ret.k == 'struct' or ret.k == 'union' then copy = ffi.typeof(ret.k .. ' ' .. prefix .. ret.name) end
        local name = fn.cname
        -- a struct parameter or result (Args for main) is declared with the
        -- unit's prefix; the host builds values of it through out.types
        for _, pt in ipairs(d.t.params) do
            if (pt.k == 'struct' or pt.k == 'union') and pt.name then
                local ok, ft = pcall(ffi.typeof, pt.k .. ' ' .. prefix .. pt.name)
                if ok then out.types[pt.name] = ft end
            end
        end
        out.arity = out.arity or {}
        out.arity[name] = n
        if fn.export_name then out.arity[fn.export_name] = n end
        out.raw[name] = ffi.cast(sigs[name], C.code(result, name))
        local call = function(...)
            local e = envt()
            for i = 1, n do e['a' .. i] = (select(i, ...)) end
            if runtime.slc_try(thunk, e) ~= 0 then
                error('slc runtime check failed: ' .. ffi.string(runtime.slc_trap_message()), 2)
            end
            if ret.k == 'void' then return nil end
            if copy then return copy(e.r) end
            return e.r
        end
        -- by the name it was exported as, and by its C name
        out[name] = call
        if fn.export_name then
            out[fn.export_name] = call
            out.raw[fn.export_name] = out.raw[name]
        end
    end
    u.ctx:release()
    out.unit = prefix
    return out
end

-- native(word): the word, compiled now, as a Lua function
function N.word(w)
    local S = require 'slc.stage'
    local fn = S.native_word(w)
    local view = setmetatable({ exports = { fn } }, { __index = S.module })
    local m = N.compile(view)
    local f = m[fn.cname]
    return f, m.raw[fn.cname]
end

return N
