const std = @import("std");
const builtin = @import("builtin");

const build_options = @import("build_options");
const core = @import("../core/root.zig");
const exec = @import("../exec/root.zig");
const ffi = @import("../binding/ffi.zig");
const zjs = @import("../binding/root.zig");

pub const InstallOptions = struct {
    overwrite: bool = false,
};

pub const LoadError = std.mem.Allocator.Error || ffi.LoadError;

pub const InstallError = ffi.ValidationError || error{
    BindingLengthOverflow,
    DuplicateBindingName,
    InvalidTarget,
    HostObjectsRequireBindings,
    PluginAlreadyConsumed,
    PropertyAlreadyExists,
    TargetNotExtensible,
    UnknownHostObjectType,
};

pub const Plugin = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    loaded: ?ffi.LoadedPlugin,
    consumed: bool = false,

    pub fn load(allocator: std.mem.Allocator, path: []const u8) LoadError!Plugin {
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);

        const loaded = try ffi.LoadedPlugin.open(path_copy);
        return .{
            .allocator = allocator,
            .path = path_copy,
            .loaded = loaded,
        };
    }

    pub fn deinit(self: *Plugin) void {
        if (self.loaded) |*loaded| loaded.deinit();
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn install(self: *Plugin, ctx: *core.JSContext, target_value: core.JSValue, options: InstallOptions) !void {
        try ctx.runtimePtr().requireOwnerThread();
        if (self.consumed) return error.PluginAlreadyConsumed;
        const loaded = self.loaded orelse return error.PluginAlreadyConsumed;
        self.consumed = true;
        try installSource(ctx, target_value, self.path, .{
            .descriptor = loaded.descriptor,
            .lib = loaded.lib,
        }, options);
        self.loaded = null;
    }
};

const LoadedSource = struct {
    descriptor: *const ffi.PluginDescriptor,
    lib: ?std.DynLib = null,
};

const InstalledPlugin = struct {
    runtime: *core.JSRuntime,
    /// Binding records, opaque wrapper payloads, and the install staging owner.
    owner_ref_count: usize = 1,
    /// Each registered host class owns one reference through Definition.binding_data.
    definition_ref_count: usize = 0,
    /// DSO trampolines/finalizers/tracers and internal unload traversal pins.
    execution_pin_count: usize = 0,
    unload_requested: bool = false,
    host_class_unregistration_started: bool = false,
    closed: bool = false,
    lib: ?std.DynLib = null,
    owns_lib: bool = false,
    path: []u8,
    descriptor: *const ffi.PluginDescriptor,
    host_classes: []HostClass = &.{},
    prop_names: ?ffi.ResolvedPropNames = null,
    close_observer: if (builtin.is_test) ?*const fn (*InstalledPlugin) void else void = if (builtin.is_test) null else {},

    fn create(rt: *core.JSRuntime, path: []const u8, descriptor: *const ffi.PluginDescriptor, lib: ?std.DynLib) !*InstalledPlugin {
        try rt.requireOwnerThread();
        const path_copy = try rt.memory.alloc(u8, path.len);
        errdefer rt.memory.free(u8, path_copy);
        @memcpy(path_copy, path);

        const plugin = try rt.memory.create(InstalledPlugin);
        plugin.* = .{
            .runtime = rt,
            .lib = lib,
            .owns_lib = false,
            .path = path_copy,
            .descriptor = descriptor,
        };
        return plugin;
    }

    fn retain(self: *InstalledPlugin) bool {
        self.runtime.assertOwnerThread();
        if (self.unload_requested) return false;
        self.owner_ref_count += 1;
        return true;
    }

    fn release(self: *InstalledPlugin) void {
        self.runtime.assertOwnerThread();
        std.debug.assert(self.owner_ref_count > 0);
        self.owner_ref_count -= 1;
        if (self.owner_ref_count != 0) return;
        self.beginUnload();
    }

    fn retainDefinition(self: *InstalledPlugin) void {
        self.runtime.assertOwnerThread();
        std.debug.assert(!self.unload_requested);
        self.definition_ref_count += 1;
    }

    fn releaseDefinition(self: *InstalledPlugin) void {
        self.runtime.assertOwnerThread();
        std.debug.assert(self.definition_ref_count > 0);
        self.definition_ref_count -= 1;
        self.tryFinalizeUnload();
    }

    fn classDefinitionFinalizer(ptr: *anyopaque) void {
        const self: *InstalledPlugin = @ptrCast(@alignCast(ptr));
        self.releaseDefinition();
    }

    fn beginExecution(self: *InstalledPlugin) bool {
        self.runtime.assertOwnerThread();
        if (self.unload_requested) return false;
        self.execution_pin_count += 1;
        return true;
    }

    fn pinExecutionForExistingOwner(self: *InstalledPlugin) void {
        self.runtime.assertOwnerThread();
        std.debug.assert(self.owner_ref_count != 0);
        std.debug.assert(!self.unload_requested);
        self.execution_pin_count += 1;
    }

    fn endExecution(self: *InstalledPlugin) void {
        self.runtime.assertOwnerThread();
        std.debug.assert(self.execution_pin_count > 0);
        self.execution_pin_count -= 1;
        self.tryFinalizeUnload();
    }

    fn beginUnload(self: *InstalledPlugin) void {
        self.runtime.assertOwnerThread();
        if (self.unload_requested) return;
        self.unload_requested = true;
        self.host_class_unregistration_started = true;

        // Class-slot clearing can recursively release prototypes and complete
        // class unregistration. Keep the plugin control block alive until the
        // complete traversal has stopped every realm from creating new wrappers.
        self.execution_pin_count += 1;
        var index = self.host_classes.len;
        while (index > 0) {
            index -= 1;
            const host_class = &self.host_classes[index];
            self.runtime.clearContextClassPrototype(host_class.class_id);
            self.runtime.classes.unregisterDynamic(host_class.class_id);
        }
        self.endExecution();
    }

    fn tryBeginUnload(self: *InstalledPlugin) core.runtime.RuntimeMutationError!void {
        try self.runtime.requireOwnerThread();
        self.beginUnload();
    }

    fn tryFinalizeUnload(self: *InstalledPlugin) void {
        self.runtime.assertOwnerThread();
        if (!self.unload_requested or self.closed) return;
        if (self.owner_ref_count != 0 or self.definition_ref_count != 0 or self.execution_pin_count != 0) return;
        std.debug.assert(self.host_class_unregistration_started);

        self.closed = true;
        if (comptime builtin.is_test) {
            if (self.close_observer) |observer| observer(self);
        }

        const rt = self.runtime;
        if (self.owns_lib) {
            if (self.lib) |*lib| lib.close();
        }
        if (self.prop_names) |*prop_names| prop_names.deinit();
        const host_classes = self.host_classes;
        self.host_classes = &.{};
        if (host_classes.len != 0) rt.memory.free(HostClass, host_classes);
        rt.memory.free(u8, self.path);
        rt.memory.destroy(InstalledPlugin, self);
    }
};

const HostClass = struct {
    class_id: core.ClassId,
    descriptor: *const ffi.HostObjectDescriptor,
};

const OpaqueWrapperPayload = struct {
    plugin: *InstalledPlugin,
    descriptor: *const ffi.HostObjectDescriptor,
    object: ffi.OpaqueHostObject,
};

const opaque_host_object_identity = "zjs.runtime.plugin.opaque_host_object.v1";

const InstalledBinding = struct {
    plugin: *InstalledPlugin,
    descriptor: *const ffi.BindingDescriptor,
    active_calls: usize = 0,
    owner_live: bool = true,

    fn create(plugin: *InstalledPlugin, descriptor: *const ffi.BindingDescriptor) !*InstalledBinding {
        const rt = plugin.runtime;
        const binding = try rt.memory.create(InstalledBinding);
        if (!plugin.retain()) {
            rt.memory.destroy(InstalledBinding, binding);
            return error.TypeError;
        }
        binding.* = .{
            .plugin = plugin,
            .descriptor = descriptor,
        };
        return binding;
    }

    fn deinit(self: *InstalledBinding) void {
        std.debug.assert(self.active_calls == 0);
        if (!self.owner_live) return;
        self.owner_live = false;
        self.destroyWithOwnerRelease();
    }

    fn destroyWithOwnerRelease(self: *InstalledBinding) void {
        std.debug.assert(!self.owner_live);
        std.debug.assert(self.active_calls == 0);
        const rt = self.plugin.runtime;
        const plugin = self.plugin;
        rt.memory.destroy(InstalledBinding, self);
        plugin.release();
    }

    fn externalFinalizer(ptr: *anyopaque) void {
        const self: *InstalledBinding = @ptrCast(@alignCast(ptr));
        if (!self.owner_live) return;
        self.owner_live = false;
        if (self.active_calls == 0) {
            self.destroyWithOwnerRelease();
            return;
        }
        // The record owner is gone now, so publish unload and prevent new
        // wrapper entries immediately. active_calls independently pins this
        // binding allocation, while execution_pin_count keeps the DSO open.
        self.plugin.release();
    }

    fn call(ptr: *anyopaque, host_call: core.host_function.ExternalCall) anyerror!core.JSValue {
        const self: *InstalledBinding = @ptrCast(@alignCast(ptr));
        if (!self.owner_live or !self.plugin.beginExecution()) return error.TypeError;
        self.active_calls += 1;
        defer self.finishCall();

        const trampoline = self.descriptor.call orelse return error.TypeError;
        var frame = ffi.CallFrame{
            .ctx = @ptrCast(host_call.realm),
            .services = &host_services,
            .host_context = self,
            .this_value = host_call.this_value,
            .args = ffi.JSValueSlice.from(host_call.args),
        };
        const status = trampoline(&frame);
        const final_status = if (status == .ok) frame.error_status else status;
        if (final_status == .ok) return frame.result;
        const ctx = host_call.realm;
        if (final_status == .pending_exception) {
            if (ctx.hasException()) return error.JSException;
            return error.GenericError;
        }
        if (final_status == .out_of_memory) return error.OutOfMemory;
        if (borrowedErrorMessage(frame.error_message)) |message| {
            return throwPluginErrorMessage(host_call, final_status, message);
        }
        return errorFromStatus(final_status);
    }

    fn finishCall(self: *InstalledBinding) void {
        std.debug.assert(self.active_calls > 0);
        const plugin = self.plugin;
        self.active_calls -= 1;
        if (!self.owner_live and self.active_calls == 0) {
            plugin.runtime.memory.destroy(InstalledBinding, self);
        }
        // This must be the last operation: dropping the callback pin may close
        // the DSO and destroy InstalledPlugin.
        plugin.endExecution();
    }
};

const PreparedBinding = struct {
    atom: core.Atom = core.atom.null_atom,
    value: core.JSValue = core.JSValue.undefinedValue(),
    external_id: u32 = 0,
};

var tombstone_context: u8 = 0;

const host_services = ffi.HostServices{
    .size = @sizeOf(ffi.HostServices),
    .feature_flags = ffi.featureBit(.opaque_host_object) | ffi.featureBit(.prop_name_id),
    .create_opaque_object = createOpaqueObject,
    .unwrap_opaque_object = unwrapOpaqueObject,
    .get_prop_name = getPropName,
};

threadlocal var service_error_buffer: [256]u8 = undefined;

test "runtime Plugin HostServices reject a null borrowed callback context" {
    var frame = ffi.CallFrame{};
    var out = ffi.OpaqueHostObject{};

    try std.testing.expectEqual(ffi.Status.type_error, unwrapOpaqueObject(&frame, core.JSValue.undefinedValue(), ffi.HostTypeId.named("test.NullFrameContext"), &out));
    try std.testing.expect(out.ptr == null);
    try std.testing.expect(!out.type_id.isValid());
}

fn createOpaqueObject(frame: *ffi.CallFrame, object: ffi.OpaqueHostObject, out: *core.JSValue) callconv(.c) ffi.Status {
    out.* = core.JSValue.undefinedValue();
    const binding = bindingFromFrame(frame) orelse return .type_error;
    const ctx = frame.borrowContext() catch return .type_error;
    out.* = createOpaqueObjectValue(ctx, binding.plugin, object) catch |err| return createOpaqueObjectStatus(frame, object, err);
    return .ok;
}

fn unwrapOpaqueObject(frame: *ffi.CallFrame, value: core.JSValue, expected_type_id: ffi.HostTypeId, out: *ffi.OpaqueHostObject) callconv(.c) ffi.Status {
    out.* = .{};
    const ctx = frame.borrowContext() catch return .type_error;
    out.* = unwrapOpaqueObjectValue(ctx.runtimePtr(), value, expected_type_id) catch |err| return unwrapOpaqueObjectStatus(frame, ctx.runtimePtr(), value, expected_type_id, err);
    return .ok;
}

fn getPropName(frame: *ffi.CallFrame, index: u32, out: *ffi.PropNameID) callconv(.c) ffi.Status {
    out.* = .{};
    const binding = bindingFromFrame(frame) orelse return serviceTypeError(frame, "plugin call frame is not associated with an installed binding");
    const prop_names = binding.plugin.prop_names orelse return serviceRangeError(frame, "plugin has no resolved property names");
    if (index >= prop_names.ids.len) {
        return serviceRangeErrorFmt(frame, "plugin property name index {} is out of range", .{index});
    }
    out.* = prop_names.ids[index];
    return .ok;
}

fn createOpaqueObjectStatus(frame: *ffi.CallFrame, object: ffi.OpaqueHostObject, err: anyerror) ffi.Status {
    if (err == error.TypeError) {
        if (object.ptr == null) return serviceTypeError(frame, "opaque host object pointer is null");
        if (!object.type_id.isValid()) return serviceTypeError(frame, "opaque host object type id is invalid");
    }
    if (err == error.UnknownHostObjectType) {
        return serviceTypeErrorFmt(frame, "opaque host object type id 0x{x} is not declared by this plugin", .{object.type_id.value});
    }
    return pluginServiceStatus(frame, err);
}

fn unwrapOpaqueObjectStatus(frame: *ffi.CallFrame, rt: *core.JSRuntime, value: core.JSValue, expected_type_id: ffi.HostTypeId, err: anyerror) ffi.Status {
    if (err == error.TypeError) {
        if (!expected_type_id.isValid()) return serviceTypeError(frame, "expected opaque host object type id is invalid");
        if (opaquePayloadFromValue(rt, value)) |payload| {
            return serviceTypeErrorFmt(
                frame,
                "opaque host object type mismatch: expected 0x{x}, actual 0x{x} ({s})",
                .{ expected_type_id.value, payload.object.type_id.value, payload.descriptor.name.slice() },
            );
        }
        return serviceTypeErrorFmt(frame, "expected opaque host object with type id 0x{x}", .{expected_type_id.value});
    }
    return pluginServiceStatus(frame, err);
}

fn pluginServiceStatus(frame: *ffi.CallFrame, err: anyerror) ffi.Status {
    return switch (err) {
        error.UnknownHostObjectType => serviceTypeError(frame, "unknown opaque host object type"),
        else => ffi.statusFromError(err),
    };
}

fn serviceTypeError(frame: *ffi.CallFrame, message: []const u8) ffi.Status {
    frame.error_status = .type_error;
    frame.error_message = ffi.BorrowedBytes.from(message);
    return .type_error;
}

fn serviceRangeError(frame: *ffi.CallFrame, message: []const u8) ffi.Status {
    frame.error_status = .range_error;
    frame.error_message = ffi.BorrowedBytes.from(message);
    return .range_error;
}

fn serviceTypeErrorFmt(frame: *ffi.CallFrame, comptime fmt: []const u8, args: anytype) ffi.Status {
    const message = std.fmt.bufPrint(service_error_buffer[0..], fmt, args) catch "opaque host object type error";
    return serviceTypeError(frame, message);
}

fn serviceRangeErrorFmt(frame: *ffi.CallFrame, comptime fmt: []const u8, args: anytype) ffi.Status {
    const message = std.fmt.bufPrint(service_error_buffer[0..], fmt, args) catch "plugin property name index is out of range";
    return serviceRangeError(frame, message);
}

fn tombstoneCall(ptr: *anyopaque, host_call: core.host_function.ExternalCall) anyerror!core.JSValue {
    _ = ptr;
    _ = host_call;
    return error.TypeError;
}

fn tombstoneRecord() core.host_function.ExternalRecord {
    return .{
        .ptr = @ptrCast(&tombstone_context),
        .call = tombstoneCall,
        .finalizer = null,
    };
}

fn installSource(ctx: *core.JSContext, target_value: core.JSValue, path: []const u8, source: LoadedSource, options: InstallOptions) !void {
    const rt = ctx.runtimePtr();
    try rt.requireOwnerThread();
    const descriptor = source.descriptor;
    try ffi.validatePlugin(descriptor);

    const target = try expectPlainTarget(rt, target_value);

    const bindings = descriptor.bindingSlice();
    if (bindings.len == 0 and descriptor.host_object_count == 0 and descriptor.prop_name_count == 0) {
        if (source.lib) |lib_value| {
            var lib = lib_value;
            lib.close();
        }
        return;
    }
    if (bindings.len == 0 and descriptor.host_object_count != 0) return error.HostObjectsRequireBindings;

    const atoms = try rt.memory.alloc(core.Atom, bindings.len);
    defer rt.memory.free(core.Atom, atoms);
    var atom_count: usize = 0;
    defer releaseAtoms(rt, atoms[0..atom_count]);

    for (bindings, 0..) |binding_descriptor, index| {
        const atom_id = try rt.internAtom(binding_descriptor.name.slice());
        atoms[index] = atom_id;
        atom_count += 1;

        for (atoms[0..index]) |existing| {
            if (existing == atom_id) return error.DuplicateBindingName;
        }
    }

    try precheckTarget(target, rt, atoms, options);

    const installed_plugin = try InstalledPlugin.create(rt, path, descriptor, source.lib);
    var staging_plugin_active = true;
    errdefer if (staging_plugin_active) installed_plugin.release();

    try installPropNames(installed_plugin);
    try installHostClasses(ctx, installed_plugin);

    if (bindings.len == 0) {
        installed_plugin.owns_lib = source.lib != null;
        staging_plugin_active = false;
        installed_plugin.release();
        return;
    }

    const original_descriptors = try rt.memory.alloc(?core.Descriptor, bindings.len);
    defer rt.memory.free(?core.Descriptor, original_descriptors);
    @memset(original_descriptors, null);
    defer destroyOriginalDescriptors(rt, original_descriptors);

    for (atoms, 0..) |atom_id, index| {
        if (try target.getOwnProperty(rt, atom_id)) |current| {
            original_descriptors[index] = current;
        }
    }

    const prepared = try rt.memory.alloc(PreparedBinding, bindings.len);
    defer rt.memory.free(PreparedBinding, prepared);
    @memset(prepared, .{});
    var prepared_count: usize = 0;
    var staging_active = true;
    errdefer if (staging_active) rollbackPrepared(rt, prepared[0..prepared_count]);

    for (bindings, 0..) |*binding_descriptor, index| {
        const function_value, const external_id = try createBindingFunction(ctx, installed_plugin, binding_descriptor);
        prepared[index] = .{
            .atom = atoms[index],
            .value = function_value,
            .external_id = external_id,
        };
        prepared_count += 1;
    }

    var defined_count: usize = 0;
    errdefer rollbackDefinedProperties(rt, target, atoms[0..defined_count], original_descriptors[0..defined_count]);

    for (prepared[0..prepared_count]) |*entry| {
        try target.defineOwnProperty(rt, entry.atom, core.Descriptor.data(entry.value, true, true, true));
        entry.value.free(rt);
        entry.value = core.JSValue.undefinedValue();
        defined_count += 1;
    }

    installed_plugin.owns_lib = source.lib != null;
    staging_plugin_active = false;
    staging_active = false;
    installed_plugin.release();
}

fn expectPlainTarget(rt: *core.JSRuntime, value: core.JSValue) InstallError!*core.Object {
    const header = value.refHeader() orelse return error.InvalidTarget;
    if (!value.isObject()) return error.InvalidTarget;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (!rt.ownsObject(object)) return error.InvalidTarget;
    if (object.class_id != core.class.ids.object) return error.InvalidTarget;
    if (object.flags.class_payload_kind != .none and object.flags.class_payload_kind != .ordinary) return error.InvalidTarget;
    if (object.hasExoticMethods()) return error.InvalidTarget;
    if (object.proxyTarget() != null) return error.InvalidTarget;
    return object;
}

fn precheckTarget(target: *core.Object, rt: *core.JSRuntime, atoms: []const core.Atom, options: InstallOptions) !void {
    for (atoms) |atom_id| {
        if (try target.getOwnProperty(rt, atom_id)) |current| {
            defer current.destroy(rt);
            if (!options.overwrite) return error.PropertyAlreadyExists;
            if (!(current.configurable orelse false)) return error.IncompatibleDescriptor;
        } else if (!target.isExtensible()) {
            return error.TargetNotExtensible;
        }
    }
}

fn installPropNames(plugin: *InstalledPlugin) !void {
    const descriptors = plugin.descriptor.propNameSlice();
    if (descriptors.len == 0) return;
    plugin.prop_names = try ffi.resolvePropNames(plugin.runtime, descriptors);
}

fn installHostClasses(ctx: *core.JSContext, plugin: *InstalledPlugin) !void {
    const rt = ctx.runtimePtr();
    const descriptors = plugin.descriptor.hostObjectSlice();
    if (descriptors.len == 0) return;

    const host_classes = try rt.memory.alloc(HostClass, descriptors.len);
    plugin.host_classes = host_classes;

    var installed_count: usize = 0;
    errdefer {
        releaseHostClassEntries(rt, host_classes[0..installed_count]);
        rt.memory.free(HostClass, host_classes);
        plugin.host_classes = &.{};
    }

    for (descriptors, 0..) |*descriptor, index| {
        const class_id = try rt.newClassId(core.class.invalid_class_id);
        var class_registered = false;
        errdefer if (class_registered) rt.classes.unregisterDynamic(class_id);
        plugin.retainDefinition();
        var definition_owned_by_record = false;
        errdefer if (!definition_owned_by_record) plugin.releaseDefinition();

        try rt.ensureContextClassPrototypeCapacity(class_id);
        try rt.classes.register(class_id, .{
            .class_name = descriptor.name.slice(),
            .binding_identity = opaque_host_object_identity,
            .binding_data = @ptrCast(plugin),
            .binding_data_finalizer = InstalledPlugin.classDefinitionFinalizer,
            .payload_kind = .none,
            .payload_finalizer = opaquePayloadFinalizer,
            .payload_mark = opaquePayloadMark,
        });
        definition_owned_by_record = true;
        class_registered = true;

        const prototype = try core.Object.create(rt, core.class.ids.object, null);
        const prototype_value = prototype.value();
        errdefer prototype_value.free(rt);
        try defineToStringTag(rt, prototype, descriptor.name.slice());
        try ctx.setClassPrototype(class_id, prototype);
        prototype_value.free(rt);

        host_classes[index] = .{
            .class_id = class_id,
            .descriptor = descriptor,
        };
        class_registered = false;
        installed_count += 1;
    }
}

fn releaseHostClassEntries(rt: *core.JSRuntime, host_classes: []HostClass) void {
    var index = host_classes.len;
    while (index > 0) {
        index -= 1;
        const host_class = &host_classes[index];
        rt.clearContextClassPrototype(host_class.class_id);
        rt.classes.unregisterDynamic(host_class.class_id);
    }
}

fn defineToStringTag(rt: *core.JSRuntime, prototype: *core.Object, tag: []const u8) !void {
    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return;
    const tag_value = (try core.string.String.createAscii(rt, tag)).value();
    defer tag_value.free(rt);
    try prototype.defineOwnProperty(rt, tag_atom, core.Descriptor.data(tag_value, false, false, true));
}

fn bindingFromFrame(frame: *ffi.CallFrame) ?*InstalledBinding {
    const raw = frame.host_context orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn createOpaqueObjectValue(ctx: *core.JSContext, plugin: *InstalledPlugin, object: ffi.OpaqueHostObject) !core.JSValue {
    if (object.ptr == null or !object.type_id.isValid()) return error.TypeError;
    if (!plugin.retain()) return error.TypeError;
    var plugin_owner_pending = true;
    errdefer if (plugin_owner_pending) plugin.release();
    const host_class = hostClassForType(plugin, object.type_id) orelse return error.UnknownHostObjectType;
    const rt = ctx.runtimePtr();
    const prototype = ctx.classPrototypeObject(host_class.class_id);
    const wrapper = try core.Object.create(rt, host_class.class_id, prototype);
    errdefer wrapper.value().free(rt);

    const payload = try rt.memory.create(OpaqueWrapperPayload);
    errdefer rt.memory.destroy(OpaqueWrapperPayload, payload);
    payload.* = .{
        .plugin = plugin,
        .descriptor = host_class.descriptor,
        .object = object,
    };
    wrapper.installExternalClassPayload(@ptrCast(payload));
    plugin_owner_pending = false;
    return wrapper.value();
}

fn hostClassForType(plugin: *InstalledPlugin, type_id: ffi.HostTypeId) ?HostClass {
    for (plugin.host_classes) |host_class| {
        if (host_class.descriptor.type_id.value == type_id.value) return host_class;
    }
    return null;
}

fn unwrapOpaqueObjectValue(rt: *core.JSRuntime, value: core.JSValue, expected_type_id: ffi.HostTypeId) !ffi.OpaqueHostObject {
    if (!expected_type_id.isValid()) return error.TypeError;
    const payload = opaquePayloadFromValue(rt, value) orelse return error.TypeError;
    if (payload.object.type_id.value != expected_type_id.value) return error.TypeError;
    return payload.object;
}

fn opaquePayloadFromValue(rt: *core.JSRuntime, value: core.JSValue) ?*OpaqueWrapperPayload {
    const header = value.refHeader() orelse return null;
    if (!value.isObject()) return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (!rt.ownsObject(object)) return null;
    if (!isOpaqueHostObjectClass(rt, object)) return null;
    const raw_payload = object.externalClassPayloadConst() orelse return null;
    return @ptrCast(@alignCast(raw_payload));
}

fn isOpaqueHostObjectClass(rt: *core.JSRuntime, object: *const core.Object) bool {
    const record = rt.classes.record(object.class_id) orelse return false;
    const identity = record.binding_identity orelse return false;
    return std.mem.eql(u8, identity, opaque_host_object_identity);
}

fn opaquePayloadFinalizer(runtime: *anyopaque, object: *anyopaque, class_payload: *core.class.Payload) void {
    _ = object;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const payload = opaquePayload(class_payload) orelse return;
    const plugin = payload.plugin;
    // The payload owns a plugin reference, so unload cannot have started.
    // Pin the DSO separately because releasing that last owner below may begin
    // class unregistration while this callback is still returning through it.
    plugin.pinExecutionForExistingOwner();
    if (payload.descriptor.owner == .js) {
        if (payload.descriptor.finalizer) |finalizer| {
            finalizer(payload.descriptor.context, payload.object);
        }
    }
    rt.memory.destroy(OpaqueWrapperPayload, payload);
    class_payload.* = null;
    plugin.release();
    plugin.endExecution();
}

fn opaquePayloadMark(runtime: *anyopaque, object: *anyopaque, class_payload: *core.class.Payload, visitor: *core.class.PayloadVisitor) void {
    _ = runtime;
    _ = object;
    const payload = opaquePayload(class_payload) orelse return;
    const plugin = payload.plugin;
    plugin.pinExecutionForExistingOwner();
    defer plugin.endExecution();
    const tracer = payload.descriptor.tracer orelse return;
    const Adapter = struct {
        visitor: *core.class.PayloadVisitor,

        fn visitValue(context: ?*anyopaque, value: *core.JSValue) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.visitor.value(@ptrCast(value));
        }
    };
    var adapter = Adapter{ .visitor = visitor };
    var host_visitor = ffi.HostTraceVisitor{
        .context = &adapter,
        .visit_value = Adapter.visitValue,
    };
    tracer(payload.descriptor.context, payload.object, &host_visitor);
}

fn opaquePayload(class_payload: *core.class.Payload) ?*OpaqueWrapperPayload {
    const payload = class_payload.* orelse return null;
    return @ptrCast(@alignCast(payload));
}

fn createBindingFunction(ctx: *core.JSContext, plugin: *InstalledPlugin, descriptor: *const ffi.BindingDescriptor) !struct { core.JSValue, u32 } {
    const rt = ctx.runtimePtr();
    const installed_binding = try InstalledBinding.create(plugin, descriptor);
    var record_registered = false;
    errdefer if (!record_registered) installed_binding.deinit();

    const length = std.math.cast(i32, descriptor.length) orelse return error.BindingLengthOverflow;
    const function_proto = ctx.cached_function_proto orelse return error.InvalidBuiltinRegistry;
    const function_value = try core.function.nativeFunctionWithPrototypeAndCapacity(ctx, function_proto, descriptor.name.slice(), length, 2);
    errdefer function_value.free(rt);
    const function_object = try core.Object.expect(function_value);

    const external_id = try rt.registerExternalHostFunction(.{
        .ptr = @ptrCast(installed_binding),
        .call = InstalledBinding.call,
        .finalizer = InstalledBinding.externalFinalizer,
    });
    record_registered = true;

    function_object.hostFunctionKindSlot().* = core.host_function.ids.external_host;
    function_object.externalHostFunctionIdSlot().* = external_id;
    return .{ function_value, external_id };
}

fn rollbackPrepared(rt: *core.JSRuntime, prepared: []PreparedBinding) void {
    for (prepared) |*entry| {
        entry.value.free(rt);
        entry.value = core.JSValue.undefinedValue();
        if (entry.external_id != 0) {
            if (rt.replaceExternalHostFunction(entry.external_id, tombstoneRecord())) |old| {
                if (old.finalizer) |finalizer| finalizer(old.ptr);
            }
            entry.external_id = 0;
        }
    }
}

fn rollbackDefinedProperties(rt: *core.JSRuntime, target: *core.Object, atoms: []const core.Atom, originals: []const ?core.Descriptor) void {
    std.debug.assert(atoms.len == originals.len);
    var index = atoms.len;
    while (index > 0) {
        index -= 1;
        if (originals[index]) |original| {
            target.defineOwnProperty(rt, atoms[index], original) catch {
                _ = target.deleteProperty(rt, atoms[index]);
            };
        } else {
            _ = target.deleteProperty(rt, atoms[index]);
        }
    }
}

fn destroyOriginalDescriptors(rt: *core.JSRuntime, originals: []const ?core.Descriptor) void {
    for (originals) |maybe_descriptor| {
        if (maybe_descriptor) |descriptor| descriptor.destroy(rt);
    }
}

fn releaseAtoms(rt: *core.JSRuntime, atoms: []const core.Atom) void {
    for (atoms) |atom_id| rt.atoms.free(atom_id);
}

fn errorFromStatus(status: ffi.Status) anyerror {
    return switch (status) {
        .ok => error.Unexpected,
        .pending_exception => error.JSException,
        .out_of_memory => error.OutOfMemory,
        .type_error => error.TypeError,
        .range_error => error.RangeError,
        .unsupported => error.Unsupported,
        .syntax_error => error.SyntaxError,
        .generic_error => error.GenericError,
        .reference_error => error.ReferenceError,
        .eval_error => error.EvalError,
        .uri_error => error.URIError,
        _ => error.GenericError,
    };
}

fn borrowedErrorMessage(message: ffi.BorrowedBytes) ?[]const u8 {
    if (message.len == 0) return null;
    const ptr = message.ptr orelse return null;
    return ptr[0..message.len];
}

fn throwPluginErrorMessage(host_call: core.host_function.ExternalCall, status: ffi.Status, message: []const u8) !core.JSValue {
    const ctx = host_call.realm;
    const global = ctx.global orelse try ctx.globalObject();
    const error_name = errorNameFromStatus(status);
    const error_value = exec.exception_ops.createNamedError(ctx, global, error_name, message) catch |err| switch (err) {
        error.InvalidUtf8 => try exec.exception_ops.createNamedError(ctx, global, error_name, fallbackMessageFromStatus(status)),
        else => return err,
    };
    if (ctx.hasException()) ctx.clearException();
    _ = ctx.throwValue(error_value);
    return error.JSException;
}

fn errorNameFromStatus(status: ffi.Status) []const u8 {
    return switch (status) {
        .type_error => "TypeError",
        .range_error => "RangeError",
        .syntax_error => "SyntaxError",
        .reference_error => "ReferenceError",
        .eval_error => "EvalError",
        .uri_error => "URIError",
        else => "Error",
    };
}

fn fallbackMessageFromStatus(status: ffi.Status) []const u8 {
    return switch (status) {
        .unsupported => "Unsupported",
        .type_error, .range_error, .syntax_error, .reference_error, .eval_error, .uri_error => errorNameFromStatus(status),
        else => "GenericError",
    };
}

fn installDescriptorForTesting(ctx: *zjs.JSContext, target_value: core.JSValue, descriptor: *const ffi.PluginDescriptor, options: InstallOptions) !void {
    try installSource(ctx.core, target_value, "<test-plugin>", .{ .descriptor = descriptor }, options);
}

fn objectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    if (header.meta().kind != .object) return null;
    return @fieldParentPtr("header", header);
}

fn objectProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8) !core.JSValue {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    return try object.getProperty(key);
}

fn expectErrorObjectProperty(rt: *core.JSRuntime, value: core.JSValue, property_name: []const u8, expected: []const u8) !void {
    const object = objectFromValue(value) orelse return error.TypeError;
    const property_value = try objectProperty(rt, object, property_name);
    defer property_value.free(rt);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try exec.value_ops.appendRawString(rt, &bytes, property_value);
    try std.testing.expectEqualStrings(expected, bytes.items);
}

test "runtime Plugin rejects foreign install and unload before mutation" {
    const Impl = struct {
        fn noop(_: ffi.ZigCall) void {}
    };
    const TestPlugin = ffi.Plugin("runtime-owner-thread-test", .{
        ffi.binding("noop", Impl.noop),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();
    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);

    const descriptor = TestPlugin.descriptor();
    const installed = try InstalledPlugin.create(rt, "<owner-thread-test>", descriptor, null);
    var installed_owner_live = true;
    defer if (installed_owner_live) installed.release();

    const Attempt = struct {
        ctx: *zjs.JSContext,
        target: core.JSValue,
        descriptor: *const ffi.PluginDescriptor,
        installed: *InstalledPlugin,
        install_rejected: bool = false,
        unload_rejected: bool = false,

        fn run(self: *@This()) void {
            self.install_rejected = if (installDescriptorForTesting(self.ctx, self.target, self.descriptor, .{})) |_| false else |err| err == error.WrongRuntimeThread;
            self.unload_rejected = if (self.installed.tryBeginUnload()) |_| false else |err| err == error.WrongRuntimeThread;
        }
    };

    const noop_atom = try rt.internAtom("noop");
    defer rt.atoms.free(noop_atom);
    const memory_before = rt.memory.allocated_bytes;
    var attempt = Attempt{
        .ctx = ctx,
        .target = target_value,
        .descriptor = descriptor,
        .installed = installed,
    };
    const thread = try std.Thread.spawn(.{}, Attempt.run, .{&attempt});
    thread.join();

    try std.testing.expect(attempt.install_rejected);
    try std.testing.expect(attempt.unload_rejected);
    try std.testing.expectEqual(memory_before, rt.memory.allocated_bytes);
    try std.testing.expect(!target.hasOwnProperty(noop_atom));
    try std.testing.expectEqual(@as(usize, 1), installed.owner_ref_count);
    try std.testing.expectEqual(@as(usize, 0), installed.definition_ref_count);
    try std.testing.expectEqual(@as(usize, 0), installed.execution_pin_count);
    try std.testing.expect(!installed.unload_requested);
    try std.testing.expect(!installed.host_class_unregistration_started);
    try std.testing.expect(!installed.closed);

    installed_owner_live = false;
    installed.release();
}

test "runtime Plugin installs synchronous bindings on an ordinary target" {
    const Impl = struct {
        fn add(call: ffi.ZigCall) !core.JSValue {
            if (call.args.len != 2) return error.TypeError;
            return core.JSValue.int32(call.args[0].asInt32().? + call.args[1].asInt32().?);
        }

        fn defaultLength(call: ffi.ZigCall) void {
            _ = call;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-test", .{
        ffi.bindingWithOptions("add", Impl.add, .{ .length = 2 }),
        ffi.binding("defaultLength", Impl.defaultLength),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);

    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const add_atom = try rt.internAtom("add");
    defer rt.atoms.free(add_atom);
    const add_descriptor = (try target.getOwnProperty(rt, add_atom)) orelse return error.TestExpectedEqual;
    defer add_descriptor.destroy(rt);
    try std.testing.expect(add_descriptor.value.isObject());
    try std.testing.expectEqual(true, add_descriptor.writable.?);
    try std.testing.expectEqual(true, add_descriptor.enumerable.?);
    try std.testing.expectEqual(true, add_descriptor.configurable.?);

    const add_value = try target.getProperty(add_atom);
    defer add_value.free(rt);
    try std.testing.expect(add_value.isObject());
    const add_object: *core.Object = @fieldParentPtr("header", add_value.refHeader().?);
    try std.testing.expectEqual(core.host_function.ids.external_host, add_object.hostFunctionKindSlot().*);
    const name_value = try add_object.getProperty(core.atom.ids.name);
    defer name_value.free(rt);
    var name_bytes = std.ArrayList(u8).empty;
    defer name_bytes.deinit(rt.memory.allocator);
    try exec.value_ops.appendRawString(rt, &name_bytes, name_value);
    try std.testing.expectEqualStrings("add", name_bytes.items);
    try std.testing.expectEqual(@as(i32, 2), (try add_object.getProperty(core.atom.ids.length)).asInt32().?);

    const default_length_atom = try rt.internAtom("defaultLength");
    defer rt.atoms.free(default_length_atom);
    const default_length_value = try target.getProperty(default_length_atom);
    defer default_length_value.free(rt);
    const default_length_object: *core.Object = @fieldParentPtr("header", default_length_value.refHeader().?);
    try std.testing.expectEqual(core.host_function.ids.external_host, default_length_object.hostFunctionKindSlot().*);
    try std.testing.expectEqual(@as(i32, 0), (try default_length_object.getProperty(core.atom.ids.length)).asInt32().?);

    const global = try ctx.globalObject();
    try std.testing.expect(!global.hasOwnProperty(add_atom));
    try std.testing.expect(!global.hasOwnProperty(default_length_atom));
    const plugin_name_atom = try rt.internAtom("runtime-test");
    defer rt.atoms.free(plugin_name_atom);
    try std.testing.expect(!global.hasOwnProperty(plugin_name_atom));
    try std.testing.expect(!target.hasOwnProperty(plugin_name_atom));

    const native_atom = try rt.internAtom("native");
    defer rt.atoms.free(native_atom);
    try global.defineOwnProperty(rt, native_atom, core.Descriptor.data(target_value, true, true, true));

    const result = try ctx.eval("native.add(2, 5)", .{});
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 7), result.asInt32().?);
}

test "runtime Plugin defers last binding release until its trampoline returns" {
    const State = struct {
        callback_entered: bool = false,
        binding_retired: bool = false,
        new_entries_stopped: bool = false,
        callback_observed_close: bool = false,
        close_count: usize = 0,
        close_saw_drained_pins: bool = false,

        var active: ?*@This() = null;

        fn retire(frame: *ffi.CallFrame) ffi.Status {
            const self = active orelse return .generic_error;
            self.callback_entered = true;
            self.callback_observed_close = self.close_count != 0;
            const binding: *InstalledBinding = @ptrCast(@alignCast(frame.host_context orelse return .type_error));
            InstalledBinding.externalFinalizer(@ptrCast(binding));
            self.binding_retired = true;
            self.new_entries_stopped = binding.plugin.unload_requested and !binding.plugin.retain();
            // Retirement removed the last artifact owner, but the active call
            // pin must keep both InstalledBinding and the DSO alive here.
            self.callback_observed_close = self.callback_observed_close or self.close_count != 0;
            return .ok;
        }

        fn observeClose(plugin: *InstalledPlugin) void {
            const self = active orelse return;
            self.close_count += 1;
            self.close_saw_drained_pins = plugin.closed and
                plugin.owner_ref_count == 0 and
                plugin.definition_ref_count == 0 and
                plugin.execution_pin_count == 0;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-binding-self-retire-test", .{
        ffi.binding("retire", State.retire),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const target = try core.Object.create(rt, core.class.ids.object, null);
    defer target.value().free(rt);

    var state = State{};
    State.active = &state;
    defer State.active = null;

    const descriptor = TestPlugin.descriptor();
    const binding_descriptors = descriptor.bindingSlice();
    const plugin = try InstalledPlugin.create(rt, "<binding-self-retire>", descriptor, null);
    plugin.close_observer = State.observeClose;
    const binding = try InstalledBinding.create(plugin, &binding_descriptors[0]);
    defer if (!state.binding_retired) binding.deinit();
    // Leave the binding record as the only installed artifact owner.
    plugin.release();

    const result = try InstalledBinding.call(@ptrCast(binding), .{
        .realm = ctx,
        .output = null,
        .func_obj = target,
        .this_value = core.JSValue.undefinedValue(),
        .args = &.{},
    });
    result.free(rt);

    try std.testing.expect(state.callback_entered);
    try std.testing.expect(state.binding_retired);
    try std.testing.expect(state.new_entries_stopped);
    try std.testing.expect(!state.callback_observed_close);
    try std.testing.expectEqual(@as(usize, 1), state.close_count);
    try std.testing.expect(state.close_saw_drained_pins);
}

fn testFixturePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return std.fs.path.resolve(allocator, &.{ "../..", path }),
        else => return err,
    };
    file.close(io);
    return allocator.dupe(u8, path);
}

test "runtime Plugin loads a dynamic library and installs its binding" {
    const fixture_path = try testFixturePath(std.testing.allocator, build_options.runtime_plugin_fixture_path);
    defer std.testing.allocator.free(fixture_path);

    var plugin = try Plugin.load(std.testing.allocator, fixture_path);
    defer plugin.deinit();

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);

    try plugin.install(ctx.core, target_value, .{});
    try std.testing.expect(plugin.loaded == null);
    try std.testing.expectError(error.PluginAlreadyConsumed, plugin.install(ctx.core, target_value, .{}));

    const global = try ctx.globalObject();
    const native_atom = try rt.internAtom("native");
    defer rt.atoms.free(native_atom);
    try global.defineOwnProperty(rt, native_atom, core.Descriptor.data(target_value, true, true, true));

    const result = try ctx.eval("native.add(20, 22)", .{});
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "runtime Plugin load owns a path copy independent from caller storage" {
    const fixture_path = try testFixturePath(std.testing.allocator, build_options.runtime_plugin_fixture_path);
    defer std.testing.allocator.free(fixture_path);

    const caller_path = try std.testing.allocator.dupe(u8, fixture_path);
    defer std.testing.allocator.free(caller_path);

    var plugin = try Plugin.load(std.testing.allocator, caller_path);
    defer plugin.deinit();

    @memset(caller_path, '#');
    try std.testing.expectEqualStrings(fixture_path, plugin.path);

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);

    try plugin.install(ctx.core, target_value, .{});

    const global = try ctx.globalObject();
    const native_atom = try rt.internAtom("native");
    defer rt.atoms.free(native_atom);
    try global.defineOwnProperty(rt, native_atom, core.Descriptor.data(target_value, true, true, true));

    const result = try ctx.eval("native.add(4, 6)", .{});
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 10), result.asInt32().?);
}

test "runtime Plugin treats repeated loads of the same path as independent installs" {
    const fixture_path = try testFixturePath(std.testing.allocator, build_options.runtime_plugin_fixture_path);
    defer std.testing.allocator.free(fixture_path);

    var first = try Plugin.load(std.testing.allocator, fixture_path);
    defer first.deinit();
    var second = try Plugin.load(std.testing.allocator, fixture_path);
    defer second.deinit();

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const left = try core.Object.create(rt, core.class.ids.object, null);
    const left_value = left.value();
    defer left_value.free(rt);
    const right = try core.Object.create(rt, core.class.ids.object, null);
    const right_value = right.value();
    defer right_value.free(rt);

    try first.install(ctx.core, left_value, .{});
    try second.install(ctx.core, right_value, .{});
    try std.testing.expect(first.loaded == null);
    try std.testing.expect(second.loaded == null);

    const global = try ctx.globalObject();
    const left_atom = try rt.internAtom("left");
    defer rt.atoms.free(left_atom);
    try global.defineOwnProperty(rt, left_atom, core.Descriptor.data(left_value, true, true, true));
    const right_atom = try rt.internAtom("right");
    defer rt.atoms.free(right_atom);
    try global.defineOwnProperty(rt, right_atom, core.Descriptor.data(right_value, true, true, true));

    const result = try ctx.eval("left.add(1, 2) + right.add(10, 20)", .{});
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 33), result.asInt32().?);
}

test "runtime Plugin accepts empty descriptors as no-op installs" {
    const fixture_path = try testFixturePath(std.testing.allocator, build_options.runtime_empty_plugin_fixture_path);
    defer std.testing.allocator.free(fixture_path);

    var plugin = try Plugin.load(std.testing.allocator, fixture_path);
    defer plugin.deinit();

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);

    const sentinel_atom = try rt.internAtom("sentinel");
    defer rt.atoms.free(sentinel_atom);
    try target.defineOwnProperty(rt, sentinel_atom, core.Descriptor.data(core.JSValue.int32(17), false, false, true));

    try plugin.install(ctx.core, target_value, .{});
    try std.testing.expect(plugin.consumed);
    try std.testing.expect(plugin.loaded == null);
    try std.testing.expectError(error.PluginAlreadyConsumed, plugin.install(ctx.core, target_value, .{}));

    const sentinel = (try target.getOwnProperty(rt, sentinel_atom)) orelse return error.TestExpectedEqual;
    defer sentinel.destroy(rt);
    try std.testing.expectEqual(@as(?i32, 17), sentinel.value.asInt32());
    try std.testing.expectEqual(false, sentinel.writable.?);
    try std.testing.expectEqual(false, sentinel.enumerable.?);
    try std.testing.expectEqual(true, sentinel.configurable.?);
}

test "runtime Plugin install consumes the loaded handle even when install fails" {
    const fixture_path = try testFixturePath(std.testing.allocator, build_options.runtime_plugin_fixture_path);
    defer std.testing.allocator.free(fixture_path);

    var plugin = try Plugin.load(std.testing.allocator, fixture_path);
    defer plugin.deinit();

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);

    const add_atom = try rt.internAtom("add");
    defer rt.atoms.free(add_atom);
    try target.defineOwnProperty(rt, add_atom, core.Descriptor.data(core.JSValue.int32(1), true, true, true));

    try std.testing.expectError(error.PropertyAlreadyExists, plugin.install(ctx.core, target_value, .{}));
    try std.testing.expect(plugin.consumed);
    try std.testing.expect(plugin.loaded != null);
    try std.testing.expectError(error.PluginAlreadyConsumed, plugin.install(ctx.core, target_value, .{ .overwrite = true }));
}

test "runtime Plugin install rejects non-ordinary targets" {
    const Impl = struct {
        fn noop(call: ffi.ZigCall) void {
            _ = call;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-target-shape-test", .{
        ffi.binding("noop", Impl.noop),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const array = try core.Object.createArray(rt, null);
    const array_value = array.value();
    defer array_value.free(rt);
    try std.testing.expectError(error.InvalidTarget, installDescriptorForTesting(ctx, array_value, TestPlugin.descriptor(), .{}));

    const function_value = try ctx.eval("(function target() {})", .{});
    defer function_value.free(rt);
    try std.testing.expectError(error.InvalidTarget, installDescriptorForTesting(ctx, function_value, TestPlugin.descriptor(), .{}));

    const proxy_value = try ctx.eval("new Proxy({}, {})", .{});
    defer proxy_value.free(rt);
    try std.testing.expectError(error.InvalidTarget, installDescriptorForTesting(ctx, proxy_value, TestPlugin.descriptor(), .{}));

    const typed_array_value = try ctx.eval("new Uint8Array(0)", .{});
    defer typed_array_value.free(rt);
    try std.testing.expectError(error.InvalidTarget, installDescriptorForTesting(ctx, typed_array_value, TestPlugin.descriptor(), .{}));

    const arguments_value = try ctx.eval("(function () { return arguments; })()", .{});
    defer arguments_value.free(rt);
    try std.testing.expectError(error.InvalidTarget, installDescriptorForTesting(ctx, arguments_value, TestPlugin.descriptor(), .{}));

    const namespace = try core.Object.create(rt, core.class.ids.module_ns, null);
    const namespace_value = namespace.value();
    defer namespace_value.free(rt);
    try std.testing.expectError(error.InvalidTarget, installDescriptorForTesting(ctx, namespace_value, TestPlugin.descriptor(), .{}));
}

test "runtime Plugin install rejects targets from another runtime" {
    const Impl = struct {
        fn noop(call: ffi.ZigCall) void {
            _ = call;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-cross-runtime-target-test", .{
        ffi.binding("noop", Impl.noop),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const other_rt = try core.JSRuntime.create(std.testing.allocator);
    defer other_rt.destroy();
    const other_target = try core.Object.create(other_rt, core.class.ids.object, null);
    const other_target_value = other_target.value();
    defer other_target_value.free(other_rt);

    try std.testing.expectError(error.InvalidTarget, installDescriptorForTesting(ctx, other_target_value, TestPlugin.descriptor(), .{}));
}

test "runtime Plugin install rejects additions on non-extensible targets" {
    const Impl = struct {
        fn noop(call: ffi.ZigCall) void {
            _ = call;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-target-extensible-test", .{
        ffi.binding("added", Impl.noop),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);
    target.preventExtensions();

    try std.testing.expectError(error.TargetNotExtensible, installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{}));
}

test "runtime Plugin install ignores inherited binding-name properties" {
    const Impl = struct {
        fn noop(call: ffi.ZigCall) void {
            _ = call;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-inherited-target-property-test", .{
        ffi.binding("shadowed", Impl.noop),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const key = try rt.internAtom("shadowed");
    defer rt.atoms.free(key);

    const prototype = try core.Object.create(rt, core.class.ids.object, null);
    const prototype_value = prototype.value();
    defer prototype_value.free(rt);
    try prototype.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(1), true, true, true));

    const target = try core.Object.create(rt, core.class.ids.object, prototype);
    const target_value = target.value();
    defer target_value.free(rt);

    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const inherited = try prototype.getProperty(key);
    defer inherited.free(rt);
    try std.testing.expectEqual(@as(i32, 1), inherited.asInt32().?);

    const own = (try target.getOwnProperty(rt, key)) orelse return error.TestExpectedEqual;
    defer own.destroy(rt);
    try std.testing.expect(own.value.isObject());
}

test "runtime Plugin install prechecks conflicts before mutating target" {
    const Impl = struct {
        fn noop(call: ffi.ZigCall) void {
            _ = call;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-conflict-test", .{
        ffi.binding("add", Impl.noop),
        ffi.binding("mul", Impl.noop),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);

    const add_atom = try rt.internAtom("add");
    defer rt.atoms.free(add_atom);
    try target.defineOwnProperty(rt, add_atom, core.Descriptor.data(core.JSValue.int32(1), true, true, true));

    try std.testing.expectError(error.PropertyAlreadyExists, installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{}));

    const mul_atom = try rt.internAtom("mul");
    defer rt.atoms.free(mul_atom);
    try std.testing.expect(!target.hasOwnProperty(mul_atom));
}

test "runtime Plugin install rejects duplicate binding names before mutating target" {
    const Impl = struct {
        fn first(call: ffi.ZigCall) void {
            _ = call;
        }

        fn second(call: ffi.ZigCall) void {
            _ = call;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-duplicate-binding-name-test", .{
        ffi.binding("dup", Impl.first),
        ffi.binding("dup", Impl.second),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);

    const before_records = rt.external_host_functions.len;
    try std.testing.expectError(error.DuplicateBindingName, installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{}));
    try std.testing.expectEqual(before_records, rt.external_host_functions.len);

    const dup_atom = try rt.internAtom("dup");
    defer rt.atoms.free(dup_atom);
    try std.testing.expect(!target.hasOwnProperty(dup_atom));
}

test "runtime Plugin install rejects non-configurable overwrite" {
    const Impl = struct {
        fn noop(call: ffi.ZigCall) void {
            _ = call;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-overwrite-test", .{
        ffi.binding("add", Impl.noop),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);

    const add_atom = try rt.internAtom("add");
    defer rt.atoms.free(add_atom);
    try target.defineOwnProperty(rt, add_atom, core.Descriptor.data(core.JSValue.int32(1), true, true, false));

    try std.testing.expectError(error.IncompatibleDescriptor, installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{ .overwrite = true }));
}

test "runtime Plugin overwrite replaces configurable own properties" {
    const Impl = struct {
        fn answer(call: ffi.ZigCall) i32 {
            _ = call;
            return 5;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-overwrite-success-test", .{
        ffi.binding("add", Impl.answer),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);

    const add_atom = try rt.internAtom("add");
    defer rt.atoms.free(add_atom);
    try target.defineOwnProperty(rt, add_atom, core.Descriptor.data(core.JSValue.int32(1), false, false, true));

    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{ .overwrite = true });

    const overwritten = (try target.getOwnProperty(rt, add_atom)).?;
    defer overwritten.destroy(rt);
    try std.testing.expect(overwritten.value.isObject());
    try std.testing.expectEqual(true, overwritten.writable.?);
    try std.testing.expectEqual(true, overwritten.enumerable.?);
    try std.testing.expectEqual(true, overwritten.configurable.?);

    const global = try ctx.globalObject();
    const native_atom = try rt.internAtom("native");
    defer rt.atoms.free(native_atom);
    try global.defineOwnProperty(rt, native_atom, core.Descriptor.data(target_value, true, true, true));

    const result = try ctx.eval("native.add()", .{});
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 5), result.asInt32().?);
}

test "runtime Plugin rollback restores overwritten descriptors" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);

    const add_atom = try rt.internAtom("add");
    const mul_atom = try rt.internAtom("mul");
    defer rt.atoms.free(add_atom);
    defer rt.atoms.free(mul_atom);

    try target.defineOwnProperty(rt, add_atom, core.Descriptor.data(core.JSValue.int32(1), false, false, true));

    var atoms = [_]core.Atom{ add_atom, mul_atom };
    var originals = [_]?core.Descriptor{
        (try target.getOwnProperty(rt, add_atom)).?,
        null,
    };
    defer destroyOriginalDescriptors(rt, originals[0..]);

    try target.defineOwnProperty(rt, add_atom, core.Descriptor.data(core.JSValue.int32(7), true, true, true));
    try target.defineOwnProperty(rt, mul_atom, core.Descriptor.data(core.JSValue.int32(9), true, true, true));

    rollbackDefinedProperties(rt, target, atoms[0..], originals[0..]);

    const restored = (try target.getOwnProperty(rt, add_atom)).?;
    defer restored.destroy(rt);
    try std.testing.expectEqual(@as(?i32, 1), restored.value.asInt32());
    try std.testing.expectEqual(false, restored.writable.?);
    try std.testing.expectEqual(false, restored.enumerable.?);
    try std.testing.expectEqual(true, restored.configurable.?);
    try std.testing.expect(!target.hasOwnProperty(mul_atom));
}

test "runtime Plugin host class release frees prototypes and unregisters classes" {
    const Hooks = struct {
        fn finalize(context: ?*anyopaque, object: ffi.OpaqueHostObject) callconv(.c) void {
            _ = context;
            _ = object;
        }
    };

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const descriptor = ffi.hostObject("RollbackHost", ffi.HostTypeId.named("test.RollbackHost"), .{
        .owner = .js,
        .finalizer = Hooks.finalize,
    });
    const class_id = try rt.newClassId(core.class.invalid_class_id);
    try rt.ensureContextClassPrototypeCapacity(class_id);
    try rt.classes.register(class_id, .{
        .class_name = descriptor.name.slice(),
        .binding_identity = opaque_host_object_identity,
        .payload_finalizer = opaquePayloadFinalizer,
        .payload_mark = opaquePayloadMark,
    });

    const prototype = try core.Object.create(rt, core.class.ids.object, null);
    const prototype_value = prototype.value();
    try ctx.setClassPrototype(class_id, prototype);
    prototype_value.free(rt);

    var host_classes = [_]HostClass{.{ .class_id = class_id, .descriptor = &descriptor }};
    releaseHostClassEntries(rt, host_classes[0..]);

    try std.testing.expect(!rt.classes.isRegistered(class_id));
    try std.testing.expect(ctx.classPrototypeObject(class_id) == null);
}

test "runtime Plugin install rejects host object descriptors without bindings" {
    const TestPlugin = ffi.Plugin("runtime-host-object-only-test", .{
        ffi.hostObject("OrphanHost", ffi.HostTypeId.named("test.OrphanHost"), .{ .owner = .host }),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);

    try std.testing.expectError(error.HostObjectsRequireBindings, installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{}));
    try std.testing.expect(rt.classes.findByName("OrphanHost") == null);
}

test "runtime Plugin install rolls back host classes when later binding preparation fails" {
    const Hooks = struct {
        const type_id = ffi.HostTypeId.named("test.RollbackPreparedHost");

        fn noop(call: ffi.ZigCall) void {
            _ = call;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-host-class-late-rollback-test", .{
        ffi.hostObject("RollbackPreparedHost", Hooks.type_id, .{ .owner = .host }),
        ffi.bindingWithOptions("tooLong", Hooks.noop, .{ .length = std.math.maxInt(u32) }),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);

    try std.testing.expectError(error.BindingLengthOverflow, installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{}));
    try std.testing.expect(rt.classes.findByName("RollbackPreparedHost") == null);
}

test "runtime Plugin install tombstones external host records on binding preparation rollback" {
    const Hooks = struct {
        fn noop(call: ffi.ZigCall) void {
            _ = call;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-binding-record-rollback-test", .{
        ffi.binding("ok", Hooks.noop),
        ffi.bindingWithOptions("tooLong", Hooks.noop, .{ .length = std.math.maxInt(u32) }),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);

    _ = try exec.zjs_vm.contextGlobal(ctx.core);
    const base_external_count = rt.external_host_functions.len;
    try std.testing.expectError(error.BindingLengthOverflow, installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{}));

    const ok_atom = try rt.internAtom("ok");
    defer rt.atoms.free(ok_atom);
    try std.testing.expect(!target.hasOwnProperty(ok_atom));
    const too_long_atom = try rt.internAtom("tooLong");
    defer rt.atoms.free(too_long_atom);
    try std.testing.expect(!target.hasOwnProperty(too_long_atom));

    try std.testing.expectEqual(base_external_count + 1, rt.external_host_functions.len);
    const record = rt.externalHostFunction(@intCast(base_external_count + 1)) orelse return error.TestExpectedEqual;
    try std.testing.expect(record.ptr == @as(*anyopaque, @ptrCast(&tombstone_context)));
    try std.testing.expect(record.finalizer == null);
    try std.testing.expectError(error.TypeError, record.call(record.ptr, .{
        .realm = ctx.core,
        .output = null,
        .func_obj = target,
        .this_value = core.JSValue.undefinedValue(),
        .args = &.{},
    }));
}

test "runtime Plugin releases committed host classes with external host records" {
    const Hooks = struct {
        const type_id = ffi.HostTypeId.named("test.ReleaseCommittedHost");

        fn noop(call: ffi.ZigCall) void {
            _ = call;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-host-class-release-test", .{
        ffi.hostObject("ReleaseCommittedHost", Hooks.type_id, .{ .owner = .host }),
        ffi.binding("noop", Hooks.noop),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);

    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});
    try std.testing.expect(rt.classes.findByName("ReleaseCommittedHost") != null);

    rt.clearExternalHostFunctions();
    rt.drainDeferredNativeCleanups();

    try std.testing.expect(rt.classes.findByName("ReleaseCommittedHost") == null);
}

test "runtime Plugin install resolves prop-name descriptors without mutating target" {
    const TestPlugin = ffi.Plugin("runtime-prop-name-test", .{
        ffi.propName("cached"),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    try std.testing.expectError(error.InvalidTarget, installDescriptorForTesting(ctx, core.JSValue.int32(1), TestPlugin.descriptor(), .{}));

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);
    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});
    const cached_atom = try rt.internAtom("cached");
    defer rt.atoms.free(cached_atom);
    try std.testing.expect(!target.hasOwnProperty(cached_atom));
}

test "runtime Plugin exposes resolved prop-name descriptors through HostServices" {
    const Impl = struct {
        fn name(frame: *ffi.CallFrame) ffi.Status {
            const services = (frame.services orelse return .unsupported).propNameServices() orelse return .unsupported;
            var prop_name = ffi.PropNameID{};
            const status = services.get(frame, 0, &prop_name);
            if (status != .ok) return status;
            const call = ffi.ZigCall.fromFrame(frame) catch return .type_error;
            const name_text = prop_name.debugName(call.ctx.runtimePtr()) orelse return .generic_error;
            const name_value = (core.string.String.createAscii(call.ctx.runtimePtr(), name_text) catch return .out_of_memory).value();
            frame.result = name_value;
            return .ok;
        }

        fn missing(frame: *ffi.CallFrame) ffi.Status {
            const services = (frame.services orelse return .unsupported).propNameServices() orelse return .unsupported;
            var prop_name = ffi.PropNameID{};
            return services.get(frame, 1, &prop_name);
        }
    };
    const TestPlugin = ffi.Plugin("runtime-prop-name-service-test", .{
        ffi.propName("cached"),
        ffi.binding("name", Impl.name),
        ffi.binding("missing", Impl.missing),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);
    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const global = try ctx.globalObject();
    const native_atom = try rt.internAtom("native");
    defer rt.atoms.free(native_atom);
    try global.defineOwnProperty(rt, native_atom, core.Descriptor.data(target_value, true, true, true));

    const name = try ctx.eval("native.name()", .{});
    defer name.free(rt);
    const name_text = try name.asString().?.toOwnedUtf8(std.testing.allocator);
    defer std.testing.allocator.free(name_text);
    try std.testing.expectEqualStrings("cached", name_text);

    try std.testing.expectError(error.JSException, ctx.eval("native.missing()", .{}));
    var exception = ctx.takePendingException();
    defer exception.free(rt);
    try expectErrorObjectProperty(rt, exception, "name", "RangeError");
    try expectErrorObjectProperty(rt, exception, "message", "plugin property name index 1 is out of range");
}

test "runtime Plugin call copies error_message into thrown JS error" {
    const Impl = struct {
        fn fail(frame: *ffi.CallFrame) ffi.Status {
            frame.error_message = ffi.BorrowedBytes.from("plugin says no");
            return .type_error;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-error-message-test", .{
        ffi.binding("fail", Impl.fail),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);
    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const global = try ctx.globalObject();
    const native_atom = try rt.internAtom("native");
    defer rt.atoms.free(native_atom);
    try global.defineOwnProperty(rt, native_atom, core.Descriptor.data(target_value, true, true, true));

    const result = try ctx.eval("try { native.fail(); 'missing'; } catch (e) { e.name + ':' + e.message; }", .{});
    defer result.free(rt);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try exec.value_ops.appendRawString(rt, &bytes, result);
    try std.testing.expectEqualStrings("TypeError:plugin says no", bytes.items);
}

test "runtime Plugin status without messages maps to JavaScript error classes" {
    const Impl = struct {
        fn failReference(frame: *ffi.CallFrame) ffi.Status {
            _ = frame;
            return .reference_error;
        }

        fn failEval(frame: *ffi.CallFrame) ffi.Status {
            _ = frame;
            return .eval_error;
        }

        fn failUri(frame: *ffi.CallFrame) ffi.Status {
            _ = frame;
            return .uri_error;
        }

        fn failUnsupported(frame: *ffi.CallFrame) ffi.Status {
            _ = frame;
            return .unsupported;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-status-error-class-test", .{
        ffi.binding("failReference", Impl.failReference),
        ffi.binding("failEval", Impl.failEval),
        ffi.binding("failUri", Impl.failUri),
        ffi.binding("failUnsupported", Impl.failUnsupported),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);
    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const global = try ctx.globalObject();
    const native_atom = try rt.internAtom("native");
    defer rt.atoms.free(native_atom);
    try global.defineOwnProperty(rt, native_atom, core.Descriptor.data(target_value, true, true, true));

    const result = try ctx.eval(
        \\var out = [];
        \\for (var name of ["failReference", "failEval", "failUri", "failUnsupported"]) {
        \\  try { native[name](); out.push("missing"); }
        \\  catch (e) { out.push(e.name + ":" + e.message); }
        \\}
        \\out.join(",");
    , .{});
    defer result.free(rt);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try exec.value_ops.appendRawString(rt, &bytes, result);
    try std.testing.expectEqualStrings("ReferenceError:,EvalError:,URIError:,Error:Unsupported", bytes.items);
}

test "runtime Plugin failed raw CallFrame calls do not free borrowed result values" {
    const Impl = struct {
        fn fail(frame: *ffi.CallFrame) ffi.Status {
            const args = frame.args.slice();
            if (args.len != 1) return .type_error;
            frame.result = args[0];
            frame.error_message = ffi.BorrowedBytes.from("borrowed result is not owned on failure");
            return .type_error;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-failed-result-borrow-test", .{
        ffi.bindingWithOptions("fail", Impl.fail, .{ .length = 1 }),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);
    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const fail_atom = try rt.internAtom("fail");
    defer rt.atoms.free(fail_atom);
    const fail_value = try target.getProperty(fail_atom);
    defer fail_value.free(rt);

    const sentinel = try core.Object.create(rt, core.class.ids.object, null);
    const sentinel_value = sentinel.value();
    const retained_sentinel = sentinel_value.dup();
    defer retained_sentinel.free(rt);
    defer sentinel_value.free(rt);

    const before_rc = sentinel.header.meta().rc;
    var args = [_]core.JSValue{sentinel_value};
    try std.testing.expectError(error.JSException, exec.call.callValue(ctx.core, null, fail_value, &args));
    try std.testing.expect(ctx.hasException());
    ctx.clearException();
    try std.testing.expectEqual(before_rc, sentinel.header.meta().rc);
}

test "runtime Plugin maps unknown status values to generic errors" {
    const Impl = struct {
        fn fail(frame: *ffi.CallFrame) ffi.Status {
            frame.error_message = ffi.BorrowedBytes.from("unknown plugin status");
            return @enumFromInt(99);
        }
    };
    const TestPlugin = ffi.Plugin("runtime-unknown-status-test", .{
        ffi.binding("fail", Impl.fail),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);
    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const global = try ctx.globalObject();
    const native_atom = try rt.internAtom("native");
    defer rt.atoms.free(native_atom);
    try global.defineOwnProperty(rt, native_atom, core.Descriptor.data(target_value, true, true, true));

    const result = try ctx.eval("try { native.fail(); 'missing'; } catch (e) { e.name + ':' + e.message; }", .{});
    defer result.free(rt);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try exec.value_ops.appendRawString(rt, &bytes, result);
    try std.testing.expectEqualStrings("Error:unknown plugin status", bytes.items);
}

test "runtime Plugin ignores invalid non-empty error messages" {
    const Impl = struct {
        fn fail(frame: *ffi.CallFrame) ffi.Status {
            frame.error_message = .{ .ptr = null, .len = 4 };
            return .generic_error;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-invalid-error-message-test", .{
        ffi.binding("fail", Impl.fail),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);
    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const global = try ctx.globalObject();
    const native_atom = try rt.internAtom("native");
    defer rt.atoms.free(native_atom);
    try global.defineOwnProperty(rt, native_atom, core.Descriptor.data(target_value, true, true, true));

    const result = try ctx.eval("try { native.fail(); 'missing'; } catch (e) { e.name + ':' + e.message; }", .{});
    defer result.free(rt);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try exec.value_ops.appendRawString(rt, &bytes, result);
    try std.testing.expectEqualStrings("Error:GenericError", bytes.items);
}

test "runtime Plugin invalid utf8 error messages fall back to status names" {
    const Impl = struct {
        const invalid = [_]u8{0xff};

        fn fail(frame: *ffi.CallFrame) ffi.Status {
            frame.error_message = ffi.BorrowedBytes.from(&invalid);
            return .type_error;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-invalid-utf8-error-message-test", .{
        ffi.binding("fail", Impl.fail),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);
    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const global = try ctx.globalObject();
    const native_atom = try rt.internAtom("native");
    defer rt.atoms.free(native_atom);
    try global.defineOwnProperty(rt, native_atom, core.Descriptor.data(target_value, true, true, true));

    const result = try ctx.eval("try { native.fail(); 'missing'; } catch (e) { e.name + ':' + e.message; }", .{});
    defer result.free(rt);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try exec.value_ops.appendRawString(rt, &bytes, result);
    try std.testing.expectEqualStrings("TypeError:TypeError", bytes.items);
}

test "runtime Plugin treats ok return with non-ok frame error_status as failure" {
    const Impl = struct {
        fn fail(frame: *ffi.CallFrame) ffi.Status {
            frame.result = core.JSValue.int32(123);
            frame.error_status = .range_error;
            frame.error_message = ffi.BorrowedBytes.from("explicit error status");
            return .ok;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-explicit-error-status-test", .{
        ffi.binding("fail", Impl.fail),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);
    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const global = try ctx.globalObject();
    const native_atom = try rt.internAtom("native");
    defer rt.atoms.free(native_atom);
    try global.defineOwnProperty(rt, native_atom, core.Descriptor.data(target_value, true, true, true));

    const result = try ctx.eval("try { native.fail(); 'missing'; } catch (e) { e.name + ':' + e.message; }", .{});
    defer result.free(rt);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try exec.value_ops.appendRawString(rt, &bytes, result);
    try std.testing.expectEqualStrings("RangeError:explicit error status", bytes.items);
}

test "runtime Plugin out_of_memory status materializes the runtime OOM exception and ignores borrowed messages" {
    const Impl = struct {
        fn fail(frame: *ffi.CallFrame) ffi.Status {
            frame.error_message = ffi.BorrowedBytes.from("must not allocate an Error for OOM");
            return .out_of_memory;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-oom-status-test", .{
        ffi.binding("fail", Impl.fail),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);
    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const fail_atom = try rt.internAtom("fail");
    defer rt.atoms.free(fail_atom);
    const fail_value = try target.getProperty(fail_atom);
    defer fail_value.free(rt);

    try std.testing.expect(!ctx.hasException());
    try std.testing.expectError(error.OutOfMemory, exec.call.callValue(ctx.core, null, fail_value, &.{}));
    try std.testing.expect(ctx.hasException());
    var exception = ctx.takePendingException();
    defer exception.free(rt);
    try std.testing.expect(!ctx.hasException());
    try expectErrorObjectProperty(rt, exception, "name", "InternalError");
    try expectErrorObjectProperty(rt, exception, "message", "out of memory");
}

test "runtime Plugin pending_exception preserves an existing pending exception" {
    const Impl = struct {
        fn fail(frame: *ffi.CallFrame) ffi.Status {
            const ctx = frame.borrowContext() catch return .type_error;
            const thrown = (core.string.String.createAscii(ctx.runtimePtr(), "pending from plugin") catch return .out_of_memory).value();
            _ = ctx.throwValue(thrown);
            frame.error_message = ffi.BorrowedBytes.from("must not replace pending exception");
            return .pending_exception;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-pending-exception-test", .{
        ffi.binding("fail", Impl.fail),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);
    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const global = try ctx.globalObject();
    const native_atom = try rt.internAtom("native");
    defer rt.atoms.free(native_atom);
    try global.defineOwnProperty(rt, native_atom, core.Descriptor.data(target_value, true, true, true));

    const result = try ctx.eval("try { native.fail(); 'missing'; } catch (e) { e; }", .{});
    defer result.free(rt);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try exec.value_ops.appendRawString(rt, &bytes, result);
    try std.testing.expectEqualStrings("pending from plugin", bytes.items);
}

test "runtime Plugin pending_exception without a pending value maps to generic errors" {
    const Impl = struct {
        fn fail(frame: *ffi.CallFrame) ffi.Status {
            _ = frame;
            return .pending_exception;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-empty-pending-exception-test", .{
        ffi.binding("fail", Impl.fail),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);
    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const global = try ctx.globalObject();
    const native_atom = try rt.internAtom("native");
    defer rt.atoms.free(native_atom);
    try global.defineOwnProperty(rt, native_atom, core.Descriptor.data(target_value, true, true, true));

    const result = try ctx.eval("try { native.fail(); 'missing'; } catch (e) { e.name + ':' + e.message; }", .{});
    defer result.free(rt);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try exec.value_ops.appendRawString(rt, &bytes, result);
    try std.testing.expectEqualStrings("Error:GenericError", bytes.items);
}

test "runtime Plugin pending_exception without a pending value ignores error messages" {
    const Impl = struct {
        fn fail(frame: *ffi.CallFrame) ffi.Status {
            frame.error_message = ffi.BorrowedBytes.from("must not be used");
            return .pending_exception;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-empty-pending-exception-message-test", .{
        ffi.binding("fail", Impl.fail),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);
    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const global = try ctx.globalObject();
    const native_atom = try rt.internAtom("native");
    defer rt.atoms.free(native_atom);
    try global.defineOwnProperty(rt, native_atom, core.Descriptor.data(target_value, true, true, true));

    const result = try ctx.eval("try { native.fail(); 'missing'; } catch (e) { e.name + ':' + e.message; }", .{});
    defer result.free(rt);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try exec.value_ops.appendRawString(rt, &bytes, result);
    try std.testing.expectEqualStrings("Error:GenericError", bytes.items);
}

test "runtime Plugin create opaque service rejects invalid host objects as TypeError" {
    const Hooks = struct {
        var native: u8 = 0;
        const type_id = ffi.HostTypeId.named("test.ValidCreateOpaque");
        const unknown_type_id = ffi.HostTypeId.named("test.UnknownCreateOpaque");

        fn finalize(context: ?*anyopaque, object: ffi.OpaqueHostObject) callconv(.c) void {
            _ = context;
            _ = object;
        }

        fn makeNull(frame: *ffi.CallFrame) ffi.Status {
            const services = (frame.services orelse return .unsupported).opaqueObjectServices() orelse return .unsupported;
            return services.create(frame, .{ .ptr = null, .type_id = type_id }, &frame.result);
        }

        fn makeUnknown(frame: *ffi.CallFrame) ffi.Status {
            const services = (frame.services orelse return .unsupported).opaqueObjectServices() orelse return .unsupported;
            return services.create(frame, ffi.OpaqueHostObject.from(@ptrCast(&native), unknown_type_id), &frame.result);
        }
    };
    const TestPlugin = ffi.Plugin("runtime-create-opaque-error-test", .{
        ffi.hostObject("ValidCreateOpaque", Hooks.type_id, .{
            .owner = .js,
            .finalizer = Hooks.finalize,
        }),
        ffi.binding("makeNull", Hooks.makeNull),
        ffi.binding("makeUnknown", Hooks.makeUnknown),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);
    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const global = try ctx.globalObject();
    const native_atom = try rt.internAtom("native");
    defer rt.atoms.free(native_atom);
    try global.defineOwnProperty(rt, native_atom, core.Descriptor.data(target_value, true, true, true));

    const result = try ctx.eval(
        \\var out = [];
        \\try { native.makeNull(); } catch (e) { out.push(e.name + ":" + e.message); }
        \\try { native.makeUnknown(); } catch (e) { out.push(e.name + ":" + e.message); }
        \\out.join(",");
    , .{});
    defer result.free(rt);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try exec.value_ops.appendRawString(rt, &bytes, result);
    const expected = try std.fmt.allocPrint(
        rt.memory.allocator,
        "TypeError:opaque host object pointer is null,TypeError:opaque host object type id 0x{x} is not declared by this plugin",
        .{Hooks.unknown_type_id.value},
    );
    defer rt.memory.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, bytes.items);
}

test "runtime Plugin unwrap opaque service reports expected and actual type diagnostics" {
    const Hooks = struct {
        var native: u8 = 0;
        const actual_type_id = ffi.HostTypeId.named("test.UnwrapActualOpaque");
        const expected_type_id = ffi.HostTypeId.named("test.UnwrapExpectedOpaque");

        fn make(frame: *ffi.CallFrame) ffi.Status {
            const services = (frame.services orelse return .unsupported).opaqueObjectServices() orelse return .unsupported;
            return services.create(frame, ffi.OpaqueHostObject.from(@ptrCast(&native), actual_type_id), &frame.result);
        }

        fn checkWrong(frame: *ffi.CallFrame) ffi.Status {
            const services = (frame.services orelse return .unsupported).opaqueObjectServices() orelse return .unsupported;
            const args = frame.args.slice();
            if (args.len != 1) return .type_error;
            var object: ffi.OpaqueHostObject = .{};
            return services.unwrap(frame, args[0], expected_type_id, &object);
        }

        fn checkInvalidExpected(frame: *ffi.CallFrame) ffi.Status {
            const services = (frame.services orelse return .unsupported).opaqueObjectServices() orelse return .unsupported;
            const args = frame.args.slice();
            if (args.len != 1) return .type_error;
            var object: ffi.OpaqueHostObject = .{};
            return services.unwrap(frame, args[0], .{}, &object);
        }
    };
    const TestPlugin = ffi.Plugin("runtime-unwrap-opaque-diagnostic-test", .{
        ffi.hostObject("UnwrapActualOpaque", Hooks.actual_type_id, .{ .owner = .host }),
        ffi.hostObject("UnwrapExpectedOpaque", Hooks.expected_type_id, .{ .owner = .host }),
        ffi.binding("make", Hooks.make),
        ffi.bindingWithOptions("checkWrong", Hooks.checkWrong, .{ .length = 1 }),
        ffi.bindingWithOptions("checkInvalidExpected", Hooks.checkInvalidExpected, .{ .length = 1 }),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);
    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const global = try ctx.globalObject();
    const native_atom = try rt.internAtom("native");
    defer rt.atoms.free(native_atom);
    try global.defineOwnProperty(rt, native_atom, core.Descriptor.data(target_value, true, true, true));

    const result = try ctx.eval(
        \\var out = [];
        \\try { native.checkWrong(native.make()); } catch (e) { out.push(e.name + ':' + e.message); }
        \\try { native.checkInvalidExpected(native.make()); } catch (e) { out.push(e.name + ':' + e.message); }
        \\out.join(",");
    , .{});
    defer result.free(rt);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try exec.value_ops.appendRawString(rt, &bytes, result);
    const expected = try std.fmt.allocPrint(
        rt.memory.allocator,
        "TypeError:opaque host object type mismatch: expected 0x{x}, actual 0x{x} (UnwrapActualOpaque),TypeError:expected opaque host object type id is invalid",
        .{ Hooks.expected_type_id.value, Hooks.actual_type_id.value },
    );
    defer rt.memory.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, bytes.items);
}

test "runtime Plugin nullable opaque references are represented as JS null" {
    const Hooks = struct {
        var native: u8 = 0;
        const type_id = ffi.HostTypeId.named("test.NullableRuntimeOpaque");

        fn finalize(context: ?*anyopaque, object: ffi.OpaqueHostObject) callconv(.c) void {
            _ = context;
            _ = object;
        }

        fn makeMaybe(frame: *ffi.CallFrame) ffi.Status {
            const services = (frame.services orelse return .unsupported).opaqueObjectServices() orelse return .unsupported;
            const args = frame.args.slice();
            const present = args.len != 0 and (args[0].asBool() orelse false);
            const ptr: ?*anyopaque = if (present) @ptrCast(&native) else null;
            const object = ffi.OpaqueHostObject.fromNullable(ptr, type_id) orelse {
                frame.result = core.JSValue.nullValue();
                return .ok;
            };
            return services.create(frame, object, &frame.result);
        }

        fn check(frame: *ffi.CallFrame) ffi.Status {
            const services = (frame.services orelse return .unsupported).opaqueObjectServices() orelse return .unsupported;
            const args = frame.args.slice();
            if (args.len != 1) return .type_error;
            var object: ffi.OpaqueHostObject = .{};
            const status = services.unwrap(frame, args[0], type_id, &object);
            if (status != .ok) return status;
            frame.result = core.JSValue.boolean(object.ptr == @as(*anyopaque, @ptrCast(&native)));
            return .ok;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-nullable-opaque-test", .{
        ffi.hostObject("NullableRuntimeOpaque", Hooks.type_id, .{
            .owner = .js,
            .finalizer = Hooks.finalize,
        }),
        ffi.bindingWithOptions("makeMaybe", Hooks.makeMaybe, .{ .length = 1 }),
        ffi.bindingWithOptions("check", Hooks.check, .{ .length = 1 }),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);
    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const global = try ctx.globalObject();
    const native_atom = try rt.internAtom("native");
    defer rt.atoms.free(native_atom);
    try global.defineOwnProperty(rt, native_atom, core.Descriptor.data(target_value, true, true, true));

    const result = try ctx.eval("native.makeMaybe(false) === null && native.check(native.makeMaybe(true))", .{});
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "runtime Plugin host services create and unwrap opaque host objects" {
    const Hooks = struct {
        var native: u8 = 0;
        var finalizer_calls: usize = 0;
        const type_id = ffi.HostTypeId.named("test.RuntimeOpaque");

        fn finalize(context: ?*anyopaque, object: ffi.OpaqueHostObject) callconv(.c) void {
            _ = context;
            if (object.ptr == @as(*anyopaque, @ptrCast(&native)) and object.type_id.value == type_id.value) {
                finalizer_calls += 1;
            }
        }

        fn make(frame: *ffi.CallFrame) ffi.Status {
            const services = (frame.services orelse return .unsupported).opaqueObjectServices() orelse return .unsupported;
            return services.create(frame, ffi.OpaqueHostObject.from(@ptrCast(&native), type_id), &frame.result);
        }

        fn check(frame: *ffi.CallFrame) ffi.Status {
            const services = (frame.services orelse return .unsupported).opaqueObjectServices() orelse return .unsupported;
            const args = frame.args.slice();
            if (args.len != 1) return .type_error;
            var object: ffi.OpaqueHostObject = .{};
            const status = services.unwrap(frame, args[0], type_id, &object);
            if (status != .ok) return status;
            frame.result = core.JSValue.boolean(object.ptr == @as(*anyopaque, @ptrCast(&native)));
            return .ok;
        }
    };
    Hooks.finalizer_calls = 0;

    const TestPlugin = ffi.Plugin("runtime-opaque-test", .{
        ffi.hostObject("RuntimeOpaque", Hooks.type_id, .{
            .owner = .js,
            .finalizer = Hooks.finalize,
        }),
        ffi.binding("make", Hooks.make),
        ffi.bindingWithOptions("check", Hooks.check, .{ .length = 1 }),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);

    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const global = try ctx.globalObject();
    const native_atom = try rt.internAtom("native");
    defer rt.atoms.free(native_atom);
    try global.defineOwnProperty(rt, native_atom, core.Descriptor.data(target_value, true, true, true));

    const result = try ctx.eval("native.check(native.make())", .{});
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);

    _ = try rt.forceMajorGC(null);
    rt.drainDeferredClassPayloadFinalizers();
    try std.testing.expectEqual(@as(usize, 1), Hooks.finalizer_calls);
}

test "runtime Plugin synchronous opaque wrapper finalizers release traced payload roots before free returns" {
    const State = struct {
        rt: *core.JSRuntime,
        slot: core.JSValue = core.JSValue.undefinedValue(),
        trace_calls: usize = 0,
        finalizer_calls: usize = 0,

        const type_id = ffi.HostTypeId.named("test.RuntimeOpaqueTraceRoot");
        var active: ?*@This() = null;

        fn finalize(context: ?*anyopaque, object: ffi.OpaqueHostObject) callconv(.c) void {
            _ = context;
            _ = object;
            const self = active orelse return;
            self.finalizer_calls += 1;
            self.slot.free(self.rt);
            self.slot = core.JSValue.undefinedValue();
        }

        fn trace(context: ?*anyopaque, object: ffi.OpaqueHostObject, visitor: *ffi.HostTraceVisitor) callconv(.c) void {
            _ = context;
            _ = object;
            const self = active orelse return;
            self.trace_calls += 1;
            visitor.value(&self.slot);
        }

        fn make(frame: *ffi.CallFrame) ffi.Status {
            const services = (frame.services orelse return .unsupported).opaqueObjectServices() orelse return .unsupported;
            const self = active orelse return .type_error;
            return services.create(frame, ffi.OpaqueHostObject.from(@ptrCast(self), type_id), &frame.result);
        }
    };

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    var state = State{ .rt = rt };
    State.active = &state;
    defer State.active = null;

    const child = try core.Object.create(rt, core.class.ids.object, null);
    const child_header = &child.header;
    state.slot = child.value().dup();
    child.value().free(rt);

    const TestPlugin = ffi.Plugin("runtime-opaque-trace-root-test", .{
        ffi.hostObject("RuntimeOpaqueTraceRoot", State.type_id, .{
            .owner = .js,
            .finalizer = State.finalize,
            .tracer = State.trace,
        }),
        ffi.binding("make", State.make),
    });

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);
    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const make_atom = try rt.internAtom("make");
    defer rt.atoms.free(make_atom);
    const make_value = try target.getProperty(make_atom);
    defer make_value.free(rt);

    const wrapper = try exec.call.callValue(ctx.core, null, make_value, &.{});
    _ = try rt.forceMajorGC(null);
    try std.testing.expect(state.trace_calls > 0);
    try std.testing.expectEqual(@as(usize, 0), state.finalizer_calls);

    wrapper.free(rt);
    try std.testing.expectEqual(@as(usize, 0), rt.pendingDeferredClassPayloadFinalizerCountForTest());
    try std.testing.expectEqual(@as(usize, 1), state.finalizer_calls);
    try std.testing.expect(state.slot.isUndefined());
    try std.testing.expect(!rt.gc.containsHeader(child_header));

    rt.drainDeferredClassPayloadFinalizers();
    try std.testing.expectEqual(@as(usize, 1), state.finalizer_calls);
}

test "runtime Plugin closes only after synchronous wrapper callbacks release the class generation" {
    const State = struct {
        rt: *core.JSRuntime,
        ctx: *core.JSContext,
        class_id: core.ClassId = core.class.invalid_class_id,
        closed: bool = false,
        close_count: usize = 0,
        trace_calls: usize = 0,
        finalizer_calls: usize = 0,
        callbacks_after_close: usize = 0,
        event_sequence: usize = 0,
        finalizer_order: usize = 0,
        close_order: usize = 0,
        close_saw_drained_pins: bool = false,
        close_saw_class_removed: bool = false,
        close_saw_slot_cleared: bool = false,

        const type_id = ffi.HostTypeId.named("test.RuntimeOpaqueQueuedClose");
        var active: ?*@This() = null;

        fn finalize(_: ?*anyopaque, _: ffi.OpaqueHostObject) callconv(.c) void {
            const self = active orelse return;
            if (self.closed) self.callbacks_after_close += 1;
            self.finalizer_calls += 1;
            self.event_sequence += 1;
            self.finalizer_order = self.event_sequence;
        }

        fn trace(_: ?*anyopaque, _: ffi.OpaqueHostObject, _: *ffi.HostTraceVisitor) callconv(.c) void {
            const self = active orelse return;
            if (self.closed) self.callbacks_after_close += 1;
            self.trace_calls += 1;
        }

        fn noop(call: ffi.ZigCall) void {
            _ = call;
        }

        fn observeClose(plugin: *InstalledPlugin) void {
            const self = active orelse return;
            self.closed = true;
            self.close_count += 1;
            self.event_sequence += 1;
            self.close_order = self.event_sequence;
            self.close_saw_drained_pins = plugin.closed and
                plugin.owner_ref_count == 0 and
                plugin.definition_ref_count == 0 and
                plugin.execution_pin_count == 0;
            self.close_saw_class_removed = !self.rt.classes.isRegistered(self.class_id);
            self.close_saw_slot_cleared = self.ctx.classPrototypeObject(self.class_id) == null;
        }
    };
    const TestPlugin = ffi.Plugin("runtime-opaque-queued-close-test", .{
        ffi.hostObject("RuntimeOpaqueQueuedClose", State.type_id, .{
            .owner = .js,
            .finalizer = State.finalize,
            .tracer = State.trace,
        }),
        ffi.binding("noop", State.noop),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var state = State{ .rt = rt, .ctx = ctx };
    State.active = &state;
    defer State.active = null;

    const plugin = try InstalledPlugin.create(rt, "<opaque-queued-close>", TestPlugin.descriptor(), null);
    var staging_owner_live = true;
    defer if (staging_owner_live) plugin.release();
    plugin.close_observer = State.observeClose;
    try installHostClasses(ctx, plugin);
    state.class_id = plugin.host_classes[0].class_id;

    const wrapper = try createOpaqueObjectValue(ctx, plugin, ffi.OpaqueHostObject.from(@ptrCast(&state), State.type_id));
    plugin.release();
    staging_owner_live = false;
    wrapper.free(rt);

    try std.testing.expectEqual(@as(usize, 0), rt.pendingDeferredClassPayloadFinalizerCountForTest());
    try std.testing.expectEqual(@as(usize, 1), state.finalizer_calls);
    try std.testing.expectEqual(@as(usize, 1), state.close_count);
    try std.testing.expect(state.finalizer_order < state.close_order);
    try std.testing.expectEqual(@as(usize, 0), state.callbacks_after_close);
    try std.testing.expectEqual(@as(usize, 0), state.trace_calls);
    try std.testing.expect(state.close_saw_drained_pins);
    try std.testing.expect(state.close_saw_class_removed);
    try std.testing.expect(state.close_saw_slot_cleared);

    rt.drainDeferredClassPayloadFinalizers();
    try std.testing.expectEqual(@as(usize, 1), state.finalizer_calls);
    try std.testing.expectEqual(@as(usize, 1), state.close_count);
}

test "runtime Plugin runtime destroy does not repeat synchronous opaque wrapper finalizers" {
    const State = struct {
        finalizer_calls: usize = 0,

        const type_id = ffi.HostTypeId.named("test.RuntimeOpaqueDestroyDrain");
        var active: ?*@This() = null;

        fn finalize(context: ?*anyopaque, object: ffi.OpaqueHostObject) callconv(.c) void {
            _ = context;
            _ = object;
            const self = active orelse return;
            self.finalizer_calls += 1;
        }

        fn make(frame: *ffi.CallFrame) ffi.Status {
            const services = (frame.services orelse return .unsupported).opaqueObjectServices() orelse return .unsupported;
            const self = active orelse return .type_error;
            return services.create(frame, ffi.OpaqueHostObject.from(@ptrCast(self), type_id), &frame.result);
        }
    };

    var state = State{};
    State.active = &state;
    defer State.active = null;

    const TestPlugin = ffi.Plugin("runtime-opaque-destroy-drain-test", .{
        ffi.hostObject("RuntimeOpaqueDestroyDrain", State.type_id, .{
            .owner = .js,
            .finalizer = State.finalize,
        }),
        ffi.binding("make", State.make),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    const ctx = try zjs.JSContext.create(rt);

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const make_atom = try rt.internAtom("make");
    const make_value = try target.getProperty(make_atom);
    const wrapper = try exec.call.callValue(ctx.core, null, make_value, &.{});
    wrapper.free(rt);
    try std.testing.expectEqual(@as(usize, 0), rt.pendingDeferredClassPayloadFinalizerCountForTest());
    try std.testing.expectEqual(@as(usize, 1), state.finalizer_calls);

    make_value.free(rt);
    rt.atoms.free(make_atom);
    target_value.free(rt);
    ctx.destroy();
    rt.destroy();

    try std.testing.expectEqual(@as(usize, 1), state.finalizer_calls);
}

test "runtime Plugin host-owned opaque wrappers can trace without taking ownership" {
    const State = struct {
        slot: core.JSValue = core.JSValue.undefinedValue(),
        trace_calls: usize = 0,

        const type_id = ffi.HostTypeId.named("test.RuntimeOpaqueHostTrace");
        var active: ?*@This() = null;

        fn trace(context: ?*anyopaque, object: ffi.OpaqueHostObject, visitor: *ffi.HostTraceVisitor) callconv(.c) void {
            _ = context;
            _ = object;
            const self = active orelse return;
            self.trace_calls += 1;
            visitor.value(&self.slot);
        }

        fn make(frame: *ffi.CallFrame) ffi.Status {
            const services = (frame.services orelse return .unsupported).opaqueObjectServices() orelse return .unsupported;
            const self = active orelse return .type_error;
            return services.create(frame, ffi.OpaqueHostObject.from(@ptrCast(self), type_id), &frame.result);
        }
    };

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    var state = State{};
    State.active = &state;
    defer State.active = null;
    defer state.slot.free(rt);

    const child = try core.Object.create(rt, core.class.ids.object, null);
    const child_header = &child.header;
    state.slot = child.value().dup();
    child.value().free(rt);

    const TestPlugin = ffi.Plugin("runtime-opaque-host-trace-test", .{
        ffi.hostObject("RuntimeOpaqueHostTrace", State.type_id, .{
            .owner = .host,
            .tracer = State.trace,
        }),
        ffi.binding("make", State.make),
    });

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);
    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const make_atom = try rt.internAtom("make");
    defer rt.atoms.free(make_atom);
    const make_value = try target.getProperty(make_atom);
    defer make_value.free(rt);

    const wrapper = try exec.call.callValue(ctx.core, null, make_value, &.{});
    _ = try rt.forceMajorGC(null);
    try std.testing.expect(state.trace_calls > 0);
    const live_trace_calls = state.trace_calls;

    wrapper.free(rt);
    try std.testing.expectEqual(@as(usize, 0), rt.pendingDeferredClassPayloadFinalizerCountForTest());

    const Counter = struct {
        expected: *core.gc.Header,
        count: usize = 0,

        fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (slot.refHeader()) |header| {
                if (header == self.expected) self.count += 1;
            }
        }

        fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void {
            _ = context;
            _ = slot;
        }
    };

    var counter = Counter{ .expected = child_header };
    var visitor = core.runtime.RootVisitor{
        .context = &counter,
        .visit_value = Counter.visitValue,
        .visit_object = Counter.visitObject,
    };
    try rt.traceActiveRoots(&visitor);

    try std.testing.expectEqual(@as(usize, 0), counter.count);
    try std.testing.expectEqual(live_trace_calls, state.trace_calls);

    rt.drainDeferredClassPayloadFinalizers();
    try std.testing.expect(state.slot.isObject());
    try std.testing.expect(rt.gc.containsHeader(child_header));
}

test "runtime Plugin opaque wrappers expose only reference branding" {
    const Hooks = struct {
        var native: u8 = 0;
        const type_id = ffi.HostTypeId.named("test.RuntimeOpaqueShape");

        fn make(frame: *ffi.CallFrame) ffi.Status {
            const services = (frame.services orelse return .unsupported).opaqueObjectServices() orelse return .unsupported;
            return services.create(frame, ffi.OpaqueHostObject.from(@ptrCast(&native), type_id), &frame.result);
        }
    };

    const TestPlugin = ffi.Plugin("runtime-opaque-shape-test", .{
        ffi.hostObject("RuntimeOpaqueShape", Hooks.type_id, .{ .owner = .host }),
        ffi.binding("make", Hooks.make),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const target_value = target.value();
    defer target_value.free(rt);
    try installDescriptorForTesting(ctx, target_value, TestPlugin.descriptor(), .{});

    const global = try ctx.globalObject();
    const native_atom = try rt.internAtom("native");
    defer rt.atoms.free(native_atom);
    try global.defineOwnProperty(rt, native_atom, core.Descriptor.data(target_value, true, true, true));

    const result = try ctx.eval(
        \\const h = native.make();
        \\[
        \\  Object.keys(h).length,
        \\  Object.getOwnPropertyNames(h).length,
        \\  Object.prototype.toString.call(h),
        \\  typeof h.ptr,
        \\  typeof h.constructor
        \\].join("|");
    , .{});
    defer result.free(rt);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try exec.value_ops.appendRawString(rt, &bytes, result);
    try std.testing.expectEqualStrings("0|0|[object RuntimeOpaqueShape]|undefined|undefined", bytes.items);
}

test "runtime Plugin unwrap accepts opaque wrappers from another plugin with the same HostTypeId" {
    const Shared = struct {
        var native: u8 = 0;
        const type_id = ffi.HostTypeId.named("test.SharedOpaque");

        fn finalize(context: ?*anyopaque, object: ffi.OpaqueHostObject) callconv(.c) void {
            _ = context;
            _ = object;
        }

        fn make(frame: *ffi.CallFrame) ffi.Status {
            const services = (frame.services orelse return .unsupported).opaqueObjectServices() orelse return .unsupported;
            return services.create(frame, ffi.OpaqueHostObject.from(@ptrCast(&native), type_id), &frame.result);
        }

        fn check(frame: *ffi.CallFrame) ffi.Status {
            const services = (frame.services orelse return .unsupported).opaqueObjectServices() orelse return .unsupported;
            const args = frame.args.slice();
            if (args.len != 1) return .type_error;
            var object: ffi.OpaqueHostObject = .{};
            const status = services.unwrap(frame, args[0], type_id, &object);
            if (status != .ok) return status;
            frame.result = core.JSValue.boolean(object.ptr == @as(*anyopaque, @ptrCast(&native)));
            return .ok;
        }
    };

    const Producer = ffi.Plugin("producer", .{
        ffi.hostObject("SharedOpaqueProducer", Shared.type_id, .{
            .owner = .js,
            .finalizer = Shared.finalize,
        }),
        ffi.binding("make", Shared.make),
    });
    const Consumer = ffi.Plugin("consumer", .{
        ffi.bindingWithOptions("check", Shared.check, .{ .length = 1 }),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const producer = try core.Object.create(rt, core.class.ids.object, null);
    const producer_value = producer.value();
    defer producer_value.free(rt);
    try installDescriptorForTesting(ctx, producer_value, Producer.descriptor(), .{});

    const consumer = try core.Object.create(rt, core.class.ids.object, null);
    const consumer_value = consumer.value();
    defer consumer_value.free(rt);
    try installDescriptorForTesting(ctx, consumer_value, Consumer.descriptor(), .{});

    const global = try ctx.globalObject();
    const producer_atom = try rt.internAtom("producer");
    defer rt.atoms.free(producer_atom);
    try global.defineOwnProperty(rt, producer_atom, core.Descriptor.data(producer_value, true, true, true));
    const consumer_atom = try rt.internAtom("consumer");
    defer rt.atoms.free(consumer_atom);
    try global.defineOwnProperty(rt, consumer_atom, core.Descriptor.data(consumer_value, true, true, true));

    const result = try ctx.eval("consumer.check(producer.make())", .{});
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "runtime Plugin unwrap rejects opaque wrappers from another runtime" {
    const Shared = struct {
        var native: u8 = 0;
        const type_id = ffi.HostTypeId.named("test.CrossRuntimeOpaque");

        fn finalize(context: ?*anyopaque, object: ffi.OpaqueHostObject) callconv(.c) void {
            _ = context;
            _ = object;
        }

        fn make(frame: *ffi.CallFrame) ffi.Status {
            const services = (frame.services orelse return .unsupported).opaqueObjectServices() orelse return .unsupported;
            return services.create(frame, ffi.OpaqueHostObject.from(@ptrCast(&native), type_id), &frame.result);
        }
    };

    const Producer = ffi.Plugin("cross-runtime-producer", .{
        ffi.hostObject("CrossRuntimeOpaque", Shared.type_id, .{
            .owner = .js,
            .finalizer = Shared.finalize,
        }),
        ffi.binding("make", Shared.make),
    });

    const rt_a = try core.JSRuntime.create(std.testing.allocator);
    defer rt_a.destroy();
    const ctx_a = try zjs.JSContext.create(rt_a);
    defer ctx_a.destroy();

    const target_a = try core.Object.create(rt_a, core.class.ids.object, null);
    const target_a_value = target_a.value();
    defer target_a_value.free(rt_a);
    try installDescriptorForTesting(ctx_a, target_a_value, Producer.descriptor(), .{});

    const make_atom = try rt_a.internAtom("make");
    defer rt_a.atoms.free(make_atom);
    const make_value = try target_a.getProperty(make_atom);
    defer make_value.free(rt_a);
    const wrapper_a = try exec.call.callValue(ctx_a.core, null, make_value, &.{});
    defer wrapper_a.free(rt_a);

    const rt_b = try core.JSRuntime.create(std.testing.allocator);
    defer rt_b.destroy();
    const ctx_b = try zjs.JSContext.create(rt_b);
    defer ctx_b.destroy();

    const target_b = try core.Object.create(rt_b, core.class.ids.object, null);
    const target_b_value = target_b.value();
    defer target_b_value.free(rt_b);
    try installDescriptorForTesting(ctx_b, target_b_value, Producer.descriptor(), .{});

    try std.testing.expectError(error.TypeError, unwrapOpaqueObjectValue(rt_b, wrapper_a, Shared.type_id));
}
