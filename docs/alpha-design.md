# slc alpha: design

**Status: alpha design, partly prototyped.** The integer differential fuzzer and the core text types now have prototype implementations; the broader fuzzing plan, maps and embedded distribution below remain alpha work. The specification records implemented language rules. Three pieces define the path from the prototype to a first alpha:

1. a differential fuzzer, to earn trust;
2. strings and a hash map, the two things every real program reaches for first;
3. one GPLv3 binary that contains everything, with a CLI built around it.

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

Stores, `Grow`, strings and maps are tested against Lua models:

* the generator emits a sequence of operations;
* the same sequence runs on a plain Lua table;
* each step's observable result goes into the checksum.

Stale `Id`s, removal during iteration and growth while a slot is in use are generated on purpose, and must trap in the slc runs exactly where the model says they are invalid.

## 1.6 Tasks

A second generator, phase two of the fuzzer, makes programs whose result does not depend on the schedule:

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

Text is bytes. UTF-8 is what the text words assume, and is checked where it matters: `utf8.valid(s)`, and `s:runes() do(cp, at) ... end` decoding with U+FFFD for invalid sequences. Indexing is by byte; `s[i]` is a checked `U8`, like a slice element.

## 2.2 Operations

Words, not operators, following the guide's rule that operators belong to numbers:

* **Length and bytes:** `s.length`, `s[i]`.
* **Slicing:** `s:sub(i, j)` (checked like `SLC_RANGE`), `s:trim()`.
* **Comparison:** `s:equals(t)`, `s:compare(t)`, which returns `oneof { less, same, greater }`.
* **Searching:** `s:starts_with(t)`, `s:ends_with(t)`, and `s:find(t)`, which returns `oneof { at: U32, missing: Unit }`.
* **Iteration:** `s:split(sep) do(part) ... end`, `s:lines() do(line) ... end`, `s:runes() do(cp, at) ... end`.
* **Parsing:** `s:parse(U32)` and friends return `oneof { value: T, bad: Unit }`. Absence is a sum, never a magic value.
* **Building text:**
  * `out:write("n = ", n, ", ok = ", ok, "\n")` appends values;
  * `out:clear()`, `out:push(byte)`, `out.length`.
* **C:** `s:cstring() do(c) ... end` lends a NUL-terminated copy on a data stack; `Str.of(c)` views a `CString` (`strlen` once).

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

The hash is keyed with a per-process random seed, so ordinary hash flooding does not work. It is not a cryptographic MAC; a map facing hostile keys should say so (`Map(K, V, { hash = 'siphash' })`).

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

**slc is distributed as one GPLv3 executable, `slc`, with gccjit as its only code generator and everything it needs inside it, except the host's C library and binutils** (decided). Nothing is downloaded. The targets for the alpha are `x86_64-linux` and `aarch64-linux`.

Running code in process is gccjit's own job: it links a shared object and slc `dlopen`s it, exactly as the prototype does today. No ELF loader of our own (decided). `dlopen` needs a dynamic C library, so `slc` links the host's libc dynamically and everything else statically. It is built against an old glibc baseline (2.28), so one binary runs on every distribution since.

What it contains:

| Part | How it is included |
|---|---|
| LuaJIT and LPeg | linked in; LPeg registered in `package.preload` |
| slc (`slc.lua`, `slc/*.lua`), LuaMacro | LuaJIT bytecode in an embedded file table, found by a package searcher |
| `lib/*.slc` | embedded sources |
| the runtime | `libslc_rt.a` linked into `slc`, and its symbols exported (`-rdynamic`), so code gccjit loads into the process binds to it; also embedded as an archive for executables; its header embedded |
| libgccjit | linked in statically, from our own GCC build (§3.4) |
| `cc1` | GCC's C front end from the same build, embedded: reads headers, compiles C beside slc (§3.5) |
| libgcc, crt files | embedded |
| glibc headers (the 2.28 baseline) | embedded: what in-process code is compiled against, since it runs on the host's glibc |
| musl `libc.a` and headers | embedded: what `slc build` executables are compiled and linked against, so they are static |
| header values for the shipped libraries | precomputed per target and per C library when slc is built, so common programs never start `cc1` (§3.5) |
| the C library | **the host's glibc**, linked dynamically |
| `as`, `ld` | **the host's binutils**, found on `PATH` or named by `SLC_AS` and `SLC_LD`; `slc doctor` says if they are missing |

The embedded executables, headers and link files are unpacked once, on first use, into `$XDG_CACHE_HOME/slc/<content hash>/`. The directory is written beside its final name and renamed into place, so concurrent first runs are safe. gccjit is pointed at it with `--sysroot` and `-B`, through `gcc_jit_context_add_driver_option`.

**Every path needs `as` and `ld`**, since gccjit always assembles and, in process, links a shared object. Because GCC chooses assembler features when it is configured, our GCC is configured against an old binutils baseline (2.38), so that its output assembles with any binutils from then on; `slc doctor` checks the host's version against that baseline.

## 3.2 Two C libraries, each where it runs

Code is compiled against the headers of the C library it will run on:

* **In process** (`slc run`, `native`, `slc.load`): the code runs inside `slc`, on the host's glibc. It is compiled against the embedded glibc headers, and its probe values (`O_RDONLY`, `struct stat`) come from them. Because glibc keeps its ABI stable, headers of the 2.28 baseline describe every newer glibc.
* **Executables** (`slc build`): static, on musl. They are compiled against musl's headers and linked with musl's `libc.a`, so they run anywhere.

The probe tables are therefore kept per C library, and a program's constants are always those of the libc it is linked with. The differential fuzzer (§1) runs both ways, which also checks that nothing in the language depends on which C library is underneath.

## 3.3 Building executables

`slc build prog.slc -o prog` runs gccjit to an executable (`GCC_JIT_OUTPUT_KIND_EXECUTABLE`):

* the host's `as` and `ld` do the rest;
* the program is compiled against musl's headers and linked against the embedded `libslc_rt.a`, musl and libgcc;
* the result is a static executable that runs on any Linux of that architecture.

Traps print the `.slc` file and line, which the IR already records for waits and will record for checks.

## 3.4 Building slc itself

`make dist`, in a pinned container per target:

1. **Toolchains.** A container with the glibc 2.28 baseline (to build `slc` itself) and a musl cross toolchain (to build the embedded `libslc_rt.a` and musl `libc.a` for executables).
2. **libgccjit.** Build GCC (the version is pinned) with `--enable-languages=jit --enable-host-shared --disable-bootstrap --disable-multilib --disable-lto`. Instead of taking the produced `libgccjit.so`, link its objects and archives into slc:
   * `jit/*.o`, `libbackend.a`, `libcommon-target.a`, `libcommon.a`;
   * `libcpp`, `libdecnumber`, `libbacktrace`, `libiberty`;
   * GMP, MPFR, MPC and zlib, all static.
3. **slc's own parts.** Build LuaJIT and LPeg static, compile slc's Lua to bytecode, build `libslc_rt.a`, and compute the header tables.
4. **Link** everything into `slc`, embedding the files with a generated assembly file (`.incbin`).
5. **Smoke test.** Run `slc run` on a hello world, `slc build` the same and run the executable, and run the full test suite *with the built binary*.

Expected size, an estimate until the first build: about 70 MB (libgccjit and `cc1` are each roughly 25 to 35 MB), and about 25 MB compressed.

Step 2 also keeps `cc1` (the same build, with `--enable-languages=c,jit`): it is embedded as a static executable.

**The risk to retire first** is gccjit's driver finding the embedded sysroots and crt files and the host's `as`/`ld` with only `-B` and `--sysroot`, and libgccjit's objects linking statically into `slc`. The first task of this part is a spike that builds a hello-world `slc` doing exactly those two things, before anything else is built around it.

## 3.5 Headers, and C beside slc

gccjit has no C front end; GCC's is `cc1`, and the binary carries it (decided). So:

* **The probe works wherever binutils is** (§38.3): a `cconst`, `cstruct` or `cread` on any header is answered by compiling the probe with the embedded `cc1` and the host's `as` and `ld` against the selected target libc's headers: glibc for in-process code, musl for standalone executables (§3.2). The probe is linked and run with that same libc, and its answer is cached under the target/libc identity. No host compiler is involved.
* **Shipped libraries cost nothing:** every constant, layout and getter `lib/` uses is computed per target when slc is built and embedded as a table. A program that only uses `lib/` never starts `cc1`.
* **C files beside slc files:** `slc build prog.slc helper.c -o prog` compiles `helper.c` with the embedded `cc1` and links it in. An extern without a header can then be defined in your own C.
* **`--emit-c` stays useful without a host compiler:** `slc build --emit-c` writes C for other build systems, and `slc cc file.c` compiles any C99 file with the embedded GCC (a thin driver over `cc1`/`as`/`ld`, mostly for the probe and for tests).

## 3.6 Licence

* **The `slc` binary is GPLv3** (decided). It links libgccjit and embeds `cc1`.
* **The runtime library, `libslc_rt`, is GPLv3 with the GCC Runtime Library Exception** (decided), as libgcc is. A program `slc build` produces links `libslc_rt.a`, musl (MIT) and libgcc (GPLv3 with the same exception), so the program may carry any licence its author chooses.
* The headers and templates the compiler emits into generated C (`slc_rt.h`, the per-type helpers) carry the same exception, so `--emit-c` output is equally free.

## 3.7 The CLI

```text
slc run prog.slc [args...]         run now: compile into this process; call main if exported
slc build prog.slc -o prog         a static executable
    -O0 .. -O3, -g                 optimization, debug info
    --emit-c -o out.c [-H out.h]   C for your own build (the C backend)
    --emit-obj -o out.o            an object file to link into a C program
slc check prog.slc                 specialize and check only: errors, no code (fast feedback)
slc test [files...]                run the program's tests (below)
slc fuzz [--seconds N] [--seed S]  the differential fuzzer (§1)
slc cc file.c -o file.o            compile C with the embedded GCC
slc doctor                         embedded versions, cache location, target, what works here
slc cache clean
slc version
```

* **`main`.** `local main = do(args: Args): I32 ... end` with `export main`. `Args` is a view: `args.length` and `args[i]`, a `Str`. The result is the exit status. A program without a `main` may still run under `slc run` through its top-level Lua and `native`.
* **Tests.** `test "parses a header" do ... end` declares a test. `check(cond)` inside it traps with the line when it fails.
  * Tests compile into one runner, each run under `slc_try`, so one failure does not stop the others.
  * Compile-time `assert`s run during `slc check` and `slc test` alike.
* **Projects.** A file runs alone. A project is a `project.lua` beside it: a Lua table with the entry, the import paths and the build options, since Lua is already slc's configuration language. `import "name"` searches the program's directory, the project's paths, then the embedded `lib/`.
* **Errors.** One line per error with the `.slc` file and line, then the chain of words being specialized when it happened (deepest last). This needs the stage to keep that chain, which it nearly does already for `S.site`.

## 3.8 What the alpha requires of this part

The alpha ships when:

* `slc` builds reproducibly for both targets;
* its own test suite passes when run through it;
* `slc run` and `slc build` work on a clean glibc container with only binutils installed, and the executables `slc build` produces run on one with nothing installed;
* the cache can be deleted at any time without consequence.

---

# Order of work

1. **Spike:** an `slc` with libgccjit linked in statically and libc dynamically, using the host's `as`/`ld`: run code in process (gccjit's shared object, bound to the runtime inside `slc`), and build a static musl hello-world executable. This settles §3 before anything depends on it.
2. **The fuzzer**, on the language as it is (§1.1 to §1.4), so everything after it is built under test.
3. **Strings:** `Str`, `Text`, `Chars(n)`, and `write` formatting.
4. **Maps:** `Map` and `StrMap`, then `Map.known`.
5. Model-based fuzzing of stores, strings and maps (§1.5); the task fuzzer (§1.6).
6. **The binary:** the full `make dist`, the CLI, header tables, tests, `main`/`Args`.
7. A week of nightly fuzzing with no open mismatch; then alpha 1.

Decided: `cc1` is embedded (§3.5); `as`, `ld` and the C library come from the host, and in-process loading is gccjit's own (§3.1); the runtime is GPLv3 with the GCC Runtime Library Exception (§3.6).
