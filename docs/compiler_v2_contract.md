# compiler-v2 identity contract (QCP-1 Stage 0.5)

Status: normative for every stage after S0.5 on `compiler-v2-qjs`.
Audited against the branch tip `6d0c69dd` (S1 builder, S2P facade, S2 G1-G4
parser migration, S3 resolve_variables_v2). Line numbers cite that tip; when
they drift, the cited function names are the stable anchors.

## 0. Ruling reframe (binding)

The goal is a **zjs identity-native compiler**, not a QuickJS clone. What
migrates from QuickJS is its **control-flow identity model**:

- the parser binds **no addresses** — a jump is born against a `LabelId` and
  stays a `LabelId` until final layout;
- relocation exists only for real consumers (`RelocEntry` per pending operand,
  chained per label);
- resolve passes are separate (`resolve_variables_v2` now, `resolve_labels_v2`
  next), and **byte addresses exist only after final layout**.

What is preserved from zjs: exact-CFG semantics as the auditing oracle,
ownership validation (atom ledger, item-wise release), OOM transactional
discipline (no consumer may observe half-published state), and the
Debug/ReleaseSafe fail-loud oracles. Absolute PC exits the core identity
system; zjs language semantics do not change.

## 1. Identity taxonomy

These are the only identities a v2 producer may create. Every later stage
(S3R exact-CFG liveness, resolve_labels_v2) keys off them.

| Identity | Definition | Role |
| --- | --- | --- |
| `LabelId` | `src/compiler_v2/labels.zig:17` — function-scoped `enum(u32)` creation index | **Jump identity.** The 4-byte operand of every jump-format instruction holds the `LabelId` (little-endian) until final emission. Stable across detach/splice: a moved block keeps its `LabelId`s; only slot offsets rebind. |
| bound label (a `LabelSlot` with `flags.bound`) | `labels.zig:41` — `bound_offset` is the temporary-stream position of the bind | **Block boundary.** The bind slot replaces the legacy in-stream `op.label` pseudo-op; it is the exact-CFG node key S3R will consume. `v2FBindLabel` (parser.zig:10918) = bind **and** invalidate `last_opcode_pos` (control-flow merge, qjs `emit_label`); `v2FBindLabelRaw` (parser.zig:10925) = bind only (provenance-preserving, qjs `emit_label_raw`; used by the optional-chain close). |
| aux label | same `LabelId`, referenced through a `RelocEntry` of kind `.aux32` | The `scope_make_ref` secondary operand (op + atom(4) + label(4) + scope(2)); `Builder.emitScopeRefOpOwned` (builder.zig:396). The put side **binds** it (qjs `put_lvalue` `emit_label`). |
| `ref_count` | `LabelSlot.ref_count`, bumped on every referencing emission, decremented on rollback/detach/dead-code removal | qjs `update_label` bookkeeping retained for the resolve_labels_v2 short-form pass. Since S3R it is **never a liveness input**: dead-code decisions come from the exact block CFG (see section 5). |
| `backward_target` flag | set when a reference is emitted against an already-bound label (and on splice when the bound target precedes the operand) | Conservative loop marker for short-form bookkeeping. **Never a correctness input**; rollback deliberately does not clear it (builder.zig:549-551). |
| source event | `SourceSlot { temp_offset, line, col }` (builder.zig:36) | pc2line identity. Bound to the logical output event order, **not** to a byte pc of any final stream; final emission maps events to output positions (QuickJS shape — no old-PC relocation chain). Markers with `line <= 0 or col <= 0` are dropped at the sink. |
| `last_opcode_pos` | `Builder.last_opcode_pos` (builder.zig:133), qjs `fd->last_opcode_pos` | The **sole target fact** for speculative-LHS rewinds (`v2GetLValue`) and the straight-line half of liveness. Invalidated (−1) at every merge bind, `truncateTail`, `detachTail`, `spliceSegment`. |

**The byte-PC rule.** Byte offsets of the temporary stream may appear in v2
parser arms only as *stream-editing coordinates*: snapshot lengths,
speculative-LHS tail classification / `truncateTail` positions, the
optional-chain pseudo-getter rewrite (`v2b.code[last_opcode_pos]`), the
switch case-tail scan (`v2CaseTailCanFallthrough`), the class brand-prologue
opcode patch, and liveness/terminal queries (`v2IsLiveCode` and class-init
child close). A byte offset must **never** be written into a jump operand,
and no v2 arm may convert a PC into a target. Relative displacements exist
only inside `resolve_labels_v2` final layout.

## 2. Builder transactional surface

### 2.1 Snapshot / rollback (`Builder.snapshot` / `Builder.rollback`, builder.zig:495-558)

A `Snapshot` is six scalars: `code_len, atom_len, label_len, reloc_len,
source_len, last_opcode_pos`. `rollback(snap)`:

1. releases atom refs beyond `snap.atom_len` (item-wise, ledger-ordered);
2. unchains relocation entries `>= snap.reloc_len` from every surviving
   label, decrementing `ref_count` per entry — sound because chains are
   pushed head-first and walk **strictly decreasing** indices, so the
   post-snapshot entries are exactly the chain heads;
3. labels created after the snapshot vanish (`label_len` restore); their
   chains are truncated by construction (Debug-asserted);
4. un-binds surviving labels with `bound_offset > snap.code_len`.

**Boundary-bind caveat (normative).** Rollback **keeps** a bind exactly at
`snap.code_len` (builder.zig:542-548): a pre-snapshot bind there is
indistinguishable from a post-snapshot one, and a kept bind at the restored
position is still valid. Therefore *sites must take their snapshot BEFORE any
boundary bind they may want rolled back*. All committed sites comply
(§4.20/§4.21/§4.22); any future producer that binds first and snapshots at the
same `code_len` is defective by contract.

### 2.2 Tail truncation (`Builder.truncateTail`, builder.zig:567-585)

The qjs `fd->byte_code.size = fd->last_opcode_pos` rewind. Legal **only** for
tails carrying no relocations and no binds: the newest reloc's operand is the
high-water mark (operand offsets are emission-ordered) so the no-reloc
requirement is O(1); binds beyond the boundary are a Debug scan. Source
markers with `temp_offset >= new_code_len` are dropped (note `>=`: a marker
exactly at the cut goes away — unlike rollback, which restores markers by
ledger length). Invalidates `last_opcode_pos`.

### 2.3 Detach / splice (`detachTail` / `spliceSegment` / `discardSegment`, builder.zig:600-850)

`detachTail(mark)` captures the tail emitted since a snapshot taken **at the
segment start, before any emission or bind belonging to the segment**:

- code bytes, ledger atoms (ownership moves out; nothing released), reloc
  entries (unchained with `ref_count` decremented, the rollback discipline),
  binds **strictly inside** the segment (`bound_offset > mark.code_len` — a
  bind exactly AT the mark stays put, the same boundary rule as rollback),
  and source slots by ledger index; all made segment-relative.
- **Labels are NOT captured**: `LabelId`s are function-global, `label_len` is
  untouched. This is the invariant that makes moved blocks (for-update, class
  runtime) sound with zero operand rewriting.
- All validation and all allocations happen before any builder mutation: OOM
  leaves the builder exactly as it was. The builder is truncated to the mark;
  `last_opcode_pos` invalidated.

`spliceSegment(seg)` validates every captured reloc against the segment bytes
(strictly increasing operand offsets, label indices in range), every bind
(label unbound, offset in range), and source monotonicity; reserves all
destination capacity; then re-appends at the current position shifting only
*offsets* by the new base. Jump/aux operands are `LabelId`s and are **not
rewritten** — no target rebase exists in v2. Reloc entries are re-chained
(`ref_count` bumped back), `backward_target` set when a bound target precedes
the operand. The segment is consumed on success; on error it is untouched and
still caller-owned — every parser consumer pairs the segment with a
`defer discardSegment` (parser.zig:12981, 19110).

### 2.4 Ownership and OOM

Atom operands enter the builder through owned sinks
(`emitAtomOpOwned`/`emitAtomOpU8Owned`/`emitAtomOpU16Owned`/
`emitScopeRefOpOwned`): the sink consumes the caller's retain even when a
capacity reservation fails. `takeLastAtomOwned` is the reverse transfer used
by the getter rewind. `deinit` releases the initialized ledger prefix then
frees backings by full capacity; uninitialized tails are never read. OOM
anywhere leaves the builder consistent for `deinit`; a failed v2 parse
abandons the whole product, so v2 arms need mid-sequence rollback only where
*parser* state must be restored (the optional-chain label, §4.5).

### 2.5 Parser-facing wrappers

`v2F*` free functions (parser.zig:10823-10927) map Builder errors into parser
errors and split marker'd vs `NoSource` emission: `v2FEmitJump`/`v2FEmitOp`
etc. add a source event at the current token first; the `NoSource` twins do
not; `v2FEmitOpAt` pins one opcode to an explicit source event (assignment /
update operators). Every runtime gate is spelled
`v2_available and s.emit_v2` so legacy builds fold the v2 leg away at
comptime. Any un-migrated construct reaching legacy emission during a v2
parse fails loudly: `appendBytesNoSource`/`appendBytesNoSourceAssumeCapacity`
assert `!(v2_available and self.emit_v2)` (parser.zig:5747, 6796).

## 3. Frame-level identity carriers

Break/continue/labelled-control and finally identities live in parser frames
so that a `break`/`continue`/`return` is *born* as a jump to the right
`LabelId` — there are no operand-offset fixup lists in v2:

- `pushBreakFrame` (parser.zig:11202): creates the continue label then the
  break label (qjs `push_break_entry` order) into
  `v2_continue_frame_labels`/`v2_break_frame_labels`.
  `pushBreakOnlyFrame` (11218): break label only (switch).
- `patchContinueFrame` (11648) binds the top continue label;
  `popBreakFrameAndPatch` (11662) pops both and binds the break label;
  `popBreakOnlyFrameAndPatch` (11686) likewise. Binds are unconditional even
  at zero refs — *every created label ends bound*; resolve_labels_v2 drops
  dead ones.
- `LabelFrame.v2_break_label` / `v2_continue_label` (parser.zig:3725):
  created by `pushLabelFrame` (5202, continue label first when allowed);
  bound unconditionally by `patchLabelBreaks`/`patchLabelContinues`
  (5221/5235).
- `FinallyLabel` (10965) and `BlockEnv.v2_label_finally` (3709): the gosub
  target identity. `BlockEnv.v2_label_finally` is the declared twin of legacy
  `label_finally = -1` and is **never set** in zjs (try uses
  `return_finally_frames`); the consuming arm in
  `emitCrossedControlBlockCleanup` (14173) is intentionally dead symmetric
  code.
- `emitResolvedControlJump` (14119): the single place an unlabelled/labelled
  break or continue becomes a `goto` — always against a frame or label-frame
  `LabelId`; fails closed (`Error.UnexpectedToken`) if the depth has no v2
  label.
- Function boundaries: `enterControlBoundary`/`leaveControlBoundary`
  (5342-5400) swap the v2 label lists along with the legacy fixup lists, so
  no frame label leaks across a nested function parse.

## 4. Producer inventory

Format per producer: **Identities** (what it creates), **Rollback** (which
snapshot discipline covers it), **Audit** (does the committed arm match).

### 4.1 `if` / `else` — parser.zig:12679-12745

- Identities: `v2_if_false_label` (created after the condition, jump
  `if_false`); with `else`: `v2_else_goto_label` (`goto` over the else) and
  the if_false label binds at the else entry; the merge bind closes whichever
  label is open. One wrapper scope for the whole statement (qjs shape).
- Rollback: none needed (no speculation).
- Audit: **matches** qjs `TOK_IF` (quickjs.c:29018): emit_goto(if_false) /
  emit_goto(goto) / emit_label at each merge. All labels end bound.

### 4.2 conditional `?:` — `parseCondExpr`, parser.zig:8146-8182

- Identities: else label (if_false), end label (goto); binds at else entry
  and merge.
- Audit: **matches** qjs `js_parse_cond_expr`.

### 4.3 logical `&&` / `||` chains — `parseLogicalAndOr`, parser.zig:8230-8303

- Identities: a **single** end label created before the operand loop; per
  operand `dup ; if_true/if_false → end ; drop`; one bind at the end
  (NoSource emission throughout).
- Audit: **matches** qjs `js_parse_logical_and_or` (single-label lowering for
  the whole chain).

### 4.4 nullish `??` chain — `parseCoalesceExpr`, parser.zig:8185-8227

- Identities: single end label; per operand
  `dup ; is_undefined_or_null ; if_false → end ; drop`; bind at end.
- Audit: **matches** qjs `js_parse_coalesce_expr`.

### 4.5 optional chain `?.` — `emitOptionalChainTest` (9620-9647) + chain close (9097-9114)

- Identities: the chain-exit `LabelId` (`OptionalChainLabel.v2`, created
  lazily at the first `?.` of the chain) and a per-test NEXT label. Test
  shape: `dup ; is_undefined_or_null ; if_false NEXT ; drop×n ; undefined ;
  goto CHAIN_EXIT ; bind NEXT` (qjs `optional_chain_test`).
- Rollback: Builder snapshot taken **before** any test emission;
  `errdefer { rollback(snap); optional_chain_label.* = old_label; }` — the
  only v2 site needing mid-sequence rollback, because the lazily created
  chain label and the caller-visible label pointer must both revert (the
  label itself vanishes via the `label_len` restore). Snapshot precedes every
  bind the sequence performs → boundary-bind caveat satisfied.
- Chain close: `v2FBindLabelRaw` (raw bind: the preceding getter stays
  visible as provenance), then the pseudo-getter rewrite
  `get_field → get_field_opt_chain` / `get_array_el → get_array_el_opt_chain`
  by patching `v2b.code[last_opcode_pos]`, else `invalidateLastOpcode`. Byte
  offsets used as stream-editing coordinates only.
- Audit: member/element chain tests and close **match**; the bind slot
  subsumes the legacy in-stream raw label marker and resolve_labels_v2
  lowers `*_opt_chain` exactly like phase 2. Optional-call consumers remain
  legacy (Findings F-7).

### 4.6 `while` — parser.zig:12746-12798

- Identities: top label **bound at the test** (back edge later references a
  bound label → `backward_target`), exit label (`if_false`); frame labels
  from `pushBreakFrame`; continue label bound by `patchContinueFrame` before
  the back edge; `goto` top; bind exit; break label bound by
  `popBreakFrameAndPatch`.
- Audit: **matches** qjs `TOK_WHILE` (label_cont bound at the test; back edge
  is emit_goto against the bound label).

### 4.7 `do`/`while` — parser.zig:12800-12842

- Identities: body label bound at body start; continue frame label bound at
  the test; `if_true` back edge to the bound body label; break frame label
  bound after.
- Audit: **matches** qjs `TOK_DO`.

### 4.8 classic `for` — parser.zig:12843-13057

- Identities: top label bound before the test (the bind slot **subsumes**
  legacy's in-stream anonymous `label 0` marker — an intentional, documented
  shape improvement with identical resolved output); empty test emits
  `push_true`; exit label (`if_false`); frame labels; continue labels bound
  before the update splice; `goto` top; bind exit.
- Update clause (detach/splice consumer): Builder snapshot `v2_update_mark`
  taken **before** parsing the update (12963); after the parenthesized parse,
  `detachTail` iff code grew (empty update detaches nothing — S2-G2 byte
  shape preserved); the segment is spliced after the body and the bound
  continue labels (13026); `defer discardSegment` (12981) covers all error
  paths. `LabelId`s inside the update survive the move untouched.
- Boundary caveat: the emission immediately before the mark is the `if_false`
  jump — no bind can sit exactly at the mark from this producer; binds
  emitted inside the update are strictly interior and are captured.
- Audit: **matches** qjs `TOK_FOR` (label_test before the test; update block
  moved after the body).

### 4.9 `for-in` / `for-of` / `for await of` — `parseForInOf`, parser.zig:14559-14949

- Identities: expr label (initial `goto` skips the one-pass target block);
  assign label bound at the target block (later a **backward** `if_false`
  re-enters it); body label; next label (continue target for the step
  sequence); frame labels. Sequence:
  `goto expr ; bind assign ; <target> ; goto body ; bind expr ; <iterable> ;
  for_in_start/for_of_start/for_await_of_start ; goto next ; bind body ;
  <body> ; bind cont-frame ; bind next ; for_*_next(+await+
  iterator_get_value_done) ; if_false → assign ; drops/iterator_close ;
  bind break-frame`.
- Audit: control-flow/label order **matches** qjs `js_parse_for_in_of`,
  including the for-await variant's NoSource `if_false` and post-loop
  `iterator_close` placement; non-declaration identifier targets are blocked
  by Findings F-8.

### 4.10 `switch` — parser.zig:13085-13355

- Identities: per case a no-match label (`if_false` after
  `dup ; <case expr> ; strict_eq`), bound at the next case's test or in the
  epilogue; fallthrough labels (`goto` emitted only when
  `v2SwitchBreakRefCount` unchanged and `v2CaseTailCanFallthrough`); an
  **eager default candidate** label created and bound at the default body
  start (legacy decides `default_body_start` after the fact; a v2 bind must
  happen at the position itself — an empty default followed by a case defers
  and re-creates the label at that case's body start; the abandoned candidate
  stays bound with zero refs and is dropped by resolve); the switch break
  frame label (`pushBreakOnlyFrame`, discriminant cleanup drop = 1).
- Epilogue (**deliberate, documented shape deviation**): qjs binds the
  default label backwards with an in-stream patch (the "ugly patch",
  quickjs.c ~29365); v2 label discipline forbids patching, so unmatched
  dispatch routes `goto skip ; bind no-match labels ; goto default ;
  bind skip`, shielded from straight-line fallthrough of the last clause
  body. Resolved semantics identical; identity discipline preserved.
- Liveness twins: `v2SwitchBreakRefCount` (11401) reads the frame label's
  `ref_count` — the exact twin of legacy `break_fixups` growth (labelled
  breaks ride the label frame's label in both backends);
  `v2CaseTailCanFallthrough` (11410) scans the temp stream from the body
  start (v2 streams carry no `line_num`/`label` pseudo-ops), same terminator
  set as `caseCanFallthrough`.
- Audit: **matches** (with the epilogue deviation documented above; all
  labels end bound; the 64-entry no-match arrays fail closed on overflow in
  both backends).

### 4.11 `break` / `continue` (incl. labelled) — 13058-13084, 5264-5302, 11329-11351, 14119-14154

- Identities: **none created** — the jump is born as the target frame's or
  label frame's `LabelId` through `emitResolvedControlJump`. Cleanup
  (catch-marker drops, iterator_close, crossed-finally
  `undefined ; gosub ; drop`) is fully v2-gated
  (`emitCatchMarkerDropsFromDepth` 11298, `emitCrossFrameCleanup` 11279,
  `emitControlThroughFinally` 14231).
- Audit: **matches** qjs `emit_break` / `emit_goto(label_cont)`. The four
  `*NoFinallyCapture` variants (5268/5287/11334/11346) are legacy-only dead
  code with no callers — no v2 exposure.

### 4.12 labeled statement — parser.zig:12471-12508 + §3

- Identities: `LabelFrame.v2_break_label` (+ `v2_continue_label` when the
  labelled statement is a loop; loops and `switch` receive the pending label
  and create the frame inside their own arm). Other non-loop labelled
  statements bind the break label via `patchLabelBreaks` after the body; a
  labelled-statement `BlockEnv` carries the break target for the finally
  walker.
- Audit: **matches**; binds are unconditional (dead labels resolved away).

### 4.13 `throw` — parser.zig:12548-12566

- Identities: none. `op.throw` with the throw-keyword source override.
- Audit: **matches** qjs TOK_THROW (quickjs.c:28596).

### 4.14 `try` / `catch` / `finally` — parser.zig:13356-13573

- Identities: `label_catch`, `label_finally`, `label_end` created upfront;
  **`label_catch2` is created at its first use in the catch clause** — a
  deliberate, documented deviation from qjs (which creates all four upfront,
  quickjs.c:29396-29400) because v2 discipline requires every created label
  bound and a no-catch try never binds catch2. Ids are per-function creation
  indices, so resolved output is unaffected. `op.catch` is emitted as a jump
  referencing the handler label — the handler target is *born* as a
  `LabelId`.
- Shape: live try tail `drop ; undefined ; gosub finally ; drop ; goto end`
  (liveness via `v2IsLiveCode`); catch entry binds `label_catch`; optional
  binding or `drop`; `op.catch → label_catch2`; live catch tail as above;
  bind catch2 `; gosub finally ; throw`; finally-only: bind catch `; gosub ;
  throw`; bind finally; shared finally body; `op.ret`; bind end.
- Frames: `pushReturnFinallyFrame` carries `FinallyLabel{ .v2 }` so any
  `return`/`break`/`continue` crossing the frame gosubs the same identity.
- Audit: **matches** qjs 29396-29539 with the catch2 creation-order exception
  documented in the arm itself.

### 4.15 `gosub` producers — 13414/13514/13529/13540, 13875-13878, 14254-14269, 14173-14179

- Identities: none created; every `gosub` references a `FinallyLabel.v2`.
  Producers: live try/catch tails, catch2 and finally-only rethrows,
  `emitReturnValue` (one gosub per crossed finally frame, qjs emit_return
  28447-28449), `emitControlThroughFinally` (per crossed frame:
  `undefined ; gosub ; drop`), and the dead-symmetric
  `BlockEnv.v2_label_finally` arm (§3).
- Audit: **matches**.

### 4.16 `return` + function terminals — 12530 (TOK_RETURN), `emitParsedReturn` 13951, `emitReturnValue` 13856, `emitFunctionReturn` 13974

- Identities: derived-constructor value substitution creates one label
  (`check_ctor_return ; if_false L ; drop ; checked-this ; bind L`);
  terminals `return` / `return_undef` / `return_async` are plain ops.
- Source: `reattributeReturnTailCallSource` returns null under v2 — pc2line
  derives from Builder source slots at final emission (qjs resolve_labels
  owns the tail-call attribution); no source-slot surgery on the v2 path.
  The legacy `EmissionSnapshot` taken in the TOK_RETURN arm is inert under
  v2 (it snapshots/rolls back only legacy streams; v2 OOM abandonment is
  builder-level).
- Audit: **matches** qjs emit_return 28396-28477.

### 4.17 function terminal / epilogue — 15909-15959, `v2EmitPlainTailForTest` 11475, `emitReturnUndefined` 5112

- Decision: `needs_return = v2IsLiveCode(s)` alone (qjs
  `js_parse_function_decl2` tail, quickjs.c:36946) — every construct
  epilogue bound its merge labels at the end, which invalidated
  `last_opcode_pos` exactly like qjs `OP_label`.
- `v2IsLiveCode` (11445): straight-line half = last opcode not a terminator
  (or `last_opcode_pos < 0` → live); merge half = a **referenced** label
  **bound exactly at the current end** is an incoming edge (twin of legacy
  `max_absolute_target >= tail_start`); unbound labels are future
  handler/exit targets and are **not** edges (twin of the tagged-parser-label
  exclusion).
- Tails: async / (async-)generator → `undefined ; return_async`; derived
  ctor → checked-this ; `return`; plain / script → `return_undef`. Arrow
  expression bodies terminate `return_async`/`return` (16460-16463).
- Audit: **matches**.

### 4.18 `scope_make_ref` (aux-label lvalue) — `v2GetLValue` 7724-7734, `v2PutLValue` 7936-7944

- Identities: one aux `LabelId` per with-scope reference, created in
  `v2GetLValue`, emitted via `emitScopeRefOpOwned`
  (`scope_make_ref` + atom + aux32 label + scope; ref_count bump = qjs
  `update_label(fd, label, 1)`), carried in `LValue.v2_ref_label`.
  `v2PutLValue` frees the descriptor atom then **binds** the aux label before
  the mode shuffle (qjs put_lvalue quickjs.c:26118-26123) — the bind is the
  provenance boundary legacy expressed as invalidateLastOpcode + deferred
  absolute publish. Fails closed if the label is missing.
- Reachability: the `scope_var`/`scope_make_ref` legs are gated on
  `emit_phase1_temp`, and the current v2 harness parses with
  `emit_phase1_temp = false` (compiler_v2/tests.zig:32) because the phase-1
  scope-event group (`enter_scope`/`leave_scope`/`close_loc`, scope_get_var
  family) is not yet migrated — the parser harness cannot produce aux32
  today; Builder inline tests cover the aux32 mechanics (see Findings F-3).
- Audit: arm **matches** the contract; reachable only once the scope-event
  group migrates.

### 4.19 speculative LHS emission — `v2GetLValue` 7686-7790

- Mechanism: `Builder.last_opcode_pos` is the sole target fact (qjs
  `get_lvalue`, quickjs.c:25933). Getter removal = ledger take-back
  (`takeLastAtomOwned`) **then** `truncateTail(pos)` — the qjs
  `fd->byte_code.size = fd->last_opcode_pos` rewind. Legal because the getter
  is a single trailing instruction: no relocs, no binds in the tail
  (truncateTail's O(1)/Debug guards enforce it). `keep` re-emits the getter
  via `v2ReemitLValueGetter` with a dup'd atom (get_field2 /
  scope_get_private_field2 / get_array_el3 / to_propkey+dup3+get_super_value
  / get_ref_value). Update/compound operators pin their op to the operator
  source event via `v2FEmitOpAt` (8477 area, 9067 area).
- Audit: field/array (and phase-1 scope forms once reachable) rewind and
  ownership mechanics **match**; errdefer releases the descriptor atom on
  failure. The current direct-binding `get_var` form is missing (Findings
  F-8).

### 4.20 detach — `v2FDetachTail` consumers (for-update 12998-13004, class runtime 19111-19115)

- Contract: mark snapshot taken at the segment start **before** any emission
  or bind of the segment; empty tail short-circuits (for-update); segment
  paired with `defer discardSegment`; §2.3 boundary rule governs binds at the
  mark (they stay in the main stream — correct: a merge label bound exactly
  where the deferred block begins belongs to the preceding control flow).
- Audit: **matches** on both sites.

### 4.21 splice — `v2FSpliceSegment` consumers (13026, 19213, 19299)

- Contract: splice after the body/`define_class`+brand prologue; no operand
  rewriting (function-global `LabelId`s); consumed on success; error paths
  covered by the paired `defer discardSegment`.
- Audit: **matches** (qjs js_parse_class quickjs.c:25274 / TOK_FOR update
  move).

### 4.22 class constructor discard (speculative rollback) — 17715-17744

- Contract: `v2_ctor_snap` taken **before** the constructor's
  `parseClassElementFunction` emission; if the element was the explicit
  constructor, `rollback(v2_ctor_snap)` discards its ordinary fclosure
  expression (the class references the child through push_const/define_class
  instead). Arm comment records the boundary-bind caveat ("no boundary bind
  is pending here"): a pre-existing merge bind exactly at the snapshot
  position is preserved by rollback — correct, it belongs to the preceding
  class element.
- Audit: **matches** qjs js_parse_class.

### 4.23 class / static block (S2-G4 remainder)

- Default constructors are synthesized directly through the **child fd's own
  Builder** (`v2EnsureBuilderForFd` per FunctionDef; check_ctor /
  enter_scope / init_ctor emitted on the child builder,
  parser.zig:19405-19440). `define_class` / `define_method` /
  `perm3`/`swap` static rotations and the deferred-runtime splice are gated
  arm-by-arm (25 gates in 18400-19000). Static blocks parse as
  `class_static_block` function kind through the same migrated
  function-body/epilogue machinery.
- Audit: spot-checked **matches**; the class-side detach/splice and ctor
  rollback audits are §4.20-4.22.

### 4.24 async resume / generator resume — NOT MIGRATED (see Findings F-1)

The mandated resume producers currently have **no v2 arms**:

- `initial_yield` (15869) — emitted ungated via legacy `s.emitOp` inside the
  otherwise-migrated function-decl arm;
- `yield` expression (8540-8548) — includes a legacy forward jump +
  `patchForwardJump` and an `emitReturnValue` resume split;
- `await` unary (8585), `yield*` delegation (`emitYieldStarDelegation`
  8598-8670, a full legacy label/patch machine), `using`-await
  (11961-11973), and the async-generator `return()`-close walk in the
  return-cleanup path (explicitly fail-loud: parser.zig:16913
  `std.debug.assert(!(v2_available and s.emit_v2))`).

Contract for their future migration: `yield`'s resume split is one label
(`if_false → normal-resume` around the abrupt-completion `emitReturnValue`);
`yield*` needs loop/dispatch labels exactly mirroring the qjs TOK_YIELD
delegation machine (quickjs.c:28005-28150: loop head bound label, backward
`if_false` re-entries, throw/return dispatch labels), all born as
`LabelId`s; `initial_yield` (qjs quickjs.c:36879) is a plain op behind the
standard gate. No new identity kinds are required.

## 5. Liveness note (S3 → S3R)

`LabelSlot.ref_count` + `flags.backward_target` + `last_opcode_pos` were the
qjs **linear** liveness model that S3 (`resolve_variables_v2`) consumed at
first. Stage S3R (landed) replaced that consumer with zjs's exact-CFG model
keyed on **bound labels as block boundaries** (`src/compiler_v2/cfg.zig`):
block starts are the dedup-sorted bound-label offsets plus stream start/end,
edges are LabelId jump operands collected only before each block's first
unconditional terminal (empty-gosub references excluded), and worklist
reachability from entry decides every dead-code/ownership choice.
`ref_count` remains as qjs `update_label` bookkeeping for the
resolve_labels_v2 short-form pass and never decides liveness again. A
Debug/ReleaseSafe oracle (`cfg.auditInstructionOwnership`) recomputes
legacy-style instruction-granularity reachability over the temp stream and
panics on any divergence from `block_live && before-terminal` — the
block/byte boundary-normalization equivalence is a proof obligation, not an
assumption. The identity taxonomy above is the S3R input contract and must
not be weakened (in particular: every label bound, binds ordered, ref_count
exact under rollback/detach/splice).

## 6. Findings (S0.5 audit)

Audit rule applied: any deviation, missing rollback coverage, or absolute-PC
leak in a **committed v2 arm** is a finding; un-migrated producers on the
mandated list are inventory findings. No code was changed in this stage.

- **F-1 (inventory gap, mandated producers): generator/async resume group has
  no v2 arms.** `initial_yield` (parser.zig:15869) is emitted through legacy
  `s.emitOp` with no `emit_v2` gate inside an arm whose neighbors
  (check_ctor 15854, epilogue 15909) are migrated; `yield` (8545),
  `await` (8585), `yield*` (8598), and `using`-await (11964) are entirely
  legacy. Under `emit_v2` these hit the fail-loud funnel assert
  (Debug/ReleaseSafe); in ReleaseFast they would emit into the legacy stream
  mid-v2-parse (mixed streams). Fail-closed today, but the mandated-list
  surface is not covered; the async-generator return()-close site carries an
  explicit local assert (16913) while `initial_yield`/`yield`/`await` rely
  only on the funnel assert.
- **F-2 (half-migrated seam): logical assignment (`&&=`, `||=`, `??=`).**
  `parseAssignExpr2` routes `getLValue` → `v2GetLValue` under v2 (7538), but
  `emitLogicalAssignLValue` (7373-7413) — reached immediately after (7311) —
  is ungated legacy: it emits `dup`/`if_true|if_false` forward jumps and
  `patchForwardJump` absolute patches. Under `emit_v2`, the getter rewind
  mutates the v2 stream and then the first legacy emission asserts: the v2
  half runs before the fail-loud stop. Same fail-closed caveat as F-1; the
  seam should either gain its v2 arm (two labels: skip-assign, end) or a
  local up-front assert before `v2GetLValue` runs.
- **F-3 (gated reachability, documented): the `scope_make_ref` aux-label arm
  (§4.18) is unreachable from the parser today** because the phase-1
  scope-event group is un-migrated and the v2 harness parses with
  `emit_phase1_temp = false` (tests.zig:32, 558-560). The arm and the
  Builder aux32 mechanics are committed and inline-tested; parser-level
  aux32 coverage lands with the scope-group migration. (Recorded so no later
  stage mistakes "no parser aux32" for dead code.)
- **F-4 (inventory note, off the mandated list): `with` (`parseWith`, 14520)
  is fully legacy** (zero gates), as are module import/export emission paths;
  they fail loudly under `emit_v2` via the funnel assert.
- **F-5 (dead symmetric code, benign): `BlockEnv.v2_label_finally` is never
  assigned** (§3); its consumer arm (14173-14179) mirrors legacy
  `label_finally >= 0`, which is equally never taken in zjs. Keep or drop
  with the legacy field, together.
- **F-6 (dead legacy code, benign): the four `*NoFinallyCapture`
  break/continue emitters** (5268, 5287, 11334, 11346) have no callers on
  the branch tip; they predate `emitControlThroughFinally` and never gained
  v2 arms. Removal is safe and would shrink the audit surface.
- **F-7 (half-migrated seam, mandated producer): optional-call chains.**
  The v2 optional-chain test arm runs for `?.(` (parser.zig:9412-9419), but
  `prepareCallReference` / `emitPreparedCall` (8912-9029) remain legacy: the
  former reads `FunctionDef.last_opcode_pos` and the legacy byte stream, and
  the latter calls `emitSourcePosAndLoc` (9001), whose v2 guard asserts
  (6807). Thus direct optional calls and calls after an optional member emit
  v2 chain labels before failing loudly; in ReleaseFast they would mix the
  call into the legacy stream. Field/element-only optional chains remain
  sound.
- **F-8 (half-migrated seam, mandated LHS / for-in/of surface): direct
  binding lvalues.** With `emit_phase1_temp = false`, `emitScopeGetVar`
  lowers an identifier through the v2 `get_var` arm (parser.zig:6115-6121,
  6561-6564), but `v2GetLValue` recognizes only the scope, field, private,
  array, and super getter forms and rejects every other opcode
  (7696-7785). Valid identifier assignment/update and non-declaration
  `for (x in/of y)` targets (14715-14718) therefore return
  `InvalidAssignmentTarget`; the current tests cover field/array lvalues and
  declaration-target for-in/of forms, not this path.

No absolute-PC leak was found in any committed v2 arm: every jump operand in
the v2 temp stream holds a `LabelId` (jump32) or aux `LabelId` (aux32); all
byte-offset uses are stream-editing coordinates per the byte-PC rule (§1).
No committed snapshot/detach site violates the boundary-bind caveat: all four
Builder-snapshot sites (9628, 12963, 17723, 19095) snapshot before any
emission or bind they may revert.
