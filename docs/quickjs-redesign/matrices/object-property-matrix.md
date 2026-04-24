# Object And Property Semantics Matrix

Purpose: split Phase 3 into ordinary object, descriptor, prototype, own-key, and
array semantics that can be validated before VM and builtins depend on them.

## Object And Property Matrix

| Area | QuickJS owner | Zig owner | Required behavior | Required tests | Status |
|---|---|---|---|---|---|
| Ordinary object allocation | object allocation helpers in `quickjs.c` | `core/object.zig` | Allocate object with class, shape, prototype, extensibility flag, and property storage | Allocate/free object, prototype set/get | validated |
| Property storage | shape/property helpers in `quickjs.c` | `core/property.zig`, `core/shape.zig` | Shape entries and property values stay aligned, flags preserved, deletion updates storage safely | Add/update/delete property | validated |
| Data descriptors | descriptor helpers in `quickjs.c` | `core/descriptor.zig` | Value/writable/enumerable/configurable semantics | Descriptor creation and define tests | validated |
| Accessor descriptors | descriptor/accessor helpers | `core/descriptor.zig`, `core/object.zig` | Getter/setter storage, missing getter/setter behavior, descriptor transitions | Accessor get/set tests without VM shortcuts | validated |
| Define property invariants | `JS_DefineProperty` family | `core/object.zig`, `core/property.zig` | Non-configurable/non-writable invariants, compatible descriptor checks | Invariant rejection tests | validated |
| Get own property | `JS_GetOwnPropertyInternal` family | `core/object.zig` | Own descriptor lookup independent of prototype chain | Own descriptor tests | validated |
| Prototype lookup | property lookup helpers | `core/object.zig`, `core/property.zig` | Prototype traversal, missing property, accessor lookup, cycle-safe traversal | Prototype chain tests | validated |
| Set property | property set helpers | `core/property.zig` | Receiver semantics, writable checks, setter invocation hook, strict failure signaling | Set data/accessor/inherited tests | validated |
| Delete property | delete helpers | `core/property.zig` | Configurable checks, strict/non-strict signaling hooks | Delete configurable/non-configurable tests | validated |
| Own keys order | own property names helpers | `core/object.zig` | Integer indices, string keys, symbol keys ordering per QuickJS | Own-key order tests | validated |
| Extensibility | prevent extensions helpers | `core/object.zig` | Prevent extensions, isExtensible, define failure on new keys | Extensibility tests | validated |
| Seal/freeze | seal/freeze helpers | `core/object.zig` | Configurable/writable transitions and descriptor consistency | Seal/freeze tests | validated |
| Array index detection | array helpers | `core/array.zig` | Canonical index detection, boundary values, non-index strings | Index classification tests | validated |
| Array length property | array length helpers | `core/array.zig`, `core/property.zig` | Length update, truncation, non-writable length, sparse deletion | Length/truncation tests | validated |
| Array element storage | array fast path helpers | `core/array.zig` | Dense/sparse transition hooks, property order, element deletion | Dense/sparse tests | validated |
| Exotic dispatch hooks | exotic method records | `core/class.zig`, `core/object.zig` | Hook shape for later typed array/proxy/string arguments without builtin shortcuts | Hook registration tests | validated |

## Phase 3 Exit Additions

- VM and builtin code may not implement object-specific shortcuts for rows that
  belong in this matrix.
- Every row must have focused tests before Phase 6 or Phase 7 depends on it.
- Deferred exotic behavior must be listed in `TRACKING.md` with its downstream
  phase owner.
