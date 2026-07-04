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
  already has them; the vm-field stores are the irreducible tail-call-architecture cost —
  the next structural lever there is widening the handler signature to carry
  code_base/arg_buf in registers, a ~250-handler mechanical rewrite, unproven).
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
  both ~0.30× qjs. The dispatch *mechanism* is not the lever. The old POC's 0.32× win is overwhelmingly
  "the toy skips real per-call work" (refcount dup/free, frame setup, shape/GC), not architecture.
- **The lever for the remaining fib gap (~2.66× qjs) is aggressive method-A:** collapse the call-path
  function decomposition and strip the per-call bookkeeping qjs doesn't have — **keeping tail-call
  dispatch**. Low risk, incremental, gate-able.
- **Native recursion (the other half of "axis ②") is UNPROVEN and risky.** `Path B` (native recursion
  + real per-call work) *regressed* to 6.04× on deep fib. Treat it as a separate, later, real-work-modeled
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
+ `/tmp/run_sweep.sh` (parameterized fib interpreter, opaque-call padding arms, `taskset -c 8`, fib(30)×3
= 8,077,611 calls). Reproduced the POC exactly (9 arms = 107.6 = the old 107.5).

| dispatch | arms | insn/call | vs qjs (389) | table base (objdump) |
|---|---|---|---|---|
| labeled-switch | 9 (POC) | 107.6 | 0.28× | resident |
| labeled-switch | 96 | 116.1 | 0.30× | resident (adrp=2) |
| labeled-switch | **224** | 116.1 | **0.30×** | **resident — 2-insn dispatch** |
| tail-call | 224 | 111.6 | 0.29× | resident |
| current zjs (real work) | — | ~1036 | 2.66× | — |

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
  locals/var_refs setup, stack-overflow check, shapes/GC — all of which qjs *also* does (hence qjs = 389,
  not 115). So a real collapse can't reach 115; its honest target is *qjs's order*, by removing the
  function-decomposition tax + the bookkeeping qjs lacks.

## 4. Invariants that must NOT be broken (load-bearing — any call-path work preserves these)

- **Ownership lockstep.** `current_function` is **KEPT OWNED** (the "borrow cur_func" facet is rejected —
  `takeSourceSlot` is a *move*, not a dup, so refcount is already identical to qjs; nothing to remove).
  The `var_refs` borrow safety is **coupled to `current_function` being owned** — the still-live function
  object roots the borrowed cells. Flipping one ownership flag without the other → double-free or leak
  (force-GC + test262 are the oracle).
- **Frame stays its current ~15-field shape; do NOT slim to 9.** Rejected for real reasons: the teardown
  cost is the *necessary* value frees (not field proliferation), and most "cold" fields
  (`storage_*`, `original_args`, eval/sync state) **cross generator/async suspend**, so a `FrameCold`
  side-struct can't be freed at teardown for a suspended generator. `FrameCold` already exists and is
  correct as-is.
- **Suspend / raw-sp bifurcation — preserve all gates.** Hot inline frames borrow a slab window; cold
  growable frames (top-level / native re-entry / generator / async) keep the full heap-backed `Stack`.
  Generators transfer buffer ownership into the generator object and *physically cannot* use a borrowed
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
  reg-alloc: the cold vars are already in stack slots, not callee-saved; only eliminating a *hot* carrier
  frees a callee-saved register (and that's the raw-sp rewrite, whose fib payoff is a known mirage).

## 6. If native recursion is ever pursued (crossing concerns)

Only as a separate experiment, *after* a real-work-modeled de-risk (the toy can't settle it; `Path B`
regressed to 6.04× with real work + the old slow path). Ground-truth these first:
- **Suspend.** Generator/async yield must unwind the native stack via a Zig error/sentinel (qjs's
  `FUNC_RET_YIELD` analog); simple-normal calls recurse, generator/async/class-ctor/eval stay on the
  current path (already excluded by `resolveInlineTarget`'s `func_kind != .normal`).
- **Deep recursion / stack overflow.** Native recursion uses the real stack → needs a TCO trampoline for
  proper tail calls + a `js_check_stack_overflow` equivalent.
- **Backtrace / exception.** Walk the live `Frame` chain (qjs `current_stack_frame->prev`); Zig `error`
  propagates naturally up the stack, replacing the explicit Entry-chain unwind.

## Pointers

- **qjs mechanism reference:** `CALL-MACHINERY-QJS.md` (verbatim quickjs.c excerpts; the keystone).
- **Live code:** `src/exec/tailcall_dispatch.zig` (dispatch + driver), `src/exec/inline_calls.zig`
  (the call path), `src/exec/frame.zig` (frame + carve), `src/exec/vm_call.zig`.
- **route-2 harness (throwaway):** `/tmp/gen_fib.py`, `/tmp/run_sweep.sh`.
- **Gates:** `zig build zjs` first (stale-binary hazard), then test262 0/49775 + `zig build test` 1223 +
  force-GC; perf via targeted benchmarks (NOT the microbench-suite geomean) vs `/home/aneryu/quickjs/qjs`.
