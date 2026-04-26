# QuickJS Redesign Docs

This directory is the long-running execution record for `QUICKJS_REDESIGN_PLAN.md`.
The root plan defines architecture and scope. These documents track implementation
progress, phase-level details, validation evidence, and handoff state.

## Document Map

| File | Purpose |
|---|---|
| `TRACKING.md` | Current phase board, validation log, decision log, risk log, and handoff notes. |
| `ERRORS_AND_LEARNINGS.md` | Durable failure records, root causes, fixes, regression evidence, and reusable lessons. |
| `errors/README.md` | Storage rules for long-form per-error records. |
| `archive/README.md` | Storage rules for superseded historical records that are no longer active status sources. |
| `phases/01-bootstrap-source-baseline.md` | Bootstrap source tree, build wiring, source baseline, and status metadata. |
| `phases/02-core-runtime-foundations.md` | Value model, runtime, context, atoms, strings, classes, shapes, refcount and GC foundations. |
| `phases/03-object-property-semantics.md` | Ordinary object model, descriptors, prototypes, property operations, and array core semantics. |
| `phases/04-opcode-bytecode-metadata.md` | Opcode table, bytecode formats, function bytecode, constants, module metadata, and debug tables. |
| `phases/05-frontend-bytecode-emitter.md` | Lexer, parser, regexp literal handling, scope resolution, and direct bytecode emission. |
| `phases/06-bytecode-execution.md` | VM dispatch, stack frames, calls, exceptions, eval, modules, promises, jobs, and iterators. |
| `phases/07-builtins-support-libraries.md` | Builtins plus regexp, unicode, bignum, and dtoa support libraries. |
| `phases/08-cli-tooling-validation.md` | `zjs`, smoke runner, compare runner integration, and test262 runner. |
| `phases/09-runtime-semantic-hardening.md` | Runtime semantic hardening after tooling completion, starting with host-visible output through normal global lookup and calls. |

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
- `blocked`: progress is stopped on a concrete dependency or decision.
- `validated`: phase or subsystem passed its documented exit checks.
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
