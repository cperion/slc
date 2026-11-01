#include <assert.h>
#include <stdint.h>
#include <stdio.h>

extern uint32_t return_logged(uint32_t);
extern uint32_t return_completed(uint32_t);
extern uint32_t return_configured(void);
extern uint32_t return_known_local(void);
extern uint32_t return_apply(uint32_t);
extern uint32_t return_recursive(uint32_t);

int main(void) {
    for (uint32_t n = 0; n < 100; ++n) {
        assert(return_logged(n) == n);
        assert(return_completed(n) == n + (n > 3 ? 10 : 12));
        assert(return_apply(n) == n + 3);
        assert(return_recursive(n) == n + 5);
    }
    assert(return_configured() == 7);
    assert(return_known_local() == 9);
    puts("activity returns: 402 checks passed");
    return 0;
}
