/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "hash_reference.h"
#include <assert.h>
#include <stdio.h>

/* First 16 standard SipHash-2-4 vectors, key bytes 00..0f and message
 * bytes 00..(n-1). Every split must produce the same canonical encoding. */
static const uint64_t vectors[] = {
    UINT64_C(0x726fdb47dd0e0e31), UINT64_C(0x74f839c593dc67fd),
    UINT64_C(0x0d6c8009d9a94f5a), UINT64_C(0x85676696d7fb7e2d),
    UINT64_C(0xcf2794e0277187b7), UINT64_C(0x18765564cd99a68d),
    UINT64_C(0xcbc9466e58fee3ce), UINT64_C(0xab0200f58b01d137),
    UINT64_C(0x93f5f5799a932462), UINT64_C(0x9e0082df0ba9e4b0),
    UINT64_C(0x7a5dbbc594ddb9f3), UINT64_C(0xf4b32f46226bada7),
    UINT64_C(0x751e8fbc860ee5fb), UINT64_C(0x14ea5627c0843d90),
    UINT64_C(0xf723ca908e7af2ee), UINT64_C(0xa129ca6149be45e5)
};
int main(void) {
    uint8_t bytes[1024];
    size_t i, n, split;
    for (i = 0; i < sizeof bytes; i++) bytes[i] = (uint8_t)i;
    for (n = 0; n < 16; n++) for (split = 0; split <= n; split++) {
        ref_hash h;
        ref_hash_init(&h, UINT64_C(0x0706050403020100), UINT64_C(0x0f0e0d0c0b0a0908));
        ref_hash_bytes(&h, bytes, split);
        ref_hash_bytes(&h, NULL, 0);
        ref_hash_bytes(&h, bytes + split, n - split);
        assert(ref_hash_end(&h) == vectors[n]);
    }
    ref_hash h;
    ref_hash_init(&h, UINT64_C(0x0706050403020100), UINT64_C(0x0f0e0d0c0b0a0908));
    ref_hash_u64(&h, UINT64_C(0x0706050403020100));
    assert(ref_hash_end(&h) == vectors[8]);
    /* Also cross multiple blocks and the length-byte wrap with the random key. */
    ref_hash_begin(&h);
    ref_hash_bytes(&h, bytes, sizeof bytes);
    uint64_t expected = ref_hash_end(&h);
    for (split = 0; split <= sizeof bytes; split++) {
        ref_hash_begin(&h);
        ref_hash_bytes(&h, bytes, split);
        ref_hash_bytes(&h, bytes + split, sizeof bytes - split);
        assert(ref_hash_end(&h) == expected);
    }
    puts("map hash: reference vectors and streaming splits passed");
    return 0;
}
