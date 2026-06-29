# Dispatch-tax investigation — findings + add_loc fusion (2026-06-24)

> **2026-06-27 frame-reduction EXECUTION (goal: shrink dispatchLoop frame to qjs's ~464 B).**
> Verified incremental progress landed: **4256 B → 3952 B (async noinline) → 3904 B (eval var-ref
> migration to frame accessors) → 3872 B (eval_local_names/slots depth-conditional) → 3856 B
> (eval_with_object/eval_global_var_bindings/is_eval_code depth-conditional), −400 B / −9.4 %, every
> step test262 clean (6 pre-existing regexp known-errors, 0 regressions); net −25 lines (the cached
> carriers + switched re-derivations collapse into depth-conditional reads).** Reaches the practical
> cold-context floor (the remaining strict/generator vars are ~16 B and delicate — prologue/reload).
> Re-confirmed outlining is dead: making the 4 generator resume fns `noinline` moved the frame the
> WRONG way (3856→3888, another equally-deep path fills in) — the floor is a *union* of many
> ~equally-deep per-arm spill paths, not a single outlinable site. The remaining 3856→464 B (8.3×)
> is the per-arm JSValue spill
> union that LLVM won't coalesce across the monolithic labeled-switch — removable only by the
> tail-call dispatch rewrite (each opcode → a small function; verified 640 B→112 B/handler in
> isolation). Disproved the earlier "no safe incremental step" claim — cold-context migration
> DOES reduce the frame, but each var's source must be verified: `eval_var_ref_names`/`eval_var_refs`
> are genuinely `frame.cold`-backed (always `== frame.evalVarRefNames()/evalVarRefs()`) → safe to
> migrate to the live accessor (drops the cached carrier, −48 B). `eval_local_names`/`eval_local_slots`
> are NOT frame-backed in the same way: the cached value is `entry_eval_local_names` (this frame's
> OWN eval locals) but `frame.evalLocalNames()` returns the INHERITED merged set for nested eval
> (frame.zig:365 `if (inherited) inherited else inputs`), so migrating them to the accessor broke
> `staging/sm/eval/undeclared-name-in-nested-strict-eval` (test262 caught it) → reverted; their
> correct migration is the depth-conditional `if (machine.depth==0) entry_eval_local_names else &.{}`.
> The remaining cold-context (8 bool/ptr vars) contributes ~0 B to the frame (the 4 slice vars are
> the full 112 B). Landed the one safe complete win and mapped the floor. See bottom section.
> TL;DR: `dispatchLoop` frame was **4256 B** (qjs `JS_CallInternal` is **464 B**, 9×). The cold
> arm-helpers are *already* `noinline` across the codebase — EXCEPT the async/generator entries
> (`yieldValue`/`yieldStar`/`awaitValue`), a genuine oversight. Marking those `noinline` dropped
> the frame to **3952 B** and the function from **56 KB → 36 KB code (−36%)**, test262 clean (the
> only 6 failures are the pre-existing regexp/unicodeSets known-errors, zero async/generator
> regressions). **Measured frame breakdown** (each component isolated empirically):
> | component | frame contribution | how measured |
> |---|---|---|
> | async/generator helper inlining | **304 B** (4256→3952) | `noinline` the 3 async entries (KEPT) |
> | 12 cold context vars (eval/generator state) | **112 B** (3952→3840) | global-sink them out of the live set (measurement-only, reentry-unsafe, reverted) |
> | carriers + per-arm temporaries (`*Stack` method temps) | **~3840 B** (the rest) | residual — needs raw-`sp` |
>
> The decisive finding: **cold context is only 112 B; the 3840 B bulk is the carriers
> (reg_ip/base/sp/var_buf/arg_buf/function/stack/frame/catch_target) + the per-arm temporaries the
> `*Stack`-object method calls generate.** Outlining cold arms (already all `noinline` except the
> async oversight) reduces CODE not FRAME — proven: outlining 4 more generator fns dropped code 1 KB
> but frame went 3952→3984 (a different path became deepest). Removing a single carrier (reg_code_end)
> left the frame UNCHANGED. So the floor is the carrier/temporary spill union across ~100 helper-call
> sites. **The ONLY lever to reach qjs's 464 B is the raw-`sp` keystone** — eliminate the `*Stack`
> object so `sp` is a raw pointer into the frame buffer (qjs's model), making every arm leaner. That
> is 357 `stack` refs + the call machinery + generator cur_sp across suspend — the frame-model
> rewrite (B5), a multi-week planned one-shot, NOT an incremental change. Cold-context→`frame.cold`
> is reentry-safe but only worth 112 B, so not worth its ~154-ref refactor alone.

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
   **→ ROOT CAUSE NAILED 2026-06-27 — see the "Frontier #1 ROOT CAUSE" section at the bottom.**
   It's NOT an LLVM policy gap: LLVM keeps the base resident whenever it can; zjs's 4256 B spill
   frame (vs qjs 464 B) saturates callee-saved so the base is evicted at 107/111 sites.
   **The fix is NOT "un-cache cold vars" (disproven same day — they're already in stack slots,
   not callee-saved). The callee-saved file is held by HOT carriers (reg_ip/reg_sp/opcode/code-ptr/
   frame, already spilling).** Freeing a register requires eliminating a hot carrier (reg_code_end
   / the *Stack object / catch_target) = the lean-frame/raw-sp rewrite. LOW ROI standalone
   (~1/3 of an already-1.24× dispatch gap; other 2/3 is NaN-boxing, blocked) → pursue only as a
   side effect of the frame rewrite, not on its own.
2. **8-byte NaN-boxed JSValue** (halve the per-op value-move cost). BLOCKED: the nan_boxing build
   (`zig build test-altrepr`) currently fails to even COMPILE (pre-existing: `value.zig:108 tag
   is not representable in the NaN-boxed encoding`, fails identically on clean HEAD). Fix that
   first.
3. More peephole fusions qjs has that zjs may lack (audit quickjs.c:34800-35500 `optimize`).

## Tooling added
`ZJS_DISASM=1 zjs file.js` dumps every compiled function's bytecode (qjs DUMP_BYTECODE-style),
wiring the existing `src/bytecode.zig` dump namespace into `createFunctionBytecode`. Use it to confirm
opcode sequences / jump widths / fusion when reasoning about dispatch.

---

## Frontier #1 ROOT CAUSE NAILED — jump-table base rematerialization (2026-06-27)

Resolved frontier #1 from a hypothesis to a fully-isolated root cause with a quantified fix
target. Measured on the Cortex-X925 big core (`taskset -c 7`, PMU pinned so the big.LITTLE dual
counter doesn't distort), zjs (clean HEAD) vs `/home/aneryu/quickjs/qjs` (GCC 13.3.0):

| benchmark | zjs insn | qjs insn | insn ratio | zjs time | qjs time | time ratio |
|---|---|---|---|---|---|---|
| fib(32) (call-bound) | 8.23B | 2.75B | **3.00×** | 0.439s | 0.127s | 3.46× |
| eloop `s=s+1` 5e7 (dispatch-bound) | 8.61B | 6.96B | **1.24×** | 0.375s | 0.287s | 1.31× |

### The codegen smoking gun (objdump of both interpreters)

| | zjs `dispatchLoop` | qjs `JS_CallInternal` |
|---|---|---|
| dispatch sites (`br xN`) | 111 | 295 |
| sites that **rematerialize** the table base (`adrp+add` before `ldr+br`) | **107 (96%)** | **0** |
| sites with table base **resident** (just `ldr x,[base,idx,lsl#3]; br`) | 4 | **287 (97%)** |
| stack frame (spill pressure proxy) | **4256 B** (`sub sp,#0x1000 + #0xa0`) | **464 B** (`#0x1d0`) |
| calls in arms (`bl`) | 370 | 405 |

Every zjs dispatch pays `adrp x8,<page>; add x8,x8,#0xbd0; ldr x8,[x8,opc,lsl#3]; br x8` = **4
insns**. qjs pays `ldr x0,[x0,opc,lsl#3]; br x0` = **2 insns** (table base lives permanently in a
callee-saved register / anchor). At ~8–10 dispatches/iter that is ~16–20 extra insns/iter — a
*broad* tax on every loop, biggest on dispatch-bound code.

### Isolation experiments (minimal Zig labeled-switch interpreters, same Zig 0.16/LLVM)

Built tiny `sw: switch (...) { ... continue :sw code[pc]; }` loops and disassembled to find the
exact trigger. `br`-count and `adrp`-before-`br` count:

| variant | long-lived locals | arm makes a call? | table base |
|---|---|---|---|
| `disp_test` | 3 | no | **resident** (1 adrp total) |
| `disp_test2` | 18 | no | **resident** (LLVM spills the cold locals, keeps the hot base) |
| `disp_min_call` | 2 | **yes** (`extern sink`) | **resident** in x23 (survives `bl` in a callee-saved reg) |
| `disp_k` (n=2..5) | ≤5 | yes | **resident** |
| `disp_k` (n=6) / `disp_low` | 6 | yes | **rematerialized** (adrp+add per dispatch) |
| `disp_test3` | 10 | yes | **rematerialized** (6/6) — reproduces zjs exactly |

**Two necessary conditions, BOTH required (proven by the table):**
1. **The dispatch arms make calls.** A call clobbers caller-saved regs, so the base can only
   survive in a **callee-saved** register. (Pure register pressure with NO calls — `disp_test2`,
   18 locals — does NOT evict the base: LLVM spills the cold locals and keeps the hot base.)
2. **Register pressure saturates the callee-saved file.** With a free callee-saved register the
   base stays resident even across calls (`disp_min_call`/`disp_k≤5`). Once ~6+ long-lived values
   compete (sharp threshold: 5→resident, 6→evicted on aarch64's 10 callee-saved x19–x28), the
   base loses its home and LLVM rematerializes the (cheap, PC-relative, rematerializable)
   `adrp+add` at every dispatch rather than pay to preserve it.

zjs hits **both**: 370 `bl` in arms + a **4256 B** spill frame (callee-saved saturated). qjs hits
only #1 (405 `bl`) — its **464 B** frame means callee-saved is free, so the base stays resident.
**This is NOT an LLVM-vs-GCC codegen-policy gap** (the earlier guess): minimal LLVM keeps the base
resident whenever it can; the eviction is purely zjs's register pressure.

### Why zjs's frame is 9× bigger — the actual "why it became like this"

`dispatchLoop` is a single mega-function (src 784–2645, ~1861 lines) that handles L0 + every
inline frame + eval + generators + module-await + strict/with, and it carries the entire
**per-level execution context as function locals**: 6 hot registers (`reg_ip/base/sp/var_buf/
arg_buf/code_end`) + 4 pointers (`function/stack/frame/catch_target`) + **12 cold context vars**
(`eval_local_names/slots`, `eval_var_ref_names/refs`, `eval_with_object`, `eval_global_var_bindings`,
`is_eval_code`, `strict_unresolved_get_var`, `generator_state`, `stop_on_yield`, `stop_before_pc`,
`suspend_on_module_await`) + `opc`/`interrupt_poller`/`inline_invariants_set`/… ≈ 30+ live values
≫ the register file → 4256 B of spills, callee-saved saturated.

qjs keeps that same per-frame state in the `JSStackFrame sf` struct (read from memory by field
only when a rare op needs it) and holds just ~7 values register-resident (`pc/sp/var_buf/arg_buf/
var_refs/ctx/b`). Small footprint → callee-saved free → table base resident.

### The fix — NOT "un-cache the cold vars" (that was disproven by reading the actual reg-alloc)

⚠️ **Corrected 2026-06-27 (same day):** the obvious fix — "un-cache the 12 cold context vars into
`frame.cold` to free registers" — **does NOT work**, verified against the actual register
allocation in the binary. Disassembling the hot dispatch (`dispatchLoop+0x2c8`) shows the 12 cold
vars are **already staged through stack slots** (`ldr x8,[x28,#152]` = frame.cold ptr → `ldp`
fields → `stp …,[sp,#456/#472]`), NOT held in callee-saved registers. The 10 callee-saved
registers (x19–x28) are all consumed by the **hot carriers**: `reg_ip`=x27, `reg_sp`=x25,
`opcode`=x24, code-pointer pieces x23/x20/x19, `frame`=x28 — and the allocator is **already
over-subscribed** (frame x28 itself gets spilled and reloaded from `[sp,#240]`). So un-caching the
cold vars frees *stack*, not the callee-saved register the table base needs. It would not move the
needle.

**The real constraint:** the table base needs ONE free callee-saved register, and they are all
held by HOT carriers (already spilling). The only way to free one is to **eliminate a hot
carrier**, and the eliminable ones are zjs-isms qjs's hot loop doesn't have:
- **`reg_code_end`** — only used for the `reg_ip >= reg_code_end` bounds check (zjs_vm.zig:1670,
  1713). qjs does NOT bounds-check pc in the hot loop; it trusts every code path to end in
  OP_return. Dropping it is faithful and frees ~1 register — but the allocator may hand the freed
  reg to the currently-spilling `frame` rather than the (rematerializable, so low-priority) table
  base, so this alone likely yields little.
- **the separate `*Stack` object** (357 refs, 154 `syncDown` write-backs) — qjs has no Stack
  object; `sp` is a raw pointer into the alloca'd frame buffer. Eliminating it is the **B5 raw-sp
  rewrite** (HANDOVER-call-dispatch-align.md), part of the frame-model rewrite — big, coupled.
- **`catch_target`** (95 refs) — movable into the frame but woven through exception handling.

### ⏫ SUPERSEDED 2026-06-27 (later same day): the root is ARM COUNT, and tail-call threading FIXES it

The "accept it as an irreducible artifact" conclusion below was **wrong and is retracted.** Pushed
to find the real root with a sweep of minimal labeled-switch interpreters (isolating one variable
at a time), and it is NEITHER carrier count NOR frame size:

| minimal test | carriers | arms (dispatch sites) | arm calls | frame | table base |
|---|---|---|---|---|---|
| disp_lean | 9 ptrs | 4 | 2–3/arm | 128 B | **resident** |
| disp_hi | **16 ptrs** | 4 | 2/arm | 192 B | **resident** |
| disp_many | 8 ptrs | **24** | 1/arm | **112 B** | **EVICTED 25/25** |

16 pointer carriers → still resident; a 112 B frame → still evicted. **The determining variable is
the number of dispatch sites (arms).** With many `continue :sw` sites spread across a big function,
the table base's live range spans the whole function; since `adrp+add` is rematerializable (cheap,
no inputs), LLVM recomputes it at each of the ~100 sites rather than pin a callee-saved register
across the entire large function. This is exactly the **LLVM labeled-switch vs GCC computed-goto**
difference: GCC's `goto *table[op]` treats the table as a first-class object and keeps it in a
register (qjs's ~200-arm function does so, 464 B frame, base resident); LLVM's `switch`/`continue`
lowering does not. So it IS a codegen-mechanism gap — but **the LLVM-side fix is not "relieve
pressure", it's "make the table base a first-class register value", which tail-call threading does.**

**Proven solution — tail-call threaded dispatch (`@call(.always_tail)`):**

| 24-arm minimal test | table-base rematerializations |
|---|---|
| labeled-switch (`disp_many`, current zjs style) | **25 / 25** |
| tail-call threaded (`disp_tc24`) | **0** |

Tail-call codegen: each opcode is its own function; the dispatch table is passed as a **parameter**
(`tbl: [*]const Erased`), so the base sits in a callee-saved register (`x19`) across every handler
and the dispatch is `ldr h,[x19,op,lsl#3]; br h` — qjs's exact 2-insn dispatch. The tail calls
lower to `br` (jumps), NOT `bl`, so there is **no per-op call overhead**; each handler is a lean
leaf with a tiny/zero frame. This is the same technique CPython 3.13's `[[clang::musttail]]`
interpreter and LuaJIT use to get optimal dispatch on LLVM. zjs HAD a tail-call dispatcher and
retired it (eebd7e0) — but the retirement rationale ("the in-function bare loop is aligned, 131<154")
was later **disproven** ([[zjs-dispatch-vs-qjs]] round-2: it's 1.47×), so reviving it as the DEFAULT
path is justified, not a regression.

**The prerequisite (the user's key point):** tail-call passes the hot state as arguments. aarch64
passes 8 args in registers; beyond that they spill to the stack on every dispatch — which would be
slower than today. So the hot state MUST first be lean (~8 values: pc, sp, var_buf, arg_buf,
var_refs/frame, ctx, table). That means the cold-context-to-`frame.cold` + raw-`sp` (drop the
`*Stack` object) + drop-`reg_code_end` work is a **prerequisite**, not an alternative: lean state is
the foundation, tail-call threading is what consumes it to keep the base resident. The two compose
into the real keystone fix. Scope/risks for the rewrite: ~100 opcode handler fns, integrate the
inline-call Machine + generator suspend/resume (handlers must resume via saved state), thread error
propagation; every stage test262 0/49775. Treat as a focused multi-stage project.

---

### (RETRACTED) Cheap probe — "register-pressure relief does NOT fix the base"

The open question — "does raw-sp / freeing registers actually make the base resident, or must we
do the whole rewrite to find out?" — was settled with a ~10-minute throwaway probe instead of the
multi-week rewrite. **Fully removed one hot carrier** (`reg_code_end`: deleted the var, its reload,
its `reloadInlineTopFrame` param + all 5 call sites; recompute `code.ptr+code.len` from memory at
the 2 forward-branch-to-end checks). Rebuilt, re-disassembled:

| | adrp-rematerialized dispatches | stack frame |
|---|---|---|
| baseline | 107 / 111 | 4256 B |
| after removing a full carrier | **107 / 111 (UNCHANGED)** | **4256 B (UNCHANGED)** |

Zero movement (fib still 2178309). **Conclusion: freeing one — or a few — callee-saved registers
does nothing.** The function is so over-subscribed (4256 B spill) that removing a carrier only
marginally shifts *other* spills; it never creates the *slack* the base needs. LLVM treats the
`adrp+add` base as rematerializable (cheap) and parks it last, so it only goes resident when there
is a genuinely free register AFTER every non-rematerializable value is placed — which requires the
function to essentially STOP spilling. raw-sp removes ~3 carriers; the frame would still be ~4 KB,
still spilling, still no slack. **So raw-sp would NOT fix the table base — proven without doing it.**

This means the table base is an LLVM-vs-GCC *codegen-mechanism* artifact, not a register-budget
problem you can relieve incrementally. The only things that would actually fix it change the
dispatch MECHANISM: (a) tail-call threading (each op a fn, `@call(.always_tail, table[op], …)`,
table ptr a live param — definitively resident, but this is the dispatcher that was already
RETIRED in eebd7e0, with per-op ABI overhead), or (b) inline-asm computed-goto pinning the base to
a named register (fragile, unfaithful). Both are disproportionate to the ~7% payoff. Per the
project's own standard ([[zjs-dispatch-vs-qjs]]: dispatch codegen LLVM-vs-gcc is "非忠实可抹平"),
**the correct disposition is to ACCEPT the table base as an abstractable codegen artifact** — it is
not a faithfulness gap, and no cheap effective fix exists.

**Honest ROI:** the table base costs ~2 insns × ~5–6 dispatches/iter ≈ 10–12 insns of the eloop
33-insn/iter gap (172 zjs vs 139 qjs) → fixing it closes ~1/3 of the dispatch gap (1.24× → ~1.16×
on dispatch-bound code), less on call-bound. The other ~2/3 is **NOT** value representation —
qjs on this aarch64 build is ALSO a 16-byte JSValue (JS_NAN_BOXING is `#ifndef JS_PTR64`, off on
64-bit; both interpreters do `…,#16` 16-byte pushes), so NaN-boxing is *not* a qjs-alignment
target. The remainder is diffuse: the separate `*Stack` object's push/pop bookkeeping +
`syncDown` write-backs (where qjs uses a raw `sp`), operand decode, and per-op helper overhead.
Both the table base AND most of that remainder collapse into one fix: **the lean-frame/raw-sp
rewrite** (eliminate the `*Stack` object → raw `sp`, drop `reg_code_end`, move catch/cold to the
frame), which gives the dispatch loop qjs's small register footprint. **So the table base is a
*side effect* of that rewrite, not a standalone fix.** Conclusion: do NOT chase the table base on
its own; either accept the ~1.24× dispatch floor, or get it (plus the Stack-object remainder) when
the operand-stack rewrite happens — noting that rewrite's *fib* payoff is a known mirage
([[frame-rewrite-premise-mirage]]), so its real return is this dispatch cleanup + faithfulness.

The measurement-only `var`→file-scope-global sink of the 12 vars (stash: "wip: global-sink…") is
moot regardless: it does not compile (the 12 names are legitimate public-API parameter names —
`runEvalWithOutput`, `reloadInlineTopFrame` — so globals collide) and is reentry-unsafe, AND per
the reg-alloc finding above it would target the wrong values (stack, not callee-saved). Do NOT
resurrect it.
