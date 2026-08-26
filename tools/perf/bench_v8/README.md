# bench-v8 (Octane 2.0, V8 benchmark suite version 9)

Since 2026-08-19 this suite (then version 7, 8 benchmarks) was the public
performance metric of zjs (owner ruling; the 15-benchmark zoo suite remained
an internal diagnostic). As of 2026-08-25 `suite/` was expanded to the full
Octane 2.0 suite (17 named results across 15 `BenchmarkSuite` registrations,
plus a `Score (version 9)` composite) — the same suite the internal zoo
runner (`tools/perf/zoo/`) already exercises, now vendored directly into
this repository instead of only via the external `javascript-zoo` checkout.

**This breaks direct comparability with QuickJS's published bench.html
numbers**, which report version 7's narrower 8-benchmark suite — Octane's
own `base.js` states scores are not comparable across versions. A qjs
comparison under this tool is now a fresh local run against the same v9
suite, not the bellard.org published number. See `docs/perf/bench-v8-status.md`
for current status, including a known-blocked benchmark (below).

## Known gap: zlib

`zlib` errors out of the zjs run (`ReferenceError: not defined`, thrown
from inside the benchmark's giant indirect `eval()` of emscripten-generated
code in `zlib-data.js`) — looks like a genuine zjs engine gap (indirect
eval / global-scope binding semantics), not a suite or tooling issue. Owner
decision 2026-08-25: skip-list it rather than block the other 16. `driver.js`
calls `BenchmarkSuite.RunSuites(runner, ['zlib'])`, which pushes Octane's own
neutral default score (1) for zlib into the composite and prints
`zlib: Skipped` — visible in the output, not silently dropped.
`run_benchv8_compare.py` expects exactly this skip (`SKIPPED_SUITES`) and
raises if a run skips anything else or fails to skip zlib. The underlying
engine bug is still open; un-skip zlib once it's fixed.

## Provenance and license

`suite/` is vendored **unmodified** from `chromium/octane`
(chromium.googlesource.com/external/octane, formerly the V8 project's
Octane benchmark), commit `570ad1ccfe86e3eecba0636c8f932ac08edec517`, which
carries `BenchmarkSuite.version = '9'`. `suite/LICENSE.octane` is the
top-level BSD license for the harness (`base.js`, `run.js`, and the
V8-authored benchmarks: richards, deltablue, crypto, raytrace,
earley-boyer, regexp, splay, navier-stokes, zlib, code-load, typescript).
Individual benchmarks carry their own original license headers instead:
`pdfjs.js` and `gbemu-part1.js`/`gbemu-part2.js` are GPLv2 (Mozilla /
Grant Galitz respectively), `box2d.js` is the zlib-style Box2D license
(Erin Catto), `mandreel.js` is BSD (Onan Games). These are vendored,
unmodified, locally-run benchmark inputs — not linked into the built `zjs`
binary — the same basis other engines (WebKit, Hermes) vendor this same
bundle on. Do not edit files under `suite/`.

`driver.js` and the Python runners are zjs-repository code (MIT).

## Direction of the number

Scores are self-reported and **higher is better**. The comparison reports
`ratio = zjs / qjs`; below 1.0 means zjs is slower. The headline is the
suite's own composite `Score (version 9)` (its internal geometric mean),
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

Multi-engine cross-check (zjs vs any of qjs/Hermes/V8-jitless/JSC-jitless
together, not just qjs): `run_benchv8_multiengine.py`. Serial, pinned,
forward/reverse round-robin across all named engines, medians; refuses to
run unpinned. This is the N-way counterpart to `run_benchv8_compare.py`,
which stays pairwise (zjs vs exactly one reference) by design; use it for
snapshots, not for the published metric or refactor A/B.

```bash
flock -x /tmp/zjs-host-heavy.lock taskset -c 19 \
  python3 tools/perf/bench_v8/run_benchv8_multiengine.py \
    --zjs zig-out/bin/zjs \
    --qjs /home/aneryu/quickjs/qjs \
    --hermes /home/aneryu/hermes/build_release/bin/hermes \
    --v8 /home/aneryu/v8/out/arm64.release/d8 \
    --jsc /home/aneryu/WebKit/WebKitBuild/JSCOnly/Release/bin/jsc \
    --samples 8 --output /tmp/benchv8-multiengine.json
```

Every named engine is optional except `--zjs`; V8 always runs with
`--jitless` and JSC with `--useJIT=false` (hardcoded, not caller-chosen, so
the "jitless" label is always true of what actually ran).

The engines execute an identical concatenation of the suite files plus
`driver.js` (zjs has no `load()`, so the upstream `run.js` loader is not
used; the driver replicates its output format exactly).

Published status lives in `docs/perf/bench-v8-status.md`. Performance
gates never run in shared-runner CI (measurement contract).
