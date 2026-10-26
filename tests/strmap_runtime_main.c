/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "hash_reference.h"
#include "map_reference.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct Entry { slc_strkey key; uint64_t value; } Entry;
static Entry *at(slc_strmap *m, uint32_t slot) { return slc_map_at(&m->entries, slot); }
/* The storage harness supplies its hash explicitly, just as the SLC library does. */
static uint64_t hash_key(const uint8_t *key, uint32_t len) {
    ref_hash h; ref_hash_begin(&h); ref_hash_u64(&h, len);
    ref_hash_bytes(&h, key, len); return ref_hash_end(&h) | 1;
}
static uint32_t find_key(const slc_strmap *m, const uint8_t *key, uint32_t len) {
    return slc_strmap_find(m, key, len, hash_key(key, len));
}
static void put(slc_strmap *m, const uint8_t *key, uint32_t len, uint64_t value) {
    uint32_t slot = find_key(m, key, len);
    if (slot == SLC_NONE) {
        Entry e = { { 0, 0, 0 }, 0 }; e.value = value;
        slc_strmap_insert(m, key, len, &e, hash_key(key, len));
    } else at(m, slot)->value = value;
}
static int remove_key(slc_strmap *m, const uint8_t *key, uint32_t len) {
    uint32_t slot = find_key(m, key, len);
    if (slot == SLC_NONE) return 0;
    slc_strmap_remove(m, slot); return 1;
}
static uint64_t get(slc_strmap *m, const uint8_t *key, uint32_t len) {
    uint32_t slot = find_key(m, key, len);
    assert(slot != SLC_NONE); return at(m, slot)->value;
}
static void blocked(void *p) { put(p, (const uint8_t *)"new", 3, 4); }
static uint32_t rng = 98765;
static uint32_t random_u32(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }
static void exercise(void *unused) {
    (void)unused;
    slc_gs_push(0, 16); slc_gs_push(1, 32);
    memset(slc_gs(0)->data, 0x55, 16); memset(slc_gs(1)->data, 0xaa, 32);
    slc_strmap m = slc_strmap_new(0, 1, sizeof(Entry));
    uint8_t keys[128][64];
    uint32_t lens[128], i, j, count = 0;
    uint64_t values[128] = { 0 };
    bool present[128] = { false };
    for (i = 0; i < 128; i++) {
        lens[i] = i ? i % 32 + 1 : 0;
        for (j = 0; j < 64; j++) keys[i][j] = j % 3 ? (uint8_t)j : (uint8_t)i;
    }
    assert(find_key(&m, NULL, 0) == SLC_NONE);
    for (i = 0; i < 20000; i++) {
        uint32_t key = random_u32() % 128;
        if (random_u32() & 1) {
            uint8_t source[64]; memcpy(source, keys[key], 64);
            uint64_t value = random_u32();
            put(&m, source, lens[key], value);
            memset(source, 0xff, 64); /* map must own its own copy */
            if (!present[key]) count++;
            present[key] = true; values[key] = value;
        } else {
            assert(remove_key(&m, keys[key], lens[key]) == present[key]);
            if (present[key]) count--;
            present[key] = false;
        }
        assert(m.entries.len == count);
        if (i % 97 == 0) for (j = 0; j < 128; j++) {
            uint32_t slot = find_key(&m, keys[j], lens[j]);
            assert((slot != SLC_NONE) == present[j]);
            if (present[j]) assert(at(&m, slot)->value == values[j]);
        }
        /* Dead history is bounded even with a permanently nonempty table. */
        assert(m.arena_len < 16384);
    }
    for (j = 0; j < 128; j++) remove_key(&m, keys[j], lens[j]);
    assert(m.entries.len == 0 && m.arena_len == 0 && m.dead == 0);
    put(&m, NULL, 0, 99); assert(get(&m, NULL, 0) == 99);
    remove_key(&m, NULL, 0);

    uint8_t large[6000], garbage[8192];
    for (i = 0; i < sizeof large; i++) large[i] = (uint8_t)(i % 251);
    memset(garbage, 'g', sizeof garbage);
    put(&m, large, sizeof large, 1);
    uint32_t slot = find_key(&m, large, sizeof large);
    const uint8_t *view = slc_strmap_key(&m, slot) + 1;
    put(&m, view, 5000, 2); /* source is in an arena that grows */
    assert(get(&m, large + 1, 5000) == 2);
    put(&m, garbage, sizeof garbage, 3);
    garbage[0] = 'h'; put(&m, garbage, sizeof garbage, 4);
    garbage[0] = 'g'; remove_key(&m, garbage, sizeof garbage);
    garbage[0] = 'h'; remove_key(&m, garbage, sizeof garbage);
    assert(m.dead >= 4096 && m.dead >= m.arena_len / 2);
    slot = find_key(&m, large, sizeof large);
    view = slc_strmap_key(&m, slot) + 2;
    put(&m, view, 4000, 5); /* source is in an arena that compacts */
    assert(get(&m, large + 2, 4000) == 5);
    assert(get(&m, large + 1, 5000) == 2 && get(&m, large, sizeof large) == 1);
    assert(m.dead == 0 && m.arena_len == 15000);

    /* A key can also be borrowed from a value in the table being grown. */
    slc_strmap table_alias = slc_strmap_new(2, 3, sizeof(Entry));
    for (i = 0; i < 7; i++) put(&table_alias, (uint8_t *)&i, sizeof i, UINT64_C(0x0123456789abcdef));
    i = 0; slot = find_key(&table_alias, (uint8_t *)&i, sizeof i);
    uint8_t expected[8]; memcpy(expected, &at(&table_alias, slot)->value, 8);
    view = (uint8_t *)&at(&table_alias, slot)->value;
    put(&table_alias, view, 8, 77);
    assert(table_alias.entries.cap == 16 && get(&table_alias, expected, 8) == 77);
    slc_release(table_alias.arena_stack, table_alias.arena_base);
    slc_release(table_alias.entries.stack, table_alias.entries.base);

    slc_grow guard = slc_map_iter_new(2, &m.entries);
    size_t bytes = m.arena_len;
    assert(slc_try(blocked, &m) == 1);
    assert(m.arena_len == bytes && m.entries.iterating == 1);
    slc_release(guard.stack, guard.base);
    for (i = 0; i < 16; i++) assert(slc_gs(0)->data[i] == 0x55);
    for (i = 0; i < 32; i++) assert(slc_gs(1)->data[i] == 0xaa);
    slc_release(m.arena_stack, m.arena_base);
    slc_release(m.entries.stack, m.entries.base);
    assert(slc_gs_top(0) == 16 && slc_gs_top(1) == 32);
}
int main(void) {
    assert(slc_try(exercise, NULL) == 0);
    slc_stacks_free(&slc_own_stacks);
    puts("StrMap runtime: owned bytes, NULs, model, growth, compaction, aliases and guards passed");
    return 0;
}
