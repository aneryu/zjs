# Zoo status vs Bellard QuickJS

Checked headline for the 15-benchmark zoo. This is the public performance
claim. It is not the `perf-self-check` self-baseline gate.

| Field | Value |
| --- | --- |
| Date | 2026-08-18 (r3) |
| zjs | `main@0280e278` |
| Bellard QuickJS | `04be246` |
| Protocol | official 8-sample zoo, parallel clusters 5-9/15-19 (new baseline protocol; not directly comparable to earlier serial-cpu19 entries) |
| Geomean (zjs / QuickJS throughput) | **1.0335** |
| At or above 1.0 | **11 / 15** |

Scores are throughput; the ratio is `zjs score / QuickJS score`, so values at
or above `1.0` indicate that zjs recorded the same or higher score in that
benchmark.

| Benchmark | QuickJS | zjs | zjs / QuickJS |
| --- | ---: | ---: | ---: |
| earley-boyer | 4,435.0 | 3,856.5 | 0.870 |
| pdfjs | 7,186.0 | 6,581.5 | 0.916 |
| box2d | 7,227.0 | 6,867.0 | 0.950 |
| typescript | 21,929.5 | 21,188.5 | 0.966 |
| splay | 6,714.5 | 6,825.0 | 1.016 |
| deltablue | 1,405.0 | 1,436.5 | 1.022 |
| richards | 1,613.5 | 1,686.5 | 1.045 |
| gbemu | 12,536.0 | 13,355.5 | 1.065 |
| mandreel | 1,983.0 | 2,128.0 | 1.073 |
| crypto | 1,843.0 | 1,987.0 | 1.078 |
| raytrace | 3,313.5 | 3,593.5 | 1.085 |
| code-load | 31,953.5 | 35,050.0 | 1.097 |
| zlib | 3,948.5 | 4,347.5 | 1.101 |
| navier-stokes | 4,174.0 | 4,598.0 | 1.102 |
| regexp | 794.0 | 921.5 | 1.161 |
| **Throughput geomean** |  |  | **1.0335** |

The suite also reports two latency sub-scores outside the 15-row throughput
geomean:

| Latency sub-score | QuickJS | zjs | zjs / QuickJS |
| --- | ---: | ---: | ---: |
| SplayLatency | 15,215.5 | 15,148.5 | 0.996 |
| MandreelLatency | 13,223.5 | 15,826.0 | 1.197 |

2026-08-18 delta over `39b8e894`: three case-derived faithful knives landed —
ValueRootFrame production gating, `Array.push`/`splice` call-shell alignment
to `js_call_c_function`/`js_array_push`, and `destroyPlainObjectFast`
alignment to `free_object`. deltablue and splay crossed 1.0. Second wave
(r2): Array named-atom fast proto walk, single markChildren body, frameless
flat string ===. Third wave (r3): in-island default instanceof walk,
hasInstance probe economics, mapped-arguments create/read slimming. All nine
knives are folded into `0280e278`. Protocol switched to parallel clusters per
driver ruling.

Do not cite the 2026-06-13 QuickJS-ng microbench files or older 0.93 geomean
handoffs as current. Those artifacts were removed from the active tree; recover
them from git history if needed.

The local-handoff regression gate is still (performance gates never run in
shared-runner CI; the measurement contract forbids it)

```sh
zig build perf-self-check --summary all
```

against `reports/perf/baseline/microbench-zjs-releasefast.json`. See
[README.md](README.md) in this directory for that workflow.
