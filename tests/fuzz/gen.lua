-- The fuzzer's program generator: seeded, deterministic, free of undefined
-- behaviour by construction. Programs are ASTs first (so a failure can be
-- shrunk), printed as slc. Each program defines a word `f` whose result is a
-- U64 checksum of everything it computed.

local Gen = {}

local INTS = {
    U8 = { bits = 8, signed = false }, U16 = { bits = 16, signed = false }, U32 = { bits = 32, signed = false },
    U64 = { bits = 64, signed = false }, I8 = { bits = 8, signed = true }, I16 = { bits = 16, signed = true },
    I32 = { bits = 32, signed = true }, I64 = { bits = 64, signed = true },
}
local UNSIGNED = { 'U8', 'U16', 'U32', 'U64' }
local ALL_INTS = { 'U8', 'U16', 'U32', 'U64', 'I8', 'I16', 'I32', 'I64' }
Gen.INTS = INTS

-- a small deterministic generator (xorshift32), independent of math.random
local R = {}
R.__index = R
function Gen.rng(seed)
    local s = bit.bxor(seed * 2654435761 % 4294967296, 0x9e3779b9)
    if s == 0 then s = 1 end
    return setmetatable({ s = s }, R)
end
function R:next()
    local x = self.s
    x = bit.bxor(x, bit.lshift(x, 13))
    x = bit.bxor(x, bit.rshift(x, 17))
    x = bit.bxor(x, bit.lshift(x, 5))
    self.s = x
    return x % 4294967296
end
function R:int(lo, hi) return lo + self:next() % (hi - lo + 1) end
function R:chance(p) return self:next() % 1000 < p * 1000 end
function R:pick(t) return t[self:int(1, #t)] end

-- a constant of an integer type, kept inside +-2^31 so Lua holds it exactly
function Gen.const_of(r, t)
    local d = INTS[t]
    local lo, hi
    if d.signed then
        local m = d.bits >= 32 and 2147483647 or 2 ^ (d.bits - 1) - 1
        lo, hi = -m - 1, m
    else
        lo, hi = 0, d.bits >= 32 and 2147483647 or 2 ^ d.bits - 1
    end
    -- small values most of the time: loops and indices like them
    local v
    if r:chance(0.6) then v = r:int(0, math.min(hi, 20)) else v = r:int(lo, hi) end
    if d.signed and r:chance(0.3) then v = -v end
    if v < lo then v = lo end
    return v
end

-- printing ------------------------------------------------------------------------------------

local function lit(t, v)
    if t == 'Bool' then return v and 'true' or 'false' end
    if v < 0 then return t .. '(' .. ('%d'):format(v) .. ')' end
    return t .. '(' .. ('%d'):format(v) .. ')'
end
Gen.lit = lit

local P = {}

function P.expr(e)
    local k = e.k
    if k == 'const' then return lit(e.t, e.v)
    elseif k == 'var' then return e.name
    elseif k == 'bin' then return '(' .. P.expr(e.a) .. ' ' .. e.op .. ' ' .. P.expr(e.b) .. ')'
    elseif k == 'divmod' then
        -- a divisor that is never zero (and, signed, never -1 with the minimum: it is odd and positive)
        return '(' .. P.expr(e.a) .. ' ' .. e.op .. ' ' .. P.expr(e.b) .. ')'
    elseif k == 'bw' then return e.fn .. '(' .. P.expr(e.a) .. ', ' .. P.expr(e.b) .. ')'
    elseif k == 'shift' then return e.fn .. '(' .. P.expr(e.a) .. ', ' .. e.n .. ')'
    elseif k == 'conv' then return e.t .. '(' .. P.expr(e.e) .. ')'
    elseif k == 'cmp' then return '(' .. P.expr(e.a) .. ' ' .. e.op .. ' ' .. P.expr(e.b) .. ')'
    elseif k == 'logic' then return '(' .. P.expr(e.a) .. ' ' .. e.op .. ' ' .. P.expr(e.b) .. ')'
    elseif k == 'not' then return '(not ' .. P.expr(e.e) .. ')'
    elseif k == 'field' then return e.base .. '.' .. e.name
    elseif k == 'index' then return e.base .. '[' .. P.expr(e.i) .. ' % ' .. e.n .. ']'
    elseif k == 'call' then
        local a = {}
        for i, x in ipairs(e.args) do a[i] = P.expr(x) end
        return e.fn .. '(' .. table.concat(a, ', ') .. ')'
    elseif k == 'raw' then return e.text
    end
    error('print: ' .. tostring(k))
end

function P.block(b, ind, out)
    for _, s in ipairs(b) do P.stmt(s, ind, out) end
end

function P.stmt(s, ind, out)
    local pad = ('    '):rep(ind)
    local k = s.k
    if k == 'local' then
        out[#out + 1] = pad .. 'local ' .. s.name .. ': ' .. s.t .. ' = ' .. P.expr(s.e)
    elseif k == 'assign' then
        out[#out + 1] = pad .. s.target .. ' = ' .. P.expr(s.e)
    elseif k == 'if' then
        out[#out + 1] = pad .. 'if ' .. P.expr(s.c) .. ' then'
        P.block(s.a, ind + 1, out)
        if s.b and #s.b > 0 then
            out[#out + 1] = pad .. 'else'
            P.block(s.b, ind + 1, out)
        end
        out[#out + 1] = pad .. 'end'
    elseif k == 'while' then
        out[#out + 1] = pad .. 'local ' .. s.counter .. ': U32 = 0'
        out[#out + 1] = pad .. 'while ' .. s.counter .. ' < ' .. s.n .. ' and ' .. P.expr(s.c) .. ' do'
        out[#out + 1] = pad .. '    ' .. s.counter .. ' = ' .. s.counter .. ' + 1'
        P.block(s.body, ind + 1, out)
        out[#out + 1] = pad .. 'end'
    elseif k == 'for' then
        out[#out + 1] = pad .. 'for ' .. s.var .. ': U32 = ' .. P.expr(s.lo) .. ', ' .. P.expr(s.hi) .. ' do'
        P.block(s.body, ind + 1, out)
        out[#out + 1] = pad .. 'end'
    elseif k == 'hostfor' then
        out[#out + 1] = pad .. 'for _ = 1, ' .. s.n .. ' do'
        P.block(s.body, ind + 1, out)
        out[#out + 1] = pad .. 'end'
    elseif k == 'break' then
        out[#out + 1] = pad .. 'break'
    elseif k == 'match' then
        out[#out + 1] = pad .. s.subject .. ' {'
        out[#out + 1] = pad .. '    num = do(x)'
        P.block(s.num, ind + 2, out)
        out[#out + 1] = pad .. '    end,'
        out[#out + 1] = pad .. '    none = do'
        P.block(s.none, ind + 2, out)
        out[#out + 1] = pad .. '    end,'
        out[#out + 1] = pad .. '}'
    elseif k == 'mix' then
        -- fold a value into the checksum
        out[#out + 1] = pad .. 'h = h * 31 + U64(' .. P.expr(s.e) .. ')'
    elseif k == 'raw' then
        out[#out + 1] = pad .. s.text
    else
        error('print stmt: ' .. tostring(k))
    end
end
Gen.print_expr, Gen.print_block = P.expr, P.block

-- generation ------------------------------------------------------------------------------------

local G = {}
G.__index = G

function Gen.new(seed, opts)
    opts = opts or {}
    return setmetatable({ r = Gen.rng(seed), n = 0, depth_max = opts.depth or 3, helpers = {}, seed = seed }, G)
end

function G:fresh(base) self.n = self.n + 1; return base .. self.n end

-- variables in scope: { name, t, mutable }
local function vars_of(scope, t)
    local out = {}
    for _, v in ipairs(scope) do if v.t == t then out[#out + 1] = v end end
    return out
end

function G:int_type() return self.r:pick(ALL_INTS) end

-- an expression of integer type t
function G:int_expr(scope, t, depth)
    local r = self.r
    local d = INTS[t]
    local choices = { 'const', 'var', 'var' }
    if depth > 0 then
        for _ = 1, 3 do choices[#choices + 1] = 'conv' end
        choices[#choices + 1] = 'bw'
        choices[#choices + 1] = 'shift'
        if not d.signed then
            for _ = 1, 3 do choices[#choices + 1] = 'bin' end
            choices[#choices + 1] = 'divmod'
        else
            choices[#choices + 1] = 'sbin'
        end
        if #self.helpers > 0 then choices[#choices + 1] = 'call' end
        if self.struct_var and t == 'U32' then choices[#choices + 1] = 'field' end
        if self.array_var and t == 'U32' then choices[#choices + 1] = 'index' end
    end
    local c = r:pick(choices)
    if c == 'var' then
        local vs = vars_of(scope, t)
        if #vs == 0 then c = 'const' else return { k = 'var', name = r:pick(vs).name, t = t } end
    end
    if c == 'const' then return { k = 'const', t = t, v = Gen.const_of(r, t) } end
    if c == 'conv' then
        local from = self:int_type()
        return { k = 'conv', t = t, e = self:int_expr(scope, from, depth - 1) }
    end
    if c == 'bin' then
        -- unsigned arithmetic wraps: always defined
        return { k = 'bin', op = r:pick { '+', '-', '*' }, a = self:int_expr(scope, t, depth - 1),
                 b = self:int_expr(scope, t, depth - 1), t = t }
    end
    if c == 'sbin' then
        -- signed: operands narrowed to a quarter of the range, so + and - cannot overflow
        local narrow = ({ I8 = 'I8', I16 = 'I8', I32 = 'I16', I64 = 'I32' })[t]
        local function small() return { k = 'conv', t = t, e = { k = 'conv', t = narrow,
            e = self:int_expr(scope, narrow, depth - 1) } } end
        local a, b = small(), small()
        if t == 'I8' then
            -- I8 + I8 can overflow I8: go through I16 and back by a defined (unsigned) route
            return { k = 'conv', t = 'I8', e = { k = 'conv', t = 'U8', e = { k = 'bin', op = r:pick { '+', '-' },
                a = { k = 'conv', t = 'U16', e = a }, b = { k = 'conv', t = 'U16', e = b }, t = 'U16' } } }
        end
        return { k = 'bin', op = r:pick { '+', '-' }, a = a, b = b, t = t }
    end
    if c == 'divmod' then
        local b = { k = 'bw', fn = 'bor', a = self:int_expr(scope, t, depth - 1), b = { k = 'const', t = t, v = 1 }, t = t }
        return { k = 'divmod', op = r:pick { '/', '%' }, a = self:int_expr(scope, t, depth - 1), b = b, t = t }
    end
    if c == 'bw' then
        if d.signed then
            -- bitwise on signed values: through the unsigned type of the same width
            local u = 'U' .. d.bits
            return { k = 'conv', t = t, e = { k = 'bw', fn = r:pick { 'band', 'bor', 'bxor' },
                a = { k = 'conv', t = u, e = self:int_expr(scope, t, depth - 1) },
                b = { k = 'conv', t = u, e = self:int_expr(scope, t, depth - 1) }, t = u } }
        end
        return { k = 'bw', fn = r:pick { 'band', 'bor', 'bxor' }, a = self:int_expr(scope, t, depth - 1),
                 b = self:int_expr(scope, t, depth - 1), t = t }
    end
    if c == 'shift' then
        local u = 'U' .. d.bits
        local e = { k = 'shift', fn = r:pick { 'shl', 'shr' }, a = d.signed and { k = 'conv', t = u,
            e = self:int_expr(scope, t, depth - 1) } or self:int_expr(scope, t, depth - 1), n = r:int(0, d.bits - 1), t = u }
        if d.signed then return { k = 'conv', t = t, e = e } end
        return e
    end
    if c == 'call' then
        local h = r:pick(self.helpers)
        local call = { k = 'call', fn = h.name, args = {}, t = h.ret }
        for i, pt in ipairs(h.params) do call.args[i] = self:int_expr(scope, pt, depth - 1) end
        if h.ret ~= t then return { k = 'conv', t = t, e = call } end
        return call
    end
    if c == 'field' then
        return { k = 'field', base = self.struct_var, name = r:pick { 'a', 'b' }, t = 'U32' }
    end
    if c == 'index' then
        return { k = 'index', base = self.array_var, i = self:int_expr(scope, 'U32', depth - 1), n = 4, t = 'U32' }
    end
    error('int_expr ' .. c)
end

function G:bool_expr(scope, depth)
    local r = self.r
    local c = r:int(1, depth > 0 and 5 or 2)
    if c <= 2 or depth <= 0 then
        local t = self:int_type()
        return { k = 'cmp', op = r:pick { '==', '~=', '<', '<=', '>', '>=' }, a = self:int_expr(scope, t, depth - 1),
                 b = self:int_expr(scope, t, depth - 1) }
    elseif c <= 4 then
        return { k = 'logic', op = r:pick { 'and', 'or' }, a = self:bool_expr(scope, depth - 1),
                 b = self:bool_expr(scope, depth - 1) }
    else
        return { k = 'not', e = self:bool_expr(scope, depth - 1) }
    end
end

-- statements: a block that mixes what it computes into h
function G:block(scope, depth, size, in_loop)
    local r = self.r
    local out = {}
    local local_scope = { parent = scope }
    for _, v in ipairs(scope) do local_scope[#local_scope + 1] = v end
    for _ = 1, size do
        local c = r:int(1, 12)
        if c <= 3 then
            local t = self:int_type()
            local name = self:fresh('v')
            out[#out + 1] = { k = 'local', name = name, t = t, e = self:int_expr(local_scope, t, self.depth_max) }
            local_scope[#local_scope + 1] = { name = name, t = t, mutable = true }
            out[#out + 1] = { k = 'mix', e = { k = 'var', name = name, t = t } }
        elseif c <= 5 then
            local vs = {}
            for _, v in ipairs(local_scope) do if v.mutable then vs[#vs + 1] = v end end
            if #vs > 0 then
                local v = r:pick(vs)
                out[#out + 1] = { k = 'assign', target = v.name, e = self:int_expr(local_scope, v.t, self.depth_max) }
            end
        elseif c == 6 and depth > 0 then
            out[#out + 1] = { k = 'if', c = self:bool_expr(local_scope, 2), a = self:block(local_scope, depth - 1, r:int(1, 3), in_loop),
                              b = r:chance(0.5) and self:block(local_scope, depth - 1, r:int(1, 3), in_loop) or {} }
        elseif c == 7 and depth > 0 then
            out[#out + 1] = { k = 'while', counter = self:fresh('k'), n = r:int(0, 9), c = self:bool_expr(local_scope, 1),
                              body = self:block(local_scope, depth - 1, r:int(1, 3), true) }
        elseif c == 8 and depth > 0 then
            local var = self:fresh('i')
            local inner = { parent = local_scope }
            for _, v in ipairs(local_scope) do inner[#inner + 1] = v end
            inner[#inner + 1] = { name = var, t = 'U32', mutable = false }
            local lo = { k = 'const', t = 'U32', v = r:int(0, 3) }
            local hi = r:chance(0.5) and { k = 'const', t = 'U32', v = r:int(0, 6) }
                or { k = 'bw', fn = 'band', a = self:int_expr(local_scope, 'U32', 1), b = { k = 'const', t = 'U32', v = 7 }, t = 'U32' }
            out[#out + 1] = { k = 'for', var = var, lo = lo, hi = hi, body = self:block(inner, depth - 1, r:int(1, 3), true) }
        elseif c == 9 and depth > 0 then
            -- a host loop unrolls; `break` inside it would break the host loop, so none is generated there
            out[#out + 1] = { k = 'hostfor', n = r:int(1, 3), body = self:block(local_scope, depth - 1, r:int(1, 2), false) }
        elseif c == 10 and self.struct_var then
            out[#out + 1] = { k = 'assign', target = self.struct_var .. '.' .. r:pick { 'a', 'b' },
                              e = self:int_expr(local_scope, 'U32', self.depth_max) }
        elseif c == 11 and self.array_var then
            out[#out + 1] = { k = 'assign', target = self.array_var .. '[' .. P.expr(self:int_expr(local_scope, 'U32', 1)) .. ' % 4]',
                              e = self:int_expr(local_scope, 'U32', self.depth_max) }
        elseif c == 12 and depth > 0 and self.sum_var then
            out[#out + 1] = { k = 'match', subject = self.sum_var,
                              num = { { k = 'mix', e = { k = 'raw', text = 'x' } } },
                              none = self:block(local_scope, depth - 1, 1, in_loop) }
        else
            out[#out + 1] = { k = 'mix', e = self:int_expr(local_scope, self:int_type(), 2) }
        end
        if in_loop and r:chance(0.05) then
            out[#out + 1] = { k = 'if', c = self:bool_expr(local_scope, 1), a = { { k = 'break' } }, b = {} }
        end
    end
    return out
end

-- helper words: plain, specialized on a compile-time table, recursive (tail and not)
function G:helper(i)
    local r = self.r
    local name = 'g' .. i
    local nparams = r:int(1, 3)
    local params, scope = {}, {}
    for j = 1, nparams do
        local t = self:int_type()
        params[j] = t
        scope[#scope + 1] = { name = 'p' .. j, t = t, mutable = false }
    end
    local ret = self:int_type()
    local kind = r:pick { 'plain', 'plain', 'rec_tail', 'rec' }
    local h = { name = name, params = params, ret = ret, kind = kind, scope = scope }
    local saved = self.helpers
    self.helpers = { unpack(saved) }
    if kind == 'plain' then
        h.body = self:int_expr(scope, ret, 2)
    else
        h.body = self:int_expr(scope, ret, 1)
        h.step = self:int_expr(scope, params[1], 1)
    end
    self.helpers = saved
    return h
end

local function print_helper(h, out)
    local ps = {}
    for j, t in ipairs(h.params) do ps[j] = 'p' .. j .. ': ' .. t end
    if h.kind == 'plain' then
        out[#out + 1] = ('local %s = do(%s): %s'):format(h.name, table.concat(ps, ', '), h.ret)
        out[#out + 1] = '    return ' .. P.expr(h.body)
        out[#out + 1] = 'end'
    else
        -- recursion with fuel: n decreases to 0 (bounded by n % 12)
        local args = { 'n - 1' }
        out[#out + 1] = ('local %s_r'):format(h.name)
        out[#out + 1] = ('%s_r = do(n: U32, %s): %s'):format(h.name, table.concat(ps, ', '), h.ret)
        out[#out + 1] = '    if n == 0 then'
        out[#out + 1] = '        return ' .. P.expr(h.body)
        out[#out + 1] = '    end'
        local call = { 'n - 1', P.expr(h.step) }
        for j = 2, #h.params do call[#call + 1] = 'p' .. j end
        if h.kind == 'rec_tail' then
            out[#out + 1] = ('    return %s_r(%s)'):format(h.name, table.concat(call, ', '))
        else
            out[#out + 1] = ('    return %s(bxor(%s(%s_r(%s)), %s(n)))'):format(h.ret, 'U' .. INTS[h.ret].bits,
                h.name, table.concat(call, ', '), 'U' .. INTS[h.ret].bits)
        end
        out[#out + 1] = 'end'
        local names = {}
        for j = 1, #h.params do names[j] = 'p' .. j end
        out[#out + 1] = ('local %s = do(%s): %s'):format(h.name, table.concat(ps, ', '), h.ret)
        out[#out + 1] = ('    return %s_r(band(U32(p1), 7), %s)'):format(h.name, table.concat(names, ', '))
        out[#out + 1] = 'end'
    end
end

-- a whole program: helpers, then f(params): U64
function Gen.program(seed, opts)
    local g = Gen.new(seed, opts)
    local r = g.r
    local prog = { seed = seed, helpers = {}, params = {} }
    for i = 1, r:int(0, 3) do
        local h = g:helper(i)
        prog.helpers[#prog.helpers + 1] = h
        g.helpers[#g.helpers + 1] = h
    end
    local scope = {}
    for j = 1, r:int(1, 4) do
        local t = g:int_type()
        prog.params[j] = t
        scope[#scope + 1] = { name = 'a' .. j, t = t, mutable = false }
    end
    prog.use_struct = r:chance(0.5)
    prog.use_array = r:chance(0.5)
    prog.use_sum = r:chance(0.5)
    -- initial values come first: they may not use the struct, array or sum they initialize
    if prog.use_sum then
        prog.sum_cond = g:bool_expr(scope, 1)
        prog.sum_val = g:int_expr(scope, 'U32', 1)
    end
    if prog.use_struct then
        prog.struct_init = { g:int_expr(scope, 'U32', 1), g:int_expr(scope, 'U32', 1) }
    end
    if prog.use_array then
        prog.array_init = {}
        for k = 1, 4 do prog.array_init[k] = g:int_expr(scope, 'U32', 1) end
    end
    if prog.use_struct then g.struct_var = 's' end
    if prog.use_array then g.array_var = 'arr' end
    if prog.use_sum then g.sum_var = 'o' end
    prog.body = g:block(scope, 3, r:int(3, 8), false)
    return prog
end

function Gen.render(prog)
    local out = { '-- fuzz program ' .. tostring(prog.seed) }
    if prog.use_struct then out[#out + 1] = 'local S = struct { a: U32, b: U32 }' end
    if prog.use_sum then out[#out + 1] = 'local O = oneof { num: U32, none: Unit }' end
    for _, h in ipairs(prog.helpers) do print_helper(h, out) end
    local ps = {}
    for j, t in ipairs(prog.params) do ps[j] = 'a' .. j .. ': ' .. t end
    out[#out + 1] = 'local f = do(' .. table.concat(ps, ', ') .. '): U64'
    out[#out + 1] = '    local h: U64 = 17'
    if prog.use_struct then
        out[#out + 1] = '    local s: S = S { a = ' .. P.expr(prog.struct_init[1]) .. ', b = ' .. P.expr(prog.struct_init[2]) .. ' }'
    end
    if prog.use_array then
        local a = {}
        for k = 1, 4 do a[k] = P.expr(prog.array_init[k]) end
        out[#out + 1] = '    local arr: Array(U32, 4) = Array(U32, 4) { ' .. table.concat(a, ', ') .. ' }'
    end
    if prog.use_sum then
        out[#out + 1] = '    local o: O = O.none()'
        out[#out + 1] = '    if ' .. P.expr(prog.sum_cond) .. ' then'
        out[#out + 1] = '        o = O.num(' .. P.expr(prog.sum_val) .. ')'
        out[#out + 1] = '    end'
    end
    P.block(prog.body, 1, out)
    if prog.use_struct then out[#out + 1] = '    h = h * 31 + U64(s.a) * 7 + U64(s.b)' end
    if prog.use_array then out[#out + 1] = '    h = h * 31 + U64(arr[0]) + U64(arr[1]) * 3 + U64(arr[2]) * 5 + U64(arr[3]) * 7' end
    out[#out + 1] = '    return h'
    out[#out + 1] = 'end'
    return table.concat(out, '\n') .. '\n'
end

-- inputs: one value per parameter
function Gen.inputs(prog, seed, n)
    local r = Gen.rng(seed + 7919)
    local vecs = {}
    for i = 1, n do
        local v = {}
        for j, t in ipairs(prog.params) do v[j] = Gen.const_of(r, t) end
        vecs[i] = v
    end
    return vecs
end

return Gen
