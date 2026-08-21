# Code Volume

Status of the code-volume line of the 2026-08-20 three-axis turn
(maintainability / binary size / code volume). Binary size closed at
4.26 MB by owner ruling; this file covers volume.

Its purpose is as much to record **what was ruled unrecoverable and why** as to
list what is left. Three of the categories below look like obvious duplication
and are load-bearing; re-deriving that costs a day each time.

## Current composition

Measured 2026-08-21 at `09446d6a`.

| | lines |
|---|---|
| Production (`src/`, excluding `src/tests/`) | 214,804 |
| — of which inline `test` blocks | 18,724 |
| — of which comments | 21,885 (10.2%) |
| — of which blank | 17,440 (8.1%) |
| `src/tests/` | 61,467 |

By area: `exec/` 96,776 · `core/` 38,993 · `parser.zig` 20,500 ·
`compiler/` 18,836 · `libs/` 12,918 · `bytecode.zig` 10,539 ·
`cli/` 5,243 · `runtime/` 4,165 · `binding/` 4,011.

## Ceiling

QuickJS's comparable surface — `quickjs.c` + `libregexp.c` + `libunicode.c` +
`cutils.c` — is 67,637 lines of C. The zjs equivalent (`parser.zig` +
`bytecode.zig` + `core/` + `exec/`) is 166,808, about **2.7×**.

That ratio is not slack. The dominant term is `exec/`'s per-opcode
specialisation, which is a measured performance position: a lean monolithic
dispatch was built and rejected (91 arms green, PMU 4/4 regression), and
per-op clusters remain the frontier. `compiler/`'s 18,836 lines have no
QuickJS counterpart at all. Zig also spends lines on explicit error sets and
`defer` where C spends none.

Treat the ratio as a description of the architecture, not as a backlog.

## Done

- **2026-08-20**: `rootValues` collapse of `ValueRootFrame` boilerplate (134
  sites, −663), byte-identical cross-file duplicate merge, `call_runtime.zig`
  7,510 → 5,542 via five domain moves (backlog H1), one owner for
  `appendRawString` (−99).
- **2026-08-21**: 364 unreferenced declarations deleted in two sweeps
  (−4,916 total), one owner for the engine error surface, parser snapshot
  collapse. See `CHANGELOG.md`.

## Exhausted: mechanical sweeps

`tools/maintainability/dead_decls.py` returns **0 declarations / 0 lines**.
Two predicate corrections got it there and both are load-bearing if the
scanner is ever re-run:

1. **Deletion cascades** — a declaration whose only reference was itself
   deleted becomes dead in turn. Run to a fixed point, not once.
2. **A non-`pub` top-level declaration is only visible in its own file.**
   Counting tree-wide hits lets a same-named declaration elsewhere keep a dead
   private one alive. `call.zig`'s private `promiseCombinatorCall` — 143 lines,
   a second implementation of the Promise combinators, zero callers — hid
   behind the live `promise_ops` function of the same name for a full sweep.

The scanner cannot see comptime-assembled names. `libs/unicode/data.zig` is
excluded by hand: its 53 property tables are reached through
`@field(@This(), "unicode_prop_" ++ field.name ++ "_table")`.

Byte-identical same-name functions are down to 16 groups / 137 lines, nearly
all 3-line local aliases (`readInt` ×8, `stringFromValue` ×4). Merging those
would trade a line for a cross-file dependency; not worth it.

## Remaining queue

About 500–700 lines, all requiring judgement rather than a script. Unit price
has dropped from thousands of lines per day to tens of lines per decision.

| Item | Size | Gate / obstacle |
|---|---|---|
| `bigIntParts` / `compareBigIntValues` / `valuesEqual` in three copies (`array_builtin_ops`, `value_ops`, `core.value`) | ~60 → save ~40 | Sink to core. Direct; no known divergence |
| Class static block's 14-field parser snapshot | ~30 | Strict superset of the 10-field `FieldInitContext` already collapsed; folding it in changes behaviour at the three field sites |
| `appendValueString`, 8 copies in 6 shapes | ~50 | Number formatting has diverged (`std.fmt "{d}"` vs ES `dtoa`); latent, needs per-site rulings |
| `unicode.zig` vs `unicode/regexp_properties.zig`: the same table format decoded twice (`unicodeGeneralCategory1`, `unicodeProp1`, `unicodeCase1`, `unicodePropOps`) | 335 → save ~150 | One yields a RangeSet, the other does point lookup. Needs a shared traversal iterator and touches the RegExp hot path — bench-v8 A/B |
| `parseArrowFunction` inlines a copy of `parseFunctionParameters` | ~150 | See ruling below — code volume only |

## Ruled unrecoverable

- **Frame-construction boilerplate** in `inline_calls.zig`,
  `tailcall_dispatch.zig` and `call_runtime.zig` (~1,200 lines of repeated
  12-line windows: `entry.stack` / `entry.teardown` / `entry.prev`). "Hot arms
  are never shared" is standing policy; three separate attempts to merge a
  call layer fattened the frame each time. Do not re-open without a frame
  disassembly.
- **`compiler/tests.zig` self-repetition** (~1,008 lines). These are expected
  bytecode-stream assertions. Being spelled out is the point of them.
- **`parseArrowFunction`'s parameter parsing copy** is *not* a divergence.
  The two sites save overlapping-but-unequal parser state, which is the shape
  that has produced three real bugs on this project, so it was differentially
  tested: 20 edge cases (duplicate parameter names, `arguments` in a default,
  non-final rest, `yield`/`await` in a parameter, `'use strict'` under a
  non-simple parameter list, `eval`/`arguments` as strict parameter names)
  agree with QuickJS in every case. It remains a volume target, not a bug.

## Discipline (learned the expensive way)

- **A deletion-only change cannot be judged by an A/B ratio alone.** The
  2026-08-21 sweep read 0.9956 on bench-v8, stable across two independent runs
  — and the pad lineage ruled it LAYOUT: instructions moved ±0.04% while cycles
  flipped sign across pads. Deleting dead code inside the op-handler island
  shrank it by 5,376 bytes and re-arranged what was left. Near-zero instruction
  delta plus a moving cycle delta is placement, not mechanism. Always pair a
  deletion A/B with `tools/perf/layout_lineage/run_lineage.py`.
- **The gates are blind to protocol observability.** Two collection-iteration
  defects have now shipped green under test262 0/49778. A change that narrows
  or widens a fast-path guard needs a differential run against QuickJS, not
  just the suite.
- **After narrowing a fast-path guard, prove the fast path still triggers.**
  A `@panic` probe is the cheapest proof. Write it as
  `if (len > 0) @panic(...)` — a bare `@panic` makes the following statements
  unreachable and fails the build instead.

## Not code volume, noted here because the audit surfaced it

zjs reports every parse failure as `SyntaxError: UnexpectedToken`. QuickJS
gives `duplicate argument names not allowed in this context`,
`"use strict" not allowed in function with default parameter`, and so on.
Message text is not normative, so no test covers it, but it is a real
diagnostic-quality gap.
