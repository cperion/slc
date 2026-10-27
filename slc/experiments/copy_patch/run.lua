-- Run from the session workspace after extracting stencils (see README).
local ffi = require 'ffi'
assert(ffi.os == 'Linux' and ffi.arch == 'x64', 'Linux x86-64 only')
ffi.cdef [[
void *mmap(void *, size_t, int, int, int, long);
int mprotect(void *, size_t, int);
int munmap(void *, size_t);
typedef uint64_t (*entry_fn)(uint64_t, uint64_t);
]]
local stencils = dofile('build/copy_patch/stencils.lua')
local checks = 0
local function check(ok)
    assert(ok)
    checks = checks + 1
end

-- Node identifiers are construction-time labels. NEXT/ZERO are edges, IMM a
-- patch-time constant. No instruction array or program counter reaches execution.
local function assemble(nodes, fallthrough)
    local pieces, offsets, size = {}, {}, 0
    for i, node in ipairs(nodes) do
        local stencil = assert(stencils[node.op], 'unknown operation')
        local code, omit = stencil.code, nil
        if fallthrough then
            for _, r in ipairs(stencil.relocs) do
                if r.symbol == 'NEXT' and node.NEXT == i + 1 and nodes[i + 1]
                    and r.kind == 4 and r.addend == -4
                    and r.offset == #code - 4 and code:byte(#code - 4) == 0xe9 then
                    code, omit = code:sub(1, -6), r
                    break
                end
            end
        end
        offsets[i] = size
        pieces[i] = {code=code, relocs=stencil.relocs, omit=omit}
        size = size + #code
    end
    assert(size > 0)
    -- Resolve and range-check every relocation before allocating executable memory.
    local patches = {}
    for i, piece in ipairs(pieces) do
        for _, r in ipairs(piece.relocs) do
            if r ~= piece.omit then
                local value = assert(nodes[i][r.symbol], 'missing relocation binding')
                local at = offsets[i] + r.offset
                if r.kind == 2 or r.kind == 4 then
                    value = assert(offsets[value], 'missing target label') + r.addend - at
                else
                    value = value + r.addend
                end
                assert(value == math.floor(value), 'noninteger patch')
                if r.kind == 10 then
                    assert(value >= 0 and value <= 4294967295, 'unsigned patch overflow')
                else
                    assert(value >= -2147483648 and value <= 2147483647, 'signed patch overflow')
                end
                patches[#patches + 1] = {at=at, value=value}
            end
        end
    end
    local mem = ffi.C.mmap(nil, size, 3, 0x22, -1, 0) -- private anonymous RW
    assert(mem ~= ffi.cast('void *', -1), 'mmap failed')
    mem = ffi.gc(ffi.cast('uint8_t *', mem), function(p) ffi.C.munmap(p, size) end)
    for i, piece in ipairs(pieces) do
        ffi.copy(mem + offsets[i], piece.code, #piece.code)
    end
    local word = ffi.new('uint32_t[1]')
    for _, p in ipairs(patches) do
        word[0] = p.value % 4294967296
        ffi.copy(mem + p.at, word, 4) -- relocation fields can be unaligned
    end
    assert(ffi.C.mprotect(mem, size, 5) == 0, 'mprotect RX failed')
    -- x86 instruction-cache coherence; other architectures need cache maintenance.
    return {memory=mem, fn=ffi.cast('entry_fn', mem), size=size}
end
local function close(p)
    ffi.gc(p.memory, nil)
    assert(ffi.C.munmap(p.memory, p.size) == 0)
    p.fn, p.memory = nil, nil
end
local function dump(p, name)
    local out = assert(io.open('build/copy_patch/' .. name .. '.bin', 'wb'))
    out:write(ffi.string(p.memory, p.size))
    out:close()
end
local affine = {
    {op='mul', IMM=3, NEXT=2},
    {op='add', IMM=7, NEXT=3},
    {op='result_x'},
}
local sum = {
    {op='init', NEXT=2},
    {op='test', NEXT=3, ZERO=4},
    {op='step', NEXT=2},
    {op='result_a'},
}
for _, trim in ipairs {false, true} do
    local a, s = assemble(affine, trim), assemble(sum, trim)
    for n = 0, 10000 do
        check(a.fn(n, 999) == n * 3 + 7)
        check(s.fn(n, 999) == n * (n + 1) / 2)
    end
    local max = 18446744073709551615ULL
    check(a.fn(max, 0) == 4ULL) -- actual U64 wraparound, not Lua double math
    check(a.fn(9223372036854775808ULL, 0) == 9223372036854775815ULL)
    check(s.fn(1000000, 0) == 500000500000ULL) -- backedge does not grow C stack
    local suffix = trim and 'fallthrough' or 'jumps'
    dump(a, 'affine-' .. suffix)
    dump(s, 'sum-' .. suffix)
    print(string.format('%s: affine %d bytes; triangular loop %d bytes', suffix, a.size, s.size))
    close(a); close(s)
end
-- Multiple independently patched copies of the same handler.
for k = 0, 31 do
    local p = assemble({{op='mul', IMM=k, NEXT=2},
                        {op='add', IMM=31-k, NEXT=3}, {op='result_x'}}, true)
    check(p.fn(123, 0) == 123*k + 31-k)
    close(p)
end
check(not pcall(assemble, {{op='add', IMM=2147483648, NEXT=2}, {op='result_x'}}, false))
check(not pcall(assemble, {{op='mul', IMM=1, NEXT=99}}, false))
check(not pcall(assemble, {{op='mul', NEXT=2}, {op='result_x'}}, false))
check(not pcall(assemble, {{op='mul', IMM=1, NEXT=2}}, true))
print(string.format('PASS: %d checks; no C compiler or interpreter in generated execution', checks))
