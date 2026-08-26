# bench-v8 status

## 2026-08-25 evening: reference-binary drift adjudicated (zjs did not regress)

The apparent −6~7pp system-wide shift between the 2026-08-19 zoo-r0
baseline (geomean 1.0304 vs qjs) and the 2026-08-25 snapshots (0.9611
Octane composite / 0.9636 zoo-protocol geomean) was fully adjudicated
with three A/Bs (parallel clusters 5-9/15-19, 8 samples, ratios only):

| Experiment | Ratio | Verdict |
| --- | --- | --- |
| zjs `HEAD` vs zjs `47cf81ef` (08-21) | **1.0017**, all 16 suites in noise | no regression since 08-21 |
| zjs `0c32a71c` (08-19, zoo-r0) vs zjs `47cf81ef` | **0.9903** | no regression 08-19→08-21 |
| **qjs Jul-24 build vs qjs Aug-24 build (same commit `04be246`)** | **0.9380** — the new build is 6.6% faster across all 16 suites | **the entire shift is reference drift** |

Root cause: the Jul-24 qjs binary (used by the zoo-r0 and earlier
published baselines) was built with **GCC 13.3.0** (Ubuntu 24.04
default); the Aug-24 rebuild used **GCC 16.0.1 experimental** (PPA
trunk snapshot 20260315). Same source, 6.6% composite difference —
the per-suite distribution of the qjs speedup mirrors the per-suite
"regressions" observed for zjs (e.g. DeltaBlue: qjs +13%, observed
zjs ratio −10.7pp), closing the ledger.

Consequences:

1. **zjs has not regressed.** All engine-side numbers since 08-19 are
   stable within noise.
2. Ratios are only comparable against the same reference binary:
   zoo-r0 1.0304 and the v7 snapshot 1.0469 were measured against the
   GCC-13 build; the 2026-08-25 five-engine snapshot (0.9611) against
   the GCC-16 build. Neither is wrong; they answer different questions.
3. **Process fix (measurement contract): the reference binary's
   fingerprint (hash + compiler) must be part of every published
   record.** The v7-era records pinned only the qjs commit; that gap
   is what allowed silent reference drift. This section records both:
   GCC-13 build (Jul 24, 5139288 B; md5 not recorded — the binary
   pre-dates this fingerprint rule), GCC-16 build md5
   `5e965b35f757e6c24c8f534bb4c6ee10` (Aug 24, 5279720 B).
4. Which build is the official yardstick going forward is an owner
   call: GCC-13 is the reproducible "system default compiler" build;
   GCC-16 is the stronger opponent. Pending that ruling, published
   comparisons must name the reference build explicitly.

## 2026-08-25: suite expanded to Octane 2.0 (version 9)

`tools/perf/bench_v8/suite/` was expanded from the narrower V8 benchmark
suite version 7 (8 benchmarks) to the full Octane 2.0 suite vendored from
`chromium/octane` (version 9, 17 named results across 15 `BenchmarkSuite`
registrations plus a composite `Score (version 9)`). See
[the tool's README](../../tools/perf/bench_v8/README.md) for provenance and
per-file licenses.

This was necessary, not additive: Octane's `base.js` changed the
`Benchmark()` constructor signature, so the old v7 richards/deltablue/crypto/
raytrace/earley-boyer/regexp/splay/navier-stokes files are incompatible with
it (`TypeError: not a function` at setup) — the whole `suite/` directory
moved to the matching Octane vendor tree, not just the 9 new files.

**Version-7 scores are not comparable with version-9 scores** (the suite's
own `base.js` says so). The superseded version-7 records were removed from
this file on 2026-08-25; see "History (version 7)" at the end for what they
were and where to recover them. Everything else in this file is a version-9
record.

**Known gap:** `zlib` throws (`ReferenceError: not defined`) from inside its
giant indirect `eval()` of emscripten-generated code — looks like a genuine
zjs engine gap (indirect eval / global-scope binding semantics), not a
suite or tooling issue. 16/17 benchmarks run cleanly. Owner decision
2026-08-25: skip-list zlib (`driver.js` passes `['zlib']` to
`BenchmarkSuite.RunSuites`) rather than block the other 16 — it prints
`zlib: Skipped` and contributes Octane's own neutral default score (1) to
the composite, visibly, not silently dropped. The underlying eval bug is
still open.

Single-engine diagnostic (`zig build perf-bench-v8` / `run_local.py`,
unpinned, no gate value) on the current head, 2026-08-25, zjs only:

| Benchmark | zjs |
| --- | ---: |
| Richards | 1694 |
| DeltaBlue | 1440 |
| Crypto | 2344 |
| RayTrace | 3638 |
| EarleyBoyer | 3731 |
| RegExp | 902 |
| Splay | 7083 |
| SplayLatency | 19059 |
| NavierStokes | 4908 |
| PdfJS | 8239 |
| Mandreel | 2185 |
| MandreelLatency | 16133 |
| Gameboy | 14058 |
| CodeLoad | 36545 |
| Box2D | 7209 |
| zlib | Skipped |
| Typescript | 22389 |
| **Score (version 9)** | **4466** |

Superseded by the pinned five-engine snapshot below, taken the same day.

## 2026-08-25: Octane v9 five-engine snapshot (zjs, QuickJS, Hermes, V8 jitless, JSC jitless)

Ran with the new N-way tool, `run_benchv8_multiengine.py` (see
[README](../../tools/perf/bench_v8/README.md)) — the pairwise
`run_benchv8_compare.py` stays reserved for the published zjs/QuickJS metric
and refactor-policy A/B.

| Field | Value |
| --- | --- |
| Date | 2026-08-25 |
| zjs | `main@14b0618d` (ReleaseFast) |
| Bellard QuickJS | `04be246` |
| Hermes | `dac0be3` (Release) |
| V8 | `999f1b39` (`d8 --jitless`) |
| JSC | WebKit `0f924849f5` (`jsc --useJIT=false`, `WebKitBuild/JSCOnly/Release`) |
| Suite | Octane 2.0 (version 9), vendored in `tools/perf/bench_v8/suite/`, zlib skip-listed for all five engines identically |
| Protocol | serial, CPU 19 pinned, exclusive host lock, forward/reverse round-robin across all five engines, 8 samples per engine, medians |
| Binary identity | every binary's MD5 checked unchanged before and after the run |
| **Score (v9), zjs / QuickJS** | **0.9611** (zjs 4521 / qjs 4704) |
| Score (v9), Hermes / QuickJS | **1.3278** (6246 / 4704) |
| Score (v9), V8 jitless / QuickJS | **1.1582** (5448 / 4704) |
| Score (v9), JSC jitless / QuickJS | **1.0832** (5096 / 4704) |

| Benchmark | zjs | QuickJS | Hermes | V8 jitless | JSC jitless |
| --- | ---: | ---: | ---: | ---: | ---: |
| Richards | 1700 | 1791 | 2944 | 2122 | 2886 |
| DeltaBlue | 1448 | 1587 | 2680 | 2014 | 1950 |
| Crypto | 2344 | 2352 | 3964 | 1744 | 3586 |
| RayTrace | 3669 | 3791 | 9792 | 6958 | 4219 |
| EarleyBoyer | 3934 | 4868 | 11818 | 10080 | 6066 |
| RegExp | 904 | 827 | 1119 | 4630 | 1022 |
| Splay | 7364 | 7966 | 6732 | 8320 | 7738 |
| SplayLatency | 20384 | 19327 | 16439 | 7771 | 20900 |
| NavierStokes | 4839 | 4776 | 6719 | 2624 | 4116 |
| PdfJS | 8265 | 10597 | 17076 | 15112 | 12730 |
| Mandreel | 2186 | 2128 | 2840 | 1920 | 1785 |
| MandreelLatency | 16265 | 15604 | 16872 | 10957 | 7402 |
| Gameboy | 14058 | 14598 | 17287 | 11612 | 11648 |
| CodeLoad | 37348 | 35530 | 10869 | 88480 | 62456 |
| Box2D | 7234 | 7648 | 16026 | 7310 | 9664 |
| zlib | Skipped | Skipped | Skipped | Skipped | Skipped |
| Typescript | 23078 | 26054 | 46442 | 35802 | 25937 |
| **Score (version 9)** | **4521** | **4704** | **6246** | **5448** | **5096** |

zjs sits just under QuickJS on this suite (0.96), and is the slowest of the
five — the other four all clear their own QuickJS ratio (Hermes 1.33, V8
jitless 1.16, JSC jitless 1.08). No per-benchmark attribution has been done
yet against this specific suite version; the historical v7 attribution work
(zoo campaigns) does not directly transfer since Octane v9 changed timing
methodology (warmup/deterministic modes, per-iteration `performance.now`)
alongside adding benchmarks.

Reproduce:

```sh
mise exec -- zig build zjs -Doptimize=ReleaseFast --summary all
flock -x /tmp/zjs-host-heavy.lock taskset -c 19 \
  python3 tools/perf/bench_v8/run_benchv8_multiengine.py \
    --zjs zig-out/bin/zjs \
    --qjs /home/aneryu/quickjs/qjs \
    --hermes /home/aneryu/hermes/build_release/bin/hermes \
    --v8 /home/aneryu/v8/out/arm64.release/d8 \
    --jsc /home/aneryu/WebKit/WebKitBuild/JSCOnly/Release/bin/jsc \
    --samples 8 --output /tmp/benchv8-multiengine.json
```

This is a maintainer single-machine measurement (ARM Cortex-X925, Linux
6.17); there is no independent reproduction yet, and it has not gone
through an owner ruling to become the *published* metric the way the
removed v7 zjs/QuickJS snapshot did — treat it as a snapshot, not yet a
gate.

## History (version 7)

The version-7 records — the 2026-08-19 published headline (composite
**1.0464**, zjs 2706 / qjs 2586, GCC-13 reference), the 2026-08-21
four-engine serial snapshot (zjs 2,714 / 1.0469), and the 2026-08-24
refactor A/B (0.9965) — were removed from the active tree on 2026-08-25;
recover them from git history (this file as of `14b0618d`). They are not
comparable with version-9 scores.
