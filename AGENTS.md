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

- `GUIDE.md`: engineering rules (Part A) and the validation command ladder
  (Part B.6). Do not recopy that ladder here.
- `CONTRIBUTING.md`: human contribution workflow.
- Root `test262.conf`, the `test262/` submodule, and `tests/fixtures/`:
  active local validation inputs.

## Production Configuration

Shipped default:

```
zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off
```

`compiler=v2` is the only compiler. `layout=short` is the release layout;
`-Dzjs_v2_layout=plain` is an A/B diagnostic. Every engine-bearing artifact
attests the configuration signature at compile time. See
`docs/qcp1_switch_decision.md` §9 if a layout-sensitive compiler change is in
scope.

## Agent skills

Issues and PRDs live under `.scratch/<feature>/`. See
`docs/agents/issue-tracker.md` and `docs/agents/triage-labels.md`.
Domain notes: `docs/agents/domain.md`.

## Repository Layout

See `docs/architecture.md`. Short map:

- `src/root.zig`: public embedder entry.
- `src/core/`: values, runtime, objects, GC.
- `src/parser.zig`: lexer, parser, TypeScript erasure.
- `src/compiler_v2/`: the compiler.
- `src/bytecode.zig`: bytecode carrier and packing.
- `src/exec/`: VM, builtins, calls, modules, promises.
- `src/runtime/`: event loop and native plugins.
- `src/binding/`: public adapters and FFI descriptors.
- `src/libs/`, `src/cli/`, `src/tests/`.

## Commands

`build.zig` pins the Zig 0.16 build/test seed to `0`; CLI `--seed` is not
required. The command ladder, focused targets (`test-core`, `test-exec`, …),
and test262 slices are in `GUIDE.md` Part B.6.

CLI contract: `zjs -e "<script>"` and `zjs <file.js>`. Missing or invalid
arguments print usage and exit non-zero.

## Change Discipline

- Reproduce before changing: run the relevant failing script, slice, or test.
- Make the smallest necessary change in the existing subsystem.
- Do not delete, move, skip, weaken, or widen excludes to manufacture a pass.
- Fix one problem class at a time; do not mix unrelated semantic domains.
- Compare semantic fixes against QuickJS reference behavior and record key
  evidence.
- Use the cheapest GUIDE B.6 tier that covers the change. Do not run the full
  Debug suite after every small edit.
- Runner or test262 changes require the relevant runner fixture or target slice.
- New throw sites should use the message-carrying throw*Message helpers; bare
  `return error.XxxError` is reserved for paths whose message is attached
  elsewhere or genuinely unreachable by user code.
- Keep validation evidence with the owning change. Do not add broad status
  ledgers back to the active tree without an explicit request.

## Pre-Commit Checklist

- The relevant failing case was reproduced and understood.
- The change is limited to the minimum necessary files.
- Related docs are updated.
- The GUIDE B.6 tier that covers the change was run.
- `git diff --check` passes.
- No noisy logs or temporary debug output were added.
