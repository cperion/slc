-- The differential fuzzer: one random program, every way slc can run it.
--
--   luajit tests/fuzz/fuzz.lua [--seconds N] [--seed S] [--count N] [--keep]
--   luajit tests/fuzz/fuzz.lua --regressions        re-check every saved regression
--
-- For each program and input vector, these must agree:
--   known      host(f(x...)) while compiling
--   native     f compiled into this process by gccjit
--   c-O0/c-O2  f exported, C backend, cc
--   splits     wrappers with some inputs known while compiling, through gccjit and C
-- Every tenth program the C build also runs under UBSan, every fiftieth under
-- ASan. A mismatch is shrunk
-- on the AST and saved to tests/fuzz/regressions/.

local root = arg[0]:match('^(.*)/tests/fuzz/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
local saved_arg = arg
arg = { [0] = root .. '/slc.lua' }
package.loaded['slc.driver_loaded'] = true
-- the compiler: this tree's source, or the copy an embedding binary carries
local function load_slc()
    local provider = rawget(_G, '__slc_embedded_source')
    if os.getenv('SLC_DIST_DEBUG') then
        io.stderr:write('debug provider=', tostring(provider), ' slc.lua=', tostring(provider and provider('slc.lua') and #provider('slc.lua')), '\n')
    end
    local text = provider and provider('slc.lua')
    local saved = package.loaded['slc.driver_loaded']
    package.loaded['slc.driver_loaded'] = true
    local module
    if text then
        module = assert(loadstring(text, '@slc.lua'))()
    else
        module = dofile(root .. '/slc.lua')
    end
    package.loaded['slc.driver_loaded'] = saved
    return module
end
local slc = load_slc()
arg = saved_arg
local Gen = dofile(root .. '/tests/fuzz/gen.lua')
local G = require 'slc.cgen'

-- unique per process: two fuzz runs in the same second must not share a directory
local STAMP = tostring(os.time()) .. '_' .. tostring({}):match('0x(%x+)')
local TMP = (os.getenv('TMPDIR') or '/tmp') .. '/slc_fuzz_' .. STAMP
os.execute('mkdir -p ' .. TMP)
-- the runtime as the embedding binary carries it (a prebuilt archive), or the
-- sources in a development tree
local RT = os.getenv('SLC_RT') and ('%q'):format(os.getenv('SLC_RT'))
    or (require('slc.runtime_build').source() .. ' ' .. root .. '/runtime/slc_rt.c')

local function sh(cmd)
    local p = io.popen('(' .. cmd .. ') 2>&1; echo "__rc=$?"')
    local out = p:read '*a'
    p:close()
    local rc = tonumber(out:match('__rc=(%d+)%s*$'))
    return rc == 0, (out:gsub('__rc=%d+%s*$', ''))
end

local function norm(v)
    if type(v) == 'number' then return ('%.0f'):format(v) end
    if type(v) == 'cdata' then return (tostring(v):gsub('U?LL$', '')) end
    return tostring(v)
end

-- the C type of an slc integer type
local function ctype(t)
    local d = Gen.INTS[t]
    return (d.signed and 'int' or 'uint') .. d.bits .. '_t'
end
local function cliteral(t, v)
    local d = Gen.INTS[t]
    if d.signed then
        if v == -2147483648 then return '(-2147483647 - 1)' end
        return ('%d'):format(v) .. (d.bits == 64 and 'LL' or '')
    end
    return ('%d'):format(v) .. 'u' .. (d.bits == 64 and 'LL' or '')
end

-- a sanitizer run is only useful where the sanitizer exists: a missing runtime
-- library is not a finding. Probed once per process.
local sanitizers = {}
local function have_sanitizer(kind)
    if sanitizers[kind] ~= nil then return sanitizers[kind] end
    local ok = os.execute(('printf "int main(void){return 0;}" | cc -x c -fsanitize=%s - -o /dev/null >/dev/null 2>&1'):format(kind))
    sanitizers[kind] = (ok == 0 or ok == true)
    if not sanitizers[kind] then
        io.write(('  (%s sanitizer unavailable here: skipping those runs)\n'):format(kind))
    end
    return sanitizers[kind]
end

-- one program, all its runs: returns { [run] = { [vector] = outcome } } and the text
local function run_program(prog, vectors, opts)
    opts = opts or {}
    local text = Gen.render(prog)
    -- splits: for the first vectors, some parameters known while compiling
    local splits = {}
    local r = Gen.rng(prog.seed * 31 + 1)
    for vi = 1, opts.fast and 0 or math.min(3, #vectors) do
        for _ = 1, 2 do
            local known = {}
            for j = 1, #prog.params do known[j] = r:chance(0.5) end
            splits[#splits + 1] = { vi = vi, known = known, name = 'f_s' .. (#splits + 1) }
        end
    end
    local extra = { '', '-- the fuzzer\'s harness' }
    for _, sp in ipairs(splits) do
        local ps, args = {}, {}
        for j, t in ipairs(prog.params) do
            if sp.known[j] then
                args[j] = Gen.lit(t, vectors[sp.vi][j])
            else
                ps[#ps + 1] = 'a' .. j .. ': ' .. t
                args[j] = 'a' .. j
            end
        end
        extra[#extra + 1] = ('local %s = do(%s): U64'):format(sp.name, table.concat(ps, ', '))
        extra[#extra + 1] = ('    return f(%s)'):format(table.concat(args, ', '))
        extra[#extra + 1] = 'end'
    end
    extra[#extra + 1] = 'export f'
    for _, sp in ipairs(splits) do extra[#extra + 1] = 'export ' .. sp.name end
    -- known evaluation and the in-process runs, from the program's own Lua
    extra[#extra + 1] = '__FZ.known, __FZ.native = {}, {}'
    for vi, v in ipairs(vectors) do
        local args = {}
        for j, t in ipairs(prog.params) do args[j] = Gen.lit(t, v[j]) end
        extra[#extra + 1] = ('__FZ.put(__FZ.known, %d, function() return host(f(%s)) end)'):format(vi, table.concat(args, ', '))
    end
    if not opts.no_native and not opts.fast then
        extra[#extra + 1] = 'local nf = native(f)'
        for vi, v in ipairs(vectors) do
            local args = {}
            for j = 1, #prog.params do args[j] = ('%d'):format(v[j]) end
            extra[#extra + 1] = ('__FZ.put(__FZ.native, %d, function() return nf(%s) end)'):format(vi, table.concat(args, ', '))
        end
        for si, sp in ipairs(splits) do
            local args = {}
            for j = 1, #prog.params do
                if not sp.known[j] then args[#args + 1] = ('%d'):format(vectors[sp.vi][j]) end
            end
            extra[#extra + 1] = ('__FZ.put(__FZ.native, "s%d", function() return (native(%s))(%s) end)')
                :format(si, sp.name, table.concat(args, ', '))
        end
    end
    local full = text .. table.concat(extra, '\n') .. '\n'
    _G.__FZ = { norm = norm }
    function __FZ.put(t, k, f)
        local ok, r = pcall(f)
        t[k] = ok and norm(r) or ('error: ' .. tostring(r))
    end
    local path = TMP .. '/p.slc'
    local fh = assert(io.open(path, 'w')); fh:write(full); fh:close()
    local ok, ctext, mod = pcall(slc.compile, full, path)
    local res = { text = full }
    if not ok then
        res.compile_error = tostring(ctext)
        return res
    end
    res.known, res.native = __FZ.known, __FZ.native
    -- the C backend: a driver calls every export on its vectors
    local names = {}
    for _, fn in ipairs(mod.exports) do names[fn.export_name or fn.cname] = fn.cname end
    local c = TMP .. '/p.c'
    fh = assert(io.open(c, 'w')); fh:write(ctext); fh:close()
    local d = { '#include <stdio.h>', '#include <stdint.h>' }
    local function proto(cname, params)
        local ps = {}
        for j, t in ipairs(params) do ps[j] = ctype(t) end
        d[#d + 1] = ('uint64_t %s(%s);'):format(cname, #ps > 0 and table.concat(ps, ', ') or 'void')
    end
    proto(names.f, prog.params)
    for _, sp in ipairs(splits) do
        local ps = {}
        for j, t in ipairs(prog.params) do if not sp.known[j] then ps[#ps + 1] = t end end
        proto(names[sp.name], ps)
    end
    d[#d + 1] = 'int main(void) {'
    for vi, v in ipairs(vectors) do
        local args = {}
        for j, t in ipairs(prog.params) do args[j] = cliteral(t, v[j]) end
        d[#d + 1] = ('    printf("%d %%llu\\n", (unsigned long long)%s(%s));'):format(vi, names.f, table.concat(args, ', '))
    end
    for si, sp in ipairs(splits) do
        local args = {}
        for j, t in ipairs(prog.params) do
            if not sp.known[j] then args[#args + 1] = cliteral(t, vectors[sp.vi][j]) end
        end
        d[#d + 1] = ('    printf("s%d %%llu\\n", (unsigned long long)%s(%s));'):format(si, names[sp.name], table.concat(args, ', '))
    end
    d[#d + 1] = '    return 0;'
    d[#d + 1] = '}'
    local dm = TMP .. '/main.c'
    fh = assert(io.open(dm, 'w')); fh:write(table.concat(d, '\n') .. '\n'); fh:close()
    local levels = opts.fast and { 'O0' } or { 'O0', 'O2' }
    if opts.ubsan and have_sanitizer('undefined') then levels[#levels + 1] = 'ubsan' end
    if opts.asan and have_sanitizer('address') then levels[#levels + 1] = 'asan' end
    for _, lv in ipairs(levels) do
        local flags = lv == 'ubsan' and '-O1 -fsanitize=undefined -fno-sanitize-recover=all'
            or lv == 'asan' and '-O1 -fsanitize=address -fno-omit-frame-pointer'
            or ('-' .. lv)
        local okc, out = sh(('cc -std=c99 -w %s -I%s/runtime %s %s %s -pthread -o %s/p_%s && %s/p_%s'):format(
            flags, root, c, dm, RT, TMP, lv, TMP, lv))
        local tab = {}
        if okc then
            for k, v in out:gmatch('(%S+) (%d+)') do tab[tonumber(k) or k] = v end
        else
            tab.error = out
        end
        res['c_' .. lv] = tab
    end
    res.splits = splits
    return res
end

-- the outcomes that must agree, as a list of { what, expected, got }
local function mismatches(res, vectors)
    if res.compile_error then
        -- a generated program must compile: rejecting it is itself a finding
        return { { 'compile', 'ok', res.compile_error } }
    end
    local bad = {}
    -- the reference: the known evaluation, unless the program uses what the
    -- specializer cannot run while compiling (arrays are memory); then C at -O0
    local function reference(key)
        local k = res.known[key]
        if type(k) == 'string' and k:find('cannot evaluate at compile time', 1, true) then
            return res.c_O0 and res.c_O0[key] or k
        end
        return k
    end
    for vi = 1, #vectors do
        local k = reference(vi)
        local function cmp(what, got)
            if got ~= k then bad[#bad + 1] = { what .. ' v' .. vi, k, tostring(got) } end
        end
        if res.native[vi] then cmp('native', res.native[vi]) end
        for _, lv in ipairs { 'O0', 'O2', 'ubsan', 'asan' } do
            local t = res['c_' .. lv]
            if t then
                if t.error then
                    bad[#bad + 1] = { 'c_' .. lv, k, t.error:sub(1, 400) }
                    break
                end
                cmp('c_' .. lv, t[vi])
            end
        end
    end
    for si, sp in ipairs(res.splits or {}) do
        local k = reference(sp.vi)
        local function cmp(what, got)
            if got ~= k then bad[#bad + 1] = { what .. ' split' .. si, k, tostring(got) } end
        end
        if res.native['s' .. si] then cmp('native', res.native['s' .. si]) end
        if res.c_O2 and not res.c_O2.error then cmp('c_O2', res.c_O2['s' .. si]) end
    end
    return bad
end

-- shrinking ----------------------------------------------------------------------------------------
-- edits that make a program smaller; a mismatch that survives an edit keeps it

local function deep_copy(x, seen)
    if type(x) ~= 'table' then return x end
    seen = seen or {}
    if seen[x] then return seen[x] end
    local y = {}
    seen[x] = y
    for k, v in pairs(x) do y[deep_copy(k, seen)] = deep_copy(v, seen) end
    return setmetatable(y, getmetatable(x))
end

local function blocks_of(prog)
    local out = {}
    local function walk(b)
        out[#out + 1] = b
        for _, s in ipairs(b) do
            for _, k in ipairs { 'a', 'b', 'body', 'num', 'none' } do
                if type(s[k]) == 'table' and s[k][1] ~= nil or (type(s[k]) == 'table' and #s[k] == 0 and k ~= 'a' and k ~= 'b') then
                    if type(s[k]) == 'table' and not s[k].k then walk(s[k]) end
                end
            end
        end
    end
    walk(prog.body)
    return out
end

local function exprs_of(prog)
    local out = {}
    local function walk(e, parent, key)
        if type(e) ~= 'table' or not e.k then return end
        out[#out + 1] = { parent = parent, key = key, e = e }
        for _, k in ipairs { 'a', 'b', 'e', 'c', 'i', 'lo', 'hi' } do walk(e[k], e, k) end
        if e.args then for i, a in ipairs(e.args) do walk(a, e.args, i) end end
    end
    local function walk_block(b)
        for _, s in ipairs(b) do
            for _, k in ipairs { 'e', 'c', 'lo', 'hi' } do walk(s[k], s, k) end
            for _, k in ipairs { 'a', 'b', 'body', 'num', 'none' } do
                if type(s[k]) == 'table' and not s[k].k then walk_block(s[k]) end
            end
        end
    end
    walk_block(prog.body)
    for _, h in ipairs(prog.helpers) do walk(h.body, h, 'body'); if h.step then walk(h.step, h, 'step') end end
    return out
end

local function shrink(prog, vectors, still_bad, seconds)
    local progress = true
    local tries = 0
    local deadline = os.time() + (seconds or 60)
    local real = still_bad
    still_bad = function(p)
        if os.time() >= deadline then return false end
        return real(p)
    end
    while progress and tries < 400 and os.time() < deadline do
        progress = false
        -- drop statements
        for _, b in ipairs(blocks_of(prog)) do
            local i = #b
            while i >= 1 do
                local s = table.remove(b, i)
                tries = tries + 1
                if still_bad(prog) then progress = true else table.insert(b, i, s) end
                i = i - 1
            end
        end
        -- replace an if or a loop by its body
        for _, b in ipairs(blocks_of(prog)) do
            for i = #b, 1, -1 do
                local s = b[i]
                local inner = s.k == 'if' and s.a or ((s.k == 'while' or s.k == 'hostfor') and s.body) or nil
                if inner and s.k ~= 'for' then
                    table.remove(b, i)
                    for j = #inner, 1, -1 do table.insert(b, i, inner[j]) end
                    tries = tries + 1
                    if still_bad(prog) then progress = true
                    else
                        for _ = 1, #inner do table.remove(b, i) end
                        table.insert(b, i, s)
                    end
                end
            end
        end
        -- replace expressions by a constant or an operand
        for _, site in ipairs(exprs_of(prog)) do
            local e = site.e
            if e.k ~= 'const' and e.t then
                local before = deep_copy(e)
                local candidates = { { k = 'const', t = e.t, v = 0 } }
                for _, k in ipairs { 'a', 'b', 'e' } do
                    if type(e[k]) == 'table' and e[k].t == e.t then candidates[#candidates + 1] = e[k] end
                end
                for _, cand in ipairs(candidates) do
                    for k in pairs(e) do e[k] = nil end
                    for k, v in pairs(deep_copy(cand)) do e[k] = v end
                    tries = tries + 1
                    if still_bad(prog) then progress = true break end
                    for k in pairs(e) do e[k] = nil end
                    for k, v in pairs(before) do e[k] = v end
                end
            end
        end
        -- drop optional features
        for _, flag in ipairs { 'use_struct', 'use_array', 'use_sum' } do
            if prog[flag] then
                prog[flag] = false
                tries = tries + 1
                if still_bad(prog) then progress = true else prog[flag] = true end
            end
        end
    end
    return prog
end

-- driving ------------------------------------------------------------------------------------------

local function save(prog, vectors, bad)
    local dir = root .. '/tests/fuzz/regressions'
    os.execute('mkdir -p ' .. dir)
    local name = ('%s/%d.lua'):format(dir, prog.seed)
    local fh = assert(io.open(name, 'w'))
    local vs = {}
    for i, v in ipairs(vectors) do
        local x = {}
        for j, n in ipairs(v) do x[j] = ('%d'):format(n) end
        vs[i] = '{ ' .. table.concat(x, ', ') .. ' }'
    end
    local ps = {}
    for j, t in ipairs(prog.params) do ps[j] = ('%q'):format(t) end
    fh:write('-- a fuzzer finding, shrunk: every run of f must agree on every vector\n')
    fh:write('-- first mismatch when found: ' .. (bad[1] and (bad[1][1] .. ': expected ' .. tostring(bad[1][2])
        .. ', got ' .. tostring(bad[1][3]):gsub('\n', ' ')) or '') .. '\n')
    fh:write('return {\n    seed = ' .. prog.seed .. ',\n    params = { ' .. table.concat(ps, ', ') .. ' },\n')
    fh:write('    vectors = { ' .. table.concat(vs, ', ') .. ' },\n')
    fh:write('    program = ' .. ('%q'):format(deep_copy(prog) and Gen.render(prog)) .. ',\n')
    fh:write('    ast = ' .. 'nil' .. ',\n}\n')
    fh:close()
    return name
end

local function check_seed(seed, opts)
    local prog = Gen.program(seed)
    local vectors = Gen.inputs(prog, seed, opts.vectors or 6)
    local res = run_program(prog, vectors, { ubsan = opts.ubsan, asan = opts.asan })
    local bad = mismatches(res, vectors)
    if #bad == 0 then return true end
    io.write(('seed %d: %d mismatches, first: %s: expected %s, got %s\n'):format(seed, #bad, bad[1][1],
        tostring(bad[1][2]), tostring(bad[1][3]):sub(1, 300)))
    if opts.shrink ~= false then
        -- shrink on the cheapest disagreement: known against C at -O0 when that is one,
        -- otherwise the full run
        local fast = false
        local rf = run_program(prog, vectors, { fast = true })
        for vi = 1, #vectors do
            local k = rf.known and rf.known[vi]
            if not rf.compile_error and rf.c_O0 and rf.c_O0[vi] and k ~= rf.c_O0[vi]
                and not tostring(k):find('cannot evaluate', 1, true) then fast = true end
        end
        local kind = bad[1][1]:match('^(%S+)')
        local small = shrink(deep_copy(prog), vectors, function(p)
            if fast then
                local r = run_program(p, vectors, { fast = true })
                if r.compile_error or not r.c_O0 or r.c_O0.error then return false end
                for vi = 1, #vectors do
                    local k = r.known[vi]
                    if r.c_O0[vi] and k ~= r.c_O0[vi] and not tostring(k):find('error', 1, true) then return true end
                end
                return false
            end
            local r = run_program(p, vectors, { ubsan = opts.ubsan, asan = opts.asan })
            local b = mismatches(r, vectors)
            for _, x in ipairs(b) do if x[1]:match('^(%S+)') == kind then return true end end
            return false
        end, opts.shrink_seconds or 60)
        local name = save(small, vectors, bad)
        io.write('  shrunk and saved: ' .. name .. '\n')
    end
    return false
end

-- a saved regression: its program text, run every way
local function check_regression(path)
    local reg = dofile(path)
    local prog = { seed = reg.seed, params = reg.params, text_override = reg.program }
    -- the saved text is the program: run it through the same harness
    local fake = setmetatable({}, { __index = prog })
    local saved_render = Gen.render
    Gen.render = function() return reg.program end
    local res = run_program(prog, reg.vectors, {})
    Gen.render = saved_render
    local bad = mismatches(res, reg.vectors)
    return #bad == 0, bad
end

local opts = { seconds = 60, ubsan_every = 10, asan_every = 50 }
local i = 1
while i <= #arg do
    local a = arg[i]
    if a == '--seconds' then i = i + 1; opts.seconds = tonumber(arg[i])
    elseif a == '--seed' then i = i + 1; opts.seed = tonumber(arg[i])
    elseif a == '--count' then i = i + 1; opts.count = tonumber(arg[i])
    elseif a == '--no-shrink' then opts.shrink = false
    elseif a == '--regressions' then opts.regressions = true
    elseif a == '--keep' then opts.keep = true
    elseif a == '--asan-every' then i = i + 1; opts.asan_every = tonumber(arg[i])
    elseif a == '--no-asan' then opts.asan_every = 0
    elseif a == '--ubsan-every' then i = i + 1; opts.ubsan_every = tonumber(arg[i])
    end
    i = i + 1
end

if opts.regressions then
    local n, fails = 0, 0
    for f in io.popen('ls ' .. root .. '/tests/fuzz/regressions/*.lua 2>/dev/null'):lines() do
        n = n + 1
        local ok, bad = check_regression(f)
        if not ok then
            fails = fails + 1
            print('FAIL ' .. f .. ': ' .. bad[1][1] .. ': expected ' .. tostring(bad[1][2]) .. ', got ' .. tostring(bad[1][3]))
        end
    end
    print(('%d regressions, %d failing'):format(n, fails))
    os.execute('rm -rf ' .. TMP)
    os.exit(fails == 0 and 0 or 1)
end

local start = os.time()
local seed = opts.seed or (os.time() % 100000) * 1000
local n, fails = 0, 0
while true do
    n = n + 1
    local ok = check_seed(seed, { ubsan = n % opts.ubsan_every == 0,
        asan = opts.asan_every > 0 and n % opts.asan_every == 0, shrink = opts.shrink })
    if not ok then fails = fails + 1 end
    seed = seed + 1
    if opts.count and n >= opts.count then break end
    if not opts.count and os.time() - start >= opts.seconds then break end
end
print(('%d programs, %d with mismatches'):format(n, fails))
if not opts.keep then os.execute('rm -rf ' .. TMP) else print('kept ' .. TMP) end
os.exit(fails == 0 and 0 or 1)
