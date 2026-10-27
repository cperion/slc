-- slc.cjit: C, spoken to libgccjit directly.
--
-- Two parts share one set of C rules:
--
--   * a core: C types, values and operations (the usual arithmetic conversions,
--     pointer arithmetic, truth values, members, calls), and function bodies
--     built as a control-flow graph that is handed to gccjit when complete;
--   * a reader for the C the compiler itself contains: the runtime header
--     slc_rt.h, the per-type helpers, and the runtime-call templates in the IR.
--     Each of those exists once, as C; the C backend prints it, this reads it.
--
-- The emitter (slc.jitgen) drives the core from the residual IR, mirroring
-- slc.cgen: where cgen writes C, it calls this.

local ffi = require 'ffi'

local C = {}
local J

function C.lib()
    if J then return J end
    ffi.cdef(require 'slc.gccjit_h')
    local name = os.getenv('SLC_GCCJIT')
    local ok, lib = pcall(ffi.load, name or 'libgccjit.so.0')
    if not ok then
        ok, lib = pcall(ffi.load, 'gccjit')
        if not ok then error('gccjit backend: cannot load libgccjit (' .. tostring(lib) .. ')', 0) end
    end
    J = lib
    return J
end

local function fail(msg) error('gccjit backend: ' .. msg, 0) end
C.fail = fail

-- C types -------------------------------------------------------------------------------------
-- Descriptors are plain Lua and belong to no context; each context makes its
-- own gccjit types from them.

local Ty = {}
Ty.__index = Ty
Ty.__tostring = function(t) return C.show(t) end
local function ty(x) return setmetatable(x, Ty) end

local ints = {}
function C.int(size, signed)
    local k = size * 2 + (signed and 1 or 0)
    if not ints[k] then ints[k] = ty { k = 'int', size = size, signed = signed } end
    return ints[k]
end
local floats = {}
function C.float(size)
    if not floats[size] then floats[size] = ty { k = 'float', size = size } end
    return floats[size]
end
C.BOOL = ty { k = 'bool', size = 1 }
C.VOID = ty { k = 'void', size = 1 }
C.INT = C.int(4, true)
C.UINT = C.int(4, false)
C.SIZE = C.int(8, false)
C.CHAR = C.int(1, true)
C.U8 = C.int(1, false)

local ptrs = setmetatable({}, { __mode = 'k' })
function C.ptr(t)
    if not ptrs[t] then ptrs[t] = ty { k = 'ptr', to = t } end
    return ptrs[t]
end
C.VOIDP = C.ptr(C.VOID)
C.CHARP = C.ptr(C.CHAR)

local arrays = setmetatable({}, { __mode = 'k' })
function C.array(t, n)
    arrays[t] = arrays[t] or {}
    if not arrays[t][n] then arrays[t][n] = ty { k = 'array', of = t, n = n } end
    return arrays[t][n]
end

function C.fntype(ret, params, variadic)
    return ty { k = 'fn', ret = ret, params = params, variadic = variadic or false }
end

-- a struct or union, completed by set_fields (fields: { {name, type}, ... })
local anon = 0
function C.record(kind, name)
    if not name then anon = anon + 1; name = '__anon' .. anon end
    return ty { k = kind, name = name, fields = nil }
end
function Ty:set_fields(list)
    if self.fields then fail('fields of ' .. self.name .. ' set twice') end
    self.fields, self.byname = list, {}
    for i, f in ipairs(list) do self.byname[f[1]] = i end
    return self
end

function C.show(t)
    if t.k == 'int' then return (t.signed and 'int' or 'uint') .. t.size * 8 end
    if t.k == 'float' then return t.size == 4 and 'float' or 'double' end
    if t.k == 'ptr' then return C.show(t.to) .. '*' end
    if t.k == 'array' then return C.show(t.of) .. '[' .. t.n .. ']' end
    if t.k == 'fn' then return 'fn' end
    if t.k == 'struct' or t.k == 'union' then return t.k .. ' ' .. t.name end
    return t.k
end

local function scalar(t) return t.k == 'int' or t.k == 'float' or t.k == 'bool' or t.k == 'ptr' end
local function arith(t) return t.k == 'int' or t.k == 'float' or t.k == 'bool' end
C.scalar, C.arith = scalar, arith

-- layout (LP64), for sizeof and zeroing
assert(ffi.abi('64bit'), 'gccjit backend: 64-bit targets only')
function C.alignof(t)
    if t.k == 'int' or t.k == 'float' or t.k == 'bool' then return t.size end
    if t.k == 'ptr' or t.k == 'fn' then return 8 end
    if t.k == 'array' then return C.alignof(t.of) end
    if t.k == 'struct' or t.k == 'union' then
        if not t.fields then fail('incomplete type ' .. t.name) end
        local a = 1
        for _, f in ipairs(t.fields) do a = math.max(a, C.alignof(f[2])) end
        return a
    end
    if t.k == 'void' then return 1 end
    fail('no alignment for ' .. C.show(t))
end
function C.sizeof(t)
    if t.k == 'int' or t.k == 'float' or t.k == 'bool' then return t.size end
    if t.k == 'ptr' or t.k == 'fn' then return 8 end
    if t.k == 'array' then return t.n * C.sizeof(t.of) end
    if t.k == 'struct' or t.k == 'union' then
        if not t.fields then fail('incomplete type ' .. t.name) end
        local size, align = 0, C.alignof(t)
        for _, f in ipairs(t.fields) do
            local fs, fa = C.sizeof(f[2]), C.alignof(f[2])
            if t.k == 'struct' then
                size = math.ceil(size / fa) * fa + fs
            else
                size = math.max(size, fs)
            end
        end
        return math.ceil(size / align) * align
    end
    if t.k == 'void' then return 1 end
    fail('no size for ' .. C.show(t))
end
function C.offsetof(t, name)
    local off = 0
    for _, f in ipairs(t.fields) do
        local fa = C.alignof(f[2])
        off = math.ceil(off / fa) * fa
        if f[1] == name then return off end
        off = off + C.sizeof(f[2])
    end
    fail('no field ' .. name .. ' in ' .. t.name)
end

-- the usual arithmetic conversions -----------------------------------------------------------

local function promote(t)
    if t.k == 'bool' then return C.INT end
    if t.k == 'int' and t.size < 4 then return C.INT end
    return t
end
C.promote = promote

local function common(a, b)
    a, b = promote(a), promote(b)
    if a.k == 'float' or b.k == 'float' then
        local s = math.max(a.k == 'float' and a.size or 0, b.k == 'float' and b.size or 0)
        return C.float(s)
    end
    if a == b then return a end
    if a.signed == b.signed then return a.size >= b.size and a or b end
    local u, s = a, b
    if a.signed then u, s = b, a end
    if u.size >= s.size then return u end
    return s
end
C.common = common

-- contexts -------------------------------------------------------------------------------------

local Ctx = {}
Ctx.__index = Ctx

function C.context(opts)
    C.lib()
    opts = opts or {}
    local c = J.gcc_jit_context_acquire()
    J.gcc_jit_context_set_int_option(c, J.GCC_JIT_INT_OPTION_OPTIMIZATION_LEVEL, opts.opt or 2)
    J.gcc_jit_context_set_bool_allow_unreachable_blocks(c, 1)
    J.gcc_jit_context_set_bool_print_errors_to_stderr(c, 0)
    if opts.debug then J.gcc_jit_context_set_bool_option(c, J.GCC_JIT_BOOL_OPTION_DEBUGINFO, 1) end
    if opts.dump then J.gcc_jit_context_set_bool_option(c, J.GCC_JIT_BOOL_OPTION_DUMP_GENERATED_CODE, 1) end
    if opts.pic ~= false then J.gcc_jit_context_add_command_line_option(c, '-fPIC') end
    local self = setmetatable({ c = c, jts = {}, jfields = {}, fns = {}, globals = {}, keep = {},
                                strings = {} }, Ctx)
    return self
end

function Ctx:check()
    local e = J.gcc_jit_context_get_first_error(self.c)
    if e ~= nil then fail(ffi.string(e)) end
end

function Ctx:release()
    if self.c ~= nil then J.gcc_jit_context_release(self.c); self.c = nil end
end

-- a gccjit type for a descriptor
function Ctx:jt(t)
    local j = self.jts[t]
    if j then return j end
    local c = self.c
    if t.k == 'int' then
        j = J.gcc_jit_context_get_int_type(c, t.size, t.signed and 1 or 0)
    elseif t.k == 'float' then
        j = J.gcc_jit_context_get_type(c, t.size == 4 and J.GCC_JIT_TYPE_FLOAT or J.GCC_JIT_TYPE_DOUBLE)
    elseif t.k == 'bool' then
        j = J.gcc_jit_context_get_type(c, J.GCC_JIT_TYPE_BOOL)
    elseif t.k == 'void' then
        j = J.gcc_jit_context_get_type(c, J.GCC_JIT_TYPE_VOID)
    elseif t.k == 'ptr' then
        if t.to.k == 'fn' then
            local f = t.to
            local ps = ffi.new('gcc_jit_type*[?]', math.max(#f.params, 1))
            for i, p in ipairs(f.params) do ps[i - 1] = self:jt(p) end
            j = J.gcc_jit_context_new_function_ptr_type(c, nil, self:jt(f.ret), #f.params, ps, f.variadic and 1 or 0)
        else
            j = J.gcc_jit_type_get_pointer(self:jt(t.to))
        end
    elseif t.k == 'array' then
        j = J.gcc_jit_context_new_array_type(c, nil, self:jt(t.of), t.n)
    elseif t.k == 'struct' then
        local st = J.gcc_jit_context_new_opaque_struct(c, nil, t.name)
        j = J.gcc_jit_struct_as_type(st)
        self.jts[t] = j
        if t.fields then
            local fs = ffi.new('gcc_jit_field*[?]', math.max(#t.fields, 1))
            for i = 1, #t.fields do fs[i - 1] = self:field(t, i) end
            J.gcc_jit_struct_set_fields(st, nil, #t.fields, fs)
        end
        return j
    elseif t.k == 'union' then
        local fs = ffi.new('gcc_jit_field*[?]', math.max(#t.fields, 1))
        for i = 1, #t.fields do fs[i - 1] = self:field(t, i) end
        j = J.gcc_jit_context_new_union_type(c, nil, t.name, #t.fields, fs)
    elseif t.k == 'fn' then
        fail('a function type is not a value type')
    end
    if j == nil then self:check(); fail('no type for ' .. C.show(t)) end
    self.jts[t] = j
    return j
end

function Ctx:field(t, i)
    self.jfields[t] = self.jfields[t] or {}
    local f = self.jfields[t][i]
    if not f then
        local d = t.fields[i]
        f = J.gcc_jit_context_new_field(self.c, nil, self:jt(d[2]), d[1])
        self.jfields[t][i] = f
    end
    return f
end

-- values -----------------------------------------------------------------------------------------
-- { t = descriptor, rv = rvalue | lv = lvalue, null = a null pointer constant }

local V = {}
V.__index = V
local function val(t, rv, extra)
    local v = setmetatable({ t = t, rv = rv }, V)
    if extra then for k, x in pairs(extra) do v[k] = x end end
    return v
end
local function lval(t, lv) return setmetatable({ t = t, lv = lv }, V) end
C.val, C.lval = val, lval

function Ctx:rv(v)
    if v.rv then return v.rv end
    if v.lv then return J.gcc_jit_lvalue_as_rvalue(v.lv) end
    if v.fn then return J.gcc_jit_function_get_address(self:fn_of(v.fn), nil) end
    fail('not a value')
end

function Ctx:int_const(t, n)
    if t.k == 'bool' then
        return val(t, n ~= 0 and J.gcc_jit_context_one(self.c, self:jt(t)) or J.gcc_jit_context_zero(self.c, self:jt(t)))
    end
    if t.k == 'float' then return val(t, J.gcc_jit_context_new_rvalue_from_double(self.c, self:jt(t), tonumber(n))) end
    if type(n) == 'number' and n >= -2147483648 and n <= 2147483647 and t.size <= 4 then
        return val(t, J.gcc_jit_context_new_rvalue_from_int(self.c, self:jt(t), n), { const = n })
    end
    local as_long
    if type(n) == 'number' then
        if n >= 2^63 then as_long = ffi.cast('int64_t', ffi.cast('uint64_t', n)) else as_long = n end
    else
        as_long = ffi.cast('int64_t', n)
    end
    return val(t, J.gcc_jit_context_new_rvalue_from_long(self.c, self:jt(t), as_long), { const = n })
end

function Ctx:zero(t)
    if scalar(t) then
        if t.k == 'ptr' then return val(t, J.gcc_jit_context_null(self.c, self:jt(t)), { null = true }) end
        return self:int_const(t, 0)
    end
    if t.k == 'struct' then
        return val(t, J.gcc_jit_context_new_struct_constructor(self.c, nil, self:jt(t), 0, nil, nil))
    end
    if t.k == 'array' then
        return val(t, J.gcc_jit_context_new_array_constructor(self.c, nil, self:jt(t), 0, nil))
    end
    if t.k == 'union' then
        return val(t, J.gcc_jit_context_new_union_constructor(self.c, nil, self:jt(t), nil, nil))
    end
    fail('no zero for ' .. C.show(t))
end

function Ctx:string(s)
    local r
    if s:find('\0', 1, true) then
        -- new_string_literal takes a NUL-terminated C string, not a byte span.
        -- Preserve binary literals in a constant, internally owned byte array.
        self.byte_strings = self.byte_strings or {}
        if self.byte_strings[s] then return self.byte_strings[s] end
        self.byte_string_count = (self.byte_string_count or 0) + 1
        local bytes = s .. '\0'
        local char = J.gcc_jit_type_get_const(self:jt(C.CHAR))
        local array = J.gcc_jit_context_new_array_type(self.c, nil, char, #bytes)
        local global = J.gcc_jit_context_new_global(self.c, nil, J.GCC_JIT_GLOBAL_INTERNAL,
            array, '__slc_binary_literal_' .. self.byte_string_count)
        J.gcc_jit_global_set_initializer(global, bytes, #bytes)
        r = J.gcc_jit_lvalue_get_address(global, nil)
        local value = val(C.CHARP, J.gcc_jit_context_new_cast(self.c, nil, r, self:jt(C.CHARP)))
        self.byte_strings[s] = value
        return value
    end
    r = J.gcc_jit_context_new_string_literal(self.c, s)
    return val(C.CHARP, J.gcc_jit_context_new_cast(self.c, nil, r, self:jt(C.CHARP)))
end

function Ctx:float_const(t, x)
    return val(t, J.gcc_jit_context_new_rvalue_from_double(self.c, self:jt(t), x))
end

-- truth: a bool rvalue
function Ctx:truth(v)
    local t = v.t
    if t.k == 'bool' then return v end
    if t.k == 'ptr' then
        return val(C.BOOL, J.gcc_jit_context_new_comparison(self.c, nil, J.GCC_JIT_COMPARISON_NE, self:rv(v),
            J.gcc_jit_context_null(self.c, self:jt(t))))
    end
    if t.k == 'int' or t.k == 'float' then
        return val(C.BOOL, J.gcc_jit_context_new_comparison(self.c, nil, J.GCC_JIT_COMPARISON_NE, self:rv(v),
            self:rv(self:int_const(t, 0))))
    end
    fail('not a truth value: ' .. C.show(t))
end

-- conversion as by assignment or cast
function Ctx:conv(v, t)
    local from = v.t
    if from == t then return v end
    if t.k == 'void' then return val(t, self:rv(v)) end
    if t.k == 'bool' then return self:truth(v) end
    if (from.k == 'int' or from.k == 'float' or from.k == 'bool') and (t.k == 'int' or t.k == 'float') then
        return val(t, J.gcc_jit_context_new_cast(self.c, nil, self:rv(v), self:jt(t)))
    end
    if t.k == 'ptr' and from.k == 'ptr' then
        return val(t, J.gcc_jit_context_new_cast(self.c, nil, self:rv(v), self:jt(t)))
    end
    if t.k == 'ptr' and (v.null or (from.k == 'int' and v.const == 0)) then
        return val(t, J.gcc_jit_context_null(self.c, self:jt(t)), { null = true })
    end
    if t.k == 'ptr' and from.k == 'array' and v.lv then
        -- an array decays to a pointer to its first element
        local first = J.gcc_jit_context_new_array_access(self.c, nil, self:rv(v), self:rv(self:int_const(C.INT, 0)))
        return self:conv(val(C.ptr(from.of), J.gcc_jit_lvalue_get_address(first, nil)), t)
    end
    if t.k == 'ptr' and from.k == 'int' and from.size == 8 then
        return val(t, J.gcc_jit_context_new_bitcast(self.c, nil, self:rv(v), self:jt(t)))
    end
    if t.k == 'int' and from.k == 'ptr' then
        local u = J.gcc_jit_context_new_bitcast(self.c, nil, self:rv(v), self:jt(C.SIZE))
        return self:conv(val(C.SIZE, u), t)
    end
    if (t.k == 'struct' or t.k == 'union' or t.k == 'array') and from == t then return v end
    if t.k == 'ptr' and from.k == 'fn' then
        return val(t, J.gcc_jit_context_new_cast(self.c, nil, self:rv(v), self:jt(t)))
    end
    fail(('cannot convert %s to %s'):format(C.show(from), C.show(t)))
end

local BINOPS = {
    ['+'] = 'GCC_JIT_BINARY_OP_PLUS', ['-'] = 'GCC_JIT_BINARY_OP_MINUS', ['*'] = 'GCC_JIT_BINARY_OP_MULT',
    ['/'] = 'GCC_JIT_BINARY_OP_DIVIDE', ['%'] = 'GCC_JIT_BINARY_OP_MODULO', ['&'] = 'GCC_JIT_BINARY_OP_BITWISE_AND',
    ['|'] = 'GCC_JIT_BINARY_OP_BITWISE_OR', ['^'] = 'GCC_JIT_BINARY_OP_BITWISE_XOR',
    ['<<'] = 'GCC_JIT_BINARY_OP_LSHIFT', ['>>'] = 'GCC_JIT_BINARY_OP_RSHIFT',
}
local CMPS = {
    ['=='] = 'GCC_JIT_COMPARISON_EQ', ['!='] = 'GCC_JIT_COMPARISON_NE', ['<'] = 'GCC_JIT_COMPARISON_LT',
    ['<='] = 'GCC_JIT_COMPARISON_LE', ['>'] = 'GCC_JIT_COMPARISON_GT', ['>='] = 'GCC_JIT_COMPARISON_GE',
}

-- &p[i]
function Ctx:offset_ptr(p, i)
    local el = J.gcc_jit_context_new_array_access(self.c, nil, self:rv(p), self:rv(i))
    return val(p.t, J.gcc_jit_lvalue_get_address(el, nil))
end

function Ctx:binop(op, a, b)
    -- pointer arithmetic
    if a.t.k == 'array' and a.lv then a = self:conv(a, C.ptr(a.t.of)) end
    if b.t.k == 'array' and b.lv then b = self:conv(b, C.ptr(b.t.of)) end
    if a.t.k == 'ptr' and (op == '+' or op == '-') and b.t.k ~= 'ptr' then
        local i = self:conv(b, C.int(8, true))
        if op == '-' then i = self:unop('-', i) end
        return self:offset_ptr(a, i)
    end
    if b.t.k == 'ptr' and op == '+' then return self:binop('+', b, a) end
    if a.t.k == 'ptr' and b.t.k == 'ptr' and op == '-' then
        local d = self:binop('-', self:conv(a, C.int(8, true)), self:conv(b, C.int(8, true)))
        local sz = math.max(C.sizeof(a.t.to.k == 'void' and C.U8 or a.t.to), 1)
        return self:binop('/', d, self:int_const(C.int(8, true), sz))
    end
    local t
    if op == '<<' or op == '>>' then
        t = promote(a.t)
        b = self:conv(b, t)
    else
        t = common(a.t, b.t)
        b = self:conv(b, t)
    end
    a = self:conv(a, t)
    if a.const and b.const and t.k == 'int' and type(a.const) == 'number' and type(b.const) == 'number' then
        -- keep constants known (array sizes, case labels); gcc folds the rest
    end
    return val(t, J.gcc_jit_context_new_binary_op(self.c, nil, J[BINOPS[op]], self:jt(t), self:rv(a), self:rv(b)))
end

function Ctx:cmp(op, a, b)
    if a.t.k == 'array' and a.lv then a = self:conv(a, C.ptr(a.t.of)) end
    if b.t.k == 'array' and b.lv then b = self:conv(b, C.ptr(b.t.of)) end
    if a.t.k == 'ptr' or b.t.k == 'ptr' then
        if a.t.k ~= 'ptr' then a = self:conv(a, b.t)
        elseif b.t.k ~= 'ptr' then b = self:conv(b, a.t)
        elseif a.t ~= b.t then b = self:conv(b, a.t) end
    else
        local t = common(a.t, b.t)
        a, b = self:conv(a, t), self:conv(b, t)
    end
    return val(C.BOOL, J.gcc_jit_context_new_comparison(self.c, nil, J[CMPS[op]], self:rv(a), self:rv(b)))
end

function Ctx:logic(op, a, b)
    local o = op == '&&' and J.GCC_JIT_BINARY_OP_LOGICAL_AND or J.GCC_JIT_BINARY_OP_LOGICAL_OR
    return val(C.BOOL, J.gcc_jit_context_new_binary_op(self.c, nil, o, self:jt(C.BOOL),
        self:rv(self:truth(a)), self:rv(self:truth(b))))
end

function Ctx:unop(op, a)
    if op == '!' then
        return val(C.BOOL, J.gcc_jit_context_new_unary_op(self.c, nil, J.GCC_JIT_UNARY_OP_LOGICAL_NEGATE,
            self:jt(C.BOOL), self:rv(self:truth(a))))
    end
    if op == '+' then return self:conv(a, promote(a.t)) end
    local t = promote(a.t)
    a = self:conv(a, t)
    if op == '-' and a.const and type(a.const) == 'number' then
        return self:int_const(t, -a.const)
    end
    local o = op == '-' and J.GCC_JIT_UNARY_OP_MINUS or J.GCC_JIT_UNARY_OP_BITWISE_NEGATE
    return val(t, J.gcc_jit_context_new_unary_op(self.c, nil, o, self:jt(t), self:rv(a)))
end

function Ctx:member(v, name)
    local t = v.t
    if t.k ~= 'struct' and t.k ~= 'union' then fail(('.%s of a %s'):format(name, C.show(t))) end
    local i = t.byname and t.byname[name]
    if not i then fail(('%s has no member %s'):format(t.name, name)) end
    self:jt(t)
    local f = self:field(t, i)
    local ft = t.fields[i][2]
    if v.lv then return lval(ft, J.gcc_jit_lvalue_access_field(v.lv, nil, f)) end
    return val(ft, J.gcc_jit_rvalue_access_field(self:rv(v), nil, f))
end

function Ctx:deref(p)
    if p.t.k ~= 'ptr' then fail('dereferencing a ' .. C.show(p.t)) end
    return lval(p.t.to, J.gcc_jit_rvalue_dereference(self:rv(p), nil))
end

function Ctx:arrow(p, name)
    if p.t.k ~= 'ptr' then fail(('->%s of a %s'):format(name, C.show(p.t))) end
    local t = p.t.to
    local i = t.byname and t.byname[name]
    if not i then fail(('%s has no member %s'):format(C.show(t), name)) end
    self:jt(t)
    return lval(t.fields[i][2], J.gcc_jit_rvalue_dereference_field(self:rv(p), nil, self:field(t, i)))
end

function Ctx:index(a, i)
    local et
    if a.t.k == 'array' then et = a.t.of
    elseif a.t.k == 'ptr' then et = a.t.to
    else fail('indexing a ' .. C.show(a.t)) end
    if i.t.k ~= 'int' then i = self:conv(i, C.INT) end
    return lval(et, J.gcc_jit_context_new_array_access(self.c, nil, self:rv(a), self:rv(i)))
end

function Ctx:addr(v)
    if v.fn then return val(C.ptr(v.fn.t), J.gcc_jit_function_get_address(self:fn_of(v.fn), nil)) end
    if not v.lv then fail('taking the address of a value') end
    return val(C.ptr(v.t), J.gcc_jit_lvalue_get_address(v.lv, nil))
end

-- functions and globals --------------------------------------------------------------------------
-- A function descriptor: { name, t = fntype, kind = 'exported'|'internal'|'imported'|'inline',
-- pnames = {...}, body = builder (or reader AST, made on first use) }

function C.fn(name, t, kind, pnames)
    return { name = name, t = t, kind = kind, pnames = pnames or {} }
end

local KINDS = { exported = 'GCC_JIT_FUNCTION_EXPORTED', internal = 'GCC_JIT_FUNCTION_INTERNAL',
                imported = 'GCC_JIT_FUNCTION_IMPORTED', inline = 'GCC_JIT_FUNCTION_ALWAYS_INLINE' }

function Ctx:fn_of(d)
    local f = self.fns[d]
    if f then return f end
    local t = d.t
    local ps = ffi.new('gcc_jit_param*[?]', math.max(#t.params, 1))
    local params = {}
    for i, pt in ipairs(t.params) do
        local p = J.gcc_jit_context_new_param(self.c, nil, self:jt(pt), d.pnames[i] or ('p' .. i))
        ps[i - 1] = p
        params[i] = p
    end
    f = J.gcc_jit_context_new_function(self.c, nil, J[KINDS[d.kind]], self:jt(t.ret), d.name, #t.params, ps,
        t.variadic and 1 or 0)
    if f == nil then self:check() end
    self.fns[d] = f
    self.keep[#self.keep + 1] = ps
    d.jparams = d.jparams or {}
    self.params = self.params or {}
    self.params[d] = params
    if d.define then d.define(self, d) end
    return f
end

function Ctx:param(d, i)
    self:fn_of(d)
    return lval(d.t.params[i], J.gcc_jit_param_as_lvalue(self.params[d][i]))
end

-- a call: arguments converted to the parameters; variadic extras promoted
function Ctx:call(target, args)
    local ft, f, through
    if target.fn then
        ft, f = target.fn.t, self:fn_of(target.fn)
    elseif target.t.k == 'ptr' and target.t.to.k == 'fn' then
        ft, through = target.t.to, self:rv(target)
    else
        fail('calling a ' .. C.show(target.t))
    end
    local n = #args
    if n ~= #ft.params and not (ft.variadic and n >= #ft.params) then
        fail(('%s takes %d arguments, got %d'):format(target.fn and target.fn.name or 'a function', #ft.params, n))
    end
    local a = ffi.new('gcc_jit_rvalue*[?]', math.max(n, 1))
    for i = 1, n do
        local v = args[i]
        local pt = ft.params[i]
        if pt then v = self:conv(v, pt)
        elseif v.t.k == 'float' then v = self:conv(v, C.float(8))
        elseif arith(v.t) then v = self:conv(v, promote(v.t))
        elseif v.t.k == 'array' then v = self:conv(v, C.ptr(v.t.of)) end
        a[i - 1] = self:rv(v)
    end
    local r
    if f then r = J.gcc_jit_context_new_call(self.c, nil, f, n, a)
    else r = J.gcc_jit_context_new_call_through_ptr(self.c, nil, through, n, a) end
    if r == nil then self:check() end
    return val(ft.ret, r, { call = true, noreturn = target.fn and target.fn.noreturn })
end

function Ctx:builtin(name)
    local f = J.gcc_jit_context_get_builtin_function(self.c, name)
    if f == nil then self:check(); fail('no builtin ' .. name) end
    return f
end

-- a gcc builtin: arguments cast to its own parameter types, its result to ret
function Ctx:call_builtin(name, ret, args)
    local f = self:builtin(name)
    local a = ffi.new('gcc_jit_rvalue*[?]', math.max(#args, 1))
    for i, v in ipairs(args) do
        local p = J.gcc_jit_function_get_param(f, i - 1)
        local pt = J.gcc_jit_rvalue_get_type(J.gcc_jit_param_as_rvalue(p))
        a[i - 1] = J.gcc_jit_context_new_cast(self.c, nil, self:rv(v), pt)
    end
    local r = J.gcc_jit_context_new_call(self.c, nil, f, #args, a)
    if r == nil then self:check() end
    if ret.k ~= 'void' then r = J.gcc_jit_context_new_cast(self.c, nil, r, self:jt(ret)) end
    return val(ret, r, { call = true })
end

-- a global: { name, t, kind = 'imported'|'exported'|'internal', tls = bool }
function Ctx:global(d)
    local g = self.globals[d]
    if g then return lval(d.t, g) end
    local kinds = { imported = J.GCC_JIT_GLOBAL_IMPORTED, exported = J.GCC_JIT_GLOBAL_EXPORTED,
                    internal = J.GCC_JIT_GLOBAL_INTERNAL }
    g = J.gcc_jit_context_new_global(self.c, nil, kinds[d.kind or 'imported'], self:jt(d.t), d.name)
    if d.tls then J.gcc_jit_lvalue_set_tls_model(g, J.GCC_JIT_TLS_MODEL_GLOBAL_DYNAMIC) end
    if d.init ~= nil then
        J.gcc_jit_global_set_initializer_rvalue(g, self:rv(self:int_const(d.t, d.init)))
    end
    self.globals[d] = g
    return lval(d.t, g)
end

-- function bodies --------------------------------------------------------------------------------
-- Statements go into Lua-side blocks; finish() gives gccjit the reachable ones.

local F = {}
F.__index = F

function Ctx:body(d)
    local f = self:fn_of(d)
    local b = setmetatable({ ctx = self, d = d, f = f, blocks = {}, nlocals = 0 }, F)
    b.entry = b:block('entry')
    b.cur = b.entry
    return b
end

function F:block(name)
    local blk = { name = name, ops = {}, term = nil, id = #self.blocks + 1 }
    self.blocks[#self.blocks + 1] = blk
    return blk
end

function F:at(blk) self.cur = blk end

-- the block to add to: after a terminator, statements are unreachable
function F:here()
    if self.cur.term then self.cur = self:block('dead') end
    return self.cur
end

function F:var(t, name)
    self.nlocals = self.nlocals + 1
    local l = J.gcc_jit_function_new_local(self.f, nil, self.ctx:jt(t), (name or 't') .. '_' .. self.nlocals)
    return lval(t, l)
end

function F:assign(lv, v)
    if not lv.lv then fail('assigning to a value') end
    local ctx = self.ctx
    local rv = ctx:rv(ctx:conv(v, lv.t))
    local l = lv.lv
    local blk = self:here()
    blk.ops[#blk.ops + 1] = function(gb) J.gcc_jit_block_add_assignment(gb, nil, l, rv) end
end

function F:eval(v)
    local rv = self.ctx:rv(v)
    local blk = self:here()
    blk.ops[#blk.ops + 1] = function(gb) J.gcc_jit_block_add_eval(gb, nil, rv) end
    if v.noreturn then self:unreachable() end
end

function F:unreachable()
    local u = self.ctx:builtin('__builtin_unreachable')
    local call = J.gcc_jit_context_new_call(self.ctx.c, nil, u, 0, nil)
    local blk = self:here()
    blk.ops[#blk.ops + 1] = function(gb) J.gcc_jit_block_add_eval(gb, nil, call) end
    blk.term = { 'unreachable' }
end

-- a value fixed now: later statements cannot change what it denotes
function F:temp(v, name)
    if v.const or v.null then return v end
    local t = self:var(v.t, name)
    self:assign(t, v)
    return t
end

function F:ret(v)
    local blk = self:here()
    if v then
        local rv = self.ctx:rv(self.ctx:conv(v, self.d.t.ret))
        blk.term = { 'ret', rv }
    else
        blk.term = { 'ret' }
    end
end

function F:jump(to)
    local blk = self:here()
    blk.term = { 'jump', to }
end

function F:branch(cond, yes, no)
    local rv = self.ctx:rv(self.ctx:truth(cond))
    local blk = self:here()
    blk.term = { 'branch', rv, yes, no }
end

-- cases: { {value, block}, ... }
function F:switch(v, default, cases)
    local blk = self:here()
    blk.term = { 'switch', self.ctx:rv(v), v.t, default, cases }
end

function F:finish()
    local ctx = self.ctx
    -- reachability
    local seen, order = {}, {}
    local function visit(b)
        if seen[b] then return end
        seen[b] = true
        order[#order + 1] = b
        local t = b.term
        if not t then return end
        if t[1] == 'jump' then visit(t[2])
        elseif t[1] == 'branch' then visit(t[3]); visit(t[4])
        elseif t[1] == 'switch' then
            visit(t[4])
            for _, cs in ipairs(t[5]) do visit(cs[2]) end
        end
    end
    visit(self.entry)
    local gb = {}
    for i, b in ipairs(order) do gb[b] = J.gcc_jit_function_new_block(self.f, b.name .. i) end
    local ret_t = self.d.t.ret
    for _, b in ipairs(order) do
        local g = gb[b]
        for _, op in ipairs(b.ops) do op(g) end
        local t = b.term
        if not t or t[1] == 'unreachable' then
            if ret_t.k == 'void' then J.gcc_jit_block_end_with_void_return(g, nil)
            else J.gcc_jit_block_end_with_return(g, nil, ctx:rv(ctx:zero(ret_t))) end
        elseif t[1] == 'ret' then
            if t[2] then J.gcc_jit_block_end_with_return(g, nil, t[2])
            else J.gcc_jit_block_end_with_void_return(g, nil) end
        elseif t[1] == 'jump' then
            J.gcc_jit_block_end_with_jump(g, nil, gb[t[2]])
        elseif t[1] == 'branch' then
            J.gcc_jit_block_end_with_conditional(g, nil, t[2], gb[t[3]], gb[t[4]])
        elseif t[1] == 'switch' then
            local cases = t[5]
            local cs = ffi.new('gcc_jit_case*[?]', math.max(#cases, 1))
            for i, c in ipairs(cases) do
                local k = ctx:rv(ctx:int_const(t[3], c[1]))
                cs[i - 1] = J.gcc_jit_context_new_case(ctx.c, k, k, gb[c[2]])
            end
            J.gcc_jit_block_end_with_switch(g, nil, t[2], gb[t[4]], #cases, cs)
        end
    end
    ctx:check()
end

-- results ------------------------------------------------------------------------------------------

-- libgccjit's driver sets GCC_EXEC_PREFIX in the process environment; give
-- the process its own environment back, or a C compiler started later finds
-- the wrong passes
local env_cdef = false
local function keep_env(f)
    if not env_cdef then
        ffi.cdef [[ int setenv(const char *, const char *, int); int unsetenv(const char *); ]]
        env_cdef = true
    end
    local before = os.getenv('GCC_EXEC_PREFIX')
    local ok, r = pcall(f)
    if os.getenv('GCC_EXEC_PREFIX') ~= before then
        if before then ffi.C.setenv('GCC_EXEC_PREFIX', before, 1) else ffi.C.unsetenv('GCC_EXEC_PREFIX') end
    end
    if not ok then error(r, 0) end
    return r
end

function Ctx:compile()
    return keep_env(function()
        local r = J.gcc_jit_context_compile(self.c)
        if r == nil then self:check(); fail('compilation failed') end
        return r
    end)
end

function Ctx:compile_to_file(kind, path)
    local kinds = { object = J.GCC_JIT_OUTPUT_KIND_OBJECT_FILE, shared = J.GCC_JIT_OUTPUT_KIND_DYNAMIC_LIBRARY,
                    assembler = J.GCC_JIT_OUTPUT_KIND_ASSEMBLER }
    keep_env(function()
        J.gcc_jit_context_compile_to_file(self.c, kinds[kind], path)
        self:check()
    end)
end

function C.code(result, name)
    local p = J.gcc_jit_result_get_code(result, name)
    if p == nil then fail('no function ' .. name .. ' in the result') end
    return p
end

function C.release_result(r) J.gcc_jit_result_release(r) end

-- the C reader ----------------------------------------------------------------------------------------
-- The C subset the compiler contains: declarations, typedefs, structs and
-- unions, prototypes, globals, static inline functions, object-like and
-- function-like macros. The prepared IR carries no C text, so there is no
-- template mode and no holes.

local KEYWORDS = {}
for w in ([[typedef extern static inline const volatile struct union enum void char short int long signed
    unsigned float double _Bool bool if else return do while for break continue sizeof __thread
    goto switch case default]]):gmatch('%S+') do KEYWORDS[w] = true end

local PUNCT = { '<<=', '>>=', '...', '->', '++', '--', '<<', '>>', '<=', '>=', '==', '!=', '&&', '||', '+=', '-=',
                '*=', '/=', '%=', '&=', '|=', '^=' }

local function lex(src, where)
    local toks, i, n = {}, 1, #src
    while i <= n do
        local c = src:sub(i, i)
        if c:match('%s') then
            i = i + 1
        elseif src:sub(i, i + 1) == '/*' then
            local e = src:find('*/', i + 2, true)
            if not e then fail(where .. ': unterminated comment') end
            i = e + 2
        elseif src:sub(i, i + 1) == '//' then
            local e = src:find('\n', i, true) or n
            i = e + 1
        elseif c:match('[%a_]') then
            local s, e = src:find('^[%w_]+', i)
            toks[#toks + 1] = { k = 'id', v = src:sub(s, e) }
            i = e + 1
        elseif c:match('%d') or (c == '.' and src:sub(i + 1, i + 1):match('%d')) then
            local s, e = src:find('^0[xX]%x+[uUlL]*', i)
            if not s then s, e = src:find('^[%d%.]+[eE][%+%-]?%d+[fFlL]?', i) end
            if not s then s, e = src:find('^[%d%.]+[uUlLfF]*', i) end
            toks[#toks + 1] = { k = 'num', v = src:sub(s, e) }
            i = e + 1
        elseif c == '"' then
            local buf, j = {}, i + 1
            while true do
                local ch = src:sub(j, j)
                if ch == '' then fail(where .. ': unterminated string') end
                if ch == '"' then break end
                if ch == '\\' then
                    local nx = src:sub(j + 1, j + 1)
                    local map = { n = '\n', t = '\t', r = '\r', ['0'] = '\0', ['\\'] = '\\', ['"'] = '"', ["'"] = "'" }
                    if nx == 'x' then
                        local hx = src:match('^%x+', j + 2)
                        buf[#buf + 1] = string.char(tonumber(hx, 16) % 256)
                        j = j + 2 + #hx
                    elseif nx:match('[0-7]') then
                        local oc = src:match('^[0-7][0-7]?[0-7]?', j + 1)
                        buf[#buf + 1] = string.char(tonumber(oc, 8) % 256)
                        j = j + 1 + #oc
                    else
                        buf[#buf + 1] = map[nx] or nx
                        j = j + 2
                    end
                else
                    buf[#buf + 1] = ch
                    j = j + 1
                end
            end
            local s = table.concat(buf)
            -- adjacent string literals concatenate
            local last = toks[#toks]
            if last and last.k == 'str' then last.v = last.v .. s else toks[#toks + 1] = { k = 'str', v = s } end
            i = j + 1
        elseif c == "'" then
            local ch = src:sub(i + 1, i + 1)
            local len = 3
            if ch == '\\' then
                local map = { n = 10, t = 9, r = 13, ['0'] = 0, ['\\'] = 92, ["'"] = 39 }
                toks[#toks + 1] = { k = 'num', v = tostring(map[src:sub(i + 2, i + 2)] or src:byte(i + 2)) }
                len = 4
            else
                toks[#toks + 1] = { k = 'num', v = tostring(src:byte(i + 1)) }
            end
            i = i + len
        else
            local p
            for _, q in ipairs(PUNCT) do
                if src:sub(i, i + #q - 1) == q then p = q break end
            end
            p = p or c
            toks[#toks + 1] = { k = 'p', v = p }
            i = i + #p
        end
    end
    return toks
end

-- scopes: typedefs, tags, macros, functions, globals and constants, with a parent
local Scope = {}
Scope.__index = Scope
function C.scope(parent)
    return setmetatable({ types = {}, tags = {}, macros = {}, names = {}, parent = parent }, Scope)
end
function Scope:find(kind, name)
    local s = self
    while s do
        local v = s[kind][name]
        if v ~= nil then return v end
        s = s.parent
    end
end

-- macro expansion over a token list
local function expand(toks, scope, hide)
    hide = hide or {}
    local out, i = {}, 1
    while i <= #toks do
        local t = toks[i]
        local m = t.k == 'id' and not hide[t.v] and not t.noexpand and scope:find('macros', t.v)
        if m and m.params then
            -- function-like: only when followed by (
            if toks[i + 1] and toks[i + 1].v == '(' and toks[i + 1].k == 'p' then
                local args, cur, depth, j = {}, {}, 0, i + 2
                while true do
                    local a = toks[j]
                    if not a then fail('macro ' .. t.v .. ': unterminated arguments') end
                    if a.k == 'p' and (a.v == '(' or a.v == '[' or a.v == '{') then depth = depth + 1 end
                    if a.k == 'p' and (a.v == ')' or a.v == ']' or a.v == '}') then
                        if depth == 0 and a.v == ')' then break end
                        depth = depth - 1
                    end
                    if a.k == 'p' and a.v == ',' and depth == 0 then
                        args[#args + 1] = cur; cur = {}
                    else
                        cur[#cur + 1] = a
                    end
                    j = j + 1
                end
                if #cur > 0 or #args > 0 then args[#args + 1] = cur end
                local h2 = setmetatable({ [t.v] = true }, { __index = hide })
                local body = {}
                for _, b in ipairs(m.body) do
                    local pi = b.k == 'id' and m.pindex[b.v]
                    if pi then
                        for _, a in ipairs(expand(args[pi] or {}, scope, hide)) do body[#body + 1] = a end
                    else
                        body[#body + 1] = b
                    end
                end
                for _, x in ipairs(expand(body, scope, h2)) do out[#out + 1] = x end
                i = j + 1
            else
                out[#out + 1] = t
                i = i + 1
            end
        elseif m then
            local h2 = setmetatable({ [t.v] = true }, { __index = hide })
            for _, x in ipairs(expand(m.body, scope, h2)) do out[#out + 1] = x end
            i = i + 1
        else
            out[#out + 1] = t
            i = i + 1
        end
    end
    return out
end

-- preprocessing: directives line by line, then lexing and expansion
local function preprocess(src, scope, where)
    local lines = {}
    src = src:gsub('\\\n', ' ')
    local stack = { true }
    local function active() for _, x in ipairs(stack) do if not x then return false end end return true end
    -- remove block comments first so directives inside them do not count
    src = src:gsub('/%*.-%*/', function(c) return (c:gsub('[^\n]', ' ')) end)
    for line in (src .. '\n'):gmatch('(.-)\n') do
        local d, rest = line:match('^%s*#%s*(%a+)(.*)$')
        if d then
            if d == 'if' then
                -- defined(X) || defined(Y): compiler-identity tests; this is gcc
                local v = rest:find('__GNUC__') or rest:find('__clang__') or rest:match('^%s*1')
                stack[#stack + 1] = v and true or false
            elseif d == 'ifdef' then
                local name = rest:match('[%w_]+')
                stack[#stack + 1] = scope:find('macros', name) ~= nil or name == '__GNUC__'
            elseif d == 'ifndef' then
                local name = rest:match('[%w_]+')
                stack[#stack + 1] = scope:find('macros', name) == nil and name ~= '__GNUC__'
            elseif d == 'else' then
                stack[#stack] = not stack[#stack]
            elseif d == 'endif' then
                stack[#stack] = nil
            elseif d == 'define' and active() then
                local name, params, body = rest:match('^%s*([%w_]+)%(([^)]*)%)(.*)$')
                if name then
                    local pl, pindex = {}, {}
                    for p in params:gmatch('[%w_]+') do pl[#pl + 1] = p; pindex[p] = #pl end
                    scope.macros[name] = { params = pl, pindex = pindex, body = lex(body, where) }
                else
                    name, body = rest:match('^%s*([%w_]+)(.*)$')
                    scope.macros[name] = { body = lex(body, where) }
                end
            end
            lines[#lines + 1] = ''
        elseif active() then
            lines[#lines + 1] = line
        else
            lines[#lines + 1] = ''
        end
    end
    return expand(lex(table.concat(lines, '\n'), where), scope)
end
C.preprocess = preprocess

-- the parser
local P = {}
P.__index = P

local function parser(toks, scope, where)
    return setmetatable({ toks = toks, i = 1, scope = scope, where = where or 'C' }, P)
end

function P:peek(o) return self.toks[self.i + (o or 0)] end
function P:is(v, o) local t = self:peek(o); return t and (t.k == 'p' or t.k == 'id') and t.v == v end
function P:next() local t = self.toks[self.i]; self.i = self.i + 1; return t end
function P:err(msg)
    local ctx = {}
    for k = math.max(1, self.i - 6), math.min(#self.toks, self.i + 6) do ctx[#ctx + 1] = self.toks[k].v end
    fail(('%s: %s near: %s'):format(self.where, msg, table.concat(ctx, ' ')))
end
function P:expect(v)
    local t = self:next()
    if not t or t.v ~= v then self.i = self.i - 1; self:err("expected '" .. v .. "'") end
    return t
end
function P:accept(v) if self:is(v) then self.i = self.i + 1 return true end return false end

-- __attribute__((...)): read past, noting noreturn
function P:attributes(info)
    while self:is('__attribute__') do
        self:next()
        self:expect('(')
        local depth = 1
        while depth > 0 do
            local t = self:next()
            if not t then self:err('unterminated attribute') end
            if t.v == '(' then depth = depth + 1 elseif t.v == ')' then depth = depth - 1 end
            if info and t.v == 'noreturn' then info.noreturn = true end
        end
    end
end

local BUILTIN_TYPEDEFS = {
    uint8_t = C.int(1, false), uint16_t = C.int(2, false), uint32_t = C.int(4, false), uint64_t = C.int(8, false),
    int8_t = C.int(1, true), int16_t = C.int(2, true), int32_t = C.int(4, true), int64_t = C.int(8, true),
    size_t = C.SIZE, ssize_t = C.int(8, true), uintptr_t = C.SIZE, intptr_t = C.int(8, true),
    ptrdiff_t = C.int(8, true),
}

function P:is_type_start()
    local t = self:peek()
    if not t or t.k ~= 'id' then return false end
    local v = t.v
    if v == 'const' or v == 'volatile' or v == 'struct' or v == 'union' or v == 'enum' or v == 'void' or v == 'char'
        or v == 'short' or v == 'int' or v == 'long' or v == 'signed' or v == 'unsigned' or v == 'float'
        or v == 'double' or v == '_Bool' or v == 'bool' then return true end
    return BUILTIN_TYPEDEFS[v] ~= nil or self.scope:find('types', v) ~= nil
end


-- declaration specifiers: storage and a base type
function P:specifiers()
    local info = { }
    local signed, unsigned, short, long, base = false, false, false, 0, nil
    local seen_any = false
    while true do
        self:attributes(info)
        local t = self:peek()
        if not t or t.k ~= 'id' then break end
        local v = t.v
        if v == 'typedef' or v == 'extern' or v == 'static' or v == 'inline' or v == '__thread' then
            info[v] = true; self:next()
        elseif v == 'const' or v == 'volatile' or v == '__restrict' or v == 'restrict' then
            self:next()
        elseif v == 'signed' then signed = true; self:next(); seen_any = true
        elseif v == 'unsigned' then unsigned = true; self:next(); seen_any = true
        elseif v == 'short' then short = true; self:next(); seen_any = true
        elseif v == 'long' then long = long + 1; self:next(); seen_any = true
        elseif v == 'int' then self:next(); seen_any = true; base = base or 'int'
        elseif v == 'char' then self:next(); seen_any = true; base = 'char'
        elseif v == 'void' then self:next(); base = C.VOID
        elseif v == 'float' then self:next(); base = C.float(4)
        elseif v == 'double' then self:next(); base = C.float(8)
        elseif v == '_Bool' or v == 'bool' then self:next(); base = C.BOOL
        elseif v == 'struct' or v == 'union' then
            self:next()
            base = self:record(v)
        elseif v == 'enum' then
            self:next()
            base = self:enum()
        elseif not base and not seen_any and (BUILTIN_TYPEDEFS[v] or self.scope:find('types', v)) then
            self:next()
            base = BUILTIN_TYPEDEFS[v] or self.scope:find('types', v)
        else
            break
        end
    end
    if type(base) ~= 'table' then
        if base == 'char' then base = unsigned and C.int(1, false) or C.int(1, true)
        elseif short then base = C.int(2, not unsigned)
        elseif long > 0 then base = C.int(8, not unsigned)
        elseif seen_any or base == 'int' then base = C.int(4, not unsigned)
        else return nil, info end
    end
    return base, info
end

function P:record(kind)
    self:attributes()
    local tag
    if self:peek().k == 'id' and not self:is('{') then tag = self:next().v end
    local t
    if tag then
        t = self.scope:find('tags', kind .. ' ' .. tag)
        if not t then
            t = C.record(kind, tag)
            self.scope.tags[kind .. ' ' .. tag] = t
        end
    end
    if self:accept('{') then
        t = t or C.record(kind, nil)
        local fields = {}
        while not self:accept('}') do
            local base = self:specifiers()
            if not base then self:err('expected a member type') end
            repeat
                local name, ft = self:declarator(base)
                fields[#fields + 1] = { name, ft }
            until not self:accept(',')
            self:expect(';')
        end
        t:set_fields(fields)
    end
    if not t then self:err('expected a struct') end
    return t
end

function P:enum()
    if self:peek().k == 'id' and not self:is('{') then self:next() end
    if self:accept('{') then
        local n = 0
        while not self:accept('}') do
            local name = self:next().v
            if self:accept('=') then n = self:const_int(self:assignment()) end
            self.scope.names[name] = { const = n, t = C.INT }
            n = n + 1
            self:accept(',')
        end
    end
    return C.INT
end

-- a declarator: pointers, a name (or (*name)(params)), arrays, a parameter list
function P:declarator(base, abstract)
    local t = base
    while self:accept('*') do
        while self:accept('const') or self:accept('volatile') or self:accept('restrict') or self:accept('__restrict') do end
        t = C.ptr(t)
    end
    self:attributes()
    local name, inner
    if self:is('(') and self:is('*', 1) then
        -- (*name)(params): a pointer to a function
        self:next(); self:next()
        if self:peek().k == 'id' then name = self:next().v end
        self:expect(')')
        inner = true
    elseif self:peek() and self:peek().k == 'id' and not KEYWORDS[self:peek().v] then
        name = self:next().v
    end
    local pnames
    if self:accept('(') then
        local params, variadic = {}, false
        pnames = {}
        if self:is('void') and self:is(')', 1) then self:next() end
        while not self:accept(')') do
            if self:accept('...') then variadic = true
            else
                local pb = self:specifiers()
                if not pb then self:err('expected a parameter type') end
                local pn, pt = self:declarator(pb, true)
                if pt.k == 'array' then pt = C.ptr(pt.of) end
                params[#params + 1] = pt
                pnames[#pnames + 1] = pn
            end
            self:accept(',')
        end
        t = C.fntype(t, params, variadic)
        if inner then t = C.ptr(t) end
    end
    while self:accept('[') do
        if self:accept(']') then
            -- [] : its length comes from the initializer
            t = setmetatable({ k = 'array', of = t, n = nil, open = true }, Ty)
        else
            local n = self:const_int(self:conditional())
            self:expect(']')
            t = C.array(t, n)
        end
    end
    self:attributes()
    return name, t, pnames
end

function P:typename()
    local base = self:specifiers()
    if not base then self:err('expected a type') end
    local _, t = self:declarator(base, true)
    return t
end

-- constant integer expressions (array sizes, enum values)
function P:const_int(e)
    local function ev(x)
        if x.k == 'num' then return x.v end
        if x.k == 'bin' then
            local a, b = ev(x.a), ev(x.b)
            if x.op == '+' then return a + b elseif x.op == '-' then return a - b
            elseif x.op == '*' then return a * b elseif x.op == '/' then return math.floor(a / b) end
        end
        if x.k == 'unop' and x.op == '-' then return -ev(x.e) end
        if x.k == 'id' then
            local n = self.scope:find('names', x.name)
            if n and n.const then return n.const end
        end
        if x.k == 'cast' then return ev(x.e) end
        if x.k == 'sizeof_t' then return C.sizeof(x.t) end
        self:err('not a constant')
    end
    return ev(e)
end

-- expressions
local PRECS = {
    ['||'] = 1, ['&&'] = 2, ['|'] = 3, ['^'] = 4, ['&'] = 5, ['=='] = 6, ['!='] = 6,
    ['<'] = 7, ['>'] = 7, ['<='] = 7, ['>='] = 7, ['<<'] = 8, ['>>'] = 8, ['+'] = 9, ['-'] = 9,
    ['*'] = 10, ['/'] = 10, ['%'] = 10,
}
local ASSIGN = { ['='] = true, ['+='] = '+', ['-='] = '-', ['*='] = '*', ['/='] = '/', ['%='] = '%',
                 ['&='] = '&', ['|='] = '|', ['^='] = '^', ['<<='] = '<<', ['>>='] = '>>' }

function P:expression()
    local e = self:assignment()
    while self:is(',') and self:peek().k == 'p' do
        self:next()
        e = { k = 'comma', a = e, b = self:assignment() }
    end
    return e
end

function P:assignment()
    local e = self:conditional()
    local t = self:peek()
    if t and t.k == 'p' and ASSIGN[t.v] then
        self:next()
        return { k = 'assign', op = t.v, a = e, b = self:assignment() }
    end
    return e
end

function P:conditional()
    local c = self:binary(1)
    if self:accept('?') then
        local a = self:expression()
        self:expect(':')
        local b = self:conditional()
        return { k = 'cond', c = c, a = a, b = b }
    end
    return c
end

function P:binary(min)
    local a = self:unary()
    while true do
        local t = self:peek()
        local p = t and t.k == 'p' and PRECS[t.v]
        if not p or p < min then break end
        self:next()
        local b = self:binary(p + 1)
        a = { k = 'bin', op = t.v, a = a, b = b }
    end
    return a
end

function P:unary()
    local t = self:peek()
    if t.k == 'p' then
        if t.v == '++' or t.v == '--' then
            self:next()
            return { k = 'preinc', op = t.v:sub(1, 1), e = self:unary() }
        end
        if t.v == '&' or t.v == '*' or t.v == '-' or t.v == '+' or t.v == '!' or t.v == '~' then
            self:next()
            return { k = 'unop', op = t.v, e = self:cast() }
        end
        if t.v == '(' then return self:cast() end
    end
    if t.k == 'id' and t.v == 'sizeof' then
        self:next()
        if self:is('(') then
            local save = self.i
            self:next()
            if self:is_type_start() then
                local ty_ = self:typename()
                self:expect(')')
                return { k = 'sizeof_t', t = ty_ }
            end
            self.i = save
        end
        return { k = 'sizeof_e', e = self:unary() }
    end
    return self:postfix(self:primary())
end

function P:cast()
    if self:is('(') then
        local save = self.i
        self:next()
        if self:is_type_start() then
            local t = self:typename()
            self:expect(')')
            if self:is('{') then
                return self:postfix({ k = 'complit', t = t, init = self:initializer() })
            end
            return { k = 'cast', t = t, e = self:cast() }
        end
        self.i = save
    end
    return self:unary_nocast()
end

function P:unary_nocast()
    local t = self:peek()
    if t.k == 'p' and t.v == '(' then return self:postfix(self:primary()) end
    return self:unary()
end

function P:primary()
    local t = self:next()
    if not t then self:err('unexpected end') end
    if t.k == 'num' then
        local s = t.v
        local body, suffix = s:match('^(.-)([uUlLfF]*)$')
        if body:find('[%.eE]') and not body:match('^0[xX]') then
            return { k = 'fnum', v = tonumber(body), float = suffix:lower():find('f') ~= nil }
        end
        local v = tonumber(body)
        if #body > 15 and not body:match('^0[xX]') then
            -- past a double's precision: read it as a 64-bit integer
            v = assert(loadstring('return ' .. body .. 'ULL'))()
            if v <= 9223372036854775807ULL then v = tonumber(v) end
        end
        if body:match('^0%d') then v = tonumber(body, 8) end
        if not v and body:match('^0[xX]') then v = tonumber(body:sub(3), 16) end
        return { k = 'num', v = v, u = suffix:lower():find('u') ~= nil, l = suffix:lower():find('l') ~= nil,
                 hex = body:match('^0[xX]') ~= nil }
    end
    if t.k == 'str' then return { k = 'str', v = t.v } end
    if t.k == 'id' then return { k = 'id', name = t.v } end
    if t.v == '(' then
        local e = self:expression()
        self:expect(')')
        return e
    end
    self.i = self.i - 1
    self:err('unexpected token')
end

function P:postfix(e)
    while true do
        if self:accept('(') then
            local args = {}
            while not self:accept(')') do
                args[#args + 1] = self:assignment()
                self:accept(',')
            end
            e = { k = 'call', f = e, args = args }
        elseif self:accept('[') then
            local i = self:expression()
            self:expect(']')
            e = { k = 'index', e = e, i = i }
        elseif self:is('.') or self:is('->') then
            local arrow = self:next().v == '->'
            e = { k = 'member', e = e, name = self:next().v, arrow = arrow }
        elseif self:is('++') or self:is('--') then
            e = { k = 'postinc', op = self:next().v:sub(1, 1), e = e }
        else
            return e
        end
    end
end

-- { a, .f = b, { ... } }
function P:initializer()
    if not self:accept('{') then return self:assignment() end
    local items = {}
    while not self:accept('}') do
        local desig
        if self:is('.') then
            self:next()
            desig = self:next().v
            -- .as.alt = v: a path
            while self:accept('.') do desig = desig .. '.' .. self:next().v end
            self:expect('=')
        elseif self:accept('[') then
            desig = { index = self:const_int(self:conditional()) }
            self:expect(']')
            self:expect('=')
        end
        items[#items + 1] = { desig = desig, v = self:initializer() }
        self:accept(',')
    end
    return { k = 'init', items = items }
end

-- statements
function P:statement()
    local t = self:peek()
    if not t then self:err('unexpected end') end
    if t.v == '{' and t.k == 'p' then
        self:next()
        local items = {}
        while not self:accept('}') do items[#items + 1] = self:block_item() end
        return { k = 'block', items = items }
    end
    if t.k == 'id' then
        if t.v == 'if' then
            self:next(); self:expect('(')
            local c = self:expression()
            self:expect(')')
            local a = self:statement()
            local b
            if self:accept('else') then b = self:statement() end
            return { k = 'if', c = c, a = a, b = b }
        elseif t.v == 'return' then
            self:next()
            local e
            if not self:is(';') then e = self:expression() end
            self:expect(';')
            return { k = 'return', e = e }
        elseif t.v == 'do' then
            self:next()
            local body = self:statement()
            self:expect('while'); self:expect('(')
            local c = self:expression()
            self:expect(')'); self:expect(';')
            return { k = 'do', body = body, c = c }
        elseif t.v == 'while' then
            self:next(); self:expect('(')
            local c = self:expression()
            self:expect(')')
            return { k = 'while', c = c, body = self:statement() }
        elseif t.v == 'for' then
            self:next(); self:expect('(')
            local init, c, step
            if not self:accept(';') then
                if self:is_type_start() then init = self:declaration() else init = { k = 'expr', e = self:expression() }; self:expect(';') end
            end
            if not self:is(';') then c = self:expression() end
            self:expect(';')
            if not self:is(')') then step = self:expression() end
            self:expect(')')
            return { k = 'for', init = init, c = c, step = step, body = self:statement() }
        elseif t.v == 'break' then self:next(); self:expect(';'); return { k = 'break' }
        elseif t.v == 'continue' then self:next(); self:expect(';'); return { k = 'continue' }
        end
    end
    if t.k == 'p' and t.v == ';' then self:next(); return { k = 'empty' } end
    local e = self:expression()
    self:expect(';')
    return { k = 'expr', e = e }
end

function P:declaration()
    local base = self:specifiers()
    local list = {}
    repeat
        local name, t = self:declarator(base)
        local init
        if self:accept('=') then init = self:initializer() end
        list[#list + 1] = { name = name, t = t, init = init }
    until not self:accept(',')
    self:expect(';')
    return { k = 'decl', list = list }
end

function P:block_item()
    if self:is_type_start() then return self:declaration() end
    return self:statement()
end

-- top level: declarations and function definitions into the scope
function P:top()
    while self:peek() do
        if self:accept(';') then goto continue end
        do
            local base, info = self:specifiers()
            if not base then self:err('expected a declaration') end
            if self:accept(';') then goto continue end   -- struct S { ... };
            repeat
                local name, t, pnames = self:declarator(base)
                self:attributes(info)
                if info.typedef then
                    self.scope.types[name] = t
                elseif t.k == 'fn' then
                    local d = self.scope.names[name]
                    if not d or not d.fn then
                        d = { fn = C.fn(name, t, (info.static or info.inline) and 'internal' or 'imported', pnames) }
                        self.scope.names[name] = d
                    end
                    if info.noreturn then d.fn.noreturn = true end
                    if self:is('{') then
                        -- a definition: kept as source, lowered where used
                        d.fn.kind = 'internal'
                        d.fn.pnames = pnames
                        d.fn.ast = self:statement()
                        goto continue
                    end
                else
                    local g = { name = name, t = t, kind = info.extern and 'imported' or 'internal',
                                tls = info.__thread }
                    self.scope.names[name] = { global = g }
                end
            until not self:accept(',')
            self:expect(';')
        end
        ::continue::
    end
end

-- read declarations (a header, helper definitions) into a scope
function C.read(src, scope, where)
    local toks = preprocess(src, scope, where or 'C')
    local p = parser(toks, scope, where)
    p:top()
    return scope
end

-- lowering the reader's AST ------------------------------------------------------------------------
-- env: { scope, names = function(name) -> value | nil }

local L = {}
L.__index = L

function C.lowerer(fb, env)
    return setmetatable({ fb = fb, ctx = fb.ctx, env = env, vars = {}, loops = {} }, L)
end

function L:lookup(name)
    for i = #self.vars, 1, -1 do
        local v = self.vars[i][name]
        if v then return v end
    end
    if self.env.names then
        local v = self.env.names(name)
        if v then return v end
    end
    local d = self.env.scope:find('names', name)
    if d then
        if d.fn then
            if d.fn.ast and not d.fn.define then C.define_from_ast(d.fn, self.env.scope) end
            return { fn = d.fn, t = d.fn.t }
        end
        if d.global then return self.ctx:global(d.global) end
        if d.const then return self.ctx:int_const(d.t or C.INT, d.const) end
        if d.value then return d.value(self.ctx) end
    end
    if self.env.unknown then
        local v = self.env.unknown(name, self.ctx)
        if v then return v end
    end
    fail('unknown name ' .. name)
end

local ATOMIC_OPS = {
    __atomic_load_n = 'load', __atomic_store_n = 'store', __atomic_exchange_n = 'exchange',
    __atomic_fetch_add = 'fetch_add', __atomic_fetch_sub = 'fetch_sub',
    __atomic_compare_exchange_n = 'compare_exchange', __atomic_thread_fence = 'thread_fence',
}
local MEMORY_ORDERS = { __ATOMIC_RELAXED = 0, __ATOMIC_CONSUME = 1, __ATOMIC_ACQUIRE = 2, __ATOMIC_RELEASE = 3,
                        __ATOMIC_ACQ_REL = 4, __ATOMIC_SEQ_CST = 5 }
C.MEMORY_ORDERS = MEMORY_ORDERS

-- the atomic builtins, by size: gcc's __atomic_*_N with void pointers
function Ctx:atomic(op, args)
    local INT = C.INT
    local function order(v) return self:conv(v, INT) end
    if op == 'thread_fence' then
        return self:call_builtin('__atomic_thread_fence', C.VOID, { order(args[1]) })
    end
    local p = args[1]
    local et = p.t.to
    local size = C.sizeof(et)
    local it = C.int(size, false)
    local vp = self:conv(p, C.VOIDP)
    local function as_bits(v)
        v = self:conv(v, et)
        if et.k == 'ptr' then return self:conv(v, it) end
        if et.k == 'bool' then return self:conv(v, it) end
        return self:conv(v, it)
    end
    local function from_bits(v)
        if et.k == 'ptr' then return self:conv(v, et) end
        return self:conv(v, et)
    end
    if op == 'load' then
        return from_bits(self:call_builtin('__atomic_load_' .. size, it, { vp, order(args[2]) }))
    elseif op == 'store' then
        return self:call_builtin('__atomic_store_' .. size, C.VOID, { vp, as_bits(args[2]), order(args[3]) })
    elseif op == 'exchange' then
        return from_bits(self:call_builtin('__atomic_exchange_' .. size, it, { vp, as_bits(args[2]), order(args[3]) }))
    elseif op == 'fetch_add' or op == 'fetch_sub' then
        return from_bits(self:call_builtin('__atomic_' .. op .. '_' .. size, it, { vp, as_bits(args[2]), order(args[3]) }))
    elseif op == 'compare_exchange' then
        local ep = self:conv(args[2], C.VOIDP)
        return self:call_builtin('__atomic_compare_exchange_' .. size, C.BOOL,
            { vp, ep, as_bits(args[3]), self:conv(args[4], C.BOOL), order(args[5]), order(args[6]) })
    end
    fail('unknown atomic operation ' .. op)
end

function L:expr(e)
    local ctx, fb = self.ctx, self.fb
    local k = e.k
    if k == 'num' then
        local v = e.v
        local t
        if e.u then
            t = v > 4294967295 and C.int(8, false) or C.UINT
        elseif e.l then
            t = C.int(8, true)
        elseif v <= 2147483647 then t = C.INT
        elseif e.hex and v <= 4294967295 then t = C.UINT
        elseif v <= 9223372036854775807 then t = C.int(8, true)
        else t = C.int(8, false) end
        return ctx:int_const(t, v)
    elseif k == 'fnum' then
        return ctx:float_const(C.float(e.float and 4 or 8), e.v)
    elseif k == 'str' then
        return ctx:string(e.v)
    elseif k == 'id' then
        if MEMORY_ORDERS[e.name] then return ctx:int_const(C.INT, MEMORY_ORDERS[e.name]) end
        if e.name == 'true' then return ctx:int_const(C.INT, 1) end
        if e.name == 'false' then return ctx:int_const(C.INT, 0) end
        return self:lookup(e.name)
    elseif k == 'call' then
        if e.f.k == 'id' and ATOMIC_OPS[e.f.name] then
            local args = {}
            for i, a in ipairs(e.args) do args[i] = self:expr(a) end
            return ctx:atomic(ATOMIC_OPS[e.f.name], args)
        end
        local f = self:expr(e.f)
        local args = {}
        for i, a in ipairs(e.args) do args[i] = self:expr(a) end
        return ctx:call(f, args)
    elseif k == 'member' then
        local v = self:expr(e.e)
        if e.arrow then return ctx:arrow(v, e.name) end
        return ctx:member(v, e.name)
    elseif k == 'index' then
        return ctx:index(self:expr(e.e), self:expr(e.i))
    elseif k == 'unop' then
        if e.op == '&' then return ctx:addr(self:expr(e.e)) end
        if e.op == '*' then return ctx:deref(self:expr(e.e)) end
        return ctx:unop(e.op, self:expr(e.e))
    elseif k == 'cast' then
        return ctx:conv(self:expr(e.e), e.t)
    elseif k == 'sizeof_t' then
        return ctx:int_const(C.SIZE, C.sizeof(e.t))
    elseif k == 'bin' then
        if e.op == '&&' or e.op == '||' then return ctx:logic(e.op, self:expr(e.a), self:expr(e.b)) end
        if CMPS[e.op] then return ctx:cmp(e.op, self:expr(e.a), self:expr(e.b)) end
        return ctx:binop(e.op, self:expr(e.a), self:expr(e.b))
    elseif k == 'assign' then
        local lv = self:expr(e.a)
        local v
        if e.op == '=' then v = self:expr(e.b)
        else v = ctx:binop(ASSIGN[e.op], lv, self:expr(e.b)) end
        v = fb:temp(ctx:conv(v, lv.t))
        fb:assign(lv, v)
        return v
    elseif k == 'preinc' or k == 'postinc' then
        local lv = self:expr(e.e)
        local old = fb:temp(lval(lv.t, lv.lv), 'old')
        local one = ctx:int_const(C.INT, 1)
        local new = ctx:conv(ctx:binop(e.op, old, one), lv.t)
        fb:assign(lv, new)
        if k == 'postinc' then return old end
        return fb:temp(lval(lv.t, lv.lv))
    elseif k == 'cond' then
        local c = self:expr(e.c)
        local yes, no, done = fb:block('then'), fb:block('else'), fb:block('fi')
        fb:branch(c, yes, no)
        fb:at(yes)
        local a = self:expr(e.a)
        local ya = fb.cur
        fb:at(no)
        local b = self:expr(e.b)
        local nb = fb.cur
        -- the result type: arithmetic in common, else the pointer side
        local t
        if arith(a.t) and arith(b.t) then t = common(a.t, b.t)
        elseif a.t.k == 'ptr' and not (a.null or a.const == 0) then t = a.t
        else t = b.t end
        local r = fb:var(t, 'cond')
        fb:at(ya); fb:assign(r, a); fb:jump(done)
        fb:at(nb); fb:assign(r, b); fb:jump(done)
        fb:at(done)
        return r
    elseif k == 'comma' then
        local a = self:expr(e.a)
        if a.call then fb:eval(a) end
        return self:expr(e.b)
    elseif k == 'complit' then
        local t = e.t
        if t.k == 'array' and t.open then t = C.array(t.of, #e.init.items) end
        local tmp = fb:var(t, 'lit')
        self:init(tmp, e.init, true)
        return tmp
    end
    fail('cannot lower expression ' .. tostring(k))
end

-- initialize lvalue lv from an initializer; zeroed first as C requires
function L:init(lv, init, zero)
    local ctx, fb = self.ctx, self.fb
    local t = lv.t
    if init.k ~= 'init' then
        fb:assign(lv, self:expr(init))
        return
    end
    if zero and not scalar(t) then fb:assign(lv, ctx:zero(t)) end
    if scalar(t) then
        if init.items[1] then self:init(lv, init.items[1].v, false) end
        return
    end
    local pos = 1
    for _, it in ipairs(init.items) do
        local target
        if type(it.desig) == 'string' then
            target = lv
            local first = true
            for part in it.desig:gmatch('[^%.]+') do
                target = ctx:member(target, part)
                if first and t.k == 'struct' then pos = t.byname[part] + 1 end
                first = false
            end
        elseif type(it.desig) == 'table' then
            pos = it.desig.index
            target = ctx:index(lv, ctx:int_const(C.INT, pos))
            pos = pos + 1
        elseif t.k == 'array' then
            target = ctx:index(lv, ctx:int_const(C.INT, pos - 1))
            pos = pos + 1
        else
            local f = t.fields[pos]
            if not f then fail('too many initializers for ' .. C.show(t)) end
            target = ctx:member(lv, f[1])
            pos = pos + 1
        end
        self:init(target, it.v, false)
    end
end

function L:stmt(s)
    local ctx, fb = self.ctx, self.fb
    local k = s.k
    if k == 'block' then
        self.vars[#self.vars + 1] = {}
        for _, x in ipairs(s.items) do self:stmt(x) end
        self.vars[#self.vars] = nil
    elseif k == 'decl' then
        local frame = self.vars[#self.vars]
        for _, d in ipairs(s.list) do
            local v = fb:var(d.t, d.name)
            frame[d.name] = v
            if d.init then self:init(v, d.init, true) end
        end
    elseif k == 'expr' then
        local e = s.e
        if e.k == 'assign' then
            local lv = self:expr(e.a)
            local v
            if e.op == '=' then v = self:expr(e.b) else v = ctx:binop(ASSIGN[e.op], lv, self:expr(e.b)) end
            fb:assign(lv, v)
        elseif e.k == 'postinc' or e.k == 'preinc' then
            local lv = self:expr(e.e)
            fb:assign(lv, ctx:conv(ctx:binop(e.op, lv, ctx:int_const(C.INT, 1)), lv.t))
        else
            local v = self:expr(e)
            if v.call then fb:eval(v) end
        end
    elseif k == 'if' then
        local yes, done = fb:block('then'), fb:block('fi')
        local no = s.b and fb:block('else') or done
        fb:branch(self:expr(s.c), yes, no)
        fb:at(yes); self:stmt(s.a); fb:jump(done)
        if s.b then fb:at(no); self:stmt(s.b); fb:jump(done) end
        fb:at(done)
    elseif k == 'return' then
        if s.e then fb:ret(self:expr(s.e)) else fb:ret() end
    elseif k == 'do' then
        local body, test, done = fb:block('do'), fb:block('while'), fb:block('od')
        fb:jump(body)
        fb:at(body)
        self.loops[#self.loops + 1] = { brk = done, cont = test }
        self:stmt(s.body)
        self.loops[#self.loops] = nil
        fb:jump(test)
        fb:at(test)
        local c = s.c
        if c.k == 'num' and c.v == 0 then fb:jump(done) else fb:branch(self:expr(c), body, done) end
        fb:at(done)
    elseif k == 'while' or k == 'for' then
        self.vars[#self.vars + 1] = {}
        if s.init then self:stmt(s.init) end
        local test, body, step, done = fb:block('test'), fb:block('body'), fb:block('step'), fb:block('done')
        fb:jump(test)
        fb:at(test)
        if s.c then fb:branch(self:expr(s.c), body, done) else fb:jump(body) end
        fb:at(body)
        self.loops[#self.loops + 1] = { brk = done, cont = step }
        self:stmt(s.body)
        self.loops[#self.loops] = nil
        fb:jump(step)
        fb:at(step)
        if s.step then self:stmt({ k = 'expr', e = s.step }) end
        fb:jump(test)
        fb:at(done)
        self.vars[#self.vars] = nil
    elseif k == 'break' then
        fb:jump(self.loops[#self.loops].brk)
    elseif k == 'continue' then
        fb:jump(self.loops[#self.loops].cont)
    elseif k == 'empty' then
        return
    else
        fail('cannot lower statement ' .. tostring(k))
    end
end

-- a function the reader read with a body: defined in a context when first used
function C.define_from_ast(d, scope)
    d.define = function(ctx, d2)
        local fb = ctx:body(d2)
        local frame = {}
        for i, n in ipairs(d2.pnames) do if n then frame[n] = ctx:param(d2, i) end end
        local l = C.lowerer(fb, { scope = scope })
        l.vars[1] = frame
        l:stmt(d2.ast)
        fb:finish()
    end
end

-- the runtime header, read once
local rt_scope
function C.runtime_scope(rt_dir)
    if rt_scope then return rt_scope end
    local s = C.scope(nil)
    local function m(name, text) s.macros[name] = { body = lex(text, 'predefined') } end
    m('UINT32_MAX', '4294967295u'); m('UINT64_MAX', '18446744073709551615ull'); m('INT32_MAX', '2147483647')
    m('SIZE_MAX', '18446744073709551615ull'); m('UINT8_MAX', '255'); m('UINT16_MAX', '65535')
    m('INT64_MAX', '9223372036854775807ll'); m('NULL', '((void *)0)')
    s.macros.__GNUC__ = { body = lex('13', 'predefined') }
    local path = rt_dir .. '/slc_rt.h'
    local f = io.open(path)
    if not f then fail('cannot read ' .. path) end
    local src = f:read '*a'
    f:close()
    C.read(src, s, 'slc_rt.h')
    rt_scope = s
    return s
end

return C
