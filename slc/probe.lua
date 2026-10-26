-- slc.probe: what only a C header knows.
--
-- libgccjit reads no headers. The C backend never needs to know a header's
-- values (the C compiler reads the header); the gccjit backend asks once: a
-- generated C file prints the platform values a module uses (constants,
-- foreign struct layouts) and defines getters for C variables it reads
-- (errno). It is compiled with the system C compiler, run, and cached by its
-- text, so a module costs one compilation the first time and nothing after.

local G = require 'slc.cgen'
local C = require 'slc.cjit'

local P = {}

local function fnv(s)
    local h = 2166136261
    for i = 1, #s do
        h = bit.bxor(h, s:byte(i))
        h = bit.band(h * 16777619, 0xffffffff)
    end
    return bit.tohex(h) .. ('%x'):format(#s)
end

local function cache_dir()
    local d = os.getenv('SLC_CACHE')
    if not d then
        local xdg = os.getenv('XDG_CACHE_HOME')
        d = (xdg or ((os.getenv('HOME') or '/tmp') .. '/.cache')) .. '/slc'
    end
    os.execute(('mkdir -p %q'):format(d))
    return d
end

local function exists(path)
    local f = io.open(path)
    if f then f:close() return true end
    return false
end

local function read_text(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local t = f:read '*a'
    f:close()
    return t
end

-- The C library the answers describe. Dist time records it; a run that sees a
-- different one probes instead of trusting the embedded tables.
local function libc_identity()
    local ok, ffi = pcall(require, 'ffi')
    if not ok then return 'unknown' end
    pcall(ffi.cdef, 'const char *gnu_get_libc_version(void);')
    local fine, v = pcall(function() return ffi.C.gnu_get_libc_version() end)
    if fine and v then return 'glibc ' .. ffi.string(v) end
    return 'unknown'
end
P.libc_identity = libc_identity

-- Tables computed at dist time ([tools/tables.lua](../tools/tables.lua)) and
-- embedded: a request they cover never starts the compiler.
local tables_loaded, tables
local function embedded_tables()
    if tables_loaded then return tables end
    tables_loaded = true
    local provider = rawget(_G, '__slc_embedded_source')
    local text = provider and provider('runtime/header_tables.lua')
    if not text then return nil end
    local chunk = loadstring(text, '@runtime/header_tables.lua')
    if not chunk then return nil end
    tables = chunk()
    return tables
end

-- recording: the answers a dist-time run saw, keyed like the probe cache
local function record(key, text)
    local path = os.getenv('SLC_PROBE_RECORD')
    if not path or not text then return end
    local f = io.open(path, 'ab')
    if not f then return end
    f:write(key, '\0', text, '\0')
    f:close()
end

local function run(cmd)
    local p = io.popen('(' .. cmd .. ') 2>&1; echo "__rc=$?"')
    local out = p:read '*a'
    p:close()
    local rc = tonumber(out:match('__rc=(%d+)%s*$'))
    return rc == 0, (out:gsub('__rc=%d+%s*$', ''))
end

local function root(p)
    local q = rawget(p, 'parent')
    while q do p = q; q = rawget(p, 'parent') end
    return p
end

-- what a module asks of its headers
local function requests(mod, fns, structs)
    local consts, cnames, vars, vnames, layouts = {}, {}, {}, {}, {}
    local headers, hlist = {}, {}
    for _, x in ipairs(mod.externs) do
        if x.header and not headers[x.header] then headers[x.header] = true; hlist[#hlist + 1] = x.header end
    end
    for _, fn in ipairs(fns) do
        G.walk_block(fn.body, nil, function(e)
            if e.op == 'cconst' and not consts[e.cconst] then
                consts[e.cconst] = e.T
                cnames[#cnames + 1] = e.cconst
            elseif e.op == 'call' and e.ext and e.ext.variable and not vars[e.ext.cname] then
                vars[e.ext.cname] = e.ext
                vnames[#vnames + 1] = e.ext.cname
            end
        end)
    end
    table.sort(cnames)
    table.sort(vnames)
    for _, t in ipairs(structs) do
        if t.kind == 'struct' and rawget(t, 'foreign') then layouts[#layouts + 1] = t end
    end
    return { consts = consts, cnames = cnames, vars = vars, vnames = vnames, layouts = layouts, headers = hlist }
end

local function getter_name(name) return 'slc_probe_' .. name:gsub('[^%w_]', '_') end
P.getter_name = getter_name

-- the probe's C text
local function source(rq)
    local out = { '/* slc header probe: generated */', '#include <stdio.h>', '#include <stddef.h>',
                  '#include <stdint.h>', '#include <stdbool.h>' }
    for _, h in ipairs(rq.headers) do out[#out + 1] = '#include ' .. h end
    -- Getters can reference application globals that do not exist in the
    -- standalone layout probe. Resolve them only in the final object/shared unit.
    out[#out + 1] = '#ifndef SLC_PROBE_MAIN'
    for _, n in ipairs(rq.vnames) do
        local x = rq.vars[n]
        out[#out + 1] = ('%s %s(void) { return (%s)(%s); }'):format(G.ctype(x.ret), getter_name(n), G.ctype(x.ret), n)
    end
    out[#out + 1] = '#endif'
    out[#out + 1] = '#ifdef SLC_PROBE_MAIN'
    out[#out + 1] = 'int main(void) {'
    out[#out + 1] = '    printf("return { c = {\\n");'
    for _, n in ipairs(rq.cnames) do
        local t = rq.consts[n]
        if t.kind == 'float' then
            out[#out + 1] = ('    printf("[\\"%s\\"] = %%.17g,\\n", (double)(%s));'):format(n, n)
        elseif t.kind == 'ptr' then
            out[#out + 1] = ('    printf("[\\"%s\\"] = %%lldLL,\\n", (long long)(intptr_t)(%s));'):format(n, n)
        elseif t.kind == 'int' and not t.signed then
            out[#out + 1] = ('    printf("[\\"%s\\"] = %%lluULL,\\n", (unsigned long long)(%s));'):format(n, n)
        else
            out[#out + 1] = ('    printf("[\\"%s\\"] = %%lldLL,\\n", (long long)(%s));'):format(n, n)
        end
    end
    out[#out + 1] = '    printf("}, s = {\\n");'
    for _, t in ipairs(rq.layouts) do
        local cn = rawget(t, 'cname')
        local paths = rawget(t, 'cpath') or {}
        out[#out + 1] = ('    printf("[\\"%s\\"] = { size = %%zu, offsets = {\\n", sizeof(%s));'):format(cn, cn)
        for _, f in ipairs(t.fields) do
            local path = paths[f.name] or f.name
            out[#out + 1] = ('    printf("[\\"%s\\"] = %%zu, ", offsetof(%s, %s));'):format(f.name, cn, path)
            out[#out + 1] = ('    printf("[\\"%s\\"] = %%zu,\\n", sizeof(((%s *)0)->%s));'):format(f.name .. '#size', cn, path)
        end
        out[#out + 1] = '    printf("} },\\n");'
    end
    out[#out + 1] = '    printf("} }\\n");'
    out[#out + 1] = '    return 0;'
    out[#out + 1] = '}'
    out[#out + 1] = '#endif'
    return table.concat(out, '\n') .. '\n'
end

-- run (or recall) the probe for a module: values, layouts, and getter objects
function P.run(mod, fns, structs, includes)
    local rq = requests(mod, fns, structs)
    if #rq.cnames == 0 and #rq.vnames == 0 and #rq.layouts == 0 then
        return { c = {}, s = {}, getters = {}, types = {} }
    end
    local src = source(rq)
    local flags = ''
    for _, d in ipairs(includes or {}) do flags = flags .. ' -I' .. d end
    local norm = flags:gsub('%-I[^ ]*runtime/?', '-I<runtime>')
    local dir = cache_dir()
    local key = fnv(norm .. '\n' .. src)
    local base = dir .. '/probe-' .. key
    local lua = base .. '.lua'
    if #rq.vnames == 0 then
        local tab = embedded_tables()
        if tab and tab._identity == libc_identity() and tab[key] then
            local chunk = loadstring(tab[key], '@probe-' .. key)
            if chunk then
                local r = chunk()
                r.getters, r.types = {}, rq.consts
                return r
            end
        end
    end
    if not exists(lua) then
        local f = assert(io.open(base .. '.c', 'w'))
        f:write(src)
        f:close()
        local cc = os.getenv('CC') or 'cc'
        local ok, out = run(('%s%s -DSLC_PROBE_MAIN -o %s.bin %s.c && %s.bin > %s.tmp && mv %s.tmp %s'):format(
            cc, flags, base, base, base, base, base, lua))
        if not ok then C.fail('the header probe failed:\n' .. out) end
        if #rq.vnames > 0 then
            ok, out = run(('%s%s -O2 -fPIC -c -o %s.o %s.c && %s -shared -o %s.so %s.o'):format(cc, flags, base, base, cc,
                base, base))
            if not ok then C.fail('the header probe getters failed:\n' .. out) end
        end
    end
    local r = dofile(lua)
    if #rq.vnames == 0 then record(key, read_text(lua)) end
    r.types = rq.consts
    r.getters = {}
    if #rq.vnames > 0 then
        r.object, r.shared = base .. '.o', base .. '.so'
        for _, n in ipairs(rq.vnames) do r.getters[n] = getter_name(n) end
    end
    return r
end

-- a foreign struct's layout
function P.layout(u, t)
    local cn = rawget(t, 'cname')
    local l = u.probe.s[cn]
    if not l then C.fail('no layout probed for ' .. cn) end
    return l
end

-- a header constant's value
function P.constant(u, name)
    local v = u.probe.c[name]
    if v == nil then return nil end
    local t = u:ct(u.probe.types[name])
    if t.k == 'ptr' then
        return u.ctx:conv(u.ctx:int_const(C.int(8, true), v), t)
    end
    return u.ctx:int_const(t, v)
end

-- a C variable read: a call to its probe getter
function P.read_variable(f, x)
    local u = f.u
    local g = u.probe.getters[x.cname]
    if not g then C.fail('no getter probed for ' .. x.cname) end
    local d = u.getter_fns[x.cname]
    if not d then
        d = C.fn(g, C.fntype(u:ct(x.ret), {}, false), 'imported')
        u.getter_fns[x.cname] = d
    end
    return f.ctx:call({ fn = d }, {})
end

return P
