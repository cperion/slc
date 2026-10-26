#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
uint32_t inferred_branch(bool flag, uint32_t x);
uint32_t inferred_loops(uint32_t n);
uint32_t inferred_snapshot(uint32_t x);
uint32_t inferred_storage(uint32_t n);
uint32_t inferred_mixed(uint32_t x);
int main(void) {
    assert(inferred_branch(true, 10) == 29);
    assert(inferred_branch(false, 10) == 27);
    assert(inferred_loops(0) == 3);
    assert(inferred_loops(10) == 103);
    assert(inferred_snapshot(7) == 25);
    assert(inferred_storage(8) == 14);
    assert(inferred_mixed(7) == 17);
    return 0;
}
