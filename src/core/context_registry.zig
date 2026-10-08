//! Borrowed indexes of constructing and published realms (`JSRuntime.contexts`).
//!
//! A link is not a keep-alive: `RealmRef`
//! is what retains a realm across prototype-slot growth. Constructing realms
//! stay off the live list until `publishLive` succeeds, so a failed publish
//! leaves neither a live member nor a new root provider.

const std = @import("std");
const class = @import("class.zig");
const context_mod = @import("context.zig");
const object_mod = @import("object.zig");
const shape = @import("shape.zig");
const JSRuntime = @import("../runtime.zig").JSRuntime;
const Object = object_mod.Object;
const JSContext = context_mod.JSContext;

/// QuickJS `context_list`: intrusive membership only. Realm ownership is
/// carried by `RealmRef` and the GC header, never by these links.
pub const Lists = struct {
    /// Published realms, linked through `runtime_prev` / `runtime_next`.
    live_head: ?*JSContext = null,
    live_tail: ?*JSContext = null,
    /// Realms under construction, linked through `construction_prev` /
    /// `construction_next`. They are absent from the live list and
    /// root-provider traversal until publication.
    constructing_head: ?*JSContext = null,
    constructing_tail: ?*JSContext = null,
};

pub fn linkLive(rt: *JSRuntime, ctx: *JSContext) void {
    rt.assertOwnerThread();
    std.debug.assert(ctx.runtime == rt);
    std.debug.assert(ctx.runtime_prev == null and ctx.runtime_next == null);
    ctx.runtime_prev = rt.contexts.live_tail;
    if (rt.contexts.live_tail) |tail| {
        tail.runtime_next = ctx;
    } else {
        rt.contexts.live_head = ctx;
    }
    rt.contexts.live_tail = ctx;
}

pub fn linkConstructing(rt: *JSRuntime, ctx: *JSContext) void {
    rt.assertOwnerThread();
    std.debug.assert(ctx.runtime == rt);
    std.debug.assert(ctx.construction_prev == null and ctx.construction_next == null);
    ctx.construction_prev = rt.contexts.constructing_tail;
    if (rt.contexts.constructing_tail) |tail| {
        tail.construction_next = ctx;
    } else {
        rt.contexts.constructing_head = ctx;
    }
    rt.contexts.constructing_tail = ctx;
}

pub fn unlinkConstructing(rt: *JSRuntime, ctx: *JSContext) void {
    rt.assertOwnerThread();
    if (ctx.construction_prev == null and ctx.construction_next == null and rt.contexts.constructing_head != ctx) return;
    if (ctx.construction_prev) |prev| {
        prev.construction_next = ctx.construction_next;
    } else {
        std.debug.assert(rt.contexts.constructing_head == ctx);
        rt.contexts.constructing_head = ctx.construction_next;
    }
    if (ctx.construction_next) |next| {
        next.construction_prev = ctx.construction_prev;
    } else {
        std.debug.assert(rt.contexts.constructing_tail == ctx);
        rt.contexts.constructing_tail = ctx.construction_prev;
    }
    ctx.construction_prev = null;
    ctx.construction_next = null;
}

pub fn unlinkLive(rt: *JSRuntime, ctx: *JSContext) void {
    rt.assertOwnerThread();
    if (ctx.runtime_prev == null and ctx.runtime_next == null and rt.contexts.live_head != ctx) return;
    if (ctx.runtime_prev) |prev| {
        prev.runtime_next = ctx.runtime_next;
    } else {
        std.debug.assert(rt.contexts.live_head == ctx);
        rt.contexts.live_head = ctx.runtime_next;
    }
    if (ctx.runtime_next) |next| {
        next.runtime_prev = ctx.runtime_prev;
    } else {
        std.debug.assert(rt.contexts.live_tail == ctx);
        rt.contexts.live_tail = ctx.runtime_prev;
    }
    ctx.runtime_prev = null;
    ctx.runtime_next = null;
}

pub fn assertNoHostRealmRefs(rt: *JSRuntime) void {
    if (comptime !std.debug.runtime_safety) return;
    var current = rt.contexts.live_head;
    while (current) |ctx| : (current = ctx.runtime_next) {
        std.debug.assert(ctx.host_api_release_consumed);
    }
    var constructing = rt.contexts.constructing_head;
    while (constructing) |ctx| : (constructing = ctx.construction_next) {
        std.debug.assert(ctx.host_api_release_consumed);
    }
}

pub fn liveForGlobal(rt: *const JSRuntime, global: *const Object) ?*JSContext {
    var current = rt.contexts.live_head;
    while (current) |ctx| : (current = ctx.runtime_next) {
        if (ctx.global == global) return ctx;
    }
    return null;
}

pub fn anyForGlobal(rt: *const JSRuntime, global: *const Object) ?*JSContext {
    if (liveForGlobal(rt, global)) |ctx| return ctx;
    var current = rt.contexts.constructing_head;
    while (current) |ctx| : (current = ctx.construction_next) {
        if (ctx.global == global) return ctx;
    }
    return null;
}

pub fn invalidateStandardArrayPrototype(rt: *JSRuntime, object_prototype: *Object) void {
    rt.assertOwnerThread();
    var live = rt.contexts.live_head;
    while (live) |ctx| : (live = ctx.runtime_next) {
        invalidateOneStandardArrayPrototype(ctx, object_prototype);
    }
    var constructing = rt.contexts.constructing_head;
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
    var current = rt.contexts.live_head;
    while (current) |ctx| : (current = ctx.runtime_next) {
        const initial = ctx.array_shape orelse continue;
        if (initial.proto == prototype) return initial;
    }
    var constructing = rt.contexts.constructing_head;
    while (constructing) |ctx| : (constructing = ctx.construction_next) {
        const initial = ctx.array_shape orelse continue;
        if (initial.proto == prototype) return initial;
    }
    return null;
}

pub fn ensureClassPrototypeCapacity(rt: *JSRuntime, class_id: class.ClassId) !void {
    try rt.requireOwnerThread();
    var current_owner = if (rt.contexts.live_head) |head| context_mod.RealmRef.retain(head) else context_mod.RealmRef{};
    defer current_owner.deinit();
    while (current_owner.borrow()) |ctx| {
        var next_owner = if (ctx.runtime_next) |next| context_mod.RealmRef.retain(next) else context_mod.RealmRef{};
        errdefer next_owner.deinit();
        _ = try ctx.ensureClassPrototypeSlot(class_id);
        current_owner.deinit();
        current_owner = next_owner;
        next_owner = .{};
    }

    var constructing_owner = if (rt.contexts.constructing_head) |head| context_mod.RealmRef.retain(head) else context_mod.RealmRef{};
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
