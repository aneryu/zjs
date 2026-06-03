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

This repository is a **QuickJS C -> Zig** rewrite. QuickJS remains the semantic
reference, and the Zig implementation should continuously improve JavaScript
semantic compatibility, tooling usability, and validation coverage.

## Source Of Truth

- `GUIDE.md`: project engineering guide. Part A is the C → Zig 0.16 migration
  spec (types, ownership, errors, C interop, style, safety). Part B is the
  validation and tracking workflow.
- Root `test262.conf`, the `test262/` submodule, and fixture snapshots under
  `tests/fixtures/`: active local validation inputs.

Prior phase plans, percentage-gate plans, snapshot ledgers, one-off analyses,
and detailed error catalogs were removed from the active tree and remain
available only through git history.

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
- `src/tests/`: Zig unit and integration test entrypoints.
- `test262/`: test262 checkout used by the local gate.
- `tests/fixtures/`: fixture snapshots used by opcode and runner tests.

## Common Commands

### Build

- `zig build zjs --summary all`
- `zig build run-test262 --summary all`

### Regression

- `zig build test --summary all` (defaults to Debug optimization; use for fast compilation during daily local development iteration)
- `zig build test -Doptimize=ReleaseSafe --summary all` (ReleaseSafe verification; run before final commits or CI gates to ensure optimized loop safety)
- `zig build test-oom --summary all` for sampled exec OOM fail-index coverage.
- `zig build test-oom-exhaustive --summary all` for very slow full exec OOM
  fail-index audits.

- `git diff --check`

### test262

Run a targeted slice based on the changed area. For runner, parser, execution, or
semantic compatibility changes, prefer the relevant `-d` / `-f` / index range
command. Use the full local gate when final confirmation is needed:

```bash
zig build test262-gate --summary all
./zig-out/bin/run-test262 -t 8 -c test262.conf -d test262/test 0 100000
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
- Compare semantic fixes against QuickJS reference behavior and record key
  evidence.
- After changes, run at least `zig build test --summary all`.
- Runner or test262 changes require the relevant runner fixture or target slice.
- Keep non-trivial validation evidence close to the relevant code change,
  commit message, issue, or PR. Do not add broad status ledgers back to the
  active tree without an explicit request.

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
- test262 runner behavior: `src/cli/run_test262.zig`.

## Pre-Commit Checklist

- The relevant failing case was reproduced and understood.
- The change is limited to the minimum necessary files.
- Related docs, tracking notes, or matrices are updated.
- `zig build test --summary all` passes.

- `git diff --check` passes.
- No noisy logs, temporary debug output, or unrelated build noise were added.
