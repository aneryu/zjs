#!/usr/bin/env python3
"""Fast fail-first GC screen backed by frozen baseline artifacts.

This tool is deliberately a coarse screening instrument.  It always uses
measurement field A (CPU9), labels its minimum paired-ABBA PMU evidence as >=0.5%
resolution, and never grants a formal performance verdict.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path


PERF_DIR = Path(__file__).resolve().parent
REPO = PERF_DIR.parents[1]
BENCH_V8_DIR = PERF_DIR / "bench_v8"
sys.path.insert(0, str(PERF_DIR))
sys.path.insert(0, str(BENCH_V8_DIR))

import gc_stats_snapshot as gc_snapshot  # noqa: E402
import measure_fields  # noqa: E402
import run_fixed_pmu as fixed_pmu  # noqa: E402


GC_HEAVY_SIX = tuple(gc_snapshot.GC_HEAVY_SIX)
BUILD_CPUS = "0-4,10-14"
INSTRUCTION_STOP_LIMIT = 1.005
CYCLES_PENDING_LIMIT = 1.005
CYCLES_STOP_LIMIT = 1.020
DRIFT_PERCENT = 10.0
RESOLUTION = ">=0.5% (coarse; Stage 0 screening only)"
REQUIRED_BASELINE_FILES = (
    "zjs",
    "gc-stats.snapshot.json",
    "pmu.json",
    "identity.txt",
)

# R-B replay proved that major-triggered values can move between identical
# binaries because the GC budget is wall-clock based.  Only deterministic rows
# participate in STOP; phase-sensitive rows remain prominent diagnostics.
METRICS: tuple[tuple[str, str, str], ...] = (
    ("blockHeap.hotReusePublished", "hot reuse published", "phase-sensitive"),
    ("blockHeap.reopened", "reopened", "phase-sensitive"),
    ("blockHeap.deferredBlockRuns", "deferred block runs", "deterministic"),
    ("cycles.majorCompleted", "major collections", "phase-sensitive"),
    ("cycles.minor", "minor collections", "deterministic"),
    ("pauseNs.minor.total", "minor STW total", "phase-sensitive"),
    ("blockHeap.committed", "block committed", "phase-sensitive"),
    ("blockHeap.bitmapReclaimedCells", "bitmap reclaimed cells", "deterministic"),
)
CONTRACT_PATHS = {path for path, _, _ in METRICS}


class Stage0Error(RuntimeError):
    pass


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(
    command: list[str],
    *,
    cwd: Path = REPO,
    env: dict[str, str] | None = None,
    timeout: int | None = None,
    capture: bool = False,
) -> subprocess.CompletedProcess[str]:
    print("stage0: + " + " ".join(command), file=sys.stderr, flush=True)
    try:
        return subprocess.run(
            command,
            cwd=cwd,
            env=env,
            text=True,
            capture_output=capture,
            timeout=timeout,
            check=True,
        )
    except subprocess.TimeoutExpired as exc:
        raise Stage0Error(
            f"command timed out after {timeout}s: {' '.join(command)}"
        ) from exc
    except subprocess.CalledProcessError as exc:
        tail = ""
        if capture:
            tail = (exc.stdout + "\n" + exc.stderr).strip()[-1600:]
        raise Stage0Error(
            f"command exited {exc.returncode}: {' '.join(command)}"
            + (f"\n{tail}" if tail else "")
        ) from exc


def git_text(*args: str, cwd: Path = REPO) -> str:
    return run(["git", *args], cwd=cwd, capture=True, timeout=60).stdout.strip()


def config_signature(binary: Path, timeout: int) -> str:
    completed = run(
        ["taskset", "-c", "0", str(binary), "--print-config-signature"],
        capture=True,
        timeout=timeout,
    )
    value = completed.stdout.strip()
    if "optimize=ReleaseFast" not in value:
        raise Stage0Error(f"expected ReleaseFast binary, got config {value!r}")
    return value


def parse_identity(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise Stage0Error(f"cannot read {path}: {exc}") from exc
    for lineno, line in enumerate(lines, 1):
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise Stage0Error(f"invalid identity line {path}:{lineno}: {line!r}")
        key, value = line.split("=", 1)
        if not key or key in values:
            raise Stage0Error(f"duplicate/empty identity key at {path}:{lineno}")
        values[key] = value
    required = {"commit", "binary_sha256", "config_signature"}
    missing = sorted(required - values.keys())
    if missing:
        raise Stage0Error(f"identity is missing keys: {', '.join(missing)}")
    return values


def load_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise Stage0Error(f"cannot read JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise Stage0Error(f"JSON root is not an object: {path}")
    return value


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def validate_baseline(base: Path) -> tuple[Path, dict[str, str], dict, dict]:
    base = base.resolve()
    missing = [name for name in REQUIRED_BASELINE_FILES if not (base / name).is_file()]
    if missing:
        raise Stage0Error(
            f"baseline {base} is missing required files: {', '.join(missing)}"
        )
    binary = base / "zjs"
    identity = parse_identity(base / "identity.txt")
    actual_sha = sha256_of(binary)
    if identity["binary_sha256"] != actual_sha:
        raise Stage0Error(
            "baseline binary SHA-256 differs from identity.txt "
            f"({actual_sha} != {identity['binary_sha256']})"
        )
    snapshot = load_json(base / "gc-stats.snapshot.json")
    engine = snapshot.get("engine", {})
    if engine.get("sha256") != actual_sha:
        raise Stage0Error("baseline snapshot does not identify baseline zjs")
    if engine.get("configSignature") != identity["config_signature"]:
        raise Stage0Error("baseline snapshot config signature differs from identity.txt")
    pmu = load_json(base / "pmu.json")
    if pmu.get("samplesPerEnginePerBench") != 2 or pmu.get("firstPositionBalanced") is not True:
        raise Stage0Error("baseline PMU artifact is not the minimum paired ABBA freeze")
    frozen_field = pmu.get("measurementField", {})
    if frozen_field.get("name") != "a" or frozen_field.get("single_cpu") != 9:
        raise Stage0Error("baseline PMU artifact was not captured on field A / CPU9")
    binary_rows = pmu.get("binaries", {})
    if binary_rows.get("zjs", {}).get("sha256") != actual_sha:
        raise Stage0Error("baseline PMU artifact does not identify baseline zjs")
    if binary_rows.get("qjs", {}).get("sha256") != actual_sha:
        raise Stage0Error("baseline PMU artifact was not a frozen self-comparison")
    return binary, identity, snapshot, pmu


def capture_stats(binary: Path, output: Path, benches: tuple[str, ...], timeout: int) -> None:
    command = [
        "taskset",
        "-c",
        "9",
        sys.executable,
        str(PERF_DIR / "measure_fields.py"),
        "run",
        "--field",
        "a",
        "--layer",
        "single",
        "--",
        sys.executable,
        str(PERF_DIR / "gc_stats_snapshot.py"),
        "--zjs",
        str(binary),
        "--cpu",
        "9",
        "--allow-field-cpu",
        "--timeout",
        str(timeout),
        "--output",
        str(output),
        "--benches",
        *benches,
    ]
    run(command, timeout=timeout * len(benches) + 60)


def run_pmu(
    candidate: Path,
    baseline: Path,
    output: Path,
    benches: tuple[str, ...],
    timeout: int,
) -> None:
    launcher = [
        "taskset",
        "-c",
        "9",
        sys.executable,
        str(PERF_DIR / "measure_fields.py"),
        "run",
        "--field",
        "a",
        "--layer",
        "single",
        "--",
    ]
    command = [
        sys.executable,
        str(BENCH_V8_DIR / "run_fixed_pmu.py"),
        "--zjs",
        str(candidate),
        "--qjs",
        str(baseline),
        "--samples",
        "2",
        "--time-rusage",
        "--field",
        "a",
        "--timeout",
        str(timeout),
        "--output",
        str(output),
        "--benches",
        *benches,
    ]
    run(launcher + command, timeout=timeout * len(benches) * 4 + 120)


def snapshot_runs(snapshot: dict) -> dict[str, dict]:
    runs = snapshot.get("runs")
    if not isinstance(runs, list):
        raise Stage0Error("snapshot runs is not a list")
    indexed: dict[str, dict] = {}
    for row in runs:
        if not isinstance(row, dict) or not isinstance(row.get("benchmark"), str):
            raise Stage0Error("snapshot contains a malformed benchmark row")
        bench = row["benchmark"]
        if bench in indexed:
            raise Stage0Error(f"snapshot has duplicate benchmark {bench}")
        indexed[bench] = row
    return indexed


def value_at(root: dict, path: str) -> int:
    value: object = root
    for part in path.split("."):
        if not isinstance(value, dict) or part not in value:
            raise Stage0Error(f"GC snapshot is missing required metric {path}")
        value = value[part]
    if isinstance(value, bool) or not isinstance(value, int):
        raise Stage0Error(f"GC snapshot metric {path} is not an integer")
    return value


def baseline_value_at(root: dict, path: str) -> int:
    """`value_at` over a FROZEN baseline, following the schema's renames.

    A frozen baseline can never be re-emitted, so a renamed contract metric
    has to be read out of it under its old name.  Dropping the metric would
    silently retire a deterministic +-10% hard line; scoring it against 0
    would be worse, because the row would then cross on every screen.
    """
    old_path = gc_snapshot.SCHEMA_RENAMED_LEAVES.get(path)
    for candidate in (path,) if old_path is None else (path, old_path):
        try:
            return value_at(root, candidate)
        except Stage0Error:
            continue
    raise Stage0Error(f"GC snapshot is missing required metric {path}")


def ratio(after: int | float, before: int | float) -> float | None:
    if before == 0:
        return 1.0 if after == 0 else None
    return after / before


def drift_row(bench: str, path: str, before: int, after: int) -> dict:
    delta = after - before
    relative = None if before == 0 else delta * 100.0 / abs(before)
    crossed = delta != 0 if before == 0 else abs(relative) > DRIFT_PERCENT
    return {
        "benchmark": bench,
        "metric": path,
        "baseline": before,
        "candidate": after,
        "delta": delta,
        "relativePercent": relative,
        "direction": "increase" if delta > 0 else "decrease" if delta < 0 else "same",
        "crossed": crossed,
    }


def compare_stats(
    baseline: dict,
    candidate: dict,
    benches: tuple[str, ...],
) -> tuple[dict[str, dict], list[dict]]:
    if baseline.get("kind") != candidate.get("kind"):
        raise Stage0Error("GC snapshot kinds differ")
    try:
        baseline_version = gc_snapshot.schema_version(baseline)
        candidate_version = gc_snapshot.schema_version(candidate)
    except gc_snapshot.SnapshotError as exc:
        raise Stage0Error(str(exc)) from exc
    if candidate_version < baseline_version:
        raise Stage0Error(
            "candidate GC snapshot schemaVersion precedes the frozen baseline"
        )
    baseline_optional = gc_snapshot.baseline_optional_leaves(baseline_version)
    candidate_retired = gc_snapshot.candidate_retired_leaves(candidate_version)
    old_runs = snapshot_runs(baseline)
    new_runs = snapshot_runs(candidate)
    summary: dict[str, dict] = {}
    other_drifts: list[dict] = []
    for bench in benches:
        if bench not in old_runs or bench not in new_runs:
            raise Stage0Error(f"GC snapshot is missing selected benchmark {bench}")
        old_row = old_runs[bench]
        new_row = new_runs[bench]
        if old_row.get("fixedSourceSha256") != new_row.get("fixedSourceSha256"):
            raise Stage0Error(f"fixed GC workload source differs for {bench}")
        old_stats = old_row.get("stats")
        new_stats = new_row.get("stats")
        if not isinstance(old_stats, dict) or not isinstance(new_stats, dict):
            raise Stage0Error(f"GC snapshot stats row is malformed for {bench}")

        metrics: dict[str, dict] = {}
        for path, label, classification in METRICS:
            row = drift_row(
                bench,
                path,
                baseline_value_at(old_stats, path),
                value_at(new_stats, path),
            )
            row["label"] = label
            row["classification"] = classification
            metrics[label] = row

        new_leaves = gc_snapshot.numeric_leaves(new_stats)
        old_leaves = gc_snapshot.follow_renames(
            gc_snapshot.numeric_leaves(old_stats), new_leaves
        )
        # Losing a metric is a broken candidate and stays fatal.  Gaining one is
        # how instrumentation grows against a FROZEN baseline snapshot: the
        # baseline JSON can never be re-emitted, so a leaf the baseline's schema
        # version predates is scored against 0 and shows up as an annotated
        # drift row rather than aborting the screen.  A gained leaf that no
        # version entry accounts for is NOT that case -- it means the snapshot
        # schema forked without a version bump, which is what let the S2 string
        # kind and the S3 atom audit diverge silently -- so it is fatal and
        # names the table that has to be updated.
        # A leaf the candidate's schema version records as REMOVED is not a
        # dropped leaf: the row left `--gc-stats` on purpose, and the frozen
        # baseline's value has nothing left to be scored against.
        missing_in_candidate = sorted(
            old_leaves.keys() - new_leaves.keys() - candidate_retired
        )
        if missing_in_candidate:
            raise Stage0Error(
                f"GC stats schema differs for {bench}: candidate dropped "
                + ", ".join(missing_in_candidate)
            )
        unlisted = sorted(new_leaves.keys() - old_leaves.keys() - baseline_optional)
        if unlisted:
            raise Stage0Error(
                f"GC stats schema differs for {bench}: candidate added "
                + ", ".join(unlisted)
                + f" with no entry in gc_stats_snapshot.SCHEMA_ADDED_LEAVES above "
                f"baseline schemaVersion {baseline_version}"
            )
        for path in sorted(new_leaves):
            if path in CONTRACT_PATHS:
                continue
            baseline_missing = path not in old_leaves
            row = drift_row(bench, path, old_leaves.get(path, 0), new_leaves[path])
            row["baselineMissingLeaf"] = baseline_missing
            if baseline_missing:
                row["note"] = (
                    f"baseline snapshot has no such leaf at schemaVersion "
                    f"{baseline_version}; scored against 0"
                )
            if row["crossed"]:
                other_drifts.append(row)

        committed = metrics["block committed"]
        summary[bench] = {
            "metrics": metrics,
            "deterministicDrift": any(
                row["crossed"] and row["classification"] == "deterministic"
                for row in metrics.values()
            ),
            "phaseSensitiveDrift": any(
                row["crossed"] and row["classification"] == "phase-sensitive"
                for row in metrics.values()
            ),
            "committedRatio": ratio(committed["candidate"], committed["baseline"]),
        }
    return summary, other_drifts


def validate_pmu(
    artifact: dict,
    candidate: Path,
    baseline: Path,
    benches: tuple[str, ...],
) -> dict[str, dict]:
    if artifact.get("samplesPerEnginePerBench") != 2:
        raise Stage0Error("PMU artifact is not the required minimum paired ABBA screen")
    if artifact.get("firstPositionBalanced") is not True:
        raise Stage0Error("PMU artifact does not balance the paired ABBA order")
    field = artifact.get("measurementField", {})
    if (
        field.get("name") != "a"
        or field.get("single_cpu") != 9
        or field.get("fieldConforming") is not True
        or field.get("lockAttested") is not True
    ):
        raise Stage0Error("PMU artifact lacks an attested field-A/CPU9 placement")
    binaries = artifact.get("binaries", {})
    if binaries.get("zjs", {}).get("sha256") != sha256_of(candidate):
        raise Stage0Error("PMU candidate SHA-256 is wrong")
    if binaries.get("qjs", {}).get("sha256") != sha256_of(baseline):
        raise Stage0Error("PMU baseline SHA-256 is wrong")
    records = artifact.get("benchmarks")
    if not isinstance(records, dict) or set(records) != set(benches):
        raise Stage0Error("PMU benchmark set differs from the selected Stage 0 set")

    result: dict[str, dict] = {}
    for bench in benches:
        metrics = records[bench].get("metrics", {})
        row: dict[str, float] = {}
        for metric in ("instructions", "cycles", "minflt", "maxrssKb"):
            value = metrics.get(metric, {}).get("ratioMedian")
            if not isinstance(value, (int, float)):
                raise Stage0Error(f"PMU artifact lacks {bench} {metric} ratio")
            row[metric] = float(value)
        result[bench] = row
    return result


def normalize_perf_symbol(raw: str) -> str:
    value = raw.strip()
    if value.startswith("[.") or value.startswith("[k"):
        close = value.find("]")
        if close >= 0:
            value = value[close + 1 :].strip()
    return value


def parse_perf_report(text: str) -> dict[str, int]:
    samples: dict[str, int] = {}
    for line in text.splitlines():
        if not line or line.lstrip().startswith("#") or "|" not in line:
            continue
        raw_count, raw_symbol, *_ = line.split("|")
        raw_count = raw_count.strip().replace(",", "")
        if not raw_count.isdigit():
            continue
        symbol = normalize_perf_symbol(raw_symbol)
        if not symbol:
            continue
        samples[symbol] = samples.get(symbol, 0) + int(raw_count)
    if not samples:
        raise Stage0Error("perf report produced no parseable symbol samples")
    return samples


def symbol_delta(base: dict[str, int], candidate: dict[str, int], limit: int = 15) -> list[dict]:
    rows = [
        {
            "symbol": symbol,
            "baselineSamples": base.get(symbol, 0),
            "candidateSamples": candidate.get(symbol, 0),
            "deltaSamples": candidate.get(symbol, 0) - base.get(symbol, 0),
        }
        for symbol in base.keys() | candidate.keys()
    ]
    rows.sort(key=lambda row: (-row["deltaSamples"], row["symbol"]))
    return rows[:limit]


def profile_pinned(args: argparse.Namespace) -> int:
    if args.field != "a":
        raise Stage0Error("Stage 0 profiling supports only field A; CPU19 is forbidden")
    if set(os.sched_getaffinity(0)) != {9}:
        raise Stage0Error("Stage 0 profiling is not pinned exactly to CPU9")
    if not measure_fields.lock_attested(measure_fields.FIELDS["a"]):
        raise Stage0Error("Stage 0 profiling lacks the field-A lock attestation")

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    script_text, provenance = fixed_pmu.build_script(
        args.bench,
        BENCH_V8_DIR / "suite",
        1,
    )
    script = output / f"{args.bench}.fixed.js"
    script.write_text(script_text, encoding="utf-8")
    profiles: dict[str, dict] = {}
    for role, binary in (("baseline", args.baseline.resolve()), ("candidate", args.candidate.resolve())):
        data = output / f"{role}.perf.data"
        record = run(
            [
                "perf",
                "record",
                "-e",
                "armv8_pmuv3_1/cycles/u",
                "-F",
                "997",
                "-o",
                str(data),
                "--",
                str(binary),
                str(script),
            ],
            capture=True,
            timeout=args.timeout,
        )
        if "ERROR" in record.stdout:
            raise Stage0Error(f"{role} profile workload reported ERROR")
        report = run(
            [
                "perf",
                "report",
                "-i",
                str(data),
                "--stdio",
                "-n",
                "--sort",
                "symbol",
                "-F",
                "sample,symbol",
                "-t",
                "|",
                "--percent-limit",
                "0",
            ],
            capture=True,
            timeout=120,
        )
        report_path = output / f"{role}.perf-report.txt"
        report_path.write_text(report.stdout, encoding="utf-8")
        profiles[role] = {
            "binary": str(binary),
            "sha256": sha256_of(binary),
            "samples": parse_perf_report(report.stdout),
            "perfData": str(data),
            "perfReport": str(report_path),
        }
    artifact = {
        "tool": "zjs-stage0-symbol-diff",
        "benchmark": args.bench,
        "event": "armv8_pmuv3_1/cycles/u",
        "frequencyHz": 997,
        "field": "a",
        "cpu": 9,
        "fixedWorkFiles": provenance,
        "top15": symbol_delta(
            profiles["baseline"]["samples"],
            profiles["candidate"]["samples"],
        ),
        "profiles": profiles,
    }
    write_json(output / "symbol-diff.json", artifact)
    return 0


def run_profile(
    candidate: Path,
    baseline: Path,
    bench: str,
    output: Path,
    timeout: int,
) -> dict:
    command = [
        "taskset",
        "-c",
        "9",
        sys.executable,
        str(PERF_DIR / "measure_fields.py"),
        "run",
        "--field",
        "a",
        "--layer",
        "single",
        "--",
        sys.executable,
        str(Path(__file__).resolve()),
        "_profile",
        "--field",
        "a",
        "--candidate",
        str(candidate),
        "--baseline",
        str(baseline),
        "--bench",
        bench,
        "--output",
        str(output),
        "--timeout",
        str(timeout),
    ]
    run(command, timeout=timeout * 2 + 180)
    return load_json(output / "symbol-diff.json")


def worst_failure(
    pmu: dict[str, dict],
    stats: dict[str, dict],
    benches: tuple[str, ...],
) -> tuple[str, str, float] | None:
    # Performance violations choose the attribution workload when present.  A
    # lifecycle-only STOP falls back to the largest normalized policy drift.
    perf_failures: list[tuple[str, str, float]] = []
    for bench in benches:
        instructions = pmu[bench]["instructions"]
        if instructions > INSTRUCTION_STOP_LIMIT:
            perf_failures.append(
                (bench, "instructions", instructions / INSTRUCTION_STOP_LIMIT)
            )
        cycles = pmu[bench]["cycles"]
        if cycles > CYCLES_STOP_LIMIT:
            perf_failures.append((bench, "cycles", cycles / CYCLES_STOP_LIMIT))
    if perf_failures:
        return max(perf_failures, key=lambda row: row[2])

    metric_failures: list[tuple[str, str, float]] = []
    for bench in benches:
        for row in stats[bench]["metrics"].values():
            if not row["crossed"] or row["classification"] != "deterministic":
                continue
            relative = row["relativePercent"]
            severity = float("inf") if relative is None else abs(relative) / DRIFT_PERCENT
            metric_failures.append((bench, row["label"], severity))
    return max(metric_failures, key=lambda row: row[2]) if metric_failures else None


def cycles_disposition(value: float) -> str:
    if value > CYCLES_STOP_LIMIT:
        return "STOP"
    if value >= CYCLES_PENDING_LIMIT:
        return "待正式"
    return "ok"


def fmt_ratio(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.6f}"


def markdown_report(artifact: dict) -> str:
    lines = [
        "# Stage 0 GC fast screen",
        "",
        f"- Verdict: **{artifact['verdict']}**",
        f"- Resolution: `{artifact['resolution']}`",
        f"- Field: A / CPU9; CPU19 used: **no**",
        f"- Duration: {artifact['durationSeconds']:.1f}s",
        "",
        "| workload | insn C/B | cycles C/B | cycles status | minflt C/B | maxrss C/B | committed C/B | deterministic drift | phase-sensitive |",
        "|---|---:|---:|---|---:|---:|---:|---|---|",
    ]
    for bench, row in artifact["summary"].items():
        lines.append(
            f"| {bench} | {row['instructions']:.6f} | {row['cycles']:.6f} | "
            f"{row['cyclesStatus']} | {row['minflt']:.6f} | {row['maxrssKb']:.6f} | "
            f"{fmt_ratio(row['committed'])} | {'DRIFT' if row['deterministicDrift'] else 'ok'} | "
            f"{'moved' if row['phaseSensitiveDrift'] else 'stable'} |"
        )
    lines.extend(["", artifact["decisionLine"], ""])
    if artifact.get("configSignatureMismatch"):
        lines.extend([
            "Config signatures differ. This comparison was explicitly enabled with `--cross-layout`; both signatures remain in the identity section.",
            "",
        ])
    lines.append("## Fixed lifecycle metrics")
    lines.append("")
    for bench, row in artifact["gcStats"].items():
        for metric in row["metrics"].values():
            magnitude = (
                "n/a from zero baseline"
                if metric["relativePercent"] is None
                else f"{metric['relativePercent']:+.2f}%"
            )
            if not metric["crossed"]:
                status = "ok"
            elif metric["classification"] == "deterministic":
                status = "HARD DRIFT"
            else:
                status = ">10% diagnostic only"
            lines.append(
                f"- {bench} / {metric['label']} [{metric['classification']}]: "
                f"{metric['baseline']} -> {metric['candidate']} "
                f"({metric['direction']}, {magnitude}; "
                f"{status})"
            )
    lines.extend(["", "## Other >10% GC-stat drifts (diagnostic appendix)", ""])
    if artifact["otherGcDrifts"]:
        for row in artifact["otherGcDrifts"]:
            # A leaf the frozen baseline predates is scored against 0, so its
            # "drift" is an instrumentation fact, not a candidate regression.
            suffix = " (baseline has no such leaf)" if row.get("baselineMissingLeaf") else ""
            lines.append(
                f"- {row['benchmark']} / {row['metric']}: "
                f"{row['baseline']} -> {row['candidate']}{suffix}"
            )
    else:
        lines.append("None.")
    schema = artifact.get("gcStatsSchema")
    if schema:
        lines.extend(["", "## GC stats schema", ""])
        lines.append(
            f"- baseline schemaVersion {schema['baselineVersion']}, "
            f"candidate schemaVersion {schema['candidateVersion']}"
        )
        if schema["baselineMissingLeaves"]:
            lines.append(
                "- leaves absent from the baseline and scored against 0: "
                + ", ".join(schema["baselineMissingLeaves"])
            )
        else:
            lines.append("- every candidate leaf is present in the baseline")
    if artifact.get("symbolDiff"):
        lines.extend(["", "## STOP attribution: cycles:u symbol delta top 15", ""])
        lines.append("| delta samples | baseline | candidate | symbol |")
        lines.append("|---:|---:|---:|---|")
        for row in artifact["symbolDiff"]["top15"]:
            lines.append(
                f"| {row['deltaSamples']:+d} | {row['baselineSamples']} | "
                f"{row['candidateSamples']} | `{row['symbol']}` |"
            )
    lines.extend([
        "",
        "This PASS/STOP result is a fail-first screen, not the formal CPU19 performance verdict.",
        "",
    ])
    return "\n".join(lines)


def warm_build(timeout: int) -> Path:
    run(
        [
            "flock",
            "-x",
            measure_fields.HOST_LOCK,
            "taskset",
            "-c",
            BUILD_CPUS,
            "zig",
            "build",
            "zjs",
            "-Doptimize=ReleaseFast",
            "--summary",
            "all",
        ],
        timeout=timeout,
    )
    return REPO / "zig-out/bin/zjs"


def screen(args: argparse.Namespace) -> int:
    started = time.monotonic()
    if args.field != "a":
        raise Stage0Error("Stage 0 supports only --field a; CPU19 is forbidden")
    benches = tuple(args.benches or GC_HEAVY_SIX)
    unknown = sorted(set(benches) - set(GC_HEAVY_SIX))
    if unknown or not benches or len(set(benches)) != len(benches):
        raise Stage0Error(
            f"--benches must be a non-empty unique subset of {list(GC_HEAVY_SIX)}; unknown={unknown}"
        )

    baseline, identity, baseline_stats, _ = validate_baseline(args.base)
    candidate = args.candidate.resolve() if args.candidate else warm_build(args.build_timeout)
    if not candidate.is_file():
        raise Stage0Error(f"candidate binary not found: {candidate}")
    candidate_sha = sha256_of(candidate)
    candidate_config = config_signature(candidate, args.timeout)
    config_mismatch = candidate_config != identity["config_signature"]
    if config_mismatch and not args.cross_layout:
        raise Stage0Error(
            "candidate/base config signatures differ; rerun with --cross-layout "
            "only for an intentional representation/layout comparison"
        )

    output = (
        args.output.resolve()
        if args.output
        else REPO / ".scratch/stage0" / f"{utc_stamp()}-{os.getpid()}"
    )
    output.mkdir(parents=True, exist_ok=False)
    candidate_snapshot_path = output / "candidate.gc-stats.snapshot.json"
    pmu_path = output / "paired-pmu-time.json"
    capture_stats(candidate, candidate_snapshot_path, benches, args.timeout)
    candidate_stats = load_json(candidate_snapshot_path)
    gc_summary, other_drifts = compare_stats(baseline_stats, candidate_stats, benches)
    gc_stats_schema = {
        "baselineVersion": baseline_stats.get("schemaVersion"),
        "candidateVersion": candidate_stats.get("schemaVersion"),
        "baselineMissingLeaves": sorted(
            {row["metric"] for row in other_drifts if row.get("baselineMissingLeaf")}
        ),
    }

    run_pmu(candidate, baseline, pmu_path, benches, args.timeout)
    pmu_artifact = load_json(pmu_path)
    pmu_summary = validate_pmu(pmu_artifact, candidate, baseline, benches)
    failure = worst_failure(pmu_summary, gc_summary, benches)
    stop = failure is not None

    if failure is not None:
        worst_bench, worst_item, _ = failure
    else:
        worst_bench, worst_item = "", ""

    symbol_diff = None
    if stop:
        # If a PMU item failed, worst_failure selected that workload before any
        # lifecycle-only drift.  That keeps attribution tied to the performance
        # symptom while still reporting every structural STOP above.
        symbol_diff = run_profile(
            candidate,
            baseline,
            worst_bench,
            output / "symbol-profile",
            args.timeout,
        )

    duration = time.monotonic() - started
    summary = {
        bench: {
            "instructions": pmu_summary[bench]["instructions"],
            "cycles": pmu_summary[bench]["cycles"],
            "cyclesStatus": cycles_disposition(pmu_summary[bench]["cycles"]),
            "minflt": pmu_summary[bench]["minflt"],
            "maxrssKb": pmu_summary[bench]["maxrssKb"],
            "committed": gc_summary[bench]["committedRatio"],
            "deterministicDrift": gc_summary[bench]["deterministicDrift"],
            "phaseSensitiveDrift": gc_summary[bench]["phaseSensitiveDrift"],
        }
        for bench in benches
    }
    pending_cycles = [
        {"benchmark": bench, "ratio": pmu_summary[bench]["cycles"]}
        for bench in benches
        if cycles_disposition(pmu_summary[bench]["cycles"]) == "待正式"
    ]
    if stop:
        decision_line = f"STOP: {worst_bench} {worst_item}"
    elif pending_cycles:
        pending_text = ", ".join(
            f"{row['benchmark']}={row['ratio']:.6f}" for row in pending_cycles
        )
        decision_line = f"PASS -> Stage 1; cycles 待正式: {pending_text}"
    else:
        decision_line = "PASS -> Stage 1"
    artifact = {
        "tool": "zjs-stage0-screen",
        "schemaVersion": 1,
        "verdict": "STOP" if stop else "PASS",
        "decisionLine": decision_line,
        "role": "fail-first coarse screen; never a formal performance verdict",
        "resolution": RESOLUTION,
        "thresholds": {
            "instructionsStopAboveRatio": INSTRUCTION_STOP_LIMIT,
            "cyclesPendingFormalFromRatio": CYCLES_PENDING_LIMIT,
            "cyclesStopAboveRatio": CYCLES_STOP_LIMIT,
            "deterministicLifecycleAbsoluteRelativePercentMax": DRIFT_PERCENT,
            "phaseSensitiveLifecycleMetricsAreDiagnosticOnly": True,
        },
        "pendingFormalCycles": pending_cycles,
        "field": {"name": "a", "cpu": 9, "cpu19Used": False},
        "benches": list(benches),
        "durationSeconds": duration,
        "baseline": {
            "directory": str(args.base.resolve()),
            "binary": str(baseline),
            "commit": identity["commit"],
            "sha256": identity["binary_sha256"],
            "configSignature": identity["config_signature"],
        },
        "candidate": {
            "binary": str(candidate),
            "sha256": candidate_sha,
            "configSignature": candidate_config,
        },
        "configSignatureMismatch": config_mismatch,
        "crossLayout": args.cross_layout,
        "summary": summary,
        "gcStats": gc_summary,
        "otherGcDrifts": other_drifts,
        "gcStatsSchema": gc_stats_schema,
        "pmuArtifact": str(pmu_path),
        "candidateStatsArtifact": str(candidate_snapshot_path),
        "symbolDiff": symbol_diff,
    }
    write_json(output / "stage0.json", artifact)
    report = markdown_report(artifact)
    (output / "stage0.md").write_text(report, encoding="utf-8")
    print(report)
    print(f"stage0 artifacts: {output}")
    return 3 if stop else 0


def write_identity(
    path: Path,
    commit: str,
    binary: Path,
    config: str,
) -> None:
    text = "\n".join(
        [
            "# zjs Stage 0 frozen baseline identity v1",
            f"commit={commit}",
            f"binary_sha256={sha256_of(binary)}",
            f"config_signature={config}",
            f"frozen_utc={datetime.now(timezone.utc).isoformat()}",
            f"build_cpus={BUILD_CPUS}",
            "measurement_field=a",
            "measurement_cpu=9",
            "cpu19_used=false",
            "",
        ]
    )
    path.write_text(text, encoding="utf-8")


def freeze(args: argparse.Namespace) -> int:
    if args.field != "a":
        raise Stage0Error("Stage 0 freeze supports only --field a; CPU19 is forbidden")
    output = args.output.resolve()
    if output.exists():
        raise Stage0Error(f"refusing to overwrite existing baseline directory: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    commit = git_text("rev-parse", f"{args.commit}^{{commit}}")
    scratch = REPO / ".scratch"
    scratch.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="stage0-freeze-", dir=scratch) as tmp:
        temp_root = Path(tmp)
        source = temp_root / "source"
        prefix = temp_root / "prefix"
        local_cache = temp_root / "zig-local-cache"
        global_cache = temp_root / "zig-global-cache"
        artifact_dir = temp_root / "artifacts"
        artifact_dir.mkdir()
        added = False
        try:
            run(["git", "worktree", "add", "--detach", str(source), commit], timeout=120)
            added = True
            env = os.environ.copy()
            env.update(
                {
                    "ZIG_LOCAL_CACHE_DIR": str(local_cache),
                    "ZIG_GLOBAL_CACHE_DIR": str(global_cache),
                }
            )
            run(
                [
                    "flock",
                    "-x",
                    measure_fields.HOST_LOCK,
                    "taskset",
                    "-c",
                    BUILD_CPUS,
                    "zig",
                    "build",
                    "zjs",
                    "-Doptimize=ReleaseFast",
                    "--prefix",
                    str(prefix),
                    "--summary",
                    "all",
                ],
                cwd=source,
                env=env,
                timeout=args.build_timeout,
            )
            built = prefix / "bin/zjs"
            if not built.is_file():
                raise Stage0Error(f"cold build did not produce {built}")
            frozen_binary = artifact_dir / "zjs"
            shutil.copy2(built, frozen_binary)
            frozen_binary.chmod(frozen_binary.stat().st_mode | 0o111)
            config = config_signature(frozen_binary, args.timeout)
            capture_stats(
                frozen_binary,
                artifact_dir / "gc-stats.snapshot.json",
                GC_HEAVY_SIX,
                args.timeout,
            )
            run_pmu(
                frozen_binary,
                frozen_binary,
                artifact_dir / "pmu.json",
                GC_HEAVY_SIX,
                args.timeout,
            )
            write_identity(
                artifact_dir / "identity.txt",
                commit,
                frozen_binary,
                config,
            )
            os.replace(artifact_dir, output)
        finally:
            if added:
                run(
                    ["git", "worktree", "remove", "--force", str(source)],
                    timeout=120,
                )
    print(f"stage0 frozen baseline: {output}")
    return 0


def add_common_benches(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--benches",
        nargs="+",
        choices=GC_HEAVY_SIX,
        help="optional unique subset of the six GC-heavy fixed workloads",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    screen_parser = sub.add_parser("screen", help="compare a candidate with a frozen baseline")
    screen_parser.add_argument("--base", type=Path, required=True)
    screen_parser.add_argument("--candidate", type=Path)
    screen_parser.add_argument("--field", choices=("a",), default="a")
    screen_parser.add_argument(
        "--cross-layout",
        action="store_true",
        help="explicitly compare different config/layout signatures while retaining both identities",
    )
    screen_parser.add_argument("--output", type=Path)
    screen_parser.add_argument("--timeout", type=int, default=900)
    screen_parser.add_argument("--build-timeout", type=int, default=1800)
    add_common_benches(screen_parser)

    freeze_parser = sub.add_parser("freeze", help="cold-build and freeze one baseline commit")
    freeze_parser.add_argument("--commit", required=True)
    freeze_parser.add_argument("--out", dest="output", type=Path, required=True)
    freeze_parser.add_argument("--field", choices=("a",), default="a")
    freeze_parser.add_argument("--timeout", type=int, default=900)
    freeze_parser.add_argument("--build-timeout", type=int, default=1800)

    profile_parser = sub.add_parser("_profile", help=argparse.SUPPRESS)
    profile_parser.add_argument("--field", choices=("a",), required=True)
    profile_parser.add_argument("--candidate", type=Path, required=True)
    profile_parser.add_argument("--baseline", type=Path, required=True)
    profile_parser.add_argument("--bench", choices=GC_HEAVY_SIX, required=True)
    profile_parser.add_argument("--output", type=Path, required=True)
    profile_parser.add_argument("--timeout", type=int, default=900)
    return parser


def main() -> int:
    # Direct invocations get the same CPU19 exclusion as the mise task.  Every
    # child narrows this further to CPU0, CPU9, or the declared build pool.
    affinity = set(os.sched_getaffinity(0))
    if 19 in affinity and len(affinity) > 1:
        affinity.remove(19)
        os.sched_setaffinity(0, affinity)
    args = build_parser().parse_args()
    try:
        if args.command == "screen":
            return screen(args)
        if args.command == "freeze":
            return freeze(args)
        if args.command == "_profile":
            return profile_pinned(args)
        raise Stage0Error(f"unknown command {args.command}")
    except (OSError, Stage0Error, gc_snapshot.SnapshotError) as exc:
        print(f"stage0: error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
