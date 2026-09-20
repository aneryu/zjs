//! Cold opcode handlers for the tail-call dispatcher: one handler per opcode,
//! each a `publish -> helper -> coldNext` shell. `buildTable` assembles the
//! 256-entry table from these plus the special handlers the main file passes
//! in. `fast = false` yields the all-cold table the fast handlers fall back
//! through; `fast = true` overrides ~100 slots with register-resident handlers.
//! Handlers land in the op-handler section via `dispatch.coldStd`'s wrapper.

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const dispatch = @import("tailcall_dispatch.zig");
const HostError = @import("exceptions.zig").HostError;

const Vm = dispatch.Vm;
const Handler = dispatch.Handler;
const coldStd = dispatch.coldStd;
const cold = dispatch.cold;
const coldOp = dispatch.coldOp;
const op = bytecode.opcode.op;

const vm_value = @import("vm_value.zig");
const vm_arith = @import("vm_arith.zig");
const vm_control = @import("vm_control.zig");
const vm_call = @import("vm_call.zig");
const object_ops = @import("object_ops.zig");
const exception_ops = @import("exception_ops.zig");
const vm_literal = @import("vm_literal.zig");
const iterator_ops = @import("iterator_ops.zig");
const vm_regexp = @import("vm_regexp.zig");
const vm_eval_module = @import("vm_eval_module.zig");
const vm_property_locals = @import("vm_property_locals.zig");
const vm_property_ref = @import("vm_property_ref.zig");
const vm_property_globals = @import("vm_property_globals.zig");
const vm_property_field = @import("vm_property_field.zig");
const vm_property_private = @import("vm_property_private.zig");
const using_ops = @import("using_ops.zig");

// ---- Shared handlers (op groups sharing helper+args) ----
pub const h_varref = coldOp(vm_property_locals.varRefVm);
pub const h_checkedloc = coldOp(vm_property_locals.checkedLocVm);
pub const h_loc = coldOp(vm_property_locals.loc);
pub const h_arg = coldOp(vm_property_locals.arg);
pub const h_get_arg_short = coldOp(vm_property_locals.getArgShort);
pub const h_binary = coldOp(vm_arith.binaryVm);
pub const h_unary = coldOp(vm_arith.unaryVm);
pub const h_field = coldOp(vm_property_field.field);
pub const h_get_array_element = coldOp(vm_property_field.getArrayElement);
pub const h_put_array_element = cold(vm_property_field.putArrayElementAfterFastMiss);
pub const h_get_var = coldOp(vm_property_globals.getVar);
/// Miss continuation for `dispatch.op_put_var` (and OP_put_var in the all-cold
/// table). The cell direct-write arm lives in the resident handler, not here.
pub const h_put_var = cold(vm_property_globals.putVar);
pub const h_dyn_env_probe = cold(vm_property_ref.dynEnvProbe);
pub const h_make_slot_ref = coldOp(vm_property_ref.makeSlotRef);
pub const h_define_class = coldOp(object_ops.defineClass);
pub const h_for_of_start = coldOp(iterator_ops.forOfStartVm);

pub const SpecialHandlers = struct {
    op_return: Handler,
    op_return_undef: Handler,
    op_call: Handler,
    op_call0: Handler,
    op_call1: Handler,
    op_call2: Handler,
    op_call3: Handler,
    op_call_method: Handler,
    op_call_method_apply_fwd: Handler,
    op_apply: Handler,
    op_call_constructor: Handler,
    op_for_of_next: Handler,
    op_tail_call: Handler,
    op_tail_call_method: Handler,
    op_eval: Handler,
    op_drop: Handler,
    op_throw: Handler,
    op_throw_error: Handler,
    h_initial_yield: Handler,
    h_yield: Handler,
    h_yield_star: Handler,
    h_await: Handler,
    op_invalid: Handler,
};

pub const BuiltTable = struct {
    table: [256]Handler,
    /// Handler bodies for opcode slots that fusion reclaimed. Not reachable dispatch
    /// arms (nothing indexes this array); the field only gives the comptime
    /// instantiations a home so the island geometry stays stable.
    keep: [12]Handler,
};

pub fn buildTable(s: SpecialHandlers, comptime fast: bool) BuiltTable {
    var t: [256]Handler = [_]Handler{s.op_invalid} ** 256;
    var keep: [12]Handler = .{
        s.op_invalid, s.op_invalid, s.op_invalid, s.op_invalid,
        s.op_invalid, s.op_invalid, s.op_invalid, s.op_invalid,
        s.op_invalid, s.op_invalid, s.op_invalid, s.op_invalid,
    };

    // --- pushes ---
    t[op.push_i32] = cold(vm_value.pushInt32Operand);
    t[op.push_bigint_i32] = cold(vm_value.pushBigIntI32Operand);
    t[op.push_i16] = cold(vm_value.pushI16Operand);
    t[op.push_i8] = cold(vm_value.pushI8Operand);
    t[op.push_const] = cold(vm_value.pushConst);
    t[op.push_const8] = cold(vm_value.pushConst8);
    t[op.private_symbol] = cold(struct {
        fn body(vm: *Vm) HostError!void {
            try vm_value.pushPrivateSymbol(vm.ctx, vm.stack, vm.function, vm.frame);
        }
    }.body);
    t[op.regexp] = cold(vm_regexp.pushLiteral);
    t[op.fclosure] = coldOp(vm_call.closure);
    t[op.fclosure8] = t[op.fclosure];
    t[op.undefined] = cold(vm_value.pushUndefined);
    t[op.null] = cold(vm_value.pushNull);
    t[op.push_false] = coldOp(vm_value.pushBoolean);
    t[op.push_true] = coldOp(vm_value.pushBoolean);
    inline for ([_]u8{ op.push_minus1, op.push_0, op.push_1, op.push_2, op.push_3, op.push_4, op.push_5, op.push_6, op.push_7 }) |o| t[o] = coldOp(vm_value.pushSmallInt);
    t[op.push_atom_value] = cold(vm_value.pushAtomValue);
    t[op.push_empty_string] = cold(vm_value.pushEmptyString);

    // --- locals / args / var_refs / checked ---
    inline for ([_]u8{ op.get_loc, op.put_loc, op.set_loc, op.get_loc8, op.put_loc8, op.set_loc8, op.get_loc0, op.get_loc1, op.get_loc2, op.get_loc3, op.put_loc0, op.put_loc1, op.put_loc2, op.put_loc3, op.set_loc0, op.set_loc1, op.set_loc2, op.set_loc3 }) |o| t[o] = h_loc;
    inline for ([_]u8{ op.get_arg0, op.get_arg1, op.get_arg2, op.get_arg3 }) |o| t[o] = h_get_arg_short;
    inline for ([_]u8{ op.get_arg, op.put_arg, op.set_arg, op.put_arg0, op.put_arg1, op.put_arg2, op.put_arg3, op.set_arg0, op.set_arg1, op.set_arg2, op.set_arg3 }) |o| t[o] = h_arg;
    inline for ([_]u8{ op.get_var_ref, op.get_var_ref_check, op.get_var_ref0, op.get_var_ref1, op.get_var_ref2, op.get_var_ref3, op.put_var_ref, op.put_var_ref_check, op.put_var_ref0, op.put_var_ref1, op.put_var_ref2, op.put_var_ref3, op.put_var_ref_check_init, op.set_var_ref, op.set_var_ref0, op.set_var_ref1, op.set_var_ref2, op.set_var_ref3 }) |o| t[o] = h_varref;
    inline for ([_]u8{ op.get_loc_check, op.get_loc_checkthis, op.put_loc_check, op.set_loc_check, op.put_loc_check_init, op.set_loc_uninitialized }) |o| t[o] = h_checkedloc;

    // --- names ---
    // to_propkey has no entry: its quarantined byte falls to the invalid handler
    // (execution reaches toPropKeyVm through the `using` carrier).
    t[op.set_name] = coldStd(struct {
        fn body(vm: *Vm, pc: [*]const u8) HostError!void {
            try vm_property_field.setName(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, pc[0]);
        }
    }.body);
    // set_name_computed likewise: quarantined byte, reached via the ext0 carrier.
    t[op.nip_catch] = cold(vm_value.nipCatch);

    // --- arith / compare / unary ---
    inline for ([_]u8{ op.add, op.sub, op.mul, op.div, op.mod, op.pow, op.shl, op.sar, op.shr, op.@"and", op.@"or", op.xor }) |o| t[o] = h_binary;
    t[op.div] = dispatch.op_div_cold;
    t[op.mod] = dispatch.op_mod_cold;
    // Register-resident cold bitwise/shift (in place on sp[-2], like qjs
    // js_binary_logic_slow); falls back to h_binary for non-number operands and at the generator stop.
    inline for ([_]u8{ op.shl, op.sar, op.shr, op.@"and", op.@"or", op.xor }) |o| t[o] = dispatch.opLogicCold;
    // Register-resident cold compare; falls back to compareVm at the generator stop.
    // Reached indirectly through cold_table so the int32 fast-path codegen is undisturbed.
    inline for ([_]u8{ op.lt, op.lte, op.gt, op.gte, op.eq, op.neq, op.strict_eq, op.strict_neq }) |o| t[o] = dispatch.opCompareCold(o);
    inline for ([_]u8{ op.neg, op.to_number, op.inc, op.dec }) |o| t[o] = h_unary;
    t[op.in] = coldOp(vm_property_field.inOrInstanceof);
    t[op.instanceof] = coldOp(vm_property_field.inOrInstanceof);
    t[op.private_in] = cold(object_ops.privateInVm);
    t[op.not] = cold(vm_arith.bitNotVm);
    t[op.lnot] = cold(vm_value.logicalNot);
    t[op.post_inc] = coldOp(vm_arith.postUpdateVm);
    t[op.post_dec] = coldOp(vm_arith.postUpdateVm);
    // Register-resident cold inc_loc/dec_loc (float counters); same indirect install.
    t[op.inc_loc] = dispatch.op_update_loc_cold;
    t[op.dec_loc] = dispatch.op_update_loc_cold;
    // op_add_loc's cold handler folds coldStd+addLocalVm into one hop; the hot miss tails into it.
    t[op.add_loc] = dispatch.op_add_loc_cold;

    // --- control ---
    // qjs polls interrupts on every goto: the back edge is a pure loop's only poll point.
    t[op.goto] = cold(vm_control.gotoPoll32);
    t[op.goto16] = cold(vm_control.gotoPoll16);
    t[op.goto8] = cold(vm_control.gotoPoll8);
    t[op.if_false] = coldOp(vm_control.branchPoll32);
    t[op.if_true] = coldOp(vm_control.branchPoll32);
    t[op.if_false8] = coldOp(vm_control.branchPoll8);
    t[op.if_true8] = coldOp(vm_control.branchPoll8);
    t[op.gosub] = cold(vm_control.gosub);
    t[op.ret] = cold(vm_control.ret);

    // --- globals / refs / with ---
    t[op.get_var] = h_get_var;
    t[op.get_var_undef] = h_get_var;
    t[op.put_var] = h_put_var;
    inline for ([_]u8{ op.make_loc_ref, op.make_arg_ref, op.make_var_ref_ref }) |o| t[o] = h_make_slot_ref;
    t[op.make_var_ref] = cold(vm_property_ref.makeVarRefVm);
    t[op.get_ref_value] = cold(vm_property_ref.getRefValueVm);
    t[op.put_ref_value] = cold(vm_property_ref.putRefValueVm);
    t[op.dyn_env_probe] = h_dyn_env_probe;

    // --- fields / private / array_el / super ---
    inline for ([_]u8{ op.get_field, op.get_field2, op.put_field }) |o| t[o] = h_field;
    t[op.get_private_field] = cold(vm_property_private.getPrivateFieldVm);
    t[op.put_private_field] = cold(vm_property_private.putPrivateFieldVm);
    t[op.define_private_field] = cold(vm_property_private.definePrivateFieldVm);
    inline for ([_]u8{ op.get_array_el, op.get_array_el2, op.get_array_el3 }) |o| t[o] = h_get_array_element;
    t[op.put_array_el] = h_put_array_element;
    t[op.get_super] = cold(object_ops.getSuper);
    t[op.get_super_value] = cold(object_ops.getSuperValue);
    t[op.get_length] = cold(vm_literal.getLength);

    // --- literals / class ---
    t[op.object] = cold(vm_literal.object);
    t[op.object_slots2] = cold(vm_literal.objectReserved2);
    t[op.array_from] = cold(vm_literal.arrayFrom);
    t[op.define_field] = cold(vm_literal.defineField);
    t[op.set_home_object] = cold(object_ops.setHomeObject);
    t[op.define_class] = h_define_class;
    t[op.define_class_computed] = h_define_class;
    t[op.define_array_el] = cold(vm_literal.defineArrayEl);
    t[op.define_method] = cold(object_ops.defineMethod);
    t[op.define_method_computed] = cold(object_ops.defineMethodComputed);
    t[op.append] = coldOp(vm_literal.appendSpreadValuesVm);
    t[op.copy_data_properties] = cold(vm_literal.copyDataProperties);
    t[op.put_var_init] = coldOp(vm_property_globals.globalDefinition);
    t[op.special_object] = cold(vm_literal.specialObject);
    t[op.ext0] = cold(using_ops.execVm);
    t[op.rest] = cold(vm_literal.rest);

    // --- typeof / is_* ---
    t[op.typeof] = cold(vm_value.typeOf);
    // Three type tests whose opcode slots fusion reclaimed; parked in `keep` (not
    // reachable arms) so the island geometry is unchanged. ICF folds the pair.
    keep[0] = cold(struct {
        fn body(vm: *Vm) HostError!void {
            try vm_value.typeOfIsUndefined(vm.ctx.runtime, vm.stack);
        }
    }.body);
    keep[1] = cold(struct {
        fn body(vm: *Vm) HostError!void {
            try vm_value.typeOfIsFunction(vm.ctx.runtime, vm.stack);
        }
    }.body);
    t[op.is_undefined_or_null] = cold(vm_value.isUndefinedOrNull);
    keep[2] = cold(struct {
        fn body(vm: *Vm) HostError!void {
            try vm_value.isUndefined(vm.ctx.runtime, vm.stack);
        }
    }.body);
    t[op.is_null] = cold(vm_value.isNull);

    // --- stack manipulation ---
    t[op.dup] = cold(vm_value.dup);
    t[op.swap] = cold(vm_value.swap);
    t[op.nip] = cold(vm_value.nip);
    keep[11] = cold(struct {
        fn body(vm: *Vm) HostError!void {
            try vm_value.dup1(vm.ctx, vm.stack);
        }
    }.body);
    keep[6] = cold(struct {
        fn body(vm: *Vm) HostError!void {
            try vm_value.dup2(vm.ctx, vm.stack);
        }
    }.body);
    keep[10] = cold(struct {
        fn body(vm: *Vm) HostError!void {
            try vm_value.dup3(vm.ctx, vm.stack);
        }
    }.body);
    t[op.insert2] = cold(vm_value.insert2);
    t[op.insert3] = cold(vm_value.insert3);
    keep[3] = cold(struct {
        fn body(vm: *Vm) HostError!void {
            try vm_value.insert4(vm.ctx, vm.stack);
        }
    }.body);
    t[op.rot3l] = cold(vm_value.rot3l);
    keep[8] = cold(struct {
        fn body(vm: *Vm) HostError!void {
            try vm_value.rot3r(vm.ctx, vm.stack);
        }
    }.body);
    keep[9] = cold(struct {
        fn body(vm: *Vm) HostError!void {
            try vm_value.rot4l(vm.ctx, vm.stack);
        }
    }.body);
    keep[4] = cold(struct {
        fn body(vm: *Vm) HostError!void {
            try vm_value.rot5l(vm.ctx, vm.stack);
        }
    }.body);
    t[op.perm3] = cold(vm_value.perm3);
    t[op.perm4] = cold(vm_value.perm4);
    keep[5] = cold(struct {
        fn body(vm: *Vm) HostError!void {
            try vm_value.perm5(vm.ctx, vm.stack);
        }
    }.body);
    keep[7] = cold(struct {
        fn body(vm: *Vm) HostError!void {
            try vm_value.swap2(vm.ctx, vm.stack);
        }
    }.body);

    // --- ctor / brand / misc ---
    t[op.@"catch"] = cold(struct {
        fn body(vm: *Vm) HostError!void {
            try vm_control.catchTarget(vm.function, vm.frame, vm.stack, vm.catch_target);
        }
    }.body);
    t[op.check_ctor] = cold(vm_call.checkCtorVm);
    t[op.init_ctor] = cold(vm_call.initCtorVm);
    t[op.check_brand] = cold(object_ops.checkBrandVm);
    t[op.add_brand] = cold(object_ops.addBrandVm);
    t[op.close_loc] = cold(vm_property_locals.closeLoc);
    t[op.nop] = cold(struct {
        fn body(vm: *Vm) HostError!void {
            _ = vm;
        }
    }.body);
    t[op.push_this] = cold(vm_value.pushThisVm);
    t[op.delete_var] = cold(vm_property_ref.deleteVar);
    t[op.delete] = cold(vm_property_ref.deletePropertyVm);
    t[op.apply] = s.op_apply;
    t[op.call_constructor] = s.op_call_constructor;
    t[op.apply_eval] = cold(vm_eval_module.applyEval);
    t[op.import] = cold(vm_eval_module.dynamicImport);

    // --- iterators ---
    t[op.for_of_start] = h_for_of_start;
    t[op.for_await_of_start] = h_for_of_start;
    t[op.for_in_start] = cold(iterator_ops.forInStartVm);
    t[op.iterator_next] = cold(iterator_ops.iteratorNextVm);
    t[op.iterator_check_object] = cold(iterator_ops.iteratorCheckObjectVm);
    t[op.iterator_get_value_done] = cold(iterator_ops.iteratorGetValueDoneVm);
    t[op.iterator_call] = cold(iterator_ops.iteratorCallVm);
    t[op.for_of_next] = s.op_for_of_next;
    t[op.for_await_of_next] = cold(iterator_ops.forAwaitOfNextVm);
    t[op.for_in_next] = cold(iterator_ops.forInNextVm);
    t[op.iterator_close] = cold(iterator_ops.iteratorCloseVm);

    // --- specials (passed in from the main file) ---
    t[op.@"return"] = s.op_return;
    t[op.return_undef] = s.op_return_undef;
    t[op.return_async] = s.op_return;
    t[op.call] = s.op_call;
    t[op.call0] = s.op_call0;
    t[op.call1] = s.op_call1;
    t[op.call2] = s.op_call2;
    t[op.call3] = s.op_call3;
    t[op.call_method] = s.op_call_method;
    t[op.call_method_apply_fwd] = s.op_call_method_apply_fwd;
    t[op.tail_call] = s.op_tail_call;
    t[op.tail_call_method] = s.op_tail_call_method;
    t[op.eval] = s.op_eval;
    t[op.drop] = s.op_drop;
    t[op.throw] = s.op_throw;
    t[op.throw_error] = s.op_throw_error;
    t[op.initial_yield] = s.h_initial_yield;
    t[op.yield] = s.h_yield;
    t[op.yield_star] = s.h_yield_star;
    t[op.async_yield_star] = s.h_yield_star;
    t[op.await] = s.h_await;

    // --- HOT fast-path overrides: register-resident handlers (dispatch.op_*); the
    //     cold handlers assigned above remain their guard-miss fallback. Gated on
    //     `fast`: the all-cold table is what fast handlers fall back THROUGH, an
    //     indirect tail call LLVM cannot inline, so they stay frameless leaves. ---
    t[op.get_loc0_field] = dispatch.op_get_loc0_field_cold;
    t[op.get_loc2_field] = dispatch.op_get_loc2_field_cold;
    t[op.get_loc2_field2] = dispatch.op_get_loc2_field2_cold;
    t[op.get_field_field2] = dispatch.op_get_field_field2_cold;
    t[op.get_var_field] = dispatch.op_get_var_field_cold;
    t[op.get_field2_call_method] = dispatch.op_get_field2_call_method_cold;
    t[op.cmp_if_false8] = dispatch.op_cmp_if_false8_cold;
    t[op.eq_if_false8] = dispatch.op_eq_if_false8_cold;
    t[op.put_loc8_get_loc8] = dispatch.op_put_loc8_get_loc8_cold;
    t[op.push_this_put_loc0] = dispatch.op_push_this_put_loc0_cold;
    t[op.push_0_or] = dispatch.op_push_0_or_cold;
    t[op.sar_get_array_el] = dispatch.op_sar_get_array_el_cold;
    t[op.push_2_sar] = dispatch.op_push_2_sar_cold;
    t[op.get_loc8_push_2] = dispatch.op_get_loc8_push_2_cold;
    t[op.push_0_shr] = dispatch.op_push_0_shr_cold;
    t[op.get_loc8_push_1] = dispatch.op_get_loc8_push_1_cold;
    t[op.get_var_ref0_get_loc8] = dispatch.op_get_var_ref0_get_loc8_cold;
    t[op.push_i8_add] = dispatch.op_push_i8_add_cold;
    t[op.get_loc8_push_i8] = dispatch.op_get_loc8_push_i8_cold;
    if (!fast) return .{ .table = t, .keep = keep };
    t[op.undefined] = dispatch.op_undefined_fast;
    t[op.null] = dispatch.op_null_fast;
    t[op.push_false] = dispatch.op_push_false_fast;
    t[op.push_true] = dispatch.op_push_true_fast;
    t[op.push_i32] = dispatch.op_push_i32;
    t[op.push_i16] = dispatch.op_push_i16;
    t[op.push_i8] = dispatch.op_push_i8;
    t[op.push_const] = dispatch.op_push_const;
    t[op.push_const8] = dispatch.op_push_const8;
    inline for ([_]u8{ op.push_minus1, op.push_0, op.push_1, op.push_2, op.push_3, op.push_4, op.push_5, op.push_6, op.push_7 }) |o| t[o] = dispatch.op_push_small;
    // Per-variant local handlers (qjs-style distinct labels, no runtime decode).
    inline for ([_]struct { o: u8, h: Handler }{
        .{ .o = op.get_loc0, .h = dispatch.opLoc(.get, .c0) },
        .{ .o = op.get_loc1, .h = dispatch.opLoc(.get, .c1) },
        .{ .o = op.get_loc2, .h = dispatch.opLoc(.get, .c2) },
        .{ .o = op.get_loc3, .h = dispatch.opLoc(.get, .c3) },
        .{ .o = op.get_loc8, .h = dispatch.opLoc(.get, .byte) },
        .{ .o = op.get_loc, .h = dispatch.opLoc(.get, .half) },
        .{ .o = op.put_loc0, .h = dispatch.opLoc(.put, .c0) },
        .{ .o = op.put_loc1, .h = dispatch.opLoc(.put, .c1) },
        .{ .o = op.put_loc2, .h = dispatch.opLoc(.put, .c2) },
        .{ .o = op.put_loc3, .h = dispatch.opLoc(.put, .c3) },
        .{ .o = op.put_loc8, .h = dispatch.opLoc(.put, .byte) },
        .{ .o = op.put_loc, .h = dispatch.opLoc(.put, .half) },
        .{ .o = op.set_loc0, .h = dispatch.opLoc(.set, .c0) },
        .{ .o = op.set_loc1, .h = dispatch.opLoc(.set, .c1) },
        .{ .o = op.set_loc2, .h = dispatch.opLoc(.set, .c2) },
        .{ .o = op.set_loc3, .h = dispatch.opLoc(.set, .c3) },
        .{ .o = op.set_loc8, .h = dispatch.opLoc(.set, .byte) },
        .{ .o = op.set_loc, .h = dispatch.opLoc(.set, .half) },
    }) |e| t[e.o] = e.h;
    // TDZ-checked locals: qjs emits OP_*_loc_check for every lexical var, so these
    // are the per-iteration ops of `for (let i…)` loops. get_loc_checkthis stays cold.
    inline for ([_]struct { o: u8, h: Handler }{
        .{ .o = op.get_loc_check, .h = dispatch.opLocCheck(.get) },
        .{ .o = op.put_loc_check, .h = dispatch.opLocCheck(.put) },
        .{ .o = op.set_loc_check, .h = dispatch.opLocCheck(.set) },
    }) |e| t[e.o] = e.h;
    t[op.set_loc_uninitialized] = dispatch.op_set_loc_uninitialized;
    t[op.put_loc_check_init] = dispatch.op_put_loc_check_init;
    // qjs OP_fclosure/OP_fclosure8 stay in JS_CallInternal; the resident twins keep
    // the allocating/rooting path but continue with register pc/sp.
    t[op.fclosure] = dispatch.opFclosure;
    t[op.fclosure8] = dispatch.opFclosure;
    t[op.get_arg] = dispatch.op_get_arg;
    t[op.get_arg0] = dispatch.op_get_arg0_fast;
    t[op.get_arg1] = dispatch.op_get_arg1_fast;
    t[op.get_arg2] = dispatch.op_get_arg2_fast;
    t[op.get_arg3] = dispatch.op_get_arg3_fast;
    inline for ([_]struct { o: u8, h: Handler }{
        .{ .o = op.put_arg, .h = dispatch.opArgStore(.put) },
        .{ .o = op.set_arg, .h = dispatch.opArgStore(.set) },
    }) |e| t[e.o] = e.h;
    inline for ([_]u8{ op.put_arg0, op.put_arg1, op.put_arg2, op.put_arg3 }) |o| t[o] = dispatch.opArgStore(.put);
    inline for ([_]u8{ op.set_arg0, op.set_arg1, op.set_arg2, op.set_arg3 }) |o| t[o] = dispatch.opArgStore(.set);
    t[op.push_atom_value] = dispatch.op_push_atom_value;
    t[op.special_object] = dispatch.op_special_object; // THIS_FUNC direct dup; other subtypes stay cold
    t[op.push_this] = dispatch.op_push_this; // objects and (in strict code) any non-uninitialized value push directly; sloppy nullish->global too. Only sloppy ToObject boxing and uninitialized stay cold
    // Per-op binary handlers (qjs has a distinct CASE per op); op.pow keeps the
    // cold h_binary — qjs OP_pow has no fast leg either.
    inline for ([_]struct { o: u8, h: Handler }{
        .{ .o = op.add, .h = dispatch.opBinary(.add) },
        .{ .o = op.sub, .h = dispatch.opBinary(.sub) },
        .{ .o = op.mul, .h = dispatch.opBinary(.mul) },
        .{ .o = op.div, .h = dispatch.opBinary(.div) },
        .{ .o = op.mod, .h = dispatch.opBinary(.mod) },
        .{ .o = op.shl, .h = dispatch.opBinary(.shl) },
        .{ .o = op.sar, .h = dispatch.opBinary(.sar) },
        .{ .o = op.shr, .h = dispatch.opBinary(.shr) },
        .{ .o = op.@"and", .h = dispatch.opBinary(.band) },
        .{ .o = op.@"or", .h = dispatch.opBinary(.bor) },
        .{ .o = op.xor, .h = dispatch.opBinary(.bxor) },
    }) |e| t[e.o] = e.h;
    // Per-op compare handlers (qjs expands one CASE per opcode): no runtime predicate select.
    inline for ([_]u8{ op.lt, op.lte, op.gt, op.gte, op.eq, op.neq, op.strict_eq, op.strict_neq }) |o| t[o] = dispatch.opCompare(o);
    // qjs OP_neg keeps int/bool/null/float in its CASE; only ToNumeric operands go slow.
    t[op.neg] = dispatch.op_neg;
    inline for ([_]u8{ op.inc, op.dec }) |o| t[o] = dispatch.op_inc_dec;
    // qjs OP_post_inc/OP_post_dec int fast leg: every `let` loop update emits
    // post_inc+put_loc_check+drop, so this is the per-iteration update op.
    inline for ([_]u8{ op.post_inc, op.post_dec }) |o| t[o] = dispatch.op_post_inc_dec;
    t[op.dup] = dispatch.op_dup;
    // Pure stack transforms hot enough to skip the publishing shell; QuickJS keeps
    // each as a register-resident CASE with direct slot moves too.
    t[op.insert2] = dispatch.op_insert2;
    t[op.insert3] = dispatch.op_insert3;
    t[op.perm3] = dispatch.op_perm3;
    t[op.swap] = dispatch.op_swap;
    // Trailing expression-statement drop. qjs OP_drop is a register-resident free+pop;
    // the plain-value fast leg inlines here, a `catch_offset` marker falls to the cold shell.
    t[op.drop] = dispatch.op_drop_fast; // catch-marker (finally/catch epilogue) → cold s.op_drop
    t[op.goto8] = dispatch.op_goto8;
    // Wide unconditional jumps: same tick + target + cont shape as goto8.
    t[op.goto16] = dispatch.op_goto16;
    t[op.goto] = dispatch.op_goto;
    t[op.if_false8] = dispatch.op_if_false8;
    t[op.cmp_if_false8] = dispatch.op_cmp_if_false8;
    t[op.eq_if_false8] = dispatch.op_eq_if_false8;
    t[op.if_true8] = dispatch.op_if_true8;
    // Long-form conditional branch (qjs OP_if_false): same fast legs as the short
    // form with a 4-byte label; other tags and the cadence-hit poll fall cold.
    t[op.if_false] = dispatch.op_if_false;
    // qjs OP_lnot answers int/bool/null/undefined inline with the OP_if_* tag test and
    // takes JS_ToBoolFree's object leg inline; every other tag stays on cold logicalNot.
    t[op.lnot] = dispatch.op_lnot;
    t[op.is_null] = dispatch.op_is_null;
    t[op.inc_loc] = dispatch.op_update_loc;
    t[op.put_loc8_get_loc8] = dispatch.op_put_loc8_get_loc8;
    t[op.push_this_put_loc0] = dispatch.op_push_this_put_loc0;
    t[op.dec_loc] = dispatch.op_update_loc;
    t[op.get_field] = dispatch.op_get_field; // inline-cache fast path; IC miss → cold h_field
    t[op.get_loc0_field] = dispatch.op_get_loc0_field;
    t[op.get_loc2_field] = dispatch.op_get_loc2_field;
    t[op.get_loc2_field2] = dispatch.op_get_loc2_field2;
    t[op.get_field_field2] = dispatch.op_get_field_field2;
    t[op.get_var_field] = dispatch.op_get_var_field;
    t[op.get_field2_call_method] = dispatch.op_get_field2_call_method;
    t[op.ext0] = dispatch.op_using;
    t[op.get_field2] = dispatch.op_get_field2; // primitive-string method resolution; else → cold h_field
    t[op.put_field] = dispatch.op_put_field; // inline-cache put; IC miss → cold h_field
    t[op.get_array_el] = dispatch.op_get_array_el; // dense fast path; miss → cold h_get_array_element
    t[op.push_0_or] = dispatch.op_push_0_or;
    t[op.sar_get_array_el] = dispatch.op_sar_get_array_el;
    t[op.push_2_sar] = dispatch.op_push_2_sar;
    t[op.get_loc8_push_2] = dispatch.op_get_loc8_push_2;
    t[op.push_0_shr] = dispatch.op_push_0_shr;
    t[op.get_loc8_push_1] = dispatch.op_get_loc8_push_1;
    t[op.get_var_ref0_get_loc8] = dispatch.op_get_var_ref0_get_loc8;
    t[op.push_i8_add] = dispatch.op_push_i8_add;
    t[op.get_loc8_push_i8] = dispatch.op_get_loc8_push_i8;
    t[op.get_array_el2] = dispatch.op_get_array_el2; // keep-receiver twin; miss → cold h_get_array_element
    t[op.put_array_el] = dispatch.op_put_array_el; // dense write fast path; miss → cold h_put_array_element
    t[op.get_length] = dispatch.op_get_length; // inline data read; accessor/Proxy/typed payload → resident action tail
    // Object/array-literal ops (qjs register-resident single-`bl` CASEs): fast handler
    // on the plain-data-add / OOM-free path; every exotic case falls to the cold h_* shell.
    t[op.object] = dispatch.op_object; // bare {} create; OOM → cold h_object
    t[op.object_slots2] = dispatch.op_object_slots2;
    t[op.define_field] = dispatch.op_define_field; // plain data add; array/private/proxy/setter → cold h_field
    t[op.array_from] = dispatch.op_array_from; // dense array build; OOM → cold h_array_from
    t[op.add_loc] = dispatch.op_add_loc;
    t[op.get_var] = dispatch.op_get_var;
    t[op.get_var_undef] = dispatch.op_get_var;
    t[op.put_var] = dispatch.op_put_var; // resident cell write-through; every other arm → cold h_put_var
    t[op.instanceof] = dispatch.op_instanceof;
    inline for ([_]struct { o: u8, h: Handler }{
        .{ .o = op.get_var_ref0, .h = dispatch.opGetVarRef(.c0) },
        .{ .o = op.get_var_ref1, .h = dispatch.opGetVarRef(.c1) },
        .{ .o = op.get_var_ref2, .h = dispatch.opGetVarRef(.c2) },
        .{ .o = op.get_var_ref3, .h = dispatch.opGetVarRef(.c3) },
        .{ .o = op.get_var_ref, .h = dispatch.opGetVarRef(.half) },
        .{ .o = op.get_var_ref_check, .h = dispatch.opGetVarRef(.half) },
        .{ .o = op.put_var_ref0, .h = dispatch.opPutVarRef },
        .{ .o = op.put_var_ref1, .h = dispatch.opPutVarRef },
        .{ .o = op.put_var_ref2, .h = dispatch.opPutVarRef },
        .{ .o = op.put_var_ref3, .h = dispatch.opPutVarRef },
        .{ .o = op.put_var_ref, .h = dispatch.opPutVarRef },
        // qjs OP_put_var_ref_check: TDZ probe + set_value. TDZ-throw / synthetic-bounds /
        // generator-stop forms fall back to cold h_varref via cold_table[pc[0]].
        .{ .o = op.put_var_ref_check, .h = dispatch.op_put_var_ref_check },
        .{ .o = op.set_var_ref0, .h = dispatch.opSetVarRef },
        .{ .o = op.set_var_ref1, .h = dispatch.opSetVarRef },
        .{ .o = op.set_var_ref2, .h = dispatch.opSetVarRef },
        .{ .o = op.set_var_ref3, .h = dispatch.opSetVarRef },
        .{ .o = op.set_var_ref, .h = dispatch.opSetVarRef },
    }) |e| t[e.o] = e.h;

    // Prove the table against the physical opcode ledger: a claimed id left at
    // `op_invalid` would otherwise fail only at run time.
    for (0..256) |raw| {
        const id: u8 = @intCast(raw);
        const claimed = bytecode.opcode.physical.stateOf(id) == .claimed;
        // `invalid` (id 0) is a claimed row whose handler is the trap itself.
        if (claimed and id != op.invalid and t[id] == s.op_invalid)
            @compileError(std.fmt.comptimePrint("claimed opcode {d} has no dispatch handler", .{id}));
        if (!claimed and t[id] != s.op_invalid)
            @compileError(std.fmt.comptimePrint("unclaimed opcode {d} has a dispatch handler", .{id}));
    }
    return .{ .table = t, .keep = keep };
}
