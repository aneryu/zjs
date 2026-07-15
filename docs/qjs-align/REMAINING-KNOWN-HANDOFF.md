# Remaining test262 known — handoff (updated 2026-07-13)

State at handoff: branch `qjs-align-phaseA`, gate **`0/49775 errors`**, **known = 2** (down from 13 at 2026-07-04).

The 2026-07-04 version of this document listed 13 known (12 fixable + 1 no-align). Commit `e71e27e` (2026-07-12, "align async modules, strings, and calls") closed 11 of those 13 in a single large change. The remaining 2 are both **non-zjs-bug** items — qjs itself fails them on the same test262 checkout.

## The 2 remaining known

### await-using — 1 test — zjs bug, but qjs also fails

Test: `await-using/await-using-does-not-imply-await-if-not-evaluated.js`.

Root cause: zjs emits an UNCONDITIONAL `OP_await` at every block-exit of a block textually containing `await using` (`parser.zig:11461` `emitUsingDisposeStack`); an unevaluated `await using` (block exited before the declaration) still forces a microtask tick. Must be runtime-conditional on the async DisposableStack being non-empty.

Correct approach: add a non-destructive host probe (new special_object subtype + HostFunction in `call.zig` + object.zig payload `resources.len != 0`) and gate the trailing Await in `emitUsingDisposeStack`/`emitUsingDisposeStackForThrow` (`parser.zig:11453-11475`) on it. Touches `parser.zig` + `promise_ops.zig` + `call.zig` + `object.zig`. High risk: shared using/await-using chokepoint every block-exit path flows through.

> **Note:** qjs also fails this test on the current checkout, so fixing it would create a reverse divergence. The fix should be coordinated with a qjs upstream change, or accepted as a zjs extension.

### import-attributes `type:text` — 1 test — NO-ALIGN (keep known)

Test: `dynamic-import/import-attributes/2nd-param-with-type-text.js`.

Not a bug to fix: zjs implements text modules for STATIC import (string, passes 5 static tests) but the DYNAMIC path (`importLoaderTypeFromAttributes`, `module_graph.zig:94`, enum only `{none,json}`) is **deliberately qjs-faithful** — qjs 04be246 has no text-module support (dynamic gives number/JSON). Adding dynamic text would DIVERGE from qjs. Leave as known.

## Closed in commit `e71e27e` (2026-07-12) — 11 items

The following 11 known were closed by `e71e27e` and are documented here for historical reference. Full per-cluster blueprints: `docs/qjs-align/KNOWN16-RECON-2026-07-03.md`. Attempt findings + status log: `docs/qjs-align/FIX-PLAN-2026-07-02.md`.

### module TLA — 7 tests — CLOSED

Tests: `top-level-await/{top-level-ticks, top-level-ticks-2, fulfillment-order, rejection-order, unobservable-global-async-evaluation-count-reset, dynamic-import-of-waiting-module}` + `verify-dfs`.

**Fix:** `vm_gen_async.zig:501` now returns `.raw` for module top-level await (genuine suspension via Promise reaction jobs). `module_graph.zig` was rewritten to use a `ModuleContinuation` queue + `drainModuleContinuations` + `hasActiveAsyncDependency` + Promise reaction alternating dispatch, replacing the old synchronous while-loop + per-step `parser.compile`. The entire `top-level-await` directory now passes 251/251.

> **Caveat (mechanism boundary):** the target test262 slice is aligned, but ModuleRecord fields (`dfs_index`, `dfs_ancestor_index`, `cycle_root`, `pending_async_dependencies`, `async_parent_modules`) and the shared top-level capability are NOT yet ported. The 251/251 pass proves target semantics, not that the async module SCC state machine is field-by-field isomorphic with qjs. See IMPL-DIVERGENCE-STATUS §5.4 P1.

### for-await `arguments` — 2 tests — CLOSED

Tests: `for-await-of/{async-func-decl, async-gen-decl}-dstr-obj-id-init-simple-no-strict.js`.

**Fix:** `parser.zig:5408` `ensureImplicitArgumentsLocal` + `arguments_var_idx` now materializes `arguments` ONCE at function scope (parse-time), with the spec `argumentsObjectNeeded` computation (ECMA 10.2.11 steps 19-20: if no parameter expressions AND `arguments` ∈ functionNames/lexicalNames → arguments object is NOT created). The entire `for-await-of` directory now passes 1234/1234.

### async-generator Cluster B — 1 test — CLOSED

Test: `AsyncGeneratorPrototype/return/return-suspendedYield-try-finally-throw.js`.

**Fix:** generator return-through-finally now uses the proper exit point to locate the synthetic rethrow, and that exit point is preserved across dead-code peephole. `AsyncGeneratorPrototype/return` now passes 19/19. Sync/async explicit finally throw and post-close `.next()` have Zig regressions.

### dynamic-import `arrow-function` — 1 test — CLOSED

Test: `dynamic-import/assignment-expression/arrow-function.js`.

**Fix:** `DynamicImportCall` codegen now clears the anonymous-function named-evaluation candidate after emitting the dynamic import, preventing the argument arrow from incorrectly marking the outer declaration as the anonymous function's naming target. The entire `dynamic-import assignment-expression` directory now passes 28/28.

## Cross-cutting lessons (from the 2026-07-04 session, still valid)

- **run-test262 is a separate binary from zjs**; `zig build zjs` does NOT rebuild it. Frequent rebuilds can corrupt zig-cache → run-test262 miscompiles (symptom: `-c` sweep SIGSEGVs ~4000 tests, or `2605/3001 errors`; the zjs engine binary is fine). Fix: `zig build run-test262` clean rebuild. Gate discipline: rebuild BOTH binaries sequentially; real gate results only from a clean rebuild; gate crash → suspect the binary before the code.
- **Worktree-agent + main-tree full-gate is effective risk management** for deep changes: worktree isolation keeps main clean; the full gate catches broad regressions that the agent's dual-engine probes miss (for-await 5, module-TLA 10). Never integrate a worktree patch without re-running the full gate on main. Tell worktree agents: NEVER `zig build test`; NEVER the full 49775 sweep; only targeted `-d`/`-f`.
- The remaining 2 known are both non-zjs-bug items (qjs also fails). Any fix to the `await-using` item should be coordinated with qjs upstream to avoid creating a reverse divergence.
