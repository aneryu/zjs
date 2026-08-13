#!/usr/bin/env python3
"""ABBA production-binary PMU run for the 15-item call exposure matrix."""

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


EVENT_NAMES = ["instructions", "cycles", "stall_backend", "stall_backend_mem"]
SCORE_RE = re.compile(r"^([A-Za-z0-9_]+):\s+[0-9]+(?:\.[0-9]+)?\s*$")


def has_score(text: str) -> bool:
    return any(SCORE_RE.match(line) for line in text.splitlines())


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def median(values: list[float]) -> float:
    return statistics.median(values)


def mad(values: list[float]) -> float:
    center = median(values)
    return median([abs(value - center) for value in values])


def parse_perf_csv(text: str) -> dict[str, int]:
    result: dict[str, int] = {}
    for line in text.splitlines():
        fields = line.split(",")
        if len(fields) < 3:
            continue
        raw, event = fields[0].strip(), fields[2].strip()
        if raw in {"<not counted>", "<not supported>"}:
            raise RuntimeError(f"unavailable PMU row: {line}")
        for name in EVENT_NAMES:
            if f"/{name}/" in event:
                result[name] = int(float(raw))
                break
    missing = [name for name in EVENT_NAMES if name not in result]
    if missing:
        raise RuntimeError(f"missing PMU events {missing}: {text}")
    return result


def run_one(binary: Path, source: Path, pmu: str, timeout: int) -> dict:
    specs = ",".join(f"{pmu}/{name}/u" for name in EVENT_NAMES)
    with tempfile.NamedTemporaryFile(prefix="call-boundary-pmu-", suffix=".csv") as stat:
        proc = subprocess.run(
            ["perf", "stat", "-x", ",", "-e", specs, "-o", stat.name, "--", str(binary), str(source)],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        counters = parse_perf_csv(Path(stat.name).read_text())
    if proc.returncode != 0:
        raise RuntimeError(f"{binary.name} exited {proc.returncode}: {proc.stderr[-500:]}")
    return {"counters": counters, "stdout": proc.stdout, "stderr": proc.stderr}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default="/home/aneryu/worktree-call-boundary")
    parser.add_argument("--zoo", default="/home/aneryu/javascript-zoo")
    parser.add_argument("--zjs", required=True)
    parser.add_argument("--qjs", required=True)
    parser.add_argument("--cpu", type=int, default=19)
    parser.add_argument("--pmu", default="armv8_pmuv3_1")
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
    with tempfile.TemporaryDirectory(prefix="call-boundary-pmu-") as tmp_name:
        tmp = Path(tmp_name)
        for bench in DEFAULT_BENCHES:
            original_path = zoo / "bench" / f"{bench}.js"
            original = original_path.read_bytes()
            fixed = fixed_source(original, original_path, args.iteration_divisor)
            source = tmp / f"{bench}.js"
            source.write_bytes(fixed)
            runs: dict[str, list[dict]] = {"qjs": [], "zjs": []}
            for sample in range(args.samples):
                order = ["qjs", "zjs"] if sample % 2 == 0 else ["zjs", "qjs"]
                first_positions[order[0]] += 1
                order_log.append({"benchmark": bench, "sample": sample, "order": order})
                for engine in order:
                    rec = run_one(qjs if engine == "qjs" else zjs, source, args.pmu, args.timeout)
                    if not has_score(rec["stdout"]):
                        raise RuntimeError(f"{bench}/{engine}: no benchmark score in stdout")
                    runs[engine].append(rec)
                    print(
                        f"{bench:14} {sample + 1}/{args.samples} {engine:4} "
                        f"insn={rec['counters']['instructions']:,} "
                        f"cycles={rec['counters']['cycles']:,} "
                        f"backend={rec['counters']['stall_backend']:,}",
                        file=sys.stderr,
                    )

            metrics: dict[str, dict] = {}
            for event in EVENT_NAMES:
                q_values = [record["counters"][event] for record in runs["qjs"]]
                z_values = [record["counters"][event] for record in runs["zjs"]]
                deltas = [z - q for z, q in zip(z_values, q_values)]
                ratios = [z / q for z, q in zip(z_values, q_values)]
                metrics[event] = {
                    "qjsMedian": median(q_values),
                    "qjsMAD": mad(q_values),
                    "zjsMedian": median(z_values),
                    "zjsMAD": mad(z_values),
                    "pairedDeltaMedian": median(deltas),
                    "pairedDeltaMAD": mad(deltas),
                    "pairedRatioMedian": median(ratios),
                    "pairedRatioMAD": mad(ratios),
                }
            results[bench] = {
                "source": {
                    "original": str(original_path),
                    "originalSha256": hashlib.sha256(original).hexdigest(),
                    "fixedSha256": hashlib.sha256(fixed).hexdigest(),
                },
                "runs": runs,
                "metrics": metrics,
            }

    config = subprocess.run([str(zjs), "--print-config-signature"], capture_output=True, text=True, check=True).stdout.strip()
    artifact = {
        "schema": "call-boundary-production-pmu-v1",
        "samplesPerEnginePerBenchmark": args.samples,
        "order": "ABBA by sample parity",
        "firstPositionCounts": first_positions,
        "parallelism": 1,
        "cpu": args.cpu,
        "affinity": affinity,
        "pmu": args.pmu,
        "events": [f"{args.pmu}/{name}/u" for name in EVENT_NAMES],
        "iterationDivisor": args.iteration_divisor,
        "binaries": {
            "zjs": {"path": str(zjs), "sha256": sha256(zjs), "configSignature": config},
            "qjs": {"path": str(qjs), "sha256": sha256(qjs)},
        },
        "benchmarks": results,
        "orderLog": order_log,
    }
    Path(args.output).write_text(json.dumps(artifact, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
