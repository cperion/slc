/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* slc runtime: tasks, channels, timers. See slc_rt.h and §36.
 *
 * Tasks are compiled state machines. Workers run them from one run queue; a
 * plain thread blocked in a wait helps run them too, so with no workers at all
 * (deterministic mode) everything runs on the blocked thread.
 *
 * A wait is a set of operation records (slc_op) living in the waiting frame.
 * Whoever completes a waiting task must first claim it (a compare-and-swap on
 * task->claimed), so exactly one operation of a first_of happens. The task
 * withdraws its other records before it runs again.
 *
 * Lock order: a channel's lock, then the scheduler's. The scheduler's lock is
 * never held while taking a channel's.
 *
 * Channel records live in a registry that only grows, so a stale handle always
 * reaches a live record whose generation says the channel is gone. */
#define _POSIX_C_SOURCE 200809L
#include "slc_rt.h"
#include "slc_io.h"
#include "slc_scheduler.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define BUDGET 1024
#define NONE (-100)
#define RESCAN (-3)          /* a channel of a first_of closed: look again */
#define STALE (-4)           /* a channel waited on retired under the waiter */

enum { RUN_QUEUED, RUN_RUNNING, RUN_PARKED, RUN_NOTIFIED };
enum { K_SEND = SLC_CASE_SEND, K_RECV = SLC_CASE_RECV, K_AFTER = SLC_CASE_AFTER, K_TAKE = SLC_CASE_TAKE,
       K_SLEEP = 10 };

/* task ids: owners of pool slots (0 free, 1 in transit) */
static uint64_t next_id = 2;
static uint64_t new_id(void) { return __atomic_fetch_add(&next_id, 1, __ATOMIC_RELAXED); }

/* the scheduler (everything here is under `sched`) ------------------------------------------ */

static pthread_mutex_t sched = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static slc_run_queue run_queue;
static slc_task *all_tasks;          /* spawned and not finished */
static slc_task *blocked;            /* plain threads blocked in a wait (linked by next) */
static int nrunning, nparked, nblocked, nactive_plain;
static int nio;                       /* I/O operations in flight */
static int det_mode;
static uint64_t rng = 88172645463325252ull;
static slc_timer_heap timers;        /* policy state, under sched */
static __thread int in_task;
/* a task woken by the task running on this thread runs here next, as in Go:
 * a handoff between two tasks stays on one thread */
static __thread slc_task *runnext;
static int nlocal;
static __thread slc_task self_stub;
static __thread int self_init;

/* an idle thread (a worker, or a blocked plain thread) sleeps on its own
 * condition variable: a push wakes exactly one, and waking a blocked thread
 * wakes exactly that one */
static struct idler *idlers;
static __thread struct idler me;

static void init_me(void) {
    if (!me.ready) {
        pthread_condattr_t ca;
        pthread_condattr_init(&ca);
        pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
        pthread_cond_init(&me.cv, &ca);
        pthread_condattr_destroy(&ca);
        me.ready = 1;
    }
}

static void wake_one_idler(void) { slc_idler_signal(&idlers); }

uint64_t slc_now_ns(void);
static uint64_t now_ns(void) { return slc_now_ns(); }
uint64_t slc_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static uint64_t next_rand(void) { return slc_sched_random(&rng); }

static void set_claimable(slc_task *t) { __atomic_store_n(&t->claimed, 0, __ATOMIC_RELEASE); }

static void push(slc_task *t) {
    t->run = RUN_QUEUED;
    slc_sched_push(&run_queue, t);
    wake_one_idler();
}

static slc_task *pop(void) {
    slc_task *t;
    if (runnext) {
        t = runnext;
        runnext = NULL;
        nlocal--;
        return t;
    }
    return slc_sched_next(&run_queue, &rng, det_mode != 0);
}

/* a plain thread counts as active (able to act on channels) while it runs
 * inside a scope, or has been woken and has not yet gone back to its code */
static void set_active(slc_task *t, int on) {
    if (t->active == on) return;
    t->active = on;
    nactive_plain += on ? 1 : -1;
}

/* make a claimed task runnable (sched held) */
void slc_wake_locked(slc_task *t) {
    if (t->blocking) {
        if (t->run == RUN_PARKED) {
            slc_blocked_remove(&blocked, t);
            nblocked--;
            set_active(t, 1);
        }
        t->run = RUN_RUNNING;
        t->woken = 1;
        pthread_cond_signal((pthread_cond_t *)t->park);
    } else if (t->run == RUN_RUNNING) {
        t->run = RUN_NOTIFIED;
    } else if (t->run == RUN_PARKED) {
        nparked--;
        if (in_task && !runnext) {
            t->run = RUN_QUEUED;
            runnext = t;
            nlocal++;
        } else {
            push(t);
        }
    }
}

void slc_task_wake(slc_task *t) {
    pthread_mutex_lock(&sched);
    slc_wake_locked(t);
    pthread_mutex_unlock(&sched);
}

/* timers -------------------------------------------------------------------------------------- */

/* Allocation/growth, heap ordering and cancellation bookkeeping are SLC.
 * Wakeup remains inside the scheduler's synchronization envelope. */
static void timer_add(slc_op *op) {
    if (slc_timer_add(&timers, op)) wake_one_idler();
}

static void timer_remove(slc_op *op) { slc_timer_remove(&timers, op); }

static int fire_timers(void) { return slc_timer_fire(&timers, now_ns()); }

/* channels ------------------------------------------------------------------------------------ */

#define CHUNK 256u
#define CHUNKS 4096u
struct chan_rec *slc_channel_chunks[CHUNKS];
static uint32_t nrecs;
static uint32_t free_head = SLC_NONE;
static pthread_mutex_t registry = PTHREAD_MUTEX_INITIALIZER;

static struct chan_rec *rec_at(uint32_t idx) { return &slc_channel_chunks[idx / CHUNK][idx % CHUNK]; }

/* Registry storage and synchronization mechanisms shared by SLC policy. */
slc_pool_meta *slc_pool_metas[SLC_POOL_CHUNKS];
struct pool_rec *slc_pool_chunks[CHUNKS];
static uint32_t npools;
static uint32_t pfree_head = SLC_NONE;
static struct pool_rec *pool_at(uint32_t idx) { return &slc_pool_chunks[idx / CHUNK][idx % CHUNK]; }

static void begin(slc_task *t, slc_op *ops, int32_t n, const char *site) {
    t->ops = ops;
    t->nops = n;
    t->site = site;
}

void slc_timer_register(slc_op *op) {
    pthread_mutex_lock(&sched);
    timer_add(op);
    pthread_mutex_unlock(&sched);
}

void slc_timer_cancel(slc_op *op) {
    pthread_mutex_lock(&sched);
    timer_remove(op);
    pthread_mutex_unlock(&sched);
}

uint64_t slc_select_ticket(void) {
    static uint32_t rotate;
    if (det_mode) {
        uint64_t value;
        pthread_mutex_lock(&sched);
        value = next_rand();
        pthread_mutex_unlock(&sched);
        return value;
    }
    return __atomic_fetch_add(&rotate, 1u, __ATOMIC_RELAXED);
}

/* scopes -------------------------------------------------------------------------------------- */

slc_scope *slc_scope_new(slc_task *me) {
    slc_scope *s = slc_scope_allocate(me);
    if (!s) slc_trap("out of memory for a tasks scope");
    if (me->blocking) {
        pthread_mutex_lock(&sched);
        me->depth++;
        set_active(me, 1);
        pthread_mutex_unlock(&sched);
    }
    return s;
}

void slc_retire_channel_sync(uint32_t idx) {
    struct chan_rec *r = rec_at(idx);
    slc_op *list;
    pthread_mutex_lock(&r->mu);
    list = slc_channel_retire(r);
    pthread_mutex_unlock(&r->mu);
    slc_wait_wake(list, STALE, STALE, false);
    pthread_mutex_lock(&registry);
    slc_channel_recycle_record(r, &free_head, idx);
    pthread_mutex_unlock(&registry);
}

void slc_retire_pool_sync(uint32_t idx) {
    struct pool_rec *r = pool_at(idx);
    slc_op *list;
    pthread_mutex_lock(&r->mu);
    list = slc_pool_retire(r);
    pthread_mutex_unlock(&r->mu);
    slc_wait_wake(list, STALE, STALE, false);
    pthread_mutex_lock(&registry);
    slc_pool_recycle_record(r, &pfree_head, idx);
    pthread_mutex_unlock(&registry);
}

slc_pool slc_pool_new(slc_scope *s, size_t elem, uint32_t n) {
    uint32_t idx;
    struct pool_rec *r;
    slc_pool p;
    if (n == 0) slc_trap("a pool needs at least one slot");
    pthread_mutex_lock(&registry);
    int32_t acquired = slc_pool_acquire(slc_pool_chunks, slc_pool_metas, &pfree_head, &npools, n, elem);
    if (acquired < 0) {
        pthread_mutex_unlock(&registry);
        slc_trap(acquired == -1 ? "too many pools" : "out of memory for pools");
    }
    idx = (uint32_t)acquired;
    pthread_mutex_unlock(&registry);
    r = pool_at(idx);
    pthread_mutex_lock(&r->mu);
    if (!slc_pool_initialize(r, s, elem, n)) {
        pthread_mutex_unlock(&r->mu);
        slc_trap("out of memory for a pool");
    }
    p.idx = idx;
    p.gen = r->m->gen;
    pthread_mutex_unlock(&r->mu);
    pthread_mutex_lock(&sched);
    if (!slc_scope_record(&s->pools, &s->npools, &s->cap_pools, 4, idx)) {
        pthread_mutex_unlock(&sched);
        slc_trap("out of memory for a pool");
    }
    pthread_mutex_unlock(&sched);
    return p;
}


int32_t slc_scope_end(slc_task *t, slc_op *ops, slc_scope *s, const char *site) {
    (void)ops;
    t->cur_scope = s->parent;
    pthread_mutex_lock(&sched);
    if (t->blocking && --t->depth == 0) set_active(t, 0);
    t->result = 0;
    if (s->live == 0) {
        pthread_mutex_unlock(&sched);
        slc_scope_retire(s);
        return SLC_NOW;
    }
    begin(t, ops, 0, site);
    set_claimable(t);
    s->waiter = t;
    pthread_mutex_unlock(&sched);
    return SLC_PENDING;
}

slc_chan slc_chan_new(slc_scope *s, size_t elem, uint32_t cap) {
    uint32_t idx;
    struct chan_rec *r;
    slc_chan c;
    pthread_mutex_lock(&registry);
    int32_t acquired = slc_channel_acquire(slc_channel_chunks, &free_head, &nrecs);
    if (acquired < 0) {
        pthread_mutex_unlock(&registry);
        slc_trap(acquired == -1 ? "too many channels" : "out of memory for channels");
    }
    idx = (uint32_t)acquired;
    pthread_mutex_unlock(&registry);
    r = rec_at(idx);
    pthread_mutex_lock(&r->mu);
    if (!slc_channel_initialize(r, elem, cap)) {
        pthread_mutex_unlock(&r->mu);
        slc_trap("out of memory for a channel");
    }
    c.idx = idx;
    c.gen = r->gen;
    pthread_mutex_unlock(&r->mu);
    pthread_mutex_lock(&sched);
    if (!slc_scope_record(&s->chans, &s->nchans, &s->cap_chans, 8, idx)) {
        pthread_mutex_unlock(&sched);
        slc_trap("out of memory for a channel");
    }
    pthread_mutex_unlock(&sched);
    return c;
}

/* running tasks ------------------------------------------------------------------------------- */

static void deadlock(void) {
    slc_task *t;
    fprintf(stderr, "slc: deadlock: every task is waiting\n");
    for (t = all_tasks; t; t = t->all_next)
        if (t->run == RUN_PARKED) fprintf(stderr, "    a task waits at %s\n", t->site ? t->site : "?");
    for (t = blocked; t; t = t->next) fprintf(stderr, "    a thread waits at %s\n", t->site ? t->site : "?");
    fflush(stderr);
    abort();
}

/* nothing runs, nothing can fire, nobody outside can act: nothing will ever wake */
static void check_deadlock(void) {
    if (nrunning == 0 && run_queue.len == 0 && nlocal == 0 && timers.len == 0 && nio == 0 && nactive_plain == 0
        && nparked + nblocked > 0)
        deadlock();
}

/* wait for work or a timer (sched held) */
static void idle(void) {
    init_me();
    /* a fired timer may have woken this very thread: let the caller look again */
    if (fire_timers()) return;
    if (run_queue.len || runnext) return;
    check_deadlock();
    slc_idler_enqueue(&idlers, &me);
    if (timers.len) {
        uint64_t d = timers.data[0]->deadline;
        struct timespec ts;
        ts.tv_sec = (time_t)(d / 1000000000ull);
        ts.tv_nsec = (long)(d % 1000000000ull);
        pthread_cond_timedwait(&me.cv, &sched, &ts);
    } else {
        pthread_cond_wait(&me.cv, &sched);
    }
    slc_idler_remove(&idlers, &me);
}

static void finish(slc_task *t) {
    slc_scope *s = t->scope;
    slc_task *waiter = NULL;
    pthread_mutex_lock(&sched);
    waiter = slc_task_detach(&all_tasks, t);
    pthread_mutex_unlock(&sched);
    slc_stacks_free(&t->stacks);
    free(t);
    if (waiter) {
        slc_scope_retire(s);
        slc_task_wake(waiter);
    }
}

/* run one step of a task taken from the queue (sched held on entry and exit) */
static void step_task(slc_task *t) {
    slc_step r;
    t->run = RUN_RUNNING;
    nrunning++;
    pthread_mutex_unlock(&sched);
    __atomic_store_n(&t->claimed, 1, __ATOMIC_RELEASE);
    if (!slc_resume_wait(t)) {
        r = SLC_WAIT;                      /* looked again, still waiting */
    } else {
        int was = in_task;
        in_task = 1;
        slc_stacks_use(&t->stacks);
        t->budget = BUDGET;
        r = t->step(t);
        slc_stacks_use(NULL);
        in_task = was;
    }
    if (r == SLC_DONE) {
        finish(t);
        pthread_mutex_lock(&sched);
        nrunning--;
        return;
    }
    pthread_mutex_lock(&sched);
    nrunning--;
    if (r == SLC_YIELD || t->run == RUN_NOTIFIED) {
        push(t);
    } else {
        t->run = RUN_PARKED;
        nparked++;
    }
}

static void *worker(void *arg) {
    (void)arg;
    pthread_mutex_lock(&sched);
    for (;;) {
        slc_task *t = pop();
        if (t) step_task(t); else idle();
    }
    return NULL;
}

void slc_worker_start(void) {
    pthread_t th;
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&th, &at, worker, NULL) != 0) slc_trap("cannot start a worker");
    pthread_attr_destroy(&at);
}

static void init(void) { slc_workers_init(&det_mode, &rng); }

slc_task *slc_spawn(slc_scope *s, size_t frame, slc_step_fn step) {
    slc_task *t;
    pthread_once(&once, init);
    t = calloc(1, frame);
    if (!t) slc_trap("out of memory for a task");
    t->step = step;
    t->scope = s;
    t->cur_scope = s;
    __atomic_store_n(&t->claimed, 1, __ATOMIC_RELEASE);
    t->id = new_id();
    pthread_mutex_lock(&sched);
    slc_task_attach(&all_tasks, t);
    pthread_mutex_unlock(&sched);
    return t;
}

void slc_start(slc_task *t) {
    pthread_mutex_lock(&sched);
    push(t);
    pthread_mutex_unlock(&sched);
}

int slc_trap_recoverable(void) {
    return !in_task && slc_cur_stacks == NULL && (!self_init || self_stub.cur_scope == NULL);
}

slc_task *slc_self(void) {
    if (in_task) slc_trap("a blocking wait inside a task");
    if (!self_init) {
        memset(&self_stub, 0, sizeof self_stub);
        self_stub.blocking = 1;
        self_stub.id = new_id();
        self_stub.run = RUN_RUNNING;
        self_stub.claimed = 1;
        init_me();
        self_stub.park = &me.cv;
        self_init = 1;
    }
    return &self_stub;
}

/* a plain thread waits; meanwhile it runs tasks */
void slc_block(slc_task *t) {
    pthread_once(&once, init);
    for (;;) {
        pthread_mutex_lock(&sched);
        if (!t->woken) {
            t->run = RUN_PARKED;
            t->next = blocked;
            blocked = t;
            nblocked++;
            set_active(t, 0);
        }
        while (!t->woken) {
            slc_task *task = pop();
            if (task) step_task(task); else idle();
        }
        t->woken = 0;
        pthread_mutex_unlock(&sched);
        __atomic_store_n(&t->claimed, 1, __ATOMIC_RELEASE);
        if (slc_resume_wait(t)) {
            pthread_mutex_lock(&sched);
            set_active(t, t->depth > 0);
            pthread_mutex_unlock(&sched);
            return;
        }
    }
}

/* I/O ----------------------------------------------------------------------------------------- */

/* Only synchronized accounting and const-pointer ABI adaptation remain here. */
void slc_io_notify(slc_task *t) {
    pthread_mutex_lock(&sched);
    nio--;
    slc_wake_locked(t);
    pthread_mutex_unlock(&sched);
}

void slc_io_publish(slc_op *op) {
    pthread_once(&once, init);
    set_claimable(op->task);
    pthread_mutex_lock(&sched);
    nio++;
    pthread_mutex_unlock(&sched);
    slc_backend_submit(op);
}

int32_t slc_io_write(slc_task *t, slc_op *ops, int32_t fd, const void *buf, uint32_t n, int64_t offset,
                     uint64_t deadline, int64_t *value, const char *site) {
    return slc_io_write_bytes(t, ops, fd, (void *)(uintptr_t)buf, n, offset, deadline, value, site);
}

int32_t slc_io_open(slc_task *t, slc_op *ops, const char *path, int32_t flags, uint32_t mode, int64_t *value,
                    const char *site) {
    return slc_io_open_path(t, ops, (void *)(uintptr_t)path, flags, mode, value, site);
}

/* blocking threads --------------------------------------------------------------------------
 * Calls into C that may block run here, not on a worker: one thread per job in
 * flight, made on demand and kept for reuse. */

static pthread_mutex_t bmu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t bcv = PTHREAD_COND_INITIALIZER;
static struct bjob *bhead, *btail;
static int bidle, bthreads;

static void *blocking_thread(void *arg) {
    (void)arg;
    pthread_mutex_lock(&bmu);
    for (;;) {
        struct bjob *j;
        while (!bhead) {
            bidle++;
            pthread_cond_wait(&bcv, &bmu);
            bidle--;
        }
        j = slc_job_dequeue(&bhead, &btail);
        pthread_mutex_unlock(&bmu);
        j->fn(j->arg);
        free(j);
        pthread_mutex_lock(&bmu);
    }
    return NULL;
}

void slc_run_blocking(void (*fn)(void *), void *arg) {
    struct bjob *j = malloc(sizeof *j);
    if (!j) slc_trap("out of memory for blocking work");
    j->fn = fn;
    j->arg = arg;
    pthread_mutex_lock(&bmu);
    slc_job_enqueue(&bhead, &btail, j);
    if (bidle > 0) {
        pthread_cond_signal(&bcv);
    } else {
        pthread_t th;
        pthread_attr_t at;
        pthread_attr_init(&at);
        pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&th, &at, blocking_thread, NULL) != 0) {
            pthread_mutex_unlock(&bmu);
            slc_trap("cannot start a blocking thread");
        }
        pthread_attr_destroy(&at);
        bthreads++;
    }
    pthread_mutex_unlock(&bmu);
}

/* a task's blocking block: run on its own data stacks, then wake the task */
static void run_task_job(void *arg) {
    slc_op *op = arg;
    slc_stacks_use(&op->task->stacks);
    op->job(op->buf);
    slc_stacks_use(NULL);
    slc_io_complete(op, SLC_IO_DONE, 0);
}

int32_t slc_blocking(slc_task *t, slc_op *ops, void (*job)(void *), void *env, const char *site) {
    slc_op *op = &ops[0];
    begin(t, ops, 1, site);
    op->task = t; op->kind = SLC_K_BLOCKING; op->index = -1; op->queued = 0;
    op->job = job; op->buf = env; op->value = &op->offset; op->deadline = 0;
    pthread_once(&once, init);
    set_claimable(t);
    pthread_mutex_lock(&sched);
    nio++;                      /* outstanding: not a deadlock while it runs */
    pthread_mutex_unlock(&sched);
    slc_run_blocking(run_task_job, op);
    return SLC_PENDING;
}
