# Production v1 Release Checklist

Use this checklist for an engine-only Production v1 release decision. The
broader roadmap is tracked in
[production-grade-plan.md](production-grade-plan.md).

## API

- Public Zig API matches `docs/adr/0001-zig-kernel-api-and-runtime-boundary.md`.
- Ownership-bearing values have documented free paths.
- Error-set changes are recorded in release notes.
- No public API was removed without a migration note.

## Lifecycle

- Runtime/context init, eval, and deinit run cleanly under Zig leak detection.
- OOM paths used by public embedding APIs have focused tests.
- Interrupt-handler behavior is covered by a regression test.

## Compatibility

- `zig build test --summary all` passes.
- `zig build test -Doptimize=ReleaseSafe --summary all` passes.
- `zig build smoke --summary all` passes.
- `zig build test262-gate --summary all` passes with the checked-in config.
- Focused test262 slices were run for every changed semantic area.

## Boundary

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
