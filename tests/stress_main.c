#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

uint32_t snapshot(uint32_t), isqrt_plus(uint32_t), parity(uint32_t), mixed_loop(uint32_t);
uint8_t mix8(uint8_t, uint8_t);
int16_t neg16(int16_t);
uint64_t big(uint64_t);
float f32(float);
int32_t walk_vec(int32_t, int32_t, uint32_t), vsum(int32_t), clamp_sum(int32_t, int32_t);
bool logic(bool, uint32_t);
int64_t poly(int64_t);
uint32_t bits_if(bool, uint32_t), walk(uint32_t), bumped(uint32_t);
void bump_ref(uint32_t *, uint32_t);
uint32_t gcd(uint32_t, uint32_t), swapper(uint32_t, uint32_t, uint32_t), walk_auto(uint32_t), cube(uint32_t);
uint32_t first_multiple(uint32_t, uint32_t), sum_until(uint32_t), hidden(uint32_t), fib_pair(uint32_t);
static uint32_t r_gcd(uint32_t a, uint32_t b) { while (b) { uint32_t t = a % b; a = b; b = t; } return a; }
static uint32_t r_first(uint32_t m, uint32_t limit) { for (uint32_t i = 1; i <= limit; i++) { if (i % 2 == 0) continue; if (i % m == 0) return i; } return 0; }
static uint32_t r_sum_until(uint32_t x) { uint32_t t = 0; for (uint32_t i = 1; i <= x; i++) if (i != 3) t += i; return t; }

/* references written directly in C */
static uint32_t r_snapshot(uint32_t x) { uint32_t y = x * 3; if (x > 10) y += 1; uint32_t a = y; y *= 2; return a + y; }
static uint32_t r_isqrt_plus(uint32_t t) { for (uint32_t i = 0; i < 1000; i++) if (i * i >= t) return i + 1; return 1001; }
static int32_t r_walk_vec(int32_t a, int32_t b, uint32_t n) { while (n--) { int32_t x = b, y = a - 1; a = x; b = y; } return a + b; }
static uint32_t r_mixed(uint32_t x) { uint32_t acc = 1; for (uint32_t i = 1; i <= 4; i++) acc = i == 3 ? acc + x : acc * 2; return acc; }
static int32_t r_clamp(int32_t x, int32_t lo, int32_t hi) { return x < lo ? lo : x > hi ? hi : x; }
static uint32_t r_bits(uint32_t x) { uint32_t n = 0; while (x) { n += x & 1; x >>= 1; } return n; }

int main(void) {
    for (uint32_t x = 0; x < 50; x++) assert(snapshot(x) == r_snapshot(x));
    for (uint32_t t = 0; t < 2000; t += 7) assert(isqrt_plus(t) == r_isqrt_plus(t));
    assert(isqrt_plus(1000000000u) == 1001);
    for (uint32_t n = 0; n < 40; n++) assert(parity(n) == (n & 1));
    for (unsigned a = 0; a < 256; a += 5)
        for (unsigned b = 0; b < 256; b += 7)
            assert(mix8((uint8_t)a, (uint8_t)b) == (uint8_t)(a * b + a - b));
    assert(neg16(-32768) == -32768 && neg16(5) == -5);
    assert(big(1) == 6364136223846793005ull + 1442695040888963407ull);
    assert(big(3) == 3ull * 6364136223846793005ull + 1442695040888963407ull);
    assert(f32(1.0f) == 1.0f / 3.0f + 0.1f);
    for (int32_t a = -3; a < 3; a++)
        for (uint32_t n = 0; n < 6; n++) assert(walk_vec(a, 7, n) == r_walk_vec(a, 7, n));
    for (uint32_t x = 0; x < 20; x++) assert(mixed_loop(x) == r_mixed(x));
    for (uint32_t x = 0; x < 10; x++) {
        assert(logic(true, x) == true);
        assert(logic(false, x) == (x > 5));
    }
    assert(vsum(40) == 42);
    for (int32_t a = -20; a < 20; a += 3)
        for (int32_t b = -9; b < 9; b += 2)
            assert(clamp_sum(a, b) == r_clamp(a, 0, 10) + r_clamp(b, -5, 5));
    for (int64_t x = -5; x < 6; x++) assert(poly(x) == ((3 * x + 0) * x - 2) * x + 7);
    for (uint32_t x = 0; x < 300; x += 11) {
        assert(bits_if(true, x) == r_bits(x) * 10);
        assert(bits_if(false, x) == r_bits(x + 1));
    }
    assert(walk(0) == 0 && walk(1234) == 1234);
    assert(bumped(1) == 12);
    { uint32_t v = 3; bump_ref(&v, 4); assert(v == 7); }
    for (uint32_t a = 0; a < 40; a += 3) for (uint32_t b = 0; b < 40; b += 5) assert(gcd(a, b) == r_gcd(a, b));
    assert(swapper(7, 9, 0) == 71 && swapper(7, 9, 1) == 91 && swapper(7, 9, 4) == 71 && swapper(7, 9, 5) == 91);
    assert(walk_auto(0) == 0 && walk_auto(777) == 777);
    assert(cube(3) == 27 && cube(10) == 1000);
    for (uint32_t m = 1; m < 8; m++) for (uint32_t l = 0; l < 30; l += 4) assert(first_multiple(m, l) == r_first(m, l));
    for (uint32_t x = 0; x < 20; x++) assert(sum_until(x) == r_sum_until(x));
    for (uint32_t n = 0; n < 50; n++) assert(hidden(n) == n * (n + 1) / 2);
    { uint32_t a = 0, b = 1; for (uint32_t n = 0; n < 20; n++) { assert(fib_pair(n) == a * 1000 + b); uint32_t t = a + b; a = b; b = t; } }
    puts("stress: ok");
    return 0;
}
