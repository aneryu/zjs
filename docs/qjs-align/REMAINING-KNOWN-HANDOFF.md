# Remaining test262 known — handoff (2026-07-04)

State at handoff: branch `qjs-align-phaseA`, ahead of main **119**, gate **`0/49775 errors`** + smoke 3/3, **known = 13**. Not pushed (per discipline).
Full per-cluster blueprints (root cause + qjs anchor + exact fix): `docs/qjs-align/KNOWN16-RECON-2026-07-03.md`. Attempt findings + status log: `docs/qjs-align/FIX-PLAN-2026-07-02.md`.

This session reduced known 24→13 (9 fix commits). The remaining 13 (12 fixable + 1 no-align) are the **hard tail**: three incremental worktree attempts this session (for-await arguments, module TLA Steps 1-2, module TLA Step A) were all **net-negative and reverted** — each remaining cluster needs a **complete, focused implementation**, not an incremental one. Main tree stayed clean throughout (worktree isolation + full-gate integration discipline).

## The 13 remaining known

### module TLA — 7 tests — **all-or-nothing keystone (~1000 lines)**
Tests: `top-level-await/{top-level-ticks, top-level-ticks-2, fulfillment-order, rejection-order, unobservable-global-async-evaluation-count-reset, dynamic-import-of-waiting-module}` + `verify-dfs`.
Root cause: module bodies do NOT genuinely suspend at top-level await — `awaitSuspendMode` (src/exec/vm_gen_async.zig:500) returns `.settled`, which synchronously drains the whole promise-job queue inside the await (vm_gen_async.zig:468-479), inverting microtask interleaving vs qjs. The two drivers (eval_entry.zig:162-215 `runEvalModuleWithVarRefs`; module_graph.zig:770-987 `evalPreloadedFileModuleStep`/`ModuleContinuation`/`drainOneModuleContinuation`) re-enter the body in a synchronous while-loop (module_graph.zig even RE-COMPILES source per step at :783).
qjs mechanism: `js_evaluate_module` (quickjs.c:31535) returns a real pending promise; `js_execute_async_module` (:31369) runs the body via `js_async_function_call` so TLA suspends/resumes via reaction JOBS; `js_inner_module_evaluation` (:31423) is the Tarjan DFS; `js_async_module_execution_fulfilled` (:31301) / `rejected` (:31256) settle the promise; `gather_available_ancestors` (:31203) + `rt->module_async_evaluation_next_timestamp++` (:377, two sites) + rqsort give ordering. The faithful async-function driver already exists and works: `promise_ops.zig` `qjsAsyncFunctionStart` (:2798) → `qjsAsyncFunctionAwait` (:2901).
**Correct approach — MUST be done as ONE complete change (Steps 1-5 together):**
- Step 1: module `await` genuinely suspends (`.settled`→`.raw`).
- Step 2: route module body through `qjsAsyncFunctionStart` (compile-once the module function/var_refs, store on the record; delete the sync-drain drivers + per-step `parser.compile`).
- Step 3: ModuleRecord async fields (core/module.zig:77): `.evaluating_async` status + dfs_index, dfs_ancestor_index, stack_prev, async_parent_modules, pending_async_dependencies, async_evaluation, async_evaluation_timestamp, cycle_root, promise, resolving_funcs; + `module_async_evaluation_next_timestamp` on JSRuntime.
- Step 4: port `js_evaluate_module`, `js_inner_module_evaluation` (Tarjan DFS, parent-registration on the CHILD, cycle_root-before-break), `js_execute_async_module`/`execute_sync_module`, `moduleExecutionFulfilled`+`gatherAvailableAncestors`(ascending-timestamp rqsort)+`setModuleEvaluated`, `moduleExecutionRejected` (depth-first parent rejection).
- Step 5: host contract (`hostAwaitPromise` = js_std_await mirror; delete the old sync drivers + host-hooks/dynamic-import copies); dynamic-import chains the evaluation promise into the import capability.
**⚠️ Attempt lessons (this session):**
- Steps 1-2 alone (genuine suspension without Steps 3-5 rejection/DFS) → **+10 regressions** (broke TLA rejection tests: await-expr-reject-throws, dynamic-import-rejection, await-awaits-thenables-that-throw, async-module-does-not-block-sibling-modules — the old `.settled` handled rejection synchronously).
- Even Step A alone (single-module rejection settlement on top of suspension) **could not converge below 5 new errors** — rejection settlement is too coupled to the DFS machinery to isolate. **Do Steps 1-5 together.**
- Blast radius is broad (hundreds of module tests). Requires incremental gating on `-d language/module-code -d language/import -d language/expressions/dynamic-import` at each stage. Reference spec map: KNOWN16-RECON qjs-async-reference finding.

### for-await `arguments` — 2 tests — **needs argumentsObjectNeeded first**
Tests: `for-await-of/{async-func-decl, async-gen-decl}-dstr-obj-id-init-simple-no-strict.js`.
Root cause: a top-level `let`/`var arguments` wrongly competes with a non-arrow function's implicit `arguments`; zjs materializes `arguments` PER-REFERENCE (inline OP_special_object, rvalue reads only, parser.zig:9464-9490; typeof at :7262) instead of ONCE at function scope, so an assignment target `arguments = 4` desyncs onto the outer binding.
Correct approach: materialize once at function scope (mirror qjs `add_arguments_var` quickjs.c:24220, driven from resolve_scope_var; prologue at bytecode.zig:5479 already materializes when `arguments_var_idx` is set). Use PARSE-TIME materialization (avoids the resolve-time prologue-size-mismatch hazard).
**⚠️ Attempt lesson:** a clean parse-time `ensureArgumentsVar` (materialize on any reference) → **+5 regressions** (`arguments-with-arguments-fn.js`×4 + `block-decl-func-skip-arguments.js`). **The fix MUST first implement the spec `argumentsObjectNeeded` computation** (ECMA 10.2.11 steps 19-20: if no parameter expressions AND `arguments` ∈ functionNames/lexicalNames → the arguments object is NOT created and `arguments` refers to the `function arguments(){}` / lexical binding). `ensureFunctionScopeVar(arguments)` also collides with a `function arguments(){}` binding — must keep them distinct. Only materialize when argumentsObjectNeeded is true.

### await-using — 1 test — moderate (4 files, shared chokepoint)
Test: `await-using/await-using-does-not-imply-await-if-not-evaluated.js`.
Root cause: zjs emits an UNCONDITIONAL OP_await at every block-exit of a block textually containing `await using` (parser.zig:11325 `emitUsingDisposeStack`); an unevaluated `await using` (block exited before the declaration) still forces a microtask tick. Must be runtime-conditional on the async DisposableStack being non-empty.
Correct approach: add a non-destructive host probe (new special_object subtype + HostFunction in call.zig + object.zig payload `resources.len != 0`) and gate the trailing Await in `emitUsingDisposeStack`/`emitUsingDisposeStackForThrow` (parser.zig:11317-11342) on it. Touches parser.zig + promise_ops.zig + call.zig + object.zig. High risk: shared using/await-using chokepoint every block-exit path flows through.

### async-generator Cluster B — 1 test — deep (fragile scan → needs gosub/ret rewrite)
Test: `AsyncGeneratorPrototype/return/return-suspendedYield-try-finally-throw.js` (+ latent SYNC-generator equivalent).
Root cause: `.return()` on a generator suspended at `yield` inside try/finally must run the finally; if the finally throws, `.return()` must throw. zjs reconstructs the finally range by SCANNING bytecode — `findGeneratorReturnFinallyTargetFromCatch` (call_runtime.zig:6272) uses `findThrowFrom(catch_target)` (:6317) as the `stop_pc`, but that returns the FIRST OP_throw — which for `finally { throw err }` IS the user's throw, so `stop_before_pc` clips it (the throw never runs; the stashed pending-return is delivered).
Verified: sync `function*(){try{yield 1}finally{throw e}}` `.return('sv')` → zjs `{value:'sv',done:true}`, qjs throws `e`.
Correct approach: the scan heuristic CANNOT reliably distinguish a user throw from the compiler's abrupt-rethrow. **Robust fix = route `.return()`-through-finally via the compiled OP_gosub/OP_ret finally protocol** (bytecode.zig gosub=108/ret=109) instead of the scan, so a throw inside the finally escapes as `error.JSException` into the existing rejection paths (call_runtime.zig:5920 sync / async_generator.zig:381-393 async). Fixes both sync + async generators.

### dynamic-import `arrow-function` — 1 test — deep (reentrancy stack corruption)
Test: `dynamic-import/assignment-expression/arrow-function.js`.
Root cause: `await import(<inline fn>)` inside an async function, where the specifier's ToString requires a re-entrant JS call (user-overridden `Function.prototype.toString`); on resume the async frame reads garbage and surfaces an EMPTY internal Error that bypasses the async function's try/catch. Isolation matrix: fails only with async + user-override toString.
Correct approach: `dynamicImport`'s reentrant `toStringForAnnexB` must snapshot/restore the operand-stack watermark around the reentry the same way the generic OP_call path does (compare vm_call reentry vs dynamicImport's raw vm.stack pop/push). vm_eval_module.zig / vm_call.zig.

### import-attributes `type:text` — 1 test — **NO-ALIGN (keep known)**
Test: `dynamic-import/import-attributes/2nd-param-with-type-text.js`.
Not a bug to fix: zjs implements text modules for STATIC import (string, passes 5 static tests) but the DYNAMIC path (`importLoaderTypeFromAttributes`, module_graph.zig:66-84, enum only `{none,json}`) is **deliberately qjs-faithful** — qjs 04be246 has no text-module support (dynamic gives number/JSON). Adding dynamic text would DIVERGE from qjs. Leave as known.

## Cross-cutting lessons (this session)
- **run-test262 is a separate binary from zjs**; `zig build zjs` does NOT rebuild it. Frequent rebuilds can corrupt zig-cache → run-test262 miscompiles (symptom: `-c` sweep SIGSEGVs ~4000 tests, or `2605/3001 errors`; the zjs engine binary is fine). Fix: `zig build run-test262` clean rebuild. Gate discipline: rebuild BOTH binaries sequentially; real gate results only from a clean rebuild; gate crash → suspect the binary before the code.
- **Worktree-agent + main-tree full-gate is effective risk management** for deep changes: worktree isolation keeps main clean; the full gate catches broad regressions that the agent's dual-engine probes miss (for-await 5, module-TLA 10). Never integrate a worktree patch without re-running the full gate on main. Tell worktree agents: NEVER `zig build test`; NEVER the full 49775 sweep; only targeted `-d`/`-f`.
- These remaining clusters are all complete-implementation type — do not attempt incrementally.
