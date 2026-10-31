/* Backend instruction mechanisms, not library algorithms. The uniform signature
 * is the register bank; no handler accepts a per-instruction register mapping.
 * This first pack establishes glue/relocation behavior before IR integration. */
#include "abi.h"
#include <string.h>
extern cp_handler NEXT, ZERO;
extern unsigned char IMM;

void CP_ABI cp_add_imm(CP_PARAMS) {
    i0 += (uintptr_t)&IMM;
    CP_TAIL NEXT(CP_ARGS);
}
void CP_ABI cp_mul_imm(CP_PARAMS) {
    i0 *= (uintptr_t)&IMM;
    CP_TAIL NEXT(CP_ARGS);
}
void CP_ABI cp_test_zero(CP_PARAMS) {
    if (i0 == 0) { CP_TAIL ZERO(CP_ARGS); }
    CP_TAIL NEXT(CP_ARGS);
}
void CP_ABI cp_sum_step(CP_PARAMS) {
    i1 += i0; --i0;
    CP_TAIL NEXT(CP_ARGS);
}
void CP_ABI cp_finish(CP_PARAMS) {
    cp_bank b = {0}; CP_SAVE(b); memcpy(ctx->result,&b,sizeof b);
}
void CP_ABI cp_call_native(CP_PARAMS) {
    cp_bank saved = {0}; CP_SAVE(saved);
    cp_call_image *image=ctx->user;
    cp_native_call(image);
    saved.i[0]=image->ret_gpr[0];
    CP_TAIL NEXT(CP_FROM(ctx,saved));
}
