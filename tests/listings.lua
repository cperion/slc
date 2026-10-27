-- Documentation checks for syntax.md and architecture.md:
--
--  1. every C listing is the compiler's actual output: each top-level piece of a
--     ```c block must appear verbatim in the C generated from examples/. Sketches
--     are exempt (architecture §7's convention, and the listings syntax §20 says
--     are design);
--  2. every `syntax §N.M` / `architecture §N.M` reference, in the docs and in the
--     source comments, names a section that exists.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'

local function read(path)
    local f = io.open(path)
    if not f then return nil end
    local s = f:read '*a'
    f:close()
    return s
end

local docs = {}
for _, name in ipairs { 'syntax', 'architecture' } do
    docs[name] = assert(read(root .. '/docs/' .. name .. '.md'), name)
end

-- 1. listings ------------------------------------------------------------------
local blob = {}
for f in io.popen('ls ' .. root .. '/examples/*.slc'):lines() do
    local p = io.popen(('luajit %s/slc.lua %s 2>&1'):format(root, f))
    blob[#blob + 1] = p:read '*a'
    p:close()
end
blob = table.concat(blob, '\n')
local n, bad = 0, 0
for _, name in ipairs { 'syntax', 'architecture' } do
    for block in docs[name]:gmatch('```c\n(.-)```') do
        if not block:find('...);', 1, true) and not block:find('/* sketch */', 1, true) then
            n = n + 1
            -- pieces separated by blank lines
            for piece in (block .. '\n\n'):gmatch('(.-)\n\n+') do
                if piece:match('%S') and not blob:find(piece, 1, true) then
                    bad = bad + 1
                    print('NOT IN OUTPUT (' .. name .. '.md, listing ' .. n .. '):\n' .. piece .. '\n')
                end
            end
        end
    end
end
print(('%d listings checked, %d pieces missing'):format(n, bad))

-- 2. section references ---------------------------------------------------------
local sections = {}
for _, name in ipairs { 'syntax', 'architecture' } do
    local set = {}
    for line in (docs[name] .. '\n'):gmatch('([^\n]*)\n') do
        local a, b = line:match('^##+ (%d+)%.(%d+) ')
        if a then set[a .. '.' .. b] = true end
        local chapter = line:match('^##+ (%d+)%.')
        if chapter then set[chapter] = true end
    end
    sections[name] = set
end

local files = {}
for _, dir in ipairs { 'docs', 'slc', 'macro', 'runtime', 'lib', 'examples', 'tests', 'tools' } do
    local p = io.popen(('find %s/%s -maxdepth 2 -type f 2>/dev/null'):format(root, dir))
    for f in p:lines() do
        if f:match('%.md$') or f:match('%.lua$') or f:match('%.slc$') or f:match('%.c$') or f:match('%.h$') then
            files[#files + 1] = f
        end
    end
    p:close()
end

local refs, broken = 0, 0
for _, path in ipairs(files) do
    local text = read(path)
    local line = 0
    for l in ((text or '') .. '\n'):gmatch('([^\n]*)\n') do
        line = line + 1
        -- Let's own syntax.md is numbered on its own; those references are not ours
        if not l:find("Let's `syntax.md`", 1, true) and not l:find('Let syntax', 1, true) then
            for _, doc in ipairs { 'syntax', 'architecture' } do
                for num in l:gmatch(doc .. ' §([%d%.]+)') do
                    refs = refs + 1
                    local key = num:gsub('%.$', '')
                    if not sections[doc][key] then
                        broken = broken + 1
                        print(('%s:%d: %s §%s does not name a section'):format(path, line, doc, num))
                    end
                end
            end
        end
    end
end
print(('%d section references checked, %d broken'):format(refs, broken))
os.exit(bad == 0 and broken == 0 and 0 or 1)
