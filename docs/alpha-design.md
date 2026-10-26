# slc alpha: design

**Status: alpha design, partly prototyped.** The integer differential fuzzer and the core text types now have prototype implementations; the broader fuzzing plan, maps and embedded distribution below remain alpha work. The specification records implemented language rules. Three pieces define the path from the prototype to a first alpha:

1. a differential fuzzer, to earn trust;
2. strings and a hash map, the two things every real program reaches for first;
3. one GPLv3 binary that embeds slc's own parts and uses the host for the rest, with a CLI built around it.

Each part says what it is, how it fits the language, and what is still open. This document belongs beside the specification ([staged-lua-c-v0.5.md](staged-lua-c-v0.5.md)) and the guide ([designing-and-writing-slc.md](designing-and-writing-slc.md)). Once a part is built, its rules move into the spec.

---

# 1. The differential fuzzer

## 1.1 The property

slc's central promise is that **staging does not change meaning**. A word gives the same result whether its inputs are known while compiling, known only when it runs, or anything in between, and whether it runs through the C backend or through gccjit. That promise can be tested mechanically, because slc already has several independent ways to run the same program:

| Run | What it exercises |
|---|---|
| **fully known**: `host(f(x...))` while compiling | `fold.lua`'s C semantics, the static paths of the specializer |
| **fully dynamic**: `export f`, C backend, `cc -O0` and `-O2` | residualization, lazy stores, loops, cgen, the C compiler |
| **split**: `export f { a = x }` with some inputs supplied | the partial evaluator proper: generalization, snapshots, rollback, range facts |
| **gccjit**: `native(f)` and `native(f { a = x })` | jitgen, cjit, the C reader |
| **checked**: the C build under UBSan and ASan | the generated code is free of undefined behaviour |

For a random program and random inputs, every run must give **the same outcome**: the same value, or the same failure. The failure cases are:

* rejected while compiling when the failing input is known (`index-range`, `ub-overflow`);
* a trap with the same check name when it runs;
* the same deadlock report (for tasks, §1.6).

A mismatch is a bug in one of the paths, and the run that disagrees says which. The split runs are the most valuable: they test exactly what a partial evaluator gets wrong (lazy stores written too late, a snapshot missed, a range fact that removed a needed check), and no ordinary test suite covers every split.

## 1.2 The generator

Programs come from a generator in Lua (`tests/fuzz/gen.lua`), seeded and deterministic. It builds an AST first and prints slc from it, so a failure can be shrunk on the AST (§1.4).

What it generates, weighted so that the hard paths come up often:

* **Types:** all integer widths and signs, `Bool`, `F64` (compared bit for bit), structs, sums, `Array(T, n)`, slices of arrays, and nesting of these.
* **Words:** typed words, with
  * some untyped (compile-time) parameters;
  * calls between generated words;
  * recursion with a decreasing fuel parameter, so it terminates;
  * tail calls.
* **Statements:** typed locals, assignment to fields and elements, and `if`/`elseif`. Also:
  * loops: `while` with bounded counters, typed `for`, `break`/`continue`, and host `for` loops over known counts;
  * sums: `match` on them with every handler form;
  * activities: opened records (`do(ctx...)`) and bind-to-remember.
* **Expressions:** every operator and conversion, `band`/`shr` and friends, and comparisons.
* **Memory:** `Store`/`Id` and `Grow`, generated together with a Lua model of their contents (§1.5). Strings and maps join once they are built.

**Avoiding undefined behaviour.** Like Csmith, the generator never relies on luck to avoid UB:

* divisors are made non-zero (`d | 1`);
* shift counts are reduced modulo the width;
* signed arithmetic stays inside ranges the generator tracks.

Intentional failures are a separate, explicit choice. The generator knows when an index it emits may be out of range, so every run's outcome is predictable in class.

**The output.** Every generated word folds all the values it computes into a `U64` checksum, written as an ordinary slc expression. The whole result is that one number.

## 1.3 The runner

`slc fuzz [--seconds N] [--seed S] [--jobs J]`:

1. Generate a program and 8 input vectors.
2. Fully known: evaluate each vector while compiling, giving expected outcomes.
3. Fully dynamic: one C file exporting the word, linked with a driver that runs all vectors; then the same through gccjit, in process.
4. Splits: for each vector, two random subsets of parameters supplied: `native` for all of them, and the C backend for one.
5. Every 50th program: the C build under UBSan and ASan.
6. Compare. On a mismatch, shrink (§1.4) and save.

The in-process path is the fast one: one `native` call per split, no processes. Several programs can share one C file so `cc` runs once per batch.

**Coverage steering.** The specializer counts which of its paths ran: rollback, snapshot, generalization, each cgen cleanup, each range fact. The generator raises the weights of constructs that reach rare paths.

## 1.4 Shrinking and regressions

A failing program is reduced on its AST, keeping it failing at each step:

* remove a statement;
* replace an expression by a constant or by one of its operands;
* inline a call;
* drop a parameter;
* narrow a type.

The result is written to `tests/fuzz/regressions/NNNN.slc` with its inputs and expected outcome. `tests/run.lua` runs every regression on every backend, so a fixed bug stays fixed.

## 1.5 Model-based fuzzing of storage

**Stores, `Grow`, `Text` and `Map` are implemented** ([storage.lua](../tests/fuzz/storage.lua)): random operation sequences run in SLC at `-O0` and `-O2` and on a Lua model with exact 64-bit checksum arithmetic. Families: store add/remove/read/write/has; grow push/read/write; text write/push/clear/length/view; map put/remove/has/read/length; a store read of a removed `Id`, a grow read one past the end through a dynamic index, and a map read of a removed key, each of which must trap with the library's message. `StrMap` and the map's iteration order are still open:

* the generator emits a sequence of operations;
* the same sequence runs on a plain Lua table;
* each step's observable result goes into the checksum.

Stale `Id`s, removal during iteration and growth while a slot is in use are generated on purpose, and must trap in the slc runs exactly where the model says they are invalid.

## 1.6 Tasks

**Implemented as templates** ([tasks.lua](../tests/fuzz/tasks.lua)), phase two of the fuzzer: five written programs whose result cannot depend on the schedule (a pipeline, four shared workers, a pool handoff, a `first_of` against a distant timer, and a deliberate deadlock). Each runs under 20 `SLC_SCHED_SEED` values and with worker threads, and every run must print the same bytes; the deadlock template must print the same report every time. The original plan was a grammar-driven generator; the scheduling surface is small enough that readable templates find more than a generator would.

* producers and consumers over channels, combined with commutative operations;
* pools passing buffers;
* `first_of` with timers far apart.

Each runs under 20 `SLC_SCHED_SEED` values and with threads, and all results must agree. Deliberately unfinished programs (a receiver nobody sends to) must produce the same deadlock report naming the same lines.

## 1.7 What the alpha requires

The fuzzer runs in CI for 10 minutes per commit and 8 hours nightly. The alpha ships after a week of nightly runs with no open mismatch.

---

# 2. Strings and maps

Both must fit the memory model as it is:

* aggregates hold no references;
* resizable values live on data stacks, are created in place and move only by `Ref`;
* long-lived relationships are `Id`s;
* tasks share nothing.

They must also do what slc does best: **when the text or the keys are known, the work happens while compiling.**

## 2.1 Three string types, one per role

| Type | Role | Storage | Copy | Store in a struct | Send to a task |
|---|---|---|---|---|---|
| `Str` | a view of text | someone else's bytes | the view | no | no |
| `Text` | text being built | its own data stack (like `Grow U8`) | never (moves by `Ref`) | as a field created in place | no |
| `Chars(n)` | short text as a value | inline: a length and `n` bytes | yes | yes | yes |

* **`Str`** is to text what `Slice` is to arrays: a read-only view, `{ptr, len}` in C. It has the same lifetime rules: a view cannot outlive the activity that made it, and cannot be stored in an aggregate. A string literal is a `Str` whose bytes are static, so it may go anywhere a `Str` may.
* **`Text`** is owned, growable text. It is `Grow U8` with text operations, created in place: `local out: Text = Text {}`. `out:view() do(s) ... end` lends it as a `Str`, as `Grow:view` does.
* **`Chars(n)`** is a fixed-capacity value. It is the type for map keys, struct fields, messages between tasks and pool slots. Assigning a longer `Str` to it is a compile-time error when the length is known and a trap otherwise. `c:str()` views it.

Text is bytes. UTF-8 is what the text words assume, and is checked where it matters: `utf8.valid(s)`, and `s:runes() do(cp, at) ... end` decoding with U+FFFD for invalid sequences (both implemented, [utf8.slc](../lib/utf8.slc)). Indexing is by byte; `s[i]` is a checked `U8`, like a slice element.

## 2.2 Operations

Words, not operators, following the guide's rule that operators belong to numbers:

* **Length and bytes:** `s.length`, `s[i]`.
* **Slicing:** `s:sub(i, j)` (checked, with the trap in the library), `s:trim()`.
* **Comparison:** `s:equals(t)`, `s:compare(t)`, which returns `oneof { less, same, greater }`.
* **Searching:** `s:starts_with(t)`, `s:ends_with(t)`, and `s:find(t)`, which returns `oneof { at: U32, missing: Unit }`.
* **Iteration:** `s:split(sep) do(part) ... end`, `s:lines() do(line) ... end`, `s:runes() do(cp, at) ... end`.
* **Parsing:** `s:parse(U32)` and friends return `oneof { value: T, bad: Unit }`. Absence is a sum, never a magic value.
* **Building text:**
  * `out:write("n = ", n, ", ok = ", ok, "\n")` appends values;
  * `out:clear()`, `out:push(byte)`, `out.length`.
* **C:** `s:cstring() do(c) ... end` lends a NUL-terminated copy on a data stack, built with the Text words when the text is only known at run time; `Str.of(c)` views a `CString` (`strlen` once).

**Formatting is decided while compiling.** `out:write` is staged like `cformat` (§33):

* known pieces are concatenated into one literal;
* each dynamic value gets the conversion its type needs;
* a known value is printed while compiling.

No format string exists at run time, so none can be wrong. Floats print as the shortest text that reads back to the same value. The runtime carries one implementation of that, used by both backends.

**Known text folds.** Every operation above has a compile-time path over Lua strings:

* `s:find("x")` on a known `s` is a constant;
* splitting a known line is done while compiling;
* matching a dynamic `Str` against a known one compiles to a length test and a fixed comparison.

This is why `native` on a CSV header (`examples/csv.slc`) can go further than fields and decimals: column names, separators and quoting rules all become part of the decoder.

## 2.3 `Map(K, V)`

A hash map is a resizable value like `Store` and `Grow`:

* created in place: `local counts: Map(Chars(32), U32) = Map(Chars(32), U32) {}`;
* it lives on its own data stack, and gives its space back when its block ends;
* it moves only by `Ref`;
* it may be a struct field created in place.

**Keys** are fixed-size values with equality: integers, `Bool`, `Id T`, `Chars(n)`, and structs and sums made of these. **`StrMap(V)`** is the map with text keys of any length: it copies key bytes into an arena of its own, so it takes two data-stack indices (each resizable region must be the top of its stack). **Values** are fixed-size values. Nested maps need a separate representation decision: a `Store` currently accepts only fixed-size payloads, so a store slot cannot directly hold a struct containing a resizable map. IDs identify objects but do not settle that storage placement. This design does not yet specify maps of maps or extend the Goose storage rules to admit them.

**Addressing uses `[]`**, as for stores and pools:

* `m[k]` is the place of an existing entry. It is checked at every use, and a missing key traps (`key not in Map(...)`). Like `store[id]`, its lookup is done once per stretch and repeated only after something that can move entries: an insertion, a removal, a call into C, a loop round.
* `m:find(k)` gives `oneof { found: V, missing: Unit }`: absence as an outcome.
* `m:put(k, v)` inserts or replaces; `m:ensure(k, init)` inserts if missing.
* `m:remove(k)` returns `Bool`, `m:has(k)` returns `Bool`, and `m.length` counts the entries.
* `m:each(do(k, v) ... end)` iterates. A structural change during the iteration traps, as a store borrow does.

```lua
-- a word count: one hash per word
counts:ensure(word, 0)
counts[word] = counts[word] + 1
```

**Layout:**

* open addressing with Robin Hood probing and backward-shift deletion, so there are no tombstones;
* entries stored inline as `{hash32, K, V}`, with the stored hash compared before the key;
* growth at 7/8 load, in place at the top of the data stack: the new table is built above the old one and moved down.

The table code is ordinary C in the runtime, one copy per entry size. Hashing and key equality are generated per key type.

**Hashing is generated from the key type, while compiling:**

* a fixed sequence of loads and mixes for a struct;
* one mix for an integer;
* known keys hash to constants.

The hash is SipHash-2-4 with a per-process random seed ([hash words](../lib/hash.slc)), so ordinary hash flooding does not work. It is a keyed PRF, not an authenticated MAC; a map facing hostile keys is covered by the seeded SipHash that is already the default, so there is no separate `{ hash = 'siphash' }` option to choose.

**Iteration order is unspecified**, and differs between runs, because the seed does. A program that needs an order sorts its keys.

## 2.4 Maps known while compiling

A map whose contents are known while compiling is not a hash table at all:

```lua
local keyword = Map.known { ["if"] = Token.if_(), ["while"] = Token.while_(), ["end"] = Token.end_() }
-- keyword:find(s) on a dynamic Str: a switch on the length, then fixed comparisons
```

With string keys, `Map.known` compiles lookups to a decision tree (length, then distinguishing bytes); with integer keys, to a switch or a perfect hash. A known key folds to its value. This is the same move as `native` on a header: the description is data, and the lookup becomes code.

## 2.5 Across tasks

* `Str` and `Text` never cross tasks.
* `Chars(n)` is a value: it is copied over channels.
* Long text crosses in a pool slot: `Pool(Buffer)` with `Buffer = struct { n: U32, bytes: Array(U8, 4096) }`, moved, not copied.
* A shared map is a task that owns it and answers requests. That is Go's model, and the only one slc has.

## 2.6 What is open

* Whether `==` should compare `Str` contents. The guide reserves operators for numbers; `s:equals(t)` is the conservative choice, and the one above.
* `Chars(n)` beyond a few hundred bytes is a poor key type; `StrMap` covers long keys.
* Small-size optimization for `Text` (inline bytes until it grows) is possible later without changing the surface.

---

# 3. One binary

## 3.1 The decision

**Status: the launcher works.** `make dist` builds `build/dist/slc` (about 1 MB):
[tools/embed.lua](../tools/embed.lua) turns slc's sources into a C table,
[tools/launcher.c](../tools/launcher.c) runs them **from memory** through a package
searcher on the host's LuaJIT, and the C runtime (runtime C plus the policy C
generated at dist time) is **linked into the binary** with `-rdynamic`, so code
gccjit loads binds to `slc_*` in the process. There is no runtime `.so` and no
`cc` for `slc run`. A static `libslc_rt.a` is built once at dist time, embedded,
and written with the runtime headers into a **per-run work directory**
(`$TMPDIR/slc-run-<hash>-<pid>/`, removed when the process exits) — the only things
the host tools must see on disk. That is not a cache: nothing is reused between
runs. The one real cache is the probe-answer cache (`SLC_CACHE`), which avoids
repeating a `cc` round-trip for an unchanged header question. `make test-dist` checks all of it,
including that no runtime library is built. LPeg is a host dependency as well:
the macro lexer uses it.

**slc is distributed as one GPLv3 executable, `slc`, that embeds slc's own parts and
depends on the host for the rest** (decided). Everything slc is — the compiler Lua,
`lib/*.slc`, the runtime archive, the runtime header — lives inside the binary. What
slc is built *from* stays outside it: the host's LuaJIT, libgccjit, C compiler,
binutils and C library are dependencies, not vendored copies. Building GCC or
LuaJIT is not part of this project; packagers already ship both.

The targets for the alpha are the host's Linux, `x86_64` and `aarch64`.

Running code in process is gccjit's own job: it links a shared object and slc
`dlopen`s it, exactly as the prototype does today. No ELF loader of our own.

What the binary contains, and where each part comes from:

| Part | How it is included |
|---|---|
| LuaJIT | **the host's**, linked dynamically (`libluajit-5.1`) |
| libgccjit | **the host's**, loaded at run time (`SLC_GCCJIT`, else the loader's search path) |
| slc (`slc.lua`, `slc/*.lua`, `macro/*.lua`) | embedded as **LuaJIT bytecode**, found by a package searcher (no source parsing at startup) |
| `lib/*.slc` | embedded sources: the compiler still specializes them with the program |
| the runtime | compiled at dist time (C plus the SLC policy), linked into `slc` with `-rdynamic`; the same `libslc_rt.a` is embedded for `slc build` |
| the runtime header | embedded |
| header values for the shipped libraries | precomputed at dist time with the host `cc`, embedded per target |
| the C compiler | **the host's `cc`**, for probes and for linking |
| `as`, `ld` | **the host's binutils**, found on `PATH` or named by `SLC_AS` and `SLC_LD` |
| the C library | **the host's**, dynamically, in process and in built executables |
| temporary files | a per-run work directory (`$TMPDIR/slc-run-<hash>-<pid>/`, removed at exit): the runtime archive and headers, for the host `cc` |

Embedded files are the generated ones (the precomputed header tables) and our own
sources; the compiler and vocabulary sources are read from memory, never written.
The runtime archive and headers are written to a per-run work directory because the
host `cc` needs paths; the directory is removed at exit.

`slc doctor` reports the versions it found for LuaJIT, libgccjit, `cc` and
binutils, and says what is missing.


## 3.2 One C library, the host's

Code is compiled against the host's headers and linked against the host's libc,
whether it runs in process or in an executable `slc build` produced. There is no
second C library to keep in step, so a program's probe values (`O_RDONLY`,
`struct stat`) are always those of the libc it will run on.

Probe answers are cached under the target identity (architecture, host libc
version). The differential fuzzer (§1) still runs every backend, which is what
checks that nothing in the language depends on how the code got there.

## 3.3 Building executables

`slc build prog.slc -o prog`:

* gccjit compiles the program to an object (`GCC_JIT_OUTPUT_KIND_OBJECT`);
* `slc` writes the embedded `libslc_rt.a` to its cache and calls the host `cc` to
  link the object with that archive and the host's libc;
* the result is a dynamic executable that runs wherever the host's libc does.

`--emit-c -o out.c` and `--emit-obj -o out.o` stay for other build systems; they
are the C backend and a linkable object respectively. No static musl, no embedded
crt files, no sysroot juggling.

Traps print the `.slc` file and line, which the IR already records for waits and
will record for checks.

## 3.4 Building slc itself

`make dist`, with nothing but a `cc` and the host's LuaJIT and libgccjit
(implemented; the runtime archive and precomputed header tables are still to come):

1. **Runtime first.** Generate the policy C from `runtime/*.slc` with the compiler,
   compile it with `runtime/*.c` and the host `cc`, and archive the result as
   `libslc_rt.a`.
2. **Embed slc's parts.** [tools/embed.lua](../tools/embed.lua) compiles the
   compiler and macro modules to LuaJIT bytecode, then writes that, `lib/*.slc`,
   the runtime headers, the fuzz scripts and the runtime archive into one C table,
   with a content hash naming the work directory. The launcher sets `slc_root` so
   modules find the runtime headers whichever directory they unpack into.
3. **Link the launcher.** [tools/launcher.c](../tools/launcher.c) loads the Lua and
   SLC sources from memory, links the host's LuaJIT dynamically, and links the
   runtime archive into the executable with `-rdynamic`. Only the headers and the
   archive are written, to a per-run work directory under `$TMPDIR`, for
   `slc build` and harnesses that link C.
4. **Smoke test.** `make test-dist`: a program runs through the binary (asserting
   no runtime library was built) and the task and storage fuzzers run through it.

There is no GCC build, no LuaJIT build, no pinned container and no 25 MB `cc1`
inside the binary. Embedded sources are recorded content-addressably, so a
`make dist` from the same tree is reproducible except for what `cc` and the host
libraries choose (documented, not promised, in the alpha).

## 3.5 Headers, and C beside slc

gccjit has no C front end, so header questions are answered by the host `cc`:

* **The probe uses the host `cc`** (§38.3): a `cconst`, `cstruct` or `cread` on any
  header is answered by compiling a small program with `cc` against the host's
  headers, linking and running it, and caching the answer under the target
  identity. `SLC_CC` names the compiler if `cc` is not it.
* **Shipped libraries cost nothing:** constants and layouts for the bundled
  libraries are recorded while `make dist` compiles the examples (the probe
  records its answers), aggregated by [tools/tables.lua](../tools/tables.lua) and
  embedded as `runtime/header_tables.lua`, keyed like the probe cache and tagged
  with the C-library identity it was recorded against. A run that sees the same
  library answers from the table without starting the compiler; another library
  falls back to probing. `make test-dist` asserts this by running an I/O program
  with `CC=/bin/false`. Getters (C variables such as `errno`) still probe.
* **C files beside slc files:** `slc build prog.slc helper.c -o prog` compiles
  `helper.c` with the host `cc` and links it in. An extern without a header can
  then be defined in your own C.
* **`--emit-c` stays useful without libgccjit:** it writes C for other build
  systems. `slc cc file.c` is a thin driver over the host compiler, mostly for the
  probe and for tests.

## 3.6 Licence

* **The `slc` binary is GPLv3** (decided). It links libgccjit (GPLv3) dynamically.
* **LuaJIT is MIT** and stays the host's, loaded dynamically.
* **The runtime library, `libslc_rt`, is GPLv3 with the GCC Runtime Library
  Exception** (decided), as libgcc is. A program `slc build` produces links
  `libslc_rt.a` and the host's libc, so the program may carry any licence its
  author chooses.
* The runtime header the compiler emits into generated C (`slc_rt.h`) carries the
  same exception, so `--emit-c` output is equally free.

## 3.7 The CLI

```text
slc run prog.slc [args...]         run now: compile into this process; call main if exported
slc build prog.slc -o prog         an executable (host cc links it)          [implemented]
    -O0 .. -O3, -g                 optimization, debug info
    --emit-c -o out.c [-H out.h]   C for your own build (the default compile form)
    --emit-obj -o out.o            an object file (the --gccjit form)
slc check prog.slc                 specialize and check only: errors, no code  [implemented]
slc test [files...]                run the program's tests (below)          [implemented]
slc fuzz [--seconds N] [--seed S]  the differential fuzzer (§1), in this process
slc fuzz --tasks [--seeds N]      the schedule-independence templates (§1.6)
slc fuzz --storage [--count N]    store operations against a Lua model (§1.5)
slc cc file.c -o file.o            compile C with the host compiler           [implemented]
slc doctor                         versions found, cache location, what works [implemented]
slc cache clean                    drop the probe cache                       [implemented]
slc version                                                                  [implemented]
```

* **`main`.** `local main = do(args: Args): I32 ... end` with `export main` (implemented, see [examples/args.slc](../examples/args.slc)). `Args` is a view of the process command line: `args.length` counts it (the program path is `args[0]`) and `args[i]` is a `Str`. The result is the exit status. A program without a `main` may still run under `slc run` through its top-level Lua and `native`.
* **Tests.** `test "parses a header" do ... end` declares a test (implemented, see [examples/tests.slc](../examples/tests.slc)). `check(cond)` inside it traps with the line when it fails; a condition known while compiling must hold then, and a dynamic one traps where it runs.
  * A test body is plain code; comparisons live in words, where `==` is staged. A host condition (`check(true)`) is decided while compiling.
  * Tests compile into one runner (`slc test`), each run under `slc_try`, so one failure does not stop the others; the exit status counts failures.
  * Compile-time `assert`s run during `slc check` and `slc test` alike.
* **Projects.** A file runs alone. A project is a `project.lua` beside it: a Lua table with the entry, module paths and build options, since Lua is already slc's configuration language (implemented, see [examples/project](../examples/project): `entry = 'main.slc'`, `paths = { 'model' }`, `options = { opt = 2 }`). `run`, `build`, `check` and `test` accept a program path, a project directory or a `project.lua`; the table is evaluated in a data-only environment. Modules use Lua's `require` and `package.path`, extended with an SLC source loader; bundled vocabularies use names such as `require "slc.io"`. The loading and cache contract is described in [modules.md](modules.md).
* **Errors.** One line per error with the `.slc` file and line, then the chain of words being specialized when it happened (deepest last) — implemented: the stage's active frames are appended to every diagnostic, e.g.
  `prog.slc:2: division by zero (undefined behaviour in C)`, then `in outer (prog.slc:4)` and `in inner (prog.slc:1)`.

## 3.8 What the alpha requires of this part

The alpha ships when:

* `slc` builds with a plain `cc` and the host's LuaJIT and libgccjit development
  packages, on both targets;
* its own test suite passes when run through it (the launcher spike plus
  `make test-dist` is the first step; the suite through the binary is not wired
  yet);
* `slc run` and `slc build` work on a clean container that has the host's cc,
  LuaJIT and libgccjit, and the executables `slc build` produces run there;
* the cache can be deleted at any time without consequence.

---

# Order of work

1. **Spike:** a launcher that embeds slc's own parts, links LuaJIT dynamically,
   loads the host's libgccjit, runs code in process (gccjit's shared object, bound
   to the runtime inside `slc`) and builds an executable through the host `cc`.
   This settles §3 before anything depends on it.
2. **The fuzzer**, on the language as it is (§1.1 to §1.4), so everything after it is built under test.
3. **Strings:** `Str`, `Text`, `Chars(n)`, `write` formatting, and the UTF-8 words.
4. **Maps:** `Map` and `StrMap`, `Map.known`, and the optional SipHash keying.
5. Model-based fuzzing of stores, strings and maps (§1.5); the task fuzzer (§1.6).
6. **The binary:** `make dist`, the CLI, header tables, tests, `main`/`Args`.
7. A week of nightly fuzzing with no open mismatch; then alpha 1.

Decided: slc's own parts are embedded and the host supplies LuaJIT, libgccjit, `cc`,
`as`, `ld` and the C library (§3.1, §3.5); in-process loading is gccjit's own
(§3.1); executables are dynamic and linked with the host `cc` (§3.3); the runtime
is GPLv3 with the GCC Runtime Library Exception (§3.6).
