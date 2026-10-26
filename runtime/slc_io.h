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

/* Submission/completion accounting is synchronized by the scheduler. */
void slc_io_publish(slc_op *op);
void slc_io_notify(slc_task *task);
/* Internal mutable-pointer entries behind the public const-pointer ABI. */
int32_t slc_io_write_bytes(slc_task *, slc_op *, int32_t, void *, uint32_t, int64_t, uint64_t, int64_t *, const char *);
int32_t slc_io_open_path(slc_task *, slc_op *, void *, int32_t, uint32_t, int64_t *, const char *);
/* deadline of an operation: absolute monotonic nanoseconds, or 0 */
#endif
