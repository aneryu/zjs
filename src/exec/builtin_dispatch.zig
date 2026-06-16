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
//! their own signatures instead of importing `src/bytecode/` directly.

const std = @import("std");
const core = @import("../core/root.zig");
const bytecode = @import("../bytecode/root.zig");
const exceptions = @import("exceptions.zig");
const frame_mod = @import("frame.zig");

const HostError = exceptions.HostError;

pub const Bytecode = bytecode.Bytecode;
pub const Frame = frame_mod.Frame;

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
    const call_fn = record.call.?;
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
    const record = ctx.runtime.internalBuiltinRecord(@intCast(@intFromEnum(native_ref.domain)), native_ref.id) orelse return null;
    // Only construct-capable records (the `JS_CFUNC_constructor` cproto
    // analogue) honor `flags.constructor`; a plain record at this id (e.g. a
    // wrapper-primitive call entry) would otherwise run its call body, so
    // report a miss and let the caller fall through to its construct cascade.
    if (!record.constructor) return null;
    const call_fn = record.call.?;
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
    }) catch |err| return @as(HostError, @errorCast(err));
}

/// True when `native_ref` resolves to a record that may be invoked without a
/// materialized function object (prepared-call eligibility). Misses report
/// false so the transitional per-domain gate stays authoritative for
/// unmigrated classes.
pub fn preparedCallOk(rt: *const core.JSRuntime, native_ref: core.function.NativeBuiltinRef) bool {
    const record = rt.internalBuiltinRecord(@intCast(@intFromEnum(native_ref.domain)), native_ref.id) orelse return false;
    return record.prepared_call_ok;
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
/// in statement position) without importing `src/bytecode/` for the opcode
/// constant. Mirrors `vm_call.zig`'s `preparedCallResultIsDropped`.
pub fn callerResultIsDropped(caller_function: ?*const Bytecode, caller_frame: ?*Frame) bool {
    const function = caller_function orelse return false;
    const frame = caller_frame orelse return false;
    return frame.pc < function.code.len and function.code[frame.pc] == bytecode.opcode.op.drop;
}
