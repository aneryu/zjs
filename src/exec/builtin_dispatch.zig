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
const exception_ops = @import("vm_exception_ops.zig");
const value_ops = @import("value_ops.zig");

const HostError = exceptions.HostError;

var empty_realm_globals: [0]core.global_slots.Slot = .{};

pub const Bytecode = bytecode.Bytecode;
pub const Frame = frame_mod.Frame;

const NativeCallEnvironment = struct {
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []core.global_slots.Slot,
    func_obj: ?*core.Object,
    is_constructor: bool,
    new_target: ?*core.Object,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
};

const CallRealmView = struct {
    ctx: *core.RealmContext,
    global: ?*core.Object,
    globals: []core.global_slots.Slot,
};

/// Resolve the final call carrier only after the caller has selected a record
/// and completed its call-side preflight. True C_FUNCTION objects switch to
/// their owned construction realm; C_FUNCTION_DATA and synthetic calls retain
/// the incoming view. This mirrors js_call_c_function's late
/// `ctx = p->u.cfunc.realm` assignment (quickjs.c:17586).
fn finalCallRealmView(
    ctx: *core.JSContext,
    global: ?*core.Object,
    globals: []core.global_slots.Slot,
    func_obj: ?*core.Object,
) HostError!CallRealmView {
    const object = func_obj orelse return .{ .ctx = ctx, .global = global, .globals = globals };
    if (object.class_id != core.class.ids.c_function) return .{ .ctx = ctx, .global = global, .globals = globals };
    const realm = object.nativeFunctionRealm() orelse return error.InvalidBuiltinRegistry;
    return .{
        .ctx = realm,
        .global = realm.global,
        .globals = empty_realm_globals[0..],
    };
}

/// Exec-side convenience view for native implementations that need more than
/// their typed cproto arguments. It is reconstructed from the current
/// stack-local environment and is not stored in `InternalRecord`.
pub const NativeCall = struct {
    ctx: *core.JSContext,
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

inline fn activeNativeEnvironment(ctx: *core.JSContext) ?*const NativeCallEnvironment {
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

/// Turn a raw engine sentinel into its JS Error while the caller's native frame
/// is still active. Message-carrying throw helpers already leave a matching
/// pending exception and therefore take the allocation-free first return.
pub fn materializeRuntimeError(ctx: *core.JSContext, global: ?*core.Object, err: anytype) HostError!void {
    const error_global = global orelse return;
    if (exception_ops.pendingExceptionMatchesError(ctx, err)) return;
    const error_info = exception_ops.runtimeErrorInfo(err) orelse return;
    const error_value = exception_ops.createNamedError(ctx, error_global, error_info.name, error_info.message) catch |create_err| {
        return @as(HostError, @errorCast(create_err));
    };
    if (ctx.hasException()) ctx.clearException();
    _ = ctx.throwValue(error_value);
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
    const view = try finalCallRealmView(ctx, global, globals, func_obj);
    // QuickJS links a JSStackFrame around every C function call. Use the same
    // active-frame chain as bytecode invocations so an error created inside a
    // builtin captures the native callee before its bytecode caller. The data
    // is borrowed only for this synchronous invocation; snapshotting retains
    // the function value when an Error is materialized.
    var native_scope = NativeBacktraceScope.init(view.ctx, func_obj);
    native_scope.push();
    defer native_scope.deinit();

    const native_env: NativeCallEnvironment = .{
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

    return invokeResolvedInternalRecord(view.ctx, this_value, record, args) catch |err| {
        try materializeRuntimeError(view.ctx, view.global, err);
        return err;
    };
}

inline fn invokeResolvedInternalRecord(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    record: *const core.host_function.InternalRecord,
    args: []const core.JSValue,
) HostError!core.JSValue {
    return callTypedInternalRecordDirect(ctx, this_value, record, args);
}

/// Outlined so the ABI-selection switch does not inflate hot call sites.
noinline fn callTypedInternalRecordDirect(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    record: *const core.host_function.InternalRecord,
    args: []const core.JSValue,
) HostError!core.JSValue {
    const native = record.native_function orelse return error.TypeError;
    // `InternalRecord` is engine-owned and its table builder guarantees that
    // the function union tag equals `cproto`. QuickJS likewise stores an
    // untagged `JSCFunctionType` and interprets it solely through `cproto`;
    // retain the invariant check in safe builds without redispatching on the
    // duplicate union tag in every hot ABI arm.
    std.debug.assert(std.meta.activeTag(native) == record.cproto);
    switch (record.cproto) {
        .generic => {
            const native_fn = native.generic;
            return native_fn(ctx, this_value, args) catch |err| return @as(HostError, @errorCast(err));
        },
        .constructor => {
            const env = activeNativeEnvironment(ctx) orelse return error.TypeError;
            if (!env.is_constructor) return error.TypeError;
            const native_fn = native.constructor;
            return native_fn(ctx, this_value, args) catch |err| return @as(HostError, @errorCast(err));
        },
        .constructor_or_func => {
            const native_fn = native.constructor_or_func;
            return native_fn(ctx, this_value, args) catch |err| return @as(HostError, @errorCast(err));
        },
        .generic_magic => {
            const native_fn = native.generic_magic;
            return native_fn(ctx, this_value, args, record.magic) catch |err| return @as(HostError, @errorCast(err));
        },
        .constructor_magic => {
            const env = activeNativeEnvironment(ctx) orelse return error.TypeError;
            if (!env.is_constructor) return error.TypeError;
            const native_fn = native.constructor_magic;
            return native_fn(ctx, this_value, args, record.magic) catch |err| return @as(HostError, @errorCast(err));
        },
        .constructor_or_func_magic => {
            const native_fn = native.constructor_or_func_magic;
            return native_fn(ctx, this_value, args, record.magic) catch |err| return @as(HostError, @errorCast(err));
        },
        .getter => {
            const native_fn = native.getter;
            return native_fn(ctx, this_value) catch |err| return @as(HostError, @errorCast(err));
        },
        .setter => {
            const native_fn = native.setter;
            return native_fn(ctx, this_value, if (args.len == 0) core.JSValue.undefinedValue() else args[0]) catch |err| return @as(HostError, @errorCast(err));
        },
        .getter_magic => {
            const native_fn = native.getter_magic;
            return native_fn(ctx, this_value, record.magic) catch |err| return @as(HostError, @errorCast(err));
        },
        .setter_magic => {
            const native_fn = native.setter_magic;
            return native_fn(ctx, this_value, if (args.len == 0) core.JSValue.undefinedValue() else args[0], record.magic) catch |err| return @as(HostError, @errorCast(err));
        },
        .f_f => {
            const native_fn = native.f_f;
            const value = primitiveF64Arg(args, 0) orelse
                return callInternalRecordFallback(ctx, this_value, record, args);
            return value_ops.numberToValue(native_fn(value));
        },
        .f_f_f => {
            const native_fn = native.f_f_f;
            const lhs = primitiveF64Arg(args, 0) orelse
                return callInternalRecordFallback(ctx, this_value, record, args);
            const rhs = primitiveF64Arg(args, 1) orelse
                return callInternalRecordFallback(ctx, this_value, record, args);
            return value_ops.numberToValue(native_fn(lhs, rhs));
        },
    }
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

noinline fn callInternalRecordFallback(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    record: *const core.host_function.InternalRecord,
    args: []const core.JSValue,
) HostError!core.JSValue {
    const fallback = record.fallback_function orelse return error.TypeError;
    return fallback(ctx, this_value, args, record.magic) catch |err| return @as(HostError, @errorCast(err));
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
/// object (e.g. `regexp_fastpath.qjsRegExpConstructCall`'s terminal) can route
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
    const view = try finalCallRealmView(ctx, global, globals, func_obj);
    var native_scope = NativeBacktraceScope.init(view.ctx, func_obj);
    if (push_native_frame) native_scope.push();
    defer native_scope.deinit();

    const native_env: NativeCallEnvironment = .{
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

    return invokeResolvedInternalRecord(view.ctx, core.JSValue.undefinedValue(), record, args) catch |err| {
        const host_err = @as(HostError, @errorCast(err));
        try materializeRuntimeError(view.ctx, view.global, host_err);
        return host_err;
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
    return frame.pc < function.code.len and function.code[frame.pc] == bytecode.opcode.op.drop;
}
