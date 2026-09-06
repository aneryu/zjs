# bench-v8 status

## 2026-09-06: 17-suite five-engine pinned snapshot (new composite baseline)

First pinned run under the 17-result contract (zlib scored, not skipped).
zjs `10966b12` ReleaseFast (md5 `c8cd7b22…`), QuickJS GCC-16 yardstick
(md5 `5e965b35…`), Hermes / V8 jitless / JSC jitless binaries unchanged
since 2026-08-25. Serial, CPU 19, host lock, forward/reverse round-robin,
8 samples per engine, medians. Artifact:
`reports/evidence/BENCH-V8-17/multiengine-2026-09-06-10966b12.json`.

| Benchmark | zjs | QuickJS | Hermes | V8 jitless | JSC jitless | zjs / qjs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Richards | 1899 | 1792 | 2926 | 2121 | 2881 | 1.06 |
| DeltaBlue | 1560 | 1587 | 2614 | 2017 | 1845 | 0.98 |
| Crypto | 2548 | 2350 | 3960 | 1746 | 3588 | 1.08 |
| RayTrace | 3833 | 3757 | 9872 | 6962 | 4180 | 1.02 |
| EarleyBoyer | 4143 | 4890 | 11848 | 10050 | 5948 | 0.85 |
| RegExp | 879 | 828 | 1114 | 4612 | 1024 | 1.06 |
| Splay | 4910 | 7962 | 6846 | 8348 | 7872 | **0.62** |
| SplayLatency | 14207 | 20511 | 16302 | 7686 | 23082 | **0.69** |
| NavierStokes | 4555 | 4764 | 6719 | 2644 | 4122 | 0.96 |
| PdfJS | 9480 | 10602 | 17170 | 15052 | 12578 | 0.89 |
| Mandreel | 2489 | 2146 | 2828 | 1918 | 1776 | 1.16 |
| MandreelLatency | 16956 | 15482 | 16160 | 10861 | 7288 | 1.10 |
| Gameboy | 15181 | 14598 | 17296 | 11465 | 11679 | 1.04 |
| CodeLoad | 34450 | 35662 | 11020 | 89668 | 61038 | 0.97 |
| Box2D | 7824 | 7606 | 16002 | 7313 | 9692 | 1.03 |
| zlib | 4890 | 3972 | 3436 | 3659 | 3650 | 1.23 |
| Typescript | 24792 | 27146 | 48252 | 36425 | 26440 | 0.91 |
| **Score (v9)** | **5678** | **5874** | **7702** | **6749** | **6305** | **0.9666** |

Hermes / qjs 1.3113, V8 jitless / qjs 1.1491, JSC jitless / qjs 1.0735.

Reading: with the tracing collector (TGC S0–S5) zjs is at or above QuickJS
on 11 of 17 results; the composite gap is Splay and SplayLatency
(0.62 / 0.69 — the structural account closed in
`docs/tracing-gc-completion-account.md` §6b), plus EarleyBoyer 0.85 and
PdfJS 0.89. Removing the two Splay results alone would put the composite
at about 1.01. **Owner ruling 2026-09-06: the performance line is closed;
Octane vs QuickJS is a regression gate at ≥ 0.95 from here.**

Protocol note going forward: the three non-yardstick engines are
unchanged binaries and are re-run only when the suite contract changes;
routine snapshots run zjs + QuickJS only (`--qjs` alone), which cuts the
run from ~65 min to ~25 min.

## 2026-09-05: zlib un-skipped (never an engine gap)

The 2026-08-25 diagnosis below ("genuine zjs engine gap: indirect eval /
global-scope binding") was wrong. The benchmark's emscripten prologue
classifies the host as a *shell* (not browser / node / worker) and then
executes `Module.read = read` eagerly, so it throws `ReferenceError` on
any shell without a d8-style global `read()`. QuickJS fails at the same
character (`'read' is not defined`) and so does Hermes; d8, the SpiderMonkey
shell and jsc define it. The benchmark never calls `read` (its
input is embedded), so `driver.js` now defines a throwing `read` shim
when the global is absent, identically for every engine, and no longer
passes a skip list. `run_benchv8_compare.py` / `run_benchv8_multiengine.py`
expect 17 numeric results and no `Skipped` line; `run_fixed_pmu.py` and
`check_completes.py` know `zlib` = `zlib.js` + `zlib-data.js`.

Two things hid this for eleven days: zjs reports every `ReferenceError`
as the bare message `not defined` (QuickJS names the identifier), and
zjs's `print` renders any object argument as `[object Object]` without
calling its `toString` (QuickJS's `print` dumps it). Both were
diagnostics debts, not correctness; both closed 2026-09-06 —
`ReferenceError: 'read' is not defined` now names the identifier on every
unresolved-binding exit, and `print` runs object arguments through
ToString (`Error: x`, custom `toString`; QuickJS's inspector dump is not
ported).

Single unpinned run, parallel with other work, so not a gate number:

| Benchmark | zjs | QuickJS | zjs / qjs |
| --- | ---: | ---: | ---: |
| zlib | 4921 | 3932 | 1.25 |
| Score (version 9), 17 suites | 5578 | 5724 | 0.9745 |

Composites are **not comparable with the 16-suite records below**: zlib
now contributes its real score instead of Octane's neutral default (1),
which lifts every engine's composite. The five-engine pinned snapshot
needs a re-run under the new contract before it is quoted again.

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
4. **Yardstick ruled (owner ratification 2026-08-26, BASE-G0):** the
   GCC-16 build (`/home/aneryu/quickjs/qjs`, md5 `5e965b35...`, sha256
   `5741f6bc...`) is the official reference going forward — the stronger
   opponent, and the binary the current v9 snapshot already used. Full
   fingerprint + recipe: `reports/evidence/BASE-G0/manifest.json`.
   Published comparisons against any other build must say so explicitly.

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

**Known gap (superseded 2026-09-05, see top):** `zlib` throws
(`ReferenceError: not defined`) from inside its giant indirect `eval()` of
emscripten-generated code — at the time read as a zjs engine gap. Owner
decision 2026-08-25: skip-list zlib (`driver.js` passed `['zlib']` to
`BenchmarkSuite.RunSuites`) rather than block the other 16 — it printed
`zlib: Skipped` and contributed Octane's neutral default score (1) to the
composite. Resolved 2026-09-05: the missing piece was the d8 shell global
`read`, which every non-d8 engine lacks; driver.js shims it.

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
