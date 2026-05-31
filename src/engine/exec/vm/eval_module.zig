const std = @import("std");

const bytecode = @import("../../bytecode/root.zig");
const builtins = @import("../../builtins/root.zig");
const core = @import("../../core/root.zig");
const frame_mod = @import("../frame.zig");
const property_ops = @import("../property_ops.zig");
const shared_vm = @import("shared.zig");
const stack_mod = @import("../stack.zig");
const value_ops = @import("../value_ops.zig");

pub fn directEval(
    ctx: *core.Context,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    output: ?*std.Io.Writer,
    global: *core.Object,
    class_field_initializer_flag: u16,
    parameter_initializer_flag: u16,
    comptime execDirectEval: anytype,
) !void {
    const eval_operands = readInt(u32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    const argc: u16 = @intCast(eval_operands & 0xffff);
    const eval_scope: u16 = @intCast((eval_operands >> 16) & 0xffff);
    try execDirectEval(
        ctx,
        stack,
        function,
        frame,
        catch_target,
        argc,
        output,
        global,
        (eval_scope & class_field_initializer_flag) != 0,
        (eval_scope & parameter_initializer_flag) != 0,
    );
}

pub fn applyEval(
    ctx: *core.Context,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    output: ?*std.Io.Writer,
    global: *core.Object,
    class_field_initializer_flag: u16,
    parameter_initializer_flag: u16,
    comptime execApplyEval: anytype,
) !void {
    const eval_scope = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    try execApplyEval(
        ctx,
        stack,
        function,
        frame,
        catch_target,
        output,
        global,
        (eval_scope & class_field_initializer_flag) != 0,
        (eval_scope & parameter_initializer_flag) != 0,
    );
}

pub fn dynamicImport(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime toStringForAnnexB: anytype,
    comptime getValueProperty: anytype,
    comptime promisePrototypeFromGlobal: anytype,
    comptime createNamedError: anytype,
    comptime rejectedPromiseForRuntimeError: anytype,
) !void {
    const options = try stack.pop();
    defer options.free(ctx.runtime);
    const specifier = try stack.pop();
    defer specifier.free(ctx.runtime);

    const prototype = promisePrototypeFromGlobal(ctx.runtime, global);
    const specifier_string = toStringForAnnexB(ctx, output, global, specifier, function, frame) catch |err| {
        const rejected = try rejectedPromiseForRuntimeError(ctx, global, err, prototype);
        errdefer rejected.free(ctx.runtime);
        try stack.pushOwned(rejected);
        return;
    };
    defer specifier_string.free(ctx.runtime);

    if (!options.isUndefined() and !options.isObject()) {
        try pushRejectedTypeError(ctx, global, stack, prototype, createNamedError, "options must be an object");
        return;
    }

    if (options.isObject()) {
        const with_atom = try ctx.runtime.internAtom("with");
        defer ctx.runtime.atoms.free(with_atom);
        const attributes = getValueProperty(ctx, output, global, options, with_atom, function, frame) catch |err| {
            const rejected = try rejectedPromiseForRuntimeError(ctx, global, err, prototype);
            errdefer rejected.free(ctx.runtime);
            try stack.pushOwned(rejected);
            return;
        };
        defer attributes.free(ctx.runtime);
        if (!attributes.isUndefined() and !attributes.isObject()) {
            try pushRejectedTypeError(ctx, global, stack, prototype, createNamedError, "options.with must be an object");
            return;
        }
        if (attributes.isObject()) {
            try enumerateImportAttributes(ctx, output, global, attributes, function, frame, getValueProperty, rejectedPromiseForRuntimeError, prototype, stack);
        }
    }

    if (ctx.dynamic_import_callback) |callback| {
        const referrer_path = ctx.runtime.atoms.name(function.name) orelse "";
        var specifier_bytes = std.ArrayList(u8).empty;
        defer specifier_bytes.deinit(ctx.runtime.memory.allocator);
        try value_ops.appendRawString(ctx.runtime, &specifier_bytes, specifier_string);

        const namespace = callback(ctx.dynamic_import_userdata, ctx, output, global, referrer_path, specifier_bytes.items) catch |err| {
            if (err == error.ModuleNotFound) {
                try pushRejectedTypeError(ctx, global, stack, prototype, createNamedError, "module not found");
                return;
            }
            const rejected = try rejectedPromiseForRuntimeError(ctx, global, err, prototype);
            errdefer rejected.free(ctx.runtime);
            try stack.pushOwned(rejected);
            return;
        };
        defer namespace.free(ctx.runtime);
        const promise = try builtins.promise.fulfilledWithPrototype(ctx.runtime, namespace, prototype);
        errdefer promise.free(ctx.runtime);
        try stack.pushOwned(promise);
        return;
    }

    try pushRejectedTypeError(ctx, global, stack, prototype, createNamedError, "dynamic import is not supported");
}

fn enumerateImportAttributes(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    attributes: core.Value,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime rejectedPromiseForRuntimeError: anytype,
    prototype: ?*core.Object,
    stack: *stack_mod.Stack,
) !void {
    const object = property_ops.expectObject(attributes) catch return;
    const keys = shared_vm.objectRestOwnKeys(ctx, output, global, object) catch |err| {
        const rejected = try rejectedPromiseForRuntimeError(ctx, global, err, prototype);
        errdefer rejected.free(ctx.runtime);
        try stack.pushOwned(rejected);
        return;
    };
    defer core.Object.freeKeys(ctx.runtime, keys);
    for (keys) |key| {
        if (ctx.runtime.atoms.kind(key) != .string) continue;
        const desc = (shared_vm.proxyAwareOwnPropertyDescriptor(ctx, output, global, object, key, function, frame) catch |err| {
            const rejected = try rejectedPromiseForRuntimeError(ctx, global, err, prototype);
            errdefer rejected.free(ctx.runtime);
            try stack.pushOwned(rejected);
            return;
        }) orelse continue;
        defer desc.destroy(ctx.runtime);
        if (!(desc.enumerable orelse false)) continue;
        const value = getValueProperty(ctx, output, global, attributes, key, function, frame) catch |err| {
            const rejected = try rejectedPromiseForRuntimeError(ctx, global, err, prototype);
            errdefer rejected.free(ctx.runtime);
            try stack.pushOwned(rejected);
            return;
        };
        value.free(ctx.runtime);
    }
}

fn pushRejectedTypeError(
    ctx: *core.Context,
    global: *core.Object,
    stack: *stack_mod.Stack,
    prototype: ?*core.Object,
    comptime createNamedError: anytype,
    message: []const u8,
) !void {
    const error_value = try createNamedError(ctx.runtime, global, "TypeError", message);
    defer error_value.free(ctx.runtime);
    const promise = try builtins.promise.rejectedWithPrototype(ctx.runtime, error_value, prototype);
    errdefer promise.free(ctx.runtime);
    try stack.pushOwned(promise);
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
