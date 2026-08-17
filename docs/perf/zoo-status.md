# Zoo status vs Bellard QuickJS

Checked headline for the 15-benchmark zoo. This is the public performance
claim. It is not the `perf-self-check` self-baseline gate.

| Field | Value |
| --- | --- |
| Date | 2026-08-18 |
| zjs | `main@1b0e520b` |
| Protocol | official 8-sample zoo |
| Geomean (zjs / QuickJS throughput) | **1.0199** |
| At or above 1.0 | **11 / 15** |

Geomean parity is the published result. The project’s stricter “every bench
≥ 1.0” bar is not met.

2026-08-18 delta over `9fdc0e23`: three case-derived faithful knives landed —
ValueRootFrame production gating (7ebec998), `Array.push`/`splice` call-shell
alignment to `js_call_c_function`/`js_array_push` (f75723b6), and
`destroyPlainObjectFast` alignment to `free_object` (1b0e520b). deltablue and
splay crossed 1.0.

## Still below 1.0

| Benchmark | Ratio |
| --- | ---: |
| pdfjs | 0.827 |
| earley-boyer | 0.819 |
| typescript | 0.946 |
| box2d | 0.962 |

Do not cite the 2026-06-13 QuickJS-ng microbench files or older 0.93 geomean
handoffs as current. Those artifacts were removed from the active tree; recover
them from git history if needed.

The local-handoff regression gate is still (performance gates never run in
shared-runner CI; the measurement contract forbids it)

```sh
zig build perf-self-check --seed 0 --summary all
```

against `reports/perf/baseline/microbench-zjs-releasefast.json`. See
[README.md](README.md) in this directory for that workflow.
