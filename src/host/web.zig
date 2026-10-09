//! Web-platform compatibility globals for the bundled programs: `navigator`,
//! `performance`, and `DOMException`. None of them is ECMAScript; an
//! engine-only Realm does not have them.
const std = @import("std");
const zjs = @import("zjs");
const clock_mod = @import("clock.zig");
const core = zjs.core;
const value_ops = zjs.exec.value_ops;
const object_ops = zjs.exec.object_ops;

/// QuickJS CLI reports `quickjs-ng/<version>`; kept equal to the QuickJS
/// reference used by the local fixtures.
pub const user_agent = "quickjs-ng/0.14.0";

pub const navigator_descriptor: core.property.AutoInit = .{
    .name = "navigator",
    .length = 0,
    .materialize_host = materializeNavigator,
};

pub const performance_descriptor: core.property.AutoInit = .{
    .name = "performance",
    .length = 0,
    .materialize_host = materializePerformance,
};

pub fn install(ctx: *core.JSContext, global: *core.Object) !void {
    const rt = ctx.runtime;
    try global.defineAutoInitPropertyFromDescriptor(rt, core.atom.predefinedId("performance", .string).?, core.property.Flags.data(.method), global, &performance_descriptor);
    try global.defineAutoInitPropertyFromDescriptor(rt, core.atom.predefinedId("navigator", .string).?, core.property.Flags.data(.{ .enumerable = true, .configurable = true }), global, &navigator_descriptor);
    try installDOMException(ctx, global);
}

fn realmOf(header: *core.gc.Header) *core.JSContext {
    return @alignCast(@fieldParentPtr("header", header));
}

/// The object held in an exact root slot. Re-read after every allocation:
/// a collection may move the object and update only the slot.
fn objectAt(value: core.JSValue) *core.Object {
    return core.Object.fromHeader(value.refHeader().?);
}

fn materializeNavigator(header: *core.gc.Header) zjs.RuntimeError!core.JSValue {
    const ctx = realmOf(header);
    const rt = ctx.runtime;
    // 0: Navigator prototype, 1: scratch (tag, getter), 2: navigator.
    var roots: core.runtime.ExactValueRoots(3) = .{};
    roots.activate(rt) catch |err| std.debug.panic("activate navigator roots: {s}", .{@errorName(err)});
    defer roots.deactivate();
    const slots = &roots.storage;

    const global = ctx.global orelse return error.InvalidBuiltinRegistry;
    slots[0] = (try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.object, object_ops.objectPrototypeFromGlobal(rt, global), 2)).value();
    slots[1] = try value_ops.createStringValue(rt, "Navigator");
    try objectAt(slots[0]).defineOwnPropertyAssumingNew(rt, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, core.Descriptor.data(slots[1], .{ .configurable = true }));
    var facade = zjs.borrowContext(ctx);
    // A collection after activation may move the realm global, so re-read it.
    slots[1] = facade.createFunction("get userAgent", zjs.native.managed(userAgent), .{ .length = 0, .realm_global = (ctx.global orelse return error.InvalidBuiltinRegistry).value() }) catch |err| return engineError(err);
    try objectAt(slots[0]).defineOwnPropertyAssumingNew(rt, core.atom.ids.userAgent, core.Descriptor.accessor(slots[1], core.JSValue.undefinedValue(), .{ .enumerable = true, .configurable = true }));
    slots[2] = (try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.object, objectAt(slots[0]), 0)).value();
    return slots[2];
}

fn userAgent(c: *zjs.Call) !zjs.Value {
    return value_ops.createStringValue(c.runtime(), user_agent);
}

/// Per-Realm HR-Time state: `performance.now()` is relative to the time the
/// Realm's `performance` object was first read, and `timeOrigin` is that
/// time in milliseconds since the Unix epoch.
const PerformanceClock = struct {
    allocator: std.mem.Allocator,
    origin_ms: f64,

    fn now(c: *zjs.Call) !zjs.Value {
        return core.JSValue.float64(monotonicMs() - c.state(PerformanceClock).origin_ms);
    }

    fn finalize(ptr: *anyopaque) void {
        const self: *PerformanceClock = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }
};

fn monotonicMs() f64 {
    return @as(f64, @floatFromInt(clock_mod.monotonicNanos())) / std.time.ns_per_ms;
}

fn materializePerformance(header: *core.gc.Header) zjs.RuntimeError!core.JSValue {
    const ctx = realmOf(header);
    const rt = ctx.runtime;
    // 0: performance, 1: now.
    var roots: core.runtime.ExactValueRoots(2) = .{};
    roots.activate(rt) catch |err| std.debug.panic("activate performance roots: {s}", .{@errorName(err)});
    defer roots.deactivate();
    const slots = &roots.storage;

    const global = ctx.global orelse return error.InvalidBuiltinRegistry;
    slots[0] = (try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.object, object_ops.objectPrototypeFromGlobal(rt, global), 2)).value();

    const allocator = rt.nativeAllocator();
    const clock = try allocator.create(PerformanceClock);
    clock.* = .{ .allocator = allocator, .origin_ms = monotonicMs() };
    // The finalizer registration owns `clock` from here on.
    rt.registerNativeEntryFinalizer(clock, PerformanceClock.finalize) catch |err| {
        allocator.destroy(clock);
        return err;
    };
    var facade = zjs.borrowContext(ctx);
    // A collection after activation may move the realm global, so re-read it.
    slots[1] = facade.createFunction("now", zjs.native.managed(PerformanceClock.now), .{ .length = 0, .state = clock, .realm_global = (ctx.global orelse return error.InvalidBuiltinRegistry).value() }) catch |err| return engineError(err);
    try objectAt(slots[0]).defineOwnPropertyAssumingNew(rt, core.atom.predefinedId("now", .string).?, core.Descriptor.data(slots[1], .method));
    const time_origin_ms = @as(f64, @floatFromInt(clock_mod.realNanos())) / std.time.ns_per_ms;
    try objectAt(slots[0]).defineOwnPropertyAssumingNew(rt, core.atom.predefinedId("timeOrigin", .string).?, core.Descriptor.data(core.JSValue.float64(time_origin_ms), .{ .enumerable = true, .configurable = true }));
    return slots[0];
}

// ----- DOMException (WebIDL) -----

const dom_exception_constants = [_]struct { name: []const u8, code: i32 }{
    .{ .name = "INDEX_SIZE_ERR", .code = 1 },
    .{ .name = "DOMSTRING_SIZE_ERR", .code = 2 },
    .{ .name = "HIERARCHY_REQUEST_ERR", .code = 3 },
    .{ .name = "WRONG_DOCUMENT_ERR", .code = 4 },
    .{ .name = "INVALID_CHARACTER_ERR", .code = 5 },
    .{ .name = "NO_DATA_ALLOWED_ERR", .code = 6 },
    .{ .name = "NO_MODIFICATION_ALLOWED_ERR", .code = 7 },
    .{ .name = "NOT_FOUND_ERR", .code = 8 },
    .{ .name = "NOT_SUPPORTED_ERR", .code = 9 },
    .{ .name = "INUSE_ATTRIBUTE_ERR", .code = 10 },
    .{ .name = "INVALID_STATE_ERR", .code = 11 },
    .{ .name = "SYNTAX_ERR", .code = 12 },
    .{ .name = "INVALID_MODIFICATION_ERR", .code = 13 },
    .{ .name = "NAMESPACE_ERR", .code = 14 },
    .{ .name = "INVALID_ACCESS_ERR", .code = 15 },
    .{ .name = "VALIDATION_ERR", .code = 16 },
    .{ .name = "TYPE_MISMATCH_ERR", .code = 17 },
    .{ .name = "SECURITY_ERR", .code = 18 },
    .{ .name = "NETWORK_ERR", .code = 19 },
    .{ .name = "ABORT_ERR", .code = 20 },
    .{ .name = "URL_MISMATCH_ERR", .code = 21 },
    .{ .name = "QUOTA_EXCEEDED_ERR", .code = 22 },
    .{ .name = "TIMEOUT_ERR", .code = 23 },
    .{ .name = "INVALID_NODE_TYPE_ERR", .code = 24 },
    .{ .name = "DATA_CLONE_ERR", .code = 25 },
};

/// Error name of each legacy code: entry `code - 1` names `code`; null marks
/// codes that have no current name.
const dom_exception_names = [_]?[]const u8{
    "IndexSizeError",           null,                  "HierarchyRequestError",      "WrongDocumentError",
    "InvalidCharacterError",    null,                  "NoModificationAllowedError", "NotFoundError",
    "NotSupportedError",        "InUseAttributeError", "InvalidStateError",          "SyntaxError",
    "InvalidModificationError", "NamespaceError",      "InvalidAccessError",         null,
    "TypeMismatchError",        "SecurityError",       "NetworkError",               "AbortError",
    "URLMismatchError",         "QuotaExceededError",  "TimeoutError",               "InvalidNodeTypeError",
    "DataCloneError",
};

fn installDOMException(ctx: *core.JSContext, global: *core.Object) !void {
    const rt = ctx.runtime;
    // 0: target global, 1: Error.prototype, 2: constructor, 3: prototype, 4: scratch.
    var roots: core.runtime.ExactValueRoots(5) = .{};
    try roots.activate(rt);
    defer roots.deactivate();
    const slots = &roots.storage;
    slots[0] = global.value();

    // The intrinsic %Error.prototype% of `global`'s own Realm, independent of
    // the mutable global `Error` binding.
    const realm = rt.contexts.forGlobal(global, .include_constructing) orelse return error.InvalidBuiltinRegistry;
    slots[1] = (realm.nativeErrorPrototypeObject(.error_) orelse return error.InvalidBuiltinRegistry).value();

    var facade = zjs.borrowContext(ctx);
    slots[2] = try facade.createFunction("DOMException", zjs.native.managed(construct), .{ .length = 0, .constructor = true, .realm_global = slots[0] });
    slots[3] = (try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.object, objectAt(slots[1]), 2 + dom_exception_constants.len)).value();
    try objectAt(slots[3]).defineOwnPropertyAssumingNew(rt, core.atom.ids.constructor, core.Descriptor.data(slots[2], .method));
    try objectAt(slots[2]).defineOwnPropertyAssumingNew(rt, core.atom.ids.prototype, core.Descriptor.data(slots[3], .none));
    slots[4] = try value_ops.createStringValue(rt, "DOMException");
    try objectAt(slots[3]).defineOwnPropertyAssumingNew(rt, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, core.Descriptor.data(slots[4], .{ .configurable = true }));
    try objectAt(slots[2]).reserveOwnPropertyCapacityAssumingPlain(rt, objectAt(slots[2]).shape_ref.prop_count + dom_exception_constants.len);
    for (dom_exception_constants) |constant| {
        const key = try rt.internAtom(constant.name);
        var key_roots = core.runtime.rootAtoms(.{&key});
        key_roots.activate(rt);
        defer key_roots.deactivate(rt);
        const value = core.JSValue.int32(constant.code);
        try objectAt(slots[2]).defineOwnPropertyAssumingNew(rt, key, core.Descriptor.data(value, .{ .enumerable = true }));
        try objectAt(slots[3]).defineOwnPropertyAssumingNew(rt, key, core.Descriptor.data(value, .{ .enumerable = true }));
    }
    try objectAt(slots[0]).defineOwnProperty(rt, core.atom.ids.DOMException, core.Descriptor.data(slots[2], .method));
}

/// `new DOMException(message = "", name = "Error")`. `this` is the instance
/// the construct path created from `new.target`; the result replaces it with
/// an Error-class object on the same prototype.
fn construct(c: *zjs.Call) !zjs.Value {
    const instance = try core.Object.expect(c.this);
    const prototype: core.JSValue = if (instance.getPrototype()) |object| object.value() else core.JSValue.nullValue();
    const global = c.global() orelse return error.InvalidBuiltinRegistry;
    // WebIDL converts `message` then `name` with ToString (user code may run,
    // and prints through the invocation's writer).
    const output = zjs.exec.builtin_dispatch.vmCallerView(c.ctx.core).output;
    const message = if (c.arg(0).is(.undefined_value)) c.arg(0) else try zjs.exec.string_ops.toStringForAnnexB(c.ctx.core, output, global, c.arg(0), null, null);
    const name = if (c.arg(1).is(.undefined_value)) c.arg(1) else try zjs.exec.string_ops.toStringForAnnexB(c.ctx.core, output, global, c.arg(1), null, null);
    return createDOMException(c.ctx.core, global, prototype, message, name);
}

/// Build a DOMException instance with the current stack, like an Error
/// constructed here. `prototype` is an object or null.
fn createDOMException(ctx: *core.JSContext, global: *core.Object, prototype: core.JSValue, message_arg: core.JSValue, name_arg: core.JSValue) !core.JSValue {
    const rt = ctx.runtime;
    // 0: prototype, 1: message, 2: name, 3: instance. Stored before the
    // first allocation.
    var roots: core.runtime.ExactValueRoots(4) = .{};
    try roots.activate(rt);
    defer roots.deactivate();
    const slots = &roots.storage;
    slots[0] = prototype;
    slots[1] = message_arg;
    slots[2] = name_arg;

    slots[1] = if (slots[1].is(.undefined_value)) try value_ops.createStringValue(rt, "") else try value_ops.toStringValue(rt, slots[1]);
    slots[2] = if (slots[2].is(.undefined_value)) try value_ops.createStringValue(rt, "Error") else try value_ops.toStringValue(rt, slots[2]);
    const code = try legacyCode(rt, slots[2]);
    const proto_object: ?*core.Object = if (slots[0].is(.object)) objectAt(slots[0]) else null;
    slots[3] = (try core.Object.create(rt, core.class.ids.error_, proto_object)).value();
    try objectAt(slots[3]).defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.data(slots[2], .method));
    try objectAt(slots[3]).defineOwnProperty(rt, core.atom.ids.message, core.Descriptor.data(slots[1], .method));
    try objectAt(slots[3]).defineOwnProperty(rt, core.atom.ids.code, core.Descriptor.data(core.JSValue.int32(code), .method));
    try zjs.exec.exception_ops.attachStackToErrorValue(ctx, global, slots[3]);
    return slots[3];
}

fn legacyCode(rt: *core.JSRuntime, name_value: core.JSValue) !i32 {
    var name = std.ArrayList(u8).empty;
    defer name.deinit(rt.nativeAllocator());
    try value_ops.appendRawString(rt, &name, name_value);
    for (dom_exception_names, 0..) |candidate, index| {
        const text = candidate orelse continue;
        if (std.mem.eql(u8, name.items, text)) return @intCast(index + 1);
    }
    return 0;
}

/// Throw `new DOMException(message, name)` in `global`'s Realm. When the
/// global `DOMException` (or its `prototype`) has been deleted or replaced by a
/// non-object, the instance falls back to the Realm's intrinsic
/// %Error.prototype% so it still prints and converts like an Error.
pub fn throwDOMException(ctx: *core.JSContext, global: *core.Object, name: []const u8, message: []const u8) !void {
    const rt = ctx.runtime;
    // 0: global, 1: prototype, 2: message, 3: name.
    var roots: core.runtime.ExactValueRoots(4) = .{};
    try roots.activate(rt);
    defer roots.deactivate();
    const slots = &roots.storage;
    slots[0] = global.value();

    slots[1] = try objectAt(slots[0]).getProperty(core.atom.ids.DOMException);
    if (slots[1].is(.object)) slots[1] = try objectAt(slots[1]).getProperty(core.atom.ids.prototype);
    if (!slots[1].is(.object)) {
        const realm = rt.contexts.forGlobal(objectAt(slots[0]), .include_constructing) orelse return error.InvalidBuiltinRegistry;
        slots[1] = (realm.nativeErrorPrototypeObject(.error_) orelse return error.InvalidBuiltinRegistry).value();
    }
    slots[2] = try value_ops.createStringValue(rt, message);
    slots[3] = try value_ops.createStringValue(rt, name);
    _ = ctx.throwValue(try createDOMException(ctx, objectAt(slots[0]), slots[1], slots[2], slots[3]));
}

/// Map a facade error into the engine's runtime error set.
fn engineError(err: anyerror) zjs.RuntimeError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidBuiltinRegistry,
    };
}
