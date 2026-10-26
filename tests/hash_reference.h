/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* Test-only oracle retained from the former runtime implementation. Production
 * key encoding and SipHash live in lib/key.slc and lib/hash.slc. */
#ifndef SLC_TEST_HASH_REFERENCE_H
#define SLC_TEST_HASH_REFERENCE_H
#include "slc_rt.h"
typedef struct ref_hash {
    uint64_t v0, v1, v2, v3, tail, length;
    uint32_t used;
} ref_hash;
static inline uint64_t ref_hash_rot(uint64_t x, unsigned n) { return (x << n) | (x >> (64 - n)); }
static inline void ref_hash_round(ref_hash *h) {
    h->v0 += h->v1; h->v1 = ref_hash_rot(h->v1, 13); h->v1 ^= h->v0; h->v0 = ref_hash_rot(h->v0, 32);
    h->v2 += h->v3; h->v3 = ref_hash_rot(h->v3, 16); h->v3 ^= h->v2;
    h->v0 += h->v3; h->v3 = ref_hash_rot(h->v3, 21); h->v3 ^= h->v0;
    h->v2 += h->v1; h->v1 = ref_hash_rot(h->v1, 17); h->v1 ^= h->v2; h->v2 = ref_hash_rot(h->v2, 32);
}
static inline void ref_hash_block(ref_hash *h, uint64_t word) {
    h->v3 ^= word; ref_hash_round(h); ref_hash_round(h); h->v0 ^= word;
}
static inline void ref_hash_init(ref_hash *h, uint64_t k0, uint64_t k1) {
    h->v0 = UINT64_C(0x736f6d6570736575) ^ k0;
    h->v1 = UINT64_C(0x646f72616e646f6d) ^ k1;
    h->v2 = UINT64_C(0x6c7967656e657261) ^ k0;
    h->v3 = UINT64_C(0x7465646279746573) ^ k1;
    h->tail = h->length = 0; h->used = 0;
}
static inline void ref_hash_begin(ref_hash *h) {
    uint64_t k0 = slc_hash_seed_word(0), k1 = slc_hash_seed_word(1);
    ref_hash_init(h, k0, k1);
}
static inline void ref_hash_bytes(ref_hash *h, const uint8_t *p, size_t n) {
    size_t i;
    h->length += (uint64_t)n;
    for (i = 0; i < n; i++) {
        h->tail |= (uint64_t)p[i] << (8 * h->used);
        if (++h->used == 8) { ref_hash_block(h, h->tail); h->tail = 0; h->used = 0; }
    }
}
static inline void ref_hash_u64(ref_hash *h, uint64_t v) {
    uint8_t bytes[8]; unsigned i;
    for (i = 0; i < 8; i++) bytes[i] = (uint8_t)(v >> (8 * i));
    ref_hash_bytes(h, bytes, 8);
}
static inline uint64_t ref_hash_end(ref_hash *h) {
    ref_hash_block(h, h->tail | ((h->length & 255) << 56));
    h->v2 ^= 255;
    ref_hash_round(h); ref_hash_round(h); ref_hash_round(h); ref_hash_round(h);
    return h->v0 ^ h->v1 ^ h->v2 ^ h->v3;
}
#endif
