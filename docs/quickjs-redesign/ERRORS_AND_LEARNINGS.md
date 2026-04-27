# Errors And Learnings

This file is the durable error ledger for the QuickJS Zig redesign. It records
failures, root causes, fixes, regression tests, and reusable lessons. It is not a
replacement for `TRACKING.md`: tracking keeps the current board, while this file
keeps the knowledge needed to avoid repeating mistakes.

## When To Create A Record

Create an error record when any of these happen:

- A validation command fails after implementation work has started.
- `run-test262` reports a new, changed, or fixed result relative to a known-error baseline.
- A crash, panic, stack overflow, allocator leak, OOM path bug, or use-after-free is observed.
- Zig behavior differs from local QuickJS behavior for an in-scope feature.
- A broad validation run is interrupted and could be mistaken for final evidence later.
- A failure reveals a reusable implementation rule, source mapping rule, or test strategy.
- A planned `out_of_scope` result needs explicit justification to avoid future rediscovery.

Do not create a full record for a typo or local edit mistake that is fixed before
running validation and has no reusable lesson. If the same mistake happens twice,
create a learning record.

## Record ID And Location

- Record IDs use `EAL-YYYYMMDD-NNN`.
- New detailed records should be created from `templates/error-record.md`.
- Store detailed records under `docs/quickjs-redesign/errors/` if the entry is
  longer than a few lines. Short entries may live only in the index table below.
- Link every detailed record from the index table.

## Status Vocabulary

- `open`: failure exists and is not fully understood.
- `investigating`: reproduction or QuickJS comparison is in progress.
- `fixed`: code was changed, but final validation evidence is missing.
- `validated`: fix has a regression test and validation evidence.
- `parked`: intentionally deferred to a named phase or dependency.
- `duplicate`: covered by another error record.
- `out_of_scope`: not part of the selected QuickJS core scope.

## Classification Vocabulary

- `quickjs_parity_gap`: Zig behavior differs from local QuickJS behavior.
- `zig_lifetime_bug`: ownership, refcount, use-after-free, or double-free bug.
- `allocator_leak`: leak or allocator accounting mismatch.
- `parser_gap`: lexer/parser accepts or rejects incorrectly.
- `emitter_gap`: parser succeeds but bytecode or metadata is wrong.
- `opcode_gap`: VM opcode handler is missing or semantically wrong.
- `builtin_gap`: builtin behavior or descriptors differ from QuickJS.
- `runner_bug`: `run-test262`, smoke, compare, or CLI tooling is wrong.
- `test_baseline_issue`: config, exclude list, harness, known-error, or oracle issue.
- `build_wiring`: build graph, module import, or stale path issue.
- `docs_tracking_gap`: process failed to record status, evidence, or handoff.
- `interrupted_validation`: command did not complete and must not be treated as proof.
- `out_of_scope`: confirmed outside the selected implementation scope.

## Error Workflow

1. Capture the exact symptom and command.
2. Classify the failure and assign severity.
3. Compare against local QuickJS when behavior is semantic.
4. Identify the QuickJS source owner and Zig owner.
5. Fix the smallest responsible subsystem.
6. Add or update focused regression tests before broad validation.
7. Update the relevant phase checklist and matrix row.
8. Add validation evidence to `TRACKING.md`.
9. Close the record only after the regression and gate evidence are recorded.
10. Promote reusable lessons into the learning log below.

## Error Index

| ID | Status | Severity | Phase | Classification | Symptom | Record | Regression | Matrix rows |
|---|---|---|---|---|---|---|---|---|
| EAL-20260424-001 | validated | low | docs | docs_tracking_gap | Redesign plan lacked a durable error and learning workflow. | `#eal-20260424-001-error-and-learning-workflow-missing` | `git diff --check -- QUICKJS_REDESIGN_PLAN.md docs/quickjs-redesign` | README, TRACKING, test262 parity |
| EAL-20260424-002 | validated | high | 8-9 | quickjs_parity_gap | Real smoke runner initially failed 45/45 scripts because `zjs` did not yet produce smoke-visible output such as `print(...)`. | `#eal-20260424-002-smoke-runner-wired-before-output-semantics` | `zig build smoke --summary all` | Phase 8 smoke runner, Phase 9 runtime hardening |
| EAL-20260426-003 | in_progress | high | AR | parser_gap, emitter_gap, opcode_gap, docs_tracking_gap | Parser dispatch is single-path, audited fixture opcodes were removed, native-method string synthesis is gone, and VM helper unsupported failures now surface as JS errors; narrow parser/builtin scaffolds still block semantic-complete claims. | `#eal-20260426-003-parser-and-vm-fixture-shortcuts` | `zig build test-frontend --summary all`; targeted parser/test262 slices | Frontend coverage, opcode execution, architecture repair |
| EAL-20260427-004 | validated | high | WQ-015 | zig_lifetime_bug | Unsupported calls with evaluated string arguments could double-free argument constants on the TypeError path and panic during bytecode teardown. | `#eal-20260427-004-call-argument-cleanup-double-free` | `zig build test-exec --summary all`; `zig build smoke --summary all` | Opcode execution, runtime hardening |
| EAL-20260427-005 | open | high | WQ-012 | parser_gap, builtin_gap, docs_tracking_gap | Test262 validation claims outpaced executable evidence; built-ins/global and Object/is are now repaired, but Map still has focused semantic failures. | `#eal-20260427-005-test262-validation-claims-outpaced-parser-semantics` | built-ins/global and Object/is targeted slices; Map blocker pending | TRACKING, frontend coverage, builtins matrix |
| EAL-20260427-006 | parked | high | WQ-012/WQ-014 | zig_lifetime_bug, builtin_gap | Standard `prototype.constructor` back-links create a constructor/prototype refcount cycle and trip teardown assertions until WQ-014 graph tracing/cycle collection owns that edge. | `#eal-20260427-006-constructor-prototype-backlink-needs-cycle-gc` | pending WQ-014 cycle regression | Core runtime invariants, builtins matrix |
| EAL-20260427-007 | validated | high | WQ-012 | zig_lifetime_bug, builtin_gap | `Object.defineProperty` returned a borrowed target object, so dropping the return value could release live prototype objects and crash later tests. | `#eal-20260427-007-object-defineproperty-returned-borrowed-target` | `Object.defineProperty returns retained target object`; Map focused run no longer exits 139 | Opcode execution, builtins matrix |

## Detailed Records

### EAL-20260424-001: Error And Learning Workflow Missing

Status: validated
Severity: low
Phase: docs
Classification: docs_tracking_gap

Summary: The redesign documentation had phase tracking, validation logs, known
failures, risks, and decisions, but no durable root-cause and learning workflow.
Long-running implementation would have lost reusable lessons across sessions.

Root cause: Error evidence and learning evidence were treated as fields inside
`TRACKING.md` instead of a separate workflow with classification, reproduction,
root cause, regression, matrix update, and closure requirements.

Fix:

- Added `ERRORS_AND_LEARNINGS.md`.
- Added `templates/error-record.md`.
- Updated root plan, README, tracking, and test262 parity matrix to require error records for reusable failures.

Validation:

```bash
git diff --check -- QUICKJS_REDESIGN_PLAN.md docs/quickjs-redesign
```

Learning: Validation evidence, known-failure summaries, and root-cause learning
serve different purposes and need separate records.

### EAL-20260424-002: Smoke Runner Wired Before Output Semantics

Status: validated
Severity: high
Phase: 8-9
Classification: quickjs_parity_gap

Summary: Phase 8 wired `zig build smoke` to the rebuilt `zjs` executable and the
existing `tests/zig-smoke/manifest.txt` golden files. The runner worked as a real
comparator, and initially all 45 manifest scripts failed because runtime-visible
output was missing.

Reproduction:

```bash
ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build smoke --summary all
```

Initial observed result: exit 1. The runner reported `smoke: 45/45 scripts failed`.
Most failures had status 0 but stdout length 0 because the rebuilt engine did
not yet implement smoke-visible output such as `print(...)`. A few scripts exited
1 on unsupported frontend/execution paths.

QuickJS owner: `quickjs/qjs.c` for CLI-visible execution behavior and
`quickjs/quickjs.c` for global builtin registration and execution semantics.

Zig owner: `src/cli/qjs.zig`, `src/engine/root.zig`, builtin global setup, and
the frontend/exec paths needed by smoke scripts.

Fix summary: Phase 8 completed the smoke runner and broader execution coverage.
Phase 9 removed the dedicated host output opcode path and routed `print(...)`
and `console.log(...)` through normal global lookup, property access, callable
values, generic call execution, and the existing `Engine.evalWithOutput*` writer.

Validation:

```bash
zig build smoke --summary all
QJS=/home/aneryu/zjs/quickjs/build/qjs QJS_ZIG=/home/aneryu/zjs/zig-out/bin/zjs bun tools/compare/run_compare.js --functional-only
./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test 0 100000
```

Current result: smoke passes 45/45 scripts, functional compare passes 45/45
scripts, and the full local test262 gate reports `0/48205 errors`.

### EAL-20260426-003: Parser And VM Fixture Shortcuts

Status: in_progress
Severity: high
Phase: AR
Classification: parser_gap, emitter_gap, opcode_gap, docs_tracking_gap

Summary: A read-only audit found that selected smoke/test262 gates can pass while
`frontend/parser.zig`, `bytecode/emitter.zig`, and `exec/vm.zig` contain
fixture-shaped shortcuts. This is not just missing feature coverage; some paths
recognize test metadata, source comments, or narrow source shapes and then emit
purpose-built bytecode or VM behavior. Several audited opcode and marker
classes have since been removed. Remaining narrow lowering shapes and broader
builtin/prototype gaps are follow-up semantic-completion work rather than open
architecture-repair shortcuts.

Observed shortcut classes and current status:

- Parser dispatch used to expose a transitional compiler path, several
  `compile*Program` helpers, and a token metadata scanner. The parser-first
  slices removed those successful dispatch paths by merging the former
  compatibility lowerer into `QuickParser`; unsupported syntax now reports
  through `syntax_error_guard`, and the dead parser path enum markers have been
  removed.
- Parser helpers used to inspect test262 metadata and source text such as
  `negative:`, `phase: parse`, `phase: runtime`, `sec-*`, `type:
  Test262Error`, and fixture prose to synthesize syntax or runtime outcomes.
  Those source-pattern pre-compilers are no longer called by parse dispatch.
- The emitter and VM used to include fixture-shaped opcodes and handlers for
  simple `for-in` concatenation, Array map multiplication, named construction,
  and named `instanceof`. The 2026-04-26 remaining-opcode cleanup removed those
  opcodes and now lowers through generic loop, closure/callback, constructor,
  and `instanceof` bytecode.
- VM helpers used to include private marker shortcuts for constructor and
  String wrapper state. The same cleanup removed those private markers. The
  follow-up native-function cleanup replaced function-looking string synthesis
  with function objects and changed VM helper unsupported failures to JS
  `TypeError`; unknown or malformed bytecode still uses `UnsupportedOpcode`.
- The parser also emitted value-level marker constants for `Math` and
  `globalThis`. The 2026-04-26 standard-global cleanup replaced those markers
  with ordinary global/property bytecode and current standard global object
  setup in `exec/call.zig`; `globalThis` identity is handled without creating a
  refcount self-cycle on the global object.

Repair progress: The first VM/domain extraction slice moved host global
callable setup, host-call dispatch, and output formatting from `exec/vm.zig`
into `exec/call.zig`; the focused exec gate now covers direct host callable
installation and invocation. The same slice replaced the VM `call` handler's
fixed 32-argument buffer with allocator-backed storage and added a 40-argument
call regression.

Parser dispatch repair progress: the former `SimpleParser` compatibility
lowerer was merged into `QuickParser`, parse entry no longer calls
metadata/source-pattern pre-compilers, and successful parses no longer use the
token metadata scanner or transitional fixture compiler. Frontend, aggregate,
smoke, and targeted expressions/statements/comments/line-terminators test262
slices passed after the migration.

Test262 helper opcode repair progress: `assert.sameValue(...)` now lowers to
ordinary global lookup, property lookup, and generic call bytecode, and `throw
new Test262Error(...)` now lowers to a generic call to the installed
`Test262Error` host callable. The former `assert_same_value` and
`throw_test262_error` VM dispatch opcodes and emitter helpers have been removed.

Native-function/error cleanup progress: Promise `then`/`catch`, collection
prototype-like method properties, and nested closure function display now use
function objects instead of synthesized strings. VM helper-level `Unsupported*`
errors now surface as `TypeError`; `UnsupportedOpcode` remains reserved for
unknown or malformed bytecode.

Standard-global cleanup progress: `Math` and `globalThis` no longer lower to
private marker constants. `frontend/parser.zig` emits ordinary global/property
access, `exec/call.zig` installs the current Math/JSON/native-constructor
globals, and `exec/property_ops.zig` returns retained global-object values for
`globalThis.globalThis` so VM property-result cleanup cannot destroy the global
root.

Remaining fixture opcode repair progress: the simple `for-in` concatenation,
Array map multiplication, named construction, and named `instanceof` opcode
families have been removed from emitter and VM dispatch. Supported source shapes
now use `object_keys` plus `for_in_next`, callback-backed `new_closure` plus
`array_method`, generic `new_function`/`construct`, and generic
`instanceof_value`; private constructor/String marker properties were removed in
favor of ordinary prototype links and object-owned String wrapper payloads.

JSON repair progress: `JSON.stringify` and `JSON.parse` lowering now runs
through `quickjs_parser`, and the narrow stringify/parse implementation moved
from `exec/vm.zig` into `builtins/json.zig`.

Math repair progress: supported `Math.<fn>` call lowering now runs through
`quickjs_parser`, `Math` is no longer blocked by the quick parser's legacy
domain-identifier fallback for those calls, and the narrow `math_call`
implementation moved from `exec/vm.zig` into `builtins/math.zig`.

URI repair progress: supported `encodeURI`, `encodeURIComponent`, `decodeURI`,
and `decodeURIComponent` calls now lower through `quickjs_parser`, the URI
global names are no longer blocked by the quick parser's legacy
domain-identifier fallback for those direct calls, and the narrow `uri_call`
implementation moved from `exec/vm.zig` into `builtins/uri.zig`.

Number parse repair progress: supported global `parseInt`/`parseFloat` and
`Number.parseInt`/`Number.parseFloat` calls now lower through `quickjs_parser`.
The VM `parse_int`/`parse_float` handlers now only collect operands and delegate
to `builtins/number.zig`, which owns supported string conversion, radix
ToInt32, prefix consumption, `Infinity`, `NaN`, and negative-zero behavior.

Date repair progress: supported `Date()` / `Date.UTC` / `Date.parse` /
`Date.now`, `new Date(...)`, and selected Date method calls now lower through
`quickjs_parser`. The VM Date opcode handlers now only collect operands and
delegate to `builtins/date.zig`, which owns the current narrow Date payload,
UTC math, supported parse strings, ISO/JSON formatting, and getter behavior.

RegExp repair progress: supported `new RegExp(pattern, flags)` and selected
RegExp instance method calls now lower through `quickjs_parser`. The VM
`new_regexp` / `regexp_method` handlers now only collect operands and delegate
to `builtins/regexp.zig`, which owns the current narrow RegExp object payload,
`toString`, `test`, and `exec` behavior. Nonstandard static `RegExp.test` /
`RegExp.exec` remain on the existing transitional TypeError path.

Promise repair progress: supported `new Promise(...)` and
`Promise.resolve` / `Promise.all` / `Promise.race` / `Promise.reject` calls now
lower through `quickjs_parser`. The VM `new_promise` / `promise_static`
handlers now only collect operands and delegate to `builtins/promise.zig`, which
owns the current narrow Promise object creation and static helper behavior while
preserving the existing unhandled-rejection exception-slot path.

Collection repair progress: supported `Map` / `Set` / `WeakMap` / `WeakSet`
construction and selected `set/get/has/delete/clear/add` prototype method calls
now lower through `quickjs_parser`. The VM `new_collection` handler only
collects constructor operands and delegates to `builtins/collection.zig`.
Strong collection storage is now object-owned and multi-entry, and weak
collections now store object identities rather than ordinary strong key
properties with an explicit sweep hook for the future GC pass. Collection method
calls lower through receiver-preserving `call_prop` and dispatch through native
function objects in `exec/call.zig`; the old collection-specific parser/VM
method opcode has been retired. VM-created collection instances now inherit the
registered `Map` / `Set` / `WeakMap` / `WeakSet` prototype methods instead of
defining method properties on each instance. Full iterable constructors,
iteration order, and automatic weak-collection GC scheduling remain explicit
future debt.

Capacity/OOM hardening progress: GC, shape, and job registries now keep backing
capacity so removal paths do not allocate and no longer use `catch unreachable`.
VM closure and array-method argument buffers are allocator-backed instead of
fixed four-slot arrays, and String.fromCharCode no longer has a hidden 64-item
limit. This does not finish the full capacity audit; stack/global/collection
growth still need broader failing-allocator coverage.

Buffer/DataView repair progress: supported `ArrayBuffer` construction/slicing,
narrow TypedArray shape creation, and `DataView` construction/get/set behavior
now live in `builtins/buffer.zig`. The VM buffer opcodes now only collect stack
operands and delegate to the builtin module while full TypedArray elements,
detachment, SharedArrayBuffer, and complete prototype descriptors remain future
debt.

String repair progress: supported `new String(...)`, `String.fromCharCode`,
`charAt`, and selected String prototype method behavior now live in
`builtins/string.zig`. The VM string opcodes now only collect stack operands and
delegate to the builtin module while full constructor/prototype descriptors,
Unicode-sensitive methods, and broader string integration remain future debt.

Object repair progress: supported object literal construction, Object.is
SameValue behavior, and Object.keys/values/entries array construction now live
in `builtins/object.zig`. The VM object helper opcodes now only decode operands
and delegate to the builtin module while full Object constructor/prototype
descriptors and ordinary property operation extraction remain future debt.

Array repair progress: supported array construction, `join`, callback-backed
`map`, and selected Array prototype method behavior now live in
`builtins/array.zig`. The VM `new_array`, `array_join`, and most `array_method`
handling now only collect operands and delegate to the builtin module, while
parser-side Array lowering, species, iteration, descriptors, sparse-array
completeness, and broader prototype semantics remain future debt.
Output-bound `forEachPrint` remains a transitional output adapter, now owned by
`exec/call.zig`.

VM semantic-helper extraction progress: value arithmetic/comparison/equality,
truthiness/type conversion, BigInt coercion/asN, property get/set/optional/index
access, `in`/`instanceof`, closure fixture state, test262 throw/assert helpers,
and output-bound Array `forEachPrint` now live outside `exec/vm.zig` in
`exec/value_ops.zig`, `exec/property_ops.zig`, `exec/closure.zig`,
`exec/test262_helpers.zig`, and `exec/call.zig`. VM dispatch now decodes
operands, manages stack/frame/global-slot glue, and maps helper errors for those
paths; narrow source-shape lowering and incomplete builtin/prototype domains
remain explicit transitional debt.

Root cause: The broad validation loop advanced before the parser-first semantic
architecture was complete. Passing local gates was treated as compatibility
evidence even though parts of the frontend and VM were still shaped around known
fixtures and selected test262 metadata.

Required repair direction: Replace source-string recognizers with
token-driven/parser-driven early errors and lowering. Move builtin/domain
semantics out of VM shortcut opcodes into shared object, property, call, and
builtin implementations. After AR closure, remaining narrow semantic work must
be explicit in follow-up queues and matrix status, not represented as alternate
successful parser paths.

Validation to close: Focused parser/emitter/VM regression slices exist for the
removed shortcut classes, and the AR closure gate requires `zig build test
--summary all`, `zig build smoke --summary all`, `git diff --check`, targeted
test262 slices for touched syntax or builtin domains, and the full local
test262 gate before claiming semantic completion beyond the AR boundary.

### EAL-20260427-004: Call Argument Cleanup Double-Free

Status: validated
Severity: high
Phase: WQ-015
Classification: zig_lifetime_bug

Summary: `call` and `call_prop` popped arguments into allocator-backed slices
with both an `errdefer` for partial stack-pop cleanup and a normal `defer` for
successful argument ownership. When a later callable lookup or native dispatch
returned `TypeError`, both defers ran and released the same string argument
values. The next bytecode constant teardown observed refcounts already at zero
and panicked.

Reproduction:

```bash
./zig-out/bin/zjs -e 'const obj = {}; obj.missing("a", "a");'
./zig-out/bin/zjs -e 'RegExp.test("a", "a");'
```

Fix: after stack-pop completion, the VM now disarms the partial-fill `errdefer`
and lets the normal argument-slice cleanup release each argument exactly once.
The same ownership shape was repaired across VM helpers that pop dynamic
argument/value slices.

Validation:

```bash
zig build test-exec --summary all
zig build test --summary all
zig build smoke --summary all
```

Current result: exec passes 58/58, aggregate passes 168/168, and smoke passes
45/45. The exec gate includes a regression for missing function calls and
unsupported `RegExp.test(...)` with evaluated string arguments.

Learning: stack-pop partial cleanup and post-pop call cleanup need separate
ownership states. Reusing one cursor for both is unsafe once later code can
return an error.

### EAL-20260427-005: Test262 Validation Claims Outpaced Parser Semantics

Status: open
Severity: high
Phase: WQ-012
Classification: parser_gap, builtin_gap, docs_tracking_gap

Summary: Current local unit/smoke gates pass, but broad `run-test262` execution
is not green. Focused reruns contradicted stale tracking entries that claimed
broad test262 success. The first repair slice added real host callables for
`assert`, `assert.throws`, `verifyProperty`, `verifyCallableProperty`, and
`isConstructor`, plus the frontend callback/property-call support needed by the
current global and Object.is tests. Those two targeted slices now pass. The
first Map crash was fixed separately by EAL-20260427-007, leaving collection
semantic gaps as the active blocker.

Reproduction:

```bash
./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/global 0 400
./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/Object/is 0 100000
./zig-out/bin/run-test262 -v -t 1 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/Map 0 20
```

Initial observed result on 2026-04-27: built-ins/global reported 29/29 errors,
Object/is reported 21/21 errors, Map reported 204/204 errors, and the root
sample reported 11/11 errors. The first verbose samples failed with
`SyntaxError`.

Current observed result on 2026-04-27: built-ins/global passes 0/29 errors,
Object/is passes 0/21 errors, and `built-ins/Map 0 21` passes 0/22 errors
after the first Map constructor/groupBy repairs. The wider
`built-ins/Map 0 60` tranche still reports 27/61 errors across iterator
closing, custom adder invocation, prototype descriptor, and `clear` receiver
semantics.

Scope: this is not fixed by adding known-error entries or restoring the removed
test262 metadata/source recognizers. The next repair needs real frontend support
for remaining harness/source syntax plus real collection semantics, then the
broader builtin slices can be used as semantic evidence again.

### EAL-20260427-006: Constructor Prototype Backlink Needs Cycle GC

Status: parked
Severity: high
Phase: WQ-012/WQ-014
Classification: zig_lifetime_bug, builtin_gap

Summary: The standard `Ctor.prototype.constructor === Ctor` descriptor cannot
be installed by a simple retained object edge while the runtime still relies on
refcount teardown without connected graph tracing. Adding that back-link in
`builtins/registry.zig` created the expected constructor/prototype object cycle
and caused teardown assertions during exec tests.

Reproduction:

```bash
# Add a retained data property from each registered prototype object back to its
# constructor value in builtins/registry.zig, then run:
zig build test-exec --summary all
```

Observed result on 2026-04-27: the standard back-link makes the registry more
descriptor-faithful, but object teardown no longer reaches zero because the
constructor and prototype retain each other. The attempted line was backed out
rather than hiding the leak or weakening teardown checks.

Scope: this is a WQ-014 dependency, not a descriptor helper typo. Constructor
and prototype back-links should be restored only after graph tracing/cycle
removal can mark, unlink, and finalize the standard builtin object graph.

### EAL-20260427-007: Object.defineProperty Returned Borrowed Target

Status: validated
Severity: high
Phase: WQ-012
Classification: zig_lifetime_bug, builtin_gap

Summary: `Object.defineProperty` returned `object.value()` for its target
without retaining it. VM call cleanup owns returned values, so a statement such
as `Object.defineProperty(Map.prototype, ...)` could drop the returned target
and release a live prototype object still reachable through the builtin
constructor graph. The focused Map test262 range crashed only when a later test
allocated after that corrupted teardown path.

Reproduction:

```bash
./zig-out/bin/run-test262 -v -t 1 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/Map 7 8
```

Observed result before the fix: `get-set-method-failure.js` reported
`TypeError`, then the next selected Map test crashed the runner with exit 139.

Fix: `callObjectStatic(..., "defineProperty", ...)` now returns
`object.value().dup()` after defining the property. The exec regression covers a
`Map.prototype` defineProperty call followed by ordinary `new Map()` and
`map.set(...)` use.

Validation:

```bash
zig build test-exec --summary all
./zig-out/bin/run-test262 -v -t 1 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/Map 0 20
```

Current result: exec passes 59/59 tests, the focused `built-ins/Map 0 21`
tranche passes 0/22 errors, and the wider `built-ins/Map 0 60` tranche remains
the active collection semantic blocker with 27/61 errors.

### EAL-20260427-008: Map Iterator Semantics Remain Separate From First GroupBy Tranche

Status: open
Severity: medium
Phase: WQ-012
Classification: builtin_gap, frontend_gap

Summary: The first Map tranche is now green, but expanding the same directory
shows the next real boundary: iterator protocol and prototype descriptor
semantics are still missing. The remaining failures include custom
`Map.prototype.set` invocation during construction, iterator close-on-error
paths, invalid iterator values, `new.target`, prototype descriptor checks, and
`Map.prototype.clear` receiver validation.

Reproduction:

```bash
./zig-out/bin/run-test262 -v -t 1 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/Map 0 60
```

Observed result on 2026-04-27: prepared 61/204 tests,
`Result: 27/61 errors, passed 34`.

Scope: do not mark Map semantic-complete based on the green 0..21 tranche.
The next repair should implement ordinary iterator protocol and callable
custom-adder dispatch rather than adding more one-off parser recognizers.

## Learning Log

| ID | Source | Lesson | Applies to | Enforcement |
|---|---|---|---|---|
| LRN-001 | prior zjs validation work | Start from a reproducing validation command, then repair from its output. | bugfixes, parity work, test262 work | README update rules and error workflow |
| LRN-002 | prior interrupted runs | Interrupted or partial sweeps are not final validation evidence. | smoke, compare, test262 | validation log and `interrupted_validation` classification |
| LRN-003 | EAL-20260426-003 | Broad green gates are not semantic-completion proof when parser or VM paths recognize source text, test metadata, or fixture-only shapes. | parser, emitter, VM, test262 validation | Architecture repair guardrails and `parse_path` tracking |
| LRN-003 | prior run-test262 work | Runner behavior must be checked against `quickjs/run-test262.c` and `quickjs/test262.conf` before changing engine semantics for excluded files. | Phase 8 and test262 triage | test262 parity matrix |
| LRN-004 | prior parity work | Requests for faithful QuickJS rewrite require source-aligned behavior, not small optimizations presented as parity. | all implementation phases | source mapping and matrix exit criteria |
| LRN-005 | prior runner performance work | Shared harness caches can add lock contention; prefer worker-local state unless evidence proves sharing is safe. | Phase 8 worker execution | test262 runner parity matrix |
| LRN-006 | prior broad-suite crashes | When a broad suite crashes, isolate the smallest file or subdirectory before editing semantics. | test262 triage, builtins, VM | error workflow reproduction step |
| LRN-007 | EAL-20260427-004 | Partial stack-pop cleanup must be disarmed before later fallible dispatch; otherwise normal cleanup and error cleanup can release the same values. | VM calls, constructors, variadic helpers | argument cleanup regression tests |
| LRN-008 | EAL-20260427-005 | Do not carry forward stale full-test262 claims after parser shortcut removal; rerun focused slices and record failures as blockers. | tracking, semantic queues, test262 validation | validation log plus open EAL record |
| LRN-009 | EAL-20260427-006 | Standard builtin graphs contain real cycles; do not install descriptor-faithful back-links as retained refcount edges until cycle GC owns them. | builtin registry, object graph ownership, GC | WQ-014 graph/cycle regression before `prototype.constructor` restoration |
| LRN-010 | EAL-20260427-007 | Builtins that return an existing object must return a retained value; borrowed returns are indistinguishable from owned values to VM call cleanup. | object builtins, collection prototypes, host call dispatch | retained-return regression tests for object-returning builtins |

## Open Questions

| ID | Question | Owner | Resolution path | Status |
|---|---|---|---|---|
| OQ-001 | Should detailed error records be one file per error from the start, or only after implementation begins? | redesign docs | Use inline index entries during planning; create files once code validation starts. | open |
