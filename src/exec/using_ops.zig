//! Bytecode handlers for explicit-resource-management (`using`) operations.
//!
//! These handlers own and pop VM operands, delegate resource lifetime to
//! `disposable_ops`, and route synchronous/async disposal failures through the
//! active catch target. Promise scheduling remains in `promise_ops`.

const std = @import("std");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const stack_mod = @import("stack.zig");
const HostError = @import("exceptions.zig").HostError;
const Vm = @import("tailcall_dispatch.zig").Vm;

const call_runtime = @import("call_runtime.zig");
const disposable_ops = @import("disposable_ops.zig");
const promise_ops = @import("promise_ops.zig");
const object_ops = @import("object_ops.zig");
const vm_call = @import("vm_call.zig");
const vm_literal = @import("vm_literal.zig");
const vm_property_field = @import("vm_property_field.zig");
const vm_value = @import("vm_value.zig");

pub const DisposalDisposition = enum {
    normal,
    throw,
};

fn popOwnedOperands(_: *core.JSRuntime, stack: *stack_mod.Stack, count: usize) !void {
    var remaining = count;
    while (remaining != 0) : (remaining -= 1) {
        _ = try stack.pop();
    }
}

fn routeRuntimeError(vm: *Vm, err: anytype) HostError!void {
    if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) {
        return;
    }
    return err;
}

pub noinline fn createStackVm(vm: *Vm) HostError!void {
    const stack = vm.stack;
    try stack.reserveAdditional(1);
    const value = promise_ops.usingCreateAsyncDisposableStack(vm.ctx, vm.global) catch |err| {
        return routeRuntimeError(vm, err);
    };
    stack.pushOwnedAssumeCapacity(value);
}

pub noinline fn execVm(vm: *Vm) HostError!void {
    const ctx = vm.ctx;
    const output = vm.output;
    const global = vm.global;
    const stack = vm.stack;
    const function = vm.function;
    const frame = vm.frame;
    const catch_target = vm.catch_target;
    const code = function.byteCode();
    if (frame.pc >= code.len) return error.InvalidBytecode;
    const sub = code[frame.pc];
    frame.pc += 1;
    if (bytecode.opcode.ext0_sub.isAdd(sub)) {
        try addResourceWithHint(vm, bytecode.opcode.ext0_sub.addHint(sub));
        return;
    }
    switch (sub) {
        bytecode.opcode.ext0_sub.create => try createStackVm(vm),
        bytecode.opcode.ext0_sub.dispose => try disposeStackVm(vm, .normal),
        bytecode.opcode.ext0_sub.dispose_throw => try disposeStackVm(vm, .throw),
        // Cold-plane reclamation (opcode-space survey §7): zero executions
        // in the benchmark suite, so the second-level branch is free.
        bytecode.opcode.ext0_sub.put_super_value => {
            try object_ops.putSuperValue(vm);
        },
        bytecode.opcode.ext0_sub.to_object => {
            try vm_value.toObjectVm(vm);
        },
        // C0 late-encoding resident: the canonical final encoding of
        // to_propkey. Identical semantics to the direct id 112, which
        // stays executable for the D11 alias window only.
        bytecode.opcode.ext0_sub.to_propkey => {
            _ = try vm_property_field.toPropKeyVm(ctx, output, global, stack, function, frame, catch_target);
        },
        // C1-1 resident: identical semantics to the direct id 75, which
        // stays executable for its D11 window only. The opcode constant is
        // passed literally -- the shared setName helper selects its
        // computed arm from it, never from the stream byte.
        bytecode.opcode.ext0_sub.set_name_computed => {
            try vm_property_field.setName(ctx, output, global, stack, function, frame, bytecode.opcode.op.set_name_computed);
        },
        bytecode.opcode.ext0_sub.set_proto => {
            try vm_literal.setProto(ctx, stack);
        },
        bytecode.opcode.ext0_sub.check_ctor_return => {
            try vm_call.checkCtorReturnVm(vm);
        },
        bytecode.opcode.ext0_sub.is_undefined => {
            try vm_value.isUndefined(ctx.runtime, stack);
        },
        bytecode.opcode.ext0_sub.typeof_is_undefined => {
            try vm_value.typeOfIsUndefined(ctx.runtime, stack);
        },
        bytecode.opcode.ext0_sub.typeof_is_function => {
            try vm_value.typeOfIsFunction(ctx.runtime, stack);
        },
        bytecode.opcode.ext0_sub.insert4 => {
            try vm_value.insert4(ctx, stack);
        },
        bytecode.opcode.ext0_sub.rot5l => {
            try vm_value.rot5l(ctx, stack);
        },
        bytecode.opcode.ext0_sub.perm5 => {
            try vm_value.perm5(ctx, stack);
        },
        bytecode.opcode.ext0_sub.dup2 => {
            try vm_value.dup2(ctx, stack);
        },
        bytecode.opcode.ext0_sub.swap2 => {
            try vm_value.swap2(ctx, stack);
        },
        bytecode.opcode.ext0_sub.rot3r => {
            try vm_value.rot3r(ctx, stack);
        },
        bytecode.opcode.ext0_sub.rot4l => {
            try vm_value.rot4l(ctx, stack);
        },
        bytecode.opcode.ext0_sub.dup3 => {
            try vm_value.dup3(ctx, stack);
        },
        bytecode.opcode.ext0_sub.dup1 => {
            try vm_value.dup1(ctx, stack);
        },
        else => return error.InvalidBytecode,
    }
}

fn addResourceWithHint(vm: *Vm, hint_byte: u8) HostError!void {
    const ctx = vm.ctx;
    const stack = vm.stack;
    const hint: core.object.DisposalHint = switch (hint_byte) {
        @intFromEnum(core.object.DisposalHint.sync) => .sync,
        @intFromEnum(core.object.DisposalHint.async) => .async,
        else => return error.InvalidBytecode,
    };
    const stack_len = stack.len();
    if (stack_len < 2) return error.StackUnderflow;
    const args = stack.values[stack_len - 2 .. stack_len];

    _ = switch (hint) {
        .sync => disposable_ops.usingAddSyncResource(ctx, vm.output, vm.global, args),
        .async => promise_ops.usingAddAsyncResource(ctx, vm.output, vm.global, args),
    } catch |err| {
        try popOwnedOperands(vm.rt, stack, 2);
        return routeRuntimeError(vm, err);
    };
    try popOwnedOperands(vm.rt, stack, 2);
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

pub noinline fn disposeStackVm(vm: *Vm, disposition: DisposalDisposition) HostError!void {
    const stack = vm.stack;
    const operand_count: usize = switch (disposition) {
        .normal => 1,
        .throw => 2,
    };
    const stack_len = stack.len();
    if (stack_len < operand_count) return error.StackUnderflow;
    const operand_base = stack_len - operand_count;
    const stack_value = stack.values[operand_base];
    const completion = if (disposition == .throw) stack.values[operand_base + 1] else null;

    const result = disposeStack(vm.ctx, vm.output, vm.global, stack_value, completion) catch |err| {
        try popOwnedOperands(vm.rt, stack, operand_count);
        return routeRuntimeError(vm, err);
    };
    try popOwnedOperands(vm.rt, stack, operand_count);
    stack.pushOwnedAssumeCapacity(result);
}
