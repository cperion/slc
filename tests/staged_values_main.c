#include "slc_rt.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
typedef struct Str { uint8_t *ptr; uint32_t len; } Str;
typedef struct U8x4 { uint8_t e[4]; } U8x4;
typedef struct Chars4 { uint32_t len; U8x4 bytes; } Chars4;
uint32_t stage_filled(Str s);
Chars4 stage_value(void);
Chars4 stage_binary_value(void);
bool stage_empty(void);
uint32_t stage_live(uint32_t n);
bool stage_shorter(void);
bool stage_nested(void);
bool stage_branch(bool flag);
bool stage_choose_view(bool flag);
uint8_t stage_changed_byte(uint8_t byte);
uint32_t stage_snapshot(uint8_t byte);
uint8_t stage_escape(uint8_t byte);
int32_t stage_parse(void);
uint8_t stage_index(uint32_t i);
uint32_t stage_array_copy(uint32_t n);
uint32_t stage_array_view(void);
uint32_t stage_array_nested(void);
uint32_t stage_array_loop(uint32_t n);
uint8_t stage_view_loop(uint32_t n);
bool stage_captured_length(Str s);
double stage_signed_zero(bool flag);
uint32_t stage_partial(Str s, uint8_t byte);
uint32_t stage_split(uint8_t byte);
uint32_t stage_task_copy(uint8_t byte);
uint32_t stage_dead_write(uint32_t i);
static Str S(const char *s) { Str v = { (uint8_t *)s, (uint32_t)strlen(s) }; return v; }
static void too_long(void *unused) { (void)unused; (void)stage_filled(S("abcde")); }
static void bad_index(void *unused) { (void)unused; (void)stage_index(3); }
static void dead_store_bounds(void *unused) { (void)unused; (void)stage_dead_write(2); }
int main(void) {
    assert(stage_filled(S("")) == 0);
    assert(stage_filled(S("abc")) == 3);
    assert(stage_filled(S("abcd")) == 4);
    Chars4 value = stage_value();
    assert(value.len == 3 && memcmp(value.bytes.e, "abc\0", 4) == 0);
    value = stage_binary_value();
    assert(value.len == 3 && memcmp(value.bytes.e, "a\0b\0", 4) == 0);
    assert(stage_empty() && stage_shorter() && stage_nested());
    assert(stage_live(5) == 6);
    assert(stage_branch(true) && !stage_branch(false));
    assert(stage_choose_view(true) && !stage_choose_view(false));
    for (unsigned i = 0; i < 256; ++i) {
        assert(stage_changed_byte((uint8_t)i) == i);
        assert(stage_snapshot((uint8_t)i) == i + 90);
        assert(stage_escape((uint8_t)i) == i);
        assert(stage_partial(S("abc"), (uint8_t)i) == i + 100);
        assert(stage_split((uint8_t)i) == i + 100);
    }
    assert(stage_parse() == -12);
    assert(stage_index(0) == 97 && stage_index(2) == 99);
    assert(stage_array_copy(5) == 31 && stage_array_copy(7) == 33);
    assert(stage_array_view() == 16 && stage_array_nested() == 5);
    for (uint32_t i = 0; i < 20; ++i) {
        assert(stage_array_loop(i) == i * (i + 1) / 2);
        assert(stage_view_loop(i) == (i == 0 ? 97 : 65 + (i - 1) % 26));
    }
    assert(stage_captured_length(S("")) && stage_captured_length(S("abcd")));
    assert(stage_task_copy(0) == 0 && stage_task_copy(20) == 40 && stage_task_copy(255) == 510);
    assert(signbit(stage_signed_zero(true)) && !signbit(stage_signed_zero(false)));
    assert(slc_try(too_long, NULL) == 1);
    assert(strstr(slc_trap_message(), "text longer") != NULL);
    assert(slc_try(bad_index, NULL) == 1);
    assert(strstr(slc_trap_message(), "index out of range") != NULL);
    assert(stage_dead_write(1) == 1 && slc_try(dead_store_bounds, NULL) == 1);
    assert(strstr(slc_trap_message(), "index out of range") != NULL);
    assert(stage_live(5) == 6); /* a trapped call does not poison the next one */
    slc_stacks_free(&slc_own_stacks);
    puts("staged values: ok");
    return 0;
}
