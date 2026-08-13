# CALL-BOUNDARY-DIAGNOSIS (CPU 19)

```
CALL-BOUNDARY-DIAGNOSIS
STATUS:  CLOSED — no continuation condition met
GATE 1:  single residual mechanism >= 20M in PdfJS   -> FAIL (backtrace tax 14.074M)
GATE 2:  same mechanism, same direction, >= 4 benchmarks, stable per-call deficit -> FAIL
GATE 3:  cross-Zoo aggregate >= 0.20 pp              -> FAIL (132.237M raw -> 0.1355 pp)
NOTE:    the return region is 8/8 same-direction in 13/15 benchmarks but remains an
         UNNAMED region overlapping the already-sealed diffuse call tax, so it may
         not be packaged.
NOTE:    native-backtrace-publication stays CANDIDATE BLOCKED on semantic eligibility.
```


## Ruling

**No cross-Zoo mechanism is authorized for intervention or packaging.**

The named `NativeBacktraceScope` publish/restore mechanism is broadly exposed,
but the PdfJS causal price transferred by exposure predicts **0.1355 pp** over
the 15-item Zoo, below the required 0.20 pp.  Its raw predicted saving is
132.237M cycles across fifteen differently sized fixed workloads; that raw sum
must not be converted directly to a Zoo score.  A cycles-perfect, uncalibrated
15-item log-geomean upper bound is 0.2768 pp, but it contradicts the task's
empirical PdfJS calibration (`23.689M ~= 0.06 pp`).  Applying that supplied
calibration gives the decision-relevant 0.1355 pp.

The separately sampled return region is real and cross-benchmark: 13/15
benchmarks have positive zjs-minus-qjs return deltas in all 8 paired samples.
For the call-heavy cluster, the region is commonly about 14--21 cycles per
semantic call (DeltaBlue 16.54, EarleyBoyer 15.22, GBEmu 14.40, Mandreel
15.74, Richards 20.62, Splay 21.13, TypeScript 19.48).  This is still a
**region**, not a named fixed-tax mechanism.  Its magnitude also overlaps the
already sealed diffuse call tax; the sampling data do not identify one seam to
remove or package.  Entry does not generalize: only 5/15 benchmarks are
positive in all 8 pairs and its sign flips across the call-heavy set.

Therefore none of the three continuation conditions is satisfied by a named
mechanism:

1. PdfJS named residual: backtrace is 14.074M cycles, below 20M.  PdfJS's
   sampled entry (+63.9M) and return (+16.0M) are region buckets, not individual
   mechanisms.
2. No mechanism has a directly measured, stable per-call deficit in three
   benchmarks.  Backtrace has one causal price (PdfJS) plus cross-Zoo exposure;
   the stable return result is unnamed regional evidence.
3. The calibrated backtrace prediction is 0.1355 pp, below 0.20 pp.

The existing semantic block on `native-backtrace-publication` remains in force.
It is not upgraded or packaged here.  No intervention patch was made.

## Primary exposure matrix

Counts are medians of counter-only ABBA8 runs.  `JS->native z` is the comparable
observable `C_FUNCTION` seam; `BT scopes` is the broader, correct exposure
count for the named zjs mechanism.  Entry/return values are fixed-period flat
sample estimates; parentheses give zjs-minus-qjs cycles per semantic call.
`Zoo pp` is the calibrated predicted contribution of the named backtrace
mechanism only.

| benchmark | JS->JS q/z | JS->native q/z | re-entry q/z | entry delta M (cyc/call) | return delta M (cyc/call) | BT scopes | named delta M | Zoo pp |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| box2d | 1.556/1.469M | 0.705/0.704M | 0.160/0.248M | +11.8 (+6.73) | +36.5 (+16.84) | 0.704M | 4.04 | 0.0104 |
| code-load | 0.003/0.003M | 0.007/0.005M | 0.001/0.000M | +0.7 (+74.56) | +0.3 (+38.14) | 0.006M | 0.03 | 0.0004 |
| crypto | 2.006/2.006M | 0.498/0.498M | 0.000/0.000M | -12.5 (-4.78) | +72.8 (+29.06) | 0.561M | 3.22 | 0.0020 |
| deltablue | 30.940/31.164M | 1.436/1.212M | 0.224/0.000M | -592.4 (-18.12) | +535.1 (+16.54) | 1.212M | 6.95 | 0.0040 |
| earley-boyer | 15.010/10.305M | 7.948/7.948M | 0.000/0.000M | -184.1 (-3.31) | +274.0 (+15.22) | 7.948M | 45.56 | 0.0233 |
| gbemu | 2.588/2.588M | 2.188/0.378M | 0.000/0.000M | -82.6 (-12.32) | +41.6 (+14.40) | 0.552M | 3.17 | 0.0053 |
| mandreel | 13.194/13.194M | 0.394/0.355M | 0.000/0.000M | -394.4 (-28.94) | +213.2 (+15.74) | 0.355M | 2.03 | 0.0010 |
| navier-stokes | 0.002/0.002M | 0.000/0.000M | 0.000/0.000M | +0.0 (+0.02) | +0.0 (+35.51) | 0.000M | 0.00 | 0.0000 |
| pdfjs | 0.629/0.628M | 2.201/2.159M | 0.006/0.005M | +63.9 (+23.13) | +16.0 (+5.73) | 2.455M | 14.07 | 0.0356 |
| raytrace | 5.637/5.637M | 2.935/2.935M | 2.531/2.531M | +244.8 (+28.68) | +262.2 (+30.61) | 2.935M | 16.83 | 0.0120 |
| regexp | 0.458/0.458M | 3.101/3.094M | 0.000/0.000M | +85.8 (+24.34) | +12.4 (+3.44) | 3.095M | 17.74 | 0.0284 |
| richards | 20.770/20.769M | 0.007/0.007M | 0.000/0.000M | -395.5 (-19.05) | +428.9 (+20.62) | 0.008M | 0.05 | 0.0000 |
| splay | 1.276/1.210M | 0.024/0.024M | 0.000/0.000M | -32.8 (-24.36) | +25.8 (+21.13) | 0.024M | 0.14 | 0.0003 |
| typescript | 10.301/10.773M | 3.491/3.012M | 0.475/0.000M | -110.1 (-7.79) | +268.8 (+19.48) | 3.105M | 17.80 | 0.0126 |
| zlib | 0.444/0.444M | 0.107/0.107M | 0.000/0.000M | -22.6 (-40.81) | +24.9 (+45.39) | 0.107M | 0.61 | 0.0001 |

The PdfJS entry column reproduces the existing combined-region anchor within
sampling uncertainty (+63.9M here versus +61.07M at the same prime under the
older combined classifier).  The explicit return column is new: it moves the
ordinary return handlers out of the dispatch bucket, so entry plus return must
not be compared numerically with the older combined classification.

## Whole-workload PMU normalized by calls

These values answer the requested instructions/cycles/backend-stall per call,
but are deliberately labeled as **whole-workload normalization**.  They are not
isolated boundary unit prices: benchmark body work remains in the numerator.
All counters come from unmodified frozen production binaries.

| benchmark | instructions/call q/z | cycles/call q/z | backend/call q/z | total cycle delta M |
|---|---:|---:|---:|---:|
| box2d | 2391.05/2536.09 | 521.35/585.54 | 173.93/167.00 | +93.2 |
| code-load | 122212.58/109207.83 | 30688.06/28583.11 | 5358.76/4177.82 | -45.0 |
| crypto | 14336.83/11559.54 | 2223.92/2138.09 | 473.24/306.38 | -212.9 |
| deltablue | 598.16/792.14 | 153.31/175.70 | 82.55/80.38 | +725.4 |
| earley-boyer | 1119.88/1625.48 | 226.68/350.86 | 74.95/102.35 | +1197.7 |
| gbemu | 1960.29/3360.88 | 367.01/662.75 | 114.75/167.93 | +212.4 |
| mandreel | 2754.83/2813.55 | 462.98/500.01 | 96.30/100.74 | +489.1 |
| navier-stokes | 5062254.36/4884271.10 | 881234.08/930102.15 | 196577.21/308022.15 | +89.8 |
| pdfjs | 2067.96/2226.41 | 380.50/464.65 | 83.64/111.37 | +221.8 |
| raytrace | 1812.98/2484.12 | 376.07/534.71 | 127.25/110.16 | +1362.1 |
| regexp | 3638.47/2819.95 | 627.63/575.44 | 69.57/103.93 | -197.1 |
| richards | 887.50/1045.18 | 207.42/229.14 | 103.48/99.91 | +451.9 |
| splay | 2848.88/3216.99 | 901.36/1097.99 | 477.60/597.85 | +182.4 |
| typescript | 1160.75/1301.48 | 317.87/334.46 | 152.66/126.17 | +227.9 |
| zlib | 162065.76/155590.52 | 27505.70/30350.41 | 2205.37/1653.83 | +1573.2 |

`stall_backend_mem` is present in the raw PMU JSON and the joined CSV.  No PMU
row was `<not counted>` or `<not supported>`.

## Frame, reload, publication, poll, and fence exposure

All push/pop and publish/restore pairs balance in every run.  QJS
`republication` is its current-frame bytecode publication; zjs republication is
the same-Machine entry publication, hence the columns are implementation seams
rather than expected equal work.

| benchmark | frame push/pop q | frame push/pop z | republication q/z | reloadTop z | reloadAfterPop z | poll q/z | fence q/z |
|---|---:|---:|---:|---:|---:|---:|---:|
| box2d | 1.717/1.717M | 1.717/1.717M | 1.717/1.469M | 0 | 1.144M | 8.115/8.115M | 0.160/0.248M |
| code-load | 0.004/0.004M | 0.004/0.004M | 0.004/0.003M | 0 | 0.003M | 0.027/0.027M | 0.001/0.000M |
| crypto | 2.006/2.006M | 2.006/2.006M | 2.006/2.006M | 0 | 1.936M | 52.334/52.342M | 0/0 |
| deltablue | 31.164/31.164M | 31.164/31.164M | 31.164/31.164M | 0 | 30.512M | 54.265/54.270M | 0.224/0.000M |
| earley-boyer | 15.010/15.010M | 10.305/10.305M | 15.010/10.305M | 0 | 8.572M | 64.803/64.808M | 0/0 |
| gbemu | 2.588/2.588M | 2.588/2.588M | 2.588/2.588M | 0 | 0.815M | 29.138/27.320M | 0.000001/0M |
| mandreel | 13.194/13.194M | 13.194/13.194M | 13.194/13.194M | 0 | 0.848M | 76.990/77.260M | 0/0 |
| navier-stokes | 0.002/0.002M | 0.002/0.002M | 0.002/0.002M | 0 | 0.001M | 23.890/23.892M | 0/0 |
| pdfjs | 0.635/0.635M | 0.634/0.634M | 0.635/0.628M | 0 | 0.338M | 14.596/14.552M | 0.006/0.005M |
| raytrace | 8.167/8.167M | 8.167/8.167M | 8.167/5.637M | 0 | 4.885M | 26.693/26.695M | 2.531/2.531M |
| regexp | 0.458/0.458M | 0.458/0.458M | 0.458/0.458M | 0 | 0.425M | 7.729/7.730M | 0/0 |
| richards | 20.770/20.770M | 20.769/20.769M | 20.770/20.769M | 0 | 20.769M | 64.647/64.654M | 0/0 |
| splay | 1.276/1.276M | 1.210/1.210M | 1.276/1.210M | 0 | 0.232M | 4.293/4.294M | 0/0 |
| typescript | 10.776/10.776M | 10.773/10.773M | 10.776/10.773M | 0 | 9.381M | 43.568/43.670M | 0.475/0.000006M |
| zlib | 0.444/0.444M | 0.444/0.444M | 0.444/0.444M | 0 | 0.444M | 146.140/146.174M | 0.000001/0M |

`reloadTop` was observed zero in all Zoo runs.  Its counter output path is
covered by the same counter build, but no independently known-positive
`reloadTop` scenario was established; this zero is reported only as an
observation and is **not used to exclude a mechanism**.  The other zero-capable
detectors had the positive control described below.

## Named backtrace cost model

PdfJS's causal ABBA8 ablation is -14.0736835M cycles with 2.1940635M MAD.
The exposure run observed 2,455,127 balanced `NativeBacktraceScope`
publish/restores.  The model price is therefore **5.732 +/- 0.894 cycles per
scope pair**.  This denominator is intentionally not the 2,158,727 comparable
PdfJS `C_FUNCTION` calls: internal observable native scopes also pay the
backtrace mechanism and were included in the causal ablation.

The model transfers only that already measured PdfJS unit price.  It does not
claim that an ablation was run in another benchmark, and it does not remove the
semantic qualification block.  The largest predicted absolute exposures are:
EarleyBoyer 45.56M, TypeScript 17.80M, RegExp 17.74M, RayTrace 16.83M, and
PdfJS 14.07M cycles.

## Measurement contract and provenance

- Base zjs SHA: `0710394f58ea123a3d8ff54b389aadb45065c6dc`.
  Current worktree HEAD is `fdabe159edf4290003b8e461967304ff4ef865b6`;
  the commits after base are documentation-only and `src/`, build files, and
  Zoo tools are identical to base.
- QuickJS SHA: `04be246001599f5995fa2f2d8c91a0f198d3f34c`.
- Compiler: Zig `0.16.0`.
- Production binaries: zjs
  `c0ad7c3e1650bbab33cc8e4022dddf1813630e9b55ad40528cde580aeac65f96`;
  qjs `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d`.
- Configuration:
  `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`.
- CPU: logical CPU 19, Cortex-X925/A725 host, `armv8_pmuv3_1`; affinity was
  exactly `[19]`, no `flock`, parallelism 1.
- Workload: all 15 javascript-zoo Octane items, deterministic fixed work,
  `--iteration-divisor 16`.
- PMU: production binaries, 8 samples per engine per benchmark, ABBA, events
  `instructions`, `cycles`, `stall_backend`, `stall_backend_mem`.
- Sampling: production binaries, 8 samples per engine per benchmark, ABBA,
  flat self samples, `armv8_pmuv3_1/cycles/u`, fixed prime period 65521.  Every
  sample is classified at most once as entry, return, or excluded.
- Counter builds: frequency only, 8 samples per engine per benchmark, ABBA.
  zjs counter hash
  `0248e33fea6d114f3b61cea9d077db8960786814fbe83835264ecf6ee1ee013d`;
  qjs counter hash
  `c8c623670b3dbe9c8298d4397d352b23fcb1afdcbee6343a1e96357a352294f3`.
  Instrumentation attaches boundary counters under the profiling build,
  disables unrelated per-opcode wall clocks, and leaves the production binary
  untouched.  These binaries were never used for unit cost or PMU timing.
- Positive control: `CALL-BOUNDARY-positive-control.js` produced 12,001
  balanced bytecode frames in both engines, 11,000 derived JS-to-JS calls and
  1,000 native-to-bytecode re-entries in both engines.  Backtrace and native
  fence publish/restores were non-zero and balanced.
- Count repeatability: 14/15 benchmarks were bit-exact across all 8 runs.
  Crypto has benchmark-internal path-count jitter; all 8 raw runs are retained
  and its matrix row uses median/MAD.

The freshly rebuilt default zjs hash was not used for comparison: Zig build
bistability produced a different hash despite the same source/config.  The
required pre-PMU `zig build zjs --seed 0 --summary all` passed, after which all
timing remained on the frozen `c0ad...` binary.

## Artifacts

- `CALL-BOUNDARY-exposure-matrix.csv`: joined long-form matrix in the requested
  `benchmark | call kind | event count | z/q per-event cost | absolute deficit |
  predicted contribution` shape.
- `CALL-BOUNDARY-exposure-matrix.json`: joined values and cost-model metadata.
- `CALL-BOUNDARY-counts-ab8.json`: raw counter runs, medians, MADs, balance and
  source hashes.
- `CALL-BOUNDARY-pmu-ab8.json`: raw production PMU ABBA8 runs and summaries.
- `CALL-BOUNDARY-sampling-p65521-ab8.json`: raw flat samples, symbol breakdowns,
  classifier contract, paired deltas and MADs.
- `CALL-BOUNDARY-run-counts.py`, `CALL-BOUNDARY-run-pmu.py`,
  `CALL-BOUNDARY-run-sampling.py`, `CALL-BOUNDARY-build-matrix.py`: auditable
  runners and joiner.
- `CALL-BOUNDARY-zjs-counter.patch`, `CALL-BOUNDARY-qjs-counter.patch`:
  source-exact, apply-checkable frequency instrumentation used to build the
  counter binaries; neither patch changes a production/default execution path.
