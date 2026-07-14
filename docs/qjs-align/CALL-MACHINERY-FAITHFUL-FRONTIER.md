# Call-machinery faithful frontier — current state & conclusion

> **Single source of truth** for where zjs's call/dispatch alignment to QuickJS stands.
> Updated 2026-07-04: method-A first tranche LANDED (`952592f` + `f3a517d`) — see §0. Previous
> update 2026-06-29 after the route-2 de-risk experiment. This doc consolidates and replaces a
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

## 7. Zero-copy JS↔Zig argument ABI — current state & conclusion (2026-07-12)

> Consolidates the four JS↔Zig argument-passing paths, the ownership contract that
> makes zero-copy safe, and the concrete wiring plan for the one path that is _not_
> yet at qjs-internal parity. Supersedes the loose "can we go zero-copy" thread.

### 7.1 Path-by-path state

| #   | Path                                                  | Today                                                                                                                                                                                                                  | qjs anchor                                                                               | At parity?                                               |
| --- | ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| A   | **JS→JS inline** (hot)                                | `initArgumentsBorrowedSlots` — args alias caller's operand-stack slots, value ownership transfers, no payload copy                                                                                                     | qjs `arg_buf = argv` fast path (17828-17871)                                             | **Yes, zero-copy**                                       |
| B   | **JS→Zig** (VM calls builtin)                         | `args: []const JSValue = stack.values[region_base+2..][0..argc]` — a borrow window into the caller's operand stack; region stays pushed for the whole call (roots obj/func/args), `popOwnedStackRegion` releases after | qjs `OP_call_method` `call_argv` borrow + tail `JS_FreeValue` loop (18232)               | **Yes, zero-copy**                                       |
| C   | **Zig→JS** (builtin re-enters VM, `runWithArgsState`) | `initArguments` — per-arg `dup()` into the frame slab                                                                                                                                                                  | qjs public `JS_Call` (`JS_CALL_FLAG_COPY_ARGV`) — also copies argv into the callee frame | **At qjs _public_ parity, NOT at qjs _internal_ parity** |
| D   | **Plugin FFI** (`binding/ffi.zig` `CallFrame`)        | heavyweight wrapper, by design                                                                                                                                                                                         | n/a (qjs has no equivalent plugin ABI)                                                   | Isolated, not on hot path                                |

The gap is **only path C**, and only relative to qjs's _internal_ call path (the
`flags=0` borrow that qjs gives its own operand-stack calls but not to embedders).
zjs's public ABI matching qjs's public ABI is an interop asset, not a deficit.

### 7.2 Why path C copies today (and why qjs's public API does too)

Public-ABI arguments are `const` and caller-owned; the callee's bytecode may
`put_arg` (overwrite an argument slot), which under a borrow would mutate the
caller's memory. Copying decouples the two. This is the same reason qjs's
`JS_Call` sets `JS_CALL_FLAG_COPY_ARGV`. The copy is _correct_, not lazy.

### 7.3 The mechanism for zero-copy path C already exists

`Frame` has three argument-init modes (`src/exec/frame.zig`):

- `initArguments` (327) — dup, current path-C mode
- `initArgumentsBorrowedSlots` (412) — borrow slots, value ownership transfers,
  frame frees values but not storage (qjs `arg_buf = argv`)
- `initArgumentsMoved` (384) — move already-owned slots in, zero refcount churn

What's missing is a selector: `CallEnv`/`runWithArgsState` has no `args_mode`
field, so internal re-entry always picks `initArguments`. **The work is wiring,
not invention.**

### 7.4 Ownership contract for zero-copy path C (all four must hold)

1. **Storage outlives the frame.** Borrowed slice must live to frame teardown.
   Host-stack arrays (native frame wraps the whole call) and caller operand-stack
   regions (no realloc while another frame owns the growth point) both satisfy this.
2. **Value ownership transfers.** Borrow/move mode means the frame frees these
   values; `put_arg` overwrites free the old value and write the new one. Call
   sites must accept "values passed in belong to the engine; dup first if you want
   to keep them." For internal call sites that were going to release the temp
   values anyway, this is free.
3. **Suspendable callees excluded.** Generator/async frames must keep args alive
   across suspend → must copy (qjs does the same: generator frames dup argv into
   the heap frame). The existing `use_inline_frame_storage` gate already excludes
   them — reuse it.
4. **Arity-padding path stays on move, not borrow.** `argc < arg_count` needs
   allocated padding slots (qjs `arg_allocated_size` branch); move the padded
   array, don't dup into it.

### 7.5 Wiring plan (ordered by ROI)

1. **Zero-arg internal callbacks first.** `iterator.next()` / `return()` are
   mostly zero-arg — no ownership problem at all, just skip the args-window slab
   carve. for-of is the highest-frequency callback in real JS; cheapest win.
2. **Single-arg internal callbacks via move.** Promise reactions (1 value, the
   job already owns it), accessors (1 value) — move the job-owned value into the
   frame, save one dup + one free pair.
3. **`Function.prototype.apply`/`call` forwarding via move.** Spread already
   materializes a temp array; move it into the callee frame instead of dup-ing
   each element.
4. **Public ABI stays dup.** This is the qjs `JS_Call` embedder-safety contract
   (const args, caller retains ownership). Do NOT break it. For advanced
   embedders who want zero-copy, add an explicit `callTakingArgs` variant
   (documented ownership transfer), opt-in.
5. **Plugin FFI `CallFrame` stays isolated.** Its wrapper cost stays out of VM
   internal paths.

### 7.6 Payoff

Per internal callback: `argc` dups + `argc` frees (atomic refcount memory
traffic) eliminated, plus one args-window slab carve skipped. Each item is small
alone, but for-of / map / filter / then-chains run millions of callbacks, and
this multiplies with the **boundary-shim** work (§6-adjacent): the shim drops
re-entry fixed cost to an inline-push; `args_mode` drops the argc-scaled variable
cost to zero. Together they bring Zig→JS callback cost down to qjs-internal-path
magnitude.

### 7.7 Invariants this adds (load-bearing for any path-C work)

- **Public ABI dup is a contract, not a perf bug.** Don't "fix" it by flipping
  `JS_Call` to borrow — that breaks embedder ownership semantics.
- **Borrow/move only on internal call sites that already own the values** (job
  queue, iterator protocol, accessor dispatch, internal apply/call). External
  callers go through the dup path.
- **Suspend gate is non-negotiable.** Generator/async/eval callees copy, always.
  Reuse `use_inline_frame_storage == false` as the discriminator; do not invent a
  new one.
- **Storage-lifetime proof per call site.** Every site flipped to borrow/move
  must have a one-line comment stating why the backing storage outlives the frame
  (host stack array / caller region / job-owned temp). This is the kind of
  invariant that costs 2 bugs if unwritten (see §4 "thread an opcode" discipline).

## Pointers

- **qjs mechanism reference:** `CALL-MACHINERY-QJS.md` (verbatim quickjs.c excerpts; the keystone).
- **Live code:** `src/exec/tailcall_dispatch.zig` (dispatch + driver), `src/exec/inline_calls.zig`
  (the call path), `src/exec/frame.zig` (frame + carve), `src/exec/vm_call.zig`.
- **route-2 harness (throwaway):** `/tmp/gen_fib.py`, `/tmp/run_sweep.sh`.
- **Gates:** `zig build zjs` first (stale-binary hazard), then test262 0/49775 + `zig build test` 1223 +
  force-GC; perf via targeted benchmarks (NOT the microbench-suite geomean) vs `/home/aneryu/quickjs/qjs`.
