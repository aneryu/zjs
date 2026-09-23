# Production v1 Release Checklist

For trusted-code JS/TS embedding releases. [Verification policy](verification-policy.md)
defines gate obligations; [GUIDE Part B.6](../GUIDE.md#b6-validation-tiers)
explains commands. Run the release aggregate through `mise run production-gate`
and the ReleaseSafe suite once. Do not repeat quick/checkpoint subsets as
prerequisites. Performance tools are diagnostic, not release gates.

## API and lifecycle

- Public API and ownership match [the contract](public-api-contract.md);
  removed APIs and error-set changes have migration/release notes.
- [Embedding examples](../tests/embedding_examples.zig) pass, including native
  registration failure cleanup and host-owned state preservation.
- Runtime/context teardown is clean under leak detection. Local/persistent
  handle lifetimes have regression coverage.
- Memory-limit/OOM paths return `error.OutOfMemory` without leftover host-owned
  values; cooperative interrupt behavior has focused coverage.

## Compatibility and boundaries

- `mise run production-gate` passes from a clean checkout: ReleaseFast suite,
  CLI/profile smoke, embedding tests, and full test262.
- `zig build test -Doptimize=ReleaseSafe --summary all` passes.
- Changed semantic areas have focused regression/slice evidence.
- Core keeps its [layer boundaries](architecture.md); host policy stays outside.
- [Compatibility](../COMPATIBILITY.md) and [Limitations](../LIMITATIONS.md)
  accurately describe the release. Release notes state the trusted-code boundary.

## Artifacts

- Ship a stripped CLI. [Nightly packaging](../.github/workflows/nightly.yml)
  strips after linking, re-signs on ARM64 macOS, and checks `zjs -e 'print(1)'`
  against the final executable before packaging.
- Keep post-link stripping so the linked code layout matches the tested binary.
  Preserve an unstripped copy for `nm`, `addr2line`, and `perf` attribution.
- Reproduce the stripped CLI locally with:

  ```sh
  zig build zjs -Doptimize=ReleaseFast
  strip zig-out/bin/zjs
  ```

  On ARM64 macOS, also re-sign as the workflow does before executing it.
  Size evidence lives in [binary composition](binary-size.md).

## Hygiene and evidence

- `git diff --check` passes; no temporary output, generated noise, or unrelated
  refactors are included.
- Record actual validation results and any diagnostic performance claims with
  the release/PR, including configuration and artifact identity.
