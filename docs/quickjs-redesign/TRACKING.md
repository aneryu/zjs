# QuickJS Redesign Tracking

Last updated: 2026-04-24

This file is the working ledger for the full QuickJS Zig redesign. It should be
updated alongside implementation, tests, and phase documents.

## Current Snapshot

| Field | Value |
|---|---|
| Active phase | Phase 8: CLI Tooling And Validation |
| Overall status | phase_8_in_progress |
| QuickJS semantic baseline | `64e64ebb1dd61505c256285a699c65c42941c5ed` |
| Current engine state | Phase 8 tooling is wired; `run-test262` now parses QuickJS-shaped args, config paths, feature lists, config excludes, direct selectors, and index spans, then runs selected tests through `zig-out/bin/zjs` with baseline harness prepended |
| Current build state | `build.zig` includes `qjs`, `run-test262`, `smoke`, `test-quickjs-port`, `test-core`, `test-bytecode`, `test-frontend`, `test-exec`, `test-builtins`, `test-tools`, and aggregate `test` |
| Current validation state | `zig build test --summary all` passed with 63/63 tests; `zig build test-tools --summary all` passed with 6/6 tests; `./zig-out/bin/zjs tests/zig-smoke/arith.js` prints `7`; `./zig-out/bin/run-test262 -v -c quickjs/test262.conf -d quickjs/test262/test/built-ins/JSON 0 9` reports `Result: 0/10 errors, passed 10`; `zig build smoke --summary all` still fails 44/45 scripts |
| Current learning state | Error and learning workflow initialized in `ERRORS_AND_LEARNINGS.md` |

## Phase Board

| Phase | Status | Phase doc | Matrix | Required next evidence |
|---|---|---|---|---|
| 1 Bootstrap And Source Baseline | completed | `phases/01-bootstrap-source-baseline.md` | none | Phase 2 runtime/context init-deinit gate |
| 2 Core Runtime Foundations | completed | `phases/02-core-runtime-foundations.md` | `matrices/core-runtime-invariants.md` | Phase 3 object/property gate |
| 3 Object And Property Semantics | completed | `phases/03-object-property-semantics.md` | `matrices/object-property-matrix.md` | Phase 4 opcode metadata gate |
| 4 Opcode And Bytecode Metadata | completed | `phases/04-opcode-bytecode-metadata.md` | `matrices/opcode-execution-matrix.md` | Phase 5 parser/emitter fixtures |
| 5 Frontend And Bytecode Emitter | completed | `phases/05-frontend-bytecode-emitter.md` | `matrices/frontend-coverage-matrix.md` | Phase 6 execution fixtures |
| 6 Bytecode Execution | completed | `phases/06-bytecode-execution.md` | `matrices/opcode-execution-matrix.md` | Phase 7 builtin/support library fixtures |
| 7 Builtins And Support Libraries | completed | `phases/07-builtins-support-libraries.md` | `matrices/builtins-support-matrix.md` | Phase 8 smoke/compare/test262 gates |
| 8 CLI Tooling And Validation | in_progress | `phases/08-cli-tooling-validation.md` | `matrices/test262-runner-parity.md` | Continue expression/object/call semantics after JSON test262 slice is visible and passing |

## Work Queue

| ID | Status | Phase | Scope | Next action | Blocker |
|---|---|---|---|---|---|
| WQ-001 | completed | 1 | Bootstrap source tree and build wiring | Created planned bootstrap tree and compiled bootstrap roots | none |
| WQ-002 | completed | 1 | Source/status metadata | Added source mapping and status tests | none |
| WQ-003 | completed | 2 | Core runtime foundations | Validated all Phase 2 matrix rows | none |
| WQ-004 | completed | 3 | Object and property semantics | Validated all Phase 3 matrix rows | none |
| WQ-005 | completed | 4 | Opcode and bytecode metadata | Validated opcode parser and bytecode ownership records | none |
| WQ-006 | completed | 5 | Frontend and bytecode emitter | Validated parser/emitter metadata fixtures without AST execution | none |
| WQ-007 | completed | 6 | Bytecode execution | Validated representative VM dispatch, Engine API, and job queue | none |
| WQ-008 | completed | 7 | Builtins and support libraries | Validated representative support libs and builtin domains | none |
| WQ-009 | in_progress | 8 | CLI and validation tooling | JSON test262 slice now executes through baseline harness; next fix smoke stdout/object/call semantics | smoke currently fails 44/45 scripts; broader test262 metadata/known-error/worker semantics remain incomplete |

## Subsystem Coverage Matrix

| Subsystem | Phase | Matrix | Status | Latest validation |
|---|---|---|---|---|
| Source baseline and status table | 1 | none | completed | `zig build test-quickjs-port --summary all` passed, 4/4 tests |
| Core runtime invariants | 2 | `matrices/core-runtime-invariants.md` | completed | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-core --summary all` passed, 21/21 tests |
| Object and property semantics | 3 | `matrices/object-property-matrix.md` | completed | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-core --summary all` passed, 31/31 tests |
| Opcode metadata | 4 | `matrices/opcode-execution-matrix.md` | completed | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-bytecode --summary all` passed, 5/5 tests |
| Frontend and bytecode emitter | 5 | `matrices/frontend-coverage-matrix.md` | completed | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-frontend --summary all` passed, 6/6 tests |
| Bytecode execution | 6 | `matrices/opcode-execution-matrix.md` | completed | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-exec --summary all` passed, 6/6 tests |
| Builtins and support libraries | 7 | `matrices/builtins-support-matrix.md` | completed | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-builtins --summary all` passed, 4/4 tests |
| CLI and validation tooling | 8 | `matrices/test262-runner-parity.md` | in_progress | `zig build test-tools --summary all` passed, 6/6 tests |

## Validation Log

| Date | Phase | Command | Exit | Result | Evidence type |
|---|---|---|---|---|---|
| 2026-04-24 | 1 | `zig build test-quickjs-port --summary all` | 1 | Baseline failed before implementation because `src/tests/quickjs_port.zig` did not exist | reproduction |
| 2026-04-24 | 1 | `zig build test-quickjs-port --summary all` | 0 | Bootstrap source/status tests passed, 4/4 tests | regression |
| 2026-04-24 | 2 | `zig build test-core --summary all` | 1 | First Phase 2 compile failed on duplicate QuickJS tag enum value and primitive-shadowing names | reproduction |
| 2026-04-24 | 2 | `zig build test-core --summary all` | 0 | Core foundation slice passed, 7/7 tests | regression |
| 2026-04-24 | 2 | `zig build test --summary all` | 0 | Aggregate bootstrap and core tests passed, 11/11 tests | regression |
| 2026-04-24 | 2 | `zig build test-core --summary all` | 0 | Atom table slice passed, 10/10 tests | regression |
| 2026-04-24 | 2 | `zig build test --summary all` | 0 | Aggregate bootstrap and core tests passed, 14/14 tests | regression |
| 2026-04-24 | 2 | `zig build test-core --summary all` | 0 | String storage slice passed with escalated Zig cache access, 13/13 tests | regression |
| 2026-04-24 | 2 | `zig build test --summary all` | 0 | Aggregate bootstrap and core tests passed with escalated Zig cache access, 17/17 tests | regression |
| 2026-04-24 | 2 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-core --summary all` | 0 | Class/shape slice passed, 15/15 tests | regression |
| 2026-04-24 | 2 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test --summary all` | 0 | Aggregate bootstrap and core tests passed, 19/19 tests | regression |
| 2026-04-24 | 2 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-core --summary all` | 0 | Completed Phase 2 core foundations passed, 21/21 tests | regression |
| 2026-04-24 | 2 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-quickjs-port --summary all` | 0 | Source/status tests passed after core runtime validation, 4/4 tests | regression |
| 2026-04-24 | 2 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test --summary all` | 0 | Aggregate bootstrap and core tests passed, 25/25 tests | regression |
| 2026-04-24 | 3 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-core --summary all` | 0 | First object/property slice passed, 29/29 tests | regression |
| 2026-04-24 | 3 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-quickjs-port --summary all` | 0 | Source/status tests passed after object_property status mapping, 4/4 tests | regression |
| 2026-04-24 | 3 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test --summary all` | 0 | Aggregate bootstrap and core tests passed, 33/33 tests | regression |
| 2026-04-24 | 3 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-core --summary all` | 0 | Completed Phase 3 object/property semantics passed, 31/31 tests | regression |
| 2026-04-24 | 3 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-quickjs-port --summary all` | 0 | Source/status tests passed after Phase 3 validation, 4/4 tests | regression |
| 2026-04-24 | 3 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test --summary all` | 0 | Aggregate bootstrap and core tests passed, 35/35 tests | regression |
| 2026-04-24 | 4 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-bytecode --summary all` | 0 | Opcode and bytecode metadata tests passed, 5/5 tests | regression |
| 2026-04-24 | 4 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-quickjs-port --summary all` | 0 | Source/status tests passed after Phase 4 validation, 4/4 tests | regression |
| 2026-04-24 | 4 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test --summary all` | 0 | Aggregate bootstrap, core, and bytecode tests passed, 40/40 tests | regression |
| 2026-04-24 | 5 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-frontend --summary all` | 0 | Frontend parser/emitter metadata tests passed, 6/6 tests | regression |
| 2026-04-24 | 5 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-quickjs-port --summary all` | 0 | Source/status tests passed after Phase 5 validation, 4/4 tests | regression |
| 2026-04-24 | 5 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test --summary all` | 0 | Aggregate bootstrap, core, bytecode, and frontend tests passed, 46/46 tests | regression |
| 2026-04-24 | 6 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-exec --summary all` | 0 | Bytecode execution tests passed, 6/6 tests | regression |
| 2026-04-24 | 6 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-quickjs-port --summary all` | 0 | Source/status tests passed after Phase 6 validation, 4/4 tests | regression |
| 2026-04-24 | 6 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test --summary all` | 0 | Aggregate bootstrap, core, bytecode, frontend, and exec tests passed, 52/52 tests | regression |
| 2026-04-24 | 7 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-builtins --summary all` | 0 | Builtins and support-library tests passed, 4/4 tests | regression |
| 2026-04-24 | 7 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-quickjs-port --summary all` | 0 | Source/status tests passed after Phase 7 validation, 4/4 tests | regression |
| 2026-04-24 | 7 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test --summary all` | 0 | Aggregate bootstrap, core, bytecode, frontend, exec, and builtins tests passed, 56/56 tests | regression |
| 2026-04-24 | 8 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test-tools --summary all` | 0 | CLI and validation tooling parser/helper tests passed, 4/4 tests | regression |
| 2026-04-24 | 8 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build qjs --summary all` | 0 | `zjs` executable built and installed | regression |
| 2026-04-24 | 8 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build run-test262 --summary all` | 0 | `run-test262` executable skeleton built and installed | regression |
| 2026-04-24 | 8 | `./zig-out/bin/zjs -e "1"` | 0 | `zjs -e` executes through rebuilt engine without output | smoke |
| 2026-04-24 | 8 | `./zig-out/bin/zjs <temp-file.js>` | 0 | `zjs <file.js>` executes through rebuilt engine without output | smoke |
| 2026-04-24 | 8 | `./zig-out/bin/zjs` | 2 | Usage path exits non-zero and prints `zjs -e <script>` / `zjs <file.js>` usage | smoke |
| 2026-04-24 | 8 | `./zig-out/bin/run-test262 -c quickjs/test262.conf -m -t 1 quickjs/test262/test` | 1 | CLI parser accepts QuickJS-shaped final gate args but execution is not implemented yet | reproduction |
| 2026-04-24 | 8 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build test --summary all` | 0 | Aggregate bootstrap, core, bytecode, frontend, exec, builtins, and tools tests passed, 60/60 tests | regression |
| 2026-04-24 | 8 | `ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build smoke --summary all` | 1 | Smoke runner is wired and compares manifest/goldens, but current engine fails 45/45 smoke scripts due missing output semantics | reproduction |
| 2026-04-24 | 8 | `zig build run-test262 --summary all` | 0 | `run-test262` builds after config/exclude/index selection prep | regression |
| 2026-04-24 | 8 | `zig build test-tools --summary all` | 0 | Tool tests passed after adding config text parsing and index span coverage, 6/6 tests | regression |
| 2026-04-24 | 8 | `./zig-out/bin/run-test262 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/JSON 0 5` | 1 | Runner prepared 6/165 JSON tests with harness and known-error paths; exits because JavaScript execution is not connected yet | reproduction |
| 2026-04-24 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after run-test262 selection prep, 60/60 tests | regression |
| 2026-04-24 | 8 | `zig build qjs --summary all` | 0 | `zjs` executable still builds after run-test262 selection prep | regression |
| 2026-04-24 | 8 | `zig build smoke --summary all` | 1 | Smoke remains the Phase 8 execution/output gap, 45/45 scripts failed | reproduction |
| 2026-04-24 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after run-test262 execution wiring, 62/62 tests | regression |
| 2026-04-24 | 8 | `zig build run-test262 --summary all` | 0 | `run-test262` builds after serial `zjs` execution wiring | regression |
| 2026-04-24 | 8 | `./zig-out/bin/run-test262 -v -c quickjs/test262.conf -d quickjs/test262/test/built-ins/JSON 0 2` | 1 | Runner executed 3 JSON tests through `zjs`; all 3 failed with uncaught exceptions | reproduction |
| 2026-04-24 | 8 | `zig build smoke --summary all` | 1 | Smoke still fails 45/45 scripts because `zjs` produces no expected stdout and a few syntax/runtime failures | reproduction |
| 2026-04-24 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after transitional print output wiring, 63/63 tests | regression |
| 2026-04-24 | 8 | `zig build qjs --summary all` | 0 | `zjs` builds after output sink and host print opcode wiring | regression |
| 2026-04-24 | 8 | `./zig-out/bin/zjs -e 'print(1); console.log("ok"); print(true); print(null); print(undefined)'` | 0 | Transitional host print path produced visible stdout for int, string, boolean, null, and undefined | smoke |
| 2026-04-24 | 8 | `zig build smoke --summary all` | 1 | Smoke still fails 45/45, but most scripts now produce non-empty stdout; remaining gap is expression/object/call semantics and syntax/runtime failures | reproduction |
| 2026-04-24 | 8 | `./zig-out/bin/run-test262 -v -c quickjs/test262.conf -d quickjs/test262/test/built-ins/JSON 0 2` | 1 | JSON slice still fails 3/3 with uncaught exceptions after print output wiring | reproduction |
| 2026-04-24 | 8 | `./zig-out/bin/zjs tests/zig-smoke/arith.js` | 0 | Smoke arithmetic script prints expected `7` after host print expression bytecode emission | smoke |
| 2026-04-24 | 8 | `./zig-out/bin/run-test262 -v -c quickjs/test262.conf -d quickjs/test262/test/built-ins/JSON 0 2` | 0 | JSON slice executes through rebuilt `zjs` and baseline harness, 3/3 passed | regression |
| 2026-04-24 | 8 | `./zig-out/bin/run-test262 -v -c quickjs/test262.conf -d quickjs/test262/test/built-ins/JSON 0 9` | 0 | Expanded JSON slice executes through rebuilt `zjs` and baseline harness, 10/10 passed | regression |
| 2026-04-24 | 8 | `zig build test-tools --summary all` | 0 | Tool tests passed after executable test262 slice repair, 6/6 tests | regression |
| 2026-04-24 | 8 | `zig build smoke --summary all` | 1 | Smoke still fails 44/45 scripts; `arith.js` now passes and `template.js` reaches stdout comparison | reproduction |
| 2026-04-24 | docs | `git diff --check -- QUICKJS_REDESIGN_PLAN.md docs/quickjs-redesign` | 0 | Root plan and redesign docs whitespace check passed | hygiene |
| 2026-04-24 | docs | `git diff --check -- QUICKJS_REDESIGN_PLAN.md docs/quickjs-redesign` | 0 | Matrix expansion and phase links whitespace check passed | hygiene |
| 2026-04-24 | docs | `git diff --check -- QUICKJS_REDESIGN_PLAN.md docs/quickjs-redesign` | 0 | Error and learning workflow whitespace check passed | hygiene |

## Decision Log

| Date | Decision | Reason | Follow-up |
|---|---|---|---|
| 2026-04-24 | Keep root plan as architecture contract and split execution details into `docs/quickjs-redesign/`. | The redesign will run for a long time and needs resumable records outside chat history. | Maintain `TRACKING.md` and active phase docs during implementation. |
| 2026-04-24 | Avoid `src/engine/quickjs/` nesting. | `src/engine/` is already the QuickJS engine namespace; explicit source mapping is clearer than redundant directory nesting. | Keep mapping table updated when files move or split. |
| 2026-04-24 | Track incomplete behavior through `status.zig` and phase docs. | A complete rewrite needs temporary gaps, but completed phases must not hide not-implemented behavior. | Phase tests should validate status transitions. |
| 2026-04-24 | Add a separate error and learning ledger. | Validation logs and known-failure summaries are not enough to preserve root causes and reusable lessons. | Use `ERRORS_AND_LEARNINGS.md` and `templates/error-record.md` for non-trivial failures. |
| 2026-04-24 | Wire Phase 8 smoke as a real golden comparator even before engine semantics pass. | A passing placeholder smoke step would hide the main remaining execution gap. | Keep `zig build smoke` failing until `zjs` produces expected script output. |

## Risk Log

| Risk | Impact | Mitigation | Status |
|---|---|---|---|
| Work drifts into a simplified interpreter instead of QuickJS parse-to-bytecode semantics. | Full test262 parity becomes unreachable. | Phase 5 forbids standalone AST execution and requires QuickJS source mapping. | open |
| Long-running validation gets interrupted but later treated as final proof. | False confidence in parity. | Validation entries must record exit status and mark interrupted sweeps explicitly. | open |
| Support libraries are postponed until builtin work. | RegExp, Unicode, BigInt, and number formatting semantics diverge. | Phase 7 ports `libs` before dependent builtins. | open |
| Stale `build.zig` roots hide deleted-code dependencies. | Redesign cannot build from clean state. | Phase 1 replaced build wiring with existing roots only. | mitigated |
| Phase 8 smoke is wired before the engine can execute smoke scripts fully. | `zig build smoke` fails until expression/object/call semantics catch up. | Transitional `print` output is wired; continue with expression and global-object semantics. | open |

## Known Failures

| Date | Phase | Command | Exit | Classification | Error record | Notes |
|---|---|---|---|---|---|---|
| 2026-04-24 | bootstrap | `zig build test-quickjs-port --summary all` | 1 | expected_bootstrap_gap | none | Failed before implementation because `src/tests/quickjs_port.zig` was missing; fixed by Phase 1 bootstrap. |
| 2026-04-24 | 8 | `zig build smoke --summary all` | 1 | expected_phase8_gap | pending | Smoke runner is real; current result is 44/45 scripts failed after `arith.js` began passing. |
| 2026-04-24 | 8 | `./zig-out/bin/run-test262 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/JSON 0 5` | 1 | expected_phase8_gap | pending | Earlier selection-only checkpoint; superseded by later `zjs` execution wiring, but still not a passing test262 result. |
| 2026-04-24 | 8 | `./zig-out/bin/run-test262 -v -c quickjs/test262.conf -d quickjs/test262/test/built-ins/JSON 0 2` | 1 | expected_phase8_gap | pending | Superseded by later passing JSON slices after baseline harness and template scanning repair. |

## Learning Summary

| Date | Source | Learning | Error record |
|---|---|---|---|
| 2026-04-24 | docs review | Non-trivial failures need durable root-cause records separate from validation logs. | `ERRORS_AND_LEARNINGS.md#eal-20260424-001-error-and-learning-workflow-missing` |

## Current Handoff

| Field | Value |
|---|---|
| Next recommended action | Fix the next smoke stdout mismatch and then expand test262 JSON beyond the first 10 files; keep metadata, known-error, and worker parity separate from engine semantic fixes. |
| Must not touch | Do not restore deleted `src/engine/vm/` or old AST interpreter paths. |
| Must update during work | Active phase checklist, work queue status, validation log, affected matrix rows, and error records for reusable failures. |
| Validation discipline | Record exact commands and exit status; keep interrupted sweeps separate from final evidence. |

## Handoff Notes

- Phase 1 bootstrap is complete.
- Phase 2 validates value tags, primitive predicates, runtime/context teardown, exception transfer, string refcounting, memory accounting, and intrusive list operations.
- Atom table slice validates QuickJS predefined atom ordering, tagged integer atoms, dynamic string interning, symbol uniqueness, and runtime teardown.
- String slice validates QuickJS-style UTF-8 decoding into 8-bit or 16-bit storage, code-unit comparison, hash calculation, atom-backed lifetime, and teardown.
- Class/shape slice validates QuickJS class IDs and registration, duplicate rejection, finalizer callbacks, context prototype slots, class-name atom lifetime, shape property atom lifetime, shape hash indexing, refcounts, and transition equality.
- Function/module/GC slice validates native, bytecode, and bound function records; module import/export metadata; runtime module list ownership; GC object list, zero-ref list, and mark placeholder plumbing; and runtime interrupt state.
- Phase 3 validates ordinary object allocation/free, descriptor invariants, accessor storage, prototype traversal and cycle checks, own-key order, extensibility, seal/freeze, array index boundaries, sparse length truncation, dense/sparse storage mode tracking, and exotic dispatch hook calls.
- Phase 4 validates opcode metadata by parsing the local QuickJS opcode header instead of duplicating a hand-maintained table, and validates bytecode buffer, constant pool, scope, module, and debug metadata ownership.
- Phase 5 validates tokenization, parser modes, source-positioned syntax errors, module/eval/function/class/private/destructuring/spread metadata, and emitter output without running bytecode.
- Phase 6 validates stack/frame ownership, representative primitive opcode dispatch, source location tracking, shared object property ops, context exception transfer, `Engine.eval`, and deterministic job queue draining.
- Phase 7 validates Unicode/dtoa/bignum/regexp support helpers, intrinsic bootstrap descriptors, representative builtin domains, Promise job integration, buffers, Reflect/Proxy hooks, iterator helpers, and Atomics lock-free scope.
- Phase 8 tooling now has `zjs`, `run-test262`, `smoke`, and `test-tools` build steps. Aggregate tests pass 63/63. `run-test262` can now show real targeted results: the JSON 0..9 slice passes 10/10 through rebuilt `zjs` with baseline harness prepended. `zig build smoke` still fails 44/45; remaining gaps are stdout semantics, object/call behavior, and unsupported runtime paths.
- Do not use old `src/engine/vm/` paths as repair targets.
- Use local QuickJS source and `quickjs/build/qjs` as semantic oracle once executable validation exists.
- Use `ERRORS_AND_LEARNINGS.md` for failures that need root-cause analysis or reusable lessons.
- Update this file before handing off a partially completed phase.
