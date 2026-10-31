-- Offline instruction-family generator. C is the backend's primitive instruction
-- description, not a home for library algorithms. Compile this output once.
local out = assert(io.open(assert(arg[1], 'output C path required'), 'wb'))
local function put(s) out:write(s, '\n') end
put('#include "abi.h"\n#include <string.h>\n#include <stdbool.h>')
put('extern cp_handler NEXT, ZERO;\nextern unsigned char OFFSET;\nextern uint64_t LITERAL;')
local fs = 'f0,f1,f2,f3,f4,f5,f6,f7'
local function args(values)
    return 'ctx,' .. table.concat(values, ',') .. ',' .. fs
end
local same = {}; for i = 0, 10 do same[#same + 1] = 'i' .. i end
local function push(value)
    local v = {value}; for i = 0, 9 do v[#v + 1] = 'i' .. i end
    return args(v)
end
local function pop(value)
    local v = {value}; for i = 2, 10 do v[#v + 1] = 'i' .. i end
    v[#v + 1] = '0'
    return args(v)
end
local function drop(refill)
    local v = {}; for i = 1, 10 do v[#v + 1] = 'i' .. i end
    v[#v + 1] = refill or '0'; return args(v)
end
local function replace(value)
    local v = {value}; for i = 1, 10 do v[#v + 1] = 'i' .. i end
    return args(v)
end
local n = 0
local function emit(name, body)
    local used = '(void)ctx;'
    for i = 0, 10 do used = used .. '(void)i' .. i .. ';' end
    for i = 0, 7 do used = used .. '(void)f' .. i .. ';' end
    put('void CP_ABI cp_' .. name .. '(CP_PARAMS) {\n' .. used .. '\n' .. body .. '\n}')
    n = n + 1
end
local function next_(a) return 'CP_TAIL NEXT(' .. a .. ');' end
emit('jump', next_(args(same)))
emit('branch', 'if (i0) { ' .. next_(drop()) .. ' }\nCP_TAIL ZERO(' .. drop() .. ');')
emit('branch_refill', 'uint64_t oldest; memcpy(&oldest, ctx->locals + (uintptr_t)&OFFSET, 8);\n'
    .. 'if (i0) { ' .. next_(drop('oldest')) .. ' }\nCP_TAIL ZERO(' .. drop('oldest') .. ');')
emit('drop', next_(drop()))
emit('literal', next_(push('LITERAL')))
emit('address', next_(push('(uintptr_t)(ctx->locals + (uintptr_t)&OFFSET)')))
emit('user', next_(push('(uintptr_t)ctx->user')))
put('extern unsigned char IMM;')
emit('copy', 'memcpy((void *)(uintptr_t)i1,(const void *)(uintptr_t)i0,(uintptr_t)&IMM);\n' .. next_(args(same)))
emit('copy_reversed', 'memcpy((void *)(uintptr_t)i0,(const void *)(uintptr_t)i1,(uintptr_t)&IMM);\n' .. next_(args(same)))
emit('zero_memory', 'memset((void *)(uintptr_t)i0,0,(uintptr_t)&IMM);\n' .. next_(args(same)))
emit('ret_blob', 'memcpy(ctx->result,(const void *)(uintptr_t)i0,(uintptr_t)&IMM);')
emit('set_result', 'ctx->result=(unsigned char *)(uintptr_t)i0;\n' .. next_(drop()))
emit('set_locals', 'ctx->locals=(unsigned char *)(uintptr_t)i0;\n' .. next_(drop()))
emit('prepare_call', 'memset(ctx->locals + (uintptr_t)&OFFSET, 0, sizeof(cp_call_image));\n' .. next_(args(same)))
emit('invoke_native', 'cp_native_call((cp_call_image *)(ctx->locals + (uintptr_t)&OFFSET));\n' .. next_(args(same)))
emit('invoke_vm', 'cp_vm_call call; memcpy(&call, ctx->locals + (uintptr_t)&OFFSET, sizeof call);\n'
    .. 'if (cp_invoke_frame(call.entry, call.frame_bytes, call.args, call.arg_bytes, call.result)) __builtin_trap();\n'
    .. next_(args(same)))
emit('spill', 'memcpy(ctx->locals + (uintptr_t)&OFFSET, &i10, 8);\n' .. next_(args(same)))
emit('refill', 'memcpy(&i10, ctx->locals + (uintptr_t)&OFFSET, 8);\n' .. next_(args(same)))
-- Every named bank argument is deliberately consumed, even by a return. The
-- compiler removes these void expressions without requiring -Wno-unused-parameter.
local unused = '(void)ctx;'
for i = 0, 10 do unused = unused .. '(void)i' .. i .. ';' end
for i = 0, 7 do unused = unused .. '(void)f' .. i .. ';' end
emit('ret_unit', unused)
emit('unreachable', '__builtin_trap();')
for _,order in ipairs {'RELAXED','ACQUIRE','RELEASE','ACQ_REL','SEQ_CST'} do
    emit('fence_'..order,'__atomic_thread_fence(__ATOMIC_'..order..');\n'..next_(args(same)))
end
local types = {{key='bool', c='bool'}}
for _, signed in ipairs {false, true} do
    for _, bits in ipairs {8, 16, 32, 64} do
        types[#types + 1] = {key=(signed and 'i' or 'u') .. bits,
            c=(signed and 'int' or 'uint') .. bits .. '_t', bits=bits, signed=signed}
    end
end
local bins = {{'add','+'},{'sub','-'},{'mul','*'},{'div','/'},{'mod','%'},
    {'band','&'},{'bor','|'},{'bxor','^'},{'shl','<<'},{'shr','>>'}}
local cmps = {{'eq','=='},{'ne','!='},{'lt','<'},{'le','<='},{'gt','>'},{'ge','>='}}
for _, t in ipairs(types) do
    local function canon(e) return '(uint64_t)(' .. t.c .. ')(' .. e .. ')' end
    local function operand(i)
        local v = '(' .. t.c .. ')i' .. i
        if t.bits and t.bits < 32 then v = '(' .. (t.signed and 'int32_t' or 'uint32_t') .. ')(' .. v .. ')' end
        return '(' .. v .. ')'
    end
    emit('load_' .. t.key, t.c .. ' v; memcpy(&v, ctx->locals + (uintptr_t)&OFFSET, sizeof v);\n'
        .. next_(push('(uint64_t)v')))
    emit('store_' .. t.key, t.c .. ' v = (' .. t.c .. ')i0; memcpy(ctx->locals + (uintptr_t)&OFFSET, &v, sizeof v);\n'
        .. next_(drop()))
    emit('ret_' .. t.key, unused .. '\n' .. t.c .. ' v = (' .. t.c .. ')i0; memcpy(ctx->result, &v, sizeof v);')
    emit('read_' .. t.key, t.c .. ' v; memcpy(&v, (const void *)(uintptr_t)i0, sizeof v);\n' .. next_(replace('(uint64_t)v')))
    emit('write_' .. t.key, t.c .. ' v = (' .. t.c .. ')i0; memcpy((void *)(uintptr_t)i1, &v, sizeof v);\n' .. next_(drop()))
    local atomic_type = 'cp_atomic_' .. t.key
    put('typedef '..t.c..' '..atomic_type..' __attribute__((may_alias));')
    for _, order in ipairs {'RELAXED','ACQUIRE','RELEASE','ACQ_REL','SEQ_CST'} do
        local suffix, native = '_'..t.key..'_'..order, '__ATOMIC_'..order
        local ptr = '('..atomic_type..' *)(uintptr_t)i1'
        if order ~= 'RELEASE' and order ~= 'ACQ_REL' then
            emit('atomic_load'..suffix, t.c..' v=__atomic_load_n(('..atomic_type..' *)(uintptr_t)i0,'..native..');\n'
                ..next_(replace('(uint64_t)v')))
        end
        if order ~= 'ACQUIRE' and order ~= 'ACQ_REL' then
            emit('atomic_store'..suffix, '__atomic_store_n('..ptr..',('..t.c..')i0,'..native..');\n'..next_(drop()))
        end
        local operations = t.bits and {'exchange','fetch_add','fetch_sub'} or {'exchange'}
        for _, operation in ipairs(operations) do
            emit('atomic_'..operation..suffix, t.c..' v=__atomic_'..(operation=='exchange' and 'exchange_n' or operation)..'('..ptr..',('..t.c..')i0,'..native..');\n'
                ..next_(pop('(uint64_t)v')))
        end
        local failure = order == 'RELEASE' and 'RELAXED' or order == 'ACQ_REL' and 'ACQUIRE' or order
        emit('atomic_cas'..suffix, 'bool v=__atomic_compare_exchange_n(('..atomic_type..' *)(uintptr_t)i2,('
            ..atomic_type..' *)(uintptr_t)i0,('..t.c..')i1,false,'..native..',__ATOMIC_'..failure..');\n'
            ..'i2=v;\n'..next_(drop()))
    end
    for _, cmp in ipairs(cmps) do
        emit('cmp_' .. cmp[1] .. '_' .. t.key, next_(pop('(' .. operand(1) .. cmp[2] .. operand(0) .. ')')))
    end
    if t.bits then
        for _, bin in ipairs(bins) do
            emit('bin_' .. bin[1] .. '_' .. t.key, next_(pop(canon(operand(1) .. bin[2] .. operand(0)))))
        end
        emit('un_bnot_' .. t.key, next_(replace(canon('~' .. operand(0)))))
        local neg = t.signed and ('-' .. operand(0)) or ('0u - ' .. operand(0))
        emit('un_neg_' .. t.key, next_(replace(canon(neg))))
    end
    emit('un_not_' .. t.key, next_(replace('!i0')))
    for _, dst in ipairs(types) do
        emit('conv_' .. t.key .. '_' .. dst.key,
            next_(replace('(uint64_t)(' .. dst.c .. ')(' .. t.c .. ')i0')))
    end
end
-- SIMD carriers transport bits; each typed word computes at its native width.
local floats = {{key='f32', c='float'}, {key='f64', c='double'}}
local f_same = {}; for i=0,7 do f_same[#f_same+1]='f'..i end
local zero = '(cp_vec){0,0}'
local function both(iv, fv) return 'ctx,' .. table.concat(iv or same, ',') .. ',' .. table.concat(fv or f_same, ',') end
local function i_push(v) local a={v}; for i=0,9 do a[#a+1]='i'..i end; return a end
local function i_drop() local a={}; for i=1,10 do a[#a+1]='i'..i end; a[#a+1]='0'; return a end
local function f_push(v) local a={v}; for i=0,6 do a[#a+1]='f'..i end; return a end
local function f_drop() local a={}; for i=1,7 do a[#a+1]='f'..i end; a[#a+1]=zero; return a end
local function f_replace(v) local a={v}; for i=1,7 do a[#a+1]='f'..i end; return a end
local function f_pop(v) local a={v}; for i=2,7 do a[#a+1]='f'..i end; a[#a+1]=zero; return a end
emit('spill_f', 'memcpy(ctx->locals + (uintptr_t)&OFFSET, &f7, 16);\n' .. next_(both()))
emit('refill_f', 'memcpy(&f7, ctx->locals + (uintptr_t)&OFFSET, 16);\n' .. next_(both()))
emit('drop_f', next_(both(nil, f_drop())))
for _, t in ipairs(floats) do
    local pack, unpack = 'pack_'..t.key, 'unpack_'..t.key
    put('static inline cp_vec '..pack..'('..t.c..' v) { cp_vec r={0,0}; memcpy(&r,&v,sizeof v); return r; }')
    put('static inline '..t.c..' '..unpack..'(cp_vec v) { '..t.c..' r; memcpy(&r,&v,sizeof r); return r; }')
end
for _, t in ipairs(floats) do
    local pack, unpack = 'pack_'..t.key, 'unpack_'..t.key
    local a, b = unpack..'(f1)', unpack..'(f0)'
    emit('literal_'..t.key, t.c..' v; memcpy(&v,&LITERAL,sizeof v);\n' .. next_(both(nil,f_push(pack..'(v)'))))
    emit('load_'..t.key, t.c..' v; memcpy(&v,ctx->locals+(uintptr_t)&OFFSET,sizeof v);\n' .. next_(both(nil,f_push(pack..'(v)'))))
    emit('store_'..t.key, t.c..' v='..b..'; memcpy(ctx->locals+(uintptr_t)&OFFSET,&v,sizeof v);\n' .. next_(both(nil,f_drop())))
    emit('ret_'..t.key, t.c..' v='..b..'; memcpy(ctx->result,&v,sizeof v);')
    emit('read_'..t.key, t.c..' v; memcpy(&v,(const void *)(uintptr_t)i0,sizeof v);\n' .. next_(both(i_drop(),f_push(pack..'(v)'))))
    emit('write_'..t.key, t.c..' v='..b..'; memcpy((void *)(uintptr_t)i0,&v,sizeof v);\n' .. next_(both(nil,f_drop())))
    for _, op in ipairs {{'add','+'},{'sub','-'},{'mul','*'},{'div','/'}} do
        emit('bin_'..op[1]..'_'..t.key, next_(both(nil,f_pop(pack..'('..a..op[2]..b..')'))))
    end
    for _, op in ipairs(cmps) do
        -- Pop one float here; the lowering emits drop_f for the second. This
        -- lets a normal refill restore the correct oldest lane at each pop.
        emit('cmp_'..op[1]..'_'..t.key, next_(both(i_push('('..a..op[2]..b..')'),f_drop())))
    end
    emit('un_neg_'..t.key, next_(both(nil,f_replace(pack..'(-'..b..')'))))
    emit('un_not_'..t.key, next_(both(i_push('!'..b),f_drop())))
    for _, dst in ipairs(floats) do
        emit('conv_'..t.key..'_'..dst.key, next_(both(nil,f_replace('pack_'..dst.key..'(('..dst.c..')'..b..')'))))
    end
    for _, it in ipairs(types) do
        emit('conv_'..t.key..'_'..it.key, next_(both(i_push('(uint64_t)('..it.c..')'..b),f_drop())))
        emit('conv_'..it.key..'_'..t.key, next_(both(i_drop(),f_push(pack..'(('..t.c..')('..it.c..')i0)'))))
    end
end
out:close()
print(('direct meta-stencils: generated %d handlers'):format(n))
