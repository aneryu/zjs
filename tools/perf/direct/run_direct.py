#!/usr/bin/env python3

import argparse
import csv
import datetime as dt
import hashlib
import json
import math
import os
import platform
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path


EXPECTED_QJS_HEAD = "04be246001599f5995fa2f2d8c91a0f198d3f34c"
EXPECTED_QJS_VERSION = "2026-06-04"
PERF_EVENTS = (
    "instructions",
    "cycles",
    "branches",
    "branch-misses",
    "cache-references",
    "cache-misses",
)
PERF_FIELD_NAMES = {
    "instructions": "instructions",
    "cycles": "cycles",
    "branches": "branches",
    "branch-misses": "branch_misses",
    "cache-references": "cache_references",
    "cache-misses": "cache_misses",
}
STDIO_TEXT_LIMIT = 4000
CASE_DEFINITIONS = {
    "dtoa/mixed-free": {
        "category": "dtoa",
        "case": "mixed-free",
        "checksum_required": True,
    },
    "regexp/exec-latin1": {
        "category": "regexp",
        "case": "exec-latin1",
        "checksum_required": True,
    },
    "property_lookup/own-data": {
        "category": "property_lookup",
        "case": "own-data",
        "checksum_required": True,
    },
    "typed_array/int32-get": {
        "category": "typed_array",
        "case": "int32-get",
        "checksum_required": True,
        # QuickJS does not export its inline/static TypedArray element fast
        # path, so the qjs side necessarily measures JS_GetPropertyUint32
        # (boxing plus a class-id switch) while zjs measures
        # typedArrayGetIndex. This case is PERMANENTLY not source-comparable
        # by design. It still publishes both sides' numbers, but never a
        # headline ratio.
        #
        # Declaring it here is what keeps a *designed* incomparability from
        # being reported as a *failed measurement*: an undeclared incomparable
        # component still makes the collector exit non-zero (PRD 2.3), which
        # would abort the PRD 5.3 baseline command under `set -e` even though
        # nothing went wrong.
        "source_comparable_required": False,
        "incomparability_reason": (
            "public-api-proxy fidelity: QuickJS exports no counterpart to "
            "typedArrayGetIndex, so the two sides measure different layers"
        ),
    },
    "bigint/mul-multilimb": {
        "category": "bigint",
        "case": "mul-multilimb",
        "checksum_required": True,
    },
}
CASES = tuple(CASE_DEFINITIONS)
PROVENANCE_CHECK_NAMES = (
    "case_registered",
    "qjs_head_matches",
    "qjs_version_matches",
    "qjs_tree_clean_before",
    "qjs_tree_clean_after",
    "binary_sha256_known",
    "taskset_binding_succeeded",
    "sampling_abba_balanced",
    "samples_complete",
    "metadata_complete",
    "timing_complete",
    "pmu_binding_reliable",
)


def parse_args(repo: Path) -> argparse.Namespace:
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    default_output = (
        repo
        / ".zig-cache"
        / "perf"
        / "qjs-align"
        / "direct"
        / f"direct-{timestamp}.json"
    )
    parser = argparse.ArgumentParser(
        prog="run_direct.sh",
        description="Run ABBA-interleaved zjs/QuickJS direct-core benchmarks."
    )
    parser.add_argument("--output", type=Path, default=default_output)
    parser.add_argument("--cpu", type=int, default=19)
    parser.add_argument("--samples", type=positive_int, default=6)
    parser.add_argument(
        "--iterations", "--iters", dest="iterations", type=positive_int, default=100_000
    )
    parser.add_argument("--warmup", type=non_negative_int, default=5_000)
    parser.add_argument("--zjs", type=Path)
    parser.add_argument(
        "--qjs-dir",
        type=Path,
        default=Path(os.environ.get("QUICKJS_DIR", "/home/aneryu/quickjs")),
    )
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    parser.add_argument("--zig", default=os.environ.get("ZIG", "zig"))
    parser.add_argument(
        "--no-perf",
        action="store_true",
        help="Run pinned wall-time samples without perf; instructions are recorded unavailable.",
    )
    parser.add_argument(
        "--case",
        action="append",
        choices=CASES,
        dest="selected_cases",
        help="Run only this case; may be repeated. The default runs all five.",
    )
    return parser.parse_args()


def positive_int(text: str) -> int:
    value = int(text)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return value


def non_negative_int(text: str) -> int:
    value = int(text)
    if value < 0:
        raise argparse.ArgumentTypeError("must be non-negative")
    return value


def command(
    args: list[str],
    *,
    cwd: Path,
    check: bool = True,
    capture: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [str(arg) for arg in args],
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        check=False,
    )
    if check and result.returncode != 0:
        stdout = (result.stdout or "").strip()
        stderr = (result.stderr or "").strip()
        tail = "\n".join(part for part in (stdout[-2000:], stderr[-4000:]) if part)
        raise RuntimeError(
            f"command failed ({result.returncode}): {' '.join(map(str, args))}"
            + (f"\n{tail}" if tail else "")
        )
    return result


def first_line(args: list[str], cwd: Path) -> str:
    result = command(args, cwd=cwd)
    lines = (result.stdout or result.stderr or "").splitlines()
    return lines[0].strip() if lines else ""


def git_output(repo: Path, *args: str) -> str:
    return command(["git", "-C", str(repo), *args], cwd=repo).stdout.strip()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def build_harnesses(
    repo: Path, args: argparse.Namespace, cases: tuple[str, ...]
) -> tuple[Path, dict[str, Path], dict]:
    zjs_binary = args.zjs
    if zjs_binary is None:
        command(
            [
                args.zig,
                "build",
                "perf-direct-build",
                "--seed",
                "0",
                "--summary",
                "all",
            ],
            cwd=repo,
            capture=False,
        )
        zjs_binary = repo / "zig-out" / "bin" / "zjs-direct-bench"
    elif not zjs_binary.is_absolute():
        zjs_binary = (repo / zjs_binary).resolve()
    if not zjs_binary.is_file():
        raise RuntimeError(f"zjs direct harness not found: {zjs_binary}")

    qjs_dir = args.qjs_dir.resolve()
    qjs_binary = (
        repo
        / ".zig-cache"
        / "perf"
        / "qjs-align"
        / "direct"
        / "bin"
        / "qjs-direct-bench"
    )
    qjs_binary.parent.mkdir(parents=True, exist_ok=True)
    qjs_binaries: dict[str, Path] = {}
    compile_info = {
        "archive_harness": {
            "status": "skipped (case not selected)",
            "seconds": None,
            "command": None,
        },
        "included_quickjs_bigint_harness": {
            "status": "skipped (case not selected)",
            "seconds": None,
            "command": None,
        },
        "total_seconds": 0.0,
    }

    if any(case_id != "bigint/mul-multilimb" for case_id in cases):
        qjs_source = repo / "tools" / "perf" / "direct" / "qjs_direct_bench.c"
        qjs_archive = qjs_dir / "libquickjs.a"
        if not qjs_archive.is_file():
            raise RuntimeError(f"pinned QuickJS archive not found: {qjs_archive}")
        archive_compile_command = [
            args.cc,
            "-O3",
            "-DNDEBUG",
            "-std=c11",
            f"-I{qjs_dir}",
            str(qjs_source),
            str(qjs_archive),
            "-lm",
            "-lpthread",
            "-ldl",
            "-o",
            str(qjs_binary),
        ]
        archive_compile_start = time.perf_counter()
        command(archive_compile_command, cwd=repo)
        archive_compile_seconds = time.perf_counter() - archive_compile_start
        qjs_binaries["default"] = qjs_binary.resolve()
        compile_info["archive_harness"] = {
            "status": "built",
            "seconds": archive_compile_seconds,
            "command": [str(part) for part in archive_compile_command],
        }
        compile_info["total_seconds"] += archive_compile_seconds

    qjs_bigint_binary = qjs_binary.with_name("qjs-bigint-direct-bench")
    if "bigint/mul-multilimb" in cases:
        qjs_bigint_source = (
            repo / "tools" / "perf" / "direct" / "qjs_bigint_direct_bench.c"
        )
        source_units = [
            qjs_dir / "dtoa.c",
            qjs_dir / "libregexp.c",
            qjs_dir / "libunicode.c",
            qjs_dir / "cutils.c",
        ]
        bigint_compile_command = [
            args.cc,
            "-O3",
            "-DNDEBUG",
            "-std=gnu11",
            "-fwrapv",
            "-D_GNU_SOURCE",
            f"-I{qjs_dir}",
            str(qjs_bigint_source),
            *(str(path) for path in source_units),
            "-lm",
            "-lpthread",
            "-ldl",
            "-o",
            str(qjs_bigint_binary),
        ]
        bigint_compile_start = time.perf_counter()
        command(bigint_compile_command, cwd=repo)
        bigint_compile_seconds = time.perf_counter() - bigint_compile_start
        qjs_binaries["bigint/mul-multilimb"] = qjs_bigint_binary.resolve()
        compile_info["included_quickjs_bigint_harness"] = {
            "status": "built",
            "seconds": bigint_compile_seconds,
            "command": [str(part) for part in bigint_compile_command],
        }
        compile_info["total_seconds"] += bigint_compile_seconds

    return zjs_binary.resolve(), qjs_binaries, compile_info


def parse_json_record(stdout: str, expected_engine: str, case_id: str) -> dict:
    lines = [line.strip() for line in stdout.splitlines() if line.strip()]
    if len(lines) != 1:
        raise RuntimeError(
            f"{expected_engine} {case_id} emitted {len(lines)} non-empty stdout lines"
        )
    try:
        record = json.loads(lines[0])
    except json.JSONDecodeError as error:
        raise RuntimeError(
            f"{expected_engine} {case_id} emitted invalid JSON: {lines[0]}"
        ) from error
    category, case_name = case_id.split("/", 1)
    expected = {
        "engine": expected_engine,
        "category": category,
        "case": case_name,
    }
    for key, value in expected.items():
        if record.get(key) != value:
            raise RuntimeError(
                f"{expected_engine} {case_id} record has {key}={record.get(key)!r}, "
                f"expected {value!r}"
            )
    return record


def parse_perf_number(text: str) -> int | float | None:
    normalized = text.strip().replace(" ", "")
    if not normalized:
        return None
    try:
        return int(normalized)
    except ValueError:
        try:
            return float(normalized)
        except ValueError:
            return None


def perf_event_matches(event: str, requested: str) -> bool:
    return event == requested or event.endswith(f"/{requested}/")


def unavailable_perf_events(reason: str) -> dict:
    return {
        event: {
            "status": "unavailable",
            "value": None,
            "event": None,
            "counter_runtime_ns": None,
            "run_percent": None,
            "reason": reason,
            "counted_candidates": [],
            "unavailable_candidates": [],
        }
        for event in PERF_EVENTS
    }


def parse_perf_events(
    perf_csv: str, expected_pmu_name: str | None = None
) -> dict:
    rows = [row for row in csv.reader(perf_csv.splitlines()) if len(row) >= 3]
    parsed: dict[str, dict] = {}
    for requested in PERF_EVENTS:
        candidates: list[dict] = []
        unavailable_rows: list[dict] = []
        for row in rows:
            event = row[2].strip()
            if not perf_event_matches(event, requested):
                continue
            raw_value = row[0].strip()
            candidate = {
                "event": event,
                "counter_runtime_ns": (
                    parse_perf_number(row[3]) if len(row) > 3 else None
                ),
                "run_percent": (
                    parse_perf_number(row[4]) if len(row) > 4 else None
                ),
            }
            if (
                not raw_value
                or "<not counted>" in raw_value
                or "<not supported>" in raw_value
            ):
                candidate["raw_value"] = raw_value or None
                unavailable_rows.append(candidate)
                continue
            value = parse_perf_number(raw_value)
            if value is None:
                candidate["raw_value"] = raw_value
                unavailable_rows.append(candidate)
                continue
            candidate["value"] = value
            candidates.append(candidate)

        if candidates:
            selected = next(
                (
                    candidate
                    for candidate in candidates
                    if expected_pmu_name is not None
                    and candidate["event"].startswith(
                        f"{expected_pmu_name}/"
                    )
                ),
                candidates[0],
            )
            parsed[requested] = {
                "status": "counted",
                **selected,
                "selection": (
                    f"selected explicitly discovered PMU {expected_pmu_name}"
                    if expected_pmu_name is not None
                    and selected["event"].startswith(
                        f"{expected_pmu_name}/"
                    )
                    else "first counted matching PMU row; PMU provenance unverified"
                ),
                "counted_candidates": candidates,
                "unavailable_candidates": unavailable_rows,
            }
        else:
            parsed[requested] = {
                "status": "unavailable",
                "value": None,
                "event": None,
                "counter_runtime_ns": None,
                "run_percent": None,
                "reason": (
                    "matching perf rows were not counted or not supported"
                    if unavailable_rows
                    else "no matching event row in perf stat CSV"
                ),
                "counted_candidates": [],
                "unavailable_candidates": unavailable_rows,
            }
    return parsed


def placeholder_record(engine: str, case_id: str) -> dict:
    category, case_name = case_id.split("/", 1)
    return {
        "engine": engine,
        "category": category,
        "case": case_name,
        "iterations": None,
        "warmup": None,
        "ns_total": None,
        "ns_per_op": None,
        "checksum": None,
        "fidelity": "unavailable",
        "entry": None,
        "comparable": False,
        "checksum_comparable": False,
        "caliber_note": "stdout record unavailable",
    }


def is_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def normalize_memory_observations(record: dict) -> None:
    memory_reason = record.get("allocations_reason")
    if not isinstance(memory_reason, str) or not memory_reason:
        memory_reason = "harness did not report runtime allocation counters"
    for output_name, input_name, reason_name in (
        ("allocations", "allocation_count", "allocation_count_reason"),
        ("allocated_bytes", "allocated_bytes", "allocated_bytes_reason"),
    ):
        observation_reason = record.get(reason_name)
        if not isinstance(observation_reason, str) or not observation_reason:
            observation_reason = memory_reason
        before = record.get(f"{input_name}_before")
        after = record.get(f"{input_name}_after")
        if is_number(before) and is_number(after):
            record[output_name] = {
                "before": before,
                "after": after,
                "delta": after - before,
                "reason": None,
            }
        else:
            record[output_name] = {
                "before": before if is_number(before) else None,
                "after": after if is_number(after) else None,
                "delta": None,
                "reason": observation_reason,
            }

    peak_rss = record.get("peak_rss_kb")
    if not is_number(peak_rss):
        record["peak_rss_kb"] = None
        if not record.get("peak_rss_reason"):
            record["peak_rss_reason"] = (
                "harness did not report /proc/self/status VmHWM"
            )


def run_invocation(
    *,
    repo: Path,
    binary: Path,
    engine: str,
    case_id: str,
    iterations: int,
    warmup: int,
    args: argparse.Namespace,
    perf_available: bool,
    phase: str,
) -> dict:
    bench_args = [str(binary), case_id, str(iterations), str(warmup)]
    perf_attempted = perf_available and not args.no_perf
    perf_events = unavailable_perf_events(
        "disabled by --no-perf"
        if args.no_perf
        else "perf executable unavailable"
    )
    perf_csv = ""
    perf_wrapper: dict | None = None
    exit_code_source = "taskset propagated direct harness exit status"

    if perf_attempted:
        expected_pmu_name = getattr(args, "expected_pmu_name", None)
        requested_perf_events = (
            [
                f"{expected_pmu_name}/{event}/"
                for event in PERF_EVENTS
            ]
            if expected_pmu_name is not None
            else list(PERF_EVENTS)
        )
        with tempfile.TemporaryDirectory(prefix="zjs-direct-perf-") as temp_dir:
            perf_output = Path(temp_dir) / "perf-stat.csv"
            perf_command = [
                "taskset",
                "-c",
                str(args.cpu),
                "perf",
                "stat",
                "-x,",
                "-o",
                str(perf_output),
                "-e",
                ",".join(requested_perf_events),
                "--",
                *bench_args,
            ]
            perf_result = command(perf_command, cwd=repo, check=False)
            try:
                perf_csv = perf_output.read_text()
            except OSError:
                perf_csv = ""
        perf_events = parse_perf_events(perf_csv, expected_pmu_name)
        any_counted = any(
            event["value"] is not None for event in perf_events.values()
        )
        perf_failed_before_output = (
            perf_result.returncode != 0
            and not perf_result.stdout.strip()
            and not any_counted
        )
        if perf_failed_before_output:
            perf_wrapper = {
                "exit_code": perf_result.returncode,
                "stderr_bytes": len(perf_result.stderr.encode()),
                "stderr_text": perf_result.stderr[:STDIO_TEXT_LIMIT],
                "reason": "perf stat failed before producing harness output",
            }
            perf_events = unavailable_perf_events(
                f"perf stat failed before harness run (exit {perf_result.returncode})"
            )
            direct_command = ["taskset", "-c", str(args.cpu), *bench_args]
            result = command(direct_command, cwd=repo, check=False)
        else:
            result = perf_result
            exit_code_source = (
                "perf stat/taskset propagated harness exit status"
            )
    else:
        direct_command = ["taskset", "-c", str(args.cpu), *bench_args]
        result = command(direct_command, cwd=repo, check=False)

    stdout = result.stdout or ""
    stderr = result.stderr or ""
    stdout_json_valid = False
    stdout_validation_error: str | None = None
    try:
        record = parse_json_record(stdout, engine, case_id)
        stdout_json_valid = True
    except RuntimeError as error:
        record = placeholder_record(engine, case_id)
        stdout_validation_error = str(error)

    loop_counts_valid = (
        stdout_json_valid
        and record.get("iterations") == iterations
        and record.get("warmup") == warmup
    )
    invalid_reasons: list[str] = []
    if result.returncode != 0:
        invalid_reasons.append(f"harness exit code {result.returncode}")
    if stderr:
        invalid_reasons.append(f"harness stderr non-empty ({len(stderr.encode())} bytes)")
    if not stdout_json_valid:
        invalid_reasons.append(
            stdout_validation_error or "stdout JSON validation failed"
        )
    elif not loop_counts_valid:
        invalid_reasons.append(
            "harness did not echo requested iterations and warmup"
        )

    record["requested_iterations"] = iterations
    record["requested_warmup"] = warmup
    record["phase"] = phase
    record["exit_code"] = result.returncode
    record["exit_code_source"] = exit_code_source
    record["stdout_bytes"] = len(stdout.encode())
    record["stdout_text"] = stdout[:STDIO_TEXT_LIMIT]
    record["stdout_truncated"] = len(stdout) > STDIO_TEXT_LIMIT
    record["stdout_json_valid"] = stdout_json_valid
    record["stdout_validation_error"] = stdout_validation_error
    record["loop_counts_valid"] = loop_counts_valid
    record["stderr_bytes"] = len(stderr.encode())
    record["stderr_text"] = stderr[:STDIO_TEXT_LIMIT]
    record["stderr_truncated"] = len(stderr) > STDIO_TEXT_LIMIT
    record["stderr_clean"] = not stderr
    record["perf_attempted"] = perf_attempted
    record["perf_csv_bytes"] = len(perf_csv.encode())
    record["perf_events"] = perf_events
    record["perf_wrapper_failure"] = perf_wrapper
    record["invalid_reasons"] = invalid_reasons
    record["valid"] = not invalid_reasons
    normalize_memory_observations(record)
    return record


def run_direct_process(
    *,
    repo: Path,
    binary: Path,
    engine: str,
    case_id: str,
    args: argparse.Namespace,
    perf_available: bool,
) -> dict:
    record = run_invocation(
        repo=repo,
        binary=binary,
        engine=engine,
        case_id=case_id,
        iterations=args.iterations,
        warmup=args.warmup,
        args=args,
        perf_available=perf_available,
        phase="main",
    )
    main_valid = record["valid"]
    baseline = run_invocation(
        repo=repo,
        binary=binary,
        engine=engine,
        case_id=case_id,
        iterations=1,
        warmup=args.warmup,
        args=args,
        perf_available=perf_available,
        phase="baseline",
    )

    record["main_invocation_valid"] = main_valid
    record["baseline"] = baseline
    record["valid"] = main_valid and baseline["valid"]
    if not baseline["valid"]:
        record["invalid_reasons"] = [
            *record["invalid_reasons"],
            *(
                f"baseline: {reason}"
                for reason in baseline["invalid_reasons"]
            ),
        ]

    counter_metrics: dict[str, dict] = {}
    for event in PERF_EVENTS:
        main_event = record["perf_events"][event]
        baseline_event = baseline["perf_events"][event]
        main_value = main_event["value"]
        baseline_value = baseline_event["value"]
        process_per_op = (
            main_value / args.iterations
            if is_number(main_value)
            else None
        )
        loop_only_per_op: float | None = None
        loop_only_reason: str | None = None
        if args.iterations == 1:
            loop_only_reason = (
                "iterations is 1; baseline subtraction denominator N-1 is zero"
            )
        elif not is_number(main_value):
            loop_only_reason = (
                main_event.get("reason") or "main perf count unavailable"
            )
        elif not is_number(baseline_value):
            loop_only_reason = (
                baseline_event.get("reason")
                or "baseline perf count unavailable"
            )
        else:
            raw_delta = main_value - baseline_value
            if raw_delta < 0:
                loop_only_reason = (
                    "below_baseline_resolution: "
                    f"main={main_value} baseline={baseline_value} "
                    f"delta={raw_delta} is negative; baseline-subtracted "
                    "derived value is unavailable and was not clamped"
                )
            else:
                loop_only_per_op = raw_delta / (args.iterations - 1)
        counter_metrics[event] = {
            "main_raw": main_value if is_number(main_value) else None,
            "baseline_raw": (
                baseline_value if is_number(baseline_value) else None
            ),
            "iterations": args.iterations,
            "baseline_iterations": 1,
            "process_scope_per_op": process_per_op,
            "loop_only_per_op": loop_only_per_op,
            "loop_only_reason": loop_only_reason,
        }
    record["performance_counters"] = counter_metrics

    instruction_main = record["perf_events"]["instructions"]
    instruction_baseline = baseline["perf_events"]["instructions"]
    record["instructions"] = instruction_main["value"]
    record["instructions_event"] = instruction_main["event"]
    record["instructions_status"] = instruction_main["status"]
    record["instructions_process_scope_per_op"] = counter_metrics[
        "instructions"
    ]["process_scope_per_op"]
    record["loop_only_instructions_per_op"] = counter_metrics[
        "instructions"
    ]["loop_only_per_op"]
    record["instructions_baseline"] = instruction_baseline["value"]
    return record


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def stats(values: list[float]) -> dict | None:
    if not values:
        return None
    return {
        "samples": len(values),
        "median": statistics.median(values),
        "p25": percentile(values, 0.25),
        "p75": percentile(values, 0.75),
        "min": min(values),
        "max": max(values),
    }


def counter_scope_summary(
    samples: list[dict],
    event: str,
    value_key: str,
    scope: str,
) -> dict:
    zjs_values: list[float] = []
    qjs_values: list[float] = []
    ratios: list[float] = []
    reasons: list[str] = []
    for sample in samples:
        zjs_record = sample["engines"]["zjs"]
        qjs_record = sample["engines"]["qjs"]
        zjs_value = zjs_record["performance_counters"][event][value_key]
        qjs_value = qjs_record["performance_counters"][event][value_key]
        if is_number(zjs_value):
            zjs_values.append(float(zjs_value))
        else:
            reason = (
                zjs_record["performance_counters"][event].get(
                    "loop_only_reason"
                )
                if value_key == "loop_only_per_op"
                else zjs_record["perf_events"][event].get("reason")
            )
            if reason:
                reasons.append(f"zjs: {reason}")
        if is_number(qjs_value):
            qjs_values.append(float(qjs_value))
        else:
            reason = (
                qjs_record["performance_counters"][event].get(
                    "loop_only_reason"
                )
                if value_key == "loop_only_per_op"
                else qjs_record["perf_events"][event].get("reason")
            )
            if reason:
                reasons.append(f"qjs: {reason}")
        if is_number(zjs_value) and is_number(qjs_value) and qjs_value != 0:
            ratios.append(float(zjs_value) / float(qjs_value))

    status = (
        "counted"
        if len(ratios) == len(samples)
        else "partial"
        if zjs_values or qjs_values
        else "unavailable"
    )
    return {
        "scope": scope,
        "status": status,
        "zjs_per_op": stats(zjs_values),
        "qjs_per_op": stats(qjs_values),
        "paired_ratio_zjs_over_qjs": stats(ratios),
        "reason": "; ".join(dict.fromkeys(reasons)) if reasons else None,
    }


def counter_summary(samples: list[dict], event: str) -> dict:
    process_scope = counter_scope_summary(
        samples,
        event,
        "process_scope_per_op",
        "whole process incl. setup and warmup",
    )
    loop_only = counter_scope_summary(
        samples,
        event,
        "loop_only_per_op",
        "marginal per-iteration, baseline-subtracted",
    )
    return {
        "status": loop_only["status"],
        "reason": loop_only["reason"],
        "process_scope": process_scope,
        "loop_only": loop_only,
    }


def wall_time_summary(samples: list[dict]) -> dict:
    zjs_values: list[float] = []
    qjs_values: list[float] = []
    ratios: list[float] = []
    for sample in samples:
        zjs_value = sample["engines"]["zjs"].get("ns_per_op")
        qjs_value = sample["engines"]["qjs"].get("ns_per_op")
        if is_number(zjs_value):
            zjs_values.append(float(zjs_value))
        if is_number(qjs_value):
            qjs_values.append(float(qjs_value))
        if is_number(zjs_value) and is_number(qjs_value) and qjs_value != 0:
            ratios.append(float(zjs_value) / float(qjs_value))
    return {
        "scope": "harness-internal timed kernel loop only",
        "zjs": stats(zjs_values),
        "qjs": stats(qjs_values),
        "paired_ratio_zjs_over_qjs": stats(ratios),
    }


def memory_delta_summary(samples: list[dict], field: str, scope: str) -> dict:
    output: dict = {"scope": scope}
    reasons: list[str] = []
    complete = True
    for engine in ("zjs", "qjs"):
        before_values: list[float] = []
        after_values: list[float] = []
        delta_values: list[float] = []
        for sample in samples:
            observation = sample["engines"][engine][field]
            before = observation["before"]
            after = observation["after"]
            delta = observation["delta"]
            if is_number(before):
                before_values.append(float(before))
            if is_number(after):
                after_values.append(float(after))
            if is_number(delta):
                delta_values.append(float(delta))
            else:
                complete = False
                if observation.get("reason"):
                    reasons.append(f"{engine}: {observation['reason']}")
        output[engine] = {
            "before": stats(before_values),
            "after": stats(after_values),
            "delta": stats(delta_values),
        }
    output["status"] = (
        "counted"
        if complete
        else "partial"
        if any(
            output[engine]["delta"] is not None for engine in ("zjs", "qjs")
        )
        else "unavailable"
    )
    output["reason"] = (
        "; ".join(dict.fromkeys(reasons)) if reasons else None
    )
    return output


def peak_rss_summary(samples: list[dict]) -> dict:
    output: dict = {
        "scope": "harness process VmHWM from /proc/self/status, excludes perf/taskset",
    }
    reasons: list[str] = []
    complete = True
    for engine in ("zjs", "qjs"):
        values: list[float] = []
        for sample in samples:
            record = sample["engines"][engine]
            value = record.get("peak_rss_kb")
            if is_number(value):
                values.append(float(value))
            else:
                complete = False
                if record.get("peak_rss_reason"):
                    reasons.append(f"{engine}: {record['peak_rss_reason']}")
        output[engine] = stats(values)
    output["status"] = (
        "counted"
        if complete
        else "partial"
        if output["zjs"] or output["qjs"]
        else "unavailable"
    )
    output["reason"] = (
        "; ".join(dict.fromkeys(reasons)) if reasons else None
    )
    return output


def invocation_failures(case_id: str, samples: list[dict]) -> list[str]:
    failures: list[str] = []
    for sample in samples:
        sample_number = sample["sample"]
        for engine in ("zjs", "qjs"):
            record = sample["engines"][engine]
            invocations = [("main", record)]
            baseline = record.get("baseline")
            if isinstance(baseline, dict) and "exit_code" in baseline:
                invocations.append(("baseline", baseline))
            for phase, invocation in invocations:
                label = f"{engine} sample {sample_number} {phase}"
                if invocation["exit_code"] != 0:
                    failures.append(
                        f"harness exit code {invocation['exit_code']} on {label}"
                    )
                if not invocation["stderr_clean"]:
                    failures.append(
                        f"harness stderr non-empty on {label} "
                        f"({invocation['stderr_bytes']} bytes)"
                    )
                if not invocation["stdout_json_valid"]:
                    detail = (
                        invocation.get("stdout_validation_error")
                        or "stdout JSON validation failed"
                    )
                    failures.append(f"{detail} on {label}")
                elif not invocation["loop_counts_valid"]:
                    failures.append(
                        f"loop-count echo mismatch on {label}"
                    )
    return failures


def component_result(reasons: list[str], **metadata: object) -> dict:
    comparable = len(reasons) == 0
    return {
        "comparable": bool(comparable),
        "reason": None
        if comparable
        else "; ".join(dict.fromkeys(reasons)),
        **metadata,
    }


def source_comparability(
    case_id: str, samples: list[dict], provenance: dict
) -> dict:
    reasons: list[str] = []
    definition = CASE_DEFINITIONS.get(case_id)
    if definition is None:
        reasons.append(
            f"case id {case_id!r} is not registered in CASE_DEFINITIONS"
        )
        category, case_name = case_id.split("/", 1)
    else:
        category = definition["category"]
        case_name = definition["case"]

    requested_iterations = provenance.get("requested_iterations")
    requested_warmup = provenance.get("requested_warmup")
    if (
        not isinstance(requested_iterations, int)
        or isinstance(requested_iterations, bool)
        or requested_iterations <= 0
    ):
        reasons.append(
            "requested iterations metadata was not checked or is missing"
        )
    if (
        not isinstance(requested_warmup, int)
        or isinstance(requested_warmup, bool)
        or requested_warmup < 0
    ):
        reasons.append(
            "requested warmup metadata was not checked or is missing"
        )
    if not samples:
        reasons.append("no matched zjs/QuickJS samples were collected")

    for sample_index, sample in enumerate(samples, 1):
        engines = sample.get("engines")
        if not isinstance(engines, dict):
            reasons.append(f"sample {sample_index} engine records are missing")
            continue
        for engine in ("zjs", "qjs"):
            record = engines.get(engine)
            if not isinstance(record, dict):
                reasons.append(
                    f"sample {sample_index} {engine} record is missing"
                )
                continue
            if record.get("comparable") is not True:
                reasons.append(
                    f"sample {sample_index} {engine} harness comparable "
                    "was not explicitly true"
                )
            if (
                record.get("category") != category
                or record.get("case") != case_name
            ):
                reasons.append(
                    f"sample {sample_index} {engine} category/case does not "
                    f"match canonical {case_id}"
                )
            if (
                record.get("iterations") != requested_iterations
                or record.get("warmup") != requested_warmup
                or record.get("loop_counts_valid") is not True
            ):
                reasons.append(
                    f"sample {sample_index} {engine} main "
                    "iterations/warmup echo was not explicitly validated"
                )
            baseline = record.get("baseline")
            if not isinstance(baseline, dict) or "exit_code" not in baseline:
                reasons.append(
                    f"sample {sample_index} {engine} baseline invocation "
                    "is missing or unchecked"
                )
                continue
            if baseline.get("comparable") is not True:
                reasons.append(
                    f"sample {sample_index} {engine} baseline harness "
                    "comparable was not explicitly true"
                )
            if (
                baseline.get("category") != category
                or baseline.get("case") != case_name
            ):
                reasons.append(
                    f"sample {sample_index} {engine} baseline category/case "
                    f"does not match canonical {case_id}"
                )
            if (
                baseline.get("iterations") != 1
                or baseline.get("warmup") != requested_warmup
                or baseline.get("loop_counts_valid") is not True
            ):
                reasons.append(
                    f"sample {sample_index} {engine} baseline "
                    "iterations/warmup echo was not explicitly validated"
                )

    return component_result(
        reasons,
        case_registered=bool(definition is not None),
        canonical_category=category,
        canonical_case=case_name,
    )


def nonempty_checksum(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def checksum_comparability(case_id: str, samples: list[dict]) -> dict:
    definition = CASE_DEFINITIONS.get(case_id)
    requirement_declared = (
        definition is not None
        and isinstance(definition.get("checksum_required"), bool)
    )
    checksum_required = (
        definition["checksum_required"]
        if requirement_declared
        else True
    )
    reasons: list[str] = []
    main_values: list[str] = []
    baseline_values: list[str] = []

    invocation_pairs: list[tuple[str, dict | None, dict | None]] = []
    for sample_index, sample in enumerate(samples, 1):
        engines = sample.get("engines")
        zjs = engines.get("zjs") if isinstance(engines, dict) else None
        qjs = engines.get("qjs") if isinstance(engines, dict) else None
        invocation_pairs.append((f"sample {sample_index} main", zjs, qjs))
        zjs_baseline = (
            zjs.get("baseline") if isinstance(zjs, dict) else None
        )
        qjs_baseline = (
            qjs.get("baseline") if isinstance(qjs, dict) else None
        )
        invocation_pairs.append(
            (
                f"sample {sample_index} baseline",
                zjs_baseline,
                qjs_baseline,
            )
        )

    checksum_evidence_present = any(
        isinstance(record, dict)
        and (
            record.get("checksum_comparable") is True
            or nonempty_checksum(record.get("checksum"))
        )
        for _label, zjs, qjs in invocation_pairs
        for record in (zjs, qjs)
    )
    strict_validation_required = (
        checksum_required or checksum_evidence_present
    )

    if not samples and strict_validation_required:
        reasons.append("no checksum samples were collected")

    if strict_validation_required:
        for label, zjs, qjs in invocation_pairs:
            if not isinstance(zjs, dict) or not isinstance(qjs, dict):
                reasons.append(f"{label} checksum invocation is missing")
                continue
            for engine, record in (("zjs", zjs), ("qjs", qjs)):
                if record.get("checksum_comparable") is not True:
                    reasons.append(
                        f"{label} {engine} checksum_comparable was not "
                        "explicitly true"
                    )
                if not nonempty_checksum(record.get("checksum")):
                    reasons.append(
                        f"{label} {engine} checksum is missing or empty"
                    )
            zjs_checksum = zjs.get("checksum")
            qjs_checksum = qjs.get("checksum")
            if (
                nonempty_checksum(zjs_checksum)
                and nonempty_checksum(qjs_checksum)
            ):
                if zjs_checksum != qjs_checksum:
                    reasons.append(
                        f"{label} cross-engine checksum mismatch "
                        f"(zjs={zjs_checksum} qjs={qjs_checksum})"
                    )
                elif label.endswith("main"):
                    main_values.append(zjs_checksum)
                else:
                    baseline_values.append(zjs_checksum)

        for sample_index, sample in enumerate(samples, 1):
            if sample.get("checksums_match") is not True:
                reasons.append(
                    f"sample {sample_index} main checksum comparison was "
                    "not explicitly true"
                )
            if sample.get("baseline_checksums_match") is not True:
                reasons.append(
                    f"sample {sample_index} baseline checksum comparison "
                    "was not explicitly true"
                )
        if main_values and len(set(main_values)) != 1:
            reasons.append(
                "main checksum changed across nominally identical samples"
            )
        if baseline_values and len(set(baseline_values)) != 1:
            reasons.append(
                "baseline checksum changed across nominally identical samples"
            )

    main_checksums_match: bool | None = (
        len(main_values) == len(samples) and len(set(main_values)) == 1
        if strict_validation_required and samples
        else None
    )
    baseline_checksums_match: bool | None = (
        len(baseline_values) == len(samples)
        and len(set(baseline_values)) == 1
        if strict_validation_required and samples
        else None
    )
    return component_result(
        reasons,
        required=bool(checksum_required),
        checksum_requirement_declared=bool(requirement_declared),
        validation_mode=(
            "required"
            if checksum_required
            else "optional evidence validated"
            if checksum_evidence_present
            else "explicitly not required"
        ),
        main_checksums_match=main_checksums_match,
        baseline_checksums_match=baseline_checksums_match,
    )


def metric_comparability(
    samples: list[dict],
    provenance: dict,
    validation_failures: list[str],
    instructions: dict,
) -> dict:
    reasons: list[str] = []
    if provenance.get("perf_requested") is not True:
        reasons.append(
            "primary loop-only instructions metric was not collected "
            "because perf was explicitly disabled by --no-perf"
        )
    if validation_failures:
        reasons.append(
            "harness validation failed: " + validation_failures[0]
        )

    loop_only = instructions.get("loop_only")
    ratio = (
        loop_only.get("paired_ratio_zjs_over_qjs")
        if isinstance(loop_only, dict)
        else None
    )
    if not isinstance(loop_only, dict) or loop_only.get("status") != "counted":
        reason = (
            loop_only.get("reason")
            if isinstance(loop_only, dict)
            else None
        )
        reasons.append(
            "loop-only instructions paired ratio is incomplete"
            + (f": {reason}" if reason else "")
        )
    if not isinstance(ratio, dict):
        reasons.append(
            "loop-only instructions paired ratio statistics are missing"
        )
    else:
        if ratio.get("samples") != len(samples):
            reasons.append(
                "loop-only instructions paired ratio sample count is "
                f"{ratio.get('samples')!r}, expected {len(samples)}"
            )
        for field in ("median", "p25", "p75", "min", "max"):
            value = ratio.get(field)
            if not is_number(value) or not math.isfinite(float(value)):
                reasons.append(
                    "loop-only instructions paired ratio has missing or "
                    f"invalid {field}"
                )

    return component_result(
        reasons,
        primary_metric="instructions_loop_only",
        perf_requested=bool(provenance.get("perf_requested") is True),
    )


def provenance_comparability(provenance: dict) -> dict:
    reasons: list[str] = []
    checks: dict[str, dict] = {}
    for name in PROVENANCE_CHECK_NAMES:
        raw_value = provenance.get(name)
        passed = raw_value is True
        supplied_reason = provenance.get(f"{name}_reason")
        if passed:
            reason = None
        elif isinstance(supplied_reason, str) and supplied_reason:
            reason = supplied_reason
        elif name not in provenance or raw_value is None:
            reason = f"{name} was not checked or is missing"
        elif not isinstance(raw_value, bool):
            reason = f"{name} is not an explicit boolean"
        else:
            reason = f"{name} check failed"
        checks[name] = {
            "passed": bool(passed),
            "reason": reason,
        }
        if not passed:
            reasons.append(f"{name}: {reason}")
    return component_result(reasons, checks=checks)


def summarize_case(
    case_id: str, samples: list[dict], provenance: dict
) -> dict:
    zjs_records = [sample["engines"]["zjs"] for sample in samples]
    qjs_records = [sample["engines"]["qjs"] for sample in samples]
    zjs_first = zjs_records[0]
    qjs_first = qjs_records[0]
    validation_failures = invocation_failures(case_id, samples)

    wall = wall_time_summary(samples)
    counters = {
        PERF_FIELD_NAMES[event]: counter_summary(samples, event)
        for event in PERF_EVENTS
    }
    instructions = counters["instructions"]
    instruction_ratio = instructions["loop_only"][
        "paired_ratio_zjs_over_qjs"
    ]
    wall_ratio = wall["paired_ratio_zjs_over_qjs"]

    source_component = source_comparability(
        case_id, samples, provenance
    )
    checksum_component = checksum_comparability(case_id, samples)
    metric_component = metric_comparability(
        samples,
        provenance,
        validation_failures,
        instructions,
    )
    provenance_component = provenance_comparability(provenance)
    components = {
        "source": source_component,
        "checksum": checksum_component,
        "metric": metric_component,
        "provenance": provenance_component,
    }
    comparable = all(
        component["comparable"] is True
        for component in components.values()
    )
    false_component_reasons = [
        f"{name}_comparable: {component['reason'] or 'false'}"
        for name, component in components.items()
        if component["comparable"] is not True
    ]
    headline_reason = (
        "; ".join(false_component_reasons)
        if false_component_reasons
        else None
    )
    headline = instruction_ratio if comparable else None
    if headline is None and headline_reason is None:
        headline_reason = (
            "metric_comparable: loop-only instructions unavailable"
        )

    direction_conflict = False
    direction_detail: dict | None = None
    if isinstance(instruction_ratio, dict) and isinstance(wall_ratio, dict):
        instruction_median = instruction_ratio["median"]
        wall_median = wall_ratio["median"]
        if is_number(instruction_median) and is_number(wall_median):
            direction_conflict = (
                (instruction_median - 1.0)
                * (wall_median - 1.0)
                < 0
                and abs(instruction_median - 1.0) > 0.02
                and abs(wall_median - 1.0) > 0.02
            )
        if direction_conflict:
            direction_detail = {
                "instructions_ratio": instruction_median,
                "wall_ratio": wall_median,
                "checksum_comparable": bool(
                    checksum_component["comparable"]
                ),
                "comparable": bool(comparable),
                "note": (
                    "opposite directions beyond 2%; this usually indicates "
                    "IPC or stall differences and needs manual attribution "
                    "with cycles and cache-misses"
                ),
            }

    pair_fidelity = (
        "true-direct"
        if zjs_first.get("fidelity") == qjs_first.get("fidelity") == "true-direct"
        else "unavailable"
        if "unavailable"
        in (zjs_first.get("fidelity"), qjs_first.get("fidelity"))
        else "public-api-proxy"
    )
    category, case_name = case_id.split("/", 1)
    summary = {
        "category": category,
        "case": case_name,
        "zjs_entry": zjs_first.get("entry"),
        "qjs_entry": qjs_first.get("entry"),
        "zjs_fidelity": zjs_first.get("fidelity"),
        "qjs_fidelity": qjs_first.get("fidelity"),
        "fidelity": pair_fidelity,
        "comparable": bool(comparable),
        "comparability": {
            "formula": (
                "source_comparable && checksum_comparable && "
                "metric_comparable && provenance_comparable"
            ),
            **components,
        },
        "source_comparable": bool(source_component["comparable"]),
        "source_comparable_reason": source_component["reason"],
        "checksum_comparable": bool(checksum_component["comparable"]),
        "checksum_comparable_reason": checksum_component["reason"],
        "metric_comparable": bool(metric_component["comparable"]),
        "metric_comparable_reason": metric_component["reason"],
        "provenance_comparable": bool(
            provenance_component["comparable"]
        ),
        "provenance_comparable_reason": provenance_component["reason"],
        "caliber_note": {
            "zjs": zjs_first.get("caliber_note"),
            "qjs": qjs_first.get("caliber_note"),
        },
        "validation": {
            "valid": not validation_failures,
            "failures": validation_failures,
        },
        "checksum_requirement_declared": checksum_component[
            "checksum_requirement_declared"
        ],
        "checksum_required": checksum_component["required"],
        "checksums_match": checksum_component["main_checksums_match"],
        "baseline_checksums_match": checksum_component[
            "baseline_checksums_match"
        ],
        "checksum": (
            zjs_first.get("checksum")
            if checksum_component["main_checksums_match"] is True
            else None
        ),
        "wall_time_ns_per_op": wall,
        **counters,
        "allocations": memory_delta_summary(
            samples,
            "allocations",
            "live runtime allocation-count before/after delta across timed loop",
        ),
        "allocated_bytes": memory_delta_summary(
            samples,
            "allocated_bytes",
            "live runtime allocated-byte before/after delta across timed loop",
        ),
        "peak_rss_kb": peak_rss_summary(samples),
        "primary_metric": "instructions_loop_only",
        "headline_ratio_zjs_over_qjs": headline,
        "headline_excluded_reason": (
            None if headline is not None else headline_reason
        ),
        "direction_conflict": direction_conflict,
        "direction_conflict_detail": direction_detail,
    }
    return summary


def cpu_inventory() -> tuple[list[str], dict[str, str]]:
    models: list[str] = []
    by_id: dict[str, str] = {}
    try:
        result = subprocess.run(
            ["lscpu", "-e=CPU,MODELNAME"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if result.returncode == 0:
            for line in result.stdout.splitlines()[1:]:
                fields = line.split(maxsplit=1)
                if len(fields) != 2 or not fields[0].isdigit():
                    continue
                model = fields[1].strip()
                if not model:
                    continue
                by_id[fields[0]] = model
                if model not in models:
                    models.append(model)
    except OSError:
        pass

    if models:
        return models, by_id
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.lower().startswith("model name") and ":" in line:
                model = line.split(":", 1)[1].strip()
                if model and model not in models:
                    models.append(model)
    except OSError:
        pass
    return models, by_id


def iter_invocations(raw_samples: dict[str, list[dict]]):
    for case_id, samples in raw_samples.items():
        for sample in samples:
            for engine in sample["order"]:
                record = sample["engines"][engine]
                yield case_id, sample["sample"], engine, "main", record
                baseline = record.get("baseline")
                if isinstance(baseline, dict) and "exit_code" in baseline:
                    yield (
                        case_id,
                        sample["sample"],
                        engine,
                        "baseline",
                        baseline,
                    )


def validation_metadata(raw_samples: dict[str, list[dict]]) -> dict:
    invocations = list(iter_invocations(raw_samples))
    total = len(invocations)
    nonzero = [
        (
            f"{engine} {case_id} sample {sample} {phase} "
            f"-> {record['exit_code']}"
        )
        for case_id, sample, engine, phase, record in invocations
        if record["exit_code"] != 0
    ]
    stderr_failures = [
        (
            f"{engine} {case_id} sample {sample} {phase} "
            f"-> {record['stderr_bytes']} bytes"
        )
        for case_id, sample, engine, phase, record in invocations
        if not record["stderr_clean"]
    ]
    stdout_failures = [
        (
            f"{engine} {case_id} sample {sample} {phase} "
            f"-> {record.get('stdout_validation_error') or 'invalid JSON'}"
        )
        for case_id, sample, engine, phase, record in invocations
        if not record["stdout_json_valid"]
    ]
    loop_failures = [
        f"{engine} {case_id} sample {sample} {phase}"
        for case_id, sample, engine, phase, record in invocations
        if not record["loop_counts_valid"]
    ]
    return {
        "exit_code_validation": (
            f"all {total} invocations exited 0"
            if not nonzero
            else f"{len(nonzero)} of {total} exited nonzero: "
            + "; ".join(nonzero)
        ),
        "stderr_validation": (
            f"all {total} invocations had empty harness stderr"
            if not stderr_failures
            else f"{len(stderr_failures)} of {total} emitted harness stderr: "
            + "; ".join(stderr_failures)
        ),
        "stdout_validation": (
            f"all {total} invocations emitted one schema-valid JSON record"
            if not stdout_failures
            else f"{len(stdout_failures)} of {total} had invalid stdout: "
            + "; ".join(stdout_failures)
        ),
        "loop_count_validation": (
            f"all {total} invocations echoed requested loop counts"
            if not loop_failures
            else f"{len(loop_failures)} of {total} had loop-count mismatch: "
            + "; ".join(loop_failures)
        ),
    }


def zjs_representation_metadata(raw_samples: dict[str, list[dict]]) -> dict:
    sizes = {
        record.get("jsvalue_size_bytes")
        for case_id, sample, engine, phase, record in iter_invocations(raw_samples)
        if engine == "zjs"
        and phase == "main"
        and is_number(record.get("jsvalue_size_bytes"))
    }
    if len(sizes) == 1:
        size = int(next(iter(sizes)))
        label = (
            "16-byte payload plus tag"
            if size == 16
            else "8-byte NaN-boxed"
            if size == 8
            else "unrecognized layout size"
        )
        return {
            "size_bytes": size,
            "label": label,
            "source": "measured by zjs harness @sizeOf(core.JSValue)",
            "reason": None,
        }
    return {
        "size_bytes": None,
        "label": None,
        "source": None,
        "reason": (
            "zjs harness did not report JSValue size"
            if not sizes
            else f"inconsistent observed JSValue sizes: {sorted(sizes)}"
        ),
    }


def compile_display(info: dict) -> str:
    if info["status"] == "built":
        return f"{info['seconds']:.3f}s"
    return info["status"]


def print_summary(output: Path, summaries: list[dict], compile_info: dict) -> None:
    print(f"direct benchmark artifact: {output}")
    print(
        "QuickJS C harness compile: "
        f"archive={compile_display(compile_info['archive_harness'])}, "
        "included-quickjs.c BigInt="
        f"{compile_display(compile_info['included_quickjs_bigint_harness'])}"
    )
    for summary in summaries:
        wall = summary["wall_time_ns_per_op"]
        zjs_ns = wall["zjs"]["median"] if wall["zjs"] else None
        qjs_ns = wall["qjs"]["median"] if wall["qjs"] else None
        wall_text = (
            f"ns/op zjs={zjs_ns:.3f} qjs={qjs_ns:.3f}"
            if zjs_ns is not None and qjs_ns is not None
            else "wall time unavailable"
        )
        loop_only = summary["instructions"]["loop_only"]
        process_scope = summary["instructions"]["process_scope"]
        if loop_only["zjs_per_op"] and loop_only["qjs_per_op"]:
            metric = (
                "loop-only insn/op "
                f"zjs={loop_only['zjs_per_op']['median']:.3f} "
                f"qjs={loop_only['qjs_per_op']['median']:.3f}"
            )
        else:
            metric = "loop-only instructions unavailable"
        if process_scope["zjs_per_op"] and process_scope["qjs_per_op"]:
            metric += (
                "; process-scope insn/op "
                f"zjs={process_scope['zjs_per_op']['median']:.3f} "
                f"qjs={process_scope['qjs_per_op']['median']:.3f}"
            )
        headline = summary["headline_ratio_zjs_over_qjs"]
        ratio = (
            f"headline {summary['primary_metric']} zjs/qjs="
            f"{headline['median']:.4f} "
            f"[{headline['p25']:.4f}, {headline['p75']:.4f}]"
            if headline
            else "headline excluded: "
            f"{summary['headline_excluded_reason']}"
        )
        print(
            f"{summary['category']}/{summary['case']}: "
            f"{wall_text}; {metric}; {ratio}"
        )
        if summary["direction_conflict"]:
            detail = summary["direction_conflict_detail"]
            print(
                "  WARNING direction conflict: "
                f"instructions={detail['instructions_ratio']:.4f}, "
                f"wall={detail['wall_ratio']:.4f}; "
                "inspect cycles/cache-misses for IPC or stalls"
            )


def optional_binary_metadata(
    binary: Path | None, skipped_reason: str
) -> tuple[str | None, str | None, str | None]:
    if binary is None:
        return None, None, skipped_reason
    return str(binary), sha256(binary), None


def parse_cpu_set(text: str) -> set[int]:
    cpus: set[int] = set()
    for part in text.strip().split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            lower_text, upper_text = part.split("-", 1)
            lower = int(lower_text)
            upper = int(upper_text)
            cpus.update(range(lower, upper + 1))
        else:
            cpus.add(int(part))
    return cpus


def discover_pmu_for_cpu(cpu: int) -> dict:
    candidates: list[dict] = []
    root = Path("/sys/bus/event_source/devices")
    for device in sorted(root.glob("armv8_pmuv3_*")):
        cpus_path = device / "cpus"
        try:
            cpus_text = cpus_path.read_text().strip()
            cpus = parse_cpu_set(cpus_text)
        except (OSError, ValueError) as error:
            candidates.append(
                {
                    "name": device.name,
                    "cpus": None,
                    "reason": f"could not read {cpus_path}: {error}",
                }
            )
            continue
        candidates.append(
            {
                "name": device.name,
                "cpus": sorted(cpus),
                "reason": None,
            }
        )
    matches = [
        candidate
        for candidate in candidates
        if isinstance(candidate["cpus"], list)
        and cpu in candidate["cpus"]
    ]
    if len(matches) == 1:
        return {
            "passed": True,
            "name": matches[0]["name"],
            "cpu": cpu,
            "candidates": candidates,
            "reason": None,
        }
    return {
        "passed": False,
        "name": None,
        "cpu": cpu,
        "candidates": candidates,
        "reason": (
            f"CPU {cpu} maps to {len(matches)} armv8 PMU devices; "
            "exactly one is required"
        ),
    }


def verify_taskset_binding(repo: Path, cpu: int) -> dict:
    probe = (
        "import json, os; "
        "print(json.dumps(sorted(os.sched_getaffinity(0))))"
    )
    result = command(
        ["taskset", "-c", str(cpu), sys.executable, "-c", probe],
        cwd=repo,
        check=False,
    )
    observed: list[int] | None = None
    parse_error: str | None = None
    try:
        parsed = json.loads(result.stdout.strip())
        if (
            isinstance(parsed, list)
            and all(
                isinstance(item, int) and not isinstance(item, bool)
                for item in parsed
            )
        ):
            observed = parsed
        else:
            parse_error = "affinity probe did not emit an integer list"
    except json.JSONDecodeError as error:
        parse_error = f"affinity probe emitted invalid JSON: {error}"
    passed = (
        result.returncode == 0
        and observed == [cpu]
        and not result.stderr
    )
    reasons: list[str] = []
    if result.returncode != 0:
        reasons.append(f"taskset probe exited {result.returncode}")
    if observed != [cpu]:
        reasons.append(
            f"observed affinity is {observed!r}, expected [{cpu}]"
        )
    if result.stderr:
        reasons.append(
            f"taskset probe stderr was non-empty ({len(result.stderr.encode())} bytes)"
        )
    if parse_error:
        reasons.append(parse_error)
    return {
        "passed": bool(passed),
        "requested_cpu": cpu,
        "observed_affinity": observed,
        "exit_code": result.returncode,
        "stderr": result.stderr,
        "reason": None if passed else "; ".join(reasons),
    }


def sha256_is_known(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def pmu_binding_reliability(
    raw_samples: list[dict],
    *,
    perf_requested: bool,
    perf_available: bool,
    expected_pmu_name: str | None,
) -> tuple[bool, str | None]:
    if not perf_requested:
        return True, None
    if not perf_available:
        return False, "perf was requested but the executable is unavailable"
    if expected_pmu_name is None:
        return (
            False,
            "perf was requested but CPU-to-PMU discovery did not identify "
            "one PMU",
        )

    reasons: list[str] = []
    for case_id, sample_number, engine, phase, record in iter_invocations(
        {"case": raw_samples}
    ):
        label = f"{engine} sample {sample_number} {phase}"
        if record.get("perf_attempted") is not True:
            reasons.append(f"{label} did not attempt requested PMU collection")
            continue
        perf_events = record.get("perf_events")
        if not isinstance(perf_events, dict):
            reasons.append(f"{label} PMU event metadata is missing")
            continue
        instruction = perf_events.get("instructions")
        if (
            not isinstance(instruction, dict)
            or not is_number(instruction.get("value"))
        ):
            reasons.append(f"{label} instructions counter was not counted")
        for event in PERF_EVENTS:
            observation = perf_events.get(event)
            if not isinstance(observation, dict):
                reasons.append(f"{label} {event} metadata is missing")
                continue
            if not is_number(observation.get("value")):
                continue
            selected_event = observation.get("event")
            if (
                not isinstance(selected_event, str)
                or not selected_event.startswith(f"{expected_pmu_name}/")
            ):
                reasons.append(
                    f"{label} {event} selected {selected_event!r}, not "
                    f"{expected_pmu_name}"
                )
            counted_candidates = observation.get("counted_candidates")
            if (
                not isinstance(counted_candidates, list)
                or len(counted_candidates) != 1
            ):
                reasons.append(
                    f"{label} {event} had "
                    f"{len(counted_candidates) if isinstance(counted_candidates, list) else 'unknown'} "
                    "counted PMU candidates; exactly one is required"
                )
    return (
        len(reasons) == 0,
        None if not reasons else "; ".join(dict.fromkeys(reasons)),
    )


def case_provenance_context(
    *,
    case_id: str,
    samples: list[dict],
    args: argparse.Namespace,
    qjs_head: str,
    qjs_version: str,
    qjs_status_before: str,
    qjs_status_after: str,
    binary_hashes: list[str | None],
    taskset_probe: dict,
    perf_available: bool,
    pmu_probe: dict,
) -> dict:
    expected_orders = [
        ["qjs", "zjs"] if index % 2 == 0 else ["zjs", "qjs"]
        for index in range(args.samples)
    ]
    observed_orders = [
        sample.get("order") if isinstance(sample, dict) else None
        for sample in samples
    ]
    first_position_counts = {"qjs": 0, "zjs": 0}
    for order in observed_orders:
        if isinstance(order, list) and order and order[0] in first_position_counts:
            first_position_counts[order[0]] += 1
    samples_complete = (
        len(samples) == args.samples
        and all(
            isinstance(sample.get("engines"), dict)
            and set(sample["engines"]) == {"zjs", "qjs"}
            for sample in samples
        )
    )
    sampling_balanced = (
        observed_orders == expected_orders
        and first_position_counts["qjs"]
        == first_position_counts["zjs"]
    )

    metadata_reasons: list[str] = []
    timing_reasons: list[str] = []
    for sample_index, sample in enumerate(samples, 1):
        for engine in ("zjs", "qjs"):
            record = sample.get("engines", {}).get(engine)
            if not isinstance(record, dict):
                metadata_reasons.append(
                    f"sample {sample_index} {engine} record is missing"
                )
                continue
            if (
                record.get("requested_iterations") != args.iterations
                or record.get("requested_warmup") != args.warmup
            ):
                metadata_reasons.append(
                    f"sample {sample_index} {engine} requested loop metadata "
                    "is incomplete"
                )
            baseline = record.get("baseline")
            if (
                not isinstance(baseline, dict)
                or baseline.get("requested_iterations") != 1
                or baseline.get("requested_warmup") != args.warmup
            ):
                metadata_reasons.append(
                    f"sample {sample_index} {engine} baseline loop metadata "
                    "is incomplete"
                )
            for phase, invocation in (("main", record), ("baseline", baseline)):
                if not isinstance(invocation, dict):
                    timing_reasons.append(
                        f"sample {sample_index} {engine} {phase} invocation "
                        "is missing"
                    )
                    continue
                if (
                    not is_number(invocation.get("ns_total"))
                    or invocation.get("ns_total") < 0
                    or not is_number(invocation.get("ns_per_op"))
                    or invocation.get("ns_per_op") < 0
                ):
                    timing_reasons.append(
                        f"sample {sample_index} {engine} {phase} timing "
                        "is missing or invalid"
                    )

    pmu_reliable, pmu_reason = pmu_binding_reliability(
        samples,
        perf_requested=not args.no_perf,
        perf_available=perf_available,
        expected_pmu_name=pmu_probe.get("name"),
    )
    context = {
        "requested_iterations": args.iterations,
        "requested_warmup": args.warmup,
        "perf_requested": bool(not args.no_perf),
        "case_registered": case_id in CASE_DEFINITIONS,
        "qjs_head_matches": qjs_head == EXPECTED_QJS_HEAD,
        "qjs_version_matches": qjs_version == EXPECTED_QJS_VERSION,
        "qjs_tree_clean_before": qjs_status_before == "",
        "qjs_tree_clean_after": qjs_status_after == "",
        "binary_sha256_known": all(
            sha256_is_known(value) for value in binary_hashes
        ),
        "taskset_binding_succeeded": taskset_probe.get("passed") is True,
        "sampling_abba_balanced": bool(sampling_balanced),
        "samples_complete": bool(samples_complete),
        "metadata_complete": len(metadata_reasons) == 0,
        "timing_complete": len(timing_reasons) == 0,
        "pmu_binding_reliable": bool(pmu_reliable),
        "case_registered_reason": (
            None
            if case_id in CASE_DEFINITIONS
            else f"{case_id!r} is absent from CASE_DEFINITIONS"
        ),
        "qjs_head_matches_reason": (
            None
            if qjs_head == EXPECTED_QJS_HEAD
            else f"observed {qjs_head}, expected {EXPECTED_QJS_HEAD}"
        ),
        "qjs_version_matches_reason": (
            None
            if qjs_version == EXPECTED_QJS_VERSION
            else f"observed {qjs_version}, expected {EXPECTED_QJS_VERSION}"
        ),
        "qjs_tree_clean_before_reason": (
            None
            if qjs_status_before == ""
            else "pinned QuickJS tree was dirty before measurement"
        ),
        "qjs_tree_clean_after_reason": (
            None
            if qjs_status_after == ""
            else "pinned QuickJS tree became dirty during measurement"
        ),
        "binary_sha256_known_reason": (
            None
            if all(sha256_is_known(value) for value in binary_hashes)
            else "one or more selected harness SHA-256 values are missing"
        ),
        "taskset_binding_succeeded_reason": taskset_probe.get("reason"),
        "sampling_abba_balanced_reason": (
            None
            if sampling_balanced
            else "observed sampling order was not balanced ABBA: "
            f"{observed_orders!r}"
        ),
        "samples_complete_reason": (
            None
            if samples_complete
            else f"collected {len(samples)} complete pairs, expected {args.samples}"
        ),
        "metadata_complete_reason": (
            None
            if not metadata_reasons
            else "; ".join(dict.fromkeys(metadata_reasons))
        ),
        "timing_complete_reason": (
            None
            if not timing_reasons
            else "; ".join(dict.fromkeys(timing_reasons))
        ),
        "pmu_binding_reliable_reason": pmu_reason,
    }
    return context


def main() -> int:
    script = Path(__file__).resolve()
    repo = script.parents[3]
    args = parse_args(repo)
    cases = tuple(args.selected_cases or CASES)
    qjs_dir = args.qjs_dir.resolve()
    output = args.output
    if not output.is_absolute():
        output = (repo / output).resolve()

    if args.cpu < 0:
        raise RuntimeError("--cpu must be non-negative")
    if hasattr(os, "sched_getaffinity") and args.cpu not in os.sched_getaffinity(0):
        raise RuntimeError(
            f"CPU {args.cpu} is outside this process affinity "
            f"{sorted(os.sched_getaffinity(0))}"
        )
    if args.samples % 2 != 0:
        print(
            f"warning: --samples {args.samples} is odd; ABBA first-position "
            "counts are not balanced",
            file=sys.stderr,
        )

    qjs_head = git_output(qjs_dir, "rev-parse", "HEAD")
    qjs_version = (qjs_dir / "VERSION").read_text().strip()
    qjs_status_before = git_output(qjs_dir, "status", "--porcelain")
    if qjs_head != EXPECTED_QJS_HEAD:
        raise RuntimeError(
            f"QuickJS HEAD is {qjs_head}, expected pinned {EXPECTED_QJS_HEAD}"
        )
    if qjs_version != EXPECTED_QJS_VERSION:
        raise RuntimeError(
            f"QuickJS VERSION is {qjs_version}, expected {EXPECTED_QJS_VERSION}"
        )
    if qjs_status_before:
        raise RuntimeError("pinned QuickJS tree is dirty before benchmark")

    taskset_available = shutil.which("taskset") is not None
    if not taskset_available:
        raise RuntimeError("taskset is required for pinned direct benchmarks")
    taskset_probe = verify_taskset_binding(repo, args.cpu)
    pmu_probe = discover_pmu_for_cpu(args.cpu)
    args.expected_pmu_name = (
        pmu_probe["name"] if pmu_probe["passed"] is True else None
    )
    zjs_binary, qjs_binaries, compile_info = build_harnesses(
        repo, args, cases
    )
    perf_available = shutil.which("perf") is not None

    raw_samples: dict[str, list[dict]] = {case_id: [] for case_id in cases}
    for case_id in cases:
        for sample_index in range(args.samples):
            order = ("qjs", "zjs") if sample_index % 2 == 0 else ("zjs", "qjs")
            records: dict[str, dict] = {}
            for engine in order:
                if engine == "qjs":
                    binary = (
                        qjs_binaries["bigint/mul-multilimb"]
                        if case_id == "bigint/mul-multilimb"
                        else qjs_binaries["default"]
                    )
                else:
                    binary = zjs_binary
                records[engine] = run_direct_process(
                    repo=repo,
                    binary=binary,
                    engine=engine,
                    case_id=case_id,
                    args=args,
                    perf_available=perf_available,
                )
            checksum_comparable = (
                records["zjs"].get("checksum_comparable") is True
                and records["qjs"].get("checksum_comparable") is True
            )
            checksum_match = (
                records["zjs"].get("checksum")
                == records["qjs"].get("checksum")
                if checksum_comparable
                and nonempty_checksum(records["zjs"].get("checksum"))
                and nonempty_checksum(records["qjs"].get("checksum"))
                else None
            )
            zjs_baseline = records["zjs"].get("baseline")
            qjs_baseline = records["qjs"].get("baseline")
            baseline_checksum_comparable = (
                isinstance(zjs_baseline, dict)
                and isinstance(qjs_baseline, dict)
                and zjs_baseline.get("checksum_comparable") is True
                and qjs_baseline.get("checksum_comparable") is True
            )
            baseline_checksum_match = (
                zjs_baseline.get("checksum") == qjs_baseline.get("checksum")
                if baseline_checksum_comparable
                and nonempty_checksum(zjs_baseline.get("checksum"))
                and nonempty_checksum(qjs_baseline.get("checksum"))
                else None
            )
            raw_samples[case_id].append(
                {
                    "sample": sample_index + 1,
                    "order": list(order),
                    "engines": records,
                    "checksums_match": checksum_match,
                    "baseline_checksums_match": baseline_checksum_match,
                }
            )

    qjs_status_after = git_output(qjs_dir, "status", "--porcelain")

    zig_version = first_line([args.zig, "version"], repo)
    cc_version = first_line([args.cc, "--version"], repo)
    cpu_models, cpu_model_by_id = cpu_inventory()
    first_position_counts = {"qjs": 0, "zjs": 0}
    for sample in raw_samples[cases[0]]:
        first_position_counts[sample["order"][0]] += 1
    sampling_balanced = (
        first_position_counts["qjs"] == first_position_counts["zjs"]
    )
    observed_validation = validation_metadata(raw_samples)
    qjs_default_path = qjs_binaries.get("default")
    qjs_bigint_path = qjs_binaries.get("bigint/mul-multilimb")
    (
        qjs_default_binary,
        qjs_default_sha,
        qjs_default_reason,
    ) = optional_binary_metadata(
        qjs_default_path, "skipped (case not selected)"
    )
    (
        qjs_bigint_binary,
        qjs_bigint_sha,
        qjs_bigint_reason,
    ) = optional_binary_metadata(
        qjs_bigint_path, "skipped (case not selected)"
    )
    zjs_binary_sha = sha256(zjs_binary)
    provenance_by_case = {}
    for case_id in cases:
        selected_qjs_sha = (
            qjs_bigint_sha
            if case_id == "bigint/mul-multilimb"
            else qjs_default_sha
        )
        provenance_by_case[case_id] = case_provenance_context(
            case_id=case_id,
            samples=raw_samples[case_id],
            args=args,
            qjs_head=qjs_head,
            qjs_version=qjs_version,
            qjs_status_before=qjs_status_before,
            qjs_status_after=qjs_status_after,
            binary_hashes=[zjs_binary_sha, selected_qjs_sha],
            taskset_probe=taskset_probe,
            perf_available=perf_available,
            pmu_probe=pmu_probe,
        )
    summaries = [
        summarize_case(
            case_id,
            raw_samples[case_id],
            provenance_by_case[case_id],
        )
        for case_id in cases
    ]

    report = {
        "schema_version": 3,
        "layer": "direct algorithm / core",
        "metadata": {
            "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "zjs_git_head": git_output(repo, "rev-parse", "HEAD"),
            "qjs_git_head": qjs_head,
            "qjs_version": qjs_version,
            "binary_sha256": {
                "zjs_direct_bench": zjs_binary_sha,
                "qjs_direct_bench": qjs_default_sha,
                "qjs_direct_bench_reason": qjs_default_reason,
                "qjs_bigint_direct_bench": qjs_bigint_sha,
                "qjs_bigint_direct_bench_reason": qjs_bigint_reason,
            },
            "binaries": {
                "zjs": str(zjs_binary),
                "qjs": qjs_default_binary,
                "qjs_reason": qjs_default_reason,
                "qjs_bigint": qjs_bigint_binary,
                "qjs_bigint_reason": qjs_bigint_reason,
            },
            "zig_version": zig_version,
            "cc_version": cc_version,
            "kernel": platform.release(),
            "machine": platform.machine(),
            "cpu_models": cpu_models,
            "cpu_model_by_id": cpu_model_by_id,
            "pinned_cpu_model": cpu_model_by_id.get(str(args.cpu)),
            "cpu_id": args.cpu,
            "warmup": args.warmup,
            "iterations": args.iterations,
            "baseline_iterations": 1,
            "timed_samples": args.samples,
            "sampling_order": "ABBA",
            "sampling_first_position_balanced": sampling_balanced,
            "first_position_counts": first_position_counts,
            "first_position_counts_scope": "per selected case",
            "case_definitions": CASE_DEFINITIONS,
            "comparability_formula": (
                "source_comparable && checksum_comparable && "
                "metric_comparable && provenance_comparable"
            ),
            "case_provenance_context": provenance_by_case,
            "metric_comparable_exemption": {
                "active": bool(args.no_perf),
                "component": "metric_comparable",
                "reason": (
                    "explicit --no-perf disables the primary PMU metric; "
                    "metric_comparable remains false but that component alone "
                    "is exempt from the collector exit code"
                    if args.no_perf
                    else None
                ),
            },
            "build_mode": {
                "zjs": "ReleaseFast, omit_frame_pointer",
                "qjs_archive": "-O3 -DNDEBUG, pinned libquickjs.a",
                "qjs_included_bigint": (
                    "-O3 -DNDEBUG -fwrapv, pinned quickjs.c included TU"
                ),
            },
            "zjs_jsvalue_representation": zjs_representation_metadata(
                raw_samples
            ),
            "perf_requested": not args.no_perf,
            "perf_executable_available": perf_available,
            "taskset_binding_probe": taskset_probe,
            "pmu_binding_probe": pmu_probe,
            "selected_pmu": args.expected_pmu_name,
            "perf_events": list(PERF_EVENTS),
            "perf_counter_columns": (
                "value, unit, event, counter runtime ns, run percent; raw "
                "per-invocation rows preserve run_percent for multiplexing"
            ),
            "instructions_scope": {
                "process_scope": (
                    "main perf count / N; whole process including setup and warmup"
                ),
                "loop_only": (
                    "(main count at N,W - baseline count at 1,W) / (N-1); "
                    "negative deltas are below baseline resolution and derive null"
                ),
                "ns_total": "harness-internal timed kernel loop only",
            },
            "quickjs_c_compile": compile_info,
            "quickjs_tree_clean_before": qjs_status_before == "",
            "quickjs_tree_clean_after": qjs_status_after == "",
            **observed_validation,
            "exit_code_observation": (
                "perf stat --output separates counter CSV and propagates the "
                "harness status; taskset propagates that observed status"
            ),
            "stderr_observation": (
                "perf CSV is written to a temporary file; captured subprocess "
                "stderr is the harness stderr and is required to be empty"
            ),
            "allocation_scope": (
                "runtime live allocation-count and allocated-byte snapshots "
                "bracket the timed loop; unavailable harnesses report null plus reason"
            ),
            "peak_rss_scope": (
                "each harness reads its own /proc/self/status VmHWM before exit"
            ),
            "parser_compile_context_teardown": (
                "excluded from ns_total except BigInt result allocation/free and "
                "kernel-intrinsic RegExp work; see per-case caliber_note"
            ),
            "leak_check": False,
        },
        "cases": summaries,
        "samples": raw_samples,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, sort_keys=False) + "\n")
    print_summary(output, summaries, compile_info)

    failed = False
    for summary in summaries:
        case_id = f"{summary['category']}/{summary['case']}"
        # Harness observation validity is checked on its own, before and
        # independently of the component loop. metric_comparability folds
        # validation failures into its reason string, so routing them only
        # through that component would let the --no-perf exemption below
        # swallow an invalid harness observation and still return 0.
        if not summary["validation"]["valid"]:
            failed = True
            print(
                f"invalid harness observation: {case_id}: "
                + "; ".join(summary["validation"]["failures"]),
                file=sys.stderr,
            )
        for component_name in (
            "source",
            "checksum",
            "metric",
            "provenance",
        ):
            component = summary["comparability"][component_name]
            if component["comparable"] is True:
                continue
            label = f"{component_name}_comparable"
            # A component the case registry declares as permanently
            # incomparable is a design fact, not a failed measurement. It still
            # suppresses the headline ratio (comparable stays False), but it
            # must not make the collector exit non-zero. Only an *undeclared*
            # incomparability is a measurement failure.
            case_definition = CASE_DEFINITIONS.get(case_id)
            if (
                case_definition is not None
                and case_definition.get(f"{component_name}_comparable_required")
                is False
            ):
                print(
                    f"declared-incomparable: {case_id}: {label}: "
                    f"{case_definition.get('incomparability_reason', 'declared in CASE_DEFINITIONS')}",
                    file=sys.stderr,
                )
                continue
            if component_name == "metric" and args.no_perf:
                print(
                    f"metric_comparable exemption (--no-perf): {case_id}: "
                    f"{component['reason']}",
                    file=sys.stderr,
                )
                continue
            failed = True
            print(
                f"not comparable: {case_id}: {label}: "
                f"{component['reason']}",
                file=sys.stderr,
            )
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"run_direct: {error}", file=sys.stderr)
        raise SystemExit(1)
