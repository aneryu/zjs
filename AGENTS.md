# AGENTS.md

## Code Discovery (codebase-memory-mcp)

Use codebase-memory-mcp as a discovery accelerator, not as a source of truth.
The checked-out source, compiler, and tests remain authoritative. The indexed
project name for this repository is `home-aneryu-zjs`.

Choose tools by task:

1. `search_graph` — find uniquely named functions, types, and definitions.
2. `search_code` — find current textual usages and group them by containing
   symbol. Prefer this over `trace_path` for exhaustive usage searches.
3. `get_code_snippet` — inspect a stable indexed symbol after finding its exact
   qualified name. Before editing, open the real file at the reported location.
4. `trace_path` — generate caller/callee and impact-analysis candidates only.
   Verify material results with `search_code`, `rg`, or direct source inspection.
5. `query_graph` and `get_architecture` — use for broad structural questions.
   Scope architecture queries to `src/` unless the task explicitly concerns
   tests or fixtures.

Reliability boundaries:

- If the project is not indexed, run `index_repository` before graph discovery.
- Treat stored line ranges and snippets as potentially stale when the worktree
  is dirty or the target file has changed. A plausible-looking snippet is not
  proof that the index is current; read the actual file before changing code.
- Zig calls through common method names such as `free`, `create`, `destroy`,
  `eval`, and `expect` may be conflated. Do not trust fan-in, hotspot,
  transitive-complexity, or impact conclusions based on those names without
  source verification.
- `trace_path` may miss callers or return file-level pseudo-callers. Never use it
  alone to claim an exhaustive caller set.
- The `test262/` corpus dominates a repository-wide index and JavaScript regular
  expressions may be misclassified as routes. Exclude or scope away `test262/`
  when reasoning about the Zig engine architecture.
- Fall back to `rg` for string literals, error messages, configuration,
  non-code files, stale-index conflicts, and exact verification. Direct file
  reads are preferred when the graph and working tree disagree.

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
  inline-cache slots, and pipeline passes.
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

- `zig build zjs --summary all`
- `zig build zjs-dev --summary all` (Debug CLI used by the inner-loop smoke gate)
- `zig build run-test262 --summary all`
- `zig build run-test262-dev --summary all` (Debug runner used by `test262-smoke`)

### Regression

- `zig build quick-check --summary all` (fast inner-loop gate: build the Debug
  `zjs-dev` and run CLI smoke fixtures; use while iterating, then add the
  changed-area Zig test or test262 slice)
- `zig build checkpoint-check --summary all` (medium checkpoint gate: unified
  Debug tests, Debug CLI smoke, architecture, Debug `test262-smoke`, and
  OOM-cap coverage inside the unified suite; use before handing off non-trivial
  code-bearing changes when full test262 is not yet justified)
- `zig build test-{core,parser,bytecode,exec,builtins,runtime,runner} --summary all`
  (explicit changed-area targets; choose the narrowest matching subsystem)
- `mise run quick-watch` (persistent incremental quick-check loop; stop it
  before running a checkpoint or production gate)
- `zig build test --summary all` (Debug full unit/integration suite; during the
  current large refactor, do NOT run this after every small edit. Prefer
  targeted compile checks, focused unit tests, or changed-area slices while
  iterating, and save the full Debug suite for meaningful checkpoints or before
  handing off substantial code changes)
- `zig build test -Doptimize=ReleaseSafe --summary all` (ReleaseSafe verification; run ONLY once as a final gate before final commits or CI gates to ensure optimized loop safety)
- `zig build test-altrepr --summary all` (alternate JSValue representation
  guard: runs the suite with the representation opposite the target default.
  REQUIRED whenever a change touches `src/core/value.zig` or
  value-representation semantics; for such changes also run the test262 gate
  once with `-Dzjs_nan_boxing=true` at stage close on 64-bit hosts. The 64-bit
  default is the QuickJS-aligned 16-byte payload+tag layout; narrower targets
  default to 8-byte NaN-boxing. The explicit option can select either mode and
  neither may rot.)
- `zig build test-oom --summary all` (OOM 注入门禁：corpus×checkAllAllocationFailures 注入 + 同 runtime 恢复金丝雀；阶段收口档位执行，不进日常迭代 / OOM injection gate: corpus x allocation-failure injection plus same-runtime recovery canaries; run at phase-close tier, not per-edit)

- `git diff --check`

### test262

Run a targeted slice based on the changed area. For runner, parser, execution, or
semantic compatibility changes, prefer `test262-smoke` plus the relevant `-d` /
`-f` / index range command. Use the full local gate when final confirmation is
needed:

```bash
zig build test262-smoke --summary all
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
- During the current large refactor, do not automatically run the full
  `zig build test --summary all` suite after every edit. Use the cheapest
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
  shapes, IC storage, and GC:
  `src/core/`.
- Lexer, parser, source positions, and TypeScript erasure: `src/parser.zig`.
- Bytecode emission, scopes, module metadata, inline-cache slots, and pipeline
  passes: `src/bytecode.zig`.
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
- `zig build test --summary all` at a checkpoint or before handoff when the
  change is code-bearing and broad enough to justify the cost; otherwise record
  the focused validation that covers the change.
- `zig build test -Doptimize=ReleaseSafe --summary all` (run ONLY once as a final pre-commit/pre-push gate verification).
- `git diff --check` passes.
- No noisy logs, temporary debug output, or unrelated build noise were added.
