/* Harness for examples/channels.slc: real threads, real channels. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#include <time.h>
#include "slc_rt.h"

uint64_t sum_squares(uint32_t n);
uint64_t total_steps4(uint32_t n);
uint64_t merged(uint32_t n);
bool poll_empty(void);
uint64_t ask(uint32_t n);
int64_t tally(uint32_t adds, uint32_t subs);
bool gives_up(void);
uint32_t late_reply(void);
uint64_t nested(uint32_t groups, uint32_t per);
uint32_t grow_in_task(uint32_t n);
uint64_t pooled(uint32_t count);
uint32_t parallel_sleeps(uint32_t n);
uint32_t take_or_time(void);
typedef struct Holder { slc_chan ch; } Holder;
void use_after_scope(Holder *h);
void forgotten(void);

static int failures;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static const char *self_path;

/* run this program again with `what` (a fresh process: fork alone would copy a
 * scheduler lock some worker may hold); it must abort, saying `want` */
static int child_aborts(const char *what, const char *want) {
    int pipefd[2], status = 0;
    char buf[1024] = { 0 };
    size_t got = 0;
    ssize_t n;
    pid_t pid;
    fflush(stdout);
    if (pipe(pipefd) != 0) return 0;
    pid = fork();
    if (pid == 0) {
        dup2(pipefd[1], 2);
        execl(self_path, self_path, what, (char *)NULL);
        _exit(127);
    }
    close(pipefd[1]);
    while (got < sizeof buf - 1 && (n = read(pipefd[0], buf + got, sizeof buf - 1 - got)) > 0) got += (size_t)n;
    close(pipefd[0]);
    waitpid(pid, &status, 0);
    return WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT && strstr(buf, want) != NULL;
}

static uint32_t steps(uint64_t x) {
    uint32_t s = 0;
    while (x != 1) { x = (x & 1) ? 3 * x + 1 : x >> 1; s++; }
    return s;
}

int main(int argc, char **argv) {
    uint64_t want = 0, i;
    self_path = argv[0];
    if (argc > 1) {
        if (strcmp(argv[1], "stale") == 0) { Holder h; use_after_scope(&h); }
        if (strcmp(argv[1], "forgotten") == 0) forgotten();
        if (strcmp(argv[1], "not_owner") == 0 || strcmp(argv[1], "used_after_send") == 0
            || strcmp(argv[1], "outside_scope") == 0) {
            /* the runtime's own checks, below what the compiler lets through */
            slc_task *me = slc_self(), other;
            slc_op ops[1];
            slc_slot s;
            slc_scope *sc = slc_scope_new(me);
            slc_pool p = slc_pool_new(sc, 16, 2);
            memset(&other, 0, sizeof other);
            other.id = 999999;
            if (strcmp(argv[1], "outside_scope") == 0) slc_take(&other, ops, p, &s, "take");
            if (slc_take(me, ops, p, &s, "take") == SLC_PENDING) slc_block(me);
            if (strcmp(argv[1], "not_owner") == 0) slc_slot_at(&other, s);
            slc_slot_at(me, s);
            slc_slot_give(me, s);
            slc_slot_at(me, s);
        }
        return 0;
    }
    for (i = 0; i < 20000; i++) want += i * i;
    CHECK(sum_squares(20000) == want);
    CHECK(sum_squares(0) == 0);

    want = 0;
    for (i = 1; i <= 3000; i++) want += steps(i);
    CHECK(total_steps4(3000) == want);

    /* select over an unbuffered and a buffered channel */
    want = 0;
    for (i = 0; i < 5000; i++) want += i + (1000000 + i);
    CHECK(merged(5000) == want);
    CHECK(merged(0) == 0);

    CHECK(poll_empty());

    /* channels of channels: request, reply */
    CHECK(ask(1000) == 10ull * 1000 * 1001 / 2);

    /* sums as messages */
    CHECK(tally(100, 40) == (int64_t)(100 * 101 / 2) - (int64_t)(40 * 41 / 2));

    /* run the scopes again and again: channel records are recycled */
    for (i = 0; i < 200; i++) CHECK(merged(50) == 50 * 49 / 2 + 50 * 1000000ull + 50 * 49 / 2);

    /* timers */
    CHECK(gives_up());
    CHECK(late_reply() == 42);

    /* scopes nested in tasks; a task's own data stacks */
    {
        uint64_t g, k, w = 0;
        for (g = 0; g < 6; g++) for (k = 0; k < 5; k++) w += g * 1000 + k;
        CHECK(nested(6, 5) == w);
    }
    CHECK(grow_in_task(1000) == 1000u * 1001u / 2u);

    /* pools */
    {
        uint64_t k, j, w = 0;
        for (k = 0; k < 5000; k++) for (j = 0; j < k % 64; j++) w += (k + j) & 255;
        CHECK(pooled(5000) == w);
    }
    CHECK(take_or_time() == 111);

    /* blocking blocks leave the workers: eight 50 ms sleeps overlap */
    {
        struct timespec a, b;
        double ms;
        clock_gettime(CLOCK_MONOTONIC, &a);
        CHECK(parallel_sleeps(8) == 8 * 50);
        clock_gettime(CLOCK_MONOTONIC, &b);
        ms = (double)(b.tv_sec - a.tv_sec) * 1e3 + (double)(b.tv_nsec - a.tv_nsec) / 1e6;
        CHECK(ms < 300.0);
    }

    /* run-time checks, each in a child process */
    CHECK(child_aborts("stale", "channel used after its tasks scope ended"));
    CHECK(child_aborts("forgotten", "deadlock: every task is waiting"));
    CHECK(child_aborts("forgotten", "channels.slc:"));
    CHECK(child_aborts("not_owner", "a slot used by a task that does not own it"));
    CHECK(child_aborts("used_after_send", "a slot used after it was sent"));
    CHECK(child_aborts("outside_scope", "a pool used outside its tasks scope"));

    if (failures == 0) printf("channels: all checks passed\n");
    return failures != 0;
}
