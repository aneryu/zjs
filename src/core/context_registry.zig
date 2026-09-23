//! Borrowed indexes of constructing and published realms.
//!
//! The two lists stay on `JSRuntime`. A link is not a keep-alive: `RealmRef`
//! is what retains a realm across prototype-slot growth. Constructing realms
//! stay off the live list until `publishLive` succeeds, so a failed publish
//! leaves neither a live member nor a new root provider.

const std = @import("std");
const class = @import("class.zig");
const context_mod = @import("context.zig");
const gc = @import("gc.zig");
const object_mod = @import("object.zig");
const shape = @import("shape.zig");
const JSRuntime = @import("../runtime.zig").JSRuntime;
const Object = object_mod.Object;
const JSContext = context_mod.JSContext;

pub fn linkLive(rt: *JSRuntime, ctx: *JSContext) void {
    rt.assertOwnerThread();
    std.debug.assert(ctx.runtime == rt);
    std.debug.assert(ctx.runtime_prev == null and ctx.runtime_next == null);
    ctx.runtime_prev = rt.context_tail;
    if (rt.context_tail) |tail| {
        tail.runtime_next = ctx;
    } else {
        rt.context_head = ctx;
    }
    rt.context_tail = ctx;
}

pub fn linkConstructing(rt: *JSRuntime, ctx: *JSContext) void {
    rt.assertOwnerThread();
    std.debug.assert(ctx.runtime == rt);
    std.debug.assert(ctx.construction_prev == null and ctx.construction_next == null);
    ctx.construction_prev = rt.constructing_context_tail;
    if (rt.constructing_context_tail) |tail| {
        tail.construction_next = ctx;
    } else {
        rt.constructing_context_head = ctx;
    }
    rt.constructing_context_tail = ctx;
}

pub fn unlinkConstructing(rt: *JSRuntime, ctx: *JSContext) void {
    rt.assertOwnerThread();
    if (ctx.construction_prev == null and ctx.construction_next == null and rt.constructing_context_head != ctx) return;
    if (ctx.construction_prev) |prev| {
        prev.construction_next = ctx.construction_next;
    } else {
        std.debug.assert(rt.constructing_context_head == ctx);
        rt.constructing_context_head = ctx.construction_next;
    }
    if (ctx.construction_next) |next| {
        next.construction_prev = ctx.construction_prev;
    } else {
        std.debug.assert(rt.constructing_context_tail == ctx);
        rt.constructing_context_tail = ctx.construction_prev;
    }
    ctx.construction_prev = null;
    ctx.construction_next = null;
}

pub fn unlinkLive(rt: *JSRuntime, ctx: *JSContext) void {
    rt.assertOwnerThread();
    if (ctx.runtime_prev == null and ctx.runtime_next == null and rt.context_head != ctx) return;
    if (ctx.runtime_prev) |prev| {
        prev.runtime_next = ctx.runtime_next;
    } else {
        std.debug.assert(rt.context_head == ctx);
        rt.context_head = ctx.runtime_next;
    }
    if (ctx.runtime_next) |next| {
        next.runtime_prev = ctx.runtime_prev;
    } else {
        std.debug.assert(rt.context_tail == ctx);
        rt.context_tail = ctx.runtime_prev;
    }
    ctx.runtime_prev = null;
    ctx.runtime_next = null;
}

pub fn firstLive(rt: *const JSRuntime) ?*JSContext {
    return rt.context_head;
}

pub fn assertNoHostRealmRefs(rt: *JSRuntime) void {
    if (comptime !std.debug.runtime_safety) return;
    var current = rt.context_head;
    while (current) |ctx| : (current = ctx.runtime_next) {
        std.debug.assert(ctx.host_api_release_consumed);
    }
    var constructing = rt.constructing_context_head;
    while (constructing) |ctx| : (constructing = ctx.construction_next) {
        std.debug.assert(ctx.host_api_release_consumed);
    }
}

pub fn liveForGlobal(rt: *const JSRuntime, global: *const Object) ?*JSContext {
    var current = rt.context_head;
    while (current) |ctx| : (current = ctx.runtime_next) {
        if (ctx.global == global) return ctx;
    }
    return null;
}

pub fn anyForGlobal(rt: *const JSRuntime, global: *const Object) ?*JSContext {
    if (liveForGlobal(rt, global)) |ctx| return ctx;
    var current = rt.constructing_context_head;
    while (current) |ctx| : (current = ctx.construction_next) {
        if (ctx.global == global) return ctx;
    }
    return null;
}

pub fn invalidateStandardArrayPrototype(rt: *JSRuntime, object_prototype: *Object) void {
    rt.assertOwnerThread();
    var live = rt.context_head;
    while (live) |ctx| : (live = ctx.runtime_next) {
        invalidateOneStandardArrayPrototype(ctx, object_prototype);
    }
    var constructing = rt.constructing_context_head;
    while (constructing) |ctx| : (constructing = ctx.construction_next) {
        invalidateOneStandardArrayPrototype(ctx, object_prototype);
    }
}

fn invalidateOneStandardArrayPrototype(ctx: *JSContext, object_prototype: *Object) void {
    const object_value = ctx.cached_values[@intFromEnum(object_mod.RealmValueSlot.object_prototype)] orelse return;
    const realm_object_prototype = Object.expect(object_value) catch unreachable;
    if (realm_object_prototype != object_prototype) return;
    const array_value = ctx.cached_values[@intFromEnum(object_mod.RealmValueSlot.array_prototype)] orelse return;
    const array_prototype = Object.expect(array_value) catch unreachable;
    array_prototype.flags.is_std_array_prototype = false;
}

pub fn initialArrayShape(rt: *const JSRuntime, prototype: ?*const Object) ?*shape.Shape {
    var current = rt.context_head;
    while (current) |ctx| : (current = ctx.runtime_next) {
        const initial = ctx.array_shape orelse continue;
        if (initial.proto == prototype) return initial;
    }
    var constructing = rt.constructing_context_head;
    while (constructing) |ctx| : (constructing = ctx.construction_next) {
        const initial = ctx.array_shape orelse continue;
        if (initial.proto == prototype) return initial;
    }
    return null;
}

pub fn ensureClassPrototypeCapacity(rt: *JSRuntime, class_id: class.ClassId) !void {
    try rt.requireOwnerThread();
    var current_owner = if (rt.context_head) |head| context_mod.RealmRef.retain(head) else context_mod.RealmRef{};
    defer current_owner.deinit();
    while (current_owner.borrow()) |ctx| {
        var next_owner = if (ctx.runtime_next) |next| context_mod.RealmRef.retain(next) else context_mod.RealmRef{};
        errdefer next_owner.deinit();
        _ = try ctx.ensureClassPrototypeSlot(class_id);
        current_owner.deinit();
        current_owner = next_owner;
        next_owner = .{};
    }

    var constructing_owner = if (rt.constructing_context_head) |head| context_mod.RealmRef.retain(head) else context_mod.RealmRef{};
    defer constructing_owner.deinit();
    while (constructing_owner.borrow()) |ctx| {
        var next_owner = if (ctx.construction_next) |next| context_mod.RealmRef.retain(next) else context_mod.RealmRef{};
        errdefer next_owner.deinit();
        _ = try ctx.ensureClassPrototypeSlot(class_id);
        constructing_owner.deinit();
        constructing_owner = next_owner;
        next_owner = .{};
    }
}

const ClassPrototypeContextList = enum {
    live,
    constructing,
};

fn nextRetainable(rt: *JSRuntime, start: ?*JSContext, comptime list: ClassPrototypeContextList) context_mod.RealmRef {
    var cursor = start;
    while (cursor) |ctx| {
        const next = switch (list) {
            .live => ctx.runtime_next,
            .constructing => ctx.construction_next,
        };
        if (rt.gc.hot.phase != .tracer_destroy or
            !gc.headerCondemned(&ctx.header))
        {
            return context_mod.RealmRef.retain(ctx);
        }
        cursor = next;
    }
    return .{};
}

pub fn clearClassPrototype(rt: *JSRuntime, class_id: class.ClassId) void {
    rt.assertOwnerThread();
    var current_owner = nextRetainable(rt, rt.context_head, .live);
    defer current_owner.deinit();
    while (current_owner.borrow()) |ctx| {
        var next_owner = nextRetainable(rt, ctx.runtime_next, .live);
        ctx.clearClassPrototype(class_id);
        current_owner.deinit();
        current_owner = next_owner;
        next_owner = .{};
    }

    var constructing_owner = nextRetainable(rt, rt.constructing_context_head, .constructing);
    defer constructing_owner.deinit();
    while (constructing_owner.borrow()) |ctx| {
        var next_owner = nextRetainable(rt, ctx.construction_next, .constructing);
        ctx.clearClassPrototype(class_id);
        constructing_owner.deinit();
        constructing_owner = next_owner;
        next_owner = .{};
    }
}
