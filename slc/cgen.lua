-- slc.cgen: residual IR -> C.
--
-- The IR handed over is already specialized: everything here is presentation
-- and local cleanup that does not change behaviour (returns that jump to a
-- `return r` become direct returns, stores no one reads are dropped, jumps to
-- the next statement disappear, declarations go where they read best).

local types = require 'slc.types'
local fold = require 'slc.fold'
local S = require 'slc.stage'

local G = {}

local function rawp(p, k) return rawget(p, k) end

-- types --------------------------------------------------------------------------------------

local struct_names = {}

local function ctype(t)
    if t.kind == 'atomic' then return ctype(t.elem) end
    if t.kind == 'struct' or t.kind == 'sum' or t.kind == 'array' then
        if not rawget(t, 'cname') then rawset(t, 'cname', S.unique_global(t.name)) end
        return rawget(t, 'cname')
    end
    if t.kind == 'ref' then return ctype(t.elem) .. ' *' end
    if t.kind == 'ptr' then return ctype(t.elem) .. ' *' end
    if t.kind == 'fn' then
        local ps = {}
        for i, p in ipairs(t.params) do ps[i] = ctype(p) end
        if #ps == 0 then ps[1] = 'void' end
        return (t.ret.kind == 'unit' and 'void' or ctype(t.ret)) .. ' (*)(' .. table.concat(ps, ', ') .. ')'
    end
    if t.ctype then return t.ctype() end
    return t.cname
end
G.ctype = ctype

local function decl_of(t, name)
    if t.kind == 'fn' then
        local ps = {}
        for i, p in ipairs(t.params) do ps[i] = ctype(p) end
        if #ps == 0 then ps[1] = 'void' end
        return (t.ret.kind == 'unit' and 'void' or ctype(t.ret)) .. ' (*' .. name .. ')(' .. table.concat(ps, ', ') .. ')'
    end
    local ct = ctype(t)
    if ct:sub(-1) == '*' then return ct .. name end
    return ct .. ' ' .. name
end

local negate

-- the C member a field names: itself, or a path given by a foreign struct
function G.cfield(t, name)
    local paths = type(t) == 'table' and rawget(t, 'cpath')
    return paths and paths[name] or name
end

-- walking the IR ----------------------------------------------------------------------------

local CHILD_BLOCKS = { 'a', 'b', 'body' }

local function walk_expr(e, f)
    if type(e) ~= 'table' then return end
    f(e)
    for _, k in ipairs { 'a', 'b', 'e', 'ptr', 'i', 'n', 'idx', 'slot' } do
        local c = e[k]
        if type(c) == 'table' and c.op then walk_expr(c, f) end
    end
    if e.args then for _, a in ipairs(e.args) do walk_expr(a, f) end end
    -- an operation that takes the address of a place uses it, exactly like addr
    if e.expected_place then
        walk_expr({ op = 'addr', place = e.expected_place, T = e.T }, f)
    end
    if e.fields then for _, a in pairs(e.fields) do walk_expr(a, f) end end
    if e.place then
        -- a place can hide a pointer expression (deref of a parameter)
        local p = e.place
        while p do
            local ptr = rawp(p, 'ptr')
            if ptr then walk_expr(ptr, f) end
            local base, idx = rawp(p, 'base'), rawp(p, 'idx')
            if base then walk_expr(base, f) end
            if idx then walk_expr(idx, f) end
            p = rawp(p, 'parent')
        end
    end
end

local STMT_EXPRS = { 'e', 'c', 'lo', 'hi', 'i', 'n', 'a', 'b', 'slot' }

local function walk_block(blk, fs, fe)
    for _, s in ipairs(blk) do
        if fs then fs(s, blk) end
        if fe then
            for _, k in ipairs(STMT_EXPRS) do if s[k] then walk_expr(s[k], fe) end end
            if s.args then for _, a in ipairs(s.args) do walk_expr(a, fe) end end
            if s.place then walk_expr({ op = 'place', place = s.place }, fe) end
            if s.iv then walk_expr({ op = 'place', place = s.iv }, fe) end
        end
        if s.op == 'if' then
            walk_block(s.a, fs, fe); walk_block(s.b, fs, fe)
        elseif s.op == 'for' or s.op == 'loop' or (s.op == 'wait' and s.body) then
            walk_block(s.body, fs, fe)
        end
    end
end

G.walk_block = walk_block
G.walk_expr = walk_expr

local function root(p)
    local q = rawp(p, 'parent')
    while q do p = q; q = rawp(p, 'parent') end
    return p
end

-- storage reached through a pointer: never declared, never assumed unread
local function memory(r) return r.pk == 'deref' or r.pk == 'index' end

local TERMINAL = { ret = true, ['goto'] = true, ['break'] = true }

local function terminal(s)
    if TERMINAL[s.op] then return true end
    if s.op == 'if' then
        local a, b = s.a[#s.a], s.b[#s.b]
        return a ~= nil and b ~= nil and terminal(a) and terminal(b)
    end
    if s.op == 'loop' then
        -- a loop that never jumps to its end (or breaks) never falls through
        local leaves = false
        walk_block(s.body, function(x)
            if x.op == 'break' or (x.op == 'goto' and s.ends and x.label == s.ends) then leaves = true end
        end)
        return not leaves
    end
    return false
end

-- cleanup ------------------------------------------------------------------------------------

-- drop statements after a terminal one
local function prune_after_terminal(blk)
    for i, s in ipairs(blk) do
        if s.op == 'if' then prune_after_terminal(s.a); prune_after_terminal(s.b)
        elseif s.op == 'for' or s.op == 'loop' then prune_after_terminal(s.body) end
        if terminal(s) then
            -- labels after a terminal statement are still reachable by jumps
            local j = i + 1
            while blk[j] and blk[j].op ~= 'label' do table.remove(blk, j) end
        end
    end
end

-- `r = e; goto L` where `L:` is followed by `return r` becomes `return e`
local function propagate_returns(body)
    local ret_after = {}
    local function scan(blk)
        for i, s in ipairs(blk) do
            if s.op == 'label' then
                local j = i + 1
                while blk[j] and blk[j].op == 'label' do j = j + 1 end
                local n = blk[j]
                if n and n.op == 'ret' then
                    if n.e == nil then
                        ret_after[s.label] = { void = true }
                    elseif n.e.op == 'read' and n.e.place.pk == 'rvar' then
                        ret_after[s.label] = { rvar = n.e.place }
                    end
                end
            end
        end
        for _, s in ipairs(blk) do
            if s.op == 'if' then scan(s.a); scan(s.b)
            elseif s.op == 'for' or s.op == 'loop' then scan(s.body) end
        end
    end
    scan(body)
    if not next(ret_after) then return end

    local function local_store(s)
        return s.op == 'store' and not memory(root(s.place))
    end
    -- rewrite the tail [store r e, local stores..., goto L] of a statement run
    local function rewrite_tail(blk, i, info)
        -- blk[i] is the jump (or the label for a fallthrough); walk back
        local j = i - 1
        while j >= 1 and local_store(blk[j]) and not (info.rvar and blk[j].place == info.rvar) do
            j = j - 1
        end
        if info.void then
            for k = i - 1, j + 1, -1 do table.remove(blk, k) end
            return j + 1
        end
        local st = blk[j]
        if j >= 1 and st.op == 'store' and st.place == info.rvar then
            for k = i - 1, j + 1, -1 do table.remove(blk, k) end
            blk[j] = { op = 'ret', e = st.e }
            return j
        end
        return nil
    end
    local function rewrite(blk)
        local i = 1
        while i <= #blk do
            local s = blk[i]
            if s.op == 'goto' and ret_after[s.label] then
                local info = ret_after[s.label]
                local at = rewrite_tail(blk, i, info)
                if at then
                    if info.void then
                        blk[at] = { op = 'ret' }
                        -- remove the goto, now replaced
                        while blk[at + 1] and blk[at + 1].op == 'goto' and blk[at + 1].label == s.label do
                            table.remove(blk, at + 1)
                        end
                        i = at + 1
                    else
                        -- remove the goto that followed the store
                        if blk[at + 1] and blk[at + 1].op == 'goto' then table.remove(blk, at + 1) end
                        i = at + 1
                    end
                else
                    i = i + 1
                end
            elseif s.op == 'label' and ret_after[s.label] and i > 1 then
                -- fallthrough into the label from a base-level `r = e`
                local info = ret_after[s.label]
                if not info.void then
                    local at = rewrite_tail(blk, i, info)
                    if at then i = at + 2 else i = i + 1 end
                else
                    i = i + 1
                end
            else
                if s.op == 'if' then rewrite(s.a); rewrite(s.b)
                elseif s.op == 'for' or s.op == 'loop' then rewrite(s.body) end
                i = i + 1
            end
        end
    end
    rewrite(body)
end

-- a jump to the label that comes next anyway disappears
local function drop_jumps_to_next(blk, next_label)
    for i, s in ipairs(blk) do
        local nxt
        local n = blk[i + 1]
        if n then
            if n.op == 'label' then nxt = n.label end
        else
            nxt = next_label
        end
        if s.op == 'if' then
            drop_jumps_to_next(s.a, nxt); drop_jumps_to_next(s.b, nxt)
        elseif s.op == 'loop' then
            -- falling off a loop body goes back to its top
            drop_jumps_to_next(s.body, s.top)
        elseif s.op == 'for' then
            drop_jumps_to_next(s.body, nil)
        end
    end
    local last = blk[#blk]
    if last and last.op == 'goto' and last.label == next_label then blk[#blk] = nil end
    for i = #blk - 1, 1, -1 do
        local s, n = blk[i], blk[i + 1]
        if s.op == 'goto' and n.op == 'label' and n.label == s.label then table.remove(blk, i) end
    end
end

local function remove_unused_labels(body)
    local used = {}
    walk_block(body, function(s) if s.op == 'goto' then used[s.label] = true end end)
    local function rm(blk)
        for i = #blk, 1, -1 do
            local s = blk[i]
            if s.op == 'label' and not used[s.label] then
                local prev = blk[i - 1]
                table.remove(blk, i)
                -- a statement after an unreachable label is unreachable too
                if prev and terminal(prev) then
                    while blk[i] and blk[i].op ~= 'label' do table.remove(blk, i) end
                end
            elseif s.op == 'if' then rm(s.a); rm(s.b)
            elseif s.op == 'for' or s.op == 'loop' then rm(s.body) end
        end
    end
    rm(body)
end

-- stores to locals nobody reads, and pure temporaries nobody uses
local function dead_stores(body)
    local changed = true
    while changed do
        changed = false
        local readers = {}
        local function mark(e)
            if (e.op == 'read' or e.op == 'addr' or e.op == 'rt') and e.place then
                readers[root(e.place)] = true
            end
        end
        walk_block(body, function(s)
            for _, key in ipairs(STMT_EXPRS) do if s[key] then walk_expr(s[key], mark) end end
            for _, e in ipairs(s.args or {}) do walk_expr(e, mark) end
            local p = s.place
            while p do
                local ptr, base, idx = rawp(p, 'ptr'), rawp(p, 'base'), rawp(p, 'idx')
                if ptr then walk_expr(ptr, mark) end
                -- A local array's LHS base names its storage; it does not read
                -- its contents. Index expressions still can read that array.
                if base and not rawp(p, 'array_owner') then walk_expr(base, mark) end
                if idx then walk_expr(idx, mark) end
                p = rawp(p, 'parent')
            end
        end)
        -- Reads used to compute an address/index count; naming its owner does not.
        local function rm(blk)
            for i = #blk, 1, -1 do
                local s = blk[i]
                if (s.op == 'store' or s.op == 'let') and not memory(root(s.place))
                    and not readers[root(s.place)] then
                    local effectful = false
                    walk_expr(s.e, function(x)
                        if x.op == 'atomic' or x.op == 'slot_at' then effectful = true end
                        if (x.op == 'call' and not (x.ext and x.ext.variable)) or (x.op == 'rt' and not x.pure) then
                            effectful = true
                        end
                    end)
                    if effectful then
                        blk[i] = { op = 'expr', e = s.e }
                    else
                        table.remove(blk, i)
                    end
                    changed = true
                elseif s.op == 'if' then
                    rm(s.a); rm(s.b)
                    if #s.a == 0 and #s.b == 0 then table.remove(blk, i); changed = true end
                elseif s.op == 'for' or s.op == 'loop' then rm(s.body) end
            end
        end
        rm(body)
    end
end

-- a temporary used once, by the very next statement, whose other operands
-- cannot be affected by computing it, is written in place
local function inline_temps(body)
    local uses = {}
    walk_block(body, nil, function(e)
        -- a place whose address is taken is used there too: it cannot move
        if (e.op == 'read' or e.op == 'addr') and e.place.pk == 'temp' then
            uses[e.place] = (uses[e.place] or 0) + 1
        end
    end)
    local function stable(e)
        -- every other leaf must keep its value across the call
        local ok = true
        walk_expr(e, function(x)
            if x.op == 'call' or x.op == 'atomic' or x.op == 'slot_at' then ok = false
            elseif x.op == 'read' or x.op == 'addr' then
                local r = root(x.place)
                if memory(r) or rawp(r, 'escaped') then ok = false end
            elseif x.op == 'rt' and not x.pure then ok = false end
        end)
        return ok
    end
    local function exprs_of(s)
        local out = {}
        for _, k in ipairs(STMT_EXPRS) do if s[k] then out[#out + 1] = { s, k } end end
        if s.args then for i in ipairs(s.args) do out[#out + 1] = { s.args, i } end end
        return out
    end
    local function rewrite(blk)
        local i = 1
        while i < #blk do
            local s, n = blk[i], blk[i + 1]
            local done = false
            if s.op == 'let' and s.place.pk == 'temp' and uses[s.place] == 1 and n.op ~= 'label'
                and n.op ~= 'for' and n.op ~= 'loop' then
                local slots = exprs_of(n)
                local found, others_ok = nil, true
                for _, slot in ipairs(slots) do
                    local e = slot[1][slot[2]]
                    -- never into a conditionally evaluated operand: the effect
                    -- would no longer happen unconditionally
                    local function find(x, conditional)
                        if type(x) ~= 'table' or not x.op then return end
                        if x.op == 'read' and x.place == s.place then
                            if conditional then others_ok = false else found = x end
                            return
                        end
                        local cond_b = x.op == 'and' or x.op == 'or'
                        for _, k in ipairs { 'a', 'b', 'e' } do
                            if type(x[k]) == 'table' then find(x[k], conditional or (cond_b and k == 'b')) end
                        end
                        if x.args then for _, a in ipairs(x.args) do find(a, conditional) end end
                        if x.fields then for _, a in pairs(x.fields) do find(a, conditional) end end
                    end
                    find(e, false)
                    if not stable(e) then others_ok = false end
                end
                if n.op == 'store' and rawp(root(n.place), 'escaped') == nil and root(n.place).pk == 'deref' then
                    -- `*p = f()`: the pointer is a parameter, fine
                end
                if found and others_ok then
                    for k in pairs(found) do found[k] = nil end
                    for k, v in pairs(s.e) do found[k] = v end
                    table.remove(blk, i)
                    done = true
                end
            end
            if not done then
                if s.op == 'if' then rewrite(s.a); rewrite(s.b)
                elseif s.op == 'for' or s.op == 'loop' then rewrite(s.body) end
                i = i + 1
            end
        end
        local last = blk[#blk]
        if last then
            if last.op == 'if' then rewrite(last.a); rewrite(last.b)
            elseif last.op == 'for' or last.op == 'loop' then rewrite(last.body) end
        end
    end
    rewrite(body)
end

local function drop_nops(blk)
    for i = #blk, 1, -1 do
        local s = blk[i]
        if s.op == 'nop' then table.remove(blk, i)
        elseif s.op == 'if' then drop_nops(s.a); drop_nops(s.b)
        elseif s.op == 'for' or s.op == 'loop' then drop_nops(s.body) end
    end
end

-- structural equality of expressions
local function same_expr(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' or a.op ~= b.op then return false end
    if a.op == 'const' then return a.T == b.T and fold.identical(a.T, a.v, b.v) end
    if a.op == 'param' then return a.name == b.name end
    if a.op == 'read' or a.op == 'addr' then return a.place == b.place end
    for _, k in ipairs { 'o', 'name', 'T', 'fn', 'ext', 'text', 'alt', 'sum' } do
        if a[k] ~= b[k] then return false end
    end
    for _, k in ipairs { 'a', 'b', 'e' } do
        if (a[k] ~= nil) ~= (b[k] ~= nil) then return false end
        if a[k] and not same_expr(a[k], b[k]) then return false end
    end
    if a.args or b.args then
        if not (a.args and b.args) or #a.args ~= #b.args then return false end
        for i = 1, #a.args do if not same_expr(a.args[i], b.args[i]) then return false end end
    end
    if a.fields or b.fields then
        if not (a.fields and b.fields) then return false end
        for k, v in pairs(a.fields) do if not same_expr(v, b.fields[k]) then return false end end
    end
    return a.op ~= 'call' and a.op ~= 'rt' or a.pure == true
end

local function reads_root(e, r)
    local found = false
    walk_expr(e, function(x)
        if (x.op == 'read' or x.op == 'addr') and x.place and root(x.place) == r then found = true end
    end)
    return found
end

-- `if (c) { s; A } else { s; B }` with a pure store s the condition does not read
local function hoist_common(blk)
    local i = 1
    while i <= #blk do
        local s = blk[i]
        if s.op == 'if' then
            hoist_common(s.a); hoist_common(s.b)
            -- a store found in the leading run of pure stores of both arms, that
            -- commutes with the stores before it, moves before the conditional
            local function pure_store(x)
                if x.op ~= 'store' and x.op ~= 'let' then return false end
                if memory(root(x.place)) then return false end
                local effect = false
                walk_expr(x.e, function(z) if z.op == 'call' or z.op == 'rt' then effect = true end end)
                return not effect
            end
            local function commutes(run, k, x)
                for n = 1, k - 1 do
                    local o = run[n]
                    if root(o.place) == root(x.place) or reads_root(x.e, root(o.place))
                        or reads_root(o.e, root(x.place)) then return false end
                end
                return true
            end
            local progress = true
            while progress do
                progress = false
                for ka = 1, #s.a do
                    local x = s.a[ka]
                    if not pure_store(x) then break end
                    if not reads_root(s.c, root(x.place)) and commutes(s.a, ka, x) then
                        for kb = 1, #s.b do
                            local y = s.b[kb]
                            if not pure_store(y) then break end
                            if y.place == x.place and same_expr(x.e, y.e) and commutes(s.b, kb, y) then
                                table.remove(s.a, ka); table.remove(s.b, kb)
                                table.insert(blk, i, x)
                                i = i + 1
                                progress = true
                                break
                            end
                        end
                    end
                    if progress then break end
                end
            end
        elseif s.op == 'for' or s.op == 'loop' then
            hoist_common(s.body)
        end
        i = i + 1
    end
end

local function jump_end(blk)
    local last = blk[#blk]
    return last and (last.op == 'ret' or last.op == 'goto' or last.op == 'break')
end

-- an arm that ends in a jump lets the other arm follow the conditional
local function flatten_ifs(blk)
    local i = 1
    while i <= #blk do
        local s = blk[i]
        if s.op == 'if' then
            flatten_ifs(s.a); flatten_ifs(s.b)
            if #s.b > 0 and jump_end(s.a) then
                for j, x in ipairs(s.b) do table.insert(blk, i + j, x) end
                s.b = {}
            elseif #s.a > 0 and #s.b > 0 and jump_end(s.b) and not jump_end(s.a) then
                local rest = s.a
                s.c, s.a, s.b = negate(s.c), s.b, {}
                for j, x in ipairs(rest) do table.insert(blk, i + j, x) end
            end
        elseif s.op == 'for' or s.op == 'loop' then
            flatten_ifs(s.body)
        end
        i = i + 1
    end
end

G.cleanup = function(fn)
    if fn.cleaned then return end
    fn.cleaned = true
    drop_nops(fn.body)
    prune_after_terminal(fn.body)
    propagate_returns(fn.body)
    prune_after_terminal(fn.body)
    drop_jumps_to_next(fn.body, nil)
    remove_unused_labels(fn.body)
    dead_stores(fn.body)
    hoist_common(fn.body)
    flatten_ifs(fn.body)
    inline_temps(fn.body)
    drop_jumps_to_next(fn.body, nil)
    remove_unused_labels(fn.body)
    -- a void function needs no final `return;`
    local last = fn.body[#fn.body]
    if fn.ret.kind == 'unit' and last and last.op == 'ret' and not last.e then
        fn.body[#fn.body] = nil
    end
end

-- expressions --------------------------------------------------------------------------------

local PREC = {
    lor = 4, land = 5, bor = 6, bxor = 7, band = 8, eq = 9, rel = 10, shift = 11,
    add = 12, mul = 13, unary = 14, postfix = 15, atom = 16,
}
-- The C type a varargs argument is promoted to (C's default argument promotions).
-- The jitgen backend converts to the matching gccjit type from the same names.
G.VACONV = { int = 'int', uint = 'unsigned', llong = 'long long', ullong = 'unsigned long long',
             double = 'double' }
local VACONV = G.VACONV
local BIN = {
    add = { '+', 'add' }, sub = { '-', 'add' }, mul = { '*', 'mul' }, div = { '/', 'mul' },
    mod = { '%', 'mul' }, band = { '&', 'band' }, bor = { '|', 'bor' }, bxor = { '^', 'bxor' },
    shl = { '<<', 'shift' }, shr = { '>>', 'shift' },
}
local CMP = { eq = { '==', 'eq' }, ne = { '!=', 'eq' }, lt = { '<', 'rel' }, le = { '<=', 'rel' },
              gt = { '>', 'rel' }, ge = { '>=', 'rel' } }

local Fn = {}
Fn.__index = Fn

function Fn:pname(p)
    local n = self.names[p]
    if not n then
        local base = p.name
        if p.pk == 'temp' then base = rawget(p, 'hint') or 't' end
        n = S.sanitize(base)
        local cand, k = n, 1
        -- a local must not hide a function, type or global it could call
        while self.used[cand] or S.module.names[cand] do k = k + 1; cand = n .. k end
        self.used[cand] = true
        if self.task_mode then
            -- a task's locals live in its frame
            self.fields[#self.fields + 1] = decl_of(p.T, cand)
            cand = 'f->' .. cand
        end
        self.names[p] = cand
        n = cand
    end
    return n
end

-- place -> C lvalue text and its precedence
function Fn:place(p)
    if p.pk == 'param' then
        return self.task_mode and ('f->' .. p.name) or p.name, self.task_mode and PREC.postfix or PREC.atom
    end
    if p.pk == 'index' then
        local base, idx = rawp(p, 'base'), rawp(p, 'idx')
        -- element 0 of a global is the object itself
        if base.op == 'gaddr' and idx.op == 'const' and idx.v == 0 then
            return S.global_cname(base.global), PREC.atom
        end
        return self:expr(base, PREC.postfix) .. '[' .. self:expr(idx, 0) .. ']', PREC.postfix
    end
    if p.pk == 'deref' then
        local ptr = rawp(p, 'ptr')
        if ptr.op == 'gaddr' then return S.global_cname(ptr.global), PREC.atom end
        local s = self:expr(ptr, PREC.unary)
        return '*' .. s, PREC.unary
    end
    if p.pk == 'field' then
        local parent = rawp(p, 'parent')
        local member = G.cfield(parent.T, rawp(p, 'fname'))
        if parent.pk == 'deref' then
            local ptr = rawp(parent, 'ptr')
            if ptr.op == 'gaddr' then return S.global_cname(ptr.global) .. '.' .. member, PREC.postfix end
            return self:expr(ptr, PREC.postfix) .. '->' .. member, PREC.postfix
        end
        local s = self:place_text(parent, PREC.postfix)
        return s .. '.' .. member, PREC.postfix
    end
    return self:pname(p), PREC.atom
end

function Fn:place_text(p, need)
    local s, pr = self:place(p)
    if pr < need then return '(' .. s .. ')' end
    return s
end

local function paren(s, pr, need)
    if pr < need then return '(' .. s .. ')' end
    return s
end

function Fn:operand(e, t, need)
    -- small integer types compute in 32 bits
    if t.small then
        local wide = t.signed and 'int32_t' or 'uint32_t'
        if e.op == 'const' then return self:expr(e, need) end
        return '(' .. wide .. ')' .. self:expr(e, PREC.unary)
    end
    return self:expr(e, need)
end

-- expression text, parenthesized if its precedence is below `need`
function Fn:expr(e, need)
    need = need or 0
    local op = e.op
    if op == 'const' then
        if e.T.kind == 'cstr' and self.strings and self.strings.names[e.v] then
            return self.strings.names[e.v]
        end
        local s = fold.c_literal(e.T, e.v)
        local pr = s:match '^%-' and PREC.unary or PREC.atom
        return paren(s, pr, need)
    elseif op == 'param' then
        if self.task_mode then return paren('f->' .. e.name, PREC.postfix, need) end
        return e.name
    elseif op == 'read' then
        return self:place_text(e.place, need)
    elseif op == 'addr' then
        local p = e.place
        if p.pk == 'deref' then return self:expr(rawp(p, 'ptr'), need) end
        return paren('&' .. self:place_text(p, PREC.unary), PREC.unary, need)
    elseif op == 'bin' then
        local t = e.T
        -- `a + -k` reads as `a - k` (signed, and k is not the minimum)
        if (e.o == 'add' or e.o == 'sub') and e.b.op == 'const' and t.kind ~= 'bool'
            and (t.kind == 'float' or t.signed) and not t.small then
            local v = e.b.v
            local lo = t.kind == 'int' and fold.limits(t) or nil
            if v < 0 and (lo == nil or v ~= lo) then
                local flipped = { op = 'bin', o = e.o == 'add' and 'sub' or 'add', a = e.a,
                                  b = { op = 'const', T = t, v = -v }, T = t }
                return self:expr(flipped, need)
            end
        end
        local sym, cls = BIN[e.o][1], BIN[e.o][2]
        local pr = PREC[cls]
        -- bitwise and shift operators read badly (and warn) with bare operators inside
        local inner = pr
        if cls == 'band' or cls == 'bor' or cls == 'bxor' or cls == 'shift' then inner = PREC.unary end
        local s = self:operand(e.a, t, math.max(pr, inner)) .. ' ' .. sym .. ' '
            .. self:operand(e.b, t, math.max(pr + 1, inner))
        if t.small then
            return paren('(' .. t.cname .. ')(' .. s .. ')', PREC.unary, need)
        end
        return paren(s, pr, need)
    elseif op == 'cmp' then
        local sym, cls = CMP[e.o][1], CMP[e.o][2]
        local pr = PREC[cls]
        return paren(self:expr(e.a, pr) .. ' ' .. sym .. ' ' .. self:expr(e.b, pr + 1), pr, need)
    elseif op == 'and' or op == 'or' then
        local pr = op == 'and' and PREC.land or PREC.lor
        local sym = op == 'and' and '&&' or '||'
        -- `a || b && c` is legal C but compilers ask for brackets
        local inner = op == 'or' and PREC.lor + 2 or pr
        return paren(self:expr(e.a, math.max(pr, inner)) .. ' ' .. sym .. ' ' .. self:expr(e.b, math.max(pr + 1, inner)), pr, need)
    elseif op == 'un' then
        local t = e.T
        if e.o == 'not' then return paren('!' .. self:expr(e.a, PREC.unary), PREC.unary, need) end
        local sym = e.o == 'neg' and '-' or '~'
        if t.small then
            local wide = t.signed and 'int32_t' or 'uint32_t'
            local inner = e.o == 'neg' and (t.signed and '-' or '0u - ') or '~'
            return paren('(' .. t.cname .. ')(' .. inner .. '(' .. wide .. ')' .. self:expr(e.a, PREC.unary) .. ')',
                PREC.unary, need)
        end
        local inner = self:expr(e.a, PREC.unary)
        if sym == '-' and inner:sub(1, 1) == '-' then inner = '(' .. inner .. ')' end
        return paren(sym .. inner, PREC.unary, need)
    elseif op == 'cconst' then
        -- a header constant: the C name itself, its value supplied by the header
        return e.cconst
    elseif op == 'stack_index' then
        return e.offset == 0 and 'gs_sp' or paren('gs_sp + ' .. e.offset, PREC.add, need)
    elseif op == 'conv' then
        return paren('(' .. ctype(e.T) .. ')' .. self:expr(e.a, PREC.unary), PREC.unary, need)
    elseif op == 'field' then
        local member = e.a.T and G.cfield(e.a.T, e.name) or e.name
        return paren(self:expr(e.a, PREC.postfix) .. '.' .. member, PREC.postfix, need)
    elseif op == 'zero' then
        return '(' .. ctype(e.T) .. '){ 0 }'
    elseif op == 'array' then
        local indices, parts = {}, {}
        for i in pairs(e.fields) do indices[#indices + 1] = i end
        table.sort(indices)
        for _, i in ipairs(indices) do parts[#parts + 1] = '[' .. i .. '] = ' .. self:expr(e.fields[i], 2) end
        if #parts == 0 then parts[1] = '0' end
        return paren('(' .. ctype(e.T) .. '){ .e = { ' .. table.concat(parts, ', ') .. ' } }', PREC.postfix, need)
    elseif op == 'agg' then
        local parts = {}
        for _, f in ipairs((e.T.native_layout and e.T.native_layout() or e.T).fields) do
            parts[#parts + 1] = '.' .. G.cfield(e.T, f.name) .. ' = ' .. self:expr(e.fields[f.name], 2)
        end
        return paren('(' .. ctype(e.T) .. '){ ' .. table.concat(parts, ', ') .. ' }', PREC.postfix, need)
    elseif op == 'sum' then
        local name = ctype(e.T)
        local s = '(' .. name .. '){ .tag = ' .. name .. '_' .. e.alt
        if e.e then s = s .. ', .as.' .. e.alt .. ' = ' .. self:expr(e.e, 2) end
        return paren(s .. ' }', PREC.postfix, need)
    elseif op == 'null' then
        return 'NULL'
    elseif op == 'gaddr' then
        return paren('&' .. S.global_cname(e.global), PREC.unary, need)
    elseif op == 'fnaddr' then
        return e.fn.cname
    elseif op == 'calli' then
        local args = {}
        for i, a in ipairs(e.args) do args[i] = self:expr(a, 2) end
        local callee = e.a.op == 'fnaddr' and e.a.fn.cname or ('(*' .. self:expr(e.a, PREC.unary) .. ')')
        return callee .. '(' .. table.concat(args, ', ') .. ')'
    elseif op == 'tagname' then
        return ctype(e.sum) .. '_' .. e.alt
    elseif op == 'call' then
        local args = {}
        for i, a in ipairs(e.args) do args[i] = self:expr(a, 2) end
        local name = e.fn and e.fn.cname or e.ext.cname
        if e.ext and e.ext.variable then return name end      -- a C variable or macro read
        if e.fn and e.fn.gs then
            local off = e.gs_off or 0
            table.insert(args, 1, off == 0 and 'gs_sp' or ('gs_sp + ' .. off))
        end
        return name .. '(' .. table.concat(args, ', ') .. ')'
    elseif op == 'atomic' then
        local ptr = self:expr(e.ptr, 2)
        local local_args, args = e.args or {}, {}
        for i, a in ipairs(local_args) do args[i] = self:expr(a, 2) end
        local builtin
        if e.o == 'load' then
            builtin = '__atomic_load_n(' .. ptr .. ', ' .. e.order .. ')'
        elseif e.o == 'store' then
            builtin = '__atomic_store_n(' .. ptr .. ', ' .. args[1] .. ', ' .. e.order .. ')'
        elseif e.o == 'exchange' then
            builtin = '__atomic_exchange_n(' .. ptr .. ', ' .. args[1] .. ', ' .. e.order .. ')'
        elseif e.o == 'cas' then
            builtin = '__atomic_compare_exchange_n(' .. ptr .. ', &' .. self:place_text(e.expected_place, PREC.unary)
                .. ', ' .. args[1] .. ', false, ' .. e.order .. ', ' .. e.fail_order .. ')'
        elseif e.o == 'fetch_add' then
            builtin = '__atomic_fetch_add(' .. ptr .. ', ' .. args[1] .. ', ' .. e.order .. ')'
        elseif e.o == 'fetch_sub' then
            builtin = '__atomic_fetch_sub(' .. ptr .. ', ' .. args[1] .. ', ' .. e.order .. ')'
        else
            error('cgen: unknown atomic operation ' .. tostring(e.o))
        end
        return paren(builtin, PREC.postfix, need)
    elseif op == 'vaconv' then
        return paren('(' .. VACONV[e.abi] .. ')' .. self:expr(e.a, PREC.unary), PREC.unary, need)
    elseif op == 'sizeof' then
        return paren('(uint64_t)sizeof(' .. ctype(e.sizeof) .. ')', PREC.unary, need)
    elseif op == 'array_index' then
        return paren(self:expr(e.a, PREC.postfix) .. '.e[' .. self:expr(e.idx, 2) .. ']', PREC.postfix, need)
    elseif op == 'slot_at' then
        local task = self.task_mode and '&f->task' or 'slc_tk'
        return paren('(' .. ctype(e.T) .. ')slc_slot_at(' .. task .. ', ' .. self:expr(e.slot, 2) .. ')',
            PREC.unary, need)
    elseif op == 'rtcall' then
        -- a runtime call: the name and its arguments, printed as C
        local args = {}
        for i, a in ipairs(e.args or {}) do args[i] = self:expr(a, 2) end
        return e.cname .. '(' .. table.concat(args, ', ') .. ')'
    elseif op == 'task' then
        -- the waiting party: the running task's record, or the plain thread
        return self.task_mode and paren('&f->task', PREC.unary, need) or 'slc_tk'
    elseif op == 'ops' then
        -- its operation records, one per outstanding wait
        return self.task_mode and 'f->ops' or 'slc_ops'
    end
    error('cgen: unknown expression ' .. tostring(op))
end

-- statements ---------------------------------------------------------------------------------

function Fn:line(s)
    self.out[#self.out + 1] = ('    '):rep(self.indent) .. s
    self.printed = (self.printed or 0) + 1
end

function Fn:declared(p)
    return self.decl_inline[p] or self.hoisted[p]
end

function Fn:assign(place, e)
    local r = root(place)
    if self.task_mode then
        self:line(self:place_text(place, 2) .. ' = ' .. self:expr(e, 2) .. ';')
        return
    end
    if self.decl_inline[r] == 'pending' and place == r then
        self.decl_inline[r] = true
        self:line(decl_of(place.T, self:pname(place)) .. ' = ' .. self:expr(e, 2) .. ';')
        return
    end
    self:line(self:place_text(place, 2) .. ' = ' .. self:expr(e, 2) .. ';')
end

function negate(e)
    if e.op == 'un' and e.o == 'not' then return e.a end
    if e.op == 'cmp' then
        local inv = { eq = 'ne', ne = 'eq', lt = 'ge', ge = 'lt', le = 'gt', gt = 'le' }
        local t = e.a.T
        if t and t.kind ~= 'float' then
            return { op = 'cmp', o = inv[e.o], a = e.a, b = e.b, T = e.T }
        end
    end
    return { op = 'un', o = 'not', a = e, T = types.Bool }
end

-- an if chain testing one sum's tag against its alternatives prints as a switch
local function tag_test(c)
    if c.op == 'cmp' and c.o == 'eq' and c.b.op == 'tagname' and c.a.op == 'field' and c.a.name == 'tag' then
        return c.a.a, c.b.alt, c.b.sum
    end
end

local function has_break(blk)
    local found = false
    walk_block(blk, function(x)
        if x.op == 'goto' and x.print_as == 'break' then found = true end
    end)
    return found
end

function Fn:emit_switch(arms, sum, subj)
    local name = ctype(sum)
    self:line('switch (' .. self:expr({ op = 'field', a = subj, name = 'tag' }, 0) .. ') {')
    local covered = {}
    for _, a in ipairs(arms) do if a.alt then covered[a.alt] = true end end
    for _, a in ipairs(arms) do
        local label
        if a.alt then label = 'case ' .. name .. '_' .. a.alt .. ':'
        else
            local rest = {}
            for _, al in ipairs(sum.alts) do if not covered[al.name] then rest[#rest + 1] = name .. '_' .. al.name end end
            label = 'default: /* ' .. table.concat(rest, ', ') .. ' */'
        end
        self:line(label .. ' {')
        self.indent = self.indent + 1
        self:block(a.body)
        if not (a.body[#a.body] and terminal(a.body[#a.body])) then self:line('break;') end
        self.indent = self.indent - 1
        self:line('}')
    end
    self:line('}')
end

-- if (tag == A) {...} else if (tag == B) {...} else {...}
function Fn:try_switch(s)
    local subj, _, sum = tag_test(s.c)
    if not subj then return false end
    local arms, node = {}, s
    while true do
        local sj, al = tag_test(node.c)
        if not sj or not same_expr(sj, subj) or #node.a == 0 then return false end
        arms[#arms + 1] = { alt = al, body = node.a }
        if #node.b == 1 and node.b[1].op == 'if' and tag_test(node.b[1].c) then
            node = node.b[1]
        else
            arms[#arms + 1] = { body = node.b }
            break
        end
    end
    if #arms < 3 then return false end
    for _, a in ipairs(arms) do if has_break(a.body) then return false end end
    self:emit_switch(arms, sum, subj)
    return true
end

-- consecutive `if (s.tag == A) { ...; return }` arms, then the remaining
-- alternative as the rest of the block, print as one switch
function Fn:block_switch(blk, i)
    local first = blk[i]
    if first.op ~= 'if' or #first.b > 0 then return nil end
    local subj, _, sum = tag_test(first.c)
    if not subj then return nil end
    local arms, j = {}, i
    while j <= #blk do
        local s = blk[j]
        if s.op ~= 'if' or #s.b > 0 then break end
        local sj, al = tag_test(s.c)
        if not sj or not same_expr(sj, subj) then break end
        local last = s.a[#s.a]
        if not (last and terminal(last)) or has_break(s.a) then return nil end
        arms[#arms + 1] = { alt = al, body = s.a }
        j = j + 1
    end
    if #arms < 2 or j > #blk then return nil end
    local rest = {}
    for k = j, #blk do rest[#rest + 1] = blk[k] end
    if has_break(rest) then return nil end
    for _, s in ipairs(rest) do if s.op == 'label' then return nil end end
    local tail = rest[#rest]
    if not (tail and terminal(tail)) then return nil end
    arms[#arms + 1] = { body = rest }
    return arms, sum, subj
end

-- `slc size`: how many lines each residual statement became. A statement's own
-- lines exclude the statements nested in it, so a range of the emission stream can
-- be summed without counting a child twice; statements the rewrites dropped keep
-- no count at all, which is exactly the point of measuring the emitted C.
-- `slc size`: a statement inside a loop is a statement paid per iteration, which is
-- what makes a shared body cost at run time even when it shrinks the C
local LOOPS = { loop = true, ['for'] = true }

function Fn:block(blk)
    self.open = self.open or {}
    local i = 1
    while i <= #blk do
        local arms, sum, subj = self:block_switch(blk, i)
        if arms then
            self:emit_switch(arms, sum, subj)
            return
        end
        local s = blk[i]
        local before = self.printed or 0
        s.child_lines = 0
        if LOOPS[s.op] then self.loop_depth = (self.loop_depth or 0) + 1 end
        s.loop = (self.loop_depth or 0) > 0
        self.open[#self.open + 1] = s
        self:stmt(s)
        if LOOPS[s.op] then self.loop_depth = self.loop_depth - 1 end
        self.open[#self.open] = nil
        local delta = (self.printed or 0) - before
        s.lines = delta - s.child_lines
        local parent = self.open[#self.open]
        if parent then parent.child_lines = parent.child_lines + delta end
        i = i + 1
    end
end

function Fn:stmt(s)
    local op = s.op
    if op == 'store' or op == 'let' then
        self:assign(s.place, s.e)
    elseif op == 'expr' then
        self:line(self:expr(s.e, 0) .. ';')
    elseif op == 'ret' then
        if self.task_mode then self:line('return SLC_DONE;')
        elseif s.e then self:line('return ' .. self:expr(s.e, 0) .. ';') else self:line('return;') end
    elseif op == 'if' then
        if self:try_switch(s) then return end
        local c, a, b = s.c, s.a, s.b
        if #a == 0 then c, a, b = negate(c), b, a end
        if #b == 0 and #a == 1 and a[1].op == 'goto' and a[1].print_as then
            self:line('if (' .. self:expr(c, 0) .. ') ' .. a[1].print_as .. ';')
            return
        end
        self:line('if (' .. self:expr(c, 0) .. ') {')
        self.indent = self.indent + 1; self:block(a); self.indent = self.indent - 1
        while #b == 1 and b[1].op == 'if' and #b[1].a > 0 do
            local n = b[1]
            self:line('} else if (' .. self:expr(n.c, 0) .. ') {')
            self.indent = self.indent + 1; self:block(n.a); self.indent = self.indent - 1
            b = n.b
        end
        if #b > 0 then
            self:line('} else {')
            self.indent = self.indent + 1; self:block(b); self.indent = self.indent - 1
        end
        self:line('}')
    elseif op == 'for' then
        local iv = self:pname(s.iv)
        local t = s.T
        local lo, hi = self:expr(s.lo, 2), self:expr(s.hi, 2)
        local ut = t.signed and ('u' .. t.cname) or t.cname
        local step = s.step
        local guard, incr, stop
        if step > 0 then
            guard = lo .. ' <= ' .. hi
            incr = step == 1 and ('++' .. iv) or (iv .. ' += ' .. step)
            if step == 1 then
                stop = iv .. ' == ' .. hi
            else
                stop = '(' .. ut .. ')' .. hi .. ' - (' .. ut .. ')' .. iv .. ' < ' .. step .. 'u'
            end
        else
            guard = lo .. ' >= ' .. hi
            incr = step == -1 and ('--' .. iv) or (iv .. ' -= ' .. (-step))
            if step == -1 then
                stop = iv .. ' == ' .. hi
            else
                stop = '(' .. ut .. ')' .. iv .. ' - (' .. ut .. ')' .. hi .. ' < ' .. (-step) .. 'u'
            end
        end
        -- the limit is tested after the body, so the induction variable never
        -- steps past it: no wraparound at the edges of the type
        local always = s.lo.op == 'const' and s.hi.op == 'const'
            and ((step > 0 and s.lo.v <= s.hi.v) or (step < 0 and s.lo.v >= s.hi.v))
        -- a start at the type's minimum (or, going down, its maximum) always passes
        if not always and t.kind == 'int' then
            local lo_min, hi_max = fold.limits(t)
            if step > 0 and s.lo.op == 'const' and s.lo.v == lo_min then always = true end
            if step < 0 and s.lo.op == 'const' and s.lo.v == hi_max then always = true end
        end
        if not always then
            self:line('if (' .. guard .. ') {')
            self.indent = self.indent + 1
        end
        local init = self.task_mode and iv or decl_of(t, iv)
        self:line('for (' .. init .. ' = ' .. lo .. ';; ' .. incr .. ') {')
        self.indent = self.indent + 1
        self:block(s.body)
        if not (s.body[#s.body] and terminal(s.body[#s.body])) then
            self:line('if (' .. stop .. ') break;')
        end
        self.indent = self.indent - 1
        self:line('}')
        if not always then
            self.indent = self.indent - 1
            self:line('}')
        end
    elseif op == 'loop' then
        self:line('for (;;) {')
        self.indent = self.indent + 1
        if self.real_labels[s.top] then
            self.indent = self.indent - 1
            self:line(self:lname(s.top) .. ':;')
            self.indent = self.indent + 1
        end
        self:block(s.body)
        self.indent = self.indent - 1
        self:line('}')
    elseif op == 'break' then
        self:line('break;')
    elseif op == 'goto' then
        if s.print_as then self:line(s.print_as .. ';')
        else self:line('goto ' .. self:lname(s.label) .. ';') end
    elseif op == 'setparam' then
        self:line((self.task_mode and 'f->' or '') .. s.name .. ' = ' .. self:expr(s.e, 2) .. ';')
    elseif op == 'wait' then
        self:wait(s)
    elseif op == 'spawn' then
        self:spawn(s)
    elseif op == 'label' then
        if self.real_labels[s.label] and not self.loop_tops[s.label] then
            self.indent = self.indent - 1
            self:line(self:lname(s.label) .. ':;')
            self.indent = self.indent + 1
        end
    elseif op == 'nop' then
        return
    elseif op == 'fence' then
        self:line('__atomic_thread_fence(' .. s.order .. ');')
    elseif op == 'trap' then
        self:line('slc_trap(' .. self:expr(s.msg, 2) .. ');')
    elseif op == 'gs_reset' then
        local at = s.k == 0 and 'gs_sp' or ('gs_sp + ' .. s.k)
        local top = self.task_mode and ('f->gs_top' .. s.k) or ('gs_top' .. s.k)
        self:line('slc_gs_reset(' .. at .. ', ' .. top .. ');')
    elseif op == 'spawn' then
        self:spawn(s)
    else
        error('cgen: unknown statement ' .. tostring(op))
    end
end

-- a spawn: a zeroed frame, the copies, then the task may run
function Fn:spawn(s)
    local args = {}
    for i, a in ipairs(s.args or {}) do args[i] = self:expr(a, 2) end
    local t = s.task.alias or s.task
    local parts = { ('{ %s *slc_t = (%s *)slc_spawn(%s, sizeof(%s), %s);'):format(
        t.task_frame, t.task_frame, args[1], t.task_frame, t.task_step) }
    for i, p in ipairs(t.params) do parts[#parts + 1] = ('slc_t->%s = %s;'):format(p.name, args[i + 1]) end
    parts[#parts + 1] = 'slc_start(&slc_t->task); }'
    self:line(table.concat(parts, ' '))
end

-- a wait: in a task, suspend and resume here; in plain code, block
function Fn:wait(s)
    if s.yield then
        local k = #self.resumes + 1
        self.resumes[k] = true
        self:line('if (slc_budget(&f->task)) {')
        self:line('    f->task.state = ' .. k .. ';')
        self:line('    return SLC_YIELD;')
        self:line('}')
        self.indent = self.indent - 1
        self:line('resume' .. k .. ':;')
        self.indent = self.indent + 1
        return
    end
    -- a blocking block first: its statements become a function over the frame,
    -- and the call names it
    if s.body then
        self.blocking_n = (self.blocking_n or 0) + 1
        local name = self.step_name .. '_blocking' .. self.blocking_n
        local out, indent = self.out, self.indent
        self.out, self.indent = {}, 1
        self:block(s.body)
        self.blocking_fns[#self.blocking_fns + 1] = { name = name, lines = self.out }
        self.out, self.indent = out, indent
    end
    local args = {}
    for i, a in ipairs(s.args) do
        if a.op == 'block_fn' then
            args[i] = self.step_name .. '_blocking' .. self.blocking_n
        elseif a.op == 'block_env' then
            args[i] = 'f'
        else
            args[i] = self:expr(a, 2)
        end
    end
    local call = s.callee.cname .. '(' .. table.concat(args, ', ') .. ')'
    local used = self.reads[s.result]
    if self.task_mode then
        local k = #self.resumes + 1
        self.resumes[k] = true
        self:line('if (' .. call .. ' == SLC_PENDING) {')
        self:line('    f->task.state = ' .. k .. ';')
        self:line('    return SLC_WAIT;')
        self:line('}')
        self.indent = self.indent - 1
        self:line('resume' .. k .. ':;')
        self.indent = self.indent + 1
        if used then self:line(self:place_text(s.result, 2) .. ' = f->task.result;') end
    else
        self:line('if (' .. call .. ' == SLC_PENDING) slc_block(slc_tk);')
        if used then self:line(self:place_text(s.result, 2) .. ' = slc_tk->result;') end
    end
end

-- the places some expression reads
local function read_places(fn)
    local reads = {}
    walk_block(fn.body, nil, function(e) if e.op == 'read' and e.place then reads[root(e.place)] = true end end)
    return reads
end

-- functions ----------------------------------------------------------------------------------

-- A long string used as a byte table gets a name: `((uint8_t *)"...")[i]` at every
-- access makes lines nobody can read, and gcc merges the copies in .rodata anyway.
-- A message stays inline, however long and however often: `slc_trap("Store grew while
-- it was not at the top of its data stack")` says what happened, `slc_trap(slc_str)`
-- does not. A table is the case where the literal is cast to a pointer.
local HOIST_LENGTH = 48
local function string_table(fns, unique_name)
    local counts, order = {}, {}
    for _, fn in ipairs(fns) do
        walk_block(fn.body, nil, function(e)
            -- the bytes of a known Str are reached through a cast to a pointer
            if e.op == 'conv' and e.a and e.a.op == 'const' and e.a.T.kind == 'cstr' then
                local v = e.a.v
                if counts[v] == nil then order[#order + 1] = v end
                counts[v] = (counts[v] or 0) + 1
            end
        end)
    end
    local names = {}
    for _, v in ipairs(order) do
        if #v >= HOIST_LENGTH then names[v] = unique_name() end
    end
    return { counts = counts, names = names }
end

-- `fn.external` is set by a split build: one translation unit per function, so
-- nothing it calls may be static
local function signature(fn)
    local exported = fn.exported or fn.external
    local ps = {}
    for _, p in ipairs(fn.params) do ps[#ps + 1] = decl_of(p.T, p.name) end
    if fn.gs then table.insert(ps, 1, 'size_t gs_sp') end
    if #ps == 0 then ps[1] = 'void' end
    if fn.ret.kind == 'fn' then
        -- a function returning a function pointer: ret (*name(params))(fparams)
        local ft = fn.ret
        local fps = {}
        for i, p in ipairs(ft.params) do fps[i] = ctype(p) end
        if #fps == 0 then fps[1] = 'void' end
        return (exported and '' or 'static ') .. (ft.ret.kind == 'unit' and 'void' or ctype(ft.ret))
            .. ' (*' .. fn.cname .. '(' .. table.concat(ps, ', ') .. '))(' .. table.concat(fps, ', ') .. ')'
    end
    local ret = fn.ret.kind == 'unit' and 'void' or ctype(fn.ret)
    local head = (exported and '' or 'static ') .. ret
    if ret:sub(-1) ~= '*' then head = head .. ' ' end
    return head .. fn.cname .. '(' .. table.concat(ps, ', ') .. ')'
end
G.signature = signature

-- the places to declare, and where: at their first assignment when that is a
-- top-level statement of the function, otherwise at the top
local function plan_declarations(f, fn)
    local used, order = {}, {}
    local function note(p)
        p = root(p)
        if memory(p) or p.pk == 'iv' then return end
        if p.pk == 'param' then return end
        if not used[p] then used[p] = true; order[#order + 1] = p end
    end
    walk_block(fn.body, nil, function(e) if e.place then note(e.place) end end)
    local first_top = {}
    for _, s in ipairs(fn.body) do
        if (s.op == 'store' or s.op == 'let') and s.place == root(s.place) and not memory(s.place) then
            local p = s.place
            if first_top[p] == nil then first_top[p] = s end
        end
    end
    -- a place is declared inline only if nothing mentions it before that statement
    local seen = {}
    local function mark(e) if e.place then seen[root(e.place)] = true end end
    for _, s in ipairs(fn.body) do
        local target = (s.op == 'store' or s.op == 'let') and s.place == root(s.place) and s.place
        -- reads in the right-hand side come first
        if s.e then walk_expr(s.e, mark) end
        if target and first_top[target] == s and not seen[target] and target.T.kind ~= 'struct'
            and target.pk ~= 'iv' and not memory(target) then
            f.decl_inline[target] = 'pending'
        end
        if target then seen[target] = true end
        walk_block({ s }, nil, mark)
    end
    table.sort(order, function(a, b) return a.id < b.id end)
    for _, p in ipairs(order) do
        if not f.decl_inline[p] then f.hoisted[p] = true end
    end
    return order
end

-- data stacks: which functions take a base index, and recursion that would
-- accumulate live data-stack positions (rejected)
local function plan_stacks(fns)
    local calls = {}
    for _, fn in ipairs(fns) do
        calls[fn] = {}
        walk_block(fn.body, nil, function(e)
            if e.op == 'call' and e.fn then table.insert(calls[fn], e) end
        end)
    end
    local need = {}
    for _, fn in ipairs(fns) do need[fn] = (fn.gs_count or 0) > 0 end
    local changed = true
    while changed do
        changed = false
        for _, fn in ipairs(fns) do
            if not need[fn] then
                for _, c in ipairs(calls[fn]) do
                    if need[c.fn] then need[fn] = true; changed = true break end
                end
            end
        end
    end
    for _, fn in ipairs(fns) do
        fn.needs_gs = need[fn]
        fn.gs = need[fn] and not fn.exported and not fn.addr_taken
    end
    -- a call inside a recursive cycle must not move the base: each round would
    -- keep more data stacks live
    local function reaches(a, b, seen)
        if a == b then return true end
        seen = seen or {}
        if seen[a] then return false end
        seen[a] = true
        for _, c in ipairs(calls[a] or {}) do
            if reaches(c.fn, b, seen) then return true end
        end
        return false
    end
    for _, fn in ipairs(fns) do
        for _, c in ipairs(calls[fn]) do
            if need[c.fn] and (c.gs_off or 0) > 0 and reaches(c.fn, fn) then
                error(('%s: recursion through %s keeps %d data stack(s) live on every round; '
                    .. 'unbounded data stacks are rejected (end the resizable values before the call)'):format(
                    fn.word.loc or fn.cname, c.fn.cname, c.gs_off), 0)
            end
        end
    end
end
G.plan_stacks = plan_stacks

-- give data stacks back before every exit of a function that allocates on them
local function stack_exits(fn)
    local n = fn.gs_count or 0
    if n == 0 then return end
    local function restores()
        local out = {}
        for k = 0, n - 1 do
            out[#out + 1] = { op = 'gs_reset', k = k }
        end
        return out
    end
    local function rewrite(blk)
        local i = 1
        while i <= #blk do
            local s = blk[i]
            if s.op == 'ret' then
                local new = {}
                if s.e then
                    -- the result is computed before the space goes away
                    local tmp = S.new_place { pk = 'temp', T = fn.ret, name = 'result', id = S.uid() }
                    new[#new + 1] = { op = 'let', place = tmp, e = s.e }
                    for _, r in ipairs(restores()) do new[#new + 1] = r end
                    new[#new + 1] = { op = 'ret', e = S.read_expr(tmp) }
                else
                    for _, r in ipairs(restores()) do new[#new + 1] = r end
                    new[#new + 1] = { op = 'ret' }
                end
                table.remove(blk, i)
                for j = #new, 1, -1 do table.insert(blk, i, new[j]) end
                i = i + #new
            else
                if s.op == 'if' then rewrite(s.a); rewrite(s.b)
                elseif s.op == 'for' or s.op == 'loop' then rewrite(s.body) end
                i = i + 1
            end
        end
    end
    rewrite(fn.body)
    local last = fn.body[#fn.body]
    if not (last and terminal(last)) then
        for _, r in ipairs(restores()) do fn.body[#fn.body + 1] = r end
    end
end

local function plan_jumps(fn, f)
    f.real_labels, f.loop_tops = {}, {}
    -- labels are numbered per function, in order of appearance
    f.label_names, f.nlabels = {}, 0
    function f:lname(l)
        local n = self.label_names[l]
        if not n then self.nlabels = self.nlabels + 1; n = 'L' .. self.nlabels; self.label_names[l] = n end
        return n
    end
    local function walk(blk, loops)
        for _, s in ipairs(blk) do
            if s.op == 'goto' then
                local inner = loops[#loops]
                if inner and inner.top == s.label then s.print_as = 'continue'
                elseif inner and inner.ends and inner.ends == s.label then s.print_as = 'break'
                else s.print_as = nil; f.real_labels[s.label] = true end
            elseif s.op == 'if' then walk(s.a, loops); walk(s.b, loops)
            elseif s.op == 'loop' then
                if s.top then f.loop_tops[s.top] = true end
                loops[#loops + 1] = s
                walk(s.body, loops)
                loops[#loops] = nil
            elseif s.op == 'for' then
                loops[#loops + 1] = { op = 'for' }
                walk(s.body, loops)
                loops[#loops] = nil
            end
        end
    end
    walk(fn.body, {})
    -- a break out of a loop to its end label, where the label immediately
    -- follows the loop: the label itself is not needed
end

local function emit_function(fn, out)
    local f = setmetatable({ out = out, indent = 1, names = {}, used = {}, decl_inline = {},
                             hoisted = {}, reads = read_places(fn), strings = fn.strings }, Fn)
    f.used.slc_tk, f.used.slc_ops = true, true
    for _, p in ipairs(fn.params) do f.used[p.name] = true end
    if fn.gs then f.used.gs_sp = true end
    plan_jumps(fn, f)
    local order = plan_declarations(f, fn)
    out[#out + 1] = signature(fn) .. ' {'
    if fn.needs_gs and fn.exported then f:line('size_t gs_sp = 0;') end
    if fn.waits or fn.needs_self then
        -- plain code waits by blocking, as a party the runtime can wake
        f:line('slc_task *slc_tk = slc_self();')
    end
    if fn.waits then f:line(('slc_op slc_ops[%d];'):format(fn.waits)) end
    -- a parameter specialization made unnecessary is still part of the signature
    local used = {}
    walk_block(fn.body, nil, function(e)
        if e.op == 'param' then used[e.name] = true end
        if e.op == 'setparam' then used[e.name] = true end
    end)
    walk_block(fn.body, function(st) if st.op == 'setparam' then used[st.name] = true end end)
    for _, p in ipairs(fn.params) do
        if not used[p.name] then f:line('(void)' .. p.name .. ';') end
    end
    for k = 0, (fn.gs_count or 0) - 1 do
        f:line(('size_t gs_top%d = slc_gs_top(%s);'):format(k, k == 0 and 'gs_sp' or ('gs_sp + ' .. k)))
    end
    for _, p in ipairs(order) do
        if f.hoisted[p] then
            f:line(decl_of(p.T, f:pname(p)) .. ';')
        end
    end
    f:block(fn.body)
    -- a value-returning function that ends in a loop with no way out never
    -- reaches its end; say so for compilers that do not see it (a worker's loop)
    local last = fn.body[#fn.body]
    if fn.ret.kind ~= 'unit' and last and last.op == 'loop' then
        local leaves = false
        walk_block(last.body, function(st) if st.op == 'ret' or st.op == 'break' then leaves = true end end)
        if not leaves then f:line('__builtin_unreachable();') end
    end
    out[#out + 1] = '}'
end

-- every loop round of a task passes a yield point
local function insert_yields(blk)
    for _, s in ipairs(blk) do
        if s.op == 'if' then insert_yields(s.a); insert_yields(s.b)
        elseif s.op == 'loop' or s.op == 'for' then
            insert_yields(s.body)
            table.insert(s.body, 1, { op = 'wait', yield = true })
        end
    end
end

-- a task: its frame, and a step function that runs to the next wait
local function emit_task(fn)
    local body = {}
    local f = setmetatable({ out = body, indent = 1, names = {}, used = {}, decl_inline = {}, hoisted = {},
                             task_mode = true, fields = {}, resumes = {}, reads = read_places(fn),
                             step_name = fn.task_step, blocking_fns = {}, strings = fn.strings }, Fn)
    for _, p in ipairs(fn.params) do f.used[p.name] = true end
    f.used.f, f.used.task, f.used.ops, f.used.gs_sp = true, true, true, true
    plan_jumps(fn, f)
    plan_declarations(f, fn)
    for k = 0, (fn.gs_count or 0) - 1 do
        f.fields[#f.fields + 1] = ('size_t gs_top%d'):format(k)
        f:line(('f->gs_top%d = slc_gs_top(%s);'):format(k, k == 0 and 'gs_sp' or ('gs_sp + ' .. k)))
    end
    f:block(fn.body)
    local last = fn.body[#fn.body]
    if not (last and terminal(last)) then f:line('return SLC_DONE;') end
    local frame, step = fn.task_frame, fn.task_step
    local out = { 'typedef struct ' .. frame .. ' {', '    slc_task task;' }
    if fn.waits then out[#out + 1] = ('    slc_op ops[%d];'):format(fn.waits) end
    for _, p in ipairs(fn.params) do out[#out + 1] = '    ' .. decl_of(p.T, p.name) .. ';' end
    for _, d in ipairs(f.fields) do out[#out + 1] = '    ' .. d .. ';' end
    out[#out + 1] = '} ' .. frame .. ';'
    local typedef = table.concat(out, '\n')
    out = {}
    for _, bf in ipairs(f.blocking_fns) do
        out[#out + 1] = 'static void ' .. bf.name .. '(void *slc_frame) {'
        out[#out + 1] = '    ' .. frame .. ' *f = (' .. frame .. ' *)slc_frame;'
        if fn.needs_gs then
            out[#out + 1] = '    size_t gs_sp = 0;'
            out[#out + 1] = '    (void)gs_sp;'
        end
        for _, l in ipairs(bf.lines) do out[#out + 1] = l end
        out[#out + 1] = '}'
        out[#out + 1] = ''
    end
    out[#out + 1] = (fn.external and '' or 'static ') .. 'slc_step ' .. step .. '(slc_task *slc_task_) {'
    out[#out + 1] = '    ' .. frame .. ' *f = (' .. frame .. ' *)slc_task_;'
    if fn.needs_gs then
        out[#out + 1] = '    size_t gs_sp = 0;'
        out[#out + 1] = '    (void)gs_sp;'
    end
    if #f.resumes > 0 then
        local cases = {}
        for k = 1, #f.resumes do cases[k] = ('case %d: goto resume%d;'):format(k, k) end
        out[#out + 1] = '    switch (f->task.state) {'
        for _, c in ipairs(cases) do out[#out + 1] = '    ' .. c end
        out[#out + 1] = '    default: break;'
        out[#out + 1] = '    }'
    end
    for _, l in ipairs(body) do out[#out + 1] = l end
    out[#out + 1] = '}'
    return typedef, table.concat(out, '\n')
end

-- the call graph from the exports: only what is reachable is emitted
local function reachable(mod)
    local seen, order = {}, {}
    local visit
    local touched = false          -- the program calls into the runtime at all
    -- a name in the program (a runtime call) reaches the runtime word of that name
    local function named(name)
        if name and name:sub(1, 4) == 'slc_' then touched = true end
        local lf = name and mod.resolve and mod.resolve(name)
        if lf then visit(lf) end
    end
    function visit(fn)
        if seen[fn] then return end
        seen[fn] = true
        -- `slc size`: only these functions reach the C, so only their copies count
        fn.emitted = true
        walk_block(fn.body, function(st)
            if st.task then visit(st.task) end
            if st.op == 'wait' and st.callee then named(st.callee.cname) end
            if st.op == 'trap' then touched = true end
        end, function(e)
            if (e.op == 'call' or e.op == 'fnaddr') and e.fn then visit(e.fn) end
            if e.op == 'call' and e.ext then named(e.ext.cname) end
            if e.op == 'rtcall' then named(e.cname) end
            if e.op == 'slot_at' then named('slc_slot_fault') end
        end)
        order[#order + 1] = fn
    end
    for _, fn in ipairs(mod.exports) do visit(fn) end
    if mod.resolve then
        -- what the generated code itself calls: stack bookkeeping, tasks, plain waits, I/O
        local function needs(pred)
            for fn in pairs(seen) do
                if pred(fn) then return true end
            end
            return false
        end
        local spawns, waits = false, false
        for fn in pairs(seen) do
            walk_block(fn.body, function(st)
                if st.op == 'spawn' then spawns = true end
                if st.op == 'wait' then waits = true end
            end)
        end
        if needs(function(fn) return (fn.gs_count or 0) > 0 end) then
            named('slc_gs_top'); named('slc_gs_reset')
        end
        -- runtime/slc_rt.c is linked as soon as anything is called, and it calls these
        for _, name in ipairs(mod.runtime_keep or {}) do named(name) end
        if touched or spawns or waits then
            for _, name in ipairs(mod.runtime_roots or {}) do named(name) end
        end
        if spawns or needs(function(fn) return fn.task end) then named('slc_spawn'); named('slc_start') end
        if waits or needs(function(fn) return fn.needs_self end) then named('slc_self'); named('slc_block') end
    end
    return order, seen
end
G.reachable = reachable

-- struct definitions in dependency order
local function collect_structs(fns)
    local seen, order = {}, {}
    local function visit(t)
        if not t or seen[t] then return end
        if t.kind == 'ref' or t.kind == 'ptr' or t.kind == 'id' or t.kind == 'store'
            or t.kind == 'grow' or t.kind == 'map' or t.kind == 'strmap' then
            if t.kind ~= 'ref' and t.kind ~= 'ptr' then
                seen[t] = true
                local native = t.native_layout and t.native_layout() or t.representation
                if native then visit(native) end
                if t.elem then visit(t.elem) end
                if t.kind == 'map' or t.kind == 'strmap' then visit(t.key); visit(t.lookup); visit(t.entry) end
                if t.kind == 'store' then visit(require('slc.memory').Id(t.elem)) end
                order[#order + 1] = t
                return
            end
            return visit(t.elem)
        end
        if t.kind == 'sum' then
            seen[t] = true
            for _, a in ipairs(t.alts) do visit(a.type) end
            order[#order + 1] = t
            return
        end
        if t.kind == 'array' then
            seen[t] = true
            visit(t.elem)
            order[#order + 1] = t
            return
        end
        if t.kind ~= 'struct' then return end
        seen[t] = true
        for _, f in ipairs(t.fields) do visit(f.type) end
        order[#order + 1] = t
    end
    for _, fn in ipairs(fns) do
        visit(fn.ret)
        for _, p in ipairs(fn.params) do visit(p.T) end
        walk_block(fn.body, nil, function(e)
            if e.T then visit(e.T) end
            if e.sizeof then visit(e.sizeof) end
            if e.place then visit(root(e.place).T); visit(e.place.T) end
        end)
    end
    return order
end
G.collect_structs = collect_structs

-- the C definition of a native global
-- mode: nil for the single-file definition, 'external' for a split build's
-- definition (no static), 'extern' for the declaration its header carries
function G.global_decl(g, mode)
    local name = S.global_cname(g)
    local link = (mode == 'extern') and 'extern '
        or ((mode == 'external' or g.exported) and '' or 'static ')
    local text = link .. (g.tls and '__thread ' or '') .. decl_of(g.T, name)
    if g.init ~= nil and mode ~= 'extern' then text = text .. ' = ' .. fold.c_literal(g.T, g.init) end
    return text .. ';'
end

-- the residual program as every backend sees it: reachable functions, cleaned
-- up, with data stacks planned, given back at every exit, and a yield point in
-- every loop round of a task. Done once per module, whichever backends run.
function G.prepare(mod)
    local fns = reachable(mod)
    if mod.prepared and #fns == mod.prepared_n then return fns end
    -- A parameter hides a function of the same name in C. A function nobody
    -- exports can be renamed, so no parameter ever hides one its function calls.
    for _, fn in ipairs(fns) do
        local params = {}
        for _, p in ipairs(fn.params) do params[p.name] = true end
        walk_block(fn.body, nil, function(e)
            local target = (e.op == 'call' or e.op == 'fnaddr') and e.fn
            if target and not target.exported and params[target.cname] then
                local name = target.cname .. '_fn'
                local n = 1
                while mod.names[name] do n = n + 1; name = target.cname .. '_fn' .. n end
                mod.names[name] = true
                target.cname = name
            end
        end)
    end
    -- cleanup first: it can only remove uses
    for _, fn in ipairs(fns) do G.cleanup(fn) end
    plan_stacks(fns)
    for _, fn in ipairs(fns) do
        if not fn.prepared then
            fn.prepared = true
            if fn.task then insert_yields(fn.body) end
            stack_exits(fn)
        end
    end
    mod.prepared, mod.prepared_n = true, #fns
    return fns
end

-- The C of a module in the pieces a split build needs, in emission order.
-- `G.emit` joins them into one translation unit; `G.emit_split` writes one file
-- per function beside a shared header, so a C compiler can work in parallel.
-- Both modes come through here, so they cannot disagree about the program.
local function module_parts(mod, opts)
    opts = opts or {}
    local fns = G.prepare(mod)
    if opts.split then for _, fn in ipairs(fns) do fn.external = true end end
    local p = { banner = {}, macros = {}, includes = {}, types = {}, types_task = {},
                strings = {}, externs = {}, globals = {}, protos = {}, functions = {},
                steps = {}, fns = fns }
    local function add(name, text) local t = p[name]; t[#t + 1] = text end
    add('banner', '/* Generated by slc (staged Lua -> C). Do not edit. */')
    -- the runtime words use POSIX: feature selection comes before every system header
    if mod.resolve then
        add('macros', '#define _POSIX_C_SOURCE 200809L')
        add('macros', '#define _DEFAULT_SOURCE 1')
    end
    add('includes', '#include <stdint.h>')
    add('includes', '#include <stdbool.h>')
    add('includes', '#include <stddef.h>')
    local need_math, need_rt = false, false
    for _, fn in ipairs(fns) do
        walk_block(fn.body, nil, function(e)
            if e.op == 'const' and e.T.kind == 'float' and (e.v ~= e.v or e.v == math.huge or e.v == -math.huge) then
                need_math = true
            end
        end)
        if fn.needs_gs or fn.uses_rt then need_rt = true end
        for _, p_ in ipairs(fn.params) do
            if p_.T.kind == 'chan' or p_.T.kind == 'group' or p_.T.kind == 'pool' or p_.T.kind == 'slot' then need_rt = true end
        end
        walk_block(fn.body, function(st) if st.task then need_rt = true end end, function(e)
            if e.T and (e.T.kind == 'chan' or e.T.kind == 'group') then need_rt = true end
        end)
    end
    -- tasks: frames and step functions; tasks that print the same share one
    local tasks, task_text, by_text = {}, {}, {}
    for _, fn in ipairs(fns) do
        if fn.task then
            fn.task_frame = S.unique_global(fn.cname .. '_frame')
            fn.task_step = S.unique_global(fn.cname .. '_step')
            local typedef, step = emit_task(fn)
            local norm = (typedef .. step):gsub(fn.task_frame, '@F'):gsub(fn.task_step, '@S')
            if by_text[norm] then
                fn.alias = by_text[norm]
            else
                by_text[norm] = fn
                tasks[#tasks + 1] = fn
                task_text[fn] = { typedef, step }
            end
        end
    end
    if need_math then add('includes', '#include <math.h>') end
    -- Headers of every foreign call the residual program makes, including calls
    -- in words inlined from a library module: their declarations belong here too.
    local headers, externs = {}, {}
    for _, x in ipairs(mod.externs) do externs[#externs + 1] = x end
    for _, fn in ipairs(fns) do
        walk_block(fn.body, nil, function(e)
            if e.op == 'call' and e.ext and e.ext.header and not externs[e.ext] then
                externs[e.ext] = true
                externs[#externs + 1] = e.ext
            end
            -- an imported global brings the header that declares it
            if e.op == 'gaddr' and e.global.imported and e.global.header and not externs[e.global] then
                externs[e.global] = true
                externs[#externs + 1] = e.global
            end
        end)
    end
    -- Which externs the module recorded depends on which library words were
    -- already specialized in this process, so the header order is canonical.
    local names = {}
    for _, x in ipairs(externs) do
        if x.header and not headers[x.header] then
            headers[x.header] = true
            names[#names + 1] = x.header
        end
    end
    table.sort(names)
    for _, header in ipairs(names) do add('includes', '#include ' .. header) end
    if need_rt then add('includes', '#include "slc_rt.h"') end
    add('includes', '')

    -- types
    for _, t in ipairs(collect_structs(fns)) do
        if t.kind == 'struct' and rawget(t, 'foreign') then
            -- its layout comes from its header
        elseif t.kind == 'struct' then
            add('types', 'typedef struct ' .. ctype(t) .. ' {')
            for _, f in ipairs(t.fields) do add('types', '    ' .. decl_of(f.type, f.name) .. ';') end
            add('types', '} ' .. ctype(t) .. ';')
            add('types', '')
        elseif t.kind == 'sum' then
            local name = ctype(t)
            local tags = {}
            for _, a in ipairs(t.alts) do tags[#tags + 1] = name .. '_' .. a.name .. ' = ' .. a.tag end
            add('types', 'enum { ' .. table.concat(tags, ', ') .. ' };')
            add('types', 'typedef struct ' .. name .. ' {')
            add('types', '    uint32_t tag;')
            local members = {}
            for _, a in ipairs(t.alts) do
                if a.type.kind ~= 'unit' then members[#members + 1] = '        ' .. decl_of(a.type, a.name) .. ';' end
            end
            if #members > 0 then
                add('types', '    union {')
                for _, m in ipairs(members) do add('types', m) end
                add('types', '    } as;')
            end
            add('types', '} ' .. name .. ';')
            add('types', '')
        elseif t.kind == 'array' then
            add('types', ('typedef struct %s { %s; } %s;'):format(ctype(t),
                decl_of(t.elem, ('e[%d]'):format(t.length)), ctype(t)))
            add('types', '')
        elseif t.cdecl then
            local d = t.cdecl()
            if d then add('types', d); add('types', '') end
        end
    end

    for _, t in ipairs(tasks) do
        add('types_task', task_text[t][1])
        add('types_task', '')
    end

    -- foreign prototypes without a header
    local protos = false
    for _, x in ipairs(mod.externs) do
        if not x.header then
            local used = false
            for _, fn in ipairs(fns) do
                walk_block(fn.body, nil, function(e) if e.op == 'call' and e.ext == x then used = true end end)
            end
            if used then
                local ps = {}
                for i, t in ipairs(x.params) do ps[i] = ctype(t) end
                if #ps == 0 then ps[1] = 'void' end
                local ret = x.ret.kind == 'unit' and 'void' or ctype(x.ret)
                add('externs', 'extern ' .. ret .. ' ' .. x.cname .. '(' .. table.concat(ps, ', ') .. ');')
                protos = true
            end
        end
    end
    if protos then add('externs', '') end

    -- native globals (static storage), in first-use order
    local globals, seen_globals = {}, {}
    for _, fn in ipairs(fns) do
        walk_block(fn.body, nil, function(e)
            if e.op == 'gaddr' and not seen_globals[e.global] then
                seen_globals[e.global] = true
                globals[#globals + 1] = e.global
            end
        end)
    end
    local defined = 0
    for _, g in ipairs(globals) do
        if not g.imported then
            add('globals', G.global_decl(g))
            defined = defined + 1
        end
    end
    p.defined_globals = globals
    if defined > 0 then add('globals', '') end

    -- prototypes for internal functions (recursion, any order)
    local any_static = false
    for _, fn in ipairs(fns) do
        if not fn.exported and not fn.task then
            add('protos', signature(fn) .. ';')
            any_static = true
        end
    end
    for _, t in ipairs(tasks) do
        add('protos', 'static slc_step ' .. t.task_step .. '(slc_task *slc_task_);')
        any_static = true
    end
    if any_static then add('protos', '') end

    -- the long or repeated literals, in first-use order
    local tables = string_table(fns, function() return S.unique_global('slc_str') end)
    for _, fn in ipairs(fns) do fn.strings = tables end
    local seen = {}
    for _, fn in ipairs(fns) do
        walk_block(fn.body, nil, function(e)
            if e.op == 'const' and e.T.kind == 'cstr' and tables.names[e.v] and not seen[e.v] then
                seen[e.v] = true
                p.strings[#p.strings + 1] = { name = tables.names[e.v], value = e.v }
            end
        end)
    end
    p.string_names = tables.names

    local plain = {}
    for _, fn in ipairs(fns) do if not fn.task then plain[#plain + 1] = fn end end
    for _, fn in ipairs(plain) do
        local out = {}
        emit_function(fn, out)
        p.functions[#p.functions + 1] = { name = fn.cname, fn = fn, text = table.concat(out, '\n') }
    end
    for _, t in ipairs(tasks) do
        p.steps[#p.steps + 1] = { name = t.task_step, fn = t, text = task_text[t][2] }
    end
    p.tasks = tasks
    return p
end
G.module_parts = module_parts

function G.emit(mod, opts)
    local p = module_parts(mod, opts)
    local out = {}
    local function push(section)
        for _, line in ipairs(p[section]) do out[#out + 1] = line end
    end
    push 'banner'
    push 'macros'
    push 'includes'
    push 'types'
    push 'types_task'
    for _, c in ipairs(p.strings) do
        out[#out + 1] = ('static const char %s[] = %s;'):format(c.name, fold.c_literal({ kind = 'cstr' }, c.value))
    end
    if #p.strings > 0 then out[#out + 1] = '' end
    push 'externs'
    push 'globals'
    push 'protos'
    for i, u in ipairs(p.functions) do
        out[#out + 1] = u.text
        if i < #p.functions then out[#out + 1] = '' end
    end
    for _, u in ipairs(p.steps) do
        out[#out + 1] = ''
        out[#out + 1] = u.text
    end
    return table.concat(out, '\n') .. '\n'
end

-- one translation unit per function beside one shared header, so a C compiler
-- can build them in parallel (`cc -c *.c` with -j). Every function becomes
-- external: nothing is inlined across a translation unit boundary unless the
-- C compiler is given -flto.
function G.emit_split(mod, opts)
    opts = opts or {}
    opts.split = true
    local p = module_parts(mod, opts)
    local header = opts.header or 'program.h'
    local out, files = {}, {}
    local function say(...) out[#out + 1] = string.format(...) end
    local function push(section)
        for _, line in ipairs(p[section]) do out[#out + 1] = line end
    end
    push 'banner'
    say('#pragma once')
    push 'includes'
    push 'types'
    push 'types_task'
    push 'externs'
    -- the definitions live in one file, so the header declares them
    local declared = false
    for _, g in ipairs(p.defined_globals or {}) do
        if not g.imported then
            say('%s', G.global_decl(g, 'extern'))
            declared = true
        end
    end
    for _, c in ipairs(p.strings) do
        say('extern const char %s[];', c.name)
        declared = true
    end
    if declared then say('') end
    for _, u in ipairs(p.functions) do say('%s;', signature(u.fn)) end
    for _, t in ipairs(p.tasks) do say('slc_step %s(slc_task *slc_task_);', t.task_step) end
    say('')
    files[#files + 1] = { name = header, text = table.concat(out, '\n') .. '\n' }

    local head = { '/* Generated by slc (staged Lua -> C). Do not edit. */' }
    for _, line in ipairs(p.macros) do head[#head + 1] = line end
    head[#head + 1] = ('#include "%s"'):format(header:match('[^/]*$'))
    local prefix = table.concat(head, '\n') .. '\n\n'
    local globals = {}
    for _, g in ipairs(p.defined_globals or {}) do
        if not g.imported then globals[#globals + 1] = G.global_decl(g, 'external') end
    end
    for _, c in ipairs(p.strings) do
        globals[#globals + 1] = ('const char %s[] = %s;'):format(c.name,
            fold.c_literal({ kind = 'cstr' }, c.value))
    end
    if #globals > 0 then
        files[#files + 1] = { name = 'globals.c', text = prefix .. table.concat(globals, '\n') .. '\n' }
    end
    for _, u in ipairs(p.functions) do
        files[#files + 1] = { name = u.name .. '.c', text = prefix .. u.text .. '\n' }
    end
    for _, u in ipairs(p.steps) do
        files[#files + 1] = { name = u.name .. '.c', text = prefix .. u.text .. '\n' }
    end
    return files
end

-- a header with the exported prototypes
function G.header(mod, guard)
    local fns = reachable(mod)
    local out = { '/* Generated by slc. */', '#pragma once', '#include <stdint.h>',
                  '#include <stdbool.h>', '#include <stddef.h>' }
    for _, fn in ipairs(mod.exports) do out[#out + 1] = signature(fn) .. ';' end
    return table.concat(out, '\n') .. '\n'
end

return G
