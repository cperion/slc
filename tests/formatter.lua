-- Formatter contract: comments, application boundaries, idempotence, no execution.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
local fmt = require 'slc.fmt'
local lexer = require 'macro.lexer'
local passed = 0
local function check(name, condition, detail)
    assert(condition, name .. (detail and ('\n' .. detail) or ''))
    passed = passed + 1
end
local function read(path)
    local f = assert(io.open(path, 'rb')); local text = f:read('*a'); f:close(); return text
end
local function write(path, text)
    local f = assert(io.open(path, 'wb')); assert(f:write(text)); assert(f:close())
end
local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function capture(command)
    local p = assert(io.popen(command .. ' 2>&1; printf "\\n__STATUS__%d\\n" "$?"'))
    local text = p:read('*a'); p:close()
    local out, rc = text:match('^(.*)\n__STATUS__(%d+)\n$')
    assert(rc, text); return out, tonumber(rc)
end
local function formatted(name, input, expected, options)
    local out = fmt.format(input, options, name)
    check(name, out == expected, out)
    check(name .. ' idempotent', fmt.format(out, options, name) == out)
end
formatted('golden', read(root .. '/tests/formatter/input.slc'), read(root .. '/tests/formatter/expected.slc'))
formatted('minimal unary', 'local r=Ref(h)', 'local r = Ref h\n')
formatted('minimal chain', 'local r=f(a)(b)', 'local r = f a b\n')
formatted('multiple arguments stay one call', 'local r=f(a,b)', 'local r = f(a, b)\n')
formatted('expression grouping', 'local r=f(a+b)', 'local r = f(a + b)\n')
formatted('result suffix', 'local r=f(x).value', 'local r = f(x).value\n')
formatted('nil argument', 'local r=f(nil)', 'local r = f(nil)\n')
formatted('empty call', 'local r=f()', 'local r = f()\n')
formatted('preserve calls', 'local r=Ref(h)', 'local r = Ref(h)\n', { call_style = 'preserve' })
formatted('type repeated by its constructor', [[local f = do(n: U32): U32
    local p: P = P { x = n }
    local a: U32 = U32(0)
    local g: Grow U32 = (Grow U32) {}
    return a
end
]], [[local f = do(n: U32): U32
    local p = P { x = n }
    local a = U32 0
    local g = (Grow U32) {}
    return a
end
]])
formatted('annotations that select a type stay', [[local f = do(n: U32): U32
    local k: U64 = U64(n) + 1
    local i: U32 = n
    local z: U32 = 0
    local q: U8 = U32 0
    return i
end
]], [[local f = do(n: U32): U32
    local k: U64 = U64 n + 1
    local i = n
    local z: U32 = 0
    local q: U8 = U32 0
    return i
end
]])
formatted('type repeated by a name of that type', [[local f = do(n: U32, r: Ref U32, s: Str): U32
    local i: U32 = n
    local j: U32 = r
    local t: Str = s
    local k: U32 = i
    for m: U32 = 1, n do
        local q: U32 = m
    end
    local w: U64 = n
    return i + k
end
]], [[local f = do(n: U32, r: Ref U32, s: Str): U32
    local i = n
    local j: U32 = r
    local t: Str = s
    local k = i
    for m: U32 = 1, n do
        local q = m
    end
    local w: U64 = n
    return i + k
end
]])
formatted('a name out of scope or shadowed keeps the annotation', [[local f = do(a: U32): U32
    if a > 0 then
        local n: U32 = a
    end
    local x: U32 = n
    local g = do(n: U64): U32
        local y: U32 = n
        return y
    end
    return x
end
]], [[local f = do(a: U32): U32
    if a > 0 then
        local n = a
    end
    local x: U32 = n
    local g = do(n: U64): U32
        local y: U32 = n
        return y
    end
    return x
end
]])
formatted('table shorthand is kept and spaced', 'local t = P {.x,.y, z=3}\n', 'local t = P { .x, .y, z = 3 }\n')
formatted('the shorthand rewrites name = name', [[local f = do(x: U32, y: U32): P
    local a, x2 = x, y
    a, x = x, y
    return P { x = x, y = y, z = z }
end
local t = { x = x, y = y }
]], [[local f = do(x: U32, y: U32): P
    local a, x2 = x, y
    a, x = x, y
    return P { .x, .y, .z }
end
local t = { .x, .y }
]])
formatted('table_style preserve keeps name = name', 'local t = { x = x }\n', 'local t = { x = x }\n',
    { table_style = 'preserve' })
formatted('shorthand is the default', 'local t = { x = x, y = 2 }\n', 'local t = { .x, y = 2 }\n')
formatted('call keeps its boundary', 'local f = do(m: Ref M, k: U32): Unit\n    call m:put(k, 1)\n    local x = call hash(k)\n    local y = call lookup(m)(k)\nend\n',
    'local f = do(m: Ref M, k: U32): Unit\n    call m:put(k, 1)\n    local x = call hash k\n    local y = call lookup m k\nend\n')
formatted('type_style preserve keeps annotations', 'local f = do(): U32\n    local a: U32 = U32(0)\n    return a\nend\n',
    'local f = do(): U32\n    local a: U32 = U32 0\n    return a\nend\n', { type_style = 'preserve' })
formatted('a host binding keeps its annotation-free form', 'local a = U32(0)\n', 'local a = U32 0\n')
formatted('unary operators', 'local r = - x + # xs', 'local r = -x + #xs\n')
formatted('minus cannot become comment', 'local r=- -x', 'local r = - -x\n')
formatted('integer suffix', 'local r=U64(0xffffffffffffffffULL)', 'local r = U64 0xffffffffffffffffULL\n')
formatted('application newline', 'f x\ng y\n', 'f x\ng y\n')
formatted('shebang and CRLF', '#!/usr/bin/env slc\r\nlocal x=1\r\n', '#!/usr/bin/env slc\r\nlocal x = 1\n')
formatted('labels', '::again::\ngoto again', '::again::\ngoto again\n')
formatted('does not execute source', 'error("must not run")', 'error "must not run"\n')
formatted('blank lines', '\n\nlocal x=1\n\n\n\nlocal y=2\n\n', 'local x = 1\n\nlocal y = 2\n')
formatted('two spaces', 'local f=do(x:U32):U32\nreturn x\nend',
    'local f = do(x: U32): U32\n  return x\nend\n', { indent_width = 2 })
-- endall spines: pure links flatten, other bodies keep their indent, and a run
-- of closers folds only where the chain is one spine inside a typed body.
formatted('spine flattens pure links', [[local import_words = do(n: U32): Unit
    counted(n) do
    counted(n) do
    counted(n) do
        insert n
    end
    end
    end
end
export import_words
]], [[local import_words = do(n: U32): Unit
    counted n do
    counted n do
    counted n do
        insert n
    endall
end
export import_words
]])
formatted('spine keeps impure bodies nested', [[local import_words = do(n: U32): Unit
    counted(n) do
    log(n)
    counted(n) do
        insert n
    end
    end
end
export import_words
]], [[local import_words = do(n: U32): Unit
    counted n do
        log n
        counted n do
            insert n
        endall
end
export import_words
]])
formatted('spine_style all flattens impure bodies', [[local import_words = do(n: U32): Unit
    counted(n) do
    log(n)
    counted(n) do
        insert n
    end
    end
end
export import_words
]], [[local import_words = do(n: U32): Unit
    counted n do
    log n
    counted n do
        insert n
    endall
end
export import_words
]], { spine_style = 'all' })
formatted('spine_style none keeps every body nested', [[local import_words = do(n: U32): Unit
    counted(n) do
    counted(n) do
        insert n
    end
    end
end
export import_words
]], [[local import_words = do(n: U32): Unit
    counted n do
        counted n do
            insert n
        endall
end
export import_words
]], { spine_style = 'none' })
formatted('a comment between closers blocks folding', [[local import_words = do(n: U32): Unit
    counted(n) do
    counted(n) do
        insert n
    end  -- keep
    end
end
export import_words
]], [[local import_words = do(n: U32): Unit
    counted n do
        counted n do
            insert n
        end  -- keep
    end
end
export import_words
]])
formatted('host spines keep their ends', [[local host = do
    f(do
        return 1
    end)
end
]], [[local host = do
    f do
        return 1
    end
end
]])
formatted('a lone trailing block keeps end', [[local import_words = do(n: U32): Unit
    counted(n) do
        insert n
    end
end
export import_words
]], [[local import_words = do(n: U32): Unit
    counted n do
        insert n
    end
end
export import_words
]])
formatted('an existing endall keeps its column', [[local ping = do(n: U64): U64
    with_eventfd do(counter...)
        local value: U64 = n
        with_epoll do(poll...)
            watch(fd)
        endall
    return n
end
export ping
]], [[local ping = do(n: U64): U64
    with_eventfd do(counter...)
        local value = n
        with_epoll do(poll...)
            watch fd
        endall
    return n
end
export ping
]])
formatted('preserve keeps end runs', [[local import_words = do(n: U32): Unit
    counted(n) do
    counted(n) do
        insert n
    end
    end
end
export import_words
]], [[local import_words = do(n: U32): Unit
    counted(n) do
        counted(n) do
            insert n
        end
    end
end
export import_words
]], { call_style = 'preserve' })
local long = 'local x = { first_value, second_value, third_value, fourth_value }\n'
local wrapped = fmt.format(long, { column_width = 30 })
check('soft width wraps list', wrapped:find(',\n', 1, true) ~= nil, wrapped)
check('wrapped list is stable', fmt.format(wrapped, { column_width = 30 }) == wrapped)
formatted('application stays on one line', 'local x = very_long_function first_value second_value third_value',
    'local x = very_long_function first_value second_value third_value\n', { column_width = 30 })
local literal = 'local s=[==[\n  literal\n\tbytes -- not a comment\n]==]\n--[=[\n  comment\n]=]\n'
local out = fmt.format(literal)
local function protected(text)
    local result = {}
    for _, tk in ipairs(lexer.scan_raw_tokenlist(text)) do
        if tk[1] == 'string' or tk[1] == 'comment' then result[#result + 1] = tk[2] end
    end
    return table.concat(result, '\0')
end
check('literal and comment bytes unchanged', protected(literal) == protected(out))
check('comments in calls keep parentheses', fmt.format('local r = f( -- why\nx)\n'):find('f(  -- why', 1, true) ~= nil)
for _, settings in ipairs { { indent_width = 0 }, { column_width = 10 }, { call_style = 'lua' }, { surprise = true }, { indent_width = false }, { spine_style = 'flat' }, { type_style = 'always' }, { table_style = 'sugar' } } do
    local ok = pcall(fmt.format, 'local x=1', settings)
    check('reject invalid config', not ok)
end
check('reject invalid syntax', not pcall(fmt.format, 'local =', nil, 'broken.slc'))

-- All real examples and libraries must parse, retain protected bytes and settle
-- after one pass. Compile formatted examples as well as originals, including
-- their compile-time assertions, and compare residual output (not source sites).
package.loaded['slc.driver_loaded'] = true
local slc = dofile(root .. '/slc.lua')
local function normalized(c)
    return c:gsub('([%w_./%-]+%.slc):%d+:', '%1:<line>:')
end
for name in io.popen('ls ' .. q(root .. '/examples') .. '/*.slc ' .. q(root .. '/lib') .. '/*.slc'):lines() do
    local source = read(name)
    local result = fmt.format(source, nil, name)
    check(name .. ': idempotent', fmt.format(result, nil, name) == result)
    check(name .. ': protected tokens', protected(source) == protected(result))
    if name:find('/examples/', 1, true) then
        local before = slc.compile(source, name)
        local after = slc.compile(result, name)
        check(name .. ': equivalent C', normalized(before) == normalized(after))
    end
end

-- CLI: output, explicit write, CI status, discovery, and failed preflight.
local build = root .. '/build/formatter-tests'
assert(os.execute('mkdir -p ' .. q(build .. '/nested')) == 0)
local source_path = build .. '/nested/input.slc'
local bad_path = build .. '/nested/bad.slc'
local cfg = build .. '/.slcfmt.lua'
local bad_cfg = build .. '/bad-config.lua'
write(source_path, 'local r=Ref(h)')
write(cfg, 'return { indent_width = 2, column_width = 80, call_style = "preserve" }\n')
write(bad_path, 'local =')
write(bad_cfg, 'return { call_style = "wrong" }\n')
local cli = 'timeout 60 ' .. q(arg[-1] or 'luajit') .. ' ' .. q(root .. '/slc.lua') .. ' fmt '
local text, rc = capture(cli .. q(source_path))
check('CLI stdout and nearest config', rc == 0 and text == 'local r = Ref(h)\n', text)
check('stdout does not modify source', read(source_path) == 'local r=Ref(h)')
text, rc = capture(cli .. '--check ' .. q(source_path))
check('check changed status', rc == 1 and text:find(source_path, 1, true), text)
text, rc = capture(cli .. '--write ' .. q(source_path) .. ' ' .. q(bad_path))
check('bad input fails preflight', rc == 2 and read(source_path) == 'local r=Ref(h)', text)
text, rc = capture(cli .. '--write ' .. q(source_path))
check('write applies formatting', rc == 0 and read(source_path) == 'local r = Ref(h)\n', text)
text, rc = capture(cli .. '--check ' .. q(source_path))
check('check clean status', rc == 0 and text == '', text)
text, rc = capture(cli .. '--config ' .. q(bad_cfg) .. ' ' .. q(source_path))
check('invalid config fails', rc == 2 and text:find('call_style', 1, true), text)
text, rc = capture('printf ' .. q('local r=Ref(h)') .. ' | ' .. cli .. '-')
check('stdin to stdout', rc == 0 and text == 'local r = Ref h\n', text)
for _, options in ipairs { '--write -', '--write --check ' .. q(source_path), '--unknown', '--config', q(source_path) .. ' ' .. q(bad_path) } do
    text, rc = capture(cli .. options)
    check('CLI invalid options', rc == 2, text)
end
print(('%d formatter checks passed'):format(passed))
