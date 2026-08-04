# P2-R1T: transactional sparse relocation — ACCEPT (2026-07-31)

Deletes the phase-2 dense `usize[code.len+1]` relocation map (253MB/run
alloc+memset, 10.9% of slots ever queried) in ReleaseFast, replacing it with
consumer-proportional scratch: a `u32` transactional array for source-loc
new pcs (committed only at the no-fail install boundary) plus a strictly
increasing (old_pc, new_pc) jump-target table bounded by the phase-1
`is_target` census. Scratch contract ≈ 4×source_slots + 8×target_count ≈
**16MB/run vs 253MB (−94%)**. The dense map survives as the Debug/
ReleaseSafe per-item oracle (every source slot, every patched jump, every
sparse row, terminal); ReleaseFast carries no dense allocation, memset,
store, or lookup.

## Implementation notes and recorded divergences from the ruling text

- **discarded-indexed-store semantics**: the ruling described `i+1/i+2 →
  emit 后`; the shipping dense code maps `i+1 → emit 前, i+2 → emit 后`.
  The cut mirrors the CODE (publishPoint before/after respectively); the
  per-item oracle proves equivalence over the whole corpus.
- SoA target arrays instead of the suggested `TargetRemap` AoS (equivalent
  bytes; the old-pc probe touches one array), terminal as the final table
  row (+1 capacity) instead of a separate field — both oracle-compared.
- **Producer bug found and fixed**: speculative `truncateCode` never
  truncated source-loc slots, leaving orphans that the dense map silently
  remapped to whatever code later occupied those pcs (wrong line
  attribution shipping today). `truncateCode` now mirrors
  `rollbackEmission`'s slot truncation; `appendSourceLoc` gained the
  non-decreasing Debug assert, and phase-2 entry enforces the full
  fail-closed order contract (bounds, non-decreasing, instruction-boundary,
  code.len terminal) via `validateSourceLocOrder` — which immediately
  caught two hand-built test fixtures appending mid-instruction slot pcs.
- Two pre-existing transactional tests pin phase-2's allocation count; the
  Debug oracle allocation shifts them by +1 (recalibrated, one collateral
  bump reverted).
- Per the orchestration instruction, the two closing contract deltas
  (validateSourceLocOrder boundary clause + hybrid ≤8-linear lookup, and
  the §10 targeted test family) were implemented by codex driven through a
  two-agent workflow on the WIP branch (`b2e51fdc`, `bb5856b6`), verified
  independently by the driver agents and reviewed here.

## Arbitration (macro-only, per the revised protocol)

Baseline colds `55945a79`/`0982ffb2` (@ a2f7363b); candidate colds built
twice, **byte-identical** `8c511c78` (deterministic build — disclosed:
layout sampling rests on the baseline pair).

| pairing | zoo code-load ratio (12 ABBA) | new med [range] | old med [range] |
|---|---:|---|---|
| a1×b1 | **1.0194** | 14877 [14845–14894] | 14594 [14584–14608] |
| a1×b2 | **1.0196** | 14865 [14833–14886] | 14579 [14308–14603] |
| a2×b1 | **1.0077** | 14860 [14780–14894] | 14746 [14499–14763] |
| a2×b2 | **1.0077** | 14860 [14755–14886] | 14746 [14673–14773] |

Score-normalized (2 interleaved rounds/side): insn/score **0.9944 / 0.9941**;
cyc/score **0.9803 / 0.9909** — cycles improve MORE than instructions (IPC
gain — the exact inverse of the C1 no-go, as removing a memory stream
should be). Target lookups: ≤8-entry linear (~4.2 targets/function mean
from P2-00), analytically far under the TargetId reopen bar (>8 avg
comparisons). Full 15-bench zoo vs real qjs: geomean **0.7003**, every
bench inside its established noise band (code-load 0.456, regexp 1.128).

ACCEPT conditions: (1) four pairings paired-median positive ✓ (2) combined
interval clearly positive ✓ (3) cyc/score < 1.0 in all pairings ✓ (4) no
insn-cut masking (both metrics same direction) ✓ (5) scratch ledger matches
4×slots+8×targets ✓ (6) no over-noise regression across the 15 ✓.

Gates at tip: test262 0/49775, unit **2051** (incl. the trim-OOM
slot-invariance sweep and six targeted relocation cases), test-oom 20/20,
smoke 3/3, architecture + API snapshot clean, Debug oracle zero
inconsistencies over both micro corpora.

Next per the ruling: re-instrument the post-R1 pass split, then P2-S1
memory-tax control (S1-C) on the new baseline. TargetId stays closed.
