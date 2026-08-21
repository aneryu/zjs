# Production v1 Release Checklist

Use this checklist for an engine-only Production v1 release decision.

`zig build engine-production-gate --summary all` is the semantic and
architecture gate. It is required release evidence, but it does not replace the
ReleaseSafe, hygiene, and performance checks below.

`mise run quick-gate` and `mise run checkpoint-gate` are iteration and handoff
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

- `zig build engine-production-gate --summary all` passes from a clean
  checkout; it includes the unified Debug suite, ReleaseFast CLI smoke,
  architecture lints (including the ReleaseFast compiler-stage `nm` check),
  OOM-cap coverage, and the full test262 gate.
- `zig build test -Doptimize=ReleaseSafe --summary all` passes once as
  the optimized-loop safety gate.
- Focused test262 slices were run for every changed semantic area.

## Boundary

- Architecture lints pass as part of `engine-production-gate`, including
  dependency rules.
- `docs/security-boundary.md` is accurate for the release.
- `COMPATIBILITY.md` and `LIMITATIONS.md` do not overclaim.
- Release notes state that the engine is trusted-code only.

## Artifacts

- Release tarballs carry a **stripped** `zjs`. `.github/workflows/nightly.yml`
  runs `strip` (plus `codesign -s -` on arm64 macOS, which `strip` invalidates)
  before the configuration-signature check, so the check runs against the exact
  bytes shipped and a broken strip fails the release rather than the user.
- Stripping is post-link on purpose: it leaves `.text` and the
  `.text.zjs.op_handlers` island byte-identical to the binary the gates
  measured. Building with `-fstrip` instead moves `.text` by 40 bytes, which
  would ship a layout the performance gate never measured.
- Reproduce a release artifact locally with `zig build zjs && strip
  zig-out/bin/zjs`. Do not strip a binary you intend to profile: `nm`,
  `addr2line`, and `perf` attribution all need the symbols, which is why no
  build step strips by default.
- Shipped ReleaseFast binaries panic with the message only, no stack trace
  (`src/cli/panic_policy.zig`). A stripped binary cannot symbolize a trace
  anyway; `zjs-dev` and every test artifact keep the full handler.

## Hygiene

- `git diff --check` passes.
- A performance-sensitive release carries local benchmark evidence recorded in
  the PR or release notes; see `docs/perf/README.md` for the measurement
  contract. Performance steps never run in CI.
- No temporary debug output, generated noise, or unrelated refactors are in the
  release diff.
- Non-trivial validation evidence is in the PR, issue, or release notes.
