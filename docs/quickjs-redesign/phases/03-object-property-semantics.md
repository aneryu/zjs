# Phase 3: Object And Property Semantics

Status: not_started

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

Detailed behavior tracking lives in `../matrices/object-property-matrix.md`.
Each row should have focused tests before VM or builtin code depends on it.

## Work Breakdown

- [ ] Implement ordinary object allocation and prototype storage.
- [ ] Implement property storage backed by shapes and property arrays.
- [ ] Implement data descriptors and accessor descriptors.
- [ ] Implement `getOwnProperty`, `defineOwnProperty`, `hasProperty`, `deleteProperty`, and own-key collection.
- [ ] Implement prototype traversal with cycle protection.
- [ ] Implement extensibility, prevent-extensions, seal, and freeze semantics.
- [ ] Implement array index detection and canonical numeric index behavior needed by ordinary arrays.
- [ ] Implement array length property updates, truncation, non-writable length behavior, and sparse arrays.
- [ ] Define exotic dispatch hooks without implementing every exotic object yet.
- [ ] Add object/property tests independent of parser and VM.

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

- [ ] Ordinary object and array property semantics pass focused tests.
- [ ] All non-deferred rows in `../matrices/object-property-matrix.md` are `validated`.
- [ ] Builtins and VM can use shared object/property APIs without shortcuts.
- [ ] `status.zig` marks object/property/array core as `validated`.
- [ ] `TRACKING.md` records validation evidence and any deferred exotic behavior.

## Handoff Notes

Record exotic object hooks that are intentionally deferred to Phase 7.
