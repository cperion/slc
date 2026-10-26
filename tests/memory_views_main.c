#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "slc_rt.h"

typedef struct Pixel { uint8_t r, g, b; } Pixel;
typedef struct U8Slice { uint8_t *ptr; uint32_t len; } U8Slice;
typedef struct Packet { uint32_t version, flags, length, id; } Packet;

void brighten(Pixel *, uint32_t, uint8_t);
uint32_t first_or(uint32_t *, uint32_t), through_pointer(uint32_t);
uint32_t sum(U8Slice), sum_raw(uint8_t *, uint32_t), squares(uint32_t);
Packet parse(U8Slice);
void fill(uint32_t *, uint32_t, uint32_t);

int main(void) {
    Pixel px[3] = { { 10, 1, 1 }, { 250, 2, 2 }, { 0, 3, 3 } };
    brighten(px, 3, 10);
    assert(px[0].r == 20 && px[1].r == 4 && px[2].r == 10 && px[1].g == 2);

    uint32_t one = 42;
    assert(first_or(&one, 7) == 42 && first_or(NULL, 7) == 7);
    assert(through_pointer(4) == 50);

    uint8_t bytes[5] = { 1, 2, 3, 4, 250 };
    U8Slice s = { bytes, 5 };
    assert(sum(s) == 260 && sum_raw(bytes, 5) == 260 && sum_raw(bytes, 0) == 0);

    uint8_t pkt[10] = { 2, 0x81, 0x01, 0x02, 0xde, 0xad, 0xbe, 0xef, 9, 9 };
    Packet p = parse((U8Slice){ pkt, 10 });
    assert(p.version == 2 && p.flags == 0x81 && p.length == 0x0102 && p.id == 0xdeadbeefu);

    assert(squares(0) == 0 && squares(4) == 30 && squares(100) == 338350);
    assert(slc_gs_top(0) == 0);
    { uint32_t a[4] = { 0 }; fill(a, 4, 10); assert(a[0] == 10 && a[3] == 13); }
    puts("memory_views: ok");
    return 0;
}
