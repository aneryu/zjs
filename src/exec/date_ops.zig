const std = @import("std");

const bytecode = @import("../bytecode/root.zig");
const builtins = @import("../builtins/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const value_ops = @import("value_ops.zig");
const call_runtime = @import("call_runtime.zig");
const coercion_ops = @import("coercion_ops.zig");
const object_ops = @import("object_ops.zig");
const string_ops = @import("string_ops.zig");

const DateToPrimitiveHint = enum {
    string,
    number,
};

pub fn qjsDateSetYear(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const object = object_ops.objectFromValue(this_value) orelse return null;
    if (object.class_id != core.class.ids.date) return null;
    const captured_ms_value = try builtins.date.methodCall(ctx.runtime, this_value, 1);
    defer captured_ms_value.free(ctx.runtime);
    const captured_ms = value_ops.numberValue(captured_ms_value) orelse std.math.nan(f64);
    const year_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const year_value = try coercion_ops.toNumberForDateMethod(ctx, output, global, year_input, caller_function, caller_frame);
    defer year_value.free(ctx.runtime);
    const year_number = value_ops.numberValue(year_value) orelse std.math.nan(f64);
    return try builtins.date.setYearNumber(ctx.runtime, this_value, captured_ms, year_number);
}

pub fn qjsDateSetTime(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const object = object_ops.objectFromValue(this_value) orelse return null;
    if (object.class_id != core.class.ids.date) return null;
    const time_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const time_value = try coercion_ops.toNumberForDateMethod(ctx, output, global, time_input, caller_function, caller_frame);
    defer time_value.free(ctx.runtime);
    return try builtins.date.methodCallArgs(ctx.runtime, this_value, 24, &.{time_value});
}

pub fn qjsDateStaticCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    _ = this_value;
    if (method_id != 1) return null;
    var coerced_args: [7]core.JSValue = undefined;
    var coerced_len: usize = 0;
    defer {
        for (coerced_args[0..coerced_len]) |value| value.free(ctx.runtime);
    }
    while (coerced_len < args.len and coerced_len < coerced_args.len) : (coerced_len += 1) {
        coerced_args[coerced_len] = try coercion_ops.toNumberForDateMethod(ctx, output, global, args[coerced_len], caller_function, caller_frame);
    }
    return try builtins.date.staticCall(ctx.runtime, method_id, coerced_args[0..coerced_len]);
}

pub fn qjsDateCapturedSetterCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (method_id < 25 or method_id > 31) return null;
    const object = object_ops.objectFromValue(this_value) orelse return null;
    if (object.class_id != core.class.ids.date) return null;

    const captured_ms_value = try builtins.date.methodCall(ctx.runtime, this_value, 1);
    defer captured_ms_value.free(ctx.runtime);
    const captured_ms = value_ops.numberValue(captured_ms_value) orelse std.math.nan(f64);

    var coerced_args: [4]core.JSValue = undefined;
    var coerced_len: usize = 0;
    defer {
        for (coerced_args[0..coerced_len]) |value| value.free(ctx.runtime);
    }
    while (coerced_len < args.len and coerced_len < coerced_args.len) : (coerced_len += 1) {
        coerced_args[coerced_len] = try coercion_ops.toNumberForDateMethod(ctx, output, global, args[coerced_len], caller_function, caller_frame);
    }

    return try builtins.date.methodCallArgsWithCapturedMs(ctx.runtime, this_value, method_id, captured_ms, coerced_args[0..coerced_len]);
}

pub fn qjsDateToJsonCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    _ = args;
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;

    const primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, this_value);
    defer primitive.free(ctx.runtime);
    if (primitive.isNumber()) {
        const number = value_ops.numberValue(primitive) orelse std.math.nan(f64);
        if (!std.math.isFinite(number)) return core.JSValue.nullValue();
    }

    const key = try ctx.runtime.internAtom("toISOString");
    defer ctx.runtime.atoms.free(key);
    const method = try object_ops.getValueProperty(ctx, output, global, this_value, key, caller_function, caller_frame);
    defer method.free(ctx.runtime);
    if (!call_runtime.isCallableValue(method)) return error.TypeError;
    return try call_runtime.callValueOrBytecode(ctx, output, global, this_value, method, &.{}, caller_function, caller_frame);
}

pub fn qjsDateConstructWithPrototype(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    prototype: ?*core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len == 0) return builtins.date.constructWithPrototype(ctx.runtime, args, prototype);

    if (args.len == 1) {
        if (object_ops.objectFromValue(args[0])) |object| {
            if (object.class_id == core.class.ids.date) {
                const time_value = try builtins.date.methodCall(ctx.runtime, args[0], 1);
                defer time_value.free(ctx.runtime);
                return builtins.date.constructWithPrototype(ctx.runtime, &.{time_value}, prototype);
            }

            const primitive = try coercion_ops.toPrimitiveForAddition(ctx, output, global, args[0]);
            defer primitive.free(ctx.runtime);
            if (primitive.isString()) return builtins.date.constructWithPrototype(ctx.runtime, &.{primitive}, prototype);
            const number = try value_ops.toNumberValue(ctx.runtime, primitive);
            defer number.free(ctx.runtime);
            return builtins.date.constructWithPrototype(ctx.runtime, &.{number}, prototype);
        }

        if (args[0].isString()) return builtins.date.constructWithPrototype(ctx.runtime, args, prototype);
        const number = try value_ops.toNumberValue(ctx.runtime, args[0]);
        defer number.free(ctx.runtime);
        return builtins.date.constructWithPrototype(ctx.runtime, &.{number}, prototype);
    }

    var coerced_args: [7]core.JSValue = undefined;
    var coerced_len: usize = 0;
    defer {
        for (coerced_args[0..coerced_len]) |value| value.free(ctx.runtime);
    }
    while (coerced_len < args.len and coerced_len < coerced_args.len) : (coerced_len += 1) {
        coerced_args[coerced_len] = try coercion_ops.toNumberForDateMethod(ctx, output, global, args[coerced_len], null, null);
    }
    return builtins.date.constructWithPrototype(ctx.runtime, coerced_args[0..coerced_len], prototype);
}

pub fn qjsDateToPrimitiveCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!this_value.isObject()) return error.TypeError;

    const hint_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const hint = qjsDateToPrimitiveHint(hint_value) orelse return error.TypeError;
    return switch (hint) {
        .string => try qjsDateOrdinaryToPrimitive(ctx, output, global, this_value, true, caller_function, caller_frame),
        .number => try qjsDateOrdinaryToPrimitive(ctx, output, global, this_value, false, caller_function, caller_frame),
    };
}

fn qjsDateToPrimitiveHint(value: core.JSValue) ?DateToPrimitiveHint {
    if (!value.isString()) return null;
    if (string_ops.stringValueUnitsEqualBytes(value, "string") or string_ops.stringValueUnitsEqualBytes(value, "default")) return .string;
    if (string_ops.stringValueUnitsEqualBytes(value, "number")) return .number;
    return null;
}

fn qjsDateOrdinaryToPrimitive(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    string_first: bool,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (string_first) {
        if (try object_ops.callObjectToPrimitiveMethod(ctx, output, global, receiver, "toString", caller_function, caller_frame)) |primitive| return primitive;
        if (try object_ops.callObjectToPrimitiveMethod(ctx, output, global, receiver, "valueOf", caller_function, caller_frame)) |primitive| return primitive;
    } else {
        if (try object_ops.callObjectToPrimitiveMethod(ctx, output, global, receiver, "valueOf", caller_function, caller_frame)) |primitive| return primitive;
        if (try object_ops.callObjectToPrimitiveMethod(ctx, output, global, receiver, "toString", caller_function, caller_frame)) |primitive| return primitive;
    }
    return error.TypeError;
}
