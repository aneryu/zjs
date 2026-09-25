//! Public call entry, engine-global installation, and native builtin dispatch.
//!
//! Callee, receiver, and arguments are value snapshots; call paths must root
//! live inputs across GC and publish returned values before the next GC point.
//! Heap owners trace retained values. The import/alias wall preserves dispatch and
//! ownership seams across extracted builtin domains. The explicit
//! `ctx`/`output`/`global`/caller-function/caller-frame tuple is a measured call
//! ABI: do not republish it through shared context state, and keep hot dispatch
//! arms separate from cold host/error paths. Native calls follow
//! js_call_c_function and OP_call_method at quickjs.c.

const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const bytecode = @import("../bytecode.zig");

const construct_mod = @import("construct.zig");
const frame_mod = @import("frame.zig");
const globals_mod = core.global_slots;
const property_ops = @import("property_ops.zig");
const value_ops = @import("value_ops.zig");
const call_runtime = @import("call_runtime.zig");
const array_ops = @import("array_ops.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const error_stack_ops = @import("exception_ops.zig");
const exception_ops = @import("exception_ops.zig");

const object_ops = @import("object_ops.zig");
const unicode = @import("../libs/unicode.zig");
const std = @import("std");
const exceptions = @import("exception_ops.zig");
const HostError = exceptions.HostError;

// Construct ref for the String wrapper boxing path (`primitiveWrapper`). The
// String constructor record's construct branch forwards `args`/`new_target` to
// `constructWithPrototype`, so routing boxing through it (Phase 6b-3 STEP 6)
// keeps construction routed through the String native-record owner.
const string_construct_ref = core.function.NativeBuiltinRef{
    .domain = .string,
    .id = @intFromEnum(core.host_function.builtin_method_ids.string.ConstructorMethod.call),
};

fn hostResult(result: anytype) HostError!switch (@typeInfo(@TypeOf(result))) {
    .error_union => |info| info.payload,
    else => @compileError("hostResult expects an error union"),
} {
    return result catch |err| return @errorCast(err);
}

pub fn restoreEvalGlobalLexicals(
    ctx: *core.JSContext,
    global: *core.Object,
    saved_lexicals: ?*core.Object,
    keep_active_lexicals: bool,
) !void {
    const active_lexicals = ctx.lexicals;
    try global.setGlobalLexicals(ctx.runtime, active_lexicals);
    ctx.setLexicals(if (keep_active_lexicals) active_lexicals else saved_lexicals);
}

/// QuickJS source map: JS_CallInternal() dispatches callable objects after the
/// VM has prepared callee/argument values. This Zig slice currently owns the
/// host callables installed for the CLI-visible global object.
pub fn engineGlobalOwnPropertyCapacity(rt: *core.JSRuntime) usize {
    return rt.standardGlobalOwnPropertyCapacity() + 4; // globalThis, NaN, Infinity, undefined
}

pub fn contextGlobalOwnPropertyCapacity(rt: *core.JSRuntime) usize {
    return engineGlobalOwnPropertyCapacity(rt) + 1; // scriptArgs, installed by the public CLI host setup
}

pub fn installEngineGlobals(ctx: *core.JSContext, global: *core.Object) !void {
    const rt = ctx.runtime;
    try global.reserveOwnPropertyCapacityAssumingPlain(rt, engineGlobalOwnPropertyCapacity(rt));
    // Bind the explicitly supplied Realm before publishing lazy host slots.
    try ctx.installStandardGlobals(global);
    try defineGlobalThisProperty(rt, global);
    try defineNumberConstantPropertyAssumingNew(rt, global, "NaN", std.math.nan(f64));
    try defineNumberConstantPropertyAssumingNew(rt, global, "Infinity", std.math.inf(f64));
    try global.defineOwnPropertyAssumingNew(rt, core.atom.ids.undefined_, core.Descriptor.data(core.JSValue.undefinedValue(), .none));
}

fn predefinedStringAtom(comptime name: []const u8) core.Atom {
    return comptime core.atom.predefinedId(name, .string).?;
}

pub fn defineObjectProperty(rt: *core.JSRuntime, object: *core.Object, key: core.Atom, value: core.JSValue) !void {
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, .all));
}

fn defineGlobalThisProperty(rt: *core.JSRuntime, global: *core.Object) !void {
    try global.defineOwnPropertyAssumingNew(rt, core.atom.predefinedId("globalThis", .string).?, core.Descriptor.data(global.value(), .method));
}

fn defineConstantPropertyAssumingNew(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void {
    const key = try rt.internAtom(name);
    try object.defineOwnPropertyAssumingNew(rt, key, core.Descriptor.data(value, .none));
}

fn defineNumberConstantPropertyAssumingNew(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: f64) !void {
    const key = core.atom.predefinedId(name, .string) orelse {
        try defineConstantPropertyAssumingNew(rt, object, name, value_ops.numberToValue(value));
        return;
    };
    try object.defineOwnPropertyAssumingNew(rt, key, core.Descriptor.data(value_ops.numberToValue(value), .none));
}

pub fn expectCallableObject(value: core.JSValue) ?*core.Object {
    const header = value.refHeader() orelse return null;
    if (!value.is(.object)) return null;
    const object = core.Object.fromHeader(header);
    if (object.class_id != core.class.ids.c_function and
        object.class_id != core.class.ids.c_function_data and
        !core.class.isAsyncFunctionResumeClass(object.class_id) and
        !core.class.isBytecodeFunctionClass(object.class_id) and
        object.class_id != core.class.ids.bound_function) return null;
    return object;
}

pub fn activeGlobalObject(_: *core.JSRuntime, global: ?*core.Object, globals: []globals_mod.Slot) !?*core.Object {
    if (global) |global_object| return global_object;
    const global_value = globals_mod.getByAtom(globals, core.atom.ids.globalThis);
    return thisObject(global_value);
}

fn installTestStandardRealm(ctx: *core.JSContext) !*core.Object {
    const rt = ctx.runtime;

    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    rt.gc.generationalBarrier(&ctx.header, global.gcHeader());
    errdefer {
        ctx.rollbackIntrinsicBootstrap();
        ctx.global = null;
    }
    try ctx.installStandardGlobals(global);
    return global;
}

/// [[Call]] a getter/setter/toString only when a Realm global is available.
/// No-global accessors are data-plane leftovers: they must not [[Call]] JS (KD20).
fn callWithRealmGlobal(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    this_value: core.JSValue,
    callee: core.JSValue,
    args: []const core.JSValue,
) HostError!core.JSValue {
    const active_global = (try activeGlobalObject(ctx.runtime, global, globals)) orelse
        return error.InvalidBuiltinRegistry;
    return call_runtime.callValueOrBytecodeSyncInternalOutlined(
        ctx,
        output,
        active_global,
        this_value,
        callee,
        args,
        null,
        null,
    );
}

pub fn getValuePropertyViaGlobalSlots(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    receiver: core.JSValue,
    key: core.Atom,
) !core.JSValue {
    const receiver_value = try objectStaticToObjectValue(ctx, global, receiver);
    const object = try expectObjectArg(receiver_value);
    var cursor: ?*core.Object = object;
    while (cursor) |current| : (cursor = current.getPrototype()) {
        const desc = (try current.getOwnProperty(ctx.runtime, key)) orelse continue;
        return switch (desc.kind) {
            .data => desc.value,
            .generic => core.JSValue.undefinedValue(),
            .accessor => if (desc.getter.is(.undefined_value))
                core.JSValue.undefinedValue()
            else
                try callWithRealmGlobal(ctx, output, global, globals, receiver_value, desc.getter, &.{}),
        };
    }
    return core.JSValue.undefinedValue();
}

fn getValuePropertyProxyAware(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    receiver: core.JSValue,
    key: core.Atom,
) !core.JSValue {
    if (try activeGlobalObject(ctx.runtime, global, globals)) |global_object| {
        return object_ops.getValueProperty(ctx, output, global_object, receiver, key, null, null);
    }
    return getValuePropertyViaGlobalSlots(ctx, output, global, globals, receiver, key);
}

fn hasOwnPropertyProxyAware(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    object: *core.Object,
    key: core.Atom,
) !bool {
    if (try activeGlobalObject(ctx.runtime, global, globals)) |global_object| {
        const desc = try object_ops.proxyAwareOwnPropertyDescriptor(ctx, output, global_object, object, key, null, null);
        return desc != null;
    }
    return object.hasOwnProperty(key);
}

pub fn callNativeFunctionRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    this_value: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    if (function_object.nativeEntry()) |record| {
        return try builtin_dispatch.callInternalRecordDirect(
            ctx,
            output,
            global,
            globals,
            function_object,
            this_value,
            record,
            args,
            caller_function,
            caller_frame,
        );
    }
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse return null;
    if (try builtin_dispatch.callInternalRecord(ctx, output, global, globals, function_object, this_value, native_ref, args, caller_function, caller_frame)) |value| return value;
    return switch (native_ref.domain) {
        // Migrated to the internal record table (internal_builtins.table);
        // reaching here means the id is not installed, which only happens
        // for corrupt ids.
        .math, .json, .uri, .number, .date, .error_object, .function, .primitive, .iterator, .collection, .reflect, .buffer, .string, .object, .array, .regexp, .performance, .atomics, .promise, .weak_ref => error.TypeError,
        .host => blk: {
            const realm = try builtin_dispatch.finalCallableRealmView(ctx, function_object);
            break :blk try callHostGlobalNativeFunctionRecord(realm.realm, realm.global, this_value, function_object, native_ref.id, args);
        },
    };
}

/// `.host` native-builtin domain: host/web globals with no spec namespace
/// (navigator accessors, host constructor stubs, the shared species getter,
/// and CallSite methods). Bundled host functions use their own NativeEntry.
/// Replaces the retired string-name dispatch branches in `callNativeBuiltin`.
pub fn callHostGlobalNativeFunctionRecord(
    ctx: *core.JSContext,
    global: ?*core.Object,
    this_value: core.JSValue,
    _: *core.Object,
    id: u32,
    _: []const core.JSValue,
) HostError!core.JSValue {
    return switch (id) {
        @intFromEnum(core.function.HostGlobalMethod.navigator_user_agent_get) => try value_ops.createStringValue(ctx.runtime, core.function.navigator_user_agent),
        @intFromEnum(core.function.HostGlobalMethod.dom_exception_ctor_call) => {
            const active_global = global orelse return error.InvalidBuiltinRegistry;
            return exception_ops.throwTypeErrorMessage(ctx, active_global, "constructor requires 'new'");
        },
        @intFromEnum(core.function.HostGlobalMethod.species_getter) => this_value,
        @intFromEnum(core.function.HostGlobalMethod.callsite_get_function),
        @intFromEnum(core.function.HostGlobalMethod.callsite_get_function_name),
        @intFromEnum(core.function.HostGlobalMethod.callsite_get_file_name),
        @intFromEnum(core.function.HostGlobalMethod.callsite_get_line_number),
        @intFromEnum(core.function.HostGlobalMethod.callsite_get_column_number),
        @intFromEnum(core.function.HostGlobalMethod.callsite_is_native),
        => {
            const receiver = thisObject(this_value) orelse return error.TypeError;
            return exception_ops.callSiteMethodById(receiver, @enumFromInt(id)) orelse error.TypeError;
        },
        else => error.TypeError,
    };
}

/// `Function.prototype.bind` body. Stays in exec because `createBoundFunction`
/// and its proxy-aware property helpers are call.zig internals (covered by the
/// in-file tests); the `.function` domain record handler delegates here. The
/// VM's own bind fast path (call_runtime.callNativeBuiltinRecordForVm) also
/// routes back through this via callNativeFunctionRecord (BOTH).
pub fn functionBindCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    this_value: core.JSValue,
    args: []const core.JSValue,
) HostError!core.JSValue {
    if (thisObject(this_value) == null or !call_runtime.isCallableValue(this_value)) return error.TypeError;
    const bound_this = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const bound_args = if (args.len >= 1) args[1..] else args[0..0];
    return createBoundFunction(ctx, output, global, globals, this_value, bound_this, bound_args);
}

pub fn createRealmObject(parent: *core.JSContext) HostError!core.JSValue {
    const rt = parent.runtime;
    const child = core.JSContext.createConstructingWithOptions(rt, .{
        .stack_size = parent.stackLimit(),
        .track_unhandled_rejections = parent.track_unhandled_rejections,
    }) catch |err| switch (err) {
        // JS execution has already entered through the Runtime owner thread;
        // keep the host-call error surface free of an impossible contract
        // failure while the checked Context API still exposes it to embedders.
        error.WrongRuntimeThread => unreachable,
        else => |owner_err| return owner_err,
    };
    var child_owner = core.context.RealmRef.takeOwned(child);
    errdefer child_owner.deinit();

    const realm_global = try hostResult(child.globalObject());
    const realm = try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.object, null, 1);
    try realm.installOwnedRealmRef(rt, &child_owner);
    try defineObjectProperty(rt, realm, core.atom.ids.global, realm_global.value());
    return realm.value();
}

const ValueSliceRoot = array_ops.ValueSliceRoot;

// The `reflect construct roots argument list while resolving prototype` test,
// the `host global bootstrap ...` test, and the matching `engine eval host
// globals ...` test in `zjs_vm.zig` were relocated to `tests/exec.zig`
// during Phase 6b-3 STEP 7B. They build a bare `core.JSRuntime` and install the
// standard globals, which now flows through `rt.installStandardGlobals` and so
// needs the standard-global installer registered first; the bootstrap-integration
// tests live in the test tree so they exercise the public setup seam.

/// Bare-runtime (no realm global) `Object.*` data-plane fallback. JS Object
/// methods go through `.object` / `objectCallForNativeRecord`; this arm only
/// reads own data descriptors. Accessors do not [[Call]] getters.
pub fn callObjectStatic(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    const rt = ctx.runtime;
    if (id == @intFromEnum(method_ids.object.StaticMethod.assign)) {
        if (args.len < 1) return error.TypeError;
        const target_value = try objectStaticToObjectValue(ctx, global, args[0]);
        const target = try expectObjectArg(target_value);
        for (args[1..]) |source_arg| {
            if (source_arg.is(.null_value) or source_arg.is(.undefined_value)) continue;
            const source_value = try objectStaticToObjectValue(ctx, global, source_arg);
            const source = try expectObjectArg(source_value);
            const keys = try source.ownKeys(rt);
            defer core.Object.freeKeys(rt, keys);
            for (keys) |key| {
                const desc = (try source.getOwnProperty(rt, key)) orelse continue;
                if (desc.enumerable != true) continue;
                const value = try objectAssignGet(ctx, output, global, globals, source_value, desc);
                try objectAssignSet(ctx, output, global, globals, target_value, target, key, value);
            }
        }
        return target_value;
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.create)) {
        if (args.len < 1) return error.TypeError;
        const proto: ?*core.Object = if (args[0].is(.null_value))
            null
        else
            try expectObjectArg(args[0]);
        const object = try core.Object.create(rt, core.class.ids.object, proto);
        errdefer core.Object.destroyFromHeader(rt, object.gcHeader());
        if (args.len >= 2 and !args[1].is(.undefined_value)) {
            try definePropertiesFromObject(rt, object, args[1]);
        }
        return object.value();
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.is)) {
        const lhs = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const rhs = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
        return core.JSValue.boolean(lhs.sameValue(rhs));
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.keys)) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(ctx, global, args[0]);
        return core.object.ownEntriesArray(rt, object_value, .keys, if (global) |g| array_ops.arrayPrototypeFromGlobal(rt, g) else null);
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.values)) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(ctx, global, args[0]);
        return core.object.ownEntriesArray(rt, object_value, .values, if (global) |g| array_ops.arrayPrototypeFromGlobal(rt, g) else null);
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.entries)) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(ctx, global, args[0]);
        return core.object.ownEntriesArray(rt, object_value, .entries, if (global) |g| array_ops.arrayPrototypeFromGlobal(rt, g) else null);
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.get_own_property_descriptor)) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(ctx, global, args[0]);
        const object = try expectObjectArg(object_value);
        const key_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
        const key = try atomFromPropertyKey(rt, key_value);
        var desc = (try object.getOwnProperty(rt, key)) orelse return core.JSValue.undefinedValue();
        materializeMappedArgumentsDescriptorValue(rt, object, key, &desc);
        return descriptorObject(rt, desc);
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.get_own_property_descriptors)) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(ctx, global, args[0]);
        const object = try expectObjectArg(object_value);
        const keys = try object.ownKeys(rt);
        defer core.Object.freeKeys(rt, keys);
        const out = try core.Object.create(rt, core.class.ids.object, null);
        errdefer core.Object.destroyFromHeader(rt, out.gcHeader());
        for (keys) |key| {
            var desc = (try object.getOwnProperty(rt, key)) orelse continue;
            materializeMappedArgumentsDescriptorValue(rt, object, key, &desc);
            const desc_value = try descriptorObject(rt, desc);
            try out.defineOwnProperty(rt, key, core.Descriptor.data(desc_value, .all));
        }
        return out.value();
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.get_own_property_names)) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(ctx, global, args[0]);
        const object = try expectObjectArg(object_value);
        const keys = try object.ownKeys(rt);
        defer core.Object.freeKeys(rt, keys);
        const out = try core.Object.createArray(rt, if (global) |g| array_ops.arrayPrototypeFromGlobal(rt, g) else null);
        errdefer core.Object.destroyFromHeader(rt, out.gcHeader());
        var out_index: u32 = 0;
        for (keys) |key| {
            const name_value = try rt.atoms.toStringValue(rt, key);
            try out.defineOwnProperty(rt, core.Atom.taggedInt(out_index), core.Descriptor.data(name_value, .all));
            out_index += 1;
        }
        return out.value();
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.get_own_property_symbols)) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(ctx, global, args[0]);
        const object = try expectObjectArg(object_value);
        const keys = try object.ownKeys(rt);
        defer core.Object.freeKeys(rt, keys);
        const out = try core.Object.createArray(rt, if (global) |g| array_ops.arrayPrototypeFromGlobal(rt, g) else null);
        errdefer core.Object.destroyFromHeader(rt, out.gcHeader());
        for (keys) |key| {
            if (!rt.atoms.isPublicSymbol(key)) continue;
            const symbol_value = try rt.symbolValue(key);
            try out.defineOwnProperty(rt, core.Atom.taggedInt(out.arrayLength()), core.Descriptor.data(symbol_value, .all));
        }
        return out.value();
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.has_own)) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(ctx, global, args[0]);
        const object = try expectObjectArg(object_value);
        const key_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
        const key = try atomFromPropertyKey(rt, key_value);
        if (try object.getOwnProperty(rt, key) != null) return core.JSValue.boolean(true);
        return core.JSValue.boolean(false);
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.get_prototype_of)) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(ctx, global, args[0]);
        const object = try expectObjectArg(object_value);
        if (object.getPrototype()) |prototype| return prototype.value();
        return core.JSValue.nullValue();
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.set_prototype_of)) {
        if (args.len < 2) return error.TypeError;
        if (args[0].is(.null_value) or args[0].is(.undefined_value)) return error.TypeError;
        const prototype: ?*core.Object = if (args[1].is(.null_value))
            null
        else
            try expectObjectArg(args[1]);
        const object = thisObject(args[0]) orelse return args[0];
        object.setPrototype(rt, prototype) catch |err| switch (err) {
            error.PrototypeCycle, error.NotExtensible => return error.TypeError,
            else => return err,
        };
        return args[0];
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.is_extensible)) {
        const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const object = thisObject(target_value) orelse return core.JSValue.boolean(false);
        return core.JSValue.boolean(object.isExtensible());
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.prevent_extensions)) {
        const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const object = thisObject(target_value) orelse return target_value;
        object.preventExtensions();
        return target_value;
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.seal)) {
        const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const object = thisObject(target_value) orelse return target_value;
        try object.seal(rt);
        return target_value;
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.is_sealed)) {
        const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const object = thisObject(target_value) orelse return core.JSValue.boolean(true);
        return core.JSValue.boolean(try objectIsSealed(rt, object));
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.is_frozen)) {
        const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const object = thisObject(target_value) orelse return core.JSValue.boolean(true);
        return core.JSValue.boolean(try objectIsFrozen(rt, object));
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.freeze)) {
        const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const object = thisObject(target_value) orelse return target_value;
        try object.freeze(rt);
        return target_value;
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.define_property)) {
        if (args.len < 3) return error.TypeError;
        const object = try expectObjectArg(args[0]);
        const key = try atomFromPropertyKey(rt, args[1]);
        const desc_object = try expectObjectArg(args[2]);
        const desc = try descriptorFromObjectBare(desc_object);
        object.defineOwnProperty(rt, key, desc) catch |err| switch (err) {
            error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
            error.InvalidLength => return error.RangeError,
            else => return err,
        };
        return object.value();
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.define_properties)) {
        if (args.len < 2) return error.TypeError;
        const object = try expectObjectArg(args[0]);
        try definePropertiesFromObject(rt, object, args[1]);
        return object.value();
    }
    return error.TypeError;
}

fn objectStaticToObjectValue(ctx: *core.JSContext, global: ?*core.Object, value: core.JSValue) !core.JSValue {
    const rt = ctx.runtime;
    if (value.is(.null_value) or value.is(.undefined_value)) return error.TypeError;
    if (value.is(.object)) return value;
    const class_id: core.class.ClassId = if (value.isString())
        core.class.ids.string
    else if (value.isNumber())
        core.class.ids.number
    else if (value.as(.boolean) != null)
        core.class.ids.boolean
    else if (value.isBigInt())
        core.class.ids.big_int
    else if (value.is(.symbol))
        core.class.ids.symbol
    else
        core.class.ids.object;
    if (class_id == core.class.ids.object) {
        const object = try core.Object.create(rt, core.class.ids.object, null);
        return object.value();
    }
    return primitiveWrapper(ctx, class_id, value, primitivePrototypeFromGlobal(rt, global, class_id));
}

fn objectAssignGet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    receiver: core.JSValue,
    desc: core.Descriptor,
) HostError!core.JSValue {
    return switch (desc.kind) {
        .data => desc.value,
        .generic => core.JSValue.undefinedValue(),
        .accessor => {
            if (desc.getter.is(.undefined_value)) return core.JSValue.undefinedValue();
            return callWithRealmGlobal(ctx, output, global, globals, receiver, desc.getter, &.{});
        },
    };
}

fn objectAssignSet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    target_value: core.JSValue,
    target: *core.Object,
    key: core.Atom,
    value: core.JSValue,
) !void {
    if (try target.getOwnProperty(ctx.runtime, key)) |desc| {
        switch (desc.kind) {
            .accessor => {
                if (desc.setter.is(.undefined_value)) return error.TypeError;
                _ = try callWithRealmGlobal(ctx, output, global, globals, target_value, desc.setter, &.{value});
                return;
            },
            .data => {
                if (desc.writable == false) return error.TypeError;
            },
            .generic => {},
        }
    } else {
        var proto = target.getPrototype();
        while (proto) |prototype| : (proto = prototype.getPrototype()) {
            if (try prototype.getOwnProperty(ctx.runtime, key)) |desc| {
                switch (desc.kind) {
                    .accessor => {
                        if (desc.setter.is(.undefined_value)) return error.TypeError;
                        _ = try callWithRealmGlobal(ctx, output, global, globals, target_value, desc.setter, &.{value});
                        return;
                    },
                    .data => {
                        if (desc.writable == false) return error.TypeError;
                    },
                    .generic => {},
                }
                break;
            }
        }
    }
    target.setProperty(ctx.runtime, key, value) catch |err| switch (err) {
        error.ReadOnly, error.AccessorWithoutSetter, error.NotExtensible, error.IncompatibleDescriptor => return error.TypeError,
        error.InvalidLength => return error.RangeError,
        else => return err,
    };
}

fn objectIsSealed(rt: *core.JSRuntime, object: *core.Object) !bool {
    if (object.isExtensible()) return false;
    const keys = try object.ownKeys(rt);
    defer core.Object.freeKeys(rt, keys);
    for (keys) |key| {
        const desc = (try object.getOwnProperty(rt, key)) orelse continue;
        if (desc.configurable == true) return false;
    }
    return true;
}

fn objectIsFrozen(rt: *core.JSRuntime, object: *core.Object) !bool {
    if (!try objectIsSealed(rt, object)) return false;
    const keys = try object.ownKeys(rt);
    defer core.Object.freeKeys(rt, keys);
    for (keys) |key| {
        const desc = (try object.getOwnProperty(rt, key)) orelse continue;
        if (desc.kind == .data and desc.writable == true) return false;
    }
    return true;
}

/// Bare-runtime (no realm global) `Object.prototype.*` data-plane fallback.
/// `toLocaleString` [[Call]]s `toString` and therefore needs a Realm global.
pub fn objectPrototypeMethodCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    method: i32,
    this_value: core.JSValue,
    args: []const core.JSValue,
) !core.JSValue {
    return switch (method) {
        1 => objectPrototypeToString(ctx.runtime, this_value),
        2 => {
            const to_string_key = core.atom.ids.toString;
            const receiver_value = try objectStaticToObjectValue(ctx, global, this_value);
            const receiver = try expectObjectArg(receiver_value);
            const method_value = try receiver.getProperty(to_string_key);
            return callWithRealmGlobal(ctx, output, global, globals, receiver_value, method_value, &.{});
        },
        3 => objectPrototypeValueOf(ctx, global, this_value),
        4 => objectPrototypeHasOwn(ctx, global, this_value, args),
        5 => objectPrototypeIsPrototypeOf(ctx, global, this_value, args),
        6 => objectPrototypePropertyIsEnumerable(ctx, global, this_value, args),
        7 => objectPrototypeDefineAccessor(ctx, global, this_value, args, true),
        8 => objectPrototypeDefineAccessor(ctx, global, this_value, args, false),
        9 => objectPrototypeLookupAccessor(ctx, global, this_value, args, true),
        10 => objectPrototypeLookupAccessor(ctx, global, this_value, args, false),
        else => error.TypeError,
    };
}

fn objectPrototypeToString(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue {
    if (receiver.is(.undefined_value)) return value_ops.createStringValue(rt, "[object Undefined]");
    if (receiver.is(.null_value)) return value_ops.createStringValue(rt, "[object Null]");
    if (receiver.as(.boolean) != null) return value_ops.createStringValue(rt, "[object Boolean]");
    if (receiver.isNumber()) return value_ops.createStringValue(rt, "[object Number]");
    if (receiver.isString()) return value_ops.createStringValue(rt, "[object String]");
    if (receiver.isBigInt()) return value_ops.createStringValue(rt, "[object BigInt]");
    if (receiver.is(.symbol)) return value_ops.createStringValue(rt, "[object Symbol]");
    return objectToString(rt, receiver);
}

fn objectPrototypeValueOf(ctx: *core.JSContext, global: ?*core.Object, receiver: core.JSValue) !core.JSValue {
    return objectStaticToObjectValue(ctx, global, receiver);
}

fn objectPrototypeHasOwn(ctx: *core.JSContext, global: ?*core.Object, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const rt = ctx.runtime;
    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const key = try atomFromPropertyKey(rt, key_value);
    const receiver_value = try objectStaticToObjectValue(ctx, global, receiver);
    const object = try expectObjectArg(receiver_value);
    if (try object.getOwnProperty(rt, key) != null) return core.JSValue.boolean(true);
    return core.JSValue.boolean(false);
}

fn objectPrototypePropertyIsEnumerable(ctx: *core.JSContext, global: ?*core.Object, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const rt = ctx.runtime;
    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const key = try atomFromPropertyKey(rt, key_value);
    const receiver_value = try objectStaticToObjectValue(ctx, global, receiver);
    const object = try expectObjectArg(receiver_value);
    const desc = (try object.getOwnProperty(rt, key)) orelse return core.JSValue.boolean(false);
    return core.JSValue.boolean(desc.enumerable orelse false);
}

fn objectPrototypeIsPrototypeOf(ctx: *core.JSContext, global: ?*core.Object, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const value_object = thisObject(value) orelse return core.JSValue.boolean(false);
    const receiver_value = try objectStaticToObjectValue(ctx, global, receiver);
    const object = try expectObjectArg(receiver_value);
    var proto = value_object.getPrototype();
    while (proto) |candidate| : (proto = candidate.getPrototype()) {
        if (candidate == object) return core.JSValue.boolean(true);
    }
    return core.JSValue.boolean(false);
}

fn objectPrototypeDefineAccessor(ctx: *core.JSContext, global: ?*core.Object, receiver: core.JSValue, args: []const core.JSValue, getter: bool) !core.JSValue {
    const rt = ctx.runtime;
    const receiver_value = try objectStaticToObjectValue(ctx, global, receiver);
    const object = try expectObjectArg(receiver_value);
    const accessor_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    if (!isCallableObjectValue(accessor_value)) return error.TypeError;
    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const key = try atomFromPropertyKey(rt, key_value);
    const desc = if (getter)
        core.Descriptor.accessor(accessor_value, core.JSValue.undefinedValue(), .{ .enumerable = true, .configurable = true })
    else
        core.Descriptor.accessor(core.JSValue.undefinedValue(), accessor_value, .{ .enumerable = true, .configurable = true });
    object.defineOwnProperty(rt, key, desc) catch |err| switch (err) {
        error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
        error.InvalidLength => return error.RangeError,
        else => return err,
    };
    return core.JSValue.undefinedValue();
}

fn objectPrototypeLookupAccessor(ctx: *core.JSContext, global: ?*core.Object, receiver: core.JSValue, args: []const core.JSValue, getter: bool) !core.JSValue {
    const rt = ctx.runtime;
    const receiver_value = try objectStaticToObjectValue(ctx, global, receiver);
    const object = try expectObjectArg(receiver_value);
    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const key = try atomFromPropertyKey(rt, key_value);
    var cursor: ?*core.Object = object;
    while (cursor) |current| : (cursor = current.getPrototype()) {
        const desc = (try current.getOwnProperty(rt, key)) orelse continue;
        if (desc.kind != .accessor) return core.JSValue.undefinedValue();
        return if (getter) desc.getter else desc.setter;
    }
    return core.JSValue.undefinedValue();
}

pub fn isCallableObjectValue(value: core.JSValue) bool {
    const object = thisObject(value) orelse return false;
    return object.class_id == core.class.ids.c_function or
        object.class_id == core.class.ids.c_function_data or
        core.class.isAsyncFunctionResumeClass(object.class_id) or
        object.class_id == core.class.ids.bound_function or
        core.class.isBytecodeFunctionClass(object.class_id);
}

pub fn primitiveWrapper(ctx: *core.JSContext, class_id: core.class.ClassId, primitive: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    const rt = ctx.runtime;
    var values = [_]core.JSValue{ primitive, if (prototype) |object| object.value() else core.JSValue.nullValue(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    // The construct-record adapter also holds a raw prototype snapshot.
    // Its borrowed input window pins that snapshot through record dispatch.
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = values[0..2] } };
    var root_frame = core.runtime.ValueRootFrame{ .slices = &slices };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);
    if (class_id == core.class.ids.string) {
        // Route `new String(primitive)` / `Object(stringPrimitive)` boxing
        // through the String construct record (Phase 6b-3 STEP 6) instead of
        // naming `string_builtin_ops.constructWithPrototype`: the record's
        // construct branch forwards `args`/`new_target` straight to that body.
        return (try builtin_dispatch.callConstructRecord(ctx, null, null, &.{}, null, string_construct_ref, thisObject(values[1]), values[0..1], null, null)) orelse error.TypeError;
    }
    values[2] = (try core.Object.create(rt, class_id, thisObject(values[1]))).value();
    const object = thisObject(values[2]).?;
    try object.setOptionalValueSlot(rt, object.objectDataSlot(), values[0]);
    return values[2];
}

test "primitiveWrapper roots direct symbol while creating call wrapper" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-call-wrapper-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const symbol_value = try rt.takeSymbolValue(symbol_atom);
    const wrapper_value = try primitiveWrapper(ctx, core.class.ids.symbol, symbol_value, null);
    const wrapper = try property_ops.expectObject(wrapper_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = wrapper.objectData() orelse return error.TypeError;
    try std.testing.expect(stored.same(symbol_value));

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn primitivePrototypeFromGlobal(rt: *core.JSRuntime, global: ?*core.Object, class_id: core.class.ClassId) ?*core.Object {
    _ = rt;
    const global_object = global orelse return null;
    const name = switch (class_id) {
        core.class.ids.string => "String",
        core.class.ids.number => "Number",
        core.class.ids.boolean => "Boolean",
        core.class.ids.symbol => "Symbol",
        core.class.ids.big_int => "BigInt",
        else => return null,
    };
    const key = core.atom.predefinedId(name, .string) orelse return null;
    const constructor = global_object.getOwnDataObjectBorrowed(key) orelse return null;
    return constructor.getOwnDataObjectBorrowed(core.atom.ids.prototype);
}

fn boundFunctionNameValue(rt: *core.JSRuntime, target_name: core.JSValue) !core.JSValue {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try bytes.appendSlice(rt.nativeAllocator(), "bound ");
    if (target_name.isString()) {
        try value_ops.appendRawString(rt, &bytes, target_name);
    }
    return value_ops.createStringValue(rt, bytes.items);
}

fn boundFunctionLengthValue(target_length: core.JSValue, bound_arg_count: usize) core.JSValue {
    const number = value_ops.numberValue(target_length) orelse return core.JSValue.int32(0);
    if (std.math.isNan(number) or std.math.isNegativeInf(number)) return core.JSValue.int32(0);
    if (std.math.isPositiveInf(number)) return core.JSValue.float64(std.math.inf(f64));
    var integer = @trunc(number);
    if (integer == 0 or std.math.isNegativeZero(integer)) integer = 0;
    if (integer < 0) return core.JSValue.int32(0);
    const remaining = integer - @as(f64, @floatFromInt(bound_arg_count));
    return value_ops.numberToValue(if (remaining > 0) remaining else 0);
}

fn createBoundFunction(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    target: core.JSValue,
    bound_this: core.JSValue,
    bound_args: []const core.JSValue,
) !core.JSValue {
    const rt = ctx.runtime;
    var rooted_target = target;
    var rooted_bound_this = bound_this;
    var root_values = [_]*core.JSValue{
        &rooted_target,
        &rooted_bound_this,
    };
    var rooted_bound_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, bound_args);
    defer rooted_bound_args_buffer.deinit();
    const rooted_bound_args = rooted_bound_args_buffer.values();
    var root_frame = core.runtime.ValueRootFrame{
        .values = &root_values,
    };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const target_object = thisObject(rooted_target) orelse return error.TypeError;
    const length_value = if (try hasOwnPropertyProxyAware(ctx, output, global, globals, target_object, core.atom.ids.length)) blk: {
        const target_length = try getValuePropertyProxyAware(ctx, output, global, globals, rooted_target, core.atom.ids.length);
        break :blk boundFunctionLengthValue(target_length, rooted_bound_args.len);
    } else core.JSValue.int32(0);
    const target_name = try getValuePropertyProxyAware(ctx, output, global, globals, rooted_target, core.atom.ids.name);
    const name_value = try boundFunctionNameValue(rt, target_name);

    const object = try core.Object.create(rt, core.class.ids.bound_function, target_object.getPrototype());
    errdefer core.Object.destroyFromHeader(rt, object.gcHeader());
    try object.setOptionalValueSlot(rt, object.boundTargetSlot(), rooted_target);
    try object.setOptionalValueSlot(rt, object.boundThisSlot(), rooted_bound_this);
    // Bound wrappers keep caller semantics. The recursive call selects a realm
    // only after it reaches the final bytecode/C-function target.
    if (rooted_bound_args.len != 0) {
        // TGC S4-c: the bound-argument array is a subordinate `.payload` GC
        // cell. The mint is the LAST fallible step and only the (allocation
        // free) copy loop separates it from the install below -- a bare cell
        // has no precise root. An abandoned cell is swept, never hand-freed,
        // so no errdefer owns it.
        const owned_bound_args = try core.Object.createPayloadSliceCell(
            rt,
            core.JSValue,
            rooted_bound_args.len,
        );
        var rooted_owned_bound_args: []core.JSValue = owned_bound_args[0..0];
        var owned_bound_args_root = ValueSliceRoot{};
        owned_bound_args_root.init(rt, &rooted_owned_bound_args);
        defer owned_bound_args_root.deinit();
        var initialized: usize = 0;
        for (rooted_bound_args, 0..) |arg, index| {
            owned_bound_args[index] = arg;
            initialized += 1;
            rooted_owned_bound_args = owned_bound_args[0..initialized];
        }
        object.boundArgsSlot().* = owned_bound_args;
        rooted_owned_bound_args = &.{};
        rt.gc.rememberOwnerForBulkWrite(object.gcHeader());
    }
    try object.defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.data(name_value, .{ .configurable = true }));
    try object.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(length_value, .{ .configurable = true }));
    return object.value();
}

test "createBoundFunction roots bound this and args while creating function" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    _ = try installTestStandardRealm(ctx);
    const target = try core.function.nativeFunction(ctx, "target", 0);

    const this_atom = try rt.atoms.newValueSymbol("gc-bound-this-symbol");
    const this_value = try rt.takeSymbolValue(this_atom);
    const arg_atom = try rt.atoms.newValueSymbol("gc-bound-arg-symbol");
    const arg_value = try rt.takeSymbolValue(arg_atom);
    const bound_args = [_]core.JSValue{arg_value};
    var globals = [_]globals_mod.Slot{};

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const bound_value = try createBoundFunction(
        ctx,
        null,
        null,
        globals[0..],
        target,
        this_value,
        &bound_args,
    );
    const bound = thisObject(bound_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(this_atom) != null);
    try std.testing.expect(rt.atoms.name(arg_atom) != null);
    try std.testing.expect(bound.boundThis().?.same(this_value));
    try std.testing.expectEqual(@as(usize, 1), bound.boundArgs().len);
    try std.testing.expect(bound.boundArgs()[0].same(arg_value));

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(this_atom) == null);
    try std.testing.expect(rt.atoms.name(arg_atom) == null);
}

test "callValueOrBytecodeRoot roots inline args before bound argument merge" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try installTestStandardRealm(ctx);

    const target = try core.function.nativeFunction(ctx, "get [Symbol.species]", 0);
    const target_object = thisObject(target) orelse return error.TypeError;
    target_object.setNativeBuiltinIdAndRecord(rt, core.function.nativeBuiltinId(.host, @intFromEnum(core.function.HostGlobalMethod.species_getter)));

    var globals = [_]globals_mod.Slot{};
    const bound_value = try createBoundFunction(
        ctx,
        null,
        null,
        globals[0..],
        target,
        core.JSValue.undefinedValue(),
        &.{},
    );

    const arg_atom = try rt.atoms.newValueSymbol("gc-call-legacy-inline-arg-root");
    const arg_value = try rt.takeSymbolValue(arg_atom);
    const args = [_]core.JSValue{arg_value};

    const Trigger = struct {
        rt: *core.JSRuntime,
        atom_id: core.Atom,
        saw_arg: bool = false,
        trace_failed: bool = false,

        fn trigger(context: ?*anyopaque, size: usize) void {
            _ = size;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const saved_trigger_fn = self.rt.gc.heap_budget.probe;
            const saved_trigger_ctx = self.rt.gc.heap_budget.probe_ctx;
            self.rt.gc.heap_budget.probe = null;
            self.rt.gc.heap_budget.probe_ctx = null;
            defer {
                self.rt.gc.heap_budget.probe = saved_trigger_fn;
                self.rt.gc.heap_budget.probe_ctx = saved_trigger_ctx;
            }
            _ = self.rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {}; // engine-frames-active trigger
            self.saw_arg = self.rt.atoms.name(self.atom_id) != null;
        }
    };

    const saved_trigger_fn = rt.gc.heap_budget.probe;
    const saved_trigger_ctx = rt.gc.heap_budget.probe_ctx;
    var trigger = Trigger{
        .rt = rt,
        .atom_id = arg_atom,
    };
    rt.gc.heap_budget.probe = Trigger.trigger;
    rt.gc.heap_budget.probe_ctx = &trigger;
    defer {
        rt.gc.heap_budget.probe = saved_trigger_fn;
        rt.gc.heap_budget.probe_ctx = saved_trigger_ctx;
    }

    _ = try call_runtime.callValueOrBytecodeRoot(
        ctx,
        null,
        global,
        core.JSValue.undefinedValue(),
        bound_value,
        &args,
        null,
        null,
    );
    rt.gc.heap_budget.probe = saved_trigger_fn;
    rt.gc.heap_budget.probe_ctx = saved_trigger_ctx;

    try std.testing.expect(!trigger.trace_failed);
    try std.testing.expect(trigger.saw_arg);

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(arg_atom) == null);
}

test "callValueOrBytecodeRoot roots overflow args across the copy allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try installTestStandardRealm(ctx);

    // Native identity echoes `args[0]` back, so the callee has to read the
    // window the helper handed it -- not the caller's original slice.
    const Identity = struct {
        fn call(_: *core.JSContext, _: core.JSValue, call_args: []const core.JSValue) HostError!core.JSValue {
            if (call_args.len < 1) return error.TypeError;
            return call_args[0];
        }
    };
    const entry = try rt.allocNativeEntry(builtin_dispatch.genericEntry(&Identity.call, 1));
    var callee = try core.function.nativeFunction(ctx, "identity", 1);
    (try core.Object.expect(callee)).installNativeEntry(entry);

    // Strictly above the 8-slot inline buffer: this is the `initCopy` arm, and
    // `initCopy` allocates, which is a collection point.
    const arg_count = 9;
    var arg_atoms: [arg_count]core.Atom = undefined;
    var args: [arg_count]core.JSValue = undefined;
    for (&arg_atoms, &args, 0..) |*atom_slot, *arg_slot, index| {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "gc-call-overflow-arg-{d}", .{index});
        atom_slot.* = try rt.atoms.newValueSymbol(name);
        arg_slot.* = try rt.takeSymbolValue(atom_slot.*);
    }

    const Trigger = struct {
        rt: *core.JSRuntime,
        atom_ids: []const core.Atom,
        collections: usize = 0,
        lost_arg: bool = false,

        fn trigger(context: ?*anyopaque, size: usize) void {
            _ = size;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const saved_trigger_fn = self.rt.gc.heap_budget.probe;
            const saved_trigger_ctx = self.rt.gc.heap_budget.probe_ctx;
            self.rt.gc.heap_budget.probe = null;
            self.rt.gc.heap_budget.probe_ctx = null;
            defer {
                self.rt.gc.heap_budget.probe = saved_trigger_fn;
                self.rt.gc.heap_budget.probe_ctx = saved_trigger_ctx;
            }
            _ = self.rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {};
            self.collections += 1;
            for (self.atom_ids) |id| {
                if (self.rt.atoms.name(id) == null) self.lost_arg = true;
            }
        }
    };

    // The caller's own GC-visible state here is the callee value; the argument
    // window is deliberately left undeclared, because covering it across the
    // copy is the callee-side obligation under test.
    var callee_roots = [_]*core.JSValue{&callee};
    var callee_frame = core.runtime.ValueRootFrame{ .values = &callee_roots };
    callee_frame.activate(rt);
    defer callee_frame.deactivate(rt);

    // Precise scanning is what makes this a regression test: under the
    // conservative regime the caller's own stack copy of `args` covers the
    // window by accident and a missing declared root cannot be observed.
    rt.forcePreciseRootScanForTest();
    defer rt.restoreDefaultRootScanForTest();

    const saved_trigger_fn = rt.gc.heap_budget.probe;
    const saved_trigger_ctx = rt.gc.heap_budget.probe_ctx;
    var trigger = Trigger{
        .rt = rt,
        .atom_ids = arg_atoms[0..],
    };
    rt.gc.heap_budget.probe = Trigger.trigger;
    rt.gc.heap_budget.probe_ctx = &trigger;
    defer {
        rt.gc.heap_budget.probe = saved_trigger_fn;
        rt.gc.heap_budget.probe_ctx = saved_trigger_ctx;
    }

    const result = try call_runtime.callValueOrBytecodeRoot(
        ctx,
        null,
        global,
        core.JSValue.undefinedValue(),
        callee,
        args[0..],
        null,
        null,
    );
    rt.gc.heap_budget.probe = saved_trigger_fn;
    rt.gc.heap_budget.probe_ctx = saved_trigger_ctx;

    // At least one collection has to have run inside the call, or the
    // assertions below prove nothing.
    try std.testing.expect(trigger.collections > 0);
    try std.testing.expect(!trigger.lost_arg);
    try std.testing.expectEqual(arg_atoms[0], result.asSymbolAtom() orelse return error.TestUnexpectedResult);
    for (arg_atoms, args) |atom_id, arg| {
        try std.testing.expect(rt.atoms.name(atom_id) != null);
        try std.testing.expectEqual(atom_id, arg.asSymbolAtom() orelse return error.TestUnexpectedResult);
    }
}

fn objectToString(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue {
    const object = try expectObjectArg(receiver);
    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return value_ops.createStringValue(rt, "[object Object]");
    const tag_value = try object.getProperty(tag_atom);
    if (tag_value.isString()) {
        var tag = std.ArrayList(u8).empty;
        defer tag.deinit(rt.nativeAllocator());
        try value_ops.appendRawString(rt, &tag, tag_value);
        var out = std.ArrayList(u8).empty;
        defer out.deinit(rt.nativeAllocator());
        try out.appendSlice(rt.nativeAllocator(), "[object ");
        try out.appendSlice(rt.nativeAllocator(), tag.items);
        try out.appendSlice(rt.nativeAllocator(), "]");
        return value_ops.createStringValue(rt, out.items);
    }
    return value_ops.createStringValue(rt, defaultObjectTag(object));
}

fn defaultObjectTag(object: *core.Object) []const u8 {
    if (object.isArray()) return "[object Array]";
    return switch (object.class_id) {
        core.class.ids.c_function,
        core.class.ids.bytecode_function,
        core.class.ids.bound_function,
        core.class.ids.c_function_data,
        core.class.ids.async_function_resolve,
        core.class.ids.async_function_reject,
        => "[object Function]",
        core.class.ids.map => "[object Map]",
        core.class.ids.set => "[object Set]",
        core.class.ids.weakmap => "[object WeakMap]",
        core.class.ids.weakset => "[object WeakSet]",
        core.class.ids.promise => "[object Promise]",
        core.class.ids.array_buffer => "[object ArrayBuffer]",
        core.class.ids.date => "[object Date]",
        core.class.ids.regexp => "[object RegExp]",
        core.class.ids.string => "[object String]",
        core.class.ids.number => "[object Number]",
        core.class.ids.boolean => "[object Boolean]",
        core.class.ids.big_int => "[object BigInt]",
        core.class.ids.symbol => "[object Symbol]",
        core.class.ids.arguments, core.class.ids.mapped_arguments => "[object Arguments]",
        else => "[object Object]",
    };
}

pub fn nativeFunctionName(rt: *core.JSRuntime, function_object: *core.Object) ![]u8 {
    const name_value = try nativeFunctionNameValue(rt, function_object, false);
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(rt.nativeAllocator());
    try value_ops.appendRawString(rt, &buffer, name_value);
    return buffer.toOwnedSlice(rt.nativeAllocator());
}

pub fn nativeFunctionNameForVm(rt: *core.JSRuntime, function_object: *core.Object) ![]u8 {
    return nativeFunctionDispatchName(rt, function_object);
}

/// Dispatch bytes with optional native ownership. Always call `deinit`.
/// A borrowed result references a string atom's immutable bytes. Immediate
/// probes need no extra root; callers crossing GC or reentrant calls must
/// root the original dispatch atom for the entire use, even if a callback
/// changes the function's metadata. Symbol descriptions and visible names
/// are copied: materializing a Symbol can replace its description storage.
pub const VmDispatchName = struct {
    name: []const u8,
    owned: ?[]u8,

    pub fn deinit(self: VmDispatchName, rt: *core.JSRuntime) void {
        if (self.owned) |bytes| rt.nativeAllocator().free(bytes);
    }
};

/// Allocation-free counterpart to `nativeFunctionNameForVm` for the native
/// dispatch probes. Every probe used to re-materialize the dispatch name with
/// an `allocator.dupe` + `free` round trip purely to run one `std.mem.eql`;
/// a single `ta.subarray()` walked ~13 of them and paid 14 allocations before
/// reaching its handler. QuickJS never re-derives a name to dispatch a native
/// call: `js_call_c_function` (quickjs.c, reached from OP_call_method at
/// quickjs.c) switches on the already-resolved function's `magic`. This
/// borrows the interned dispatch atom's bytes instead, which is the closest
/// zjs equivalent of reading that pre-resolved identity.
///
/// The fallback preserves `nativeFunctionNameForVm`'s core property-read
/// behavior, UTF-8 encoding and errors. Core property reads can materialize
/// AUTOINIT properties; this helper does not invoke JavaScript getters.
pub fn nativeFunctionNameForVmBorrowed(rt: *core.JSRuntime, function_object: *core.Object) !VmDispatchName {
    const dispatch_atom = function_object.nativeDispatchName();
    if (rt.atoms.kind(dispatch_atom) == .string) {
        if (rt.atoms.name(dispatch_atom)) |bytes| return .{ .name = bytes, .owned = null };
    }
    const owned = try nativeFunctionDispatchName(rt, function_object);
    return .{ .name = owned, .owned = owned };
}

/// Single-name form of `nativeFunctionNameForVmBorrowed`, equivalent to
/// `std.mem.eql(u8, try nativeFunctionNameForVm(rt, o), expected)` including
/// the error cases, but without the allocation on the interned-atom path.
pub fn nativeFunctionNameForVmEquals(
    rt: *core.JSRuntime,
    function_object: *core.Object,
    expected: []const u8,
) !bool {
    const dispatch = try nativeFunctionNameForVmBorrowed(rt, function_object);
    defer dispatch.deinit(rt);
    return std.mem.eql(u8, dispatch.name, expected);
}

pub fn functionToStringValue(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    if (value.is(.function_bytecode)) {
        const function_bytecode = functionBytecodeFromValue(value) orelse return error.TypeError;
        return functionBytecodeToStringValue(rt, function_bytecode, null);
    }

    const object = thisObject(value) orelse return error.TypeError;
    if (object.isProxy()) {
        if (object.proxyHandler() == null) return error.TypeError;
        const target = object.proxyTarget() orelse return error.TypeError;
        if (!isFunctionToStringCallable(target)) return error.TypeError;
        return nativeFunctionSourceValue(rt, null);
    }
    if (core.class.isBytecodeFunctionClass(object.class_id)) {
        const stored = object.functionBytecode() orelse return nativeFunctionSourceValue(rt, object);
        const function_bytecode = functionBytecodeFromValue(stored) orelse return nativeFunctionSourceValue(rt, object);
        return functionBytecodeToStringValue(rt, function_bytecode, object);
    }
    if (object.class_id == core.class.ids.bound_function) {
        return nativeFunctionSourceValue(rt, null);
    }
    if (isFunctionClass(object.class_id)) {
        if (object.functionSource()) |source| return source;
        return nativeFunctionSourceValue(rt, object);
    }
    return error.TypeError;
}

/// Pure short-lived projection: borrow internal atom bytes or the flat
/// Latin1 own data `name`. Ropes (including cached ropes), UTF-16, missing
/// and non-string names return null. No allocation or property resolution.
/// `name_value` is only an owner snapshot, not a root. Consume the borrow
/// before GC, callbacks, or atom storage changes; dispatch across callbacks
/// uses `nativeFunctionDispatchNameForCall` or `nativeFunctionNameForVmBorrowed`.
pub fn nativeFunctionDispatchNameRef(
    rt: *core.JSRuntime,
    function_object: *core.Object,
) ?struct { name: []const u8, name_value: core.JSValue } {
    const dispatch_atom = function_object.nativeDispatchName();
    if (dispatch_atom != core.atom.null_atom) {
        if (rt.atoms.name(dispatch_atom)) |bytes| {
            return .{ .name = bytes, .name_value = core.JSValue.undefinedValue() };
        }
    }
    const name_value = function_object.getOwnDataPropertyValue(core.atom.ids.name) orelse return null;
    if (!name_value.isString()) {
        return null;
    }
    const bytes = stringLatin1BytesRef(name_value) orelse {
        return null;
    };
    return .{ .name = bytes, .name_value = name_value };
}

/// Borrow latin1 bytes from a string `JSValue` without copying. Returns
/// `null` if the value is not a latin1 string (utf16 strings carry no
/// usable byte slice for ASCII-only dispatch comparisons).
fn stringLatin1BytesRef(value: core.JSValue) ?[]const u8 {
    const string_value = core.string.asFlat(value) orelse return null;
    return switch (string_value.resolveData()) {
        .latin1 => |bytes| bytes,
        .utf16 => null,
    };
}

/// Legacy callable-name dispatch reads only own data, without resolving
/// properties or invoking getters. Missing/non-string/wide names have no
/// dispatch. Keep internal string atoms borrowed; copy all other usable
/// names into native storage before callbacks can delete their owners.
/// Native allocation can fail, but this function cannot collect or flatten.
/// The caller roots the original dispatch atom before crossing a GC point.
pub fn nativeFunctionDispatchNameForCall(rt: *core.JSRuntime, function_object: *core.Object) !?VmDispatchName {
    var borrow = core.runtime.NoGcScope{};
    borrow.activate(rt);
    defer borrow.deactivate();
    const dispatch_atom = function_object.nativeDispatchName();
    if (rt.atoms.name(dispatch_atom)) |bytes| {
        if (rt.atoms.kind(dispatch_atom) == .string) return .{ .name = bytes, .owned = null };
        const owned = try rt.nativeAllocator().dupe(u8, bytes);
        return .{ .name = owned, .owned = owned };
    }
    const value = function_object.getOwnDataPropertyValue(core.atom.ids.name) orelse return null;
    if (!value.isString()) return null;
    const wide = if (value.ropeBody()) |rope| rope.isWide() else core.string.asFlat(value).?.isWide();
    if (wide) return null;
    const owned = try rt.nativeAllocator().alloc(u8, core.string.stringValueLenUnchecked(value));
    errdefer rt.nativeAllocator().free(owned);
    var iterator = core.string.StringValueIterator.init(value);
    var offset: usize = 0;
    while (iterator.next()) |leaf| {
        const bytes = switch (leaf) {
            .latin1 => |bytes| bytes,
            .utf16 => unreachable, // The string's width metadata covers every leaf.
        };
        @memcpy(owned[offset..][0..bytes.len], bytes);
        offset += bytes.len;
    }
    std.debug.assert(offset == owned.len);
    return .{ .name = owned, .owned = owned };
}

fn nativeFunctionDispatchName(rt: *core.JSRuntime, function_object: *core.Object) ![]u8 {
    const dispatch_atom = function_object.nativeDispatchName();
    if (dispatch_atom != core.atom.null_atom) {
        if (rt.atoms.name(dispatch_atom)) |bytes| {
            return try rt.nativeAllocator().dupe(u8, bytes);
        }
    }
    const name_value = try nativeFunctionNameValue(rt, function_object, true);
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(rt.nativeAllocator());
    try value_ops.appendRawString(rt, &buffer, name_value);
    return buffer.toOwnedSlice(rt.nativeAllocator());
}

fn nativeFunctionNameValue(rt: *core.JSRuntime, function_object: *core.Object, prefer_dispatch_name: bool) !core.JSValue {
    if (prefer_dispatch_name) return call_runtime.nativeFunctionNameValueLocal(rt, function_object);
    const name_value = try function_object.getProperty(core.atom.ids.name);
    if (!name_value.isString()) {
        return error.TypeError;
    }
    return name_value;
}

const functionBytecodeFromValue = call_runtime.functionBytecodeFromValue;

fn functionBytecodeToStringValue(
    rt: *core.JSRuntime,
    function_bytecode: *const bytecode.FunctionBytecode,
    object: ?*core.Object,
) !core.JSValue {
    if (function_bytecode.sourceText()) |source| return value_ops.createStringValue(rt, source);
    if (object) |function_object| {
        if (function_object.functionSource()) |source| return source;
        return nativeFunctionSourceValue(rt, function_object);
    }
    return nativeFunctionSourceValue(rt, null);
}

fn nativeFunctionSourceValue(rt: *core.JSRuntime, object: ?*core.Object) !core.JSValue {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.nativeAllocator());
    try buffer.appendSlice(rt.nativeAllocator(), "function");
    if (object) |function_object| {
        const name_value = nativeFunctionNameValue(rt, function_object, false) catch null;
        if (name_value) |stored_name| {
            try appendNativeFunctionSourceName(rt, &buffer, stored_name);
        }
    }
    try buffer.appendSlice(rt.nativeAllocator(), "() {\n    [native code]\n}");
    return value_ops.createStringValue(rt, buffer.items);
}

fn appendNativeFunctionSourceName(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), stored_name: core.JSValue) !void {
    var name_buffer = std.ArrayList(u8).empty;
    defer name_buffer.deinit(rt.nativeAllocator());
    try value_ops.appendRawString(rt, &name_buffer, stored_name);

    const source_name = nativeFunctionSourceName(name_buffer.items) orelse return;
    try buffer.append(rt.nativeAllocator(), ' ');
    try buffer.appendSlice(rt.nativeAllocator(), source_name);
}

fn nativeFunctionSourceName(name: []const u8) ?[]const u8 {
    if (name.len == 0) return name;
    if (std.mem.startsWith(u8, name, "get ")) {
        const property_name = name["get ".len..];
        return if (isNativeFunctionPropertyName(property_name)) name else "get";
    }
    if (std.mem.startsWith(u8, name, "set ")) {
        const property_name = name["set ".len..];
        return if (isNativeFunctionPropertyName(property_name)) name else "set";
    }
    return if (isNativeFunctionPropertyName(name)) name else null;
}

fn isNativeFunctionPropertyName(name: []const u8) bool {
    return call_runtime.isSimpleIdentifierName(name) or
        isUnicodeIdentifierName(name) or
        isNativeFunctionComputedPropertyName(name);
}

/// Non-ASCII identifier names ("ém") are legal JS identifiers and qjs
/// js_function_toString emits the name property verbatim,
/// so the native-source name filter must not drop them. The name bytes are
/// UTF-8 (appendRawString post-widening); reject invalid sequences.
fn isUnicodeIdentifierName(name: []const u8) bool {
    if (name.len == 0) return false;
    const view = std.unicode.Utf8View.init(name) catch return false;
    var it = view.iterator();
    var first = true;
    while (it.nextCodepoint()) |cp| {
        if (cp > 0x10ffff) return false;
        const c: u21 = @intCast(cp);
        if (first) {
            if (!unicode.isIdentifierStart(c)) return false;
            first = false;
        } else if (!unicode.isIdentifierContinue(c)) return false;
    }
    return true;
}

fn isNativeFunctionComputedPropertyName(name: []const u8) bool {
    if (name.len < 2 or name[0] != '[') return false;

    var index: usize = 1;
    var depth: usize = 1;
    var quote: u8 = 0;
    var escaped = false;
    while (index < name.len) : (index += 1) {
        const ch = name[index];
        if (quote != 0) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == quote) {
                quote = 0;
            } else if (ch == '\n' or ch == '\r') {
                return false;
            }
            continue;
        }

        switch (ch) {
            '\'', '"' => quote = ch,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return index == name.len - 1;
            },
            else => {},
        }
    }
    return false;
}

fn isFunctionToStringCallable(value: core.JSValue) bool {
    if (value.is(.function_bytecode)) return true;
    const object = thisObject(value) orelse return false;
    if (isFunctionClass(object.class_id)) return true;
    if (!object.isProxy() or object.proxyHandler() == null) return false;
    const target = object.proxyTarget() orelse return false;
    return isFunctionToStringCallable(target);
}

pub fn thisObject(value: core.JSValue) ?*core.Object {
    if (!value.is(.object)) return null;
    const header = value.refHeader() orelse return null;
    return core.Object.fromHeader(header);
}

fn materializeMappedArgumentsDescriptorValue(
    rt: *core.JSRuntime,
    object: *core.Object,
    key: core.Atom,
    desc: *core.Descriptor,
) void {
    if (desc.kind != .data) return;
    if (object.class_id != core.class.ids.mapped_arguments) return;
    const index = core.array.arrayIndexFromAtom(rt.atoms, key) orelse return;
    if (index >= object.argumentsVarRefs().len) return;
    const cell = object.argumentsVarRefs()[index] orelse return;
    const value = cell.varRefValue();
    desc.value = value;
    desc.value_present = true;
}

pub fn materializeMappedArgumentsDescriptorValueForVm(
    rt: *core.JSRuntime,
    object: *core.Object,
    key: core.Atom,
    desc: *core.Descriptor,
) !void {
    materializeMappedArgumentsDescriptorValue(rt, object, key, desc);
}

pub fn descriptorFromObjectBare(object: *core.Object) !core.Descriptor {
    const has_get = object.hasProperty(core.atom.ids.get);
    const has_set = object.hasProperty(core.atom.ids.set);
    const has_value = object.hasProperty(core.atom.ids.value);
    const has_writable = object.hasProperty(core.atom.ids.writable);
    const enumerable = try optionalBoolProperty(object, core.atom.ids.enumerable);
    const configurable = try optionalBoolProperty(object, core.atom.ids.configurable);
    if (has_get or has_set) {
        const getter = if (has_get) try object.getProperty(core.atom.ids.get) else core.JSValue.undefinedValue();
        const setter = if (has_set) try object.getProperty(core.atom.ids.set) else core.JSValue.undefinedValue();
        return .{
            .kind = .accessor,
            .getter = getter,
            .setter = setter,
            .enumerable = enumerable,
            .configurable = configurable,
        };
    }
    if (has_value or has_writable) {
        const value = if (has_value) try object.getProperty(core.atom.ids.value) else core.JSValue.undefinedValue();
        return .{
            .kind = .data,
            .value = value,
            .value_present = has_value,
            .writable = try optionalBoolProperty(object, core.atom.ids.writable),
            .enumerable = enumerable,
            .configurable = configurable,
        };
    }
    return core.Descriptor.generic(enumerable, configurable);
}

fn descriptorObject(rt: *core.JSRuntime, desc: core.Descriptor) !core.JSValue {
    var desc_value = desc.value;
    var desc_getter = desc.getter;
    var desc_setter = desc.setter;
    var root_values = [_]*core.JSValue{
        &desc_value,
        &desc_getter,
        &desc_setter,
    };
    var root_frame = core.runtime.ValueRootFrame{
        .values = &root_values,
    };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const object = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, object.gcHeader());
    if (desc.kind == .data) try defineObjectProperty(rt, object, core.atom.ids.value, desc_value);
    if (desc.kind == .accessor) {
        try defineObjectProperty(rt, object, core.atom.ids.get, desc_getter);
        try defineObjectProperty(rt, object, core.atom.ids.set, desc_setter);
    }
    if (desc.writable) |flag| try defineBoolProperty(rt, object, core.atom.ids.writable, flag);
    if (desc.enumerable) |flag| try defineBoolProperty(rt, object, core.atom.ids.enumerable, flag);
    if (desc.configurable) |flag| try defineBoolProperty(rt, object, core.atom.ids.configurable, flag);
    return object.value();
}

test "descriptorObject roots direct symbol value while creating descriptor object" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-call-descriptor-object-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const symbol_value = try rt.takeSymbolValue(symbol_atom);
    const descriptor_value = try descriptorObject(
        rt,
        core.Descriptor.data(symbol_value, .all),
    );
    const descriptor = thisObject(descriptor_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_key = try rt.internAtom("value");
    {
        const stored = try descriptor.getProperty(value_key);
        try std.testing.expect(stored.same(symbol_value));
    }

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn optionalBoolProperty(object: *core.Object, key: core.Atom) !?bool {
    if (!object.hasProperty(key)) return null;
    const value = try object.getProperty(key);
    return value.as(.boolean) orelse false;
}

fn definePropertiesFromObject(rt: *core.JSRuntime, object: *core.Object, properties_value: core.JSValue) !void {
    const properties = try expectObjectArg(properties_value);
    const keys = try properties.ownKeys(rt);
    defer core.Object.freeKeys(rt, keys);
    for (keys) |key| {
        const desc_value = try properties.getProperty(key);
        if (desc_value.is(.undefined_value)) continue;
        const desc_object = try expectObjectArg(desc_value);
        const desc = try descriptorFromObjectBare(desc_object);
        object.defineOwnProperty(rt, key, desc) catch |err| switch (err) {
            error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
            error.InvalidLength => return error.RangeError,
            else => return err,
        };
    }
}

fn atomFromPropertyKey(rt: *core.JSRuntime, value: core.JSValue) HostError!core.Atom {
    return try hostResult(property_ops.propertyKeyAtom(rt, value));
}

fn defineBoolProperty(rt: *core.JSRuntime, object: *core.Object, key: core.Atom, value: bool) !void {
    try defineObjectProperty(rt, object, key, core.JSValue.boolean(value));
}

pub const expectObjectArg = core.value_semantics.expectObject;

pub fn errorNameMatchesConstructor(err: anytype, constructor_name: []const u8) bool {
    const err_name = @errorName(err);
    return (std.mem.eql(u8, err_name, "TypeError") and std.mem.eql(u8, constructor_name, "TypeError")) or
        (std.mem.eql(u8, err_name, "SyntaxError") and std.mem.eql(u8, constructor_name, "SyntaxError")) or
        (std.mem.eql(u8, err_name, "RangeError") and std.mem.eql(u8, constructor_name, "RangeError")) or
        (std.mem.eql(u8, err_name, "EvalError") and std.mem.eql(u8, constructor_name, "EvalError")) or
        (std.mem.eql(u8, err_name, "ReferenceError") and std.mem.eql(u8, constructor_name, "ReferenceError"));
}

fn isFunctionClass(class_id: core.ClassId) bool {
    return class_id == core.class.ids.c_function or
        core.class.isBytecodeFunctionClass(class_id) or
        class_id == core.class.ids.bound_function or
        class_id == core.class.ids.c_function_data or
        core.class.isAsyncFunctionResumeClass(class_id);
}

test "four-class bytecode callable consumers accept every class" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const class_ids = [_]core.ClassId{
        core.class.ids.bytecode_function,
        core.class.ids.generator_function,
        core.class.ids.async_function,
        core.class.ids.async_generator_function,
    };
    for (class_ids) |class_id| {
        const function_object = try core.Object.create(rt, class_id, null);
        const function_value = function_object.value();

        try std.testing.expectEqual(function_object, expectCallableObject(function_value).?);
        try std.testing.expect(isCallableObjectValue(function_value));
        try std.testing.expect(isFunctionToStringCallable(function_value));
        try std.testing.expect(isFunctionClass(class_id));
        try std.testing.expectEqual(function_object, object_ops.functionObjectFromValue(function_value).?);

        const source = try functionToStringValue(rt, function_value);
        try std.testing.expect(source.isString());
    }
}

pub fn evalGlobalScriptSource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source: []const u8,
    filename: []const u8,
) !core.JSValue {
    const parser = @import("../parser.zig");
    const stack_mod = @import("stack.zig");
    const zjs_vm = @import("zjs_vm.zig");

    // Arm the native recursion guard at this outermost script entry (the public
    // ctx.evalScript embedding API + test262 $262.evalScript) — analogue of
    // eval()'s JS_UpdateStackTop refresh — so deeply nested source here surfaces
    // a catchable SyntaxError/InternalError instead of a native crash.
    if (ctx.runtime.call_depth == 0) ctx.runtime.updateNativeStackTop();

    const context_global = ctx.global;
    const use_global_lexicals = context_global == null or context_global.? != global;
    const keep_active_lexicals = context_global == null;
    const saved_lexicals = ctx.lexicals;
    if (use_global_lexicals) ctx.setLexicals(global.globalLexicals(ctx.runtime));

    const EvalResult = @typeInfo(@TypeOf(evalGlobalScriptSource)).@"fn".return_type.?;
    const result: EvalResult = blk: {
        const compile_realm = ctx.runtime.contextForGlobalIncludingConstructing(global) orelse break :blk error.InvalidBuiltinRegistry;
        var compiled = parser.compile(.{ .realm = compile_realm }, source, .{ .mode = .script, .filename = filename, .strict = false, .return_completion = true }) catch |err| break :blk err;
        defer compiled.deinit();
        if (compiled.syntax_error) |*parse_error| {
            // Compile-error surface: own fileName/lineNumber/columnNumber +
            // leading stack line (build_backtrace filename branch,
            // quickjs.c).
            const parse_filename = ctx.runtime.atoms.name(parse_error.filename) orelse filename;
            _ = error_stack_ops.throwParseSyntaxError(ctx, global, parse_filename, parse_error.position.line, parse_error.position.column, parse_error.message) catch |err| break :blk err;
            break :blk error.SyntaxError;
        }
        _ = compiled.functionBytecode() orelse break :blk error.InvalidBytecode;
        const owned_root = compiled.takeFunctionBytecodeValue() orelse break :blk error.InvalidBytecode;
        var root_function_value = object_ops.createRootBytecodeFunctionObject(
            compile_realm,
            global,
            owned_root,
            .root_global,
        ) catch |err| break :blk err;
        var root_values = [_]*core.JSValue{
            &root_function_value,
        };
        var root_frame = core.runtime.ValueRootFrame{
            .values = &root_values,
        };
        root_frame.activate(ctx.runtime);
        defer root_frame.deactivate(ctx.runtime);
        const root_function_object = object_ops.functionObjectFromValue(root_function_value) orelse break :blk error.InvalidBytecode;
        const root_bytecode_value = root_function_object.functionBytecode() orelse break :blk error.InvalidBytecode;
        const function = call_runtime.functionBytecodeFromValue(root_bytecode_value) orelse break :blk error.InvalidBytecode;
        var nested_stack = stack_mod.Stack.init(ctx.runtime, ctx.runtime.stackSize());
        defer nested_stack.deinit(ctx.runtime);
        break :blk zjs_vm.runWithCallEnv(.{
            .ctx = compile_realm,
            .stack = &nested_stack,
            .function = function,
            .initial_this_value = global.value(),
            .var_refs = root_function_object.functionCaptures(),
            .output = output,
            .global = global,
            .strict_unresolved_get_var = function.isStrictMode(),
            .current_function_value = root_function_value,
            .direct_eval_vars_reach_global = true,
        }) catch |err| exception_ops.normalizeEvalRuntimeError(err);
    };

    if (use_global_lexicals) {
        var rooted_result = result catch |err| {
            try restoreEvalGlobalLexicals(ctx, global, saved_lexicals, keep_active_lexicals);
            return err;
        };
        var root_frame = core.runtime.rootValues(.{&rooted_result});
        root_frame.activate(ctx.runtime);
        defer root_frame.deactivate(ctx.runtime);
        try restoreEvalGlobalLexicals(ctx, global, saved_lexicals, keep_active_lexicals);
        return rooted_result;
    }
    return result;
}
