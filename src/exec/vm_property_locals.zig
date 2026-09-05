//! Local/arg/var-ref slot opcode handlers (get/put/set_loc, get/put_arg, var_ref forms, close_loc).

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");

const call_runtime = @import("call_runtime.zig");
const exception_ops = @import("exception_ops.zig");
const slot_ops = @import("slot_ops.zig");
const readInt = call_runtime.readInt;

// Helpers that remain in vm_property.zig (shared with the leftover handlers).
const vm_property = @import("vm_property.zig");
const Step = vm_property.Step;
const varRefReadableBorrowed = vm_property.varRefReadableBorrowed;

const op = bytecode.opcode.op;
pub noinline fn loc(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    opc: u8,
) !void {
    switch (opc) {
        op.get_loc => {
            const idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
            try slot_ops.execGetLoc(ctx, frame, stack, idx, 2, opc);
        },
        op.put_loc => try slot_ops.execPutLoc(frame, stack, readInt(u16, function.byteCode()[frame.pc..][0..2]), 2, opc),
        op.set_loc => try slot_ops.execSetLoc(frame, stack, readInt(u16, function.byteCode()[frame.pc..][0..2]), 2, opc),

        op.get_loc8 => {
            const idx = function.byteCode()[frame.pc];
            try slot_ops.execGetLoc(ctx, frame, stack, idx, 1, opc);
        },
        op.put_loc8 => try slot_ops.execPutLoc(frame, stack, function.byteCode()[frame.pc], 1, opc),
        op.set_loc8 => try slot_ops.execSetLoc(frame, stack, function.byteCode()[frame.pc], 1, opc),

        op.get_loc0 => {
            try slot_ops.execGetLoc(ctx, frame, stack, 0, 0, opc);
        },
        op.get_loc1 => {
            try slot_ops.execGetLoc(ctx, frame, stack, 1, 0, opc);
        },
        op.get_loc2 => {
            try slot_ops.execGetLoc(ctx, frame, stack, 2, 0, opc);
        },
        op.get_loc3 => {
            try slot_ops.execGetLoc(ctx, frame, stack, 3, 0, opc);
        },
        op.put_loc0 => try slot_ops.execPutLoc(frame, stack, 0, 0, opc),
        op.put_loc1 => try slot_ops.execPutLoc(frame, stack, 1, 0, opc),
        op.put_loc2 => try slot_ops.execPutLoc(frame, stack, 2, 0, opc),
        op.put_loc3 => try slot_ops.execPutLoc(frame, stack, 3, 0, opc),
        op.set_loc0 => try slot_ops.execSetLoc(frame, stack, 0, 0, opc),
        op.set_loc1 => try slot_ops.execSetLoc(frame, stack, 1, 0, opc),
        op.set_loc2 => try slot_ops.execSetLoc(frame, stack, 2, 0, opc),
        op.set_loc3 => try slot_ops.execSetLoc(frame, stack, 3, 0, opc),
        else => unreachable,
    }
}

pub noinline fn arg(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    opc: u8,
) !void {
    switch (opc) {
        op.get_arg => try slot_ops.execGetArg(ctx, frame, stack, readInt(u16, function.byteCode()[frame.pc..][0..2]), 2, opc),
        op.put_arg => try slot_ops.execPutArg(frame, stack, readInt(u16, function.byteCode()[frame.pc..][0..2]), 2, opc),
        op.set_arg => try slot_ops.execSetArg(frame, stack, readInt(u16, function.byteCode()[frame.pc..][0..2]), 2, opc),
        op.get_arg0 => try slot_ops.execGetArg(ctx, frame, stack, 0, 0, opc),
        op.get_arg1 => try slot_ops.execGetArg(ctx, frame, stack, 1, 0, opc),
        op.get_arg2 => try slot_ops.execGetArg(ctx, frame, stack, 2, 0, opc),
        op.get_arg3 => try slot_ops.execGetArg(ctx, frame, stack, 3, 0, opc),
        op.put_arg0 => try slot_ops.execPutArg(frame, stack, 0, 0, opc),
        op.put_arg1 => try slot_ops.execPutArg(frame, stack, 1, 0, opc),
        op.put_arg2 => try slot_ops.execPutArg(frame, stack, 2, 0, opc),
        op.put_arg3 => try slot_ops.execPutArg(frame, stack, 3, 0, opc),
        op.set_arg0 => try slot_ops.execSetArg(frame, stack, 0, 0, opc),
        op.set_arg1 => try slot_ops.execSetArg(frame, stack, 1, 0, opc),
        op.set_arg2 => try slot_ops.execSetArg(frame, stack, 2, 0, opc),
        op.set_arg3 => try slot_ops.execSetArg(frame, stack, 3, 0, opc),
        else => unreachable,
    }
}

pub noinline fn checkedLocVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    function: *const bytecode.FunctionBytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    opc: u8,
    catch_target: *?usize,
) !Step {
    const idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
    frame.pc += 2;
    if (idx >= frame.locals.len) return error.InvalidBytecode;

    switch (opc) {
        op.set_loc_uninitialized => {
            // A lexical reset starts a new binding instance. Detach any cell
            // from the previous instance before publishing the TDZ sentinel.
            try frame.closeLocalBinding(ctx.runtime, idx);
            frame.locals[idx] = core.JSValue.uninitialized();
        },
        op.get_loc_check => {
            if (frame.locals[idx].isUninitialized()) {
                const is_derived_this = function.isDerivedClassConstructor() and
                    idx < function.varDefs().len and
                    function.varDefs()[idx].var_name == core.atom.ids.this_;
                const err = if (is_derived_this) blk: {
                    _ = exception_ops.throwReferenceErrorMessage(ctx, global, "this is not initialized") catch |err| break :blk err;
                    unreachable;
                } else exception_ops.throwTdzReferenceError(ctx);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            }
            try stack.push(frame.locals[idx]);
        },
        op.get_loc_checkthis => {
            if (frame.locals[idx].isUninitialized()) {
                // This opcode is the compiler-generated implicit return after
                // derived-constructor return unwinding. QuickJS constructs its
                // ReferenceError in caller_ctx, so leave it as a distinct
                // sentinel for the caller frame instead of materializing here.
                return error.DerivedThisUninitialized;
            }
            try stack.push(frame.locals[idx]);
        },
        op.put_loc_check => {
            if (frame.locals[idx].isUninitialized()) {
                const err = exception_ops.throwTdzReferenceError(ctx);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            }
            const value = try stack.pop();
            if (idx < function.varDefs().len and function.varDefs()[idx].isConst()) {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
                return error.TypeError;
            }
            frame.locals[idx] = value;
        },
        op.set_loc_check => {
            if (frame.locals[idx].isUninitialized()) {
                const err = exception_ops.throwTdzReferenceError(ctx);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            }
            const value = stack.peek() orelse return error.StackUnderflow;
            frame.locals[idx] = value;
        },
        op.put_loc_check_init => {
            // Only derived `this` has once-only init semantics (double-super ->
            // "'this' can be initialized only once"). put_loc_check_init is also
            // emitted for other lexical inits (e.g. AnnexB block-function var
            // copies) that legitimately overwrite an already-set slot, so the
            // once-only error must stay gated on the derived-this binding.
            const is_derived_this = function.isDerivedClassConstructor() and
                idx < function.varDefs().len and
                function.varDefs()[idx].var_name == core.atom.ids.this_;
            if (is_derived_this and !frame.locals[idx].isUninitialized()) {
                _ = exception_ops.throwReferenceErrorMessage(ctx, global, "'this' can be initialized only once") catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
                unreachable;
            }
            const value = try stack.pop();
            frame.locals[idx] = value;
        },
        else => unreachable,
    }
    return .done;
}

pub fn varRef(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    function: *const bytecode.FunctionBytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    opc: u8,
    catch_target: *?usize,
) !Step {
    switch (opc) {
        op.get_var_ref, op.get_var_ref_check => {
            if (frame.pc + 2 > function.byteCode().len) return error.TypeError;
            const idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
            if (try tryFastDirectVarRefGet(function, frame, stack, idx, 2)) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, output, function, frame, stack, idx, 2, catch_target, global)) return .continue_loop;
        },
        op.put_var_ref, op.put_var_ref_check, op.put_var_ref_check_init => {
            if (frame.pc + 2 > function.byteCode().len) return error.TypeError;
            const idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
            try slot_ops.execPutVarRef(ctx, function, global, frame, stack, idx, 2, opc);
        },
        op.set_var_ref => {
            if (frame.pc + 2 > function.byteCode().len) return error.TypeError;
            try slot_ops.execSetVarRef(ctx, frame, stack, readInt(u16, function.byteCode()[frame.pc..][0..2]), 2, opc);
        },

        op.get_var_ref0 => {
            if (try tryFastDirectVarRefGet(function, frame, stack, 0, 0)) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, output, function, frame, stack, 0, 0, catch_target, global)) return .continue_loop;
        },
        op.get_var_ref1 => {
            if (try tryFastDirectVarRefGet(function, frame, stack, 1, 0)) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, output, function, frame, stack, 1, 0, catch_target, global)) return .continue_loop;
        },
        op.get_var_ref2 => {
            if (try tryFastDirectVarRefGet(function, frame, stack, 2, 0)) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, output, function, frame, stack, 2, 0, catch_target, global)) return .continue_loop;
        },
        op.get_var_ref3 => {
            if (try tryFastDirectVarRefGet(function, frame, stack, 3, 0)) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, output, function, frame, stack, 3, 0, catch_target, global)) return .continue_loop;
        },
        op.put_var_ref0 => try slot_ops.execPutVarRef(ctx, function, global, frame, stack, 0, 0, opc),
        op.put_var_ref1 => try slot_ops.execPutVarRef(ctx, function, global, frame, stack, 1, 0, opc),
        op.put_var_ref2 => try slot_ops.execPutVarRef(ctx, function, global, frame, stack, 2, 0, opc),
        op.put_var_ref3 => try slot_ops.execPutVarRef(ctx, function, global, frame, stack, 3, 0, opc),
        op.set_var_ref0 => try slot_ops.execSetVarRef(ctx, frame, stack, 0, 0, opc),
        op.set_var_ref1 => try slot_ops.execSetVarRef(ctx, frame, stack, 1, 0, opc),
        op.set_var_ref2 => try slot_ops.execSetVarRef(ctx, frame, stack, 2, 0, opc),
        op.set_var_ref3 => try slot_ops.execSetVarRef(ctx, frame, stack, 3, 0, opc),
        else => unreachable,
    }
    return .done;
}

pub noinline fn varRefVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    function: *const bytecode.FunctionBytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    opc: u8,
    catch_target: *?usize,
) !Step {
    return varRef(ctx, output, function, global, frame, stack, opc, catch_target) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
}

fn tryFastDirectVarRefGet(function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, stack: *stack_mod.Stack, idx: u16, consume: u8) !bool {
    if (call_runtime.closureVarIsNonLexicalGlobalSentinel(function, idx)) return false;
    const value = varRefReadableBorrowed(frame, idx) orelse return false;
    frame.pc += consume;
    try stack.push(value);
    return true;
}

pub noinline fn closeLoc(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    const idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
    frame.pc += 2;
    try frame.closeLocalBinding(ctx.runtime, idx);
}
