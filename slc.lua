#!/usr/bin/env luajit
--[==[
slc: staged Lua -> C.

    luajit slc.lua program.slc            print the C program
    luajit slc.lua -o out.c program.slc   write it to a file (-H out.h for a header)
    luajit slc.lua -d program.slc         print the Lua the program becomes
    luajit slc.lua --cc program.slc       also check the C with cc -Wall -Wextra -Werror
    luajit slc.lua --gccjit -o out.o p.slc  compile with libgccjit instead, to an object file
    luajit slc.lua run program.slc args   run it now: compiled into this process by libgccjit

A program is Lua extended with typed words. Running it (at compile time, in
LuaJIT) constructs and specializes native code; `export name` materializes a
word as a C function. Only what the exports reach is emitted.
]==]

-- Resolve the project tree from this module, not the embedding application's arg.
local source = debug.getinfo(1, 'S').source
local here = rawget(_G, 'slc_root') or source:match('^@(.*)[/\\][^/\\]*$') or '.'
if here ~= '.' then package.path = here .. '/?.lua;' .. package.path end

local macro = require 'macro'
require 'macro.builtin'
require 'macro.slc'
local S = require 'slc.stage'
local G = require 'slc.cgen'
local T = require 'slc.types'
local loader = require 'slc.loader'
-- Compiler implementation modules have host lifetime. Load their registration
-- hooks before entering a program's module scope, so resets cannot stack hooks
-- or discard native-backend/FFI state. This does not load libgccjit itself.
local Mem = require 'slc.memory'
local Str = require 'slc.strings'
local Maps = require 'slc.maps'
local Native = require 'slc.native'

local slc = {}

-- the names a program sees besides Lua's own
function slc.prelude()
    local env = setmetatable({}, { __index = _G })
    for _, n in ipairs(T.scalars) do env[n] = T[n] end
    env.__S = S
    env.__ENV = env
    env.Ref = S.Ref
    env.opaque = T.opaque
    env.cstruct = S.cstruct
    env.cconst = S.cconst
    env.cread = S.cread
    env.view_of = S.view_of
    env.Atomic = function(t)
        local ok, r = pcall(T.atomic, t)
        if not ok then S.fail((tostring(r):gsub('^[^:]+:%d+: ', '')), 2) end
        return r
    end
    env.Chan = function(t)
        local ok, r = pcall(T.chan, t)
        if not ok then S.fail((tostring(r):gsub('^[^:]+:%d+: ', '')), 2) end
        return r
    end
    env.tasks = S.tasks
    env.blocking = S.blocking
    env.take = S.take_case
    env.Pool = function(t)
        local ok, r = pcall(T.pool, t)
        if not ok then S.fail((tostring(r):gsub('^[^:]+:%d+: ', '')), 2) end
        return r
    end
    env.Slot = function(t)
        local ok, r = pcall(T.slot, t)
        if not ok then S.fail((tostring(r):gsub('^[^:]+:%d+: ', '')), 2) end
        return r
    end
    env.first_of = S.first_of
    env.recv = S.recv_case
    env.send = S.send_case
    env.after = S.after_case
    env.sleep = S.sleep
    env.Duration = T.Duration
    env.ns, env.us, env.ms, env.seconds = S.ns, S.us, S.ms, S.seconds
    env.fence = S.fence
    env.trap = S.trap
    env.atomic_ptr = S.atomic_ptr
    env.bytes = S.bytes
    env.size_of = S.size_of
    env.rawmember = S.rawmember
    env.global = S.global
    env.fnptr = S.fnptr
    env.Fn = function(params, ret)
        local ok, r = pcall(T.fn, params, ret)
        if not ok then S.fail((tostring(r):gsub('^[^:]+:%d+: ', '')), 2) end
        return r
    end
    env.cformat = S.cformat
    env.Args = S.args_type()
    env.test = S.test
    env.check = S.check
    env.Ptr = S.Ptr
    env.Slice = S.Slice
    env.Array = S.Array
    env.null = S.null
    env.dynamic = S.dynamic
    env.host = S.host
    -- native(word): compile now, into this process, and call it from Lua
    env.native = function(w) return Native.word(w) end
    env.extern = S.extern
    env.band, env.bor, env.bxor, env.shl, env.shr, env.bnot = S.band, S.bor, S.bxor, S.shl, S.shr, S.bnot
    Mem.prelude(env)
    Str.prelude(env)
    Maps.prelude(env)
    return env
end

local function read(path)
    local f, err = io.open(path)
    if not f then error(err, 0) end
    local s = f:read '*a'
    f:close()
    return s
end

local function escape(s) return (s:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0')) end

-- report errors at the innermost line of the program being compiled
local function locate(path)
    return function(e)
        local msg = tostring(type(e) == 'table' and (e.slc_ub or e[1]) or e)
        local user = '^' .. escape(path) .. ':%d+:'
        if msg:match(user) then return msg end
        for level = 2, 60 do
            local info = debug.getinfo(level, 'Sl')
            if not info then break end
            if info.source == '@' .. path and info.currentline and info.currentline > 0 then
                msg = msg:gsub('^[^\n:]+%.lua:%d+: ', '')
                return path .. ':' .. info.currentline .. ': ' .. msg
            end
        end
        return msg
    end
end

-- translate a source text to Lua
function slc.translate(src, path)
    local code, err = macro.substitute_tostring(src, path)
    if not code then
        -- macro errors name the macro's own file first; keep the program's line
        local at = tostring(err):find(path .. ':', 1, true)
        error(at and err:sub(at) or err, 0)
    end
    return code
end

-- compile a program; returns the C text and the module
function slc.compile(src, path, opts)
    opts = opts or {}
    local dir = path:match('^(.*)/[^/]*$') or '.'
    -- a project's extra module paths join the program's own for this compilation
    local saved_path = package.path
    if opts.paths and #opts.paths > 0 then
        local parts = {}
        for i, d in ipairs(opts.paths) do parts[i] = d .. '/?.lua;' .. d .. '/?/init.lua' end
        package.path = table.concat(parts, ';') .. ';' .. package.path
    end
    local ok, out, mod, env = pcall(function()
        return loader.with_context(here, dir, slc.translate, slc.prelude, function()
            S.reset()
            S.user_source, S.user_path = '@' .. path, path
            local code = slc.translate(src, path)
            if opts.dump then return code end
            local chunk, err = loadstring(code, '@' .. path)
            if not chunk then error(locate(path)(err), 0) end
            local penv = slc.prelude()
            -- the program's own arguments (slc run), never the compiler's
            penv.arg = opts.arg or { [0] = path }
            setfenv(chunk, penv)
            local fine, e = xpcall(chunk, locate(path))
            if not fine then error(e, 0) end
            if opts.no_c then return nil, S.module, penv end
            return G.emit(S.module), S.module, penv
        end)
    end)
    package.path = saved_path
    if not ok then error(out, 0) end
    return out, mod, env
end

-- load a program into this process: its exports, compiled by libgccjit, as Lua functions
function slc.load(path, opts)
    local src = read(path)
    local _, mod = slc.compile(src, path, { no_c = true })
    return require('slc.native').compile(mod, opts)
end

-- run a program now: its Lua runs (native(word) calls words as it goes), then
-- its exports are compiled into this process; an exported main is called
local function run(args)
    if not args[1] then io.stderr:write('usage: slc run program.slc|project [args...]\n'); os.exit(2) end
    local proj = require('slc.project').resolve(args[1])
    local path = proj.entry
    local prog_arg = { [0] = args[1] }
    for i = 2, #args do prog_arg[i - 1] = args[i] end
    local ok, r = pcall(function()
        local _, mod = slc.compile(read(path), path, { no_c = true, arg = prog_arg, paths = proj.paths })
        if #mod.exports == 0 then return nil end
        local m = require('slc.native').compile(mod)
        if not m.main then return nil end
        local arity = (m.arity and m.arity.main) or 0
        if arity == 0 then return m.main() end
        -- main(args: Args): the program path and its arguments, as the process saw them
        local ffi = require 'ffi'
        local count = #prog_arg + 1
        local argv = ffi.new('char *[?]', count)
        argv[0] = ffi.cast('char *', path)
        for i = 1, #prog_arg do argv[i] = ffi.cast('char *', prog_arg[i]) end
        local ArgsT = m.types and m.types['slc_args']
        if not ArgsT then return m.main() end
        return m.main(ffi.new(ArgsT, { count = count, argv = argv }))
    end)
    if not ok then io.stderr:write(tostring(r), '\n'); os.exit(1) end
    if type(r) == 'number' then os.exit(r) end
    if r == false then os.exit(1) end
end

-- slc test program.slc: run the program's tests, each under slc_try
local function run_tests(rest)
    if not rest[1] then io.stderr:write('usage: slc test program.slc|project\n'); os.exit(2) end
    local proj = require('slc.project').resolve(rest[1])
    local path = proj.entry
    local ok, mod = pcall(function() return select(2, slc.compile(read(path), path, { no_c = true, paths = proj.paths })) end)
    if not ok then io.stderr:write(tostring(mod), '\n'); os.exit(1) end
    local tests = mod.tests or {}
    if #tests == 0 then
        io.write('no tests in ', path, '\n')
        os.exit(0)
    end
    local mok, m = pcall(function() return require('slc.native').compile(mod) end)
    if not mok then io.stderr:write(tostring(m), '\n'); os.exit(1) end
    local failed = 0
    for _, fn in ipairs(tests) do
        local call = m[fn.export_name or fn.cname] or m[fn.cname]
        local pok, err = pcall(call)
        if pok then
            io.write('ok    ', fn.test_name or fn.cname, '\n')
        else
            failed = failed + 1
            io.write('FAIL  ', fn.test_name or fn.cname, '\n', tostring(err), '\n')
        end
    end
    io.write(('%d tests, %d failed\n'):format(#tests, failed))
    os.exit(failed == 0 and 0 or 1)
end

-- slc build prog.slc -o prog: an executable, linked by the host cc
local function build_opts(rest)
    local o = { opt = 'O2' }
    local input, out = nil, nil
    local i = 1
    while i <= #rest do
        local a = rest[i]
        if a == '-o' then i = i + 1; out = rest[i]
        elseif a == '-g' then o.debug = true
        elseif a:match('^%-O%d$') then o.opt = a:sub(2)
        elseif a:sub(1, 1) == '-' then io.stderr:write('slc build: unknown option ', a, '\n'); os.exit(2)
        else input = input or a end
        i = i + 1
    end
    return input, out, o
end

local function build(rest)
    local path, out, opts = build_opts(rest)
    if not path or not out then
        io.stderr:write('usage: slc build prog.slc -o prog [-O0..-O3] [-g]\n'); os.exit(2)
    end
    local proj = require('slc.project').resolve(path)
    local entry = proj.entry
    if proj.options.opt then opts.opt = 'O' .. tostring(proj.options.opt) end
    if proj.options.debug ~= nil then opts.debug = proj.options.debug end
    local ok, err = pcall(function()
        local src = read(entry)
        local _, mod = slc.compile(src, entry, { no_c = true, paths = proj.paths })
        local has_main = false
        for _, fn in ipairs(mod.exports) do if (fn.export_name or fn.cname) == 'main' then has_main = true end end
        if not has_main then
            error('slc build: the program exports no main; add `export main`', 0)
        end
        local main_fn
        for _, fn in ipairs(mod.exports) do
            if (fn.export_name or fn.cname) == 'main' then main_fn = fn end
        end
        local u = require('slc.jitgen').build(mod, { opt = tonumber(opts.opt), debug = opts.debug })
        local tmp = (os.getenv('TMPDIR') or '/tmp')
        local obj = ('%s/slc-build-%d.o'):format(tmp, math.random(1e9))
        if u.probe.object then
            u.ctx:compile_to_file('object', obj .. '.part')
            local r = os.execute(('ld -r -o %q %q %q'):format(obj, obj .. '.part', u.probe.object))
            os.remove(obj .. '.part')
            if r ~= 0 and r ~= true then error('slc build: linking the probe object failed', 0) end
        else
            u.ctx:compile_to_file('object', obj)
        end
        u.ctx:release()
        -- the C entry point: slc names the export after its word, which may be
        -- renamed ("main_"), so a tiny wrapper is the executable's main
        local wrapper = obj .. '.main.c'
        local f = assert(io.open(wrapper, 'w'))
        f:write(('/* generated by slc build */\nint %s(void);\nint main(void) { return %s(); }\n'):format(
            main_fn.cname, main_fn.cname))
        f:close()
        local wrapper_obj = obj .. '.main.o'
        local okw, outw = require('slc.toolchain').sh(('%s -std=c99 -c %q -o %q'):format(
            require('slc.toolchain').cc(), wrapper, wrapper_obj))
        os.remove(wrapper)
        if not okw then os.remove(obj); error('slc build: compiling the entry point failed:\n' .. outw, 0) end
        local linked, out_text = require('slc.toolchain').link_executable(wrapper_obj, out, {
            opt = opts.opt, debug = opts.debug, extra_objects = { obj } })
        os.remove(obj)
        os.remove(wrapper_obj)
        if not linked then error('slc build: linking failed:\n' .. out_text, 0) end
    end)
    if not ok then io.stderr:write(tostring(err), '\n'); os.exit(1) end
    os.exit(0)
end

-- slc check program.slc: specialize and report errors, emit nothing
local function check(rest)
    if not rest[1] then io.stderr:write('usage: slc check program.slc|project\n'); os.exit(2) end
    local proj = require('slc.project').resolve(rest[1])
    local path = proj.entry
    local ok, err = pcall(function() slc.compile(read(path), path, { no_c = true, paths = proj.paths }) end)
    if not ok then io.stderr:write(tostring(err), '\n'); os.exit(1) end
    os.exit(0)
end

-- slc cc file.c -o file.o: the host compiler, for probes and for C beside slc
local function cc(rest)
    local parts = { require('slc.toolchain').cc(), '-std=c99' }
    for _, a in ipairs(rest) do parts[#parts + 1] = ("'%s'"):format((a:gsub("'", "'\\''"))) end
    os.exit(os.execute(table.concat(parts, ' ')) and 0 or 1)
end

-- slc doctor: what this host has
local function doctor()
    local lines = {}
    lines[#lines + 1] = jit and jit.version or _VERSION
    local ok, lpeg = pcall(require, 'lpeg')
    lines[#lines + 1] = 'LPeg: ' .. (ok and (type(lpeg.version) == 'function' and lpeg.version() or 'present') or 'MISSING (install lpeg 5.1)')
    local c = require 'slc.cjit'
    local have_jit, lib = pcall(c.lib)
    lines[#lines + 1] = have_jit and ('libgccjit: %d.%d.%d'):format(
        lib.gcc_jit_version_major(), lib.gcc_jit_version_minor(), lib.gcc_jit_version_patchlevel())
        or 'libgccjit: MISSING (SLC_GCCJIT or libgccjit.so.0)'
    local t = require 'slc.toolchain'
    local _, ccv = t.sh(t.cc() .. ' --version')
    lines[#lines + 1] = 'cc: ' .. ((ccv or ''):match('^[^\n]*') or t.cc())
    for _, tool in ipairs { 'as', 'ld' } do
        local ok2, v = t.sh(tool .. ' --version')
        lines[#lines + 1] = tool .. ': ' .. (ok2 and ((v or ''):match('^[^\n]*') or 'present') or 'MISSING')
    end
    lines[#lines + 1] = 'cache: ' .. t.cache_dir()
    lines[#lines + 1] = 'runtime: ' .. (os.getenv('SLC_RT') and ('linked in; archive ' .. os.getenv('SLC_RT')) or 'built on demand')
    for _, l in ipairs(lines) do print(l) end
    os.exit(ok and have_jit and 0 or 1)
end

-- slc cache clean: drop the probe/compilation cache
local function cache(rest)
    local t = require 'slc.toolchain'
    if rest[1] == 'clean' then
        os.exit(os.execute(('rm -rf %q'):format(t.cache_dir())) and 0 or 1)
    end
    print(t.cache_dir())
    os.exit(0)
end

-- slc fuzz [--tasks] [--storage] [options]: the fuzzers, in this process (the
-- single binary has no `luajit` to spawn)
local function script(name, args, defaults, first)
    local here = rawget(_G, 'slc_root') or debug.getinfo(1, 'S').source:match('^@(.*)/[^/]*$') or '.'
    local saved = arg
    local rest = {}
    for i = 1, #defaults do rest[i] = defaults[i] end
    for i = first, #args do rest[#rest + 1] = args[i] end
    arg = { [0] = here .. '/tests/fuzz/' .. name }
    for i, a in ipairs(rest) do arg[i] = a end
    local ok, err = pcall(dofile, here .. '/tests/fuzz/' .. name)
    arg = saved
    if not ok then io.stderr:write(tostring(err), '\n'); return 1 end
    return 0
end

local function fuzz(args)
    local first = 1
    local defaults = {}
    local name = 'fuzz.lua'
    if args[1] == '--tasks' then name, first, defaults = 'tasks.lua', 2, { '--seeds', '5' }
    elseif args[1] == '--storage' then name, first, defaults = 'storage.lua', 2, { '--count', '20' } end
    os.exit(script(name, args, defaults, first))
end

local function main(args)
    local sub = args[1]
    local function rest() local r = {}; for i = 2, #args do r[#r + 1] = args[i] end; return r end
    if sub == 'build' then return build(rest()) end
    if sub == 'check' then return check(rest()) end
    if sub == 'test' then return run_tests(rest()) end
    if sub == 'cc' then return cc(rest()) end
    if sub == 'doctor' then return doctor() end
    if sub == 'cache' then return cache(rest()) end
    if sub == 'version' then print('slc 0.5-alpha'); os.exit(0) end
    if args[1] == 'fuzz' then
        local rest = {}
        for i = 2, #args do rest[#rest + 1] = args[i] end
        return fuzz(rest)
    end
    if args[1] == 'fmt' then
        local rest = {}
        for i = 2, #args do rest[#rest + 1] = args[i] end
        os.exit(require('slc.fmt_cli').run(rest))
    end
    if args[1] == 'run' then
        local rest = {}
        for i = 2, #args do rest[#rest + 1] = args[i] end
        return run(rest)
    end
    local opts, input = {}, nil
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == '-o' then i = i + 1; opts.out = args[i]
        elseif a == '-H' then i = i + 1; opts.header = args[i]
        elseif a == '-d' then opts.dump = true
        elseif a == '--cc' then opts.cc = true
        elseif a == '--gccjit' then opts.gccjit = true
        elseif a:sub(1, 1) == '-' and a ~= '-' then
            io.stderr:write('slc: unknown option ', a, '\n'); os.exit(2)
        else input = a end
        i = i + 1
    end
    if not input then
        io.stderr:write((([[usage: luajit slc.lua [-o out.c] [-H out.h] [-d] [--cc] program.slc
       luajit slc.lua run program.slc [args...]
       luajit slc.lua build program.slc -o program [-O0..-O3] [-g]
       luajit slc.lua check program.slc
       luajit slc.lua test program.slc
       luajit slc.lua fuzz [--tasks] [--seconds N] [--seed S] [--count N]
       luajit slc.lua cc file.c -o file.o
       luajit slc.lua doctor | version | cache clean
       luajit slc.lua fmt [files...]
]]))); os.exit(2)
    end
    local ok, out, mod = pcall(function()
        local src = read(input)
        return slc.compile(src, input, opts)
    end)
    if not ok then
        io.stderr:write(tostring(out), '\n')
        os.exit(1)
    end
    if opts.gccjit then
        -- the same module through libgccjit: an object file
        if not opts.out then io.stderr:write('slc: --gccjit needs -o out.o\n'); os.exit(2) end
        local okj, err = pcall(function()
            local u = require('slc.jitgen').build(mod, { opt = 2 })
            if u.probe.object then
                -- C variables are read through the header probe's getters: one object
                local tmp = opts.out .. '.jit.o'
                u.ctx:compile_to_file('object', tmp)
                local r = os.execute(('ld -r -o %q %q %q && rm -f %q'):format(opts.out, tmp, u.probe.object, tmp))
                if r ~= 0 and r ~= true then error('slc: ld -r failed', 0) end
            else
                u.ctx:compile_to_file('object', opts.out)
            end
            u.ctx:release()
        end)
        if not okj then io.stderr:write(tostring(err), '\n'); os.exit(1) end
    elseif opts.out then
        local f = assert(io.open(opts.out, 'w'))
        f:write(out)
        f:close()
    else
        io.write(out)
    end
    if opts.header and mod then
        local f = assert(io.open(opts.header, 'w'))
        f:write(G.header(mod))
        f:close()
    end
    if opts.cc and not opts.dump then
        local tmp = opts.out or os.tmpname() .. '.c'
        if not opts.out then local f = assert(io.open(tmp, 'w')); f:write(out); f:close() end
        local cmd = ('cc -std=c99 -Wall -Wextra -Werror -pedantic -I%s/runtime -c %s -o /dev/null'):format(here, tmp)
        local r = os.execute(cmd)
        if r ~= 0 and r ~= true then os.exit(1) end
    end
end

if arg and arg[0] and arg[0]:match('slc%.lua$') and not package.loaded['slc.driver_loaded'] then
    main(arg)
else
    return slc
end
