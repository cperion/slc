/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* slc runtime: data stacks and traps. See slc_rt.h. */
#include "slc_rt.h"
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* every thread has its own data stacks, and so does every task: a worker
 * switches to a task's set while it runs the task */
__thread slc_stackset slc_own_stacks;
__thread slc_stackset *slc_cur_stacks;

void slc_stacks_use(slc_stackset *s) { slc_cur_stacks = s; }

void slc_stacks_free(slc_stackset *s) {
    size_t i;
    for (i = 0; i < s->n; i++) free(s->stacks[i].data);
    free(s->stacks);
    s->stacks = NULL;
    s->n = 0;
}

slc_stack *slc_gs_slow(size_t i) {
    slc_stackset *set = slc_cur_stacks ? slc_cur_stacks : &slc_own_stacks;
    if (i >= set->n) {
        size_t n = set->n ? set->n : 4;
        while (n <= i) n *= 2;
        slc_stack *s = realloc(set->stacks, n * sizeof *s);
        if (!s) slc_trap("out of memory for data stacks");
        memset(s + set->n, 0, (n - set->n) * sizeof *s);
        set->stacks = s;
        set->n = n;
    }
    return &set->stacks[i];
}


static void reserve(slc_stack *s, size_t need) {
    if (need <= s->cap) return;
    size_t cap = s->cap ? s->cap : 256;
    while (cap < need) {
        if (cap > SIZE_MAX / 2) slc_trap("data stack too large");
        cap *= 2;
    }
    unsigned char *d = realloc(s->data, cap);
    if (!d) slc_trap("out of memory for a data stack");
    s->data = d;
    s->cap = cap;
}

size_t slc_gs_begin(size_t i) {
    slc_stack *s = slc_gs(i);
    size_t top = (s->top + 15u) & ~(size_t)15u;
    reserve(s, top);
    s->top = top;
    return top;
}

size_t slc_gs_push(size_t i, size_t n) {
    slc_stack *s = slc_gs(i);
    size_t at = s->top;
    if (n > SIZE_MAX - at) slc_trap("data stack too large");
    reserve(s, at + n);
    s->top = at + n;
    return at;
}

/* A caller in the same process (the in-process driver) may catch the traps of
 * plain code on its own thread: slc_try runs body(env) and returns 1 if it
 * trapped. Traps inside tasks, or while a tasks scope is open, still abort:
 * other threads may be in the middle of its work. */
static __thread jmp_buf *trap_jmp;
static __thread const char *trap_what;

void slc_trap(const char *what) {
    if (trap_jmp && slc_trap_recoverable()) {
        trap_what = what;
        longjmp(*trap_jmp, 1);
    }
    fprintf(stderr, "slc runtime check failed: %s\n", what);
    abort();
}

int slc_try(void (*body)(void *), void *env) {
    jmp_buf jb;
    jmp_buf *saved = trap_jmp;
    trap_jmp = &jb;
    if (setjmp(jb)) {
        size_t i;
        trap_jmp = saved;
        /* the outermost call gives the thread's data stacks back */
        if (!saved) for (i = 0; i < slc_own_stacks.n; i++) slc_own_stacks.stacks[i].top = 0;
        return 1;
    }
    body(env);
    trap_jmp = saved;
    return 0;
}

const char *slc_trap_message(void) { return trap_what; }

uint64_t slc_next_token(void) {
    static uint64_t next = 1;
    uint64_t t = __atomic_fetch_add(&next, 1, __ATOMIC_RELAXED);
    if (t == UINT64_MAX) slc_trap("store tokens exhausted");
    return t;
}

/* text ------------------------------------------------------------------------------------- */

void slc_grow_write_bytes(slc_grow *g, const uint8_t *p, uint32_t n) {
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

void slc_grow_write_u64(slc_grow *g, uint64_t v) {
    uint8_t buf[20];
    uint32_t n = 0;
    do { buf[sizeof buf - 1 - n++] = (uint8_t)('0' + v % 10u); v /= 10u; } while (v);
    slc_grow_write_bytes(g, buf + sizeof buf - n, n);
}

void slc_grow_write_i64(slc_grow *g, int64_t v) {
    if (v < 0) {
        slc_grow_write_bytes(g, (const uint8_t *)"-", 1);
        slc_grow_write_u64(g, (uint64_t)0 - (uint64_t)v);
    } else {
        slc_grow_write_u64(g, (uint64_t)v);
    }
}

void slc_grow_write_bool(slc_grow *g, bool v) {
    if (v) slc_grow_write_bytes(g, (const uint8_t *)"true", 4);
    else slc_grow_write_bytes(g, (const uint8_t *)"false", 5);
}

uint32_t slc_format_f64(char *buf, double v) {
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

void slc_grow_write_f64(slc_grow *g, double v) {
    char buf[32];
    uint32_t n = slc_format_f64(buf, v);
    slc_grow_write_bytes(g, (const uint8_t *)buf, n);
}

void slc_grow_clear(slc_grow *g) {
    slc_gs_reset(g->stack, g->base);
    g->len = 0;
}

uint32_t slc_chars_fill(uint8_t *dst, uint32_t cap, const uint8_t *p, uint32_t n) {
    if (n > cap) slc_trap("text longer than its Chars(n)");
    memcpy(dst, p, n);
    return n;
}

uint32_t slc_strlen(const char *s) {
    size_t n = strlen(s);
    if (n > UINT32_MAX) slc_trap("a C string longer than a Str can view");
    return (uint32_t)n;
}
