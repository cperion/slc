/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
#ifndef SLC_IO_URING_H
#define SLC_IO_URING_H
#include "slc_io_posix.h"
#include <pthread.h>
#include <linux/io_uring.h>
#include <netinet/in.h>
typedef struct {
    pthread_mutex_t mu;
    int32_t fd;
    uint32_t *sq_head, *sq_tail, *sq_mask, *sq_array, sq_entries;
    uint32_t *cq_head, *cq_tail, *cq_mask;
    struct io_uring_sqe *sqes;
    struct io_uring_cqe *cqes;
} slc_uring_state;
typedef struct { struct __kernel_timespec ts; struct sockaddr_in addr; } slc_uring_extra;
int32_t slc_uring_enter(slc_uring_state *, uint32_t submit, uint32_t wait, uint32_t flags);
/* Kernel ABI marshalling: io_uring encodes addresses in integer fields. */
void slc_uring_address(struct io_uring_sqe *, void *);
void slc_uring_user(struct io_uring_sqe *, slc_op *);
slc_op *slc_uring_decode(uint64_t);
void slc_uring_submit(slc_uring_state *, slc_op *);
void slc_uring_run(slc_uring_state *);
#endif
