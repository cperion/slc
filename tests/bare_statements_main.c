#include <assert.h>
#include <stdint.h>
#include <stdio.h>
extern uint32_t bare_opened(uint32_t);
extern uint32_t bare_method(uint32_t);
extern uint32_t bare_qualified(uint32_t);
extern uint32_t bare_shadow(void);
extern uint32_t value_contexts(void);
int main(void) {
    for (uint32_t n = 0; n < 100; ++n) {
        assert(bare_opened(n) == n + 2);
        assert(bare_method(n) == n + 2);
        assert(bare_qualified(n) == n + 1);
    }
    assert(bare_shadow() == 10);
    assert(value_contexts() == 42);
    puts("bare statements: 302 checks passed");
    return 0;
}
