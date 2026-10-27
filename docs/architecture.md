# slc: the compiler

*How the rules in [syntax.md](syntax.md) are implemented.* This document owns the
compilation pipeline, the partial evaluator and its residual command language, the
memory analysis that places what survives, the two backends, the runtime, the
toolchain, and the boundary between what is written in SLC, what stays in Lua and
what stays in C. [The guide](designing-and-writing-slc.md) owns how to design a
program with these mechanisms.

Section numbers are stable and are cited from the sources as `architecture §N.M`.

The compiler is Lua and the runtime is SLC. That split is not an accident of
history: everything expressible as a word is written as a word so that it
specializes with the calling program, and Lua keeps only type construction, host
metaprogramming and the primitives a specializer needs. §15 records the boundary
and the reasons for each thing that remains on the Lua or C side.

## 1. Why the compiler is shaped this way

### 1.1 Vision

slc is a small, staged systems-programming language built on Lua and LuaMacro.

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

### 1.2 Architectural rationale

#### Why Lua?

Lua already provides a complete compile-time programming environment: lexical scope, closures, higher-order functions, tables, modules and control flow. There is no need to invent another metaprogramming language.

#### Why LuaMacro, and why parse typed bodies?

LuaMacro keeps the surface Lua's: macro.let gives lambdas and application, and the same token stream feeds the typed-body parser. Parsing is unavoidable: with token rewriting alone, staging `a < b and c` correctly would need operator precedence anyway, and comparisons cannot be staged by metamethods at all.

#### Why tail recursion instead of loop syntax?

Words are already evaluated in place, so a tail call that re-enters a word is a round of a loop, and the evaluator's existing tools decide its fate: compile-time evaluation while rounds stay known, generalization of what changes under dynamic control, rollback of a round to redo it in general form. Loop-carried state becomes explicit parameters — the sugar makes the locals a loop mentions into its parameters, so nothing has to be discovered — `break` and `continue` are exit and next, and `while` and `for` stay as sugar because they read well. One mechanism replaces two.

#### Why reified commands?

Commands make native computation inspectable and transformable, and preserve what the memory checker and the backend need: effects, control flow, places.

#### Why online partial evaluation?

Known computation disappears during construction. Lua closures provide the execution mechanism; smart constructors produce residual expressions; structured blocks handle branches, mutation, loops and returns. This achieves Let-like specialization without the Let VM.

#### Why materialize only exports and re-entered keys?

Because evaluation already inlines, a boundary is needed only where evaluation alone cannot finish: where the outside world calls in, and where a key repeats. The same view explains non-termination (keys that never repeat) and gives one remedy (`dynamic`).

#### Why lazy stores?

Most native state in specialized code is private and short-lived. Keeping it pending until something needs storage makes private structs, temporaries and method round-trips free, without a separate optimization pass.

#### Why Goose?

Allocation becomes predictable and reclamation follows lexical ownership. Its restrictions make data-stack assignment simple; the compiler proves the restrictions rather than solving a general heap-placement problem.

#### Why stores and IDs?

Stores provide independent recycling without independent ownership. Generational IDs support persistent and cyclic relationships while preventing stale handles from identifying replacement objects.

#### Why C?

C is the execution target and ABI foundation. Its toolchains provide optimization, linking and portability, and the generated source stays readable.

### 1.3 Final formulation

The system is a **Lua-hosted, online specializing compiler for a typed native language**.

Its central computation is a word. A word receives requirements; known requirements are consumed during specialization. Applied, its body is evaluated in place by LuaJIT through staged closures and smart constructors. Known parts compute; unknown parts become residual native commands; a key that re-enters itself becomes a function. The commands are checked against a Goose-style ownership and storage model, then emitted as ordinary C.

> **Lua provides abstraction. Application provides specialization. Online evaluation eliminates known work. Commands preserve unknown work. Goose provides memory. C provides execution.**

The significance is not simply that Lua generates C. It is that **the generated program contains only the native work that survives progressive application and compile-time specialization**, with memory placement determined afterward from that smaller residual computation.

## 2. The compilation pipeline

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
                     PREPARE
              Cleanup rewrites, data-stack
              indices, give-backs at exits,
              a yield in every task loop round
                          |
              ┌───────────┴───────────┐
              v                       v
          C BACKEND              LIBGCCJIT
              |                       |
              └───────────┬───────────┘
                          v
                   NATIVE EXECUTABLE
```

**Residualization is not a secondary optimization pass. It occurs as staged computations are constructed and specialized.**

The preparation and the backends operate on the remaining native program, after
static computations and unreachable branches have been eliminated. Only functions
reachable from exports are emitted, and both backends see the same prepared program
(§11).

## 3. The partial-evaluation pattern

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

### 3.1 Smart constructors

```lua
local function binary(op, T, a, b)
    if a:is_known() and b:is_known() then
        return Known(T, native_compute(op, T, a.value, b.value))
    end
    return Dynamic(T, Binary(op, a:reify(), b:reify()))
end
```

`native_compute` implements the target's rules for the operation (syntax §7.1); it is not unrestricted Lua arithmetic. Integer identities are applied while constructing (`x + 0`, `x * 1`, `x * 0`, `x / 1`), and division by a known zero is rejected even when the other operand is dynamic.

```text
Known(4) + Known(3)    → Known(7)
Dynamic(x) + Known(3)  → Add(x, Const(3))
```

The programmer does not request constant folding. It occurs as operations are constructed.

### 3.2 Lua metamethods

Arithmetic (`+ - * / %` and unary `-`) uses metamethods on values and places:

```lua
local body = function(a, b, x)
    return a * x + b
end
```

With known arguments this computes a known result; with unknown arguments it constructs a residual expression. The same closure supplies both behaviours. That is the core of **online partial evaluation by evaluation**.

Metamethods cannot do everything. Comparison metamethods (`__eq`, `__lt`, `__le`) have their results coerced to a Lua boolean, so they can never return a staged `Compare`; `__eq` fires only between two tables, so `Dynamic(x) == 3` would silently be `false`. Comparisons are therefore staged by the typed-body translation (syntax §4), like `and`, `or` and conditions.

### 3.3 Why this is not simply AST interpretation

A traditional partial evaluator constructs a full program representation and walks it. Here, most specialization happens while the Lua closures that represent the program execute: known arithmetic never becomes a residual node, unknown arithmetic creates exactly the necessary expression, and known branches evaluate only their selected computation.

This does not remove the need for structured commands or an abstract state. It moves most of specialization into ordinary Lua execution.

## 4. Effects and residualization

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

## 5. Inlining, materialization and specialization keys

### 5.1 Application is evaluation

A saturated application evaluates the word's body in place, with its arguments bound. The residual code appears in the caller. **No decision is involved:** this is simply what evaluation does. The question is what forces a C function boundary, and only two things do.

### 5.2 Exports

`export name` (or `export name as "c_name"`) materializes a word as an extern C function. Its remaining requirements become parameters; supplied arguments are baked in. Exports are the roots of the program: only what they reach is emitted.

### 5.3 Re-entry of a specialization key

A specialization key is the word's identity and, for each argument, either its known value, or "dynamic of type T", or "reference to T". Its *shape* is the same without the known values.

If an application's key is already being evaluated — the word has re-entered itself with the same knowns — in non-tail position, unfolding would never end. That key becomes a C function: its dynamic positions become parameters, and the inner application becomes a call. When the outermost application of the key finishes, it is undone (its residual statements and state changes discarded) and replaced by a call, so the function appears once:

```lua
local function fact(n: U32): U32
    if n <= 1 then return 1 end
    return n * fact(n - 1)
end
assert(host(fact 10) == 3628800)  -- known: evaluated at compile time
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

A tail re-entry does not need a function (syntax §6.2): it becomes a loop in place, or a jump to the top of the function it is already in.

### 5.4 Generalization

One rule decides when unfolding stops, for tail and non-tail re-entry alike:

> **A re-entry of the same word and shape under known control keeps evaluating. Under dynamic control — reached through a branch whose condition is dynamic, or from a residual loop — the known arguments that changed are generalized, and the frame is evaluated again in that form.**

Recursion with known bounds (`pow(x, 3)`, `fact(10)`) unfolds completely. Recursion whose termination test is dynamic generalizes what would otherwise make keys differ forever, so the same key comes back and the recursion becomes a loop or a function. Tail rounds additionally stop being compile-time work as soon as a round is not entirely known (syntax §6.2).

A known argument that changes forever under known control still never repeats a key:

```lua
local function up(k: U32): U32
    return up(k + 1) + 1
end
```

After 400 nested applications the evaluator stops with an error listing the recent keys. `dynamic(e)` makes a known value a runtime parameter explicitly; generalization makes it unnecessary in the common case.

### 5.5 What is cached

- **Materialized keys**: each key has at most one function; re-entry and later applications call it.
- **Pure known calls**: within one evaluation, an application whose arguments are all static and which emitted nothing is memoized by key.

Nothing else is shared: each call site gets the residual code of its own arguments. Code size is not a concern of the semantics, but it is a concern of programs: a large word applied at many sites is that many copies. `call` (§5.7) puts a function boundary at one site.

### 5.6 Consequences

- Effect and memory summaries are needed only at boundaries: an inlined application needs none, because the caller's abstract state flows through the callee's body.
- At a materialized call, a reference to a tracked local escapes: the local is written to storage and untracked from then on.
- The data-stack recursion bound (§7) is checked only on cycles of materialized functions. A tail jump gives back the data stacks of the round it leaves.

### 5.7 `call`: what a function boundary costs

The language rule is syntax §3.9: `call` before an application makes it a residual
function, specialized on the word, its compile-time parameters and the arguments
known at the site (§5.1), shared by every `call` with the same key. A key with other
known arguments is another function. The exception is compile-time evaluation, which
has no function to call from: there `call` is ignored and the application runs in
place, so a word that uses `call` internally still runs on known inputs while
compiling (`host(sip24(...))`).

```lua
local weigh = do(x: U32): U32
    local y = x * 3
    return y + y + x
end

local both = do(a: U32, b: U32): U32
    return call weigh a + call weigh b + weigh a
end
```

```c
uint32_t both(uint32_t a, uint32_t b) {
    uint32_t t = weigh(a);
    return t + weigh(b) + (a * 3u + a * 3u + a);
}
```

An application without `call` is unchanged: the word's body is evaluated in place
with whatever is known. Meaning never changes, only the shape of the C.

A known view of a caller's local array (a `Str` over a `Chars`) crosses the boundary
as a runtime address and length, since the callee cannot name the caller's local.

The boundary is the programmer's, and `slc size program.slc` finds it. It reports the generated C per function and, for each word that is evaluated in place at several sites, the residual statements one `call` would share, with the heaviest sites and their source lines (`maps.slc:121  x3  3,600 statements  m:put(k, v + 100)`). Words too small to repay a call are left out. A large program also prints a one-line note pointing at it.

A library puts `call` at the words the report names in its own code, so that a program with a hundred map operations contains one probe, not a hundred: `lib/map.slc` at the key digest, the probe, growth, insertion and key copy; `lib/hash.slc` and `lib/key.slc` at hash finalization; `lib/storage.slc` at the `Id` check that `remove` and `borrow` share; `lib/storage_layout.slc` at the checked element address that a map read and a map write both take; `lib/stacks.slc` at its stack-set selection and at two stack growth steps. The runtime's policy words are libraries too: `withdraw`, `claim_waiter`, `drain`, `recv`/`checked_send`, `step_task` and `idle` each get a `call` where their own module applies them at several sites.

The cost is a call where there was none, so it is measured, not assumed. Sharing the SipHash block costs 33% of a map loop and sharing its round 59%, for 5% and 1% of that program's C — so `lib/hash.slc` keeps its inner loop in place, and the size of a program hashing known text stays proportional to the text. Sharing the map element address costs nothing measurable, because the C compiler inlines the smaller function back at every site, and removes 12% of a map program's C. At a hot site, leave `call` out.

## 6. The residual command representation

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

### 6.1 Declarations

Declarations are placed by the backend: a variable whose first appearance is an assignment at the top level of its function is declared there; others are declared at the top of the function; loop variables in their `for`. Only places that residual code mentions are declared.

### 6.2 Cleanup

The backend applies presentation-only rewrites that cannot change behaviour:

- `r = e; goto L` where `L:` is followed by `return r` becomes `return e`;
- jumps to the next statement and labels nobody jumps to disappear;
- stores to locals nobody reads are dropped (effects in them are kept as statements);
- a temporary used once by the very next statement is written in place, under the conditions of §4.

## 7. Data-stack assignment

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

## 8. Memory-aware specialization and ordering

### 8.1 Memory-aware specialization

Knownness is semantic information used during residualization; memory facts are verified for the residual program. They are separate responsibilities.

Specialization keys contain code identity, native types and known arguments — never absolute data-stack positions, because `gs_sp` is a relative base.

Unreachable code contributes nothing: a branch removed by a known condition allocates nothing, and only functions reachable from exports are emitted or counted.

### 8.2 Effects, aliases and ordering

- Known pure work disappears. Observable effects remain, in source order.
- Operands and arguments evaluate left to right. Effects bind their results to temporaries where they occur, so C's unspecified evaluation order never matters.
- A place whose address escapes becomes untracked storage; reads of it are reads of memory.
- A materialized call invalidates exactly the knowledge it could change: tracked locals whose address it received.
- Folding respects width, conversions and floating-point rules (syntax §7.1); LuaJIT's own arithmetic is never substituted where it differs.

## 9. The minimal semantic machinery

The compiler rests on three staging abstractions.

### Staged values

Known, dynamic, aggregate or reference. Smart constructors compute known results and construct residual expressions otherwise.

### Staged words

Requirements, identity and static supplies. Application coerces arguments, binds partials, and evaluates saturated applications in place; a tail re-entry becomes a loop, a non-tail re-entry of the same key a function, and a re-entry under dynamic control generalizes the known arguments that changed.

### Staged blocks

Places with lazy stores, isolated states for dynamic branches, joins, returns, frames whose tail rounds run at compile time while known and become jumps otherwise, and data-stack ownership of resizable values.

Everything else — generic containers, serializers, state machines, numerical kernels — is built from these and ordinary Lua functions.

The objective is not a small number of source-level features. It is a **small number of semantic mechanisms that compose**.

## 10. Worked examples

### 10.1 Stores and specialization

```lua
function Graph:add(value: U32): Id Node
    return self.nodes:add Node {
        .value,
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

### 10.2 A complete end-to-end example

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

    local box = NumberBox {
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
assert(host answer == 86)

-- Native entry
local entry = do(x: U32): U32 =
enabled_process x

export entry
```

#### Compile-time events

1. Lua evaluates `Box U32`, constructing the `NumberBox` type and its methods.
2. `affine(4, 3)` and `process true` bind static requirements.
3. `enabled_process 10` evaluates entirely at compile time: `Known(U32, 86)`.
4. `export entry` evaluates `entry` with `x` dynamic. `enabled_process x` is evaluated in place: the known `enabled` selects the branch, `transform x` stores `4 * x + 3` into `box.value` as a pending value, `box:get()` reads it back, `box:set(...)` replaces it with another pending value, and the final `box:get()` returns it.
5. `box` never needs storage: its address never escaped, its field was never forced into storage, so it is never declared.

#### Generated C

```c
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

uint32_t entry(uint32_t x) {
    return (4u * x + 3u) * 2u;
}
```

No generic abstraction, partial-application environment, closure, method dispatch, box storage, conditional branch, LuaJIT dependency, garbage collector or reference count survives. The `NumberBox` type is not emitted: no reachable code uses it.

### 10.3 Runtime memory example

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
        .value,
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

local populate_double = populate 2

local run = do(n: U32): U32
    local g = Graph {
        nodes = Store(Node) {},
    }

    populate_double(Ref g, n)

    return g.nodes.length
end

export run
```


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

## 11. Two backends: C, and libgccjit in this process

The residual program has two ways to machine code. `slc.cgen` prints it as C;
`slc.jitgen` builds the same program with libgccjit, calling gccjit where cgen writes
C. Both start from one preparation of the IR (`G.prepare`: cleanup, data-stack
planning, give-backs at every exit, a yield point in every loop round of a task),
done once per module whichever backends run, so neither can see a different program.

### 11.1 The same IR, the same rules

`slc.jitgen` mirrors cgen method by method: `place`, `expr`, `stmt`, `wait`, task frames and step functions, blocking functions, spawns, externs. Where cgen writes `xs.ptr[i]`, the emitter asks for an array access; where cgen writes `if (call == SLC_PENDING) { f->task.state = 2; return SLC_WAIT; } resume2:;`, it builds the same blocks, and the step function's resume `switch` becomes a gccjit switch over them. Bodies are built as a control-flow graph in Lua and handed to gccjit when complete, so labels, `goto`, `break` and resume points are just edges.

C's rules live in one place, `slc.cjit`: C type descriptors, the usual arithmetic conversions, integer promotions, pointer arithmetic, truth values, members, calls with default promotions for variadic arguments. gccjit itself converts nothing implicitly; this core does what a C compiler would.

### 11.2 The C inside the compiler

The compiler's own output is ordinary C for ordinary IR operations; it carries no call templates. What it does read is the runtime header `slc_rt.h`: its record layouts, constants, prototypes, thread-local stacks and inline helpers such as `slc_slot_at`. The prepared IR holds no text, so there is no template mode.

The gccjit backend does not keep a second copy of any of them. `slc.cjit` contains a reader for exactly the C subset the runtime header uses (declarations, typedefs, structs and unions, function pointers, prototypes, globals with `__thread`, static inline functions, object-like and function-like macros, compound literals with designators) and lowers it through the same core. A runtime struct's layout, a macro's value, a helper's logic each exist once.

### 11.3 How the two are kept aligned

* The C backend's output is byte-identical with and without the gccjit backend present.
* Every example's C harness is linked against gccjit's object file (`luajit slc.lua --gccjit -o out.o program.slc`) and must pass, including the deterministic schedule and the io_uring backend.
* The in-process tests call examples from Lua, raise and recover from traps, and run `native(word)` on a value given at run time.
* Every record each example makes (frames, sums, foreign structs) is laid out again by LuaJIT's C parser and compared with the layout the backend assumed, since `slc_spawn` is told a frame's size.

### 11.4 What is implemented

Everything above, with libgccjit 13 or later on 64-bit targets. Compiling a module takes a few hundred milliseconds at `-O2` (most of it gcc; `opt` lowers it). Code quality is gcc's: with the same gcc version the two backends produce the same code. (On the machine these tests ran on, libgccjit is GCC 14 and `cc` is GCC 13, and a Collatz loop ran in 0.82 s through gccjit against 1.24 s through `cc -O2`.) ThreadSanitizer covers the C backend only, since gccjit's code is not instrumented. The C reader reads the C the compiler writes, not C in general.

## 12. The runtime

### 12.1 The runtime in SLC

With globals and function values the runtime's remaining C is SLC. [process.slc](../runtime/process.slc) holds the data-stack set a thread uses (thread-local `slc_own_stacks` and `slc_cur_stacks`), store tokens and the hash key; [tasks.slc](../runtime/tasks.slc) holds workers, plain-thread waits, scopes, the channel and pool registries, timers and blocking threads, with `pthread_create` taking `fnptr` of the thread bodies; [backend.slc](../runtime/backend.slc) starts the poll and kqueue pollers. Mutexes are zero-initialized objects initialized once through `pthread_once`.

Because programs and runtime are SLC, a program reads some runtime state in place. `lib/stacks.slc` reads the thread-local stack set as imported globals, so a data-stack access is two loads instead of a call; `lib/hash.slc` reads the process hash key the same way once it exists, taking the out-of-line path only on first use.

What stays C, and why:

| File | Why |
|---|---|
| `runtime/slc_rt.c` | `slc_trap` and `slc_try` use `setjmp`/`longjmp`, a function that returns twice; `slc_gs_pin` locates a pointer in a data stack by address comparison, and SLC has no pointer subtraction |
| `runtime/slc_io_uring.c` | the kernel takes addresses as integers (`sqe->addr`, `user_data`); SLC has no integer-pointer conversions |
| `slc_rt.h` | the shared ABI: record layouts, constants, prototypes and inline accessors such as `slc_slot_at` |

### 12.2 The runtime is built with the program

A program is one C file. The runtime's words are made lazily: `export` in `runtime/scheduler.slc` records a word, and the function is made only when something names it. Reachability follows names: a call to an extern or runtime function reaches the runtime word of that name, and so does what the generated code itself calls (data-stack bookkeeping, spawn, plain waits, the slot check). Everything else is left out, so `hello` is 13 lines of C and a program that never waits carries no scheduler.

Beside the program only C that C alone expresses links: `runtime/slc_rt.c` (traps and stack pinning) and, for io_uring, `runtime/slc_io_uring.c`. C of your own that calls runtime words the program never names asks for them: `--keep-runtime slc_stacks_free,slc_store_new` (or `SLC_KEEP_RUNTIME`).

Two paths keep a single runtime unit instead, because they must have one copy of the scheduler's state: the in-process backend (`slc.load`, `slc run`, `native`) and libgccjit objects (`--gccjit`, `slc build`), which link the unit that `make runtime` prints (`--shared-runtime` builds it).

### 12.3 The runtime's mechanisms

The compiler emits calls to the runtime's exported words; everything
system-specific sits behind them. What those words are made of is §12.1, and how
they get into the program is §12.2; this is the machinery they run.


* **Workers.** N threads, one per core by default (`SLC_WORKERS` overrides), run runnable tasks from a run queue: a task's step runs until it returns `WAIT`, `YIELD` or `DONE`. Plain threads blocked in a wait run tasks too. One locked queue; work stealing can come later without changing anything above it.
* **Handoffs stay on one thread.** A task woken by the task running on a thread runs there next, Go's `runnext`: a producer and its consumer pass values without crossing threads.
* **Claims.** Whoever completes a waiting task first claims it with a compare-and-swap, so exactly one case of a `first_of` happens. A channel that closes under a waiting `first_of` makes it look again (a closed channel never fires; it may make `closed` ready).
* **Channels and pools.** A lock and queues of operation records each, for waiting senders, receivers and takers. A waiting party is an operation record, and waking it means scheduling its task. Only idle threads sleep in the operating system, each on its own condition variable, so a wake-up reaches exactly the thread it is for.
* **Timers.** A heap of deadlines; idle threads wait until the nearest one.
* **Blocking threads.** A pool that grows on demand runs `blocking` blocks and a readiness backend's file work; a blocking job counts as outstanding for deadlock detection.
* **I/O backends.** One per system: poll (`runtime/poll.slc`) and kqueue (`runtime/kqueue.slc`) are SLC, over shared POSIX words in `runtime/posix.slc`; io_uring is SLC policy over `slc_io_uring.c` (raw system calls, no liburing, because the kernel takes addresses as integers). Each has one poller thread; a completion makes its task runnable. Outstanding I/O counts for deadlock detection, so a task waiting on I/O is never reported as deadlocked.

## 13. Modules and the compilation scope

The language contract is syntax §2.1: `require` is Lua's own, extended with a source
searcher for SLC. This section is how that is implemented, and what a compilation's
module state is. It matters beyond the loader because SLC modules can hold types,
words, extern descriptors and caches that belong to exactly one compilation.

### 13.1 The searcher

`slc/loader.lua` appends **one** searcher to the host's `package.loaders`, so
preload, ordinary Lua source, native modules and any custom searcher keep their
order and precedence. It is never first: `require "io"` and `require "ffi"` still
reach Lua's modules.

For a module name, the searcher tries, in order:

1. for a bundled name `slc.name`, `lib/name.slc` and `lib/name/init.slc` beside the
   compiler (served from memory in a `make dist` binary, through
   `__slc_embedded_source`);
2. every current `package.path` template that ends in `.lua`, with `.slc`
   substituted and each `?` replaced by the slash-separated module name. A template
   that does not end in `.lua` belongs to its existing Lua loader and is left alone.

The entry program's directory contributes `?.lua` and `?/init.lua` at the front of
`package.path` for the duration of the compilation, so a project's modules resolve
relative to its entry, not to the working directory.

A found source is translated (macros applied), loaded, and given the SLC prelude as
its environment; Lua's require machinery calls the chunk with the module name and
publishes what it returns. A module that is found but invalid fails at once with its
own diagnostic: there is no fall-through to the next candidate or to a second
implementation. Missing-file diagnostics list the SLC candidates alongside the
existing Lua loader lines, because the searcher returns them in the loader's own
format.

### 13.2 The compilation scope

A process can compile several programs, and `slc.load`, `slc test` and `native` compile
inside a long-lived one. Caching a module's types or words globally would let a
later program reuse an earlier program's staging state. Clearing only `.slc` entries
would not be enough either: a Lua wrapper can keep them alive.

The compiler therefore scopes **Lua's existing cache** rather than adding one.
`M.with_context`:

* copies the host's loaded table into a fresh table and installs it as both
  `package.loaded` and the registry's `_LOADED` table (which native LuaJIT
  `require` reads);
* copies `package.loaders` and `package.preload`, appends the SLC searcher to the
  copy, and prepends the program's directory to `package.path`;
* restores the loaded/preload/loader tables and the source and native paths on
  success and on failure, including translation errors and the `no_c`/dump paths;
* refuses nested entry (`slc: nested compilation is not supported`), because the
  staging engine is single-context, and refuses it *before* touching the state.

Existing host modules keep their identity: the copy holds the same tables. Every
newly loaded module — Lua, SLC or native — lands in the compilation's table.

Compiler implementation modules (`slc/*.lua`, `macro/*.lua`) are loaded before
entering this scope and keep host lifetime, so their registration hooks cannot be
stacked twice and their native-backend and FFI state survives a compilation. What
must *not* survive is any cache of a program's words: library-word caches look
their vocabulary up through `require` (for example the `Str`, `Chars` and `format`
words in `slc/strings.lua`) instead of retaining it in a module-level variable.

### 13.3 What is shared, and what is not

* This is **not a sandbox**. Existing host module tables are shared, not deep-copied;
  explicit writes to host globals, FFI declarations, C-library state and external
  effects are not undone.
* Lua's rules are not reinterpreted: a module that returns nothing yields `true`
  unless the loader published a value; `false` does not suppress a later reload;
  cycles and a previous loader failure use LuaJIT's usual error sentinel, and
  clearing that cache entry allows the usual explicit retry.
* Returned residual artifacts — exports loaded with `slc.load`, types for the FFI —
  stay usable after their compilation ends. There is no API for evaluating old
  staged words once the compilation that made them has ended.
* Concurrent compilation is not supported; the staging engine is one context.

`make test-modules` checks the loader and cache contract: Lua/FFI dependencies,
namespaces, project modules and package initializers, Lua-source/preload precedence,
return values, explicit cache publication, repeated compilation, transitive Lua
wrappers around staged values, cycles, error recovery, nested-entry rejection and
host-state restoration. The ordinary suite drives the same loader for every bundled
library a program reaches, on both backends.

## 14. The toolchain

### 14.1 What only a header knows

libgccjit reads no headers, and some values exist only in one: `O_RDONLY` (`cconst`, syntax §18), the layout of `struct stat` (`cstruct`), the variable `errno` (`cread`). For those, the backend writes a small C file that prints the values and offsets the module uses and defines a getter for each variable, compiles it with the system C compiler, runs it, and caches the result by its text (`$SLC_CACHE`, else `~/.cache/slc`). A foreign struct then gets the header's offsets, with padding between its declared fields, and a field declared at the wrong size is rejected. A module that uses none of these never runs the probe.

### 14.2 Run it now

```lua
local tab_stop = do(config, column: U32): U32
    local width: U32 = config.tab_width
    return (column / width + 1) * width
end
local width = tonumber(arg[1])
local stop = native(tab_stop { tab_width = width })
io.write(stop 5, "\n")
```

`examples/csv.slc` does this with a file: it reads the header line and the first row in Lua, finds the field's position and its number of decimals, and compiles a decoder in which skipping the earlier fields and reading the decimals are unrolled to exactly that layout (`luajit slc.lua run examples/csv.slc examples/data/sales.csv price`). The same word, given a layout in the source, is exported and compiled ahead of time.

`native(word)` materializes a word as a function of its own (the module's C does not include it), compiles it into executable memory in this process, and returns it as a Lua function. Here the width arrives on the command line and is folded into the code before it is compiled: **start-up becomes a binding time**. Specialization is the same as at compile time; only when it happens has moved.

* `luajit slc.lua run program.slc args...` runs a program now: its Lua runs (calling `native` as it likes), its exports are compiled into the process, and an exported `main` is called; its result is the exit status.
* From Lua, `slc.load(path)` returns a program's exports as functions, plus `raw` (the bare function pointers) and `types` (FFI types for the module's structs, to build arguments: `g.types.Document { length = 3, cursor = 3 }`).
* The runtime is the same C library every backend links, built once per source text and I/O backend (`SLC_IO`, default `poll`) and loaded with its symbols global, so the generated code binds to it, its thread-local data stacks included.
* A failed check in plain code on the calling thread raises a Lua error (`slc runtime check failed: slice index out of range`) and the process goes on: each export is called through a thunk under `slc_try`, which catches the trap and gives the thread's data stacks back. A trap inside a task, or while a tasks scope is open, still aborts: other threads may be in the middle of its work.
* An extern without a header must already be in the process: `slc.load(path, { libs = { 'libx.so' } })`.

### 14.3 The single binary

`make dist` builds a single executable, `build/dist/slc`. It embeds slc's own parts
and depends on the host for the rest: LuaJIT, libgccjit, the C compiler, binutils
and the C library are dependencies, not vendored copies. Building GCC or LuaJIT is
not part of this project; packagers already ship both.

What the binary contains, and where each part comes from:

| Part | How it is included |
|---|---|
| LuaJIT | **the host's**, linked dynamically (`libluajit-5.1`) |
| libgccjit | **the host's**, loaded at run time (`SLC_GCCJIT`, else the loader's search path) |
| slc (`slc.lua`, `slc/*.lua`, `macro/*.lua`) | embedded as **LuaJIT bytecode**: no source parsing at startup |
| `lib/*.slc` | embedded sources: the compiler still specializes them with the program |
| the runtime | compiled at dist time (C plus the SLC policy), linked into `slc` with `-rdynamic`, so gccjit'd code binds to `slc_*` in the process |
| `libslc_rt.a` | built once at dist time, embedded, written out for `slc build` and for C harnesses |
| the runtime headers | embedded |
| header answers for the shipped libraries | precomputed at dist time with the host `cc` (`tools/tables.lua`), embedded as `runtime/header_tables.lua`, tagged with the C-library identity they were recorded against |
| the C compiler | **the host's `cc`**, for probes and for linking |
| `as`, `ld` | **the host's binutils**, on `PATH` |
| the C library | **the host's**, dynamically, in process and in built executables |
| temporary files | a **work directory per run** (`$TMPDIR/slc-run-<hash>-<pid>/`), holding only the runtime archive and headers, because the host `cc` needs paths; removed when the process exits |

The work directory is not a cache: nothing is reused between runs. The one real
cache is the probe-answer cache (`SLC_CACHE`, else `~/.cache/slc`), which avoids
repeating a `cc` round-trip for an unchanged header question. A run that sees the
same C library as the recorded tables answers from them without starting the
compiler; another library probes. `make test-dist` asserts this by running an I/O
program with `CC=/bin/false`.

Running code in process is gccjit's own job: it compiles into memory and slc calls
the result, exactly as the development tree does. There is no ELF loader of our own
and no runtime `.so` for `slc run`.

`slc build prog.slc -o prog` compiles the program with gccjit to an object, adds the
entry-point wrapper for an exported `main`, and links it with the embedded
`libslc_rt.a` and the host's libc through the host `cc`; the result is a dynamic
executable that runs wherever that libc does. `--emit`-style output stays available
for other build systems: `-o out.c` is the C backend and `--gccjit -o out.o` is a
linkable object.

**One C library, the host's.** Code is compiled against the host's headers and
linked against the host's libc, in process and in a built executable, so a program's
probe values (`O_RDONLY`, `struct stat`) are always those of the libc it will run
on. Probe answers are cached under the target identity (architecture, host libc
version) and the differential fuzzer runs every backend, which is what checks that
nothing in the language depends on how the code got there.

**Licence.** The `slc` binary is GPLv3; it links libgccjit (GPLv3) dynamically.
LuaJIT is MIT and stays the host's. The runtime library is GPLv3 with the GCC Runtime
Library Exception, as libgcc is, so a program `slc build` produces links
`libslc_rt.a` and the host's libc and may carry any licence its author chooses. The
header the compiler emits into generated C carries the same exception, so `-o out.c`
output is equally free.

**Checks.** `make dist` builds the binary; `make test-dist` runs a program through
it, asserts no runtime library is built, and drives `check`, `build`, `test`,
`run` on a project, `args`, the task and storage fuzzers, and the arrays example;
`make test-dist-suite` runs the whole suite with `SLC_BIN` pointing at the binary.

### 14.4 The command line

The driver is `slc.lua`. Every command below is what the sources implement; `slc` in
a `make dist` binary is the same driver with its own parts embedded (§14.3).

```text
luajit slc.lua program.slc                    print the C
luajit slc.lua -o out.c [-H out.h] program.slc   write the C, optionally its declarations
luajit slc.lua -d program.slc                 print the Lua the program becomes
luajit slc.lua --cc program.slc               also check the C with -Wall -Wextra -Werror -pedantic
luajit slc.lua --gccjit -o out.o program.slc  compile with libgccjit instead
luajit slc.lua --shared-runtime ...           declare the runtime, do not emit it
luajit slc.lua --keep-runtime a,b ...         emit runtime words no program code names
luajit slc.lua run program.slc|project [args...]
luajit slc.lua build program.slc|project -o prog [-O0..-O3] [-g]
luajit slc.lua check program.slc|project
luajit slc.lua --split dir program.slc        one C file per function beside one header
luajit slc.lua size program.slc|project [--top N] [--profile written|inline|share] [--compare]
luajit slc.lua test program.slc|project
luajit slc.lua fuzz [--seconds N] [--seed S] [--count N] [--keep] [--regressions]
luajit slc.lua fuzz --storage [--count N] [--seed S] [--keep]
luajit slc.lua fuzz --tasks [--seeds N] [--quick]
luajit slc.lua cc file.c -o file.o
luajit slc.lua doctor
luajit slc.lua version
luajit slc.lua cache [clean]
luajit slc.lua fmt [--check|--write] [--config FILE] [--] [files...]
```

Exit status is **0** on success, **1** on a compile, link or check failure, and **2**
on a usage error. Diagnostics name the `.slc` file and line, then the chain of words
being specialized when it happened, deepest last:

```text
prog.slc:2: division by zero (undefined behaviour in C)
in outer (prog.slc:4)
in inner (prog.slc:1)
```

**`run`, `build`, `check`, `test`** accept a program file, a project directory or a
`project.lua`.

* `run` compiles the program into this process: its Lua runs (calling `native` as it
  likes), its exports are compiled by libgccjit, and an exported `main` is called.
  Its result is the exit status. A program without `main` still runs through its
  top-level Lua.
* `build` requires an exported `main`; it compiles to an object, writes a small C
  entry point that calls the program's `main`, and links with the host `cc` and the
  runtime archive. A project's `options.opt`/`options.debug` become the default
  optimization and debug settings.
* `check` specializes and reports errors without emitting code.
* `test` collects `test "name" do ... end` blocks into one runner, each called under
  `slc_try` so a failing test does not stop the others; `check(cond)` inside a test
  traps with its line, and a condition known while compiling must hold then. The
  exit status counts failures. Compile-time `assert`s run under `check` and `test`
  alike.

**A project** is a `project.lua` beside the program: a return table with `entry`
(required), `paths` (extra module directories, resolved against the project), and
`options` (`opt`, `debug`). It is evaluated in a data-only environment, since Lua is
already slc's configuration language. Modules use Lua's `require` and `package.path`,
extended with an SLC source searcher (§13). `examples/project` is a working one.

**`size`** profiles the compilation and prints where the C comes from; §16 describes
the report and the thresholds. `--top N` sets how many entries each list shows.

**`--split dir`** writes that same program as one translation unit per function beside
one header: `dir/<program>.h` (types, task frames, externs, globals and every
prototype), `dir/globals.c` when the module has data of its own, and `dir/<function>.c`
for each function and task step. Every function becomes external, so a C compiler can
build the files in parallel; nothing is inlined across a unit boundary unless it is
given `-flto`.

```sh
luajit slc.lua --split out examples/maps.slc
ls out/*.c | xargs -P 16 -n 1 cc -std=c99 -O2 -I runtime -c
cc -std=c99 -O2 tests/maps_main.c out/*.o runtime/slc_rt.c -pthread -o maps
```

Measured on `examples/maps.slc` (141 functions, 9,606 lines of C): 1.5 s as one unit at
`-O2`, 0.9 s in parallel on 16 cores, and the same 0.9 s at `-O3` where the single unit
takes 1.9 s — most of `-O3`'s time is per-function work, so it is the case the option
exists for. The per-unit cost is dominated by the header every unit parses, which is
why the gain is 1.7× and not 16×; a precompiled header would close that. The binary
links and runs the same checks, and runs about 9% slower on the map harness without LTO
(the accessors are no longer inlined into their callers); `-flto` brings it back to the
single unit's speed. `--split` cannot be combined with `-o`, `-H`, `-d`, `--cc` or
`--gccjit`, which each describe one output of their own.

**`fuzz`** dispatches to the three fuzzers in `tests/fuzz/` (§17). They run the same
tree's compiler, or the embedded copy when invoked from a built binary.

**`cc`** is a thin driver over the host compiler, for probes, for C beside slc, and
for tests. **`doctor`** prints the versions it found for LuaJIT, LPeg, libgccjit, `cc`
and binutils, the cache location, and whether the runtime is linked in; it exits
nonzero when LuaJIT, LPeg or libgccjit is missing. **`cache`** prints the cache
directory, `cache clean` removes it. **`version`** prints `slc 0.5-alpha`.

From Lua, `require 'slc'` and `slc.load(path)` return the program's exports as
functions, plus `raw` (the bare function pointers), `types` (FFI types for the
module's structs, to build arguments such as `g.types.Document { length = 3 }`) and
`arity` (per name, so the host knows whether to pass arguments). A failed check in
plain code on the calling thread raises a Lua error
(`slc runtime check failed: slice index out of range`) and the process goes on: each
export is called through a thunk under `slc_try`, which catches the trap and gives
the thread's data stacks back. A trap inside a task, or while a tasks scope is open,
still aborts, because other threads may be in the middle of its work. An extern
without a header must already be in the process:
`slc.load(path, { libs = { 'libx.so' } })`.

`native(word)` materializes one word as a function of its own (the module's C does
not include it), compiles it into executable memory, and returns it as a Lua
function plus its raw pointer. This is what makes start-up a binding time: a value
read at start-up is folded into the code before it is compiled.

## 15. What stays in C and Lua, and why

**SLC-first, consistently.** Expressible behavior belongs in ordinary SLC words, so
the specializer sees it with the caller and it folds, specializes and residualizes
like any other code. Moving a function from one Lua module to another, or replacing
it with an opaque C call, is not a migration; a thin SLC wrapper around a C
algorithm does not meet the standard either. Backend inlining is not a substitute
for SLC specialization.

Classification is by behavior, never by names such as `helper`, `runtime` or
`primitive`. A native algorithm compiled from SLC is still runtime code — and that
is the point: it can specialize with the caller.

### 15.1 The standard

**Keep in the compiler** what is language machinery: syntax, native type
construction, known and dynamic values, places, effects, specialization, checked
references, control-flow generalization, the shared IR and backend lowering.

**Keep in the runtime** what is a genuine mechanism: allocation and stack
relocation, relocation-safe byte addressing and copy, entropy, traps and trap
recovery, OS calls, scheduling and wake transitions, task capture and borrowing,
atomic instructions, and the kernel's submission/completion ABI. Every retained
operation needs a mechanism-level reason; "it was already in C" is not one.

**Move into SLC** library policy and algorithms: traversal, lookup composition,
formatting, hashing and equality, table probing, deletion and rebuild, collection
APIs, and ordinary arithmetic and control-flow wrappers. When SLC cannot express
one of them, record the missing capability and add the smallest general primitive
that closes it — not a feature-specific compiler subsystem.

This is an implementation rule. It does not license a change to language semantics,
ownership, the ABI, error outcomes or a library's accepted API.

### 15.2 Where the boundary lies

| Area | Where it lives now | What stays, and why |
|---|---|---|
| Channel iteration | [`lib/channel.slc`](../lib/channel.slc): `each` is an SLC word over `recv` | waiting and successful-path slot adoption |
| I/O vocabulary and receive results | [`lib/completion.slc`](../lib/completion.slc) composes status into sums; matching is ordinary `match`; [`lib/io.slc`](../lib/io.slc) adds the flag and error constants from the headers | one wait primitive, buffer borrowing, frame storage, option/type validation, and the pack-returning argument packaging (§15.4) |
| Slice subviews | [`lib/slice.slc`](../lib/slice.slc): bounds, comparisons and trap text are words | owner identity, known byte contents, lifetime tokens, deferred addresses, and building the view |
| Text | [`lib/str.slc`](../lib/str.slc), [`lib/chars.slc`](../lib/chars.slc), [`lib/format.slc`](../lib/format.slc), [`lib/utf8.slc`](../lib/utf8.slc) | the compile-time fold of a known float (`float_is_known`/`float_text` in [`slc/strings.lua`](../slc/strings.lua)); libc is an explicit external dependency of decimal conversion |
| `Store`/`Grow`/maps | [`lib/storage.slc`](../lib/storage.slc), [`lib/storage_layout.slc`](../lib/storage_layout.slc), [`lib/map.slc`](../lib/map.slc), [`lib/key.slc`](../lib/key.slc), [`lib/hash.slc`](../lib/hash.slc) | checked stack byte access and copy, relocation, entropy, traps, and `Mem.view`/`checked_place` ownership integration |
| Data stacks | [`lib/stacks.slc`](../lib/stacks.slc) | TLS stack-set selection (`slc_stacks_current`) and the const-pointer adapters `slc_gs_write`/`slc_stacks_unwind` |
| Scheduler, bookkeeping | [`runtime/scheduler.slc`](../runtime/scheduler.slc), [`runtime/bookkeeping.slc`](../runtime/bookkeeping.slc): xorshift, run-queue selection, timer heap, worker configuration | the lock, clock reads, claims, parking and wake transitions |
| Channel/pool protocol, lifecycle | [`runtime/protocol.slc`](../runtime/protocol.slc), [`runtime/lifecycle.slc`](../runtime/lifecycle.slc): waiters, transfers, slot ownership, registries, scope teardown, first-of scan/arm/withdraw/retry | the lock transactions, memory orders, claim ordering, unlock-before-trap and successful-path adoption |
| POSIX and I/O construction | [`runtime/posix.slc`](../runtime/posix.slc), [`runtime/io.slc`](../runtime/io.slc) | syscalls, errno and blocking callback submission |
| Event loops | [`runtime/poll.slc`](../runtime/poll.slc), [`runtime/kqueue.slc`](../runtime/kqueue.slc), [`runtime/uring.slc`](../runtime/uring.slc), [`runtime/backend.slc`](../runtime/backend.slc) | native thread start; io_uring keeps `mmap` and integer-address kernel marshalling in C |
| Atomics, durations, formatting | atomic words are IR operations; [`lib/duration.slc`](../lib/duration.slc) unit arithmetic | the atomic instructions themselves and memory-order validation |
| Compiler, FFI, macros | Lua, by role | type construction, host metaprogramming, the specializer, header probing |

### 15.3 Retained mechanisms

* **Parsing, macro expansion, types, places, knownness, specialization,
  generalization, the IR**: compiler semantics. This does not excuse an application
  algorithm hidden in a macro expansion or a generated helper.
* **Instruction lowering, ABI and layout probing**: backend and interop mechanics.
  No feature algorithm may be duplicated between the C and libgccjit backends.
* **Allocation, relocation-safe byte addressing, entropy, trap recovery, scope
  cleanup, task capture, borrowing**: storage, lifetime and platform mechanics. A
  feature-specific convenience wrapper around one is still a removal candidate.
* **Atomic instructions, lock/park/wake transitions, kernel submission and
  completion**: concurrency and platform boundaries. The scheduling and collection
  policy around them stays subject to migration.

### 15.4 What the compiler still composes

Two library-composition items remain in compiler Lua. Both were reviewed against
§15.1 and are **accepted as compiler primitives** by decision, not migration debt:

* `cformat(...)` returns a **pack** — the format string plus the promoted arguments
  — so that `printf(cformat(...parts))` can pass them on. Packs are second-class
  (syntax §10.8): they cannot be returned, stored or passed whole, so no ordinary
  word can build one. Format selection, literal rendering and percent escaping are
  host metaprogramming over a variadic pack, which the standard allows; the only
  lowering involved is the ABI default promotion, a `vaconv` IR operation in both
  backends. Replacing it needs a returnable pack or an explicit "spread these
  arguments into this call" form: a language extension, recorded here rather than
  taken unasked.
* the **I/O vocabulary** (`io.read`/`write`/`open`/…) has optional positionals plus
  an options table plus a trailing handler block, and its result sums and `done`
  projections are type-level. What remains in the compiler is exactly what the
  standard keeps: one wait primitive, buffer borrowing, frame storage, type and
  option validation, and the diagnostics. Status-to-sum composition and matching
  are already SLC words ([`completion.slc`](../lib/completion.slc)); the residue is
  argument packaging, which needs the same pack/spread form or an
  options-struct-only API — a public interface change.

### 15.5 The C, function by function

Every remaining C translation unit was read for this boundary. Each entry is a
mechanism, not a policy the SLC modules could own today:

| File | What it does | Why it is C |
|---|---|---|
| [`runtime/slc_rt.c`](../runtime/slc_rt.c) | `slc_trap`/`slc_try` (setjmp), locating a pointer in a data stack, the const-pointer write adapter | `setjmp`/`longjmp` return twice; SLC has no pointer subtraction. The stack sets, store tokens and the hash key are [`runtime/process.slc`](../runtime/process.slc) |
| [`runtime/slc_io_uring.c`](../runtime/slc_io_uring.c) | ring setup and `mmap`, integer-address marshalling | the kernel takes addresses as integers (`sqe->addr`, `user_data`) and SLC has no integer-pointer conversions |
| [`runtime/slc_rt.h`](../runtime/slc_rt.h) | record layouts, constants, prototypes and `static inline` accessors (`slc_slot_at`, `slc_store`, `slc_grow`, …) | the shared ABI both backends read; no policy algorithm lives there |
| [policy C](../slc/runtime_build.lua) | the compile of `runtime/*.slc` into the policy object | it *is* the SLC modules |

Task records, spawn, workers, scopes, registries, timers, blocking threads and the
deadlock report are [`runtime/tasks.slc`](../runtime/tasks.slc) over native globals
and `fnptr` thread bodies (syntax §21): mutex and condition-variable transitions are
libc calls made from SLC. The poll and kqueue poller threads are
[`runtime/backend.slc`](../runtime/backend.slc). Per-type generated helper C is
gone: the backends use `slc_store`, `slc_grow`, `slc_id`, `slc_map` and `slc_strmap`
from the header directly.

### 15.6 What remains

1. **Numeric conversion.** Decimal formatting and parsing are
   [`format.slc`](../lib/format.slc) words that call libc `snprintf`/`strtod`; a fully
   SLC decimal kernel would replace the libc trial, not the composition around it.
2. **The two composition items of §15.4**, both blocked on a language form rather
   than on effort.
3. **Boundary review.** Synchronization and diagnostic code inside
   `runtime/tasks.slc`, `protocol.slc` and `lifecycle.slc` was reviewed at the policy
   level, not line by line; the deadlock report and some surrounding bookkeeping are
   the parts most likely to hide ordinary logic.

Displaced C and generated-C algorithms survive in `tests/*_reference.h` and the map
oracle as **historical test oracles** — never as production implementations or
fallback paths. Passing an oracle is not acceptance evidence for its SLC
replacement; the model checks in [`tests/map_types.lua`](../tests/map_types.lua) and
the storage fuzzer exercise the SLC algorithms directly.

This section records an inspection of the collection, text, slice, channel, I/O,
timer, scheduling and pool policy. It is **not** a claim that every line of the
specializer, backend or synchronization implementation has been audited.

## 16. Measuring code size

`slc size` answers one question: which applications in place are worth a `call`
boundary, and which module wrote the C. It is a measurement, not an estimate: the
backend records how many lines each residual statement became, so a figure is lines of
the C in front of you. The user-facing loop is in
[the guide](designing-and-writing-slc.md#112-code-size-and-compile-time); this is
what the report means and where its numbers come from.

**What is profiled.** `slc/size.lua` installs a profile on the staging engine and
records each saturated application: the word, its specialization key, the source site,
the module that wrote it, and the range of residual statements it covers
(`Builder:emit` keeps the stream, `S.emitted()` its length). A record is closed when
the application ends; an application abandoned by a rolled-back loop round is dropped.

**What is measured, and what is not.** After emission, each statement in the stream
that the C backend printed carries the number of lines it became (`Fn:block` in
`slc/cgen.lua` records a statement's own lines, excluding the statements nested in
it, so a range sums without counting a child twice). A statement the rewrites of §6.2
dropped carries no count, and a range that lost statements therefore shrinks: **the
figures are the emitted C, not the evaluator's work**. Three sources of phantom copies
are excluded by construction: statements on a path the specializer already knows is
dead, the runtime words staged so a program *may* name them, and the body of any
function the program's exports never reach (`G.reachable` marks `fn.emitted`).

**Where the C comes from.** Every statement is attributed to the module that writes
it: the innermost word under evaluation, or the body of the materialized function it
belongs to. Summed over the emitted C, that is the first table of the report, and it
answers a question the per-word list cannot — whether the program is mostly the
program or mostly a library:

```text
examples/strmaps.slc: 10,612 lines of C from 113 source lines (94x), 104 functions

where the C comes from
     3,033   29%  lib/stacks.slc
     2,607   25%  lib/map.slc
     1,172   11%  lib/hash.slc
       747    7%  lib/storage_layout.slc
       317    3%  lib/str.slc
       113    1%  examples/strmaps.slc
        66    1%  lib/slice.slc
        20    0%  runtime/process.slc
        37    0%  3 further modules
     2,500   24%  declarations, headers and function prologues
```

**What is ranked.** Per word, the report computes what one shared copy per
specialization key would remove, in lines:

```text
saves = Σ over keys of (applications × lines − lines)
```

so a word applied once saves nothing, and one applied at twenty sites saves nineteen
copies. Entries are listed when `saves ≥ 100` lines and one application adds at least
4: a word of a line or two is not worth a boundary, while a ten-line body copied
three hundred times is, and the `each` column says which of the two a line is. The
figure counts the copies, not the net difference: a call site, the temporaries its
arguments need and the function's own prologue add lines back, so `call` on
`lib/stacks.slc`'s byte accessor predicted 1,283 lines saved and cost 200 — the
report names the candidate, the C decides.

**The report** (default 8 entries per list, `--top N`) prints the source path, the C
line count, the modules, the generated functions by size, then the ranked words with
their heaviest source sites, read back from the program's file or from the library or
runtime module the application is written in (`lib/stacks.slc:101  x66  594 lines`).
That source echo is what makes the report actionable: it names the application to put
`call` before, wherever it is written.

**A site inside a loop is marked.** The backend records whether each statement is
printed inside a loop, and a candidate's sites are annotated with it (`(in a loop)`,
or `every site is in a loop` for the word). That is the second half of a size figure:
a shared body inside a loop is a call per iteration, while one in straight-line code —
the unrolled eight bytes of `hash.u64`, for example — costs a call and nothing else.
`examples/key_encoding.slc` is 127% above its geometric mean for exactly this reason:
its hash is unrolled over a known layout, and the words with the most to share
(`byte`, `block`, `sip_round`) are all inside the per-byte path.

**The three profiles.** `slc size --compare` compiles the same program three ways and
puts the figures side by side, which is the only way to see how much of the C a `call`
decision is moving:

```text
examples/maps.slc: 183 source lines, compiled three ways

  profile  lines of C   functions   compile  how `call` is read
  share         7,402         594     1.0 s  every application that can cross one
  written       9,607         140     1.6 s  as written
  inline       50,112          72    11.4 s  ignored: everything in place
```

`inline` ignores every `call` (`S.call_policy = 'inline'`), which is always sound: an
application without `call` is evaluated in place (syntax §3.9). `share` asks for a
boundary at every saturated application that has something unknown left to do, except
where one cannot exist — a callback, a compile-time application, an argument that
cannot cross, a word that reaches another function's local, a chain that suspends
where a task would call it. Those stay in place and are counted. Two programs in
`examples/` have no all-shared form at all (`ring` and `stress`): a materialized call
that returns a reference produces a value that cannot be passed on as a `Ref`. The
report says so instead of guessing. `--profile written|inline|share` prints the full
report for one of them.

**Neither extreme is the target.** The inlined end is a pile of copies and the shared
end is a call on every path that reaches one, so a program wants to be inside the range,
and the geometric mean of the two is the fair reference for sizes (the arithmetic mean
is printed too, since it is the one people estimate by eye). The last lines of
`--compare` say where the program as written sits against them:

```text
the extremes bracket this program: 2,959 lines with everything in place, 652 all-shared;
their geometric mean is 1,389 and their arithmetic mean 1,806.
as written is 1,484: 2.28x the all-shared end, 2.0x below the inlined one.
below both means: sharing more would buy size with calls on the paths that
reach them, which is between the extremes and where a program wants to be.
```

Read it as a rule of thumb, not a verdict. Below the means, the library boundaries are
already doing the work and a further `call` buys C with a call on a real path; above the
geometric mean, the program still has copies worth sharing and the report names them;
above *both* means the `call`s in play are not paying for themselves, which is what
`examples/boundary.slc` shows (43 lines as written, 18 with every `call` ignored, 45
all-shared) because that program exists to demonstrate boundaries. Examples below the
geometric mean: `maps` (9,607 against 19,260), `strmaps` (10,612 against 22,045),
`channels` (5,198 against 5,284), `guide` (5,309 against 5,334). `io` sits just above it
(4,823 against 4,683) and has little left to share.

A small program can sit below the all-shared end instead: `examples/arrays.slc` is 190
lines as written, 212 with every `call` ignored and 222 all-shared, so `--compare` says
that sharing everything would make it bigger — every boundary there costs more than the
copy it removes. The rule of thumb is about programs with large specialized bodies, not
about programs whose words are two lines long.

**Size is not speed, and the C compiler decides.** A shared body is also a body the C
compiler may stop inlining, which is how a size change becomes a runtime change. Three
measurements on this tree, all with `cc -O2` and the example harnesses: sharing the map
element address (`lib/storage_layout.slc`) is free, because gcc inlines the smaller
function back at every site; sharing `lib/stacks.slc`'s twelve-line stack-set selection
is free for the same reason; but `call`ing `hash.finish` at the two sites in
`examples/hashing.slc` takes that program from 1,324 lines of C to 1,202 and makes its
1 KB streaming path slower (3 ms to 4 ms per harness run, which is process start here),
because gcc then stops inlining the function and the `State` it hashes leaves its
registers. A `call`
on a word with one call site is free and pointless; a `call` on a word with many is
where both the saving and the cost appear, and only the C compiler knows which way it
will go for a given body.

The count that matters is per program and per key, which is why the report never
recommends removing one. `lib/hash.slc` places no `call` inside `hash.sip24`: a boundary
there is worth 14 lines to a program that hashes one dynamic string and its function's
prologue to a program with no second site. A program with several sites asks for the
sharing itself — three dynamic strings through `call hash.sip24(...)` are 242 lines of C
against 655, and each site is then one call rather than a copy of the whole hash.

**What it does not do.** It does not choose for you, and it does not change the
program. `call` at a known site still specializes on the known arguments (syntax
§5.7), so a `call` on a word applied to many constants yields one function per
constant, which the report shows as little saving. It counts lines, not time: a small
body copied many times is a size problem and a boundary there adds a call to whatever
path reaches it, which is why §5.7's measurements were needed to settle the hash
inner loop. A program that prints more than 20,000 lines of C gets a one-line note on
stderr pointing at `slc size`; the note is the only automatic advice the compiler
gives.

**What linkage and the C compiler do with it.** Every word whose C is emitted once and
called only from this program is `static`, and the module's own data is `static
__thread`. What stays external is the program's `export`ed words — the C entry points —
and the runtime's words, which are `export`ed in `runtime/*.slc` and declared in the
runtime headers because `--shared-runtime`, `--gccjit` and `slc build` link a runtime
unit that provides them (§12.2). That is the only real cost of the arrangement, and it
is small: on `examples/maps.slc` not one of the 55 runtime definitions emitted beside the
program is still called after inlining at `-O2` — every one is inlined into its callers
despite external linkage, and their out-of-line copies stay in the binary because the
linker must keep
an exported symbol. `-ffunction-sections -fdata-sections -Wl,--gc-sections` drops them:
79,921 bytes of `.text` become 77,378 on that program, and 57,900 become 54,237 on
`examples/channels.slc` (−3% and −6%). Marking those copies `static` instead would need
the runtime headers split into types and prototypes, and would recover the same few
percent; adding `inline` to the emitted C would buy nothing, because the C compiler
already inlines every one of them.

**The optimization level matters more than either.** The map harness, ten runs and the
`.text` of the whole program: `-O0` 41 ms and 134 KB, `-O1` 9 ms and 63 KB, `-Og`
11 ms and 71 KB, `-O2` 8 ms and 78 KB, `-O3` 8 ms and 92 KB. `-O2` is the knee and
what `slc build` uses; `-O3` spends 14 KB to stand still on that program.

**Run on the libraries.** Running this loop over the builtin libraries is what set
the `call` sites §5.7 lists, and the first table is what drove the last round of it:
`lib/stacks.slc` was 42% of a StrMap program and 53% of a store program, and the
ranked list named `get`, twelve lines of C copied 41 to 361 times. Sharing it took
`examples/strmaps.slc` from 14,422 lines to 10,612 and `examples/maps.slc` from 11,386
to 9,607, with the map and store harnesses unchanged; it cost six lines on a program
that reaches a store once, which is the trade a shared small body always makes.
`saves` predicts the copies removed, not the net diff — a call site and its argument
setup add lines back, so a change is kept or dropped by re-measuring the C.

## 17. Status, limits and remaining work

### 17.1 What is implemented

Everything in [syntax.md](syntax.md) is implemented unless §17.2 lists it. The
features are exercised by programs in `examples/`, each with a harness in `tests/`
that links the generated C and checks results, and by the in-process checks.

| Area | Contract | Checked by |
|---|---|---|
| application, words, partial application, `call` | syntax §2–§3, §5.7 | `examples/boundary.slc`, `examples/spec_core.slc` |
| typed control flow, state, loops, generalization | syntax §4–§6 | `examples/spec_core.slc`, `examples/claims.slc`, `examples/stress.slc` |
| types, C-exact folding, conversions | syntax §7 | `examples/spec_core.slc`, the differential fuzzer |
| methods, references, stores, `Grow` | syntax §8–§9 | `examples/stores.slc`, `examples/memory_views.slc` |
| activities, opening, spread, `endall`, packs | syntax §10 | `examples/activities.slc` |
| sums and matching | syntax §11 | `examples/sums.slc` |
| pointers, slices, range facts | syntax §12 | `examples/memory_views.slc` |
| fixed-length arrays | syntax §13 | `examples/arrays.slc` |
| text: `Str`, `Text`, `Chars(n)`, UTF-8, parse | syntax §14 | `examples/strings.slc`, `examples/staged_values.slc` |
| maps, `StrMap`, known descriptions | syntax §15 | `examples/maps.slc`, `examples/strmaps.slc`, `examples/known_maps.slc`, `examples/map_models.slc` |
| library-defined types | syntax §16 | `examples/user_types.slc`, `examples/ring.slc` |
| externs, `CString`, formats, libc, POSIX | syntax §17–§18 | `examples/libc_demo.slc`, `examples/posix_demo.slc`, `examples/base64.slc`, `examples/boundary.slc` |
| atomics, fences, `atomic_ptr` | syntax §19 | `examples/atomics.slc` (also under ThreadSanitizer) |
| tasks, channels, pools, `first_of`, I/O by completion | syntax §20 | `examples/channels.slc`, `examples/io.slc`, `examples/channel_iteration.slc` |
| native globals, `Fn`, `fnptr` | syntax §21 | `examples/globals.slc` |
| the runtime built with the program | architecture §12 | `tests/run.lua`'s codegen expectations (`hello` carries no runtime) |

The I/O checks run on all three backends (`poll`, `uring`, `kqueue` through
libkqueue), each under ThreadSanitizer where that backend supports it. `make test`
runs the whole set, the rejection diagnostics (`tests/errors.lua`), the codegen
expectations, `slc size`, the three fuzzers and the documentation checks.

### 17.2 What is not

| Not implemented | Where the design says so |
|---|---|
| Variable-size values: a value whose size is fixed at construction but not known while compiling (an array sized by a parameter) | syntax §9.3 and syntax §22 |
| Work stealing; the run queue is one locked queue | syntax §20.8 |
| Maps of maps (a map as a store payload or a map value) | syntax §15.1 |
| `s:find` faster than the obvious algorithm | implementation note, not a contract |
| A fully SLC decimal conversion (libc `snprintf`/`strtod` are called today) | architecture §15.6 |

| Not verified here | Consequence |
|---|---|
| The kqueue backend on macOS or a BSD: it runs on Linux through libkqueue | platform differences in its events are untested |
| A second architecture (aarch64): the binary builds and passes its checks on x86-64 | target-specific layout and ABI assumptions are untested |
| Windows (IOCP, or a thread layer other than POSIX threads) | out of scope |

### 17.3 The fuzzers

Three fuzzers share one principle: whatever runs the same program must agree.

**The differential fuzzer** ([`tests/fuzz/fuzz.lua`](../tests/fuzz/fuzz.lua),
generator in [`gen.lua`](../tests/fuzz/gen.lua)) builds a random program with a
known/full/split decomposition and runs it every way slc can: fully known while
compiling, exported through C at `-O0` and `-O2`, compiled in process by gccjit, and
split with some inputs supplied. Every tenth program's C build also runs under
UBSan, every fiftieth under ASan. A mismatch is shrunk on the AST — drop a statement,
replace an expression by a constant, inline a call, drop a parameter, narrow a type —
and saved to `tests/fuzz/regressions/`, which `tests/run.lua` re-checks on every
backend.

**The storage model fuzzer** ([`storage.lua`](../tests/fuzz/storage.lua)) runs random
store, grow, text, map and `StrMap` operation sequences in SLC and on a Lua model with
exact 64-bit checksums, including deliberate stale-`Id`, out-of-range, removed-key and
removed-`StrMap`-key cases that must trap where the model says they are invalid. A
`StrMap`'s iteration order is unspecified, so the model checks membership, not order.

**The task fuzzer** ([`tasks.lua`](../tests/fuzz/tasks.lua)) runs five written
templates whose result cannot depend on the schedule — a pipeline, four shared
workers, a pool handoff, a `first_of` against a distant timer, and a deliberate
deadlock — under seeded schedules and with worker threads. Every run must print the
same bytes, and the deadlock template the same report.

Commands: `slc fuzz --regressions`, `slc fuzz --seconds N --seed S`, `slc fuzz
--storage`, `slc fuzz --tasks`. The alpha gate is a week of nightly runs (eight
hours) with no open mismatch, on top of ten minutes per commit. Those commands do
not establish that the gate has been met.

### 17.4 Limits the compiler enforces

| Limit | Value | Meaning |
|---|---|---|
| inline fuel | 400 nested applications | a known argument that never repeats a key stops with an error listing recent keys (syntax §5.4) |
| known-loop fuel | 100 000 iterations | a generation-time loop that does not finish under known control |
| pending value | 24 expression nodes | a larger computed value is stored instead of kept pending (syntax §5.3) |

`make doctor` reports what the host has; `make test-native` requires libgccjit and
is not an optional skip; `make test-scheduler` requires it too and covers the runtime
policy objects, recursive layouts and the queue/heap/channel/pool models.

## 18. Source layout

| Part | Source |
|---|---|
| Driver and embedding entry | [`slc.lua`](../slc.lua) |
| Project file resolution | [`slc/project.lua`](../slc/project.lua) |
| Host compiler, cache location | [`slc/toolchain.lua`](../slc/toolchain.lua) |
| LuaMacro engine and upstream modules | [`macro.lua`](../macro.lua), [`macro/`](../macro/), [`macro/lib/`](../macro/lib/) |
| SLC application, lambdas, typed bodies | [`macro/let.lua`](../macro/let.lua), [`macro/slc.lua`](../macro/slc.lua) |
| Standalone source-macro CLI | [`luam`](../luam) |
| Native types and constructors | [`slc/types.lua`](../slc/types.lua) |
| C-exact folding | [`slc/fold.lua`](../slc/fold.lua) |
| Typed-body parser and translation | [`slc/syntax.lua`](../slc/syntax.lua) |
| Values, places, lazy stores, branches, loops, words, materialization, tasks, I/O | [`slc/stage.lua`](../slc/stage.lua) |
| Goose storage and record layouts | [`slc/memory.lua`](../slc/memory.lua) |
| Immutable fixed-array contents | [`slc/array_value.lua`](../slc/array_value.lua) |
| Text types and their compile-time fold | [`slc/strings.lua`](../slc/strings.lua) |
| `Map`/`StrMap` type hooks and layouts | [`slc/maps.lua`](../slc/maps.lua) |
| Residual IR → C | [`slc/cgen.lua`](../slc/cgen.lua) |
| Residual IR → libgccjit (mirrors cgen) | [`slc/jitgen.lua`](../slc/jitgen.lua) |
| C rules over libgccjit; the C reader | [`slc/cjit.lua`](../slc/cjit.lua), [`slc/gccjit_h.lua`](../slc/gccjit_h.lua) |
| Header probes and their cache | [`slc/probe.lua`](../slc/probe.lua) |
| In-process execution: runtime library, `slc.load`, `native` | [`slc/native.lua`](../slc/native.lua) |
| Runtime policy build (shared unit and dist) | [`slc/runtime_build.lua`](../slc/runtime_build.lua) |
| Statement profiling for `slc size` | [`slc/size.lua`](../slc/size.lua) |
| Formatter | [`slc/fmt.lua`](../slc/fmt.lua), [`slc/fmt_cli.lua`](../slc/fmt_cli.lua) |
| Module loader and compilation scope | [`slc/loader.lua`](../slc/loader.lua) |
| Bundled `require "slc.*"` vocabularies | [`lib/`](../lib) |
| Runtime: ABI, record layouts, accessors | [`runtime/slc_rt.h`](../runtime/slc_rt.h), the `runtime/slc_io*.h` headers |
| Runtime: traps and data-stack location (C) | [`runtime/slc_rt.c`](../runtime/slc_rt.c) |
| Runtime policy (SLC) | [`runtime/scheduler.slc`](../runtime/scheduler.slc), [`tasks.slc`](../runtime/tasks.slc), [`protocol.slc`](../runtime/protocol.slc), [`lifecycle.slc`](../runtime/lifecycle.slc), [`bookkeeping.slc`](../runtime/bookkeeping.slc), [`process.slc`](../runtime/process.slc) |
| Runtime: I/O backends (selected by `SLC_IO`) | [`runtime/poll.slc`](../runtime/poll.slc), [`runtime/kqueue.slc`](../runtime/kqueue.slc), [`runtime/uring.slc`](../runtime/uring.slc) with [`runtime/slc_io_uring.c`](../runtime/slc_io_uring.c), over [`runtime/posix.slc`](../runtime/posix.slc), [`runtime/io.slc`](../runtime/io.slc), [`runtime/backend.slc`](../runtime/backend.slc) |
| Single binary | [`tools/embed.lua`](../tools/embed.lua), [`tools/launcher.c`](../tools/launcher.c), [`tools/tables.lua`](../tools/tables.lua) |
| Editor support | [`tools/tree-sitter-slc/`](../tools/tree-sitter-slc) |
| Examples, fixtures and checks | [`examples/`](../examples), [`tests/`](../tests) |

Generated C includes `slc_rt.h` when it needs the runtime. Beside it, link
`runtime/slc_rt.c` (or the archive `make runtime` prints, so a program that never
calls into the runtime does not need it), `runtime/slc_io_uring.c` for
`SLC_IO=uring`, and `-pthread`. On Linux, the kqueue backend needs
`-I/usr/include/kqueue -lkqueue`. Generated C enables the POSIX feature declarations
before system headers.

The examples in `examples/` are the programs of [syntax.md](syntax.md); their
harnesses in `tests/` link the generated C and check results, including against
reference implementations and under UBSan and ASan. `tests/errors.lua` holds programs
that must be rejected, each with its expected diagnostic and line.
49