-- Run every example: compile to C, check the C strictly, link and run its harness.
-- Then check that bad programs fail with the right diagnostic.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
local function sh(cmd)
    local p = io.popen('(' .. cmd .. ') 2>&1; echo "__rc=$?"')
    local out = p:read '*a'
    p:close()
    local rc = tonumber(out:match('__rc=(%d+)%s*$'))
    out = out:gsub('__rc=%d+%s*$', '')
    return rc == 0, out
end
local CC = 'cc -std=c99 -Wall -Wextra -Werror -pedantic -O1 -I' .. root .. '/runtime'
local build = os.getenv('TMPDIR') or '/tmp'
local failures, passes = 0, 0
local function check(name, ok, detail)
    if ok then passes = passes + 1; print('ok    ' .. name)
    else failures = failures + 1; print('FAIL  ' .. name .. '\n' .. (detail or '')) end
end

local examples = {}
for f in io.popen('ls ' .. root .. '/examples/*.slc'):lines() do examples[#examples + 1] = f end
for _, f in ipairs(examples) do
    local name = f:match('([^/]+)%.slc$')
    local c = build .. '/slc_' .. name .. '.c'
    local ok, out = sh(('luajit %s/slc.lua -o %s %s'):format(root, c, f))
    check(name .. ': compile', ok, out)
    if ok then
        local okc, outc = sh(('%s -c %s -o %s.o'):format(CC, c, c))
        check(name .. ': strict C', okc, outc)
        local main = root .. '/tests/' .. name .. '_main.c'
        local fh = io.open(main)
        if fh and okc then
            fh:close()
            local rt = root .. '/runtime/slc_rt.c ' .. root .. '/runtime/slc_tasks.c ' .. root .. '/runtime/slc_io_posix.c '
                .. root .. '/runtime/slc_io_poll.c'
            local okl, outl = sh(('%s %s %s %s -pthread -o %s.bin && %s.bin'):format(CC, c, main, rt, c, c))
            check(name .. ': run', okl, outl)
            if okl and name == 'staged_values' then
                local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
                local sources = { q(c), q(main) }
                for _, file in ipairs { 'slc_rt.c', 'slc_tasks.c', 'slc_io_posix.c', 'slc_io_poll.c' } do
                    sources[#sources + 1] = q(root .. '/runtime/' .. file)
                end
                for _, opt in ipairs { 'O0', 'O2' } do
                    local exe = c .. '.' .. opt
                    local oks, outs = sh(('cc -std=c99 -Wall -Wextra -Werror -%s -I%s %s -pthread -o %s && %s')
                        :format(opt, q(root .. '/runtime'), table.concat(sources, ' '), q(exe), q(exe)))
                    check(name .. ': ' .. opt .. ' binding-time equivalence', oks, outs)
                end
                if sh('command -v clang') then
                    local exe = c .. '.asan'
                    local oks, outs = sh(('clang -std=c99 -O1 -g -fsanitize=address,undefined '
                        .. '-fno-sanitize-recover=all -I%s %s -pthread -o %s && ASAN_OPTIONS=detect_leaks=1 %s')
                        :format(q(root .. '/runtime'), table.concat(sources, ' '), q(exe), q(exe)))
                    check(name .. ': ASan/UBSan', oks, outs)
                else
                    print('skip  staged values ASan/UBSan: clang not found')
                end
                local generated = assert(io.open(c))
                local source = generated:read('*a'); generated:close()
                for _, word in ipairs { 'stage_empty', 'stage_value', 'stage_binary_value', 'stage_live', 'stage_shorter', 'stage_nested', 'stage_parse', 'stage_split' } do
                    local body = source:match(word .. '%b()%s*(%b{})')
                    check(word .. ': known data needs no runtime fill', body and not body:find('slc_chars_fill', 1, true))
                end
            end
            -- I/O runs on every backend, each also under ThreadSanitizer
            if okl and name == 'io' then
                local base = root .. '/runtime/slc_rt.c ' .. root .. '/runtime/slc_tasks.c ' .. root .. '/runtime/slc_io_posix.c '
                local backends = { { 'io_uring', 'slc_io_uring.c', '' } }
                if io.open('/usr/include/kqueue/sys/event.h') then
                    backends[#backends + 1] = { 'kqueue', 'slc_io_kqueue.c', '-I/usr/include/kqueue -lkqueue' }
                end
                for _, be in ipairs(backends) do
                    local src = base .. root .. '/runtime/' .. be[2]
                    local okb, outb = sh(('%s %s %s %s -pthread %s -o %s.%s && %s.%s'):format(CC, c, main, src, be[3],
                        c, be[1], c, be[1]))
                    check(name .. ': run on ' .. be[1], okb, outb)
                end
                backends[#backends + 1] = { 'poll', 'slc_io_poll.c', '' }
                for _, be in ipairs(backends) do
                    local src = base .. root .. '/runtime/' .. be[2]
                    local okt, outt = sh(('clang -std=c99 -Wall -Wextra -Werror -O1 -g -fsanitize=thread -I%s/runtime %s %s %s -pthread %s -o %s.tsan_%s && %s.tsan_%s'):format(
                        root, c, main, src, be[3], c, be[1], c, be[1]))
                    check(name .. ': ThreadSanitizer on ' .. be[1], okt and not outt:find('ThreadSanitizer'), outt)
                end
            end
            -- tasks also run in deterministic mode: one thread, a seeded schedule
            if okl and name == 'channels' then
                local okd, outd = sh(('SLC_SCHED_SEED=7 %s.bin'):format(c))
                check(name .. ': deterministic schedule', okd, outd)
            end
            -- threaded harnesses also run under ThreadSanitizer (clang's models fences)
            if okl and (name == 'atomics' or name == 'channels') then
                local probe = build .. '/slc_tsan_probe.c'
                local pf = assert(io.open(probe, 'w')); pf:write('int main(void){return 0;}\n'); pf:close()
                local have = sh(('clang -fsanitize=thread %s -o %s.bin'):format(probe, probe))
                if have then
                    local okt, outt = sh(('clang -std=c99 -Wall -Wextra -Werror -O1 -g -fsanitize=thread -I%s/runtime %s %s %s -pthread -o %s.tsan && %s.tsan'):format(
                        root, c, main, rt, c, c))
                    check(name .. ': ThreadSanitizer', okt and not outt:find('ThreadSanitizer'), outt)
                end
            end
        end
    end
end

local oka, erra = pcall(dofile, root .. '/tests/array_value.lua')
check('immutable array contents: persistence and sparse zeros', oka, erra)

-- Text's C helper accepts unrelated buffers and self-aliases across growth.
-- Keep pointer comparisons separate from UBSan's pointer-overflow instrumentation.
-- Pointer-subtract instrumentation also flags intentional uintptr_t address math.
do
    local rt = root .. '/runtime/slc_rt.c ' .. root .. '/runtime/slc_tasks.c '
        .. root .. '/runtime/slc_io_posix.c ' .. root .. '/runtime/slc_io_poll.c'
    local main = root .. '/tests/text_runtime_main.c'
    local bin = build .. '/slc_text_runtime'
    local ok, out = sh(('%s %s %s -pthread -o %s && %s'):format(CC, main, rt, bin, bin))
    check('Text runtime: aliases and buffer growth', ok, out)
    local clang = sh('command -v clang')
    if clang then
        for i, flags in ipairs { 'address,undefined', 'address,pointer-compare' } do
            local exe = bin .. '.san' .. i
            local oks, outs = sh(('clang -std=c99 -Wall -Wextra -Werror -O1 -g -fsanitize=%s '
                .. '-fno-sanitize-recover=all -fno-omit-frame-pointer -I%s/runtime %s %s -pthread -o %s '
                .. '&& ASAN_OPTIONS=detect_leaks=1:detect_invalid_pointer_pairs=2 %s'):format(flags, root, main, rt, exe, exe))
            check('Text runtime: ' .. flags, oks, outs)
        end
    else
        print('skip  Text runtime sanitizers: clang not found')
    end
end

-- the gccjit backend: the same harnesses, linked against libgccjit's object
-- files, and the in-process backend
local have_jit = sh(('luajit -e "package.path=[[%s/?.lua;]]..package.path; require([[slc.cjit]]).lib()"'):format(root))
if have_jit then
    local rt = root .. '/runtime/slc_rt.c ' .. root .. '/runtime/slc_tasks.c ' .. root .. '/runtime/slc_io_posix.c '
    for _, f in ipairs(examples) do
        local name = f:match('([^/]+)%.slc$')
        local o = build .. '/slc_jit_' .. name .. '.o'
        local ok, out = sh(('luajit %s/slc.lua --gccjit -o %s %s'):format(root, o, f))
        check(name .. ': gccjit object', ok, out)
        local main = root .. '/tests/' .. name .. '_main.c'
        local fh = io.open(main)
        if fh and ok then
            fh:close()
            local okl, outl = sh(('%s %s %s %s%s/runtime/slc_io_poll.c -pthread -o %s.bin && %s.bin'):format(
                CC, o, main, rt, root, o, o))
            check(name .. ': gccjit run', okl, outl)
            if okl and name == 'channels' then
                local okd, outd = sh(('SLC_SCHED_SEED=7 %s.bin'):format(o))
                check(name .. ': gccjit deterministic schedule', okd, outd)
            end
            if okl and name == 'io' then
                local oku, outu = sh(('%s %s %s %s%s/runtime/slc_io_uring.c -pthread -o %s.uring && %s.uring'):format(
                    CC, o, main, rt, root, o, o))
                check(name .. ': gccjit run on io_uring', oku, outu)
            end
        end
    end
    local okn, outn = sh(('luajit %s/tests/native.lua'):format(root))
    check('in-process backend', okn, outn)
else
    print('skip  gccjit backend: libgccjit not found')
end

-- the differential fuzzer: its saved findings, and a few new programs
if have_jit then
    local okr, outr = sh(('luajit %s/tests/fuzz/fuzz.lua --regressions'):format(root))
    check('fuzz regressions agree on every run', okr, outr)
    local okf, outf = sh(('luajit %s/tests/fuzz/fuzz.lua --seed 424242 --count 5 --no-shrink'):format(root))
    check('fuzz: 5 programs agree on every run', okf, outf)
end

-- programs that must be rejected, with a fragment of the expected message
local bad = dofile(root .. '/tests/errors.lua')
for _, case in ipairs(bad) do
    local path = build .. '/slc_bad.slc'
    local fh = assert(io.open(path, 'w')); fh:write(case.src); fh:close()
    local ok, out = sh(('luajit %s/slc.lua %s'):format(root, path))
    local good = not ok and out:find(case.expect, 1, true)
    if good and case.line then good = out:find(':' .. case.line .. ':', 1, true) end
    check('rejects: ' .. case.name, good, out)
end

-- the generated C keeps the checks nothing proves, and drops the ones a branch proved
local expectations = {
    { 'memory_views', 'SLC_BOUND(i + 1u - 1u, xs.len);', true, 'an index no fact covers stays checked' },
    { 'memory_views', 'SLC_BOUND(i, xs.len)', false, 'an index the branch proved is not checked' },
    { 'activities', 'Node *at = NodeStore_borrow(&g->nodes, id);', true, 'one checked lookup per stretch' },
}
for _, x in ipairs(expectations) do
    local okc, outc = sh(('luajit %s/slc.lua %s/examples/%s.slc'):format(root, root, x[1]))
    local has = outc:find(x[2], 1, true) ~= nil
    check('codegen: ' .. x[4], okc and has == x[3], x[2])
end

-- the spec's C listings are real output
local okl, outl = sh(('luajit %s/tests/listings.lua'):format(root))
check('spec listings are real output', okl, outl)

-- the design guide's examples are real code and real output
local okg, outg = sh(('luajit %s/tests/guide.lua'):format(root))
check('guide examples are real', okg, outg)

print(('%d passed, %d failed'):format(passes, failures))
os.exit(failures == 0 and 0 or 1)
