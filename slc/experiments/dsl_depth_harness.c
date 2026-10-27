/* Run from repository root; generated C stays under ignored slc/build/. */
#include <assert.h>
#include <stdio.h>
#include "../build/dsl_depth.c"

int main(void) {
    unsigned checks = 0;
    for (uint32_t n = 0; n <= 256; ++n) {
        uint32_t sum = 0, before = 0, after = 0;
        for (uint32_t i = 1; i <= n; ++i) {
            if ((i * 2u) % 3u == 0) sum += i * 2u;
            if (i > 5u) before += i * 2u;
            if (i * 2u > 5u) after += i * 2u;
        }
        assert(stream_sum(n) == sum); ++checks;
        assert(filter_first(n) == before); ++checks;
        assert(map_first(n) == after); ++checks;
        for (uint32_t threshold = 0; threshold <= 260; threshold += 13) {
            uint32_t expected = 0;
            for (uint32_t i = 1; i <= n; ++i)
                if (i > threshold) expected += i;
            assert(threshold_sum(n, threshold) == expected); ++checks;
        }
    }
    const uint32_t values[] = {0, 1, 2, 5, 10, 30, 31, 50, 100, UINT32_MAX, UINT32_MAX / 3};
    for (size_t i = 0; i < sizeof(values)/sizeof(values[0]); ++i) {
        uint32_t x = values[i], v = x * 3u + 7u;
        assert(formula_native(x) == v); ++checks;
        assert(scripted(x) == (v > 100u ? 100u : v)); ++checks;
        for (size_t j = 0; j < sizeof(values)/sizeof(values[0]); ++j) {
            uint32_t a = values[j];
            Instruction add = {.tag = Instruction_add, .as.add = a};
            Instruction mul = {.tag = Instruction_multiply, .as.multiply = a};
            Instruction cap = {.tag = Instruction_ceiling, .as.ceiling = a};
            assert(runtime_sum(add, x) == x + a); ++checks;
            assert(runtime_sum(mul, x) == x * a); ++checks;
            assert(runtime_sum(cap, x) == (x > a ? a : x)); ++checks;
            assert(runtime_instruction(0, a, x) == x + a); ++checks;
            assert(runtime_instruction(1, a, x) == x * a); ++checks;
            assert(runtime_instruction(2, a, x) == (x > a ? a : x)); ++checks;
            for (size_t k = 0; k < sizeof(values)/sizeof(values[0]); ++k) {
                uint32_t max = values[k], draft = x + a - 2u;
                assert(activity(x, a, max) == (draft > max ? x : draft)); ++checks;
            }
        }
    }
    assert(stream_known() == 36); ++checks;
    printf("DSL depth: %u assertions passed\n", checks);
    return 0;
}
