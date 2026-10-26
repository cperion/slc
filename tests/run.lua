-- Run every example: compile to C, check the C strictly, link and run its harness.
-- Then check that bad programs fail with the right diagnostic.
--
-- Independent shell steps run concurrently (SLC_TEST_JOBS, default: this
-- machine's CPU count). Checks are still counted, and reported, in a fixed
-- order. SLC_WORKERS is left alone: the runtime scheduler honours it, so test
-- concurrency has its own variable.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
local function sh(cmd)
    local p = io.popen('(' .. cmd .. ') 2>&1; echo "__rc=$?"')
    local out = p:read '*a'
    p:close()
    local rc = tonumber(out:match('__rc=(%d+)%s*$'))
    out = out:gsub('__rc=%d+%s*$', '')
    return rc == 0, out
end
local function sq(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local CC = 'cc -std=c99 -Wall -Wextra -Werror -pedantic -O1 -I' .. root .. '/runtime'
local build = os.getenv('TMPDIR') or '/tmp'
package.path = root .. '/?.lua;' .. package.path
local policy_for = require('slc.runtime_build').source
local policy = policy_for('poll')
local failures, passes = 0, 0
local check   -- reported by every phase; declared before the parallel driver uses it

-- Backend and sanitizer variants repeat one program many times; they catch a
-- different class of bug, not a different feature. Every feature keeps its
-- single compile/run assertion below; these representatives carry the repeats.
local SANITIZED = { staged_values = true }
local HARNESS_SAN = { runtime_scheduler = true, runtime_channel = true }

local function cpus()
    local p = io.popen('nproc 2>/dev/null')
    local n = tonumber((p:read '*a') or '')
    p:close()
    return n or 16
end
local JOBS = math.max(1, tonumber(os.getenv('SLC_TEST_JOBS') or '') or cpus())
-- the compiler under test: the development entry point, or a built binary
local SLC = os.getenv('SLC_BIN') or ('luajit ' .. root .. '/slc.lua')
local par_dir = build .. '/slc_par'

-- Run independent commands at once; results come back in input order.
local function now()
    local ok, ffi = pcall(require, 'ffi')
    if ok then return tonumber(ffi.C.gettimeofday and 0 or 0) end
    return os.time()
end
local start_time = os.time()

-- Run commands a batch at a time and report each as it lands, so a long run
-- still shows progress instead of sitting silent.
local function par(cmds, labels, verdict)
    local results, n = {}, #cmds
    if n == 0 then return results end
    local report = verdict or check
    assert(os.execute('mkdir -p ' .. sq(par_dir)) == 0, 'cannot create ' .. par_dir)
    for first = 1, n, JOBS do
        local last = math.min(first + JOBS - 1, n)
        local list = assert(io.open(par_dir .. '/list', 'w'))
        for i = first, last do
            local base = ('%s/j%06d'):format(par_dir, i)
            local f = assert(io.open(base .. '.sh', 'w'))
            f:write('(', cmds[i], ') >', sq(base .. '.out'), ' 2>&1\n')
            f:write('echo $? >', sq(base .. '.rc'), '\n')
            f:close()
            list:write(base .. '.sh\n')
        end
        list:close()
        os.execute(('xargs -P %d -n 1 sh < %s'):format(last - first + 1, sq(par_dir .. '/list')))
        for i = first, last do
            local base = ('%s/j%06d'):format(par_dir, i)
            local rf = assert(io.open(base .. '.rc'))
            local rc = rf:read '*a'; rf:close()
            local of = assert(io.open(base .. '.out'))
            local out = of:read '*a'; of:close()
            results[i] = { ok = tonumber(rc) == 0, out = out }
            if labels then report(labels[i], results[i].ok, out) end
        end
    end
    return results
end

-- Run a named phase and report how long it took.
local function phase(title)
    local t = os.time()
    io.write(('== %s\n'):format(title)); io.flush()
    return function()
        io.write(('== %s done in %ds\n'):format(title, os.time() - t)); io.flush()
    end
end

check = function(name, ok, detail)
    if ok then passes = passes + 1; print('ok    ' .. name)
    else failures = failures + 1; print('FAIL  ' .. name .. '\n' .. (detail or '')) end
    io.flush()
end

local function sources(p, backend)
    return p .. ' ' .. root .. '/runtime/slc_rt.c ' .. root .. '/runtime/slc_tasks.c '
        .. root .. '/runtime/slc_io_posix.c ' .. root .. '/runtime/' .. (backend or 'slc_io_poll.c')
end
local rt_sources = sources(policy)

local function have(program) return sh('command -v ' .. program) end
local clang = have('clang')

-- Every example compiles on its own; nothing later may read a missing C file.
local examples, names, cpaths = {}, {}, {}
for f in io.popen('ls ' .. root .. '/examples/*.slc'):lines() do
    examples[#examples + 1] = f
    names[#examples] = f:match('([^/]+)%.slc$')
end
local order = {}
for i = 1, #examples do order[i] = i end
table.sort(order, function(a, b) return names[a] < names[b] end)
for i, index in ipairs(order) do
    examples[i], names[i] = examples[index], names[index]
    cpaths[i] = build .. '/slc_' .. names[i] .. '.c'
end

local compiled, strict = {}, {}
do
    local done = phase('compile examples')
    local cmds, labels = {}, {}
    for i, f in ipairs(examples) do
        cmds[i] = ('%s -o %s %s'):format(SLC, cpaths[i], f)
        labels[i] = names[i] .. ': compile'
    end
    local results = par(cmds, labels)
    for i = 1, #examples do compiled[i] = results[i].ok end
    done()

    done = phase('strict C')
    local strict_cmds, strict_labels, at, labels_of = {}, {}, {}, {}
    for i = 1, #examples do
        if compiled[i] then
            at[#at + 1] = i
            strict_cmds[#strict_cmds + 1] = ('%s -c %s -o %s.o'):format(CC, cpaths[i], cpaths[i])
            labels_of[#labels_of + 1] = names[i] .. ': strict C'
        end
    end
    local strict_results = par(strict_cmds, labels_of)
    for n, i in ipairs(at) do strict[i] = strict_results[n].ok end
    done()
end

-- Link and run each harness against the C backend.
local ran, mains = {}, {}
do
    local done = phase('run harnesses')
    local cmds, at, labels = {}, {}, {}
    for i = 1, #examples do
        local main = root .. '/tests/' .. names[i] .. '_main.c'
        local fh = io.open(main)
        mains[i] = fh and main or nil
        if fh then fh:close() end
        if strict[i] and mains[i] then
            cmds[#cmds + 1] = ('%s %s %s %s -pthread -o %s.bin && %s.bin')
                :format(CC, cpaths[i], mains[i], rt_sources, sq(cpaths[i]), sq(cpaths[i]))
            at[#at + 1] = i
            labels[#labels + 1] = names[i] .. ': run'
        end
    end
    local results = par(cmds, labels)
    for n, i in ipairs(at) do ran[i] = results[n].ok end
    done()
end

-- Variants of the examples that did run: optimization levels, sanitizers, the
-- other I/O backends, a seeded schedule, and thread checking where it applies.
do
    local cmds, apply = {}, {}
    local function add(label, cmd)
        cmds[#cmds + 1] = cmd
        apply[#apply + 1] = label
    end
    for i, name in ipairs(names) do
        if ran[i] then
            local c, main = cpaths[i], mains[i]
            if SANITIZED[name] and clang then
                add(name .. ': ASan/UBSan',
                    ('clang -std=c99 -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all '
                    .. '-I%s %s -pthread -o %s.asan && ASAN_OPTIONS=detect_leaks=1 %s.asan')
                    :format(sq(root .. '/runtime'), c .. ' ' .. main .. ' ' .. rt_sources, sq(c), sq(c)))
            end
            if name == 'staged_values' then
                for _, word in ipairs { 'stage_empty', 'stage_value', 'stage_binary_value', 'stage_live', 'stage_shorter', 'stage_nested', 'stage_parse', 'stage_split' } do
                    local generated = assert(io.open(c))
                    local source = generated:read('*a'); generated:close()
                    local body = source:match(word .. '%b()%s*(%b{})')
                    check(word .. ': known construction leaves no copy loop',
                        body and not body:find('for%s*%(') and not body:find('while%s*%('))
                end
            elseif name == 'strmaps' or name == 'maps' then
                local generated = assert(io.open(c))
                local source = generated:read('*a'); generated:close()
                local word = name == 'maps' and 'edit_counts' or 'strmap_lookup'
                local body = source:match(word .. '%b()%s*(%b{})')
                local staged = body and body:find('slc_hash_seed_word', 1, true)
                for _, helper in ipairs { 'begin', 'init', 'bytes', 'u64', 'end' } do
                    if body and body:find('slc_hash_' .. helper .. '(', 1, true) then staged = false end
                end
                check(name .. ': hashing is SLC, not an opaque C helper', not not staged)
                local native_algorithm = false
                for _, helper in ipairs { 'slc_map_probe', 'slc_map_insert', 'slc_map_remove',
                    'slc_strmap_find', 'slc_strmap_insert', 'slc_strmap_remove' } do
                    if source:find(helper .. '(', 1, true) then native_algorithm = true end
                end
                check(name .. ': no opaque native map algorithms', not native_algorithm)
            elseif name == 'known_maps' then
                local generated = assert(io.open(c))
                local source = generated:read('*a'); generated:close()
                local body = source:match('known_constant%b()%s*(%b{})')
                check('known maps: lookup folds to its value', body and body:find('return 13u;', 1, true))
                check('known maps: no mutable native heap', not source:find('slc_map_new', 1, true)
                    and not source:find('slc_strmap_new', 1, true))
            end
            if name == 'io' then
                local base = root .. '/runtime/slc_rt.c ' .. root .. '/runtime/slc_tasks.c ' .. root .. '/runtime/slc_io_posix.c '
                local backends = { { 'io_uring', 'slc_io_uring.c', '' } }
                if io.open('/usr/include/kqueue/sys/event.h') then
                    backends[#backends + 1] = { 'kqueue', 'slc_io_kqueue.c', '-I/usr/include/kqueue -lkqueue' }
                end
                for _, be in ipairs(backends) do
                    local src = policy_for(be[1] == 'io_uring' and 'uring' or be[1]) .. ' ' .. base .. root .. '/runtime/' .. be[2]
                    add(name .. ': run on ' .. be[1],
                        ('%s %s %s %s -pthread %s -o %s.%s && %s.%s'):format(CC, c, main, src, be[3],
                            sq(c), be[1], sq(c), be[1]))
                end
                local src = policy_for('poll') .. ' ' .. base .. root .. '/runtime/slc_io_poll.c'
                add(name .. ': run on poll',
                    ('%s %s %s %s -pthread -o %s.poll && %s.poll'):format(CC, c, main, src, sq(c), sq(c)))
                if clang then
                    add(name .. ': ThreadSanitizer on poll',
                        ('clang -std=c99 -Wall -Wextra -Werror -O1 -g -fsanitize=thread -I%s/runtime %s %s %s -pthread '
                        .. '-o %s.tsan_poll && %s.tsan_poll'):format(root, c, main, src, sq(c), sq(c)))
                end
            end
            if name == 'channels' then
                add(name .. ': deterministic schedule', ('SLC_SCHED_SEED=7 %s.bin'):format(sq(c)))
            end
            if (name == 'atomics' or name == 'channels') and clang then
                add(name .. ': ThreadSanitizer',
                    ('clang -std=c99 -Wall -Wextra -Werror -O1 -g -fsanitize=thread -I%s/runtime %s %s %s -pthread '
                    .. '-o %s.tsan && %s.tsan'):format(root, c, main, rt_sources, sq(c), sq(c)))
            end
        end
    end
    par(cmds, apply, function(label, ok, out)
        if label:find('ThreadSanitizer', 1, true) then ok = ok and not out:find('ThreadSanitizer') end
        check(label, ok, out)
    end)
end

local oka, erra = pcall(dofile, root .. '/tests/array_value.lua')
check('immutable array contents: persistence and sparse zeros', oka, erra)
local okm, errm = pcall(dofile, root .. '/tests/map_types.lua')
check('map types: recursive key/value rules', okm, errm)

local okr, errr = pcall(dofile, root .. '/tests/recursive_foreign.lua')
check('recursive foreign layouts: construction and rejection', okr, errr)

-- Runtime policy and storage models, before the compiler-facing tests.
do
    local harnesses = { 'map_hash', 'map_runtime', 'strmap_runtime', 'runtime_scheduler', 'runtime_channel', 'runtime_lifecycle' }
    local cmds, apply = {}, {}
    local function add(label, cmd) cmds[#cmds + 1] = cmd; apply[#apply + 1] = label end
    for _, harness in ipairs(harnesses) do
        local sources_text = { sq(policy) }
        for _, f in ipairs { 'tests/' .. harness .. '_main.c', 'runtime/slc_rt.c', 'runtime/slc_tasks.c',
            'runtime/slc_io_posix.c', 'runtime/slc_io_poll.c' } do
            sources_text[#sources_text + 1] = sq(root .. '/' .. f)
        end
        local input = table.concat(sources_text, ' ') .. ' -pthread -I' .. sq(root .. '/runtime')
        local bin = sq(build .. '/slc_' .. harness)
        add(harness .. ': runtime', 'cc -std=c99 -Wall -Wextra -Werror -pedantic -O1 '
            .. input .. ' -o ' .. bin .. ' && ' .. bin)
        if HARNESS_SAN[harness] and clang then
            local bin = sq(build .. '/slc_' .. harness .. '.san')
            add(harness .. ': ASan/UBSan', 'clang -std=c99 -Wall -Wextra -Werror -O1 -g '
                .. '-fsanitize=address,undefined -fno-sanitize-recover=all ' .. input .. ' -o ' .. bin .. ' && ' .. bin)
        end
    end
    par(cmds, apply)
    if not clang then print('skip  runtime harness sanitizers: clang not found') end
end

-- Text's C helper accepts unrelated buffers and self-aliases across growth.
-- Keep pointer comparisons separate from UBSan's pointer-overflow instrumentation.
-- Pointer-subtract instrumentation also flags intentional uintptr_t address math.
do
    local rt = policy .. ' ' .. root .. '/runtime/slc_rt.c ' .. root .. '/runtime/slc_tasks.c '
        .. root .. '/runtime/slc_io_posix.c ' .. root .. '/runtime/slc_io_poll.c'
    local main = root .. '/tests/text_runtime_main.c'
    local bin = build .. '/slc_text_runtime'
    local cmds = { ('%s %s %s -pthread -o %s && %s'):format(CC, main, rt, sq(bin), sq(bin)) }
    local apply = { 'Text runtime: aliases and buffer growth' }
    if clang then
        for _, flags in ipairs { 'address,undefined', 'address,pointer-compare' } do
            cmds[#cmds + 1] = ('clang -std=c99 -Wall -Wextra -Werror -O1 -g -fsanitize=%s '
                .. '-fno-sanitize-recover=all -fno-omit-frame-pointer -I%s/runtime %s %s -pthread -o %s.%s '
                .. '&& ASAN_OPTIONS=detect_leaks=1:detect_invalid_pointer_pairs=2 %s.%s')
                :format(flags, root, main, rt, sq(bin), flags, sq(bin), flags)
            apply[#apply + 1] = 'Text runtime: ' .. flags
        end
    else
        print('skip  Text runtime sanitizers: clang not found')
    end
    par(cmds, apply)
end

-- the gccjit backend: the same harnesses, linked against libgccjit's object
-- files, and the in-process backend
local have_jit = sh(('luajit -e "package.path=[[%s/?.lua;]]..package.path; require([[slc.cjit]]).lib()"'):format(root))
if have_jit then
    local objects, built = {}, {}
    do
        local cmds = {}
        for i, f in ipairs(examples) do
            objects[i] = build .. '/slc_jit_' .. names[i] .. '.o'
            cmds[i] = ('%s --gccjit -o %s %s'):format(SLC, objects[i], f)
        end
        local labels = {}
        for i = 1, #examples do labels[i] = names[i] .. ': gccjit object' end
        local results = par(cmds, labels)
        for i = 1, #examples do built[i] = results[i].ok end
    end
    do
        local cmds, apply = {}, {}
        local function add(label, cmd) cmds[#cmds + 1] = cmd; apply[#apply + 1] = label end
        for i, name in ipairs(names) do
            if built[i] and mains[i] then
                local o = objects[i]
                add(name .. ': gccjit run',
                    ('%s %s %s %s -pthread -o %s.bin && %s.bin'):format(CC, o, mains[i], rt_sources, sq(o), sq(o)))
                if name == 'channels' then
                    add(name .. ': gccjit deterministic schedule', ('SLC_SCHED_SEED=7 %s.bin'):format(sq(o)))
                end
                if name == 'io' then
                    add(name .. ': gccjit run on io_uring',
                        ('%s %s %s %s -pthread -o %s.uring && %s.uring')
                        :format(CC, o, mains[i], sources(policy_for('uring'), 'slc_io_uring.c'), sq(o), sq(o)))
                end
            end
        end
        par(cmds, apply)
    end
    local okn, outn = sh(('luajit %s/tests/native.lua'):format(root))
    check('in-process backend', okn, outn)
else
    print('skip  gccjit backend: libgccjit not found')
end

-- the differential fuzzer: its saved findings, and a few new programs
if have_jit then
    local results = par {
        ('luajit %s/tests/fuzz/fuzz.lua --regressions'):format(root),
        ('luajit %s/tests/fuzz/fuzz.lua --seed 424242 --count 5 --no-shrink'):format(root),
        ('luajit %s/tests/fuzz/tasks.lua --quick'):format(root),
        ('luajit %s/tests/fuzz/storage.lua --count 8'):format(root),
    }
    check('fuzz regressions agree on every run', results[1].ok, results[1].out)
    check('fuzz: 5 programs agree on every run', results[2].ok, results[2].out)
    check('task fuzzer agrees across schedules', results[3].ok, results[3].out)
    check('storage model fuzzer agrees with the model', results[4].ok, results[4].out)
end

-- programs that must be rejected, with a fragment of the expected message
do
    local bad = dofile(root .. '/tests/errors.lua')
    local cmds, labels, by_label = {}, {}, {}
    for i, case in ipairs(bad) do
        local path = ('%s/bad_%04d.slc'):format(par_dir, i)
        local fh = assert(io.open(path, 'w')); fh:write(case.src); fh:close()
        cmds[i] = ('%s %s'):format(SLC, sq(path))
        labels[i] = 'rejects: ' .. case.name
        by_label[labels[i]] = case
    end
    par(cmds, labels, function(label, ran_ok, out)
        local case = by_label[label]
        local expected = (not ran_ok) and out:find(case.expect, 1, true)
        if expected and case.line then expected = out:find(':' .. case.line .. ':', 1, true) end
        check(label, expected, out)
    end)
end

-- the generated C keeps the checks nothing proves, and drops the ones a branch proved
do
    local expectations = {
        { 'memory_views', 'if ((uint64_t)(i + 1u - 1u) >= (uint64_t)xs.len)', true,
          'an index no fact covers stays checked' },
        { 'memory_views', 'if ((uint64_t)i >= (uint64_t)xs.len)', false,
          'an index the branch proved is not checked' },
        { 'activities', 'at->value = at->value * 2u;\n    at->weight = at->weight + 1u;', true,
          'one checked lookup serves the whole stretch' },
        { 'activities', 'NodeStore_borrow', false, 'no C helper for a store lookup' },
    }
    local cmds = {}
    for i, x in ipairs(expectations) do
        cmds[i] = ('%s %s/examples/%s.slc'):format(SLC, root, x[1])
    end
    local labels = {}
    for i, x in ipairs(expectations) do labels[i] = 'codegen: ' .. x[4] end
    local results = par(cmds)
    for i, x in ipairs(expectations) do
        local has = results[i].out:find(x[2], 1, true) ~= nil
        check(labels[i], results[i].ok and has == x[3], x[2])
    end
end

local docs = par {
    ('luajit %s/tests/listings.lua'):format(root),
    ('luajit %s/tests/guide.lua'):format(root),
}
check('spec listings are real output', docs[1].ok, docs[1].out)
check('guide examples are real', docs[2].ok, docs[2].out)

print(('%d passed, %d failed'):format(passes, failures))
os.exit(failures == 0 and 0 or 1)
