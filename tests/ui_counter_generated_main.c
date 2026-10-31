#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

/* Native ABI only. The example supplies every routing/drawing algorithm in SLC. */
typedef struct Input { uint32_t kind, x, y; } Input;
typedef struct Draw {
    uint32_t control, x, y, width, height, color, value;
    bool enabled;
} Draw;
typedef struct Frame { uint32_t length; struct { Draw e[5]; } commands; } Frame;
typedef struct Observation {
    uint32_t consumed, frames, count;
    bool enabled, modal;
    Frame frame;
} Observation;
extern uint32_t run_counter_generated(Input *, uint32_t, Observation *);
extern uint32_t counter_limit(uint32_t);
extern bool counter_reset_limit(void);
extern uint32_t known_counter(void);

static const struct {
    Input input;
    uint32_t count;
    bool modal;
} cases[] = {
    {{0, 20, 60}, 1, false},
    {{0, 119, 89}, 2, false},
    {{0, 120, 60}, 2, false}, /* right edge excluded */
    {{0, 20, 90}, 2, false},  /* bottom edge excluded */
    {{0, 19, 60}, 2, false},
    {{0, 20, 59}, 2, false},
    {{0, 128, 60}, 2, true},
    {{0, 20, 60}, 2, true},  /* modal blocks background */
    {{0, 128, 60}, 2, true},
    {{0, 228, 140}, 2, true},
    {{0, 128, 170}, 2, true},
    {{0, 128, 140}, 2, false}, /* keep */
    {{0, 40, 140}, 2, false},  /* hidden dialog cannot activate */
    {{0, 227, 89}, 2, true},
    {{0, 120, 140}, 2, true},
    {{0, 40, 140}, 0, false}, /* reset */
    {{0, 150, 150}, 0, false},
    {{0, 20, 60}, 1, false},
    {{2, 20, 60}, 1, false}, /* unknown input */
    {{0, 128, 60}, 1, true},
    {{1, 0, 0}, 1, true},    /* root quit, including during a modal */
    {{0, 20, 60}, 1, true},  /* not delivered after quit */
};

static void check_frame(const Observation *o, uint32_t count, bool modal) {
    static const uint32_t geometry[][5] = {
        {20, 20, 208, 24, 66051},
        {20, 60, 100, 30, 263430},
        {128, 60, 100, 30, 460809},
        {40, 140, 80, 30, 658188},
        {128, 140, 100, 30, 855567},
    };
    assert(o->count == count && o->modal == modal && o->enabled);
    assert(o->frame.length == (modal ? 5u : 3u));
    for (uint32_t i = 0; i < o->frame.length; ++i) {
        const Draw *d = &o->frame.commands.e[i];
        assert(d->control == i + 1 && d->enabled);
        assert(d->x == geometry[i][0] && d->y == geometry[i][1]);
        assert(d->width == geometry[i][2] && d->height == geometry[i][3]);
        assert(d->color == geometry[i][4]);
        assert(d->value == (i == 0 ? count : 0));
    }
}

int main(void) {
    enum { count = sizeof cases / sizeof cases[0], close_at = 21 };
    Input inputs[count];
    for (unsigned i = 0; i < count; ++i) inputs[i] = cases[i].input;
    /* Every prefix is an independent instance; observe each resulting frame. */
    for (uint32_t n = 0; n <= count; ++n) {
        Observation result = {0};
        uint32_t consumed = n < close_at ? n : close_at;
        uint32_t expected = consumed ? cases[consumed - 1].count : 0;
        bool modal = consumed ? cases[consumed - 1].modal : false;
        assert(run_counter_generated(inputs, n, &result) == expected);
        assert(result.consumed == consumed);
        assert(result.frames == consumed + (n < close_at ? 1u : 0u));
        check_frame(&result, expected, modal);
    }
    Observation empty = {0};
    assert(run_counter_generated(NULL, 0, &empty) == 0);
    check_frame(&empty, 0, false);
    assert(known_counter() == 0);
    assert(counter_limit(999997) == 999999);
    assert(counter_limit(999998) == 999999);
    assert(counter_limit(999999) == 999999);
    assert(counter_reset_limit());
    puts("UI counter: 24 independent replays, geometry/colors, modal routing, bounds, quit and limit checks passed");
    return 0;
}
