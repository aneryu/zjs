# Architecture Repair Plan

Last updated: 2026-04-27

This document tracks the repair work opened after the whole-project architecture
review. The architecture-repair queue is now closed; broader semantic
completion work is tracked as follow-up work in `TRACKING.md`.

## Current Truth

- The local `run-test262` gate can pass the selected `quickjs/test262.conf`
  baseline, but that is not the same as QuickJS semantic completeness.
- `frontend/parser.zig` now has a single parser entry path: executable inputs
  are owned by `quickjs_parser`, the former `SimpleParser` compatibility path
  has been merged into that parser, and test262 metadata/source-pattern
  pre-compilers have been removed from parse dispatch. Unsupported syntax now
  reports through the syntax-error guard instead of succeeding through a token
  metadata scanner.
- `exec/vm.zig` still owns too much dispatch glue, but helper-level
  `Unsupported*` failures now map to JS-visible `TypeError` rather than
  leaking `UnsupportedOpcode`; the remaining `UnsupportedOpcode` trap is for
  unknown or malformed bytecode. The host global callable
  setup, host-call dispatch, output formatting, JSON/Math/URI helper semantics,
  Number parse helper semantics, Date helper semantics, RegExp
  constructor/instance-method semantics, Promise constructor/static semantics,
  Collection constructor/prototype-method semantics, ArrayBuffer/TypedArray/
  DataView semantics, String constructor/fromCharCode/charAt/method semantics,
  Object literal/Object.is/entries semantics, Array construction/join/map and
  selected prototype-method semantics, value/equality/conversion/BigInt
  semantics, property/in/instanceof/global-property semantics, closure fixture
  state, test262 helper behavior, standard global object setup, output-bound
  Array `forEachPrint`, and allocator-backed call argument storage have moved
  out of the former fixed-buffer VM helper shape.
- `builtins/*` and `libs/*` contain useful focused fixtures, but several modules
  are still scaffolds or narrow helpers rather than full constructor/prototype
  and library ports. This is follow-up semantic-completion work, not remaining
  architecture-repair work.
- `core/gc.zig` records cycle-removal scaffolding only; full JS cycle handling
  remains open as a follow-up work queue item.

## Repair Tracks

| Track | Status | Required next action |
|---|---|---|
| Status calibration | completed | `status.zig` records known-gap subsystems below `semantic_complete` and includes the extracted exec helper modules. |
| Parser-first architecture | completed | `quickjs_parser` is the only successful parse/lower path and covers the former compatibility domains plus module metadata, eval feature tracking, statements, assignments, updates, expressions, literals, parenthesized property/index/optional access, generic host-output calls, supported builtin helper calls, generic named construction, named `instanceof`, simple `for-in`, callback-backed `Array.map`, and ordinary `Math`/`globalThis` global/property lowering. Unsupported syntax reports through `syntax_error_guard`; legacy parse path markers have been removed. |
| VM/domain extraction | completed | Host callable setup/dispatch/output formatting, standard global object setup, and output-bound Array `forEachPrint` moved into `exec/call.zig`; JSON/Math/URI/Number parse/Date/RegExp/Promise/Collection/Buffer/String/Object/Array helper semantics moved into builtins modules; VM value/equality/conversion/BigInt, property/in/instanceof/global property, construct, closure, and test262 helper behavior moved into exec helper modules; helper-level unsupported failures now surface as `TypeError`. |
| Builtins and support libs | follow_up | Replace placeholder constructor/prototype/library domains with real shared object/property behavior. |
| GC cycle removal | follow_up | Implement or explicitly scope QuickJS-style cycle removal and weak collection integration. |
| Capacity/OOM hardening | follow_up | Replace hidden fixed limits and infallible allocation helpers with allocator-backed, fallible paths. |

## Parser-First Boundary

- `quickjs_parser` is the only successful parse path. The legacy token metadata
  scanner and transitional fixture compiler are no longer exposed as
  `ParsePath` variants.
- New syntax work should add source-aligned parse/lower behavior before adding
  VM shortcuts or source-string recognizers.
- Do not add new source-string recognizers, test262 metadata recognizers, or VM
  domain shortcut opcodes as semantic coverage. If a temporary exception is
  unavoidable, record it as transitional debt in this document, `TRACKING.md`,
  and `ERRORS_AND_LEARNINGS.md`.
- The current `quickjs_parser` slice is intentionally conservative: unsupported
  syntax must fail with a syntax diagnostic rather than silently succeeding
  through metadata scanning. Fixture-shaped bytecode operations that remain
  below the parser are tracked as emitter/VM debt, not as separate parser paths.
- Quick parser postfix parsing is split by call/property/optional/index handlers
  so future syntax slices can extend the path without adding new source-string
  recognizers.

## Audit Findings

The 2026-04-26 parser/VM shortcut audit is recorded as
`EAL-20260426-003` in `ERRORS_AND_LEARNINGS.md`. The audited shortcut classes
now stand as:

- Removed in the 2026-04-26 remaining-opcode cleanup: the fixture-shaped
  emitter/VM opcodes for simple `for-in` concatenation, `Array.map(x => x * N)`,
  named object construction, and named `instanceof`; those paths now lower
  through `object_keys` plus `for_in_next`, `new_closure` plus `array_method`,
  generic `new_function`/`construct`, and generic `instanceof_value`.
- Removed in the same cleanup: private constructor and String wrapper marker
  properties. Constructor/prototype data now uses ordinary object/prototype
  links, and String wrapper payloads use object-owned string data.
- Removed in the 2026-04-26 native-function cleanup: Promise, collection, and
  closure function display paths no longer synthesize function-looking strings;
  they use function objects with native/source display payloads.
- Removed in the 2026-04-26 standard-global cleanup: value-level `Math` and
  `globalThis` marker constants. The parser now emits ordinary global/property
  bytecode for those names, and `exec/call.zig` installs the current standard
  global object/native-function properties.
- Follow-up semantic-completion work: narrow source-shape lowering, incomplete
  constructor/prototype descriptors, broader builtin/library scaffolds, and
  unknown/malformed bytecode `UnsupportedOpcode` traps.

Progress: the 2026-04-26 VM/domain extraction slice moved CLI-visible host
callable setup, host-call dispatch, and output formatting out of `exec/vm.zig`
and into `exec/call.zig`; it also replaced the VM `call` handler's fixed
32-argument buffer with allocator-backed storage. Focused `test-exec` coverage
locks both paths. The follow-up JSON slice moved `JSON.stringify`/`JSON.parse`
lowering into `quickjs_parser` and moved the narrow JSON implementation from
VM helpers into `builtins/json.zig`. The Math slice moved supported
`Math.<fn>` call lowering into `quickjs_parser` and moved the narrow
transitional `math_call` implementation from VM helpers into
`builtins/math.zig`, with VM dispatch now limited to argument collection and
builtin delegation. The URI slice moved supported global URI call lowering into
`quickjs_parser` and moved the narrow `uri_call` implementation from VM helpers
into `builtins/uri.zig`, while leaving current URI try/catch smoke fallback
shapes explicit transitional debt. The Number parse slice moved supported global
`parseInt`/`parseFloat` and `Number.parseInt`/`Number.parseFloat` lowering into
`quickjs_parser`, kept unsupported broader `Number(...)` shapes on transitional
paths, and moved `parse_int`/`parse_float` execution semantics into
`builtins/number.zig`. The Date slice moved supported `Date()` /
`Date.UTC` / `Date.parse` / `Date.now`, `new Date(...)`, and selected Date
method lowering into `quickjs_parser`, moved Date execution semantics into
`builtins/date.zig`, and left broader Date prototype/setter/locale/string
formatting support as explicit future Date debt. The RegExp slice moved
supported `new RegExp(pattern, flags)` and `toString` / `test` / `exec`
instance method lowering into `quickjs_parser`, moved the corresponding narrow
object payload and method behavior into `builtins/regexp.zig`, and intentionally
left nonstandard static `RegExp.test` / `RegExp.exec` on the existing
transitional TypeError path. The Promise slice moved supported
`new Promise(...)` and `Promise.resolve` / `Promise.all` / `Promise.race` /
`Promise.reject` lowering into `quickjs_parser`, moved the corresponding narrow
object construction and static helper behavior into `builtins/promise.zig`, and
preserved the current unhandled-rejection exception-slot path for
`Promise.reject`. The Collection slice moved supported `Map` / `Set` /
`WeakMap` / `WeakSet` construction and selected `set/get/has/delete/clear/add` method
lowering into `quickjs_parser`, moved the corresponding narrow single-entry
storage behavior into `builtins/collection.zig`, and left iterable
constructors, iteration order, full prototype descriptors, and weak-collection
GC integration as future Collection debt. The Buffer/DataView slice moved
supported ArrayBuffer construction/slicing, narrow TypedArray shape creation,
and DataView construction/get/set semantics into `builtins/buffer.zig`, with VM
opcode handlers reduced to operand collection and builtin delegation; full
TypedArray element semantics, detachment, SharedArrayBuffer, and complete
prototype descriptors remain future Buffer debt. The String slice moved
`new_string_object`, `string_from_char_code`, `string_char_at`, and
`string_method` semantics into `builtins/string.zig`, with VM opcode handlers
reduced to operand collection and builtin delegation; full String constructor
and prototype descriptor coverage, Unicode-sensitive methods, and broader
string integration remain future String debt. The Object slice moved object
literal construction, Object.is SameValue behavior, and Object keys/values/
entries array construction into `builtins/object.zig`; VM opcode handlers now
only decode operands and delegate, while full Object constructor/prototype
descriptors and ordinary property operation extraction remain future
Object/property debt. The Array slice moved array literal construction, `join`,
callback-backed `map`, and selected
prototype methods (`filterEven`, `reduceSum`, `some/every` fixture helpers,
`indexOf`/`includes`/`lastIndexOf`, `at`, `slice`, and `splice`) into
`builtins/array.zig`; VM opcode handlers now collect operands and delegate,
while parser-side Array lowering, species, iteration, descriptors, sparse-array
completeness, and broader prototype semantics remain future Array debt.
Output-bound `forEachPrint` is now an `exec/call.zig` transitional output
adapter.

The VM semantic-helper slice moved value arithmetic/comparison/equality,
truthiness/type conversion, BigInt coercion/asN, property get/set/optional/index
access, `in`/`instanceof`, closure fixture state, test262 throw/assert helpers,
and output-bound Array `forEachPrint` out of `exec/vm.zig` into
`exec/value_ops.zig`, `exec/property_ops.zig`, `exec/closure.zig`,
`exec/test262_helpers.zig`, and `exec/call.zig`. VM dispatch now owns operand
decoding, stack/frame/global-slot glue, and helper error mapping for those
paths; helper-level unsupported failures map to `TypeError`, while narrow
source-shape lowering and incomplete builtin/prototype domains remain explicit
transitional debt outside the VM semantic domain.

The test262 helper opcode slice removed the VM dispatch opcodes for
`assert_same_value` and `throw_test262_error`. `assert.sameValue(...)` now lowers
to ordinary `assert` global lookup, property lookup, and generic call; `throw
new Test262Error(...)` now lowers to a generic call to the installed
`Test262Error` host callable.

The remaining-opcode cleanup slice removed the simple `for-in` concatenation,
`Array.map(x => x * N)`, named construction, and named `instanceof` opcodes from
emitter and VM dispatch. The parser now emits generic loop, closure/callback,
constructor, and `instanceof` bytecode for the supported source shapes, while
`exec/construct.zig`, `exec/property_ops.zig`, and `exec/closure.zig` own the
runtime helpers. It also removed the private constructor/String marker
properties in favor of object prototype links and object-owned String wrapper
payloads.

The standard-global cleanup slice removed parser-emitted `Math` and
`globalThis` marker constants. `Math` and the current native constructor globals
are installed on the global object by `exec/call.zig`, and `globalThis`
identity/property reads use ordinary bytecode with a retained global-object
result to avoid premature refcount release of the global root.

Closure: parser metadata/source recognizers have been removed from parse
dispatch, legacy successful parse path markers have been removed, test262 helper
opcodes have been removed, and the known fixture-shaped VM opcodes from the
shortcut audit have been replaced with general bytecode and shared
builtin/property/call/construct semantics. Native-method string synthesis has
been replaced with function objects and VM helper unsupported fallbacks now
surface as `TypeError`. Value-level `Math`/`globalThis` marker constants have
also been replaced by ordinary global/property lowering plus standard global
object setup. Remaining semantic-completion work is tracked in `TRACKING.md`.

## Acceptance Gates

- `zig build test --summary all`
- `zig build smoke --summary all`
- `git diff --check`
- Targeted test262 slices for any changed syntax, VM, builtin, or library domain.
- Full local test262 gate before declaring a repair track complete.
