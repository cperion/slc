# SDL3 as an SLC canvas activity

[The client](main.slc) moves an orange rectangle with the arrow keys. Escape or
window close ends the activity. Resizing changes the white diagonal: each frame
receives the current renderer output dimensions, in pixels.

This is a small activity language, not a complete SDL binding. The application
says `interact`, `clear`, `fill_rect` and `line`; ordinary SLC words supply the
resource scopes, event loop, failure handling and diagnostic copying.

## Build and run

From the repository root, with SDL3 development headers/libraries and the normal
SLC dependencies installed:

```sh
make doctor
make test-canvas
./build/canvas/demo
```

The test target builds the demo, but never opens an interactive window. Its real
SDL checks run with `SDL_VIDEODRIVER=dummy`; the demo runs with your normal driver.
SDL3 is optional for the rest of SLC. The target reports a skip if its development
package is absent; compilation or execution failures with SDL present are errors.

To build the C version explicitly:

```sh
export LUA_CPATH="$(luarocks --lua-version=5.1 path --lr-cpath);;"
export SLC_CACHE="$PWD/build/cache"
mkdir -p build/canvas
luajit slc.lua -o build/canvas/main.c examples/canvas/main.slc
cc -std=c99 -O2 -Wall -Wextra -Werror -pedantic -I runtime \
  build/canvas/main.c examples/canvas/entry.c runtime/slc_rt.c \
  $(pkg-config --cflags --libs sdl3) -o build/canvas/demo
./build/canvas/demo
```

[The C entry point](entry.c) only calls the generated export. It contains no
library behavior. No SDL-specific compiler changes or production C shim are used.

## Vocabulary and contracts

[The SDL layer](../../lib/sdl.slc) declares the subset of the ABI used here and
provides `with_video`, `with_window config`, and `with_renderer window`.
Their bodies return `Result`, a sum with `done: Unit` and `failed: Failure`.
Resources are released after the body returns, in reverse acquisition order.
Initialization failure releases only resources already acquired. Traps and
process termination are outside this normal-completion guarantee.

[The canvas layer](../../lib/canvas.slc) adds:

| Activity or word | Contract |
|---|---|
| `open config do(view..) ... end` | Own one window and renderer under a video-subsystem reference. Body returns `Result`. |
| `interact { key = ..., draw = ... }` | Drain input, draw a frame, delay, repeat until stopped or failed. `draw` is required; `key` is optional. |
| `stop()` | Latch stop. The current handler finishes; no further event is polled or frame started. A frame already underway completes and presents if successful. |
| `frame do(drawing..) ... end` | Draw and present once; body returns Unit, activity returns `Result`. Available independently of `interact`. |
| `with_frame renderer body` | The same frame activity over a renderer borrowed from the lower-level SDL layer. |
| `clear color` | Set the drawing color, then clear the complete backbuffer. |
| `fill_rect x y width height color` | Fill an output-pixel rectangle with floating-point coordinates. |
| `line x1 y1 x2 y2 color` | Draw an output-pixel line. |
| Frame `width`, `height` | Query output-pixel dimensions before each frame, not cached startup dimensions. |

`Color.black`, `Color.orange`, and `Color.white` are supplied. `RGBA { r = ...,
g = ..., b = ..., a = ... }` constructs another color. Channels are U8 values.
This first version uses SDL's default, non-blended drawing mode; alpha does not
promise transparency. There are no textures, sprites, render targets or logical
coordinate transforms yet.

Configuration is a known Lua table: `title`, `width`, and `height` are required;
`resizable` defaults to false and `frame_delay_ms` to 16. Set the delay to 0 to
request no additional delay. This is simple pacing, not vsync or a fixed-step
simulation clock. SDL chooses its default renderer; the library adds no renderer
fallback or retry policy.

Key handlers receive `code`, `pressed`, and `repeated`. `Key` supplies arrows and
Escape as SDL keycodes. Key-up and repeat are preserved. Events from another
window are ignored; other event kinds are not exposed in this first vocabulary.
A global quit event or this window's close request stops normally. Returning
from a key handler does **not** stop interaction. Returning from a frame body
still presents that frame if no drawing operation failed.

## Failures

A frame records its first failed operation. Later drawing words do not call SDL,
and a failed frame is not presented. Output-size failure prevents the body from
running; presentation failure is reported too. A failed frame stops interaction,
and `open` propagates it even if its body discards the frame's result.

`Failure` contains:

- `operation`: an entry in `Operation` (`init`, `window`, `renderer`, `size`,
  `color`, `clear`, `fill_rect`, `line`, or `present`).
- `message`: an owned `Chars(512)` diagnostic captured immediately, before any
  cleanup can change SDL's error text. Its length is explicit; it is not a C string.
- `truncated`: true when the original diagnostic exceeded 512 bytes. Truncation
  is by byte and can split a UTF-8 sequence.

The result is data the caller can inspect after all resources have been released.
The example prints it and returns a nonzero exit status.

## Ownership and binding time

Call these activities on SDL's main thread, never a scheduler worker. Keep one
active canvas/event-loop owner; `interact` consumes the process-wide SDL event
queue and is not a multiwindow dispatcher. The video activity balances its own
`SDL_Init(SDL_INIT_VIDEO)` with `SDL_QuitSubSystem`, not global `SDL_Quit`, so it
does not force teardown of independently owned subsystems.

Drawing/view contexts and handles are borrowed only for their activity. Do not
store them, mutate their implementation fields, or use a renderer after its scope
ends. This library does not claim static prevention of all raw-pointer/context
escapes, nested interaction or reentrant frame use.

Configuration and the handler table are known during specialization. Mutable
application state, events, dimensions, handles and SDL results remain runtime
values. There is no runtime handler-table lookup or DSL interpreter. SDL effects
are never executed while specializing.

The event union is a non-overlapping `cstruct` view through its keyboard member;
its type/timestamp and window ID use the common initial sequence shared by the
relevant SDL event structs. Key-specific fields are read only after testing the
event type. Size and offsets come from the installed SDL headers, not copied
numeric ABI constants. The timestamp field retains the event's 64-bit alignment
on the verified platform (Linux x86-64, SDL 3.4.16).

## Evidence

[The acceptance program](../../tests/canvas.slc) is compiled once against a
[deterministic SDL boundary](../../tests/canvas_main.c), and once against
[real SDL](../../tests/canvas_smoke.c). The test boundary uses the actual SDL3
headers; it contains no canvas algorithms.

`make test-canvas` checks:

- Reverse-order, exactly-once cleanup and partial initialization failures.
- Early body return, explicit stop, and no polling/drawing after stop.
- Window filtering, key-up/repeat preservation and input-driven state changes.
- Resized dimensions on the next frame.
- Every fallible operation, first-error latching, and skipped presentation.
- Owned diagnostics after cleanup, including empty, exact-capacity and truncated text.
- Real dummy-driver drawing and balanced subsystem references.
- C and available libgccjit code, plus Clang ASan/UBSan when Clang is installed.
- Generated C containing SDL calls without residual activity-wrapper functions.

The same checks are included in `make test` when SDL3 is installed. Dummy-driver
coverage is not a visual or hardware-accelerated rendering test.
