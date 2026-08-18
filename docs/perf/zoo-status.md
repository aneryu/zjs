# Zoo status vs Bellard QuickJS

Checked headline for the 15-benchmark zoo. This is the public performance
claim. It is not the `perf-self-check` self-baseline gate.

| Field | Value |
| --- | --- |
| Date | 2026-08-18 (r3) |
| zjs | `main@0280e278` |
| Protocol | official 8-sample zoo, parallel clusters 5-9/15-19 (new baseline protocol; not directly comparable to earlier serial-cpu19 entries) |
| Geomean (zjs / QuickJS throughput) | **1.0335** |
| At or above 1.0 | **11 / 15** |

**Measurement-field advisory (2026-08-18 evening).** A post-campaign
reconciliation run (identical `.text` to `0280e278`, bit-for-bit) returned
geomean 1.0163 with per-bench swings up to ±11pp in both directions
(pdfjs 0.809, typescript 1.035, earley-boyer reproduced at 0.869). Root
cause found afterwards: two orphaned 100%-CPU `test-exec` processes from a
deleted worktree had been running since 2026-08-14, one pinned to CPUs
17-18 — inside the official cluster. Both the r3 headline above and the
reconciliation number were taken with that contamination present. The r3
figure stays recorded but must be re-established by a clean-field rerun
before it is cited further. The maintainability campaign itself is
performance-neutral by construction: its final production `.text` is
bit-identical to the pre-campaign binary.

Geomean parity is the published result. The project’s stricter “every bench
≥ 1.0” bar is not met.

2026-08-18 delta over `39b8e894`: three case-derived faithful knives landed —
ValueRootFrame production gating, `Array.push`/`splice` call-shell alignment
to `js_call_c_function`/`js_array_push`, and `destroyPlainObjectFast`
alignment to `free_object`. deltablue and splay crossed 1.0. Second wave
(r2): Array named-atom fast proto walk, single markChildren body, frameless
flat string ===. Third wave (r3): in-island default instanceof walk,
hasInstance probe economics, mapped-arguments create/read slimming. All nine
knives are folded into `0280e278`. Protocol switched to parallel clusters per
driver ruling.

## Still below 1.0

| Benchmark | Ratio |
| --- | ---: |
| pdfjs | 0.916 |
| earley-boyer | 0.870 |
| typescript | 0.966 |
| box2d | 0.950 |

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
