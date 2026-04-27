# Phase 3: Object And Property Semantics

Status: completed

## Goal

Port ordinary object behavior and property semantics before parser, VM, or builtins
depend on them. This phase establishes descriptors, prototype traversal, property
flags, own-key order, extensibility, array index rules, and array length behavior.

## QuickJS References

- `quickjs/quickjs.c` object, shape, property, descriptor, prototype, and array helper sections.
- `quickjs/quickjs.h` property flags and object-related constants.

## Target Files

- `src/engine/core/object.zig`
- `src/engine/core/property.zig`
- `src/engine/core/descriptor.zig`
- `src/engine/core/array.zig`
- `src/engine/core/shape.zig`
- `src/tests/core/all.zig`

## Coverage Matrix

Detailed behavior tracking lives in `../../matrices/object-property-matrix.md`.
Each row should have focused tests before VM or builtin code depends on it.

## Work Breakdown

- [x] Implement ordinary object allocation and prototype storage.
- [x] Implement property storage backed by shapes and property arrays.
- [x] Implement data descriptors and accessor descriptors.
- [x] Implement `getOwnProperty`, `defineOwnProperty`, `hasProperty`, `deleteProperty`, and own-key collection.
- [x] Implement prototype traversal with cycle protection.
- [x] Implement extensibility, prevent-extensions, seal, and freeze semantics.
- [x] Implement array index detection and canonical numeric index behavior needed by ordinary arrays.
- [x] Implement array length property updates, truncation, non-writable length behavior, and sparse arrays.
- [x] Define exotic dispatch hooks without implementing every exotic object yet.
- [x] Add object/property tests independent of parser and VM.

## Validation

```bash
zig fmt .
zig build test --summary all
```

Focused tests should cover:

- Data vs accessor descriptor transitions.
- Non-configurable and non-writable descriptor invariants.
- Prototype lookup and delete behavior.
- Property enumeration order.
- Non-extensible object failures.
- Array length truncation and sparse element deletion.
- Cycle-safe prototype operations.

## Exit Checklist

- [x] Ordinary object and array property semantics pass focused tests.
- [x] All non-deferred rows in `../../matrices/object-property-matrix.md` are `validated`.
- [x] Builtins and VM can use shared object/property APIs without shortcuts.
- [x] `status.zig` marks object/property/array core as `validated`.
- [x] `TRACKING.md` records validation evidence and any deferred exotic behavior.

## Handoff Notes

- Phase 3 validates ordinary object descriptors, prototype lookup, own-key
  order, extensibility, seal/freeze, array index detection, sparse length
  truncation, dense/sparse storage mode tracking, and exotic dispatch hook shape.
- Exotic object-specific behavior remains owned by later builtin/support-library
  phases; this phase only validates the shared dispatch surface.
