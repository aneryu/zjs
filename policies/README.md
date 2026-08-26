# Preregistered measurement policies (BASE-G0)

This directory holds the frozen decision policies required by
`docs/roadmap.md` §0.2 item 5. Each file is preregistered **before** the
measurement it governs produces any official number; metrics may not be
chosen after results exist.

- `gc_merge_policy.json` — statistical gate for merging the tracing GC
  (`G2-GC-MERGE`), plus the `GC-GAP` measurement protocol it consumes.
- `spikes/perf-t-spike-v1.json` — typed-slot interpreter spike (`PERF-T-SPIKE`).
- `spikes/perf-dyn-spike-v1.json` — dynamic-feedback spike (`PERF-DYN-SPIKE`).
- `spikes/perf-jit-spike-v1.json` — baseline-JIT spike (`PERF-JIT-SPIKE`).
- `spikes/perf-n-spike-v1.json` — native AOT shape spike (`PERF-N-SPIKE`).

Amendment rule (applies to every file here): before the first official
sample governed by a policy is taken, the policy may be amended by bumping
`policy_version` and recording the reason; after the first official sample,
thresholds are immutable — a materially different design is a new spike
with a new policy file.

Each threshold carries a `basis`: `"doc"` means the number is stated in the
cited domain document; `"proposed"` means it was chosen at freeze time
(2026-08-26, delegated execution) and is an explicit owner-ratification
point before that spike starts.

The whole-process measurement contract
(`tools/compare/measurement_policy.json`,
sha256 `020f2f1830506c1035efafaf9747e43ee6223e40225ac2d0bac19c8d2e11ec68`)
and `docs/perf/README.md` govern how samples are taken; files here govern
what the numbers mean and which verdict they force. Reference-binary and
suite fingerprints live in `reports/evidence/BASE-G0/manifest.json`.
