# Object And Shape Implementation

This note describes the current object/shape contract. The source of truth is:

- `src/core/object.zig`
- `src/core/shape.zig`
- `src/core/property.zig`
- `src/exec/property_direct.zig`
- `src/exec/vm_property*.zig`

The dated zjs / QuickJS subsystem baseline
(`docs/qjs-align/SUBSYSTEM-DIFFERENCE-BASELINE-2026-07-27.md`, removed
2026-08-25; recover from git history) contains the field-level comparison
and behavior probes as of its freeze date.

## Fixed Layout

On the current 64-bit target:

- `Object` is 64 bytes.
- `Shape` has a 56-byte fixed header.
- `shape.Property` is an 8-byte packed QuickJS-style shape-property record.
- `property.Entry` is one value-sized property union: 16 bytes in the default
  representation.
- `ObjectStorage` is the 24-byte class-data union.

Bytecode-function and RegExp state fit directly in `ObjectStorage`. Many other
classes use the union's payload pointer and an out-of-line typed payload.

## Shape Model

`Shape` is GC-managed and shared by objects with the same structural property
sequence and prototype identity. Its fixed header contains:

- the intrusive GC header;
- hashed-shape state and hash;
- property hash mask;
- property capacity/count/deleted count;
- registry hash link;
- prototype.

One allocation contains the fixed Shape followed by:

```text
[shape.Property array][u32 hash buckets]
```

This order differs from QuickJS, which places the buckets first and the
properties second. Do not change the order without size-bucketed cache and
relocation measurements.

The shape property array owns property atoms and descriptor flags. The Object's
property-value array owns only values/getter-setter/VarRef/AutoInit state. The
two arrays must remain index-compatible.

## Lookup And Mutation

Shapes carry a property hash; ordinary named lookup resolves an atom to a shape
slot and then reads the matching Object value slot. Property addition can reuse
a hashed structural transition. Prototype identity is part of the shape.

Deletion clears/unlinks the live property metadata and increments the deleted
count, but does not move every following slot immediately. Enumeration and
lookup skip deleted entries; later rebuild/relocation may compact storage.

Mutation must preserve:

- shape/value-slot index compatibility;
- atom retain/release balance;
- prototype ownership through the shape;
- descriptor and AutoInit operation order;
- rollback safety if value storage or a relocated Shape cannot be allocated;
- Proxy/exotic/typed-array/array special semantics before using an ordinary
  fast path.

## Arrays And Class Data

The `ObjectStorage.array` arm stores dense values, count, capacity, and visible
length. QuickJS keeps visible array length in an ordinary shape property; zjs
keeps a scalar mirror in the array arm. Every array mutation must preserve
`length >= count`, hole semantics, sparse fallback, and non-writable length.

Typed arrays do not use an inline Object ptr/count cache in zjs. The Object
points to `TypedArrayPayload`, which contains live length/data and participates
in the backing buffer's view list. Element fast paths must not bypass
detach/resize/immutable checks.

## Property Fast Paths: No Inline Cache Today

The former shape-keyed per-bytecode-site inline cache has been removed:

- no `src/core/ic.zig`;
- no FunctionBytecode IC slots;
- no `zjs_enable_ic` build option.

`src/exec/property_direct.zig` (renamed from the historical
`property_ic.zig` on 2026-08-19; the always-false `cachedSet*` zombie was
deleted at the same time) owns the non-cached helpers:

- direct ordinary own-data lookup;
- immediate prototype-data lookup;
- global data-slot lookup/store;
- simple ordinary put;
- computed-property action resolution.

The retained `dataPropertyValueForFastPath` signature always misses and
routes to the authoritative current-state lookup. It does not retain shapes
or versions.

Ruling status (2026-08-25): the IC-removal resolution itself (retired clause
R2, "runtime structural alignment with qjs") was retired with the charter
transition adopted in `14b0618d` — see
[qjs_alignment_charter_transition.md](../qjs_alignment_charter_transition.md)
§2. Phase 0.5 feedback slots are approved
([engine-evolution-plan.md](../engine-evolution-plan.md) §3.4), and the
typed-slot reconciliation of the 2026-08-17 IC disproof lives in
[type-directed-optimization-plan.md](../type-directed-optimization-plan.md)
§1.5. This document describes the current implementation only; it no longer
forbids future cache work.

When describing the current implementation, a property result is a direct
shape/hash fast-path hit or a slow/exotic path — never an IC hit, because no
IC exists in the tree today.

## Validation

Start with the narrowest changed-area target:

```sh
zig build test-core --summary all
zig build test-exec --summary all
mise run quick-gate
git diff --check
```

Add focused test262 slices for the touched behavior:

```sh
./zig-out/bin/run-test262 -t 8 -c test262.conf \
  -d test262/test/language/expressions/property-accessors
./zig-out/bin/run-test262 -t 8 -c test262.conf \
  -d test262/test/built-ins/Object
./zig-out/bin/run-test262 -t 8 -c test262.conf \
  -d test262/test/built-ins/Reflect
./zig-out/bin/run-test262 -t 8 -c test262.conf \
  -d test262/test/built-ins/Proxy
```

For layout/GC/ownership changes, also run the checkpoint and phase-close OOM
gate at the appropriate handoff tier. Performance-sensitive changes require a
pinned QuickJS mechanism reference plus controlled before/after measurement.
