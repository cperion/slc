-- A project is a `project.lua` beside a program: a table with the entry, extra
-- module paths and build options, since Lua is already slc's configuration
-- language. The command layer resolves a target path to one of these.
local P = {}

local function read(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local t = f:read '*a'
    f:close()
    return t
end

local function is_dir(path)
    local ok = os.execute(('test -d %q'):format(path))
    return ok == 0 or ok == true
end

function P.exists(path)
    return read(path) ~= nil
end

-- load a project file in a data-only environment: it evaluates to a table
function P.load(path)
    local src = read(path)
    if not src then return nil end
    local chunk, err = loadstring(src, '@' .. path)
    if not chunk then error('project file ' .. path .. ': ' .. tostring(err), 0) end
    local env = { math = math, string = string, table = table, tostring = tostring }
    setfenv(chunk, env)
    local ok, spec = pcall(chunk)
    if not ok then error('project file ' .. path .. ': ' .. tostring(spec), 0) end
    if type(spec) ~= 'table' then error('project file ' .. path .. ': expected a table', 0) end
    local dir = path:match('^(.*)/[^/]*$') or '.'
    local entry = spec.entry
    if type(entry) ~= 'string' then error('project file ' .. path .. ': entry = "file.slc" is required', 0) end
    local paths = {}
    for i, p in ipairs(spec.paths or {}) do
        if type(p) ~= 'string' then error('project file ' .. path .. ': paths must be strings', 0) end
        paths[i] = p:sub(1, 1) == '/' and p or (dir .. '/' .. p)
    end
    return {
        file = path, dir = dir, entry = entry:sub(1, 1) == '/' and entry or (dir .. '/' .. entry),
        paths = paths, options = spec.options or {},
    }
end

-- A target is a program file, a project directory, or a project file.
function P.resolve(target)
    if not target then return nil end
    if target:match('project%.lua$') then return P.load(target) end
    if is_dir(target) then
        local file = target:gsub('/$', '') .. '/project.lua'
        if P.exists(file) then return P.load(file) end
        error(target .. ': no project.lua in the directory', 0)
    end
    return { entry = target, dir = (target:match('^(.*)/[^/]*$') or '.'), paths = {}, options = {} }
end

return P
