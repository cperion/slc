local ffi=require 'ffi'
ffi.cdef [[void *dlopen(const char *,int); const char *dlerror(void); void *dlsym(void *,const char *);]]
local M={owners={}}
function M.c_baseline(slc,path,module,name)
    local source=assert(io.open(path,'rb')); local text=source:read('*a'); source:close()
    local code=slc.compile(text,path,{runtime='shared'})
    local cpath,sopath='build/direct/'..name..'.c','build/direct/'..name..'.so'
    local out=assert(io.open(cpath,'wb')); out:write(code); out:close()
    assert(os.execute(('%s -std=c99 -O2 -shared -fPIC -Wl,-Bsymbolic -Iruntime %q -o %q')
        :format(os.getenv('CC') or 'cc',cpath,sopath))==0,'C baseline build failed: '..path)
    local handle=ffi.C.dlopen(sopath,2)
    if handle==nil then error(ffi.string(ffi.C.dlerror()),0) end
    M.owners[#M.owners+1]=handle
    local names={}
    for fn in pairs(module.direct.plans) do if fn.export_name then names[fn.export_name]=fn.cname end end
    local result={}
    for name,pointer in pairs(module.raw) do
        local address=ffi.C.dlsym(handle,names[name] or name)
        assert(address~=nil,'missing C export '..name)
        result[name]=ffi.cast(ffi.typeof(pointer),address)
    end
    return result
end
return M
