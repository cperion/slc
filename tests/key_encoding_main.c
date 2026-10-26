/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "hash_reference.h"
#include <assert.h>
#include <stdio.h>
typedef struct Str { uint8_t *ptr; uint32_t len; } Str;
uint64_t semantic_key_hash(int64_t n, bool flag, Str text, bool number);
int main(void) {
    uint8_t bytes[] = { 'a', 0, 'b' };
    Str text = { bytes, sizeof bytes };
    const int64_t values[] = { INT64_MIN, -1, 0, INT64_MAX };
    unsigned i, flag, number;
    for (i = 0; i < sizeof values / sizeof values[0]; i++)
        for (flag = 0; flag < 2; flag++) for (number = 0; number < 2; number++) {
            ref_hash h; ref_hash_init(&h, 0, 1);
            ref_hash_u64(&h, (uint64_t)values[i]);
            ref_hash_u64(&h, flag);
            ref_hash_u64(&h, text.len);
            ref_hash_bytes(&h, text.ptr, text.len);
            ref_hash_u64(&h, number);
            if (number) ref_hash_u64(&h, 7);
            assert(semantic_key_hash(values[i], flag != 0, text, number != 0) == ref_hash_end(&h));
        }
    puts("semantic keys: known/dynamic records, signed extrema, Bool, Chars and sums passed");
    return 0;
}
