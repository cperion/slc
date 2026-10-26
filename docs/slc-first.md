# SLC-first implementation course correction

User direction: this applies across the project, not only to maps. Expressible
behavior belongs in ordinary SLC words so the specializer can see it with the
caller. Moving Lua code to another Lua module or replacing it with opaque C calls
is not a migration. Backend optimization is not a substitute for staging.

## Boundary

Keep language machinery in the compiler: syntax, native type construction,
known/dynamic values, places, effects, specialization, checked references,
shared IR, and backend lowering. Keep necessary mechanisms in the runtime:
allocation and stack relocation, entropy, traps, OS calls, scheduling and atomic
synchronization. Every retained operation needs an actual mechanism-level reason;
being already implemented in C is not one.

Move library policy and algorithms into SLC: traversal, lookup composition,
formatting, hashing/equality, table probing/deletion/rebuild, collection APIs,
and ordinary arithmetic/control-flow wrappers. When SLC cannot express one of
these, record the exact missing capability and implement the smallest general
primitive rather than a new feature-specific compiler subsystem.

This is an implementation migration, not permission to change language semantics,
ownership, ABI, error outcomes or the accepted map API.

## Initial inventory and dependency order

The [remaining-helper audit](helpers-audit.md) supersedes this initial inventory
with concrete move/split/keep findings, including scheduler policy and the I/O
vocabulary. It explicitly distinguishes reviewed policy from paths still needing
protocol-level review.

| Area | Direction |
|---|---|
| Channel iteration | First correction implemented: channel `each` is an SLC word using `recv`; compiler keeps wait and slot-adoption semantics. |
| Text | Search/compare/parse, C-string scanning, integer/Boolean formatting, Chars construction, append/clear and floating precision selection now use SLC. Decimal conversion still uses libc through a Lua bridge; that is an explicit remaining dependency, not a completed numerical-kernel migration. |
| Store/Grow | Allocation policy, free-list reuse, generation checking/retirement, removal, push and checked indexing now use [SLC storage words](../lib/storage.slc). Feature-specific generated layout/access helpers still need replacement by general structured operations. |
| Maps/StrMap | Hashing, semantic equality, probing, API composition, insertion/deletion, growth, arena compaction and traversal now live in [SLC libraries](../lib/map.slc). Production C algorithms are removed. Remaining hooks are layout/ownership, checked stack byte access/copy/relocation, entropy and traps. Historical C algorithms are test-only oracles; production SLC algorithms have independent model/alias checks. |
| Known maps | Implemented immutable, snapshotted host descriptions. Ordinary SLC lookup words fold known queries and residualize dynamic comparisons, with semantic duplicate checks and ordered specialization-time iteration. |
| Slices/arrays | Keep value/place and bounds-check primitives; inspect traversal/subview/convenience operations for library implementation. |
| Channels/tasks/pools | Retain task capture/isolation, suspension, ownership transfers and scheduler mechanisms. Move orchestration and traversal convenience into SLC. Audit runtime policy separately from synchronization machinery. |
| I/O/POSIX | Existing POSIX activities are the pattern. Keep OS/completion boundaries primitive; move expressible wrappers and outcome composition into SLC. |
| Atomics/durations/formatting | Duration unit arithmetic now lives in SLC; Lua only dispatches and casts to its native type. Keep atomic instructions and memory-order validation primitive. Audit remaining conversion and formatting policy. |
| Compiler/FFI/macros | Genuine compiler/host responsibilities remain Lua. Do not rewrite the specializer merely to change implementation language. |

## Execution

1. Move independent library behaviors now, starting outside maps as well as within
   them. Channel iteration is the first concrete migration.
2. Identify the minimal storage access/capacity/relocation interface needed by
   Store/Grow/maps. Reuse existing facilities; do not expose unsafe map internals
   as a user-facing workaround.
3. Migrate the collection and text algorithms, deleting the displaced implementation
   once its SLC replacement passes focused behavioral and staging checks.
4. Complete known-map descriptions on the same basis.
5. Finish the inventory of other subsystems and migrate remaining expressible
   behavior. Document precise reasons for retained primitives.

Use focused examples and one or two relevant backend checks per change. Run broad
acceptance at coherent milestones, not repeatedly after every edit. Preserve
unrelated tree-sitter/editor work. The feature migration is not yet complete.
