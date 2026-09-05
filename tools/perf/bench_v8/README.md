# bench-v8 (Octane 2.0, V8 benchmark suite version 9)

Since 2026-08-19 this suite (then version 7, 8 benchmarks) was the public
performance metric of zjs (owner ruling; the 15-benchmark zoo suite remained
an internal diagnostic). As of 2026-08-25 `suite/` was expanded to the full
Octane 2.0 suite (17 named results across 15 `BenchmarkSuite` registrations,
plus a `Score (version 9)` composite) — the same suite the internal zoo
runner (`tools/perf/zoo/`, retired 2026-08-29) exercised via the external
`javascript-zoo` checkout, now vendored directly into this repository.
Fixed-work PMU screening lives here too (`run_fixed_pmu.py`,
`mise run perf-screen`).

**This breaks direct comparability with QuickJS's published bench.html
numbers**, which report version 7's narrower 8-benchmark suite — Octane's
own `base.js` states scores are not comparable across versions. A qjs
comparison under this tool is now a fresh local run against the same v9
suite, not the bellard.org published number. See `docs/perf/bench-v8-status.md`
for current status and the zlib shell-shim note (below).

## zlib and the shell `read` shim

The emscripten prologue in `zlib-data.js` classifies the host as a
*shell* (not browser / node / worker) and then runs `Module.read = read`
eagerly, so it throws `ReferenceError` on any shell without a d8-style
global `read(path)` — QuickJS, Hermes and zjs alike (d8, the SpiderMonkey
shell and jsc define it). The benchmark never calls `read`; its input
is embedded. `driver.js` therefore defines a throwing `read` shim when the
global is absent, identically for every engine, so zlib runs and scores
everywhere. It was skip-listed from 2026-08-25 to 2026-09-05 under a
mistaken engine-gap diagnosis; the runners' `SKIPPED_SUITES` contract is
now empty and a run that prints any `Skipped` line is rejected.

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
python3 tools/perf/measure_fields.py run --field b --layer single -- \
  python3 tools/perf/bench_v8/run_benchv8_compare.py \
    --zjs zig-out/bin/zjs --qjs /home/aneryu/quickjs/qjs \
    --field b --samples 8 --output /tmp/benchv8.json
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
python3 tools/perf/measure_fields.py run --field b --layer single -- \
  python3 tools/perf/bench_v8/run_benchv8_multiengine.py \
    --zjs zig-out/bin/zjs \
    --qjs /home/aneryu/quickjs/qjs \
    --hermes /home/aneryu/hermes/build_release/bin/hermes \
    --v8 /home/aneryu/v8/out/arm64.release/d8 \
    --jsc /home/aneryu/WebKit/WebKitBuild/JSCOnly/Release/bin/jsc \
    --field b --samples 8 --output /tmp/benchv8-multiengine.json
```

Every named engine is optional except `--zjs`; V8 always runs with
`--jitless` and JSC with `--useJIT=false` (hardcoded, not caller-chosen, so
the "jitless" label is always true of what actually ran).

The engines execute an identical concatenation of the suite files plus
`driver.js` (zjs has no `load()`, so the upstream `run.js` loader is not
used; the driver replicates its output format exactly).

Published status lives in `docs/perf/bench-v8-status.md`. Performance
gates never run in shared-runner CI (measurement contract).
