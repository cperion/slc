# Designing and writing slc

**Status: a guide to writing programs in slc, beside the specification ([staged-lua-c-v0.5.md](staged-lua-c-v0.5.md)), which owns the language rules.** It follows Let's guide, *Designing and writing Let*, and keeps what transfers. Where slc differs, it says how and why.

Every `lua` block below is an excerpt of [`examples/guide.slc`](../examples/guide.slc), which the test suite compiles to strict C and runs; every `c` block is that compilation's actual output. `tests/guide.lua` checks both, so this guide cannot drift from the language.

## 0. Forms this guide relies on

| Form | Used for |
|---|---|
| `local f = do(x: T): R ... end`, `do(x: T): R = e` | typed words: compiled to native code |
| `function T:m(...): R ... end` | methods: the receiver is `self`, a reference |
| `struct { ... }`, `oneof { ... }` | records and sums |
| `s { name = do(p) ... end, name(p) = e }` | matching a sum: one handler per alternative |
| untyped parameters, `f(known)` | compile-time parameters, partial application |
| `f "lit"`, `f 1 2`, `f(x) do ... end` | literal application and saturating chains |
| `do(ctx...)`, `local ctx... = e` | opening a record or a vocabulary |
| `endall` | closing a spine of trailing blocks |
| `s[id]`, `g[i]`, `pool[slot]`, `a[i]` | checked places |
| `tasks do(scope...)`, `spawn do`, `first_of` | concurrency |
| `require "slc.io"` | libraries, including I/O by completion |
| `native(word)`, `slc run` | compile now, into this process, and call from Lua |

---

# Part I — Design

## 1. The stance

slc puts **binding time** at the center. A program is Lua that runs while compiling. Typed words are evaluated in place with whatever is known, and only the work that depends on run time remains, as C. Let's question, "what is known, and when?", has an exact answer for every value in an slc program:

* **A Lua value** (a table, a string, a closure, a number in host code) exists only while compiling.
* **A known native value** (`U32(4)`, a constant field, a sum with a known tag) is computed while compiling. It shapes the C, and may vanish from it.
* **A runtime value** (a parameter of an export, a read from a file) is in the C.

Three commitments follow from Let and sharpen in slc:

1. **Say it as you think it.** A program is words for its domain, spoken in the contexts where they make sense. The surface is Lua's, extended; it reads as a script and compiles as C.
2. **Never hide what matters.** Ownership, lifetime, failure and cost are visible in the contracts, and in the C: every check, every wait, every allocation is a line you can read.
3. **Grow the vocabulary in Lua, not the language.** Configuration, dialects, generators and tests are Lua running at compile time. A new macro is a last resort.

## 2. The method

| Step | Question | slc answer |
|---|---|---|
| Values | What does the program talk about? | `struct`, `oneof`, `Array` |
| Ownership | What exists, and who owns it? | fields for trees, `Store`/`Id` for graphs, `Grow` for sequences, pools across tasks |
| Activities | What bounded work happens? | activity words with a body |
| Vocabularies | What can be done here? | methods, opened records, Lua tables, `require` |
| Pure core | What is decided? | words from values to values |
| Composition root | Who connects the parts? | an exported word |
| Edges | Where does the world come in? | externs, `require "slc.io"`, opened at the outside |
| Tests | How do we know? | a C harness drives the exports; Lua asserts at compile time |
| Costs | What must stay fast? | read the C; measure |

**Draft top-down.** Write the word you wish you had, then the words it needs. slc compiles only what exports reach, so a draft costs nothing until something uses it.

## 3. Data

### 3.1 Values first

Model records and sums before behavior. Anything that is stored, replayed, logged, undone or tested should be data:

```lua
local Direction = oneof { left: Unit, right: Unit }
local Command = oneof { move: Direction, insert: U32, undo: Unit, quit: Unit }
```

Commands as data give undo, replay and tests one foundation, and (§8) they give specialization something to work with.

### 3.2 Ownership

* **Give mutable state an owner.** A scope owns its locals; a struct owns its fields; a store owns its slots. Other code receives access explicitly, as a `Ref`.
* **Trees are fields; graphs are stores.** A `Store T` holds objects with stable identity, and an `Id T` names one without owning it:

```lua
local Heading = struct { level: U32, words: U32 }
local Outline = struct { headings: Store Heading }

local add_words = do(outline: Ref Outline, id: Id Heading, n: U32): U32
    outline.headings[id].words = outline.headings[id].words + n
    return outline.headings[id].words
end
```

  `outline.headings[id]` is a place, checked at every use. Nothing holds its address past the stretch it was found in, so the store may grow between two uses.
* **Distinguish values from access.** A `Ref` writes through to its place. An `Id` identifies a slot; it owns nothing. A `Slot` moves between tasks (§10). Copying any of them copies the handle, not the thing.
* **Aggregates hold no references.** A struct cannot contain a `Ref` or a `Slice`; long-lived relationships are `Id`s.
* **Lua tables are for compile time.** Open, dynamic data is a Lua table while compiling. At run time, data has a shape.

### 3.3 Outcomes and failures

An outcome a caller can act on is a sum, matched exhaustively. A broken invariant traps. Do not encode absence as a magic value:

```lua
local Found = oneof { found: U32, missing: Unit }
```

```lua
local find_nonzero = do(xs: Slice U32): Found
    local i: U32 = 0
    while i < xs.length do
        if xs[i] ~= 0 then
            return Found.found(i)
        end
        i = i + 1
    end
    return Found.missing()
end
```

The libraries follow the same rule: a receive is `oneof { value: T, closed: Unit }`, an I/O result is `oneof { done: U32, failed: I32 }`.

## 4. Words

### 4.1 Subject first, body last

A call should read like a sentence: subject, verb, objects, continuation. A method makes the subject the receiver:

```lua
function Document:move_left(): Unit
    if self.cursor > 0 then
        self.cursor = self.cursor - 1
    end
end

function Document:at_end(): Bool
    return self.cursor == self.length
end
```

Put the body last when the word establishes structure: `transaction(document) do(editing...) ... end`.

### 4.2 Let the contract say copy or borrow

| Operation | Usual design |
|---|---|
| maintain a component's own invariants | a method: `self` is a reference |
| query or transform a value | a word taking `T` |
| coordinate mutation from outside a component | a word taking `Ref T` |

A `T` parameter is a copy; a `Ref T` parameter writes through. A method call on a value (not a place) works on a temporary, never silently on a copy the caller thinks it still has.

### 4.3 A match reads as a protocol

Handlers are named after outcomes, and the handler sugar `name(p) = e` keeps short arms short:

```lua
local first_or = do(xs: Slice U32, fallback: U32): U32
    return find_nonzero(xs) {
        found(i) = xs[i],
        missing() = fallback,
    }
end
```

### 4.4 Keep known information available

**An untyped parameter of a native word is a compile-time parameter.** Configuration, grammars, layouts and counts known before run time belong there, usually as Lua tables:

```lua
local tab_stop = do(config, column: U32): U32
    local width: U32 = config.tab_width
    return (column / width + 1) * width
end

local tab_stop_4 = tab_stop { tab_width = 4 }
```

```c
uint32_t tab_stop_4(uint32_t column) {
    return (column / 4u + 1u) * 4u;
}
```

**Typed is not the same as runtime.** A typed parameter receives whatever the caller has: applied to a known value, it computes while compiling. An untyped parameter is always known. Do not erase known information by routing it through C, a store, or a channel on a hot path.

### 4.5 Do not decide inlining

Applying a word evaluates its body in place. There is no inlining decision to make, and no cost to small words. A C function appears for exactly two reasons: an export, or a word re-entered in non-tail position (recursion). A tail call is a loop. Write the words the domain needs, at the size the meaning wants.

## 5. Activities

> **Entities own what persists. Activities own or borrow what is needed for a purpose. Words express what happens inside.**

An activity is a design role made of ordinary parts: a word that sets up a context, runs a body that opens it, and owns completion. In slc it costs nothing extra: the body is a callback evaluated in place, and a private context is an ordinary local that folds away.

### 5.1 Enter an activity and speak its verbs

```lua
local Editing = struct { length: U32, cursor: U32, edits: U32 }

function Editing:insert(n: U32): Unit
    self.length = self.length + n
    self.cursor = self.cursor + n
    self.edits = self.edits + 1
end
```

```lua
local type_word = do(document: Ref Document, n: U32): U32
    local moved: U32 = 0
    transaction(document) do(editing...)
        insert n
        local before = cursor
        move_left()
        moved = before - cursor
    end
    return moved
end
```

`do(editing...)` opens the context. Bare calls use its methods (`insert n`, `move_left()`), and its fields are live places (`cursor`).

### 5.2 Open to work; bind to remember

An opened field name is the field's place: reading it reads the current value. A binding takes the value at that point: `local before = cursor` keeps the cursor from before `move_left()`. Opening a place keeps it a place: `local node... = g.nodes[id]` works on the store's slot itself.

### 5.3 The activity owns completion

```lua
local transaction = do(document: Ref Document, body): Unit
    local editing: Editing = Editing { ...document }
    body(Ref(editing))
    document = Document { ...editing }
end
```

This one commits a working copy at the end. Its contract is its own: write through, commit, roll back, retry. Three boundaries hold:

* the body's `return` leaves the body, not the activity;
* cleanup and commit are the activity's code, not a side effect of opening;
* a borrow cannot outlive its activity, but an owned result may leave it.

The working copy costs nothing. The whole activity becomes field copies:

```c
uint32_t type_word(Document *document, uint32_t n) {
    Editing editing;
    editing.length = document->length;
    editing.cursor = document->cursor;
    editing.edits = document->edits;
    editing.length = editing.length + n;
    editing.cursor = editing.cursor + n;
    editing.edits = editing.edits + 1u;
    uint32_t before = editing.cursor;
    if (editing.cursor > 0u) {
        editing.cursor = editing.cursor - 1u;
    }
    uint32_t moved = before - editing.cursor;
    document->length = editing.length;
    document->cursor = editing.cursor;
    document->edits = editing.edits;
    return moved;
}
```

### 5.4 Stack activities instead of adding options

```lua
local import_words = do(document: Ref Document, stats: Ref Stats, n: U32): Unit
    counted(stats) do
    counted(stats) do
    transaction(document) do(editing...)
        insert n
    endall
end
```

Each word owns its policy, and the order is visible. `endall` closes the spine; it adds no semantics.

### 5.5 Dialects

A dialect is a vocabulary plus an engine. In slc the engine often runs while compiling: a description built from Lua tables and words is consumed by Lua code that emits only the work that remains. Keep descriptions pure and effects in engines. Lua at compile time can do anything; a convention is not a sandbox.

## 6. Connecting behavior

| Connection | Use |
|---|---|
| ordinary result | a computation producing a value: the default |
| subject block | a block receiving a thing to act on: `ch:each(do(v) ... end)` |
| activity block | a block receiving a vocabulary: `do(editing...)` |
| keyed handlers | one behavior per outcome: matching a sum, a receive, an I/O result |
| channel | values crossing tasks (§10) |

**Saturating chains.** `transaction(document) do(editing...) ... end` applies `transaction` to its arguments group by group until it is saturated. The signature decides the invocation point, not the parser. A pending runtime argument stays inside its chain; it never becomes a runtime closure (slc has none).

## 7. Composition

* **Exports are the composition roots.** C calls them, and they wire the parts together. Only what they reach is compiled.
* **Start-up is a binding time too.** `native(word)` compiles a word into this process and returns it as a Lua function, so a value read at start-up (an argument, a config file, a schema) can be specialized on like a table written in the source: `native(tab_stop { tab_width = width })`. Keep the reading in Lua and the work in words; the same words compile ahead of time.
* **Effects enter at the edges.** Externs, `require "slc.io"` and the POSIX library are opened at the outside and passed in. The word that opens a file is not the word that parses it.
* **The pure core decides.** Words from values to values are testable while compiling. Applied to known values, a typed word computes in the compiler, and Lua asserts the answer:

```lua
assert(host(tab_stop({ tab_width = 8 }, U32(3))) == 8)
```

## 8. Describe, then run

When a problem has structure (a grammar, a key map, a protocol), write the structure as data and an engine that consumes it. Keep one engine:

```lua
local apply = do(document: Ref Document, c: Command): Unit
    c {
        move = do(d)
            d {
                left() = document:move_left(),
```

Over a description known while compiling, the engine dissolves:

```lua
local greeting = { Command.insert(5), Command.move(Direction.left()), Command.insert(1) }
local type_greeting = do(document: Ref Document): Unit
    for i = 1, #greeting do
        apply(document, greeting[i])
    end
end
```

```c
void type_greeting(Document *document) {
    document->length = document->length + 5u;
    document->cursor = document->cursor + 5u;
    if (document->cursor > 0u) {
        document->cursor = document->cursor - 1u;
    }
    document->length = document->length + 1u;
    document->cursor = document->cursor + 1u;
}
```

Over a description known only at run time, the same engine is a loop with a `switch`:

```lua
local replay = do(document: Ref Document, commands: Ref (Grow Command)): Unit
    local i: U32 = 0
    while i < commands.length do
        apply(document, commands[i])
        i = i + 1
    end
end
```

Do not maintain a second, hand-specialized implementation. Read the C to confirm the interpretation vanished.

## 9. Arithmetic and operators

Arithmetic is C's, exactly: folding while compiling follows C's widths, wraparound and conversions, and undefined behavior (signed overflow, division by zero, oversized shifts) is rejected where it is known. Operators belong to numbers, including a library's own (a fixed-point type defines `__add`, `__mul` and `__cast`; spec §41). Bitwise operations are words (`band`, `bor`, `shr`) because Lua's operators cannot be staged for them. I/O, sending and matching are named words, never symbols.

## 10. Concurrency

Go's model, fitted to a language without a garbage collector: **tasks share no memory, and every lifetime is a scope.**

### 10.1 Share nothing

A spawned block sees the outside through copies taken when it is spawned. Assigning one is rejected, and a `Ref`, `Ptr`, `Slice` or `CString` cannot be copied in at all: each points into memory someone else owns. When the compiler says `a task shares no memory`, the design is asking for a message or a move.

### 10.2 Scopes own lifetimes

A `tasks` scope ends when its body and all its tasks have, and its channels and pools retire with it. To wait for a group of workers and then act (Go's WaitGroup), give the group a scope of its own, and act when it ends.

### 10.3 Messages are copied; buffers move

Use channels for messages. Use a pool for buffers: take a slot, fill it in place, send the slot. Ownership moves with it, and the receiver uses it in place. `pool[slot]` checks ownership at every use, so a slot used after it was sent traps.

### 10.4 The world comes in at the edges

This word counts the lines of a file. The scope body opens the file (a path is a `CString`, which no task may hold) and hands the `File` to a reader task. Workers run in a scope of their own, so `counts` closes exactly when the last worker finishes:

```lua
local line_count = do(workers, path: CString): U32
    local total: U32 = 0
    io.open(path, io.READ) {
        done = do(file)
            tasks do(scope...)
                local chunks = pool(Chunk, 8)
                local filled = channel(Slot Chunk, 8)
                local counts = channel(U32, 8)
                spawn do
                    local more: Bool = true
                    while more do
                        local s = chunks:take()
                        io.read(file, chunks[s].bytes) {
                            done = do(n) chunks[s].n = n end,
                            failed = do(e) chunks[s].n = 0 end,
                        }
                        if chunks[s].n == 0 then
                            chunks:release(s)
                            more = false
                        else
                            filled:send(s)
                        end
                    end
                    filled:close()
                end
                -- the workers run in a scope of their own: when it ends, counts can close
                spawn do
                    tasks do(crew)
                        for _ = 1, workers do
                            crew.spawn do
                                filled:each(do(s)
                                    counts:send(count_lines(chunks[s]))
                                    chunks:release(s)
                                end)
                            end
                        end
                    end
                    counts:close()
                end
                counts:each(do(n)
                    total = total + n
                end)
            end
            io.close(file) { done = do() end, failed = do(e) end }
        end,
        failed = do(e) end,
    }
    return total
end
```

Count what chunking cannot split: a word can straddle two chunks, a newline cannot. The reads go straight into pool slots, and the slots move to the workers, so no byte is copied between tasks.

### 10.5 Choose, time out, block

`first_of` takes whichever operation completes first. It admits operations the runtime can take back: receives, sends, takes and timers:

```lua
        first_of {
            recv(replies) do(v) answer = v end,
            after(seconds(1)) do answer = 0 end,
            closed = do end,
        }
```

I/O is never a case, because the kernel's work cannot be taken back. Give an I/O operation a deadline, or spawn a task for it. A call into C that may block goes in `blocking do ... end`, so it never holds a worker.

### 10.6 When it goes wrong

* **Deadlock is reported, not hung.** The runtime names each wait with its source line.
* **Misuse traps**: a send on a closed channel, a stale handle, a slot used by a task that does not own it.
* **Cancellation is closing a channel.** There is no other mechanism, so no operation grows a third outcome.

## 11. Cost

Put cost requirements on the inner loops, codecs and engines that matter, then **read the C**: `luajit slc.lua program.slc` prints it. Know what stays:

* **A check nothing proves stays.** `first_or` keeps one, because the fact `i < xs.length` does not travel through the `Found` sum that carried `i` out:

```c
uint32_t first_or(U32Slice xs, uint32_t fallback) {
    Found r;
    uint32_t i = 0u;
    for (;;) {
        if (i >= xs.len) break;
        if (xs.ptr[i] != 0u) {
            r = (Found){ .tag = Found_found, .as.found = i };
            goto L1;
        }
        i = i + 1u;
    }
    r = (Found){ .tag = Found_missing };
L1:;
    if (r.tag == Found_found) {
        if ((uint64_t)r.as.found >= (uint64_t)xs.len) {
            slc_trap("slice index out of range");
        }
        return xs.ptr[r.as.found];
    }
    return fallback;
}
```

* **A check a branch proved goes.** The loop's own `xs[i]` has none: the loop condition proved `i < xs.length`.
* **Lookups are checked once per stretch.** `store[id]`, `g[i]` and `pool[slot]` look again after anything that could change the answer (a structural change, a slot moving, a call into C, a loop round), and not otherwise.
* **Waits are calls.** Every channel operation, take, sleep and I/O operation is a visible call into the runtime.
* **Allocation is in the runtime, and only there.** Task frames, channels and pools are allocated by the runtime. Stores and Grow arrays live on data stacks. Plain words allocate nothing.

---

# Part II — Style

## 12. Naming

> **A name is a promise. A vocabulary is a set of promises spoken together.**

**PascalCase for types, including built-ins; snake_case for words and values.** slc's own types already do: `U32`, `Store`, `Chan`, `Pool`, `Slot`, `Array`.

| Role | Convention | Examples |
|---|---|---|
| entity or value type | PascalCase noun | `Document`, `Heading`, `Command` |
| activity context type | PascalCase activity name | `Editing` |
| instance or parameter | snake_case role | `document`, `outline` |
| action | imperative verb | `insert`, `apply`, `release` |
| transformation | participle or adjective | `trimmed`, `translated` |
| query | the thing returned | `line_count`, `tab_stop` |
| predicate | proposition | `at_end`, `has_selection` |
| activity word | purposeful word, or `with_` + resource | `transaction`, `counted`, `with_file` |
| activity block parameter | gerund | `editing`, `importing` |
| sum alternative | snake_case outcome | `found`, `missing`, `done`, `timed_out` |
| library | snake_case domain | `io`, `posix` |

**Let the receiver carry the subject**: `document:move_left()`, not `document:move_document_left()`. **Name for the call site**: no unexplained flags; prefer two words or a sum. **Collisions are design feedback**: when `spread-shadow` fires, ask whether two activities are mixed, a name is too generic, or a homonym should stay qualified (`do(crew)` instead of `do(crew...)` inside an opened scope).

## 13. Spelling forms

| Form | Use |
|---|---|
| literal argument | readable fixed configuration: `insert 5`, `tab_stop { tab_width = 4 }` |
| parentheses | computed values, explicit argument lists |
| `word()` | nullary invocation |
| trailing block | scopes, iteration, activities |
| headed braces | construction (`Document { ... }`) or handlers (`s { ... }`) |
| `do(x) = e` | a small expression lambda |
| `do(x) ... end` | a callback with statements |
| `endall` | the closing run of a trailing-block spine |
| `local x: T = e` | a typed local: runtime storage |
| `local x = e` | a binding: a name for a value |

Prefer explicit parenthesized calls when a computed result matters to the surrounding expression. Literal postfix chains obey their precedence; when in doubt, parenthesize.

## 14. Formatting

* Four-space indentation; lines up to about 110 columns; one blank line between top-level words.
* Keep `do` on its owning call's line; align `end` with its opener.
* For a flat spine, align the opening calls and the final `endall`; indent the innermost body once.
* Space binary operators; keep calls and spread markers tight.
* Multiline braces take a trailing comma.
* `export name` directly after the word it exports.
* Imports first.

## 15. Files and libraries

* **A file is a vocabulary or a program.** A program file defines its words and exports its edges. A library returns ordinary Lua values through `require`. Bundled vocabularies live in `lib/` and use names such as `require "slc.io"`; project modules use their own names. Lua's `require "io"` still names Lua's I/O library. See [module loading](modules.md) for paths and compilation lifetimes.
* **Newspaper order:** imports; types; exported words, each with a one-line promise; private helpers.
* **Dependencies point toward the domain.** Activities use entities; entities do not import every activity that can operate on them. A free `transaction(document: Ref Document, body)` lives beside `Document` without growing it.

## 16. Comments

Explain why when the code says what. State what a signature cannot: an invariant, an ownership obligation, a cost condition. Give each exported word one sentence of promise. An overview of a subtle engine saves the reader a reconstruction; write it.

## 17. Anti-patterns

| Anti-pattern | Prefer |
|---|---|
| hand-unrolling, or a second specialized copy of an engine | a host loop or a compile-time parameter over one engine |
| a runtime parameter for configuration known before run time | an untyped parameter: a Lua table |
| `dynamic(e)` to "help" the compiler | nothing; `dynamic` only makes a key repeat on purpose |
| an extra word kept "for inlining" or avoided "for performance" | the word the meaning wants; evaluation inlines |
| references or slices stored in structs | `Id`s, or a `Ptr` at a foreign boundary |
| locks or atomics to coordinate tasks | channels for messages, pools for buffers |
| a task that writes its spawner's locals | a message back, or results collected in the scope body |
| a closer that guesses when workers are done | a scope of their own: close when it ends |
| I/O raced in `first_of` | a deadline, or a task that sends its result |
| a blocking C call in a task | `blocking do ... end` |
| ignoring an outcome | handle it: the match is exhaustive for a reason |
| a magic value for absence | a sum |
| counting what a chunk boundary can split | count what it cannot, or carry state across chunks |
| assuming a check vanished | read the C |

## 18. Review checklist

* **Binding time:** what is known while compiling? Is it still known where it is used?
* **Names:** do calls read as sentences? Are activity parameters gerunds and subjects nouns?
* **Ownership:** who owns each mutable thing? What does each `Ref` reach, each `Id` name, each `Slot` move?
* **Activities:** who sets up, completes, commits or rolls back?
* **Outcomes:** is every actionable result a sum, and every arm handled?
* **Concurrency:** does anything cross a task except copies and moves? Does each scope end, and who closes each channel?
* **Edges:** are effects opened at the outside and passed in?
* **Cost:** have you read the C for the inner loops? Have you measured what matters?
* **Tests:** do the harness and the compile-time asserts exercise the contracts?

## 19. Status

The forms and libraries in this guide are implemented in the prototype and exercised by `examples/guide.slc`. The specification marks what is not: §36.12 for concurrency and I/O (work stealing; kqueue verified only through libkqueue on Linux), §26 for exclusions. Formatting and naming here are house conventions, not grammar.

## Maxim

> **Model the values. Own the state. Name the words. Enter the activity. Open the context to work with it; bind a value to remember it. Specialize what is known; share nothing between tasks; read the C.**
