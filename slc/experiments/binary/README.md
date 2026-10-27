# Binary formats as an SLC vocabulary

An experiment, not a general serialization library. One description drives native
encoding, callback-based zero-copy decoding, validated encoded size, and Markdown
wire documentation. All algorithms are ordinary SLC words. Lua only constructs
and inspects the descriptions; no new macro or compiler primitive is involved.

## The program the user writes

From [schema.slc](schema.slc):

```lua
local packet = binary.format(Message) {
    binary.u8 "version" { equals = 1 },
    binary.u8 "flags" { max = 3 },
    binary.u32be "sequence" {},
    binary.bytes "length" { prefix = 2, max = 4096 },
}
```

The final word describes a length prefix followed by that many payload bytes.
Offsets, total header size and integer limits are computed from the description.
The native `Message` record is deliberately separate from its wire layout: its
fields are U32, so invalid narrow-field values can be rejected rather than
silently truncated. A second layout reorders fields, changes sequence to little
endian, changes the version/flags constraints, and uses a one-byte length prefix.
Reusable field descriptions are copied when a layout is prepared, so assembling
one layout cannot overwrite another layout's offsets.

[binary.slc](binary.slc) contains the vocabulary and its interpretations;
[packet.slc](packet.slc) exposes concrete native entry points. A consumer can use:

```lua
binary.decode(packet, input) do(record, payload)
    -- validated header, borrowed read-only payload
    -- domain work goes here, and specializes with the decoder
end
```

The callback is not a runtime function pointer. The tested visitor computes a
checksum directly inside the specialized decoder. It allocates and copies no
payload. The exported metadata decoder has a callback that copies only the four
header scalars into the caller's result.

## Contract

- Fixed unsigned integers of 1, 2 or 4 bytes; a single final length-prefixed byte
  payload. No nested messages, checksums on the wire, varints, or optional fields.
- Packet header: version=1, flags in 0..3, big-endian U32 sequence, big-endian U16
  length in 0..4096. Header size is eight bytes.
- Compact header: little-endian U32 sequence, version=2, flags in 0..15, U8 length
  in 0..255. Header size is seven bytes.
- `size(record, payload_length)` returns the validated total size or zero.
- `encode(record, payload, output, capacity)` validates everything before its first
  write. It returns bytes written, or zero with the entire output unchanged.
- `decode(input, body)` validates the complete packet before invoking the callback.
  Rejection returns zero and does not invoke the callback. Success returns bytes
  consumed. It parses a **prefix**: trailing bytes are permitted and not consumed.
- The metadata decode exports leave the output record unchanged on rejection.
- Zero intentionally conflates invalid fields, inconsistent length, truncation,
  and insufficient output capacity. This is not a rich diagnostic API.
- All foreign pointers must refer to live, suitably sized memory for the duration
  of a call. Input/output regions must not overlap. Empty payloads may use a null
  pointer; a null zero-length input is rejected without reading it, and a null
  zero-capacity output is rejected without writing it. These are C-boundary caller
  obligations, not claims of compiler-checked allocation bounds.
- Inside SLC, payload slices are read-only borrows. The tests reject storing them
  inside owned records, writing through them, or growing their viewed owner while
  the callback runs. Deliberately escaping via `Ptr` would cross the unchecked
  boundary; this library does not do that for decoded payloads.
- The payload callback may have arbitrary effects; it is not a rollback mechanism.

The generated header export currently contains prototypes but not type definitions.
[baseline.h](baseline.h) mirrors the two native ABI records for the independent C
translation units. It does not supply or generate wire offsets for the SLC codec.

## Reproduction

From the session workspace:

```sh
python3 experiments/binary/run.py --sanitizer-cc clang
```

On a machine whose default C compiler has working sanitizer libraries, omit that
option. It selects only the sanitizer compiler; benchmark builds still use `CC`
(or `cc`). Nothing silently falls back or turns a failed check into a skip.

The runner writes each attempt to a new subdirectory of ignored
[build/binary/](../../build/binary/), prints that path, and retains commands, exit
codes, stdout/stderr, raw CSV samples, compiler/CPU metadata, generated C, generated
wire documentation, symbol sizes, disassembly, and a summary. Earlier attempts are
not overwritten. `--check-only` runs acceptance checks without benchmarks;
`--samples` and `--milliseconds` control the paired timing samples.

## Correctness strategy

[check.c](check.c) tests independently specified golden byte sequences, every legal
payload length for both layouts, C/SLC differential encoding and decoding, checksums,
trailing bytes, output preservation, exact-capacity writes, one-byte-short outputs,
selected exhaustive truncations, all compact truncations, selected invalid U32
inputs, 12,000 seeded mutations, null/zero cases, and guard pages after input spans.
Both the byte-loop and `memcpy` C encoders must agree byte-for-byte. A native-owned
array exercises the callback path without a foreign pointer.

The runner executes this under strict C99 at `-O0`, `-O2`, and `-O3`, then with
AddressSanitizer and UndefinedBehaviorSanitizer. Four negative compilation fixtures
check duplicate fields and the borrow restrictions. SLC formatting is also checked.
These are experiment acceptance gates, not a full compiler regression campaign.

## Benchmark design

[baseline.c](baseline.c) implements the same packet format directly in C. It is not
a deliberately slow runtime schema interpreter. There are two encoders: an ordinary
byte loop and a `memcpy` variant. Both use the same validation and failure contract.
[bench.c](bench.c) compares:

1. Encoding, including validation and payload copy.
2. Zero-copy metadata decoding, including validation and header output.
3. Decoding plus payload checksum, which actually reads the entire payload.
4. Mixed decoding: 50% valid, 25% invalid version, 25% truncated.

Payload lengths are 0, 16, 128, 1024 and 4096. The corpus holds 256 varying packets
in preallocated buffers. Allocation, corpus generation, correctness checks, and
printing are outside timing. The corpus is hot and repeatedly visited: this does
not measure networking, cold-cache performance, allocation, or streaming I/O.

[fused.c](fused.c) is an additional control for the visitor: it manually combines
header decoding and checksum consumption instead of calling the reusable C decoder.
That distinguishes a composition/inlining effect from a claim that C cannot express
the same optimization. The summary's last column means `memcpy` for encoding and
hand fusion for visiting; the main C column always means the ordinary C API.

Both implementations use the same compiler and flags, native ABI, data, out-of-line
call structure, and work. Translation units are separate, LTO is disabled, and
checksums are observed and compared. Input/output pointers use no `restrict` hints.
The process pins itself to one permitted CPU. Warmups precede measurements; sample
order rotates and reverses. Iterations calibrate against the fastest variant and
are equal within a case. The default is nine samples of approximately at least
30 ms per variant; raw samples and min/max/median are retained.

The sample time includes common driver/call/checksum overhead. Small metadata-only
operations are especially sensitive to that overhead, code alignment, branch
predictors, clock changes, and the surrounding shared machine. Medians are not
confidence intervals. No result here supports “SLC is faster than C” generally.

Compilation measurements include process startup and use repeated warm runs. SLC
staging time is separate from downstream C compilation. The SLC translation unit
also exports the compact codec and owned-array probe and includes emitted runtime
helpers, so whole-TU compile times and sizes are **not** an equal-feature code-size
contest. Per-function symbol sizes provide the narrower kernel comparison.

## What this experiment is intended to reveal

The schema loops should disappear; payload loops and necessary validation should
remain. DSL ergonomics and runtime performance are separate questions: specialization
can remove the description machinery without choosing the best bulk-copy algorithm.
A libc `memcpy` win would identify that distinction, not invalidate the DSL model.

The callback form also tests whether parsing and immediate consumption can compose
without a runtime callback or a temporary decoded heap object. The read-only borrow
contract is part of the vocabulary, not decoration around unchecked C algorithms.

See the [measured results and implementation observations](RESULTS.md), including
complete timing tables, code sizes, compile costs, limitations, and preserved
failed/exploratory attempts.
