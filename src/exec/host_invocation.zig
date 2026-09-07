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
const builtin = @import("builtin");
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
    /// Bumped by every re-target of the resident Machine. A `CallSite` that
    /// has entered through this invocation once caches (invocation, epoch)
    /// and re-uses it with one compare, instead of re-proving
    /// (ctx, output, global) against the Machine on every call.
    retarget_epoch: u32 = 0,
    /// Lean frame (`inline_calls.LeanFrame`) of the last one-shot callee,
    /// keyed by the callee value, its FunctionBytecode and its capture base
    /// (a collected closure whose address is reused cannot alias all three
    /// with a different frame shape). Only read while a call is live, when
    /// the embedder holds the callee.
    lean: inline_calls.LeanFrame = undefined,
    lean_callee: core.JSValue = core.JSValue.undefinedValue(),
    lean_valid: bool = false,
    /// One-shot route cache (`JSContext.callFunction`): the last resolved
    /// `InlineTarget` and its lean frame, so an embedder loop over one
    /// callback resolves the callee once instead of on every call --
    /// `resolveInlineFunction` walks callable -> storage -> FunctionBytecode
    /// -> CallFacts -> Realm -> global and then binds a 56-byte target onto
    /// the caller's frame, ~30 instructions of which the cache keeps only a
    /// global compare and a callable compare.
    ///
    /// `one_shot_pin` is what makes the cached facts sound across calls: the
    /// callee object (and through its FunctionBytecode, its Realm) cannot be
    /// collected and have its address reused under a stale resolution. It is
    /// released when the cached callee changes and at `destroy`.
    ///
    /// Re-targeting can never race a live call: the cache is read ONLY from
    /// the arm of `call_site.callOnceInto` that requires no active
    /// invocation, and a nested host -> JS call from inside a running
    /// callback has one, so it takes the same-Machine route instead.
    one_shot_target: inline_calls.InlineTarget = undefined,
    one_shot_global: ?*core.Object = null,
    one_shot_pin: core.JSValueHandle = .{},
    one_shot_simple: bool = false,

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
        self.one_shot_global = null;
        self.one_shot_pin.deinit();
        self.machine.deinitStorage(rt);
        self.idle_stack.deinit(rt);
        rt.memory.destroy(HostInvocation, self);
    }

    /// Runtime-owned singleton, created on first use.
    pub inline fn acquire(rt: *core.JSRuntime, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !*HostInvocation {
        if (rt.host_invocation) |ptr| {
            const self: *HostInvocation = @ptrCast(@alignCast(ptr));
            std.debug.assert(!self.published and self.machine.depth == 0);
            if (!self.machine.alreadyTargets(ctx, output, global)) {
                self.machine.retarget(ctx, output, global);
                self.retarget_epoch +%= 1;
            }
            return self;
        }
        return acquireSlow(rt, ctx, output, global);
    }

    noinline fn acquireSlow(rt: *core.JSRuntime, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !*HostInvocation {
        const self = try create(rt, ctx, output, global);
        rt.host_invocation = self;
        rt.host_invocation_retire = retire;
        return self;
    }

    /// The cached lean frame for `target`, (re)initialized on a callee change;
    /// null when the callee's shape is not lean-eligible.
    pub inline fn leanFrameFor(self: *HostInvocation, rt: *core.JSRuntime, target: *const inline_calls.InlineTarget) ?*inline_calls.LeanFrame {
        if (self.lean_valid and self.lean.isIntact() and
            self.lean_callee.repr.payload == target.callable.repr.payload and
            self.lean_callee.repr.tag == target.callable.repr.tag and
            self.lean.entry.frame.function == target.fb and
            self.lean.entry.frame.var_refs.ptr == target.var_refs)
        {
            return &self.lean;
        }
        return self.leanFrameInit(rt, target);
    }

    noinline fn leanFrameInit(self: *HostInvocation, rt: *core.JSRuntime, target: *const inline_calls.InlineTarget) ?*inline_calls.LeanFrame {
        self.lean_valid = false;
        if (!self.lean.initInPlace(rt, target)) return null;
        self.lean_callee = target.callable;
        self.lean_valid = true;
        return &self.lean;
    }

    /// The resolved one-shot route for `callee` under `global`, with this
    /// call's receiver written into the cached target, or null when the
    /// callee is not eligible for same-Machine bytecode execution (the
    /// caller takes the authoritative root path).
    pub const OneShotRoute = struct {
        target: *inline_calls.InlineTarget,
        lean: ?*inline_calls.LeanFrame,
        simple: bool,
    };

    pub inline fn oneShotRoute(
        self: *HostInvocation,
        rt: *core.JSRuntime,
        global: *core.Object,
        callee: core.JSValue,
        this_value: core.JSValue,
    ) ?OneShotRoute {
        const target = &self.one_shot_target;
        if (self.one_shot_global == global and
            target.callable.repr.payload == callee.repr.payload and
            target.callable.repr.tag == callee.repr.tag)
        {
            // By value, not through `&this_value`: taking the caller's
            // address forces the receiver into the caller's frame and adds a
            // `str q` / `ldr` round trip in front of every call.
            core.JSValue.storeSlotAsIntPair(&target.this_value, this_value);
            return .{
                .target = target,
                .lean = if (self.lean_valid and self.lean.isIntact()) &self.lean else null,
                .simple = self.one_shot_simple,
            };
        }
        return self.oneShotRouteResolve(rt, global, callee, this_value);
    }

    noinline fn oneShotRouteResolve(
        self: *HostInvocation,
        rt: *core.JSRuntime,
        global: *core.Object,
        callee: core.JSValue,
        this_value: core.JSValue,
    ) ?OneShotRoute {
        self.one_shot_global = null;
        self.one_shot_pin.deinit();
        self.one_shot_pin = .{};
        const resolved = inline_calls.resolveInlineFunction(global, callee) orelse return null;
        // Pin before publishing the resolution: the cached CallFacts and
        // Realm belong to this exact callee object.
        self.one_shot_pin = core.JSValueHandle.init(rt, callee) catch return null;
        self.one_shot_target = resolved.bind(this_value, callee);
        self.one_shot_simple = inline_calls.Machine.nativeBoundarySimpleEligible(&self.one_shot_target);
        self.one_shot_global = global;
        return .{
            .target = &self.one_shot_target,
            .lean = self.leanFrameFor(rt, &self.one_shot_target),
            .simple = self.one_shot_simple,
        };
    }

    fn retire(rt: *core.JSRuntime, ptr: *anyopaque) void {
        const self: *HostInvocation = @ptrCast(@alignCast(ptr));
        self.destroy(rt);
    }

    /// Publish for one call: becomes the active invocation and the head of
    /// the backtrace chain. Requires no active invocation.
    pub inline fn publish(self: *HostInvocation, rt: *core.JSRuntime) void {
        std.debug.assert(!self.published);
        std.debug.assert(rt.active_invocation == null);
        std.debug.assert(self.machine.depth == 0);
        // `root_view.live` and `invocation.current_backtrace_view` are
        // invariants of the idle machine (set at creation; an idle-mode
        // boundary scope never installs a nested view), so a publish is the
        // backtrace link plus the invocation pointer.
        std.debug.assert(self.root_view.live and self.invocation.current_backtrace_view == &self.root_view);
        // `rt` by parameter, not `ctx.runtime`: the caller already holds it,
        // and re-deriving it here cost two dependent loads per publish and
        // two more per unpublish on every embedder crossing.
        const hot = &rt.hot;
        self.backtrace_frame.previous = hot.current_backtrace_frame;
        hot.current_backtrace_frame = &self.backtrace_frame;
        rt.active_invocation = &self.invocation;
        if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) self.published = true;
    }

    pub inline fn unpublish(self: *HostInvocation, rt: *core.JSRuntime) void {
        std.debug.assert(self.published);
        std.debug.assert(self.machine.depth == 0);
        std.debug.assert(rt.hot.current_backtrace_frame == &self.backtrace_frame);
        const hot = &rt.hot;
        rt.active_invocation = null;
        hot.current_backtrace_frame = self.backtrace_frame.previous;
        if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) self.published = false;
    }
};
