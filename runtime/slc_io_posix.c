/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* Native callback ABI adapters only. POSIX operation policy is posix.slc. */
#include "slc_io_posix.h"

static void open_close(void *arg) { slc_posix_open_close(arg); }
static void file_io(void *arg) { slc_posix_file_io(arg); }

void slc_posix_submit_open_close(slc_op *op) { slc_run_blocking(open_close, op); }
void slc_posix_submit_file(slc_op *op) { slc_run_blocking(file_io, op); }
