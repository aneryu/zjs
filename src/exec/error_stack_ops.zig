//! Error.stack capture/formatting, backtrace naming and CallSite helpers.

const std = @import("std");

const core = @import("../core/root.zig");
const exception_ops = @import("vm_exception_ops.zig");
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
const callValueOrBytecode = call_runtime.callValueOrBytecode;
const defineDataProperty = object_ops.defineDataProperty;
const formatCapturedErrorStackStringValue = string_ops.formatCapturedErrorStackStringValue;
const isCallableValue = call_runtime.isCallableValue;

pub fn defineErrorStack(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, instance: *core.Object) !void {
    const stack_value = try buildErrorStackValue(ctx, output, global, instance.value(), null);
    defer stack_value.free(ctx.runtime);
    try defineDataProperty(ctx.runtime, instance, "stack", stack_value, true, false, true);
}

pub fn captureErrorStack(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, instance: *core.Object) !void {
    _ = output;
    const sites = try buildCallSiteArray(ctx, global, null);
    defer sites.free(ctx.runtime);
    try instance.setErrorStackSites(ctx.runtime, sites);
}

/// Value-level stack capture: attach the current VM backtrace as call sites
/// to `value` when it is an object; non-object values are ignored. This is
/// the seam used by the `vm_exception_ops` construction primitives, which
/// capture the stack at error construction time (QuickJS `build_backtrace`
/// inside `JS_ThrowError2`).
pub fn attachStackToErrorValue(ctx: *core.JSContext, global: *core.Object, value: core.JSValue) !void {
    const object = property_ops.expectObject(value) catch return;
    try captureErrorStack(ctx, null, global, object);
}

pub fn buildErrorStackValue(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, error_value: core.JSValue, skip_name: ?[]const u8) !core.JSValue {
    if (ctx.formatting_error_stack) return buildErrorStackStringValue(ctx, global, skip_name);

    if (try errorPrepareStackTrace(ctx.runtime, global)) |prepare| {
        defer prepare.free(ctx.runtime);
        const sites = try buildCallSiteArray(ctx, global, skip_name);
        defer sites.free(ctx.runtime);
        ctx.formatting_error_stack = true;
        defer ctx.formatting_error_stack = false;
        return callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), prepare, &.{ error_value, sites }, null, null) catch |err| {
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
    if (ctx.formatting_error_stack) return formatCapturedErrorStackStringValue(ctx, sites_value, site_count);

    if (try errorPrepareStackTrace(ctx.runtime, global)) |prepare| {
        defer prepare.free(ctx.runtime);
        const sites_arg = sites_value.dup();
        defer sites_arg.free(ctx.runtime);
        ctx.formatting_error_stack = true;
        defer ctx.formatting_error_stack = false;
        return callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), prepare, &.{ error_value, sites_arg }, null, null) catch |err| {
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

pub fn errorPrepareStackTrace(rt: *core.JSRuntime, global: *core.Object) !?core.JSValue {
    const error_key = try rt.internAtom("Error");
    defer rt.atoms.free(error_key);
    const error_value = global.getProperty(error_key);
    defer error_value.free(rt);
    const error_object = property_ops.expectObject(error_value) catch return null;
    const prepare_key = try rt.internAtom("prepareStackTrace");
    defer rt.atoms.free(prepare_key);
    const prepare = error_object.getProperty(prepare_key);
    if (!isCallableValue(prepare)) {
        prepare.free(rt);
        return null;
    }
    return prepare;
}

pub fn backtraceFunctionNameEql(ctx: *core.JSContext, entry: core.BacktraceFrame, expected: []const u8) bool {
    return std.mem.eql(u8, callSiteFunctionName(ctx, entry), expected);
}

pub fn callSiteFunctionName(ctx: *core.JSContext, entry: core.BacktraceFrame) []const u8 {
    const name = ctx.runtime.atoms.name(entry.function_name) orelse "";
    const file = ctx.runtime.atoms.name(entry.filename) orelse "";
    if (name.len == 0 or std.mem.eql(u8, name, file)) return "<anonymous>";
    return name;
}

pub fn callSiteFunctionNameValue(ctx: *core.JSContext, entry: core.BacktraceFrame) !core.JSValue {
    const name = ctx.runtime.atoms.name(entry.function_name) orelse "";
    const file = ctx.runtime.atoms.name(entry.filename) orelse "";
    if (name.len == 0 or std.mem.eql(u8, name, file)) return core.JSValue.nullValue();
    return value_ops.createStringValue(ctx.runtime, name);
}

pub fn errorStackTraceLimit(rt: *core.JSRuntime, global: *core.Object) usize {
    const error_key = rt.internAtom("Error") catch return 10;
    defer rt.atoms.free(error_key);
    const error_value = global.getProperty(error_key);
    defer error_value.free(rt);
    const error_object = property_ops.expectObject(error_value) catch return 10;
    const limit_key = rt.internAtom("stackTraceLimit") catch return 10;
    defer rt.atoms.free(limit_key);
    const limit_value = error_object.getProperty(limit_key);
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
    if (name.len == 0 or std.mem.eql(u8, name, file)) {
        try bytes.appendSlice(ctx.runtime.memory.allocator, "<anonymous>");
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
