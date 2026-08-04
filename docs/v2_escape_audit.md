# QCP-1 Phase 5 — the runtime ownership ESCAPE audit

Branch `compiler-v2-qjs`, tip `e385d6db` (the merge that brought main's
ownership-correctness arc onto the branch). This is the gate that must pass
before the legacy pipeline can be **deleted**.

**The criterion is not refcount balance.** Refcount balance was already proved:
the four-ledger phase accounting and the atom audit closed it, and
`docs/v2_builder_lifetime.md` §9-§14 measured every duplicate-ownership interval
to zero at the peak instant. The question this document answers is different:

> 不是 refcount 是否平衡，而是 escape boundary 是否明确 —
> is every point at which **compiler-owned** state escapes into
> **runtime-owned** state EXPLICIT, NAMED, and ENFORCED?

A boundary can have perfectly balanced refcounts and still be unaudited, because
"the counts came out even" is a property of one execution, while "the transfer is
named and enforced" is a property of the code. This audit reads the code.

---

## 0. Method

### 0.1 What counts as an escape

An **escape** is a point where a value that the compiler created, and whose
lifetime the compiler would otherwise end, becomes reachable from state whose
lifetime the runtime controls. Three shapes exist and are distinguished
throughout:

| shape | meaning | who is inert afterwards |
| --- | --- | --- |
| **MOVE** | the sole owner changes hands; the source slot is reset to its null sentinel | the source |
| **COPY** | the destination takes an independent reference/allocation | neither — both own, independently |
| **RETAIN** | the destination adds a reference to an object the source keeps | neither — refcount grows |

Only MOVE creates an inertness obligation. COPY and RETAIN are recorded because
mistaking one for another is exactly how these boundaries break.

### 0.2 EXPLICIT vs IMPLICIT expression

Per the ruling, an escape is **EXPLICIT** when it is expressed as *a named
transfer primitive with a documented contract*, and **IMPLICIT** when it is a
bare field assignment, a pointer copy, or an unstated assumption that the
runtime will keep the value alive.

That test is applied at two granularities, because the answer differs:

* **transaction** — is the boundary itself a named, delimited, documented
  region with a stated atomicity rule?
* **item** — is each individual owner moved through a named primitive?

A boundary can be EXPLICIT as a transaction while its items are paired field
assignments. §2 is exactly that case and says so.

### 0.3 Enforcement taxonomy

Reused verbatim from the P4 scorecard
(`docs/qcp1_architecture_scorecard.md` §1.4) so the two documents are
comparable:

* **COMPILE** — the type system or `comptime` makes the violation unspellable;
* **ASSERT** — a fail-closed check: an all-build `error`, or a
  Debug/ReleaseSafe `std.debug.assert` / `@panic`;
* **ORACLE** — caught by a Debug/ReleaseSafe audit pass, the dual comparator, or
  a gate suite (OOM injection, force-GC);
* **PROSE** — documented only;
* **NOTHING** — implicit; a violation is silent.

Where a boundary carries several independently-violable rules, each is scored
separately and the boundary's headline is the weakest rule that can break the
escape.

### 0.4 Classification

* **EXPLICIT** — the transfer is named, its contract is written down, and at
  least one mechanical tier (COMPILE / ASSERT / ORACLE) catches a violation.
* **IMPLICIT-BUT-SOUND** — the transfer is a field assignment or a convention,
  but soundness is established by enumerating every caller / by a mechanical
  cross-check that makes the failure mode unreachable in production.
* **UNCLEAR** — soundness cannot be established from the code. **Any UNCLEAR is
  a finding that must be resolved before legacy deletion.**

---

## 1. Summary

| # | boundary | what escapes | shape | expression | weakest enforcement | class |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | **FunctionBytecode → runtime** | 1 realm ref, 1 cpool (incl. every child FB), 3 + n + m name atoms, the inline atom-operand ledger, the pc2line buffer, the source text | MOVE (atoms, cpool, pc2line, source), COPY (code bytes), RETAIN (realm) | transaction EXPLICIT, items IMPLICIT (paired field assignments) | ASSERT | **EXPLICIT** |
| 2 | **module persistent** | exactly one object — the module root FB. All module metadata atoms are re-duplicated, not transferred | MOVE (FB), COPY (all atoms) | EXPLICIT (`*NoFail` primitives + `take*` primitives) | COMPILE + ASSERT | **EXPLICIT** |
| 3 | **closure persistent** | 1 FB ref per function object + the capture-cell array | RETAIN (nested, via `constantAt` dup), MOVE (root, via `takeFunctionBytecodeValue`), MOVE (cells) | EXPLICIT (`setFunctionBytecodeValue`, `setFunctionCaptures`, both with consumption contracts) | ASSERT | **EXPLICIT** |
| 4 | **async continuation** | the FB (kept alive by the continuation), plus two compiler-assigned bytecode coordinates that outlive the call: `pc`, `catch_target_pc` | RETAIN (FB), COPY (coordinates) | FB retention EXPLICIT; storage transfer EXPLICIT; **pc↔FB binding IMPLICIT** | ASSERT (after this commit; NOTHING before it) | **IMPLICIT-BUT-SOUND** |
| 5 | **generator continuation** | identical mechanism to #4 | identical | identical | identical | **IMPLICIT-BUT-SOUND** |

**No boundary is UNCLEAR.** One sub-invariant was NOTHING-enforced when this
audit started — the binding between a parked program counter and the
FunctionBytecode it indexes (§5.4) — and this commit closes it with a
three-line null-tolerant Debug assert at the single resume seam, moving it to
ASSERT. Two residual observations that are *not* blockers are recorded in §7.

**v2 vs legacy:** the two backends are indistinguishable at boundaries 1-5. All
five escapes are downstream of the point where the two lowering paths converge
(`src/bytecode.zig:12758`); no escape site branches on the backend. The only
backend-visible difference anywhere near an escape is *which producer was
already made inert before it*, and there **v2 is the more explicit of the two**
(§2.6).

---

## 2. Boundary 1 — FunctionBytecode → runtime

### 2.1 What escapes, from whom, to whom

**FROM** two compiler-side owners:

* `FunctionDef` (`src/bytecode.zig:13484` region) — parse-time, `MemoryAccount`
  owned, destroyed when `Parser.compile` tears the parse state down;
* the lowering carrier `lowered: bytecode_function.Bytecode`, a stack local
  created at `src/bytecode.zig:12721` with `defer lowered.deinit(rt)`.

**TO** the packed GC artifact `FunctionBytecode`, whose lifetime the runtime's
collector controls from `src/bytecode.zig:12887` onward.

| # | what | shape | site |
| --- | --- | --- | --- |
| a | executable code bytes | **COPY** — `@memcpy(byte_code, lowered.code)`; the carrier keeps and frees its own buffer | `src/bytecode.zig:12806` |
| b | inline atom-operand refs | **MOVE** — the code bytes become the authoritative owner ledger and the carrier's parallel ledger is blanked in place so `lowered.deinit` cannot release them | `src/bytecode.zig:12860` |
| c | `func_name` | **MOVE** | `src/bytecode.zig:12831-12832` |
| d | `filename` | **MOVE** into the debug tail | `src/bytecode.zig:12833-12834` |
| e | `script_or_module` | **MOVE** into the hot extension | `src/bytecode.zig:12835-12836` |
| f | every arg/var `var_name` (n = `args.len + vars.len`) | **MOVE**, one row at a time | `src/bytecode.zig:12838-12845` |
| g | every closure row `var_name` (m = `closure_var.len`) | **MOVE** | `src/bytecode.zig:12846-12849` |
| h | the whole cpool, **including every child FunctionBytecode value** | **MOVE**; sources set to `undefined`, `fd.cpool_count = 0` | `src/bytecode.zig:12851-12855` |
| i | pc2line buffer | **MOVE** — pointer + length, carrier's `owns_pc2line_buf` cleared | `src/bytecode.zig:12862-12866` |
| j | source text | **MOVE** — raw `[*:0]const u8` + length, `fd.source_text = null` | `src/bytecode.zig:12868-12872` |
| k | realm | **RETAIN** — `fb.realm = @TypeOf(fb.realm).retain(compile_context.realm)` | `src/bytecode.zig:12829` |

Row (j) is the only escape in the whole audit expressed as a **raw pointer
copy**. It is sound because the free side is symmetric: `FunctionDef.deinit`
frees `source.ptr[0 .. source.len + 1]` (`src/bytecode.zig:3629`) and the FB's
owner release frees `src_ptr[0 .. logical_len + 1]`
(`src/bytecode.zig:2470-2476`). The sentinel byte is part of the transferred
allocation on both sides. Nothing but the paired arithmetic enforces that; it is
recorded in §7.2.

Row (h) is what makes the whole compiled tree escape as one artifact: a child's
FunctionBytecode value is installed into its parent's cpool by
`installChildFunctionBytecodes` (`src/bytecode.zig:13174`) *before* the parent
reaches its own commit, so the tree escapes bottom-up and the root FB
transitively owns every node.

### 2.2 Where the transfer is expressed

The escape is a **single delimited region**:

```
src/bytecode.zig:12808   // --- No-fail owner commit. No `try` or allocation is allowed below. ---
   ...
src/bytecode.zig:12886   shell_owned = false;
src/bytecode.zig:12887   rt.gc.addInitializedWithSizeNoFail(&fb.header, fb.heapByteSizeWithLayout(layout));
```

`:12886` is the point after which the raw FB allocation is no longer the
function's to free; `:12887` is the **publication seam** — the instant the
artifact becomes a GC-registered, runtime-owned object.

* As a **transaction** this is **EXPLICIT**: the region is named, its atomicity
  rule is written into the source, every fallible step (layout preflight
  `:12766`, shell allocation `:12777`, all four validators) is hoisted above it,
  and the failure path before it is a single `errdefer` that frees the raw
  allocation without touching any FunctionDef owner (`:12780`, with the
  reasoning spelled out at `:12784-12787`).
* As **items** it is **IMPLICIT**: each owner moves by a pair of field
  assignments (`fb.func_name = fd.func_name; fd.func_name = atom.null_atom;`).
  There is no `Owned(T)` / move-only wrapper, no `take*` primitive, and no type
  that becomes unusable after transfer. The parser has a `*Owned` return
  convention (`moduleImportNameAtomOwned`, `src/parser.zig:20523`) and the v2
  lowering has named transfer primitives (§2.6); this boundary has neither.

That split is the honest answer for boundary 1: **the boundary is explicit, the
individual moves are not.**

### 2.3 What enforces it

| rule | tier | site |
| --- | --- | --- |
| the runtime that owns the FunctionDef's buffers/atoms is the runtime that will account for and destroy the FB | **ASSERT** (all-build `error`) | `validateRuntimeIdentity`, `src/bytecode.zig:12575` |
| arg/var/defined-arg counts fit the u16 fields the passes publish into | **ASSERT** | `validatePreLoweringArtifactShape`, `:12582` |
| final counts agree with the slices, and nothing overflows the packed layout | **ASSERT** | `validateFinalArtifactShape`, `:12594` |
| **the moved atom refs are exactly the atoms encoded in the code stream, in order** | **ASSERT** | `validateFinalAtomOwners`, `:12664` — the doc comment states why a count-only check is not enough: "a count-only check could free unrelated atoms" |
| every var-ref operand indexes inside the closure table that is about to be published | **ASSERT** | `validateVarRefOperandBounds`, `:12634` |
| an empty code stream never escapes | **ASSERT** | `:12765` |
| the packed layout is computable before the first artifact allocation | **ASSERT** | `FunctionLayout.init`, `:12766` |
| the v2 producer is already inert when the escape begins | **ASSERT** (Debug/ReleaseSafe) | `std.debug.assert(fd.v2_builder == null)`, `:12744` |
| the header is fresh, unmarked, unpinned and unaccounted at publication | **ASSERT** (Debug/ReleaseSafe) | `Registry.addInitializedWithSizeNoFail`, `src/core/gc.zig:1318-1326` |
| **"no `try` or allocation below this line"** | **PROSE**, backed by **ORACLE** | the comment at `:12808`; the OOM-injection suite (`zig build test-oom`) drives every allocation site to failure, so an allocating `try` inside the region is caught — a *non-allocating* fallible call would not be |
| the published product is the same on both backends | **ORACLE** | dual comparator, `src/compiler_v2/compare.zig` |

COMPILE: **0**. NOTHING: **0**.

### 2.4 The inertness obligation, and how it is now tested

Ten of the eleven rows are MOVEs, so `FunctionDef` must be inert with respect to
all of them the instant the region ends. Before this commit that was asserted
only by prose plus the shape of the code. It is now pinned by a test:

`compiler_v2.p5: FunctionDef owners are inert after the FunctionBytecode escape`
(`src/compiler_v2/tests.zig`) walks the whole FunctionDef tree after
`createFunctionBytecode` returns and requires, for every node: `v2_builder ==
null`, `func_name == null_atom`, `filename == null_atom`, `script_or_module ==
null_atom`, `source_text == null`, every arg / var / closure-row `var_name ==
null_atom`, every cpool slot `undefined`, `cpool_count == 0`. It then checks the
receiving side — the published FB's names still resolve in the atom table and
its cpool holds the child artifact — so the test cannot be satisfied by a
compiler that simply drops the owners. It runs on **all three** builds
(`legacy`, `v2`, `dual`), which makes it the mechanical statement of "v2 and
legacy do not differ at this boundary".

`compiler_v2.p5: escaped atoms outlive compiler teardown` pins the other half:
an atom used only by the compiled code is interned, its refcount recorded, the
program compiled, and then **the entire compiler is torn down while the FB is
still alive** (parse state, lexer, root carrier). The refcount must be unchanged
by that teardown, and must return to exactly its baseline when the FB — and only
the FB — is released. That is the executable form of "the runtime-reachable atom
outlives compiler teardown, and the FB is its sole owner".

### 2.5 What is *not* transferred, and why that matters

`fd.args`, `fd.vars`, `fd.scopes`, `fd.global_vars`, `fd.child_list` and the
FunctionDef's own growable buffers are **not** escaped. The vardef *rows* are
copied by value into FAM storage (`:12788-12804`) with `var_name` deliberately
initialised to `null_atom` *before* the commit region, so an allocation failure
above the region frees the single raw FB allocation without touching a single
atom owner. This "owner-free FAM storage first, owners last" ordering is stated
at `:12784-12787` and is the reason the boundary can be no-fail at all.

### 2.6 v2 vs legacy at this boundary

**The escape itself is byte-identical.** The backend fork is at
`src/bytecode.zig:12731-12756`, entirely above the escape; both arms converge at
`:12758` and every line from there down is shared. Nothing in the commit region
reads `compiler_v2_available` or `fd.v2_builder`.

The difference is *upstream*, in how each backend makes its own producer inert:

| | legacy | v2 |
| --- | --- | --- |
| producer | `fd.byte_code`, `fd.atom_operands`, `fd.source_loc_slots` | `fd.v2_builder` (a `Builder` with five backings) |
| how it becomes inert | `lowerLegacyPhase1` **moves** the three buffers into the carrier and nulls the FunctionDef fields — six inline field assignments plus a comment (`src/bytecode.zig:12685-12712`) | `releaseConsumedBuilder` — a **named function with a documented contract** ("RELEASE AT THE CONSUMPTION POINT … the producer becomes inert here: its slice fields reset to empty, capacity 0, backings freed, and the FunctionDef no longer names it"), `src/compiler_v2/root.zig:97-113` |
| enforcement of inertness | none beyond the assignments | `std.debug.assert(consumed.code_capacity == 0 and …)` over all five backings (`root.zig:108-109`) **plus** `std.debug.assert(fd.v2_builder == null)` re-checked at the call site (`src/bytecode.zig:12744`) |
| downstream transfer primitives | `installCode` / `installAtomOperands` | `installCodeWithCapacity` / `installAtomOperandsWithCapacity` / `installSourceLocsNoFail`, driven from one `commit` documented as the "Sole ownership-transfer point … allocation-free and infallible, so no observable half-install can escape by construction" (`src/compiler_v2/resolve_labels.zig:2777-2803`) |

**v2 is more explicit.** Legacy's producer inertness is a pattern; v2's is a
named primitive with an assertion. Deleting legacy therefore *removes* the less
explicit of the two producer-release shapes and leaves the more explicit one.

One consequence is worth stating precisely, because writing the §2.4 tests
surfaced it: the two backends leave *different residue* on the FunctionDef, and
on both backends that residue is disjoint from the escape.

* Legacy's phase-1 atom ledger `fd.atom_operands` is **moved** into the carrier
  (`src/bytecode.zig:12699-12702`) and therefore ends up owned by the published
  FB. The FunctionDef holds nothing afterwards.
* v2 never emits through that ledger — with the L3 gate at zero legacy
  emissions in v2 scope, a production v2 parse leaves it empty — so the v2 arm
  has nothing to move and simply does not touch it. `FunctionDef.deinit`
  (`src/bytecode.zig:3597`) releases whatever is there, which in production is
  nothing.
* Under the **test bridge** (`attachTranslatedBuilderTree`, which translates a
  legacy phase-1 stream into a v2 Builder for the v2/dual test builds) the
  original ledger *is* populated and *is* duplicated into the Builder, so the
  same probe atom is momentarily held twice: once by the FB and once by the
  FunctionDef's untouched scratch. That is a property of the harness, not of the
  pipeline, and the test states the difference explicitly rather than relaxing
  its assertion.

Because the two sets are disjoint on both backends — no atom ref is reachable
from both the FB and a live FunctionDef — `compiler_v2.p5: escaped atoms outlive
compiler teardown` can assert **exact** refcount arithmetic instead of an
inequality, and does: after full compiler teardown the probe's count is exactly
the FB's share, and after the FB is released it is exactly the baseline.

---

## 3. Boundary 2 — module persistent

### 3.1 The finding that shapes this boundary

**Exactly one object escapes into the persistent module registry: the module
root FunctionBytecode.** Every atom in the module metadata — request
specifiers, import names, local names, export names, indirect-export names,
star-export names, import-attribute keys and values — is **re-duplicated** into
runtime-owned storage and the compiler-side record is destroyed immediately.
There is no borrowed atom, no shared slice and no aliasing between
`bytecode.module.Record` and `core.module.ModuleRecord`.

That is visible in one function: `pendingDefinitionFromArtifact`
(`src/exec/module.zig:95`) opens with

```
var parsed = artifact.record;
defer parsed.deinit();                                       // :102-103
```

and every metadata item is re-added through `PendingDefinition.add*`, each of
which begins with `self.atoms.dup(...)` under an `errdefer self.atoms.free(...)`
(`src/core/module.zig:225-317`). So the compiler-side record's atoms are
released by `parsed.deinit()` on **every** path, success or failure, and the
runtime's copies are independent.

### 3.2 The four hops

| hop | from → to | shape | site | expression |
| --- | --- | --- | --- | --- |
| 2a | `Bytecode.module_record` → the compile `Result` | MOVE | `src/parser.zig:21327-21332` (normal), `:21482-21487` (dual) — `function.module_record = null` immediately after the read | field assignment, but into a **tagged union** (`RootArtifactImpl`, `:20973`) whose `.module` variant owns FB and record together and whose `deinit` releases both (`ModuleArtifactImpl.deinit`, `:20964`) |
| 2b | `Result` → caller | MOVE | `takeModuleArtifact`, `src/parser.zig:21108` | **EXPLICIT** — named primitive, contract in the doc comment: "Move the canonical module root and its record out together. The Result becomes empty before returning, preventing either owner from being released twice." |
| 2c | `ModuleArtifact` → `PendingDefinition` | MOVE (FB) + COPY (all atoms) | `pendingDefinitionFromArtifact`, `src/exec/module.zig:95`; FB handed over by `pending.adoptFuncObjectValueNoFail(...)` at `:106` | **EXPLICIT** — `adoptFuncObjectValueNoFail` / `takeFuncObjectValueNoFail` (`src/core/module.zig:326`, `:332`) are named, no-fail, and paired |
| 2d | `PendingDefinition` → registry-linked `ModuleRecord` | MOVE (whole definition) | `Registry.prepareFreshTarget`, `src/core/module.zig:841` → `ModuleRecord.replaceDefinitionNoFail`, `:420` → GC publication `:857` → list linkage `:858` | **EXPLICIT** — the contract is in the doc comment at `:836-840`: "Allocation is the only fallible step. After it succeeds, definition transfer, GC publication, and list linkage are all no-fail, so OOM cannot leave a partial record or perturb an existing generation." |

A fifth hop is internal to the runtime but completes the picture: at link time
the record's single `func_obj` slot changes *type* from FunctionBytecode to
module function object — `takeFuncObjectValueNoFail` then
`adoptFuncObjectValueNoFail(object.value())` then
`setFunctionBytecodeValue(..., owned_bytecode) catch unreachable`
(`src/exec/module.zig:401-404`). The polymorphism is documented on the field
itself: "Owns either the compiled FunctionBytecode value or the resulting module
function object. Core never decodes the active JSValue variant."
(`src/core/module.zig:373-375`).

### 3.3 What enforces it

| rule | tier | site |
| --- | --- | --- |
| the module record and the FunctionDef share one MemoryAccount and one AtomTable | **ASSERT** (all-build `error`) | `createModuleFunctionBytecode`, `src/bytecode.zig:12571` |
| **every import/export `var_idx` indexes the published FB's closure table, names the same atom, and has the expected closure type** | **ASSERT** (all-build `error`) | `src/exec/module.zig:112-126` — this is the cross-artifact check that makes the escaped metadata indices meaningful; without it a module record could name a closure slot that does not exist |
| every request index used by an import / indirect export / star export / attribute is in range | **ASSERT** | `requestName`, `src/exec/module.zig:784`, called on every entry at `:113`, `:127`, `:129`, `:132` |
| a star export's name is exactly `*` | **ASSERT** | `src/exec/module.zig:130` |
| the resolved-request vector length matches the parsed request count | **ASSERT** | `src/exec/module.zig:134` |
| the target record is fresh, unpublished, empty in all six metadata slices, and has no func_obj / module_ns, before a definition is installed | **ASSERT** (Debug/ReleaseSafe, 12 of them) | `replaceDefinitionNoFail`, `src/core/module.zig:421-434` |
| a published generation is never replaced (it would invalidate MODULE_NS AUTOINIT opaque pointers) | **COMPILE** + ASSERT | only `prepareFreshTarget` can reach `replaceDefinitionNoFail`, and it is called only on a record it just created; the `PreparedTarget` union (`:723`) makes "was `pending` consumed?" a **tag** rather than a convention, with the rule in its doc comment |
| the module root FB is a module and belongs to this realm | **ASSERT** | `src/exec/module.zig:110`, `:396`; `moduleFunctionBytecode` re-checks `isModule()` at `:304` |
| linking never observes a provisionally-published record | **ASSERT** | `requests_resolved` + `requestsResolved()` guards, `src/core/module.zig:365-367`, `src/exec/module.zig:744` |

COMPILE: **2** (`RootArtifactImpl`, `PreparedTarget`). NOTHING: **0**.

### 3.4 v2 vs legacy

**No difference.** `createModuleFunctionBytecode` (`src/bytecode.zig:12563`) is
shared, and it reaches the same `createFunctionBytecodeAfterChildren` as every
other root. The dual-compile path (`src/parser.zig:21482-21487`) performs the
identical move as the single-backend path (`:21327-21332`). No module code reads
`compiler_v2_available`.

---

## 4. Boundary 3 — closure persistent

### 4.1 What escapes

Two things become reachable from a persistent function object:

* **one FunctionBytecode reference**, stored in
  `Object.u.bytecode_function.function_bytecode`;
* **the capture-cell array** — `closureVarCount()` `*VarRef` pointers, each an
  owned cell reference, stored in `Object.u.bytecode_function.var_refs`.

The FB reference arrives by two different shapes depending on which function
object is being built:

| case | shape | site |
| --- | --- | --- |
| nested function (`OP_fclosure`) | **RETAIN** — `fb.constantAt(index)` returns `values[index].dup()`, so the parent's cpool keeps its own reference and the closure gets an independent one | `src/bytecode.zig:2025-2029`, reached from `pushFunctionClosure`, `src/exec/array_ops.zig:173` |
| script / eval root | **MOVE** — the compile `Result` gives up its sole reference | `takeFunctionBytecodeValue`, `src/parser.zig:21015`, consumed at `src/exec/eval_entry.zig:136`, `src/exec/eval_ops.zig:499`, `src/exec/call.zig:3188`, `src/exec/call_runtime.zig:3227`, `:5249` |
| module root | **MOVE**, inside the record | `src/exec/module.zig:400-403` (§3.2) |

### 4.2 Where the transfer is expressed — EXPLICIT at item level

Unlike boundary 1, every item here moves through a **named primitive with a
written consumption contract**:

* `Result.takeFunctionBytecodeValue` (`src/parser.zig:21015`) — "Move the sole
  canonical ordinary root artifact out of this result. The returned
  FunctionBytecode value is owned by the caller and the Result becomes empty, so
  `deinit` cannot release a second reference. This is the producer-side
  ownership transfer consumed by root js_closure2."
* `Object.setFunctionBytecodeValue` (`src/core/object.zig:6001`) — "`next_value`
  is owned and **consumed on both success and failure**. … attachment is a
  no-allocation pointer publication just like qjs `js_closure2`'s
  `p->u.func.function_bytecode = b` transfer." The `errdefer next_value.free(rt)`
  at `:6006` is what makes the "consumed on failure" half true.
* `Object.setFunctionCaptures` (`src/core/object.zig:6319`) — "Replace the
  closure-captures slice, releasing the previous cells — the cell-typed
  `setValueSlice` (ownership of `next_cells` transfers)."

The capture array is built in `attachFunctionCaptures`
(`src/exec/object_ops.zig:454-492`) with a three-part discipline that is worth
recording because it is the shape the other boundaries lack: a
`captures_transferred` flag drives two independent `errdefer`s (`:465`, `:471`)
so a failure part-way through the fill frees exactly the cells already created
and nothing else; the partially-filled array is published to the GC through a
`CellSliceRoot` (`:466-469`) so a collection triggered by cell creation traces
it; and the transfer is one call at the end (`:491-492`). The commentary at
`:449-453` states the invariant ("No function property or side adapter is
published across this transaction") and `:535-538` states why properties are
installed only afterwards.

### 4.3 What enforces it

| rule | tier | site |
| --- | --- | --- |
| only a **finalized, non-empty, extension-carrying** artifact may become a callable | **ASSERT** (all-build `error`) | `src/exec/object_ops.zig:520` |
| the FB's realm is this context and this global | **ASSERT** | `src/exec/object_ops.zig:522` |
| **the capture array length equals the compiler's closure-table length** | **ASSERT** (Debug/ReleaseSafe) | `setFunctionCaptures`, `src/core/object.zig:6322-6323` — the cross-check binding the runtime capture array to compiler metadata |
| the value being attached is really a FunctionBytecode header | **ASSERT** (all-build `error` + Debug assert) | `src/core/object.zig:6007-6009` |
| the object is a bytecode-function class | **ASSERT** (Debug) | `src/core/object.zig:6008` |
| every root GLOBAL_DECL is validated before a single cell is created | **ASSERT** | `validateGlobalVarDeclarations`, called at `src/exec/object_ops.zig:478` and `src/exec/zjs_vm.zig:537` |
| every var-ref operand the closure will execute is inside the capture table | **ASSERT** | `validateVarRefOperandBounds` at the FB escape, `src/bytecode.zig:12634` — the guarantee the interpreter's unchecked `var_refs[idx]` reads depend on, documented at `:12621-12633` |
| partial capture arrays never leak or double-free under allocation failure | **ORACLE** | `zig build test-oom` |
| the FB survives collection while only the closure references it | **ORACLE** | force-GC gate |

COMPILE: **0**. NOTHING: **0**.

### 4.4 v2 vs legacy

**No difference.** Nothing in `object_ops.zig` or `core/object.zig` reads the
backend. The compiler-side input this boundary consumes — the closure-var table
— is produced by `resolve_variables` on both sides and is cross-validated at the
FB escape by `validateVarRefOperandBounds`, and in dual mode compared row by row
by the comparator (`src/compiler_v2/compare.zig:680` and the closure-source
ledger `closure_sources_threaded`, `src/compiler_v2/root.zig:88`).

---

## 5. Boundaries 4 and 5 — async continuation and generator continuation

These are **one mechanism**. An ordinary `async function` call creates the same
`GeneratorExecutionState` on the same generator-class payload as a `function*`
call: `qjsAsyncFunctionStart` (`src/exec/promise_ops.zig:3431`) calls
`createGeneratorObject` (`src/exec/object_ops.zig:2251`) at `:3447`, exactly as
the generator path does at `src/exec/call_runtime.zig:5624`. They differ only in
the driver — a promise job versus `.next()` / `.return()` / `.throw()`. Module
top-level await reuses the same payload again
(`src/exec/module.zig:762-772`). They are therefore audited together, and the
classification applies to all three.

### 5.1 What escapes

| # | what | shape | from → to |
| --- | --- | --- | --- |
| i | **the FunctionBytecode** | RETAIN | the call's `current_function` → `GeneratorExecutionState.current_function` (`src/core/object.zig:1221`) |
| ii | **the parked program counter** — a compiler-assigned offset into that FB | COPY (scalar) | `Frame.pc` → `SuspendedExecutionState.pc` (`src/core/object.zig:1117`) |
| iii | **the parked catch target** — a compiler-computed exception-handler offset | COPY (scalar) | live catch state → `SuspendedExecutionState.catch_target_pc` (`src/core/object.zig:1123`) |
| iv | the frame windows (operand stack, locals, args, var-refs, open var-refs) | MOVE, or resident-alias | live `Frame`/`Stack` → `SuspendedExecutionStorage` (`src/core/object.zig:1051`) |

(iv) is runtime state, but its *dimensions* are compiler metadata
(`fb.stack_size`, `var_count`, `openVarRefCount()`), which is why the
resume seam cross-checks them (§5.3).

(ii) and (iii) are the interesting ones for this audit: they are the only
compiler outputs in the entire system that are **stored, outlive the call that
produced them, and are later used to index into bytecode**. Everything else the
compiler produces is either consumed immediately or embedded in the artifact it
belongs to.

### 5.2 Where the transfer is expressed

**Park** — `parkGeneratorExecutionState` (`src/exec/vm_gen_async.zig:87`), reached
from `saveGeneratorExecutionState` (`:181`), the single documented seam
("Keep the ownership handoff as one cold-ish seam. Every yield/await opcode
reaches this helper", `:178-180`):

* resident fast path — `state.pc = pc; state.catch_target_pc = catch_target_pc;`
  (`:121-122`) followed by `clearLiveExecutionViews` (`:66`), which is a named
  function whose whole job is making the live views inert;
* general path — `state.replaceStorageOwned(pc, catch_target_pc, &replacement, rt)`
  (`:163`), a **named primitive with a documented publication order**
  (`src/core/object.zig:1178-1180`: "Publish replacement storage and pc before
  destroying the old buffers; cleanup-time GC therefore observes the new
  authoritative state").

The two-bit ownership discriminator `running_aliases` / `resident_storage_owner`
(`src/core/object.zig:1129-1136`) is itself an explicit, documented ownership
model with named transitions `beginRunningAliases` / `finishRunningAliases`
(`:1157`, `:1164`) — this is the most carefully expressed ownership state
machine in the audit.

**FB retention** — `object.setGeneratorCurrentFunction(ctx.runtime, saved_current.dup())`
(`src/exec/object_ops.zig:2351`), preceded by the statement of intent at
`:2348-2350`: "This is the complete realm provenance for generator/async
resumption: normal calls save the closure object, while internal calls save the
raw FunctionBytecode. **Both own the FB that owns its RealmContext.**" Release is
symmetric in `GeneratorPayload.destroy` (`src/core/object.zig:1385`).

**Resume** — `resumeExecutionStateRaw` (`src/exec/vm_gen_async.zig:265`):
`const resume_pc = state.pc;` (`:301`) … `frame.pc = resume_pc;` (`:331`).

### 5.3 What enforces it

| rule | tier | site |
| --- | --- | --- |
| the FB outlives every suspension | **ASSERT** (refcount, all-build) + **ORACLE** (force-GC) | owned `.dup()` at `src/exec/object_ops.zig:2351`; released at `src/core/object.zig:1385` |
| a catch target that does not fit u32 never parks | **ASSERT** (all-build `error`) | `std.math.cast(u32, target) orelse return error.InvalidBytecode`, `src/exec/vm_gen_async.zig:200-203` |
| `maxInt(u32)` is the *only* null sentinel for a catch target, and resume restores it rather than re-deriving it from `pc` | **PROSE** + ASSERT | documented at `src/core/object.zig:1119-1123` ("A shared finalizer PC has multiple possible incoming catch states, so resume must restore this scalar instead of inferring it from `pc`"); `catchTarget()` `:1173` |
| "a resident frame exists" is a separate fact from "pc is nonzero" | **COMPILE**-adjacent | the dedicated `has_frame` bool with its rationale at `src/core/object.zig:1124-1127` |
| a generator frame never runs on a borrowed VM stack-arena window | **ASSERT** (Debug) | `src/exec/vm_gen_async.zig:193`, restated at `:289` |
| frame storage / var-refs are owned (or provably empty) at park | **ASSERT** (Debug) | `src/exec/vm_gen_async.zig:194-196` |
| **the parked frame's open-var-ref window matches the resuming FB's `openVarRefCount()`** | **ASSERT** (all-build `error`) | park `src/exec/vm_gen_async.zig:197`; resume `:334` |
| **the FB passed to resume is the FB the continuation retains** | **ASSERT** (Debug/ReleaseSafe) — *added by this commit* | `src/exec/vm_gen_async.zig`, in `resumeExecutionStateRaw`; see §5.4 |
| both backends agree on every escaping pc / catch target | **ORACLE** (dual only) | the comparator's jump-target model, `src/compiler_v2/compare.zig:978-987`, `:1136-1177` |

### 5.4 The one boundary that was not enforced, and the one-line fix

`SuspendedExecutionState.pc` is a bare `usize` and `catch_target_pc` a bare
`u32`. Neither carries a provenance token naming the FunctionBytecode it
indexes. At the resume seam the FB and the continuation arrive as **two
independent parameters**:

```
src/exec/zjs_vm.zig:635
  const resume_state = try gen_async_vm.resumeExecutionState(
      ctx, entry_stack, entry_function, &frame_storage, entry_generator_state, resume_value);
```

and `entry_function` / `entry_generator_state` are separate fields of `CallEnv`.
`resumeExecutionStateRaw` then installs the parked offset directly —
`frame.pc = resume_pc` (`:331`) — with **no bounds or identity check**. The
arithmetic at `:306-310` that mentions `resume_pc <= function.byteCode().len` is
a *feature detect* for the two-slot yield resume protocol, not a guard: an
out-of-range `resume_pc` merely makes `resume_needs_branch_false` false and is
then installed anyway.

Nothing in the type system, and nothing at the seam, said that `entry_function`
must be the FB reachable from `entry_generator_state`. The invariant held only
because every production caller derives it that way. That enumeration is the
soundness argument, and it is complete:

| resume entry | how the FB is obtained |
| --- | --- |
| `qjsGeneratorNext` | `generatorFunctionBytecodeFromExecution(object, execution)`, `src/exec/call_runtime.zig:5798` |
| `qjsSyncGeneratorStep` | same helper, `:5873` |
| `qjsGeneratorReturn` | `object.generatorFunctionBytecode()`, `:5941` |
| generator `throw` | `generatorFunctionBytecodeFromExecution`, `:6012` |
| the for-of / iterator fast paths | `object.generatorFunctionBytecode()`, `:6057`, `:6250`, `:6282` |
| async-generator body driver | `gen.generatorFunctionBytecode()`, `src/exec/async_generator.zig:278` |
| async-function driver | `continuation.generatorFunctionBytecode()`, `src/exec/promise_ops.zig:3485` |
| module top-level await | `moduleFunctionBytecode(record)`, `src/exec/module.zig:746` — the module continuation object never has a `current_function`, so its execution state carries `undefined` there |

Eight sites, all deriving the FB from the continuation (or, for modules, from
the record that owns the same function object). The boundary was therefore
**IMPLICIT-BUT-SOUND**, not UNCLEAR — but its enforcement tier was **NOTHING**,
the only NOTHING in this audit.

Because the fix is one statement and obviously correct, it is taken here: a
null-tolerant Debug/ReleaseSafe assert at the single resume seam requiring that,
whenever the continuation *has* a derivable FunctionBytecode, it is the one being
resumed. It is null-tolerant precisely so the module-continuation case
(no `current_function`) and the self-referential internal-fixture case
(`current_object == self`, `src/core/object.zig:6044`) stay legal. The
invariant moves **NOTHING → ASSERT**, and the whole audit is left with no
NOTHING-tier rule.

### 5.5 What is *not* an escape here

The frame windows (iv) look like the biggest transfer at this boundary, but they
are runtime-created and runtime-owned throughout; the compiler contributes only
their dimensions. The FAM-resident case does not even change owner — the
execution-state allocation keeps the backing and lends borrowed views, which is
what `resident_storage_owner` records (`src/core/object.zig:1134-1136`) and
what makes `parkGeneratorExecutionState`'s fast path a pure scalar update
(`:110-133`). This is a *runtime→runtime* boundary and is out of scope for a
compiler-ownership audit; it is described only because the pc rides in the same
record.

### 5.6 v2 vs legacy

**No difference in mechanism**, and the mechanism is entirely downstream of the
FB escape: nothing in `vm_gen_async.zig`, `async_generator.zig` or
`promise_ops.zig` reads the backend.

The *values* that escape do depend on the backend — the pc of every yield/await
and every catch target is chosen by the lowering pipeline. Their equality across
backends is not assumed: in dual mode the comparator normalises jump targets to
`target_pc` → `target_ordinal` (`src/compiler_v2/compare.zig:978-987`,
`:1136-1177`) and compares the continuation product in
`(kind, ordinal, target ordinal)` coordinates, so a backend that parked its
generators at different offsets would fail the comparator before it could fail
at runtime.

### 5.7 The test that pins it

`generator continuation keeps its FunctionBytecode alive after every source
binding is dropped` (`src/tests/exec.zig`) suspends a generator at its first
`yield` and an async function at its `await`, assigns `undefined` over **every**
source-level binding to both functions, forces a collection through `$262.gc()`,
and then resumes the generator and requires the correct value. It then drains
the job queue and requires the async function to have settled with its own
correct value, so both continuation kinds — §4 and §5 — are covered by one
fixture. If a continuation did not itself own the FunctionBytecode — if it
relied on the source binding, the cpool, or the caller's frame to keep it alive
— the resume would read freed bytecode. This is the executable form of
escape (i), and it also exercises the new §5.4 assert on every resume it
performs.

---

## 6. The escape map, end to end

```
  parse                     lower                    escape                    persist
  ─────                     ─────                    ──────                    ───────
  FunctionDef ─┬─ v2 Builder ──► ResolvedProduct ──► lowered carrier ─┐
               │   (released at    (released at        (released by   │
               │    consumption,    consumption,        defer)        │
               │    root.zig:104)   resolve_labels.zig:462)           │
               │                                                      ├──► FunctionBytecode ──► GC registry
               └─ legacy phase-1 buffers ──► lowered carrier ─────────┘        [§2]              (bytecode.zig:12887)
                    (moved, bytecode.zig:12694-12712)                            │
                                                                                 ├──► Object.function_bytecode  [§4]
  Bytecode.module_record ──► Result.artifact.module ──► PendingDefinition ──►    │    + capture cells
      (parser.zig:21328)        (takeModuleArtifact)      (atoms re-duped)       │
                                                              │                  ├──► GeneratorExecutionState   [§5]
                                                              └──► ModuleRecord ─┘    .current_function (RETAIN)
                                                                   [§3]               .pc / .catch_target_pc (COPY)
```

Read from the artifact's point of view there is exactly **one** escape into the
runtime — `src/bytecode.zig:12887` — and three persistence structures that
subsequently take references to that artifact (module record, function object,
continuation record). Boundaries 2-5 are therefore *re-homing* boundaries, and
the reason they are cheap to audit is that only the FunctionBytecode crosses
them; the module metadata is copied and the continuation coordinates are
scalars.

---

## 7. Findings

### 7.1 Resolved in this commit

**F1 — the parked program counter had no binding to the FunctionBytecode it
indexes.** §5.4. Enforcement was NOTHING; soundness rested on an unwritten
calling convention across eight call sites. Closed here by a null-tolerant
Debug/ReleaseSafe assert at the single resume seam (NOTHING → ASSERT). This was
the only NOTHING-tier rule in the audit.

### 7.2 Recorded, not blocking

**F2 — boundary 1's items are paired field assignments, not transfer
primitives.** §2.2. The transaction is explicit, delimited, documented and
ASSERT-enforced, and the moved-out state is now pinned by a test (§2.4), so this
is a readability/robustness observation rather than a correctness gap. The
asymmetry with boundary 2 and boundary 3 — which both use named `take*` /
`adopt*` / `set*` primitives with written consumption contracts — is the
strongest available argument for eventually giving the FB commit the same
vocabulary. **It does not block legacy deletion**: deleting legacy does not touch
this region.

**F3 — the source-text escape is a raw pointer copy whose correctness is a
`len + 1` arithmetic agreement between two files.** §2.1 row (j). Both sides are
correct today (`src/bytecode.zig:3629` vs `:2470-2476`). No enforcement tier
above PROSE covers the agreement itself; the OOM and force-GC gates cover its
consequences. Recorded because it is the only escape in the audit that is not
mediated by a typed value or an atom.

**F4 — "no `try` below this line" is prose.** §2.3. The OOM-injection gate
converts it into an ORACLE for the allocating case, which is the case that
matters, but a future non-allocating fallible call inside the region would be
caught by neither.

### 7.3 Explicitly checked and found *not* to be problems

* **No compiler-owned atom escapes into the module registry.** All module
  metadata atoms are re-duplicated and the parsed record is destroyed on every
  path (§3.1). A borrowed-atom escape here was the obvious hazard given main's
  borrowed-atom lint work; it does not exist.
* **No compiler-owned buffer is aliased by the artifact.** Code bytes are copied
  into FAM storage (`:12806`); the carrier frees its own buffer. The lifetime
  audit independently confirmed that **0 of the 1,604 pointers reachable from a
  published FB tree fall inside a parser-arena block, on both pipelines**
  (`docs/v2_builder_lifetime.md` §11.3, §12.2.1).
* **No v2-only persistent table exists.** The label table, reloc array and
  source-slot array are absent from the artifact on both pipelines
  (`docs/v2_builder_lifetime.md` §11.2: labels 0, boundaries 0).
* **The cpool escape is a MOVE with `cpool_count = 0`**, so a FunctionDef that
  is destroyed after a successful escape cannot release a child artifact.
* **No escape site branches on the backend.** Verified by reading every site
  cited above; the single backend fork (`src/bytecode.zig:12731-12756`) sits
  entirely above the escape.

---

## 8. Verdict

| boundary | class | blocks legacy deletion? |
| --- | --- | --- |
| FunctionBytecode → runtime | **EXPLICIT** | no |
| module persistent | **EXPLICIT** | no |
| closure persistent | **EXPLICIT** | no |
| async continuation | **IMPLICIT-BUT-SOUND** (ASSERT-enforced after F1) | no |
| generator continuation | **IMPLICIT-BUT-SOUND** (ASSERT-enforced after F1) | no |

**Zero UNCLEAR boundaries. The Phase 5 escape gate passes.**

The load-bearing reason it passes is structural rather than diligent: the
compiled program escapes into the runtime at exactly **one** point
(`src/bytecode.zig:12887`), that point is a delimited no-fail region guarded by
five fail-closed validators, and every later persistence structure takes an
ordinary reference to the already-published artifact. There is no second door.

Two statements the ruling asked for, made plainly:

1. **v2 and legacy do not differ at any of the five boundaries.** They converge
   before the first one and never fork again. Where they differ at all — in how
   each makes its *own* producer inert before the escape — v2 is the more
   explicit: a named `releaseConsumedBuilder` with a documented contract and a
   five-way capacity assertion, against six inline field assignments.
2. **Deleting legacy removes no escape enforcement.** Every validator, primitive
   and assertion listed in §2.3, §3.3, §4.3 and §5.3 is backend-neutral and
   survives. The only escape-adjacent code that dies with legacy is
   `lowerLegacyPhase1` (`src/bytecode.zig:12685-12712`), which is the *less*
   explicit of the two producer-release shapes.

---

## 9. Tests added

| test | file | what it pins |
| --- | --- | --- |
| `compiler_v2.p5: FunctionDef owners are inert after the FunctionBytecode escape` | `src/compiler_v2/tests.zig` | every MOVE in §2.1 leaves its source slot at the null sentinel, over the whole FunctionDef tree, **on all three builds**; and the receiving FB really got them |
| `compiler_v2.p5: escaped atoms outlive compiler teardown` | `src/compiler_v2/tests.zig` | an atom reachable only through compiled code survives full compiler teardown, and the FB is its **sole** owner (refcount returns exactly to baseline when the FB is released) |
| `generator continuation keeps its FunctionBytecode alive after every source binding is dropped` | `src/tests/exec.zig` | escape (i) of §5.1: a suspended generator and a suspended async function keep their FunctionBytecode alive across `$262.gc()` with every source-level binding overwritten |

Three tests, one per escape shape that can be cheaply falsified: MOVE inertness,
atom-ref survival, and continuation retention. Boundary 2's contract is already
mechanically enforced by the `replaceDefinitionNoFail` assertion block and the
`var_idx` cross-validation, and boundary 3's by the `setFunctionCaptures` length
assertion, so neither earns a new test.

## 10. Gates

| gate | result |
| --- | --- |
| `zig fmt --check src build.zig` | PASS |
| `zig build zjs` (legacy) | PASS |
| `zig build zjs -Dzjs_compiler=v2` | PASS |
| `zig build zjs -Dzjs_compiler=dual` | PASS |
| `zig build test-compiler-v2 -Dzjs_compiler=v2` | PASS (197) |
| `zig build test-compiler-v2 -Dzjs_compiler=dual` | PASS (197) |
| `zig build test-compiler-v2` (legacy) | PASS (50 + 147 expected skips) |
| `zig build test -Dzjs_compiler=dual` | PASS (2,266, 1 skip) |
| `zig build test-oom -Dzjs_compiler=v2` | PASS |
| `zig build test-core -Dzjs_compiler=v2 -Dzjs_force_gc=true` | PASS |
| corpus `mc.js` / `ma.js`, v2 | `CHECKSUM: 240/240` both |
| corpus `mc.js` / `ma.js`, dual | `CHECKSUM: 240/240` both, **0** `ZJS-DUAL-MISMATCH` |

The force-GC and OOM gates are the ones that bear on this audit specifically:
force-GC drives a collection at every allocation point, which is what would
expose a boundary that published an artifact the collector could not yet trace
or that released an owner the runtime still reached; OOM injection drives every
allocation to failure, which is what would expose a half-completed transfer.
Both pass with the escape tests of §9 in the suite.
