# C1 (Phase3Record fold-plan cache): NO-GO, reverted (2026-07-31)

Implemented exactly to the revised contract — 12-byte `Phase3Record`
(comptime-pinned) + payload side vector storing the full `InputFoldPlan`
union only for payload-carrying kinds, one stride-walk builder mirroring
layout/emit exactly, shared per-step cursor with always-on Debug
`input_pc`/`raw_size` asserts, Debug/ReleaseSafe re-derivation oracle at
every consumption, right-sized `initCapacity` + 8KB `stackFallback`
(precedent: the stack-size pass), fixed-point algorithm and old topology
untouched. The oracle ran clean over 480 jQuery/Closure compiles in Debug —
correctness was never the problem.

## The measurements that killed it

| measurement | result |
|---|---|
| micro compile, 4 combos (2 cold builds/side, 8 ABBA pairs) | insn −0.36..−0.39% (MAD 0), cycles −0.19..−0.70%, **all b-better** |
| micro atom | insn −0.40%, cycles flat |
| zoo code-load A/B, warm pair, 12 interleaved samples | **0.987** (new 14556 / old 14741) |
| zoo code-load A/B, cold pair, 12 interleaved samples | **0.991** (new 14612 / old 14741), sample ranges FULLY separated (14530–14598 vs 14647–14765) |
| macro normalized (perf stat over the zoo script, score-normalized) | insn/score **0.9973**, cyc/score **1.0037** |

The macro loss reproduced across two independent build pairs with zero
sample overlap — not layout lottery. The normalized triangle explains it:
C1 really does remove work (−0.27% insn/score) but pays more than it saves
in IPC (+0.37% cyc/score). The fold recompute it eliminated is ~10
instructions of cache-hot, high-IPC early-out work per call (the 3.15%
`inputFoldPlan` symbol share is dominated by the rare deep-matcher paths,
not the common early-outs); the cache replaced it with a new 12B-per-step
record stream plus a payload vector — fresh memory competing with the
macro's monotonically growing heap (live uniquified globals/atoms). The
fixed-payload micro reuses warm lines and shows the win; the real workload
shows the loss.

This is the campaign's own axiom biting the campaign: **instruction cuts
get hidden by OoO; only removing memory traffic moves macro** — and C1
*added* memory traffic (~360–760KB transient per 95KB compile) to remove
computation. The C-instrumentation multiplier (`fold_calls` ≈ 3.2×/instr)
was accurate as a count but wrong as a cost premise: per-call cost is far
below what the symbol share suggested.

## Disposition

- Reverted before commit; the rebuilt binary is byte-identical to the
  pre-C1 baseline (`3499b96c`). No production delta ever landed.
- **Do not retry fold-plan caching in this shape.** A retry would need to
  cache only the rare deep-match minority without a per-step stream, and
  nothing measured suggests that is worth its complexity.
- C2a's premise is NOT killed — its target is the per-round re-decode and
  boundary/position writes (the walk itself), not fold recomputation. But
  its "iterate LayoutRecords" design must not inherit C1's record stream
  assumption uncritically: any record materialization pays the same memory
  toll. A C2a proposal must A/B that toll first.
- Next-cut candidates stand as measured by the pass instrumentation:
  p2_write 10.8%, p3_topo 9.7%, p2_bind 8.2%, p2_sizing 8.5% — with the
  explicit lesson that shares alone do not qualify a cut; the winning cuts
  so far removed O(n²) rescans (cut A) and syscalls (P7-31), not
  recomputation.
