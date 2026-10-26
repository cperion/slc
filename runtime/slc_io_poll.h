/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
#ifndef SLC_IO_POLL_H
#define SLC_IO_POLL_H
#include "slc_io_posix.h"
#include <pthread.h>
#include <poll.h>
typedef struct {
    pthread_mutex_t mu;
    int32_t reader, writer;
    slc_op **pending;
    uint64_t count, capacity;
} slc_poll_state;
void slc_poll_prepare(slc_poll_state *state);
void slc_poll_submit(slc_poll_state *state, slc_op *op);
void slc_poll_run(slc_poll_state *state);
#endif
