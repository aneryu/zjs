# AGENTS.md

## Project

zjs is a **JavaScript / TypeScript engine written in Zig**. ECMA-262 defines
JavaScript semantics; test262 validates the configured compatibility profile.
QuickJS is a differential reference and performance yardstick, not an
implementation constraint. Follow the spec and record reference divergences.

TypeScript runs through native parsing, type erasure, and supported syntax
lowering. Type checking is outside scope; see [LIMITATIONS.md](LIMITATIONS.md).

## Working agreements

- Inspect the branch/worktree, `git status`, and relevant diff before editing.
  Preserve pre-existing changes; keep edits and staging within the task.
- Complete authorized edits and validation without repeatedly asking for
  confirmation. Resolve routine implementation choices yourself; clarify
  ambiguity that materially changes scope, public contracts, or irreversible
  actions. Review/diagnosis alone does not authorize implementation.
- Commit, merge, and push only when authorized; one does not imply the others.
- For bugs, reproduce before editing and identify the owning subsystem. For
  semantic changes, retain focused differential evidence and the spec basis.
- Fix the general mechanism and implied edge cases with a focused change.
  Add regression coverage for new behavior or invariants.
- Finish with the outcome, relevant validation results, and unresolved work.
  Distinguish passed, failed, interrupted, and unrun checks.

## Zig Code Editing

When modifying Zig code, prioritize correctness, minimal context usage, and
small, auditable changes.

### Tool priority

1. Prefer ZLS for semantic navigation: find symbols, go to definition, find
   references, inspect symbol/type information, and inspect diagnostics when
   useful.
2. Use text search (`rg` / `search`) when ZLS cannot resolve the symbol, when
   searching strings, comments, build files, generated names, or non-Zig files,
   or when semantic lookup is unnecessary.
3. Read only the smallest relevant source ranges. Do not read entire files
   unless required.
4. Use `apply_patch` for modifications to existing files. Avoid whole-file
   rewrites.
5. After every meaningful Zig code change, validate with the mise-managed Zig
   toolchain: run `zig fmt` on changed Zig files and relevant tests (`zig test`
   where standalone, or the project's targeted test task). Run `zig build
   check` during iteration and one final `zig build test`, with additional
   builds when applicable, following the verification policy below.

### ZLS usage

Use ZLS primarily as a semantic read/navigation tool. Prefer:

`ZLS symbol lookup → definition/references → ranged source read`

over:

`grep → large file read → manual symbol discovery`

Do not assume ZLS is the final authority on whether code is correct. Zig
compiler and test results are authoritative. Do not blindly apply large
workspace edits.

## Verification

Read [verification-policy](docs/verification-policy.md) before implementation.
It is the sole authority for verification obligations, including exceptions
and retired gates. Command details live in [GUIDE.md](GUIDE.md) Part B.6.

| Change | Validation scope |
| --- | --- |
| Prose-only documentation | Check facts, local links/anchors, and `git diff --check` |
| Implementation | `zig build check`, targeted tests, then one final `zig build test` |
| Runner / test262 | Also run the relevant fixture or focused test262 slice |
| Merge batch / release | Run the policy's aggregate gates once at that boundary |

Preserve command exit status (`pipefail` for pipelines). Empty selections,
missing corpus, and partial output do not establish a pass. Debug is the
iteration default; shipped builds use `-Doptimize=ReleaseFast`, `layout=short`,
NaN-boxed `JSValue`, and `force_gc` / `ownership_audit` off.

## Engineering constraints

- Use Zig 0.16.0 and the ownership, error, and style rules in GUIDE Part A.
- Preserve public API/ABI unless the task requires a change. Keep host, CLI,
  test262, and event-loop policy out of `src/core/`.
- Preserve validation, error handling, security checks, and GC safety nets.
  Values surviving a host call must follow the public handle contract.
- Never manufacture a pass with hardcoded answers, fixture/benchmark-specific
  logic, weakened tests, broader excludes, or altered failure records.
- Do not hide errors with empty catches, broad mocks, or type/lint suppression.
  `catch unreachable` requires a proven safety argument.
- User-visible throws use `throw*Message` helpers; bare `error.XxxError` is
  allowed only when its message is attached elsewhere or the path is
  unreachable by user code.

## Read when relevant

Read the sections needed for the task; following a link does not require
loading every document it references.

| Task | Reference |
| --- | --- |
| Zig implementation / test commands | [GUIDE.md](GUIDE.md), Parts A / B.6 |
| Find source owners or change layer boundaries | [Architecture](docs/architecture.md) |
| Public API, embedding, or host lifetimes | [Public API contract](docs/public-api-contract.md) |
| GC edges, roots, or finalization | [GC invariants](docs/gc-invariants.md) |
| Compiler layout | [Compiler contract](docs/compiler-contract.md) |
| Performance investigation | [GUIDE](GUIDE.md#b8-performance-investigation), [verification policy](docs/verification-policy.md) |
| Other documentation | [Documentation index](docs/README.md) |

Entry points: `src/root.zig` exports `zjs`; `src/parser.zig` parses;
`src/compiler/` compiles; `src/core/` owns values/runtime/GC; `src/exec/`
executes. Unit tests live beside the code; integration tests use `tests/`.

Put scratch artifacts, issues, and PRDs in this worktree's `.scratch/<feature>/`,
not bare `/tmp` filenames. For an empty test262 submodule in a linked worktree,
use `mise run worktree-init` and keep its corpus symlink out of commits.
Keep evidence with the owning change; add no broad status ledgers unless asked.
