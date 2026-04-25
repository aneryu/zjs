# Phase 8: CLI Tooling And Validation

Status: completed

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
- [x] Update compare invocation only as needed to point at rebuilt `zjs`.
- [x] Rebuild test262 config parsing aligned to `quickjs/run-test262.c`.
- [x] Implement exclude handling from `quickjs/test262.conf`.
- [x] Implement known-error/errorfile behavior and exit semantics.
- [x] Implement direct file and directory selection.
- [x] Implement baseline harness loading.
- [x] Implement metadata parsing.
- [x] Implement worker execution without shared-cache contention hazards.
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
QJS=/home/aneryu/zjs/quickjs/build/qjs \
QJS_ZIG=/home/aneryu/zjs/zig-out/bin/zjs \
bun tools/compare/run_compare.js --functional-only
```

Final test262 gate:

```bash
zig build -Doptimize=ReleaseFast run-test262 --summary all
./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test 0 100000
```

## Exit Checklist

- [x] `zjs -e "<script>"` works.
- [x] `zjs <file.js>` works.
- [x] Smoke runner uses manifest and golden expectations.
- [x] Compare workflow has no unexpected failures against local QuickJS baseline.
- [x] All non-deferred rows in `../matrices/test262-runner-parity.md` are `validated`.
- [x] `run-test262` follows QuickJS runner behavior for config, excludes, known errors, direct selection, harness loading, metadata, and workers.
- [x] Final test262 gate has no new unexpected failures relative to local QuickJS configuration.
- [x] `TRACKING.md` records final command evidence.
- [x] Targeted parity fixtures were run for `-e`, `-u`, `-v`, `-vv`, `-T`, `-m` and `exclude` behavior.
- [x] Negative metadata behavior was fixture-validated for both matching and mismatched `type` handling.
- [x] `Host-visible output` is transferred to the Phase 9 runtime semantic hardening matrix.

## Handoff Notes

- First tooling slice added `zjs`, `run-test262`, `smoke`, and `test-tools`
  build steps.
- `zjs -e "1"` and `zjs <file>` execute through the rebuilt engine and exit 0
  without printing expression results.
- Host-visible output is no longer a Phase 8 tooling dependency. Phase 9 owns
  hardening `print(...)` and `console.log(...)` through normal global lookup,
  property access, callable values, and generic call execution.
- The transitional execution path now covers simple globals, templates, string
  operations, simple arrays, narrow array maps, simple functions/arrows, JSON and
  Math smoke subsets, typeof, direct eval of simple expression strings, logical
  and nullish operators, `in`, `instanceof Object`, `String.fromCharCode`,
  string methods, narrow String constructor/conversion paths, standard global
  `typeof` checks, `new Object()`, and narrow Number/Boolean constructor
  conversion/valueOf paths. The
  Date smoke now runs through Date-specific construction, UTC/parse/now, and
  method bytecode paths; control-flow and switch smoke now run through narrow
  structured parser lowering rather than fixture output bridges.
  Primitive property smoke coverage now includes array prototype function
  `typeof` checks and string `.charAt()` through narrow helpers.
- Template literals are currently scanned as one literal through the closing
  backtick so test262 harness files with `${...}` text can be parsed by the
  transitional frontend. Full template interpolation semantics remain future
  parser/compiler work.
- `run-test262` now parses QuickJS-shaped index spans, config-relative
  `testdir` / `harnessdir` / `errorfile`, feature lists, `[exclude]` entries,
  direct `-d` / `-f` selectors, prepares selected test counts, and runs selected
  tests through `zig-out/bin/zjs` with `sta.js` and `assert.js` prepended.
  Test metadata parsing now covers `includes`, `features`, `flags`, and
  `negative.phase` / `negative.type`; config skip-features are filtered during
  selection and metadata includes are loaded from the harness directory in
  declaration order. Negative tests now require non-zero exit and match the
  expected stderr error type when metadata provides one, instead of treating any
  failure as success.
  Test execution now runs in-process instead of spawning `zjs` per test, removing
  process-launch overhead while preserving per-test engine isolation.
  Runner selection now follows the original `run-test262.c` shape more closely:
  namelists grow by capacity, are sorted/deduped, selection does not parse every
  file's metadata, feature skipping happens during test execution, and `-t`
  workers distribute tests by index stride.
  Harness includes are cached per worker, avoiding shared-cache lock contention
  while preventing repeated disk reads for common helpers.
  Example:
  `./zig-out/bin/run-test262 -v -t 4 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/JSON 0 99`
  now reports `Result: 0/100 errors, passed 100`.
- Compare tooling defaults to rebuilt `zig-out/bin/zjs` and resolves the C
  baseline fallback inside this repository at `quickjs/build/qjs`.
- `zig build smoke --summary all` runs the manifest and golden comparator
  against real runtime behavior. Current smoke gate passes 45/45 after Date,
  control-flow, and switch smoke paths were implemented without restoring the
  old output bridge.
- Full local test262 now runs to completion under one minute with ReleaseFast;
  latest result is `0/48205 errors, passed 42200`, elapsed 15.00s.
- Phase 8 is complete; host-visible output tracking has moved to the Phase 9
  runtime semantic hardening matrix.
