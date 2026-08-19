# bench-v8 status vs Bellard QuickJS

Checked headline on the V8 benchmark suite version 7 — the suite upstream
QuickJS publishes its own scores with (bellard.org/quickjs/bench.html).
This is the public performance claim (owner ruling 2026-08-19; the
15-benchmark zoo suite remains an internal diagnostic, see
[zoo-status.md](zoo-status.md)). It is a measurement record, not a
build-graph gate.

| Field | Value |
| --- | --- |
| Date | 2026-08-19 |
| zjs | `main@da875a7d` (ReleaseFast, binary md5 `f7c7808d…`) |
| Bellard QuickJS | `04be246` (upstream Makefile release build, md5 `c58f46db…`) |
| Suite | V8 benchmark suite v7, vendored unmodified in `tools/perf/bench_v8/suite/` |
| Protocol | serial CPU-19 pinned, exclusive host lock, ABBA-interleaved, 8 samples per engine, medians |
| **Composite Score (version 7), zjs / QuickJS** | **1.0464** (zjs 2706 / qjs 2586) |
| At or above 1.0 | **7 / 8** |

Scores are the suite's own self-reported numbers; higher is better. The
ratio is `zjs score / QuickJS score`.

| Benchmark | zjs | QuickJS | zjs / QuickJS |
| --- | ---: | ---: | ---: |
| EarleyBoyer | 3,950 | 4,492 | 0.879 |
| Splay | 7,346 | 7,208 | 1.019 |
| DeltaBlue | 1,457 | 1,411 | 1.033 |
| Richards | 1,700 | 1,614 | 1.054 |
| Crypto | 2,346 | 2,198 | 1.068 |
| RayTrace | 3,687 | 3,367 | 1.095 |
| NavierStokes | 4,792 | 4,307 | 1.113 |
| RegExp | 976 | 854 | 1.144 |
| **Composite Score (version 7)** | **2,706** | **2,586** | **1.0464** |

EarleyBoyer is the only benchmark below parity — the same known laggard as
in the zoo suite (zoo EB 0.886); its attribution history lives with the
zoo campaigns.

Reproduce (measurement machine only; performance comparisons never run in
shared-runner CI per the measurement contract):

```sh
zig build zjs --summary all
flock -x /tmp/zjs-host-heavy.lock taskset -c 19 \
  python3 tools/perf/bench_v8/run_benchv8_compare.py \
    --zjs zig-out/bin/zjs --qjs /home/aneryu/quickjs/qjs \
    --samples 8 --output /tmp/benchv8.json
```

Suite provenance and license: [tools/perf/bench_v8/README.md](../../tools/perf/bench_v8/README.md).
This is a maintainer single-machine measurement (ARM Cortex-X925, Linux
6.17); there is no independent reproduction yet.
