# Handover — qjs-faithful perf alignment round 2 (2026-06-24)

> **2026-06-25 round-6 addendum (frame-E threaded resume + qjs-absent fast-path deletion).** The
> frame rewrite continued past the keystone with the threaded-resume facet, then pivoted (owner
> guidance: "fast paths zjs has that qjs does NOT have can be deleted") to deleting qjs-absent fast
> paths. **fib 3.26× → 3.01× this round** (continuing from round-5's 3.46×→3.26×; campaign start 3.64×).
> Each gated test262 0/49775 + 1223 + force-GC 1223. **Lesson burned repeatedly: estimates were wrong
> every time — measure on a fresh `zig build zjs`. The stale-binary hazard struck a 4th and 5th time.**
> - **`b822492` hoist inline-invariant per-level locals** (3.328×→3.277×, −368M). The prologue re-set
>   all 17 per-level locals per frame switch; 10 are constants for every inline frame — set once on
>   entering the inline regime (`inline_invariants_set`), skip on inline→inline switches.
> - **`e23d30c` inline returnTop/finishFunctionReturn** (3.277×→3.257×, −139M).
> - **`207676f` threaded post-call/post-return resume** (3.257×→3.189×, **−489M**). The inline call/
>   return arms `continue`d through the cold prologue every time; now a `reloadInlineTopFrame` helper
>   reloads the dispatch registers from the top Entry and `continue :sw` straight into the next opcode,
>   skipping the prologue (gated on `inline_invariants_set`; L0/exception/generator stay cold). qjs's
>   `*sp++ = ret; opcode = *pc++; BREAK` analog. Bigger than estimated — the compiler keeps reg_* live.
> - **`29869d9` inline Stack.deinit + Frame.init** (3.189×→3.122×, **−480M**). Frame.init inline lets
>   the compiler elide the dead default writes setupInlineEntry immediately overwrites.
> - **`dada9d3` execCall: try resolveInlineTarget FIRST** (3.122×→3.032×, **−645M**). Skips
>   fastHostOutputCall + isCurrentSuperConstructor for inline calls — safe because resolveInlineTarget
>   returns null for constructors (super never resolves inline) and host fns aren't bytecode.
> - **`67daad1` delete fastHostOutputCall** (3.032×→3.012×, −147M). A per-call console.log probe qjs
>   lacks; console.log now dispatches as an ordinary host fn.
> - **`e5296a8` delete the method-position simple-numeric fusion probe** (method 11.43B→11.31B). The
>   ++var-ref pattern probe qjs lacks; the ++c-via-method case still computes via the slow path.
>
> **Round-6 end-state: fib 3.012× (21.64B), method 3.062×.** Profiling: dispatchLoop ~52%, pushFrame
> ~25%, execCall ~12%, teardown ~8%. pushFrame (the arena-carve alloca substitute) and dispatchLoop
> (LLVM-vs-gcc codegen) remain the structural floor.
>
> **qjs-absent fast-path deletion — survey done, more to delete (owner direction).** A 5-agent survey
> (`qjs-absent-fastpath-survey`) ranked zjs fast paths qjs lacks. DONE: fastHostOutputCall, the method
> fusion probe. REMAINING (each deletes a qjs-absent probe, aligns, may regress a non-fib bench):
> - **the simple_numeric_kind/simple_string_kind fusion layer** (inline_calls.zig resolveInlineTarget
>   filter + callSimpleNumericBytecode/callSimpleStringBytecode + the parser detection) — qjs has no
>   fusion; deleting it routes those fns through the normal interpreter (regresses accumulator/getter
>   benches, the documented "cheat layer" the doctrine says to revert).
> - ~~method-dispatch native fast paths~~ — **TESTED + REVERTED. NOT deletable.** Deleting
>   fastNativeMethodCall + qjsArrayMethodFastCall and routing native methods through
>   callValueOrBytecodeClassMode **regressed mapget 10.56B→11.30B (+710M)** while arrmap was flat.
>   The survey was wrong: `fastNativeMethodCall` is the FAITHFUL equivalent of qjs's
>   `js_call_c_function` (quickjs.c:17562) — qjs's "magic dispatch" IS a fast direct C-pointer call,
>   not a slow general path, so zjs's probe mirrors it rather than diverging. The generic
>   vmNativeCallableDispatch is slower than this faithful fast path. **Lesson: the survey conflated
>   "zjs has a helper qjs has no named function for" with "qjs has no fast path" — but qjs's fast path
>   is inline in js_call_c_function. Always MEASURE a deletion; "qjs-absent" needs the perf check, not
>   just a source diff.** (qjsArrayMethodFastCall alone was perf-neutral but was reverted with it.)
> - NOT deletable (survey over-flagged; they are FAITHFUL): property ICs (qjsGetFieldFast,
>   fastDenseArrayElementValue — qjs has get_ic/put_ic + fast_array), threaded dispatch arms
>   (push_const etc. — qjs computed-goto), int32/float64 arith fast paths (qjs has identical inline
>   paths), plain_undefined_this (deleting it makes eager-this MORE expensive — the real fix is lazy
>   this, not deletion).

> **2026-06-25 round-5 addendum (frame monolithic rewrite — keystone landed).** The documented
> multi-week frame rewrite was started. Profiling (post round-4, fib 3.46×) confirmed the targets:
> **pushFrame 28% (frame setup), dispatchLoop 51% (opcode + per-call re-entry + broad codegen),
> execCall 11% (call resolution).** Three gated commits this round (each test262 0/49775 + 1223 +
> force-GC):
> - **`9dfb819` Frame slim keystone (the documented A+B).** The 27-field Frame was value-initialized
>   per call. Split the 13 cold fields a plain inline call never touches (eval_* 5, global_lexical_sync_*
>   4, constructor_this_value(_owned) 2, arguments_object, original_args) into a lazily-allocated
>   `Frame.FrameCold` reached via `frame.cold: ?*FrameCold`. Hot Frame keeps the per-call fields; init
>   writes one null pointer, the hot Frame is ~190B narrower. Reads go through defaulting accessors;
>   writes ensureCold(). `freeCold` (full teardown) vs `releaseColdStorage` (storage release / generator
>   resume — keeps eval/ctor/arguments + box). External readers migrated via a 10-agent by-file workflow,
>   all write sites reviewed. **fib 24.88B→24.63B (3.46×→3.43×); pushFrame 28%→24%.**
> - **`b42bc70` zero-size OpcodeProfileScope when profiling compiled out — the round's standout.** The
>   dispatch prologue constructed a 5-field inactive scope per cold re-entry (= per call/return) that the
>   optimizer did NOT elide. Made it a zero-size struct (no-op deinit) when `zjs_enable_opcode_profile`
>   is comptime-false (default). **fib 24.63B→23.95B (3.43×→3.33×)** — bigger than the keystone, and the
>   biggest single fib win of the whole campaign. (Found via a background-build measurement; a concurrent
>   synchronous build had reported a false 0M — the stale-binary hazard struck a THIRD time.)
> - **`04f84d1` hoist function/generator payload in functionRealmGlobalPtr chain.** Correctness-neutral
>   reorder (one payload per object); resolveInlineTarget reads it per call on a bytecode function.
>   fib −36M (3.33×→3.328×).
> - **`b822492` hoist inline-invariant per-level locals out of the frame switch (bounded E).** The
>   prologue's depth>0 branch re-set all 17 per-level locals per switch; 10 are identical constants for
>   every inline frame (no eval/generator/eval-code) and only change at the L0↔inline boundary. Gate them
>   behind an `inline_invariants_set` flag — set once on entering the inline regime, skip on every
>   inline→inline switch (fib's ~18.45M switches are almost all inline→inline). Verified the 10 are
>   written ONLY in the prologue (correctness-neutral). **fib 23.91B→23.55B (3.328×→3.277×).**
> - **`e23d30c` inline the hot return-path passthrough.** `returnTop`/`finishFunctionReturn` were
>   separate non-inlined calls per return; marked inline. **fib 23.55B→23.41B (3.277×→3.257×).**
>
> **Frame-rewrite status & remaining (honest).** Round-5 fib end-state **3.257× qjs (23.41B)**, down
> from 3.46× (turn start) — five gated commits, ~1.48B insn off fib. The **keystone (A+B) is done** and
> the **bounded (E) slices are extracted** (profile-scope, invariant-hoist, return-inline = the
> per-cold-re-entry overhead that did NOT need the recursion rewrite). The remaining documented facets
> have **no cheap win** and are genuinely multi-session:
> - **(E) threaded resume / recursion model** — the real *structural* lever (caller registers survive the
>   call) needs C-recursion as the default + the frame-setup collapse; re-plumbs exception unwinding +
>   generator/async suspend. The bounded prologue slices above are extracted; the rest is the deep rewrite.
> - **(C) raw-sp operand stack** — Stack.deinit ~2% + part of pushFrame; ~165 cold handlers take `*Stack`.
> - **(F) backtrace from the Entry chain** — needs the Machine reachable from the throw site; ~0.25%, low ROI.
> The residual **3.26×** is dominated by (a) **pushFrame ~22%** = the arena-carve alloca-substitute
> (structurally permanent — Zig has no variadic alloca) and (b) **dispatchLoop ~56%** = LLVM-vs-gcc
> per-opcode codegen (NOT a faithful divergence). Neither is a clean faithful target; bounded wins have
> diminishing returns (683M→368M→139M). The doc-estimated ~1.3–1.5× ceiling requires the full (C)+(E)
> deep recursion/raw-sp rewrite — a dedicated multi-session project (write the suspend-crossing-aware
> step-by-step gated plan first, per §0).

> **2026-06-25 round-4 addendum (frame-incremental + dense-array builds).** On top of round-3,
> **4 more faithful slices**, each gated test262 0/49775 + 1223 + force-GC:
> - **`5545cef` Slice A — frame teardown gate** (DIVERGENCE-CATALOG #4 / HANDOVER-frame-incremental).
>   `teardownInlineEntry` ran `eval_snapshot.deinit` + `freeEvalResources` (both non-inlined) every
>   call; for a no-eval frame both are provable no-ops. A `simple_frame` flag (= `!need_eval_var_refs`)
>   gates them. **fib 26.16B→25.35B (3.64×→3.53×)**; broad (every plain call).
> - **`698824e` Slice C — var_refs borrow.** `initFrameVarRefs` carved+`.dup()`'d every closure
>   capture per call, freed each at teardown; qjs borrows `var_refs = p->u.func.var_refs`
>   (quickjs.c:17844). zjs now aliases the captures array when EVERY mutation is provably cell-routed
>   and the array is never realloced — gated on `simple_frame && !has_eval_call && global_vars.len==0
>   && all-captures-are-cells`; a `var_refs_borrowed` flag skips the teardown free. **A 5-agent
>   adversarial workflow proved the naive borrow UNSAFE on 4 paths** (non-cell captures, eval
>   `replaceFrameVarRefBinding`, global_decl rebind, teardown double-free under recursion) — the four
>   conjuncts eliminate all four. **fib 25.35B→24.88B (3.53×→3.46×)**; scales with capture count.
>   force-GC is the load-bearing gate.
> - **`a5e6218` Map/Set entries dense pair + `9252d94` Object.entries dense pair.** Both built the
>   `[k,v]` pair with two per-element `defineOwnProperty(atomFromUInt32)`; qjs's `js_create_array`
>   (quickjs.c:9601) pre-sizes a dense fast array + direct slot writes. zjs now allocs a 2-slot slice,
>   dups after the alloc (no GC between dup and adopt; components stay rooted/collection-alive), and
>   `adoptDenseArrayElementsAssumingEmpty` + sets `may_have_indexed_properties`. **Map.entries
>   4.41×→1.87×, Object.entries 1.61×→1.44×.** The dense-build primitive is reusable for ANY
>   small known-length array currently built per-element (Array.from/map/filter dense output — but
>   those couple to the count/length split and the per-callback frame tax).
>
> **Corrections to the round-3 catalog:** (1) **closure length/name is NOT a faithful lazy target.**
> qjs `js_closure`→`js_function_set_properties` (quickjs.c:5853) EAGERLY defines both via
> `JS_DefinePropertyValue`; only `prototype` is autoinit (`JS_AUTOINIT_ID_PROTOTYPE`, the only
> autoinit id). The catalog's "qjs makes those lazy autoinit too" was wrong — making them lazy would
> DIVERGE. closure-per-iter 3.73× is broad tax (zjs already matches qjs's eager length/name+lazy
> prototype). (2) Slice D (lazy-`this`/non-owning cur_func) deferred: cur_func is already a MOVE not a
> dup (no refcount win), and the plain-undefined-`this` fast path already avoids `coerceCallThis` for
> fib, so D's fib payoff is marginal + carries this-coercion-semantics risk. Slice B (backtrace pop
> gate) stays low-priority. **Session end-state (clean binary):** fib 3.46×, method 3.15×,
> proto_method 3.49×, mapget 2.78×, mapentries 1.86×, closure 3.73×, foreach 4.00×. Branch
> `qjs-faithful-perf-round2`, not merged/pushed. **The stale-binary hazard bit again** — measured
> Object benchmarks at 150–166× off a leftover force-GC binary before catching it; ALWAYS
> `zig build zjs` before `perf`.

> **2026-06-25 round-3 addendum.** On top of the round-2 commits below, a measurement-driven
> sweep (`docs/qjs-align/DIVERGENCE-CATALOG.md`, 28 faithful divergences found) shipped **9 more
> faithful slices**, each gated test262 0/49775 + 1223 + force-GC:
> `b20d5b4` method-dispatch cascade hoist (`o.m()` 4.43×→2.30×) · `18a2610` lazy
> function.prototype (closure 5.68×→3.90×) · `40b928f` typeof interned atom (3.45×→2.27×) ·
> `a7b7256` inline float64 arith fast path (3.4–5.1×→2.3–2.5×) · `69e2183` Array
> indexOf/includes/lastIndexOf dense scan (indexOf 13.56×→1.35×) · `9e4029e` iterator-result
> predefined atoms · `d3edbc6` ordinaryHasInstance leaner · `e30ecef` string-method atom
> bitset · **`be06930` Map/Set for-of result-object-free (21.22×→1.78×)**. One attempt
> (cloneShape verbatim copy) was implemented, verified, then reverted — correct but zero
> measurable benefit. Remaining frontiers + corrected tractability estimates are in the
> CATALOG. **Benchmarking hazard (below) bit hard — always `zig build zjs` before `perf`.**

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
| method `o.m(s)` (simple) | 43.6B | **22.7B** | 9.8B | 4.43× → **2.30×** |
| method `p.step(s)` (proto) | 48.1B | **27.2B** | 9.9B | 4.85× → **2.74×** |
| closure-per-iter (`var c=function(){...}`) | — | **94.7B** | 24.3B | 5.68× → **3.90×** |
| fib(34) | 26.2B | 26.1B | 7.2B | 3.64× → **3.64× (unchanged — frame-model-gated)** |

Global access now equals **local** access (both ~2.35× qjs): the global-specific divergence is
gone; the residual 2.35× is the shared broad dispatch tax (see below).

**Method calls were the largest under-measured gap** (4.4–4.85×, *worse* than fib, and method
calls are ubiquitous): a per-call ~20-member array-method cascade ran on every callee that lacked a
native builtin id — i.e. every user *bytecode* method (`obj.m()`). Eliminated (`b20d5b4`, below).
After the fix the residual method gap is the proto get_field IC tax + the call-machinery (frame)
tax, both shared broad frontiers — no method-specific divergence remains.

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
4. **Method-dispatch cascade hoist** (`b20d5b4`). `qjsArrayMethodFastCall` (array_ops.zig:193) ran a
   linear ~20-member `qjsArray*Call` cascade on *every* method call reached after `fastNativeMethodCall`
   missed (any callee with no native builtin id — i.e. all user bytecode methods). Every member opens
   with the same `callableObjectFromValue(func) orelse return null` (c_function/c_closure/bound_function
   only), so for a bytecode callee the whole cascade was ~20 sequential no-ops (~30% of a simple
   method-call loop). Hoisted that universal precondition to a single early-out — provably
   behaviour-preserving (returns null exactly when every member already would, so generic
   `Array.prototype.X.call(arrayLike)` and builtin-name-shadowing user methods are byte-identical).
   Faithful to qjs: OP_call_method (quickjs.c:18220) resolves the callee once and dispatches by magic in
   `js_call_c_function` (quickjs.c:17562) — never a per-call method scan. `o.m(s)` 4.43×→2.30×,
   `p.step(s)` 4.85×→2.74×; real array methods / plain calls / non-simple methods unchanged. Investigation:
   `array-cascade-faithful-gate` workflow (5 agents) verified the receiver-gate was UNSAFE (members
   implement generic array-like semantics, need only `receiver.isObject()`) and the func-precondition
   was the safe hoist.
5. **Lazy `function.prototype`** (`18a2610`). `createBytecodeFunctionObject` eagerly allocated a prototype
   object + `constructor` back-ref for every normal function with `has_prototype`. Two divergences in one:
   a wasted allocation for any function whose `.prototype` is never observed, AND the
   `func ↔ prototype.constructor` cycle — which means refcount can NEVER free such a function; only the
   cycle collector can. A closure-per-iteration loop thus paid the full mark/sweep collector
   (`destroyRuntimeCyclesWithValueRoots` ~10%). qjs makes `.prototype` a lazy autoinit property
   (`JS_AUTOINIT_ID_PROTOTYPE` / `js_instantiate_prototype`, quickjs.c:17341). zjs already had the autoinit
   infra (`Slot.auto_init`, used for ~700 lazy builtins); added a `function_prototype` AutoInitKind whose
   materializer derives realm/constructor from the owner function object (one shared interned descriptor —
   no per-function table growth). Installed for normal non-class functions; generators/async-gen/class
   ctors keep the eager path. A never-constructed closure now has no prototype + no cycle → reclaimed by
   refcount, not the collector. Closure-per-iter 5.68×→3.90×, cycle collector gone from the profile;
   constructors materialize on `new` exactly as before. Remaining closure cost is function-object creation
   (`createBytecodeFunctionObject` + `defineOwnProperty` for length/name) — qjs makes those lazy autoinit
   too (next slice candidate).

## ⚠️ Benchmarking hazard — gate builds overwrite `zig-out/bin/zjs`

`zig build test` / `zig build test262-gate` / **especially `zig build test -Dzjs_force_gc=true`** rebuild
and install the `zjs` artifact with **different build options**. The force-GC binary runs a full GC before
*every* allocation, so allocation-heavy benchmarks read **100–260× qjs** on it — a pure artifact, not a real
regression (a clean `zig build zjs` restores normal ~2–2.5×). This burned a long investigation: an apparent
"GC pathology" (objlit 165×, arraylit 259×, new 120×) was entirely the force-GC binary left in
`zig-out/bin/zjs` by a prior gate run. **ALWAYS run `zig build zjs` immediately before any `perf stat`
benchmark, never benchmark after a gate without rebuilding.** A stale binary can also show an *older*
mtime after `zig build zjs` (build-cache hit), so check behaviour, not timestamp.

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
