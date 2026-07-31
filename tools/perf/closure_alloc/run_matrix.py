#!/usr/bin/env python3
"""P7-50 closure-allocation matrix collector.

Drives the shared same-runtime harnesses (`tools/perf/same_runtime`) over the
P7-50 case matrix. Three independent measurements per (case, engine instance):

wall
    `--iterations I --warmup W`, harness-internal per-sample `clock_gettime`
    around exactly one `run()` call. Reported from the raw `samples_ns` array so
    the phase-alternating `retain` cases can be split into creation-only
    (odd-indexed samples) and release-only (even-indexed samples).

pmu-combined
    whole-process `perf stat` at two iteration counts; the difference removes
    process startup, runtime/context creation, parse and compile exactly, with
    no baseline-subtraction guesswork. Both counts are even so a `retain` delta
    contains equal numbers of fill and clear samples.

pmu-split
    whole-process `perf stat` at three consecutive iteration counts around an
    even warmup, so consecutive differences isolate one fill sample and one
    clear sample. Only meaningful for the `retain` lifetime.

Sampling order is ABBA in the same sense as `run_same_runtime.js`: even sample
index runs qjs first, odd runs zjs first, and the sample count must be even or
the order is left unbalanced.

CPU 19 of this host is on `armv8_pmuv3_1`; the other PMU prints
`<not counted>` and those rows are discarded rather than parsed.
"""

import argparse
import json
import os
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
CASES = os.path.join(REPO, "tools", "perf", "same_runtime", "cases")

SHAPES = [
    "reuse",
    "arrow_nocap",
    "fnexpr_nocap",
    "arrow_cap1",
    "fnexpr_cap1",
    "arrow_cap4",
    "arrow_loopbind",
    "arrow_call",
]
LIFETIMES = ["retain", "churn"]

PMU_EVENTS = "instructions,cycles,task-clock"


def case_name(shape, lifetime):
    return "closure_%s_%s" % (shape, lifetime)


def case_path(name):
    return os.path.join(CASES, name + ".js")


def harness_args(name, iterations, warmup):
    return [
        "--case", name,
        "--source", case_path(name),
        "--iterations", str(iterations),
        "--warmup", str(warmup),
        "--teardown", "normal",
    ]


def run_wall(binary, cpu, name, iterations, warmup):
    proc = subprocess.run(
        ["taskset", "-c", str(cpu), binary] + harness_args(name, iterations, warmup),
        cwd=REPO, capture_output=True, text=True,
    )
    if proc.returncode != 0 or proc.stderr:
        raise RuntimeError(
            "wall run failed for %s %s: rc=%d stderr=%s"
            % (binary, name, proc.returncode, proc.stderr[:2000])
        )
    record = json.loads(proc.stdout)
    return {
        "samples_ns": record["steady_execute"]["samples_ns"],
        "median_ns": record["steady_execute"]["median_ns"],
        "checksum": record["result_checksum"],
        "source_sha256": record["source_sha256"],
        "allocated_bytes": record["resources"].get("allocated_bytes"),
        "malloc_count": record["resources"].get("malloc_count"),
        "allocation_count": record["resources"].get("allocation_count"),
        "peak_rss_bytes": record["resources"].get("peak_rss_bytes"),
    }


def run_pmu(binary, cpu, name, iterations, warmup, tmpdir, pmu_device):
    out = os.path.join(tmpdir, "perf.csv")
    proc = subprocess.run(
        ["perf", "stat", "-x,", "-o", out, "-e", PMU_EVENTS,
         "taskset", "-c", str(cpu), binary] + harness_args(name, iterations, warmup),
        cwd=REPO, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            "perf run failed for %s %s: rc=%d stderr=%s"
            % (binary, name, proc.returncode, proc.stderr[:2000])
        )
    counts = {}
    with open(out) as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split(",")
            if len(fields) < 3:
                continue
            value, _unit, event = fields[0], fields[1], fields[2]
            if value == "<not counted>" or value == "<not supported>":
                continue
            if "/" in event:
                device, inner = event.split("/", 1)
                if device != pmu_device:
                    continue
                event = inner.strip("/")
            key = event.strip()
            if key in counts:
                raise RuntimeError("duplicate counted row for %s" % key)
            counts[key] = float(value)
    for required in ("instructions", "cycles", "task-clock"):
        if required not in counts:
            raise RuntimeError("missing %s row: %s" % (required, counts))
    return counts


def pmu_device_for_cpu(cpu):
    base = "/sys/devices"
    for entry in sorted(os.listdir(base)):
        if not entry.startswith("armv8_pmuv3_"):
            continue
        path = os.path.join(base, entry, "cpus")
        if not os.path.exists(path):
            continue
        with open(path) as handle:
            spec = handle.read().strip()
        for part in spec.split(","):
            if "-" in part:
                lo, hi = part.split("-")
                if int(lo) <= cpu <= int(hi):
                    return entry
            elif int(part) == cpu:
                return entry
    raise RuntimeError("no PMU device found for cpu %d" % cpu)


def median(values):
    return statistics.median(values) if values else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zjs", action="append", required=True,
                        metavar="LABEL=PATH")
    parser.add_argument("--qjs", action="append", required=True,
                        metavar="LABEL=PATH")
    parser.add_argument("--cpu", type=int, default=19)
    parser.add_argument("--wall-samples", type=int, default=6)
    parser.add_argument("--wall-iterations", type=int, default=40)
    parser.add_argument("--warmup", type=int, default=8)
    parser.add_argument("--pmu-repeats", type=int, default=6)
    parser.add_argument("--pmu-lo", type=int, default=12)
    parser.add_argument("--pmu-hi", type=int, default=52)
    parser.add_argument("--split-repeats", type=int, default=8)
    parser.add_argument("--inner", type=int, default=20000,
                        help="N baked into each generated case")
    parser.add_argument("--phases", default="wall,pmu,split")
    parser.add_argument("--shapes", default=",".join(SHAPES))
    parser.add_argument("--lifetimes", default=",".join(LIFETIMES))
    parser.add_argument("--tmpdir", default=os.environ.get("TMPDIR", "/tmp"))
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    if args.wall_samples % 2 != 0:
        raise SystemExit("--wall-samples must be even to balance ABBA")
    if args.warmup % 2 != 0:
        raise SystemExit("--warmup must be even so retain sample 1 is a fill")
    if args.wall_iterations % 2 != 0:
        raise SystemExit("--wall-iterations must be even")
    if args.pmu_lo % 2 != 0 or args.pmu_hi % 2 != 0:
        raise SystemExit("--pmu-lo/--pmu-hi must be even")

    phases = set(p for p in args.phases.split(",") if p)
    shapes = [s for s in args.shapes.split(",") if s]
    lifetimes = [l for l in args.lifetimes.split(",") if l]

    def parse_pairs(items):
        out = []
        for item in items:
            label, _, path = item.partition("=")
            out.append((label, os.path.abspath(path)))
        return out

    zjs = parse_pairs(args.zjs)
    qjs = parse_pairs(args.qjs)
    pmu_device = pmu_device_for_cpu(args.cpu)

    binaries = {}
    for label, path in zjs + qjs:
        digest = subprocess.run(["sha256sum", path], capture_output=True,
                                text=True, check=True).stdout.split()[0]
        binaries[label] = {"path": path, "sha256": digest}

    results = {
        "line": "P7-50",
        "cpu": args.cpu,
        "pmu_device": pmu_device,
        "inner_loop_n": args.inner,
        "warmup": args.warmup,
        "wall": {"iterations": args.wall_iterations,
                 "samples": args.wall_samples, "data": {}},
        "pmu_combined": {"lo": args.pmu_lo, "hi": args.pmu_hi,
                         "repeats": args.pmu_repeats, "data": {}},
        "pmu_split": {"repeats": args.split_repeats, "data": {}},
        "binaries": binaries,
        "cases": [],
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    case_list = [case_name(s, l) for s in shapes for l in lifetimes]
    results["cases"] = case_list

    # ---- wall ---------------------------------------------------------------
    if "wall" in phases:
        for name in case_list:
            for zlabel, zpath in zjs:
                for qlabel, qpath in qjs:
                    key = "%s|%s|%s" % (name, zlabel, qlabel)
                    series = {"zjs": [], "qjs": [], "orders": []}
                    for sample in range(args.wall_samples):
                        order = (["qjs", "zjs"] if sample % 2 == 0
                                 else ["zjs", "qjs"])
                        series["orders"].append("->".join(order))
                        for engine in order:
                            binary = qpath if engine == "qjs" else zpath
                            rec = run_wall(binary, args.cpu, name,
                                           args.wall_iterations, args.warmup)
                            series[engine].append(rec)
                    results["wall"]["data"][key] = series
                    print("wall %s done" % key, file=sys.stderr)

    # ---- pmu combined -------------------------------------------------------
    if "pmu" in phases:
        for name in case_list:
            for label in list(binaries):
                key = "%s|%s" % (name, label)
                series = {"lo": [], "hi": []}
                for _ in range(args.pmu_repeats):
                    for tag, iters in (("lo", args.pmu_lo), ("hi", args.pmu_hi)):
                        series[tag].append(run_pmu(
                            binaries[label]["path"], args.cpu, name, iters,
                            args.warmup, args.tmpdir, pmu_device))
                results["pmu_combined"]["data"][key] = series
                print("pmu %s done" % key, file=sys.stderr)

    # ---- pmu split (retain only) -------------------------------------------
    if "split" in phases:
        for shape in shapes:
            name = case_name(shape, "retain")
            for label in list(binaries):
                key = "%s|%s" % (name, label)
                series = {"i0": [], "i1": [], "i2": []}
                base = args.pmu_lo
                for _ in range(args.split_repeats):
                    for tag, iters in (("i0", base), ("i1", base + 1),
                                       ("i2", base + 2)):
                        series[tag].append(run_pmu(
                            binaries[label]["path"], args.cpu, name, iters,
                            args.warmup, args.tmpdir, pmu_device))
                results["pmu_split"]["data"][key] = series
                print("split %s done" % key, file=sys.stderr)

    # ---- live bytes / live allocation count per retained closure -----------
    # The retain lifetime makes this exact: `--iterations 1 --warmup 0` ends on
    # a fill, so N closures are live when the harness samples its allocator
    # accounting; `--iterations 2` ends on a clear, so none are. The difference
    # is the resident cost of N closures with every fixed cost cancelled.
    if "bytes" in phases:
        results["bytes"] = {"data": {}}
        for shape in shapes:
            name = case_name(shape, "retain")
            for label in list(binaries):
                filled = run_wall(binaries[label]["path"], args.cpu, name, 1, 0)
                empty = run_wall(binaries[label]["path"], args.cpu, name, 2, 0)
                entry = {"filled": filled, "empty": empty}
                for field in ("allocated_bytes", "malloc_count",
                              "allocation_count"):
                    if filled.get(field) is None or empty.get(field) is None:
                        entry[field + "_per_op"] = None
                    else:
                        entry[field + "_per_op"] = (
                            filled[field] - empty[field]) / args.inner
                results["bytes"]["data"]["%s|%s" % (name, label)] = entry
                print("bytes %s|%s done" % (name, label), file=sys.stderr)

    results["finished_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with open(args.out, "w") as handle:
        json.dump(results, handle, indent=1)
    print(args.out)


if __name__ == "__main__":
    main()
