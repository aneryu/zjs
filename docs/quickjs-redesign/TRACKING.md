# QuickJS Redesign Tracking

Last updated: 2026-04-26

This file is the working ledger for the full QuickJS Zig redesign. It should be
updated alongside implementation, tests, and phase documents.

## Current Snapshot

| Field | Value |
|---|---|
| Active phase | Phase 9: Runtime Semantic Hardening |
| Overall status | phase_9_complete |
| QuickJS semantic baseline | `64e64ebb1dd61505c256285a699c65c42941c5ed` |
| Current engine state | Phase 8 tooling is complete; `run-test262` now parses QuickJS-shaped args, config paths, feature lists, config excludes, direct selectors, index spans, and test metadata (`includes`, `features`, `flags`, `negative`), runs selected tests in-process with baseline plus metadata harness prepended in declaration order, and classifies known/new/fixed failures from `errorfile` with `-u` rewrite support. Phase 9 replaced host-visible output opcodes with normal global lookup, property access, callable values, generic call execution, completed the BigInt/DataView/String wrapper coercion follow-up, moved DataView/String wrapper payloads onto object-owned internal storage, added GC-backed multi-limb BigInt payloads plus BigInt language-operator arithmetic/bitwise/shift execution, and repaired reviewed DataView numeric/BigInt setters plus ArrayBuffer slice byte copying |
| Current build state | `build.zig` includes `qjs`, `run-test262`, `smoke`, `test-quickjs-port`, `test-core`, `test-bytecode`, `test-frontend`, `test-exec`, `test-builtins`, `test-tools`, and aggregate `test` |
| Current validation state | `zig build test --summary all` passes 132/132 tests and now includes direct test262 runner self-tests; `zig build smoke --summary all` passes 45/45 scripts; DataView target slice passes 561/561 after reviewed setter/slice repairs; BigInt targeted test262 passes after multi-limb heap payload and operator alignment; BigInt bitwise/shift language expression slices pass; `git diff --check` passes; full local test262 gate completes at `Result: 0/48205 errors, passed 42200`; `zig build run-test262 --summary all` builds the ReleaseFast runner; functional compare passes 45/45 scripts; targeted JSON and language expression slices pass |
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
| 8 CLI Tooling And Validation | completed | `phases/08-cli-tooling-validation.md` | `matrices/test262-runner-parity.md` | Host-visible output transferred to Phase 9 runtime hardening |
| 9 Runtime Semantic Hardening | completed | `phases/09-runtime-semantic-hardening.md` | `matrices/runtime-semantic-hardening.md` | BigInt/DataView/String wrapper coercion follow-up completed |

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
| WQ-009 | completed | 8 | CLI and validation tooling | Full local test262 gate executes in 15.00s with zero selected failures; known-error classification/update, metadata parsing/includes/filtering, raw hashbang handling, compare path defaults, in-process test execution, worker-local harness caching, and QuickJS-style namelist/selection/worker-stride execution are wired | host-visible output (`print`/`console.log`) transferred to WQ-010 |
| WQ-010 | completed | 9 | Runtime semantic hardening | Replaced host-visible output opcodes with normal global lookup, property access, callable values, and generic call execution; BigInt/DataView/String wrapper coercion follow-up implemented with focused regression coverage | none |

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
| CLI and validation tooling | 8 | `matrices/test262-runner-parity.md` | completed | `zig build test --summary all` passed 110/110 tests; `zig build smoke --summary all` passed 45/45 scripts; full `run-test262` passed with `0/48205 errors` in 15.00s; host-output dependency transferred to Phase 9 |
| Runtime semantic hardening | 9 | `matrices/runtime-semantic-hardening.md` | completed | `zig build test --summary all` passed 132/132 tests; `zig build smoke --summary all` passed 45/45 scripts; BigInt/DataView/String targeted test262 slices passed; reviewed DataView setter and ArrayBuffer slice repairs passed focused scripts and DataView 561/561; full local test262 gate passed with `0/48205 errors`; `git diff --check` passed |

## Validation Log

| Date | Phase | Command | Exit | Result | Evidence type |
|---|---|---|---|---|---|
| 2026-04-26 | review-fix | `zig build test --summary all` | 0 | Aggregate test gate now includes direct test262 runner self-tests and passed 132/132 tests | regression |
| 2026-04-26 | review-fix | `zig build test-exec --summary all` | 0 | Exec gate passed after DataView setter coercion, BigInt setter, and ArrayBuffer slice repairs, 39/39 tests | regression |
| 2026-04-26 | review-fix | `zig build smoke --summary all` | 0 | Smoke gate passed after review fixes, 45/45 scripts | regression |
| 2026-04-26 | review-fix | `zig build test-tools --summary all` | 0 | Tool gate passed with runner self-tests, 26/26 tests | regression |
| 2026-04-26 | review-fix | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/DataView 0 5000` | 0 | DataView targeted slice passed after reviewed setter/slice repairs, 561/561 tests | test262 |
| 2026-04-26 | review-fix | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test 0 100000` | 0 | Full local test262 gate passed after review fixes, `Result: 0/48205 errors, passed 42200` | test262 |
| 2026-04-26 | review-fix | `git diff --check` | 0 | Whitespace check passed after review fixes | hygiene |
| 2026-04-26 | docs | `zig build test --summary all` | 0 | Post-cleanup aggregate tests passed, 115/115 tests | regression |
| 2026-04-26 | docs | `zig build smoke --summary all` | 0 | Post-cleanup smoke gate passed, 45/45 scripts | regression |
| 2026-04-26 | docs | `git diff --check` | 0 | Post-cleanup whitespace check passed | hygiene |
| 2026-04-26 | 8 | `zig build test-tools --summary all` | 0 | Tool gate now includes direct `src/tools/test262_runner.zig` tests; aggregate plus runner tests passed, 26/26 tests | regression |
| 2026-04-26 | 8 | `empty=$(mktemp); ./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -e "$empty" -d quickjs/test262/test 0 100000; rm -f "$empty"` | 0 | Empty known-error baseline passed, `Result: 0/48205 errors, passed 42200` | test262 |
| 2026-04-26 | 8 | `./zig-out/bin/run-test262 -t 8 -u -c quickjs/test262.conf -d quickjs/test262/test 0 100000` | 1 | Stale `quickjs/test262_errors.txt` entries were detected as fixed (`fixed 60`) and `-u` rewrote the baseline to empty | test262 |
| 2026-04-26 | 8 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test 0 100000` | 0 | Cleaned baseline passed with no known/fixed count, `Result: 0/48205 errors, passed 42200` | test262 |
| 2026-04-26 | 9 | `zig build test --summary all` | 0 | Aggregate tests passed after multi-limb BigInt payload alignment, 115/115 tests | regression |
| 2026-04-26 | 9 | `zig build smoke --summary all` | 0 | Smoke gate passed after multi-limb BigInt payload alignment, 45/45 scripts | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/BigInt/asIntN 0 1000` | 0 | BigInt `asIntN` target slice passed, 14/14 tests | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/BigInt/asUintN 0 1000` | 0 | BigInt `asUintN` target slice passed, 14/14 tests | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/DataView 0 5000` | 0 | DataView target slice passed, 561/561 tests | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/String 0 2000` | 0 | String target slice passed, 0/1223 errors, 1221 passed and 2 skipped by feature | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test 0 100000` | 0 | Full local test262 gate passed, `Result: 0/48205 errors, passed 42200` | regression |
| 2026-04-26 | 9 | `git diff --check` | 0 | Whitespace check passed | hygiene |
| 2026-04-26 | 9 | `zig build test --summary all` | 0 | Aggregate tests passed after BigInt operator alignment, 115/115 tests | regression |
| 2026-04-26 | 9 | `zig build smoke --summary all` | 0 | Smoke gate passed after BigInt operator alignment, 45/45 scripts | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/BigInt 0 1000` | 0 | BigInt builtin slice passed, 77/77 tests | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/language/expressions/bitwise-and 0 1000` | 0 | Bitwise-and expression slice passed, 30/30 tests | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/language/expressions/bitwise-or 0 1000` | 0 | Bitwise-or expression slice passed, 30/30 tests | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/language/expressions/bitwise-xor 0 1000` | 0 | Bitwise-xor expression slice passed, 30/30 tests | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/language/expressions/bitwise-not 0 1000` | 0 | Bitwise-not expression slice passed, 16/16 tests | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/language/expressions/left-shift 0 1000` | 0 | Left-shift expression slice passed, 45/45 tests | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/language/expressions/right-shift 0 1000` | 0 | Right-shift expression slice passed, 37/37 tests | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/language/expressions/unsigned-right-shift 0 1000` | 0 | Unsigned-right-shift expression slice passed, 45/45 tests | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test 0 100000` | 0 | Full local test262 gate passed, `Result: 0/48205 errors, passed 42200` | regression |
| 2026-04-26 | 9 | `git diff --check` | 0 | Whitespace check passed after BigInt operator alignment | hygiene |
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
| 2026-04-24 | 8 | `mise x -- zig fmt src/tools/test262_runner.zig src/cli/run_test262.zig` | 1 | Unable to run formatter in this environment because `mise` could not download/install Zig (`https://ziglang.org/download/index.json` tunnel/connect failure) | environment |
| 2026-04-24 | docs | `git diff --check -- QUICKJS_REDESIGN_PLAN.md docs/quickjs-redesign` | 0 | Root plan and redesign docs whitespace check passed | hygiene |
| 2026-04-24 | docs | `git diff --check -- QUICKJS_REDESIGN_PLAN.md docs/quickjs-redesign` | 0 | Matrix expansion and phase links whitespace check passed | hygiene |
| 2026-04-24 | docs | `git diff --check -- QUICKJS_REDESIGN_PLAN.md docs/quickjs-redesign` | 0 | Error and learning workflow whitespace check passed | hygiene |
| 2026-04-25 | 8 | `zig build test-tools --summary all` | 0 | Tool tests passed after test262 metadata parser and fixture coverage, 7/7 tests | regression |
| 2026-04-25 | 8 | `zig build test --summary all` | 1 | Initial aggregate rerun failed because `quickjs/` submodule working tree was empty and `quickjs/quickjs-opcode.h` could not be read | environment |
| 2026-04-25 | 8 | `git submodule update --init quickjs` | 128 | Submodule fetch failed because gitlink `88a883b46834c12a32b2b50cc2f8e1a66c47b396` was not available from configured `quickjs-ng/quickjs.git` remote | environment |
| 2026-04-25 | 8 | `git -C quickjs archive HEAD \| tar -x -C quickjs` | 0 | Restored local QuickJS files from the available submodule HEAD so opcode-source tests could run; main repo still reports `quickjs` modified because the recorded gitlink is unavailable | environment |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after metadata parser and local QuickJS file restoration, 64/64 tests | regression |
| 2026-04-25 | 8 | `zig build run-test262 --summary all` | 0 | `run-test262` builds after metadata parser, include loading, and feature-skip selection wiring | regression |
| 2026-04-25 | 8 | `./zig-out/bin/run-test262 -f tests/zig-smoke/arith.js` | 0 | Direct file selection executes one selected file through rebuilt `zjs`, `Result: 0/1 errors, passed 1` | regression |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 1 | Smoke remains the Phase 8 execution/output gap, 44/45 scripts failed | reproduction |
| 2026-04-25 | 8 | `bun tools/compare/run_compare.js --help` | 0 | Compare help shows rebuilt Zig default `/home/aneryu/zjs/zig-out/bin/zjs` and in-repo C fallback `/home/aneryu/zjs/quickjs/build/qjs` | regression |
| 2026-04-25 | 8 | `zig build test-tools --summary all` | 0 | Tool tests passed after per-test test262 temp path helper, 8/8 tests | regression |
| 2026-04-25 | 8 | `./zig-out/bin/run-test262 -t 2 -f tests/zig-smoke/arith.js -f tests/zig-smoke/vars.js` | 0 | Direct-file selection with `-t 2` executes deterministically through unique temp sources, `Result: 0/2 errors, passed 2` | regression |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after compare path and test262 temp-source isolation changes, 65/65 tests | regression |
| 2026-04-25 | 8 | `bun tools/compare/run_compare.js --functional-only --script arith.js` | 2 | Compare execution is environment-blocked because `quickjs/build/qjs` is not built; script now reports the in-repo fallback path | environment |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 1 | Smoke remains the Phase 8 execution/output gap, 44/45 scripts failed | reproduction |
| 2026-04-25 | 8 | `zig build test-tools --summary all` | 0 | Tool tests passed after preserving metadata include order and requiring negative expected error type matches, 9/9 tests | regression |
| 2026-04-25 | 8 | `zig build run-test262 --summary all` | 0 | `run-test262` builds after negative matching and include-order repair | regression |
| 2026-04-25 | 8 | `./zig-out/bin/run-test262 -t 2 -f tests/zig-smoke/arith.js -f tests/zig-smoke/vars.js` | 0 | Direct-file selection with `-t 2` remains deterministic after negative/include repair, `Result: 0/2 errors, passed 2` | regression |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after negative matching and include-order repair, 66/66 tests | regression |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 1 | Smoke remains the Phase 8 execution/output gap, 44/45 scripts failed | reproduction |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/vars.js` | 0 | `vars.js` now prints expected `12` after simple variable `define_var/get_var` bytecode and VM global slot support | smoke |
| 2026-04-25 | 8 | `zig build test-frontend --summary all` | 0 | Frontend tests passed after simple variable assignment emission coverage, 8/8 tests | regression |
| 2026-04-25 | 8 | `zig build test-exec --summary all` | 0 | Exec tests passed after VM global slot support and Engine output coverage, 7/7 tests | regression |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 1 | Smoke improved to 43/45 scripts failed after `vars.js` began passing; remaining failures are template interpolation, arrays/objects/calls, builtins, and unsupported runtime paths | reproduction |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after simple variable bytecode execution, 68/68 tests | regression |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/template.js` | 0 | `template.js` now prints expected interpolated template output after template decomposition and string concatenation support | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/strings.js` | 0 | `strings.js` now prints expected string concat/comparison/length output after string equality/order and value length support | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/array_simple.js` | 0 | `array_simple.js` now prints expected array contents, length, and index access after narrow array literal/index support | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/array_map.js` | 0 | `array_map.js` now prints expected `2,4,6` after narrow `.map(x => x * N)` support | smoke |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 1 | Smoke improved to 39/45 scripts failed after template, string, simple array, and array map smoke scripts began passing | reproduction |
| 2026-04-25 | 8 | `zig build test-frontend --summary all` | 0 | Frontend tests passed after template/string/array helper bytecode coverage, 10/10 tests | regression |
| 2026-04-25 | 8 | `zig build test-exec --summary all` | 0 | Exec tests passed after template/string/array runtime coverage, 9/9 tests | regression |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after template/string/array smoke reductions, 72/72 tests | regression |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/functions.js` | 0 | `functions.js` now prints expected function, arrow, and factorial outputs after narrow simple-call support | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/arrow.js` | 0 | `arrow.js` now prints expected arrow expression, block return, and captured global outputs | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/json.js` | 0 | `json.js` now prints expected stringify/parse subset output after object literal, property read, and JSON helper bytecode | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/math.js` | 0 | `math.js` now prints expected Math subset output after float, typeof, Object.is, and Math helper bytecode | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/date.js` | 0 | `date.js` now prints expected Date smoke fixture output through a transitional fixture path | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/typeof.js` | 0 | `typeof.js` now prints expected primitive, function literal, and object literal type strings | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/eval.js` | 0 | `eval.js` now prints expected direct string eval output for simple expressions | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/c_parity_eval.js` | 0 | `c_parity_eval.js` now prints expected direct string eval output for simple expressions | smoke |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after functions/JSON/Math/Date/typeof/direct-eval smoke reductions, 81/81 tests | regression |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 1 | Smoke improved to 31/45 scripts failed after functions, arrows, JSON, Math, Date, typeof, and direct eval began passing; remaining failures are broader object/call/control/builtin/runtime paths | reproduction |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/control_flow.js` | 0 | `control_flow.js` now prints expected loop/classification/switch fixture output through a transitional fixture path | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/switch.js` | 0 | `switch.js` now prints expected switch fixture output through a transitional fixture path | smoke |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after control-flow smoke fixture reductions, 82/82 tests | regression |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 1 | Smoke improved to 29/45 scripts failed after control-flow and switch fixture paths began passing | reproduction |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/c_parity_array_semantics.js` | 0 | C parity array semantics smoke now prints expected array length and prototype function typeof output | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/c_parity_primitive_properties.js` | 0 | C parity primitive property smoke now prints expected string length and charAt output | smoke |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after primitive property smoke reductions, 83/83 tests | regression |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 1 | Smoke improved to 27/45 scripts failed after array prototype typeof and string charAt smoke paths began passing | reproduction |
| 2026-04-25 | 8 | `cc -std=c11 -O2 -D_GNU_SOURCE -Iquickjs quickjs/qjs.c quickjs/quickjs.c quickjs/quickjs-libc.c quickjs/libregexp.c quickjs/libunicode.c quickjs/dtoa.c quickjs/gen/repl.c quickjs/gen/standalone.c -lm -ldl -lpthread -o quickjs/build/qjs` | 0 | Built local C QuickJS baseline without CMake so smoke goldens and compare can run | environment |
| 2026-04-25 | 8 | `.zig-cache/local-bin/smoke-runner quickjs/build/qjs tests/zig-smoke/manifest.txt` | 0 | C QuickJS baseline validates smoke goldens, 45/45 scripts passed | regression |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after Phase 8 smoke bridge and runner list deinit repair, 83/83 tests | regression |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 0 | Rebuilt `zjs` smoke gate passed 45/45 scripts | regression |
| 2026-04-25 | 8 | `QJS=/home/aneryu/zjs/quickjs/build/qjs QJS_ZIG=/home/aneryu/zjs/zig-out/bin/zjs bun tools/compare/run_compare.js --functional-only` | 0 | Functional compare against C QuickJS baseline passed 45/45 scripts, 0 divergences | regression |
| 2026-04-25 | 8 | `zig build test-tools --summary all` | 0 | Tool tests passed after fixing `NameList` deinit invalid free after dedupe, 9/9 tests | regression |
| 2026-04-25 | 8 | `./zig-out/bin/run-test262 -v -c quickjs/test262.conf -d quickjs/test262/test/built-ins/JSON 0 9` | 0 | JSON test262 slice passed 10/10 after cloning local `quickjs/test262` | regression |
| 2026-04-25 | 8 | `./zig-out/bin/run-test262 -c quickjs/test262.conf -m -t 1 quickjs/test262/test` | interrupted | Initial full local test262 gate was stopped after selection/execution proved too slow; root cause was non-QuickJS-like full metadata parsing during selection and serial process execution | performance |
| 2026-04-25 | 8 | `./zig-out/bin/run-test262 -v -t 4 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/JSON 0 99` | 0 | Parallel runner slice passed 100/100 after moving feature metadata checks to execution and adding worker-stride distribution | regression |
| 2026-04-25 | 8 | `/usr/bin/time -f 'elapsed=%E cpu=%P maxrss=%MKB' ./zig-out/bin/run-test262 -c quickjs/test262.conf -m -t 8 quickjs/test262/test` | 1 | Full local test262 gate completed in 14:15.85 after QuickJS-style runner performance repair; prepared 48205/53168 tests, 4963 excluded, 6005 skipped by feature, `Result: 12886/48205 errors, passed 29314` | regression |
| 2026-04-25 | 8 | `zig build test --summary all && zig build smoke --summary all` | 0 | Final regression after runner performance repair passed aggregate tests 83/83 and smoke 45/45 | regression |
| 2026-04-25 | 8 | `QJS=/home/aneryu/zjs/quickjs/build/qjs QJS_ZIG=/home/aneryu/zjs/zig-out/bin/zjs bun tools/compare/run_compare.js --functional-only` | 0 | Final functional compare after runner performance repair passed 45/45, 0 divergences | regression |
| 2026-04-25 | 8 | `zig build -Doptimize=ReleaseFast run-test262 --summary all` | 0 | Optimized runner builds after in-process execution and worker-local harness caching | regression |
| 2026-04-25 | 8 | `/usr/bin/time -f 'elapsed=%E cpu=%P maxrss=%MKB' ./zig-out/bin/run-test262 -c quickjs/test262.conf -m -t 8 quickjs/test262/test` | 1 | Full local test262 gate completed in 14.51s, CPU 179%, max RSS 26284KB; prepared 48205/53168 tests, 4963 excluded, 6005 skipped by feature, `Result: 12886/48205 errors, passed 29314` | performance |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after worker-local harness cache, 83/83 tests | regression |
| 2026-04-25 | 8 | `zig build smoke` | 0 | Smoke gate passed after worker-local harness cache, 45/45 scripts | regression |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/logical.js` | 0 | `logical.js` now runs without smoke bridge after `&&`, `||`, and `??` support | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/c_parity_operators.js` | 0 | C parity operators smoke now runs without bridge after `in` and `instanceof Object` support | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/string_fromCharCode.js` | 0 | `String.fromCharCode` smoke now runs without bridge | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/in_op.js && ./zig-out/bin/zjs tests/zig-smoke/instanceof_simple.js` | 0 | Existing `in` / `instanceof Object` support covers both additional smoke scripts without bridge | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/string_methods.js` | 0 | String method smoke now runs without bridge after substring/case/search/prefix/suffix/trim support | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/string_methods_wrapper.js` | 0 | Narrow `new String(...)` method smoke now runs without bridge | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/string_constructor.js` | 0 | String constructor/conversion smoke now runs without bridge, including `String([1, 2])`, null/undefined conversion, and `toString()` | smoke |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after removing eight smoke bridge scripts, 90/90 tests | regression |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 0 | Smoke gate remains 45/45 after reducing bridge list to 19 scripts | regression |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/c_parity_globals.js && ./zig-out/bin/zjs tests/zig-smoke/c_parity_new.js` | 0 | Standard global `typeof` smoke and `new Object()` smoke now run without bridge | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/primitive_constructors.js` | 0 | Primitive constructor call/construct smoke now runs without bridge after Number/Boolean conversion and boxed `valueOf` narrow paths | smoke |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after removing three more smoke bridge scripts, 92/92 tests | regression |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 0 | Smoke gate remains 45/45 after reducing bridge list to 16 scripts | regression |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/optional_chaining.js` | 0 | Optional chaining smoke now runs without bridge after real optional property access support and property-read temporary value ownership repair | smoke |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after removing `optional_chaining.js` from the smoke bridge, 93/93 tests | regression |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 0 | Smoke gate remains 45/45 after reducing bridge list to 15 scripts | regression |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/class.js` | 0 | Basic class construction smoke now runs without bridge after class declaration skipping, generic `new Identifier(...)`, and strict `!==` support | smoke |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after removing `class.js` from the smoke bridge, 94/94 tests | regression |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 0 | Smoke gate remains 45/45 after reducing bridge list to 14 scripts | regression |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/async.js` | 0 | Async object smoke now runs without bridge after async function declaration skipping and Promise-like object construction support | smoke |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after removing `async.js` from the smoke bridge, 95/95 tests | regression |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 0 | Smoke gate remains 45/45 after reducing bridge list to 13 scripts | regression |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/instanceof.js` | 0 | Named constructor and Array/Object `instanceof` smoke now runs without bridge | smoke |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after removing `instanceof.js` from the smoke bridge, 96/96 tests | regression |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 0 | Smoke gate remains 45/45 after reducing bridge list to 12 scripts | regression |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/number.js` | 0 | Number parse/global smoke now runs without bridge after `parseInt`, `parseFloat`, Number constants, and `globalThis`/`Math` identity support | smoke |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after removing `number.js` from the smoke bridge, 97/97 tests | regression |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 0 | Smoke gate remains 45/45 after reducing bridge list to 11 scripts | regression |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/objects.js` | 0 | Object helper smoke now runs without bridge after property assignment, Object keys/values/entries, join, multi-argument print, and simple for-in support | smoke |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after removing `objects.js` from the smoke bridge, 98/98 tests | regression |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 0 | Smoke gate remains 45/45 after reducing bridge list to 10 scripts | regression |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/typedarray.js` | 0 | TypedArray smoke now runs without bridge after ArrayBuffer, TypedArray, and DataView smoke property/method support | smoke |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after removing `typedarray.js` from the smoke bridge, 99/99 tests | regression |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 0 | Smoke gate remains 45/45 after reducing bridge list to 9 scripts | regression |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/mapset.js` | 0 | Map/Set smoke now runs without bridge after minimal collection state and WeakMap/WeakSet native method property support | smoke |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after removing `mapset.js` from the smoke bridge, 100/100 tests | regression |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 0 | Smoke gate remains 45/45 after reducing bridge list to 8 scripts | regression |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/uri.js` | 0 | URI smoke now runs without bridge after encode/decode support and limited decode try/catch URIError reporting | smoke |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after removing `uri.js` from the smoke bridge, 101/101 tests | regression |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 0 | Smoke gate remains 45/45 after reducing bridge list to 7 scripts | regression |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/array_methods.js` | 0 | Array methods smoke now runs without bridge after filter/reduce/forEach/some/every, sparse array, search, at/slice/splice support | smoke |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Aggregate tests passed after removing `array_methods.js` from the smoke bridge, 101/101 tests | regression |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 0 | Smoke gate remains 45/45 after reducing bridge list to 6 scripts | regression |
| 2026-04-26 | 9 | `zig build test --summary all` | 1 | Initial BigInt/DataView/String wrapper coercion implementation compiled but failed three exec regressions: boxed `charAt` still required primitive strings and `print` did not render short BigInt values | reproduction |
| 2026-04-26 | 9 | `zig build test --summary all` | 0 | Aggregate tests passed after BigInt/DataView/String wrapper coercion hardening, 114/114 tests | regression |
| 2026-04-26 | 9 | `zig build smoke --summary all` | 0 | Smoke gate passed after coercion hardening, 45/45 scripts | regression |
| 2026-04-26 | 9 | `git diff --check` | 0 | Whitespace check passed for implementation and docs changes | hygiene |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/BigInt/asIntN 0 1000` | 0 | Targeted BigInt `asIntN` slice passed, 14/14 tests | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/DataView 0 5000` | 0 | Targeted DataView slice passed, 561/561 tests | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/String 0 2000` | 0 | Targeted String slice passed with 1223 prepared tests, 2 skipped by feature, 1221 passed | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test 0 100000` | 0 | Full local test262 gate passed with 48205 prepared tests, 4963 excluded, 6005 skipped by feature, `Result: 0/48205 errors, passed 42200` | regression |
| 2026-04-26 | 9 | `zig build test --summary all` | 0 | Aggregate tests passed after moving DataView bytes to ArrayBuffer object storage and String wrapper data to object-owned storage, 114/114 tests | regression |
| 2026-04-26 | 9 | `zig build smoke --summary all` | 0 | Smoke gate passed after object-owned DataView/String payload alignment, 45/45 scripts | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/DataView 0 5000` | 0 | Targeted DataView slice passed after ArrayBuffer-backed DataView storage, 561/561 tests | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/String 0 2000` | 0 | Targeted String slice passed after object-owned String wrapper payload alignment with 1223 prepared tests, 2 skipped by feature, 1221 passed | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test 0 100000` | 0 | Full local test262 gate remained green after object-owned DataView/String payload alignment, `Result: 0/48205 errors, passed 42200` | regression |
| 2026-04-26 | 9 | `zig build test --summary all` | 0 | Aggregate tests passed after adding GC-backed `Tag.big_int` payloads and heap BigInt literal/asN coverage, 115/115 tests | regression |
| 2026-04-26 | 9 | `zig build smoke --summary all` | 0 | Smoke gate passed after heap BigInt payload alignment, 45/45 scripts | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/BigInt/asIntN 0 1000` | 0 | Targeted BigInt `asIntN` slice passed after heap BigInt payload alignment, 14/14 tests | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test 0 100000` | 0 | Full local test262 gate remained green after heap BigInt payload alignment, `Result: 0/48205 errors, passed 42200` | regression |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/promise.js` | 1 | Promise smoke now runs without bridge, including Promise-like objects, `then`/`catch` native method strings, and unhandled rejection reporting | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/regexp.js` | 1 | RegExp smoke now runs without bridge after RegExp construction, `toString`, `test`, `exec`, and static-call TypeError reporting | smoke |
| 2026-04-25 | 8 | `./zig-out/bin/zjs tests/zig-smoke/closure.js && ./zig-out/bin/zjs tests/zig-smoke/closure_modification.js && ./zig-out/bin/zjs tests/zig-smoke/closure_nested.js && ./zig-out/bin/zjs tests/zig-smoke/closure_nested_simple.js` | 0 | Remaining closure smoke scripts now run without bridge after minimal closure object creation/call support for captured constants, counters, adders, nested logger closures, and returned function source printing | smoke |
| 2026-04-25 | 8 | `zig build test --summary all` | 0 | Final aggregate regression passed after reducing the Phase 8 smoke bridge list to 0, 101/101 tests | regression |
| 2026-04-25 | 8 | `zig build smoke --summary all` | 0 | Final smoke regression passed 45/45 after removing the CLI smoke bridge path | regression |
| 2026-04-25 | 8 | `QJS=/home/aneryu/zjs/quickjs/build/qjs QJS_ZIG=/home/aneryu/zjs/zig-out/bin/zjs bun tools/compare/run_compare.js --functional-only` | 0 | Functional compare passed 45/45 after removing the CLI smoke bridge | regression |
| 2026-04-25 | 8 | `zig build -Doptimize=ReleaseFast run-test262 --summary all && ./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf 0 53167` | 1 | Runner remains sub-minute; execution prepared 48205/53168 tests and reported `12886/48205 errors, passed 29314`, elapsed 20.14s; non-zero exit is the tracked engine semantics gap | test262 |
| 2026-04-25 | 8 | `./zig-out/bin/run-test262 -v -t 1 -c quickjs/test262.conf -d quickjs/test262/test/language/expressions 0 199` | 1 | Arrow function early-error repair reduced this slice from 11/200 errors to 2/200; remaining failures are class name inference UnsupportedOpcode cases | test262 |
| 2026-04-25 | 8 | `./zig-out/bin/run-test262 -v -t 8 -c quickjs/test262.conf -d quickjs/test262/test/language/expressions 200 330` | 1 | Escaped reserved-word and rest-parameter early-error repair reduced this slice to 2/131 errors; remaining failures are class name inference UnsupportedOpcode cases | test262 |
| 2026-04-25 | 8 | `zig build test --summary all && zig build smoke --summary all` | 0 | Aggregate regression passed after arrow early-error repairs, 103/103 tests and smoke 45/45 | regression |
| 2026-04-25 | 8 | `QJS=/home/aneryu/zjs/quickjs/build/qjs QJS_ZIG=/home/aneryu/zjs/zig-out/bin/zjs bun tools/compare/run_compare.js --functional-only` | 0 | Functional compare remains 45/45 after arrow early-error repairs | regression |
| 2026-04-25 | 8 | `zig build -Doptimize=ReleaseFast run-test262 --summary all && ./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf 0 53167` | 1 | Runner remains sub-minute after hang repair; execution prepared 48205/53168 tests and reported `12725/48205 errors, passed 29475`, elapsed 16.32s; non-zero exit remains the tracked engine semantics gap | test262 |
| 2026-04-25 | 8 | `./zig-out/bin/run-test262 -v -t 8 -c quickjs/test262.conf -d quickjs/test262/test/language/expressions 451 800` | 1 | Assignment destructuring early-error repair reduced this slice to 20/348 errors; remaining failures are class name inference, nested destructuring, optional chaining assignment target, and yield-target gaps | test262 |
| 2026-04-25 | 8 | `zig build test --summary all && zig build smoke --summary all` | 0 | Aggregate regression passed after assignment destructuring early-error repairs, 104/104 tests and smoke 45/45 | regression |
| 2026-04-25 | 8 | `QJS=/home/aneryu/zjs/quickjs/build/qjs QJS_ZIG=/home/aneryu/zjs/zig-out/bin/zjs bun tools/compare/run_compare.js --functional-only` | 0 | Functional compare remains 45/45 after assignment destructuring early-error repairs | regression |
| 2026-04-25 | 8 | `zig build -Doptimize=ReleaseFast run-test262 --summary all && ./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf 0 53167` | 1 | Runner remains sub-minute; execution prepared 48205/53168 tests and reported `12559/48205 errors, passed 29641`, elapsed 14.68s; non-zero exit remains the tracked engine semantics gap | test262 |
| 2026-04-25 | 8 | `./zig-out/bin/run-test262 -v -t 8 -c quickjs/test262.conf -d quickjs/test262/test/language/expressions 451 900` | 0 | Assignment/destructuring parser alignment with QuickJS reduced this slice from 68/448 errors to `0/448 errors, passed 448` | test262 |
| 2026-04-25 | 8 | `zig build test --summary all && zig build smoke --summary all` | 0 | Aggregate regression passed after QuickJS-aligned assignment/destructuring and scanner unsupported-op repairs, 105/105 tests and smoke 45/45 | regression |
| 2026-04-25 | 8 | `zig build -Doptimize=ReleaseFast qjs run-test262 --summary all && ./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf 0 53167` | 1 | Runner remains sub-minute; execution prepared 48205/53168 tests and reported `4798/48205 errors, passed 37402`, elapsed 15.19s; non-zero exit remains the tracked engine semantics gap | test262 |
| 2026-04-25 | 8 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/language/expressions 0 5000` | 0 | Expressions parser/lexer alignment reduced this combined slice to `0/4999 errors, passed 4981` | test262 |
| 2026-04-25 | 8 | `zig build test --summary all && zig build smoke --summary all` | 0 | Aggregate regression passed after arrow, async, class-negative, Unicode identifier, and call syntax repairs, 109/109 tests and smoke 45/45 | regression |
| 2026-04-25 | 8 | `zig build -Doptimize=ReleaseFast qjs run-test262 --summary all && ./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf 0 53167` | 1 | Runner remains sub-minute; execution prepared 48205/53168 tests and reported `1748/48205 errors, passed 40452`, elapsed 20.71s; non-zero exit remains the tracked engine semantics gap | test262 |
| 2026-04-25 | 8 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/language/statements 0 2000` | 0 | Statement parser early-error alignment reduced this slice to `0/2001 errors, passed 1893` | test262 |
| 2026-04-25 | 8 | `zig build test --summary all && zig build smoke --summary all` | 0 | Aggregate regression passed after statement early-error repairs, 109/109 tests and smoke 45/45 | regression |
| 2026-04-25 | 8 | `zig build -Doptimize=ReleaseFast qjs run-test262 --summary all && ./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf 0 53167` | 1 | Runner remains sub-minute; execution prepared 48205/53168 tests and reported `1712/48205 errors, passed 40488`, elapsed 18.05s; non-zero exit remains the tracked engine semantics gap | test262 |
| 2026-04-25 | 8 | `/usr/bin/time -f 'elapsed=%E cpu=%P maxrss=%MKB' ./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test` | 1 | Full local test262 gate after QuickJS parser/lexer early-error convergence prepared 48205/53168 tests and reported `337/48205 errors, passed 41863`, elapsed 17.99s, CPU 184%, max RSS 28576KB; non-zero exit remains the tracked engine semantics gap | test262 |
| 2026-04-25 | 8 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/language/expressions 8001 12000` | 0 | Expression object/function/update/template parser alignment reduced this slice to `0/3037 errors, passed 3032` | test262 |
| 2026-04-25 | 8 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/language/literals 0 5000` | 0 | Literal lexer/parser alignment reduced this slice to `0/533 errors, passed 450` | test262 |
| 2026-04-25 | 8 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/language/statements 0 8000` | 1 | Statement parser early-error alignment reduced this slice to `6/8001 errors, passed 7868`; remaining failures are TDZ/runtime and Function constructor gaps | test262 |
| 2026-04-25 | 8 | `zig build test --summary all && zig build smoke --summary all` | 1 | Aggregate regression now fails visibly after removing Date/control-flow smoke output bridges: exec tests fail 2/109 and smoke fails 3/45 (`control_flow.js`, `switch.js`, `date.js`) | regression |
| 2026-04-25 | 8 | `zig build test --summary all && zig build smoke --summary all` | 0 | Aggregate regression passed after Date object, control-flow, and switch smoke repair: 109/109 tests and smoke 45/45 | regression |
| 2026-04-25 | 8 | `zig build -Doptimize=ReleaseFast qjs --summary all && /usr/bin/time -f 'elapsed=%e cpu=%P maxrss=%M' ./zig-out/bin/run-test262 -c quickjs/test262.conf quickjs/test262/test` | 1 | Full local test262 gate remains sub-minute after Date/control-flow/switch repair: prepared 48205/53168 tests, 4963 excluded, 6005 skipped by feature, `Result: 337/48205 errors, passed 41863`, elapsed 33.82s; non-zero exit remains the tracked engine semantics gap | test262 |
| 2026-04-25 | 8 | `./zig-out/bin/run-test262 -v -t 8 -c quickjs/test262.conf -d quickjs/test262/test/annexB 0 2000` | 0 | QuickJS-aligned AnnexB HTML comment and strict template legacy-octal handling reduced AnnexB to `0/1086 errors, passed 1059` | test262 |
| 2026-04-25 | 8 | `zig build -Doptimize=ReleaseFast qjs run-test262 --summary all && /usr/bin/time -f 'elapsed=%e cpu=%P maxrss=%M' ./zig-out/bin/run-test262 -c quickjs/test262.conf quickjs/test262/test` | 1 | Full local test262 gate after AnnexB and statements repair remains sub-minute: prepared 48205/53168 tests, 4963 excluded, 6005 skipped by feature, `Result: 310/48205 errors, passed 41890`, elapsed 34.33s; non-zero exit remains the tracked engine semantics gap | test262 |
| 2026-04-25 | 8 | `zig build -Doptimize=ReleaseFast qjs run-test262 --summary all && /usr/bin/time -f 'elapsed=%e cpu=%P maxrss=%M' ./zig-out/bin/run-test262 -c quickjs/test262.conf quickjs/test262/test` | 0 | Full local test262 gate completed under one minute: prepared 48205/53168 tests, 4963 excluded, 6005 skipped by feature, `Result: 0/48205 errors, passed 42200`, elapsed 38.88s, CPU 91%, max RSS 15792KB | test262 |
| 2026-04-25 | 8 | `zig build test --summary all && zig build smoke --summary all && git diff --check` | 0 | Aggregate regression passed after phase 8 convergence: 109/109 tests, smoke 45/45, and whitespace check clean | regression |
| 2026-04-26 | 8 | `zig build test --summary all` | 0 | Aggregate regression passed, 109/109 tests | regression |
| 2026-04-26 | 8 | `zig build smoke --summary all` | 0 | Smoke gate passed, 45/45 scripts | regression |
| 2026-04-26 | 8 | `zig build run-test262 --summary all` | 0 | ReleaseFast `run-test262` build step succeeded from cache | regression |
| 2026-04-26 | 8 | `/usr/bin/time -f 'full elapsed=%e user=%U sys=%S maxrss=%M' ./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test 0 100000` | 0 | Full local test262 gate prepared 48205/53168 tests, excluded 4963, skipped 6005 by feature, `Result: 0/48205 errors, passed 42200`, elapsed 15.00s, user 25.88s, sys 2.86s, max RSS 22352KB | test262 |
| 2026-04-26 | 8 | `./zig-out/bin/run-test262 -vv -T 0 -f tests/zig-smoke/arith.js` | 0 | `-T 0` prints timing line for the selected test and does not classify a pass as an unexpected failure (`Result: 0/1 errors, passed 1`) | test-tools |
| 2026-04-26 | 9 | `zig build test-bytecode --summary all` | 0 | Bytecode focused gate passed after replacing host output opcode names with generic `call`, 6/6 tests | regression |
| 2026-04-26 | 9 | `zig build test-frontend --summary all` | 0 | Frontend focused gate passed after `print`/`console.log` lowering moved to global/property/call bytecode, 21/21 tests | regression |
| 2026-04-26 | 9 | `zig build test-exec --summary all` | 0 | Exec focused gate passed after global callable output path and indirect output-call coverage, 37/37 tests | regression |
| 2026-04-26 | 9 | `./zig-out/bin/zjs -e 'print(1); console.log("ok"); const f = print; f(2 + 3, typeof f); const log = console.log; log("indirect")'` | 0 | CLI output path produced `1`, `ok`, `5 function`, and `indirect` through direct and indirect global/property calls | smoke |
| 2026-04-26 | 9 | `zig build test --summary all` | 0 | Aggregate regression passed after Phase 9 runtime output hardening, 112/112 tests | regression |
| 2026-04-26 | 9 | `zig build smoke --summary all` | 0 | Smoke gate passed after output path replacement, 45/45 scripts | regression |
| 2026-04-26 | 9 | `zig build run-test262 --summary all` | 0 | ReleaseFast `run-test262` build step succeeded after Phase 9 changes | regression |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/JSON 0 200` | 0 | Targeted JSON slice passed, prepared 165/165 tests, `Result: 0/165 errors, passed 165` | test262 |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/language/expressions 0 500` | 0 | Targeted language expressions slice passed, prepared 499 selected tests, `Result: 0/499 errors, passed 499` | test262 |
| 2026-04-26 | 9 | `./zig-out/bin/zjs -e 'print(1); console.log("ok")'` | 0 | CLI direct output check printed `1` and `ok` | smoke |
| 2026-04-26 | 9 | `./zig-out/bin/zjs tests/zig-smoke/arith.js` | 0 | CLI file execution printed `7` for `arith.js` | smoke |
| 2026-04-26 | 9 | `QJS=/home/aneryu/zjs/quickjs/build/qjs QJS_ZIG=/home/aneryu/zjs/zig-out/bin/zjs bun tools/compare/run_compare.js --functional-only` | 0 | Functional compare passed, 45 passed, 0 failed, 0 known-fail | compare |
| 2026-04-26 | 9 | `./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test 0 100000` | 0 | Full local test262 gate passed: prepared 48205/53168 tests, excluded 4963, skipped 6005 by feature, `Result: 0/48205 errors, passed 42200` | test262 |
| 2026-04-26 | 9 | `git diff --check` | 0 | Whitespace check passed after Phase 9 code and docs updates | regression |

## Decision Log

| Date | Decision | Reason | Follow-up |
|---|---|---|---|
| 2026-04-24 | Keep root plan as architecture contract and split execution details into `docs/quickjs-redesign/`. | The redesign will run for a long time and needs resumable records outside chat history. | Maintain `TRACKING.md` and active phase docs during implementation. |
| 2026-04-24 | Avoid `src/engine/quickjs/` nesting. | `src/engine/` is already the QuickJS engine namespace; explicit source mapping is clearer than redundant directory nesting. | Keep mapping table updated when files move or split. |
| 2026-04-24 | Track incomplete behavior through `status.zig` and phase docs. | A complete rewrite needs temporary gaps, but completed phases must not hide not-implemented behavior. | Phase tests should validate status transitions. |
| 2026-04-24 | Add a separate error and learning ledger. | Validation logs and known-failure summaries are not enough to preserve root causes and reusable lessons. | Use `ERRORS_AND_LEARNINGS.md` and `templates/error-record.md` for non-trivial failures. |
| 2026-04-24 | Wire Phase 8 smoke as a real golden comparator even before engine semantics pass. | A passing placeholder smoke step would hide the main remaining execution gap. | Keep `zig build smoke` failing until `zjs` produces expected script output. |
| 2026-04-26 | Move host-visible output from Phase 8 runner dependency to Phase 9 runtime semantic hardening. | Runner parity is complete; output semantics belong to runtime global lookup/property/call behavior rather than tooling. | Validate output through normal callable execution and close completed BigInt/DataView/String wrapper coercion hardening in Phase 9 records. |

## Risk Log

| Risk | Impact | Mitigation | Status |
|---|---|---|---|
| Work drifts into a simplified interpreter instead of QuickJS parse-to-bytecode semantics. | Full test262 parity becomes unreachable. | Phase 5 forbids standalone AST execution and requires QuickJS source mapping. | open |
| Long-running validation gets interrupted but later treated as final proof. | False confidence in parity. | Validation entries must record exit status and mark interrupted sweeps explicitly. | open |
| Support libraries are postponed until builtin work. | RegExp, Unicode, BigInt, and number formatting semantics diverge. | Phase 7 ports `libs` before dependent builtins. | open |
| Stale `build.zig` roots hide deleted-code dependencies. | Redesign cannot build from clean state. | Phase 1 replaced build wiring with existing roots only. | mitigated |
| Phase 8 smoke is wired before the engine can execute smoke scripts fully. | `zig build smoke` fails until expression/object/call semantics catch up. | CLI smoke bridge path is removed and `zig build smoke --summary all` passes 45/45 through runtime behavior. | mitigated |

## Known Failures

No current known failures are open for the completed Phase 9 baseline. Historical
bootstrap and Phase 8 expected failures that are superseded by current gates are
archived under `docs/quickjs-redesign/archive/`.

## Learning Summary

| Date | Source | Learning | Error record |
|---|---|---|---|
| 2026-04-24 | docs review | Non-trivial failures need durable root-cause records separate from validation logs. | `ERRORS_AND_LEARNINGS.md#eal-20260424-001-error-and-learning-workflow-missing` |

## Current Handoff

| Field | Value |
|---|---|
| Next recommended action | Continue post-Phase 9 semantic hardening for assert-heavy builtin parity gaps and any new divergences found by targeted test262 triage. |
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
- Phase 8 tooling now has `zjs`, `run-test262`, `smoke`, and `test-tools` build steps. `run-test262` follows the original runner design more closely: namelists use capacity growth and sort/dedupe, known/exclude lookups use sorted lists, selection no longer parses every file's metadata, feature skip is handled during execution, workers run by index stride, tests execute in-process, raw tests preserve source-leading hashbangs, and harness includes are cached per worker without shared lock contention. Full local test262 completes under one minute with ReleaseFast: prepared 48205/53168 tests, excluded 4963, skipped 6005 by feature, `Result: 0/48205 errors, passed 42200`, elapsed 15.00s. Metadata parsing covers includes, features, flags, and negative records; includes are loaded from the harness directory in declaration order; negative records require non-zero exit and match expected stderr type when present. The previous Date/control-flow smoke output bridge has been removed; `zig build test --summary all` and `zig build smoke --summary all` now pass through real Date/control-flow/switch smoke behavior. AnnexB HTML comment handling follows the QuickJS lexer shape for `<!--` and line-start `-->`, and the tracked expressions/literals/statements/module/global/rest/built-ins slices now match the local test262 gate.
- Phase 9 is complete. The dedicated host output opcode names and VM dispatch path were removed. `print(...)` now lowers to global lookup plus generic call, `console.log(...)` lowers through global lookup and property read before generic call, and the output sink remains the writer passed through `Engine.evalWithOutput*` / `zjs`. BigInt/DataView/String-wrapper coercion follow-up work is also complete, including reviewed DataView numeric/BigInt setter and ArrayBuffer slice repairs. Aggregate tests pass 132/132, smoke and compare pass 45/45, and the full local test262 gate remains `0/48205 errors`.
- Compare tooling now defaults to rebuilt `zig-out/bin/zjs` and in-repo `quickjs/build/qjs`; CMake was unavailable locally, so `quickjs/build/qjs` was built directly with `cc`.
- Current checkout caveat: the parent repository is clean and records `quickjs`
  at `c707cf5eda67a97bbff7a60cb2ef124fd4a77420`; the nested
  `quickjs/test262` submodule is not initialized in `git submodule status`, but
  the local `quickjs/test262` tree required for validation is present and the
  full runner gate passes.
- Do not use old `src/engine/vm/` paths as repair targets.
- Use local QuickJS source and `quickjs/build/qjs` as semantic oracle once executable validation exists.
- Use `ERRORS_AND_LEARNINGS.md` for failures that need root-cause analysis or reusable lessons.
- Update this file before handing off a partially completed phase.
