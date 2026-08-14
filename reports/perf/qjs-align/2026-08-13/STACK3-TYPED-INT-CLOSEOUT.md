# stack3 + typed-int closeout

Status: **landed on `42b6160f`; formal 7-lineage Zoo gate is PASS**.
See `STACK3-TYPED-INT-FORMAL-LINEAGE.md`.

## Outcome first

The best coherent package found in this exploration is:

1. QuickJS-shaped resident handlers for `insert2`, `insert3`, and `perm3`;
2. the narrow integer-kind/int32-value TypedArray store arm, with floating kinds
   and all non-int32 values retaining the canonical conversion path.

The current formal zjs/QuickJS serial AB4 baseline is
`0.9133113024727958`. A single frozen package screen measured candidate/base
`1.0139017624`. Multiplying the two is only a projection (the baseline and
candidate effect were measured under different runner tiers), but it places the
candidate near `0.9260`: about 1.27 absolute points recovered, or 14.6% of the
current absolute gap. Roughly 7.9% additional relative improvement would still
be needed for parity even if this effect carries through formal measurement.

## Source identity

- Worktree: `/home/aneryu/worktree-stack-permute-typed-int`
- Branch: `perf/stack-permute-typed-int-20260813`
- Base: `e3e8190a2ee50968602dc2f1d5c758379e5c37db`
- Scope: five source/test files, 183 insertions / 1 deletion, plus this report
- Binary-diff SHA-256:
  `700847c37ecf8b0203a20ad60413d068b154e9ced0a8256df5be8b66cda53869`
- Frozen screening binary:
  `/tmp/zjs-stack-permute-typed-int-e3e8190-1b0913cb`
- Binary SHA-256:
  `1b0913cbde3954ddeaa24e8ec91833ef670d4d40fbbc6bffc7a459657fcf2ac1`
- Configuration:
  `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`
- Landing policy: local commit and fast-forward only; no push is authorized by
  this closeout.

## Mechanism and structure

The three stack handlers mirror QuickJS's direct stack-slot moves. `insert2`
and `insert3` perform exactly one `JSValue.dup`; `perm3` performs no dup/free.
All three stay in the fast table while the cold table keeps the canonical
implementation.

- `perm3`: 28 B
- `insert2`: 64 B
- `insert3`: 64 B
- no native stack frame, call, or spill
- tail dispatch remains `br`

The TypedArray arm only handles integer element kinds 1 through 7 when the
incoming JSValue is already int32. It therefore avoids the generic conversion
leaf and scratch-buffer store/reload for the common case. Float16/32/64,
objects, strings, BigInts, Symbols, detach/resize rechecks, immutable buffers,
and OOB semantics remain on the existing canonical path.

The combined binary preserves the standalone native shapes of both mechanisms.

## Correctness and structural gates

- `test-core`: 329 passed / 1 skipped
- focused TypedArray regression: 1 passed / 418 filtered / 0 failed
- `quick-check`: 2 passed / 1 skipped
- `checkpoint-check`: 2167 passed / 1 skipped / 0 failed; architecture and
  config-drift gates passed; test262 smoke 15/15
- ReleaseSafe full suite: 2167 passed / 1 skipped / 0 failed
- `git diff --check`: PASS

The new stack regression covers exact final opcode selection and reference-
counted identity/ownership behavior. The focused TypedArray regression covers
signed/unsigned truncation, Uint8 clamping, OOB assignment semantics, the
Float64 negative path, and observable object conversion fallback.

The Debug checkpoint, test262 smoke, and final ReleaseSafe suite now form the
local merge gate. A formal 7-lineage Zoo campaign was deliberately not run;
the performance label remains staged pad0 2x2 robustness, not formal PASS.

## Fixed-work PMU gate

Artifact:
`/tmp/zjs-stack-permute-typed-int-pmu-cpu5-d128-abba4.json`

SHA-256:
`b2721060255c63511c1d8582868c44e4f7bea1e99c04e9f0a2f546c9ee510cfe`

CPU 5, `armv8_pmuv3_1`, fixed `d128`, ABBA4. Ratios are candidate/base;
cycles below 1 are favorable.

| benchmark | instructions | cycles |
|---|---:|---:|
| NavierStokes | 0.935122 | 0.887923 |
| GBEmu | 0.963207 | 0.960047 |
| zlib | 0.974932 | 0.975327 |
| Mandreel | 0.966460 | 0.971425 |
| PDFJS | 0.994351 | 0.998456 |
| Box2D | 0.999260 | 1.003876 |
| RayTrace | 0.999616 | 1.006363 |
| EarleyBoyer | 0.999872 | 1.002688 |
| Splay | 0.998889 | 0.997771 |

No benchmark showed a stable cycles regression above 1%.

## 15-item Zoo screen

Artifact:
`/tmp/zjs-stack-permute-typed-int-zoo-parallel-ab2-1b0913cb-vs-c0ad7c3e.json`

SHA-256:
`0c4c93265267fa4e640c449d52ba9ac5cd4d197b74bc83431e9b1d76d5b95f08`

Parallel cluster-swap AB2, 15/15 coverage. Candidate/base throughput geomean:
**1.0139017624**.

| benchmark | ratio |
|---|---:|
| NavierStokes | 1.092016 |
| GBEmu | 1.043768 |
| Mandreel | 1.032437 |
| zlib | 1.027676 |
| Splay | 1.008742 |
| PDFJS | 1.008109 |
| CodeLoad | 1.004553 |
| Crypto | 1.004382 |
| Box2D | 1.001428 |
| DeltaBlue | 1.000810 |
| RayTrace | 1.001143 |
| TypeScript | 1.000674 |
| EarleyBoyer | 0.998874 |
| Richards | 0.996274 |
| RegExp | 0.992148 |

This package was better than the broader resident-nine package. Removing
resident `goto16`/long `if_true` and the four inc/dec handlers restored the
RayTrace/Earley/Splay macro results while retaining the important
Navier/GBEmu/zlib/Mandreel gains.

## Staged cold-build robustness

The first formal attempt was deliberately stopped after the cost was challenged:
`7 pads × 2 sides × 2 cold builds = 28 builds` is appropriate only for final
D10 adjudication, not continued mechanism exploration. Seventeen complete
frozen binaries remain under `/tmp/zjs-stacktyped-formal-20260813`; the
interrupted cache was discarded and no partial binary entered the state.

Instead, pad 0 used the required two independent cold builds per side and all
four combinations, each with cluster-swap AB2:

| baseline | candidate | factor | log effect |
|---|---|---:|---:|
| a | a | 1.014235 | +1.4135 pp |
| b | a | 1.015226 | +1.5112 pp |
| b | b | 1.012716 | +1.2636 pp |
| a | b | 1.014942 | +1.4832 pp |

Summary artifact:
`/tmp/zjs-stacktyped-pad0-2x2-20260813/pad0-2x2-summary.json`

SHA-256:
`f966eeb9ea72265cbe81fcf58c04401ba735b02d7f36a41a32753471e2a85ae7`

All combinations were positive. Median factor was `1.0145887`; build-combination
spread was 0.248 log percentage points. This establishes that the effect is not
a single lucky cold build. It does **not** establish cross-pad formal PASS.

## Exploration decisions

The following larger or apparently obvious directions were rejected by direct
structure, PMU, causal Zoo, or upper-bound evidence during this exploration:

- aggregate JSValue read-forwarding and production A1 carrier;
- class-first indexed dispatcher and TypedArray object carrier;
- constructor shell, original-args snapshot removal, mapped-arguments pointer
  table, and generic dispatch carriers;
- get-field stable-shape reads, registry/cached-iterator/GC accounting changes,
  and TypeScript return residual;
- push-small arithmetic lowering, broad resident opcode families, and physical
  allocation accounting as part of the best package;
- flat-string slab-slack append: 68,533 current fit events and about 70.37
  measured cycles saved per fit imply only about +0.0136 absolute Zoo points.

The flat-string evidence is archived separately in
`/home/aneryu/worktree-flat-string-census/reports/perf/qjs-align/2026-08-13/FLAT-STRING-SLACK-CENSUS-OUTCOME.md`.

## Landing decision

The implementation was reviewed against the pinned QuickJS stack-transform
and TypedArray store mechanisms. The focused regression, Debug checkpoint,
test262 smoke, configuration drift checks, and final ReleaseSafe suite passed.
The pad0 2x2 cold-build result is accepted as staged robustness for this local
increment, so it may be committed and fast-forwarded without resuming broad
exploration.

The formal D10 `7×8` campaign was resumed after landing and is recorded in
`STACK3-TYPED-INT-FORMAL-LINEAGE.md`: median **+1.3838 log-pp**, worst pad
**+1.0704 log-pp**, verdict **PASS**. Do not push implicitly.

Parity has not been reached. This package is the strongest validated increment
found, but even the optimistic projection leaves about 7.9% relative work.
