//! VM call/construct routing and the runtime machinery around call frames.
//!
//! Callees and arguments borrowed from the operand stack remain frame-rooted
//! until their region is released; results pushed with `pushOwned` transfer one
//! owned reference. The alias wall keeps extracted subsystems behind their
//! established names without recreating a dependency cycle. The explicit
//! `ctx`/`output`/`global`/caller-function/caller-frame tuple is a measured ABI:
//! `global` is the call's realm authority, and publishing these scalars through
//! shared VM/context state regresses the hot path. Hot dispatch arms therefore
//! stay separate from cold catch and fallback bodies. Mirrors QuickJS's
//! JS_CallInternal and constructor dispatch.

const std = @import("std");
const function_ops = @import("function_ops.zig");
const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const internal_builtins = @import("internal_builtins.zig");
const parser = @import("../parser.zig");
const unicode_lib = @import("../libs/unicode.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call_mod = @import("call.zig");
const date_ops = @import("date_ops.zig");
const exception_ops = @import("exception_ops.zig");
const frame_mod = @import("frame.zig");
const iterator_ops = @import("iterator_ops.zig");
const inline_calls = @import("inline_calls.zig");
const property_ops = @import("property_ops.zig");
const zjs_vm = @import("zjs_vm.zig");
const vm_opcodes = @import("vm_opcodes.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");
const HostError = exception_ops.HostError;
const op = bytecode.opcode.op;
const runWithCallEnv = zjs_vm.runWithCallEnv;
const runWithCallEnvAfterInterruptPoll = zjs_vm.runWithCallEnvAfterInterruptPoll;
const string_ops = @import("string_ops.zig");
const array_ops = @import("array_ops.zig");
const promise_ops = @import("promise_ops.zig");
const object_ops = @import("object_ops.zig");
const builtin_glue = @import("builtin_glue.zig");

pub const InlineCallRequest = struct {
    target: inline_calls.InlineTarget,
    /// Index of the operand region on the caller stack; its shape (where the
    /// callable, receiver, and args live) is given by `layout`.
    region_base: usize,
    argc: u16,
    /// Operand-region layout for the dispatch loop's push (see `RegionLayout`).
    layout: inline_calls.RegionLayout = .plain,
};

/// Payload-free: the `inline_call` request is written through `req_out` (a
/// caller-owned shared frame slot) instead of being returned by value, so the
/// 88-byte InlineCallRequest no longer materializes a per-call-site sret alloca.
pub const ExecCallResult = enum { done, continue_loop, inline_call };

pub fn execCall(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    argc: u16,
    output: ?*std.Io.Writer,
    global: *core.Object,
    allow_inline: bool,
    req_out: *InlineCallRequest,
) align(32) !ExecCallResult {
    // Zero-copy call sequence: borrow `func` and `args` directly from the
    // operand stack (which is owned by the caller's frame) instead
    // of popping them into a duplicated, separately rooted staging buffer.
    // The region is popped and released only after the call completes, so
    // the values stay rooted for the whole call.
    const total: usize = @as(usize, argc) + 1;
    if (stack.len() < total) return error.StackUnderflow;
    const region_base = stack.len() - total;
    const func = stack.values[region_base];
    const args: []const core.JSValue = stack.values[region_base + 1 ..][0..argc];

    // Fast path FIRST: a plain bytecode-to-bytecode call resolves to an inline
    // target. `this` binds undefined (arrow targets override with their lexical
    // `this` inside resolveInlineTarget). A non-bytecode callee falls through to
    // the general dispatch, which handles host-output (console.log) like any other
    // host function — qjs has no per-call host-output fast path.
    if (allow_inline) {
        if (inline_calls.resolveInlineTarget(global, core.JSValue.undefinedValue(), func)) |target| {
            req_out.* = .{ .target = target, .region_base = region_base, .argc = argc };
            return .inline_call;
        }
    }

    // OP_call is never a constructor call. Legal super() is emitted as
    // call_constructor (or apply(1)); superclass identity alone cannot grant a
    // normal call permission to invoke a class constructor.
    const result = callValueOrBytecodeDispatch(ctx, output, global, core.JSValue.undefinedValue(), func, args, function, frame, .borrow) catch |err| {
        popOwnedStackRegion(stack, region_base);
        // This close runs return() after the call window is popped. tryCatchInFrame scans again, sees the iterator slot already undefined, and does not call return() a second time.
        try iterator_ops.closeStackTopForOfIteratorForPendingError(ctx, output, global, stack);
        if (try handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) {
            return .continue_loop;
        }
        return err;
    };
    popOwnedStackRegion(stack, region_base);
    stack.pushOwnedAssumeCapacity(result);
    return .done;
}

/// Drop the operand window above `region_base`; the collector scans only the
/// published stack length.
pub fn popOwnedStackRegion(stack: *stack_mod.Stack, region_base: usize) void {
    stack.setLen(region_base);
}

// noinline: this is the cold exception path shared by every `*Vm` opcode wrapper.
// Inlining it splices the whole catch machinery (iterator close, error
// construction, stack unwinding) into each hot handler's frame — inflating the
// spill set the hot path must set up and tear down every call. Outlining keeps a
// single `bl` on the cold edge and shrinks every wrapper's frame.
pub noinline fn handleCatchableRuntimeError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
    err: anyerror,
) !bool {
    return tryCatchInFrame(ctx, output, stack, frame, catch_target, global, err);
}

/// Attempt to dispatch `err` to the current frame's catch handler. Returns
/// true when the frame has a catch target: the operand stack is trimmed to
/// the marker, the exception value is pushed, and `frame.pc` moves to the
/// handler. Errors with no handler in the current frame propagate out of
/// the dispatch loop, where the inline-call machine unwinds suspended
/// frames before the error escapes `runWithArgsState`.
pub fn tryCatchInFrame(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
    err: anyerror,
) !bool {
    if (err == error.Interrupted) {
        // A bare poll result from the parser or a native loop is as
        // uncatchable as the VM's own interrupt.
        exception_ops.raiseBareInterrupt(ctx, global, err);
        return false;
    }
    if (ctx.exceptionIsUncatchable()) return false;
    const is_pending_exception = exception_ops.pendingExceptionMatchesError(ctx, err);
    const error_info = if (is_pending_exception) null else exception_ops.runtimeErrorInfo(err) orelse return false;
    // Run before testing the local catch target: an uncaught abrupt completion
    // must close this frame's live pattern/loop iterators before the frame is
    // unwound. IteratorNext marks only its failing record undefined before it
    // reaches this seam, so enclosing pattern iterators still close normally.
    try iterator_ops.closeStackTopForOfIteratorForPendingError(ctx, output, global, stack);
    const target = catch_target.* orelse {
        // No handler here: materialize a sentinel now, while this frame is
        // still the innermost, so its backtrace starts at the throwing
        // function rather than at whichever caller catches it. Callers match
        // the pending exception back to `err` by name. OOM keeps its
        // allocation-free path; the derived-constructor result
        // checks run after the callee context is removed (§10.2.2 steps
        // 10-12), so the caller materializes them in its own realm.
        if (error_info) |info| switch (err) {
            error.OutOfMemory, error.DerivedConstructorReturn, error.DerivedThisUninitialized => {},
            else => _ = ctx.throwValue(try exception_ops.createSentinelError(ctx, global, err, info)),
        };
        return false;
    };
    try stack.reserveAdditional(1);
    const catch_value: core.JSValue = if (is_pending_exception)
        ctx.takeException()
    else
        exception_ops.createSentinelError(ctx, global, err, error_info.?) catch |create_err| blk: {
            // A fully exhausted heap cannot materialize a fresh error object;
            // fall back to the preallocated out-of-memory exception so the
            // JS catch handler still runs (allocation-free dup). This is the
            // delivery point of the documented no-stack exemption: the
            // preallocated error is dup()ed, never rebuilt, so no stack can
            // be captured here.
            if (create_err == error.OutOfMemory) {
                if (ctx.preallocated_oom_error) |prealloc| break :blk prealloc;
            }
            return create_err;
        };
    var catch_value_owned = true;
    errdefer if (catch_value_owned and is_pending_exception) {
        _ = ctx.throwValue(catch_value);
    };
    if (!is_pending_exception and ctx.hasException()) ctx.clearException();
    const restored = (try array_ops.popCatchMarker(stack)) orelse null;
    stack.pushOwnedAssumeCapacity(catch_value);
    catch_value_owned = false;
    frame.pc = target;
    catch_target.* = restored;
    return true;
}

pub fn callValueOrBytecodeRoot(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    // Raw ABI snapshots remain in dispatch frames across interrupt callbacks
    // and nested calls. Register a borrowed slice even in production builds,
    // before overflow-buffer allocation; scalar-only frames are insufficient.
    const call_values = [_]core.JSValue{ global.value(), this_value, func };
    var root_slices = [_]core.runtime.ValueRootSlice{
        .{ .borrowed = &call_values },
        .{ .borrowed = args },
    };
    var root_frame = core.runtime.ValueRootFrame{ .slices = &root_slices };
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);
    var inline_args: [8]core.JSValue = undefined;
    var args_buffer: core.runtime.ValueRootBuffer = .{};
    defer args_buffer.deinit();
    const rooted_args: []const core.JSValue = if (args.len <= inline_args.len) blk: {
        @memcpy(inline_args[0..args.len], args);
        break :blk inline_args[0..args.len];
    } else blk: {
        args_buffer = try core.runtime.ValueRootBuffer.initCopy(ctx.runtime, args);
        break :blk args_buffer.values();
    };
    // Switch protection to the owned snapshot before a callback can mutate
    // the caller's original argument window. Cleanup does not collect.
    root_slices[1] = .{ .borrowed = rooted_args };
    return callValueOrBytecodeDispatch(ctx, output, global, this_value, func, rooted_args, caller_function, caller_frame, .copy);
}

/// Eagerly coerce the receiver of an async function start, whose `this` is
/// consumed outside a Frame. Ordinary normal bytecode
/// calls retain raw `this` and materialize it when first observed.
pub fn coerceCallThis(
    ctx: *core.JSContext,
    global: *core.Object,
    runtime_strict: bool,
    this_value: core.JSValue,
) HostError!core.JSValue {
    if (runtime_strict) return this_value;
    if (this_value.is(.undefined_value) or this_value.is(.null_value)) return global.value();
    if (!this_value.is(.object)) {
        return try object_ops.primitiveObjectForAccess(ctx.runtime, global, this_value);
    }
    return this_value;
}

pub fn callNativeBuiltinRecordForVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    native_ref: core.function.NativeBuiltinRef,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    // Route the VM hot path through the same exec-owned internal record
    // table the slow record dispatch uses (`call.zig:callNativeFunctionRecord`),
    // so this generic call Module carries zero compile-time knowledge of domains. The
    // VM call site only has the caller `global` object (no legacy slot array),
    // so pass it with an empty slice. Observable handlers ignore both as realm
    // authorities and consume the final callable view; only explicitly
    // func-object-free synthetic record reuse can retain supplied legacy data.
    if (internal_builtins.lookup(native_ref.domain, native_ref.id)) |record| {
        if (function_object.class_id == core.class.ids.c_function) {
            try builtin_dispatch.preflightCFunctionCall(ctx, global, function_object, record.arity);
            const view = try builtin_dispatch.finalCallableRealmView(ctx, function_object);
            return try builtin_dispatch.callInternalRecordDirectInRealm(view, output, function_object, this_value, record, args, caller_function, caller_frame);
        }
        return try builtin_dispatch.callInternalRecordDirect(ctx, output, global, &.{}, function_object, this_value, record, args, caller_function, caller_frame);
    }
    // Host builtins are exec-owned integer records too, but unlike standard
    // builtins they do not live in internal_builtins.table. Dispatch them by id
    // here.
    if (native_ref.domain == .engine_helper) {
        return try call_mod.callEngineHelperDomain(ctx, function_object, this_value, native_ref.id);
    }
    // Standard-native domains are table-dispatched. A null result now only
    // identifies an invalid or stale standard-native id for the caller to
    // classify.
    return null;
}

/// `.copy` is JS_CALL_FLAG_COPY_ARGV. `.borrow` is flags=0: the opcode window
/// may be borrowed when the actual arity already covers the formals.
pub const ArgvMode = enum { copy, borrow };

/// Variant for callers whose `this_value`, `func`, and `args` are already
/// rooted (e.g. borrowed directly from a frame-rooted operand stack).
/// Skips the defensive copy and extra value-root frame of
/// `callValueOrBytecodeRoot`.
pub fn callValueOrBytecodeRootPreRooted(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    return callValueOrBytecodeDispatch(ctx, output, global, this_value, func, args, caller_function, caller_frame, .copy);
}

/// VM fast-call fallback after the opcode path has already performed the
/// caller-Realm call-entry poll.
pub fn callValueOrBytecodeRootPreRootedAfterInterruptPoll(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    return callValueOrBytecodeDispatchAfterInterruptPoll(ctx, output, global, this_value, func, args, caller_function, caller_frame, .borrow);
}

/// Transactional owned staging for a synchronous native -> bytecode call.
/// The first two slots are `[receiver, callable]`, followed by arguments.
/// Construction publishes only the initialized prefix to the Runtime root
/// chain; successful frame setup replaces every transferred slot with
/// undefined, while any failure releases exactly the remaining owners.
const OwnedArgList = struct {
    const inline_capacity = 10;

    rt: ?*core.JSRuntime = null,
    inline_values: [inline_capacity]core.JSValue = undefined,
    values: []core.JSValue = &.{},
    rooted_prefix: []core.JSValue = &.{},
    root: array_ops.ValueSliceRoot = .{},
    heap_backed: bool = false,

    /// Allocate `total` slots and publish an empty rooted prefix. Callers
    /// advance `rooted_prefix` only after the corresponding slots are written.
    inline fn reserve(self: *OwnedArgList, rt: *core.JSRuntime, total: usize) HostError!void {
        std.debug.assert(self.rt == null);
        self.rt = rt;
        self.values = if (total <= self.inline_values.len)
            self.inline_values[0..total]
        else blk: {
            self.heap_backed = true;
            break :blk try rt.nativeAllocator().alloc(core.JSValue, total);
        };
        self.rooted_prefix = self.values[0..0];
        self.root.init(rt, &self.rooted_prefix);
    }

    fn init(
        self: *OwnedArgList,
        rt: *core.JSRuntime,
        receiver: core.JSValue,
        callable: core.JSValue,
        args: []const core.JSValue,
    ) HostError!void {
        const total = try std.math.add(usize, args.len, 2);
        try self.reserve(rt, total);
        errdefer self.deinit();

        self.values[0] = receiver;
        self.rooted_prefix = self.values[0..1];
        self.values[1] = callable;
        self.rooted_prefix = self.values[0..2];
        for (args, 0..) |arg, index| {
            self.values[index + 2] = arg;
            self.rooted_prefix = self.values[0 .. index + 3];
        }
    }

    fn initTakeArgs(
        self: *OwnedArgList,
        rt: *core.JSRuntime,
        receiver: core.JSValue,
        callable: core.JSValue,
        args: []core.JSValue,
    ) HostError!void {
        const total = try std.math.add(usize, args.len, 2);
        try self.reserve(rt, total);
        errdefer self.deinit();

        self.values[0] = receiver;
        self.rooted_prefix = self.values[0..1];
        self.values[1] = callable;
        self.rooted_prefix = self.values[0..2];
        @memcpy(self.values[2..], args);
        @memset(args, core.JSValue.undefinedValue());
        self.rooted_prefix = self.values;
    }

    fn deinit(self: *OwnedArgList) void {
        const rt = self.rt orelse return;
        var index = self.rooted_prefix.len;
        while (index > 0) {
            index -= 1;
            self.values[index] = core.JSValue.undefinedValue();
        }
        self.rooted_prefix = self.values[0..0];
        self.root.deinit();
        if (self.heap_backed) rt.nativeAllocator().free(self.values);
        self.values = &.{};
        self.rt = null;
        self.heap_backed = false;
    }
};

const SyncInlineRoute = struct {
    invocation: *inline_calls.ActiveInvocation,
    target: inline_calls.InlineTarget,
};

/// Same execution authority: context, Realm global, and output.
pub inline fn machineMatches(machine: *const inline_calls.Machine, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) bool {
    return machine.ctx == ctx and machine.global == global and machine.output == output;
}

inline fn resolveSyncInlineRoute(
    route: *SyncInlineRoute,
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
) bool {
    const invocation = inline_calls.activeInvocation(ctx.runtime) orelse return false;
    if (!machineMatches(invocation.machine, ctx, output, global)) return false;
    route.invocation = invocation;
    return inline_calls.resolveInlineTargetInto(
        &route.target,
        global,
        this_value,
        func,
    );
}

/// The native-boundary run helpers below take the invocation and the
/// resolved target separately: `call_site.CallSite` keeps one immutable
/// target per site and selects the Machine per call.
/// `idle_machine`: the fence is an idle Machine (the resident host
/// invocation), so the scope skips the outer dispatch-state snapshot.
noinline fn runSyncInlineRouteMoved(
    comptime idle_machine: bool,
    invocation: *inline_calls.ActiveInvocation,
    target: *const inline_calls.InlineTarget,
    global: *core.Object,
    moved_values: []core.JSValue,
    out: *core.JSValue,
) HostError!void {
    var boundary = if (idle_machine)
        inline_calls.IdleBoundaryScope.init(invocation)
    else
        inline_calls.NativeBoundaryScope.init(invocation);
    boundary.push();
    errdefer boundary.deinit();

    _ = try invocation.machine.pushMovedCall(
        global,
        target,
        moved_values,
        .method,
        .native_boundary,
        0,
    );
    inline_calls.recordSameMachineSyncCall();
    try zjs_vm.runActiveInvocationUntilNativeBoundary(invocation, &boundary);
    boundary.finish();
    invocation.machine.vm.takeNativeReturnInto(out);
}

/// `lean`: the site's pre-built lean frame (`inline_calls.LeanFrame`), tried
/// first; a miss (reentrant site, budget, arena) takes the generic push.
pub inline fn runSyncInlineRouteCopiedArgs(
    comptime fixed_argc: ?usize,
    comptime idle_machine: bool,
    invocation: *inline_calls.ActiveInvocation,
    target: *const inline_calls.InlineTarget,
    global: *core.Object,
    this_value: *const core.JSValue,
    args: []const core.JSValue,
    lean: ?*inline_calls.LeanFrame,
    out: *core.JSValue,
) HostError!void {
    std.debug.assert(inline_calls.Machine.nativeBoundarySimpleEligible(target));
    var boundary = if (idle_machine)
        inline_calls.IdleBoundaryScope.init(invocation)
    else
        inline_calls.NativeBoundaryScope.init(invocation);
    boundary.push();
    errdefer boundary.deinit();

    const machine = invocation.machine;
    // Resident runtime pointer (one load) instead of machine -> ctx ->
    // runtime, which sits in front of the admission checks.
    const rt = machine.vm.rt;
    var lean_live: ?*inline_calls.LeanFrame = null;
    defer if (lean_live) |frame| {
        frame.in_use = false;
    };
    const entry = blk: {
        if (lean) |frame| {
            if (machine.pushLeanEntry(fixed_argc, rt, frame, this_value, args)) |entry| {
                lean_live = frame;
                break :blk entry;
            }
        }
        break :blk machine.tryPushNativeBoundaryCopiedArgsFast(rt, target, args) orelse
            try machine.pushNativeBoundaryCopiedArgs(global, target, args);
    };
    inline_calls.recordSameMachineSyncCall();
    try zjs_vm.runPushedEntryUntilNativeBoundary(invocation, &boundary, entry, target);
    boundary.finish();
    machine.vm.takeNativeReturnInto(out);
}

noinline fn runSyncInlineRouteMovedArgs(
    invocation: *inline_calls.ActiveInvocation,
    target: *const inline_calls.InlineTarget,
    global: *core.Object,
    args: []core.JSValue,
    out: *core.JSValue,
) HostError!void {
    std.debug.assert(inline_calls.Machine.nativeBoundarySimpleEligible(target));
    var boundary = inline_calls.NativeBoundaryScope.init(invocation);
    boundary.push();
    errdefer boundary.deinit();

    const machine = invocation.machine;
    const entry = machine.tryPushNativeBoundaryMovedArgsFast(
        machine.ctx.runtime,
        target,
        args,
    ) orelse try machine.pushNativeBoundaryMovedArgs(
        global,
        target,
        args,
    );
    inline_calls.recordSameMachineSyncCall();
    try zjs_vm.runPushedEntryUntilNativeBoundary(invocation, &boundary, entry, target);
    boundary.finish();
    machine.vm.takeNativeReturnInto(out);
}

pub noinline fn runSyncInlineRouteOwnedCopy(
    idle_machine: bool,
    invocation: *inline_calls.ActiveInvocation,
    target: *const inline_calls.InlineTarget,
    ctx: *core.JSContext,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    out: *core.JSValue,
) HostError!void {
    var owned_args = OwnedArgList{};
    try owned_args.init(ctx.runtime, this_value, func, args);
    defer owned_args.deinit();
    // One outlined copy owns the arg list. The idle vs active fence stays
    // specialized in `runSyncInlineRouteMoved`; a runtime branch here avoids
    // instantiating this helper twice for a comptime bool.
    if (idle_machine) {
        return runSyncInlineRouteMoved(true, invocation, target, global, owned_args.values, out);
    }
    return runSyncInlineRouteMoved(false, invocation, target, global, owned_args.values, out);
}

noinline fn runSyncInlineRouteOwnedArgsGeneral(
    invocation: *inline_calls.ActiveInvocation,
    target: *const inline_calls.InlineTarget,
    ctx: *core.JSContext,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []core.JSValue,
    out: *core.JSValue,
) HostError!void {
    std.debug.assert(!inline_calls.Machine.nativeBoundarySimpleEligible(target));
    var owned_args = OwnedArgList{};
    try owned_args.initTakeArgs(ctx.runtime, this_value, func, args);
    defer owned_args.deinit();
    return runSyncInlineRouteMoved(false, invocation, target, global, owned_args.values, out);
}

/// Copied-args prologue when `simple`, otherwise the owned-copy prologue.
/// `this_value` is the receiver cell the lean arm copies; the owned arm reads
/// that cell and `callee`.
pub inline fn runOnInvocation(
    comptime fixed_argc: ?usize,
    comptime idle_machine: bool,
    invocation: *inline_calls.ActiveInvocation,
    simple: bool,
    target: *const inline_calls.InlineTarget,
    ctx: *core.JSContext,
    global: *core.Object,
    this_value: *const core.JSValue,
    callee: *const core.JSValue,
    args: []const core.JSValue,
    lean: ?*inline_calls.LeanFrame,
    out: *core.JSValue,
) HostError!void {
    if (simple) {
        return runSyncInlineRouteCopiedArgs(fixed_argc, idle_machine, invocation, target, global, this_value, args, lean, out);
    }
    return runSyncInlineRouteOwnedCopy(idle_machine, invocation, target, ctx, global, this_value.*, callee.*, args, out);
}

/// Explicit synchronous internal call boundary for native algorithms that
/// must receive a bytecode callback result before they can finish. Inputs must
/// remain rooted for this call (native invocation arguments and algorithm
/// OwnedArgList values already satisfy that contract).
///
/// Eligible same-context, same-Realm normal bytecode targets push an Entry on
/// the active Machine and stop at `.native_boundary`. Every other target
/// unconditionally retains the authoritative JS_Call-shaped root path.
pub inline fn callValueOrBytecodeSyncInternal(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    // One call-entry poll regardless of whether routing selects the resident
    // Machine or the authoritative fallback.
    try exception_ops.pollInterrupt(ctx, global);

    var route: SyncInlineRoute = undefined;
    if (!resolveSyncInlineRoute(&route, ctx, output, global, this_value, func))
        return callValueOrBytecodeDispatchAfterInterruptPoll(
            ctx,
            output,
            global,
            this_value,
            func,
            args,
            caller_function,
            caller_frame,
            .copy,
        );

    var out: core.JSValue = undefined;
    try runOnInvocation(
        null,
        false,
        route.invocation,
        inline_calls.Machine.nativeBoundarySimpleEligible(&route.target),
        &route.target,
        ctx,
        global,
        &route.target.this_value,
        &route.target.callable,
        args,
        null,
        &out,
    );
    return out;
}

/// Loop-callback adapter for the same explicit synchronous contract. Keeping
/// target resolution and the fallback union out of the surrounding native
/// algorithm prevents one callback call site from extending its spill set
/// across the algorithm's whole iteration body. Apply's single terminal call
/// retains the inline adapter above; callback cohorts deliberately use this
/// outlined seam.
pub noinline fn callValueOrBytecodeSyncInternalOutlined(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    return callValueOrBytecodeSyncInternal(
        ctx,
        output,
        global,
        this_value,
        func,
        args,
        caller_function,
        caller_frame,
    );
}

/// Same synchronous routing contract as `callValueOrBytecodeSyncInternal`,
/// but the caller supplies a rooted, owned argument list. Simple eligible
/// targets move the arguments directly into the writable frame while
/// receiver/callable remain borrowed from the still-live native algorithm.
/// Other eligible bytecode layouts build the full owned transaction on their
/// cold path. Fallback leaves every argument owned by the caller.
pub inline fn callOwnedArgsValueOrBytecodeSyncInternal(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    try exception_ops.pollInterrupt(ctx, global);

    var route: SyncInlineRoute = undefined;
    if (!resolveSyncInlineRoute(&route, ctx, output, global, this_value, func))
        return callValueOrBytecodeDispatchAfterInterruptPoll(
            ctx,
            output,
            global,
            this_value,
            func,
            args,
            caller_function,
            caller_frame,
            .copy,
        );
    var out: core.JSValue = undefined;
    if (inline_calls.Machine.nativeBoundarySimpleEligible(&route.target)) {
        try runSyncInlineRouteMovedArgs(route.invocation, &route.target, global, args, &out);
        return out;
    }
    try runSyncInlineRouteOwnedArgsGeneral(
        route.invocation,
        &route.target,
        ctx,
        global,
        this_value,
        func,
        args,
        &out,
    );
    return out;
}

const VmNativeCallableDispatch = union(enum) {
    bound_function,
    resolved_record: core.Object.NativeCallTarget,
    native_ref: core.function.NativeBuiltinRef,
    internal: core.host_function.InternalCallableTag,
    no_record,
};

fn vmNativeCallableDispatch(function_object: *core.Object) VmNativeCallableDispatch {
    return switch (function_object.class_id) {
        core.class.ids.bound_function => .bound_function,
        core.class.ids.async_function_resolve,
        core.class.ids.async_function_reject,
        => .{ .internal = .async_function_resume },
        core.class.ids.c_function => blk: {
            if (function_object.nativeCallTarget()) |target| {
                break :blk .{ .resolved_record = target };
            }
            if (core.function.decodeNativeBuiltinId(function_object.nativeFunctionId())) |native_ref| {
                break :blk .{ .native_ref = native_ref };
            }
            const tag = function_object.internalCallableTag();
            if (tag != .none) break :blk .{ .internal = tag };
            break :blk .no_record;
        },
        core.class.ids.c_function_data => blk: {
            if (core.function.decodeNativeBuiltinId(function_object.nativeFunctionId())) |native_ref| {
                break :blk .{ .native_ref = native_ref };
            }
            const tag = function_object.internalCallableTag();
            if (tag != .none) break :blk .{ .internal = tag };
            break :blk .no_record;
        },
        else => .no_record,
    };
}

pub fn callInternalCallableByTag(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    tag: core.host_function.InternalCallableTag,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    return switch (tag) {
        .none => null,
        .promise_resolving => try promise_ops.promiseResolvingFunctionCall(ctx, output, global, function_object, args, caller_function, caller_frame),
        .promise_capability_executor => try promise_ops.promiseCapabilityExecutorCall(ctx, function_object, args),
        .promise_combinator_element => try promise_ops.promiseCombinatorElementCall(ctx, output, global, function_object, args, caller_function, caller_frame),
        .promise_finally_callback => try promise_ops.promiseFinallyCallbackCall(ctx, output, global, function_object, args, caller_function, caller_frame),
        .async_function_resume => try promise_ops.asyncFunctionResumeCallbackCall(ctx, output, global, function_object, args),
        .async_generator_resolve => try promise_ops.asyncGeneratorResolveFunctionCall(ctx, output, global, function_object, args),
        .async_from_sync_iterator_close_wrap => try promise_ops.asyncFromSyncIteratorCloseWrapCall(ctx, output, global, function_object, args),
        .async_from_sync_iterator_unwrap => try promise_ops.asyncFromSyncIteratorUnwrapCall(ctx, global, function_object, args),
        .async_disposable_stack_continuation => try disposable_ops.asyncDisposableStackContinuationCall(ctx, output, global, function_object, args, caller_function, caller_frame),
        .array_from_async_continuation => try array_ops.arrayFromAsyncContinuationCall(ctx, output, global, function_object, args, caller_function, caller_frame),
        .throw_type_error_intrinsic => @as(?core.JSValue, try throwTypeErrorIntrinsic(ctx, global)),
    };
}

noinline fn callRawFunctionBytecode(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    argv: ArgvMode,
) HostError!core.JSValue {
    // The dispatcher already required the function_bytecode tag. A header
    // that does not decode is a zero payload, not a user type mismatch.
    _ = functionBytecodeFromValue(func) orelse return error.InvalidBytecode;
    // Class direct-call rejection is the bytecode entry OP_check_ctor, matching
    // qjs JS_CallInternal. Ordinary functions use this same undefined-new.target
    // path; no class-syntax fact is carried in the FunctionBytecode.
    return callFunctionBytecodeModeStateAfterInterruptPoll(
        ctx,
        func,
        func,
        this_value,
        args,
        &.{},
        output,
        global,
        .{ .copy_argv = argv == .copy },
    );
}

noinline fn callFunctionObjectBytecode(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    argv: ArgvMode,
) HostError!core.JSValue {
    // The dispatcher already selected a bytecode function class.
    const function_value = function_object.functionBytecode() orelse return error.InvalidBytecode;
    // functionBytecode() returns JSValue.functionBytecode of a live header.
    _ = functionBytecodeFromValue(function_value) orelse unreachable;
    // Bound/Proxy dispatch has already recursed to this final bytecode arm.
    // The helper keeps this caller view through interrupt/stack preflight;
    // zjs_vm selects the FB Realm only after those checks.
    // OP_check_ctor owns class direct-call rejection in the function realm.
    return callFunctionBytecodeModeStateAfterInterruptPoll(
        ctx,
        function_value,
        func,
        this_value,
        args,
        function_object.functionCaptures(),
        output,
        global,
        .{ .copy_argv = argv == .copy },
    );
}

noinline fn callNativeCallableObject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    switch (vmNativeCallableDispatch(function_object)) {
        .bound_function => return callBoundFunction(ctx, output, global, function_object, args, caller_function, caller_frame),
        .resolved_record => |target| {
            try builtin_dispatch.preflightCFunctionCall(ctx, global, function_object, target.entry.arity);
            const view = try builtin_dispatch.CallRealmView.caller(target.realm);
            const native_result = builtin_dispatch.callInternalRecordDirectInRealm(
                view,
                output,
                function_object,
                this_value,
                target.entry,
                args,
                caller_function,
                caller_frame,
            ) catch |err| {
                try builtin_dispatch.materializeRuntimeError(view.realm, view.global, err);
                return err;
            };
            return native_result;
        },
        .native_ref => |native_ref| {
            const native_result = callNativeBuiltinRecordForVm(ctx, output, global, this_value, function_object, native_ref, args, caller_function, caller_frame) catch |err| {
                const view = try builtin_dispatch.finalCallableRealmView(ctx, function_object);
                try builtin_dispatch.materializeRuntimeError(view.realm, view.global, err);
                return err;
            };
            if (native_result) |value| return value;
        },
        .internal => |tag| {
            const view = try builtin_dispatch.finalCallableRealmView(ctx, function_object);
            if (try callInternalCallableByTag(view.realm, output, view.global, function_object, tag, args, caller_function, caller_frame)) |value| return value;
        },
        .no_record => {},
    }
    const view = try builtin_dispatch.finalCallableRealmView(ctx, function_object);
    return callNativeCallableWithoutRecord(
        view.realm,
        output,
        view.global,
        this_value,
        func,
        function_object,
        args,
        caller_function,
        caller_frame,
    ) catch |err| {
        try builtin_dispatch.materializeRuntimeError(view.realm, view.global, err);
        return err;
    };
}

pub fn callValueOrBytecodeDispatch(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    argv: ArgvMode,
) HostError!core.JSValue {
    try exception_ops.pollInterrupt(ctx, global);
    return callValueOrBytecodeDispatchAfterInterruptPoll(ctx, output, global, this_value, func, args, caller_function, caller_frame, argv);
}

pub fn callValueOrBytecodeDispatchAfterInterruptPoll(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    argv: ArgvMode,
) HostError!core.JSValue {
    ctx.runtime.assertExecutionAllowed();
    if (func.is(.function_bytecode)) {
        return callRawFunctionBytecode(ctx, output, global, this_value, func, args, argv);
    }
    if (object_ops.objectFromValue(func)) |object| {
        switch (object.class_id) {
            core.class.ids.bytecode_function,
            core.class.ids.generator_function,
            core.class.ids.async_function,
            core.class.ids.async_generator_function,
            => {
                return callFunctionObjectBytecode(ctx, output, global, this_value, func, object, args, argv);
            },
            core.class.ids.proxy => {
                if (object.proxyTarget() != null and object_ops.proxyTargetIsCallable(func)) {
                    return object_ops.callProxyApply(ctx, output, global, object, this_value, args, caller_function, caller_frame);
                }
            },
            core.class.ids.c_function,
            core.class.ids.c_function_data,
            core.class.ids.async_function_resolve,
            core.class.ids.async_function_reject,
            core.class.ids.bound_function,
            => return callNativeCallableObject(ctx, output, global, this_value, func, object, args, caller_function, caller_frame),
            else => {},
        }
    }
    return exception_ops.throwTypeErrorMessage(ctx, global, "not a function");
}

/// Native callables that carry no call record or internal-callable tag. A
/// standard constructor called without `new` dispatches on its
/// `NativeConstructorKind`; kept out of the normal call frame like QuickJS's
/// class-specific call functions.
noinline fn callNativeCallableWithoutRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    switch (function_object.nativeConstructorKind()) {
        .none => {},
        .array => return constructArrayNativeRecordVm(ctx, output, global, function_object, array_ops.arrayPrototypeFromGlobal(ctx.runtime, global), args, caller_function, caller_frame),
        .bigint => return builtin_glue.bigIntFunctionCall(ctx, output, global, args),
        .number => return builtin_glue.numberFunctionCall(ctx, output, global, args),
        .function => return function_ops.constructDynamicFunctionFromSource(ctx, output, global, func, func, args, .normal, caller_function, caller_frame),
        .async_function => return function_ops.constructDynamicFunctionFromSource(ctx, output, global, func, func, args, .async_function, caller_function, caller_frame),
        .generator_function => return function_ops.constructDynamicFunctionFromSource(ctx, output, global, func, func, args, .generator, caller_function, caller_frame),
        .async_generator_function => return function_ops.constructDynamicFunctionFromSource(ctx, output, global, func, func, args, .async_generator, caller_function, caller_frame),
        .aggregate_error => {
            const prototype = try object_ops.constructorPrototypeObject(func);
            return try object_ops.aggregateErrorConstructWithPrototype(ctx, output, global, prototype, args, caller_function, caller_frame);
        },
        .suppressed_error => {
            const prototype = try object_ops.constructorPrototypeObject(func);
            return try object_ops.suppressedErrorConstructWithPrototype(ctx, output, global, prototype, args, caller_function, caller_frame);
        },
        .error_,
        .eval_error,
        .range_error,
        .reference_error,
        .syntax_error,
        .type_error,
        .uri_error,
        .internal_error,
        => {
            const prototype = try object_ops.constructorPrototypeObject(func);
            return try object_ops.errorConstructWithPrototype(ctx, output, global, prototype, args, caller_function, caller_frame);
        },
        // Every other standard constructor without a call record (Map(),
        // Promise(), DisposableStack(), ...) requires `new`.
        else => return exception_ops.throwTypeErrorMessage(ctx, global, "must be called with new"),
    }
    if (try call_mod.callNativeFunctionRecord(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
    return exception_ops.throwTypeErrorMessage(ctx, global, "not a function");
}

test "callValueOrBytecodeRoot roots inline args before bytecode frame allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try zjs_vm.contextGlobal(ctx);

    const fb = try bytecode.FunctionBytecode.createFixture(rt, .{
        .realm = ctx,
        .var_count = 1,
        .byte_code = &.{op.return_undef},
    });
    fb.allVarDefs()[0] = bytecode.function_bytecode.BytecodeVarDef.init(.{
        .var_name = core.atom.null_atom,
    });
    fb.publishFixtureNoFail(rt);

    const func_value = core.JSValue.functionBytecode(&fb.header);

    const arg_atom = try rt.atoms.newValueSymbol("gc-call-value-inline-arg-root");
    const arg_value = try rt.symbolValue(arg_atom);
    const args = [_]core.JSValue{arg_value};

    const Trigger = struct {
        rt: *core.JSRuntime,
        atom_id: core.Atom,
        saw_arg: bool = false,
        trace_failed: bool = false,

        fn trigger(context: ?*anyopaque, size: usize) void {
            _ = size;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = self.rt.collectFull() catch {
                self.trace_failed = true;
                return;
            };
            self.saw_arg = self.rt.atoms.name(self.atom_id) != null;
        }
    };

    var trigger = Trigger{
        .rt = rt,
        .atom_id = arg_atom,
    };
    const saved_trigger_fn = rt.gc.heap_budget.installProbe(.{ .run = Trigger.trigger, .context = &trigger });
    defer rt.gc.heap_budget.restoreProbe(saved_trigger_fn);

    _ = try callValueOrBytecodeRoot(
        ctx,
        null,
        global,
        core.JSValue.undefinedValue(),
        func_value,
        &args,
        null,
        null,
    );
    rt.gc.heap_budget.restoreProbe(saved_trigger_fn);

    try std.testing.expect(!trigger.trace_failed);
    try std.testing.expect(trigger.saw_arg);

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(arg_atom) == null);
}

const disposable_ops = @import("disposable_ops.zig");

pub const RegExpCapture = struct {
    start: usize,
    len: usize,
    undefined: bool = false,
    name: ?[]const u8 = null,
};

pub fn functionHasInstanceCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const value = value_ops.argOrUndefined(args, 0);
    return core.JSValue.boolean(try ordinaryHasInstance(ctx, output, global, this_value, value, caller_function, caller_frame));
}

pub fn ordinaryHasInstance(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!bool {
    if (!isCallableValue(constructor_value)) return false;
    if (object_ops.objectFromValue(constructor_value)) |constructor_object| {
        if (constructor_object.class_id == core.class.ids.bound_function) {
            // Step 2: InstanceofOperator(O, BC), which consults BC's own
            // @@hasInstance. A bound chain recurses once per level.
            if (ctx.runtime.stack.checkNativeOverflow(0)) return error.StackOverflow;
            const target = constructor_object.boundTarget() orelse return error.TypeError;
            return instanceofValue(ctx, output, global, value, target, caller_function, caller_frame);
        }
    }
    const object = object_ops.objectFromValue(value) orelse return false;
    // Fast `.prototype` read: a class constructor (and any non-proxy callable)
    // carries `prototype` as an own data property, so read it directly without
    // building/destroying a Descriptor (qjs reads JS_ATOM_prototype once,
    // quickjs.c). A normal function's lazy-autoinit prototype, an
    // inherited/accessor prototype, or a proxy returns null here and falls to
    // the generic getValueProperty (which materializes / traps correctly).
    const proto_value = blk: {
        if (object_ops.objectFromValue(constructor_value)) |co| {
            if (!co.isProxy()) {
                if (co.getOwnDataPropertyValue(core.atom.ids.prototype)) |v| break :blk v;
            }
        }
        break :blk try object_ops.getValueProperty(ctx, output, global, constructor_value, core.atom.ids.prototype, caller_function, caller_frame);
    };
    const prototype = object_ops.objectFromValue(proto_value) orelse {
        _ = try exception_ops.throwTypeErrorMessage(ctx, global, "operand 'prototype' property is not an object");
        unreachable;
    };
    // Walk the prototype chain. The non-proxy step IS object.getPrototype() (a
    // direct shape.proto deref); inline it and only call the trap-aware step for
    // proxies / the throw-type-error intrinsic, mirroring qjs's p->shape->proto
    // walk that bypasses [[GetPrototypeOf]] for ordinary
    // objects.
    // Only a Proxy can make the chain endless; its steps poll the interrupt
    // handler (contract C8).
    var current: ?*core.Object = object;
    while (current) |candidate| {
        const next = if (candidate.isProxy() or object_ops.isThrowTypeErrorIntrinsicObject(candidate)) step: {
            try exception_ops.pollNativeLoop(ctx, global);
            break :step try object_ops.objectGetPrototypeOfStep(ctx, output, global, candidate, caller_function, caller_frame);
        } else candidate.getPrototype();
        const parent = next orelse return false;
        if (parent == prototype) return true;
        current = parent;
    }
    return false;
}

/// Function.prototype.call body shared by the native-record owner and the
/// legacy name-only callable path. Keeping the VM caller pair preserves
/// nested callsite/property-access context while the native record contributes
/// the surrounding `call (native)` frame.
pub fn functionCallCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    const this_arg = value_ops.argOrUndefined(args, 0);
    const call_args = if (args.len >= 1) args[1..] else &.{};
    // qjs `js_function_call` forwards `argv + 1` straight to `JS_Call`. The
    // outer native call keeps `this_value` and `args` rooted for this complete
    // synchronous invocation, so rebuilding the defensive eight-slot argument
    // copy/root frame here is redundant.
    return callValueOrBytecodeRootPreRooted(ctx, output, global, this_arg, this_value, call_args, caller_function, caller_frame);
}

/// Function.prototype.apply body shared by the native-record owner and the
/// legacy name-only callable path. Flat mirror of `js_function_apply`
/// (qjs:41213): check_function -> read this_arg/array_arg -> null/undefined
/// short-circuit -> build_arg_list -> JS_Call -> free_arg_list. Callable
/// classification is one `isCallableValue` probe (qjs `check_function`
/// resolves before argv is read), with the throw outlined; bound/Proxy
/// callables share the same call leg as plain functions.
pub fn functionApplyCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    // qjs:41221 `check_function(ctx, this_val)` precedes reading argv.
    if (!isCallableValue(this_value)) return throwApplyTypeError(ctx, global, "not a function");
    const this_arg = value_ops.argOrUndefined(args, 0);
    const arg_array = value_ops.argOrUndefined(args, 1);
    // qjs:41224: undefined/null array_arg calls the target with no arguments.
    if (arg_array.is(.null_value) or arg_array.is(.undefined_value)) {
        return callValueOrBytecodeSyncInternal(ctx, output, global, this_arg, this_value, &.{}, caller_function, caller_frame);
    }
    return functionApplyArrayLike(
        ctx,
        output,
        global,
        this_arg,
        this_value,
        arg_array,
        caller_function,
        caller_frame,
    );
}

/// Outlined cold throw for both apply TypeError arms: qjs `check_function`
/// "not a function" for the non-callable receiver, `build_arg_list`
/// "not an object" for the non-object argument list.
noinline fn throwApplyTypeError(ctx: *core.JSContext, global: *core.Object, message: []const u8) HostError!core.JSValue {
    const error_value = try exception_ops.createNamedError(ctx, global, "TypeError", message);
    _ = ctx.throwValue(error_value);
    return error.JSException;
}

/// Observable CreateListFromArrayLike materialization (qjs `build_arg_list`,
/// qjs:41159) and its owned argument transaction are needed only when apply
/// receives a non-null list. Keep that large cold state outlined from the
/// flat record body -- the slow leg lives behind this call boundary.
noinline fn functionApplyArrayLike(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_arg: core.JSValue,
    this_value: core.JSValue,
    arg_array: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    // qjs build_arg_list (qjs:41167) rejects non-object argument lists.
    if (!arg_array.is(.object)) return throwApplyTypeError(ctx, global, "not an object");
    var owned_args = try array_ops.ownedArgsFromArrayLike(
        ctx,
        output,
        global,
        arg_array,
        caller_function,
        caller_frame,
    );
    defer owned_args.deinit();
    var apply_args = owned_args.values;
    if (apply_args.len == 0) {
        return callValueOrBytecodeSyncInternal(ctx, output, global, this_arg, this_value, &.{}, caller_function, caller_frame);
    }
    var apply_args_root = array_ops.ValueSliceRoot{};
    apply_args_root.init(ctx.runtime, &apply_args);
    defer apply_args_root.deinit();
    return callOwnedArgsValueOrBytecodeSyncInternal(
        ctx,
        output,
        global,
        this_arg,
        this_value,
        apply_args,
        caller_function,
        caller_frame,
    );
}

pub fn constructValueOrBytecode(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return constructValueOrBytecodeWithNewTarget(ctx, output, global, func, args, caller_function, caller_frame, func);
}

/// `Object`'s own record id: `new Object()` with `new.target === Object`
/// runs the call body (ToObject of the argument).
const object_construct_id: u32 = @intFromEnum(core.host_function.builtin_method_ids.object.ConstructorMethod.call);

// `new Array(...)` / `Array(...)` route through the Array construct record. The
// Array constructor object carries no native id (its species recognition and
// the call-as-function fast paths above stay name + `arrayBuiltinMarker`
// based), so these sites pass this explicit ref to `callConstructRecord`; the
// record's construct branch runs `constructConstructorWithPrototype` (the
// single-number-length vs element-list semantics) with the threaded prototype.
const array_construct_ref = core.function.NativeBuiltinRef{
    .domain = .array,
    .id = @intFromEnum(core.host_function.builtin_method_ids.array.ConstructorMethod.construct),
};

/// Route `(args, prototype)` through the Array construct record, mapping the
/// constructor body's `RangeError` (invalid `new Array(length)`) to the
/// engine's thrown RangeError exactly as the retired direct calls did.
pub fn constructArrayNativeRecordVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: ?*core.Object,
    prototype: ?*core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    return (builtin_dispatch.callConstructRecord(ctx, output, global, function_object, array_construct_ref, prototype, args, caller_function, caller_frame) catch |err| switch (err) {
        error.RangeError => {
            if (exception_ops.pendingExceptionMatchesError(ctx, err)) return err;
            return exception_ops.throwRangeErrorMessage(ctx, global, "invalid array length");
        },
        else => return err,
    }) orelse error.TypeError;
}

pub inline fn constructNativeInScope(
    comptime body: anytype,
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    native_ref: core.function.NativeBuiltinRef,
    new_target: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    try builtin_dispatch.preflightInternalRecordCFunction(ctx, global, function_object, native_ref);
    var native_scope = builtin_dispatch.NativeBacktraceScope.init(ctx, function_object);
    native_scope.push();
    defer native_scope.deinit();
    return body(ctx, output, global, function_object, native_ref, new_target, args, caller_function, caller_frame) catch |err| {
        try builtin_dispatch.materializeRuntimeError(ctx, global, err);
        return err;
    };
}

pub fn constructStringBuiltinNativeInScope(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    native_ref: core.function.NativeBuiltinRef,
    new_target: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    // §22.1.1.1: ToString(value) before GetPrototypeFromConstructor.
    var string_value = if (args.len == 0)
        try value_ops.createStringValue(ctx.runtime, "")
    else
        try string_ops.toStringForAnnexB(ctx, output, global, args[0], caller_function, caller_frame);
    var string_root = core.runtime.rootValues(.{&string_value});
    string_root.activate(ctx.runtime);
    defer string_root.deactivate(ctx.runtime);
    const prototype = try object_ops.reflectConstructPrototypeVm(ctx, output, global, "String", new_target, caller_function, caller_frame);
    return builtin_dispatch.callConstructRecordInNativeScope(ctx, output, global, function_object, native_ref, prototype, &.{string_value}, caller_function, caller_frame);
}

pub fn constructDateBuiltinNativeInScope(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    native_ref: core.function.NativeBuiltinRef,
    new_target: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    // Every later argument is read after earlier ones ran JS (valueOf,
    // toString) that may collect. The caller's slice is not
    // necessarily a root: keep it, the constructor and new.target alive.
    const operands = [_]core.JSValue{ function_object.value(), new_target };
    const slices = [_]core.runtime.ValueRootSlice{ .{ .borrowed = &operands }, .{ .borrowed = args } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    var coerced_storage: [7]core.JSValue = undefined;
    var coerced: []core.JSValue = coerced_storage[0..0];
    var date_args: []const core.JSValue = args;
    if (args.len == 1) {
        if (object_ops.objectFromValue(args[0])) |object| {
            if (object.class_id == core.class.ids.date) {
                coerced_storage[0] = try date_ops.callDateBody(ctx, args[0], .get_time, &.{});
            } else {
                const primitive = try value_ops.toPrimitiveForAddition(ctx, output, global, args[0]);
                if (primitive.isString()) {
                    coerced_storage[0] = primitive;
                } else {
                    if (primitive.isBigInt()) return @as(?core.JSValue, try exception_ops.throwTypeErrorMessage(ctx, global, "cannot convert bigint to number"));
                    coerced_storage[0] = try value_ops.toNumberValue(ctx.runtime, primitive);
                }
            }
            coerced = coerced_storage[0..1];
            date_args = coerced;
        } else if (!args[0].isString()) {
            if (args[0].isBigInt()) return @as(?core.JSValue, try exception_ops.throwTypeErrorMessage(ctx, global, "cannot convert bigint to number"));
            coerced_storage[0] = try value_ops.toNumberValue(ctx.runtime, args[0]);
            coerced = coerced_storage[0..1];
            date_args = coerced;
        }
    } else if (args.len >= 2) {
        var coerced_len: usize = 0;
        while (coerced_len < args.len and coerced_len < coerced_storage.len) : (coerced_len += 1) {
            coerced_storage[coerced_len] = try value_ops.toNumberRejectingBigInt(ctx, output, global, args[coerced_len]);
            coerced = coerced_storage[0 .. coerced_len + 1];
        }
        date_args = coerced;
    }
    // §21.4.2.1: the arguments are converted before OrdinaryCreateFromConstructor
    // reads `newTarget.prototype`, whose getter may collect.
    const coerced_slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = coerced }};
    var coerced_roots = core.runtime.ValueRootFrame{ .slices = &coerced_slices };
    coerced_roots.activate(ctx.runtime);
    defer coerced_roots.deactivate(ctx.runtime);
    const prototype = try object_ops.reflectConstructPrototypeVm(ctx, output, global, "Date", new_target, caller_function, caller_frame);
    return builtin_dispatch.callConstructRecordInNativeScope(ctx, output, global, function_object, native_ref, prototype, date_args, caller_function, caller_frame);
}

pub fn constructValueOrBytecodeWithNewTarget(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    new_target: core.JSValue,
) HostError!core.JSValue {
    return constructValueOrBytecodeWithNewTargetMode(
        ctx,
        output,
        global,
        func,
        args,
        caller_function,
        caller_frame,
        new_target,
        .copy,
    );
}

/// OP_call_constructor/super opcode entry. Its argv window is VM-owned and
/// follows QuickJS flags=0; public/algorithmic construction uses the wrapper
/// above and preserves JS_CALL_FLAG_COPY_ARGV.
pub fn constructValueOrBytecodeWithNewTargetInternal(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    new_target: core.JSValue,
) HostError!core.JSValue {
    return constructValueOrBytecodeWithNewTargetMode(
        ctx,
        output,
        global,
        func,
        args,
        caller_function,
        caller_frame,
        new_target,
        .borrow,
    );
}

/// Same-Machine constructor admission record for OP_call_constructor.
/// Resolution is deliberately narrower than general [[Construct]]: only a
/// same-Realm direct ordinary or derived bytecode function enters. Base class,
/// proxy, bound, native, cross-Realm, and differing-new-target construction
/// retain the authoritative recursive adapter below.
pub const SameMachineConstructorTarget = struct {
    resolved: inline_calls.ResolvedInlineFunction,
    function_object: *core.Object,
    /// Resolution-time image of `new_target.sameValue(func)`. The direct
    /// `new F(...)` admission gate already proved it, and the spread resolver
    /// computes it while classifying the differing-new-target Realm — so the
    /// prepare path reads this bit instead of re-running the outline
    /// sameValue per `new` (qjs holds new_target in a JS_CallInternal
    /// register and never re-compares it, quickjs.c).
    new_target_is_func: bool,
};

/// Own `.prototype` data slot without materializing auto_init or taking the
/// outline `getOwnConstructorPrototypeObject` (9% of N0). First construct of
/// a function still falls through to the full helper to publish the lazy slot.
fn ownConstructorPrototypeData(function_object: *core.Object) ?*core.Object {
    if (function_object.hasExoticMethods()) return null;
    const index = function_object.findProperty(core.atom.ids.prototype) orelse return null;
    const flags = function_object.propFlagsAt(index);
    if (flags.deleted or flags.kind != .data) return null;
    const stored = function_object.asDataAt(index) orelse return null;
    return object_ops.objectFromValue(stored);
}

pub fn resolveSameMachineConstructor(
    global: *core.Object,
    func: core.JSValue,
    new_target: core.JSValue,
) ?SameMachineConstructorTarget {
    // Direct `new F(...)` emits `dup`, so new_target and func are the same
    // object. Admission only needs identity. Generic SameValue (NaN/±0/string)
    // is an outline bl and was 4% of N0 — qjs never re-compares here
    // (quickjs.c holds new_target in a register).
    if (!new_target.same(func)) return null;
    const resolved = inline_calls.resolveInlineDirectConstructorFunction(global, func) orelse return null;
    if (!resolved.fb.hasPrototype()) return null;
    const function_object = object_ops.plainBytecodeFunctionObjectFromValue(func) orelse return null;
    if (!isConstructibleBytecodeFunctionObject(function_object, resolved.fb)) return null;
    return .{
        .resolved = resolved,
        .function_object = function_object,
        .new_target_is_func = true,
    };
}

/// OP_apply(1) admission. Spread construction has an owned new-target operand,
/// so same-Realm `super(...args)` may preserve a differing new.target without
/// borrowing it from the caller frame. Cross-Realm targets remain execution
/// roots until Entry carries an explicit Realm/global binding.
pub fn resolveSameMachineSpreadConstructor(
    global: *core.Object,
    func: core.JSValue,
    new_target: core.JSValue,
) ?SameMachineConstructorTarget {
    const resolved = inline_calls.resolveInlineSpreadConstructorFunction(global, func) orelse return null;
    if (!resolved.fb.hasPrototype()) return null;
    const function_object = object_ops.plainBytecodeFunctionObjectFromValue(func) orelse return null;
    if (!isConstructibleBytecodeFunctionObject(function_object, resolved.fb)) return null;
    const new_target_is_func = new_target.same(func);
    if (!new_target_is_func) {
        // `callableObjectFromValue` is the native/bound-call adapter and
        // deliberately excludes the bytecode-function class. A super-call's
        // differing new.target is normally precisely that class, so inspect
        // the general object and use its authoritative FunctionRealm instead.
        const new_target_object = object_ops.objectFromValue(new_target) orelse return null;
        const new_target_global = object_ops.objectRealmGlobal(new_target_object) orelse return null;
        if (new_target_global != global) return null;
    }
    return .{
        .resolved = resolved,
        .function_object = function_object,
        .new_target_is_func = new_target_is_func,
    };
}

/// Continue an admitted constructor after OP_call_constructor has paid the
/// outer JS_CallConstructorInternal interrupt poll. Creates the eager
/// instance (owned) for a same-Machine bytecode frame. Derived entry is handled
/// separately by the opcode adapter. No second poll follows instance creation:
/// the caller's entry poll is the only one per `new`.
pub fn prepareSameMachineConstructorAfterFirstPoll(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    func: core.JSValue,
    new_target: core.JSValue,
    target: *const SameMachineConstructorTarget,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    std.debug.assert(!target.resolved.fb.isDerivedClassConstructor());
    if (target.new_target_is_func) {
        // Direct route: resolution proved new_target == func, so skip
        // createBytecodeConstructorInstance's per-call sameValue re-check
        // and take the materialized-`.prototype` data read (the first
        // construct materializes the lazy auto_init slot; see
        // createBytecodeConstructorInstance). A prototype miss — e.g.
        // `F.prototype = 42` — keeps the authoritative
        // createConstructorInstance fallback, mirroring qjs
        // js_create_from_ctor's non-object-prototype arm.
        if (ownConstructorPrototypeData(target.function_object) orelse
            try target.function_object.getOwnConstructorPrototypeObject(ctx.runtime)) |prototype|
        {
            return try createProfiledConstructorInstance(ctx.runtime, prototype, target.resolved.fb);
        }
        return try createConstructorInstance(
            ctx,
            output,
            global,
            new_target,
            caller_function,
            caller_frame,
        );
    }
    return try createBytecodeConstructorInstance(
        ctx,
        output,
        global,
        func,
        target.function_object,
        new_target,
        caller_function,
        caller_frame,
    );
}

/// Object result replaces the allocated instance; a non-object result returns it.
inline fn constructorResult(result: core.JSValue, instance: core.JSValue) core.JSValue {
    if (result.is(.object)) return result;
    return instance;
}

/// Run a bytecode constructor body and apply `constructorResult`.
/// `noteConstructorAllocation` stays with the function-object caller: the raw
/// function-bytecode arm and host constructors do not record that allocation.
inline fn constructBytecodeBody(
    ctx: *core.JSContext,
    func: core.JSValue,
    current_function_value: core.JSValue,
    instance: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const *core.VarRef,
    output: ?*std.Io.Writer,
    global: *core.Object,
    new_target_value: core.JSValue,
    argv: ArgvMode,
) HostError!core.JSValue {
    const result = try callFunctionBytecodeConstruct(ctx, func, current_function_value, instance, args, var_refs, output, global, new_target_value, argv);
    return constructorResult(result, instance);
}

/// Construct an ordinary (non-native) bytecode function object. qjs
/// JS_CallConstructorInternal dispatches construction on the function's class,
/// not its name — a bytecode function body is never a native builtin — so this
/// is reached WITHOUT the builtin-name string-comparison dispatch. A derived
/// class constructor allocates no instance (`this` stays TDZ until super());
/// base/ordinary constructors get the eager js_create_from_ctor instance, then
/// the simple-field fast path (this.f = arg patterns) or the full body.
fn constructOrdinaryBytecodeFunctionObject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    func: core.JSValue,
    function_object: *core.Object,
    function_value: core.JSValue,
    fb: *const bytecode.FunctionBytecode,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    new_target: core.JSValue,
    argv: ArgvMode,
) HostError!core.JSValue {
    const function_global = object_ops.objectRealmGlobal(function_object) orelse global;
    if (fb.isDerivedClassConstructor()) {
        return try callFunctionBytecodeConstruct(ctx, function_value, func, core.JSValue.uninitialized(), args, function_object.functionCaptures(), output, function_global, new_target, argv);
    }
    const instance = try createBytecodeConstructorInstance(ctx, output, global, func, function_object, new_target, caller_function, caller_frame);
    defer noteConstructorAllocation(fb, instance);
    return constructBytecodeBody(ctx, function_value, func, instance, args, function_object.functionCaptures(), output, function_global, new_target, argv);
}

fn constructValueOrBytecodeWithNewTargetMode(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    new_target: core.JSValue,
    argv: ArgvMode,
) HostError!core.JSValue {
    // QuickJS JS_CallConstructorInternal polls before proxy/bound dispatch and
    // before testing constructibility. Recursive proxy/bound forwarding enters
    // this wrapper again, so every semantic constructor entry charges the
    // caller Realm exactly once.
    try exception_ops.pollInterrupt(ctx, global);
    return constructValueOrBytecodeWithNewTargetAfterInterruptPoll(ctx, output, global, func, args, caller_function, caller_frame, new_target, argv);
}

fn constructValueOrBytecodeWithNewTargetAfterInterruptPoll(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    new_target: core.JSValue,
    argv: ArgvMode,
) HostError!core.JSValue {
    if (object_ops.callableObjectFromValue(func)) |function_object| {
        if (function_object.class_id == core.class.ids.c_function and isConstructorLike(func)) {
            // Rejecting a non-constructor stays in the caller environment.
            // Like V8's InvokeFunctionWithNewTarget, enter the callee context
            // before running the native constructor, including argument coercion.
            // Argument expressions have already been evaluated by the caller.
            // Bound functions and proxies forward before selecting this view.
            const view = try builtin_dispatch.finalCallableRealmView(ctx, function_object);
            return constructValueOrBytecodeInEnvironment(view.realm, output, view.global, func, args, caller_function, caller_frame, new_target, argv) catch |err| {
                try builtin_dispatch.materializeRuntimeError(view.realm, view.global, err);
                return err;
            };
        }
    }
    return constructValueOrBytecodeInEnvironment(ctx, output, global, func, args, caller_function, caller_frame, new_target, argv);
}

fn constructValueOrBytecodeInEnvironment(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    new_target: core.JSValue,
    argv: ArgvMode,
) HostError!core.JSValue {
    if (object_ops.objectFromValue(func)) |object| {
        if (object.proxyTarget() != null) {
            return object_ops.constructProxy(ctx, output, global, object, args, caller_function, caller_frame, new_target);
        }
    }
    if (object_ops.callableObjectFromValue(func)) |function_object| {
        if (function_object.class_id == core.class.ids.bound_function) {
            if (ctx.runtime.stack.checkNativeOverflow(0)) return error.StackOverflow;
            const target = function_object.boundTarget() orelse return error.TypeError;
            var combined = try boundFunctionArgs(ctx.runtime, function_object, args);
            defer freeArgs(ctx.runtime, combined);
            var combined_root = array_ops.ValueSliceRoot{};
            combined_root.init(ctx.runtime, &combined);
            defer combined_root.deinit();
            const next_new_target = if (func.sameValue(new_target)) target else new_target;
            return constructValueOrBytecodeWithNewTarget(ctx, output, global, target, combined, caller_function, caller_frame, next_new_target);
        }
        if (try array_ops.constructArrayBufferNativeRecord(ctx, output, global, func, function_object, args, new_target)) |constructed| {
            return constructed;
        }
        // QuickJS `js_object_constructor`: when new.target is the active
        // Object function, construction shares the same nullish/ToObject body
        // as a plain call. A distinct new.target creates from that constructor
        // in `constructBuiltin`.
        if (core.function.decodeNativeBuiltinId(function_object.nativeFunctionId())) |native_ref| {
            if (native_ref.domain == .object and native_ref.id == object_construct_id and new_target.sameValue(func)) {
                const constructor_global = object_ops.objectRealmGlobal(function_object) orelse global;
                return (try builtin_dispatch.callConstructRecord(ctx, output, constructor_global, function_object, native_ref, null, args, caller_function, caller_frame)) orelse error.TypeError;
            }
        }
        if (try function_ops.constructBuiltin(ctx, output, global, function_object, function_object.nativeConstructorKind(), args, caller_function, caller_frame, new_target)) |constructed| {
            return constructed;
        }
        if (function_object.isHostEntryFunction()) {
            return constructExternalHostFunction(ctx, output, global, function_object, args, caller_function, caller_frame, new_target);
        }
        if (function_object.class_id == core.class.ids.c_function) return exception_ops.throwTypeErrorMessage(ctx, global, "not a constructor");
    }
    if (func.is(.function_bytecode)) {
        // The tag check above still allows a zero payload; that is corrupt
        // bytecode, matching setFunctionBytecodeValue.
        const fb = functionBytecodeFromValue(func) orelse return error.InvalidBytecode;
        if (!isConstructibleFunctionBytecode(fb)) return exception_ops.throwTypeErrorMessage(ctx, global, "not a constructor");
        // qjs JS_CallConstructorInternal: a DERIVED class ctor
        // allocates NO instance and does NO prototype lookup — `this` stays
        // uninitialized (TDZ) until super() builds the object via new.target and
        // binds it. Only base/ordinary ctors get the eager js_create_from_ctor
        // instance.
        if (fb.isDerivedClassConstructor()) {
            return try callFunctionBytecodeConstruct(ctx, func, func, core.JSValue.uninitialized(), args, &.{}, output, global, new_target, argv);
        }
        const instance = try createConstructorInstance(ctx, output, global, new_target, caller_function, caller_frame);
        return constructBytecodeBody(ctx, func, func, instance, args, &.{}, output, global, new_target, argv);
    }
    if (object_ops.functionObjectFromValue(func)) |function_object| {
        // Ordinary user bytecode constructor (`new Vec(x, y, z)`, classes):
        // `callableObjectFromValue` above excludes the bytecode classes.
        // functionObjectFromValue already required a bytecode function class.
        const function_value = function_object.functionBytecode() orelse return error.InvalidBytecode;
        // functionBytecode() returns JSValue.functionBytecode of a live header.
        const fb = functionBytecodeFromValue(function_value) orelse unreachable;
        if (!isConstructibleBytecodeFunctionObject(function_object, fb)) return exception_ops.throwTypeErrorMessage(ctx, global, "not a constructor");
        return constructOrdinaryBytecodeFunctionObject(ctx, output, global, func, function_object, function_value, fb, args, caller_function, caller_frame, new_target, argv);
    }
    if (object_ops.objectFromValue(func)) |object| {
        if (object.class_id == core.class.ids.object and object.proxyTarget() == null) {
            return exception_ops.throwTypeErrorMessage(ctx, global, "not a constructor");
        }
    }
    // QuickJS JS_CallInternal rejects non-object call targets before the
    // constructor-only object checks. This is the path used by a live
    // `super()` after the derived constructor's [[Prototype]] becomes null.
    if (!func.is(.object)) return exception_ops.throwTypeErrorMessage(ctx, global, "not a function");
    return exception_ops.throwTypeErrorMessage(ctx, global, "not a constructor");
}

fn constructExternalHostFunction(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    new_target: core.JSValue,
) !core.JSValue {
    const entry = function_object.nativeEntry() orelse return error.TypeError;
    if (!entry.flags.host_constructor) return exception_ops.throwTypeErrorMessage(ctx, global, "not a constructor");
    const instance = try createConstructorInstance(ctx, output, global, new_target, caller_function, caller_frame);

    const result = if (entry.kind.isConstructor()) blk: {
        const target = object_ops.objectFromValue(new_target) orelse return error.TypeError;
        break :blk try builtin_dispatch.constructInternalRecordDirect(ctx, output, global, function_object, instance, entry, args, caller_function, caller_frame, target);
    } else try builtin_dispatch.callInternalRecordDirect(ctx, output, global, &.{}, function_object, instance, entry, args, caller_function, caller_frame);
    return constructorResult(result, instance);
}

test "constructFinalizationRegistryWithPrototype roots function bytecode cleanup while creating registry" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-finalization-cleanup-bytecode-symbol");
    const fb = try bytecode.FunctionBytecode.createPublishedFixture(rt, .{
        .flags = .{ .func_kind = .generator },
        .cpool_count = 1,
    }, &.{try rt.symbolValue(symbol_atom)});

    const cleanup_callback = core.JSValue.functionBytecode(&fb.header);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const registry_value = try object_ops.constructFinalizationRegistryWithPrototype(ctx, cleanup_callback, null);
    const registry = object_ops.objectFromValue(registry_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = registry.finalizationRegistryCleanupCallback() orelse return error.TypeError;
    try std.testing.expect(stored.same(cleanup_callback));

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "finalizationRegistryAppendCell roots direct symbol fields while allocating cell" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const registry = try core.Object.create(rt, core.class.ids.finalization_registry, null);
    const target_atom = try rt.atoms.newValueSymbol("gc-finalization-target-symbol");
    const target_value = try rt.symbolValue(target_atom);
    const held_atom = try rt.atoms.newValueSymbol("gc-finalization-held-symbol");
    const held_value = try rt.symbolValue(held_atom);
    const token_atom = try rt.atoms.newValueSymbol("gc-finalization-token-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const token_value = try rt.symbolValue(token_atom);
    try builtin_glue.finalizationRegistryAppendCell(
        rt,
        registry,
        target_value,
        held_value,
        token_value,
    );

    try std.testing.expect(rt.atoms.name(target_atom) != null);
    try std.testing.expect(rt.atoms.name(held_atom) != null);
    try std.testing.expect(rt.atoms.name(token_atom) != null);
    try std.testing.expectEqual(@as(usize, 1), registry.finalizationRegistryCells().len);
    const cell = registry.finalizationRegistryCells()[0];
    try std.testing.expect(cell.held_value.same(held_value));
    try std.testing.expectEqual(
        core.Object.weakIdentityFromValuePeek(rt, token_value),
        cell.unregister_token_identity,
    );

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(target_atom) == null);
    try std.testing.expect(rt.atoms.name(held_atom) == null);
    try std.testing.expect(rt.atoms.name(token_atom) == null);
}

pub fn createConstructorInstance(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    new_target: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const prototype = try object_ops.reflectConstructPrototypeVm(ctx, output, global, "Object", new_target, caller_function, caller_frame);
    const instance = try core.Object.create(ctx.runtime, core.class.ids.object, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, instance.gcHeader());
    return instance.value();
}

fn createBytecodeConstructorInstance(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    func: core.JSValue,
    function_object: *core.Object,
    new_target: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (new_target.sameValue(func)) {
        // qjs js_create_from_ctor reads new_target.prototype: a base function's
        // `.prototype` is created eagerly, so this is always a plain-data object
        // read. zjs materializes `.prototype` lazily (auto_init), so materialize
        // it here on the first construct — it then stays a data slot, and every
        // later `new` (plus the simple-field fast path) takes the direct read
        // instead of the reflectConstructPrototypeVm chain below.
        if (try function_object.getOwnConstructorPrototypeObject(ctx.runtime)) |prototype| {
            return createProfiledConstructorInstance(
                ctx.runtime,
                prototype,
                function_object.bytecodeArm().*.function_bytecode,
            );
        }
    }
    return createConstructorInstance(ctx, output, global, new_target, caller_function, caller_frame);
}

const max_ctor_alloc_capacity = bytecode.function_bytecode.max_ctor_alloc_capacity;

fn createProfiledConstructorInstance(
    rt: *core.JSRuntime,
    prototype: *core.Object,
    fb: ?*const bytecode.FunctionBytecode,
) !core.JSValue {
    const capacity: usize = if (fb) |function| blk: {
        const profile = function.ctorAllocProfile() orelse break :blk 0;
        break :blk if (profile.state == .live) profile.capacity else 0;
    } else 0;
    const instance = try core.Object.create(rt, core.class.ids.object, prototype);
    errdefer core.Object.destroyFromHeader(rt, instance.gcHeader());
    // Reserving 1–3 slots costs more than the later put_field grows on this
    // host (N3 1.21 → 1.28). Four or more named writes pay for the extra
    // buffer. Threshold is a slot count, not a bytecode pattern.
    if (capacity >= 4) try instance.reserveOwnPropertyCapacity(rt, capacity);
    return instance.value();
}

pub fn noteConstructorAllocation(fb: *const bytecode.FunctionBytecode, instance: core.JSValue) void {
    const profile = fb.ctorAllocProfileMut() orelse return;
    if (profile.state == .inert) return;
    const object = object_ops.objectFromValue(instance) orelse return;
    const observed = object.shape_ref.prop_count;
    // Steady state: one compare, no store. Small-ctor recovery is ~0, so this
    // hook must not become a net tax (DESIGN R3).
    if (profile.state == .live and observed <= profile.capacity) return;
    if (observed == 0) return;
    profile.capacity = @intCast(@min(observed, @as(usize, max_ctor_alloc_capacity)));
    profile.state = .live;
}

/// Cold `JS_GetFunctionRealm` analogue. This query must not be used to switch
/// actual call dispatch early: Bound and Proxy calls perform their wrapper
/// work in the caller realm and only their final target arm changes context.
pub fn functionRealmContext(caller: *core.JSContext, function_value: core.JSValue) HostError!*core.JSContext {
    // GetFunctionRealm follows proxy and bound targets iteratively.
    var current = function_value;
    while (true) {
        const object = object_ops.objectFromValue(current) orelse return caller;
        switch (object.class_id) {
            core.class.ids.c_function => return object.nativeFunctionRealm() orelse error.InvalidBuiltinRegistry,
            core.class.ids.bytecode_function,
            core.class.ids.generator_function,
            core.class.ids.async_function,
            core.class.ids.async_generator_function,
            => return object.bytecodeFunctionRealmContext() orelse error.InvalidBuiltinRegistry,
            core.class.ids.proxy => {
                if (object.proxyHandler() == null) {
                    const caller_global = caller.global orelse return error.InvalidBuiltinRegistry;
                    _ = try exception_ops.throwTypeErrorMessage(caller, caller_global, "revoked proxy");
                    unreachable;
                }
                current = object.proxyTarget() orelse return caller;
            },
            core.class.ids.bound_function => current = object.boundTarget() orelse return error.InvalidBuiltinRegistry,
            // C_FUNCTION_DATA, C_CLOSURE, Promise/async special classes, and
            // every other JSClassCall-style object all use the caller realm.
            else => return caller,
        }
    }
}

pub fn functionRealmGlobal(caller: *core.JSContext, function_value: core.JSValue) HostError!*core.Object {
    const realm = try functionRealmContext(caller, function_value);
    return realm.global orelse error.InvalidBuiltinRegistry;
}

pub fn collectIteratorValues(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const record = try iterator_ops.getIteratorDirect(ctx, output, global, iterator_value, caller_function, caller_frame);
    return iterator_ops.iteratorToList(ctx, output, global, record);
}

pub fn getIteratorMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source_value: core.JSValue,
) !core.JSValue {
    const symbol_key = comptime core.atom.predefinedId("Symbol.iterator", .symbol).?;
    return object_ops.getValueProperty(ctx, output, global, source_value, symbol_key, null, null);
}

/// Spread / rest append (`[...src]`, `f(...src)`), faithful to qjs
/// `js_append_enumerate`. Always resolves `src[@@iterator]`
/// and constructs the iterator, then takes the dense bulk copy ONLY when the
/// Array iterator protocol is un-tampered: the constructed iterator is a default
/// Array Iterator of `value` kind whose `next` is the builtin
/// `js_array_iterator_next`, and its target is a hole-free fast array
/// (`length == count`). Otherwise it steps the iterator through the generic
/// protocol. The previous fast path keyed only on `flags.is_array`, so it
/// silently ignored a user-overridden `src[Symbol.iterator]` or a patched
/// `%ArrayIteratorPrototype%.next` (observably wrong vs spec AND qjs).
///
/// Reading densely from the *iterator's* current target (not from `src`) is the
/// established faithful pattern of `fastArrayForOfNext` and stays correct even
/// when `@@iterator` was repointed to another array's (possibly partially
/// consumed) iterator — qjs reaches the same result via its `general_case`.
pub fn appendSpreadValuesEnumerate(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target: *core.Object,
    source_value: core.JSValue,
    start_index: i32,
) !i32 {
    const rt = ctx.runtime;
    // Source, destination, method, iterator, next, current item, dense source.
    var values = [_]core.JSValue{ source_value, target.value() } ++ ([_]core.JSValue{core.JSValue.undefinedValue()} ** 5);
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);

    // iterator method = GetProperty(src, @@iterator) (qjs quickjs.c)
    // Even a generator can override @@iterator; class identity is not a
    // substitute for the observable GetIterator operation.
    values[2] = try getIteratorMethod(ctx, output, global, values[0]);
    if (!isCallableValue(values[2])) {
        _ = try exception_ops.throwTypeErrorMessage(ctx, global, "value is not iterable");
        unreachable;
    }

    // enumobj = src[@@iterator] (qjs GetIterator, quickjs.c)
    values[3] = try callValueOrBytecodeRoot(ctx, output, global, values[0], values[2], &.{}, null, null);
    _ = try property_ops.expectObject(values[3]);

    // next = GetProperty(enumobj, "next") (qjs quickjs.c)
    // GetIterator captures next once per acquisition, even if this iterator
    // was consumed previously or its next getter changes the property.
    values[4] = try object_ops.getValueProperty(ctx, output, global, values[3], core.atom.ids.next, null, null);
    if (!isCallableValue(values[4])) return error.NotAFunction;

    var index = start_index;

    // Fast path (qjs quickjs.c): default Array Iterator (value kind)
    // + builtin `next` + hole-free fast-array target (`length == count`).
    fast: {
        // JSValue slots stay put for this block. A copying collection can
        // still move the objects, so each *Object is rebound after a call
        // that can allocate.
        const next_obj = object_ops.objectFromValue(values[4]) orelse break :fast;
        if (!next_obj.isArrayIteratorNextFunction()) break :fast;
        const iter = object_ops.objectFromValue(values[3]).?;
        if (iter.class_id != core.class.ids.array_iterator) break :fast;
        if (iterator_ops.arrayIteratorKind(iter) != .value) break :fast;
        const target_value = (iter.iteratorTargetSlot().*) orelse break :fast;
        values[6] = target_value;
        const source = object_ops.objectFromValue(values[6]) orelse break :fast;
        if (!source.isArray() or source.hasExoticMethods() or source.proxyTarget() != null) break :fast;
        const element_count = source.arrayElements().len;
        const length: usize = @intCast(source.arrayLength());
        if (length != element_count) break :fast; // qjs: len != count32 -> general_case
        const cursor = iter.iteratorIndexSlot().*;
        if (cursor > element_count) break :fast;
        // This builtin iterator has a known, side-effect-free dense range.
        // Reserve its destination once: each incremental growth otherwise
        // leaves an obsolete GC storage cell alive until the next sweep.
        // Keep all unusual descriptor/length targets on the per-item path.
        const dest = object_ops.objectFromValue(values[1]).?;
        if (cursor < element_count and index >= 0 and dest != source and
            dest.isArray() and !dest.hasExoticMethods() and
            dest.arrayElementStorageMode() == .dense and
            dest.flags.extensible and dest.flags.length_writable and
            dest.shape_ref.prop_count == 0 and dest.arrayElements().len == @as(usize, @intCast(index)))
        {
            const needed = @as(usize, @intCast(index)) + element_count - cursor;
            if (needed <= std.math.maxInt(i32)) {
                // A failed first definition has already consumed one item.
                iter.iteratorIndexSlot().* = cursor + 1;
                try dest.reserveDenseArrayElements(rt, @intCast(needed));
            }
        }
        var i: usize = cursor;
        while (i < element_count) : (i += 1) {
            try exception_ops.pollNativeLoop(ctx, global);
            // Reserve and per-item growth can relocate storage, including
            // the source storage when source and destination are identical.
            const live_source = object_ops.objectFromValue(values[6]).?;
            values[5] = live_source.arrayElements()[i];
            const live_iter = object_ops.objectFromValue(values[3]).?;
            live_iter.iteratorIndexSlot().* = i + 1;
            // A contiguous C_W_E definition can stay dense. The shared
            // CreateDataProperty helper retains descriptor/length fallbacks
            // and never invokes an inherited indexed setter.
            const live_dest = object_ops.objectFromValue(values[1]).?;
            try array_ops.createArrayDataOrTypedArrayElement(rt, live_dest, core.Atom.taggedInt(@intCast(index)), values[5]);
            index += 1;
        }
        const done_iter = object_ops.objectFromValue(values[3]).?;
        done_iter.iteratorIndexSlot().* = element_count; // exhaust, matching a full drain
        done_iter.clearOptionalValueSlot(rt, done_iter.iteratorTargetSlot());
        return index;
    }

    // General case (qjs quickjs.c): step the constructed iterator.
    while (true) {
        try exception_ops.pollNativeLoop(ctx, global);
        const step = try iterator_ops.iteratorStepWithNext(ctx, output, global, values[3], values[4], null, null);
        if (step.done) {
            break;
        }
        values[5] = step.value;
        try array_ops.createArrayDataOrTypedArrayElement(rt, object_ops.objectFromValue(values[1]).?, core.Atom.taggedInt(@intCast(index)), values[5]);
        index += 1;
    }
    return index;
}

pub fn isCallableValue(value: core.JSValue) bool {
    if (value.is(.function_bytecode)) return true;
    const object = object_ops.objectFromValue(value) orelse return false;
    return core.class.isFunctionClass(object.class_id) or
        object_ops.proxyTargetIsCallableObject(object);
}

pub fn globalLexicalEnv(ctx: *core.JSContext) !*core.Object {
    if (ctx.lexicals) |env| return env;
    if (ctx.global) |global| {
        if (global.globalLexicals(ctx.runtime)) |env| {
            ctx.setLexicals(env);
            return env;
        }
    }
    const env = try core.Object.create(ctx.runtime, core.class.ids.object, null);
    ctx.setLexicals(env);
    return env;
}

pub fn existingGlobalLexicalEnv(ctx: *core.JSContext) ?*core.Object {
    if (ctx.lexicals) |env| return env;
    if (ctx.global) |global| return global.globalLexicals(ctx.runtime);
    return null;
}

pub fn existingGlobalLexicalEnvForGlobal(ctx: *core.JSContext, global: *core.Object) ?*core.Object {
    if (ctx.lexicals) |env| return env;
    if (global.globalLexicals(ctx.runtime)) |env| return env;
    if (ctx.global) |context_global| {
        if (context_global != global) return context_global.globalLexicals(ctx.runtime);
    }
    return null;
}

pub fn globalLexicalHasForGlobal(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom) bool {
    const env = existingGlobalLexicalEnvForGlobal(ctx, global) orelse return false;
    return env.hasOwnProperty(atom_id);
}

/// QuickJS `js_closure_global_var` for one ordinary GLOBAL capture. This is
/// the sole selector shared by root, nested, and direct-eval closure builders:
/// lexical VARREF -> materialized global AUTOINIT/retry -> global VARREF ->
/// shared parked uninitialized cell. Data/accessor properties are observed by
/// descriptor kind only; their getter is never invoked here.
///
/// The returned JSValue is an owned reference to the selected VarRef cell.
/// Consumer ClosureVar flags do not mutate that owner cell; declaration and
/// local-slot producers remain the only authorities for const/lexical/name
/// metadata.
pub fn selectOrdinaryGlobalClosureCell(
    ctx: *core.JSContext,
    global: *core.Object,
    atom_id: core.Atom,
) !core.JSValue {
    if (existingGlobalLexicalEnvForGlobal(ctx, global)) |env| {
        if (env.findProperty(atom_id)) |index| {
            if (env.asVarRefAt(index)) |cell| return cell.valueRef();
        }
    }

    while (global.findProperty(atom_id)) |index| {
        const flags = global.propFlagsAt(index);
        if (flags.isAutoInit()) {
            _ = (try global.getOwnProperty(ctx.runtime, atom_id)) orelse return error.InvalidBytecode;
            // A failed builder must have returned its error and kept the
            // placeholder retryable. A successful read cannot leave the same
            // slot in AUTOINIT form.
            if (global.findProperty(atom_id)) |materialized_index| {
                if (global.propFlagsAt(materialized_index).isAutoInit()) return error.InvalidBytecode;
            }
            continue;
        }
        if (global.asVarRefAt(index)) |cell| return cell.valueRef();
        break;
    }
    return globalObjectGetUninitializedVar(ctx, global, atom_id);
}

/// qjs u.global_object.uninitialized_vars, create-on-demand: the side table
/// object hangs off the global object (quickjs.c js_global_object_get/
/// find_uninitialized_var operate on it, 17069-17123).
fn globalUninitializedVarsEnv(ctx: *core.JSContext, global: *core.Object) !*core.Object {
    if (global.globalUninitializedVars()) |env| return env;
    const env = try core.Object.create(ctx.runtime, core.class.ids.object, null);
    try global.setGlobalUninitializedVars(ctx.runtime, env);
    return env;
}

/// qjs js_global_object_get_uninitialized_var: return
/// the shared UNINITIALIZED cell for `atom_id`, creating and filing it in the
/// side table when absent. The caller owns the returned ref; the table slot
/// holds its own ref. The fresh cell's value carries the UNINITIALIZED
/// sentinel (js_create_var_ref(ctx, TRUE)); is_lexical/is_const stay false.
pub fn globalObjectGetUninitializedVar(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom) !core.JSValue {
    const rt = ctx.runtime;
    const env = try globalUninitializedVarsEnv(ctx, global);
    if (env.findProperty(atom_id)) |index| {
        if (env.asVarRefAt(index)) |cell| return cell.valueRef();
    }
    const cell = try core.VarRef.createClosed(rt, core.JSValue.uninitialized());
    // qjs JS_PROP_C_W_E | JS_PROP_VARREF (17088).
    // appendPreparedPropertyEntry consumes the cell slot on both success and
    // failure, so no caller-side errdefer may release it again.
    try env.appendPreparedPropertyEntry(rt, atom_id, core.property.Flags.varRef(.all), .{ .var_ref = cell });
    return cell.valueRef();
}

/// qjs js_global_object_find_uninitialized_var: if a
/// parked cell exists for `atom_id`, remove it from the side table and hand it
/// to the new declaration so every earlier capture aliases the new binding
/// (non-lexical reuse resets the value to undefined). Returns a fresh owned
/// ref, or null when no parked cell exists (caller creates a fresh cell).
pub fn globalObjectFindUninitializedVar(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom, is_lexical: bool) error{OutOfMemory}!?core.JSValue {
    const rt = ctx.runtime;
    const env = global.globalUninitializedVars() orelse return null;
    const index = env.findProperty(atom_id) orelse return null;
    const cell = env.asVarRefAt(index) orelse return null;
    const cell_value = cell.valueRef();
    _ = try env.deleteProperty(rt, atom_id);
    if (!is_lexical) {
        cell.varRefValueSlot().* = core.JSValue.undefinedValue();
    }
    return cell_value;
}

/// Create or reuse the JS_PROP_VARREF slot backing a top-level `var`/function
/// global. Existing data properties already use VARREF in QuickJS because the
/// global object's ordinary define path creates them that way; zjs normalizes
/// its plain-data representation here. A configurable accessor is converted
/// only for a function declaration, matching `js_closure_define_global_var`.
pub fn ensureGlobalObjectVarRefCell(
    ctx: *core.JSContext,
    global: *core.Object,
    atom_id: core.Atom,
    configurable: bool,
    is_function: bool,
) !?core.JSValue {
    const rt = ctx.runtime;
    while (global.findProperty(atom_id)) |initial_index| {
        const initial_flags = global.propFlagsAt(initial_index);
        if (initial_flags.isAutoInit()) {
            _ = (try global.getOwnProperty(rt, atom_id)) orelse return error.OutOfMemory;
            if (global.propFlagsAt(initial_index).isAutoInit()) return error.OutOfMemory;
            continue;
        }

        var next_flags = initial_flags.withKind(.var_ref);
        if (is_function and initial_flags.configurable) {
            next_flags = core.property.Flags.varRef(.{ .writable = true, .enumerable = true, .configurable = configurable });
        }
        if (global.asVarRefAt(initial_index)) |cell| {
            if (next_flags.bits() != initial_flags.bits()) {
                try global.replaceOwnPropertyWithVarRefCell(rt, atom_id, initial_index, next_flags, cell);
            }
            cell.varRefIsConstSlot().* = !next_flags.writable;
            cell.varRefIsDeletableSlot().* = next_flags.configurable;
            return cell.valueRef();
        }
        if (initial_flags.isAccessor() and (!is_function or !initial_flags.configurable)) return null;

        // initialClosureVarRef parked this exact unresolved-global cell in the
        // side table. Keep the table ref until the shape clone/slot replacement
        // succeeds; this makes OOM rollback automatic.
        const cell_value = try globalObjectGetUninitializedVar(ctx, global, atom_id);
        const cell = core.VarRef.fromValue(cell_value).?;
        try global.replaceOwnPropertyWithVarRefCell(rt, atom_id, initial_index, next_flags, cell);
        const parked = global.globalUninitializedVars() orelse return error.InvalidBytecode;
        if (!try parked.deleteProperty(rt, atom_id)) return error.InvalidBytecode;
        return cell_value;
    }

    // qjs js_closure_define_global_var tail: "if there
    // is a corresponding uninitialized variable, use it" — a capture parked in
    // the side table before this declaration is reused (value reset to
    // undefined), so every earlier capture aliases the new property cell.
    const cell_value = try globalObjectFindUninitializedVar(ctx, global, atom_id, false) orelse blk: {
        const fresh = try core.VarRef.createClosed(rt, core.JSValue.undefinedValue());
        break :blk fresh.valueRef();
    };
    const cell = core.VarRef.fromValue(cell_value).?;
    // appendPreparedPropertyEntry consumes cell_value on both paths.
    try global.appendPreparedPropertyEntry(
        rt,
        atom_id,
        core.property.Flags.varRef(.{ .writable = true, .enumerable = true, .configurable = configurable }),
        .{ .var_ref = cell },
    );
    cell.varRefIsDeletableSlot().* = configurable;
    return cell.valueRef();
}

/// Create-or-fetch the VarRef cell for a top-level lexical in ctx.lexicals,
/// stored as a JS_PROP_VARREF slot (qjs js_closure_define_global_var, lexical
/// arm, quickjs.c). Returns a fresh ref the caller owns (for
/// frame.var_refs[idx]). The slot holds its own ref; the cell starts
/// uninitialized (TDZ) like qjs js_create_var_ref.
pub fn ensureGlobalLexicalCell(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom, is_const: bool) !core.JSValue {
    const env = try globalLexicalEnv(ctx);
    if (env.findProperty(atom_id)) |index| {
        if (env.asVarRefAt(index)) |cell| return cell.valueRef();
    }
    const rt = ctx.runtime;
    // qjs quickjs.c: "if there is a corresponding global variable,
    // reuse its reference and create a new one for the global variable" — the
    // definition-time cell surgery. The OLD property cell (which every earlier
    // capture aliases) becomes the lexical cell (value parked at UNINITIALIZED
    // for the TDZ window); a NEW cell holding the old value takes its place as
    // the global-object property, so globalThis.<name> keeps the var value.
    if (global.findProperty(atom_id)) |gidx| {
        if (global.asVarRefAt(gidx)) |old_cell| {
            // Allocate before moving the old value so an allocation failure
            // leaves the existing global property untouched.
            const new_cell = try core.VarRef.createClosed(rt, core.JSValue.undefinedValue());
            const old_is_lexical = old_cell.is_lexical;
            const old_is_const = old_cell.varRefIsConstSlot().*;
            // var_ref1->value = var_ref->value; var_ref->value = JS_UNINITIALIZED
            // — the value MOVES (no dup/free), qjs 17155-17156.
            new_cell.varRefValueSlot().* = old_cell.varRefValueSlot().*;
            old_cell.varRefValueSlot().* = core.JSValue.uninitialized();
            // pr->u.var_ref = var_ref1 (17157): the property slot's ref on the
            // old cell transfers to us; the new cell's creation ref transfers
            // to the property slot. Kind stays .var_ref — no shape change.
            global.propertyEntry(gidx).*.slot.var_ref = new_cell;
            // The global object is old by the time a second script declares a
            // `let` over an eval-created `var`; `new_cell` is young. Without
            // this the next minor condemns the cell and the global's slot
            // dangles (TGC S0 L3 site C: reproduced with `zjs -I a.js b.js`,
            // a.js `eval("var x = {}")`, b.js `let x = 1`).
            rt.gc.generationalBarrier(global.gcHeader(), &new_cell.header);
            rt.gc.auditUnbarrieredStore(global.gcHeader(), &new_cell.header, .global_lexical_cell_replace);
            // Keep one rollback ref because appendPreparedPropertyEntry consumes
            // the transferred property ref even when its shape allocation fails.
            const rollback_cell = old_cell;
            var rollback_cell_owned = true;
            errdefer if (rollback_cell_owned) {
                old_cell.varRefValueSlot().* = new_cell.varRefValueSlot().*;
                new_cell.varRefValueSlot().* = core.JSValue.undefinedValue();
                old_cell.is_lexical = old_is_lexical;
                old_cell.varRefIsConstSlot().* = old_is_const;
                global.propertyEntry(gidx).*.slot.var_ref = rollback_cell;
                rt.gc.generationalBarrier(global.gcHeader(), &rollback_cell.header);
                rollback_cell_owned = false;
            };
            // add_var_ref (17210-17223): the old cell becomes the lexical cell.
            old_cell.is_lexical = true;
            old_cell.varRefIsConstSlot().* = is_const;
            try env.appendPreparedPropertyEntry(rt, atom_id, core.property.Flags.varRef(.{ .writable = !is_const }), .{ .var_ref = old_cell });
            rollback_cell_owned = false;
            return old_cell.valueRef();
        }
    }
    // qjs 17193: reuse a parked uninitialized capture cell if one exists (the
    // value stays UNINITIALIZED for the lexical TDZ window), else fresh.
    const cell_value = try globalObjectFindUninitializedVar(ctx, global, atom_id, true) orelse blk: {
        const fresh = try core.VarRef.createClosed(rt, core.JSValue.uninitialized());
        break :blk fresh.valueRef();
    };
    const cell = core.VarRef.fromValue(cell_value).?;
    cell.varRefIsConstSlot().* = is_const;
    cell.is_lexical = true;
    // appendPreparedPropertyEntry consumes cell_value on both paths.
    try env.appendPreparedPropertyEntry(rt, atom_id, core.property.Flags.varRef(.{ .writable = !is_const }), .{ .var_ref = cell });
    return cell.valueRef();
}

pub fn globalLexicalValueForGlobal(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom) ?core.JSValue {
    const env = existingGlobalLexicalEnvForGlobal(ctx, global) orelse return null;
    if (env.getOwnDataPropertyValue(atom_id)) |value| return value;
    const index = env.findProperty(atom_id) orelse return null;
    const cell = env.asVarRefAt(index) orelse return null;
    return cell.varRefValue();
}

pub fn setGlobalLexicalValueForGlobal(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom, value: core.JSValue) !bool {
    const env = existingGlobalLexicalEnvForGlobal(ctx, global) orelse return false;
    if (!env.hasOwnProperty(atom_id)) return false;
    const rt = ctx.runtime;
    if (initializeGlobalLexicalValue(rt, env, atom_id, value)) return true;
    if (try env.setOwnWritableDataProperty(rt, atom_id, value)) return true;
    try env.setProperty(rt, atom_id, value);
    return true;
}

pub fn setGlobalLexicalValueForFastPathOwned(ctx: *core.JSContext, atom_id: core.Atom, value: core.JSValue) !bool {
    const env = existingGlobalLexicalEnv(ctx) orelse return false;
    const index = env.findProperty(atom_id) orelse return false;
    return env.setOwnDataPropertyAtForLexicalSyncOwned(ctx.runtime, index, atom_id, value);
}

pub fn initializeGlobalLexicalValue(rt: *core.JSRuntime, env: *core.Object, atom_id: core.Atom, value: core.JSValue) bool {
    // Hashed lookup: a script with n top-level lexicals initializes each once.
    const index = env.findProperty(atom_id) orelse return false;
    switch (env.propKindAt(index)) {
        .data => {
            const stored = &env.propertyEntry(index).*.slot.data;
            if (!stored.is(.uninitialized)) return false;
            stored.* = value;
            // Initialising a binding in a long-lived environment object is
            // an old-to-young edge like any other property store.
            rt.gc.generationalBarrier(env.gcHeader(), value.cycleMarkHeader());
            return true;
        },
        .var_ref => {
            const cell = env.propertyEntry(index).*.slot.var_ref;
            if (!cell.varRefValue().is(.uninitialized)) return false;
            cell.setVarRefValue(rt, value);
            return true;
        },
        .accessor, .auto_init => return false,
    }
}

pub fn indirectEval(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    eval_global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
) !core.JSValue {
    if (args.len == 0) return core.JSValue.undefinedValue();
    if (!args[0].isString()) return args[0];
    var source = std.ArrayList(u8).empty;
    defer source.deinit(ctx.runtime.nativeAllocator());
    try string_ops.appendSourceStringUtf8(ctx.runtime, &source, args[0]);

    const context_global = ctx.global;
    const use_global_lexicals = context_global == null or context_global.? != eval_global;
    const keep_active_lexicals = context_global == null;
    const saved_lexicals = ctx.lexicals;
    if (use_global_lexicals) ctx.setLexicals(eval_global.globalLexicals(ctx.runtime));

    const EvalResult = @typeInfo(@TypeOf(indirectEval)).@"fn".return_type.?;
    const result: EvalResult = blk: {
        const compile_realm = ctx.runtime.contexts.forGlobal(eval_global, .include_constructing) orelse break :blk error.InvalidBuiltinRegistry;
        // PerformEval: eval code runs with the caller's ScriptOrModule, so a
        // dynamic import() in it resolves against the calling module.
        const script_or_module = if (caller_function) |outer_function| outer_function.scriptOrModule() else null;
        var compiled = parser.compile(.{ .realm = compile_realm }, source.items, .{ .mode = .eval_indirect, .filename = "<eval>", .script_or_module = script_or_module, .strict = false }) catch |err| break :blk err;
        defer compiled.deinit();
        if (compiled.syntax_error) |*parse_error| {
            // Compile-error surface: own fileName/lineNumber/columnNumber +
            // leading stack line (build_backtrace filename branch,
            // quickjs.c).
            const parse_filename = ctx.runtime.atoms.name(parse_error.filename) orelse "<eval>";
            _ = exception_ops.throwParseSyntaxError(ctx, eval_global, parse_filename, parse_error.position.line, parse_error.position.column, parse_error.message) catch |err| break :blk err;
            break :blk error.SyntaxError;
        }
        _ = compiled.functionBytecode() orelse break :blk error.InvalidBytecode;
        const owned_root = compiled.takeFunctionBytecodeValue() orelse break :blk error.InvalidBytecode;
        var root_function_value = object_ops.createRootBytecodeFunctionObject(
            compile_realm,
            eval_global,
            owned_root,
            .root_global,
        ) catch |err| break :blk err;
        var root_values = [_]*core.JSValue{
            &root_function_value,
        };
        var root_frame = core.runtime.ValueRootFrame{
            .values = &root_values,
        };
        root_frame.activate(ctx.runtime);
        defer root_frame.deactivate(ctx.runtime);
        const root_function_object = object_ops.functionObjectFromValue(root_function_value) orelse break :blk error.InvalidBytecode;
        const root_bytecode_value = root_function_object.functionBytecode() orelse break :blk error.InvalidBytecode;
        const function = functionBytecodeFromValue(root_bytecode_value) orelse break :blk error.InvalidBytecode;
        var nested_stack = stack_mod.Stack.init(ctx.runtime, ctx.runtime.stackSize());
        defer nested_stack.deinit(ctx.runtime);
        break :blk runWithCallEnv(.{
            .ctx = compile_realm,
            .stack = &nested_stack,
            .function = function,
            .initial_this_value = eval_global.value(),
            .var_refs = root_function_object.functionCaptures(),
            .output = output,
            .global = eval_global,
            .strict_unresolved_get_var = function.isStrictMode(),
            .current_function_value = root_function_value,
            .eval_global_var_bindings = !function.isStrictMode(),
            .direct_eval_vars_reach_global = !function.isStrictMode(),
            .is_eval_code = true,
        }) catch |err| exception_ops.normalizeEvalRuntimeError(err);
    };

    if (use_global_lexicals) {
        var rooted_result = result catch |err| {
            try call_mod.restoreEvalGlobalLexicals(ctx, eval_global, saved_lexicals, keep_active_lexicals);
            return err;
        };
        var root_frame = core.runtime.rootValues(.{&rooted_result});
        root_frame.activate(ctx.runtime);
        defer root_frame.deactivate(ctx.runtime);
        try call_mod.restoreEvalGlobalLexicals(ctx, eval_global, saved_lexicals, keep_active_lexicals);
        return rooted_result;
    }
    return result;
}

pub fn isSimpleIdentifierName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!unicode_lib.isAsciiIdentifierStartByte(name[0])) return false;
    for (name[1..]) |ch| {
        if (!unicode_lib.isAsciiIdentifierPartByte(ch)) return false;
    }
    return true;
}

// Forces a cycle-removal pass mid-operation so a caller can prove its in-flight
// values were rooted: if they were not, they would be reclaimed here and the
// caller's outcome assertion (e.g. the copied value) would fail.
pub const ActiveRootValueProbe = struct {
    rt: *core.JSRuntime,

    pub fn trigger(context: ?*anyopaque, size: usize) void {
        _ = size;
        const self: *@This() = @ptrCast(@alignCast(context.?));
        _ = self.rt.collectFull() catch {}; // engine-frames-active trigger
    }
};

pub fn freeArgs(rt: *core.JSRuntime, args: []core.JSValue) void {
    if (args.len != 0) rt.nativeAllocator().free(args);
}

test "argsFromArrayLike roots initialized prefix while reading source" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try zjs_vm.contextGlobal(ctx);

    const source = try core.Object.create(rt, core.class.ids.object, null);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-args-from-array-like-prefix-root");
    const symbol_value = try rt.symbolValue(symbol_atom);
    try source.defineOwnProperty(rt, core.Atom.taggedInt(0), core.Descriptor.data(symbol_value, .all));
    try source.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(2), .method));
    try source.defineAutoInitPropertyWithRealm(
        rt,
        core.Atom.taggedInt(1),
        "lazyArgsFromArrayLikeValue",
        0,
        core.property.Flags.data(.all),
        global,
    );

    const Probe = struct {
        rt: *core.JSRuntime,
        atom_id: core.Atom,
        saw_symbol: bool = false,
        trace_failed: bool = false,

        fn trigger(context: ?*anyopaque, size: usize) void {
            _ = size;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = self.rt.collectFull() catch {
                self.trace_failed = true;
                return;
            };
            self.saw_symbol = self.rt.atoms.name(self.atom_id) != null;
        }
    };

    var probe = Probe{
        .rt = rt,
        .atom_id = symbol_atom,
    };
    const saved_trigger_fn = rt.gc.heap_budget.installProbe(.{ .run = Probe.trigger, .context = &probe });
    defer rt.gc.heap_budget.restoreProbe(saved_trigger_fn);

    const args = try array_ops.argsFromArrayLike(ctx, null, global, source.value(), null, null);
    var args_alive = true;
    defer if (args_alive) freeArgs(rt, args);

    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expect(!probe.trace_failed);
    try std.testing.expect(probe.saw_symbol);

    freeArgs(rt, args);
    args_alive = false;
    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn callFunctionBytecodeConstruct(
    ctx: *core.JSContext,
    func: core.JSValue,
    current_function_value: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const *core.VarRef,
    output: ?*std.Io.Writer,
    global: *core.Object,
    new_target_value: core.JSValue,
    argv: ArgvMode,
) !core.JSValue {
    // A bytecode constructor takes the JS_CallConstructorInternal poll above
    // and then a second JS_CallInternal poll, both in the caller Realm. Only
    // after this point does the bytecode body switch to its function Realm.
    const interrupt_global = ctx.global orelse global;
    try exception_ops.pollInterrupt(ctx, interrupt_global);
    return callFunctionBytecodeModeStateAfterInterruptPoll(
        ctx,
        func,
        current_function_value,
        this_value,
        args,
        var_refs,
        output,
        interrupt_global,
        .{ .new_target_value = new_target_value, .copy_argv = argv == .copy },
    ) catch |err| {
        if (err == error.DerivedThisUninitialized) {
            // `global` is already the final bytecode callee's realm, while
            // `ctx` is still JS_CallConstructorInternal's caller_ctx. QuickJS
            // materializes OP_get_loc_checkthis in that caller context before
            // returning through the construct boundary.
            const caller_global = ctx.global orelse return error.InvalidBuiltinRegistry;
            try builtin_dispatch.materializeRuntimeError(ctx, caller_global, err);
        }
        return err;
    };
}

/// Tail of an ordinary bytecode call: defer generators, no resume, undefined new.target.
/// Passed by value. Defaults are the direct-call path.
pub const BytecodeCallMode = struct {
    defer_generators: bool = true,
    generator_state: ?*core.Object = null,
    resume_value: ?core.JSValue = null,
    new_target_value: core.JSValue = core.JSValue.undefinedValue(),
    copy_argv: bool = false,
    call_depth_precharged: bool = false,
};

pub fn callFunctionBytecodeModeState(
    ctx: *core.JSContext,
    func: core.JSValue,
    current_function_value: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const *core.VarRef,
    output: ?*std.Io.Writer,
    global: *core.Object,
    mode: BytecodeCallMode,
) HostError!core.JSValue {
    const caller_global = ctx.global orelse global;
    var effective = mode;
    // QuickJS async_func_resume checks native SP with alloca_size=0
    // before entering the inner JS_CallInternal interrupt poll.
    const resident_guard = if (effective.generator_state != null)
        try zjs_vm.preflightResidentEntry(ctx, caller_global, false)
    else blk: {
        try exception_ops.pollInterrupt(ctx, caller_global);
        break :blk null;
    };
    defer if (resident_guard) |guard| guard.deinit();
    if (effective.generator_state != null) effective.call_depth_precharged = true;
    return callFunctionBytecodeModeStateAfterInterruptPoll(
        ctx,
        func,
        current_function_value,
        this_value,
        args,
        var_refs,
        output,
        caller_global,
        effective,
    );
}

fn callFunctionBytecodeModeStateAfterInterruptPoll(
    ctx: *core.JSContext,
    func: core.JSValue,
    current_function_value: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const *core.VarRef,
    output: ?*std.Io.Writer,
    global: *core.Object,
    mode: BytecodeCallMode,
) HostError!core.JSValue {
    // Callers already required a bytecode tag or a published functionBytecode()
    // value. Decode fails only for a zero payload.
    const fb = functionBytecodeFromValue(func) orelse return error.InvalidBytecode;
    const deferred_heap_entry = mode.generator_state == null and
        ((mode.defer_generators and
            (fb.functionKind() == .generator or fb.functionKind() == .async_generator)) or
            fb.functionKind() == .async);
    const heap_resident_frame = fb.functionKind() != .normal or mode.generator_state != null;
    const planned_stack_bytes = if (heap_resident_frame)
        0
    else
        vm_opcodes.bytecodeFrameAllocaSize(fb, args.len, mode.copy_argv);
    const call_depth_guard = try zjs_vm.enterCallDepthUnlessPrecharged(
        ctx,
        global,
        planned_stack_bytes,
        mode.call_depth_precharged or deferred_heap_entry,
    );
    defer if (call_depth_guard) |guard| guard.deinit();

    const function_ctx = fb.realmContext() orelse return error.InvalidBuiltinRegistry;
    const function_global = function_ctx.global orelse return error.InvalidBuiltinRegistry;
    if (mode.defer_generators and (fb.functionKind() == .generator or fb.functionKind() == .async_generator)) {
        return object_ops.createGeneratorObject(
            function_ctx,
            func,
            current_function_value,
            this_value,
            args,
            var_refs,
            output,
            function_global,
            fb.functionKind() == .async_generator,
            false,
            ctx,
            global,
        );
    }

    const fb_runtime_strict = fb.isStrictMode() or fb.runtimeStrictMode();
    if (fb.functionKind() == .async and mode.generator_state == null) {
        const effective_this = try coerceCallThis(function_ctx, function_global, fb_runtime_strict, this_value);
        return promise_ops.asyncFunctionStart(
            function_ctx,
            func,
            current_function_value,
            effective_this,
            args,
            var_refs,
            output,
            function_global,
            ctx,
            global,
        );
    }
    const stop_on_yield = fb.functionKind() == .generator or fb.functionKind() == .async_generator;

    // Mirror QuickJS JS_CallInternal: non-suspending bytecode frames carve
    // their operand stack from the contiguous per-runtime VM stack arena
    // instead of heap-allocating per call. Generator/async resumption swaps
    // heap buffers in and out of the stack, so those keep heap mode.
    const arena_eligible = fb.functionKind() == .normal and mode.generator_state == null;
    const arena_mark = if (arena_eligible) ctx.runtime.vm_stack.mark() else null;
    defer if (arena_mark) |mark| ctx.runtime.vm_stack.restore(mark);
    const operand_window: ?[]core.JSValue = if (arena_eligible)
        ctx.runtime.vm_stack.carve(ctx.runtime, @as(usize, fb.stack_size) + 1)
    else
        null;
    var nested_stack = if (operand_window) |window|
        stack_mod.Stack.initFrameWindow(ctx.runtime, ctx.runtime.stack.frame_storage, window)
    else
        stack_mod.Stack.init(ctx.runtime, ctx.runtime.stackSize());
    defer if (mode.generator_state) |generator| generator.finalizeGeneratorExecutionCompletion(ctx.runtime);
    defer nested_stack.deinit(ctx.runtime);
    // Async-generator bodies return their raw suspension/completion value to
    // the queue machine (exec/promise_ops.zig execBody) — no promise
    // wrapping here (qjs async_func_resume returns the raw value/ret code,
    // quickjs.c).
    return runWithCallEnvAfterInterruptPoll(.{
        .ctx = ctx,
        .stack = &nested_stack,
        .function = fb,
        .initial_this_value = this_value,
        .args = args,
        .var_refs = var_refs,
        .output = output,
        .global = global,
        .strict_unresolved_get_var = fb_runtime_strict,
        .stop_on_yield = stop_on_yield,
        .generator_state = mode.generator_state,
        .resume_value = mode.resume_value,
        .current_function_value = current_function_value,
        .new_target_value = mode.new_target_value,
        .call_depth_precharged = mode.call_depth_precharged or call_depth_guard != null,
        .copy_argv = mode.copy_argv,
    });
}

pub fn runGeneratorParameterInit(
    ctx: *core.JSContext,
    fb: *const bytecode.FunctionBytecode,
    prepared_entry_frame: ?*const zjs_vm.PreparedEntryFrame,
    object: *core.Object,
    current_function_value: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const *core.VarRef,
    output: ?*std.Io.Writer,
    call_depth_precharged: bool,
    call_entry_ctx: *core.JSContext,
    call_entry_global: *core.Object,
) !core.JSValue {
    var nested_stack = stack_mod.Stack.init(ctx.runtime, ctx.runtime.stackSize());
    defer object.finalizeGeneratorExecutionCompletion(ctx.runtime);
    defer nested_stack.deinit(ctx.runtime);
    // Canonical generators suspend on their explicit OP_initial_yield after
    // parameter initialization. Ordinary async functions have no such opcode:
    // keep their resident frame parked at pc 0 until the promise driver starts
    // the body. Empty packed fixtures likewise retain their pc-0 entry
    // contract without reintroducing a production bytecode scan.
    const stop_before_pc: ?usize = if (fb.functionKind() == .async or
        fb.byteCode().len == 0)
        0
    else
        null;
    const env: zjs_vm.CallEnv = .{
        .ctx = call_entry_ctx,
        .stack = &nested_stack,
        .function = fb,
        .initial_this_value = this_value,
        .args = args,
        .var_refs = var_refs,
        .output = output,
        .global = call_entry_global,
        .strict_unresolved_get_var = true,
        .generator_state = object,
        .stop_on_yield = stop_before_pc == null and
            (fb.functionKind() == .generator or fb.functionKind() == .async_generator),
        .stop_before_pc = stop_before_pc,
        .current_function_value = current_function_value,
        .prepared_entry_frame = prepared_entry_frame,
        .call_depth_precharged = true,
    };
    // QuickJS async_func_init only prepares the resident frame. Its first
    // async_func_resume below owns the single guard(0) -> interrupt-poll
    // entry; generators and async generators resume here to their initial
    // yield and therefore keep this entry preflight.
    if (fb.functionKind() == .async) {
        return runWithCallEnvAfterInterruptPoll(env);
    }
    const call_depth_guard = try zjs_vm.preflightResidentEntry(
        call_entry_ctx,
        call_entry_global,
        call_depth_precharged,
    );
    defer if (call_depth_guard) |guard| guard.deinit();
    return runWithCallEnvAfterInterruptPoll(env);
}

/// Sync generator object behind `receiver`, or null for any other value
/// (the caller reports GeneratorValidate's TypeError).
fn syncGeneratorObject(receiver: core.JSValue) ?*core.Object {
    const object = core.value_semantics.objectFromValue(receiver) orelse return null;
    return if (object.class_id == core.class.ids.generator) object else null;
}

/// Resumes a suspended sync generator frame with `completion`. Every resume
/// leg goes through here so the GeneratorValidate executing guard (§27.5.3.2
/// step 5) is always set: a next/return/throw re-entering from the body must
/// fail instead of resuming the frame that is already running.
fn resumeSyncGeneratorFrame(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    generator_global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    resume_value: core.JSValue,
    completion: core.generator_state.ResumeCompletion,
) !core.JSValue {
    const payload = object.generatorPayloadPtr();
    const execution = payload.execution orelse return error.TypeError;
    const function_value = generatorFunctionBytecodeFromExecution(object, execution) orelse return error.TypeError;
    const current_function_value = if (execution.current_function.is(.undefined_value)) receiver else execution.current_function;
    payload.resume_completion = completion;
    payload.executing = true;
    defer payload.executing = false;
    return callFunctionBytecodeModeState(
        ctx,
        function_value,
        current_function_value,
        execution.this_value,
        execution.suspended.storage.frame.args,
        execution.suspended.storage.frame.var_refs,
        output,
        generator_global,
        .{
            .defer_generators = false,
            .generator_state = object,
            .resume_value = resume_value,
        },
    ) catch |err| {
        object.completeGeneratorExecution(ctx.runtime);
        return err;
    };
}

/// Resumes the generator and builds its `{value, done}` result. A resume
/// that suspends inside `yield*` already produced the inner iterator's
/// result object, which passes through unchanged.
fn resumeSyncGenerator(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    generator_global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    resume_value: core.JSValue,
    completion: core.generator_state.ResumeCompletion,
) !core.JSValue {
    const result = try resumeSyncGeneratorFrame(ctx, output, generator_global, receiver, object, resume_value, completion);
    const payload = object.generatorPayloadPtr();
    const done = !payload.just_yielded;
    if (done) {
        object.completeGeneratorExecution(ctx.runtime);
    } else if (payload.yield_star_suspended) {
        return result;
    }
    return try iterator_ops.createIteratorResult(ctx.runtime, generator_global, generatorCatchResumeResultValue(result), done);
}

pub fn generatorNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
) !core.JSValue {
    const object = syncGeneratorObject(receiver) orelse return error.NotAGenerator;
    const payload = object.generatorPayloadPtr();
    if (payload.executing) return error.GeneratorRunning;
    const generator_global = object.generatorFunctionRealmGlobalPtr() orelse global;
    if (payload.done) {
        return try iterator_ops.createIteratorResult(ctx.runtime, generator_global, core.JSValue.undefinedValue(), true);
    }
    const resume_value = if (object.generatorPc() != 0 and args.len > 0) args[0] else core.JSValue.undefinedValue();
    return try resumeSyncGenerator(ctx, output, generator_global, receiver, object, resume_value, .next);
}

/// A raw generator step result: the yielded/returned value + done flag, with no
/// `{value, done}` iterator-result object built. The caller owns `value`.
pub const GeneratorValueDone = struct {
    value: core.JSValue,
    done: bool,
};

inline fn generatorFunctionBytecodeFromExecution(object: *core.Object, execution: *const core.object.GeneratorExecutionState) ?core.JSValue {
    const current = execution.current_function;
    if (current.is(.function_bytecode)) return current;
    const current_object = object_ops.objectFromValue(current) orelse return null;
    if (current_object == object) return null;
    return current_object.functionBytecode();
}

/// Resume a SYNC generator one step and return (value, done) WITHOUT allocating the
/// iterator-result object, so a for-of consumer can skip it (qjs JS_IteratorNext2
/// built-in fast path, quickjs.c). Returns null if `receiver` is not a sync
/// generator (caller falls back to the generic protocol). The yield*-delegation case
/// (result is ALREADY an iterator-result object) is unwrapped here with the same
/// done-then-conditional-value reads the generic for-of would do.
pub fn syncGeneratorStep(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
) !?GeneratorValueDone {
    const object = syncGeneratorObject(receiver) orelse return null;
    const payload = object.generatorPayloadPtr();
    if (payload.executing) return error.GeneratorRunning;
    if (payload.done) return .{ .value = core.JSValue.undefinedValue(), .done = true };
    const generator_global = object.generatorFunctionRealmGlobalPtr() orelse global;
    const result = try resumeSyncGeneratorFrame(ctx, output, generator_global, receiver, object, core.JSValue.undefinedValue(), .next);
    if (payload.just_yielded and payload.yield_star_suspended) {
        // yield* passthrough: `result` is already an iterator-result object — unwrap it
        // exactly as the generic for-of step would (read .done, then .value only if !done).
        const done_key = comptime core.atom.predefinedId("done", .string).?;
        const done_value = try object_ops.getValueProperty(ctx, output, global, result, done_key, null, null);
        const done = value_ops.isTruthy(done_value);
        if (done) return .{ .value = core.JSValue.undefinedValue(), .done = true };
        const value_key = comptime core.atom.predefinedId("value", .string).?;
        const value = try object_ops.getValueProperty(ctx, output, global, result, value_key, null, null);
        return .{ .value = value, .done = false };
    }
    // A finished generator's `result` is its return value, which an
    // iterator step reports as done with value undefined (destructuring
    // reads it; for-of never does).
    if (!payload.just_yielded) return .{ .value = core.JSValue.undefinedValue(), .done = true };
    return .{ .value = result, .done = false };
}

pub fn setGeneratorYieldStarSuspended(object: *core.Object, value: bool) void {
    object.generatorYieldStarSuspendedSlot().* = value;
}

pub fn setGeneratorResumeCompletion(object: *core.Object, completion: core.generator_state.ResumeCompletion) void {
    object.generatorResumeCompletionSlot().* = completion;
}

/// Generator.prototype.return / .throw: resume a started generator with an
/// abrupt completion, or complete one that has not started (or is done).
fn generatorAbruptCompletion(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
    completion: core.generator_state.ResumeCompletion,
) !core.JSValue {
    const object = syncGeneratorObject(receiver) orelse return error.NotAGenerator;
    const payload = object.generatorPayloadPtr();
    if (payload.executing) return error.GeneratorRunning;
    const generator_global = object.generatorFunctionRealmGlobalPtr() orelse global;
    const value = value_ops.argOrUndefined(args, 0);
    if (payload.yield_star_suspended or (object.generatorPc() != 0 and payload.started)) {
        return try resumeSyncGenerator(ctx, output, generator_global, receiver, object, value, completion);
    }
    object.completeGeneratorExecution(ctx.runtime);
    if (completion == .throw) {
        _ = ctx.throwValue(value);
        return error.JSException;
    }
    return try iterator_ops.createIteratorResult(ctx.runtime, generator_global, value, true);
}

pub fn generatorReturn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
) !core.JSValue {
    return generatorAbruptCompletion(ctx, output, global, receiver, args, .return_);
}

pub fn generatorThrow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
) !core.JSValue {
    return generatorAbruptCompletion(ctx, output, global, receiver, args, .throw);
}

pub fn generatorCatchResumeResultValue(result: core.JSValue) core.JSValue {
    return if (result.is(.catch_offset)) core.JSValue.undefinedValue() else result;
}

pub fn wrapIteratorFromIterator(ctx: *core.JSContext, global: *core.Object, iterator: core.JSValue, next_method: core.JSValue) !core.JSValue {
    var values = [_]core.JSValue{ iterator, next_method, core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var root_frame = core.runtime.ValueRootFrame{ .slices = &slices };
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    _ = object_ops.objectFromValue(values[0]) orelse return error.TypeError;
    values[2] = (try object_ops.wrapForValidIteratorPrototype(ctx.runtime, global)).value();
    values[3] = (try core.Object.create(ctx.runtime, core.class.ids.iterator_wrap, object_ops.objectFromValue(values[2]).?)).value();
    const wrapper = object_ops.objectFromValue(values[3]).?;
    try wrapper.setOptionalValueSlot(ctx.runtime, wrapper.iteratorTargetSlot(), values[0]);
    try wrapper.setOptionalValueSlot(ctx.runtime, wrapper.iteratorNextSlot(), values[1]);
    return wrapper.value();
}

test "wrapIteratorFromIterator roots direct function bytecode next method while creating wrapper" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    global.promoteToGlobalObjectClass(rt);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const iterator = try core.Object.create(rt, core.class.ids.object, null);

    const prototype = try core.Object.create(rt, core.class.ids.object, null);
    try builtin_glue.storeRealmValue(rt, global, .wrap_for_valid_iterator_prototype, prototype.value());

    const symbol_atom = try rt.atoms.newValueSymbol("gc-wrap-iterator-next-bytecode-symbol");
    const fb = try bytecode.FunctionBytecode.createPublishedFixture(rt, .{
        .flags = .{ .func_kind = .generator },
        .cpool_count = 1,
    }, &.{try rt.symbolValue(symbol_atom)});

    const next_method = core.JSValue.functionBytecode(&fb.header);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const wrapper_value = try wrapIteratorFromIterator(ctx, global, iterator.value(), next_method);
    const wrapper = object_ops.objectFromValue(wrapper_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = wrapper.iteratorNext() orelse return error.TypeError;
    try std.testing.expect(stored.same(next_method));

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn pollGCSafePoint(ctx: *core.JSContext) !void {
    _ = ctx.runtime.pollGC(.safepoint) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PayloadMarkFailed => return error.OutOfMemory,
    };
}

pub fn pollHostScheduler(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) HostError!bool {
    if (ctx.hostScheduler()) |scheduler| {
        return scheduler.poll(scheduler.ptr, ctx, output, global) catch |err| return @errorCast(err);
    }
    return false;
}

pub fn enqueuePendingMicrotask(ctx: *core.JSContext, callback: core.JSValue) !void {
    try promise_ops.enqueuePendingPromiseJob(ctx, callback);
}

test "iterator_ops.createIteratorResult roots direct function bytecode value while creating result" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    global.promoteToGlobalObjectClass(rt);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;

    const symbol_atom = try rt.atoms.newValueSymbol("gc-iterator-result-bytecode-symbol");
    const fb = try bytecode.FunctionBytecode.createPublishedFixture(rt, .{ .cpool_count = 1 }, &.{try rt.symbolValue(symbol_atom)});

    const result_value = core.JSValue.functionBytecode(&fb.header);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const iterator_result_value = try iterator_ops.createIteratorResult(rt, global, result_value, false);
    const iterator_result = object_ops.objectFromValue(iterator_result_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_atom = try rt.internAtom("value");
    {
        const stored = try iterator_result.getProperty(value_atom);
        try std.testing.expect(stored.same(result_value));
    }

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn throwTypeErrorIntrinsicForGlobal(rt: *core.JSRuntime, global: *core.Object) !core.JSValue {
    if (global.cachedThrowTypeErrorIntrinsic(rt)) |stored| return stored;

    const thrower = try core.function.nativeFunctionForGlobal(rt, global, "", 0);
    const thrower_object = try property_ops.expectObject(thrower);
    try thrower_object.setFunctionRealmGlobalPtr(rt, global);
    if (object_ops.functionPrototypeFromGlobal(global)) |function_prototype| {
        try thrower_object.setPrototype(rt, function_prototype);
    }

    try thrower_object.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(0), .none));
    const empty_name = try value_ops.createStringValue(rt, "");
    try thrower_object.defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.data(empty_name, .none));
    try thrower_object.addThrowTypeErrorIntrinsicFunction(rt);
    try thrower_object.freeze(rt);

    try object_ops.installFunctionPrototypeThrowTypeErrorAccessors(rt, global, thrower);
    try global.setCachedRealmValue(rt, .throw_type_error_intrinsic, thrower);
    return thrower;
}

pub fn throwTypeErrorIntrinsic(ctx: *core.JSContext, global: *core.Object) !core.JSValue {
    const error_value = try exception_ops.createNamedError(ctx, global, "TypeError", "'caller', 'callee' and 'arguments' are restricted in this context");
    _ = ctx.throwValue(error_value);
    return error.JSException;
}

pub fn currentFrameFunctionIsStrict(frame: *frame_mod.Frame) bool {
    if (frame.function.isStrictMode() or frame.function.runtimeStrictMode()) return true;
    const fb = if (functionBytecodeFromValue(frame.current_function)) |bytecode_value|
        bytecode_value
    else if (object_ops.objectFromValue(frame.current_function)) |function_object|
        if (function_object.functionBytecode()) |stored| functionBytecodeFromValue(stored) else null
    else
        null;
    if (fb) |function_bytecode| return function_bytecode.isStrictMode() or function_bytecode.runtimeStrictMode();
    return false;
}

pub fn functionBytecodeFromValue(value: core.JSValue) ?*const bytecode.FunctionBytecode {
    const header = value.functionBytecodeHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

pub fn isConstructibleFunctionBytecode(fb: *const bytecode.FunctionBytecode) bool {
    return fb.hasPrototype() and
        fb.functionKind() == .normal;
}

pub fn isConstructibleBytecodeFunctionObject(function_object: *const core.Object, fb: *const bytecode.FunctionBytecode) bool {
    return function_object.class_id == core.class.ids.bytecode_function and isConstructibleFunctionBytecode(fb);
}

test "four-class bytecode constructability follows class and function flags" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const Case = struct {
        class_id: core.ClassId,
        func_kind: bytecode.function_bytecode.FunctionKind,
        has_prototype: bool,
        expected_constructor: bool,
    };
    const Fixture = struct {
        fn create(runtime: *core.JSRuntime, case: Case) !*core.Object {
            const object = try core.Object.create(runtime, case.class_id, null);

            const fb = try bytecode.FunctionBytecode.createFixture(runtime, .{ .flags = .{
                .func_kind = case.func_kind,
                .has_prototype = case.has_prototype,
            } });
            fb.publishFixtureNoFail(runtime);
            try object.setFunctionBytecodeValue(runtime, core.JSValue.functionBytecode(&fb.header));
            return object;
        }
    };
    const cases = [_]Case{
        .{ .class_id = core.class.ids.bytecode_function, .func_kind = .normal, .has_prototype = true, .expected_constructor = true },
        // Canonical arrows are ordinary-kind bytecode functions without a
        // prototype. The parser invariant is covered by the F6 arrow tests;
        // do not manufacture an impossible prototype-bearing arrow here.
        .{ .class_id = core.class.ids.bytecode_function, .func_kind = .normal, .has_prototype = false, .expected_constructor = false },
        .{ .class_id = core.class.ids.generator_function, .func_kind = .generator, .has_prototype = true, .expected_constructor = false },
        .{ .class_id = core.class.ids.async_function, .func_kind = .async, .has_prototype = false, .expected_constructor = false },
        .{ .class_id = core.class.ids.async_generator_function, .func_kind = .async_generator, .has_prototype = true, .expected_constructor = false },
    };

    for (cases) |case| {
        const function_object = try Fixture.create(rt, case);
        try std.testing.expect(core.class.isFunctionClass(case.class_id));
        try std.testing.expectEqual(case.expected_constructor, isConstructorLike(function_object.value()));
    }
}

pub fn isConstructorLike(bound_or_value: core.JSValue) bool {
    // A bound function is a constructor exactly when its target is; walk the
    // chain iteratively so it cannot exhaust the native stack. A proxy's
    // answer was fixed by ProxyCreate.
    var value = bound_or_value;
    while (object_ops.objectFromValue(value)) |object| {
        if (object.class_id == core.class.ids.bound_function) {
            value = object.boundTarget() orelse return false;
        } else if (object.isProxy()) {
            return object.proxyIsConstructor();
        } else break;
    }
    if (value.is(.function_bytecode)) {
        const fb = functionBytecodeFromValue(value) orelse return false;
        return isConstructibleFunctionBytecode(fb);
    }
    if (object_ops.functionObjectFromValue(value)) |function_object| {
        const function_value = function_object.functionBytecode() orelse return false;
        const fb = functionBytecodeFromValue(function_value) orelse return false;
        return isConstructibleBytecodeFunctionObject(function_object, fb);
    }
    if (object_ops.callableObjectFromValue(value)) |function_object| {
        if (function_object.class_id == core.class.ids.c_function_data or
            core.class.isAsyncFunctionResumeClass(function_object.class_id)) return false;
        if (function_object.flags.is_html_dda) return false;
        if (function_object.isHostEntryFunction()) {
            const entry = function_object.nativeEntry() orelse return false;
            return entry.flags.host_constructor;
        }
        if (function_object.nativeConstructorKind() != .none) return true;
        // A function carrying a construct-capable builtin native id is a
        // constructor too.
        const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse return false;
        return builtin_dispatch.isConstructRecordRef(native_ref);
    }
    return false;
}

pub fn callBoundFunction(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    // Each level of a bound chain is a native call frame.
    if (ctx.runtime.stack.checkNativeOverflow(0)) return error.StackOverflow;
    const target = object.boundTarget() orelse return error.TypeError;
    const bound_this = object.boundThis() orelse return error.TypeError;
    const combined = try boundFunctionArgs(ctx.runtime, object, args);
    defer freeArgs(ctx.runtime, combined);
    return callValueOrBytecodeRoot(ctx, output, global, bound_this, target, combined, caller_function, caller_frame);
}

pub fn boundFunctionArgs(rt: *core.JSRuntime, object: *core.Object, args: []const core.JSValue) ![]core.JSValue {
    const bound_args = object.boundArgs();
    const bound_count = bound_args.len;
    if (bound_count == 0 and args.len == 0) return &.{};
    // The combined list obeys the same cap as every other argument list.
    if (bound_count + args.len > array_ops.max_apply_arguments) return error.TooManyArguments;
    const combined = try rt.allocNative(core.JSValue, bound_count + args.len);
    errdefer rt.nativeAllocator().free(combined);
    for (bound_args, 0..) |arg, index| {
        combined[index] = arg;
    }
    for (args, 0..) |arg, arg_index| {
        combined[bound_count + arg_index] = arg;
    }
    return combined;
}

pub fn throwPrivateBrandTypeError(
    ctx: *core.JSContext,
    global: *core.Object,
    atom_id: core.Atom,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const error_global = if (caller_frame) |frame| blk: {
        const function_object = object_ops.objectFromValue(frame.current_function) orelse break :blk global;
        break :blk object_ops.objectRealmGlobal(function_object) orelse global;
    } else global;
    const atom_name = ctx.runtime.atoms.name(atom_id) orelse "";
    const message = try std.fmt.allocPrint(
        ctx.runtime.nativeAllocator(),
        "private class field '{s}' does not exist",
        .{atom_name},
    );
    defer ctx.runtime.nativeAllocator().free(message);
    return exception_ops.throwTypeErrorMessage(ctx, error_global, message);
}

pub const SetFailureError = error{
    AccessorWithoutSetter,
    IncompatibleDescriptor,
    NotExtensible,
    ReadOnly,
    TypeError,
};

pub fn throwSetFailureTypeError(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom, reason: SetFailureError) !core.JSValue {
    const static_message = switch (reason) {
        error.AccessorWithoutSetter => "no setter for property",
        error.NotExtensible => "object is not extensible",
        else => null,
    };
    if (static_message) |message| return exception_ops.throwTypeErrorMessage(ctx, global, message);

    // A generic [[Set]] failure (proxy trap, receiver accessor) is not a
    // read-only property.
    const read_only = @as(anyerror, reason) != error.TypeError;
    if (ctx.runtime.atoms.name(atom_id)) |name| {
        const message = if (read_only)
            try std.fmt.allocPrint(ctx.runtime.nativeAllocator(), "'{s}' is read-only", .{name})
        else
            try std.fmt.allocPrint(ctx.runtime.nativeAllocator(), "cannot set property '{s}'", .{name});
        defer ctx.runtime.nativeAllocator().free(message);
        return exception_ops.throwTypeErrorMessage(ctx, global, message);
    }
    return exception_ops.throwTypeErrorMessage(ctx, global, if (read_only) "property is read-only" else "cannot set property");
}

pub fn setFailureShouldThrow(caller_function: ?*const bytecode.FunctionBytecode) bool {
    if (caller_function) |function| return functionRuntimeStrict(function);
    return false;
}

pub fn functionRuntimeStrict(function: *const bytecode.FunctionBytecode) bool {
    return function.isStrictMode() or function.runtimeStrictMode();
}

pub fn ordinarySetWithReceiver(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target: *core.Object,
    receiver_value: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!bool {
    // OrdinarySet walks the prototype chain until an own descriptor, a proxy,
    // or the end; iterate so a long chain cannot exhaust the native stack.
    var current = target;
    while (true) {
        if (current.proxyTarget() != null) {
            return object_ops.proxySetValueProperty(ctx, output, global, receiver_value, current, atom_id, value, caller_function, caller_frame);
        }
        if (try array_ops.typedArrayPrototypeSet(ctx, output, global, receiver_value, current.getPrototype(), atom_id, value, caller_function, caller_frame)) |ok| return ok;
        // `__proto__` needs no special case: %Object.prototype%'s accessor is
        // an ordinary own descriptor, found only if the chain reaches it.
        if (try current.getOwnProperty(ctx.runtime, atom_id)) |own_desc| {
            return object_ops.setWithOwnDescriptor(ctx, output, global, receiver_value, atom_id, value, own_desc, caller_function, caller_frame);
        }
        current = current.getPrototype() orelse break;
    }
    return object_ops.setWithOwnDescriptor(ctx, output, global, receiver_value, atom_id, value, core.Descriptor.data(core.JSValue.undefinedValue(), .all), caller_function, caller_frame);
}

pub fn definePropertiesCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 2) return error.NullishToObject;
    const target = core.value_semantics.objectFromValue(args[0]) orelse return @as(?core.JSValue, try exception_ops.throwTypeErrorMessage(ctx, global, "not an object"));
    try definePropertiesOnTarget(ctx, output, global, target, args[1], caller_function, caller_frame);
    return args[0];
}

pub const IntegrityLevel = enum {
    sealed,
    frozen,
};

/// Root provider for the `definePropertiesOnTarget` staging list; see the
/// activation site for why the list needs one.
const PendingDescriptorRoots = struct {
    runtime: *core.JSRuntime,
    list: *std.ArrayList(object_ops.PendingPropertyDescriptor),
    registered: bool = false,

    fn traceRoots(context: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        const self: *PendingDescriptorRoots = @ptrCast(@alignCast(context));
        for (self.list.items) |*entry| {
            try visitor.atomRoot(entry.atom_id);
            try visitor.value(&entry.desc.value);
            try visitor.value(&entry.desc.getter);
            try visitor.value(&entry.desc.setter);
        }
    }

    fn provider(self: *PendingDescriptorRoots) core.runtime.RootProvider {
        return .{ .context = @ptrCast(self), .trace = traceRoots };
    }

    inline fn activate(self: *PendingDescriptorRoots) !void {
        try self.runtime.registerRootProvider(self.provider());
        self.registered = true;
    }

    fn deactivate(self: *PendingDescriptorRoots) void {
        if (!self.registered) return;
        self.runtime.unregisterRootProvider(self.provider());
        self.registered = false;
    }
};

pub fn definePropertiesOnTarget(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target: *core.Object,
    properties_arg: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (properties_arg.is(.null_value) or properties_arg.is(.undefined_value)) return error.NullishToObject;
    // The target is not necessarily published yet (Object.create). Keep the
    // borrowed ABI inputs stable throughout both collection and installation.
    const borrowed = [_]core.JSValue{ global.value(), target.value(), properties_arg };
    var values = [_]core.JSValue{core.JSValue.undefinedValue()};
    const live: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{ .{ .borrowed = &borrowed }, .{ .mutable = &live } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    values[0] = if (object_ops.objectFromValue(properties_arg)) |_| properties_arg else try object_ops.primitiveObjectForAccess(ctx.runtime, global, properties_arg);
    const properties = object_ops.objectFromValue(values[0]) orelse return error.TypeError;

    const keys = try object_ops.objectRestOwnKeys(ctx, output, global, properties);
    defer core.Object.freeKeys(ctx.runtime, keys);
    // TGC S3 §4 class B: the snapshot is a native []Atom held across every
    // descriptor read below, each of which can reach a proxy trap.
    var keys_roots = core.runtime.rootAtomList(&keys);
    keys_roots.activate(ctx.runtime);
    defer keys_roots.deactivate(ctx.runtime);

    var pending = std.ArrayList(object_ops.PendingPropertyDescriptor).empty;
    defer pending.deinit(ctx.runtime.nativeAllocator());
    // TGC S3 §2.2 root G: `PendingPropertyDescriptor` is a frame-resident atom
    // box, and its heap-allocated backing array is visible to neither the
    // value-root frames nor the conservative stack scan. A root provider
    // reports the ids and the descriptor values
    // the list is still holding; converting `atom_id` to a body JSValue would
    // mean rewriting every defineOwnProperty seam it feeds.
    var pending_roots = PendingDescriptorRoots{ .runtime = ctx.runtime, .list = &pending };
    try pending_roots.activate();
    defer pending_roots.deactivate();

    for (keys) |key| {
        const prop_desc = try object_ops.objectRestOwnPropertyDescriptor(ctx, output, global, object_ops.objectFromValue(values[0]).?, key) orelse continue;
        if (prop_desc.enumerable != true) continue;

        const desc_value = try object_ops.getValueProperty(ctx, output, global, values[0], key, caller_function, caller_frame);
        const desc_object = object_ops.objectFromValue(desc_value) orelse return error.InvalidPropertyDescriptor;
        const desc = try object_ops.descriptorFromObject(ctx, output, global, desc_value, desc_object, target, key, caller_function, caller_frame);
        try pending.append(ctx.runtime.nativeAllocator(), .{ .atom_id = key, .desc = desc });
    }

    for (pending.items) |item| {
        const defined = try object_ops.defineOwnPropertyVm(ctx, output, global, target, item.atom_id, item.desc, .keep_error, caller_function, caller_frame);
        if (!defined) return error.CannotDefineProperty;
    }
}

pub fn callAccessorSetter(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (try object_ops.findPropertyDescriptor(ctx.runtime, object, atom_id)) |desc| {
        if (desc.kind != .accessor) return false;
        if (desc.setter.is(.undefined_value)) return error.AccessorWithoutSetter;
        // K3 native setter: direct native terminal (design §8.2).
        if (builtin_dispatch.tryNativeAccessorCall(ctx, output, global, receiver, desc.setter, &.{value}, caller_function, caller_frame, .setter)) |native_result| {
            _ = try native_result;
            return true;
        }
        _ = try callValueOrBytecodeSyncInternalOutlined(ctx, output, global, receiver, desc.setter, &.{value}, caller_function, caller_frame);
        return true;
    }
    return false;
}

pub fn inOp(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    output: ?*std.Io.Writer,
    global: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const rhs = try stack.pop();
    const lhs = try stack.pop();
    const object = core.value_semantics.objectFromValue(rhs) orelse {
        _ = try exception_ops.throwTypeErrorMessage(ctx, global, "invalid 'in' operand");
        unreachable;
    };
    const key = try object_ops.toPropertyKeyAtom(ctx, output, global, lhs, caller_function, caller_frame);
    const found = if (object.proxyTarget() != null)
        try object_ops.hasValueProperty(ctx, output, global, object, key, caller_function, caller_frame)
    else
        try object_ops.ordinaryHasValueProperty(ctx, output, global, object, key, caller_function, caller_frame);
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(found));
}

pub fn instanceofOp(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    output: ?*std.Io.Writer,
    global: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const rhs = try stack.pop();
    const lhs = try stack.pop();
    const result = try instanceofValue(ctx, output, global, lhs, rhs, caller_function, caller_frame);
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(result));
}

/// Value-level `JS_IsInstanceOf` twin for the register-resident opcode shell.
/// The caller keeps both borrowed operands rooted until this returns; the
/// helper owns only the values it obtains from property lookup/call results.
pub fn instanceofValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    lhs: core.JSValue,
    rhs: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!bool {
    _ = core.value_semantics.objectFromValue(rhs) orelse {
        _ = try exception_ops.throwTypeErrorMessage(ctx, global, "invalid 'instanceof' right operand");
        unreachable;
    };
    const has_instance = try instanceofMethod(ctx, output, global, rhs, caller_function, caller_frame);
    return instanceofValueWithMethod(ctx, output, global, lhs, rhs, has_instance, caller_function, caller_frame);
}

pub fn instanceofMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rhs: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    // qjs names this atom as the constant JS_ATOM_Symbol_hasInstance.
    // Resolve it at comptime rather than hashing the spelling
    // through the predefined-symbol map on every `instanceof`.
    const has_instance_atom = comptime core.atom.predefinedId("Symbol.hasInstance", .symbol).?;
    const fast = object_ops.probeNamedDataProperty(ctx.runtime, rhs, has_instance_atom);
    if (fast.slot) |slot| return slot.*;
    if (!fast.needs_slow) return core.JSValue.undefinedValue();
    return instanceofMethodSlow(ctx, output, global, rhs, caller_function, caller_frame);
}

pub noinline fn instanceofMethodSlow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rhs: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const has_instance_atom = comptime core.atom.predefinedId("Symbol.hasInstance", .symbol).?;
    return object_ops.getValueProperty(ctx, output, global, rhs, has_instance_atom, caller_function, caller_frame);
}

pub fn instanceofValueWithMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    lhs: core.JSValue,
    rhs: core.JSValue,
    has_instance: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!bool {
    if (!has_instance.is(.undefined_value) and !has_instance.is(.null_value)) {
        const result = try callValueOrBytecodeRoot(ctx, output, global, rhs, has_instance, &.{lhs}, caller_function, caller_frame);
        return value_ops.valueTruthy(result);
    }
    if (!isCallableValue(rhs)) {
        _ = try exception_ops.throwTypeErrorMessage(ctx, global, "invalid 'instanceof' right operand");
        unreachable;
    }
    return ordinaryHasInstance(ctx, output, global, rhs, lhs, caller_function, caller_frame);
}

/// A native function's name: its dispatch name, else a string own `name`.
/// Null when it has neither.
pub fn nativeFunctionName(rt: *core.JSRuntime, object: *core.Object) !?core.JSValue {
    const dispatch_atom = object.nativeDispatchName();
    if (dispatch_atom != core.atom.null_atom) {
        const dispatch_name = try rt.atoms.toStringValue(rt, dispatch_atom);
        if (dispatch_name.isString()) return dispatch_name;
    }
    const name_value = try object.getProperty(core.atom.ids.name);
    return if (name_value.isString()) name_value else null;
}

pub fn isBlockedByUnscopables(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object_value: core.JSValue,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    const unscopables_atom = comptime core.atom.predefinedId("Symbol.unscopables", .symbol).?;
    const unscopables = try object_ops.getValueProperty(ctx, output, global, object_value, unscopables_atom, caller_function, caller_frame);
    if (!unscopables.is(.object)) return false;
    const blocked = try object_ops.getValueProperty(ctx, output, global, unscopables, atom_id, caller_function, caller_frame);
    return value_ops.valueTruthy(blocked);
}

pub fn closureVarIsNonLexicalGlobalSentinel(function: *const bytecode.FunctionBytecode, idx: usize) bool {
    if (idx >= function.closureVar().len) return false;
    const cv = function.closureVar()[idx];
    if (cv.isLexical()) return false;
    return switch (cv.closureType()) {
        .global, .global_ref, .global_decl => true,
        else => false,
    };
}

pub fn atomIdOrNameEql(rt: *core.JSRuntime, left: core.Atom, right: core.Atom) bool {
    if (left == right) return true;
    const left_name = rt.atoms.name(left) orelse return false;
    const right_name = rt.atoms.name(right) orelse return false;
    return std.mem.eql(u8, left_name, right_name);
}

pub fn functionNameValueFromAtom(rt: *core.JSRuntime, atom_id: core.Atom, prefix: ?[]const u8) !core.JSValue {
    // qjs JS_AtomToString duplicates the atom's string body directly. The
    // common function-declaration/expression case has no prefix and no public
    // Symbol bracket syntax, so use the AtomTable's identical cached-string
    // conversion instead of allocating an ArrayList plus a fresh JSString for
    // every closure. Prefix and public-Symbol names still need composition.
    if (prefix == null and !rt.atoms.isPublicSymbol(atom_id)) {
        return rt.atoms.toStringValueForPush(rt, atom_id);
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    if (prefix) |text| {
        try bytes.appendSlice(rt.nativeAllocator(), text);
        try bytes.append(rt.nativeAllocator(), ' ');
    }
    if (atom_id.isTaggedInt()) {
        var buf: [std.fmt.count("{d}", .{std.math.maxInt(u32)})]u8 = undefined;
        // buf is sized by std.fmt.count for the widest value
        const text = std.fmt.bufPrint(&buf, "{d}", .{atom_id.toUInt32()}) catch unreachable;
        try bytes.appendSlice(rt.nativeAllocator(), text);
        return value_ops.createStringValue(rt, bytes.items);
    }
    const atom_name = rt.atoms.name(atom_id) orelse "";
    if (rt.atoms.isPublicSymbol(atom_id)) {
        if (core.symbol.description(rt, atom_id)) |description| {
            try bytes.append(rt.nativeAllocator(), '[');
            try bytes.appendSlice(rt.nativeAllocator(), description);
            try bytes.append(rt.nativeAllocator(), ']');
        }
    } else {
        try bytes.appendSlice(rt.nativeAllocator(), atom_name);
    }
    return value_ops.createStringValue(rt, bytes.items);
}

pub fn mappedArgumentsValue(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) ?core.JSValue {
    if (object.class_id != core.class.ids.mapped_arguments) return null;
    const index = core.array.arrayIndexFromAtom(rt.atoms, atom_id) orelse return null;
    const refs = object.argumentsVarRefs();
    if (index >= refs.len) return null;
    const cell = refs[index] orelse return null;
    if (!object.hasOwnProperty(atom_id)) return null;
    return cell.varRefValue();
}

pub fn setMappedArgumentsValue(ctx: *core.JSContext, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !bool {
    if (object.class_id != core.class.ids.mapped_arguments) return false;
    const index = core.array.arrayIndexFromAtom(ctx.runtime.atoms, atom_id) orelse return false;
    const refs = object.argumentsVarRefsMut();
    if (index >= refs.len) return false;
    const cell = refs[index] orelse return false;
    if (!object.hasOwnProperty(atom_id)) {
        refs[index] = null;
        return false;
    }
    cell.setVarRefValue(ctx.runtime, value);
    return true;
}

pub fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
