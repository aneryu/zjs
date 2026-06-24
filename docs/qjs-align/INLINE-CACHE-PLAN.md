# Inline Cache Wiring for zjs Property + Global Access — Implementation Design

## TL;DR

The IC is built and enabled (`build.zig` `zjs_enable_ic = true`). **S1 (get_field/get_field2) and S2 (put_field) are LANDED in `e8c852b`** — the field opcodes now probe the IC before the slow chain (property read 3.4x→2.57x, write →2.79x). **Remaining: S3** (global / top-level-lexical stable-cell IC + retire `global_lexical_sync`) and **S4** (poly/mega validation). A wiring mistake that defeats a guard = wrong value = test262 regression, so every remaining stage re-runs the full gate triad.

## What exists (read these before touching anything)

- `src/core/ic.zig` — `Slot` (state: empty/mono/poly/mega, entries[4]), `Entry{shape_ref, holder_shape_ref, version, holder_version, atom_id, slot_index}`. Guard: `shape_ref==receiver.shape_ref && version==receiver.shape_ref.version && atom_id==atom`. `installOwnData`/`installProtoData` retain shapes; `releaseEntries` releases on deinit/mega. `poly_entry_limit = 4`.
- `src/core/shape.zig` — `Shape.version: u32`, bumped `+%= 1` on transitionProperty/addProperty/markPropertyDeleted/updatePropertyFlags/replacePrototypeAssumePrepared/cloneForMutation/restorePropertyLayout/rebuildPropertyHash. Shapes are immobile (GC never moves them). Deleted props keep their index, set `flags.deleted`, bump version.
- `src/bytecode/function.zig` — `ic_slots/ic_site_ids/ic_sites` (`:198-200`), allocated post-finalization by `allocateIcSlots` (`:256`) for `opcodeHasOwnDataIc` opcodes (`:611`, already lists get_var/get_var_undef/put_var/get_field/get_field2/put_field). `icSlotForPc(site_pc)` (`:299`) — dense O(1) (code_len>128 or sites>8) else sparse O(log n).
- `src/core/function_bytecode.zig:186-188` — GC-managed mirror of the slot arrays.
- `src/exec/property_ic.zig` — **the IC-aware helpers that are currently unused by the field opcodes**:
  - `dataPropertyValueForFastPath(function, site_pc, rt, receiver, atom_id)` (`:68`) — gates via `cacheableNamedDataObject`, checks IC (own at `:82` + proto at `:83`), on miss does `fastOwnOrdinaryDataPropertyLookupForObject` + `installOwnDataIcForObject` (`:88-94`) and one-level proto + `installProtoDataIcForObject` (`:95-101`). Returns borrowed value.
  - `setObjectDataPropertyForPutFieldFastPath(rt, function, site_pc, receiver, atom_id, value)` (`:218`) — IC-hit write + install-after-write.
  - `cachedOwnDataPropertyLookupForObject` (`:259`) -> `ownDataPropertyBorrowedAt` -> `dataSlotAt` (`:846`) revalidates atom_id + flags at the cached index.
- `src/exec/vm_property_field.zig` — `field()`: get_field, get_field2, put_field. **As of `e8c852b` (S1/S2) these probe the IC first** (`dataPropertyValueForFastPath` / `setObjectDataPropertyForPutFieldFastPath` with `site_pc`), falling to `qjsGetFieldFast` (full `findOwnDataPropertyFast` proto walk) only on miss. (Pre-S1 they bypassed the IC entirely — that is the gap S1/S2 closed.)
- `src/exec/vm_property_globals.zig` — `getVar` (`:206`) is **already IC-wired**: `site_pc = frame.pc - 1` (`:222`), `cachedGlobalDataValue` (`:228`/`:164`), `fastInstalledGlobalDataValueForAtomAtPc` (`:245`), `globalDataPropertyValueForFastPath` (`:259`). Covers `var`-globals (data props on the global object).

## Diagnosis (confirmed by reading the code)

| Gap | Bench | Cause | Fix |
|---|---|---|---|
| prop_read_mono ~3.41x | `o.b` in loop | get_field bypasses IC -> `findProperty` hash walk every access | **S1**: wire get_field/get_field2 to `dataPropertyValueForFastPath` |
| (property writes) | `o.b = i` | put_field bypasses IC | **S2**: wire put_field to `setObjectDataPropertyForPutFieldFastPath` |
| global_read ~4.46x | `let g` in loop | `let` is a top-level LEXICAL (var_ref in `ctx.lexicals`), missed by the global DATA-prop IC; pays name lookup + global_lexical_sync mirror | **S3**: stable-cell IC for lexical globals + retire the mirror |
| (poly) | poly3 | poly machinery exists; validate it engages once S1 lands | **S4**: validate/tune poly + mega |

Note `global_read_loop` uses `var x` (data prop) and **already hits** the existing global IC — do not regress it.

## Feasibility

- **Shape identity is IC-guardable**: pointer-compare + u32 version. Immobile shapes make the pointer valid; in-place unique-shape mutation keeps the pointer but always bumps version, so the version check is load-bearing. All mutation paths bump version -> stale IC detected on next access -> slow path + refill. Cached shapes are retained/released, so no dangling pointers.
- **Bytecode does NOT carry an IC index** — and should not. Fixed opcode sizes (get_field=5, get_var=3) have no room; widening forces a variable-length rewrite. The chosen storage is the **per-function side-channel slot array** (already built and allocated for these opcodes). `site_pc` = opcode byte offset = `frame.pc - 1` captured at handler entry (the dispatch loop already consumed the opcode byte).

## Staged plan (each stage independently gateable)

### S0 / S1 / S2 — ✅ LANDED in `e8c852b`
get_field / get_field2 read IC + put_field write IC are wired in `vm_property_field.zig`: the arm captures `site_pc = frame.pc - 1`, probes `dataPropertyValueForFastPath` / `setObjectDataPropertyForPutFieldFastPath` before the slow chain, and inlines the monomorphic hit into the dispatch arm (`zjs_vm.zig`). put_field transfers value ownership (`value_consumed`). Result: prop_read_mono 3.41x→2.57x, write →2.79x; var-global global_read_loop unchanged. Implementation in git history.

### S3 — global / top-level-lexical stable-cell IC + retire global_lexical_sync (PENDING)
The `let g` site lives in `ctx.lexicals` (an Object with a Shape). Add a `cachedGlobalLexicalCellValue` path in `getVar` after `cachedGlobalDataValue`, keyed on `ctx.lexicals.shape_ref` (pointer+version)+atom, caching the lexical **index only** (reuse `ic.Slot`/`installOwnData` against the lexicals object). On hit: deref the cell, run TDZ check (`isUninitialized()` -> ReferenceError), push. Gate on `inactiveGlobalOverlayState`. Then, as the LAST step (own gate run): retire `global_lexical_sync` — delete `frame.global_lexical_sync_*`, `ensureGlobalLexicalSyncSlots` (slot_ops.zig:146), `syncTopLevelGlobalLexicalLocal` (slot_ops.zig:124), the `sync_global_lexical_locals` plumbing, and the frame.deinit cleanup (the single-cell write path from da34bc1 covers writes). If test262 drops, revert just the removal and keep the read IC.
**Expected**: global_read 4.46x -> ~1.0-1.5x; var-global global_read_loop unchanged.

### S4 — poly / mega validation + tuning
Confirm `dataPropertyValueForFastPath` install promotes empty->mono->poly(4)->mega (`ic.zig:135`), that poly3 (3 shapes) stays poly with all hits, and that mega promotion releases retained shapes (`releaseEntries`). Inline the poly hot-check only if poly3 still lags qjs after S1.

## Verify (run for EVERY stage — BLOCKING)
1. `zig build test262-gate` -> **exactly 0/49775** (any stale-IC wrong value flips a conformance test).
2. `zig build test` -> **1223 unit pass**.
3. force-GC build -> **1223 pass** (churns shapes -> stresses version-invalidation and shape-retention release).
4. Targeted correctness micro-tests per stage: delete-after-cache (read undefined), redefine-to-accessor (slow path), setPrototype-after-cache (proto IC invalidates), and for S3: TDZ throw, reassignment observed, let-shadows-var, eval/with invalidation.
5. Pinned perf on cpu19/pmuv3_1 for the stage's target bench(es); confirm the profiler shows the expected IC hit-rate. **Never claim a win without the pinned number.**

## Must-preserve invariants
See the structured `must_preserve` list: version-guarded invalidation on every mutation; deleted-prop revalidation via `dataSlotAt`; accessor/proxy/exotic/typed-array/array-length fallback via `cacheableNamedDataObject`; one-level proto guard on holder shape+version; TDZ deref-not-value for lexicals; eval/with overlay gating; mega release-on-promotion (no shape leak); borrowed-vs-owned refcount contract.

## Top risk
**A stale IC after shape mutation = wrong value = test262 regression.** The version guard + `dataSlotAt` revalidation already prevent this; the task is to not bypass them when wiring. test262 0/49775 + force-GC 1223 + targeted delete/redefine/setPrototype tests are the detectors, run every stage.