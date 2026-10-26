-- Lua's actual require, with SLC source loading and compilation lifetimes.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
package.loaded['slc.driver_loaded'] = true
local slc = require 'slc'
local stage = require 'slc.stage'
local registry = debug.getregistry()
local passed = 0
local function check(name, ok, detail)
    assert(ok, name .. (detail and ('\n' .. tostring(detail)) or ''))
    passed = passed + 1
end
local saved = { loaded = package.loaded, registry = registry._LOADED,
    loaders = package.loaders, preload = package.preload, path = package.path, cpath = package.cpath }
local function restored()
    check('host loader state restored', package.loaded == saved.loaded and registry._LOADED == saved.registry
        and package.loaders == saved.loaders and package.preload == saved.preload
        and package.path == saved.path and package.cpath == saved.cpath)
    check('module values do not leak', package.loaded.value == nil and package.loaded.wrapper == nil
        and package.loaded['slc.hash'] == nil and package.loaded.cycle_a == nil)
end
local path = root .. '/tests/modules/main.slc'
local captures = {}
local previous_record = package.preload.record
package.preload.record = function()
    return function(value) captures[#captures + 1] = value end
end
local src = [[
assert(require == _G.require)
assert(import == nil and __S.import == nil)
assert(package.loaded == debug.getregistry()._LOADED)
local lua_io = require "io"
assert(lua_io == _G.io)
local io = require "slc.io"
assert(io ~= lua_io and io.read ~= nil)
local ffi = require "ffi"
assert(ffi.sizeof("uint32_t") == 4)
local bit = require "bit"
assert(bit.band(7, 3) == 3)
local wrapped = require "wrapper"
local value = require "value"
assert(wrapped.value == value and require("wrapper") == wrapped)
assert(value.name == "value")
assert(package.loaded.value == value)
assert(require("pkg").name == "pkg")
assert(require("pkg").answer == 42)
assert(require("preferred") == "Lua source wins")
assert(require("empty") == true)
assert(require("published").published)
local record = require "record"
record(wrapped)
local answer = do(x: U32): U32 = value.increment x
export answer
]]
for i = 1, 3 do
    local c = slc.compile(src, path)
    check('compile mixed modules', c:find('return x + 1u;', 1, true))
    restored()
end
check('Lua wrappers are fresh each compilation', captures[1] ~= captures[2] and captures[2] ~= captures[3])
check('staged values are fresh each compilation', captures[1].value.increment ~= captures[2].value.increment
    and captures[1].value.Item ~= captures[2].value.Item)

-- Native require owns nil/false, package.loaded publication and failure sentinels.
local old_counter = package.preload.counter
package.preload.counter = function() return { loads = 0 } end
slc.compile([[
local counter = require "counter"
assert(require("false_value") == false)
assert(require("false_value") == false and counter.loads == 2)
local ok, why = pcall(require, "failure")
assert(not ok and why:find("module failed deliberately", 1, true))
local again, reason = pcall(require, "failure")
assert(not again and reason:find("loop or previous error", 1, true))
package.loaded.failure = nil
local retried, error = pcall(require, "failure")
assert(not retried and error:find("module failed deliberately", 1, true))
]], path)
check('native require return and failure semantics', true)
restored()
package.preload.counter = old_counter

for _, case in ipairs {
    { 'cycle_a', 'loop or previous error' },
    { 'failure', 'module failed deliberately' },
    { 'broken', 'broken.slc' },
    { 'not_a_module', 'not_a_module.slc' },
} do
    local ok, why = pcall(slc.compile, 'require "' .. case[1] .. '"\n', path)
    check('reject ' .. case[1], not ok and tostring(why):find(case[2], 1, true), why)
    restored()
end
local _, _, env = slc.compile('local value = require "value"\n', path, { no_c = true })
check('no_c preserves returned environment', type(env) == 'table')
restored()
slc.compile('local value = require "value"\n', path, { dump = true })
restored()

-- A cached host module is still the exact same ordinary Lua value.
local host_value = {}
package.loaded.module_test_host = host_value
package.preload.host_check = function() return function(v) assert(v == host_value) end end
slc.compile('local check = require "host_check"\ncheck(require "module_test_host")\n', path)
check('existing host modules retain identity', package.loaded.module_test_host == host_value)
package.loaded.module_test_host, package.preload.host_check = nil, nil
restored()

-- Preload keeps precedence; scoped path/preload edits do not escape on failure.
local old_value = package.preload.value
package.preload.value = function() return 'preloaded' end
slc.compile('assert(require("value") == "preloaded")\n', path)
check('preload wins', true)
package.preload.value = old_value
local ok, why = pcall(slc.compile, [[
package.path = "changed"
package.cpath = "changed"
package.preload.test_leak = function() return true end
package.loaded.test_leak = {}
error "restore me"
]], path)
check('restore after error', not ok and tostring(why):find('restore me', 1, true), why)
restored()
check('preload edits isolated', package.preload.test_leak == nil and package.loaded.test_leak == nil)

-- Do not reset the active builder if a host callback attempts nested compilation.
package.preload.try_nested = function() return function() slc.compile('', path) end end
local c = slc.compile([[
local nested = require "try_nested"
local ok, why = pcall(nested)
assert(not ok and why:find("nested compilation", 1, true))
local f = do(x: U32): U32 = x + 2
export f
]], path)
check('nested compilation rejected before reset', c:find('return x + 2u;', 1, true))
package.preload.try_nested = nil
restored()

-- Internal library requests also use the active cache. No global string or
-- storage-word cache may retain a previous compilation's library instance.
local original_preload = package.preload['slc.str']
local loads = 0
package.preload['slc.str'] = function()
    loads = loads + 1
    local function equal() return stage.known(require('slc.types').Bool, loads % 2 == 1) end
    return { equals = equal, equals_known = equal }
end
for i = 1, 2 do
    local code = slc.compile('local f = do(x: Str): Bool = x:equals("x")\nexport f\n', path)
    check('internal text library scoped', code:find('return ' .. (i == 1 and 'true' or 'false') .. ';', 1, true), code)
end
package.preload['slc.str'] = original_preload
package.preload.record = previous_record
restored()
check('no custom import API remains', slc.import == nil and stage.import == nil)
print(('%d module loading checks passed'):format(passed))
