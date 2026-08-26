# Backlog

The single priced work queue. Merged 2026-08-25 from the former
`impl-quality-backlog.md`, `maintainability-backlog.md`, `code-volume.md`,
and `perf/shared-vm-decomposition.md`; the closed records of all four live in
their git history (see "Closed record" below). Gate selection follows
[refactor-policy.md](refactor-policy.md)'s 2026-08-22 tiers; **AB** =
bench-v8 A/B against a frozen merge-base build, **suite** = test262 +
unified suite, **identity** = `.text` byte-compare. Try the identity gate
first: most queue items are moves and renames, and a machine-code-identical
result is both cheaper and stronger than a statistical one. Historical A/B
ratios cited in closed records were measured on the retired V8-v7 8-suite
composite and are not comparable to Octane 2.0 readings.

Evidence line references drift; function names are the anchor. Treat line
cites as historical unless marked re-verified.

## Hot-zone refactor queue

Hot-path maintainability items deferred from the 2026-08-18 campaign. Each
lands only item by item under [refactor-policy.md](refactor-policy.md)
rule 2 (or the cheaper identity gates of rule 4 where noted).

| # | Item | Evidence | Notes / gate |
|---|---|---|---|
| H7 | Bring the orphan section `.text.zjs.nmfd_term` under explicit linker-script management | `vm_call.zig` emits it (at 722-739, re-verified 2026-08-25); `tail_hot_layout_aarch64.ld` never mentions it, so its placement relies on orphan-section defaults | Linker change: always bench-v8 A/B |
| H9 | Narrow the public `JSValue` surface (89 leaked internal pub decls, e.g. `freeObjectAssumeObjectDuringActiveBytecode`) via an opaque public value type. **2026-08-20: 88 → 89** (`catchTarget`); the pin caught it only on the production gate, so `checkpoint-gate` now depends on the snapshot test too | Public-api audit A3; `public-api-contract.md` promises the opposite | Design jointly with the fun port |
| H10 | Separate name from role in `src/parser.zig` (hosts `compile_entry` + ~326 `v2` substring occurrences — re-counted 2026-08-25 after the QCP-1 legacy deletion and H13 renames) and `src/bytecode.zig` (hosts `pipeline_*` namespaces) | Architecture doc admits the mismatch | Large project |
| H11 | Re-evaluate the four remaining `core/root.zig` implementation-module absences (`bulk_memory`, `bytes_view`, `module_auto_init`, `string_view`) | The `jobs.zig` owner seam was fixed 2026-08-20: callers now use `core.jobs` and the inverted `exec.jobs` re-export is gone | The jobs slice reproduced the same two-image stripped whole-image set on both sources; apply the deletion test before widening the core Interface for the four internal modules |

## Implementation quality — open items

From the 2026-08-21 implementation-quality review. As of 2026-08-25 only
these three threads remain open; everything else (Q1–Q10, Q14–Q20, G1–G6)
is closed.

### Q11 T3/T4 — `object.zig` split, remaining tranches

T1 and T2 are done (2026-08-22): `object.zig` 13,251 → 11,163 with
`object_payloads.zig` and `object_gc.zig` split out; A/B in envelope both
times. Remaining:

- **T3 (optional)**: the six class-family method sections (~3,760 lines),
  aliased back (`pub const foo = impl.foo;` keeps call sites unchanged).
  Residue after T1–T3 is ~7,200 cohesive lines. Note from T1:
  `destroyDetachedClassPayload` stays in `object.zig` — it bridges Object
  cursor teardown and both extracted modules.
- **T4 (recommended-against)**: create/destroy/define/set property engines —
  hottest code, two hot pins. **Recommended stop point: do not do T4.**
- Forbidden: converting `ObjectStorage` to a tagged union or reordering
  `Object` fields — that is a representation experiment, barred by
  [vm-value-representation-contract.md](vm-value-representation-contract.md)
  (JSValue layout and non-moving object identity are contractual). The
  original qjs-parity justification retired with charter clauses R1–R3
  ([qjs_alignment_charter_transition.md](qjs_alignment_charter_transition.md));
  the representation contract is the standing authority.
- Gate: every tranche **AB** + pad lineage (`--pads 0 3 7`); data layout is
  comptime-pinned but `.text` placement is not, and pure-placement swings of
  ±0.4–2.7% are on record. The hot mark arms' `align(16)` pins are
  function-entry pins and travel with the functions.

### Q12 — parked `BuiltinCallEnv` pilot

The five-tuple investigation (2026-08-22) ruled: **keep the explicit
threading** (memo: `.scratch/q12-five-tuple-memo-2026-08-21.md`,
gitignored; this entry is the durable record). The hot position is measured
(removing a 9-field env round trip once won −1.31% fixed-work cycles),
`output` is API policy inside that ABI, `global` is cross-realm correctness
authority, and the QuickJS current-stack-frame alternative is exactly the
rejected per-call publication pattern.

Standing discipline: no output-on-context, no global derivation, no runtime
current-frame collapse without a new requirement.

The one parked increment: a gated `*const BuiltinCallEnv` pilot in the
disposable/reflect cold domains (~409 cold sites upper bound), two-track —
cold builtins take the bundled env struct, the hot call chain keeps explicit
args. Sequenced after Q11/Q13; every step **AB**-gated.

### Q13 — parser file split (unblocked, not yet scheduled)

Natural seams exist (`token` and `compile_entry` are namespace-clean;
~4,300 lines liftable verbatim). The original sequencing blocker is gone
(corrected 2026-08-25): the QCP-1 legacy deletion NO-GO was amended to
ACCEPT on 2026-08-06 and executed
([qcp1_switch_decision.md](qcp1_switch_decision.md) §8/§9.1,
[compiler-contract.md](compiler-contract.md), `build.zig` "`-Dzjs_compiler`
retired"), so there is no preserved legacy residue left to scatter and no
pending verdict to wait on.

Precursors done 2026-08-22: statement-kind bodies extracted to named
functions (emission byte-identical); the lexer lifted verbatim to
`src/lexer.zig` (parser.zig 20,769 → 17,408). Remaining work is the
`parser_core` split itself, under emission-identity.

## `call_runtime.zig` candidate domains

The `src/exec/call_runtime.zig` decomposition map was executed through
2026-08 (five domain moves, the forwarding-shell deletion H5, and the
`71505d11` code-size pass brought it 7,510 → 5,359 lines); the current
shard inventory is in [architecture.md](architecture.md). These domains
remain reasonable candidates for future splits when touched:

- global object and global lexical environment operations.
- closure and var-ref operations.
- builtin wrapper glue that does not belong in an existing `builtins/`
  module (Reflect/Iterator-helper native records and similar `qjs*` call
  glue).

Move criteria (standing rules):

- The target file has one coherent domain.
- Imports do not introduce cycles back through `call_runtime.zig`.
- Moved helpers retain the same ownership, rooting, and exception behavior.
- Callers reference the owning module directly; do not add new forwarding
  aliases in `call_runtime.zig`.
- Prefer leaf helper groups first. Avoid moving an orchestration function if
  its callees would still force broad imports from `call_runtime.zig`. Do
  not create a new shard for a single unrelated helper; leave nearby code in
  place until there is a stable domain boundary.

Minimum validation for a small move: `zig build zjs --summary all` +
`git diff --check`. For multi-domain moves or any observable behavior risk:
`zig build test --summary all` + `zig build smoke --summary all`, plus a
relevant test262 slice when the moved code handles visible JavaScript
semantics.

## Code volume

Status of the code-volume line of the 2026-08-20 three-axis turn
(maintainability / binary size / code volume). Binary size closed at
4.26 MB by owner ruling (figure as of `47cf81ef`, 2026-08-21; not
re-measured after the 2026-08-24 interpreter/runtime code-size reduction
`71505d11`). This section records **what was ruled unrecoverable and why**
as much as what is left; three of the categories below look like obvious
duplication and are load-bearing.

### Current composition

Measured 2026-08-25 (the tree of the 2026-08-25 consolidation commit).

| | lines |
|---|---|
| Production (`src/`, excluding `src/tests/`) | 216,774 |
| — of which inline `test` blocks | 18,734 |
| — of which comments | 22,780 (10.5%) |
| — of which blank | 17,604 (8.1%) |
| `src/tests/` | 62,187 |

By area: `exec/` 97,513 · `core/` 39,589 · `parser.zig` 17,566 ·
`compiler/` 18,847 · `libs/` 12,859 · `bytecode.zig` 10,539 ·
`cli/` 5,406 · `runtime/` 4,178 · `binding/` 4,076 · `lexer.zig` 3,364
(lifted verbatim out of `parser.zig` by the Q13 precursor, `b82b0155`).

QuickJS's comparable surface — `quickjs.c` + `libregexp.c` + `libunicode.c`
+ `cutils.c` — is 67,637 lines of C; the zjs equivalent (`parser.zig` +
`lexer.zig` + `bytecode.zig` + `core/` + `exec/`) is 168,571, about
**2.5×**. That ratio is not slack: the dominant term is `exec/`'s per-opcode
specialisation, a measured performance position (a lean monolithic dispatch
was built and rejected — 91 arms green, PMU 4/4 regression), and
`compiler/` has no QuickJS counterpart at all. Treat the ratio as a
description of the architecture, not as a backlog.

### Mechanical sweeps: exhausted

`tools/maintainability/dead_decls.py` returns **0 declarations / 0 lines**
(re-verified 2026-08-25). Two predicate corrections got it
there and both are load-bearing if the scanner is ever re-run:

1. **Deletion cascades** — a declaration whose only reference was itself
   deleted becomes dead in turn. Run to a fixed point, not once.
2. **A non-`pub` top-level declaration is only visible in its own file.**
   Counting tree-wide hits lets a same-named declaration elsewhere keep a
   dead private one alive.

The scanner cannot see comptime-assembled names (`libs/unicode/data.zig` is
excluded by hand). Manual grep finds two residues outside its predicate —
`pub const ReflectConstructResolution` (`src/exec/reflect_ops.zig:580`,
zero references tree-wide) and the unused private import alias `module_mod`
in `src/core/object.zig:18`; both are scanner blind spots, noted rather
than deleted. Byte-identical same-name functions are down to 16 groups /
137 lines, nearly all 3-line local aliases; merging those would trade a
line for a cross-file dependency — not worth it.

### Remaining reduction queue

About 500–700 lines, all requiring judgement rather than a script.

| Item | Size | Gate / obstacle |
|---|---|---|
| `bigIntParts` / `compareBigIntValues` / `valuesEqual` in three copies (`array_builtin_ops`, `value_ops`, `core.value`) | ~60 → save ~40 | Sink to core. Direct; no known divergence |
| `appendValueString`, 8 copies in 6 shapes | ~50 | Number formatting has diverged (`std.fmt "{d}"` vs ES `dtoa`); latent, needs per-site rulings |
| `unicode.zig` vs `unicode/regexp_properties.zig`: the same table format decoded twice (`unicodeGeneralCategory1`, `unicodeProp1`, `unicodeCase1`, `unicodePropOps`) | 335 → save ~150 | One yields a RangeSet, the other does point lookup. Needs a shared traversal iterator and touches the RegExp hot path — bench-v8 A/B |
| `parseArrowFunction` inlines a copy of `parseFunctionParameters` | ~150 | See "Ruled unrecoverable" — code volume only |

### Ruled unrecoverable

- **Frame-construction boilerplate** in `inline_calls.zig`,
  `tailcall_dispatch.zig` and `call_runtime.zig` (~1,200 lines of repeated
  12-line windows: `entry.stack` / `entry.teardown` / `entry.prev`). "Hot
  arms are never shared" is standing policy; three separate attempts to
  merge a call layer fattened the frame each time. Do not re-open without a
  frame disassembly.
- **`compiler/tests.zig` self-repetition** (~1,008 lines). These are
  expected bytecode-stream assertions. Being spelled out is the point of
  them.
- **`parseArrowFunction`'s parameter parsing copy** is *not* a divergence.
  The two sites save overlapping-but-unequal parser state, which is the
  shape that has produced three real bugs on this project, so it was
  differentially tested: 20 edge cases agree with QuickJS in every case. It
  remains a volume target, not a bug.

## Discipline (learned the expensive way; applies to every item)

- **A deletion-only change cannot be judged by an A/B ratio alone.** The
  2026-08-21 sweep read 0.9956 on bench-v8, stable across two independent
  runs — and the pad lineage ruled it LAYOUT: instructions moved ±0.04%
  while cycles flipped sign across pads. Near-zero instruction delta plus a
  moving cycle delta is placement, not mechanism. Always pair a deletion
  A/B with `tools/perf/layout_lineage/run_lineage.py`.
- **The gates are blind to protocol observability.** Two
  collection-iteration defects have shipped green under test262 0/49778. A
  change that narrows or widens a fast-path guard needs a differential run
  against QuickJS, not just the suite.
- **After narrowing a fast-path guard, prove the fast path still fires.**
  A `@panic` probe is the cheapest proof. Write it as
  `if (len > 0) @panic(...)` — a bare `@panic` makes the following
  statements unreachable and fails the build instead.
- **Hot-arm bodies are never shared with cold paths**; merging call layers
  has fattened frames three times.

## Closed record

Q1–Q10, Q14–Q20 and G1–G6 (closed 2026-08-21→23 with gate evidence),
H1–H6, H8, H12–H14 and the H13 pricing debt, the executed
`call_runtime.zig` decomposition map, and the code-volume campaign records
(including the 2026-08-20/21 "Done" sweeps and the closed
diagnostic-quality note) were removed from the active tree on 2026-08-25.
Recover them from the git history of the four predecessor files —
`docs/impl-quality-backlog.md`, `docs/maintainability-backlog.md`,
`docs/code-volume.md`, `docs/perf/shared-vm-decomposition.md` — at
`14b0618d` and earlier (all four files' committed history is fully
reachable there).
