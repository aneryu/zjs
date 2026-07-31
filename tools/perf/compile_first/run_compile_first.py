#!/usr/bin/env python3
"""Collect diagnostic compile/first-run scaling points from the two harnesses."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import re
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[2]
DEFAULT_MANIFEST = SCRIPT_DIR / "manifest.json"
DEFAULT_ZJS_HARNESS = REPO_ROOT / "zig-out/bin/zjs-same-runtime"
DEFAULT_QJS_HARNESS = (
    REPO_ROOT
    / ".zig-cache/perf/qjs-align/same-runtime/qjs-same-runtime"
)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
LOCAL_DECLARATION_RE = re.compile(
    rb"^  const v[0-9]{5} = [0-9]+;$", re.MULTILINE
)
PHASES = ("compile_ns", "first_execute_ns")


class MeasurementError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_int(value: Any, label: str, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise MeasurementError(f"{label} must be an integer >= {minimum}")
    return value


def require_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise MeasurementError(f"{label} must be a non-empty string")
    return value


def load_manifest(path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    try:
        raw = path.read_bytes()
        manifest = json.loads(raw)
    except (OSError, json.JSONDecodeError) as error:
        raise MeasurementError(f"cannot load manifest {path}: {error}") from error
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 1:
        raise MeasurementError("manifest schema_version must be 1")
    if manifest.get("padding") != "none":
        raise MeasurementError("manifest must declare padding=none")
    entries = manifest.get("anchors")
    if not isinstance(entries, list) or len(entries) < 4:
        raise MeasurementError("manifest must contain at least four anchors")

    manifest_dir = path.resolve().parent
    anchors: list[dict[str, Any]] = []
    seen_names: set[str] = set()
    seen_sizes: set[int] = set()
    for index, entry in enumerate(entries):
        label = f"manifest.anchors[{index}]"
        if not isinstance(entry, dict):
            raise MeasurementError(f"{label} must be an object")
        name = require_string(entry.get("name"), f"{label}.name")
        if name in seen_names:
            raise MeasurementError(f"duplicate anchor name: {name}")
        seen_names.add(name)
        relative_path = require_string(
            entry.get("relative_path"), f"{label}.relative_path"
        )
        source_path = (manifest_dir / relative_path).resolve()
        try:
            source_path.relative_to(manifest_dir)
        except ValueError as error:
            raise MeasurementError(
                f"{label}.relative_path escapes the manifest directory"
            ) from error
        try:
            source = source_path.read_bytes()
        except OSError as error:
            raise MeasurementError(
                f"cannot read anchor {source_path}: {error}"
            ) from error

        expected_bytes = require_int(
            entry.get("source_bytes"), f"{label}.source_bytes", 1
        )
        if len(source) != expected_bytes:
            raise MeasurementError(
                f"{name} source byte mismatch: expected {expected_bytes}, "
                f"got {len(source)}"
            )
        expected_sha = require_string(
            entry.get("source_sha256"), f"{label}.source_sha256"
        )
        if not SHA256_RE.fullmatch(expected_sha):
            raise MeasurementError(f"{label}.source_sha256 is not lowercase SHA-256")
        actual_sha = hashlib.sha256(source).hexdigest()
        if actual_sha != expected_sha:
            raise MeasurementError(
                f"{name} source SHA-256 mismatch: expected {expected_sha}, "
                f"got {actual_sha}"
            )
        if b"function run()" not in source:
            raise MeasurementError(f"{name} does not define function run()")
        if b"//" in source or b"/*" in source:
            raise MeasurementError(
                f"{name} contains comments; compile anchors must not use comment padding"
            )
        declaration_count = require_int(
            entry.get("payload_declarations"),
            f"{label}.payload_declarations",
        )
        actual_declarations = len(LOCAL_DECLARATION_RE.findall(source))
        if actual_declarations != declaration_count:
            raise MeasurementError(
                f"{name} declaration count mismatch: expected "
                f"{declaration_count}, got {actual_declarations}"
            )
        expected_checksum = require_string(
            entry.get("expected_checksum"), f"{label}.expected_checksum"
        )
        if expected_bytes in seen_sizes:
            raise MeasurementError(f"duplicate anchor source size: {expected_bytes}")
        seen_sizes.add(expected_bytes)
        anchors.append(
            {
                "name": name,
                "relative_path": relative_path,
                "source_path": str(source_path),
                "source_bytes": expected_bytes,
                "source_sha256": expected_sha,
                "payload_declarations": declaration_count,
                "expected_checksum": expected_checksum,
            }
        )
    anchors.sort(key=lambda anchor: anchor["source_bytes"])
    return (
        {
            "path": str(path.resolve()),
            "sha256": hashlib.sha256(raw).hexdigest(),
            "schema_version": 1,
            "shape": manifest.get("shape"),
            "padding": "none",
        },
        anchors,
    )


def executable_identity(path: Path, engine: str) -> dict[str, Any]:
    resolved = path.resolve()
    if not resolved.is_file():
        raise MeasurementError(f"{engine} harness is not a file: {resolved}")
    if not os.access(resolved, os.X_OK):
        raise MeasurementError(f"{engine} harness is not executable: {resolved}")
    return {
        "path": str(resolved),
        "binary_sha256": sha256_file(resolved),
        "size_bytes": resolved.stat().st_size,
    }


def git_identity(path: Path) -> dict[str, Any]:
    resolved = path.resolve()

    def git(*arguments: str) -> str:
        completed = subprocess.run(
            ["git", "-C", str(resolved), *arguments],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if completed.returncode != 0:
            raise MeasurementError(
                f"git {' '.join(arguments)} failed for {resolved}: "
                f"{completed.stderr.strip()}"
            )
        return completed.stdout

    commit = git("rev-parse", "HEAD").strip()
    status_lines = [
        line
        for line in git(
            "status", "--porcelain=v1", "--untracked-files=normal"
        ).splitlines()
        if line
    ]
    return {
        "path": str(resolved),
        "commit": commit,
        "dirty": bool(status_lines),
        "status_porcelain": status_lines,
    }


def validate_harness_record(
    record: Any,
    *,
    engine: str,
    anchor: dict[str, Any],
) -> dict[str, Any]:
    if not isinstance(record, dict):
        raise MeasurementError(f"{engine}/{anchor['name']} record is not an object")

    exact_values = {
        "engine": engine,
        "layer": "same-runtime",
        "case": anchor["name"],
        "source_sha256": anchor["source_sha256"],
        "compiles": 1,
        "top_level_executions": 1,
        "teardown_mode": "normal",
        "iterations": 1,
        "warmup": 0,
        "result_checksum": anchor["expected_checksum"],
    }
    for field, expected in exact_values.items():
        if record.get(field) != expected:
            raise MeasurementError(
                f"{engine}/{anchor['name']} {field} mismatch: expected "
                f"{expected!r}, got {record.get(field)!r}"
            )

    if not isinstance(record.get("build"), dict):
        raise MeasurementError(f"{engine}/{anchor['name']} build must be an object")
    representation = record.get("jsvalue_representation")
    if not isinstance(representation, dict):
        raise MeasurementError(
            f"{engine}/{anchor['name']} jsvalue_representation must be an object"
        )
    require_int(
        representation.get("size_bytes"),
        f"{engine}/{anchor['name']}.jsvalue_representation.size_bytes",
        1,
    )
    require_int(
        record.get("clock_monotonic_resolution_ns"),
        f"{engine}/{anchor['name']}.clock_monotonic_resolution_ns",
        1,
    )
    phase_definitions = record.get("phase_definitions")
    if not isinstance(phase_definitions, dict):
        raise MeasurementError(
            f"{engine}/{anchor['name']} phase_definitions must be an object"
        )
    phases = record.get("phases")
    if not isinstance(phases, dict):
        raise MeasurementError(f"{engine}/{anchor['name']} phases must be an object")
    validated_phases: dict[str, int] = {}
    for phase in PHASES:
        require_string(
            phase_definitions.get(phase),
            f"{engine}/{anchor['name']}.phase_definitions.{phase}",
        )
        validated_phases[phase] = require_int(
            phases.get(phase), f"{engine}/{anchor['name']}.phases.{phase}"
        )
    return {
        "phases": validated_phases,
        "build": record["build"],
        "jsvalue_representation": representation,
        "clock_monotonic_resolution_ns": record[
            "clock_monotonic_resolution_ns"
        ],
        "phase_definitions": {
            phase: phase_definitions[phase] for phase in PHASES
        },
    }


def invoke_harness(
    identity: dict[str, Any],
    engine: str,
    anchor: dict[str, Any],
) -> dict[str, Any]:
    command = [
        identity["path"],
        "--case",
        anchor["name"],
        "--source",
        anchor["source_path"],
        "--iterations",
        "1",
        "--warmup",
        "0",
        "--teardown",
        "normal",
    ]
    completed = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise MeasurementError(
            f"{engine}/{anchor['name']} harness exited "
            f"{completed.returncode}: {completed.stderr.strip()}"
        )
    if completed.stderr:
        raise MeasurementError(
            f"{engine}/{anchor['name']} emitted unexpected stderr: "
            f"{completed.stderr.strip()}"
        )
    try:
        record = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise MeasurementError(
            f"{engine}/{anchor['name']} did not emit one JSON document: {error}"
        ) from error
    return validate_harness_record(record, engine=engine, anchor=anchor)


def median_number(values: list[int]) -> float:
    return float(statistics.median(values))


def linear_regression(points: list[dict[str, Any]]) -> dict[str, Any]:
    xs = [float(point["source_bytes"]) for point in points]
    ys = [float(point["median_ns"]) for point in points]
    x_mean = statistics.fmean(xs)
    y_mean = statistics.fmean(ys)
    denominator = sum((x - x_mean) ** 2 for x in xs)
    if denominator == 0:
        raise MeasurementError("cannot regress anchors with identical source sizes")
    slope = sum(
        (x - x_mean) * (y - y_mean) for x, y in zip(xs, ys, strict=True)
    ) / denominator
    intercept = y_mean - slope * x_mean
    residual_sum = sum(
        (y - (intercept + slope * x)) ** 2
        for x, y in zip(xs, ys, strict=True)
    )
    total_sum = sum((y - y_mean) ** 2 for y in ys)
    r_squared = None if total_sum == 0 else 1.0 - residual_sum / total_sum
    return {
        "model": (
            "median_ns = intercept_ns + "
            "slope_ns_per_source_byte * source_bytes"
        ),
        "fit_input": "per-anchor median of raw fresh-process points",
        "n_anchors": len(points),
        "intercept_ns": intercept,
        "slope_ns_per_source_byte": slope,
        "r_squared": r_squared,
    }


def summarize(
    raw_points: list[dict[str, Any]],
    anchors: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    per_anchor: list[dict[str, Any]] = []
    regressions: dict[str, Any] = {
        "warning": (
            "Four-point OLS is a minimal descriptive model, not a formal "
            "complexity or causality claim."
        )
    }
    regression_points: dict[str, dict[str, list[dict[str, Any]]]] = {
        engine: {phase: [] for phase in PHASES}
        for engine in ("qjs", "zjs")
    }

    for anchor in anchors:
        item: dict[str, Any] = {
            key: anchor[key]
            for key in (
                "name",
                "relative_path",
                "source_bytes",
                "source_sha256",
                "payload_declarations",
                "expected_checksum",
            )
        }
        item["engines"] = {}
        for engine in ("qjs", "zjs"):
            engine_points = [
                point
                for point in raw_points
                if point["anchor"] == anchor["name"]
                and point["engine"] == engine
            ]
            phase_stats: dict[str, Any] = {}
            for phase in PHASES:
                samples = [point[phase] for point in engine_points]
                median_ns = median_number(samples)
                phase_stats[phase] = {
                    "samples_ns": samples,
                    "min_ns": min(samples),
                    "median_ns": median_ns,
                    "max_ns": max(samples),
                }
                regression_points[engine][phase].append(
                    {
                        "anchor": anchor["name"],
                        "source_bytes": anchor["source_bytes"],
                        "median_ns": median_ns,
                    }
                )
            item["engines"][engine] = phase_stats
        item["zjs_over_qjs"] = {
            phase: (
                item["engines"]["zjs"][phase]["median_ns"]
                / item["engines"]["qjs"][phase]["median_ns"]
                if item["engines"]["qjs"][phase]["median_ns"] > 0
                else None
            )
            for phase in PHASES
        }
        per_anchor.append(item)

    for engine in ("qjs", "zjs"):
        regressions[engine] = {}
        for phase in PHASES:
            points = regression_points[engine][phase]
            regressions[engine][phase] = {
                "points": points,
                "regression": linear_regression(points),
            }
    return per_anchor, regressions


def machine_environment() -> dict[str, Any]:
    cpu_brand = None
    if platform.system() == "Darwin":
        completed = subprocess.run(
            ["sysctl", "-n", "machdep.cpu.brand_string"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if completed.returncode == 0:
            cpu_brand = completed.stdout.strip() or None
    return {
        "system": platform.system(),
        "release": platform.release(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "cpu_brand": cpu_brand or platform.processor() or None,
        "logical_cpu_count": os.cpu_count(),
        "affinity_pinned": False,
        "frequency_pinned": False,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--zjs-harness", type=Path, default=DEFAULT_ZJS_HARNESS)
    parser.add_argument("--qjs-harness", type=Path, default=DEFAULT_QJS_HARNESS)
    parser.add_argument("--zjs-repo", type=Path, default=REPO_ROOT)
    parser.add_argument(
        "--qjs-repo", type=Path, default=REPO_ROOT.parent / "quickjs"
    )
    parser.add_argument(
        "--samples-per-engine",
        type=int,
        default=10,
        help="fresh-process samples per engine and anchor; must be positive and even",
    )
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def collect(args: argparse.Namespace) -> dict[str, Any]:
    if args.samples_per_engine <= 0 or args.samples_per_engine % 2 != 0:
        raise MeasurementError("--samples-per-engine must be positive and even")
    manifest_identity, anchors = load_manifest(args.manifest.resolve())
    harnesses = {
        "qjs": executable_identity(args.qjs_harness, "qjs"),
        "zjs": executable_identity(args.zjs_harness, "zjs"),
    }
    repositories = {
        "qjs": git_identity(args.qjs_repo),
        "zjs": git_identity(args.zjs_repo),
    }
    raw_points: list[dict[str, Any]] = []
    first_records: dict[str, dict[str, Any]] = {}
    sequence = 0
    blocks = args.samples_per_engine // 2

    for block in range(blocks):
        # Rotate and reverse anchor order between blocks so increasing source
        # size is not confounded with the full-run time trend.
        offset = block % len(anchors)
        anchor_order = anchors[offset:] + anchors[:offset]
        if block % 2:
            anchor_order = list(reversed(anchor_order))
        for anchor in anchor_order:
            for position, engine in enumerate(("qjs", "zjs", "zjs", "qjs"), 1):
                validated = invoke_harness(harnesses[engine], engine, anchor)
                if engine not in first_records:
                    first_records[engine] = validated
                sequence += 1
                raw_points.append(
                    {
                        "sequence": sequence,
                        "abba_block": block,
                        "block_position": position,
                        "anchor": anchor["name"],
                        "source_bytes": anchor["source_bytes"],
                        "source_sha256": anchor["source_sha256"],
                        "engine": engine,
                        "harness_binary_sha256": harnesses[engine][
                            "binary_sha256"
                        ],
                        "result_checksum": anchor["expected_checksum"],
                        **validated["phases"],
                    }
                )

    # Fail if an executable or source changed while measurements were in flight.
    for engine, identity in harnesses.items():
        post_sha = sha256_file(Path(identity["path"]))
        identity["post_run_binary_sha256"] = post_sha
        identity["binary_unchanged_during_run"] = (
            post_sha == identity["binary_sha256"]
        )
        if not identity["binary_unchanged_during_run"]:
            raise MeasurementError(f"{engine} harness changed during collection")
    post_manifest, post_anchors = load_manifest(args.manifest.resolve())
    if post_manifest["sha256"] != manifest_identity["sha256"] or [
        (item["name"], item["source_sha256"]) for item in post_anchors
    ] != [
        (item["name"], item["source_sha256"]) for item in anchors
    ]:
        raise MeasurementError("manifest or anchor sources changed during collection")

    per_anchor, regressions = summarize(raw_points, anchors)
    environment = machine_environment()
    dirty_repositories = [
        engine for engine, identity in repositories.items() if identity["dirty"]
    ]
    diagnostic_reasons = [
        "The collector does not pin CPU affinity or frequency.",
        (
            "macOS does not provide the Linux taskset/perf controls used by "
            "the stricter performance workflow."
            if environment["system"] == "Darwin"
            else "This run did not use a platform-specific pinned runner."
        ),
        "Fresh-process launch and scheduler noise remain in the raw samples.",
    ]
    if dirty_repositories:
        diagnostic_reasons.append(
            "Dirty source repositories: " + ", ".join(dirty_repositories) + "."
        )

    return {
        "schema_version": 1,
        "tool": "compile-first-run",
        "layer": "fresh-process-compile-first-run",
        "created_at_utc": dt.datetime.now(dt.UTC).isoformat(),
        "measurement_classification": "diagnostic-only",
        "formal_claim_allowed": False,
        "diagnostic_reasons": diagnostic_reasons,
        "sampling": {
            "order": "ABBA",
            "a_engine": "qjs",
            "b_engine": "zjs",
            "samples_per_engine_per_anchor": args.samples_per_engine,
            "blocks": blocks,
            "fresh_process_per_point": True,
            "iterations_per_harness_process": 1,
            "warmup_per_harness_process": 0,
            "anchor_order": (
                "rotated each block and reversed on odd-numbered blocks"
            ),
        },
        "phase_contract": {
            "compile_ns": {
                "use": "cross-engine diagnostic scaling",
                "comparability": (
                    "Both harnesses stop at their ordinary-global-script "
                    "compile-only FunctionBytecode boundary, but internal "
                    "instrumentation and finalization work are not identical."
                ),
            },
            "first_execute_ns": {
                "use": "diagnostic only",
                "comparability": (
                    "Both begin with a compiled ordinary root and stop after "
                    "the first top-level result. QuickJS times "
                    "JS_EvalFunction; zjs includes root publication and its "
                    "top-level VM boundary. Cleanup and Realm/global surfaces "
                    "remain different."
                ),
            },
            "source_size_model": {
                "independent_variable": "exact source bytes",
                "fixed_work": (
                    "Each source creates two global functions; the scalable "
                    "function is never called, and run() returns one constant "
                    "checksum string."
                ),
                "scalable_work": (
                    "Fixed-width local const declarations inside the uncalled "
                    "compilePayload function; no comment padding."
                ),
            },
        },
        "inputs": {
            "manifest": manifest_identity,
            "anchors": [
                {
                    key: anchor[key]
                    for key in (
                        "name",
                        "relative_path",
                        "source_bytes",
                        "source_sha256",
                        "payload_declarations",
                        "expected_checksum",
                    )
                }
                for anchor in anchors
            ],
            "collector": {
                "path": str(Path(__file__).resolve()),
                "sha256": sha256_file(Path(__file__).resolve()),
            },
            "harnesses": harnesses,
            "repositories": repositories,
        },
        "environment": environment,
        "harness_schema_evidence": {
            engine: {
                "build": record["build"],
                "jsvalue_representation": record[
                    "jsvalue_representation"
                ],
                "clock_monotonic_resolution_ns": record[
                    "clock_monotonic_resolution_ns"
                ],
                "phase_definitions": record["phase_definitions"],
            }
            for engine, record in first_records.items()
        },
        "raw_points": raw_points,
        "per_anchor": per_anchor,
        "regressions": regressions,
        "validation": {
            "status": "passed",
            "checks": [
                "manifest schema, exact source bytes, and source SHA-256",
                "ordinary script run() definition and no comment padding",
                "declared linear payload-declaration count",
                "harness executable SHA-256 before and after collection",
                "one complete harness JSON object per fresh process",
                "engine/layer/case/source/checksum/one-compile/one-first-run schema",
                "compile_ns and first_execute_ns non-negative integer schema",
                "cross-engine checksum equality through the shared manifest value",
            ],
        },
    }


def write_artifact(path: Path, artifact: dict[str, Any]) -> None:
    destination = path.resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    payload = (json.dumps(artifact, indent=2, sort_keys=True) + "\n").encode(
        "utf-8"
    )
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            dir=destination.parent,
            prefix=f".{destination.name}.",
            delete=False,
        ) as temporary:
            temporary.write(payload)
            temporary_name = temporary.name
        os.replace(temporary_name, destination)
    finally:
        if temporary_name is not None:
            temporary_path = Path(temporary_name)
            if temporary_path.exists():
                temporary_path.unlink()


def print_summary(artifact: dict[str, Any], output: Path) -> None:
    print(f"wrote diagnostic artifact: {output.resolve()}")
    print("engine phase intercept_ns slope_ns_per_byte r_squared")
    for engine in ("qjs", "zjs"):
        for phase in PHASES:
            regression = artifact["regressions"][engine][phase]["regression"]
            r_squared = regression["r_squared"]
            print(
                engine,
                phase,
                f"{regression['intercept_ns']:.3f}",
                f"{regression['slope_ns_per_source_byte']:.6f}",
                "null" if r_squared is None else f"{r_squared:.6f}",
            )
    print("classification: diagnostic-only (formal_claim_allowed=false)")


def main() -> int:
    args = parse_args()
    try:
        artifact = collect(args)
        write_artifact(args.output, artifact)
    except (MeasurementError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print_summary(artifact, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
