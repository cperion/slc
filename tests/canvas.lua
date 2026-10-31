-- Optional SDL3 case study: real headers, deterministic boundary, real driver.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function sh(command)
    local p = assert(io.popen('(' .. command .. ') 2>&1; echo "__rc=$?"'))
    local text = p:read '*a'; p:close()
    local code = tonumber(text:match('__rc=(%d+)%s*$'))
    return code == 0, text:gsub('__rc=%d+%s*$', '')
end
local function run(label, command)
    local ok, text = sh(command)
    assert(ok, label .. ':\n' .. text)
    print('ok    canvas: ' .. label)
    if #text > 0 then io.write(text) end
end
local available = sh('pkg-config --exists sdl3')
if not available then print('skip  canvas: SDL3 development package unavailable'); return end
local _, cflags = sh('pkg-config --cflags sdl3')
local _, libs = sh('pkg-config --libs sdl3')
cflags, libs = cflags:gsub('%s+$', ''), libs:gsub('%s+$', '')
local build = root .. '/build/canvas'
run('build directory', 'mkdir -p ' .. quote(build))
local compiler = os.getenv('SLC_BIN') or ('luajit ' .. quote(root .. '/slc.lua'))
local cc = (os.getenv('CC') or 'cc') .. ' -std=c99 -O2 -Wall -Wextra -Werror -pedantic -I' .. quote(root .. '/runtime') .. ' ' .. cflags
local source = quote(root .. '/tests/canvas.slc')
local function harness(label, object, suffix, flags, tool)
    local cc = tool or cc
    local binary = quote(build .. '/test' .. suffix)
    run(label .. ' fault injection', cc .. ' ' .. flags .. ' ' .. object .. ' ' .. quote(root .. '/tests/canvas_main.c') .. ' -o ' .. binary .. ' && ' .. binary)
    binary = quote(build .. '/smoke' .. suffix)
    run(label .. ' real dummy driver', cc .. ' ' .. flags .. ' ' .. object .. ' ' .. quote(root .. '/tests/canvas_smoke.c') .. ' ' .. libs .. ' -o ' .. binary .. ' && SDL_VIDEODRIVER=dummy ' .. binary)
end
local generated = build .. '/test.c'
run('C compilation', compiler .. ' -o ' .. quote(generated) .. ' ' .. source)
harness('C', quote(generated), '', '')
local f = assert(io.open(generated)); local text = f:read '*a'; f:close()
assert(text:find('SDL_PollEvent(', 1, true) and text:find('SDL_RenderPresent(', 1, true))
for _, name in ipairs { 'View_interact(', 'Frame_fill_rect(', 'with_video(', 'with_frame(' } do
    assert(not text:find(name, 1, true), 'activity wrapper survived specialization: ' .. name)
end
print('ok    canvas: activity wrappers specialize into SDL calls')
-- Match tests/run.lua: sanitizer variants use Clang, not GCC's optional
-- libasan/libubsan packages. A failed sanitizer run remains a failure.
if sh('command -v clang') then
    local clang = 'clang -std=c99 -O1 -g -Wall -Wextra -Werror -pedantic -I' .. quote(root .. '/runtime') .. ' ' .. cflags
    harness('Clang ASan/UBSan', quote(generated), '-san',
        '-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer', clang)
else
    print('skip  canvas sanitizers: clang not found')
end
local jit = pcall(function() require('slc.cjit').lib() end)
if jit then
    local object = quote(build .. '/test-jit.o')
    run('libgccjit compilation', compiler .. ' --gccjit -o ' .. object .. ' ' .. source)
    harness('libgccjit', object, '-jit', '')
else
    print('skip  canvas: libgccjit unavailable')
end
run('interactive example C compilation', compiler .. ' -o ' .. quote(build .. '/main.c') .. ' ' .. quote(root .. '/examples/canvas/main.slc'))
-- The diagnostic printer reaches checked byte reads, so its C carries the
-- corresponding SLC runtime words and links the minimal trap mechanism.
run('interactive example link', cc .. ' ' .. quote(build .. '/main.c') .. ' ' .. quote(root .. '/examples/canvas/entry.c') .. ' ' .. quote(root .. '/runtime/slc_rt.c') .. ' ' .. libs .. ' -o ' .. quote(build .. '/demo'))
print('canvas: all available checks passed')
