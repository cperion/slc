#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
typedef struct Str { uint8_t *ptr; uint32_t len; } Str;
bool is_world(Str name);
uint32_t word_count(Str text);
int64_t line_sum(Str line);
uint32_t port_of(Str config);
uint32_t where(Str s);
bool render_matches(uint32_t n, bool ok, Str expected);
uint32_t remember(Str name, uint32_t age);
int32_t order(Str a, Str b);
static Str S(const char *s) { Str r; r.ptr = (uint8_t *)s; r.len = (uint32_t)strlen(s); return r; }
static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)
int main(void) {
    CHECK(is_world(S("world")) && !is_world(S("worle")) && !is_world(S("worlds")));
    CHECK(word_count(S("  one two   three ")) == 3);
    CHECK(word_count(S("")) == 0);
    CHECK(line_sum(S("10, -3, x, 5")) == 12);
    CHECK(line_sum(S("9223372036854775807")) == INT64_C(9223372036854775807));
    CHECK(line_sum(S("-9223372036854775808")) == INT64_MIN);
    CHECK(line_sum(S("9223372036854775808")) == 0);          /* too big: not a number */
    CHECK(port_of(S("host=a\nport=8080\nuser=b\n")) == 8080);
    CHECK(port_of(S("port=x\n")) == 0);
    CHECK(where(S("the quick brown fox")) == 16);
    CHECK(where(S("no")) == 99);
    CHECK(where(S("fo")) == 99);
    CHECK(render_matches(42, true, S("n = 42, ok = true, unit = 1.5")));
    CHECK(!render_matches(42, false, S("n = 42, ok = true, unit = 1.5")));
    CHECK(remember(S("Ada"), 36) == 39);
    CHECK(remember(S(""), 1) == 1);
    CHECK(order(S("abc"), S("abd")) == -1);
    CHECK(order(S("abc"), S("abc")) == 0);
    CHECK(order(S("abcd"), S("abc")) == 1);
    printf("strings: %s\n", fails ? "FAILED" : "ok");
    return fails != 0;
}
