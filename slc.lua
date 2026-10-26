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
local here = source:match('^@(.*)[/\\][^/\\]*$') or '.'
package.path = here .. '/?.lua;' .. package.path

local macro = require 'macro'
require 'macro.builtin'
require 'macro.slc'
local S = require 'slc.stage'
local G = require 'slc.cgen'
local T = require 'slc.types'

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
    env.atomic_ptr = S.atomic_ptr
    env.bytes = S.bytes
    env.size_of = S.size_of
    env.cformat = S.cformat
    env.import = slc.import
    env.Ptr = S.Ptr
    env.Slice = S.Slice
    env.Array = S.Array
    env.null = S.null
    env.dynamic = S.dynamic
    env.host = S.host
    -- native(word): compile now, into this process, and call it from Lua
    env.native = function(w) return (require 'slc.native').word(w) end
    env.extern = S.extern
    env.band, env.bor, env.bxor, env.shl, env.shr, env.bnot = S.band, S.bor, S.bxor, S.shl, S.shr, S.bnot
    local mem = package.loaded['slc.memory'] or (pcall(require, 'slc.memory') and require 'slc.memory')
    if mem then mem.prelude(env) end
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

-- import "name": load lib/name.slc (next to slc.lua, or next to the program) once,
-- and return what it returns, typically a vocabulary table
local imported = {}
function slc.import(name)
    if imported[name] ~= nil then return imported[name] end
    local dirs = { here .. '/lib', slc.program_dir or '.' }
    local path
    for _, d in ipairs(dirs) do
        local candidate = d .. '/' .. name .. '.slc'
        local f = io.open(candidate)
        if f then f:close(); path = candidate break end
    end
    if not path then error(("import: no library '%s' (looked in %s)"):format(name, table.concat(dirs, ', ')), 2) end
    local code = slc.translate(read(path), path)
    local chunk, err = loadstring(code, '@' .. path)
    if not chunk then error(err, 0) end
    setfenv(chunk, slc.prelude())
    local r = chunk()
    imported[name] = r == nil and true or r
    return r
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
    S.reset()
    imported = {}
    slc.program_dir = path:match('^(.*)/[^/]*$') or '.'
    S.user_source, S.user_path = '@' .. path, path
    local code = slc.translate(src, path)
    if opts.dump then return code end
    local chunk, err = loadstring(code, '@' .. path)
    if not chunk then error(locate(path)(err), 0) end
    local env = slc.prelude()
    -- the program's own arguments (slc run), never the compiler's
    env.arg = opts.arg or { [0] = path }
    setfenv(chunk, env)
    local ok, e = xpcall(chunk, locate(path))
    if not ok then error(e, 0) end
    if opts.no_c then return nil, S.module, env end
    return G.emit(S.module), S.module, env
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
    local path = args[1]
    if not path then io.stderr:write('usage: luajit slc.lua run program.slc [args...]\n'); os.exit(2) end
    local prog_arg = { [0] = path }
    for i = 2, #args do prog_arg[i - 1] = args[i] end
    local ok, r = pcall(function()
        local _, mod = slc.compile(read(path), path, { no_c = true, arg = prog_arg })
        if #mod.exports == 0 then return nil end
        local m = require('slc.native').compile(mod)
        if m.main then return m.main() end
    end)
    if not ok then io.stderr:write(tostring(r), '\n'); os.exit(1) end
    if type(r) == 'number' then os.exit(r) end
    if r == false then os.exit(1) end
end

local function main(args)
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
