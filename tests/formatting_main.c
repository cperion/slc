#include "slc_rt.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
typedef struct Chars20 { uint32_t len; struct { uint8_t e[20]; } bytes; } Chars20;
typedef struct Str { uint8_t *ptr; uint32_t len; } Str;
Chars20 format_unsigned(uint64_t value);
Chars20 format_signed(int64_t value);
uint32_t format_known_length(void);
bool format_render(int64_t a, uint64_t b, bool flag, Str expected);
static void same(Chars20 got, const char *expected) {
    assert(got.len == strlen(expected));
    assert(memcmp(got.bytes.e, expected, got.len) == 0);
}
int main(void) {
    const uint64_t edges[] = { 0, 1, 9, 10, 99, 100, UINT32_MAX, INT64_MAX, UINT64_MAX };
    char buf[128];
    size_t i;
    for (i = 0; i < sizeof edges / sizeof edges[0]; i++) {
        snprintf(buf, sizeof buf, "%llu", (unsigned long long)edges[i]);
        same(format_unsigned(edges[i]), buf);
    }
    const int64_t signed_edges[] = { INT64_MIN, INT64_MIN + 1, -100, -10, -1, 0, 1, 10, INT64_MAX };
    for (i = 0; i < sizeof signed_edges / sizeof signed_edges[0]; i++) {
        snprintf(buf, sizeof buf, "%lld", (long long)signed_edges[i]);
        same(format_signed(signed_edges[i]), buf);
    }
    uint64_t v = 123456789;
    for (i = 0; i < 128; i++) {
        v ^= v << 13; v ^= v >> 7; v ^= v << 17;
        snprintf(buf, sizeof buf, "%llu", (unsigned long long)v);
        same(format_unsigned(v), buf);
        snprintf(buf, sizeof buf, "%lld", (long long)(int64_t)v);
        same(format_signed((int64_t)v), buf);
    }
    assert(format_known_length() == 20);
    const char *text = "-9223372036854775808,18446744073709551615,false,42,18446744073709551615";
    Str expected = { (uint8_t *)text, (uint32_t)strlen(text) };
    assert(format_render(INT64_MIN, UINT64_MAX, false, expected));
    slc_stacks_free(&slc_own_stacks);
    puts("formatting: SLC known/dynamic integer loops, extrema and Text composition passed");
    return 0;
}
