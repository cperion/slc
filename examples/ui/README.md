# Component counter on SDL3

[The counter](counter.slc) uses the actual [UI library](../../lib/ui.slc): instruction
blocks construct native component records; application methods handle generated
sums. Layout and routing are ordinary SLC words. SDL3 and SDL_ttf provide the window,
input, font measurements and rendering. No C UI algorithm or replacement font is used.

## Build and run

From the repository root:

```sh
make test-ui
./build/ui/demo '/path/to/font.ttf'
```

The font path is required. For example, `fc-match -f '%{file}\n' sans` prints a local
font path; pass the selected path explicitly. Tests use `SLC_UI_FONT` when supplied,
otherwise report the font selected with `fc-match`. The library itself does not
search for a substitute font.

Click Increase, open Reset, then choose Reset or Keep value. Closing the window
routes `close_requested` to the root handler. The host uses the existing SDL
resource activities and does not change the canvas API.

Manual build:

```sh
export LUA_CPATH="$(luarocks --lua-version=5.1 path --lr-cpath);;"
mkdir -p build/ui
luajit slc.lua examples/ui/main.slc -o build/ui/main.c
cc -std=c99 -O1 -Wall -Wextra -Werror -pedantic -Iruntime \
  build/ui/main.c examples/ui/entry.c runtime/slc_rt.c \
  $(pkg-config --cflags --libs sdl3 sdl3-ttf) -lm -lpthread -o build/ui/demo
```

## Evidence and scope

- [Builder checks](../../tests/ui.lua) compile the real instruction surface, native
  fields, component methods, generated outcomes, themes, sharing, lexical fallback,
  variants and rejection cases.
- [Replay](../ui_counter.slc) with [native assertions](../../tests/ui_counter_main.c)
  checks 17 input prefixes: layout geometry, exclusive bounds, press/release,
  modal blocking, keep/reset outcomes and stopping on quit. `fixed_increment_y`
  compiles to the literal `76.0f`; this is a constant-layout check, not a claim that
  every field remains constant across the full runtime loop.
- [Real SDL acceptance](../../tests/ui_sdl.lua) runs with the dummy video driver.
  Its [fixture](../../tests/ui_sdl_main.c) queues real pointer events, observes
  the strings passed to real SDL_ttf rendering, and checks six presented frames,
  increment/keep/reset/quit, a missing-font failure, and balanced cleanup.

The current counter gives controls explicit dimensions. Rendering currently covers
rectangular backgrounds, colour/opacity variants and text at an explicit font size.
The broader instruction vocabulary does **not** yet mean complete Tailwind layout
or rendering. Full grid/flex placement, clipping, rounded corners, borders, shadows,
rings, keyboard focus and editable controls remain unfinished; see
[the style implementation boundary](../../docs/ui-style.md#implementation-boundary).
`ui.run(App, config)` currently returns the SDL resource result (`done` or `failed`).
Normal close is decided by the root's `ui.Reply`, not by a canvas-style immediate stop.
