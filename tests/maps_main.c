#include "slc_rt.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
typedef struct Str { uint8_t *ptr; uint32_t len; } Str;
uint64_t map_tally(uint32_t n);
uint64_t edit_counts(uint32_t k);
uint32_t label_count(Str s);
uint64_t absent(uint32_t k);
uint64_t record_keys(uint32_t n);
uint32_t sum_keys(int64_t n);
uint32_t id_keys(uint32_t n);
uint64_t map_field(uint32_t n);
uint64_t checked_map_place(uint32_t k);
uint64_t map_each_sum(uint32_t n);
uint64_t map_each_nested(uint32_t n);
uint64_t map_each_mutation(uint32_t mode);
uint64_t map_task_each(uint32_t n);
static void mutate(void *mode) { (void)map_each_mutation(*(uint32_t *)mode); }
static void missing(void *unused) { (void)unused; (void)absent(123); }
int main(void) {
    uint32_t n;
    for (n = 0; n < 1000; n += 7) assert(map_tally(n) == n);
    for (n = 0; n < 10; n++) {
        assert(map_each_sum(n) == (uint64_t)n * (n + 1) / 2 + 1);
        assert(map_each_nested(n) == 29 * n + 1);
    }
    for (n = 0; n < 3; n++) {
        assert(slc_try(mutate, &n) == 1);
        assert(strstr(slc_trap_message(), "structural mutation") != NULL);
        assert(map_each_sum(10) == 56);
    }
    assert(map_task_each(0) == 1);
    assert(map_task_each(100) == 5051);
    assert(record_keys(15) == 56);
    assert(sum_keys(INT64_MIN) == 19 && sum_keys(INT64_MAX) == 19);
    assert(id_keys(42) == 42);
    assert(map_field(99) == 19);
    assert(checked_map_place(17) == 219);
    assert(edit_counts(0) == 20);
    assert(edit_counts(UINT32_MAX) == 20);
    Str cat = { (uint8_t *)"cat", 3 }, dog = { (uint8_t *)"dog", 3 }, empty = { NULL, 0 };
    assert(label_count(cat) == 3 && label_count(dog) == 4 && label_count(empty) == 0);
    assert(slc_try(missing, NULL) == 1);
    assert(strstr(slc_trap_message(), "map-key") != NULL);
    assert(map_tally(2000) == 2000);
    slc_stacks_free(&slc_own_stacks);
    puts("maps: fixed-key operations, snapshots, Chars keys and missing-key trap passed");
    return 0;
}
