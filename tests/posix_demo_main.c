#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <errno.h>

int32_t make_file(const char *);
uint32_t magic(const char *);
bool missing(const char *);
uint64_t ping(uint64_t);

int main(void) {
    const char *path = "/tmp/slc_posix_demo.bin";
    assert(make_file(path) == 0);
    char buf[64] = { 0 };
    FILE *f = fopen(path, "rb");
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    assert(n == 18 && memcmp(buf, "SLC1hello, kernel\n", 18) == 0);
    assert(magic(path) == 0x534c4331u);                 /* "SLC1", big-endian */
    assert(make_file("/nonexistent/dir/x") == ENOENT);
    assert(magic("/nonexistent/dir/x") == 0);
    assert(missing("/nonexistent/dir/x") && !missing(path));
    assert(ping(7) == 7 && ping(123456789012ull) == 123456789012ull);
    puts("posix_demo: ok");
    return 0;
}
