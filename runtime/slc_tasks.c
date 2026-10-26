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
static slc_task *rq_head, *rq_tail;
static size_t rq_len;
static slc_task *all_tasks;          /* spawned and not finished */
static slc_task *blocked;            /* plain threads blocked in a wait (linked by next) */
static int nrunning, nparked, nblocked, nactive_plain;
static int nio;                       /* I/O operations in flight */
static int det_mode;
static uint64_t rng = 88172645463325252ull;
static slc_op **heap;                /* timers by deadline */
static size_t nheap, capheap;
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
struct idler { pthread_cond_t cv; struct idler *next; int listed, ready; };
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

static void wake_one_idler(void) {
    struct idler *i = idlers;
    if (!i) return;
    idlers = i->next;
    i->listed = 0;
    pthread_cond_signal(&i->cv);
}

uint64_t slc_now_ns(void);
static uint64_t now_ns(void) { return slc_now_ns(); }
uint64_t slc_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static uint64_t next_rand(void) {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
}

static void set_claimable(slc_task *t) { __atomic_store_n(&t->claimed, 0, __ATOMIC_RELEASE); }

static int claim(slc_task *t) {
    int32_t expect = 0;
    return __atomic_compare_exchange_n(&t->claimed, &expect, 1, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
}

static void push(slc_task *t) {
    t->run = RUN_QUEUED;
    t->next = NULL;
    if (rq_tail) rq_tail->next = t; else rq_head = t;
    rq_tail = t;
    rq_len++;
    wake_one_idler();
}

static slc_task *pop(void) {
    slc_task *t, *prev = NULL;
    size_t k;
    if (runnext) {
        t = runnext;
        runnext = NULL;
        nlocal--;
        return t;
    }
    if (!rq_head) return NULL;
    k = det_mode ? (size_t)(next_rand() % rq_len) : 0;
    t = rq_head;
    while (k--) { prev = t; t = t->next; }
    if (prev) prev->next = t->next; else rq_head = t->next;
    if (rq_tail == t) rq_tail = prev;
    rq_len--;
    t->next = NULL;
    return t;
}

/* a plain thread counts as active (able to act on channels) while it runs
 * inside a scope, or has been woken and has not yet gone back to its code */
static void set_active(slc_task *t, int on) {
    if (t->active == on) return;
    t->active = on;
    nactive_plain += on ? 1 : -1;
}

/* make a claimed task runnable (sched held) */
static void wake_locked(slc_task *t) {
    if (t->blocking) {
        if (t->run == RUN_PARKED) {
            slc_task **p = &blocked;
            while (*p && *p != t) p = &(*p)->next;
            if (*p) *p = t->next;
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

static void wake(slc_task *t) {
    pthread_mutex_lock(&sched);
    wake_locked(t);
    pthread_mutex_unlock(&sched);
}

/* timers -------------------------------------------------------------------------------------- */

static void heap_set(size_t i, slc_op *op) { heap[i] = op; op->queued = (int32_t)i + 1; }

static void heap_up(size_t i) {
    while (i > 0) {
        size_t p = (i - 1) / 2;
        slc_op *a = heap[i], *b = heap[p];
        if (b->deadline <= a->deadline) break;
        heap_set(i, b);
        heap_set(p, a);
        i = p;
    }
}

static void heap_down(size_t i) {
    for (;;) {
        size_t l = 2 * i + 1, r = l + 1, m = i;
        slc_op *t;
        if (l < nheap && heap[l]->deadline < heap[m]->deadline) m = l;
        if (r < nheap && heap[r]->deadline < heap[m]->deadline) m = r;
        if (m == i) break;
        t = heap[i];
        heap_set(i, heap[m]);
        heap_set(m, t);
        i = m;
    }
}

static void timer_add(slc_op *op) {
    if (nheap == capheap) {
        size_t n = capheap ? capheap * 2 : 16;
        slc_op **h = realloc(heap, n * sizeof *h);
        if (!h) slc_trap("out of memory for timers");
        heap = h;
        capheap = n;
    }
    heap_set(nheap, op);
    heap_up(nheap++);
    if (heap[0] == op) wake_one_idler();   /* an earlier deadline: someone recomputes its timeout */
}

static void timer_remove(slc_op *op) {
    size_t i;
    if (!op->queued) return;
    i = (size_t)op->queued - 1;
    op->queued = 0;
    nheap--;
    if (i < nheap) {
        heap_set(i, heap[nheap]);
        heap_down(i);
        heap_up(i);
    }
}

static int fire_timers(void) {
    uint64_t now = now_ns();
    int fired = 0;
    while (nheap && heap[0]->deadline <= now) {
        fired = 1;
        slc_op *op = heap[0];
        timer_remove(op);
        if (claim(op->task)) {
            op->task->result = op->index < 0 ? 0 : op->index;
            wake_locked(op->task);
        }
    }
    return fired;
}

/* channels ------------------------------------------------------------------------------------ */

struct queue { slc_op *head, *tail; };

struct chan_rec {
    pthread_mutex_t mu;
    uint32_t gen;
    bool live, closed;
    size_t elem;
    uint32_t cap, head, count;
    unsigned char *buf;
    struct queue recvq, sendq;
    uint32_t next_free;
};

#define CHUNK 256u
#define CHUNKS 4096u
static struct chan_rec *chunks[CHUNKS];
static uint32_t nrecs;
static uint32_t free_head = SLC_NONE;
static pthread_mutex_t registry = PTHREAD_MUTEX_INITIALIZER;

static struct chan_rec *rec_at(uint32_t idx) { return &chunks[idx / CHUNK][idx % CHUNK]; }

static struct chan_rec *lock_chan(slc_chan c) {
    struct chan_rec *r;
    if (c.gen == 0 || c.idx / CHUNK >= CHUNKS || chunks[c.idx / CHUNK] == NULL) slc_trap("not a channel");
    r = rec_at(c.idx);
    pthread_mutex_lock(&r->mu);
    if (!r->live || r->gen != c.gen) {
        pthread_mutex_unlock(&r->mu);
        slc_trap("channel used after its tasks scope ended");
    }
    return r;
}

static void enqueue(struct queue *q, slc_op *op) {
    op->next = NULL;
    op->prev = q->tail;
    if (q->tail) q->tail->next = op; else q->head = op;
    q->tail = op;
    op->queued = 1;
}

static void unlink_op(struct queue *q, slc_op *op) {
    if (!op->queued) return;
    if (op->prev) op->prev->next = op->next; else q->head = op->next;
    if (op->next) op->next->prev = op->prev; else q->tail = op->prev;
    op->next = op->prev = NULL;
    op->queued = 0;
}

/* the first waiter we can claim (never the asking task itself) */
static slc_op *claim_waiter(struct queue *q, slc_task *self) {
    slc_op *op = q->head;
    while (op) {
        slc_op *next = op->next;
        if (op->task != self) {
            unlink_op(q, op);
            if (claim(op->task)) return op;
        }
        op = next;
    }
    return NULL;
}

static int has_waiter(struct queue *q, slc_task *self) {
    slc_op *op;
    for (op = q->head; op; op = op->next) if (op->task != self) return 1;
    return 0;
}

static void *slot(struct chan_rec *r, uint32_t k) { return r->buf + (size_t)((r->head + k) % r->cap) * r->elem; }

/* the result a completed operation gives its task */
static int32_t done_result(slc_op *op, int32_t plain) { return op->index >= 0 ? op->index : plain; }

/* under the channel's lock: complete a receive into out if possible.
 * Returns 1 done, 0 not ready, -1 closed and drained. The woken sender, if
 * any, is returned through *wk and must be woken after unlocking. */
static int try_recv(struct chan_rec *r, void *out, slc_task *self, slc_task **wk) {
    slc_op *w;
    *wk = NULL;
    if (r->count > 0) {
        memcpy(out, slot(r, 0), r->elem);
        r->head = (r->head + 1) % r->cap;
        r->count--;
        if ((w = claim_waiter(&r->sendq, self))) {
            memcpy(slot(r, r->count), w->buf, r->elem);
            r->count++;
            w->task->result = done_result(w, 0);
            *wk = w->task;
        }
        return 1;
    }
    if ((w = claim_waiter(&r->sendq, self))) {
        memcpy(out, w->buf, r->elem);
        w->task->result = done_result(w, 0);
        *wk = w->task;
        return 1;
    }
    return r->closed ? -1 : 0;
}

/* under the channel's lock: complete a send of v if possible (1 done, 0 not ready) */
static int try_send(struct chan_rec *r, void *v, slc_task *self, slc_task **wk) {
    slc_op *w;
    *wk = NULL;
    if (r->closed) { pthread_mutex_unlock(&r->mu); slc_trap("send on a closed channel"); }
    if ((w = claim_waiter(&r->recvq, self))) {
        memcpy(w->buf, v, r->elem);
        w->task->result = done_result(w, 1);
        *wk = w->task;
        return 1;
    }
    if (r->count < r->cap) {
        memcpy(slot(r, r->count), v, r->elem);
        r->count++;
        return 1;
    }
    return 0;
}

static void begin(slc_task *t, slc_op *ops, int32_t n, const char *site) {
    t->ops = ops;
    t->nops = n;
    t->site = site;
}

int32_t slc_send(slc_task *t, slc_op *ops, slc_chan c, void *v, const char *site) {
    slc_op *op = &ops[0];
    slc_task *wk;
    struct chan_rec *r;
    begin(t, ops, 1, site);
    op->task = t; op->buf = v; op->chan = c; op->kind = K_SEND; op->index = -1; op->queued = 0;
    r = lock_chan(c);
    if (try_send(r, v, t, &wk)) {
        pthread_mutex_unlock(&r->mu);
        if (wk) wake(wk);
        t->nops = 0;
        t->result = 0;
        return SLC_NOW;
    }
    set_claimable(t);
    enqueue(&r->sendq, op);
    pthread_mutex_unlock(&r->mu);
    return SLC_PENDING;
}

int32_t slc_recv(slc_task *t, slc_op *ops, slc_chan c, void *out, const char *site) {
    slc_op *op = &ops[0];
    slc_task *wk;
    struct chan_rec *r;
    int got;
    begin(t, ops, 1, site);
    op->task = t; op->buf = out; op->chan = c; op->kind = K_RECV; op->index = -1; op->queued = 0;
    r = lock_chan(c);
    got = try_recv(r, out, t, &wk);
    if (got != 0) {
        pthread_mutex_unlock(&r->mu);
        if (wk) wake(wk);
        t->nops = 0;
        t->result = got == 1 ? 1 : 0;
        return SLC_NOW;
    }
    set_claimable(t);
    enqueue(&r->recvq, op);
    pthread_mutex_unlock(&r->mu);
    return SLC_PENDING;
}

void slc_chan_close(slc_chan c) {
    struct chan_rec *r = lock_chan(c);
    slc_op *w, *list = NULL;
    if (r->closed) { pthread_mutex_unlock(&r->mu); slc_trap("close of a closed channel"); }
    if (has_waiter(&r->sendq, NULL)) { pthread_mutex_unlock(&r->mu); slc_trap("send on a closed channel"); }
    r->closed = true;
    while ((w = claim_waiter(&r->recvq, NULL))) { w->next = list; list = w; }
    pthread_mutex_unlock(&r->mu);
    while (list) {
        slc_op *n = list->next;
        /* a plain receive sees `closed`; a first_of looks again */
        list->task->result = list->index < 0 ? 0 : RESCAN;
        list->next = NULL;
        wake(list->task);
        list = n;
    }
}

int32_t slc_sleep(slc_task *t, slc_op *ops, uint64_t ns, const char *site) {
    slc_op *op = &ops[0];
    begin(t, ops, 1, site);
    op->task = t; op->kind = K_SLEEP; op->index = -1; op->queued = 0;
    t->result = 0;
    if (ns == 0) { t->nops = 0; return SLC_NOW; }
    op->deadline = now_ns() + ns;
    set_claimable(t);
    pthread_mutex_lock(&sched);
    timer_add(op);
    pthread_mutex_unlock(&sched);
    return SLC_PENDING;
}

/* pools ----------------------------------------------------------------------------------------- */

#define FREE_OWNER 0
#define TRANSIT 1

/* the metadata slc_slot_at reads inline (slc_rt.h): owner and gen are written
 * under the pool's lock and read without it at every access */
slc_pool_meta *slc_pool_metas[SLC_POOL_CHUNKS];

/* a pool's memory is never freed while its record can be named: a retired
 * pool's memory waits for the next pool that fits, so a stale slot always
 * lands on memory whose generation says it is stale */
struct pool_rec {
    pthread_mutex_t mu;
    slc_pool_meta *m;           /* published: generation, size, memory, slots */
    bool live;
    uint32_t free_head;
    size_t cap_bytes;
    uint32_t cap_slots;
    slc_scope *scope;
    struct queue takers;
    uint32_t next_free;
};

static struct pool_rec *pchunks[CHUNKS];
static uint32_t npools;
static uint32_t pfree_head = SLC_NONE;

static struct pool_rec *pool_at(uint32_t idx) { return &pchunks[idx / CHUNK][idx % CHUNK]; }

static struct pool_rec *lock_pool(uint32_t idx, uint32_t gen) {
    struct pool_rec *r;
    if (gen == 0 || idx / CHUNK >= CHUNKS || pchunks[idx / CHUNK] == NULL) slc_trap("not a pool");
    r = pool_at(idx);
    pthread_mutex_lock(&r->mu);
    if (!r->live || __atomic_load_n(&r->m->gen, __ATOMIC_ACQUIRE) != gen) {
        pthread_mutex_unlock(&r->mu);
        slc_trap("pool used after its tasks scope ended");
    }
    return r;
}

/* the slot record behind a handle, its pool locked; traps on a stale slot */
static slc_slot_meta *lock_slot(slc_slot s, struct pool_rec **out) {
    struct pool_rec *r = lock_pool(s.pool, s.pgen);
    if (s.index >= r->m->n || __atomic_load_n(&r->m->slots[s.index].gen, __ATOMIC_ACQUIRE) != s.gen) {
        pthread_mutex_unlock(&r->mu);
        slc_trap("a slot used after it was released");
    }
    *out = r;
    return &r->m->slots[s.index];
}

/* is `me` inside scope s (or a scope nested in it)? */
static int inside(slc_task *me, slc_scope *s);

static void set_owner(slc_slot_meta *sl, uint64_t owner) { __atomic_store_n(&sl->owner, owner, __ATOMIC_RELEASE); }

static void owned_by(struct pool_rec *r, slc_slot_meta *sl, slc_task *me) {
    if (sl->owner != me->id) {
        pthread_mutex_unlock(&r->mu);
        slc_trap(sl->owner == TRANSIT ? "a slot used after it was sent" : "a slot used by a task that does not own it");
    }
}

/* under the pool's lock: hand a free slot to `owner` (1), or none is free (0) */
static int try_take(struct pool_rec *r, uint32_t pidx, slc_slot *out, uint64_t owner) {
    uint32_t i = r->free_head;
    if (i == SLC_NONE) return 0;
    r->free_head = r->m->slots[i].next_free;
    set_owner(&r->m->slots[i], owner);
    out->pool = pidx;
    out->pgen = r->m->gen;
    out->index = i;
    out->gen = r->m->slots[i].gen;
    return 1;
}

int32_t slc_take(slc_task *t, slc_op *ops, slc_pool p, slc_slot *out, const char *site) {
    slc_op *op = &ops[0];
    struct pool_rec *r;
    begin(t, ops, 1, site);
    op->task = t; op->buf = out; op->chan.idx = p.idx; op->chan.gen = p.gen; op->kind = K_TAKE; op->index = -1;
    op->queued = 0;
    r = lock_pool(p.idx, p.gen);
    if (!inside(t, r->scope)) {
        pthread_mutex_unlock(&r->mu);
        slc_trap("a pool used outside its tasks scope");
    }
    if (try_take(r, p.idx, out, t->id)) {
        pthread_mutex_unlock(&r->mu);
        t->nops = 0;
        t->result = 0;
        return SLC_NOW;
    }
    set_claimable(t);
    enqueue(&r->takers, op);
    pthread_mutex_unlock(&r->mu);
    return SLC_PENDING;
}

/* the slow path of slc_slot_at: look again under the lock to say what failed */
void slc_slot_fault(slc_task *me, slc_slot s) {
    struct pool_rec *r;
    slc_slot_meta *sl = lock_slot(s, &r);       /* traps on a stale pool or slot */
    owned_by(r, sl, me);                        /* traps on another owner */
    pthread_mutex_unlock(&r->mu);
    slc_trap("a slot check failed");
}

void slc_slot_give(slc_task *me, slc_slot s) {
    struct pool_rec *r;
    slc_slot_meta *sl = lock_slot(s, &r);
    owned_by(r, sl, me);
    set_owner(sl, TRANSIT);
    pthread_mutex_unlock(&r->mu);
}

void slc_slot_adopt(slc_task *me, slc_slot s) {
    struct pool_rec *r;
    slc_slot_meta *sl = lock_slot(s, &r);
    if (sl->owner != TRANSIT) { pthread_mutex_unlock(&r->mu); slc_trap("a slot adopted that was not sent"); }
    if (!inside(me, r->scope)) { pthread_mutex_unlock(&r->mu); slc_trap("a slot received outside its pool's tasks scope"); }
    set_owner(sl, me->id);
    pthread_mutex_unlock(&r->mu);
}

void slc_slot_release(slc_task *me, slc_slot s) {
    struct pool_rec *r;
    slc_slot_meta *sl = lock_slot(s, &r);
    slc_op *w;
    owned_by(r, sl, me);
    __atomic_store_n(&sl->gen, sl->gen + 1 == 0 ? 1 : sl->gen + 1, __ATOMIC_RELEASE);
    set_owner(sl, FREE_OWNER);
    sl->next_free = r->free_head;
    r->free_head = s.index;
    if ((w = claim_waiter(&r->takers, NULL))) {
        try_take(r, s.pool, (slc_slot *)w->buf, w->task->id);
        w->task->result = done_result(w, 0);
        pthread_mutex_unlock(&r->mu);
        wake(w->task);
        return;
    }
    pthread_mutex_unlock(&r->mu);
}

/* take every record of t out of every queue (t is not claimable) */
static void withdraw(slc_task *t) {
    int32_t i;
    for (i = 0; i < t->nops; i++) {
        slc_op *op = &t->ops[i];
        if (op->kind >= SLC_K_READ) continue;   /* I/O completed: nothing is linked */
        /* `queued` is read under the lock that guards it: a completer that
         * lost its claim may be unlinking this very record */
        if (op->kind == K_RECV || op->kind == K_SEND) {
            struct chan_rec *r = rec_at(op->chan.idx);
            pthread_mutex_lock(&r->mu);
            unlink_op(op->kind == K_RECV ? &r->recvq : &r->sendq, op);
            pthread_mutex_unlock(&r->mu);
        } else if (op->kind == K_TAKE) {
            struct pool_rec *r = pool_at(op->chan.idx);
            pthread_mutex_lock(&r->mu);
            unlink_op(&r->takers, op);
            pthread_mutex_unlock(&r->mu);
        } else {
            pthread_mutex_lock(&sched);
            timer_remove(op);
            pthread_mutex_unlock(&sched);
        }
    }
}

/* first_of: one pass over the cases from a rotating start. Returns the case
 * that completed, SLC_CASE_CLOSED when every receive case is closed and
 * drained, or NONE. */
static int32_t scan(slc_task *t, slc_op *ops, int32_t n) {
    static uint32_t rotate;
    int32_t start, j, nrecv = 0, nclosed = 0;
    uint64_t now = now_ns();
    if (det_mode) {
        pthread_mutex_lock(&sched);
        start = (int32_t)(next_rand() % (uint64_t)n);
        pthread_mutex_unlock(&sched);
    } else {
        start = (int32_t)(__atomic_fetch_add(&rotate, 1u, __ATOMIC_RELAXED) % (uint32_t)n);
    }
    for (j = 0; j < n; j++) {
        int32_t i = (start + j) % n;
        slc_op *op = &ops[i];
        slc_task *wk = NULL;
        if (op->kind == K_RECV) {
            struct chan_rec *r = lock_chan(op->chan);
            int got = try_recv(r, op->buf, t, &wk);
            pthread_mutex_unlock(&r->mu);
            if (wk) wake(wk);
            nrecv++;
            if (got == 1) return i;
            if (got < 0) nclosed++;
        } else if (op->kind == K_SEND) {
            struct chan_rec *r = lock_chan(op->chan);
            int done = try_send(r, op->buf, t, &wk);
            pthread_mutex_unlock(&r->mu);
            if (wk) wake(wk);
            if (done) return i;
        } else if (op->kind == K_TAKE) {
            struct pool_rec *r = lock_pool(op->chan.idx, op->chan.gen);
            int got = try_take(r, op->chan.idx, (slc_slot *)op->buf, t->id);
            pthread_mutex_unlock(&r->mu);
            if (got) return i;
        } else if (op->deadline <= now) {
            return i;
        }
    }
    if (nrecv > 0 && nclosed == nrecv) return SLC_CASE_CLOSED;
    return NONE;
}

/* first_of: link every case (t is claimable). A case found ready while linking
 * is completed by t itself, if t can still claim itself. */
static int32_t arm(slc_task *t, slc_op *ops, int32_t n) {
    int32_t i, nrecv = 0, nlinked_recv = 0;
    for (i = 0; i < n; i++) {
        slc_op *op = &ops[i];
        if (op->kind == K_AFTER) {
            pthread_mutex_lock(&sched);
            timer_add(op);
            pthread_mutex_unlock(&sched);
            continue;
        }
        if (op->kind == K_TAKE) {
            struct pool_rec *r = lock_pool(op->chan.idx, op->chan.gen);
            if (r->free_head != SLC_NONE) {
                if (!claim(t)) { pthread_mutex_unlock(&r->mu); return SLC_PENDING; }
                try_take(r, op->chan.idx, (slc_slot *)op->buf, t->id);
                pthread_mutex_unlock(&r->mu);
                withdraw(t);
                t->result = i;
                return SLC_NOW;
            }
            enqueue(&r->takers, op);
            pthread_mutex_unlock(&r->mu);
            continue;
        }
        {
            struct chan_rec *r = lock_chan(op->chan);
            int ready;
            if (op->kind == K_RECV) {
                nrecv++;
                if (r->closed && r->count == 0) { pthread_mutex_unlock(&r->mu); continue; }
                ready = r->count > 0 || has_waiter(&r->sendq, t);
            } else {
                ready = r->closed || r->count < r->cap || has_waiter(&r->recvq, t);
            }
            if (ready) {
                slc_task *wk = NULL;
                int done;
                if (!claim(t)) { pthread_mutex_unlock(&r->mu); return SLC_PENDING; }
                done = op->kind == K_RECV ? try_recv(r, op->buf, t, &wk) == 1 : try_send(r, op->buf, t, &wk);
                pthread_mutex_unlock(&r->mu);
                if (wk) wake(wk);
                withdraw(t);
                if (!done) { set_claimable(t); return arm(t, ops, n); }
                t->result = i;
                return SLC_NOW;
            }
            enqueue(op->kind == K_RECV ? &r->recvq : &r->sendq, op);
            if (op->kind == K_RECV) nlinked_recv++;
            pthread_mutex_unlock(&r->mu);
        }
    }
    if (nrecv > 0 && nlinked_recv == 0) {
        /* every receive channel closed while we looked */
        if (!claim(t)) return SLC_PENDING;
        withdraw(t);
        t->result = SLC_CASE_CLOSED;
        return SLC_NOW;
    }
    return SLC_PENDING;
}

int32_t slc_first_of(slc_task *t, slc_op *ops, const slc_case *cases, int32_t n, bool has_default,
                     const char *site) {
    int32_t i, r;
    uint64_t now = now_ns();
    begin(t, ops, n, site);
    for (i = 0; i < n; i++) {
        ops[i].task = t;
        ops[i].kind = cases[i].kind;
        ops[i].chan = cases[i].chan;
        ops[i].buf = cases[i].buf;
        ops[i].index = i;
        ops[i].queued = 0;
        ops[i].deadline = cases[i].kind == K_AFTER ? now + cases[i].ns : 0;
    }
    r = scan(t, ops, n);
    if (r == NONE && has_default) r = SLC_CASE_DEFAULT;
    if (r != NONE) { t->result = r; t->nops = 0; return SLC_NOW; }
    set_claimable(t);
    if (arm(t, ops, n) == SLC_NOW) { t->nops = 0; return SLC_NOW; }
    return SLC_PENDING;
}

/* a waiter resumes: withdraw what is left; a first_of whose channel closed
 * looks again. Returns 1 when the wait is over. */
static int resume_wait(slc_task *t) {
    if (t->result == STALE) slc_trap("channel used after its tasks scope ended");
    if (t->nops == 0) return 1;
    withdraw(t);
    if (t->result == RESCAN) {
        int32_t r = scan(t, t->ops, t->nops);
        if (r != NONE) { t->result = r; t->nops = 0; return 1; }
        set_claimable(t);
        if (arm(t, t->ops, t->nops) == SLC_PENDING) return 0;
    }
    t->nops = 0;
    return 1;
}

/* scopes -------------------------------------------------------------------------------------- */

struct slc_scope {
    slc_scope *parent;       /* the scope its opener was in */
    int live;                /* tasks spawned and not finished */
    slc_task *waiter;
    uint32_t *chans;
    size_t nchans, cap_chans;
    uint32_t *pools;
    size_t npools, cap_pools;
};

slc_scope *slc_scope_new(slc_task *me) {
    slc_scope *s = calloc(1, sizeof *s);
    if (!s) slc_trap("out of memory for a tasks scope");
    s->parent = me->cur_scope;
    me->cur_scope = s;
    if (me->blocking) {
        pthread_mutex_lock(&sched);
        me->depth++;
        set_active(me, 1);
        pthread_mutex_unlock(&sched);
    }
    return s;
}

static int inside(slc_task *me, slc_scope *s) {
    slc_scope *c;
    for (c = me->cur_scope; c; c = c->parent) if (c == s) return 1;
    return 0;
}

static void retire_chan(uint32_t idx) {
    struct chan_rec *r = rec_at(idx);
    slc_op *w, *list = NULL;
    pthread_mutex_lock(&r->mu);
    r->live = false;
    if (++r->gen == 0) r->gen = 1;
    free(r->buf);
    r->buf = NULL;
    /* a waiter with a stale handle finds out when it resumes */
    while ((w = claim_waiter(&r->recvq, NULL))) { w->next = list; list = w; }
    while ((w = claim_waiter(&r->sendq, NULL))) { w->next = list; list = w; }
    pthread_mutex_unlock(&r->mu);
    while (list) {
        slc_op *n = list->next;
        list->task->result = STALE;
        wake(list->task);
        list = n;
    }
    pthread_mutex_lock(&registry);
    r->next_free = free_head;
    free_head = idx;
    pthread_mutex_unlock(&registry);
}

static void retire_pool(uint32_t idx) {
    struct pool_rec *r = pool_at(idx);
    slc_op *w, *list = NULL;
    pthread_mutex_lock(&r->mu);
    r->live = false;
    __atomic_store_n(&r->m->gen, r->m->gen + 1 == 0 ? 1 : r->m->gen + 1, __ATOMIC_RELEASE);
    r->scope = NULL;
    /* the memory stays with the record (see struct pool_rec) */
    while ((w = claim_waiter(&r->takers, NULL))) { w->next = list; list = w; }
    pthread_mutex_unlock(&r->mu);
    while (list) {
        slc_op *n = list->next;
        list->task->result = STALE;
        wake(list->task);
        list = n;
    }
    pthread_mutex_lock(&registry);
    r->next_free = pfree_head;
    pfree_head = idx;
    pthread_mutex_unlock(&registry);
}

static void retire_scope(slc_scope *s) {
    size_t i;
    for (i = 0; i < s->nchans; i++) retire_chan(s->chans[i]);
    for (i = 0; i < s->npools; i++) retire_pool(s->pools[i]);
    free(s->chans);
    free(s->pools);
    free(s);
}

slc_pool slc_pool_new(slc_scope *s, size_t elem, uint32_t n) {
    uint32_t idx, i;
    struct pool_rec *r;
    slc_pool p;
    if (n == 0) slc_trap("a pool needs at least one slot");
    pthread_mutex_lock(&registry);
    {
        /* a retired record whose memory fits */
        uint32_t *link = &pfree_head;
        idx = SLC_NONE;
        while (*link != SLC_NONE) {
            struct pool_rec *c = pool_at(*link);
            if (c->cap_slots >= n && c->cap_bytes >= (size_t)n * elem) {
                idx = *link;
                *link = c->next_free;
                break;
            }
            link = &c->next_free;
        }
    }
    if (idx == SLC_NONE) {
        idx = npools;
        if (idx / CHUNK >= CHUNKS) { pthread_mutex_unlock(&registry); slc_trap("too many pools"); }
        if (!pchunks[idx / CHUNK]) {
            uint32_t k;
            struct pool_rec *chunk = calloc(CHUNK, sizeof *chunk);
            slc_pool_meta *metas = calloc(CHUNK, sizeof *metas);
            if (!chunk || !metas) { pthread_mutex_unlock(&registry); slc_trap("out of memory for pools"); }
            for (k = 0; k < CHUNK; k++) {
                pthread_mutex_init(&chunk[k].mu, NULL);
                chunk[k].m = &metas[k];
            }
            slc_pool_metas[idx / CHUNK] = metas;
            pchunks[idx / CHUNK] = chunk;
        }
        npools++;
    }
    pthread_mutex_unlock(&registry);
    r = pool_at(idx);
    pthread_mutex_lock(&r->mu);
    if (r->m->gen == 0) r->m->gen = 1;
    r->live = true;
    r->m->elem = elem;
    r->m->n = n;
    r->scope = s;
    if (!r->m->data) {
        r->m->data = calloc(n, elem ? elem : 1);
        r->m->slots = calloc(n, sizeof *r->m->slots);
        if (!r->m->data || !r->m->slots) { pthread_mutex_unlock(&r->mu); slc_trap("out of memory for a pool"); }
        r->cap_bytes = (size_t)n * elem;
        r->cap_slots = n;
    } else {
        memset(r->m->data, 0, (size_t)n * elem);
    }
    for (i = 0; i < n; i++) {
        /* generations only grow: a stale slot from an earlier pool stays stale */
        if (r->m->slots[i].gen == 0) r->m->slots[i].gen = 1;
        set_owner(&r->m->slots[i], FREE_OWNER);
        r->m->slots[i].next_free = i + 1 < n ? i + 1 : SLC_NONE;
    }
    r->free_head = 0;
    r->takers.head = r->takers.tail = NULL;
    p.idx = idx;
    p.gen = r->m->gen;
    pthread_mutex_unlock(&r->mu);
    pthread_mutex_lock(&sched);
    if (s->npools == s->cap_pools) {
        size_t m = s->cap_pools ? s->cap_pools * 2 : 4;
        uint32_t *a = realloc(s->pools, m * sizeof *a);
        if (!a) { pthread_mutex_unlock(&sched); slc_trap("out of memory for a pool"); }
        s->pools = a;
        s->cap_pools = m;
    }
    s->pools[s->npools++] = idx;
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
        retire_scope(s);
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
    if (free_head != SLC_NONE) {
        idx = free_head;
        free_head = rec_at(idx)->next_free;
    } else {
        idx = nrecs;
        if (idx / CHUNK >= CHUNKS) { pthread_mutex_unlock(&registry); slc_trap("too many channels"); }
        if (!chunks[idx / CHUNK]) {
            uint32_t k;
            struct chan_rec *chunk = calloc(CHUNK, sizeof *chunk);
            if (!chunk) { pthread_mutex_unlock(&registry); slc_trap("out of memory for channels"); }
            for (k = 0; k < CHUNK; k++) pthread_mutex_init(&chunk[k].mu, NULL);
            chunks[idx / CHUNK] = chunk;
        }
        nrecs++;
    }
    pthread_mutex_unlock(&registry);
    r = rec_at(idx);
    pthread_mutex_lock(&r->mu);
    if (r->gen == 0) r->gen = 1;
    r->live = true;
    r->closed = false;
    r->elem = elem;
    r->cap = cap;
    r->head = r->count = 0;
    r->recvq.head = r->recvq.tail = NULL;
    r->sendq.head = r->sendq.tail = NULL;
    r->buf = cap ? malloc((size_t)cap * elem) : NULL;
    if (cap && !r->buf) { pthread_mutex_unlock(&r->mu); slc_trap("out of memory for a channel"); }
    c.idx = idx;
    c.gen = r->gen;
    pthread_mutex_unlock(&r->mu);
    pthread_mutex_lock(&sched);
    if (s->nchans == s->cap_chans) {
        size_t n = s->cap_chans ? s->cap_chans * 2 : 8;
        uint32_t *a = realloc(s->chans, n * sizeof *a);
        if (!a) { pthread_mutex_unlock(&sched); slc_trap("out of memory for a channel"); }
        s->chans = a;
        s->cap_chans = n;
    }
    s->chans[s->nchans++] = idx;
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
    if (nrunning == 0 && rq_len == 0 && nlocal == 0 && nheap == 0 && nio == 0 && nactive_plain == 0
        && nparked + nblocked > 0)
        deadlock();
}

/* wait for work or a timer (sched held) */
static void idle(void) {
    init_me();
    /* a fired timer may have woken this very thread: let the caller look again */
    if (fire_timers()) return;
    if (rq_len || runnext) return;
    check_deadlock();
    if (!me.listed) {
        me.next = idlers;
        idlers = &me;
        me.listed = 1;
    }
    if (nheap) {
        uint64_t d = heap[0]->deadline;
        struct timespec ts;
        ts.tv_sec = (time_t)(d / 1000000000ull);
        ts.tv_nsec = (long)(d % 1000000000ull);
        pthread_cond_timedwait(&me.cv, &sched, &ts);
    } else {
        pthread_cond_wait(&me.cv, &sched);
    }
    if (me.listed) {
        struct idler **p = &idlers;
        while (*p && *p != &me) p = &(*p)->next;
        if (*p) *p = me.next;
        me.listed = 0;
    }
}

static void finish(slc_task *t) {
    slc_scope *s = t->scope;
    slc_task *waiter = NULL;
    pthread_mutex_lock(&sched);
    if (t->all_prev) t->all_prev->all_next = t->all_next; else all_tasks = t->all_next;
    if (t->all_next) t->all_next->all_prev = t->all_prev;
    if (--s->live == 0 && s->waiter && claim(s->waiter)) waiter = s->waiter;
    pthread_mutex_unlock(&sched);
    slc_stacks_free(&t->stacks);
    free(t);
    if (waiter) {
        retire_scope(s);
        wake(waiter);
    }
}

/* run one step of a task taken from the queue (sched held on entry and exit) */
static void step_task(slc_task *t) {
    slc_step r;
    t->run = RUN_RUNNING;
    nrunning++;
    pthread_mutex_unlock(&sched);
    __atomic_store_n(&t->claimed, 1, __ATOMIC_RELEASE);
    if (!resume_wait(t)) {
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

static void init(void) {
    const char *seed = getenv("SLC_SCHED_SEED");
    const char *nw = getenv("SLC_WORKERS");
    long n, i;
    if (seed && *seed) {
        det_mode = 1;
        rng = strtoull(seed, NULL, 10) * 2654435761ull + 1;
        return;                             /* no workers: blocked threads run everything */
    }
    n = nw ? strtol(nw, NULL, 10) : sysconf(_SC_NPROCESSORS_ONLN);
    if (n < 1) n = 1;
    for (i = 0; i < n; i++) {
        pthread_t th;
        pthread_attr_t at;
        pthread_attr_init(&at);
        pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&th, &at, worker, NULL) != 0) slc_trap("cannot start a worker");
        pthread_attr_destroy(&at);
    }
}

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
    s->live++;
    t->all_next = all_tasks;
    if (all_tasks) all_tasks->all_prev = t;
    all_tasks = t;
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
        if (resume_wait(t)) {
            pthread_mutex_lock(&sched);
            set_active(t, t->depth > 0);
            pthread_mutex_unlock(&sched);
            return;
        }
    }
}

/* I/O ----------------------------------------------------------------------------------------- */

void slc_io_complete(slc_op *op, int32_t status, int64_t value) {
    slc_task *t = op->task;
    *op->value = value;
    if (!claim(t)) slc_trap("an I/O operation completed twice");
    t->result = status;
    pthread_mutex_lock(&sched);
    nio--;
    wake_locked(t);
    pthread_mutex_unlock(&sched);
}

static int32_t io_start(slc_task *t, slc_op *ops, int32_t kind, int32_t fd, void *buf, uint32_t n, int64_t offset,
                        uint64_t deadline, int64_t *value, const char *site) {
    slc_op *op = &ops[0];
    begin(t, ops, 1, site);
    op->task = t; op->kind = kind; op->index = -1; op->queued = 0;
    op->fd = fd; op->buf = buf; op->len = n; op->offset = offset; op->value = value; op->backend = NULL;
    op->deadline = deadline ? now_ns() + deadline : 0;
    pthread_once(&once, init);
    set_claimable(t);
    pthread_mutex_lock(&sched);
    nio++;
    pthread_mutex_unlock(&sched);
    slc_backend_submit(op);
    return SLC_PENDING;
}

int32_t slc_io_read(slc_task *t, slc_op *ops, int32_t fd, void *buf, uint32_t n, int64_t offset, uint64_t deadline,
                    int64_t *value, const char *site) {
    return io_start(t, ops, SLC_K_READ, fd, buf, n, offset, deadline, value, site);
}

int32_t slc_io_write(slc_task *t, slc_op *ops, int32_t fd, const void *buf, uint32_t n, int64_t offset,
                     uint64_t deadline, int64_t *value, const char *site) {
    return io_start(t, ops, SLC_K_WRITE, fd, (void *)(uintptr_t)buf, n, offset, deadline, value, site);
}

int32_t slc_io_accept(slc_task *t, slc_op *ops, int32_t fd, uint64_t deadline, int64_t *value, const char *site) {
    return io_start(t, ops, SLC_K_ACCEPT, fd, NULL, 0, -1, deadline, value, site);
}

int32_t slc_io_connect(slc_task *t, slc_op *ops, uint32_t host, uint32_t port, uint64_t deadline, int64_t *value,
                       const char *site) {
    /* host and port travel in the offset: the backend makes the socket */
    return io_start(t, ops, SLC_K_CONNECT, -1, NULL, port, (int64_t)host, deadline, value, site);
}

int32_t slc_io_open(slc_task *t, slc_op *ops, const char *path, int32_t flags, uint32_t mode, int64_t *value,
                    const char *site) {
    return io_start(t, ops, SLC_K_OPEN, flags, (void *)(uintptr_t)path, mode, -1, 0, value, site);
}

int32_t slc_io_close(slc_task *t, slc_op *ops, int32_t fd, int64_t *value, const char *site) {
    return io_start(t, ops, SLC_K_CLOSE, fd, NULL, 0, -1, 0, value, site);
}

/* blocking threads --------------------------------------------------------------------------
 * Calls into C that may block run here, not on a worker: one thread per job in
 * flight, made on demand and kept for reuse. */

struct bjob { void (*fn)(void *); void *arg; struct bjob *next; };
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
        j = bhead;
        bhead = j->next;
        if (!bhead) btail = NULL;
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
    j->next = NULL;
    pthread_mutex_lock(&bmu);
    if (btail) btail->next = j; else bhead = j;
    btail = j;
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
