-- docs/designing-and-writing-slc.md cannot drift: every ```lua block is an
-- excerpt of examples/guide.slc, and every top-level piece of a ```c block
-- appears verbatim in that file's generated C.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
local src = assert(io.open(root .. '/examples/guide.slc')):read '*a'
local p = io.popen(('luajit %s/slc.lua %s/examples/guide.slc 2>&1'):format(root, root))
local out = p:read '*a'
p:close()
local doc = assert(io.open(root .. '/docs/designing-and-writing-slc.md')):read '*a'
local nl, nc, bad = 0, 0, 0
for block in doc:gmatch('```lua\n(.-)```') do
    nl = nl + 1
    if not src:find(block, 1, true) then
        bad = bad + 1
        print('NOT IN examples/guide.slc (lua block ' .. nl .. '):\n' .. block)
    end
end
for block in doc:gmatch('```c\n(.-)```') do
    nc = nc + 1
    for piece in (block .. '\n\n'):gmatch('(.-)\n\n+') do
        if piece:match('%S') and not out:find(piece, 1, true) then
            bad = bad + 1
            print('NOT IN OUTPUT (c block ' .. nc .. '):\n' .. piece .. '\n')
        end
    end
end
print(('%d lua and %d c blocks checked, %d missing'):format(nl, nc, bad))
os.exit(bad == 0 and 0 or 1)
