#!/usr/bin/env python3
"""Fixed-work PMU comparison for javascript-zoo's Octane benchmarks.

The ordinary zoo runner deliberately preserves Octane's throughput protocol:
each benchmark runs for about one second, so the faster engine performs more
work.  That is the right macro score and the wrong workload for attributing
retired instructions or cycles.  This runner rewrites only the two Octane
harness configuration assignments in a temporary copy:

  * warmup is disabled;
  * deterministic mode is enabled, so both engines execute the benchmark's
    declared ``deterministicIterations`` count (and the same fixed repetitions
    when ``minIterations`` requires more than one batch).

It then records explicit-PMU counters in paired ABBA order.  Ratios are
``zjs / qjs``; below one means zjs retired fewer instructions / cycles.

Usage:
    flock -x /tmp/zjs-host-heavy.lock taskset -c 19 \
      python3 tools/perf/zoo/run_zoo_fixed_pmu.py \
        --zjs zig-out/bin/zjs --qjs /home/aneryu/quickjs/qjs \
        --benches raytrace earley-boyer splay typescript pdfjs \
        --samples 4 --cpu 19 --pmu armv8_pmuv3_1 \
        --output reports/.../zoo-fixed-pmu.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from run_zoo_compare import (
    DEFAULT_BENCHES,
    cpu_model,
    git_describe,
    parse_scores,
    sha256_of,
)


WARMUP_MARKER = "BenchmarkSuite.config.doWarmup = undefined;"
DETERMINISTIC_MARKER = "BenchmarkSuite.config.doDeterministic = undefined;"


def fail(message: str, code: int = 2) -> "NoReturn":  # type: ignore[valid-type]
    print(f"error: {message}", file=sys.stderr)
    sys.exit(code)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fixed_source(source: bytes, path: Path, iteration_divisor: int) -> bytes:
    warmup = WARMUP_MARKER.encode()
    deterministic = DETERMINISTIC_MARKER.encode()
    if source.count(warmup) != 1 or source.count(deterministic) != 1:
        fail(
            f"{path} does not contain exactly one canonical Octane warmup and "
            "deterministic configuration assignment"
        )
    deterministic_replacement = "BenchmarkSuite.config.doDeterministic = true;"
    if iteration_divisor != 1:
        deterministic_replacement += f"""
for (var __zjs_suite = 0; __zjs_suite < BenchmarkSuite.suites.length; __zjs_suite++) {{
  var __zjs_benchmarks = BenchmarkSuite.suites[__zjs_suite].benchmarks;
  for (var __zjs_bench = 0; __zjs_bench < __zjs_benchmarks.length; __zjs_bench++) {{
    var __zjs_item = __zjs_benchmarks[__zjs_bench];
    __zjs_item.deterministicIterations = Math.max(1, Math.ceil(__zjs_item.deterministicIterations / {iteration_divisor}));
    __zjs_item.minIterations = Math.max(1, Math.ceil(__zjs_item.minIterations / {iteration_divisor}));
  }}
}}"""
    return source.replace(
        warmup,
        b"BenchmarkSuite.config.doWarmup = false;",
    ).replace(
        deterministic,
        deterministic_replacement.encode(),
    )


def parse_perf_csv(text: str, event_names: list[str]) -> dict[str, int]:
    counters: dict[str, int] = {}
    for line in text.splitlines():
        parts = line.split(",")
        if len(parts) < 3:
            continue
        raw, event = parts[0].strip(), parts[2].strip()
        if raw in ("<not counted>", "<not supported>"):
            fail(f"perf event was unavailable: {line}", 1)
        for name in event_names:
            if f"/{name}/" in event:
                try:
                    counters[name] = int(float(raw))
                except ValueError:
                    fail(f"invalid perf counter row: {line}", 1)
                break
    missing = [name for name in event_names if name not in counters]
    if missing:
        fail(f"perf stat emitted no counted rows for: {', '.join(missing)}", 1)
    return counters


def run_one(
    binary: Path,
    script: Path,
    event_specs: list[str],
    event_names: list[str],
    timeout: int,
) -> dict:
    with tempfile.NamedTemporaryFile(prefix="zoo-fixed-pmu-", suffix=".csv") as stat:
        started = time.monotonic()
        proc = subprocess.run(
            [
                "perf",
                "stat",
                "-x",
                ",",
                "-e",
                ",".join(event_specs),
                "-o",
                stat.name,
                "--",
                str(binary),
                str(script),
            ],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        elapsed = time.monotonic() - started
        counters = parse_perf_csv(Path(stat.name).read_text(), event_names)
    if proc.returncode != 0:
        fail(
            f"{binary.name} exited {proc.returncode} for {script.name}: "
            f"{proc.stderr.strip()[-400:]!r}",
            1,
        )
    scores = parse_scores(proc.stdout + proc.stderr)
    if not scores:
        fail(
            f"{binary.name} produced no parseable benchmark score for {script.name}",
            1,
        )
    return {
        "counters": counters,
        "wallSeconds": elapsed,
        "stdout": proc.stdout.strip(),
        "scores": scores,
    }


def median(values: list[float]) -> float:
    return statistics.median(values)


def mad(values: list[float]) -> float:
    middle = median(values)
    return median([abs(value - middle) for value in values])


def validate_score_keys(
    bench: str, runs: dict[str, list[dict]]
) -> tuple[str, ...]:
    score_keys: dict[str, tuple[str, ...]] = {}
    for engine in ("qjs", "zjs"):
        per_run_keys = {tuple(sorted(run["scores"])) for run in runs[engine]}
        if len(per_run_keys) != 1:
            fail(
                f"{bench}: {engine} reported inconsistent score keys: "
                f"{sorted(per_run_keys)}",
                1,
            )
        score_keys[engine] = next(iter(per_run_keys))
    if score_keys["qjs"] != score_keys["zjs"]:
        fail(
            f"{bench}: engines reported different score keys "
            f"(qjs {list(score_keys['qjs'])} vs zjs {list(score_keys['zjs'])})",
            1,
        )
    return score_keys["qjs"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zjs", required=True)
    ap.add_argument("--qjs", required=True)
    ap.add_argument("--zoo", default="/home/aneryu/javascript-zoo")
    ap.add_argument("--benches", nargs="*", default=None)
    ap.add_argument("--samples", type=int, default=4)
    ap.add_argument("--cpu", type=int, default=19)
    ap.add_argument("--pmu", default="armv8_pmuv3_1")
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument(
        "--iteration-divisor",
        type=int,
        default=1,
        help=(
            "divide every benchmark's deterministicIterations and minIterations "
            "by this value (rounding up); both engines still execute identical work"
        ),
    )
    ap.add_argument("--output")
    args = ap.parse_args()

    if args.samples < 2 or args.samples % 2 != 0:
        fail("--samples must be an even integer of at least 2 (paired ABBA balance)")
    if args.iteration_divisor < 1:
        fail("--iteration-divisor must be at least 1")
    affinity = set(os.sched_getaffinity(0))
    if affinity != {args.cpu}:
        fail(
            f"effective affinity is {sorted(affinity)}, not exactly [{args.cpu}]; "
            f"run under taskset -c {args.cpu} and the exclusive host lock"
        )

    zjs = Path(args.zjs).resolve()
    qjs = Path(args.qjs).resolve()
    zoo = Path(args.zoo).resolve()
    for binary in (zjs, qjs):
        if not binary.is_file():
            fail(f"binary not found: {binary}")
    bench_dir = zoo / "bench"
    benches = args.benches or DEFAULT_BENCHES
    for bench in benches:
        if not (bench_dir / f"{bench}.js").is_file():
            fail(f"benchmark not found: {bench_dir / f'{bench}.js'}")

    event_names = [
        "instructions",
        "cycles",
        "branch-instructions",
        "branch-misses",
        "cache-references",
        "cache-misses",
    ]
    event_specs = [f"{args.pmu}/{name}/" for name in event_names]
    results: dict[str, dict] = {}
    order_log: list[dict] = []
    first_positions = {"qjs": 0, "zjs": 0}

    with tempfile.TemporaryDirectory(prefix="zoo-fixed-work-") as tmp:
        tmp_dir = Path(tmp)
        for bench in benches:
            original_path = bench_dir / f"{bench}.js"
            original = original_path.read_bytes()
            transformed = fixed_source(original, original_path, args.iteration_divisor)
            script = tmp_dir / original_path.name
            script.write_bytes(transformed)

            runs: dict[str, list[dict]] = {"qjs": [], "zjs": []}
            for sample in range(args.samples):
                order = ["qjs", "zjs"] if sample % 2 == 0 else ["zjs", "qjs"]
                first_positions[order[0]] += 1
                order_log.append({"bench": bench, "sample": sample, "order": "->".join(order)})
                for engine in order:
                    binary = qjs if engine == "qjs" else zjs
                    run = run_one(binary, script, event_specs, event_names, args.timeout)
                    runs[engine].append(run)
                    print(
                        f"  {bench:14} sample {sample + 1}/{args.samples} {engine:4} "
                        f"insn={run['counters']['instructions']:,} "
                        f"cyc={run['counters']['cycles']:,}",
                        file=sys.stderr,
                    )

            validate_score_keys(bench, runs)

            metrics: dict[str, dict] = {}
            for metric in [*event_names, "wallSeconds"]:
                def value(engine: str, index: int) -> float:
                    run = runs[engine][index]
                    return run[metric] if metric == "wallSeconds" else run["counters"][metric]

                qjs_values = [value("qjs", index) for index in range(args.samples)]
                zjs_values = [value("zjs", index) for index in range(args.samples)]
                ratios = [zjs_values[index] / qjs_values[index] for index in range(args.samples)]
                metrics[metric] = {
                    "qjsMedian": median(qjs_values),
                    "zjsMedian": median(zjs_values),
                    "pairedRatiosZjsOverQjs": ratios,
                    "ratioMedian": median(ratios),
                    "ratioMAD": mad(ratios),
                }

            qjs_ipc = metrics["instructions"]["qjsMedian"] / metrics["cycles"]["qjsMedian"]
            zjs_ipc = metrics["instructions"]["zjsMedian"] / metrics["cycles"]["zjsMedian"]
            results[bench] = {
                "source": {
                    "path": str(original_path),
                    "sha256": sha256_bytes(original),
                    "fixedWorkSha256": sha256_bytes(transformed),
                },
                "runs": runs,
                "metrics": metrics,
                "derived": {
                    "qjsIPC": qjs_ipc,
                    "zjsIPC": zjs_ipc,
                    "ipcRatioZjsOverQjs": zjs_ipc / qjs_ipc,
                },
            }

    artifact = {
        "tool": "zjs-zoo-fixed-pmu",
        "schemaVersion": 1,
        "direction": "ratios are zjs/qjs; below 1.0 means zjs used fewer counters or wall time",
        "workload": (
            "temporary source copies set doWarmup=false and doDeterministic=true; "
            "both engines execute identical deterministicIterations/minIterations batches"
        ),
        "iterationDivisor": args.iteration_divisor,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "samplesPerEnginePerBench": args.samples,
        "samplingOrder": "paired ABBA by sample parity",
        "firstPositionCounts": first_positions,
        "firstPositionBalanced": first_positions["qjs"] == first_positions["zjs"],
        "cpu": args.cpu,
        "effectiveAffinity": sorted(affinity),
        "pmu": args.pmu,
        "events": event_specs,
        "kernel": platform.release(),
        "cpuModel": cpu_model(),
        "binaries": {
            "zjs": {
                "path": str(zjs),
                "sha256": sha256_of(zjs),
                "repo": git_describe(Path(__file__).resolve().parents[3]),
            },
            "qjs": {
                "path": str(qjs),
                "sha256": sha256_of(qjs),
                "repo": git_describe(qjs.parent),
            },
        },
        "zoo": git_describe(zoo),
        "benchmarks": results,
        "orderLog": order_log,
    }

    if args.output:
        target = Path(args.output)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(artifact, indent=1) + "\n")

    print("\nbenchmark       insn z/q   cycles z/q    IPC z/q   wall z/q")
    for bench in benches:
        rec = results[bench]
        metrics = rec["metrics"]
        print(
            f"{bench:14} {metrics['instructions']['ratioMedian']:10.4f} "
            f"{metrics['cycles']['ratioMedian']:12.4f} "
            f"{rec['derived']['ipcRatioZjsOverQjs']:10.4f} "
            f"{metrics['wallSeconds']['ratioMedian']:10.4f}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
