# CALL-MACHINERY-QJS — 实锤 reference (QuickJS-ng 2026-06-04 vs zjs)

Source of truth: `/home/aneryu/quickjs/quickjs.c`. Every C excerpt below is copied verbatim with its real line numbers. zjs citations are `file:line`. This document is the keystone reference for aligning zjs's call path to QuickJS.

---

## 0. The one-paragraph answer: how does qjs do a call?

qjs makes a **plain C recursion**. `JS_CallInternal` builds a **~72-byte pointer-only `JSStackFrame` as a C local** (`JSStackFrame sf_s, *sf = &sf_s;`, line 17754) and carves **the entire frame's value storage in ONE C-stack `alloca`** (`local_buf = alloca(alloca_size)`, line 17846). Binding is ~6 stores: args are **borrowed in place** (`arg_buf = argv`, 17841), `cur_func` is a **non-owning cast-store** (17843), closure captures are a **single O(1) pointer borrow** (`var_refs = p->u.func.var_refs`, 17844), locals are undefined-filled (17860), and `this`/`new_target` are **not stored in the frame at all** — `this` is coerced **lazily** at `OP_push_this` (17933). Every bytecode-to-bytecode call **recurses** (`ret_val = JS_CallInternal(...)`, 18191): one C frame per JS frame. Mid-call GC keeps frame values alive by **refcount only** — the cycle collector never walks the frame chain. The backtrace **reuses** the same `rt->current_stack_frame -> prev_frame` chain (built only on throw). Teardown is **one store** + free C-stack unwind (20709-20710).

**Recurse vs loop verdict:** qjs RECURSES. zjs's `inline_calls.Machine` LOOPS in place for the hot shape — a **deliberate structural DEVIATION**, faithful in operand-stack layout and result semantics but not in control flow. The `inline_calls.zig` doc-comment claim of "mirroring qjs OP_call" overstates fidelity.

---

## 1. Frame memory layout — the single alloca

### 1.1 `JSStackFrame` struct (quickjs.c:407-420) — pointer-only, ~72B

```c
typedef struct JSStackFrame {
    struct JSStackFrame *prev_frame; /* NULL if first stack frame */
    JSValue cur_func; /* current function, JS_UNDEFINED if the frame is detached */
    JSValue *arg_buf; /* arguments */
    JSValue *var_buf; /* variables */
    struct JSVarRef **var_refs; /* references to arguments or local variables */ 
    const uint8_t *cur_pc; /* only used in bytecode functions : PC of the
                        instruction after the call */
    int arg_count;
    int js_mode; /* not supported for C functions */
    /* only used in generators. Current stack pointer value. NULL if
       the function is running. */
    JSValue *cur_sp;
} JSStackFrame;
```

Field sizes (default 64-bit, **non-NaN-boxed** `JS_PTR64` build — `JSValue` = `JSValueUnion u` (8B) + `int64_t tag` (8B) = 16B, per quickjs.h:229-232): prev_frame 8 + cur_func 16 + arg_buf 8 + var_buf 8 + var_refs 8 + cur_pc 8 + arg_count 4 + js_mode 4 + cur_sp 8 = **72B**. The struct holds **only pointers + one embedded value + scalars** — NO inline value array. (On a NaN-boxing build `JSValue` is 8B and the header shrinks to 64B; the default build is assumed throughout.)

### 1.2 The single alloca + pointer-arithmetic partition (quickjs.c:17828-17871)

```c
    if (unlikely(argc < b->arg_count || (flags & JS_CALL_FLAG_COPY_ARGV))) {
        arg_allocated_size = b->arg_count;
    } else {
        arg_allocated_size = 0;
    }

    alloca_size = sizeof(JSValue) * (arg_allocated_size + b->var_count +
                                     b->stack_size) +
        sizeof(JSVarRef *) * b->var_ref_count;
    if (js_check_stack_overflow(rt, alloca_size))
        return JS_ThrowStackOverflow(caller_ctx);

    sf->js_mode = b->js_mode;
    arg_buf = argv;
    sf->arg_count = argc;
    sf->cur_func = (JSValue)func_obj;
    var_refs = p->u.func.var_refs;

    local_buf = alloca(alloca_size);
    if (unlikely(arg_allocated_size)) {
        int n = min_int(argc, b->arg_count);
        arg_buf = local_buf;
        for(i = 0; i < n; i++)
            arg_buf[i] = JS_DupValue(caller_ctx, argv[i]);
        for(; i < b->arg_count; i++)
            arg_buf[i] = JS_UNDEFINED;
        sf->arg_count = b->arg_count;
    }
    var_buf = local_buf + arg_allocated_size;
    sf->var_buf = var_buf;
    sf->arg_buf = arg_buf;

    for(i = 0; i < b->var_count; i++)
        var_buf[i] = JS_UNDEFINED;

    stack_buf = var_buf + b->var_count;
    sf->var_refs = (JSVarRef **)(stack_buf + b->stack_size);
    for(i = 0; i < b->var_ref_count; i++)
        sf->var_refs[i] = NULL;
    sp = stack_buf;
    pc = b->byte_code_buf;
    sf->prev_frame = rt->current_stack_frame;
    rt->current_stack_frame = sf;
    ctx = b->realm; /* set the current realm */
```

ONE `alloca(alloca_size)` (17846) carves the entire frame off the C stack, partitioned by pure pointer arithmetic into `arg_buf` (= `argv` borrow on the fast path / `local_buf` on the arity-pad slow path) / `var_buf` / `stack_buf` (= operand stack base; `sp = stack_buf`) / `sf->var_refs` (the frame's OWN open refs, tail slice). The operand stack is just the `[stack_buf, stack_buf+stack_size)` sub-slice with `sp` as a raw register. Frame linkage is a 2-store intrusive-list push (17869-17870). Zero allocator/arena/heap traffic.

### zjs delta — frame allocation
- qjs: 72B C-local header + ONE stack-pointer decrement + free unwind teardown.
- zjs: a 27-field `Frame` (`frame.zig:225-251`, 4 embedded 16B JSValues + 6 owned `[]JSValue` slices + 3 sync slices + bool flags) embedded in a **heap-resident chunked `Entry`** (`inline_calls.zig:111-133`; 16-Entry chunks created via `rt.memory.create` at `:201`), carved off a `VmStackArena` needing an explicit `Mark`/restore watermark, with a **separate `Stack` object** (`Stack.initArenaWindow`, `:384`) and a **7-resource per-pop `teardownInlineEntry`** (`:656-665`).
- The contiguous slab carve and the borrow-args fast path ARE faithful; the residual tax is the wide heap Entry + standalone Stack + arena watermark + explicit teardown.

---

## 2. Dispatch — recurse (qjs) vs loop-in-place (zjs)

### 2.1 `CASE(OP_call)` recurses (quickjs.c:18182-18202)

```c
        CASE(OP_call):
        CASE(OP_tail_call):
            {
                call_argc = get_u16(pc);
                pc += 2;
                goto has_call_argc;
            has_call_argc:
                call_argv = sp - call_argc;
                sf->cur_pc = pc;
                ret_val = JS_CallInternal(ctx, call_argv[-1], JS_UNDEFINED,
                                          JS_UNDEFINED, call_argc, call_argv, 0);
                if (unlikely(JS_IsException(ret_val)))
                    goto exception;
                if (opcode == OP_tail_call)
                    goto done;
                for(i = -1; i < call_argc; i++)
                    JS_FreeValue(ctx, call_argv[i]);
                sp -= call_argc + 1;
                *sp++ = ret_val;
            }
            BREAK;
```

The load-bearing line is **18191**: `ret_val = JS_CallInternal(...)` — a nested C call back into `JS_CallInternal`. Args are passed **in place** (`call_argv = sp - call_argc`, 18189); resume PC saved (`sf->cur_pc = pc`, 18190); result pushed back (`sp -= call_argc + 1; *sp++ = ret_val;`, 18199-18200). The `for(;;)` at 17874 belongs to ONE frame. There is **no loop-continue** at the call site.

### 2.2 `CASE(OP_call_method)` — identical recursion, passes receiver as `this` (quickjs.c:18220-18238)

```c
        CASE(OP_call_method):
        CASE(OP_tail_call_method):
            {
                call_argc = get_u16(pc);
                pc += 2;
                call_argv = sp - call_argc;
                sf->cur_pc = pc;
                ret_val = JS_CallInternal(ctx, call_argv[-1], call_argv[-2],
                                          JS_UNDEFINED, call_argc, call_argv, 0);
                if (unlikely(JS_IsException(ret_val)))
                    goto exception;
                if (opcode == OP_tail_call_method)
                    goto done;
                for(i = -2; i < call_argc; i++)
                    JS_FreeValue(ctx, call_argv[i]);
                sp -= call_argc + 2;
                *sp++ = ret_val;
            }
            BREAK;
```

Stack region is `[receiver=call_argv[-2], func=call_argv[-1], args...]`; receiver is the explicit `this` C argument. (`OP_call_constructor` at 18203-18218 recurses the same way via `JS_CallConstructorInternal` at 18209.)

### zjs delta — dispatch
zjs splits this into two paths (`zjs_vm.zig:1723-1737`):

```zig
.inline_call => |request| {
    machine.pushCall(global, stack, request.target, request.region_base, request.argc, request.layout) catch |err| { ... };
    continue;
},
```

The common plain-bytecode shape LOOPS in place (`pushCall` + `continue`, no Zig recursion); non-inline callees (C fn, class ctor, cross-realm, fusion bodies, async/generator) recurse via `runWithArgsState` re-entry — the true qjs analogue. **VERDICT: structural DEVIATION.** The `inline_calls.zig:1-14` doc-comment ("Mirrors QuickJS JS_CallInternal's OP_call handling ... instead of recursing") is false as a control-flow fidelity claim — qjs provably recurses at 18191. Operand-stack layout `[callable,args]` / `[receiver,callable,args]` (`RegionLayout`) and result-push ARE faithful; only recurse-vs-loop diverges.

---

## 3. Prologue binding — args, this, current_function

- **args borrowed in place** on the common path: `arg_buf = argv` (17841) when `argc >= b->arg_count` and `!COPY_ARGV`; the arity-pad slow path dups into the alloca + undefined-pads (17847-17854).
- **cur_func is a non-owning cast-store**: `sf->cur_func = (JSValue)func_obj;` (17843) — no refcount; the caller owns the ref for the call's duration.
- **`this` / `new_target` are NOT in the frame** (struct 407-420 has no fields). `this` is coerced **lazily** at `OP_push_this` (quickjs.c:17933-17945) with sloppy coercion (undefined/null -> global_obj, primitive -> `JS_ToObject`), only when the body reads it.

### zjs delta — binding
- Borrow predicate is **narrower**: `canBorrowSourceArgs` (`inline_calls.zig:487-495`) also requires `argc!=0`, no padding, AND `source==.stack_region` (`.moved` never borrows) — else a `memcpy`+`memset` move (`frame.zig:347-368`).
- `current_function` is **OWNED** via `takeSourceSlot` (`inline_calls.zig:333`; transfers ref, nulls slot, freed at deinit) — qjs borrows.
- `this` is **materialized eagerly** every call via `coerceCallThis` (`call_runtime.zig:295-310`, identical sloppy logic) + a plain-undefined fast path + method `take_receiver_as_this` — qjs defers to OP_push_this.

---

## 4. var_refs / closure captures — borrow (qjs) vs per-call copy+retain (zjs)

### 4.1 qjs: single O(1) pointer borrow (quickjs.c:17758, 17844)

```c
    JSVarRef **var_refs;
...
    var_refs = p->u.func.var_refs;
```

One load + one store, no loop/malloc/refcount regardless of capture count. The `alloca_size` (17834-17836) reserves room only for the frame's OWN open refs (`b->var_ref_count`), **never** a copy of the captures. Opcode deref through the borrowed array (quickjs.c:18627-18646):

```c
        CASE(OP_get_var_ref):
            {
                int idx;
                JSValue val;
                idx = get_u16(pc);
                pc += 2;
                val = *var_refs[idx]->pvalue;
                sp[0] = JS_DupValue(ctx, val);
                sp++;
            }
            BREAK;
        CASE(OP_put_var_ref):
            {
                int idx;
                idx = get_u16(pc);
                pc += 2;
                set_value(ctx, var_refs[idx]->pvalue, sp[-1]);
                sp--;
            }
            BREAK;
```

The `done:` teardown (quickjs.c:20698-20710, below) frees only `local_buf..sp` plus `close_var_refs` for the frame's OWN open refs (def 17533) — the borrowed `p->u.func.var_refs` is **never** freed or decremented.

### 4.2 zjs: per-call copy + per-element retain (vm_call.zig:171)

```zig
        for (var_refs, 0..) |value, idx| owned_refs[idx] = value.dup();
        frame.var_refs = owned_refs;
```

`initFrameVarRefs` (`vm_call.zig:152`) carves a fresh per-frame window and `.dup()`s every capture (a `gc.retain` each) on entry; `Frame.deinit`/`releaseOwnedStorage` (`frame.zig:511/544`) `.free()`s every element on exit. The opcode deref `frame.var_refs[idx]` (`zjs_vm.zig:1024-1062`) is byte-for-byte identical to qjs — the cost is entirely in **how the array was populated**, not how it is indexed.

### zjs delta — var_refs
- qjs = 1 pointer borrow (O(1), 0 refcount ops, 0 teardown).
- zjs = carve N-slot window + N `gc.retain` on entry + N `.free` on exit = **O(captures) per-call refcount traffic** + a window write.
- `mergeEvalBindings` (`inline_calls.zig:538`) extra alloc is real but COLD (gated `eval_names.len>0 and eval_refs.len>0` at `:276`; not taken on the common no-eval call).
- **Faithful fix:** alias `frame.var_refs` directly to the closure captures slice (borrow, no per-element dup) and have teardown skip releasing it.

---

## 5. GC during the call — 零 GC 簿记 (and why this gap is DROPPED)

The frame (sf_s C local + alloca) lives on the C stack; the only global link is `rt->current_stack_frame = sf` (17870) — a backtrace pointer, NOT a GC root. Liveness is **refcount only**. The cycle collector iterates ONLY `rt->gc_obj_list` / `tmp_obj_list` (quickjs.c:6697-6754, `JS_RunGCInternal` 6815-6833) and **never walks the JSStackFrame chain or the C stack**. The smoking gun — `mark_children`'s async-function case explicitly skips a running frame (quickjs.c:6639-6661):

```c
                if (sf->cur_sp) {
                    /* if the function is running, cur_sp is not known so we
                       cannot mark the stack. Marking the variables is not needed
                       because a running function cannot be part of a removable
                       cycle */
                    for(sp = sf->arg_buf; sp < sf->cur_sp; sp++)
                        JS_MarkValue(rt, *sp, mark_func);
                }
```

**zjs ALREADY MATCHES on this facet.** `FrameRootScope`/`active_value_roots` were removed from the frame path in S5/e8c852b; `FrameSlab` populates slots by `.dup()` (refcount, no rooting) with refcount teardown; the dispatch loop and `frame.zig` carry NO `active_value_roots` (grep finds zero `FrameRootScope` in `src/`). The remaining `active_value_roots` sites are C-host-builtin helpers, the analog of qjs C builtins. **CAVEAT (architectural, not per-call):** zjs's collector is mark/sweep with an explicit root set (`MajorPhase.mark_roots`; `traceRoots`/`traceValueRootFrames`, `runtime.zig:1166/1198`) vs qjs's refcount + trial-deletion — but `traceRoots` deliberately does NOT trace the bytecode frame chain, so bytecode frame values rely on refcount exactly as qjs. **This presumed gap is DROPPED.** The presumed "shadow-root for GC" gap is likewise not real.

---

## 6. Return + backtrace

### 6.1 OP_return + epilogue (quickjs.c:18266-18271, 20698-20710)

```c
        CASE(OP_return):
            ret_val = *--sp;
            goto done;
        CASE(OP_return_undef):
            ret_val = JS_UNDEFINED;
            goto done;
```

```c
    } else {
    done:
        if (unlikely(b->var_ref_count != 0)) {
            /* variable references reference the stack: must close them */
            close_var_refs(rt, b, sf);
        }
        /* free the local variables and stack */
        for(pval = local_buf; pval < sp; pval++) {
            JS_FreeValue(ctx, *pval);
        }
    }
    rt->current_stack_frame = sf->prev_frame;
    return ret_val;
```

OP_return latches the value and jumps; the epilogue's entire runtime-visible teardown is **ONE store** `rt->current_stack_frame = sf->prev_frame;` (20709). The C return frees sf + alloca for free.

### 6.2 build_backtrace reuses the same chain (quickjs.c:7571-7595)

```c
    for(sf = ctx->rt->current_stack_frame; sf != NULL; sf = sf->prev_frame) {
        if (sf->js_mode & JS_MODE_BACKTRACE_BARRIER)
            break;
        ...
        func_name_str = get_prop_string(ctx, sf->cur_func, JS_ATOM_name);
        ...
        if (js_class_has_bytecode(p->class_id)) {
            ...
            if (b->has_debug) {
                line_num1 = find_line_num(ctx, b,
                                          sf->cur_pc - b->byte_code_buf - 1, &col_num1);
```

There is NO dedicated backtrace structure — it walks the same `rt->current_stack_frame -> prev_frame` list the interpreter already maintains, and is called ONLY on throw (20668, 7655, etc.). The no-throw hot path pays zero backtrace bookkeeping.

### zjs delta — backtrace
zjs threads a SEPARATE `ActiveBacktraceFrame{previous,data,resolver}` chain through `ctx.current_backtrace_frame` (`context.zig:40-44/:428`), pushed at `inline_calls.zig:290` and popped at `:663` on **every** call — ~4 pointer-list stores/call (`context.zig:797-806`) that qjs spends zero on. It IS GC-orthogonal (only walked on throw in `snapshotBacktraceFrames`), matching qjs's lazy semantics; only the constant per-call push/pop tax is the delta. **Faithful fix:** derive backtraces from the existing inline `Entry` stack instead of a second linked list.

---

## 7. Comparison table

| Mechanism | qjs | zjs | Gap |
|---|---|---|---|
| Frame alloc | 72B pointer-only C-local `sf_s` (17754) + ONE C-stack `alloca` (17846); free unwind | 27-field Frame in heap-resident chunked Entry (frame.zig:225 / inline_calls.zig:111); arena Mark + separate Stack + 7-resource teardown (:656) | Heap Entry + Stack obj + arena watermark + explicit teardown vs free alloca+recursion — **#1** |
| Dispatch | RECURSE: `JS_CallInternal(...)` per call (18191) | LOOP: pushCall + continue (zjs_vm.zig:1729) for hot shape; recurse on slow path | Structural deviation (doc-comment overstates fidelity); faithful in layout, not control flow |
| this/arg binding | args borrowed `arg_buf=argv` (17841); cur_func non-owning cast (17843); this lazy at OP_push_this (17933) | narrower borrow (inline_calls.zig:487); current_function OWNED (takeSourceSlot :333); this eager (coerceCallThis) | owned-vs-borrowed func + eager-vs-lazy this — **#3** |
| var_refs | O(1) borrow `var_refs = p->u.func.var_refs` (17844); never freed | per-call window + N `value.dup()` (vm_call.zig:171) + N free on exit (frame.zig:511/544) | O(captures) retain/release tax vs O(1) borrow — **#2** |
| GC rooting | ZERO roots; refcount-only; collector never walks frame chain (6697/6639-6661) | MATCHES: FrameSlab .dup() refcount, no FrameRootScope (removed S5); frame chain not traced (runtime.zig:1198) | **NO GAP — DROPPED** |
| Backtrace | reuses prev_frame chain (7571); built only on throw; 1 epilogue store (20709) | separate ActiveBacktraceFrame chain (context.zig:40-44) pushed/popped every call (inline_calls.zig:290/:663) | ~4 extra pointer stores/call — **#4** |

---

## 8. Ranked gaps (likely contribution to the fib 6-7x)

1. **Frame allocation** — heap Entry + separate Stack + arena Mark/restore + 7-resource teardown vs qjs's single C-stack alloca + free C-recursion teardown. Largest structural source: fib makes a JS->JS call per node, so frame setup/teardown IS the per-node cost.
2. **var_refs per-call copy+retain** — O(N) `value.dup()` on entry / free on exit vs qjs's O(1) `var_refs = p->u.func.var_refs`. Hot for fib because the recursive self-reference is itself a capture.
3. **this/current_function** — eager `coerceCallThis` every call + OWNED `current_function` (takeSourceSlot refcount round-trip) vs lazy OP_push_this + non-owning borrowed cur_func.
4. **Backtrace shadow chain** — ~4 pointer stores/call for a parallel list qjs reuses for free. Constant, smaller, but real.

**DROPPED (already matched):** per-call GC rooting of frame values, and the "shadow-root for GC" concern — zjs's `FrameSlab` + `.dup()` refcount discipline already matches qjs's zero-per-call-rooting after S5/e8c852b; the bytecode frame chain is not GC-traced on either side.

---

## 9. Faithful target structure for zjs's call path

To match qjs's `JS_CallInternal`, zjs's hot bytecode-to-bytecode call should converge to:

1. **Collapse the frame to a thin C-stack-equivalent header + ONE contiguous slab.** Keep the `FrameSlab` contiguous carve (already faithful) but shrink the per-call object toward a pointer-only header: avoid the wide 27-field heap `Entry` for the common shape, avoid a standalone `Stack` object (let the operand stack be the slab sub-slice with a raw `sp`), and avoid the arena `Mark`/restore + multi-resource teardown where a watermark-only reclaim suffices. Target: per-call cost ≈ one slab cursor bump + tiny init loops, teardown ≈ slab restore.
2. **Borrow closure captures, do not copy.** Make `frame.var_refs` ALIAS `function_object.functionCapturesSlot().*` directly (the slice zjs already reads at `inline_calls.zig:275`) and have teardown skip releasing it — matching `var_refs = p->u.func.var_refs` (17844). This removes the O(captures) per-call retain/release entirely. Keep the eval-merge path cold/gated as today.
3. **Defer `this` and borrow `current_function`.** Stop materializing `this` eagerly on calls whose body never reads it (move coercion to the OP_push_this analog), and make `current_function` a non-owning borrow for the call's duration (drop the `takeSourceSlot` ownership transfer + deinit free) — matching `sf->cur_func = (JSValue)func_obj` (17843).
4. **Single backtrace source.** Derive backtraces from the existing inline `Entry` stack (walk it like qjs walks `prev_frame`) and delete the parallel `ActiveBacktraceFrame` push/pop on the hot path.
5. **Keep loop-in-place, but stop calling it a mirror.** The in-place Machine is a legitimate optimization (no C-stack growth, no full prologue re-entry per hot call); it is NOT a structural mirror of qjs's recursion. Update the doc-comment to say so. The slow recursive path (`runWithArgsState`) remains the faithful structural analogue for non-inline callees.

Net: items (1)-(4) close the four per-call taxes; item (5) is a fidelity-of-claim correction. The GC-rooting facet needs no change — zjs already matches qjs there.