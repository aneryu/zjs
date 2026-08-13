# PDFJS-DIAG P2 — edge, shape, and lifecycle decomposition

P2 instruments frequency only. No number in this report is used as a unit
cost, and none of the counter binaries is compared by PMU or wall time.

## Provenance and counter contract

- zjs source: `0710394f58ea123a3d8ff54b389aadb45065c6dc`
- QuickJS source: `04be246001599f5995fa2f2d8c91a0f198d3f34c`
- Zig: `0.16.0`; qjs counter build: repository `gcc -O2` build
- CPU 19, parallelism 1, no `flock`, eight ABBA samples per engine
- zjs counter binary:
  `0b4292e379ca22bc575951f62a426e501c0c7a4ad0b3c138fdf74b5e877e021c`
- qjs counter binary:
  `42c1a94b8e1919e68bed5a2fc007467b26eecb8427c0e1be0510f9197630d22a`
- instrumentation: frame-local opcode predecessor and edge matrix; selected
  hot-op value tags and flat-Latin1/wide/rope backing; `get_field` and `add`
  arms; zjs cold-table entry, `publish`, and `coldNext`; dup/free/drop-to-zero;
  frame enter/return, stack growth/alloca, native fence; selected qjs helper
  entries.

The qjs dump point is after the job loop and before runtime teardown, matching
the zjs benchmark lifetime. The edge predecessor is frame-local and reset on
entry, so it cannot invent cross-frame return-to-caller edges. Positive
controls made a recursive edge, integer-add arm, dup/free, and drop-to-zero
counter fire before their absence was used as evidence.

The qjs profile is exact across all eight runs. The zjs score-dependent tail
varies by at most 80 opcodes and three frames; ranges below expose that
variation instead of selecting one favorable run.

## Opcode and edge mix

| Fact | qjs | zjs | interpretation |
|---|---:|---:|---|
| opcodes | 97,457,771 | 97,197,229–97,197,309 | z/q 0.997327 |
| within-frame edges | 96,822,846 | 96,563,604 representative | same fixed work |
| opcode-distribution TV | — | 1.1014% | small compiler/layout mix difference |
| edge-distribution TV | — | 2.1905% | edge mix differs more than opcode mix |

The largest edge delta is not extra semantic work. `strict_eq -> if_false8`
is +719,198 while `strict_eq -> if_true8` is -716,192; the following `dup`
edges flip in the same way. Both engines execute exactly 1,575,297
`strict_eq` operations. This is the V2 compiler's inverted conditional
encoding, not 719k additional comparisons. Tail-call/drop layout differences
explain most of the next-largest edges. Edge mix therefore describes the
different dependency/dispatch shape, but does not by itself name a cost.

## Value shape and hot arms

At the ordinary JS tag level, the selected hot-op operand distributions are
almost identical: weighted mismatch is 0.0198%. `add` is especially strong:

| `add` arm | qjs | zjs |
|---|---:|---:|
| integer | 1,261,197 | 1,261,125 |
| numeric non-integer | 131,875 | 131,951 |
| string | 1,014,638 | 1,014,638 |
| other slow | 132 | 132 |

The backing representation underneath the identical `string` tag is not the
same. Across all selected hot operands, both engines observe exactly 7,740,081
strings:

| backing | qjs | zjs | z-q |
|---|---:|---:|---:|
| flat Latin-1 | 6,279,637 | 5,189,327 | -1,090,310 |
| wide | 211,276 | 211,276 | 0 |
| rope | 1,249,168 | 2,339,478 | **+1,090,310** |

The concentration is `strict_eq`'s second operand: qjs has 0 ropes there;
zjs has 1,056,542, replacing the same number of flat Latin-1 observations.
This is a value-shape candidate hidden by the ordinary tag histogram and is
carried to P3. It does not yet imply that flattening every rope is beneficial:
unequal-length strings have a cheap length early-out.

## Lifecycle, publication, and helper frequencies

| Count | qjs | zjs | result |
|---|---:|---:|---|
| frame entries | 634,925 | 633,702–633,705 | zjs slightly fewer |
| frame returns | 634,925 | 633,702–633,705 | balanced |
| native fences | 5,735 | 5,310 | zjs fewer |
| dup | 23,633,494 | 23,573,414–23,573,453 | zjs fewer |
| free | 26,400,907 | 23,929,722–23,929,763 | zjs fewer |
| drop-to-zero | 2,848,008 | 1,747,210–1,747,211 | zjs much fewer |
| stack grows | n/a | 0 | no macro path entry |
| zjs `publish` | n/a | 1,393,735–1,393,741 | frequency only |
| zjs `coldNext` | n/a | 3,451,826–3,451,835 | frequency only |

These counters reject the proposed model “the same opcodes cause more zjs
ownership transitions.” They do not claim that an individual zjs transition
has equal cost. The hottest zjs cold-table entries are `get_field2` 263,377,
`get_array_el` 182,546, `mul` 93,588, and `and` 92,074; all remaining entries
are below 40k. No stack growth occurs.

Selected qjs helper entries include 2,201,049 C-function calls, 1,062,100
string concatenations, 6,747,111 own-property searches, and 2,259,014 internal
property gets. These are frequency anchors, not cross-engine cost estimates;
qjs inlining and zjs tail handlers do not give a one-to-one symbol boundary.

## P2 decision

- “Same opcode count” is real, but insufficient: edge TV is 2.19%, largely
  compiler conditional/tail encoding rather than semantic work.
- Ordinary value-tag and `add`-arm mix is effectively the same. This excludes a
  broad int/float/string/object-arm explanation for the handler gap.
- A narrower shape difference is real: zjs carries 1.090M more ropes through
  the selected hot operands, concentrated in strict equality.
- More RC/ownership transitions, stack growth, frame entry, or native fences
  cannot be the global model: every corresponding zjs count is equal or lower.
- P3 must test the rope/equality prediction and independently dissect the hot
  native-call wrapper. Layout, property-tail dispatch, and `coldNext` are kept
  as explicit exclusion/sizing interventions rather than inferred from samples.

## Evidence

- `PDFJS-DIAG-p2-counters-ab8-v3.json` (final backing-aware counter set)
- `PDFJS-DIAG-p2-counters-ab8-v2.json` and `PDFJS-DIAG-p2-analysis.json`
- `PDFJS-DIAG-p2-counters.py` and `PDFJS-DIAG-p2-analyze.py`

