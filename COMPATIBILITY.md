# Compatibility and Validation

`zjs` does not claim general ECMAScript completeness beyond the repository-local
validation profile. The compatibility boundary is the root `test262.conf`
configuration plus focused Zig and smoke tests.

## Test262 Gate

Active configuration:

- Config: `test262.conf`
- Harness: `test262/harness`
- Tests: `test262/test`
- Known-error file: `test262_errors.txt`
- Latest report directory: `reports/test262-latest/`

Run the gate through Zig:

```sh
zig build test262-gate --summary all
```

Or invoke the runner directly:

```sh
zig build run-test262 --summary all
./zig-out/bin/run-test262 -t 8 -c test262.conf -d test262/test 0 100000
```

As currently tracked, the gate has no unexpected failures and no checked-in
known failures. The latest local run selected 49,671 tests from 53,292 total
tests, excluded 3,621 by config, skipped 5,225 by feature, and reported
`0/49,671` errors with 44,446 passing tests. `test262_errors.txt` is currently
empty.

## Configured Skips and Excludes

The following are intentionally outside the active gate unless the config is
changed with a concrete implementation plan:

- `test262/test/intl402/` is excluded. Intl requires data and API surface that
  are outside the current core-engine target.
- Test262 features marked `=skip` include `Temporal`, `ShadowRealm`,
  `decorators`, `tail-call-optimization`, `host-gc-required`, `import-defer`,
  source-phase imports, canonical time zone data, duplicate RegExp named
  groups, and the Intl feature groups listed in `test262.conf`.
- Generated RegExp string-property and UnicodeSets cases that still exceed the
  current parity boundary are excluded individually.
- Most `test262/test/staging/` tests are excluded by default, with selected
  locally useful staging slices re-included. Known SpiderMonkey staging
  divergences remain explicitly excluded or tracked in `test262_errors.txt`
  when the selected path stays useful in the gate.

Do not broaden skips or excludes to manufacture a green gate. Any change to the
compatibility boundary needs a failing scenario, QuickJS reference evidence,
and an exit criterion.

## Local Test262 Overrides

The runner checks `tests/fixtures/test262-overrides/` before reading a selected
file from the `test262/` submodule. Overrides are allowed only for narrow
upstream source contradictions where the selected test path should stay in the
gate but the checked-in upstream source is internally inconsistent with another
enabled upstream harness or feature.

Overrides must not be used for engine failures. They must keep the original
test path selected, avoid changes to `test262_errors.txt`, and be removed when
the upstream test262 source is corrected.

## Supported Areas Under Active Validation

The local gate currently enables and validates broad ES language coverage,
including modules, async functions, async iteration, BigInt, typed arrays,
Proxy/Reflect, classes and private fields, iterator helpers, explicit resource
management, JSON parse source context, promise combinators, Set methods,
RegExp match indices/modifiers/escape/property escapes, and modern Array,
String, Object, and Promise additions listed in `test262.conf`.

Additional smoke fixtures in `src/tests/smoke_test.zig` cover CLI behavior,
QuickJS parity markers, host module behavior, and targeted regressions that are
faster to run than the full test262 gate.

## Comparison With Upstream QuickJS

While `zjs` targets semantic parity with QuickJS, its local validation profile
enables and validates several features that are skipped or unsupported in
upstream QuickJS:

- **Atomics.waitAsync**: Fully supported and validated in `zjs` (including engine-deinit cleanup validation), whereas upstream QuickJS lists this as unsupported and skips it.
- **Other Enabled Features**: Features like `await-dictionary`, `legacy-regexp`, `nonextensible-applies-to-private`, and `regexp-modifiers` are enabled and validated in `zjs` but skipped in upstream QuickJS.
- **Import Bytes**: Both `zjs` and upstream QuickJS validate binary module imports (`import-bytes`).

## Validation Commands

Common checks:

```sh
zig build test --summary all
zig build smoke --summary all
git diff --check
```

For execution, parser, runner, or semantic compatibility work, add the relevant
test262 slice. Examples:

```sh
./zig-out/bin/run-test262 -t 8 -c test262.conf -d test262/test/built-ins/RegExp
./zig-out/bin/run-test262 -t 8 -c test262.conf -d test262/test/language/expressions
```

For behavior parity outside test262, add a focused Zig or smoke regression and
record the QuickJS reference evidence with the owning change.

## Production v1

The engine-only Production v1 compatibility target is QuickJS parity within the
repository validation profile. Required gates from a clean checkout:

```sh
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build test262-gate --summary all
zig build engine-production-gate --summary all
git diff --check
```

The `engine-production-gate` build step is the top-level engine release gate and
must pass before cutting a Production v1 release. Its sub-gates include
semantic tests, smoke coverage, test262, public API snapshot validation, and
architecture dependency checks; a failure in any sub-gate is release-blocking.
