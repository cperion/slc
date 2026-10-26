/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* slc runtime: the interface between the scheduler and an I/O backend.
 *
 * A backend file (slc_io_poll.c, slc_io_uring.c or slc_io_kqueue.c) is linked
 * with slc_tasks.c. The scheduler hands it operation records; the backend
 * calls slc_io_complete exactly once per record, from any thread. */
#ifndef SLC_IO_H
#define SLC_IO_H
#include "slc_rt.h"

enum { SLC_K_READ = 20, SLC_K_WRITE, SLC_K_ACCEPT, SLC_K_CONNECT, SLC_K_OPEN, SLC_K_CLOSE, SLC_K_BLOCKING };

/* run fn(arg) on a blocking thread (for a backend's own blocking work, such as
 * regular-file I/O on a readiness backend) */
void slc_run_blocking(void (*fn)(void *), void *arg);

/* start an operation; it completes later (or at once) through slc_io_complete */
void slc_backend_submit(slc_op *op);
/* provided by the scheduler */
void slc_io_complete(slc_op *op, int32_t status, int64_t value);
uint64_t slc_now_ns(void);

/* deadline of an operation: absolute monotonic nanoseconds, or 0 */
#endif
