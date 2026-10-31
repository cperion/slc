/* Direct backend platform mechanism: Linux x86-64 / Clang preserve_none. */
#ifndef SLC_DIRECT_ABI_H
#define SLC_DIRECT_ABI_H
#include <stddef.h>
#include <stdint.h>
#if !defined(__clang__) || !defined(__x86_64__) || !defined(__linux__)
#error "direct backend requires Clang on Linux x86-64"
#endif
#if !__has_attribute(preserve_none) || !__has_attribute(musttail)
#error "direct backend requires preserve_none and musttail"
#endif
#define CP_ABI __attribute__((preserve_none))
#define CP_TAIL __attribute__((musttail)) return
#define CP_NI 11
#define CP_NF 8
typedef uint64_t cp_vec __attribute__((vector_size(16)));
typedef struct cp_bank {
    uint64_t i[CP_NI];
    cp_vec f[CP_NF];
} cp_bank;
typedef struct cp_context {
    unsigned char *locals;
    unsigned char *result;
    void *user;
} cp_context;
#define CP_PARAMS cp_context *ctx, \
    uint64_t i0, uint64_t i1, uint64_t i2, uint64_t i3, uint64_t i4, \
    uint64_t i5, uint64_t i6, uint64_t i7, uint64_t i8, uint64_t i9, uint64_t i10, \
    cp_vec f0, cp_vec f1, cp_vec f2, cp_vec f3, cp_vec f4, cp_vec f5, cp_vec f6, cp_vec f7
#define CP_ARGS ctx, i0,i1,i2,i3,i4,i5,i6,i7,i8,i9,i10, f0,f1,f2,f3,f4,f5,f6,f7
#define CP_SAVE(b) do { \
    (b).i[0]=i0; (b).i[1]=i1; (b).i[2]=i2; (b).i[3]=i3; (b).i[4]=i4; \
    (b).i[5]=i5; (b).i[6]=i6; (b).i[7]=i7; (b).i[8]=i8; (b).i[9]=i9; (b).i[10]=i10; \
    (b).f[0]=f0; (b).f[1]=f1; (b).f[2]=f2; (b).f[3]=f3; \
    (b).f[4]=f4; (b).f[5]=f5; (b).f[6]=f6; (b).f[7]=f7; \
} while (0)
#define CP_FROM(ctx,b) ctx, \
    (b).i[0],(b).i[1],(b).i[2],(b).i[3],(b).i[4],(b).i[5], \
    (b).i[6],(b).i[7],(b).i[8],(b).i[9],(b).i[10], \
    (b).f[0],(b).f[1],(b).f[2],(b).f[3],(b).f[4],(b).f[5],(b).f[6],(b).f[7]
typedef void CP_ABI cp_handler(CP_PARAMS);
void cp_invoke(cp_handler *entry, cp_context *ctx, const cp_bank *bank);
int cp_invoke_frame(cp_handler *entry, size_t bytes, const void *args, size_t arg_bytes, void *result);
typedef struct cp_tls_slot cp_tls_slot;
cp_tls_slot *cp_tls_new(size_t bytes, const void *initial);
void *cp_tls_get(cp_tls_slot *slot, size_t offset);
void cp_tls_destroy(cp_tls_slot *slot);
typedef int (*cp_try_fn)(void (*body)(void *), void *env);
int cp_try_invoke(cp_try_fn guard, cp_handler *entry, size_t bytes, const void *args, size_t arg_bytes, void *result);
/* ABI revision and layout fingerprint checked by the Lua loader. */
const uint32_t *cp_abi_layout(void);

/* Layout shared with the gates through generated offsetof constants. Stack bytes
 * are prelaid by the caller; stack_size includes argument padding, not return PC.
 * Supported native arguments have alignment <= 16; the planner rejects others. */
typedef struct cp_call_image {
    void *target;
    uint64_t gpr[6];
    cp_vec xmm[8];
    const unsigned char *stack_data;
    size_t stack_size;
    uint8_t vector_count;
    uint64_t ret_gpr[2];
    cp_vec ret_xmm[2];
} cp_call_image;
void cp_native_call(cp_call_image *image);
typedef struct cp_vm_call {
    cp_handler *entry;
    size_t frame_bytes;
    const void *args;
    size_t arg_bytes;
    void *result;
} cp_vm_call;
typedef struct cp_export_desc {
    cp_handler *entry;
    size_t frame_bytes;
    size_t result_offset;
    cp_handler *finish;
} cp_export_desc;
void cp_export_dispatch(void *user, cp_call_image *image);
typedef void (*cp_dispatch_fn)(void *user, cp_call_image *image);
typedef struct cp_entry_desc {
    cp_dispatch_fn dispatch;
    void *user;
} cp_entry_desc;
void cp_dispatch(const cp_entry_desc *desc, cp_call_image *image);
void cp_native_entry(void); /* entered only through the generated native stub */
/* Emit a native entry stub to a caller-owned writable buffer; publish separately.
 * The descriptor and code must outlive every caller, including escaped callbacks. */
#define CP_ENTRY_BYTES 23
void cp_entry_write(unsigned char code[CP_ENTRY_BYTES], const cp_entry_desc *desc);
#endif
