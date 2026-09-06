//! Public embedding context facade over a core realm and exec semantics.
//!
//! A heap-created `JSContext` owns the initial reference to its stable core
//! realm until `deinit`/`destroy`; `borrowCore` is explicitly non-owning.
//! Evaluation, calls, conversion, properties, and exception APIs translate the
//! core ownership rules into embedder-visible operations while lazily ensuring
//! standard globals are installed. This binding seam may bridge core and exec
//! (the QuickJS `JSContext` API role) but must never import CLI.

const std = @import("std");
const core = @import("../core/root.zig");
const native = @import("native.zig");
const exec = @import("../exec/root.zig");
const platform_clock = @import("../platform_clock.zig");

const JSRuntime = core.JSRuntime;
const Object = core.Object;
const JSValue = core.JSValue;
const Descriptor = core.Descriptor;
const class = core.class;
const atom = core.atom;
const string = core.string;

/// Exact window for raw JSValues borrowed by a public embedding call.  This
/// deliberately lives at the binding seam: internal VM calls already have
/// their own frame/argv ownership and must not pay for a blanket scalar-root
/// policy.  Default RC erases the slice descriptor and frame entirely.
fn PublicValueRootWindow(comptime count: usize) type {
    return struct {
        const Self = @This();

        values: [count]JSValue,
        slices: if (core.runtime.value_root_frames_enabled) [1]core.runtime.ValueRootSlice else void =
            if (core.runtime.value_root_frames_enabled) undefined else {},
        frame: if (core.runtime.value_root_frames_enabled) core.runtime.ValueRootFrame else void =
            if (core.runtime.value_root_frames_enabled) .{} else {},

        fn init(values: [count]JSValue) Self {
            return .{ .values = values };
        }

        fn activate(self: *Self, rt: *JSRuntime) void {
            if (comptime core.runtime.value_root_frames_enabled) {
                self.slices[0] = .{ .borrowed = &self.values };
                self.frame.slices = &self.slices;
                self.frame.activate(rt);
            }
        }

        fn deactivate(self: *Self, rt: *JSRuntime) void {
            if (comptime core.runtime.value_root_frames_enabled) self.frame.deactivate(rt);
        }
    };
}

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

/// Internal diagnostics for the two stable sub-phases inside public
/// `JSContext.createWithOptions`. The complete public-ready boundary remains
/// the caller's outer measurement around `createWithOptionsMeasured`.
pub const ContextCreateTiming = struct {
    raw_create_ns: u64 = 0,
    bootstrap_ns: u64 = 0,
};

fn initWithOptionsImpl(
    comptime measure: bool,
    self: *JSContext,
    rt: *JSRuntime,
    options: core.ContextOptions,
    timing: if (measure) *ContextCreateTiming else void,
) !void {
    ensureStandardGlobalsRegistered(rt);
    // Public construction completes intrinsic bootstrap before publication.
    // That bootstrap may run GC and tune its next threshold; preserve the
    // embedder's configured Runtime threshold across this formerly-lazy
    // construction boundary.
    const gc_threshold = rt.gcThreshold();
    defer rt.setGCThreshold(gc_threshold);

    const raw_create_start = if (measure) platform_clock.monotonicNanos() else {};
    self.* = .{ .core = try core.JSContext.createConstructingWithOptions(rt, options) };
    errdefer self.core.destroy();
    if (measure) timing.raw_create_ns += platform_clock.elapsedNanosSince(raw_create_start);

    const bootstrap_start = if (measure) platform_clock.monotonicNanos() else {};
    _ = try self.core.globalObject();
    if (measure) timing.bootstrap_ns += platform_clock.elapsedNanosSince(bootstrap_start);
}

fn createWithOptionsImpl(
    comptime measure: bool,
    rt: *JSRuntime,
    options: core.ContextOptions,
    timing: if (measure) *ContextCreateTiming else void,
) !*JSContext {
    const ctx = try rt.memory.create(JSContext);
    errdefer rt.memory.destroy(JSContext, ctx);
    try initWithOptionsImpl(measure, ctx, rt, options, timing);
    return ctx;
}

/// Internal measurement entry. It executes the exact public constructor
/// implementation; only the two requested monotonic-clock reads are added.
pub fn createWithOptionsMeasured(
    rt: *JSRuntime,
    options: core.ContextOptions,
    timing: *ContextCreateTiming,
) !*JSContext {
    return createWithOptionsImpl(true, rt, options, timing);
}

pub const JSContext = struct {
    /// Stable heap identity; this pointer owns the initial RealmRef returned by
    /// `core.JSContext.createConstructingWithOptions` until `deinit`/`destroy`.
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
        return createWithOptionsImpl(false, rt, options, {});
    }

    pub fn init(self: *JSContext, rt: *JSRuntime, options: core.ContextOptions) !void {
        return initWithOptionsImpl(false, self, rt, options, {});
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

    pub fn defineDataProperty(
        self: *JSContext,
        target: JSValue,
        property_name: []const u8,
        val: JSValue,
        options: core.DataPropertyOptions,
    ) !void {
        const object = try Object.expect(target);
        const key = try self.core.runtime.internAtom(property_name);
        // TGC S3 §4 class B: `key` is a bare id held across a define that can
        // allocate a shape and collect.
        var key_roots = core.runtime.rootAtoms(.{&key});
        key_roots.activate(self.core.runtime);
        defer key_roots.deactivate(self.core.runtime);
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
            return cached.value();
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
        // TGC S3 §4 class B: the getter below can run a JS accessor.
        var key_roots = core.runtime.rootAtoms(.{&key});
        key_roots.activate(self.core.runtime);
        defer key_roots.deactivate(self.core.runtime);
        return self.getPropertyAtom(val, key);
    }

    pub fn getPropertyKey(self: *JSContext, val: JSValue, property_key: JSValue, options: core.PropertyAccessOptions) !JSValue {
        var roots = PublicValueRootWindow(2).init(.{ val, property_key });
        roots.activate(self.core.runtime);
        defer roots.deactivate(self.core.runtime);
        const global = options.realm_global orelse try self.globalObject();
        const key = try exec.object_ops.toPropertyKeyAtom(self.core, options.output, global, roots.values[1], null, null);
        return exec.object_ops.getValueProperty(self.core, options.output, global, roots.values[0], key, null, null);
    }

    pub fn deleteProperty(self: *JSContext, val: JSValue, property_name: []const u8) !bool {
        const key = try self.core.runtime.internAtom(property_name);
        // TGC S3 §4 class B: delete can reach a proxy trap.
        var key_roots = core.runtime.rootAtoms(.{&key});
        key_roots.activate(self.core.runtime);
        defer key_roots.deactivate(self.core.runtime);
        return self.deletePropertyAtom(val, key, .{});
    }

    pub fn deletePropertyKey(self: *JSContext, val: JSValue, property_key: JSValue, options: core.PropertyAccessOptions) !bool {
        var roots = PublicValueRootWindow(2).init(.{ val, property_key });
        roots.activate(self.core.runtime);
        defer roots.deactivate(self.core.runtime);
        const global = options.realm_global orelse try self.globalObject();
        const key = try exec.object_ops.toPropertyKeyAtom(self.core, options.output, global, roots.values[1], null, null);
        return self.deletePropertyAtom(roots.values[0], key, .{ .output = options.output, .realm_global = global });
    }

    pub fn hasOwnProperty(self: *JSContext, val: JSValue, property_name: []const u8) !bool {
        const key = try self.core.runtime.internAtom(property_name);
        // TGC S3 §4 class B: hasOwn can reach a proxy trap.
        var key_roots = core.runtime.rootAtoms(.{&key});
        key_roots.activate(self.core.runtime);
        defer key_roots.deactivate(self.core.runtime);
        return self.hasOwnPropertyAtom(val, key, .{});
    }

    pub fn hasOwnPropertyKey(self: *JSContext, val: JSValue, property_key: JSValue, options: core.PropertyAccessOptions) !bool {
        var roots = PublicValueRootWindow(2).init(.{ val, property_key });
        roots.activate(self.core.runtime);
        defer roots.deactivate(self.core.runtime);
        const global = options.realm_global orelse try self.globalObject();
        const key = try exec.object_ops.toPropertyKeyAtom(self.core, options.output, global, roots.values[1], null, null);
        return self.hasOwnPropertyAtom(roots.values[0], key, .{ .output = options.output, .realm_global = global });
    }

    pub fn ownPropertyDescriptor(self: *JSContext, val: JSValue, property_key: JSValue, options: core.PropertyAccessOptions) !?core.PropertyDescriptor {
        var roots = PublicValueRootWindow(2).init(.{ val, property_key });
        roots.activate(self.core.runtime);
        defer roots.deactivate(self.core.runtime);
        const global = options.realm_global orelse try self.globalObject();
        const key = try exec.object_ops.toPropertyKeyAtom(self.core, options.output, global, roots.values[1], null, null);
        return self.ownPropertyDescriptorAtom(roots.values[0], key, .{ .output = options.output, .realm_global = global });
    }

    pub fn toString(self: *JSContext, val: JSValue) !JSValue {
        const global = try self.globalObject();
        return exec.string_ops.toStringForAnnexB(self.core, null, global, val, null, null);
    }

    pub fn toOwnedUtf8(self: *JSContext, val: JSValue, allocator: std.mem.Allocator) ![]u8 {
        const string_value = try self.toString(val);
        const string_view = string_value.asString() orelse return error.TypeError;
        return string_view.toOwnedUtf8(allocator);
    }

    pub fn toNumber(self: *JSContext, val: JSValue) !f64 {
        const global = try self.globalObject();
        const primitive = try exec.coercion_ops.toPrimitiveForNumber(self.core, null, global, val);
        if (primitive.isBigInt()) return error.TypeError;
        const number_value = try exec.value_ops.toNumberValue(self.core.runtime, primitive);
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
        const global = options.realm_global orelse blk: {
            ensureStandardGlobalsRegistered(self.core.runtime);
            break :blk try exec.zjs_vm.contextGlobalFast(self.core);
        };
        // NB2 contract C2 (design §7): the callee, the receiver and `args` are
        // the embedder's; values in native stack memory are covered by the
        // conservative scan, heap-held arrays must be pinned by the embedder.
        // No per-call root frame is linked here (qjs JS_Call links none).
        const rooted_callee = callee;
        const rooted_this = options.this_value orelse JSValue.undefinedValue();
        // One-shot CallSite route (native-boundary design section 6): an
        // eligible bytecode callee enters through the resident host Machine
        // (or the active one when this is a nested host -> JS call) like a
        // builtin callback; everything else takes the authoritative root path.
        // Embedders that call the same function repeatedly keep a `CallSite`.
        var out: JSValue = undefined;
        exec.call_site.callOnceInto(self.core, options.output, global, rooted_this, rooted_callee, args, null, null, &out) catch |err|
            return self.restoreUncaughtOutOfMemory(err);
        return exec.call_site.pinnedLoad(&out);
    }

    pub fn createError(self: *JSContext, name: []const u8, message: []const u8, options: core.ErrorOptions) !JSValue {
        const global = options.realm_global orelse try self.globalObject();
        if (options.capture_stack) return exec.exception_ops.createNamedError(self.core, global, name, message);
        return exec.exception_ops.createNamedErrorWithoutStack(self.core.runtime, global, name, message);
    }

    pub fn throwError(self: *JSContext, name: []const u8, message: []const u8, options: core.ErrorOptions) !JSValue {
        const error_value = try self.createError(name, message, options);
        _ = self.throwValue(error_value);
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
        return try self.getPropertyAtom(realm, atom.ids.global);
    }

    pub fn realmGlobalObject(self: *JSContext, realm: JSValue) !*Object {
        const global_value = try self.realmGlobal(realm);
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
        return (try self.ownPropertyDescriptorAtom(val, property_name, options)) != null;
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
                return Descriptor.data(object.value(), true, false, true);
            }
            return null;
        };
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
        errdefer Object.destroyFromHeader(self.core.runtime, object.gcHeader());
        object.installSharedByteStorage(self.core.runtime, store);
        object.arrayBufferMaxByteLengthSlot().* = ref.max_byte_length;
        return object.value();
    }

    pub fn functionRealmGlobal(self: *JSContext, function_value: JSValue) !?*Object {
        return try exec.call_runtime.functionRealmGlobal(self.core, function_value);
    }

    /// Restore `error.OutOfMemory` for an allocation failure that no JavaScript
    /// handler consumed.
    ///
    /// Allocation failure is deliberately catchable: it becomes
    /// `InternalError: out of memory` and then travels the engine as an
    /// ordinary JS exception, so the native seam reports `error.JSException`
    /// like any other throw. That is the correct category *inside* the engine,
    /// and widening it there would change control flow (error rebuilding,
    /// promise-job re-queue, module and async-generator error handling). At
    /// this boundary it is the wrong category: the contract on
    /// `exception_ops.runtimeErrorInfo` is that a path with no JavaScript
    /// handler still surfaces `error.OutOfMemory` to the embedder. If
    /// JavaScript did catch it, the exception -- and the flag with it -- was
    /// already cleared, so `err` passes through unchanged.
    fn restoreUncaughtOutOfMemory(self: *JSContext, err: anytype) @TypeOf(err) {
        if (@as(anyerror, err) == error.JSException and self.core.exceptionIsOutOfMemory()) {
            return error.OutOfMemory;
        }
        return err;
    }

    pub fn evalScriptSource(self: *JSContext, source_text: []const u8, options: core.ScriptEvalOptions) !JSValue {
        ensureStandardGlobalsRegistered(self.core.runtime);
        const target = if (options.realm_global) |global|
            self.core.runtime.contextForGlobal(global) orelse return error.TypeError
        else
            self.core;
        return exec.eval_entry.evalScriptSource(target, source_text, options) catch |err|
            self.restoreUncaughtOutOfMemory(err);
    }

    pub fn evalScriptValue(self: *JSContext, source_value: JSValue, options: core.ScriptEvalOptions) !JSValue {
        ensureStandardGlobalsRegistered(self.core.runtime);
        const target = if (options.realm_global) |global|
            self.core.runtime.contextForGlobal(global) orelse return error.TypeError
        else
            self.core;
        return exec.eval_entry.evalScriptValue(target, source_value, options) catch |err|
            self.restoreUncaughtOutOfMemory(err);
    }

    pub fn eval(self: *JSContext, source_text: []const u8, options: core.EvalOptions) !JSValue {
        ensureStandardGlobalsRegistered(self.core.runtime);
        return exec.eval_entry.eval(self.core, source_text, options) catch |err|
            self.restoreUncaughtOutOfMemory(err);
    }

    pub fn runJobs(self: *JSContext, output: ?*std.Io.Writer) !void {
        const global_object = try self.globalObject();
        exec.zjs_vm.drainPendingPromiseJobs(self.core, output, global_object) catch |err| {
            if (self.hasException() or self.hasUnhandledRejection()) return;
            return err;
        };
    }

    /// NB2 (design §9.1): install a native function built by
    /// `zjs.native.managed` (or the leaf / class generators) as a global.
    pub fn defineFunction(self: *JSContext, name: []const u8, spec: native.Spec, options: native.Options) !JSValue {
        const rt = self.core.runtime;
        const global_object = try self.globalObject();
        var opts = options;
        if (opts.realm_global == null) opts.realm_global = global_object;
        const function_value = try self.createFunction(name, spec, opts);
        const property_name = try rt.internAtom(name);
        // TGC S3 §4 class B.
        var name_roots = core.runtime.rootAtoms(.{&property_name});
        name_roots.activate(rt);
        defer name_roots.deactivate(rt);
        try global_object.defineOwnProperty(rt, property_name, Descriptor.data(function_value, true, false, true));
        return function_value;
    }

    /// NB2: create a native function object without installing it.
    pub fn createFunction(self: *JSContext, name: []const u8, spec: native.Spec, options: native.Options) !JSValue {
        const rt = self.core.runtime;
        const realm_global = options.realm_global orelse try self.globalObject();
        const realm = rt.contextForGlobalIncludingConstructing(realm_global) orelse return error.InvalidEngineState;
        const function_proto = realm.cached_function_proto orelse return error.InvalidEngineState;
        var template = spec.template;
        template.state = options.state;
        if (options.length) |length| template.arity = length;
        // Publish the ownership registration before anything can fail after
        // it; the entry itself is immortal until teardown.
        if (options.finalize) |finalize| {
            const state = options.state orelse return error.InvalidEngineState;
            try rt.registerNativeEntryFinalizer(state, finalize);
        }
        const entry = try rt.allocNativeEntry(template);
        const function_capacity: usize = 2 + @as(usize, @intFromBool(options.with_prototype));
        const function_value = try core.function.nativeFunctionWithPrototypeAndCapacity(realm, function_proto, name, @intCast(template.arity), function_capacity);
        const function_object = try Object.expect(function_value);
        if (options.with_prototype) {
            const object_proto_value = realm_global.cachedRealmValue(rt, .object_prototype) orelse return error.InvalidEngineState;
            const object_proto = try Object.expect(object_proto_value);
            const prototype = try Object.createWithOwnPropertyCapacity(rt, class.ids.object, object_proto, 1);
            const prototype_value = prototype.value();
            try prototype.defineOwnPropertyAssumingNew(rt, atom.ids.constructor, Descriptor.data(function_value, true, false, true));
            try function_object.defineOwnPropertyAssumingNew(rt, atom.ids.prototype, Descriptor.data(prototype_value, true, false, false));
        }
        function_object.installNativeEntry(entry);
        return function_value;
    }

    /// NB2 (design §8.1 / §9.2): register a `zjs.native.Class` in this
    /// runtime (once per runtime; the class id is process-global) and
    /// install its prototype + constructor in this context's realm (once per
    /// realm). Returns the handle used to wrap host pointers.
    pub fn defineClass(self: *JSContext, comptime C: type, options: native.ClassOptions) !C.Handle {
        const rt = self.core.runtime;
        const class_id = try C.classId();
        const native_type = try core.native_object.registerType(rt, class_id, C.name, C.finalize_fn);
        const realm_global = options.realm_global orelse try self.globalObject();
        const realm = rt.contextForGlobalIncludingConstructing(realm_global) orelse return error.InvalidEngineState;
        if (realm.classPrototypeObject(class_id) == null) {
            try self.installClassInRealm(C, native_type, realm, realm_global, options);
        }
        return .{ .native_type = native_type };
    }

    fn installClassInRealm(self: *JSContext, comptime C: type, native_type: *const core.NativeType, realm: *core.JSContext, realm_global: *Object, options: native.ClassOptions) !void {
        const rt = self.core.runtime;
        const class_id = native_type.class_id;
        const object_proto_value = realm_global.cachedRealmValue(rt, .object_prototype) orelse return error.InvalidEngineState;
        const object_proto = try Object.expect(object_proto_value);
        const member_count = C.methods.len + C.getters.len + C.setters.len + 1;
        const prototype = try Object.createWithOwnPropertyCapacity(rt, class.ids.object, object_proto, member_count);
        // The realm's class-prototype slot is a traced root: publish first so
        // every allocation below runs with the prototype reachable.
        try realm.setClassPrototype(class_id, prototype);
        errdefer realm.clearClassPrototype(class_id);

        inline for (C.methods) |member| {
            var spec = member.spec;
            spec.template.class_id = class_id;
            var function_value = try self.createFunction(member.name, spec, .{ .realm_global = realm_global });
            var roots = core.runtime.rootValues(.{&function_value});
            roots.activate(rt);
            defer roots.deactivate(rt);
            try defineMemberProperty(rt, prototype, member.name, Descriptor.data(function_value, true, false, true));
        }
        inline for (C.getters) |getter| {
            var getter_spec = getter.spec;
            getter_spec.template.class_id = class_id;
            var getter_value = try self.createFunction("get " ++ getter.name, getter_spec, .{ .realm_global = realm_global });
            var setter_value = JSValue.undefinedValue();
            var roots = core.runtime.rootValues(.{ &getter_value, &setter_value });
            roots.activate(rt);
            defer roots.deactivate(rt);
            inline for (C.setters) |setter| {
                if (comptime std.mem.eql(u8, setter.name, getter.name)) {
                    var setter_spec = setter.spec;
                    setter_spec.template.class_id = class_id;
                    setter_value = try self.createFunction("set " ++ setter.name, setter_spec, .{ .realm_global = realm_global });
                }
            }
            try defineMemberProperty(rt, prototype, getter.name, Descriptor.accessor(getter_value, setter_value, false, true));
        }
        inline for (C.setters) |setter| {
            const paired = comptime blk: {
                for (C.getters) |getter| {
                    if (std.mem.eql(u8, getter.name, setter.name)) break :blk true;
                }
                break :blk false;
            };
            if (!paired) {
                var setter_spec = setter.spec;
                setter_spec.template.class_id = class_id;
                var setter_value = try self.createFunction("set " ++ setter.name, setter_spec, .{ .realm_global = realm_global });
                var roots = core.runtime.rootValues(.{&setter_value});
                roots.activate(rt);
                defer roots.deactivate(rt);
                try defineMemberProperty(rt, prototype, setter.name, Descriptor.accessor(JSValue.undefinedValue(), setter_value, false, true));
            }
        }

        // Constructor: a host entry function owning `prototype` is what the
        // construct path accepts (`isHostEntryFunction` + own `prototype`).
        var ctor_spec = C.constructor_spec;
        ctor_spec.template.class_id = class_id;
        var ctor_value = try self.createFunction(C.name, ctor_spec, .{ .realm_global = realm_global, .state = @ptrCast(@constCast(native_type)), .length = C.constructor_length });
        var ctor_roots = core.runtime.rootValues(.{&ctor_value});
        ctor_roots.activate(rt);
        defer ctor_roots.deactivate(rt);
        const ctor_object = try Object.expect(ctor_value);
        try ctor_object.defineOwnPropertyAssumingNew(rt, atom.ids.prototype, Descriptor.data(prototype.value(), false, false, false));
        try prototype.defineOwnPropertyAssumingNew(rt, atom.ids.constructor, Descriptor.data(ctor_value, true, false, true));
        if (options.global_name) |global_name| {
            try defineMemberProperty(rt, realm_global, global_name, Descriptor.data(ctor_value, true, false, true));
        }
    }

    fn defineMemberProperty(rt: *JSRuntime, target: *Object, name: []const u8, desc: Descriptor) !void {
        const property_name = try rt.internAtom(name);
        // TGC S3 §4 class B.
        var name_roots = core.runtime.rootAtoms(.{&property_name});
        name_roots.activate(rt);
        defer name_roots.deactivate(rt);
        try target.defineOwnProperty(rt, property_name, desc);
    }

    pub fn formatException(self: *JSContext, exc: JSValue, allocator: std.mem.Allocator) ![]const u8 {
        const rt = self.core.runtime;
        if (exc.isObject()) {
            const header = exc.refHeader() orelse return error.InvalidEngineState;
            const object = Object.fromHeader(header);

            const name_opt = try getPropertyString(rt, object, atom.ids.name, allocator);
            errdefer if (name_opt) |n| allocator.free(n);
            const msg_opt = try getPropertyString(rt, object, atom.ids.message, allocator);
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
        const val = try self.getPropertyAtom(exc, atom.ids.stack);
        if (!val.isString()) return null;

        var temp_list = std.ArrayList(u8).empty;
        defer temp_list.deinit(rt.memory.allocator);
        try exec.value_ops.appendRawString(rt, &temp_list, val);
        return try allocator.dupe(u8, temp_list.items);
    }
};

fn getPropertyString(rt: *JSRuntime, obj: *Object, key: atom.Atom, allocator: std.mem.Allocator) !?[]const u8 {
    const val = try obj.getProperty(key);
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

test "JSContext.toString performs ECMAScript ToString instead of tag assertion" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var wrapper = JSContext.borrowCore(ctx);
    const object = try wrapper.eval("({ toString() { return 'semantic-string'; } })", .{});
    try std.testing.expect(object.asString() == null);

    const converted = try wrapper.toString(object);
    try std.testing.expectEqualStrings("semantic-string", converted.asString().?.units().?.latin1);
}

/// A resolved native -> JS call target for embedders that call one function
/// repeatedly (event handlers, comparators, plugin callbacks): the callee
/// class check, inline eligibility and Realm match are done once in `init`,
/// and every `call` pays only the interrupt poll, the frame push and the
/// dispatch loop. The callee and receiver are pinned in the runtime's
/// persistent root ledger until `deinit`. `output` is the writer `print` /
/// `console.log` use for the calls made through this site (null = process
/// stdout, as for `JSContext.callFunction`).
///
/// A site may be used from the embedder's own stack (no JS running) and from
/// inside a host function that JS called; both enter the resident dispatch
/// loop. Callees that are not plain bytecode functions of the context's Realm
/// (bound functions, proxies, natives, generators, other Realms) still work
/// through the authoritative root path.
pub const CallSite = struct {
    ctx: *JSContext,
    site: exec.call_site.CallSite,

    pub const Options = struct {
        this_value: ?JSValue = null,
        output: ?*std.Io.Writer = null,
    };

    pub fn init(ctx: *JSContext, callee: JSValue, options: Options) !CallSite {
        const global = try ctx.globalObject();
        const this_value = options.this_value orelse JSValue.undefinedValue();
        return .{
            .ctx = ctx,
            .site = try exec.call_site.CallSite.init(ctx.core, options.output, global, this_value, callee),
        };
    }

    pub fn deinit(self: *CallSite) void {
        self.site.deinit();
    }

    pub fn call(self: *CallSite, args: []const JSValue) !JSValue {
        var out: JSValue = undefined;
        self.site.callInto(args, &out) catch |err| return self.ctx.restoreUncaughtOutOfMemory(err);
        return exec.call_site.pinnedLoad(&out);
    }

    pub inline fn call0(self: *CallSite) !JSValue {
        return self.callFixed(0, &.{});
    }

    pub inline fn call1(self: *CallSite, a0: JSValue) !JSValue {
        var args: [1]JSValue = undefined;
        exec.call_site.pinnedStore(&args[0], a0);
        return self.callFixed(1, &args);
    }

    pub inline fn call2(self: *CallSite, a0: JSValue, a1: JSValue) !JSValue {
        var args: [2]JSValue = undefined;
        exec.call_site.pinnedStore(&args[0], a0);
        exec.call_site.pinnedStore(&args[1], a1);
        return self.callFixed(2, &args);
    }

    inline fn callFixed(self: *CallSite, comptime argc: usize, args: *const [argc]JSValue) !JSValue {
        var out: JSValue = undefined;
        self.site.callFixedInto(argc, args, &out) catch |err| return self.ctx.restoreUncaughtOutOfMemory(err);
        return exec.call_site.pinnedLoad(&out);
    }

    /// Same callee, a different receiver for this call only. `this_value`
    /// must stay reachable from the host for the duration of the call.
    pub fn callWithThis(self: *CallSite, this_value: JSValue, args: []const JSValue) !JSValue {
        var out: JSValue = undefined;
        self.site.callWithThisInto(this_value, args, &out) catch |err| return self.ctx.restoreUncaughtOutOfMemory(err);
        return exec.call_site.pinnedLoad(&out);
    }
};
