import json, statistics, sys, tempfile, time
from pathlib import Path
sys.path.insert(0, "tools/perf/bench_v8")
import run_benchv8_compare as bv8
import run_benchv8_multiengine as me
H = Path("/home/aneryu/hermes/build_release/bin/hermes")
CPU = 19
BASE = ["-Xcustom-opt=" + p for p in "simplemem2reg simplestackpromotion frameloadstoreopts scopeelimination dce simplifycfg".split()]
CONFIGS = {"base": BASE,
           "base_ti": BASE + ["-Xcustom-opt=typeinference", "-Xcustom-opt=instsimplify"],
           "base_inl": BASE + ["-Xcustom-opt=functionanalysis", "-Xcustom-opt=inlining", "-Xcustom-opt=dce"]}
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
suites = list(runs[names[0]][0]["suites"])
med = {n: {"score": statistics.median(x["score"] for x in runs[n]),
           "suites": {s: statistics.median(x["suites"][s] for x in runs[n]) for s in suites}} for n in names}
print(f"\n| Suite | " + " | ".join(names) + " |")
for s in suites:
    print(f"| {s} | " + " | ".join(f"{med[n]['suites'][s]:.0f}" for n in names) + " |")
print(f"| Score | " + " | ".join(f"{med[n]['score']:.0f}" for n in names) + " |")
json.dump({"runs": runs, "medians": med, "samples": N, "configs": CONFIGS}, open("/tmp/hermes_arms.json", "w"), indent=1)
