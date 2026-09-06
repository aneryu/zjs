import json, statistics, sys, tempfile, time
from pathlib import Path
sys.path.insert(0, "tools/perf/bench_v8")
import run_benchv8_compare as bv8
import run_benchv8_multiengine as me
H = Path("/home/aneryu/hermes/build_release/bin/hermes")
CPU = 19
CONFIGS = {"default": [], "O0": ["-O0"], "O": ["-O"]}
here = Path("tools/perf/bench_v8")
combined = Path(tempfile.mkstemp(suffix=".js")[1])
bv8.build_combined(here / "suite", here / "driver.js", combined)
runs = {k: [] for k in CONFIGS}
N = int(sys.argv[1]) if len(sys.argv) > 1 else 3
names = list(CONFIGS)
for r in range(N):
    order = names if r % 2 == 0 else names[::-1]
    for n in order:
        t = time.time()
        res = me.run_once(H, CONFIGS[n], combined, CPU)
        runs[n].append(res)
        print(f"round {r+1}/{N} {n}: score {res['score']:.0f} ({time.time()-t:.0f}s)", flush=True)
suites = list(runs["default"][0]["suites"])
med = {n: {"score": statistics.median(x["score"] for x in runs[n]),
           "suites": {s: statistics.median(x["suites"][s] for x in runs[n]) for s in suites}} for n in names}
print(f"\n| Suite | " + " | ".join(names) + " | O0/O |")
for s in suites:
    row = [med[n]["suites"][s] for n in names]
    print(f"| {s} | " + " | ".join(f"{v:.0f}" for v in row) + f" | {med['O0']['suites'][s]/med['O']['suites'][s]:.2f} |")
print(f"| Score | " + " | ".join(f"{med[n]['score']:.0f}" for n in names) + f" | {med['O0']['score']/med['O']['score']:.2f} |")
json.dump({"runs": runs, "medians": med, "samples": N}, open("/tmp/hermes_olevels.json", "w"), indent=1)
