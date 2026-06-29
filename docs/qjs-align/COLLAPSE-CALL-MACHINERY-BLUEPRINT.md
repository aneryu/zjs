# Collapse call-machinery to single-function C-recursion — blueprint v0 (2026-06-29)

> The terminal-state plan to make zjs's call machinery a qjs-style single recursive function, so
> call-heavy code (fib/funcall) faithfully matches — and likely beats — qjs. Per
> [[frame-rewrite-one-shot]]: exhaust ground-truth + write to terminal state in one shot.
> Evidence base: `CALL-MACHINERY-FAITHFUL-FRONTIER.md` §⑥.

## Why this overturns FRAME-MODEL-ONESHOT-BLUEPRINT

`FRAME-MODEL-ONESHOT-BLUEPRINT.md` states the terminal model is **NOT** a Zig-recursive rewrite —
"keep loop-in-place, residual 1.3-1.5×". That stance assumed collapse had no big payoff / hit a floor.
**The §⑥ probe refutes it:** a Zig single-function recursive interpreter (in-function labeled-switch +
op_call recursing into itself) runs fib at **124.5 insn/call = 0.32× qjs** even with type checks +
stack-overflow guard + frame chain. zjs loop-in-place is 1036/call. **The 8× gap is function
decomposition (15 fns vs 1), not a Zig floor.** So collapse IS the lever, and this blueprint supersedes
the "keep loop-in-place" stance for the call path.

## Core insight: the change is op_call's RETURN model, not the dispatcher

Today (loop-in-place): `op_call` resolves the callee, sets `vm.tail_request`, returns `.tail`; the
driver (`runTC`/`zjs_vm.zig:712`) does `machine.pushCall` + `continue` — the callee runs on the SAME
dispatch loop via the `Machine.Entry` chain, return via `reloadInlineTopFrame`. **All call state is
externalized to the heap Entry chain.**

Target (qjs C-recursion): `op_call` **directly recurses** into a "run one callee frame to its return"
entry, gets the return JSValue, pushes it, continues the caller. Caller's pc/sp/var_buf survive in
registers/stack across the recursive call (the C calling convention does the save — same `stp×6` qjs
pays). **No Entry chain, no reloadInlineTopFrame, no externalized call state.**

## Two dispatch shapes — the key open decision (needs ground-truth)

**A. Single-function in-function dispatch (labeled-switch), qjs-most-faithful.** One big function,
`sw: switch` over all ~150 ops, op_call recurses into it. This is exactly qjs `JS_CallInternal` +
exactly the §⑥ probe shape. **Risk:** the probe is fib-only (17 ops); a FULL-op single function is a
giant labeled-switch — memory [[dispatch-table-base-remat-rootcause]] measured the old `dispatchLoop`
(full-op labeled-switch) at 4256 B frame. **BUT** that frame was bloated by 12 cold context vars carried
as function locals; qjs keeps them in `JSStackFrame` (memory reads). **Unknown to ground-truth: does a
LEAN full-op single function (cold state in a frame struct, ~7 hot locals like qjs) avoid the bloat?**
The probe says lean small functions are fine; the question is whether lean+big stays fine.

**B. Keep tail-call threaded dispatch (HEAD) + make op_call C-recurse.** HEAD is already tail-call
threaded (per-op small functions, no giant-function frame bloat, dispatch already 4-insn faithful). Only
change op_call: instead of `.tail`+driver-switch, call a `runFrameToReturn(callee, args)` that builds the
callee frame and runs the tail-call dispatch to that frame's return, returns the JSValue. **Pro:** keeps
the solved dispatch-frame problem; smallest delta. **Con:** `runFrameToReturn` is a normal (non-tail)
call inside an `always_tail` handler — legal (only the final `next` must be tail position), but the
recursion crosses the tail-call ABI; needs a dispatch entry that stops at THIS frame's return (not L0).

**Recommendation:** prototype **B first** (smallest delta, keeps dispatch win), measure fib per-call. If B
hits qjs's order → done. If B carries loop-in-place residue that won't collapse → fall back to **A** and
ground-truth the lean-big-function frame question. Path B's deleted `call_internal.zig` (git
`eebd7e0~1`, `recurseInlineCall` + TCO trampoline, worktree `/tmp/zjs-pathb`) is the resurrection base
for the recursion plumbing (but its op_call goes through the OLD execCall slow path — see §④ of the
findings doc; HEAD's inlined op_call resolve must be kept).

## Crossing concerns (ground-truth before writing)

1. **Suspend (generator/async).** qjs: monolithic + `JS_CALL_FLAG_GENERATOR` re-entry, state on heap
   (`JSAsyncFunctionState`), yield = `return FUNC_RET_YIELD` unwinding the C stack. zjs suspend
   (`vm_gen_async.zig`) is ORTHOGONAL to the call model (proven this session) — but C-recursion must
   **gate**: simple-normal calls C-recurse; generator/async/class-ctor keep the current path (they're
   already excluded by `resolveInlineTarget:79` `func_kind != .normal` + the admission gates). A
   suspended generator inside a C-recursive caller unwinds the C stack via Zig error/sentinel — design
   the sentinel like qjs's FUNC_RET_YIELD.
2. **Exception unwinding.** C-recursion makes this SIMPLER — Zig `error` propagates naturally up the C
   stack, replacing `machine.unwindForError` + the Entry-chain drain. Per-frame `errdefer` (close
   for-of iterators, free frame) runs on unwind.
3. **Deep recursion / C-stack overflow.** fib(30) is 30 deep — fine. But 100k strict tail calls would
   blow the C stack → need the TCO trampoline (Path B's `recurseInlineCall` reuses the frame for proper
   tail calls) + `js_check_stack_overflow` equivalent (the §⑥ probe's depth guard, ~0 cost).
4. **Backtrace.** Walk the live C-recursion `Frame` chain (each frame's `prev`), replacing the
   `MachineBacktrace` Entry walk — closer to qjs `current_stack_frame`.

## Ground-truth checklist (do BEFORE writing terminal state)

- [ ] B feasibility: can an `always_tail` op_call handler make a normal recursive `runFrameToReturn`
      call + then tail `next`? Write a minimal PoC, confirm it compiles + the recursion doesn't spill
      the dispatch ABI.
- [ ] `runFrameToReturn`: the dispatch entry that runs ONE frame to its `op_return` and returns the
      value (not to L0). How does HEAD's `runTC` decide "this frame returned"? (`op_return` →
      `popReturn` → `reloadInlineTopFrame`; need a variant that returns to the C caller at depth boundary.)
- [ ] Frame build for the recursive callee: reuse `setupSimpleInlineEntry`'s lean carve, or a fresh
      `alloca`-style stack array (the probe used a fixed `[32]JSValue` — what's zjs's var_count/stack_size
      bound per call?).
- [ ] Suspend sentinel design: how a generator yield inside a C-recursive frame returns through the C
      stack without losing caller state (qjs FUNC_RET_YIELD analog).
- [ ] A-fallback: if B fails, measure a LEAN full-op single-function labeled-switch frame (cold state in
      frame struct) — does it stay small or bloat like the old dispatchLoop?

## Staging (one-shot per concern, gate after each)

This is NOT incrementally flag-gated (per doctrine), but is naturally staged by call kind:
1. simple-normal C-recursion (fib/funcall) — the hot 90%, the whole perf win.
2. method calls (`op_call_method`) — same recursion, receiver `this`.
3. keep generator/async/class-ctor/eval on the current path (gated out), wire the suspend sentinel.

Correctness gate each stage: test262 0/49775 + unit + force-GC. Expected fib landing: from 2.66× toward
qjs's order or below (probe headroom 0.32×).

## Status

Blueprint v0 — design space + key open decision (A vs B) + ground-truth checklist laid out. NOT yet
ground-truthed enough to write terminal state. Next concrete step: the B-feasibility PoC (does
`always_tail` op_call + recursive `runFrameToReturn` compile + stay lean). That 1-2 day PoC decides A vs B
and de-risks the multi-week rewrite.
