/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* slc runtime: data stacks and traps. See slc_rt.h. */
#include "slc_rt.h"
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <pthread.h>
#include <sys/random.h>

/* every thread has its own data stacks, and so does every task: a worker
 * switches to a task's set while it runs the task */
__thread slc_stackset slc_own_stacks;
__thread slc_stackset *slc_cur_stacks;

void slc_stacks_use(slc_stackset *s) { slc_cur_stacks = s; }

slc_stackset *slc_stacks_current(void) {
    return slc_cur_stacks ? slc_cur_stacks : &slc_own_stacks;
}

/* A caller in the same process (the in-process driver) may catch the traps of
 * plain code on its own thread: slc_try runs body(env) and returns 1 if it
 * trapped. Traps inside tasks, or while a tasks scope is open, still abort:
 * other threads may be in the middle of its work. */
static __thread jmp_buf *trap_jmp;
static __thread const char *trap_what;
static __thread uint64_t trap_map_mark;

void slc_trap(const char *what) {
    if (trap_jmp && slc_trap_recoverable()) {
        trap_what = what;
        /* Release before longjmp, while the map headers in the unwound native
         * frames are still alive. An enclosing try's guards remain active. */
        slc_stacks_unwind(&slc_own_stacks, trap_map_mark);
        longjmp(*trap_jmp, 1);
    }
    fprintf(stderr, "slc runtime check failed: %s\n", what);
    abort();
}

int slc_try(void (*body)(void *), void *env) {
    jmp_buf jb;
    jmp_buf *saved = trap_jmp;
    uint64_t saved_mark = trap_map_mark;
    trap_map_mark = slc_next_token();
    trap_jmp = &jb;
    if (setjmp(jb)) {
        trap_jmp = saved;
        trap_map_mark = saved_mark;
        /* the outermost call gives the thread's data stacks back */
        if (!saved) slc_stacks_clear(&slc_own_stacks);
        return 1;
    }
    body(env);
    trap_jmp = saved;
    trap_map_mark = saved_mark;
    return 0;
}

const char *slc_trap_message(void) { return trap_what; }

uint64_t slc_next_token(void) {
    static uint64_t next = 1;
    uint64_t t = __atomic_fetch_add(&next, 1, __ATOMIC_RELAXED);
    if (t == UINT64_MAX) slc_trap("store tokens exhausted");
    return t;
}

size_t slc_gs_pin(size_t stack, const uint8_t *p, size_t bytes) {
    slc_stack *s = slc_gs(stack);
    uintptr_t at = (uintptr_t)p - (uintptr_t)s->data;
    if (!bytes || !s->data || at >= s->top) return SIZE_MAX;
    if (bytes > s->top - at) slc_trap("data stack source out of range");
    return (size_t)at;
}
/* Const-pointer ABI adaptation only; byte-range composition is SLC. */
void slc_gs_write(size_t stack, size_t dst, const uint8_t *src, size_t bytes) {
    slc_gs_write_bytes(stack, dst, (uint8_t *)(uintptr_t)src, bytes);
}

/* Only process entropy lives here; key encoding and SipHash are SLC words. */
static pthread_once_t hash_once = PTHREAD_ONCE_INIT;
static uint64_t hash_key[2];
static int hash_key_error;
static void hash_seed(void) {
    size_t at = 0;
    while (at < sizeof hash_key) {
        ssize_t n = getrandom((unsigned char *)hash_key + at, sizeof hash_key - at, 0);
        if (n < 0 && errno == EINTR) continue;
        /* Do not trap inside pthread_once: a recoverable longjmp would leave
         * its initialization unfinished. Publish the failure, then report it. */
        if (n <= 0) { hash_key_error = 1; return; }
        at += (size_t)n;
    }
}
uint64_t slc_hash_seed_word(uint32_t index) {
    if (index > 1) slc_trap("Map: invalid hash seed word");
    if (pthread_once(&hash_once, hash_seed) != 0 || hash_key_error)
        slc_trap("Map: cannot obtain a random hash seed");
    return hash_key[index];
}
