# Staged Lua → C
## Language Semantics and Compiler Architecture

**LuaMacro · LuaJIT · Online Partial Evaluation · Reified Commands · Goose Memory · C**

**Design Proposal — v0.5**

*This document specifies the language, its compilation semantics, its memory model and the reasons behind them. v0.5 closes the design gaps found in v0.4 and is checked against a working prototype (Appendix A): every C listing below is the prototype's actual output, not an illustration (the one exception, a calling-convention sketch in §16, says so). Where the prototype does not yet implement something the design calls for, the text says so.*

---

# What changed from v0.4

The resolutions, in the order they matter:

1. **Typed bodies are parsed, not token-juggled.** Lua metamethods cannot stage comparisons (their results are coerced to booleans, and `__eq` only fires between two tables), `and`/`or`, conditions, local assignment or `return`. A typed body is therefore parsed with Lua's grammar and precedence, and each of those constructs becomes a staged operation (§7).
2. **Application has one precise rule (§3.3).** Literals, tables, strings and lambdas attach as arguments on any line; a *name* attaches only on the same line, after a name. A newline ends an application chain before any token that can begin a statement. An argument is a primary expression with its full Lua postfix chain, so `add Node { value = 42 }` is `add(Node { value = 42 })`, and an empty store is written `Store(Node) {}` (v0.4 used both readings).
3. **Annotations live in five places only**: struct fields, parameters, result types, `local x: T` and typed `for`. The bare statement `x: U32` is gone (it collided with method calls).
4. **A lambda is a native word exactly when it declares a result type** (§3.4). All its parameters must then be typed; typed parameters without a result type are an error.
5. **Inlining is not a decision.** Saturated application evaluates the callee's body in place. A C function boundary appears for exactly two reasons: an export, or a specialization key re-entered during its own evaluation in non-tail position (§12); a tail re-entry is a loop (§9). Non-termination (keys that never repeat) and materialization (keys that repeat) are one rule about keys; `dynamic(e)` makes a key repeat.
6. **Typed places store lazily (§8.3).** A store whose value depends only on immutable leaves stays pending in the abstract state; storage is written only when a join, a loop, an escaping address or a read of changed storage requires it. This is what makes private structs disappear.
7. **Struct places are tracked field by field (§8.4)**, so a partly known struct is partly static.
8. **Untyped bindings take values, lazily (§8.5).** `local a = y` names `y`'s current value. If `y` is later overwritten while `a` is alive, a snapshot is written at the point of the binding, and only then.
9. **Host rebinding is checked where it can go wrong (§8.6)**: inside a branch whose condition is dynamic, or the body of a residual loop. Assigning a binding declared outside the typed body is rejected statically.
10. **Loops are tail recursion (§9).** `return f(...)` is a tail call. A tail re-entry runs at compile time while each round stays known; otherwise the known arguments that changed are generalized and it becomes a jump — a loop in place, or a jump to the top of a function. `while` and typed `for` are sugar for anonymous tail-recursive loops, with `break` and `continue`; the typed locals a loop mentions are its explicit parameters (§9.4). Typed bodies are deterministic and stage-safe, so a round can be rolled back and redone in general form.
11. **One generalization rule (§12.4)**: a re-entry of the same word and shape under dynamic control generalizes the known arguments that changed; under known control it keeps unfolding. Recursion with a dynamic termination test no longer needs `dynamic(...)`.
12. **A reference denotes its place (§14)**: it reads its target, and assigning to a name that holds one writes the target.
13. **Resizable storage has a defined storage class (§15–§18).** Stores and Grow arrays are created in place, take the lowest free data-stack index, give it back when their block ends, move only by reference, and are never assigned, returned or copied.
14. **Activities, opening and spread (§30)**, after Let's design guide and `spread.md`: untyped lambdas in typed bodies are callbacks evaluated in place; untyped parameters of native words are compile-time parameters; saturating chains; `do(ctx...)`, `local ctx...` and live field places; keyed spread, rest packs and ordered spread; `endall`.
15. **Sums and matching (§31)**, after Let's `syntax.md` §8.1: `oneof`, constructors, matching as keyed application with exhaustive handlers; a known tag selects its handler while specializing, a runtime tag becomes a test per alternative printed as a `switch`.
16. **Raw pointers and slices (§32)**, after Let's §8.4–8.5: `p[i]`, `p.field`, `Ptr(place)`, `null(T)`, `==` and nothing else; read-only checked slices whose known indices are checked at compile time; `Grow:view` as an activity.
17. **libc as activities (§33)**: opaque C types, `CString`, variadic externs, formats built while specializing, Lua's `require`; `lib/libc.slc` wraps files and heap buffers as activities.
18. **POSIX and Linux as activities (§34)**: structs and constants from system headers, errno reads, `bytes`/`size_of`; `lib/posix.slc` wraps descriptors, mmap views, eventfd and epoll, with outcomes as sums.
19. **Atomics (§35)**: `Atomic T` accessed only by atomic operations, memory orders checked while compiling, fences, `atomic_ptr` for shared memory; a spinlock activity and an io_uring-shaped ring, checked with threads under ThreadSanitizer.
20. **Tasks, channels and I/O (§36)**: Go's model rather than a race checker. Tasks share no memory: `spawn do` copies what it mentions, channels carry copies, and pool slots move. Tasks compile to resumable state machines, so no function coloring is needed. Every wait is an operation, `first_of` chooses among those the runtime can withdraw, and I/O is by completion through `require "slc.io"`, with backends for `poll`, io_uring and kqueue. Scopes own tasks, channels and pools; deadlocks are detected exactly.
21. **Slots are addressed with `[]` (§18, §30.6, §36.6)**: `s[id]`, `g[i]` and `pool[slot]` are places whose address is recomputed and checked at every use, replacing `get`, `set` and the `with` activities. A store may grow while its slots are in use, since nothing holds an address across the change.
22. **Fixed-length arrays (§37)**: `Array(T, n)`, a value checked like a slice, viewed as one, and the buffer type of pools and I/O.
23. **§25 curried the wrong parameter**: `populate(g, scale, n)` partially applied to `2` bound `g`. The parameter order is now `(scale, g, n)`.
24. **A second backend, in process (§38)**: the same prepared IR built with libgccjit, which mirrors the C emitter call for call and reads the C the compiler contains (runtime header, helpers, templates) instead of copying it. `native(word)` compiles a word into executable memory now and returns it as a Lua function, so values that exist only at start-up can be specialized on; `slc run` runs a program that way.
25. **Text (§39)**: `Str` views, `Text` built in place with formatting decided while compiling, `Chars(n)` values; the text words are slc, so known text folds and known needles unroll. Range facts now include lower bounds by constants, and an arm that cannot fall through lends its facts to what follows. Field and method access in typed bodies no longer collides with the evaluator's own keys (a struct field named `name` used to read the local's name).

26. **Library-defined types (§41)**: a type's layout is a `struct`; what `x.f`, `x[k]`, a conversion, an operator or a comparison means on it is a hook, a Lua function or native word run while specializing. The built-in kinds are served by the same hooks, so a library can define a fixed-point number, a ring buffer or a struct-of-arrays with no compiler change.
30. **The runtime is built with the program (§42.4) and `first_of` is sequenced where it is written (§36.4)**: a program's C carries the runtime words it reaches and links only `slc_rt.c`; a two-case select runs 2.4 times faster.
29. **`call` (§12.7)**: a keyword before an application that makes it a function boundary, shared by specialization key; `slc size` reports where one would pay. The map and data-stack libraries use it at seven large steps.
28. **Native globals and function values (§42)**: `global(T, opts)` is static (or thread-local) storage reached as a `Ptr T`; `Fn(params): ret` is a C function pointer and `fnptr(word)` materializes a word as one. With them the whole runtime is SLC: the scheduler, tasks, workers, registries, timers, blocking threads, entropy and the I/O bootstraps compile with the program's other SLC words; C keeps `setjmp` traps, address location in a data stack and the io_uring kernel ABI. The data-stack set and the hash key are read in place by programs.
27. **Field shorthand (§3.3)**: `.name` in a table constructor is `name = name`.

---

# 1. Vision

We propose a small, staged systems-programming language built on Lua and LuaMacro.

The language uses ordinary Lua for compile-time computation, native typed words for runtime computation, and **online partial evaluation** to determine which computations can be completed during compilation and which must be residualized into C.

The native memory model follows Goose: ordinary values have structured, scope-owned storage, resizable values use compiler-assigned data stacks, and references have statically proven lifetimes.

Managed stores provide independently recyclable objects, with generational IDs representing long-lived relationships without creating ownership edges.

The language has five essential mechanisms:

1. **LuaMacro provides a unified surface language.** Typed functions, annotations, methods, declarations and control flow look like natural extensions of Lua. Typed bodies are parsed with Lua's grammar so that every construct Lua cannot overload can be staged.
2. **LuaJIT executes compile-time computation.** Lua functions, closures, tables, generics and higher-order generators construct and specialize programs.
3. **Native words specialize through application.** Partial application binds known arguments; saturated applications evaluate the word's body with every argument, known or not.
4. **Online partial evaluation constructs residual code.** Known operations compute immediately. Unknown operations produce typed commands. The same computation can do both.
5. **Goose-style memory analysis assigns native storage.** Lexical ownership, borrowed references, stores and data-stack requirements are checked and lowered to C for the residual program.

The generated executable has no LuaJIT dependency, no tracing garbage collector, no reference-counting system and no implicit heap promotion.

The central principle is:

> **Lua computes what is known. Commands represent what remains. Words progressively specialize computation. Goose determines where the residual values live. C executes the result.**

---

# 2. The complete compilation pipeline

```text
                       SOURCE
                Lua + typed extensions
                          |
                          v
                LUAMACRO + macro.let
         Application, lambdas, struct, export.
      Typed bodies are parsed (Lua's precedence)
        and translated into staged operations
                          |
                          v
                      LUA CODE
              Words, types, delayed closures
                          |
                          v
                        LUAJIT
              Compile-time computation
                   Word application
                          |
                          v
                ONLINE PARTIAL EVALUATOR
                 ┌──────────────────┐
                 │ Known operations │──→ Results
                 │ Dynamic operands │──→ Residual commands
                 │ Known branches   │──→ Selected computation
                 │ Dynamic branches │──→ Residual control flow
                 │ Native effects   │──→ Residual effects
                 │ Re-entered keys  │──→ C function boundaries
                 └──────────────────┘
                          |
                          v
                    RESIDUAL IR
                          |
                          v
                 GOOSE MEMORY ANALYSIS
                   Data-stack indices
                  Release at block ends
                 Store/ID validation
                    Recursion bounds
                          |
                          v
                      C BACKEND
                          |
                          v
                   NATIVE EXECUTABLE
```

**Residualization is not a secondary optimization pass. It occurs as staged computations are constructed and specialized.**

The memory analyzer and the C backend operate on the remaining native program, after static computations and unreachable branches have been eliminated. Only functions reachable from exports are emitted.

---

# 3. A unified surface language

The surface language retains Lua's ordinary vocabulary wherever possible.

It uses:

- `local` and `=` for bindings.
- `:` for type annotations and method syntax.
- `do` for lambdas.
- `function` for named functions and methods.
- `if`, `for` and `while` for control flow.
- Tables for Lua data and native construction syntax.
- Juxtaposition for application.

No source-level `emit`, `set`, `var`, `comptime`, `template` or `specialize` keywords are required. The language adds two words, `struct` and `export`, and a handful of prelude functions (`extern`, `dynamic`, `host`, `Ref`, `Ptr`, `Slice`, `null`, `opaque`, `cformat`, `cstruct`, `cconst`, `cread`, `bytes`, `size_of`, `view_of`, `Atomic`, `fence`, `atomic_ptr`, and the bitwise operations `band bor bxor shl shr bnot`, which Lua 5.1 has no operators for).

## 3.0 Modules are Lua values

Modules use Lua's actual `require`, not a separate import API. `require "slc.hash"`
loads a bundled SLC vocabulary; `require "model"` loads a project module;
`require "io"`, `require "ffi"` and other Lua modules retain their Lua meaning.
An SLC loader translates `.slc` source and evaluates it in the SLC prelude,
returning ordinary Lua values through the standard module machinery.

During compilation, the program's directory is prepended to the Lua source path
as `?.lua` and `?/init.lua`. The existing preload, Lua, C and custom searchers
keep their order and precedence. An appended SLC searcher checks bundled
`slc.*` names in `lib/`, then follows the current Lua source-path templates with
`.slc` in place of `.lua`. Dots in module names denote directories. A found
module's syntax or evaluation error is an error, not permission to try another
candidate. Lua owns cache hits, no-value results, explicit `package.loaded`
publication, false results, and cycle/previous-load-error diagnostics.

Each compilation uses a fresh `package.loaded` table, also installed as the Lua
registry's loaded table, seeded with existing host modules. Newly loaded Lua,
SLC and C modules remain in that compilation's cache; this includes Lua wrappers
which retain SLC words. Compiler implementation modules have host lifetime.
Host loader/cache tables and source/native paths are restored on success and
failure. This is not a sandbox or a deep copy of host module values: explicit
host-global effects and mutations of existing host modules are shared. The
compiler's staging state is single-context; nested compilation is rejected.

See [modules.md](modules.md) for the design, examples and acceptance checks.

## 3.1 Types are compile-time values

```lua
local Vec2 = struct {
    x: F32,
    y: F32,
}

local Player = struct {
    position: Vec2,
    health: U32,
}
```

`Vec2` and `Player` are Lua bindings to native type objects.

The `struct` operation constructs a type description. It does not immediately generate C; a struct is emitted only if residual code uses it.

Annotations appear in exactly five places:

```lua
struct { x: U32 }               -- struct fields
do(x: U32): U32 = ...           -- parameters and result types
function T:m(n: U32): Unit      -- the same, on named functions and methods
local y: U32 = x                -- typed locals
for i: U32 = 1, n do ... end    -- typed (native) loops
```

An ordinary Lua table remains ordinary Lua data:

```lua
local t = { x = U32 }
```

It is not a struct declaration merely because its value happens to be a type.

*v0.4 also allowed a bare declaration statement `x: U32`. It is removed: it cannot be told apart from a method call `x:U32 ...`, and `local x: U32` covers it.*

## 3.2 Generic types are ordinary Lua functions

```lua
local Pair = do(A, B) = struct {
    first: A,
    second: B,
}

local IntPair = Pair(U32, U32)
local MixedPair = Pair(U32, F64)
```

`Pair` is an ordinary compile-time Lua function.

No native generic representation exists at runtime.

Its result is a specialized native type object.

## 3.3 Application

Application is juxtaposition, extending macro.let:

```lua
local Numbers = Grow U32
local NodeRef = Ref Node
local fifteen = triangular 5
local times8 = choose(true, 8)
```

and constructor-headed arguments:

```lua
self.nodes:add Node {
    value = 42,
}
```

which means:

```lua
self.nodes:add(Node { value = 42 })
```

The rules:

1. **What can be an argument.** After a callable expression, these start an argument: a number, a string, `true` or `false`, a table constructor, a `do` lambda — on any line — and a **name**, only on the same line and only directly after a name (or after a name argument).
2. **The newline rule.** A newline ends an application chain before any token that can begin a statement. Names and `(` can begin statements, so `local y: U32 = x` followed by `y = y + 1` on the next line stays two statements. Literals, tables and lambdas cannot begin statements, so they still attach across lines.
3. **What an argument is.** A primary expression with its full postfix chain, exactly as Lua parses it: `.name`, `[i]`, `:m args`, `(args)`, and for a name, a table constructor or string. So `f a.b` is `f(a.b)`, `f a(b)` is `f(a(b))`, and `add Node { ... }` is `add(Node { ... })`. A literal's chain stops at a table or string (`f 21 {}` is `f(21)({})`).
4. **Left associativity.** `f a b` is `f(a)(b)`. Application binds more tightly than infix operators: `f a + 1` is `f(a) + 1`, and `f -1` is subtraction.
5. **Brackets** group, delimit argument lists and resolve ambiguity: an empty store is `Store(Node) {}` or `(Store Node) {}`; `Store Node {}` would apply `Store` to `Node {}`.
6. **Loop headers.** The `do` of a `while` or `for` header ends the header; a lambda inside a header goes in brackets: `for x in each(xs, do(x) = x > 0) do`.
7. **Saturating chains.** `f(a) do ... end` on a word accumulates arguments until the word is saturated (§30.4).
8. **Statements on one line.** Two statements on one line where the first ends with a name and the second begins with one (`a = b c = d`) form an application; separate them with `;`. `f() g()` is unaffected: a name after `)` is not an argument.
9. **Field shorthand.** In a table constructor, `.name` is `name = name`: `Point { .x, .y, z = 3 }` is `Point { x = x, y = y, z = 3 }`. A `.` never follows `{`, `,` or `;` in Lua, so no existing program changes. The shorthand is rewritten in the token stream, so it works in typed bodies and in the plain Lua code around them, and it is only spelling: the program is the one the long form writes. A bare `{x}` is not a shorthand, because it is already a one-element array table.

The syntax remains independent of the runtime arity of the callee.

## 3.4 Words and host functions

A lambda is a **native word** exactly when it declares a result type:

```lua
local inc  = do(x: U32): U32 = x + 1        -- a native word
local wrap = do(x) = { value = x }          -- a Lua function
local bad  = do(x: U32) = x + 1             -- error: typed parameters need a result type
```

Inside a typed body, an untyped lambda is a callback, evaluated in place (§30.1).

A word's untyped parameters are compile-time parameters (§30.2), and a word may end with a rest requirement `...args` (§30.8). The same holds for named functions: `function T:m(n: U32): Unit ... end` defines a method word on struct `T`, and `local function f(n: U32): U32 ... end` a word that may name itself.

---

# 4. Ordinary Lua and native words

The language distinguishes **host computation** from **native computation**, but both are written in familiar Lua syntax.

## 4.1 Ordinary Lua

```lua
local make_multiplier = do(k)
    return do(x: U32): U32 =
        x * k
end

local double = make_multiplier 2
local triple = make_multiplier 3
```

`make_multiplier` is an ordinary Lua closure. It executes inside LuaJIT.

The returned typed lambdas are native words. The value `k` is captured as a compile-time constant.

## 4.2 Native typed words

```lua
local add = do(a: U32, b: U32): U32 =
    a + b
```

The typed lambda constructs a native word with two typed requirements. Its body describes operations in the native type system. A word may be applied to known values, dynamic values, or a mixture of both.

## 4.3 Type annotations identify native semantics

Typing does not automatically mean runtime execution. A typed computation can be completely evaluated during compilation; a typed computation with unknown inputs is partly evaluated, leaving only the dynamic remainder.

> **Types determine native semantics. Knownness determines binding time.**

---

# 5. The word model

A native word contains:

```lua
Word = {
    identity = ...,
    requirements = ...,
    result = ...,
    body = ...,
    supplied = ...,
}
```

This is a conceptual description, not a required object layout.

A word's `body` is a Lua closure produced from the typed body. That closure expresses native computation through staged operations. Its captures are ordinary Lua upvalues.

Its identity is stable across aliases and partial applications.

## 5.1 Autocurrying

```lua
local affine = do(
    a: U32,
    b: U32,
    x: U32
): U32 = a * x + b

local transform = affine(4, 3)
```

The first application supplies two requirements. The word is not saturated, so the result is a word with the static bindings `a = 4`, `b = 3` and the remaining requirement `x: U32`.

No runtime closure is constructed.

## 5.2 Saturated specialization

```lua
local use = do(x: U32): U32 =
    affine(4, 3, x)
```

The call to `affine` is saturated, with `a` and `b` known. Application evaluates `affine`'s body with those arguments:

**Every saturated application uses all known arguments, not only those previously captured by partial application.**

```c
uint32_t use(uint32_t x) {
    return 4u * x + 3u;
}
```

## 5.3 Fully known execution

```lua
local answer = affine(4, 3, 10)
```

Applied from host code with every argument known, the body is evaluated entirely at compile time and produces `Known(U32, 43)`. The result remains a typed known value inside the compiler rather than silently losing its native type; `host(answer)` returns the Lua number.

Applying a word from host code with an argument that is not known is an error: there is no native function for the dynamic remainder to live in.

## 5.4 Partial application rules

- Supplying fewer than the remaining requirements produces a word only when the supplied arguments are static (known scalars, or fully known struct values). References are never static.
- A saturated application evaluates the body (§12).
- A dynamic argument cannot be bound into an incomplete word.
- Overapplication is accepted when the result is itself callable: `f(a, b)(c)`.
- Arguments are coerced to the requirement's type at application: a Lua literal takes the requirement's type (with a range check), a place is read, and a `Ref T` requirement takes a place of type `T` by reference.

---

# 6. The partial-evaluation pattern

The evaluator uses **staged values, Lua closures and smart constructors**.

The fundamental native-value domain is:

```text
Value(T)
    Known(T, value)
    Dynamic(T, expression)
    Aggregate(T, field → Value)      -- struct values, field by field
    Ref(T, place)                    -- a compile-time handle to a place
```

`Known` contains an actual typed compile-time value. `Dynamic` contains an expression for computation that must remain in the native program. An `Aggregate` is known when all its fields are; a partly known struct is partly static.

## 6.1 Smart constructors

```lua
local function binary(op, T, a, b)
    if a:is_known() and b:is_known() then
        return Known(T, native_compute(op, T, a.value, b.value))
    end
    return Dynamic(T, Binary(op, a:reify(), b:reify()))
end
```

`native_compute` implements the target's rules for the operation (§10.1); it is not unrestricted Lua arithmetic. Integer identities are applied while constructing (`x + 0`, `x * 1`, `x * 0`, `x / 1`), and division by a known zero is rejected even when the other operand is dynamic.

```text
Known(4) + Known(3)    → Known(7)
Dynamic(x) + Known(3)  → Add(x, Const(3))
```

The programmer does not request constant folding. It occurs as operations are constructed.

## 6.2 Lua metamethods

Arithmetic (`+ - * / %` and unary `-`) uses metamethods on values and places:

```lua
local body = function(a, b, x)
    return a * x + b
end
```

With known arguments this computes a known result; with unknown arguments it constructs a residual expression. The same closure supplies both behaviours. That is the core of **online partial evaluation by evaluation**.

Metamethods cannot do everything. Comparison metamethods (`__eq`, `__lt`, `__le`) have their results coerced to a Lua boolean, so they can never return a staged `Compare`; `__eq` fires only between two tables, so `Dynamic(x) == 3` would silently be `false`. Comparisons are therefore staged by the typed-body translation (§7), like `and`, `or` and conditions.

## 6.3 Why this is not simply AST interpretation

A traditional partial evaluator constructs a full program representation and walks it. Here, most specialization happens while the Lua closures that represent the program execute: known arithmetic never becomes a residual node, unknown arithmetic creates exactly the necessary expression, and known branches evaluate only their selected computation.

This does not remove the need for structured commands or an abstract state. It moves most of specialization into ordinary Lua execution.

---

# 7. Typed control flow

## 7.1 What the translation stages

Lua cannot overload:

- comparisons (results coerced to booleans; `__eq` between tables only),
- conditions (they need a concrete truth value),
- `and`, `or` and `not`,
- local assignment,
- `return` (it exits the actual Lua function).

A typed body is therefore parsed — a recursive-descent parser with Lua's precedence over the LuaMacro token stream — and translated:

| Source | Staged form |
|---|---|
| `a < b`, `a == b`, ... | `stage.lt(a, b)`, `stage.eq(a, b)`, ... |
| `a and b`, `a or b` | `stage.and_(a, function() return b end)` |
| `not a` | `stage.not_(a)` |
| `if c then A else B end` | `stage.if_(c, function() A end, function() B end)` |
| `while c do B end` | `stage.while_(function() return c end, function() B end)` (a loop, §9.3) |
| `for i: T = a, b do B end` | `stage.for_(T, a, b, step, function(i) B end)` (a loop, §9.3) |
| `break`, `continue` | `stage.loop_break()`, `stage.loop_continue()` |
| `local y: T = e` | `local y = stage.decl(T, e)` |
| `y = e` (typed `y`) | `stage.set(y, e)` |
| `obj.f = e` | `stage.setindex(obj, "f", e)` |
| `local a = e` | `local a = stage.bind(e)` |
| `return e` | `stage.ret(e)`, then leave the closure |
| `return f(args)` | `stage.tail(f, args)`: a tail call (§9.2) |
| `do(x) ... end` (untyped) | `stage.callback(...)`: evaluated in place (§30.1) |
| `f(a)(b)`, `f(a) do ... end` | `stage.chain(f, ...)`: a saturating chain (§30.4) |
| a free name, a bare call or an assignment in an opened region | resolved against the opened contexts (§30.5) |
| `...e`, `T { ...p, x = 1 }` | `stage.expand`, `stage.keyed` (§30.7, §30.8) |
| `oneof { ... }`, `s { alt = handler, ... }` | `stage.oneof`, matching (§31) |
| `p[i]`, `s[i]`, `Ptr(place)`, `Slice(p, n)` | element places and checked reads (§32) |

Arithmetic, calls, field access and constructors stay ordinary Lua expressions; metamethods handle them.

Every staged operation also accepts host values with host semantics: `stage.lt(1, 2)` is `true`, and `stage.and_` keeps Lua's value semantics for host operands. So the same translated body serves generation-time code and native code.

## 7.2 Native conditionals

```lua
local choose = do(
    enabled: Bool,
    k: U32,
    x: U32
): U32

    if enabled then
        return x * k
    end

    return x + k
end
```

The binding time of a condition decides what happens:

- **A host value** (a Lua boolean, a number, a table): plain Lua control flow. Nothing is speculative.
- **A known `Bool`**: only the selected branch is evaluated.
- **A dynamic `Bool`**: both branches are evaluated, each against its own copy of the abstract state, and a residual `if` is emitted.

A native condition must have type `Bool`; native values have no truthiness.

After a branch returns, its path is dead. A conditional whose branches are all dead leaves the rest of the enclosing body dead, and the translation stops evaluating it.

### Known condition

```lua
local times8 = choose(true, 8)
```

```c
uint32_t times8(uint32_t x) {
    return x * 8u;
}
```

### Known complete invocation

```lua
local answer = choose(true, 8, 7)     -- Known(U32, 56)
```

### Unknown condition

```lua
local use = do(flag: Bool, x: U32): U32
    return choose(flag, 8, x)
end
```

```c
uint32_t use(bool flag, uint32_t x) {
    if (flag) {
        return x * 8u;
    }
    return x + 8u;
}
```

`choose` was evaluated in place. Its returns jumped to the end of its application and were then turned into direct returns, because the result was returned immediately (§13.2).

## 7.3 Branch-local state

```lua
local f = do(flag: Bool, x: U32): U32
    local y: U32 = x

    if flag then
        y = y * 2
    else
        y = y + 1
    end

    return y
end
```

When `flag` is dynamic, both branches are residualized, each against its own state. At the join, `y` differs between the branches, so each branch writes its pending value (§8.3) and `y` becomes dynamic:

```c
uint32_t f(bool flag, uint32_t x) {
    uint32_t y;
    if (flag) {
        y = x * 2u;
    } else {
        y = x + 1u;
    }
    return y;
}
```

The initial `y = x` never reaches storage: it was pending, and both branches overwrote it.

## 7.4 Boolean operators

`and` and `or` keep short-circuit semantics through a delayed right-hand closure.

- With a known left operand, the right side is evaluated only if the result depends on it.
- With a dynamic left operand, the right side is first evaluated speculatively. If it performs no effects and changes no state, the result is the residual expression `a && b`. Otherwise a real conditional is built into a `Bool` local, so the effect happens only on the path that reaches it.

## 7.5 The staging discipline

Typed bodies must be deterministic and stage-safe: the evaluator may run a closure more than once (both branches of a dynamic condition, a round that is rolled back and redone in general form, an application undone to make a recursive key a function). Therefore:

- A typed body can assign only bindings it declares. Assigning a variable declared outside it (a host upvalue or global) is rejected when the body is translated.
- Rebinding a host binding declared outside the current branch is an error when that branch's condition is dynamic, or inside the body of a residual loop (§8.6).
- Mutating a host table from inside a dynamic branch or a residual loop is an error.
- Arbitrary Lua I/O and opaque FFI effects belong in host code, outside typed bodies.

These are precise rules, checked where the problem can occur, not a blanket ban: host control flow and known branches may rebind host bindings freely.

---

# 8. Native state and mutation

The evaluator distinguishes **values** from **addressable places**.

## 8.1 Local types can be inferred

```lua
local f = do(x: U32): U32
    local k = 4
    local y = x * k

    return y + 1
end
```

`k` is a host number. `y` infers `U32` from its initializer and is a mutable native place, just as with `local y: U32 = x * k`. Inference depends on the initializer's native type, not whether its value is known. Lazy stores still eliminate unnecessary C variables:

```c
uint32_t unannotated(uint32_t x) {
    return x * 4u + 1u;
}
```

Inside staged bodies, `local name = expression` infers native storage whenever the initializer can inhabit a native local. Constructors need no repeated annotation: `local p = Point { x = 1, y = 2 }`, `local count = U32 0`, and `local out = Text {}`. Assignments keep the inferred type, including inside runtime branches and loops. Multiple locals can infer independently; explicit and inferred annotations can be mixed.

Plain Lua values remain host bindings: `local k = 4` does not invent a native integer type. An annotation is still needed to select a different type or declare uninitialized native storage. A later assignment does not retroactively infer a host binding's type. Outside staged evaluation, ordinary Lua bindings are unchanged.

Initializing from a native place takes its value at that point (§8.5), not an alias. References retain write-through behavior. Borrowed views and existing resizable storage retain their existing alias and lifetime rules: inference does not copy them into new storage. Fresh resizable constructors initialize their inferred storage in place.

## 8.2 Typed locals are places

```lua
local f = do(x: U32): U32
    local y: U32 = x
    y = y + 1
    return y
end
```

`y` denotes an addressable native place, assignment becomes a staged store, and the abstract state tracks the place's current value:

```c
uint32_t typed_local(uint32_t x) {
    return x + 1u;
}
```

Parameters are immutable values. To modify one, copy it into a typed local.

## 8.3 Lazy stores

For each tracked place the abstract state holds one of:

```text
pending(v)        the value is v; storage need not hold it yet
materialized(n)   storage holds the value (version n); reads read storage
uninitialized     declared, not yet written
```

A store is **pending** when its value depends only on immutable leaves — constants, parameters, temporaries, loop variables — and is small. Otherwise it is emitted at once and the place becomes materialized with a new version.

A pending value is written to storage only when something needs storage to hold it:

- a join where the paths disagree (each path writes its own value),
- entry to a residual loop that writes the place, and every back edge,
- an address that leaves the evaluator (a `Ref` passed to a materialized function or a foreign call),
- a return that jumps out of an inlined application.

Reading a pending place returns its value directly, so private computation through places costs nothing. Reading an uninitialized place is an error.

## 8.4 Structs are tracked field by field

A typed local of struct type is a set of field places, each tracked on its own. A struct value is an aggregate of field values, and a struct constructor stores field by field. A local struct that never has its address taken and is never read as a whole needs no storage at all; this is how `NumberBox` disappears in §24.

A struct is materialized as a whole only when C needs the whole: passing it by value to a materialized function, for instance, reads as the place itself when all its fields are in storage, and as a compound literal otherwise.

## 8.5 Snapshots

```lua
local snapshot = do(x: U32): U32
    local y: U32 = x * 3
    if x > 10 then
        y = y + 1
    end
    local a = y
    y = y * 2
    return a + y
end
```

`local a = y` infers a separate `U32` place initialized with `y`'s value. `y` is in storage at that point (it differs between the branches), so initialization snapshots that read. Later writes to `y` do not change `a`:

```c
uint32_t snapshot(uint32_t x) {
    uint32_t y;
    if (x > 10u) {
        y = x * 3u + 1u;
    } else {
        y = x * 3u;
    }
    uint32_t a = y;
    y = y * 2u;
    return a + y;
}
```

If `y` is still a pending value, the inferred local can also remain pending without a C variable. Arguments of inlined applications use lazy snapshots: `counter:add(i)` reads `i` directly unless the callee writes `i` first.

Reads through pointers (untracked storage) are snapshotted at once. As a safety net, every read of a tracked place carries the place's version; a residual statement that would use a read older than the place's current contents is rejected rather than emitted.

## 8.6 Host rebinding

Host bindings may be rebound in generation-time code. Inferred native locals are places, not host bindings. Inside a body:

- rebinding a binding declared **outside a dynamic branch** from inside it is an error: both branches are evaluated, so the Lua variable would end up holding the second branch's value;
- rebinding a binding declared **outside a loop** from its body is an error once the loop is residual: the round may be rolled back and redone, and a Lua variable cannot carry runtime state. Rounds that run at compile time may rebind freely.

Native mutation that must survive such constructs uses a typed place. Known branches and host control flow are not speculative, and rebinding there is fine.

## 8.7 Abstract native state

```text
AbstractState:
    tracked place → pending(v) | materialized(version) | uninitialized
```

Tracked places are typed locals and their fields, while no address of them has escaped. A place whose address leaves the evaluator — passed to a materialized function, or to foreign code — is materialized and becomes ordinary, untracked storage from then on. Places reached through pointers are never tracked.

Unknown branches join their continuing states. Returns that jump out of an inlined application join at its end. A residual loop's state is its parameters (§9.4).

The evaluator performs partial evaluation of local native state without implementing a general-purpose C heap.

---

# 9. Loops are tail recursion

There is one iteration mechanism: **tail recursion**. `while` and typed `for` are sugar for anonymous tail-recursive loops, and generation-time iteration is ordinary Lua.

## 9.1 Generation-time loops

An untyped `for` is ordinary Lua and runs while the word is being constructed or evaluated:

```lua
local make_sum = do(n)
    return do(x: U32): U32
        local total: U32 = x
        for i = 1, n do
            total = total + i
        end
        return total
    end
end

local add6 = make_sum 3
```

```c
uint32_t add6(uint32_t x) {
    return x + 1u + 2u + 3u;
}
```

Its bounds must be known (host numbers or known integers); a dynamic bound is an error that points to the native form.

## 9.2 Tail calls

`return f(args)` in a word is a **tail call**. Applying a word evaluates its body in place (§12), so a tail call that re-enters the same word with the same *shape* — the same pattern of known and dynamic arguments — is a round of a loop. What happens to it follows one rule:

> **A tail re-entry runs at compile time for as long as each round stays entirely known: no residual statement, and every place it writes still holds a known value. Otherwise the known arguments that changed are generalized, and the re-entry becomes a jump.**

Typed bodies are deterministic and stage-safe, so the round that failed the test can be rolled back and evaluated again in the more general form. Rounds that stayed known before it are kept: their work is done at compile time.

```lua
local function count_down(k: U32, x: U32): U32
    if x == 0 then return k end
    return count_down(k + 1, x - 1)
end
local walk = do(x: U32): U32 = count_down(0, x)
```

The test `x == 0` is dynamic, so the first round is not known; `k`, the known argument that changed (0 → 1), is generalized. `count_down` re-enters only in tail position, so it does not become a function at all: its application turns into a loop in place, with one variable per dynamic parameter:

```c
uint32_t walk(uint32_t x) {
    uint32_t k = 0u;
    uint32_t x2 = x;
    for (;;) {
        if (x2 == 0u) {
            return k;
        }
        x2 = x2 - 1u;
        k = k + 1u;
    }
}
```

The parameters are assigned all at once; a temporary appears only where one new value still needs another variable's old value (a swap).

A word that also re-enters in non-tail position becomes a C function (§12.3), and its tail self-calls become jumps to its top:

```lua
local function gcd(a: U32, b: U32): U32
    if b == 0 then return a end
    return gcd(b, a % b)
end
export gcd
```

```c
uint32_t gcd(uint32_t a, uint32_t b) {
    uint32_t t;
    for (;;) {
        if (b == 0u) {
            return a;
        }
        t = a;
        a = b;
        b = t % b;
    }
}
```

Mutual tail recursion forms one loop: the other word is evaluated into each round.

## 9.3 Loops

A loop is a tail-recursive *join point*: it has parameters and rounds like a word, but it is not a word. A `return` inside a loop returns from the enclosing word, `break` leaves the loop, and `continue` starts the next round.

`while c do body end` is the loop

```text
loop():  if c then body; next() else exit end
```

and `for i: T = lo, hi, step do body end` is

```text
if lo <= hi then
    loop(i = lo):  body; if i is the last value then exit else next(i + step)
end
```

where "the last value" is `i == hi` for a unit step and `(UT)hi - (UT)i < step` in the unsigned type otherwise. The limit is tested after the body, so the variable never steps past it: no wraparound at the edges of the type. The limit is evaluated once.

Loop rounds follow the rule of §9.2. A loop whose control and carried state stay known runs at compile time:

```lua
local triangular = do(n: U32): U32
    local total: U32 = 0
    for i: U32 = 1, n do
        total = total + i
    end
    return total
end

local fifteen = triangular 5        -- Known(U32, 15)
```

With an unknown `n`, the first round is not known and the loop is residualized:

```lua
local runtime_sum = do(n: U32): U32 =
    triangular n
```

```c
uint32_t runtime_sum(uint32_t n) {
    uint32_t i;
    uint32_t total = 0u;
    if (1u <= n) {
        i = 1u;
        for (;;) {
            total = total + i;
            if (i == n) break;
            i = i + 1u;
        }
    }
    return total;
}
```

`runtime_sum(UINT32_MAX)` terminates.

A loop whose rounds turn dynamic part way keeps the known rounds before it:

```lua
local mixed_loop = do(x: U32): U32
    local acc: U32 = 1
    for i: U32 = 1, 4 do
        if i == 3 then acc = acc + x else acc = acc * 2 end
    end
    return acc
end
```

```c
uint32_t mixed_loop(uint32_t x) {
    uint32_t i = 3u;
    uint32_t acc = 4u;
    for (;;) {
        if (i == 3u) {
            acc = acc + x;
        } else {
            acc = acc * 2u;
        }
        if (i == 4u) break;
        i = i + 1u;
    }
    return acc;
}
```

`break` and `continue` are the loop's exit and next:

```lua
local sum_until = do(x: U32): U32
    local total: U32 = 0
    local i: U32 = 0
    while true do
        i = i + 1
        if i > x then break end
        if i == 3 then continue end
        total = total + i
    end
    return total
end
```

```c
uint32_t sum_until(uint32_t x) {
    uint32_t i = 0u;
    uint32_t total = 0u;
    for (;;) {
        i = i + 1u;
        if (i > x) break;
        if (i == 3u) continue;
        total = total + i;
    }
    return total;
}
```

A `while` with a host condition runs at compile time as long as its rounds are known, which makes it a generation-time loop; a host binding it rebinds cannot be carried into a residual loop (§8.6).

## 9.4 A loop's state is explicit

A loop is sugar for a tail-recursive word, and a word receives its state as parameters. The sugar does the same: **every typed local of the enclosing word that a loop mentions becomes a parameter of the loop.** In `sum_until`, `total` and `i` are its state.

- Each round works on its own copies, under the same names.
- `next` (a round ending, or `continue`) passes the copies to the next round.
- Leaving the loop (`break`, or the condition failing) stores them back into the word's locals, all at once.
- A `return` inside the loop leaves the word; nothing needs storing back.

So a residual loop's state is exactly its parameters, and no hidden iteration is needed to discover what it carries. In a residual loop a state variable is its own local: nothing else reads it while the loop runs, so the C has one variable, not a copy (`total` in `runtime_sum`).

```lua
local Pair = struct { a: U32, b: U32 }
local fib_pair = do(n: U32): U32
    local p: Pair = Pair { a = 0, b = 1 }
    for i: U32 = 1, n do
        p = Pair { a = p.b, b = p.a + p.b }
    end
    return p.a * 1000 + p.b
end
```

```c
uint32_t fib_pair(uint32_t n) {
    Pair p;
    uint32_t i;
    if (1u <= n) {
        i = 1u;
        p = (Pair){ .a = 0u, .b = 1u };
        for (;;) {
            p = (Pair){ .a = p.b, .b = p.a + p.b };
            if (i == n) break;
            i = i + 1u;
        }
    } else {
        p.a = 0u;
        p.b = 1u;
    }
    return p.a * 1000u + p.b;
}
```

One case remains where a loop changes a place no syntax shows: a write through a reference taken before the loop, or by a word that captured the place. If a residual loop writes a tracked place that existed before it, the outermost such loop rolls its round back, the place becomes ordinary memory before the loop, and the round is evaluated again. The result is still exact (`hidden` in the examples); the place merely loses its compile-time tracking.

## 9.5 Where unrolling comes from

Non-tail recursion under known control keeps unfolding, as any evaluation does:

```lua
local function pow(x: U32, n: U32): U32
    if n == 0 then return 1 end
    return x * pow(x, n - 1)
end
local cube = do(x: U32): U32 = pow(x, 3)
```

```c
uint32_t cube(uint32_t x) {
    return x * (x * x);
}
```

Under dynamic control, a non-tail re-entry with other known arguments generalizes the ones that changed, exactly as a tail re-entry does; it then re-enters with the same key and becomes a function (§12). Deliberate unrolling of statements is the generation-time loop's job (§9.1).

---

# 10. Types and native semantics

Native types are compile-time Lua values: `U8 U16 U32 U64 I8 I16 I32 I64 F32 F64 Bool Unit`, and the constructors `Ref T`, `Store T`, `Id T`, `Grow T`, `Ptr T` and `Slice T` (§32), plus structs and sums (§31). (Fixed-length arrays are part of the design and not yet in the prototype.)

## 10.1 C semantics

A known operation must produce the result its valid C counterpart produces:

- **8- and 16-bit integers** compute in 32 bits and wrap to their width after every operation. The C backend makes this explicit with casts, so C's integer promotions can never introduce undefined behaviour (`u16 * u16` would overflow `int`).
- **32-bit integers** compute exactly (products of unsigned values in 64-bit) and wrap if unsigned.
- **64-bit integers** are held as LuaJIT `int64_t`/`uint64_t` cdata, which wrap as C does.
- **F32** results are rounded through a C `float` after every operation; F64 is a Lua double.
- **Undefined behaviour is rejected**, never folded: signed overflow, division or remainder by zero, `MIN / -1`, shifts by the width or more, out-of-range float-to-integer conversion. The error names the operation and the source line.
- Division and remainder truncate toward zero, as in C (Lua's `%` floors; the folder uses C's rule).

## 10.2 Literals and conversions

A Lua number literal takes the type of the native operand it meets, with a range check (`a + 300` is an error when `a` is a `U8`). Two typed operands of different types do not meet: convert explicitly with `U32(x)`, which follows C's conversion rules. Integer literals beyond 2^53 are written in LuaJIT's 64-bit form, `6364136223846793005ULL`.

## 10.3 FFI

LuaJIT FFI provides the 64-bit and float representations. It is not the source of truth for native semantics; the folding rules above are.

## 10.4 Compile-time GC

LuaJIT's GC owns compiler objects: types, words, closures, staged values, command graphs and abstract states. The generated program does not inherit it.

---

# 11. Effects and residualization

Pure operations over known values are evaluated. Native effects stay in the residual program: foreign calls, observable memory writes, store operations, and operations whose operands remain dynamic.

```lua
local foreign_print = extern("foreign_print", { U32 }, Unit)

local print_scaled = do(k: U32, x: U32): Unit
    foreign_print(x * k)
end

local print_twice = print_scaled 2
```

```c
void print_twice(uint32_t x) {
    foreign_print(x * 2u);
}
```

Even when every argument is known, a foreign effect is not executed at compile time: a word whose evaluation needs one cannot be applied from host code.

Every effect is emitted where it happens, and an effect with a result binds it to a temporary, which fixes its order relative to other effects. (The backend later writes a temporary in place when its single use is the very next statement and nothing else in that statement can observe the effect; never into the right operand of `&&` or `||`.)

**Knownness determines what can be computed; the effect contract determines what is allowed to disappear.**

---

# 12. Inlining, materialization and specialization keys

## 12.1 Application is evaluation

A saturated application evaluates the word's body in place, with its arguments bound. The residual code appears in the caller. **No decision is involved:** this is simply what evaluation does. The question is what forces a C function boundary, and only two things do.

## 12.2 Exports

`export name` (or `export name as "c_name"`) materializes a word as an extern C function. Its remaining requirements become parameters; supplied arguments are baked in. Exports are the roots of the program: only what they reach is emitted.

## 12.3 Re-entry of a specialization key

A specialization key is the word's identity and, for each argument, either its known value, or "dynamic of type T", or "reference to T". Its *shape* is the same without the known values.

If an application's key is already being evaluated — the word has re-entered itself with the same knowns — in non-tail position, unfolding would never end. That key becomes a C function: its dynamic positions become parameters, and the inner application becomes a call. When the outermost application of the key finishes, it is undone (its residual statements and state changes discarded) and replaced by a call, so the function appears once:

```lua
local function fact(n: U32): U32
    if n <= 1 then return 1 end
    return n * fact(n - 1)
end
assert(host(fact(10)) == 3628800)     -- known: evaluated at compile time
export fact
```

```c
uint32_t fact(uint32_t n) {
    if (n <= 1u) {
        return 1u;
    }
    return n * fact(n - 1u);
}
```

A tail re-entry does not need a function (§9.2): it becomes a loop in place, or a jump to the top of the function it is already in.

## 12.4 Generalization

One rule decides when unfolding stops, for tail and non-tail re-entry alike:

> **A re-entry of the same word and shape under known control keeps evaluating. Under dynamic control — reached through a branch whose condition is dynamic, or from a residual loop — the known arguments that changed are generalized, and the frame is evaluated again in that form.**

Recursion with known bounds (`pow(x, 3)`, `fact(10)`) unfolds completely. Recursion whose termination test is dynamic generalizes what would otherwise make keys differ forever, so the same key comes back and the recursion becomes a loop or a function. Tail rounds additionally stop being compile-time work as soon as a round is not entirely known (§9.2).

A known argument that changes forever under known control still never repeats a key:

```lua
local function up(k: U32): U32
    return up(k + 1) + 1
end
```

After 400 nested applications the evaluator stops with an error listing the recent keys. `dynamic(e)` makes a known value a runtime parameter explicitly; generalization makes it unnecessary in the common case.

## 12.5 What is cached

- **Materialized keys**: each key has at most one function; re-entry and later applications call it.
- **Pure known calls**: within one evaluation, an application whose arguments are all static and which emitted nothing is memoized by key.

Nothing else is shared: each call site gets the residual code of its own arguments. Code size is not a concern of the semantics, but it is a concern of programs: a large word applied at many sites is that many copies. `call` (§12.7) puts a function boundary at one site.

## 12.6 Consequences

- Effect and memory summaries are needed only at boundaries: an inlined application needs none, because the caller's abstract state flows through the callee's body.
- At a materialized call, a reference to a tracked local escapes: the local is written to storage and untracked from then on.
- The data-stack recursion bound (§16) is checked only on cycles of materialized functions. A tail jump gives back the data stacks of the round it leaves.

## 12.7 `call`: a function boundary at one site

`call` before an application makes that application a real call: a residual function, specialized on the word, its compile-time parameters and the arguments known at the site (§12.1), shared by every `call` with the same key. A key with other known arguments is another function. It is always a call; the programmer asked for one. The exception is compile-time evaluation, which has no function to call from: there `call` is ignored and the application runs in place, so a word that uses `call` internally still runs on known inputs while compiling (`host(sip24(...))`).

```lua
local weigh = do(x: U32): U32
    local y = x * 3
    return y + y + x
end

local both = do(a: U32, b: U32): U32
    return call weigh(a) + call weigh(b) + weigh(a)
end
```

```c
uint32_t both(uint32_t a, uint32_t b) {
    uint32_t t = weigh(a);
    return t + weigh(b) + (a * 3u + a * 3u + a);
}
```

An application without `call` is unchanged: the word's body is evaluated in place with whatever is known. Meaning never changes, only the shape of the C.

`call` takes the next application: `call f(x)`, `call m:put(k, v)`, `call f a b`, in a statement or an expression, and `return call f(x)` is a return of the call (not a tail jump). It needs a native word; a foreign function is already a call, and an untyped Lua function is an error. A known view of a caller's local array (a `Str` over a `Chars`) crosses as a runtime address and length, since the callee cannot name the caller's local. `call` is a keyword only before a name on the same line: `call(x)` is an ordinary application of a binding named `call`.

The boundary is the programmer's, and `slc size program.slc` finds it. It reports the generated C per function and, for each word that is evaluated in place at several sites, the residual statements one `call` would share, with the heaviest sites and their source lines (`maps.slc:121  x3  3,600 statements  m:put(k, v + 100)`). Words too small to repay a call are left out. A large program also prints a one-line note pointing at it. A library puts `call` at the words the report names in its own code (`lib/map.slc` at the digest, probe, growth, insertion and key copy; `lib/hash.slc` and `lib/key.slc` at hash finalization; `slc/maps.lua` at `put`; `lib/stacks.slc` at two stack growth steps), so that a program with a hundred map operations contains one probe, not a hundred. The cost is a call where there was none (about 8% on a map loop that does nothing else); at a hot site, leave `call` out.

---

# 13. The residual command representation

The evaluator produces a typed command tree.

Expressions:

```text
Constant  Parameter  Read(place, version)  Address(place)
Binary  Unary  Compare  And  Or  Not  Convert
Field  Aggregate  Call(function | extern)  Runtime(op)
```

Places:

```text
Local  Field  Dereference(pointer)  Temporary  LoopVariable  ResultVariable
```

Statements:

```text
Store  Let(temporary)  SetParameter  Expression  If  Loop(top, end)  Return  Goto  Label
```

`Goto` and `Label` implement returns from inside inlined applications and the jumps of loops; the backend prints a jump to the innermost loop's top or end as `continue` or `break`. Emitted statements own their expressions (they are copied when emitted), so later rewrites of live values — lazy snapshots — cannot reach back into code already emitted.

## 13.1 Declarations

Declarations are placed by the backend: a variable whose first appearance is an assignment at the top level of its function is declared there; others are declared at the top of the function; loop variables in their `for`. Only places that residual code mentions are declared.

## 13.2 Cleanup

The backend applies presentation-only rewrites that cannot change behaviour:

- `r = e; goto L` where `L:` is followed by `return r` becomes `return e`;
- jumps to the next statement and labels nobody jumps to disappear;
- stores to locals nobody reads are dropped (effects in them are kept as statements);
- a temporary used once by the very next statement is written in place, under the conditions of §11.

---

# 14. Methods and `self`

```lua
local Counter = struct {
    value: U32,
}

function Counter:add(n: U32): Unit
    self.value = self.value + n
end

function Counter:get(): U32
    return self.value
end
```

A method is a native word attached to a struct type, with an implicit first requirement `self: Ref T`. A method name may not equal a field name.

The receiver is passed by reference. Calling a method on a struct value rather than a place gives it a temporary place.

Methods specialize like any word:

```lua
local count3 = do(a: U32, b: U32, c: U32): U32
    local counter: Counter = Counter { value = 0 }
    counter:add(a)
    counter:add(b)
    counter:add c
    return counter:get()
end
```

```c
uint32_t count3(uint32_t a, uint32_t b, uint32_t c) {
    return a + b + c;
}
```

Materialized, a mutable method takes an explicit receiver pointer:

```lua
export Counter.add as "counter_add"
```

```c
void counter_add(Counter *self, uint32_t n) {
    self->value = self->value + n;
}
```

No vtable, inheritance, hidden header or runtime method registry is involved.

A reference denotes its place, as a C++ reference does: it reads its target wherever a value is expected, and assigning to a name that holds one writes the target. A reference is never re-pointed.

```lua
local bump = do(r: Ref U32, k: U32): Unit
    r = r + k            -- writes through r; parameters are otherwise immutable
end
```

---

# 15. Goose-style native memory

**Memory management happens after residualization**, on the specialized program that remains.

Native memory has exactly two ownership forms:

1. **A lexical scope owns a value.**
2. **A managed store owns an object slot.**

References and IDs never own memory. There is no `Rc`, tracing GC or implicit heap promotion.

## 15.1 Fixed-size values

Scalars, structs without resizable fields, references and IDs are fixed-size. They live in registers or the C stack.

## 15.2 Resizable values

`Store T` and `Grow T` are resizable: they grow after construction. A struct may contain one resizable field, and it must be the last.

The storage class of a resizable value:

- **Created in place.** It is constructed where it lives — `local s: Store Node = Store(Node) {}`, or a struct field initializer `Graph { nodes = Store(Node) {} }` — and nowhere else. Declaring one without creating it is an error.
- **One data stack each.** Creation takes the lowest free data-stack index of the function. A resizable value occupies the top of its stack, and no other live growing value shares it.
- **Released when its block ends.** At the end of the residual block that created it, its stack's top returns to where the value began, and the index becomes free.
- **Moved only by reference.** It cannot be assigned, returned, read as a value, copied into another place, or passed by value; a struct containing one follows the same rules. Words take it as `Ref T`.
- **Runtime only.** Creating one at compile time is an error.

## 15.3 Variable-size values

Values whose size is fixed at construction but unknown at compile time (strings of computed length, arrays sized by a parameter) belong to the design: they use data-stack storage with properly nested lifetimes. They are not yet in the prototype.

---

# 16. Goose's stack assignment

The compiler assigns the lowest available relative data-stack index; an index is released when the block that owns it ends.

Functions that use data stacks — directly, or by calling functions that do — take a hidden `size_t gs_sp` base parameter. A local index `k` is the stack `gs_sp + k`. A call passes `gs_sp` plus the number of indices live at the call, so a callee never shares a stack with a caller's live growing values:

A sketch of the convention (not compiler output):

```c
static uint32_t helper(size_t gs_sp, ...);   /* its stacks: gs_sp + 0, ... */

/* in a caller with two live resizable locals */
helper(gs_sp + 2, ...);
```

The callee needs no separately generated body per absolute location.

Exports are entry points: they take no base parameter and start at stack 0.

Every function that allocates on data stacks records the tops of its stacks on entry and restores them before every return (the result is computed first), so early exits give space back too. Block-end releases give space back inside loops.

**Recursive cycles that would keep data stacks live across a recursive call are rejected**: a call inside a cycle of materialized functions must not move the base. A recursive word may use data stacks, provided none of its resizable values is live at the recursive call.

A resizable value reached through a reference keeps its stack identity in its header, so it can grow through the reference.

---

# 17. Borrowed references

`Ref T` borrows an addressable native place and never owns it.

## 17.1 Borrowed results

A word can return a reference derived from a reference it received:

```lua
local identity = do(r: Ref U32): Ref U32 =
    r
```

A word that returns a reference to its own local is rejected.

## 17.2 Restricted aggregates

References cannot be stored in structs (and therefore not in stores). Long-lived relationships are represented by IDs.

## 17.3 Invalidation

Operations capable of invalidating borrowed storage are rejected while an incompatible borrow is live: a Grow cannot grow while a view of it is live. Borrow lifetimes are lexical.

A store slot is not borrowed: it is addressed as a place, `s[id]`, whose address is recomputed and whose ID is checked at every use (§30.6). Nothing holds a slot's address across a change to the store, so the store may grow or shrink while its slots are in use. The one lexical borrow left is a Grow's view (§32.4).

---

# 18. Managed stores and generational IDs

```lua
local Node = struct {
    value: U32,
}

local Graph = struct {
    nodes: Store Node,
}
```

| Operation | Meaning |
|---|---|
| `s:add(v)` | insert a copy of `v`; returns an `Id T` |
| `s:remove(id)` | remove the object; `false` if `id` is stale or foreign |
| `s:has(id)` | whether `id` identifies a live object of `s` |
| `s[id]` | the object, as a place: read it, assign it or its fields, pass it as a reference; every use checks `id` |
| `s.length` | the number of live objects |
| `a == b`, `a ~= b` | IDs compare by token, slot and generation |

All store operations are runtime effects: they always remain in the residual code.

## 18.1 ID semantics

An ID is a store token, a slot index and a generation. A checked lookup verifies all three plus occupancy, so an old ID never identifies a replacement object in a recycled slot. Generations start at 1 (a zeroed ID is never valid); a slot whose generation would wrap is retired instead of reused. Store tokens come from a 64-bit counter and are never reused.

## 18.2 Store ownership

A store's slots live on its data stack; its header (stack index, base offset, counters, token) lives in its place. Slots are addressed by offset, so growth may move the stack's buffer safely.

## 18.3 Cyclic graphs

Graph edges contain IDs, not owning references:

```lua
local Edge = struct {
    from: Id Node,
    to: Id Node,
}
```

Cycles are ordinary relationships; they create no ownership cycles. Objects are removed explicitly or with their store.

## 18.4 Grow arrays

`Grow T` supports `g:push(v)`, `g[i]` (a place, its index checked at every use) and `g.length`.

---

# 19. Stores and specialization

```lua
function Graph:add(value: U32): Id Node
    return self.nodes:add Node {
        value = value,
    }
end

local insert = do(
    enabled: Bool,
    k: U32,
    graph: Ref Graph,
    value: U32
): Id Node

    if enabled then
        return graph:add(value * k)
    end

    return graph:add value
end

local insert_double = insert(true, 2)
export insert_double
```

The partial application binds `enabled = true` and `k = 2`. The false branch disappears, the multiplier is substituted, and the store insertion remains because it changes runtime storage. Store operations are ordinary SLC words, so the insertion inlines into the caller; the call it lowers to is:

```c
/* sketch */
NodeId insert_double(Graph *graph, uint32_t value) {
    return NodeStore_add(&graph->nodes, (Node){ .value = value * 2u });
}
```

`NodeStore` and `NodeId` are typedefs of the fixed runtime records (`slc_store`, `slc_id`) in `slc_rt.h`; `add`, `get` and the other operations are SLC words that read and write those records.

**The original Boolean condition and static parameter `k` never reach C emission.**

---

# 20. Memory-aware specialization

Knownness is semantic information used during residualization; memory facts are verified for the residual program. They are separate responsibilities.

Specialization keys contain code identity, native types and known arguments — never absolute data-stack positions, because `gs_sp` is a relative base.

Unreachable code contributes nothing: a branch removed by a known condition allocates nothing, and only functions reachable from exports are emitted or counted.

---

# 21. Effects, aliases and ordering

- Known pure work disappears. Observable effects remain, in source order.
- Operands and arguments evaluate left to right. Effects bind their results to temporaries where they occur, so C's unspecified evaluation order never matters.
- A place whose address escapes becomes untracked storage; reads of it are reads of memory.
- A materialized call invalidates exactly the knowledge it could change: tracked locals whose address it received.
- Folding respects width, conversions and floating-point rules (§10.1); LuaJIT's own arithmetic is never substituted where it differs.

---

# 22. Foreign C interoperability

```lua
local puts_u32 = extern("puts_u32", { U32 }, Unit)
local abs      = extern("abs", { I32 }, I32, { header = "<stdlib.h>" })

local dist = do(a: I32, b: I32): I32 = abs(a - b)
```

```c
int32_t dist(int32_t a, int32_t b) {
    return abs(a - b);
}
```

A foreign function is an opaque effect: it is never executed at compile time, whatever its arguments. With a header, the backend includes it; without one, it emits the prototype.

Structs with fixed C layouts cross the boundary directly; exported words taking `Ref T` take `T *`, and `Slice T` is a `{ T *ptr; uint32_t len; }` struct passed by value. Resizable values and stores cross only by pointer, with their header layout from `slc_rt.h`. Raw pointers (`Ptr T`, §32) are the foreign boundary, not provenance-checked references.

---

# 23. The minimal semantic machinery

The compiler rests on three staging abstractions.

## Staged values

Known, dynamic, aggregate or reference. Smart constructors compute known results and construct residual expressions otherwise.

## Staged words

Requirements, identity and static supplies. Application coerces arguments, binds partials, and evaluates saturated applications in place; a tail re-entry becomes a loop, a non-tail re-entry of the same key a function, and a re-entry under dynamic control generalizes the known arguments that changed.

## Staged blocks

Places with lazy stores, isolated states for dynamic branches, joins, returns, frames whose tail rounds run at compile time while known and become jumps otherwise, and data-stack ownership of resizable values.

Everything else — generic containers, serializers, state machines, numerical kernels — is built from these and ordinary Lua functions.

The objective is not a small number of source-level features. It is a **small number of semantic mechanisms that compose**.

---

# 24. A complete end-to-end example

```lua
-- Generic compile-time type generator
local Box = do(T)
    local B = struct {
        value: T,
    }

    function B:get(): T
        return self.value
    end

    function B:set(value: T): Unit
        self.value = value
    end

    return B
end

local NumberBox = Box U32

-- Native word
local affine = do(
    a: U32,
    b: U32,
    x: U32
): U32 = a * x + b

-- Static partial application
local transform = affine(4, 3)

-- Specialized branch
local process = do(
    enabled: Bool,
    x: U32
): U32

    local box: NumberBox = NumberBox {
        value = transform x,
    }

    if enabled then
        box:set(box:get() * 2)
    end

    return box:get()
end

-- Further specialization
local enabled_process = process true

-- Fully known invocation
local answer = enabled_process 10
assert(host(answer) == 86)

-- Native entry
local entry = do(x: U32): U32 =
    enabled_process x

export entry
```

### Compile-time events

1. Lua evaluates `Box U32`, constructing the `NumberBox` type and its methods.
2. `affine(4, 3)` and `process true` bind static requirements.
3. `enabled_process 10` evaluates entirely at compile time: `Known(U32, 86)`.
4. `export entry` evaluates `entry` with `x` dynamic. `enabled_process x` is evaluated in place: the known `enabled` selects the branch, `transform x` stores `4 * x + 3` into `box.value` as a pending value, `box:get()` reads it back, `box:set(...)` replaces it with another pending value, and the final `box:get()` returns it.
5. `box` never needs storage: its address never escaped, its field was never forced into storage, so it is never declared.

### Generated C

```c
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

uint32_t entry(uint32_t x) {
    return (4u * x + 3u) * 2u;
}
```

No generic abstraction, partial-application environment, closure, method dispatch, box storage, conditional branch, LuaJIT dependency, garbage collector or reference count survives. The `NumberBox` type is not emitted: no reachable code uses it.

---

# 25. Runtime memory example

A computation that genuinely needs dynamic native storage:

```lua
local Node = struct {
    value: U32,
}

local Graph = struct {
    nodes: Store Node,
}

function Graph:add(value: U32): Id Node
    return self.nodes:add Node {
        value = value,
    }
end

local populate = do(
    scale: U32,
    g: Ref Graph,
    n: U32
): Unit

    for i: U32 = 1, n do
        g:add(i * scale)
    end
end

local populate_double = populate(2)

local run = do(n: U32): U32
    local g: Graph = Graph {
        nodes = Store(Node) {},
    }

    populate_double(Ref(g), n)

    return g.nodes.length
end

export run
```

*v0.4 declared `populate(g, scale, n)` and applied it to `2`, which would bind `g`. Static requirements come first.*

The static `scale` disappears from the residual code. The loop count is dynamic, so the loop survives. `g` is owned by `run`'s scope; its store takes data stack 0 and gives it back before `run` returns. The store's own operations are SLC and inline, so the shape is:

```c
/* sketch */
uint32_t run(uint32_t n) {
    size_t gs_sp = 0;
    size_t gs_top0 = slc_gs_top(gs_sp);
    Graph g;
    uint32_t i;
    g.nodes = NodeStore_new(gs_sp);
    if (1u <= n) {
        i = 1u;
        for (;;) {
            NodeStore_add(&g.nodes, (Node){ .value = i * 2u });
            if (i == n) break;
            i = i + 1u;
        }
    }
    uint32_t t = g.nodes.live;
    slc_gs_reset(gs_sp, gs_top0);
    return t;
}
```

There are no independently owned or reference-counted node objects.

**Partial evaluation determines which computation survives. Goose determines how the surviving computation stores its data.**

---

# 26. Deliberate exclusions

The core language does not provide:

- Arbitrary Lua-to-C compilation.
- A second complete typed C virtual machine.
- Implicit runtime closure allocation.
- General-purpose heap ownership, reference counting or tracing garbage collection.
- Automatic heap promotion.
- References stored in aggregates.
- Arbitrary independently owned objects, or automatic collection of unreachable graph nodes.
- Unrestricted speculation of compile-time side effects.
- A runtime object model for generic types, or dynamic method dispatch by default.
- Shared mutable memory between tasks, and the lock and ownership type disciplines that would police it (tasks communicate over channels and move pool slots, §36).

Planned but not yet in the prototype: variable-size values. Pointer arithmetic beyond `p[i]` is excluded by design (§32).

---

# 27. Architectural rationale

## Why Lua?

Lua already provides a complete compile-time programming environment: lexical scope, closures, higher-order functions, tables, modules and control flow. There is no need to invent another metaprogramming language.

## Why LuaMacro, and why parse typed bodies?

LuaMacro keeps the surface Lua's: macro.let gives lambdas and application, and the same token stream feeds the typed-body parser. Parsing is unavoidable: with token rewriting alone, staging `a < b and c` correctly would need operator precedence anyway, and comparisons cannot be staged by metamethods at all.

## Why tail recursion instead of loop syntax?

Words are already evaluated in place, so a tail call that re-enters a word is a round of a loop, and the evaluator's existing tools decide its fate: compile-time evaluation while rounds stay known, generalization of what changes under dynamic control, rollback of a round to redo it in general form. Loop-carried state becomes explicit parameters — the sugar makes the locals a loop mentions into its parameters, so nothing has to be discovered — `break` and `continue` are exit and next, and `while` and `for` stay as sugar because they read well. One mechanism replaces two.

## Why reified commands?

Commands make native computation inspectable and transformable, and preserve what the memory checker and the backend need: effects, control flow, places.

## Why online partial evaluation?

Known computation disappears during construction. Lua closures provide the execution mechanism; smart constructors produce residual expressions; structured blocks handle branches, mutation, loops and returns. This achieves Let-like specialization without the Let VM.

## Why materialize only exports and re-entered keys?

Because evaluation already inlines, a boundary is needed only where evaluation alone cannot finish: where the outside world calls in, and where a key repeats. The same view explains non-termination (keys that never repeat) and gives one remedy (`dynamic`).

## Why lazy stores?

Most native state in specialized code is private and short-lived. Keeping it pending until something needs storage makes private structs, temporaries and method round-trips free, without a separate optimization pass.

## Why Goose?

Allocation becomes predictable and reclamation follows lexical ownership. Its restrictions make data-stack assignment simple; the compiler proves the restrictions rather than solving a general heap-placement problem.

## Why stores and IDs?

Stores provide independent recycling without independent ownership. Generational IDs support persistent and cyclic relationships while preventing stale handles from identifying replacement objects.

## Why C?

C is the execution target and ABI foundation. Its toolchains provide optimization, linking and portability, and the generated source stays readable.

---

# 28. The defining semantic contracts

1. **Ordinary Lua is the compile-time host language.**
2. **A lambda that declares a result type is a native word.**
3. **Saturated application evaluates the word in place, with every argument.**
4. **Partial application binds only static values.**
5. **A C function boundary exists only for an export or a specialization key re-entered in non-tail position.**
6. **Eligible known native computation executes during compilation; a tail re-entry runs at compile time while its rounds stay known, and becomes a jump otherwise.**
7. **Loops are tail recursion; a re-entry under dynamic control generalizes the known arguments that changed.**
8. **Unknown or observable native computation becomes residual commands, in source order.**
9. **Typed bodies are parsed; comparisons, conditions, `and`/`or`, assignment and `return` are staged.**
10. **Unknown branches use isolated states; rebinding host bindings across them is rejected.**
11. **Typed places store lazily; storage is written only when something needs it.**
12. **The C backend receives a specialized residual program, not a translation of the source.**
13. **Goose memory analysis operates on the surviving native operations.**
14. **Scopes own ordinary values; stores own recyclable objects; resizable values are created in place and moved only by reference.**
15. **References borrow, IDs identify, and neither owns storage.**
16. **Data-stack allocation is bounded through lexical scopes and call-graph restrictions.**
17. **No runtime GC, reference counting or implicit heap ownership exists.**
18. **Activities are compile-time: a callback never becomes a closure; opening introduces live field places and may not shadow.**
19. **Tasks share no memory: what reaches a task or crosses a channel is a copy or a move, every wait is an operation in the task's own body, and a scope joins every task it started.**
20. **The resulting executable is independent of LuaJIT.**

---

# 29. Final formulation

The system is a **Lua-hosted, online specializing compiler for a typed native language**.

Its central computation is a word. A word receives requirements; known requirements are consumed during specialization. Applied, its body is evaluated in place by LuaJIT through staged closures and smart constructors. Known parts compute; unknown parts become residual native commands; a key that re-enters itself becomes a function. The commands are checked against a Goose-style ownership and storage model, then emitted as ordinary C.

> **Lua provides abstraction. Application provides specialization. Online evaluation eliminates known work. Commands preserve unknown work. Goose provides memory. C provides execution.**

The significance is not simply that Lua generates C. It is that **the generated program contains only the native work that survives progressive application and compile-time specialization**, with memory placement determined afterward from that smaller residual computation.

---

# 30. Activities, opening and spread

> **Entities own what persists. Activities own or borrow what is needed for a purpose. Words express what happens inside.**

An activity is a design role, not a mechanism: an activity word sets up a context, runs a body that opens it and speaks its verbs, and owns completion. It is written with ordinary words, callbacks and opening, and needs no activity type. The pattern comes from Let, where it structured mutation and bounded borrows without reference counting. slc has no reference counting and no runtime closures at all, so the pattern is its natural shape for bounded mutable work.

The forms below follow Let's `spread.md`, adapted where slc differs (noted).

## 30.1 Callbacks

An untyped lambda inside a typed body is a **callback**. It is evaluated in place, like a word: its control flow is staged, a `return` leaves only the callback, and its result type comes from its returns (the first return that needs storage fixes it). A callback never becomes a C function or a closure; it exists only while the program is being specialized.

```lua
local apply = do(f, x: U32): U32 = f(x)
local clamp_cb = do(x: U32): U32
    return apply(do(v)
        if v > 10 then return v - 10 end
        return v
    end, x) + 1
end
```

```c
uint32_t clamp_cb(uint32_t x) {
    uint32_t r;
    if (x > 10u) {
        r = x - 10u;
        goto L1;
    }
    r = x;
L1:;
    return r + 1u;
}
```

A callback may assign the typed locals of its word (they are places), but not the untyped bindings of its word (§7.5).

## 30.2 Compile-time parameters

A native word may leave a parameter untyped. **An untyped parameter of a native word is a compile-time parameter**: its argument must be a Lua value or a known native value, and it is part of the specialization key (§12). It is how a word receives a callback, a vocabulary table or a generator. Supplying a runtime value is an error. *(Let's unannotated parameters default to `Any`, a dynamic type; slc's counterpart is compile-time, since slc has no runtime dynamic values.)*

## 30.3 Activity words

```lua
local Document = struct { length: U32, cursor: U32, edits: U32 }
local Editing = struct { length: U32, cursor: U32, edits: U32 }

function Editing:insert(n: U32): Unit
    self.length = self.length + n
    self.cursor = self.cursor + n
    self.edits = self.edits + 1
end

function Editing:move_left(): Unit
    if self.cursor > 0 then
        self.cursor = self.cursor - 1
    end
end

-- work on a copy, commit at the end
local transaction = do(document: Ref Document, body): Unit
    local editing: Editing = Editing { ...document }
    body(Ref(editing))
    document = Document { ...editing }
end

local type_text = do(doc: Ref Document, n: U32): Unit
    transaction(doc) do(editing...)
        insert n
        move_left()
        if cursor > 3 then
            insert 1
        end
    end
end
```

```c
void type_text(Document *doc, uint32_t n) {
    Editing editing;
    editing.length = doc->length;
    editing.cursor = doc->cursor;
    editing.edits = doc->edits;
    editing.length = editing.length + n;
    editing.cursor = editing.cursor + n;
    editing.edits = editing.edits + 1u;
    if (editing.cursor > 0u) {
        editing.cursor = editing.cursor - 1u;
    }
    if (editing.cursor > 3u) {
        editing.length = editing.length + 1u;
        editing.cursor = editing.cursor + 1u;
        editing.edits = editing.edits + 1u;
    }
    doc->length = editing.length;
    doc->cursor = editing.cursor;
    doc->edits = editing.edits;
}
```

The activity word controls setup and completion; the callback's `return` does not leave the activity; borrowed access cannot outlive its owner. When the entity is private, the activity disappears entirely:

```c
uint32_t fresh_length(uint32_t n) {
    return (n + 2u) * 100u + 2u;
}
```

An activity can own temporary state and return a result. Its body may open the home without naming it (`do(...)`):

```lua
local counting = do(body): U32
    local counting: Counting = Counting { count = 0 }
    body(Ref(counting))
    return counting.count
end
local evens = do(n: U32): U32 =
    counting do(...)
        for i: U32 = 1, n do
            if i % 2 == 0 then
                tick()
            end
        end
    end
```

```c
uint32_t evens(uint32_t n) {
    Counting counting;
    uint32_t i;
    counting.count = 0u;
    if (1u <= n) {
        i = 1u;
        for (;;) {
            if (i % 2u == 0u) {
                counting.count = counting.count + 1u;
            }
            if (i == n) break;
            i = i + 1u;
        }
    }
    return counting.count;
}
```

(The loop writes the context through the opened reference, which no syntax of the loop shows, so `counting` becomes plain memory before the loop, §9.4.)

Temporary resizable state (a worklist, a change log) created in an activity takes a data stack and gives it back when the activity ends: activity scope is Goose scope.

## 30.4 Saturating chains

`transaction(doc) do(editing...) ... end` is the application `transaction(doc)(body)`. On its own, `transaction(doc)` would be a partial application with a runtime argument, which §5.4 rejects. **A chain of applications on a word accumulates its arguments until the word is saturated**, as in Let; surplus arguments apply to the result. The same holds for method chains (`g:view() do(xs) ... end`) and for library functions with a declared arity. Any other Lua function applies each group in turn.

## 30.5 Opening

| Form | Meaning |
|---|---|
| `do(ctx...)`, `do(ctx...: T)` | receive one argument, then open it |
| `do(...)`, `do(...: T)` | the same, without a name; `(...)` reads the home |
| `local ctx...` | open an existing binding |
| `local ctx... = e` | evaluate once, bind, then open |

One parameter may be opened. What a context introduces:

| Context | Names introduced |
|---|---|
| a record value, place or reference | its field names, as live field places of the retained receiver |
| a Lua table (a vocabulary) | its string keys |

- **Open to work; bind to remember.** An introduced field name denotes the field's place: reading it reads the current value, assigning it stores to the field. `local before = cursor` takes the value at that point.
- **Methods stay attached.** Opening introduces no method names. An otherwise-unbound bare call inside an opened region uses the innermost receiver that has such a member; actual members win over lexical words; locally bound callables stay ordinary calls. `(name)(args)` bypasses the receiver.
- **Spread may not shadow (`spread-shadow`).** An introduced name may not collide with a visible declared name, a name an enclosing opening introduced, a program global or a prelude name; and a later declaration may not shadow an introduced name. *(Lua's own standard-library globals do not count as visible names here, so a field named `next` or `type` can be opened; the library remains reachable as `_G.next`.)* Because a context's type is known only when the program is specialized, these checks happen then, at the opening and at each use.
- **An opened context cannot be assigned whole (`context-use`).**

### Anonymous spread

When a context's name adds nothing, open it unnamed. Its fields are in scope, bare calls go to it, and `(...)` reads the home itself — including to pass it on explicitly with `(f)(..., other)`, which bypasses receiver insertion:

```lua
local squared = do(...: Vec): F64 = x*x + y*y

local session = do(...: Ref Terminal, lines: U32): U32
    draw(lines)
    (status)(..., 1)
    return width - drawn
end
```

```c
double squared(Vec vec) {
    return vec.x * vec.x + vec.y * vec.y;
}
```

```c
uint32_t session(Terminal *terminal, uint32_t lines) {
    terminal->drawn = terminal->drawn + lines;
    terminal->drawn = terminal->drawn + 1u;
    return terminal->width - terminal->drawn;
}
```

A materialized unnamed home is named after its type in C. A home read where none is opened is `context-required`.

### Vocabularies

```lua
local units = { kilo = 1000, mega = 1000000 }
local to_base = do(k: U32, m: U32): U32
    local units...
    return k * kilo + m * mega
end
```

## 30.6 Addressing a store slot

`s[id]` is the slot as a place. Opened, its fields are live places too (§30.5):

```lua
local double_node = do(g: Ref Graph, id: Id Node): Unit
    local node... = g.nodes[id]
    value = value * 2
    weight = weight + 1
end
```

```c
/* sketch */
void double_node(Graph *g, NodeId id) {
    Node *at = NodeStore_borrow(&g->nodes, id);
    at->value = at->value * 2u;
    at->weight = at->weight + 1u;
}
```

Every use is checked, as a slice checks its index, but uses that nothing separates share one check. The compiler keeps the address it found in a temporary and reuses it on the same path until something could change what the lookup would find:

* a structural change: `add`, `remove`, `push`, or a slot moving (`release`, a send);
* a call into a function compiled on its own, or into C;
* the start of a residual loop's round, the end of the loop, and the join after a branch.

Then the next use looks again. The C compiler cannot do this merging itself, because a store to an element may alias the store's header as far as it can tell. The lookup itself is inline: a few loads and compares, with the failure and the growth of the stack set out of line. Because no address outlives the stretch it was found in, a store may grow (its data stack can move) between two uses of the same slot. This replaces both a borrow checker for §17.3 and the borrow-by-scope activity of earlier versions.

## 30.7 Keyed spread

```lua
local moved_x = do(p: Point, dx: I32): Point = Point { ...p, x = p.x + dx }
```

A spread contributes a record's data fields (from a value, place or reference); the result is ordinary construction. Explicit fields override spread fields regardless of position; duplicate explicit fields are rejected; two spreads contributing the same field are rejected (`spread-overlap`), even if an explicit field overrides it; unknown fields are rejected, including overridden ones. All operands evaluate in source order.

## 30.8 Rest requirements, packs and ordered spread

A word may end its parameters with one unannotated rest requirement `...args`. Once the fixed requirements are supplied, the rest takes every remaining argument and the application is saturated. The components form a **pack**: a static length and components, second-class. Only three operations exist: `...args` contributes the components to an ordered list, `args.length` is the static length, and `args[i]` is a component (a static, in-range index, from 1). Passing, storing, returning or assigning a pack whole is rejected (`pack-use`); a bad index is `pack-index`.

```lua
local logged = do(f, ...args): U32
    log_call(args.length)
    return f(...args)
end
local use_logged = do(x: U32, y: U32): U32 = logged(twice, x) + logged(add3, x, y, 1)
```

```c
uint32_t use_logged(uint32_t x, uint32_t y) {
    log_call(1u);
    log_call(3u);
    return x * 2u + (x + y + 1u);
}
```

A pack's shape is part of the specialization key, so each shape gets its own residual code; no runtime tuple or variadic call exists.

`...e` may appear at any position of an argument list, a return list or a binding initializer list. It contributes a pack's components, or the several results of a Lua call. Records do not expand positionally (`spread-source`); nor do Lua tables (runtime-length expansion is deferred). Items evaluate once, left to right. A word's `return ...args` must supply exactly one value.

## 30.9 `endall`

```lua
local import_rows = do(doc: Ref Document, n: U32): Unit
    traced 1 do
    traced 2 do
    transaction(doc) do(editing...)
        insert n
    endall
    trace(9)
end
```

`endall` closes the innermost trailing block lambda and each enclosing block lambda whose body ends there. It stops at any other block, so the word's body stays open. It returns nothing, calls nothing and cleans nothing up: its effects are exactly those of the expanded program.

```c
void import_rows(Document *doc, uint32_t n) {
    Editing editing;
    trace(1u);
    trace(2u);
    editing.length = doc->length;
    editing.cursor = doc->cursor;
    editing.edits = doc->edits;
    editing.length = editing.length + n;
    editing.cursor = editing.cursor + n;
    editing.edits = editing.edits + 1u;
    doc->length = editing.length;
    doc->cursor = editing.cursor;
    doc->edits = editing.edits;
    trace(102u);
    trace(101u);
    trace(9u);
}
```

## 30.10 Not included

Keyed application other than matching (§31), modules and `use` (Lua tables play the vocabulary role), `defer`, rest destructuring, and spreading Lua tables. The forms here work in typed bodies; top-level code is plain Lua.

---

# 31. Sums and matching

Sums follow Let's `syntax.md` §8.1.

## 31.1 Declaring and constructing

```lua
local Circle = struct { radius: U32 }
local Rect = struct { width: U32, height: U32 }
local Shape = oneof { circle: Circle, rect: Rect, dot: Unit }
```

A sum is a finite set of named alternatives, each with a payload type (`Unit` for none). Alternative order is canonical (by name), so two spellings of the same alternatives are the same type. A `oneof` needs at least one alternative. Payloads are fixed-size: no resizable storage and, as everywhere in slc, no references (*Let's recursive sums go through `Ref`; in slc they go through `Id`s into a store, as graphs do*).

Member selection on the sum type names a constructor. A record payload is built by keyed supply, another payload is applied to one value, and a `Unit` alternative to nothing:

```lua
Shape.rect { width = 4, height = 5 }
Opt.some(x)
Opt.none()
```

In C, a sum is a tag and a union of the payloads, with the tags as named constants:

```c
enum { Shape_circle = 0, Shape_dot = 1, Shape_rect = 2 };
typedef struct Shape {
    uint32_t tag;
    union {
        Circle circle;
        Rect rect;
    } as;
} Shape;
```

## 31.2 Matching

Matching is keyed application of a sum value, with one handler per alternative. Each handler receives that alternative's payload:

```lua
local area = do(s: Shape): U32 = s {
    circle = do(c) = c.radius * c.radius * 3,
    rect = do(r)
        local w = r.width
        return w * r.height
    end,
    dot = do() = 0,
}
```

`name(params) = body` in a headed supply is `name = do(params) = body`: `o { some(v) = v, none() = d }`.

Every alternative must be handled exactly once, even when the tag is known: a missing, unknown or duplicate handler is rejected. A payload is reached only by matching; selecting it by name is rejected.

## 31.3 Binding times of a sum

A sum value is tracked with its tag and payload separately, so a sum whose **tag is known** can carry a payload of any binding time (`Command.insert(n)` with `n` from input). This is the common case in practice.

- **A known tag selects its handler while specializing.** Only that handler runs; the others are never evaluated. `area(Shape.rect { width = k, height = 1 })` is `k`:

```c
uint32_t strip(uint32_t k) {
    return k;
}
```

- **A runtime tag** gives a test per alternative, the payload projected inside its arm. Each arm is evaluated against its own copy of the state, as the branches of a dynamic `if` are, and the result is joined. The handlers must agree on a result type; a Lua number takes its type from the other handlers, so the result does not depend on alternative order, and handlers that agree on one Lua number fold to it. A chain of tests on one tag prints as a `switch`:

```c
uint32_t area(Shape s) {
    switch (s.tag) {
    case Shape_circle: {
        return s.as.circle.radius * s.as.circle.radius * 3u;
    }
    case Shape_dot: {
        return 0u;
    }
    default: /* Shape_rect */ {
        return s.as.rect.width * s.as.rect.height;
    }
    }
}
```

A sum stored in a typed local keeps a known tag through the evaluator (lazy stores, §8.3); paths that disagree make it memory at the join, as any place.

## 31.4 Describe, then run

Commands as data and one interpreter:

```lua
local Direction = oneof { left: Unit, right: Unit }
local Command = oneof { move: Direction, insert: U32, undo: Unit }

local apply = do(e: Ref Editor, c: Command): Unit
    c {
        move = do(d)
            d {
                left = do
                    if e.cursor > 0 then e.cursor = e.cursor - 1 end
                end,
                right = do
                    if e.cursor < e.length then e.cursor = e.cursor + 1 end
                end,
            }
        end,
        insert = do(n)
            e.length = e.length + n
            e.cursor = e.cursor + n
        end,
        undo = do
            e.undos = e.undos + 1
        end,
    }
end
```

Over a script known while specializing, the interpreter dissolves into straight-line code:

```lua
local script = {
    Command.insert(5),
    Command.move(Direction.left()),
    Command.move(Direction.left()),
    Command.undo(),
    Command.insert(2),
}
local run_script = do(e: Ref Editor): Unit
    for i = 1, #script do
        apply(e, script[i])
    end
end
```

```c
void run_script(Editor *e) {
    e->length = e->length + 5u;
    e->cursor = e->cursor + 5u;
    if (e->cursor > 0u) {
        e->cursor = e->cursor - 1u;
    }
    if (e->cursor > 0u) {
        e->cursor = e->cursor - 1u;
    }
    e->undos = e->undos + 1u;
    e->length = e->length + 2u;
    e->cursor = e->cursor + 2u;
}
```

Over a program known only at run time, the same interpreter is a switch inside a loop, a bytecode VM:

```lua
local Program = Grow Command
local run_program = do(e: Ref Editor, prog: Ref Program): Unit
    local i: U32 = 0
    while i < prog.length do
        apply(e, prog[i])
        i = i + 1
    end
end
```

```c
/* sketch */
    for (;;) {
        if (i >= prog.len) break;
        at = CommandGrow_elem(&prog, i);
        t = *at;
        switch (t.tag) {
        case Command_insert: {
            e.length = e.length + t.as.insert;
            e.cursor = e.cursor + t.as.insert;
            break;
        }
        case Command_move: {
            if (t.as.move.tag == Direction_left) {
                if (e.cursor > 0u) {
                    e.cursor = e.cursor - 1u;
                }
            } else if (e.cursor < e.length) {
                e.cursor = e.cursor + 1u;
            }
            break;
        }
        default: /* Command_undo */ {
            e.undos = e.undos + 1u;
            break;
        }
        }
        i = i + 1u;
    }
```

(The printer emits a `switch` only when no arm leaves an enclosing loop, so its `break`s always mean the `switch`.) One implementation, two binding times: this is the guide's "describe, then run", with the interpretive work removed by construction when the description is known.

---

# 32. Raw pointers and slices

Pointers follow Let's `syntax.md` §8.5 and slices its §8.4. **`Ptr` is the edge of the program; `Slice` is for the work.**

## 32.1 Raw pointers

`Ptr T` is an address the compiler does not track: the explicit foreign boundary, where the programmer is responsible and the compiler offers no rule to break.

| Form | Meaning |
|---|---|
| `p[i]` | the element at index `i` (an unsigned integer): an unchecked place, readable and assignable |
| `p.field` | a field of a record target, readable and assignable |
| `Ptr(place)` | the address of a place: the **only** place a lifetime is dropped |
| `null(T)` | the null `Ptr T` |
| `Ptr(T)(p)` | an explicit unchecked conversion from one raw pointer type to another |
| `p == q`, `p ~= q` | address comparison |

There is no other arithmetic, no ordering and no conversion to or from integers; `p[i]` is the only arithmetic, so one thing has one spelling. `Ref(p)` is rejected: an unchecked address must not become a checked borrow. Pointers may be stored in structs, returned and passed freely.

A `CString` and a raw pointer convert to each other the same way: `(Ptr U8)(s)` reads a C string's address as a byte pointer and `CString(p)` reads a byte pointer's address as text, where a foreign interface needs one for the other. No integer takes part.

`Ptr(T)(p)` accepts only an existing `Ptr U`. It preserves the address and does not copy or reinterpret a value, check alignment or bounds, transfer ownership, extend a lifetime, or create a borrow. The programmer must satisfy the foreign ABI, alignment and aliasing rules before dereferencing the result. Converting back to the original pointer type preserves its address; null stays null. Pointer conversions are never implicit. For example, a POSIX `Ptr sockaddr_in` can explicitly become a `Ptr sockaddr` for `connect`, and a raw operation buffer can explicitly recover its declared slot-pointer type. Both backends lower this through the ordinary prepared-IR conversion operation.

```lua
local brighten = do(px: Ptr Pixel, n: U32, k: U8): Unit
    local i: U32 = 0
    while i < n do
        px[i].r = px[i].r + k
        i = i + 1
    end
end
```

```c
void brighten(Pixel *px, uint32_t n, uint8_t k) {
    uint32_t i = 0u;
    for (;;) {
        if (i >= n) {
            return;
        }
        px[i].r = (uint8_t)((uint32_t)px[i].r + (uint32_t)k);
        i = i + 1u;
    }
}
```

**Pointers and the evaluator.** Pointer operations are always residual: there is no memory at compile time. The evaluator makes no assumptions about memory it does not track, so pointers need no extra rules: `Ptr(place)` treats the place as a `Ref` passed to a materialized call does (its pending values are stored and it is plain memory from then on), values read through pointers are never kept pending, and binding one to a name snapshots it at once. A write through any pointer therefore cannot invalidate anything the evaluator believes. `Ptr(v)[0]` is `v` and `Ptr(s).f` is `s.f`:

```c
uint32_t through_pointer(uint32_t x) {
    uint32_t v = x;
    v = v + 1u;
    return v * 10u;
}
```

A pointer into a store slot or a `Grow` dangles after the storage grows. That is the responsibility §8.5 hands to the programmer: it is documented, not checked.

## 32.2 Slices

`Slice T` is a read-only view: a pointer and a `U32` length. Its operations:

| Form | Meaning |
|---|---|
| `s[i]` | a checked element read (a copy) |
| `s.length` | the length |
| `s:sub(a, b)` | the view of `[a, b)`, checked |
| `Slice(p, n)` | a view of `n` elements at pointer `p`: the boundary where a length is trusted |
| `g:view() do(xs) ... end` | a view of a `Grow` (§32.3) |

**A check that a branch already proved is dropped.** On each arm of a dynamic branch the compiler records what an integer comparison proves (the loop exit `if (i >= n) break;` proves `i < n` on the path that continues), over values that cannot change behind its back: constants, parameters, temporaries, versioned reads of tracked locals, and a view's length. When `i` changes, its version changes and the fact stops matching. `s[i]` and `a[i]` (§37) emit no check when such a fact proves `i < length`.

A view is read-only: `s[i] = v` is rejected (`not-a-place`); writes go through the storage or a `Ptr`. Slices cannot be compared. Slices are borrows, like `Ref`, so they cannot be stored in structs (*Let admits slices in records; slc keeps its rule that aggregates hold no borrows*).

**Checks and binding times.** Internally a slice is a two-field struct, so the evaluator tracks its length apart from its pointer. A **known index against a known length is checked at compile time** (`index-range`) and costs nothing at run time; anything else is one check when it runs (the `slice.index` word of [lib/slice.slc](../lib/slice.slc), a trap on failure). `s:sub(a, b)` with known bounds produces a slice whose **length is known**, after one range check. So the idiom for formats is to take the whole header once, then read at constant offsets with no further checks.

## 32.3 Describe, then run: a binary format

```lua
local Packet = struct { version: U32, flags: U32, length: U32, id: U32 }
local format = {
    { "version", 0, 1 },
    { "flags",   1, 1 },
    { "length",  2, 2 },
    { "id",      4, 4 },
}
local size = 8
local read_be = do(s: Slice U8, at, width): U32
    local v: U32 = 0
    for k = 0, width - 1 do
        v = v * 256 + U32(s[at + k])
    end
    return v
end
local parse = do(buf: Slice U8): Packet
    local h = buf:sub(0, size)
    local fields = {}
    for _, f in ipairs(format) do
        fields[f[1]] = read_be(h, f[2], f[3])
    end
    return Packet(fields)
end
```

```c
Packet parse(U8Slice buf) {
    if (8ull > (uint64_t)buf.len) {
        slc_trap("slice range out of bounds");
    }
    uint32_t v = (uint32_t)buf.ptr[0u];
    uint32_t v2 = (uint32_t)buf.ptr[1u];
    uint32_t v3 = (uint32_t)buf.ptr[2u];
    v3 = v3 * 256u + (uint32_t)buf.ptr[3u];
    uint32_t v4 = (uint32_t)buf.ptr[4u];
    v4 = v4 * 256u + (uint32_t)buf.ptr[5u];
    v4 = v4 * 256u + (uint32_t)buf.ptr[6u];
    v4 = v4 * 256u + (uint32_t)buf.ptr[7u];
    return (Packet){ .version = v, .flags = v2, .length = v3, .id = v4 };
}
```

The description, the loop over it and the reader's own loop are gone; one range check remains.

## 32.4 Views of a Grow

A view of a `Grow` is an activity, the one lexical borrow left (§17.3): the body receives the elements as a slice, the `Grow` cannot grow while the view lasts (`push` is rejected, as is a materialized call receiving a reference that reaches it), and the slice cannot outlive the view, nor be stored. The view's result is the body's.

```lua
return g:view() do(xs)
    return sum32(xs)
end
```

## 32.5 What is not checked

A check stays when no recorded fact proves it: facts are kept per path, over values that cannot change behind the compiler's back (above), and are not carried through a `Bool` that stored a comparison (`ok = i < n; if ok then ... xs[i]`), nor across loop rounds once a variable changes. Taking a known-length sub-slice first is a way to state a bound the compiler cannot see.

---

# 33. libc as activities

libc is C, and slc emits C, so wrapping it is a matter of externs. What the language adds is the shape: **every libc resource with a lifetime becomes an activity**, and an activity's completion cannot be skipped, because a body's `return` leaves only the body. A file opened by `with_file` is always closed and a buffer from `with_buffer` always freed, short of a trap: RAII without destructors, `defer` without `defer`. Everything is evaluated in place, so the wrappers leave no calls of their own in the C.

## 33.1 What wrapping C needs

| Form | Meaning |
|---|---|
| `opaque "FILE"` | an opaque C type, usable only behind a `Ptr` (`FILE *`) |
| `CString` | `const char *`; a Lua string literal is a known `CString` |
| `extern(name, params, result, { header = "<stdio.h>" })` | a C function from a header (no prototype is emitted) |
| `{ variadic = true }` | a variadic C function; extra arguments must be native scalars, `CString`s or pointers |
| `cformat(...)` | a format string and its arguments, built while specializing |
| `require "slc.libc"` | load `lib/libc.slc` once per compilation and return its vocabulary table (§3.0) |

**Formats are decided by the compiler.** `cformat("n = ", n, ", ratio = ", ratio, "\n")` produces the format `"n = %u, ratio = %g\n"` and the arguments cast to the types those conversions expect, so a format can never disagree with its values. Lua strings and numbers, and known native values, go into the format itself:

```c
void greet(uint32_t times) {
    printf("hello 3 times, then %u (true)\n", (unsigned)times);
}
```

## 33.2 The library

`lib/libc.slc` declares the externs and returns a vocabulary:

```lua
local FILE = opaque "FILE"
local fopen  = extern("fopen",  { CString, CString }, Ptr FILE, { header = "<stdio.h>" })
local fclose = extern("fclose", { Ptr FILE }, I32, { header = "<stdio.h>" })

local File = struct { handle: Ptr FILE }
function File:write(s: CString): Unit
    fputs(s, self.handle)
end
function File:say(...parts): Unit
    fprintf(self.handle, cformat(...parts))
end

local with_file = do(path: CString, mode: CString, body): Bool
    local h: Ptr FILE = fopen(path, mode)
    if h == null(FILE) then
        return false
    end
    local file: File = File { handle = h }
    body(Ref(file))
    fclose(h)
    return true
end
```

It also provides `say` (formatted `printf`), `each_byte(path) do(b) ... end` (an activity built on `with_file`), and `with_buffer(n) do(buffer...) ... end` with `data`, `size` and `fill`.

## 33.3 Using it

```lua
local c = require "slc.libc"

local report = do(path: CString, n: U32, ratio: F64): Bool
    local c...
    return with_file(path, "w") do(file...)
        write "report\n"
        say("n = ", n, ", ratio = ", ratio, "\n")
        if n > 10 then
            return                -- leaves the body only: the file is still closed
        end
        say("small\n")
    end
end
```

```c
bool report(const char *path, uint32_t n, double ratio) {
    FILE *h;
    FILE *t = fopen(path, "w");
    if (t == NULL) {
        return false;
    }
    fputs("report\n", t);
    fprintf(t, "n = %u, ratio = %g\n", (unsigned)n, (double)ratio);
    if (n > 10u) {
        h = t;
        goto L1;
    }
    fprintf(t, "small\n");
    h = t;
L1:;
    fclose(h);
    return true;
}
```

The early `return` jumps to `fclose`; there is no path that leaves the file open. Inside the body, `write` and `say` are the receiver's methods (§30.5), and `say` resolves to `File:say`, not the library's `say`: the innermost receiver's member wins.

A heap buffer, written through its `Ptr`, read through a checked `Slice`:

```lua
local sum_filled = do(n: U32, byte: U8): U32
    local c...
    local total: U32 = 0
    with_buffer(n) do(buffer...)
        fill(byte)
        data[0] = 1
        local bytes = Slice(data, size)
        local i: U32 = 0
        while i < bytes.length do
            total = total + U32(bytes[i])
            i = i + 1
        end
    end
    return total
end
```

```c
uint32_t sum_filled(uint32_t n, uint8_t byte) {
    uint32_t total;
    uint8_t *p;
    U8Slice bytes;
    uint8_t *t = malloc((uint64_t)n);
    if (t == NULL) {
        total = 0u;
        p = t;
        goto L1;
    }
    memset(t, (int32_t)byte, (uint64_t)n);
    t[0u] = 1u;
    total = 0u;
    bytes = (U8Slice){ .ptr = t, .len = n };
    uint32_t i = 0u;
    for (;;) {
        if (i >= bytes.len) {
            p = t;
            break;
        }
        total = total + (uint32_t)bytes.ptr[i];
        i = i + 1u;
    }
    free(p);
L1:;
    return total;
}
```

The slice index is checked, and the check is gone: the loop's condition already proved `i < n` on the path that reads `bytes[i]` (§32.2).

The same approach extends to any C API with resources: sockets, locks, directories, a GPU context. The vocabulary is the API, and the activity is its lifetime.

---

# 34. POSIX and Linux as activities

In Unix everything is a file, and in Linux nearly everything is a file descriptor: files, pipes, sockets, devices, timers, event counters, the epoll set itself. A descriptor has a lifetime, which makes it an activity: open, run the body, close. `lib/posix.slc` wraps the kernel interface this way. The completion guarantee matters more here than anywhere: a leaked descriptor or mapping is a real class of bug, and a body's `return` cannot skip the `close`.

## 34.1 Talking to the kernel correctly

| Form | Meaning |
|---|---|
| `cstruct("struct stat", "<sys/stat.h>", { { "size", I64, "st_size" } })` | a struct whose **layout comes from the header**; only the named fields are seen, each optionally mapped to a C member path |
| `cconst("O_RDONLY", I32, "<fcntl.h>")` | a constant whose **value comes from the header** (a runtime value: platform values are always right) |
| `cread("errno", I32, "<errno.h>")` | a C variable or macro, read where it is called |
| `bytes(place)` | the storage of a place as `Ptr U8` (its lifetime dropped, as with `Ptr(place)`) |
| `size_of(T)` | the C size of a type |
| `view_of(p, n, body)` | a scoped read-only view, for library activities |

Declaring kernel structs by hand risks ABI mismatches (`struct epoll_event` is packed on x86-64; `struct stat` differs between architectures). A `cstruct` emits no definition of its own: the C compiler supplies the real layout, and a field like `{ "fd", I32, "data.fd" }` reaches into nested unions.

For a recursive foreign layout, the fields argument may be a host function. It
receives the type being declared and returns the same field list:

```lua
local Node = cstruct("struct node", '"node.h"', function(Self)
    return { { "next", Ptr Self }, { "value", U32 } }
end)
```

The callback runs once during type construction, not at runtime. The incomplete
type may occur behind a pointer, not as a by-value field (including an array
element). This describes an existing C layout; it does not introduce shared
references between tasks or change the ownership rules.

## 34.2 The library

- `with_fd(path, flags) do(writing...) ... end` returns an **`Outcome`**, `oneof { done: Unit, failed: I32 }` carrying the errno. Inside, the body has `write_text`, `write_bytes`, `read_bytes`, `size` and `mapped`.
- `mapped(n) do(bytes) ... end` maps the file's first `n` bytes as a read-only `Slice U8` that ends with its `munmap`.
- `with_eventfd do(counter...) ... end` gives a kernel counter that is a descriptor.
- `with_epoll do(poll...) ... end` gives `watch(fd)` and `next_ready(timeout_ms)`.

**Failures are the activity's outcome.** The `Fd` context records the first failed call's errno (every `read` and `write` result is checked, as `warn_unused_result` demands), and `with_fd` reports it as `failed(e)`: the completion policy belongs to the activity.

## 34.3 Using it

```lua
local px = require "slc.posix"

local make_file = do(path: CString): I32
    local px...
    return with_fd(path, bor(O_WRONLY, bor(O_CREAT, O_TRUNC))) do(writing...)
        write_text "SLC1"
        write_text "hello, kernel\n"
    end { done() = 0, failed(e) = e }
end
```

The outcome is matched right where the activity ends: `with_fd(...) do ... end { ... }` is one saturating chain whose surplus argument, the handler table, applies to the result.

```c
int32_t make_file(const char *path) {
    Outcome r;
    Fd file;
    int32_t t = open(path, O_WRONLY | (O_CREAT | O_TRUNC), 420u);
    if (t < 0) {
        r = (Outcome){ .tag = Outcome_failed, .as.failed = errno };
        goto L1;
    }
    if (write(t, "SLC1", 4ull) < 0ll) {
        file.error = errno;
    } else {
        file.error = 0;
    }
    if (write(t, "hello, kernel\n", 14ull) < 0ll && file.error == 0) {
        file.error = errno;
    }
    close(t);
    if (file.error != 0) {
        r = (Outcome){ .tag = Outcome_failed, .as.failed = file.error };
        file.fd = t;
        goto L1;
    }
    r = (Outcome){ .tag = Outcome_done };
    file.fd = t;
L1:;
    if (r.tag == Outcome_done) {
        return 0;
    }
    return r.as.failed;
}
```

Constants are the header's (`O_WRONLY | (O_CREAT | O_TRUNC)`); text known while specializing has a known length (`4ull`); the first write's "no error yet" test folded away, because the evaluator knows the error is still 0 there.

A mapping is a view, so the header format idiom applies (§32.3): one sub-slice of known length, then constant offsets, with no check left:

```lua
mapped(4) do(bytes)
    local h = bytes:sub(0, 4)
    found = U32(h[0]) * 16777216 + U32(h[1]) * 65536 + U32(h[2]) * 256 + U32(h[3])
end
```

```c
        t = mmap(NULL, 4ull, PROT_READ, MAP_PRIVATE, file.fd, 0ll);
        if (t == MAP_FAILED) {
            goto L3;
        }
        found = (uint32_t)t[0u] * 16777216u + (uint32_t)t[1u] * 65536u + (uint32_t)t[2u] * 256u + (uint32_t)t[3u];
        munmap(t, 4ull);
    L3:;
```

And the kernel's own event machinery, an eventfd watched by epoll, as a spine of activities:

```lua
local ping = do(n: U64): U64
    local px...
    local got: U64 = 0
    with_eventfd do(counter...)
        local value: U64 = n
        write_bytes(bytes(value), size_of(U64))
        with_epoll do(poll...)
            watch(fd)
            if next_ready(100) == fd then
                local back: U64 = 0
                read_bytes(bytes(back), size_of(U64))
                got = back
            end
        endall
    return got
end
```

Inside `with_epoll`, `fd` is still the counter's field and `watch` the poll's method: nested openings compose, and `spread-shadow` keeps them from colliding (naming the activity parameter `fd` would collide with `Fd`'s own field, which is why activity parameters are gerunds).

## 34.4 What is next

Shared-memory kernel interfaces (io_uring rings, futexes) use the atomics of §35. Arrays of kernel structs (`epoll_wait` filling many events) are fixed-length arrays (§37) of `cstruct` types.

---

# 35. Atomics

Atomics serve two kinds of sharing: state shared between threads of a program, and memory shared with the kernel (io_uring's rings, futex words).

## 35.1 The type and its operations

`Atomic T`, for an integer, a `Bool` or a pointer, is a struct field or a typed local that is **accessed only by atomic operations**: a plain read or write is rejected, and atomics are never copied (a struct holding one cannot be read as a whole). Its initialization is the one plain store, before anything is shared.

| Operation | Result |
|---|---|
| `a:load(order)` | the value |
| `a:store(v, order)` | — |
| `a:exchange(v, order)` | the value before |
| `a:add(v, order)`, `a:sub(v, order)` (integers) | the value before |
| `a:cas(expected, desired, order)` | `true` when the value was `expected` and is now `desired` |
| `fence(order)` | a memory fence |
| `atomic_ptr(p)` | `Ptr T` viewed as `Ptr (Atomic T)`: the boundary form for shared memory from C or the kernel |

**Memory orders are compile-time arguments**, `"relaxed"`, `"acquire"`, `"release"`, `"acq_rel"` or `"seq_cst"` (the default), and the orders C leaves undefined are rejected while compiling: a load cannot be `release` or `acq_rel`, a store cannot be `acquire` or `acq_rel`. A compare-and-swap derives its failure order from its success order.

**In C**, an atomic is a plain `T` accessed with the GCC/Clang `__atomic` builtins. They work in C99 (`<stdatomic.h>` would need C11), and the layout of a struct holding atomics stays identical to the C caller's or the kernel's.

**In the evaluator**, atomic operations are effects: never folded, never kept pending, never tracked, and emitted in source order. Atomic places are not tracked even inside a local struct whose other fields are.

## 35.2 A spinlock is an activity

```lua
local SpinLock = struct { held: Atomic Bool }
local with_lock = do(lock: Ref SpinLock, body): Unit
    while not lock.held:cas(false, true, "acquire") do
    end
    body()
    lock.held:store(false, "release")
end

local Shared = struct { lock: SpinLock, total: U64 }
local add_locked = do(s: Ref Shared, times: U32): Unit
    local i: U32 = 0
    while i < times do
        with_lock(Ref(s.lock)) do
            s.total = s.total + 1
        end
        i = i + 1
    end
end
```

The release is the activity's completion, so it cannot be skipped by the body's `return`.

```c
void add_locked(Shared *s, uint32_t times) {
    bool t;
    uint32_t i = 0u;
    for (;;) {
        if (i >= times) {
            return;
        }
        for (;;) {
            t = false;
            if (__atomic_compare_exchange_n(&s->lock.held, &t, true, false, __ATOMIC_ACQUIRE, __ATOMIC_ACQUIRE)) break;
        }
        s->total = s->total + 1ull;
        __atomic_store_n(&s->lock.held, false, __ATOMIC_RELEASE);
        i = i + 1u;
    }
}
```

The expected value is reset on every round of the spin, as a compare-and-swap requires (it overwrites `expected` on failure).

## 35.3 A ring shaped like io_uring's

A single-producer single-consumer ring publishes with release stores of its indices and observes with acquire loads:

```lua
local Ring = struct { head: Atomic U32, tail: Atomic U32, mask: U32, slots: Ptr U32 }

local push = do(r: Ref Ring, v: U32): Bool
    local tail: U32 = r.tail:load("relaxed")
    local head: U32 = r.head:load("acquire")
    if tail - head > r.mask then
        return false                      -- full
    end
    r.slots[band(tail, r.mask)] = v
    r.tail:store(tail + 1, "release")
    return true
end
```

```c
bool push(Ring *r, uint32_t v) {
    uint32_t t = __atomic_load_n(&r->tail, __ATOMIC_RELAXED);
    uint32_t t2 = __atomic_load_n(&r->head, __ATOMIC_ACQUIRE);
    if (t - t2 > r->mask) {
        return false;
    }
    r->slots[t & r->mask] = v;
    __atomic_store_n(&r->tail, t + 1u, __ATOMIC_RELEASE);
    return true;
}
```

The consumer side returns a sum (`oneof { empty: Unit, value: U32 }`), matched by the draining loop. For io_uring itself, the ring indices live in memory mapped from the kernel: `atomic_ptr` turns the plain pointers `mmap` returns into atomic ones.

## 35.4 Checked with real threads

The C harness drives these words from POSIX threads (four threads bumping a counter, four contending on the lock, a producer and a consumer passing 200 000 values through the ring) and checks exact totals. It also runs under **ThreadSanitizer**, which reports no data races; a deliberately non-atomic version of the counter is reported, so the check has teeth. (The ThreadSanitizer build uses clang, whose runtime models standalone fences.)

---

# 36. Tasks, channels and I/O

*The prototype implements this section (§36.12 says how it is checked). The C listings are the prototype's output.*

slc takes Go's concurrency model, communicating sequential tasks, and fits it to a language with no garbage collector, with words evaluated in place, and with explicit loop state. Four rules carry the design. Everything else follows from them.

1. **A task owns its memory.** Nothing is shared between tasks. Values cross by copy, and slots of a pool cross by move.
2. **Every wait is an operation the compiler can see,** in the task's own body.
3. **Every lifetime is a scope.** Tasks, channels and pools belong to the `tasks` scope that made them, and the scope ends only when all its tasks have.
4. **There is one way to wait.** An operation is started and later completes. `first_of` chooses among operations the runtime can take back.

What this rules out, on purpose: locks, shared mutable memory, and an ownership type system to police them. Atomics (§35) remain for memory shared with the kernel and for library internals; they are not how tasks cooperate.

## 36.1 Scopes

```lua
tasks do(scope...)
    local jobs = channel(Job, 16)
    spawn do
        for i: U32 = 1, n do jobs:send(Job { id = i, n = i }) end
        jobs:close()
    end
    jobs:each(do(j) total = total + U64(j.n) end)
end
```

`tasks` is an activity (§30.3). Its body opens a vocabulary:

| Word | Meaning |
|---|---|
| `spawn do ... end` | start a task running the block |
| `spawn(f, args...)` | sugar for `spawn do f(args...) end` |
| `channel(T, n)` | a channel of `T` with `n` buffered slots; `n = 0` is unbuffered |
| `pool(T, n)` | `n` slots of `T` whose ownership moves between tasks (§36.6) |

**The scope's end is a wait.** It completes when the body has finished and every task spawned in the scope has finished. Then the channels and pools retire. A scope does not cancel anything: it waits. A scope that would wait forever is a deadlock, and the scheduler reports it (§36.9).

**The scope body is the enclosing code, continued.** It runs in sequence with the code around it, so it reads and writes that code's locals freely; `total` above is one. Spawned tasks are not the enclosing code, and the next section says what they can reach.

* *Inside a task*, the body is part of that task. Its waits suspend the task, and so does the scope's end.
* *In plain code*, such as an exported function called from C, the body runs on the calling thread, and its waits **block** that thread instead of suspending it. The compiler emits the same runtime call in both cases. A blocked thread is not idle: it runs tasks from the scheduler's queue until its own wait completes. So a scope in plain code costs no closure conversion, and with no worker threads at all (deterministic mode, §36.9) everything runs on the blocked thread.

Scopes nest. A task may open its own scope. It may also spawn into the scope it belongs to, or make channels and pools in it, because a task carries its scope's handle implicitly. Everything it makes there still ends with that scope.

## 36.2 What a task reaches

```lua
spawn do
    for i: U32 = 1, n do jobs:send(Job { id = i, n = i }) end
    jobs:close()
end
```

A spawned block may mention:

* **Runtime names from outside, as copies.** Every outer typed local, parameter or introduced name the block mentions (`n` and `jobs` here) is copied into the task when it is spawned. The set is the one the compiler already computes for loop state (§9.4): the names the block mentions. Each copied name must have a *sendable* type (§36.5), and assigning one inside the block is rejected. A copy that looked like shared state would be the one way to misread the model.
* **Compile-time values, as facts.** Known values, types, words and Lua data are baked into the task's specialization, as in any word (§12). A spawn inside a host loop unrolls.
* **Its own locals,** which nobody else can reach.

`spawn(f, a, b)` evaluates `a` and `b` in the spawning code and copies them; it is exactly `spawn do f(a, b) end`. Either way, the task's result is `Unit`. Results are sent on channels.

## 36.3 What a task compiles to

A task is not a thread. It compiles to a **resumable C function**: a frame struct holding the task's typed locals and its copies, and a step function that runs until the next wait and returns. Two properties of slc make this both possible and cheap:

* **Words are evaluated in place (§12),** so a `send` inside a word inside a callback lands in the task's own body. No `async` marks the words that may wait: there is no call to mark, so there is no function coloring.
* **Loop state is explicit (§9.4),** so the locals live at each wait are known exactly.

```lua
local square = do(inp: Chan U32, out: Chan U64): Unit
    inp:each(do(v)
        out:send(U64(v) * U64(v))
    end)
    out:close()
end
```

Spawned with `spawn(square, nums, squares)`, it becomes a frame and a step function:

```c
typedef struct square_frame {
    slc_task task;
    slc_op ops[1];
    slc_chan inp;
    slc_chan out;
    bool open;
    uint32_t got;
    int32_t r;
    ReceivedU32 r2;
    uint64_t msg;
} square_frame;
```

```c
static slc_step square_step(slc_task *slc_task_) {
    square_frame *f = (square_frame *)slc_task_;
    switch (f->task.state) {
    case 1: goto resume1;
    case 2: goto resume2;
    case 3: goto resume3;
    default: break;
    }
    f->open = true;
    for (;;) {
        if (slc_budget(&f->task)) {
            f->task.state = 1;
            return SLC_YIELD;
        }
    resume1:;
        if (!f->open) break;
        if (slc_recv(&f->task, f->ops, f->inp, &f->got, "channels.slc:8: recv") == SLC_PENDING) {
            f->task.state = 2;
            return SLC_WAIT;
        }
    resume2:;
        f->r = f->task.result;
        if (f->r == 1) {
            f->r2 = (ReceivedU32){ .tag = ReceivedU32_value, .as.value = f->got };
            goto L1;
        }
        f->r2 = (ReceivedU32){ .tag = ReceivedU32_closed };
    L1:;
        if (f->r2.tag == ReceivedU32_closed) {
            f->open = false;
        } else {
            f->msg = (uint64_t)f->r2.as.value * (uint64_t)f->r2.as.value;
            if (slc_send(&f->task, f->ops, f->out, &f->msg, "channels.slc:9: send") == SLC_PENDING) {
                f->task.state = 3;
                return SLC_WAIT;
            }
        resume3:;
        }
    }
    slc_chan_close(f->out);
    return SLC_DONE;
}
```

The copies are named after the word's parameters, `inp` and `out`. Each wait passes its site, the source line, which a deadlock report prints.

Jumping into a loop body is ordinary C99, so the lowering is portable: no stack switching and no assembly.

* **A wait owns its operation records** (`slc_op`) in the frame: one, or one per case of a `first_of`. Waiting allocates nothing: the record is linked into a channel's queue or handed to the I/O backend, and whoever completes it writes the result into the record and makes the task runnable.
* **Each task has its own data stacks** (§16). They are heap buffers addressed by offset, so a suspended task's stores and Grow arrays stay where they are. A worker switches to a task's stack set when it runs the task, and back to its own afterwards. The frame never moves, so references into the task's own locals stay valid across waits.
* **Loop back-edges count down a budget** and yield when it runs out. The compiler knows every residual loop, because loops are tail calls (§9), so a task that never waits still cannot starve the others. This is cooperative scheduling with the cooperation inserted by the compiler. Only a long call into C goes unchecked.

**The one restriction.** A task cannot wait inside a word that is compiled as its own C function: a recursion re-entered in non-tail position (§12). Plain code may, since it blocks rather than suspends. Such a function has a real C stack frame, which cannot be suspended. Tail recursion is a loop and is fine. Non-tail recursion that waits is written with an explicit stack in a Grow. The design leaves room for a later extension that lays such frames on the task's data stack, which amounts to segmented stacks.

The scope body that spawned it is plain code, an export. Its waits block, and `slc_self()` names the calling thread as a party the runtime can wake:

```c
uint64_t sum_squares(uint32_t n) {
    slc_task *slc_tk = slc_self();
    slc_op slc_ops[1];
    uint64_t got;
    int32_t r;
    ReceivedU64 r2;
    slc_scope *scope = slc_scope_new(slc_tk);
    slc_chan ch = slc_chan_new(scope, (uint64_t)sizeof(uint32_t), 8u);
    slc_chan ch2 = slc_chan_new(scope, (uint64_t)sizeof(uint64_t), 8u);
    { task_frame *slc_t = (task_frame *)slc_spawn(scope, sizeof(task_frame), task_step); slc_t->nums = ch; slc_t->n = n; slc_start(&slc_t->task); }
    { square_frame *slc_t = (square_frame *)slc_spawn(scope, sizeof(square_frame), square_step); slc_t->inp = ch; slc_t->out = ch2; slc_start(&slc_t->task); }
    uint64_t total = 0ull;
    bool open = true;
    for (;;) {
        if (!open) break;
        if (slc_recv(slc_tk, slc_ops, ch2, &got, "channels.slc:28: recv") == SLC_PENDING) slc_block(slc_tk);
        r = slc_tk->result;
        if (r == 1) {
            r2 = (ReceivedU64){ .tag = ReceivedU64_value, .as.value = got };
            goto L1;
        }
        r2 = (ReceivedU64){ .tag = ReceivedU64_closed };
    L1:;
        if (r2.tag == ReceivedU64_closed) {
            open = false;
        } else {
            total = total + r2.as.value;
        }
    }
    if (slc_scope_end(slc_tk, slc_ops, scope, "channels.slc:16: the end of a tasks scope") == SLC_PENDING) slc_block(slc_tk);
    return total;
}
```

A spawn allocates a zeroed frame, fills in the copies (the producer block captured `n` and the channel), and starts the task.

## 36.4 Operations and `first_of`

Every wait is an **operation**: it is started, and later it completes with a result. A single operation suspends the task until it completes:

| Operation | Completes with |
|---|---|
| `c:send(v)` | — (traps if `c` is closed) |
| `c:recv()` | `Received T`: `oneof { value: T, closed: Unit }` |
| `p:take()` | a `Slot T` the task now owns (§36.6) |
| `sleep(d)` | — (`d` is a `Duration`, built with `ns`, `us`, `ms` or `seconds`) |
| I/O (§36.7) | `oneof { done: U32, failed: I32 }`, and `timed_out` with a deadline |
| `blocking do ... end` | — (the block ran on a blocking thread) |
| a scope's end | — |

`c:recv() { value = do(v) ... end, closed = do ... end }` matches the receive directly, without building the sum. `c:each(do(v) ... end)` receives until the channel is closed and drained.

**`blocking do ... end`** is for calls into C that may block (a library that sleeps, a slow `fsync`). In a task, the block runs on a blocking thread while the task waits, so the call never holds a worker; the task's locals are its frame and the task is not running, so the block reads and writes them as they are. It compiles to a function over the frame. A block cannot wait (it runs outside the scheduler). In plain code the thread may block anyway, and the block simply runs in place.

**`first_of`** starts several operations and continues with the first one to complete:

```lua
first_of {
    recv(results) do(r) ... end,
    send(out, x) do ... end,
    take(buffers) do(s) ... end,
    after(ms(100)) do ... end,
    closed = do ... end,
    default = do ... end,
}
```

* Each case is an operation and a handler. `default` runs when no case is ready at once, and then nothing waits.
* A closed channel never fires its `recv` case. `closed` is ready once every `recv` case's channel is closed and drained, which is Go's merge idiom made explicit.
* A `send` case on a closed channel is always ready, and taking it traps, as in Go: it traps when it is the case taken, not merely because it is listed.
* A `first_of` with a `recv` case must have `closed` or `default`, or it is rejected. Otherwise, once its channels close, it could only wait forever. This is the same exhaustiveness rule as matching (§31).
* When one case completes, the others are **withdrawn before the handler runs**, so exactly one case happens. A completing counterpart first claims the waiting task with a compare-and-swap on its selection word, so two senders cannot both deliver to it.
* Ready cases are scanned from a rotating start, for fairness.

The cases are known while compiling, so `first_of` is sequenced where it is written (`lib/select.slc`): the program fills the operation records itself, and a shared function per shape of `first_of` (its kinds in order, and whether it has a default) makes one attempt per case through the runtime's `slc_poll_recv`, `slc_poll_send` and `slc_poll_take`, each one locked transaction. Only when nothing is ready and there is no default does it wait, on every record, through `slc_select_arm`. No case array is built, no case kind is looked up at run time, and the clock is read only when a case waits on time: a two-case select over ready channels runs about 2.4 times faster than the interpreter it replaced.

**Why I/O is never a case of `first_of`.** A channel operation, a pool take and a timer belong to the runtime, which can take them back exactly: a withdrawn receive has received nothing. The kernel's work cannot be taken back. A read that loses the race may already have consumed bytes from the socket, and then they are gone. So `first_of` admits only operations the runtime can withdraw, and an I/O case is rejected. The two needs behind such a case have direct forms:

* *I/O with a time limit:* give the operation a deadline. Its result gains `timed_out`, and the result is exact: if bytes were read, the result says `done` with their count, never `timed_out`.
* *I/O raced against something else:* spawn a task that does the I/O and sends the result on a channel, and put that channel in the `first_of`.

## 36.5 Channels

`Chan T` is a value: a handle that is copied freely, stored in structs and sent on channels, including channels of channels. A channel lives as long as the scope that made it.

**Sendable types**, for channel elements and for copies taken at spawn:

* scalars, `Bool`, `Duration`;
* structs and sums made of sendable types;
* `Chan T` and `Pool T`: handles to runtime-synchronized objects of the same scope;
* `Slot T` (§36.6), which moves rather than copies. A slot anywhere inside a message moves with it: the compiler knows where slots sit in the message's layout, and emits the ownership transfer for each one.

Never `Ref`, `Ptr`, `Slice`, `CString`, `Atomic` or a store `Id`, at any depth. Each of those points into memory someone else owns. The diagnostic names the offending field or alternative.

**Semantics**, as in Go:

* A send on a buffered channel waits while the channel is full. A send on an unbuffered channel completes when a receiver has taken the value; the value goes straight from the sender's frame into the receiver's.
* `close` means no more values. Receivers drain what is buffered, then see `closed`.
* Sending on a closed channel, or closing one twice, traps.

**Handles are generational,** like IDs (§18). A handle kept past its scope, by storing it in a longer-lived struct or by sending it to an outer task, traps on its next use. It never reaches freed memory. Channel records live in a registry that only grows, so a stale handle always lands on a live record that knows it is stale.

## 36.6 Pools: moving instead of copying

Copying is right for messages and wrong for buffers. A pool moves them instead:

```lua
local Block = struct { n: U32, data: Array(U8, 64) }

local pooled = do(count: U32): U64
    local total: U64 = 0
    tasks do(scope...)
        local buffers = pool(Block, 4)
        local full = channel(Slot Block, 4)
        spawn do
            local k: U32 = 0
            while k < count do
                local s = buffers:take()             -- waits while all four are out
                fill(buffers[s], k)                  -- buffers[s]: checked at every use
                full:send(s)                         -- s now belongs to the receiver
                k = k + 1
            end
            full:close()
        end
        full:each(do(s)
            total = total + U64(checksum(buffers[s]))
            buffers:release(s)
        end)
    end
    return total
end
```

* `pool(T, n)` reserves `n` slots of the fixed-size, sendable type `T` once, when called. The pool never grows, so slots never move.
* `p:take()` is an operation: it waits for a free slot and returns a `Slot T` owned by the current task. Because a take can be withdrawn, `take(p) do(s) ... end` is a `first_of` case, which gives backpressure among other waits.
* `p[s]` is the slot's contents as a place: read it, assign it or its fields, pass it as a reference, read into it. Every use checks that the current task owns `s`, as a slice checks its index: inline and lock-free, a few atomic loads. Uses that nothing separates share one check (§30.6), and a send or release of any slot ends the stretch, so a name bound to `p[s]` and used after `s` was sent traps at that use.
* Sending a `Slot` on a channel moves it, alone or as a field of a message: the sender gives it before the send, and whoever receives it adopts it. A send case of `first_of` that loses keeps its slots: every other arm takes them back.
* `p:release(s)` gives the slot back to the pool, or straight to a task waiting to take one.

The consumer above compiles to the receive, the adoption, and one checked address per round of the loop:

```c
uint64_t pooled(uint32_t count) {
    slc_task *slc_tk = slc_self();
    slc_op slc_ops[1];
    slc_slot got;
    int32_t r;
    ReceivedSlotBlock r2;
    uint32_t s;
    uint32_t i;
    Block *at;
    slc_scope *scope = slc_scope_new(slc_tk);
    slc_pool pool = slc_pool_new(scope, (uint64_t)sizeof(Block), 4u);
    slc_chan ch = slc_chan_new(scope, (uint64_t)sizeof(slc_slot), 4u);
    { task_11_frame *slc_t = (task_11_frame *)slc_spawn(scope, sizeof(task_11_frame), task_11_step); slc_t->buffers = pool; slc_t->full = ch; slc_t->count = count; slc_start(&slc_t->task); }
    uint64_t total = 0ull;
    bool open = true;
    for (;;) {
        if (!open) break;
        if (slc_recv(slc_tk, slc_ops, ch, &got, "channels.slc:345: recv") == SLC_PENDING) slc_block(slc_tk);
        r = slc_tk->result;
        if (r == 1) {
            slc_slot_adopt(slc_tk, got);
            r2 = (ReceivedSlotBlock){ .tag = ReceivedSlotBlock_value, .as.value = got };
            goto L1;
        }
        r2 = (ReceivedSlotBlock){ .tag = ReceivedSlotBlock_closed };
    L1:;
        if (r2.tag == ReceivedSlotBlock_closed) {
            open = false;
        } else {
            i = 0u;
            s = 0u;
            for (;;) {
                at = (Block *)slc_slot_at(slc_tk, r2.as.value);
                if (i >= at->n) break;
                if ((uint64_t)i >= 64ull) {
                    slc_trap("slice index out of range");
                }
                s = s + (uint32_t)at->data.e[i];
                i = i + 1u;
            }
            total = total + (uint64_t)s;
            slc_slot_release(slc_tk, r2.as.value);
        }
    }
    if (slc_scope_end(slc_tk, slc_ops, scope, "channels.slc:332: the end of a tasks scope") == SLC_PENDING) slc_block(slc_tk);
    return total;
}
```

**Correctness comes from the runtime, convenience from the compiler.** Every slot records its owner by task id (ids are never reused, unlike frame addresses). Using, giving or releasing a slot the current task does not own traps, as a stale ID does (§18), and so does using a slot after it was released (slots are generational). A slot cannot leave its pool's scope: taking from a pool, or receiving one of its slots, outside that scope traps. And a pool's memory is never freed while its record can be named (a retired pool's memory waits for the next pool that fits), so even a stale slot fails its check on memory that is still there. On top of that, the compiler rejects the plain mistake, naming a slot again after it was sent or released on the same path: `this slot was sent at prog.slc:7: send; it no longer belongs to this task` (the site of the send). A mark made in one branch says nothing about the other branch or after the join, where the runtime check decides. A slot that is never released stays out of the pool until the scope ends, when the whole pool is freed: a leak bounded by the scope, never unsafety.

## 36.7 I/O by completion

I/O operations are described by their completion, never by readiness, because completion can be provided everywhere and readiness cannot. **io_uring** is completion-based: you submit an operation, and the kernel says when it is done. **kqueue** (macOS, the BSDs) and **`poll`** (any POSIX system) report readiness; their backends make it a completion by performing the system call once the descriptor is ready. A wait is the same shape on every system, and so is a program. (Windows is out of scope.)

The operations live in a library, `local io = require "slc.io"`, like the libc and POSIX vocabularies (§33–§34):

| Operation | Done with | Notes |
|---|---|---|
| `io.read(f, buf [, n] [, opts])` | the count read (0 at the end) | `buf` is an `Array(U8, N)` itself: a local, a field, a pool slot's field (`pool[s].bytes`) |
| `io.write(f, data [, n] [, opts])` | the count written | `data` is an `Array(U8, N)`, a `Slice U8`, or a string known while compiling |
| `io.open(path, flags [, mode])` | a `File` | flags `io.READ`, `io.WRITE`, `io.READ_WRITE`, `io.CREATE`, `io.TRUNCATE`, `io.APPEND` (from the system's headers) |
| `io.close(f)` | — | |
| `io.accept(listener [, opts])` | a `File` | |
| `io.connect(host, port [, opts])` | a `File` | IPv4 TCP; `io.LOOPBACK`, `io.ANY` |
| `io.pipe()`, `io.listen(host, port)` | a `Pipe`, a `File` | setup that never waits |

* **Options** are `{ at = offset }` for positioned reads and writes, and `{ deadline = d }`. A deadline adds `timed_out` to the result, and the result is exact: on a readiness backend the system call happens only once the descriptor is ready, so `timed_out` means nothing was done; on io_uring the deadline is a linked timeout, and an operation that finished first keeps its result.
* **Results are sums**, `oneof { done: U32, failed: I32 }` and its relatives, matched exhaustively; `failed` carries the system's error code (`io.ENOENT`, `io.ECONNREFUSED`, ... come from the headers). A handler table may follow the call directly: `io.read(f, buf) { done = do(n) ... end, failed = do(e) ... end }`.
* **Suspension is the borrow.** During an operation its task is suspended (plain code: blocked), so nobody but the system touches the buffer. That holds for any memory the task owns, so no extra ownership rule is needed. Reading into a pool slot and then sending the slot is zero-copy I/O between tasks.
* **I/O is never a `first_of` case**: `I/O cannot lose a first_of: give io.read a deadline ({ deadline = d }), or spawn a task that does it and receive its result` (§36.4).
* **Regular files never hold a worker or the poller.** On io_uring a file read is asynchronous in the kernel. A readiness backend hands regular-file reads and writes, and every `open` and `close`, to the blocking threads, since a regular file is always "ready" and the call blocks.

A plain-code example, with a deadline that expires on an empty pipe and then data that arrives:

```c
uint32_t timeout_then_data(void) {
    slc_task *slc_tk = slc_self();
    slc_op slc_ops[1];
    uint32_t outcome;
    int32_t reader;
    int32_t writer;
    int64_t io;
    IoPipe r;
    U8x8 buf;
    int64_t io2;
    int32_t r2;
    IoCountOrTimeout r3;
    int64_t io3;
    int32_t r4;
    int64_t io4;
    int32_t r5;
    IoCountOrTimeout r6;
    int64_t io5;
    int32_t r7;
    int64_t io6;
    int32_t r8;
    if (slc_io_pipe(&reader, &writer, &io) == 0) {
        r = (IoPipe){ .tag = IoPipe_done, .as.done = (Pipe){ .reader = (File){ .fd = reader }, .writer = (File){ .fd = writer } } };
        outcome = 0u;
        goto L1;
    }
    r = (IoPipe){ .tag = IoPipe_failed, .as.failed = (int32_t)io };
    outcome = 0u;
L1:;
    if (r.tag == IoPipe_done) {
        buf = (U8x8){ .e = { 0 } };
        if (slc_io_read(slc_tk, slc_ops, r.as.done.reader.fd, &buf.e[0u], 8u, -1ll, 20000000ull, &io2, "io.slc:72: read") == SLC_PENDING) slc_block(slc_tk);
        r2 = slc_tk->result;
        if (r2 == 0) {
            r3 = (IoCountOrTimeout){ .tag = IoCountOrTimeout_done, .as.done = (uint32_t)io2 };
            goto L2;
        }
        if (r2 == 2) {
            r3 = (IoCountOrTimeout){ .tag = IoCountOrTimeout_timed_out };
            goto L2;
        }
        r3 = (IoCountOrTimeout){ .tag = IoCountOrTimeout_failed, .as.failed = (int32_t)io2 };
    L2:;
        switch (r3.tag) {
        case IoCountOrTimeout_done: {
            outcome = 100u;
            break;
        }
        case IoCountOrTimeout_failed: {
            outcome = 200u;
            break;
        }
        default: /* IoCountOrTimeout_timed_out */ {
            outcome = 1u;
            break;
        }
        }
        if (slc_io_write(slc_tk, slc_ops, r.as.done.writer.fd, "abc", 3u, -1ll, 0ull, &io3, "io.slc:77: write") == SLC_PENDING) slc_block(slc_tk);
        r4 = slc_tk->result;
        if (r4 != 0) {
        }
        if (slc_io_read(slc_tk, slc_ops, r.as.done.reader.fd, &buf.e[0u], 8u, -1ll, 1000000000ull, &io4, "io.slc:78: read") == SLC_PENDING) slc_block(slc_tk);
        r5 = slc_tk->result;
        if (r5 == 0) {
            r6 = (IoCountOrTimeout){ .tag = IoCountOrTimeout_done, .as.done = (uint32_t)io4 };
            goto L3;
        }
        if (r5 == 2) {
            r6 = (IoCountOrTimeout){ .tag = IoCountOrTimeout_timed_out };
            goto L3;
        }
        r6 = (IoCountOrTimeout){ .tag = IoCountOrTimeout_failed, .as.failed = (int32_t)io4 };
    L3:;
        if (r6.tag == IoCountOrTimeout_done) {
            outcome = outcome + 10u * r6.as.done;
        }
        if (slc_io_close(slc_tk, slc_ops, r.as.done.reader.fd, &io5, "io.slc:83: close") == SLC_PENDING) slc_block(slc_tk);
        r7 = slc_tk->result;
        if (r7 != 0) {
        }
        if (slc_io_close(slc_tk, slc_ops, r.as.done.writer.fd, &io6, "io.slc:84: close") == SLC_PENDING) slc_block(slc_tk);
        r8 = slc_tk->result;
        if (r8 != 0) {
        }
    }
    return outcome;
}
```

The `failed` arms the program left empty disappeared; the match is the branch on the result.

## 36.8 The runtime

The compiler emits calls to the runtime's exported words; everything system-specific sits behind them. The runtime is SLC (`runtime/*.slc`, §42) and is built with the program: a program's C holds the runtime words it reaches, by name, and nothing else, so it is one file (§42.4). C holds only what C alone expresses (§42.3).

* **Workers.** N threads, one per core by default (`SLC_WORKERS` overrides), run runnable tasks from a run queue: a task's step runs until it returns `WAIT`, `YIELD` or `DONE`. Plain threads blocked in a wait run tasks too. One locked queue; work stealing can come later without changing anything above it.
* **Handoffs stay on one thread.** A task woken by the task running on a thread runs there next, Go's `runnext`: a producer and its consumer pass values without crossing threads.
* **Claims.** Whoever completes a waiting task first claims it with a compare-and-swap, so exactly one case of a `first_of` happens. A channel that closes under a waiting `first_of` makes it look again (a closed channel never fires; it may make `closed` ready).
* **Channels and pools.** A lock and queues of operation records each, for waiting senders, receivers and takers. A waiting party is an operation record, and waking it means scheduling its task. Only idle threads sleep in the operating system, each on its own condition variable, so a wake-up reaches exactly the thread it is for.
* **Timers.** A heap of deadlines; idle threads wait until the nearest one.
* **Blocking threads.** A pool that grows on demand runs `blocking` blocks and a readiness backend's file work; a blocking job counts as outstanding for deadlock detection.
* **I/O backends.** One per system: poll (`runtime/poll.slc`) and kqueue (`runtime/kqueue.slc`) are SLC, over shared POSIX words in `runtime/posix.slc`; io_uring is SLC policy over `slc_io_uring.c` (raw system calls, no liburing, because the kernel takes addresses as integers). Each has one poller thread; a completion makes its task runnable. Outstanding I/O counts for deadlock detection, so a task waiting on I/O is never reported as deadlocked.

## 36.9 Deadlocks, determinism, failure

* **Deadlock is detected exactly.** Suppose no task is runnable or running, no plain thread is active in a scope, and no timer or I/O operation is outstanding, yet some task or thread is waiting. Then nothing can ever wake it, because only tasks and scope bodies touch channels and pools. The runtime traps with `deadlock: every task is waiting` and names the wait each party is suspended in. The classic leak, a goroutine blocked forever on a channel nobody closes, becomes this diagnostic at the scope's end.
* **Deterministic mode.** With `SLC_SCHED_SEED=n`, the runtime starts no workers. The blocked plain thread runs every task, with a seeded choice among runnable tasks and ready cases. A failing concurrent test can be replayed exactly, apart from the timing of real I/O and timers.
* **A trap aborts the process,** as an unrecovered panic does in Go: an out-of-range index, a stale handle, a send on a closed channel, a slot used by a task that does not own it.
* **Cancellation is closing a channel.** There is no separate mechanism, so no operation grows a third outcome. A deadline bounds a single I/O operation; a task stops when it observes `closed`.

## 36.10 What is checked, and where

While compiling:

| Rejected | Diagnostic |
|---|---|
| a spawned block mentioning an unsendable runtime name | `a task shares no memory: the outside name 'c' is a Ref C, and a reference points into memory someone else owns; send values, or pass them to spawn` |
| assigning a copied name inside a spawned block | `'count' is a copy taken at spawn; a task cannot assign it (declare a local to change it)` |
| `spawn(f, ...)` with a non-`Unit` result | `a task's result goes nowhere; send it on a channel` |
| `spawn(f, ...)` with an unsendable parameter | `spawn: parameter 'c' of bump is a Ref C; a task shares no memory, ...` |
| an unsendable channel element | `Chan M: values crossing a channel are copies, and its field 'p' is a Ptr U8: ...` |
| a slot inside a oneof on a channel | `Chan M: a Slot inside a oneof cannot move (its ownership would depend on a runtime choice)` |
| a task waiting inside a function compiled on its own | `a wait inside walk, which is compiled as its own C function (...); a task cannot suspend inside it: loop by tail call, or keep an explicit stack` |
| a `first_of` with `recv` cases and neither `closed` nor `default` | ``first_of: when every channel is closed it runs `closed = do ... end`; give it one (or a default)`` |
| a `first_of` with `closed` but no `recv` case | ``first_of: `closed` runs when every received channel is closed, but no case receives`` |
| a receive matched without `closed` | `matching a ReceivedU32: alternative 'closed' has no handler` |
| a channel returned from its scope | `a channel cannot leave its tasks scope: it retires when the scope ends` |
| a slot named again after it was sent or released | `this slot was sent at prog.slc:7: send; it no longer belongs to this task` (the site of the send) |
| reading a slot's contents without its pool | `Slot B is a handle: its contents are addressed through its pool, pool[slot]` |
| a store addressed with something other than its Id | `Id: expected Id N, got U32` |
| an I/O operation as a case of `first_of` | `I/O cannot lose a first_of: give io.read a deadline ({ deadline = d }), or spawn a task that does it and receive its result` |
| a known count larger than its buffer | `io.read: 16 bytes do not fit a buffer of 8` |
| a wait inside `blocking do ... end` | `a blocking block runs outside the scheduler: it cannot wait (send); wait after it` |
| a timed operation matched without `timed_out` | `alternative 'timed_out' has no handler` |

At run time, these trap: a stale channel or pool handle, a send on a closed channel, closing twice, a slot used, given or released by a task that does not own it (including after sending it), a slot used after it was released, a pool used or a slot received outside its scope, a stale store Id or an out-of-range Grow index, a dynamic count larger than its buffer, and a deadlock.

Not checked: memory that C code shares behind an extern's back (§22), and a blocking call into C made outside `blocking do ... end`, which holds its worker.

## 36.11 The whole picture

| Need | Form |
|---|---|
| start work | `spawn do ... end`, `spawn(f, args...)` |
| pass a message | `channel(T, n)`, `send`, `recv`, `each`, `close` |
| pass a buffer | `pool(T, n)`, `take`, `pool[slot]`, `release`; send the `Slot` |
| wait for one of several | `first_of { ... }` over channels, pools and timers |
| talk to the system | `require "slc.io"`: operations by completion, optional deadlines |
| bound lifetimes | the `tasks` scope: joins its tasks, retires its channels and pools |
| share memory with the kernel | atomics (§35), inside libraries |

## 36.12 What the prototype implements

All of this section is built: tasks as state machines, the scheduler, channels, `first_of` over receives, sends, takes and timers, `spawn do`, pools and slots, `blocking` blocks on a blocking thread pool, I/O by completion with the `poll`, io_uring and kqueue backends, deadlock detection and deterministic mode.

The harnesses (`examples/channels.slc`, `examples/io.slc`) cover:

* a pipeline, a fan-out over four workers, `first_of` with `default`, timers, channels of channels, sum messages, nested scopes and a Grow inside a task;
* a pool pipeline, `take` as a case, and a send case that loses and keeps its slot;
* eight `blocking` blocks sleeping 50 ms each, which overlap (the run takes about 50 ms, with one worker or none);
* a pipe between tasks, a file read back at an offset, an exact timeout followed by data, a TCP echo server with twenty concurrent clients, reads straight into pool slots moved between tasks, and a refused connection.

They run in the default mode, with one worker and with seeded schedules. Every I/O check runs on all three backends, each under ThreadSanitizer, and the runtime checks (stale handles, ownership, deadlock reports) run in child processes. Hundreds of repeated runs per backend and mode found no failures.

Two bugs the backends taught, now fixed and kept in the tests:

* A kqueue poller must not touch a descriptor after completing its last operation. The woken task may already have closed it, and its number been reused; registrations are one-shot.
* A connect's error must come from the event (kqueue's `EV_EOF` carries it in `fflags`) or a confirmed peer, because `SO_ERROR` reads only once.

**Not built:** work stealing. **Not verified:** the kqueue backend runs here on Linux through libkqueue, not yet on macOS or a BSD. **Out of scope:** Windows (IOCP, and a thread layer other than POSIX threads).

**Performance, measured on two cores.** A three-stage pipeline moves about 1.5 million values per second through two channels with workers, and about 7 million on one thread in deterministic mode; the cost with workers is lock traffic between threads, not waiting.

---

# 37. Fixed-length arrays

`Array(T, n)` holds `n` elements of a fixed-size `T`, with `n` known while compiling. It is a value: a typed local, a struct field, a parameter, a pool's slot type. In C it is a struct wrapping `T e[n]`, so it copies and passes by value as structs do.

```lua
local fixed = do(): U32
    local a: Array(U32, 4) = Array(U32, 4) { 10, 20, 30, 40 }
    local b: Array(U32, 4)
    b[0] = a[3]
    b[1] = a[0] + a[1]
    return b[0] + b[1] + a.length
end
```

```c
typedef struct U32x4 { uint32_t e[4]; } U32x4;
```

```c
uint32_t fixed(void) {
    return 74u;
}
```

* `a[i]` is checked like a slice's element (§32.2): at compile time when the index is known (`index-range: index 4 is outside an array of length 4`), otherwise when it runs.
* `a.length` is known. `a:slice()` views the elements as a read-only `Slice T`.
* `Array(T, n)()` is zeroed, `Array(T, n) { ... }` lists every element, and a typed local declared without a value starts zeroed.
* Fully known array contents are immutable aggregate values in the evaluator. A typed local keeps its whole pending value; known-index reads and known writes can fold. Copies keep independent snapshots, including nested arrays and structs. Compact zero contents do not require one compiler cell per element.
* A dynamic write or a read requiring runtime indexing materializes the array conservatively; the prototype does not maintain a partly known element map afterward. Different branch results materialize on their respective paths, and loops widen as other tracked values do. Equal known contents may stay known.
* `a:slice()` is a live read-only view of the owner, not a snapshot of its contents. It can read known elements without creating an address. Once a raw address or foreign boundary requires memory, pending values are written and affected knowledge is invalidated. Explicit `Ptr(...)` remains the runtime boundary of §32.1; this is not a compile-time heap.
* Elements are fixed-size: scalars, structs, sums, arrays and channels; never references or slices. An array is sendable when its elements are.

---

# 38. Two backends: C, and libgccjit in this process

The residual program has two ways to machine code. `slc.cgen` prints it as C; `slc.jitgen` builds the same program with libgccjit, calling gccjit where cgen writes C. Both start from one preparation of the IR (`G.prepare`: cleanup, data-stack planning, give-backs at every exit, a yield point in every loop round of a task), done once per module whichever backends run, so neither can see a different program.

## 38.1 The same IR, the same rules

`slc.jitgen` mirrors cgen method by method: `place`, `expr`, `stmt`, `wait`, task frames and step functions, blocking functions, spawns, externs. Where cgen writes `xs.ptr[i]`, the emitter asks for an array access; where cgen writes `if (call == SLC_PENDING) { f->task.state = 2; return SLC_WAIT; } resume2:;`, it builds the same blocks, and the step function's resume `switch` becomes a gccjit switch over them. Bodies are built as a control-flow graph in Lua and handed to gccjit when complete, so labels, `goto`, `break` and resume points are just edges.

C's rules live in one place, `slc.cjit`: C type descriptors, the usual arithmetic conversions, integer promotions, pointer arithmetic, truth values, members, calls with default promotions for variadic arguments. gccjit itself converts nothing implicitly; this core does what a C compiler would.

## 38.2 The C inside the compiler

The compiler's own output is ordinary C for ordinary IR operations; it carries no call templates. What it does read is the runtime header `slc_rt.h`: its record layouts, constants, prototypes, thread-local stacks and inline helpers such as `slc_slot_at`. The prepared IR holds no text, so there is no template mode.

The gccjit backend does not keep a second copy of any of them. `slc.cjit` contains a reader for exactly the C subset the runtime header uses (declarations, typedefs, structs and unions, function pointers, prototypes, globals with `__thread`, static inline functions, object-like and function-like macros, compound literals with designators) and lowers it through the same core. A runtime struct's layout, a macro's value, a helper's logic each exist once.

## 38.3 What only a header knows

libgccjit reads no headers, and some values exist only in one: `O_RDONLY` (`cconst`, §34), the layout of `struct stat` (`cstruct`), the variable `errno` (`cread`). For those, the backend writes a small C file that prints the values and offsets the module uses and defines a getter for each variable, compiles it with the system C compiler, runs it, and caches the result by its text (`$SLC_CACHE`, else `~/.cache/slc`). A foreign struct then gets the header's offsets, with padding between its declared fields, and a field declared at the wrong size is rejected. A module that uses none of these never runs the probe.

## 38.4 Run it now

```lua
local tab_stop = do(config, column: U32): U32
    local width: U32 = config.tab_width
    return (column / width + 1) * width
end
local width = tonumber(arg[1])
local stop = native(tab_stop { tab_width = width })
io.write(stop(5), "\n")
```

`examples/csv.slc` does this with a file: it reads the header line and the first row in Lua, finds the field's position and its number of decimals, and compiles a decoder in which skipping the earlier fields and reading the decimals are unrolled to exactly that layout (`luajit slc.lua run examples/csv.slc examples/data/sales.csv price`). The same word, given a layout in the source, is exported and compiled ahead of time.

`native(word)` materializes a word as a function of its own (the module's C does not include it), compiles it into executable memory in this process, and returns it as a Lua function. Here the width arrives on the command line and is folded into the code before it is compiled: **start-up becomes a binding time**. Specialization is the same as at compile time; only when it happens has moved.

* `luajit slc.lua run program.slc args...` runs a program now: its Lua runs (calling `native` as it likes), its exports are compiled into the process, and an exported `main` is called; its result is the exit status.
* From Lua, `slc.load(path)` returns a program's exports as functions, plus `raw` (the bare function pointers) and `types` (FFI types for the module's structs, to build arguments: `g.types.Document { length = 3, cursor = 3 }`).
* The runtime is the same C library every backend links, built once per source text and I/O backend (`SLC_IO`, default `poll`) and loaded with its symbols global, so the generated code binds to it, its thread-local data stacks included.
* A failed check in plain code on the calling thread raises a Lua error (`slc runtime check failed: slice index out of range`) and the process goes on: each export is called through a thunk under `slc_try`, which catches the trap and gives the thread's data stacks back. A trap inside a task, or while a tasks scope is open, still aborts: other threads may be in the middle of its work.
* An extern without a header must already be in the process: `slc.load(path, { libs = { 'libx.so' } })`.

## 38.5 How the two are kept aligned

* The C backend's output is byte-identical with and without the gccjit backend present.
* Every example's C harness is linked against gccjit's object file (`luajit slc.lua --gccjit -o out.o program.slc`) and must pass, including the deterministic schedule and the io_uring backend.
* The in-process tests call examples from Lua, raise and recover from traps, and run `native(word)` on a value given at run time.
* Every record each example makes (frames, sums, foreign structs) is laid out again by LuaJIT's C parser and compared with the layout the backend assumed, since `slc_spawn` is told a frame's size.

## 38.6 What the prototype implements

Everything above, with libgccjit 13 or later on 64-bit targets. Compiling a module takes a few hundred milliseconds at `-O2` (most of it gcc; `opt` lowers it). Code quality is gcc's: with the same gcc version the two backends produce the same code. (On the machine these tests ran on, libgccjit is GCC 14 and `cc` is GCC 13, and a Collatz loop ran in 0.82 s through gccjit against 1.24 s through `cc -O2`.) ThreadSanitizer covers the C backend only, since gccjit's code is not instrumented. The C reader reads the C the compiler writes, not C in general.

---

# 39. Text

Three types, one per role, each fitting the memory model as it is: views never outlive what they view, resizable storage lives on data stacks, and values are copied.

| Type | Role | Storage | Store in a struct | Send to a task |
|---|---|---|---|---|
| `Str` | a view of text | someone else's bytes | no | no |
| `Text` | text being built | its own data stack (it is `Grow U8`) | as a field created in place | no |
| `Chars(n)` | short text as a value | inline: a length and `n` bytes | yes | yes |

## 39.1 Str

`Str` is to text what `Slice U8` is to bytes: `{ptr, len}` in C, `s.length`, a checked `s[i]` (a `U8`), `s:sub(a, b)`, and the same lifetime rules. A Lua string where a `Str` is expected is a literal, known while compiling, and so are its bytes and its length. Text is compared with words, not operators.

| Word | Gives |
|---|---|
| `s:equals(t)`, `s:starts_with(t)`, `s:ends_with(t)` | `Bool` |
| `s:find(t)` | `oneof { at: U32, missing: Unit }` |
| `s:compare(t)` | `oneof { less, same, greater }` (bytes, then length) |
| `s:trim()` | `Str` without leading and trailing spaces, tabs, CR, LF |
| `s:split(",") do(part) ... end` | each part between one-byte separators |
| `s:lines() do(line) ... end` | each line, without a last empty one |
| `s:parse(T)` | `oneof { value: T, bad: Unit }` for any integer `T`; overflow is `bad` |
| `Str.of(x)` | a view of a `Slice U8` or a `CString` (`strlen` once) |

These words are written in slc (`lib/str.slc`), so they specialize like any other. Over text known while compiling they run while compiling (`assert(host(word_count("the quick  brown fox")) == 4)`). With a known needle, the method picks a variant that takes the needle as a Lua string, a compile-time parameter, so the loop over it is Lua's and unrolls:

```lua
local is_world = do(name: Str): Bool = name:equals("world")
```

```c
bool is_world(Str name) {
    if (name.len != 5u) {
        return false;
    }
    bool same = name.ptr[0u] == 119u;
    same = same && name.ptr[1u] == 111u;
    same = same && name.ptr[2u] == 114u;
    same = same && name.ptr[3u] == 108u;
    same = same && name.ptr[4u] == 100u;
    return same;
}
```

There are no bounds checks: when an arm of an `if` cannot fall through, what follows is reached only through the other arm, so the facts of that arm hold for the rest of the block. `name.len != 5u` returning makes `name.len >= 5` known, and a constant index below a known lower bound needs no check (the range facts of §32.2, extended to `==`, `>=` and `>` against constants).

## 39.2 Text

`Text` is `Grow U8` with text words, created in place like any `Grow`: `local out: Text = Text {}`.

* `out:write(a, b, ...)` appends each value as text. Known pieces (Lua strings and numbers, known values, known `Str`) are joined while compiling into one literal; each runtime value gets the conversion its type needs: integers in decimal, `Bool` as `true`/`false`, floats as the shortest text that reads back as the same value, `Str` and `CString` as their bytes. No format string exists at run time.
* `out:str() do(s) ... end` lends the text as a `Str`, while it cannot grow (like `Grow:view`).
* `out:clear()`, `out:push(byte)`, `out.length`, `out[i]`.

Integer digit generation and Boolean formatting are ordinary SLC words in
[format.slc](../lib/format.slc), not opaque runtime conversions. `Text:write` uses
these same words for known and dynamic operands. Known formatting can disappear
entirely; dynamic formatting residualizes its loops with the caller. For example,
[formatting.slc](../examples/formatting.slc) specializes the length of a formatted
known `U64` to:

```c
uint32_t format_known_length(void) {
    return 20u;
}
```

The remaining floating-formatting helper is still a runtime boundary; migrating
that algorithm is separate work, not a property claimed for the current prototype.

## 39.3 Chars(n)

`Chars(n)` holds up to `n` bytes inline, with a length: a value like any struct, so it can be a field, a message, a pool slot and (later) a map key. `Chars(16)(s)` fills one from text: longer known text is rejected while compiling (`Chars(2) holds 2 bytes; this text has 3`), longer runtime text traps. `c:str()` views it and `c.length` is its length.

Known construction is a value operation: `Chars(n)("abc")` and `Chars(n)()` need no runtime frame, and unused capacity is zero-filled. A typed local initialized from known text can be inspected through `:str()`, compared or parsed while compiling, just like the text operations on literal `Str`. The capacity branch and byte-copy loop live in [chars.slc](../lib/chars.slc): they fold for known text and residualize for dynamic text. Lua supplies the type and compile-time capacity diagnostic, not a separate copy algorithm. The C layout and copy ABI are the same at both binding times.

A `c:str()` view records an owner, offset and the length at creation. It reads the owner's current bytes: reassigning `c` changes what the view sees, but does not change that captured length. A copied `Chars(n)` is independent. The evaluator therefore must not replace a view with a cached string snapshot; taking an address materializes its actual owner, not an unrelated static literal. This does not extend the owner's lifetime or introduce stronger raw-pointer lifetime guarantees than §32.

[The staged-values example](../examples/staged_values.slc) exercises these distinctions across known, split and dynamic inputs, nested fields, joins, loops, raw address escape and task captures. A task's view addresses its own captured value, never the parent's later contents.

A struct field cannot be a `Str` (`field 's' is a Str, a view of someone else's bytes; store text as Chars(n), or keep it in a Text`).

## 39.4 What the prototype implements

Everything above, on both backends (`examples/strings.slc`, `tests/strings_main.c`), including the UTF-8 words (`s:runes()`, `utf8.valid`, [utf8.slc](../lib/utf8.slc)): an ill-formed sequence decodes as U+FFFD and `valid` applies RFC 3629. `s:cstring()` lends a NUL-terminated copy built with the Text words for text known only when it runs. `s:parse(F64)` checks the decimal grammar in SLC and converts through libc `strtod`; known text folds while compiling. Not yet: `find` faster than the obvious algorithm. Maps are described in §40.

---

# 40. Maps and known lookup descriptions

## 40.1 Owned mutable storage

`Map(K, V)` owns fixed-size entries on one Goose data stack. `StrMap(V)` owns
entries and copied arbitrary byte keys on two stacks. Create either in place with
`{}` and pass it by `Ref`; it cannot be copied, returned by value, or captured by
another task. A task may own its own map. A map can be the last and sole resizable
field of a struct. Scope exit and trap recovery release its owned stacks.

Keys of `Map` are integers (including Duration), Bool, Id, Chars, or recursive
structs and sums of these. General arrays, floating keys, pointers and borrowed
views are not keys. Values are fixed owned data: numeric scalars, Bool, Id, Chars,
arrays, and recursive structs/sums. Standalone Unit, views, pointers, channels,
atomics and resizable values are not map values. Unit remains valid as a sum
alternative. `StrMap` accepts Str and ordinary text-to-Str coercions, including
empty keys and embedded NUL bytes.

```lua
local Counts = Map(U32, U64)
local count = do(n: U32): U64
    local m = Counts {}
    for i: U32 = 1, n do
        local k = i % 17
        m:ensure(k, 0)
        m[k] = m[k] + 1
    end
    local total = U64 0
    m:each do(k, v) total = total + v end
    return total
end
export count
```

- `m[k]` is a checked existing value place. Missing keys trap with `map-key`;
  assignment does not insert. Aggregate fields of the value are places too.
- `find(k)` returns `oneof { found: V, missing: Unit }`, with a found value snapshot.
- `has(k)` returns Bool. `put(k, v)` inserts or replaces and returns Unit.
- `ensure(k, initial)` inserts only if absent. Both arguments evaluate eagerly,
  including when an existing value makes `initial` unnecessary.
- `remove(k)` returns whether an entry was removed. `length` is the U32 live count.
- `each(activity)` visits an unspecified order. Fixed keys and values are snapshots;
  a StrMap key is a read-only view valid only during that callback.

During iteration, existing-value replacement and no-op ensure/remove are allowed.
Actual insertion/removal traps before changing storage, including through aliases
or calls. Nested traversal is allowed. Guard ownership survives task suspension
and is balanced by scope cleanup and trap recovery.

## 40.2 Semantic keys and checked references

Equality/hash observe typed values, not object bytes: Id's token/slot/generation,
Chars length and used bytes, declared struct fields, and sum tag/active payload.
Padding, unused Chars capacity and inactive payload do not affect identity.

A checked place captures a fixed key by value and resolves again after mutation,
calls and control-flow boundaries. Remove/reinsert of an equal key addresses the
new entry; it is not Store's generational identity. A StrMap place instead captures
a borrowed byte view and its length. Its owner must remain alive; each resolution
observes the view's current bytes. It does not silently allocate an owning key.

## 40.3 Immutable known descriptions

```lua
local numbers = Map.known(U32, U32, { { 1, 10 }, { 2, 20 } })
local keywords = StrMap.known(U32, { { "if", 1 }, { "while", 2 } })
local classify = do(s: Str): U32
    return keywords:find(s) { found(v) = v, missing() = U32 0 }
end
export classify
```

These are immutable host descriptions, not native map storage. Explicit types
also describe an empty entry list. All keys/values must be known; construction
snapshots inputs and rejects duplicate semantic keys. The API is `find`, `has`,
`length`, checked **value** indexing, and `each` in entry-list order while
specializing. There are no mutable places or mutators and no native/task ABI.

Known queries fold. Known missing checked indexing fails during specialization;
dynamic checked indexing traps with `map-key`. Dynamic queries residualize
ordinary SLC comparisons/branches. Bracket keys do not shadow API members, even
for keys such as `"length"`.

## 40.4 Implementation boundary

[Map algorithms](../lib/map.slc), [semantic key operations](../lib/key.slc), and
[SipHash-2-4](../lib/hash.slc) are ordinary SLC words shared by both backends.
Mutable tables use Robin Hood probing, backward-shift deletion, growth at 7/8
load, and offset-based string arenas with bounded dead-byte compaction. Pending
keys are copied before table movement, and arena aliases are rebased after
allocation. Hashing incorporates a per-process random seed; entropy failure traps.

Compiler hooks provide type/layout projection, scoped storage/guard ownership and
borrow lifetime checks. Native runtime primitives provide allocation, checked
byte spans/copies, relocation offsets, entropy and trapping—not map algorithms.
Mutable maps remain runtime storage even when their arguments are known. Known
descriptions have no mutable compile-time heap.

# 41. Library-defined types

A type is a layout plus what the language's operations mean on it. The layout is
a `struct`. The meaning is a set of **hooks**: Lua functions or native words stored
on the type under `__`-names. A hook runs while specializing and returns staged
values, places or words, so whatever it builds folds and residualizes with the
caller. No runtime dispatch, inheritance or object model is involved (§26).

| Hook | Runs for | Returns |
|---|---|---|
| `__member(x, name)` | `x.name`, `x:name(...)` | a value, place or word; `nil` falls back to fields, then methods |
| `__index(x, key)` | `x[key]` | a value or a place; a word may return a `Ref` |
| `__newindex(x, key, v)` | `x[key] = v` | nothing |
| `__cast(v, T)` | a host value or other-typed value where a `T` is expected, and `T(v)` | a `T`, or `nil` to refuse |
| `__add` `__sub` `__mul` `__div` `__mod` `__unm` | arithmetic | a `T`; the other operand is first converted through `__cast` |
| `__eq` `__lt` `__le` | comparisons; `~=`, `>` and `>=` derive from them | a `Bool` |

A hook is stored on the type, so it is written with a dot:
`function Fixed.__add(a, b)`. The hooks whose first argument is the receiver,
`__index` and `__newindex`, may also be methods: `function R:__index(i: U32): Ref E`.
The others take no receiver (`__cast` converts a value that is not yet a `T`; an
operator's operands are both `T`, and either may be the converted one), so
writing one as a method is an error.

While a type's hook runs, that type's hooks are not consulted again, so a hook
reads its own representation with ordinary field access; `rawmember(x, name)` does
the same outside a hook. Comparisons are staged only in typed bodies (§6.2, §7),
so a hook that compares is a native word. Assigning to a native field or element
works in plain Lua code as well as in typed bodies.

```lua
local Fixed = struct { raw: I32 }                    -- 16 fractional bits

function Fixed.__cast(v)
    if type(v) == 'number' then return Fixed { raw = I32(v * 65536) } end
end

function Fixed.__mul(a: Fixed, b: Fixed): Fixed
    local wide = I64(a.raw) * I64(b.raw)
    return Fixed { raw = I32(wide / 65536) }
end

function Fixed.__add(a: Fixed, b: Fixed): Fixed
    return Fixed { raw = a.raw + b.raw }
end

local scale = do(x: Fixed, y: Fixed): Fixed = x * 1.5 + y
```

The literal `1.5` goes through `Fixed.__cast` while compiling, so `scale` is two
integer operations on the representation.

Containers follow the same way. A generic type is a Lua function (§3.2), its
storage is a field of an existing resizable kind (`Grow`, `Store`), and `[]` is a
hook that returns the element's place:

```lua
local Ring = do(E, capacity)
    local R = struct { head: U32, len: U32, items: Grow E }

    function R:push(v: E): Unit
        if self.len < capacity then
            self.items:push v
            self.len = self.len + 1
        else
            self.items[self.head] = v
            self.head = (self.head + 1) % capacity
        end
    end

    function R:__index(i: U32): Ref E
        if i >= self.len then trap "ring index out of range" end
        return self.items[(self.head + i) % capacity]
    end

    return R
end
```

A type that holds a resizable field is itself resizable (§15), so ownership,
creation in place and give-back are the existing rules; nothing is declared
about them. The `Ref` returned by `__index` borrows from `self` (§17.1).

## 41.1 The built-in kinds

`Str`, `Chars(n)` and the `x[k]` places of Store, Grow, Map and StrMap register
their hooks on their types. `Ptr`, `Slice`, `Atomic`, `Chan`, `Array`, `Pool` and
`Slot` register once per family. Types with computed members and built-in methods
(`properties`, `builtin_methods`) serve them through the same `__member` hook. A
Lua string where a `Str` is expected is `Str.__cast`. What remains outside the
hooks is the default: struct fields, struct methods, and the error for a sum.

## 41.2 What this does not provide

Hooks do not hide a representation: a struct's fields stay visible unless its
`__member` refuses them. There are no declared roles; a type is copyable,
storable or sendable by the rules of the layout it is built from (§15, §17.2,
§36). There is no scalar newtype, no read-only static data and no user-defined
view lifetime; a library view is a `Slice` or `Str`.

Implemented in `slc/stage.lua`; see [type-hooks.md](type-hooks.md) and the
examples `examples/user_types.slc` and `examples/ring.slc`.

# 42. Native globals and function values

Two capabilities that the runtime needed and that any native program may use.

## 42.1 Globals

`global(T, opts)` is static storage for the whole program. It is the `Ptr T` of a C object, so `g[0]` is its place (and `g.field` a field of a record), read and written as memory in source order, never kept pending:

```lua
local hits = global(U32, { name = "hits" })
local per_thread = global(U32, { name = "per_thread", thread_local = true })
local seed = global(U32, { name = "seed", init = 100 })

local bump = do(n: U32): U32
    hits[0] = hits[0] + n
    return hits[0]
end
```

```c
static uint32_t hits;
static __thread uint32_t per_thread;
static uint32_t seed = 100u;

uint32_t bump(uint32_t n) {
    hits = hits + n;
    return hits;
}
```

| Option | Meaning |
|---|---|
| `name` | the C name (made unique at file scope); required for `exported` and `imported` |
| `thread_local` | one object per thread (`__thread`) |
| `init` | a number the object starts with; otherwise it is zero |
| `exported` | external linkage: another unit, or a header, can name it |
| `imported`, `header` | defined elsewhere and declared by `header`, which the program includes |

A global cannot be Unit, opaque, a reference, a channel, resizable storage or a view. Both backends emit it from the same IR (`gccjit` creates an internal, exported or imported global, with the TLS model for `thread_local`). An imported and an exported global of one name are one object.

## 42.2 Function values

`Fn(params): ret` is a C function pointer; `Fn({ U32 }, U32)` takes and returns a `U32`. `fnptr(word)` materializes a native word as a residual function with its declared parameter types and is that function's address. Compile-time parameters are supplied first, by partial application. Calling an `Fn` value calls through it; when the value is a known function the call is direct. `null(Fn(...))` is the null pointer, and `==` and `~=` compare addresses. An `Fn` can be a parameter, result, field, local, global or extern argument (`pthread_create` takes one):

```lua
local Op = Fn({ U32 }, U32)
local double = do(x: U32): U32 = x * 2
local square = do(x: U32): U32 = x * x

local pick = do(which: U32): Op
    if which == 0 then return fnptr(double) end
    if which == 1 then return fnptr(square) end
    return null(Op)
end
```

```c
uint32_t (*pick(uint32_t which))(uint32_t) {
    if (which == 0u) {
        return double_;
    }
    if (which == 1u) {
        return square;
    }
    return NULL;
}
```

A function whose address is taken starts its data stacks at index 0, as an export does, so it takes no hidden base parameter.

## 42.3 The runtime in SLC

With globals and function values the runtime's remaining C is SLC. [process.slc](../runtime/process.slc) holds the data-stack set a thread uses (thread-local `slc_own_stacks` and `slc_cur_stacks`), store tokens and the hash key; [tasks.slc](../runtime/tasks.slc) holds workers, plain-thread waits, scopes, the channel and pool registries, timers and blocking threads, with `pthread_create` taking `fnptr` of the thread bodies; [backend.slc](../runtime/backend.slc) starts the poll and kqueue pollers. Mutexes are zero-initialized objects initialized once through `pthread_once`.

Because programs and runtime are SLC, a program reads some runtime state in place. `lib/stacks.slc` reads the thread-local stack set as imported globals, so a data-stack access is two loads instead of a call; `lib/hash.slc` reads the process hash key the same way once it exists, taking the out-of-line path only on first use.

What stays C, and why:

| File | Why |
|---|---|
| `runtime/slc_rt.c` | `slc_trap` and `slc_try` use `setjmp`/`longjmp`, a function that returns twice; `slc_gs_pin` locates a pointer in a data stack by address comparison, and SLC has no pointer subtraction |
| `runtime/slc_io_uring.c` | the kernel takes addresses as integers (`sqe->addr`, `user_data`); SLC has no integer-pointer conversions |
| `slc_rt.h` | the shared ABI: record layouts, constants, prototypes and inline accessors such as `slc_slot_at` |

## 42.4 The runtime is built with the program

A program is one C file. The runtime's words are made lazily: `export` in `runtime/scheduler.slc` records a word, and the function is made only when something names it. Reachability follows names: a call to an extern or runtime function reaches the runtime word of that name, and so does what the generated code itself calls (data-stack bookkeeping, spawn, plain waits, the slot check). Everything else is left out, so `hello` is 13 lines of C and a program that never waits carries no scheduler.

Beside the program only C that C alone expresses links: `runtime/slc_rt.c` (traps and stack pinning) and, for io_uring, `runtime/slc_io_uring.c`. C of your own that calls runtime words the program never names asks for them: `--keep-runtime slc_stacks_free,slc_store_new` (or `SLC_KEEP_RUNTIME`).

Two paths keep a single runtime unit instead, because they must have one copy of the scheduler's state: the in-process backend (`slc.load`, `slc run`, `native`) and libgccjit objects (`--gccjit`, `slc build`), which link the unit that `make runtime` prints (`--shared-runtime` builds it).

# Appendix A. The prototype

The prototype (`slc`) implements this document except where marked. It needs LuaJIT, LPeg and a C99 compiler; the second backend (§38) also needs libgccjit.

```text
luajit slc.lua program.slc            print the C program
luajit slc.lua -o out.c program.slc   write it (-H out.h for a header)
luajit slc.lua -d program.slc         print the Lua the program becomes
luajit slc.lua --cc program.slc       also compile it with -Wall -Wextra -Werror
luajit slc.lua --gccjit -o out.o p.slc  compile it with libgccjit instead (§38)
luajit slc.lua run program.slc args   run it now, compiled into this process (§38.4)
luajit tests/run.lua                  compile, check and run every example, on both backends
```

| Part | File |
|---|---|
| LuaMacro engine and source modules | `macro.lua`, `macro/`, `macro/lib/` |
| Standalone macro CLI | `luam` |
| Native types | `slc/types.lua` |
| C-exact folding | `slc/fold.lua` |
| Values, places, lazy stores, branches, loops, words, materialization | `slc/stage.lua` |
| Stores, IDs, Grow, data-stack indices | `slc/memory.lua` |
| Immutable fixed-array contents | `slc/array_value.lua` |
| Typed-body parser and translation | `slc/syntax.lua` |
| Application, lambdas (extended) | `macro/let.lua` |
| `struct`, `export`, typed `function` | `macro/slc.lua` |
| Residual IR → C | `slc/cgen.lua` |
| Residual IR → libgccjit (mirrors cgen) | `slc/jitgen.lua` |
| C rules over libgccjit; the reader for the compiler's own C | `slc/cjit.lua`, `slc/gccjit_h.lua` |
| What only a header knows: constants, layouts, variables | `slc/probe.lua` |
| Run it now: runtime library, `native`, `slc.load` | `slc/native.lua` |
| Text: `Str`, `Text`, `Chars(n)`; the text words | `slc/strings.lua`, `lib/str.slc` |
| Runtime: ABI, record layouts, inline slot checks | `runtime/slc_rt.h`, `runtime/slc_io.h` |
| Runtime: traps and data-stack source location (C) | `runtime/slc_rt.c` |
| Runtime: scheduler, tasks, channels, pools, timers, process state | `runtime/scheduler.slc`, `runtime/tasks.slc`, `runtime/protocol.slc`, `runtime/lifecycle.slc`, `runtime/bookkeeping.slc`, `runtime/process.slc` |
| Runtime: I/O backends (selected by `SLC_IO`) | `runtime/poll.slc`, `runtime/kqueue.slc`, `runtime/uring.slc` (with `runtime/slc_io_uring.c`), over `runtime/posix.slc`, `runtime/io.slc`, `runtime/backend.slc` |
| Bundled `require "slc.*"` libraries | `lib/` (`libc.slc`, `posix.slc`, `io.slc`) |
| Driver | `slc.lua` |

Generated C includes `slc_rt.h` when it needs the runtime; link `runtime/slc_rt.c` (as an archive member, so a program that never calls into the runtime does not need it) and, for io_uring (`SLC_IO=uring`), `runtime/slc_io_uring.c`, with `-pthread` (kqueue on Linux: `-I/usr/include/kqueue -lkqueue`). The examples in `examples/` contain every program in this document; their harnesses in `tests/` link the generated C and check results (including against reference implementations, and under UBSan and ASan). `tests/errors.lua` holds programs that must be rejected, each with its expected diagnostic and line.

Limits worth knowing: the inline fuel is 400 nested applications, the known-loop fuel 100 000 iterations, and a pending value may hold up to 24 expression nodes before it is stored.
