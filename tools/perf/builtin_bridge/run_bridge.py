#!/usr/bin/env python3
"""P7-41 collector: paired instruction/cycle counts for the builtin-bridge corpus.

Same discipline as the P7-40 collector:

* one case at a time; inside a case the two engines interleave ABBA so the pair
  stays adjacent in time, and the exclusive host lock is taken per case so
  sibling audit lines are not blocked for the whole sweep;
* sample counts must be even (odd ABBA counts have voided headlines twice in
  this campaign);
* events carry an explicit PMU prefix, because this host is big.LITTLE with two
  PMUs and an unqualified `-e cycles` emits a `<not counted>` row for the PMU
  the pinned core is not on;
* stdout is compared between the two engines for every run.
"""

import argparse
import json
import os
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")
sys.path.insert(0, os.path.dirname(HERE))
from measure_fields import field_metadata, measurement_lock, single_cpu


def parse_perf(stderr_text, events):
    out = {}
    for line in stderr_text.splitlines():
        parts = line.split(",")
        if len(parts) < 3:
            continue
        raw, _unit, ev = parts[0], parts[1], parts[2]
        if ev not in events:
            continue
        if "not counted" in raw or "not supported" in raw:
            raise RuntimeError("perf row not counted: " + line)
        out[ev] = float(raw)
    missing = [e for e in events if e not in out]
    if missing:
        raise RuntimeError("missing perf rows: " + ",".join(missing))
    return out


def run_once(engine_bin, script, cpu, events):
    cmd = ["taskset", "-c", str(cpu), "perf", "stat", "-x,",
           "-e", ",".join(events), "--", engine_bin, script]
    t0 = time.perf_counter()
    proc = subprocess.run(cmd, capture_output=True, text=True)
    wall = time.perf_counter() - t0
    if proc.returncode != 0:
        raise RuntimeError(f"{engine_bin} {script} failed: {proc.stderr[-400:]}")
    vals = parse_perf(proc.stderr, events)
    vals["wall_s"] = wall
    vals["stdout"] = proc.stdout.strip()
    return vals


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zjs", required=True)
    ap.add_argument("--qjs", default="/home/aneryu/quickjs/qjs")
    ap.add_argument("--field", choices=("a", "b", "host"), default=None)
    ap.add_argument("--cpu", type=int, default=None,
                    help="legacy CPU override; noncanonical values are diagnostic-only")
    ap.add_argument("--samples", type=int, default=6)
    ap.add_argument("--pmu", default="armv8_pmuv3_1")
    ap.add_argument("--cases", default=None,
                    help="comma-separated subset; default is the timing corpus")
    ap.add_argument("--label", default="A")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    try:
        measure_field, args.cpu, field_conforming = single_cpu(args.field, args.cpu)
    except ValueError as error:
        ap.error(str(error))

    if args.samples % 2 != 0:
        sys.exit("samples must be even (ABBA balance)")

    events = [f"{args.pmu}/instructions/", f"{args.pmu}/cycles/", "task-clock"]
    meta = json.load(open(os.path.join(HERE, "cases.json")))
    skip = set(meta["perf_only"]) | set(meta["count_only"])
    names = (args.cases.split(",") if args.cases
             else [n for n in meta["cases"] if n not in skip])

    zjs = os.path.abspath(args.zjs)
    qjs = os.path.abspath(args.qjs)
    results = {}
    first_positions = {"qjs": 0, "zjs": 0}

    for name in names:
        script = os.path.join(CASES, name + ".js")
        samples = {"qjs": [], "zjs": []}
        outputs = {"qjs": set(), "zjs": set()}
        with measurement_lock(measure_field):
            for s in range(args.samples):
                order = ("qjs", "zjs") if s % 2 == 0 else ("zjs", "qjs")
                first_positions[order[0]] += 1
                for eng in order:
                    binary = qjs if eng == "qjs" else zjs
                    v = run_once(binary, script, args.cpu, events)
                    outputs[eng].add(v.pop("stdout"))
                    samples[eng].append(v)

        rec = {"case": name,
               "iterations": meta["iterations"].get(name, 1),
               "elements_per_iteration": meta["elements_per_iteration"].get(name, 0),
               "callback_count": meta["callback_count"].get(name, 0),
               "outputs": {e: sorted(outputs[e]) for e in outputs},
               "output_match": outputs["qjs"] == outputs["zjs"]}
        for eng in ("qjs", "zjs"):
            ins = [x[events[0]] for x in samples[eng]]
            cyc = [x[events[1]] for x in samples[eng]]
            tc = [x["task-clock"] / 1e6 for x in samples[eng]]
            rec[eng] = {
                "instructions_median": statistics.median(ins),
                "instructions_samples": ins,
                "cycles_median": statistics.median(cyc),
                "cycles_samples": cyc,
                "task_clock_ms_median": statistics.median(tc),
            }
        rec["paired_instruction_ratios"] = [
            samples["zjs"][i][events[0]] / samples["qjs"][i][events[0]]
            for i in range(args.samples)]
        rec["paired_cycle_ratios"] = [
            samples["zjs"][i][events[1]] / samples["qjs"][i][events[1]]
            for i in range(args.samples)]
        results[name] = rec
        qi = rec["qjs"]["instructions_median"]
        zi = rec["zjs"]["instructions_median"]
        qc = rec["qjs"]["cycles_median"]
        zc = rec["zjs"]["cycles_median"]
        print(f"{name:22s} insn q={qi:>13.0f} z={zi:>13.0f} r={zi/qi:.3f} "
              f"cyc q={qc:>12.0f} z={zc:>12.0f} r={zc/qc:.3f} "
              f"{'' if rec['output_match'] else 'OUTPUT-MISMATCH'}", flush=True)

    payload = {
        "collector": "tools/perf/builtin_bridge/run_bridge.py",
        "build_label": args.label,
        "cpu": args.cpu,
        "measurement_field": {
            **field_metadata(measure_field, "single"),
            "fieldConforming": field_conforming,
            "lockAttested": True,
        },
        "pmu": args.pmu,
        "samples_per_case_per_engine": args.samples,
        "sampling_order": "ABBA, per case, canonical measurement-field lock held per case",
        "first_position_counts": first_positions,
        "first_position_balanced":
            first_positions["qjs"] == first_positions["zjs"],
        "zjs_binary": zjs,
        "qjs_binary": qjs,
        "events": events,
        "cases": results,
    }
    with open(args.out, "w") as fh:
        json.dump(payload, fh, indent=1)
        fh.write("\n")
    print("wrote", args.out)


if __name__ == "__main__":
    main()
