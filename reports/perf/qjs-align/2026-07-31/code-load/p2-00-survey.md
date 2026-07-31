# P2-00: phase-2 mechanism survey (scratch instrumentation, 2026-07-31)

Compile-mode micro, 240 compiles / 71,282 function lowerings, counters +
contiguous-segment timers in a discarded worktree at `8d67fac6` (per-
instruction interleaved work counted, never timed — timer reads are invalid
at ~10-instruction granularity). Ticks are cntvct_el0.

## Dense pc_map (P2-R1 candidate) — QUALIFIES, first

| fact | value |
|---|---|
| pc_map alloc+memset | **253.2MB** per run (8B × (input+1) per function) |
| memset alone | 32.8M ticks (vs write loop 53.3M total) |
| map stores | 7.4M (+ uncounted fold-arm consumed-pc fills) |
| jump queries | 356,412 (unique targets **296,290** = 0.94% of input bytes) |
| srcloc slots | 3,244,298 (unique PCs 3,175,050) |
| union of queried old_pcs | **3,448,539 = 10.9%** of map slots |

89% of the dense stream is never read. The two consumers split cleanly:
- source-loc slots are emitted in monotone pc order and the write pass
  advances old-pc monotonically → **streaming inline remap, zero storage**;
- jump targets need stored relocations, but phase-1 topology already marks
  `is_target` on every node — the write pass can append (old_pc → new_pc)
  for flagged pcs into a compact sorted array (~4.2 entries/function) and
  the patch loop binary-searches it. **No new scan, no dense stream.**
  Terminal `code.len` entry special-cased. Debug/ReleaseSafe keeps the
  dense map as the comparison oracle per the ruling (R1 contract).

## Sizing pass (P2-S1 candidate) — QUALIFIES, second

Output is universally smaller than input: ratio max **0.549**, 100% of
71,282 functions ≤ 0.75 (aggregate 12.3MB out / 31.6MB in = 0.39; atoms
0.376). Grow simulation: reserve = input_len → **zero functions grow, zero
bytes copied**; same at input×9/8. `t_sizing` = **70.1M ticks** — the
largest single deletable segment measured. Cost side (memory-tax control
required before implementation): transient output buffer grows from
exact-size (0.39×input) to input-size (~2.6× actual), and the existing
trim-copy becomes universal (12.3MB linear streaming copies per run).

## p2_bind (P2-B1) — DOES NOT QUALIFY, closed

lookupClosureVar 242,895 calls / **2.76 rows per call**;
lookupGlobalClosureVar 3.07; addOrFindClosureSource 1.95;
ensureGlobalClosureVar 10.6 rows over only 3,242 calls;
threadClosureSource 155,525 frames; closure list max **23 rows**
(sum 149,531 over 71,282 functions ≈ 2.1 avg). No superlinearity at any
scale present in the corpus — the ruling's bar for a thresholded index is
not met. Closed unless a future corpus shows large closure lists.

## Routing recommendation

P2-R1 first: the largest deletable byte-stream (253MB alloc+memset+stores)
with zero new transient state — pure deletion, the exact post-C1 winning
shape. P2-S1 second: bigger tick prize (70.1M) but introduces an
over-reserve transient, so its memory-tax control (reserve-only, results
unchanged, zoo A/B) runs first. p3_topo / C2a stay paused per the ruling.
