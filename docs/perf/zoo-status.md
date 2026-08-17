# Zoo status vs Bellard QuickJS

Checked headline for the 15-benchmark zoo. This is the public performance
claim. It is not the `perf-self-check` self-baseline gate.

| Field | Value |
| --- | --- |
| Date | 2026-08-17 |
| zjs | `main@9fdc0e23` |
| Protocol | official 8-sample zoo |
| Geomean (zjs / QuickJS throughput) | **1.0141** |
| At or above 1.0 | **9 / 15** |

Geomean parity is the published result. The project’s stricter “every bench
≥ 1.0” bar is not met.

## Still below 1.0

| Benchmark | Ratio |
| --- | ---: |
| pdfjs | 0.8141 |
| earley-boyer | 0.8153 |
| typescript | 0.9443 |
| box2d | 0.9668 |
| splay | 0.9952 |

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
