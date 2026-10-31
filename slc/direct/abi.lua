-- FFI sees only native bridge functions, never calls preserve_none itself.
local ffi = require 'ffi'
assert(ffi.os == 'Linux' and ffi.arch == 'x64', 'direct backend requires Linux x86-64')
ffi.cdef [[
typedef uint64_t cp_vec __attribute__((vector_size(16)));
typedef struct cp_bank { uint64_t i[11]; cp_vec f[8]; } cp_bank;
typedef struct cp_context { unsigned char *locals; unsigned char *result; void *user; } cp_context;
typedef struct cp_call_image {
    void *target; uint64_t gpr[6]; cp_vec xmm[8];
    const unsigned char *stack_data; size_t stack_size; uint8_t vector_count;
    uint64_t ret_gpr[2]; cp_vec ret_xmm[2];
} cp_call_image;
typedef struct cp_vm_call {
    void *entry; size_t frame_bytes; const void *args; size_t arg_bytes; void *result;
} cp_vm_call;
typedef struct cp_export_desc { void *entry; size_t frame_bytes; size_t result_offset; void *finish; } cp_export_desc;
typedef struct cp_entry_desc {
    void (*dispatch)(void *, cp_call_image *); void *user;
} cp_entry_desc;
void cp_entry_write(unsigned char *code, const cp_entry_desc *desc);
void cp_export_dispatch(void *user, cp_call_image *image);
void *dlsym(void *, const char *);
void cp_invoke(void *entry, cp_context *ctx, const cp_bank *bank);
void cp_native_call(cp_call_image *image);
int cp_invoke_frame(void *entry, size_t bytes, const void *args, size_t arg_bytes, void *result);
typedef struct cp_tls_slot cp_tls_slot;
cp_tls_slot *cp_tls_new(size_t bytes, const void *initial);
void *cp_tls_get(cp_tls_slot *slot, size_t offset);
void cp_tls_destroy(cp_tls_slot *slot);
int cp_try_invoke(void *guard, void *entry, size_t bytes, const void *args, size_t arg_bytes, void *result);
const uint32_t *cp_abi_layout(void);
void *mmap(void *, size_t, int, int, int, long);
int mprotect(void *, size_t, int);
int munmap(void *, size_t);
]]
local M = {}
function M.load(path)
    assert(path, 'direct backend requires an explicitly prebuilt bridge library')
    local lib = ffi.load(path)
    local expected = {2, 11, 8, ffi.sizeof('cp_bank'), ffi.offsetof('cp_bank', 'f'),
        ffi.sizeof('cp_context'), ffi.offsetof('cp_context', 'result'), ffi.sizeof('cp_call_image')}
    for _, field in ipairs {'gpr', 'xmm', 'stack_data', 'stack_size', 'vector_count', 'ret_gpr', 'ret_xmm'} do
        expected[#expected + 1] = ffi.offsetof('cp_call_image', field)
    end
    for _, value in ipairs {ffi.sizeof('cp_vm_call'), ffi.sizeof('cp_export_desc'),
        ffi.offsetof('cp_export_desc', 'finish'), ffi.sizeof('cp_entry_desc')} do expected[#expected + 1] = value end
    local actual = lib.cp_abi_layout()
    for i, value in ipairs(expected) do
        assert(actual[i - 1] == value, 'direct: incompatible native bridge layout at field ' .. i)
    end
    return lib
end
return M
