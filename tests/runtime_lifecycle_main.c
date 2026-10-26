/* Record lifecycle models for the SLC runtime, independent of scheduling. */
#include "slc_scheduler.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>

static void registry_growth(void) {
    struct chan_rec *channels[4096] = {0};
    struct pool_rec *pools[4096] = {0};
    slc_pool_meta *metas[4096] = {0};
    uint32_t ch_count = 0, p_count = 0, ch_head = SLC_NONE, p_head = SLC_NONE;
    for (int32_t i = 0; i < 260; ++i) {
        assert(slc_channel_acquire(channels, &ch_head, &ch_count) == i);
        assert(slc_pool_acquire(pools, metas, &p_head, &p_count, 1, 8) == i);
        assert(pools[i / 256][i % 256].m == &metas[i / 256][i % 256]);
    }
    assert(ch_count == 260 && p_count == 260);
    slc_channel_recycle_record(&channels[0][3], &ch_head, 3);
    assert(slc_channel_acquire(channels, &ch_head, &ch_count) == 3 && ch_count == 260);
    pools[0][7].cap_slots = 3; pools[0][7].cap_bytes = 24;
    slc_pool_recycle_record(&pools[0][7], &p_head, 7);
    assert(slc_pool_acquire(pools, metas, &p_head, &p_count, 2, 8) == 7 && p_count == 260);
    ch_count = p_count = 4096 * 256;
    assert(slc_channel_acquire(channels, &ch_head, &ch_count) == -1);
    assert(slc_pool_acquire(pools, metas, &p_head, &p_count, 1, 8) == -1);
    for (unsigned page = 0; page < 2; ++page) {
        for (unsigned i = 0; i < 256; ++i) {
            assert(pthread_mutex_trylock(&channels[page][i].mu) == 0);
            assert(pthread_mutex_unlock(&channels[page][i].mu) == 0);
            assert(pthread_mutex_destroy(&channels[page][i].mu) == 0);
            assert(pthread_mutex_trylock(&pools[page][i].mu) == 0);
            assert(pthread_mutex_unlock(&pools[page][i].mu) == 0);
            assert(pthread_mutex_destroy(&pools[page][i].mu) == 0);
        }
        free(channels[page]); free(pools[page]); free(metas[page]);
    }
}
int main(void) {
    registry_growth();
    slc_task task = {0};
    slc_scope *outer = slc_scope_allocate(&task);
    slc_scope *inner = slc_scope_allocate(&task);
    assert(outer && inner && inner->parent == outer && task.cur_scope == inner);
    assert(slc_scope_inside(&task, inner) && slc_scope_inside(&task, outer));
    assert(!slc_scope_inside(&task, NULL));
    uint32_t *items = NULL;
    uint64_t count = 0, cap = 0;
    for (uint32_t i = 0; i < 100; ++i) assert(slc_scope_record(&items, &count, &cap, 4, i));
    assert(count == 100 && cap == 128);
    for (uint32_t i = 0; i < 100; ++i) assert(items[i] == i);
    free(items);

    struct chan_rec channels[256] = {0};
    struct chan_rec *chunks[] = {channels};
    uint32_t head = SLC_NONE;
    slc_channel_recycle_record(&channels[7], &head, 7);
    slc_channel_recycle_record(&channels[3], &head, 3);
    assert(slc_channel_reuse(chunks, &head) == 3);
    assert(slc_channel_reuse(chunks, &head) == 7);
    assert(slc_channel_reuse(chunks, &head) == SLC_NONE);
    struct chan_rec *ch = &channels[3];
    assert(slc_channel_initialize(ch, 4, 5));
    assert(ch->live && ch->gen == 1 && ch->buf && ch->cap == 5 && !ch->closed);
    slc_task reader = {0}, sender = {0};
    slc_op recv = {0}, send = {0}; recv.task = &reader; send.task = &sender;
    slc_wait_enqueue(&ch->recvq, &recv); slc_wait_enqueue(&ch->sendq, &send);
    slc_op *list = slc_channel_retire(ch);
    assert(list == &send && list->next == &recv && !recv.next);
    assert(!ch->live && !ch->buf && ch->gen == 2 && !ch->sendq.head && !ch->recvq.head);
    assert(reader.claimed && sender.claimed);
    ch->gen = UINT32_MAX;
    assert(!slc_channel_retire(ch) && ch->gen == 1);
    assert(slc_channel_initialize(ch, 4, 0) && !ch->buf);
    slc_channel_retire(ch);

    struct pool_rec pools[256] = {0};
    struct pool_rec *pchunks[] = {pools};
    slc_pool_meta meta = {0};
    struct pool_rec *p = &pools[8]; p->m = &meta;
    assert(slc_pool_initialize(p, outer, 8, 7));
    assert(p->live && p->scope == outer && meta.gen == 1 && meta.n == 7);
    unsigned char *data = meta.data;
    slc_slot_meta *slots = meta.slots;
    for (unsigned i = 0; i < 7; ++i) {
        assert(slots[i].gen == 1 && slots[i].owner == 0);
        assert(slots[i].next_free == (i == 6 ? SLC_NONE : i + 1));
    }
    meta.data[0] = 42; slots[0].gen = 99;
    assert(!slc_pool_retire(p));
    assert(!p->live && !p->scope && meta.gen == 2 && meta.data == data && meta.slots == slots);
    head = SLC_NONE;
    slc_pool_recycle_record(p, &head, 8);
    pools[2].cap_slots = 1; pools[2].cap_bytes = 1;
    slc_pool_recycle_record(&pools[2], &head, 2);
    assert(slc_pool_reuse(pchunks, &head, 6, 8) == 8 && head == 2);
    assert(pools[2].next_free == SLC_NONE);
    assert(slc_pool_reuse(pchunks, &head, 2, 8) == SLC_NONE && head == 2);
    assert(slc_pool_initialize(p, inner, 8, 6));
    assert(meta.data == data && meta.slots == slots && meta.data[0] == 0 && slots[0].gen == 99);
    meta.gen = UINT32_MAX;
    assert(!slc_pool_retire(p) && meta.gen == 1);
    free(meta.data); free(meta.slots);
    free(inner); free(outer);
    puts("lifecycle: scope ancestry, vectors, reuse selection, initialization and retirement passed");
    return 0;
}
