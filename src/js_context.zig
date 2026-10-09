//! Public embedding context facade over a core realm and exec semantics.
//!
//! A heap-created `JSContext` owns the initial reference to its stable core
//! realm until `deinit`/`destroy`; `borrowCore` is explicitly non-owning.
//! Evaluation, calls, conversion, properties, and exception APIs translate the
//! core ownership rules into embedder-visible operations while lazily ensuring
//! standard globals are installed. This host facade may bridge core and exec
//! (the QuickJS `JSContext` API role) but must never import CLI.

const std = @import("std");
const core = @import("core/root.zig");
const exec = @import("exec/root.zig");
const native_bindings = @import("core/native_bindings.zig");

const JSRuntime = core.JSRuntime;
const Object = core.Object;
const JSValue = core.JSValue;
const NativeEntry = core.NativeEntry;
const Descriptor = core.Descriptor;
const class = core.class;
const atom = core.atom;
const string = core.string;

// Host-function registration: a comptime `callconv(.c)` thunk over a plain
// Zig function becomes the `NativeEntry.target`, so a host function is
// dispatched exactly like a builtin. The public `Context.defineFunction`
// path wraps the function through `managed`; CLI, test262, and in-repo
// tests may still call `managed` directly. There is no per-call arena,
// handle scope, marshalling framework, or registry lookup.
//
// Rooting: every `JSValue` in `argv` stays alive for the duration of the
// call (the machine's operand window); values the function creates are
// covered by the conservative native-stack scan while they live in locals.
// Only cross-call retention needs a persistent handle.

/// The error a managed function returns after it already installed a JS
/// exception (`ctx.throwValue` / `ctx.throwError`).
pub const Exception = error{JSException};

/// One managed call. Built on the C stack by the thunk; never outlives
/// the call.
pub const Call = struct {
    /// Non-owning facade for the callee realm.
    ctx: JSContext,
    this: JSValue,
    argv: [*]const JSValue,
    argc: u32,
    entry: *const NativeEntry,
    /// The callee function object (null only for engine-internal synthetic
    /// invocations, which never reach a host function).
    func_obj: ?*core.Object,

    /// Positional argument; `undefined` past `argc` (JS semantics).
    pub inline fn arg(self: *const Call, index: usize) JSValue {
        return if (index < self.argc) self.argv[index] else JSValue.undefinedValue();
    }

    /// The argument window as a slice (borrowed for this call).
    pub inline fn args(self: *const Call) []const JSValue {
        return self.argv[0..self.argc];
    }

    /// Typed access to the state pointer given at registration.
    pub inline fn state(self: *const Call, comptime T: type) *T {
        return @ptrCast(@alignCast(self.entry.state.?));
    }

    pub inline fn runtime(self: *const Call) *core.JSRuntime {
        return self.ctx.core.runtime;
    }

    /// `new.target` of a function registered with `.constructor = true`.
    /// Undefined for every other function.
    pub fn newTarget(self: *const Call) JSValue {
        if (self.entry.kind != .constructor) return JSValue.undefinedValue();
        const env = exec.builtin_dispatch.activeNativeEnvironment(self.ctx.core) orelse return JSValue.undefinedValue();
        const target = env.new_target orelse return JSValue.undefinedValue();
        return target.value();
    }

    /// The realm's global object.
    pub inline fn global(self: *const Call) ?*core.Object {
        return self.ctx.core.global;
    }

    /// The host output writer of the current VM invocation (the `output`
    /// passed to eval / callFunction), if any.
    pub inline fn output(self: *const Call) ?*std.Io.Writer {
        return exec.builtin_dispatch.vmCallerView(self.ctx.core).output;
    }

    /// Install a JS error of class `name` (TypeError, RangeError, ...) with
    /// `message` and return the error the function must propagate.
    pub fn throwError(self: *const Call, name: []const u8, message: []const u8) Exception {
        var ctx = self.ctx;
        // Building the Error failed (e.g. out of memory): that failure
        // becomes the pending exception instead of none at all.
        _ = ctx.throwError(name, message, .{}) catch {};
        return error.JSException;
    }

    pub fn throwTypeError(self: *const Call, message: []const u8) Exception {
        return self.throwError("TypeError", message);
    }

    pub fn throwRangeError(self: *const Call, message: []const u8) Exception {
        return self.throwError("RangeError", message);
    }
};

/// Registration-side description produced by `managed` and consumed by
/// `JSContext.defineFunction` / `createFunction`. Comptime constant;
/// `state` / `finalize` are per-registration options.
pub const NativeSpec = struct {
    template: NativeEntry,
};

pub const NativeOptions = struct {
    /// JS `length` (arity). Defaults to the spec template's arity, which is
    /// 0 for `managed` functions.
    length: ?u8 = null,
    /// Opaque state handed back through `Call.state`.
    state: ?*anyopaque = null,
    /// Runs on the runtime thread when the runtime is destroyed (ownership
    /// registration for `state`).
    finalize: ?*const fn (*anyopaque) void = null,
    /// Also create a `prototype` object with a back-pointing `constructor`.
    with_prototype: bool = false,
    /// Only constructible: a plain call throws TypeError before the body
    /// runs, and `Call.newTarget` is valid. The function also needs an own
    /// `prototype` (`with_prototype` or defined by the host).
    constructor: bool = false,
    /// Realm to create the function in (defaults to the context's realm).
    realm_global: ?JSValue = null,
};

/// Build a managed native function from `f: fn (*Call) E!JSValue`. Any
/// error set is accepted: `error.JSException` means "already thrown",
/// engine sentinels (`error.TypeError`, `error.RangeError`, `OutOfMemory`,
/// `Interrupted`, ...) are materialized by the engine, and every other
/// error name becomes `Error: <name>`.
pub fn managed(comptime f: anytype) NativeSpec {
    const F = @TypeOf(f);
    const info = @typeInfo(F);
    if (info != .@"fn") @compileError("native.managed expects a function");
    const params = info.@"fn".params;
    if (params.len != 1 or params[0].type != *Call) @compileError("native.managed expects fn (*Call) E!Value");
    const Thunk = struct {
        fn thunk(
            ctx: *core.JSContext,
            this: JSValue,
            argv: [*]const JSValue,
            argc: u32,
            entry: *const NativeEntry,
            func_obj: ?*core.Object,
        ) callconv(.c) JSValue {
            var call = Call{
                .ctx = borrowCore(ctx),
                .this = this,
                .argv = argv,
                .argc = argc,
                .entry = entry,
                .func_obj = func_obj,
            };
            const Ret = info.@"fn".return_type.?;
            const value = if (@typeInfo(Ret) == .error_union)
                f(&call) catch |err| return exec.builtin_dispatch.embedderErrorToValue(ctx, err)
            else
                f(&call);
            // Returning a value is success. A nested API failure the callback
            // caught leaves its exception pending, which would otherwise
            // surface as some later, unrelated error. An uncatchable
            // interrupt is not the callback's to drop.
            if (ctx.hasException()) {
                if (ctx.exceptionIsUncatchable()) return core.JSValue.exception();
                ctx.clearException();
            }
            return value;
        }
    };
    return .{ .template = .{
        .target = NativeEntry.code(&Thunk.thunk),
        .kind = .managed,
        .flags = .{},
        .arity = 0,
    } };
}

test "managed produces a managed entry template" {
    const Probe = struct {
        fn f(call: *Call) error{ JSException, TypeError }!JSValue {
            if (call.argc == 0) return error.TypeError;
            return call.arg(0);
        }
    };
    const spec = managed(Probe.f);
    try std.testing.expectEqual(core.native_entry.Kind.managed, spec.template.kind);
    try std.testing.expect(!spec.template.flags.needs_env);
}

/// Exact window for raw JSValues borrowed by a public embedding call.  This
/// deliberately lives at the binding seam: internal VM calls already have
/// their own frame/argv ownership and must not pay for a blanket scalar-root
/// policy.
fn PublicValueRootWindow(comptime count: usize) type {
    return struct {
        const Self = @This();

        values: [count]JSValue,
        slices: [1]core.runtime.ValueRootSlice = undefined,
        frame: core.runtime.ValueRootFrame = .{},

        fn init(values: [count]JSValue) Self {
            return .{ .values = values };
        }

        fn activate(self: *Self, rt: *JSRuntime) void {
            self.slices[0] = .{ .borrowed = &self.values };
            self.frame.slices = &self.slices;
            self.frame.activate(rt);
        }

        fn deactivate(self: *Self, rt: *JSRuntime) void {
            self.frame.deactivate(rt);
        }
    };
}

/// Internal diagnostics for the two stable sub-phases inside public
/// `JSContext.create`. The complete public-ready boundary remains
/// the caller's outer measurement around `createMeasured`.
/// Requires Runtime.Options.diagnostic_clock for nonzero durations.
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
    const raw_create_start = if (measure) rt.diagnosticNanos() else {};
    self.* = .{ .core = try core.JSContext.createConstructingWithOptions(rt, options) };
    errdefer self.core.destroy();
    if (measure) timing.raw_create_ns += rt.diagnosticElapsedSince(raw_create_start);

    const bootstrap_start = if (measure) rt.diagnosticNanos() else {};
    _ = try self.core.globalObject();
    if (measure) timing.bootstrap_ns += rt.diagnosticElapsedSince(bootstrap_start);
}

fn createImpl(
    comptime measure: bool,
    rt: *JSRuntime,
    options: core.ContextOptions,
    timing: if (measure) *ContextCreateTiming else void,
) !*JSContext {
    const ctx = try rt.nativeAllocator().create(JSContext);
    errdefer rt.nativeAllocator().destroy(ctx);
    try initWithOptionsImpl(measure, ctx, rt, options, timing);
    return ctx;
}

/// Internal measurement entry. It executes the exact public constructor
/// implementation; only the two requested monotonic-clock reads are added.
pub fn createMeasured(
    rt: *JSRuntime,
    options: core.ContextOptions,
    timing: *ContextCreateTiming,
) !*JSContext {
    return createImpl(true, rt, options, timing);
}

/// Non-owning facade for callbacks whose ABI already carries the stable
/// core realm pointer. The facade must not be destroyed.
pub fn borrowCore(core_ctx: *core.JSContext) JSContext {
    return .{ .core = core_ctx };
}

/// Engine-internal: the realm global as `*Object`.
pub fn globalObjectPtr(self: *JSContext) !*Object {
    return self.globalPtr();
}

pub const JSContext = struct {
    pub const Options = core.ContextOptions;
    pub const EvalMode = core.EvalMode;
    pub const EvalOptions = core.EvalOptions;
    pub const EvalTiming = core.EvalTiming;
    pub const FunctionOptions = NativeOptions;

    /// Stable heap identity; this pointer owns the initial RealmRef returned by
    /// `core.JSContext.createConstructingWithOptions` until `deinit`/`destroy`.
    core: *core.JSContext,

    pub fn create(rt: *JSRuntime, options: Options) !*JSContext {
        return createImpl(false, rt, options, {});
    }

    pub fn init(self: *JSContext, rt: *JSRuntime, options: Options) !void {
        return initWithOptionsImpl(false, self, rt, options, {});
    }

    pub fn deinit(self: *JSContext) void {
        exec.zjs_vm.cleanupAtomicsWaitersForContext(self.core);
        self.core.destroy();
    }

    pub fn destroy(self: *JSContext) void {
        const rt = self.core.runtime;
        self.deinit();
        rt.nativeAllocator().destroy(self);
    }

    // --- Core delegates ---
    pub fn runtimePtr(self: *JSContext) *JSRuntime {
        return self.core.runtime;
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

    pub fn takePendingException(self: *JSContext) JSValue {
        return self.core.takePendingException();
    }

    pub fn defineDataProperty(self: *JSContext, target: JSValue, property_name: []const u8, val: JSValue, options: core.DataPropertyOptions) Error!void {
        return self.defineDataPropertyImpl(target, property_name, val, options) catch |err| self.apiError(err);
    }

    fn defineDataPropertyImpl(
        self: *JSContext,
        target: JSValue,
        property_name: []const u8,
        val: JSValue,
        options: core.DataPropertyOptions,
    ) !void {
        self.discardStaleException();
        const object = try Object.expect(target);
        const key = try self.core.runtime.internAtom(property_name);
        // TGC S3 §4 class B: `key` is a bare id held across a define that can
        // allocate a shape and collect.
        var key_roots = core.runtime.rootAtoms(.{&key});
        key_roots.activate(self.core.runtime);
        defer key_roots.deactivate(self.core.runtime);
        var value_roots = PublicValueRootWindow(2).init(.{ target, val });
        value_roots.activate(self.core.runtime);
        defer value_roots.deactivate(self.core.runtime);
        const desc = Descriptor.data(value_roots.values[1], .{ .writable = options.writable, .enumerable = options.enumerable, .configurable = options.configurable });
        // DefinePropertyOrThrow: a `false` result is the TypeError case.
        const global = try self.globalPtr();
        const defined = try exec.object_ops.defineOwnPropertyVm(self.core, self.hostOutput(null), global, object, key, desc, .keep_error, null, null);
        if (!defined) return error.IncompatibleDescriptor;
    }

    pub fn arrayBuffer(self: *JSContext, store: *JSValue.Bytes.Store) Error!JSValue {
        return self.arrayBufferImpl(store) catch |err| self.apiError(err);
    }

    fn arrayBufferImpl(self: *JSContext, store: *JSValue.Bytes.Store) !JSValue {
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

    pub fn setHostScheduler(self: *JSContext, host_loop: core.context.HostScheduler) void {
        self.core.setHostScheduler(host_loop);
    }

    pub fn clearHostScheduler(self: *JSContext, ptr: *anyopaque) void {
        self.core.clearHostScheduler(ptr);
    }

    pub fn hostScheduler(self: *JSContext) ?core.context.HostScheduler {
        return self.core.hostScheduler();
    }

    // --- Execution / VM / Builtins Helpers (Moved from core/context.zig) ---
    fn globalPtr(self: *JSContext) !*Object {
        return exec.zjs_vm.contextGlobal(self.core);
    }

    pub fn globalObject(self: *JSContext) Error!JSValue {
        const global = self.globalPtr() catch |err| return self.apiError(err);
        return global.value();
    }

    pub fn createObject(self: *JSContext) Error!JSValue {
        return self.createObjectImpl() catch |err| self.apiError(err);
    }

    fn createObjectImpl(self: *JSContext) !JSValue {
        self.discardStaleException();
        const object = try Object.create(self.core.runtime, class.ids.object, self.core.classPrototypeObject(class.ids.object));
        return object.value();
    }

    pub fn createString(self: *JSContext, bytes_data: []const u8) Error!JSValue {
        return self.createStringImpl(bytes_data) catch |err| self.apiError(err);
    }

    fn createStringImpl(self: *JSContext, bytes_data: []const u8) !JSValue {
        self.discardStaleException();
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

    fn getPropertyAtom(self: *JSContext, val: JSValue, property_name: atom.Atom, options: core.PropertyAccessOptions) !JSValue {
        const global = options.realm_global orelse try self.globalPtr();
        return exec.zjs_vm.getValueProperty(self.core, self.hostOutput(options.output), global, val, property_name, null, null);
    }

    /// Name-keyed public calls share one root order: discard, intern, root the
    /// atom, then the operation. The call can run a JS accessor or a proxy trap
    /// (TGC S3 §4 class B).
    fn withInternedPropertyName(self: *JSContext, val: JSValue, property_name: []const u8, comptime call: anytype) @typeInfo(@TypeOf(call)).@"fn".return_type.? {
        self.discardStaleException();
        const key = try self.core.runtime.internAtom(property_name);
        var key_roots = core.runtime.rootAtoms(.{&key});
        key_roots.activate(self.core.runtime);
        defer key_roots.deactivate(self.core.runtime);
        return call(self, val, key, .{});
    }

    /// Key-valued public calls share one root order: window of receiver then
    /// key, realm global, then `toPropertyKeyAtom` on the rooted key.
    fn withResolvedPropertyKey(self: *JSContext, val: JSValue, property_key: JSValue, options: core.PropertyAccessOptions, comptime call: anytype) @typeInfo(@TypeOf(call)).@"fn".return_type.? {
        self.discardStaleException();
        var roots = PublicValueRootWindow(2).init(.{ val, property_key });
        roots.activate(self.core.runtime);
        defer roots.deactivate(self.core.runtime);
        const global = options.realm_global orelse try self.globalPtr();
        const output = self.hostOutput(options.output);
        const key = try exec.object_ops.toPropertyKeyAtom(self.core, output, global, roots.values[1], null, null);
        return call(self, roots.values[0], key, .{ .output = output, .realm_global = global });
    }

    pub fn getProperty(self: *JSContext, val: JSValue, property_name: []const u8) Error!JSValue {
        return self.withInternedPropertyName(val, property_name, getPropertyAtom) catch |err| self.apiError(err);
    }

    pub fn getPropertyKey(self: *JSContext, val: JSValue, property_key: JSValue, options: core.PropertyAccessOptions) Error!JSValue {
        return self.withResolvedPropertyKey(val, property_key, options, getPropertyAtom) catch |err| self.apiError(err);
    }

    pub fn deleteProperty(self: *JSContext, val: JSValue, property_name: []const u8) Error!bool {
        return self.withInternedPropertyName(val, property_name, deletePropertyAtom) catch |err| self.apiError(err);
    }

    pub fn deletePropertyKey(self: *JSContext, val: JSValue, property_key: JSValue, options: core.PropertyAccessOptions) Error!bool {
        return self.withResolvedPropertyKey(val, property_key, options, deletePropertyAtom) catch |err| self.apiError(err);
    }

    pub fn hasOwnProperty(self: *JSContext, val: JSValue, property_name: []const u8) Error!bool {
        return self.withInternedPropertyName(val, property_name, hasOwnPropertyAtom) catch |err| self.apiError(err);
    }

    pub fn hasOwnPropertyKey(self: *JSContext, val: JSValue, property_key: JSValue, options: core.PropertyAccessOptions) Error!bool {
        return self.withResolvedPropertyKey(val, property_key, options, hasOwnPropertyAtom) catch |err| self.apiError(err);
    }

    pub fn ownPropertyDescriptor(self: *JSContext, val: JSValue, property_key: JSValue, options: core.PropertyAccessOptions) Error!?core.PropertyDescriptor {
        return self.withResolvedPropertyKey(val, property_key, options, ownPropertyDescriptorAtom) catch |err| self.apiError(err);
    }

    pub fn toString(self: *JSContext, val: JSValue) Error!JSValue {
        return self.toStringImpl(val) catch |err| self.apiError(err);
    }

    fn toStringImpl(self: *JSContext, val: JSValue) !JSValue {
        self.discardStaleException();
        var roots = PublicValueRootWindow(1).init(.{val});
        roots.activate(self.core.runtime);
        defer roots.deactivate(self.core.runtime);
        const global = try self.globalPtr();
        return exec.string_ops.toStringForAnnexB(self.core, self.hostOutput(null), global, roots.values[0], null, null);
    }

    pub fn toOwnedUtf8(self: *JSContext, val: JSValue, allocator: std.mem.Allocator) Error![]u8 {
        return self.toOwnedUtf8Impl(val, allocator) catch |err| self.apiError(err);
    }

    fn toOwnedUtf8Impl(self: *JSContext, val: JSValue, allocator: std.mem.Allocator) ![]u8 {
        const string_value = try self.toStringImpl(val);
        return JSValue.String.valueToOwnedUtf8(self.core.runtime, allocator, string_value, .wtf8);
    }

    pub fn toNumber(self: *JSContext, val: JSValue) Error!f64 {
        return self.toNumberImpl(val) catch |err| self.apiError(err);
    }

    fn toNumberImpl(self: *JSContext, val: JSValue) !f64 {
        self.discardStaleException();
        const global = try self.globalPtr();
        const primitive = try exec.coercion_ops.toPrimitiveForNumber(self.core, self.hostOutput(null), global, val);
        if (primitive.isBigInt()) try self.failTypeError("cannot convert bigint to number");
        const number_value = try exec.value_ops.toNumberValue(self.core.runtime, primitive);
        return number_value.asNumber() orelse std.math.nan(f64);
    }

    pub fn toIntegerOrInfinity(self: *JSContext, val: JSValue) Error!f64 {
        return self.toIntegerOrInfinityImpl(val) catch |err| self.apiError(err);
    }

    fn toIntegerOrInfinityImpl(self: *JSContext, val: JSValue) !f64 {
        const number_value = try self.toNumberImpl(val);
        if (std.math.isNan(number_value) or number_value == 0) return 0;
        if (!std.math.isFinite(number_value)) return number_value;
        return if (number_value < 0) -@floor(@abs(number_value)) else @floor(number_value);
    }

    pub fn isCallable(self: *JSContext, val: JSValue) bool {
        _ = self;
        return exec.call_runtime.isCallableValue(val);
    }

    pub fn isConstructor(self: *JSContext, val: JSValue) bool {
        _ = self;
        return exec.call_runtime.isConstructorLike(val);
    }

    pub fn functionName(self: *JSContext, val: JSValue, allocator: std.mem.Allocator) Error![]u8 {
        return self.functionNameImpl(val, allocator) catch |err| self.apiError(err);
    }

    fn functionNameImpl(self: *JSContext, val: JSValue, allocator: std.mem.Allocator) ![]u8 {
        self.discardStaleException();
        if (!exec.call_runtime.isCallableValue(val)) return error.NotAFunction;
        const object = try Object.expect(val);
        const runtime_name = try exec.call.nativeFunctionNameForVm(self.core.runtime, object);
        defer self.core.runtime.nativeAllocator().free(runtime_name);
        return allocator.dupe(u8, runtime_name);
    }

    pub fn callFunction(self: *JSContext, callee: JSValue, args: []const JSValue, options: core.FunctionCallOptions) Error!JSValue {
        return self.callFunctionImpl(callee, args, options) catch |err| self.apiError(err);
    }

    fn callFunctionImpl(self: *JSContext, callee: JSValue, args: []const JSValue, options: core.FunctionCallOptions) !JSValue {
        self.discardStaleException();
        const global = options.realm_global orelse try exec.zjs_vm.contextGlobalFast(self.core);
        // NB2 contract C2 (design §7): the callee, the receiver and `args` are
        // the embedder's; values in native stack memory are covered by the
        // conservative scan, heap-held arrays must be pinned by the embedder.
        // No per-call root frame is linked here (qjs JS_Call links none).
        const this_value = options.this_value orelse JSValue.undefinedValue();
        // One-shot call (native-boundary design section 6): an eligible
        // bytecode callee enters through the resident host Machine (or the
        // active one when this is a nested host -> JS call) like a builtin
        // callback; everything else takes the authoritative root path.
        var out: JSValue = undefined;
        try exec.call_site.callOnceInto(self.core, self.hostOutput(options.output), global, this_value, callee, args, null, null, &out);
        return exec.call_site.pinnedLoad(&out);
    }

    pub fn createError(self: *JSContext, name: []const u8, message: []const u8, options: core.ErrorOptions) Error!JSValue {
        return self.createErrorImpl(name, message, options) catch |err| self.apiError(err);
    }

    fn createErrorImpl(self: *JSContext, name: []const u8, message: []const u8, options: core.ErrorOptions) !JSValue {
        self.discardStaleException();
        const global = options.realm_global orelse try self.globalPtr();
        if (options.capture_stack) return exec.exception_ops.createNamedError(self.core, global, name, message);
        return exec.exception_ops.createNamedErrorWithoutStack(self.core.runtime, global, name, message);
    }

    pub fn throwError(self: *JSContext, name: []const u8, message: []const u8, options: core.ErrorOptions) Error!JSValue {
        const error_value = self.createErrorImpl(name, message, options) catch |err| return self.apiError(err);
        _ = self.throwValue(error_value);
        return error.JSException;
    }

    pub fn pendingExceptionMatchesErrorName(self: *JSContext, expected_name: []const u8) !bool {
        if (!self.hasException()) return false;
        return exec.string_ops.thrownValueMatchesConstructor(self.core.runtime, self.core.runtime.exception.value, expected_name);
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
        return std.mem.eql(u8, err_name, expected_name) and core.error_names.isErrorConstructorName(expected_name);
    }

    pub fn createRealm(self: *JSContext) Error!JSValue {
        return self.createRealmImpl() catch |err| self.apiError(err);
    }

    fn createRealmImpl(self: *JSContext) !JSValue {
        self.discardStaleException();
        return exec.call.createRealmObject(self.core);
    }

    pub fn realmGlobal(self: *JSContext, realm: JSValue) Error!JSValue {
        return self.realmGlobalImpl(realm) catch |err| self.apiError(err);
    }

    fn realmGlobalImpl(self: *JSContext, realm: JSValue) !JSValue {
        self.discardStaleException();
        return try self.getPropertyAtom(realm, atom.ids.global, .{});
    }

    pub fn realmGlobalObject(self: *JSContext, realm: JSValue) Error!*Object {
        const global_value = self.realmGlobalImpl(realm) catch |err| return self.apiError(err);
        return Object.expect(global_value) catch |err| self.apiError(err);
    }

    pub fn isArray(self: *JSContext, val: JSValue) Error!bool {
        return self.isArrayImpl(val) catch |err| self.apiError(err);
    }

    fn isArrayImpl(self: *JSContext, val: JSValue) !bool {
        self.discardStaleException();
        const object = try arrayObjectFromValue(val);
        return object != null;
    }

    pub fn arrayLength(self: *JSContext, val: JSValue) Error!u32 {
        return self.arrayLengthImpl(val) catch |err| self.apiError(err);
    }

    fn arrayLengthImpl(self: *JSContext, val: JSValue) !u32 {
        self.discardStaleException();
        const object = (try arrayObjectFromValue(val)) orelse try self.failTypeError("not an array");
        return object.arrayLength();
    }

    pub fn getIndex(self: *JSContext, val: JSValue, index: u32) Error!JSValue {
        return self.getIndexImpl(val, index) catch |err| self.apiError(err);
    }

    fn getIndexImpl(self: *JSContext, val: JSValue, index: u32) !JSValue {
        self.discardStaleException();
        // Tagged-int atoms stop at max_int_atom; a larger index is a string key.
        const key = try exec.object_ops.propertyAtomFromLengthIndex(self.core.runtime, index);
        defer key.deinit(self.core.runtime);
        return self.getPropertyAtom(val, key.atom, .{});
    }

    fn hasOwnPropertyAtom(self: *JSContext, val: JSValue, property_name: atom.Atom, options: core.PropertyAccessOptions) !bool {
        return (try self.ownPropertyDescriptorAtom(val, property_name, options)) != null;
    }

    fn deletePropertyAtom(self: *JSContext, val: JSValue, property_name: atom.Atom, options: core.PropertyAccessOptions) !bool {
        const object = try Object.expect(val);
        const global = options.realm_global orelse try self.globalPtr();
        return exec.object_ops.deleteValueProperty(self.core, self.hostOutput(options.output), global, object, property_name, null, null);
    }

    fn ownPropertyDescriptorAtom(self: *JSContext, val: JSValue, property_name: atom.Atom, options: core.PropertyAccessOptions) !?core.PropertyDescriptor {
        const object = try Object.expect(val);
        const global = options.realm_global orelse try self.globalPtr();
        var desc = try exec.object_ops.proxyAwareOwnPropertyDescriptor(self.core, self.hostOutput(options.output), global, object, property_name, null, null) orelse {
            if (object.isGlobal() and exec.value_ops.atomNameEql(self.core.runtime, property_name, "globalThis")) {
                return Descriptor.data(object.value(), .method);
            }
            return null;
        };
        exec.call.materializeMappedArgumentsDescriptorValue(self.core.runtime, object, property_name, &desc);
        return desc;
    }

    pub fn retainSharedArrayBuffer(self: *JSContext, val: JSValue) Error!core.SharedArrayBufferRef {
        return self.retainSharedArrayBufferImpl(val) catch |err| self.apiError(err);
    }

    fn retainSharedArrayBufferImpl(self: *JSContext, val: JSValue) !core.SharedArrayBufferRef {
        self.discardStaleException();
        const object = try Object.expect(val);
        if (object.class_id != class.ids.shared_array_buffer) try self.failTypeError("not a SharedArrayBuffer");
        const store = object.sharedByteStorageStore() orelse try self.failTypeError("not a SharedArrayBuffer");
        store.retain();
        return .{
            .store = store,
            .max_byte_length = object.arrayBufferMaxByteLength(),
        };
    }

    pub fn sharedArrayBufferFromRef(self: *JSContext, ref: core.SharedArrayBufferRef) Error!JSValue {
        return self.sharedArrayBufferFromRefImpl(ref) catch |err| self.apiError(err);
    }

    fn sharedArrayBufferFromRefImpl(self: *JSContext, ref: core.SharedArrayBufferRef) !JSValue {
        self.discardStaleException();
        const store = ref.sharedStore() orelse return error.TypeError;
        if (ref.max_byte_length) |max_byte_length| {
            if (max_byte_length < store.bytes.len) return error.RangeError;
        }
        store.retain();
        errdefer store.release();
        const object = try Object.create(self.core.runtime, class.ids.shared_array_buffer, self.core.classPrototypeObject(class.ids.shared_array_buffer));
        errdefer Object.destroyFromHeader(self.core.runtime, object.gcHeader());
        object.installSharedByteStorage(self.core.runtime, store);
        object.arrayBufferMaxByteLengthSlot().* = ref.max_byte_length;
        return object.value();
    }

    pub fn functionRealmGlobal(self: *JSContext, function_value: JSValue) Error!?*Object {
        return exec.call_runtime.functionRealmGlobal(self.core, function_value) catch |err| self.apiError(err);
    }

    /// The writer user code run by an API call prints through: the explicit
    /// one, else the active host invocation's (a host function calling back
    /// into the API), else none (top level).
    fn hostOutput(self: *JSContext, explicit: ?*std.Io.Writer) ?*std.Io.Writer {
        return explicit orelse exec.builtin_dispatch.vmCallerView(self.core).output;
    }

    /// Throw a TypeError with `message` in this context's realm.
    fn failTypeError(self: *JSContext, message: []const u8) !noreturn {
        const global = try self.globalPtr();
        _ = try exec.exception_ops.throwTypeErrorMessage(self.core, global, message);
        unreachable;
    }

    /// A failed call leaves its exception pending for the embedder to take.
    /// If it was never taken, the next entry from the host (no JavaScript
    /// running) discards it, so it cannot leak into unrelated work.
    fn discardStaleException(self: *JSContext) void {
        if (self.core.hasException() and !self.core.runtime.isExecuting()) self.core.clearException();
    }

    /// Install (or, with null, remove) the loader that resolves and reads the
    /// sources of `eval(.module)` imports and `import()` (QuickJS
    /// `JS_SetModuleLoaderFunc`). `loader` and its `ptr` must outlive the
    /// Context.
    pub fn setModuleSourceLoader(self: *JSContext, loader: ?*const core.context.ModuleSourceLoader) void {
        self.core.module_source_loader = loader;
    }

    /// Largest module source the installed loader is asked to read.
    pub const max_module_source_size = 64 * 1024 * 1024;

    /// `eval(.module)` with a loader: link and evaluate the module graph whose
    /// root is `source_text`, running top-level await to completion.
    fn evalModuleWithLoader(self: *JSContext, source_text: []const u8, options: core.EvalOptions) !JSValue {
        var discarding = std.Io.Writer.Discarding.init(&.{});
        const output = options.output orelse &discarding.writer;
        return exec.module.evalModuleGraph(
            self.core.runtime,
            self.core,
            source_text,
            output,
            options.filename,
            .{
                .io = std.Io.Threaded.global_single_threaded.io(),
                .allocator = self.core.runtime.nativeAllocator(),
                .max_source_size = max_module_source_size,
            },
        );
    }

    /// How every fallible Context call fails (QuickJS: `JS_EXCEPTION` with a
    /// pending exception). The exception is always pending: `JSException`
    /// for an ordinary throw, `OutOfMemory` for an allocation failure no
    /// JavaScript handler consumed, `Interrupted` when the interrupt handler
    /// stopped execution.
    pub const Error = error{ JSException, OutOfMemory, Interrupted };

    /// Normalize an internal failure to `Error`, materializing a JS exception
    /// for an error that has none yet (a validation failure, an engine
    /// sentinel, an embedder error name).
    ///
    /// Allocation failure is deliberately catchable inside the engine: it
    /// becomes `InternalError: out of memory` and travels as an ordinary JS
    /// exception. At this boundary, one that no JavaScript handler consumed
    /// is reported as `OutOfMemory` again.
    fn apiError(self: *JSContext, err: anyerror) Error {
        if (err != error.JSException) _ = exec.builtin_dispatch.embedderErrorToValue(self.core, err);
        if (self.core.exceptionIsOutOfMemory()) return error.OutOfMemory;
        if (self.core.exceptionIsUncatchable()) return error.Interrupted;
        return error.JSException;
    }

    pub fn evalScriptSource(self: *JSContext, source_text: []const u8, options: core.ScriptEvalOptions) Error!JSValue {
        return self.evalScriptSourceImpl(source_text, options) catch |err| self.apiError(err);
    }

    fn scriptTarget(self: *JSContext, options: core.ScriptEvalOptions) !*core.JSContext {
        self.discardStaleException();
        const global = options.realm_global orelse return self.core;
        return self.core.runtime.contextForGlobal(global) orelse try self.failTypeError("realm_global is not a realm's global object");
    }

    fn evalScriptSourceImpl(self: *JSContext, source_text: []const u8, options: core.ScriptEvalOptions) !JSValue {
        const target = try self.scriptTarget(options);
        return exec.eval_entry.evalScriptSource(target, source_text, options);
    }

    pub fn evalScriptValue(self: *JSContext, source_value: JSValue, options: core.ScriptEvalOptions) Error!JSValue {
        return self.evalScriptValueImpl(source_value, options) catch |err| self.apiError(err);
    }

    fn evalScriptValueImpl(self: *JSContext, source_value: JSValue, options: core.ScriptEvalOptions) !JSValue {
        const target = try self.scriptTarget(options);
        return exec.eval_entry.evalScriptValue(target, source_value, options);
    }

    pub fn eval(self: *JSContext, source_text: []const u8, options: core.EvalOptions) Error!JSValue {
        return self.evalImpl(source_text, options) catch |err| self.apiError(err);
    }

    fn evalImpl(self: *JSContext, source_text: []const u8, options: core.EvalOptions) !JSValue {
        self.discardStaleException();
        if (options.mode == .module and self.core.module_source_loader != null) {
            return self.evalModuleWithLoader(source_text, options);
        }
        return exec.eval_entry.eval(self.core, source_text, options);
    }

    pub fn runJobs(self: *JSContext, output: ?*std.Io.Writer) Error!void {
        return self.runJobsImpl(output) catch |err| self.apiError(err);
    }

    fn runJobsImpl(self: *JSContext, output: ?*std.Io.Writer) !void {
        self.discardStaleException();
        const global_object = try self.globalPtr();
        try exec.zjs_vm.drainPendingPromiseJobs(self.core, output, global_object);
    }

    /// Install a host function as a writable, non-enumerable, configurable
    /// global. `spec_or_fn` is `fn (*Call) E!Value` or a `NativeSpec`.
    pub fn defineFunction(self: *JSContext, name: []const u8, spec_or_fn: anytype, options: FunctionOptions) Error!JSValue {
        return self.defineFunctionImpl(name, spec_or_fn, options) catch |err| self.apiError(err);
    }

    fn defineFunctionImpl(self: *JSContext, name: []const u8, spec_or_fn: anytype, options: FunctionOptions) !JSValue {
        self.discardStaleException();
        const rt = self.core.runtime;
        // Install on the realm the function belongs to.
        const global_object = if (options.realm_global) |realm_global| try Object.expect(realm_global) else try self.globalPtr();
        var opts = options;
        if (opts.realm_global == null) opts.realm_global = global_object.value();
        // Once the global is installed, script can reach `state`: nothing
        // after it may fail and hand `state` back to the caller.
        if (opts.finalize != null) try native_bindings.reserveFinalizer(rt);
        errdefer if (opts.finalize != null) native_bindings.releaseFinalizerReservation(rt);
        const function_value = try self.createFunctionUnfinalized(name, spec_or_fn, opts);
        const property_name = try rt.internAtom(name);
        // TGC S3 §4 class B.
        var name_roots = core.runtime.rootAtoms(.{&property_name});
        name_roots.activate(rt);
        defer name_roots.deactivate(rt);
        try global_object.defineOwnProperty(rt, property_name, Descriptor.data(function_value, .method));
        registerReservedFinalizer(rt, opts);
        return function_value;
    }

    /// Create a host function object without installing it.
    pub fn createFunction(self: *JSContext, name: []const u8, spec_or_fn: anytype, options: FunctionOptions) Error!JSValue {
        return self.createFunctionImpl(name, spec_or_fn, options) catch |err| self.apiError(err);
    }

    fn createFunctionImpl(self: *JSContext, name: []const u8, spec_or_fn: anytype, options: FunctionOptions) !JSValue {
        self.discardStaleException();
        if (options.finalize != null) try native_bindings.reserveFinalizer(self.core.runtime);
        errdefer if (options.finalize != null) native_bindings.releaseFinalizerReservation(self.core.runtime);
        const function_value = try self.createFunctionUnfinalized(name, spec_or_fn, options);
        registerReservedFinalizer(self.core.runtime, options);
        return function_value;
    }

    /// `finalize` takes ownership of `state` only as the last, successful
    /// step: an error from `createFunction` / `defineFunction` leaves `state`
    /// with the caller and the finalizer never runs.
    fn registerReservedFinalizer(rt: *JSRuntime, options: FunctionOptions) void {
        const finalize = options.finalize orelse return;
        native_bindings.registerReservedFinalizer(rt, options.state.?, finalize);
    }

    fn createFunctionUnfinalized(self: *JSContext, name: []const u8, spec_or_fn: anytype, options: FunctionOptions) !JSValue {
        const rt = self.core.runtime;
        if (options.finalize != null and options.state == null) return error.InvalidEngineState;
        const realm_global_value = options.realm_global orelse (try self.globalPtr()).value();
        const realm_global = try Object.expect(realm_global_value);
        const realm = rt.contexts.forGlobal(realm_global, .include_constructing) orelse return error.InvalidEngineState;
        const function_proto = realm.cached_function_proto orelse return error.InvalidEngineState;
        const spec = specFrom(spec_or_fn);
        var template = spec.template;
        template.state = options.state;
        if (options.constructor) {
            if (template.kind != .managed) return error.InvalidEngineState;
            template.kind = .constructor;
        }
        if (options.length) |length| template.arity = length;
        template.flags.host_constructor = options.with_prototype or options.constructor;
        // The entry itself is immortal until teardown.
        const entry = try rt.allocNativeEntry(template);
        // Until `installNativeEntry` publishes it, a failure returns the
        // entry instead of leaving it in the arena until teardown.
        errdefer native_bindings.abandon(rt, entry);
        const function_capacity: usize = 2 + @as(usize, @intFromBool(options.with_prototype));
        const function_value = try core.function.nativeFunctionWithPrototypeAndCapacity(realm, function_proto, name, @intCast(template.arity), function_capacity);
        const function_object = try Object.expect(function_value);
        if (options.with_prototype) {
            const object_proto_value = realm_global.cachedRealmValue(rt, .object_prototype) orelse return error.InvalidEngineState;
            const object_proto = try Object.expect(object_proto_value);
            const prototype = try Object.createWithOwnPropertyCapacity(rt, class.ids.object, object_proto, 1);
            const prototype_value = prototype.value();
            try prototype.defineOwnPropertyAssumingNew(rt, atom.ids.constructor, Descriptor.data(function_value, .method));
            try function_object.defineOwnPropertyAssumingNew(rt, atom.ids.prototype, Descriptor.data(prototype_value, .{ .writable = true }));
        }
        function_object.installNativeEntry(entry);
        return function_value;
    }

    /// Install `scriptArgs` as a writable, enumerable, configurable global
    /// string array. Used by the CLI; empty `args` materializes an empty array
    /// on first read.
    pub fn defineScriptArgs(self: *JSContext, args: []const []const u8) Error!void {
        return self.defineScriptArgsImpl(args) catch |err| self.apiError(err);
    }

    fn defineScriptArgsImpl(self: *JSContext, args: []const []const u8) !void {
        self.discardStaleException();
        const rt = self.runtimePtr();
        const global = try self.globalPtr();
        const key = try rt.internAtom("scriptArgs");
        if (args.len == 0) {
            try global.defineEmptyArrayAutoInitProperty(rt, key, core.property.Flags.data(.all), global);
            return;
        }

        const array_prototype = cachedArrayPrototype(rt, global) orelse try constructorPrototypeObjectByAtom(global, atom.ids.Array);
        // Rooted: every `createStringImpl` below can collect.
        var roots = PublicValueRootWindow(1).init(.{(try Object.createArrayWithOwnPropertyCapacity(rt, array_prototype, args.len)).value()});
        roots.activate(rt);
        defer roots.deactivate(rt);
        for (args, 0..) |item, index| {
            const item_value = try self.createStringImpl(item);
            const array = try Object.expect(roots.values[0]);
            // A fresh array takes dense appends, so it prints and behaves as
            // an ordinary list.
            if (!try array.appendDenseArrayLiteralIndex(rt, @intCast(index), item_value)) {
                try array.defineOwnProperty(rt, core.Atom.taggedInt(@intCast(index)), Descriptor.data(item_value, .all));
            }
        }
        try global.defineOwnProperty(rt, key, Descriptor.data(roots.values[0], .all));
    }

    /// `object[key]` through [[Get]] (so an accessor `name` / `message` is
    /// honoured) when it yields a string; null when it is not a string or the
    /// read throws. Formatting an exception must not raise a new one.
    fn getPropertyString(self: *JSContext, object: *Object, key: atom.Atom, allocator: std.mem.Allocator) !?[]const u8 {
        const rt = self.core.runtime;
        const global = try self.globalPtr();
        const saved = if (self.core.hasException()) self.core.takeException() else null;
        var restore_saved = true;
        defer if (restore_saved) if (saved) |value| {
            _ = self.core.throwValue(value);
        };
        const val = exec.object_ops.getValueProperty(self.core, self.hostOutput(null), global, object.value(), key, null, null) catch |err| {
            // An interruption inside the getter must keep terminating: leave
            // it pending (over any saved exception) and report it.
            if (self.core.exceptionIsUncatchable()) {
                restore_saved = false;
                return error.Interrupted;
            }
            if (err == error.OutOfMemory) return err;
            if (self.core.hasException()) self.core.clearException();
            return null;
        };
        if (!val.isString()) return null;
        var temp_list = std.ArrayList(u8).empty;
        defer temp_list.deinit(rt.nativeAllocator());
        try exec.value_ops.appendRawString(rt, &temp_list, val);
        return try allocator.dupe(u8, temp_list.items);
    }

    pub fn formatException(self: *JSContext, exc: JSValue, allocator: std.mem.Allocator) ![]const u8 {
        const rt = self.core.runtime;
        if (exc.is(.object)) {
            const header = exc.refHeader() orelse return error.InvalidEngineState;
            const object = Object.fromHeader(header);

            const name_opt = try self.getPropertyString(object, atom.ids.name, allocator);
            errdefer if (name_opt) |n| allocator.free(n);
            const msg_opt = try self.getPropertyString(object, atom.ids.message, allocator);
            errdefer if (msg_opt) |m| allocator.free(m);

            if (name_opt) |name| {
                // Error.prototype.toString: an empty message prints the name alone.
                if (msg_opt) |msg| if (msg.len == 0) {
                    allocator.free(msg);
                    return name;
                };
                if (msg_opt) |msg| {
                    // Single release path: the two `errdefer`s above own `name`
                    // and `msg` until `allocPrint` succeeds, so the frees below
                    // only run once the error path can no longer fire.
                    const joined = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ name, msg });
                    allocator.free(name);
                    allocator.free(msg);
                    return joined;
                }
                return name;
            } else if (msg_opt) |msg| {
                return msg;
            }
        }

        var temp_list = std.ArrayList(u8).empty;
        defer temp_list.deinit(rt.nativeAllocator());
        try exec.value_ops.appendValueString(rt, &temp_list, exc);
        return try allocator.dupe(u8, temp_list.items);
    }

    /// `exc.stack` as UTF-8, or null when it is not a string. Like
    /// `formatException`, it leaves any pending exception as it found it.
    pub fn formatExceptionStack(self: *JSContext, exc: JSValue, allocator: std.mem.Allocator) !?[]const u8 {
        if (!exc.is(.object)) return null;
        return self.getPropertyString(try Object.expect(exc), atom.ids.stack, allocator);
    }
};

fn specFrom(spec_or_fn: anytype) NativeSpec {
    if (@TypeOf(spec_or_fn) == NativeSpec) return spec_or_fn;
    return managed(spec_or_fn);
}

fn cachedArrayPrototype(rt: *JSRuntime, global: *Object) ?*Object {
    const stored = global.cachedRealmValue(rt, .array_prototype) orelse return null;
    return objectFromValue(stored);
}

fn constructorPrototypeObjectByAtom(global: *Object, key: atom.Atom) !?*Object {
    const constructor_value = try global.getProperty(key);
    const constructor = objectFromValue(constructor_value) orelse return null;
    const prototype_value = try constructor.getProperty(atom.ids.prototype);
    return objectFromValue(prototype_value);
}

const objectFromValue = core.value_semantics.objectFromValue;

/// The Array a value is, or that a proxy chain over it ends in. Iterative
/// with the same depth cap as `core.array.isArrayValue`.
fn arrayObjectFromValue(value: JSValue) !?*Object {
    var object = objectFromValue(value) orelse return null;
    var depth: usize = 0;
    while (object.isProxy()) {
        if (depth > 1000) return error.StackOverflow;
        depth += 1;
        if (object.proxyHandler() == null) return error.RevokedProxy;
        const target = object.proxyTarget() orelse return error.RevokedProxy;
        object = objectFromValue(target) orelse return null;
    }
    return if (object.isArray()) object else null;
}
