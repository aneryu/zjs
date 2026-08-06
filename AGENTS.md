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

## Production Configuration

The shipped configuration, and the build defaults:

```
zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off
```

- **`compiler=v2` is the only compiler.** The retired `-Dzjs_compiler` option,
  legacy Phase 1/2/3 passes, and dual comparator are no longer in the tree.
  The signature keeps `compiler=v2` so every artifact still names and attests
  the compiler it contains.
- **`layout=short` is release configuration, not a tuning knob.** The switch was
  gated on it. `-Dzjs_v2_layout=plain` survives only as the A/B diagnostic
  instrument.
- Any measurement, gate result or report must name the configuration it ran. The
  binary states its own (`zig-out/bin/zjs --print-config-signature`) and every
  engine-bearing artifact asserts it at compile time.

**Legacy compiler source has been removed.** QCP-1B was reopened only after a
deletion bisection identified the old crypto regression: shrinking
`CompileContext` by the dual comparator's unused pointer changed Zig 0.16's
whole-program native layout despite identical bytecode and allocation streams.
The reserved-word control proved the trigger but was not retained. The durable
fix is to keep V2 lowering and the stack-size walk as explicit non-inlined
compiler stages, preventing legacy deletion from folding both into the packed
finalizer. See `docs/qcp1_switch_decision.md` §9.

## Agent skills

### Issue tracker

Issues and PRDs are tracked as local Markdown under `.scratch/<feature>/`. See
`docs/agents/issue-tracker.md`.

### Triage labels

Use the five canonical local status strings. See
`docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repository. See `docs/agents/domain.md`.

## Repository Layout

- `src/root.zig`: public engine entrypoint.
- `src/core/`: values, runtime/context, atoms, strings, objects,
  properties, arrays, GC, and core ownership.
- `src/parser.zig`: lexer, parser, source positions, and compile entry.
- `src/bytecode.zig`: bytecode, constants, scopes, module metadata,
  `FunctionBytecode` packing, and pipeline passes.
- `src/exec/`: bytecode execution, standard-global bootstrap and built-in
  behavior, calls, eval, exceptions, modules, promises, VM opcode shards, and
  job queue.
- `src/runtime/`: host/runtime policy helpers for event loop, cleanup,
  module file graphs, plugins, and buffer operations.
- `src/binding/`: FFI plugins, host binding helpers, and public API aliases.
- `src/libs/`: regexp, unicode, bignum, dtoa, and support libraries.
- `src/cli/`: `zjs` and test262 CLI entrypoints.
- `src/tests/`: Zig unit and integration test entrypoints.
- `test262/`: test262 checkout used by the local gate.
- `tests/fixtures/`: fixture snapshots used by opcode and runner tests.

## Common Commands

### Build

- `zig build zjs --seed 0 --summary all`
- `zig build zjs-dev --seed 0 --summary all` (Debug CLI used by the inner-loop smoke gate)
- `zig build run-test262 --seed 0 --summary all`
- `zig build run-test262-dev --seed 0 --summary all` (Debug runner used by `test262-smoke`)

Always pass CLI `--seed 0` to one-shot `zig build` commands. Zig 0.16
randomizes dependency traversal by default; a stable seed prevents unchanged
builds from cycling through duplicate cache artifacts. The `mise` validation
tasks below include it.

### Regression

- `zig build test-core --seed 0 --summary all` (example changed-area target;
  replace `core` with `parser`, `bytecode`, `exec`, `builtins`, `runtime`, or
  `runner`, and use the narrowest matching target on each focused edit)
- `mise run quick-check` (Debug CLI integration gate: build `zjs-dev` and run
  CLI smoke fixtures after a coherent edit, in addition to the direct
  changed-area Zig test or test262 slice)
- `mise run checkpoint-check` (medium checkpoint gate: unified
  Debug tests, Debug CLI smoke, architecture, Debug `test262-smoke`, and
  OOM-cap coverage inside the unified suite; use before handing off non-trivial
  code-bearing changes when full test262 is not yet justified)
- `mise run quick-watch` (persistent incremental quick-check loop; stop it
  before running a checkpoint or production gate; prefer it when several
  consecutive edits all need CLI smoke feedback)
- `zig build test --seed 0 --summary all` (Debug full unit/integration suite;
  during the current large refactor, do NOT run this after every small edit. Prefer
  targeted compile checks, focused unit tests, or changed-area slices while
  iterating, and save the full Debug suite for meaningful checkpoints or before
  handing off substantial code changes)
- `zig build test -Doptimize=ReleaseSafe --seed 0 --summary all` (ReleaseSafe
  verification; run ONLY once as a final gate before final commits or CI gates
  to ensure optimized loop safety)
- `zig build test-altrepr --seed 0 --summary all` (alternate JSValue representation
  guard: runs the suite with the representation opposite the target default.
  REQUIRED whenever a change touches `src/core/value.zig` or
  value-representation semantics; for such changes also run the test262 gate
  once with `-Dzjs_nan_boxing=true` at stage close on 64-bit hosts. The 64-bit
  default is the QuickJS-aligned 16-byte payload+tag layout; narrower targets
  default to 8-byte NaN-boxing. The explicit option can select either mode and
  neither may rot. The step spawns a nested `zig build test` and forwards every
  `-D` option of the outer invocation plus the resolved optimize mode, so
  `zig build test-altrepr -Doptimize=ReleaseSafe` genuinely runs that
  configuration under the alternate representation. The step also
  passes the child the exact configuration signature it must resolve
  (`-Dzjs_expect_config`), so a dropped option is a hard build failure rather
  than a green run of a different configuration.)
- `zig build config-signature-check --seed 0` (runs the built `zjs`, makes it
  state its own configuration via `--print-config-signature`, and compares that
  against what the build graph requested. The binary answers from the
  declarations the engine consumes — `resolve_labels.default_layout`,
  `core.value.nan_boxing`, `builtin.mode`,
  `core.memory.force_gc_on_allocation_enabled`,
  `core.atom.ownership_audit_enabled` — so an option that never reached the
  code fails here. Included in `zig build smoke`. Every engine-bearing artifact
  asserts the same string at COMPILE time
  (`comptime { config_signature.attest("<artifact>"); }` in each root), each
  reporting its own optimize mode, so no test artifact borrows another's
  attestation and a Debug build cannot pass for a ReleaseSafe one.)
- `zig build config-drift-gate --seed 0` (proves the attestation above can
  still fail. Five halves: a wrong `compiler`, a wrong `layout` and a wrong
  `optimize` expectation must FAIL, the correct expectation must SUCCEED, and
  `-Dzjs_v2_layout=plain` with a `layout=plain` expectation must SUCCEED. That
  last pair is the `.plain` diagnostic's self-proof: the same expectation
  string must fail against a `short` build and succeed against a `plain` one.
  Wired into `checkpoint-check` and `engine-production-gate`; the output names
  which half is running, so an expected failure is distinguishable from a real
  one. A negative half that fails for an unrelated reason is reported
  INCONCLUSIVE, not as a pass.)
- `zig build test-oom --seed 0 --summary all` (OOM 注入门禁：
  corpus×checkAllAllocationFailures 注入 + 同 runtime 恢复金丝雀；阶段收口档位执行，
  不进日常迭代 / OOM injection gate: corpus x allocation-failure injection plus
  same-runtime recovery canaries; run at phase-close tier, not per-edit)

- `git diff --check`

### test262

Run a targeted slice based on the changed area. For runner, parser, execution, or
semantic compatibility changes, prefer `test262-smoke` plus the relevant `-d` /
`-f` / index range command. Use the full local gate when final confirmation is
needed:

```bash
zig build test262-smoke --seed 0 --summary all
zig build test262-gate --seed 0 --summary all
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
- During the current large refactor, do not automatically run the full
  `zig build test --seed 0 --summary all` suite after every edit. Use the cheapest
  validation that proves the changed surface: targeted compile commands,
  changed-area unit tests, runner fixtures, or focused test262 slices. Run the
  full Debug suite at meaningful checkpoints, before broad handoff, or when a
  change touches shared runtime/core semantics and targeted evidence is not
  strong enough.
- Runner or test262 changes require the relevant runner fixture or target slice.
- New throw sites should use the message-carrying throw*Message helpers; bare
  `return error.XxxError` is reserved for paths whose message is attached
  elsewhere or genuinely unreachable by user code.
- Keep non-trivial validation evidence close to the relevant code change,
  commit message, issue, or PR. Do not add broad status ledgers back to the
  active tree without an explicit request.

## Where To Look

- Core values, runtime/context, atoms, strings, objects, properties, arrays,
  shapes, and GC:
  `src/core/`.
- Lexer, parser, source positions, and TypeScript erasure: `src/parser.zig`.
- Bytecode emission, scopes, module metadata, `FunctionBytecode` packing, and
  pipeline passes: `src/bytecode.zig`.
- Execution semantics, calls, exceptions, eval, modules, promises, job queue,
  and opcode handlers:
  `src/exec/`.
- Host/runtime policy helpers for event loop, cleanup, module file graphs,
  plugins, and buffer operations: `src/runtime/`.
- Standard-global installation and built-in object behavior: `src/exec/`.
- RegExp, Unicode, BigInt, and number formatting: `src/libs/`.
- CLI behavior and test262 runner: `src/cli/`.

## Pre-Commit Checklist

- The relevant failing case was reproduced and understood.
- The change is limited to the minimum necessary files.
- Related docs, tracking notes, or matrices are updated.
- `zig build test --seed 0 --summary all` at a checkpoint or before handoff when the
  change is code-bearing and broad enough to justify the cost; otherwise record
  the focused validation that covers the change.
- `zig build test -Doptimize=ReleaseSafe --seed 0 --summary all` (run ONLY once as a final pre-commit/pre-push gate verification).
- `git diff --check` passes.
- No noisy logs, temporary debug output, or unrelated build noise were added.
