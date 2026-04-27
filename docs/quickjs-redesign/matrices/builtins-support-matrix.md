# Builtins And Support Libraries Matrix

Purpose: split Phase 7 into independently trackable support libraries and
builtin domains. A domain is not `validated` until constructor/prototype setup,
property descriptors, behavior tests, and shared object/property/call paths are
all covered.

Architecture repair note: the status rows below are historical Phase 7 fixture
evidence. Several builtin and support-library modules are still narrow helpers
or scaffolds, so the subsystem is `fixture_validated`, not `semantic_complete`,
until the repair plan replaces placeholder constructor/prototype/library paths.

## Support Libraries

| Domain | QuickJS owner | Zig owner | Required coverage | Required tests | Status |
|---|---|---|---|---|---|
| RegExp bytecode/interpreter | `libregexp.c`, `libregexp-opcode.h` | `libs/regexp.zig`, `libs/regexp_opcode.zig` | Compile, execute, captures, unicode flags, errors | RegExp library fixtures, leak-free teardown | validated |
| Unicode tables/helpers | `libunicode.c`, `libunicode-table.h` | `libs/unicode.zig`, `libs/unicode_tables.zig` | Case conversion, categories, identifier helpers, string helpers | Unicode edge fixtures | validated |
| Big number arithmetic | BigInt/bignum sections in `quickjs.c` for this vendored baseline | `libs/bignum.zig` | BigInt arithmetic backend, conversion, division/mod edge cases | BigInt backend fixtures | validated |
| Number formatting | `dtoa.c` | `libs/dtoa.zig` | Number parse/format, radix paths, special values | dtoa parse/format fixtures | validated |

## Builtin Domains

| Domain | QuickJS owner | Zig owner | Required coverage | Representative validation | Status |
|---|---|---|---|---|---|
| Intrinsic bootstrap | intrinsic registration in `quickjs.c` | `builtins/registry.zig`, `builtins/root.zig`, `exec/call.zig` | Constructor/prototype graph, global bindings, descriptor flags | Shared registry helper now installs standard globals, constructors, prototype objects, namespace methods, and descriptor flags for intrinsic bootstrap and host global setup; host assert/verify/isConstructor helpers are ordinary callable properties, built-ins/global test262 passes 0/29, and bootstrap descriptor tests pass. Standard `prototype.constructor` back-links remain deferred until WQ-014 cycle GC can own constructor/prototype object cycles. | fixture_validated |
| Object | Object builtin functions | `builtins/object.zig` | Create, define/get descriptors, keys, seal/freeze, prototype APIs | Narrow object literal, Object.is, Object.defineProperty, Object.getOwnPropertyDescriptor, Object.getOwnPropertyNames, and Object.keys/values/entries helpers are owned by builtin/host callable dispatch; generic constructor/prototype object creation is owned by `exec/construct.zig`; Object smoke, builtins helper coverage, and Object/is test262 pass 0/21. Broader prototype APIs remain incomplete. | fixture_validated |
| Function | Function builtin functions | `builtins/function.zig`, `exec/call.zig` | Call/apply/bind, constructor behavior, name/length/toString | Native/source function objects now back Promise/Collection/closure display instead of synthesized strings; function helper and exec coverage pass | validated |
| Array | Array builtin functions | `builtins/array.zig`, `core/array.zig` | Constructor, length, methods, species where in baseline, iteration | Narrow Array construction/join/callback-backed map/prototype-method helper is owned by `builtins/array.zig` except output-bound `forEachPrint` in `exec/call.zig`; Array methods now dispatch through callable prototype properties via `call_prop`; Array smoke and builtins helper coverage pass | fixture_validated |
| String | String builtin functions | `builtins/string.zig`, `libs/unicode.zig` | Wrapper behavior, indexing, Unicode-sensitive methods | Narrow String constructor/fromCharCode/charAt/method helper is owned by `builtins/string.zig`; String static/prototype helpers now dispatch through callable properties via `call_prop`; String smoke and builtins helper coverage pass | fixture_validated |
| Number | Number builtin functions | `builtins/number.zig`, `libs/dtoa.zig` | Conversion, formatting, constants, errors | Number formatting tests plus supported parseInt/parseFloat helper coverage; global parseInt/parseFloat and Number.parseInt/parseFloat test262 slices pass 0/111 | validated |
| Boolean | Boolean builtin functions | `builtins/boolean.zig` | Wrapper and primitive behavior | Boolean wrapper tests | validated |
| Symbol | Symbol builtin functions | `builtins/symbol.zig`, `core/atom.zig` | Well-known symbols, registry, description, property keys | Symbol tests | validated |
| BigInt | BigInt builtin functions | `builtins/bigint.zig`, `libs/bignum.zig` | Arithmetic, comparison, conversion errors, formatting | BigInt tests | validated |
| Math | Math builtin functions | `builtins/math.zig`, `exec/call.zig` | Constants, numeric functions, random state parity where applicable | Narrow `math_call` helper is now owned by `builtins/math.zig`; `Math` is installed as an ordinary global object property rather than emitted as a marker value; Math smoke, builtins helper coverage, and 0/327 Math test262 slice pass | validated |
| Date | Date builtin functions | `builtins/date.zig` | Parsing, time values, UTC/local behavior, formatting | Narrow Date call/static/constructor/method helper is owned by `builtins/date.zig`; supported Date static and prototype helpers now dispatch through callable properties via `call_prop`; Date smoke and builtins helper coverage pass | fixture_validated |
| JSON | JSON builtin functions | `builtins/json.zig` | Parse/stringify, replacer, reviver, property order, errors | Narrow stringify/parse helper is now owned by `builtins/json.zig`; JSON smoke and 0/165 JSON test262 slice pass | validated |
| URI globals | URI encode/decode global functions | `builtins/uri.zig` | Encode/decode URI and component helpers, string conversion, errors | Narrow `uri_call` helper is now owned by `builtins/uri.zig`; URI smoke, builtins helper coverage, and 0/173 URI test262 slices pass | validated |
| RegExp | RegExp builtin functions | `builtins/regexp.zig`, `libs/regexp.zig` | Constructor, exec/test, flags, string integration hooks | Narrow RegExp constructor and instance method helper is owned by `builtins/regexp.zig`; supported instance helpers now dispatch through callable properties via `call_prop`, and unsupported static calls report `TypeError` without cleanup panics; RegExp smoke and builtins helper coverage pass | fixture_validated |
| Error | Error builtin functions | `builtins/error.zig`, `exec/exceptions.zig` | Error constructors, stack/name/message, throw integration | Error/exception tests | validated |
| Promise | Promise builtin functions | `builtins/promise.zig`, `exec/promise.zig`, `exec/jobs.zig` | Resolution, reactions, jobs, then/catch/finally, unhandled hooks | Narrow Promise constructor/static helper is owned by `builtins/promise.zig`; static helpers and `then`/`catch` are callable function object properties dispatched through `call_prop`; Promise smoke and builtins helper coverage pass | fixture_validated |
| Map | Map builtin functions | `builtins/collection.zig` | SameValueZero keys, iteration order, constructor iterable | Map now uses object-owned tombstone-backed storage with SameValueZero lookup, `set` returning `this`, VM-created instances inheriting registered `Map.prototype` methods, `Symbol.species`, non-owning `Map.prototype.constructor`, `Map.prototype.{keys,values,entries,clear}`, `Map.prototype[Symbol.iterator]`, `Map.prototype[Symbol.toStringTag]`, array-entry `new Map(iterable)`, `Array.from` over Map iterators, and the first Map.groupBy tranche. Map smoke and builtins helper coverage pass; `built-ins/Map 0 60` is 49/61 passing and full `built-ins/Map 0 400` is 177/204 passing. Remaining blockers are custom adder/iterator-close fixtures, remaining forEach mutation/throw and getOrInsertComputed callback edge cases, and valid-keys parser/value coverage. | fixture_validated |
| Set | Set builtin functions | `builtins/collection.zig` | SameValueZero values, iteration order, constructor iterable | Set now uses object-owned multi-entry storage with duplicate suppression, `add` returning `this`, and VM-created instances inheriting registered `Set.prototype` methods; Set smoke and builtins helper coverage pass | fixture_validated |
| WeakMap | WeakMap builtin functions | `builtins/collection.zig` | Object-key-only behavior, GC integration hooks | WeakMap storage now records object identities without retaining keys, validates object-key `set`, returns false/undefined for primitive lookup/delete paths, inherits registered prototype methods in VM construction, and exposes a weak-entry sweep hook; full automatic GC scheduling remains follow-up scope | fixture_validated |
| WeakSet | WeakSet builtin functions | `builtins/collection.zig` | Object-key-only behavior, GC integration hooks | WeakSet storage now records object identities without retaining keys, validates object-key `add`, returns false for primitive lookup/delete paths, inherits registered prototype methods in VM construction, and exposes a weak-entry sweep hook; full automatic GC scheduling remains follow-up scope | fixture_validated |
| ArrayBuffer | ArrayBuffer builtin functions | `builtins/buffer.zig` | Allocation, slicing, detachment state where in scope | Narrow ArrayBuffer constructor/slice helper is now owned by `builtins/buffer.zig`; typedarray smoke, builtins helper coverage, and DataView slice coverage pass | validated |
| TypedArray | TypedArray builtin functions | `builtins/buffer.zig` | Element access, views, bounds, methods, species where in baseline | Narrow TypedArray shape helper is now owned by `builtins/buffer.zig`; typedarray smoke and builtins helper coverage pass | validated |
| DataView | DataView builtin functions | `builtins/buffer.zig` | Endianness, bounds, buffer state | Narrow DataView constructor/get/set helper is now owned by `builtins/buffer.zig`; typedarray smoke, exec coverage, builtins helper coverage, and 0/561 targeted DataView test262 slice pass | validated |
| Reflect | Reflect builtin functions | `builtins/reflect_proxy.zig` | get/set/construct/apply/ownKeys through shared paths | Reflect tests | validated |
| Proxy | Proxy builtin functions | `builtins/reflect_proxy.zig` | Traps, invariants, revocation, object operation integration | Proxy invariant tests | validated |
| Iterator | Iterator helpers in baseline | `builtins/iterator.zig`, `exec/iterator.zig` | Iterator prototype and helpers present in local QuickJS baseline | Iterator tests | validated |
| Atomics | Atomics builtin functions | `builtins/atomics.zig` | Shared memory behavior in selected scope, out-of-scope notes if host support absent | Atomics tests or scoped exclusion | validated |

## Phase 7 Exit Additions

- Support libraries must be validated before dependent builtin domains are marked
  `validated`.
- Every builtin domain must have descriptor tests for constructor/prototype/global
  registration.
- Every builtin domain must record smoke/compare/test262 evidence once Phase 8
  tooling exists.
