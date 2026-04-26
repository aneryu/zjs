# Code Review

Date: 2026-04-26

## Scope And Baseline

This review targets the current working tree, including uncommitted changes and
untracked files. The reviewed project code includes `src/`, `tests/`,
`tools/`, `build.zig`, `build.zig.zon`, and the redesign documentation. The
vendored `quickjs/` tree is treated as the semantic reference, not as code to
review.

The current worktree contains implementation changes in the VM, parser, bignum,
core value/object ownership, tests, and redesign docs. The largest risk areas
are:

- `src/engine/exec/vm.zig`
- `src/engine/frontend/parser.zig`
- `src/engine/libs/bignum.zig`
- `src/tools/test262_runner.zig`
- build/test wiring

## Executive Summary

No critical issue was found. The original review found high-impact
DataView/ArrayBuffer correctness gaps and validation wiring gaps; those findings
have been fixed in the current working tree.

Current post-fix validation passes `zig build test --summary all` with 132/132
tests, including the direct `src/tools/test262_runner.zig` tests that were
previously only covered by `zig build test-tools`.

## Remediation Update

Fixed after review:

- H-001: `DataView#setUint32` now uses unsigned 32-bit coercion and no longer
  aborts on `4294967295`.
- H-002: `ArrayBuffer.prototype.slice` now uses `start`/`end` and copies bytes
  from the source buffer.
- M-001: `DataView#setBigInt64` and `setBigUint64` are wired through parser and
  VM execution.
- M-002: aggregate `zig build test` now includes direct test262 runner
  self-tests.
- M-003: `build.zig.zon` package paths now include the local `quickjs`
  reference tree.

## Findings

### Critical

None found.

### High

#### H-001: `DataView#setUint32` could abort the process for valid uint32 input

Status: fixed in the current working tree.

Location: `src/engine/exec/vm.zig:1057`, `src/engine/exec/vm.zig:2456`

At review time, `dataViewSet` converted all 32-bit writes through `valueToInt32`, and
`valueToInt32` uses `@intFromFloat` into `i32`. Valid `setUint32` values above
`std.math.maxInt(i32)` therefore panic instead of applying ECMAScript
ToNumber/ToUint32 semantics.

Reproduction:

```bash
./zig-out/bin/zjs -e 'const ab = new ArrayBuffer(4); const dv = new DataView(ab); dv.setUint32(0, 4294967295); print(dv.getUint32(0));'
```

Original observed result: process aborts with `integer part of floating point value out
of bounds`, exit 134.

Expected QuickJS behavior:

```text
4294967295
```

Impact: a valid JavaScript program can terminate the host process. This is more
severe than returning a JS exception because it bypasses normal error handling.

Recommended fix: split numeric conversion helpers by target coercion. Use an
explicit ToUint32 path for `setUint32`, ToInt32 for `setInt32`, and byte-width
masking/truncation for smaller integer setters. Add tests for `4294967295`,
`2147483648`, `-1`, `NaN`, and fractional values.

Suggested validation:

- `zig build test-exec --summary all`
- `zig build smoke --summary all`
- targeted DataView test262 slice

#### H-002: `ArrayBuffer.prototype.slice` ignored `start` and did not copy bytes

Status: fixed in the current working tree.

Location: `src/engine/exec/vm.zig:967`

At review time, `arrayBufferSlice` popped `end`, `start`, and the source buffer, but used `end` as
the new buffer length, ignores `start`, and zero-fills the result instead of
copying the selected byte range from the source ArrayBuffer.

Reproduction:

```bash
./zig-out/bin/zjs -e 'const ab = new ArrayBuffer(4); const dv = new DataView(ab); dv.setUint8(0, 65); dv.setUint8(1, 66); const sliced = ab.slice(1, 3); const sdv = new DataView(sliced); print(sliced.byteLength); print(sdv.getUint8(0)); print(sdv.getUint8(1));'
```

Original observed result:

```text
3
0
0
```

Expected QuickJS behavior:

```text
2
66
0
```

Impact: any code relying on sliced binary data sees incorrect length and
contents. This also weakens DataView validation because slice can create a
plausible-looking but zeroed buffer.

Recommended fix: implement ArrayBuffer slice using normalized `start` and `end`
indices, allocate `end - start` bytes, and copy from source
`byte_storage[start..end]`. Include negative/clamped index behavior only if the
frontend can currently parse those cases; otherwise cover the supported
positive-index path now and track the rest.

Suggested validation:

- focused exec tests for slice content and byteLength
- `zig build test-exec --summary all`
- `zig build smoke --summary all`

### Medium

#### M-001: BigInt DataView setters were missing

Status: fixed in the current working tree.

Location: `src/engine/frontend/parser.zig:3782`,
`src/engine/exec/vm.zig:1057`

At review time, the parser recognized `getBigInt64` and `getBigUint64`, but
`dataViewSetKind` only recognizes setters through `setFloat64`. The VM
`dataViewSet` switch also handles only setter kinds 1 through 8. As a result,
`setBigInt64` and `setBigUint64` fall through to unsupported/generic behavior
even though the corresponding getters exist.

Reproduction:

```bash
./zig-out/bin/zjs -e 'const ab = new ArrayBuffer(8); const dv = new DataView(ab); dv.setBigInt64(0, -1n); print(dv.getBigInt64(0));'
```

Original observed result:

```text
zjs: evaluation failed: UnsupportedOpcode
```

Expected QuickJS behavior:

```text
-1
```

Impact: the DataView BigInt API is only half implemented. This contradicts the
current docs claiming completed DataView/BigInt hardening and leaves test262
coverage with a blind spot.

Recommended fix: add parser kinds for `setBigInt64` and `setBigUint64`; in the
VM, coerce the value through the BigInt path, write signed/unsigned 64-bit
two's-complement bytes with requested endianness, and add round-trip tests for
`-1n`, `0n`, `2n ** 63n - 1n`, and `2n ** 64n - 1n`.

Suggested validation:

- focused exec tests for BigInt DataView setters/getters
- targeted DataView test262 slice
- targeted BigInt test262 slice

#### M-002: `zig build test` did not run the direct test262 runner tests

Status: fixed in the current working tree.

Location: `build.zig:210`

`test-tools` depends on both `run_tools_tests` and
`run_test262_runner_tests`, but the aggregate `test` step only depends on
`run_tools_tests`. At review time:

- `zig build test --summary all` reports 115/115 tests.
- `zig build test-tools --summary all` reports 26/26 tests, including 17 direct
  tests from `src/tools/test262_runner.zig`.

After remediation, `zig build test --summary all` reports 132/132 tests.

Impact: the primary regression command misses runner coverage for known-error
classification, metadata parsing, feature skipping, and timeout behavior. A
runner regression can pass `zig build test` and only fail when `test-tools` is
run explicitly.

Recommended fix: make the aggregate `test` step depend on
`run_test262_runner_tests`, or depend on the `test-tools` step's complete set of
run artifacts. Keep the summary counts in `TRACKING.md` aligned after the build
graph changes.

Suggested validation:

- `zig build test --summary all` should include the extra runner tests.
- `zig build test-tools --summary all`

#### M-003: Package paths omitted the local QuickJS reference used by tests

Status: fixed in the current working tree.

Location: `build.zig.zon:7`, `src/tests/bytecode/all.zig:11`

At review time, `build.zig.zon` included `src`, `tests`, `tools`, and docs, but did not include
`quickjs/`. The bytecode tests read `quickjs/quickjs-opcode.h` at runtime, and
the runner/tooling paths also assume local `quickjs/test262.conf` and test262
layout.

Impact: a package built from `.paths` can omit files required by the documented
test and validation flow. This is a clean-package/reproducibility issue rather
than a local checkout issue.

Recommended fix: either include the minimal QuickJS reference files needed by
tests and tooling in `.paths`, or split package tests so source-reference tests
are disabled/explicit when the QuickJS tree is absent. The current project
purpose suggests including the reference files is the safer default.

Suggested validation:

- run package/archive smoke if supported by the local Zig version
- `zig build test-bytecode --summary all` from a clean packaged checkout

### Low

#### L-001: VM and parser are carrying large transitional semantic surfaces

Location: `src/engine/exec/vm.zig`, `src/engine/frontend/parser.zig`

`vm.zig` is over 3,000 lines and `parser.zig` is over 4,000 lines. Both contain
many narrow recognizers and direct semantic helpers for smoke/test262 cases. The
current gates pass, but this shape makes it easy for narrow support to look like
general ECMAScript support.

Impact: future compatibility work will be harder to review and more likely to
introduce hidden precedence, coercion, or ownership bugs.

Recommended fix: do not refactor this immediately in the same patch as semantic
fixes. Instead, after fixing the concrete DataView/ArrayBuffer issues, split
future work by semantic owner: numeric coercion helpers, ArrayBuffer/DataView,
BigInt operations, and parser lowering. Each split should preserve current
targeted tests.

## Architecture Review

The repository structure matches the redesign plan at a high level: core values
and ownership live under `core`, parsing/lowering under `frontend` and
`bytecode`, execution under `exec`, and validation tooling under `src/tools`.
The source mapping discipline is useful and should stay.

The main architectural concern is that several runtime domains are still
implemented as narrow VM/parser special cases rather than reusable semantic
operations. DataView and BigInt now have enough behavior that ad hoc conversion
inside `vm.zig` is becoming risky. The `setUint32` abort is a direct symptom:
the same helper is used for signed and unsigned cases with different required
coercions.

## Test Coverage Review

Strong coverage:

- Aggregate Zig tests pass.
- Smoke coverage is broad and currently 45/45.
- `test-tools` covers runner behavior beyond the aggregate test target.
- Recent targeted test262 slices are recorded for BigInt, DataView, String, and
  language expressions.

Coverage gaps found during review:

- ArrayBuffer slice content/length was missing; focused exec coverage has been
  added.
- DataView unsigned setter boundary coverage was missing; `setUint32` coverage
  for `4294967295` and `-1` has been added.
- DataView BigInt setter coverage was missing; `setBigInt64` and `setBigUint64`
  round-trip coverage has been added.
- Aggregate `zig build test` did not include direct test262 runner tests; the
  aggregate target now includes them.

## Documentation And Tooling Review

The redesign docs reflect the completed Phase 9 state and archive superseded
Phase 8 validation evidence. The review-identified DataView/BigInt caveat has
been resolved by wiring `setBigInt64` and `setBigUint64`.

The build graph has been tightened so the documented pre-commit command runs
the direct test262 runner self-tests as part of aggregate `zig build test`.

## Fix Batches

1. Fixed DataView numeric coercion and BigInt setters.
   Add explicit ToInt/ToUint helpers, wire BigInt setters, and add boundary
   tests.

2. Fixed ArrayBuffer slice.
   Implement correct positive-index copy semantics first, then expand toward
   full ECMAScript start/end normalization as parser support allows.

3. Fixed validation wiring.
   Add direct runner tests to aggregate `zig build test`; update tracking
   counts after the change.

4. Fixed package reproducibility.
   Include required QuickJS reference files in package paths or make
   QuickJS-dependent tests explicitly conditional.

5. Open architectural follow-up: continue semantic decomposition.
   Extract shared ArrayBuffer/DataView and numeric conversion helpers in a
   dedicated refactor after this correctness patch. This is not required to
   close the concrete review findings.

## Validation Run

Commands run during review:

```bash
zig build test --summary all
zig build smoke --summary all
zig build test-core --summary all
zig build test-bytecode --summary all
zig build test-frontend --summary all
zig build test-exec --summary all
zig build test-builtins --summary all
zig build test-tools --summary all
./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/DataView 0 5000
./zig-out/bin/run-test262 -t 8 -c quickjs/test262.conf -d quickjs/test262/test 0 100000
git diff --check
```

Results:

- `zig build test --summary all`: 132/132 passed.
- `zig build smoke --summary all`: 45/45 scripts passed.
- `zig build test-core --summary all`: 32/32 passed.
- `zig build test-bytecode --summary all`: 6/6 passed.
- `zig build test-frontend --summary all`: 21/21 passed.
- `zig build test-exec --summary all`: 39/39 passed.
- `zig build test-builtins --summary all`: 4/4 passed.
- `zig build test-tools --summary all`: 26/26 passed.
- DataView targeted test262 slice: 561/561 passed after remediation.
- Full local test262 gate: `Result: 0/48205 errors, passed 42200`.
- `git diff --check`: passed.

Full test262 was rerun after remediation.
