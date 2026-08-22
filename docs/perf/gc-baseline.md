# GC behaviour baseline (pre-refactor)

The "before" picture for the GC refactor: what the current collector does on
a real workload, measured with the shipped binary. Captured 2026-08-23 at
`a3e36a19`, the commit that added `--gc-stats`.

Without this, a refactor can only argue from the composite benchmark score,
which says nothing about how much the collector ran, how long a single pause
was, or whether rounds were aborting.

## How to reproduce

```sh
zig build zjs -Doptimize=ReleaseFast
python3 - <<'EOF'
import importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location("r", "tools/perf/bench_v8/run_benchv8_compare.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.build_combined(Path("tools/perf/bench_v8/suite"), Path("tools/perf/bench_v8/driver.js"), Path("/tmp/benchv8-combined.js"))
EOF
./zig-out/bin/zjs --gc-stats /tmp/benchv8-combined.js
```

The whole V8 suite in one process, so the numbers are cumulative across all
eight benchmarks. This is a maintainer single-machine measurement (ARM
Cortex-X925, Linux 6.17), unpinned — the counters are stable across runs even
though the score is not.

## Baseline, three consecutive runs

| | run 1 | run 2 | run 3 |
|---|---:|---:|---:|
| Cycle-collection entries | 877 | 879 | 880 |
| Completed rounds | 877 | 879 | 880 |
| Failed collections | 0 | 0 | 0 |
| Objects freed | 13,401,009 | 13,406,963 | 13,415,579 |
| Zero-ref drains | 13,491,421 | 13,497,606 | 13,390,500 |
| Cycle-collection time, total | 661 ms | 693 ms | 675 ms |
| Cycle-collection time, last round | 38.9 ms | 51.0 ms | 45.1 ms |
| Live bytes at exit | 1,213,561 | 1,213,561 | 1,213,561 |
| Suite score | 2,580 | 2,722 | 2,724 |

Counter dispersion is under 0.5% across runs; the live-byte figure is
identical every time.

## What this says about the refactor's targets

- **Entries equal completed rounds in every run.** No aborted collections,
  so the failure paths are not currently exercised by this workload — a
  refactor cannot use this baseline to claim anything about them.
- **Total collection time is ~0.67 s** for the whole suite. That is the
  budget a throughput-oriented change is bidding against.
- **A single round reaches 39-51 ms.** This is the number that matters for
  anything interactive, and it is the strongest argument for incremental or
  concurrent work — the throughput figure alone would hide it.
- **Zero-ref drains slightly exceed objects freed** (13.49 M vs 13.40 M):
  most reclamation is ordinary refcounting, and the cycle collector handles
  the remainder. A refactor that speeds up cycle collection is therefore
  optimising the smaller half of reclamation.
- **Live bytes at exit are byte-identical across runs**, which makes this a
  usable regression check on its own: a refactor that changes it has changed
  what survives.

## The panel distinguishes the two reclamation paths

A cycle-only workload — 50,000 self-referencing objects, which refcounting
cannot reclaim by construction:

```sh
./zig-out/bin/zjs --gc-stats -e "for (let i=0;i<50000;i++){const o={a:i,self:null};o.self=o;}"
```

reports **1 zero-ref drain** and 42,952 objects freed, i.e. essentially all
reclamation through the cycle collector — the mirror image of the suite
baseline above (13.49 M drains against 13.40 M freed). So the counters can
tell which half of reclamation a change moved, which is what makes them
usable as refactor evidence rather than decoration.

## First use of this baseline (G4, `a837a17e`)

Moving each payload's trace arm beside its destroy method was expected to be
behaviour-neutral. Re-measuring says it mostly was, and shows one thing the
A/B could not:

| | baseline (3 runs) | after G4 (3 runs) |
|---|---:|---:|
| Cycle-collection entries | 877 / 879 / 880 | 858 / 857 / 856 |
| Objects freed | 13.401 M / 13.407 M / 13.416 M | 13.064 M / 13.041 M / 13.030 M |
| Zero-ref drains | 13.491 M / 13.498 M / 13.391 M | 13.273 M / 13.253 M / 13.278 M |
| Live bytes at exit | 1,213,561 | 1,213,561 |

The two groups do not overlap: collections fall about 2.5% and total
reclamation about 2.7%, well outside each group's own 0.2-0.4% spread. The
bench-v8 A/B for the same change read 1.0033 then 0.9986 — it cannot see
this at all.

The direction rules out the dangerous reading. A missed trace edge leaks,
which would *raise* live bytes; live bytes are byte-identical, and the
edge-parity and per-family cycle guards are green. Less reclamation with an
unchanged survivor set means the run allocated fewer objects — consistent
with collapsing `FunctionRarePayload`'s two trace copies into one method and
the inlining changes that follow from moving code. Recorded as the new
reference point rather than as a regression.

## Contract

Re-measure with the same command after any GC change and record the same
table. Deltas in the counters are attributable to the change; deltas in the
score are not (the score is dispersion-dominated, see
[refactor-policy.md](../refactor-policy.md)).
