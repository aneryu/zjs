const std = @import("std");

const zjs_binding = @import("binding/root.zig");
pub const runtime = @import("runtime/public.zig");
const zjs_core = @import("core/root.zig");
const zjs_exec = @import("exec/root.zig");
const zjs_builtins = @import("builtins/root.zig");
const CoreObject = zjs_binding.Object;

pub const JSRuntime = zjs_binding.JSRuntime;
pub const JSContext = zjs_binding.JSContext;
pub const ffi = zjs_binding.ffi;
pub const JSValue = zjs_binding.JSValue;
pub const RuntimeOptions = zjs_binding.RuntimeOptions;
pub const RuntimeMemoryUsage = zjs_binding.RuntimeMemoryUsage;
pub const OpcodeProfile = zjs_binding.OpcodeProfile;
pub const default_stack_size = zjs_binding.default_stack_size;
pub const default_gc_threshold = zjs_binding.default_gc_threshold;

pub fn activateOpcodeProfile(profile: ?*OpcodeProfile) ?*OpcodeProfile {
    zjs_core.profile.setOpcodeNameProvider(zjs_exec.opcodeName);
    return zjs_binding.activateOpcodeProfile(profile);
}

pub const value = struct {
    pub const Value = zjs_binding.JSValue;
    pub const Scope = zjs_binding.HandleScope;
    pub const Local = zjs_binding.LocalHandle;
    pub const Ref = zjs_binding.JSValueHandle;
    pub const Persistent = zjs_binding.JSValueHandle;
    pub const WeakRef = zjs_binding.WeakPersistentValue;
    pub const Weak = zjs_binding.WeakPersistentValue;
    pub const String = zjs_binding.JSString;
    pub const Bytes = zjs_binding.JSBytes;

    pub fn undefinedValue() Value {
        return Value.undefinedValue();
    }

    pub fn nullValue() Value {
        return Value.nullValue();
    }

    pub fn boolean(v: bool) Value {
        return Value.boolean(v);
    }

    pub fn int32(v: i32) Value {
        return Value.int32(v);
    }

    pub fn float64(v: f64) Value {
        return Value.float64(v);
    }

    pub fn numberFromU64(v: u64) Value {
        if (v <= @as(u64, @intCast(std.math.maxInt(i32)))) {
            return Value.int32(@intCast(v));
        }
        return Value.float64(@floatFromInt(v));
    }

    pub fn numberFromI64(v: i64) Value {
        if (v >= std.math.minInt(i32) and v <= std.math.maxInt(i32)) {
            return Value.int32(@intCast(v));
        }
        return Value.float64(@floatFromInt(v));
    }

    pub fn createString(runtime_ptr: *JSRuntime, bytes: []const u8) !Value {
        return zjs_exec.value_ops.createStringValue(runtime_ptr, bytes);
    }

    pub fn appendRawString(runtime_ptr: *JSRuntime, out: *std.ArrayList(u8), v: Value) !void {
        try zjs_exec.value_ops.appendRawString(runtime_ptr, out, v);
    }

    pub fn appendString(runtime_ptr: *JSRuntime, out: *std.ArrayList(u8), v: Value) !void {
        try zjs_exec.value_ops.appendValueString(runtime_ptr, out, v);
    }

    pub fn toOwnedString(runtime_ptr: *JSRuntime, v: Value) ![]u8 {
        var buffer = std.ArrayList(u8).empty;
        errdefer buffer.deinit(runtime_ptr.memory.allocator);
        if (v.isString()) {
            try appendRawString(runtime_ptr, &buffer, v);
        } else {
            try appendString(runtime_ptr, &buffer, v);
        }
        return buffer.toOwnedSlice(runtime_ptr.memory.allocator);
    }

    pub fn toIntegerOrInfinity(runtime_ptr: *JSRuntime, v: Value) !f64 {
        return zjs_exec.value_ops.toIntegerOrInfinity(runtime_ptr, v);
    }

    pub fn isTruthy(v: Value) bool {
        return zjs_exec.value_ops.isTruthy(v);
    }
};

pub const host = struct {
    pub const Call = zjs_binding.ExternalHostCall;
    pub const Function = zjs_binding.ExternalHostCallFn;
    pub const Finalizer = zjs_binding.ExternalHostFinalizer;
    pub const FunctionOptions = zjs_binding.ExternalFunctionOptions;
    pub const NativeClass = zjs_binding.binding.JSObject;
    pub const NativeBinding = zjs_binding.binding;
    pub const NativeObject = object.Object;
    pub const PropName = zjs_binding.PropNameID;

    pub fn defineScriptArgs(ctx: *JSContext, args: []const []const u8) !void {
        try object.defineStringArrayGlobal(ctx, "scriptArgs", args);
    }

    pub fn defineArgvGlobals(ctx: *JSContext, argv0: []const u8, exec_argv: []const []const u8) !void {
        const rt = ctx.runtimePtr();
        const global = object.fromCore(try ctx.globalObject());
        try object.defineStringProperty(rt, global, "argv0", argv0);
        try object.defineStringArrayGlobal(ctx, "execArgv", exec_argv);
    }

    pub fn evalGlobalScriptSource(
        ctx: *JSContext,
        output: ?*std.Io.Writer,
        global: *object.Object,
        source: []const u8,
        filename: []const u8,
    ) !value.Value {
        return evalGlobalScriptSourceCore(ctx, output, object.toCore(global), source, filename);
    }

    pub fn evalGlobalScriptValue(
        ctx: *JSContext,
        output: ?*std.Io.Writer,
        global: *object.Object,
        source_value: value.Value,
        filename: []const u8,
    ) !value.Value {
        if (!source_value.isString()) return error.TypeError;
        const source = try value.toOwnedString(ctx.runtimePtr(), source_value);
        defer ctx.runtimePtr().memory.allocator.free(source);
        return evalGlobalScriptSource(ctx, output, global, source, filename);
    }

    fn evalGlobalScriptSourceCore(
        ctx: *JSContext,
        output: ?*std.Io.Writer,
        global: *CoreObject,
        source: []const u8,
        filename: []const u8,
    ) !value.Value {
        return zjs_exec.call.qjsEvalGlobalScriptSource(&ctx.core, output, global, source, filename);
    }

    fn evalGlobalScriptValueCore(
        ctx: *JSContext,
        output: ?*std.Io.Writer,
        global: *CoreObject,
        source_value: value.Value,
        filename: []const u8,
    ) !value.Value {
        if (!source_value.isString()) return error.TypeError;
        const source = try value.toOwnedString(ctx.runtimePtr(), source_value);
        defer ctx.runtimePtr().memory.allocator.free(source);
        return evalGlobalScriptSourceCore(ctx, output, global, source, filename);
    }
};

pub const object = struct {
    pub const Object = opaque {};
    pub const Builder = struct {};
    pub const Template = struct {};
    pub const MemoryAccount = zjs_core.memory.MemoryAccount;
    pub const SharedArrayBufferRef = zjs_binding.SharedArrayBufferRef;
    pub const String = zjs_core.string.String;

    fn fromCore(obj: *CoreObject) *Object {
        return @ptrCast(obj);
    }

    fn toCore(obj: *Object) *CoreObject {
        return @ptrCast(@alignCast(obj));
    }

    fn optionalToCore(obj: ?*Object) ?*CoreObject {
        return if (obj) |some| toCore(some) else null;
    }

    fn coreFromValue(v: value.Value) ?*CoreObject {
        if (!v.isObject()) return null;
        const header = v.refHeader() orelse return null;
        if (header.kind != .object) return null;
        return @fieldParentPtr("header", header);
    }

    pub fn toValue(obj: *Object) value.Value {
        return toCore(obj).value();
    }

    pub fn arrayLength(obj: *Object) u32 {
        return toCore(obj).length;
    }

    pub fn promiseResult(obj: *Object) ?value.Value {
        return toCore(obj).promiseResult();
    }

    pub fn promiseIsRejected(obj: *Object) bool {
        return toCore(obj).promiseIsRejected();
    }

    pub const OwnDataProperty = struct {
        name: []const u8,
        value: value.Value,
        enumerable: bool,
    };

    pub fn forEachOwnDataProperty(
        rt: *JSRuntime,
        obj: *Object,
        visitor_context: anytype,
        comptime visitor: anytype,
    ) !void {
        for (toCore(obj).properties) |entry| {
            if (entry.flags.deleted or entry.flags.accessor) continue;
            const stored = switch (entry.slot) {
                .data => |value_slot| value_slot,
                else => continue,
            };
            const name = rt.atoms.name(entry.atom_id) orelse continue;
            try visitor(visitor_context, OwnDataProperty{
                .name = name,
                .value = stored,
                .enumerable = entry.flags.enumerable,
            });
        }
    }

    pub const Buffer = struct {
        pub fn isTypedArrayObject(obj: *Object) bool {
            return zjs_builtins.buffer.isTypedArrayObject(toCore(obj));
        }

        pub fn typedArrayByteLength(rt: *JSRuntime, obj: *Object) !usize {
            return zjs_builtins.buffer.typedArrayByteLength(rt, toCore(obj));
        }

        pub fn ownedBytesFromObject(rt: *JSRuntime, obj: *Object) ![]u8 {
            const bytes = value.Bytes.fromObject(toCore(obj)) catch |err| return bufferViewError(err);
            return rt.memory.allocator.dupe(u8, bytes.slice());
        }

        pub fn createUint8ArrayFromBytes(rt: *JSRuntime, global: *Object, bytes: []const u8) !value.Value {
            return zjs_exec.array_ops.createUint8ArrayFromBytes(rt, toCore(global), bytes);
        }

        /// Consumes bytes allocated by `rt.memory` on success and failure.
        pub fn createUint8ArrayFromOwnedBytes(rt: *JSRuntime, global: *Object, bytes: []u8) !value.Value {
            var bytes_owned = true;
            errdefer if (bytes_owned) rt.memory.free(u8, bytes);

            if (bytes.len > @as(usize, @intCast(std.math.maxInt(i32)))) return error.RangeError;
            const buffer_proto = try constructorPrototypeObject(rt, global, "ArrayBuffer");
            const buffer_value = try zjs_builtins.buffer.arrayBufferConstructLength(rt, 0, null, optionalToCore(buffer_proto));
            var buffer_owned = true;
            errdefer if (buffer_owned) buffer_value.free(rt);

            const buffer = fromValue(buffer_value) orelse return error.TypeError;
            const buffer_core = toCore(buffer);
            try buffer_core.installByteStorage(rt, bytes);
            bytes_owned = false;

            const typed_array_proto = try constructorPrototypeObject(rt, global, "Uint8Array");
            buffer_owned = false;
            return zjs_builtins.buffer.typedArrayConstructFullBufferOwned(rt, 1, 2, buffer_value, buffer_core, optionalToCore(typed_array_proto));
        }

        fn bufferViewError(err: value.Bytes.Error) anyerror {
            return switch (err) {
                error.TypeError, error.Detached, error.OutOfBounds, error.InvalidStore, error.ReadOnly => error.TypeError,
            };
        }
    };

    pub fn createPlain(rt: *JSRuntime) !*Object {
        return fromCore(try CoreObject.create(rt, zjs_core.class.ids.object, null));
    }

    pub fn createError(rt: *JSRuntime, prototype: ?*Object) !*Object {
        return fromCore(try CoreObject.create(rt, zjs_core.class.ids.error_, optionalToCore(prototype)));
    }

    pub fn createArray(rt: *JSRuntime, prototype: ?*Object) !*Object {
        return fromCore(try CoreObject.createArray(rt, optionalToCore(prototype)));
    }

    pub fn createArrayValue(rt: *JSRuntime, prototype: ?*Object) !value.Value {
        return toValue(try createArray(rt, prototype));
    }

    pub fn createArrayBuffer(rt: *JSRuntime, prototype: ?*Object) !*Object {
        return fromCore(try CoreObject.create(rt, zjs_core.class.ids.array_buffer, optionalToCore(prototype)));
    }

    pub fn fromValue(v: value.Value) ?*Object {
        return if (coreFromValue(v)) |obj| fromCore(obj) else null;
    }

    pub fn isCallableValue(v: value.Value) bool {
        const obj = coreFromValue(v) orelse return false;
        return obj.class_id == zjs_core.class.ids.c_function or
            obj.class_id == zjs_core.class.ids.bytecode_function or
            obj.class_id == zjs_core.class.ids.c_closure or
            obj.class_id == zjs_core.class.ids.bound_function;
    }

    pub fn isPromiseObject(obj: *Object) bool {
        return toCore(obj).class_id == zjs_core.class.ids.promise;
    }

    pub fn isPromiseValue(v: value.Value) bool {
        const obj = fromValue(v) orelse return false;
        return isPromiseObject(obj);
    }

    pub fn isArrayBufferObject(obj: *Object) bool {
        return toCore(obj).class_id == zjs_core.class.ids.array_buffer;
    }

    pub fn isTypedArrayObject(obj: *Object) bool {
        return zjs_builtins.buffer.isTypedArrayObject(toCore(obj));
    }

    pub fn typedArrayByteLength(rt: *JSRuntime, obj: *Object) !usize {
        return zjs_builtins.buffer.typedArrayByteLength(rt, toCore(obj));
    }

    pub fn arrayBufferConstructLength(rt: *JSRuntime, len: usize, proto: ?*Object) !value.Value {
        return zjs_builtins.buffer.arrayBufferConstructLength(rt, len, null, optionalToCore(proto));
    }

    pub fn typedArrayConstructFullBufferOwned(
        rt: *JSRuntime,
        element_size: usize,
        kind: u8,
        buffer_value: value.Value,
        buffer: *Object,
        prototype: ?*Object,
    ) !value.Value {
        return zjs_builtins.buffer.typedArrayConstructFullBufferOwned(rt, @intCast(element_size), kind, buffer_value, toCore(buffer), optionalToCore(prototype));
    }

    fn atomFromUInt32(index: u32) zjs_core.Atom {
        return zjs_core.atom.atomFromUInt32(index);
    }

    pub fn getProperty(rt: *JSRuntime, obj: *Object, name: []const u8) !value.Value {
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        return toCore(obj).getProperty(key);
    }

    pub fn getOwnIndexPropertyValue(rt: *JSRuntime, obj: *Object, index: u32) ?value.Value {
        const desc = toCore(obj).getOwnProperty(atomFromUInt32(index)) orelse return null;
        if (!desc.value_present) {
            desc.destroy(rt);
            return null;
        }
        return desc.value;
    }

    pub fn defineValueProperty(rt: *JSRuntime, obj: *Object, name: []const u8, v: value.Value) !void {
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        try toCore(obj).defineOwnProperty(rt, key, zjs_core.Descriptor.data(v, true, true, true));
    }

    pub fn defineHiddenValueProperty(rt: *JSRuntime, obj: *Object, name: []const u8, v: value.Value) !void {
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        try toCore(obj).defineOwnProperty(rt, key, zjs_core.Descriptor.data(v, false, false, false));
    }

    pub fn defineAccessorProperty(
        rt: *JSRuntime,
        obj: *Object,
        name: []const u8,
        getter: value.Value,
        setter: value.Value,
    ) !void {
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        try toCore(obj).defineOwnProperty(rt, key, zjs_core.Descriptor.accessor(getter, setter, true, true));
    }

    pub fn defineStringProperty(rt: *JSRuntime, obj: *Object, name: []const u8, bytes: []const u8) !void {
        const string_value = try value.createString(rt, bytes);
        defer string_value.free(rt);
        try defineValueProperty(rt, obj, name, string_value);
    }

    pub fn defineHiddenStringProperty(rt: *JSRuntime, obj: *Object, name: []const u8, bytes: []const u8) !void {
        const string_value = try value.createString(rt, bytes);
        defer string_value.free(rt);
        try defineHiddenValueProperty(rt, obj, name, string_value);
    }

    pub fn defineIntProperty(rt: *JSRuntime, obj: *Object, name: []const u8, v: u16) !void {
        try defineValueProperty(rt, obj, name, value.int32(@intCast(v)));
    }

    pub fn defineHiddenIntProperty(rt: *JSRuntime, obj: *Object, name: []const u8, v: u16) !void {
        try defineHiddenValueProperty(rt, obj, name, value.int32(@intCast(v)));
    }

    pub fn defineStringArrayGlobal(ctx: *JSContext, name: []const u8, items: []const []const u8) !void {
        if (items.len == 0) {
            try defineEmptyArrayGlobal(ctx, name);
            return;
        }

        const rt = ctx.runtimePtr();
        const global = fromCore(try ctx.globalObject());
        const array_prototype = cachedArrayPrototype(global) orelse try constructorPrototypeObject(rt, global, "Array");
        const array = fromCore(try CoreObject.createArrayWithOwnPropertyCapacity(rt, optionalToCore(array_prototype), items.len));
        const array_value = toValue(array);
        errdefer array_value.free(rt);
        const array_core = toCore(array);
        for (items, 0..) |item, index| {
            const item_value = try value.createString(rt, item);
            array_core.defineOwnProperty(rt, atomFromUInt32(@intCast(index)), zjs_core.Descriptor.data(item_value, true, true, true)) catch |err| {
                item_value.free(rt);
                return err;
            };
            item_value.free(rt);
        }
        array_core.length = @intCast(items.len);
        try defineValueProperty(rt, global, name, array_value);
        array_value.free(rt);
    }

    fn cachedArrayPrototype(global: *Object) ?*Object {
        const stored = toCore(global).cachedRealmValue(.array_prototype) orelse return null;
        return fromCore(coreFromValue(stored) orelse return null);
    }

    fn defineEmptyArrayGlobal(ctx: *JSContext, name: []const u8) !void {
        const rt = ctx.runtimePtr();
        const global = fromCore(try ctx.globalObject());
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        const flags = zjs_core.property.Flags.data(true, true, true);
        try toCore(global).defineEmptyArrayAutoInitProperty(rt, key, flags, toCore(global));
    }

    pub fn constructorPrototypeObject(rt: *JSRuntime, global: *Object, name: []const u8) !?*Object {
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        const constructor_value = toCore(global).getProperty(key);
        defer constructor_value.free(rt);
        const constructor = coreFromValue(constructor_value) orelse return null;
        const prototype_value = constructor.getProperty(zjs_core.atom.ids.prototype);
        defer prototype_value.free(rt);
        return fromValue(prototype_value);
    }

    pub fn appendArrayValue(rt: *JSRuntime, array: *Object, v: value.Value) !void {
        const array_core = toCore(array);
        try array_core.defineOwnProperty(
            rt,
            atomFromUInt32(array_core.length),
            zjs_core.Descriptor.data(v, true, true, true),
        );
    }
};

test "public object appendArrayValue maintains array length once" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const array = try object.createArray(rt, null);
    const array_value = object.toValue(array);
    defer array_value.free(rt);

    try object.appendArrayValue(rt, array, value.int32(1));
    try object.appendArrayValue(rt, array, value.int32(2));

    try std.testing.expectEqual(@as(u32, 2), object.arrayLength(array));
    const first = object.getOwnIndexPropertyValue(rt, array, 0).?;
    defer first.free(rt);
    const second = object.getOwnIndexPropertyValue(rt, array, 1).?;
    defer second.free(rt);
    try std.testing.expectEqual(@as(?i32, 1), first.asInt32());
    try std.testing.expectEqual(@as(?i32, 2), second.asInt32());
}

test "public host defineScriptArgs materializes empty array on first read" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try JSContext.create(rt);
    defer ctx.destroy();

    try host.defineScriptArgs(ctx, &.{"stale"});
    try host.defineScriptArgs(ctx, &.{});
    try host.defineScriptArgs(ctx, &.{});
    const result = try ctx.eval(
        \\var desc = Object.getOwnPropertyDescriptor(globalThis, "scriptArgs");
        \\desc.writable === true &&
        \\desc.enumerable === true &&
        \\desc.configurable === true &&
        \\Array.isArray(desc.value) &&
        \\desc.value.length === 0 &&
        \\Object.getPrototypeOf(scriptArgs) === Array.prototype &&
        \\(scriptArgs.push("ok"), scriptArgs.length === 1 && scriptArgs[0] === "ok") &&
        \\delete globalThis.scriptArgs &&
        \\!("scriptArgs" in globalThis);
    , .{});
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "public Buffer helpers create and copy Uint8Array bytes" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try JSContext.create(rt);
    defer ctx.destroy();

    const global = try context.globalObject(ctx);
    const value_from_copy = try object.Buffer.createUint8ArrayFromBytes(rt, global, "abc");
    defer value_from_copy.free(rt);
    const typed_array = object.fromValue(value_from_copy).?;
    const copied = try object.Buffer.ownedBytesFromObject(rt, typed_array);
    defer rt.memory.allocator.free(copied);
    try std.testing.expectEqualStrings("abc", copied);

    const owned = try rt.memory.alloc(u8, 3);
    @memcpy(owned, "xyz");
    const value_from_owned = try object.Buffer.createUint8ArrayFromOwnedBytes(rt, global, owned);
    defer value_from_owned.free(rt);
    const owned_typed_array = object.fromValue(value_from_owned).?;
    const copied_owned = try object.Buffer.ownedBytesFromObject(rt, owned_typed_array);
    defer rt.memory.allocator.free(copied_owned);
    try std.testing.expectEqualStrings("xyz", copied_owned);
}

pub const context = struct {
    pub const Options = zjs_binding.ContextOptions;
    pub const EvalMode = zjs_binding.EvalMode;
    pub const EvalOptions = zjs_binding.EvalOptions;
    pub const EvalTiming = zjs_binding.EvalTiming;
    pub const DataPropertyOptions = zjs_binding.DataPropertyOptions;
    pub const PropertyAccessOptions = zjs_binding.PropertyAccessOptions;
    pub const PropertyDescriptor = zjs_binding.PropertyDescriptor;
    pub const ErrorOptions = zjs_binding.ErrorOptions;
    pub const ScriptEvalOptions = zjs_binding.ScriptEvalOptions;
    pub const FunctionCallOptions = struct {
        this_value: ?value.Value = null,
        output: ?*std.Io.Writer = null,
        realm_global: ?*object.Object = null,
    };

    pub fn globalObject(ctx: *JSContext) !*object.Object {
        return object.fromCore(try ctx.globalObject());
    }

    pub fn callFunction(
        ctx: *JSContext,
        callee: value.Value,
        args: []const value.Value,
        options: @This().FunctionCallOptions,
    ) !value.Value {
        return ctx.callFunction(callee, args, .{
            .this_value = options.this_value,
            .output = options.output,
            .realm_global = object.optionalToCore(options.realm_global),
        });
    }
};

pub const module = struct {
    const module_graph = @import("exec/module_graph.zig");
    pub const Key = module_graph.HostHooks.ResolvedModule;
    pub const Source = module_graph.HostHooks.LoadedModule;
    pub const Host = module_graph.HostHooks;
    pub const ResolveResult = module_graph.HostHooks.ResolvedModule;
    pub const LoadResult = module_graph.HostHooks.LoadedModule;

    pub fn evalFileGraphWithHost(
        ctx: *JSContext,
        source_text: []const u8,
        output: *std.Io.Writer,
        filename: []const u8,
        host_hooks: Host,
        allocator: std.mem.Allocator,
    ) !value.Value {
        return module_graph.evalFileModuleGraphWithHostHooks(ctx.runtimePtr(), &ctx.core, source_text, output, filename, host_hooks, allocator);
    }

    fn moduleResolutionError(err: anyerror) anyerror {
        return switch (err) {
            error.ModuleNotFound => error.ModuleNotFound,
            error.PermissionDenied => error.PermissionDenied,
            else => err,
        };
    }
};

pub const compile = struct {
    pub const SourceKind = module.Host.ModuleKind;
    pub const Options = struct {};
    pub const Cache = struct {};
};

pub const @"error" = struct {
    pub const Info = struct {
        message: []const u8,
        stack: ?[]const u8 = null,
        path: ?[]const u8 = null,
        line: ?u32 = null,
        column: ?u32 = null,
        kind: Kind = .runtime,
    };
    pub const Kind = enum {
        syntax,
        reference,
        type,
        range,
        uri,
        eval,
        runtime,
    };
    pub const Span = struct {
        start: usize,
        end: usize,
    };
};

pub const job = struct {
    pub const DrainOptions = struct {
        budget: ?usize = null,
    };
    pub const DrainResult = struct {
        jobs_drained: usize,
        has_more: bool,
    };

    pub fn drain(ctx: *JSContext, options: DrainOptions) !DrainResult {
        _ = options;
        const had_work = ctx.peekPendingPromiseJobSequence() != null;
        try ctx.runJobs(null);
        return DrainResult{
            .jobs_drained = if (had_work) 1 else 0,
            .has_more = ctx.peekPendingPromiseJobSequence() != null,
        };
    }
};

test {
    _ = zjs_binding;
    _ = runtime;
}

test "public root exposes only the explicit runtime surface" {
    try std.testing.expect(!@hasDecl(@This(), "internal"));
    try std.testing.expect(!@hasDecl(@This(), "core"));
    try std.testing.expect(!@hasDecl(@This(), "exec"));
    try std.testing.expect(!@hasDecl(@This(), "kernel"));
    try std.testing.expect(!@hasDecl(@This(), "low"));
    try std.testing.expect(!@hasDecl(@This(), "ContextOptions"));
    try std.testing.expect(!@hasDecl(@This(), "EvalOptions"));
    try std.testing.expect(!@hasDecl(@This(), "EvalMode"));
    try std.testing.expect(!@hasDecl(@This(), "EvalTiming"));
    try std.testing.expect(!@hasDecl(@This(), "ScriptEvalOptions"));

    try std.testing.expect(@hasDecl(runtime, "EventLoop"));
    try std.testing.expect(@hasDecl(runtime, "EventLoopOptions"));
    try std.testing.expect(@hasDecl(runtime, "EventLoopRunResult"));
    try std.testing.expect(@hasDecl(runtime, "runUntilIdle"));
    try std.testing.expect(@hasDecl(runtime, "cleanupAtomicsWaitersForContext"));
    try std.testing.expect(@hasDecl(runtime, "wakeAtomicsWaitersForRuntimes"));
    try std.testing.expect(@hasDecl(runtime, "detachArrayBuffer"));
    try std.testing.expect(@hasDecl(runtime, "evalFileModuleGraphWithOutput"));
    try std.testing.expect(@hasDecl(runtime, "resolveModuleSpecifier"));
    try std.testing.expect(@hasDecl(runtime, "Plugin"));
    try std.testing.expect(@hasDecl(runtime, "PluginInstallOptions"));
    try std.testing.expect(@typeInfo(object.Object) == .@"opaque");
    try std.testing.expect(!@hasDecl(object.Object, "value"));
    try std.testing.expect(!@hasDecl(@This(), "JSValueHandle"));
    try std.testing.expect(!@hasDecl(@This(), "LocalHandle"));
    try std.testing.expect(!@hasDecl(@This(), "HandleScope"));
    try std.testing.expect(!@hasDecl(@This(), "WeakPersistent"));
    try std.testing.expect(!@hasDecl(@This(), "WeakPersistentValue"));
    try std.testing.expect(!@hasDecl(@This(), "DataPropertyOptions"));
    try std.testing.expect(!@hasDecl(@This(), "PropertyAccessOptions"));
    try std.testing.expect(!@hasDecl(@This(), "PropertyDescriptor"));
    try std.testing.expect(!@hasDecl(@This(), "ExternalFunctionOptions"));
    try std.testing.expect(!@hasDecl(@This(), "FunctionCallOptions"));
    try std.testing.expect(!@hasDecl(@This(), "ErrorOptions"));
    try std.testing.expect(!@hasDecl(@This(), "SharedArrayBufferRef"));
    try std.testing.expect(!@hasDecl(@This(), "ExternalHostCall"));
    try std.testing.expect(!@hasDecl(@This(), "ExternalHostCallFn"));
    try std.testing.expect(!@hasDecl(@This(), "ExternalHostFinalizer"));
    try std.testing.expect(!@hasDecl(@This(), "PropNameID"));
    try std.testing.expect(!@hasDecl(@This(), "JSString"));
    try std.testing.expect(!@hasDecl(@This(), "JSBytes"));
    try std.testing.expect(!@hasDecl(@This(), "binding"));

    try std.testing.expect(!@hasDecl(runtime, "event_loop"));
    try std.testing.expect(!@hasDecl(runtime, "plugin"));
    try std.testing.expect(!@hasDecl(runtime, "modules"));
    try std.testing.expect(!@hasDecl(runtime, "cleanup"));
    try std.testing.expect(!@hasDecl(runtime, "buffer"));
    try std.testing.expect(!@hasDecl(runtime, "Engine"));
    try std.testing.expect(!@hasDecl(runtime, "BorrowedValue"));
    try std.testing.expect(!@hasDecl(runtime, "OwnedValue"));
    try std.testing.expect(!@hasDecl(object, "Kind"));
}
