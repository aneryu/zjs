# Phase 8: CLI Tooling And Validation

Status: in_progress

## Goal

Rebuild user-facing tooling on top of the new engine: `zjs`, smoke runner,
compare workflow, and test262 runner. This phase is complete only when commands
use the rebuilt engine and no deleted engine path remains in the tooling graph.

## QuickJS References

- `quickjs/qjs.c`
- `quickjs/run-test262.c`
- `quickjs/test262.conf`

## Target Files

- `src/cli/qjs.zig`
- `src/cli/run_test262.zig`
- `src/tools/smoke_runner.zig`
- `src/tools/test262_runner.zig`
- `build.zig`
- `tools/compare/*` only if invocation paths need updating

## Parity Matrix

Detailed test262 runner option and behavior tracking lives in
`../matrices/test262-runner-parity.md`. Keep targeted runner fixtures separate
from full-suite evidence.

## Work Breakdown

- [x] Rebuild `zjs -e "<script>"`.
- [x] Rebuild `zjs <file.js>`.
- [x] Implement CLI usage and non-zero exit behavior for invalid arguments.
- [x] Rebuild smoke runner against `tests/zig-smoke/manifest.txt`.
- [x] Preserve golden stdout/stderr/exit comparison behavior for smoke tests.
- [ ] Update compare invocation only as needed to point at rebuilt `zjs`.
- [ ] Rebuild test262 config parsing aligned to `quickjs/run-test262.c`.
- [ ] Implement exclude handling from `quickjs/test262.conf`.
- [ ] Implement known-error/errorfile behavior and exit semantics.
- [x] Implement direct file and directory selection.
- [ ] Implement harness loading and metadata parsing.
- [ ] Implement worker execution without shared-cache contention hazards.
- [x] Add build steps for `qjs`, `smoke`, `run-test262`, and aggregate tests.

## Validation

```bash
zig fmt .
zig build qjs --summary all
zig build smoke --summary all
zig build run-test262 --summary all
zig build test --summary all
```

Compare gate:

```bash
QJS=/Users/aneryu/zjs/quickjs/build/qjs \
QJS_ZIG=/Users/aneryu/zjs/zig-out/bin/zjs \
bun tools/compare/run_compare.js --functional-only
```

Final test262 gate:

```bash
./zig-out/bin/run-test262 -c quickjs/test262.conf -m -t 1 quickjs/test262/test
```

## Exit Checklist

- [ ] `zjs -e "<script>"` works.
- [ ] `zjs <file.js>` works.
- [ ] Smoke runner uses manifest and golden expectations.
- [ ] Compare workflow has no unexpected failures against local QuickJS baseline.
- [ ] All non-deferred rows in `../matrices/test262-runner-parity.md` are `validated`.
- [ ] `run-test262` follows QuickJS runner behavior for config, excludes, known errors, direct selection, harness loading, metadata, and workers.
- [ ] Final test262 gate has no new unexpected failures relative to local QuickJS configuration.
- [ ] `TRACKING.md` records final command evidence.

## Handoff Notes

- First tooling slice added `zjs`, `run-test262`, `smoke`, and `test-tools`
  build steps.
- `zjs -e "1"` and `zjs <file>` currently execute through the rebuilt engine and
  exit 0 without printing expression results.
- `zig build smoke --summary all` now runs the manifest and golden comparator,
  but fails 45/45 scripts because the rebuilt engine does not yet implement
  smoke-visible output such as `print(...)`; this is expected in the current
  Phase 8 in-progress state and must not be recorded as final smoke evidence.
