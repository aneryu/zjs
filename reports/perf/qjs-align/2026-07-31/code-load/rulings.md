# code-load campaign rulings (2026-07-31 review of main `e2e725cb`)

User review verdict on the draft plan: attribution credible, direction right,
NOT approved wholesale. Binding dispositions:

| cut | ruling | binding correction |
|---|---|---|
| A | conditional pass | independent `FlowTailSummary` state (do NOT reuse `FunctionDef.last_opcode_pos` — it is lvalue/provenance state with merge invalidation semantics); two distinct queries (absolute-only for `isLiveCode`, tagged-inclusive for epilogues); ALL label-operand writes unified through one `publishParserLabelTarget` primitive, any non-unified write/truncate/move/rebase invalidates the summary (next query does one full rebuild); full summary joins `EmissionSnapshot` so OOM rollback restores exactly (lazy rebuild only for block move / bulk rebase / non-unified writes / test injection); Debug keeps the old scans as a dual oracle; extended test list incl. tagged-vs-absolute divergence, placeholder patching, lower-than-watermark patch, moved/rebased bytecode, scope_make_ref labels, atom_label_u8/u16 + label_u16, catch/gosub, raw labels, mixed cleanup tails, OOM between source marker and opcode |
| B1 | approved | digit gate inside `parseArrayIndex` itself (mirror qjs:3465); serves as measurement-loop calibration |
| B2 | prototype only, risk raised to MEDIUM | `AtomTable.init` is currently infallible/no-alloc; pre-seeding changes init/OOM/memory model. Required shape: split `StringInternMap: bytes -> Atom` from `SymbolInternMap: bytes -> EntryIndex`; predefined hits return id without refcount traffic; numeric spellings resolve to array-index atoms before the map; exact-capacity single seeding; merge only if code-load AND startup cycles AND resident bytes all pass; tests: mid-init OOM, deinit, empty runtime, repeated init/deinit |
| C0 | **REJECTED** | `validateFinalAtomOwners` / `validateVarRefOperandBounds` stay in ReleaseFast. They are the only final production gates before no-fail ownership commit (zjs has side-owner ledger + multi-phase rewrite + unchecked var-ref runtime access; qjs-has-no-scan proves nothing). Future path: separate ownership-hardening PR making invariants construction-by-design (owner ledger emitted in lockstep, incremental `max_var_ref_index` O(1) check, all emit paths through shared owner/index publish primitives), THEN discuss removing the scans. Scratch-only build switch may measure their true share |
| C1 | conditional pass | do NOT cache the full `InputFoldPlan` union per instruction; materialize compact `LayoutRecord` {input_pc u32, input_size u16, plan_kind u8, flags u8, aux_index u32} with rare payloads in side vectors; `.unchanged` must not pay max-union size; gates add sizeof/record-count/scratch-peak accounting and a Debug/ReleaseSafe re-derive oracle vs `inputFoldPlan` |
| C2 | sent back, split | jump-site list alone reads stale positions (every shrink shifts all later source/target positions). **C2a**: relaxation iterates LayoutRecords (no re-decode, no matcher, no per-code-byte boundary writes per round), one final positions/source-loc materialization — approved next after C1. **C2b** (jump-only worklist + Fenwick prefix-delta + monotone-shrink proof + fold-plan-generated jump coverage): only if C2a leaves relaxation hot |
| C3 | approved, HIGH priority (may move ahead of C1 if instrumentation says so) | sparse `RefFoldEvent` {make_ref_pc u32, tail_pc u32, payload u32, kind u8, reads_value bool} + tail-sorted u32 index array replacing five dense per-code-byte arrays (4+1+2+8+1 = 16B/byte); ALSO fix `has_make_ref` to count only REACHABLE scope_make_ref (today set during the initial topology scan even for unreachable ones). Tests: dead make_ref, two make_refs racing one tail, crossed tail order, local/global, reads_value both, eval probe, OOM at append/index-build/sort |
| C4a | approved as corrected | `Phase1CfgNode` → `packed struct(u8) { size: u5, is_temp: bool, is_live: bool, is_target: bool }` gated by comptime assert all phase-1 sizes ≤ 31 (fallback 2B: size u8 + flags); worklist → `u32[instruction_count]` (not usize[code.len+1]); scratch is context-owned stack-borrowed arena, NO process-global scratch (reentrancy/nested compile/concurrency). Honest accounting: ~12B/byte → ~8.25B/byte ≈ −31% scratch, NOT "32x"; decode/target-discovery/worklist processing remain; phase-3 has its own independent `TargetTopology` this does not touch |
| C4b | paused, out of this campaign | linear liveness cannot be ported without qjs's LabelSlot/refcount/owner representation as a whole; ReleaseSafe validators cannot prove absence of extra retention. Requires a standalone ownership proof |

## Benefit accounting: demoted to theoretical ceiling

0.71–0.76 is a campaign ceiling conditional on ALL attributed lowering/atom
excess cycles disappearing; it is NOT a promise of C1–C4a. Stage forecasts
are to be recomputed from per-pass EXCLUSIVE cycles once the C instrumentation
run exists; overlapping symbol attributions must not be summed.

## Measurement protocol (revised, binding)

- micro: `tools/perf/codeload/` two modes — compile (fixed payload,
  throw-gated global eval, zero payload execution; for A/C) and atom
  (fixed-width salt renames, same runtime; for B). Instructions primary;
  cycles must not contradict; zoo macro arbitrates.
- formal verdicts: ≥8 paired samples ABBA, paired ratio + median/geomean +
  MAD, instructions AND cycles same-direction, two independent cold builds
  per side (all four combinations).
- richards/deltablue whole-process: gross-regression sentinel only.
  Execution-only claims need compile-once-execute-many.

## Approved sequence

1. revised micro + C pass instrumentation (scratch)   [this session]
2. B1  3. A (contract above)  4. C1  5. C2a  6. C3 (may advance)  7. C4a
8. C2b (conditional)  9. B2 (prototype-gated)  10. C0-replacement
(ownership-hardening, separate project)
