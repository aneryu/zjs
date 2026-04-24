# Opcode Execution Matrix

Purpose: make Phase 6 track bytecode execution at opcode level. Phase 4 owns
opcode metadata; Phase 6 owns handlers and semantic execution tests.

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
| Invalid/no-op | `invalid`, `nop` | `exec/vm.zig` | Invalid traps in tests; nop preserves state | not_started |
| Push constants | `push_i32`, `push_const`, `undefined`, `null`, `push_true`, `push_false`, short `push_*` | `exec/vm.zig`, `core/value.zig` | Correct value creation, constant pool ownership, BigInt literal handoff | not_started |
| Stack manipulation | `drop`, `nip`, `dup`, `insert*`, `perm*`, `swap*`, `rot*` | `exec/stack.zig` | Exact stack effects and bounds checks | not_started |
| Calls and returns | `call*`, `tail_call*`, `call_constructor`, `apply`, `return*`, `check_ctor*`, `init_ctor` | `exec/call.zig`, `exec/construct.zig` | Argument layout, `this`, constructor return rules, tail-call behavior if supported by baseline | not_started |
| Async/generator control | `return_async`, `initial_yield`, `yield`, `yield_star`, `async_yield_star`, `await` | `exec/vm.zig`, `exec/promise.zig`, `exec/jobs.zig` | Resume state, promise job ordering, iterator delegation | not_started |
| Exceptions | `throw`, `throw_error`, `catch`, `gosub`, `ret`, `nip_catch` | `exec/exceptions.zig` | Context exception state, finally execution, stack trace metadata | not_started |
| Eval/import/regexp | `eval`, `apply_eval`, `import`, `regexp` | `exec/eval.zig`, `exec/module.zig`, `builtins/regexp.zig` | Direct/indirect eval, dynamic import promise, regexp object creation | not_started |
| Variables and refs | `get_var*`, `put_var*`, `define_var`, `define_func`, `get_ref_value`, `put_ref_value`, `make_*_ref`, `with_*` | `exec/vm.zig`, `bytecode/scope.zig` | Global/lexical lookup, TDZ checks, with-scope behavior, reference put/get | not_started |
| Properties | `get_field*`, `put_field`, `get_array_el*`, `put_array_el`, `define_field`, `set_name*`, `set_proto`, `copy_data_properties` | `exec/property_ops.zig`, `core/object.zig` | Ordinary/exotic get/set/delete/define, computed names, object spread semantics | not_started |
| Private/super/class | `get_private_field`, `put_private_field`, `define_private_field`, `private_in`, `get_super*`, `put_super_value`, `set_home_object`, `define_method*`, `define_class*`, `check_brand`, `add_brand` | `exec/property_ops.zig`, `exec/call.zig` | Brand checks, private names, home object, super lookup, class constructor/prototype setup | not_started |
| Locals/args/closures | `get_loc*`, `put_loc*`, `set_loc*`, `get_arg*`, `put_arg*`, `set_arg*`, `get_var_ref*`, `put_var_ref*`, `set_var_ref*`, `close_loc` | `exec/frame.zig`, `exec/stack.zig` | Fast locals/args, closure cells, TDZ, close-over lifetime | not_started |
| Branching | `if_false*`, `if_true*`, `goto*`, `label`, `source_loc` | `exec/vm.zig`, `bytecode/debug.zig` | PC updates, label lowering, source location update | not_started |
| Conversions | `to_object`, `to_propkey`, `to_propkey2`, `typeof*`, `is_undefined*`, `is_null`, `is_undefined_or_null` | `exec/vm.zig`, `core/value.zig`, `builtins/*` | ECMAScript conversions and typeof behavior | not_started |
| Iteration | `for_in_*`, `for_of_*`, `for_await_of_start`, `iterator_*` | `exec/iterator.zig` | Iterator protocol, close behavior, async iterator handoff | not_started |
| Arithmetic/unary | `neg`, `plus`, `dec`, `inc`, `post_*`, `dec_loc`, `inc_loc`, `add_loc`, `not`, `lnot`, `delete`, `delete_var` | `exec/vm.zig`, `core/value.zig` | Numeric/BigInt dispatch, side effects, delete semantics | not_started |
| Binary arithmetic | `mul`, `div`, `mod`, `add`, `sub`, `shl`, `sar`, `shr`, `and`, `xor`, `or`, `pow` | `exec/vm.zig`, `builtins/bigint.zig` | Number/BigInt semantics, string concatenation, errors for mixed BigInt/Number | not_started |
| Comparisons | `lt`, `lte`, `gt`, `gte`, `instanceof`, `in`, `eq`, `neq`, `strict_eq`, `strict_neq` | `exec/vm.zig`, `exec/property_ops.zig` | Abstract/strict equality, relational comparison, private `in`, prototype checks | not_started |
| Temporary lowering opcodes | `enter_scope`, `leave_scope`, `scope_*`, `get_field_opt_chain`, `get_array_el_opt_chain`, `set_class_name` | `bytecode/emitter.zig`, `exec/vm.zig` if still reachable | Lowered before final bytecode or explicitly handled if reachable | not_started |
| Short opcodes | `push_*`, `get_loc*`, `put_loc*`, `set_loc*`, `get_arg*`, `put_arg*`, `set_arg*`, `call0..3`, short branches | `exec/vm.zig`, `exec/frame.zig` | Same semantics as long form with compressed operands | not_started |

## Phase 6 Exit Additions

- No opcode group may remain `not_started`.
- A full per-opcode table must be present here or generated from `bytecode/opcode.zig`
  and linked from this file.
- Any opcode marked lowering-only must have a test proving it is absent from final
  bytecode or handled safely if encountered.

