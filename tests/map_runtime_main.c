/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "map_reference.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct Entry { uint64_t hash, key, value; } Entry;
static uint64_t hash(uint64_t key) { return (key % 13) | 1; }
static uint32_t find(const slc_map *m, uint64_t key) {
    uint32_t cursor = 0, slot;
    while ((slot = slc_map_probe(m, hash(key), &cursor)) != SLC_NONE)
        if (((Entry *)slc_map_at(m, slot))->key == key) return slot;
    return SLC_NONE;
}
static void put(slc_map *m, uint64_t key, uint64_t value) {
    uint32_t slot = find(m, key);
    if (slot != SLC_NONE) ((Entry *)slc_map_at(m, slot))->value = value;
    else { Entry entry = { hash(key), key, value }; slc_map_insert(m, &entry); }
}
static void blocked_insert(void *p) { put(p, 10000, 1); }
static void blocked_remove(void *p) { slc_map *m = p; slc_map_remove(m, find(m, 42)); }
static void missing_bucket(void *p) { slc_map_at(p, UINT32_MAX); }
static void guarded_failure(void *p) {
    slc_map *m = p;
    (void)slc_map_iter_new(2, m);
    assert(m->iterating == 2);
    blocked_insert(m);
}
static void local_guard_failure(void *unused) {
    (void)unused;
    slc_map local = slc_map_new(2, sizeof(Entry));
    (void)slc_map_iter_new(3, &local);
    slc_trap("unwind local map");
}
static uint32_t rng = 12345;
static uint32_t random_u32(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }
static void exercise(void *unused) {
    (void)unused;
    slc_gs_push(0, 32); /* preserve a preexisting owner's bytes at a nonzero base */
    memset(slc_gs(0)->data, 0xa5, 32);
    slc_map m = slc_map_new(0, sizeof(Entry));
    uint64_t values[512] = { 0 };
    bool present[512] = { false };
    uint32_t round, key, count = 0;
    assert(m.base == 32 && m.len == 0 && find(&m, 1) == SLC_NONE);
    for (round = 0; round < 20000; round++) {
        key = random_u32() % 512;
        if (random_u32() & 1) {
            uint64_t value = random_u32();
            put(&m, key, value);
            if (!present[key]) count++;
            present[key] = true; values[key] = value;
        } else {
            uint32_t slot = find(&m, key);
            assert((slot != SLC_NONE) == present[key]);
            if (present[key]) { slc_map_remove(&m, slot); count--; present[key] = false; }
        }
        assert(m.len == count);
        if (round % 97 == 0) for (key = 0; key < 512; key++) {
            uint32_t slot = find(&m, key);
            assert((slot != SLC_NONE) == present[key]);
            if (present[key]) assert(((Entry *)slc_map_at(&m, slot))->value == values[key]);
        }
    }
    put(&m, 42, 100);
    slc_grow guard = slc_map_iter_new(1, &m);
    put(&m, 42, 101); /* value replacement is not structural */
    assert(slc_try(blocked_insert, &m) == 1);
    assert(strstr(slc_trap_message(), "structural mutation") != NULL);
    assert(find(&m, 10000) == SLC_NONE);
    assert(slc_try(blocked_remove, &m) == 1);
    assert(((Entry *)slc_map_at(&m, find(&m, 42)))->value == 101);
    assert(m.iterating == 1); /* guards outside a nested try stay active */
    assert(slc_try(guarded_failure, &m) == 1);
    assert(m.iterating == 1 && slc_gs_top(2) == 0);
    slc_release(guard.stack, guard.base);
    assert(m.iterating == 0);
    assert(slc_try(local_guard_failure, NULL) == 1);
    assert(slc_gs(3)->map_counter == NULL);
    uint32_t visited = 0, at;
    for (at = 0; at < m.cap; at++) if (((Entry *)slc_map_at(&m, at))->hash) visited++;
    assert(visited == m.len);
    assert(slc_try(missing_bucket, &m) == 1);
    for (key = 0; key < 32; key++) assert(slc_gs(0)->data[key] == 0xa5);
    slc_release(m.stack, m.base);
    assert(slc_gs_top(0) == 32);
}
int main(void) {
    assert(slc_try(exercise, NULL) == 0);
    slc_stacks_free(&slc_own_stacks);
    puts("map runtime: collisions, growth, deletion, reference model and traps passed");
    return 0;
}
