/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
#ifndef SLC_SCHEDULER_H
#define SLC_SCHEDULER_H
#include "slc_rt.h"
#include <pthread.h>

/* Shared internal layouts. SLC initializes mutexes through pthread's foreign
 * API; lock acquisition and release remain in the synchronization envelope. */
struct slc_scope {
    slc_scope *parent;
    int live;
    slc_task *waiter;
    uint32_t *chans;
    size_t nchans, cap_chans;
    uint32_t *pools;
    size_t npools, cap_pools;
};
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
struct pool_rec {
    pthread_mutex_t mu;
    slc_pool_meta *m;
    bool live;
    uint32_t free_head;
    size_t cap_bytes;
    uint32_t cap_slots;
    slc_scope *scope;
    struct queue takers;
    uint32_t next_free;
};

/* Internal policy state. The caller holds the owning scheduler/channel/pool
 * lock throughout each call. Words may claim atomically, but never wait,
 * unlock or wake threads. */
typedef struct { slc_task *head, *tail; uint64_t len; } slc_run_queue;
typedef struct { slc_op **data; uint64_t len, cap; } slc_timer_heap;
uint64_t slc_sched_random(uint64_t *state);
void slc_sched_push(slc_run_queue *q, slc_task *task);
slc_task *slc_sched_pop(slc_run_queue *q, uint64_t index);
slc_task *slc_sched_next(slc_run_queue *q, uint64_t *state, bool deterministic);
bool slc_timer_add(slc_timer_heap *h, slc_op *op);
void slc_timer_remove(slc_timer_heap *h, slc_op *op);
int32_t slc_op_result(slc_op *op, int32_t plain);
bool slc_task_claim(slc_task *task);
void slc_wait_enqueue(struct queue *q, slc_op *op);
void slc_wait_unlink(struct queue *q, slc_op *op);
slc_op *slc_wait_claim(struct queue *q, slc_task *self);
bool slc_wait_has(struct queue *q, slc_task *self);
int32_t slc_channel_recv(struct chan_rec *r, uint8_t *out, slc_task *self, slc_task **wake);
int32_t slc_channel_send(struct chan_rec *r, uint8_t *value, slc_task *self, slc_task **wake);
bool slc_pool_take(struct pool_rec *r, uint32_t pool, slc_slot *out, uint64_t owner);
void slc_pool_recycle(struct pool_rec *r, uint32_t index);
slc_scope *slc_scope_allocate(slc_task *task);
bool slc_scope_inside(slc_task *task, slc_scope *scope);
bool slc_scope_record(uint32_t **items, uint64_t *count, uint64_t *capacity, uint64_t initial, uint32_t index);
uint32_t slc_channel_reuse(struct chan_rec **chunks, uint32_t *head);
uint32_t slc_pool_reuse(struct pool_rec **chunks, uint32_t *head, uint32_t n, uint64_t elem);
bool slc_channel_initialize(struct chan_rec *r, uint64_t elem, uint32_t cap);
bool slc_pool_initialize(struct pool_rec *r, slc_scope *s, uint64_t elem, uint32_t n);
slc_op *slc_channel_retire(struct chan_rec *r);
slc_op *slc_pool_retire(struct pool_rec *r);
void slc_channel_recycle_record(struct chan_rec *r, uint32_t *head, uint32_t index);
void slc_pool_recycle_record(struct pool_rec *r, uint32_t *head, uint32_t index);
/* Registry calls hold registry; -1 means full, -2 allocation failure. */
int32_t slc_channel_acquire(struct chan_rec **chunks, uint32_t *head, uint32_t *count);
int32_t slc_pool_acquire(struct pool_rec **chunks, slc_pool_meta **metas, uint32_t *head,
                         uint32_t *count, uint32_t n, uint64_t elem);
slc_op *slc_channel_close_waiters(struct chan_rec *r);
/* Teardown orchestration runs without the object lock; these callbacks own
 * synchronization and wake transitions, not list traversal policy. */
void slc_task_wake(slc_task *task);
void slc_retire_channel_sync(uint32_t index);
void slc_retire_pool_sync(uint32_t index);
void slc_wait_wake(slc_op *list, int32_t plain, int32_t selected, bool clear);
void slc_scope_retire(slc_scope *scope);
extern struct chan_rec *slc_channel_chunks[4096];
extern struct pool_rec *slc_pool_chunks[4096];
void slc_timer_register(slc_op *op);
void slc_timer_cancel(slc_op *op);
uint64_t slc_select_ticket(void);
bool slc_resume_wait(slc_task *task);
struct idler { pthread_cond_t cv; struct idler *next; int listed, ready; };
struct bjob { void (*fn)(void *); void *arg; struct bjob *next; };
void slc_idler_signal(struct idler **head);
void slc_idler_enqueue(struct idler **head, struct idler *thread);
void slc_idler_remove(struct idler **head, struct idler *thread);
void slc_task_attach(slc_task **head, slc_task *task);
slc_task *slc_task_detach(slc_task **head, slc_task *task);
void slc_blocked_remove(slc_task **head, slc_task *task);
void slc_job_enqueue(struct bjob **head, struct bjob **tail, struct bjob *job);
struct bjob *slc_job_dequeue(struct bjob **head, struct bjob **tail);
bool slc_timer_fire(slc_timer_heap *heap, uint64_t now);
void slc_wake_locked(slc_task *task);
void slc_workers_init(int32_t *deterministic, uint64_t *seed);
void slc_worker_start(void);
#endif
