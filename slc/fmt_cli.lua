-- File/configuration handling for slc fmt; formatting itself lives in slc.fmt.
local fmt = require 'slc.fmt'
local M = {}
local usage = [[usage: luajit slc.lua fmt [--check | --write] [--config PATH] [FILE ... | -]
Without --check/--write, format one file (or stdin) to stdout.
Configuration: nearest .slcfmt.lua, searched upward from each file (cwd for stdin).
]]

local function read(path)
    local f, err = io.open(path, 'rb')
    if not f then error(err, 0) end
    local text, why = f:read('*a'); f:close()
    if not text then error(why, 0) end
    return text
end

local function absolute(path, cwd)
    if path:sub(1, 1) ~= '/' then path = cwd .. '/' .. path end
    local parts = {}
    for part in path:gmatch('[^/]+') do
        if part == '..' then parts[#parts] = nil
        elseif part ~= '.' then parts[#parts + 1] = part end
    end
    return '/' .. table.concat(parts, '/')
end

local function parent(path)
    return path:match('^(.*)/[^/]+$') or '/'
end

local function config(path)
    local source = read(path)
    if source:byte(1) == 27 then error(path .. ': fmt: configuration must be Lua source, not bytecode', 0) end
    local chunk, err = loadstring(source, '@' .. path)
    if not chunk then error(err, 0) end
    -- A configuration returns data; it has no access to I/O or process globals.
    setfenv(chunk, {})
    local ok, result = pcall(chunk)
    if not ok then error(result, 0) end
    if type(result) ~= 'table' then error(path .. ': fmt: configuration must return a table', 0) end
    return fmt.options(result)
end

local function discover(dir)
    while true do
        if dir == '' then dir = '/' end
        local path = (dir == '/' and '' or dir) .. '/.slcfmt.lua'
        local f, err, code = io.open(path, 'rb')
        if f then f:close(); return path end
        if code ~= 2 then error(err, 0) end
        if dir == '/' then return nil end
        dir = parent(dir)
    end
end

function M.run(args)
    local mode, configuration, paths, stop = nil, nil, {}, false
    local i = 1
    while i <= #args do
        local a = args[i]
        if not stop and a == '--' then stop = true
        elseif not stop and (a == '--check' or a == '--write') then
            if mode then io.stderr:write('fmt: choose only one of --check and --write\n'); return 2 end
            mode = a
        elseif not stop and a == '--config' then
            i = i + 1; configuration = args[i]
            if not configuration then io.stderr:write('fmt: --config needs a path\n'); return 2 end
        elseif not stop and (a == '--help' or a == '-h') then io.write(usage); return 0
        elseif not stop and a:sub(1, 1) == '-' and a ~= '-' then
            io.stderr:write('fmt: unknown option ', a, '\n'); return 2
        else paths[#paths + 1] = a end
        i = i + 1
    end
    if #paths == 0 then paths[1] = '-' end
    if not mode and #paths > 1 then io.stderr:write('fmt: stdout mode takes one input\n'); return 2 end
    for _, path in ipairs(paths) do
        if path == '-' and (mode == '--write' or #paths > 1) then
            io.stderr:write('fmt: stdin cannot be combined with --write or other inputs\n'); return 2
        end
    end
    local ok, status = pcall(function()
        local pipe = assert(io.popen('pwd'))
        local cwd = assert(pipe:read('*l')); pipe:close()
        local cache, results, seen = {}, {}, {}
        -- Preflight every input before writing any of them.
        for _, path in ipairs(paths) do
            local target = path ~= '-' and absolute(path, cwd) or '-'
            if seen[target] then error('fmt: duplicate input ' .. path, 0) end
            seen[target] = true
            local cfg = configuration and absolute(configuration, cwd) or discover(path == '-' and cwd or parent(target))
            if cfg and not cache[cfg] then cache[cfg] = config(cfg) end
            local source = path == '-' and io.read('*a') or read(target)
            local output = fmt.format(source, cfg and cache[cfg] or nil, path)
            results[#results + 1] = { path = path, target = target, output = output, changed = source ~= output }
        end
        local changed = false
        for _, result in ipairs(results) do
            if not mode then io.write(result.output)
            elseif result.changed then
                changed = true
                if mode == '--write' then
                    local f, err = io.open(result.target, 'wb')
                    if not f then error(err, 0) end
                    local wrote, why = f:write(result.output)
                    local closed, close_error = f:close()
                    if not wrote or not closed then error(why or close_error, 0) end
                end
                io.write(result.path, '\n')
            end
        end
        return mode == '--check' and changed and 1 or 0
    end)
    if not ok then io.stderr:write(tostring(status), '\n'); return 2 end
    return status
end

return M
