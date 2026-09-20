//! Private-field opcode handlers (get/put/define_private_field).

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const call_runtime = @import("call_runtime.zig");
const exception_ops = @import("exception_ops.zig");
const object_ops = @import("object_ops.zig");
const stack_mod = @import("stack.zig");
const Vm = @import("tailcall_dispatch.zig").Vm;
const HostError = @import("exceptions.zig").HostError;

const vm_property = @import("vm_property.zig");

fn privateFieldAtom(
    ctx: *core.JSContext,
    global: *core.Object,
    frame: *frame_mod.Frame,
    receiver: core.JSValue,
    key: core.JSValue,
) !core.Atom {
    const error_global = if (object_ops.objectFromValue(frame.current_function)) |function_object|
        object_ops.objectRealmGlobal(function_object) orelse global
    else
        global;
    if (!receiver.is(.object)) {
        _ = try exception_ops.throwTypeErrorMessage(ctx, error_global, "not an object");
        unreachable;
    }
    if (key.asSymbolAtom()) |atom_id| return atom_id;
    _ = try exception_ops.throwTypeErrorMessage(ctx, error_global, "not a symbol");
    unreachable;
}

pub fn getPrivateField(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    const key = try stack.pop();
    const obj = try stack.pop();
    const atom_id = try privateFieldAtom(ctx, global, frame, obj, key);
    const value = try object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame);
    try stack.pushOwned(value);
}

pub noinline fn getPrivateFieldVm(vm: *Vm) HostError!void {
    getPrivateField(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub fn putPrivateField(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    const key = try stack.pop();
    const value = try stack.pop();
    const obj = try stack.pop();
    const atom_id = try privateFieldAtom(ctx, global, frame, obj, key);
    _ = try object_ops.setValueProperty(ctx, output, global, obj, atom_id, value, function, frame);
}

pub noinline fn putPrivateFieldVm(vm: *Vm) HostError!void {
    putPrivateField(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub fn definePrivateField(
    ctx: *core.JSContext,
    _: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    _: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    const value = try stack.pop();
    const key = try stack.pop();
    const obj = stack.peek() orelse return error.StackUnderflow;
    const atom_id = try privateFieldAtom(ctx, global, frame, obj, key);
    const object = try property_ops.expectObject(obj);
    try object_ops.defineClassFieldDataProperty(ctx.runtime, object, atom_id, value);
}

pub noinline fn definePrivateFieldVm(vm: *Vm) HostError!void {
    definePrivateField(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}
