/* Harness for examples/guide.slc: the guide's examples, run. */
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include "slc_rt.h"

typedef struct Document { uint32_t length, cursor, edits; } Document;
typedef struct Stats { uint32_t entered, left; } Stats;
typedef struct U32Slice { uint32_t *ptr; uint32_t len; } U32Slice;

uint32_t outline_demo(uint32_t n);
uint32_t first_or(U32Slice xs, uint32_t fallback);
uint32_t tab_stop_4(uint32_t column);
uint32_t type_word(Document *d, uint32_t n);
void import_words(Document *d, Stats *s, uint32_t n);
void type_greeting(Document *d);
uint32_t line_count_2(const char *path);
uint32_t ask(void);

static int failures;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

int main(void) {
    uint32_t xs[] = { 0, 0, 7, 9 }, zeros[] = { 0, 0 };
    U32Slice a = { xs, 4 }, b = { zeros, 2 };
    Document d = { 0, 0, 0 };
    Stats st = { 0, 0 };
    FILE *f;
    int i;
    CHECK(outline_demo(5) == 10);
    CHECK(first_or(a, 99) == 7);
    CHECK(first_or(b, 99) == 99);
    CHECK(tab_stop_4(5) == 8 && tab_stop_4(0) == 4);
    CHECK(type_word(&d, 3) == 1 && d.length == 3 && d.cursor == 2 && d.edits == 1);
    import_words(&d, &st, 4);
    CHECK(st.entered == 2 && st.left == 2 && d.length == 7);
    d.length = d.cursor = d.edits = 0;
    type_greeting(&d);
    CHECK(d.length == 6 && d.cursor == 5);
    /* a file of 1000 lines, read in 64-byte chunks by two workers */
    f = fopen("/tmp/slc_guide_words.txt", "w");
    for (i = 0; i < 1000; i++) fprintf(f, "alpha beta gamma\n");
    fclose(f);
    CHECK(line_count_2("/tmp/slc_guide_words.txt") == 1000);
    CHECK(ask() == 42);
    if (failures == 0) printf("guide: all checks passed\n");
    return failures != 0;
}
