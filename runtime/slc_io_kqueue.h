/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
#ifndef SLC_IO_KQUEUE_H
#define SLC_IO_KQUEUE_H
#include "slc_io_posix.h"
#include <pthread.h>
#include <sys/event.h>
#include <time.h>
typedef struct { slc_op *head, *tail; } slc_fd_waiters;
typedef struct { slc_fd_waiters read, write; } slc_fd_queue;
typedef struct {
    pthread_mutex_t mu;
    int32_t kq;
    slc_op *incoming;
    slc_fd_queue *fds;
    uint64_t capacity;
} slc_kqueue_state;
void slc_kqueue_prepare(slc_kqueue_state *state);
void slc_kqueue_submit(slc_kqueue_state *state, slc_op *op);
void slc_kqueue_run(slc_kqueue_state *state);
#endif
