-- Exercise separate compilation with one shared source type. In particular,
-- native(word)'s export view must not inherit its parent's prepared layouts.
return function(slc, with_direct)
    local ffi = require 'ffi'
    local S = require 'slc.stage'
    local G = require 'slc.cgen'
    local N = require 'slc.native'
    local checks = 0
    local function check(ok, message) assert(ok, message); checks = checks + 1 end
    local source = [[
local Record = struct { prefix: U32, value: U32, suffix: U32 }
local private_count = do(n: U32): U32
    local r = Record { prefix = 101, value = 0, suffix = 303 }
    while r.value < n do r.value = r.value + 1 end
    return r.prefix + r.value + r.suffix
end
export private_count
local read_record = do(r: Ref Record): U32 = r.value
local make_record = do(n: U32): Record
    return Record { prefix = 101, value = n, suffix = 303 }
end
local ReadRecord = Fn({ Ref Record }, U32)
local call_reader = do(r: Ref Record, f: ReadRecord): U32 = f r
boundary = { Record = Record, read = read_record, make = make_record, call = call_reader }
]]
    local _, mod, env = slc.compile(source, 'tests/storage_boundaries.slc', { no_c = true })
    local parent = N.compile(mod, { check_layouts = true })
    local record = env.boundary.Record
    check(mod.prepared_n == 1, 'regression needs equal-sized export views')
    check(#assert(mod.storage_layouts[record]) == 1, 'parent record should be compact')
    check(ffi.sizeof(parent.types.Record) == 4, 'parent native layout should be compact')
    check(parent.private_count(7) == 411, 'parent computation')
    local before = G.emit(mod)
    S.module = mod
    local read, raw_read = env.native(env.boundary.read)
    local words = ffi.new('uint32_t[3]', {101, 29, 303})
    check(read(ffi.cast('void *', words)) == 29, 'native word must retain declared field offsets')
    local make = env.native(env.boundary.make)
    local value = make(47)
    check(ffi.sizeof(value) == 12 and value.prefix == 101 and value.value == 47 and value.suffix == 303,
        'native aggregate return must retain all declared fields')
    local box = ffi.new(ffi.typeof('$[1]', ffi.typeof(value)), value)
    local call = env.native(env.boundary.call)
    check(call(ffi.cast('void *', box), raw_read) == 47, 'record passed between separate native words')
    check(read(ffi.cast('void *', box)) == 47, 'native return passed to another native word')
    check(G.emit(mod) == before and #mod.storage_layouts[record] == 1,
        'native views must not change the parent layout')
    check(parent.private_count(9) == 413, 'parent remains callable after native compilation')
    if with_direct then
        local D = require 'slc.direct'
        -- Direct retains the complete private layout even for the already
        -- prepared parent; execute both while sharing the C-built runtime.
        local full = D.compile(mod)
        check(ffi.sizeof(full.types.Record) == 12, 'direct private record uses declared layout')
        check(full.private_count(7) == parent.private_count(7), 'direct/gccjit private execution')
        local reader = S.native_word(env.boundary.read)
        local caller = S.native_word(env.boundary.call)
        local view = setmetatable({ exports = { reader, caller } }, { __index = mod })
        local direct = D.compile(view)
        check(direct[caller.cname](ffi.cast('void *', box), raw_read) == 47,
            'direct caller passes gccjit-produced record to gccjit native word')
        check(call(ffi.cast('void *', box), direct.raw[reader.cname]) == 47,
            'gccjit caller passes gccjit-produced record to direct word')
    end
    -- slc.load exposes per-unit FFI types. Only ABI-visible records are
    -- interchangeable; private records can deliberately have different sizes.
    local first = slc.load('examples/storage_layout.slc')
    local second = slc.load('examples/storage_layout.slc', with_direct and { backend = 'direct' } or nil)
    check(ffi.sizeof(first.types.CompactCounter) == 4, 'loaded gccjit private layout')
    check(ffi.sizeof(second.types.CompactCounter) == (with_direct and 12 or 4), 'loaded unit private layout')
    check(ffi.sizeof(first.types.PublicEnvelope) == 16 and ffi.sizeof(second.types.PublicEnvelope) == 16,
        'separately loaded units preserve exported nested layout')
    local left = ffi.new(ffi.typeof('$[1]', first.types.PublicEnvelope), { { 101, { 202, 303 }, 404 } })
    local right = ffi.new(ffi.typeof('$[1]', second.types.PublicEnvelope), { { 505, { 606, 707 }, 808 } })
    second.public_increment(ffi.cast('void *', left))
    first.public_increment(ffi.cast('void *', right))
    check(left[0].prefix == 101 and left[0].counter.config == 202
        and left[0].counter.count == 304 and left[0].suffix == 404, 'first unit record passed to second')
    check(right[0].prefix == 505 and right[0].counter.config == 606
        and right[0].counter.count == 708 and right[0].suffix == 808, 'second unit record passed to first')
    return checks
end
