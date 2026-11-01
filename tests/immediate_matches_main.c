#include <assert.h>
#include <stdint.h>
#include <stdio.h>
extern uint32_t native_match(uint32_t);
extern uint32_t callback_match(uint32_t);
extern uint32_t state_join(uint32_t);
extern uint32_t constant_payload(uint32_t);
extern uint32_t mixed_unknown(uint32_t);
extern uint32_t boundary_match(uint32_t);
extern uint32_t recursive_match(uint32_t);
extern uint32_t required_table(uint32_t);
extern uint32_t side_effects(uint32_t);
extern uint32_t record_payload(uint32_t);
int main(void) {
    for (uint32_t n = 0; n < 100; ++n) {
        uint32_t value = n == 0 ? 10 : n == 1 ? 20 : n == 2 ? 32 : 0;
        uint32_t matched = n < 3 ? value + 1 : 99;
        assert(native_match(n) == matched);
        assert(boundary_match(n) == matched);
        assert(callback_match(n) == (n == 1 ? 122u : n == 2 ? 134u : 7u));
        assert(state_join(n) == (n % 2 == 0 ? 11022u : 21043u));
        assert(constant_payload(n) == 101);
        assert(mixed_unknown(n) == (n == 0 ? 1007u : (n < 3 ? value : 90u) + 900u));
        assert(recursive_match(n) == 2 * (n + 1));
        assert(required_table(n) == n + 9);
        assert(side_effects(n) == (n % 2 == 0 ? 110111u + n : 220220u));
        assert(record_payload(n) == (n % 2 == 0 ? 3u : 7u));
    }
    puts("immediate matches: 1000 checks passed");
    return 0;
}
