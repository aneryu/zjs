//! Private-field opcode handlers (get/put/define_private_field).

const std = @import("std");
const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const stack_mod = @import("stack.zig");

const property_vm = @import("vm_property.zig");
const Step = property_vm.Step;

pub fn getPrivateField(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime toPropertyKeyAtom: anytype,
    comptime getValueProperty: anytype,
) !void {
    const key = try stack.pop();
    defer key.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key, function, frame);
    defer ctx.runtime.atoms.free(atom_id);
    const value = try getValueProperty(ctx, output, global, obj, atom_id, function, frame);
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
}

pub fn getPrivateFieldVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime toPropertyKeyAtom: anytype,
    comptime getValueProperty: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    getPrivateField(ctx, output, global, stack, function, frame, toPropertyKeyAtom, getValueProperty) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn putPrivateField(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime toPropertyKeyAtom: anytype,
    comptime setValueProperty: anytype,
) !void {
    const key = try stack.pop();
    defer key.free(ctx.runtime);
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key, function, frame);
    defer ctx.runtime.atoms.free(atom_id);
    const result = try setValueProperty(ctx, output, global, obj, atom_id, value, function, frame);
    result.free(ctx.runtime);
}

pub fn putPrivateFieldVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime toPropertyKeyAtom: anytype,
    comptime setValueProperty: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    putPrivateField(ctx, output, global, stack, function, frame, toPropertyKeyAtom, setValueProperty) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn definePrivateField(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime toPropertyKeyAtom: anytype,
    comptime defineClassFieldDataProperty: anytype,
) !void {
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const key = try stack.pop();
    defer key.free(ctx.runtime);
    const obj = stack.peek() orelse return error.StackUnderflow;
    defer obj.free(ctx.runtime);
    const object = try property_ops.expectObject(obj);
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key, function, frame);
    defer ctx.runtime.atoms.free(atom_id);
    try defineClassFieldDataProperty(ctx.runtime, object, atom_id, value);
}

pub fn definePrivateFieldVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime toPropertyKeyAtom: anytype,
    comptime defineClassFieldDataProperty: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    definePrivateField(ctx, output, global, stack, function, frame, toPropertyKeyAtom, defineClassFieldDataProperty) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}
