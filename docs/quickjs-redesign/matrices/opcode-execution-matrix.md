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

## F2 prep — Bespoke Opcode Expansion Plans

Pre-flight audit (PARSER_REWRITE_PLAN.md §2.5) identified 61 bespoke opcodes
in the legacy emitter that have no counterpart in `quickjs-opcode.h`. They
currently squat on real QuickJS opcode ids that are reserved for unrelated
operations, so the F2+F3 atomic swap (PARSER_REWRITE_PLAN.md §2.5.5/§2.5.6)
must replace each emit site with a real op sequence, a real built-in call,
or drop it entirely.

This table is the published expansion plan that must land **before** F2's
VM/parser rewrite. Each row commits a strategy. Entries are grouped by the
three buckets defined in §2.5.5 and ordered by current emit-site frequency
in `frontend/parser.zig`.

### Bucket A — Expand to real op sequence inside the emitter

Each row's "Real op sequence" column lists the QuickJS opcode names (from
`bytecode/opcode.zig: op`) that must be emitted in place of the bespoke op.

| Bespoke opcode | Strategy | Real op sequence | Notes |
|---|---|---|---|
| `set_prop name` | rewrite | `put_field name` | direct rename to QuickJS shape |
| `get_prop name` | rewrite | `get_field name` | direct rename |
| `optional_get_prop name` | rewrite | `get_field_opt_chain name` | Phase 1 temp; F10 lowers to real `get_field` chain |
| `get_index` | rewrite | `get_array_el` | numeric/string index path |
| `new_array n` | rewrite | `array_from n` | `array_from` matches stack contract `args... -> arr` |
| `new_object n + atom_list` | rewrite | `object` + (`define_field name`)* | `object` pushes `{}`, then per-slot `define_field` |
| `call_prop atom argc` | rewrite | `dup ; get_field atom ; swap ; call_method argc` | preserves `this` receiver |
| `bit_not` | rename | `not` | QuickJS calls bitwise NOT just `not` |
| `typeof_value` | rename | `typeof` | |
| `bit_and / bit_or / bit_xor` | rename | `and / or / xor` | |
| `gte` | keep | `gte` | exists in QuickJS, but at id 168 (we squat 218) — same swap fixes id |
| `eq / strict_eq / strict_neq` | rename | identical names at correct ids | id swap only |
| `mul / div / mod / add / sub / shl / sar / shr / pow` | rename | identical names at correct ids | id swap only |
| `goto pc` | rewrite | `goto label` (label-relative) | F3.4 label resolution rewrites to relative `goto8`/`goto16` in resolve_labels |
| `get_var atom` | keep | `get_var atom` | exists at correct id 56 (we squat 61) |
| `define_var atom` | keep | `define_var atom` | exists at correct id 61 (we squat 66) |
| `define_class atom` | keep | `define_class atom` | exists at correct id 85 (we squat 91) |
| `import` | keep | `import` | exists at correct id 54 (we squat 59) |
| `drop` | keep | `drop` | exists at correct id 14 (we squat 11) |
| `return_undef` | keep | `return_undef` | exists at correct id 41 (we squat 45) |
| `for_in_next atom patch` | rewrite | `for_in_next` (no atom; QuickJS form) | drop the atom payload — the real op uses iterator state on stack |
| `value_length` | rewrite | `get_field length` | atom for `length` already in predefined table |
| `logical_and` | rewrite | `dup ; if_false L_skip ; drop ; <rhs> ; L_skip:` | short-circuit branch |
| `logical_or` | rewrite | `dup ; if_true L_skip ; drop ; <rhs> ; L_skip:` | |
| `nullish_coalesce` | rewrite | `dup ; is_undefined_or_null ; if_false L_skip ; drop ; <rhs> ; L_skip:` | |
| `value_to_number` | rewrite | (built-in coercion) | F4 emits explicit unary `+` lowering; no dedicated op |
| `value_to_boolean` | rewrite | (built-in coercion) | use `lnot ; lnot` pair, or rely on truthiness in branch ops |
| `value_to_string` | rewrite | `get_var String ; get_field call ; swap ; call_method 1` | invoke `String(value)` |
| `prop_in` | rewrite | `in` | direct QuickJS opcode |
| `instanceof_array / instanceof_object / instanceof_value` | rewrite | `instanceof` | unify on the generic op |
| `factorial` | drop | (none — runtime call) | not a real JS op; remove from emitter and any fixture |
| `new_array_buffer` | rewrite | `get_var ArrayBuffer ; call_constructor 0` | |

### Bucket B — Reroute through a real built-in call

Each row replaces the bespoke op with the standard call shape
`get_var <Ctor> ; get_field <method> ; <args> ; call <argc>` (or
`call_method` when receiver is on the stack). The relevant built-in is
already implemented under `src/engine/builtins/*` (WQ-007/008/012); F2
only changes how the parser reaches them.

| Bespoke opcode | Replacement call shape |
|---|---|
| `math_call(id)` | `get_var Math ; get_field <method> ; <args> ; call argc` |
| `string_method(id, argc)` | `get_field <method> ; call_method argc` (receiver pre-pushed) |
| `string_from_char_code(argc)` | `get_var String ; get_field fromCharCode ; <args> ; call argc` |
| `string_char_at` | `get_field charAt ; call_method 1` |
| `array_method(method)` | `get_field <method> ; call_method argc` |
| `array_join` | `get_field join ; call_method 0..1` |
| `object_keys / object_values / object_entries` | `get_var Object ; get_field <method> ; call 1` |
| `object_is` | `get_var Object ; get_field is ; call 2` |
| `json_stringify` | `get_var JSON ; get_field stringify ; call 1..3` |
| `json_parse` | `get_var JSON ; get_field parse ; call 1..2` |
| `parse_int(argc)` | `get_var parseInt ; call argc` |
| `parse_float` | `get_var parseFloat ; call 1` |
| `uri_call(mode)` | `get_var <encodeURI/decodeURI/...> ; call 1` |
| `new_date(argc)` | `get_var Date ; call_constructor argc` |
| `date_call(argc)` | `get_var Date ; call argc` |
| `date_static(encoded)` | `get_var Date ; get_field <method> ; call argc` |
| `date_method(encoded)` | `get_field <method> ; call_method argc` |
| `new_collection(kind)` | `get_var <Map/Set/WeakMap/WeakSet> ; call_constructor 0` |
| `new_typed_array(elem)` | `get_var <Int8Array/...> ; call_constructor argc` |
| `new_dataview(argc)` | `get_var DataView ; call_constructor argc` |
| `dataview_get(kind, argc)` | `get_field <getInt8/getFloat32/...> ; call_method argc` |
| `dataview_set(kind, argc)` | `get_field <setInt8/...> ; call_method argc` |
| `arraybuffer_slice` | `get_field slice ; call_method argc` |
| `new_string_object(argc)` | `get_var String ; call_constructor argc` |
| `new_promise` | `get_var Promise ; call_constructor 1` |
| `promise_static(mode)` | `get_var Promise ; get_field <resolve/reject/all/...> ; call argc` |
| `new_regexp` | `regexp` (real QuickJS opcode at id 52) — pattern/flags from stack |
| `regexp_method(method)` | `get_field <exec/test> ; call_method argc` |
| `new_function atom` | `fclosure const_idx` — closure literal is a constant-pool entry, not a runtime call |
| `new_closure encoded` | `fclosure const_idx` — same as `new_function`, the encoded scratch state goes away |
| `call_closure argc` | `call argc` — just the QuickJS form |
| `bigint_as_int_n / bigint_as_uint_n` | `get_var BigInt ; get_field asIntN/asUintN ; call 2` |

### Bucket C — Drop entirely

These have no real JS counterpart and were synthetic shortcuts for
fixture-driven recognisers. The matching parser recogniser is removed in
F11 (already partially scoped in WQ-011); no replacement op is needed.

| Bespoke opcode | Replacement |
|---|---|
| `throw_type_error` | `throw_error <atom>, <ctor=TypeError>` (real QuickJS shape, format `atom_u8`) |
| `throw_syntax_error` | `throw_error <atom>, <ctor=SyntaxError>` |
| `throw_range_error` | `throw_error <atom>, <ctor=RangeError>` |
| `throw_reference_error` | `throw_error <atom>, <ctor=ReferenceError>` |
| `throw_eval_error` | `throw_error <atom>, <ctor=EvalError>` |
| `construct argc` | `call_constructor argc` (real QuickJS shape) |

### Open follow-ups

- The encoded operand layouts for `dataview_get/set`, `string_method`,
  `date_method` etc. (`(kind << 16) | argc`, `(id << 8) | argc`) lose
  meaning once they become regular `call_method`s. F2 PR removes the
  encoding helpers in `bytecode/emitter.zig` and the matching decode
  branches in `exec/vm.zig`.
- The fixture-only `factorial` op and any helper that exists solely for
  test262 sanity (`new_function`, `new_closure`, `call_closure` in their
  current bespoke form) move to `fclosure` + ordinary `call`. Closure
  capture is handled by Phase 2 `resolve_variables` building the real
  `closure_var[]` table.
- After F2 lands, every row above must be removed from this matrix and
  re-recorded as a regular validated entry in the per-family tables
  (calls/properties/arithmetic/...) at the top of this file.
