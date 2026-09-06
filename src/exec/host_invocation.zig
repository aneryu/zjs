//! Resident host invocation (P4, native-boundary plan): the execution root
//! the embedder's `JSContext.callFunction` reuses across calls.
//!
//! Every embedder call used to build a fresh execution root
//! (`runWithArgsState`: frame arena mark, Frame, Machine with its 4 KiB
//! chunk array + first 4 KiB chunk, backtrace view, ActiveInvocation) and
//! tear it all down again -- ~1500 instructions per call against QuickJS's
//! ~290 for `JS_Call`. This keeps ONE Machine per runtime alive between
//! calls and enters the callee exactly the way a builtin enters a callback:
//! push an Entry with `.native_boundary` return and run the dispatch loop
//! until it pops (`runSyncInlineRouteCopiedArgs`).
//!
//! Lifetime rules:
//! - The machine is published as `rt.active_invocation` only for the
//!   duration of a call. Idle, it is invisible to the GC, to backtraces and
//!   to the runtime-destroy invariants; the embedder never sees a
//!   half-published root.
//! - It is used only when no invocation is active (a nested host call from
//!   inside JS takes the existing same-machine sync route on the running
//!   invocation instead).
//! - Its L0 level is an inert idle frame + empty stack: the boundary entry
//!   returns to the host at `fence_depth == 0`, so depth 0 never executes.
//! - `(ctx, global, output)` are re-targeted per call at depth 0; the
//!   Machine only ever holds chunk storage between calls.
const std = @import("std");
const core = @import("../core/root.zig");
const bytecode = @import("../bytecode.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");
const inline_calls = @import("inline_calls.zig");
const active_invocation_trace = if (core.runtime.value_root_frames_enabled)
    @import("active_invocation_trace.zig")
else
    struct {};

/// Never executed and never traced (not in the GC address registry); only
/// its address is taken so the idle frame has a well-typed `function`.
var host_idle_function: bytecode.FunctionBytecode = undefined;

pub const HostInvocation = struct {
    idle_frame: frame_mod.Frame,
    idle_stack: stack_mod.Stack,
    idle_catch_target: ?usize = null,
    l0: inline_calls.L0State,
    machine: inline_calls.Machine,
    root_view: inline_calls.MachineBacktraceView,
    backtrace_frame: core.ActiveBacktraceFrame,
    invocation: inline_calls.ActiveInvocation,
    published: bool = false,

    pub fn create(rt: *core.JSRuntime, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !*HostInvocation {
        const self = try rt.memory.create(HostInvocation);
        self.* = .{
            .idle_frame = .{ .function = &host_idle_function },
            .idle_stack = stack_mod.Stack.init(&rt.memory, 0),
            .l0 = undefined,
            .machine = undefined,
            .root_view = undefined,
            .backtrace_frame = undefined,
            .invocation = undefined,
        };
        self.l0 = .{ .level = .{
            .frame = &self.idle_frame,
            .stack = &self.idle_stack,
            .catch_target = &self.idle_catch_target,
        } };
        self.machine = inline_calls.Machine.init(ctx, output, global, &self.l0);
        // A segment view with no bottom: the idle L0 level is never part of
        // a backtrace.
        self.root_view = inline_calls.MachineBacktraceView.segment(&self.machine, null);
        self.backtrace_frame = .{
            .data = &self.root_view,
            .resolver = inline_calls.resolveMachineBacktraceView,
        };
        self.invocation = .{
            .machine = &self.machine,
            .current_backtrace_view = &self.root_view,
        };
        if (comptime core.runtime.value_root_frames_enabled) {
            self.invocation.header = .{ .traceRoots = active_invocation_trace.traceRoots };
            self.invocation.previous = null;
        }
        return self;
    }

    pub fn destroy(self: *HostInvocation, rt: *core.JSRuntime) void {
        std.debug.assert(!self.published);
        std.debug.assert(self.machine.depth == 0);
        self.machine.deinitStorage(rt);
        self.idle_stack.deinit(rt);
        rt.memory.destroy(HostInvocation, self);
    }

    /// Runtime-owned singleton, created on first use.
    pub fn acquire(rt: *core.JSRuntime, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !*HostInvocation {
        if (rt.host_invocation) |ptr| {
            const self: *HostInvocation = @ptrCast(@alignCast(ptr));
            std.debug.assert(!self.published and self.machine.depth == 0);
            self.machine.ctx = ctx;
            self.machine.global = global;
            self.machine.output = output;
            return self;
        }
        const self = try create(rt, ctx, output, global);
        rt.host_invocation = self;
        rt.host_invocation_retire = retire;
        return self;
    }

    fn retire(rt: *core.JSRuntime, ptr: *anyopaque) void {
        const self: *HostInvocation = @ptrCast(@alignCast(ptr));
        self.destroy(rt);
    }

    /// Publish for one call: becomes the active invocation and the head of
    /// the backtrace chain. Requires no active invocation.
    pub fn publish(self: *HostInvocation, ctx: *core.JSContext) void {
        std.debug.assert(!self.published);
        std.debug.assert(ctx.runtime.active_invocation == null);
        std.debug.assert(self.machine.depth == 0);
        ctx.pushActiveBacktraceFrame(&self.backtrace_frame);
        self.root_view.live = true;
        self.invocation.current_backtrace_view = &self.root_view;
        ctx.runtime.active_invocation = &self.invocation;
        self.published = true;
    }

    pub fn unpublish(self: *HostInvocation, ctx: *core.JSContext) void {
        std.debug.assert(self.published);
        std.debug.assert(self.machine.depth == 0);
        ctx.runtime.active_invocation = null;
        ctx.popActiveBacktraceFrame(&self.backtrace_frame);
        self.published = false;
    }
};
