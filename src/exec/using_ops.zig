//! Bytecode handlers for explicit-resource-management (`using`) operations.
//!
//! These handlers own and pop VM operands, delegate resource lifetime to
//! `disposable_ops`, and route synchronous/async disposal failures through the
//! active catch target. Promise scheduling remains in `promise_ops`.

const std = @import("std");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");

const call_runtime = @import("call_runtime.zig");
const disposable_ops = @import("disposable_ops.zig");
const promise_ops = @import("promise_ops.zig");
const object_ops = @import("object_ops.zig");
const vm_call = @import("vm_call.zig");
const vm_literal = @import("vm_literal.zig");
const vm_value = @import("vm_value.zig");

pub const Step = enum {
    done,
    continue_loop,
};

pub const DisposalDisposition = enum {
    normal,
    throw,
};

fn popOwnedOperands(rt: *core.JSRuntime, stack: *stack_mod.Stack, count: usize) !void {
    var remaining = count;
    while (remaining != 0) : (remaining -= 1) {
        const value = try stack.pop();
        value.free(rt);
    }
}

fn routeRuntimeError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    err: anytype,
) !Step {
    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) {
        return .continue_loop;
    }
    return err;
}

pub noinline fn createStackVm(
    ctx: *core.JSContext,
    global: *core.Object,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    output: ?*std.Io.Writer,
) !Step {
    try stack.reserveAdditional(1);
    const value = promise_ops.usingCreateAsyncDisposableStack(ctx, global) catch |err| {
        return routeRuntimeError(ctx, output, global, stack, frame, catch_target, err);
    };
    stack.pushOwnedAssumeCapacity(value);
    return .done;
}

pub noinline fn execVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const code = function.byteCode();
    if (frame.pc >= code.len) return error.InvalidBytecode;
    const sub = code[frame.pc];
    frame.pc += 1;
    if (bytecode.opcode.using_sub.isAdd(sub)) {
        return addResourceWithHint(ctx, output, global, stack, frame, catch_target, bytecode.opcode.using_sub.addHint(sub));
    }
    return switch (sub) {
        bytecode.opcode.using_sub.create => createStackVm(ctx, global, stack, frame, catch_target, output),
        bytecode.opcode.using_sub.dispose => disposeStackVm(ctx, output, global, stack, frame, catch_target, .normal),
        bytecode.opcode.using_sub.dispose_throw => disposeStackVm(ctx, output, global, stack, frame, catch_target, .throw),
        // Cold-plane reclamation (opcode-space survey §7): zero executions
        // in the benchmark suite, so the second-level branch is free.
        bytecode.opcode.using_sub.put_super_value => {
            _ = try object_ops.putSuperValue(ctx, output, global, stack, function, frame, catch_target);
            return .done;
        },
        bytecode.opcode.using_sub.to_object => {
            _ = try vm_value.toObjectVm(ctx, output, stack, frame, catch_target, global);
            return .done;
        },
        bytecode.opcode.using_sub.set_proto => {
            try vm_literal.setProto(ctx, stack);
            return .done;
        },
        bytecode.opcode.using_sub.check_ctor_return => {
            _ = try vm_call.checkCtorReturnVm(ctx, output, stack, frame, catch_target, global);
            return .done;
        },
        bytecode.opcode.using_sub.is_undefined => {
            try vm_value.isUndefined(ctx.runtime, stack);
            return .done;
        },
        bytecode.opcode.using_sub.typeof_is_undefined => {
            try vm_value.typeOfIsUndefined(ctx.runtime, stack);
            return .done;
        },
        bytecode.opcode.using_sub.typeof_is_function => {
            try vm_value.typeOfIsFunction(ctx.runtime, stack);
            return .done;
        },
        bytecode.opcode.using_sub.insert4 => {
            try vm_value.insert4(ctx, stack);
            return .done;
        },
        bytecode.opcode.using_sub.rot5l => {
            try vm_value.rot5l(ctx, stack);
            return .done;
        },
        bytecode.opcode.using_sub.perm5 => {
            try vm_value.perm5(ctx, stack);
            return .done;
        },
        bytecode.opcode.using_sub.dup2 => {
            try vm_value.dup2(ctx, stack);
            return .done;
        },
        bytecode.opcode.using_sub.swap2 => {
            try vm_value.swap2(ctx, stack);
            return .done;
        },
        bytecode.opcode.using_sub.rot3r => {
            try vm_value.rot3r(ctx, stack);
            return .done;
        },
        bytecode.opcode.using_sub.rot4l => {
            try vm_value.rot4l(ctx, stack);
            return .done;
        },
        bytecode.opcode.using_sub.dup3 => {
            try vm_value.dup3(ctx, stack);
            return .done;
        },
        bytecode.opcode.using_sub.dup1 => {
            try vm_value.dup1(ctx, stack);
            return .done;
        },
        else => error.InvalidBytecode,
    };
}

fn addResourceWithHint(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    hint_byte: u8,
) !Step {
    const hint: core.object.DisposalHint = switch (hint_byte) {
        @intFromEnum(core.object.DisposalHint.sync) => .sync,
        @intFromEnum(core.object.DisposalHint.async) => .async,
        else => return error.InvalidBytecode,
    };
    const stack_len = stack.len();
    if (stack_len < 2) return error.StackUnderflow;
    const args = stack.values[stack_len - 2 .. stack_len];

    const result = switch (hint) {
        .sync => disposable_ops.usingAddSyncResource(ctx, output, global, args),
        .async => promise_ops.usingAddAsyncResource(ctx, output, global, args),
    } catch |err| {
        try popOwnedOperands(ctx.runtime, stack, 2);
        return routeRuntimeError(ctx, output, global, stack, frame, catch_target, err);
    };
    result.free(ctx.runtime);
    try popOwnedOperands(ctx.runtime, stack, 2);
    return .done;
}

fn disposeStack(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack_value: core.JSValue,
    completion: ?core.JSValue,
) !core.JSValue {
    const disposable_stack = try disposable_ops.parserDisposableStackReceiver(stack_value);
    if (!disposable_stack.disposableStackHasAsyncHint()) {
        if (completion) |thrown| {
            const args = [_]core.JSValue{ stack_value, thrown };
            return disposable_ops.usingDisposeSyncStackForThrow(ctx, output, global, &args);
        }
        const args = [_]core.JSValue{stack_value};
        return disposable_ops.usingDisposeSyncStack(ctx, output, global, &args);
    }

    if (completion) |thrown| {
        const args = [_]core.JSValue{ stack_value, thrown };
        return promise_ops.usingDisposeAsyncStackForThrow(ctx, output, global, &args);
    }
    const args = [_]core.JSValue{stack_value};
    return promise_ops.usingDisposeAsyncStack(ctx, output, global, &args);
}

pub noinline fn disposeStackVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    disposition: DisposalDisposition,
) !Step {
    const operand_count: usize = switch (disposition) {
        .normal => 1,
        .throw => 2,
    };
    const stack_len = stack.len();
    if (stack_len < operand_count) return error.StackUnderflow;
    const operand_base = stack_len - operand_count;
    const stack_value = stack.values[operand_base];
    const completion = if (disposition == .throw) stack.values[operand_base + 1] else null;

    const result = disposeStack(ctx, output, global, stack_value, completion) catch |err| {
        try popOwnedOperands(ctx.runtime, stack, operand_count);
        return routeRuntimeError(ctx, output, global, stack, frame, catch_target, err);
    };
    try popOwnedOperands(ctx.runtime, stack, operand_count);
    stack.pushOwnedAssumeCapacity(result);
    return .done;
}
