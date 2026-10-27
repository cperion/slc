/* Deliberately straightforward, independently written C for the packet layout.
 * Same validation, failure atomicity, prefix parsing, ABI and non-overlap
 * contract as SLC. No runtime schema interpreter is penalized here. */
#include "baseline.h"
#include <string.h>

uint32_t c_size(Message m, uint32_t length) {
    if (m.version != 1 || m.flags > 3 || m.length > 4096 || m.length != length)
        return 0;
    return 8 + length;
}

static uint32_t encode_header(Message m, U8Slice payload, uint8_t *out, uint32_t cap) {
    uint32_t size = c_size(m, payload.len);
    if (!size || cap < size) return 0;
    out[0] = (uint8_t)m.version;
    out[1] = (uint8_t)m.flags;
    out[2] = (uint8_t)(m.sequence >> 24);
    out[3] = (uint8_t)(m.sequence >> 16);
    out[4] = (uint8_t)(m.sequence >> 8);
    out[5] = (uint8_t)m.sequence;
    out[6] = (uint8_t)(m.length >> 8);
    out[7] = (uint8_t)m.length;
    return size;
}

uint32_t c_encode(Message m, U8Slice payload, uint8_t *out, uint32_t cap) {
    uint32_t size = encode_header(m, payload, out, cap);
    if (!size) return 0;
    for (uint32_t i = 0; i < payload.len; ++i) out[8 + i] = payload.ptr[i];
    return size;
}

uint32_t c_encode_memcpy(Message m, U8Slice payload, uint8_t *out, uint32_t cap) {
    uint32_t size = encode_header(m, payload, out, cap);
    if (!size) return 0;
    if (payload.len) memcpy(out + 8, payload.ptr, payload.len);
    return size;
}

uint32_t c_decode(U8Slice input, Message *out) {
    if (input.len < 8) return 0;
    Message m;
    m.version = input.ptr[0];
    m.flags = input.ptr[1];
    m.sequence = ((uint32_t)input.ptr[2] << 24) | ((uint32_t)input.ptr[3] << 16)
        | ((uint32_t)input.ptr[4] << 8) | input.ptr[5];
    m.length = ((uint32_t)input.ptr[6] << 8) | input.ptr[7];
    if (m.version != 1 || m.flags > 3 || m.length > 4096) return 0;
    uint32_t consumed = 8 + m.length;
    if (input.len < consumed) return 0;
    *out = m;
    return consumed;
}

uint64_t c_visit(U8Slice input) {
    Message m;
    uint32_t consumed = c_decode(input, &m);
    if (!consumed) return 0;
    uint32_t checksum = m.sequence;
    for (uint32_t i = 0; i < m.length; ++i) checksum += input.ptr[8 + i];
    return ((uint64_t)consumed << 32) + checksum;
}
