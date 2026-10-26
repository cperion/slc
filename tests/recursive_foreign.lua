local S = require 'slc.stage'
local T = require 'slc.types'
local calls = 0
local node = S.cstruct('slc_task', '"slc_rt.h"', function(Self)
    calls = calls + 1
    return { { 'next', T.ptr(Self) } }
end)
assert(calls == 1 and node.index.next.type.elem == node)
assert(node.cname == 'slc_task' and node.foreign == '"slc_rt.h"')
for _, fields in ipairs {
    function(Self) return { { 'self', Self } } end,
    function(Self) return { { 'self', T.array(Self, 2) } } end,
    function(Self) return { { 'self', T.sum('Inner', { { 'value', Self } }) } } end,
    function(Self) return { { 'self', T.struct('Inner', { { 'value', Self } }) } } end,
} do
    local ok, err = pcall(S.cstruct, 'bad', '"slc_rt.h"', fields)
    assert(not ok and tostring(err):find('incomplete type'), tostring(err))
end
local ok, err = pcall(S.cstruct, 'bad', '"slc_rt.h"', function() return false end)
assert(not ok and tostring(err):find('fields must be'), tostring(err))
print('recursive foreign descriptors: construction and by-value rejection passed')
