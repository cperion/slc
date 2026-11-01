-- Optional real SDL3 + SDL_ttf acceptance, with a font supplied explicitly.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function sh(command)
    local p = assert(io.popen('(' .. command .. ') 2>&1; echo "__rc=$?"'))
    local text = p:read('*a'); p:close()
    local code = tonumber(text:match('__rc=(%d+)%s*$'))
    return code == 0, text:gsub('__rc=%d+%s*$', '')
end
local function run(name, command)
    local ok, text = sh(command)
    assert(ok, name .. ':\n' .. text)
    print('ok    UI: ' .. name)
    if #text > 0 then io.write(text) end
end
if not sh('pkg-config --exists sdl3 sdl3-ttf') then
    print('skip  UI SDL: SDL3/SDL_ttf development packages unavailable'); return
end
local font = os.getenv('SLC_UI_FONT')
if not font then
    local ok, selected = sh("fc-match -f '%{file}' sans")
    if not ok or selected == '' then
        print('skip  UI SDL: set SLC_UI_FONT to a real font file'); return
    end
    font = selected
end
print('UI SDL test font: ' .. font)
local _, flags = sh('pkg-config --cflags --libs sdl3 sdl3-ttf')
flags = flags:gsub('%s+$', '')
local build = root .. '/build/ui'
run('build directory', 'mkdir -p ' .. quote(build))
local compiler = os.getenv('SLC_BIN') or ('luajit ' .. quote(root .. '/slc.lua'))
local common = ' -std=c99 -Wall -Wextra -Werror -pedantic -I' .. quote(root .. '/runtime')
local fixture = quote(root .. '/tests/ui_sdl_main.c') .. ' ' .. quote(root .. '/runtime/slc_rt.c')
local link = ' ' .. flags .. ' -Wl,--wrap=SDL_RenderPresent -Wl,--wrap=TTF_RenderText_Blended -lm -lpthread'
local generated = quote(build .. '/smoke.c')
run('SDL compilation', compiler .. ' -o ' .. generated .. ' ' .. quote(root .. '/examples/ui/smoke.slc'))
local function harness(label, tool, options, object, suffix)
    local binary = quote(build .. '/smoke' .. suffix)
    run(label, tool .. common .. ' ' .. options .. ' ' .. object .. ' ' .. fixture .. link .. ' -o ' .. binary
        .. ' && SDL_VIDEODRIVER=dummy ' .. binary .. ' ' .. quote(font))
end
harness('C real SDL driver', os.getenv('CC') or 'cc', '-O1', generated, '')
if sh('command -v clang') then
    harness('Clang ASan/UBSan SDL driver', 'clang', '-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer', generated, '-san')
else print('skip  UI SDL sanitizers: clang unavailable') end
if pcall(function() require('slc.cjit').lib() end) then
    local object = quote(build .. '/smoke-jit.o')
    run('SDL libgccjit compilation', compiler .. ' --gccjit -o ' .. object .. ' ' .. quote(root .. '/examples/ui/smoke.slc'))
    local policy = require('slc.runtime_build').source('poll')
    harness('libgccjit real SDL driver', os.getenv('CC') or 'cc', '', object .. ' ' .. quote(policy), '-jit')
else print('skip  UI SDL libgccjit: unavailable') end
run('interactive application compilation', compiler .. ' -o ' .. quote(build .. '/main.c') .. ' ' .. quote(root .. '/examples/ui/main.slc'))
run('interactive application link', (os.getenv('CC') or 'cc') .. common .. ' -O1 ' .. quote(build .. '/main.c')
    .. ' ' .. quote(root .. '/examples/ui/entry.c') .. ' ' .. quote(root .. '/runtime/slc_rt.c')
    .. ' ' .. flags .. ' -lm -lpthread -o ' .. quote(build .. '/demo'))
print('UI SDL: all available checks passed')
