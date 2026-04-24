# Phase 7: Builtins And Support Libraries

Status: completed

## Goal

Port QuickJS core builtins and low-level support libraries. Builtins must use the
same object, property, call, and exception paths as user code.

## QuickJS References

- `quickjs/quickjs.c` intrinsic registration and builtin function sections.
- `quickjs/libregexp.c`
- `quickjs/libregexp-opcode.h`
- `quickjs/libunicode.c`
- `quickjs/libunicode-table.h`
- `quickjs/libbf.c`
- `quickjs/libbf.h`
- `quickjs/dtoa.c`

## Target Files

- `src/engine/libs/regexp.zig`
- `src/engine/libs/regexp_opcode.zig`
- `src/engine/libs/unicode.zig`
- `src/engine/libs/unicode_tables.zig`
- `src/engine/libs/bignum.zig`
- `src/engine/libs/dtoa.zig`
- `src/engine/builtins/*.zig`
- `src/tests/builtins/all.zig`

## Coverage Matrix

Detailed support-library and builtin-domain tracking lives in
`../matrices/builtins-support-matrix.md`. Support libraries must be validated
before dependent builtins move beyond `in_progress`.

## Work Breakdown

- [x] Port regexp engine support before `RegExp` builtin integration.
- [x] Port Unicode tables and string classification/case helpers.
- [x] Port bignum support required by BigInt.
- [x] Port dtoa and numeric formatting/parsing helpers.
- [x] Port Object and Function intrinsics.
- [x] Port Array and iterator-related intrinsics.
- [x] Port String, Number, Boolean, Symbol, BigInt, Math, and Date.
- [x] Port JSON, RegExp, Error, and Promise.
- [x] Port Map, Set, WeakMap, and WeakSet.
- [x] Port ArrayBuffer, TypedArray, DataView, Atomics, Reflect, Proxy, and Iterator.
- [x] Ensure builtin registration goes through runtime/context intrinsic setup.
- [x] Ensure builtin property behavior goes through shared object/property APIs.

## Validation

```bash
zig fmt .
zig build test --summary all
zig build smoke --summary all
```

After `zjs` exists:

```bash
QJS=/Users/aneryu/zjs/quickjs/build/qjs \
QJS_ZIG=/Users/aneryu/zjs/zig-out/bin/zjs \
bun tools/compare/run_compare.js --functional-only
```

Focused tests should cover:

- Constructor/prototype property descriptors.
- Builtin function names, lengths, and error behavior.
- String and Unicode edge cases.
- BigInt arithmetic and conversion edge cases.
- RegExp compilation and execution.
- JSON parse/stringify.
- Promise job ordering.
- Collection key equality and iteration.
- Typed array bounds and buffer detachment rules where in scope.

## Exit Checklist

- [x] Support libraries have focused tests and leak-free teardown.
- [x] All non-deferred rows in `../matrices/builtins-support-matrix.md` are `validated`.
- [x] Builtin domains have representative tests and smoke/compare coverage.
- [x] Builtins do not bypass shared object/property/call/exception paths.
- [x] `status.zig` marks completed builtin domains as `validated`.
- [x] `TRACKING.md` records validation evidence and any local QuickJS baseline differences.

## Handoff Notes

Phase 7 validates representative support-library and builtin-domain behavior.
Broad smoke/compare/test262 validation remains Phase 8 work once CLI and
validation tooling are wired into this redesigned engine path.
