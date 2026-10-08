//! Optional bundled host globals. Installation is explicit in each Realm.
const std = @import("std");
const zjs = @import("zjs");
const core = zjs.core;
const value_ops = zjs.exec.value_ops;
const uint8array_codec = zjs.exec.uint8array_codec;
const call_runtime = zjs.exec.call_runtime;
const exception_ops = zjs.exec.exception_ops;
const HostError = zjs.HostError;
const web = @import("web.zig");

fn hostResult(result: anytype) HostError!@typeInfo(@TypeOf(result)).error_union.payload {
    return result catch |err| return @errorCast(err);
}

fn descriptor(comptime name: []const u8, comptime length: u8, comptime f: anytype) core.property.AutoInit {
    const Adapter = struct {
        fn call(c: *zjs.Call) !zjs.Value {
            // Argument-free host functions omit the `args` parameter.
            if (comptime @typeInfo(@TypeOf(f)).@"fn".params.len == 2) return f(c.ctx.core, c.global());
            return f(c.ctx.core, c.global(), c.args());
        }
        const entry: core.NativeEntry = blk: {
            var e = zjs.native.managed(call).template;
            e.arity = length;
            break :blk e;
        };
        fn prepare(_: *core.JSRuntime, _: *const core.property.AutoInit, value: core.JSValue) !void {
            const object = try core.Object.expect(value);
            object.installNativeEntry(&entry);
        }
    };
    return .{ .name = name, .length = length, .prepare_native_function = Adapter.prepare };
}

const functions = [_]core.property.AutoInit{
    descriptor("btoa", 1, globalBtoa),
    descriptor("atob", 1, globalAtob),
    descriptor("queueMicrotask", 1, globalQueueMicrotask),
    descriptor("gc", 0, globalGc),
};

pub fn install(ctx: *core.JSContext, global: *core.Object) !void {
    try @import("output.zig").install(ctx, global);
    try web.install(ctx, global);
    for (&functions) |*info| {
        const key = try ctx.runtime.internAtom(info.name);
        var roots = core.runtime.rootAtoms(.{&key});
        roots.activate(ctx.runtime);
        defer roots.deactivate(ctx.runtime);
        try global.defineAutoInitPropertyFromDescriptor(ctx.runtime, key, core.property.Flags.data(.method), global, info);
    }
}

/// WebIDL `DOMString` argument 0: required, converted with ToString.
fn stringArgument(ctx: *core.JSContext, global: ?*core.Object, args: []const core.JSValue, comptime function_name: []const u8) !core.JSValue {
    const realm_global = global orelse try ctx.globalObject();
    if (args.len == 0) return exception_ops.throwTypeErrorMessage(ctx, realm_global, function_name ++ ": 1 argument required");
    // ToString can run user code (toString/valueOf), which prints through the
    // active invocation's host writer.
    const output = zjs.exec.builtin_dispatch.vmCallerView(ctx).output;
    return zjs.exec.string_ops.toStringForAnnexB(ctx, output, realm_global, args[0], null, null);
}

fn globalBtoa(ctx: *core.JSContext, global: ?*core.Object, args: []const core.JSValue) !core.JSValue {
    const string_value = try stringArgument(ctx, global, args, "btoa");
    var bytes = stringToLatin1Bytes(ctx.runtime, string_value, 0xff) catch |err| switch (err) {
        error.InvalidCharacter => return throwInvalidCharacter(ctx, global, "String contains an invalid character"),
        else => |other| return other,
    };
    defer bytes.deinit(ctx.runtime.nativeAllocator());
    var encoded = try hostResult(uint8array_codec.encodeBase64Bytes(ctx.runtime, bytes.items, .base64, false));
    defer encoded.deinit(ctx.runtime.nativeAllocator());
    return value_ops.createStringValue(ctx.runtime, encoded.items);
}

fn globalAtob(ctx: *core.JSContext, global: ?*core.Object, args: []const core.JSValue) !core.JSValue {
    const string_value = try stringArgument(ctx, global, args, "atob");
    var bytes = stringToLatin1Bytes(ctx.runtime, string_value, 0x7f) catch |err| switch (err) {
        error.InvalidCharacter => return throwInvalidCharacter(ctx, global, "The string to be decoded is not correctly encoded"),
        else => |other| return other,
    };
    defer bytes.deinit(ctx.runtime.nativeAllocator());
    var decoded = uint8array_codec.decodeBase64Bytes(ctx.runtime, bytes.items, .base64, .loose) catch |err| switch (err) {
        error.SyntaxError => return throwInvalidCharacter(ctx, global, "The string to be decoded is not correctly encoded"),
        else => |other| return other,
    };
    defer decoded.deinit(ctx.runtime.nativeAllocator());
    const string = try core.string.String.createAscii(ctx.runtime, decoded.items);
    return string.value();
}

const Latin1StringError = error{ InvalidCharacter, TypeError } || std.mem.Allocator.Error;

fn stringToLatin1Bytes(rt: *core.JSRuntime, value: core.JSValue, max_unit: u16) Latin1StringError!std.ArrayList(u8) {
    if (!value.isString()) return error.TypeError;
    var borrow = core.runtime.NoGcScope{};
    borrow.activate(rt);
    defer borrow.deactivate();
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(rt.nativeAllocator());
    var iterator = core.string.StringValueIterator.init(value);
    while (iterator.next()) |chunk| switch (chunk) {
        .latin1 => |bytes| {
            for (bytes) |byte| {
                if (byte > max_unit) return error.InvalidCharacter;
            }
            try out.appendSlice(rt.nativeAllocator(), bytes);
        },
        .utf16 => |units| {
            try out.ensureUnusedCapacity(rt.nativeAllocator(), units.len);
            for (units) |unit| {
                if (unit > max_unit) return error.InvalidCharacter;
                out.appendAssumeCapacity(@intCast(unit));
            }
        },
    };
    return out;
}

fn throwInvalidCharacter(ctx: *core.JSContext, global: ?*core.Object, message: []const u8) !core.JSValue {
    const error_global = global orelse ctx.global orelse return error.TypeError;
    try hostResult(web.throwDOMException(ctx, error_global, "InvalidCharacterError", message));
    return error.InvalidCharacterError;
}

fn globalQueueMicrotask(ctx: *core.JSContext, global: ?*core.Object, args: []const core.JSValue) !core.JSValue {
    const active_global = global orelse ctx.global orelse return error.TypeError;
    const callback = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (!call_runtime.isCallableValue(callback)) return try hostResult(exception_ops.throwTypeErrorMessage(ctx, active_global, "not a function"));
    try hostResult(call_runtime.enqueuePendingMicrotask(ctx, callback));
    return core.JSValue.undefinedValue();
}

fn globalGc(ctx: *core.JSContext, global: ?*core.Object) HostError!core.JSValue {
    _ = ctx.runtime.collectFull(null, .engine_active) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PayloadMarkFailed => return try hostResult(exception_ops.throwInternalErrorMessage(ctx, global orelse ctx.global orelse return error.InvalidBuiltinRegistry, "GC payload marking failed")),
    };
    return core.JSValue.undefinedValue();
}
