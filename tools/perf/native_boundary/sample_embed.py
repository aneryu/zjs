#!/usr/bin/env python3
"""Embedding-surface twin of sample.py: zjs-boundary-bench vs qjs-boundary-bench.
Usage: sample_embed.py --samples 4 --out nb-embed.csv --zjs zig-out/bin/zjs-boundary-bench \
         --qjs /tmp/qjs-boundary-bench --plugin zig-out/lib/libzjs-runtime-plugin-fixture.so
       sample_embed.py --report nb-embed.csv
Per-call cost = (case - ctrl) / N for the JS-loop cases; for n2j* it is (case - n2j_base)/N where
n2j_base is the same harness run with N=0 (process + engine startup).
"""
import argparse, csv, statistics, subprocess, sys, os
from collections import defaultdict
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from measure_fields import single_cpu

N = 20_000_000
CASES = ["ctrl", "builtin", "host2", "host0", "hostm2", "plugin2", "n2j1", "n2j0"]

def run(argv, cpu):
    p = subprocess.run(["taskset", "-c", str(cpu), "perf", "stat", "-x,", "-e", "instructions,cycles", *argv],
                       capture_output=True, text=True, timeout=600)
    ins = cyc = None
    for line in p.stderr.splitlines():
        parts = line.split(",")
        if len(parts) < 3 or parts[0] in ("<not counted>", ""): continue
        if "instructions" in parts[2]: ins = int(parts[0])
        elif "cycles" in parts[2]: cyc = int(parts[0])
    if p.returncode != 0 or ins is None:
        raise RuntimeError(f"{argv}: rc={p.returncode} {p.stderr[-300:]} {p.stdout[-200:]}")
    return ins, cyc, p.stdout.strip()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", type=int, default=4); ap.add_argument("--cpu", type=int)
    ap.add_argument("--out"); ap.add_argument("--report")
    ap.add_argument("--zjs"); ap.add_argument("--qjs"); ap.add_argument("--plugin")
    a = ap.parse_args()
    if a.report:
        rows = defaultdict(lambda: defaultdict(list))
        for r in csv.DictReader(open(a.report)):
            rows[r["engine"]][(r["case"], int(r["n"]))].append((int(r["instructions"]), int(r["cycles"])))
        per = {}
        for e in rows:
            med = {k: (statistics.median(x[0] for x in v), statistics.median(x[1] for x in v)) for k, v in rows[e].items()}
            base = med[("ctrl", 0)]
            ctrl = ((med[("ctrl", N)][0] - base[0]) / N, (med[("ctrl", N)][1] - base[1]) / N)
            per[e] = {}
            for c in CASES:
                if (c, N) not in med: continue
                if c.startswith("n2j"):
                    per[e][c] = ((med[(c, N)][0] - base[0]) / N, (med[(c, N)][1] - base[1]) / N)
                else:
                    per[e][c] = ((med[(c, N)][0] - base[0]) / N - ctrl[0], (med[(c, N)][1] - base[1]) / N - ctrl[1])
        engines = list(per)
        print("| case | " + " | ".join(f"{e} insn/cyc" for e in engines) + " | qjs/zjs cyc |")
        print("|---|" + "---|" * (len(engines) + 1))
        for c in CASES[1:]:
            cells = [f"{per[e][c][0]:.0f} / {per[e][c][1]:.0f}" if c in per[e] else "-" for e in engines]
            ratio = f"{per['qjs'][c][1] / per['zjs'][c][1]:.2f}" if c in per.get("qjs", {}) and c in per.get("zjs", {}) else "-"
            print(f"| {c} | " + " | ".join(cells) + f" | {ratio} |")
        return
    _, cpu, _ = single_cpu(None, a.cpu)
    engines = [("zjs", [a.zjs]), ("qjs", [a.qjs])]
    jobs = [("ctrl", 0)] + [(c, N) for c in CASES]
    outputs = {}
    with open(a.out, "w", newline="") as fh:
        w = csv.writer(fh); w.writerow(["engine", "case", "n", "sample", "instructions", "cycles"])
        for s in range(1, a.samples + 1):
            for label, argv in (engines if s % 2 else engines[::-1]):
                for case, n in (jobs if s % 2 else jobs[::-1]):
                    if case in ("plugin2", "hostm2") and label == "qjs": continue
                    extra = [a.plugin] if case == "plugin2" else []
                    ins, cyc, out = run(argv + [case, str(n)] + extra, cpu)
                    key = (case, n)
                    if key in outputs and outputs[key] != out and case != "plugin2":
                        sys.exit(f"stdout mismatch {key}: {label} {out!r} vs {outputs[key]!r}")
                    outputs[key] = out
                    w.writerow([label, case, n, s, ins, cyc]); fh.flush()
                    print(f"[{s}/{a.samples}] {label} {case:8s} n={n:<9d} {cyc/1e6:9.1f} Mcyc", flush=True)

if __name__ == "__main__":
    main()
