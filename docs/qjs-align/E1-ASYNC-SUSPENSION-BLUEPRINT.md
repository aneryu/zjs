# E1 — ASYNC-SUSPENSION KEYSTONE BLUEPRINT (ground-truth synthesized)

Status: **BLUEPRINT — approved ground truth, implementation not started.**
Provenance: synthesized 2026-07-03 from four ground-truth reports (qjs async-function
machinery · qjs async-generator machinery · qjs module-TLA + host loop · zjs current
async model survey), each anchor re-verified against qjs @ `04be246`
(/home/aneryu/quickjs/quickjs.c) and zjs branch `qjs-align-phaseA` @ `8ba31e7`.
Every quickjs.c / zjs `file:line` below was checked in-source during synthesis; an
implementer must NOT need to re-derive ground truth, only re-confirm line drift.

Discipline (keystone rules, binding):
- **One-shot to final state.** No flag-gated intermediate modes, no dual dispatch
  paths, no "legacy fallback". The `AwaitSuspendMode` enum is *deleted*, not extended.
- Root-cause only; mirror quickjs.c mechanism/structure (commit messages cite
  `quickjs.c fn:line`); zjs frame-model differences are *faithful adaptations*, called
  out explicitly in §3.0.
- RED LINE: `test262` gate stays `Result: 0/49775 errors`; known list may only SHRINK
  (report fixed count). Force-GC probe suite must stay green.
- Never push.

---

## 0. Thesis

qjs has exactly **one** suspension primitive: a heap-saved interpreter frame
(`JSAsyncFunctionState`, quickjs.c:784-794) that `OP_await`/`OP_yield*` park by saving
`cur_pc`/`cur_sp` (done_generator, quickjs.c:20695-20697) and that promise-reaction
**jobs** later resume. The engine **never** drains the job queue itself —
`JS_ExecutePendingJob` (quickjs.c:2303) appears in quickjs.c only as its definition;
the sole callers are the host loop (quickjs-libc.c:4299/4334). Suspension = return
control to caller; progression = host-pumped microtasks.

zjs today has **four** await modes (`AwaitSuspendMode`, vm_gen_async.zig:22-32,
selected at vm_gen_async.zig:494-499):

| mode | used by | behavior | verdict |
|---|---|---|---|
| `.raw` | async functions | real suspension + `Promise.resolve().then(resume)` — mirrors qjs | KEEP (template) |
| `.drain` | async generators | **synchronously drains the whole job queue inside `.next()`** at every internal await; still-pending → resume with `undefined` | DELETE |
| `.settled` | module TLA | drains synchronously, then fake-suspends with the already-settled value; module re-entry loop; file-graph path **recompiles the module source per step** | DELETE |
| `.none` | non-entry frames | resumes immediately | DELETE (single semantics) |

Live-verified divergences (dual-engine probes, /tmp/e1_probe*.js):
(a) `async function* g(){ const v = await new Promise(()=>{}); … }` — zjs resumes with
`undefined` and yields; qjs stays pending forever (vm_gen_async.zig:466-467).
(b) async-gen `await Promise.resolve(0)` before `yield`: zjs prints continuation
*before* the synchronous script tail (drain runs inside `.next()`); qjs after, on a
microtask. (c) async-gen step vs 3-deep `.then` chain: zjs delivers after micro1, qjs
after micro3. (d) plain async-function interleaving matches qjs exactly — the `.raw`
path + `ctx.pending_promise_jobs` queue is already faithful.

**E1 = collapse the four modes to the one qjs model**: every `await`/async-gen
step/TLA step genuinely suspends and returns control; all progression happens through
`ctx.pending_promise_jobs` pumped only from host boundaries; async generators get the
`AsyncGeneratorRequest` queue + 6-state machine; modules get promise-returning
evaluation with the qjs async-DFS bookkeeping.

---

## 1. qjs ground truth — the complete mechanism map (all anchors @ 04be246)

### 1.1 The saved-frame primitive (shared by async fn / sync gen / async gen)

- `JSAsyncFunctionState` quickjs.c:784-794 — GC object (JS_GC_OBJ_TYPE_ASYNC_FUNCTION)
  embedding `JSStackFrame` + `this_val, argc, throw_flag, is_completed,
  resolving_funcs[2]`; arg/var/stack bufs + var_refs follow **in the same allocation**.
  The interpreter runs *in* this heap buffer from the first instruction — suspension is
  O(1), no copying.
- `async_func_init` quickjs.c:20893-20935 — single malloc; `sf->js_mode |= JS_MODE_ASYNC`
  (the marker by which var-ref machinery recognizes heap frames); `cur_pc = byte_code_buf`.
- `async_func_resume` quickjs.c:20951-20986 — stack-overflow guard, then re-enters
  `JS_CallInternal` with `func_obj = JS_MKPTR(JS_TAG_INT, s)` + `JS_CALL_FLAG_GENERATOR`.
  Completion detected by return value: exception or `JS_UNDEFINED` (OP_return_async);
  suspensions return int `FUNC_RET_*`. On completion: real return value read from
  `cur_sp[-1]`, `is_completed=TRUE`, `close_var_refs`, `async_func_free_frame`.
- `JS_CALL_FLAG_GENERATOR` entry branch quickjs.c:17787-17813 — rebinds sp/pc/bufs from
  the frame, `sf->cur_sp = NULL` ("running" sentinel used by GC mark, 6641-6650), links
  into `rt->current_stack_frame`, then `throw_flag ? goto exception : goto restart`.
  **throw() injection = pending exception + jump to the frame's exception handler.**
- Suspension opcodes quickjs.c:17735-17738 (FUNC_RET codes), 20592-20607 (OP_await /
  OP_yield / OP_yield_star / OP_async_yield_star / OP_return_async / OP_initial_yield),
  done_generator epilogue 20690-20710 (persist pc/sp; locals deliberately NOT freed).
  `OP_await` does NOT pop its operand — it stays at `sp[-1]` as the resume slot.
- GC/var-ref pinning: `JS_MODE_ASYNC` + `container_of` — get_var_ref incref
  quickjs.c:17037-17045, close_var_ref 17522-17526, free_var_ref 6172-6178, gc mark
  6631-6650 (stack slots walked only when `cur_sp != NULL`, i.e. suspended not running).
- Teardown: `async_func_free` / `__async_func_free` quickjs.c:20988-21018 — pure decref;
  destructor frees frame values only if `!is_completed`; REMOVE_CYCLES-aware.

### 1.2 Async functions

- `js_async_function_call` quickjs.c:21319-21341 (class call, registered 54648):
  `async_func_init` → `JS_NewPromiseCapability(ctx, s->resolving_funcs)` (result
  promise) → `js_async_function_resume` (body runs **synchronously to first
  await/return**) → `async_func_free` → return promise. Exceptions before first await
  reject the promise, never throw synchronously.
- `js_async_function_resume` quickjs.c:21238-21291: completed → settle
  `resolving_funcs[0/1]` via plain `JS_Call`. Awaiting → operand popped from
  `frame.cur_sp[-1]` (slot cleared, becomes the resume slot);
  `js_promise_resolve(ctx->promise_ctor, value)` (spec PromiseResolve — genuine promise
  with `.constructor === %Promise%` reused, 53794-53803; thenable → one
  `js_promise_resolve_thenable_job`, 53626); fresh RESOLVE/REJECT closure pair
  (`js_async_function_resolve_create` 21215-21236, classes
  JS_CLASS_ASYNC_FUNCTION_RESOLVE/REJECT, each holds a strong ref on `s`); attached via
  `perform_promise_then` with an **UNDEFINED capability** — qjs extension, no throwaway
  promise ("no need to create 'thrownawayCapability'"), honored in promise_reaction_job
  53413-53422.
- `js_async_function_resolve_call` quickjs.c:21293-21317: `is_reject` from class-id
  arithmetic; `s->throw_flag = is_reject`; reject → `JS_Throw(dup(arg))` now; fulfill →
  write arg directly into `s->frame.cur_sp[-1]`; then `js_async_function_resume` again.
- **No synchronous drain anywhere**: settlement paths only `list_add_tail` via
  `JS_EnqueueJob2` (quickjs.c:2263-2291); resume always happens ≥1 microtask later.

### 1.3 Async generators

- States quickjs.c:21345-21352: `SUSPENDED_START, SUSPENDED_YIELD,
  SUSPENDED_YIELD_STAR, EXECUTING, AWAITING_RETURN, COMPLETED`. YIELD_STAR is distinct
  because a `throw()` delivered while delegating must NOT set `throw_flag` — the
  compiled yield* loop forwards the completion to the inner iterator itself (resume
  with completion int = 2). `func_state == NULL` in AWAITING_RETURN/COMPLETED.
- `JSAsyncGeneratorRequest` quickjs.c:21354-21361: intrusive list node +
  `completion_type` (GEN_MAGIC_NEXT=0/RETURN=1/THROW=2, quickjs.c:21073-21075) +
  `result` + full promise capability (`promise`, `resolving_funcs[2]`).
  `JSAsyncGeneratorData` 21362-21370: `generator` back-pointer, `state`, `func_state`,
  `queue`. Free/finalizer/mark: 21372-21418.
- Construction `js_async_generator_function_call` quickjs.c:21749-21781 (registered
  54651): state=SUSPENDED_START; `async_func_init` + resume **up to OP_initial_yield**
  (arg binding, no await possible); generator object via `js_create_from_ctor` with
  class JS_CLASS_ASYNC_GENERATOR.
- Enqueue `js_async_generator_next` quickjs.c:21706-21747 — **one C function** for
  next/return/throw with GEN_MAGIC magic (proto table 54617-54622). Always creates the
  request's promise capability FIRST (observable via then-getter-ticks tests);
  brand-check failure **rejects that promise** with TypeError, doesn't throw
  (21717-21728); appends to queue; `if (state != EXECUTING) resume_next` — a call
  arriving during EXECUTING (reentrant next) **only appends**; the running drain loop
  picks it up.
- State machine `js_async_generator_resume_next` quickjs.c:21568-21668 — head-of-queue
  FIFO loop until queue empty or parked:
  - EXECUTING → `goto resume_exec` (re-entered from the await trampoline).
  - AWAITING_RETURN → `goto done` (frozen; requests stay queued).
  - SUSPENDED_START + NEXT → exec, no value pushed; + RETURN/THROW →
    `js_async_generator_complete` then loop (same request re-handled as COMPLETED).
  - COMPLETED: NEXT → resolve `{undefined, true}`; RETURN → state=AWAITING_RETURN +
    `js_async_generator_completed_return(next->result)` (**awaits the argument**);
    THROW → reject with the argument; then `goto done`.
  - SUSPENDED_YIELD / _YIELD_STAR: THROW while SUSPENDED_YIELD → `JS_Throw` +
    `throw_flag=TRUE`. Otherwise push **TWO** slots into the frame:
    `cur_sp[-1] = value; cur_sp[0] = JS_NewInt32(completion_type); cur_sp++`
    (21611-21614) — consumed by the compiled yield/yield* bytecode. state=EXECUTING.
  - resume_exec: `async_func_resume`. is_completed: exception → complete +
    reject(GetException); normal → complete + resolve(func_ret, done=TRUE). Else pop
    value from `cur_sp[-1]` (slot := UNDEFINED): FUNC_RET_YIELD/_YIELD_STAR → set
    SUSPENDED_YIELD or SUSPENDED_YIELD_STAR (21642-21645), resolve `{value, false}`,
    **LOOP** (next request processed immediately); FUNC_RET_AWAIT →
    `js_async_generator_await(value)`; failure → `throw_flag=TRUE; goto resume_exec`;
    success → `goto done` (parked EXECUTING until trampoline fires).
- Settlement quickjs.c:21481-21518: always pops the queue **head** (promise order ==
  call order), `JS_Call(next->resolving_funcs[is_reject], …)`; resolve wraps in a fresh
  `js_create_iterator_result` (16768-16789) per request.
- `js_async_generator_await` quickjs.c:21446-21479: PromiseResolve(value) +
  `perform_promise_then` onto trampoline pair, UNDEFINED capability (same extension as
  async fn); generator identity via `func_data[0]` = the generator OBJECT.
- Trampolines `js_async_generator_resolve_function` quickjs.c:21670-21703 — one C
  function, magic = `is_reject | (is_resume_next << 1)`:
  - magic 0/1 (await resume): guarded by `state == EXECUTING` (stale trampolines after
    completion are no-ops); write arg to `cur_sp[-1]` or `throw_flag`+`JS_Throw`; then
    `js_async_generator_resume_next`.
  - magic 2/3 (AWAITING_RETURN resume): assert AWAITING_RETURN||COMPLETED; state =
    COMPLETED; settle the head request (`resolve(arg, done=TRUE)` / `reject(arg)`).
    **VERIFIED IN SOURCE: there is NO resume_next call after the magic>=2 settlement**
    — remaining queued requests are only drained by later next()/return()/throw()
    calls. The spec (AsyncGeneratorDrainQueue) would continue; qjs does not. Mirror qjs
    exactly; see risk R5.
  - `/* XXX: what if s == NULL */` (21679) — unhandled in qjs; zjs may keep a defensive
    no-op with a comment.
- Completion quickjs.c:21520-21566: `complete` frees the frame immediately
  (`func_state=NULL`); `completed_return` = spec AsyncGeneratorAwaitReturn:
  PromiseResolve(return arg); **poisoned `Promise.constructor` edge** (comment
  21537-21541): if PromiseResolve throws, catch and build a REJECTED promise from the
  error instead (so it reaches the request promise as rejection via magic=3); then
  perform_promise_then with magic 2/3 trampolines.
- Compiled forms:
  - plain `yield` in async gen: **parser emits OP_await BEFORE OP_yield**
    (quickjs.c:28131-28140) — the yield operand is awaited. After resume, completion
    int tested: `if_false` (NEXT=0) continue, else `emit_return(TRUE)`.
  - `emit_return` for async gens quickjs.c:28392-28445: **OP_await the return value
    BEFORE unwinding finally** (comment 28402-28404); enclosing for-of iterators get
    inline AsyncIteratorClose with OP_await after the `.return()` call (28422-28440);
    ends OP_return_async (28475).
  - `yield*` fully compiled inline quickjs.c:28031-28130: OP_for_await_of_start; loop
    { OP_iterator_next; OP_await; OP_iterator_check_object; get .done; … }; async
    extracts `.value` first then OP_async_yield_star (yields the plain value; the
    {value,done} wrapper for the caller is rebuilt by js_async_generator_resolve);
    both OP_yield_star/OP_async_yield_star return FUNC_RET_YIELD_STAR → state
    SUSPENDED_YIELD_STAR. return-completion(1): await arg, OP_iterator_call 0
    (iter.return), await, done? → extract .value + emit_return; throw-completion(2):
    OP_iterator_call 1 (iter.throw), missing → OP_iterator_call 2 + OP_await +
    OP_throw_error "throw is not a method".
  - for-await-of quickjs.c:28812-28883: OP_for_await_of_next (disables catch-offset so
    exceptions while awaiting don't close the iterator, js_for_await_of_next
    16713-16726) → OP_await → OP_iterator_get_value_done (restores catch-offset,
    16747-16766).

### 1.4 AsyncFromSyncIterator

- `JS_GetIterator(is_async=TRUE)` quickjs.c:16513-16545: try @@asyncIterator; fall back
  to @@iterator → build sync iterator → `JS_CreateAsyncFromSyncIterator`.
- Creation quickjs.c:54394-54447: wrapper object class
  JS_CLASS_ASYNC_FROM_SYNC_ITERATOR caching `sync_iter` **and its `.next` method (read
  once at creation)**; proto chains to %AsyncIteratorPrototype% (54685-54691).
- `js_async_from_sync_iterator_next` quickjs.c:54484-54607 — one function, magic =
  GEN_MAGIC next/return/**throw** (proto table 54603-54607). Own capability first;
  brand failure rejects. next uses the cached method; return/throw re-read each call;
  **absent return → resolve `{arg, done:true}`; absent throw → IteratorClose(sync_iter)
  then reject TypeError "throw is not a method"** (54510-54520). Sync result →
  PromiseResolve wrap → perform_promise_then with onFulfilled = unwrap closure
  (`js_async_from_sync_iterator_unwrap` 54449-54456, builds {value, done:captured}) and
  onRejected = **close-wrap closure only when `!done && magic != RETURN`**
  (`js_async_from_sync_iterator_close_wrap` 54468-54476: re-throw, IteratorClose,
  return exception). PromiseResolve throw → close sync_iter (same guard) + reject.

### 1.5 Module TLA

- **Every JS module body is compiled as an async function**: parser sets
  `func_kind=JS_FUNC_ASYNC` for modules unconditionally (quickjs.c:37258-37261);
  `has_tla = fd->has_await` recorded separately (37277) and serialized (37959/39047).
- `JSModuleDef` async tail quickjs.c:910-937: `has_tla`, `status` (enum 879-886:
  UNLINKED/LINKING/LINKED/EVALUATING/**EVALUATING_ASYNC**/EVALUATED),
  `dfs_index/dfs_ancestor_index/stack_prev` (Tarjan temps),
  `async_parent_modules[+count+size]`, `pending_async_dependencies`,
  `async_evaluation` + `async_evaluation_timestamp` (int64, = spec
  [[AsyncEvaluationOrder]], source: runtime-global monotonic counter
  `rt->module_async_evaluation_next_timestamp`, quickjs.c:377), `cycle_root`,
  `promise` + `resolving_funcs[2]` (= spec [[TopLevelCapability]], **exists only on
  cycle roots**), `eval_has_exception`/`eval_exception`.
- `js_evaluate_module` quickjs.c:31535-31592: redirect to `cycle_root`; memoized
  `m->promise` (re-eval returns same promise); run `js_inner_module_evaluation`;
  failure → unwind SCC stack marking each EVALUATED + store exception + reject
  capability; success → if `!async_evaluation` resolve immediately, else promise stays
  PENDING (settled later from a job). **Returns the promise; zero job draining.**
- `js_inner_module_evaluation` quickjs.c:31421-31531 (spec InnerModuleEvaluation):
  stack-overflow guard; EVALUATING_ASYNC/EVALUATED → return stored exception or index;
  EVALUATING → return index (cycle); mark EVALUATING, dfs indices, push. DFS over
  requested modules; child (or its cycle_root) with `async_evaluation` → parent
  `pending_async_dependencies++` AND parent appended to **child's**
  `async_parent_modules` (31486-31493). Then: pending deps > 0 → become async
  (timestamp), body **NOT run** (deferred); else `has_tla` → become async + timestamp +
  `js_execute_async_module` NOW; else `js_execute_sync_module`. SCC pop: each popped
  module gets status EVALUATED or EVALUATING_ASYNC keyed on `async_evaluation`, and
  `cycle_root = m` assigned BEFORE the break test ("spec bug" comment 31523).
- `js_execute_async_module` quickjs.c:31362-31382: body promise =
  `js_async_function_call(m->func_obj)`; then'd with two JS_NewCFunctionData handlers
  capturing the module value → `js_async_module_execution_fulfilled/rejected` run as
  **jobs**.
- `js_execute_sync_module` quickjs.c:31384-31419: C module init directly; JS body via
  the same `js_async_function_call`; promise must be already settled — FULFILLED ok,
  REJECTED → error out, PENDING → defensive TypeError "promise is pending".
- `js_async_module_execution_fulfilled` quickjs.c:31301-31360 + helpers 31173-31242:
  idempotent (EVALUATED → assert eval_has_exception, no-op); clear async_evaluation;
  `js_set_module_evaluated` (status=EVALUATED + resolve capability if cycle root);
  `gather_available_ancestors` (31203-31234: skip already-collected / failed cycle
  roots; `pending_async_dependencies--`; hit 0 → append; recurse only through
  **non-TLA** parents); sort ready ancestors **ascending by timestamp** (rqsort,
  31236-31242); execute each: TLA → `js_execute_async_module`, sync →
  `js_execute_sync_module` inline (failure routes into …rejected). Whole cascade runs
  inside ONE reaction job.
- `js_async_module_execution_rejected` quickjs.c:31256-31299: idempotent; store
  exception; status=EVALUATED; reject own capability if cycle root; **depth-first
  recursively reject every async parent with the same error** (parents do not
  decrement pending counts on error).
- Dynamic import: `js_dynamic_import` enqueues `js_dynamic_import_job`
  (quickjs.c:31153-31155 — explicit comment: synchronous load would recurse into
  js_evaluate_module); job → `JS_LoadModuleInternal` (30973-31017) → eval → then the
  evaluation promise into the import()'s capability, resolving with the **namespace**
  only after the whole TLA subgraph settles (30952-30970).
- Host loop: qjs.c eval_buf (49-76) — modules: COMPILE_ONLY → JS_EvalFunction →
  **js_std_await** (quickjs-libc.c:4317-4351: loop on JS_PromiseState; while PENDING
  run JS_ExecutePendingJob; queue empty → rejection check + os_poll; REJECTED →
  JS_Throw). After all files: js_std_loop (quickjs-libc.c:4292-4312: drain all jobs,
  rejection check, block in os_poll until no handlers).

---

## 2. zjs current state — what exists (anchors @ 8ba31e7)

### 2.1 The one real suspension mechanism (sync-generator buffer swap) — REUSED

`saveGeneratorExecutionState` (vm_gen_async.zig:64-103) /
`resumeExecutionStateRaw` (117-197): suspension = ownership transfer of the operand
stack buffer + frame storage (locals/args/var_refs slices) into Object slots on the
generator/continuation object, plus pc into `generatorPcSlot`. Requires heap-backed
stack (`assert !stack.arena_window`, :74 — `arena_eligible` only for `.normal` kind,
call_runtime.zig:5350). This is zjs's faithful adaptation of `JSAsyncFunctionState`:
qjs keeps the frame in one heap allocation and re-enters it; zjs transfers buffers into
a continuation object and re-enters `runWithArgsState`. **Both are one native frame
per resume — keep this shape.**

Known substrate weaknesses to fix in E1 (they become live under many-await suspension):
- `activeCatchTargetForPc` (vm_gen_async.zig:501-518) reconstructs the catch target by
  linear-scanning ALL bytecode from 0 to pc on every resume → replace with a persisted
  slot written at save time.
- `resume_needs_branch_false` (:137-142) sniffs `code[pc] == if_false/if_false8` to
  decide the push protocol → replace with an explicit saved resume-shape enum
  (yield / yield_star / await / initial) written at save time.

### 2.2 The four modes and their sites

- `AwaitSuspendMode` enum vm_gen_async.zig:22-32; selector `awaitSuspendMode`
  :494-499 (module → .settled; async fn → .raw; async gen (stop_on_yield) → .drain;
  else .none).
- `awaitValueRaw` vm_gen_async.zig:423-476 — the divergence core: :437-441 = the
  faithful `.raw` suspend; :464 `settlePendingPromiseReaction`; :465 in-VM
  `drainPendingPromiseJobs` for .settled/.drain; :466 `awaitPendingPromise`
  (1 ms sleep-poll for Atomics.waitAsync promises); :467 **resume-with-undefined**.
- Suspension only at `machine.depth == 0` (zjs_vm.zig:2107-2132 op dispatch;
  stop_before_pc :871): inlined callees pass null generator state. Async/generator
  bodies always enter via a fresh `runWithArgsState`
  (callFunctionBytecodeModeState routes .generator/.async_generator/.async around the
  inline-call fast path, call_runtime.zig:5339-5360). **Invariant to keep + assert.**

### 2.3 Async functions — the faithful path (promise_ops.zig:2796-2957)

`qjsAsyncFunctionStart` (2796): native result promise up front → continuation object →
`qjsAsyncFunctionRunAndSettle`. `RunState` (2820-2844) re-enters runWithArgsState with
`suspend_on_module_await=true` (→ .raw). `qjsAsyncFunctionAwait` (2899-2923) mirrors
js_async_function_resume 21268-21290: `Promise.resolve(awaited)` + two
`.async_function_resume`-tagged native callbacks (continuation + rejected flag) via
internal `qjsPerformPromiseThen` with undefined resolving funcs. Resume dispatch:
call_runtime.zig:516 → `qjsAsyncFunctionResumeCallbackCall` (2940). Divergences even
here: fresh `makeBytecodeView` per resume (acceptable adaptation);
`clearHandledRejectionException` (2895) papers over exception-slot leakage — remove at
root during E1 if the root cause is the drain model, else keep with a written
justification.

### 2.4 Async generators — the .drain model (call_runtime.zig:5441-5660)

`qjsGeneratorNext` (5441-5516): brand + `generatorExecuting() → error.TypeError`
(:5451 — qjs enqueues instead); body runs synchronously to next yield;
`finishAsyncGeneratorStep` (5564-5660) awaits the yield operand via
`awaitAsyncGeneratorOperand` (5523-5549: settle at 5531, **drain at 5532**, sleep-poll
at 5533) and loops re-entering the body. No request queue; result promises minted
AFTER the run (fulfilledWithPrototype :5367-5370) instead of capability-first.
B7 already aligned semantics runtime-side (yield operand awaited, return(v) awaited,
finally-yield pending return) — E1 moves the await to **parser emission** (§1.3) and
replaces the driver with the queue machine.

### 2.5 Module TLA — two parallel drivers, both fake

- ctx.eval module mode: `runEvalModuleWithVarRefs` (eval_entry.zig:162-215) loops
  `runModuleWithOutputAndVarRefsState` with a bare generator-class continuation;
  resume value = already-settled result (drained in-VM before suspension); extra host
  drain at :208. eval blocks until module completion; caller never sees a pending
  promise.
- File graph (CLI): `ModuleContinuation{source, path, continuation, awaited}`
  (module_graph.zig:35-57) stores **raw source text**; `drainOneModuleContinuation`
  (:729-773, drain at :759) → `evalPreloadedFileModuleStep` (:556-638) **re-parses via
  parser.compile (:569)** and rebuilds module_var_refs per resume step; readiness via
  `recordHasActiveAsyncDependency` graph walk (:788).
- `core.module.ModuleRecord` (core/module.zig:77-100) already has `status`
  (unlinked/linking/linked/evaluating/evaluated/errored — **no evaluating_async**),
  `has_top_level_await`, `eval_exception` (mirrors qjs eval_has_exception per its own
  doc comment). Missing: all qjs async-DFS fields (§1.5).
- Dynamic import already defers to a job faithfully (module_graph.zig:151-252 mirrors
  js_dynamic_import); only the CLI installs the callback (zjs.zig:239); the test262
  runner never does → 273 known errors (out of E1 scope, see §6).

### 2.6 Job queues — three of them

1. `ctx.pending_promise_jobs` (core/context.zig:385-405) — the real queue:
   `PendingPromiseJob{sequence: u64, value: JSValue}`, FIFO, GC-traced, sequence from
   `rt.nextJobSequence`. **KEEP as the single queue.**
2. Runtime finalization jobs (runtime.zig:2216-2236) — merged into the drain by
   sequence. **KEEP (merge semantics preserved).**
3. LEGACY `rt.job_queue` (core/jobs.zig:8-121, native fn-ptr Queue) — only feeds
   `core.promise.enqueueReaction` (core/promise.zig:780); run by
   binding runJobs (:505) and module_graph runJobs (:290), NOT by
   drainPendingPromiseJobs. **DELETE** (migrate enqueueReaction to
   pending_promise_jobs; core/promise.zig narrow combinators at :316-492 are
   superseded — audit reachability via staticCall while deleting).

`drainPendingPromiseJobs` (promise_ops.zig:3721-3779) is simultaneously the host event
loop (merges queues 1+2 by sequence, then loops OS signal/rw/timer handlers) AND is
re-entered from inside VM execution — the exact opposite of qjs. Legacy lazy path:
single-slot `promiseReactionCallback/Arg` pair set by qjsPerformPromiseThen
(:3476-3482, Atomics.waitAsync only) and test fixtures (:3680); force-fired
synchronously by `settlePendingPromiseReaction` (:3572-3646) from every await site and
every drain iteration (:3765); `awaitPendingPromise` (:3704-3719) sleep-polls 1 ms per
iteration. **All DELETE** (§3.6, §4.6).

### 2.7 Complete `drainPendingPromiseJobs` call-site inventory and fate

Verified by grep @ 8ba31e7 (11 occurrences):

| # | site | role | fate |
|---|------|------|------|
| 1 | promise_ops.zig:3721 | definition (jobs + OS handlers, in one fn) | SPLIT: `executePendingJob(ctx)` = run exactly ONE job (min-sequence of promise vs finalization queue; no OS polling; mirrors JS_ExecutePendingJob quickjs.c:2303) + `hostRunJobs` = loop executePendingJob until empty, then OS signal/rw/timer handlers (current drain semantics, host-only) |
| 2 | zjs_vm.zig:2543 | `pub const` re-export | KEEP → points at `hostRunJobs` |
| 3 | vm_gen_async.zig:465 | in-VM await drain (.settled/.drain) | **DELETE** (with the whole 442-476 block) |
| 4 | call_runtime.zig:5532 | in-VM async-gen operand drain (`awaitAsyncGeneratorOperand`) | **DELETE** (helper dies) |
| 5 | promise_ops.zig:3831 | in-VM drain in `awaitThenableValue` | **DELETE** (thenable adoption already enqueues a job per D2; a pending wrapper = genuine suspension) |
| 6 | promise_ops.zig:3922 | unit test "promise enqueues reactions and executes jobs via engine" | KEEP (host-position; retarget to hostRunJobs/executePendingJob) |
| 7 | eval_entry.zig:139 | host drain after every ctx.eval | **KEEP** (host boundary; load-bearing for fire-and-forget async in tests) |
| 8 | eval_entry.zig:208 | TLA re-entry loop drain | **DELETE** (with `runEvalModuleWithVarRefs` loop) |
| 9 | binding/context.zig:507 | ctx.runJobs host API | **KEEP** (drop the companion legacy `rt.job_queue.runAll()` at :505) |
| 10 | module_graph.zig:292 | module-graph runJobs | **KEEP** (drop legacy runAll at :290) |
| 11 | module_graph.zig:759 | `drainOneModuleContinuation` | **DELETE** (function dies with ModuleContinuation) |

Companion in-VM sync-settle sites, all DELETE with their hosts:
`settlePendingPromiseReaction` calls at vm_gen_async.zig:464, call_runtime.zig:5531,
promise_ops.zig:3076 (asyncDispose), promise_ops.zig:3765 (drain loop; the slot
mechanism itself dies), promise_ops.zig:3686 (its own unit test — delete with fn);
`awaitPendingPromise` calls at vm_gen_async.zig:466, call_runtime.zig:5533,
promise_ops.zig:3077.

---

## 3. Target architecture — fn-by-fn mapping

### 3.0 Frame-model adaptations (declared up front, per code-level-faithful discipline)

| qjs mechanism | zjs faithful adaptation | why acceptable |
|---|---|---|
| `JSAsyncFunctionState` single heap allocation, interpreter runs in it | continuation Object + buffer-ownership transfer (`saveGeneratorExecutionState`) + fresh `runWithArgsState` per resume | both = one native activation per resume; zjs Object slots are the GC-traced equivalent of the state struct; buffer swap is O(1) like qjs |
| `JS_MKPTR(JS_TAG_INT, s)` smuggled func_obj + JS_CALL_FLAG_GENERATOR | `generator_state` parameter threading into runWithArgsState | same role: "the stack frame is already allocated" |
| `sf->cur_sp = NULL` running sentinel (GC skips live stack while running) | `generatorExecutingSlot` bit + buffers owned by the live Stack while running (slots emptied) | equivalent observable: suspended values traced via object slots, running values via VM stack roots |
| var_refs `container_of` incref on state | closure cells already keep zjs frames alive via cell boxing; suspended buffers live in traced Object slots | verify with force-GC probes (§5.3) |
| resume `goto exception` on throw_flag | `generatorResumeCompletionType==2` → `completeResumeState` throws into the frame (vm_gen_async.zig:199) | already the B7-aligned mechanism |

Everything else mirrors qjs structurally, function-for-function.

### 3.1 Await (the single semantics replacing 4 modes)

| qjs | zjs target |
|---|---|
| OP_await handler quickjs.c:20592 (push nothing, save pc/sp, return FUNC_RET_AWAIT) | `awaitValue` → always `suspendAwaitValue` at the entry frame: save state, mark just-yielded, return `.{ .return_value = awaited }` (today's .raw branch, vm_gen_async.zig:437-441, becomes the only branch) |
| caller discriminates FUNC_RET_AWAIT | caller (async-fn driver / async-gen resumeNext / module driver) sees just-yielded + not-done and routes to its await wiring |

`awaitSuspendMode` + the enum are deleted. `machine.depth == 0` remains the only
suspension site; add `std.debug.assert` that an `op.await` in an
async/generator/module function never executes at depth > 0 (audit
callFunctionBytecodeModeState routing while writing it).

### 3.2 Async functions (KEEP — reference implementation, minor cleanup)

| qjs fn | zjs fn (exists) | change |
|---|---|---|
| js_async_function_call 21319 | qjsAsyncFunctionStart promise_ops.zig:2796 | none (capability-first + sync-run-to-first-await already faithful) |
| js_async_function_resume 21238 | qjsAsyncFunctionRunAndSettle 2846 + qjsAsyncFunctionAwait 2899 | none structural; delete `clearHandledRejectionException` (2895) if root cause was drain reentrancy |
| js_async_function_resolve_create 21215 | `.async_function_resume` tagged callbacks | none |
| js_async_function_resolve_call 21293 | qjsAsyncFunctionResumeCallbackCall 2940 | none |

### 3.3 Async generators (REWRITE — the queue machine)

New module section (recommended: `src/exec/async_generator.zig`, or a clearly-fenced
section in promise_ops.zig — pick one, do not scatter):

| qjs | zjs target fn | notes |
|---|---|---|
| JSAsyncGeneratorStateEnum 21345 | `AsyncGeneratorState` enum {suspended_start, suspended_yield, suspended_yield_star, executing, awaiting_return, completed} | stored in async-generator side data |
| JSAsyncGeneratorData 21362 | `AsyncGeneratorData` heap side-struct referenced from the generator Object (opaque slot, like today's continuation wiring): `{ state, func_state: ?continuation Object ref, queue: request list }` | `func_state == null` in awaiting_return/completed |
| JSAsyncGeneratorRequest 21354 | `AsyncGeneratorRequest { completion: enum(next/return/throw), result, promise, resolving_funcs[2], next: ?*Request }` | FIFO singly-linked or ArrayList; 4 JSValues GC-traced |
| js_async_generator_function_call 21749 | `asyncGeneratorFunctionCall` replacing the current .async_generator route in callFunctionBytecodeModeState | run to op.initial_yield eagerly; state=suspended_start |
| js_async_generator_next 21706 (magic) | `asyncGeneratorNext(ctx, gen, magic, arg)` — single fn behind .next/.return/.throw builtins | capability FIRST; brand fail → reject that promise (not throw); append; `state != executing → resumeNext`; **replaces the error.TypeError at call_runtime.zig:5451** |
| js_async_generator_resume_next 21568 | `asyncGeneratorResumeNext` | mirror the state machine verbatim incl. two-slot resume push (value + completion int) and the loop-on-yield behavior; suspended_yield + THROW → throw-into-frame; suspended_yield_star + THROW → resume with completion int 2 |
| js_async_generator_resolve_or_reject/resolve/reject 21481 | `asyncGeneratorSettleHead` (+ iterator-result wrapper) | always pops head; fresh {value,done} per request |
| js_async_generator_await 21446 | `asyncGeneratorAwait` | PromiseResolve + qjsPerformPromiseThen with undefined capability; trampolines carry the generator OBJECT |
| js_async_generator_resolve_function 21670 (magic 0-3) | `.async_generator_resolve`-tagged native callbacks, magic = is_reject | (is_resume_next<<1), dispatched in call_runtime.zig:516 area | magic<2 guarded by state==executing; **magic>=2 settles head only, NO resumeNext after (mirror qjs; risk R5)** |
| js_async_generator_complete 21520 | `asyncGeneratorComplete` | frees/detaches continuation buffers, func_state=null |
| js_async_generator_completed_return 21532 | `asyncGeneratorCompletedReturn` | poisoned-Promise.constructor fallback: catch PromiseResolve throw → build rejected promise → magic 2/3 then |

DELETE: `awaitAsyncGeneratorOperand` (call_runtime.zig:5523-5549), the synchronous
loop in `finishAsyncGeneratorStep` (5564-5660), post-run promise minting
(fulfilledWithPrototype :5367-5370 — request capabilities replace it),
`asyncGeneratorIteratorResultFromPromise` (promise_ops.zig:3100-3109) if orphaned.
Sync generators keep the existing direct-resume path (js_generator_next mirror) —
untouched except shared-substrate hardening (§3.7).

Parser (mirror qjs emission; retires the B7 runtime-side awaits):
- async-gen plain `yield`: emit `op.await` BEFORE `op.yield` (quickjs.c:28134-28136;
  parser.zig ~7766).
- async-gen return path: emit `op.await` on the return value BEFORE finally unwinding
  (quickjs.c:28402-28404; parser.zig return emission /
  emitStackTopReturnThroughFinally interplay) and the inline AsyncIteratorClose awaits
  (28422-28440) — audit `emitYieldStarDelegation` (parser.zig:7809-7881, already
  qjs-shaped) and keep it; the compact non-expanded lowering in `yieldStarRaw`
  (vm_gen_async.zig:354-401, stored-YieldStarIterator path) becomes dead once only the
  expanded lowering is emitted — delete it and the `generatorYieldStarIterator` slot if
  nothing else reaches them (serialized old bytecode is not a compatibility target).
- for-await-of lowering already matches qjs (parser.zig:14645-14647:
  for_await_of_next; await; iterator_get_value_done) — no change.

### 3.4 AsyncFromSyncIterator (EXTEND)

Existing: qjsAsyncFromSyncIterator* promise_ops.zig:3112-3253 (next=1, return=2,
`else => null`). Add:
- `throw` (method_id 3) mirroring the GEN_MAGIC_THROW arm of
  js_async_from_sync_iterator_next 54484-54607: re-read `.throw` per call; absent →
  IteratorClose(sync_iter) + reject TypeError "throw is not a method".
- onRejected close-wrap reaction (js_async_from_sync_iterator_close_wrap 54468) wired
  only when `!done && magic != RETURN`; PromiseResolve-throw close path (54544-54549).
- Verify the cached-next-method-at-creation invariant matches (qjs 54427).

### 3.5 Module TLA (REWRITE — promise-returning evaluation)

`core/module.zig` `ModuleRecord` gains the qjs tail (mirror JSModuleDef 910-937):
`status` adds `.evaluating_async`; `dfs_index/dfs_ancestor_index/stack_prev`;
`async_parent_modules: []*ModuleRecord (+count/size or ArrayList)`;
`pending_async_dependencies: u32`; `async_evaluation: bool`;
`async_evaluation_timestamp: i64` (counter on JSRuntime, mirrors
`module_async_evaluation_next_timestamp` quickjs.c:377); `cycle_root: ?*ModuleRecord`;
`promise: ?JSValue` + `resolving_funcs: [2]JSValue` (capability, cycle-root-only);
existing `eval_exception` extends to the eval_has_exception discipline. All new
JSValues GC-traced with the record.

| qjs fn | zjs target | notes |
|---|---|---|
| js_evaluate_module 31535 | `evaluateModule(ctx, record) → JSValue(promise)` in module_graph.zig | cycle_root redirect; memoized promise; NO draining |
| js_inner_module_evaluation 31423 | `innerModuleEvaluation` | Tarjan DFS exactly as §1.5 incl. cycle_root-before-break and parent-registration on the CHILD |
| js_execute_async_module 31362 | `executeAsyncModule` | body promise = qjsAsyncFunctionStart on the module function (module body enters the SAME async-function driver as §3.2 — `.settled` special-casing deleted); then two `.module_execution_fulfilled/rejected`-tagged callbacks |
| js_execute_sync_module 31384 | `executeSyncModule` | body via async-fn driver; promise must be settled; PENDING → defensive TypeError |
| js_async_module_execution_fulfilled 31301 (+ js_set_module_evaluated 31173, ExecModuleList 31186, cmp 31236) | `moduleExecutionFulfilled` | idempotency guards, timestamp sort ascending, whole cascade in one job |
| gather_available_ancestors 31203 | `gatherAvailableAncestors` | recursion only through non-TLA parents; stack-overflow guard |
| js_async_module_execution_rejected 31256 | `moduleExecutionRejected` | depth-first parent rejection, no pending-count decrement |

DELETE: `ModuleEvalStep`/`ModuleContinuation` (module_graph.zig:27-57),
`evalPreloadedFileModuleStep` recompile driver (:556-638, incl. parser.compile at
:569), `drainModuleContinuations*`/`drainOneModuleContinuation` (:696-773),
`hasActiveAsyncDependency`/`recordHasActiveAsyncDependency` (:775-808),
`freeModuleContinuations` (:809), `runEvalModuleWithVarRefs` re-entry loop
(eval_entry.zig:162-215). Modules compile ONCE; the compiled function + var_refs live
on the record/graph for the whole evaluation.

Host contract (what replaces the loops): `evaluateModule` returns the promise.
- ctx.eval module mode: eval_entry awaits it via new `hostAwaitPromise(ctx, promise)`
  = js_std_await mirror (quickjs-libc.c:4317-4351): loop { settled → return
  result / throw rejection; `executePendingJob` ran → continue; OS handler ran →
  continue; nothing runnable → return/report the pending promise } — preserves the
  blocking ctx.eval contract for embedders (fun) and the test262 runner.
- CLI module run (zjs.zig): evaluate → hostAwaitPromise → final `hostRunJobs`
  (js_std_loop mirror) — keeps fire-and-forget async observable.
- Dynamic import chaining (module_graph evalDynamicImportModule*): then the evaluation
  promise into the import capability, resolve with the namespace (mirror
  js_load_module_fulfilled 30952-30970) — replaces continuation-drain waiting.

### 3.6 Job queue + host loop (SPLIT)

- `executePendingJob(ctx) → bool` (new, engine): pop-and-run exactly one job by
  min-sequence across pending_promise_jobs / finalization jobs (JS_ExecutePendingJob
  mirror). Callable ONLY from host boundaries; debug-assert not re-entered from VM
  dispatch (e.g. a `ctx.in_vm_execution` depth counter — assert-only, not a mode).
- `hostRunJobs(ctx)` (rename/refactor of drainPendingPromiseJobs body): jobs until
  empty + OS signal/rw/timer handler polling. Sites: §2.7 KEEP rows.
- Legacy deletion: core/jobs.zig Queue + `core.promise.enqueueReaction` migrated to
  pending_promise_jobs; the two `rt.job_queue.runAll()` sites (binding :505,
  module_graph :290) removed; audit core/promise.zig combinators for dead code while
  there (do not rewrite them in E1 unless they sit on the deleted queue).
- Atomics.waitAsync re-plumb: delete the lazy `promiseReactionCallback/Arg` slot pair
  (writes at promise_ops.zig:3476-3482, :3680), `settlePendingPromiseReaction`
  (:3572-3646) and sleep-polling `awaitPendingPromise` (:3704-3719). Replacement:
  notify (possibly cross-thread) marks the waiter settled and wakes the host poll; the
  waiter becomes an OS-handler-like source in hostRunJobs' polling section (peer of
  runNextOsSignalHandler/runNextOsRwHandler/runNextOsTimer) that, when fired, settles
  the promise via the normal reaction pipeline (jobs enqueued, not called). timeout=∞
  = waiter with no timer, woken only by notify. `qjsPromiseSettleValue`'s
  `needs_callback_job` special case (:1203) dies with the slot.

### 3.7 Substrate hardening (shared with sync generators — behavior-preserving)

- Persist `catch_target` into a continuation slot at `saveGeneratorExecutionState`;
  delete `activeCatchTargetForPc` bytecode re-scan (vm_gen_async.zig:501-518).
- Persist an explicit resume-shape enum (initial / yield / yield_star / await) at save
  time; delete the `if_false` sniff (:137-142). Resume push protocol becomes purely
  data-driven: yield/yield_star → push value + completion int (two slots, qjs
  21611-21614); await → write value into the operand slot (one slot, qjs 21307-21313);
  throw-completion → no push, throw into frame.
- Keep `takeGeneratorPendingReturn` finally-yield protocol (call_runtime.zig:5461,
  B7 commit adfd3d1) — it is the js_generator_next GEN_MAGIC_RETURN 21077/21109 mirror
  and applies unchanged to the async-gen return path.

---

## 4. Edit plan by file (anchors @ 8ba31e7; re-grep before editing — lines will drift)

Build order below is a sequencing of ONE final design — each step lands final-state
code for its area, full test262 after every step; no compatibility flags at any point.

1. **src/exec/vm_gen_async.zig**
   - Delete `AwaitSuspendMode` (:22-32) + `awaitSuspendMode` (:494-499).
   - `awaitValueRaw` (:423-476): keep thenable/non-promise normalization + the
     suspend branch (:437-441) as the only outcome; delete :442-476
     (settle/drain/sleep/resume-with-undefined).
   - Save/resume hardening per §3.7 (catch_target slot, resume-shape enum, delete
     :501-518 scan and :137-142 sniff).
   - Delete the compact `yieldStarRaw` stored-iterator path (:354-401) once the parser
     emits only the expanded lowering; keep the expanded path (:325-352).
2. **src/parser.zig**
   - ~7766: async-generator `yield` → emit `op.await` before `op.yield`
     (quickjs.c:28134-28136).
   - Return emission for async generators: `op.await` before finally unwinding +
     inline AsyncIteratorClose awaits (quickjs.c:28392-28445); reconcile with
     `emitStackTopReturnThroughFinally` (:7885+).
   - No change: `emitYieldStarDelegation` (:7809), for-await-of (:14640-14660), await
     unary (:7773-7797). (The two `syntax-await-*` known entries are Phase-C parser
     work, NOT E1.)
3. **src/exec/call_runtime.zig + new src/exec/async_generator.zig**
   - Route `.async_generator` in callFunctionBytecodeModeState (:5342-5370) to
     `asyncGeneratorFunctionCall`; delete the stop_on_yield/.drain plumbing for async
     gens (sync generators keep stop_on_yield).
   - Replace qjsGeneratorNext's async arm: delete :5451 executing→TypeError,
     :5523-5549 awaitAsyncGeneratorOperand, :5564-5660 finishAsyncGeneratorStep sync
     loop; wire builtins .next/.return/.throw → `asyncGeneratorNext` magic dispatch.
   - Add `.async_generator_resolve` (magic 0-3) and `.module_execution_fulfilled/
     rejected` native-callback tags to the dispatch at :516.
   - Implement the §3.3 table in async_generator.zig with qjs anchors in doc comments.
4. **src/exec/promise_ops.zig**
   - AsyncFromSyncIterator `throw` + close-wrap per §3.4 (:3112-3253 area).
   - asyncDispose path (:3044-3085): replace settle+sleep (:3076-3077) with a real
     reaction continuation.
   - `awaitThenableValue` (:3789-3834): delete the drain at :3831 — pending wrapper
     suspends like any await.
   - Delete `settlePendingPromiseReaction` (:3572-3646 + test :3648-3699),
     `awaitPendingPromise` (:3704-3719), lazy-slot writes (:3476-3482), and
     `needs_callback_job` in qjsPromiseSettleValue (:1195-1242).
   - Split drain per §3.6: `executePendingJob` + `hostRunJobs` (def :3721-3779).
   - Async-fn driver: remove `clearHandledRejectionException` (:2895) if root-caused.
5. **src/core/module.zig / src/core/runtime.zig**
   - ModuleRecord async fields + `.evaluating_async` status + GC tracing (§3.5);
     runtime timestamp counter.
6. **src/exec/module_graph.zig**
   - Port the §3.5 qjs functions; delete ModuleContinuation machinery (:27-57,
     :556-638, :696-773, :775-824); dynamic-import chaining onto the evaluation
     promise; drop legacy `rt.job_queue.runAll()` at :290.
7. **src/exec/eval_entry.zig**
   - Delete `runEvalModuleWithVarRefs` (:162-215); module path = evaluateModule +
     `hostAwaitPromise`; keep the :139 host drain (now hostRunJobs).
8. **src/binding/context.zig**
   - runJobs (:505-510): drop legacy runAll, keep hostRunJobs.
9. **src/core/jobs.zig + src/core/promise.zig**
   - Delete Queue; migrate `enqueueReaction` (promise.zig:780) to
     pending_promise_jobs; dead-code audit of the narrow combinators.
10. **src/cli/zjs.zig / src/cli/run_test262.zig**
    - CLI: module run → hostAwaitPromise + final hostRunJobs (js_std_loop shape).
    - Runner: module tests consume the evaluation promise (rejection → test error);
      keep runJobs at :1766/:2814/:2817. Do NOT install a dynamic-import hook in E1
      (that is the post-E1 slice, §6).
11. **Atomics waitAsync plumbing** (runtime layer; find via
    `cleanupAtomicsWaitersForContext` + promise_ops:3476): waiter → host-poll source
    per §3.6.

---

## 5. Invariants that must not break

1. **test262 red line**: `zig build test262` ⇒ `Result: 0/49775 errors` after every
   step; known list (test262_errors.txt, currently 440) only shrinks (`-u` update with
   fixed-count reported). Force-GC probe suite green (Object/Array/Proxy/Weak*/class +
   new async probes, §5.3).
2. **Sync generators**: behavior byte-identical. Specifically preserved: B7
   finally-yield pending-return (`takeGeneratorPendingReturn`, commit adfd3d1 =
   quickjs.c:21077/21109); resume push protocol; heap-backed stack rule
   (`arena_eligible` only `.normal`, call_runtime.zig:5350 — async/gen frames never in
   the vm_stack arena; this is also the bug-B over-free hazard class); the
   flatMap-inner-double-close intentional divergence stays cataloged (c86fd09).
3. **Promise D2 semantics** (E1 depends on D2, do not regress): thenables always
   enqueue a job (quickjs.c:53626 mirror, promise_ops:1356-1364); no settled-adoption
   shortcut; reaction job honors the qjs undefined-handler extension
   (promise_ops:1502-1508 = quickjs.c:53413-53422); genuine-promise reuse in
   PromiseResolve (`.constructor === %Promise%`, 53794-53803); job FIFO by sequence
   with finalization-jobs merged by sequence.
4. **GC rooting of suspended state**: continuation buffers (stack/frame slots), async
   generator request values (4 JSValues each), trampoline func_data (generator
   object), ModuleRecord promise/resolving_funcs/eval_exception/async_parent pointers
   — all reached via traced Object slots / record tracing, NOT via external symbol
   roots (the ModuleContinuation symbol-root workaround dies with it). qjs reference:
   gc mark of state 6641-6650, request queue mark 21400-21418.
5. **Suspension only at machine.depth == 0**; assert it. Async/gen/module bodies
   always enter via fresh runWithArgsState.
6. **Host drain at every entry point retained** (eval_entry:139, binding runJobs,
   module_graph runJobs, CLI, test262 runner) — with real suspension, forgetting one
   makes all fire-and-forget async silently dead. This exact class of bug was caught
   in Phase A review ("2 entry points not armed").
7. **Reentrant next() during EXECUTING appends, never throws** (quickjs.c:21738-21741).
8. **Request-capability-first ordering** (promise minted before any body execution —
   then-getter-ticks observable).
9. **No new global mutable state** beyond the runtime timestamp counter (mirrors qjs).

### 5.3 Probe suite (add under test/ or tests/, run with both engines)

- The four dual-engine probes from the survey (pending-forever await; drain-inside-
  next; gen-step vs 3-deep then chain; plain async interleave) — byte-identical stdout
  vs /home/aneryu/quickjs/qjs.
- Request-queue probes: 3× next() before first resume; next() from inside a then
  during EXECUTING; return(v) on COMPLETED with thenable v; throw() while
  SUSPENDED_YIELD_STAR delegating to a sync iterator whose throw is missing.
- TLA probes: diamond graph with one TLA leaf (fulfillment order by timestamp);
  rejecting TLA leaf (recursive parent rejection, importer sees stored exception on
  re-import); dynamic import of a waiting module.
- Force-GC probes: force GC while (a) an async fn is suspended across a never-resolved
  promise held alive elsewhere, (b) 100 queued async-gen requests, (c) a TLA module
  graph is half-evaluated; then resolve and verify values survive.

---

## 6. test262 known-shrink expectations by cluster (of the current 440)

In-scope for E1 (expected to shrink; verify each with `-u` and report the count):

| cluster | count | mechanism that fixes it |
|---|---|---|
| built-ins/AsyncGeneratorPrototype/* (request-queue-*, return-broken-promise, …) | 16 | request queue + resumeNext + completed_return |
| language async-generator forms (yield-star-sync-throw ×11, yield(-star)-return-then-getter-ticks, yield-star-promise-not-unwrapped, return-undefined-implicit-and-explicit, await interleaving ×2) | ~15 | queue ticks + SUSPENDED_YIELD_STAR + parser awaits |
| built-ins/AsyncFromSyncIteratorPrototype/* (throw/* ×8, next/* ×4) | 12 | throw method + close-wrap + real tick ordering |
| language/module-code TLA (top-level-ticks ×2, fulfillment-order, rejection-order, unobservable-…-count-reset, dynamic-import-of-waiting-module, verify-dfs) | 7 | promise-returning evaluation + timestamp ordering |
| await-using / async disposal ×4 | 4 | asyncDispose via reactions |
| harness asyncHelpers-asyncTest-* | 3 | faithful job/completion ordering in the runner |
| Atomics/waitAsync ×2 | 2 | notify→job plumbing, timeout=∞ |
| Promise/* subset (combinator-fidelity entries may need separate fixes) | ≤11, expect partial | job-order fixes only; do NOT chase combinator internals in E1 |

Explicitly OUT of E1 scope (do not let known-shrink expectations include them):
dynamic-import ×273 (test262 runner module-loader hook — separate post-E1 slice; it
then *exercises* E1's TLA machinery), Array.fromAsync ×90 (post-E1 slice built ON the
new machinery, qjs js_array_fromAsync), `syntax-await-*` ×2 + for-await-of dstr ×3
(Phase-C parser). Realistic E1 shrink: **~45-60 entries**.

---

## 7. Risk register + kill-criteria

| # | risk | detection | mitigation | KILL criterion (abort/re-scope signal) |
|---|------|-----------|------------|----------------------------------------|
| R1 | Sync-generator regression via shared substrate / parser return-path changes | full test262 per step; generator probe set | substrate changes are behavior-preserving (§3.7) and land first, gated alone | sync-gen failures that can only be fixed by diverging substrate shape from qjs → stop, re-audit ground truth before any workaround |
| R2 | Embedder contract breakage: code relying on synchronous await completion (fun bindings, module init order) | fun subtree build + binding tests; ctx.eval semantics | hostAwaitPromise preserves blocking ctx.eval; hostRunJobs at all entries | an embedder contract that *requires* in-VM draining (none known) → escalate to user, do not re-add a mode |
| R3 | GC over-free/leak of suspended state (bug-B class: arena-window orphans, borrowed refs) | force-GC probes §5.3; Debug rc-tracking (dbg_track) on a failing object | rooting via traced slots only; no external symbol roots; heap-backed stacks asserted | force-GC failures that trace to the frame model itself (not a missed slot) → halt E1, fix frame-model rooting as its own keystone first |
| R4 | Atomics.waitAsync cross-thread settle race | TSan-style stress: notify storm from 4 threads; the 2 known tests | settle-marking atomic + wake host poll; promise settled only on owner thread inside hostRunJobs | data race not closable without in-VM polling → fall back to host-poll-only source (still no in-VM sleep); if even that fails, carve waitAsync out of E1 as its own slice |
| R5 | magic>=2 "no drain after AWAITING_RETURN settle" (qjs diverges from spec AsyncGeneratorDrainQueue) may fail a test262 test | run the AsyncGeneratorPrototype/return cluster against qjs binary first | mirror qjs exactly (verified in source, §1.3); if a test demands the spec drain AND qjs fails it too → catalog as intentional divergence per the B7/flatMap protocol; if qjs passes it → our reading is wrong, re-read source | never "fix" by adding a drain qjs doesn't have without the catalog entry |
| R6 | depth==0 invariant violated: some path enters an async body through the inline-call fast path | new assert fires under test262/Debug | audit callFunctionBytecodeModeState routing up front | a structural need for depth>0 suspension → abort E1; that is a frame-model rewrite prerequisite, blueprint it separately |
| R7 | Module TLA Tarjan port errors (cycle_root/dfs bookkeeping) silently corrupt graphs | verify-dfs + fulfillment/rejection-order tests + cyclic-graph probes | port assertions from qjs (they are load-bearing: 31311-31317, 31215-31220) | — (fix-forward; this is contained) |
| R8 | Perf regression on async/generator hot paths (queue + per-request capability) | targeted perf: async-fn ping-pong, async-gen drain, module startup — vs qjs binary only (never vs old zjs) | qjs does the same allocations; measure before/after with perf stat instructions | >1.2× regression vs pre-E1 zjs on sync-generator benchmarks (async paths becoming slower-but-correct is acceptable; sync must not pay) |
| R9 | Job-loop split leaks OS-handler starvation (timers never polled because a KEEP site was converted to executePendingJob-only) | CLI timer smoke (setTimeout chains), os signal tests | hostRunJobs keeps the exact current polling loop | — |
| R10 | Scope creep: fixing Promise combinator known-entries, fromAsync, dynamic-import hook "while there" | review of the diff | §6 scope table is binding | any non-E1 cluster edit in the E1 series → split it out |

General kill discipline: at any gate, if the fix for a red test requires adding a mode,
a flag, or an in-VM drain — that is the abort signal; stop and re-derive rather than
compromise the model (this is precisely how the current four-mode debt accreted).

---

## 8. Gates

- Per build-order step (§4): `zig build zjs` + full `zig build test262` (expect
  `0/49775`, known-only-shrink) + smoke (CLI script, module w/ TLA, timer chain) +
  probe suite §5.3 dual-engine diff.
- Final: force-GC gate build (remember it overwrites zig-out/bin/zjs — rebuild before
  any perf measurement), fun subtree `zig build fun` if touched surfaces reach the
  binding layer, known-errors `-u` shrink commit with per-cluster fixed counts, and a
  DIVERGENCE-CATALOG.md entry for any R5-class intentional divergence.
- Commits: one per §4 step, message `fix(qjs-align): E1 — <area> (mirrors <qjs fn>
  quickjs.c:<line>)`; final status update in FIX-PLAN-2026-07-02.md.
