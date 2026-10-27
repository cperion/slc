#define _POSIX_C_SOURCE 200809L
#include "baseline.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Hot repeated corpus, not a network/storage benchmark. All timed calls cross
 * the same out-of-line ABI; compile the three translation units without LTO. */
enum { CORPUS = 256, MAX_PAYLOAD = 4096, STRIDE = MAX_PAYLOAD + 8 };
static uint8_t source[CORPUS][MAX_PAYLOAD];
static uint8_t wires[CORPUS][STRIDE];
static uint8_t outputs[CORPUS][STRIDE];
static Message records[CORPUS];
static U8Slice inputs[CORPUS], payloads[CORPUS];
static volatile uint64_t sink;
typedef uint32_t (*encoder)(Message, U8Slice, uint8_t *, uint32_t);
typedef uint32_t (*decoder)(U8Slice, Message *);
typedef uint64_t (*visitor)(U8Slice);
struct Implementation { const char *name; encoder encode; decoder decode; visitor visit; };
static struct Implementation implementations[] = {
    {"slc", packet_encode, packet_decode, packet_visit},
    {"c-loop", c_encode, c_decode, c_visit},
    {"c-memcpy", c_encode_memcpy, c_decode, c_visit_fused}
};

static uint64_t now(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) abort();
    return (uint64_t)t.tv_sec * UINT64_C(1000000000) + (uint64_t)t.tv_nsec;
}
static void prepare(uint32_t length, int mixed) {
    uint32_t state = 0x51c12345;
    for (unsigned j = 0; j < CORPUS; ++j) {
        for (unsigned i = 0; i < MAX_PAYLOAD; ++i) {
            state = state * 1664525u + 1013904223u;
            source[j][i] = (uint8_t)(state >> 24);
        }
        records[j] = (Message){1, j & 3, state, length};
        payloads[j] = (U8Slice){source[j], length};
        uint32_t size = c_encode(records[j], payloads[j], wires[j], STRIDE);
        if (size != length + 8) abort();
        inputs[j] = (U8Slice){wires[j], size};
        if (mixed && j % 4 == 0) wires[j][0] = 0; /* invalid version: 25% */
        if (mixed && j % 4 == 1) --inputs[j].len; /* truncation: 25% */
    }
}
static uint64_t run(unsigned operation, struct Implementation *impl, uint64_t count, uint32_t length) {
    uint64_t checksum = 0;
    if (operation == 0) {
        encoder f = impl->encode;
        for (uint64_t i = 0; i < count; ++i) {
            unsigned j = (unsigned)i & (CORPUS - 1);
            uint32_t size = f(records[j], payloads[j], outputs[j], STRIDE);
            checksum += size + outputs[j][0] + outputs[j][7 + length];
        }
    } else if (operation == 1 || operation == 3) {
        decoder f = impl->decode;
        for (uint64_t i = 0; i < count; ++i) {
            unsigned j = (unsigned)i & (CORPUS - 1);
            Message decoded = {0, 0, 0, 0};
            checksum += f(inputs[j], &decoded);
            checksum += decoded.version + decoded.flags + decoded.length + decoded.sequence;
        }
    } else {
        visitor f = impl->visit;
        for (uint64_t i = 0; i < count; ++i) {
            unsigned j = (unsigned)i & (CORPUS - 1);
            checksum += f(inputs[j]);
        }
    }
    sink ^= checksum;
    return checksum;
}
int main(int argc, char **argv) {
    unsigned samples = argc > 1 ? (unsigned)strtoul(argv[1], NULL, 10) : 9;
    double target_ms = argc > 2 ? strtod(argv[2], NULL) : 30.0;
    if (samples < 3 || samples > 100 || target_ms < 1 || target_ms > 1000) return 2;
    const uint32_t lengths[] = {0, 16, 128, 1024, 4096};
    const char *operations[] = {"encode", "decode", "visit", "decode-mixed"};
    puts("operation,payload,variant,sample,iterations,elapsed_ns,ns_per_packet,checksum");
    for (unsigned op = 0; op < 4; ++op) {
        unsigned variants = op == 0 || op == 2 ? 3 : 2;
        implementations[2].name = op == 0 ? "c-memcpy" : "c-fused";
        for (unsigned l = 0; l < sizeof(lengths)/sizeof(lengths[0]); ++l) {
            uint32_t length = lengths[l];
            prepare(length, op == 3);
            /* Calibrate on the fastest implementation; every sample is at least
             * approximately target_ms. Same count for every paired variant. */
            uint64_t count = 4096;
            for (;;) {
                uint64_t fastest = UINT64_MAX;
                for (unsigned v = 0; v < variants; ++v) {
                    uint64_t begin = now();
                    run(op, &implementations[v], count, length);
                    uint64_t elapsed = now() - begin;
                    if (elapsed < fastest) fastest = elapsed;
                }
                if ((double)fastest >= target_ms * 1000000.0 || count >= UINT64_C(67108864)) break;
                count *= 2;
            }
            for (unsigned sample = 0; sample < samples; ++sample) {
                uint64_t expected = 0;
                for (unsigned order = 0; order < variants; ++order) {
                    /* Rotate and reverse to reduce systematic order bias. */
                    unsigned v = (sample + (sample % 2 ? variants - order : order)) % variants;
                    run(op, &implementations[v], 4096, length); /* untimed warmup */
                    uint64_t begin = now();
                    uint64_t checksum = run(op, &implementations[v], count, length);
                    uint64_t elapsed = now() - begin;
                    if (order == 0) expected = checksum;
                    else if (checksum != expected) { fputs("benchmark checksum mismatch\n", stderr); return 1; }
                    printf("%s,%u,%s,%u,%" PRIu64 ",%" PRIu64 ",%.6f,%" PRIu64 "\n",
                        operations[op], length, implementations[v].name, sample, count, elapsed,
                        (double)elapsed / (double)count, checksum);
                }
            }
        }
    }
    fprintf(stderr, "observable checksum: %" PRIu64 "\n", sink);
    return 0;
}
