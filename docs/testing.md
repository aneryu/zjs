# Testing Strategy and Practices

This document defines how `fun` approaches testing at every stage of development.
It is the single source of truth for test philosophy, current practices, and the
evolution from scaffold tests to full integration and conformance coverage.

## Philosophy

- **Host vs language separation**: `fun` tests product/host behavior (CLI, resolver,
  loader, diagnostics, host APIs, REPL loop). JavaScript and TypeScript semantics
  (ECMAScript compliance, TypeScript lowering) are validated primarily through
  `zjs` (test262 and its own suite).
- **Explicit placeholders are tested**: Every deferred boundary (`runtime`,
  `repl`, `bundler`, etc.) must have a test that asserts the precise
  `NotImplemented` error. This makes the scaffold self-documenting and prevents
  accidental partial implementations.
- **Deterministic diagnostics**: All error paths and exit codes must be easy to
  test and snapshot. Avoid hidden global state that makes tests order-dependent.
- **No claims without evidence**: Do not document or advertise Node/Bun
  compatibility, TypeScript support, or feature completeness until covered by
  focused local tests or a documented conformance slice.
- **Small, focused tests**: One behavior per test. Prefer table-driven or clear
  `expectEqual` / `expectError` patterns following Zig 0.16.0 stdlib style.

## Current State (Scaffold / M0–M2)

All tests today are **inline Zig `test` blocks** colocated with the code they
verify:

- `src/main.zig`, `src/root.zig`, and every `src/*/root.zig` (new layered locations
  under `primitives/`, `js/`, `runtime/vm/`, `tooling/*`, etc.) contain their own tests.
- Future integration and engine-contract tests will live under the `tests/` hierarchy
  described in `fun_zjs_subtree_architecture.md` §15 once real execution lands.
- Typical patterns:
  - Reachability / facade tests (`root.zig`)
  - Command parsing and special flags (`cli`)
  - Classification functions (`core.detectModuleKind`, `resolver.classifySpecifier`)
  - Placeholder error assertions for every `NotImplemented` surface
  - Pipeline composition tests that exercise the explicit placeholder chain
- Execution: `zig build test` (runs both library module tests and executable tests).
- Formatting gate: `zig fmt --check build.zig src` must pass before any handoff.

No separate `test/` directory or external fixture runner exists yet. This is
intentional while the host pipeline is still being built.

See the "pipeline placeholders are explicit" test in [root.zig](../src/root.zig) for
the canonical example of how deferred components are kept honest.

## MVP Testing Requirements (M3–M4 Target)

Detailed acceptance tests for the first usable runtime surface are recorded in
[runtime-mvp.md](runtime-mvp.md#testing-and-validation). In summary:

**Unit / Parsing Tests (already partially present)**
- CLI command model (`fun`, `fun <file> [...args]`, `--help`, version, rejection of
  `run`/`eval`/`repl` as subcommands).
- Source kind detection for all documented extensions (JS, TS, JSX, JSON, etc.).
- Specifier classification (relative, absolute, `node:`, bare package rejection).

**CLI Fixture / Integration Tests (planned for M3)**
- REPL entry with stdin/EOF.
- File execution with script arguments surfaced via `process.argv`.
- Local ESM imports and basic `node:fs` / `node:fs/promises` behavior.
- Clear `unsupported_source_kind` for TypeScript entry points during MVP.
- Stable exit codes and structured diagnostics for error cases.

**zjs Integration Smoke Tests (M4)**
- Context creation/teardown through the `src/runtime` adapter only.
- REPL inputs reuse a single persistent context.
- Runtime errors become `fun` diagnostics (not raw `zjs` strings).
- Host APIs (`console`, `process`, timers, fs subset) are registered and visible.
- Jobs / microtasks are pumped after evaluation.

These fixture tests will live alongside the Zig unit tests once the
infrastructure is added (see Near-Term Backlog in roadmap.md).

## Conformance and Language Semantics

- ECMAScript behavior: Prefer test262-compatible results. Any deliberate
  deviations must be documented.
- `zjs` owns the test262 gate and its own language test surface. `fun` does not
  duplicate JS semantics tests.
- TypeScript execution (M5+): Tests focus on erasure/lowering producing correct
  JS runtime behavior and clear diagnostics for unsupported syntax. Type warm-up
  is an optimization and must be covered by performance or debug tests, never
  by changing observable semantics.
- Future compatibility suites (selected Bun/Node tests, product smoke suites)
  will be added only after the runtime MVP is stable and will be tracked in the
  roadmap Open Questions and milestone acceptance criteria.

## Rules for Adding Tests

1. Every new public function or observable behavior in `cli`, `core`, `resolver`,
   `loader`, `runtime`, or `repl` requires at least one focused test in the same
   file.
2. When a component is still an explicit placeholder, add (or keep) a test that
   asserts the exact error (example: `expectError(error.ReplNotImplemented, ...)`).
3. Diagnostics and exit-code mapping must be exercised in tests.
4. Before any code or documentation handoff:
   - `zig build test`
   - `zig fmt build.zig src`
5. When real file execution or loader I/O lands, migrate relevant tests toward
   fixture style while keeping fast unit tests for pure functions.
6. Update the "Current Implementation Status" matrix in [roadmap.md](roadmap.md)
   when a layer's test posture meaningfully advances (e.g., from "scaffold + tests"
   to having real execution coverage).

## Diagnostics Testing

Diagnostics are a first-class product surface. Tests should cover:
- All documented diagnostic kinds (`usage_error`, `file_not_found`,
  `unsupported_source_kind`, `resolve_error`, `runtime_error`, etc.).
- Presence of path / line / column / source kind where applicable.
- Stable exit-code mapping (0 success, 1 runtime/host, 2 usage, 3 load/resolve).
- REPL vs file-execution control flow differences (REPL continues on recoverable
  errors; file execution exits).

Prefer matching on structured fields over fragile string output when the
diagnostic type is available.

## Relationship to Other Documents

- [AGENTS.md](../AGENTS.md#testing-expectations) — non-negotiable contributor rules.
- [runtime-mvp.md](runtime-mvp.md#testing-and-validation) — concrete MVP unit,
  fixture, and smoke test lists + acceptance criteria.
- [roadmap.md](roadmap.md) — "Tests" tradeoff row, "Add fixture test infrastructure"
  backlog item, per-milestone acceptance criteria that include test requirements.
- [docs/README.md](README.md#documentation-handoff-checklist) — mandatory steps
  before merging changes that touch implementation or design.
- [zjs-integration.md](zjs-integration.md#validation-plan) — validation obligations
  on both sides of the embedding boundary.

## Planned Fixture Layout (M3+)

When real execution and loader work begins, we will introduce fixture-style
integration tests. The expected structure is:

```
test/
  fixtures/
    cli/                 # end-to-end CLI behavior (REPL, file execution, args)
    resolver/            # resolution cases (relative, node:, errors)
    loader/              # file loading, JSON, source kind edge cases
    diagnostics/         # golden files for error output and exit codes
    host/                # host API surface (console, process, fs subset, timers)
```

- Each fixture directory will contain small, self-contained cases.
- Where output is deterministic, we will use golden-file / snapshot testing.
- These tests will be driven from Zig test blocks or a small test runner (TBD).
- See `docs/runtime-mvp.md` for the initial list of required CLI fixtures.

This layout will be created only when the first real file execution path lands.

## Evolution

As the project moves through M3 (CLI/loader/resolver) and M4 (first `zjs`
execution), this document will be updated with:
- Location and format of CLI fixture tests.
- How host API surface tests are organized.
- Any snapshot or golden-file conventions adopted for diagnostics and REPL output.

Keep the "current vs future" distinction explicit so readers always know what
infrastructure actually exists today.

---

All tests are versioned with the source. Untested behavior is undocumented behavior.