# Handover — qjs-faithful perf alignment round 2 (2026-06-24)

Branch `qjs-faithful-perf-round2` (linear on top of main `9fc72eb`), 4 commits, each gated
`test262 0/49775` + `zig build test` 1223 + force-GC 1223:

```
44149a4 perf(zjs): qjs-faithful global access — drop per-access authoritative findProperty (bind-once)
b434b8b docs(qjs-align): dispatch-tax investigation findings + add_loc fusion handover
f2cd63f perf(zjs): qjs-faithful add_loc fusion — accumulator loops 2.4×→1.3× qjs
6d3f679 feat(zjs): qjs-faithful global var_ref lowering — global read/write 7×→~2.5× qjs
```
Not merged to main, not pushed (no instruction to). Working tree clean except the pre-existing
`test262` submodule pointer (not ours).

## Method (the doctrine, after a mid-round course-correction)

The owner course-corrected mid-round: **do not chase microbenchmark numbers or invent optimizations
to "tie qjs" — diff zjs's IMPLEMENTATION against qjs's, find the structural divergences, and
eliminate them. Perf is the *result* of faithfulness, not the target pursued directly.** Every win
below is a qjs structure zjs was missing or diverging from, with a `quickjs.c:N` anchor. The
`add_loc` fusion is the canonical shape: qjs has the peephole, zjs lacked it → add it.

A factual correction that reframed the whole "broad tax": **qjs on this aarch64 host is 16-byte
JSValue (`sizeof(JSValue)=16, JS_NAN_BOXING=0` — the `#define JS_NAN_BOXING` at quickjs.h:64 is
inside `#ifndef JS_PTR64`, and JS_PTR64 is set on 64-bit).** zjs default is also 16-byte. So the
comparison is like-for-like; **NaN-boxing is a non-issue here (enabling zjs's 8-byte mode would
DIVERGE from this qjs, not align), and is also currently a pre-existing compile failure** —
`value.zig:108 tag not representable`, fails identically on clean HEAD, unrelated to this work.

## Results (targeted benchmarks, `perf stat -e instructions`, vs `/home/aneryu/quickjs/qjs`)

| benchmark | round start | shipped | qjs | start→ship vs qjs |
|---|---|---|---|---|
| global read `s=s+g+h` | 76.6B | **25.4B** | 10.8B | 7.08× → **2.35×** |
| global write `g=g+1` | 69.4B | **17.8B** | 10.4B | 6.70× → **1.71×** |
| accumulator `s=s+1` | 16.6B | **9.2B** | 7.0B | 2.39× → **1.32×** |
| fib(34) | 26.2B | 26.1B | 7.2B | 3.64× → **3.64× (unchanged — frame-model-gated)** |

Global access now equals **local** access (both ~2.35× qjs): the global-specific divergence is
gone; the residual 2.35× is the shared broad dispatch tax (see below).

## Divergences eliminated (with qjs anchors)

1. **Global var_ref lowering** (`6d3f679`). Top-level `var`/function → `JS_PROP_VARREF` cell;
   `.global` closure vars alias it; OP_get_var/OP_put_var deref the cell directly. qjs
   `js_closure_define_global_var` / `OP_get_var` (quickjs.c:17125, 18462). Fixed 33 scope regressions
   the lowering introduced (4 staged sub-fixes — directEvalGlobalVarNeedsRef ordering, generator
   stop-boundary guard on the threaded lanes, don't-convert-existing-global-props, parent-eval-shadow
   guard). Detail: `HANDOVER-global-varref.md`.
2. **add_loc fusion** (`f2cd63f`). `get_loc(n); W; add; put_loc(n)` → `W; add_loc(n)` for a
   side-effect-free operand W. qjs peephole quickjs.c:35417-35458. zjs had the opcode (even threaded)
   but never emitted it. Accumulator loops (sums/counters/string-builders) 2.39×→1.32×.
3. **Global bind-once** (`44149a4`). Removed the per-access `global.findProperty(name)`
   authoritativeness re-check. qjs's OP_get_var is a bare `*var_refs[idx]->pvalue` deref + an
   uninitialized→fallback branch, with NO per-access check (the binding is fixed at closure creation;
   non-configurable globals never orphan). Replaced with the one real precondition it compensated
   for — a global lexical shadows a global var (qjs's global_var_obj precedence) — gated cheaply on
   `ctx.lexicals == null`.

## Remaining frontiers — both DEEP, neither a quick "continue"

### 1. Frame-model rewrite (the only thing that moves fib; multi-week, high-risk)
Profiling fib: `Machine.pushFrame` is **25%** of total, `execCall` 12%, teardown ~7% — the call
PATH is ~44%, dominated by **frame setup**. The divergence (dissected in `CALL-MACHINERY-QJS.md`):
- qjs: 72-byte pointer-only `JSStackFrame` C-local + ONE `alloca` carving args/vars/stack/own-refs +
  free C-recursion unwind + refcount-only liveness (collector never walks the frame chain).
- zjs: a 27-field `Frame` in a heap-resident chunked `Entry` + a separate `Stack` object + a
  `VmStackArena` mark/restore watermark + a multi-resource teardown.

This is the prior round's deferred item. The earlier HANDOVER (this session's predecessor) already
verified-away the easy sub-pieces: "borrow cur_func" is a MOVE not a dup (zero refcount diff, NOT a
real gap), and "Frame slim (B3)" is low-benefit/high-complexity (the teardown cost is the NECESSARY
value frees qjs also does, AND the cold fields cross generator/async suspend so a FrameCold
side-struct can't be freed at teardown for a suspended generator). The remaining per-call items don't
help fib specifically: `var_refs` borrow (#2) needs splitting qjs's two-array model (borrowed
captures vs alloca-resident own-refs — zjs conflates them into one growable `frame.var_refs` that
`ensureVarRefsCapacity` reallocs mid-frame on nested capture); eager-`this` (#3) only helps bodies
that read `this` (fib doesn't); backtrace shadow chain (#4) is small. **Only the monolithic frame
collapse (#1) moves fib, and it must handle generator/async suspend-crossing + borrowed-arg/var_ref
lifetimes — a dedicated multi-session project with a step-by-step gated plan, NOT an ad-hoc edit.**

### 2. Broad dispatch tax ~2.35× — mostly LLVM-vs-gcc codegen, NOT a faithful divergence
Investigated with a new bytecode disassembler (`ZJS_DISASM=1`, qjs DUMP_BYTECODE-style, wires
`bytecode/dump.zig` into `createFunctionBytecode`). Findings:
- The dispatch STRUCTURE is aligned (register-resident sp/pc/stack + threaded `switch`+`continue :sw`).
  That prior alignment is intact.
- Concrete codegen divergence (~26% of the bare-loop gap): the jump-table base is **not hoisted**.
  zjs's `continue :sw` emits `adrp page; add #off; ldr table[opc]; br` (re-materializes the table
  address every opcode); qjs's gcc computed-goto keeps the table base in a register → `ldr [base,opc];
  br`. Zig's labeled-switch (LLVM) doesn't hoist it; the only fix is the retired tail-call dispatcher
  structure (a Zig-level handler table) — deep, ~8% bare-loop payoff, low ROI.
- The remaining ~74% is op-body codegen: equivalent logic (e.g. zjs `lt` does `asInt32() orelse break`
  per operand vs qjs's one combined `JS_VALUE_IS_BOTH_INT`), LLVM emitting more instructions than
  gcc -O2 for the same algorithm. NOT a structural divergence — not faithfully eliminable.
- Ruled out (with experiments): per-iteration prologue / non-threaded back-edge (loops stay in
  threaded `goto8`/`if_false8` chains — threading `if_true8` had zero effect); generic-add heaviness
  (made it register-resident like `lt`, ~1%). The remaining qjs `optimize` peepholes zjs lacks are
  minor (`i32 neg→i32(-val)`, `dup put_x drop→put_x`, `put_x get_x→set_x`); add_loc was the big one.

## Tooling added this round
`ZJS_DISASM=1 zjs file.js` dumps every compiled function's bytecode (raw bytes + offsets). Committed
in `f2cd63f` (finalize.zig). Use it to confirm opcode sequences / jump widths / fusion.

## Gates / how to verify
- `zig build test262-gate` → 0/49775 (the hard correctness gate; covers TDZ/eval/with/cross-realm/delete).
- `zig build test` → 1223; `zig build test -Dzjs_force_gc=true` → 1223.
- Perf: `taskset -c 19 perf stat -e armv8_pmuv3_1/instructions/ <bin> /tmp/{fib,gread,gwrite,eloop_int}.js`.
- `zig build test-altrepr` (nan_boxing) FAILS TO COMPILE — pre-existing (clean HEAD too), unrelated.

## Pointers
- qjs source: `/home/aneryu/quickjs/quickjs.c` (quickjs-ng 2026-06-04, 16-byte JSValue on this host).
- This round's docs: `HANDOVER-global-varref.md`, `DISPATCH-TAX-FINDINGS.md`, `CALL-MACHINERY-QJS.md`,
  `FRAME-STRUCTURAL-ALIGN.md`, `GLOBAL-VARREF-PLAN.md`.
- Next: if pursuing fib, write a step-by-step gated frame-model-rewrite plan first (handle suspend
  crossing); the broad dispatch tax is largely codegen quality, not a faithful target.
