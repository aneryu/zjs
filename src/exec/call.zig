//! Public call entry, engine-global installation, and native builtin dispatch.
//!
//! Callee, receiver, and arguments are value snapshots; call paths must root
//! live inputs across GC and publish returned values before the next GC point.
//! Heap owners trace retained values. The import/alias wall preserves dispatch and
//! ownership seams across extracted builtin domains. The explicit
//! `ctx`/`output`/`global`/caller-function/caller-frame tuple is a measured call
//! ABI: do not republish it through shared context state, and keep hot dispatch
//! arms separate from cold host/error paths. Native calls follow
//! QuickJS js_call_c_function and OP_call_method.

const core = @import("../core/root.zig");
const bytecode = @import("../bytecode.zig");

const frame_mod = @import("frame.zig");
const globals_mod = core.global_slots;
const property_ops = @import("property_ops.zig");
const value_ops = @import("value_ops.zig");
const call_runtime = @import("call_runtime.zig");
const array_ops = @import("array_ops.zig");
const standard_globals = @import("standard_globals.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const exception_ops = @import("exception_ops.zig");

const object_ops = @import("object_ops.zig");
const unicode = @import("../libs/unicode.zig");
const std = @import("std");
const HostError = exception_ops.HostError;

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

fn engineGlobalOwnPropertyCapacity() usize {
    return standard_globals.standardGlobalOwnPropertyCapacity() + 4; // globalThis, NaN, Infinity, undefined
}

pub fn contextGlobalOwnPropertyCapacity() usize {
    return engineGlobalOwnPropertyCapacity() + 1; // scriptArgs, installed by the public CLI host setup
}

pub fn installEngineGlobals(ctx: *core.JSContext, global: *core.Object) !void {
    const rt = ctx.runtime;
    try global.reserveOwnPropertyCapacityAssumingPlain(rt, engineGlobalOwnPropertyCapacity());
    // Bind the explicitly supplied Realm before publishing lazy host slots.
    try ctx.installStandardGlobals(global);
    try defineGlobalThisProperty(rt, global);
    try global.defineOwnPropertyAssumingNew(rt, core.atom.ids.NaN, core.Descriptor.data(core.JSValue.float64(std.math.nan(f64)), .none));
    try global.defineOwnPropertyAssumingNew(rt, core.atom.ids.Infinity, core.Descriptor.data(core.JSValue.float64(std.math.inf(f64)), .none));
    try global.defineOwnPropertyAssumingNew(rt, core.atom.ids.undefined_, core.Descriptor.data(core.JSValue.undefinedValue(), .none));
}

pub fn defineObjectProperty(rt: *core.JSRuntime, object: *core.Object, key: core.Atom, value: core.JSValue) !void {
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, .all));
}

fn defineGlobalThisProperty(rt: *core.JSRuntime, global: *core.Object) !void {
    try global.defineOwnPropertyAssumingNew(rt, core.atom.ids.globalThis, core.Descriptor.data(global.value(), .method));
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

pub fn callNativeFunctionRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
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
            &.{},
            function_object,
            this_value,
            record,
            args,
            caller_function,
            caller_frame,
        );
    }
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse return null;
    if (try builtin_dispatch.callInternalRecord(ctx, output, global, &.{}, function_object, this_value, native_ref, args, caller_function, caller_frame)) |value| return value;
    return switch (native_ref.domain) {
        // Migrated to the internal record table (internal_builtins.table);
        // reaching here means the id is not installed, which only happens
        // for corrupt ids.
        .math, .json, .uri, .number, .date, .error_object, .function, .primitive, .iterator, .collection, .reflect, .buffer, .string, .object, .array, .regexp, .atomics, .promise, .weak_ref, .disposable => error.TypeError,
        .engine_helper => blk: {
            const realm = try builtin_dispatch.finalCallableRealmView(ctx, function_object);
            break :blk try callEngineHelperRecord(realm.realm, realm.global, this_value, native_ref.id);
        },
    };
}

/// `.engine_helper` native-builtin domain: engine helpers with no spec
/// namespace (the shared species getter and CallSite methods).
pub fn callEngineHelperRecord(
    ctx: *core.JSContext,
    global: *core.Object,
    this_value: core.JSValue,
    id: u32,
) HostError!core.JSValue {
    return switch (id) {
        @intFromEnum(core.function.EngineHelperMethod.species_getter) => this_value,
        @intFromEnum(core.function.EngineHelperMethod.callsite_get_function),
        @intFromEnum(core.function.EngineHelperMethod.callsite_get_function_name),
        @intFromEnum(core.function.EngineHelperMethod.callsite_get_file_name),
        @intFromEnum(core.function.EngineHelperMethod.callsite_get_line_number),
        @intFromEnum(core.function.EngineHelperMethod.callsite_get_column_number),
        @intFromEnum(core.function.EngineHelperMethod.callsite_is_native),
        => {
            const receiver = thisObject(this_value) orelse return callSiteReceiverError(ctx, global);
            return exception_ops.callSiteMethodById(receiver, @enumFromInt(id)) orelse callSiteReceiverError(ctx, global);
        },
        else => error.TypeError,
    };
}

fn callSiteReceiverError(ctx: *core.JSContext, global: *core.Object) HostError!core.JSValue {
    return exception_ops.throwTypeErrorMessage(ctx, global, "CallSite method expects CallSite as receiver");
}

/// `Function.prototype.bind` body. Stays in exec because `createBoundFunction`
/// and its proxy-aware property helpers are call.zig internals (covered by the
/// in-file tests); the `.function` domain record handler delegates here.
pub fn functionBindCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
) HostError!core.JSValue {
    if (thisObject(this_value) == null or !call_runtime.isCallableValue(this_value)) return error.NotAFunction;
    const bound_this = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const bound_args = if (args.len >= 1) args[1..] else args[0..0];
    return createBoundFunction(ctx, output, global, this_value, bound_this, bound_args);
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
        // naming `string_ops.constructWithPrototype`: the record's
        // construct branch forwards `args`/`new_target` straight to that body.
        return (try builtin_dispatch.callConstructRecord(ctx, null, null, null, string_construct_ref, thisObject(values[1]), values[0..1], null, null)) orelse error.TypeError;
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

    const symbol_value = try rt.symbolValue(symbol_atom);
    const wrapper_value = try primitiveWrapper(ctx, core.class.ids.symbol, symbol_value, null);
    const wrapper = try property_ops.expectObject(wrapper_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = wrapper.objectData() orelse return error.TypeError;
    try std.testing.expect(stored.same(symbol_value));

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn boundFunctionNameValue(rt: *core.JSRuntime, target_name: core.JSValue) !core.JSValue {
    const prefix = try value_ops.createStringValue(rt, "bound ");
    if (!target_name.isString()) return prefix;
    // A concatenation (rope for long names) keeps `bind` chains linear.
    return value_ops.stringAdd(rt, prefix, target_name);
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
    target: core.JSValue,
    bound_this: core.JSValue,
    bound_args: []const core.JSValue,
) !core.JSValue {
    const rt = ctx.runtime;
    var rooted_target = target;
    var rooted_bound_this = bound_this;
    var rooted_prototype = core.JSValue.nullValue();
    var root_values = [_]*core.JSValue{
        &rooted_target,
        &rooted_bound_this,
        &rooted_prototype,
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
    // BoundFunctionCreate step 1, ? Target.[[GetPrototypeOf]](), precedes the
    // `length` and `name` reads (Function.prototype.bind steps 3-8).
    const realm_global = global orelse ctx.global orelse return error.InvalidBuiltinRegistry;
    if (try object_ops.objectGetPrototypeOfStep(ctx, output, realm_global, target_object, null, null)) |prototype| {
        rooted_prototype = prototype.value();
    }
    const length_value = if (try object_ops.proxyAwareOwnPropertyDescriptor(ctx, output, realm_global, target_object, core.atom.ids.length, null, null) != null) blk: {
        const target_length = try object_ops.getValueProperty(ctx, output, realm_global, rooted_target, core.atom.ids.length, null, null);
        break :blk boundFunctionLengthValue(target_length, rooted_bound_args.len);
    } else core.JSValue.int32(0);
    const target_name = try object_ops.getValueProperty(ctx, output, realm_global, rooted_target, core.atom.ids.name, null, null);
    const name_value = try boundFunctionNameValue(rt, target_name);

    const object = try core.Object.create(rt, core.class.ids.bound_function, object_ops.objectFromValue(rooted_prototype));
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
        var owned_bound_args_root = array_ops.ValueSliceRoot{};
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
    // SetFunctionLength, then SetFunctionName: own keys are length, name.
    try object.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(length_value, .{ .configurable = true }));
    try object.defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.data(name_value, .{ .configurable = true }));
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
    const this_value = try rt.symbolValue(this_atom);
    const arg_atom = try rt.atoms.newValueSymbol("gc-bound-arg-symbol");
    const arg_value = try rt.symbolValue(arg_atom);
    const bound_args = [_]core.JSValue{arg_value};

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const bound_value = try createBoundFunction(
        ctx,
        null,
        null,
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

    _ = try rt.collectForTest();
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
    target_object.setNativeBuiltinIdAndRecord(core.function.nativeBuiltinId(.engine_helper, @intFromEnum(core.function.EngineHelperMethod.species_getter)));

    const bound_value = try createBoundFunction(
        ctx,
        null,
        null,
        target,
        core.JSValue.undefinedValue(),
        &.{},
    );

    const arg_atom = try rt.atoms.newValueSymbol("gc-call-legacy-inline-arg-root");
    const arg_value = try rt.symbolValue(arg_atom);
    const args = [_]core.JSValue{arg_value};

    const Trigger = struct {
        rt: *core.JSRuntime,
        atom_id: core.Atom,
        saw_arg: bool = false,
        trace_failed: bool = false,

        fn trigger(context: ?*anyopaque, size: usize) void {
            _ = size;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = self.rt.collectFull() catch {}; // engine-frames-active trigger
            self.saw_arg = self.rt.atoms.name(self.atom_id) != null;
        }
    };

    var trigger = Trigger{
        .rt = rt,
        .atom_id = arg_atom,
    };
    const saved_trigger_fn = rt.gc.heap_budget.installProbe(.{ .run = Trigger.trigger, .context = &trigger });
    defer rt.gc.heap_budget.restoreProbe(saved_trigger_fn);

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
    rt.gc.heap_budget.restoreProbe(saved_trigger_fn);

    try std.testing.expect(!trigger.trace_failed);
    try std.testing.expect(trigger.saw_arg);

    _ = try rt.collectForTest();
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
        arg_slot.* = try rt.symbolValue(atom_slot.*);
    }

    const Trigger = struct {
        rt: *core.JSRuntime,
        atom_ids: []const core.Atom,
        collections: usize = 0,
        lost_arg: bool = false,

        fn trigger(context: ?*anyopaque, size: usize) void {
            _ = size;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = self.rt.collectFull() catch {};
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

    var trigger = Trigger{
        .rt = rt,
        .atom_ids = arg_atoms[0..],
    };
    const saved_trigger_fn = rt.gc.heap_budget.installProbe(.{ .run = Trigger.trigger, .context = &trigger });
    defer rt.gc.heap_budget.restoreProbe(saved_trigger_fn);

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
    rt.gc.heap_budget.restoreProbe(saved_trigger_fn);

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

pub fn functionToStringValue(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    if (value.is(.function_bytecode)) {
        const function_bytecode = functionBytecodeFromValue(value) orelse return error.TypeError;
        return functionBytecodeToStringValue(rt, function_bytecode, null);
    }

    const object = thisObject(value) orelse return error.NotAFunction;
    if (object.isProxy()) {
        // Only IsCallable matters (§20.2.3.5 step 4); a revoked callable
        // proxy keeps [[Call]].
        if (!call_runtime.isCallableValue(value)) return error.NotAFunction;
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
    if (core.class.isFunctionClass(object.class_id)) {
        if (object.functionSource()) |source| return source;
        return nativeFunctionSourceValue(rt, object);
    }
    return error.NotAFunction;
}

/// The native function's intrinsic name (owned bytes), for diagnostics and
/// embedder queries; dispatch never consults it.
pub fn nativeFunctionNameForVm(rt: *core.JSRuntime, function_object: *core.Object) ![]u8 {
    const dispatch_atom = function_object.nativeDispatchName();
    if (dispatch_atom != core.atom.null_atom) {
        if (rt.atoms.name(dispatch_atom)) |bytes| {
            return try rt.nativeAllocator().dupe(u8, bytes);
        }
    }
    const name_value = (try call_runtime.nativeFunctionName(rt, function_object)) orelse return error.TypeError;
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(rt.nativeAllocator());
    try value_ops.appendRawString(rt, &buffer, name_value);
    return buffer.toOwnedSlice(rt.nativeAllocator());
}

const functionBytecodeFromValue = call_runtime.functionBytecodeFromValue;

fn functionBytecodeToStringValue(
    rt: *core.JSRuntime,
    function_bytecode: *const bytecode.FunctionBytecode,
    object: ?*core.Object,
) !core.JSValue {
    if (function_bytecode.sourceText()) |source| {
        try rt.interrupt.pollNativeBulkWork(source.len);
        return value_ops.createStringValue(rt, source);
    }
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
        if (try call_runtime.nativeFunctionName(rt, function_object)) |stored_name| {
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

pub fn thisObject(value: core.JSValue) ?*core.Object {
    if (!value.is(.object)) return null;
    const header = value.refHeader() orelse return null;
    return core.Object.fromHeader(header);
}

pub fn materializeMappedArgumentsDescriptorValue(
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
        try std.testing.expect(call_runtime.isCallableValue(function_value));
        try std.testing.expect(core.class.isFunctionClass(class_id));
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
    if (ctx.runtime.stack.call_depth == 0) ctx.runtime.stack.captureNativeTop();

    const context_global = ctx.global;
    const use_global_lexicals = context_global == null or context_global.? != global;
    const keep_active_lexicals = context_global == null;
    const saved_lexicals = ctx.lexicals;
    if (use_global_lexicals) ctx.setLexicals(global.globalLexicals(ctx.runtime));

    const EvalResult = @typeInfo(@TypeOf(evalGlobalScriptSource)).@"fn".return_type.?;
    const result: EvalResult = blk: {
        const compile_realm = ctx.runtime.contexts.forGlobal(global, .include_constructing) orelse break :blk error.InvalidBuiltinRegistry;
        var compiled = parser.compile(.{ .realm = compile_realm }, source, .{ .mode = .script, .filename = filename, .strict = false, .return_completion = true }) catch |err| break :blk err;
        defer compiled.deinit();
        if (compiled.syntax_error) |*parse_error| {
            // Compile-error surface: own fileName/lineNumber/columnNumber +
            // leading stack line (build_backtrace filename branch,
            // quickjs.c).
            const parse_filename = ctx.runtime.atoms.name(parse_error.filename) orelse filename;
            _ = exception_ops.throwParseSyntaxError(ctx, global, parse_filename, parse_error.position.line, parse_error.position.column, parse_error.message) catch |err| break :blk err;
            break :blk error.SyntaxError;
        }
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
