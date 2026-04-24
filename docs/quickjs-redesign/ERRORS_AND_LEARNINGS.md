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
| EAL-20260424-002 | open | high | 8 | quickjs_parity_gap | Real smoke runner fails 45/45 scripts because `zjs` does not yet produce smoke-visible output such as `print(...)`. | `#eal-20260424-002-smoke-runner-wired-before-output-semantics` | pending | Phase 8, smoke runner |

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

Status: open
Severity: high
Phase: 8
Classification: quickjs_parity_gap

Summary: Phase 8 wired `zig build smoke` to the rebuilt `zjs` executable and the
existing `tests/zig-smoke/manifest.txt` golden files. The runner works as a real
comparator, but all 45 manifest scripts currently fail.

Reproduction:

```bash
ZIG_GLOBAL_CACHE_DIR=/Users/aneryu/zjs/.zig-cache/global zig build smoke --summary all
```

Observed result: exit 1. The runner reports `smoke: 45/45 scripts failed`.
Most failures have status 0 but stdout length 0 because the rebuilt engine does
not yet implement smoke-visible output such as `print(...)`. A few scripts exit
1 on unsupported frontend/execution paths.

QuickJS owner: `quickjs/qjs.c` for CLI-visible execution behavior and
`quickjs/quickjs.c` for global builtin registration and execution semantics.

Zig owner: `src/cli/qjs.zig`, `src/engine/root.zig`, builtin global setup, and
the frontend/exec paths needed by smoke scripts.

Next fix target: implement the smallest source-aligned output path for
`print(...)` and expression execution, then rerun focused smoke scripts before
the full manifest.

## Learning Log

| ID | Source | Lesson | Applies to | Enforcement |
|---|---|---|---|---|
| LRN-001 | prior zjs validation work | Start from a reproducing validation command, then repair from its output. | bugfixes, parity work, test262 work | README update rules and error workflow |
| LRN-002 | prior interrupted runs | Interrupted or partial sweeps are not final validation evidence. | smoke, compare, test262 | validation log and `interrupted_validation` classification |
| LRN-003 | prior run-test262 work | Runner behavior must be checked against `quickjs/run-test262.c` and `quickjs/test262.conf` before changing engine semantics for excluded files. | Phase 8 and test262 triage | test262 parity matrix |
| LRN-004 | prior parity work | Requests for faithful QuickJS rewrite require source-aligned behavior, not small optimizations presented as parity. | all implementation phases | source mapping and matrix exit criteria |
| LRN-005 | prior runner performance work | Shared harness caches can add lock contention; prefer worker-local state unless evidence proves sharing is safe. | Phase 8 worker execution | test262 runner parity matrix |
| LRN-006 | prior broad-suite crashes | When a broad suite crashes, isolate the smallest file or subdirectory before editing semantics. | test262 triage, builtins, VM | error workflow reproduction step |

## Open Questions

| ID | Question | Owner | Resolution path | Status |
|---|---|---|---|---|
| OQ-001 | Should detailed error records be one file per error from the start, or only after implementation begins? | redesign docs | Use inline index entries during planning; create files once code validation starts. | open |
