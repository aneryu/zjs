# A4 — Retire the `global_lexical_sync_*` mirror by routing eval top-level lexicals faithfully (frame-local, no parallel env property)

> **Terminal-state blueprint, CORRECTED.** The prior revision of this doc claimed the
> mirror is "near-dead, just delete it." **That premise is WRONG.** A `@panic` probe at
> `slot_ops.zig:199` (the `has_sync_slot = true` point) **fires in the unit suite** —
> the mirror is **LIVE for the host eval-mode path** (`ctx.eval(.eval_direct/.eval_indirect)`).
> This revision corrects the firing-map, the qjs target, and the migration.
>
> Read-only ground-truth at `main @ d244776` (post-L2 16B property slot, post-L3 array
> count/length). Every claim is anchored to a real `file:line` / `quickjs.c:line`
> re-verified at HEAD. **Doctrine:** faithful = mirror qjs structure; terminal-state;
> the ONLY allowed deviation is where qjs's structure would regress a test262 case
> (then keep the minimal deviation + document it, §0.4). Correctness gate: test262
> 0/49775 (currently 6 accepted unicodeSets `\q{}` upstream-known) + 1227 unit + 1227
> force-GC. perf is the RESULT.

---

## 0. TL;DR — the corrected headline

1. **The mirror is LIVE.** It fires on the **host `ctx.eval()` API with `.eval_direct` /
   `.eval_indirect` mode** (the path unit tests / embedders use; e.g.
   `src/tests/exec.zig:3416` `evalWithOptions(…, .{ .mode = .eval_indirect })` with a
   top-level `const b`). It does **not** fire from the in-VM `eval()` builtin
   (`eval_ops.zig:666` / `call_runtime.zig:4733` pass `sync_global_lexical_locals=false`),
   which is why **test262 eval-code dirs do not exercise the mirror** (the test262 harness
   runs source in `.script` mode, `run_test262.zig:1743`, so its `eval(...)` goes through
   the sync=false builtin). So the firing surface is **unit-suite-only today**, but it is
   real LIVE plumbing, not dead code.

2. **The root cause is a runner mismatch, not a missing cell.** `eval_entry.eval`
   (`eval_entry.zig:94`) runs **all** non-module eval modes through `zjs_vm.runWithOutput`
   — the **script runner** — which hardcodes `entry_is_eval_code = false` and
   `entry_sync_global_lexical_locals = true` (`zjs_vm.zig:334` → `runWithArgs`
   `zjs_vm.zig:422`). The in-VM eval builtin instead uses the eval contract
   (`is_eval_code = true`, `sync = false`, `eval_ops.zig:666`). So the host eval path is
   **the script runner being misapplied to eval code**: it (a) turns the sync mirror ON and
   (b) treats eval bindings as script globals, which is exactly the combination that creates
   a redundant `ctx.lexicals` env property next to the eval's frame-local and then mirrors
   into it on every store.

3. **The faithful qjs target says: DON'T migrate eval lexicals to cells.** A top-level
   `let`/`const` becomes a `JS_CLOSURE_GLOBAL_DECL` / `JS_CLOSURE_MODULE_DECL` cell **only**
   for `JS_EVAL_TYPE_GLOBAL` (= zjs `.script`) and `JS_EVAL_TYPE_MODULE`
   (`quickjs.c:24362-24372`, `35985-35988`). For `JS_EVAL_TYPE_DIRECT` and
   `JS_EVAL_TYPE_INDIRECT`, a top-level `let`/`const` is `add_scope_var` — a **frame local**
   that lives and dies with the eval frame, with **no `global_var_obj` cell and no mirror**
   (qjs has no `global_lexical_sync_*` analogue at all). zjs **already** keeps eval top-level
   lexicals as frame-locals (parser `else if (is_lexical)` → `addScopeVar`,
   `parser.zig:9585-9593`, with the cell branch gated `… && !s.is_eval`,
   `parser.zig:9562`). So **the storage class is already faithful** — the ONLY
   non-faithful artifact is the redundant `ctx.lexicals` mirror, created and fed solely by
   the misapplied script runner.

**Net A4:** route the host eval-mode entry through the **eval runner contract**
(`is_eval_code = true`, `sync = false`) so it stops materialising a parallel `ctx.lexicals`
property for an eval frame-local; then **delete the mirror** (helpers, frame cold fields,
the `sync_global_lexical_locals` thread, the `localStoreNeedsSlowSync` per-op guards, and
the `vm_arith` `max_ref_count=3` special case). Script + module stay on the already-faithful
cell. This is a **2-step one-shot** (re-route + delete in one commit), NOT a cell construction
and NOT a bare deletion.

---

## 1. CURRENT STATE — the corrected firing-map (verified at HEAD)

### 1.1 Where top-level `let`/`const` live, by mode (parser routing)

`parser.zig:175`: `state.top_level_lexical_as_global_ref = (options.mode == .script)`.
`parser.zig:176-177`: `eval_global_var_bindings` is on for indirect eval + explicit
global-var-bindings, but **off** for strict direct/indirect eval.
`eval_entry.zig:204`: `.eval_direct`/`.eval_indirect` → `enableEvalReturn()` →
`s.is_eval = true` (`parser.zig:877-879`) and adds the `_ret_` completion slot (this is
why firing `var_names.len` includes a `_ret_` entry: e.g. `{b, Box, _ret_}` = len 3).

| Mode (zjs) | qjs eval_type | Parser branch | Storage | Self-read op |
|---|---|---|---|---|
| `.script`, scope 0 | `JS_EVAL_TYPE_GLOBAL` | `top_level_lexical_as_global_ref && scope0 && !is_eval` (`parser.zig:9562`) | `.global_decl` cell (NO `addScopeVar`) | `get_var_ref` |
| `.module`, scope 0 | `JS_EVAL_TYPE_MODULE` | `module_top_level_decl` (`parser.zig:9546`) | `.module_decl` cell | `get_var_ref` |
| `.eval_direct` / `.eval_indirect`, scope 0 | `JS_EVAL_TYPE_DIRECT` / `INDIRECT` | `else if (is_lexical)` → `addScopeVar` (`parser.zig:9585-9593`); `addGlobalVar` SKIPPED (`9588` gate `!s.is_eval`) | **frame local** (TDZ `get_loc_check`) | `get_loc_check` |
| block (scope > 0), any mode | — | `else if (is_lexical)` → `addScopeVar` | frame local | `get_loc_check` |

**Key fact:** eval top-level lexicals are **frame locals with no `global_vars` entry** — the
storage class already matches qjs `add_scope_var`. The cell branch is correctly gated off for
eval.

### 1.2 The mirror's LIVE firing path (the stack trace, anchored)

```
host ctx.eval(src, {.mode = .eval_indirect})        binding/context.zig:500
  → eval_entry.eval                                  eval_entry.zig:28
    → zjs_vm.runWithOutput                           eval_entry.zig:94
      → runWithArgs(…, /*sync*/ true)                zjs_vm.zig:334  (→ 422)
        → runWithArgsState(is_eval_code=false,       zjs_vm.zig:500
                           sync=true)
          → dispatchLoop                             zjs_vm.zig:730
            → checkedLocVm  (put_loc_check_init for `const b`)
                                                     vm_property_locals.zig:263
              → syncTopLevelGlobalLexicalLocal       slot_ops.zig:122
                → ensureGlobalLexicalSyncSlots       slot_ops.zig:146
                  → has_sync_slot = true             slot_ops.zig:199   ← PROBE FIRES
```

`runWithArgs` (`zjs_vm.zig:422`) maps its trailing `…, true, false` →
`entry_sync_global_lexical_locals = true` (because it routes through `runWithOutput`'s
`…, true, false, false` then `runWithArgsState`'s fixed `…, false /*is_eval_code*/,
true /*sync*/, …, false`). Confirm by contrast: the in-VM eval builtin
(`eval_ops.zig:666`) passes the eval contract `…, eval_global_var_bindings, /*is_eval_code*/
true, eval_with_object, /*sync*/ false, false`; indirect-eval builtin (`call_runtime.zig:4733`)
likewise passes `sync = false`.

### 1.3 Why the env property exists for the firing case (the redundancy)

The mirror's `ensureGlobalLexicalSyncSlots` only returns true when `env.hasOwnProperty(atom_id)`
(`slot_ops.zig:184`) AND the name is a scope-0 frame-local lexical in `var_names`
(`slot_ops.zig:175,183`). For the firing eval, the `ctx.lexicals` entry is materialised by the
**misapplied script runner**: with `is_eval_code = false`, `runWithArgsState` runs the
script-mode global-var instantiation path (`zjs_vm.zig:630` →
`instantiateGlobalVarDeclarations`, `vm_property_globals.zig:1151`) and the script-mode
`defineGlobalVarDeclaration` lexical arm (`vm_property_globals.zig:1130-1137`), which —
when `defineGlobalDeclLexicalCell` returns false for a non-`.global_decl` binding — falls
back to `defineGlobalLexicalValue(uninitialized)` (`vm_property_globals.zig:1136`), creating a
**plain data property in `ctx.lexicals`**. (For indirect eval, `ctx.lexicals` has already been
swapped to `eval_global.globalLexicals()`, `call_runtime.zig:4719`, so this property lands in
the realm's global lexical env.) That env property is the mirror's sync target. **qjs never
creates it** — its eval lexicals are pure frame locals. The mirror exists only to keep this
zjs-only redundant property in step with the frame local.

### 1.4 Proof the mirror is functionally redundant (empirical)

The same eval scenarios resolve **correctly without any mirror** via the var_ref capture path
on the sync=false builtin route (verified against `zig-out/bin/zjs`):
- indirect eval `let z; function rd(){return z;} z=99; rd()` → **99** (closure sees the write).
- indirect eval `const C=10; (function(){return C;})` → **10**.
- direct eval `let q=5;` does **not** leak to outer (`q` → ReferenceError).
- a `let` from one indirect eval does **not** leak into a second indirect eval
  (per-call lexical env, ReferenceError) — so persisting it as a global cell would be a
  *bug*, confirming §0.3 / §4.

So nothing the mirror does is observable that the var_ref path does not already provide on the
faithful (eval-contract) runner.

---

## 2. qjs TARGET (faithful structure)

| qjs construct | quickjs.c anchor | meaning |
|---|---|---|
| `eval_type` constants | `quickjs.h:332-336` | GLOBAL=0, MODULE=1, DIRECT=2, INDIRECT=3 |
| public `JS_Eval` = `JS_EVAL_TYPE_GLOBAL` | `quickjs.c:37343-37362` | host top-level program = zjs `.script` |
| `eval()` builtin = `JS_EVAL_TYPE_INDIRECT` | `quickjs.c:39883` | `(0,eval)(…)` |
| `is_global_var = (GLOBAL) \|\| (MODULE) \|\| !STRICT` | `quickjs.c:37089-37091` | who registers `global_vars` |
| **top-level `let`/`const` → `add_global_var` ONLY for `is_eval && (GLOBAL \|\| MODULE) && scope==body_scope`; else `add_scope_var` (frame local)** | `quickjs.c:24362-24387` | **the decisive gate** |
| same gate for top-level eval function decls | `quickjs.c:36589-36592` | consistency |
| `add_global_variables`: each `global_vars[]` → `JS_CLOSURE_GLOBAL_DECL` / `MODULE_DECL` | `quickjs.c:35954-36001` | builds the cells |
| `js_closure_define_global_var` (lexical → JS_PROP_VARREF in `global_var_obj`, uninitialized=TDZ, ref reuse) | `quickjs.c:17125-17159` | the single shared cell |
| `OP_get_var_ref` = `*sp++ = JS_DupValue(*var_refs[idx]->pvalue)` | `quickjs.c:18613-18627` | single-indirection read |
| **NO mirror / write-through to a parallel env property** | — | qjs has no `global_lexical_sync_*` |

**Therefore the faithful storage classes are already correct in zjs:**
- `.script` top-level let/const → `.global_decl` cell (matches `add_global_var` + GLOBAL_DECL). ✅
- `.module` top-level let/const → `.module_decl` cell. ✅
- `.eval_direct` / `.eval_indirect` top-level let/const → **frame local, discarded with the
  eval frame** (matches `add_scope_var`; NOT a global cell). ✅ already; the migration just
  removes the redundant env property the script runner adds.

> Note on indirect eval: qjs `JS_EVAL_TYPE_INDIRECT` runs in the global object scope but its
> body-scope let/const are **still `add_scope_var` frame locals** (line 24362 requires
> GLOBAL/MODULE, not INDIRECT). Per the spec, an eval's lexical declarations live in the
> eval's own *declarative environment record*, discarded when the eval returns — never the
> global lexical environment. zjs's frame-local storage is the faithful match; the
> `ctx.lexicals` data property is the deviation.

---

## 3. MIGRATION DESIGN (terminal state)

**Goal:** every top-level `let`/`const` read/write goes through its faithful storage —
the `.global_decl`/`.module_decl` cell for script/module, the **frame local** for direct/
indirect eval — and the `global_lexical_sync_*` mirror **does not exist**. The probe at
`slot_ops.zig:199` must not fire on unit + test262 after the change.

### 3.1 STEP A — route the host eval-mode entry through the eval runner contract (the real fix)

The single structural change is in `eval_entry.eval`: stop running `.eval_direct`/
`.eval_indirect` source through the **script** runner. Two equivalent ways to land it; A.2 is
preferred (it is the minimal, most faithful edit):

- **A.1 (broad):** give `eval_entry.eval` a dedicated eval run that calls
  `zjs_vm.runWithArgsState` with the eval contract used by the in-VM builtin —
  `entry_is_eval_code = true`, `entry_sync_global_lexical_locals = false`,
  `entry_eval_global_var_bindings` derived as today (`= options.eval_global_var_bindings or
  mode == .eval_indirect`, mirroring `parser.zig:176`). Mirror what `eval_ops.zig:666`
  already does for a top-level (no caller frame) eval.

- **A.2 (minimal, preferred):** since `runWithOutput` is shared by script and host-eval, add a
  thin `runEvalWithOutput` (or pass an `is_eval_code`/`sync` pair through a small
  `EvalRunOptions`) and have `eval_entry.eval:94` select it for `.eval_direct`/`.eval_indirect`
  (the module path already branches at `eval_entry.zig:87`). The selected runner passes
  `entry_is_eval_code = true, entry_sync_global_lexical_locals = false`. Script keeps
  `runWithOutput` unchanged.

**Why this is the fix, not "make eval lexicals cells":** with `is_eval_code = true`,
`instantiateGlobalVarDeclarations` no longer runs the script-mode lexical-cell/data-property
arm for eval bindings (`vm_property_globals.zig:1166` already special-cases `!is_eval_code`,
and eval has no `global_vars` lexical anyway), so **no parallel `ctx.lexicals` property is
created** — the eval frame-local stands alone, exactly as qjs. With `sync = false`, even if an
env property existed, the mirror is inert. After A, the probe at `slot_ops.zig:199` has no
path to fire (no sync=true entry over an eval frame-local).

**What STAYS frame-local (the genuinely eval-scoped, discarded cases):** all `.eval_direct` /
`.eval_indirect` top-level `let`/`const`/`class`. These are correct as frame locals
(`parser.zig:9585`); STEP A does not touch the parser. They are discarded with the eval
frame — never promoted to a cell.

**What is already a cell and is NOT touched:** `.script` (`.global_decl`) and `.module`
(`.module_decl`) — the cell lifecycle (`ensureGlobalLexicalCell` /
`defineGlobalDeclLexicalCell` / `defineGlobalDeclVarCell`, `call_runtime.zig:3581-3708`),
`get_var_ref`/`put_var_ref` deref (`vm_property_locals.zig:270-322`), and the L2 var_ref
property model (`property.zig` `Kind.var_ref`, `object.zig` `asVarRefAt`/`isVarRefAt`).

### 3.2 STEP B — delete the mirror (now provably inert)

After A, no entry passes `sync_global_lexical_locals = true` over an eval frame-local, and
script/module never had a frame-local lexical to sync. The mirror is dead. Delete it.

### 3.3 No new IC / cache

Eval reads are frame-local `get_loc_check` (O(1)); script/module reads are `get_var_ref`
single indirection (O(1)). There is **no by-name lookup on any live top-level-lexical read
path** to cache. A4 needs **no stable-cell IC** — the DIVERGENCE-CATALOG "stable-cell needs a
cache" premise is false at HEAD.

---

## 4. MINIMAL-DEVIATION ANALYSIS (§0.4) — VERDICT: NO deviation needed; the WRONG move is the one to avoid

**The candidate deviation the task asks about:** "is there an eval case where making it a cell
would REGRESS a test262 case (e.g. an eval-introduced binding that must stay a deletable data
property, not a non-deletable cell)?"

**Answer: making eval lexicals cells would regress — so DON'T do it.** That is precisely why
the faithful design (STEP A) keeps eval top-level let/const as **frame locals**, matching qjs.
Concretely:

- **Per-call lexical environment.** An eval-introduced `let`/`const` must NOT survive the eval
  (`language/eval-code/{direct,indirect}/lex-env-no-init-let.js` and the per-call scoping the
  empirical check confirms: a `let` from one `(0,eval)(…)` is invisible to the next). A
  **non-deletable global cell would persist it across evals** → regression. Frame-local is
  correct.
- **No global property to delete.** `delete`-of-eval-binding semantics
  (`language/global-code/decl-lex-deletion.js` is script-mode and stays on the cell;
  eval-introduced lexicals have no global property at all) require the eval binding to live in
  the eval's declarative record, not as a global cell. Frame-local is correct.
- **eval var (non-lexical) deletability.** `language/eval-code/{direct,indirect}/var-env-func-
  init-global-update-{,non-}configurable.js` concern eval-introduced *var/function* bindings
  becoming **configurable** global data properties — handled by the existing
  `eval_global_var_bindings` data-property path (`addGlobalVar` `is_configurable`,
  `parser.zig:779`), which A4 does **not** touch (it is not a lexical, not the mirror).

**So the minimal documented deviation is: NONE that A4 introduces.** A4 *removes* a deviation
(the redundant `ctx.lexicals` mirror) and keeps the faithful frame-local for eval. The only
trap to avoid is the inverse — do **not** route eval lexicals to `.global_decl` cells; that
would be the regression. (If, contrary to expectation, STEP A surfaces a case where some
nested-function-in-eval read genuinely depended on the env property — none found empirically,
§1.4 — the faithful repair is to make that read capture the eval frame-local via a var_ref,
**not** to re-add the mirror or a cell.)

---

## 5. REGRESSION SURFACE (the hard gate)

Run after the one-shot: test262 0/49775 (6 accepted unicodeSets known) + 1227 unit + 1227
force-GC. Specific dirs, ranked by risk:

1. **`language/eval-code/direct/**` and `language/eval-code/indirect/**` — HIGHEST.** This is
   the storage class A4 stabilises. Watch: `lex-env-no-init-let.js` (TDZ in the eval's own
   lexical env), `lex-env-distinct-cls.js`, `var-env-global-lex-non-strict.js` (var↔lexical
   collision → SyntaxError), `var-env-gloabl-lex-strict-caller.js`,
   `var-env-func-init-global-update-{,non-}configurable.js` (eval var deletability — unchanged
   path), and any direct-eval closure capturing an eval `let` after a write (var_ref path,
   §1.4). NB: test262 reaches these via the **sync=false builtin**, so they are unaffected by
   the mirror today — but STEP A changes the host-eval runner contract; re-running proves the
   eval-frame-local read/write/TDZ still resolve once the redundant env property is gone.
2. **`language/global-code/**` — script-mode cells (already faithful).** `decl-lex.js`,
   `decl-lex-deletion.js` (cell is non-deletable → `delete` returns false, binding survives),
   `decl-lex-configurable-global.js` (`let Array` shadows the configurable global property),
   `decl-lex-restricted-global.js`, `script-decl-lex*.js`. STEP A/B do not touch the cell;
   these must stay green (regression here would mean the deletion nicked the cell path).
3. **`language/statements/{let,const}` + TDZ.** Top-level + block TDZ must still throw via the
   cell uninitialized arm (`object.zig` var_ref existence/TDZ) for script, and via the
   frame-local `get_loc_check` uninitialized for eval/block.
4. **cross-realm let reassignment (`da34bc1`).** `r = eval(...)` lowering `scope_make_ref` →
   `make_var_ref_ref` writes through the **shared `.global_decl` cell**
   (`closureVarIsRuntimeVarRef` keeps `.global_decl`). This is the script-mode cell path — A4
   must not disturb it (`built-ins/eval`, `$262.createRealm` cross-realm tests).
5. **generator suspend.** Generators preserve `var_refs` and frame locals across resume
   (`vm_gen_async.zig`). The mirror never participated, but deleting the
   `localStoreNeedsSlowSync` guards changes the `put_loc_check`/`set_loc`/`add_loc`/
   `update_loc` **fast-path entry** — a generator/await frame doing local stores must
   regress-test (`language/expressions/generators`, `language/statements/for-of`).
6. **with-shadow.** `with` routes around the var_ref fast lane via the dynamic-global overlay
   (`hasDynamicGlobalOverlay`, `vm_property_globals.zig:97`); it does not use the mirror, but
   the local-store fast-path collapse (§6.3) touches the same op handlers, so
   with-blocks doing local stores are in scope (`language/statements/with`).

---

## 6. DELETION SURFACE (every file:line; all DELETIONS after STEP A)

### 6.1 Mirror helpers (`slot_ops.zig`)
- `syncTopLevelGlobalLexicalLocal` (`slot_ops.zig:122-144`) — DELETE.
- `ensureGlobalLexicalSyncSlots` (`slot_ops.zig:146-211`) — DELETE (the probe site `:199`).
- Call sites in `execPutLoc`/`execSetLoc` (`slot_ops.zig:76,97`) — DELETE the
  `try syncTopLevelGlobalLexicalLocal(...)` line; drop the `sync_global_lexical_locals` param
  from both signatures (`slot_ops.zig:68,88`). NB the **second** sync call at
  `slot_ops.zig:411` lives in a *different* helper (the `getVar`/`useFastGlobalDataValue`
  slow path writing a free global-lexical name); that call is `setGlobalLexicalValueForGlobal`
  for a genuinely free name, **not** the mirror — keep it (it does not gate on
  `ensureGlobalLexicalSyncSlots`).

### 6.2 Frame cold state (`frame.zig`)
- `no_global_lexical_sync_index` const (`frame.zig:14`) — DELETE.
- Fields `global_lexical_sync_env/_slots/_indices/_checked` (`frame.zig:261-264`) — DELETE.
- Free sites (`frame.zig:299-300, 315-320`) — DELETE.
- Getters `globalLexicalSyncEnv/Slots/Indices/Checked` (`frame.zig:339-350`) — DELETE.

### 6.3 The `sync_global_lexical_locals` thread + the per-op fast-path guards
- `zjs_vm.zig`: `localStoreNeedsSlowSync` (`zjs_vm.zig:173-178`) and its 7 `break :*_fast`
  guards (`1038,1047,1257,1282,1307,2419,2444`) — `localStoreNeedsSlowSync` becomes
  `return false`, so all 7 guards become **unconditional fast paths** (the perf-relevant
  simplification: `put_loc_check`/`set_loc`/`add_loc`/`update_loc`/`put_loc` no longer probe
  the sync mask per store). Plus the loop var (`753`), the entry field/reassigns
  (`461,529,629/657 region,730,753,814,841`), and every `vm_property_*`/`arith_vm` call
  passing the flag (`495,1062,1240,1270,1295,1320,1327,1719,1821,1844,2430,2457`).
- `vm_property_locals.zig`: drop the param on `loc`/`checkedLocVm`/`storeBinding*` and every
  `syncTopLevelGlobalLexicalLocal` call (e.g. the firing site `vm_property_locals.zig:263`
  + `233,243,506,520,523,540,541,545,559,563,581,583,588`) and the `execPutLoc`/`execSetLoc`
  arg sites.
- `vm_arith.zig`: drop the param on `updateLocal`/`addLocal`/`updateLocalVm`/`addLocalVm`
  (`364,417,433,515`) and the sync calls (`380,391,405,466,…`).
- `vm_property.zig` / `vm_property_globals.zig` / `vm_property_field.zig`: drop the param +
  the dead `_ = sync_global_lexical_locals` pass-throughs.

### 6.4 The `vm_arith` `max_ref_count = 3` string-append special case
- `addLocal` (`vm_arith.zig:458-468`): the `has_global_sync_mirror` branch that bumps
  `max_ref_count` from 2 to 3 (the mirror held a third ref to the accumulator string) —
  DELETE; `max_ref_count` becomes constant `2`. With no mirror there is never a third holder,
  so `tryAppendStringInPlace` may in-place-mutate at refcount ≤ 2 unconditionally
  (correctness-relevant: the `3` existed *only* for the mirror).

### 6.5 Object helper (`object.zig`) — delete only the mirror-only one
- `setOwnDataPropertyAtForLexicalSync` (`object.zig:8905`) — sole caller was
  `slot_ops.zig:138`. DELETE after the mirror is gone.
- **KEEP** `setOwnDataPropertyAtForLexicalSyncOwned` (`object.zig:8933`) — caller is
  `setGlobalLexicalValueForFastPathOwned` (`call_runtime.zig:3748`), the non-mirror
  `put_var_init` fast path.

### 6.6 Resolver twin (`resolve_variables.zig` + `parser.zig` + `function_def.zig`) — recommended
- `isTopLevelGlobalLexical` (`resolve_variables.zig:776-786`) gates on `persist_global_lexical`
  which is **always false** (`parser.zig:178`). Both use sites
  (`resolve_variables.zig:1263,1652`) are unreachable. Remove them +
  `persist_global_lexical` (`function_def.zig` field, `parser.zig:178`). This is a faithful
  dead-code removal and the resolver-side twin of the mirror; leaving it is a latent footgun
  (flipping `persist_global_lexical` would re-introduce a by-name top-level-lexical lowering).
  Recommended to include in the same commit.

---

## 7. ONE-SHOT vs STAGED + verification protocol

**Recommendation: ONE-SHOT (single commit), 2 steps inside it, gate-after.** Doctrine-aligned
(`MEMORY: frame-rewrite-one-shot`, `zjs-decision-style`: single large commit, gate after, no
flag-gated intermediate state). The change is mechanical:
1. **STEP A** — re-route host eval-mode to the eval runner contract (`is_eval_code = true`,
   `sync = false`), §3.1.A.2. This alone makes the mirror inert.
2. **STEP B** — delete the mirror surface, §6.

Do NOT flag-gate. A flag would leave the mirror plumbing half-present (the worst state). The
catalog's "S3 flag-gated stages" note is honored as **gate discipline**, not staged rollout.

**Probe-based verification protocol (the load-bearing discipline):**
1. **BEFORE** any deletion: re-add the throwaway `@panic` (or a counter) at
   `slot_ops.zig:199` (the `has_sync_slot = true` site). Confirm it **FIRES** on the unit
   suite today (baseline: the mirror is live — e.g. `exec.zig:3416`
   `.mode = .eval_indirect` + `const b`). This reproduces the proven fact.
2. Apply **STEP A only** (re-route). Re-run unit + test262 with the probe still in.
   **The probe must now NOT fire** anywhere (unit + full test262). This proves the re-route
   removed the only live firing path *before* any deletion.
3. If the probe still fires after STEP A → record the exact source/mode/`var_names`, find the
   remaining sync=true-over-frame-local entry, and fix the runner contract for that entry too
   (still no cell, no mirror). Re-run until the probe is silent.
4. Once silent on unit + full test262 → apply **STEP B** (delete), remove the probe.
5. **Final gate:** test262 0/49775 (6 accepted unicodeSets) + 1227 unit + 1227 force-GC, all
   green. Then `zig build zjs` and re-baseline perf (the unconditional local-store fast paths,
   §6.3, are the perf-relevant payoff: no per-store sync-mask probe).

This converts "the mirror is dead after STEP A" from an argument into a measured fact, and
keeps the one-shot honest: re-route first, prove silence, then delete.

---

## 8. SUMMARY

- **Mirror is LIVE** on the host `ctx.eval(.eval_direct/.eval_indirect)` path (unit-suite
  today; not test262, which evals in `.script` mode through the sync=false builtin). Root
  cause: `eval_entry.eval` runs eval modes through the **script runner** (`runWithOutput`),
  forcing `is_eval_code = false` + `sync = true`, which materialises a redundant
  `ctx.lexicals` property next to the eval frame-local and mirrors into it.
- **qjs target:** top-level let/const → cell ONLY for GLOBAL (=zjs `.script`) and MODULE
  (`quickjs.c:24362`). DIRECT/INDIRECT eval → `add_scope_var` **frame local**, discarded,
  no cell, **no mirror** (qjs has none).
- **Migration:** STEP A re-route host eval to the eval runner contract (`is_eval_code = true`,
  `sync = false`) — eval lexicals stay frame-local (already faithful), the redundant env
  property stops being created, the mirror goes inert. STEP B delete the mirror surface
  (slot_ops helpers, frame cold fields, the `sync_global_lexical_locals` thread + 7
  `localStoreNeedsSlowSync` guards → unconditional fast paths, the `vm_arith max_ref_count=3`
  branch, `setOwnDataPropertyAtForLexicalSync`, and the dead `isTopLevelGlobalLexical`/
  `persist_global_lexical` resolver twin).
- **Minimal deviation (§0.4): NONE introduced.** The deviation being *removed* is the mirror.
  The regression trap to avoid is the inverse — do **not** make eval lexicals cells (would
  persist per-call eval bindings across evals → `lex-env-no-init-let` / per-call-env
  regressions). Keep eval frame-local.
- **One-shot, 2 steps, gate-after**, with the probe protocol (fire → re-route → silent →
  delete). No flag gate.
