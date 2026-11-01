-- Shared compiler/formatter application proofs: lexical facts, not execution.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
local fmt = require 'slc.fmt'
local passed = 0
local function check(name, condition, detail)
    assert(condition, name .. (detail and ('\n' .. detail) or ''))
    passed = passed + 1
end
local application = require 'slc.application'
local joined, count = application.word_arguments { { n = 1 }, { n = 2, [1] = 7 } }
check('shared argument collection preserves nil positions', count == 3 and joined[1] == nil
    and joined[2] == 7 and joined[3] == nil)
local add = 'local f = do(a: U32, b: U32): U32 = a + b'
local function call(name, prefix, input, expected, suffix, params)
    local source = prefix .. '\nlocal run = do(' .. (params or 'x: U32, y: U32') .. '): U32\n'
        .. '    return ' .. input .. '\nend\n' .. (suffix or '')
    local out = fmt.format(source, nil, name)
    check(name, out:find('return ' .. expected .. '\n', 1, true) ~= nil, out)
    check(name .. ': idempotent', fmt.format(out, nil, name) == out)
    return source, out
end
call('known native word', add, 'f(x, y)', 'f x y')
call('word alias', add .. '\nlocal alias = f', 'alias(x, y)', 'alias x y')
call('alias chain', add .. '\nlocal a = f\nlocal b = a', 'b(x, y)', 'b x y')
call('partial word alias', 'local sum = do(a: U32, b: U32, c: U32): U32 = a + b + c\nlocal f = sum(1)',
    'f(x, y)', 'f x y')
call('local typed function', 'local function f(a: U32, b: U32): U32 return a + b end', 'f(x, y)', 'f x y')
call('rest word collects every group', 'local f = do(a: U32, ..rest): U32 = a + U32(rest.length)',
    'f(x, y, 3)', 'f x y 3')
call('multiline arguments', add, 'f(\n        x,\n        y\n    )', 'f x y')
call('argument comment', add, 'f(x, --[[ keep ]] y)', 'f x  --[[ keep ]] y')
call('compound argument becomes a spaced group', add, 'f(x + 1, y)', 'f (x + 1) y')
call('compound arguments in every position', 'local f = do(a: U32, b: U32, c: U32): U32 = a + b + c',
    'f(x * 2, y, x + y)', 'f (x * 2) y (x + y)')
call('word result in the middle', add .. '\nlocal g = do(a: U32): U32 = a', 'f(g(x), y)', 'f (g x) y')
call('string after a name argument', 'local f = do(a: U32, b: Str): U32 = a', 'f(x, "s")', 'f x ("s")')
call('long multiline arguments keep their lines', add,
    'f(\n        xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx,\n        yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\n    )',
    'f(\n        xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx,', nil,
    'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx: U32, yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy: U32')
call('postfix result still needs grouping', add, 'f(x, y).value', 'f(x, y).value')
call('explicit boundary stays', add, 'call f(x, y)', 'call f(x, y)')
call('overapplication stays', add, 'f(x, y, 3)', 'f(x, y, 3)')
call('handler boundary stays', 'local f = do(x: U32): Outcome = Outcome.ok(x)',
    'f(x, handlers)', 'f(x, handlers)')
call('Lua function stays', 'local f = do(a, b) = a + b', 'f(x, y)', 'f(x, y)')
call('unknown import stays', 'local f = require "unknown-module"', 'f(x, y)', 'f(x, y)')
call('parameter shadows word', add, 'f(x, y)', 'f(x, y)', nil, 'f, x: U32, y: U32')
call('later write invalidates captured word', add, 'f(x, y)', 'f(x, y)', 'f = replacement\n')
call('captured write invalidates word', add .. '\nlocal change = do f = replacement end', 'f(x, y)', 'f(x, y)')
call('function statement invalidates word', add, 'f(x, y)', 'f(x, y)', 'function f(a, b) return a end\n')
call('rebound alias stays', add .. '\nlocal alias = f', 'alias(x, y)', 'alias(x, y)', 'alias = replacement\n')
call('alias of mutable binding stays', add .. '\nlocal alias = f', 'alias(x, y)', 'alias(x, y)', 'f = replacement\n')
call('opened parameter hides word', add, 'f(x, y)', 'f(x, y)', nil, 'ctx.., x: U32, y: U32')
call('method remains unknown', add, 'obj:f(x, y)', 'obj:f(x, y)')
call('multiple-result argument stays', add, 'f(pair(), y)', 'f(pair(), y)')
call('spread argument stays', add, 'f(x, ..values)', 'f(x, ..values)')

local function stable(name, source, expected)
    local out = fmt.format(source, nil, name)
    check(name, out:find(expected, 1, true) ~= nil, out)
    check(name .. ': idempotent', fmt.format(out, nil, name) == out)
end
stable('host calls keep groups even for words', add .. '\nlocal out = f(1, 2)', 'local out = f(1, 2)')
stable('block argument keeps its own commas',
    'local f = do(x: U32, body): U32 = body(x)\nlocal run = do(x: U32): U32\n'
        .. 'return f(x, do(v) local a,b=v,v return a+b end)\nend',
    'return f x do(v) local a, b = v, v return a + b end')
stable('native nested declaration', 'local run = do(x: U32, y: U32): U32\n' .. add .. '\nreturn f(x,y)\nend', 'return f x y')
stable('local opening blocks proof', add .. '\nlocal run = do(x: U32, y: U32): U32\nlocal ctx.. = value\nreturn f(x,y)\nend',
    'return f(x, y)')
stable('numeric loop variable shadows word', add .. '\nlocal run = do(): Unit\nfor f=1,2 do consume(f(1,2)) end\nend',
    'f(1, 2)')
stable('generic loop variable shadows word', add .. '\nlocal run = do(): Unit\nfor f in values do consume(f(1,2)) end\nend',
    'f(1, 2)')
stable('repeat locals scope over condition', add .. '\nlocal run = do(): Unit\nrepeat local f = other until f(1,2)\nend',
    'until f(1, 2)')
stable('branch local does not escape', add .. '\nlocal run = do(x: U32,y: U32): U32\nif true then local f = other end\nreturn f(x,y)\nend',
    'return f x y')
stable('typed declaration shadows sequentially', add .. '\nlocal run = do(x: U32,y: U32): U32\nlocal f: U32, alias = 1, f\nreturn alias(x,y)\nend',
    'return alias(x, y)')
local preserve_source = add .. '\nlocal run = do(x: U32,y: U32): U32 return f(x,y) end'
check('preserve option', fmt.format(preserve_source, { call_style = 'preserve' }):find('return f(x, y)', 1, true) ~= nil)

-- Compilation executes assertions on both spellings. Compare residual functions
-- rather than optional unused headers, and independently execute their C bodies.
package.loaded['slc.driver_loaded'] = true
local slc = dofile(root .. '/slc.lua')
local program = [=[
local add = do(a: U32, b: U32): U32 = a + b
local alias = add
local sum3 = do(a: U32, b: U32, c: U32): U32 = a + b + c
local partial = sum3(10)
local count = do(first: U32, ..rest): U32 = first + U32(rest.length)
local pair = function() return U32 7, U32 99 end
local multi = do(x: U32, y: U32): U32
    local nested = do(a: U32, b: U32): U32 = a + b
    return nested(x, y) + alias(x, y) + partial(x, y) + count(x, y, 42)
end
local adjusted = do(y: U32): U32 = add(pair(), y)
local Outcome = oneof { ok: U32 }
local producer = do(x: U32): Outcome = Outcome.ok(x)
local handled = do(x: U32): U32 = producer(x) { ok(v) = v + 1 }
local through_alias = do(x: U32, y: U32): U32
    return alias(x, y)
end
local returned_rest = do(x: U32): U32
    return count(x, 10, 20)
end
local lua_curry = do(a) = do(b) = a + b
local host_chain = do(x: U32, y: U32): U32
    return lua_curry(x)(y)
end
local function recur(n: U32, total: U32): U32
    if n == 0 then return total end
    local next_n = n - 1
    local next_total = total + n
    return recur(next_n, next_total)
end
assert(host(through_alias(U32 3, U32 4)) == 7)
assert(host(returned_rest(U32 3)) == 5)
assert(host(host_chain(U32 3, U32 4)) == 7)
assert(host(recur(U32 10, U32 0)) == 55)
assert(host(multi(U32 3, U32 4)) == 36)
assert(host(adjusted(U32 2)) == 9)
assert(host(handled(U32 5)) == 6)
export multi
export adjusted
export handled
export recur
export through_alias
export returned_rest
export host_chain
]=]
local output = fmt.format(program, nil, 'application.slc')
check('semantic fixture actually rewrites groups', output:find('nested x y', 1, true) ~= nil, output)
check('semantic fixture preserves return adjustment', output:find('add(pair(), y)', 1, true) ~= nil, output)
local before, after = slc.compile(program, 'application.slc'), slc.compile(output, 'application.slc')
for _, name in ipairs { 'multi', 'adjusted', 'handled', 'recur', 'through_alias', 'returned_rest', 'host_chain' } do
    local pattern = '(uint32_t ' .. name .. '%b() %b{})'
    check(name .. ': equivalent residual C', assert(before:match(pattern)) == assert(after:match(pattern)))
end
check('both compilation-time assertion sets executed', true)
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local build = root .. '/build/formatter-application'
assert(os.execute('mkdir -p ' .. quote(build)) == 0)
local function write(path, text)
    local f = assert(io.open(path, 'wb')); assert(f:write(text)); assert(f:close())
end
write(build .. '/main.c', [[
#include <assert.h>
#include <stdint.h>
uint32_t multi(uint32_t, uint32_t);
uint32_t adjusted(uint32_t);
uint32_t handled(uint32_t);
uint32_t recur(uint32_t, uint32_t);
uint32_t through_alias(uint32_t, uint32_t);
uint32_t returned_rest(uint32_t);
uint32_t host_chain(uint32_t, uint32_t);
int main(void) {
    assert(recur(100000, 0) == 705082704u);
    assert(through_alias(100, 200) == 300);
    assert(returned_rest(100) == 102);
    assert(host_chain(100, 200) == 300);
    assert(multi(100, 200) == 1012);
    assert(adjusted(20) == 27);
    assert(handled(9) == 10);
    return 0;
}
]])
for _, item in ipairs { { 'before', before }, { 'after', after } } do
    local path = build .. '/' .. item[1]
    write(path .. '.c', item[2])
    local cc = os.getenv('CC') or 'cc'
    check(item[1] .. ': strict C build', os.execute(cc .. ' -std=c99 -Wall -Wextra -Werror -I '
        .. quote(root .. '/runtime') .. ' ' .. quote(path .. '.c') .. ' ' .. quote(build .. '/main.c')
        .. ' -o ' .. quote(path)) == 0)
    check(item[1] .. ': native results', os.execute(quote(path)) == 0)
end

-- A known local chain now emits the same staged Lua as its grouped spelling:
-- the compiler, not just the formatter, consumes the shared analysis.
local macro = require 'macro'
local lexer = require 'macro.lexer'
local function translated(source)
    local code = assert(macro.substitute_tostring(source, 'shared.slc'))
    local parts = {}
    for _, tk in ipairs(lexer.scan_raw_tokenlist(code)) do
        if tk[1] ~= 'space' and tk[1] ~= 'comment' then parts[#parts + 1] = tk[2] end
    end
    return table.concat(parts, '\0')
end
local grouped = 'local run = do(x: U32, y: U32): U32 ' .. add .. ' return f(x, y) end'
local bare = 'local run = do(x: U32, y: U32): U32 ' .. add .. ' return f x y end'
check('codegen shares word normalization', translated(grouped) == translated(bare))
print(('%d application formatter/compiler checks passed'):format(passed))
