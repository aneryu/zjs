#!/usr/bin/env python3
"""Collect deterministic call-boundary exposure counts for all 15 Zoo items.

This runner is intentionally counter-only.  Its instrumented binaries must
never be used for timing or unit-cost estimates.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import tempfile


SCORE_RE = re.compile(r"^([A-Za-z0-9_]+):\s+[0-9]+(?:\.[0-9]+)?\s*$")


def parse_score_keys(text: str) -> list[str]:
    return sorted(match.group(1) for line in text.splitlines() if (match := SCORE_RE.match(line)))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def stable_counter_record(engine: str, raw: dict[str, int]) -> dict[str, int]:
    if engine == "qjs":
        result = dict(raw)
    else:
        js_to_js = raw["call_frames"] - raw["l0_entries"] - raw["native_fences"]
        if js_to_js < 0:
            raise RuntimeError(f"negative derived zjs JS->JS count: {raw}")
        result = {
            "bytecode_entries": raw["call_frames"],
            "bytecode_returns": raw["call_returns"],
            "js_to_js": js_to_js,
            "root_entries": raw["l0_entries"] - raw["fallback_native_reentries"],
            "native_reentries": raw["native_fences"] + raw["fallback_native_reentries"],
            "c_function_calls": raw["c_function_calls"],
            "native_calls": raw["native_calls"],
            "frame_publishes": raw["call_frames"],
            "frame_restores": raw["call_returns"],
            "backtrace_publishes": raw["backtrace_publishes"],
            "backtrace_restores": raw["backtrace_restores"],
            "native_fences": raw["native_fences"],
            "native_fence_restores": raw["native_fence_restores"],
            "entry_republications": raw["entry_republications"],
            "reload_top": raw["reload_top"],
            "reload_after_pop": raw["reload_after_pop"],
            "interrupt_polls": raw["interrupt_polls"],
        }
    return {key: int(value) for key, value in result.items()}


def validate_balances(engine: str, rec: dict[str, int]) -> None:
    pairs = [
        ("bytecode_entries", "bytecode_returns"),
        ("frame_publishes", "frame_restores"),
        ("backtrace_publishes", "backtrace_restores"),
    ]
    if engine == "zjs":
        pairs.append(("native_fences", "native_fence_restores"))
    for entered, left in pairs:
        if rec[entered] != rec[left]:
            raise RuntimeError(f"{engine}: unbalanced {entered}/{left}: {rec}")


def run_qjs(binary: Path, source: Path, counter_path: Path, timeout: int) -> tuple[dict[str, int], str]:
    env = os.environ.copy()
    env["CALL_BOUNDARY_QJS_COUNTERS"] = str(counter_path)
    proc = subprocess.run(
        [str(binary), str(source)], capture_output=True, text=True, env=env, timeout=timeout
    )
    if proc.returncode != 0:
        raise RuntimeError(f"qjs exited {proc.returncode}: {proc.stderr[-500:]}")
    if not counter_path.is_file():
        raise RuntimeError("qjs did not write its counter record")
    return stable_counter_record("qjs", json.loads(counter_path.read_text())), proc.stdout


def run_zjs(binary: Path, source: Path, timeout: int) -> tuple[dict[str, int], str]:
    proc = subprocess.run(
        [str(binary), "--profile-opcodes", "--perf-json", str(source)],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"zjs-profile exited {proc.returncode}: {proc.stderr[-500:]}")
    payload = json.loads(proc.stderr)
    return stable_counter_record("zjs", payload["opcode_profile"]), proc.stdout


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default="/home/aneryu/worktree-call-boundary")
    parser.add_argument("--zoo", default="/home/aneryu/javascript-zoo")
    parser.add_argument("--zjs", required=True)
    parser.add_argument("--qjs", required=True)
    parser.add_argument("--cpu", type=int, default=19)
    parser.add_argument("--samples", type=int, default=8)
    parser.add_argument("--iteration-divisor", type=int, default=16)
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    if args.samples < 8 or args.samples % 2:
        raise SystemExit("--samples must be even and >= 8")
    affinity = sorted(os.sched_getaffinity(0))
    if affinity != [args.cpu]:
        raise SystemExit(f"affinity must be [{args.cpu}], got {affinity}")

    repo = Path(args.repo).resolve()
    zoo = Path(args.zoo).resolve()
    zjs = Path(args.zjs).resolve()
    qjs = Path(args.qjs).resolve()
    sys.path.insert(0, str(repo / "tools/perf/zoo"))
    from run_zoo_compare import DEFAULT_BENCHES  # type: ignore
    from run_zoo_fixed_pmu import fixed_source  # type: ignore

    results: dict[str, dict] = {}
    order_log: list[dict] = []
    first_positions = {"qjs": 0, "zjs": 0}
    with tempfile.TemporaryDirectory(prefix="call-boundary-counts-") as tmp_name:
        tmp = Path(tmp_name)
        for bench in DEFAULT_BENCHES:
            original_path = zoo / "bench" / f"{bench}.js"
            original = original_path.read_bytes()
            fixed = fixed_source(original, original_path, args.iteration_divisor)
            source = tmp / f"{bench}.js"
            source.write_bytes(fixed)

            runs: dict[str, list[dict[str, int]]] = {"qjs": [], "zjs": []}
            stdout_hashes: dict[str, list[str]] = {"qjs": [], "zjs": []}
            score_keys: dict[str, list[list[str]]] = {"qjs": [], "zjs": []}
            for sample in range(args.samples):
                order = ["qjs", "zjs"] if sample % 2 == 0 else ["zjs", "qjs"]
                first_positions[order[0]] += 1
                order_log.append({"benchmark": bench, "sample": sample, "order": order})
                for engine in order:
                    if engine == "qjs":
                        counter_path = tmp / f"{bench}-{sample}-qjs.json"
                        rec, stdout = run_qjs(qjs, source, counter_path, args.timeout)
                    else:
                        rec, stdout = run_zjs(zjs, source, args.timeout)
                    validate_balances(engine, rec)
                    score_stdout = stdout.split("\nZJS opcode profile", 1)[0]
                    scores = parse_score_keys(score_stdout)
                    if not scores:
                        raise RuntimeError(f"{bench}/{engine}: no benchmark score in stdout")
                    runs[engine].append(rec)
                    stdout_hashes[engine].append(hashlib.sha256(stdout.encode()).hexdigest())
                    score_keys[engine].append(scores)
                    print(
                        f"{bench:14} {sample + 1}/{args.samples} {engine:4} "
                        f"jsjs={rec['js_to_js']:,} native={rec['native_calls']:,} "
                        f"reentry={rec['native_reentries']:,}",
                        file=sys.stderr,
                    )

            for engine in ("qjs", "zjs"):
                if any(keys != score_keys[engine][0] for keys in score_keys[engine][1:]):
                    raise RuntimeError(f"{bench}/{engine}: score keys changed across samples")
            if score_keys["qjs"][0] != score_keys["zjs"][0]:
                raise RuntimeError(f"{bench}: qjs/zjs score keys differ")

            counter_keys = {
                engine: sorted(runs[engine][0]) for engine in ("qjs", "zjs")
            }
            counts_median = {
                engine: {
                    key: statistics.median(record[key] for record in runs[engine])
                    for key in counter_keys[engine]
                }
                for engine in ("qjs", "zjs")
            }
            counts_mad = {
                engine: {
                    key: statistics.median(
                        abs(record[key] - counts_median[engine][key]) for record in runs[engine]
                    )
                    for key in counter_keys[engine]
                }
                for engine in ("qjs", "zjs")
            }
            results[bench] = {
                "source": {
                    "original": str(original_path),
                    "originalSha256": hashlib.sha256(original).hexdigest(),
                    "fixedSha256": hashlib.sha256(fixed).hexdigest(),
                },
                "counts": counts_median,
                "countsMAD": counts_mad,
                "counterRuns": runs,
                "exactAcrossSamples": {
                    engine: all(record == runs[engine][0] for record in runs[engine][1:])
                    for engine in ("qjs", "zjs")
                },
                "stdoutHashes": stdout_hashes,
                "scoreKeys": score_keys["qjs"][0],
            }

    artifact = {
        "schema": "call-boundary-exposure-counts-v1",
        "counterOnly": True,
        "timingUseForbidden": True,
        "samplesPerEnginePerBenchmark": args.samples,
        "order": "ABBA by sample parity",
        "firstPositionCounts": first_positions,
        "parallelism": 1,
        "cpu": args.cpu,
        "affinity": affinity,
        "iterationDivisor": args.iteration_divisor,
        "binaries": {
            "zjsCounter": {"path": str(zjs), "sha256": sha256(zjs)},
            "qjsCounter": {"path": str(qjs), "sha256": sha256(qjs)},
        },
        "benchmarks": results,
        "orderLog": order_log,
    }
    target = Path(args.output)
    target.write_text(json.dumps(artifact, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
