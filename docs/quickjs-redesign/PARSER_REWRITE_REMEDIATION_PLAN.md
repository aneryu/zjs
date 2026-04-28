# Parser Rewrite Remediation Plan

Last updated: 2026-04-29

This document is the **remediation plan** for `PARSER_REWRITE_PLAN.md`. It catalogues
every gap between the original plan's stated contract and the current
implementation, and lays out a milestone-driven path to close those gaps.

This file is the working ledger for that remediation work. The original
`PARSER_REWRITE_PLAN.md` remains the durable architectural reference; this
file is the **delivery plan** that gets the codebase to satisfy that
architectural reference.

---

## 1. Gap Summary

### 1.A BLOCKER — Strong-alignment contract or anti-regression violations

| ID | Gap | Evidence | Plan clause |
|---|---|---|---|
| **B1** | `Value.payload` still has `ptr: ?*anyopaque` + `Value.functionBytecode(ptr)` as a temporary non-GC FunctionBytecode carrier; now registered as deviation D1 with 2026-05-29 expiry | `src/engine/core/value.zig:30-32, 73-75`; `docs/quickjs-redesign/matrices/parser-deviation-matrix.md` | §1 No shortcuts; §1.5 strong-alignment contract |
| **B2** | `FunctionBytecode` field order now matches `quickjs.c:768-804`, but allocation still uses per-field `MemoryAccount.alloc` instead of QuickJS single contiguous allocation; registered as deviation D2 | `src/engine/bytecode/function.zig`; `parser-deviation-matrix.md` D2; QuickJS ref `quickjs.c:768`, `js_create_function:35499-35550` | §1.5.3 data structure mirroring contract |
| **B3** | F2+F3 is `dual_dispatch_landed`, not the planned atomic swap. `OpcodeFormat` enum keeps two dispatchers coexisting, contradicting §2.5.5.1's "transitional dual-key dispatcher is unsound" finding | `src/engine/bytecode/function.zig:28-33`; TRACKING.md F2+F3 row | §2.5.5.1 |
| **B4** | M0 by-dir baseline exists, but F4-F9 exit gates are still unmet or not isolated to their target subdirs | `docs/quickjs-redesign/baseline/2026-04-29/test262-by-dir.json`; TRACKING.md M0 Baseline Data | §2 exit-gate contract; §4 anti-regression |

### 1.B CORE — Missing core deliverables that block downstream work

| ID | Gap | Current state | Plan clause |
|---|---|---|---|
| **C1** | `createFunctionBytecode` is now wired into the qjs VM path for nested `FunctionDef` children via `runWithFunctionDefRuntime`, GC-backed `Value.functionBytecode`, `fclosure*`, bytecode-function objects, and nested bytecode calls. Remaining gap: this is still a minimal bytecode-function object path, not the full QuickJS JSFunctionObject / JS_EvalThis2 top-level replacement | `pipeline/finalize.zig`; `exec/qjs_vm.zig`; regressions `M1.3: nested FunctionDef child runs through fclosure and call`, `M1.3: nested FunctionDef function expression captures parent var` | §F10.5 |
| **C2** | `resolve_variables` is still incomplete. Done: `global_vars` pre-pass, `OP_check_define_var`, `OP_eval` scope_idx rewrite, local lowering, and a narrow parser-side parent-chain closure-var synthesis for captured `local` / `arg` / `ref`. Missing: full `resolveScopeVar`, full `getClosureVar`, every `JSClosureTypeEnum` path, private-field lowering, opt-chain lowering | `pipeline/resolve_variables.zig`; `frontend/qjs_parser.zig`; `exec/qjs_vm.zig` `get_var_ref*` runtime | §F10.1 |
| **C3** | `resolve_labels` is now partial, not absent: it emits the FunctionDef prologue skeleton, drops `OP_label`, rewrites parser absolute jump targets to post-resolve relative offsets, selects `goto8` for near `goto`, lowers `push_i32` to `push_minus1` / `push_0..7` / `push_i8` / `push_i16`, shortens direct `get` / `put` / `set` slot ops for loc/arg/var_ref where QuickJS has short forms, and coalesces both short and wide `get_loc 0; get_loc 1` to `get_loc0_loc1`. Remaining gaps: parser-side prologue metadata wiring, `LabelSlot.addr` + `JumpSlot` table-driven relocation, operand-sensitive parity, short-form-disabled byte-size reduction comparison, and exhaustive prologue tests | `pipeline/resolve_labels.zig`; `exec/qjs_vm.zig`; regressions `F10.2: resolve_labels shortens direct loc arg and var_ref slot ops`, `F10.2: resolve_labels coalesces wide get_loc 0 and get_loc 1 after short selection` | §F10.2 |
| **C4** | Closure variable synthesis is now partial, not absent: child `FunctionDef`s can register captured parent `local` / `arg` / parent `ref`, multi-level captures are threaded through intermediate `.ref` closure vars, `fclosure*` constructs a bytecode-function object with mutable var-ref cells, and `get_var_ref*` / `put_var_ref*` / `set_var_ref*` plus `put_arg*` / `set_arg*` execute in qjs VM. Covered slices include parent writes after closure creation, returned closures surviving the parent frame, function declarations callable before their declaration and capturing a later `var`, argument captures observing parent argument writes, closure writes back to parent local/argument slots, and grandparent reads/writes through a ref chain. Remaining gap: this is still targeted closure/declaration handling, not full QuickJS declaration-instantiation semantics | `qjs_parser.zig` `ensureClosureChain`, `predeclareFunctionBodyVars`; `qjs_vm.zig` `ensureVarRefCell`, `execPutArg`, `execGetVarRef`; regressions `M1.3: nested FunctionDef writes captured grandparent var through ref chain`, `M1.3: nested FunctionDef declaration is callable before declaration` | §F10.1 (`getClosureVar`) |
| **C5** | `parser.zig` (legacy QuickParser) is **6548 lines**, well over F11's <2000 target; 24 fixture recognisers (`isHarness*` / `peek*Object` / `parseSynthetic*`) still alive | `grep -cE "isHarness|peek.*Object|parseSynthetic|fixture" parser.zig = 24` | §F11.1 / §1 |
| **C6** | `emitter.zig` still contains 7 bespoke high-level emitters (`emitArrayMethod` / `emitStringMethod` / `emitMathCall` / `emitNewDate` / `emitNewCollection` / `emitUriCall` / `emitNewTypedArray`); `vm.zig` carries 10 corresponding dispatch arms | `grep -c "emit*Method" emitter.zig = 7`; `grep -c "arrayMethod\|stringMethod\|..." vm.zig = 10` | §F11.1 / §F2+F3 |

### 1.C VERIFY — Claimed complete but lacking measurement

| ID | Gap | Current state | Plan clause |
|---|---|---|---|
| **V1** | F4 marked `feature_complete`, but `language/expressions` baseline is only 1282/10645 passed (12.0%), below the ≥60% exit gate | TRACKING M0 Baseline Data | §2 exit gates |
| **V2** | F5 `partial`; `language/statements` baseline is only 818/9113 passed (9.0%), below the ≥60% exit gate; switch / for-init / labeled / catch / finally remain incomplete | TRACKING F5 row + M0 Baseline Data | §F5 / §2 |
| **V3** | F6 marked `completed`, but `language/destructuring` baseline is 0/18 passed, below the ≥60% exit gate; full destructuring semantics remain deferred | TRACKING F6 row + M0 Baseline Data | §F6 / §2 |
| **V4** | F7 `partial`; class pass-rate is not yet isolated from broader expressions data, and private field semantics, construction opcode, proto chain all remain deferred | TRACKING F7 row; M3.4 still not started | §F7 / §2 |
| **V5** | F8 `partial`, **syntax only**; `language/module-code` baseline is 166/588 passed (27.9%), below the ≥50% exit gate, with no JSModuleDef / module resolution / linking / `import.meta` / `import()` | TRACKING F8 row + M0 Baseline Data | §F8 |
| **V6** | F9 `partial`, **syntax only**: no generator state machine, no microtask scheduling, no await suspend/resume | TRACKING F9 row; §F9.2 lists F9a/F9b/F9c | §F9 |
| **V7** | F10 §9 self-claims "completed", but §F10.6 is only partially satisfied: `zig build f10-parity` now matches **50/50** configured opcode sequences and reports bytecode-size metrics (**ZJS 31,150 bytes vs QuickJS 29,700 bytes, +4.88%** on the configured anchors), but the required short-form-disabled control comparison and operand-sensitive parity are still missing, and the parity path contains normalization/deviation handling that is not a runtime wire-up | `tools/compare/dump-zjs-bytecode.zig`; `tools/compare/dump-quickjs-bytecode.sh`; `tools/compare/diff-bc.zig`; `tools/compare/run-f10-parity.sh`; `tests/test262-anchors/F10/sample.list` | §F10.6 |

### 1.D LATE — Mature work, not started

| ID | Gap | Plan clause |
|---|---|---|
| **L1** | F11 `parser.zig` deletion + high-level opcode removal not started | §F11 |
| **L2** | F12 RegExp / templates / tagged templates / String method completion not started | §F12 |
| **L3** | Comparison toolchain is active and wired: `dump-zjs-bytecode.zig`, `dump-quickjs-bytecode.sh`, `diff-bc.zig`, `run-f10-parity.sh`, and `zig build f10-parity` exist; the configured 50-entry opcode-sequence gate now passes and reports aggregate bytecode-size metrics, with operand sensitivity and the short-form-disabled reduction measurement still outstanding | §4 QuickJS comparison tooling |

---

## 2. Improvement Plan

ROI-prioritised, four milestones. Each milestone has a **measurable** exit gate
— not "code complete" but "numbers meet the contract".

### Milestone M0 — Stop the bleeding, baseline the truth (1 week)

> **Goal**: stop the morale-victory pattern. Establish a factual baseline of
> what is actually broken. Then we can talk about progress.

#### M0.1 Roll back the last 7 days of shortcuts (B1, B2)

- **Roll back `Value.payload.ptr`** variant. Either:
  - delete `Value.functionBytecode` and the `ptr` payload variant entirely, or
  - register the deviation in a new `docs/quickjs-redesign/matrices/parser-deviation-matrix.md` with a 30-day expiry date and the conditions under which the deviation must be retired
- **Reorder `FunctionBytecode` fields to match QuickJS**. The flat per-field allocation may be retained (registered as `-DZJS_FB_FLAT_ALLOC` in the deviation matrix), but **field names, types, and order must be 1:1 with `quickjs.c:768-804`**
- **`createFunctionBytecode` either gets wired up or gets `@compileError("not wired")`**. Dead code that audit tools mistake for "complete" must not survive

**Acceptance**:
- `grep -n "ptr: ?*anyopaque" src/engine/core/value.zig` returns 0 lines (rollback) **or** the deviation matrix file exists with a dated entry
- `parser-deviation-matrix.md` exists and lists every current deviation with expiry dates

#### M0.2 Rebuild the test262 by-dir baseline

- Run `zig build run-test262 -Dargs="-c quickjs/test262.conf -d quickjs/test262/test 0 100000"`, output to `reports/test262-2026-04-29/`
- Diff against `docs/quickjs-redesign/baseline/2026-04-27/`, commit as the new baseline
- Backfill the by-dir numbers into TRACKING.md F4-F9 "latest validation" columns

**Acceptance**:
- `reports/test262-2026-04-29/test262-by-dir.json` exists and is committed
- TRACKING.md F4-F9 rows carry concrete numbers (passed / failed / ratio) compared against their plan exit gates

#### M0.3 CI anti-regression gate

- Add `--regression-baseline reports/test262-2026-04-29/test262-by-dir.json` flag to `tools/test262_runner.zig` (planned in §4 but not implemented)
- Enable by default in the `run-test262` step of `build.zig`
- Any directory pass-rate drop → exit non-zero

**Acceptance**: deliberately break one expression test, `zig build run-test262` exits 1

---

### Milestone M1 — F10 actually finished (3-4 weeks)

> **Goal**: make the §9 self-claimed "F10 completed" line honest by satisfying
> §F10.6 exit gates. This is the foundation for every later phase.

#### M1.1 FunctionDef-driven `resolve_variables` (closes C2)

Mirror `quickjs.c:33622` step by step:

| Sub-task | QuickJS ref | Acceptance |
|---|---|---|
| `global_vars` pre-pass + `OP_check_define_var` emission | `quickjs.c:33636-33672` | `var x = 1; var x;` round-trips correctly |
| `OP_eval` / `OP_apply_eval` scope_idx → `s->scopes[scope].first + 1` rewrite | `quickjs.c:~33700` | `eval("var x")` captures correctly |
| `resolveScopeVar` lexical-chain walk | `quickjs.c:32377` | Nested scope hits the right var |
| `getClosureVar` closure-variable synthesis | `quickjs.c:32162` | `closure_var[]` table populated correctly |
| `JSClosureTypeEnum` classification → emits `get_loc / get_arg / get_var_ref / get_var / get_var_undef` | `quickjs.c:675` | Each closure_type value has a corresponding opcode test |
| Private-field lowering (`scope_get_private_field` → `get_private_field`) | `quickjs.c:~33850` | Class private field read/write |
| Opt-chain lowering | `quickjs.c:~33900` | `a?.b?.c` end-jump correct |

**Acceptance**:
- `pipeline/resolve_variables_test.zig` has one test per `JSClosureTypeEnum` value
- End-to-end test `function f(){var a=1; function g(){return a;} return g();}` returns 1

#### M1.2 FunctionDef-driven `resolve_labels` + function prologue (closes C3)

| Sub-task | QuickJS ref | Acceptance |
|---|---|---|
| Function prologue: `OP_special_object` for home_object / this_active_func / new_target / arguments / func_var / var_object | `quickjs.c:34232-34294` | Each special_object subtype has a VM test |
| `LabelSlot.addr` + `JumpSlot` relocation table | `quickjs.c:34197-34800` | Jump targets remain correct after short-form selection |
| Full `put_short_code` (`*0..*3` / `*8` / 16-bit) | `quickjs.c:34140` | `bytecode/short_code_test.zig` covers every (op, idx) combination |
| `push_short_int` (`push_minus1` / `push_0..7` / `push_i8` / `push_i16` / `push_i32`) | `quickjs.c:34120` | Integer literals select op by value range |
| `get_loc0_loc1` and other adjacent-op coalescing | `quickjs.c:~34600` | Adjacent loc operations merge |
| Relative-offset jump patching (`goto8` / `goto16` / `if_true8` / `if_false8`) | `quickjs.c:~34700` | Distance ≤127 takes the 8-bit form |

**Acceptance**:
- `pipeline/short_code_test.zig` ≥30 (op, idx) combinations
- Prologue tests cover every special_object subtype

#### M1.3 Wire up `js_create_function` end to end (closes C1)

- Change `runWithFunctionDef(bytecode, fd)` to: first `for child in fd.child_list: createFunctionBytecode(child)` recursively, install results into the parent's cpool; then process fd itself
- Top-level program parse returns a **single `FunctionBytecode`** to `JS_EvalThis2`
- Wire `Value.functionBytecode` into GC: add `gc.ObjectHeader` to `FunctionBytecode`, register with `gc.Registry.add(fb.header)`, ensure `Value.refHeader` / `dup` / `release` handle the `function_bytecode` tag correctly
- VM, on encountering `op.fclosure <const_idx>`, fetches FunctionBytecode from cpool and constructs a JSFunctionObject

**Acceptance**:
- Nested function end-to-end `function outer(){function inner(){return 42;} return inner();} outer();` runs through qjs_parser → pipeline → qjs_vm and returns 42
- GC valgrind-clean

#### M1.4 Comparison toolchain + parity gate (closes V7, L3)

Per §4 of the original plan:
- `tools/compare/dump-zjs-bytecode.zig` — output the same ASCII format as `qjs --bytecode-dump`
- `tools/compare/dump-quickjs-bytecode.sh` — wraps `qjs --bytecode-dump`
- `tools/compare/diff-bc.zig` — strip atom_id / label_id, then diff op sequences
- `tests/test262-anchors/F10/sample.list` — 50 representative scripts
- `zig build f10-parity` — diff all 50; **100% op-sequence match** or non-zero exit

**Acceptance**:
- 50/50 op-sequence parity
- Bytecode byte size ↓ ≥30% (vs a control with short-form selection disabled)

---

### Milestone M2 — F2+F3 real atomic swap (2-3 weeks)

> **Goal**: kill the dual dispatcher. Per §2.5.5 this is indivisible work.

#### M2.1 Expand every bespoke opcode

Per `matrices/opcode-execution-matrix.md` Buckets A/B/C:
- **Bucket A** (directly isomorphic to a single QuickJS op): parser emits the QuickJS op directly
- **Bucket B** (expands to an op sequence): parser emits the generic sequence (e.g. `get_var Math; get_field min; call argc`); `emit*` helper deleted from emitter; corresponding dispatch arm deleted from VM
- **Bucket C** (kept as a builtin call): parser uses generic `call_method` against a builtin

**Acceptance**:
- `grep -c "pub const known\." emitter.zig = 0`
- `grep -cE "emit(Array|String|Math|Date|Uri|Collection|TypedArray)Method" emitter.zig = 0`
- vm.zig dispatch arms for those bespoke ops likewise zero

#### M2.2 Delete the OpcodeFormat enum

- All `bytecode.Bytecode` flow through the new dispatcher
- Delete the legacy dispatcher in `exec/vm.zig` (keep `exec/qjs_vm.zig` as the only one)
- Legacy `parser.zig` may stay for now but must produce only the new ABI

**Acceptance**:
- `grep -n "OpcodeFormat" src/engine/` returns no matches after the deletion commit
- `zig build run-test262` shows **every dir pass-rate ≥** the M0.2 baseline

---

### Milestone M3 — F4-F9 exit gates met (4-6 weeks, parallelisable)

> **Goal**: turn F4-F9 from "code looks done" into "test262 numbers meet the bar".

#### M3.1 F4 → `language/expressions ≥60%`

- Run M0.2 baseline against the corresponding dir, identify the top-10 failure modes
- Mirror missing expression forms one by one against `quickjs.c` line numbers (spread call, tagged template, optional call, private name expression, ...)
- Per failure class: anchor test → by-dir snapshot → commit

#### M3.2 F5 → `language/statements ≥60%`

- Take every item the F5 row currently labels "deferred to F10" (switch case parsing, full for-init/test/update, for-in/of, labeled statements, catch/finally semantics, full scope management) and turn each into its own sub-PR
- Each sub-PR ties to a specific failure bucket

#### M3.3 F6 → `language/destructuring ≥60%`

- Split into F6a (binding destructuring) / F6b (assignment destructuring)
- `parseDestructuringElement` mirrors `quickjs.c:25716` completely, including default, rest, computed key

#### M3.4 F7 → `language/expressions/class ≥50%`

- Replace placeholder `define_class` op: implement a real class-construction opcode
- Private fields: from syntax placeholder to full semantics (owner check, `#`-prefixed atom, `scope_get_private_field` lowering)
- Proto chain: real runtime wiring of `extends`

#### M3.5 F8 → `language/module-code ≥50%`

- Introduce a `JSModuleDef` mirror (QuickJS `quickjs.c:~32100`)
- Import / export entry tables
- Module resolution + linking + instantiation (`JS_LinkModule` / `JS_EvalModule`)
- `import.meta` / `import()` are not required until F12

#### M3.6 F9 → `language/statements/async-function ≥40%` (split F9a/F9b/F9c)

- F9a: existing syntax acceptance + synchronous lowering
- F9b: generator state machine — `JSGeneratorState`, `OP_initial_yield`, suspend / resume frames
- F9c: async / await + microtask (hooked into the existing job queue)

**M3 overall acceptance**: by-dir pass-rate vs M0.2 baseline rises to the target threshold for every listed dir.

---

### Milestone M4 — F11 + F12 (4-5 weeks)

#### M4.1 F11 fixture-recogniser deletion (closes C5, L1)

Per §F11.1 deletion checklist:
- For each recogniser group deleted from `parser.zig`: run M0.2 dir-by-dir tests; pass rate must not drop
- Targets: `parser.zig < 2000` lines; `grep` for fixture markers returns 0
- emitter / vm cleanup happens in step (already largely done in M2.1)

**Acceptance**:
- `wc -l parser.zig` < 2000
- Total test262 ≥ 25000 / 48205

#### M4.2 F12 RegExp + templates (closes L2)

- `libs/regexp/` wired into the RegExp literal compilation path
- Template substitution / tagged templates / `raw` property
- Missing String methods filled in (`normalize` / iterators / locale)

**Acceptance**:
- `built-ins/RegExp ≥ 50%`
- `language/expressions/template-literal ≥ 80%`

---

## 3. Operating Discipline

To prevent the failure mode that produced the "F10 self-claimed completed"
gap in the first place:

1. **Every milestone exit gate must be a measured number, not "code complete"**. A milestone with an unmet exit gate cannot be marked completed.
2. **Every PR must include before/after by-dir data**. No data, no review.
3. **Every strong-alignment violation must be registered in the deviation matrix first**. Adding new `Value.payload` variants, reordering `JSFunctionBytecode` fields, or introducing non-QuickJS opcodes — all three classes must first land an entry in `parser-deviation-matrix.md` with an expiry date.
4. **Dead code is deleted immediately**. Orphan functions like `createFunctionBytecode` may not merge unless they have a call site and tests — otherwise audit tools are deceived.
5. **No more thin-skeleton "F10.1h" naming**. §F10 already has g-suffixes; piling on h/i/j does not solve core problems. M0 is complete; the next work must close a measured M1 exit-gate item rather than adding another skeleton label.

---

## 4. Milestone schedule

| Milestone | Working days | Exit gate |
|---|---|---|
| M0 Stop the bleeding, baseline truth | 5 | deviation matrix exists; new test262 baseline committed; CI anti-regression gate enabled |
| M1 F10 actually finished | 15-20 | 50/50 op-sequence parity; bytecode ↓30%; nested function e2e |
| M2 F2+F3 atomic swap | 10-15 | Bespoke opcodes all zero; OpcodeFormat deleted; dir pass-rate ≥ baseline |
| M3 F4-F9 exit gates | 20-30 | Each dir meets §2 thresholds |
| M4 F11 + F12 | 20-25 | parser.zig <2000 lines; total ≥25000 |

Roughly **70-95 working days** total (about 3-4 months of dedicated single-person time). With cloud-handoff parallelism on M3 sub-items, achievable in 2.5-3 months.

---

## 5. Status

Last updated: 2026-04-29 (honest re-audit after code-level verification).

| Milestone | Status | Notes |
|---|---|---|
| M0.1 Rollback shortcuts | completed | `parser-deviation-matrix.md` exists; `FunctionBytecode` field order matches `quickjs.c:768-804`; `createFunctionBytecode` now has a real nested-runtime call path — see M1.3 for remaining JSFunctionObject / top-level gaps |
| M0.2 test262 baseline | completed | `docs/quickjs-redesign/baseline/2026-04-29/test262-by-dir.json` committed |
| M0.3 CI anti-regression gate | completed | `--regression-baseline` flag wired in `build.zig:104-105`; unit-test `test262 checkRegressions detects passed-count drops` exercises the path; `run-test262` now exits non-zero for directory regressions while allowing the committed baseline's existing failures, so `zig build test262-gate --summary all` is a usable green anti-regression gate |
| M1.1 closure / private / opt-chain | partial | task1 (global_vars + `OP_check_define_var`) and task2 (`OP_eval` scope_idx rewrite) done. task3 (`resolveScopeVar`) is local-only. A narrow parser-side parent-chain capture path now populates `closure_var` for captured parent `local` / `arg` / `ref`, including multi-level ref-chain propagation through intermediate functions; qjs VM executes `get_var_ref*` / `put_var_ref*` / `set_var_ref*` through mutable var-ref cells; qjs VM supports `put_arg*` / `set_arg*`; and a function-body `var` predeclaration scan covers function declarations that capture a later simple `var`. Full QuickJS declaration-instantiation / `getClosureVar`, every `JSClosureTypeEnum` path, task6 private field + opt-chain lowering remain **not done** |
| M1.2 prologue / labels / short-form | partial | task1 prologue skeleton landed in `resolve_labels.zig`, and `finalize.runWithFunctionDef` now passes the `FunctionDef` into `resolve_labels`; the parser still does not set `home_object_var_idx` / `this_var_idx` / `arguments_var_idx` etc., so most prologue paths emit nothing in real bytecode. Additional real slices landed: parser absolute jumps are rewritten to final relative offsets, qjs VM executes relative `goto` / `if_true` / `if_false` plus `goto8` / `goto16` / `if_true8` / `if_false8`, `goto8` is selected for near targets, `push_i32` lowers through `push_minus1` / `push_0..7` / `push_i8` / `push_i16`, direct final-form loc/arg/var_ref slot ops shorten to the QuickJS-available short forms, and short or wide `get_loc 0; get_loc 1` coalesces to `get_loc0_loc1`. Still incomplete: parser-side prologue metadata, table-driven `LabelSlot.addr` / `JumpSlot` relocation, operand-sensitive parity, short-form-disabled byte-size reduction comparison, and exhaustive prologue tests |
| M1.3 wire js_create_function | partial | `createFunctionBytecode` is now runtime-wired for nested qjs bytecode: parser reserves parent cpool slots for child `FunctionDef`s, `runWithFunctionDefRuntime` recursively materialises GC-registered `FunctionBytecode` values, `fclosure`/`fclosure8` load them from constants, create a minimal `bytecode_function` object, capture parent/ancestor `local` / `arg` / `ref` via mutable var-ref cells, and `call`/`call0..3` execute nested `FunctionBytecode`. Covered by `tests/exec/qjs_vm_test.zig` M1.3 regressions for no-capture nested calls, parent-var capture, argument capture, post-closure parent local/argument writes, returned closures, function declarations capturing later `var` declarations, function declarations callable before their declaration, parent local/argument writeback from inner functions, and grandparent ref-chain read/write captures. Still incomplete: full QuickJS JSFunctionObject construction, full declaration-instantiation semantics beyond the targeted simple-`var` predeclare scan, top-level `JS_EvalThis2` returning a single `FunctionBytecode`, and valgrind-level GC proof |
| M1.4 comparison toolchain | partial | `tools/compare/dump-zjs-bytecode.zig` is a **real disassembler** wired as `zig build dump-zjs-bytecode`; `tools/compare/dump-quickjs-bytecode.sh` preserves dumps even when a fixture throws after dumping; `tools/compare/diff-bc.zig` parses dump files into normalized opcode sequences after instruction markers and exits non-zero on mismatch; `tools/compare/run-f10-parity.sh` is wired as `zig build f10-parity` over the 50-entry sample list. After rebuilding local `quickjs/build/qjs` with `ENABLE_DUMPS`, `zig build f10-parity --summary all` passes **50/50 opcode sequences** and now reports aggregate bytecode-size metrics: **ZJS 31,150 bytes, QuickJS 29,700 bytes, 9,496 instructions, +1,450 bytes / +4.88% vs QuickJS**. Operand-sensitive parity and the required short-form-disabled control comparison remain unmeasured |
| M2.1 expand bespoke opcodes | not_started | `grep -cE "emit(Array\|String\|Math\|Date\|Uri\|Collection\|TypedArray)Method" src/engine/bytecode = 3` (target 0); 61-row Bucket A/B/C plan in `matrices/opcode-execution-matrix.md` is still authoritative but no source rewrite has happened |
| M2.2 delete OpcodeFormat enum | not_started | `grep -c OpcodeFormat src/engine = 5` (target 0); legacy + qjs dispatchers still coexist in `exec/vm.zig` and `exec/qjs_vm.zig` |
| M3.1-M3.6 F4-F9 exit gates | not_started | No by-dir snapshot taken since the M0.2 baseline; no exit gate has been measured |
| M4.1 parser.zig <2000 lines | not_started | `wc -l src/engine/frontend/parser.zig = 6548` (target <2000); `grep -cE "isHarness\|peek.*Object\|parseSynthetic" src/engine/frontend/parser.zig = 24` (target 0) |
| M4.2 RegExp + templates | not_started | No work in `libs/regexp/` literal compilation path |

### Immediate next work order

1. **Complete declaration-instantiation semantics**: simple `var` predeclaration now covers function-declaration captures of later vars, but destructuring vars, Annex B interactions, eval/arguments effects, and full QuickJS declaration ordering remain incomplete.
2. **Replace the minimal bytecode-function object with a full JSFunctionObject path**: `fclosure*` now constructs an object with bytecode and captures, but it is not yet the full QuickJS function object model.
3. **Make top-level evaluation FunctionDef-first**: top-level qjs parser execution still uses `Bytecode`; `JS_EvalThis2` should eventually receive a single final `FunctionBytecode`.
4. **Finish label relocation and prologue proof**: replace the current direct absolute-target rewrite with full `LabelSlot.addr` / `JumpSlot` relocation, wire parser-side prologue metadata, add exhaustive prologue tests, and measure operand-sensitive parity plus byte-size reduction.
5. **Rerun M1 gates before M2**: nested function e2e, 50/50 op-sequence parity, bytecode-size reduction, `zig build test`, `zig build smoke`, and the test262 regression gate must all be measured before starting the atomic dispatcher swap.

### What is verified to work today

- `zig build qjs` clean
- `zig build test --summary all`: **17/17 build steps succeeded; 464/464 tests passed** (includes nested `FunctionDef` -> `fclosure` -> call, parent-var/argument capture/writeback, grandparent ref-chain capture/writeback, post-closure write, returned-closure, later-`var` hoist capture, callable-before-declaration, relative-jump, short-int, conditional-wide-jump, direct slot short-code, and wide `get_loc0_loc1` regressions)
- `zig build smoke --summary all`: **45/45 scripts passed**
- `zig build dump-zjs-bytecode` produces a working disassembler at `zig-out/bin/dump-zjs-bytecode`
- `zig build f10-parity --summary all`: **50/50 configured opcode sequences matched**; bytecode-size metrics now report **ZJS 31,150 bytes vs QuickJS 29,700 bytes** across **9,496** compared instructions (**+1,450 bytes / +4.88%**)
- `zig build test262-gate --summary all`: **4/4 steps succeeded**; full selected test262 run matched the 2026-04-29 baseline (`36698/48205` errors, `5442` passed, `60` known) and exits non-zero only on dir-level passed-count regressions

### What is honestly not done

The plan's §4 schedule estimates 70-95 working days. M0 is done in real terms; M1.3 now has a real nested-function runtime path with a minimal bytecode-function object, mutable var-ref cells, post-capture write visibility, writeback through captured refs, returned-closure survival, simple later-`var` hoist capture, and callable-before-declaration coverage. M1.2 now has real relative-jump rewriting, qjs VM relative jump execution, small-int short forms, direct loc/arg/var_ref slot short-code selection, and `get_loc0_loc1` coalescing, but it is not the full QuickJS relocation/prologue implementation. M1.4 has the dump/diff tools, 50-entry sample list, passing `zig build f10-parity` opcode-sequence gate, and aggregate bytecode-size measurement against QuickJS. The rest of M1 (full declaration-instantiation semantics, M1.1 remaining classification/private/opt-chain work, remaining M1.2 relocation/prologue proof, full JSFunctionObject semantics, operand-sensitive parity, and the short-form-disabled bytecode-size reduction comparison) remains focused follow-up work. M2 (atomic swap — the plan §2.5.5.1 explicitly states piecemeal renames are unsound, so this must land as one coordinated change) and M3 (F4-F9 numeric gates) are the heaviest blocks remaining. M4 is the cleanup pass after M2-M3 land.

---

## 6. Cross-references

- Original plan: `docs/quickjs-redesign/PARSER_REWRITE_PLAN.md`
- Phase status: `docs/quickjs-redesign/TRACKING.md` (parser-rewrite sub-rows)
- Current test262 baseline: `docs/quickjs-redesign/baseline/2026-04-29/test262-by-dir.json`
- Deviation matrix: `docs/quickjs-redesign/matrices/parser-deviation-matrix.md`
- Opcode bucket plan: `docs/quickjs-redesign/matrices/opcode-execution-matrix.md`
- QuickJS reference: `quickjs/quickjs.c`, `quickjs/quickjs-opcode.h`, `quickjs/quickjs-atom.h` at SHA `64e64ebb1dd61505c256285a699c65c42941c5ed`
