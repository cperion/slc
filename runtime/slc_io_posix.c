/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* slc runtime: POSIX pieces every I/O backend shares.
 *
 * Readiness backends (poll, kqueue) wait until a descriptor is ready, then
 * perform the operation here without blocking. So an operation that times out
 * has done nothing, which keeps `timed_out` exact. Descriptors the runtime
 * makes are non-blocking. */
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#include "slc_io_posix.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <arpa/inet.h>

int slc_io_nonblocking(int fd) {
    int fl = fcntl(fd, F_GETFL);
    if (fl < 0) return -1;
    if (fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0) return -1;
    return fcntl(fd, F_SETFD, FD_CLOEXEC);
}

static int again(int e) { return e == EAGAIN || e == EWOULDBLOCK || e == EINTR; }

/* open and close may block (a slow file system): a blocking thread does them */
static void open_close(void *arg) {
    slc_op *op = arg;
    if (op->kind == SLC_K_OPEN) {
        int fd = open((const char *)op->buf, op->fd | O_CLOEXEC, (mode_t)op->len);
        if (fd < 0) slc_io_complete(op, SLC_IO_FAILED, errno);
        else slc_io_complete(op, SLC_IO_DONE, fd);
    } else {
        if (close(op->fd) < 0) slc_io_complete(op, SLC_IO_FAILED, errno);
        else slc_io_complete(op, SLC_IO_DONE, 0);
    }
}

static void file_io(void *arg) {
    slc_op *op = arg;
    if (!slc_io_try(op)) slc_io_complete(op, SLC_IO_FAILED, EAGAIN);
}

int slc_io_offload_file(slc_op *op) {
    struct stat st;
    if (op->kind != SLC_K_READ && op->kind != SLC_K_WRITE) return 0;
    if (fstat(op->fd, &st) != 0 || !S_ISREG(st.st_mode)) return 0;
    slc_run_blocking(file_io, op);
    return 1;
}

int slc_io_prepare(slc_op *op) {
    if (op->kind == SLC_K_OPEN || op->kind == SLC_K_CLOSE) {
        slc_run_blocking(open_close, op);
        return 1;
    }
    if (op->kind == SLC_K_CONNECT) {
        struct sockaddr_in a;
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) { slc_io_complete(op, SLC_IO_FAILED, errno); return 1; }
        slc_io_nonblocking(fd);
        memset(&a, 0, sizeof a);
        a.sin_family = AF_INET;
        a.sin_port = htons((uint16_t)op->len);
        a.sin_addr.s_addr = htonl((uint32_t)op->offset);
        op->fd = fd;
        if (connect(fd, (struct sockaddr *)&a, sizeof a) == 0) {
            slc_io_complete(op, SLC_IO_DONE, fd);
            return 1;
        }
        if (errno != EINPROGRESS) {
            int e = errno;
            close(fd);
            slc_io_complete(op, SLC_IO_FAILED, e);
            return 1;
        }
        return 0;                       /* wait until writable */
    }
    return 0;
}

int slc_io_wants_write(const slc_op *op) { return op->kind == SLC_K_WRITE || op->kind == SLC_K_CONNECT; }

int slc_io_try(slc_op *op) {
    ssize_t n;
    switch (op->kind) {
    case SLC_K_READ:
        n = op->offset >= 0 ? pread(op->fd, op->buf, op->len, (off_t)op->offset) : read(op->fd, op->buf, op->len);
        break;
    case SLC_K_WRITE:
        n = op->offset >= 0 ? pwrite(op->fd, op->buf, op->len, (off_t)op->offset) : write(op->fd, op->buf, op->len);
        break;
    case SLC_K_ACCEPT: {
        int fd = accept(op->fd, NULL, NULL);
        if (fd < 0) {
            if (again(errno) || errno == ECONNABORTED) return 0;
            slc_io_complete(op, SLC_IO_FAILED, errno);
            return 1;
        }
        slc_io_nonblocking(fd);
        slc_io_complete(op, SLC_IO_DONE, fd);
        return 1;
    }
    case SLC_K_CONNECT: {
        int err = 0;
        socklen_t len = sizeof err;
        if (getsockopt(op->fd, SOL_SOCKET, SO_ERROR, &err, &len) < 0) err = errno;
        if (err == EINPROGRESS || err == EALREADY) return 0;
        if (!err) {
            /* SO_ERROR reads once (a kqueue may already have read it): confirm the peer,
             * and if there is none, a read says why */
            struct sockaddr_in peer;
            socklen_t plen = sizeof peer;
            if (getpeername(op->fd, (struct sockaddr *)&peer, &plen) < 0) {
                char c;
                if (read(op->fd, &c, 1) < 0) {
                    if (again(errno)) return 0;
                    err = errno;
                } else {
                    err = ENOTCONN;
                }
            }
        }
        if (err) {
            close(op->fd);
            slc_io_complete(op, SLC_IO_FAILED, err);
        } else {
            slc_io_complete(op, SLC_IO_DONE, op->fd);
        }
        return 1;
    }
    default:
        return 0;
    }
    if (n < 0) {
        if (again(errno)) return 0;
        slc_io_complete(op, SLC_IO_FAILED, errno);
        return 1;
    }
    slc_io_complete(op, SLC_IO_DONE, (int64_t)n);
    return 1;
}

/* a timed-out connect owns a socket nobody will see */
void slc_io_abandon(slc_op *op) {
    if (op->kind == SLC_K_CONNECT && op->fd >= 0) close(op->fd);
}

int32_t slc_io_pipe(int32_t *reader, int32_t *writer, int64_t *value) {
    int fds[2];
    if (pipe(fds) < 0) { *value = errno; return SLC_IO_FAILED; }
    slc_io_nonblocking(fds[0]);
    slc_io_nonblocking(fds[1]);
    *reader = fds[0];
    *writer = fds[1];
    *value = 0;
    return SLC_IO_DONE;
}

int32_t slc_io_listen(uint32_t host, uint32_t port, int64_t *value) {
    struct sockaddr_in a;
    int one = 1;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { *value = errno; return SLC_IO_FAILED; }
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    a.sin_addr.s_addr = htonl(host);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0 || listen(fd, 128) < 0) {
        int e = errno;
        close(fd);
        *value = e;
        return SLC_IO_FAILED;
    }
    slc_io_nonblocking(fd);
    *value = fd;
    return SLC_IO_DONE;
}

uint32_t slc_io_local_port(int32_t fd) {
    struct sockaddr_in a;
    socklen_t len = sizeof a;
    if (getsockname(fd, (struct sockaddr *)&a, &len) < 0) return 0;
    return ntohs(a.sin_port);
}
