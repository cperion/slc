#include <assert.h>
#include <stdint.h>
typedef struct Point { uint32_t x; uint32_t y; } Point;
Point make(uint32_t x, uint32_t y);
Point shifted(uint32_t x);
uint32_t fixed_sum(uint32_t z);
int main(void) {
    Point p = make(7, 9);
    assert(p.x == 7 && p.y == 9);
    Point q = shifted(10);
    assert(q.x == 10 && q.y == 11);
    assert(fixed_sum(5) == 3 + 4 + 5 * 2);
    return 0;
}
