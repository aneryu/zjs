const core = @import("../core/root.zig");
const JSValue = @import("../core/value.zig").JSValue;
const std = @import("std");
const call = @import("../exec/call.zig");
const exceptions = @import("../exec/exceptions.zig");
const string_ops = @import("../exec/string_ops.zig");

const HostError = exceptions.HostError;
const InternalCall = core.host_function.InternalCall;

pub const BuiltinFunction = struct {
    name: []const u8,
    length: u16,
};

pub const PrototypeMethod = enum(u32) {
    to_string = 1,
    bind = 2,
};

/// Declaration + dispatch table for the `.function` native-builtin domain
/// (QuickJS js_function_proto_funcs analogue). One shared record handler
/// `functionCall` switches on the per-record `magic` (== domain-local id) for
/// `Function.prototype.toString` and `Function.prototype.bind`. The
/// implementations stay in exec: `toString` reuses `string_ops`, and `bind`
/// reuses call.zig's `createBoundFunction` (and its proxy-aware property
/// helpers), both also reached by the VM's bind/toString fast path
/// (call_runtime.callNativeBuiltinRecordForVm) — so these are thin delegating
/// entries (BOTH). Property installation still binds the canonical
/// name/length through the registry (`installFunctionPrototypeExtras`); this
/// table is consumed by the slow record-dispatch path (`rt.internal_builtins`).
/// Neither method is callable without a materialized function object, so
/// `prepared_call_ok` stays false.
pub const internal_entries = [_]core.host_function.InternalEntry{
    functionEntry("toString", 0, @intFromEnum(PrototypeMethod.to_string)),
    functionEntry("bind", 1, @intFromEnum(PrototypeMethod.bind)),
};

fn functionEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{ .name = name, .length = length, .id = id, .magic = @intCast(id), .prepared_call_ok = false, .call = &functionCall };
}

/// Shared record handler for the `.function` domain. Mirrors the retired
/// `call.zig` `callFunctionNativeFunctionRecord`: `toString` returns the
/// function's source text, `bind` builds a bound-function exotic. Both
/// delegate to exec ops shared with the VM fast path.
fn functionCall(host_call: InternalCall) HostError!core.JSValue {
    const ctx = host_call.ctx;
    const id: u32 = host_call.magic;
    return switch (id) {
        @intFromEnum(PrototypeMethod.to_string) => string_ops.qjsFunctionToStringCall(ctx, host_call.this_value),
        @intFromEnum(PrototypeMethod.bind) => call.qjsFunctionBindCall(ctx, host_call.output, host_call.global, host_call.globals, host_call.this_value, host_call.args),
        else => error.TypeError,
    };
}

pub fn applyReturnThis(this_value: JSValue) JSValue {
    return this_value.dup();
}

/// Returns true when `bytes` is plain ASCII (every code unit < 0x80).
/// Used by `nativeFunction` to take a memcpy-only string path for
/// builtin / host-helper names without paying the two-pass UTF-8
/// scan that `createUtf8` performs. Hot during builtins install but
/// also cheap for arbitrary inputs (single linear pass, vectorisable).
pub const nativeFunction = core.function.nativeFunction;

pub fn sourceFunction(rt: *core.JSRuntime, name: []const u8, source: []const u8) !core.JSValue {
    const function_object = try core.Object.create(rt, core.class.ids.c_function, null);
    var function_value = function_object.value();
    var source_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &function_value },
        .{ .value = &source_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    errdefer {
        const failed_function = function_value;
        function_value = core.JSValue.undefinedValue();
        failed_function.free(rt);
    }

    try defineFunctionName(rt, function_object, name);
    const source_string = try core.string.String.createUtf8(rt, source);
    source_value = source_string.value();
    try function_object.setOptionalValueSlot(rt, function_object.functionSourceSlot(), source_value.dup());
    source_value.free(rt);
    source_value = core.JSValue.undefinedValue();

    return function_value;
}

pub fn defineNativeMethod(rt: *core.JSRuntime, target: *core.Object, name: []const u8, length: i32) !void {
    const method = try nativeFunction(rt, name, length);
    defer method.free(rt);
    try defineData(rt, target, name, method, true, false, true);
}

fn defineData(
    rt: *core.JSRuntime,
    target: *core.Object,
    name: []const u8,
    value: core.JSValue,
    writable: bool,
    enumerable: bool,
    configurable: bool,
) !void {
    var target_value = target.value();
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &target_value },
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try target.defineOwnProperty(rt, key, core.Descriptor.data(rooted_value, writable, enumerable, configurable));
}

fn defineFunctionName(rt: *core.JSRuntime, function_object: *core.Object, name: []const u8) !void {
    const name_string = try core.string.String.createUtf8(rt, name);
    const name_value = name_string.value();
    defer name_value.free(rt);
    try defineData(rt, function_object, "name", name_value, false, false, true);
}

test "sourceFunction roots function and source while attaching source text" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const function_value = try sourceFunction(rt, "namedSource", "function namedSource() { return 1; }");
    defer function_value.free(rt);
    const function_object = try expectObject(function_value);
    const source_value = function_object.functionSource() orelse return error.TypeError;
    const source_string = try expectString(source_value);
    try std.testing.expect(source_string.eqlBytes("function namedSource() { return 1; }"));
}

fn expectObject(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}

fn expectString(value: core.JSValue) !*core.string.String {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isString()) return error.TypeError;
    return @fieldParentPtr("header", header);
}
