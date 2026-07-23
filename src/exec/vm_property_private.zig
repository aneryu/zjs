//! Private-field opcode handlers (get/put/define_private_field).

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const call_runtime = @import("call_runtime.zig");
const exception_ops = @import("vm_exception_ops.zig");
const object_ops = @import("object_ops.zig");
const stack_mod = @import("stack.zig");

const property_vm = @import("vm_property.zig");
const Step = property_vm.Step;

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
    if (!receiver.isObject()) {
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
    defer key.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    const atom_id = try privateFieldAtom(ctx, global, frame, obj, key);
    const value = try object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame);
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
}

pub noinline fn getPrivateFieldVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    getPrivateField(ctx, output, global, stack, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
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
    defer key.free(ctx.runtime);
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    const atom_id = try privateFieldAtom(ctx, global, frame, obj, key);
    const result = try object_ops.setValueProperty(ctx, output, global, obj, atom_id, value, function, frame);
    result.free(ctx.runtime);
}

pub noinline fn putPrivateFieldVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    putPrivateField(ctx, output, global, stack, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
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
    defer value.free(ctx.runtime);
    const key = try stack.pop();
    defer key.free(ctx.runtime);
    const obj = stack.peek() orelse return error.StackUnderflow;
    defer obj.free(ctx.runtime);
    const atom_id = try privateFieldAtom(ctx, global, frame, obj, key);
    const object = try property_ops.expectObject(obj);
    try object_ops.defineClassFieldDataProperty(ctx.runtime, object, atom_id, value);
}

pub noinline fn definePrivateFieldVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    definePrivateField(ctx, output, global, stack, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}
