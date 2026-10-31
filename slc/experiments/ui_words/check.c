/* Typed, already-routed events: this checks composition, not a UI router. */
#ifdef UI_WORDS_JIT
#include "probe-api.h"
#else
#include "probe.c"
#endif
#include <assert.h>
#include <stdio.h>
#include <string.h>

static unsigned checks;
static void paint_is_inert(App *app) {
    unsigned char before[sizeof *app];
    memcpy(before, app, sizeof *app);
    for (unsigned i = 0; i < 4; ++i) {
        Stats s = probe_paint(app);
        assert(s.actions == 0 && s.submitted == 0);
        assert(memcmp(before, app, sizeof *app) == 0);
        if (app->done) assert(s.buttons == 0 && s.labels == 0);
    }
    ++checks;
}
static Stats send(App *app, uint32_t kind, uint32_t target, uint32_t ticket) {
    Stats result = probe_input(app, (Input){ kind, target, ticket });
    assert(result.buttons == 0 && result.labels == 0);
    paint_is_inert(app);
    return result;
}
static void verify(unsigned condition) { assert(condition); ++checks; }

int main(void) {
    App a = probe_init(100, 73), b = probe_init(200, 91);
    verify(known_counter() == 1);
    paint_is_inert(&a); paint_is_inert(&b);
    Stats s = probe_paint(&a);
    verify(s.buttons == 2 && s.labels == 1);

    /* Homes persist; the press can span any number of presentation passes. */
    verify(send(&a, 1, 106, 0).actions == 0 && a.counter.plus.armed);
    verify(send(&b, 2, 206, 0).actions == 0 && b.counter.value == 0);
    verify(send(&a, 2, 106, 0).actions == 1 && a.counter.value == 1 && a.observed == 1);
    verify(send(&a, 2, 106, 0).actions == 0 && a.counter.value == 1);
    send(&a, 1, 106, 0); send(&a, 3, 106, 0);
    verify(send(&a, 2, 106, 0).actions == 0 && !a.counter.plus.armed);
    s = probe_revisit(&a, (Input){ 4, 106, 0 });
    verify(s.actions == 1 && a.counter.value == 2 && a.observed == 2);
    paint_is_inert(&a);
    verify(b.counter.value == 0 && b.editor.document == 91);

    /* One targeted event cannot enter and accept a newly displayed dialog. */
    s = send(&a, 4, 101, 0);
    verify(s.actions == 1 && s.submitted == 0 && a.editor.mode.tag == Mode_confirming);
    s = probe_paint(&a);
    verify(s.buttons == 3 && s.labels == 1);
    verify(send(&a, 4, 103, 0).actions == 1 && a.editor.mode.tag == Mode_editing);
    verify(a.editor.document == 73 && a.editor.serial == 0);

    send(&a, 4, 101, 0);
    s = send(&a, 4, 102, 0);
    verify(s.actions == 1 && s.submitted == 1 && s.snapshot == 73);
    verify(a.editor.mode.tag == Mode_saving && a.editor.mode.as.saving == 1);
    verify(send(&a, 4, 102, 0).submitted == 0 && a.editor.serial == 1);
    verify(send(&a, 5, 200, 1).actions == 0 && a.editor.mode.tag == Mode_saving);
    verify(send(&a, 5, 100, 99).actions == 0 && a.editor.mode.tag == Mode_saving);
    verify(send(&a, 6, 100, 1).actions == 1 && a.editor.mode.tag == Mode_failed);
    verify(a.editor.document == 73 && !a.done);

    /* Retrying has a fresh continuation ticket, not an old captured callback. */
    s = send(&a, 4, 104, 0);
    verify(s.submitted == 1 && s.snapshot == 73 && a.editor.mode.as.saving == 2);
    verify(send(&a, 5, 100, 1).actions == 0 && !a.done);
    verify(send(&a, 5, 100, 2).actions == 1 && a.done && a.finished == 1);
    verify(send(&a, 5, 100, 2).actions == 0 && a.finished == 1);
    verify(send(&a, 4, 106, 0).actions == 0 && a.counter.value == 2);
    verify(a.editor.document == 73);

    /* The same component in another home is still independently usable. */
    send(&b, 4, 201, 0); send(&b, 4, 202, 0); send(&b, 6, 200, 1);
    verify(b.editor.mode.tag == Mode_failed && !b.done);
    verify(send(&b, 4, 205, 0).actions == 1 && b.editor.mode.tag == Mode_editing);
    verify(b.editor.document == 91 && b.finished == 0);
    printf("ordinary-word UI probe: %u assertions/presentation checks passed\n", checks);
    return 0;
}
