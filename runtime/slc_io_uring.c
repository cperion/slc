/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* Linux mapping/syscall and native thread boundaries. Ring and operation
 * policy lives in uring.slc; addresses cross the kernel's integer ABI here. */
#define _GNU_SOURCE
#include "slc_io_uring.h"
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/syscall.h>

static pthread_once_t once = PTHREAD_ONCE_INIT;
static slc_uring_state state = { .mu = PTHREAD_MUTEX_INITIALIZER };
const char *slc_io_backend(void) { return "io_uring"; }
int32_t slc_uring_enter(slc_uring_state *s, uint32_t submit, uint32_t wait, uint32_t flags) {
    return (int32_t)syscall(__NR_io_uring_enter, s->fd, submit, wait, flags, NULL, 0);
}
void slc_uring_address(struct io_uring_sqe *sqe, void *p) { sqe->addr = (uint64_t)(uintptr_t)p; }
void slc_uring_user(struct io_uring_sqe *sqe, slc_op *op) { sqe->user_data = (uint64_t)(uintptr_t)op; }
slc_op *slc_uring_decode(uint64_t data) { return (slc_op *)(uintptr_t)data; }
static void *poller(void *arg) { slc_uring_run(arg); return NULL; }

static void start(void) {
    struct io_uring_params p;
    size_t sq_size, cq_size;
    unsigned char *sq, *cq;
    pthread_t thread;
    pthread_attr_t attr;
    slc_uring_state *s = &state;
    memset(&p, 0, sizeof p);
    s->fd = (int)syscall(__NR_io_uring_setup, 256, &p);
    if (s->fd < 0) slc_trap("io_uring_setup failed (link the poll backend instead)");
    sq_size = p.sq_off.array + p.sq_entries * sizeof(unsigned);
    cq_size = p.cq_off.cqes + p.cq_entries * sizeof(struct io_uring_cqe);
    if (p.features & IORING_FEAT_SINGLE_MMAP) {
        if (cq_size > sq_size) sq_size = cq_size;
        cq_size = sq_size;
    }
    sq = mmap(NULL, sq_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, s->fd, IORING_OFF_SQ_RING);
    if (sq == MAP_FAILED) slc_trap("cannot map the io_uring submission ring");
    if (p.features & IORING_FEAT_SINGLE_MMAP) cq = sq;
    else {
        cq = mmap(NULL, cq_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, s->fd, IORING_OFF_CQ_RING);
        if (cq == MAP_FAILED) slc_trap("cannot map the io_uring completion ring");
    }
    s->sqes = mmap(NULL, p.sq_entries * sizeof(struct io_uring_sqe), PROT_READ | PROT_WRITE,
                   MAP_SHARED | MAP_POPULATE, s->fd, IORING_OFF_SQES);
    if (s->sqes == MAP_FAILED) slc_trap("cannot map the io_uring entries");
    s->sq_head = (unsigned *)(sq + p.sq_off.head);
    s->sq_tail = (unsigned *)(sq + p.sq_off.tail);
    s->sq_mask = (unsigned *)(sq + p.sq_off.ring_mask);
    s->sq_array = (unsigned *)(sq + p.sq_off.array);
    s->sq_entries = p.sq_entries;
    s->cq_head = (unsigned *)(cq + p.cq_off.head);
    s->cq_tail = (unsigned *)(cq + p.cq_off.tail);
    s->cq_mask = (unsigned *)(cq + p.cq_off.ring_mask);
    s->cqes = (struct io_uring_cqe *)(cq + p.cq_off.cqes);
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&thread, &attr, poller, s) != 0) slc_trap("cannot start the io_uring poller");
    pthread_attr_destroy(&attr);
}
void slc_backend_submit(slc_op *op) {
    pthread_once(&once, start);
    slc_uring_submit(&state, op);
}
