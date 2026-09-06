//! Typed bridge between exec's native-record dispatch sites and the
//! runtime's standard native record table (`rt.internal_builtins`).
//!
//! QuickJS source map: the JSCFunctionListEntry dispatch inside
//! JS_CallInternal. The record holds a cproto-tagged function pointer; realm,
//! host-output and VM caller state live in a stack-local exec environment,
//! never in the core ABI payload.

const std = @import("std");
const core = @import("../core/root.zig");
const bytecode = @import("../bytecode.zig");
const exceptions = @import("exceptions.zig");
const frame_mod = @import("frame.zig");
const exception_ops = @import("exception_ops.zig");
const value_ops = @import("value_ops.zig");
const native_legacy = @import("native_legacy.zig");
const inline_calls = @import("inline_calls.zig");

const HostError = exceptions.HostError;

var empty_realm_globals: [0]core.global_slots.Slot = .{};

/// Native-chain return. 16B, AAPCS64 x0+x1. Failure iff tag==exception
/// and rt.current_exception is set (throwValue already does both).
/// Mirrors qjs JS_EXCEPTION / JS_IsException (quickjs.c:294).
pub const NativeValue = core.JSValue;

/// Integer overlay for the noinline assume terminal. Zig's auto ABI srets
/// the 16B extern `JSValue`; a same-width unsigned int returns in x0+x1.
pub const NativeBits = std.meta.Int(.unsigned, @bitSizeOf(core.JSValue));

pub inline fn nativeToBits(v: NativeValue) NativeBits {
    return @bitCast(v);
}

pub inline fn nativeFromBits(b: NativeBits) NativeValue {
    return @bitCast(b);
}

pub inline fn nativeOk(v: core.JSValue) NativeValue {
    return v;
}

pub inline fn nativeExc() NativeValue {
    return core.JSValue.exception();
}

/// Debug/ReleaseSafe: isException() iff ctx.hasException().
pub inline fn nativeIsExc(ctx: *core.JSContext, v: NativeValue) bool {
    const exc = v.isException();
    std.debug.assert(exc == ctx.hasException());
    return exc;
}

/// Leaf/helper-boundary adapter only. Must not appear as the NMFD↔assume ABI.
/// Returns NativeBits so the caller does not allocate a JSValue sret slot.
/// noinline: keep materialize / Error construction out of the assume prologue.
pub noinline fn nativeFromHostError(ctx: *core.JSContext, global: ?*core.Object, err: anyerror) NativeBits {
    materializeRuntimeError(ctx, global, err) catch {};
    if (!ctx.hasException()) {
        if (global orelse ctx.global) |error_global| {
            const error_value = exception_ops.createNamedError(
                ctx,
                error_global,
                "Error",
                @errorName(err),
            ) catch {
                installNativeExceptionFallback(ctx);
                return nativeToBits(nativeExc());
            };
            _ = ctx.throwValue(error_value);
        } else {
            installNativeExceptionFallback(ctx);
        }
    }
    std.debug.assert(ctx.hasException());
    return nativeToBits(nativeExc());
}

fn installNativeExceptionFallback(ctx: *core.JSContext) void {
    if (ctx.hasException()) return;
    const fallback = if (ctx.preallocated_oom_error) |preallocated|
        preallocated
    else
        core.JSValue.nullValue();
    _ = ctx.throwValue(fallback);
}

/// Reconstruct the host sentinel at a !JSValue receive. Uncatchable interrupt
/// keeps `error.Interrupted` (materialize already left the prebuilt pending
/// InternalError); every other native failure is `error.JSException`.
///
/// An allocation failure deliberately does NOT get its own error here, even
/// though `current_exception_out_of_memory` records it. Inside the engine an
/// OOM that reached this seam has already become an ordinary catchable JS
/// exception, and widening the error category would change engine control
/// flow: `pendingExceptionMatchesError` would stop matching it (rebuilding the
/// error and losing its stack), promise jobs would re-queue on it, and module
/// and async-generator paths would turn it into a hard error instead of a
/// rejection. The flag is read once, at the embedder boundary
/// (`binding.JSContext.restoreUncaughtOutOfMemory`), where restoring
/// `error.OutOfMemory` is observable to the host and to nothing else.
pub inline fn nativeHostError(ctx: *core.JSContext) HostError {
    if (ctx.exceptionIsUncatchable()) return error.Interrupted;
    return error.JSException;
}

inline fn nativeAsHostResult(ctx: *core.JSContext, v: NativeValue) HostError!core.JSValue {
    if (nativeIsExc(ctx, v)) return nativeHostError(ctx);
    return v;
}

/// Rooted-path receive: sentinel -> `HostError`. Unlike `nativeAsHostResult`
/// it does not assert sentinel <=> pending, because a host caller may enter
/// with an exception already pending (qjs `JS_Call` allows it) and a body
/// that returns a value then leaves it pending, unrelated to this call.
inline fn sentinelToHost(ctx: *core.JSContext, v: NativeValue) HostError!core.JSValue {
    if (v.isException()) return nativeHostError(ctx);
    return v;
}

/// NB2 thunk seam: legacy `HostError!JSValue` -> sentinel-carrying JSValue.
pub inline fn hostResultToValue(ctx: *core.JSContext, result: HostError!core.JSValue) core.JSValue {
    // `ctx` is the callee realm at every thunk site, so its global is the
    // error-constructor authority (`realm_global` of the VM terminal).
    const value = result catch |err| return nativeFromBits(nativeFromHostError(ctx, ctx.global, err));
    return value;
}

pub inline fn hostErrorToValue(ctx: *core.JSContext, global: ?*core.Object, err: anyerror) core.JSValue {
    return nativeFromBits(nativeFromHostError(ctx, global, err));
}

/// Embedder seam (`zjs.native.managed` thunks): a Zig error returned by a
/// host function becomes the pending JS exception. Engine control errors
/// (OutOfMemory / ProcessExit / Interrupted / Timeout / StackOverflow /
/// UnhandledPromiseRejection) keep their engine materialization; an already
/// pending exception is left as is; the six standard error names map to
/// their constructors with an empty message (`InvalidUtf8` to URIError);
/// every other name becomes `Error: <name>`.
pub noinline fn embedderErrorToValue(ctx: *core.JSContext, err: anyerror) core.JSValue {
    switch (err) {
        error.OutOfMemory, error.ProcessExit, error.Interrupted, error.Timeout, error.StackOverflow, error.UnhandledPromiseRejection => {
            return nativeFromBits(nativeFromHostError(ctx, ctx.global, err));
        },
        else => {},
    }
    if (ctx.hasException()) return nativeExc();
    const global = ctx.global orelse return nativeFromBits(nativeFromHostError(ctx, null, err));
    const info = embedderErrorInfo(err);
    const error_value = exception_ops.createNamedError(ctx, global, info.name, info.message) catch |create_err| {
        return nativeFromBits(nativeFromHostError(ctx, global, create_err));
    };
    _ = ctx.throwValue(error_value);
    return nativeExc();
}

fn embedderErrorInfo(err: anyerror) struct { name: []const u8, message: []const u8 } {
    return switch (err) {
        error.TypeError => .{ .name = "TypeError", .message = "" },
        error.RangeError => .{ .name = "RangeError", .message = "" },
        error.SyntaxError => .{ .name = "SyntaxError", .message = "" },
        error.ReferenceError => .{ .name = "ReferenceError", .message = "" },
        error.EvalError => .{ .name = "EvalError", .message = "" },
        error.URIError, error.InvalidUtf8 => .{ .name = "URIError", .message = "" },
        else => .{ .name = "Error", .message = @errorName(err) },
    };
}

/// What a native body needs from its VM caller without a per-call
/// environment (NB2 §5.2 / §15 R5): the host output writer and the caller
/// bytecode frame, read from the active invocation's top level (the frame
/// that issued the call; natives push no level of their own). Outside any
/// invocation (rooted host call) the environment, if published, is the
/// source; otherwise there is no caller.
pub const VmCallerView = struct {
    output: ?*std.Io.Writer,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
};

pub inline fn vmCallerView(ctx: *core.JSContext) VmCallerView {
    if (inline_calls.activeInvocation(ctx.runtime)) |invocation| {
        const level = invocation.machine.currentLevel();
        return .{ .output = invocation.machine.output, .caller_function = level.function(), .caller_frame = level.frame };
    }
    if (activeNativeEnvironment(ctx)) |env| {
        return .{ .output = env.output, .caller_function = env.caller_function, .caller_frame = env.caller_frame };
    }
    return .{ .output = null, .caller_function = null, .caller_frame = null };
}

pub const Bytecode = bytecode.FunctionBytecode;
pub const Frame = frame_mod.Frame;

pub const NativeCallEnvironment = struct {
    callable_realm: ?CallRealmView,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []core.global_slots.Slot,
    func_obj: ?*core.Object,
    is_constructor: bool,
    new_target: ?*core.Object,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
};

/// Atomic execution authority for one observable callable invocation.  The
/// global is a borrowed alias of `realm.global`; keeping the pair in one value
/// prevents native handlers from independently selecting a context and a
/// global from different realms.
pub const CallRealmView = struct {
    realm: *core.RealmContext,
    global: *core.Object,

    pub fn caller(realm: *core.RealmContext) HostError!CallRealmView {
        return .{
            .realm = realm,
            .global = realm.global orelse return error.InvalidBuiltinRegistry,
        };
    }

    pub fn cFunction(object: *core.Object) HostError!CallRealmView {
        if (object.class_id != core.class.ids.c_function) return error.InvalidBuiltinRegistry;
        const realm = object.nativeFunctionRealm() orelse return error.InvalidBuiltinRegistry;
        return caller(realm);
    }
};

const FinalCallEnvironment = struct {
    ctx: *core.RealmContext,
    global: ?*core.Object,
    globals: []core.global_slots.Slot,
    callable_realm: ?CallRealmView,
};

/// Select the active realm at a proven final callable arm.  True C_FUNCTION
/// objects use their owned construction realm; every caller-semantics class
/// (including C_FUNCTION_DATA) uses the incoming realm.  The incoming `global`
/// and legacy slot slice are intentionally ignored for observable calls: they
/// are not independent authorities.  A null `func_obj` denotes an explicitly
/// synthetic record invocation and retains the supplied algorithm-local view.
pub fn finalCallableRealmView(
    caller: *core.RealmContext,
    object: *core.Object,
) HostError!CallRealmView {
    const view = if (object.class_id == core.class.ids.c_function)
        try CallRealmView.cFunction(object)
    else
        try CallRealmView.caller(caller);
    if (view.realm.runtime != caller.runtime) return error.InvalidBuiltinRegistry;
    return view;
}

/// Resolve the final call carrier only after the caller has selected a record
/// and completed its call-side preflight. True C_FUNCTION objects switch to
/// their owned construction realm; C_FUNCTION_DATA and synthetic calls retain
/// the incoming view. This mirrors js_call_c_function's late
/// `ctx = p->u.cfunc.realm` assignment (quickjs.c:17586).
fn finalCallEnvironment(
    ctx: *core.JSContext,
    global: ?*core.Object,
    globals: []core.global_slots.Slot,
    func_obj: ?*core.Object,
) HostError!FinalCallEnvironment {
    const object = func_obj orelse return .{
        .ctx = ctx,
        .global = global,
        .globals = globals,
        .callable_realm = null,
    };
    const view = try finalCallableRealmView(ctx, object);
    return .{
        .ctx = view.realm,
        .global = view.global,
        .globals = empty_realm_globals[0..],
        .callable_realm = view,
    };
}

/// Exec-side convenience view for native implementations that need more than
/// their typed cproto arguments. It is reconstructed from the current
/// stack-local environment and is not stored in `InternalRecord`.
pub const NativeCall = struct {
    ctx: *core.JSContext,
    /// Non-null only for an observable JS callable invocation. Synthetic
    /// algorithmic record reuse has no callable carrier and keeps this null.
    callable_realm: ?CallRealmView,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []core.global_slots.Slot,
    func_obj: ?*core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    magic: u16,
    is_constructor: bool,
    new_target: ?*core.Object,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
};

/// Leaf-boundary adapter: HostError!JSValue → NativeBits (x0+x1).
pub inline fn nativeFromHostResult(
    ctx: *core.JSContext,
    global: ?*core.Object,
    result: HostError!core.JSValue,
) NativeBits {
    const value = result catch |err| return nativeFromHostError(ctx, global, err);
    return nativeToBits(value);
}

pub inline fn activeNativeEnvironment(ctx: *core.JSContext) ?*const NativeCallEnvironment {
    const opaque_ptr = ctx.runtime.active_native_call orelse return null;
    return @ptrCast(@alignCast(opaque_ptr));
}

/// Recover the current exec environment while preserving the QJS-style typed
/// native function signature at the record boundary.
pub inline fn nativeCall(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    args: []const core.JSValue,
    magic: i32,
) ?NativeCall {
    const env = activeNativeEnvironment(ctx) orelse return null;
    return .{
        .ctx = ctx,
        .callable_realm = env.callable_realm,
        .output = env.output,
        .global = env.global,
        .globals = env.globals,
        .func_obj = env.func_obj,
        .this_value = this_value,
        .args = args,
        .magic = @intCast(magic),
        .is_constructor = env.is_constructor,
        .new_target = env.new_target,
        .caller_function = env.caller_function,
        .caller_frame = env.caller_frame,
    };
}

/// Require the atomic authority attached to an observable JS callable. Native
/// implementations with a separate algorithmic/bare-runtime entry should
/// branch on `callable_realm == null` before calling this helper.
pub inline fn callableRealm(call: NativeCall) HostError!CallRealmView {
    return call.callable_realm orelse error.InvalidBuiltinRegistry;
}

pub fn genericMagicFunction(comptime implementation: core.host_function.NativeGenericMagicFn) core.host_function.NativeFunctionPtr {
    return .{ .generic_magic = implementation };
}

pub fn constructorOrFunctionMagic(comptime implementation: core.host_function.NativeGenericMagicFn) core.host_function.NativeFunctionPtr {
    return .{ .constructor_or_func_magic = implementation };
}

pub fn constructorMagic(comptime implementation: core.host_function.NativeGenericMagicFn) core.host_function.NativeFunctionPtr {
    return .{ .constructor_magic = implementation };
}

const NativeBacktraceData = struct {
    function_value: core.JSValue,
};

fn resolveNativeBacktrace(data: ?*const anyopaque, index: usize) ?core.ActiveBacktraceSnapshot {
    if (index != 0) return null;
    const native: *const NativeBacktraceData = @ptrCast(@alignCast(data.?));
    return .{
        .function_name = core.atom.null_atom,
        .filename = core.atom.null_atom,
        .line_num = 0,
        .col_num = 0,
        .function_value = native.function_value,
        .is_native = true,
    };
}

/// Stack-local native frame scope. `push` wires the self-referential resolver
/// data only after the scope has reached its final address, so returning the
/// value from `init` never leaves the active frame pointing at a moved temporary.
pub const NativeBacktraceScope = struct {
    ctx: *core.JSContext,
    data: NativeBacktraceData,
    frame: core.ActiveBacktraceFrame = undefined,
    active: bool = false,

    pub fn init(ctx: *core.JSContext, func_obj: ?*core.Object) NativeBacktraceScope {
        return .{
            .ctx = ctx,
            .data = .{
                .function_value = if (func_obj) |object| object.value() else core.JSValue.undefinedValue(),
            },
        };
    }

    pub fn push(self: *NativeBacktraceScope) void {
        std.debug.assert(!self.active);
        self.frame = .{
            .data = &self.data,
            .resolver = resolveNativeBacktrace,
        };
        self.ctx.pushActiveBacktraceFrame(&self.frame);
        self.active = true;
    }

    pub fn deinit(self: *NativeBacktraceScope) void {
        if (!self.active) return;
        self.ctx.popActiveBacktraceFrame(&self.frame);
        self.active = false;
    }
};

/// QuickJS preflights every observable C_FUNCTION call against the caller's
/// native stack before linking the native frame or switching to the function's
/// realm. C_FUNCTION_DATA and synthetic record reuse deliberately keep their
/// caller-semantics path and do not pass through this guard.
pub inline fn preflightCFunctionCall(
    caller_ctx: *core.JSContext,
    caller_global: ?*core.Object,
    func_obj: ?*core.Object,
    formal_length: usize,
) HostError!void {
    const object = func_obj orelse return;
    if (object.class_id != core.class.ids.c_function) return;
    return preflightCFunctionCallAssumeCFunction(caller_ctx, caller_global, object, formal_length);
}

/// K1: skip the class_id gate; caller already proved C_FUNCTION.
pub inline fn preflightCFunctionCallAssumeCFunction(
    caller_ctx: *core.JSContext,
    caller_global: ?*core.Object,
    func_obj: *core.Object,
    formal_length: usize,
) HostError!void {
    _ = func_obj;
    const planned_stack_bytes = std.math.mul(
        usize,
        formal_length,
        @sizeOf(core.JSValue),
    ) catch return throwCFunctionStackOverflow(caller_ctx, caller_global);
    if (!caller_ctx.runtime.checkNativeStackOverflow(planned_stack_bytes)) return;
    return throwCFunctionStackOverflow(caller_ctx, caller_global);
}

/// Preflight an installed record when an outer dispatcher must establish a
/// native frame before the record terminal (for example, constructor argument
/// coercion). A missing record remains the terminal's ordinary dispatch miss.
pub inline fn preflightInternalRecordCFunction(
    caller_ctx: *core.JSContext,
    caller_global: ?*core.Object,
    func_obj: ?*core.Object,
    native_ref: core.function.NativeBuiltinRef,
) HostError!void {
    const record = caller_ctx.runtime.internalBuiltinRecord(
        @intCast(@intFromEnum(native_ref.domain)),
        native_ref.id,
    ) orelse return;
    return preflightCFunctionCall(caller_ctx, caller_global, func_obj, record.arity);
}

noinline fn throwCFunctionStackOverflow(
    caller_ctx: *core.JSContext,
    caller_global: ?*core.Object,
) HostError!void {
    const global = caller_global orelse caller_ctx.global orelse return error.InvalidBuiltinRegistry;
    _ = exception_ops.throwInternalErrorMessage(caller_ctx, global, "stack overflow") catch |err| {
        return err;
    };
    return error.StackOverflow;
}

/// Turn a raw engine sentinel into its JS Error while the caller's native frame
/// is still active. Message-carrying throw helpers already leave a matching
/// pending exception and therefore take the allocation-free first return.
pub fn materializeRuntimeError(ctx: *core.JSContext, global: ?*core.Object, err: anyerror) HostError!void {
    const error_global = global orelse return;
    // A synchronous native -> bytecode callback may return the VM's
    // uncatchable interrupt sentinel through this native-call seam. Its
    // prebuilt pending InternalError is authoritative; rebuilding it here
    // would clear the uncatchable bit and incorrectly expose it to the
    // suspended outer JavaScript catch.
    if (@as(anyerror, err) == error.Interrupted and ctx.exceptionIsUncatchable()) return;
    if (exception_ops.pendingExceptionMatchesError(ctx, err)) return;
    const error_info = exception_ops.runtimeErrorInfo(err) orelse return;
    const error_value = exception_ops.createSentinelError(ctx, error_global, err, error_info) catch |create_err| {
        // The native-call seam signals failure by returning the exception
        // sentinel, and `nativeIsExc` asserts sentinel implies a pending
        // exception. On an exhausted heap the Error object cannot be built, so
        // the seam would otherwise claim an exception nobody installed --
        // `nativeFromHostError` swallows this error and returns the sentinel
        // regardless. Install the Realm's preallocated OOM value instead, the
        // same allocation-free fallback VM catch delivery and
        // `throwInterrupted` use. The error is still returned, so `try`
        // callers propagate exactly as before.
        if (create_err == error.OutOfMemory and !ctx.hasException()) {
            const fallback = if (ctx.preallocated_oom_error) |preallocated|
                preallocated
            else
                core.JSValue.nullValue();
            _ = ctx.throwValue(fallback);
            ctx.markExceptionOutOfMemory();
        }
        return create_err;
    };
    if (ctx.hasException()) ctx.clearException();
    _ = ctx.throwValue(error_value);
    // Allocation failure is catchable, so it becomes a JS exception here and
    // the `error.OutOfMemory` that caused it is about to be collapsed into
    // `error.JSException` at the seam. Tag the exception so `nativeHostError`
    // can restore the specific error if no JavaScript handler consumes it.
    if (@as(anyerror, err) == error.OutOfMemory) ctx.markExceptionOutOfMemory();
}

/// Probe the internal-builtin table for `native_ref` and invoke the record.
/// Returns null for the separate host domain, an invalid/gap id, or a runtime
/// that has not installed standard globals yet.
pub fn callInternalRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []core.global_slots.Slot,
    func_obj: ?*core.Object,
    this_value: core.JSValue,
    native_ref: core.function.NativeBuiltinRef,
    args: []const core.JSValue,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) HostError!?core.JSValue {
    const record = ctx.runtime.internalBuiltinRecord(@intCast(@intFromEnum(native_ref.domain)), native_ref.id) orelse return null;
    return try callInternalRecordDirect(ctx, output, global, globals, func_obj, this_value, record, args, caller_function, caller_frame);
}

/// Invoke an already-resolved internal record WITHOUT the `internalBuiltinRecord`
/// probe. Divergence B: `fastNativeMethodCall` memoizes the resolved record on
/// the func-object payload (qjs `func = p->u.cfunc.c_function`), and the memo only
/// ever stores records that already passed the probe, so re-validating on every
/// hot call is pure overhead. Returns the record's result (unwrapped, never null — a
/// resolved record always dispatches).
pub inline fn callInternalRecordDirect(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []core.global_slots.Slot,
    func_obj: ?*core.Object,
    this_value: core.JSValue,
    record: *const core.host_function.InternalRecord,
    args: []const core.JSValue,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) HostError!core.JSValue {
    try preflightCFunctionCall(ctx, global, func_obj, record.arity);
    const view = try finalCallEnvironment(ctx, global, globals, func_obj);
    return callInternalRecordDirectWithEnvironment(view, output, func_obj, this_value, record, args, caller_function, caller_frame);
}

/// Final C-function terminal for a dispatcher that already loaded the record
/// and RealmContext together from the function payload.  No generic realm
/// resolver or caller-global transport is consulted after this boundary.
pub inline fn callInternalRecordDirectInRealm(
    view: CallRealmView,
    output: ?*std.Io.Writer,
    func_obj: *core.Object,
    this_value: core.JSValue,
    record: *const core.host_function.InternalRecord,
    args: []const core.JSValue,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) HostError!core.JSValue {
    if (func_obj.class_id != core.class.ids.c_function) return error.InvalidBuiltinRegistry;
    if (func_obj.nativeFunctionRealm() != view.realm) return error.InvalidBuiltinRegistry;
    return callInternalRecordDirectWithEnvironment(.{
        .ctx = view.realm,
        .global = view.global,
        .globals = empty_realm_globals[0..],
        .callable_realm = view,
    }, output, func_obj, this_value, record, args, caller_function, caller_frame);
}

inline fn callInternalRecordDirectWithEnvironment(
    view: FinalCallEnvironment,
    output: ?*std.Io.Writer,
    func_obj: ?*core.Object,
    this_value: core.JSValue,
    record: *const core.host_function.InternalRecord,
    args: []const core.JSValue,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) HostError!core.JSValue {
    // QuickJS links a JSStackFrame around every C function call. Use the same
    // active-frame chain as bytecode invocations so an error created inside a
    // builtin captures the native callee before its bytecode caller. The data
    // is borrowed only for this synchronous invocation; snapshotting retains
    // the function value when an Error is materialized.
    var native_scope = NativeBacktraceScope.init(view.ctx, func_obj);
    native_scope.push();
    defer native_scope.deinit();

    const native_env: NativeCallEnvironment = .{
        .callable_realm = view.callable_realm,
        .output = output,
        .global = view.global,
        .globals = view.globals,
        .func_obj = func_obj,
        .is_constructor = false,
        .new_target = null,
        .caller_function = caller_function,
        .caller_frame = caller_frame,
    };
    const previous_native_call = view.ctx.runtime.active_native_call;
    view.ctx.runtime.active_native_call = &native_env;
    defer view.ctx.runtime.active_native_call = previous_native_call;

    return invokeResolvedInternalRecord(view.ctx, this_value, record, args, func_obj) catch |err| {
        try materializeRuntimeError(view.ctx, view.global, err);
        return err;
    };
}

/// VM-originated native call core (P3, native-boundary plan). The receiver
/// and `args` are the machine's operand window, which the active invocation
/// already traces as roots, so no ValueRootFrame is built; the typed result
/// is converted to NativeBits exactly once, with the exception thrown here.
/// The dispatchers fetch record and realm from the function payload in one
/// go (`nativeCallTarget`), so the payload is not walked twice. One `bl`
/// from the dispatcher to the native body, like qjs `js_call_c_function`.
pub inline fn callRecordFromVmInRealm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    func_obj: *core.Object,
    record: *const core.host_function.InternalRecord,
    realm: *core.RealmContext,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) NativeBits {
    // Native stack preflight (qjs js_call_c_function's js_check_stack_overflow
    // with the arg_buf reservation): `length` is a u8, so the byte count
    // cannot overflow -- no checked multiply.
    const planned_stack_bytes: usize = @as(usize, record.arity) * @sizeOf(core.JSValue);
    if (ctx.runtime.checkNativeStackOverflow(planned_stack_bytes)) {
        throwCFunctionStackOverflow(ctx, global) catch |err| return nativeFromHostError(ctx, global, err);
        return nativeFromHostError(ctx, global, error.StackOverflow);
    }
    const realm_global = realm.global orelse
        return nativeFromHostError(ctx, global, error.InvalidBuiltinRegistry);
    // Native backtrace frame, pushed directly (no scope object, no active
    // flag): the qjs `sf` link of js_call_c_function. The function value is
    // written as an integer pair: a q-register store here would stall the
    // 64-bit reads of the backtrace walker (store-forwarding width rule).
    var bt_data: NativeBacktraceData = undefined;
    core.JSValue.storeSlotAsIntPair(&bt_data.function_value, func_obj.value());
    var bt_frame: core.ActiveBacktraceFrame = .{ .data = &bt_data, .resolver = resolveNativeBacktrace };
    realm.pushActiveBacktraceFrame(&bt_frame);
    defer realm.popActiveBacktraceFrame(&bt_frame);
    // K2 prim-self leaf (lane K): receiver-taking typed arm; a miss (or a
    // K1 leaf whose tags missed in the handler) takes the fallback below.
    if (record.kind == .method_leaf) {
        if (invokeMethodLeafFast(ctx, record, this_value, args)) |value| return nativeToBits(value);
    }
    // NB2 bodies (and the former exec-direct bodies, which read the caller
    // through `vmCallerView`) take no environment: one `bl` from here. The
    // legacy `needs_env` leg is outlined so this frame stays small.
    if (!record.flags.needs_env) {
        const direct_result = invokeEntry(realm, this_value, record, args, func_obj) catch |err| {
            return nativeFromHostError(realm, realm_global, err);
        };
        return nativeToBits(direct_result);
    }
    return callRecordWithEnvironment(output, realm_global, func_obj, record, realm, this_value, args, caller_function, caller_frame);
}

noinline fn callRecordWithEnvironment(
    output: ?*std.Io.Writer,
    realm_global: *core.Object,
    func_obj: *core.Object,
    record: *const core.host_function.InternalRecord,
    realm: *core.RealmContext,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) NativeBits {
    const native_env: NativeCallEnvironment = .{
        .callable_realm = .{ .realm = realm, .global = realm_global },
        .output = output,
        .global = realm_global,
        .globals = empty_realm_globals[0..],
        .func_obj = func_obj,
        .is_constructor = false,
        .new_target = null,
        .caller_function = caller_function,
        .caller_frame = caller_frame,
    };
    const previous_native_call = realm.runtime.active_native_call;
    realm.runtime.active_native_call = &native_env;
    defer realm.runtime.active_native_call = previous_native_call;
    const result = invokeEntry(realm, this_value, record, args, func_obj) catch |err| {
        return nativeFromHostError(realm, realm_global, err);
    };
    return nativeToBits(result);
}

inline fn invokeResolvedInternalRecord(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    record: *const core.NativeEntry,
    args: []const core.JSValue,
    func_obj: ?*core.Object,
) HostError!core.JSValue {
    return callTypedInternalRecordDirect(ctx, this_value, record, args, func_obj);
}

/// Outlined so the kind switch does not inflate hot call sites.
noinline fn callTypedInternalRecordDirect(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    record: *const core.NativeEntry,
    args: []const core.JSValue,
    func_obj: ?*core.Object,
) HostError!core.JSValue {
    // Every rooted-path builtin call passes through here, so this is where
    // the receiver and arguments become exact roots for the duration of the
    // call (`Set.prototype.add` losing its collection mid-insert is the case
    // that made this concrete; TGC R1-c re-confirmed nothing further is
    // needed). The VM-window terminal does not need it: the operand window
    // is already a `traceStack` root.
    var receiver = this_value;
    var call_roots = core.runtime.ValueRootFrame{
        .values = &[_]core.runtime.ValueRootValue{.{ .value = &receiver }},
        .slices = &[_]core.runtime.ValueRootSlice{.{ .borrowed = args }},
    };
    call_roots.activate(ctx.runtime);
    defer call_roots.deactivate(ctx.runtime);

    return invokeEntry(ctx, this_value, record, args, func_obj);
}

/// The NB2 kind switch shared by the rooted terminal above and the VM-window
/// terminal (`callRecordFromVmInRealm`). `ctx` is the callable's own realm.
/// Constructor kinds carry the managed prototype in phase A2 (see
/// `native_entry.ManagedFn`); the construct path publishes `is_constructor`
/// / `new_target` through the environment exactly as before.
inline fn invokeEntry(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    entry: *const core.NativeEntry,
    args: []const core.JSValue,
    func_obj: ?*core.Object,
) HostError!core.JSValue {
    switch (entry.kind) {
        .managed, .constructor_or_func => {
            return sentinelToHost(ctx, entry.managed()(ctx, this_value, args.ptr, @intCast(args.len), entry, func_obj));
        },
        .constructor => {
            const env = activeNativeEnvironment(ctx) orelse return error.TypeError;
            if (!env.is_constructor) return error.TypeError;
            return sentinelToHost(ctx, entry.managed()(ctx, this_value, args.ptr, @intCast(args.len), entry, func_obj));
        },
        .getter => {
            if (entry.sig != 0) return invokeTypedGetter(ctx, this_value, entry);
            return sentinelToHost(ctx, entry.getter()(ctx, this_value, entry));
        },
        .setter => {
            const new_value = if (args.len == 0) core.JSValue.undefinedValue() else args[0];
            if (entry.sig != 0) return invokeTypedSetter(ctx, this_value, entry, new_value);
            return sentinelToHost(ctx, entry.setter()(ctx, this_value, new_value, entry));
        },
        .leaf => {
            if (invokeLeafFast(entry, args)) |value| return value;
            return invokeLeafFallback(ctx, this_value, entry, args, func_obj);
        },
        // K2 (design §4.3): receiver class check + `self` unwrap, then the
        // typed leaf arm or the managed prototype with `self` first.
        .method_leaf => {
            if (invokeMethodLeafFast(ctx, entry, this_value, args)) |value| return value;
            if (entry.class_id != 0) return invokeMethodLeafMiss(ctx, this_value, entry, args, func_obj);
            return invokeLeafFallback(ctx, this_value, entry, args, func_obj);
        },
        .method_managed => {
            const self_ptr = nativeReceiverSelf(this_value, entry) orelse return throwNativeReceiverTypeError(ctx, entry);
            return sentinelToHost(ctx, entry.methodManaged()(ctx, self_ptr, this_value, args.ptr, @intCast(args.len), entry));
        },
        .forward_call, .forward_apply, .retired => return error.TypeError,
    }
}

/// K2 receiver unwrap (design §4.3 steps 1-2): `this` must be an object of
/// exactly the entry's NativeType class with a live `self`. Null for a
/// foreign receiver or a disposed instance; the caller throws.
pub inline fn nativeReceiverSelf(this_value: core.JSValue, entry: *const core.NativeEntry) ?*anyopaque {
    const obj = core.value_semantics.objectFromValue(this_value) orelse return null;
    if (obj.class_id != entry.class_id) return null;
    return obj.nativeSelfAssumeClass();
}

/// Install the K2/K3 receiver TypeError (qjs `JS_GetOpaque2`:
/// "<Class> object expected"; a disposed instance reads the same) and return
/// the host error for the rooted arms.
pub noinline fn throwNativeReceiverTypeError(ctx: *core.JSContext, entry: *const core.NativeEntry) HostError!core.JSValue {
    const global = ctx.global orelse return error.TypeError;
    var buffer: [128]u8 = undefined;
    const name: []const u8 = if (core.native_object.NativeType.fromRecord(ctx.runtime, entry.class_id)) |t| t.name else "native";
    const message = std.fmt.bufPrint(&buffer, "{s} object expected", .{name}) catch "native object expected";
    _ = exception_ops.throwTypeErrorMessage(ctx, global, message) catch |err| return @errorCast(err);
    return error.TypeError;
}

/// Thunk-side variant (accessor / constructor thunks built by
/// `zjs.native.Class`): unwrap or leave the TypeError pending and return null
/// so the thunk answers with the exception sentinel.
pub fn nativeReceiverSelfOrThrow(ctx: *core.JSContext, this_value: core.JSValue, entry: *const core.NativeEntry) ?*anyopaque {
    if (nativeReceiverSelf(this_value, entry)) |self_ptr| return self_ptr;
    _ = throwNativeReceiverTypeError(ctx, entry) catch {};
    return null;
}

/// Canonical marshal helpers for thunks built outside this file (typed
/// accessor thunks of `zjs.native.Class`): FNABI §15.3, no coercion.
pub inline fn marshalI32(val: core.JSValue) ?i32 {
    const one = [_]core.JSValue{val};
    return leafI32Arg(&one, 0);
}

pub inline fn marshalF64(val: core.JSValue) ?f64 {
    const one = [_]core.JSValue{val};
    return leafF64Arg(&one, 0);
}

/// Thunk-side TypeError with a message: installs the exception and returns
/// the sentinel.
pub fn throwTypeErrorSentinel(ctx: *core.JSContext, message: []const u8) NativeValue {
    const global = ctx.global orelse return nativeFromBits(nativeFromHostError(ctx, null, error.TypeError));
    _ = exception_ops.throwTypeErrorMessage(ctx, global, message) catch {};
    if (ctx.hasException()) return nativeExc();
    return nativeFromBits(nativeFromHostError(ctx, global, error.TypeError));
}

/// K2 typed leaf arm: class check + `self` load + the K1 marshal checks +
/// direct C call + boxing. Null on a receiver miss or an argument tag miss.
inline fn invokeNativeMethodLeafFast(entry: *const core.NativeEntry, this_value: core.JSValue, args: []const core.JSValue) ?core.JSValue {
    const self_ptr = nativeReceiverSelf(this_value, entry) orelse return null;
    switch (entry.sig) {
        native_legacy.sig_self_i32_to_i32 => {
            const f: native_legacy.LeafSelfI32ToI32 = @ptrCast(entry.target);
            const x = leafI32Arg(args, 0) orelse return null;
            return core.JSValue.int32(f(self_ptr, x));
        },
        native_legacy.sig_self_to_i32 => {
            const f: native_legacy.LeafSelfToI32 = @ptrCast(entry.target);
            return core.JSValue.int32(f(self_ptr));
        },
        native_legacy.sig_self_i32_to_void => {
            const f: native_legacy.LeafSelfI32ToVoid = @ptrCast(entry.target);
            const x = leafI32Arg(args, 0) orelse return null;
            f(self_ptr, x);
            return core.JSValue.undefinedValue();
        },
        native_legacy.sig_self_to_void => {
            const f: native_legacy.LeafSelfToVoid = @ptrCast(entry.target);
            f(self_ptr);
            return core.JSValue.undefinedValue();
        },
        native_legacy.sig_self_to_f64 => {
            const f: native_legacy.LeafSelfToF64 = @ptrCast(entry.target);
            return value_ops.numberToValue(f(self_ptr));
        },
        native_legacy.sig_self_f64_to_void => {
            const f: native_legacy.LeafSelfF64ToVoid = @ptrCast(entry.target);
            const x = leafF64Arg(args, 0) orelse return null;
            f(self_ptr, x);
            return core.JSValue.undefinedValue();
        },
        native_legacy.sig_self_f64_f64_to_void => {
            const f: native_legacy.LeafSelfF64F64ToVoid = @ptrCast(entry.target);
            const x = leafF64Arg(args, 0) orelse return null;
            const y = leafF64Arg(args, 1) orelse return null;
            f(self_ptr, x, y);
            return core.JSValue.undefinedValue();
        },
        else => return null,
    }
}

/// Cold K2 miss: a bad receiver throws the class TypeError; an argument tag
/// miss takes the entry's fallback (or TypeError under the canonical policy).
noinline fn invokeMethodLeafMiss(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    entry: *const core.NativeEntry,
    args: []const core.JSValue,
    func_obj: ?*core.Object,
) HostError!core.JSValue {
    if (nativeReceiverSelf(this_value, entry) == null) return throwNativeReceiverTypeError(ctx, entry);
    return invokeLeafFallback(ctx, this_value, entry, args, func_obj);
}

/// K3 typed getter arm (design §4.4 typed variant): class check + `self` +
/// direct C call + boxing. Null on a receiver miss.
pub inline fn invokeTypedGetterFast(entry: *const core.NativeEntry, this_value: core.JSValue) ?core.JSValue {
    const self_ptr = nativeReceiverSelf(this_value, entry) orelse return null;
    switch (entry.sig) {
        native_legacy.sig_self_to_f64 => {
            const f: native_legacy.LeafSelfToF64 = @ptrCast(entry.target);
            return value_ops.numberToValue(f(self_ptr));
        },
        native_legacy.sig_self_to_i32 => {
            const f: native_legacy.LeafSelfToI32 = @ptrCast(entry.target);
            return core.JSValue.int32(f(self_ptr));
        },
        else => unreachable,
    }
}

/// Outcome of the typed setter arm: the value stored, a receiver miss, or a
/// marshal miss (canonical policy: no coercion).
pub const TypedSetterOutcome = enum { stored, receiver_miss, value_miss };

pub inline fn invokeTypedSetterFast(entry: *const core.NativeEntry, this_value: core.JSValue, new_value: core.JSValue) TypedSetterOutcome {
    const self_ptr = nativeReceiverSelf(this_value, entry) orelse return .receiver_miss;
    switch (entry.sig) {
        native_legacy.sig_self_f64_to_void => {
            const f: native_legacy.LeafSelfF64ToVoid = @ptrCast(entry.target);
            const x = marshalF64(new_value) orelse return .value_miss;
            f(self_ptr, x);
        },
        native_legacy.sig_self_i32_to_void => {
            const f: native_legacy.LeafSelfI32ToVoid = @ptrCast(entry.target);
            const x = marshalI32(new_value) orelse return .value_miss;
            f(self_ptr, x);
        },
        else => unreachable,
    }
    return .stored;
}

fn invokeTypedGetter(ctx: *core.JSContext, this_value: core.JSValue, entry: *const core.NativeEntry) HostError!core.JSValue {
    if (invokeTypedGetterFast(entry, this_value)) |value| return value;
    return throwNativeReceiverTypeError(ctx, entry);
}

fn invokeTypedSetter(ctx: *core.JSContext, this_value: core.JSValue, entry: *const core.NativeEntry, new_value: core.JSValue) HostError!core.JSValue {
    return switch (invokeTypedSetterFast(entry, this_value, new_value)) {
        .stored => core.JSValue.undefinedValue(),
        .receiver_miss => throwNativeReceiverTypeError(ctx, entry),
        .value_miss => throwTypedSetterValueTypeError(ctx, entry),
    };
}

pub noinline fn throwTypedSetterValueTypeError(ctx: *core.JSContext, entry: *const core.NativeEntry) HostError!core.JSValue {
    const global = ctx.global orelse return error.TypeError;
    const message: []const u8 = if (entry.sig == native_legacy.sig_self_i32_to_void) "int32 expected" else "number expected";
    _ = exception_ops.throwTypeErrorMessage(ctx, global, message) catch |err| return @errorCast(err);
    return error.TypeError;
}

/// K3 direct call (design §8.2 slow path): when `accessor` is a native
/// function whose entry is a `.getter` / `.setter`, invoke it through the VM
/// native terminal (preflight + backtrace marker + realm from the payload)
/// instead of the generic call machinery. Null when `accessor` is anything
/// else (bytecode getter, bound function, ...), so the caller keeps its path.
pub fn tryNativeAccessorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    accessor: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
    comptime expected_kind: core.native_entry.Kind,
) ?HostError!core.JSValue {
    const target = nativeAccessorTarget(accessor, expected_kind) orelse return null;
    return callNativeAccessorTarget(ctx, output, global, target, receiver, args, caller_function, caller_frame, expected_kind);
}

/// A native accessor function object with its entry + realm, resolved from
/// the accessor slot value (the pure test half of `tryNativeAccessorCall`,
/// so a handler can decide before publishing its pc / stack top).
pub const NativeAccessorTarget = struct {
    func_obj: *core.Object,
    record: *const core.NativeEntry,
    realm: *core.RealmContext,
};

pub inline fn nativeAccessorTarget(accessor: core.JSValue, comptime expected_kind: core.native_entry.Kind) ?NativeAccessorTarget {
    comptime std.debug.assert(expected_kind == .getter or expected_kind == .setter);
    // The accessor value is a property slot read (an expression value), so
    // the tag test alone identifies the object (qjs JS_VALUE_GET_OBJ).
    const func_obj = core.value_semantics.objectFromValueTrustedExpression(accessor) orelse return null;
    if (func_obj.class_id != core.class.ids.c_function) return null;
    const target = func_obj.nativeCallTarget() orelse return null;
    if (target.record.kind != expected_kind) return null;
    return .{ .func_obj = func_obj, .record = target.record, .realm = target.realm };
}

pub fn callNativeAccessorTarget(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target: NativeAccessorTarget,
    receiver: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
    comptime expected_kind: core.native_entry.Kind,
) HostError!core.JSValue {
    // Typed accessor: leaf contract (§4.7 K1/K2 row) -- no preflight, no
    // backtrace marker; the VM throws on a receiver / marshal miss.
    if (target.record.sig != 0) {
        if (expected_kind == .getter) {
            return invokeTypedGetter(target.realm, receiver, target.record);
        } else {
            const new_value = if (args.len == 0) core.JSValue.undefinedValue() else args[0];
            return invokeTypedSetter(target.realm, receiver, target.record, new_value);
        }
    }
    const bits = callRecordFromVmInRealm(ctx, output, global, target.func_obj, target.record, target.realm, receiver, args, caller_function, caller_frame);
    const result = nativeFromBits(bits);
    if (nativeIsExc(ctx, result)) return nativeHostError(ctx);
    return result;
}

/// VM-side entry for the leaf arm (vm_native.dispatch).
pub inline fn invokeLeafFastEntry(entry: *const core.NativeEntry, args: []const core.JSValue) ?core.JSValue {
    return invokeLeafFast(entry, args);
}

/// VM-side entry for the K2 `prim_self` arm (`op_call_method` inline arm):
/// `this` is the operand-window receiver. Outlined on purpose: the string
/// tag checks plus the boxing would otherwise sit inside the op_call_method
/// handler body (whose size is load-bearing for the island tails).
pub noinline fn invokeMethodLeafFastEntry(ctx: *core.JSContext, entry: *const core.NativeEntry, this_value: core.JSValue, args: []const core.JSValue) ?core.JSValue {
    return invokeMethodLeafFast(ctx, entry, this_value, args);
}

/// K2 `prim_self` arm (design §4.3): receiver tag check in place of the
/// class-id check, `self` = the flat string body, canonical i32 index, one
/// direct C call, boxing. Null on any miss (non-string / unlinearized rope /
/// Symbol receiver, non-int32 index, negative target result): the caller
/// takes the entry's fallback, i.e. the legacy body with its full ToString /
/// ToIntegerOrInfinity semantics.
inline fn invokeMethodLeafFast(ctx: *core.JSContext, entry: *const core.NativeEntry, this_value: core.JSValue, args: []const core.JSValue) ?core.JSValue {
    switch (entry.sig) {
        native_legacy.sig_string_i32_to_i32 => {
            const f: native_legacy.LeafStringI32ToI32 = @ptrCast(entry.target);
            const str = leafStringReceiver(this_value) orelse return null;
            const index = leafI32Arg(args, 0) orelse return null;
            const code = f(str, index);
            if (code < 0) return null;
            return core.JSValue.int32(code);
        },
        native_legacy.sig_string_i32_to_string => {
            const f: native_legacy.LeafStringI32ToI32 = @ptrCast(entry.target);
            const str = leafStringReceiver(this_value) orelse return null;
            const index = leafI32Arg(args, 0) orelse return null;
            const code = f(str, index);
            if (code < 0) return null;
            return leafCodeUnitString(ctx.runtime, @intCast(code));
        },
        // Native-object receivers (lane D): SELF_* signatures.
        else => return invokeNativeMethodLeafFast(entry, this_value, args),
    }
}

/// `prim_self` receiver unwrap: a flat string, or a rope already linearized
/// by an earlier read (the flat body cached in the node). Symbols share the
/// body layout but must miss (ToString throws on them); ropes not yet
/// linearized miss so the fallback linearizes once, as qjs
/// js_linearize_string_rope does.
inline fn leafStringReceiver(this_value: core.JSValue) ?*const core.string.String {
    const tag = this_value.tagOf();
    if (tag == core.value.Tag.string) return this_value.asStringBodyRaw().?;
    if (tag == core.value.Tag.string_rope) return this_value.ropeBody().?.flatString();
    return null;
}

/// One-code-unit result string (charAt / at). Allocation failure is a miss:
/// the fallback repeats the allocation and reports it through the
/// legacy error path.
inline fn leafCodeUnitString(rt: *core.JSRuntime, unit: u16) ?core.JSValue {
    if (unit < 0x100) {
        const byte: [1]u8 = .{@intCast(unit)};
        const str = core.string.String.createLatin1(rt, &byte) catch return null;
        return str.value();
    }
    const units: [1]u16 = .{unit};
    const str = core.string.String.createUtf16(rt, &units) catch return null;
    return str.value();
}

/// K1 leaf arm: tag checks + direct C call + boxing, no environment. Returns
/// null on a tag miss (the caller takes the fallback with the environment,
/// or throws TypeError when the entry has none -- the canonical marshal
/// policy of FNABI §15.3 / §15.6: a missing argument is `undefined` and
/// therefore a miss).
inline fn invokeLeafFast(entry: *const core.NativeEntry, args: []const core.JSValue) ?core.JSValue {
    switch (entry.sig) {
        native_legacy.sig_f64_to_f64 => {
            const f: native_legacy.LeafF64ToF64 = @ptrCast(entry.target);
            const x = primitiveF64Arg(args, 0) orelse return null;
            return value_ops.numberToValue(f(x));
        },
        native_legacy.sig_f64_f64_to_f64 => {
            const f: native_legacy.LeafF64F64ToF64 = @ptrCast(entry.target);
            const x = primitiveF64Arg(args, 0) orelse return null;
            const y = primitiveF64Arg(args, 1) orelse return null;
            return value_ops.numberToValue(f(x, y));
        },
        native_legacy.sig_void_to_void => {
            const f: native_legacy.LeafVoidToVoid = @ptrCast(entry.target);
            f();
            return core.JSValue.undefinedValue();
        },
        native_legacy.sig_i32_to_i32 => {
            const f: native_legacy.LeafI32ToI32 = @ptrCast(entry.target);
            const x = leafI32Arg(args, 0) orelse return null;
            return core.JSValue.int32(f(x));
        },
        native_legacy.sig_i32_i32_to_i32 => {
            const f: native_legacy.LeafI32I32ToI32 = @ptrCast(entry.target);
            const x = leafI32Arg(args, 0) orelse return null;
            const y = leafI32Arg(args, 1) orelse return null;
            return core.JSValue.int32(f(x, y));
        },
        native_legacy.sig_f64_to_void => {
            const f: native_legacy.LeafF64ToVoid = @ptrCast(entry.target);
            const x = leafF64Arg(args, 0) orelse return null;
            f(x);
            return core.JSValue.undefinedValue();
        },
        native_legacy.sig_bool_to_bool => {
            const f: native_legacy.LeafBoolToBool = @ptrCast(entry.target);
            if (args.len == 0) return null;
            const x = args[0].asBool() orelse return null;
            return core.JSValue.boolean(f(x));
        },
        native_legacy.sig_state_f64_to_void => {
            const f: native_legacy.LeafStateF64ToVoid = @ptrCast(entry.target);
            const x = leafF64Arg(args, 0) orelse return null;
            f(entry.state.?, x);
            return core.JSValue.undefinedValue();
        },
        native_legacy.sig_state_i32_to_i32 => {
            const f: native_legacy.LeafStateI32ToI32 = @ptrCast(entry.target);
            const x = leafI32Arg(args, 0) orelse return null;
            return core.JSValue.int32(f(entry.state.?, x));
        },
        else => return null,
    }
}

/// Canonical `i32` marshal (FNABI §15.3): a JS Number whose mathematical
/// value is an int32, whether it is int-tagged or double-represented. Any
/// other value (including a missing argument) is a miss.
inline fn leafI32Arg(args: []const core.JSValue, index: usize) ?i32 {
    if (index >= args.len) return null;
    const value = args[index];
    if (value.isInt()) return value.asInt32().?;
    if (value.asFloat64()) |f| {
        if (f != @trunc(f)) return null;
        if (f < -2147483648.0 or f > 2147483647.0) return null;
        // -0.0 is not an int32 value.
        if (f == 0 and std.math.signbit(f)) return null;
        return @intFromFloat(f);
    }
    return null;
}

/// Canonical `f64` marshal (FNABI §15.3): any JS Number, nothing else.
inline fn leafF64Arg(args: []const core.JSValue, index: usize) ?f64 {
    if (index >= args.len) return null;
    const value = args[index];
    if (value.isInt()) return @floatFromInt(value.asInt32().?);
    return value.asFloat64();
}

noinline fn invokeLeafFallback(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    entry: *const core.NativeEntry,
    args: []const core.JSValue,
    func_obj: ?*core.Object,
) HostError!core.JSValue {
    const fallback = entry.fallback orelse return error.TypeError;
    return sentinelToHost(ctx, fallback(ctx, this_value, args.ptr, @intCast(args.len), entry, func_obj));
}

/// Numeric C-proto calls mirror QuickJS's primitive JS_ToFloat64 fast path.
/// Strings, objects, BigInts and Symbols deliberately miss: the record's cold
/// typed generic+magic fallback owns their full, observable ToNumber semantics.
inline fn primitiveF64Arg(args: []const core.JSValue, index: usize) ?f64 {
    if (index >= args.len) return std.math.nan(f64);
    const value = args[index];
    if (value.isInt()) return @floatFromInt(value.asInt32().?);
    if (value.isFloat64()) return value.asFloat64().?;
    if (value.asBool()) |boolean| return if (boolean) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isUndefined()) return std.math.nan(f64);
    return null;
}

/// Probe the internal-builtin table for `native_ref` and invoke the record on
/// the construct (`new X()`) path: the current native environment is marked as
/// a constructor and `prototype`
/// (the resolved new.target instance `[[Prototype]]`) is threaded so the
/// record's construct branch can forward it to `constructWithPrototype`.
/// Returns null when the id is not table-dispatched so the caller can fall back
/// to its name/class construct cascade. QuickJS routes `new X()` through the
/// same C-function pointer as a call with a constructor cproto.
///
/// `func_obj` is optional: the migrated construct branches (Date/RegExp/String)
/// read only `args`/`new_target`, so VM construct fast paths that already hold
/// the coerced args and resolved prototype but no materialized constructor
/// object (e.g. `regexp_fastpath.regExpConstructCall`'s terminal) can route
/// their result through the table with `func_obj == null`.
pub fn callConstructRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []core.global_slots.Slot,
    func_obj: ?*core.Object,
    native_ref: core.function.NativeBuiltinRef,
    prototype: ?*core.Object,
    args: []const core.JSValue,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) HostError!?core.JSValue {
    return callConstructRecordImpl(true, ctx, output, global, globals, func_obj, native_ref, prototype, args, caller_function, caller_frame);
}

/// Construct-record terminal used by a constructor dispatcher that already
/// owns a `NativeBacktraceScope` spanning its observable argument coercions.
/// Keeping the terminal in that same scope avoids duplicate native frames.
pub fn callConstructRecordInNativeScope(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []core.global_slots.Slot,
    func_obj: ?*core.Object,
    native_ref: core.function.NativeBuiltinRef,
    prototype: ?*core.Object,
    args: []const core.JSValue,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) HostError!?core.JSValue {
    return callConstructRecordImpl(false, ctx, output, global, globals, func_obj, native_ref, prototype, args, caller_function, caller_frame);
}

fn callConstructRecordImpl(
    comptime push_native_frame: bool,
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []core.global_slots.Slot,
    func_obj: ?*core.Object,
    native_ref: core.function.NativeBuiltinRef,
    prototype: ?*core.Object,
    args: []const core.JSValue,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) HostError!?core.JSValue {
    const record = ctx.runtime.internalBuiltinRecord(@intCast(@intFromEnum(native_ref.domain)), native_ref.id) orelse return null;
    // Only construct-capable records honor the construct environment; a plain
    // record at this id (e.g. a
    // wrapper-primitive call entry) would otherwise run its call body, so
    // report a miss and let the caller fall through to its construct cascade.
    if (!record.isConstructor()) return null;
    if (push_native_frame) {
        try preflightCFunctionCall(ctx, global, func_obj, record.arity);
    }
    const view = try finalCallEnvironment(ctx, global, globals, func_obj);
    var native_scope = NativeBacktraceScope.init(view.ctx, func_obj);
    if (push_native_frame) native_scope.push();
    defer native_scope.deinit();

    const native_env: NativeCallEnvironment = .{
        .callable_realm = view.callable_realm,
        .output = output,
        .global = view.global,
        .globals = view.globals,
        .func_obj = func_obj,
        .is_constructor = true,
        .new_target = prototype,
        .caller_function = caller_function,
        .caller_frame = caller_frame,
    };
    const previous_native_call = view.ctx.runtime.active_native_call;
    view.ctx.runtime.active_native_call = &native_env;
    defer view.ctx.runtime.active_native_call = previous_native_call;

    return invokeResolvedInternalRecord(view.ctx, core.JSValue.undefinedValue(), record, args, func_obj) catch |err| {
        try materializeRuntimeError(view.ctx, view.global, err);
        return err;
    };
}

/// True when `native_ref` resolves to a construct-capable record (the
/// `JS_CFUNC_constructor` cproto analogue: Date/RegExp/String today). The
/// constructor-validity predicates (`isConstructorLike`/`isConstructorValue`)
/// use this to recognize a builtin constructor by its native id instead of its
/// resolved dispatch name, so a function carrying a builtin construct id but a
/// custom `name` still validates as a constructor. Misses report false.
pub fn isConstructRecordRef(rt: *const core.JSRuntime, native_ref: core.function.NativeBuiltinRef) bool {
    const record = rt.internalBuiltinRecord(@intCast(@intFromEnum(native_ref.domain)), native_ref.id) orelse return false;
    return record.isConstructor();
}

/// Recover the typed VM caller bytecode from a native call.
pub fn callerBytecode(call: NativeCall) ?*const Bytecode {
    return call.caller_function;
}

/// Recover the typed VM caller frame from a native call.
pub fn callerFrame(call: NativeCall) ?*Frame {
    return call.caller_frame;
}

/// True when the instruction the VM caller will execute on return is `drop`,
/// i.e. the call result is discarded. Native operation domains use this to take the
/// result-free mutation fast path (e.g. `Map.prototype.set`/`Set.prototype.add`
/// in statement position) without importing `src/bytecode.zig` for the opcode
/// constant. Mirrors `vm_call.zig`'s `preparedCallResultIsDropped`.
pub fn callerResultIsDropped(caller_function: ?*const Bytecode, caller_frame: ?*Frame) bool {
    const function = caller_function orelse return false;
    const frame = caller_frame orelse return false;
    return frame.pc < function.byteCode().len and function.byteCode()[frame.pc] == bytecode.opcode.op.drop;
}
