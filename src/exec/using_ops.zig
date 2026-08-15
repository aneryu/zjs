const std = @import("std");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");

const call_runtime = @import("call_runtime.zig");
const disposable_ops = @import("disposable_ops.zig");
const promise_ops = @import("promise_ops.zig");
const value_vm = @import("vm_value.zig");

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
    const value = promise_ops.qjsUsingCreateAsyncDisposableStack(ctx, global) catch |err| {
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
        bytecode.opcode.using_sub.is_undefined => {
            try value_vm.isUndefined(ctx.runtime, stack);
            return .done;
        },
        bytecode.opcode.using_sub.typeof_is_undefined => {
            try value_vm.typeOfIsUndefined(ctx.runtime, stack);
            return .done;
        },
        bytecode.opcode.using_sub.typeof_is_function => {
            try value_vm.typeOfIsFunction(ctx.runtime, stack);
            return .done;
        },
        bytecode.opcode.using_sub.insert4 => {
            try value_vm.insert4(ctx, stack);
            return .done;
        },
        bytecode.opcode.using_sub.rot5l => {
            try value_vm.rot5l(ctx, stack);
            return .done;
        },
        bytecode.opcode.using_sub.perm5 => {
            try value_vm.perm5(ctx, stack);
            return .done;
        },
        bytecode.opcode.using_sub.dup2 => {
            try value_vm.dup2(ctx, stack);
            return .done;
        },
        bytecode.opcode.using_sub.swap2 => {
            try value_vm.swap2(ctx, stack);
            return .done;
        },
        bytecode.opcode.using_sub.rot3r => {
            try value_vm.rot3r(ctx, stack);
            return .done;
        },
        bytecode.opcode.using_sub.rot4l => {
            try value_vm.rot4l(ctx, stack);
            return .done;
        },
        bytecode.opcode.using_sub.dup3 => {
            try value_vm.dup3(ctx, stack);
            return .done;
        },
        bytecode.opcode.using_sub.dup1 => {
            try value_vm.dup1(ctx, stack);
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
        .sync => disposable_ops.qjsUsingAddSyncResource(ctx, output, global, args),
        .async => promise_ops.qjsUsingAddAsyncResource(ctx, output, global, args),
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
            return disposable_ops.qjsUsingDisposeSyncStackForThrow(ctx, output, global, &args);
        }
        const args = [_]core.JSValue{stack_value};
        return disposable_ops.qjsUsingDisposeSyncStack(ctx, output, global, &args);
    }

    if (completion) |thrown| {
        const args = [_]core.JSValue{ stack_value, thrown };
        return promise_ops.qjsUsingDisposeAsyncStackForThrow(ctx, output, global, &args);
    }
    const args = [_]core.JSValue{stack_value};
    return promise_ops.qjsUsingDisposeAsyncStack(ctx, output, global, &args);
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
