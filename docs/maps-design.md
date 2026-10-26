# Maps: approved design and implementation contract

The approved model is implemented with ordinary SLC algorithms. The authoritative
language contract is now [§40 of the specification](staged-lua-c-v0.5.md#40-maps-and-known-lookup-descriptions).
This document records the design rationale against the existing Goose model.

## 1. Two mutable storage types

- `Map(K, V)` owns fixed-size key/value entries on one data stack.
- `StrMap(V)` owns entries and copied key bytes on two data stacks.
- Both are created in place with `{}`, passed by `Ref`, never copied or returned
  by value, and released at the end of their owning scope.
- Either can be the last (and sole resizable) field of a struct. Such a struct
  is not a fixed-size map value or Store payload. Maps of maps are not admitted.
- Neither map nor its references cross tasks. A task can own a map and service
  requests; fixed-size results cross channels under the existing rules.

`Map` keys: integers (including Duration), Bool, Id, Chars(n), and structs or
sums recursively made from these. No floating keys, pointers, CString, Str,
references, channels, atomics, or general Array keys in this first contract.
Chars is explicitly supported despite its internal array representation.

Values: ordinary fixed-size data: numeric scalars, Bool, Id, Chars, arrays,
structs and sums recursively composed of these. No borrowed views, raw pointers,
channels, atomics, or resizable fields. Unit remains a sum alternative payload,
not a standalone map value. These restrictions must be checked recursively,
not inferred just from the outer type's size.

## 2. Surface operations

```lua
local Counts = Map(Chars(32), U32)
local counts: Counts = Counts {}
counts:ensure(Chars(32)("word"), 0)
counts[Chars(32)("word")] = counts[Chars(32)("word")] + 1

local words: StrMap(U32) = StrMap(U32) {}
words:put("arbitrary-length key", 1)
```

This uses existing constructor and activity syntax; no new grammar is proposed.

- `m[k]`: checked place for an existing value; a missing key traps (`map-key`).
  Assigning to it does not insert. Fields of aggregate values are places too.
- `m:find(k)`: `oneof { found: V, missing: Unit }`; found is a value snapshot.
- `m:has(k)`: Bool.
- `m:put(k, v)`: insert or replace, Unit result.
- `m:ensure(k, initial)`: insert only if absent, Unit result. Arguments evaluate
  normally and eagerly, even when the key exists. This is not a lazy factory.
- `m:remove(k)`: Bool; absent returns false.
- `m.length`: U32 live entry count.
- `m:each(do(k, v) ... end)`: unspecified iteration order. Fixed keys and values
  are snapshots. StrMap keys are read-only Str views valid only in the callback.

During iteration, replacing an existing value is allowed, including through
`m[k]`. Insertion of a new key and removal of an existing key trap before changing
storage. No-op ensure/remove are allowed. Replacements affect a later visit;
they do not change a value already passed to a callback. Nested read iteration
is allowed. An active-iteration counter enforces this through aliases and calls.
All exits must balance it, including nonlocal returns and recovered traps.

## 3. Key identity and checked places

Equality is semantic, not memcmp of object representation:

- integers and Bool compare their typed values;
- Id compares token, slot and generation without dereferencing it;
- Chars compares length and exactly that many bytes, ignoring unused capacity;
- structs compare declared fields; sums compare tag and active payload only.

Hashing follows exactly the same rules; padding and inactive bytes never enter
it. Embedded NUL bytes are ordinary key bytes. StrMap accepts Str and existing
text-to-Str coercions, and copies bytes only on insertion of a new key. Replacing
an equal key does not retain a redundant copy.

A checked place re-resolves its key after structural mutation, separately
compiled/foreign calls, loop boundaries and joins, using the existing checked
place mechanism. There is no durable entry pointer and no entry Id.
A fixed key is captured by value when forming a place. A StrMap key is a borrowed
view (pointer and captured length), not an implicit owning allocation: a fresh
lookup observes the current bytes of that view. Its owner must remain alive;
modifying the key owner ends cached lookup validity. Implementation must treat
such view-key lookups conservatively when it cannot prove byte stability.
Removing and reinserting an equal key makes the place address the new entry;
this is key identity, deliberately not Store's generational identity.

## 4. Binding time: known descriptions versus mutable storage

Mutable Map and StrMap operations are runtime effects, like Store/Grow/Text.
Known arguments alone do not turn mutable storage into a compile-time heap.

Known lookup descriptions are immutable host objects with a distinct API:

```lua
local keyword = StrMap.known(Token, {
    { "if", Token.if_() },
    { "while", Token.while_() },
    { "end", Token.end_() },
})
local numbers = Map.known(U32, U32, { { 1, 10 }, { 2, 20 } })
```

Explicit types and entry lists avoid Lua-table key identity and numeric precision
ambiguities, represent empty maps, and allow precise duplicate-key diagnostics.
All keys and values must be known. Duplicate semantic keys are rejected, rather
than choosing a winner by Lua iteration order. Input contents are snapshotted.

Known descriptions expose `find`, `has`, `length`, and checked value indexing,
not mutable places or mutators. A known key folds; missing checked indexing
fails during specialization. A dynamic key produces comparisons/branches and
exactly the same sum or runtime trap as mutable lookup. Text dispatch uses
length then bytes; fixed-key dispatch uses typed equality. Perfect hashing is
an optional later optimization, not an alpha semantic requirement. Known
`each` invokes the activity while specializing, in entry-list order.
These descriptions specialize code; they have no native map header or task ABI.

## 5. Runtime and compiler integration

**Revised by the user's project-wide SLC-first direction:** implement the table
algorithm, probing, key equality/hash, iteration and API composition in ordinary
SLC words. Both backends consume their shared prepared IR. Robin Hood probing,
backward-shift deletion and growth at 7/8 load remain the intended behavior.
Lua supplies type construction and minimal general compiler hooks; C supplies
only necessary storage/platform mechanisms. The former production C/generated-C
algorithms are removed. Historical C implementations remain only as test oracles;
model checks exercise the actual SLC table/arena algorithms separately.

A per-process random seed keys hashing. A known key may precompute semantic
encoding/mixes but its final runtime hash must incorporate that seed. Do not
claim hash-flood resistance from a noncryptographic keyed mixer. The first
implementation uses a specified keyed hash with reviewed test vectors (proposed:
SipHash-2-4 for all key encodings), without a hash-policy option. This replaces
the roadmap's underspecified default plus optional SipHash split. Random-source
failure is reported, not silently replaced with a fixed predictable seed.

StrMap entries retain byte offsets, not pointers into their movable arena.
Removal marks key bytes reclaimable. Arena compaction/rebuild is triggered by
a bounded dead-byte threshold before further growth, so insert/remove churn
cannot accumulate unbounded historical key storage. Rebuilding updates offsets;
all temporary pointers must be reacquired after data-stack growth. Capacity,
byte-size and alignment arithmetic is checked before allocation or mutation.

Storage allocation/release hooks must support two owned stacks for StrMap,
including struct fields, branches, loops, calls, returns and trap recovery.
This is a focused extension of Goose ownership accounting, not another allocator.

## 6. Delivery slices and acceptance

1. Map(K,V): recursive type rules, semantic hashing/equality, runtime storage,
   checked places, operations and iteration, plus a word-count-style example.
2. StrMap(V): two-stack ownership, copied keys, arena reclamation and view rules.
3. Known descriptions: folding, dynamic lookup specialization and snapshots.
4. Specification/guide integration and complete focused backend validation.

Each slice gets C O0/O2 and JIT tests. Cover collisions, growth, removal chains,
replacement, missing-key traps, structural changes during iteration through
aliases, scope exit, and recovered traps. Test padding-independent equality,
Chars spare capacity, signed/extreme integers, sums, Id keys, embedded NUL,
mutable source keys, copied StrMap keys, arena churn, known/dynamic/split lookup,
and rejected borrowed/resizable payloads. Sanitizers check runtime memory paths.
Run existing project suites before declaring the feature complete. General
fuzzer hardening, distribution, unrelated parser fixes and alpha qualification
remain outside this feature change.
