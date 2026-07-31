# Lowering-pipeline pass instrumentation (2026-07-31, scratch build)

Per-pass exclusive shares of `runPhases` on the fixed compile-mode micro
(120 iterations, 240 compiles, 71,282 function lowerings; cntvct_el0 tick
brackets in a scratch worktree at `4892d379`; instrumentation NOT merged —
the probes distort what they measure, overhead ~1-3%). Shares are relative
within the pipeline; `phases_total` covers resolve_variables +
resolve_labels + stack_size + pc2line + capture/publish.

| pass | % of phases_total | notes |
|---|---:|---|
| p2 resolve_variables total | 49.12 | |
| — p2_bind (bindParserLabels) | 8.18 | **not targeted by any approved cut** |
| — p2_topo_alloc (nodes alloc+memset, 4B/byte) | 2.11 | C4a |
| — p2_topo_scan (linear scan) | 4.66 | stays under C4a |
| — p2_topo_solve (worklist alloc + BFS, 8B/byte) | 4.53 | C4a |
| — p2_topo_count (scope-var count) | 2.22 | |
| — **p2_ledger (five make_ref arrays alloc+memset)** | **0.12** | **C3 demoted: has_make_ref is rare in this workload; the 16B/byte ledgers almost never allocate** |
| — p2_events (analyzeResolutionEvents) | 5.77 | |
| — p2_sizing | 8.48 | |
| — p2_write (copy + pc_map 8B/byte + patch + remap) | 10.81 | largest p2 sub-pass |
| p3 resolve_labels total | 36.61 | |
| — p3_topo (TargetTopology) | 9.69 | **independent of phase-1 CFG; untargeted** |
| — p3_layout (fixed-point) | 16.09 | C1+C2a target |
| — p3_emit | 9.76 | C1 target |
| rest (stack_size + pc2line + capture + publish) | 14.27 | |
| p6_prep (prepareCurrentBeforeChildren) | 4.59 | outside phases_total |
| p6_validators (final atom-owner + var-ref scans) | 3.66 | ≈1.5-2% of process — measured cost of the C0 rejection, acceptable |
| p6 packing (create_total − contained phases − validators) | ~5.7 | |

Counters: fold_calls 12,207,034 = **171.2/function = ~3.2 recomputes per
instruction** (2.17 layout rounds + 1 emit pass) — C1's cache multiplier is
real. p2/p3 sub-sums reconcile with their totals to within 2.07%/0.69%.

## Consequences for the approved sequence

- C1 (+C2a) remains first: layout+emit = 25.9% of the pipeline carry the
  3.2x fold recompute.
- **C3 drops to the tail**: measured 0.12% alloc+memset (its ledger-row
  attribution was PLAUSIBLE-by-code-reading and is hereby corrected — the
  memset profile row must come mostly from p2 nodes, p2 pc_map, p3 sizes /
  states, not the make_ref ledgers). The reachable-has_make_ref fix stays
  worthwhile as hygiene, not as a perf lever.
- C4a's measured target is topo_alloc + topo_solve ≈ 6.6% of pipeline.
- New unattributed candidates for a future ruling: p2_bind 8.2%,
  p3_topo 9.7%, p2_write 10.8%, p2_sizing 8.5%.
- Stage forecasts must be recomputed from these exclusive shares
  (rulings.md: no summing of overlapping symbol attributions).
