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

-- Omitted annotations infer native places, on the same prepared IR as C.
local inferred = slc.load(root .. '/examples/inferred_locals.slc')
check('inferred branch true', inferred.inferred_branch(true, 10) == 29)
check('inferred branch false', inferred.inferred_branch(false, 10) == 27)
check('inferred nested loops', inferred.inferred_loops(10) == 103)
check('inferred empty loops', inferred.inferred_loops(0) == 3)
check('inferred snapshots and references', inferred.inferred_snapshot(7) == 25)
check('inferred array and Text constructors', inferred.inferred_storage(8) == 14)
check('mixed explicit and inferred locals', inferred.inferred_mixed(7) == 17)

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

-- Maps share the runtime table algorithm and generated semantic key adapters.
local maps = slc.load(root .. '/examples/maps.slc')
check('Map insertion and checked update', maps.map_tally(1000) == 1000)
check('Map replace, ensure and find snapshots', maps.edit_counts(0xffffffff) == 20)
local label = maps.types.Str { ptr = ffi.cast('uint8_t *', 'cat'), len = 3 }
check('Map Chars key equality', maps.label_count(label) == 3)
ok, err = pcall(maps.absent, 9)
check('Map missing key traps', not ok and tostring(err):find('map-key', 1, true), err)
check('Map after recovered trap', maps.map_tally(23) == 23)
check('Map each snapshots and replacement', maps.map_each_sum(10) == 56)
check('Map nested iteration and callback returns', maps.map_each_nested(10) == 291)
ok, err = pcall(maps.map_each_mutation, 0)
check('Map structural mutation through alias traps', not ok and tostring(err):find('structural mutation', 1, true), err)
check('Map iteration after recovered trap', maps.map_each_sum(10) == 56)
check('Map iteration across task suspension', maps.map_task_each(100) == 5051)

-- stores and Grow arrays: helpers read from the same C the C backend prints
local st = slc.load(root .. '/examples/stores.slc')
check('stores run', type(st.churn) == 'function')

-- Fixed-array values and owner-backed text views at both binding times.
local sv = slc.load(root .. '/examples/staged_values.slc')
local function text(s)
    return sv.types.Str { ptr = ffi.cast('uint8_t *', s), len = #s }
end
check('known Chars empty and exact-capacity construction', sv.stage_empty() and sv.stage_filled(text('abcd')) == 4)
local value = sv.stage_value()
check('known Chars returned by value', value.len == 3 and value.bytes.e[0] == 97 and value.bytes.e[3] == 0)
local binary = sv.stage_binary_value()
check('embedded NUL survives known construction and native return', binary.len == 3
    and binary.bytes.e[0] == 97 and binary.bytes.e[1] == 0 and binary.bytes.e[2] == 98 and binary.bytes.e[3] == 0)
check('live view versus value copy', sv.stage_live(5) == 6 and sv.stage_shorter() and sv.stage_nested())
check('view joins retain branch owners', sv.stage_branch(true) and not sv.stage_branch(false)
    and sv.stage_choose_view(true) and not sv.stage_choose_view(false))
local bytes_ok = true
for byte = 0, 255 do
    bytes_ok = bytes_ok and sv.stage_changed_byte(byte) == byte
        and sv.stage_snapshot(byte) == byte + 90 and sv.stage_escape(byte) == byte
        and sv.stage_partial(text('abc'), byte) == byte + 100 and sv.stage_split(byte) == byte + 100
end
check('all byte values, snapshots and raw address escape', bytes_ok)
check('known text parsing and checked indexing', sv.stage_parse() == -12 and sv.stage_index(2) == 99)
local arrays_ok = sv.stage_array_copy(5) == 31 and sv.stage_array_view() == 16 and sv.stage_array_nested() == 5
for i = 0, 19 do
    arrays_ok = arrays_ok and sv.stage_array_loop(i) == i * (i + 1) / 2
        and sv.stage_view_loop(i) == (i == 0 and 97 or 65 + (i - 1) % 26)
end
check('array copies, views, nested writes and loop widening', arrays_ok)
check('view length is captured independently of live bytes', sv.stage_captured_length(text(''))
    and sv.stage_captured_length(text('abcd')))
check('array joins distinguish signed floating zero', 1 / sv.stage_signed_zero(true) == -math.huge
    and 1 / sv.stage_signed_zero(false) == math.huge)
ok, err = pcall(sv.stage_filled, text('abcde'))
check('dynamic Chars overflow traps', not ok and tostring(err):find('text longer', 1, true), err)
ok, err = pcall(sv.stage_index, 3)
check('dynamic owner-backed view bounds trap', not ok and tostring(err):find('index out of range', 1, true), err)
check('successful call after view trap', sv.stage_live(5) == 6)
check('array/text task captures are independent copies', sv.stage_task_copy(0) == 0
    and sv.stage_task_copy(20) == 40 and sv.stage_task_copy(255) == 510)
ok, err = pcall(sv.stage_dead_write, 2)
check('dead array stores retain bounds checks', sv.stage_dead_write(1) == 1
    and not ok and tostring(err):find('index out of range', 1, true), err)

-- Load the model harness's foreign probes rather than exempting its layouts.
local support = root .. '/build/tmp/map-model-support.so'
local command = ('cc -shared -fPIC -DSLC_MAP_MODEL_SUPPORT_ONLY -I%q %q -o %q')
    :format(root .. '/runtime', root .. '/tests/map_models_main.c', support)
local status = os.execute(command)
check('build map model foreign probes', status == 0)
local model_support = ffi.load(support, true)
local models = slc.load(root .. '/examples/map_models.slc')
check('SLC map models in process', models.map_model(20000, 80, 128)
    and models.strmap_model(20000, 80, 128))
check('SLC map relocation aliases in process', models.map_table_alias(6) == 10
    and models.map_arena_alias(128, 96) == 1064)

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
