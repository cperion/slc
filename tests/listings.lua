-- Every C listing in the spec must be the compiler's actual output: each
-- top-level piece of a ```c block must appear verbatim in the C generated
-- from examples/. (Sketches are exempt: §16's convention, and §36's design.)
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
local blob = {}
for f in io.popen('ls ' .. root .. '/examples/*.slc'):lines() do
    local p = io.popen(('luajit %s/slc.lua %s 2>&1'):format(root, f))
    blob[#blob + 1] = p:read '*a'
    p:close()
end
blob = table.concat(blob, '\n')
local doc = assert(io.open(root .. '/docs/staged-lua-c-v0.5.md')):read '*a'
local n, bad = 0, 0
for block in doc:gmatch('```c\n(.-)```') do
    if not block:find('...);', 1, true) and not block:find('/* sketch */', 1, true) then
        n = n + 1
        -- pieces separated by blank lines
        for piece in (block .. '\n\n'):gmatch('(.-)\n\n+') do
            if piece:match('%S') and not blob:find(piece, 1, true) then
                bad = bad + 1
                print('NOT IN OUTPUT (listing ' .. n .. '):\n' .. piece .. '\n')
            end
        end
    end
end
print(('%d listings checked, %d pieces missing'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
