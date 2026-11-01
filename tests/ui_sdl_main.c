#include <SDL3/SDL.h>
#include <SDL3_ttf/SDL_ttf.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
extern uint32_t smoke(const char *);
static unsigned frames;
static char counts[8];
static bool dialogs[8];
SDL_Surface *__real_TTF_RenderText_Blended(TTF_Font *, const char *, size_t, SDL_Color);
SDL_Surface *__wrap_TTF_RenderText_Blended(TTF_Font *font, const char *text, size_t length, SDL_Color color) {
    assert(frames < 8);
    if (length == 1 && text[0] >= '0' && text[0] <= '9') counts[frames] = text[0];
    if (length == strlen("Reset the counter?") && memcmp(text, "Reset the counter?", length) == 0) dialogs[frames] = true;
    return __real_TTF_RenderText_Blended(font, text, length, color);
}
static void click(SDL_WindowID window, float x, float y) {
    SDL_Event event = {0};
    event.button.type = SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.windowID = window;
    event.button.button = SDL_BUTTON_LEFT;
    event.button.down = true;
    event.button.x = x;
    event.button.y = y;
    assert(SDL_PushEvent(&event));
    event.button.type = SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.down = false;
    assert(SDL_PushEvent(&event));
}
bool __real_SDL_RenderPresent(SDL_Renderer *);
bool __wrap_SDL_RenderPresent(SDL_Renderer *renderer) {
    bool ok = __real_SDL_RenderPresent(renderer);
    SDL_WindowID window = SDL_GetWindowID(SDL_GetRenderWindow(renderer));
    ++frames;
    if (frames == 1) click(window, 24, 76);
    else if (frames == 2 || frames == 4) click(window, 160, 76);
    else if (frames == 3) click(window, 296, 220);
    else if (frames == 5) click(window, 176, 220);
    else if (frames == 6) {
        SDL_Event event = {0};
        event.type = SDL_EVENT_QUIT;
        assert(SDL_PushEvent(&event));
    }
    return ok;
}
int main(int argc, char **argv) {
    assert(argc == 2);
    assert(smoke(argv[1]) == 0);
    assert(frames == 6);
    assert(TTF_WasInit() == 0);
    assert(SDL_WasInit(SDL_INIT_VIDEO) == 0);
    assert(smoke("/this-font-must-not-exist.ttf") == 21);
    assert(frames == 6);
    assert(TTF_WasInit() == 0);
    assert(SDL_WasInit(SDL_INIT_VIDEO) == 0);
    assert(memcmp(counts, "011110", 6) == 0);
    assert(!dialogs[0] && !dialogs[1] && dialogs[2] && !dialogs[3] && dialogs[4] && !dialogs[5]);
    puts("SDL UI: real font, six frames, increment/keep/reset/quit, font failure and cleanup passed");
    return 0;
}
