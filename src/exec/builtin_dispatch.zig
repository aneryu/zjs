//! Bridge between exec's native-record dispatch sites and the
//! builtins-owned internal record table (`rt.internal_builtins`).
//!
//! QuickJS source map: the JSCFunctionListEntry dispatch inside
//! JS_CallInternal. Exec probes the per-runtime table first; a hit calls the
//! record with zero compile-time knowledge of the builtin, a miss falls back
//! to the transitional per-domain enum dispatch (deleted class by class as
//! Phase 6 migrates them).
//!
//! This module also owns the typed erase/recover helpers for the VM caller
//! threading pair: `core.host_function.InternalCall` stores
//! (`?*const Bytecode`, `?*Frame`) as opaque pointers because core cannot
//! name exec/bytecode types. Builtins recover them through
//! `callerBytecode`/`callerFrame` and use the `Bytecode`/`Frame` aliases in
//! their own signatures instead of importing `src/bytecode.zig` directly.

const std = @import("std");
const core = @import("../core/root.zig");
const bytecode = @import("../bytecode.zig");
const exceptions = @import("exceptions.zig");
const frame_mod = @import("frame.zig");
const exception_ops = @import("vm_exception_ops.zig");
const value_ops = @import("value_ops.zig");

const HostError = exceptions.HostError;

pub const Bytecode = bytecode.Bytecode;
pub const Frame = frame_mod.Frame;

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
/// Returns null when the id is not (yet) table-dispatched so the caller can
/// continue with the transitional enum dispatch.
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
/// hot call is pure overhead. Shares the `InternalCall` build with
/// `callInternalRecord`. Returns the record's result (unwrapped, never null — a
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
    // QuickJS links a JSStackFrame around every C function call. Use the same
    // active-frame chain as bytecode invocations so an error created inside a
    // builtin captures the native callee before its bytecode caller. The data
    // is borrowed only for this synchronous invocation; snapshotting retains
    // the function value when an Error is materialized.
    var native_scope = NativeBacktraceScope.init(ctx, func_obj);
    native_scope.push();
    defer native_scope.deinit();

    return invokeResolvedInternalRecord(ctx, output, global, globals, func_obj, this_value, record, args, caller_function, caller_frame) catch |err| {
        try materializeRuntimeError(ctx, global, err);
        return err;
    };
}

inline fn invokeResolvedInternalRecord(
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
    // Most records are still on the transitional ABI. Keep its single compare
    // as the first branch so adding typed cprotos does not tax unmigrated
    // builtins on every call.
    if (record.cproto == .zjs_internal_call) {
        const call_fn = record.call orelse blk: {
            const native = record.native_function orelse return error.TypeError;
            break :blk native.zjs_internal_call;
        };
        return invokeInternalCall(call_fn, ctx, output, global, globals, func_obj, this_value, record, args, caller_function, caller_frame);
    }

    return callTypedInternalRecordDirect(ctx, output, global, globals, func_obj, this_value, record, args, caller_function, caller_frame);
}

/// Outlined so extending the typed-cproto set cannot push the overwhelmingly
/// common transitional branch out of its callers. Typed records take one cold
/// ABI-selection call, then their numeric function pointer remains direct.
noinline fn callTypedInternalRecordDirect(
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
    switch (record.cproto) {
        .f_f => {
            const native = record.native_function orelse return error.TypeError;
            const native_fn = switch (native) {
                .f_f => |function| function,
                else => return error.TypeError,
            };
            const value = primitiveF64Arg(args, 0) orelse
                return callInternalRecordFallback(ctx, output, global, globals, func_obj, this_value, record, args, caller_function, caller_frame);
            return value_ops.numberToValue(native_fn(value));
        },
        .f_f_f => {
            const native = record.native_function orelse return error.TypeError;
            const native_fn = switch (native) {
                .f_f_f => |function| function,
                else => return error.TypeError,
            };
            const lhs = primitiveF64Arg(args, 0) orelse
                return callInternalRecordFallback(ctx, output, global, globals, func_obj, this_value, record, args, caller_function, caller_frame);
            const rhs = primitiveF64Arg(args, 1) orelse
                return callInternalRecordFallback(ctx, output, global, globals, func_obj, this_value, record, args, caller_function, caller_frame);
            return value_ops.numberToValue(native_fn(lhs, rhs));
        },
        else => return error.TypeError,
    }
}

/// Numeric C-proto calls mirror QuickJS's primitive JS_ToFloat64 fast path.
/// Strings, objects, BigInts and Symbols deliberately miss: the record's cold
/// InternalCall fallback owns their full, observable ToNumber semantics.
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
    const call_fn = record.call orelse return error.TypeError;
    return invokeInternalCall(call_fn, ctx, output, global, globals, func_obj, this_value, record, args, caller_function, caller_frame);
}

inline fn invokeInternalCall(
    call_fn: core.host_function.InternalCallFn,
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
    // Record implementations are declared with error sets contained in
    // HostError and only widen to anyerror at the table boundary, so the
    // narrowing cast cannot fail at runtime.
    return call_fn(.{
        .ctx = ctx,
        .output = output,
        .global = global,
        .globals = globals,
        .func_obj = func_obj,
        .this_value = this_value,
        .args = args,
        .magic = record.magic,
        .caller_function = caller_function,
        .caller_frame = caller_frame,
    }) catch |err| return @as(HostError, @errorCast(err));
}

/// Probe the internal-builtin table for `native_ref` and invoke the record on
/// the construct (`new X()`) path: `flags.constructor` is set and `prototype`
/// (the resolved new.target instance `[[Prototype]]`) is threaded so the
/// record's construct branch can forward it to `constructWithPrototype`.
/// Returns null when the id is not table-dispatched so the caller can fall back
/// to its name/class construct cascade. QuickJS routes `new X()` through the
/// same C-function pointer as a call with `JS_CFUNC_constructor`'s cproto;
/// `flags.constructor` is the analogue selector.
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
    // Only construct-capable records (the `JS_CFUNC_constructor` cproto
    // analogue) honor `flags.constructor`; a plain record at this id (e.g. a
    // wrapper-primitive call entry) would otherwise run its call body, so
    // report a miss and let the caller fall through to its construct cascade.
    if (!record.constructor) return null;
    if (record.cproto != .zjs_internal_call) return error.TypeError;
    const call_fn = record.call orelse blk: {
        const native = record.native_function orelse return error.TypeError;
        break :blk native.zjs_internal_call;
    };
    var native_scope = NativeBacktraceScope.init(ctx, func_obj);
    if (push_native_frame) native_scope.push();
    defer native_scope.deinit();

    return call_fn(.{
        .ctx = ctx,
        .output = output,
        .global = global,
        .globals = globals,
        .func_obj = func_obj,
        .this_value = core.JSValue.undefinedValue(),
        .args = args,
        .magic = record.magic,
        .flags = .{ .constructor = true },
        .new_target = prototype,
        .caller_function = caller_function,
        .caller_frame = caller_frame,
    }) catch |err| {
        const host_err = @as(HostError, @errorCast(err));
        try materializeRuntimeError(ctx, global, host_err);
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
    return record.constructor;
}

/// Recover the typed VM caller bytecode from an internal call.
pub fn callerBytecode(call: core.host_function.InternalCall) ?*const Bytecode {
    const ptr = call.caller_function orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// Recover the typed VM caller frame from an internal call.
pub fn callerFrame(call: core.host_function.InternalCall) ?*Frame {
    const ptr = call.caller_frame orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// True when the instruction the VM caller will execute on return is `drop`,
/// i.e. the call result is discarded. Builtins use this to take the
/// result-free mutation fast path (e.g. `Map.prototype.set`/`Set.prototype.add`
/// in statement position) without importing `src/bytecode.zig` for the opcode
/// constant. Mirrors `vm_call.zig`'s `preparedCallResultIsDropped`.
pub fn callerResultIsDropped(caller_function: ?*const Bytecode, caller_frame: ?*Frame) bool {
    const function = caller_function orelse return false;
    const frame = caller_frame orelse return false;
    return frame.pc < function.code.len and function.code[frame.pc] == bytecode.opcode.op.drop;
}
