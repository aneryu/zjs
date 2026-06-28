//! Cold opcode handlers for the tail-call dispatcher (TAILCALL-DISPATCH-ONESHOT-
//! BLUEPRINT.md §5-6). One handler per opcode, transcribed verbatim from
//! dispatchLoop's slow-path helper calls. `buildTable` assembles the 256-entry
//! dispatch table (cold handlers here + the special handlers passed in from the
//! main file). v1: hot ops route through their cold handler too (frame story holds
//! either way; the frame-zero fast paths are a perf follow-up).

const std = @import("std");
const core = @import("../core/root.zig");
const bytecode = @import("../bytecode/root.zig");
const td = @import("tailcall_dispatch.zig");
const HostError = @import("exceptions.zig").HostError;

const Vm = td.Vm;
const Handler = td.Handler;
const coldStd = td.coldStd;
const op = bytecode.opcode.op;
const JSValue = core.JSValue;

const value_vm = @import("vm_value.zig");
const arith_vm = @import("vm_arith.zig");
const control_vm = @import("vm_control.zig");
const call_vm = @import("vm_call.zig");
const class_vm = @import("object_ops.zig");
const literal_vm = @import("vm_literal.zig");
const iter_vm = @import("iterator_ops.zig");
const regexp_vm = @import("vm_regexp.zig");
const eval_module_vm = @import("vm_eval_module.zig");
const slot_ops = @import("slot_ops.zig");
const vm_property_locals = @import("vm_property_locals.zig");
const vm_property_ref = @import("vm_property_ref.zig");
const vm_property_globals = @import("vm_property_globals.zig");
const vm_property_field = @import("vm_property_field.zig");
const vm_property_private = @import("vm_property_private.zig");

// ---- Shared handlers (op groups sharing helper+args) ----
pub const h_varref = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = try vm_property_locals.varRefVm(vm.ctx, vm.function, vm.global, vm.frame, vm.stack, pc[0], vm.catch_target, (if (vm.machine.depth == 0) vm.l0.eval_global_var_bindings else false), (if (vm.machine.depth == 0) vm.l0.is_eval_code else false), (if (vm.machine.depth == 0) vm.l0.eval_local_names else &.{}), vm.frame.evalVarRefNames(), (if (vm.machine.depth == 0) vm.l0.eval_with_object else core.JSValue.undefinedValue()));
    }
}.b);
pub const h_checkedloc = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = try vm_property_locals.checkedLocVm(vm.ctx, vm.function, vm.global, vm.frame, vm.stack, pc[0], vm.catch_target, (if (vm.machine.depth == 0) vm.l0.eval_local_names else &.{}), vm.frame.evalVarRefNames(), (if (vm.machine.depth == 0) vm.l0.eval_with_object else core.JSValue.undefinedValue()));
    }
}.b);
pub const h_loc = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        try vm_property_locals.loc(vm.ctx, vm.function, vm.global, vm.frame, vm.stack, pc[0], (if (vm.machine.depth == 0) vm.l0.eval_local_names else &.{}), vm.frame.evalVarRefNames(), (if (vm.machine.depth == 0) vm.l0.eval_with_object else core.JSValue.undefinedValue()));
    }
}.b);
pub const h_arg = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        try vm_property_locals.arg(vm.ctx, vm.function, vm.frame, vm.stack, pc[0]);
    }
}.b);
pub const h_get_arg_short = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        try slot_ops.execGetArg(vm.ctx, vm.frame, vm.stack, @as(u16, @intCast(pc[0] - op.get_arg0)), 0, pc[0]);
    }
}.b);
pub const h_binary = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = try arith_vm.binaryVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, pc[0], vm.output, vm.global);
    }
}.b);
pub const h_compare = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = try arith_vm.compareVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, pc[0], vm.output, vm.global);
    }
}.b);
pub const h_unary = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = try arith_vm.unaryVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, pc[0], vm.output, vm.global);
    }
}.b);
pub const h_field = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = try vm_property_field.field(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, pc[0]);
    }
}.b);
pub const h_array_element = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = try vm_property_field.arrayElement(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, pc[0]);
    }
}.b);
pub const h_get_var = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = try vm_property_globals.getVar(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, pc[0], (if (vm.machine.depth == 0) vm.l0.eval_local_names else &.{}), (if (vm.machine.depth == 0) vm.l0.eval_local_slots else &.{}), vm.frame.evalVarRefNames(), vm.frame.evalVarRefs(), (if (vm.machine.depth == 0) vm.l0.eval_with_object else core.JSValue.undefinedValue()));
    }
}.b);
pub const h_put_var = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = pc;
        _ = try vm_property_globals.putVar(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, (if (vm.machine.depth == 0) vm.l0.strict_unresolved_get_var else (vm.function.flags.is_strict or vm.function.flags.runtime_strict)), (if (vm.machine.depth == 0) vm.l0.eval_global_var_bindings else false), (if (vm.machine.depth == 0) vm.l0.is_eval_code else false), (if (vm.machine.depth == 0) vm.l0.eval_local_names else &.{}), (if (vm.machine.depth == 0) vm.l0.eval_local_slots else &.{}), vm.frame.evalVarRefNames(), vm.frame.evalVarRefs(), (if (vm.machine.depth == 0) vm.l0.eval_with_object else core.JSValue.undefinedValue()));
    }
}.b);
pub const h_with_get_or_delete = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = try vm_property_ref.withGetOrDelete(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, pc[0]);
    }
}.b);
pub const h_make_slot_ref = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        try vm_property_ref.makeSlotRef(vm.ctx, vm.stack, vm.function, vm.frame, pc[0]);
    }
}.b);
pub const h_define_class = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = try class_vm.defineClass(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, (if (vm.machine.depth == 0) vm.l0.eval_local_names else &.{}), (if (vm.machine.depth == 0) vm.l0.eval_local_slots else &.{}), vm.frame.evalVarRefNames(), vm.frame.evalVarRefs(), pc[0] == op.define_class_computed);
    }
}.b);
pub const h_for_of_start = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = try iter_vm.forOfStartVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, pc[0] == op.for_await_of_start);
    }
}.b);

/// Wrap a void/`_ = try` helper body as a cold handler. `pc`-free bodies welcome.
fn h(comptime body: fn (vm: *Vm) HostError!void) Handler {
    return coldStd(struct {
        fn b(vm: *Vm, pc: [*]const u8) HostError!void {
            _ = pc;
            try body(vm);
        }
    }.b);
}

pub const SpecialHandlers = struct {
    op_return: Handler,
    op_return_undef: Handler,
    op_call: Handler,
    op_call_method: Handler,
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

pub fn buildTable(s: SpecialHandlers, comptime fast: bool) [256]Handler {
    var t: [256]Handler = [_]Handler{s.op_invalid} ** 256;

    // --- pushes ---
    t[op.push_i32] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.pushInt32Operand(vm.stack, vm.function, vm.frame);
        }
    }.b);
    t[op.push_bigint_i32] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.pushBigIntI32Operand(vm.stack, vm.function, vm.frame);
        }
    }.b);
    t[op.push_i16] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.pushI16OperandVm(vm.ctx, vm.stack, vm.function, vm.frame, .{ .global = vm.global, .eval_local_names = (if (vm.machine.depth == 0) vm.l0.eval_local_names else &.{}), .eval_var_ref_names = vm.frame.evalVarRefNames(), .eval_with_object = (if (vm.machine.depth == 0) vm.l0.eval_with_object else core.JSValue.undefinedValue()) });
        }
    }.b);
    t[op.push_i8] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.pushI8Operand(vm.stack, vm.function, vm.frame);
        }
    }.b);
    t[op.push_const] = coldStd(struct {
        fn b(vm: *Vm, pc: [*]const u8) HostError!void {
            try value_vm.pushConst(vm.ctx, vm.stack, vm.function, vm.frame, pc[0]);
        }
    }.b);
    t[op.push_const8] = coldStd(struct {
        fn b(vm: *Vm, pc: [*]const u8) HostError!void {
            try value_vm.pushConst8(vm.ctx, vm.stack, vm.function, vm.frame, pc[0]);
        }
    }.b);
    t[op.private_symbol] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.pushPrivateSymbol(vm.ctx, vm.stack, vm.function, vm.frame);
        }
    }.b);
    t[op.regexp] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try regexp_vm.pushLiteral(vm.ctx, vm.stack, class_vm.constructorPrototypeFromGlobal(vm.ctx.runtime, vm.global, "RegExp"));
        }
    }.b);
    t[op.fclosure] = coldStd(struct {
        fn b(vm: *Vm, pc: [*]const u8) HostError!void {
            _ = try call_vm.closure(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, pc[0], (if (vm.machine.depth == 0) vm.l0.eval_local_names else &.{}), (if (vm.machine.depth == 0) vm.l0.eval_local_slots else &.{}), vm.frame.evalVarRefNames(), vm.frame.evalVarRefs());
        }
    }.b);
    t[op.fclosure8] = t[op.fclosure];
    t[op.undefined] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.pushUndefined(vm.stack);
        }
    }.b);
    t[op.null] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.pushNull(vm.stack);
        }
    }.b);
    t[op.push_false] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.pushBoolean(vm.stack, false);
        }
    }.b);
    t[op.push_true] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.pushBoolean(vm.stack, true);
        }
    }.b);
    inline for ([_]struct { o: u8, v: i32 }{ .{ .o = op.push_minus1, .v = -1 }, .{ .o = op.push_0, .v = 0 }, .{ .o = op.push_1, .v = 1 }, .{ .o = op.push_2, .v = 2 }, .{ .o = op.push_3, .v = 3 }, .{ .o = op.push_4, .v = 4 }, .{ .o = op.push_5, .v = 5 }, .{ .o = op.push_6, .v = 6 }, .{ .o = op.push_7, .v = 7 } }) |e| {
        t[e.o] = h(struct {
            fn b(vm: *Vm) HostError!void {
                try value_vm.pushSmallIntMaybeFuse(vm.stack, vm.function, vm.frame, e.v);
            }
        }.b);
    }
    t[op.push_atom_value] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.pushAtomValue(vm.ctx, vm.stack, vm.function, vm.frame);
        }
    }.b);
    t[op.push_empty_string] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.pushEmptyString(vm.ctx, vm.stack);
        }
    }.b);

    // --- locals / args / var_refs / checked ---
    inline for ([_]u8{ op.get_loc, op.put_loc, op.set_loc, op.get_loc8, op.put_loc8, op.set_loc8, op.get_loc0, op.get_loc1, op.get_loc2, op.get_loc3, op.put_loc0, op.put_loc1, op.put_loc2, op.put_loc3, op.set_loc0, op.set_loc1, op.set_loc2, op.set_loc3 }) |o| t[o] = h_loc;
    inline for ([_]u8{ op.get_arg0, op.get_arg1, op.get_arg2, op.get_arg3 }) |o| t[o] = h_get_arg_short;
    inline for ([_]u8{ op.get_arg, op.put_arg, op.set_arg, op.put_arg0, op.put_arg1, op.put_arg2, op.put_arg3, op.set_arg0, op.set_arg1, op.set_arg2, op.set_arg3 }) |o| t[o] = h_arg;
    inline for ([_]u8{ op.get_var_ref, op.get_var_ref_check, op.get_var_ref0, op.get_var_ref1, op.get_var_ref2, op.get_var_ref3, op.put_var_ref, op.put_var_ref_check, op.put_var_ref0, op.put_var_ref1, op.put_var_ref2, op.put_var_ref3, op.put_var_ref_check_init, op.set_var_ref, op.set_var_ref0, op.set_var_ref1, op.set_var_ref2, op.set_var_ref3 }) |o| t[o] = h_varref;
    inline for ([_]u8{ op.get_loc_check, op.get_loc_checkthis, op.put_loc_check, op.set_loc_check, op.put_loc_check_init, op.set_loc_uninitialized }) |o| t[o] = h_checkedloc;

    // --- names ---
    t[op.to_propkey] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_property_field.toPropKeyVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.set_name] = coldStd(struct {
        fn b(vm: *Vm, pc: [*]const u8) HostError!void {
            try vm_property_field.setName(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, pc[0]);
        }
    }.b);
    t[op.set_name_computed] = t[op.set_name];
    t[op.nip_catch] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.nipCatch(vm.ctx.runtime, vm.stack);
        }
    }.b);

    // --- arith / compare / unary ---
    inline for ([_]u8{ op.add, op.sub, op.mul, op.div, op.mod, op.pow, op.shl, op.sar, op.shr, op.@"and", op.@"or", op.xor }) |o| t[o] = h_binary;
    // Register-resident cold compare (no publish round-trip) — falls back to the
    // publishing h_compare path internally at a generator stop boundary. Reached via
    // the same indirect cold_table dispatch op_compare always used (direct routing
    // would perturb the int32 fast-path codegen).
    inline for ([_]u8{ op.lt, op.lte, op.gt, op.gte, op.eq, op.neq, op.strict_eq, op.strict_neq }) |o| t[o] = td.op_compare_cold;
    inline for ([_]u8{ op.neg, op.plus, op.inc, op.dec }) |o| t[o] = h_unary;
    t[op.in] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_property_field.inOrInstanceof(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, undefined);
        }
    }.b);
    t[op.in] = h_compare_placeholder(op.in);
    t[op.instanceof] = h_compare_placeholder(op.instanceof);
    t[op.private_in] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try class_vm.privateInVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.not] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try arith_vm.bitNotVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, vm.output, vm.global);
        }
    }.b);
    t[op.lnot] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.logicalNot(vm.ctx.runtime, vm.stack);
        }
    }.b);
    t[op.post_inc] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try arith_vm.postUpdateVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, undefined, vm.output, vm.global);
        }
    }.b);
    t[op.post_inc] = h_post(op.post_inc);
    t[op.post_dec] = h_post(op.post_dec);
    // Register-resident cold inc_loc/dec_loc (float counters), publishing fallback at
    // a generator stop boundary — installed indirectly to avoid perturbing the int32
    // fast-path codegen (see op_update_loc_cold).
    t[op.inc_loc] = td.op_update_loc_cold;
    t[op.dec_loc] = td.op_update_loc_cold;
    // OP_add_loc's cold handler collapses coldStd+addLocalVm into one hop (see
    // td.op_add_loc_cold) to cut the int+float backend stall; op_add_loc also
    // tail-calls it directly on the hot miss.
    t[op.add_loc] = td.op_add_loc_cold;

    // --- control ---
    t[op.goto] = h(struct {
        fn b(vm: *Vm) HostError!void {
            control_vm.jump32(vm.function, vm.frame);
        }
    }.b);
    t[op.goto16] = h(struct {
        fn b(vm: *Vm) HostError!void {
            control_vm.jump16(vm.function, vm.frame);
        }
    }.b);
    t[op.goto8] = h(struct {
        fn b(vm: *Vm) HostError!void {
            control_vm.jump8(vm.function, vm.frame);
        }
    }.b);
    t[op.if_false] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try control_vm.branch32(vm.ctx, vm.stack, vm.function, vm.frame, false);
        }
    }.b);
    t[op.if_true] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try control_vm.branch32(vm.ctx, vm.stack, vm.function, vm.frame, true);
        }
    }.b);
    t[op.if_false8] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try control_vm.branch8(vm.ctx, vm.stack, vm.function, vm.frame, false);
        }
    }.b);
    t[op.if_true8] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try control_vm.branch8(vm.ctx, vm.stack, vm.function, vm.frame, true);
        }
    }.b);
    t[op.gosub] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try control_vm.gosub(vm.function, vm.frame, vm.stack);
        }
    }.b);
    t[op.ret] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try control_vm.ret(vm.ctx, vm.function, vm.frame, vm.stack);
        }
    }.b);

    // --- globals / refs / with ---
    t[op.get_var] = h_get_var;
    t[op.get_var_undef] = h_get_var;
    t[op.put_var] = h_put_var;
    inline for ([_]u8{ op.make_loc_ref, op.make_arg_ref, op.make_var_ref_ref }) |o| t[o] = h_make_slot_ref;
    t[op.make_var_ref] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_property_ref.makeVarRefVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, (if (vm.machine.depth == 0) vm.l0.eval_local_names else &.{}), (if (vm.machine.depth == 0) vm.l0.eval_local_slots else &.{}), vm.frame.evalVarRefNames(), vm.frame.evalVarRefs());
        }
    }.b);
    t[op.get_ref_value] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_property_ref.getRefValueVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.put_ref_value] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_property_ref.putRefValueVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    inline for ([_]u8{ op.with_get_var, op.with_delete_var, op.with_make_ref, op.with_get_ref }) |o| t[o] = h_with_get_or_delete;
    t[op.with_put_var] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_property_ref.withPut(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.to_object] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try value_vm.toObjectVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, vm.global);
        }
    }.b);

    // --- fields / private / array_el / super ---
    inline for ([_]u8{ op.get_field, op.get_field2, op.put_field }) |o| t[o] = h_field;
    t[op.get_private_field] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_property_private.getPrivateFieldVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.put_private_field] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_property_private.putPrivateFieldVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.define_private_field] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_property_private.definePrivateFieldVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    inline for ([_]u8{ op.get_array_el, op.get_array_el2, op.get_array_el3, op.put_array_el }) |o| t[o] = h_array_element;
    t[op.get_super] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try class_vm.getSuper(vm.ctx, vm.stack, vm.frame);
        }
    }.b);
    t[op.get_super_value] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try class_vm.getSuperValue(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.put_super_value] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try class_vm.putSuperValue(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.get_length] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try literal_vm.getLength(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);

    // --- literals / class ---
    t[op.object] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try literal_vm.object(vm.ctx, vm.stack, vm.global);
        }
    }.b);
    t[op.array_from] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try literal_vm.arrayFrom(vm.ctx, vm.stack, vm.function, vm.frame, vm.global);
        }
    }.b);
    t[op.define_field] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try literal_vm.defineField(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.set_proto] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try literal_vm.setProto(vm.ctx, vm.stack);
        }
    }.b);
    t[op.set_home_object] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try class_vm.setHomeObject(vm.ctx, vm.stack);
        }
    }.b);
    t[op.define_class] = h_define_class;
    t[op.define_class_computed] = h_define_class;
    t[op.define_array_el] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try literal_vm.defineArrayEl(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.define_method] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try class_vm.defineMethod(vm.ctx, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.define_method_computed] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try class_vm.defineMethodComputed(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.append] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try literal_vm.appendSpreadValuesVm(vm.ctx, vm.output, vm.global, vm.stack, undefined, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.append] = h_append(op.append);
    t[op.copy_data_properties] = h(struct {
        fn b(vm: *Vm) HostError!void {
            const mask = vm.function.code[vm.frame.pc];
            vm.frame.pc += 1;
            _ = try literal_vm.copyDataProperties(vm.ctx, vm.output, vm.global, vm.stack, mask, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.put_var_init] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_property_globals.globalDefinition(vm.ctx, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, undefined);
        }
    }.b);
    t[op.put_var_init] = h_putvarinit(op.put_var_init);
    t[op.special_object] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try literal_vm.specialObject(vm.ctx, vm.stack, vm.function, vm.frame, vm.global, (if (vm.machine.depth == 0) vm.l0.eval_local_names else &.{}), (if (vm.machine.depth == 0) vm.l0.eval_local_slots else &.{}), vm.frame.evalVarRefNames(), vm.frame.evalVarRefs());
        }
    }.b);
    t[op.rest] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try literal_vm.rest(vm.ctx, vm.stack, vm.function, vm.frame);
        }
    }.b);

    // --- typeof / is_* ---
    t[op.typeof] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.typeOf(vm.ctx, vm.stack);
        }
    }.b);
    t[op.typeof_is_undefined] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.typeOfIsUndefined(vm.ctx.runtime, vm.stack);
        }
    }.b);
    t[op.typeof_is_function] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.typeOfIsFunction(vm.ctx.runtime, vm.stack);
        }
    }.b);
    t[op.is_undefined_or_null] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.isUndefinedOrNull(vm.ctx.runtime, vm.stack);
        }
    }.b);
    t[op.is_undefined] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.isUndefined(vm.ctx.runtime, vm.stack);
        }
    }.b);
    t[op.is_null] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.isNull(vm.ctx.runtime, vm.stack);
        }
    }.b);

    // --- stack manipulation ---
    t[op.dup] = coldStd(struct {
        fn b(vm: *Vm, pc: [*]const u8) HostError!void {
            try value_vm.dup(vm.ctx, vm.stack, pc[0]);
        }
    }.b);
    t[op.swap] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.swap(vm.ctx, vm.stack);
        }
    }.b);
    t[op.nip] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.nip(vm.ctx, vm.stack);
        }
    }.b);
    t[op.nip1] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.nip1(vm.ctx, vm.stack);
        }
    }.b);
    t[op.dup1] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.dup1(vm.ctx, vm.stack);
        }
    }.b);
    t[op.dup2] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.dup2(vm.ctx, vm.stack);
        }
    }.b);
    t[op.dup3] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.dup3(vm.ctx, vm.stack);
        }
    }.b);
    t[op.insert2] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.insert2(vm.ctx, vm.stack);
        }
    }.b);
    t[op.insert3] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.insert3(vm.ctx, vm.stack);
        }
    }.b);
    t[op.insert4] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.insert4(vm.ctx, vm.stack);
        }
    }.b);
    t[op.rot3l] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.rot3l(vm.ctx, vm.stack);
        }
    }.b);
    t[op.rot3r] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.rot3r(vm.ctx, vm.stack);
        }
    }.b);
    t[op.rot4l] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.rot4l(vm.ctx, vm.stack);
        }
    }.b);
    t[op.rot5l] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.rot5l(vm.ctx, vm.stack);
        }
    }.b);
    t[op.perm3] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.perm3(vm.ctx, vm.stack);
        }
    }.b);
    t[op.perm4] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.perm4(vm.ctx, vm.stack);
        }
    }.b);
    t[op.perm5] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.perm5(vm.ctx, vm.stack);
        }
    }.b);
    t[op.swap2] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try value_vm.swap2(vm.ctx, vm.stack);
        }
    }.b);

    // --- ctor / brand / misc ---
    t[op.@"catch"] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try control_vm.catchTarget(vm.function, vm.frame, vm.stack, vm.catch_target);
        }
    }.b);
    t[op.check_ctor] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try call_vm.checkCtorVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, vm.global);
        }
    }.b);
    t[op.check_ctor_return] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try call_vm.checkCtorReturnVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, vm.global);
        }
    }.b);
    t[op.init_ctor] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try call_vm.initCtorVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.check_brand] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try class_vm.checkBrandVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, vm.global);
        }
    }.b);
    t[op.add_brand] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try class_vm.addBrandVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, vm.global);
        }
    }.b);
    t[op.close_loc] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_property_locals.closeLoc(vm.ctx, vm.function, vm.frame);
        }
    }.b);
    t[op.nop] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = vm;
            control_vm.nop();
        }
    }.b);
    t[op.push_this] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try value_vm.pushThisVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, vm.global);
        }
    }.b);
    t[op.delete_var] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_property_ref.deleteVar(vm.ctx, vm.global, vm.stack, vm.function, vm.frame, (if (vm.machine.depth == 0) vm.l0.eval_local_names else &.{}), (if (vm.machine.depth == 0) vm.l0.eval_local_slots else &.{}), vm.frame.evalVarRefNames(), vm.frame.evalVarRefs());
        }
    }.b);
    t[op.delete] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_property_ref.deletePropertyVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.apply] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try call_vm.apply(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.call_constructor] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try call_vm.constructor(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.apply_eval] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try eval_module_vm.applyEval(vm.ctx, vm.stack, vm.function, vm.frame, vm.catch_target, vm.output, vm.global, 0x8000, 0x4000);
        }
    }.b);
    t[op.import] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try eval_module_vm.dynamicImport(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame);
        }
    }.b);

    // --- iterators ---
    t[op.for_of_start] = h_for_of_start;
    t[op.for_await_of_start] = h_for_of_start;
    t[op.for_in_start] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try iter_vm.forInStartVm(vm.ctx, vm.output, vm.global, vm.stack, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.iterator_next] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try iter_vm.iteratorNextVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.iterator_check_object] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try iter_vm.iteratorCheckObjectVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, vm.global);
        }
    }.b);
    t[op.iterator_get_value_done] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try iter_vm.iteratorGetValueDoneVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.iterator_call] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try iter_vm.iteratorCallVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.for_of_next] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try iter_vm.forOfNextVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.for_await_of_next] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try iter_vm.forAwaitOfNextVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.for_in_next] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try iter_vm.forInNext(vm.ctx, vm.output, vm.global, vm.stack);
        }
    }.b);
    t[op.iterator_close] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try iter_vm.iteratorCloseVm(vm.ctx, vm.output, vm.global, vm.stack, vm.frame, vm.catch_target);
        }
    }.b);

    // --- specials (passed in from the main file) ---
    t[op.@"return"] = s.op_return;
    t[op.return_undef] = s.op_return_undef;
    t[op.return_async] = s.op_return;
    t[op.call] = s.op_call;
    t[op.call0] = s.op_call;
    t[op.call1] = s.op_call;
    t[op.call2] = s.op_call;
    t[op.call3] = s.op_call;
    t[op.call_method] = s.op_call_method;
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

    // --- HOT fast-path overrides: register-resident inlined work (td.op_*), the
    //     cold handlers assigned above remain as their guard-miss fallback target.
    //     Gated on `fast`: buildTable(.., false) yields the all-cold table the fast
    //     handlers fall back THROUGH (indirect `cold_table[pc[0]]` tail call → the
    //     compiler can't devirtualize+inline it, so the fast handler stays a
    //     frameless leaf instead of carrying the cold 128B frame on its hot path). ---
    if (!fast) return t;
    t[op.push_i32] = td.op_push_i32;
    t[op.push_i16] = td.op_push_i16;
    t[op.push_i8] = td.op_push_i8;
    inline for ([_]u8{ op.push_minus1, op.push_0, op.push_1, op.push_2, op.push_3, op.push_4, op.push_5, op.push_6, op.push_7 }) |o| t[o] = td.op_push_small;
    // Per-variant local handlers (qjs-style distinct labels, no runtime decode).
    inline for ([_]struct { o: u8, h: Handler }{
        .{ .o = op.get_loc0, .h = td.opLoc(.get, .c0) },
        .{ .o = op.get_loc1, .h = td.opLoc(.get, .c1) },
        .{ .o = op.get_loc2, .h = td.opLoc(.get, .c2) },
        .{ .o = op.get_loc3, .h = td.opLoc(.get, .c3) },
        .{ .o = op.get_loc8, .h = td.opLoc(.get, .byte) },
        .{ .o = op.get_loc, .h = td.opLoc(.get, .half) },
        .{ .o = op.put_loc0, .h = td.opLoc(.put, .c0) },
        .{ .o = op.put_loc1, .h = td.opLoc(.put, .c1) },
        .{ .o = op.put_loc2, .h = td.opLoc(.put, .c2) },
        .{ .o = op.put_loc3, .h = td.opLoc(.put, .c3) },
        .{ .o = op.put_loc8, .h = td.opLoc(.put, .byte) },
        .{ .o = op.put_loc, .h = td.opLoc(.put, .half) },
        .{ .o = op.set_loc0, .h = td.opLoc(.set, .c0) },
        .{ .o = op.set_loc1, .h = td.opLoc(.set, .c1) },
        .{ .o = op.set_loc2, .h = td.opLoc(.set, .c2) },
        .{ .o = op.set_loc3, .h = td.opLoc(.set, .c3) },
        .{ .o = op.set_loc8, .h = td.opLoc(.set, .byte) },
        .{ .o = op.set_loc, .h = td.opLoc(.set, .half) },
    }) |e| t[e.o] = e.h;
    inline for ([_]u8{ op.get_arg0, op.get_arg1, op.get_arg2, op.get_arg3 }) |o| t[o] = td.op_get_arg_short;
    inline for ([_]u8{ op.add, op.sub, op.mul, op.div, op.mod, op.shl, op.sar, op.shr, op.@"and", op.@"or", op.xor }) |o| t[o] = td.op_binary;
    inline for ([_]u8{ op.lt, op.lte, op.gt, op.gte, op.eq, op.neq, op.strict_eq, op.strict_neq }) |o| t[o] = td.op_compare;
    inline for ([_]u8{ op.inc, op.dec }) |o| t[o] = td.op_inc_dec;
    t[op.dup] = td.op_dup;
    t[op.swap] = td.op_swap;
    t[op.goto8] = td.op_goto8;
    t[op.if_false8] = td.op_if_false8;
    t[op.if_true8] = td.op_if_true8;
    t[op.inc_loc] = td.op_update_loc;
    t[op.dec_loc] = td.op_update_loc;
    t[op.get_field] = td.op_get_field; // inline-cache fast path; IC miss → cold h_field
    t[op.get_field2] = td.op_get_field2; // primitive-string method resolution; else → cold h_field
    t[op.put_field] = td.op_put_field; // inline-cache put; IC miss → cold h_field
    t[op.get_array_el] = td.op_get_array_el; // dense fast path; miss → cold h_array_element
    t[op.put_array_el] = td.op_put_array_el; // dense write fast path; miss → cold h_array_element
    t[op.get_length] = td.op_get_length; // inline string-length read; non-string → cold getLength
    t[op.add_loc] = td.op_add_loc;
    t[op.get_var] = td.op_get_var;
    t[op.get_var_undef] = td.op_get_var;
    inline for ([_]struct { o: u8, h: Handler }{
        .{ .o = op.get_var_ref0, .h = td.opGetVarRef(.c0) },
        .{ .o = op.get_var_ref1, .h = td.opGetVarRef(.c1) },
        .{ .o = op.get_var_ref2, .h = td.opGetVarRef(.c2) },
        .{ .o = op.get_var_ref3, .h = td.opGetVarRef(.c3) },
        .{ .o = op.get_var_ref, .h = td.opGetVarRef(.half) },
        .{ .o = op.get_var_ref_check, .h = td.opGetVarRef(.half) },
    }) |e| t[e.o] = e.h;
    return t;
}

// Operand-carrying singletons that need `pc[0]` — small helpers returning a Handler.
fn h_compare_placeholder(comptime o: u8) Handler {
    return coldStd(struct {
        fn b(vm: *Vm, pc: [*]const u8) HostError!void {
            _ = pc;
            _ = try vm_property_field.inOrInstanceof(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, o);
        }
    }.b);
}
fn h_post(comptime o: u8) Handler {
    return coldStd(struct {
        fn b(vm: *Vm, pc: [*]const u8) HostError!void {
            _ = pc;
            _ = try arith_vm.postUpdateVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, o, vm.output, vm.global);
        }
    }.b);
}
fn h_updatelocal(comptime o: u8) Handler {
    return coldStd(struct {
        fn b(vm: *Vm, pc: [*]const u8) HostError!void {
            _ = pc;
            _ = try arith_vm.updateLocalVm(vm.ctx, vm.stack, vm.function, vm.global, vm.frame, vm.catch_target, o, vm.output);
        }
    }.b);
}
fn h_append(comptime o: u8) Handler {
    return coldStd(struct {
        fn b(vm: *Vm, pc: [*]const u8) HostError!void {
            _ = pc;
            _ = try literal_vm.appendSpreadValuesVm(vm.ctx, vm.output, vm.global, vm.stack, o, vm.frame, vm.catch_target);
        }
    }.b);
}
fn h_putvarinit(comptime o: u8) Handler {
    return coldStd(struct {
        fn b(vm: *Vm, pc: [*]const u8) HostError!void {
            _ = pc;
            _ = try vm_property_globals.globalDefinition(vm.ctx, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, o);
        }
    }.b);
}
