-- Focused formatter regression: a same-line do argument needs no call parens.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
local fmt = require 'slc.fmt'
local passed = 0
local function check(name, condition, detail)
    assert(condition, name .. (detail and ('\n' .. detail) or ''))
    passed = passed + 1
end
local function formatted(name, source, expected, options)
    local result = fmt.format(source, options, name)
    check(name, result == expected, result)
    check(name .. ': idempotent', fmt.format(result, options, name) == result)
    return result
end
formatted('host method block', 'items:each(do(item)\nconsume item\nend)',
    'items:each do(item)\n    consume item\nend\n')
formatted('host plain block', 'visit(do\nwork()\nend)',
    'visit do\n    work()\nend\n')
formatted('inline block', 'visit(do(x) return x end)', 'visit do(x) return x end\n')
formatted('comments in body', 'visit(do(x) -- keep this\n-- and this\nconsume x\nend)',
    'visit do(x)  -- keep this\n    -- and this\n    consume x\nend\n')
formatted('already bare', 'visit do(x)\nconsume x\nend',
    'visit do(x)\n    consume x\nend\n')
formatted('preserve option', 'visit(do(x)\nconsume x\nend)',
    'visit(do(x)\n        consume x\n    end)\n', { call_style = 'preserve' })
formatted('next-line do stays delimited', 'visit(\ndo(x)\nconsume x\nend)',
    'visit(\n    do(x)\n        consume x\n    end)\n')
check('invalid split owning call rejected', not pcall(fmt.format, 'visit\n(do end)'))
formatted('multiple arguments stay together', 'visit(1, do(x)\nconsume x\nend)',
    'visit(1, do(x)\n        consume x\n    end)\n')
formatted('callee after call', 'visit(1)(do(x)\nconsume x\nend)',
    'visit 1 do(x)\n    consume x\nend\n')
formatted('native block', 'local f=do():Unit\nvisit(do(x)\nconsume x\nend)\nend',
    'local f = do(): Unit\n    visit do(x)\n        consume x\n    end\nend\n')
formatted('nested do blocks', 'visit(do(x)\nother(do(y)\nconsume y\nend)\nend)',
    'visit do(x)\n    other do(y)\n        consume y\n    end\nend\n')

-- Exercise the actual macro translator independently of runtime/compiler
-- initialization. Execute the host case; compare generated staged Lua for the
-- native case, rather than relying only on the formatter's parser fingerprint.
local macro = require 'macro'
require 'macro.builtin'
require 'macro.slc'
local lexer = require 'macro.lexer'
local function equivalent(name, source, execute)
    local result = fmt.format(source, nil, name)
    local before = assert(macro.substitute_tostring(source, name))
    local after = assert(macro.substitute_tostring(result, name))
    local function normalize(code)
        local parts = {}
        for _, tk in ipairs(lexer.scan_raw_tokenlist(code)) do
            if tk[1] ~= 'space' and tk[1] ~= 'comment' then parts[#parts + 1] = tk[2] end
        end
        return table.concat(parts, '\0')
    end
    check(name .. ': same translated Lua', normalize(before) == normalize(after), after)
    if execute then
        assert(loadstring(before, '@' .. name))()
        assert(loadstring(after, '@' .. name))()
        check(name .. ': host assertions executed', true)
    end
end
equivalent('host_do.slc', [[
local each = do(body)
    body(1)
    body(2)
end
local total = 0
each(do(x)
    total = total + x
end)
assert(total == 3)
]], true)
equivalent('native_do.slc', [[
local twice = do(body) = body(2) + body(3)
local f = do(x: U32): U32
    return twice(do(y)
        return x + y
    end)
end
export f
]])
print(('%d do-block formatter checks passed'):format(passed))
