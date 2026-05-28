# Compatibility v1

The Production v1 compatibility target is QuickJS parity within the repository
validation profile.

## Reference

- Semantic reference: QuickJS behavior.
- Test262 config: `test262.conf`.
- Harness root: `test262/harness`.
- Test root: `test262/test`.
- Known-error file: `test262_errors.txt`.
- Local upstream-source overrides: `tests/fixtures/test262-overrides`.

## Required Gates

Production v1 requires these gates to pass from a clean checkout:

```sh
zig build test --summary all
zig build test-fast --summary all
zig build smoke --summary all
zig build test262-gate --summary all
zig build engine-production-gate --summary all
git diff --check
```

The `engine-production-gate` build step is the top-level engine release gate
and must stay green for the active Production v1 validation profile.

## Compatibility Boundary

The boundary is defined by the checked-in config and skip/exclude policy, not by
general ECMAScript completeness claims. A local test262 override may correct an
upstream source contradiction without removing the selected test path from the
gate, but it must not hide an engine failure. Expanding or shrinking the
boundary requires:

- A concrete scenario.
- QuickJS/reference evidence.
- Focused regression coverage.
- A release note when externally observable behavior changes.

## Non Goals

- Node.js compatibility.
- Deno compatibility.
- Browser API compatibility.
- Intl completeness unless the active test262 config is changed with a data and
  API plan.
