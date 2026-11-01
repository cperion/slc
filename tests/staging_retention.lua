-- Rolled-back rounds must release IR and locals without losing live nested functions.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
package.loaded['slc.driver_loaded'] = true
local slc = dofile(root .. '/slc.lua')
local S = require 'slc.stage'
local B = S.Builder
local new_local, snapshot, rollback = B.new_local, B.snapshot, B.rollback
local marks = setmetatable({}, { __mode = 'k' })
local owners, retries, discarded = 0, 0, 0
B.new_local = function(b, ...)
    local p = new_local(b, ...)
    local owner = rawget(p, 'frame')
    if owner then
        assert(next(owner) == nil, 'a local retains its full staging frame')
        owners = owners + 1
    end
    return p
end
B.snapshot = function(b, ...)
    local snap = snapshot(b, ...)
    marks[snap] = { locals = b.fn and #b.fn.locals, emissions = #b.emissions }
    return snap
end
B.rollback = function(b, snap)
    local mark, abandoned = assert(marks[snap]), {}
    for i = mark.emissions + 1, #b.emissions do abandoned[#abandoned + 1] = b.emissions[i] end
    rollback(b, snap)
    if mark.locals then assert(#b.fn.locals == mark.locals, 'rollback retained abandoned locals') end
    for _, id in ipairs(abandoned) do
        assert(S.statement(id) == false, 'rollback retained abandoned statement graphs')
        discarded = discarded + 1
    end
    retries = retries + 1
end
local prior_profile = S.size_profile
local profile = require('slc.size').new()
S.size_profile = profile
local path = root .. '/examples/loop_adoption.slc'
local f = assert(io.open(path)); local source = f:read('*a'); f:close()
local ok, c = pcall(slc.compile, source, path)
B.new_local, B.snapshot, B.rollback = new_local, snapshot, rollback
S.size_profile = prior_profile
assert(ok, c)
assert(owners > 0 and retries > 0 and discarded > 0, 'retention fixture did not exercise retries')
profile:measure() -- discarded stream positions still count as zero in size reports
local report = require('slc.size').report(profile, c, path, 3)
assert(report:find('where the C comes from', 1, true), 'size attribution lost discarded positions')
assert(c:find('change(', 1, true), 'rollback lost the live materialized helper')
print(('staging retention: %d local identities, %d rollbacks, %d discarded statements checked'):format(
    owners, retries, discarded))
