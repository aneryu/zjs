#!/usr/bin/env python3
"""Fixed-work PMU comparison over the vendored bench-v8 (Octane 2.0) suite.

The score protocol (run_benchv8_compare.py) deliberately preserves Octane's
throughput design: each benchmark runs for about one second, so the faster
engine performs more work.  That is the right macro score and the wrong
workload for attributing retired instructions or cycles.  This runner
assembles a per-benchmark script from the vendored suite and appends a
configuration override before the run:

  * warmup is disabled;
  * deterministic mode is enabled, so both engines execute the benchmark's
    declared ``deterministicIterations`` count (and the same fixed
    repetitions when ``minIterations`` requires more than one batch).

It then records explicit-PMU counters in paired ABBA order.  Ratios are
``zjs / qjs``; below one means zjs retired fewer instructions / cycles.

This is the SCREENING instrument: run it (targeted at the touched
benchmarks) before spending a full score A/B on a candidate.  It replaced
tools/perf/zoo/run_zoo_fixed_pmu.py on 2026-08-29 when the external
javascript-zoo checkout was retired in favour of the vendored suite.

Usage:
    python3 tools/perf/measure_fields.py run --field b --layer single -- \
      python3 tools/perf/bench_v8/run_fixed_pmu.py \
        --zjs zig-out/bin/zjs --qjs /home/aneryu/quickjs/qjs \
        --benches raytrace splay typescript --field b \
        --samples 2 --pmu armv8_pmuv3_1 \
        --output /tmp/fixed-pmu.json
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

PERF_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PERF_DIR))
from measure_fields import field_metadata, lock_attested, single_cpu  # noqa: E402

# Benchmark name -> vendored suite files, in load order after base.js.
BENCH_FILES: dict[str, list[str]] = {
    "richards": ["richards.js"],
    "deltablue": ["deltablue.js"],
    "crypto": ["crypto.js"],
    "raytrace": ["raytrace.js"],
    "earley-boyer": ["earley-boyer.js"],
    "regexp": ["regexp.js"],
    "splay": ["splay.js"],
    "navier-stokes": ["navier-stokes.js"],
    "pdfjs": ["pdfjs.js"],
    "mandreel": ["mandreel.js"],
    "gbemu": ["gbemu-part1.js", "gbemu-part2.js"],
    "code-load": ["code-load.js"],
    "box2d": ["box2d.js"],
    "zlib": ["zlib.js", "zlib-data.js"],
    "typescript": ["typescript.js", "typescript-input.js", "typescript-compiler.js"],
}
DEFAULT_BENCHES = list(BENCH_FILES)

CONFIG_OVERRIDE = (
    "BenchmarkSuite.config.doWarmup = false;\n"
    "BenchmarkSuite.config.doDeterministic = true;"
)

RUNNER_FOOTER = """
var __zjs_success = true;
function __zjsPrintResult(name, result) { print(name + ': ' + result); }
function __zjsPrintError(name, error) { __zjsPrintResult(name, 'ERROR: ' + error); __zjs_success = false; }
function __zjsPrintScore(score) { if (__zjs_success) { print('----'); } }
BenchmarkSuite.RunSuites({ NotifyResult: __zjsPrintResult, NotifyError: __zjsPrintError, NotifyScore: __zjsPrintScore });
"""


def fail(message: str, code: int = 2) -> "NoReturn":  # type: ignore[valid-type]
    print(f"error: {message}", file=sys.stderr)
    sys.exit(code)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_of(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def git_describe(path: Path) -> str:
    try:
        proc = subprocess.run(
            ["git", "-C", str(path), "describe", "--always", "--dirty"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except OSError:
        return "unavailable"
    return proc.stdout.strip() if proc.returncode == 0 else "unavailable"


def cpu_model() -> str:
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.lower().startswith(("model name", "cpu part")):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or "unknown"


def parse_scores(text: str) -> dict[str, float]:
    """Benchmark result lines only ('Name: 123'); the composite is excluded."""
    scores: dict[str, float] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("Score (") or "ERROR" in stripped:
            continue
        parts = stripped.split(": ")
        if len(parts) == 2 and parts[0].replace("-", "").isalnum():
            try:
                scores[parts[0]] = float(parts[1])
            except ValueError:
                continue
    return scores


def divisor_patch(iteration_divisor: int) -> str:
    return f"""
for (var __zjs_suite = 0; __zjs_suite < BenchmarkSuite.suites.length; __zjs_suite++) {{
  var __zjs_benchmarks = BenchmarkSuite.suites[__zjs_suite].benchmarks;
  for (var __zjs_bench = 0; __zjs_bench < __zjs_benchmarks.length; __zjs_bench++) {{
    var __zjs_item = __zjs_benchmarks[__zjs_bench];
    __zjs_item.deterministicIterations = Math.max(1, Math.ceil(__zjs_item.deterministicIterations / {iteration_divisor}));
    __zjs_item.minIterations = Math.max(1, Math.ceil(__zjs_item.minIterations / {iteration_divisor}));
  }}
}}"""


def build_script(bench: str, suite_dir: Path, iteration_divisor: int) -> tuple[str, list[dict]]:
    """Assemble base.js + the benchmark's files + the fixed-work runner.

    Returns the script text and the provenance list (path + sha256 per
    vendored file). Fails closed on an unknown benchmark or missing file.
    """
    if bench not in BENCH_FILES:
        fail(f"unknown benchmark {bench!r}; known: {', '.join(BENCH_FILES)}")
    provenance: list[dict] = []
    parts: list[str] = []
    for name in ["base.js", *BENCH_FILES[bench]]:
        path = suite_dir / name
        if not path.is_file():
            fail(f"vendored suite file not found: {path}")
        data = path.read_bytes()
        provenance.append({"file": name, "sha256": sha256_bytes(data)})
        parts.append(data.decode())
    parts.append(CONFIG_OVERRIDE)
    if iteration_divisor != 1:
        parts.append(divisor_patch(iteration_divisor))
    parts.append(RUNNER_FOOTER)
    return "\n".join(parts), provenance


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


def parse_time_rusage(text: str) -> dict[str, int]:
    fields: dict[str, int] = {}
    for token in text.strip().split():
        if "=" not in token:
            continue
        key, raw = token.split("=", 1)
        if key not in ("minflt", "maxrssKb"):
            continue
        try:
            fields[key] = int(raw)
        except ValueError:
            fail(f"invalid /usr/bin/time field: {token}", 1)
    missing = sorted({"minflt", "maxrssKb"} - fields.keys())
    if missing:
        fail(f"/usr/bin/time emitted no fields for: {', '.join(missing)}", 1)
    return fields


def validate_samples(samples: int) -> None:
    if samples < 2 or samples % 2 != 0:
        fail("--samples must be an even integer of at least 2 (paired ABBA balance)")


def run_one(
    binary: Path,
    script: Path,
    event_specs: list[str],
    event_names: list[str],
    timeout: int,
    time_rusage: bool = False,
) -> dict:
    with (
        tempfile.NamedTemporaryFile(prefix="benchv8-fixed-pmu-", suffix=".csv") as stat,
        tempfile.NamedTemporaryFile(prefix="benchv8-fixed-time-", suffix=".txt") as usage,
    ):
        engine_command = [str(binary), str(script)]
        if time_rusage:
            engine_command = [
                "/usr/bin/time",
                "-f",
                "minflt=%R maxrssKb=%M",
                "-o",
                usage.name,
                "--",
                *engine_command,
            ]
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
                *engine_command,
            ],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        elapsed = time.monotonic() - started
        counters = parse_perf_csv(Path(stat.name).read_text(), event_names)
        rusage = parse_time_rusage(Path(usage.name).read_text()) if time_rusage else None
    if proc.returncode != 0:
        fail(
            f"{binary.name} exited {proc.returncode} for {script.name}: "
            f"{proc.stderr.strip()[-400:]!r}",
            1,
        )
    if "ERROR" in proc.stdout:
        fail(f"{binary.name} reported a benchmark error for {script.name}: {proc.stdout.strip()[-400:]!r}", 1)
    scores = parse_scores(proc.stdout + proc.stderr)
    if not scores:
        fail(
            f"{binary.name} produced no parseable benchmark score for {script.name}",
            1,
        )
    result = {
        "counters": counters,
        "wallSeconds": elapsed,
        "stdout": proc.stdout.strip(),
        "scores": scores,
    }
    if rusage is not None:
        result["rusage"] = rusage
    return result


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
    ap.add_argument("--qjs", required=True, help="reference binary (pinned QuickJS, or a baseline zjs build for A/B screening)")
    ap.add_argument("--suite-dir", default=str(Path(__file__).resolve().parent / "suite"))
    ap.add_argument("--benches", nargs="*", default=None)
    ap.add_argument("--samples", type=int, default=4)
    ap.add_argument(
        "--time-rusage",
        action="store_true",
        help="collect paired minflt/maxrss with /usr/bin/time in the same arms",
    )
    ap.add_argument(
        "--field",
        choices=("a", "b", "host"),
        default=None,
        help="measurement field (default: ZJS_MEASURE_FIELD or b)",
    )
    ap.add_argument(
        "--cpu",
        type=int,
        default=None,
        help="compatibility override; field verdicts use the field's canonical single CPU",
    )
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

    try:
        measure_field, args.cpu, field_conforming = single_cpu(
            args.field, args.cpu
        )
    except ValueError as error:
        fail(str(error))

    validate_samples(args.samples)
    if args.iteration_divisor < 1:
        fail("--iteration-divisor must be at least 1")
    affinity = set(os.sched_getaffinity(0))
    if affinity != {args.cpu}:
        fail(
            f"effective affinity is {sorted(affinity)}, not exactly [{args.cpu}]; "
            "run through tools/perf/measure_fields.py or under an equivalent "
            "attested affinity and lock"
        )

    zjs = Path(args.zjs).resolve()
    qjs = Path(args.qjs).resolve()
    suite_dir = Path(args.suite_dir).resolve()
    for binary in (zjs, qjs):
        if not binary.is_file():
            fail(f"binary not found: {binary}")
    benches = args.benches or DEFAULT_BENCHES

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

    with tempfile.TemporaryDirectory(prefix="benchv8-fixed-work-") as tmp:
        tmp_dir = Path(tmp)
        for bench in benches:
            script_text, provenance = build_script(bench, suite_dir, args.iteration_divisor)
            script = tmp_dir / f"{bench}.js"
            script.write_text(script_text)

            runs: dict[str, list[dict]] = {"qjs": [], "zjs": []}
            for sample in range(args.samples):
                order = ["qjs", "zjs"] if sample % 2 == 0 else ["zjs", "qjs"]
                first_positions[order[0]] += 1
                order_log.append({"bench": bench, "sample": sample, "order": "->".join(order)})
                for engine in order:
                    binary = qjs if engine == "qjs" else zjs
                    run = run_one(
                        binary,
                        script,
                        event_specs,
                        event_names,
                        args.timeout,
                        args.time_rusage,
                    )
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
            if args.time_rusage:
                for metric in ("minflt", "maxrssKb"):
                    qjs_values = [run["rusage"][metric] for run in runs["qjs"]]
                    zjs_values = [run["rusage"][metric] for run in runs["zjs"]]
                    ratios = [
                        zjs_values[index] / qjs_values[index]
                        for index in range(args.samples)
                    ]
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
                    "suiteDir": str(suite_dir),
                    "files": provenance,
                    "fixedWorkSha256": sha256_bytes(script_text.encode()),
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
        "tool": "zjs-benchv8-fixed-pmu",
        "schemaVersion": 1,
        "direction": "ratios are zjs/qjs; below 1.0 means zjs used fewer counters or wall time",
        "workload": (
            "per-benchmark scripts assembled from the vendored suite with "
            "doWarmup=false and doDeterministic=true appended; both engines "
            "execute identical deterministicIterations/minIterations batches"
        ),
        "role": "screening instrument; score adjudication stays with run_benchv8_compare.py",
        "iterationDivisor": args.iteration_divisor,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "samplesPerEnginePerBench": args.samples,
        "samplingOrder": "paired ABBA by sample parity",
        "timeRusage": args.time_rusage,
        "firstPositionCounts": first_positions,
        "firstPositionBalanced": first_positions["qjs"] == first_positions["zjs"],
        "cpu": args.cpu,
        "effectiveAffinity": sorted(affinity),
        "measurementField": {
            **field_metadata(measure_field, "single"),
            "fieldConforming": field_conforming,
            "lockAttested": lock_attested(measure_field),
        },
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
