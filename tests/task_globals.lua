-- Global address provenance is checked on complete, shared residual IR.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
package.loaded['slc.driver_loaded'] = true
local slc = dofile(root .. '/slc.lua')
local count = 0
local function program(body, prefix, options, before)
    return 'local hits = global(U32, { name = "hits"' .. (options or '') .. ' })\n'
        .. (prefix or '') .. '\nlocal run = do(n: U32): U32\n' .. (before or '')
        .. '\n    tasks do(..)\n        spawn do\n' .. body
        .. '\n        end\n    end\n    return n\nend\nexport run\n'
end
local function check(name, source, reject)
    local ok, result = pcall(slc.compile, source, 'task_globals_' .. name .. '.slc')
    if reject then
        assert(not ok and tostring(result):find(reject, 1, true),
            name .. ': ' .. (ok and 'unexpected successful compilation' or tostring(result)))
    else assert(ok, name .. ': ' .. tostring(result)) end
    count = count + 1
end
local error_text = "it writes global 'hits'"
check('direct', program('hits[0] = 1'), error_text)
check('blocking', program('blocking do hits[0] = 1 end'), error_text)
check('alias', program('local p = hits\np[0] = 1'), error_text)
check('converted', program('local p = (Ptr U8)(hits)\np[0] = 1'), error_text)
local bump = 'local bump = do(p: Ptr U32): Unit\n    p[0] = 1\nend\n'
check('callee', program('call bump hits', bump), "it writes global 'hits' (in bump)")
check('fnptr', program('local f = fnptr bump\nf(hits)', bump), error_text)
check('returned', program('local p = call address()\np[0] = 1',
    'local address = do(): Ptr U32 = hits\n'), error_text)
check('aggregate_alias', program('local box = Box { p = hits }\nbox.p[0] = 1',
    'local Box = struct { p: Ptr U32 }\n'), error_text)
local pointer_sum = [[local Choice = oneof { address: Ptr U32, none: Unit }
local choose = do(n: U32): Choice
    if n > 0 then return Choice.address hits end
    return Choice.none()
end
]]
check('sum_payload_alias', program([[local value = call choose n
value { address = do(p) p[0] = 1 end, none = do() end }
]], pointer_sum), error_text)
check('sum_payload_read', program([[local value = call choose n
value { address = do(p) assert(p[0] >= 0) end, none = do() end }
]], pointer_sum))
check('stored_before_spawn', program('alias[0][0] = 1',
    'local alias = global(Ptr U32, { name = "alias" })\n', nil, 'alias[0] = hits\n'), error_text)
check('opaque', program('opaque(hits)',
    'local opaque = extern("opaque", { Ptr U32 }, Unit)\n'), "opaque code may write global 'hits'")
check('opaque_record_address', program('local box = Box { p = hits }\nopaque(Ptr box)', [[local Box = struct { p: Ptr U32 }
local opaque = extern("opaque", { Ptr Box }, Unit)
]]), "opaque code may write global 'hits'")
check('shared_pointer_is_not_shared_pointee', program('alias[0] = hits\nalias[0][0] = 1',
    'local alias = global(Ptr U32, { name = "alias", shared = true })\n'), error_text)
check('foreign_callback', program('invoke(fnptr touch)',
    'local touch = do(): Unit\n    hits[0] = 1\nend\nlocal invoke = extern("invoke", { Fn({}, Unit) }, Unit)\n'), error_text)
check('recursive', program('call descend(hits, n)', [[local descend
descend = do(p: Ptr U32, n: U32): U32
    if n == 0 then p[0] = 1; return 0 end
    return 1 + descend(p, n - 1)
end
]]), error_text)
check('tail_parameter_alias', program('local value: U32 = 0\ncall route(Ptr value, n)', [[local route
route = do(p: Ptr U32, n: U32): Unit
    if n == 0 then p[0] = 1; return end
    return route(hits, n - 1)
end
]]), error_text)
check('callee_stores_alias', program('local p = null U32\ncall link(Ptr p, hits)\np[0] = 1',
    'local link = do(dst: Ptr(Ptr U32), src: Ptr U32): Unit\n    dst[0] = src\nend\n'), error_text)
check('indirect_callback', program('call invoke(fnptr touch)', [[local touch = do(): Unit
    hits[0] = 1
end
local invoke = do(f: Fn({}, Unit)): Unit
    f()
end
]]), error_text)
check('mixed_indirect', program('local f = fnptr read_only\nif n > 0 then f = getfn() end\nf(hits)', [[local read_only = do(p: Ptr U32): U32 = p[0]
local getfn = extern("getfn", {}, Fn({ Ptr U32 }, U32))
]]), "opaque code may write global 'hits'")
check('opaque_memory_alias', program('local p = alloc(U64 8)\np[0] = hits\np[0][0] = 1',
    'local alloc = extern("alloc", { U64 }, Ptr(Ptr U32))\n'), error_text)
check('read', program('local value = hits[0]\nassert(value >= 0)'))
check('callee_reads', program('local value = call read_only hits\nassert(value >= 0)',
    'local read_only = do(p: Ptr U32): U32 = p[0]\n'))
check('tls', program('hits[0] = 1', nil, ', thread_local = true'))
check('shared', program('hits[0] = 1', nil, ', shared = true'))
check('atomic', [[local hits = global(Atomic U32, { name = "hits" })
local run = do(): U32
    tasks do(..) spawn do hits[0]:add 1 end end
    return hits[0]:load()
end
export run
]])
check('non_atomic_alias_of_atomic', [[local hits = global(Atomic U32, { name = "hits" })
local run = do(): U32
    tasks do(..)
        spawn do
            local p = (Ptr U32)(hits)
            p[0] = 1
        end
    end
    return 0
end
export run
]], error_text)
-- The same helper can touch a global in plain code and local storage in a task.
-- Ordinary caller arguments must not leak into its task-call context.
check('caller_contexts', program('local value: U32 = 0\ncall bump(Ptr value)', bump, nil, 'call bump hits\n'))
print(('task globals: %d provenance checks passed'):format(count))
