-- The task fuzzer: programs whose result cannot depend on the schedule.
--
--   luajit tests/fuzz/tasks.lua [--seeds N] [--quick]
--
-- Each template runs under SLC_SCHED_SEED=0..N-1 (no worker threads: the seeded
-- choice drives everything) and with SLC_WORKERS=4 (real threads). Every run
-- must print the same bytes. A template that is meant to deadlock must print
-- the same report, naming the same wait, on every run.
--
-- The templates are written, not generated: the scheduling surface is small and
-- a template that reads clearly is worth more than a generator here. Each one
-- keeps its result commutative or unique, so only a scheduling bug can change
-- the output.

local root = arg[0]:match('^(.*)/tests/fuzz/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path

local opts = { seeds = 20 }
for i = 1, #arg do
    local a = arg[i]
    if a == '--quick' then opts.seeds, opts.workers = 3, 1
    elseif a == '--seeds' then i = i + 1; opts.seeds = tonumber(arg[i])
    end
end
opts.workers = opts.workers or 2

-- unique per process: two task-fuzzer runs in the same second must not share one
local STAMP = tostring(os.time()) .. '_' .. tostring({}):match('0x(%x+)')
local TMP = (os.getenv('TMPDIR') or '/tmp') .. '/slc_tasks_' .. STAMP
os.execute('mkdir -p ' .. TMP)
-- the compiler to call for generated programs: this binary when embedded
local SLC = os.getenv('SLC_DIST') and ('%q'):format(os.getenv('SLC_DIST')) or ('luajit %q/slc.lua'):format(root)
-- the runtime as the embedding binary carries it (a prebuilt archive), or the
-- sources in a development tree
local RT = os.getenv('SLC_RT') and ('%q'):format(os.getenv('SLC_RT'))
    or (require('slc.runtime_build').source() .. ' ' .. root .. '/runtime/slc_rt.c ' .. root .. '/runtime/slc_tasks.c '
        .. root .. '/runtime/slc_io_posix.c ' .. root .. '/runtime/slc_io_poll.c')

local function sh(cmd)
    local p = io.popen('(' .. cmd .. ') 2>&1; echo "__rc=$?"')
    local out = p:read '*a'
    p:close()
    local rc = tonumber(out:match('__rc=(%d+)%s*$'))
    return rc == 0, (out:gsub('__rc=%d+%s*$', ''))
end

local function sq(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function write(name, text)
    local f = assert(io.open(TMP .. '/' .. name, 'w'))
    f:write(text)
    f:close()
end

-- the templates ---------------------------------------------------------------------------------

local TEMPLATES = {
    {
        name = 'pipeline',
        expect = 'total = 332833500',
        source = [[
local libc = require "slc.libc"

-- one producer, one squarer, the main thread sums: the sum cannot depend on order
local run = do(): Unit
    local total: U64 = 0
    tasks do(scope...)
        local nums = channel(U64, 8)
        local ch = channel(U64, 8)
        spawn do
            local i: U64 = 0
            while i < 1000 do
                nums:send(i)
                i = i + 1
            end
            nums:close()
        end
        spawn do
            nums:each(do(v)
                ch:send(v * v)
            end)
            ch:close()
        end
        ch:each(do(v)
            total = total + v
        end)
    end
    libc.say("total = ", total)
end
export run
]],
    },
    {
        name = 'workers',
        expect = 'steps = 8418',
        source = [[
local libc = require "slc.libc"
local Job = struct { n: U32 }
local Done = struct { steps: U32 }

local collatz = do(n: U32): U32
    local steps: U32 = 0
    local x: U64 = U64(n)
    while x ~= 1 do
        if band(x, 1) == 0 then
            x = shr(x, 1)
        else
            x = 3 * x + 1
        end
        steps = steps + 1
    end
    return steps
end

local worker = do(jobs: Chan Job, results: Chan Done): Unit
    jobs:each(do(j)
        results:send(Done { steps = collatz(j.n) })
    end)
end

-- four workers share the jobs; every job is counted once
local run = do(): Unit
    local total: U64 = 0
    tasks do(scope...)
        local jobs = channel(Job, 4)
        local results = channel(Done, 4)
        spawn do
            for i: U32 = 1, 200 do
                jobs:send(Job { n = i })
            end
            jobs:close()
        end
        for _ = 1, 4 do
            spawn(worker, jobs, results)
        end
        for _: U32 = 1, 200 do
            results:recv() {
                value = do(d) total = total + U64(d.steps) end,
                closed = do end,
            }
        end
    end
    libc.say("steps = ", total)
end
export run
]],
    },
    {
        name = 'pool',
        expect = 'bytes = 64000',
        source = [[
local libc = require "slc.libc"
local Buffer = struct { n: U32, bytes: Array(U8, 64) }

-- buffers move through a pool; the total of their sizes is fixed
local run = do(): Unit
    local total: U64 = 0
    local count: U32 = 0
    tasks do(scope...)
        local buffers = pool(Buffer, 4)
        local full = channel(Slot Buffer, 4)
        spawn do
            local sent: U32 = 0
            while sent < 1000 do
                local s = buffers:take()
                buffers[s].n = 64
                buffers[s].bytes[0] = U8 1
                full:send(s)
                sent = sent + 1
            end
            full:close()
        end
        full:each(do(s)
            total = total + U64(buffers[s].n)
            buffers:release(s)
        end)
    end
    libc.say("bytes = ", total)
end
export run
]],
    },
    {
        name = 'first_of',
        expect = 'case = channel 4950',
        source = [[
local libc = require "slc.libc"

-- the channel case is ready, the timer is far away: whoever runs first, the
-- channel wins and the sum is the same
local run = do(): Unit
    local sum: U64 = 0
    local chosen: U32 = 0
    tasks do(scope...)
        local ready = channel(U64, 16)
        spawn do
            local i: U64 = 0
            while i < 100 do
                ready:send(i)
                i = i + 1
            end
            ready:close()
        end
        while true do
            local more: Bool = true
            first_of {
                recv(ready) do(v)
                    sum = sum + v
                    chosen = 1
                end,
                after(seconds(10)) do
                    more = false
                    chosen = 2
                end,
                closed = do more = false end,
            }
            if not more then break end
        end
    end
    libc.say("case = channel ", sum)
end
export run
]],
    },
    {
        name = 'deadlock',
        deadlock = true,
        expect = 'deadlock: every task is waiting',
        source = [[
local libc = require "slc.libc"

-- nobody ever sends: the scope end must report the same deadlock everywhere
local run = do(): Unit
    tasks do(scope...)
        local never = channel(U32, 0)
        spawn do
            never:recv() {
                value = do(v) libc.say("value = ", v) end,
                closed = do end,
            }
        end
    end
    libc.say("unreachable")
end
export run
]],
    },
}

-- the driver ------------------------------------------------------------------------------------

local fails, runs = 0, 0
local function fail(what) fails = fails + 1; print('MISMATCH ' .. what) end

for _, t in ipairs(TEMPLATES) do
    write(t.name .. '.slc', t.source)
    local ok, out = sh((SLC .. ' -o %q %q'):format(TMP .. '/' .. t.name .. '.c', TMP .. '/' .. t.name .. '.slc'))
    if not ok then
        fail(t.name .. ': compile')
        print(out)
        goto continue
    end
    write(t.name .. '_main.c', 'int run(void);\nint main(void) { return run(); }\n')
    ok, out = sh(('cc -std=c99 -Wall -Wextra -Werror -pedantic -O2 -pthread -I%q %q %q %s -o %q'):format(
        root .. '/runtime', TMP .. '/' .. t.name .. '.c', TMP .. '/' .. t.name .. '_main.c', RT, TMP .. '/' .. t.name .. '.bin'))
    if not ok then
        fail(t.name .. ': link')
        print(out)
        goto continue
    end

    local first
    local function once(env, desc)
        runs = runs + 1
        local cmd = ('%s timeout 60 %q'):format(env, TMP .. '/' .. t.name .. '.bin')
        local _, text = sh(cmd)
        if first == nil then
            first = text
            if not text:find(t.expect, 1, true) then
                fail(('%s: %s does not contain %q'):format(t.name, desc, t.expect))
                print(text)
            end
        elseif text ~= first then
            fail(('%s: %s disagrees:\n--- first\n%s\n--- now\n%s'):format(t.name, desc, first, text))
        end
    end
    for s = 0, opts.seeds - 1 do once(('SLC_SCHED_SEED=%d'):format(s), 'seed ' .. s) end
    for w = 1, opts.workers do once('SLC_WORKERS=4', 'workers run ' .. w) end
    if t.deadlock and not (first or ''):find('deadlock', 1, true) then
        fail(t.name .. ': no deadlock report')
    end
    ::continue::
end

os.execute('rm -rf ' .. sq(TMP))
print(('%d task templates, %d runs, %d mismatches'):format(#TEMPLATES, runs, fails))
os.exit(fails == 0 and 0 or 1)
