# PDFJS-DIAG P3 — causal interventions and exclusions

All interventions are diagnostic-only ReleaseFast builds made in independent
temporary source copies. The repository's engine source was never edited.
Every timing comparison uses the frozen production zjs binary as the first arm
and one uninstrumented intervention binary as the second arm; counter builds
are never timed.

## Contract and thresholds

- base zjs: `0710394f58ea123a3d8ff54b389aadb45065c6dc`
- QuickJS: `04be246001599f5995fa2f2d8c91a0f198d3f34c`
- Zig `0.16.0`, ReleaseFast, exact production configuration signature
- CPU 19, parallelism 1, no `flock`, eight ABBA samples per arm
- fixed source SHA-256:
  `1a7ebe21975991190a0e3e57d2682fe340306b8a5b4e403f3b2f5ef302ea5deb`
- frozen baseline zjs:
  `c0ad7c3e1650bbab33cc8e4022dddf1813630e9b55ad40528cde580aeac65f96`
- P0 gap: 219.315M cycles; 20% = 43.863M; 10% = 21.931M

Each run verifies affinity, binary hash before/after, exit status, the
`PdfJS: <integer>` output contract, source hash, and exact configuration
signature. The changes below are ablations/amplifications for this workload,
not proposed patches; some deliberately remove state needed by other programs.

## Validated cause 1: active native-call backtrace publication

Model: every native builtin call publishes/restores active-call backtrace
state. That work adds retired instructions and backend dependency work, but
should add little memory stall. It is only one component of the large
`nativeMethodFastDispatch` sample aggregate.

| control | intervention | instructions | cycles | backend | memory stall |
|---|---|---:|---:|---:|---:|
| negative/ablation | omit active-backtrace publication/restore | -53.285M | **-14.074M ±2.194M** | -1.511M | -0.138M |
| positive | repeat the publication/restoration work 8x | +492.644M | **+224.226M ±2.863M** | +99.891M | +0.186M |

The positive control is intentionally non-linear and is not divided by eight
to estimate a unit cost. It establishes direction and macro-path entry. The
ablation sizes the baseline mechanism at 14.074M cycles, **6.42% of the P0
gap**. This is causal but below the 20% target and below the 10% diffuse-piece
threshold.

Two splits/exclusions prevent the backtrace result from being relabelled as a
generic call-boundary tax:

- removing the other native preflight checks retires 18.462M fewer
  instructions but changes cycles by only -0.380M ±6.749M;
- replacing the copied native-call environment with a pointer view adds only
  3.892M instructions but **worsens** cycles by 17.182M ±2.049M, almost all as
  backend stall (+15.989M). Copying the view is not the deficit; the added
  pointer dependency is harmful.

Disabling the native fast route worsens by 6.122M cycles, and force-inlining
the native wrapper worsens by 37.639M. Thus neither failure to take the route
nor the helper boundary itself is the missing cause.

## Validated cause 2: equal-length rope strict equality

Model: P2 found 1,056,542 zjs ropes replacing flat Latin-1 values specifically
at `strict_eq`'s second operand. Only equal-length rope comparisons predict
extra traversal; unequal lengths should retain the length early-out. The
prediction is fewer instructions/branches and lower backend work when only
that equal-length path is flattened, with little memory-stall movement.

| control | intervention | instructions | cycles | branches | backend | memory stall |
|---|---|---:|---:|---:|---:|---:|
| negative/ablation | flatten only equal-length rope strict comparisons | -60.020M | **-9.615M ±2.924M** | -9.146M | -6.396M | -0.061M |
| positive | repeat qualifying rope equality comparison 4 extra times | +70.547M | **+16.368M ±2.682M** | +15.891M | -0.202M | +0.307M |

The controls move in the predicted directions and the frequency detector has
already demonstrated macro-path entry. This names a 9.615M-cycle baseline
mechanism, **4.38% of the P0 gap**. As with the native positive control, the
amplification is qualitative and is not divided by its repeat count.

An earlier all-rope flattening intervention added 13.475M cycles because it
destroyed the unequal-length early-out. That artifact is retained as a rejected
intervention design, not used against the causal result above.

## Sizing interventions and exclusions

These interventions do not have a complete positive/negative pair and are not
promoted to validated causes. They bound tempting aggregate explanations.

| hypothesis/intervention | instructions | cycles | conclusion |
|---|---:|---:|---|
| remove `coldNext` bounds/stop checks on the fixed workload | -45.177M | -5.931M ±2.337M | real instruction tax, at most 2.70% here; not a P3-qualified cause |
| resolve property-tail targets directly instead of table load | +7.980M | -5.330M ±4.221M | small/noisy; indirect property tail is not a large cause |
| align hot dispatch target to 16 bytes | -0.617M | -3.964M ±2.915M | small |
| align to 32 bytes | -3.228M | +0.238M ±1.337M | null |
| align to 128 bytes | -3.395M | -2.980M ±0.846M | small |
| align to 256 bytes | +0.272M | -1.021M ±3.642M | null |

The four alignment pads move the target address across distinct boundaries and
never approach 10% of the gap. This excludes one global code-layout/BTB
accident of the required magnitude; it does not claim layout has zero cost.

P0/P1/P2 add independent exclusions: backend-memory stall contributes only
0.97M to the production gap; allocation and RC regions favor zjs by 18.8M and
14.6M; zjs executes fewer dup/free/drop-zero transitions; stack growth is zero;
ordinary hot-op value-tag mismatch is 0.0198%.

## Diffuse upper-bound audit

The P1 buckets are sums, not mechanisms. The following source-aware audit is
why their 60–153M sizes are not assigned to one cause:

- Directly paired hot CASE deltas are `get_array_el` about +13.02M,
  `call_method` +7.38M, `if_false8` +1.79M, `get_field2` +2.33M, and
  `get_field` -0.12M sampled cycles. All are below 21.931M.
- The aggregate compare CASE delta is about +22.45M, just above 10%. The
  validated equal-length-rope ablation removes 9.62M, leaving about 12.84M;
  it cannot remain a hidden >=10% mechanism.
- The zjs primitive-property tail is 27.89M absolute samples, but its qjs work
  is in `JS_GetPropertyInternal`, not the CASE lines. It is therefore not a
  differential. The source-aware property/helper bucket is only +9.86M to
  +12.02M total, and its largest zjs helper self symbol is 12.88M absolute.
- The string bucket's largest individual zjs self symbols are 19.66M
  (`stringCall`), 18.35M (`stringAddStringsOwned`), and 12.22M
  (`concatFlatStringBodiesOwned`). No one reaches 21.931M, and the rope
  mechanism above is already charged across the relevant compare/string code.
- The 77M-absolute `nativeMethodFastDispatch` symbol is split by instruction
  and source line. Its largest source-line component is 8.24M absolute; other
  call-region symbols are at most 15.60M absolute. The only measurable grouped
  ablation is backtrace publication at 14.07M; preflight is cycle-null, while
  boundary removal and the pointer-view substitution worsen.
- Allocation, arithmetic, frontend, and RC are stable negative regions. The
  residual `other` bucket is only 3.0–3.8M.

This is not “several hot functions.” After counterpart-aware CASE bucketing,
source/IP subdivision, and the two causal debits, every observed positive
mechanism/component is below 10% of the current gap. The cross-cutting
alternatives capable of joining many components—ordinary value mix, excess
ownership, allocation/memory, native-call boundary, and one global layout
accident—are contradicted by counts or interventions.

## P3 decision

No candidate explains 20% (43.863M) of the P0 deficit. Two mechanisms pass
both positive and negative controls, but explain only 6.42% and 4.38%
individually. The evidence therefore supports the alternative stopping model:
the gap is a distributed sum of individually sub-10% mechanisms, not one
unnamed 137M cost center.

## Evidence

- `PDFJS-DIAG-p3-native-{backtrace-ablate,backtrace-amplify8,preflight-ablate,env-pointer}-ab8.json`
- `PDFJS-DIAG-p3-native-{base-vs-ablate,base-vs-inline,bookkeeping-ablate}-ab8.json`
- `PDFJS-DIAG-p3-stricteq-{eqlen-flatten,rope-amplify4}-ab8.json`
- `PDFJS-DIAG-p3-stricteq-flatten-ab8.json` (rejected intervention design)
- `PDFJS-DIAG-p3-coldnext-lean-ab8.json`
- `PDFJS-DIAG-p3-property-tail-direct-ab8.json`
- `PDFJS-DIAG-p3-layout-align{16,32,128,256}-ab8.json`

