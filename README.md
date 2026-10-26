# slc — staged Lua → C

A prototype of the language in `docs/staged-lua-c-v0.5.md`: Lua at compile time,
typed native words specialized by online partial evaluation, Goose-style memory,
C out.

```lua
local affine = do(a: U32, b: U32, x: U32): U32 = a * x + b
local transform = affine(4, 3)          -- a word with a = 4, b = 3 bound
assert(host(affine(4, 3, 10)) == 43)    -- fully known: computed at compile time
local entry = do(x: U32): U32 = transform x * 2
export entry
```

```c
uint32_t entry(uint32_t x) {
    return (4u * x + 3u) * 2u;
}
```

## Use

Requires LuaJIT, LPeg (`lua-lpeg`) and a C99 compiler; the gccjit backend also needs libgccjit (13 or later).

```sh
luajit slc.lua program.slc            # print C
luajit slc.lua -o out.c program.slc   # write C (-H out.h for a header)
luajit slc.lua -d program.slc         # print the Lua the program becomes
luajit slc.lua --cc program.slc       # also check the C with -Wall -Wextra -Werror
luajit slc.lua --gccjit -o out.o p.slc  # compile with libgccjit instead of printing C
luajit slc.lua run program.slc args   # run it now: compiled into this process by libgccjit
luajit tests/run.lua                  # every example: compile, strict C, run harness; bad programs
```

Programs that use `Store`, `Grow` or `Id` include `runtime/slc_rt.h`; link
`runtime/slc_rt.c`.

## Layout

| | |
|---|---|
| `slc.lua` | driver |
| `slc/types.lua` | native types |
| `slc/fold.lua` | compile-time evaluation with exact C semantics |
| `slc/stage.lua` | values, places and lazy stores, branches, loops, words, materialization |
| `slc/memory.lua` | stores, IDs, Grow arrays, data-stack indices |
| `slc/syntax.lua` | typed-body parser and translation to staged Lua |
| `slc/cgen.lua` | residual IR to C |
| `slc/jitgen.lua` | residual IR to libgccjit, mirroring cgen |
| `slc/cjit.lua` | C's rules over libgccjit, and a reader for the C the compiler contains |
| `slc/probe.lua` | header constants, foreign layouts and variables for the gccjit backend |
| `slc/native.lua` | run it now: runtime library, `native(word)`, `slc.load` |
| `macro/let.lua` | macro.let, extended: name application, typed-lambda hand-off |
| `macro/slc.lua` | `struct`, `export`, typed `function` |
| `luam.lua` | LuaMacro 2.5 (bundled, unchanged) |
| `runtime/` | data stacks, traps, store tokens, slice checks |
| `lib/` | libraries for `import`: `libc.slc` wraps libc, `posix.slc` the Linux descriptor interface, as activities |
| `examples/` | every program from the spec, plus stress cases; `activities.slc` for §30, `sums.slc` for §31, `memory_views.slc` for §32, `libc_demo.slc` for §33, `posix_demo.slc` for §34, `atomics.slc` for §35 |
| `tests/` | C harnesses, rejected programs, the runner |
