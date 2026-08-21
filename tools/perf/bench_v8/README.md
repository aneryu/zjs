# bench-v8 (V8 benchmark suite, version 7)

This is the suite Bellard's QuickJS publishes its performance numbers with
(bellard.org/quickjs/bench.html), and since 2026-08-19 it is the public
performance metric of zjs (owner ruling; the 15-benchmark zoo suite remains
an internal diagnostic).

## Provenance and license

`suite/` is vendored **unmodified** from the V8 project repository,
`benchmarks/` directory at tag `7.9.317`
(chromium.googlesource.com/v8/v8), which carries
`BenchmarkSuite.version = '7'` — the same suite version QuickJS reports.
Each file retains its original BSD-style license header (V8 project
authors / respective third-party authors for earley-boyer, raytrace,
regexp, crypto and navier-stokes). Do not edit files under `suite/`.

`driver.js` and the Python runners are zjs-repository code (MIT).

## Direction of the number

Scores are self-reported and **higher is better**. The comparison reports
`ratio = zjs / qjs`; below 1.0 means zjs is slower. The headline is the
suite's own composite `Score (version 7)` (its internal geometric mean),
taken as the ratio of per-engine median composites.

## Usage

Official comparison against QuickJS — the published metric. Serial, pinned,
ABBA-interleaved, medians; refuses to run unpinned:

```bash
flock -x /tmp/zjs-host-heavy.lock taskset -c 19 \
  python3 tools/perf/bench_v8/run_benchv8_compare.py \
    --zjs zig-out/bin/zjs --qjs /home/aneryu/quickjs/qjs \
    --samples 8 --output /tmp/benchv8.json
```

Refactor-policy rule 2 A/B — two-cluster parallel, about two minutes instead
of thirteen. Each lane runs both binaries at the same instant, one per
cluster, swapping clusters every batch:

```bash
flock -x /tmp/zjs-host-heavy.lock taskset -c 5-9,15-19 \
  python3 tools/perf/bench_v8/run_benchv8_compare.py \
    --zjs <candidate> --baseline <merge-base build> \
    --parallel-clusters 5-9 15-19 \
    --samples 8 --output /tmp/refactor-ab.json
```

Parallelism is legal for the A/B because it consumes only the ratio. It is
NOT legal for `--qjs`, which publishes an absolute score: sharing L3 and
memory bandwidth lowers every absolute score, so a parallel number is not
comparable to the published serial one. The tool refuses the combination
rather than trusting the caller to remember, and the JSON artifact records
which protocol produced its numbers.

Local diagnostic single run (no pinning, no gate value):

```bash
zig build perf-bench-v8 --summary all
```

The engines execute an identical concatenation of the suite files plus
`driver.js` (zjs has no `load()`, so the upstream `run.js` loader is not
used; the driver replicates its output format exactly).

Published status lives in `docs/perf/bench-v8-status.md`. Performance
gates never run in shared-runner CI (measurement contract).
