-- Use Lua's require machinery, with an SLC source searcher and a compilation
-- lifetime for newly loaded modules. No second require implementation/cache.
local M = {}
local active = false
local unpack = unpack
local function pack(...) return { n = select('#', ...), ... } end
local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function searcher(root, translate, prelude)
    return function(name)
        local module_path = name:gsub('%.', '/')
        local candidates, seen = {}, {}
        local function add(path)
            if not seen[path] then seen[path] = true; candidates[#candidates + 1] = path end
        end
        -- Bundled vocabulary names do not replace Lua's io, string, etc.
        local bundled = name:match('^slc%.(.+)$')
        if bundled then
            local stem = root .. '/lib/' .. bundled:gsub('%.', '/')
            add(stem .. '.slc'); add(stem .. '/init.slc')
        end
        -- Follow the current Lua source path, including program-local modules.
        -- A custom non-.lua template belongs to its existing Lua loader.
        for template in package.path:gmatch('[^;]+') do
            if template:sub(-4) == '.lua' then
                add((template:sub(1, -5) .. '.slc'):gsub('%?', function() return module_path end))
            end
        end
        local missing = {}
        for _, path in ipairs(candidates) do
            -- an embedded build serves the module from memory
            local provider = rawget(_G, '__slc_embedded_source')
            local memory = provider and provider(path)
            if memory then
                local chunk, why = loadstring(translate(memory, path), '@' .. path)
                if not chunk then error(why, 0) end
                setfenv(chunk, prelude())
                return chunk
            end
            local f, err, code = io.open(path, 'rb')
            if f then
                local source, read_error = f:read('*a'); f:close()
                if not source then error(read_error, 0) end
                -- A found module with a syntax/load error must fail, not fall
                -- through to another source candidate.
                local chunk, why = loadstring(translate(source, path), '@' .. path)
                if not chunk then error(why, 0) end
                setfenv(chunk, prelude())
                return chunk
            end
            if code ~= 2 and code ~= 20 then error(err, 0) end
            missing[#missing + 1] = "\n\tno file '" .. path .. "'"
        end
        return table.concat(missing)
    end
end

function M.with_context(root, program_dir, translate, prelude, body)
    if active then error('slc: nested compilation is not supported', 0) end
    local registry = debug.getregistry()
    local saved_loaded, saved_public = registry._LOADED, package.loaded
    local saved_loaders, saved_path, saved_preload = package.loaders, package.path, package.preload
    local saved_cpath = package.cpath
    local loaded, loaders = copy(saved_loaded), copy(saved_loaders)
    -- Keep the precedence of every host loader (preload, Lua, C and custom).
    -- SLC source extends that chain instead of intercepting existing modules.
    loaders[#loaders + 1] = searcher(root, translate, prelude)
    active = true
    registry._LOADED, package.loaded = loaded, loaded
    package.loaders = loaders
    package.preload = copy(saved_preload)
    package.path = program_dir .. '/?.lua;' .. program_dir .. '/?/init.lua;' .. saved_path
    local result = pack(pcall(body))
    registry._LOADED, package.loaded = saved_loaded, saved_public
    package.loaders, package.path, package.preload = saved_loaders, saved_path, saved_preload
    package.cpath = saved_cpath
    active = false
    if not result[1] then error(result[2], 0) end
    return unpack(result, 2, result.n)
end

return M
