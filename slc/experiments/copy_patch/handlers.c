/* Experiment only: x86-64 SysV, Clang musttail, two symbolic U64 registers. */
#include <stdint.h>
extern uint64_t NEXT(uint64_t, uint64_t);
extern uint64_t ZERO(uint64_t, uint64_t);
extern unsigned char IMM;
#define TAIL(f, x, a) __attribute__((musttail)) return f(x, a)

uint64_t mul(uint64_t x, uint64_t a) {
    TAIL(NEXT, x * (uintptr_t)&IMM, a);
}
uint64_t add(uint64_t x, uint64_t a) {
    TAIL(NEXT, x + (uintptr_t)&IMM, a);
}
uint64_t init(uint64_t x, uint64_t a) {
    (void)a;
    TAIL(NEXT, x, 0);
}
uint64_t test(uint64_t x, uint64_t a) {
    if (x == 0) { TAIL(ZERO, x, a); }
    TAIL(NEXT, x, a);
}
uint64_t step(uint64_t x, uint64_t a) {
    TAIL(NEXT, x - 1, a + x);
}
uint64_t result_x(uint64_t x, uint64_t a) { (void)a; return x; }
uint64_t result_a(uint64_t x, uint64_t a) { (void)x; return a; }
