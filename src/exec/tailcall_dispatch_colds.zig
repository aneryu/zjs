//! Cold opcode handlers for the tail-call dispatcher. One handler per opcode,
//! transcribed from the former switch-dispatcher slow-path helper calls.
//! `buildTable` assembles the 256-entry dispatch table (cold handlers here +
//! the special handlers passed in from the main file). v1: hot ops route
//! through their cold handler too (frame story holds either way; the
//! frame-zero fast paths are a perf follow-up).
//!
//! This file has no linksection literal of its own: every handler here lands
//! in the hot .text.zjs.op_handlers island implicitly via dispatch.coldStd's
//! linksection wrapper — a grep for linksection will not find this file.

const std = @import("std");
const core = @import("../core/root.zig");
const bytecode = @import("../bytecode.zig");
const dispatch = @import("tailcall_dispatch.zig");
const HostError = @import("exceptions.zig").HostError;

const Vm = dispatch.Vm;
const Handler = dispatch.Handler;
const coldStd = dispatch.coldStd;
const op = bytecode.opcode.op;
const JSValue = core.JSValue;

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
const slot_ops = @import("slot_ops.zig");
const vm_property_locals = @import("vm_property_locals.zig");
const vm_property_ref = @import("vm_property_ref.zig");
const vm_property_globals = @import("vm_property_globals.zig");
const vm_property_field = @import("vm_property_field.zig");
const vm_property_private = @import("vm_property_private.zig");
const using_ops = @import("using_ops.zig");

// ---- Shared handlers (op groups sharing helper+args) ----
pub const h_varref = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = try vm_property_locals.varRefVm(vm.ctx, vm.output, vm.function, vm.global, vm.frame, vm.stack, pc[0], vm.catch_target);
    }
}.b);
pub const h_checkedloc = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = try vm_property_locals.checkedLocVm(vm.ctx, vm.output, vm.function, vm.global, vm.frame, vm.stack, pc[0], vm.catch_target);
    }
}.b);
pub const h_loc = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        try vm_property_locals.loc(vm.ctx, vm.function, vm.frame, vm.stack, pc[0]);
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
        _ = try vm_arith.binaryVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, pc[0], vm.output, vm.global);
    }
}.b);
pub const h_compare = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = try vm_arith.compareVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, pc[0], vm.output, vm.global);
    }
}.b);
pub const h_unary = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = try vm_arith.unaryVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, pc[0], vm.output, vm.global);
    }
}.b);
pub const h_field = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = try vm_property_field.field(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, pc[0]);
    }
}.b);
pub const h_get_array_element = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = try vm_property_field.getArrayElement(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, pc[0]);
    }
}.b);
pub const h_put_array_element = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = pc;
        _ = try vm_property_field.putArrayElementAfterFastMiss(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
    }
}.b);
pub const h_get_var = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = try vm_property_globals.getVar(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, pc[0]);
    }
}.b);
/// Miss continuation for `dispatch.op_put_var`, and the whole of OP_put_var in the
/// all-cold table. The cell direct-write arm no longer runs here: it moved into
/// the resident handler, which reaches this shell only after that arm declined,
/// so re-testing it would be a guaranteed second miss.
pub const h_put_var = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = pc;
        _ = try vm_property_globals.putVar(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, dispatch.strictUnresolvedGetVar(vm), dispatch.evalGlobalVarBindings(vm), dispatch.isEvalCode(vm));
    }
}.b);
pub const h_dyn_env_probe = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = pc;
        _ = try vm_property_ref.dynEnvProbe(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
    }
}.b);
pub const h_make_slot_ref = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        try vm_property_ref.makeSlotRef(vm.ctx, vm.stack, vm.function, vm.frame, pc[0]);
    }
}.b);
pub const h_define_class = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = try object_ops.defineClass(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, pc[0] == op.define_class_computed);
    }
}.b);
pub const h_for_of_start = coldStd(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!void {
        _ = try iterator_ops.forOfStartVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, pc[0] == op.for_await_of_start);
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
    /// Geometry keep: reclaimed-slot coldStd leaves. Live so LLVM cannot DCE them.
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
    t[op.push_i32] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.pushInt32Operand(vm.stack, vm.function, vm.frame);
        }
    }.b);
    t[op.push_bigint_i32] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.pushBigIntI32Operand(vm.stack, vm.function, vm.frame);
        }
    }.b);
    t[op.push_i16] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.pushI16Operand(vm.stack, vm.function, vm.frame);
        }
    }.b);
    t[op.push_i8] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.pushI8Operand(vm.stack, vm.function, vm.frame);
        }
    }.b);
    t[op.push_const] = coldStd(struct {
        fn b(vm: *Vm, pc: [*]const u8) HostError!void {
            try vm_value.pushConst(vm.ctx, vm.stack, vm.function, vm.frame, pc[0]);
        }
    }.b);
    t[op.push_const8] = coldStd(struct {
        fn b(vm: *Vm, pc: [*]const u8) HostError!void {
            try vm_value.pushConst8(vm.ctx, vm.stack, vm.function, vm.frame, pc[0]);
        }
    }.b);
    t[op.private_symbol] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.pushPrivateSymbol(vm.ctx, vm.stack, vm.function, vm.frame);
        }
    }.b);
    t[op.regexp] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_regexp.pushLiteral(vm.ctx, vm.stack, vm.global);
        }
    }.b);
    t[op.fclosure] = coldStd(struct {
        fn b(vm: *Vm, pc: [*]const u8) HostError!void {
            _ = try vm_call.closure(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, pc[0]);
        }
    }.b);
    t[op.fclosure8] = t[op.fclosure];
    t[op.undefined] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.pushUndefined(vm.stack);
        }
    }.b);
    t[op.null] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.pushNull(vm.stack);
        }
    }.b);
    t[op.push_false] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.pushBoolean(vm.stack, false);
        }
    }.b);
    t[op.push_true] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.pushBoolean(vm.stack, true);
        }
    }.b);
    inline for ([_]struct { o: u8, v: i32 }{ .{ .o = op.push_minus1, .v = -1 }, .{ .o = op.push_0, .v = 0 }, .{ .o = op.push_1, .v = 1 }, .{ .o = op.push_2, .v = 2 }, .{ .o = op.push_3, .v = 3 }, .{ .o = op.push_4, .v = 4 }, .{ .o = op.push_5, .v = 5 }, .{ .o = op.push_6, .v = 6 }, .{ .o = op.push_7, .v = 7 } }) |e| {
        t[e.o] = h(struct {
            fn b(vm: *Vm) HostError!void {
                try vm_value.pushSmallIntMaybeFuse(vm.stack, vm.function, vm.frame, e.v);
            }
        }.b);
    }
    t[op.push_atom_value] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.pushAtomValue(vm.ctx, vm.stack, vm.function, vm.frame);
        }
    }.b);
    t[op.push_empty_string] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.pushEmptyString(vm.ctx, vm.stack);
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
            switch (try vm_value.nipCatch(vm.ctx.runtime, vm.stack)) {
                .value => {},
                .catch_target => |target| vm.catch_target.* = target,
            }
        }
    }.b);

    // --- arith / compare / unary ---
    inline for ([_]u8{ op.add, op.sub, op.mul, op.div, op.mod, op.pow, op.shl, op.sar, op.shr, op.@"and", op.@"or", op.xor }) |o| t[o] = h_binary;
    t[op.div] = dispatch.op_div_cold;
    t[op.mod] = dispatch.op_mod_cold;
    // Register-resident cold bitwise/shift (qjs js_binary_logic_slow 15214 /
    // js_shr_slow 15735 operate in place on sp[-2]); falls back to the publishing
    // h_binary path for BigInt/string/object/symbol operands and at the generator stop.
    inline for ([_]u8{ op.shl, op.sar, op.shr, op.@"and", op.@"or", op.xor }) |o| t[o] = dispatch.opLogicCold(o);
    // Register-resident cold compare (no publish round-trip) — falls back to the
    // publishing h_compare path internally at the generator parameter/body stop. Reached via
    // the same indirect cold_table dispatch the compare fast handlers always used
    // (direct routing would perturb the int32 fast-path codegen).
    inline for ([_]u8{ op.lt, op.lte, op.gt, op.gte, op.eq, op.neq, op.strict_eq, op.strict_neq }) |o| t[o] = dispatch.opCompareCold(o);
    inline for ([_]u8{ op.neg, op.to_number, op.inc, op.dec }) |o| t[o] = h_unary;
    t[op.in] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_property_field.inOrInstanceof(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, undefined);
        }
    }.b);
    t[op.in] = handlerComparePlaceholder(op.in);
    t[op.instanceof] = handlerComparePlaceholder(op.instanceof);
    t[op.private_in] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try object_ops.privateInVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.not] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_arith.bitNotVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, vm.output, vm.global);
        }
    }.b);
    t[op.lnot] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.logicalNot(vm.ctx.runtime, vm.stack);
        }
    }.b);
    t[op.post_inc] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_arith.postUpdateVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, undefined, vm.output, vm.global);
        }
    }.b);
    t[op.post_inc] = handlerPost(op.post_inc);
    t[op.post_dec] = handlerPost(op.post_dec);
    // Register-resident cold inc_loc/dec_loc (float counters), publishing fallback at
    // the generator parameter/body stop — installed indirectly to avoid perturbing the int32
    // fast-path codegen (see op_update_loc_cold).
    t[op.inc_loc] = dispatch.op_update_loc_cold;
    t[op.dec_loc] = dispatch.op_update_loc_cold;
    // OP_add_loc's cold handler collapses coldStd+addLocalVm into one hop (see
    // dispatch.op_add_loc_cold) to cut the int+float backend stall; op_add_loc also
    // tail-calls it directly on the hot miss.
    t[op.add_loc] = dispatch.op_add_loc_cold;

    // --- control ---
    // qjs polls interrupts on every OP_goto/goto16/goto8 (quickjs.c:18822-18836)
    // — the loop back edge; a pure loop otherwise never reaches a poll point.
    t[op.goto] = h(struct {
        fn b(vm: *Vm) HostError!void {
            vm_control.jump32(vm.function, vm.frame);
            try exception_ops.pollInterrupt(vm.ctx, vm.global);
        }
    }.b);
    t[op.goto16] = h(struct {
        fn b(vm: *Vm) HostError!void {
            vm_control.jump16(vm.function, vm.frame);
            try exception_ops.pollInterrupt(vm.ctx, vm.global);
        }
    }.b);
    t[op.goto8] = h(struct {
        fn b(vm: *Vm) HostError!void {
            vm_control.jump8(vm.function, vm.frame);
            try exception_ops.pollInterrupt(vm.ctx, vm.global);
        }
    }.b);
    t[op.if_false] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_control.branch32(vm.ctx, vm.stack, vm.function, vm.frame, false);
            try exception_ops.pollInterrupt(vm.ctx, vm.global);
        }
    }.b);
    t[op.if_true] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_control.branch32(vm.ctx, vm.stack, vm.function, vm.frame, true);
            try exception_ops.pollInterrupt(vm.ctx, vm.global);
        }
    }.b);
    t[op.if_false8] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_control.branch8(vm.ctx, vm.stack, vm.function, vm.frame, false);
            try exception_ops.pollInterrupt(vm.ctx, vm.global);
        }
    }.b);
    t[op.if_true8] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_control.branch8(vm.ctx, vm.stack, vm.function, vm.frame, true);
            try exception_ops.pollInterrupt(vm.ctx, vm.global);
        }
    }.b);
    t[op.gosub] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_control.gosub(vm.function, vm.frame, vm.stack);
        }
    }.b);
    t[op.ret] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_control.ret(vm.ctx, vm.function, vm.frame, vm.stack);
        }
    }.b);

    // --- globals / refs / with ---
    t[op.get_var] = h_get_var;
    t[op.get_var_undef] = h_get_var;
    t[op.put_var] = h_put_var;
    inline for ([_]u8{ op.make_loc_ref, op.make_arg_ref, op.make_var_ref_ref }) |o| t[o] = h_make_slot_ref;
    t[op.make_var_ref] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_property_ref.makeVarRefVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
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
    t[op.dyn_env_probe] = h_dyn_env_probe;

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
    inline for ([_]u8{ op.get_array_el, op.get_array_el2, op.get_array_el3 }) |o| t[o] = h_get_array_element;
    t[op.put_array_el] = h_put_array_element;
    t[op.get_super] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try object_ops.getSuper(vm.ctx, vm.stack, vm.frame);
        }
    }.b);
    t[op.get_super_value] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try object_ops.getSuperValue(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.get_length] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_literal.getLength(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);

    // --- literals / class ---
    t[op.object] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_literal.object(vm.ctx, vm.stack, vm.global);
        }
    }.b);
    t[op.object_slots2] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_literal.objectReserved2(vm.ctx, vm.stack, vm.global);
        }
    }.b);
    t[op.array_from] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_literal.arrayFrom(vm.ctx, vm.stack, vm.function, vm.frame, vm.global);
        }
    }.b);
    t[op.define_field] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_literal.defineField(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.set_home_object] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try object_ops.setHomeObject(vm.ctx, vm.stack);
        }
    }.b);
    t[op.define_class] = h_define_class;
    t[op.define_class_computed] = h_define_class;
    t[op.define_array_el] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_literal.defineArrayEl(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.define_method] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try object_ops.defineMethod(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.define_method_computed] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try object_ops.defineMethodComputed(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.append] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_literal.appendSpreadValuesVm(vm.ctx, vm.output, vm.global, vm.stack, undefined, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.append] = handlerAppend(op.append);
    t[op.copy_data_properties] = h(struct {
        fn b(vm: *Vm) HostError!void {
            const mask = vm.function.byteCode()[vm.frame.pc];
            vm.frame.pc += 1;
            _ = try vm_literal.copyDataProperties(vm.ctx, vm.output, vm.global, vm.stack, mask, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.put_var_init] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_property_globals.globalDefinition(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, dispatch.evalGlobalVarBindings(vm), undefined);
        }
    }.b);
    t[op.put_var_init] = handlerPutVarInit(op.put_var_init);
    t[op.special_object] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_literal.specialObject(vm.ctx, vm.stack, vm.function, vm.frame, vm.global);
        }
    }.b);
    t[op.using] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try using_ops.execVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.rest] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_literal.rest(vm.ctx, vm.stack, vm.function, vm.frame);
        }
    }.b);

    // --- typeof / is_* ---
    t[op.typeof] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.typeOf(vm.ctx, vm.stack);
        }
    }.b);
    // 240/242/243 were these three type tests. Fusion v3 reclaimed the
    // slots; instantiate the same coldStd leaves here (returned in
    // `keep` so LLVM cannot DCE them) so later island offsets match
    // 6a61951e. Both tables instantiate — ICF folds the pair, same as v2.1.
    keep[0] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.typeOfIsUndefined(vm.ctx.runtime, vm.stack);
        }
    }.b);
    keep[1] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.typeOfIsFunction(vm.ctx.runtime, vm.stack);
        }
    }.b);
    t[op.get_var_field] = dispatch.op_get_var_field_cold;
    t[op.get_loc2_field2] = dispatch.op_get_loc2_field2_cold;
    t[op.is_undefined_or_null] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.isUndefinedOrNull(vm.ctx.runtime, vm.stack);
        }
    }.b);
    keep[2] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.isUndefined(vm.ctx.runtime, vm.stack);
        }
    }.b);
    t[op.get_field_field2] = dispatch.op_get_field_field2_cold;
    t[op.is_null] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.isNull(vm.ctx.runtime, vm.stack);
        }
    }.b);

    // --- stack manipulation ---
    t[op.dup] = coldStd(struct {
        fn b(vm: *Vm, pc: [*]const u8) HostError!void {
            try vm_value.dup(vm.ctx, vm.stack, pc[0]);
        }
    }.b);
    t[op.swap] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.swap(vm.ctx, vm.stack);
        }
    }.b);
    t[op.nip] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.nip(vm.ctx, vm.stack);
        }
    }.b);
    keep[11] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.dup1(vm.ctx, vm.stack);
        }
    }.b);
    keep[6] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.dup2(vm.ctx, vm.stack);
        }
    }.b);
    keep[10] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.dup3(vm.ctx, vm.stack);
        }
    }.b);
    t[op.insert2] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.insert2(vm.ctx, vm.stack);
        }
    }.b);
    t[op.insert3] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.insert3(vm.ctx, vm.stack);
        }
    }.b);
    keep[3] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.insert4(vm.ctx, vm.stack);
        }
    }.b);
    t[op.rot3l] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.rot3l(vm.ctx, vm.stack);
        }
    }.b);
    keep[8] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.rot3r(vm.ctx, vm.stack);
        }
    }.b);
    keep[9] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.rot4l(vm.ctx, vm.stack);
        }
    }.b);
    keep[4] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.rot5l(vm.ctx, vm.stack);
        }
    }.b);
    t[op.perm3] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.perm3(vm.ctx, vm.stack);
        }
    }.b);
    t[op.perm4] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.perm4(vm.ctx, vm.stack);
        }
    }.b);
    keep[5] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.perm5(vm.ctx, vm.stack);
        }
    }.b);
    keep[7] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_value.swap2(vm.ctx, vm.stack);
        }
    }.b);

    // --- ctor / brand / misc ---
    t[op.@"catch"] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_control.catchTarget(vm.function, vm.frame, vm.stack, vm.catch_target);
        }
    }.b);
    t[op.check_ctor] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_call.checkCtorVm(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global);
        }
    }.b);
    t[op.init_ctor] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_call.initCtorVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.check_brand] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try object_ops.checkBrandVm(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global);
        }
    }.b);
    t[op.add_brand] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try object_ops.addBrandVm(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global);
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
            vm_control.nop();
        }
    }.b);
    t[op.push_this] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_value.pushThisVm(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global);
        }
    }.b);
    t[op.delete_var] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_property_ref.deleteVar(vm.ctx, vm.global, vm.stack, vm.function, vm.frame);
        }
    }.b);
    t[op.delete] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_property_ref.deletePropertyVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.apply] = s.op_apply;
    t[op.call_constructor] = s.op_call_constructor;
    t[op.apply_eval] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try vm_eval_module.applyEval(vm.ctx, vm.stack, vm.function, vm.frame, vm.catch_target, vm.output, vm.global, dispatch.directEvalVarsReachGlobal(vm));
        }
    }.b);
    t[op.import] = h(struct {
        fn b(vm: *Vm) HostError!void {
            try vm_eval_module.dynamicImport(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame);
        }
    }.b);

    // --- iterators ---
    t[op.for_of_start] = h_for_of_start;
    t[op.for_await_of_start] = h_for_of_start;
    t[op.for_in_start] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try iterator_ops.forInStartVm(vm.ctx, vm.output, vm.global, vm.stack, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.iterator_next] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try iterator_ops.iteratorNextVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.iterator_check_object] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try iterator_ops.iteratorCheckObjectVm(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global);
        }
    }.b);
    t[op.iterator_get_value_done] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try iterator_ops.iteratorGetValueDoneVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.iterator_call] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try iterator_ops.iteratorCallVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.for_of_next] = s.op_for_of_next;
    t[op.for_await_of_next] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try iterator_ops.forAwaitOfNextVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.for_in_next] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try iterator_ops.forInNextVm(vm.ctx, vm.output, vm.global, vm.stack, vm.frame, vm.catch_target);
        }
    }.b);
    t[op.iterator_close] = h(struct {
        fn b(vm: *Vm) HostError!void {
            _ = try iterator_ops.iteratorCloseVm(vm.ctx, vm.output, vm.global, vm.stack, vm.frame, vm.catch_target);
        }
    }.b);

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

    // --- HOT fast-path overrides: register-resident inlined work (dispatch.op_*), the
    //     cold handlers assigned above remain as their guard-miss fallback target.
    //     Gated on `fast`: buildTable(.., false) yields the all-cold table the fast
    //     handlers fall back THROUGH (indirect `cold_table[pc[0]]` tail call → the
    //     compiler can't devirtualize+inline it, so the fast handler stays a
    //     frameless leaf instead of carrying the cold 128B frame on its hot path). ---
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
    t[op.put_loc0_get_loc0] = dispatch.op_put_loc0_get_loc0_cold;
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
    // TDZ-checked locals: the per-iteration hot loc ops in `for (let i…)` loops
    // (quickjs.c emits OP_get_loc_check/OP_put_loc_check for every lexical var,
    // 33072-33078). get_loc_checkthis stays on cold h_checkedloc; the plain-slot
    // set_loc_uninitialized / put_loc_check_init cases have dedicated fast handlers.
    inline for ([_]struct { o: u8, h: Handler }{
        .{ .o = op.get_loc_check, .h = dispatch.opLocCheck(.get) },
        .{ .o = op.put_loc_check, .h = dispatch.opLocCheck(.put) },
        .{ .o = op.set_loc_check, .h = dispatch.opLocCheck(.set) },
    }) |e| t[e.o] = e.h;
    t[op.set_loc_uninitialized] = dispatch.op_set_loc_uninitialized;
    t[op.put_loc_check_init] = dispatch.op_put_loc_check_init;
    // qjs OP_fclosure/OP_fclosure8 keep the operand decode and `*sp++ =
    // js_closure(...)` in JS_CallInternal (qjs:17914-17915,18165-18170).
    // The resident zjs twins preserve the allocating constructor/rooting path
    // while continuing with their register pc/sp; the all-cold table above
    // remains the stop-boundary implementation.
    t[op.fclosure] = dispatch.opFclosure(true);
    t[op.fclosure8] = dispatch.opFclosure(false);
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
    t[op.push_this] = dispatch.op_push_this; // object dup / sloppy nullish->global; ToObject boxing + strict non-object + uninitialized stay cold
    // Per-op binary handlers (qjs CASE(OP_add)/…/CASE(OP_xor) are distinct labels,
    // quickjs.c:19696-20227; op.pow keeps the cold h_binary — qjs OP_pow:19916 has
    // no fast leg and falls straight to js_binary_arith_slow).
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
    // Per-op compare handlers (qjs OP_CMP/OP_CMP_EQ/OP_CMP_STRICT_EQ expand one
    // independent CASE per opcode, quickjs.c:20268-20271/20340-20341/20397-20398 —
    // no runtime predicate select on the int fast path).
    inline for ([_]u8{ op.lt, op.lte, op.gt, op.gte, op.eq, op.neq, op.strict_eq, op.strict_neq }) |o| t[o] = dispatch.opCompare(o);
    // qjs OP_neg keeps int/bool/null/float in its CASE and calls
    // js_unary_arith_slow only for ToNumeric operands (quickjs.c:19940-19970).
    t[op.neg] = dispatch.op_neg;
    inline for ([_]u8{ op.inc, op.dec }) |o| t[o] = dispatch.op_inc_dec;
    // qjs OP_post_inc/OP_post_dec int fast leg (quickjs.c:20009-20045). Every
    // `let` loop update emits post_inc+put_loc_check+drop (checked lvalues are
    // outside the resolve_labels plain-loc fusions, matching qjs), so this is
    // the per-iteration update op of every lexical counter loop.
    inline for ([_]u8{ op.post_inc, op.post_dec }) |o| t[o] = dispatch.op_post_inc_dec;
    t[op.dup] = dispatch.op_dup;
    // Pure stack transforms that cross the dynamic-exposure threshold in the
    // frozen 12-workload census. QuickJS keeps each as a register-resident CASE
    // with direct slot moves (and one JS_DupValue for insert2/insert3), so these
    // do not need the publishing cold shell either.
    t[op.insert2] = dispatch.op_insert2;
    t[op.insert3] = dispatch.op_insert3;
    t[op.perm3] = dispatch.op_perm3;
    t[op.swap] = dispatch.op_swap;
    // Trailing expression-statement drop (the per-iter `dup; put_loc_check; DROP`
    // tail of every `o = {…}` / `s = …` / `a = […]` loop). qjs OP_drop:17968 is a
    // register-resident `JS_FreeValue(sp[-1]); sp--`; the plain-value / live-refcount
    // fast leg inlines here, a `catch_offset` marker on top falls to the cold shell.
    t[op.drop] = dispatch.op_drop_fast; // catch-marker (finally/catch epilogue) → cold s.op_drop
    t[op.goto8] = dispatch.op_goto8;
    // D-E4: wide unconditional jumps were left on coldStd after
    // `519317b8` took only goto8. Same tick + target + cont shape.
    t[op.goto16] = dispatch.op_goto16;
    t[op.goto] = dispatch.op_goto;
    t[op.if_false8] = dispatch.op_if_false8;
    t[op.cmp_if_false8] = dispatch.op_cmp_if_false8;
    t[op.eq_if_false8] = dispatch.op_eq_if_false8;
    t[op.if_true8] = dispatch.op_if_true8;
    // Long-form conditional branch (qjs CASE(OP_if_false):18859 — same immediate/
    // object fast legs as the short form, 4-byte label); float/string/HTMLDDA and
    // the cadence-hit poll fall to the cold branch32 shell assigned above.
    t[op.if_false] = dispatch.op_if_false;
    // qjs CASE(OP_lnot):19092 answers int/bool/null/undefined inline with the same
    // tag comparison OP_if_* uses, and the object arm takes JS_ToBoolFree's object
    // leg (11205-11211) inline like op_if_false8; every other tag stays on the cold
    // logicalNot assigned above (qjs reaches those via an out-of-line JS_ToBoolFree
    // bl too — pinned binary, JS_CallInternal+0x6abc).
    t[op.lnot] = dispatch.op_lnot;
    t[op.is_null] = dispatch.op_is_null;
    t[op.inc_loc] = dispatch.op_update_loc;
    t[op.put_loc8_get_loc8] = dispatch.op_put_loc8_get_loc8;
    t[op.push_this_put_loc0] = dispatch.op_push_this_put_loc0;
    t[op.put_loc0_get_loc0] = dispatch.op_put_loc0_get_loc0;
    t[op.dec_loc] = dispatch.op_update_loc;
    t[op.get_field] = dispatch.op_get_field; // inline-cache fast path; IC miss → cold h_field
    t[op.get_loc0_field] = dispatch.op_get_loc0_field;
    t[op.get_loc2_field] = dispatch.op_get_loc2_field;
    t[op.get_loc2_field2] = dispatch.op_get_loc2_field2;
    t[op.get_field_field2] = dispatch.op_get_field_field2;
    t[op.get_var_field] = dispatch.op_get_var_field;
    t[op.get_field2_call_method] = dispatch.op_get_field2_call_method;
    t[op.using] = dispatch.op_using;
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
    // Object/array-literal ops (qjs CASE(OP_object)/(OP_define_field)/(OP_array_from)
    // are register-resident single-`bl` inlines, quickjs.c:17961/19269/18239). Without
    // these overrides they routed through the 224-byte coldStd publish shell EVERY
    // iteration — the per-iter hottest ops of the object/array-literal benchmarks (see
    // dispatch-audit). Fast handler on the plain-data-add / OOM-free path; every exotic
    // case falls to the cold h_* shell assigned above.
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
        .{ .o = op.put_var_ref0, .h = dispatch.opPutVarRef(.c0) },
        .{ .o = op.put_var_ref1, .h = dispatch.opPutVarRef(.c1) },
        .{ .o = op.put_var_ref2, .h = dispatch.opPutVarRef(.c2) },
        .{ .o = op.put_var_ref3, .h = dispatch.opPutVarRef(.c3) },
        .{ .o = op.put_var_ref, .h = dispatch.opPutVarRef(.half) },
        // qjs OP_put_var_ref_check (quickjs.c:18670-18682): TDZ probe + set_value.
        // The TDZ-throw / synthetic-bounds / generator-stop forms fall back to
        // the cold h_varref shell (execPutVarRef) via cold_table[pc[0]].
        .{ .o = op.put_var_ref_check, .h = dispatch.op_put_var_ref_check },
        .{ .o = op.set_var_ref0, .h = dispatch.opSetVarRef(.c0) },
        .{ .o = op.set_var_ref1, .h = dispatch.opSetVarRef(.c1) },
        .{ .o = op.set_var_ref2, .h = dispatch.opSetVarRef(.c2) },
        .{ .o = op.set_var_ref3, .h = dispatch.opSetVarRef(.c3) },
        .{ .o = op.set_var_ref, .h = dispatch.opSetVarRef(.half) },
    }) |e| t[e.o] = e.h;
    return .{ .table = t, .keep = keep };
}

// Operand-carrying singletons that need `pc[0]` — small helpers returning a Handler.
fn handlerComparePlaceholder(comptime o: u8) Handler {
    return coldStd(struct {
        fn b(vm: *Vm, pc: [*]const u8) HostError!void {
            _ = pc;
            _ = try vm_property_field.inOrInstanceof(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, o);
        }
    }.b);
}
fn handlerPost(comptime o: u8) Handler {
    return coldStd(struct {
        fn b(vm: *Vm, pc: [*]const u8) HostError!void {
            _ = pc;
            _ = try vm_arith.postUpdateVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, o, vm.output, vm.global);
        }
    }.b);
}
fn handlerAppend(comptime o: u8) Handler {
    return coldStd(struct {
        fn b(vm: *Vm, pc: [*]const u8) HostError!void {
            _ = pc;
            _ = try vm_literal.appendSpreadValuesVm(vm.ctx, vm.output, vm.global, vm.stack, o, vm.frame, vm.catch_target);
        }
    }.b);
}
fn handlerPutVarInit(comptime o: u8) Handler {
    return coldStd(struct {
        fn b(vm: *Vm, pc: [*]const u8) HostError!void {
            _ = pc;
            _ = try vm_property_globals.globalDefinition(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, dispatch.evalGlobalVarBindings(vm), o);
        }
    }.b);
}
