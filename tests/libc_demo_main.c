#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>

bool report(const char *, uint32_t, double);
uint32_t checksum(const char *), sum_filled(uint32_t, uint8_t);
void greet(uint32_t);

static uint32_t c_sum(const char *s) { uint32_t t = 0; while (*s) t += (unsigned char)*s++; return t; }

int main(void) {
    const char *path = "/tmp/slc_libc_demo.txt";
    assert(report(path, 5, 0.5));
    char buf[128] = { 0 };
    FILE *f = fopen(path, "r");
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    buf[n] = 0;
    assert(strcmp(buf, "report\nn = 5, ratio = 0.5\nsmall\n") == 0);
    assert(checksum(path) == c_sum(buf));

    assert(report(path, 20, 2.0));           /* the early return still closes the file */
    f = fopen(path, "r");
    n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    buf[n] = 0;
    assert(strcmp(buf, "report\nn = 20, ratio = 2\n") == 0);

    assert(!report("/nonexistent/dir/x", 1, 1.0));
    assert(checksum("/nonexistent/dir/x") == 0);
    assert(sum_filled(10, 2) == 1 + 9 * 2);
    greet(7);
    puts("libc_demo: ok");
    return 0;
}
