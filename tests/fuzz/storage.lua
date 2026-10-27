-- The storage model fuzzer (§1.5): a random sequence of store operations runs
-- twice -- once in SLC (C backend, -O0 and -O2) and once on a plain Lua table --
-- and every observable step must agree.
--
--   luajit tests/fuzz/storage.lua [--count N] [--seed S] [--keep]
--
-- Two families:
--   valid  every operation names a live Id; the checksum is compared.
--   stale  one read or write names an Id that was removed; both the model and
--          the program must stop at that step, with the store's trap.
--
-- Ids are opaque values, so the generated program keeps one typed local per
-- slot and the model keeps the same slots: generator and model use one sequence
-- of decisions, so they cannot drift.

local root = arg[0]:match('^(.*)/tests/fuzz/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path

local opts = { count = 20, seed = 12345 }
for i = 1, #arg do
    local a = arg[i]
    if a == '--count' then i = i + 1; opts.count = tonumber(arg[i])
    elseif a == '--seed' then i = i + 1; opts.seed = tonumber(arg[i])
    elseif a == '--keep' then opts.keep = true end
end

local STAMP = tostring(os.time()) .. '_' .. tostring({}):match('0x(%x+)')
local TMP = (os.getenv('TMPDIR') or '/tmp') .. '/slc_storage_' .. STAMP
os.execute('mkdir -p ' .. TMP)
-- the compiler to call for generated programs: this binary when embedded
local SLC = os.getenv('SLC_DIST') and ('%q'):format(os.getenv('SLC_DIST')) or ('luajit %q/slc.lua'):format(root)
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
local function write(name, text)
    local f = assert(io.open(TMP .. '/' .. name, 'w'))
    f:write(text)
    f:close()
end

-- a small deterministic generator, independent of math.random and the host
local function rng(seed)
    local s = bit.bxor(seed * 2654435761 % 4294967296, 0x9e3779b9)
    if s == 0 then s = 1 end
    return function(n)
        s = bit.bxor(s, bit.lshift(s, 13))
        s = bit.bxor(s, bit.rshift(s, 17))
        s = bit.bxor(s, bit.lshift(s, 5))
        s = s % 4294967296
        return (s % n) + 1
    end
end

local ffi = require 'ffi'
local SLOTS = 8
local OPS = 60

-- one program: source text, the model's checksum, and whether it traps
local function make_program(seed, stale)
    local r = rng(seed)
    local src = {
        'local run = do(): U64',
        '    local store: Store U32 = Store(U32) {}',
    }
    for i = 1, SLOTS do src[#src + 1] = ('    local id%d: Id U32'):format(i) end
    src[#src + 1] = '    local acc: U64 = 0'
    local body = {}
    -- the model's checksum is 64-bit and wraps exactly like the program's
    local model = { acc = ffi.new('uint64_t', 0), alive = {}, value = {}, trapmsg = nil }

    for step = 1, OPS do
        -- a live slot to read, write or remove
        local live = {}
        for i = 1, SLOTS do if model.alive[i] then live[#live + 1] = i end end
        local dead = {}
        for i = 1, SLOTS do if not model.alive[i] then dead[#dead + 1] = i end end
        local op
        if #dead > 0 and r(3) == 1 then
            op = 'add'
        elseif #live > 0 then
            op = ({ 'read', 'set', 'has', 'remove' })[r(4)]
        else
            op = 'add'
        end
        if op == 'add' then
            local slot = dead[r(#dead)]
            local v = r(1000)
            body[#body + 1] = ('    id%d = store:add(%d)'):format(slot, v)
            model.alive[slot], model.value[slot] = true, v
        elseif op == 'read' then
            local slot = live[r(#live)]
            body[#body + 1] = ('    acc = acc * 31 + U64(store[id%d])'):format(slot)
            model.acc = model.acc * 31 + model.value[slot]
        elseif op == 'set' then
            local slot = live[r(#live)]
            local v = r(1000)
            body[#body + 1] = ('    store[id%d] = %d'):format(slot, v)
            model.value[slot] = v
        elseif op == 'has' then
            local slot = live[r(#live)]
            body[#body + 1] = ('    acc = acc * 2 + U64(store:has(id%d))'):format(slot)
            model.acc = model.acc * 2 + 1
        else
            local slot = live[r(#live)]
            body[#body + 1] = ('    store:remove(id%d)'):format(slot)
            model.alive[slot] = false
        end
    end
    -- the stale family: one read of an Id that was removed must trap
    if stale then
        local dead = {}
        for i = 1, SLOTS do if not model.alive[i] then dead[#dead + 1] = i end end
        if #dead == 0 then
            local slot = r(SLOTS)
            body[#body + 1] = ('    store:remove(id%d)'):format(slot)
            model.alive[slot] = false
            dead[1] = slot
        end
        local victim = dead[r(#dead)]
        body[#body + 1] = ('    acc = acc * 31 + U64(store[id%d])'):format(victim)
        model.trapmsg = 'stale or foreign Id in Store'
    end
    if not model.trapmsg then
        body[#body + 1] = '    acc = acc * 31 + U64(store.length)'
        model.acc = model.acc * 31 + (function()
            local n = 0
            for i = 1, SLOTS do if model.alive[i] then n = n + 1 end end
            return n
        end)()
    end
    for _, line in ipairs(body) do src[#src + 1] = line end
    src[#src + 1] = '    return acc'
    src[#src + 1] = 'end'
    src[#src + 1] = 'export run'
    return { text = table.concat(src, '\n') .. '\n', model = model, stale = stale }
end

-- a Grow family: pushes and literal-index touches, plus a dynamic-index read
-- that must trap when it lands one past the end.
local function make_grow_program(seed, out_of_range)
    local r = rng(seed)
    local src = {
        'local run = do(at: U32): U64',
        '    local g: Grow U32 = Grow(U32) {}',
        '    local acc: U64 = 0',
    }
    local model = { acc = ffi.new('uint64_t', 0), len = 0, values = {}, trapmsg = nil }
    local function push(v)
        src[#src + 1] = ('    g:push(%d)'):format(v)
        src[#src + 1] = ('    acc = acc * 31 + %d'):format(v)
        model.len = model.len + 1
        model.values[model.len] = v
        model.acc = model.acc * 31 + v
    end
    for _ = 1, 20 + r(20) do
        if model.len > 0 and r(2) == 1 then
            local i = r(model.len)
            if r(2) == 1 then
                src[#src + 1] = ('    acc = acc * 31 + U64(g[%d])'):format(i - 1)
                model.acc = model.acc * 31 + model.values[i]
            else
                local v = r(1000)
                src[#src + 1] = ('    g[%d] = %d'):format(i - 1, v)
                src[#src + 1] = ('    acc = acc * 2 + %d'):format(v)
                model.values[i] = v
                model.acc = model.acc * 2 + v
            end
        else
            push(r(1000))
        end
    end
    if out_of_range then
        src[#src + 1] = '    acc = acc * 31 + U64(g[at])'
        model.trapmsg = 'Grow index out of range'
        model.arg = model.len
    end
    src[#src + 1] = '    return acc'
    src[#src + 1] = 'end'
    src[#src + 1] = 'export run'
    return { text = table.concat(src, '\n') .. '\n', model = model, grow = true }
end

-- a Text family: building text is appending, pushing and clearing; the model
-- tracks only the byte count, which is what the checksum sees
local function make_text_program(seed)
    local r = rng(seed)
    local src = {
        'local run = do(): U64',
        '    local t: Text = Text {}',
        '    local acc: U64 = 0',
    }
    local model = { acc = ffi.new('uint64_t', 0), length = 0 }
    for _ = 1, 30 do
        local op = r(4)
        if op == 1 then
            local v = r(100000)
            src[#src + 1] = ('    t:write(%d)'):format(v)
            src[#src + 1] = ('    acc = acc * 31 + %d'):format(#tostring(v))
            model.length = model.length + #tostring(v)
            model.acc = model.acc * 31 + #tostring(v)
        elseif op == 2 then
            local b = r(255) - 1
            src[#src + 1] = ('    t:push(U8 %d)'):format(b)
            src[#src + 1] = ('    acc = acc * 31 + %d'):format(b)
            model.length = model.length + 1
            model.acc = model.acc * 31 + b
        elseif op == 3 then
            src[#src + 1] = '    acc = acc * 31 + U64(t.length)'
            model.acc = model.acc * 31 + model.length
        else
            src[#src + 1] = '    t:str() do(s) acc = acc * 31 + U64(s.length) end'
            model.acc = model.acc * 31 + model.length
        end
        if r(10) == 1 then
            src[#src + 1] = '    t:clear()'
            model.length = 0
        end
    end
    src[#src + 1] = '    return acc'
    src[#src + 1] = 'end'
    src[#src + 1] = 'export run'
    return { text = table.concat(src, '\n') .. '\n', model = model }
end

-- a Map family: put, remove, has, a read of a live key, and the length
local function make_map_program(seed, missing)
    local r = rng(seed)
    local src = {
        'local run = do(): U64',
        '    local m: Map(U32, U32) = Map(U32, U32) {}',
        '    local acc: U64 = 0',
    }
    local model = { acc = ffi.new('uint64_t', 0), value = {}, count = 0 }
    local function put(k, v)
        src[#src + 1] = ('    m:put(%d, %d)'):format(k, v)
        src[#src + 1] = ('    acc = acc * 31 + %d'):format(v)
        if model.value[k] == nil then model.count = model.count + 1 end
        model.value[k] = v
        model.acc = model.acc * 31 + v
    end
    for _ = 1, 30 do
        local k = r(6)
        local op = r(4)
        if op == 1 then
            put(k, r(1000))
        elseif op == 2 then
            src[#src + 1] = ('    m:remove(%d)'):format(k)
            src[#src + 1] = '    acc = acc * 2 + 1'
            if model.value[k] ~= nil then
                model.value[k] = nil
                model.count = model.count - 1
            end
            model.acc = model.acc * 2 + 1
        elseif op == 3 then
            src[#src + 1] = ('    acc = acc * 2 + U64(m:has(%d))'):format(k)
            model.acc = model.acc * 2 + (model.value[k] ~= nil and 1 or 0)
        else
            put(k, r(1000))
        end
    end
    if missing then
        -- remove a key that is present, then read it: the checked place must trap
        local k = nil
        for key in pairs(model.value) do k = key end
        if k == nil then k = 1; put(k, 1) end
        src[#src + 1] = ('    m:remove(%d)'):format(k)
        model.value[k] = nil
        model.count = model.count - 1
        src[#src + 1] = ('    acc = acc * 31 + U64(m[%d])'):format(k)
        model.trapmsg = 'map-key: missing key'
    else
        src[#src + 1] = '    acc = acc * 31 + U64(m.length)'
        model.acc = model.acc * 31 + model.count
    end
    src[#src + 1] = '    return acc'
    src[#src + 1] = 'end'
    src[#src + 1] = 'export run'
    return { text = table.concat(src, '\n') .. '\n', model = model }
end

-- a StrMap family: text keys of any length; iteration is unspecified in order,
-- so its contribution is commutative (xor over the entries)
local STRKEYS = { 'a', 'b', 'c', 'aa', 'ab', 'ba' }
local function make_strmap_program(seed, missing)
    local r = rng(seed)
    local src = {
        'local Counts = StrMap(U32)',
        'local run = do(): U64',
        '    local m: Counts = Counts {}',
        '    local acc: U64 = 0',
        '    local x: U64 = 0',
    }
    local model = { acc = ffi.new('uint64_t', 0), x = ffi.new('uint64_t', 0), value = {} }
    local function count()
        local n = 0
        for _ in pairs(model.value) do n = n + 1 end
        return n
    end
    for _ = 1, 30 do
        local k = STRKEYS[r(#STRKEYS)]
        local op = r(5)
        if op == 1 or op == 2 then
            local v = r(1000)
            src[#src + 1] = ('    m:put(%q, %d)'):format(k, v)
            src[#src + 1] = ('    acc = acc * 31 + %d'):format(v)
            model.value[k] = v
            model.acc = model.acc * 31 + v
        elseif op == 3 then
            src[#src + 1] = ('    m:remove(%q)'):format(k)
            src[#src + 1] = '    acc = acc * 2 + 1'
            model.value[k] = nil
            model.acc = model.acc * 2 + 1
        elseif op == 4 then
            src[#src + 1] = ('    acc = acc * 2 + U64(m:has(%q))'):format(k)
            model.acc = model.acc * 2 + (model.value[k] ~= nil and 1 or 0)
        else
            if model.value[k] ~= nil then
                src[#src + 1] = ('    acc = acc * 31 + U64(m[%q])'):format(k)
                model.acc = model.acc * 31 + model.value[k]
            end
        end
        if r(8) == 1 then
            src[#src + 1] = '    m:each(do(k, v) x = bxor(x, U64(v) * 31 + U64(k.length)) end)'
            src[#src + 1] = '    acc = acc * 31 + x'
            -- the program's x accumulates across visits; the model does the same
            local x = model.x
            for key, v in pairs(model.value) do
                x = x ~ (ffi.new('uint64_t', v * 31 + #key))
            end
            model.x = x
            model.acc = model.acc * 31 + x
        end
    end
    if missing then
        local k = nil
        for key in pairs(model.value) do k = key end
        if k == nil then k = 'a'; src[#src + 1] = ('    m:put("a", 1)'):format() end
        src[#src + 1] = ('    m:remove(%q)'):format(k)
        model.value[k] = nil
        src[#src + 1] = ('    acc = acc * 31 + U64(m[%q])'):format(k)
        model.trapmsg = 'map-key: missing key'
    else
        src[#src + 1] = '    acc = acc * 31 + U64(m.length)'
        model.acc = model.acc * 31 + count()
    end
    src[#src + 1] = '    return acc'
    src[#src + 1] = 'end'
    src[#src + 1] = 'export run'
    return { text = table.concat(src, '\n') .. '\n', model = model }
end

-- the driver -------------------------------------------------------------------------------------

local fails, checks = 0, 0
local function fail(what) fails = fails + 1; print('MISMATCH ' .. what) end

for n = 0, opts.count - 1 do
    -- alternate the families; the odd ones must trap
    local family = n % 8
    local prog
    if family == 0 then prog = make_program(opts.seed + n, false)
    elseif family == 1 then prog = make_grow_program(opts.seed + n, false)
    elseif family == 2 then prog = make_program(opts.seed + n, true)
    elseif family == 3 then prog = make_grow_program(opts.seed + n, true)
    elseif family == 4 then prog = make_text_program(opts.seed + n)
    elseif family == 5 then prog = make_map_program(opts.seed + n, false)
    elseif family == 6 then prog = make_strmap_program(opts.seed + n, false)
    else prog = make_strmap_program(opts.seed + n, true) end
    local name = 's' .. n
    write(name .. '.slc', prog.text)
    local ok, out = sh((SLC .. ' -o %q %q'):format(TMP .. '/' .. name .. '.c', TMP .. '/' .. name .. '.slc'))
    if not ok then
        fail(name .. ': compile\n' .. out)
        goto continue
    end
    write(name .. '_main.c', ([[
#include <stdint.h>
#include <stdio.h>
uint64_t run(%s);
int main(void) { printf("%%llu\n", (unsigned long long)run(%s)); return 0; }
]]):format(prog.model.arg and 'uint32_t' or 'void', prog.model.arg and tostring(prog.model.arg) or ''))
    for _, lv in ipairs { 'O0', 'O2' } do
        local bin = TMP .. '/' .. name .. '_' .. lv
        ok, out = sh(('cc -std=c99 -Wall -Wextra -Werror -pedantic -%s -I%q %q %q %s -o %q'):format(
            lv, root .. '/runtime', TMP .. '/' .. name .. '.c', TMP .. '/' .. name .. '_main.c', RT, bin))
        if not ok then
            fail(('%s: link %s\n%s'):format(name, lv, out))
            goto continue
        end
        local ran, text = sh(('%q'):format(bin))
        checks = checks + 1
        if prog.model.trapmsg then
            if ran then
                fail(('%s %s: expected a trap, got %q'):format(name, lv, (text:gsub('%s+$', ''))))
            elseif not text:find(prog.model.trapmsg, 1, true) then
                fail(('%s %s: trapped with the wrong message: %s'):format(name, lv, text:sub(1, 200)))
            end
        else
            local want = (tostring(prog.model.acc):gsub('U?LL$', ''))
            if not ran or (text:gsub('%s+$', '')) ~= want then
                fail(('%s %s: model says %s, program says %q'):format(name, lv, want, text:sub(1, 200)))
            end
        end
    end
    ::continue::
end

if not opts.keep then os.execute('rm -rf ' .. TMP) end
print(('%d storage programs, %d checks, %d mismatches'):format(opts.count, checks, fails))
os.exit(fails == 0 and 0 or 1)
