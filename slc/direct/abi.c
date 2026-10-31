#include "abi.h"
#include <string.h>
#include <stdlib.h>
#include <pthread.h>

/* One platform TLS key per compiled module. Values are byte images of native
 * globals; no language/runtime policy is implemented here. */
struct cp_tls_slot { pthread_key_t key; size_t bytes; unsigned char initial[]; };
cp_tls_slot *cp_tls_new(size_t bytes, const void *initial) {
    if (!bytes || bytes > SIZE_MAX - sizeof(cp_tls_slot)) return NULL;
    cp_tls_slot *slot=malloc(sizeof(*slot)+bytes);
    if (!slot) return NULL;
    if (pthread_key_create(&slot->key,free)) { free(slot); return NULL; }
    slot->bytes=bytes; memcpy(slot->initial,initial,bytes); return slot;
}
void *cp_tls_get(cp_tls_slot *slot, size_t offset) {
    if (!slot || offset>=slot->bytes) return NULL;
    void *value=pthread_getspecific(slot->key);
    if (!value) {
        value=malloc(slot->bytes);
        if (!value) return NULL;
        memcpy(value,slot->initial,slot->bytes);
        if (pthread_setspecific(slot->key,value)) { free(value); return NULL; }
    }
    return (unsigned char *)value+offset;
}
void cp_tls_destroy(cp_tls_slot *slot) {
    if (!slot) return;
    /* Only unpublished modules may be destroyed: no other thread has a value. */
    free(pthread_getspecific(slot->key)); pthread_key_delete(slot->key); free(slot);
}
const uint32_t *cp_abi_layout(void) {
    static const uint32_t layout[] = {
        2, CP_NI, CP_NF, sizeof(cp_bank), offsetof(cp_bank,f),
        sizeof(cp_context), offsetof(cp_context,result), sizeof(cp_call_image),
        offsetof(cp_call_image,gpr), offsetof(cp_call_image,xmm),
        offsetof(cp_call_image,stack_data), offsetof(cp_call_image,stack_size),
        offsetof(cp_call_image,vector_count), offsetof(cp_call_image,ret_gpr),
        offsetof(cp_call_image,ret_xmm), sizeof(cp_vm_call), sizeof(cp_export_desc),
        offsetof(cp_export_desc,finish), sizeof(cp_entry_desc)
    };
    return layout;
}
void cp_invoke(cp_handler *entry, cp_context *ctx, const cp_bank *bank) {
    /* A normal C call INTO the uniform VM ABI, not a cast to a native signature.
     * Clang preserves the SysV caller state around preserve_none automatically. */
    entry(CP_FROM(ctx, *bank));
}
static int invoke_frame(cp_handler *entry, size_t bytes, const void *args, size_t arg_bytes, void *result, void *user, cp_handler *finish) {
    if (arg_bytes > bytes || bytes > (size_t)PTRDIFF_MAX - 16) return -1;
    /* Variable-sized native invocation storage is a platform mechanism. The
     * handler chain must return before this storage goes out of scope. */
    unsigned char *locals = __builtin_alloca_with_align(bytes ? bytes : 16, 128);
    if (arg_bytes) memcpy(locals, args, arg_bytes);
    cp_context ctx = {.locals=locals, .result=result, .user=user};
    cp_bank bank = {0};
    entry(CP_FROM(&ctx, bank));
    if (finish) finish(CP_FROM(&ctx, bank));
    return 0;
}
int cp_invoke_frame(cp_handler *entry, size_t bytes, const void *args, size_t arg_bytes, void *result) {
    return invoke_frame(entry, bytes, args, arg_bytes, result, NULL, NULL);
}
typedef struct try_env {
    cp_handler *entry;
    size_t bytes;
    const void *args;
    size_t arg_bytes;
    void *result;
    int status;
} try_env;
static void try_body(void *raw) {
    try_env *env = raw;
    env->status = cp_invoke_frame(env->entry, env->bytes, env->args, env->arg_bytes, env->result);
}
int cp_try_invoke(cp_try_fn guard, cp_handler *entry, size_t bytes, const void *args, size_t arg_bytes, void *result) {
    try_env env = {entry, bytes, args, arg_bytes, result, -1};
    if (guard(try_body, &env)) return 1;
    return env.status;
}
void cp_export_dispatch(void *user, cp_call_image *image) {
    const cp_export_desc *desc = user;
    if (invoke_frame(desc->entry, desc->frame_bytes, NULL, 0,
            (unsigned char *)image + desc->result_offset, image, desc->finish)) __builtin_trap();
}
void cp_dispatch(const cp_entry_desc *desc, cp_call_image *image) {
    desc->dispatch(desc->user, image);
}
void cp_entry_write(unsigned char code[CP_ENTRY_BYTES], const cp_entry_desc *desc) {
    /* movabs descriptor,%r10; movabs gate,%r11; jmp *%r11.
     * Neither register carries a SysV C argument; AL is untouched. */
    const unsigned char prefix[2] = {0x49, 0xba};
    const unsigned char middle[2] = {0x49, 0xbb};
    const unsigned char jump[3] = {0x41, 0xff, 0xe3};
    uintptr_t d = (uintptr_t)desc, gate = (uintptr_t)cp_native_entry;
    memcpy(code, prefix, 2); memcpy(code + 2, &d, 8);
    memcpy(code + 10, middle, 2); memcpy(code + 12, &gate, 8);
    memcpy(code + 20, jump, 3);
}
