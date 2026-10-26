/* Independent state-model checks for the SLC scheduler policy. */
#include "slc_scheduler.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t reference_random(uint64_t *s) {
    *s ^= *s << 13; *s ^= *s >> 7; *s ^= *s << 17; return *s;
}
static void check_heap(slc_timer_heap *h, slc_op *ops, unsigned n) {
    unsigned live = 0;
    for (unsigned i = 0; i < n; ++i) {
        if (!ops[i].queued) continue;
        ++live;
        assert((uint64_t)ops[i].queued <= h->len);
        assert(h->data[ops[i].queued - 1] == &ops[i]);
    }
    assert(live == h->len);
    for (uint64_t i = 0; i < h->len; ++i) {
        assert(h->data[i]->queued == (int32_t)i + 1);
        if (i) assert(h->data[(i - 1) / 2]->deadline <= h->data[i]->deadline);
    }
}
int main(void) {
    uint64_t a = 88172645463325252ull, b = a;
    for (unsigned i = 0; i < 10000; ++i) assert(slc_sched_random(&a) == reference_random(&b));
    a = 0; assert(slc_sched_random(&a) == 0);
    slc_run_queue q = {0};
    slc_task tasks[128] = {{0}};
    slc_task *model[128];
    unsigned n = 0;
    assert(!slc_sched_pop(&q, 0));
    for (unsigned round = 0; round < 20; ++round) {
        for (unsigned i = 0; i < 128; ++i) {
            slc_sched_push(&q, &tasks[i]); model[n++] = &tasks[i];
            assert(q.len == n && q.tail == &tasks[i]);
        }
        while (n) {
            unsigned k = (unsigned)(reference_random(&b) % n);
            slc_task *t = slc_sched_pop(&q, k);
            assert(t == model[k] && !t->next);
            memmove(model + k, model + k + 1, (--n - k) * sizeof *model);
            assert(q.len == n);
            assert(q.head == (n ? model[0] : NULL));
            assert(q.tail == (n ? model[n - 1] : NULL));
            slc_task *p = q.head;
            for (unsigned j = 0; j < n; ++j) { assert(p == model[j]); p = p->next; }
            assert(!p);
        }
    }
    a = 19; b = a;
    assert(!slc_sched_next(&q, &a, true) && a == b);
    for (unsigned mode = 0; mode < 2; ++mode) {
        n = 128;
        for (unsigned i = 0; i < n; ++i) {
            slc_sched_push(&q, &tasks[i]); model[i] = &tasks[i];
        }
        while (n) {
            unsigned k = mode ? (unsigned)(reference_random(&b) % n) : 0;
            assert(slc_sched_next(&q, &a, mode != 0) == model[k]);
            assert(a == b);
            memmove(model + k, model + k + 1, (--n - k) * sizeof *model);
        }
    }
    slc_timer_heap h = {0};
    slc_op ops[257] = {{0}};
    for (unsigned step = 0; step < 12000; ++step) {
        unsigned i = (unsigned)(reference_random(&b) % 257);
        if (ops[i].queued) {
            slc_timer_remove(&h, &ops[i]);
            slc_timer_remove(&h, &ops[i]); /* cancellation is idempotent */
        } else {
            ops[i].deadline = reference_random(&b) % 41; /* deliberate ties */
            bool first = slc_timer_add(&h, &ops[i]);
            assert(first == (h.data[0] == &ops[i]));
        }
        check_heap(&h, ops, 257);
    }
    uint64_t last = 0;
    while (h.len) {
        slc_op *op = h.data[0];
        assert(op->deadline >= last); last = op->deadline;
        slc_timer_remove(&h, op);
        check_heap(&h, ops, 257);
    }
    assert(h.cap >= 128);
    free(h.data);
    puts("scheduler policy: random sequence, queue model, heap growth/removal/ties passed");
    return 0;
}
