/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _POSIX_C_SOURCE 200809L
#include "base64_reference.h"
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int32_t main_(void);

/* Run the program over one buffer: stdin from a file, stdout to a file, the way
 * a shell would run it. Returns the encoded length. */
static size_t run_main(const uint8_t *in, size_t n, char *out, size_t cap) {
    char inpath[] = "/tmp/slc_base64_inXXXXXX", outpath[] = "/tmp/slc_base64_outXXXXXX";
    int infd = mkstemp(inpath), outfd = mkstemp(outpath);
    assert(infd >= 0 && outfd >= 0);
    if (n) assert(write(infd, in, n) == (ssize_t)n);
    assert(lseek(infd, 0, SEEK_SET) == 0);
    int saved0 = dup(0), saved1 = dup(1);
    assert(saved0 >= 0 && saved1 >= 0);
    assert(dup2(infd, 0) == 0 && dup2(outfd, 1) == 1);
    close(infd);
    assert(main_() == 0);
    assert(dup2(saved0, 0) == 0 && dup2(saved1, 1) == 1);
    close(saved0);
    close(saved1);
    assert(lseek(outfd, 0, SEEK_SET) == 0);
    size_t got = 0;
    ssize_t r;
    while (got < cap && (r = read(outfd, out + got, cap - got)) > 0) got += (size_t)r;
    close(outfd);
    assert(unlink(inpath) == 0);
    assert(unlink(outpath) == 0);
    return got;
}

/* Fill a buffer from a counter: no libc randomness, so a failure repeats. */
static void fill(uint8_t *p, size_t n) {
    size_t i;
    for (i = 0; i < n; i++) p[i] = (uint8_t)(i * 7 + (i >> 3));
}

int main(void) {
    static const struct { const char *plain, *encoded; } vectors[] = {
        { "", "" }, { "f", "Zg==" }, { "fo", "Zm8=" }, { "foo", "Zm9v" },
        { "foob", "Zm9vYg==" }, { "fooba", "Zm9vYmE=" }, { "foobar", "Zm9vYmFy" },
    };
    static const size_t sizes[] = { 0, 1, 2, 3, 4, 5, 3071, 3072, 3073, 3074, 4094,
        4095, 4096, 4097, 6143, 6144, 6145, 8192 };
    uint8_t in[8192];
    char out[11200], expected[11200];
    size_t i;

    /* RFC 4648 §10, through the program itself */
    for (i = 0; i < sizeof vectors / sizeof vectors[0]; i++) {
        size_t n = strlen(vectors[i].plain), want = strlen(vectors[i].encoded);
        memcpy(in, vectors[i].plain, n);
        size_t got = run_main(in, n, out, sizeof out);
        assert(got == want);
        assert(memcmp(out, vectors[i].encoded, want) == 0);
    }

    /* the same bytes through the program's own path, at the buffer boundaries:
     * 3072 is its input buffer, 4096 its output buffer, so these straddle the
     * refill that carries a one- or two-byte tail to the front */
    for (i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
        size_t n = sizes[i];
        fill(in, n);
        size_t want = ref_base64_encode(in, n, expected);
        assert(want < sizeof expected);
        size_t got = run_main(in, n, out, sizeof out);
        if (got != want || memcmp(out, expected, want) != 0) {
            fprintf(stderr, "base64 mismatch at %zu bytes: got %zu, want %zu\n", n, got, want);
            return 1;
        }
    }

    puts("SLC base64: RFC vectors and stdin/stdout streaming at the buffer boundaries passed");
    return 0;
}
