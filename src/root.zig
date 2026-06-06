const std = @import("std");

const zjs_kernel = @import("kernel/root.zig");
pub const runtime = @import("runtime/public.zig");
const zjs_core = @import("core/root.zig");
const zjs_exec = @import("exec/root.zig");
const zjs_builtins = @import("builtins/root.zig");

pub const JSRuntime = zjs_kernel.JSRuntime;
pub const JSContext = zjs_kernel.JSContext;
pub const Object = zjs_kernel.Object;
pub const ffi = zjs_kernel.ffi;
pub const JSValue = zjs_kernel.JSValue;
pub const JSValueHandle = zjs_kernel.JSValueHandle;
pub const LocalHandle = zjs_kernel.LocalHandle;
pub const HandleScope = zjs_kernel.HandleScope;
pub const WeakPersistent = zjs_kernel.WeakPersistent;
pub const WeakPersistentValue = zjs_kernel.WeakPersistentValue;
pub const RuntimeOptions = zjs_kernel.RuntimeOptions;
pub const RuntimeMemoryUsage = zjs_kernel.RuntimeMemoryUsage;
pub const ContextOptions = zjs_kernel.ContextOptions;
pub const EvalOptions = zjs_kernel.EvalOptions;
pub const EvalMode = zjs_kernel.EvalMode;
pub const EvalTiming = zjs_kernel.EvalTiming;
pub const DataPropertyOptions = zjs_kernel.DataPropertyOptions;
pub const PropertyAccessOptions = zjs_kernel.PropertyAccessOptions;
pub const PropertyDescriptor = zjs_kernel.PropertyDescriptor;
pub const ExternalFunctionOptions = zjs_kernel.ExternalFunctionOptions;
pub const FunctionCallOptions = zjs_kernel.FunctionCallOptions;
pub const ErrorOptions = zjs_kernel.ErrorOptions;
pub const ScriptEvalOptions = zjs_kernel.ScriptEvalOptions;
pub const SharedArrayBufferRef = zjs_kernel.SharedArrayBufferRef;
pub const ExternalHostCall = zjs_kernel.ExternalHostCall;
pub const ExternalHostCallFn = zjs_kernel.ExternalHostCallFn;
pub const ExternalHostFinalizer = zjs_kernel.ExternalHostFinalizer;
pub const OpcodeProfile = zjs_kernel.OpcodeProfile;
pub const default_stack_size = zjs_kernel.default_stack_size;
pub const default_gc_threshold = zjs_kernel.default_gc_threshold;
pub const PropNameID = zjs_kernel.PropNameID;
pub const JSString = zjs_kernel.JSString;
pub const JSBytes = zjs_kernel.JSBytes;
pub const binding = zjs_kernel.binding;
pub const activateOpcodeProfile = zjs_kernel.activateOpcodeProfile;

pub const value = struct {
    pub const Value = zjs_kernel.JSValue;
    pub const Local = zjs_kernel.LocalHandle;
    pub const Ref = zjs_kernel.JSValueHandle;
    pub const WeakRef = zjs_kernel.WeakPersistentValue;

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
    pub const Call = zjs_kernel.ExternalHostCall;
    pub const Function = zjs_kernel.ExternalHostCallFn;
    pub const NativeClass = zjs_kernel.binding.JSObject;
    pub const NativeObject = zjs_kernel.Object;

    var test_host_context: u8 = 0;

    pub fn exposeStdOsGlobals(ctx: *JSContext) !void {
        try zjs_exec.call.installLegacyStdOsGlobals(ctx);
    }

    pub fn defineScriptArgs(ctx: *JSContext, args: []const []const u8) !void {
        try object.defineStringArrayGlobal(ctx, "scriptArgs", args);
    }

    pub fn defineArgvGlobals(ctx: *JSContext, argv0: []const u8, exec_argv: []const []const u8) !void {
        const rt = ctx.runtimePtr();
        const global = try ctx.globalObject();
        try object.defineStringProperty(rt, global, "argv0", argv0);
        try object.defineStringArrayGlobal(ctx, "execArgv", exec_argv);
    }

    pub fn installTest262HostGlobals(ctx: *JSContext) !void {
        const rt = ctx.runtimePtr();
        const global = try ctx.globalObject();
        const ns_value = try ctx.getProperty(global.value(), "$262");
        defer ns_value.free(rt);

        var created_ns = false;
        const ns_target = if (ns_value.isObject()) ns_value else result: {
            const obj_value = try ctx.createObject();
            try ctx.defineDataProperty(global.value(), "$262", obj_value, .{ .enumerable = true });
            created_ns = true;
            break :result obj_value;
        };
        defer if (created_ns) ns_target.free(rt);

        const methods = [_]struct {
            name: []const u8,
            length: i32,
            function: Function,
        }{
            .{ .name = "evalScript", .length = 1, .function = wrapExternalWithFunc(test262EvalScript) },
            .{ .name = "createRealm", .length = 0, .function = wrapExternal(test262CreateRealm) },
            .{ .name = "gc", .length = 0, .function = wrapExternal(test262Gc) },
        };
        inline for (methods) |method| {
            const func_value = try createExternalHostFunctionWithRealm(ctx, method.name, method.length, method.function, false, global);
            defer func_value.free(rt);
            try ctx.defineDataProperty(ns_target, method.name, func_value, .{ .enumerable = false });
        }
    }

    fn createExternalHostFunctionWithRealm(
        ctx: *JSContext,
        name: []const u8,
        length: i32,
        function: Function,
        with_prototype: bool,
        realm_global: ?*Object,
    ) !value.Value {
        return ctx.createExternalFunction(name, length, &test_host_context, function, null, .{
            .with_prototype = with_prototype,
            .realm_global = realm_global,
        });
    }

    pub fn evalGlobalScriptSource(
        ctx: *JSContext,
        output: ?*std.Io.Writer,
        global: *Object,
        source: []const u8,
        filename: []const u8,
    ) !value.Value {
        return zjs_exec.call.qjsEvalGlobalScriptSource(ctx, output, global, source, filename);
    }

    pub fn evalGlobalScriptValue(
        ctx: *JSContext,
        output: ?*std.Io.Writer,
        global: *Object,
        source_value: value.Value,
        filename: []const u8,
    ) !value.Value {
        if (!source_value.isString()) return error.TypeError;
        const source = try value.toOwnedString(ctx.runtimePtr(), source_value);
        defer ctx.runtimePtr().memory.allocator.free(source);
        return evalGlobalScriptSource(ctx, output, global, source, filename);
    }

    fn wrapExternal(comptime function: anytype) Function {
        return struct {
            fn call(_: *anyopaque, host_call: Call) anyerror!value.Value {
                const ctx: *JSContext = @ptrCast(@alignCast(host_call.ctx));
                return function(ctx, host_call.output, host_call.global, host_call.args);
            }
        }.call;
    }

    fn wrapExternalWithFunc(comptime function: anytype) Function {
        return struct {
            fn call(_: *anyopaque, host_call: Call) anyerror!value.Value {
                const ctx: *JSContext = @ptrCast(@alignCast(host_call.ctx));
                const global = host_call.global orelse host_call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
                return function(ctx, host_call.output, global, host_call.func_obj, host_call.args);
            }
        }.call;
    }

    fn test262EvalScript(
        ctx: *JSContext,
        output: ?*std.Io.Writer,
        global: *Object,
        function_object: *Object,
        args: []const value.Value,
    ) !value.Value {
        if (args.len == 0) return value.undefinedValue();
        if (!args[0].isString()) return error.TypeError;
        const eval_global = (try ctx.functionRealmGlobal(function_object.value())) orelse global;
        return evalGlobalScriptValue(ctx, output, eval_global, args[0], "<evalScript>");
    }

    fn test262CreateRealm(
        ctx: *JSContext,
        output: ?*std.Io.Writer,
        global: ?*Object,
        args: []const value.Value,
    ) !value.Value {
        _ = output;
        _ = global;
        _ = args;
        const realm_value = try ctx.createRealm();
        errdefer realm_value.free(ctx.runtimePtr());
        const realm_global = try ctx.realmGlobalObject(realm_value);
        const eval_func = try createExternalHostFunctionWithRealm(ctx, "evalScript", 1, wrapExternalWithFunc(test262EvalScript), false, realm_global);
        defer eval_func.free(ctx.runtimePtr());
        try ctx.defineDataProperty(realm_value, "evalScript", eval_func, .{});
        return realm_value;
    }

    fn test262Gc(
        ctx: *JSContext,
        output: ?*std.Io.Writer,
        global: ?*Object,
        args: []const value.Value,
    ) !value.Value {
        _ = output;
        _ = global;
        _ = args;
        _ = ctx.runtimePtr().runObjectCycleRemoval();
        return value.undefinedValue();
    }
};

pub const object = struct {
    pub const Builder = struct {};
    pub const Template = struct {};
    pub const Descriptor = zjs_core.Descriptor;
    pub const MemoryAccount = zjs_core.memory.MemoryAccount;
    pub const String = zjs_core.string.String;
    pub const Atom = struct {
        pub const ids = struct {
            pub const prototype = zjs_core.atom.ids.prototype;
        };

        pub fn atomFromUInt32(index: u32) zjs_core.Atom {
            return zjs_core.atom.atomFromUInt32(index);
        }

        pub fn predefinedId(name: []const u8, kind: zjs_core.atom.AtomKind) ?zjs_core.Atom {
            return zjs_core.atom.predefinedId(name, kind);
        }
    };
    pub const Buffer = struct {
        pub const isTypedArrayObject = zjs_builtins.buffer.isTypedArrayObject;
        pub const typedArrayByteLength = zjs_builtins.buffer.typedArrayByteLength;
        pub const arrayBufferConstructLength = zjs_builtins.buffer.arrayBufferConstructLength;
        pub const typedArrayConstructFullBufferOwned = zjs_builtins.buffer.typedArrayConstructFullBufferOwned;
    };

    pub fn createPlain(rt: *JSRuntime) !*Object {
        return Object.create(rt, zjs_core.class.ids.object, null);
    }

    pub fn createError(rt: *JSRuntime, prototype: ?*Object) !*Object {
        return Object.create(rt, zjs_core.class.ids.error_, prototype);
    }

    pub fn createArray(rt: *JSRuntime, prototype: ?*Object) !*Object {
        return Object.createArray(rt, prototype);
    }

    pub fn createArrayBuffer(rt: *JSRuntime, prototype: ?*Object) !*Object {
        return Object.create(rt, zjs_core.class.ids.array_buffer, prototype);
    }

    pub fn fromValue(v: value.Value) ?*Object {
        if (!v.isObject()) return null;
        const header = v.refHeader() orelse return null;
        if (header.kind != .object) return null;
        return @fieldParentPtr("header", header);
    }

    pub fn isCallableValue(v: value.Value) bool {
        const obj = fromValue(v) orelse return false;
        return obj.class_id == zjs_core.class.ids.c_function or
            obj.class_id == zjs_core.class.ids.bytecode_function or
            obj.class_id == zjs_core.class.ids.c_closure or
            obj.class_id == zjs_core.class.ids.bound_function;
    }

    pub fn isPromiseObject(obj: *Object) bool {
        return obj.class_id == zjs_core.class.ids.promise;
    }

    pub fn isPromiseValue(v: value.Value) bool {
        const obj = fromValue(v) orelse return false;
        return isPromiseObject(obj);
    }

    pub fn isArrayBufferObject(obj: *Object) bool {
        return obj.class_id == zjs_core.class.ids.array_buffer;
    }

    pub fn isTypedArrayObject(obj: *Object) bool {
        return zjs_builtins.buffer.isTypedArrayObject(obj);
    }

    pub fn typedArrayByteLength(rt: *JSRuntime, obj: *Object) !usize {
        return zjs_builtins.buffer.typedArrayByteLength(rt, obj);
    }

    pub fn arrayBufferConstructLength(rt: *JSRuntime, len: usize, proto: ?*Object) !value.Value {
        return zjs_builtins.buffer.arrayBufferConstructLength(rt, len, null, proto);
    }

    pub fn typedArrayConstructFullBufferOwned(
        rt: *JSRuntime,
        element_size: usize,
        kind: u8,
        buffer_value: value.Value,
        buffer: *Object,
        prototype: ?*Object,
    ) !value.Value {
        return zjs_builtins.buffer.typedArrayConstructFullBufferOwned(rt, @intCast(element_size), kind, buffer_value, buffer, prototype);
    }

    pub fn atomFromUInt32(index: u32) zjs_core.Atom {
        return zjs_core.atom.atomFromUInt32(index);
    }

    pub fn prototypeAtom() zjs_core.Atom {
        return zjs_core.atom.ids.prototype;
    }

    pub fn predefinedStringAtom(name: []const u8) ?zjs_core.Atom {
        return zjs_core.atom.predefinedId(name, .string);
    }

    pub fn getProperty(rt: *JSRuntime, obj: *Object, name: []const u8) !value.Value {
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        return obj.getProperty(key);
    }

    pub fn defineValueProperty(rt: *JSRuntime, obj: *Object, name: []const u8, v: value.Value) !void {
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        try obj.defineOwnProperty(rt, key, zjs_core.Descriptor.data(v, true, true, true));
    }

    pub fn defineHiddenValueProperty(rt: *JSRuntime, obj: *Object, name: []const u8, v: value.Value) !void {
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        try obj.defineOwnProperty(rt, key, zjs_core.Descriptor.data(v, false, false, false));
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
        try obj.defineOwnProperty(rt, key, zjs_core.Descriptor.accessor(getter, setter, true, true));
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
        const rt = ctx.runtimePtr();
        const global = try ctx.globalObject();
        const values = try rt.memory.alloc(value.Value, items.len);
        defer rt.memory.free(value.Value, values);
        var initialized: usize = 0;
        defer {
            for (values[0..initialized]) |item| item.free(rt);
        }
        for (items, 0..) |item, index| {
            values[index] = try value.createString(rt, item);
            initialized += 1;
        }

        const array_prototype = try constructorPrototypeObject(rt, global, "Array");
        const array = try createArray(rt, array_prototype);
        const array_value = array.value();
        errdefer array_value.free(rt);
        for (values, 0..) |item, index| {
            try array.defineOwnProperty(rt, atomFromUInt32(@intCast(index)), zjs_core.Descriptor.data(item, true, true, true));
        }
        array.length = @intCast(items.len);
        try defineValueProperty(rt, global, name, array_value);
        array_value.free(rt);
    }

    pub fn constructorPrototypeObject(rt: *JSRuntime, global: *Object, name: []const u8) !?*Object {
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        const constructor_value = global.getProperty(key);
        defer constructor_value.free(rt);
        const constructor = fromValue(constructor_value) orelse return null;
        const prototype_value = constructor.getProperty(zjs_core.atom.ids.prototype);
        defer prototype_value.free(rt);
        return fromValue(prototype_value);
    }

    pub fn appendArrayValue(rt: *JSRuntime, array: *Object, v: value.Value) !void {
        try array.defineOwnProperty(
            rt,
            atomFromUInt32(array.length),
            zjs_core.Descriptor.data(v, true, true, true),
        );
        array.length += 1;
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
        return module_graph.evalFileModuleGraphWithHostHooks(ctx.runtimePtr(), ctx, source_text, output, filename, host_hooks, allocator);
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
    _ = zjs_kernel;
    _ = runtime;
}

test "public root exposes only the explicit runtime surface" {
    try std.testing.expect(!@hasDecl(@This(), "internal"));
    try std.testing.expect(!@hasDecl(@This(), "core"));
    try std.testing.expect(!@hasDecl(@This(), "exec"));
    try std.testing.expect(!@hasDecl(@This(), "kernel"));
    try std.testing.expect(!@hasDecl(@This(), "low"));

    try std.testing.expect(@hasDecl(runtime, "EventLoop"));
    try std.testing.expect(@hasDecl(runtime, "EventLoopOptions"));
    try std.testing.expect(@hasDecl(runtime, "EventLoopRunResult"));
    try std.testing.expect(@hasDecl(runtime, "runUntilIdle"));
    try std.testing.expect(@hasDecl(runtime, "cleanupAtomicsWaitersForContext"));
    try std.testing.expect(@hasDecl(runtime, "wakeAtomicsWaitersForRuntimes"));
    try std.testing.expect(@hasDecl(runtime, "cleanupWorkersForRuntime"));
    try std.testing.expect(@hasDecl(runtime, "detachArrayBuffer"));
    try std.testing.expect(@hasDecl(runtime, "evalFileModuleGraphWithOutput"));
    try std.testing.expect(@hasDecl(runtime, "resolveModuleSpecifier"));
    try std.testing.expect(@hasDecl(runtime, "Plugin"));
    try std.testing.expect(@hasDecl(runtime, "PluginInstallOptions"));
    try std.testing.expect(Object == zjs_kernel.Object);

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
