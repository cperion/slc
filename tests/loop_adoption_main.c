#include <assert.h>
#include <stdint.h>
#include <stdio.h>
extern uint32_t evens(uint32_t);
extern uint32_t mixed_aliases(uint32_t);
extern uint32_t nested_aliases(uint32_t);
extern uint32_t widening(uint32_t);
extern uint32_t escape_inside(uint32_t);
extern uint32_t escape_between(uint32_t);
extern uint32_t exits(uint32_t);
extern uint32_t spin(uint32_t, uint32_t);
extern uint32_t early_return(uint32_t);
extern uint32_t sum_field(uint32_t);
extern uint32_t sum_state(uint32_t);
int main(void) {
    for (uint32_t n = 0; n < 100; ++n) {
        uint32_t small = n < 3 ? n : 3;
        uint32_t capped = n < 10 ? n : 10;
        assert(sum_field(n) == (n ? 3 * n : 100));
        assert(sum_state(n) == (n ? n : 100));
        assert(evens(n) == 3 * ((n + 1) / 2));
        assert(early_return(n) == 3 * small);
        assert(mixed_aliases(n) == 4 * n);
        assert(nested_aliases(n) == 3 * n * (n + 1) / 2);
        assert(widening(n) == 3 * small + 5 * (n - small));
        assert(escape_inside(n) == 3 * n + n * (n ? n - 1 : 0) / 2);
        assert(escape_between(n) == 7 * n);
        assert(exits(n) == 3 * ((capped + 1) / 2));
        uint32_t value = n + 1234567u;
        for (uint32_t i = 0; i < n; ++i) value = ((value << 3) | (value >> 29)) + 3u;
        assert(spin(n, n + 1234567u) == value);
    }
    puts("loop adoption: 1100 checks passed");
    return 0;
}
