/* Control: manually fuse decoding and consumption, removing the ordinary C API
 * boundary. No intrinsics, compiler attributes, altered validation or fewer reads. */
#include "baseline.h"
uint64_t c_visit_fused(U8Slice input) {
    if (input.len < 8) return 0;
    uint32_t version = input.ptr[0];
    uint32_t flags = input.ptr[1];
    uint32_t sequence = ((uint32_t)input.ptr[2] << 24) | ((uint32_t)input.ptr[3] << 16)
        | ((uint32_t)input.ptr[4] << 8) | input.ptr[5];
    uint32_t length = ((uint32_t)input.ptr[6] << 8) | input.ptr[7];
    if (version != 1 || flags > 3 || length > 4096) return 0;
    uint32_t consumed = 8 + length;
    if (input.len < consumed) return 0;
    uint32_t checksum = sequence;
    for (uint32_t i = 0; i < length; ++i) checksum += input.ptr[8 + i];
    return ((uint64_t)consumed << 32) + checksum;
}
