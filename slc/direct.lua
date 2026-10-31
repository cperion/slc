-- EXPERIMENTAL / DEPRECATED: not for production use. Use the default libgccjit
-- backend instead. Retained for reference and reproducible measurements.
-- Direct native execution: shared prepared IR, offline stencils, explicit C
-- bridges. Unsupported IR is rejected; no compiler subprocess or fallback.
local ffi = require 'ffi'
local G = require 'slc.cgen'
local ABI = require 'slc.direct.abi'
local Lower = require 'slc.direct.lower'
local Layout = require 'slc.direct.layout'
local RuntimeMeta = require 'slc.direct.runtime_meta'
local Assemble = require 'slc.direct.assemble'
local D = {results={}}
local active_arguments = {} -- native callbacks may re-enter Lua and collect
local here = debug.getinfo(1, 'S').source:match('^@(.*)/slc/direct.lua$') or '.'
local function bits(value)
    local word = ffi.new('uint64_t[1]', value)
    return ffi.string(word, 8)
end
local function release(memory, bytes)
    ffi.gc(memory, nil); ffi.C.munmap(memory, bytes)
end
local function compile(mod, opts)
    opts = opts or {}
    local dir = opts.direct_dir or (here .. '/build/direct')
    local chunk, why = loadfile(dir .. '/stencils.lua')
    if not chunk then error('direct: missing prebuilt stencil pack; run make direct\n' .. tostring(why), 0) end
    local pack = chunk()
    local ok, lib = pcall(ABI.load, dir .. '/libslc_direct.so')
    if not ok then error('direct: prebuilt bridge unavailable; run make direct\n' .. tostring(lib), 0) end
    local libraries = {}
    for _, path in ipairs(opts.libs or {}) do libraries[#libraries + 1] = ffi.load(path, true) end
    local fns = G.prepare(mod)
    local plans, bases, nodes, symbols, globals = {}, {}, {}, {}, {}
    local tls_offsets,tls_bytes={},0
    local out = {raw={}, types={}, arity={}, backend='direct'}
    if #fns == 0 then return out end
    local meta = RuntimeMeta.new(opts.runtime_metadata or (dir .. '/runtime-meta.lua'), here .. '/runtime')
    local layout = Layout.new(meta)
    for _, fn in ipairs(fns) do plans[fn] = Lower.plan(fn, pack, layout) end
    local io_backend = os.getenv('SLC_IO') or 'poll'
    local runtime_ok, runtime = pcall(require('slc.native').runtime_prebuilt,
        opts.runtime_path or (dir .. '/libslc_rt-' .. io_backend .. '.so'))
    if not runtime_ok then error('direct: prebuilt shared runtime unavailable; run make direct\n' .. tostring(runtime), 0) end
    local runtime_name = io_backend == 'uring' and 'io_uring' or io_backend
    assert(ffi.string(runtime.slc_io_backend()) == runtime_name, 'direct: shared runtime I/O backend mismatch')
    local guard = ffi.cast('void *', runtime.slc_try)
    libraries[#libraries + 1] = ffi.load(dir .. '/libslc_direct_rt.so', true)
    local function symbol(name)
        if symbols[name] then return symbols[name] end
        local address
        if name == 'cp_native_call' or name == 'cp_invoke_frame' or name == 'cp_tls_get' then
            address = ffi.cast('void *', lib[name])
        else address = ffi.C.dlsym(nil, (meta.proof.inlines or {})[name] or name) end
        if address == nil then error('direct: unresolved native symbol ' .. name .. '; supply its prebuilt library', 0) end
        symbols[name] = address; return address
    end
    -- Resolve externs before allocating executable storage. Only ordinary symbol
    -- lookup occurs here; C headers and macros must have prebuilt metadata.
    for _, fn in ipairs(fns) do
        local plan = plans[fn]
        bases[fn] = #nodes
        for _, node in ipairs(plan.nodes) do
            if node.SYMBOL then node.LITERAL = bits(ffi.cast('uintptr_t', symbol(node.SYMBOL))) end
            if node.TLS_GLOBAL and not tls_offsets[node.TLS_GLOBAL] then
                local d=layout:of(node.TLS_GLOBAL.T)
                local offset=math.ceil(tls_bytes/d.align)*d.align
                tls_offsets[node.TLS_GLOBAL]=offset; tls_bytes=offset+math.max(1,d.size)
            end
            if node.GLOBAL then
                local g = node.GLOBAL
                if not globals[g] then
                    local value = ffi.new(layout:of(g.T).ctype .. '[1]')
                    if g.init ~= nil then value[0] = g.init end
                    globals[g] = value
                end
                node.LITERAL = bits(ffi.cast('uintptr_t', globals[g]))
            end
            for _, r in ipairs(pack.stencils[node.op].relocs) do
                if r.symbol == 'cp_native_call' or r.symbol == 'cp_invoke_frame' or r.symbol == 'memset' or r.symbol == 'memcpy' then
                    symbol(r.symbol)
                end
            end
            nodes[#nodes + 1] = node
        end
    end
    local entries = {}
    for _,fn in ipairs(fns) do
        local plan=plans[fn]
        entries[#entries+1]={fn=fn,key=fn,entry=plan.native_entry,bytes=fn.task and 0 or plan.frame_bytes,
            finish=plan.native_finish,float=fn.ret.kind=='float'}
        for _,block in ipairs(plan.blocks) do
            entries[#entries+1]={fn=fn,key=block,entry=block.native_entry,bytes=0}
        end
    end
    local stub_bytes = #entries * 32
    local raw = ffi.C.mmap(nil, stub_bytes, 3, 0x22, -1, 0)
    assert(raw ~= ffi.cast('void *', -1), 'direct: entry allocation failed')
    local stubs = ffi.gc(ffi.cast('uint8_t *', raw), function(p) ffi.C.munmap(p, stub_bytes) end)
    local unit,tls
    local fine, result = pcall(function()
        if tls_bytes>0 then
            local initial=ffi.new('uint8_t[?]',tls_bytes)
            for g,offset in pairs(tls_offsets) do
                if g.init~=nil then ffi.cast(layout:of(g.T).ctype..' *',initial+offset)[0]=g.init end
            end
            tls=lib.cp_tls_new(tls_bytes,initial)
            assert(tls~=nil,'direct: native TLS key allocation failed')
            tls=ffi.gc(tls,lib.cp_tls_destroy)
        end
        local native_ptrs = {}
        for i, item in ipairs(entries) do native_ptrs[item.key] = stubs + (i - 1) * 32 end
        for _, fn in ipairs(fns) do
            local base = bases[fn]
            for _, node in ipairs(plans[fn].nodes) do
                if node.ENTRY then
                    local callee = node.ENTRY
                    node.ENTRY = assert(bases[callee]) + plans[callee].body_entry
                elseif node.TLS_GLOBAL then node.LITERAL=bits(assert(tls_offsets[node.TLS_GLOBAL]))
                elseif node.TLS_DESCRIPTOR then node.LITERAL=bits(ffi.cast('uintptr_t',assert(tls)))
                elseif node.FRAME then node.LITERAL = bits(assert(plans[node.FRAME]).frame_bytes)
                elseif node.FUNCTION then node.LITERAL = bits(ffi.cast('uintptr_t', assert(native_ptrs[node.FUNCTION]))) end
                for _, edge in ipairs {'NEXT', 'ZERO'} do
                    if node[edge] then node[edge] = node[edge] + base end
                end
            end
        end
        unit = Assemble.build(pack, nodes, symbols)
        local descriptors = ffi.new('cp_entry_desc[?]', #entries)
        local exports = ffi.new('cp_export_desc[?]', #entries)
        for i, item in ipairs(entries) do
            exports[i - 1].entry = unit.memory + unit.offsets[bases[item.fn] + item.entry]
            exports[i - 1].frame_bytes = item.bytes
            if item.finish then exports[i - 1].finish = unit.memory + unit.offsets[bases[item.fn] + item.finish] end
            exports[i - 1].result_offset = ffi.offsetof('cp_call_image', item.float and 'ret_xmm' or 'ret_gpr')
            descriptors[i - 1].dispatch = lib.cp_export_dispatch
            descriptors[i - 1].user = ffi.cast('cp_export_desc *', exports) + i - 1
            lib.cp_entry_write(native_ptrs[item.key], ffi.cast('cp_entry_desc *', descriptors) + i - 1)
        end
        assert(ffi.C.mprotect(stubs, stub_bytes, 5) == 0, 'direct: entry publication failed')
        for _, fn in ipairs(mod.exports) do
            local plan = assert(plans[fn])
            local entry = unit.memory + unit.offsets[bases[fn] + plan.body_entry]
            local ps = {}; for i, p in ipairs(fn.params) do ps[i] = layout:of(p.T).ctype end
            local ret = layout:of(fn.ret)
            local signature = ret.ctype .. ' (*)(' .. (#ps > 0 and table.concat(ps, ',') or 'void') .. ')'
            local raw_entry = ffi.cast(signature, native_ptrs[fn])
            local function invoke(...)
                if select('#', ...) ~= #fn.params then
                    error(('direct: %s expects %d arguments'):format(fn.export_name or fn.cname, #fn.params), 2)
                end
                local values = {...}
                local args = ffi.new('uint8_t[?]', math.max(1, plan.arg_bytes))
                for i, p in ipairs(fn.params) do
                    ffi.cast(layout:of(p.T).ctype .. ' *', args + plan.params[p.name])[0] = values[i]
                end
                local value = ffi.new(ret.kind == 'unit' and 'uint8_t[1]' or (ret.ctype .. '[1]'))
                active_arguments[values] = true
                local status = lib.cp_try_invoke(guard, entry, plan.frame_bytes, args, plan.arg_bytes, value)
                active_arguments[values] = nil
                if status == 1 then error('slc runtime check failed: ' .. ffi.string(runtime.slc_trap_message()), 2) end
                assert(status == 0, 'direct: invalid invocation frame')
                if ret.kind == 'record' then return ffi.new(ret.ctype, value[0]) end
                if ret.kind ~= 'unit' then return value[0] end
            end
            -- LuaJIT cannot safely enter a Lua FFI callback from a compiled
            -- FFI-call trace. Only this host marshaling wrapper stays untraced;
            -- the entire guest, including task steps, is still native code.
            require('jit').off(invoke)
            out[fn.cname], out.arity[fn.cname], out.raw[fn.cname] = invoke, #fn.params, raw_entry
            if fn.export_name then
                out[fn.export_name], out.arity[fn.export_name], out.raw[fn.export_name] = invoke, #fn.params, raw_entry
            end
        end
        for t, d in pairs(layout.cache) do
            if d.kind == 'record' then out.types[G.ctype(t)] = ffi.typeof(d.ctype) end
        end
        D.results[#D.results + 1] = {unit=unit, stubs=stubs, descriptors=descriptors, exports=exports,
            plans=plans, library=lib, libraries=libraries, runtime=runtime, globals=globals, tls=tls}
        out.direct = {plans=plans, unit=unit}
        return out
    end)
    if not fine then
        if tls~=nil then ffi.gc(tls,nil); lib.cp_tls_destroy(tls) end
        release(stubs, stub_bytes)
        if unit then release(unit.memory, unit.size) end
        error(result, 0)
    end
    return result
end
function D.compile(mod, opts)
    local S = require 'slc.stage'
    local saved = S.module; S.module = mod
    local ok, result = pcall(compile, mod, opts)
    S.module = saved
    if not ok then error(result, 0) end
    return result
end
return D
