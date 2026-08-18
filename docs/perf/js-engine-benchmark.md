# js-engine-benchmark v8-v7 score

Local scoring of `zjs` with the
[ahaoboy/js-engine-benchmark](https://github.com/ahaoboy/js-engine-benchmark)
protocol. This is not the Octane zoo headline in [zoo-status.md](zoo-status.md)
and is not the `perf-self-check` self-baseline gate.

| Field | Value |
| --- | --- |
| Date | 2026-08-18 |
| zjs | `main@976e0f41` binary, report commit on this branch; `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off` |
| Protocol | one bundled `dist/run.js` per engine, official `Name: <int>` parser |
| Suite | `ahaoboy/js-engine-benchmark@4d1d79e3` (2026-08-18 published table) |
| Host | 4× Intel Xeon (KVM), Linux 6.12.94+, x86_64 |
| zjs Score | **1813 / 1810 / 1797** (three samples; median **1810**) |
| Same-host zjs / Bellard QuickJS | **0.972 / 0.978** on the two paired samples |

The suite `Score` is the geometric mean of the eight throughput benches.
This KVM host is noisy (qjs Splay moved 5541 → 4754 across samples). The
paired ratio stayed in a 0.97–0.98 band.

## Same-host comparison

Same machine, sequential runs, official binaries for the reference engines:

| Engine | Richards | DeltaBlue | Crypto | RayTrace | EarleyBoyer | RegExp | Splay | NavierStokes | Score | Time(s) | Exe |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| node 22.14.0 | 48897 | 94707 | 59332 | 87689 | 102058 | 12146 | 39075 | 56279 | 53356 | 20 | 114.6M |
| qjs 2026-06-04 (run 1) | 1279 | 1103 | 1591 | 2149 | 2550 | 646 | 5541 | 3325 | 1865 | 30 | 1.0M |
| qjs 2026-06-04 (run 2) | 1274 | 1100 | 1575 | 2328 | 2582 | 630 | 4754 | 3284 | 1838 | 31 | 1.0M |
| **zjs** (run 1) | 1126 | 1086 | 1510 | 2324 | 2338 | 732 | 4686 | 3393 | **1813** | 30 | 31.6M |
| zjs (run 2) | 1142 | 1100 | 1515 | 2347 | 2335 | 735 | 4469 | 3361 | 1810 | 30 | 31.6M |
| zjs (run 3, via runner) | 1059 | 1087 | 1485 | 2392 | 2297 | 736 | 4669 | 3366 | 1797 | 30 | 31.6M |
| qjs-ng 0.16.1 | 861 | 943 | 507 | 1855 | 2562 | 423 | 4355 | 1582 | 1243 | 39 | 2.5M |

`qjs` is the `ahaoboy/quickjs-build` nightly used by the published table
(QuickJS 2026-06-04). `qjs-ng` is the v0.16.1 `qjs-linux-x86_64` release.

### zjs / qjs per bench (paired run 1)

| Benchmark | Ratio |
| --- | ---: |
| Richards | 0.880 |
| DeltaBlue | 0.985 |
| Crypto | 0.949 |
| RayTrace | 1.081 |
| EarleyBoyer | 0.917 |
| RegExp | 1.133 |
| Splay | 0.846 |
| NavierStokes | 1.020 |
| Score | 0.972 |

Above 1.0: RayTrace, RegExp, NavierStokes. The deficit is Splay and Richards.

zjs / qjs-ng Score is **1.46**. zjs / node Score is **0.034**.

## Placement on the published ubuntu table

The published 2026-08-18 ubuntu table is a different host. Same-host `qjs`
here is 1865 vs their 1978 (0.943×); same-host `node` here is 53356 vs their
51627 (1.033×). Absolute scores are therefore only a placement hint.

| Neighbour on the published table | Their ubuntu Score |
| --- | ---: |
| hermes | 2668 |
| quickjs | 1978 |
| **zjs (this host)** | **1813** |
| **zjs scaled by local/published qjs** | **1923** |
| goant | 1652 |
| llrt | 1418 |
| txiki.js | 1403 |
| rquickjs | 1294 |
| quickjs-ng | 1256 |

On this host zjs sits just below Bellard QuickJS and well above quickjs-ng
and the other embeddable interpreters in that band.

## Score / MB

The official `Score/MB` uses the on-disk exe plus `ldd` deps, with no strip
step. The shipped `zig build zjs` binary still has debug info (31.6M). A
`strip` copy is 5.0M. Official `qjs` is already stripped at 1.0M.

| Binary | Size | Score/MB |
| --- | ---: | ---: |
| zjs as built | 31.6M | 57 |
| zjs stripped | 5.0M | 361 |
| qjs 2026-06-04 | 1.0M | 1825 |
| qjs-ng 0.16.1 | 2.5M | 504 |

Do not cite the unstripped 57 against the published qjs 1935 as an efficiency
comparison.

## Reproduce

```sh
zig build zjs --seed 0 --summary all

python3 tools/perf/js_engine_benchmark/run.py \
  --zjs zig-out/bin/zjs \
  --engine qjs=/path/to/qjs \
  --output /tmp/js-engine-benchmark.json
```

Parser contract: `python3 tools/perf/verify/test_run_js_engine_benchmark.py`.

## Upstream listing

The published table is filled by `ahaoboy/js-engine-setup` (`ei`) plus
`info.json`. Ready-to-open patches live in
[`contrib/js-engine-benchmark/`](../../contrib/js-engine-benchmark/README.md).
`.github/workflows/release-cli.yml` publishes the stripped CLI archives
`ei` needs. This environment cannot fork `ahaoboy/js-engine-benchmark`, so
the listing PRs have to be opened from a GitHub account that can.
