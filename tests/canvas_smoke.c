/* Real SDL3, no display required: SDL_VIDEODRIVER=dummy. */
#include <SDL3/SDL.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
uint32_t exercise(int32_t mode);
static int frames;
void canvas_test_frame(int32_t width, int32_t height, float x) {
    assert(width == 640 && height == 480 && x == 100); ++frames;
}
void canvas_test_key(uint32_t code, bool pressed, bool repeated) {
    (void)code; (void)pressed; (void)repeated;
    assert(!"unexpected keyboard input on the dummy driver");
}
void canvas_test_error(uint32_t operation, uint8_t *message, uint32_t length, bool truncated) {
    fprintf(stderr, "SDL operation %u failed: %.*s%s\n", operation, (int)length, message, truncated ? "..." : "");
}
int main(void) {
    assert(SDL_Init(SDL_INIT_EVENTS));
    assert(exercise(3) == 0 && frames == 1);
    assert(SDL_WasInit(SDL_INIT_VIDEO) == 0);
    assert(SDL_WasInit(SDL_INIT_EVENTS) == SDL_INIT_EVENTS);
    SDL_QuitSubSystem(SDL_INIT_EVENTS);
    puts("canvas: real SDL3 dummy-driver frame and teardown passed");
    return 0;
}
