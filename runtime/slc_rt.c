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
