#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

extern uint32_t panel_extent(uint32_t);
extern uint32_t tally_odd(uint32_t);
extern uint32_t exit_change(uint32_t);
extern uint32_t nested_exit(uint32_t);
extern uint32_t nested_loops(uint32_t);
extern uint32_t continue_fields(uint32_t);
extern uint32_t swap_fields(uint32_t);
extern uint32_t snapshots(uint32_t);
extern uint32_t late_address(uint32_t);
extern uint32_t hidden_record(uint32_t);
extern uint32_t native_mutation(uint32_t);
extern uint32_t tail_fields(uint32_t);
extern uint32_t multiple_exits(uint32_t);
extern bool bool_exit(uint32_t);
extern float inline_early_return(uint32_t, float);
extern uint32_t inline_early_mutation(uint32_t);
extern uint32_t inline_return_join(bool);
extern uint32_t inline_return_join_reverse(bool);

int main(void) {
    for (uint32_t n = 0; n <= 32; ++n) {
        uint32_t total = 0, gap = 3;
        for (uint32_t i = 1; i <= n; ++i) {
            if (i == 1) continue;
            if (i == 2) gap = 5;
            if (i == 4) gap = 7;
            total += gap;
        }
        assert(panel_extent(n) == 48 + 12 * n);
        assert(tally_odd(n) == n / 2);
        assert(exit_change(n) == (n < 3 ? 12u : 55u));
        assert(nested_exit(n) == (n < 2 ? 7u : 12u));
        assert(nested_loops(n) == 6 * n + 4);
        assert(continue_fields(n) == total + 10);
        assert(swap_fields(n) == (n % 2 ? 219u : 129u));
        assert(snapshots(n) == 3 * n * (n ? n - 1 : 0) / 2 + 5 * n);
        assert(late_address(n) == 36 + n);
        assert(hidden_record(n) == (n ? 99u : 12u));
        assert(native_mutation(n) == (n ? 99u : 12u) + n);
        assert(tail_fields(n) == 3 * n + 3);
        assert(multiple_exits(n) == (n < 3 ? 39u : n % 2 ? 55u : 82u));
        assert(bool_exit(n) == (n >= 3));
        assert(inline_early_return(n, -1.0f) == 92.0f);
        assert(inline_early_return(n, 16.0f) == 92.0f);
        assert(inline_early_return(n, 64.0f) == 92.0f);
        assert(inline_early_mutation(n) == (n == 0 ? 36u : n == 1 ? 42u : 85u));
    }
    assert(inline_return_join(false) == 7);
    assert(inline_return_join(true) == 9);
    assert(inline_return_join_reverse(false) == 9);
    assert(inline_return_join_reverse(true) == 7);
    puts("loop fields: 598 checks passed");
    return 0;
}
