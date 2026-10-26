# slc — staged Lua → C

Lua for program construction; typed native words, online partial evaluation and
Goose-style memory for the work that remains. Emit readable C or compile the same
prepared residual program in process with libgccjit.

```lua
local affine = do(a: U32, b: U32, x: U32): U32 = a * x + b
local transform = affine(4, 3)
assert(host(affine(4, 3, 10)) == 43)
local entry = do(x: U32): U32 = transform x * 2
export entry
```

```c
uint32_t entry(uint32_t x) {
    return (4u * x + 3u) * 2u;
}
```

Start with [Designing and writing SLC](docs/designing-and-writing-slc.md).
[The specification](docs/staged-lua-c-v0.5.md) owns the language and ABI rules.

## Requirements

- LuaJIT and LPeg built for **Lua 5.1**, not another Lua ABI.
- A C99 compiler and POSIX threads for the native runtime/harnesses.
- libgccjit **13+**, on a 64-bit target, for JIT/native loading (optional for C output).
- GNU make and `timeout` for the convenience/check targets. Some packaged checks
  additionally use Clang/ThreadSanitizer or optional platform I/O facilities.

If LPeg is not installed for LuaJIT:

```sh
luarocks --lua-version=5.1 install lpeg
```

`make` discovers LuaRocks' Lua 5.1 C path. For direct LuaJIT commands, use
`luarocks --lua-version=5.1 path` or set `LUA_CPATH` yourself, retaining `;;` for
LuaJIT's defaults. An LPeg module built for Lua 5.4 is not interchangeable.

```sh
make doctor
make test
make test-native                 # requires libgccjit; not an optional skip
make run PROGRAM=examples/csv.slc ARGS='examples/data/sales.csv price'
```

The development targets default to two task workers; override with `SLC_WORKERS=N`.
Generated files, logs and caches go under ignored `build/`. A local libgccjit copy
may be placed at `.local/lib/libgccjit.so.0`; Make selects it if `SLC_GCCJIT` is unset.
Otherwise install the platform's libgccjit package or set `SLC_GCCJIT` explicitly.
No compiler binary or machine-specific dependency is committed.

## Compiler and library

```sh
luajit slc.lua program.slc                      # print C
luajit slc.lua -o build/out.c program.slc        # write C (-H build/out.h for declarations)
luajit slc.lua -d program.slc                   # print staged Lua
luajit slc.lua -o build/out.c --cc program.slc   # also check strict C
luajit slc.lua --gccjit -o build/out.o program.slc
luajit slc.lua run program.slc args             # execute now, with an optional main export
```

From Lua, `require 'slc'` and call `slc.load(path)` to obtain exports, raw pointers
and FFI record types. A program can call `native(word)` to specialize on values
available at startup. See specification §38 for error recovery, code lifetime and
foreign-library requirements. Direct invocations must have their dependencies on
the loader paths; Make's environment is not a system-wide installation.

Programs needing data stacks link `runtime/slc_rt.c`. Tasks also need
`runtime/slc_tasks.c`, `runtime/slc_io_posix.c`, one I/O backend and `-pthread`.
See the specification for io_uring/kqueue support and validation limits.

## Source layout

| Part | Source |
|---|---|
| Driver / embedding entry | `slc.lua` |
| LuaMacro engine | `macro.lua`, `macro/`, `macro/lib/` |
| SLC application and typed-body hand-off | `macro/let.lua`, `macro/slc.lua` |
| Standalone source macro CLI | `luam` (`luajit luam -lmacro.let program.lua`) |
| Native types and exact folding | `slc/types.lua`, `slc/fold.lua` |
| Specialization, state, words and control | `slc/stage.lua`, `slc/syntax.lua` |
| Goose storage | `slc/memory.lua` |
| C / libgccjit backends | `slc/cgen.lua`, `slc/jitgen.lua` |
| Shared C rules / compiler-owned C reader | `slc/cjit.lua`, `slc/gccjit_h.lua` |
| Header probes / in-process execution | `slc/probe.lua`, `slc/native.lua` |
| Runtime / imported libraries | `runtime/`, `lib/` |
| Examples, fixtures and checks | `examples/`, `tests/` |

The macro layer is project source, **not a runtime bundle**. See
[its integration notes](docs/luamacro/INTEGRATION.md) and
[third-party attribution](THIRD_PARTY.md). No new project-wide license is assigned
by this repository bootstrap.
