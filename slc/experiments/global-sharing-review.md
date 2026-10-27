# Review: task access to native globals

Status: design review, not a new language contract. The proposed global checker
has **not** been added to the working compiler.

## Current contract and proposed change

[The globals contract](<../../docs/syntax.md#L3190-L3224>) exposes static C storage
as `Ptr T`. [The task sendability contract](<../../docs/syntax.md#L2892-L2899>)
rejects pointers and other borrowed state copied into tasks. These are different
boundaries: a task can reach static storage without receiving its address as a
spawn capture.

The downloaded patch proposes rejecting task writes to globals unless they are
thread-local, Atomic, or declared `shared = true`. It permits reads. Its checker
walks residual stores, recognizes a directly embedded global address, and follows
direct materialized calls. It does not propagate pointer provenance through
function arguments or inspect the targets of indirect calls.

## Fresh evidence

Only the patch's compiler changes were applied to an isolated source copy under
ignored build output. The working compiler and existing Map changes were not
replaced. Three probes were compiled, not executed:

| Probe | Observed result with proposed checker |
|---|---|
| Task directly updates `hits[0]` | Rejected with the intended global-write diagnostic |
| Task calls `bump(hits, n)` through an explicit function boundary; `bump` writes `p[0]` | Accepted |
| Task calls a function pointer loaded from a global; its target updates `hits[0]` | Accepted |

The pointer-parameter probe emitted both of these operations:

```c
static void bump(uint32_t *p, uint32_t n) {
    p[0u] = p[0u] + n;
}
/* Inside the task step: */
bump(&hits, f->n);
```

This is not dead code or a hypothetical alias: the task's residual program
actually writes the global through the parameter. The indirect-call probe likewise
retains the target's global write and the task's indirect call.

Local evidence: [direct probe](<../build/patch-review/global-direct.slc>),
[rejection diagnostic](<../build/patch-review/global-direct.log>),
[pointer probe](<../build/patch-review/global-pointer-call.slc>),
[its generated C](<../build/patch-review/global-pointer-call.c>),
[indirect probe](<../build/patch-review/global-indirect-call.slc>), and
[its generated C](<../build/patch-review/global-indirect-call.c>). These artifacts
are deliberately ignored; the table and code above preserve the substantive result.

## Decisions before implementation

1. **Guarantee or lint?** A direct-store diagnostic is useful as a lint, but cannot
   be advertised as transitive task isolation. Decide whether native globals and
   foreign calls remain an explicitly unsafe boundary or fall within an enforced
   task-access contract.
2. **Reads count too.** Permitting all reads while constraining only task writers
   does not prevent a race with a native thread or foreign writer. Immutable,
   safely published data is different from mutable shared storage.
3. **Thread-local is not task-local.** TLS is per operating-system thread. The
   [scheduler](<../../docs/architecture.md#L706-L712>) does not establish a private
   TLS object per task; multiple tasks can use one worker's storage.
4. **Atomic and locked access need precise boundaries.** A `shared` boolean is a
   programmer promise, not proof that accesses hold a lock. An Atomic exemption
   must concern atomic operations, not give blanket permission to access the
   object's representation non-atomically. These are policy requirements, not
   additional experimentally demonstrated bypasses in this review.
5. **Effects must survive composition.** An enforced rule needs reads/writes
   through pointer parameters, aliases, direct recursion, function values, and
   foreign calls accounted for. The current memory/effect machinery should be
   inspected and extended where appropriate, rather than adding a second,
   global-only syntactic walker. Unknown effects need an explicit contract, not
   a silent exemption.
6. **Runtime code is still SLC.** The [backend policy](<../../runtime/backend.slc>)
   already synchronizes shared global state through pointers and POSIX calls.
   Any trusted/unsafe boundary must be explicit and usable by ordinary SLC code;
   moving its algorithms into C or special-casing runtime names is not a solution.

Recommendation: retain the existing Map validation, take the independent fortified
wake-pipe warning fix, and settle the task-access/effect boundary before introducing
`shared = true` or claiming enforcement. No new global-sharing semantics are
implemented by this change.
