#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct Counter { uint32_t value; } Counter;
uint32_t double_(uint32_t), triple(uint32_t), transform(uint32_t), use(uint32_t), times8(uint32_t);
uint32_t choose_use(bool, uint32_t), f(bool, uint32_t), unannotated(uint32_t), typed_local(uint32_t);
uint32_t add6(uint32_t), runtime_sum(uint32_t), count3(uint32_t, uint32_t, uint32_t);
void print_twice(uint32_t);
void counter_add(Counter *, uint32_t);
uint32_t branch_bump(bool, uint32_t);

static uint32_t printed;
void foreign_print(uint32_t x) { printed = x; }

int main(void) {
    assert(double_(21) == 42 && triple(5) == 15);
    assert(transform(10) == 43 && use(10) == 43);
    assert(times8(7) == 56);
    assert(choose_use(true, 7) == 56 && choose_use(false, 7) == 15);
    assert(f(true, 5) == 10 && f(false, 5) == 6);
    assert(unannotated(5) == 21 && typed_local(5) == 6 && add6(10) == 16);
    assert(runtime_sum(5) == 15 && runtime_sum(0) == 0);
    /* the loop must stop at the limit even when the limit is the type's maximum */
    assert(runtime_sum(UINT32_MAX) == (uint32_t)((uint64_t)UINT32_MAX * ((uint64_t)UINT32_MAX + 1) / 2));
    print_twice(21); assert(printed == 42);
    assert(count3(1, 2, 3) == 6);
    Counter c = { 5 }; counter_add(&c, 3); assert(c.value == 8);
    /* a call in one arm escapes the local for every path: both arms must see 0 */
    assert(branch_bump(true, 3) == 3 && branch_bump(false, 3) == 6);
    puts("spec_core: ok");
    return 0;
}
