/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "hash_reference.h"
#include <assert.h>
#include <stdio.h>
typedef struct Str { uint8_t *ptr; uint32_t len; } Str;
uint64_t hash_known(void);
uint64_t hash_stream(Str a, Str b);
uint64_t hash_word(Str prefix, uint64_t word);
uint64_t hash_keys(Str text, uint64_t k0, uint64_t k1);
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
    uint32_t i, n, split;
    uint64_t k0 = UINT64_C(0x0706050403020100), k1 = UINT64_C(0x0f0e0d0c0b0a0908);
    for (i = 0; i < sizeof bytes; i++) bytes[i] = (uint8_t)i;
    assert(hash_known() == vectors[0]);
    for (n = 0; n < 16; n++) for (split = 0; split <= n; split++) {
        Str a = { bytes, split }, b = { bytes + split, n - split }, whole = { bytes, n };
        assert(hash_stream(a, b) == vectors[n]);
        assert(hash_keys(whole, k0, k1) == vectors[n]);
    }
    for (n = 0; n < 16; n++) {
        Str prefix = { bytes, n };
        ref_hash reference;
        ref_hash_init(&reference, k0, k1);
        ref_hash_bytes(&reference, bytes, n);
        ref_hash_u64(&reference, UINT64_MAX);
        assert(hash_word(prefix, UINT64_MAX) == ref_hash_end(&reference));
    }
    Str whole = { bytes, sizeof bytes };
    uint64_t expected = hash_keys(whole, k0, k1);
    for (split = 0; split <= sizeof bytes; split++) {
        Str a = { bytes, split }, b = { bytes + split, sizeof bytes - split };
        assert(hash_stream(a, b) == expected);
    }
    puts("SLC SipHash: known/dynamic vectors, streaming splits and word encodings passed");
    return 0;
}
