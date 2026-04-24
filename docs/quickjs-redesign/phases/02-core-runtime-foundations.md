# Phase 2: Core Runtime Foundations

Status: in_progress

## Goal

Port the runtime foundations required by every higher layer: value tags, reference
lifetime, runtime/context ownership, atoms, strings, classes, shapes, function
records, module records, exception slots, allocator accounting, and GC scaffolding.

## QuickJS References

- `quickjs/quickjs.h` for value tags, property flags, class IDs, and API constants.
- `quickjs/quickjs.c` runtime, context, atom, string, class, shape, function, module, and GC sections.
- `quickjs/quickjs-atom.h` for predefined atom ordering.
- `quickjs/list.h` and `quickjs/cutils.h` for intrusive list and utility behavior.

## Target Files

- `src/engine/core/value.zig`
- `src/engine/core/list.zig`
- `src/engine/core/gc.zig`
- `src/engine/core/atom.zig`
- `src/engine/core/string.zig`
- `src/engine/core/class.zig`
- `src/engine/core/shape.zig`
- `src/engine/core/function.zig`
- `src/engine/core/module.zig`
- `src/engine/core/runtime.zig`
- `src/engine/core/context.zig`
- `src/engine/core/exception.zig`
- `src/engine/core/memory.zig`
- `src/tests/core/all.zig`

## Coverage Matrix

Detailed invariant tracking lives in
`../matrices/core-runtime-invariants.md`. Update the relevant row whenever an
area moves from `not_started` to `in_progress` or `validated`.

## Work Breakdown

- [x] Define Zig value representation with QuickJS-aligned tag semantics and typed accessors.
- [x] Implement duplication/free hooks for primitive and reference values.
- [x] Implement runtime allocator accounting and ownership rules.
- [x] Implement context lifecycle and exception slot transfer helpers.
- [x] Port intrusive list behavior in Zig style.
- [x] Implement atom table with predefined atoms, dynamic atoms, integer atoms, symbols, and private names.
- [x] Implement string storage for 8-bit and 16-bit strings, comparison, hashing, and atom backing.
- [ ] Implement class table, class definitions, finalizer hooks, exotic method records, and prototype slots.
- [ ] Implement shape records, property shape entries, shape hashing, and transition scaffolding.
- [ ] Add function object payload records for native, bytecode, bound, constructor, and home-object state.
- [ ] Add runtime module records and lifecycle state without executing modules yet.
- [ ] Add GC/refcount scaffolding and leak-free runtime teardown.

## Validation

```bash
zig fmt .
zig build test-quickjs-port --summary all
zig build test --summary all
```

Focused tests should cover:

- QuickJS tag constants and value predicates.
- Atom ordering and atom lifetime.
- Class ID and class definition registration.
- String allocation and free paths.
- Runtime/context init-deinit with `std.testing.allocator`.
- Refcount edge cases for primitive vs reference values.

## Exit Checklist

- [ ] Runtime/context init-deinit is leak-free.
- [ ] QuickJS constants needed by later phases are locked by tests.
- [ ] All non-deferred rows in `../matrices/core-runtime-invariants.md` are `validated`.
- [ ] `status.zig` marks completed core foundations as `validated`.
- [ ] No public API exposes raw reference payloads or `anyopaque`.
- [ ] `TRACKING.md` records validation results and open risks.

## Handoff Notes

- GC cycle removal, function records, module records, context prototype slots,
  object finalizer invocation order, and atom hash-table optimization remain
  incomplete and are tracked in `../matrices/core-runtime-invariants.md`.
