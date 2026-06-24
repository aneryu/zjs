# Object and Shape Implementation

This note describes the active object/shape contract. It is not a roadmap or
completion ledger.

Primary owners:

- `src/core/object.zig`
- `src/core/shape.zig`
- `src/core/property.zig`
- property opcode handlers in `src/exec/vm_property.zig`

## Shape Model

`Shape` is GC-managed (an embedded GC header; shapes live in the cycle
collector's `gc_obj_list`) and shared by objects with the same structural
property sequence and prototype identity. Important fields:

- `header` (GC object header — shapes are collected, not hand-ref-counted)
- `parent`, `transition_atom`, `transition_flags` (back-link recording how this shape was reached)
- `proto` (the prototype identity is owned by the shape, not the object)
- `version`
- `hash`
- `registry_index`, `registry_hash_next`, `registry_hash_prev`
- `prop_hash_mask`, `hash_buckets`
- `props`

`Shape.version` is the structural invalidation token used by inline caches. It
is bumped when property layout or prototype identity changes, including property
addition, deletion, flag updates, hash rebuilds, and prototype replacement.

## Property Lookup

Shapes always carry a property hash (`prop_hash_mask` + `hash_buckets`) — there
is no small-shape linear-scan threshold (the former `small_shape_linear_limit`
path was removed to align with qjs always-build-hash). The hash maps property
name to slot.

Property storage remains insertion-ordered in `Object.properties`; the shape
hash only accelerates name-to-slot lookup. Property entries are not moved just
because the hash table is rebuilt.

Deletion marks the property as deleted and bumps `Shape.version`. Deleted
entries are skipped by enumeration and can contribute to later hash rebuilds.

## Shape Registry

`shape.Registry` owns all live shapes. It keeps:

- a dense `shapes` array for ownership and destruction.
- `shape_hash_buckets` for hash-based lookup by shape identity, with shapes
  chained through `registry_hash_next`/`registry_hash_prev`.

`createObjectRoot` reuses a cacheable empty root shape for the same prototype
identity. `transitionProperty` reuses a cached child when the same
`(parent, atom, flags)` transition is found in the hashed-shape registry
(this replaced the former per-parent transition arrays, aligning with qjs
`find_hashed_shape_prop`).

The registry is also responsible for retaining and releasing atoms held by
shape properties and transition metadata.

## Object Layout

`Object` keeps common fields inline:

- GC header, class id, class payload tag/pointer.
- the shape reference (`shape_ref`); the prototype identity is owned by the
  shape (`shape_ref.proto`), not a separate object→prototype edge.
- object flags such as extensibility, array/proxy/global markers, HTMLDDA,
  with-environment, and indexed-property markers.
- shared caches such as lazy native functions, cached iterator next, and
  global lexical environment.
- array length metadata, property storage, and exotic methods.

Class-specific state is held in external payload structs where possible:

- iterator, collection, buffer, typed array, regexp.
- bound function, proxy, arguments, object-data wrappers, var-ref.
- array, promise, generator, function, module namespace.
- finalization registry, std file, disposable stack, realm payload.

Payload accessors should be used instead of reaching through `class_payload`
directly. New class-specific state should default to a payload unless it is
needed by ordinary objects on the hot path.

## Invariants

- `Object.shape_ref` must remain retained for the object's lifetime.
- Prototype changes must update shape identity or bump the existing shape
  version through the registry.
- Shape-owned atom references must be duplicated on insertion and freed on
  shape release.
- `Object.properties` and `Shape.props` must stay index-compatible for live
  property slots.
- Inline-cache entries must retain guard shapes and release them on function
  teardown or cache promotion to megamorphic.
- Any change that can invalidate a cached slot must bump `Shape.version`.

## Validation

For object/shape changes, run at least:

```sh
zig build test --summary all
zig build smoke --summary all
git diff --check
```

Add targeted test262 slices according to the touched behavior, for example:

```sh
./zig-out/bin/run-test262 -t 8 -c test262.conf \
  -d test262/test/language/expressions/property-accessors
./zig-out/bin/run-test262 -t 8 -c test262.conf \
  -d test262/test/built-ins/Object
./zig-out/bin/run-test262 -t 8 -c test262.conf \
  -d test262/test/built-ins/Reflect
```

Performance-sensitive object/property work should record a fresh measurement
command and environment with the owning change.
