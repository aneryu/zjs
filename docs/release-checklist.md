# Production v1 Release Checklist

Use this checklist for an engine-only Production v1 release decision.

`zig build engine-production-gate --seed 0 --summary all` is the semantic and
architecture gate. It is required release evidence, but it does not replace the
ReleaseSafe, hygiene, and performance checks below.

`mise run quick-check` and `mise run checkpoint-check` are iteration and handoff
shortcuts. Do not rerun them as prerequisites for the aggregate release gate.

## API

- Public Zig API matches `docs/public-api-contract.md`.
- Public embedding cookbook examples compile and pass through
  `src/tests/embedding_examples.zig`.
- Public NativeBinding and runtime Plugin failure paths preserve host-owned
  state and leave no half-installed public binding.
- Ownership-bearing values have documented free paths.
- Error-set changes are recorded in release notes.
- No public API was removed without a migration note.

## Lifecycle

- Runtime/context init, eval, and deinit run cleanly under Zig leak detection.
- Public handle lifetime is covered by production tests: local handle scopes
  release at scope exit, and persistent handles keep host-held values alive
  across scopes.
- Memory-limit / OOM paths used by public embedding APIs have focused tests
  that return `error.OutOfMemory` without leaving pending host-owned values.
- Interrupt-handler behavior is covered by a production regression test.

## Compatibility

- `zig build engine-production-gate --seed 0 --summary all` passes from a clean
  checkout; it includes the unified Debug suite, ReleaseFast CLI smoke,
  architecture checks, OOM-cap coverage, and the full test262 gate.
- `zig build test -Doptimize=ReleaseSafe --seed 0 --summary all` passes once as
  the optimized-loop safety gate.
- Focused test262 slices were run for every changed semantic area.

## Boundary

- `zig build architecture-check --seed 0 --summary all` passes, including
  dependency rules and public API snapshot validation.
- `docs/security-boundary.md` is accurate for the release.
- `COMPATIBILITY.md` and `LIMITATIONS.md` do not overclaim.
- Release notes state that the engine is trusted-code only.

## Hygiene

- `git diff --check` passes.
- `zig build perf-self-check --seed 0 --summary all` passes when the release
  includes performance-sensitive runtime changes.
- No temporary debug output, generated noise, or unrelated refactors are in the
  release diff.
- Non-trivial validation evidence is in the PR, issue, or release notes.
