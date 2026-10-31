-- Offline runtime-header evidence and TLS accessors. Share the existing C
-- declaration reader, then ask the real C compiler for every recorded layout.
local C = require 'slc.cjit'
local signature = require('slc.direct.runtime_meta').signature
local scope = C.runtime_scope('runtime')
local probe = assert(io.open(assert(arg[1]), 'wb'))
local access = assert(io.open(assert(arg[2]), 'wb'))
local function put(s) probe:write(s, '\n') end
local function text(s) put('puts(' .. string.format('%q', s) .. ');') end
local function keys(t, predicate)
    local names={}; for n,v in pairs(t) do if predicate(n,v) then names[#names+1]=n end end
    table.sort(names); return names
end
put('#include "slc_rt.h"\n#include <stdio.h>\n#include <stddef.h>\n#include <fcntl.h>\n#include <errno.h>\nint main(void) {')
text('return {abi=1,target="linux-x64",records={')
for _, name in ipairs(keys(scope.types, function(n,t)
    return n:match('^slc_[%w_]+$') and (t.k=='struct' or t.k=='union') and t.fields
end)) do
    local t=scope.types[name]
    put(('printf("[\\\"%s\\\"]={size=%%zu,align=%%zu,fields={\\n",sizeof(%s),_Alignof(%s));'):format(name,name,name))
    for _, f in ipairs(t.fields) do
        put(('printf("[\\\"%s\\\"]={offset=%%zu,size=%%zu},\\n",offsetof(%s,%s),sizeof(((%s *)0)->%s));')
            :format(f[1],name,f[1],name,f[1]))
    end
    text('}},')
end
text('}, functions={')
for _, name in ipairs(keys(scope.names,function(_,d) return d.fn~=nil end)) do
    text(('[%q]=%q,'):format(name,signature(scope.names[name].fn.t)))
end
text('}, constants={')
local constants={}
-- Native constants used by the existing I/O vocabulary: values come from the
-- target headers, never from a duplicated platform-number table.
for name in ('O_RDONLY O_WRONLY O_RDWR O_CREAT O_TRUNC O_APPEND ENOENT EACCES ECONNREFUSED EPIPE'):gmatch('%S+') do
    constants[name]=true
end
for name,d in pairs(scope.names) do if d.const~=nil then constants[name]=true end end
for name,m in pairs(scope.macros) do
    if name:match('^SLC_') and not m.params and #m.body>0
        and name~='SLC_HELPER' and name~='SLC_NORETURN' and name~='SLC_COLD' then constants[name]=true end
end
for _,name in ipairs(keys(constants,function() return true end)) do
    put(('printf("[\\\"%s\\\"]=%%lluULL,\\n",(unsigned long long)(%s));'):format(name,name))
end
text('}, globals={')
access:write('#include "slc_rt.h"\n')
for _,name in ipairs(keys(scope.names,function(_,d) return d.global~=nil end)) do
    local getter='cp_runtime_address_'..name
    access:write('void *',getter,'(void) { return (void *)&',name,'; }\n')
    text(('[%q]=%q,'):format(name,getter))
end
text('}, inlines={')
local function declaration(t,n)
    if t.k=='ptr' then
        local inner='*'..n
        if t.to.k=='fn' or t.to.k=='array' then inner='('..inner..')' end
        return declaration(t.to,inner)
    elseif t.k=='array' then return declaration(t.of,n..'['..t.n..']')
    elseif t.k=='fn' then
        local ps={}; for i,p in ipairs(t.params) do ps[i]=declaration(p,'a'..i) end
        assert(not t.variadic,'direct: an inline varargs wrapper needs an explicit adapter')
        return declaration(t.ret,n..'('..(#ps>0 and table.concat(ps,',') or 'void')..')')
    end
    local c=t.k=='int' and ((t.signed and 'int' or 'uint')..(t.size*8)..'_t')
        or t.k=='float' and (t.size==4 and 'float' or 'double')
        or (t.k=='struct' or t.k=='union') and (t.k..' '..t.name) or t.k
    return c..' '..n
end
for _,name in ipairs(keys(scope.names,function(_,d) return d.fn and d.fn.ast end)) do
    local t=scope.names[name].fn.t
    local wrapper='cp_runtime_inline_'..name
    local args={}; for i=1,#t.params do args[i]='a'..i end
    access:write(declaration(t,wrapper),' { ',t.ret.k=='void' and '' or 'return ',name,'(',table.concat(args,','),'); }\n')
    text(('[%q]=%q,'):format(name,wrapper))
end
text('}}')
put('return 0;\n}')
probe:close(); access:close()
