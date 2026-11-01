#include <assert.h>
#include <stdint.h>
#include <stdio.h>
extern uint32_t opened_lexical(uint32_t);
extern uint32_t opened_home(uint32_t);
extern uint32_t opened_member(uint32_t);
extern uint32_t opened_local(uint32_t);
extern uint32_t opened_vocabulary(uint32_t);
int main(void) {
    for (uint32_t n = 0; n < 100; ++n) {
        assert(opened_lexical(n) == 1 + 2 * n);
        assert(opened_home(n) == 1 + n);
        assert(opened_member(n) == 1 + 4 * n);
        assert(opened_local(n) == 7 * n);
        assert(opened_vocabulary(n) == n + 10);
    }
    puts("opened boundaries: 500 checks passed");
    return 0;
}
