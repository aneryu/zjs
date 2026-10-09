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

    pub const Scope = enum { live_only, include_constructing };

    /// Published realms first, then (for `.include_constructing`) realms
    /// under construction. Borrowed: the walk must not destroy a realm.
    pub const Iterator = struct {
        current: ?*JSContext,
        constructing: ?*JSContext,
        in_live: bool = true,

        pub fn next(self: *Iterator) ?*JSContext {
            while (true) {
                if (self.current) |ctx| {
                    self.current = if (self.in_live) ctx.runtime_next else ctx.construction_next;
                    return ctx;
                }
                if (!self.in_live) return null;
                self.in_live = false;
                self.current = self.constructing;
            }
        }
    };

    pub fn iterator(self: *const Lists, scope: Scope) Iterator {
        return .{
            .current = self.live_head,
            .constructing = if (scope == .include_constructing) self.constructing_head else null,
        };
    }

    /// The realm whose global object is `global`; live realms are searched
    /// before constructing ones.
    /// Two plain loops rather than `iterator`: this lookup sits on native
    /// call paths, where the iterator's list-switch state costs measurably.
    pub fn forGlobal(self: *const Lists, global: *const Object, comptime scope: Scope) ?*JSContext {
        var live = self.live_head;
        while (live) |ctx| : (live = ctx.runtime_next) {
            if (ctx.global == global) return ctx;
        }
        if (comptime scope == .live_only) return null;
        var constructing = self.constructing_head;
        while (constructing) |ctx| : (constructing = ctx.construction_next) {
            if (ctx.global == global) return ctx;
        }
        return null;
    }
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
    std.debug.assert(!anyHostRealmRef(rt));
}

/// Whether some realm still has an undestroyed host create-reference.
pub fn anyHostRealmRef(rt: *const JSRuntime) bool {
    var realms = rt.contexts.iterator(.include_constructing);
    while (realms.next()) |ctx| {
        if (!ctx.host_api_release_consumed) return true;
    }
    return false;
}

pub fn invalidateStandardArrayPrototype(rt: *JSRuntime, object_prototype: *Object) void {
    rt.assertOwnerThread();
    var realms = rt.contexts.iterator(.include_constructing);
    while (realms.next()) |ctx| invalidateOneStandardArrayPrototype(ctx, object_prototype);
}

fn invalidateOneStandardArrayPrototype(ctx: *JSContext, object_prototype: *Object) void {
    // Cached realm prototypes are objects; a non-object is a broken cache.
    const object_value = ctx.cached_values[@intFromEnum(object_mod.RealmValueSlot.object_prototype)] orelse return;
    const realm_object_prototype = Object.expect(object_value) catch unreachable;
    if (realm_object_prototype != object_prototype) return;
    const array_value = ctx.cached_values[@intFromEnum(object_mod.RealmValueSlot.array_prototype)] orelse return;
    const array_prototype = Object.expect(array_value) catch unreachable;
    array_prototype.flags.is_std_array_prototype = false;
}

pub fn initialArrayShape(rt: *const JSRuntime, prototype: ?*const Object) ?*shape.Shape {
    // Plain loops, like `Lists.forGlobal`: array creation reaches this.
    var live = rt.contexts.live_head;
    while (live) |ctx| : (live = ctx.runtime_next) {
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

/// Reserve a prototype slot in every realm before a class id is published.
/// The lists are indexes; `RealmRef` keeps each realm alive across growth.
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
