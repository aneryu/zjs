# Controlled demo: what the probe chain is actually worth

`demo_slot_cost.zig` rebuilds only zjs's data structures (Object 64B, Shape +
inline FAM, Property packed u64, 16-byte value entries) and transcribes
`findOwnDataSlotFast`, then times it against guard + direct slot in four
regimes. No engine, no dispatch, no refcounting — just the access forms.

40M accesses per mode, pinned CPU 19, `perf stat`. Both forms verified to
produce identical checksums in every regime.

| regime | probe insn/access | probe cyc/access | slot insn | slot cyc | speedup |
|---|---|---|---|---|---|
| dependent chain (access on the critical path) | 33.1 | **33.6** | 6.1 | **11.1** | **3.0x** |
| independent accesses (ILP available) | 33.0 | 6.25 | 5.5 | 1.03 | 6.1x |
| **interleaved with a serial float chain** | 38.1 | **13.07** | 13.1 | **13.07** | **1.00x — zero** |
| through an indirect call | 33.1 | 6.25 | 5.5 | 1.03 | 6.1x |

## What this says

The mechanism removes ~27 instructions per access — that part is
workload-independent. Whether those instructions become *time* depends
entirely on whether they sit on the critical path:

- On a dependent chain the removed loads were pure latency, so the payoff is
  large and superlinear in instruction terms.
- Interleaved with a serial floating-point dependency chain the access is
  **completely hidden**: 522,883,662 cycles vs 522,839,433, a 0.008%
  difference. Removing 25 instructions per access bought literally nothing.

The first engine benchmark (`own_slot.js`) was a physics loop — exactly the
third row. It measured the one regime in which the mechanism cannot pay,
and the +3.8% it reported was a property of that benchmark, not of the
mechanism.
