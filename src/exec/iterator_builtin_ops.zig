const std = @import("std");
const core = @import("../core/root.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call_runtime = @import("call_runtime.zig");
const exceptions = @import("exceptions.zig");
const object_ops = @import("object_ops.zig");

const HostError = exceptions.HostError;
const InternalCall = core.host_function.InternalCall;

pub const Result = struct {
    value_index: usize,
    done: bool,
};

pub const AccessorMethod = core.host_function.builtin_method_ids.iterator.AccessorMethod;
pub const StaticMethod = core.host_function.builtin_method_ids.iterator.StaticMethod;
pub const PrototypeMethod = core.host_function.builtin_method_ids.iterator.PrototypeMethod;
pub const IntrinsicMethod = core.host_function.builtin_method_ids.iterator.IntrinsicMethod;

pub fn staticMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "from")) return @intFromEnum(StaticMethod.from);
    if (std.mem.eql(u8, name, "concat")) return @intFromEnum(StaticMethod.concat);
    if (std.mem.eql(u8, name, "zip")) return @intFromEnum(StaticMethod.zip);
    if (std.mem.eql(u8, name, "zipKeyed")) return @intFromEnum(StaticMethod.zip_keyed);
    return null;
}

pub fn prototypeMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "toArray")) return @intFromEnum(PrototypeMethod.to_array);
    if (std.mem.eql(u8, name, "every")) return @intFromEnum(PrototypeMethod.every);
    if (std.mem.eql(u8, name, "find")) return @intFromEnum(PrototypeMethod.find);
    if (std.mem.eql(u8, name, "forEach")) return @intFromEnum(PrototypeMethod.for_each);
    if (std.mem.eql(u8, name, "reduce")) return @intFromEnum(PrototypeMethod.reduce);
    if (std.mem.eql(u8, name, "some")) return @intFromEnum(PrototypeMethod.some);
    if (std.mem.eql(u8, name, "map")) return @intFromEnum(PrototypeMethod.map);
    if (std.mem.eql(u8, name, "filter")) return @intFromEnum(PrototypeMethod.filter);
    if (std.mem.eql(u8, name, "take")) return @intFromEnum(PrototypeMethod.take);
    if (std.mem.eql(u8, name, "drop")) return @intFromEnum(PrototypeMethod.drop);
    if (std.mem.eql(u8, name, "flatMap")) return @intFromEnum(PrototypeMethod.flat_map);
    return null;
}

pub fn next(index: *usize, length: usize) Result {
    if (index.* >= length) return .{ .value_index = index.*, .done = true };
    const current = index.*;
    index.* += 1;
    return .{ .value_index = current, .done = false };
}

/// Declaration + dispatch table for the `.iterator` native-builtin domain
/// (QuickJS js_iterator_proto_funcs / js_iterator_funcs analogue). One shared
/// record handler `iteratorCall` switches on the per-record `magic`
/// (== domain-local id) and forwards to the iterator-helper VM ops, which stay
/// in exec because they interleave with the iterator protocol (next/close) and
/// the static helpers reach the for-of machinery. Property installation still
/// resolves names through the registry's `iterator_static`/`iterator_prototype`
/// method tables plus the accessor/dispose enum ids; this table is consumed by
/// the slow record-dispatch path (`rt.internal_builtins`). None of these
/// records are prepared-call eligible (the prepared gate in
/// `vm_call.zig` reports `.iterator => false`).
pub const internal_entries = iteratorEntries: {
    const Entry = core.host_function.InternalEntry;
    break :iteratorEntries [_]Entry{
        iteratorEntry("get constructor", 0, @intFromEnum(AccessorMethod.constructor_getter)),
        iteratorEntry("set constructor", 1, @intFromEnum(AccessorMethod.constructor_setter)),
        iteratorEntry("get [Symbol.toStringTag]", 0, @intFromEnum(AccessorMethod.to_string_tag_getter)),
        iteratorEntry("set [Symbol.toStringTag]", 1, @intFromEnum(AccessorMethod.to_string_tag_setter)),
        iteratorEntry("from", 1, @intFromEnum(StaticMethod.from)),
        iteratorEntry("concat", 0, @intFromEnum(StaticMethod.concat)),
        iteratorEntry("zip", 1, @intFromEnum(StaticMethod.zip)),
        iteratorEntry("zipKeyed", 1, @intFromEnum(StaticMethod.zip_keyed)),
        iteratorEntry("toArray", 0, @intFromEnum(PrototypeMethod.to_array)),
        iteratorEntry("every", 1, @intFromEnum(PrototypeMethod.every)),
        iteratorEntry("find", 1, @intFromEnum(PrototypeMethod.find)),
        iteratorEntry("forEach", 1, @intFromEnum(PrototypeMethod.for_each)),
        iteratorEntry("reduce", 1, @intFromEnum(PrototypeMethod.reduce)),
        iteratorEntry("some", 1, @intFromEnum(PrototypeMethod.some)),
        iteratorEntry("map", 1, @intFromEnum(PrototypeMethod.map)),
        iteratorEntry("filter", 1, @intFromEnum(PrototypeMethod.filter)),
        iteratorEntry("take", 1, @intFromEnum(PrototypeMethod.take)),
        iteratorEntry("drop", 1, @intFromEnum(PrototypeMethod.drop)),
        iteratorEntry("flatMap", 1, @intFromEnum(PrototypeMethod.flat_map)),
        iteratorEntry("[Symbol.dispose]", 0, @intFromEnum(PrototypeMethod.dispose)),
        iteratorEntry("Array Iterator.next", 0, @intFromEnum(IntrinsicMethod.array_iterator_next)),
        iteratorEntry("Generator.next", 1, @intFromEnum(IntrinsicMethod.generator_next)),
        iteratorEntry("Generator.return", 1, @intFromEnum(IntrinsicMethod.generator_return)),
        iteratorEntry("Generator.throw", 1, @intFromEnum(IntrinsicMethod.generator_throw)),
    };
};

fn iteratorEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{ .name = name, .length = length, .id = id, .magic = @intCast(id), .prepared_call_ok = false, .call = &iteratorCall };
}

/// Shared record handler for the `.iterator` domain. Mirrors the retired
/// `call.zig` `callIteratorNativeFunctionRecord`: it resolves the active realm
/// global and forwards to `call_runtime.qjsIteratorCallForNativeRecord`, which
/// dispatches the accessors, static helpers, and prototype helper methods. A
/// null result means the id resolved to no handler, which only happens for a
/// corrupt id, so it surfaces as a TypeError.
fn iteratorCall(host_call: InternalCall) HostError!core.JSValue {
    const ctx = host_call.ctx;
    const id: u32 = host_call.magic;
    const active_global = host_call.global orelse object_ops.objectRealmGlobal(host_call.func_obj orelse return error.TypeError) orelse ctx.global orelse return error.TypeError;
    const caller_function = builtin_dispatch.callerBytecode(host_call);
    const caller_frame = builtin_dispatch.callerFrame(host_call);
    if (try call_runtime.qjsIteratorCallForNativeRecord(ctx, host_call.output, active_global, host_call.this_value, id, host_call.args, caller_function, caller_frame)) |value| return value;
    return error.TypeError;
}

test "intrinsic iterator next methods have dedicated native records" {
    const testing = std.testing;
    const expected_ids = [_]u32{
        @intFromEnum(IntrinsicMethod.array_iterator_next),
        @intFromEnum(IntrinsicMethod.generator_next),
        @intFromEnum(IntrinsicMethod.generator_return),
        @intFromEnum(IntrinsicMethod.generator_throw),
    };
    for (expected_ids) |expected_id| {
        var handler: ?core.host_function.InternalCallFn = null;
        for (internal_entries) |entry| {
            if (entry.id == expected_id) handler = entry.call;
        }
        try testing.expect(handler != null);
        try testing.expect(handler.? == &iteratorCall);
    }
}
