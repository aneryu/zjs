# RayTrace tranche-1 outcome — four knives landed on main

Merged: `07ab9b24` (fast-forward of `perf/raytrace-integration-20260810`).
Baseline for all A/Bs: frozen `d050302c` binary (`/tmp/zjs-rt-baseline`).
Integrated binary snapshot: `/tmp/zjs-rt-integrated`.

## Knives (each A/B'd in an isolated worktree against the frozen baseline)

| knife | commits | isolated rt-fixed-d64 |
|---|---|---|
| W1 put_field cold-path single walk (mirrors `JS_SetPropertyInternal`, 4 own probes→1, dup gate sets→1, Descriptor→flags) + array-index probe class gate | `d0986ac5`, `56a63116`, `71d4ba05` | insn −10.9%, cyc −9.5% |
| W2 constructor frames admitted to the simple-frame family (mirrors qjs single-prologue construction) | `f7484e80` | insn −2.3%, cyc −3.5% |
| W4 arguments objects built by owned prop transfer + realm-cache iterator read + out-of-line builder | `373f70b3`, `d5885187`, `66718640` | insn −1.3%, cyc −1.2% |
| W3 dedicated `Function.prototype.apply` native record + `fromCodePoint.apply` semantic fix | `dd28b095` | insn −0.35%, cyc neutral (layout-lottery verified across seeds) |

Instructions composed exactly additively (−14.9% integrated = sum of parts);
cycles realized −12.2% of a −14.2% naive sum (86% realization).

## Integrated results

| measurement | before | after |
|---|---|---|
| rt-fixed-d64 instructions vs qjs | 1.733x | **1.475x** |
| rt-fixed-d64 cycles vs qjs | 1.766x | **1.550x** |
| RayTrace Octane score ratio (8 samples) | 0.565 | **0.645** |
| zoo 15-bench throughput geomean (8 samples) | 0.794 (2026-08-09) | **0.8326** |

Score moved exactly as cycles predicted (1/1.550 = 0.645).

**Attribution caveat (causal A/B against the frozen d050302c baseline, same
session, 8 samples):** the knives' own cross-benchmark effect is raytrace
1.138, typescript 1.046, box2d 1.023, navier-stokes 0.999, crypto 0.966. The
large crypto/navier moves in the table above belong to the ten interim commits
landed between the 2026-08-09 measurement base and d050302c (751831b0 zoo
hot-path alignment, argument-residency pair, string-add outlining, …) plus
cross-session spread — not to these knives. A per-knife crypto bisect read
1.001/0.999/1.007/1.005: the integrated 0.966 decomposes to no single knife
and is consistent with integrated-build layout lottery (±2.5% precedent).
No benchmark regressed beyond spread (regexp 1.094 is inside its 1.07–1.11
band).

## Gates (all on the integrated tree)

- `test-exec` 409, `test-bytecode` 69
- unified Debug **2153**/1 skipped/0 failed; ReleaseSafe **2153**/1/0 (the
  constructor-teardown abort precedent did not reappear)
- `test262-gate`: **0/49,775 errors, 44,581 passed** — bit-identical to baseline
- Semantic fix with regression tests: `String.fromCodePoint.apply(null, arraylike)`
  now returns "AB" like qjs instead of throwing TypeError; apply's non-object
  argument-list TypeError message now matches qjs (`build_arg_list`, qjs:41167)

## Post-merge residual map (callshapes vs qjs, cycles)

G ctor 1.74 · D apply(arguments) 1.62 · E4 1.61 · L0 1.59 · E2 1.57 · C2 1.54 ·
L3p 1.48 · C 1.47 · L4 1.42 · W1 per-new-prop-write 1.34 (98.1 vs 73.2 cyc) ·
E0 1.33 · A 1.23 (closed call-model constant) · reads all ahead.

New falsifications from this round, recorded for tranche 2:
- qjs's apply also double-copies (`JS_CALL_FLAG_COPY_ARGV`, qjs:20717/17846) —
  "mirror qjs's single copy" knives are void; only the dead-deinit loop and the
  double root are salvageable.
- Removing apply dispatch glue (magic switch, callable cascade, probe) is
  cycles-neutral: the remaining native-boundary cost lives in the NativeCall
  rebuild, entry setup, and materialization copies, not in dispatch.

Artifacts: `zoo-raytrace-post4knives.json`, `zoo-full-post4knives.json`,
worktree branches `worktree-wf_a6bca2c0-2c5-{1,2,4}`, `nb1-apply-dedicated-record`.
