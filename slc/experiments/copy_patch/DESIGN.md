# Direct backend: register-bank VM

Status: proposed specification. Supersedes the slot-first draft.
Target first: Linux x86-64, Clang, SysV C ABI.

## 1. One pipeline

```text
shared prepared IR → symbolic VM → select stencils → copy → patch → native code
```

Lua constructs the code. No runtime bytecode, opcode dispatch, or Lua execution
exists inside the generated program. Existing SLC semantics, checks, Goose
storage rules, and task lifetimes remain unchanged.

## 2. One internal ABI

Every handler uses the same `preserve_none` signature and ends in a `musttail`
transfer, except a terminal handler returning to its entry bridge.

Conceptual C signature; BANK is expanded to ordinary named C parameters:

```c
#define VM_ABI __attribute__((preserve_none))
typedef void VM_ABI Handler(Context *ctx, BANK);
extern Handler NEXT;

void VM_ABI add(Context *ctx, BANK) {
    /* typed operation on designated bank lanes */
    __attribute__((musttail)) return NEXT(ctx, BANK_VALUES);
}
```

**The parameters are the VM register bank.** Their parameter positions, types,
and calling convention determine their physical locations. The direct backend
has no physical-register allocator and generates no register permutations.
Unchanged lanes are forwarded; modified lanes contain the operation's results.

`Context *` occupies one parameter position. Context holds invocation bookkeeping,
addressable local storage, overflow storage, and return storage. Ordinary temporary
values stay in bank parameters, not automatically in Context.

The bank declaration is generated once for the target, not chosen per program.
Its exact integer/floating lane counts and physical mapping must come from a
compiled ABI probe. Select a signature whose bank parameters are all register
passed; reject a toolchain that ignores the attribute or violates this contract.
Do not assume that `preserve_none` makes every register available or prevents
compiler-generated temporary spills inside a handler.

## 3. One symbolic operand convention

Use a fixed top-of-stack bank convention, separately for integer/pointer and
floating lanes. Each operation declares the lanes it consumes and produces.
Lane 0 is the newest operand. For left-to-right evaluation of `a op b`, lane 1
contains `a` and lane 0 contains `b`; the handler computes `lane1 op lane0`, leaves
its result at lane 0, and shifts older values down by one lane. This operand order
also applies to subtraction, division, shifts, and comparisons.

Lua tracks typed stack positions while building code. Handler variants implement
these fixed transitions; there is no runtime stack-depth counter or lane map.
Explicit load/store handlers transfer values between the bank and fixed local or
overflow offsets. Address-taken locals have stable memory homes.

At a branch join, incoming paths must agree on the bank's typed stack shape and
on overflow locations. Loop backedges obey the same rule. Edge transfer handlers
reconcile values where necessary without changing evaluation order or snapshots.

## 4. One meta-stencil rule

A meta-stencil generates a family of C-compiled handlers offline.

| Select before compiling the stencil pack | Patch when building a program |
|---|---|
| operation and native type | exact constants |
| fixed bank stack effect | local/overflow/field offsets |
| operand form: bank, immediate, memory | successor addresses |
| comparison result or branch | callee and global symbols |
| legal atomic memory order | source-site references |

Start with arithmetic, comparison/branch, conversion, load/store/address,
constant, transfer, call, and return families. Labels emit no code.
Type widths, rounding, signedness, and atomic semantics remain those of SLC.

A small fused recipe such as compare-and-branch is compiled as one body.
Do not generate arbitrary instruction sequences or a cross-product of physical
register choices. Ordinary unfused handlers remain sufficient for correctness.
All holes have declared widths, relocation rules, and checked ranges.

## 5. Two explicit C bridges

### VM to C

A call-site plan is constructed from the callee's native signature while building
the program; it is not discovered by the running handler.

1. Save the VM bank and context needed after the call into invocation-owned storage.
2. Marshal arguments into SysV integer registers, SIMD registers, and stack slots.
3. Call the target using the ordinary C ABI.
4. Collect its scalar or aggregate result into declared VM result storage/lanes.
5. Restore the surviving VM state, excluding lanes replaced by the result.
6. `musttail` the continuation using the uniform VM signature.

The first implementation saves all bank lanes at this boundary; it needs no
liveness analysis. C may call back into SLC: saved state must be invocation-local,
not a global scratch buffer. Stack alignment, hidden aggregate returns, and
variadic promotions belong to the marshaling contract.

### C to VM

1. Preserve every register required by the SysV caller contract before entering
   `preserve_none` code.
2. Establish an invocation context and marshal native arguments into VM inputs.
3. Call the first handler; the stencil chain eventually returns to this bridge.
4. Marshal the VM result into the native return convention.
5. Release invocation storage, restore the caller's preserved state, and return.

Exports, native callbacks, and escaped function pointers name this bridge, never
a raw handler. Arguments beyond bank capacity use explicit argument storage.
The terminal handler writes return storage; the common handler return type is
`void`, independent of the exported SLC result type.

C glue owns context setup/teardown and marshaling buffers. Target bridge code owns
native register placement and saving/restoring machine state. These are ABI
mechanisms, not another interpreter. They are compiled ahead of time and patched
from call-site plans; no runtime C compiler is part of this design.

## 6. Calls, traps, and suspension

A stencil continuation is a jump. A real residual function call is not: it saves
the caller bank, establishes a distinct callee context, calls the callee chain,
collects its result, restores the caller bank, and continues. It uses the VM ABI
without a SysV argument-marshaling round trip. Tail-recursive loops already present
in prepared IR remain backedges, not new invocations.

Invocation frames are native-stack storage, not an implicit heap for SLC values.
The entry/call glue must unwind correctly through the existing trap boundary;
cleanup cannot depend solely on reaching a normal return. Goose resets remain
those prescribed by the shared prepared program and runtime.

Before task suspension, save bank values that must survive into the task's owned
persistent frame. Resume restores them before jumping to the continuation.
Never retain a pointer to a transient invocation context across suspension.
Task step entry/return uses the runtime's native ABI and status contract.

## 7. Construction and ownership

The stencil pack fixes target, compiler flags, VM bank signature, and runtime ABI.
It contains code, relocation records, and hole contracts. Keep the compiler's
internal branches and associated data relocatable with their handler.

Lay out code and data, validate targets and ranges, copy into writable memory,
patch, then make code executable before publishing entries. No RWX mappings.
External calls must support addresses outside the module's relative-branch range.
Retain code and referenced libraries while any entry, callback, or task can use them.

Runtime artifacts and foreign-layout facts must already be available. Missing
artifacts are explicit diagnostics, not hidden C/libgccjit compilation fallbacks.

## 8. Evidence and next proof

The [existing experiment](<README.md>) proves C handlers joined by tail transfers,
constant/branch patching, and native execution. It **does not yet test
`preserve_none`, the full register bank, or C marshaling**.

The next experiment must test these together:

- Probe and record the common handler ABI and register-passed bank capacity.
- Carry distinct sentinels in every lane through arithmetic and long loops.
- Call native C with more arguments than its register capacity, then verify all
  surviving VM lanes and context.
- Enter from C and verify its callee-saved registers survive the VM chain.
- Exercise a nested C → VM → C → VM callback and both scalar and aggregate results.
- Check trap recovery and task-style save/restore without dangling context pointers.

Only after these pass do we lower real SLC IR into that established VM ABI.
No backend implementation or performance result is claimed by this specification.

## 9. Detailed VM state contract

The simple architecture above is not a substitute for the following obligations.

### Bank shape and representation

The pack defines `NI` integer/pointer lanes and `NF` floating-carrier lanes, plus
one context parameter. Every handler declaration, function-pointer type, entry
helper, and continuation uses that exact signature and calling-convention attribute.
A different signature is a different pack ABI, never a local optimization.

Integer carriers are 64-bit words on this target. A typed operation uses its
actual native width and signedness; it does not perform every operation as U64.
Narrow results have a documented canonical extension in the carrier: zero-extend
unsigned integers and Bool, sign-extend signed integers. Bool is 0 or 1. Pointers
are transported as target address bits without introducing source-level integer/
pointer conversions. These representation operations are backend glue.

Floating carriers must preserve the exact bits of F32 and F64 between operations.
The candidate transport is a fixed 128-bit SIMD C parameter type with the scalar
bits in its low portion and other bits initialized. This is transport only, not a
new SLC vector type. Each handler extracts the declared scalar, computes at the
correct precision, and repacks it. The ABI probe must validate this candidate
alongside the integer bank; if the toolchain does not pass it in SIMD registers,
the bank declaration must be revised explicitly before it is frozen.

Never use uninitialized C arguments for unused lanes. Pass initialized canonical
values, so forwarding a lane cannot introduce undefined behavior. No `restrict`
promise is allowed on context, operand, or output pointers unless their actual
aliasing contract establishes it.

### Stack effects and overflow

Each selected handler has a construction-time contract:

```text
input typed stack → output typed stack
memory read/write effects
control successors
holes and their domains
```

Lua maintains the logical mixed-type stack and its projection onto the two banks.
A conversion pops from its source class and pushes into its destination class.
Cross-class comparisons/conversions cannot silently reorder evaluation effects.

When a push exceeds a bank's capacity, store that bank's oldest resident value to
its assigned overflow slot before shifting the remaining lanes. When a pop exposes
an older value held in overflow, refill the vacated oldest lane. Lua chooses the
slot offset and the push/pop-with-overflow variant from the known stack shape.
No running handler searches a stack map or decides where a value belongs.

This can generate register moves; those are prescribed VM stack transitions,
not physical-register allocation. Measure their cost. Fused recipes may eliminate
intermediate transitions while preserving the same declared input/output shape.

### Local places and expression values

Addressable locals have stable homes, with size/alignment and lexical lifetime
from their native types. A value read from a place is a snapshot, not an alias
that follows later assignments. A `Ref` or address explicitly denotes the place.
Aggregate values use stable or temporary byte storage with descriptors in Lua;
the native bytes retain their declared layout and are not boxed or runtime-tagged.

Fixed locals, overflow, bank-save areas, call images, and argument/result areas
are planned separately. Do not reuse a location while an address to it may remain
live. Checked places must preserve their existing re-resolution behavior; no bank
cache may retain a store/map/pool address past its invalidation boundary.

A statement with no expression result leaves the logical operand stack empty.
Any expression carried across a branch gets an explicit agreed destination or
matching bank shape on both paths. A prepared loop's carried places are stable
homes; its edge transfers must preserve simultaneous-update semantics.

## 10. C glue: concrete division of responsibility

The glue consists of four mechanisms, not a second compiler:

1. **Invocation helper:** create aligned invocation storage and enter a handler
   using the common VM function-pointer type.
2. **Native outbound gate:** load one prepared SysV call image, perform the call,
   and capture the return registers.
3. **Native inbound gate:** capture native arguments, invoke the prepared entry
   adapter, and return its native result.
4. **Publication helper:** executable-memory protection and cache synchronization.

Ordinary C owns buffers and invocation lifetimes. A small target-specific gate
owns the machine-register instructions that ordinary portable C cannot express.
The gate has no knowledge of SLC operators, types, ownership, or library algorithms.
The pack compiler sees the `preserve_none` type at every C-to-VM call site, so it
must preserve the native caller's state around that call.

### Outbound call image

The fixed image has the following conceptual fields. Concrete C declarations
and gate offsets are generated from one layout definition and checked together:

```text
NativeCallImage:
    target: address
    gpr[6]: U64                    # RDI, RSI, RDX, RCX, R8, R9
    xmm[8]: 16-byte bit containers # XMM0 through XMM7
    stack_bytes: address          # already laid out, including ABI padding
    stack_size: size
    vector_argument_count: U8     # SysV AL for variadic calls
    return_gpr[2]: U64            # RAX, RDX
    return_xmm[2]: 16-byte containers
```

A result returned through memory uses an explicit result buffer; its address
occupies the hidden native argument position. It is not an extra imaginary
return register. Images and VM-bank snapshots belong to this invocation.

The outgoing adapter is straight-line selected/patchable transfer code. It fills
the image from bank values and memory arguments according to a construction-time
ABI plan. It performs no runtime classification or opcode interpretation.

The gate performs these steps in order:

1. Preserve its own native callee-saved state and retain the image pointer in
   storage that survives the target call.
2. Reserve the planned outgoing stack area with the required alignment. Immediately
   before `call`, RSP satisfies SysV alignment. The callee's first stack argument
   is above the pushed return address, with padding supplied by the ABI plan.
3. Copy the prelaid stack bytes; load XMM and GPR argument registers; set AL after
   any use of RAX as scratch. Do not overwrite an argument while loading another.
4. Invoke the exact target address, using an indirect call when necessary.
5. Capture RAX/RDX and XMM0/XMM1 before using them as scratch or calling any helper.
6. Restore the gate's stack and callee-saved state and return to the call handler.

The call handler restores the saved VM bank, installs the declared result, and
musttails its successor. Saving the full bank is the baseline contract: neither
the ordinary C callee's preservation rules nor `preserve_none` can be assumed to
preserve a surviving VM value for us.

### ABI classification, not register allocation

The construction-time planner follows x86-64 SysV classification for supported
native types. Integers/pointers use INTEGER classes, floats use SSE classes, and
aggregate eightbytes are recursively classified and merged. MEMORY-class values
use stack arguments or hidden-result storage. If an aggregate cannot fit its
required register classes, roll back tentative register consumption for that
whole argument and place it according to the ABI. Preserve required padding and
stack alignment; do not split an argument arbitrarily between registers and stack.

Variadic operands undergo the existing default promotions before classification.
The planner sets the vector-register argument count and records the exact native
return convention. It never classifies an opaque record using only its byte size.
Unsupported native types such as an unimplemented x87/vector ABI class are rejected
explicitly, not treated as U64 or silently passed to a different backend.

The planner produces fixed transfers into/out of the image, not a function-sized
C source file. Consequently the number of native signature combinations does not
multiply the number of compiled gates.

### Inbound capture and entry adapters

Each exported function or callback has a tiny entry stub with its immutable entry
descriptor address. On this target the stub may load that descriptor into R10,
a SysV scratch register that is not an ordinary C argument register, then jump
to the common inbound gate. The stub must not overwrite AL, native argument GPRs,
SIMD arguments, the native return address, or the caller's stack arguments.

The inbound gate captures all six argument GPRs, eight SIMD argument registers,
AL, and the original stack-argument base before calling a C helper. It preserves
the native callee-saved GPRs RBP, RBX, and R12–R15 wherever its own code changes them.
The entry descriptor names an already-built straight-line input adapter, VM body,
invocation layout, and output adapter; it is immutable and not a global current-call
variable.

The C invocation helper establishes the context, invokes the input adapter, and
calls the VM body with the bank arguments. After terminal return, the output
adapter produces the native return image. The gate installs result registers,
restores native preserved state and RSP, and returns. For an indirect aggregate
result, honor both the caller's destination and the required native pointer return.

The C compiler must know that the VM body preserves none; declaring its pointer
as an ordinary C function pointer and casting at the call is forbidden. Full
machine-state sentinel tests check this contract, rather than assuming that a
successful scalar result proves native register preservation.

### Invocation storage and nested calls

Invocation storage is an aligned native-stack allocation whose size is fixed by
the prepared function, although supplied to the precompiled helper at execution.
The helper checks size/alignment arithmetic before allocation and is compiled with
the target's stack-probing requirements. It does not promise recovery from native
stack exhaustion beyond the existing native backend contract.

A context contains pointers to that invocation's stable local area, overflow area,
result destination, and boundary scratch areas, plus required runtime context.
A task entry instead points persistent values into the task-owned frame. It must
not relocate those values into a short-lived C helper frame.

A residual VM call saves the caller bank in its own call area, prepares callee
arguments, invokes a helper with a fresh callee context, and collects the result.
The helper calls through the VM type; no outgoing SysV argument image is needed
for the SLC parameters. Its own C implementation may use the platform ABI as an
implementation detail, but there is no source-argument marshaling through C.

A native callback establishes a separate invocation even if it re-enters the same
compiled function. Neither its saved bank nor its native return image aliases the
outer call's buffers. Cross-thread callbacks similarly share immutable code only.

## 11. Precise exits: return, trap, and wait

A normal return stores the declared result and returns to the invocation helper;
the helper releases its stack storage by returning. Continuation handlers must not
retain pointers to their own C locals when they musttail another handler.

A recoverable trap follows the existing [runtime trap path](<../../../runtime/slc_rt.c#L19-L47>):
managed-stack/guard cleanup occurs before longjmp while invocation storage is
still alive. The longjmp restores the native stack; an epilogue in skipped glue
must not be required to release heap allocations, restore a TLS current-context
pointer, or unpin executable code. Use no such per-call glue resources.

The direct backend must not broaden recovery: traps in tasks or while a task
scope is open retain the current runtime's abort behavior. Calls from arbitrary
foreign code retain the existing responsibility for whether a trap boundary is
installed; C++ exception unwinding through copied code is not promised.

Task yield/wait is different from a trap. Save continuation-live bank values and
resume identity in the persistent frame before returning the existing runtime
status. A later step entry reconstructs its transient context and restores the
bank. A saved Context pointer must never refer to the previous native stack.
Keep the scheduler's budget checks and operation-record lifetimes unchanged.
Blocking callbacks use native entry bridges over the same persistent task frame.

## 12. Prepared-IR coverage ledger

Use shared [preparation](<../../cgen.lua#L1648-L1679>) once. Direct lowering keeps
its location maps separate rather than annotating or rewriting the shared IR.

The 31 [expression tags](<../../jitgen.lua#L295-L462>) map as follows:

| Tags | Direct lowering |
|---|---|
| const, null, zero | immediate/literal-pool, zero, or aggregate-zero recipe |
| param, read | entry binding or snapshot load into a bank lane |
| addr, field, array_index | address/field/index calculation and projection |
| bin, un | typed arithmetic family with fixed stack effect |
| cmp | Bool result or compare-and-branch |
| and, or | short-circuit control flow, never eager evaluation |
| conv, vaconv | native conversion/default-promotion family |
| array, agg, sum | correctly laid-out aggregate construction and field stores |
| cconst, sizeof, tagname | authoritative platform/type metadata constants |
| stack_index | prepared Goose base plus its declared offset |
| gaddr | global address or thread-dependent TLS access, as appropriate |
| fnaddr | public native entry bridge when the value has native Fn semantics |
| call, calli, rtcall | internal call protocol or native bridge according to target |
| atomic | typed atomic operation, never a normal load/store substitution |
| slot_at | existing checked runtime operation, preserving ownership validation |
| task, ops | current runtime party and operation-record addresses |

The 17 [statement tags](<../../jitgen.lua#L512-L599>) map as follows:

| Tags | Direct lowering |
|---|---|
| store, let, setparam | evaluate, preserve snapshots, transfer to the declared place |
| expr | evaluate effects and discard the resulting operand |
| ret | terminal result/status recipe |
| if | typed condition and two explicit successors |
| for, loop | labels, body, correct limit test, and backedge |
| break, goto | direct edge to the established destination |
| label, nop | destination binding or no emitted code |
| wait | operation call, pending test, save/resume or plain blocking |
| spawn | allocate frame, copy captures, then publish/start the task |
| fence | native atomic fence with its specified order |
| trap | existing runtime trap entry with retained source information |
| gs_reset | prepared Goose reset, never omitted on a surviving exit |

`block_fn` and `block_env` are additional blocking-call operands, not ordinary
expressions. They become a native callback bridge and its persistent environment.
Module globals, layout, exported entries, and literal storage are required beyond
these dispatch tags. The inventory is not a claim that every stencil is implemented.

## 13. Layout, semantic, and patching rules

Native layouts remain those of the existing language and target ABI. Array stride,
sum tag/payload offsets, foreign nested members, and resizable-header layouts must
come from authoritative descriptions, not a second approximate struct model.

Keep all of the following explicit in generated families and acceptance tests:

- Small integer operation widths and narrowing, signed versus unsigned shifts,
  division/remainder semantics, and exact conversion rules.
- F32 rounding after each operation; no fused multiply-add unless the language
  operation itself permits it. Floating comparisons retain NaN behavior.
- Source-ordered effects and snapshot reads, including writes through aliases.
- Typed loops terminate at inclusive bounds without stepping past the type limit.
- Atomic memory orders and compare-exchange failure order, including effects on
  expected-value storage. Do not move atomics across stencil boundaries.
- Bounds/ownership checks already represented in IR remain observable. A checked
  reference must re-resolve after the same mutation/call/control boundaries.

A hole record specifies section, byte offset, width, signedness, relocation kind,
addend, symbol category, and permissible value range. Use exact-width integers for
U64 constants and actual addresses; Lua doubles are not an address representation.
Pointer/constant placeholders must not let the offline optimizer assume a property
that a legal patched value violates. In particular, zero offsets and constants,
maximum immediates, and signed displacements need explicit tests.

Internal relative branches use module labels. External symbols use a supported
far-target form when needed. Code and literal pools are laid out together with
alignment recorded. Validate relative patches before allocation where possible,
and actual-address patches after allocation but before publication. A removed
terminal jump is valid only when the successor exists immediately after it and
all remaining relocations retain their intended targets.

No patched program is callable until all its references are resolved and memory
protections are final. Keep unpublished mappings reclaimable on error. Initially
retain published code for process lifetime, as the existing native loader does;
raw function pointers and running tasks must not outlive their code or libraries.

Foreign constants, TLS accessors, and runtime libraries require prebuilt artifacts
for the strict direct path. The current header probe/runtime loader can invoke a
compiler on cache misses; do not reuse that behavior silently. A missing fact is
an explicit preparation requirement, not an invented layout or fallback backend.

## 14. Detailed acceptance and reporting

The following are acceptance obligations, not claims established by the first
experiment. The ABI/glue proof precedes IR integration rather than being deferred
until after choosing an incompatible VM.

| Area | Required evidence |
|---|---|
| Handler ABI | compiled register map; no bank arguments on stack; attributes enforced |
| Bank forwarding | distinct full-width sentinels in every lane through multiple handlers |
| Stack transitions | subtraction/division order; mixed-class conversions; overflow/refill |
| Long chains | long loops without native-stack growth; both branches and joins |
| Native outbound | 0, register-limit, and over-limit arguments; mixed classes; stack alignment |
| Native inbound | callee-saved sentinels; exact scalar and aggregate results; hidden returns |
| Re-entry | nested callbacks and concurrent calls with independent save areas |
| Varargs | actual promotions and AL convention checked by an independent C callee |
| Aggregate ABI | register-class rollback, mixed aggregate arguments/returns, memory class |
| Memory | address-taken locals, alias snapshots, lifetime across a nested call |
| Traps | recoverable native trap, cleanup before longjmp, successful subsequent invocation |
| Tasks | saved bank/context across resume; existing WAIT/YIELD/DONE values and budget behavior |
| Patches | full-width constants, negative displacements, range rejection, far calls |
| Publication | no entry before resolution and RX protection; failed build cleans mappings |

Then lower real prepared IR and compare results with both existing backends.
Exercise native, storage, task, and I/O acceptance slices as each supported scope
becomes complete. Record environmental skips separately from failures.

Measure specialization, lowering/selection, layout/patching, publication, and
artifact loading separately. Compare native runtime speed, code bytes, pack bytes,
frame size, bank-overflow traffic, and boundary cost. Report fused and unfused
variants; do not judge the design only on arithmetic that never crosses a boundary.

Remaining unobserved facts are the exact supported bank signature/register map,
the generated bridge machine code, and measured costs. The contracts above specify
what those implementations must do; they do not replace verification with a claim.
No new production backend, default selection, or performance promise is introduced
by this design document.
