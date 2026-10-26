/* slc runtime: the io_uring backend (Linux), on raw system calls.
 *
 * Submitting writes a submission entry and enters the kernel at once; one
 * poller thread waits for completions. A deadline is a linked timeout: the
 * kernel cancels the operation if the timeout fires first, and the operation
 * completes with -ECANCELED, which is `timed_out`. If the operation finished
 * first, its result stands. */
#define _GNU_SOURCE
#include "slc_io_posix.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <linux/io_uring.h>

#define ENTRIES 256
#define TIMEOUT_TAG 1u            /* user_data of a linked timeout's own completion */

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static int ring_fd;
static unsigned *sq_head, *sq_tail, *sq_mask, *sq_array, sq_entries;
static unsigned *cq_head, *cq_tail, *cq_mask;
static struct io_uring_sqe *sqes;
static struct io_uring_cqe *cqes;

/* what an operation needs to keep alive while the kernel has it */
struct extra {
    struct __kernel_timespec ts;
    struct sockaddr_in addr;
};

const char *slc_io_backend(void) { return "io_uring"; }

static int enter(unsigned submit, unsigned wait, unsigned flags) {
    return (int)syscall(__NR_io_uring_enter, ring_fd, submit, wait, flags, NULL, 0);
}

static void *poller(void *arg);

static void start(void) {
    struct io_uring_params p;
    size_t sq_size, cq_size;
    unsigned char *sq, *cq;
    pthread_t th;
    pthread_attr_t at;
    memset(&p, 0, sizeof p);
    ring_fd = (int)syscall(__NR_io_uring_setup, ENTRIES, &p);
    if (ring_fd < 0) slc_trap("io_uring_setup failed (link the poll backend instead)");
    sq_size = p.sq_off.array + p.sq_entries * sizeof(unsigned);
    cq_size = p.cq_off.cqes + p.cq_entries * sizeof(struct io_uring_cqe);
    if (p.features & IORING_FEAT_SINGLE_MMAP) {
        if (cq_size > sq_size) sq_size = cq_size;
        cq_size = sq_size;
    }
    sq = mmap(NULL, sq_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, ring_fd, IORING_OFF_SQ_RING);
    if (sq == MAP_FAILED) slc_trap("cannot map the io_uring submission ring");
    if (p.features & IORING_FEAT_SINGLE_MMAP) {
        cq = sq;
    } else {
        cq = mmap(NULL, cq_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, ring_fd, IORING_OFF_CQ_RING);
        if (cq == MAP_FAILED) slc_trap("cannot map the io_uring completion ring");
    }
    sqes = mmap(NULL, p.sq_entries * sizeof(struct io_uring_sqe), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
                ring_fd, IORING_OFF_SQES);
    if (sqes == MAP_FAILED) slc_trap("cannot map the io_uring entries");
    sq_head = (unsigned *)(sq + p.sq_off.head);
    sq_tail = (unsigned *)(sq + p.sq_off.tail);
    sq_mask = (unsigned *)(sq + p.sq_off.ring_mask);
    sq_array = (unsigned *)(sq + p.sq_off.array);
    sq_entries = p.sq_entries;
    cq_head = (unsigned *)(cq + p.cq_off.head);
    cq_tail = (unsigned *)(cq + p.cq_off.tail);
    cq_mask = (unsigned *)(cq + p.cq_off.ring_mask);
    cqes = (struct io_uring_cqe *)(cq + p.cq_off.cqes);
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&th, &at, poller, NULL) != 0) slc_trap("cannot start the io_uring poller");
    pthread_attr_destroy(&at);
}

/* a free submission entry (mu held); entries are submitted at once, so the
 * ring has room unless the kernel is still consuming */
static struct io_uring_sqe *next_sqe(void) {
    unsigned tail = *sq_tail, idx;
    while (tail - __atomic_load_n(sq_head, __ATOMIC_ACQUIRE) >= sq_entries) enter(0, 0, 0);
    idx = tail & *sq_mask;
    memset(&sqes[idx], 0, sizeof sqes[idx]);
    sq_array[idx] = idx;
    __atomic_store_n(sq_tail, tail + 1, __ATOMIC_RELEASE);
    return &sqes[idx];
}

void slc_backend_submit(slc_op *op) {
    struct io_uring_sqe *sqe;
    struct extra *x = NULL;
    unsigned n = 1;
    pthread_once(&once, start);
    if (op->deadline || op->kind == SLC_K_CONNECT) {
        x = calloc(1, sizeof *x);
        if (!x) slc_trap("out of memory for I/O");
    }
    op->backend = x;
    if (op->kind == SLC_K_CONNECT) {
        int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (fd < 0) { free(x); slc_io_complete(op, SLC_IO_FAILED, errno); return; }
        op->fd = fd;
        x->addr.sin_family = AF_INET;
        x->addr.sin_port = htons((uint16_t)op->len);
        x->addr.sin_addr.s_addr = htonl((uint32_t)op->offset);
    }
    pthread_mutex_lock(&mu);
    sqe = next_sqe();
    sqe->user_data = (uint64_t)(uintptr_t)op;
    switch (op->kind) {
    case SLC_K_READ:
    case SLC_K_WRITE:
        sqe->opcode = op->kind == SLC_K_READ ? IORING_OP_READ : IORING_OP_WRITE;
        sqe->fd = op->fd;
        sqe->addr = (uint64_t)(uintptr_t)op->buf;
        sqe->len = op->len;
        sqe->off = op->offset >= 0 ? (uint64_t)op->offset : (uint64_t)-1;
        break;
    case SLC_K_ACCEPT:
        sqe->opcode = IORING_OP_ACCEPT;
        sqe->fd = op->fd;
        sqe->accept_flags = SOCK_CLOEXEC;
        break;
    case SLC_K_CONNECT:
        sqe->opcode = IORING_OP_CONNECT;
        sqe->fd = op->fd;
        sqe->addr = (uint64_t)(uintptr_t)&x->addr;
        sqe->off = sizeof x->addr;
        break;
    case SLC_K_OPEN:
        sqe->opcode = IORING_OP_OPENAT;
        sqe->fd = AT_FDCWD;
        sqe->addr = (uint64_t)(uintptr_t)op->buf;
        sqe->len = op->len;
        sqe->open_flags = (uint32_t)op->fd | O_CLOEXEC;
        break;
    case SLC_K_CLOSE:
        sqe->opcode = IORING_OP_CLOSE;
        sqe->fd = op->fd;
        break;
    }
    if (op->deadline) {
        uint64_t now = slc_now_ns(), left = op->deadline > now ? op->deadline - now : 0;
        struct io_uring_sqe *t;
        sqe->flags |= IOSQE_IO_LINK;
        x->ts.tv_sec = (long long)(left / 1000000000ull);
        x->ts.tv_nsec = (long long)(left % 1000000000ull);
        t = next_sqe();
        t->opcode = IORING_OP_LINK_TIMEOUT;
        t->addr = (uint64_t)(uintptr_t)&x->ts;
        t->len = 1;
        t->user_data = TIMEOUT_TAG;
        n = 2;
    }
    if (enter(n, 0, 0) < 0) {
        pthread_mutex_unlock(&mu);
        slc_trap("io_uring_enter failed to submit");
    }
    pthread_mutex_unlock(&mu);
}

static void complete(slc_op *op, int res) {
    if (op->kind == SLC_K_CONNECT) {
        if (res < 0) {
            close(op->fd);
            res == -ECANCELED && op->deadline ? slc_io_complete(op, SLC_IO_TIMED_OUT, 0)
                                              : slc_io_complete(op, SLC_IO_FAILED, -res);
        } else {
            slc_io_nonblocking(op->fd);
            slc_io_complete(op, SLC_IO_DONE, op->fd);
        }
        return;
    }
    if (res >= 0) {
        if (op->kind == SLC_K_ACCEPT || op->kind == SLC_K_OPEN) slc_io_nonblocking(res);
        slc_io_complete(op, SLC_IO_DONE, op->kind == SLC_K_CLOSE ? 0 : res);
    } else if (res == -ECANCELED && op->deadline) {
        slc_io_complete(op, SLC_IO_TIMED_OUT, 0);
    } else {
        slc_io_complete(op, SLC_IO_FAILED, -res);
    }
}

static void *poller(void *arg) {
    (void)arg;
    for (;;) {
        unsigned head, tail;
        if (enter(0, 1, IORING_ENTER_GETEVENTS) < 0 && errno != EINTR && errno != EAGAIN && errno != EBUSY) {
            slc_trap("io_uring_enter failed to wait");
        }
        head = *cq_head;
        tail = __atomic_load_n(cq_tail, __ATOMIC_ACQUIRE);
        /* every completion up to `tail` was submitted, under mu, before it
         * appeared: taking mu now orders the submitters' writes to their records
         * before our reads (the kernel orders them too, invisibly to tools) */
        pthread_mutex_lock(&mu);
        pthread_mutex_unlock(&mu);
        while (head != tail) {
            struct io_uring_cqe *c = &cqes[head & *cq_mask];
            uint64_t ud = c->user_data;
            int res = c->res;
            head++;
            __atomic_store_n(cq_head, head, __ATOMIC_RELEASE);
            if (ud != TIMEOUT_TAG && ud != 0) {
                slc_op *op = (slc_op *)(uintptr_t)ud;
                void *x = op->backend;
                complete(op, res);
                free(x);
            }
        }
    }
    return NULL;
}
