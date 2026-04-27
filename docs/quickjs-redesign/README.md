# QuickJS Redesign Docs

This directory is the long-running execution record for `QUICKJS_REDESIGN_PLAN.md`.
The root plan defines architecture and scope. These documents track implementation
progress, phase-level details, validation evidence, and handoff state.

## Document Map

| File | Purpose |
|---|---|
| `TRACKING.md` | Current phase board, validation log, decision log, risk log, and handoff notes. |
| `ARCHITECTURE_REPAIR_PLAN.md` | Active architecture repair queue for status calibration and parser-first semantic completion. |
| `ERRORS_AND_LEARNINGS.md` | Active per-failure records (reproduction, root cause, fix, validation). The workflow, status/classification vocabulary, and reusable learning log live in `/GUIDE.md` Part B. |
| `errors/README.md` | Storage rules for long-form per-error records. |
| `archive/README.md` | Storage rules for superseded historical records that are no longer active status sources. |
| `PHASES_HISTORY.md` | Consolidated history of completed Phases 1-9: scope, QuickJS source owners, key target files, exit contracts, and closing evidence. |
| `archive/phases/` | Original per-phase execution plans (Phase 1-9) preserved for deep-dive reference; not an active status source. |

## Matrix Map

| File | Phase | Purpose |
|---|---|---|
| `matrices/core-runtime-invariants.md` | 2 | Runtime/context/value/atom/string/class/shape/function/module/GC invariant tracking. |
| `matrices/object-property-matrix.md` | 3 | Ordinary object, descriptor, prototype, own-key, and array behavior tracking. |
| `matrices/frontend-coverage-matrix.md` | 5 | Lexer/parser/emitter syntax-domain coverage tracking. |
| `matrices/opcode-execution-matrix.md` | 4 and 6 | Opcode metadata, lowering, and execution-handler tracking. |
| `matrices/builtins-support-matrix.md` | 7 | Support library and builtin domain tracking. |
| `matrices/test262-runner-parity.md` | 8 | QuickJS `run-test262.c` option and runner-semantics parity tracking. |
| `matrices/runtime-semantic-hardening.md` | 9 | Runtime semantic hardening matrix for replacing transitional execution shortcuts. |

## Template Map

| File | Purpose |
|---|---|
| `templates/error-record.md` | Detailed record template for failures, root-cause analysis, fixes, validation, and lessons. |

## Update Rules

- Update `TRACKING.md` at the start and end of every meaningful implementation session.
- Update the active phase document whenever a task is completed, blocked, or descoped.
- Record exact validation commands, exit status, and relevant summary output. Do not record interrupted long sweeps as final proof.
- Record architecture decisions in the decision log before implementing broad ownership or directory changes.
- Keep root `QUICKJS_REDESIGN_PLAN.md` stable. Edit it only for architecture, scope, or phase-contract changes.
- Keep phase documents detailed enough for a new agent to resume without reading chat history.
- Update the relevant matrix row whenever implementation status, validation evidence, or ownership changes.
- Create or update `ERRORS_AND_LEARNINGS.md` whenever a failure has a reusable lesson, requires a code fix, changes a known-error baseline, or interrupts a validation run.
- Do not close a work item as fixed until the error record has reproduction, root cause, regression test, matrix updates, and validation evidence.

## Status Vocabulary

- `not_started`: no implementation claim.
- `in_progress`: implementation exists, but incomplete paths may remain.
- `source_mapped`: QuickJS source ownership is recorded, but behavior is not yet validated.
- `fixture_validated`: focused Zig fixtures pass for the scoped behavior.
- `baseline_validated`: the scoped behavior passes the current local smoke/test262 baseline.
- `semantic_complete`: no known in-scope public placeholder remains for that subsystem.
- `blocked`: progress is stopped on a concrete dependency or decision.
- `validated`: historical matrix wording meaning the row passed its documented exit checks; prefer the more specific status terms above for new work.
- `completed`: phase exit checklist is satisfied and reflected in `TRACKING.md`.
- `out_of_scope`: intentionally excluded by the root plan.

## Evidence Standard

Every validation entry should include:

- Date.
- Phase or subsystem.
- Command.
- Exit status.
- Short result summary.
- Whether the result is a gate, a smoke signal, or an expected temporary failure.

Example:

```text
2026-04-24 | phase-01 | zig build test-quickjs-port --summary all | exit 0 | source/status tests passed | gate
```

## Error Record Standard

Every non-trivial error record should include:

- ID and status.
- Severity and classification.
- Reproduction command.
- Expected QuickJS behavior or planned invariant.
- Actual Zig behavior.
- QuickJS source owner.
- Zig owner.
- Root cause.
- Fix plan and fix summary.
- Regression test.
- Matrix rows touched.
- Validation evidence.
- Reusable learning.

Use `templates/error-record.md` for detailed entries.
