/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* Historical test oracle only. Production algorithms are lib/map.slc. */
#ifndef SLC_TEST_MAP_REFERENCE_H
#define SLC_TEST_MAP_REFERENCE_H
#include "slc_rt.h"
#include <string.h>
static inline uint64_t map_hash(const void *entry) {
    uint64_t h;
    memcpy(&h, entry, sizeof h);
    return h;
}
static inline uint32_t map_distance(uint64_t hash, uint32_t slot, uint32_t cap) {
    return (slot - (uint32_t)hash) & (cap - 1);
}
static inline uint32_t slc_map_probe(const slc_map *m, uint64_t hash, uint32_t *cursor) {
    hash |= 1;
    while (*cursor < m->cap) {
        uint32_t distance = (*cursor)++;
        uint32_t slot = ((uint32_t)hash + distance) & (m->cap - 1);
        uint64_t found = map_hash(slc_map_at(m, slot));
        if (!found || map_distance(found, slot, m->cap) < distance) break;
        if (found == hash) return slot;
    }
    *cursor = m->cap;
    return SLC_NONE;
}
static inline size_t map_bytes(const slc_map *m, uint32_t cap) {
    if ((size_t)cap + 1 > SIZE_MAX / m->width) slc_trap("Map is full");
    return ((size_t)cap + 1) * m->width;
}
static inline void map_top(const slc_map *m) {
    size_t bytes = m->cap ? map_bytes(m, m->cap) : 0;
    if (slc_gs_top(m->stack) - m->base != bytes)
        slc_trap("Map grew while it was not at the top of its data stack");
}
static inline void map_insert_raw(slc_map *m, const void *entry) {
    unsigned char *scratch = slc_gs(m->stack)->data + m->base + (size_t)m->cap * m->width;
    uint32_t distance = 0, slot;
    uint64_t hash = map_hash(entry) | 1;
    memcpy(scratch, entry, m->width);
    memcpy(scratch, &hash, sizeof hash);
    slot = (uint32_t)hash & (m->cap - 1);
    for (;;) {
        unsigned char *bucket = slc_map_at(m, slot);
        uint64_t old = map_hash(bucket);
        if (!old) { memcpy(bucket, scratch, m->width); m->len++; return; }
        uint32_t prior = map_distance(old, slot, m->cap);
        if (prior < distance) {
            size_t i;
            for (i = 0; i < m->width; i++) {
                unsigned char byte = bucket[i]; bucket[i] = scratch[i]; scratch[i] = byte;
            }
            distance = prior;
        }
        slot = (slot + 1) & (m->cap - 1);
        distance++;
    }
}
static inline void map_grow(slc_map *m) {
    uint32_t i, cap;
    if (m->cap >= UINT32_C(0x80000000)) slc_trap("Map is full");
    cap = m->cap ? m->cap * 2 : 8;
    size_t bytes = map_bytes(m, cap);
    slc_map next = *m;
    next.base = slc_gs_push(m->stack, bytes);
    next.cap = cap; next.len = 0;
    memset(slc_gs(m->stack)->data + next.base, 0, bytes);
    for (i = 0; i < m->cap; i++) {
        void *entry = slc_map_at(m, i);
        if (map_hash(entry)) map_insert_raw(&next, entry);
    }
    slc_stack *stack = slc_gs(m->stack);
    memmove(stack->data + m->base, stack->data + next.base, bytes);
    stack->top = m->base + bytes;
    m->cap = cap;
}
static inline void slc_map_insert(slc_map *m, const void *entry) {
    if (m->iterating) slc_trap("Map structural mutation during iteration");
    map_top(m);
    /* entry is an adapter's by-value local, never a movable bucket address. */
    if (!m->cap || m->len >= m->cap - m->cap / 8) map_grow(m);
    map_insert_raw(m, entry);
}
static inline void slc_map_remove(slc_map *m, uint32_t slot) {
    if (m->iterating) slc_trap("Map structural mutation during iteration");
    if (!map_hash(slc_map_at(m, slot))) slc_trap("Map: removing an empty bucket");
    for (;;) {
        uint32_t next = (slot + 1) & (m->cap - 1);
        void *entry = slc_map_at(m, next);
        uint64_t hash = map_hash(entry);
        if (!hash || !map_distance(hash, next, m->cap)) break;
        memcpy(slc_map_at(m, slot), entry, m->width);
        slot = next;
    }
    memset(slc_map_at(m, slot), 0, m->width);
    m->len--;
}

static inline slc_strkey strmap_header(const slc_strmap *m, uint32_t slot) {
    slc_strkey key;
    memcpy(&key, slc_map_at(&m->entries, slot), sizeof key);
    return key;
}
static inline const uint8_t *slc_strmap_key(const slc_strmap *m, uint32_t slot) {
    slc_strkey key = strmap_header(m, slot);
    if (!key.len) return NULL;
    return slc_gs(m->arena_stack)->data + m->arena_base + key.offset;
}
static inline uint32_t slc_strmap_find(const slc_strmap *m, const uint8_t *key, uint32_t len, uint64_t hash) {
    uint32_t slot, cursor = 0;
    while ((slot = slc_map_probe(&m->entries, hash, &cursor)) != SLC_NONE) {
        slc_strkey found = strmap_header(m, slot);
        if (found.len == len && (!len || memcmp(slc_strmap_key(m, slot), key, len) == 0)) return slot;
    }
    return SLC_NONE;
}
static inline size_t strmap_append(slc_strmap *m, const uint8_t *key, uint32_t len) {
    slc_stack *s = slc_gs(m->arena_stack);
    uintptr_t from = (uintptr_t)key - (uintptr_t)s->data;
    int inside = len && s->data && from < s->top;
    size_t offset;
    if (s->top - m->arena_base != m->arena_len)
        slc_trap("StrMap grew while its arena was not at the top of its data stack");
    /* Rebuild before more arena growth when dead storage is substantial.
     * Include the pending key while old bytes still exist: it may itself be
     * a subview of an old key. No allocation occurs after offsets change. */
    if (m->dead >= 4096 && m->dead >= m->arena_len / 2) {
        size_t live = m->arena_len - m->dead, out = 0, bytes;
        uint32_t i;
        if (len > SIZE_MAX - live) slc_trap("StrMap key arena is full");
        bytes = live + len;
        size_t fresh = slc_gs_push(m->arena_stack, bytes);
        s = slc_gs(m->arena_stack);
        if (inside) key = s->data + (size_t)from;
        for (i = 0; i < m->entries.cap; i++) {
            void *entry = slc_map_at(&m->entries, i);
            slc_strkey old;
            memcpy(&old, entry, sizeof old);
            if (!old.hash) continue;
            if (old.len) memcpy(s->data + fresh + out, s->data + m->arena_base + old.offset, old.len);
            old.offset = out;
            out += old.len;
            memcpy(entry, &old, sizeof old);
        }
        offset = out;
        if (len) memmove(s->data + fresh + out, key, len);
        if (bytes) memmove(s->data + m->arena_base, s->data + fresh, bytes);
        s->top = m->arena_base + bytes;
        m->arena_len = bytes;
        m->dead = len; /* pending insertion not yet owned by an entry */
    } else {
        offset = m->arena_len;
        slc_gs_push(m->arena_stack, len);
        s = slc_gs(m->arena_stack);
        if (inside) key = s->data + (size_t)from;
        if (len) memmove(s->data + m->arena_base + offset, key, len);
        m->arena_len += len;
        m->dead += len;
    }
    return offset;
}
static inline void slc_strmap_insert(slc_strmap *m, const uint8_t *key, uint32_t len, void *entry, uint64_t hash) {
    slc_strkey header = { 0 };
    if (m->entries.iterating) slc_trap("Map structural mutation during iteration");
    map_top(&m->entries);
    header.hash = hash | 1;
    header.len = len;
    /* Copy before table growth: key may point into an existing Chars value in
     * the table. The adapter's new value is already a by-value local. */
    header.offset = strmap_append(m, key, len);
    memcpy(entry, &header, sizeof header);
    slc_map_insert(&m->entries, entry);
    m->dead -= len;
}
static inline void slc_strmap_remove(slc_strmap *m, uint32_t slot) {
    slc_strkey key = strmap_header(m, slot);
    slc_map_remove(&m->entries, slot); /* checks the guard before changing anything */
    m->dead += key.len;
    if (!m->entries.len) {
        slc_gs_reset(m->arena_stack, m->arena_base);
        m->arena_len = m->dead = 0;
    }
}


#endif
