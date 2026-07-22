const std = @import("std");
const core = @import("../core/root.zig");
const exec = @import("../exec/root.zig");

const JSRuntime = core.JSRuntime;
const Object = core.Object;
const JSValue = core.JSValue;
const Descriptor = core.Descriptor;
const class = core.class;
const atom = core.atom;
const string = core.string;
const runtime_mod = core.runtime;

fn ensureStandardGlobalsRegistered(rt: *JSRuntime) void {
    if (rt.materialize_context_global_cb == null) {
        rt.materialize_context_global_cb = struct {
            fn cb(c: *core.JSContext) anyerror!*core.Object {
                return try exec.zjs_vm.contextGlobal(c);
            }
        }.cb;
    }
    // The context-global materializer above bootstraps the standard globals
    // through `rt.installStandardGlobals`; configure the callback and its
    // matching capacity together before the first realm is materialized.
    if (rt.install_standard_globals_cb == null) {
        exec.standard_globals.configureRuntime(rt);
    }
}

pub const JSContext = struct {
    /// Stable heap identity; this pointer owns the initial RealmRef returned by
    /// `core.JSContext.createWithOptions` until `deinit`/`destroy`.
    core: *core.JSContext,

    /// Non-owning facade for callbacks whose ABI already carries the stable
    /// core realm pointer.  The facade must not be destroyed.
    pub fn borrowCore(core_ctx: *core.JSContext) JSContext {
        return .{ .core = core_ctx };
    }

    pub fn create(rt: *JSRuntime) !*JSContext {
        return createWithOptions(rt, .{});
    }

    pub fn createWithOptions(rt: *JSRuntime, options: core.ContextOptions) !*JSContext {
        const ctx = try rt.memory.create(JSContext);
        errdefer rt.memory.destroy(JSContext, ctx);
        ensureStandardGlobalsRegistered(rt);
        ctx.core = try core.JSContext.createWithOptions(rt, options);
        return ctx;
    }

    pub fn init(self: *JSContext, rt: *JSRuntime, options: core.ContextOptions) !void {
        ensureStandardGlobalsRegistered(rt);
        self.* = .{ .core = try core.JSContext.createWithOptions(rt, options) };
    }

    pub fn deinit(self: *JSContext) void {
        exec.zjs_vm.cleanupAtomicsWaitersForContext(self.core);
        self.core.destroy();
    }

    pub fn destroy(self: *JSContext) void {
        const rt = self.core.runtime;
        exec.zjs_vm.cleanupAtomicsWaitersForContext(self.core);
        self.core.destroy();
        rt.memory.destroy(JSContext, self);
    }

    // --- Core delegates ---
    pub fn runtimePtr(self: *JSContext) *JSRuntime {
        return self.core.runtime;
    }

    pub fn dupValue(self: *JSContext, val: JSValue) JSValue {
        return self.core.dupValue(val);
    }

    pub fn freeValue(self: *JSContext, val: JSValue) void {
        self.core.freeValue(val);
    }

    pub fn createValueHandle(self: *JSContext, val: JSValue) !core.runtime.JSValueHandle {
        return self.core.createValueHandle(val);
    }

    pub fn takeValueHandle(self: *JSContext, val: JSValue) !core.runtime.JSValueHandle {
        return self.core.takeValueHandle(val);
    }

    pub fn hasException(self: JSContext) bool {
        return self.core.hasException();
    }

    pub fn takeException(self: *JSContext) JSValue {
        return self.core.takeException();
    }

    pub fn clearException(self: *JSContext) void {
        self.core.clearException();
    }

    pub fn throwValue(self: *JSContext, val: JSValue) JSValue {
        return self.core.throwValue(val);
    }

    pub fn recordUnhandledRejection(self: *JSContext, val: JSValue) void {
        self.core.recordUnhandledRejection(val);
    }

    pub fn recordUnhandledPromiseRejection(self: *JSContext, promise: ?JSValue, val: JSValue) void {
        self.core.recordUnhandledPromiseRejection(promise, val);
    }

    pub fn hasUnhandledRejection(self: JSContext) bool {
        return self.core.hasUnhandledRejection();
    }

    pub fn takeUnhandledRejection(self: *JSContext) JSValue {
        return self.core.takeUnhandledRejection();
    }

    pub fn clearUnhandledRejection(self: *JSContext) void {
        self.core.clearUnhandledRejection();
    }

    pub fn classPrototypeSlotCount(self: JSContext) usize {
        return self.core.classPrototypeSlotCount();
    }

    pub fn takePendingException(self: *JSContext) JSValue {
        return self.core.takePendingException();
    }

    pub fn pushBacktraceFrame(
        self: *JSContext,
        function_name: atom.Atom,
        filename: atom.Atom,
        line_num: i32,
        col_num: i32,
    ) !void {
        try self.core.pushBacktraceFrame(function_name, filename, line_num, col_num);
    }

    pub fn pushBacktraceFrameWithResolver(
        self: *JSContext,
        function_name: atom.Atom,
        filename: atom.Atom,
        line_num: i32,
        col_num: i32,
        location_data: ?*const anyopaque,
        location_resolver: ?core.BacktraceLocationResolver,
    ) !void {
        try self.core.pushBacktraceFrameWithResolver(function_name, filename, line_num, col_num, location_data, location_resolver);
    }

    pub fn popBacktraceFrame(self: *JSContext) void {
        self.core.popBacktraceFrame();
    }

    pub fn updateBacktracePc(self: *JSContext, pc: usize) void {
        self.core.updateBacktracePc(pc);
    }

    pub fn borrowBacktracePc(self: *JSContext, pc_source: *const usize) void {
        self.core.borrowBacktracePc(pc_source);
    }

    pub fn updateBacktraceLocation(self: *JSContext, pc: usize, line_num: i32, col_num: i32) void {
        self.core.updateBacktraceLocation(pc, line_num, col_num);
    }

    pub fn ensurePendingPromiseJobCapacity(self: *JSContext, min_capacity: usize) !void {
        try self.core.ensurePendingPromiseJobCapacity(min_capacity);
    }

    pub fn peekPendingPromiseJobSequence(self: JSContext) ?u64 {
        return self.core.peekPendingPromiseJobSequence();
    }

    pub fn takePendingPromiseJob(self: *JSContext) ?core.PendingPromiseJob {
        return self.core.takePendingPromiseJob();
    }

    pub fn defineDataProperty(
        self: *JSContext,
        target: JSValue,
        property_name: []const u8,
        val: JSValue,
        options: core.DataPropertyOptions,
    ) !void {
        const object = try Object.expect(target);
        const key = try self.core.runtime.internAtom(property_name);
        defer self.core.runtime.atoms.free(key);
        try object.defineOwnProperty(self.core.runtime, key, Descriptor.data(val, options.writable, options.enumerable, options.configurable));
    }

    pub fn arrayBuffer(self: *JSContext, store: *JSValue.Bytes.Store) !JSValue {
        return self.core.arrayBuffer(store);
    }

    pub fn setStackLimit(self: *JSContext, size: usize) void {
        self.core.setStackLimit(size);
    }

    pub fn stackLimit(self: JSContext) usize {
        return self.core.stackLimit();
    }

    pub fn setTrackUnhandledRejections(self: *JSContext, enabled: bool) void {
        self.core.setTrackUnhandledRejections(enabled);
    }

    pub fn tracksUnhandledRejections(self: JSContext) bool {
        return self.core.tracksUnhandledRejections();
    }

    pub fn setPreserveUncaughtException(self: *JSContext, enabled: bool) void {
        self.core.setPreserveUncaughtException(enabled);
    }

    pub fn preservesUncaughtException(self: JSContext) bool {
        return self.core.preservesUncaughtException();
    }

    pub fn setHostEventLoop(self: *JSContext, host_loop: core.context.HostEventLoop) void {
        self.core.setHostEventLoop(host_loop);
    }

    pub fn clearHostEventLoop(self: *JSContext, ptr: *anyopaque) void {
        self.core.clearHostEventLoop(ptr);
    }

    pub fn hostEventLoop(self: *JSContext) ?core.context.HostEventLoop {
        return self.core.hostEventLoop();
    }

    // --- Execution / VM / Builtins Helpers (Moved from core/context.zig) ---
    pub fn globalObject(self: *JSContext) !*Object {
        ensureStandardGlobalsRegistered(self.core.runtime);
        return exec.zjs_vm.contextGlobal(self.core);
    }

    pub fn createObject(self: *JSContext) !JSValue {
        const object = try Object.create(self.core.runtime, class.ids.object, null);
        return object.value();
    }

    pub fn createString(self: *JSContext, bytes_data: []const u8) !JSValue {
        if (bytes_data.len == 0) {
            const cached = try self.core.runtime.emptyString();
            return cached.value().dup();
        }
        const created = if (string.isAsciiBytes(bytes_data))
            try string.String.createAscii(self.core.runtime, bytes_data)
        else
            try string.String.createUtf8(self.core.runtime, bytes_data);
        return created.value();
    }

    pub fn getPropertyAtom(self: *JSContext, val: JSValue, property_name: atom.Atom) !JSValue {
        const global = try self.globalObject();
        return exec.zjs_vm.getValueProperty(self.core, null, global, val, property_name, null, null);
    }

    pub fn getProperty(self: *JSContext, val: JSValue, property_name: []const u8) !JSValue {
        const key = try self.core.runtime.internAtom(property_name);
        defer self.core.runtime.atoms.free(key);
        return self.getPropertyAtom(val, key);
    }

    pub fn getPropertyKey(self: *JSContext, val: JSValue, property_key: JSValue, options: core.PropertyAccessOptions) !JSValue {
        const global = options.realm_global orelse try self.globalObject();
        const key = try exec.object_ops.toPropertyKeyAtom(self.core, options.output, global, property_key, null, null);
        defer self.core.runtime.atoms.free(key);
        return exec.object_ops.getValueProperty(self.core, options.output, global, val, key, null, null);
    }

    pub fn deleteProperty(self: *JSContext, val: JSValue, property_name: []const u8) !bool {
        const key = try self.core.runtime.internAtom(property_name);
        defer self.core.runtime.atoms.free(key);
        return self.deletePropertyAtom(val, key, .{});
    }

    pub fn deletePropertyKey(self: *JSContext, val: JSValue, property_key: JSValue, options: core.PropertyAccessOptions) !bool {
        const global = options.realm_global orelse try self.globalObject();
        const key = try exec.object_ops.toPropertyKeyAtom(self.core, options.output, global, property_key, null, null);
        defer self.core.runtime.atoms.free(key);
        return self.deletePropertyAtom(val, key, .{ .output = options.output, .realm_global = global });
    }

    pub fn hasOwnProperty(self: *JSContext, val: JSValue, property_name: []const u8) !bool {
        const key = try self.core.runtime.internAtom(property_name);
        defer self.core.runtime.atoms.free(key);
        return self.hasOwnPropertyAtom(val, key, .{});
    }

    pub fn hasOwnPropertyKey(self: *JSContext, val: JSValue, property_key: JSValue, options: core.PropertyAccessOptions) !bool {
        const global = options.realm_global orelse try self.globalObject();
        const key = try exec.object_ops.toPropertyKeyAtom(self.core, options.output, global, property_key, null, null);
        defer self.core.runtime.atoms.free(key);
        return self.hasOwnPropertyAtom(val, key, .{ .output = options.output, .realm_global = global });
    }

    pub fn ownPropertyDescriptor(self: *JSContext, val: JSValue, property_key: JSValue, options: core.PropertyAccessOptions) !?core.PropertyDescriptor {
        const global = options.realm_global orelse try self.globalObject();
        const key = try exec.object_ops.toPropertyKeyAtom(self.core, options.output, global, property_key, null, null);
        defer self.core.runtime.atoms.free(key);
        return self.ownPropertyDescriptorAtom(val, key, .{ .output = options.output, .realm_global = global });
    }

    pub fn toString(self: *JSContext, val: JSValue) !JSValue {
        const global = try self.globalObject();
        return exec.string_ops.toStringForAnnexB(self.core, null, global, val, null, null);
    }

    pub fn toOwnedUtf8(self: *JSContext, val: JSValue, allocator: std.mem.Allocator) ![]u8 {
        const string_value = try self.toString(val);
        defer string_value.free(self.core.runtime);
        const string_view = string_value.asString() orelse return error.TypeError;
        return string_view.toOwnedUtf8(allocator);
    }

    pub fn toNumber(self: *JSContext, val: JSValue) !f64 {
        const global = try self.globalObject();
        const primitive = try exec.coercion_ops.toPrimitiveForNumber(self.core, null, global, val);
        defer primitive.free(self.core.runtime);
        if (primitive.isBigInt()) return error.TypeError;
        const number_value = try exec.value_ops.toNumberValue(self.core.runtime, primitive);
        defer number_value.free(self.core.runtime);
        return number_value.asNumber() orelse std.math.nan(f64);
    }

    pub fn toIntegerOrInfinity(self: *JSContext, val: JSValue) !f64 {
        const number_value = try self.toNumber(val);
        if (std.math.isNan(number_value) or number_value == 0) return 0;
        if (!std.math.isFinite(number_value)) return number_value;
        return if (number_value < 0) -@floor(@abs(number_value)) else @floor(number_value);
    }

    pub fn isCallable(self: *JSContext, val: JSValue) bool {
        _ = self;
        return exec.call_runtime.isCallableValue(val);
    }

    pub fn isConstructor(self: *JSContext, val: JSValue) bool {
        // Public predicate spelling stays infallible; under allocation
        // failure it degrades to a conservative `false`. Engine-internal
        // paths use the fallible form and propagate OOM.
        return exec.call_runtime.isConstructorLike(self.core, val) catch false;
    }

    pub fn functionName(self: *JSContext, val: JSValue, allocator: std.mem.Allocator) ![]u8 {
        const object = try Object.expect(val);
        const runtime_name = try exec.call.nativeFunctionNameForVm(self.core.runtime, object);
        defer self.core.runtime.memory.allocator.free(runtime_name);
        return allocator.dupe(u8, runtime_name);
    }

    pub fn callFunction(self: *JSContext, callee: JSValue, args: []const JSValue, options: core.FunctionCallOptions) !JSValue {
        const global = options.realm_global orelse try self.globalObject();
        const this_value = options.this_value orelse JSValue.undefinedValue();
        return exec.call_runtime.callValueOrBytecode(self.core, options.output, global, this_value, callee, args, null, null);
    }

    pub fn createError(self: *JSContext, name: []const u8, message: []const u8, options: core.ErrorOptions) !JSValue {
        const global = options.realm_global orelse try self.globalObject();
        if (options.capture_stack) return exec.exception_ops.createNamedError(self.core, global, name, message);
        return exec.exception_ops.createNamedErrorWithoutStack(self.core.runtime, global, name, message);
    }

    pub fn throwError(self: *JSContext, name: []const u8, message: []const u8, options: core.ErrorOptions) !JSValue {
        const error_value = try self.createError(name, message, options);
        var error_value_owned = true;
        errdefer if (error_value_owned) error_value.free(self.core.runtime);
        _ = self.throwValue(error_value);
        error_value_owned = false;
        return error.JSException;
    }

    pub fn pendingExceptionMatchesErrorName(self: *JSContext, expected_name: []const u8) !bool {
        if (!self.hasException()) return false;
        return exec.string_ops.thrownValueMatchesConstructor(self.core.runtime, self.core.runtime.current_exception, expected_name);
    }

    pub fn consumePendingExceptionIfErrorName(self: *JSContext, expected_name: []const u8) !bool {
        if (!self.hasException()) return false;
        const matches = try self.pendingExceptionMatchesErrorName(expected_name);
        self.clearException();
        return matches;
    }

    pub fn runtimeErrorMatchesErrorName(self: *JSContext, err: anyerror, expected_name: []const u8) bool {
        _ = self;
        if (exec.exception_ops.runtimeErrorInfo(err)) |info| {
            return std.mem.eql(u8, info.name, expected_name);
        }
        const err_name = @errorName(err);
        return std.mem.eql(u8, err_name, expected_name) and exec.exception_ops.isErrorConstructorName(expected_name);
    }

    pub fn createRealm(self: *JSContext) !JSValue {
        return exec.call.createRealmObject(self.core);
    }

    pub fn realmGlobal(self: *JSContext, realm: JSValue) !JSValue {
        return self.getProperty(realm, "global");
    }

    pub fn realmGlobalObject(self: *JSContext, realm: JSValue) !*Object {
        const global_value = try self.realmGlobal(realm);
        defer global_value.free(self.core.runtime);
        return Object.expect(global_value);
    }

    pub fn isArray(self: *JSContext, val: JSValue) !bool {
        _ = self;
        const object = try arrayObjectFromValue(val);
        return object != null;
    }

    pub fn arrayLength(self: *JSContext, val: JSValue) !u32 {
        _ = self;
        const object = (try arrayObjectFromValue(val)) orelse return error.TypeError;
        return object.arrayLength();
    }

    pub fn getIndex(self: *JSContext, val: JSValue, index: u32) !JSValue {
        return self.getPropertyAtom(val, atom.atomFromUInt32(index));
    }

    fn hasOwnPropertyAtom(self: *JSContext, val: JSValue, property_name: atom.Atom, options: core.PropertyAccessOptions) !bool {
        var desc = (try self.ownPropertyDescriptorAtom(val, property_name, options)) orelse return false;
        defer desc.destroy(self.core.runtime);
        return true;
    }

    fn deletePropertyAtom(self: *JSContext, val: JSValue, property_name: atom.Atom, options: core.PropertyAccessOptions) !bool {
        const object = try Object.expect(val);
        const global = options.realm_global orelse try self.globalObject();
        return exec.object_ops.deleteValueProperty(self.core, options.output, global, val, object, property_name, null, null);
    }

    fn ownPropertyDescriptorAtom(self: *JSContext, val: JSValue, property_name: atom.Atom, options: core.PropertyAccessOptions) !?core.PropertyDescriptor {
        const object = try Object.expect(val);
        const global = options.realm_global orelse try self.globalObject();
        var desc = try exec.object_ops.proxyAwareOwnPropertyDescriptor(self.core, options.output, global, object, property_name, null, null) orelse {
            if (object.isGlobal() and exec.value_ops.atomNameEql(self.core.runtime, property_name, "globalThis")) {
                return Descriptor.data(object.value().dup(), true, false, true);
            }
            return null;
        };
        errdefer desc.destroy(self.core.runtime);
        try exec.call.materializeMappedArgumentsDescriptorValueForVm(self.core.runtime, object, property_name, &desc);
        return desc;
    }

    pub fn retainSharedArrayBuffer(self: *JSContext, val: JSValue) !core.SharedArrayBufferRef {
        _ = self;
        const object = try Object.expect(val);
        if (object.class_id != class.ids.shared_array_buffer) return error.TypeError;
        const store = object.sharedByteStorageStore() orelse return error.TypeError;
        store.retain();
        return .{
            .store = store,
            .max_byte_length = object.arrayBufferMaxByteLength(),
        };
    }

    pub fn sharedArrayBufferFromRef(self: *JSContext, ref: core.SharedArrayBufferRef) !JSValue {
        const store = ref.sharedStore() orelse return error.TypeError;
        if (ref.max_byte_length) |max_byte_length| {
            if (max_byte_length < store.bytes.len) return error.RangeError;
        }
        store.retain();
        errdefer store.release();
        const object = try Object.create(self.core.runtime, class.ids.shared_array_buffer, null);
        errdefer Object.destroyFromHeader(self.core.runtime, &object.header);
        object.installSharedByteStorage(self.core.runtime, store);
        object.arrayBufferMaxByteLengthSlot().* = ref.max_byte_length;
        return object.value();
    }

    pub fn functionRealmGlobal(self: *JSContext, function_value: JSValue) !?*Object {
        _ = self;
        const function_object = try Object.expect(function_value);
        return exec.object_ops.objectRealmGlobal(function_object);
    }

    pub fn evalScriptSource(self: *JSContext, source_text: []const u8, options: core.ScriptEvalOptions) !JSValue {
        ensureStandardGlobalsRegistered(self.core.runtime);
        const target = if (options.realm_global) |global|
            self.core.runtime.contextForGlobal(global) orelse return error.TypeError
        else
            self.core;
        return exec.eval_entry.evalScriptSource(target, source_text, options);
    }

    pub fn evalScriptValue(self: *JSContext, source_value: JSValue, options: core.ScriptEvalOptions) !JSValue {
        ensureStandardGlobalsRegistered(self.core.runtime);
        const target = if (options.realm_global) |global|
            self.core.runtime.contextForGlobal(global) orelse return error.TypeError
        else
            self.core;
        return exec.eval_entry.evalScriptValue(target, source_value, options);
    }

    pub fn eval(self: *JSContext, source_text: []const u8, options: core.EvalOptions) !JSValue {
        ensureStandardGlobalsRegistered(self.core.runtime);
        return exec.eval_entry.eval(self.core, source_text, options);
    }

    pub fn runJobs(self: *JSContext, output: ?*std.Io.Writer) !void {
        self.core.runtime.job_queue.runAll();
        const global_object = try self.globalObject();
        exec.zjs_vm.drainPendingPromiseJobs(self.core, output, global_object) catch |err| {
            if (self.hasException() or self.hasUnhandledRejection()) return;
            return err;
        };
    }

    pub fn defineGlobalFunction(
        self: *JSContext,
        name: []const u8,
        length: i32,
        ptr: *anyopaque,
        call: core.ExternalHostCallFn,
        finalizer: ?core.ExternalHostFinalizer,
    ) !void {
        const rt = self.core.runtime;
        const global_object = try self.globalObject();
        const function_value = try self.createExternalFunction(name, length, ptr, call, finalizer, .{ .realm_global = global_object });
        defer function_value.free(rt);

        const property_name = try rt.internAtom(name);
        defer rt.atoms.free(property_name);
        try global_object.defineOwnProperty(rt, property_name, Descriptor.data(function_value, true, false, true));
    }

    pub fn createExternalFunction(
        self: *JSContext,
        name: []const u8,
        length: i32,
        ptr: *anyopaque,
        call: core.ExternalHostCallFn,
        finalizer: ?core.ExternalHostFinalizer,
        options: core.ExternalFunctionOptions,
    ) !JSValue {
        const rt = self.core.runtime;
        const id = try rt.registerExternalHostFunction(.{
            .ptr = ptr,
            .call = call,
            .finalizer = finalizer,
        });

        const function_value = try core.function.nativeFunction(rt, name, length);
        errdefer function_value.free(rt);

        const function_object = try Object.expect(function_value);
        function_object.hostFunctionKindSlot().* = core.host_function.ids.external_host;
        function_object.externalHostFunctionIdSlot().* = id;
        const realm_global = options.realm_global orelse try self.globalObject();
        try function_object.setFunctionRealmGlobalPtr(rt, realm_global);

        if (options.with_prototype) {
            const prototype = try Object.create(rt, class.ids.object, null);
            const prototype_value = prototype.value();
            defer prototype_value.free(rt);
            try function_object.defineOwnProperty(rt, atom.ids.prototype, Descriptor.data(prototype_value, true, true, true));
        }

        return function_value;
    }

    pub fn formatException(self: *JSContext, exc: JSValue, allocator: std.mem.Allocator) ![]const u8 {
        const rt = self.core.runtime;
        if (exc.isObject()) {
            const header = exc.refHeader() orelse return error.InvalidEngineState;
            const object: *Object = @fieldParentPtr("header", header);

            const name_opt = try getPropertyString(rt, object, "name", allocator);
            errdefer if (name_opt) |n| allocator.free(n);
            const msg_opt = try getPropertyString(rt, object, "message", allocator);
            errdefer if (msg_opt) |m| allocator.free(m);

            if (name_opt) |name| {
                if (msg_opt) |msg| {
                    defer allocator.free(name);
                    defer allocator.free(msg);
                    return try std.fmt.allocPrint(allocator, "{s}: {s}", .{ name, msg });
                }
                return name;
            } else if (msg_opt) |msg| {
                return msg;
            }
        }

        var temp_list = std.ArrayList(u8).empty;
        defer temp_list.deinit(rt.memory.allocator);
        try exec.value_ops.appendValueString(rt, &temp_list, exc);
        return try allocator.dupe(u8, temp_list.items);
    }

    pub fn formatExceptionStack(self: *JSContext, exc: JSValue, allocator: std.mem.Allocator) !?[]const u8 {
        const rt = self.core.runtime;
        if (!exc.isObject()) return null;
        const val = try self.getProperty(exc, "stack");
        defer val.free(rt);
        if (!val.isString()) return null;

        var temp_list = std.ArrayList(u8).empty;
        defer temp_list.deinit(rt.memory.allocator);
        try exec.value_ops.appendRawString(rt, &temp_list, val);
        return try allocator.dupe(u8, temp_list.items);
    }
};

fn getPropertyString(rt: *JSRuntime, obj: *Object, name: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const val = obj.getProperty(key);
    defer val.free(rt);
    if (!val.isString()) return null;

    var temp_list = std.ArrayList(u8).empty;
    defer temp_list.deinit(rt.memory.allocator);
    try exec.value_ops.appendRawString(rt, &temp_list, val);
    return try allocator.dupe(u8, temp_list.items);
}

fn arrayObjectFromValue(value: JSValue) !?*Object {
    if (!value.isObject()) return null;
    const object = Object.expect(value) catch return null;
    if (object.isProxy()) {
        if (object.proxyHandler() == null) return error.TypeError;
        const target = object.proxyTarget() orelse return error.TypeError;
        return arrayObjectFromValue(target);
    }
    return if (object.isArray()) object else null;
}
