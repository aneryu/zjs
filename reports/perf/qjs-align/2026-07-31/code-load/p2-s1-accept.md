# P2-S1: single-pass Phase2Builder — ACCEPT (2026-08-01)

Deletes the phase-2 sizing bytecode walk from ReleaseFast and replaces the
two-pass exact-fit emitter with a single-pass `Phase2Builder` (input-reserve
capacities, one joint `ensureAdditional` per lowering action, assume-capacity
writes, geometric grow fallback, Cc capacity-carry commit via
installCodeWithCapacity/installAtomOperandsWithCapacity). Scope-var plans are
computed per-op and consumed immediately; jump capacity comes from the new
per-occurrence `Phase1Topology.input_jump_site_count`; R1T sparse relocation
is untouched. Debug/ReleaseSafe run the FULL old two-pass shadow without
committing, compare item-wise (code bytes, atom sequences, jump sites,
patched targets, source pcs, target rows, exact counts), then commit the
single-pass product.

Implemented per the orchestration instruction by codex through a three-stage
workflow on branch p2-s1 (`22841cca` builder+primitives, `bdba9e5e`
single-pass core, `5ec1547e` grow/OOM matrix), each stage independently
verified by its driver and reviewed here. One collateral fix: the D1a
comptime size pins broke under the 8-byte nan-boxed representation
(test-altrepr was not in D1a's gate list); pins are now
representation-aware (`cbc50327`).

## Arbitration (macro-only, tightened bar: clearly-positive-or-NO-GO)

Baseline colds `cb4b62a6`/`142cfa70` (@ main b3d396ec); candidate cold
builds byte-identical `1fcfa2ca` ×2 (two real build processes, disclosed).

| pairing | zoo code-load (12 ABBA) | S1 med [range] | base med [range] |
|---|---:|---|---|
| a1×b1 | **1.0433** | 15311 [15278–15341] | 14676 [14652–14724] |
| a1×b2 | **1.0339** | 15171 [15120–15206] | 14674 [14664–14710] |
| a2×b1 | **1.0427** | 15308 [15223–15327] | 14681 [14601–14729] |
| a2×b2 | **1.0339** | 15178 [15142–15203] | 14681 [14606–14698] |

Sample ranges fully separated in all four; the b1-vs-b2 spread (~1pp on an
identical binary) is run-state variance, both decisively positive.
Normalized: insn/score **0.9676/0.9699**, cyc/score **0.9626/0.9644** —
cycles improve more than instructions (IPC gain; the delete-a-pass shape).
Full 15: geomean **0.7016**, **code-load 0.469** (first time off the bottom
of the suite, above pdfjs 0.457), all other benches inside their noise
bands (regexp 1.140).

ACCEPT conditions: four medians positive ✓ clearly-positive distribution ✓
cyc/score < 1 ✓ insn/score not negative ✓ ReleaseFast sizing walk verified
stripped ✓ grow = 0 on the corpus (shadow compareProducts pins exact ==
used per function) ✓ Cc slack/allocation ledger ✓ 15-bench clean ✓
Debug/ReleaseSafe shadow oracle green over 480+240 corpus compiles ✓.

Gates at tip: test262 0/49775, unit 2061 (incl. builder ownership,
accounting-roundtrip, grow fixtures, OOM matrices), test-oom 20/20,
test-altrepr 2061 green, force-GC 320+73, smoke, architecture + API
snapshot clean, ReleaseSafe corpus spot 240/240.

Campaign position: code-load 0.438 → 0.469 across B1+A+R1T+S1
(+7.1% relative). Next per the routing table: re-instrument, then decide
among the paused candidates with fresh exclusive shares. TargetId /
p3_topo / C2a / LabelId remain closed/paused.
