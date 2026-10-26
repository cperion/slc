#include <stdio.h>
#include <stdint.h>
typedef struct U32x4 { uint32_t e[4]; } U32x4;
uint32_t fill(uint32_t n); uint32_t fixed(void); uint32_t pick(U32x4 a, uint32_t i);
int main(void) {
    U32x4 a = { { 5, 6, 7, 8 } };
    printf("%u %u %u\n", fill(5), fixed(), pick(a, 2));
    return !(fill(5) == 0+3+6+9+12 && fixed() == 40 + 30 + 4 && pick(a, 2) == 7);
}
