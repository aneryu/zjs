//! Error.stack capture/formatting, backtrace naming and CallSite helpers.

const std = @import("std");
const frame_mod = @import("frame.zig");
const method_ids = core.host_function.builtin_method_ids;
const error_stack_ops = @import("error_stack_ops.zig");
const bytecode = @import("../bytecode.zig");

const core = @import("../core/root.zig");
const exception_ops = @import("exception_ops.zig");
const property_ops = @import("property_ops.zig");
const value_ops = @import("value_ops.zig");

const call_runtime = @import("call_runtime.zig");
const array_ops = @import("array_ops.zig");
const object_ops = @import("object_ops.zig");
const string_ops = @import("string_ops.zig");

// Helpers that remain in call_runtime.zig (generic runtime utilities outside the
// error-stack cluster).
const buildCallSiteArray = array_ops.buildCallSiteArray;
const buildErrorStackStringValue = string_ops.buildErrorStackStringValue;
const callValueOrBytecodeRoot = call_runtime.callValueOrBytecodeRoot;
const defineDataPropertyByName = object_ops.defineDataPropertyByName;
const formatCapturedErrorStackStringValue = string_ops.formatCapturedErrorStackStringValue;
const isCallableValue = call_runtime.isCallableValue;

pub fn captureErrorStack(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, instance: *core.Object) !void {
    _ = output;
    const sites = try buildCallSiteArray(ctx, global, null);
    defer sites.free(ctx.runtime);
    try instance.setErrorStackSites(ctx.runtime, sites);
}

/// Value-level stack capture: attach the current VM backtrace as call sites
/// to `value` when it is an object; non-object values are ignored. This is
/// the seam used by the `exception_ops` construction primitives, which
/// capture the stack at error construction time (QuickJS `build_backtrace`
/// inside `JS_ThrowError2`).
pub fn attachStackToErrorValue(ctx: *core.JSContext, global: *core.Object, value: core.JSValue) !void {
    const object = property_ops.expectObject(value) catch return;
    try captureErrorStack(ctx, null, global, object);
}

pub fn buildErrorStackValue(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, error_value: core.JSValue, skip_name: ?[]const u8) !core.JSValue {
    if (ctx.runtime.formatting_error_stack) return buildErrorStackStringValue(ctx, global, skip_name);

    if (try errorPrepareStackTrace(ctx.runtime, global)) |prepare| {
        defer prepare.free(ctx.runtime);
        const sites = try buildCallSiteArray(ctx, global, skip_name);
        defer sites.free(ctx.runtime);
        ctx.runtime.formatting_error_stack = true;
        defer ctx.runtime.formatting_error_stack = false;
        return callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), prepare, &.{ error_value, sites }, null, null) catch |err| {
            if (exception_ops.pendingExceptionMatchesError(ctx, err)) {
                const thrown_value = ctx.takeException();
                thrown_value.free(ctx.runtime);
                return core.JSValue.nullValue();
            }
            if (ctx.hasException()) ctx.clearException();
            if (exception_ops.runtimeErrorInfo(err) != null) return core.JSValue.nullValue();
            return err;
        };
    }
    return buildErrorStackStringValue(ctx, global, skip_name);
}

pub fn formatCapturedErrorStackValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    error_value: core.JSValue,
    sites_value: core.JSValue,
    site_count: usize,
) !core.JSValue {
    if (ctx.runtime.formatting_error_stack) return formatCapturedErrorStackStringValue(ctx, sites_value, site_count);

    if (try errorPrepareStackTrace(ctx.runtime, global)) |prepare| {
        defer prepare.free(ctx.runtime);
        const sites_arg = sites_value.dup();
        defer sites_arg.free(ctx.runtime);
        ctx.runtime.formatting_error_stack = true;
        defer ctx.runtime.formatting_error_stack = false;
        return callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), prepare, &.{ error_value, sites_arg }, null, null) catch |err| {
            if (exception_ops.pendingExceptionMatchesError(ctx, err)) {
                const thrown_value = ctx.takeException();
                thrown_value.free(ctx.runtime);
                return core.JSValue.nullValue();
            }
            if (ctx.hasException()) ctx.clearException();
            if (exception_ops.runtimeErrorInfo(err) != null) return core.JSValue.nullValue();
            return err;
        };
    }
    return formatCapturedErrorStackStringValue(ctx, sites_value, site_count);
}

/// Throw the compile-error SyntaxError for a parse failure, mirroring qjs's
/// parse-error surface: build_backtrace's filename branch (quickjs.c:7553-7570)
/// defines own fileName/lineNumber/columnNumber data properties
/// (JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE, non-enumerable) and prepends a
/// `    at <file>:<line>:<col>` line to the stack, which for compile errors is
/// built eagerly at throw time (JS_ThrowError2 -> build_backtrace with
/// filename != NULL). zjs stores the eagerly-built string via `setErrorStack`
/// so the lazy `stack` accessor returns it verbatim.
pub fn throwParseSyntaxError(
    ctx: *core.JSContext,
    global: *core.Object,
    filename: []const u8,
    line: u32,
    col: u32,
    message: []const u8,
) !core.JSValue {
    const rt = ctx.runtime;
    const line_num: i32 = std.math.cast(i32, line) orelse std.math.maxInt(i32);
    const col_num: i32 = std.math.cast(i32, col) orelse std.math.maxInt(i32);
    const error_value = try exception_ops.createNamedErrorWithoutStack(rt, global, "SyntaxError", message);
    // Ownership: on construction failure below free the value; once
    // `throwValue` has stored it the exception slot owns it (the final
    // `return error.SyntaxError` is the intended result, not a failure).
    defineParseErrorSurface(ctx, global, error_value, filename, line_num, col_num) catch |err| {
        error_value.free(rt);
        return err;
    };
    _ = ctx.throwValue(error_value);
    return error.SyntaxError;
}

fn defineParseErrorSurface(
    ctx: *core.JSContext,
    global: *core.Object,
    error_value: core.JSValue,
    filename: []const u8,
    line_num: i32,
    col_num: i32,
) !void {
    const rt = ctx.runtime;
    const instance = property_ops.expectObject(error_value) catch return;
    const filename_value = try value_ops.createStringValue(rt, filename);
    defer filename_value.free(rt);
    try defineDataPropertyByName(rt, instance, "fileName", filename_value, true, false, true);
    try defineDataPropertyByName(rt, instance, "lineNumber", core.JSValue.int32(line_num), true, false, true);
    try defineDataPropertyByName(rt, instance, "columnNumber", core.JSValue.int32(col_num), true, false, true);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(rt.memory.allocator);
    try bytes.print(rt.memory.allocator, "    at {s}:{d}:{d}\n", .{ filename, line_num, col_num });
    const frames_value = try buildErrorStackStringValue(ctx, global, null);
    defer frames_value.free(rt);
    try value_ops.appendRawString(rt, &bytes, frames_value);
    const stack_value = try value_ops.createStringValue(rt, bytes.items);
    defer stack_value.free(rt);
    try instance.setErrorStack(rt, stack_value);
}

pub fn errorPrepareStackTrace(rt: *core.JSRuntime, global: *core.Object) !?core.JSValue {
    const error_key = try rt.internAtom("Error");
    defer rt.atoms.free(error_key);
    const error_value = try global.getProperty(error_key);
    defer error_value.free(rt);
    const error_object = property_ops.expectObject(error_value) catch return null;
    const prepare_key = try rt.internAtom("prepareStackTrace");
    defer rt.atoms.free(prepare_key);
    const prepare = try error_object.getProperty(prepare_key);
    if (!isCallableValue(prepare)) {
        prepare.free(rt);
        return null;
    }
    return prepare;
}

pub fn backtraceFunctionNameEql(ctx: *core.JSContext, entry: core.BacktraceFrame, expected: []const u8) bool {
    return std.mem.eql(u8, callSiteFunctionName(ctx, entry), expected);
}

/// Display name for a backtrace frame. Mirrors qjs build_backtrace
/// (quickjs.c:7580-7586): an empty name renders "<anonymous>", a top-level
/// script/eval frame renders "<eval>". qjs gets the latter for free because
/// the compiler names every top-level function def JS_ATOM__eval_
/// (quickjs.c:37252); zjs's top-level bytecode instead carries name ==
/// filename (the name-equality is also its eval-frame detection convention,
/// e.g. vm_call.zig / eval_ops.zig), so the "<eval>" mapping is applied at
/// this rendering seam.
pub fn callSiteFunctionName(ctx: *core.JSContext, entry: core.BacktraceFrame) []const u8 {
    const name = ctx.runtime.atoms.name(entry.function_name) orelse "";
    const file = ctx.runtime.atoms.name(entry.filename) orelse "";
    if (name.len == 0) return "<anonymous>";
    if (std.mem.eql(u8, name, file)) return "<eval>";
    return name;
}

pub fn callSiteFunctionNameValue(ctx: *core.JSContext, entry: core.BacktraceFrame) !core.JSValue {
    const name = ctx.runtime.atoms.name(entry.function_name) orelse "";
    const file = ctx.runtime.atoms.name(entry.filename) orelse "";
    if (name.len == 0) return core.JSValue.nullValue();
    if (std.mem.eql(u8, name, file)) return value_ops.createStringValue(ctx.runtime, "<eval>");
    return value_ops.createStringValue(ctx.runtime, name);
}

pub fn errorStackTraceLimit(rt: *core.JSRuntime, global: *core.Object) usize {
    const error_key = rt.internAtom("Error") catch return 10;
    defer rt.atoms.free(error_key);
    const error_object = global.getOwnDataObjectBorrowed(error_key) orelse return 10;
    const limit_key = rt.internAtom("stackTraceLimit") catch return 10;
    defer rt.atoms.free(limit_key);
    const limit_value = error_object.getOwnDataPropertyValue(limit_key) orelse return 10;
    defer limit_value.free(rt);
    if (limit_value.isUndefined() or limit_value.isNull()) return 0;
    const number = value_ops.numberValue(limit_value) orelse return 10;
    if (!std.math.isFinite(number) or number <= 0) return 0;
    const truncated = @floor(number);
    if (truncated > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return std.math.maxInt(usize);
    return @intFromFloat(truncated);
}

pub fn appendBacktraceFunctionName(
    ctx: *core.JSContext,
    bytes: *std.ArrayList(u8),
    function_name: core.Atom,
    filename: core.Atom,
) !void {
    const name = ctx.runtime.atoms.name(function_name) orelse "";
    const file = ctx.runtime.atoms.name(filename) orelse "";
    if (name.len == 0) {
        try bytes.appendSlice(ctx.runtime.memory.allocator, "<anonymous>");
    } else if (std.mem.eql(u8, name, file)) {
        // Top-level script/eval frame (see callSiteFunctionName).
        try bytes.appendSlice(ctx.runtime.memory.allocator, "<eval>");
    } else {
        try bytes.appendSlice(ctx.runtime.memory.allocator, name);
    }
}

pub fn appendCallSiteFunctionName(rt: *core.JSRuntime, bytes: *std.ArrayList(u8), site: *core.Object) !void {
    const name_value = site.callSiteFunctionName() orelse {
        try bytes.appendSlice(rt.memory.allocator, "<anonymous>");
        return;
    };
    if (!name_value.isString()) {
        try bytes.appendSlice(rt.memory.allocator, "<anonymous>");
        return;
    }
    try value_ops.appendRawString(rt, bytes, name_value);
}

pub fn appendCallSiteFileName(rt: *core.JSRuntime, bytes: *std.ArrayList(u8), site: *core.Object) !void {
    const file_value = site.callSiteFile() orelse {
        try bytes.appendSlice(rt.memory.allocator, "<anonymous>");
        return;
    };
    if (!file_value.isString()) {
        try bytes.appendSlice(rt.memory.allocator, "<anonymous>");
        return;
    }
    try value_ops.appendRawString(rt, bytes, file_value);
}

pub fn errorStackGetter(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
) !core.JSValue {
    const object = object_ops.objectFromValue(this_value) orelse return error.TypeError;
    if (object.class_id != core.class.ids.error_) return core.JSValue.undefinedValue();
    if (object.errorStack()) |stack| return stack.dup();
    if (object.errorStackSites()) |sites| {
        const stack = try error_stack_ops.formatCapturedErrorStackValue(ctx, output, global, this_value, sites, object.errorStackSiteCount());
        errdefer stack.free(ctx.runtime);
        try object.setErrorStack(ctx.runtime, stack);
        return stack;
    }
    return error_stack_ops.buildErrorStackValue(ctx, output, global, this_value, null);
}

pub fn errorStackSetter(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const receiver = object_ops.objectFromValue(this_value) orelse return error.TypeError;
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (!value.isString()) return error.TypeError;

    if (ctx.nativeErrorPrototypeObject(.error_)) |error_proto| {
        if (object_ops.sameObjectIdentity(this_value, error_proto.value())) return error.TypeError;
    }

    const stack_key = try ctx.runtime.internAtom("stack");
    defer ctx.runtime.atoms.free(stack_key);
    const desc = try object_ops.proxyAwareOwnPropertyDescriptor(ctx, output, global, receiver, stack_key, caller_function, caller_frame);
    defer if (desc) |item| item.destroy(ctx.runtime);

    if (desc == null) {
        const create_desc = core.Descriptor.data(value, true, true, true);
        const ok = if (receiver.proxyTarget() != null)
            try object_ops.proxyDefineOwnProperty(ctx, output, global, receiver, stack_key, create_desc, caller_function, caller_frame)
        else blk: {
            receiver.defineOwnProperty(ctx.runtime, stack_key, create_desc) catch |err| switch (err) {
                error.ReadOnly, error.NotExtensible, error.IncompatibleDescriptor => break :blk false,
                error.InvalidLength => return error.RangeError,
                else => return err,
            };
            break :blk true;
        };
        if (!ok) return error.TypeError;
        return core.JSValue.undefinedValue();
    }

    const own_desc = desc.?;
    if (own_desc.kind == .accessor and object_ops.sameObjectIdentity(own_desc.setter, function_object.value()) and isErrorStackSetterValue(own_desc.setter)) {
        if (try object_ops.proxySetTrapForErrorStackSetter(ctx, output, global, this_value, receiver, stack_key, value, caller_function, caller_frame)) {
            return core.JSValue.undefinedValue();
        }
        try object_ops.defineErrorStackDataProperty(ctx, output, global, receiver, stack_key, core.Descriptor.data(value, true, true, true), caller_function, caller_frame);
        return core.JSValue.undefinedValue();
    }

    if (receiver.proxyTarget() != null) {
        const ok = try object_ops.proxySetValueProperty(ctx, output, global, this_value, receiver, stack_key, value, caller_function, caller_frame);
        if (!ok) return error.TypeError;
        return core.JSValue.undefinedValue();
    }

    switch (own_desc.kind) {
        .accessor => {
            if (own_desc.setter.isUndefined()) return error.TypeError;
            const result = try call_runtime.callValueOrBytecodeSyncInternalOutlined(ctx, output, global, this_value, own_desc.setter, &.{value}, caller_function, caller_frame);
            result.free(ctx.runtime);
            return core.JSValue.undefinedValue();
        },
        .data, .generic => {
            if (own_desc.kind == .data and own_desc.writable == false) return error.TypeError;
            try object_ops.defineErrorStackDataProperty(ctx, output, global, receiver, stack_key, core.Descriptor{ .kind = .data, .value = value, .value_present = true }, caller_function, caller_frame);
            return core.JSValue.undefinedValue();
        },
    }
}

pub fn isErrorStackSetterValue(value: core.JSValue) bool {
    const object = object_ops.objectFromValue(value) orelse return false;
    const native_ref = core.function.decodeNativeBuiltinId(object.nativeFunctionId()) orelse return false;
    return native_ref.domain == .error_object and native_ref.id == @intFromEnum(method_ids.error_object.PrototypeMethod.stack_setter);
}

pub fn errorCaptureStackTrace(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 1 or !args[0].isObject()) return exception_ops.throwTypeErrorMessage(ctx, global, "not an object");
    const target = try property_ops.expectObject(args[0]);
    const skip_name = if (args.len >= 2 and isCallableValue(args[1]))
        try exception_ops.functionNameBytes(ctx.runtime, args[1])
    else
        null;
    defer if (skip_name) |bytes| ctx.runtime.memory.allocator.free(bytes);
    const stack_value = try error_stack_ops.buildErrorStackValue(ctx, output, global, args[0], skip_name);
    defer stack_value.free(ctx.runtime);
    try object_ops.defineDataPropertyByName(ctx.runtime, target, "stack", stack_value, true, false, true);
    return core.JSValue.undefinedValue();
}
