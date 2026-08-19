# Zoo status vs Bellard QuickJS

> **2026-08-19 (owner ruling): the public performance metric moved to
> bench-v8** — the V8 benchmark suite v7 that upstream QuickJS publishes
> its own numbers with. See
> [bench-v8-status.md](bench-v8-status.md). The zoo suite remains an
> internal diagnostic (broader coverage: 15 benchmarks vs 8); the numbers
> below stay as the last zoo baseline.

Checked headline for the 15-benchmark zoo. It is not the `perf-self-check`
self-baseline gate.

| Field | Value |
| --- | --- |
| Date | 2026-08-19 (campaign zoo-r0 close) |
| zjs | `main@0c32a71c` |
| Bellard QuickJS | `04be246` |
| Protocol | **pad0 + parallel clusters 5-9/15-19, 15×8** (standing official protocol per user/driver ruling 2026-08-19; serial CPU-19 retained for adjudication cross-checks) |
| Measured image | `zjs-r0-headline-final-1bded06a` `.text` `29e0f286…` (bistable build recorded; shipped basin = independent-cold-cache basin) |
| Geomean (zjs / QuickJS throughput) | **1.0304** |
| At or above 1.0 | **11 / 15** |

Full provenance, window attestation and the per-round build-bistability
record: `headline-r0-final.md` in the maintainer's local zoo-r0 campaign
archive (not in this repository; direct after-vs-qjs sample, no synthesized
ratios).

## Superseded (do not cite)

| Claim | Number | Why dead |
| --- | --- | --- |
| r3 headline (2026-08-18, `0280e278`) | geo 1.0335; pdfjs 0.916; earley-boyer 0.870; box2d 0.950; typescript 0.966 | Contaminated field: two orphaned 100%-CPU `test-exec` processes pinned inside the official cluster (CPUs 17-18) since 2026-08-14. |
| post-r3 reconciliation | geo 1.0163 (pdfjs 0.809, typescript 1.035) | Same contaminated field; ±11pp swings are not engine. |

The clean-field re-baseline that replaced both is campaign zoo-r0 Gate 0
(2026-08-18 evening): serial CPU-19 geomean **1.0259**, parallel-calibrated
**1.0292**, throughput MDE 0.53%, layout geomean band 0.33pp
(`BASELINE-R0.md`, maintainer-local campaign archive). The r3 "1.0335" was
contamination-inflated mainly through pdfjs (0.916 contaminated vs 0.846
clean, confirmed on both protocols).

Scores are throughput; the ratio is `zjs score / QuickJS score`, so values at
or above `1.0` indicate that zjs recorded the same or higher score in that
benchmark.

| Benchmark | zjs / QuickJS | vs Gate 0 serial |
| --- | ---: | ---: |
| pdfjs | 0.8492 | +0.36pp |
| earley-boyer | 0.8859 | +0.83pp |
| box2d | 0.9550 | +0.06pp |
| typescript | 0.9578 | −0.41pp |
| splay | 1.0129 | +0.52pp |
| deltablue | 1.0284 | +0.29pp |
| richards | 1.0411 | +0.69pp |
| gbemu | 1.0690 | +1.40pp |
| crypto | 1.0770 | −0.21pp |
| mandreel | 1.0911 | +1.25pp |
| raytrace | 1.0940 | +0.97pp |
| code-load | 1.0945 | −1.45pp |
| navier-stokes | 1.1051 | +0.16pp |
| zlib | 1.1095 | +1.37pp |
| regexp | 1.1386 | +1.06pp |
| **Throughput geomean** | **1.0304** | **+0.45pp** |

Latency sub-scores (reported, out of headline geomean): SplayLatency 0.993,
MandreelLatency 1.169.

Geomean parity is the published result. The stricter "every bench ≥ 1.0"
bar is not met: pdfjs 0.849, earley-boyer 0.886, box2d 0.955,
typescript 0.958 remain below parity.

## Campaign zoo-r0 (2026-08-18/19) — what landed and what closed

One product mechanism landed: **island-thin wide `goto`/`goto16`**
(`main@0c32a71c`, coldStd 51→12 insn, frame 64→0, matching the `goto8`
template; qjs runs 14 insn in-CASE). Full five-gate chain is in the commit
message; Earley-Boyer is the main beneficiary (+0.83pp).

Everything else was adjudicated closed with numbers, none by assertion:
proof-carrying numeric/string opcodes (static proveability 0/1560 TS,
9/4752 Box2D), `object_from_shape` (eligible literals ≪ G1 bar),
`get_array_el` read-forwarding Form A (0/3 fixed-work targets; successor
pairs ≈0 dynamically), frame-prologue slimming (predicted 1.34%, measured
0.16%), dense-get re-proof (0.16–0.26%), rope/string equality region
(event ceilings ≤0.36%), `get_field` arms (own-hit already 7 insn cheaper
than qjs). Per-mechanism verdicts: `MECHANISM-LEDGER-R0.md` in the
maintainer-local campaign archive.

The shared remainder — front-end density/miss tax (2.1–2.4× FE-stall on
all four laggards) and the +10–12 cyc/call family constant — is documented
as an architecture-tier evidence pack (`DEFERRED_TO_ARCHITECTURE`). The
PLAN §10 architecture trigger did not fire this round.

Do not cite the 2026-06-13 QuickJS-ng microbench files or older 0.93 geomean
handoffs as current. Those artifacts were removed from the active tree; recover
them from git history if needed.

The local-handoff regression gate is still the following command (performance
gates never run in shared-runner CI; the measurement contract forbids it):

```sh
zig build perf-self-check --summary all
```

against `reports/perf/baseline/microbench-zjs-releasefast.json`. See
[README.md](README.md) in this directory for that workflow.
