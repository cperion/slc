-- One subsystem acceptance: policy models, C/JIT lowering and task integration.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function run(cmd)
    print(cmd)
    local rc = os.execute(cmd)
    assert(rc == 0, 'scheduler check failed: ' .. tostring(rc))
end
local build = root .. '/build/runtime'
run('mkdir -p ' .. q(build))
dofile(root .. '/tests/recursive_foreign.lua')
local policy = require('slc.runtime_build').source()
local runtime = ''
for _, f in ipairs { 'slc_rt.c', 'slc_tasks.c', 'slc_io_posix.c', 'slc_io_poll.c' } do
    runtime = runtime .. ' ' .. q(root .. '/runtime/' .. f)
end
local cc = (os.getenv('CC') or 'cc') .. ' -std=c99 -Wall -Wextra -Werror -pedantic -O2 -pthread -I' .. q(root .. '/runtime')
local driver = (os.getenv('LUA') or 'luajit') .. ' ' .. q(root .. '/slc.lua')
local function model(source, name)
    for _, harness in ipairs { 'runtime_scheduler', 'runtime_channel', 'runtime_lifecycle' } do
        local bin = q(build .. '/' .. name .. '-' .. harness)
        run(cc .. ' ' .. q(source) .. ' ' .. q(root .. '/tests/' .. harness .. '_main.c') .. runtime .. ' -o ' .. bin)
        run(bin)
    end
end
model(policy, 'scheduler-c')
-- No optional skip: this target deliberately requires both supported backends.
local obj = build .. '/scheduler-jit.o'
run('CC=' .. q((os.getenv('CC') or 'cc') .. ' -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE=1')
    .. ' CPATH=' .. q(root .. '/runtime:' .. (os.getenv('CPATH') or '')) .. ' ' .. driver .. ' --gccjit -o ' .. q(obj) .. ' ' .. q(root .. '/runtime/scheduler.slc'))
model(obj, 'scheduler-jit')
for _, name in ipairs { 'channels', 'io' } do
    local c = build .. '/' .. name .. '.c'
    local bin = q(build .. '/' .. name)
    run(driver .. ' -o ' .. q(c) .. ' ' .. q(root .. '/examples/' .. name .. '.slc'))
    run(cc .. ' ' .. q(c) .. ' ' .. q(policy) .. ' ' .. q(root .. '/tests/' .. name .. '_main.c') .. runtime .. ' -o ' .. bin)
    run('SLC_WORKERS=2 ' .. bin)
    run('SLC_SCHED_SEED=7 ' .. bin)
end
print('scheduler subsystem passed')
