# QCP-1 architecture scorecard — post-P3 recount (C1 / C3 / C4, STOP-D, STOP-E)

Branch `compiler-v2-qjs`, tip `23f7ed14` (P3 stage 2). Measurement and
documentation only: nothing outside this file changed.

This document recounts the four architecture-health metrics after P3 (the
`Emitter` / `LegacyEmitter` / `V2Emitter` vocabulary, `ebedfd92` + `23f7ed14`)
and states plainly where each one stands.

## Summary

| metric | prior | now | direction |
| --- | --- | --- | --- |
| **STOP-E** migration-only / v2 production | 61% full, 43% conservative | **45.5% full, 42.4% conservative** | inside the ~30–50% band — **but see §5.3** |
| **C1** v2 production / deletable legacy | 1.11x (1.77x with migration code) | **1.56x (2.27x)** | **worse** |
| **C1** runtime concepts (legacy → v2) | not previously stated | **46 → 40 types, 40 → 34 carriers, 130 → 190 mutable fields** | fewer types, more state |
| **C1** public invariants (legacy → v2) | not previously stated | **29 → 42**, mechanically enforced **13 → 27**, unenforced **11 → 2** | more invariants, far better enforced |
| **C3** comparator special cases | 28 (20 folds + 8 model) | **31 families (18 folds + 13 model) + 3 tolerances**; ruler differs, see §2 | unchanged by P3 (0 added) |
| **C4** semantic inventory | 41 removed / 36 added, net −5 | **37 removed / 33 added, net −4** pipeline-only; **−3** with the branch's ownership term; **+1** projected after main merges | see §3 |
| **STOP-D** identity kinds | v2 = 1, legacy ≥ 12 | **unchanged, not triggered** | — |

**The headline needs its caveat attached.** STOP-E lands inside the band on the
ruler that produced the original 61%. That pass is fragile and is not "P3 fixed
STOP-E": the *absolute* migration-only line count fell only 4.6% versus the S6
tip (4,364 → 4,165), and about 86% of the ratio improvement comes from the
**denominator growing 29%**, most of it Debug/ReleaseSafe-only identity oracle
added between S6 and P3 for reasons unrelated to P3. On a denominator that
excludes that oracle the ratio is **68.8%** and STOP-E is still triggered. §5.3
gives both and does not pick a favourite.

---

## 0. The ruler, and the proof that it is the right ruler

Every LOC figure below counts **code lines** — non-blank lines that are not
comment-only — under one mechanical census with these rules.

**Migration-only** (exists only because two backends coexist):

| bucket | rule |
| --- | --- |
| `compiler_v2/compare.zig` | whole file, split at the first top-level `test "` into comparator core and comparator self-tests |
| `compiler_v2/cfg.zig` audit oracle | `AuditInstruction` + `enqueueAuditOffset` + `auditInstructionOwnership` |
| `compiler_v2/tests.zig` translator | the 16 named phase1→v2 translation / legacy-equivalence helpers |
| `compiler_v2/coverage.zig` | whole pre-test file (L3 emission gate) |
| `compiler_v2/test_entry.zig` | whole pre-test file (backend-selecting test entry) |
| `compiler_v2/root.zig` ledger | the comparator-ledger plumbing block |
| `parser.zig` dual dispatch | the `compile()` dual-backend block |
| `parser.zig` gate-arm scaffolding | the `if (v2_available and …) {` / `} else {` / `}` lines of every gate, and nothing inside either arm |
| `parser.zig` P3 dispatch | the `Emitter` namespace + the `LegacyEmitter` leg |
| `parser.zig` L3 hooks, `v2_ledger` sites | the coverage push/pop/note helpers and the ledger references |

**V2 production**: pre-test code in `compiler_v2/{labels,root,cfg,builder,
resolve_variables,resolve_labels}.zig` minus the two buckets above that live in
those files, plus in `parser.zig` the `v2F*` facade helpers, the v2 arm bodies
still inside surviving gates, and the `V2Emitter` leg.

**Deletable legacy**: `bytecode.zig` `pipeline_resolve_variables` minus the
curated `pipeline_resolve_variables.v2` reuse surface, plus
`pipeline_resolve_labels`, plus the `parser.zig` legacy emission / parser-label
/ fixup machinery, plus the legacy `else`-arm bodies under gates.

**Conservative variant**: the full migration figure minus the mechanical gate
scaffolding, the fail-closed legacy-emitter asserts, the L3 hooks and the
`v2_ledger` sites — the lines whose only content is "which backend am I".

### Calibration

The ruler was applied unchanged to the S6 tip `642e7b8d`, the tree on which
STOP-E was originally declared. It reproduces the published figures:

| S6 figure | published | this ruler at `642e7b8d` | error |
| --- | ---: | ---: | ---: |
| migration-only LOC | 4,345 | 4,364 | +0.4% |
| v2 production LOC | 7,102 | 7,083 | −0.3% |
| STOP-E full | 61% | 61.6% | — |
| STOP-E conservative | 43% | 43.6% | — |
| deletable legacy LOC | 6,393 | 6,368 | −0.4% |
| C1 | 1.11x | 1.11x | exact |
| C1 counting migration code | 1.77x | 1.80x | +1.7% |
| parser dual-arm scaffolding | 1,265 | 1,265 | exact |
| `compare.zig` core | 1,767 | 1,767 | exact |

So the deltas below are measured with one ruler that independently lands on the
numbers the stop condition was written against.

### Three points, one ruler

`d35c66ea` is the pre-P3 tree. It is included because without it P3's
contribution cannot be separated from the S3R+ oracle work, the L3 coverage
gate and the unified test entry that landed in the same window.

| | S6 `642e7b8d` | pre-P3 `d35c66ea` | post-P3 `23f7ed14` |
| --- | ---: | ---: | ---: |
| migration-only LOC | 4,364 | 4,986 | **4,165** |
| v2 production LOC | 7,083 | 9,624 | **9,156** |
| deletable legacy LOC | 6,368 | 6,391 | **5,868** |
| **STOP-E full** | 61.6% | 51.8% | **45.5%** |
| **STOP-E conservative** | 43.6% | 37.9% | **42.4%** |
| **C1** | 1.11x | 1.51x | **1.56x** |
| C1 counting migration code | 1.80x | 2.29x | **2.27x** |

P3's diff touches exactly one file: `src/parser.zig`, +1,213 / −2,380.

---

## 1. C1 — lines, and then the counts that actually matter

### 1.1 Lines

**v2 added production 9,156 LOC vs deletable legacy 5,868 LOC = 1.56x**
(2.27x if migration-only code is counted on the v2 side).

Prior: 1.11x / 1.77x. **C1 got worse**, and P3 is not the cause:

* the numerator grew **+2,073** between S6 and pre-P3 — `cfg.zig` production
  went 402 → 2,377 LOC (the S3R+ / S3R+U / S3R+R identity-oracle commits),
  `resolve_labels.zig` +387, `resolve_variables.zig` +146;
* P3 itself moved the numerator **down 468** (parser v2 arm bodies 1,192 → 644,
  offset by the 80-line `V2Emitter`);
* P3 moved the denominator **down 523** (legacy `else`-arm bodies 832 → 309),
  because the paired legacy statements collapsed into the 90-line
  `LegacyEmitter`, which this census books as migration-only rather than
  deletable legacy. Booking `LegacyEmitter` on the legacy side instead gives
  5,958 and C1 = 1.54x — the classification is worth 0.02x, not more.

**C1 is not a P3 metric.** Over the S6→post-P3 window it degraded because v2
grew ~2,000 lines of Debug/ReleaseSafe-only oracle. §5.3(b) shows the same
oracle dominating the STOP-E sensitivity.

### 1.2 Runtime CONCEPT count

Distinct named data types (`struct` / `enum` / `union`) the lowering pipeline
instantiates, excluding pure namespace containers, counted over `bytecode.zig`
`pipeline_resolve_variables` + `pipeline_resolve_labels` (legacy) and
`compiler_v2/{labels,builder,cfg,resolve_variables,resolve_labels,root}.zig`
(v2), pre-test regions only.

| | legacy | v2 | delta |
| --- | ---: | ---: | ---: |
| production types | 46 | 40 | **−6** |
| production state carriers (types with ≥1 field) | 40 | 34 | **−6** |
| production mutable fields | 130 | **190** | **+60** |
| Debug/ReleaseSafe-only oracle + test-harness types | 0 | 18 | +18 |
| …their carriers / fields | 0 / 0 | 15 / 102 | +15 / +102 |

Read plainly: **v2 has fewer types and fewer carriers but 46% more mutable
fields.** It concentrates state into a few fat pass objects
(`resolve_labels.Resolver` 29 fields, `resolve_variables.Resolver` 19,
`ResolvedProduct` 15, `Builder` 18) where legacy spread it across many small
structs.

That could have been an artifact — legacy might pass its state as parameters
instead of fields. It does not:

| | legacy | v2 |
| --- | ---: | ---: |
| functions in the pass region | 264 | 284 |
| total declared parameters | 722 | 765 |
| mean / max parameters per function | 2.73 / 11 | 2.69 / 10 |

The parameter load is the same on both sides, so the +60 fields is a real
increase in simultaneously-live named state, not a style difference. The
mitigation, such as it is, is that it is *reachable* state — one `Resolver` you
can print — rather than 40 structures whose live set a reader must reconstruct.

On top of the production numbers, v2 carries 18 Debug/ReleaseSafe-only types
(`OracleReport`, `FanoutCensus`, `AnchorSplitCensus`, `AnchorExemplar`,
`BoundaryReportAccounting`, `AuditInstruction`, `DiffBucket`,
`DivergenceOrigin`, `ReportIdentity`, `AnchorCoincidence`, `SourceSite`, … plus
three test harnesses) with **no legacy counterpart at all**. They are
comptime-erased in ReleaseFast — `cfg.zig:107` asserts `@sizeOf(OracleReport)
== 0` there — but a maintainer still has to hold them.

### 1.3 Compiler STATE count — the parser side

The parser-side state is where v2 is unambiguously ahead.

| | legacy | v2 |
| --- | --- | --- |
| break/continue control state | `break_fixups`, `break_frame_lens`, `continue_fixups`, `continue_frame_lens`, `label_break`, `label_cont`, `label_finally` — 7 concepts, 13 field declarations across `State` / `LabelFrame` / the saved-frame struct (`parser.zig:3734-3773`, `4103-4110`) | `v2_break_frame_labels`, `v2_continue_frame_labels`, `v2_break_label`, `v2_continue_label`, `v2_label_finally`, `v2_catch_label`, `v2_ref_label` — 9 field declarations, all of one type `LabelId` |
| label handle | `ParserLabelRef` (`parser.zig:11988`) + raw `usize` jump-operand offsets threaded through locals | `LabelId` (`compiler_v2/labels.zig:17`) |
| label address | `LabelSlot { pos, pos2, addr }` — three coordinate spaces (`bytecode.zig:2799-2805`) | `LabelSlot { bound_offset }` — one (`compiler_v2/labels.zig:45-58`) |
| relocation chain head | `?*RelocEntry` heap pointer (`bytecode.zig:2803`) | `u32` index (`compiler_v2/labels.zig:54`) |
| rewind state | `EmissionSnapshot` — 6 fields (`parser.zig:5717`) | `Builder.Snapshot` — 6 fields (`compiler_v2/builder.zig:97`) |

P3 added two dual-carrier structs to `parser.zig`: `Label { v2, legacy_pending,
legacy_target }` (`parser.zig:11561`) and `PhysLabel { v2, legacy }`
(`parser.zig:11581`). Of their five fields, **three are legacy-only** and die
with legacy; what remains is one `LabelId` each.

### 1.4 PUBLIC INVARIANT count

A public invariant here is a rule about the module's data that some function
other than the one establishing it must not violate, counted once per
independently violable cross-function mechanism, and labelled by how a
violation is caught:

* **COMPILE** — the type system or `comptime` makes it unspellable;
* **ASSERT** — a fail-closed check (all-build `error`, or a Debug/ReleaseSafe
  `std.debug.assert` / `@panic`);
* **ORACLE** — caught by a Debug/ReleaseSafe audit pass or the dual comparator;
* **PROSE** — documented only;
* **NOTHING** — implicit; a violation is silent.

| side | COMPILE | ASSERT | ORACLE | PROSE | NOTHING | total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| legacy (`pipeline_resolve_variables` + `pipeline_resolve_labels` + the parser emission/label/fixup machinery) | 0 | 10 | 3 | 5 | 11 | **29** |
| v2 (`compiler_v2/*` + the `v2F*` facade) | 1 | 15 | 11 | 13 | 2 | **42** |
| delta | +1 | +5 | +8 | +8 | **−9** | **+13** |

**v2 has 13 more public invariants than legacy.** That is the raw answer and it
is the "10 concepts replacing 3" direction the ruling warns about. The
enforcement split is what makes it defensible rather than alarming:

* mechanically enforced contracts (COMPILE + ASSERT + ORACLE) rise **13 → 27**;
* silently-violable contracts (NOTHING) fall **11 → 2**.

The two remaining v2 NOTHING rows are both provenance: `Builder.Snapshot` is six
bare scalars with no builder token, so `rollback` trusts them
(`compiler_v2/builder.zig:97-104`, `587-603`); and `DetachedSegment` carries no
origin token, so a splice into a foreign Builder with coincidentally matching
label indices is accepted (`compiler_v2/builder.zig:833-853`). Legacy has the
same two holes plus nine more, including `ParserLabelRef` cross-function
identity (`parser.zig:11988-12012`), forward-fixup offset targeting
(`parser.zig:6763-6788`), and the parallel break/continue frame-length stacks
(`parser.zig:12239-12263`).

Countervailing finding, reported because it is a real gap: **13 v2 invariants
are verified in code but absent or materially incomplete in the normative
contract** `docs/compiler_v2_contract.md`, which still records the older audited
tip `6d0c69dd`. The largest are same-offset alias canonicalisation, the
`match_barrier` bound-label flag, the S3→S4 `ResolvedProduct` field contract,
the S4 label-format allowlist, the S4 final validator and commit boundary, and
the release-at-consumption lifecycle. The contract document is behind the code.

---

## 2. C3 — comparator special cases

`src/compiler_v2/compare.zig` was **not touched by P3** (last change
`c7f998b8`, S3R+R), so **P3 added zero comparator special cases**. The recount
below is therefore a re-derivation on a stated rule, not a change measurement.

Two counting rules are reported because the published "28" is ambiguous between
them:

| view | encoding folds (a) | model normalisations (b) | tolerances/skips (c) | total |
| --- | ---: | ---: | ---: | ---: |
| source-decision count (one per range-return / `switch` arm / decoder arm / tolerance) | 35 | 16 | 3 | **54** |
| semantic-family count (statements collapsed to the rule they implement) | 22 | 13 | 3 | **38** |
| distinct semantic targets / families (closest to the published rule) | **18** | **13** | 3 | **31 + 3** |

Prior: **28 = 20 encoding folds + 8 model-level normalisations.** The closest
comparable figure here is 18 + 13 = 31. The encoding side is slightly *smaller*
than published under a per-target rule (18 vs 20) and the model side is larger
(13 vs 8) — the difference is that this recount counts the constant-pool
identity model (canonical NaN, `sameValue` for BigInt/String, symbol-atom
pairing, frozen tagged-template array structural equality) and the pc2line
decoding model as model-level normalisations. No published enumeration survives
to diff against, so **treat 31 as a re-derivation on a stated rule, not as
evidence of drift.**

### (a) Encoding folds — all 22, and the `.short` counterfactual

`foldOpcode` (`compare.zig:891-932`) is 11 range statements plus 11 `switch`
arms = **22 fold statements**, covering 49 + 13 = **62 compact opcode IDs**,
collapsing to **18 distinct semantic targets**: `push_i32`, `get_loc`,
`put_loc`, `set_loc`, `get_arg`, `put_arg`, `set_arg`, `get_var_ref`,
`put_var_ref`, `set_var_ref`, `call`, `push_const`, `fclosure`,
`push_atom_value`, `get_field`, `if_false`, `if_true`, `goto`.

13 further decisions exist only to support those folds: implicit-operand and
implicit-atom materialisation (`compare.zig:1008-1017`), the operand-less
compact formats accepted only when an implicit operand exists
(`compare.zig:1023-1025`), the u8/u16/u32 and i8/i16/i32 width arms, the
`label8`/`label16`/`label` displacement-width arms, and
`CodeAtomCounts.semantic() = explicit + implicit` (`compare.zig:709-739`),
which reconciles the atom-owner ledger against opcodes like `get_length` and
`push_empty_string` whose atom is implicit in the opcode ID.

**All of these exist only because production emits `.plain`.** V2 selects
`default_layout = .plain` (`compiler_v2/resolve_labels.zig:21`, used at
`compiler_v2/root.zig:75`) while legacy emits the compact forms. Under
`.short`, **all 22 fold statements / 35 source-level encoding decisions would
stop widening legacy↔v2 equality**: both sides would select the same compact
opcodes, the same implicit operands and atoms, and the same displacement
widths. The decoder arms would still be needed to *decode* compact bytecode,
but their cross-layout normalisation would be a no-op. That is 65% of the
source-decision count and 58% of the semantic-family count.

**The default is FROZEN and is not changed here.**

### (b) Model-level normalisations — 13 families

Atom identity (dynamic atom id → `(kind, name)`; `no_symbol_description`;
symbol/private one-to-one pairing, `compare.zig:488-540`); source text by bytes
not pointer; canonical Number bits including a single canonical NaN
(`compare.zig:742-745`); BigInt and String by `sameValue` not heap identity;
symbol-valued constants through the atom model; tagged-template frozen arrays
by full structural product (`compare.zig:808-879`); the jump-target model
(relative displacement → `target_pc` → `target_ordinal`,
`compare.zig:978-987`, `1136-1177`); the source-event model (pc2line
compact/extended decoding → absolute `(pc,line,col)` → ordinal,
`compare.zig:305-350`, `1143-1156`); the ordinal-block CFG product; and the
continuation product in `(kind, ordinal, target ordinal)` coordinates.

These would all survive `.short`: each reconciles a genuine model difference,
not an encoding one.

### (c) Tolerances — 3, and none of them hides a divergence

1. `Ledger.labels_created` is written (`compiler_v2/root.zig:79`) and never
   read by `compareCompiles` — created-label telemetry is not an equality
   input, while `labels_unbound == 0` and relocation balance still are
   (`compare.zig:424-434`).
2. `ledger.source_events_emitted > ledger.source_markers` is a one-sided check
   (`compare.zig:435-443`): identical adjacent markers may coalesce into one
   encoded pc2line event, so surplus markers are tolerated; a *deficit* fails.
3. `var_ref_idx` is compared only when both rows are captured
   (`compare.zig:680`) — finalization writes zero and readers ignore the field
   for uncaptured rows.

**No special case papers over a known semantic divergence.** One coverage
caveat is worth recording anyway: `FunctionBytecodeImpl.realm` is never
compared. It is not an active legacy↔v2 tolerance today because both parses
copy the same `compile_context.realm` through the shared finalizer, but a
future backend-specific realm-publication bug would escape this comparator.

---

## 3. C4 — semantic inventory delta

### 3.1 Pipeline inventory

```
Legacy concepts removed: 37
V2 concepts added:       33
Net: -4 concepts
```

Prior: 41 removed / 36 added / net −5. The published tally is reproducible as a
**raw named-carrier census**, but it was not rename-normalised. Four
concept-preserving renames were counted on both sides
(`function_def.RelocEntry`→`labels.RelocEntry`,
`function_def.JumpSlot`→resolve-labels `JumpSlot`,
`TopologyInstruction`→`TempInstruction`, `Phase2Product`→`ResolvedProduct`);
removing those symmetric pairs leaves the net unchanged. One genuinely
one-sided error existed: `Builder.Snapshot` was counted as an addition without
its legacy counterpart `State.EmissionSnapshot` (`parser.zig:5717`), so the
honest pre-P3 baseline is **−6**, not −5.

**P3 moves the normalised result two concepts toward zero, −6 → −4:**

* `Emitter` (`parser.zig:11598`) adds one protocol but removes the
  construct-local "which backend am I" protocol — those cancel;
* `Label` (`parser.zig:11561`) is a genuinely new concept: a deliberately
  one-shot patch label that may also become a backward target, which is not
  `ParserLabelRef` and not `PhysLabel` (+1);
* `PhysLabel` (`parser.zig:11581`) is a rename of `ParserLabelRef` — the source
  says so — so it adds nothing, but that also **withdraws the previously
  claimed removal of `ParserLabelRef`** (−1 removed);
* `LegacyEmitter` and `V2Emitter` are name-only forwarders and add nothing.

So `41 − 4 renames − 1 ParserLabelRef + 1 backend-fork = 37 removed`, and
`36 − 4 renames − 1 Snapshot + 2 (Emitter, Label) = 33 added`.

The biggest genuine consolidations all still hold on this tree:

| consolidation | verified |
| --- | --- |
| 13 legacy peephole structs → one `matchSeq` + `PatternToken`/`SeqMatch` | holds — 13 structs at `bytecode.zig:9543…10212`; one generic matcher at `resolve_labels.zig:773`, used at 36 sites |
| `LabelSlot { pos, pos2, addr }` → `bound_offset` | holds exactly (`bytecode.zig:2799` vs `labels.zig:45`) |
| 6 parser fixup lists → 2 `LabelId` lists | holds exactly (`parser.zig:3752`, `4103` vs `4108`, `4111`) |
| ~17 legacy binding concepts deliberately retained | holds; the curated reuse surface (`bytecode.zig:9270`) is **50** exported symbols, not ~48, grouping into 17 retained semantic families |

### 3.2 The ownership term the ruling added

**First, a branch fact that must not be buried: the UAF ownership audit and the
borrowed-atom lint are not on this branch.**

| artifact | `compiler-v2-qjs` @ `23f7ed14` | `main` @ `f6b68556` |
| --- | --- | --- |
| `tools/architecture/check_borrowed_atoms.js` | **absent** | present, wired into `architecture-check` |
| `tools/architecture/borrowed-atoms-allowlist.json` | **absent** | present, **14 entries** |
| `docs/borrowed_atom_audit.md` | **absent** | present |
| `-Dzjs_ownership_audit` + one-slot atom quarantine | **absent** (`finalizeDeadEntry` pushes the dead slot straight onto the LIFO free list, `src/core/atom.zig:1538`) | present (`main:build.zig:39`, `main:src/core/atom.zig:883`) |

The split is partial, not total. The branch **does** already free
identifier-token atoms (`parser.zig:394-400`, qjs `free_token`
`quickjs.c:22190`) and **does** have the `*Owned` return convention
(`moduleImportNameAtomOwned`, `parser.zig:20523`). It still carries the
un-duped borrowed-return shapes in `exportDefaultFunctionName` /
`exportDefaultClassName` (`parser.zig:20773`, `20800`) and the
borrowed-after-`advance` delete-super shape (`parser.zig:8903`) that main has
fixed.

**On the branch as it stands** the ownership term is:

```
Implicit ownership assumptions removed: 1
  - "identifier-token atoms are immortal because the lexer leaks their retain"
    -- killed by freeToken's `.ident` release arm (parser.zig:400)
Explicit ownership concepts added: 2
  - the token-payload lifetime boundary (an identifier token owns its atom only
    until advance()/freeToken())
  - the `*Owned` return contract (parser.zig:20523)
```

so C4 on the branch is `-4 - 1 + 2 = **-3 concepts**.

**After main's ownership work merges**, two further implicit assumptions die
(borrowed lookahead returns surviving helper exit by LIFO slot-reuse luck;
reading a member atom after `advance()` released the token) and six further
explicit concepts arrive (lint rules A/B/C/D — `borrowed-return`,
`borrowed-state-store`, `borrowed-use-after-release`,
`owned-escape-state-store`; the allowlist-with-exit-milestone governance
protocol; and the `-Dzjs_ownership_audit` one-slot quarantine tier):

```
C4 = -3 - 2 + 6 = +1 concept
```

**The ownership term flips C4 positive.** That is the honest arithmetic under
the ruling's instruction to count it, and it should be stated rather than
smoothed: making ownership explicit costs more named concepts than the implicit
assumptions it removes, because one implicit assumption is replaced by four
separately-named escape rules plus a governance protocol plus a runtime tier.

The result is rule-granularity sensitive, so both readings are given. If lint
rules A–D are counted as **one** concept ("a borrowed atom must not escape its
owner's lifetime", four detectors) rather than four, the additions are 3 and
C4 = **−2**. This scorecard does not pick; the ruling's phrase "explicit
ownership boundaries" reads more naturally as four named contracts, which is
why +1 is stated first.

Two further honest notes:

* **14 allowlist entries** are outstanding on main (3 `borrowed-return`, 4
  `borrowed-state-store`, 5 `borrowed-use-after-release`, 2
  `owned-escape-state-store`). Each is a known borrow **not yet removed**, so
  they earn no "implicit assumption removed" credit. Ownership is machine-*policed*,
  not machine-*proved*.
* The v2 Builder atom ledger, item-wise release, and `takeLastAtomOwned`
  **do not** increase C4: legacy `FunctionDef` already owns an
  `atom_operands` ledger with owned sinks (`bytecode.zig:3487`, `3508`) and a
  reverse `takeLastAtomOperand` transfer (`bytecode.zig:3523`). Those are
  retained/renamed, not added.

### 3.3 C4, every reading side by side

| reading | net |
| --- | ---: |
| published (raw carrier census, not rename-normalised) | −5 |
| rename-normalised pre-P3 baseline | −6 |
| **pipeline-only, post-P3** | **−4** |
| post-P3 + the branch's own ownership term | **−3** |
| post-P3 + ownership after main merges (lint = 4 concepts) | **+1** |
| post-P3 + ownership after main merges (lint = 1 concept) | −2 |

---

## 4. STOP-D — identity kinds, and the fan-out / chain-depth census

**Not triggered.** The v2 parser has exactly **one** jump-target identity:
`LabelId`. Legacy has at least twelve distinct notions a jump target can be
represented as, and all of them are still in the tree:

1. phase-1 PC — `LabelSlot.pos` (`bytecode.zig:2801`)
2. phase-2 PC — `LabelSlot.pos2` (`bytecode.zig:2802`)
3. phase-3 address — `LabelSlot.addr` (`bytecode.zig:2803`)
4. label index — the `i32` in `JumpSlot.label` (`bytecode.zig:2811`)
5. `ParserLabelRef` — the parser-side handle (`parser.zig:11988`)
6. `RelocEntry` heap pointer — `LabelSlot.first_reloc` (`bytecode.zig:2803`)
7. `JumpSlot` (`bytecode.zig:2808`)
8. `SparseRelocation` (`bytecode.zig:6365`)
9. the `pc_map` old→new pair table (`bytecode.zig:8273`)
10. `Phase1CfgNode` index (`bytecode.zig:7342`)
11. `TopologyInstruction` index (`bytecode.zig:7256`)
12. the in-stream `op.label` pseudo-op (31 emission/consumption sites across
    `parser.zig` and `bytecode.zig`)
13. pc2line PC

**Identity fan-out / chain depth, re-measured on this tip** rather than carried
forward: `zig build zjs-dev -Dzjs_compiler=v2`, then
`ZJS_V2_IDENTITY_HEALTH=1 zjs-dev mc.js` (the vendored Octane `code-load`
payload — Closure `base.js` + jQuery 1.7.2 — 120 iterations):

```
identity kinds=5 instances=367454
fan-out{mean=1.12 p95=2 max=7}
chain{mean=3.04 p95=4 max=4 +final-hop=298450}
final-source{events=2465335 on-identity=232564 between-identities=2232771}
unanchored{source=179883 fold=41406 contested=4082}
```

Identical to the previously reported figures (fan-out mean 1.12 / p95 2 /
max 7; chain mean 3.04 / p95 4 / max 4). P3 did not move the identity model,
which is the intended result; the same run reports `CHECKSUM: 240/240`.

Two different things are called "identity kinds" and must not be conflated: the
`5` in that line is the *census taxonomy* `cfg.identity_kinds =
{label, boundary, block, source_event, fold_region}` (`cfg.zig:127`) — the kinds
of thing the census buckets. The STOP-D count is how many representations a
**jump target** may take, and that is 1 versus ≥12.

---

## 5. STOP-E — migration-only code

### 5.1 The number

```
full          4,165 / 9,156 = 45.5%
conservative  3,883 / 9,156 = 42.4%
band          ~30-50%
```

**VERDICT: PASS on this ruler — read §5.3 before using that word.** Both
variants are inside the band. The full variant has fallen 61.6% → 45.5% since
the S6 tip; the conservative variant is roughly where it was (43.6% → 42.4%)
and is **worse than it was immediately before P3** (37.9% → 42.4%), because the
conservative variant already excluded the mechanical scaffolding P3 deleted
while P3's new 235-line dispatch layer counts and the v2-production denominator
shrank by 468.

### 5.2 Per-file breakdown

| bucket | S6 `642e7b8d` | pre-P3 `d35c66ea` | post-P3 `23f7ed14` |
| --- | ---: | ---: | ---: |
| `compiler_v2/compare.zig` — comparator core | 1,767 | 1,810 | **1,810** |
| `compiler_v2/compare.zig` — comparator self-tests | 314 | 361 | **361** |
| `compiler_v2/tests.zig` — phase1→v2 translator | 694 | 694 | **694** |
| `compiler_v2/coverage.zig` — L3 emission gate | 0 | 276 | **276** |
| `parser.zig` — gate-arm scaffolding | 1,265 | 1,304 | **248** |
| `parser.zig` — P3 `Emitter` dispatch + `LegacyEmitter` | 0 | 0 | **235** |
| `compiler_v2/test_entry.zig` — dual test entry | 0 | 146 | **146** |
| `parser.zig` — dual dispatch in `compile()` | 138 | 143 | **143** |
| `compiler_v2/cfg.zig` — audit oracle | 110 | 111 | **111** |
| `compiler_v2/root.zig` — comparator ledger plumbing | 65 | 107 | **107** |
| `parser.zig` — L3 coverage hooks | 0 | 32 | **32** |
| `parser.zig` — fail-closed legacy-emitter asserts | 9 | 0 | **0** |
| `parser.zig` — `v2_ledger` plumbing sites | 2 | 2 | **2** |
| **total** | **4,364** | **4,986** | **4,165** |

Dual-arm gate sites, independently recounted here and reproducing P3's report
exactly (pre-P3 `d35c66ea` → post-P3 `23f7ed14`): **414 → 62** dual-arm blocks
(−85%), 30 v2-only blocks unchanged, `v2_available and ` line count 469 → 117,
`parser.zig` 22,942 → 21,775 raw lines and 19,358 → 18,105 code lines. At the S6
tip the corresponding figures were 401 dual-arm blocks and 464 `v2_available
and ` lines.

### 5.3 Why the pass is fragile — three things the ratio hides

**(a) The numerator barely moved.** 4,364 → 4,165 is −199 lines, −4.6%, across
the whole S6→post-P3 window. P3 deleted 1,056 lines of gate scaffolding; over
the same window the L3 coverage gate (+276), the unified test entry (+146), the
P3 dispatch layer (+235), the L3 hooks (+32), comparator growth (+90) and
ledger growth (+42) added ~820 back. Decomposing the 16.1pp drop in the full
ratio: holding the denominator at 7,083, the numerator change alone gives 58.8%
(−2.8pp); holding the numerator at 4,364, the denominator change alone gives
47.7% (−13.9pp). **About 86% of the improvement is denominator growth.**

**(b) Most of that denominator growth is oracle, not compiler.** Of `cfg.zig`'s
2,488 pre-test code lines, **1,376 are `audit_oracles`-gated**
(Debug/ReleaseSafe only, `cfg.zig:22`), of which 111 are already booked as
migration-only. If the remaining 1,265 — `auditBoundaryUniqueness` (586),
`classifyAnchorSplits` (158), the fan-out and anchor censuses, the report
formatters — are classified as migration diagnostics rather than v2 production
(they exist to prove the v2 identity model agrees with legacy notions; the
`OracleReport` doc comment describes "every legacy-notion boundary claim
resolved against the v2 identity that owns it", `cfg.zig:70-74`), then

```
5,430 / 7,891 = 68.8%   ->  STOP-E STILL TRIGGERED
```

That is not a contrived reading; it is the reading under which the ratio
measures *compiler* rather than *instrumentation*. This scorecard does not pick
between them. Both are stated so the decision is the reader's.

**(c) One correction that runs the other way.**
`cfg.auditInstructionOwnership` (111 LOC) is booked as migration-only because
S6 booked it there, but it does not compare against legacy at all: it audits the
v2 builder stream against the v2 block graph (`cfg.zig:1192`, called from
`resolve_variables.zig:2079`), so it survives legacy deletion. Moving it to
production gives 4,054 / 9,267 = **43.8%** (−1.7pp). It is disclosed rather
than taken, because the headline should stay on the ruler that produced the
original figure.

Two further variants for completeness: excluding the comparator self-tests as
"tests rather than migration code" gives 41.5%; also excluding the relocated P3
dispatch namespace from the conservative variant — it is the same mechanical
"which backend am I" branch, moved from 464 sites into one — gives 40.8%.

### 5.4 What is left, and the schedule argument

Of the 4,165 migration-only lines, **4,054 are deleted the day legacy is
deleted** — everything except `auditInstructionOwnership`:

| survives legacy deletion | dies with legacy |
| --- | --- |
| `cfg.auditInstructionOwnership` (111) | comparator core + self-tests (2,171); phase1→v2 translator (694); L3 coverage gate + hooks (308); P3 dispatch + `LegacyEmitter` (235); dual test entry (146); dual dispatch in `compile()` (143); ledger plumbing (109); residual gate scaffolding (248) |

`compare.zig` at 2,171 lines is **52% of the whole numerator** and the single
largest remaining component. It is deletion-scheduled by construction: a
comparator with only one compiler to compare has nothing to do.

**That is an argument about schedule, not about the current number.** As of
`23f7ed14` those 2,171 lines exist, are maintained, and are counted. The
reachable floor without touching the comparator is
`(4,165 − 660) / 9,156 = 38.3%` — removing every remaining parser-side
migration line (residual scaffolding, dual dispatch, the P3 dispatch layer, the
L3 hooks, the ledger sites) — inside the band, but only by 12 points, and only
on the denominator that includes the oracle.

The 62 surviving dual-arm sites are, by P3's family census: 32 control flow
deliberately out of scope (multi-pending patch lists, break/continue fixup
frames), 11 direct `v2Builder()` / byte-stream mutation, 6 source markers and
emission snapshots, 6 detach / splice / `truncateCode`, 4 raw labels /
assume-capacity / `patchJumpTarget` retargeting, 3 other.

---

## 6. Gates

| gate | result |
| --- | --- |
| `zig fmt --check src/ build.zig` | PASS |
| `zig build zjs -Dzjs_compiler=legacy` | PASS |
| `zig build zjs -Dzjs_compiler=v2` | PASS |
| `zig build zjs -Dzjs_compiler=dual` | PASS |
| `zig build zjs-dev -Dzjs_compiler=v2` | PASS |
| `zjs-dev` (v2) on `mc.js` | `CHECKSUM: 240/240` |
| source changes outside this file | none |
