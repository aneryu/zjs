//! Execution records embedded in `JSRuntime.execution`: live invocation
//! pointers, resident host invocation, stored backtrace, small-inline byte
//! accounting, and the waitAsync root-walk gate.
//!
//! Execution counters, stack guards, and the VM arena stay Runtime-owned. The
//! three live pointers stay distinct and are restored by their own callers:
//! `active_invocation` for the bytecode entry, `host_invocation` for the
//! resident executor, `active_native_call` for the native environment.

const std = @import("std");
const context_mod = @import("context.zig");
const engine_services = @import("../engine_services.zig");
const runtime_mod = @import("../runtime.zig");
const JSRuntime = runtime_mod.JSRuntime;

const ActiveBacktraceFrame = context_mod.ActiveBacktraceFrame;

/// Execution records embedded in `JSRuntime.execution`. The three live
/// pointers stay distinct and are restored by their own callers.
pub const State = struct {
    /// Borrowed exec-owned authority for the currently running bytecode
    /// invocation; its records chain through `previous`. The root walk
    /// visits them through `engine_services`.
    active_invocation: ?*ActiveInvocation = null,
    /// Exec-owned native environment of the innermost native call.
    active_native_call: ?*const NativeCallEnvironment = null,
    host_invocation: ?HostInvocation = null,
    small_inline: SmallInline = .{},
    /// Set by the owner thread when this Runtime first links an
    /// Atomics.waitAsync waiter; never cleared. Until then the root walk
    /// skips the process-global waiter registry and its mutex.
    wait_async_used: bool = false,
    /// Head of the stack-local observable backtrace chain. Native calls and
    /// synchronous native fences replace it on entry and restore it on return.
    current_backtrace_frame: ?*ActiveBacktraceFrame = null,
    formatting_error_stack: bool = false,

    /// Link `frame` as the head of the observable backtrace chain.
    pub inline fn pushBacktrace(self: *State, frame: *ActiveBacktraceFrame) void {
        frame.previous = self.current_backtrace_frame;
        self.current_backtrace_frame = frame;
    }

    /// Unlink the head pushed by the matching `pushBacktrace`. Strict LIFO;
    /// checked only in safe builds so the native-call windows stay a load and
    /// a store.
    pub inline fn popBacktrace(self: *State, frame: *ActiveBacktraceFrame) void {
        std.debug.assert(self.current_backtrace_frame == frame);
        self.current_backtrace_frame = frame.previous;
    }

    /// Publish `env` for the duration of one native call; returns the
    /// environment to restore with `leaveNativeCall`.
    pub inline fn enterNativeCall(self: *State, env: *const NativeCallEnvironment) ?*const NativeCallEnvironment {
        const previous = self.active_native_call;
        self.active_native_call = env;
        return previous;
    }

    pub inline fn leaveNativeCall(self: *State, previous: ?*const NativeCallEnvironment) void {
        self.active_native_call = previous;
    }

    /// Publish `invocation` as the running bytecode authority; returns the
    /// one it nests inside, to restore with `leaveInvocation`.
    pub inline fn enterInvocation(self: *State, invocation: *ActiveInvocation) ?*ActiveInvocation {
        const previous = self.active_invocation;
        self.active_invocation = invocation;
        return previous;
    }

    pub inline fn leaveInvocation(self: *State, previous: ?*ActiveInvocation) void {
        self.active_invocation = previous;
    }

    /// Error.stack formatting through a user `prepareStackTrace` must not
    /// recurse into itself; nested errors format plainly while this is set.
    pub inline fn beginErrorStackFormatting(self: *State) void {
        std.debug.assert(!self.formatting_error_stack);
        self.formatting_error_stack = true;
    }

    pub inline fn endErrorStackFormatting(self: *State) void {
        std.debug.assert(self.formatting_error_stack);
        self.formatting_error_stack = false;
    }

    /// Owner thread, on linking the first Atomics.waitAsync waiter.
    pub inline fn noteWaitAsyncUsed(self: *State) void {
        self.wait_async_used = true;
    }

    /// True while any invocation record is still published.
    pub fn hasLiveRecords(self: *const State) bool {
        return self.current_backtrace_frame != null or
            self.active_native_call != null or
            self.active_invocation != null or
            self.formatting_error_stack;
    }
};

pub const ActiveInvocation = engine_services.ActiveInvocation;
pub const NativeCallEnvironment = engine_services.NativeCallEnvironment;

/// Exec-owned resident execution root for embedder -> JS calls
/// (`exec/call_site.zig`), created on first use. Core cannot name the exec
/// type, so the record carries its own retire hook.
pub const HostInvocation = struct {
    ptr: *anyopaque,
    retire: *const fn (*JSRuntime, *anyopaque) void,
};

/// R-1 small-function-inlining budget. Exec owns the policy and the
/// `CallerState` side records (reached through `engine_services`); core only
/// accounts bytes.
pub const SmallInline = struct {
    /// Published production bytecode bytes.
    published_bytes: usize = 0,
    /// Bytes consumed by specialized copies.
    specialized_bytes: usize = 0,
};

/// Retire the resident executor. Destroy calls this before `vm_stack.deinit`.
pub fn retireHostInvocation(rt: *JSRuntime) void {
    const host_invocation = rt.execution.host_invocation orelse return;
    rt.execution.host_invocation = null;
    host_invocation.retire(rt, host_invocation.ptr);
}
