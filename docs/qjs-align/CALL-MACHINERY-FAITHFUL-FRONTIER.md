# Call-machinery faithful frontier — current state & conclusion

> **Single source of truth** for where zjs's call/dispatch alignment to QuickJS stands.
> Updated 2026-07-15: the same-Machine internal for-of callback and its result/setup refinements are in §7. Method-A's
> first tranche landed 2026-07-04 (`952592f` + `f3a517d`) — see §0. This doc consolidates and replaces a
> cluster of now-historical plan/investigation/handover docs (DISPATCH-TAX-FINDINGS,
> TAILCALL-DISPATCH-ONESHOT-BLUEPRINT, FRAME-MODEL-ONESHOT-BLUEPRINT, FRAME-RAW-SP-BLUEPRINT,
> FRAME-STRUCTURAL-ALIGN, COLLAPSE-CALL-MACHINERY-BLUEPRINT, HANDOVER-call-dispatch-align,
> HANDOVER-frame-incremental, PHASE3-leaves-and-levers) — deleted; their durable conclusions,
> invariants, and disproven claims are folded in below. qjs-side mechanism reference is kept in
> `CALL-MACHINERY-QJS.md`.

## 0. 2026-07-04 method-A first tranche — LANDED (`952592f`, fix `f3a517d`)

- **Knife 1 — InlineTarget is scalars-only and rides by pointer.** The old target embedded a
  by-value `bytecode.Bytecode` (~450B) and was copied 4-5× per call through
  `op_call -> vm.tail_request -> driver -> pushCall -> pushFrame` — memcpy was the #1 fib
  profile line (16.96%). Now `view: ?*const Bytecode` (the per-FB cached view; null for a
  cache-less fixture FB, which gets an Entry-owned heap-boxed rebuild — old per-call-rebuild
  semantics preserved). `Entry.view_storage` is deleted. qjs anchor: OP_call passes only the
  16B func_obj; the callee prologue dereferences `p->u.func.function_bytecode` (17800).
- **Knife 2 — `setupSimpleInlineEntry` is a straight-line mirror of qjs's prologue
  (17828-17871):** one size computation, ONE arena carve, pointer-arithmetic partition, every
  frame field bound exactly once. The `Frame.init` default-then-overwrite pass, the 7-slice
  by-value `FrameSlab` round-trip, `FrameStorageWindows`, and the double open_var_refs memset
  are gone from the simple path. Ownership flags unchanged (verified under force-GC).
- **Fix — two dispatcher semantics lost when tail-call threading landed** (pre-existing on
  HEAD, exposed by the gate): (a) interrupt polling — qjs polls on every OP_goto (18822) and
  at call entry (17787); the tail-call path had NO poll point, so pure loops hung the
  interrupt tests (suite idx 38/56) and the whole unit suite never completed. (b) op.call's
  push-failure catch leg (`handleCatchableRuntimeError`) — a bare `try` leaked OOM out of
  eval instead of delivering the preallocated InternalError to the caller's catch.
- **Numbers (fib(30)×3, X925 pinned):** 1390 → **988 insn/call**, 4.15× → **3.02×** qjs wall.
  funcall pure per-call tax (differential vs inlined body): 1169 → **774** insn (qjs 249).
- **Second tranche (same day, `ea1760e` + `a6c25bb` + `4ae9a79`) — in-handler call/return:**
  op_call/op_call_method fast hits complete the whole call inside the handler
  (pushAndEnter: push + poll + reload + tail-dispatch into the callee, qjs CASE(OP_call)
  18182-18202) and op_return/op_return_undef at depth>0 run a fused teardown + result
  delivery + caller resume (popAndResume) — the driver round-trip (Outcome encode, 88B
  tail_request staging, Vm spill/reload; `runWithArgsState` 19% self) is gone from the hot
  path. The dying simple frame tears down via straight-line `teardownSimpleEntry` (qjs done:
  epilogue 20698-20710; `Entry.fast_teardown` static gate + dynamic escapes for cold-box /
  heap-storage / heap-stack, any escape → full teardown), inlined so the return value stays
  in a register. **fib 988 → 920 insn/call, 3.02× → 2.64× wall — past the 2.66× pre-
  struct-align best. funcall tax 774 → 704 (wall 2.06×).** Disproven en route: manually
  inlining pushCall/pushFrame and a depth>0-specialized reloadTop are both no-ops (LLVM
  already has them; the vm-field stores are the irreducible tail-call-architecture cost).
- **Third tranche (workflow `wf_972da3d7`, 4 experiments A/B-measured on isolated
  worktrees, TIME as the yardstick): E2+E5 landed (`17bb4b7` + `f14c3f0`) — fib
  925.4 → 909.4 insn/call, 378 → 358.6 ms = 2.51×; funcall tax 709 → 689.**
  E2: pushFrame/pushCall return the acquired `*Entry`; pushAndEnter reloads from it
  directly (qjs never re-derives the frame address — it IS the alloca pointer, 17846);
  kills the 344B-stride umaddl on the push edge (−9 insn, −3.8% time). E5: caller
  operand-region retreat moved to the top of the simple prologue (qjs borrows argv at
  17841 before the alloca; the length retreat was the setup chain's hottest tail store),
  errdefer restores the length before cleanup (−7 insn, −0.3% time).
  **DISPROVEN (do not re-attempt without new evidence): E1 handler 5th-register-arg for
  code_base — −5 insn but +0.9% TIME (register-pressure/layout backfire at ~45-handler
  scale); E3 Entry stride 512 — −3 insn but +2.0% TIME (cache-footprint loss beats the
  multiply→shift win). Both prove insn-count alone is not the yardstick.**
- **get_var recon (docs/qjs-align/GET-VAR-FIB-RECON.md): the presumed "lever ② parser
  divergence" is REFUTED** — both engines compile fib's self-reference to isomorphic
  bytecode (get_var u16-idx / get_var_ref0) and zjs's hot op_get_var already reads the
  cell directly (no name lookup, no IC on the hot path). The REAL divergence is the
  var_refs slot contract: qjs's typed `JSVarRef **var_refs` folds delete / top-level-let
  shadowing / eval bindings / undeclared-global into cell state at closure-creation /
  mutation time, leaving ONE read-side check; zjs's untyped `[]JSValue` slots re-verify
  all four per read (8 guards, 28 vs 4 cycles, 10.9% of fib).
- **Slot contract — EXECUTED (workflows `wf_a735f162` + `wf_6595def0`, 6 commits):**
  Step1 delete→UNINITIALIZED sentinel, is_deleted retired (`90dd5f3`, qjs 9288; also
  structurally fixed a pre-existing revival-asymmetry bug). Step2 top-level-lexical
  shadowing folds into the global cell at definition time, shadows guard retired
  (`4cfeeb3`, qjs 17148 dual-channel: VARREF cell surgery + uninitialized_vars side
  table; first version was gate-rejected 2/49775 — root cause was NOT the mechanism but
  zjs's parser globalizing `arguments` in two corner shapes where qjs resolves it at
  parse time (32970), fixed by restoring the frame-model rescue in the new uninit arm;
  also fixed pre-existing fn-before-let permanent-TDZ bug via cells-before-values
  ordering). Slot typing via blueprint (`f3c4821`) in 4 gated phases: A accessor funnel
  (`52badfc`, 39 raw accesses → 7 inline accessors, objdump-verified zero codegen
  change), B every slot source produces a real cell (`9eac2a6`, backfill/global_ref/
  eval-boundary cellified + Debug asserts, 2930-file canary sweep), C module import
  slots alias the exporter's cell directly (`71d6574`, qjs 30765, const wrapper
  de-nested to cv.is_const), D atomic type flip `[]JSValue → []*VarRef` across the
  whole coupling network — Frame/captures/generator payload/module/merged/FrameSlab
  8B windows/GC visitor/teardown, 22 files in one commit (`2b360fb`); read-side
  cell-kind + bounds + nested-cell guards retired (qjs OP_get_var_ref 18627 zero-check
  deref is the landed end state). Remaining guards (dynamic-overlay + parentEvalShadows)
  are Step-4 domain: eval-overlay→compile-time closure vars, folds into the
  REMAINING-KNOWN direct-eval rework.
  **Numbers: fib 902.5 → 866-870 insn/call, 356.7 → 350.4 ms = 2.45×; funcall tax
  682 → 664, wall 1.88× — first time under 2×.** Every phase passed the full gate
  (test262 0/49775 known 13 exact, force-GC smokes, parity suites three-way vs qjs,
  unit-suite sequential FAIL-set identity).
- **Fourth tranche (workflow `wf_59aa590c`, accounting-driven): 4 knives landed
  (`4a04ff7`/`34187e1`/`ce508be`/`07b6144`) — fib 870 → 840 insn/call, 351 → 332 ms =
  2.32×; funcall tax 668 → 638, wall 1.77×.** (1) return value is an ownership MOVE
  (qjs `ret_val = *--sp` 18266) — the old peek+dup+teardown-free did strictly more
  refcount work than qjs; ALSO resolves this doc's long-standing returnTop
  value-semantics question. (2) register-resident ret_val — finishFunctionReturn's
  error union forced a 3-slot memory phi (funcall's hottest single instruction,
  23.6% of op_return); derived-ctor/generator legs are now cold branches, hot leg
  carries a plain JSValue (qjs OP_return is infallible; ctor legality is a separate
  opcode 18273). (3) qjs frame-pointer chain transplanted: Entry.prev + cached
  Machine.top ≅ JSStackFrame.prev_frame / rt->current_stack_frame (408/17869/20709)
  — both per-return umaddl index chains gone; best single knife (−2.9 % wall).
  (4) direct-eval const wrapper de-nested to a pvalue alias — last nested-cell
  producer gone. **REJECTED: get-var-frame-flag-fold (+2.8 % wall — guard fold
  into a Vm flag backfired).**
- **The accounting ledger (fib, 477 insn/call gap decomposed, closes to 0.0):
  call machinery +402 (84 %) | op bodies +75 (16 %: get_var 49, arithmetic 33,
  compare 13, minus zjs-ahead ops −20) | dispatch −44 (zjs is AHEAD of qjs).**
  Priority read-out: collapse the return/teardown half first (~276 of the
  machinery gap), then the call/setup half (~354 vs qjs ~170). Full qjs-form
  convergence projects fib ≈ 1.16×. Dispatch work is negative-value.
  Next: the op_call/setup half (resolve chain + cachedBytecodeView loads +
  enterInlineCallDepth double check + frameOpenVarRefStorageCount recompute —
  precomputable per-FB like simple_inline_eligible), op_binary's 0x1e0
  frame-open/close (the frame=sum-of-arm-spills problem, instance-level),
  and get_var's remaining spill prologue (Step-4 direct-eval domain).
- **Fifth tranche (workflow `wf_4bc6919f`, ledger-targeted 5 knives, 3 landed):
  fib 840 → 727 insn/call, 330 → 289 ms = 2.02×; funcall tax 638 → 521,
  215 → 195 ms = 1.62×.** (K3, `c4ee2cd`) resolveInlineTarget tightened to
  qjs prologue form: recursive `bl objectRealmGlobal` → single
  `ldr [payload,#48]` (`ctx = b->realm`, 17871), cachedBytecodeView split
  inline-hot/noinline-cold, arrow legs outlined — −56/call, the round's
  biggest. (K4, `2d47467`) op_binary de-framed into per-op `opBinary(kind)`
  generators: int leg is int64-widen+truncate (19701, NOT @addWithOverflow),
  each arm writes sp[-2] directly (no 16B phi spill), float/overflow fall
  indirect to cold — killed the 0x1e0 frame + fmod bl + double-dispatch,
  −36.5/call. (K5, `eab00dd`) op_compare split into per-op `opCompare(opc)`:
  comptime predicate folds the cmp+cset+csel select chain to one cmp+cset
  (qjs OP_CMP 20230), −13/call fib, −30 funcall tax. **DEFERRED (faithful but
  flat on fib/funcall — not on these benchmarks' hot path, kept for
  native-entry/eval-heavy code): K1 frameOpenVarRefStorageCount per-FB
  precompute (setup-path flag already cheap here), K2 native depth-check
  shape (`max_native_call_depth` field — the recompute was on the VM-entry
  path, not the inline path fib/funcall exercise).**
- **Sixth round (workflow `wf_99b8c92e`, orchestrating the `codex` CLI to
  implement in isolated worktrees): NULL RESULT — all 3 micro-targets
  rejected, base unchanged.** The three "safe" remaining hotspots were handed
  to codex (a Claude wrapper drove `codex exec`, then authoritatively
  built/smoked/faithfulness-reviewed each diff). All landed clean and
  faithful but none is a demonstrated win on deterministic insn count:
  C1 op_get_arg_short early-out for non-refcounted args = **+4 insn/call
  (regression** — JSValue.dup() already tag-checks internally, so the
  explicit branch is redundant work, not a save); C2 setupSimpleInlineEntry
  errdefer calling popOwnedStackRegion directly instead of cleanupStackSource
  = cold-error-path-only, +3 insn/call layout perturbation, hot path
  untouched; C3 op_get_var guard reorder = 0 insn change (LLVM already
  scheduled it). **Lesson: these three hotspots (get_arg 13.6% / setup 10.5%
  / get_var 9.0% self) are already at qjs-form — no micro-optimization is
  accessible. Their residual cost is STRUCTURAL: get_var's is the two Step-4
  direct-eval guards (deferred), setup/get_arg's is irreducible per-call
  work already matching qjs. Future effort must go to the big handlers
  (op_call 17-24% / op_return 20% — restructuring, not micro-tightening) or
  Step-4, NOT back to these three.** Codex mechanics for the record: `codex
exec --dangerously-bypass-approvals-and-sandbox -C <worktree>` works
  headless under ChatGPT auth; `-o <file>` did NOT reliably capture the last
  message (read the stdout tail instead); the wrapper's independent
  build+smoke+diff-review is the source of truth (codex's self-report is
  not).
- **Gates:** test262 full 0/49775 (known 13, == main); force-GC build smoke green
  (closure/recursion/PTC/exception mix byte-identical to qjs); unit suite compared
  segment-by-segment against the unpatched-HEAD binary — identical failure sets. NOTE: the
  unit suite itself is **pre-broken on HEAD** (idx-58 NativeBinding crash stops a sequential
  run; ForbiddenCoreRuntimeDependency + oom_cap FAILs; crashes past idx 900) and has
  process-global order coupling (isolated/range runs differ from sequential runs).
- **Next in §2.1, by current profile:** driver round-trip collapse for call/return (the
  `.tail`/`.returned` detour through the driver — push/pop + reload + tail-jump directly in
  the handler, qjs's "the whole call happens inside CASE(OP_call)" shape;
  `runWithArgsState`(driver) is 19% self), then teardown straight-lining (6.5%), then
  `op_call` resolve+stage (9.4%).

## TL;DR — the current verdict

- **Dispatch is a faithful match and is DONE.** HEAD is tail-call threaded (`src/exec/tailcall_dispatch.zig`):
  `next` = 4 insns ≈ qjs computed-goto's 4-5; table base resident (no `adrp+add` remat); per-handler
  frame ~80-150 B vs the old monolithic 3504 B. **Do not touch the dispatch mechanism.**
- **The single-function / labeled-switch rewrite is UNNECESSARY — proven (route-2, §3).** At full
  224-arm scale a labeled-switch (116 insn/call) and tail-call (112 insn/call) fib are within 4% and
  both ~0.30× qjs. The dispatch _mechanism_ is not the lever. The old POC's 0.32× win is overwhelmingly
  "the toy skips real per-call work" (refcount dup/free, frame setup, shape/GC), not architecture.
- **The lever for the remaining fib gap (~2.66× qjs) is aggressive method-A:** collapse the call-path
  function decomposition and strip the per-call bookkeeping qjs doesn't have — **keeping tail-call
  dispatch**. Low risk, incremental, gate-able.
- **Native recursion (the other half of "axis ②") is UNPROVEN and risky.** `Path B` (native recursion
    - real per-call work) _regressed_ to 6.04× on deep fib. Treat it as a separate, later, real-work-modeled
      experiment — NOT bundled into a "collapse" rewrite.

## 1. What has landed (current state)

- **Tail-call threaded dispatch** (the dispatchLoop monolith is gone). Why per-op functions beat one big
  switch: the monolith's 3504 B frame was the **sum of per-arm JSValue spills that don't coalesce**
  (proven by comptime-delete bisection — additive); making each opcode a separate function puts its
  temporaries in its own frame that dies at its return, so runtime stack = **max single handler**, not sum.
- **The hot simple-inline call path** (`inline_calls.zig`): `setupSimpleInlineEntry` (noinline, regalloc-
  isolated — load-bearing), `simple_inline_eligible` precomputed on the Bytecode view, `var_refs` borrow
  (alias closure captures, skip per-call dup/free), single backtrace chain (no parallel per-call node),
  `op_call`/`op_call_method` inline their bytecode-call resolution (skip `execCall`).
- **Perf trajectory:** fib ~3.6× → **2.66×** qjs; accumulator loops fused (`add_loc`); method dispatch
  cascade hoisted. Measure on a fresh `zig build zjs` (stale-binary hazard).

## 2. The faithful frontier (what's left, ranked)

1. **Aggressive method-A — collapse the call path (low risk, keep tail-call).** Merge the ~9 incidental
   frame-setup functions (`pushCall→pushFrame→acquireSlot→{Frame.init, FrameSlab.carve, initArenaWindow,
initFrameLocals, initArgumentsBorrowedSlots}`) toward a straight-line sequence like qjs's
   `JS_CallInternal` prologue, and strip per-call bookkeeping qjs lacks (Entry pool, profile guard, eval
   checks, arena mark on the simple frame). Each step gate-able; expect single-digit-% wins (diminishing).
2. **Native recursion** — open, unproven, correctness-bearing (see §6). Not recommended without a
   real-work-modeled de-risk first.

## 3. route-2 de-risk result (2026-06-29) — single-function rewrite is unnecessary

Question: does the 30-line POC's `0.28-0.32× qjs` (single-function labeled-switch + native recursion)
survive scaling to a full ~200-opcode space, or is it a small-scale artifact? Harness: `/tmp/gen_fib.py`

- `/tmp/run_sweep.sh` (parameterized fib interpreter, opaque-call padding arms, `taskset -c 8`, fib(30)×3
  = 8,077,611 calls). Reproduced the POC exactly (9 arms = 107.6 = the old 107.5).

| dispatch                | arms    | insn/call | vs qjs (389) | table base (objdump)           |
| ----------------------- | ------- | --------- | ------------ | ------------------------------ |
| labeled-switch          | 9 (POC) | 107.6     | 0.28×        | resident                       |
| labeled-switch          | 96      | 116.1     | 0.30×        | resident (adrp=2)              |
| labeled-switch          | **224** | 116.1     | **0.30×**    | **resident — 2-insn dispatch** |
| tail-call               | 224     | 111.6     | 0.29×        | resident                       |
| current zjs (real work) | —       | ~1036     | 2.66×        | —                              |

**Conclusions:**

- **Dispatch mechanism doesn't move the needle** (ls 116 ≈ tc 112 at 224 arms) → the single-function
  rewrite buys nothing the current tail-call doesn't already have. B is dominated.
- **Corrects `DISPATCH-TAX-FINDINGS`:** that doc claimed "arm count is the determining variable" for
  table-base eviction (24 arms → 25/25 evicted). Verified false here — the fib interpreter at **224 arms
  keeps the base resident**. The doc's `disp_many` evicted because it held **8 long-lived pointer carriers**
  across every arm (saturating callee-saved); a real interpreter loop carries few values, so **arm count
  alone does not evict** (consistent with the doc's own earlier two-condition root cause: arms-call AND
  carrier-saturation, both required).
- **The POC's win is toy-leanness, not architecture.** The toy omits 16 B JSValue refcount dup/free, frame
  locals/var_refs setup, stack-overflow check, shapes/GC — all of which qjs _also_ does (hence qjs = 389,
  not 115). So a real collapse can't reach 115; its honest target is _qjs's order_, by removing the
  function-decomposition tax + the bookkeeping qjs lacks.

## 4. Invariants that must NOT be broken (load-bearing — any call-path work preserves these)

- **Ownership lockstep.** `current_function` is **KEPT OWNED** (the "borrow cur_func" facet is rejected —
  `takeSourceSlot` is a _move_, not a dup, so refcount is already identical to qjs; nothing to remove).
  The `var_refs` borrow safety is **coupled to `current_function` being owned** — the still-live function
  object roots the borrowed cells. Flipping one ownership flag without the other → double-free or leak
  (force-GC + test262 are the oracle).
- **Frame stays its current ~15-field shape; do NOT slim to 9.** Rejected for real reasons: the teardown
  cost is the _necessary_ value frees (not field proliferation), and most "cold" fields
  (`storage_*`, `original_args`, eval/sync state) **cross generator/async suspend**, so a `FrameCold`
  side-struct can't be freed at teardown for a suspended generator. `FrameCold` already exists and is
  correct as-is.
- **Suspend / raw-sp bifurcation — preserve all gates.** Hot inline frames borrow a slab window; cold
  growable frames (top-level / native re-entry / generator / async) keep the full heap-backed `Stack`.
  Generators transfer buffer ownership into the generator object and _physically cannot_ use a borrowed
  slab window — do not unify the two regimes.
- **Refcount-only frame liveness.** The cycle collector never walks the frame/Entry chain
  (`traceRoots`); frame values stay alive by refcount only. Don't add the frame chain to GC roots.
- **Thread an opcode → read the FULL push/helper refcount + error chain, not just the top function.**
  This discipline cost 2 bugs historically: missing the `dup`/retain in a threaded `pushAssumeCapacity`
  (under-ref → premature free), caching a `var_refs` pointer that reallocs mid-frame on closure capture
  (stale UAF), and threading the `put_array_el` grow path (fallible, can't sync the operand stack).

## 5. Disproven — do NOT re-attempt

- **Single-function / labeled-switch dispatch rewrite** — route-2: unnecessary, tail-call is equivalent
  at scale, and it re-introduces table-remat risk on higher-pressure code.
- **"Borrow cur_func"** — a non-diff (move, not dup; same refcount as qjs).
- **Frame slim to 9 fields** — low benefit, high complexity, cold fields cross suspend.
- **Un-caching cold context vars to free a register for the table base** — disproven by reading the actual
  reg-alloc: the cold vars are already in stack slots, not callee-saved; only eliminating a _hot_ carrier
  frees a callee-saved register (and that's the raw-sp rewrite, whose fib payoff is a known mirage).

## 6. If native recursion is ever pursued (crossing concerns)

Only as a separate experiment, _after_ a real-work-modeled de-risk (the toy can't settle it; `Path B`
regressed to 6.04× with real work + the old slow path). Ground-truth these first:

- **Suspend.** Generator/async yield must unwind the native stack via a Zig error/sentinel (qjs's
  `FUNC_RET_YIELD` analog); simple-normal calls recurse, generator/async/class-ctor/eval stay on the
  current path (already excluded by `resolveInlineTarget`'s `func_kind != .normal`).
- **Deep recursion / stack overflow.** Native recursion uses the real stack → needs a TCO trampoline for
  proper tail calls + a `js_check_stack_overflow` equivalent.
- **Backtrace / exception.** Walk the live `Frame` chain (qjs `current_stack_frame->prev`); Zig `error`
  propagates naturally up the stack, replacing the explicit Entry-chain unwind.

## 7. Internal callback re-entry — current state & corrected conclusion (2026-07-15)

> The earlier version of this section incorrectly attributed zero-argument
> callback cost to an argument-window allocation. A zero-argument frame already
> has `frame_arg_count == 0`, so it allocates and copies no argument slots. The
> measured gap was the second `runWithArgsState` Machine boundary. The first
> high-frequency internal callback now stays in the caller's Machine.

### 7.1 Path-by-path state

| # | Path | Current contract | qjs anchor | State |
|---|---|---|---|---|
| A | **JS→JS inline** | Arguments alias/move from the caller operand region through `initArgumentsBorrowedSlots`; no payload copy. | `arg_buf = argv`, `JS_CallInternal` 17828–17871 | At internal parity. |
| B | **JS→Zig builtin** | `args` borrows the still-pushed caller operand region; the owner frees it after the builtin returns. | `OP_call_method` borrows `call_argv`, then frees the call region. | At internal parity. |
| C1 | **Public Zig→JS** (`runWithArgsState`) | `initArguments` duplicates caller-owned `const` arguments. | Public `JS_Call` sets `JS_CALL_FLAG_COPY_ARGV`. | At public-ABI parity; keep it. |
| C2 | **Internal for-of → bytecode `next`** | Eligible same-realm normal bytecode targets borrow the suspended caller's persistent `[receiver, method]` record and attach a post-return continuation. Ineligible targets retain the owned dup/move fallback. Zero args means no argument slots. | Internal `JS_CallInternal(..., flags=0)` remains in the interpreter call chain and borrows its `JSValueConst` inputs. | Second Machine boundary and eligible call-binding copy removed. |
| D | **Plugin FFI** | Heavyweight `CallFrame`, intentionally isolated. | No qjs equivalent. | Out of the interpreter hot path. |

### 7.2 What the zero-argument profile actually measured

Before this change, custom bytecode iterator `next()` called
`runWithArgsState` from `iteratorStepWithNext`. Although `argc == 0` made every
argument allocation/copy loop empty, re-entry still constructed and drove a
second Machine, published/reloaded VM state, and returned through the generic
host-call boundary. The profile accordingly put recursive `runWithArgsState`
at 14.8% and `iteratorStepWithNext` at 10.6%. The cost was fixed re-entry, not
an argc-scaled copy.

### 7.3 Landed same-Machine for-of continuation

`op_for_of_next` now performs the qjs-shaped internal path when all eligibility
proofs hold:

- Resolve a same-realm, normal, non-suspendable bytecode `next` target.
- Borrow the iterator and method from the suspended caller's persistent record
  and push the callee on the existing Machine. The dedicated eligible prologue
  allocates no call-binding or argument payload; the general fallback still
  duplicates them into an owned moved-method region.
- Tag the callee entry with `ReturnAction.for_of_next`; its payload is the
  bytecode depth operand. Proper-tail-call frame replacement moves this action
  to the replacement entry.
- On return, consume the iterator-result object in the caller Machine: read
  `done` before `value`, skip `value` when done is true, and preserve observable
  accessor/Proxy semantics. The overwhelmingly common own-data leg uses the
  same trusted shape-hash probe as qjs `find_own_property`, returns the borrowed
  slot, then duplicates it once. A missing own slot continues through the
  ordinary prototype walk; accessor, var-ref, auto-init, Proxy, and exotic cases
  fall back to the authoritative Get path.
- The fallback `pushMovedCall` selects a compile-time moved-method setup
  instance. It no longer fails the two plain-call selectors and round-trips
  through `setupFallbackInlineEntry` before choosing the same simple frame.
  The eligible borrowed prologue, generic `pushCall`/tail-reuse instance, and
  the single acquire/link/ownership lifecycle remain separately proven.
- A throw from `next()` propagates without `IteratorClose`, matching qjs and the
  ECMAScript IteratorNext/for-of ordering. Loop-body abrupt completion still
  closes the iterator through the existing path.

Native, cross-realm, generator/async, class-constructor, malformed, and other
non-eligible targets retain the generic helper. This is a semantic gate, not a
best-effort optimization.

### 7.4 Measured result

Three fixed 2,000,000-step custom iterators progressively remove work from
`next()`: `for-of-bytecode-next-zero-arg-2m.js` mutates and reuses its result,
`for-of-bytecode-next-constant-result-2m.js` returns a constant result through
`this.result`, and `for-of-bytecode-next-self-result-2m.js` makes the iterator
itself the constant result. Cortex-X925 CPU19, ReleaseFast, 11 three-way
interleaved rounds; table values are medians. Binary identities are frozen zjs
`20f11d0f…`, current zjs `523c35a6…`, and qjs `b76d1542…`.

| Fixed workload | Frozen zjs instructions / cycles | Current zjs instructions / cycles | qjs instructions / cycles | Current / qjs |
|---|---:|---:|---:|---:|
| Reused, mutating result | 6,870,837,207 / 1,173,361,316 | 3,012,183,112 / 497,804,678 | 1,703,544,660 / 280,438,613 | 1.7682x / 1.7751x |
| Constant result via `this.result` | 6,362,477,788 / 1,118,866,663 | 2,645,610,051 / 425,869,884 | 1,735,441,613 / 327,835,490 | 1.5245x / 1.2990x |
| Iterator is result | 6,150,387,934 / 1,026,515,970 | 2,433,434,884 / 387,106,870 | 1,615,341,743 / 265,941,614 | 1.5065x / 1.4556x |

The complete bounded sequence removes 56.160% instructions / 57.574% cycles
from the frozen zjs baseline on the mutating workload, 58.419% / 61.937% on the
constant-result control, and 60.434% / 62.289% when the iterator is the result.
The own-data probe and moved-method setup first removed the generic property and
fallback path. The final large fixed saving came from replacing ReleaseFast
runtime `predefinedId("done"/"value")` lookups with the compile-time predefined
atom IDs; LLVM had not folded the atom-table scan, so this removes about 434
instructions per iteration.

The call target now also carries a non-null pointer to the FB-shared cached
execution view. Cache construction failure declines the same-Machine path and
falls back to the authoritative generic call; a successful Entry never owns a
per-call view. Removing that obsolete owner retains the default NaN-boxed
Entry's 256-byte stride; the 16-byte reference representation omits the
default-only padding and uses 280 bytes instead of the old 288. Compile-time
assertions lock both layouts. The cleanup eliminates one nullable/ownership
check per ordinary call and two on the moved path. The moved-method instance
publishes its real continuation exactly once after setup; a direct binary A/B
kept ordinary empty/strict/closure instruction counts identical and removed
exactly two stores per for-of step.

The final qjs ownership alignment removes the moved region itself for eligible
zero-argument `next()` methods. The suspended caller's persistent
`[iterator, next]` record roots both `this_obj` and `func_obj`, just as qjs
borrows those `JSValueConst` inputs in internal `JS_CallInternal`. A dedicated
zero-argument prologue therefore installs borrowed frame bindings and allocates
only padded formals/locals/stack/open-var-ref storage. Arrow, non-simple,
suspendable, cross-realm, and otherwise ineligible targets keep the established
dup/move path. This removes another fixed 169 instructions per iteration. A/B
controls for ordinary empty/strict/closure, exact/padded/strict methods, and
Proxy continuations remain instruction-identical; the three iterator controls
improve cycles as well as instructions.

The shared return epilogue now also follows the pointer qjs has already
published. `popFrame` writes `dying.prev` to `Machine.top`; the old return path
then tested `depth` and reloaded that same top pointer through
`loadCurrentLevel`. `reloadAfterPop` instead treats nullable `Machine.top`
directly as qjs's `prev_frame` (`null` means L0). No state or Entry bytes were
added. `op_return_undef` shrank from 3096B to 3056B and `op_return` from 3336B
to 3316B. Across 15 paired rounds this removes about four instructions/call
for every ordinary and iterator control. Empty/strict/closure/method/reused
iterator paired cycles improve 3.23%/3.19%/1.58%/2.70%/0.14%; the self-result
iterator is noise-bound (25-round paired +0.19%, independent medians −0.12%)
while instructions improve 0.33%. Final zjs/qjs instruction ratios are
1.525x/1.615x/1.557x/1.698x for
constant-call/empty/strict-two-arg/closure, while the three iterator ratios are
the table values above.

Two broader pointer/layout attempts were rejected. Keeping `dying.prev` live
across teardown consumed another callee-saved register, grew the return stack
frame from 96B to 112B, and added about one instruction/call. A retired-Entry
free chain removed repeated chunk arithmetic but grew `pushFrame` and both
return handlers by roughly 48B; closure cycles regressed 2.83%, method cycles
0.69%, and the lowest-work iterator added 0.24% instructions. Both source
candidates were removed.

After removing return's repeated caller lookup, the lowest-work control fixes
the remaining attribution: samples now concentrate in
`finishForOfNextResult`, common simple-frame setup, dispatch, and the isolated
post-return handler—not recursive Machine re-entry, argument/call-binding
copying, dynamic predefined-atom lookup, per-closure/per-call execution-view
ownership, or a second caller-frame lookup.

### 7.5 Remaining work and invariants

- **Do not add an `args_mode` to solve zero-arg calls.** There are no argument
  slots to optimize. First prove whether the cost is re-entry, setup, or result
  processing.
- **Public `JS_Call`-style ownership stays duplicate-in.** Caller-owned `const`
  arguments may be overwritten by `put_arg`; borrowing would corrupt embedder
  storage.
- **Move/borrow only with a proven owner and lifetime.** The eligible for-of
  path borrows `[receiver, method]` only while the suspended caller's persistent
  iterator record remains unchanged and rooted through return/unwind. Every
  target outside that proof duplicates into the owned moved region.
- **Suspendable and cross-realm targets fall back.** Their lifetime/realm state
  is not represented by this continuation.
- **Continuation ownership follows proper tail calls and unwind.** Proxy atoms
  and for-of depth share a tagged payload but have different destruction rules;
  action-specific take/deinit logic is mandatory.
- **`next()` throw is not loop-body throw.** Never run IteratorClose merely
  because the pending continuation is for-of-next.
- **Keep the post-return handler isolated.** A measured direct-resume experiment
  saved 20 instructions per for-of iteration but added 5 instructions to every
  ordinary empty call. It was reverted; narrow continuation work must not grow
  the common return shape.
- **Do not copy qjs's missing per-op `pc >= code_end` check in isolation.** An
  inline removal saved only 5–11 instructions per iteration while strict and
  closure call cycles regressed about 1.94%/1.97%. Outlining the four-instruction
  dispatcher still regressed strict cycles 1.59%, with median branch misses up
  about 24% and L1I misses about 12%. qjs gets this shape inside one monolithic
  `SWITCH`; zjs's split tail-called handlers need a handler-collapse proof before
  this check can be reconsidered. Both candidates were reverted.
- **Do not add an isolated `OP_push_this` handler only because qjs has a direct
  arm.** The object/raw-strict candidate saved 7.1–8.3% on functions that read
  `this`, but the ordinary method-without-`this` control regressed a stable
  0.507% cycles over 25 runs solely from handler placement. The candidate was
  reverted; the two fixed `this` probes remain to validate a future shared
  handler/frame collapse.
- **Next P0 evidence target:** the lowest-work control now isolates the shared
  setup/dispatch frontier after the redundant caller reload was removed. Reduce
  `finishForOfNextResult` only where the same proof also helps ordinary calls;
  other internal `runWithArgsState` callers still require their own storage and
  suspension proof, so do not generalize this fast path by callable class alone.

## Pointers

- **qjs mechanism reference:** `CALL-MACHINERY-QJS.md` (verbatim quickjs.c excerpts; the keystone).
- **Live code:** `src/exec/tailcall_dispatch.zig` (dispatch + driver), `src/exec/inline_calls.zig`
  (the call path), `src/exec/frame.zig` (frame + carve), `src/exec/vm_call.zig`.
- **route-2 harness (throwaway):** `/tmp/gen_fib.py`, `/tmp/run_sweep.sh`.
- **Current gates:** `checkpoint-check` 32/32, Debug/ReleaseSafe/alternate-repr unified
  1406/1406, force-GC core/exec 226/226 + 203/203, OOM 8/8, alternate-repr
  test262 smoke 12/12, for-of 751/751, Iterator 514/514;
  109 fixed qjs-alignment perf scripts, with comparisons made through targeted
  interleaved benchmarks (not a suite geomean) against `/home/aneryu/quickjs/qjs`.
