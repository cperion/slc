/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* slc runtime: POSIX helpers shared by the I/O backends. */
#ifndef SLC_IO_POSIX_H
#define SLC_IO_POSIX_H
#include "slc_io.h"

int slc_io_nonblocking(int fd);
/* open, close, and the start of a connect complete here (1); otherwise 0: wait */
int slc_io_prepare(slc_op *op);
/* does the operation wait to write (or to read)? */
int slc_io_wants_write(const slc_op *op);
/* the descriptor is ready: perform the operation; 0 when it would still block */
int slc_io_try(slc_op *op);
/* a read or write of a regular file: handed to a blocking thread (1), since
 * such a file is always "ready" and the call blocks; otherwise 0 */
int slc_io_offload_file(slc_op *op);
/* an operation given up on (its deadline passed) releases what it holds */
void slc_io_abandon(slc_op *op);
/* Native callback ABI adapters; worker bodies are ordinary SLC. */
void slc_posix_open_close(slc_op *op);
void slc_posix_file_io(slc_op *op);
void slc_posix_submit_open_close(slc_op *op);
void slc_posix_submit_file(slc_op *op);
#endif
