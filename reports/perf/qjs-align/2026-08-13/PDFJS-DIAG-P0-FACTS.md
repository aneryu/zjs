# PDFJS-DIAG P0 — independent fixed-fact rerun

Date: 2026-08-13. Track: B. CPU: 19. Parallelism: 1. No `flock`.

## Provenance

- zjs source: `0710394f58ea123a3d8ff54b389aadb45065c6dc`
- QuickJS source: `04be246001599f5995fa2f2d8c91a0f198d3f34c`
- Zig: `0.16.0`
- frozen zjs binary: `c0ad7c3e1650bbab33cc8e4022dddf1813630e9b55ad40528cde580aeac65f96`
- frozen qjs binary: `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d`
- zjs configuration: `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`
- fixed-work source: independently generated with
  `tools/perf/zoo/run_zoo_fixed_pmu.py fixed_source --iteration-divisor 16`;
  SHA-256 `1a7ebe21975991190a0e3e57d2682fe340306b8a5b4e403f3b2f5ef302ea5deb`
- production-counter instrumentation: none for the PMU run; allocator count uses
  `LD_PRELOAD`; opcode/native-entry builds are explicitly frequency-only.

Every production measurement used exact CPU-19 affinity, eight samples per
engine, and alternating `qjs->zjs`, `zjs->qjs` order. All requested PMU rows
were 100% counted; `<not counted>` and multiplexed rows fail closed. Each run
validated exit status, `PdfJS: <integer>` stdout shape, per-run stdout SHA-256,
source hash, and before/after binary hash. The timing-derived score itself is
expected to vary; the complete stdout/hash list is in the raw JSON.

## Frozen-binary facts (median; spread is MAD)

| Fact | qjs | zjs | z/q or z-q |
|---|---:|---:|---:|
| PdfJS score | 9,975 | 7,773.5 | 0.77930 |
| instructions | 5,887,253,283.5 | 6,237,386,958 | 1.05949; +350,248,399 |
| cycles | 1,105,120,365.5 | 1,320,349,799 | 1.19755; **+219,314,558** |
| cycles ratio MAD | — | — | 0.00435 |
| cycle delta MAD | — | — | 2,338,571.5 |
| IPC | 5.32725 | 4.72404 | — |
| frontend-stall cycles | 77,240,662.5 | 128,278,054 | 1.66172; +50,529,310 |
| backend-stall cycles | 254,977,340.5 | 332,298,359.5 | 1.30142; +76,432,050.5 |
| backend-memory-stall cycles | 6,818,415.5 | 7,812,240.5 | 1.14201; +968,272 |
| branch instructions | 1,048,807,486.5 | 1,223,064,010 | 1.16616; +174,265,098 |
| branch misses | 3,347,188.5 | 4,329,183.5 | 1.29365; +982,344 |

The raw architectural branch run independently reports 1,043,705,858 versus
1,217,788,616.5 retired branches (z/q 1.16684). It reports 66,775,352 versus
52,061,376 retired returns (z/q 0.77965). `BR_RETURN_RETIRED` is only an
out-of-line-return frequency proxy, not a semantic helper counter. Its positive
control detects one million explicit qjs JS calls (+1,000,517 returns); zjs's
same-machine JS calls are not native returns (+502), demonstrating why this
counter must not be relabelled as a cross-engine JS/helper count.

## Phase split (counter-free same-runtime harness, wall nanoseconds)

| Region | qjs median | zjs median | paired z/q median | ratio MAD |
|---|---:|---:|---:|---:|
| compile | 46,508,551 | 26,702,289.5 | 0.58762 | 0.01176 |
| first execute | 232,523,746.5 | 308,611,624 | 1.32858 | 0.00245 |

This reproduces the direction and approximate magnitude of the old frontend
and execution split, but these values are wall nanoseconds, not PMU cycles.

## Fixed-work frequency facts (counter builds; never used for cost)

| Count | qjs | zjs | z/q |
|---|---:|---:|---:|
| all opcodes | 97,457,771 | 97,197,149–97,197,229 | **0.997326** |
| bytecode/JS frame entries | 634,925 | 633,699–633,702 | 0.99807 |
| native C-function entries | 2,201,049 | 2,158,733–2,158,736 | 0.98078 |
| arithmetic/compare family | 16,435,838 | 16,435,480 | 0.99998 |
| branch family | 11,758,990 | 11,754,731 | 0.99964 |
| property/array family | 10,276,767 | 10,217,503 | 0.99423 |
| call/return family | 3,316,425 | 3,366,419 | 1.01507 |

The qjs counter is deterministic over all eight samples. The zjs total varies
by only 80 opcodes (0.000082%) with the timing-derived score/notification tail;
the benchmark body remains fixed. A 10,000-call positive control reports
260,020 qjs opcodes/10,001 bytecode entries and 260,022 zjs opcodes/10,001
frames, so both opcode/frame detectors demonstrably fire.

The stock zjs profile's `value_dups` and `allocations` fields do not instrument
the corresponding general paths (the former is zero here); they are excluded
instead of being treated as evidence that work does not occur. Exact
region-specific helper/RC transitions require P2 instrumentation after P1
identifies the dominant region.

## Allocator frequency (LD_PRELOAD counter; never timed)

The allocator detector passed a small/large positive control for both engines.

| Count | qjs | zjs | z/q or z-q |
|---|---:|---:|---:|
| malloc+calloc+realloc calls | 511,455 | 536,561 | 1.04909; +25,106 |
| requested bytes | 1,851,537,811 | 1,929,085,759 | 1.04188; +77,547,948 |
| malloc calls | 505,132 | 530,825 | 1.05086 |
| realloc calls | 6,323 | 5,736 | 0.90716 |

All allocator counts are exact and identical across the eight samples.

## Multi-build stability

Two independently cold zjs builds and two independently cold qjs builds were
crossed in all four combinations, each with eight ABBA samples. Debug-path/build
metadata changes the full binary hashes, while each engine's two cold builds
have identical `.text`. Across the four cold combinations the cycle ratio is
1.20163–1.20484 and the delta is 221,271,795–225,247,413 cycles. The frozen
production pair gives 219,314,558 cycles. The deficit is therefore stable
across samples and cold builds, with a small build-state shift, not a one-build
outlier.

An initial artifact was rejected after an incorrect `objcopy --dump-section`
invocation rewrote a temporary binary. The runner's binary-hash check exposed
the mismatch. That artifact is named `PDFJS-DIAG-DISCARDED-*`; every number in
this report comes from the restored pristine binaries or explicitly named
counter builds.

## P0 decision

- **Confirmed:** the score is about 0.779; execution is about 1.329x slower;
  total opcode work is about 0.997326x; the production fixed-work cycle deficit
  is currently **219.3M**, stable to samples/builds.
- **Not independently confirmed:** `137M` and `60%` are not raw facts. They are
  the remainder after subtracting an older modeled attribution from an older
  roughly 230M total. Reusing that model would violate this track's contract.
  P1 must first assign the current 219.3M deficit to semantic regions; only then
  can a current unexplained remainder be stated.
- **Early exclusions, not causes:** backend-memory stall adds only about 1.0M
  cycles, allocator frequency adds only 4–5%, JS/native entry counts are
  slightly lower in zjs, and zjs retires 14.7M fewer returns. None can by count
  alone explain a 219.3M deficit. The large raw correlates are +350.2M
  instructions, +174.3M branches, +50.5M frontend stalls, and +76.4M backend
  stalls; causation remains open.

## Raw evidence

- `PDFJS-DIAG-p0-frozen-ab8.json`
- `PDFJS-DIAG-p0-cold-{za,zb}-{qa,qb}-ab8.json`
- `PDFJS-DIAG-p0-phases-ab8.json`
- `PDFJS-DIAG-p0-alloc-ab8.json`
- `PDFJS-DIAG-p0-{zjs-native,qjs}-profile-ab8.json`
- `PDFJS-DIAG-p0-branch-pmu-ab8.json`
- counter patches and positive-control artifacts sharing the `PDFJS-DIAG-` prefix
