# Handover — int+float `s=s+i` loop alignment (2026-06-28)

Continuation of the dispatch-tax / call-boundary work. This session ground the
float-accumulator loop down to its faithful floor on the (now-active) tail-call
dispatcher and found two **global** codegen levers. Micro-optimization of the
hot opcode is **exhausted**; what remains is **structural** (and big).

## Benchmark

```js
// /tmp/loop.js
function run(){ var s=0; for(var i=0;i<20000000;i++){ s=s+i; } return s; } print(run());
```

After `s` overflows int32 it becomes float64, so 99.7% of the adds are
**float64 + int32 (int+float)**. In BOTH zjs and qjs this MISSES the inline
both-int / both-float fast paths and routes to the slow add
(zjs `op_add_loc_cold`→`addLocal`, qjs `js_add_slow`). So the benchmark isolates
the slow-add + dispatch machinery, not the arithmetic.

Measure with `taskset -c 2 perf stat -e task-clock zig-out/bin/zjs /tmp/loop.js`.
**Rebuild `zig build zjs` first** — the test262 gate (force-GC) overwrites
`zig-out/bin/zjs` and corrupts perf numbers (see memory `zjs-bench-stale-binary-hazard`).

## Result arc

| state | time | vs qjs (458ms) | lever |
|---|---|---|---|
| session start | ~713ms | 1.56× | call-boundary inlining, bare-box hybrid (prior) |
| **i64 tag** | 566ms | 1.24× | partial store-to-load forwarding fix |
| **+ callconv(.c) + phi-split** | **530ms** | **1.155×** | JSValue register passing |

qjs baseline: 458ms (`taskset -c 2 ... /home/aneryu/quickjs/qjs /tmp/loop.js`).

## The two GLOBAL levers (the wins — reusable elsewhere, esp. fib/call machinery)

### 1. `tag: i32 + padding` → `tag: i64`  (src/core/value.zig)
The 16-byte `JSValue` lives in a SIMD (q) register. Reading the 4-byte i32 tag at
offset 8 of a 16-byte SIMD store only **partially** overlaps → no clean
store-to-load forwarding → backend stall. A full **8-byte** load forwards cleanly.
This also matches qjs's `int64_t tag` on 64-bit (NaN-boxing is `#ifndef JS_PTR64`,
i.e. OFF here — qjs is a 16-byte all-integer JSValue). **713→566ms, backend-stall
cycles −63%, test262 unchanged.** Diagnosed with `perf stat -e stalled-cycles-backend`
+ `perf annotate` (str q / ldr at same address = partial forwarding) — NOT
instructions/loads (those were correlated-not-causal red herrings).

### 2. `callconv(.c)` on hot JSValue-by-value functions  (slot_ops.zig `slotValueBorrow`)
Zig's **default** calling convention passes a 16-byte struct **by pointer** —
the caller does `str q0,[sp]; add x1,sp` (spill to stack, pass the address). The
**C ABI** passes a 16-byte all-integer struct in **two registers** (x0,x1) per
the aarch64 PCS. Adding `callconv(.c)` to the hot dup helper killed the spill.
**560→529ms.** ⚠️ This is a GLOBAL Zig-vs-C-ABI misalignment: *every* `fn f(v: JSValue)`
in the interpreter pays the by-pointer spill. Only the loop's hot one was fixed.
**This lever is unreleased on fib / call machinery, which pass many JSValues.**

## Why the remaining hot path is at its floor (micro EXHAUSTED — 6 failed variants)

`op_add_loc_cold` cycle profile (clean, no skid): **`str q0,[x1]` store-s 30%** +
**`bl slotValueBorrow` dup 22%** + everything else <3%.

- **store-s (30%)**: the loop-carried `s` store. qjs's `set_value` stores too. Necessary, aligned (1 store/iter).
- **dup (22%)**: `slotValueDup` = `slotValueBorrow(slot).dup()`. `slotValueBorrow` is a
  **16-deep var-ref cell-walk loop**; qjs's `JS_DupValue` is an inline trivial refcount.
  Verified the cell chain is **depth-1** (`fromValue`→`refHeader` tag check; every
  `setVarRefValue`/`createClosed` stores a plain value; var-refs are not first-class
  values), so the 16-loop is over-defensive — but LLVM can't prove ≤1 iteration so it
  stays a call, and **inlining it bloats**.

**Six variants tried to remove/inline the dup — ALL slower or neutral:**
1. `if (cell_opt == null) frame.locals[idx].dup() else slotValueDup` (line ~453 branch) → 567ms
2. `lhs_borrowed.dup()` (reuse already-resolved borrow, no re-walk) → 553ms, bl→0 but slower
3. global `inline fn` fast path (earlier) → 610ms (binary bloat)
4. no-loop single-check `inline fn slotValueBorrow`+`slotValueDup` → 615ms (LLVM re-outlined, bl still 2)
5. redundant-`refHeader` removal (cell_opt computed twice: once for `cell_opt`, once inside `slotValueDup`) — same as 2
6. (the `op_add_loc_cold` handling int+float directly was judged **CHEATING** earlier and reverted — qjs's OP_add_loc routes int+float to js_add_slow, it does not inline it)

**Conclusion**: the dup's 22% **overlaps** the store-s critical path (removing the
call doesn't shorten the chain; inlining only adds register pressure). The
out-of-line `callconv(.c)` call is **optimal for the current structure**. Do not
re-try local dup micro-opts.

## The real misalignments (NOT a wall — structural, both ~1-session each)

| misalignment | zjs | qjs | faithful fix |
|---|---|---|---|
| **captured locals** | boxing-on-capture: `frame.locals[idx]` is converted **in-place into a cell** when captured (`vm_call.zig:116`, `ensureVarRefCell` slot_ops:525-527) → **every** local op cell-checks, the dup walks the chain | compile-time separation: captured vars live in a separate `var_refs[]` accessed by **distinct opcodes** (`OP_get_var_ref`), so `OP_add_loc` reads `*pv` directly and **never** checks for a cell | compiler capture analysis drives opcode selection + VM split (locals always plain values) |
| **dispatch glue** | tail-call: per-op `publish`(sync pc/sp)/`coldNext`(re-dispatch) | dispatch lives inside `JS_CallInternal`, state register-resident | dispatch-model change (see DISPATCH-TAX-FINDINGS §tail-call threading) |

The capture-separation is the **broadest faithful lever**: it removes the cell
check + chain-walk from ALL local-heavy code, not just this loop, and makes the
dup a trivial inline (qjs's `JS_DupValue`). It is the recommended next slice.

## Recommended next steps (pick one)

1. **Compiler capture-separation** — most faithful, broadest payoff. Spans the
   bytecode compiler (mark/emit captured-var opcodes) + the VM (drop cell checks
   from `op_*_loc`). Removes the dup's cell-walk root.
2. **fib / call machinery** — apply the `callconv(.c)` global lever where it's
   unreleased (the per-call JSValue-by-pointer spills). Likely higher ROI than the
   last 0.155× on this loop. See memory `qjs-call-machinery-deepdive`.
3. **Consolidate** — the loop is a strong 1.155× result; stop here.

## Changeset (all UNCOMMITTED, on top of `b3d48d0`)

Two intertwined bodies of work — the **tail-call dispatch revival** (the active
path, `run`→`tailcall_dispatch.run`) and the **int+float loop opt** on top of it:

- `src/core/value.zig` — **i64 tag** (lever #1)
- `src/exec/slot_ops.zig` — `slotValueBorrow` **callconv(.c)** (lever #2)
- `src/exec/vm_arith.zig` — `addLocal`: consume `toPrimitiveForAdditionFree`, number-inline add, bare-box hybrid, phi-split, outlined string path
- `src/exec/coercion_ops.zig` — `toPrimitiveForAdditionFree` (consume primitive, inline) + borrow wrapper
- `src/exec/value_ops.zig` — `binaryNumber` bare-box hybrid (= `__JS_NewFloat64`)
- `src/exec/call_runtime.zig` — `handleCatchableRuntimeError` noinline
- `src/exec/tailcall_dispatch.zig` (NEW, 916L) — threaded dispatcher; `op_add_loc` both-int+both-float inline, `op_add_loc_cold` hop-collapse
- `src/exec/tailcall_dispatch_colds.zig` (NEW, 861L) — cold handler table
- `src/exec/zjs_vm.zig` — `run` routes to `tailcall_dispatch.run`; `dispatchLoop` retained only for generator suspend/resume re-entry
- `src/exec/vm_call.zig`, `src/exec/vm_gen_async.zig`, `build.zig` — wiring
- docs: `DISPATCH-TAX-FINDINGS.md` (tail-call threading root cause), `FRAME-RAW-SP-BLUEPRINT.md`, `TAILCALL-DISPATCH-ONESHOT-BLUEPRINT.md`

## Validation

test262 is the oracle for the i64-tag + dispatch + cell-depth-1 changes. Expected:
**44589 pass, 6 failures all regexp/unicode** (pre-existing upstream churn —
`known_errors.txt` timestamp predates the regexp commits; ZERO add/dispatch
failures). The `test262-gate` target exits non-zero **because of that pre-existing
regexp churn**, not a regression — verify the 6 failures are regexp-only.
