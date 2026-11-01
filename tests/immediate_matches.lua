local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
package.loaded['slc.driver_loaded'] = true
local slc = dofile(root .. '/slc.lua')
local path = root .. '/examples/immediate_matches.slc'
local f = assert(io.open(path)); local source = f:read('*a'); f:close()
local c = slc.compile(source, path)
local function body(name)
    return assert(c:match(name .. '%b()%s*(%b{})'), 'missing function ' .. name)
end
for _, name in ipairs { 'native_match', 'callback_match', 'state_join', 'constant_payload',
    'side_effects', 'record_payload' } do
    local text = body(name)
    assert(not text:find('%.tag'), name .. ': immediate known outcomes materialized a sum tag')
end
local native = body('native_match')
assert(native:find('payload = 10u', 1, true) and native:find('payload = 20u', 1, true))
local _, arm_count = native:gsub('return payload %+ 1u;', '')
assert(arm_count == 1, 'same-tag producer returns duplicated their handler')
assert(body('constant_payload'):find('return 101u;', 1, true))
assert(body('boundary_match'):find('choose(', 1, true))
assert(body('boundary_match'):find('%.tag'), 'an explicit call boundary was bypassed')
assert(body('mixed_unknown'):find('%.tag'), 'unknown sum returns lost their runtime dispatch')
local ok, err = pcall(slc.compile, [[local Choice = oneof { yes: U32, no: Unit }
local run = do(n: U32): U32
    local body = do()
        if n > 0 then return Choice.yes(U32 1) end
        return Choice.no()
    end
    return body() { yes(p) = p }
end
export run
]], 'missing-immediate-handler.slc')
assert(not ok and tostring(err):find("alternative 'no' has no handler", 1, true), tostring(err))
print('immediate matches: owned landings, payload joins, boundaries and exhaustiveness passed')
