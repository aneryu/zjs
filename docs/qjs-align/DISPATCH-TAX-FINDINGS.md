# Dispatch-tax investigation — findings + add_loc fusion (2026-06-24)

Branch `qjs-dispatch-investigation` (on top of the global-var_ref work). Goal: the broad
~2.4×-qjs per-opcode interpreter cost that affects EVERY loop (local reads, arithmetic, empty
loops), separate from the global-var_ref and call-machinery frontiers.

## Measurement baseline (ReleaseFast zjs vs `/home/aneryu/quickjs/qjs`, perf stat instructions)

The default `zig build zjs` IS ReleaseFast (verified: `-Doptimize=ReleaseFast` gives identical
instruction counts), so the gap is real, not a ReleaseSafe artifact.

| benchmark | zjs (before) | qjs | ratio |
|---|---|---|---|
| bare loop `for(i<N){}` | 145 insn/iter | 99 | 1.47× |
| `s=s+1` (eloop) | 332 insn/iter | 139 | 2.39× |
| local read `s=s+a+b` | 24.0B | 10.2B | 2.35× |

## What was ruled out

- **Float-bound deopt**: `5e7` vs `50000000` identical — not a float-comparison issue.
- **Per-iteration prologue / non-threaded back-edge**: the new `ZJS_DISASM` disassembler shows
  the loop back-edge is `goto8`/`if_false8` — both THREADED. Loops stay in a `continue :sw`
  threaded chain and never hit the dispatch-loop prologue (interrupt poll / profile scope /
  6-register reload). Threading `if_true8` (a real asymmetry — if_false8 was threaded, if_true8
  not) had ZERO measurable effect, confirming the loops don't use it.
- **Generic `add` heaviness**: making the int binary arm register-resident on `reg_sp` (mirror
  the lean `op.lt` arm, dropping the sp_len ptr-round-trip window helper) gained only ~1%.

## Root finding

The ~2.4× is **distributed per-opcode** (perf annotate of the all-inlined dispatchLoop): the
central threaded dispatch (`ldrb opc / adrp table / br x8`), 16-byte JSValue moves (`str q0` /
`ldr q0`), and operand decode. Two structural contributors:
1. The jump-table base (`adrp`) is re-materialized at every dispatch site instead of hoisted to
   a register across the loop (LLVM codegen of the labeled `switch`/`continue :sw`).
2. 16-byte JSValue loads/stores per push/pop (the standard, NaN-boxing-off representation).
There is **no single fixable hotspot** — this is fundamental interpreter efficiency
(dispatch codegen + value representation), a deep frontier on par with the frame-model rewrite.

## What shipped — add_loc fusion (commit `f2cd63f`)

The disassembler exposed one concrete, qjs-faithful win: `s = s + expr` (and `s += expr`) on a
LOCAL was NOT fused — it emitted `get_loc(n); W; add; put_loc(n)` (4 ops, generic add). QuickJS
fuses exactly this (quickjs.c:35417-35458, and the `XXX: should optimize loc(a) += expr as expr
add_loc(a)` note at 32797). zjs had the `add_loc` opcode (even threaded) but never EMITTED it
(only inc_loc fusion existed).

Extended the inc_loc peephole (finalize.zig) to fuse `get_loc(n); W; add; put_loc(n)` ->
`W; add_loc(n)` for a single side-effect-free operand W (push_i32/const/atom, small-int pushes,
get_loc/get_arg/get_var_ref — qjs's operand set; `get_var` excluded since a global getter can
have effects). Jump-safe because at this pipeline stage every jump target carries an `OP_label`
marker, which breaks the contiguous match (same argument as inc_loc fusion).

| benchmark | before | after | qjs | ratio |
|---|---|---|---|---|
| eloop `s=s+1` | 16.6B | **9.2B** | 6.96B | 2.39× → **1.32×** |
| `s=s+x` | 18.8B | **11.4B** | 7.0B | 2.66× → **1.63×** |

Global read/write and fib unchanged (global `get_var` isn't a fusable operand — faithful; fib
has no accumulator). Gates: test262 0/49775 + 1223 unit + force-GC 1223. Accumulator loops
(sums, counters, string builders, `x += …`) are extremely common, so the win is broad in
practice even though the targeted global/fib benchmarks don't move.

## Remaining dispatch frontiers (deep, no quick win)

1. **Hoist the jump-table base out of the dispatch.** Each `continue :sw` re-materializes the
   table page via `adrp` (~1 insn/dispatch × ~8-10 dispatches/iter). Would need LLVM to keep the
   table base in a callee-saved register across the loop, or a hand-rolled dispatch (the retired
   tail-call dispatcher, or an explicit computed-goto-style table). Investigate first.
2. **8-byte NaN-boxed JSValue** (halve the per-op value-move cost). BLOCKED: the nan_boxing build
   (`zig build test-altrepr`) currently fails to even COMPILE (pre-existing: `value.zig:108 tag
   is not representable in the NaN-boxed encoding`, fails identically on clean HEAD). Fix that
   first.
3. More peephole fusions qjs has that zjs may lack (audit quickjs.c:34800-35500 `optimize`).

## Tooling added
`ZJS_DISASM=1 zjs file.js` dumps every compiled function's bytecode (qjs DUMP_BYTECODE-style),
wiring the existing `src/bytecode/dump.zig` into `createFunctionBytecode`. Use it to confirm
opcode sequences / jump widths / fusion when reasoning about dispatch.
