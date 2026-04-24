# Core Runtime Invariants Matrix

Purpose: make Phase 2 reviewable at subsystem and invariant level. A row can be
marked `validated` only when the source mapping, focused tests, ownership notes,
and status entry all exist.

## Runtime Foundation Matrix

| Area | QuickJS owner | Zig owner | Required invariants | Required tests | Status |
|---|---|---|---|---|---|
| Value tags and immediates | `quickjs.h`, `quickjs.c` value helpers | `core/value.zig` | Tag ordering, primitive payload range, NaN/int/bool/null/undefined behavior, typed accessors hide reference payloads | Tag constants, predicates, conversion edge cases, no public `anyopaque` | validated |
| Reference values | `quickjs.c` refcount helpers | `core/value.zig`, `core/gc.zig` | Dup/free dispatch by tag, zero-ref behavior, finalizer handoff, double-free protection in tests | Primitive dup/free no-op, object/string dup/free, teardown leak check | validated |
| Allocator accounting | `quickjs.c` malloc helpers | `core/memory.zig`, `core/runtime.zig` | Runtime-owned allocator, accounting increments/decrements, OOM propagation, no hidden global allocator | Allocation success/failure, same allocator frees, runtime teardown leak-free | validated |
| Runtime lifecycle | `JS_NewRuntime`, `JS_FreeRuntime` | `core/runtime.zig` | Atom/class/shape/job/module/GC lists initialized and released in deterministic order | Init-deinit with `std.testing.allocator`, repeated init-deinit | validated |
| Context lifecycle | `JS_NewContext`, `JS_FreeContext` | `core/context.zig` | Context owns intrinsic state, exception slot, stack limit, interrupt/random state, module state hooks | Init-deinit, multiple contexts per runtime, exception slot clear | validated |
| Exception slot | exception helpers in `quickjs.c` | `core/exception.zig` | JS exception value stored in context, `takeException` transfers ownership and clears slot | Set/take/clear, no pending exception returns undefined | validated |
| Intrusive list | `list.h` | `core/list.zig` | No C macro leakage, typed list nodes, safe init/remove/splice behavior | Empty list, insert/remove, double remove guard where applicable | validated |
| Predefined atoms | `quickjs-atom.h` | `core/atom.zig` | Exact order, stable numeric IDs, predefined strings interned before dynamic atoms | Atom order lock, lookup by ID/name | validated |
| Dynamic atoms | atom table in `quickjs.c` | `core/atom.zig` | Hashing, integer atoms, symbol/private atom kinds, refcounted lifetime | Intern/dedup/free, integer atom roundtrip, symbol/private distinction | validated |
| Strings | string helpers in `quickjs.c` | `core/string.zig` | 8-bit/16-bit storage, length, hash, compare, atom backing, conversion ownership | ASCII/BMP allocation, compare, atom-backed lifetime, free paths | validated |
| Class table | class helpers in `quickjs.c` | `core/class.zig` | Class IDs, definitions, finalizers, exotic method records, prototype slots | Class registration, duplicate class rejection, finalizer call order | validated |
| Shapes | shape helpers in `quickjs.c` | `core/shape.zig` | Shape hash, property shape entries, prototype-linked transitions, shared shape refcounts | Shape create/share/free, transition equality, proto transition | validated |
| Function records | function object records in `quickjs.c` | `core/function.zig` | Native/bytecode/bound callable records, constructor flags, home object, lifetime | Native record, bytecode record, bound record, finalizer path | validated |
| Module records | module records in `quickjs.c` | `core/module.zig` | Runtime module list, status, import/export record storage, namespace backing placeholders | Create/free module record, import/export metadata lifetime | validated |
| GC scaffolding | cycle removal in `quickjs.c` | `core/gc.zig` | Refcount headers, GC object lists, mark/sweep hooks, cycle-removal placeholders visible in status | Zero-ref list, mark hook plumbing, leak-free teardown | validated |
| Stack and interrupt state | runtime/context state in `quickjs.c` | `core/runtime.zig`, `core/context.zig` | Stack limit stored and checked by later phases, interrupt hook storage, random state initialized | Stack limit set/get, interrupt hook set/get, deterministic teardown | validated |

## Phase 2 Exit Additions

- Every row above must be `validated` or explicitly listed in `TRACKING.md` as a
  Phase 2 deferral with reason and downstream owner.
- `status.zig` must expose the same area names or a stable mapping from these
  rows to status entries.
- Runtime/context teardown must be validated with `std.testing.allocator`.
