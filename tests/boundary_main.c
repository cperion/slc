#include <assert.h>
#include <stdint.h>
uint32_t both(uint32_t a, uint32_t b);
uint32_t known(void);
uint32_t bump(uint32_t a, uint32_t b);
int main(void) {
    assert(both(2, 5) == 2 * 7 + 5 * 7 + 2 * 7);
    assert(known() == 7 * 7);
    assert(bump(3, 4) == 7);
    return 0;
}
