# RayTrace tranche-3 outcome — six knives (three pairs) landed on main

Merged: `104e7811`. Baseline for causal A/Bs: frozen T1 binary
`/tmp/zjs-rt-integrated` (= main `07ab9b24`). T3 snapshot: `/tmp/zjs-rt-t3`.

## Knives (each pair A/B'd in an isolated worktree)

| pair | commits | isolated rt-fixed-d64 cycles |
|---|---|---|
| T3-A teardown: var_ref freed synchronously bypassing the zero-ref queue (mirrors `free_var_ref`, qjs:6164; qjs queues only OBJECT/FB/MODULE, qjs:6471) + `destroyZeroRefNow` stripped from a 304-byte-frame body to a frame-free tail-jump switch (mirrors `free_gc_object`, qjs:6394) | `05e8ba7a`, `78c46185` | **−2.84%** |
| T3-B ctor seam: simple-ctor classification published as a CallFacts bit at FB finalization (kills the unconditional per-`new` probe + dead sameValue pair; spread-side sameValue kept) + constructor return fused into the qjs two-branch epilogue (with a static proof that `constructor_completion ∧ tail_chain` is unsatisfiable) | `4f9be1e7`, `40b27cc3` | −0.71% (insn −1.54%; OoO-absorption pattern) |
| T3-C native boundary: `exec_direct` record ABI passes the native-call context by parameter, skipping the NativeCallEnvironment materialize/rebuild round trip (wired for apply/call/hasInstance) + warm fast twin for the moved-args native-boundary simple entry (98.85% counter-validated hit rate; frame args = max(argc, declared)) | `aaa23789`, `08da80bb` | **−2.65%** |

## Integrated results

| measurement | campaign start | after T1 | after T3 |
|---|---:|---:|---:|
| rt-fixed-d64 cycles vs qjs | 1.766x | 1.550x | **1.461x** |
| rt-fixed-d64 instructions vs qjs | 1.733x | 1.475x | **1.402x** |
| RayTrace Octane score | 0.565 | 0.645 | **0.679** |

T3 vs T1 interleaved: cycles −5.57%, instructions −4.87% — cycle realization
*above* the naive sum of parts, consistent with the teardown/env knives removing
pointer-chasing rather than predictable bookkeeping.

Causal cross-benchmark A/B (T3 vs frozen T1, full 15 benchmarks, 8 samples,
same session): **geomean 1.0114, zero regressions.** Movers: raytrace 1.065,
earley-boyer 1.045, crypto 1.036 (recovering T1's integrated-layout dip and
more), zlib 1.010, box2d 1.009; richards 0.998/code-load 0.999 within noise.

Notable side effect: `instanceof` (case J) improved 1.80→1.60 vs qjs — the
`Symbol.hasInstance` path shares the NativeCallEnvironment round trip that
T3-C removed.

## Gates (integrated tree)

- `test-exec` **413** (409 + 4 new boundary tests: remove_cycles rc==0 no-op,
  parked-generator open-cell death, prototype-miss fallback, ctor-return
  fusion vs abrupt mutual exclusivity), `test-bytecode` 69
- unified Debug **2157**/1/0 and ReleaseSafe **2157**/1/0
- `test262-gate` **0/49,775 errors, 44,581 passed** — bit-identical again
- splay (RC-heavy control) flat on the teardown pair; zoo fixed-work apply-free
  controls flat on the boundary pair

## Residual map after T3 (vs qjs, cycles)

G ctor ~1.68 · E2/E4 ~1.44–1.57 (per-arg var-ref access, no knife yet) ·
L0 1.58 (remaining construct-path gap is *not* the seam — CTOR-2R removed it
and only realized −1%) · D ~1.55–1.62 · C 1.34 · J 1.60 · per-new-prop write
1.34 · A 1.23 (closed model constant) · reads ahead.

Remaining structural walls (not knife-addressable): the 1.378x uniform
per-opcode engine baseline, and the audited JS→JS call-model constant.

Artifacts: `zoo-raytrace-post-t3.json`, `zoo-t3-causal-ab.json`.
