# Production v1 Release Checklist

Use this checklist for an engine-only Production v1 release decision.

`zig build engine-production-gate --summary all` is the semantic and
architecture gate. It is required release evidence, but it does not replace the
ReleaseSafe, hygiene, and performance checks below.

`zig build quick-check --summary all` and `zig build checkpoint-check --summary
all` are iteration and handoff shortcuts. They are useful before starting the
release sweep, but they are not release evidence replacements.

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

- `zig build checkpoint-check --summary all` passes before the final release
  sweep starts.
- `zig build test --summary all` passes.
- `zig build test -Doptimize=ReleaseSafe --summary all` passes.
- `zig build smoke --summary all` passes.
- `zig build test262-gate --summary all` passes with the checked-in config.
- `zig build engine-production-gate --summary all` passes from a clean
  checkout.
- Focused test262 slices were run for every changed semantic area.

## Boundary

- `zig build architecture-check --summary all` passes, including dependency
  rules and public API snapshot validation.
- `docs/security-boundary.md` is accurate for the release.
- `COMPATIBILITY.md` and `LIMITATIONS.md` do not overclaim.
- Release notes state that the engine is trusted-code only.

## Hygiene

- `git diff --check` passes.
- `zig build perf-self-check --summary all` passes when the release includes
  performance-sensitive runtime changes.
- No temporary debug output, generated noise, or unrelated refactors are in the
  release diff.
- Non-trivial validation evidence is in the PR, issue, or release notes.
