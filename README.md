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
[Maps and immutable lookup descriptions](docs/staged-lua-c-v0.5.md#40-maps-and-known-lookup-descriptions)
are implemented in ordinary SLC. [The alpha roadmap](docs/alpha-design.md) covers
broader fuzzing and the single-binary distribution; [the SLC-first inventory](docs/slc-first.md)
tracks the remaining library migrations.

## Requirements

- LuaJIT and LPeg built for **Lua 5.1**, not another Lua ABI. `make dist` also
  needs the LuaJIT development files (`lua.h`) and `libluajit-5.1`.
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

## Formatting

```sh
luajit slc.lua fmt program.slc          # stdout; does not modify the source
luajit slc.lua fmt --write program.slc  # explicitly update files
luajit slc.lua fmt --check examples/*.slc
```

Defaults favor four-space indentation, a soft 100-column width, safe
parenthesis-free calls and flat endall spines. A `.slcfmt.lua` can set
`indent_width`, `column_width`, `call_style` (`"minimal"` or `"preserve"`) and
`spine_style` (`"pure"`, `"all"` or `"none"`). See
[formatting](docs/formatting.md) for semantics, configuration discovery and exit
codes. `make test-format` checks style, idempotence, source preservation and
compiler-output equivalence.

## Modules

```lua
local hash = require "slc.hash" -- bundled SLC vocabulary
local ffi = require "ffi"      -- ordinary Lua module
local model = require "model"  -- project Lua or SLC module
```

This is Lua's actual `require`, extended with an SLC source searcher. Bundled
names use `slc.*`, so Lua's `require "io"` still means Lua I/O. Newly loaded
modules are cached per compilation, including Lua wrappers around staged
values; host loader state is restored afterwards. See [module loading](docs/modules.md).
Run `make test-modules` for the loader/cache contract checks.

## Neovim syntax highlighting

SLC has a dedicated Tree-sitter grammar and highlight queries. Build the local
parser with `make tree-sitter`, then follow the
[Neovim setup instructions](tools/tree-sitter-slc/README.md).
`make test-tree-sitter` checks the parser and highlighting in headless Neovim.
No changes to the compiler or your existing Lua filetype are required.

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

## Fixed-size values at compile time

Known arrays and `Chars(n)` can remain immutable compiler data until they need
storage. Known-index updates and text reads can fold; dynamic operations and raw
address escape materialize conservatively. Value copies are snapshots, while
`:str()`/`:slice()` views retain their owner and observe later changes (with the
view's original length).

See the [staged-values example](examples/staged_values.slc) and
[the text contract](docs/staged-lua-c-v0.5.md#393-charsn). Its harnesses compare known,
split, C and in-process execution, including copies, live views and task captures.
This adds neither a compile-time heap nor a new borrowing policy.

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
| Immutable fixed-array contents | `slc/array_value.lua` |
| Text types and library | `slc/strings.lua`, `lib/str.slc` |
| Differential fuzzing | `tests/fuzz/gen.lua`, `tests/fuzz/fuzz.lua` |
| C / libgccjit backends | `slc/cgen.lua`, `slc/jitgen.lua` |
| Shared C rules / compiler-owned C reader | `slc/cjit.lua`, `slc/gccjit_h.lua` |
| Header probes / in-process execution | `slc/probe.lua`, `slc/native.lua` |
| Runtime / imported libraries | `runtime/`, `lib/` |
| Examples, fixtures and checks | `examples/`, `tests/` |

The macro layer is project source, **not a runtime bundle**. See
[its integration notes](docs/luamacro/INTEGRATION.md) and
[third-party attribution](THIRD_PARTY.md).

## Licence

SLC is free software under the GNU General Public License, version 3 or later
([COPYING](COPYING)). The runtime library (`runtime/`) and compiler-generated
runtime/header helpers additionally carry the GCC Runtime Library Exception,
version 3.1 ([COPYING.RUNTIME](COPYING.RUNTIME)), as specified by the incoming
prototype and alpha design. Third-party notices retain their own terms.

## Differential fuzzing

With LuaJIT/LPeg and libgccjit configured as above:

```sh
luajit tests/fuzz/fuzz.lua --regressions
luajit tests/fuzz/fuzz.lua --seed 424242 --count 10 --no-shrink --keep
```

The fuzzer compares known/native/split runs with C at `-O0` and `-O2`; every tenth
program also needs the C compiler's UBSan runtime. A failed compiler/link command
is not evidence of a value mismatch: inspect its diagnostic and keep the seed and
scratch output. The alpha roadmap specifies the broader planned campaign; these
commands do not establish that its nightly qualification gate has been met.
