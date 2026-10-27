# A symbolic VM as a stencil ABI

Isolated feasibility experiment, not an SLC backend. No compiler sources changed.

## Question and result

Can a tiny VM supply an ABI, compile its handlers as C functions ahead of time,
and then disappear when Lua copies and patches those handlers into native code?

**Yes, for the scalar machine tested here.** Clang 22.1.8 on Linux x86-64 compiles
seven handlers using the common SysV signature `uint64_t(uint64_t x, uint64_t a)`.
`x` and `a` travel in `rdi` and `rsi`. `musttail` continuations become direct jump
relocations. No interpreter, opcode fetch, dispatch loop, VM register array, or
Lua invocation occurs inside the generated functions. LuaJIT FFI calls their entry.

This is not concatenation of arbitrary C functions: continuation handlers must
satisfy `musttail` and the uniform ABI. Only exit handlers return. The compiler
provides instruction selection and the per-handler register allocation.

## Pieces

- [handlers.c](<handlers.c>): multiply/add a patchable constant, initialize an
  accumulator, branch on zero, accumulate/decrement, and two returns.
- [extract.py](<extract.py>): dependency-free, deliberately narrow ELF64 extractor.
  Reads function sections and RELA records into a generated Lua stencil table.
  Rejects unsupported relocation kinds and symbols rather than guessing.
- [run.lua](<run.lua>): a construction-time graph of stencil names, constants, and
  continuation labels. Layout, copy, patch, then change RW memory to RX. Supports
  unsigned/signed 32-bit immediate and PC-relative 32-bit patches, with range
  checks. No RWX mapping. Removes an exact terminal `jmp NEXT` instruction only
  when its successor is the immediately following stencil.
- [run.sh](<run.sh>): reproducible build, tests, and disassembly.

Run from the session workspace (`slc/` inside the repository):

```sh
bash experiments/copy_patch/run.sh
```

Requires Linux x86-64, Clang with `musttail`, Python 3, LuaJIT, and GNU objdump.
Generated objects, Lua tables, machine code, and disassembly remain in ignored
[build/copy_patch](<../../build/copy_patch/>). The Lua assembly/execution phase does
not invoke a C compiler or linker. C compilation and ELF extraction happen first.

## Observed evidence

Each run passes **40,046 assertions**, both normally and with `luajit -joff`:

- `x * 3 + 7` and triangular sum for every input 0–10,000;
- selected exact U64 wraparound cases (LuaJIT integer cdata, not double arithmetic);
- a million-round loop, with no recursive stack growth;
- 32 independently patched variants of the same stencils;
- rejection of an overflowing signed immediate, an absent target, and an absent
  immediate binding;
- the same positive tests with and without terminal-jump removal.

| Program | Keeping jumps | With fallthrough |
|---|---:|---:|
| `x * 3 + 7` | 30 bytes | 20 bytes |
| `sum(1..x)` | 38 bytes | 33 bytes |

The assembled affine function actually disassembles to:

```asm
mov  $3, %eax
imul %rax, %rdi
lea  7(%rdi), %rdi
mov  %rdi, %rax
ret
```

The sum loop actually disassembles to:

```asm
xor  %esi, %esi
head:
test %rdi, %rdi
jne  body
xor  %edi, %edi
jmp  exit
body:
add  %rdi, %rsi
dec  %rdi
jmp  head
exit:
mov  %rsi, %rax
ret
```

No hand-written machine instructions implement these operations. The only
instruction-specific rewrite is recognizing and dropping the terminal five-byte
jump; relocation fields come from the C compiler's ELF output. The loop also
shows a cost: per-handler compilation retains a redundant zeroing and extra jump
that whole-function compilation could eliminate.

Strict C warnings and shell syntax checks pass. No full SLC regression suite,
backend integration tests, performance benchmark, or compilation-latency comparison
was run: production SLC code is unchanged. Existing unrelated work was preserved.
Initial `jj status` was blocked by the repository lock outside the writable
workspace; read-only `jj --ignore-working-copy log` succeeded.

## What this proves, and does not

The shared C ABI is enough to compose these stencils while keeping the entire
machine state in real registers. A runtime VM state structure is **not necessary**
for this example. This avoids needing a custom register allocator for the probe;
it does not solve arbitrary live-value assignment for an SLC backend.

The graph is manually constructed, not lowered from actual SLC prepared IR.
There are only two U64 state registers, small immediate constants, one platform,
and no foreign calls, aggregates, memory operations, spills, floating point,
tasks, unwind metadata, debug metadata, or general relocation support. x86 cache
coherence is assumed; another architecture needs explicit instruction-cache work.
The extractor is a trusted build helper, not a hardened arbitrary-object loader.

Constants patched after compilation do not trigger new C optimizations: multiplier
3 uses `imul`, not an optimized shift/add sequence. More stencil variants could
trade offline size for better generated code. Guaranteed tail calls and flags
that prohibit instrumentation/prologues unsuitable for copying are part of this
experiment's build contract, not a guarantee for arbitrary C handlers.

The next coherent question is whether this ABI can handle a small **real residual
IR** subset, including spilled locals and loads/stores, while retaining the same
copy/patch-only runtime assembly. That is separate work, not implemented here.
