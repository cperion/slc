#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
typedef struct Fixed { int32_t raw; } Fixed;
Fixed scale(Fixed x, Fixed y);
bool below(Fixed x, Fixed y);
int32_t to_raw(Fixed x);
uint32_t window_sum(uint32_t a, uint32_t b);
int main(void) {
    Fixed two = { 2 * 65536 }, half = { 65536 / 2 };
    assert(to_raw(scale(two, half)) == 3 * 65536 + 65536 / 2);
    assert(below(half, two) && !below(two, half) && !below(two, two));
    assert(window_sum(1, 2) == 11);
    assert(window_sum(0, 5) == 16);
    return 0;
}
