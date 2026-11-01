#include <stdint.h>
#include <assert.h>
#include <stdio.h>

typedef struct { uint32_t config, count; } PublicCounter;
typedef struct { uint32_t prefix; PublicCounter counter; uint32_t suffix; } PublicEnvelope;
extern uint32_t compact_count(uint32_t);
extern uint32_t compact_nested(uint32_t);
extern uint32_t shared_constant(uint32_t);
extern uint32_t shared_write(uint32_t);
extern void public_increment(PublicEnvelope *);

int main(void) {
    for (uint32_t n = 0; n < 100; ++n) {
        assert(compact_count(n) == 7 + 3 * n);
        assert(compact_nested(n) == 11 + 5 * n);
        assert(shared_constant(n) == 9 + n);
        assert(shared_write(n) == 9 + 2 * n);
    }
    PublicEnvelope e = { 101, { 202, 303 }, 404 };
    public_increment(&e);
    assert(e.prefix == 101 && e.counter.config == 202);
    assert(e.counter.count == 304 && e.suffix == 404);
    puts("storage layout: 402 checks passed");
    return 0;
}
