# L1.c — split the 648B FunctionPayload (per-closure kitchen-sink) → per-closure small + shared/rare

Working dir: /tmp/wt-align/third_party/zjs (branch perf/qjs-align, builds on L1.a commit db8b66c9). Goal: shrink the per-closure cost. Audit finding: a JS closure = 128B Object + a SEPARATE 648B FunctionPayload (object.zig ~:835) — a ~70-field struct holding promise/regexp/async/proxy/iterator/eval state for EVERY callable. qjs keeps per-closure data in a 24B u.func union (function_bytecode ref + var_refs + home_object) and ALL the promise/regexp/async markers in the SHARED JSFunctionBytecode or tiny class-specific structs — so a plain closure costs ~64B JSObject + a small var_refs array, NOT 648B+. richards/deltablue create huge numbers of bound-method closures; this 648B-per-closure is a top lever.

## Do this
1. INSPECT object.zig FunctionPayload (~:835) + every field. Categorize each field into:
   - **PER-CLOSURE-HOT** (must be inline/cheap per instance): the bytecode reference, captured var_refs/upvalues, home_object/this-binding, and the small flags a plain function actually needs to call. (qjs u.func ≈ these, 24B.)
   - **SHARED** (one per function DEFINITION, not per closure): anything derivable from the bytecode/function template (parameter info, source, name, the function KIND markers). Move to the shared bytecode/function record (allocated once per function definition), referenced by pointer.
   - **RARE-CLASS** (only for promise/regexp/async/proxy/generator/async-generator/bound/eval objects): the promise reaction state, regexp compiled data, async controller, proxy handler/target, generator state, etc. Move these to SMALL class-specific payloads (PromisePayload/RegExpPayload/AsyncPayload/ProxyPayload/...) allocated ONLY when an object of that class is created — NOT carried by every plain closure. Several of these payload types may already exist (IteratorPayload/PromisePayload/ObjectDataPayload at object.zig:719+); reuse/extend them.
2. Restructure so the common case — a plain JS function/closure — allocates only the small per-closure data (target ≈ qjs's 24B u.func equivalent), and promise/regexp/async/proxy objects allocate their own small payload on top. The `class_payload` single pointer already supports per-class payloads (used by ArrayPayload etc.) — route the rare classes through it.
3. Update all readers/writers of the moved fields to the new location (shared record or class payload). Keep semantics identical.

Report: the new size of the per-closure payload (target: from 648B toward ~24-48B for a plain closure), and which fields went where.

## Gate (MUST pass; commit when green) — CORRECTNESS ONLY, do NOT judge on perf
1. Build 3 flags 0 errors (`zig build zjs`, `-Dzjs_tailcall_dispatch=true`, `-Dzjs_recursive_dispatch=true`).
2. `zig build test --summary all` → 1192 passed; 0 failed. (This + the external test262 are the ONLY gates.)
3. Smoke: richards.js / deltablue.js / a closure+promise+regexp+generator+async test all run correctly (e.g. `zig-out/bin/zjs -e 'async function f(){await 1} f(); var r=/a(b)c/.exec("abc"); function*g(){yield 1} print([...g()], r[1], new Promise(()=>{})!=null)'`).
4. `zig fmt`; `git add -A && git commit -m "perf(zjs): L1.c split FunctionPayload — per-closure small, promise/regexp/async/proxy to class payloads"`.

## Constraints
- CORRECTNESS is the only gate — promise/regexp/async/generator/proxy/bound-function/eval semantics MUST stay identical (these are the rare classes whose state you are relocating; a mistake here breaks those features). When unsure whether a field is per-closure or shareable, KEEP it per-closure (safe, just less shrink) and report.
- Do NOT judge or revert on performance — this is a structural change; commit on correctness-green even if a local micro shows nothing. Perf is measured later, after the full memory-model alignment.
- Do NOT touch the GcNode (separate step) or the dispatcher.
- If the full split is too large to land at once, do the highest-value separation first (move the promise/async/proxy/regexp rare-class fields out so a PLAIN closure is small), COMMIT that, and report what remains.
