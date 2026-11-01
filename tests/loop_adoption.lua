-- Inspect residual invariants, not just optimized machine-code behavior.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
package.loaded['slc.driver_loaded'] = true
local slc = dofile(root .. '/slc.lua')
local path = root .. '/examples/loop_adoption.slc'
local f = assert(io.open(path)); local source = f:read('*a'); f:close()
local c = slc.compile(source, path)
local function body(name)
    return assert(c:match(name .. '%b()%s*(%b{})'), 'missing function ' .. name)
end
for _, name in ipairs { 'evens', 'mixed_aliases', 'nested_aliases', 'exits', 'spin', 'sum_field' } do
    local text = body(name)
    assert(not text:find('%.step'), name .. ': invariant field became storage')
    assert(text:find('3u', 1, true), name .. ': invariant value did not fold')
end
local inside = body('escape_inside')
local loop = assert(inside:find('for (;;)', 1, true))
assert(assert(inside:find('state.count = 0u', 1, true)) < loop)
assert(assert(inside:find('state.step = 3u', 1, true)) < loop)
assert(inside:find('state.count + state.step', 1, true))
local between = body('escape_between')
local call = assert(between:find('change(&state)', 1, true))
assert(between:sub(1, call):find('state.count + 3u', 1, true))
assert(between:sub(call):find('state.count + state.step', 1, true))
local rotating = body('spin')
assert(not rotating:find('uint32_t left', 1, true) and not rotating:find('uint32_t right', 1, true),
    'derived rotate locals materialized instead of sharing the bound input')
print('loop adoption: invariant fields, alias ownership, escape placement and read snapshots passed')
