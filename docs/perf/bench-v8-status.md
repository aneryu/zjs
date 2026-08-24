# bench-v8 status

Checked headline on the V8 benchmark suite version 7 — the suite upstream
QuickJS publishes its own scores with (bellard.org/quickjs/bench.html).
This is a public single-machine performance record (the 15-benchmark zoo
suite remains an internal diagnostic, see [zoo-status.md](zoo-status.md)). It
is a measurement record, not a build-graph gate.

## Current-head preservation check

The current ReleaseFast head was checked against its direct parent with the
runner's native parallel A/B protocol on 2026-08-24. This check establishes
whether the code-size change preserved performance; it does not replace the
serial QuickJS comparison below.

| Field | Value |
| --- | --- |
| Candidate | `71505d11a9fcf882a2176069cf64d2f8a9b7b871` |
| Baseline | `7f9873e6dc6c3a621bb6f33916d3334eab1dd90f` (direct parent) |
| Configuration | `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off` |
| Candidate binary SHA-256 | `006dbe030d32dad04b04396aecd150298fce4984432c7f4fd8ce4ba474f7dd90` |
| Baseline binary SHA-256 | `ed006fa31169819a0870bf3b2a66458669f807ef9f24eaa33c9b024e4527d3ad` |
| Protocol | parallel clusters `5-9` / `15-19`, equal four-sample halves with engine-to-cluster assignment swapped, exclusive host lock |
| Coverage | 8 samples per binary; all 16 invocations exited successfully and reported all 8 suites plus the composite score |
| **Composite ratio, candidate / baseline** | **0.9965** (protocol-local medians 2575 / 2584) |
| Refactor gate | **PASS**: composite at least `0.995`; every suite within its historical dispersion envelope |

| Benchmark | Candidate / baseline |
| --- | ---: |
| Richards | 1.0138 |
| DeltaBlue | 0.9961 |
| Crypto | 0.9982 |
| RayTrace | 0.9892 |
| EarleyBoyer | 0.9880 |
| RegExp | 0.9759 |
| Splay | 1.0012 |
| NavierStokes | 0.9990 |
| **Composite Score (version 7)** | **0.9965** |

Reproduce the current-head A/B on the measurement machine:

```sh
flock -x /tmp/zjs-host-heavy.lock taskset -c 5-9,15-19 \
  python3 tools/perf/bench_v8/run_benchv8_compare.py \
    --zjs /path/to/71505d11/zjs --baseline /path/to/7f9873e6/zjs \
    --parallel-clusters 5-9 15-19 --samples 8 \
    --output /tmp/benchv8-refactor-ab.json
```

Parallel execution changes the absolute score, so only the ratios in this
section may be compared. Public cross-engine absolute scores use the serial
protocol.

## Published serial cross-engine snapshot

| Field | Value |
| --- | --- |
| Date | 2026-08-21 |
| zjs | `main@47cf81ef` (ReleaseFast) |
| Bellard QuickJS | `04be2460` (upstream Makefile release build) |
| V8 | `999f1b39` (`--jitless`) |
| Hermes | `dac0be31` (Release) |
| Suite | V8 benchmark suite v7, vendored unmodified in `tools/perf/bench_v8/suite/` |
| Protocol | serial CPU-19 pinned, exclusive host lock, forward/reverse interleaving, 8 samples per engine, medians |
| **Composite Score (version 7), zjs / QuickJS** | **1.0469** (zjs 2714 / qjs 2592.5) |
| Composite Score, V8 jitless / QuickJS | **1.5614** (4048 / 2592.5) |
| Composite Score, Hermes / QuickJS | **1.6359** (4241 / 2592.5) |
| zjs benchmarks at or above 1.0 vs QuickJS | **7 / 8** |

Scores are the suite's own self-reported numbers; higher is better. The
comparison ratios are each engine's composite score divided by the QuickJS
composite score.

| Benchmark | zjs | QuickJS | V8 `--jitless` | Hermes |
| --- | ---: | ---: | ---: | ---: |
| Richards | 1,693 | 1,617 | 2,120 | 2,540 |
| DeltaBlue | 1,461 | 1,415 | 2,019 | 2,448.5 |
| Crypto | 2,341 | 2,200.5 | 1,736.5 | 3,888.5 |
| RayTrace | 3,657.5 | 3,382 | 6,942 | 8,960.5 |
| EarleyBoyer | 3,995 | 4,507 | 10,035 | 9,346 |
| RegExp | 994 | 844.5 | 6,627 | 1,191.5 |
| Splay | 7,306 | 7,297.5 | 7,994.5 | 6,530.5 |
| NavierStokes | 4,860.5 | 4,307 | 2,631.5 | 6,685.5 |
| **Composite Score (version 7)** | **2,714** | **2,592.5** | **4,048** | **4,241** |

EarleyBoyer is the only benchmark below parity for zjs versus QuickJS
(0.886); its attribution history lives with the zoo campaigns.

Reproduce (measurement machine only; performance comparisons never run in
shared-runner CI per the measurement contract):

```sh
mise exec -- zig build zjs -Doptimize=ReleaseFast --summary all
flock -x /tmp/zjs-host-heavy.lock taskset -c 19 \
  python3 tools/perf/bench_v8/run_benchv8_compare.py \
    --zjs zig-out/bin/zjs --qjs /home/aneryu/quickjs/qjs \
    --samples 8 --output /tmp/benchv8.json
```

The published runner above reproduces the zjs/QuickJS pair. The four-engine
snapshot additionally ran `/home/aneryu/v8/out/arm64.release/d8 --jitless`
and `/home/aneryu/hermes/build_release/bin/hermes` against the same combined
suite script and protocol. Suite provenance and license:
[tools/perf/bench_v8/README.md](../../tools/perf/bench_v8/README.md). This is a
maintainer single-machine measurement (ARM Cortex-X925, Linux 6.17); there is
no independent reproduction yet.
