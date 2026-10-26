-- The in-process backend: programs compiled by libgccjit into this process
-- and called from Lua, a failed check raised as a Lua error, and native(word)
-- specializing on values that exist only at run time.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
local saved_arg = arg
arg = { [0] = root .. '/slc.lua' }
package.loaded['slc.driver_loaded'] = true
local slc = dofile(root .. '/slc.lua')
arg = saved_arg
local ffi = require 'ffi'

local fails, n = 0, 0
local function check(name, ok, detail)
    n = n + 1
    if not ok then fails = fails + 1; print('FAIL  native: ' .. name .. (detail and ('\n' .. tostring(detail)) or '')) end
end

-- the guide's program
local g = slc.load(root .. '/examples/guide.slc')
check('outline_demo', g.outline_demo(5) == 10)
check('tab_stop_4', g.tab_stop_4(5) == 8)
check('ask (first_of, a timer, a task)', g.ask() == 42)
local Document = g.types.Document
local doc = Document { length = 3, cursor = 3, edits = 0 }
check('type_word through a Ref', g.type_word(doc, 4) == 1 and doc.length == 7 and doc.cursor == 6 and doc.edits == 1)

-- tasks, channels, pools, blocking
local ch = slc.load(root .. '/examples/channels.slc')
local sq = 0
for i = 0, 999 do sq = sq + i * i end
check('sum_squares', ch.sum_squares(1000) == sq)
check('tally', ch.tally(100, 40) == 100 * 101 / 2 - 40 * 41 / 2)
check('take_or_time', ch.take_or_time() == 111)
check('parallel_sleeps', ch.parallel_sleeps(4) == 200)

-- a failed check in plain code is a Lua error, and the process goes on
local arr = slc.load(root .. '/examples/arrays.slc')
local a = arr.types.U32x4 { e = { 5, 6, 7, 8 } }
check('pick', arr.pick(a, 2) == 7)
local ok, err = pcall(arr.pick, a, 9)
check('a trap becomes an error', not ok and tostring(err):find('slice index out of range', 1, true), err)
check('and the process goes on', arr.pick(a, 3) == 8)

-- a stale channel handle traps too, after its scope has ended
local h = ch.types.Holder()
ok, err = pcall(ch.use_after_scope, h)
check('stale handle', not ok and tostring(err):find('slc runtime check failed', 1, true), err)
check('still running', ch.late_reply() == 42)

-- stores and Grow arrays: helpers read from the same C the C backend prints
local st = slc.load(root .. '/examples/stores.slc')
check('stores run', type(st.churn) == 'function')

-- every record of every example: the layout this backend assumes is the C layout
for f in io.popen('ls ' .. root .. '/examples/*.slc'):lines() do
    local okl, e = pcall(slc.load, f, { check_layouts = true })
    -- two examples call C functions their harness defines: not in this process
    local foreign = not okl and tostring(e):find('is not defined in this process', 1, true)
        and (f:find('activities') or f:find('spec_core'))
    check('layouts of ' .. f:match('[^/]+$'), okl or foreign, e)
end

-- run: native(word) specialized on a value that arrives at run time
local prog = os.tmpname() .. '.slc'
local f = assert(io.open(prog, 'w'))
f:write([[
local tab_stop = do(config, column: U32): U32
    local width: U32 = config.tab_width
    return (column / width + 1) * width
end
local width = tonumber(arg[1])
local stop = native(tab_stop { tab_width = width })
io.write(stop(5), "\n")
local main = do(): I32
    return 3
end
export main
]])
f:close()
local p = io.popen(('luajit %s/slc.lua run %s 8; echo "rc=$?"'):format(root, prog))
local out = p:read '*a'
p:close()
os.remove(prog)
check('slc run, native(word), exit status from main', out == '8\nrc=3\n', out)

-- a decoder made for its file: the header names the field, the first row its decimals
p = io.popen(('luajit %s/slc.lua run %s/examples/csv.slc %s/examples/data/sales.csv price'):format(root, root, root))
out = p:read '*a'
p:close()
check('csv decoder specialized on its header', out:find('5 rows, sum 128.29, min -1.25, max 100', 1, true), out)

print(('%d native checks, %d failed'):format(n, fails))
os.exit(fails == 0 and 0 or 1)
