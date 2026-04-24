# QuickJS Redesign Tracking

Last updated: 2026-04-24

This file is the working ledger for the full QuickJS Zig redesign. It should be
updated alongside implementation, tests, and phase documents.

## Current Snapshot

| Field | Value |
|---|---|
| Active phase | Phase 1: Bootstrap And Source Baseline |
| Overall status | in_progress |
| QuickJS semantic baseline | `64e64ebb1dd61505c256285a699c65c42941c5ed` |
| Current engine state | Phase 1 bootstrap tree exists with source/status metadata and empty subsystem roots |
| Current build state | `build.zig` references only current Phase 1 roots and `test-quickjs-port` |
| Current validation state | `zig build test-quickjs-port --summary all` passed with 4/4 tests |
| Current learning state | Error and learning workflow initialized in `ERRORS_AND_LEARNINGS.md` |

## Phase Board

| Phase | Status | Phase doc | Matrix | Required next evidence |
|---|---|---|---|---|
| 1 Bootstrap And Source Baseline | completed | `phases/01-bootstrap-source-baseline.md` | none | Phase 2 runtime/context init-deinit gate |
| 2 Core Runtime Foundations | not_started | `phases/02-core-runtime-foundations.md` | `matrices/core-runtime-invariants.md` | Leak-free runtime/context init-deinit and constants tests |
| 3 Object And Property Semantics | not_started | `phases/03-object-property-semantics.md` | `matrices/object-property-matrix.md` | Descriptor/prototype/array property tests |
| 4 Opcode And Bytecode Metadata | not_started | `phases/04-opcode-bytecode-metadata.md` | `matrices/opcode-execution-matrix.md` | Opcode and bytecode ownership tests |
| 5 Frontend And Bytecode Emitter | not_started | `phases/05-frontend-bytecode-emitter.md` | `matrices/frontend-coverage-matrix.md` | Parser/emitter fixtures |
| 6 Bytecode Execution | not_started | `phases/06-bytecode-execution.md` | `matrices/opcode-execution-matrix.md` | Representative `Engine.eval` execution tests |
| 7 Builtins And Support Libraries | not_started | `phases/07-builtins-support-libraries.md` | `matrices/builtins-support-matrix.md` | Builtin and support library tests |
| 8 CLI Tooling And Validation | not_started | `phases/08-cli-tooling-validation.md` | `matrices/test262-runner-parity.md` | `zjs`, smoke, compare, and test262 runner gates |

## Work Queue

| ID | Status | Phase | Scope | Next action | Blocker |
|---|---|---|---|---|---|
| WQ-001 | completed | 1 | Bootstrap source tree and build wiring | Created planned bootstrap tree and compiled bootstrap roots | none |
| WQ-002 | completed | 1 | Source/status metadata | Added source mapping and status tests | none |
| WQ-003 | ready | 2 | Core runtime foundations | Start value/runtime/context invariants matrix | none |

## Subsystem Coverage Matrix

| Subsystem | Phase | Matrix | Status | Latest validation |
|---|---|---|---|---|
| Source baseline and status table | 1 | none | completed | `zig build test-quickjs-port --summary all` passed, 4/4 tests |
| Core runtime invariants | 2 | `matrices/core-runtime-invariants.md` | not_started | none |
| Object and property semantics | 3 | `matrices/object-property-matrix.md` | not_started | none |
| Opcode metadata | 4 | `matrices/opcode-execution-matrix.md` | not_started | none |
| Frontend and bytecode emitter | 5 | `matrices/frontend-coverage-matrix.md` | not_started | none |
| Bytecode execution | 6 | `matrices/opcode-execution-matrix.md` | not_started | none |
| Builtins and support libraries | 7 | `matrices/builtins-support-matrix.md` | not_started | none |
| CLI and validation tooling | 8 | `matrices/test262-runner-parity.md` | not_started | none |

## Validation Log

| Date | Phase | Command | Exit | Result | Evidence type |
|---|---|---|---|---|---|
| 2026-04-24 | 1 | `zig build test-quickjs-port --summary all` | 1 | Baseline failed before implementation because `src/tests/quickjs_port.zig` did not exist | reproduction |
| 2026-04-24 | 1 | `zig build test-quickjs-port --summary all` | 0 | Bootstrap source/status tests passed, 4/4 tests | regression |
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

## Risk Log

| Risk | Impact | Mitigation | Status |
|---|---|---|---|
| Work drifts into a simplified interpreter instead of QuickJS parse-to-bytecode semantics. | Full test262 parity becomes unreachable. | Phase 5 forbids standalone AST execution and requires QuickJS source mapping. | open |
| Long-running validation gets interrupted but later treated as final proof. | False confidence in parity. | Validation entries must record exit status and mark interrupted sweeps explicitly. | open |
| Support libraries are postponed until builtin work. | RegExp, Unicode, BigInt, and number formatting semantics diverge. | Phase 7 ports `libs` before dependent builtins. | open |
| Stale `build.zig` roots hide deleted-code dependencies. | Redesign cannot build from clean state. | Phase 1 replaced build wiring with existing roots only. | mitigated |

## Known Failures

| Date | Phase | Command | Exit | Classification | Error record | Notes |
|---|---|---|---|---|---|---|
| 2026-04-24 | bootstrap | `zig build test-quickjs-port --summary all` | 1 | expected_bootstrap_gap | none | Failed before implementation because `src/tests/quickjs_port.zig` was missing; fixed by Phase 1 bootstrap. |

## Learning Summary

| Date | Source | Learning | Error record |
|---|---|---|---|
| 2026-04-24 | docs review | Non-trivial failures need durable root-cause records separate from validation logs. | `ERRORS_AND_LEARNINGS.md#eal-20260424-001-error-and-learning-workflow-missing` |

## Current Handoff

| Field | Value |
|---|---|
| Next recommended action | Start Phase 2 WQ-003 with value/runtime/context invariants and update `matrices/core-runtime-invariants.md`. |
| Must not touch | Do not restore deleted `src/engine/vm/` or old AST interpreter paths. |
| Must update during work | Active phase checklist, work queue status, validation log, affected matrix rows, and error records for reusable failures. |
| Validation discipline | Record exact commands and exit status; keep interrupted sweeps separate from final evidence. |

## Handoff Notes

- Phase 1 bootstrap is complete.
- Do not use old `src/engine/vm/` paths as repair targets.
- Use local QuickJS source and `quickjs/build/qjs` as semantic oracle once executable validation exists.
- Use `ERRORS_AND_LEARNINGS.md` for failures that need root-cause analysis or reusable lessons.
- Update this file before handing off a partially completed phase.
