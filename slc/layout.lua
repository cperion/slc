-- slc.layout: storage required by a whole residual program.
-- Source types are shared by specializations/modules; never edit their fields.
local types = require 'slc.types'
local L = {}

function L.analyze(fns, walk_block)
    local seen, fixed, used = {}, {}, {}
    local visit, pin
    local function children(t, f)
        if t.elem then f(t.elem) end
        if t.ret then f(t.ret) end
        for _, p in ipairs(t.params or {}) do f(p) end
        for _, field in ipairs(t.fields or {}) do f(field.type) end
        for _, alt in ipairs(t.alts or {}) do f(alt.type) end
        local native = t.native_layout and t.native_layout() or t.representation
        if native and native ~= t then f(native) end
        if t.key then f(t.key) end
        if t.entry then f(t.entry) end
    end
    function pin(t)
        if not t or fixed[t] then return end
        fixed[t] = true
        children(t, pin)
    end
    function visit(t)
        if not t or seen[t] then return end
        seen[t] = true
        -- No alias/byte-provenance proof is attempted here. Even an internal
        -- pointer can be converted to bytes or handed to opaque native code.
        if t.kind == 'ptr' or t.kind == 'ref' or t.kind == 'fn'
            or rawget(t, 'foreign') or t.native_layout or t.representation then pin(t) end
        children(t, visit)
    end
    local function field(t, name)
        visit(t)
        -- Sum payload/array wrapper projections are not source record fields;
        -- the synthetic `as` projection of a sum has no source type at all.
        if not t or t.kind ~= 'struct' then return end
        used[t] = used[t] or {}
        used[t][name] = true
    end
    local function place(p)
        while p do
            visit(p.T)
            local parent = rawget(p, 'parent')
            if p.pk == 'field' and parent then field(parent.T, p.fname) end
            p = parent
        end
    end
    local function signature(fn)
        pin(fn.ret)
        for _, p in ipairs(fn.params or {}) do pin(p.T or p) end
    end
    for _, fn in ipairs(fns) do
        visit(fn.ret)
        for _, p in ipairs(fn.params) do visit(p.T) end
        if fn.exported or fn.addr_taken then signature(fn) end
        walk_block(fn.body, function(s)
            -- A whole-record store writes every field, including zero/constant
            -- initializers. Retain it rather than discard effects or writes.
            if s.place then pin(s.place.T) end
            if s.result then place(s.result); pin(s.result.T) end
            if s.callee then signature(s.callee) end
        end, function(e)
            visit(e.T)
            if e.place then
                place(e.place)
                if e.op == 'addr' then
                    local p = e.place
                    while rawget(p, 'parent') do p = rawget(p, 'parent') end
                    pin(p.T)
                end
            end
            if e.op == 'field' then field(e.a.T, e.name) end
            -- All real aggregate expressions observe/construct the whole value.
            -- The walker's synthetic `place` is only a field-store destination.
            if e.op ~= 'place' then pin(e.T) end
            if e.sizeof then visit(e.sizeof); pin(e.sizeof) end
            if e.global then visit(e.global.T); pin(e.global.T) end
            if e.ext then signature(e.ext) end
            if e.op == 'fnaddr' then signature(e.fn) end
        end)
    end
    local layouts = {}
    for t in pairs(seen) do
        if t.kind == 'struct' and not fixed[t] then
            local fields = {}
            for _, f in ipairs(t.fields) do
                if used[t] and used[t][f.name] then fields[#fields + 1] = f end
            end
            if #fields < #t.fields then
                -- C99 has no empty records. This byte has no source-level name.
                if #fields == 0 then fields[1] = { name = 'slc_empty', type = types.U8 } end
                layouts[t] = fields
            end
        end
    end
    return layouts
end

function L.fields(mod, t)
    return (mod.storage_layouts and mod.storage_layouts[t]) or t.fields
end

return L
