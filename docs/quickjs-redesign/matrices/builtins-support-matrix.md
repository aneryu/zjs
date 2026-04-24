# Builtins And Support Libraries Matrix

Purpose: split Phase 7 into independently trackable support libraries and
builtin domains. A domain is not `validated` until constructor/prototype setup,
property descriptors, behavior tests, and shared object/property/call paths are
all covered.

## Support Libraries

| Domain | QuickJS owner | Zig owner | Required coverage | Required tests | Status |
|---|---|---|---|---|---|
| RegExp bytecode/interpreter | `libregexp.c`, `libregexp-opcode.h` | `libs/regexp.zig`, `libs/regexp_opcode.zig` | Compile, execute, captures, unicode flags, errors | RegExp library fixtures, leak-free teardown | validated |
| Unicode tables/helpers | `libunicode.c`, `libunicode-table.h` | `libs/unicode.zig`, `libs/unicode_tables.zig` | Case conversion, categories, identifier helpers, string helpers | Unicode edge fixtures | validated |
| Big number arithmetic | `libbf.c`, `libbf.h` | `libs/bignum.zig` | BigInt arithmetic backend, conversion, division/mod edge cases | BigInt backend fixtures | validated |
| Number formatting | `dtoa.c` | `libs/dtoa.zig` | Number parse/format, radix paths, special values | dtoa parse/format fixtures | validated |

## Builtin Domains

| Domain | QuickJS owner | Zig owner | Required coverage | Representative validation | Status |
|---|---|---|---|---|---|
| Intrinsic bootstrap | intrinsic registration in `quickjs.c` | `core/context.zig`, `builtins/root.zig` | Constructor/prototype graph, global bindings, descriptor flags | Bootstrap descriptor tests | validated |
| Object | Object builtin functions | `builtins/object.zig` | Create, define/get descriptors, keys, seal/freeze, prototype APIs | Object smoke + descriptor tests | validated |
| Function | Function builtin functions | `builtins/function.zig`, `exec/call.zig` | Call/apply/bind, constructor behavior, name/length/toString | Function call/bind tests | validated |
| Array | Array builtin functions | `builtins/array.zig`, `core/array.zig` | Constructor, length, methods, species where in baseline, iteration | Array smoke + edge tests | validated |
| String | String builtin functions | `builtins/string.zig`, `libs/unicode.zig` | Wrapper behavior, indexing, Unicode-sensitive methods | String/Unicode tests | validated |
| Number | Number builtin functions | `builtins/number.zig`, `libs/dtoa.zig` | Conversion, formatting, constants, errors | Number formatting tests | validated |
| Boolean | Boolean builtin functions | `builtins/boolean.zig` | Wrapper and primitive behavior | Boolean wrapper tests | validated |
| Symbol | Symbol builtin functions | `builtins/symbol.zig`, `core/atom.zig` | Well-known symbols, registry, description, property keys | Symbol tests | validated |
| BigInt | BigInt builtin functions | `builtins/bigint.zig`, `libs/bignum.zig` | Arithmetic, comparison, conversion errors, formatting | BigInt tests | validated |
| Math | Math builtin functions | `builtins/math.zig` | Constants, numeric functions, random state parity where applicable | Math compare tests | validated |
| Date | Date builtin functions | `builtins/date.zig` | Parsing, time values, UTC/local behavior, formatting | Date smoke/test262 slices | validated |
| JSON | JSON builtin functions | `builtins/json.zig` | Parse/stringify, replacer, reviver, property order, errors | JSON smoke/test262 slices | validated |
| RegExp | RegExp builtin functions | `builtins/regexp.zig`, `libs/regexp.zig` | Constructor, exec/test, flags, string integration hooks | RegExp tests | validated |
| Error | Error builtin functions | `builtins/error.zig`, `exec/exceptions.zig` | Error constructors, stack/name/message, throw integration | Error/exception tests | validated |
| Promise | Promise builtin functions | `builtins/promise.zig`, `exec/promise.zig`, `exec/jobs.zig` | Resolution, reactions, jobs, then/catch/finally, unhandled hooks | Promise job tests | validated |
| Map | Map builtin functions | `builtins/map.zig` | SameValueZero keys, iteration order, constructor iterable | Map tests | validated |
| Set | Set builtin functions | `builtins/set.zig` | SameValueZero values, iteration order, constructor iterable | Set tests | validated |
| WeakMap | WeakMap builtin functions | `builtins/weakmap.zig` | Object-key-only behavior, GC integration hooks | WeakMap tests | validated |
| WeakSet | WeakSet builtin functions | `builtins/weakset.zig` | Object-key-only behavior, GC integration hooks | WeakSet tests | validated |
| ArrayBuffer | ArrayBuffer builtin functions | `builtins/array_buffer.zig` | Allocation, slicing, detachment state where in scope | ArrayBuffer tests | validated |
| TypedArray | TypedArray builtin functions | `builtins/typed_array.zig` | Element access, views, bounds, methods, species where in baseline | TypedArray tests | validated |
| DataView | DataView builtin functions | `builtins/data_view.zig` | Endianness, bounds, buffer state | DataView tests | validated |
| Reflect | Reflect builtin functions | `builtins/reflect.zig` | get/set/construct/apply/ownKeys through shared paths | Reflect tests | validated |
| Proxy | Proxy builtin functions | `builtins/proxy.zig` | Traps, invariants, revocation, object operation integration | Proxy invariant tests | validated |
| Iterator | Iterator helpers in baseline | `builtins/iterator.zig`, `exec/iterator.zig` | Iterator prototype and helpers present in local QuickJS baseline | Iterator tests | validated |
| Atomics | Atomics builtin functions | `builtins/atomics.zig` | Shared memory behavior in selected scope, out-of-scope notes if host support absent | Atomics tests or scoped exclusion | validated |

## Phase 7 Exit Additions

- Support libraries must be validated before dependent builtins move past
  `in_progress`.
- Every builtin domain must have descriptor tests for constructor/prototype/global
  registration.
- Every builtin domain must record smoke/compare/test262 evidence once Phase 8
  tooling exists.

