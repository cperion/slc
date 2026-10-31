# Direct copy-and-patch backend — experimental, deprecated

**Not for production use.** This backend is retained as an experimental,
deprecated implementation for reference and reproducible measurements.
Use libgccjit, the default native backend, for production execution.

The backend implements the [design](<../experiments/copy_patch/DESIGN.md>) using
shared prepared SLC IR. It is selected explicitly:

```lua
local module = slc.load('program.slc', {backend='direct'})
local result = module.run(42)
local native_pointer = module.raw.run
```

Build artifacts first, from the repository root:

```sh
make direct
make test-direct
```

The offline build requires Linux x86-64, Clang supporting `preserve_none` and
`musttail`, a C compiler, LuaJIT, Python 3, GNU binutils, and the normal SLC build
prerequisites. `direct_dir` selects another artifact directory. Missing artifacts,
foreign layout facts, constants, and symbols are errors, not compiler fallbacks.
`libs` supplies prebuilt native libraries. `runtime_path` and `runtime_metadata`
can select prepared runtime artifacts; these must match the compiler headers.

## Execution and ABI

Handler parameters **are the VM register bank**. Clang allocates the physical
registers; Lua does not contain a register allocator. On Clang 22.1.8:

| Parameter | Location |
|---|---|
| Context | R12 |
| Integer lanes 0–10 | R13, R14, R15, RDI, RSI, RDX, RCX, R8, R9, R11, RAX |
| 128-bit SIMD carriers 0–7 | XMM0–XMM7 |

Handlers tail-call successors with the uniform signature in [abi.h](<abi.h>).
Expressions use separate integer and floating operand stacks; excess operands
spill to explicit frame storage. Mutable places, snapshots, and arguments/results
that must survive calls also have typed frame storage. There is no instruction
interpreter or runtime opcode dispatch loop.

[direct_stencils.lua](<../../tools/direct_stencils.lua>) generates primitive C
families offline. [pack.py](<pack.py>) extracts machine code, read-only sections,
and validated relocation records. [lower.lua](<lower.lua>) selects and connects
stencils. [assemble.lua](<assemble.lua>) patches exact-width literals, successors,
entry addresses, and nearby native-call veneers. It removes only eligible terminal
jumps to the immediately following node. Publication changes mappings from RW to
RX only after resolution; failed construction releases unpublished mappings.

Ordinary internal calls pass a typed argument packet through `cp_invoke_frame`,
not through the source function's SysV signature. Native boundaries instead use
the explicit call image and [assembly gates](<gates.S>): six integer registers,
eight SIMD registers, stack arguments, variadic AL, and integer/SIMD return images.
The planner implements recursive INTEGER/SSE eightbyte classification, whole-value
register rollback, and hidden memory returns. Small aggregate native returns use
an epilogue while the invocation frame is still alive. The compiler-derived layout
fingerprint is checked before execution.

Incoming stubs supply immutable descriptors without disturbing native arguments.
Each invocation owns its save areas, including nested callbacks and calls from
multiple native threads. Published code, descriptors, literals, globals, native
libraries, and TLS descriptors remain pinned. Raw pointers must not be invoked
after the hosting Lua state is destroyed.

## Runtime and supported lowering

The backend lowers scalar integer/Bool/F32/F64 operations and conversions, pointers,
locals, aggregate snapshots and field/index access, arrays, sums, native and
internal calls, function pointers, structured and prepared control flow, atomics,
fences, traps, globals, Goose stack operations, task spawning, waits, and blocking
callbacks.

The runtime algorithms remain the existing ordinary SLC sources. The explicit
build compiles the shared runtime policy; direct loading never builds it on a
cache miss. The native loader and direct loader share one process runtime, so TLS
trap and storage state cannot accidentally split into two instances.

[direct_runtime.lua](<../../tools/direct_runtime.lua>) reuses the C declaration
reader and obtains sizes, alignments, field offsets, and constant values from a
compiled offline probe. Foreign runtime views use the complete header layout,
not a guessed layout of the fields exposed by a partial view. The build also
provides native TLS accessors and wrappers for existing inline header functions.
The standard I/O vocabulary's native constants are prepared by that probe.
Private module TLS uses one platform TLS key per module, with per-thread initial
images and native-thread exit cleanup.

Tasks retain their locals and operation records in the runtime-owned frame after
the authoritative `slc_task` prefix. Native step entries attach the VM context to
that frame and branch to the saved continuation. Operand stacks are empty at
suspension boundaries. WAIT/YIELD/DONE, budget checks, ownership transfers, Goose
watermarks, and blocking-job behavior follow the same prepared IR/runtime as the
other backends. Blocking callbacks reuse the persistent environment; they are not
Lua callbacks or interpreted task bodies.

Lua-facing calls use the shared `slc_try` recovery mechanism. Raw native entries
have the normal native runtime contract: callers must provide a recovery boundary
if they want recoverable traps. Traps during active task scopes remain fatal where
the existing runtime requires that behavior. Host argument owners stay pinned
through re-entrant calls. The small Lua marshaling wrapper is deliberately not
JIT-traced, so a foreign call can safely enter a LuaJIT FFI callback; guest execution
remains native copied code.

## Explicit limits

- The measured target is Linux x86-64. No claim is made for another architecture,
  compiler ABI, x87/long-double/vector ABI classes, or alignment above 16 bytes.
- General foreign headers/macros need additional prebuilt metadata/adapters.
  Unknown facts are diagnosed; no header probe runs implicitly.
- Defining an externally named C global requires a prebuilt object. Imported
  globals, private module globals, runtime TLS, and private module TLS are supported.
  This backend does not publish a new ELF shared object's symbol table.
- Native function pointers are retained for process use, not independently
  unloadable code objects. LuaJIT FFI restrictions still apply to direct calls of
  some by-value aggregate signatures; native C adapters and Lua argument packets
  do not rely on those FFI call shapes.
- Native stack frames and copied code retain the target's stack/resource limits.
  There is no claim of bounded memory for unbounded source recursion.

## Verification

The tests distinguish independent native ABI checks from real-source integration:

- [direct_abi.c](<../../tests/direct_abi.c>) and its [assembly observer](<../../tests/direct_abi.S>):
  all bank lanes, callee-saved state, deliberate native clobbers, stack arguments,
  aggregate return classes, varargs, nested/concurrent callbacks, and longjmp.
- [direct.lua](<../../tests/direct.lua>): copied handlers, full-width values,
  million-round loops, patch validation, far calls, and both LuaJIT modes.
- [direct_ir.lua](<../../tests/direct_ir.lua>): emitted C/libgccjit/direct
  comparisons, native entry adapters, recursion, scalar/aggregate C calls, and traps.
- [direct_storage.lua](<../../tests/direct_storage.lua>): existing Store/Grow/Map
  sources, recovered storage traps, and concurrent native atomic updates.
- [direct_tasks.lua](<../../tests/direct_tasks.lua>): existing scheduler/channel/pool,
  timer, blocking, and I/O examples compared with C and libgccjit.
- [direct_standalone.lua](<../../tests/direct_standalone.lua>): fresh-process loading
  with compiler/process entry points disabled, escaped callbacks, thread-local
  initialization, and Lua callback/GC re-entry.

Generated artifacts and logs stay under ignored `build/direct`. Consult current
test output for observed counts rather than treating this feature inventory as
proof of every possible program.

UBSan's function-type check expects compiler metadata before an indirect target;
copied entries do not have that metadata. Native glue sanitizer checks therefore
use `-fsanitize=address,undefined -fno-sanitize=function`. Copied machine code itself
is not instrumented. No runtime-speed or compilation-latency claim is made.
