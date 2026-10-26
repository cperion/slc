/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* Native thread/bootstrap boundary; kqueue policy and event loop are SLC. */
#define _DEFAULT_SOURCE
#include "slc_io_kqueue.h"

static pthread_once_t once = PTHREAD_ONCE_INIT;
static slc_kqueue_state state = { .mu = PTHREAD_MUTEX_INITIALIZER };
const char *slc_io_backend(void) { return "kqueue"; }
static void *poller(void *arg) { slc_kqueue_run(arg); return NULL; }
static void start(void) {
    pthread_t thread;
    pthread_attr_t attr;
    slc_kqueue_prepare(&state);
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&thread, &attr, poller, &state) != 0) slc_trap("cannot start the kqueue poller");
    pthread_attr_destroy(&attr);
}
void slc_backend_submit(slc_op *op) {
    pthread_once(&once, start);
    slc_kqueue_submit(&state, op);
}
