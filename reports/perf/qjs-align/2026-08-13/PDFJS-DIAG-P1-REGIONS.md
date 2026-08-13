# PDFJS-DIAG P1 — semantic region attribution

This report attributes the current P0 deficit; it does not reuse the old 137M
remainder or any old per-helper cost model.

## Sampling contract

- Frozen production binaries and fixed-work source are exactly those in
  `PDFJS-DIAG-P0-FACTS.md`.
- CPU 19, parallelism 1, no `flock`, exact affinity.
- Eight samples per engine in ABBA order for each of two independent fixed
  prime periods: 65,521 and 65,519 cycles.
- Flat self samples, user cycles on `armv8_pmuv3_1`; zero lost samples; every
  sample assigned to exactly one region.
- Sampled total gaps are 217.69M and 217.98M cycles, within 0.7% of the P0
  counter result (219.31M).

For qjs, every `JS_CallInternal` instruction address is resolved through the
full DWARF inline chain. Lines 17746–17872 and 20662–20704 are call
entry/return; lines 20705–20710 are teardown; all `SWITCH`/`CASE`/`BREAK` and
shared-tail code is one handler bucket. In particular, no short source window
is assigned to one opcode: the dispatch emitted at each `BREAK` and the shared
`set_true`/`free_and_set_false` tails cannot create the warned-about false
7.12x attribution.

## Stable net attribution

| Region | gap at period 65,521 | gap at period 65,519 | sign stability |
|---|---:|---:|---:|
| dispatch / hot opcode handlers | **+152.79M** | **+147.88M** | 8/8 positive in both |
| string / regexp | **+69.29M** | **+70.37M** | 8/8 positive in both |
| call entry / return | **+61.07M** | **+62.57M** | 8/8 positive in both |
| property / array helpers | +9.86M | +12.02M | 8/8 positive in both |
| native / libc | +2.10M | +1.41M | 7/8 positive in both |
| other | +3.01M | +3.77M | 8/8 positive in both |
| arithmetic / conversion | -31.68M | -31.38M | 0/8 positive in both |
| allocation | -18.77M | -18.25M | 0/8 positive in both |
| frontend / compile | -17.04M | -16.87M | 0/8 positive in both |
| RC / teardown | -14.58M | -15.07M | 0/8 positive in both |

Positive regions sum above the net deficit because qjs spends substantially
more cycles in the four negative regions. The named regions account for
97.6–97.9% of the net gap; `other` is only 3.0–3.8M (1.4–1.7%). Thus P1's 80%
region-attribution condition is satisfied with stable signs at two adjacent
prime periods.

At period 65,521, the absolute median sampled cycles are:

| Region | qjs | zjs | z/q |
|---|---:|---:|---:|
| dispatch / handlers | 394.70M | 547.33M | 1.387 |
| string / regexp | 71.65M | 139.99M | 1.973 |
| call entry / return | 67.29M | 126.55M | 1.916 |
| property / array helpers | 112.66M | 121.44M | 1.088 |
| allocation | 147.72M | 130.49M | 0.875 |
| arithmetic / conversion | 46.16M | 14.84M | 0.320 |
| frontend / compile | 100.31M | 83.31M | 0.830 |
| RC / teardown | 43.51M | 28.86M | 0.669 |

## What P1 establishes and does not establish

- The old premise that opcode count should explain the deficit is false at the
  right level: opcode count is 0.997326x, while the same coarse handler region
  is 1.37–1.39x and carries 148–153M extra cycles.
- The largest remaining work is therefore inside handler execution, not in
  allocation, RC teardown, frontend, or memory stalls. Call and string regions
  are also individually large, but they overlap neither with the flat handler
  samples nor with one another.
- Region samples are attribution, not a causal mechanism. In particular,
  `nativeMethodFastDispatch` being hot does not prove that a native-call fence,
  frame setup, or any single line causes its region's gap.
- P2 must enter the handler bucket first and distinguish edge mix, value-shape
  arms, publication/cold transitions, helper entries, and ownership work. Call
  and string regions remain secondary hypotheses if the handler bucket
  decomposes into those helpers.

## Evidence

- `PDFJS-DIAG-p1-samples-ab8.json` and `PDFJS-DIAG-p1-regions-v2.json`
- `PDFJS-DIAG-p1-samples-p65519-ab8.json` and
  `PDFJS-DIAG-p1-regions-p65519-v2.json`
- `PDFJS-DIAG-p1-sample.py` and `PDFJS-DIAG-p1-regions.py`
- Raw `perf.data` paths and SHA-256 values are recorded per run in the sample
  JSON; all raw data remains under the named `/tmp/pdfjs-diagnosis-20260813/`
  directories for audit during this track.
