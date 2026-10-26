/* slc runtime: the kqueue backend (macOS, the BSDs; on Linux through libkqueue).
 *
 * Submitters queue operations and trigger a user event; the poller thread
 * alone touches kqueue state. Operations wait per descriptor and direction;
 * a ready descriptor runs its waiting operations in order until one would
 * block. An operation past its deadline completes as timed out, having done
 * nothing. */
#define _DEFAULT_SOURCE
#include "slc_io_posix.h"
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/event.h>
#include <sys/stat.h>

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static int kq;
static slc_op *incoming;            /* submitted, not yet seen by the poller (linked by next) */

struct waiters { slc_op *head, *tail; };
struct fdq { struct waiters dir[2]; };          /* 0 read, 1 write */
static struct fdq *fds;
static size_t nfds;

const char *slc_io_backend(void) { return "kqueue"; }

static void *poller(void *arg);

static void start(void) {
    struct kevent ev;
    pthread_t th;
    pthread_attr_t at;
    kq = kqueue();
    if (kq < 0) slc_trap("cannot make a kqueue");
    EV_SET(&ev, 0, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0, NULL);
    if (kevent(kq, &ev, 1, NULL, 0, NULL) < 0) slc_trap("cannot register the kqueue wake-up");
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&th, &at, poller, NULL) != 0) slc_trap("cannot start the kqueue poller");
    pthread_attr_destroy(&at);
}

void slc_backend_submit(slc_op *op) {
    struct kevent ev;
    pthread_once(&once, start);
    if (slc_io_prepare(op) || slc_io_offload_file(op)) return;
    pthread_mutex_lock(&mu);
    op->next = incoming;
    incoming = op;
    pthread_mutex_unlock(&mu);
    EV_SET(&ev, 0, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
    kevent(kq, &ev, 1, NULL, 0, NULL);
}

static struct fdq *queue_of(int fd) {
    if ((size_t)fd >= nfds) {
        size_t n = nfds ? nfds : 64;
        struct fdq *f;
        while (n <= (size_t)fd) n *= 2;
        f = realloc(fds, n * sizeof *f);
        if (!f) slc_trap("out of memory for I/O");
        memset(f + nfds, 0, (n - nfds) * sizeof *f);
        fds = f;
        nfds = n;
    }
    return &fds[fd];
}

/* registrations are one-shot: once an event fires, the poller never touches
 * that descriptor again unless an operation still waits on it (the woken task
 * may close it at once, and its number be reused) */
static int watch(int fd, int dir, int on) {
    struct kevent ev;
    EV_SET(&ev, (uintptr_t)fd, dir ? EVFILT_WRITE : EVFILT_READ, on ? EV_ADD | EV_ONESHOT : EV_DELETE, 0, 0, NULL);
    return kevent(kq, &ev, 1, NULL, 0, NULL);
}

static void push(struct waiters *w, slc_op *op) {
    op->next = NULL;
    op->prev = w->tail;
    if (w->tail) w->tail->next = op; else w->head = op;
    w->tail = op;
}

static void unlink_op(struct waiters *w, slc_op *op) {
    if (op->prev) op->prev->next = op->next; else w->head = op->next;
    if (op->next) op->next->prev = op->prev; else w->tail = op->prev;
    op->next = op->prev = NULL;
}

/* run the waiting operations of a ready descriptor until one would block.
 * At EV_EOF kqueue reports the socket's error in fflags: a connect that
 * failed is told so here (its SO_ERROR may already have been read). */
static void ready(int fd, int dir, int eof_error) {
    struct waiters *w = &queue_of(fd)->dir[dir];
    while (w->head) {
        slc_op *op = w->head;
        unlink_op(w, op);
        if (eof_error && op->kind == SLC_K_CONNECT) {
            close(op->fd);
            slc_io_complete(op, SLC_IO_FAILED, eof_error);
            continue;
        }
        if (!slc_io_try(op)) {
            /* still blocked: back at the front, and armed again */
            op->next = w->head;
            op->prev = NULL;
            if (w->head) w->head->prev = op; else w->tail = op;
            w->head = op;
            break;
        }
    }
    /* the one-shot event fired: arm again only for operations still waiting */
    if (w->head && watch(fd, dir, 1) < 0) {
        int e = errno;
        while (w->head) {
            slc_op *op = w->head;
            unlink_op(w, op);
            slc_io_complete(op, SLC_IO_FAILED, e);
        }
    }
}

static void *poller(void *arg) {
    struct kevent evs[64];
    (void)arg;
    for (;;) {
        slc_op *in;
        size_t f;
        int d, n, i;
        uint64_t now, soonest = 0;
        struct timespec ts, *tp = NULL;
        pthread_mutex_lock(&mu);
        in = incoming;
        incoming = NULL;
        pthread_mutex_unlock(&mu);
        while (in) {
            slc_op *next = in->next;
            int dir = slc_io_wants_write(in);
            struct waiters *w;
            w = &queue_of(in->fd)->dir[dir];
            if (w->head == NULL && watch(in->fd, dir, 1) < 0) {
                int e = errno;
                if (!slc_io_try(in)) slc_io_complete(in, SLC_IO_FAILED, e);
                in = next;
                continue;
            }
            push(w, in);
            in = next;
        }
        /* the nearest deadline bounds the wait */
        for (f = 0; f < nfds; f++)
            for (d = 0; d < 2; d++) {
                slc_op *op;
                for (op = fds[f].dir[d].head; op; op = op->next)
                    if (op->deadline && (!soonest || op->deadline < soonest)) soonest = op->deadline;
            }
        if (soonest) {
            uint64_t t = slc_now_ns(), left = soonest > t ? soonest - t : 0;
            ts.tv_sec = (time_t)(left / 1000000000ull);
            ts.tv_nsec = (long)(left % 1000000000ull);
            tp = &ts;
        }
        n = kevent(kq, NULL, 0, evs, 64, tp);
        for (i = 0; i < n; i++) {
            if (evs[i].filter == EVFILT_USER) continue;
            ready((int)evs[i].ident, evs[i].filter == EVFILT_WRITE,
                  (evs[i].flags & EV_EOF) ? (int)evs[i].fflags : 0);
        }
        now = slc_now_ns();
        for (f = 0; f < nfds; f++)
            for (d = 0; d < 2; d++) {
                slc_op *op = fds[f].dir[d].head;
                while (op) {
                    slc_op *next = op->next;
                    if (op->deadline && now >= op->deadline) {
                        unlink_op(&fds[f].dir[d], op);
                        if (!fds[f].dir[d].head) watch((int)f, d, 0);   /* before completing it */
                        slc_io_abandon(op);
                        slc_io_complete(op, SLC_IO_TIMED_OUT, 0);
                    }
                    op = next;
                }
            }
    }
    return NULL;
}
