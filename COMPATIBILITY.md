# Compatibility and Validation

JavaScript behavior follows ECMA-262. The validated scope is the repository's
`test262.conf`, pinned `test262/` submodule, and focused Zig/CLI tests;
it is not a claim of complete ECMAScript or host-platform support.
TypeScript and host boundaries are listed in [LIMITATIONS.md](LIMITATIONS.md).

## Test262 Gate

Inputs are `test262.conf`, `test262/harness`, `test262/test`, and
`test262_errors.txt`. The known-error file is empty: the configured gate
allows no failures. Dated counts and the corpus pin live in
[STATUS.md](STATUS.md#test262); they do not validate an untested checkout.

Gate timing and commands have one authority:
[verification policy](docs/verification-policy.md), with command details in
[GUIDE Part B.6](GUIDE.md#b6-validation-tiers). Full test262 runs at the merge
batch/CI boundary. Use a focused file or directory for local diagnosis.
The runner writes local reports to `reports/test262-latest/` (gitignored).

## Configured Skips and Excludes

`test262.conf` is the exact selection. Its major exclusions include:

- `intl402/` and related Intl data/API features.
- Temporal, ShadowRealm, decorators, deferred/source-phase imports, and
  the other feature groups marked `=skip`.
- Most staging tests, with selected useful slices re-included and explicit
  exclusions for incompatible SpiderMonkey-specific expectations.
- `tail-call-optimization`; current tail-call scope is documented in
  [Limitations](LIMITATIONS.md#proper-tail-calls).

Never broaden skips or excludes to manufacture a pass. A deliberate boundary
change needs a concrete implementation plan, reproducer, spec basis, relevant
reference evidence, and an exit criterion.

## Local Test262 Overrides

The runner checks `tests/fixtures/test262-overrides/` before the selected
submodule file. An override is permitted only for a narrow upstream source
contradiction with another enabled test/harness feature.

Keep the original path selected, do not change `test262_errors.txt`, and
remove the override when upstream is corrected. Overrides must never hide
an engine failure.

## Supported Areas Under Active Validation

The configured profile covers modules, async functions/iteration, BigInt,
typed arrays, Proxy/Reflect, classes/private fields, iterator helpers,
explicit resource management, JSON source context, promise combinators,
Set methods, RegExp indices/modifiers/escape/property escapes, and modern
Array/String/Object/Promise additions listed in `test262.conf`.

[CLI smoke tests](tests/smoke_test.zig) and focused engine regressions cover
host integration and behaviors outside the full test262 selection.

## Comparison With Upstream QuickJS

QuickJS is a differential reference, not the compatibility definition.
When it disagrees with ECMA-262, follow the spec and record the divergence.
Compare equivalent runner configurations before attributing a difference.

The pinned QuickJS profile skips several features selected locally, including
`Atomics.waitAsync`, `arbitrary-module-namespace-names`, `Array.fromAsync`,
`await-dictionary`, `explicit-resource-management`, `immutable-arraybuffer`,
`import-text`, `import-bytes`, `joint-iteration`, `legacy-regexp`, and
`nonextensible-applies-to-private`.

The local profile also enables `host-gc-required`. Its selected staging cases
cover generator lifetime, WeakMap, detached buffers, dictionary properties,
and `for-in` across explicit GC. Different staging selections make raw
cross-engine pass counts unsuitable as a completeness comparison.

## Production v1

The release target is spec-correct trusted-code embedding within the declared
profile and public API. Use the [release checklist](docs/release-checklist.md)
for release evidence and [verification policy](docs/verification-policy.md)
for gate obligations. A failed semantic sub-gate blocks release.
