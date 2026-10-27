/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Test-only oracle: the obvious encoder, written out. The program under test is
 * examples/base64.slc; nothing here is linked into a program. */
#ifndef SLC_TEST_BASE64_REFERENCE_H
#define SLC_TEST_BASE64_REFERENCE_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>

static const char ref_base64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/* four characters per three bytes, padding the last group; writes n/3*4 + 4 at most */
static size_t ref_base64_encode(const uint8_t *in, size_t n, char *out) {
    size_t i, o = 0;
    for (i = 0; i + 3 <= n; i += 3) {
        out[o++] = ref_base64[in[i] >> 2];
        out[o++] = ref_base64[((in[i] & 3) << 4) | (in[i + 1] >> 4)];
        out[o++] = ref_base64[((in[i + 1] & 15) << 2) | (in[i + 2] >> 6)];
        out[o++] = ref_base64[in[i + 2] & 63];
    }
    if (i < n) {
        out[o++] = ref_base64[in[i] >> 2];
        if (i + 1 < n) {
            out[o++] = ref_base64[((in[i] & 3) << 4) | (in[i + 1] >> 4)];
            out[o++] = ref_base64[(in[i + 1] & 15) << 2];
        } else {
            out[o++] = ref_base64[(in[i] & 3) << 4];
            out[o++] = '=';
        }
        out[o++] = '=';
    }
    out[o] = 0;
    return o;
}

#endif
