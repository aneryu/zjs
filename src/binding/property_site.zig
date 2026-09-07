//! `zjs.PropertySite`: the resolved-once form of a host-side property access
//! (docs/perf/native-boundary-design.md §8.3 / §9.4, WP8 of
//! docs/perf/native-boundary-plan-r3.md).
//!
//! `JSContext.getProperty(obj, "field")` interns the name on every call and
//! then walks the object from scratch. A host that reads the same field in a
//! loop (an ECS system reading `entity.x`, a serializer walking a record) is
//! the embedder's analogue of a `get_field` bytecode site, and it deserves
//! the same inline cache: this type holds ONE `PropSiteCache` entry -- the
//! very struct and the very capture core the W1 VM sites use
//! (`exec.vm_property_field`) -- guarded by the receiver's `Shape.identity`.
//!
//! Arms, in the order the guard tests them (mirroring `op_get_field` and
//! `op_prop_site_indirect_tail` in `src/exec/tailcall_dispatch.zig`):
//!   - `.own`: identity match and `proto_key == 0` -> one indexed load;
//!   - `.proto`: identity match, receiver `class_id` re-check, holder
//!     identity re-check -> one indexed load out of the prototype;
//!   - `.native_getter`: the same two guards, then the accessor slot one
//!     prototype link up; a typed (K3) getter is a class check and one
//!     direct C call, an untyped one falls back to the ordinary path.
//! Anything else -- a miss, a non-object receiver, a Proxy, an exotic own
//! property, a getter written in JS -- takes the ordinary
//! `getValueProperty` / `setValueProperty` walk and charges the site one
//! capture, with the same miss budget and the same `.mega` retirement the VM
//! sites use (`PropSiteCache.miss_budget`, four overwrites).
//!
//! Invalidation (representation contract 5.2): `Shape.identity` is a
//! monotonic per-Runtime counter. A shape takes a NEW identity at creation
//! and before every in-place mutation of the guarded state -- property
//! append, property delete, flag update, prototype swap -- and identities are
//! never reused, so a freed Shape whose ADDRESS is recycled can never
//! re-match. Adding a property to the receiver, deleting one, freezing it, or
//! swapping its prototype therefore invalidates a site implicitly: the next
//! `get` guard-misses, re-captures, and either fills with the new layout or
//! retires. No explicit invalidation call exists, and none is needed.
//!
//! GC contract: a site holds NO `JSValue`. The property name is an interned
//! Atom pinned for the host between `init` and `deinit`
//! (`Atoms.pinForHost`, TGC S3 §2.5); the cache entry holds only integers (a
//! shape identity, a holder identity, a slot index, a class id), so it is
//! never a GC edge and never needs tracing. The receiver and the returned
//! value are the caller's, covered by the conservative native-stack scan
//! while they live in host locals, exactly as for `JSContext.getProperty`.
//! A site is bound to the context it was created for; use it only on the
//! runtime's thread, and `deinit` it before that context (or its runtime) is
//! destroyed -- `deinit` releases the atom pin against the runtime the site
//! was created with.

const std = @import("std");
const core = @import("../core/root.zig");
const exec = @import("../exec/root.zig");
const context_mod = @import("context.zig");
const prop_name = @import("prop_name.zig");

const JSContext = context_mod.JSContext;
const JSValue = core.JSValue;
const Object = core.Object;
const PropNameID = prop_name.PropNameID;
const vm_property_field = exec.vm_property_field;
const PropSiteCache = vm_property_field.PropSiteCache;
const objectFromValue = core.value_semantics.objectFromValueTrustedExpression;

pub const PropertySite = struct {
    ctx: *JSContext,
    /// Realm global for the ordinary property walk, resolved once (the same
    /// thing `CallSite.init` does with the callee's realm).
    global: *Object,
    /// Interned property name, pinned for the host until `deinit`.
    name: core.Atom,
    /// Read cache. Own / one-level-prototype / native-getter arms.
    read: PropSiteCache = .{},
    /// Write cache, deliberately SEPARATE from `read`: the two capture cores
    /// admit different properties (a read may cache a read-only own slot or a
    /// prototype slot, neither of which a write may store into), so one
    /// shared entry would either be unsound or thrash between the two access
    /// kinds on any host that both reads and writes the same field.
    write: PropSiteCache = .{},

    /// Intern `name` and pin it for the host. The site is bound to `ctx`'s
    /// realm.
    pub fn init(ctx: *JSContext, name: []const u8) !PropertySite {
        const rt = ctx.core.runtime;
        const id = try rt.internAtom(name);
        rt.atoms.pinForHost(id);
        errdefer rt.atoms.unpinForHost(id);
        return .{ .ctx = ctx, .global = try ctx.globalObject(), .name = id };
    }

    /// Same, for a name the host already interned (`zjs.host.PropName`). The
    /// site takes its own host pin, so the caller's id may be released
    /// independently.
    pub fn initAtom(ctx: *JSContext, name: PropNameID) !PropertySite {
        const rt = ctx.core.runtime;
        rt.atoms.pinForHost(name.value);
        errdefer rt.atoms.unpinForHost(name.value);
        return .{ .ctx = ctx, .global = try ctx.globalObject(), .name = name.value };
    }

    pub fn deinit(self: *PropertySite) void {
        self.ctx.core.runtime.atoms.unpinForHost(self.name);
        self.* = undefined;
    }

    /// The interned name, for hosts that also want to use it with the
    /// `PropNameID` operations.
    pub fn propName(self: *const PropertySite) PropNameID {
        return .{ .value = self.name };
    }

    /// `obj[name]`. A guard hit is an identity compare and an indexed load;
    /// everything else takes the ordinary walk and charges one capture.
    pub inline fn get(self: *PropertySite, obj: JSValue) !JSValue {
        if (objectFromValue(obj)) |object| {
            const site = &self.read;
            if (object.shape_ref.identity == site.guard_key) {
                if (site.proto_key == 0) {
                    return JSValue.loadSlotAsIntPair(&object.propertyEntry(site.slot).slot.data);
                }
                if (self.readIndirectArm(object, obj)) |value| return value;
            }
        }
        return self.getSlow(obj);
    }

    /// `obj[name] = value`, with the strict `Set` discipline: a write the
    /// object refuses (read-only own or inherited slot, non-extensible
    /// receiver, setter-less accessor) throws a TypeError, surfaced to the
    /// host as `error.JSException` with the exception pending on the context.
    /// The fast arm is an own writable data slot only.
    pub inline fn set(self: *PropertySite, obj: JSValue, value: JSValue) !void {
        if (objectFromValue(obj)) |object| {
            const site = &self.write;
            // Same guard pair as `op_put_field`: the WRITE arm is
            // class-dependent (mapped `arguments` must reach its binding) and
            // a Shape does not pin the class, so the class is re-checked here
            // even though the read's own arm does not need it.
            if (object.shape_ref.identity == site.guard_key and object.class_id == site.class_id) {
                const slot = &object.propertyEntry(site.slot).slot.data;
                JSValue.storeSlotAsIntPair(slot, value);
                // This arm writes the slot itself rather than going through
                // the `setOrDefineOwnDataProperty*` funnel, so it carries its
                // own barrier: `record.field = fresh` on an established
                // object is the old-to-young direction the minor's sticky
                // marks stop at.
                self.ctx.core.runtime.gc.generationalBarrierValue(object.gcHeader(), value);
                return;
            }
        }
        return self.setSlow(obj, value);
    }

    /// `.proto` / `.native_getter` arms. Out of line for the same reason
    /// `op_prop_site_indirect_tail` is a separate handler: keeping their
    /// extra guards in `get` costs the own hit a frame it does not use.
    /// Returns null when a guard detail missed, and the caller falls through
    /// to the ordinary walk (which re-captures).
    noinline fn readIndirectArm(self: *PropertySite, object: *Object, receiver: JSValue) ?JSValue {
        const site = &self.read;
        if (object.class_id != site.class_id) return null;
        const holder = object.shape_ref.proto orelse return null;
        if (holder.shape_ref.identity != site.proto_key) return null;
        if (site.state == vm_property_field.site_proto) {
            return JSValue.loadSlotAsIntPair(&holder.propertyEntry(site.slot).slot.data);
        }
        // `.native_getter`: the resolved `NativeEntry` is deliberately NOT
        // cached (`defineProperty` can replace the getter function without
        // touching a shape flag), so the accessor is re-read out of the
        // guarded slot and re-resolved. Only a typed (K3) getter answers
        // here; an untyped one needs the native terminal and takes the
        // ordinary walk.
        const accessor = holder.propertyEntry(site.slot).slot.accessor.getterValue();
        const target = exec.builtin_dispatch.nativeAccessorTarget(accessor, .getter) orelse return null;
        if (target.entry.sig == 0) return null;
        return exec.builtin_dispatch.invokeTypedGetterFast(target.entry, receiver);
    }

    noinline fn getSlow(self: *PropertySite, obj: JSValue) !JSValue {
        if (objectFromValue(obj)) |object| {
            if (vm_property_field.siteCapturable(&self.read)) {
                _ = vm_property_field.captureFieldSite(&self.read, object, self.name, true);
            }
        }
        return exec.object_ops.getValueProperty(self.ctx.core, null, self.global, obj, self.name, null, null);
    }

    noinline fn setSlow(self: *PropertySite, obj: JSValue, value: JSValue) !void {
        if (objectFromValue(obj)) |object| {
            if (vm_property_field.siteCapturable(&self.write)) {
                vm_property_field.capturePutSite(&self.write, object, self.name);
            }
        }
        _ = try exec.object_ops.setValuePropertyWithThrow(
            self.ctx.core,
            null,
            self.global,
            obj,
            self.name,
            value,
            null,
            null,
            true,
        );
    }
};

test "PropertySite caches an own data slot and follows a shape change" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try JSContext.create(rt);
    defer ctx.destroy();

    const obj = try ctx.eval("({ x: 1, field: 3 })", .{});
    var site = try PropertySite.init(ctx, "field");
    defer site.deinit();

    // First read captures; the rest hit the own arm.
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try std.testing.expectEqual(@as(?i32, 3), (try site.get(obj)).asInt32());
    }
    try std.testing.expectEqual(vm_property_field.site_own, site.read.state);

    // A shape change (property append) takes a fresh identity, so the guard
    // misses and the site re-captures against the new layout.
    const guard_before = site.read.guard_key;
    try ctx.defineDataProperty(obj, "later", JSValue.int32(9), .{});
    try std.testing.expectEqual(@as(?i32, 3), (try site.get(obj)).asInt32());
    try std.testing.expect(site.read.guard_key != guard_before);
    try std.testing.expectEqual(@as(?i32, 3), (try site.get(obj)).asInt32());
}

test "PropertySite and VM field caches handle slots beyond u16" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try JSContext.create(rt);
    defer ctx.destroy();
    const obj = try ctx.eval(
        \\var wide = {};
        \\for (var i = 0; i < 65536; i++) wide["p" + i] = i;
        \\wide.target = 123;
        \\wide;
    , .{});
    var last = try PropertySite.init(ctx, "p65535");
    defer last.deinit();
    try std.testing.expectEqual(@as(?i32, 65535), (try last.get(obj)).asInt32());
    try std.testing.expectEqual(vm_property_field.site_own, last.read.state);
    try std.testing.expectEqual(@as(u16, 65535), last.read.slot);

    var site = try PropertySite.init(ctx, "target");
    defer site.deinit();
    try std.testing.expectEqual(@as(?i32, 123), (try site.get(obj)).asInt32());
    try std.testing.expectEqual(vm_property_field.site_mega, site.read.state);
    try site.set(obj, JSValue.int32(456));
    try std.testing.expectEqual(vm_property_field.site_mega, site.write.state);
    try std.testing.expectEqual(@as(?i32, 456), (try site.get(obj)).asInt32());

    const inherited = try ctx.eval("var child = Object.create(wide); child", .{});
    var proto_site = try PropertySite.init(ctx, "target");
    defer proto_site.deinit();
    try std.testing.expectEqual(@as(?i32, 456), (try proto_site.get(inherited)).asInt32());
    try std.testing.expectEqual(vm_property_field.site_mega, proto_site.read.state);

    const Getter = struct {
        fn get(_: *core.JSContext, _: JSValue, _: *const core.NativeEntry) callconv(.c) JSValue {
            return JSValue.int32(1);
        }
    };
    const getter = try ctx.createFunction("wideGetter", .{ .template = .{
        .kind = .getter,
        .target = core.NativeEntry.code(&Getter.get),
    } }, .{});
    try ctx.defineDataProperty((try ctx.globalObject()).value(), "wideGetter", getter, .{});
    _ = try ctx.eval(
        \\function read(o) { return o.target; }
        \\function write(o, v) { o.target = v; }
        \\for (var n = 0; n < 3; n++) {
        \\  write(wide, 789);
        \\  if (read(wide) !== 789 || read(child) !== 789 || wide.p0 !== 0)
        \\    throw new Error("wide field cache aliased another slot");
        \\}
        \\Object.defineProperty(wide, "target", { get: wideGetter });
        \\Object.defineProperty(wide, "p65535", { get: wideGetter });
        \\function readSize(o) { return o.target; }
        \\for (var n = 0; n < 3; n++) {
        \\  if (readSize(child) !== 1) throw new Error("wide native getter cache");
        \\}
    , .{});
    var last_getter = try PropertySite.init(ctx, "p65535");
    defer last_getter.deinit();
    try std.testing.expectEqual(@as(?i32, 1), (try last_getter.get(inherited)).asInt32());
    try std.testing.expectEqual(vm_property_field.site_native_getter, last_getter.read.state);
    try std.testing.expectEqual(@as(u16, 65535), last_getter.read.slot);
    var getter_site = try PropertySite.init(ctx, "target");
    defer getter_site.deinit();
    try std.testing.expectEqual(@as(?i32, 1), (try getter_site.get(inherited)).asInt32());
    try std.testing.expectEqual(vm_property_field.site_mega, getter_site.read.state);
}
