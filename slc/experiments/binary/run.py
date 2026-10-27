#!/usr/bin/env python3
"""Reproduce correctness gates, code inspection artifacts and paired benchmarks.
Run from any directory. All generated files remain in slc/build/binary/.
"""
import argparse
import csv
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = ROOT / "slc/build/binary"


def main():
    global OUT
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", type=int, default=9)
    parser.add_argument("--milliseconds", type=float, default=30)
    parser.add_argument("--check-only", action="store_true")
    parser.add_argument("--sanitizer-cc", default=os.environ.get("CC", "cc"))
    args = parser.parse_args()
    OUT = OUT / (time.strftime("run-%Y%m%d-%H%M%S") + f"-{os.getpid()}")
    OUT.mkdir(parents=True, exist_ok=False)
    print(f"Artifacts: {OUT}", flush=True)
    snapshot = OUT / "sources"
    snapshot.mkdir()
    for source in HERE.iterdir():
        if source.is_file():
            (snapshot / source.name).write_bytes(source.read_bytes())
    env = os.environ.copy()
    rocks = subprocess.check_output(["luarocks", "--lua-version=5.1", "path", "--lr-cpath"], text=True).strip()
    env.update(LUA_CPATH=rocks + ";;", SLC_CACHE=str(ROOT / "slc/build/cache"),
               TMPDIR=str(OUT), SLC_DSL_DOC=str(OUT / "wire.md"))
    cpu = None
    if hasattr(os, "sched_getaffinity"):
        allowed = sorted(os.sched_getaffinity(0))
        cpu = allowed[len(allowed) // 2]
        os.sched_setaffinity(0, {cpu})
    cc = os.environ.get("CC", "cc")
    commands = []

    def run(command, name, expected=0, extra_env=None):
        start = time.perf_counter()
        result = subprocess.run([str(x) for x in command], cwd=ROOT, env=extra_env or env,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        elapsed = time.perf_counter() - start
        (OUT / (name + ".stdout")).write_text(result.stdout)
        (OUT / (name + ".stderr")).write_text(result.stderr)
        commands.append({"name": name, "command": [str(x) for x in command],
                         "seconds": elapsed, "exit": result.returncode})
        (OUT / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        if result.returncode != expected:
            raise RuntimeError(f"{name}: exit {result.returncode}, expected {expected}\n{result.stdout}\n{result.stderr}")
        print(f"{name}: exit {result.returncode}, {elapsed:.3f}s", flush=True)
        return result, elapsed

    compiler_diff = subprocess.check_output(["git", "diff"], cwd=ROOT, text=True)
    (OUT / "compiler-worktree.patch").write_text(compiler_diff)
    info = {"platform": platform.platform(), "machine": platform.machine(), "pinned_cpu": cpu,
            "git_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
            "dirty_tracked_tree": bool(compiler_diff),
            "compiler": subprocess.check_output([cc, "--version"], text=True),
            "sanitizer_compiler": subprocess.check_output([args.sanitizer_cc, "--version"], text=True),
            "cpu": subprocess.check_output(["lscpu"], text=True),
            "samples": args.samples, "target_ms": args.milliseconds,
            "scope": "hot 256-packet corpus; out-of-line ABI; no LTO; no I/O/allocation in timed region"}
    (OUT / "environment.json").write_text(json.dumps(info, indent=2) + "\n")
    lua = ["luajit", "slc.lua"]
    sources = sorted(HERE.glob("*.slc"))
    run(lua + ["fmt", "--check"] + sources, "format")
    generate = lua + ["-H", OUT / "packet.h", "-o", OUT / "packet.c", HERE / "packet.slc"]
    staging_times = [run(generate, f"generate-{i}")[1] for i in range(3)]
    rejects = {"reject_duplicate": "duplicate/invalid field name",
               "reject_mutate_borrow": "is borrowed",
               "reject_payload_write": "not-a-place",
               "reject_payload_escape": "borrows cannot be stored"}
    for fixture, diagnostic in rejects.items():
        result, _ = run(lua + ["-o", OUT / (fixture + ".c"), HERE / (fixture + ".slc")], fixture, expected=1)
        if diagnostic not in result.stderr + result.stdout:
            raise RuntimeError(f"{fixture}: wrong rejection, expected {diagnostic!r}")

    common = [cc, "-std=c99", "-Wall", "-Wextra", "-Werror", "-pedantic", "-fno-lto",
              "-ffunction-sections", "-fdata-sections", "-Iruntime", "-I" + str(OUT), "-I" + str(HERE)]
    codec_sources = [OUT / "packet.c", HERE / "baseline.c", HERE / "fused.c"]
    for opt in ("-O0", "-O2", "-O3"):
        output = OUT / ("check" + opt)
        run(common + [opt] + codec_sources + [HERE / "check.c", "runtime/slc_rt.c", "-pthread",
             "-Wl,--gc-sections", "-o", output], "build-check" + opt)
        result, _ = run([output], "check" + opt)
        print(result.stdout.strip(), flush=True)
    sanitizer = OUT / "check-sanitized"
    run([args.sanitizer_cc] + common[1:] + ["-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
        + codec_sources + [HERE / "check.c", "runtime/slc_rt.c", "-pthread", "-Wl,--gc-sections",
                           "-o", sanitizer], "build-sanitized")
    san_env = dict(env, ASAN_OPTIONS="detect_leaks=1:abort_on_error=1", UBSAN_OPTIONS="halt_on_error=1")
    result, _ = run([sanitizer], "check-sanitized", extra_env=san_env)
    print(result.stdout.strip(), flush=True)
    if args.check_only:
        return

    summary = {"staging_seconds": staging_times, "variants": {}, "measurements": []}
    for opt in ("-O2", "-O3"):
        objects = []
        timing = {}
        for label, source in (("slc", OUT / "packet.c"), ("c", HERE / "baseline.c"),
                              ("c-fused", HERE / "fused.c")):
            obj = OUT / (label + opt + ".o")
            # Repeated warm compilation: full translation units, not kernel-only time.
            timing[label] = [run(common + [opt, "-c", source, "-o", obj],
                                f"compile-{label}{opt}-{i}")[1] for i in range(3)]
            objects.append(obj)
            run(["nm", "-S", "--size-sort", obj], f"symbols-{label}{opt}")
            run(["objdump", "-dr", obj], f"assembly-{label}{opt}")
        timing["note"] = "SLC TU also contains compact codec, owned probe and emitted runtime helpers"
        summary["variants"][opt] = timing
        executable = OUT / ("bench" + opt)
        run(common + [opt, HERE / "bench.c", "runtime/slc_rt.c"] + objects
            + ["-pthread", "-Wl,--gc-sections", "-o", executable], "link-bench" + opt)
        result, _ = run([executable, args.samples, args.milliseconds], "bench" + opt)
        csv_path = OUT / ("bench" + opt + ".csv")
        csv_path.write_text(result.stdout)
        grouped, pairs = {}, {}
        for row in csv.DictReader(result.stdout.splitlines()):
            key = (row["operation"], int(row["payload"]), row["variant"])
            grouped.setdefault(key, []).append(float(row["ns_per_packet"]))
            pair = (row["operation"], int(row["payload"]), int(row["sample"]))
            pairs.setdefault(pair, []).append(row)
        first_counts = {}
        for (operation, length, sample), pair in pairs.items():
            expected_variants = {"slc", "c-loop"}
            if operation == "encode": expected_variants.add("c-memcpy")
            if operation == "visit": expected_variants.add("c-fused")
            assert len(pair) == len(expected_variants)
            assert {r["variant"] for r in pair} == expected_variants
            assert len({r["iterations"] for r in pair}) == 1
            assert len({r["checksum"] for r in pair}) == 1
            counts = first_counts.setdefault((operation, length), dict.fromkeys(expected_variants, 0))
            counts[pair[0]["variant"]] += 1
        for counts in first_counts.values():
            assert sum(counts.values()) == args.samples
            assert max(counts.values()) - min(counts.values()) <= 1, "unbalanced sample order"
        (OUT / ("sample-order" + opt + ".json")).write_text(json.dumps(
            {f"{op}/{n}": counts for (op, n), counts in first_counts.items()}, indent=2) + "\n")
        print(f"{opt}: paired checksums/counts and balanced sample order verified", flush=True)
        for (operation, length, variant), values in grouped.items():
            summary["measurements"].append({"optimization": opt, "operation": operation,
                "payload": length, "variant": variant, "median_ns": statistics.median(values),
                "min_ns": min(values), "max_ns": max(values), "samples_ns": values})
    (OUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    lines = ["# Binary DSL benchmark", "", "Median ns/packet; C/SLC > 1 means SLC is faster.", "",
             "| Flags | Operation | Payload | SLC ns | C loop ns | C/SLC | C memcpy/fused ns |",
             "| --- | --- | ---: | ---: | ---: | ---: | ---: |"]
    rows = summary["measurements"]
    for opt in ("-O2", "-O3"):
        for operation in ("encode", "decode", "visit", "decode-mixed"):
            for length in (0, 16, 128, 1024, 4096):
                values = {r["variant"]: r["median_ns"] for r in rows if r["optimization"] == opt
                          and r["operation"] == operation and r["payload"] == length}
                control = values.get("c-memcpy", values.get("c-fused"))
                memcpy = f"{control:.2f}" if control is not None else "—"
                lines.append(f"| {opt} | {operation} | {length} | {values['slc']:.2f} | "
                             f"{values['c-loop']:.2f} | {values['c-loop']/values['slc']:.3f} | {memcpy} |")
    (OUT / "summary.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines), flush=True)


if __name__ == "__main__":
    main()
