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
| EAL-20260426-003 | parked | high | AR | parser_gap, emitter_gap, opcode_gap, docs_tracking_gap | Parser and VM can pass selected gates through source-pattern recognizers, test262 metadata guards, and fixture-shaped opcodes instead of general QuickJS semantics. | `#eal-20260426-003-parser-and-vm-fixture-shortcuts` | Pending parser-first replacement slices | Frontend coverage, opcode execution, architecture repair |

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

Status: parked
Severity: high
Phase: AR
Classification: parser_gap, emitter_gap, opcode_gap, docs_tracking_gap

Summary: A read-only audit found that selected smoke/test262 gates can pass while
`frontend/parser.zig`, `bytecode/emitter.zig`, and `exec/vm.zig` still contain
fixture-shaped shortcuts. This is not just missing feature coverage; some paths
recognize test metadata, source comments, or narrow source shapes and then emit
purpose-built bytecode or VM behavior.

Observed shortcut classes:

- `frontend.parser.Result.parse_path` exposes a
  `transitional_fixture_compiler`, and the parse entrypoint tries several
  `compile*Program` helpers before falling back to token metadata scanning.
- Parser helpers inspect test262 metadata and source text such as `negative:`,
  `phase: parse`, `phase: runtime`, `sec-*`, `type: Test262Error`, and fixture
  prose to synthesize syntax or runtime outcomes.
- `SimpleParser` lowers a narrow set of smoke/test262 statement and expression
  shapes for assertions, JSON, Math, Date, URI, Promise, RegExp, arrays,
  closures, named constructors, and selected control flow instead of using a
  complete source-aligned parser/lowering pipeline.
- The emitter and VM include fixture-shaped opcodes and handlers such as
  `throw_test262_error`, `assert_same_value`, `for_in_concat`,
  `array_map_mul`, `new_named_object`, and `instanceof_named`.
- VM helpers still include narrow domain shortcuts such as `parseFlatJsonObject`,
  `__zjs_constructor`, `__zjs_string_data`, native-method string synthesis, and
  public execution paths that can return `UnsupportedOpcode`.

Root cause: The broad validation loop advanced before the parser-first semantic
architecture was complete. Passing local gates was treated as compatibility
evidence even though parts of the frontend and VM were still shaped around known
fixtures and selected test262 metadata.

Required repair direction: Replace source-string recognizers with
token-driven/parser-driven early errors and lowering. Move builtin/domain
semantics out of VM shortcut opcodes into shared object, property, call, and
builtin implementations. Keep any remaining transitional path explicit through
`parse_path`, matrix status, and architecture-repair tracking until removed.

Validation to close: Add focused parser/emitter/VM regression slices for each
removed shortcut class, run `zig build test --summary all`, `zig build smoke
--summary all`, `git diff --check`, targeted test262 slices for touched syntax
or builtin domains, and the full local test262 gate before claiming semantic
completion.

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

## Open Questions

| ID | Question | Owner | Resolution path | Status |
|---|---|---|---|---|
| OQ-001 | Should detailed error records be one file per error from the start, or only after implementation begins? | redesign docs | Use inline index entries during planning; create files once code validation starts. | open |
