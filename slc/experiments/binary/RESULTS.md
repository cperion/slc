# Binary DSL: results and reflection

## Main finding

**In this experiment, a reusable SLC format description and callback consumer reach
roughly hand-written C performance, without turning the description or callback
into runtime machinery.** That is not a universal speed advantage: a better bulk
copy still wins, code generation idioms matter, and ordinary C can achieve the same
fusion manually or through a more aggressive optimizer.

See the [language/library design and reproduction instructions](README.md) and
[actual schemas](schema.slc). The final accepted run is
[run-20261031-102254-2](../../build/binary/run-20261031-102254-2/).

## Measurement conditions

AMD Ryzen 7 PRO 8840HS, Linux x86-64, GCC 16.2.1; process pinned to CPU 8. Nine samples
per case, warm 256-packet corpus, matching inputs/validation/ABI/compiler flags,
separate translation units, no LTO, no allocation or I/O in timed regions.
Both `-O2` and `-O3` were measured. The runner verifies equal paired iteration counts,
checksums, variant sets, and balanced first-position counts from the actual CSV.
See [environment](../../build/binary/run-20261031-102254-2/environment.json),
[commands](../../build/binary/run-20261031-102254-2/commands.json), and
[methodology](README.md#benchmark-design).

These are medians, not confidence intervals. A few-percent difference is not a
portable ranking. All raw samples and their min/max remain in the
[JSON summary](../../build/binary/run-20261031-102254-2/summary.json).

## Runtime results

**Nanoseconds per packet, lower is better.** C means the straightforward reusable
C implementation, not a runtime schema interpreter. The control column is
`memcpy` for encoding and manually fused C for decoding plus checksum.

### GCC -O3

| Operation | Payload bytes | SLC | C | C control |
| --- | ---: | ---: | ---: | ---: |
| Encode | 0 | 4.00 | 3.60 | 3.69 |
| Encode | 16 | 5.23 | 5.28 | 6.34 |
| Encode | 128 | 7.81 | 8.03 | 8.40 |
| Encode | 1024 | 31.99 | 32.12 | 29.31 |
| Encode | 4096 | 117.91 | 119.98 | 118.33 |
| Decode metadata | 0 | 11.09 | 11.10 | — |
| Decode metadata | 16 | 11.10 | 11.08 | — |
| Decode metadata | 128 | 11.09 | 11.09 | — |
| Decode metadata | 1024 | 11.08 | 11.07 | — |
| Decode metadata | 4096 | 11.08 | 11.08 | — |
| Decode + checksum | 0 | 2.79 | 3.07 | 3.07 |
| Decode + checksum | 16 | 4.39 | 4.38 | 4.51 |
| Decode + checksum | 128 | 11.45 | 10.35 | 10.41 |
| Decode + checksum | 1024 | 68.57 | 72.10 | 73.24 |
| Decode + checksum | 4096 | 255.69 | 259.70 | 261.41 |
| Mixed decode | 0 | 6.15 | 6.07 | — |
| Mixed decode | 16 | 6.28 | 6.24 | — |
| Mixed decode | 128 | 6.28 | 6.23 | — |
| Mixed decode | 1024 | 6.28 | 6.24 | — |
| Mixed decode | 4096 | 6.27 | 6.23 | — |

There is no uniform winner. Encoding and metadata decoding are very close; the
128-byte checksum case is about 11% slower for SLC in this run, while some other
cases favor SLC. The tiny empty-payload cases include substantial call/driver cost.

Metadata decode writes a record and the driver then reads it. The checksum visitor
returns a packed scalar. **Do not interpret their absolute timings as an apples-to-
apples comparison of different amounts of work**: the result ABIs differ. Each
SLC-versus-C comparison within a row does use the same ABI and work.

### GCC -O2

| Operation | Payload bytes | SLC | C | C control |
| --- | ---: | ---: | ---: | ---: |
| Encode | 0 | 3.70 | 3.69 | 3.40 |
| Encode | 16 | 9.21 | 8.83 | 6.59 |
| Encode | 128 | 49.11 | 48.83 | 8.19 |
| Encode | 1024 | 348.25 | 346.92 | 32.74 |
| Encode | 4096 | 1298.95 | 1287.48 | 116.65 |
| Decode metadata | 0 | 11.24 | 11.20 | — |
| Decode metadata | 16 | 11.25 | 11.23 | — |
| Decode metadata | 128 | 11.25 | 11.19 | — |
| Decode metadata | 1024 | 11.24 | 11.21 | — |
| Decode metadata | 4096 | 11.24 | 11.20 | — |
| Decode + checksum | 0 | 2.53 | 4.63 | 3.08 |
| Decode + checksum | 16 | 4.35 | 9.53 | 4.31 |
| Decode + checksum | 128 | 10.65 | 52.67 | 10.61 |
| Decode + checksum | 1024 | 65.44 | 429.12 | 71.00 |
| Decode + checksum | 4096 | 247.99 | 1903.28 | 248.57 |
| Mixed decode | 0 | 6.29 | 6.23 | — |
| Mixed decode | 16 | 6.40 | 6.38 | — |
| Mixed decode | 128 | 6.39 | 6.37 | — |
| Mixed decode | 1024 | 6.40 | 6.37 | — |
| Mixed decode | 4096 | 6.42 | 6.38 | — |

Two important counterpoints:

- At 4096 bytes, SLC's fused visitor is about **7.7× faster than the ordinary C API
  composition**, but it is essentially tied with **hand-fused C**. The
  [C disassembly](../../build/binary/run-20261031-102254-2/assembly-c-O2.stdout)
  retains a decoder call and scalar checksum loop. The
  [SLC disassembly](../../build/binary/run-20261031-102254-2/assembly-slc-O2.stdout)
  and [fused C control](../../build/binary/run-20261031-102254-2/assembly-c-fused-O2.stdout)
  contain vectorized checksum loops. This is a composition/optimization-boundary
  result, not something C cannot express. At `-O3`, the ordinary C version catches up.
- At the same payload size, C with `memcpy` is about **11× faster than both simple
  byte-loop encoders at -O2**. Specializing a DSL removes its description machinery;
  it does not automatically replace its algorithm with the best platform routine.
  At `-O3` the loops vectorize and that gap largely closes in this hot-buffer test.

Full raw CSV: [-O2](../../build/binary/run-20261031-102254-2/bench-O2.csv),
[-O3](../../build/binary/run-20261031-102254-2/bench-O3.csv).

## One useful refinement, entirely inside the DSL library

The initial integer reader used `value * 256 + byte`. Although mathematically
correct, GCC emitted separate byte loads, shifts and additions rather than the
compact byte-swap idiom recognized for the direct C baseline.

Changing that one ordinary SLC word to `bor(shl(value, 8), U32 bytes[at])` preserved
the schemas and wire semantics. The final
[decoder assembly](../../build/binary/run-20261031-102254-2/assembly-slc-O2.stdout#L156-L188)
uses a word load and `bswap`. Metadata decoding is then essentially tied with C.
This is not a new compiler optimization or a foreign helper: the vocabulary's
implementation was improved once, and both layouts and all consumers benefited.

The earlier [multiply/add source snapshot](../../build/binary/run-20261031-101842-2/sources/binary.slc)
and [assembly](../../build/binary/run-20261031-101842-2/assembly-slc-O2.stdout) are retained.
Treat the earlier timing tables as exploratory, not a controlled before/after claim:
a harness ordering defect was subsequently corrected (see below).

## Code size and compile cost

Native function symbol sizes in bytes, excluding alignment gaps and runtime helpers:

| Kernel | SLC -O2 | C -O2 | SLC -O3 | C -O3 |
| --- | ---: | ---: | ---: | ---: |
| Validated size | 52 | 52 | 52 | 52 |
| Byte-loop encoder | 167 | 143 | 499 | 482 |
| Metadata decoder | 93 | 89 | 93 | 89 |
| Visitor | 300 | 93* | 527 | 539 |

*The ordinary C visitor at `-O2` additionally calls the 89-byte decoder and is
scalar. The hand-fused C visitor is 296 bytes at `-O2`, versus SLC's 300 bytes.*

Sources: [SLC -O2](../../build/binary/run-20261031-102254-2/symbols-slc-O2.stdout),
[C -O2](../../build/binary/run-20261031-102254-2/symbols-c-O2.stdout),
[SLC -O3](../../build/binary/run-20261031-102254-2/symbols-slc-O3.stdout),
[C -O3](../../build/binary/run-20261031-102254-2/symbols-c-O3.stdout).

Median of three warm process runs:

- SLC staging and C/header/documentation generation: **0.791 s**.
- Generated SLC translation unit → object: **0.125 s at -O2**, **0.129 s at -O3**.
- Ordinary C baseline translation unit → object: **0.045 s at -O2**, **0.068 s at -O3**.

These whole-translation-unit times are **not equal-feature comparisons**: SLC also
exports the compact codec and owned-array probe and emits runtime support. They
include process startup and are local measurements, not a general compile-time
ratio. Runtime speed is bought partly with staging work and potentially larger
specialized code. The schema tables, field-name traversal and callbacks are absent
from the residual codec; necessary validation and payload loops remain.

## Verification and experimental honesty

Final acceptance passed at GCC `-O0`, `-O2`, `-O3`, and Clang 22.1.8
AddressSanitizer + UndefinedBehaviorSanitizer. The harness prints **17,101,541
checks**, mostly repetitive canary-byte checks: that count is not millions of
independent test cases. Substantive coverage includes every packet length 0..4096,
every compact length 0..255, golden bytes, 12,000 mutations, truncated input,
prefix parsing, unchanged outputs on rejection, exact-size guarded input/output,
and read-only borrow restrictions. All four intended rejection fixtures produced
the expected diagnostics; formatting and paired benchmark checksum/order checks
passed. See [check log](../../build/binary/run-20261031-102254-2/check-O3.stdout) and
[sanitizer log](../../build/binary/run-20261031-102254-2/check-sanitized.stdout).

Failures and corrections were kept, not silently reclassified:

- The first GCC sanitizer **link failed**, because the installed GCC ASan/UBSan
  shared libraries are absent. The [linker diagnostic](../../build/binary/build-sanitized.stderr)
  remains. Clang was then explicitly selected and its instrumented run passed.
- An initial sample-order formula accidentally always put SLC first for two-way
  comparisons. Final review caught it; the formula was corrected and an independent
  CSV check now verifies balanced first-position counts. Only the final balanced
  run supplies this report's tables. Earlier raw runs are preserved.
- The initial callback tried to rebind a captured reference parameter, which the
  language rejects. A small typed assignment word expresses the operation instead;
  it disappears under specialization. No compiler workaround was added.

No JIT/native-backend validation, cold-cache benchmark, multi-platform measurement,
or full project regression suite was run. The repository had existing unrelated
changes; they were left intact. Compiler source was not modified. The final run
records the Git revision, dirty tracked patch, source snapshots, commands and
machine metadata. jj history inspection was unavailable because its metadata lock
is outside this session's writable workspace.

## What this says about SLC DSLs

1. **The schema is useful data, not merely pleasant call syntax.** Encoding,
   decoding, size and documentation agree because they consume one description.
2. **A callback is a place to compose domain work without necessarily creating an
   ABI boundary.** That lets a reusable decoder behave like hand-fused code while
   its source stays modular. C can do the same, but the ordinary function boundary
   may depend on optimizer decisions.
3. **Domain safety is still a library responsibility.** This vocabulary checks
   widths, versions, flags, lengths and buffers; SLC's borrow rules constrain
   payload use. Neither staging nor attractive syntax invents those contracts.
4. **Optimization remains inspectable and local.** Improving one integer reader
   improved both schemas without changing client code. The `memcpy` counterexample
   shows that eliminating abstraction overhead is not the same as choosing an
   optimal algorithm.

The next meaningful extension would be nested/dependent fields plus structured
failure information, followed by streaming/partial input. Those would stress the
DSL's compositional contracts rather than simply adding more benchmark rows.
