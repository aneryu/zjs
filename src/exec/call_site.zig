//! `CallSite`: one resolved native -> JS call target (native-boundary design
//! section 6). It merges the three former entry paths -- the embedder's
//! `JSContext.callFunction` (`callFromHost` + the resident `HostInvocation`),
//! the builtin-callback `SyncInternalCallSite`, and the authoritative root
//! path `callValueOrBytecodeRoot` -- into one resolution product with two
//! ways in:
//!
//! - an invocation is active (a builtin running under the dispatch loop, or
//!   a host function that JS called): push a `.native_boundary` Entry on
//!   that Machine and run until it pops;
//! - no invocation is active (the embedder on its own C stack): publish the
//!   runtime's resident `HostInvocation` for the duration of the call and
//!   enter the same way.
//!
//! `init` does the per-target work once (callee class check, inline
//! eligibility through `resolveInlineFunction`, Realm match, the pin) and
//! `call` does only the per-call work: one interrupt poll, the Entry push
//! with copied arguments, the dispatch loop, the return.
//!
//! Route arms: `bytecode` (eligible plain bytecode function of the site's
//! Realm) and `generic` (bound functions, proxies, natives, generators,
//! cross-Realm callees: the JS_Call-shaped root path). A `native` arm that
//! dispatches a native callee straight to its record without a Machine is
//! owned by the core lane (`NativeEntry`) and is not part of this file yet.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/root.zig");
const bytecode = @import("../bytecode.zig");
const frame_mod = @import("frame.zig");
const inline_calls = @import("inline_calls.zig");
const call_runtime = @import("call_runtime.zig");
const exception_ops = @import("exception_ops.zig");
const host_invocation_mod = @import("host_invocation.zig");
const exceptions = @import("exceptions.zig");

const HostError = exceptions.HostError;
const JSValue = core.JSValue;

pub const BytecodeRoute = struct {
    /// The invocation that was active when the site was prepared, or null
    /// when it was prepared outside bytecode execution. The same-Machine arm
    /// compares it against the active invocation with one pointer test;
    /// a mismatch falls back to the (ctx, global, output) machine check.
    invocation: ?*inline_calls.ActiveInvocation,
    /// Receiver/callable/capture record, valid for any Machine of the site's
    /// Realm.
    target: inline_calls.InlineTarget,
    /// `nativeBoundarySimpleEligible(&target)`: the copied-args prologue is
    /// admissible; otherwise the owned-copy general prologue is used.
    simple: bool,
    /// `ctx`'s own Realm global is the site's `global`, so the runtime's
    /// resident host Machine (which runs under `ctx`) may execute the callee
    /// when no invocation is active.
    host_eligible: bool,
    /// The resident host invocation this site last entered through, with the
    /// re-target epoch that proved its Machine targets (ctx, output, global).
    /// A matching epoch replaces `HostInvocation.acquire`'s three-field
    /// re-proof with one compare; any other caller re-targeting the shared
    /// Machine bumps the epoch and sends this site back through `acquire`.
    host: ?*host_invocation_mod.HostInvocation = null,
    host_epoch: u32 = 0,
};

pub const Route = union(enum) {
    bytecode: BytecodeRoute,
    generic: void,
};

pub const CallSite = struct {
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: JSValue,
    callee: JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    route: Route,
    /// The pre-built lean frame for a bytecode route of a lean-eligible
    /// shape (native-boundary design section 6), initialized in place on
    /// the first call (`leanFrame`): an eager optional would be copied out
    /// of `initInternal` -- 300 bytes through q registers per builtin call.
    lean: inline_calls.LeanFrame,
    lean_state: enum(u8) { unknown, none, ready },
    /// Host sites pin callee/receiver through the runtime's persistent root
    /// ledger; engine-internal sites leave both empty (the callee is already
    /// rooted by the operand window or the algorithm's owned list).
    pins: Pins = .{},

    const Pins = struct {
        callee: core.JSValueHandle = .{},
        this_value: core.JSValueHandle = .{},
    };

    /// Host-side constructor: pins `callee` and `this_value` for the site's
    /// lifetime and resolves the route once. `deinit` releases the pins.
    pub fn init(
        ctx: *core.JSContext,
        output: ?*std.Io.Writer,
        global: *core.Object,
        this_value: JSValue,
        callee: JSValue,
    ) !CallSite {
        var site = initInternal(ctx, output, global, this_value, callee, null, null);
        site.pins.callee = try core.JSValueHandle.init(ctx.runtime, callee);
        errdefer site.pins.callee.deinit();
        site.pins.this_value = try core.JSValueHandle.init(ctx.runtime, this_value);
        return site;
    }

    /// Engine-internal constructor (the former `SyncInternalCallSite.init`):
    /// no pin, the callee/receiver are rooted by the caller for the site's
    /// lifetime. `caller_function`/`caller_frame` feed the root-path
    /// fallback's backtrace attribution exactly as before.
    pub inline fn initInternal(
        ctx: *core.JSContext,
        output: ?*std.Io.Writer,
        global: *core.Object,
        this_value: JSValue,
        callee: JSValue,
        caller_function: ?*const bytecode.FunctionBytecode,
        caller_frame: ?*frame_mod.Frame,
    ) CallSite {
        return .{
            .ctx = ctx,
            .output = output,
            .global = global,
            .this_value = this_value,
            .callee = callee,
            .caller_function = caller_function,
            .caller_frame = caller_frame,
            .route = resolveRoute(ctx, output, global, this_value, callee),
            .lean = undefined,
            .lean_state = .unknown,
        };
    }

    inline fn leanFrame(self: *CallSite, route: *const BytecodeRoute) ?*inline_calls.LeanFrame {
        switch (self.lean_state) {
            .ready => return if (self.lean.isIntact()) &self.lean else self.leanFrameInit(route),
            .none => return null,
            .unknown => return self.leanFrameInit(route),
        }
    }

    noinline fn leanFrameInit(self: *CallSite, route: *const BytecodeRoute) ?*inline_calls.LeanFrame {
        if (self.lean.initInPlace(self.ctx.runtime, &route.target)) {
            self.lean_state = .ready;
            return &self.lean;
        }
        self.lean_state = .none;
        return null;
    }

    pub fn deinit(self: *CallSite) void {
        self.pins.this_value.deinit();
        self.pins.callee.deinit();
        self.route = .generic;
    }

    /// Call with the site's receiver. Every call polls the interrupt once,
    /// then takes the same-Machine arm, the resident host arm, or the
    /// authoritative root path (in that order of preference).
    ///
    /// The result travels through `out` as two 64-bit words (pinned
    /// `ldp`/`stp`, see `Vm.takeNativeReturnInto`) and the error tag in a
    /// register: no 24-byte error union is materialized in memory, and the
    /// caller's 64-bit reads of the result forward. `callInto` is outlined so
    /// a native algorithm's loop body does not absorb the call's spill set;
    /// `call` is the by-value convenience wrapper.
    pub noinline fn callInto(self: *CallSite, args: []const JSValue, out: *JSValue) HostError!void {
        try exception_ops.pollInterrupt(self.ctx, self.global);
        switch (self.route) {
            .bytecode => |*route| return enterBytecode(null, self.ctx, self.output, self.global, route, &route.target, &self.this_value, &self.callee, args, self.caller_function, self.caller_frame, self.leanFrame(route), out),
            .generic => {},
        }
        return callGeneric(self.ctx, self.output, self.global, self.this_value, self.callee, args, self.caller_function, self.caller_frame, out);
    }

    pub inline fn call(self: *CallSite, args: []const JSValue) HostError!JSValue {
        var out: JSValue = undefined;
        try self.callInto(args, &out);
        return pinnedLoad(&out);
    }

    /// Fixed-arity forms. The argument window is written with pinned
    /// integer-pair stores from general registers: the frame constructor
    /// copies it with 64-bit loads, and a window LLVM had assembled through
    /// q registers (or left as a mem-to-mem copy of a sret temporary) misses
    /// store-to-load forwarding on every element.
    pub inline fn call0(self: *CallSite) HostError!JSValue {
        return self.callFixed(0, &.{});
    }

    pub inline fn call1(self: *CallSite, a0: JSValue) HostError!JSValue {
        var args: [1]JSValue = undefined;
        pinnedStore(&args[0], a0);
        return self.callFixed(1, &args);
    }

    pub inline fn call2(self: *CallSite, a0: JSValue, a1: JSValue) HostError!JSValue {
        var args: [2]JSValue = undefined;
        pinnedStore(&args[0], a0);
        pinnedStore(&args[1], a1);
        return self.callFixed(2, &args);
    }

    pub inline fn call3(self: *CallSite, a0: JSValue, a1: JSValue, a2: JSValue) HostError!JSValue {
        var args: [3]JSValue = undefined;
        pinnedStore(&args[0], a0);
        pinnedStore(&args[1], a1);
        pinnedStore(&args[2], a2);
        return self.callFixed(3, &args);
    }

    pub inline fn call4(self: *CallSite, a0: JSValue, a1: JSValue, a2: JSValue, a3: JSValue) HostError!JSValue {
        var args: [4]JSValue = undefined;
        pinnedStore(&args[0], a0);
        pinnedStore(&args[1], a1);
        pinnedStore(&args[2], a2);
        pinnedStore(&args[3], a3);
        return self.callFixed(4, &args);
    }

    /// Fixed-arity twin of `call` (`call0..call4`). The argument window is
    /// still written with pinned stores; the outlined walk is the existing
    /// `callInto` (one leftover copy). A comptime `argc` into `enterBytecode`
    /// outlined one ~6 KiB copy per leftover arity.
    pub inline fn callFixed(self: *CallSite, comptime argc: usize, args: *const [argc]JSValue) HostError!JSValue {
        var out: JSValue = undefined;
        try self.callFixedInto(argc, args, &out);
        return pinnedLoad(&out);
    }

    pub inline fn callFixedInto(self: *CallSite, comptime argc: usize, args: *const [argc]JSValue, out: *JSValue) HostError!void {
        return self.callInto(args, out);
    }

    /// Reuse the prepared callable route while supplying the receiver for
    /// this invocation (JSON reviver/replacer walks keep one callback but
    /// change the holder used as `this` at every step). The copied target is
    /// stack-local so nested or reentrant calls cannot mutate the site's
    /// immutable template. `this_value` must be rooted by the caller for the
    /// duration of the call.
    pub noinline fn callWithThisInto(self: *CallSite, this_value: JSValue, args: []const JSValue, out: *JSValue) HostError!void {
        try exception_ops.pollInterrupt(self.ctx, self.global);
        switch (self.route) {
            .bytecode => |*route| {
                var target = route.target;
                target.this_value = this_value;
                return enterBytecode(null, self.ctx, self.output, self.global, route, &target, &this_value, &self.callee, args, self.caller_function, self.caller_frame, self.leanFrame(route), out);
            },
            .generic => {},
        }
        return callGeneric(self.ctx, self.output, self.global, this_value, self.callee, args, self.caller_function, self.caller_frame, out);
    }

    pub inline fn callWithThis(self: *CallSite, this_value: JSValue, args: []const JSValue) HostError!JSValue {
        var out: JSValue = undefined;
        try self.callWithThisInto(this_value, args, &out);
        return pinnedLoad(&out);
    }
};

/// Pinned integer-pair load of a JSValue slot (`ldp` of two general
/// registers on AArch64). See `Vm.takeNativeReturnInto` for why the width
/// discipline matters at the boundary.
pub inline fn pinnedLoad(slot: *const JSValue) JSValue {
    if (comptime builtin.cpu.arch == .aarch64) {
        var lo: u64 = undefined;
        var hi: u64 = undefined;
        asm volatile ("ldp %[lo], %[hi], [%[p]]"
            : [lo] "=r" (lo),
              [hi] "=r" (hi),
            : [p] "r" (slot),
            : .{ .memory = true });
        return @bitCast([2]u64{ lo, hi });
    }
    return JSValue.loadSlotAsIntPair(slot);
}

/// Pinned integer-pair store of a JSValue slot (`stp` of two general
/// registers on AArch64); `pinnedLoad`'s twin.
pub inline fn pinnedStore(slot: *JSValue, value: JSValue) void {
    if (comptime builtin.cpu.arch == .aarch64) {
        const words: [2]u64 = @bitCast(value);
        asm volatile ("stp %[lo], %[hi], [%[p]]"
            :
            : [lo] "r" (words[0]),
              [hi] "r" (words[1]),
              [p] "r" (slot),
            : .{ .memory = true });
        return;
    }
    JSValue.storeSlotAsIntPair(slot, value);
}

/// One-shot form of `CallSite.initInternal` + `callInto` for callers that
/// do not keep a site (`JSContext.callFunction`): the route is decided in
/// registers and entered directly, so nothing site-shaped is materialized
/// around the call (only the 72-byte InlineTarget the frame constructors
/// read by pointer). The result lands in `out` as two 64-bit words.
pub inline fn callOnceInto(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: JSValue,
    callee: JSValue,
    args: []const JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    out: *JSValue,
) HostError!void {
    try exception_ops.pollInterrupt(ctx, global);
    if (inline_calls.activeInvocation(ctx.runtime)) |active| {
        // Nested host -> JS from inside a running callback: the callee is
        // resolved per call (the one-shot cache below belongs to the idle
        // resident Machine and must not be re-targeted while a call is live).
        if (inline_calls.resolveInlineFunction(global, callee)) |resolved| {
            const target = resolved.bind(this_value, callee);
            if (machineMatches(active.machine, ctx, output, global)) {
                const simple = inline_calls.Machine.nativeBoundarySimpleEligible(&target);
                return runOnInvocation(null, false, active, simple, &target, ctx, global, &this_value, &callee, args, null, out);
            }
        }
    } else if (hostEligible(ctx, global)) {
        // Embedder on its own C stack. The resident host invocation caches
        // the resolved route and the lean frame of the last one-shot callee,
        // so a `callFunction` loop over one callback pays resolution once.
        const rt = ctx.runtime;
        const host = try host_invocation_mod.HostInvocation.acquire(rt, ctx, output, global);
        if (host.oneShotRoute(rt, global, callee, this_value)) |route| {
            host.publish(rt);
            defer host.unpublish(rt);
            // The receiver and the callable are read out of the cached
            // target, not out of this frame: the guard above proved
            // `target.callable == callee`, and pointing at the parameters
            // would spill both 16-byte values to the caller's frame.
            return runOnInvocation(null, true, &host.invocation, route.simple, route.target, ctx, global, &route.target.this_value, &route.target.callable, args, route.lean, out);
        }
    }
    return callGeneric(ctx, output, global, this_value, callee, args, caller_function, caller_frame, out);
}

/// The resident host Machine runs under the caller's context; the root path
/// switches to the callee's Realm, so only the context's own Realm qualifies.
inline fn hostEligible(ctx: *core.JSContext, global: *core.Object) bool {
    const ctx_global = ctx.global orelse return false;
    return ctx_global == global;
}

/// `this_value`/`callee` by pointer: the site's own fields, so the generic
/// arm reads them where they are and the lean arm copies the receiver with
/// one pinned pair store (no 32-byte q-register temporary at every entry).
inline fn enterBytecode(
    comptime fixed_argc: ?usize,
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    route: *BytecodeRoute,
    target: *const inline_calls.InlineTarget,
    this_value: *const JSValue,
    callee: *const JSValue,
    args: []const JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    lean: ?*inline_calls.LeanFrame,
    out: *JSValue,
) HostError!void {
    if (inline_calls.activeInvocation(ctx.runtime)) |active| {
        // A Machine other than the one the site was prepared under may still
        // run the callee: the route is Machine-independent, only the
        // execution authority (context, Realm global, output) has to agree.
        if (active == route.invocation or machineMatches(active.machine, ctx, output, global)) {
            return runOnInvocation(fixed_argc, false, active, route.simple, target, ctx, global, this_value, callee, args, lean, out);
        }
    } else if (route.host_eligible) {
        return runOnHostInvocation(fixed_argc, ctx, output, global, route, target, this_value, callee, args, lean, out);
    }
    return callGeneric(ctx, output, global, this_value.*, callee.*, args, caller_function, caller_frame, out);
}

inline fn machineMatches(machine: *const inline_calls.Machine, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) bool {
    return machine.ctx == ctx and machine.global == global and machine.output == output;
}

/// The JS_Call-shaped root path: a fresh execution root in the callee's
/// Realm. Bound functions, proxies, natives, generators, cross-Realm and
/// cross-Machine callees all end here.
fn callGeneric(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: JSValue,
    callee: JSValue,
    args: []const JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    out: *JSValue,
) HostError!void {
    const value = try call_runtime.callValueOrBytecodeDispatchAfterInterruptPoll(
        ctx,
        output,
        global,
        this_value,
        callee,
        args,
        caller_function,
        caller_frame,
        true,
    );
    pinnedStore(out, value);
}

inline fn runOnInvocation(
    comptime fixed_argc: ?usize,
    comptime idle_machine: bool,
    invocation: *inline_calls.ActiveInvocation,
    simple: bool,
    target: *const inline_calls.InlineTarget,
    ctx: *core.JSContext,
    global: *core.Object,
    this_value: *const JSValue,
    callee: *const JSValue,
    args: []const JSValue,
    lean: ?*inline_calls.LeanFrame,
    out: *JSValue,
) HostError!void {
    if (simple) {
        return call_runtime.runSyncInlineRouteCopiedArgs(fixed_argc, idle_machine, invocation, target, global, this_value, args, lean, out);
    }
    return call_runtime.runSyncInlineRouteOwnedCopy(idle_machine, invocation, target, ctx, global, this_value.*, callee.*, args, out);
}

/// Embedder -> JS with no invocation active: publish the runtime's resident
/// host Machine for this one call and enter exactly like a builtin callback.
/// Nothing is published for a route that would take the root path anyway
/// (`host_eligible` was decided at resolution).
inline fn runOnHostInvocation(
    comptime fixed_argc: ?usize,
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    route: *BytecodeRoute,
    target: *const inline_calls.InlineTarget,
    this_value: *const JSValue,
    callee: *const JSValue,
    args: []const JSValue,
    lean: ?*inline_calls.LeanFrame,
    out: *JSValue,
) HostError!void {
    const rt = ctx.runtime;
    const host = blk: {
        if (route.host) |cached| {
            if (cached.retarget_epoch == route.host_epoch) break :blk cached;
        }
        break :blk try acquireForRoute(rt, ctx, output, global, route);
    };
    host.publish(rt);
    defer host.unpublish(rt);
    return runOnInvocation(fixed_argc, true, &host.invocation, route.simple, target, ctx, global, this_value, callee, args, lean, out);
}

/// Cold arm of the site's host-invocation binding: the runtime's resident
/// invocation may not exist yet, or another caller may have re-targeted its
/// Machine since this site last used it.
noinline fn acquireForRoute(
    rt: *core.JSRuntime,
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    route: *BytecodeRoute,
) HostError!*host_invocation_mod.HostInvocation {
    const host = try host_invocation_mod.HostInvocation.acquire(rt, ctx, output, global);
    route.host = host;
    route.host_epoch = host.retarget_epoch;
    return host;
}

/// Resolve once: callee class + inline eligibility (`resolveInlineFunction`
/// also rejects a callee whose Realm global is not `global`), the active
/// invocation's execution authority, and whether the resident host Machine
/// may run the callee under `ctx`.
inline fn resolveRoute(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: JSValue,
    callee: JSValue,
) Route {
    const resolved = inline_calls.resolveInlineFunction(global, callee) orelse return .generic;
    var route: BytecodeRoute = .{
        .invocation = null,
        .target = resolved.bind(this_value, callee),
        .simple = undefined,
        .host_eligible = false,
    };
    if (inline_calls.activeInvocation(ctx.runtime)) |active| {
        const machine = active.machine;
        if (machine.ctx == ctx and machine.global == global and machine.output == output) {
            route.invocation = active;
        }
    }
    route.host_eligible = hostEligible(ctx, global);
    route.simple = inline_calls.Machine.nativeBoundarySimpleEligible(&route.target);
    return .{ .bytecode = route };
}
