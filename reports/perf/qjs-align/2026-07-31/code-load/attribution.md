# code-load gap attribution (2026-07-31)

Binaries: zjs `df214576` @ main `e2e725cb` (clean) vs pinned qjs `b76d1542`
@ `04be2460`. Formal zoo ratio at time of attribution: **0.438** (worst in
suite). Method: perf record `-e cycles -c 1000003` both engines on the zoo
CodeLoad, symbol tables paired mechanism-by-mechanism against quickjs.c,
normalized per score unit (the Octane harness is time-based — raw counter
totals are NOT comparable across engines). Adversarially verified: every
share re-derived from the saved reports, arithmetic exact, structural claims
read in code on both sides (verifier verdicts below).

## Verdict

The gap is **compiler throughput, not VM**: zjs spends ~85% of cycles in
lexer/parser/bytecode-pipeline symbols with no VM-exec symbol above 0.3%.
Per score unit zjs executes **2.03x instructions / 2.20x cycles** (IPC 3.66
vs 3.96). Total gap 296.8k cyc/point. Excluding the regexp mechanism (a
15–20x zjs advantage that masks the compile side), compile-side excess is
**2.52x**.

| mechanism | zjs% | qjs% | normalized | share of gap | verdict |
|---|---:|---:|---:|---:|---|
| lowering cluster (resolve_variables + resolve_labels + finalize) | 42.59 | 14.67 | 6.4x | **66%** (195.6k) | CONFIRMED |
| scratch zeroing (compiler_rt.memset), zjs-only | 4.44 | ~0 | — | 8% (24.2k) | PLAUSIBLE (no call graph; sites enumerated by read) |
| atom interning (triple lookup vs single hash) | 7.39 | 6.47 | 2.5x | 8% (24.2k excess) | CONFIRMED |
| parser O(code-len) rescans (trailingCleanupStart/hasJumpToCurrentEnd/lastParserPhaseOpcode) | 3.39 | O(1) | — | 6% (18.5k) | CONFIRMED |
| lexing | 10.6 | 18.84 | 1.24x | near parity | combined-with-atom robust (1.56x) |
| GC of accumulating artifacts | 3.09 | 5.62 | 1.21x | near parity | — |
| pc2line / line-col | 2.59 | 6.41 | **0.89x (zjs ahead)** | — | CONFIRMED |
| allocator machinery | 1.33 | 7.81 | **0.37x (zjs ahead)** | — | — |
| cacheBust RegExp replace | 0.37 | 13.14 | **~0.06x (zjs 15–20x ahead)** | −30.5k | CONFIRMED (replace micro re-measured) |

Key structural facts (read in code, both sides):

- qjs `resolve_variables` (quickjs.c:34187) is ONE linear dbuf pass, no CFG;
  `compute_stack_size` + `compute_pc2line_info` + FB packing are inlined into
  `js_create_function` (verified via nm). qjs per-code-byte scratch totals
  ~6B in one phase. zjs phase-2 allocates+memsets ≥36B/code-byte across
  phases (4B CFG nodes + 8B worklist + 16B make_ref ledgers + 8B pc_map) and
  makes ≥4 full decode passes.
- qjs's own `resolve_labels` shrink loop is worst-case quadratic and flagged
  by its author ("XXX: should reduce complexity", quickjs.c:35634) — mirror
  the mechanism, not the debt.
- `hasJumpToCurrentEnd`-family guards the no-fall-off dispatch contract
  (parser.zig:10488-10497): a wrong answer is a memory-safety bug, not a perf
  bug.

## regexp drift closure (same session)

The 1.173 → 1.087 zoo drift was adjudicated **noise**: 12-sample interleaved
new-vs-old-binary A/B (old rebuilt at `ce027912`, sha `756952b0`) gave
0.990 with heavily overlapping distributions (new 888–912, old 898–914);
run-1's zjs 936 exceeds all 24 samples measured since, from both binaries.
Current regexp level: **1.111** (12-sample). No code cause; nothing to fix.

## Micro harness validation

`tools/perf/codeload/` (payload byte-identical to the zoo benchmark; both
engines verified LEN 8348/94841; N=25 smoke reproduces the macro excess:
zjs 0.35s vs qjs 0.15s ≈ 2.3x vs macro 2.28x). Null test (same binary both
sides, 4 pairs): instructions ratio 1.00000 MAD 0.00000, cycles MAD 0.12% —
instructions are effectively exact on this workload.

Artifacts from the attribution run (scratch, not archived): cl-{zjs,qjs}.data
+ reports, regexp-{cur-vs-qjs,new-vs-old}.json, zjs-old-ce027912 under the
session job directory.
