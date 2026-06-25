# Handover — qjs-faithful global var_ref lowering (2026-06-24)

Branch `qjs-faithful-global-varref`. The single biggest remaining perf lever from the previous
handover (`HANDOVER-call-dispatch-align.md`, "lever ②"): global variable access was ~7× qjs.
This round lands the var_ref-cell lowering and fixes all 33 scope-correctness regressions it
introduced, gated `test262 0/49775` + `zig build test` 1223 + force-GC 1223.

## Result (targeted benchmarks, `taskset -c 19 perf stat -e instructions`, vs `/home/aneryu/quickjs/qjs`)

| bench | real baseline (no var_ref) | shipped | qjs | ratio |
|---|---|---|---|---|
| global-read (`s=s+g+h`) | 76.6B | **31.3B** | 10.8B | 7.08× → **2.45×** over baseline / 2.90× qjs |
| global-write (`g=g+1`) | 69.4B | **23.3B** | 10.4B | 6.70× → **2.98×** over baseline / 2.24× qjs |
| fib(34) | 26.23B | 26.29B | 7.18B | **neutral** (no regression) |

`/tmp/gread.js`, `/tmp/gwrite.js`, `/tmp/fib.js`. The win comes from OP_get_var/OP_put_var
dereferencing the global property's var_ref cell directly (register-resident) instead of a
full scope-chain + global-object lookup.

## Architecture (the var_ref-cell model — qjs `js_closure_define_global_var` / OP_get_var)

The OP_get_var/OP_put_var operand `idx` is already a closure-var index (`vm_property.globalVarAtom`).
Top-level `var`/function global declarations now create a `JS_PROP_VARREF` cell on the global
object (`call_runtime.defineGlobalDeclVarCell` → `ensureGlobalObjectVarRefCell`); `.global`
closure vars alias that cell (`vm_call.initialClosureVarRef`, `object_ops.createGlobalClosureVarRef`);
the getVar/putVar fast lanes (`vm_property_globals.zig` + threaded twins in `zjs_vm.zig`) deref
`cell.pvalue.*` when no dynamic overlay AND the cell is authoritative. `object.zig`
defineProperty/setProperty/mergeDescriptor write through a var_ref slot's cell. Host/undeclared
globals (Date, …) keep ordinary data props → the fast lane's authoritative check fails → slow path.

## The 4 scope-correctness fixes (each its own qjs anchor; each gated 0/49775)

1. **`directEvalGlobalVarNeedsRef` ordering** (`call_runtime.zig` ~4658). Moved
   `if (gv.force_init) return true;` to AFTER the three binding-match guards
   (functionHasNonLexicalLocal / function_decl_names / priorDirectEvalGlobalVarMatches). qjs
   `js_closure_define_global_var` (quickjs.c:17059-17071) sets `force_init=FALSE` when a name
   resolves to a matching closure_var BEFORE the force_init redirect. Fixes the 4 eval-introduced
   binding tests (S13_A14_T1, var-env-func-init-multi, eval-has-lexical-environment,
   function-definition-eval) — eval `function name(){}` value was landing in a stale temp ref.

2. **Generator stop-boundary guard** (`zjs_vm.zig` get_var_fast/put_var_fast). The threaded
   get_var/put_var lanes (added with the var_ref fast lane) omitted the
   `localFastPathNeedsGeneratorStopBoundary(stop_before_pc)` guard every other threaded lane has
   (zjs_vm.zig:133, used at 963/1165/…). During a `.return()`-driven generator resume the lane
   `continue :sw`'d past the per-opcode stop-boundary save → corrupted generator state →
   JSException. Fixes the 7 generator-close-via-* + try-finally-* tests.

3. **Do not convert existing global properties to var_ref** (`call_runtime.ensureGlobalObjectVarRefCell`).
   An EXISTING `.data`/`.auto_init` global now returns null (no conversion). qjs
   `js_closure_define_global_var` (quickjs.c:17171-17205) hands back a detached uninitialized
   var_ref and leaves the property's slot AND observable flags untouched: a plain `var`
   redeclaration keeps its descriptor, a function redeclaration's value+flags are applied by the
   ordinary `slot_ops.defineGlobalFunctionBindingValue` define path. Converting clobbered the
   descriptor (a var_ref slot derives writable from is_const). Fixes script-decl-var/func.

4. **Parent-eval-shadow guard on the fast lane** (`vm_property.parentFunctionEvalBindingShadowsGlobal`,
   gated by the cheap inline `frameClosureHasEvalParent`; wired into getVar/putVar fast lanes and
   the `zjs_vm.zig` threaded lanes via `parentEvalShadowsGlobalForIdx`). A closure created inside an
   eval-containing function must resolve a free var to the parent's eval-introduced binding, not the
   global cell — the baseline slow path already does this via `lookupParentFunctionEvalBindingValue`
   (call_runtime.zig:7708), zjs's analog of qjs var_object_test (quickjs.c:33158-33167). The fast
   lane was bypassing it. Fixes the 20 scope-param-*-var tests. Zero cost for top-level/ordinary
   closures (frameClosureHasEvalParent short-circuits at the tag check).

## Remaining frontiers

1. **Compile-time `parent_has_eval` flag (zero-cost faithful refinement of fix 4).** qjs decides
   the var_object_test at COMPILE time — a function with an eval/with parent gets var_object_idx ≥ 0
   and the test is emitted only there, so normal functions pay ZERO runtime cost. We instead pay a
   RUNTIME per-access guard (`frameClosureHasEvalParent`: tag test + header deref + field load) on
   every global read/write. The signal already exists (`function.zig` `has_eval_call`,
   `function_def.zig` `var_object_idx`). Lowering it to a Bytecode flag checked register-resident
   would eliminate the ~6% the guard costs vs the theoretical max on global-access microbenchmarks
   (the current 31.3B/23.3B would approach 29.6B/21.7B). Medium risk (touches resolve_variables /
   bytecode), test262-gated.

2. **Pre-existing TDZ bug — NOT this round's regression (verified fails identically on clean HEAD).**
   `function r(){return y;} let y=7; r()` → qjs returns 7, zjs throws "Cannot access 'x' before
   initialization" (note the wrong atom name). A function hoisted above a top-level `let`/`const`
   captures the lexical cell while uninitialized; `let y=7` does not initialize that captured cell.
   Same FAMILY as fix 4 (global-cell aliasing) but a distinct mechanism (global lexical cell, hoisted
   capture). test262-invisible (suite is 0/49775). Repro `/tmp/lex1.js`, `/tmp/lex2.js`. Separate
   focused fix.

3. **v2-base latent concerns surfaced by code-review (all test262 + force-GC clean today, none a
   shipped regression):** (a) `slot_ops.defineGlobalFunctionBindingValue` var_ref branch writes value
   but not flags — only reachable for differing-configurability redeclaration, which can't happen in
   global script code (all cells configurable=false); (b) `object.zig` var_ref write-through sites
   carry a redundant `errdefer` alongside `setVarRefValue`'s internal one — harmless while
   setVarRefValue's error set is empty, latent double-free if it becomes fallible; (c)
   `createGlobalClosureVarRef`/`initialClosureVarRef` set is_lexical/is_const on the fresh cell but
   not on a reused shared cell; (d) `globalVarRefCellIsAuthoritative` does a `findProperty` hash probe
   per global access (gives back part of the var_ref win — a shape-mutation staleness flag would
   restore the zero-probe fast path).

4. The other previous-handover frontier — **full frame-model rewrite** (the call-machinery floor) —
   is untouched and still the path to closing the fib gap (3.65× qjs).

## Pointers
- qjs source: `/home/aneryu/quickjs/quickjs.c` (quickjs-ng 2026-06-04). Binary `/home/aneryu/quickjs/qjs`.
- Investigation findings (6-agent workflow): root-causes per bucket, all confirmed against qjs source.
- Gates: `zig build test262-gate` (0/49775), `zig build test` (1223), `zig build test -Dzjs_force_gc=true` (1223).
  NOTE `zig build test-altrepr` (nan_boxing) fails to COMPILE — verified pre-existing on clean HEAD
  (`value.zig:108 tag is not representable`), unrelated to this work.
