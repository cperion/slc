-- Copy/patch only: never invokes a compiler, linker, or bytecode interpreter.
local ffi = require 'ffi'
local bit = require 'bit'
require 'slc.direct.abi'
local M = {}
local function integer(n)
    return type(n) == 'number' and n == math.floor(n)
end
local function align(n, a) return math.floor((n + a - 1) / a) * a end
local function displacement(n)
    assert(integer(n) and n >= -2147483648 and n <= 2147483647, 'direct: relative patch out of range')
    return n
end
function M.build(pack, nodes, symbols)
    assert(pack.abi == 2 and pack.target == 'linux-x64' and pack.ni == 11 and pack.nf == 8,
        'direct: incompatible stencil ABI')
    assert(#nodes > 0, 'direct: empty program')
    symbols = symbols or {}
    local pieces, offsets, size, externs, literals, readonly = {}, {}, 0, {}, {}, {}
    for i, node in ipairs(nodes) do
        local st = assert(pack.stencils[node.op], 'direct: unsupported stencil ' .. tostring(node.op))
        assert(type(st.code) == 'string' and #st.code > 0, 'direct: invalid stencil code')
        local a = st.align
        assert(integer(a) and a >= 1 and a <= 16 and bit.band(a, a - 1) == 0, 'direct: code alignment')
        size = align(size, a)
        offsets[i] = size
        local code, omit = st.code
        for _, r in ipairs(st.relocs) do
            assert(integer(r.offset) and r.offset >= 0 and r.offset + 4 <= #code,
                'direct: relocation outside stencil')
            if r.symbol == 'NEXT' and node.NEXT == i + 1 and nodes[i + 1]
                and r.kind == 4 and r.addend == -4
                and r.offset == #code - 4 and code:byte(#code - 4) == 0xe9 then
                omit = r
            elseif r.symbol == 'LITERAL' then
                assert(r.kind == 2, 'direct: literal relocation kind')
                assert((type(node.LITERAL) == 'string' and #node.LITERAL == 8) or integer(node.ENTRY),
                    'direct: literal requires eight exact bytes or an entry label')
                literals[i] = {bytes=node.LITERAL, entry=node.ENTRY}
            elseif r.symbol:sub(1, 6) == '@data:' then
                assert(r.kind == 2 and pack.data and pack.data[r.symbol], 'direct: invalid read-only relocation')
                readonly[r.symbol] = true
            elseif r.symbol ~= 'NEXT' and r.symbol ~= 'ZERO' and r.symbol ~= 'IMM' and r.symbol ~= 'OFFSET' then
                assert(r.symbol == 'cp_native_call' or r.symbol == 'cp_invoke_frame'
                    or r.symbol == 'memcpy' or r.symbol == 'memset', 'direct: unsupported external relocation')
                assert(symbols[r.symbol] ~= nil, 'direct: unresolved symbol ' .. r.symbol)
                externs[r.symbol] = true
            end
        end
        if omit then code = code:sub(1, -6) end
        pieces[i] = {code=code, relocs=st.relocs, omit=omit}
        size = size + #code
    end
    local data_names = {}
    for name in pairs(readonly) do data_names[#data_names + 1] = name end
    table.sort(data_names)
    for _, name in ipairs(data_names) do
        local data = pack.data[name]
        assert(integer(data.align) and data.align >= 1 and data.align <= 32
            and bit.band(data.align, data.align - 1) == 0, 'direct: read-only alignment')
        size = align(size, data.align); readonly[name] = size; size = size + #data.bytes
    end
    for i = 1, #nodes do
        if literals[i] then
            if literals[i].entry then assert(offsets[literals[i].entry], 'direct: missing literal entry') end
            size = align(size, 8); literals[i].offset = size; size = size + 8
        end
    end
    local names = {}
    for name in pairs(externs) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        size = align(size, 8)
        externs[name] = size
        size = size + 14 -- jmp *0(%rip), followed by an absolute address
    end
    assert(size > 0 and size <= 2147483647, 'direct: module too large')
    local patches = {}
    for i, p in ipairs(pieces) do
        for _, r in ipairs(p.relocs) do
            if r ~= p.omit then
                assert(integer(r.addend), 'direct: invalid relocation addend')
                local at, value = offsets[i] + r.offset
                if r.symbol == 'IMM' or r.symbol == 'OFFSET' then
                    assert(r.kind == 10 or r.kind == 11, 'direct: immediate relocation kind')
                    value = nodes[i][r.symbol]
                    assert(integer(value), 'direct: missing or noninteger immediate')
                    value = value + r.addend
                    if r.kind == 10 then
                        assert(value >= 0 and value <= 4294967295, 'direct: unsigned immediate out of range')
                    else
                        assert(value >= -2147483648 and value <= 2147483647, 'direct: signed immediate out of range')
                    end
                else
                    assert(r.kind == 2 or r.kind == 4, 'direct: branch relocation kind')
                    local destination
                    if r.symbol == 'NEXT' or r.symbol == 'ZERO' then
                        local target = nodes[i][r.symbol]
                        assert(integer(target) and offsets[target], 'direct: missing successor ' .. r.symbol)
                        destination = offsets[target]
                    elseif r.symbol == 'LITERAL' then
                        destination = literals[i].offset
                    elseif readonly[r.symbol] then destination = readonly[r.symbol]
                    else
                        destination = assert(externs[r.symbol])
                    end
                    value = displacement(destination + r.addend - at)
                end
                patches[#patches + 1] = {at=at, value=value}
            end
        end
    end
    -- Validate/convert external addresses before allocating the mapping.
    local addresses = {}
    for _, name in ipairs(names) do
        assert(type(symbols[name]) == 'cdata', 'direct: external address must be exact cdata')
        local address = ffi.cast('uintptr_t', symbols[name])
        assert(address ~= 0, 'direct: null external symbol')
        addresses[name] = ffi.new('uint64_t[1]', address)
    end
    local raw = ffi.C.mmap(nil, size, 3, 0x22, -1, 0)
    assert(raw ~= ffi.cast('void *', -1), 'direct: mmap failed')
    local memory = ffi.gc(ffi.cast('uint8_t *', raw), function(p) ffi.C.munmap(p, size) end)
    local ok, err = pcall(function()
        ffi.fill(memory, size, 0x90) -- alignment padding permits safe fallthrough
        for i, p in ipairs(pieces) do ffi.copy(memory + offsets[i], p.code, #p.code) end
        for _, name in ipairs(data_names) do
            local data = pack.data[name]; ffi.copy(memory + readonly[name], data.bytes, #data.bytes)
        end
        for _, literal in pairs(literals) do
            if literal.entry then
                local address = ffi.new('uintptr_t[1]', ffi.cast('uintptr_t', memory + offsets[literal.entry]))
                ffi.copy(memory + literal.offset, address, 8)
            else ffi.copy(memory + literal.offset, literal.bytes, 8) end
        end
        for _, name in ipairs(names) do
            local at = externs[name]
            ffi.copy(memory + at, '\255\037\000\000\000\000', 6)
            ffi.copy(memory + at + 6, addresses[name], 8)
        end
        local word = ffi.new('uint32_t[1]')
        for _, p in ipairs(patches) do
            word[0] = p.value % 4294967296
            ffi.copy(memory + p.at, word, 4)
        end
        assert(ffi.C.mprotect(memory, size, 5) == 0, 'direct: mprotect RX failed')
    end)
    if not ok then
        ffi.gc(memory, nil); ffi.C.munmap(memory, size); error(err, 0)
    end
    -- Low-level owner: must be retained while an entry address is used.
    -- The public loader will retain published owners for process lifetime.
    return {memory=memory, entry=ffi.cast('void *', memory), size=size, offsets=offsets, symbols=symbols}
end
return M
