# Cut A: FlowTailSummary — O(1) parser last-opcode / end-jump queries

Implements the reviewed contract (rulings.md): independent `FlowTailSummary`
(NOT reusing `FunctionDef.last_opcode_pos`, which is lvalue/provenance state
with merge-invalidation semantics), two distinct queries (absolute-only for
`isLiveCode`, tagged-inclusive for the function epilogues), unified label
mutation through `publishParserLabelTarget`, lazy invalidation for every
non-unified path, and the legacy scans kept as a Debug re-derivation oracle
asserted on every query.

## Shape

- `bytecode.FlowTailSummary` on each `FunctionDef` + a root-stream copy on
  the parser `State`; born valid-empty.
- All emission funnels through `appendBytesNoSource` /
  `appendBytesNoSourceAssumeCapacity` (verified: `appendBytes`/`appendBytesAt`
  route into them), which run `noteEmittedOp` (op-class fields + one-deep
  history). Label operand initial values are noted at the label-emitting
  wrappers; operand rewrites all go through `publishParserLabelTarget`,
  which reads the old value so tagged/absolute bookkeeping stays exact and
  invalidates on a watermark-lowering rewrite.
- Invalidation sites: moved-bytecode splice (`appendMovedCodeWithAtoms`),
  multi-instruction `truncateCode` (one-instruction speculative-LHS rollback
  is restored precisely from the one-deep history; measured 12,842 restores
  vs 120 failures on the compile micro), emission rollback, and the 8 direct
  `FunctionDef.appendByteCode` sites in the class machinery.
- Queries: `isLiveCode` / `caseCanFallthrough` / both function epilogues use
  the summary; the once-per-compile root eval epilogue keeps the legacy
  scans (cold, and it runs outside the State context).

## Two corrections found by measurement, one contract deviation

1. **Born-invalid was wrong.** First version started summaries invalid
   ("self-priming"); diagnosis counters showed 71,162 rebuilds for 77,405
   queries — this workload queries ~1.09×/function (epilogue-dominated), so
   every function's first query paid the full legacy scan and the cut
   measured insn +0.79% / mixed direction. Born valid-empty (with the
   class-machinery sites invalidating explicitly) dropped rebuilds to 8,882.
2. **Deviation from the ruling: rollback invalidates instead of restoring a
   snapshot copy.** Carrying the summary in `EmissionSnapshot` costs a
   ~36-byte copy in `takeEmissionSnapshot`, which runs multiple times per
   emitted instruction — measured ~0.8% of ALL compile instructions — while
   `rollbackEmission` measured **zero** executions on the corpus (it is an
   OOM-abort path). Invalidate-on-rollback keeps exactness (the next query
   rebuilds precisely) at zero hot-path cost. The ruling's intent (no stale
   state, no O(n²) return) is preserved; the letter (snapshot-precise
   restore) was traded on measured evidence.
3. **Structural residual, accepted:** `for(;;update)` clauses detach
   (multi-op truncate → invalidate) and later splice back (rebased multi-op
   append → invalidate); precise tracking across the detach window would
   overcount tagged/watermark while body statements query in between, which
   the oracle rejects. Residual: 8,882 rebuilds (≈37/compile, avg 1.1KB),
   `flowSummary` 0.73% of cycles. A future cut could revisit with a
   detach-aware design; not worth the risk now.

## Verification

- Debug oracle (full re-derivation per query) clean over: compile micro
  (240 jQuery/Closure compiles), atom micro (240 uniquified), smoke-dev,
  unit suites. New corpus test pins 17 construct classes
  (src/tests/parser.zig "flow-tail summary" test).
- Gates: zig build test 2043/2043, test262-gate 0/49775, test-oom 20/20
  (see commit message for the exact run).

## Measurement (formal, two cold builds per side, all four combinations)

Compile-mode micro, 8 ABBA pairs per combination, b = cut A, a = B1 baseline:

| combo | insn b/a | cycles b/a |
|---|---:|---:|
| A1×B1 | 0.99876 | 0.97889 |
| A1×B2 | 0.99876 | 0.97977 |
| A2×B1 | 0.99877 | 0.97710 |
| A2×B2 | 0.99877 | 0.97774 |

Instructions −0.123% (identical to 1e-5 across combos — the bookkeeping
almost exactly pays for the removed scans in instruction count); cycles
**−2.0% to −2.3%** consistently (the removed scans were cache-hot but the
O(n²) rescans on large functions dominate stalls). Atom mode: insn −0.114%,
cycles −2.02%. Zoo macro arbitration, code-load new-vs-old zjs, 12
interleaved samples: **14444 → 14802 = +2.48%**.

Cumulative campaign position after B1+A (vs qjs at the 2026-07-31 formal
run): code-load ≈ 0.438 × ~1.032 ≈ **~0.45**, to be confirmed at the next
full zoo run.
