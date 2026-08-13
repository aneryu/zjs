# PDFJS-DIAGNOSIS — first-stage causal closeout

```
PDFJS-DIAGNOSIS-PHASE-1
STATUS:            COMPLETE / FROZEN ARCHIVE
VERDICT:           NO DOMINANT SINGLE MECHANISM
ACCOUNTED DEFICIT: 97.6-97.9%
CAUSALLY NAMED:    23.689M cycles / 10.8%
NEXT:              independent cross-benchmark call-boundary diagnosis
```

> ⚠️ **SUPERSEDED.** The earlier figure "137M cycles, about 60% unexplained"
> (D4, 2026-08-12) is **not a current fact** and must not be cited again except
> as history, together with the reason it was overturned. The independent rerun
> measures a **219.315M-cycle** total production deficit.
>
> ⚠️ **On the word "diffuse."** This report does NOT prove that every remaining
> mechanism is below 10%. The operational conclusion is:
>
> > Under the global hypotheses covered and intervened on in this round, no
> > single dominant mechanism accounting for >=10% of the total deficit was
> > found; the two validated mechanisms are each below 10%, and the remaining
> > residual is classified as diffuse **on current evidence**.
>
> A later line finding, say, a 15% mechanism would not contradict this archive.


## Result

The old “137M cycles, about 60% unexplained” number is not a current fact. The
independent rerun measures a **219.315M-cycle total production deficit**. P1
assigns 97.6–97.9% of that net deficit to stable semantic regions, and P2/P3
show that the large positive regions are aggregates of small mechanisms rather
than one missing opcode-count model.

The first-stage causal model is:

1. PdfJS performs essentially the same bytecode work (z/q opcode count
   **0.997327**), and its ordinary hot-op value tags/arms also match.
2. zjs pays a distributed execution cost across handler dependency/dispatch
   shape, string backing, and native-call bookkeeping. The negative regions
   (allocation, arithmetic/conversion, frontend, RC) offset part of those
   positive costs.
3. Two specific pieces are causally named:
   - active native-call backtrace publication/restoration: **14.074M cycles,
     6.42%** of the current gap;
   - equal-length rope traversal in strict equality, enabled by zjs carrying
     1.090M more ropes through selected hot operands: **9.615M cycles, 4.38%**.
4. Both mechanisms pass a macro-path detector plus a positive amplification
   and a negative/ablation intervention. Neither is inferred from samples.
5. Under the hypotheses covered in this round, no tested or source-bounded
   individual mechanism reaches 10% of the gap, much less the required 20%
   (this is an operational finding, not a proof about undiscovered mechanisms). Counterpart-aware CASE comparisons, source/IP
   subdivision, and explicit interventions exclude the proposed global joins:
   ordinary value mix, excess RC/ownership work, allocator/memory stalls,
   stack growth, native helper boundary, native environment copying, and one
   code-layout/BTB accident.

## Stable region ledger

| net region | period 65,521 | period 65,519 |
|---|---:|---:|
| dispatch / hot handlers | +152.79M | +147.88M |
| string / regexp | +69.29M | +70.37M |
| call entry / return | +61.07M | +62.57M |
| property / array helpers | +9.86M | +12.02M |
| arithmetic / conversion | -31.68M | -31.38M |
| allocation | -18.77M | -18.25M |
| frontend / compile | -17.04M | -16.87M |
| RC / teardown | -14.58M | -15.07M |
| unassigned `other` | +3.01M | +3.77M |

These are mutually exclusive flat-sample regions. Positive regions exceed the
net deficit because the negative regions favor zjs. The two prime periods have
the same signs, eight of eight paired samples for every major region, and
sampled total gaps within 0.7% of the production PMU gap.

## Stop-condition decision

The >=80% attribution condition is met. The >=20% single-cause branch is not:
the largest validated baseline mechanism is 6.42%. The alternative branch is
met by the diffuse upper-bound and exclusion audit in
`PDFJS-DIAG-P3-INTERVENTIONS.md`: after counterpart-aware subdivision and the
two causal debits, every observed positive component is below the 21.931M
10%-threshold, while all tested global joining hypotheses are negative.

Therefore the honest name of the deficit is **a diffuse interpreter execution
deficit dominated by handler/dependency shape, with validated native-backtrace
and equal-length-rope subcomponents**. It is not “137M in calls,” “more
opcodes,” “more RC,” or a single layout accident.

This closes the requested first diagnostic stage. It does not authorize an
optimization: every intervention is diagnostic-only, no production patch is
proposed, and the repository engine-source diff is required to remain zero.

## Provenance

- zjs SHA: `0710394f58ea123a3d8ff54b389aadb45065c6dc`
- QuickJS SHA: `04be246001599f5995fa2f2d8c91a0f198d3f34c`
- Zig: `0.16.0`
- production zjs binary:
  `c0ad7c3e1650bbab33cc8e4022dddf1813630e9b55ad40528cde580aeac65f96`
- production qjs binary:
  `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d`
- CPU 19, ReleaseFast, parallelism 1, no `flock`
- production instrumentation flags: none
- frequency builds: P2 edge/shape/arm/helper/RC/frame/cold-path counters only;
  never timed
- intervention builds: individually isolated uninstrumented diagnostic
  ablation/amplification only; never combined into the production binary

## Report chain

- `PDFJS-DIAG-P0-FACTS.md`
- `PDFJS-DIAG-P1-REGIONS.md`
- `PDFJS-DIAG-P2-DECOMPOSITION.md`
- `PDFJS-DIAG-P3-INTERVENTIONS.md`

