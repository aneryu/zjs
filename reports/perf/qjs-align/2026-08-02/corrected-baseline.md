# Corrected performance baseline of main @ 8c8787cd (2026-08-02)

STABILIZATION-3B. Measurement only — no code was changed for this run.

`8c8787cd fix(parser): release identifier and private-name token atoms
(qjs:22190)` landed on main through the correctness channel as a standalone
commit. Every prior code-load number in this campaign was produced by a binary
that leaked one atom retain per identifier occurrence, so it skipped work that
QuickJS's `free_token` (quickjs.c:22190-22208) does on every token. This
dossier re-establishes the baseline with that work present, and measures the
pre-fix binary in the *same session* so the before/after delta is not a
cross-session comparison.

## Binaries

| role | path | sha256 | repo |
|---|---|---|---|
| corrected main A | `zjs-mainfix-A` | `514e23dc9062…` | 8c8787cd clean |
| corrected main B | `zjs-mainfix-B` | `514e23dc9062…` | 8c8787cd clean |
| pre-fix (the 0.469 binary) | `zjs-S1F-b1` | `cb4b62a658b9…` | cbc50327 |
| pinned reference | `/home/aneryu/quickjs/qjs` | `b76d154265e8…` | qjs 04be2460 |

A and B are two independent cold builds (`rm -rf .zig-cache zig-out` between,
`flock -x /tmp/zjs-host-heavy.lock zig build zjs`) that came out **byte
identical**. That is stated deliberately: it means the A-vs-B pairing carries
no build-layout component at all and is a *pure run-to-run noise reference*,
not the usual two-layout protocol. Layout variance is therefore NOT bounded by
this run; only run-state variance is.

Host: kernel 6.17.0-1014-nvidia, all runs under
`flock -x /tmp/zjs-host-heavy.lock taskset -c 19`, effective affinity attested
`{19}`, zoo checkout a17d4e0a clean.

## Code-load (zoo macro arbiter, 12 samples per engine, ABBA)

| pairing | ratio | zjs median [min–max] | reference median [min–max] |
|---|---:|---|---|
| pre-fix `cb4b62a6` vs qjs | **0.4693** | 15333 [15221–15357] | 32675 [32393–32757] |
| corrected A vs qjs | **0.4460** | 14557 [14519–14595] | 32642 [32323–32719] |
| corrected B vs qjs | **0.4456** | 14560 [14457–14586] | 32674 [32364–32803] |
| **noise: A vs B** (identical bytes) | **0.9997** | 14548 [14519–14562] | 14552 [14485–14567] |

- **Corrected code-load baseline: 0.4458** (mean of the two 12-sample runs;
  the independent 4-sample full-suite run below reproduces it at 0.4448).
- **Delta vs pre-fix: −0.0235 absolute, −5.00% relative.**
- **Noise reference: 0.9997**, i.e. 0.027% — the delta is ~185× the noise
  floor, and the zjs sample ranges are *fully disjoint* ([14457–14595]
  corrected vs [15221–15357] pre-fix). This is not a marginal call.

The pre-fix binary re-measures at 0.4693 against the archived 0.4687 from the
post-S1 run — a 0.13% reproduction across sessions, which is what licenses
reading the archived campaign lineage below at face value.

## Full 15-bench zoo (4 samples per engine), corrected main vs qjs

`zoo/zoo-mainfix.json`. Compared against the archived post-S1 run
(`2026-07-31/zoo/zoo-compare-post-s1.json`).

| bench | before (post-S1) | after (corrected) | delta | rel |
|---|---:|---:|---:|---:|
| code-load | 0.4687 | **0.4448** | −0.0239 | **−5.09%** |
| regexp | 1.1399 | 1.0994 | −0.0405 | −3.55% |
| navier-stokes | 0.7137 | 0.7256 | +0.0119 | +1.67% |
| typescript | 0.7040 | 0.7011 | −0.0028 | −0.40% |
| pdfjs | 0.4573 | 0.4588 | +0.0015 | +0.33% |
| splay | 0.7417 | 0.7433 | +0.0016 | +0.22% |
| gbemu | 0.8365 | 0.8348 | −0.0017 | −0.20% |
| crypto / box2d / zlib | 0.7087 / 0.7410 / 0.8239 | 0.7100 / 0.7424 / 0.8255 | — | +0.19% each |
| deltablue / richards | 0.7993 / 0.7987 | 0.8004 / 0.7977 | — | +0.14% / −0.12% |
| raytrace / earley-boyer / mandreel | 0.5043 / 0.5678 / 0.8153 | 0.5037 / 0.5676 / 0.8161 | — | ≤0.12% |
| **geomean** | **0.7016** | **0.6984** | −0.0031 | **−0.45%** |

Latency (out of geomean by policy): SplayLatency 0.6318 → 0.6330,
MandreelLatency 0.8602 → 0.8649.

**Geomean excluding code-load: 0.7221 → 0.7213 (−0.11%).** The entire headline
move is code-load; the rest of the suite is flat.

`regexp` is the only other double-digit-basis-point mover and it is
noise-dominated on the *reference* side: qjs regexp samples span 783–827
(±2.7%) in this run versus 798–824 before, while zjs moved 916.5 → 903 median.
At 4 samples that ratio band is not a signal. Do not book it as a regression
without a dedicated high-sample run.

## How much of the reported 0.469 was the skipped work

**All of the 0.469 → 0.446 gap: 0.0235 absolute, 5.00% of the reported figure,
is attributable to the omitted token-atom release work.** Nothing else changed
between the two binaries' measurement conditions — same host, same session,
same pinned reference, same harness, and the pre-fix binary reproduced its
archived value to 0.13%.

Placed on the campaign lineage (all archived points measured on leaking
binaries):

| point | code-load | geomean |
|---|---:|---:|
| campaign start `e2e725cb` | 0.4383 | 0.6947 |
| post-A | 0.4537 | 0.6990 |
| post-R1T | 0.4559 | 0.7003 |
| post-S1 (reported) | 0.4687 | 0.7016 |
| **corrected main 8c8787cd** | **0.4458** | **0.6984** |

Read against its own start, the campaign's code-load claim of 0.4383 → 0.4687
(+6.9%) becomes 0.4383 → 0.4458 (**+1.7%**) — about three quarters of the
claimed gain is consumed by work the engine is required to do. Ranked on that
archived lineage the corrected end point falls *below* the post-A point
(0.4537) — though that particular comparison is confounded in the same way as
everything else in the table, since post-A was measured on a leaking binary
too.

That framing carries one honest caveat, and it is load-bearing: the 0.4383
start was itself measured on a leaking binary, so it is inflated too, and
0.4383 → 0.4458 is therefore not a like-for-like campaign delta. If the leak's
cost is roughly proportional, a corrected start would be near 0.4383 × 0.95 ≈
0.416 and the campaign's true relative gain would be close to the originally
claimed ~7%. **That is an estimate, not a measurement.** Settling it requires
rebuilding `e2e725cb` with 8c8787cd cherry-picked and re-running; until then,
the only figure this dossier asserts as measured is the end-point correction
**0.4693 → 0.4458**.

## Baseline of record

Future code-load work compares against **0.4458** (12-sample) / **0.4448**
(full-suite 4-sample) and full-15 geomean **0.6984**, on binary
`514e23dc9062…` from main `8c8787cd`. The archived 0.469 / 0.7016 pair is
superseded and must not be reused as a baseline: it was produced by a binary
that skipped required work.

Artifacts: `code-load/cl-prefix.json`, `code-load/cl-mainfix-{A,B}.json`,
`code-load/cl-noise-AB.json`, `zoo/zoo-mainfix.json`.
