# Exploring the depth of SLC DSLs

This is an exploratory notebook, not a compiler change or a production library.
The executable probes are in [dsl_depth.slc](dsl_depth.slc), with an independent
[C harness](dsl_depth_harness.c). Generated artifacts live in ignored
[build/](../build/) under this workspace. No new macros or compiler primitives.

## What we actually observed

| Probe | Description | Generated C, before C optimization |
| --- | --- | --- |
| Multiple interpretations | One formula receives an arithmetic or printing vocabulary | `return x * 3u + 7u;` for native evaluation; the printing interpretation is asserted during compilation |
| Stream composition | range → map → filter → sum | One loop; no callback calls, pipeline objects, or intermediate collections |
| Fully known stream | The same stream with `n = 10` | `return 36u;` |
| Order of composition | Filter above five before vs after doubling | Different predicates in otherwise fused loops; at `n = 4`, results are 0 and 14 |
| Dynamic capture | A known filter callback captures a runtime threshold | An ordinary comparison against the exported threshold parameter, no closure object |
| Data DSL | Multiply by three, add seven, cap at 100 | Arithmetic plus the cap branch; no instruction list or dispatch |
| Runtime instruction | The same evaluator receives a runtime native sum | A tag switch remains |
| Activity DSL | Open a balance draft, credit/debit, commit only below a limit | A branch and a small account local; no draft object or callback call |

The distinction between erased *description overhead* and surviving *domain work*
is important: the cap branch must remain when the input is unknown. A DSL does not
make inherently dynamic work static.

## Interpretation

### 1. A vocabulary can be a semantic parameter

The formula is not tied to one implementation of its words. Its vocabulary gives
it meaning. We exercised native arithmetic and human-readable rendering; an AST
builder, dimension checker, or interval interpreter are plausible next experiments,
not verified results here.

This is deeper than syntax sugar: the same domain description can be consumed in
more than one way, without parsing a second source language. But rendering this
small arithmetic expression does not establish that arbitrary imperative programs
can be reinterpreted. Host `if` cannot simply stand for symbolic conditional syntax;
a symbolic vocabulary would need an explicit conditional combinator or data node.
The rendered expression also does not itself specify U32 wraparound semantics.

### 2. Higher-order structure need not become runtime machinery

The stream experiment separates a known topology from unknown elements and bounds.
The callback capturing `threshold` is particularly revealing: its *identity* is
known, but its captured value is not. SLC specializes the former while retaining
the latter. That is the useful distinction, not “callbacks must be all-static.”

The two pipeline orders preserve different meanings while both fuse. Abstraction
removal is not license to commute effects or reorder domain operations.

### 3. An interpreter is a candidate implementation of a compiler

The data DSL needs one evaluator. Given a known script it specializes into a small
native program; given an unknown instruction it dispatches at runtime. This makes
schemas, protocols, query plans, and state machines attractive targets.

The experiment proves this for a three-instruction arithmetic script, not arbitrary
interpreters, recursive grammars, or large programs. Code size and specialization
time still need measurement as description size grows.

### 4. A DSL can define a bounded activity, not just an expression

The balance words acquire their receiver from an opened context. The activity owns
setup and completion; the body supplies domain operations. This is a promising
shape for builders, transactions, encoders, and resource scopes.

The demonstrated reject operation discards only a private draft. It does **not**
roll back I/O, global writes, or arbitrary effects. U32 arithmetic wraps: this toy
balance vocabulary is not a financially safe account model, and the harness
explicitly exercises wraparound. A real domain DSL must encode its own invariants.

## A boundary we deliberately tested

[dsl_runtime_description_rejected.slc](dsl_runtime_description_rejected.slc) passes
a runtime factor to an untyped requirement. Compilation fails as expected:

```text
argument 'factor' of configure is a compile-time parameter (it has no type), but the value is not known at compile time
```

If factor is runtime data, annotate it with its native type. If the operation itself
is runtime-selected, represent that choice as data (as with Instruction), or choose
a suitable runtime function-value contract. Do not pretend a runtime choice is a
compile-time vocabulary.

## Evidence and reproduction

Observed: 8,248 runtime assertions passed at each of `-O0` and `-O2`, strict C99
warnings enabled. Coverage includes empty streams, counts 0–256, dynamic thresholds,
composition order, all three valid instruction variants, cap boundaries, commit and
reject, and selected U32 wraparound cases. Compile-time assertions also passed.
Both SLC files pass `fmt --check`. The deliberate rejection exits 1 with the
compile-time-parameter diagnostic above.

Run from the repository root (one directory above the session workspace):

```sh
export LUA_CPATH="$(luarocks --lua-version=5.1 path --lr-cpath);;"
export SLC_CACHE="$PWD/slc/build/cache"
export TMPDIR="$PWD/slc/build"
luajit slc.lua -o slc/build/dsl_depth.c slc/experiments/dsl_depth.slc
for opt in 0 2; do
    cc -std=c99 -Wall -Wextra -Werror -pedantic -O"$opt" -Iruntime \
        slc/experiments/dsl_depth_harness.c -o "slc/build/dsl-depth-O$opt"
    "slc/build/dsl-depth-O$opt"
done
luajit slc.lua fmt --check slc/experiments/dsl_depth.slc \
    slc/experiments/dsl_runtime_description_rejected.slc
# Expected failure, not part of the successful compilation above:
luajit slc.lua slc/experiments/dsl_runtime_description_rejected.slc
```

No JIT validation, performance benchmark, or full project regression suite was run.
No compiler or existing project sources were modified. Existing unrelated changes
were left intact. The initial jj inspection could not acquire its repository lock
because the repository metadata is outside the writable workspace.

## Where the next experiments should push

Follow-up: the [binary-format DSL and C comparison](binary/README.md) now implement
and benchmark the first direction below. The evidence above describes only this
initial set of arithmetic/stream/activity probes.

1. **Binary layout vocabulary:** one description drives encoder, decoder, size
   calculation, and a human-readable schema. Probe dependent lengths, malformed
   inputs, and borrowed buffer lifetimes. This tests multiple meanings and safety.
2. **Protocol vocabulary:** describe states and legal transitions, specialize a
   handler, and produce a transition graph from the same description. Test what
   invariants the vocabulary enforces rather than assuming specialization provides
   protocol correctness.
3. **Stream completion:** extend this push model with `take`, early termination,
   resource cleanup, and side effects. Count effects to verify their order. Fusion
   alone is the easy part; cancellation/completion contracts are the deeper test.
4. **Scale and diagnostics:** grow descriptions, measure generated code and compile
   time, deliberately collide opened vocabularies, and observe whether errors name
   domain concepts or expose implementation machinery.

The emerging design rule: choose the representation based on what the DSL must do.
Words and callbacks suit immediate composition; data descriptions suit inspection,
serialization, alternate interpretations, and runtime selection. SLC makes their
execution paths meet through specialization, but does not erase that design choice.
