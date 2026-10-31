/* Build-time layout emitter: the C definition is authoritative for the gates. */
#include "abi.h"
#include <stdio.h>
#define OFF(name, field) printf("#define " #name " %zu\n", offsetof(cp_call_image, field))
int main(void) {
    OFF(CP_TARGET, target); OFF(CP_GPR, gpr); OFF(CP_XMM, xmm);
    OFF(CP_STACK_DATA, stack_data); OFF(CP_STACK_SIZE, stack_size);
    OFF(CP_VECTOR_COUNT, vector_count); OFF(CP_RET_GPR, ret_gpr); OFF(CP_RET_XMM, ret_xmm);
    printf("#define CP_IMAGE_SIZE %zu\n", sizeof(cp_call_image));
    printf("#define CP_BANK_I %zu\n", offsetof(cp_bank, i));
    printf("#define CP_BANK_F %zu\n", offsetof(cp_bank, f));
    printf("#define CP_CTX_RESULT %zu\n", offsetof(cp_context, result));
    _Static_assert(sizeof(cp_call_image) % 16 == 0, "image alignment");
    _Static_assert(sizeof(cp_vec) == 16, "SIMD width");
    return 0;
}
