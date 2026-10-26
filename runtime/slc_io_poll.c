/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* slc runtime: the poll(2) backend, for any POSIX system.
 *
 * One poller thread waits on every pending operation's descriptor and on a
 * wake-up pipe. A ready descriptor's operation is performed without blocking;
 * an operation past its deadline completes as timed out, having done nothing. */
#define _POSIX_C_SOURCE 200809L
#include "slc_io_posix.h"
#include <poll.h>
#include <pthread.h>
#include <stdlib.h>
#include <unistd.h>

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static int wake_fds[2];
static slc_op **pending;
static size_t npending, cap;

const char *slc_io_backend(void) { return "poll"; }

static void *poller(void *arg);

static void start(void) {
    pthread_t th;
    pthread_attr_t at;
    if (pipe(wake_fds) < 0) slc_trap("cannot make the I/O wake-up pipe");
    slc_io_nonblocking(wake_fds[0]);
    slc_io_nonblocking(wake_fds[1]);
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&th, &at, poller, NULL) != 0) slc_trap("cannot start the I/O poller");
    pthread_attr_destroy(&at);
}

static void wake_poller(void) {
    char c = 1;
    ssize_t r = write(wake_fds[1], &c, 1);
    (void)r;                            /* a full pipe already means "look again" */
}

void slc_backend_submit(slc_op *op) {
    pthread_once(&once, start);
    if (slc_io_prepare(op) || slc_io_offload_file(op)) return;
    pthread_mutex_lock(&mu);
    if (npending == cap) {
        size_t n = cap ? cap * 2 : 16;
        slc_op **p = realloc(pending, n * sizeof *p);
        if (!p) { pthread_mutex_unlock(&mu); slc_trap("out of memory for I/O"); }
        pending = p;
        cap = n;
    }
    pending[npending++] = op;
    pthread_mutex_unlock(&mu);
    wake_poller();
}

static void *poller(void *arg) {
    struct pollfd *fds = NULL;
    size_t capfds = 0;
    (void)arg;
    for (;;) {
        size_t n, i, k;
        int timeout = -1;
        uint64_t now;
        char buf[64];
        pthread_mutex_lock(&mu);
        n = npending;
        if (n + 1 > capfds) {
            struct pollfd *f = realloc(fds, (n + 1) * sizeof *f);
            if (!f) { pthread_mutex_unlock(&mu); slc_trap("out of memory for I/O"); }
            fds = f;
            capfds = n + 1;
        }
        fds[0].fd = wake_fds[0];
        fds[0].events = POLLIN;
        now = slc_now_ns();
        for (i = 0; i < n; i++) {
            slc_op *op = pending[i];
            fds[i + 1].fd = op->fd;
            fds[i + 1].events = slc_io_wants_write(op) ? POLLOUT : POLLIN;
            fds[i + 1].revents = 0;
            if (op->deadline) {
                uint64_t left = op->deadline > now ? op->deadline - now : 0;
                int ms = (int)((left + 999999u) / 1000000u);
                if (timeout < 0 || ms < timeout) timeout = ms;
            }
        }
        pthread_mutex_unlock(&mu);

        poll(fds, (nfds_t)(n + 1), timeout);
        while (read(wake_fds[0], buf, sizeof buf) > 0) {}

        /* only this thread removes, so the first n entries are the ones polled */
        pthread_mutex_lock(&mu);
        now = slc_now_ns();
        for (i = 0; i < n; i++) {
            slc_op *op = pending[i];
            if (fds[i + 1].revents && slc_io_try(op)) {
                pending[i] = NULL;
            } else if (op->deadline && now >= op->deadline) {
                pending[i] = NULL;
                slc_io_abandon(op);
                slc_io_complete(op, SLC_IO_TIMED_OUT, 0);
            }
        }
        for (i = k = 0; i < npending; i++) if (pending[i]) pending[k++] = pending[i];
        npending = k;
        pthread_mutex_unlock(&mu);
    }
    return NULL;
}
