# M2 — eliminate hot-path `bl` + make slow paths noinline (read ALIGN-PLAN.md, builds on M1 commit d36732db)

Working dir: /tmp/wt-align/third_party/zjs. Target: src/exec/call_internal.zig `dispatchRecursive` + the helpers it calls. Goal: match qjs's body structure — the HOT loop has ZERO `bl` (function calls); every slow/delegating path is a `no_inline` function called ONLY from cold arms.

## Why (proven)
A `bl` (call) in a HOT arm clobbers caller-saved registers, forcing dispatchRecursive to RELOAD the hot pointers (code base, var_buf, sp) after the call — this is exactly why M1's A5 (var_buf register) gave NO load reduction (131->131): a hot-arm `bl` keeps clobbering var_buf. qjs's hot opcode bodies are fully inline (JS_CallInternal 73% self); its slow paths are `no_inline` (`js_binary_arith_slow` etc.) reached only on the cold branch, so the hot loop's registers survive.

## Do this
1. **Find every `bl` on the HOT path.** objdump the dispatchRecursive hot loop (`objdump -d zig-out/bin/zjs` around `exec.call_internal.dispatchRecursive`), and/or perf-annotate on /tmp/lv-int.js + crypto, and list the `bl` targets that are reached on the fast path of hot opcodes (get_loc/put_loc/get_arg/push/int-arith/compare/if/goto/inc/dec/drop/dup + the get_field/put_field/get_array_el/put_array_el dense fast paths). The arith fast path (fastBinaryInt32 / tryInt32BinaryWindow*) should already be inline from prior work — verify no `bl` remains there.
2. **Inline the fast leaf of each hot-path `bl`** so the fast case is call-free (the value stays in registers); keep ONLY the slow case behind a call. Pattern: `if (fast-case-inline) { ...no bl...; continue; } else { enterStackBoundary; bl slowHelper; leaveStackBoundary; }`. Apply to get_field/put_field (the qjsGetFieldFast/qjsPutFieldFast fast path — make the monomorphic-hit path fully inline, no `bl`), get_array_el/put_array_el (dense in-bounds get/set inline; the refcount dup/free for the read value is cheap inline; only object/exotic/grow cases `bl`), and any get_loc/put_loc slow helper still `bl`'d on the fast path.
3. **Mark every SLOW/delegating helper `noinline`** (Zig: `@call(.never_inline, f, .{...})` at the call site, OR add a `noinline` qualifier on the fn) so LLVM does NOT inline the cold bodies into dispatchRecursive (which would bloat it + add live values + re-spill). Targets: binaryVm/compareVm/unaryVm, the value_vm.* push-const/atom delegations, vm_call.* call setup, vm_property_field slow paths, object/array literal builders, iterator ops, etc. — everything currently reached via the cold arms' `enterStackBoundary; <delegate>; leaveStackBoundary` pattern. Keep their behavior identical; just prevent inlining.
4. **Re-measure after EACH of (2) and (3):** loads/iter + instr/iter on /tmp/lv-int.js (target: drop below M1's 131/528 toward qjs 71/196 — especially watch whether var_buf/sp now STAY in registers, i.e. the per-opcode `ldr [frame,#..]` locals reload disappears in the disasm) + crypto best-of-5 vs fresh c0be6fce baseline. Report the disasm before/after for one hot arm (e.g. get_loc) showing the locals reload gone.

## Gate (MUST pass; commit when green) — same as M1
1. Build 3 flags 0 errors (`zig build zjs`, `-Dzjs_tailcall_dispatch=true`, `-Dzjs_recursive_dispatch=true`).
2. Debug dual-population assert: `zig build zjs -Doptimize=Debug -Dzjs_recursive_dispatch=true`; run the M1 assert script (`var s=0;function f(a){...}...print(s)`) -> 179999400004, no panic.
3. GC-stress (tiny gc threshold, Debug recursive) -> same output, no UAF; revert the hack.
4. `zig build test --summary all` -> 1192 passed; 0 failed.
5. Report loads/iter + instr/iter + crypto vs baseline + the disasm evidence.
6. `zig fmt` touched files; `git add -A && git commit -m "align(zjs): M2 zero hot-path bl + noinline slow paths (qjs body structure)"`.

## Constraints
- Correctness first; the GC-root publish discipline + dual-population assert must hold (do NOT skip enterStackBoundary/leaveStackBoundary on any arm that can allocate/GC/sub-call).
- Do NOT touch tailcall/dispatchLoop dispatchers.
- noinline on a slow helper must not change semantics — if marking a fn noinline causes a build/behavior issue (e.g. it was relied upon to inline for comptime), leave it and note it.
- If inlining a field/array fast path is too risky (refcount/GC subtlety), keep it delegated but ensure that delegation is a clean noinline `bl` on the COLD branch only (not on the monomorphic fast path), and report which ones you left.
- Commit the largest correct subset; report what's left + measured loads/iter.
