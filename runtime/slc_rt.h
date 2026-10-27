/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* slc runtime: Goose-style data stacks, managed stores, generational IDs.
 *
 * A data stack is a growable byte buffer. Every resizable value (a store, a
 * Grow array) occupies the top of the data stack the compiler assigned to it;
 * it is the only live growing value on that stack, so it can always grow in
 * place. Scopes give the space back by resetting the top.
 *
 * Stacks are addressed by index. A function receives a base index (gs_sp) and
 * uses gs_sp + k for its k-th live resizable local, so callees never share a
 * stack with a caller's live growing values. Exported functions start at 0.
 *
 * Contents are addressed by offset, never by pointer: growth may move a buffer.
 */
#ifndef SLC_RT_H
#define SLC_RT_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

/* helpers the compiler emits per element type: not all are used by every program */
#if defined(__GNUC__) || defined(__clang__)
#define SLC_HELPER static inline __attribute__((unused))
#define SLC_NORETURN __attribute__((noreturn))
#define SLC_COLD __attribute__((cold, noreturn))
#else
#define SLC_HELPER static inline
#define SLC_NORETURN
#define SLC_COLD
#endif

typedef struct slc_stack {
    unsigned char *data;
    size_t top;
    size_t cap;
    /* An iteration guard owns its own data stack. Resetting that stack
     * releases the borrow, including returns and residual loop exits. */
    uint32_t *map_counter;
    size_t map_guard_base;
    uint64_t map_guard_token;
} slc_stack;

/* a failed runtime check: invalid ID, misuse of a growing value */
SLC_NORETURN void slc_trap(const char *what);
/* for in-process callers: run body(env); 1 if plain code on this thread trapped
 * (slc_trap_message says why), 0 if it returned */
int slc_try(void (*body)(void *), void *env);
const char *slc_trap_message(void);
/* whether a trap here can return to slc_try: not in a task, no scope open */
int slc_trap_recoverable(void);

/* the data stacks of a thread or a task */
typedef struct slc_stackset { slc_stack *stacks; size_t n; } slc_stackset;

/* the stack set in use on this thread: a task's while a worker runs it,
 * otherwise (NULL) the thread's own */
extern __thread slc_stackset slc_own_stacks;
extern __thread slc_stackset *slc_cur_stacks;
/* the stack with index i, made on first use (out of line) */
slc_stack *slc_gs_slow(size_t i);

/* TLS selection is native; stack growth/access policy is ordinary SLC. */
slc_stackset *slc_stacks_current(void);
slc_stack *slc_gs(size_t i);
size_t slc_gs_top(size_t i);
void slc_stacks_unwind(slc_stackset *set, uint64_t mark);
void slc_stacks_clear(slc_stackset *set);
void slc_gs_write_bytes(size_t stack, size_t dst, uint8_t *src, size_t bytes);
void slc_gs_reset(size_t i, size_t top);
/* align the top of stack i for a new resizable value; returns the new top */
size_t slc_gs_begin(size_t i);
/* grow stack i by n bytes at the top; returns the offset of the new bytes */
size_t slc_gs_push(size_t i, size_t n);

/* a store token that no other store, live or dead, has had */
uint64_t slc_next_token(void);

/* the header of a managed store; slots live on its data stack */
typedef struct slc_store {
    size_t stack;       /* data stack index */
    size_t base;        /* offset of slot 0 */
    uint32_t len;       /* slots ever created */
    uint32_t live;      /* occupied slots */
    uint32_t free_head; /* first free slot, or SLC_NONE */
    uint64_t token;
} slc_store;

/* a generational ID: identifies, never owns */
typedef struct slc_id {
    uint64_t token;
    uint32_t slot;
    uint32_t gen;
} slc_id;

#define SLC_NONE UINT32_MAX
#define SLC_OCCUPIED (UINT32_MAX - 1)
#define SLC_RETIRED (UINT32_MAX - 2)

/* General movable-stack byte access and relocation primitives. */
uint8_t *slc_gs_bytes(size_t stack, size_t at, size_t bytes);
size_t slc_gs_pin(size_t stack, const uint8_t *p, size_t bytes);
void slc_gs_copy(size_t stack, size_t dst, size_t src, size_t bytes);
void slc_gs_write(size_t stack, size_t dst, const uint8_t *src, size_t bytes);
void slc_gs_zero(size_t stack, size_t at, size_t bytes);

/* a Grow array: elements live on its data stack */
typedef struct slc_grow {
    size_t stack;
    size_t base;
    uint32_t len;
} slc_grow;

slc_store slc_store_new(size_t stack);
slc_grow slc_grow_new(size_t stack);

/* give a resizable value's space back: its stack top returns to its base */
void slc_release(size_t stack, size_t base);

/* The command line a program's main sees: a count and the NUL-terminated
 * argument strings, exactly as the process received them. */
typedef struct slc_args {
    uint32_t count;
    const char **argv;
} slc_args;

/* Checked slice access is a library word (lib/slice.slc), not a C macro. */

/* Native storage metadata. Encoding, equality, probing, growth and mutation
 * are ordinary SLC words. Bucket zero hashes denote empty slots. */
typedef struct slc_map {
    size_t stack, base, width;
    uint32_t len, cap, iterating;
} slc_map;
slc_map slc_map_new(size_t stack, size_t width);
void *slc_map_at(const slc_map *m, uint32_t slot);
/* Internal scope-owned guard, represented by an ordinary stack/base header. */
slc_grow slc_map_iter_new(size_t stack, slc_map *m);

/* Platform boundary used by SLC hashing; no hashing algorithm in this accessor. */
uint64_t slc_hash_seed_word(uint32_t index);
/* Once slc_hash_ready is set the key is final: user code reads it in place. */
extern int32_t slc_hash_ready;
extern uint64_t slc_hash_key0, slc_hash_key1;

/* StrMap entries begin with this complete key header, followed by a typed
 * value. Offsets survive arena movement; there are no retained byte pointers. */
typedef struct slc_strkey { uint64_t hash; size_t offset; uint32_t len; } slc_strkey;
typedef struct slc_strmap {
    slc_map entries;
    size_t arena_stack, arena_base, arena_len, dead;
} slc_strmap;
slc_strmap slc_strmap_new(size_t table_stack, size_t arena_stack, size_t width);

/* tasks, channels, timers (runtime/tasks.slc) ---------------------------------------------------
 * A task is a frame whose first member is an slc_task, and a step function the
 * compiler generated: it runs to its next wait and returns. A wait starts an
 * operation: it completes now (SLC_NOW), or later (SLC_PENDING), when whoever
 * completes it writes the task's result and makes it runnable. Plain code
 * waits the same way through slc_self() and blocks in slc_block(). */
typedef struct slc_scope slc_scope;
typedef struct slc_task slc_task;
typedef struct slc_chan { uint32_t idx; uint32_t gen; } slc_chan;
typedef int32_t slc_step;
typedef slc_step (*slc_step_fn)(slc_task *);

#define SLC_DONE 0
#define SLC_WAIT 1
#define SLC_YIELD 2
#define SLC_NOW 0
#define SLC_PENDING 1

typedef struct slc_op {
    slc_task *task;
    struct slc_op *next, *prev;
    void *buf;
    uint64_t deadline;
    slc_chan chan;
    int32_t kind, index, queued;
    /* I/O */
    int32_t fd;
    uint32_t len;
    int64_t offset;
    int64_t *value;
    void *backend;
    void (*job)(void *);     /* blocking work */
} slc_op;

/* operation kinds of a first_of record, and its two non-case results */
#define SLC_CASE_RECV 1
#define SLC_CASE_SEND 2
#define SLC_CASE_AFTER 3
#define SLC_CASE_TAKE 4
#define SLC_CASE_DEFAULT (-1)
#define SLC_CASE_CLOSED (-2)

struct slc_task {
    int32_t state;      /* resume point (generated code) */
    uint64_t id;        /* who owns a pool slot: never reused */
    int32_t result;     /* the last wait's result */
    int32_t budget;     /* loop rounds before the task yields */
    int32_t claimed;    /* a waiting task is completed by whoever claims it */
    int32_t run, nops, woken, blocking, depth, active;
    slc_op *ops;
    void *park;         /* a blocked plain thread's condition variable */
    slc_scope *cur_scope;   /* the innermost scope this party is in */
    slc_step_fn step;
    slc_scope *scope;
    slc_task *next, *all_prev, *all_next;
    const char *site;
    slc_stackset stacks;
};

/* the data stacks the calling thread uses (NULL: its own) */
void slc_stacks_use(slc_stackset *s);
void slc_stacks_free(slc_stackset *s);

slc_scope *slc_scope_new(slc_task *me);
int32_t slc_scope_end(slc_task *t, slc_op *ops, slc_scope *s, const char *site);
slc_task *slc_spawn(slc_scope *s, size_t frame, slc_step_fn step);
void slc_start(slc_task *t);
slc_task *slc_self(void);
void slc_block(slc_task *t);
static inline int slc_budget(slc_task *t) { return --t->budget <= 0; }

slc_chan slc_chan_new(slc_scope *s, size_t elem, uint32_t cap);
void slc_chan_close(slc_chan c);
int32_t slc_send(slc_task *t, slc_op *ops, slc_chan c, void *v, const char *site);
/* result: 1 a value, 0 closed and drained */
int32_t slc_recv(slc_task *t, slc_op *ops, slc_chan c, void *out, const char *site);
int32_t slc_sleep(slc_task *t, slc_op *ops, uint64_t ns, const char *site);
/* pools: n slots of elem bytes whose ownership moves between tasks. A slot
 * names its pool, so ownership calls need only the slot. */
typedef struct slc_pool { uint32_t idx; uint32_t gen; } slc_pool;
typedef struct slc_slot { uint32_t pool, pgen, index, gen; } slc_slot;
slc_pool slc_pool_new(slc_scope *s, size_t elem, uint32_t n);
/* wait for a free slot; *out becomes a slot the task owns */
int32_t slc_take(slc_task *t, slc_op *ops, slc_pool p, slc_slot *out, const char *site);
/* what slc_slot_at reads, published by the runtime: a pool's generation and
 * memory, and each slot's generation and owner (atomics; the memory stays for
 * as long as the record can be named) */
typedef struct slc_slot_meta { uint64_t owner; uint32_t gen, next_free; } slc_slot_meta;
typedef struct slc_pool_meta { uint32_t gen, n; size_t elem; unsigned char *data; slc_slot_meta *slots; } slc_pool_meta;
#define SLC_POOL_CHUNK 256u
#define SLC_POOL_CHUNKS 4096u
extern slc_pool_meta **slc_pool_metas;     /* SLC_POOL_CHUNKS pointers, made when the runtime starts */
/* a failed slot check: names what failed, then traps */
SLC_COLD void slc_slot_fault(slc_task *me, slc_slot s);

/* the slot's contents, checked at every access: this party owns the slot.
 * Inline and lock-free; only a failure leaves the fast path. */
static inline void *slc_slot_at(slc_task *me, slc_slot s) {
    slc_pool_meta *chunk = slc_pool_metas && s.pool / SLC_POOL_CHUNK < SLC_POOL_CHUNKS
        ? slc_pool_metas[s.pool / SLC_POOL_CHUNK] : NULL;
    if (chunk && s.pgen) {
        slc_pool_meta *m = &chunk[s.pool % SLC_POOL_CHUNK];
        if (__atomic_load_n(&m->gen, __ATOMIC_ACQUIRE) == s.pgen && s.index < m->n) {
            slc_slot_meta *sl = &m->slots[s.index];
            if (__atomic_load_n(&sl->gen, __ATOMIC_ACQUIRE) == s.gen
                && __atomic_load_n(&sl->owner, __ATOMIC_ACQUIRE) == me->id)
                return m->data + (size_t)s.index * m->elem;
        }
    }
    slc_slot_fault(me, s);
}
void slc_slot_release(slc_task *me, slc_slot s);
/* a send moves a slot: its owner gives it before, the receiver adopts it after */
void slc_slot_give(slc_task *me, slc_slot s);
void slc_slot_adopt(slc_task *me, slc_slot s);

/* I/O by completion (§36.7). The result is SLC_IO_DONE, SLC_IO_FAILED or
 * SLC_IO_TIMED_OUT; *value receives the count or descriptor when done, the
 * system's error code when failed. A deadline of 0 is none; an offset of -1
 * is the descriptor's own position. */
#define SLC_IO_DONE 0
#define SLC_IO_FAILED 1
#define SLC_IO_TIMED_OUT 2
int32_t slc_io_read(slc_task *t, slc_op *ops, int32_t fd, void *buf, uint32_t n, int64_t offset, uint64_t deadline,
                    int64_t *value, const char *site);
int32_t slc_io_write(slc_task *t, slc_op *ops, int32_t fd, void *buf, uint32_t n, int64_t offset,
                     uint64_t deadline, int64_t *value, const char *site);
int32_t slc_io_accept(slc_task *t, slc_op *ops, int32_t fd, uint64_t deadline, int64_t *value, const char *site);
int32_t slc_io_connect(slc_task *t, slc_op *ops, uint32_t host, uint32_t port, uint64_t deadline, int64_t *value,
                       const char *site);
int32_t slc_io_open(slc_task *t, slc_op *ops, const char *path, int32_t flags, uint32_t mode, int64_t *value,
                    const char *site);
int32_t slc_io_close(slc_task *t, slc_op *ops, int32_t fd, int64_t *value, const char *site);
/* setup that never waits: 0 done, 1 failed (*value: the error) */
int32_t slc_io_pipe(int32_t *reader, int32_t *writer, int64_t *value);
int32_t slc_io_listen(uint32_t host, uint32_t port, int64_t *value);
uint32_t slc_io_local_port(int32_t fd);
/* run job(env) on a blocking thread while the task waits: for calls into C
 * that may block. The task's data stacks travel with it. */
int32_t slc_blocking(slc_task *t, slc_op *ops, void (*job)(void *), void *env, const char *site);

/* the backend linked in: "poll", "io_uring" or "kqueue" */
const char *slc_io_backend(void);

/* first_of is sequenced where it is written (lib/select.slc): the program fills the
 * operation records, tries each case once through these, and arms them all when none
 * is ready. Each try is one locked transaction on one channel or pool: 1 it
 * happened, 0 not ready (a receive also gives -1: closed and drained). */
int32_t slc_poll_recv(slc_task *t, slc_op *op);
int32_t slc_poll_send(slc_task *t, slc_op *op);
int32_t slc_poll_take(slc_task *t, slc_op *op);
/* wait on every record; SLC_NOW when one was ready after all, SLC_PENDING otherwise */
int32_t slc_select_arm(slc_task *t, slc_op *ops, int32_t n, const char *site);
/* where the scan starts, so no case is always favoured */
uint64_t slc_select_ticket(void);
uint64_t slc_now_ns(void);

#endif
