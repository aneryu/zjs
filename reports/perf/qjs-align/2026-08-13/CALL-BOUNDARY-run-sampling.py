#!/usr/bin/env python3
"""Flat fixed-period call-entry/return sampling on frozen production binaries."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import tempfile


DSO_OFFSET = re.compile(r"\((?P<dso>.+)\+0x(?P<offset>[0-9a-fA-F]+)\)$")
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


def addr2lines(binary: Path, offsets: set[int]) -> dict[int, int | None]:
    result: dict[int, int | None] = {}
    ordered = sorted(offsets)
    for start in range(0, len(ordered), 500):
        chunk = ordered[start : start + 500]
        proc = subprocess.run(
            ["addr2line", "-e", str(binary), *[hex(value) for value in chunk]],
            capture_output=True,
            text=True,
            check=True,
        )
        lines = proc.stdout.splitlines()
        if len(lines) != len(chunk):
            raise RuntimeError("addr2line output length mismatch")
        for offset, location in zip(chunk, lines):
            match = re.search(r":(\d+)(?:\s|$)", location)
            result[offset] = int(match.group(1)) if match else None
    return result


def classify_zjs(symbol: str) -> str | None:
    return_markers = (
        "exec.tailcall_dispatch.op_return",
        "exec.tailcall_dispatch.op_return_undef",
        "exec.inline_calls.Machine.popConstructorReturn",
        "exec.frame.Frame.freeCold",
        "exec.vm_call.CallProfileGuard.deinit",
        "reloadAfterPop",
    )
    if any(marker in symbol for marker in return_markers):
        return "return"
    entry_markers = (
        "exec.vm_call.nativeMethodFastDispatch",
        "exec.builtin_dispatch.callTypedInternalRecordDirect",
        "exec.builtin_dispatch.callInternalRecord",
        "exec.frame.Frame.captureLocal",
        "exec.frame.ensureVarRefsCapacity",
        "exec.inline_calls.Machine.setup",
        "exec.inline_calls.Machine.push",
        "exec.call_runtime.call",
        "exec.call_runtime.execCall",
        "exec.call_runtime.runSyncInlineRoute",
        "exec.call_runtime.SyncInternalCallSite.call",
        "exec.call_runtime.qjsFunctionApply",
        "exec.call_runtime.constructValueOrBytecode",
        "exec.call_runtime.prepareSameMachineConstructor",
        "exec.call_runtime.functionNameValueFromAtom",
        "exec.call_runtime.ordinaryHasInstance",
        "exec.call_runtime.prototypeChainBlocksSimpleFieldStore",
    )
    if any(marker in symbol for marker in entry_markers):
        return "entry"
    return None


def classify_qjs(symbol: str, line: int | None) -> str | None:
    if symbol == "JS_CallInternal":
        if line is not None and 17746 <= line <= 17872:
            return "entry"
        if line is not None and (
            18266 <= line <= 18271
            or 20694 <= line <= 20704
            or 20709 <= line <= 20710
        ):
            return "return"
        return None
    if symbol == "js_call_c_function":
        if line is not None and 17686 <= line <= 17688:
            return "return"
        return "entry"
    if symbol in {"JS_CallFree", "JS_CallConstructorInternal"}:
        return "entry"
    return None


def parse_samples(engine: str, binary: Path, data: Path) -> dict:
    proc = subprocess.run(
        ["perf", "script", "-i", str(data), "-F", "ip,dsoff,sym,dso"],
        capture_output=True,
        text=True,
        check=True,
    )
    rows: list[tuple[str, int | None]] = []
    q_offsets: set[int] = set()
    binary_resolved = binary.resolve()
    for raw in proc.stdout.splitlines():
        fields = raw.strip().split(maxsplit=2)
        if len(fields) < 3:
            continue
        symbol = fields[1].split("+", 1)[0]
        match = DSO_OFFSET.search(fields[2])
        offset: int | None = None
        if match and Path(match.group("dso")).resolve() == binary_resolved:
            offset = int(match.group("offset"), 16)
            if engine == "qjs" and symbol in {"JS_CallInternal", "js_call_c_function"}:
                q_offsets.add(offset)
        rows.append((symbol, offset))

    line_map = addr2lines(binary, q_offsets) if engine == "qjs" else {}
    categories = Counter()
    symbols: dict[str, Counter[str]] = {"entry": Counter(), "return": Counter()}
    unresolved_qjs_call_samples = 0
    for symbol, offset in rows:
        category = (
            classify_qjs(symbol, line_map.get(offset) if offset is not None else None)
            if engine == "qjs"
            else classify_zjs(symbol)
        )
        if category is None:
            if engine == "qjs" and symbol in {"JS_CallInternal", "js_call_c_function"} and offset is None:
                unresolved_qjs_call_samples += 1
            continue
        categories[category] += 1
        symbols[category][symbol] += 1
    return {
        "totalSamples": len(rows),
        "entrySamples": categories["entry"],
        "returnSamples": categories["return"],
        "unresolvedQjsCallSamples": unresolved_qjs_call_samples,
        "entrySymbols": dict(symbols["entry"].most_common()),
        "returnSymbols": dict(symbols["return"].most_common()),
    }


def run_one(binary: Path, source: Path, engine: str, event: str, period: int, timeout: int, tmp: Path) -> dict:
    data = tmp / f"{engine}.data"
    proc = subprocess.run(
        ["perf", "record", "--no-buildid", "-e", event, "-c", str(period), "-o", str(data), "--", str(binary), str(source)],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"perf record/{engine} exited {proc.returncode}: {proc.stderr[-500:]}")
    parsed = parse_samples(engine, binary, data)
    parsed["stdout"] = proc.stdout
    parsed["perfRecordStderr"] = proc.stderr
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default="/home/aneryu/worktree-call-boundary")
    parser.add_argument("--zoo", default="/home/aneryu/javascript-zoo")
    parser.add_argument("--zjs", required=True)
    parser.add_argument("--qjs", required=True)
    parser.add_argument("--cpu", type=int, default=19)
    parser.add_argument("--pmu", default="armv8_pmuv3_1")
    parser.add_argument("--period", type=int, default=65521)
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

    event = f"{args.pmu}/cycles/u"
    results: dict[str, dict] = {}
    order_log: list[dict] = []
    first_positions = {"qjs": 0, "zjs": 0}
    with tempfile.TemporaryDirectory(prefix="call-boundary-sampling-") as tmp_name:
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
                    run_tmp = tmp / f"{bench}-{sample}-{engine}"
                    run_tmp.mkdir()
                    rec = run_one(qjs if engine == "qjs" else zjs, source, engine, event, args.period, args.timeout, run_tmp)
                    if not has_score(rec["stdout"]):
                        raise RuntimeError(f"{bench}/{engine}: no benchmark score in stdout")
                    runs[engine].append(rec)
                    print(
                        f"{bench:14} {sample + 1}/{args.samples} {engine:4} "
                        f"entry={rec['entrySamples']:,} return={rec['returnSamples']:,} "
                        f"total={rec['totalSamples']:,}",
                        file=sys.stderr,
                    )

            metrics: dict[str, dict] = {}
            for category in ("entry", "return"):
                field = f"{category}Samples"
                q_values = [record[field] * args.period for record in runs["qjs"]]
                z_values = [record[field] * args.period for record in runs["zjs"]]
                deltas = [z - q for z, q in zip(z_values, q_values)]
                metrics[category] = {
                    "qjsMedianApproxCycles": median(q_values),
                    "qjsMADApproxCycles": mad(q_values),
                    "zjsMedianApproxCycles": median(z_values),
                    "zjsMADApproxCycles": mad(z_values),
                    "pairedDeltaMedian": median(deltas),
                    "pairedDeltaMAD": mad(deltas),
                    "positiveDeltaSamples": sum(delta > 0 for delta in deltas),
                    "pairedDeltas": deltas,
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

    artifact = {
        "schema": "call-boundary-fixed-period-sampling-v1",
        "classificationContract": {
            "scope": "flat self samples; entry and return are disjoint; all unclassified samples excluded",
            "qjs": "address-resolved JS_CallInternal 17746-17872 entry; OP_return/OP_return_undef 18266-18271 plus frame done/restore 20694-20704 and 20709-20710 return; RC teardown 20705-20708 excluded; all js_call_c_function self samples are entry except restore lines 17686-17688 return; JS_CallFree/JS_CallConstructorInternal entry",
            "zjs": "mechanism-level entry helpers matching PdfJS P1 plus op_return/op_return_undef and explicit pop/reload helpers as return",
        },
        "samplesPerEnginePerBenchmark": args.samples,
        "order": "ABBA by sample parity",
        "firstPositionCounts": first_positions,
        "parallelism": 1,
        "cpu": args.cpu,
        "affinity": affinity,
        "event": event,
        "period": args.period,
        "iterationDivisor": args.iteration_divisor,
        "binaries": {
            "zjs": {"path": str(zjs), "sha256": sha256(zjs)},
            "qjs": {"path": str(qjs), "sha256": sha256(qjs)},
        },
        "benchmarks": results,
        "orderLog": order_log,
    }
    Path(args.output).write_text(json.dumps(artifact, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
