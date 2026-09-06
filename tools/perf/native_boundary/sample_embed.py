#!/usr/bin/env python3
"""Embedding-surface twin of sample.py: zjs-boundary-bench vs qjs-boundary-bench.
Usage: sample_embed.py --samples 4 --out nb-embed.csv --zjs zig-out/bin/zjs-boundary-bench \
         --qjs /tmp/qjs-boundary-bench --plugin zig-out/lib/libzjs-runtime-plugin-fixture.so
       sample_embed.py --report nb-embed.csv
       sample_embed.py --diff before.csv after.csv
Per-call cost = (case - ctrl) / N for the JS-loop cases; for the host-loop cases (n2j*, site*,
prop_site) it is (case - base)/N where base is the same harness run with N=0 (process + engine
startup). Each engine binary is probed with `--list` first; cases it does not list, and cases
that exit with code 2 (unsupported), are skipped instead of failing the sample.
"""
import argparse, csv, statistics, subprocess, sys, os
from collections import defaultdict
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from measure_fields import single_cpu

N = 20_000_000
CASES = ["ctrl", "builtin", "host2", "host0", "hostm2", "plugin2", "n2j1", "n2j0",
         # B-group arms (docs/perf/native-boundary-design.md section 12)
         "leaf2", "leaf_state", "method_typed", "method_managed", "getter_native", "getter_typed",
         "site1", "site0", "prop_site"]
# host-loop cases: the loop runs in the embedder, so no JS ctrl loop is subtracted
HOST_LOOP = {"n2j1", "n2j0", "site1", "site0", "prop_site"}
UNSUPPORTED_RC = 2

def run(argv, cpu):
    p = subprocess.run(["taskset", "-c", str(cpu), "perf", "stat", "-x,", "-e", "instructions,cycles", *argv],
                       capture_output=True, text=True, timeout=600)
    if p.returncode == UNSUPPORTED_RC:
        return None
    ins = cyc = None
    for line in p.stderr.splitlines():
        parts = line.split(",")
        if len(parts) < 3 or parts[0] in ("<not counted>", ""): continue
        if "instructions" in parts[2]: ins = int(parts[0])
        elif "cycles" in parts[2]: cyc = int(parts[0])
    if p.returncode != 0 or ins is None:
        raise RuntimeError(f"{argv}: rc={p.returncode} {p.stderr[-300:]} {p.stdout[-200:]}")
    return ins, cyc, p.stdout.strip()

def probe_supported(binary):
    """Case names the binary lists with --list, or None when it predates --list (then rc 2 decides)."""
    p = subprocess.run([binary, "--list"], capture_output=True, text=True, timeout=60)
    if p.returncode != 0:
        return None
    return {line.strip() for line in p.stdout.splitlines() if line.strip()}

def per_crossing(path):
    """{engine: {case: (insn, cycles)}} per crossing, medians over samples."""
    rows = defaultdict(lambda: defaultdict(list))
    for r in csv.DictReader(open(path)):
        rows[r["engine"]][(r["case"], int(r["n"]))].append((int(r["instructions"]), int(r["cycles"])))
    per = {}
    for e in rows:
        med = {k: (statistics.median(x[0] for x in v), statistics.median(x[1] for x in v)) for k, v in rows[e].items()}
        base = med[("ctrl", 0)]
        ctrl = ((med[("ctrl", N)][0] - base[0]) / N, (med[("ctrl", N)][1] - base[1]) / N)
        per[e] = {}
        for c in CASES:
            if (c, N) not in med: continue
            if c in HOST_LOOP:
                per[e][c] = ((med[(c, N)][0] - base[0]) / N, (med[(c, N)][1] - base[1]) / N)
            else:
                per[e][c] = ((med[(c, N)][0] - base[0]) / N - ctrl[0], (med[(c, N)][1] - base[1]) / N - ctrl[1])
    return per

def report(path):
    per = per_crossing(path)
    engines = list(per)
    print("| case | " + " | ".join(f"{e} insn/cyc" for e in engines) + " | qjs/zjs cyc |")
    print("|---|" + "---|" * (len(engines) + 1))
    for c in CASES[1:]:
        if not any(c in per[e] for e in engines): continue
        cells = [f"{per[e][c][0]:.0f} / {per[e][c][1]:.0f}" if c in per[e] else "-" for e in engines]
        ratio = f"{per['qjs'][c][1] / per['zjs'][c][1]:.2f}" if c in per.get("qjs", {}) and c in per.get("zjs", {}) else "-"
        print(f"| {c} | " + " | ".join(cells) + f" | {ratio} |")

def diff(before_path, after_path):
    before, after = per_crossing(before_path), per_crossing(after_path)
    engines = [e for e in before if e in after] + [e for e in after if e not in before]
    print("| engine | case | before insn/cyc | after insn/cyc | after/before cyc |")
    print("|---|---|---|---|---|")
    for e in engines:
        b, a = before.get(e, {}), after.get(e, {})
        for c in CASES[1:]:
            if c not in b and c not in a: continue
            bc = f"{b[c][0]:.0f} / {b[c][1]:.0f}" if c in b else "-"
            ac = f"{a[c][0]:.0f} / {a[c][1]:.0f}" if c in a else "-"
            ratio = f"{a[c][1] / b[c][1]:.2f}" if c in a and c in b and b[c][1] > 0 else "-"
            print(f"| {e} | {c} | {bc} | {ac} | {ratio} |")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", type=int, default=4); ap.add_argument("--cpu", type=int)
    ap.add_argument("--out"); ap.add_argument("--report")
    ap.add_argument("--diff", nargs=2, metavar=("BEFORE", "AFTER"))
    ap.add_argument("--zjs"); ap.add_argument("--qjs"); ap.add_argument("--plugin")
    a = ap.parse_args()
    if a.report:
        report(a.report)
        return
    if a.diff:
        diff(*a.diff)
        return
    if not a.out or not (a.zjs or a.qjs):
        sys.exit("need --out and at least one of --zjs / --qjs")
    _, cpu, _ = single_cpu(None, a.cpu)
    engines = [(label, [path]) for label, path in (("zjs", a.zjs), ("qjs", a.qjs)) if path]
    supported = {label: probe_supported(argv[0]) for label, argv in engines}
    for label, cases in supported.items():
        listed = "no --list (exit code 2 decides)" if cases is None else " ".join(c for c in CASES if c in cases)
        print(f"{label}: {listed}", flush=True)
    jobs = [("ctrl", 0)] + [(c, N) for c in CASES]
    outputs = {}
    skipped = set()
    with open(a.out, "w", newline="") as fh:
        w = csv.writer(fh); w.writerow(["engine", "case", "n", "sample", "instructions", "cycles"])
        for s in range(1, a.samples + 1):
            for label, argv in (engines if s % 2 else engines[::-1]):
                for case, n in (jobs if s % 2 else jobs[::-1]):
                    if (label, case) in skipped: continue
                    if supported[label] is not None and case not in supported[label]: continue
                    if case == "plugin2" and not a.plugin: continue
                    extra = [a.plugin] if case == "plugin2" else []
                    res = run(argv + [case, str(n)] + extra, cpu)
                    if res is None:
                        skipped.add((label, case))
                        print(f"[{s}/{a.samples}] {label} {case:14s} skipped (unsupported)", flush=True)
                        continue
                    ins, cyc, out = res
                    key = (case, n)
                    if key in outputs and outputs[key] != out and case != "plugin2":
                        sys.exit(f"stdout mismatch {key}: {label} {out!r} vs {outputs[key]!r}")
                    outputs[key] = out
                    w.writerow([label, case, n, s, ins, cyc]); fh.flush()
                    print(f"[{s}/{a.samples}] {label} {case:14s} n={n:<9d} {cyc/1e6:9.1f} Mcyc", flush=True)

if __name__ == "__main__":
    main()
