#include <assert.h>
#include <stdint.h>
uint32_t ring_sum(uint32_t n);
uint32_t ring_bytes(uint8_t a, uint8_t b, uint8_t c);
int main(void) {
    assert(ring_sum(2) == 5 * 10000 + 1001);
    assert(ring_sum(4) == 30 * 10000 + 1001);
    assert(ring_sum(6) == 86 * 10000 + 1009);
    assert(ring_sum(9) == 230 * 10000 + 1036);
    assert(ring_bytes(1, 2, 3) == 2 * 256 + 3);
    return 0;
}
