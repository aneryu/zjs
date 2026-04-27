# AGENTS.md

## No shortcuts / No cheating

Do real work. Do not make the code only look correct.

When implementing code:

- Do not use ugly hacks just to pass tests.
- Do not hardcode answers unless the task clearly asks for constants.
- Do not skip, delete, weaken, or rewrite tests to make them pass.
- Do not hide errors with empty `catch`, broad mocks, `any`, `@ts-ignore`, or
  `eslint-disable` unless there is a strong reason.
- Do not replace real logic with fake logic.
- Do not ignore edge cases that are already implied by the code or tests.
- Do not change public APIs unless the task requires it.
- Do not remove validation, security checks, or error handling to make code
  simpler.
- Do not claim the task is done without checking the relevant build, test, or
  typecheck when possible.

Prefer:

- Simple code over clever code.
- Correct code over fast-looking code.
- Small focused changes over large unrelated rewrites.
- Fixing the root cause over patching symptoms.
- Clear errors over silently ignoring failures.

If the proper solution is hard, do the hard work.
If you cannot finish it, explain what is missing instead of faking completion.
If a solution only works for the current test case but not the real problem, it
is considered wrong.

## Project Purpose

This repository is a **QuickJS C -> Zig** rewrite. The local QuickJS source is
the semantic reference, and the Zig implementation should continuously improve
JavaScript semantic compatibility, tooling usability, and validation coverage.

Do not store dynamic project status, phase progress, or latest validation
numbers in this file. Keep that information in
`docs/quickjs-redesign/TRACKING.md`.

## Source Of Truth

- `QUICKJS_REDESIGN_PLAN.md`: architecture contract and long-term constraints.
- `docs/quickjs-redesign/TRACKING.md`: current phase, validation log, risks, and
  handoff notes.
- `docs/quickjs-redesign/PHASES_HISTORY.md`: consolidated history of completed
  Phases 1-9 (original per-phase plans archived under `archive/phases/`).
- `docs/quickjs-redesign/ARCHITECTURE_REPAIR_PLAN.md`: architecture repair
  queue and post-AR follow-up status.
- `docs/quickjs-redesign/matrices/`: subsystem coverage matrices and validation
  status.
- `docs/quickjs-redesign/ERRORS_AND_LEARNINGS.md`: reusable failure records and
  lessons.

## Repository Layout

- `src/engine/root.zig`: public engine entrypoint.
- `src/engine/core/`: values, runtime/context, atoms, strings, objects,
  properties, arrays, and core ownership.
- `src/engine/frontend/`: lexer, parser, source positions, and frontend parsing.
- `src/engine/bytecode/`: bytecode, constants, scopes, module metadata, and
  emitter.
- `src/engine/exec/`: bytecode execution, calls, eval, exceptions, and job queue.
- `src/engine/builtins/`: ECMAScript built-in objects and constructors.
- `src/engine/libs/`: regexp, unicode, bignum, dtoa, and support libraries.
- `src/cli/`: `zjs` and test262 CLI entrypoints.
- `src/tools/`: smoke runner, test262 runner, and other tools.
- `src/tests/`: Zig unit and integration test entrypoints.
- `tests/zig-smoke/`: JavaScript smoke scripts, manifest, and golden output.
- `quickjs/`: QuickJS semantic reference and local test262 configuration.
- `tools/compare/`: helpers for comparing behavior against the QuickJS baseline.

## Common Commands

### Build

- `zig build qjs --summary all`
- `zig build run-test262 --summary all`

### Regression

- `zig build test --summary all`
- `zig build smoke --summary all`
- `git diff --check`

### test262

Run a targeted slice based on the changed area. For runner, parser, execution, or
semantic compatibility changes, prefer the relevant `-d` / `-f` / index range
command. Use the full local gate when final confirmation is needed:

```bash
./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test 0 100000
```

## CLI Contract

`zjs` supports:

- `zjs -e "<script>"`
- `zjs <file.js>`

Missing or invalid arguments should print usage and exit non-zero.

## Change Discipline

- Reproduce before changing: run the relevant failing script, slice, or test.
- Make the smallest necessary change in the existing subsystem.
- Do not delete, move, skip, weaken, or widen excludes to manufacture a pass.
- Fix one problem class at a time; do not mix unrelated semantic domains.
- Compare semantic fixes against QuickJS source and record key evidence.
- After changes, run at least `zig build test --summary all` and
  `zig build smoke --summary all`.
- Runner or test262 changes require the relevant runner fixture or target slice.
- Update `TRACKING.md`, the relevant matrix, and when useful
  `ERRORS_AND_LEARNINGS.md` for durable failures, regressions, or decisions.

## Where To Look

- Core values, runtime/context, atoms, strings, objects, properties, and arrays:
  `src/engine/core/`.
- Lexer, parser, and early errors: `src/engine/frontend/`.
- Bytecode emission, scopes, and module metadata: `src/engine/bytecode/`.
- Execution semantics, calls, exceptions, eval, and job queue:
  `src/engine/exec/`.
- Built-in object behavior: `src/engine/builtins/`.
- RegExp, Unicode, BigInt, and number formatting: `src/engine/libs/`.
- CLI behavior: `src/cli/`.
- Smoke and test262 runner behavior: `src/tools/`.

## Pre-Commit Checklist

- The relevant failing case was reproduced and understood.
- The change is limited to the minimum necessary files.
- Related docs, phase notes, or matrices are updated.
- `zig build test --summary all` passes.
- `zig build smoke --summary all` passes.
- `git diff --check` passes.
- No noisy logs, temporary debug output, or unrelated build noise were added.
