#include "slc_rt.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
typedef struct Str { uint8_t *ptr; uint32_t len; } Str;
uint32_t known_number(uint32_t key);
uint32_t known_word(Str key);
uint32_t known_checked(Str key);
uint32_t known_constant(void);
uint32_t known_order(void);
uint32_t known_label(Str key);
static Str text(const char *p) { Str s = { (uint8_t *)p, (uint32_t)strlen(p) }; return s; }
static void missing(void *unused) { (void)unused; (void)known_checked(text("missing")); }
int main(void) {
    Str binary = { (uint8_t *)"a\0b", 3 };
    assert(known_number(1) == 10 && known_number(2) == 20 && known_number(9) == 0);
    assert(known_word(text("if")) == 1 && known_word(binary) == 2);
    assert(known_checked(text("length")) == 3 && known_word(text("")) == 4);
    assert(known_word(text("absent")) == 0);
    assert(known_constant() == 13 && known_order() == 12);
    assert(known_label(text("x")) == 42 && known_label(text("y")) == 0);
    assert(slc_try(missing, NULL) == 1);
    assert(strstr(slc_trap_message(), "map-key") != NULL);
    puts("known maps: immutable snapshots, folding, ordered each and dynamic lookup passed");
    return 0;
}
