#!/usr/bin/env python3
"""JS<->native boundary microbench sampler (multi-engine).

Usage:
  sample.py --samples 4 --out /tmp/nb.csv zjs=./zig-out/bin/zjs qjs=/path/qjs \
            "v8=/path/d8 --jitless" "jsc=/path/jsc --useJIT=false" hermes=/path/hermes
  sample.py --report /tmp/nb.csv [--base zjs]

Discipline (same as tools/perf/callshapes/sample.sh): even sample count, engine
and case order reversed on even samples (ABBA), pinned to the measurement CPU,
perf stat instructions/cycles/task-clock with the big-core PMU rows only, stdout
of every run compared across engines (a checksum mismatch aborts).

Report: per-iteration cost = (case - empty) / N, minus (ctrl - empty) / N_ctrl,
where N is the case's own iteration count (read from `var N = ...`). Cases with
several boundary crossings per iteration (C1..C5, N5) divide by the crossing
count noted in `PER_ITER` so the printed number is per crossing.
"""
import argparse
import csv
import os
import re
import shlex
import statistics
import subprocess
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
CASES_DIR = os.path.join(HERE, "cases")
sys.path.insert(0, os.path.dirname(HERE))
from measure_fields import single_cpu  # noqa: E402

CASES = ["empty", "ctrl",
         "N1_abs_hoisted", "N1m_abs_method", "N2_max3_variadic", "N3_charcodeat",
         "N3b_charat", "N3c_at", "N3d_codepointat",
         "N4_hasown_string", "N5_push_pop", "N6_fcall", "N7_fapply",
         "C1_foreach8", "C2_reduce8", "C3_map8", "C4_sort8", "C5_replace_fn"]
# crossings per loop iteration (JS->native call or native->JS callback)
PER_ITER = {"N5_push_pop": 2, "C1_foreach8": 8, "C2_reduce8": 8, "C3_map8": 8,
            "C4_sort8": 12, "C5_replace_fn": 2}


def case_n(case):
    src = open(os.path.join(CASES_DIR, case + ".js")).read()
    m = re.search(r"var N = (\d+);", src)
    return int(m.group(1)) if m else 1


def run_one(argv, script, cpu):
    cmd = ["taskset", "-c", str(cpu), "perf", "stat", "-x,", "-e",
           "instructions,cycles,task-clock", *argv, script]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    ins = cyc = tc = None
    for line in p.stderr.splitlines():
        parts = line.split(",")
        if len(parts) < 3 or parts[0] in ("<not counted>", ""):
            continue
        if "instructions" in parts[2]:
            ins = int(parts[0])
        elif "cycles" in parts[2]:
            cyc = int(parts[0])
        elif parts[2] == "task-clock":
            tc = float(parts[0])
    if p.returncode != 0 or ins is None:
        raise RuntimeError(f"{argv} {script}: rc={p.returncode} stderr={p.stderr[-400:]}")
    return ins, cyc, tc, p.stdout.strip()


def sample(args):
    engines = []
    for spec in args.engines:
        label, _, rest = spec.partition("=")
        engines.append((label, shlex.split(rest)))
    if args.samples % 2:
        sys.exit("sample count must be even")
    _, cpu, _ = single_cpu(None, args.cpu)
    outputs = {}
    with open(args.out, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["engine", "case", "sample", "instructions", "cycles", "task_clock_ms"])
        for s in range(1, args.samples + 1):
            eng_order = engines if s % 2 else engines[::-1]
            case_order = CASES if s % 2 else CASES[::-1]
            for label, argv in eng_order:
                for case in case_order:
                    ins, cyc, tc, out = run_one(argv, os.path.join(CASES_DIR, case + ".js"), cpu)
                    key = case
                    if key in outputs and outputs[key] != out:
                        sys.exit(f"stdout mismatch on {case}: {label} printed {out!r}, expected {outputs[key]!r}")
                    outputs[key] = out
                    w.writerow([label, case, s, ins, cyc, f"{tc:.3f}"])
                    fh.flush()
                    print(f"[{s}/{args.samples}] {label:7s} {case:18s} {cyc/1e6:10.1f} Mcyc", flush=True)


def report(args):
    rows = defaultdict(lambda: defaultdict(list))
    with open(args.report) as fh:
        for r in csv.DictReader(fh):
            rows[r["engine"]][r["case"]].append((int(r["instructions"]), int(r["cycles"])))
    engines = list(rows)
    per = {}
    for e in engines:
        med = {c: (statistics.median(x[0] for x in v), statistics.median(x[1] for x in v)) for c, v in rows[e].items()}
        e_ins, e_cyc = med["empty"]
        n_ctrl = case_n("ctrl")
        ctrl_ins = (med["ctrl"][0] - e_ins) / n_ctrl
        ctrl_cyc = (med["ctrl"][1] - e_cyc) / n_ctrl
        per[e] = {}
        for c in CASES[2:]:
            if c not in med:
                continue
            n = case_n(c)
            k = PER_ITER.get(c, 1)
            per[e][c] = (((med[c][0] - e_ins) / n - ctrl_ins) / k,
                         ((med[c][1] - e_cyc) / n - ctrl_cyc) / k)
    base = args.base if args.base in per else engines[0]
    hdr = "| case | " + " | ".join(f"{e} insn/cyc" for e in engines) + " | " + " | ".join(f"{e}/{base} cyc" for e in engines if e != base) + " |"
    print(hdr)
    print("|" + "---|" * (hdr.count("|") - 1))
    for c in CASES[2:]:
        cells = []
        for e in engines:
            if c in per[e]:
                cells.append(f"{per[e][c][0]:.0f} / {per[e][c][1]:.0f}")
            else:
                cells.append("-")
        ratios = []
        for e in engines:
            if e == base:
                continue
            if c in per[e] and c in per[base] and per[base][c][1] > 0:
                ratios.append(f"{per[e][c][1] / per[base][c][1]:.2f}")
            else:
                ratios.append("-")
        print(f"| {c} | " + " | ".join(cells) + " | " + " | ".join(ratios) + " |")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", type=int, default=4)
    ap.add_argument("--cpu", type=int, default=None)
    ap.add_argument("--out")
    ap.add_argument("--report")
    ap.add_argument("--base", default="zjs")
    ap.add_argument("engines", nargs="*")
    args = ap.parse_args()
    if args.report:
        report(args)
    else:
        if not args.out or not args.engines:
            sys.exit("need --out and engine specs")
        sample(args)


if __name__ == "__main__":
    main()
