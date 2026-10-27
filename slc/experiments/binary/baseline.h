#ifndef BINARY_DSL_BASELINE_H
#define BINARY_DSL_BASELINE_H
#include <stdint.h>
/* The -H output supplies prototypes, not record definitions. This mirrors the
 * public native ABI only; wire offsets and encoding live in baseline.c. */
typedef struct Message {
    uint32_t version, flags, sequence, length;
} Message;
typedef struct U8Slice {
    uint8_t *ptr;
    uint32_t len;
} U8Slice;
#include "packet.h"
uint32_t c_size(Message record, uint32_t payload_length);
uint32_t c_encode(Message record, U8Slice payload, uint8_t *output, uint32_t capacity);
uint32_t c_encode_memcpy(Message record, U8Slice payload, uint8_t *output, uint32_t capacity);
uint32_t c_decode(U8Slice input, Message *output);
uint64_t c_visit(U8Slice input);
uint64_t c_visit_fused(U8Slice input);
#endif
