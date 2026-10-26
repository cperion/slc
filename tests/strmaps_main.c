#include "slc_rt.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
typedef struct Str { uint8_t *ptr; uint32_t len; } Str;
uint32_t strmap_words(Str text);
uint32_t strmap_copy(void);
uint32_t strmap_live_key(void);
uint32_t strmap_scopes(uint32_t n);
uint32_t strmap_missing(Str key);
uint32_t strmap_mutation(uint32_t mode);
uint32_t strmap_reserved_keys(void);
uint32_t map_bool_keys(void);
uint32_t strmap_lookup(Str key);
static Str str(const char *s) { Str v = { (uint8_t *)s, (uint32_t)strlen(s) }; return v; }
static void missing(void *unused) { (void)unused; (void)strmap_missing(str("missing")); }
static void mutation(void *mode) { (void)strmap_mutation(*(uint32_t *)mode); }
int main(void) {
    uint32_t i;
    assert(strmap_words(str("a b a cat b")) == 503);
    assert(strmap_words(str("   ")) == 0);
    assert(strmap_copy() == 27);
    assert(strmap_live_key() == 12);
    assert(strmap_reserved_keys() == 21);
    assert(map_bool_keys() == 5);
    assert(strmap_lookup(str("dynamic key")) == 20);
    assert(strmap_lookup(str("")) == 20);
    for (i = 0; i < 20; i++) {
        uint32_t odds = (i + 1) / 2;
        assert(strmap_scopes(i) == odds * odds);
        assert(slc_gs_top(0) == 0 && slc_gs_top(1) == 0);
    }
    assert(slc_try(missing, NULL) == 1);
    assert(strstr(slc_trap_message(), "map-key") != NULL);
    for (i = 0; i < 2; i++) {
        assert(slc_try(mutation, &i) == 1);
        assert(strstr(slc_trap_message(), "structural mutation") != NULL);
        assert(strmap_copy() == 27);
    }
    slc_stacks_free(&slc_own_stacks);
    puts("StrMap: copied keys, binary text, iteration, live view keys and scope cleanup passed");
    return 0;
}
