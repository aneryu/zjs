//! Fixed execution services for the engine compiled in this module.
//!
//! This is a source-level core/exec boundary, not a pluggable backend or a
//! Runtime resource. No installation, factory, mutable registry, or per-runtime
//! copy is needed. Context owns bootstrap transactions; jobs owns checkpoints.

const runtime = @import("runtime.zig");
const context = @import("core/context.zig");
const object = @import("core/object.zig");
const property = @import("core/property.zig");
const value = @import("core/value.zig");
const errors = @import("core/errors.zig");
const jobs = @import("core/jobs.zig");
const native_entry = @import("core/native_entry.zig");
const function = @import("core/function.zig");
const standard_globals = @import("exec/standard_globals.zig");
const vm = @import("exec/zjs_vm.zig");
const promises = @import("exec/promise_ops.zig");
const builtins = @import("exec/internal_builtins.zig");
const small_inline = @import("exec/small_inline.zig");
const inline_calls = @import("exec/inline_calls.zig");
const builtin_dispatch = @import("exec/builtin_dispatch.zig");
const atomics = @import("exec/atomics_ops.zig");
const FunctionBytecode = @import("bytecode.zig").FunctionBytecode;

// Preserve the former bootstrap callback error contracts. Callers retain
// their existing RuntimeError conversion and transaction rollback boundaries.
pub fn installStandardGlobals(ctx: *context.JSContext, global: *object.Object) anyerror!void {
    return standard_globals.installStandardGlobals(ctx, global);
}

pub fn materializeContextGlobal(ctx: *context.JSContext) anyerror!*object.Object {
    return vm.contextGlobal(ctx);
}

pub fn materializeBuiltinNamespace(rt: *runtime.JSRuntime, global: *object.Object, kind: property.AutoInitKind) anyerror!value.JSValue {
    return standard_globals.materializeBuiltinNamespace(rt, global, kind);
}

pub fn runMicrotask(rt: *runtime.JSRuntime) errors.HostError!jobs.RunOneStatus {
    return promises.runRuntimeMicrotask(rt);
}

/// Records have static lifetime in this engine module, even before a Realm
/// exists. Host-domain, gap and out-of-range ids retain their null result.
pub fn internalBuiltinRecord(domain: function.NativeBuiltinDomain, id: u32) ?*const native_entry.NativeEntry {
    return builtins.lookup(domain, id);
}

/// Small-inline `CallerState` teardown. Runs before FunctionBytecode clears
/// its code pointer; a function without one returns at the hot-pad read.
pub fn destroySmallInlineState(rt: *runtime.JSRuntime, fb: *FunctionBytecode) void {
    small_inline.destroyCallerState(rt, fb);
}

/// Atom edges held by a small-inline `CallerState` (TGC S3 §2.2 edge H).
pub fn traceSmallInlineAtoms(fb: *const FunctionBytecode, visitor: anytype) !void {
    return small_inline.traceCallerStateAtoms(fb, visitor);
}

/// The exec record published as `JSRuntime.execution.active_invocation`.
pub const ActiveInvocation = inline_calls.ActiveInvocation;
/// The exec record published as `JSRuntime.execution.active_native_call`.
pub const NativeCallEnvironment = builtin_dispatch.NativeCallEnvironment;

/// Live windows of the running invocations, innermost first.
pub fn traceActiveInvocations(invocation: *ActiveInvocation, visitor: *runtime.RootVisitor) runtime.RootTraceError!void {
    return inline_calls.traceRoots(invocation, visitor);
}

/// An Atomics.waitAsync waiter handed to the job queue for completion.
pub const AtomicsWaiter = atomics.AtomicsWaiter;

/// Release a waiter whose completion job was dropped (queue teardown or
/// termination discard).
pub fn destroyAtomicsWaiter(waiter: *AtomicsWaiter) void {
    atomics.destroyAsyncWaiter(waiter);
}

/// Runtime teardown: free every pending Atomics.waitAsync node of `rt`.
pub fn retireAtomicsWaiters(rt: *runtime.JSRuntime) void {
    atomics.retireAtomicsWaitersForRuntime(rt);
}

/// Promise roots of this Runtime's pending Atomics.waitAsync waiters. Only
/// called once the Runtime has linked a waiter (`wait_async_used`).
pub fn traceAtomicsWaitAsyncRoots(rt: *runtime.JSRuntime, visitor: *runtime.RootVisitor) runtime.RootTraceError!void {
    return atomics.traceWaitAsyncRoots(rt, visitor);
}
