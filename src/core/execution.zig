//! Cold execution bookkeeping: resident host invocation, stored backtrace,
//! and small-inline hooks.
//!
//! Execution counters, stack guards, and the VM arena are Runtime-owned. The
//! three live pointers stay distinct and are restored by their own callers:
//! `active_invocation` for the bytecode entry, `host_invocation` for the
//! resident executor, `active_native_call` for the native environment.

const std = @import("std");
const atom = @import("atom.zig");
const context_mod = @import("context.zig");
const runtime_mod = @import("../runtime.zig");
const JSRuntime = runtime_mod.JSRuntime;

const ActiveBacktraceFrame = context_mod.ActiveBacktraceFrame;

pub const SmallInlineDestroy = *const fn (rt: *JSRuntime, fb: *anyopaque) void;
pub const SmallInlineTraceAtoms = *const fn (
    rt: *JSRuntime,
    fb: *anyopaque,
    ctx: *anyopaque,
    visit: *const fn (ctx: *anyopaque, id: atom.Atom) void,
) void;

/// Exec-owned resident execution root for embedder -> JS calls
/// (`exec/call_site.zig`), created on first use. Core cannot name the exec
/// type, so the record carries its own retire hook.
pub const HostInvocation = struct {
    ptr: *anyopaque,
    retire: *const fn (*JSRuntime, *anyopaque) void,
};

/// R-1 small-function-inlining state. Exec owns the policy; core only
/// accounts bytes and calls the hooks.
pub const SmallInline = struct {
    /// Published production bytecode bytes.
    published_bytes: usize = 0,
    /// Bytes consumed by specialized copies.
    specialized_bytes: usize = 0,
    /// Tears down the `CallerState` hanging off a FunctionBytecode's hot pad.
    destroy: ?SmallInlineDestroy = null,
    /// TGC S3 §2.2 edge H: reports the atom ids a `CallerState` holds, since
    /// the FunctionBytecode trace cannot see into exec.
    trace_atoms: ?SmallInlineTraceAtoms = null,
};

/// Retire the resident executor. Destroy calls this before `vm_stack.deinit`.
pub fn retireHostInvocation(rt: *JSRuntime) void {
    const host_invocation = rt.host_invocation orelse return;
    rt.host_invocation = null;
    host_invocation.retire(rt, host_invocation.ptr);
}

pub fn linkActiveBacktrace(rt: *JSRuntime, frame: *ActiveBacktraceFrame) void {
    frame.previous = rt.current_backtrace_frame;
    rt.current_backtrace_frame = frame;
}

pub fn unlinkActiveBacktrace(rt: *JSRuntime, frame: *ActiveBacktraceFrame) void {
    std.debug.assert(rt.current_backtrace_frame == frame);
    rt.current_backtrace_frame = frame.previous;
    frame.previous = null;
}

pub fn installSmallInlineHooks(rt: *JSRuntime, destroy_hook: SmallInlineDestroy, trace_hook: SmallInlineTraceAtoms) void {
    if (rt.small_inline.destroy == null) rt.small_inline.destroy = destroy_hook;
    if (rt.small_inline.trace_atoms == null) rt.small_inline.trace_atoms = trace_hook;
}
