# Opcode Execution Matrix

Purpose: make Phase 6 track bytecode execution at opcode level. Phase 4 owns
opcode metadata; Phase 6 owns handlers and semantic execution tests.

Architecture repair note: historical `validated` rows prove metadata, fixture,
or local-baseline coverage for the recorded phase. VM helper-level unsupported
failures now surface as JS `TypeError`, with `UnsupportedOpcode` reserved for
unknown or malformed bytecode. Domain semantics still need to keep moving out
of VM dispatch during follow-up semantic completion. JSON stringify/parse,
`math_call`, `uri_call`, `parse_int`, `parse_float`, `date_call`,
`new_date`, `new_regexp`, and `new_promise` opcodes, plus `new_collection`,
`new_array_buffer`, `new_typed_array`, `new_dataview`,
`arraybuffer_slice`, `dataview_get`, `dataview_set`, `new_string_object`,
`new_object`,
`object_is`, `object_keys`, `object_values`, `object_entries`, `new_array`,
and `array_join` are currently transitional lowering opcodes
delegated from VM
dispatch to `builtins/json.zig` / `builtins/math.zig` / `builtins/uri.zig` /
`builtins/number.zig` / `builtins/date.zig` / `builtins/regexp.zig` /
`builtins/promise.zig` / `builtins/collection.zig` / `builtins/buffer.zig` /
`builtins/string.zig` / `builtins/object.zig` / `builtins/array.zig`. The
former Array/String/Date/RegExp/Promise method/static source shapes now lower
through receiver-preserving `call_prop` and dispatch to callable native function
objects in `exec/call.zig`; their legacy method/static opcode handlers remain
only as malformed/manual-bytecode compatibility glue. VM value/equality/conversion/BigInt helpers now live in
`exec/value_ops.zig`; property/in/instanceof helpers live in
`exec/property_ops.zig`; generic constructor helpers live in
`exec/construct.zig`; closure fixture state lives in `exec/closure.zig`; and
test262 helper behavior lives in `exec/test262_helpers.zig` and host callables
installed by `exec/call.zig`; current host callables include `assert`,
`assert.throws`, `assert.sameValue`, `assert.notSameValue`, `verifyProperty`,
`verifyCallableProperty`, and `isConstructor`, and the same setup installs
current standard global properties. The former test262 helper opcodes,
value-level `Math`/`globalThis`
marker constants, dead parser path markers, and the fixture-shaped simple
`for-in`, Array map multiplication, named construction, and named `instanceof`
opcodes have been removed; those source shapes now lower to ordinary
global/property bytecode, generic `for_in_next`, callback/`array_method`,
`new_function`/`construct`, and `instanceof_value` bytecode. Function-looking
Promise, collection, and closure display values now use function objects rather
than synthesized strings.

## Phase 4 Metadata Matrix

| Area | QuickJS owner | Zig owner | Required behavior | Required tests | Status |
|---|---|---|---|---|---|
| Opcode source parsing | `quickjs/quickjs-opcode.h` | `bytecode/opcode.zig` | Parse `FMT`, `DEF`, and `def` entries in QuickJS order without duplicating the table | Format count, opcode count, normal/temp/short boundaries | validated |
| Opcode metadata | `quickjs/quickjs-opcode.h` | `bytecode/opcode.zig`, `bytecode/format.zig` | Preserve name, size, pop/push counts, operand format, immediate width, stack delta, and opcode kind | Representative values for `push_i32`, `call`, `source_loc`, and short push opcodes | validated |
| Bytecode buffer | function bytecode records in `quickjs.c` | `bytecode/function.zig` | Own and replace bytecode bytes with deterministic release | Allocate/copy/free bytecode buffer | validated |
| Constant pool | function bytecode records in `quickjs.c` | `bytecode/constant.zig` | Retain/free `Value` constants with runtime ownership rules | String constant refcount test | validated |
| Scope metadata | closure variable and scope records in `quickjs.c` | `bytecode/scope.zig` | Store local bindings, lexical flags, captured flags, and closure variable coordinates | Binding and closure metadata tests | validated |
| Module bytecode metadata | module bytecode records in `quickjs.c` | `bytecode/module.zig` | Store request/import/export metadata with atom lifetime rules | Request/import/export ownership test | validated |
| Debug metadata | PC-to-line/debug records in `quickjs.c` | `bytecode/debug.zig` | Store filename atom and PC-to-line entries with lookup | Source line lookup and teardown test | validated |

## Full Per-Opcode Tracking Rule

Before Phase 6 starts, generate or manually populate a row for every non-format
opcode in `quickjs/quickjs-opcode.h`, including temporary and short opcodes. The
row schema is:

| Opcode | Kind | QuickJS source owner | Zig handler | Semantic group | Required fixture | Status |
|---|---|---|---|---|---|---|
| `example` | normal/temp/short | `quickjs.c` handler or lowering pass | `exec/*.zig` | group name | fixture path or description | not_started |

`validated` requires:

- Opcode metadata exists and matches Phase 4.
- The VM dispatch can reach the handler or the emitter/lowering proves the opcode
  is removed before final bytecode.
- A focused execution fixture exists, or the opcode is a temporary lowering-only
  opcode with a Phase 5/Phase 6 lowering test.

## Semantic Group Matrix

| Group | Representative opcodes | Zig owner | Required behavior | Status |
|---|---|---|---|---|
| Invalid/no-op | `invalid`, `nop` | `exec/vm.zig` | Invalid traps in tests; nop preserves state | validated |
| Push constants | `push_i32`, `push_const`, `undefined`, `null`, `push_true`, `push_false`, short `push_*` | `exec/vm.zig`, `core/value.zig` | Correct value creation, constant pool ownership, BigInt literal handoff | validated |
| Stack manipulation | `drop`, `nip`, `dup`, `insert*`, `perm*`, `swap*`, `rot*` | `exec/stack.zig` | Exact stack effects and bounds checks | validated |
| Calls and returns | `call*`, `tail_call*`, `call_constructor`, `apply`, `return*`, `check_ctor*`, `init_ctor` | `exec/call.zig`, `exec/construct.zig`, `builtins/function.zig` | Argument layout, `this`, constructor return rules, native/source function display, test262 host helper callables, callback closure thunks for current `assert.throws` cases, and tail-call behavior if supported by baseline | validated |
| Async/generator control | `return_async`, `initial_yield`, `yield`, `yield_star`, `async_yield_star`, `await`, transitional `new_promise`, receiver-preserving `call_prop` for Promise statics | `exec/vm.zig`, `exec/promise.zig`, `exec/jobs.zig`, `builtins/promise.zig`, `exec/call.zig` | Resume state, promise job ordering, iterator delegation, selected Promise constructor delegated to `builtins/promise.zig`, and selected Promise static helpers dispatched through callable native properties | validated |
| Exceptions | `throw`, `throw_error`, `catch`, `gosub`, `ret`, `nip_catch` | `exec/exceptions.zig` | Context exception state, finally execution, stack trace metadata | validated |
| Eval/import/regexp | `eval`, `apply_eval`, `import`, `regexp`, transitional `new_regexp`, receiver-preserving `call_prop` for RegExp methods | `exec/eval.zig`, `exec/module.zig`, `builtins/regexp.zig`, `exec/call.zig` | Direct/indirect eval, dynamic import promise, regexp object creation, selected RegExp instance methods dispatched through callable native properties | validated |
| Variables and refs | `get_var*`, `put_var*`, `define_var`, `define_func`, `get_ref_value`, `put_ref_value`, `make_*_ref`, `with_*` | `exec/vm.zig`, `exec/call.zig`, `bytecode/scope.zig` | Global/lexical lookup, current standard global object setup, TDZ checks, with-scope behavior, reference put/get | validated |
| Properties | `get_field*`, `put_field`, `get_array_el*`, `put_array_el`, `define_field`, `set_name*`, `set_proto`, `copy_data_properties` | `exec/property_ops.zig`, `core/object.zig` | Ordinary/exotic get/set/delete/define, computed names, object spread semantics, and current `globalThis` identity property behavior | validated |
| Object helpers | transitional `new_object`, `object_is`, `object_keys`, `object_values`, `object_entries` plus generic `new_function`/`construct` and ordinary `call_prop` Object statics | `builtins/object.zig`, `core/object.zig`, `exec/call.zig`, `exec/construct.zig` | Selected object literal construction, SameValue, Object define/get descriptor helpers, retained object returns from `Object.defineProperty`, Object keys/values/entries/names, and current generic constructor/prototype object creation semantics delegated outside VM domain helpers; Object/is test262 now passes 0/21 | validated |
| Array helpers | transitional `new_array`, `array_join`, receiver-preserving `call_prop` for methods | `builtins/array.zig`, `exec/call.zig`, `exec/vm.zig`, `exec/closure.zig` | Selected array construction and join delegated to `builtins/array.zig`; callback-backed map and selected prototype methods dispatch through callable native properties; output-bound `forEachPrint` delegated to `exec/call.zig`; VM remains operand-decoding glue | validated |
| Private/super/class | `get_private_field`, `put_private_field`, `define_private_field`, `private_in`, `get_super*`, `put_super_value`, `set_home_object`, `define_method*`, `define_class*`, `check_brand`, `add_brand` | `exec/property_ops.zig`, `exec/call.zig` | Brand checks, private names, home object, super lookup, class constructor/prototype setup | validated |
| Locals/args/closures | `get_loc*`, `put_loc*`, `set_loc*`, `get_arg*`, `put_arg*`, `set_arg*`, `get_var_ref*`, `put_var_ref*`, `set_var_ref*`, `close_loc`, transitional `new_closure`, transitional `call_closure` | `exec/frame.zig`, `exec/stack.zig`, `exec/closure.zig` | Fast locals/args, closure cells, TDZ, close-over lifetime, and current fixture closure state outside VM dispatch | validated |
| Branching | `if_false*`, `if_true*`, `goto*`, `label`, `source_loc` | `exec/vm.zig`, `bytecode/debug.zig` | PC updates, label lowering, source location update | validated |
| Conversions | `to_object`, `to_propkey`, `to_propkey2`, `typeof*`, `is_undefined*`, `is_null`, `is_undefined_or_null` | `exec/value_ops.zig`, `core/value.zig`, `builtins/*` | Current value conversion, truthiness, `typeof`, and string/number/boolean coercion behavior outside VM dispatch | validated |
| Iteration and collections | `for_in_*`, `for_of_*`, `for_await_of_start`, `iterator_*`, transitional `new_collection`, receiver-preserving `call_prop` | `exec/iterator.zig`, `exec/call.zig`, `builtins/collection.zig`, `exec/vm.zig`, `builtins/function.zig` | Iterator protocol, close behavior, async iterator handoff, current simple `for-in` key iteration through `for_in_next`, selected collection constructors delegated to `builtins/collection.zig`, VM-created collection instances inherit registered prototype methods, and selected collection prototype calls now use function object properties plus `call_prop` receiver dispatch instead of `collection_method` lowering | validated |
| Buffers and binary data | transitional `new_array_buffer`, `new_typed_array`, `new_dataview`, `arraybuffer_slice`, `dataview_get`, `dataview_set` | `builtins/buffer.zig` | Selected ArrayBuffer, TypedArray shape, and DataView constructor/get/set semantics delegated to `builtins/buffer.zig` | validated |
| Strings and text | transitional `new_string_object`, receiver-preserving `call_prop` for `String.fromCharCode`, primitive/string-wrapper methods | `builtins/string.zig`, `exec/call.zig` | Selected String wrapper construction delegated to `builtins/string.zig`; `fromCharCode`, `charAt`, and selected prototype methods dispatch through callable native properties | validated |
| Arithmetic/unary | `neg`, `plus`, `dec`, `inc`, `post_*`, `dec_loc`, `inc_loc`, `add_loc`, `not`, `lnot`, `delete`, `delete_var` | `exec/value_ops.zig`, `core/value.zig` | Numeric/BigInt unary semantics, truthiness, and current factorial helper outside VM dispatch; side-effecting delete paths remain future debt | validated |
| Binary arithmetic | `mul`, `div`, `mod`, `add`, `sub`, `shl`, `sar`, `shr`, `and`, `xor`, `or`, `pow` | `exec/value_ops.zig`, `core/bigint.zig`, `libs/bignum.zig` | Number/BigInt semantics, string concatenation, and errors for mixed BigInt/Number outside VM dispatch | validated |
| Comparisons | `lt`, `lte`, `gt`, `gte`, `instanceof`, `instanceof_value`, `in`, `eq`, `neq`, `strict_eq`, `strict_neq` | `exec/value_ops.zig`, `exec/property_ops.zig` | Abstract/strict equality, relational comparison, current `in`, and current constructor-prototype `instanceof` behavior outside VM domain shortcuts | validated |
| Temporary lowering opcodes | `enter_scope`, `leave_scope`, `scope_*`, `get_field_opt_chain`, `get_array_el_opt_chain`, `set_class_name` | `bytecode/emitter.zig`, `exec/vm.zig` if still reachable | Lowered before final bytecode or explicitly handled if reachable | validated |
| Short opcodes | `push_*`, `get_loc*`, `put_loc*`, `set_loc*`, `get_arg*`, `put_arg*`, `set_arg*`, `call0..3`, short branches | `exec/vm.zig`, `exec/frame.zig` | Same semantics as long form with compressed operands | validated |

## Phase 6 Exit Additions

- No opcode group may remain `not_started`.
- A full per-opcode table must be present here or generated from `bytecode/opcode.zig`
  and linked from this file.
- Any opcode marked lowering-only must have a test proving it is absent from final
  bytecode or handled safely if encountered.
