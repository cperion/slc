-- Fixed-bank copied code and far native calls, with no compiler on this path.
local ffi = require 'ffi'
local ABI = require 'slc.direct.abi'
local A = require 'slc.direct.assemble'
local dir = arg[1] or 'build/direct'
local lib = ABI.load(dir .. '/libslc_direct.so')
ffi.cdef [[uint64_t cp_fixture_sum10(uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,
                                  uint64_t,uint64_t,uint64_t,uint64_t,uint64_t);
uint64_t cp_test_clobber(void);]]
local fixture = ffi.load(dir .. '/libdirect_fixture.so')
local pack = dofile(dir .. '/stencils.lua')
local count = 0
local function check(x) assert(x); count = count + 1 end
local function bank()
    local b = ffi.new('cp_bank')
    for i = 0, 10 do b.i[i] = 0x8123456700000000ULL + i * 97 end
    local f = ffi.cast('uint64_t *', b.f)
    for i = 0, 15 do f[i] = 0x7ff8123400000000ULL + i * 19 end
    return b
end
local function verify(b, expected)
    for i = 0, 10 do check(b.i[i] == expected.i[i]) end
    local f, e = ffi.cast('uint64_t *', b.f), ffi.cast('uint64_t *', expected.f)
    for i = 0, 15 do check(f[i] == e[i]) end
end
local function invoke(unit, input, image)
    local output = ffi.new('cp_bank')
    local ctx = ffi.new('cp_context')
    ctx.result = ffi.cast('unsigned char *', output)
    ctx.user = image and ffi.cast('void *', image) or nil
    lib.cp_invoke(unit.entry, ctx, input)
    return output
end
local affine = A.build(pack, {
    {op='cp_mul_imm', IMM=3, NEXT=2},
    {op='cp_add_imm', IMM=7, NEXT=3},
    {op='cp_finish'},
})
for n = 0, 1000 do
    local b = bank(); b.i[0] = n
    local out = invoke(affine, b)
    b.i[0] = n * 3 + 7; verify(out, b)
end
local b = bank(); b.i[0] = 18446744073709551615ULL
local out = invoke(affine, b); b.i[0] = 4; verify(out, b)
local loop = A.build(pack, {
    {op='cp_test_zero', NEXT=2, ZERO=3},
    {op='cp_sum_step', NEXT=1},
    {op='cp_finish'},
})
for _, n in ipairs {0, 1, 2, 10, 10000, 1000000} do
    b = bank(); b.i[0] = n; b.i[1] = 0
    out = invoke(loop, b); b.i[0] = 0; b.i[1] = n * (n + 1) / 2
    verify(out, b)
end
local native = A.build(pack, {
    {op='cp_call_native', NEXT=2}, {op='cp_add_imm', IMM=7, NEXT=3}, {op='cp_finish'},
}, {cp_native_call=lib.cp_native_call})
local image = ffi.new('cp_call_image')
image.target = ffi.cast('void *', fixture.cp_fixture_sum10)
for i = 0, 5 do image.gpr[i] = i + 1 end
local stack = ffi.new('uint64_t[4]', 7, 8, 9, 10)
image.stack_data = ffi.cast('unsigned char *', stack); image.stack_size = ffi.sizeof(stack)
b = bank(); out = invoke(native, b, image); b.i[0] = 392; verify(out, b)
image.target = ffi.cast('void *', fixture.cp_test_clobber)
image.stack_size = 0; image.stack_data = nil
b = bank(); out = invoke(native, b, image); b.i[0] = 123463; verify(out, b)
-- Boundary errors must be diagnosed, not produce partly published code.
local function rejects(nodes, symbols)
    check(not pcall(A.build, pack, nodes, symbols))
end
rejects({{op='cp_add_imm', IMM=1, NEXT=2}})
rejects({{op='cp_add_imm', IMM=2147483648, NEXT=2}, {op='cp_finish'}})
rejects({{op='cp_add_imm', NEXT=2}, {op='cp_finish'}})
rejects({{op='cp_call_native', NEXT=2}, {op='cp_finish'}})
rejects({{op='cp_call_native', NEXT=2}, {op='cp_finish'}}, {cp_native_call=0})
rejects({{op='cp_missing'}})
local wrong = {abi=2}
check(not pcall(A.build, wrong, {{op='cp_finish'}}))
for name, unit in pairs {affine=affine, loop=loop, native=native} do
    local f = assert(io.open(dir .. '/' .. name .. '.bin', 'wb'))
    f:write(ffi.string(unit.memory, unit.size)); f:close()
end
print(('direct copied stencils: %d checks passed (all 19 bank lanes)'):format(count))
