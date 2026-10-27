#define _GNU_SOURCE
#include "baseline.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); abort(); } } while (0)
static uint32_t random_state = 0x51cba123u;
static uint32_t random_u32(void) {
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return random_state;
}
static int same(Message a, Message b) {
    return a.version == b.version && a.flags == b.flags && a.sequence == b.sequence && a.length == b.length;
}
static const Message sentinel = {99, 98, 97, 96};

static void compare_decode(uint8_t *bytes, uint32_t length) {
    Message a = sentinel, b = sentinel;
    U8Slice input = {bytes, length};
    uint32_t x = packet_decode(input, &a), y = c_decode(input, &b);
    CHECK(x == y);
    CHECK(same(a, b));
    CHECK(packet_visit(input) == c_visit(input));
    CHECK(packet_visit(input) == c_visit_fused(input));
    if (!x) CHECK(same(a, sentinel));
}

static void guarded_inputs(void) {
    long page = sysconf(_SC_PAGESIZE);
    CHECK(page > 16);
    uint8_t *memory = mmap(NULL, (size_t)page * 2, PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(memory != MAP_FAILED);
    CHECK(mprotect(memory + page, (size_t)page, PROT_NONE) == 0);
    const uint8_t wire[] = {1, 3, 0x12, 0x34, 0x56, 0x78, 0, 3, 10, 20, 30};
    for (uint32_t n = 0; n <= sizeof(wire); ++n) {
        uint8_t *at = memory + page - n;
        memcpy(at, wire, n);
        compare_decode(at, n);
    }
    /* Complete header claims data across the inaccessible page: reject first. */
    uint8_t *at = memory + page - 8;
    memcpy(at, wire, 8);
    at[6] = 0x10; at[7] = 0;
    compare_decode(at, 8);
    /* Exactly sized output abuts the guard page as well. */
    uint8_t data[] = {10, 20, 30};
    for (uint32_t n = 0; n <= 3; ++n) {
        uint8_t *out = memory + page - (8 + n);
        Message m = {1, 3, 0x12345678, n};
        CHECK(packet_encode(m, (U8Slice){data, n}, out, 8 + n) == 8 + n);
        Message decoded = sentinel;
        CHECK(packet_decode((U8Slice){out, 8 + n}, &decoded) == 8 + n);
        CHECK(same(m, decoded));
    }
    CHECK(munmap(memory, (size_t)page * 2) == 0);
}

int main(void) {
    uint8_t payload[4097], a[4120], b[4120], c[4120];
    for (unsigned i = 0; i < sizeof(payload); ++i) payload[i] = (uint8_t)random_u32();
    const uint8_t golden[] = {1, 3, 0x12, 0x34, 0x56, 0x78, 0, 3, 10, 20, 30};
    uint8_t three[] = {10, 20, 30};
    Message record = {1, 3, 0x12345678, 3};
    CHECK(packet_encode(record, (U8Slice){three, 3}, a, sizeof(a)) == sizeof(golden));
    CHECK(memcmp(a, golden, sizeof(golden)) == 0);
    CHECK(packet_visit((U8Slice){a, sizeof(golden)}) == ((uint64_t)11 << 32) + 0x12345678u + 60);

    for (uint32_t n = 0; n <= 4096; ++n) {
        record = (Message){1, random_u32() & 3, random_u32(), n};
        U8Slice data = {n ? payload : NULL, n};
        memset(a, 0xa5, sizeof(a)); memset(b, 0xa5, sizeof(b)); memset(c, 0xa5, sizeof(c));
        CHECK(packet_size(record, n) == 8 + n);
        CHECK(packet_size(record, n) == c_size(record, n));
        CHECK(packet_encode(record, data, a + 1, 8 + n) == 8 + n);
        CHECK(c_encode(record, data, b + 1, 8 + n) == 8 + n);
        CHECK(c_encode_memcpy(record, data, c + 1, 8 + n) == 8 + n);
        CHECK(memcmp(a, b, sizeof(a)) == 0 && memcmp(a, c, sizeof(a)) == 0);
        CHECK(a[0] == 0xa5 && a[9 + n] == 0xa5);
        Message decoded = sentinel;
        CHECK(packet_decode((U8Slice){a + 1, 8 + n}, &decoded) == 8 + n);
        CHECK(same(record, decoded));
        /* Prefix parser: trailing bytes are left alone, not counted. */
        CHECK(packet_decode((U8Slice){a + 1, 10 + n}, &decoded) == 8 + n);
        compare_decode(a + 1, 8 + n);
        CHECK(owned_roundtrip(record.sequence) == ((uint64_t)11 << 32) + (uint32_t)(record.sequence + 60));
        memset(b, 0xa5, sizeof(b));
        CHECK(packet_encode(record, data, b + 1, 7 + n) == 0);
        for (size_t i = 0; i < sizeof(b); ++i) CHECK(b[i] == 0xa5);
        if (n == 0 || n == 1 || n == 3 || n == 255 || n == 256 || n == 4096)
            for (uint32_t cut = 0; cut < 8 + n; ++cut) compare_decode(a + 1, cut);
    }

    const Message invalid[] = {{0, 0, 0, 0}, {256, 0, 0, 0}, {1, 4, 0, 0},
        {1, UINT32_MAX, 0, 0}, {1, 0, 0, 4097}, {1, 0, 0, UINT32_MAX}, {1, 0, 0, 1}};
    for (size_t i = 0; i < sizeof(invalid)/sizeof(invalid[0]); ++i) {
        memset(a, 0xa5, sizeof(a)); memset(b, 0xa5, sizeof(b));
        CHECK(packet_size(invalid[i], 0) == 0);
        CHECK(packet_encode(invalid[i], (U8Slice){NULL, 0}, a, sizeof(a)) == 0);
        CHECK(memcmp(a, b, sizeof(a)) == 0);
        CHECK(c_encode(invalid[i], (U8Slice){NULL, 0}, a, sizeof(a)) == 0);
        CHECK(c_encode_memcpy(invalid[i], (U8Slice){NULL, 0}, a, sizeof(a)) == 0);
        CHECK(memcmp(a, b, sizeof(a)) == 0);
    }
    CHECK(packet_encode((Message){1, 0, 0, 0}, (U8Slice){NULL, 0}, NULL, 0) == 0);
    compare_decode(NULL, 0);
    /* Mutations have a valid base, avoiding a fuzz corpus dominated by bad version bytes. */
    for (unsigned iteration = 0; iteration < 12000; ++iteration) {
        uint32_t n = random_u32() % 4097;
        record = (Message){1, random_u32() & 3, random_u32(), n};
        CHECK(c_encode(record, (U8Slice){payload, n}, a, sizeof(a)) == n + 8);
        if (iteration % 3) a[random_u32() % (n + 8)] ^= (uint8_t)(1u << (random_u32() % 8));
        uint32_t available = iteration % 4 ? n + 8 : random_u32() % (n + 9);
        compare_decode(a, available);
    }

    /* Independently specified compact golden bytes + exhaustive payload lengths. */
    const uint8_t compact_golden[] = {0x78, 0x56, 0x34, 0x12, 2, 15, 3, 10, 20, 30};
    record = (Message){2, 15, 0x12345678, 3};
    CHECK(compact_encode(record, (U8Slice){three, 3}, a, sizeof(a)) == sizeof(compact_golden));
    CHECK(memcmp(a, compact_golden, sizeof(compact_golden)) == 0);
    for (uint32_t n = 0; n <= 255; ++n) {
        record = (Message){2, n % 16, random_u32(), n};
        CHECK(compact_size(record, n) == 7 + n);
        CHECK(compact_encode(record, (U8Slice){payload, n}, a, sizeof(a)) == 7 + n);
        Message decoded = sentinel;
        CHECK(compact_decode((U8Slice){a, n + 7}, &decoded) == n + 7);
        CHECK(same(record, decoded));
        for (uint32_t cut = 0; cut < n + 7; ++cut) {
            decoded = sentinel;
            CHECK(compact_decode((U8Slice){a, cut}, &decoded) == 0);
            CHECK(same(decoded, sentinel));
        }
    }
    /* Compact validation is exercised independently, not only through round trips. */
    memcpy(a, compact_golden, sizeof(compact_golden));
    for (unsigned field = 4; field <= 5; ++field) {
        uint8_t saved = a[field];
        a[field] = field == 4 ? 1 : 16;
        Message decoded = sentinel;
        CHECK(compact_decode((U8Slice){a, sizeof(compact_golden)}, &decoded) == 0);
        CHECK(same(decoded, sentinel));
        a[field] = saved;
    }
    CHECK(owned_roundtrip(UINT32_MAX) == ((uint64_t)11 << 32) + 59);
    record.length = 256;
    CHECK(compact_size(record, 256) == 0);
    CHECK(compact_encode(record, (U8Slice){payload, 256}, a, sizeof(a)) == 0);
    guarded_inputs();
    printf("binary DSL: %u checks passed (all lengths, mutations, truncations, canaries, guard pages)\n", checks);
    return 0;
}
