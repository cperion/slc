/* Deterministic SDL boundary, compiled against the real SDL3 declarations.
 * No application behavior is implemented here: only outcomes and observations.
 */
#include <SDL3/SDL.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

uint32_t exercise(int32_t mode);
static int fail_at, event_mode, polls, frames, keys, presents, colors, clears, fills, lines, delays;
static int cycle, cursor, report_count, message_length;
static char trace[128], diagnostic[800];
static size_t trace_length;
static int window_token, renderer_token;
#define WINDOW ((SDL_Window *)&window_token)
#define RENDERER ((SDL_Renderer *)&renderer_token)
static void note(char c) { assert(trace_length + 1 < sizeof trace); trace[trace_length++] = c; trace[trace_length] = 0; }
static bool outcome(int operation) { return fail_at != operation; }
static void reset(int failure, int events, int length) {
    fail_at = failure; event_mode = events; message_length = length;
    polls = frames = keys = presents = colors = clears = fills = lines = delays = 0;
    cycle = cursor = report_count = 0; trace_length = 0; trace[0] = 0;
    memset(diagnostic, 'F', (size_t)length); diagnostic[length] = 0;
}
bool SDL_Init(SDL_InitFlags flags) { assert(flags == SDL_INIT_VIDEO); note('I'); return outcome(1); }
void SDL_QuitSubSystem(SDL_InitFlags flags) { assert(flags == SDL_INIT_VIDEO); note('q'); strcpy(diagnostic, "cleanup changed the error"); }
SDL_Window *SDL_CreateWindow(const char *title, int w, int h, SDL_WindowFlags flags) {
    assert(!strcmp(title, "canvas test") && w == 640 && h == 480 && flags == SDL_WINDOW_RESIZABLE);
    note('W'); return outcome(2) ? WINDOW : NULL;
}
void SDL_DestroyWindow(SDL_Window *w) { assert(w == WINDOW); note('w'); strcpy(diagnostic, "window cleanup"); }
SDL_Renderer *SDL_CreateRenderer(SDL_Window *w, const char *name) {
    assert(w == WINDOW && name == NULL); note('R'); return outcome(3) ? RENDERER : NULL;
}
void SDL_DestroyRenderer(SDL_Renderer *r) { assert(r == RENDERER); note('r'); strcpy(diagnostic, "renderer cleanup"); }
SDL_WindowID SDL_GetWindowID(SDL_Window *w) { assert(w == WINDOW); return 42; }
const char *SDL_GetError(void) { return diagnostic; }
bool SDL_GetRenderOutputSize(SDL_Renderer *r, int *w, int *h) {
    assert(r == RENDERER); *w = cycle == 1 ? 640 : 800; *h = cycle == 1 ? 480 : 600;
    return outcome(4);
}
bool SDL_SetRenderDrawColor(SDL_Renderer *r, Uint8 red, Uint8 green, Uint8 blue, Uint8 alpha) {
    assert(r == RENDERER && alpha == 255); (void)red; (void)green; (void)blue;
    ++colors; return outcome(5);
}
bool SDL_RenderClear(SDL_Renderer *r) { assert(r == RENDERER); ++clears; return outcome(6); }
bool SDL_RenderFillRect(SDL_Renderer *r, const SDL_FRect *rect) {
    assert(r == RENDERER && rect->x == 110 && rect->y == 20 && rect->w == 80 && rect->h == 60);
    ++fills; return outcome(7);
}
bool SDL_RenderLine(SDL_Renderer *r, float x1, float y1, float x2, float y2) {
    assert(r == RENDERER && x1 == 0 && y1 == 0 && x2 == 20 && y2 == 20);
    ++lines; return outcome(8);
}
bool SDL_RenderPresent(SDL_Renderer *r) { assert(r == RENDERER); ++presents; return outcome(9); }
void SDL_Delay(Uint32 ms) { assert(ms == 0); ++delays; }
static void key(SDL_Event *e, SDL_WindowID id, SDL_Keycode code, bool down, bool repeat) {
    e->type = down ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
    e->key.windowID = id; e->key.key = code; e->key.down = down; e->key.repeat = repeat;
}
bool SDL_PollEvent(SDL_Event *e) {
    assert(++polls < 30); memset(e, 0, sizeof *e);
    if (event_mode == 1) { key(e, 42, SDLK_ESCAPE, true, false); return true; }
    if (event_mode == 2) { e->type = SDL_EVENT_WINDOW_CLOSE_REQUESTED; e->window.windowID = 42; return true; }
    if (event_mode == 3) { e->type = SDL_EVENT_QUIT; return true; }
    if (cycle == 0) {
        switch (cursor++) {
        case 0: key(e, 99, SDLK_RIGHT, true, false); return true;
        case 1: e->type = SDL_EVENT_WINDOW_CLOSE_REQUESTED; e->window.windowID = 99; return true;
        case 2: key(e, 42, SDLK_RIGHT, true, true); return true;
        case 3: key(e, 42, SDLK_RIGHT, false, false); return true;
        default: ++cycle; cursor = 0; return false;
        }
    }
    if (cycle == 1) {
        if (cursor++ == 0) { e->type = SDL_EVENT_WINDOW_RESIZED; e->window.windowID = 42; return true; }
        ++cycle; return false;
    }
    e->type = SDL_EVENT_QUIT; return true;
}
void canvas_test_key(uint32_t code, bool pressed, bool repeated) {
    ++keys;
    if (event_mode == 1) { assert(code == SDLK_ESCAPE && pressed && !repeated); return; }
    assert(code == SDLK_RIGHT);
    assert((keys == 1 && pressed && repeated) || (keys == 2 && !pressed && !repeated));
}
void canvas_test_frame(int32_t width, int32_t height, float x) {
    ++frames; assert(x == 110);
    assert(width == (frames == 1 ? 640 : 800));
    assert(height == (frames == 1 ? 480 : 600));
}
void canvas_test_error(uint32_t operation, uint8_t *message, uint32_t length, bool truncated) {
    ++report_count; assert(operation == (uint32_t)fail_at);
    assert(length == (uint32_t)(message_length > 512 ? 512 : message_length));
    assert(truncated == (message_length > 512));
    for (uint32_t i = 0; i < length; ++i) assert(message[i] == 'F');
    /* This is called after resources were destroyed; diagnostics must be owned. */
    if (fail_at > 1) assert(strcmp(diagnostic, "cleanup changed the error") == 0);
}
int main(void) {
    reset(0, 0, 7); assert(exercise(0) == 0);
    assert(!strcmp(trace, "IWRrwq") && frames == 2 && keys == 2 && presents == 2 && delays == 2);
    reset(0, 0, 7); assert(exercise(1) == 0);
    assert(!strcmp(trace, "IWRrwq") && polls == 0 && presents == 0);
    reset(0, 0, 7); assert(exercise(2) == 0);
    assert(!strcmp(trace, "IWRrwq") && polls == 0 && clears == 1 && presents == 1);
    reset(0, 0, 7); assert(exercise(3) == 0);
    assert(frames == 1 && presents == 1 && delays == 0 && polls == 5);
    reset(6, 0, 7); assert(exercise(4) == 6 && report_count == 1);
    assert(clears == 1 && colors == 1 && presents == 0 && !strcmp(trace, "IWRrwq"));
    reset(0, 0, 7); assert(exercise(5) == 0);
    assert(clears == 0 && polls == 0 && presents == 0 && !strcmp(trace, "IWRrwq"));
    for (int events = 1; events <= 3; ++events) {
        reset(0, events, 7); assert(exercise(0) == 0);
        assert(polls == 1 && frames == 0 && presents == 0 && keys == (events == 1));
        assert(!strcmp(trace, "IWRrwq"));
    }
    for (int failure = 1; failure <= 9; ++failure) {
        reset(failure, 0, 7); assert(exercise(0) == (uint32_t)failure && report_count == 1);
        const char *expected = failure == 1 ? "I" : failure == 2 ? "IWq" : failure == 3 ? "IWRwq" : "IWRrwq";
        assert(!strcmp(trace, expected));
        assert(presents == (failure == 9));
        if (failure == 4) assert(frames == 0 && colors == 0);
        if (failure == 5) assert(colors == 1 && clears == 0 && fills == 0 && lines == 0);
        if (failure == 6) assert(colors == 1 && clears == 1 && fills == 0 && lines == 0);
        if (failure == 7) assert(colors == 2 && fills == 1 && lines == 0);
        if (failure == 8) assert(colors == 3 && lines == 1);
    }
    for (int length = 0; length <= 700; ++length) {
        if (length != 0 && length != 512 && length != 700) continue;
        reset(7, 0, length); assert(exercise(0) == 7 && report_count == 1);
    }
    puts("canvas: lifecycle, events, resize, stop, first failure and owned diagnostics passed");
    return 0;
}
