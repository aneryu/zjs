# stack3 + typed-int formal 7-lineage Zoo gate

Status: **PASS**.

This is the measurement Codex deferred. The implementation is already on
`42b6160f`. This file only records the pre-registered D10 `7×8` causal Zoo
campaign.

## Verdict

| quantity | value |
|---|---:|
| median lineage effect | **+1.3838 log-pp** |
| worst lineage | **+1.0704 log-pp** (pad 63) |
| D10 Zoo MDE `U(7,8)` | 0.278 log-pp |
| signal / MDE | **4.98×** |
| ordinary median factor | 1.01393 |
| lineage MAD | 0.0547 pp |
| observed robust σ | 0.0811 pp |
| within-lineage robust σ | 0.1901 pp |
| τ (lineage after sampling) | 0.0455 pp |
| effect gate `M > U` | yes |
| worst-pad gate `W ≥ 0` | yes |
| **verdict** | **PASS** |

All seven pre-registered pads are beneficial. The worst pad is still 3.85× MDE.

## Design

Pre-registered in the frozen campaign state, unchanged:

- pads `0,1,3,7,15,31,63`
- two independent local+global cold builds per side per pad
- all four build combinations measured
- each combination is serial-alternating ABBA2
- eight paired Zoo samples per pad
- CPU class: Cortex-X925 @ 3.9 GHz, `armv8_pmuv3_1`
- effect: `100 × ln(candidate/base causal Zoo throughput geomean)`
- pass rule: median effect > 0.278 and worst pad ≥ 0

Configuration of every binary:

`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`

## Source identity

| side | identity |
|---|---|
| baseline | `e3e8190a`, clean |
| candidate at freeze | dirty `e3e8190a` worktree, five engine/test files |
| candidate at resume | landed `42b6160f`, clean |
| engine-file diff SHA-256 | `700847c37ecf8b0203a20ad60413d068b154e9ced0a8256df5be8b66cda53869` |
| Zoo | `a17d4e0a`, clean |

The first 17 binaries were frozen from the dirty worktree. The remaining 11
were built after landing: clean `e3e8190a` for baseline, clean `42b6160f` for
candidate. The five engine/test files are the closeout package; the extra
landed files are docs only. Frozen binary SHA-256 values were rechecked after
the campaign: 0 drift.

## Dispatch

The original orchestrator measured pad 0 sequentially on CPU 8, then was
stopped so the remaining 24 independent combos could run as one-core
serial-alternating jobs on distinct X925 cores `6,7,8,9,15,16,17,19`.
Each job still has `executionMode=serial-alternating`,
`firstPositionBalanced=true`, and `samplesPerEnginePerBench=2`. Affinity is
attested, not requested.

This is not D10's "every sample on CPU 8" layout. It keeps the D10
execution *mode* and only parallelizes already-independent pad/combo pairs.
Shared-cache contention is a real risk; the observed lineage MAD is 0.055 pp
and the worst pad remains +1.07 pp, so contention did not approach the gate.

Wall time after resume: about 17 minutes for 24 combos. A single-core serial
finish would have been about 2.2 hours.

## Lineage geomeans

Effects are log percentage points; positive is candidate faster.

| pad | paired-median | ratio-of-medians | combo range | cores |
|---:|---:|---:|---|---|
| 0 | +1.6542 | +1.5894 | +1.5489 … +1.8514 | 8,8,8,8 |
| 1 | +1.4386 | +1.3679 | +1.2642 … +1.4617 | 6,7,8,9 |
| 3 | +1.3270 | +1.3086 | +1.1939 … +1.3703 | 15,16,17,19 |
| 7 | +1.3838 | +1.3053 | +1.3370 … +1.5085 | 6,7,8,19 |
| 15 | +1.3573 | +1.3755 | +1.2050 … +1.4670 | 9,15,16,17 |
| 31 | +1.4348 | +1.3000 | +0.9738 … +1.7587 | 7,8,9,19 |
| 63 | +1.0704 | +1.0164 | +0.9731 … +1.2077 | 6,15,16,17 |
| **median** | **+1.3838** | | | |
| **worst** | **+1.0704** | | | |

Pad 0 remains the strongest lineage and matches the earlier pad0 2×2 parallel
screen (median +1.448 log-pp). Pad 63 is the weakest and still well above MDE.

## Per-benchmark log effects

Each cell is `100 × ln(median_candidate / median_baseline)` from the eight
combined samples of that pad.

| benchmark | pad0 | pad1 | pad3 | pad7 | pad15 | pad31 | pad63 | median | worst |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| navier-stokes | +9.131 | +9.046 | +9.069 | +8.279 | +8.515 | +8.647 | +8.519 | +8.647 | +8.279 |
| gbemu | +4.216 | +4.629 | +4.301 | +4.544 | +4.597 | +5.352 | +4.103 | +4.544 | +4.103 |
| mandreel | +3.312 | +3.436 | +2.659 | +3.075 | +3.034 | +2.840 | +3.054 | +3.054 | +2.659 |
| regexp | +2.333 | +1.181 | +0.734 | +2.197 | +2.536 | +2.313 | +0.000 | +2.197 | +0.000 |
| zlib | +2.112 | +1.206 | +1.966 | +1.397 | +2.128 | +1.909 | +1.987 | +1.966 | +1.206 |
| pdfjs | +0.625 | +0.706 | +0.511 | +0.795 | +0.801 | +0.886 | +0.191 | +0.706 | +0.191 |
| box2d | +0.487 | +0.531 | +0.382 | +0.620 | +0.477 | +0.465 | +0.045 | +0.477 | +0.045 |
| code-load | +0.188 | +0.270 | +0.387 | −0.163 | +0.355 | +0.193 | +0.604 | +0.270 | −0.163 |
| deltablue | +0.121 | +0.322 | +0.040 | +0.365 | +0.284 | +0.732 | −0.203 | +0.284 | −0.203 |
| typescript | +0.174 | +0.243 | −0.076 | +0.308 | −0.200 | +0.363 | −0.005 | +0.174 | −0.200 |
| raytrace | +0.907 | +0.096 | −0.191 | +0.154 | −0.346 | −0.632 | −0.346 | −0.191 | −0.632 |
| earley-boyer | −0.199 | −0.173 | +0.142 | −0.058 | −0.674 | +0.087 | −0.358 | −0.173 | −0.674 |
| crypto | +0.346 | −0.022 | +0.176 | −0.448 | −0.407 | −0.674 | −0.293 | −0.293 | −0.674 |
| richards | −0.473 | −0.752 | −0.411 | −0.308 | −0.342 | −0.171 | −0.445 | −0.411 | −0.752 |
| splay | +0.561 | −0.200 | −0.062 | −1.177 | −0.124 | −2.810 | −1.606 | −0.200 | −2.810 |

The package is not uniform. Navier/GBEmu/Mandreel/zlib/regexp carry the
geomean. Richards is slightly negative on every pad. Splay is the unstable
loser: pad 31 −2.81 pp, pad 63 −1.61 pp. Those single-benchmark losses do not
fail the D10 rule, which adjudicates pad geomeans.

## Relation to the staged screen

The closeout's pad0 2×2 parallel-cluster screen was median +1.448 log-pp,
spread 0.248 pp, all four combinations positive. Formal pad 0 is +1.654
log-pp. The 7-pad median +1.384 is a little lower than that single-pad
screen, as expected once pad 63 is included, and still several times MDE.

This is a causal zjs/zjs result. It does not replace a new zjs/QuickJS
absolute baseline.

## Frozen binaries

SHA-256 of every `zjs` used in the campaign. `resumed=true` means the binary
was built after landing.

| pad | base-a | base-b | cand-a | cand-b | resumed |
|---:|---|---|---|---|---|
| 0 | `1958ab13751b` | `9a2344ab3c34` | `a5e3742cf85f` | `685e3d397053` | no |
| 1 | `9455c1b9c87a` | `880dd0e859ec` | `cd4f59610a14` | `7e8f897a524a` | no |
| 3 | `4fc30b6a33a1` | `5b372f02d39f` | `44eadb89989c` | `cfe8a97a1aea` | no |
| 7 | `09074d0aed4f` | `e1ea2064bb82` | `7965e9265968` | `17c301f2e884` | no |
| 15 | `a0d3467014c6` | `08391857c3f8` | `40414d2d6b29` | `c78eccdbfd20` | base-a no; others yes |
| 31 | `3622201e795f` | `901610873f5f` | `d759104ba19c` | `a07f73331713` | yes |
| 63 | `c5bd2243c738` | `08d985e1ce48` | `76a5adc72f82` | `68f6124e83ab` | yes |

Full hashes are in `STACK3-TYPED-INT-formal/formal-lineage.json`.

## Artifacts

Directory: [`STACK3-TYPED-INT-formal/`](STACK3-TYPED-INT-formal/)

| file | SHA-256 |
|---|---|
| `formal-lineage.json` | `c5a29a1ead99ab812b537bf700e483e6d39c7e81724027e42ce70ab37b00815a` |
| `parallel.log` | `4425497e2a329bfce959c18532964c2e356f8d2ce19828ac9aafdacac5fae78b` |

Also archived: the 28 measurement JSONs, the resume runner, the 8-core
dispatcher, the original `/tmp` orchestrator, and the interrupted serial log.
Binaries remain under `/tmp/zjs-stacktyped-formal-20260813/binaries` and are
not copied into git.

No production source changed in this measurement.
