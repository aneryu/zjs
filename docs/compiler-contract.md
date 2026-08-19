# Compiler identity contract

Status: normative for `src/compiler/` and the v2 emission arms in
`src/parser.zig`. This (the v2 compiler, directory renamed from
`compiler_v2` on 2026-08-19) is the only compiler; the legacy compiler and
its dual-emission gates are deleted. Function and file names are the stable
anchors; line numbers are deliberately not cited because they drift.

## 0. Ruling reframe (binding)

The goal is a **zjs identity-native compiler**, not a QuickJS clone. What
migrates from QuickJS is its **control-flow identity model**:

- the parser binds **no addresses** — a jump is born against a `LabelId` and
  stays a `LabelId` until final layout;
- relocation exists only for real consumers (`RelocEntry` per pending operand,
  chained per label);
- resolve passes are separate (`resolve_variables.zig`, then
  `resolve_labels.zig`), and **byte addresses exist only after final layout**.

What is preserved from zjs: exact-CFG semantics as the auditing oracle,
ownership validation (atom ledger, item-wise release), OOM transactional
discipline (no consumer may observe half-published state), and the
Debug/ReleaseSafe fail-loud oracles. Absolute PC exits the core identity
system; zjs language semantics do not change.

## 1. Identity taxonomy

These are the only identities a v2 producer may create. Every later stage
(S3R exact-CFG liveness, `resolve_labels.zig`) keys off them.

| Identity | Definition | Role |
| --- | --- | --- |
| `LabelId` | `src/compiler/labels.zig` — function-scoped `enum(u32)` creation index | **Jump identity.** The 4-byte operand of every jump-format instruction holds the `LabelId` (little-endian) until final emission. Stable across detach/splice: a moved block keeps its `LabelId`s; only slot offsets rebind. |
| bound label (a `LabelSlot` with `flags.bound`) | `bound_offset` is the temporary-stream position of the bind | **Block boundary.** The bind slot subsumes the in-stream `op.label` pseudo-op of the deleted legacy emitter; it is the exact-CFG node key S3R consumes. `emitterBindLabel` = bind **and** invalidate `last_opcode_pos` (control-flow merge, qjs `emit_label`); `emitterBindLabelRaw` = bind only (provenance-preserving, qjs `emit_label_raw`; used by the optional-chain close). |
| aux label | same `LabelId`, referenced through a `RelocEntry` of kind `.aux32` | The `scope_make_ref` secondary operand (op + atom(4) + label(4) + scope(2)); `Builder.emitScopeRefOpOwned`. The put side **binds** it (qjs `put_lvalue` `emit_label`). |
| `ref_count` | `LabelSlot.ref_count`, bumped on every referencing emission, decremented on rollback/detach/dead-code removal, moved wholesale by `Builder.retargetLabelRefs` | qjs `update_label` bookkeeping retained for the `resolve_labels` short-form pass. Since S3R it is **never a liveness input**: dead-code decisions come from the exact block CFG (see section 5). |
| `backward_target` flag | set when a reference is emitted against an already-bound label (and on splice when the bound target precedes the operand) | Conservative loop marker for short-form bookkeeping. **Never a correctness input**; rollback deliberately does not clear it. |
| source event | `SourceSlot { temp_offset, line, col }` | pc2line identity. Bound to the logical output event order, **not** to a byte pc of any final stream; final emission maps events to output positions (QuickJS shape — no old-PC relocation chain). Markers with `line <= 0 or col <= 0` are dropped at the sink. |
| `last_opcode_pos` | `Builder.last_opcode_pos`, qjs `fd->last_opcode_pos` | The **sole target fact** for speculative-LHS rewinds (`getLValue`) and the straight-line half of liveness. Invalidated (−1) at every merge bind, `truncateTail`, `detachTail`, `spliceSegment`. |

**The byte-PC rule.** Byte offsets of the temporary stream may appear in v2
parser arms only as *stream-editing coordinates*: snapshot lengths,
speculative-LHS tail classification / `truncateTail` positions, the
optional-chain pseudo-getter rewrite (`v2b.code[last_opcode_pos]`), the
switch case-tail scan (`caseTailCanFallthrough`), the class brand-prologue
opcode patch, and liveness/terminal queries (`isLiveCode` and class-init
child close). A byte offset must **never** be written into a jump operand,
and no v2 arm may convert a PC into a target. Relative displacements exist
only inside `resolve_labels.zig` final layout.

**Standing invariants (audited at QCP-1 L4; normative for every future
arm).** No committed v2 arm leaks an absolute PC: every jump operand in the
v2 temp stream holds a `LabelId` (jump32) or aux `LabelId` (aux32), and every
byte-offset use falls under the stream-editing whitelist above. The identity
discipline — every created label ends bound, binds ordered, `ref_count` exact
under rollback/detach/splice/retarget — is the resolve-stage input contract
(section 5) and must not be weakened.

## 2. Builder transactional surface

### 2.1 Snapshot / rollback (`Builder.snapshot` / `Builder.rollback`)

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
`snap.code_len`: a pre-snapshot bind there is indistinguishable from a
post-snapshot one, and a kept bind at the restored position is still valid.
Therefore *sites must take their snapshot BEFORE any boundary bind they may
want rolled back*. All committed snapshot/detach sites comply (§4.5,
§4.20–§4.22): each takes its snapshot before any emission or bind it may
revert. Any future producer that binds first and snapshots at the same
`code_len` is defective by contract.

### 2.2 Tail truncation (`Builder.truncateTail`)

The qjs `fd->byte_code.size = fd->last_opcode_pos` rewind. Legal **only** for
tails carrying no relocations and no binds: the newest reloc's operand is the
high-water mark (operand offsets are emission-ordered) so the no-reloc
requirement is O(1); binds beyond the boundary are a Debug scan. Source
markers with `temp_offset >= new_code_len` are dropped (note `>=`: a marker
exactly at the cut goes away — unlike rollback, which restores markers by
ledger length). Invalidates `last_opcode_pos`.

### 2.3 Detach / splice (`detachTail` / `spliceSegment` / `discardSegment`)

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
`defer discardSegment`.

`retargetLabelRefs(from, to)` moves every pending reference of one label onto
another label's chain (`ref_count` follows), leaving both labels' bind state
alone. References move between *identities*; no operand PC is ever patched.
Its one producer is the switch epilogue (§4.10).

### 2.4 Ownership and OOM

Atom operands enter the builder through owned sinks
(`emitAtomOpOwned`/`emitAtomOpU8Owned`/`emitAtomOpU16Owned`/
`emitScopeRefOpOwned`): the sink consumes the caller's retain even when a
capacity reservation fails. `takeLastAtomOwned` is the reverse transfer used
by the getter rewind. `deinit` releases the initialized ledger prefix then
frees backings by full capacity; uninitialized tails are never read. OOM
anywhere leaves the builder consistent for `deinit`; a failed parse abandons
the whole product, so v2 arms need mid-sequence rollback only where *parser*
state must be restored (the optional-chain label, §4.5).

### 2.5 Parser-facing wrappers

The `emitter*` free functions in `src/parser.zig` map Builder errors into parser
errors and split marker'd vs `NoSource` emission: `emitterJump`/`emitterOp`
etc. add a source event at the current token first; the `NoSource` twins do
not; `emitterOpAt` pins one opcode to an explicit source event (assignment /
update operators); `emitterRetargetLabel` wraps `Builder.retargetLabelRefs`. The
former `v2_available and s.emit_v2` runtime gates and the anti-legacy asserts
in the `appendBytesNoSource` family are gone with the legacy compiler; the
Builder path is the only emission path, and the `appendBytesNoSource` family
survives as the parser-phase append funnel with flow-tail bookkeeping.

## 3. Frame-level identity carriers

Break/continue/labelled-control and finally identities live in parser frames
so that a `break`/`continue`/`return` is *born* as a jump to the right
`LabelId` — no live path appends to an operand-offset fixup list (the F-6 dead
machinery was deleted 2026-08-19 — see §6; the remaining
`break_fixups`/`continue_fixups` lists are guarded by length assertions
that prove no path grows them):

- `pushBreakFrame`: creates the continue label then the break label (qjs
  `push_break_entry` order) into
  `continue_frame_labels`/`break_frame_labels`.
  `pushBreakOnlyFrame`: break label only (switch).
- `patchContinueFrame` binds the top continue label;
  `popBreakFrameAndPatch` pops both and binds the break label;
  `popBreakOnlyFrameAndPatch` likewise. Binds are unconditional even
  at zero refs — *every created label ends bound*; `resolve_labels.zig` drops
  dead ones.
- `LabelFrame.break_label` / `continue_label`: created by
  `pushLabelFrame` (continue label first when allowed); bound unconditionally
  by `patchLabelBreaks`/`patchLabelContinues`.
- `FinallyLabel`: the gosub target identity (tags `temp`/`builder` name
  the stream the label belongs to). The never-assigned
  `BlockEnv.builder_label_finally` twin and its dead consuming arm were
  deleted (F-5, §6).
- `emitResolvedControlJump`: the single place an unlabelled/labelled
  break or continue becomes a `goto` — always against a frame or label-frame
  `LabelId`; fails closed (`Error.UnexpectedToken`) if the depth has no v2
  label.
- Function boundaries: `enterControlBoundary`/`leaveControlBoundary`
  swap the v2 label lists along with the frame bookkeeping, so no frame label
  leaks across a nested function parse.

## 4. Producer inventory

Format per producer: **Identities** (what it creates), **Rollback** (which
snapshot discipline covers it).

**Audit summary.** Every committed arm was audited against its QuickJS
counterpart in the pinned `quickjs.c` at S0.5 and re-verified at QCP-1 L4;
all match, except three deliberate, documented shape deviations that keep
identical resolved output: the classic-`for` top-label bind (§4.8), the
switch default epilogue (§4.10), and `try`'s catch2 creation order (§4.14).
Per-arm `quickjs.c` line citations were dropped from this inventory; the
commit history carries them.

### 4.1 `if` / `else`

- Identities: `if_false_label` (created after the condition, jump
  `if_false`); with `else`: `else_goto_label` (`goto` over the else) and
  the if_false label binds at the else entry; the merge bind closes whichever
  label is open. One wrapper scope for the whole statement (qjs shape).
- Rollback: none needed (no speculation).

### 4.2 conditional `?:` — `parseCondExpr`

- Identities: else label (if_false), end label (goto); binds at else entry
  and merge.

### 4.3 logical `&&` / `||` chains — `parseLogicalAndOr`

- Identities: a **single** end label created before the operand loop; per
  operand `dup ; if_true/if_false → end ; drop`; one bind at the end
  (NoSource emission throughout; qjs single-label lowering for the whole
  chain).

### 4.4 nullish `??` chain — `parseCoalesceExpr`

- Identities: single end label; per operand
  `dup ; is_undefined_or_null ; if_false → end ; drop`; bind at end.

### 4.5 optional chain `?.` — `emitOptionalChainTest` + chain close

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
- Chain close: `emitterBindLabelRaw` (raw bind: the preceding getter stays
  visible as provenance), then the pseudo-getter rewrite
  `get_field → get_field_opt_chain` / `get_array_el → get_array_el_opt_chain`
  by patching `v2b.code[last_opcode_pos]`, else `invalidateLastOpcode`. Byte
  offsets used as stream-editing coordinates only. `resolve_labels.zig`
  lowers the `*_opt_chain` forms at final layout.

### 4.6 `while`

- Identities: top label **bound at the test** (back edge later references a
  bound label → `backward_target`), exit label (`if_false`); frame labels
  from `pushBreakFrame`; continue label bound by `patchContinueFrame` before
  the back edge; `goto` top; bind exit; break label bound by
  `popBreakFrameAndPatch`.

### 4.7 `do`/`while`

- Identities: body label bound at body start; continue frame label bound at
  the test; `if_true` back edge to the bound body label; break frame label
  bound after.

### 4.8 classic `for`

- Identities: top label bound before the test (the bind slot **subsumes**
  legacy's in-stream anonymous `label 0` marker — an intentional, documented
  shape deviation with identical resolved output); empty test emits
  `push_true`; exit label (`if_false`); frame labels; continue labels bound
  before the update splice; `goto` top; bind exit.
- Update clause (detach/splice consumer): Builder snapshot `update_mark`
  taken **before** parsing the update; after the parenthesized parse,
  `detachTail` iff code grew (empty update detaches nothing); the segment is
  spliced after the body and the bound continue labels; a paired
  `defer discardSegment` covers all error paths. `LabelId`s inside the update
  survive the move untouched.
- Boundary caveat: the emission immediately before the mark is the `if_false`
  jump — no bind can sit exactly at the mark from this producer; binds
  emitted inside the update are strictly interior and are captured.

### 4.9 `for-in` / `for-of` / `for await of` — `parseForInOf`

- Identities: expr label (initial `goto` skips the one-pass target block);
  assign label bound at the target block (later a **backward** `if_false`
  re-enters it); body label; next label (continue target for the step
  sequence); frame labels. Sequence:
  `goto expr ; bind assign ; <target> ; goto body ; bind expr ; <iterable> ;
  for_in_start/for_of_start/for_await_of_start ; goto next ; bind body ;
  <body> ; bind cont-frame ; bind next ; for_*_next(+await+
  iterator_get_value_done) ; if_false → assign ; drops/iterator_close ;
  bind break-frame`.
- Control-flow/label order matches qjs `js_parse_for_in_of`, including the
  for-await variant's NoSource `if_false` and post-loop `iterator_close`
  placement; non-declaration identifier targets go through the speculative
  LHS path (§4.19).

### 4.10 `switch`

- Identities: per case a no-match label (`if_false` after
  `dup ; <case expr> ; strict_eq`), bound at the next case's test or
  retargeted in the epilogue; fallthrough labels (`goto` emitted when the
  next clause exists and `caseTailCanFallthrough` holds — qjs always emits
  the fallthrough goto and lets `js_is_live_code` strip dead tails; an
  earlier extra "no switch-break in the body" ref-count conjunct was removed
  because it wrongly suppressed the goto after
  `case 0: if(false) break; y(); case 1:`); an **eager default candidate**
  label created and bound at the default body start (legacy decides
  `default_body_start` after the fact; a v2 bind must happen at the position
  itself — an empty default followed by a case defers and re-creates the
  label at that case's body start; the abandoned candidate stays bound with
  zero refs and is dropped by resolve); the switch break frame label
  (`pushBreakOnlyFrame`, discriminant cleanup drop = 1).
- Epilogue (**deliberate, documented shape deviation**): qjs binds the
  default label backwards with an in-stream patch (the "ugly patch"). v2
  label discipline forbids patching a jump's PC, so the no-match references
  are moved onto the default label's identity with `emitterRetargetLabel`
  (`Builder.retargetLabelRefs`) — the unmatched-dispatch boundary and the
  default body are one program point, so references change *identity*, not
  operand bytes. With no default clause, the no-match labels simply bind at
  the common discriminant drop. An earlier epilogue trampoline
  (`goto SKIP ; NO_MATCH: goto DEFAULT ; SKIP:`) was removed: it materialized
  an instruction pair qjs never emits and perturbed stream probes. Resolved
  semantics identical; identity discipline preserved.
- Liveness twin: `caseTailCanFallthrough` scans the temp stream from the
  body start (v2 streams carry no `line_num`/`label` pseudo-ops), same
  terminator set as `caseCanFallthrough`, plus the incoming-edge rule (a
  referenced label bound at the current end keeps the tail live).
- The no-match label array fails closed on overflow.

### 4.11 `break` / `continue` (incl. labelled)

- Identities: **none created** — the jump is born as the target frame's or
  label frame's `LabelId` through `emitResolvedControlJump`. Cleanup
  (catch-marker drops, iterator_close, crossed-finally
  `undefined ; gosub ; drop`) is emitted by `emitCatchMarkerDropsFromDepth`,
  `emitCrossFrameCleanup`, and `emitControlThroughFinally`.
- The former `*NoFinallyCapture` dead variants were deleted (F-6, §6).

### 4.12 labeled statement

- Identities: `LabelFrame.break_label` (+ `continue_label` when the
  labelled statement is a loop; loops and `switch` receive the pending label
  and create the frame inside their own arm). Other non-loop labelled
  statements bind the break label via `patchLabelBreaks` after the body; a
  labelled-statement `BlockEnv` carries the break target for the finally
  walker. Binds are unconditional (dead labels resolved away).

### 4.13 `throw`

- Identities: none. `op.throw` with the throw-keyword source override.

### 4.14 `try` / `catch` / `finally`

- Identities: `label_catch`, `label_finally`, `label_end` created upfront;
  **`label_catch2` is created at its first use in the catch clause** — a
  deliberate, documented deviation from qjs (which creates all four upfront)
  because v2 discipline requires every created label bound and a no-catch try
  never binds catch2. Ids are per-function creation indices, so resolved
  output is unaffected. `op.catch` is emitted as a jump referencing the
  handler label — the handler target is *born* as a `LabelId`.
- Shape: live try tail `drop ; undefined ; gosub finally ; drop ; goto end`
  (liveness via `isLiveCode`); catch entry binds `label_catch`; optional
  binding or `drop`; `op.catch → label_catch2`; live catch tail as above;
  bind catch2 `; gosub finally ; throw`; finally-only: bind catch `; gosub ;
  throw`; bind finally; shared finally body; `op.ret`; bind end.
- Frames: `pushReturnFinallyFrame` carries `FinallyLabel{ .v2 }` so any
  `return`/`break`/`continue` crossing the frame gosubs the same identity.

### 4.15 `gosub` producers

- Identities: none created; every `gosub` references a `FinallyLabel.v2`.
  Producers: live try/catch tails, catch2 and finally-only rethrows,
  `emitReturnValue` (one gosub per crossed finally frame, qjs emit_return),
  and `emitControlThroughFinally` (per crossed frame:
  `undefined ; gosub ; drop`). The dead-symmetric
  `BlockEnv.builder_label_finally` arm was deleted (F-5, §6).

### 4.16 `return` + function terminals — `emitParsedReturn` / `emitReturnValue` / `emitFunctionReturn`

- Identities: derived-constructor value substitution creates one label
  (`check_ctor_return ; if_false L ; drop ; checked-this ; bind L`);
  terminals `return` / `return_undef` / `return_async` are plain ops.
- Source: `reattributeReturnTailCallSource` returns null under v2 — pc2line
  derives from Builder source slots at final emission (the resolve stage owns
  tail-call attribution); no source-slot surgery on the v2 path.

### 4.17 function terminal / epilogue

- Decision: `needs_return = isLiveCode(s)` alone (qjs
  `js_parse_function_decl2` tail) — every construct epilogue bound its merge
  labels at the end, which invalidated `last_opcode_pos` exactly like qjs
  `OP_label`.
- `isLiveCode`: straight-line half = last opcode not a terminator
  (or `last_opcode_pos < 0` → live); merge half = a **referenced** label
  **bound exactly at the current end** is an incoming edge (twin of legacy
  `max_absolute_target >= tail_start`); unbound labels are future
  handler/exit targets and are **not** edges.
- Tails: async / (async-)generator → `undefined ; return_async`; derived
  ctor → checked-this ; `return`; plain / script → `return_undef`. Arrow
  expression bodies terminate `return_async`/`return`.

### 4.18 `scope_make_ref` (aux-label lvalue) — `getLValue` / `putLValue`

- Identities: one aux `LabelId` per with-scope reference, created in
  `getLValue`, emitted via `emitScopeRefOpOwned`
  (`scope_make_ref` + atom + aux32 label + scope; ref_count bump = qjs
  `update_label(fd, label, 1)`), carried in `LValue.ref_label`.
  `putLValue` frees the descriptor atom then **binds** the aux label before
  the mode shuffle (qjs put_lvalue) — the bind is the provenance boundary.
  Fails closed if the label is missing.
- Reachability: `emit_phase1_temp` defaults to `true` in production
  (`ParseState` and `compiler/test_entry.zig`); only the
  `compiler/tests.zig` harness turns it off. The `scope_get_var` case of
  `getLValue` therefore runs in production, and its `with`-scope branch emits
  `scope_make_ref` with a real aux `LabelId`.

### 4.19 speculative LHS emission — `getLValue`

- Mechanism: `Builder.last_opcode_pos` is the sole target fact (qjs
  `get_lvalue`). Getter removal = ledger take-back (`takeLastAtomOwned`)
  **then** `truncateTail(pos)` — the qjs
  `fd->byte_code.size = fd->last_opcode_pos` rewind. Legal because the getter
  is a single trailing instruction: no relocs, no binds in the tail
  (truncateTail's O(1)/Debug guards enforce it). `keep` re-emits the getter
  via `reemitLValueGetter` with a dup'd atom (get_field2 /
  scope_get_private_field2 / get_array_el3 / to_propkey+dup3+get_super_value
  / get_ref_value). Update/compound operators pin their op to the operator
  source event via `emitterOpAt`. The direct-binding `scope_get_var` form is
  the first case of `getLValue` (with-scope chains upgrade the descriptor to
  `ref_value` plus a `scope_make_ref` aux label, §4.18). An errdefer releases
  the descriptor atom on failure.

### 4.20 detach — `emitterDetachTail` consumers

- Contract: mark snapshot taken at the segment start **before** any emission
  or bind of the segment; empty tail short-circuits (for-update); segment
  paired with `defer discardSegment`; §2.3 boundary rule governs binds at the
  mark (they stay in the main stream — correct: a merge label bound exactly
  where the deferred block begins belongs to the preceding control flow).
  Consumers: the classic-`for` update clause and the class deferred-runtime
  block.

### 4.21 splice — `emitterSpliceSegment` consumers

- Contract: splice after the body/`define_class`+brand prologue; no operand
  rewriting (function-global `LabelId`s); consumed on success; error paths
  covered by the paired `defer discardSegment`. Consumers: the for-update
  move and the class-runtime splice sites (qjs `js_parse_class` / TOK_FOR
  update move).

### 4.22 class constructor discard (speculative rollback)

- Contract: `ctor_snap` taken **before** the constructor's
  `parseClassElementFunction` emission; if the element was the explicit
  constructor, `rollback(ctor_snap)` discards its ordinary fclosure
  expression (the class references the child through push_const/define_class
  instead). The arm comment records the boundary-bind caveat ("no boundary
  bind is pending here"): a pre-existing merge bind exactly at the snapshot
  position is preserved by rollback — correct, it belongs to the preceding
  class element.

### 4.23 class / static block

- Default constructors are synthesized directly through the **child fd's own
  Builder** (`ensureBuilderForFd` per FunctionDef; check_ctor /
  enter_scope / init_ctor emitted on the child builder). `define_class` /
  `define_method` / `perm3`/`swap` static rotations and the deferred-runtime
  splice are emitted arm-by-arm. Static blocks parse as
  `class_static_block` function kind through the same function-body/epilogue
  machinery. The class-side detach/splice and ctor rollback contracts are
  §4.20–§4.22.

### 4.24 async resume / generator resume

The resume group is a single, unconditional emission path — there is no
V2-suffixed twin of any of these functions and no forward-jump patching
anywhere in the group:

- `initial_yield` — emitted in `parseFunction`;
- `yield` expression — the resume split is a real `LabelId` pair;
- `await` unary — plain op emission;
- `yield*` delegation — `emitYieldStarDelegation` is the one implementation,
  a complete `LabelId` twin of the qjs TOK_YIELD delegation machine;
- `using`-await — `emitUsingAwaitIfNeeded` carries a
  `emitterNewLabel`/`emitterJump`/`emitterBindLabel` triple.

No identity kinds beyond section 1 were required.

## 5. Liveness note (S3 → S3R)

`LabelSlot.ref_count` + `flags.backward_target` + `last_opcode_pos` were the
qjs **linear** liveness model that S3 (`resolve_variables.zig`) consumed at
first. Stage S3R (landed) replaced that consumer with zjs's exact-CFG model
keyed on **bound labels as block boundaries** (`src/compiler/cfg.zig`):
block starts are the dedup-sorted bound-label offsets plus stream start/end,
edges are LabelId jump operands collected only before each block's first
unconditional terminal (empty-gosub references excluded), and worklist
reachability from entry decides every dead-code/ownership choice.
`ref_count` remains as qjs `update_label` bookkeeping for the
`resolve_labels.zig` short-form pass and never decides liveness again. A
Debug/ReleaseSafe oracle (`cfg.auditInstructionOwnership`) recomputes
legacy-style instruction-granularity reachability over the temp stream and
panics on any divergence from `block_live && before-terminal` — the
block/byte boundary-normalization equivalence is a proof obligation, not an
assumption. The identity taxonomy above is the S3R input contract and must
not be weakened (in particular: every label bound, binds ordered, ref_count
exact under rollback/detach/splice).

## 6. Findings

The S0.5 audit opened eight findings. Six are closed and folded into the
inventory above: F-1 (generator/async resume, §4.24), F-2 (logical
assignment `&&=`/`||=`/`??=`, now a plain `LabelId` skip-assign lowering in
`emitLogicalAssignLValue`), F-3 (aux-label reachability, §4.18), F-4 (`with`
and module import/export — `parseWith` emits directly; `parseImport` /
`parseExport` reach bytecode only through shared emitters), F-7
(optional-call chains, `prepareCallReference` / `emitPreparedCall`), and F-8
(direct-binding lvalues, §4.19). The mechanical coverage gate that once
guarded against silent legacy emission was retired together with the legacy
compiler; with a single emission path, that failure mode no longer exists.

Both findings were **deleted on 2026-08-19**, landed during the
refactor-policy zoo-gate suspension window: semantic safety rests on this
contract's own ruling plus the full green suite; the layout effect was
measured and recorded (stripped-image identity comparison: `.text` −432 B
from the `BlockEnv` field removal — a QCP-1B-class layout shift accepted
under the suspension, to be re-priced at the next zoo re-baseline):

- **F-5**: the never-assigned `BlockEnv.builder_label_finally` field and
  its dead consuming arm in `emitCrossedControlBlockCleanup` are gone.
- **F-6**: the four `*NoFinallyCapture` break/continue emitters and the
  `emitForwardJump*` / `patchForwardJump` machinery they were the last
  users of are gone. The `break_fixups`/`continue_fixups` lists remain:
  their length assertions are live guards proving no path grows them.
