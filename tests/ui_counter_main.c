#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

typedef struct { uint32_t kind; float x, y; } Input;
typedef struct {
    uint32_t count, consumed;
    bool modal, quit;
    float increment_x, increment_y, reset_x, reset_y;
} Observation;
extern void replay_counter(Input *, uint32_t, Observation *);
extern float fixed_increment_y(void);

int main(void) {
    Input inputs[] = {
        {0, 24, 76}, {0, 151, 115}, {0, 152, 76},
        {3, 24, 76}, {4, 24, 76},
        {3, 24, 76}, {4, 0, 0},
        {0, 160, 76}, {0, 24, 76}, {0, 0, 0},
        {0, 296, 220}, /* keep */
        {0, 160, 76}, {0, 176, 220}, /* reset */
        {0, 24, 76}, {1, 0, 0}, {0, 24, 76},
    };
    const uint32_t counts[] = {1,2,2,2,3,3,3,3,3,3,3,3,0,1,1,1};
    const bool modals[] = {false,false,false,false,false,false,false,true,true,true,false,true,false,false,false,false};
    assert(fixed_increment_y() == 76.0f);
    for (uint32_t n = 0; n <= sizeof(inputs) / sizeof(inputs[0]); ++n) {
        Observation o = {0};
        replay_counter(inputs, n, &o);
        assert(o.increment_x == 24 && o.increment_y == 76);
        assert(o.reset_x == 176 && o.reset_y == 220);
        assert(o.count == (n ? counts[n - 1] : 0));
        assert(o.modal == (n ? modals[n - 1] : false));
        assert(o.quit == (n >= 15));
        assert(o.consumed == (n < 15 ? n : 15));
    }
    puts("UI component counter: 17 replays, constant layout, pointer release, modal outcomes and close passed");
    return 0;
}
