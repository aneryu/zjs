const std = @import("std");

const builtins = @import("../../builtins/root.zig");
const core = @import("../../core/root.zig");
const property_ops = @import("../property_ops.zig");
const value_ops = @import("../value_ops.zig");

pub const ErrorInfo = struct { name: []const u8, message: []const u8 };

pub fn createNamedError(rt: *core.JSRuntime, global: *core.Object, name: []const u8, message: []const u8) !core.JSValue {
    const ctor_key = try rt.internAtom(name);
    defer rt.atoms.free(ctor_key);
    const ctor_value = global.getProperty(ctor_key);
    defer ctor_value.free(rt);
    return createNamedErrorWithConstructor(rt, ctor_value, name, message);
}

pub fn createNamedErrorWithConstructor(rt: *core.JSRuntime, ctor_value: core.JSValue, name: []const u8, message: []const u8) !core.JSValue {
    var rooted_ctor_value = ctor_value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_ctor_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const object = try core.Object.create(rt, core.class.ids.error_, null);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    const name_value = try value_ops.createStringValue(rt, name);
    defer name_value.free(rt);
    try defineValueProperty(rt, object, "name", name_value);
    const message_value = try value_ops.createStringValue(rt, message);
    defer message_value.free(rt);
    try defineValueProperty(rt, object, "message", message_value);
    if (!rooted_ctor_value.isUndefined()) {
        try defineValueProperty(rt, object, "constructor", rooted_ctor_value);
        if (rooted_ctor_value.isObject()) {
            const ctor = property_ops.expectObject(rooted_ctor_value) catch null;
            if (ctor) |ctor_object| {
                const proto_value = ctor_object.getProperty(core.atom.ids.prototype);
                defer proto_value.free(rt);
                if (proto_value.isObject()) {
                    const proto = property_ops.expectObject(proto_value) catch null;
                    if (proto) |prototype| try object.setPrototype(rt, prototype);
                }
            }
        }
    }
    return object.value();
}

test "createNamedErrorWithConstructor roots direct symbol constructor while creating error object" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-error-constructor-symbol");
    const ctor_value = core.JSValue.symbol(symbol_atom);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const error_value = try createNamedErrorWithConstructor(rt, ctor_value, "TypeError", "boom");
    var error_alive = true;
    defer if (error_alive) error_value.free(rt);
    const object = try property_ops.expectObject(error_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const constructor_key = try rt.internAtom("constructor");
    defer rt.atoms.free(constructor_key);
    const stored = object.getProperty(constructor_key);
    defer stored.free(rt);
    try std.testing.expect(stored.same(ctor_value));

    error_value.free(rt);
    error_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

/// Throw the canonical `ReferenceError` for a TDZ violation.
/// Returns `error.ReferenceError` to align with the legacy VM
/// convention (`exec/test262_helpers.raise(.reference)`).
pub fn throwTdzReference(ctx: *core.JSContext) error{ReferenceError} {
    const rt = ctx.runtime;

    const error_obj = core.Object.create(rt, core.class.ids.error_, null) catch {
        throwReferenceErrorSentinel(ctx);
        return error.ReferenceError;
    };
    defer error_obj.value().free(rt);

    const name_str = core.string.String.createUtf8(rt, "ReferenceError") catch {
        throwReferenceErrorSentinel(ctx);
        return error.ReferenceError;
    };
    defer core.JSValue.string(&name_str.header).free(rt);

    const name_atom = rt.internAtom("ReferenceError") catch {
        throwReferenceErrorSentinel(ctx);
        return error.ReferenceError;
    };
    defer rt.atoms.free(name_atom);

    const name_value = core.JSValue.string(&name_str.header);
    error_obj.defineOwnProperty(rt, name_atom, core.Descriptor.data(name_value, true, false, true)) catch {
        throwReferenceErrorSentinel(ctx);
        return error.ReferenceError;
    };

    const message_str = core.string.String.createUtf8(rt, "Cannot access 'x' before initialization") catch {
        throwReferenceErrorSentinel(ctx);
        return error.ReferenceError;
    };
    defer core.JSValue.string(&message_str.header).free(rt);

    const message_atom = rt.internAtom("message") catch {
        throwReferenceErrorSentinel(ctx);
        return error.ReferenceError;
    };
    defer rt.atoms.free(message_atom);

    const message_value = core.JSValue.string(&message_str.header);
    error_obj.defineOwnProperty(rt, message_atom, core.Descriptor.data(message_value, true, false, true)) catch {
        throwReferenceErrorSentinel(ctx);
        return error.ReferenceError;
    };

    _ = ctx.throwValue(error_obj.value().dup());
    return error.ReferenceError;
}

pub fn normalizeEvalRuntimeError(err: anytype) (@TypeOf(err) || error{TypeError}) {
    return switch (err) {
        error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => error.TypeError,
        else => err,
    };
}

pub fn runtimeErrorValueForGeneratorCatch(ctx: *core.JSContext, global: *core.Object, err: anytype) !core.JSValue {
    if (pendingExceptionMatchesError(ctx, err)) return ctx.takeException();
    const name = @errorName(err);
    const value = if (std.mem.eql(u8, name, "TypeError"))
        try createNamedError(ctx.runtime, global, "TypeError", "not a function")
    else if (std.mem.eql(u8, name, "RangeError"))
        try createNamedError(ctx.runtime, global, "RangeError", "")
    else if (std.mem.eql(u8, name, "ReferenceError"))
        try createNamedError(ctx.runtime, global, "ReferenceError", "not defined")
    else if (std.mem.eql(u8, name, "SyntaxError"))
        try createNamedError(ctx.runtime, global, "SyntaxError", "invalid syntax")
    else {
        if (ctx.hasException()) ctx.clearException();
        return err;
    };
    if (ctx.hasException()) ctx.clearException();
    return value;
}


pub fn qjsPromiseAggregateError(rt: *core.JSRuntime, global: *core.Object, errors: *core.Object) !core.JSValue {
    const aggregate_error = try createNamedError(rt, global, "AggregateError", "");
    errdefer aggregate_error.free(rt);
    const object = objectFromValue(aggregate_error) orelse return error.TypeError;
    try defineValueProperty(rt, object, "errors", errors.value());
    return aggregate_error;
}

pub fn qjsPromiseErrorValue(ctx: *core.JSContext, global: *core.Object, err: anytype) !core.JSValue {
    if (pendingExceptionMatchesError(ctx, err)) return ctx.takeException();
    const error_info = promiseErrorInfo(err);
    return createNamedError(ctx.runtime, global, error_info.name, error_info.message);
}

pub fn rejectedPromiseForRuntimeError(
    ctx: *core.JSContext,
    global: *core.Object,
    err: anytype,
    prototype: ?*core.Object,
) !core.JSValue {
    if (pendingExceptionMatchesError(ctx, err)) {
        const thrown_value = ctx.exception_slot.value;
        const promise = try builtins.promise.rejectedWithPrototype(ctx.runtime, thrown_value, prototype);
        ctx.clearException();
        return promise;
    }
    const error_info = runtimeErrorInfo(err) orelse return err;
    const error_value = try createNamedError(ctx.runtime, global, error_info.name, error_info.message);
    defer error_value.free(ctx.runtime);
    const promise = try builtins.promise.rejectedWithPrototype(ctx.runtime, error_value, prototype);
    if (ctx.hasException()) ctx.clearException();
    return promise;
}


pub fn isCallSiteObject(rt: *core.JSRuntime, object: *core.Object) bool {
    _ = rt;
    return object.isCallSite();
}

pub fn qjsCallSiteMethod(rt: *core.JSRuntime, object: *core.Object, name: []const u8) !?core.JSValue {
    if (!isCallSiteObject(rt, object)) return null;
    if (std.mem.eql(u8, name, "getFunction")) return core.JSValue.nullValue();
    if (std.mem.eql(u8, name, "getFunctionName")) return if (object.callSiteFunctionName()) |value| value.dup() else core.JSValue.nullValue();
    if (std.mem.eql(u8, name, "getFileName")) return if (object.callSiteFile()) |value| value.dup() else core.JSValue.nullValue();
    if (std.mem.eql(u8, name, "getLineNumber")) return core.JSValue.int32(object.callSiteLine());
    if (std.mem.eql(u8, name, "getColumnNumber")) return core.JSValue.int32(object.callSiteColumn());
    if (std.mem.eql(u8, name, "isNative")) return core.JSValue.boolean(false);
    return null;
}

pub fn isErrorConstructorName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Error") or
        std.mem.eql(u8, name, "AggregateError") or
        std.mem.eql(u8, name, "SuppressedError") or
        std.mem.eql(u8, name, "EvalError") or
        std.mem.eql(u8, name, "RangeError") or
        std.mem.eql(u8, name, "ReferenceError") or
        std.mem.eql(u8, name, "SyntaxError") or
        std.mem.eql(u8, name, "TypeError") or
        std.mem.eql(u8, name, "URIError") or
        std.mem.eql(u8, name, "Test262Error");
}

pub fn functionNameBytes(rt: *core.JSRuntime, value: core.JSValue) ![]u8 {
    const object = property_ops.expectObject(value) catch return rt.memory.allocator.dupe(u8, "");
    const name_value = object.getProperty(core.atom.ids.name);
    defer name_value.free(rt);
    if (!name_value.isString()) return rt.memory.allocator.dupe(u8, "");
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &bytes, name_value);
    return rt.memory.allocator.dupe(u8, bytes.items);
}

pub fn pendingExceptionMatchesError(ctx: *core.JSContext, err: anytype) bool {
    if (!ctx.hasException()) return false;
    if (std.mem.eql(u8, @errorName(err), "Test262Error")) return true;
    const expected = errorNameForRuntimeError(err) orelse return false;
    const object = objectFromValue(ctx.exception_slot.value) orelse return false;
    const name_value = object.getProperty(core.atom.ids.name);
    defer name_value.free(ctx.runtime);
    const header = name_value.refHeader() orelse return false;
    if (header.kind != .string) return false;
    const string: *core.string.String = @fieldParentPtr("header", header);
    switch (string.resolveData()) {
        .latin1 => |bytes| return std.mem.eql(u8, bytes, expected),
        .utf16 => |units| {
            if (units.len != expected.len) return false;
            for (units, expected) |unit, byte| {
                if (unit != byte) return false;
            }
            return true;
        },
    }
}

pub fn runtimeErrorInfo(err: anytype) ?ErrorInfo {
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "Test262Error")) return .{ .name = "Test262Error", .message = "" };
    if (std.mem.eql(u8, name, "URIError") or std.mem.eql(u8, name, "InvalidUtf8")) return .{ .name = "URIError", .message = "expecting hex digit" };
    if (std.mem.eql(u8, name, "TypeError") or std.mem.eql(u8, name, "NotExtensible")) return .{ .name = "TypeError", .message = "not a Date object" };
    if (std.mem.eql(u8, name, "InvalidCharacterError")) return .{ .name = "InvalidCharacterError", .message = "" };
    if (std.mem.eql(u8, name, "SyntaxError")) return .{ .name = "SyntaxError", .message = "invalid syntax" };
    if (std.mem.eql(u8, name, "RangeError")) return .{ .name = "RangeError", .message = "Date value is NaN" };
    if (std.mem.eql(u8, name, "ReferenceError")) return .{ .name = "ReferenceError", .message = "not defined" };
    return null;
}

pub fn promiseErrorInfo(err: anytype) ErrorInfo {
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "URIError") or std.mem.eql(u8, name, "InvalidUtf8")) return .{ .name = "URIError", .message = "expecting hex digit" };
    if (std.mem.eql(u8, name, "TypeError")) return .{ .name = "TypeError", .message = "not a Date object" };
    if (std.mem.eql(u8, name, "SyntaxError")) return .{ .name = "SyntaxError", .message = "invalid syntax" };
    if (std.mem.eql(u8, name, "RangeError")) return .{ .name = "RangeError", .message = "Date value is NaN" };
    if (std.mem.eql(u8, name, "ReferenceError")) return .{ .name = "ReferenceError", .message = "not defined" };
    return .{ .name = "Error", .message = "" };
}

fn errorNameForRuntimeError(err: anytype) ?[]const u8 {
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "Test262Error")) return "Test262Error";
    if (std.mem.eql(u8, name, "URIError") or std.mem.eql(u8, name, "InvalidUtf8")) return "URIError";
    if (std.mem.eql(u8, name, "TypeError")) return "TypeError";
    if (std.mem.eql(u8, name, "InvalidCharacterError")) return "InvalidCharacterError";
    if (std.mem.eql(u8, name, "SyntaxError")) return "SyntaxError";
    if (std.mem.eql(u8, name, "RangeError")) return "RangeError";
    if (std.mem.eql(u8, name, "ReferenceError")) return "ReferenceError";
    return null;
}

fn objectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn defineValueProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, true, true, true));
}

fn throwReferenceErrorSentinel(ctx: *core.JSContext) void {
    const reference_error_atom: u32 = 209;
    _ = ctx.throwValue(core.JSValue.int32(@intCast(reference_error_atom)));
}
