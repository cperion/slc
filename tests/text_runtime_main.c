/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Text append must accept unrelated sources and survive same-stack relocation. */
#include "text_reference.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

static void expect(const slc_grow *g, const char *text) {
    assert(g->len == strlen(text));
    assert(memcmp(slc_gs(g->stack)->data + g->base, text, g->len) == 0);
}

int main(void) {
    slc_stackset stacks = { 0 };
    slc_stacks_use(&stacks);
    slc_grow text = slc_grow_new(0);
    slc_grow_write_bytes(&text, NULL, 0);
    assert(text.len == 0);
    assert(slc_gs(0)->data == NULL);
    /* Integer/Bool formatting now lives in SLC (formatting_main.c tests it).
     * The remaining float helper still supplies an unrelated stack buffer. */
    slc_grow_write_bytes(&text, (const uint8_t *)"unit = ", 7);
    slc_grow_write_f64(&text, 1.5);
    expect(&text, "unit = 1.5");
    slc_grow_clear(&text);
    uint8_t stack_bytes[] = { 's', 't', 'a', 'c', 'k' };
    uint8_t *heap_bytes = malloc(4);
    assert(heap_bytes);
    memcpy(heap_bytes, "heap", 4);
    slc_grow_write_bytes(&text, stack_bytes, sizeof stack_bytes);
    slc_grow_write_bytes(&text, heap_bytes, 4);
    expect(&text, "stackheap");
    free(heap_bytes);

    /* A nonzero base catches offsets accidentally measured from the Text rather
     * than from the entire stack. The append must exceed the current capacity. */
    slc_gs_push(1, 32);
    memset(slc_gs(1)->data, 0xa5, 32);
    slc_grow alias = slc_grow_new(1);
    assert(alias.base == 32);
    uint8_t seed[257];
    for (size_t i = 0; i < sizeof seed; ++i) seed[i] = (uint8_t)(i * 17u);
    slc_grow_write_bytes(&alias, seed, sizeof seed);
    size_t before_cap = slc_gs(1)->cap;
    uintptr_t before_address = (uintptr_t)slc_gs(1)->data;
    uint32_t appended = (uint32_t)sizeof seed - 7;
    assert(slc_gs(1)->top + appended > before_cap);
    slc_grow_write_bytes(&alias, slc_gs(1)->data + alias.base + 7, appended);
    assert(slc_gs(1)->cap > before_cap);
    assert(alias.len == sizeof seed + appended);
    assert(memcmp(slc_gs(1)->data + alias.base, seed, sizeof seed) == 0);
    assert(memcmp(slc_gs(1)->data + alias.base + sizeof seed, seed + 7, appended) == 0);
    for (size_t i = 0; i < 32; ++i) assert(slc_gs(1)->data[i] == 0xa5);
    printf("Text runtime: ok (capacity %zu -> %zu, relocated=%s)\n", before_cap,
        slc_gs(1)->cap, before_address != (uintptr_t)slc_gs(1)->data ? "yes" : "no");
    slc_stacks_use(NULL);
    slc_stacks_free(&stacks);
    return 0;
}
