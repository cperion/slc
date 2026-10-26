# Remaining helper architecture audit

## Scope and standard

Repository-wide inventory of compiler modules, SLC libraries, and all runtime C
translation units, with direct inspection of collection, text, slice, channel,
I/O, timer, scheduling and pool policy. This is **not** a claim that every line of
the specializer, backend or synchronization implementation has been audited.

Classification is by behavior, not by names such as `helper`, `runtime`, or
`primitive`. Code already being in a runtime does not justify keeping it there.
A native algorithm compiled from SLC is still runtime code; it can specialize
with its caller. A thin SLC wrapper around a C algorithm does not count.

## Remaining migration findings

| Implementation | Finding and disposition | Required capability / next boundary |
|---|---|---|
| [I/O vocabulary](../lib/io.slc) and [compiler I/O operations](../slc/stage.lua) (`io_vocabulary`, `io_wait`) | **Partly moved during audit.** Status-to-sum composition for waiting and immediate operations now lives in [completion words](../lib/completion.slc), followed by normal language matching. The vocabulary still obtains its operation adapters/defaults from `__S.io_vocabulary()`. | Keep one wait/completion primitive, task frame storage, writable-buffer borrowing and option/type validation. Move the remaining ordinary operation composition out of the compiler. |
| [Channel receive](../slc/stage.lua) (`chan_method.recv`) | **Split during audit.** `value`/`closed` construction now lives in [completion words](../lib/completion.slc); handlers use ordinary sum matching. Waiting and successful-path ownership adoption remain primitives. | Keep adoption inside the successful SLC branch. This does not exempt the separate C channel queue/ring policies below. |
| [Slice subviews](../slc/stage.lua) (`slice_sub`) | **Moved, with a projection primitive left.** The bounds, the comparison forms and the trap text are the `index`/`high`/`nonempty`/`range` words of [slice.slc](../lib/slice.slc), called after the compiler folds the cases it can decide; the IR no longer has `bound`/`range` operations and `slc_rt.h` no longer has `SLC_BOUND`/`SLC_RANGE`. Retaining owner identity, known byte contents, lifetime tokens and deferred addresses stays compiler machinery, and so does building the resulting view. | A general view-construction/projection primitive, if one is wanted; preserve known folding and lifetime diagnostics rather than making all views raw pointers. |
| [C printf formatting](../slc/stage.lua) (`cformat`, `FORMATS`) | **Move policy.** Literal rendering, percent escaping and format selection remain in compiler Lua. | The library may use host metaprogramming for variadic packs/type selection. Only ABI default promotions and foreign calls belong in compiler lowering. |
| [Floating conversion](../slc/strings.lua) and [formatting words](../lib/format.slc) | **Moved.** Precision search, special values, the `Chars(32)` buffer, the `snprintf`/`strtod` calls and the parsed check are ordinary SLC in [format.slc](../lib/format.slc); the compiler keeps only the fold of a value that is known while compiling ([`float_is_known`/`float_text`](../slc/strings.lua)). libc is an explicit external dependency, not an irreducible primitive. | A fully SLC decimal kernel is further work and would replace the libc trial, not the composition around it. |
| [Collection layout adapters](../slc/memory.lua), [map adapters](../slc/maps.lua) | **Moved.** Per-type generated `_at`, `_read`, `_write`, `_value_at`, `_id`, `_view` helpers and their textual declarations are gone. [Storage layout words](../lib/storage_layout.slc) read and write the fixed runtime records; the backends use `slc_store`, `slc_grow`, `slc_id`, `slc_map` and `slc_strmap` from `slc_rt.h` directly. | Ownership/checked-place integration stays compiler machinery (`Mem.view`, `checked_place`); no per-collection C helper and no gccjit C reader for it remains. |
| [Data stacks](../lib/stacks.slc) | **Moved.** Growth, alignment, push, reset, byte view/copy/zero and trap unwinding are SLC words over explicit stack state. | C keeps TLS stack-set selection (`slc_stacks_current`) and the const-pointer adapters `slc_gs_write`/`slc_stacks_unwind`. Record layout comes from `slc_rt.h`, so gccjit no longer needs a probed copy. |
| [Timer heap](../runtime/scheduler.slc) | **Moved.** Growth, insertion, sifting, replacement and cancellation bookkeeping are ordinary SLC words over explicit heap state. | C retains the scheduler lock, clock, claims and wakeups. SLC calls libc allocation directly; allocation failure retains the existing trap. |
| [Scheduling policy](../runtime/scheduler.slc) and [bookkeeping](../runtime/bookkeeping.slc) | **Moved.** Xorshift, run-queue selection, timer firing, idler/task/job lists and worker configuration are SLC. | C retains thread-local handoff, synchronized randomness acquisition, parking, task-step callbacks and atomic wake transitions. Deadlock diagnostics and some surrounding state bookkeeping still require review. |
| [Channel/pool protocol](../runtime/protocol.slc) and [lifecycle](../runtime/lifecycle.slc) | **Moved.** Waiters, buffered/rendezvous transfer, slot validation/ownership, free lists, generation rollover, registry chunk growth, metadata linkage, scope teardown and first-of scan/arm/withdraw/retry are SLC. | The same lock transactions, unlock-before-trap paths, memory orders, claim ordering and successful-path adoption remain. C provides synchronization envelopes for registry lifetime and scheduler wakeups. |
| [POSIX operations](../runtime/posix.slc) and [I/O construction/completion](../runtime/io.slc) | **Moved.** Socket setup, options, connect/accept/read/write/open/close composition, retry classification, failure cleanup and result assembly are ordinary SLC. | Syscalls, errno and blocking callback submission remain foreign boundaries. Two C const-pointer ABI adapters forward to SLC without implementing operation policy. |
| [Poll](../runtime/poll.slc), [kqueue](../runtime/kqueue.slc), [io_uring](../runtime/uring.slc) | **Moved event-loop policy.** Queue growth/compaction, direction queues, deadline selection, rearming, timeout handling, ring indexing, submission preparation and completion classification are SLC. | C starts native threads. io_uring additionally retains Linux setup/mmap and integer-address kernel ABI marshalling: SLC intentionally has no integer-pointer conversions. Backend-specific SLC is selected at build time; there is no handwritten policy fallback. |

## Behaviors already moved

- [Maps](../lib/map.slc): probing, insertion, displacement, deletion, growth,
  arena compaction, public operation composition, traversal and known lookup words.
- [Keys](../lib/key.slc) and [hashing](../lib/hash.slc): semantic encoding/equality
  and streaming SipHash. Id operator equality now delegates to the SLC key word.
- [Storage](../lib/storage.slc): Store free-list allocation, generation validation
  and retirement, removal, Grow push/index checking, Text append/relocation and clear.
- [Formatting](../lib/format.slc), [Chars](../lib/chars.slc),
  [text](../lib/str.slc), [durations](../lib/duration.slc), and
  [channel iteration](../lib/channel.slc): integer/Bool formatting, floating
  precision selection, capacity/copy loops, C-string scanning, text operations,
  unit arithmetic and traversal.

Displaced C algorithms in test reference headers are historical oracles, **not**
production implementations or fallback paths. Passing those oracles alone is not
acceptance evidence for the SLC implementation.

## Retained mechanisms and why

- Parsing, lexical/source macros, types, places, knownness, specialization,
  control-flow generalization and shared IR: compiler semantics. This does not
  excuse application algorithms hidden in macro expansions or generated helpers.
- Native instruction lowering and foreign ABI/layout probing: backend/interop
  mechanics. Feature algorithms must not be duplicated between C and libgccjit.
- Allocation, relocation-safe byte addressing/copy, OS entropy, trap recovery,
  scope cleanup, task capture and borrowing: storage/lifetime/platform mechanics.
  Feature-specific convenience wrappers around these remain removal candidates.
- Atomic instructions, lock/park/wakeup transitions, kernel submission and
  completion: concurrency/platform boundaries. Scheduling and collection policy
  surrounding them remains subject to migration.

## Execution order

1. Remove compiler-built I/O/receive result composition and printf policy.
   **Done as far as the standard requires**: status-to-sum composition and matching
   are SLC words ([completion.slc](../lib/completion.slc)); what stays in the
   compiler is the pack-returning format builder and the I/O argument packaging,
   accepted as primitives (see the last section).
2. Replace per-feature C layout helpers with general structured operations.
   **Done**: [storage_layout.slc](../lib/storage_layout.slc) reads and writes the
   fixed runtime records; the backends use the header's `slc_store`/`slc_grow`/
   `slc_slot_at` helpers directly, and per-type generated helpers are gone.
3. Runtime-SLC build integration and timer/run-queue/random policy are now
   implemented in [scheduler words](../runtime/scheduler.slc), retaining their
   synchronization envelope. [The shared builder](../slc/runtime_build.lua)
   generates policy C under the build/cache directory; native loading and C
   harnesses link it, with no handwritten policy fallback. Channel/pool waiter
   queues, transfers, free lists, registry growth, scope teardown, first-of,
   slot ownership and scheduler lists now use SLC as well. POSIX composition and
   all three backend event-loop policies are ordinary SLC modules.
4. Finish numeric-conversion and compiler-library composition migration; audit
   residual synchronization/diagnostic code and explicitly record remaining
   external algorithms instead of treating the runtime rewrite as whole-goal
   completion. **Done**: decimal conversion and its buffer composition are
   [format.slc](../lib/format.slc) words, checked slice access is
   [slice.slc](../lib/slice.slc), the compiler keeps only the compile-time fold;
   every remaining C function is inventoried below as a mechanism, with the
   external libc/kernel dependencies named.

## What still ties the gccjit backend to a C reader

[`slc/cjit.lua`](../slc/cjit.lua) keeps a C reader for `slc_rt.h` itself: the
fixed record layouts (which the backends use directly, with no second probed
copy), the `static inline` accessors the generated code calls, and the macros.
That is all it reads. Its template mode and its placeholder ("hole") handling
are gone: the prepared IR carries no C text.

A wait is `{ op = 'wait', callee, args }`, where `callee` names a function the
runtime header declares and the arguments include the `task`, `ops`, `block_fn`
and `block_env` IR nodes; the C backend prints `callee(args)` and the gccjit
backend calls the header's own declaration with converted arguments. Every other
runtime call is an `rtcall` node with the same properties: channel close, slot
give/adopt/release, scope/channel/pool creation and
`io.pipe`/`listen`/`local_port`. `first_of`'s case list is a `case_array` IR
node, a spawn is its own statement carrying its frame plan, and the data-stack
restore before an exit is a `gs_reset` node. Atomics, fences, size queries,
array views, the slot accessor, varargs promotions and the string casts are IR
operations as well.

Per-type helper generation is gone, so nothing in the backend reads generated
helper C any more.

## The C that remains, function by function

Every remaining C translation unit was read for this audit. Each entry below is
a mechanism, not a policy the SLC modules could own today:

| File | What it does | Why it is C |
|---|---|---|
| [slc_rt.c](../runtime/slc_rt.c) | thread-local data-stack sets, `slc_trap`/`slc_try` (setjmp), stack pinning, process entropy for map seeds | `__thread`, `setjmp`/`longjmp`, `getrandom` and `pthread_once` are the platform; bounds checks around them trap |
| [slc_tasks.c](../runtime/slc_tasks.c) | task records, spawn, worker and plain-thread parking, wake transitions under the scheduler lock, timer heap driver, deadlock report, trap recovery | mutex/condvar transitions and the lock envelope around wake-ups; heap ordering, queue selection and random choice are [SLC](../runtime/scheduler.slc) |
| [slc_io_posix.c](../runtime/slc_io_posix.c) | two callback adapters: hand a blocking job to `slc_run_blocking` | the operation policy and the `openat`/`read`/`write`/`close`/`accept`/`connect` composition are [posix.slc](../runtime/posix.slc) |
| [slc_io_poll.c](../runtime/slc_io_poll.c), [slc_io_uring.c](../runtime/slc_io_uring.c), [slc_io_kqueue.c](../runtime/slc_io_kqueue.c) | thread bootstrap, ring/kevent mapping and the kernel ABI | syscalls, `mmap`, integer address ABI; the poll loop, submission and operation policy are SLC |
| [slc_rt.h](../runtime/slc_rt.h) | record layouts, constants, prototypes, and `static inline` accessors (`slc_slot_at`, `slc_store`, `slc_grow`, ...) | the shared ABI both backends read; no policy algorithm lives there any more |
| build-time [policy C](../slc/runtime_build.lua) | compile of `runtime/*.slc` into the policy object | it *is* the SLC modules |

## What the compiler still composes, and why

Two library-composition items remain in compiler Lua after this pass. Both were
reviewed against the standard above and are **accepted as compiler primitives**
by decision (not migration debt):

- `cformat(...)`: it returns a **pack** — the format string plus the promoted
  arguments — so that `printf(cformat(...parts))` can pass them on. SLC packs are
  second-class: they cannot be returned, stored or passed whole (§20), so no
  ordinary word can build one. Format selection, literal rendering and percent
  escaping are host metaprogramming over a variadic pack, which the standard
  allows; the only lowering involved — the ABI default promotions — is the
  `vaconv` IR operation, in both backends. Converting this to a word would need a
  returnable pack or an explicit "spread these arguments into this call" form; that
  is a language extension, recorded here rather than taken unasked.
- the [I/O vocabulary](../slc/stage.lua) (`io.read`/`write`/`open`/...): the
  public shape is optional positionals plus an options table plus a trailing
  handler block, and the result sums and `done` projections are type-level. What
  the standard keeps in the compiler is exactly what remains: one wait primitive,
  buffer borrowing, frame storage, type/option validation and the diagnostics;
  status-to-sum composition and matching are already SLC
  ([completion.slc](../lib/completion.slc)) applied through ordinary `match`.
  Argument packaging is the small residue. Moving it needs the same pack/spread
  form, or an options-struct-only API, which is a public interface change; both
  are recorded as available work rather than done.

Use existing subsystem checks at these boundaries, not a new validation campaign
for each helper. Earlier migration checks are evidence for those revisions, not
proof that the current combined working tree passes integration.
