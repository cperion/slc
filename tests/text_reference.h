/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* Historical oracle only. Production text policy is in lib/storage.slc and lib/format.slc. */
#ifndef SLC_TEXT_REFERENCE_H
#define SLC_TEXT_REFERENCE_H
#include "slc_rt.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static inline void slc_grow_write_bytes(slc_grow *g, const uint8_t *p, uint32_t n) {
    slc_stack *s = slc_gs(g->stack);
    size_t at, from = 0;
    uintptr_t offset;
    int inside;
    if (n == 0) return;
    if (s->top != g->base + (size_t)g->len) slc_trap("Text grew while it was not at the top of its data stack");
    if (n > UINT32_MAX - g->len) slc_trap("Text is full");
    /* The supported flat-address targets preserve addresses in uintptr_t.
     * Compare integers: p may name an unrelated literal or formatting buffer,
     * so ordering/subtracting the pointers themselves would be undefined.
     * If it names this stack, save its offset before growth can move it. */
    offset = (uintptr_t)p - (uintptr_t)s->data;
    inside = s->data && offset < s->top;
    if (inside) from = (size_t)offset;
    at = slc_gs_push(g->stack, n);
    s = slc_gs(g->stack);
    if (inside) p = s->data + from;
    memmove(s->data + at, p, n);
    g->len += n;
}

static inline uint32_t slc_format_f64(char *buf, double v) {
    int p;
    if (v != v) { memcpy(buf, "nan", 4); return 3; }
    if (v == 1.0 / 0.0) { memcpy(buf, "inf", 4); return 3; }
    if (v == -1.0 / 0.0) { memcpy(buf, "-inf", 5); return 4; }
    for (p = 1; p <= 17; p++) {
        snprintf(buf, 32, "%.*g", p, v);
        if (strtod(buf, NULL) == v) break;
    }
    return (uint32_t)strlen(buf);
}

static inline void slc_grow_write_f64(slc_grow *g, double v) {
    char buf[32];
    uint32_t n = slc_format_f64(buf, v);
    slc_grow_write_bytes(g, (const uint8_t *)buf, n);
}

static inline void slc_grow_clear(slc_grow *g) {
    slc_gs_reset(g->stack, g->base);
    g->len = 0;
}

#endif
