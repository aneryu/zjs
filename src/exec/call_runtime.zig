//! VM call/construct routing and the runtime machinery around call frames.
//!
//! Callees and arguments borrowed from the operand stack remain frame-rooted
//! until their region is released; results pushed with `pushOwned` transfer one
//! owned reference. The alias wall keeps extracted subsystems behind their
//! established names without recreating a dependency cycle. The explicit
//! `ctx`/`output`/`global`/caller-function/caller-frame tuple is a measured ABI:
//! `global` is the call's realm authority, and publishing these scalars through
//! shared VM/context state regresses the hot path. Hot dispatch arms therefore
//! stay separate from cold catch and fallback bodies. Mirrors JS_CallInternal
//! and constructor dispatch around quickjs.c:20817-20951.

const regexp_properties = @import("../libs/unicode.zig").regexp_properties;
const std = @import("std");
const function_ops = @import("function_ops.zig");
const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const parser = @import("../parser.zig");
const unicode_lib = @import("../libs/unicode.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call_mod = @import("call.zig");
const construct_mod = @import("construct.zig");
const date_ops = @import("date_ops.zig");
const exception_ops = @import("exception_ops.zig");
const frame_mod = @import("frame.zig");
const iterator_ops = @import("iterator_ops.zig");
const inline_calls = @import("inline_calls.zig");
const property_ops = @import("property_ops.zig");
const zjs_vm = @import("zjs_vm.zig");
const vm_call = @import("vm_call.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");
const HostError = exceptions.HostError;
const op = bytecode.opcode.op;
const runWithArgs = zjs_vm.runWithArgs;
const runWithCallEnv = zjs_vm.runWithCallEnv;
const runWithCallEnvAfterInterruptPoll = zjs_vm.runWithCallEnvAfterInterruptPoll;
const exceptions = @import("exceptions.zig");

const string_ops = @import("string_ops.zig");

const array_ops = @import("array_ops.zig");

const promise_ops = @import("promise_ops.zig");

const async_generator = @import("async_generator.zig");

const object_ops = @import("object_ops.zig");

// --- for-in/for-of iterator helpers moved to forof_ops.zig ---
const forof_ops = @import("forof_ops.zig");

const coercion_ops = @import("coercion_ops.zig");

// --- Builtin glue moved to builtin_glue.zig ---
const builtin_glue = @import("builtin_glue.zig");

// --- Local/arg/var-ref slot ops moved to slot_ops.zig ---
const slot_ops = @import("slot_ops.zig");
const value_slot = @import("value_slot.zig");

// --- Direct eval execution moved to eval_ops.zig ---
const eval_ops = @import("eval_ops.zig");

const atomics_wait = @import("atomics_wait.zig");

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
        if (inline_calls.resolveInlineTarget(ctx, global, core.JSValue.undefinedValue(), func)) |target| {
            req_out.* = .{ .target = target, .region_base = region_base, .argc = argc };
            return .inline_call;
        }
    }

    // OP_call is never a constructor call. Legal super() is emitted as
    // call_constructor (or apply(1)); superclass identity alone cannot grant a
    // normal call permission to invoke a class constructor.
    const result = callValueOrBytecodeRootPreRootedInternal(ctx, output, global, core.JSValue.undefinedValue(), func, args, function, frame) catch |err| {
        popOwnedStackRegion(ctx.runtime, stack, region_base);
        try forof_ops.closeStackTopForOfIteratorForPendingError(ctx, output, global, stack);
        if (try handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) {
            return .continue_loop;
        }
        return err;
    };
    popOwnedStackRegion(ctx.runtime, stack, region_base);
    stack.pushOwnedAssumeCapacity(result);
    return .done;
}

/// Pop and release every owned value above `region_base` on the operand
/// stack. Used by the zero-copy call sequence to drop the borrowed
/// `func | args...` region once a call completes.
pub fn popOwnedStackRegion(rt: *core.JSRuntime, stack: *stack_mod.Stack, region_base: usize) void {
    // Mirror qjs OP_call_method teardown (quickjs.c:18232): `call_argv` is a
    // register-held local and the loop just `JS_FreeValue(call_argv[i])` — no
    // per-slot poison-store and no re-derivation of the operand-stack base.
    // This helper is reached only while the owning bytecode Machine is active,
    // so the runtime cannot be in teardown. `freeDuringActiveBytecode` keeps
    // QuickJS's tag/refcount/zero-ref behavior while omitting that impossible
    // per-value phase probe. Destruction cannot push to this operand stack, so
    // `stack.values` remains loop-invariant. Slots above the shrunk length are
    // logically dead — every `push*` overwrites its target and GC scans only
    // `values[0..len]` — so the qjs form omits the undefined poison-store.
    const base = stack.values;
    var index = stack.len();
    while (index > region_base) {
        index -= 1;
        base[index].freeDuringActiveBytecode(rt);
    }
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
    err: anytype,
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
    err: anytype,
) !bool {
    if (ctx.exceptionIsUncatchable()) return false;
    const is_pending_exception = exception_ops.pendingExceptionMatchesError(ctx, err);
    const error_info = if (is_pending_exception) null else exception_ops.runtimeErrorInfo(err) orelse return false;
    // Run before testing the local catch target: an uncaught abrupt completion
    // must close this frame's live pattern/loop iterators before the frame is
    // unwound. IteratorNext marks only its failing record undefined before it
    // reaches this seam, so enclosing pattern iterators still close normally.
    try forof_ops.closeStackTopForOfIteratorForPendingErrorWithFrame(ctx, output, global, stack, frame);
    const target = catch_target.* orelse return false;
    try stack.reserveAdditional(1);
    var catch_value: core.JSValue = if (is_pending_exception)
        ctx.takeException()
    else
        exception_ops.createNamedError(ctx, global, error_info.?.name, error_info.?.message) catch |create_err| blk: {
            // A fully exhausted heap cannot materialize a fresh error object;
            // fall back to the preallocated out-of-memory exception so the
            // JS catch handler still runs (allocation-free dup). This is the
            // delivery point of the documented no-stack exemption: the
            // preallocated error is dup()ed, never rebuilt, so no stack can
            // be captured here.
            if (create_err == error.OutOfMemory) {
                if (ctx.preallocated_oom_error) |prealloc| break :blk prealloc.dup();
            }
            return create_err;
        };
    var catch_value_owned = true;
    errdefer if (catch_value_owned) {
        if (is_pending_exception) {
            _ = ctx.throwValue(catch_value);
        } else {
            catch_value.free(ctx.runtime);
        }
    };
    if (!is_pending_exception and ctx.hasException()) ctx.clearException();
    const restored = (try array_ops.popCatchMarker(ctx.runtime, stack)) orelse null;
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
    var inline_args: [8]core.JSValue = undefined;
    var args_buffer: core.runtime.ValueRootBuffer = .{};
    defer args_buffer.deinit(ctx.runtime);
    var rooted_args: []core.JSValue = inline_args[0..0];
    if (args.len <= inline_args.len) {
        rooted_args = inline_args[0..args.len];
        @memcpy(rooted_args, args);
    } else {
        args_buffer = try core.runtime.ValueRootBuffer.initCopy(ctx.runtime, args);
        rooted_args = args_buffer.values;
    }
    return callValueOrBytecodeDispatch(ctx, output, global, this_value, func, rooted_args, caller_function, caller_frame, true);
}

/// Eagerly coerce a receiver for suspended async/generator state, whose `this`
/// slot currently lives outside the active Frame. Ordinary normal bytecode
/// calls retain raw `this` and materialize it when first observed.
pub fn coerceCallThis(
    ctx: *core.JSContext,
    global: *core.Object,
    runtime_strict: bool,
    this_value: core.JSValue,
    boxed_out: *?core.JSValue,
) HostError!core.JSValue {
    if (runtime_strict) return this_value;
    if (this_value.isUndefined() or this_value.isNull()) return global.value();
    if (!this_value.isObject()) {
        const boxed = try object_ops.primitiveObjectForAccess(ctx.runtime, global, this_value);
        boxed_out.* = boxed;
        return boxed;
    }
    return this_value;
}

pub fn callNativeBuiltinRecordForVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    func: core.JSValue,
    this_value: core.JSValue,
    function_object: *core.Object,
    native_ref: core.function.NativeBuiltinRef,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    // `func` is the function value; the table dispatch only needs the function
    // object (`function_object`), so the raw value is no longer consulted here.
    _ = func;
    // Route the VM hot path through the same exec-owned internal record
    // table the slow record dispatch uses (`call.zig:callNativeFunctionRecord`),
    // so this generic call Module carries zero compile-time knowledge of domains. The
    // VM call site only has the caller `global` object (no legacy slot array),
    // so pass it with an empty slice. Observable handlers ignore both as realm
    // authorities and consume the final callable view; only explicitly
    // func-object-free synthetic record reuse can retain supplied legacy data.
    if (ctx.runtime.internalBuiltinRecord(@intCast(@intFromEnum(native_ref.domain)), native_ref.id)) |record| {
        if (function_object.class_id == core.class.ids.c_function) {
            try builtin_dispatch.preflightCFunctionCall(ctx, global, function_object, record.length);
            const view = try builtin_dispatch.finalCallableRealmView(ctx, function_object);
            return try builtin_dispatch.callInternalRecordDirectInRealm(view, output, function_object, this_value, record, args, caller_function, caller_frame);
        }
        return try builtin_dispatch.callInternalRecordDirect(ctx, output, global, &.{}, function_object, this_value, record, args, caller_function, caller_frame);
    }
    // Host builtins are exec-owned integer records too, but unlike standard
    // builtins they do not live in rt.internal_builtins. Dispatch them by id
    // here instead of falling through to the legacy function-name cascade.
    if (native_ref.domain == .host) {
        const view = try builtin_dispatch.finalCallableRealmView(ctx, function_object);
        return try call_mod.callHostGlobalNativeFunctionRecord(view.realm, view.global, this_value, function_object, native_ref.id, args);
    }
    // Standard-native domains are table-dispatched. A null result now only
    // identifies an invalid or stale standard-native id for the caller to
    // classify.
    return null;
}

pub fn throwRuntimeErrorForGlobal(ctx: *core.JSContext, global: *core.Object, err: anytype) !void {
    if (exception_ops.pendingExceptionMatchesError(ctx, err)) return;
    const error_info = exception_ops.runtimeErrorInfo(err) orelse return;
    const error_value = try exception_ops.createNamedError(ctx, global, error_info.name, error_info.message);
    if (ctx.hasException()) ctx.clearException();
    _ = ctx.throwValue(error_value);
}

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
    return callValueOrBytecodeDispatch(ctx, output, global, this_value, func, args, caller_function, caller_frame, true);
}

/// Bytecode-opcode call whose argument window is already rooted. Unlike the
/// C-API/JS_Call-shaped helper above, OP_call and shadowed OP_eval pass
/// flags=0 and may borrow argv when the actual arity already covers formals.
pub fn callValueOrBytecodeRootPreRootedInternal(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    return callValueOrBytecodeDispatch(ctx, output, global, this_value, func, args, caller_function, caller_frame, false);
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
    return callValueOrBytecodeDispatchAfterInterruptPoll(ctx, output, global, this_value, func, args, caller_function, caller_frame, false);
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

    fn init(
        self: *OwnedArgList,
        rt: *core.JSRuntime,
        receiver: core.JSValue,
        callable: core.JSValue,
        args: []const core.JSValue,
    ) HostError!void {
        std.debug.assert(self.rt == null);
        const total = try std.math.add(usize, args.len, 2);
        self.rt = rt;
        self.values = if (total <= self.inline_values.len)
            self.inline_values[0..total]
        else blk: {
            self.heap_backed = true;
            break :blk try rt.memory.alloc(core.JSValue, total);
        };
        self.rooted_prefix = self.values[0..0];
        self.root.init(rt, &self.rooted_prefix);
        errdefer self.deinit();

        self.values[0] = receiver.dup();
        self.rooted_prefix = self.values[0..1];
        self.values[1] = callable.dup();
        self.rooted_prefix = self.values[0..2];
        for (args, 0..) |arg, index| {
            self.values[index + 2] = arg.dup();
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
        std.debug.assert(self.rt == null);
        const total = try std.math.add(usize, args.len, 2);
        self.rt = rt;
        self.values = if (total <= self.inline_values.len)
            self.inline_values[0..total]
        else blk: {
            self.heap_backed = true;
            break :blk try rt.memory.alloc(core.JSValue, total);
        };
        self.rooted_prefix = self.values[0..0];
        self.root.init(rt, &self.rooted_prefix);
        errdefer self.deinit();

        self.values[0] = receiver.dup();
        self.rooted_prefix = self.values[0..1];
        self.values[1] = callable.dup();
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
            const value = self.values[index];
            self.values[index] = core.JSValue.undefinedValue();
            value.free(rt);
        }
        self.rooted_prefix = self.values[0..0];
        self.root.deinit();
        if (self.heap_backed) rt.memory.free(core.JSValue, self.values);
        self.values = &.{};
        self.rt = null;
        self.heap_backed = false;
    }
};

const SyncInlineRoute = struct {
    invocation: *inline_calls.ActiveInvocation,
    target: inline_calls.InlineTarget,
};

inline fn resolveSyncInlineRoute(
    route: *SyncInlineRoute,
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
) bool {
    const invocation = inline_calls.activeInvocation(ctx.runtime) orelse return false;
    const machine = invocation.machine;
    if (machine.ctx != ctx or
        machine.global != global or
        machine.output != output)
    {
        return false;
    }
    route.invocation = invocation;
    return inline_calls.resolveInlineTargetInto(
        &route.target,
        ctx,
        global,
        this_value,
        func,
    );
}

noinline fn runSyncInlineRouteMoved(
    route: *SyncInlineRoute,
    global: *core.Object,
    moved_values: []core.JSValue,
) HostError!core.JSValue {
    var boundary = inline_calls.NativeBoundaryScope.init(route.invocation);
    boundary.push();
    errdefer boundary.deinit();

    _ = try route.invocation.machine.pushMovedCall(
        global,
        &route.target,
        moved_values,
        .method,
        .native_boundary,
        0,
    );
    inline_calls.recordSameMachineSyncCall();
    const result = try zjs_vm.runActiveInvocationUntilNativeBoundary(route.invocation, &boundary);
    boundary.finish();
    return result;
}

inline fn runSyncInlineRouteCopiedArgs(
    route: *SyncInlineRoute,
    global: *core.Object,
    args: []const core.JSValue,
) HostError!core.JSValue {
    std.debug.assert(inline_calls.Machine.nativeBoundarySimpleEligible(&route.target));
    var boundary = inline_calls.NativeBoundaryScope.init(route.invocation);
    boundary.push();
    errdefer boundary.deinit();

    const machine = route.invocation.machine;
    if (machine.tryPushNativeBoundaryCopiedArgsFast(
        machine.ctx.runtime,
        &route.target,
        args,
    ) == null) {
        _ = (try machine.pushNativeBoundaryCopiedArgs(
            global,
            &route.target,
            args,
        )).?;
    }
    inline_calls.recordSameMachineSyncCall();
    const result = try zjs_vm.runActiveInvocationUntilNativeBoundary(route.invocation, &boundary);
    boundary.finish();
    return result;
}

noinline fn runSyncInlineRouteMovedArgs(
    route: *SyncInlineRoute,
    global: *core.Object,
    args: []core.JSValue,
) HostError!core.JSValue {
    std.debug.assert(inline_calls.Machine.nativeBoundarySimpleEligible(&route.target));
    var boundary = inline_calls.NativeBoundaryScope.init(route.invocation);
    boundary.push();
    errdefer boundary.deinit();

    const machine = route.invocation.machine;
    if (machine.tryPushNativeBoundaryMovedArgsFast(
        machine.ctx.runtime,
        &route.target,
        args,
    ) == null) {
        _ = (try machine.pushNativeBoundaryMovedArgs(
            global,
            &route.target,
            args,
        )).?;
    }
    inline_calls.recordSameMachineSyncCall();
    const result = try zjs_vm.runActiveInvocationUntilNativeBoundary(route.invocation, &boundary);
    boundary.finish();
    return result;
}

noinline fn runSyncInlineRouteOwnedCopy(
    route: *SyncInlineRoute,
    ctx: *core.JSContext,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
) HostError!core.JSValue {
    var owned_args = OwnedArgList{};
    try owned_args.init(ctx.runtime, this_value, func, args);
    defer owned_args.deinit();
    return runSyncInlineRouteMoved(route, global, owned_args.values);
}

noinline fn runSyncInlineRouteOwnedArgsGeneral(
    route: *SyncInlineRoute,
    ctx: *core.JSContext,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []core.JSValue,
) HostError!core.JSValue {
    std.debug.assert(!inline_calls.Machine.nativeBoundarySimpleEligible(&route.target));
    var owned_args = OwnedArgList{};
    try owned_args.initTakeArgs(ctx.runtime, this_value, func, args);
    defer owned_args.deinit();
    return runSyncInlineRouteMoved(route, global, owned_args.values);
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
            true,
        );

    if (inline_calls.Machine.nativeBoundarySimpleEligible(&route.target)) {
        return runSyncInlineRouteCopiedArgs(&route, global, args);
    }
    return runSyncInlineRouteOwnedCopy(
        &route,
        ctx,
        global,
        this_value,
        func,
        args,
    );
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

/// A stack-local adapter for native algorithms that invoke one immutable
/// callback repeatedly. QuickJS resolves the JSFunction record once from the
/// callback value held by the native algorithm; mirror that lifetime here
/// instead of rebuilding the wider InlineTarget on every iteration.
///
/// Call entry remains fully observable: every `call` polls interrupts and
/// verifies that the invocation which prepared the route is still active.
/// A site prepared outside bytecode execution, or used after an execution-root
/// change, takes the authoritative root-call fallback unconditionally.
pub const SyncInternalCallSite = struct {
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    route: ?SyncInlineRoute,

    pub inline fn init(
        ctx: *core.JSContext,
        output: ?*std.Io.Writer,
        global: *core.Object,
        this_value: core.JSValue,
        func: core.JSValue,
        caller_function: ?*const bytecode.FunctionBytecode,
        caller_frame: ?*frame_mod.Frame,
    ) SyncInternalCallSite {
        var route: SyncInlineRoute = undefined;
        return .{
            .ctx = ctx,
            .output = output,
            .global = global,
            .this_value = this_value,
            .func = func,
            .caller_function = caller_function,
            .caller_frame = caller_frame,
            .route = if (resolveSyncInlineRoute(
                &route,
                ctx,
                output,
                global,
                this_value,
                func,
            )) route else null,
        };
    }

    pub noinline fn call(
        self: *SyncInternalCallSite,
        args: []const core.JSValue,
    ) HostError!core.JSValue {
        try exception_ops.pollInterrupt(self.ctx, self.global);

        if (self.route) |*route| {
            if (inline_calls.activeInvocation(self.ctx.runtime) == route.invocation) {
                if (inline_calls.Machine.nativeBoundarySimpleEligible(&route.target)) {
                    return runSyncInlineRouteCopiedArgs(route, self.global, args);
                }
                return runSyncInlineRouteOwnedCopy(
                    route,
                    self.ctx,
                    self.global,
                    self.this_value,
                    self.func,
                    args,
                );
            }
        }
        return callValueOrBytecodeDispatchAfterInterruptPoll(
            self.ctx,
            self.output,
            self.global,
            self.this_value,
            self.func,
            args,
            self.caller_function,
            self.caller_frame,
            true,
        );
    }

    /// Reuse the prepared callable route while supplying the receiver for this
    /// invocation. Recursive native algorithms such as JSON reviver/replacer
    /// walks keep one callback but change the holder used as `this` at every
    /// step. The copied route is stack-local so nested/reentrant calls cannot
    /// mutate the site's immutable template.
    pub noinline fn callWithThis(
        self: *SyncInternalCallSite,
        this_value: core.JSValue,
        args: []const core.JSValue,
    ) HostError!core.JSValue {
        try exception_ops.pollInterrupt(self.ctx, self.global);

        if (self.route) |template| {
            if (inline_calls.activeInvocation(self.ctx.runtime) == template.invocation) {
                var route = template;
                route.target.this_value = this_value;
                if (inline_calls.Machine.nativeBoundarySimpleEligible(&route.target)) {
                    return runSyncInlineRouteCopiedArgs(&route, self.global, args);
                }
                return runSyncInlineRouteOwnedCopy(
                    &route,
                    self.ctx,
                    self.global,
                    this_value,
                    self.func,
                    args,
                );
            }
        }
        return callValueOrBytecodeDispatchAfterInterruptPoll(
            self.ctx,
            self.output,
            self.global,
            this_value,
            self.func,
            args,
            self.caller_function,
            self.caller_frame,
            true,
        );
    }
};

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
            true,
        );
    if (inline_calls.Machine.nativeBoundarySimpleEligible(&route.target)) {
        return runSyncInlineRouteMovedArgs(&route, global, args);
    }
    return runSyncInlineRouteOwnedArgsGeneral(
        &route,
        ctx,
        global,
        this_value,
        func,
        args,
    );
}

/// Slow-path collection prototype methods reached by name without a baked
/// native id (the id-carrying path already routed through
/// `call_mod.callNativeFunctionRecord` above). Replaces the retired
/// collection helper triple: gate on the installed collection owner class and
/// the exact (method, owner) pairs those wrappers handled — keys/values/entries
/// and forEach on Map|Set, the Set composition/comparison operators on Set —
/// then route the body through the record table. Returns null (continue the
/// dispatch chain) for any non-matching function, exactly as the wrappers did;
/// the record handler performs the receiver-validity throw the wrappers raised.
fn collectionPrototypeMethodByName(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    name: []const u8,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    const owner_class = function_object.collectionMethodOwnerClass();
    if (owner_class == core.class.invalid_class_id) return null;
    const PrototypeMethod = method_ids.collection.PrototypeMethod;
    const id = core.host_function.builtin_method_id_lookup.collection.prototypeMethodId(name) orelse return null;
    const handled = switch (id) {
        @intFromEnum(PrototypeMethod.keys),
        @intFromEnum(PrototypeMethod.values),
        @intFromEnum(PrototypeMethod.entries),
        @intFromEnum(PrototypeMethod.for_each),
        => owner_class == core.class.ids.map or owner_class == core.class.ids.set,
        @intFromEnum(PrototypeMethod.difference),
        @intFromEnum(PrototypeMethod.intersection),
        @intFromEnum(PrototypeMethod.is_disjoint_from),
        @intFromEnum(PrototypeMethod.is_subset_of),
        @intFromEnum(PrototypeMethod.is_superset_of),
        @intFromEnum(PrototypeMethod.symmetric_difference),
        @intFromEnum(PrototypeMethod.union_),
        => owner_class == core.class.ids.set,
        // set/get/has/delete/clear/add/size/getOrInsert(Computed) carry native
        // ids and were handled at `callNativeFunctionRecord`; never reached the
        // retired name wrappers, so leave them to the dispatch chain.
        else => false,
    };
    if (!handled) return null;
    const native_ref = core.function.NativeBuiltinRef{ .domain = .collection, .id = id };
    return builtin_dispatch.callInternalRecord(ctx, output, global, &.{}, function_object, this_value, native_ref, args, caller_function, caller_frame);
}

const VmNativeCallableDispatch = union(enum) {
    bound_function,
    resolved_record: core.Object.NativeCallTarget,
    native_ref: core.function.NativeBuiltinRef,
    host_function,
    internal: core.host_function.InternalCallableTag,
    name_dispatch,
};

fn vmNativeCallableDispatch(function_object: *core.Object) VmNativeCallableDispatch {
    return switch (function_object.class_id) {
        core.class.ids.bound_function => .bound_function,
        core.class.ids.c_function => blk: {
            if (function_object.nativeCallTarget()) |target| {
                break :blk .{ .resolved_record = target };
            }
            if (core.function.decodeNativeBuiltinId(function_object.nativeFunctionId())) |native_ref| {
                break :blk .{ .native_ref = native_ref };
            }
            if (function_object.hostFunctionKind() != 0) break :blk .host_function;
            const tag = function_object.internalCallableTag();
            if (tag != .none) break :blk .{ .internal = tag };
            break :blk .name_dispatch;
        },
        core.class.ids.c_function_data => blk: {
            if (core.function.decodeNativeBuiltinId(function_object.nativeFunctionId())) |native_ref| {
                break :blk .{ .native_ref = native_ref };
            }
            if (function_object.hostFunctionKind() != 0) break :blk .host_function;
            const tag = function_object.internalCallableTag();
            if (tag != .none) break :blk .{ .internal = tag };
            break :blk .name_dispatch;
        },
        else => .name_dispatch,
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
        .async_function_resume => try promise_ops.asyncFunctionResumeCallbackCall(ctx, output, global, function_object, args, caller_function, caller_frame),
        .async_generator_resolve => try async_generator.asyncGeneratorResolveFunctionCall(ctx, output, global, function_object, args),
        .async_from_sync_iterator_close_wrap => try promise_ops.asyncFromSyncIteratorCloseWrapCall(ctx, output, global, function_object, args),
        .async_from_sync_iterator_unwrap => try promise_ops.asyncFromSyncIteratorUnwrapCall(ctx, global, function_object, args),
        .async_disposable_stack_continuation => try promise_ops.asyncDisposableStackContinuationCall(ctx, output, global, function_object, args, caller_function, caller_frame),
        .array_from_async_continuation => try array_ops.arrayFromAsyncContinuationCall(ctx, output, global, function_object, args, caller_function, caller_frame),
        .throw_type_error_intrinsic => @as(?core.JSValue, try throwTypeErrorIntrinsic(ctx, global, function_object)),
    };
}

noinline fn callRawFunctionBytecode(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    copy_argv: bool,
) HostError!core.JSValue {
    _ = functionBytecodeFromValue(func) orelse return error.TypeError;
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
        true,
        null,
        null,
        null,
        core.JSValue.undefinedValue(),
        copy_argv,
        false,
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
    copy_argv: bool,
) HostError!core.JSValue {
    const function_value = function_object.functionBytecode() orelse return error.TypeError;
    _ = functionBytecodeFromValue(function_value) orelse return error.TypeError;
    // Bound/Proxy dispatch has already recursed to this final bytecode arm.
    // The helper keeps this caller view through interrupt/stack preflight;
    // zjs_vm selects the FB Realm only after those checks.
    // OP_check_ctor owns class direct-call rejection in the function realm.
    return callFunctionBytecodeModeStateAfterInterruptPoll(ctx, function_value, func, this_value, args, function_object.functionCaptures(), output, global, true, null, null, null, core.JSValue.undefinedValue(), copy_argv, false);
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
            try builtin_dispatch.preflightCFunctionCall(ctx, global, function_object, target.record.length);
            const view = try builtin_dispatch.CallRealmView.caller(target.realm);
            const native_result = builtin_dispatch.callInternalRecordDirectInRealm(
                view,
                output,
                function_object,
                this_value,
                target.record,
                args,
                caller_function,
                caller_frame,
            ) catch |err| {
                try throwRuntimeErrorForGlobal(view.realm, view.global, err);
                return err;
            };
            return native_result;
        },
        .native_ref => |native_ref| {
            const native_result = callNativeBuiltinRecordForVm(ctx, output, global, func, this_value, function_object, native_ref, args, caller_function, caller_frame) catch |err| {
                const view = try builtin_dispatch.finalCallableRealmView(ctx, function_object);
                try throwRuntimeErrorForGlobal(view.realm, view.global, err);
                return err;
            };
            if (native_result) |value| return value;
        },
        .host_function => {
            if (try call_mod.callHostFunctionObjectForVm(ctx, output, global, function_object, this_value, args)) |value| return value;
        },
        .internal => |tag| {
            const view = try builtin_dispatch.finalCallableRealmView(ctx, function_object);
            if (try callInternalCallableByTag(view.realm, output, view.global, function_object, tag, args, caller_function, caller_frame)) |value| return value;
        },
        .name_dispatch => {},
    }
    const view = try builtin_dispatch.finalCallableRealmView(ctx, function_object);
    return callNativeCallableByName(
        view.realm,
        output,
        view.global,
        this_value,
        func,
        function_object,
        args,
        caller_function,
        caller_frame,
    );
}

fn callValueOrBytecodeDispatch(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    copy_argv: bool,
) HostError!core.JSValue {
    try exception_ops.pollInterrupt(ctx, global);
    return callValueOrBytecodeDispatchAfterInterruptPoll(ctx, output, global, this_value, func, args, caller_function, caller_frame, copy_argv);
}

fn callValueOrBytecodeDispatchAfterInterruptPoll(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    copy_argv: bool,
) HostError!core.JSValue {
    if (func.isFunctionBytecode()) {
        return callRawFunctionBytecode(ctx, output, global, this_value, func, args, copy_argv);
    }
    if (object_ops.objectFromValue(func)) |object| {
        switch (object.class_id) {
            core.class.ids.bytecode_function,
            core.class.ids.generator_function,
            core.class.ids.async_function,
            core.class.ids.async_generator_function,
            => {
                return callFunctionObjectBytecode(ctx, output, global, this_value, func, object, args, copy_argv);
            },
            core.class.ids.proxy => {
                if (object.proxyTarget() != null and object_ops.proxyTargetIsCallable(func)) {
                    return object_ops.callProxyApply(ctx, output, global, func, object, this_value, args, caller_function, caller_frame);
                }
            },
            core.class.ids.c_function,
            core.class.ids.c_function_data,
            core.class.ids.c_closure,
            core.class.ids.bound_function,
            => return callNativeCallableObject(ctx, output, global, this_value, func, object, args, caller_function, caller_frame),
            else => {},
        }
    }
    if (!isCallableValue(func)) return exception_ops.throwTypeErrorMessage(ctx, global, "not a function");
    return call_mod.callValueWithThisGlobalsAndGlobal(ctx, output, global, &.{}, this_value, func, args);
}

/// Compatibility fallback for callable objects which do not carry a stable
/// native record or internal-callable tag. Keep this legacy name dispatch out
/// of the normal call frame: QuickJS classifies the callable in
/// `JS_CallInternal` and enters a class-specific call function, so a C/native
/// call does not share a frame with bytecode and compatibility dispatch.
noinline fn callNativeCallableByName(
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
    // Borrow the internal dispatch-name bytes instead of allocating a
    // fresh `[]u8` per call. Hot URI 4-byte-UTF-8 sweeps call this path millions of
    // times, and the previous round-trip alloc/free showed up clearly
    // on the profile. Native dispatch names are atom-backed ASCII
    // builtin names in practice; a `null` return here means there is
    // no usable dispatch name.
    const dispatch = call_mod.nativeFunctionDispatchNameRef(ctx.runtime, function_object) orelse {
        return core.JSValue.undefinedValue();
    };
    defer dispatch.name_value.free(ctx.runtime);
    const name = dispatch.name;
    if (name.len == 0) return core.JSValue.undefinedValue();
    if (std.mem.eql(u8, name, "raw")) {
        return string_ops.stringRaw(ctx, output, global, args, caller_function, caller_frame);
    }
    if (std.mem.eql(u8, name, "sumPrecise")) {
        return math_ops.mathSumPrecise(ctx, output, global, args, caller_function, caller_frame);
    }
    if (try disposable_ops.disposableStackMethodCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| {
        return value;
    }
    if (try promise_ops.asyncDisposableStackMethodCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| {
        return value;
    }
    if (try call_mod.callNativeFunctionRecord(ctx, output, global, &.{}, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
    if (try collectionPrototypeMethodByName(ctx, output, global, this_value, function_object, name, args, caller_function, caller_frame)) |value| {
        return value;
    }
    // Hot-path dispatch: a small first-byte switch routes the common
    // global builtins directly to their handlers, bypassing the long
    // `std.mem.eql` chain below. The previous chain walked ~95 checks
    // before reaching `uriCallId` for `decodeURI` / `encodeURI`,
    // which dominated tight-loop URI benchmarks.
    if (name.len != 0) {
        switch (name[0]) {
            'A' => if (std.mem.eql(u8, name, "Array") and function_object.arrayBuiltinMarker() == .constructor) {
                return constructArrayNativeRecordVm(ctx, output, global, function_object, array_ops.arrayPrototypeFromGlobal(ctx.runtime, global), args, caller_function, caller_frame);
            },
            'B' => if (std.mem.eql(u8, name, "BigInt")) {
                return builtin_glue.bigIntFunctionCall(ctx, output, global, args);
            },
            'N' => if (std.mem.eql(u8, name, "Number")) {
                return builtin_glue.numberFunctionCall(ctx, output, global, args);
            },
            'O' => if (std.mem.eql(u8, name, "Object")) {
                return construct_mod.constructValue(ctx, func, args, &.{});
            },
            'S' => if (std.mem.eql(u8, name, "String")) {
                return string_ops.stringFunctionCall(ctx, output, global, args, caller_function, caller_frame);
            },
            'd', 'e' => if (core.host_function.builtin_method_id_lookup.uri.methodId(name)) |mode| {
                const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
                const native_ref = core.function.NativeBuiltinRef{ .domain = .uri, .id = mode };
                return (try builtin_dispatch.callInternalRecord(ctx, output, global, &.{}, null, this_value, native_ref, &.{input}, caller_function, caller_frame)) orelse error.TypeError;
            },
            'f' => if (std.mem.eql(u8, name, "fromCharCode")) {
                // Skip the long `std.mem.eql` chain below for the
                // canonical `String.fromCharCode` shape; routes
                // straight to the same handler the slow path uses,
                // so coercion semantics (e.g. string args, BigInt
                // rejection) stay identical.
                return string_ops.stringFromCharCode(ctx, output, global, args);
            },
            'r' => if (std.mem.eql(u8, name, "raw")) {
                return string_ops.stringRaw(ctx, output, global, args, caller_function, caller_frame);
            },
            else => {},
        }
    }
    if (std.mem.eql(u8, name, "get [Symbol.species]")) return this_value.dup();
    if (std.mem.eql(u8, name, "Function")) return function_ops.constructFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "AsyncFunction")) return promise_ops.constructAsyncFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "GeneratorFunction")) return function_ops.constructGeneratorFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "AsyncGeneratorFunction")) return promise_ops.constructAsyncGeneratorFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "Object")) return construct_mod.constructValue(ctx, func, args, &.{});
    if (std.mem.eql(u8, name, "Array") and function_object.arrayBuiltinMarker() == .constructor) {
        return constructArrayNativeRecordVm(ctx, output, global, function_object, array_ops.arrayPrototypeFromGlobal(ctx.runtime, global), args, caller_function, caller_frame);
    }
    if (std.mem.eql(u8, name, "String")) return string_ops.stringFunctionCall(ctx, output, global, args, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "Number")) return builtin_glue.numberFunctionCall(ctx, output, global, args);
    if (std.mem.eql(u8, name, "BigInt")) return builtin_glue.bigIntFunctionCall(ctx, output, global, args);
    if (std.mem.eql(u8, name, "parseInt")) return builtin_glue.globalParseInt(ctx, output, global, args, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "parseFloat")) return builtin_glue.globalParseFloat(ctx, output, global, args, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "isNaN")) return builtin_glue.globalIsNaNOrFinite(ctx, output, global, this_value, args, true);
    if (std.mem.eql(u8, name, "isFinite")) return builtin_glue.globalIsNaNOrFinite(ctx, output, global, this_value, args, false);
    if (std.mem.eql(u8, name, "RegExp")) {
        var native_scope = builtin_dispatch.NativeBacktraceScope.init(ctx, function_object);
        native_scope.push();
        defer native_scope.deinit();
        return regexp_fastpath.regExpFunctionCall(ctx, output, global, function_object, args, caller_function, caller_frame) catch |err| {
            try builtin_dispatch.materializeRuntimeError(ctx, global, err);
            return err;
        };
    }
    if (std.mem.eql(u8, name, "DisposableStack")) return error.TypeError;
    if (std.mem.eql(u8, name, "AsyncDisposableStack")) return error.TypeError;
    if (std.mem.eql(u8, name, "AggregateError")) {
        var prototype = try object_ops.constructorPrototypeObject(ctx.runtime, func);
        defer prototype.deinit(ctx.runtime);
        return try object_ops.aggregateErrorConstructWithPrototype(ctx, output, global, prototype.object(), args, caller_function, caller_frame);
    }
    if (std.mem.eql(u8, name, "SuppressedError")) {
        var prototype = try object_ops.constructorPrototypeObject(ctx.runtime, func);
        defer prototype.deinit(ctx.runtime);
        return try object_ops.suppressedErrorConstructWithPrototype(ctx, output, global, prototype.object(), args, caller_function, caller_frame);
    }
    if (exception_ops.isErrorConstructorName(name)) {
        var prototype = try object_ops.constructorPrototypeObject(ctx.runtime, func);
        defer prototype.deinit(ctx.runtime);
        return try object_ops.errorConstructWithPrototype(ctx, output, global, name, prototype.object(), args, caller_function, caller_frame);
    }
    if (std.mem.eql(u8, name, "isError")) return builtin_glue.errorIsError(args);
    if (std.mem.eql(u8, name, "isView")) return array_ops.arrayBufferIsView(args);
    if (std.mem.eql(u8, name, "set")) {
        if (try array_ops.typedArraySetCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
    }
    if (std.mem.eql(u8, name, "next")) {
        if (try promise_ops.asyncFromSyncIteratorMethodCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
        if (try iterator_ops.iteratorHelperNext(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
        if (try iterator_ops.iteratorWrapNext(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
        if (promise_ops.isAsyncGeneratorPrototypeMethod(ctx.runtime, function_object) and !promise_ops.isAsyncGeneratorReceiver(this_value)) return promise_ops.asyncGeneratorRejectedTypeError(ctx, global);
        if (try generatorNext(ctx, output, global, this_value, args)) |value| return value;
        if (promise_ops.isAsyncGeneratorPrototypeMethod(ctx.runtime, function_object)) return promise_ops.asyncGeneratorRejectedTypeError(ctx, global);
        if (try string_ops.regExpStringIteratorNext(ctx, output, global, this_value, caller_function, caller_frame)) |value| return value;
        {
            // Array Iterator `next` is still marker/name-dispatched rather
            // than table-dispatched. Give this legacy terminal the same
            // native-frame/error-materialization boundary as a record call.
            var native_scope = builtin_dispatch.NativeBacktraceScope.init(ctx, function_object);
            native_scope.push();
            defer native_scope.deinit();
            const next_result = array_ops.arrayIteratorNextFast(ctx, output, global, this_value, function_object) catch |err| {
                try builtin_dispatch.materializeRuntimeError(ctx, global, err);
                return err;
            };
            if (next_result) |value| return value;
        }
    }
    if (std.mem.eql(u8, name, "throw")) {
        if (try promise_ops.asyncFromSyncIteratorMethodCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
        if (promise_ops.isAsyncGeneratorPrototypeMethod(ctx.runtime, function_object) and !promise_ops.isAsyncGeneratorReceiver(this_value)) return promise_ops.asyncGeneratorRejectedTypeError(ctx, global);
        if (try generatorThrow(ctx, output, global, this_value, args)) |value| return value;
        if (promise_ops.isAsyncGeneratorPrototypeMethod(ctx.runtime, function_object)) return promise_ops.asyncGeneratorRejectedTypeError(ctx, global);
    }
    if (std.mem.eql(u8, name, "[Symbol.iterator]")) {
        if (isIteratorIdentityFunction(ctx.runtime, function_object)) return this_value.dup();
        if (object_ops.objectFromValue(this_value)) |this_object| {
            if (this_object.class_id == core.class.ids.array_iterator) return this_value.dup();
        }
    }
    if (std.mem.eql(u8, name, "[Symbol.asyncIterator]")) {
        return this_value.dup();
    }
    if (std.mem.eql(u8, name, "[Symbol.asyncDispose]")) {
        if (try promise_ops.asyncIteratorAsyncDispose(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
    }
    if (std.mem.eql(u8, name, "return")) {
        if (try promise_ops.asyncFromSyncIteratorMethodCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
        if (try iterator_ops.iteratorHelperReturn(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
        if (try iterator_ops.iteratorWrapReturn(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
        if (promise_ops.isAsyncGeneratorPrototypeMethod(ctx.runtime, function_object) and !promise_ops.isAsyncGeneratorReceiver(this_value)) return promise_ops.asyncGeneratorRejectedTypeError(ctx, global);
        if (try generatorReturn(ctx, output, global, this_value, args)) |value| return value;
        if (promise_ops.isAsyncGeneratorPrototypeMethod(ctx.runtime, function_object)) return promise_ops.asyncGeneratorRejectedTypeError(ctx, global);
    }
    if (std.mem.eql(u8, name, "fromCharCode")) {
        return string_ops.stringFromCharCode(ctx, output, global, args);
    }
    if (std.mem.eql(u8, name, "fromCodePoint")) {
        return string_ops.stringFromCodePoint(ctx, output, global, args);
    }
    if (std.mem.eql(u8, name, "raw")) {
        return string_ops.stringRaw(ctx, output, global, args, caller_function, caller_frame);
    }
    if (core.host_function.builtin_method_id_lookup.date.staticMethodId(name)) |method_id| {
        if (object_ops.objectFromValue(this_value)) |receiver_object| {
            if (try constructorNameEqlLocal(ctx.runtime, receiver_object, "Date")) {
                if (try date_ops.dateStaticCall(ctx, output, global, this_value, method_id, args, caller_function, caller_frame)) |value| return value;
                // parse/now fall-through (utc was handled above with VM
                // coercion): route the static body through the record table.
                return date_ops.callDateStaticBody(ctx, method_id, args) catch |err| switch (err) {
                    error.TypeError => error.TypeError,
                    else => err,
                };
            }
        }
    }
    if (try iterator_ops.arrayIteratorMethod(ctx, global, this_value, function_object)) |value| {
        return value;
    }
    if (std.mem.eql(u8, name, "apply")) {
        // Legacy name-only entry for recordless `apply` data functions; must
        // stay behaviorally identical to `functionApplyRecord`'s body.
        return functionApplyCall(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (std.mem.eql(u8, name, "call")) {
        return functionCallCall(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (std.mem.eql(u8, name, "get __proto__")) return object_ops.objectProtoGetterCall(ctx, output, global, this_value, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "set __proto__")) {
        const proto_arg = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        return object_ops.objectProtoSetterCall(ctx, output, global, this_value, proto_arg, caller_function, caller_frame);
    }
    if (std.mem.eql(u8, name, "set")) {
        if (try array_ops.typedArraySetCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
    }
    if (std.mem.eql(u8, name, "join")) {
        if (try array_ops.arrayJoinCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
    }
    if (std.mem.eql(u8, name, "toString")) {
        if (try string_ops.arrayToStringCall(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
    }
    if (std.mem.eql(u8, name, "toLocaleString")) {
        if (try string_ops.arrayToLocaleStringCall(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
    }
    if (try array_ops.arrayFromCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
    if (try array_ops.arrayFromAsyncCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
    if (try array_ops.arrayOfCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
    if (try array_ops.arrayIterationCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
    if (try array_ops.arrayAtCall(ctx, output, global, this_value, func, args)) |value| return value;
    if (try array_ops.arrayReduceCall(ctx, output, global, this_value, func, args, false)) |value| return value;
    if (try array_ops.arrayReduceCall(ctx, output, global, this_value, func, args, true)) |value| return value;
    if (try string_ops.arraySearchCall(ctx, output, global, this_value, func, args)) |value| return value;
    if (try array_ops.arrayCopyWithinCall(ctx, output, global, this_value, func, args)) |value| return value;
    if (try array_ops.arrayFillCall(ctx, output, global, this_value, func, args)) |value| return value;
    if (try array_ops.arrayPushCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
    if (try array_ops.arrayPopCall(ctx, output, global, this_value, func, caller_function, caller_frame)) |value| return value;
    if (try array_ops.arrayShiftCall(ctx, output, global, this_value, func)) |value| return value;
    if (try array_ops.arrayUnshiftCall(ctx, output, global, this_value, func, args)) |value| return value;
    if (try array_ops.arrayReverseCall(ctx, output, global, this_value, func, caller_function, caller_frame)) |value| return value;
    if (try array_ops.arraySpliceCall(ctx, output, global, this_value, func, args)) |value| return value;
    if (try array_ops.typedArraySliceSubarrayCall(ctx, output, global, this_value, func, args)) |value| return value;
    if (try array_ops.arraySliceCall(ctx, output, global, this_value, func, args)) |value| return value;
    if (try array_ops.arrayFlatCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
    if (try array_ops.arraySortCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
    if (try array_ops.arrayByCopyCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
    if (try string_ops.arrayConcatCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
    // Retained even though `Promise.prototype.{then,catch,finally}` now carry
    // native records: `core.promise.constructWithPrototype` (src/core/promise.zig:29)
    // still installs recordless own `then`/`catch` data functions on a
    // prototype-less promise, which `call.zig`'s capability path can produce
    // whenever `Promise.prototype` is not (yet) an own data property.
    if (std.mem.eql(u8, name, "then") or std.mem.eql(u8, name, "catch") or std.mem.eql(u8, name, "finally")) {
        if (try promise_ops.promiseThen(ctx, output, global, this_value, name, args, caller_function, caller_frame)) |value| return value;
    }
    if (std.mem.eql(u8, name, "eval")) {
        const eval_global = if (function_object.functionRealmGlobal()) |realm_value|
            property_ops.expectObject(realm_value) catch global
        else
            global;
        return indirectEval(ctx, output, eval_global, args);
    }
    if (std.mem.eql(u8, name, "throws")) return assertThrows(ctx, output, global, args, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "groupBy")) {
        // `Map.groupBy` static: route through the collection record table's
        // `group_by` handler instead of naming a JS-visible function body.
        // The only native `groupBy` is `Map.groupBy`, so this slow-path
        // fallback always carries the Map constructor as receiver. Exec keys
        // the record by its stable value rather than importing the registry.
        const native_ref = core.function.NativeBuiltinRef{ .domain = .collection, .id = collection_group_by_static_id };
        if (try builtin_dispatch.callInternalRecord(ctx, output, global, &.{}, function_object, this_value, native_ref, args, caller_function, caller_frame)) |grouped| return grouped;
    }
    if (std.mem.eql(u8, name, "getOrInsertComputed")) {
        // `Map`/`WeakMap.prototype.getOrInsertComputed` reached by name
        // without a baked id: gate on a Map/WeakMap receiver (the retired
        // `mapGetOrInsertComputed` returned null to continue the chain for
        // any other receiver) and route the body through the record table.
        if (object_ops.objectFromValue(this_value)) |receiver| {
            if (receiver.class_id == core.class.ids.map or receiver.class_id == core.class.ids.weakmap) {
                const native_ref = core.function.NativeBuiltinRef{ .domain = .collection, .id = @intFromEnum(method_ids.collection.PrototypeMethod.get_or_insert_computed) };
                if (try builtin_dispatch.callInternalRecord(ctx, output, global, &.{}, function_object, this_value, native_ref, args, caller_function, caller_frame)) |value| return value;
            }
        }
    }
    if (object_ops.getNumberPrototypeMethodId(ctx.runtime, function_object)) |method_id| {
        return object_ops.numberPrototypeMethod(ctx, output, global, this_value, @intCast(method_id), args, caller_function, caller_frame);
    }
    if (std.mem.eql(u8, name, "concat") and !array_ops.isArrayMethodReceiver(this_value)) {
        return string_ops.stringConcat(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (std.mem.eql(u8, name, "replace")) {
        return string_ops.stringReplace(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (std.mem.eql(u8, name, "exec")) {
        return regexp_fastpath.regExpExecMethod(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (std.mem.eql(u8, name, "test")) {
        if (try regexp_fastpath.regExpTestMethod(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
    }
    if (std.mem.eql(u8, name, "compile")) {
        if (try regexp_fastpath.regExpCompile(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
    }
    if (std.mem.eql(u8, name, "[Symbol.search]")) {
        if (try string_ops.regExpSymbolSearch(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
    }
    if (std.mem.eql(u8, name, "[Symbol.match]")) {
        if (try string_ops.regExpSymbolMatch(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
    }
    if (std.mem.eql(u8, name, "[Symbol.matchAll]")) {
        if (try string_ops.regExpSymbolMatchAll(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
    }
    if (std.mem.eql(u8, name, "[Symbol.replace]")) {
        if (try string_ops.regExpSymbolReplace(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
    }
    if (std.mem.eql(u8, name, "[Symbol.split]")) {
        if (try string_ops.regExpSymbolSplit(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
    }
    if (core.function.decodeNativeBuiltinId(function_object.nativeFunctionId())) |native_ref| {
        if (native_ref.domain == .regexp and
            core.host_function.builtin_method_id_lookup.regexp.accessorNameFromId(native_ref.id) != null)
        {
            // The `.regexp` accessor record runs the same `regExpAccessor`
            // fast path + primitive `accessor` fallback this site used to
            // inline; route through the table by the function's own id.
            return (try builtin_dispatch.callInternalRecord(ctx, output, global, &.{}, function_object, this_value, native_ref, args, caller_function, caller_frame)) orelse error.TypeError;
        }
    }
    if (core.host_function.builtin_method_id_lookup.regexp.accessorIdFromGetterName(name)) |accessor_id| {
        const native_ref = core.function.NativeBuiltinRef{ .domain = .regexp, .id = accessor_id };
        return (try builtin_dispatch.callInternalRecord(ctx, output, global, &.{}, function_object, this_value, native_ref, args, caller_function, caller_frame)) orelse error.TypeError;
    }
    if (core.host_function.builtin_method_id_lookup.buffer.dataViewGetMethodId(name)) |method_id| {
        return builtin_glue.dataViewGetCall(ctx, output, global, this_value, method_id, args) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            error.RangeError => error.RangeError,
            else => err,
        };
    }
    if (core.host_function.builtin_method_id_lookup.buffer.dataViewSetMethodId(name)) |method_id| {
        return builtin_glue.dataViewSetCall(ctx, output, global, this_value, method_id, args) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            error.RangeError => error.RangeError,
            else => err,
        };
    }
    if (std.mem.eql(u8, name, "charAt")) {
        const index = if (args.len >= 1) args[0] else core.JSValue.int32(0);
        return string_ops.callStringCharAtBody(ctx, this_value, index) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            else => err,
        };
    }
    if (std.mem.eql(u8, name, "[Symbol.iterator]")) {
        return string_ops.stringIteratorCall(ctx, output, global, this_value, caller_function, caller_frame);
    }
    if (string_ops.getStringPrototypeMethodId(ctx.runtime, function_object)) |method_id| {
        return string_ops.stringPrototypeMethod(ctx, output, global, this_value, method_id, args, caller_function, caller_frame) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            else => err,
        };
    }
    if (string_ops.isStringMethodReceiver(this_value)) {
        if (string_ops.standardStringMethodId(name)) |method_id| {
            return string_ops.callStringBody(ctx, this_value, method_id, args) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                else => err,
            };
        }
    }
    if (string_ops.annexBStringMethodId(name)) |method_id| {
        return string_ops.stringPrototypeMethod(ctx, output, global, this_value, method_id, args, caller_function, caller_frame) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            else => err,
        };
    }
    return call_mod.callValueWithThisGlobalsAndGlobal(ctx, output, global, &.{}, this_value, func, args);
}

test "callValueOrBytecodeRoot roots inline args before bytecode frame allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    @import("standard_globals.zig").configureRuntime(rt);
    const ctx = try core.JSContext.create(rt);
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

    var func_value = core.JSValue.functionBytecode(&fb.header);
    var func_alive = true;
    defer if (func_alive) func_value.free(rt);

    const arg_atom = try rt.atoms.newValueSymbol("gc-call-value-inline-arg-root");
    const arg_value = try rt.symbolValue(arg_atom);
    const args = [_]core.JSValue{arg_value};

    const Trigger = struct {
        rt: *core.JSRuntime,
        atom_id: u32,
        saw_arg: bool = false,
        trace_failed: bool = false,

        fn trigger(context: ?*anyopaque, size: usize) void {
            _ = size;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const saved_trigger_fn = self.rt.memory.trigger_gc_fn;
            const saved_trigger_ctx = self.rt.memory.trigger_gc_ctx;
            self.rt.memory.trigger_gc_fn = null;
            self.rt.memory.trigger_gc_ctx = null;
            defer {
                self.rt.memory.trigger_gc_fn = saved_trigger_fn;
                self.rt.memory.trigger_gc_ctx = saved_trigger_ctx;
            }
            _ = self.rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {}; // engine-frames-active trigger
            self.saw_arg = self.rt.atoms.name(self.atom_id) != null;
        }
    };

    const saved_trigger_fn = rt.memory.trigger_gc_fn;
    const saved_trigger_ctx = rt.memory.trigger_gc_ctx;
    var trigger = Trigger{
        .rt = rt,
        .atom_id = arg_atom,
    };
    rt.memory.trigger_gc_fn = Trigger.trigger;
    rt.memory.trigger_gc_ctx = &trigger;
    defer {
        rt.memory.trigger_gc_fn = saved_trigger_fn;
        rt.memory.trigger_gc_ctx = saved_trigger_ctx;
    }

    const result = try callValueOrBytecodeRoot(
        ctx,
        null,
        global,
        core.JSValue.undefinedValue(),
        func_value,
        &args,
        null,
        null,
    );
    defer result.free(rt);
    rt.memory.trigger_gc_fn = saved_trigger_fn;
    rt.memory.trigger_gc_ctx = saved_trigger_ctx;

    try std.testing.expect(!trigger.trace_failed);
    try std.testing.expect(trigger.saw_arg);

    func_value.free(rt);
    func_alive = false;
    arg_value.free(rt);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(arg_atom) == null);
}

// --- Class instance initialization moved to class_init_ops.zig ---
const class_init_ops = @import("class_init_ops.zig");

const disposable_ops = @import("disposable_ops.zig");

// --- Error stack ops moved to error_stack_ops.zig ---
const error_stack_ops = @import("error_stack_ops.zig");

// --- RegExp fast paths moved to regexp_fastpath.zig ---
const regexp_fastpath = @import("regexp_fastpath.zig");

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
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
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
) !bool {
    if (!isCallableValue(constructor_value)) return false;
    if (object_ops.objectFromValue(constructor_value)) |constructor_object| {
        if (constructor_object.class_id == core.class.ids.bound_function) {
            const target = constructor_object.boundTarget() orelse return error.TypeError;
            return ordinaryHasInstance(ctx, output, global, target, value, caller_function, caller_frame);
        }
    }
    const object = object_ops.objectFromValue(value) orelse return false;
    // Fast `.prototype` read: a class constructor (and any non-proxy callable)
    // carries `prototype` as an own data property, so read it directly without
    // building/destroying a Descriptor (qjs reads JS_ATOM_prototype once,
    // quickjs.c:8078). A normal function's lazy-autoinit prototype, an
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
    defer proto_value.free(ctx.runtime);
    const prototype = object_ops.objectFromValue(proto_value) orelse return error.TypeError;
    // Walk the prototype chain. The non-proxy step IS object.getPrototype() (a
    // direct shape.proto deref); inline it and only call the trap-aware step for
    // proxies / the throw-type-error intrinsic, mirroring qjs's p->shape->proto
    // walk (quickjs.c:8087-8125) that bypasses [[GetPrototypeOf]] for ordinary
    // objects.
    var current: ?*core.Object = object;
    while (current) |candidate| {
        const next = if (candidate.isProxy() or object_ops.isThrowTypeErrorIntrinsicObject(candidate))
            try object_ops.objectGetPrototypeOfStep(ctx, output, global, candidate, caller_function, caller_frame)
        else
            candidate.getPrototype();
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
    const this_arg = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
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
    const this_arg = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const arg_array = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    // qjs:41224: undefined/null array_arg calls the target with no arguments.
    if (arg_array.isNull() or arg_array.isUndefined()) {
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
/// (qjs:41167) "not a object" for the non-object argument list.
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
    if (!arg_array.isObject()) return throwApplyTypeError(ctx, global, "not a object");
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

// Native-builtin construct-record ids for the table-dispatched constructors the
// VM construct path routes through `builtin_dispatch.callConstructRecord`. The
// VM dispatcher decodes the constructor's native id and matches against these
// instead of comparing the resolved function name, so a user function named
// "Date"/"String"/"RegExp"/"Object" no longer aliases the builtin (matching the
// native-id keying `exec/construct.zig` adopted in Phase 6b-3d). The construct
// branches run the same builtin `constructWithPrototype` bodies the VM fast
// paths previously called directly; the VM-context argument coercion stays on
// the exec side (here for Date/String, inside `regExpConstructCall` for
// RegExp) and the coerced args + resolved prototype are threaded to the record.
const date_construct_id: u32 = @intFromEnum(core.host_function.builtin_method_ids.date.ConstructorMethod.construct);
const string_construct_id: u32 = @intFromEnum(core.host_function.builtin_method_ids.string.ConstructorMethod.call);
const regexp_construct_id: u32 = @intFromEnum(core.host_function.builtin_method_ids.regexp.ConstructorMethod.construct);
const object_construct_id: u32 = @intFromEnum(core.host_function.builtin_method_ids.object.ConstructorMethod.call);

// `Map.groupBy` static-method record id. The collection static-method id range
// is `StaticMethod.group_by == 101` in `exec/collection_ops.zig`, kept out of
// the core `builtin_method_ids.collection.PrototypeMethod` 1..21 range so it
// densifies into its own record slot. Exec keys the slow-path `groupBy`
// fallback by this stable value instead of importing registry metadata.
const collection_group_by_static_id: u32 = 101;

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
    return (builtin_dispatch.callConstructRecord(ctx, output, global, &.{}, function_object, array_construct_ref, prototype, args, caller_function, caller_frame) catch |err| switch (err) {
        error.RangeError => {
            if (exception_ops.pendingExceptionMatchesError(ctx, err)) return err;
            return exception_ops.throwRangeErrorMessage(ctx, global, "invalid array length");
        },
        else => return err,
    }) orelse error.TypeError;
}

/// Route VM-coerced construct args + resolved prototype through the builtin
/// record table. Returns null only when the id is somehow not construct-capable
/// (never for the ids passed here), so callers can keep a defensive fallback.
fn constructBuiltinNativeRecordVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: ?*core.Object,
    native_ref: core.function.NativeBuiltinRef,
    prototype: ?*core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    return builtin_dispatch.callConstructRecord(ctx, output, global, &.{}, function_object, native_ref, prototype, args, caller_function, caller_frame);
}

fn constructStringBuiltinNativeVm(
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

    return constructStringBuiltinNativeInScope(ctx, output, global, function_object, native_ref, new_target, args, caller_function, caller_frame) catch |err| {
        try builtin_dispatch.materializeRuntimeError(ctx, global, err);
        return err;
    };
}

fn constructStringBuiltinNativeInScope(
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
    var prototype = try object_ops.constructorPrototypeObject(ctx.runtime, new_target);
    defer prototype.deinit(ctx.runtime);
    const string_value = if (args.len == 0)
        try value_ops.createStringValue(ctx.runtime, "")
    else
        try string_ops.toStringForAnnexB(ctx, output, global, args[0], caller_function, caller_frame);
    defer string_value.free(ctx.runtime);
    return builtin_dispatch.callConstructRecordInNativeScope(ctx, output, global, &.{}, function_object, native_ref, prototype.object(), &.{string_value}, caller_function, caller_frame);
}

fn constructDateBuiltinNativeVm(
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

    return constructDateBuiltinNativeInScope(ctx, output, global, function_object, native_ref, new_target, args, caller_function, caller_frame) catch |err| {
        try builtin_dispatch.materializeRuntimeError(ctx, global, err);
        return err;
    };
}

/// Promise remains on the legacy constructor-name dispatcher rather than the
/// internal record table. Give it the same C-function preflight, native
/// backtrace scope, and error materialization boundary as record-dispatched
/// constructors before it synchronously invokes the executor.
fn constructPromiseNativeVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    new_target: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    // Promise.length is 1; this is the JSCFunctionListEntry length analogue
    // used by QuickJS's native-stack preflight, not the observable argument
    // count or mutable `length` property.
    try builtin_dispatch.preflightCFunctionCall(ctx, global, function_object, 1);
    var native_scope = builtin_dispatch.NativeBacktraceScope.init(ctx, function_object);
    native_scope.push();
    defer native_scope.deinit();

    return promise_ops.promiseConstruct(ctx, output, global, new_target, args, caller_function, caller_frame) catch |err| {
        try builtin_dispatch.materializeRuntimeError(ctx, global, err);
        return err;
    };
}

fn constructDateBuiltinNativeInScope(
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
    var prototype = try object_ops.reflectConstructPrototypeVm(ctx, output, global, "Date", new_target, caller_function, caller_frame);
    defer prototype.deinit(ctx.runtime);
    var coerced_storage: [7]core.JSValue = undefined;
    var coerced: []core.JSValue = coerced_storage[0..0];
    var coerced_owned = false;
    defer if (coerced_owned) {
        for (coerced) |value| value.free(ctx.runtime);
    };
    var date_args: []const core.JSValue = args;
    if (args.len == 1) {
        if (object_ops.objectFromValue(args[0])) |object| {
            if (object.class_id == core.class.ids.date) {
                coerced_storage[0] = try date_ops.callDateBody(ctx, args[0], 1, &.{});
            } else {
                const primitive = try coercion_ops.toPrimitiveForAddition(ctx, output, global, args[0]);
                if (primitive.isString()) {
                    coerced_storage[0] = primitive;
                } else {
                    defer primitive.free(ctx.runtime);
                    if (primitive.isBigInt()) return @as(?core.JSValue, try exception_ops.throwTypeErrorMessage(ctx, global, "cannot convert bigint to number"));
                    coerced_storage[0] = try value_ops.toNumberValue(ctx.runtime, primitive);
                }
            }
            coerced = coerced_storage[0..1];
            coerced_owned = true;
            date_args = coerced;
        } else if (!args[0].isString()) {
            if (args[0].isBigInt()) return @as(?core.JSValue, try exception_ops.throwTypeErrorMessage(ctx, global, "cannot convert bigint to number"));
            coerced_storage[0] = try value_ops.toNumberValue(ctx.runtime, args[0]);
            coerced = coerced_storage[0..1];
            coerced_owned = true;
            date_args = coerced;
        }
    } else if (args.len >= 2) {
        var coerced_len: usize = 0;
        while (coerced_len < args.len and coerced_len < coerced_storage.len) : (coerced_len += 1) {
            coerced_storage[coerced_len] = try coercion_ops.toNumberForDateMethod(ctx, output, global, args[coerced_len], caller_function, caller_frame);
            coerced = coerced_storage[0 .. coerced_len + 1];
            coerced_owned = true;
        }
        date_args = coerced;
    }
    return builtin_dispatch.callConstructRecordInNativeScope(ctx, output, global, &.{}, function_object, native_ref, prototype.object(), date_args, caller_function, caller_frame);
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
        true,
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
        false,
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
    /// register and never re-compares it, quickjs.c:20839-20856).
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
    // (quickjs.c:20839-20856 holds new_target in a register).
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

pub const SameMachineConstructorPreparation = union(enum) {
    /// The QuickJS-style simple-field writer completed construction without
    /// entering the bytecode body.
    completed: core.JSValue,
    /// Owned base instance whose body must execute in the active Machine.
    instance: core.JSValue,
};

/// Continue an admitted constructor after OP_call_constructor has paid the
/// outer JS_CallConstructorInternal interrupt poll. Creates the eager
/// instance for a same-Machine bytecode frame. Derived entry is handled
/// separately by the opcode adapter. The second poll remains after instance
/// creation and before bytecode-frame stack preflight, matching
/// JS_CallInternal's constructor entry ordering.
pub fn prepareSameMachineConstructorAfterFirstPoll(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    func: core.JSValue,
    new_target: core.JSValue,
    target: *const SameMachineConstructorTarget,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!SameMachineConstructorPreparation {
    std.debug.assert(!target.resolved.fb.isDerivedClassConstructor());
    _ = args;
    const instance = instance: {
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
                (target.function_object.getOwnConstructorPrototypeObject(ctx.runtime) catch null)) |prototype|
            {
                break :instance try createProfiledConstructorInstance(ctx.runtime, prototype, target.resolved.fb);
            }
            break :instance try createConstructorInstance(
                ctx,
                output,
                global,
                new_target,
                caller_function,
                caller_frame,
            );
        }
        break :instance try createBytecodeConstructorInstance(
            ctx,
            output,
            global,
            func,
            target.function_object,
            new_target,
            caller_function,
            caller_frame,
        );
    };
    errdefer instance.free(ctx.runtime);
    // E6: the CallConstructorInternal entry poll (quickjs.c:20817) is paid by
    // the caller. A second poll here was the eliminated per-`new` tax.
    return .{ .instance = instance };
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
    copy_argv: bool,
) HostError!core.JSValue {
    const function_global = object_ops.objectRealmGlobal(function_object) orelse global;
    if (fb.isDerivedClassConstructor()) {
        return try callFunctionBytecodeConstruct(ctx, function_value, func, core.JSValue.uninitialized(), args, function_object.functionCaptures(), output, function_global, new_target, copy_argv);
    }
    const instance = try createBytecodeConstructorInstance(ctx, output, global, func, function_object, new_target, caller_function, caller_frame);
    errdefer instance.free(ctx.runtime);
    defer noteConstructorAllocation(fb, instance);
    const result = try callFunctionBytecodeConstruct(ctx, function_value, func, instance, args, function_object.functionCaptures(), output, function_global, new_target, copy_argv);
    if (result.isObject()) {
        instance.free(ctx.runtime);
        return result;
    }
    result.free(ctx.runtime);
    return instance;
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
    copy_argv: bool,
) HostError!core.JSValue {
    // QuickJS JS_CallConstructorInternal polls before proxy/bound dispatch and
    // before testing constructibility. Recursive proxy/bound forwarding enters
    // this wrapper again, so every semantic constructor entry charges the
    // caller Realm exactly once.
    try exception_ops.pollInterrupt(ctx, global);
    return constructValueOrBytecodeWithNewTargetAfterInterruptPoll(ctx, output, global, func, args, caller_function, caller_frame, new_target, copy_argv);
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
    copy_argv: bool,
) HostError!core.JSValue {
    if (object_ops.objectFromValue(func)) |object| {
        if (object.proxyTarget() != null) {
            return object_ops.constructProxy(ctx, output, global, func, object, args, caller_function, caller_frame, new_target);
        }
    }
    if (object_ops.callableObjectFromValue(func)) |function_object| {
        if (function_object.class_id == core.class.ids.bound_function) {
            const target = function_object.boundTarget() orelse return error.TypeError;
            var combined = try boundFunctionArgs(ctx.runtime, function_object, args);
            defer freeArgs(ctx.runtime, combined);
            var combined_root = array_ops.ValueSliceRoot{};
            combined_root.init(ctx.runtime, &combined);
            defer combined_root.deinit();
            const next_new_target = if (func.sameValue(new_target)) target else new_target;
            return constructValueOrBytecodeWithNewTarget(ctx, output, global, target, combined, caller_function, caller_frame, next_new_target);
        }
        if (function_object.typedArrayElementSize() != 0 and function_object.typedArrayKind() != 0) {
            if (!new_target.sameValue(func)) {
                const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
                defer ctx.runtime.memory.allocator.free(name);
                if (try class_init_ops.constructBuiltinSuperConstructor(ctx, output, global, func, name, args, caller_function, caller_frame, new_target)) |constructed| {
                    return constructed;
                }
            }
            if (array_ops.typedArrayConstructVm(ctx, output, global, func, function_object, args, caller_function, caller_frame) catch |err| switch (err) {
                error.RangeError => return exception_ops.throwRangeErrorMessage(ctx, global, "invalid array index"),
                else => return err,
            }) |value| return value;
            return construct_mod.constructValue(ctx, func, args, &.{});
        }
        if (try array_ops.constructArrayBufferNativeRecord(ctx, output, global, func, function_object, args, new_target)) |constructed| {
            return constructed;
        }
        // Ordinary user bytecode constructor (`new Vec(x,y,z)`, class instances):
        // dispatch on the function class, not its name. A bytecode function body
        // is never one of the native builtins the name comparisons below match,
        // so hoist this ahead of the ~20 std.mem.eql(name, "...") checks and the
        // function-name materialization they require — the constructor tax that
        // made an empty `new E()` 2.4x qjs while a plain call is at parity.
        if (function_object.functionBytecode()) |function_value| {
            const fb = functionBytecodeFromValue(function_value) orelse return error.TypeError;
            if (!isConstructibleBytecodeFunctionObject(function_object, fb)) return error.TypeError;
            return constructOrdinaryBytecodeFunctionObject(ctx, output, global, func, function_object, function_value, fb, args, caller_function, caller_frame, new_target, copy_argv);
        }
        // Decode the constructor's native-builtin id once: the Date/String/RegExp
        // construct branches below gate on it (not the resolved function name)
        // and route their construct through the record table. Direct
        // construction (`new Date()`) reaches the per-id branches; subclass
        // `super(...)` (new_target != func) is intercepted above by
        // `constructBuiltinSuperConstructor`, exactly as for the other builtin
        // constructors.
        const construct_native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId());
        if (construct_native_ref) |native_ref| {
            // QuickJS `js_object_constructor`: when new.target is the active
            // Object function, construction shares the same nullish/ToObject
            // body as a plain call. A distinct new.target must instead create
            // from that constructor and therefore continues to the existing
            // name-aware custom-new-target branch below.
            if (native_ref.domain == .object and native_ref.id == object_construct_id and new_target.sameValue(func)) {
                const constructor_global = object_ops.objectRealmGlobal(function_object) orelse global;
                return (try constructBuiltinNativeRecordVm(ctx, output, constructor_global, function_object, native_ref, null, args, caller_function, caller_frame)) orelse error.TypeError;
            }
        }
        const dispatch_name = call_mod.nativeFunctionDispatchNameRef(ctx.runtime, function_object);
        defer if (dispatch_name) |dispatch| dispatch.name_value.free(ctx.runtime);
        var owned_name: ?[]u8 = null;
        defer if (owned_name) |name_bytes| ctx.runtime.memory.allocator.free(name_bytes);
        const name = if (dispatch_name) |dispatch|
            dispatch.name
        else blk: {
            owned_name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
            break :blk owned_name.?;
        };
        const is_native_array_constructor = function_object.arrayBuiltinMarker() == .constructor;
        // Order matters, not just the predicate: this whole gate only fires for
        // subclass `super(...)` / `Reflect.construct` with a foreign new.target
        // (qjs `js_create_from_ctor`, quickjs.c:8117, is likewise only consulted
        // when new.target differs). `isBuiltinConstructorName` is a ~30-way
        // string cascade (including the error-name and typed-array-name sets),
        // and `and` short-circuits left to right, so testing it first made every
        // direct `new Map()`/`new Date()`/`new WeakRef()` pay the full scan to
        // reach a branch it can never take. The three operands are pure, so
        // hoisting the one-word new.target comparison is behavior-identical.
        if (!new_target.sameValue(func) and
            isBuiltinConstructorName(name) and
            (!std.mem.eql(u8, name, "Array") or is_native_array_constructor))
        {
            if (try class_init_ops.constructBuiltinSuperConstructor(ctx, output, global, func, name, args, caller_function, caller_frame, new_target)) |constructed| {
                return constructed;
            }
        }
        if (std.mem.eql(u8, name, "Function")) return function_ops.constructFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "AsyncFunction")) return promise_ops.constructAsyncFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "GeneratorFunction")) return function_ops.constructGeneratorFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "AsyncGeneratorFunction")) return promise_ops.constructAsyncGeneratorFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "Symbol")) return exception_ops.throwTypeErrorMessage(ctx, global, "Symbol is not a constructor");
        if (array_ops.typedArrayConstructorName(name)) {
            if (try array_ops.typedArrayConstructFromIterable(ctx, output, global, func, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "Number")) {
            const primitive = try builtin_glue.numberFunctionCall(ctx, output, global, args);
            defer primitive.free(ctx.runtime);
            return construct_mod.constructValue(ctx, func, &.{primitive}, &.{});
        }
        if (construct_native_ref) |native_ref| {
            if (native_ref.domain == .string and native_ref.id == string_construct_id) {
                // `new String(x)`: coerce the argument to a primitive string in
                // VM context (so a user `toString`/`Symbol.toPrimitive` runs with
                // the caller frame), then run the builtin String constructor body
                // through the record table with the resolved wrapper prototype.
                return (try constructStringBuiltinNativeVm(ctx, output, global, function_object, native_ref, new_target, args, caller_function, caller_frame)) orelse error.TypeError;
            }
        }
        if (construct_native_ref) |native_ref| if (native_ref.domain == .date and native_ref.id == date_construct_id) {
            // `new Date(...)`: coerce the arguments in VM context exactly as the
            // retired `dateConstructWithPrototype` inline path did (so user
            // `valueOf`/`toString`/`Symbol.toPrimitive` run with the caller
            // frame), collect the coerced primitives, then run the builtin Date
            // constructor body through the record table with the resolved
            // prototype. The single-arg date-copy and string fast paths pass the
            // argument through unchanged.
            return (try constructDateBuiltinNativeVm(ctx, output, global, function_object, native_ref, new_target, args, caller_function, caller_frame)) orelse error.TypeError;
        };
        if (function_object.arrayBuiltinMarker() == .constructor) {
            var prototype = try object_ops.constructorPrototypeObject(ctx.runtime, new_target);
            defer prototype.deinit(ctx.runtime);
            return constructArrayNativeRecordVm(ctx, output, global, function_object, prototype.object(), args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "Promise")) return constructPromiseNativeVm(ctx, output, global, function_object, new_target, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "DisposableStack")) {
            var prototype = try object_ops.reflectConstructPrototypeVm(ctx, output, global, "DisposableStack", new_target, caller_function, caller_frame);
            defer prototype.deinit(ctx.runtime);
            return try object_ops.disposableStackConstructWithPrototype(ctx, global, prototype.object());
        }
        if (std.mem.eql(u8, name, "AsyncDisposableStack")) {
            var prototype = try object_ops.reflectConstructPrototypeVm(ctx, output, global, "AsyncDisposableStack", new_target, caller_function, caller_frame);
            defer prototype.deinit(ctx.runtime);
            return try promise_ops.asyncDisposableStackConstructWithPrototype(ctx, global, prototype.object());
        }
        if (construct_native_ref) |native_ref| if (native_ref.domain == .regexp and native_ref.id == regexp_construct_id) {
            // `new RegExp(...)`: `regExpConstructCall` performs the
            // observable pattern/flags coercion and resolves the instance
            // prototype after it (matching QuickJS `js_regexp_constructor` ->
            // `js_regexp_constructor_internal`); its terminal construct runs the
            // builtin RegExp constructor body through the record table.
            return regexp_fastpath.regExpConstructCall(ctx, output, global, function_object, new_target, args, caller_function, caller_frame);
        };
        if (core.host_function.builtin_method_id_lookup.collection.constructorId(name)) |kind| return builtin_glue.constructCollectionFromVm(ctx, output, global, func, kind, args);
        if (std.mem.eql(u8, name, "ArrayBuffer") or std.mem.eql(u8, name, "SharedArrayBuffer")) {
            var prototype = try object_ops.constructorPrototypeObject(ctx.runtime, new_target);
            defer prototype.deinit(ctx.runtime);
            return array_ops.arrayBufferConstructWithPrototype(ctx, output, global, args, prototype.object(), std.mem.eql(u8, name, "SharedArrayBuffer"));
        }
        if (std.mem.eql(u8, name, "DataView")) {
            const coerced = try builtin_glue.dataViewConstructorArgs(ctx, output, global, args);
            var prototype = try object_ops.constructorPrototypeObject(ctx.runtime, new_target);
            defer prototype.deinit(ctx.runtime);
            return try object_ops.dataViewConstructWithPrototype(ctx.runtime, args[0], coerced, prototype.object());
        }
        if (std.mem.eql(u8, name, "Proxy")) {
            return construct_mod.constructValue(ctx, func, args, &.{}) catch |err| switch (err) {
                error.TypeError => return exception_ops.throwTypeErrorMessage(ctx, global, "not an object"),
                else => err,
            };
        }
        if (std.mem.eql(u8, name, "DOMException")) {
            var prototype = try object_ops.constructorPrototypeObject(ctx.runtime, new_target);
            defer prototype.deinit(ctx.runtime);
            return try construct_mod.constructDOMExceptionObject(ctx.runtime, prototype.object(), args);
        }
        if (std.mem.eql(u8, name, "AggregateError")) {
            var prototype = try object_ops.constructorPrototypeObject(ctx.runtime, new_target);
            defer prototype.deinit(ctx.runtime);
            const constructor_global = object_ops.objectRealmGlobal(function_object) orelse global;
            return try object_ops.aggregateErrorConstructWithPrototype(ctx, output, constructor_global, prototype.object(), args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "SuppressedError")) {
            var prototype = try object_ops.constructorPrototypeObject(ctx.runtime, new_target);
            defer prototype.deinit(ctx.runtime);
            return try object_ops.suppressedErrorConstructWithPrototype(ctx, output, global, prototype.object(), args, caller_function, caller_frame);
        }
        if (exception_ops.isErrorConstructorName(name)) {
            var prototype = try object_ops.constructorPrototypeObject(ctx.runtime, new_target);
            defer prototype.deinit(ctx.runtime);
            return try object_ops.errorConstructWithPrototype(ctx, output, global, name, prototype.object(), args, caller_function, caller_frame);
        }
        if (function_object.hostFunctionKind() == core.host_function.ids.external_host) {
            return constructExternalHostFunction(ctx, output, global, function_object, args, caller_function, caller_frame, new_target);
        }
        if (function_object.class_id == core.class.ids.c_function and !isBuiltinConstructorName(name)) return error.TypeError;
    }
    if (func.isFunctionBytecode()) {
        const fb = functionBytecodeFromValue(func) orelse return error.TypeError;
        if (!isConstructibleFunctionBytecode(fb)) return error.TypeError;
        // qjs JS_CallConstructorInternal (quickjs.c:20837): a DERIVED class ctor
        // allocates NO instance and does NO prototype lookup — `this` stays
        // uninitialized (TDZ) until super() builds the object via new.target and
        // binds it. Only base/ordinary ctors get the eager js_create_from_ctor
        // instance (quickjs.c:20842).
        if (fb.isDerivedClassConstructor()) {
            return try callFunctionBytecodeConstruct(ctx, func, func, core.JSValue.uninitialized(), args, &.{}, output, global, new_target, copy_argv);
        }
        const instance = try createConstructorInstance(ctx, output, global, new_target, caller_function, caller_frame);
        errdefer instance.free(ctx.runtime);
        const result = try callFunctionBytecodeConstruct(ctx, func, func, instance, args, &.{}, output, global, new_target, copy_argv);
        if (result.isObject()) {
            instance.free(ctx.runtime);
            return result;
        }
        result.free(ctx.runtime);
        return instance;
    }
    if (object_ops.functionObjectFromValue(func)) |function_object| {
        // Fallback for a bytecode function object not reached through the
        // callableObjectFromValue hoist above (kept so no construct form is
        // lost); the common `new UserFn()` path already returned there.
        const function_value = function_object.functionBytecode() orelse return error.TypeError;
        const fb = functionBytecodeFromValue(function_value) orelse return error.TypeError;
        if (!isConstructibleBytecodeFunctionObject(function_object, fb)) return error.TypeError;
        return constructOrdinaryBytecodeFunctionObject(ctx, output, global, func, function_object, function_value, fb, args, caller_function, caller_frame, new_target, copy_argv);
    }
    if (object_ops.objectFromValue(func)) |object| {
        if (object.class_id == core.class.ids.object and object.proxyTarget() == null) {
            return exception_ops.throwTypeErrorMessage(ctx, global, "not a constructor");
        }
    }
    // QuickJS JS_CallInternal rejects non-object call targets before the
    // constructor-only object checks. This is the path used by a live
    // `super()` after the derived constructor's [[Prototype]] becomes null.
    if (!func.isObject()) return exception_ops.throwTypeErrorMessage(ctx, global, "not a function");
    return construct_mod.constructValue(ctx, func, args, &.{});
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
    if (!function_object.hasOwnProperty(core.atom.ids.prototype)) return error.TypeError;
    const instance = try createConstructorInstance(ctx, output, global, new_target, caller_function, caller_frame);
    var instance_owned = true;
    errdefer if (instance_owned) instance.free(ctx.runtime);

    const result = (try call_mod.callHostFunctionObjectForVm(ctx, output, global, function_object, instance, args)) orelse return error.TypeError;
    if (result.isObject()) {
        instance.free(ctx.runtime);
        instance_owned = false;
        return result;
    }
    result.free(ctx.runtime);
    instance_owned = false;
    return instance;
}

test "constructWeakRefWithPrototype roots direct symbol target while creating weak ref" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-qjs-weak-ref-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const symbol_value = try rt.symbolValue(symbol_atom);
    const weak_ref_value = try object_ops.constructWeakRefWithPrototype(rt, symbol_value, null);
    var weak_ref_alive = true;
    defer if (weak_ref_alive) weak_ref_value.free(rt);
    const weak_ref = object_ops.objectFromValue(weak_ref_value) orelse return error.TypeError;

    {
        const live = weak_ref.weakRefDeref(rt);
        defer live.free(rt);
        try std.testing.expect(live.same(symbol_value));
    }
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    symbol_value.free(rt);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
    try std.testing.expect(weak_ref.weakRefDeref(rt).isUndefined());

    weak_ref_value.free(rt);
    weak_ref_alive = false;
}

test "constructFinalizationRegistryWithPrototype roots function bytecode cleanup while creating registry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const fb = try bytecode.FunctionBytecode.createFixture(rt, .{
        .flags = .{ .func_kind = .generator },
        .cpool_count = 1,
    });
    var fb_published = false;
    errdefer if (!fb_published) fb.destroyUnpublishedFixture(rt);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-finalization-cleanup-bytecode-symbol");
    fb.cpoolSlice()[0] = try rt.symbolValue(symbol_atom);
    fb.publishFixtureNoFail(rt);
    fb_published = true;

    var cleanup_callback = core.JSValue.functionBytecode(&fb.header);
    var cleanup_callback_alive = true;
    defer if (cleanup_callback_alive) cleanup_callback.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const registry_value = try object_ops.constructFinalizationRegistryWithPrototype(ctx, cleanup_callback, null);
    var registry_alive = true;
    defer if (registry_alive) registry_value.free(rt);
    const registry = object_ops.objectFromValue(registry_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = registry.finalizationRegistryCleanupCallback() orelse return error.TypeError;
    try std.testing.expect(stored.same(cleanup_callback));

    registry_value.free(rt);
    registry_alive = false;
    cleanup_callback.free(rt);
    cleanup_callback_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "finalizationRegistryAppendCell roots direct symbol fields while allocating cell" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const registry = try core.Object.create(rt, core.class.ids.finalization_registry, null);
    var registry_alive = true;
    defer if (registry_alive) registry.value().free(rt);
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
    target_value.free(rt);
    held_value.free(rt);
    token_value.free(rt);

    registry.value().free(rt);
    registry_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(target_atom) == null);
    try std.testing.expect(rt.atoms.name(held_atom) == null);
    try std.testing.expect(rt.atoms.name(token_atom) == null);
}

pub fn isBuiltinConstructorName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Object") or
        std.mem.eql(u8, name, "Function") or
        std.mem.eql(u8, name, "AsyncFunction") or
        std.mem.eql(u8, name, "GeneratorFunction") or
        std.mem.eql(u8, name, "AsyncGeneratorFunction") or
        std.mem.eql(u8, name, "Array") or
        std.mem.eql(u8, name, "String") or
        std.mem.eql(u8, name, "Number") or
        std.mem.eql(u8, name, "Boolean") or
        std.mem.eql(u8, name, "Symbol") or
        std.mem.eql(u8, name, "BigInt") or
        std.mem.eql(u8, name, "Date") or
        std.mem.eql(u8, name, "RegExp") or
        core.error_names.isErrorConstructorName(name) or
        std.mem.eql(u8, name, "DOMException") or
        std.mem.eql(u8, name, "Iterator") or
        std.mem.eql(u8, name, "DisposableStack") or
        std.mem.eql(u8, name, "AsyncDisposableStack") or
        std.mem.eql(u8, name, "Promise") or
        std.mem.eql(u8, name, "Map") or
        std.mem.eql(u8, name, "Set") or
        std.mem.eql(u8, name, "WeakMap") or
        std.mem.eql(u8, name, "WeakSet") or
        std.mem.eql(u8, name, "WeakRef") or
        std.mem.eql(u8, name, "ArrayBuffer") or
        std.mem.eql(u8, name, "SharedArrayBuffer") or
        std.mem.eql(u8, name, "FinalizationRegistry") or
        std.mem.eql(u8, name, "DataView") or
        std.mem.eql(u8, name, "TypedArray") or
        core.typed_array_names.isConcrete(name) or
        std.mem.eql(u8, name, "Proxy");
}

pub fn createConstructorInstance(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    new_target: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var prototype = try object_ops.reflectConstructPrototypeVm(ctx, output, global, "Object", new_target, caller_function, caller_frame);
    defer prototype.deinit(ctx.runtime);
    const instance = try core.Object.create(ctx.runtime, core.class.ids.object, prototype.object());
    errdefer core.Object.destroyFromHeader(ctx.runtime, &instance.header);
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
        if (function_object.getOwnConstructorPrototypeObject(ctx.runtime) catch null) |prototype| {
            return createProfiledConstructorInstance(
                ctx.runtime,
                prototype,
                function_object.u.bytecode_function.function_bytecode,
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
    errdefer core.Object.destroyFromHeader(rt, &instance.header);
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
    const object = object_ops.objectFromValue(function_value) orelse return caller;
    return switch (object.class_id) {
        core.class.ids.c_function => object.nativeFunctionRealm() orelse error.InvalidBuiltinRegistry,
        core.class.ids.bytecode_function,
        core.class.ids.generator_function,
        core.class.ids.async_function,
        core.class.ids.async_generator_function,
        => object.bytecodeFunctionRealmContext() orelse error.InvalidBuiltinRegistry,
        core.class.ids.proxy => blk: {
            if (object_ops.isRevokedProxy(object)) {
                const caller_global = caller.global orelse return error.InvalidBuiltinRegistry;
                _ = try exception_ops.throwTypeErrorMessage(caller, caller_global, "revoked proxy");
                unreachable;
            }
            const target = object.proxyTarget() orelse break :blk caller;
            break :blk try functionRealmContext(caller, target);
        },
        core.class.ids.bound_function => blk: {
            const target = object.boundTarget() orelse return error.InvalidBuiltinRegistry;
            break :blk try functionRealmContext(caller, target);
        },
        // C_FUNCTION_DATA, C_CLOSURE, Promise/async special classes, and
        // every other JSClassCall-style object all use the caller realm.
        else => caller,
    };
}

pub fn functionRealmGlobal(caller: *core.JSContext, function_value: core.JSValue) HostError!*core.Object {
    const realm = try functionRealmContext(caller, function_value);
    return realm.global orelse error.InvalidBuiltinRegistry;
}

pub fn assertThrows(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    const expected = try property_ops.expectObject(args[0]);
    const expected_name = try call_mod.nativeFunctionNameForVm(ctx.runtime, expected);
    defer ctx.runtime.memory.allocator.free(expected_name);
    const result = callAssertThrowsCallback(ctx, output, global, args[1], caller_function, caller_frame) catch |err| {
        if (exception_ops.pendingExceptionMatchesError(ctx, err)) {
            if (try string_ops.consumePendingExceptionIfMatchesConstructor(ctx, expected_name)) {
                return core.JSValue.undefinedValue();
            }
            return error.JSException;
        }
        if (call_mod.errorNameMatchesConstructorForVm(err, expected_name)) {
            ctx.clearException();
            return core.JSValue.undefinedValue();
        }
        return error.JSException;
    };
    defer result.free(ctx.runtime);
    return error.JSException;
}

pub fn callAssertThrowsCallback(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    callback: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), callback, &.{}, caller_function, caller_frame);
}

pub fn collectIteratorValues(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const iterator = object_ops.objectFromValue(iterator_value) orelse return error.TypeError;
    const values = try core.Object.createArray(ctx.runtime, array_ops.arrayPrototypeFromGlobal(ctx.runtime, global));
    const values_value = values.value();
    errdefer values_value.free(ctx.runtime);
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try object_ops.getValueProperty(ctx, output, global, iterator.value(), next_key, caller_function, caller_frame);
    defer next_method.free(ctx.runtime);
    if (!isCallableValue(next_method)) return error.TypeError;

    var index: u32 = 0;
    while (true) : (index += 1) {
        const next = callValueOrBytecodeRoot(ctx, output, global, iterator.value(), next_method, &.{}, caller_function, caller_frame) catch |err| {
            try iterator_ops.iteratorCloseValue(ctx, output, global, iterator.value(), caller_function, caller_frame);
            return err;
        };
        defer next.free(ctx.runtime);
        const next_object = object_ops.objectFromValue(next) orelse {
            try iterator_ops.iteratorCloseValue(ctx, output, global, iterator.value(), caller_function, caller_frame);
            return error.TypeError;
        };
        const done = object_ops.getValueProperty(ctx, output, global, next_object.value(), core.atom.predefinedId("done", .string).?, caller_function, caller_frame) catch |err| {
            try iterator_ops.iteratorCloseValue(ctx, output, global, iterator.value(), caller_function, caller_frame);
            return err;
        };
        defer done.free(ctx.runtime);
        if (done.asBool() == true) break;
        const item = object_ops.getValueProperty(ctx, output, global, next_object.value(), core.atom.predefinedId("value", .string).?, caller_function, caller_frame) catch |err| {
            try iterator_ops.iteratorCloseValue(ctx, output, global, iterator.value(), caller_function, caller_frame);
            return err;
        };
        defer item.free(ctx.runtime);
        values.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(index), core.Descriptor.data(item, true, true, true)) catch |err| {
            try iterator_ops.iteratorCloseValue(ctx, output, global, iterator.value(), caller_function, caller_frame);
            return err;
        };
    }
    values.setArrayLength(index);
    return values_value;
}

pub fn getIteratorMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source_value: core.JSValue,
) !core.JSValue {
    const symbol_key = core.atom.predefinedId("Symbol.iterator", .symbol) orelse return error.TypeError;
    return object_ops.getValueProperty(ctx, output, global, source_value, symbol_key, null, null);
}

pub fn cacheIteratorNextMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
) !void {
    const iterator = try property_ops.expectObject(iterator_value);
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try object_ops.getValueProperty(ctx, output, global, iterator_value, next_key, null, null);
    defer next_method.free(ctx.runtime);
    if (!isCallableValue(next_method)) return error.TypeError;
    const cached = try iterator.cachedIteratorNextSlot(ctx.runtime);
    try iterator.setOptionalValueSlot(ctx.runtime, cached, next_method.dup());
}

pub fn appendIteratorValues(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target: *core.Object,
    source_value: core.JSValue,
    start_index: i32,
) !i32 {
    const source_object = property_ops.expectObject(source_value) catch null;
    const iterator_value = if (source_object != null and
        (source_object.?.class_id == core.class.ids.generator or source_object.?.class_id == core.class.ids.async_generator))
        source_value.dup()
    else blk: {
        const iterator_method = try getIteratorMethod(ctx, output, global, source_value);
        defer iterator_method.free(ctx.runtime);
        if (!isCallableValue(iterator_method)) {
            _ = exception_ops.throwTypeErrorMessage(ctx, global, "value is not iterable") catch |err| return err;
            return error.TypeError;
        }
        break :blk try callValueOrBytecodeRoot(ctx, output, global, source_value, iterator_method, &.{}, null, null);
    };
    defer iterator_value.free(ctx.runtime);
    if (!iterator_value.isObject()) return error.TypeError;
    var index = start_index;
    while (true) {
        const step = try iterator_ops.iteratorStepValue(ctx, output, global, iterator_value);
        if (step.done) {
            step.value.free(ctx.runtime);
            break;
        }
        try property_ops.defineDataProperty(ctx.runtime, target, core.atom.atomFromUInt32(@intCast(index)), step.value);
        step.value.free(ctx.runtime);
        index += 1;
    }
    return index;
}

/// Spread / rest append (`[...src]`, `f(...src)`), faithful to qjs
/// `js_append_enumerate` (quickjs.c:16814). Always resolves `src[@@iterator]`
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
    const source_object = property_ops.expectObject(source_value) catch null;

    // Generators / async-generators ARE iterators (their @@iterator returns
    // self); the generic helper handles them exactly as qjs's GetIterator does.
    if (source_object) |so| {
        if (so.class_id == core.class.ids.generator or so.class_id == core.class.ids.async_generator) {
            return appendIteratorValues(ctx, output, global, target, source_value, start_index);
        }
    }

    // iterator method = GetProperty(src, @@iterator)  (qjs quickjs.c:16834)
    const iterator_method = try getIteratorMethod(ctx, output, global, source_value);
    defer iterator_method.free(rt);
    if (!isCallableValue(iterator_method)) {
        _ = exception_ops.throwTypeErrorMessage(ctx, global, "value is not iterable") catch |err| return err;
        return error.TypeError;
    }

    // enumobj = src[@@iterator]()  (qjs GetIterator, quickjs.c:16843)
    const iterator_value = try callValueOrBytecodeRoot(ctx, output, global, source_value, iterator_method, &.{}, null, null);
    defer iterator_value.free(rt);
    const iterator = property_ops.expectObject(iterator_value) catch return error.TypeError;

    // next = GetProperty(enumobj, "next")  (qjs quickjs.c:16846)
    const next_method = blk: {
        if (iterator.cachedIteratorNext(rt)) |stored| break :blk stored.dup();
        const next_key = try rt.internAtom("next");
        defer rt.atoms.free(next_key);
        break :blk try object_ops.getValueProperty(ctx, output, global, iterator_value, next_key, null, null);
    };
    defer next_method.free(rt);
    if (!isCallableValue(next_method)) return error.TypeError;

    var index = start_index;

    // Fast path (qjs quickjs.c:16855-16866): default Array Iterator (value kind)
    // + builtin `next` + hole-free fast-array target (`length == count`).
    fast: {
        const next_obj = object_ops.objectFromValue(next_method) orelse break :fast;
        if (!next_obj.isArrayIteratorNextFunction()) break :fast;
        if (iterator.class_id != core.class.ids.array_iterator) break :fast;
        if (iterator.iteratorKindSlot().* != 2) break :fast; // 2 == ArrayIteratorKind.value
        const target_value = (iterator.iteratorTargetSlot().*) orelse break :fast;
        const target_obj = object_ops.objectFromValue(target_value) orelse break :fast;
        if (!target_obj.isArray() or target_obj.hasExoticMethods() or target_obj.proxyTarget() != null) break :fast;
        const elements = target_obj.arrayElements(); // len == array_count
        const length: usize = @intCast(target_obj.arrayLength());
        if (length != elements.len) break :fast; // qjs: len != count32 -> general_case
        const cursor = iterator.iteratorIndexSlot().*;
        if (cursor > elements.len) break :fast;
        var i: usize = cursor;
        while (i < elements.len) : (i += 1) {
            const item = elements[i].dup();
            defer item.free(rt);
            try property_ops.defineDataProperty(rt, target, core.atom.atomFromUInt32(@intCast(index)), item);
            index += 1;
        }
        iterator.iteratorIndexSlot().* = elements.len; // exhaust, matching a full drain
        return index;
    }

    // General case (qjs quickjs.c:16868): step the constructed iterator.
    while (true) {
        const step = try iterator_ops.iteratorStepValue(ctx, output, global, iterator_value);
        if (step.done) {
            step.value.free(rt);
            break;
        }
        try property_ops.defineDataProperty(rt, target, core.atom.atomFromUInt32(@intCast(index)), step.value);
        step.value.free(rt);
        index += 1;
    }
    return index;
}

pub fn isCallableValue(value: core.JSValue) bool {
    if (value.isFunctionBytecode()) return true;
    const object = object_ops.objectFromValue(value) orelse return false;
    return isFunctionLikeClass(object.class_id) or
        object_ops.proxyTargetIsCallableObject(object);
}

pub fn isIteratorIdentityFunction(rt: *core.JSRuntime, function_object: *core.Object) bool {
    _ = rt;
    return function_object.isIteratorIdentityFunction();
}

pub fn globalLexicalEnv(ctx: *core.JSContext) !*core.Object {
    if (ctx.lexicals) |env| return env;
    if (ctx.global) |global| {
        if (global.globalLexicals(ctx.runtime)) |env| {
            ctx.lexicals = env;
            return env;
        }
    }
    const env = try core.Object.create(ctx.runtime, core.class.ids.object, null);
    ctx.lexicals = env;
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

pub fn globalLexicalHas(ctx: *core.JSContext, atom_id: core.Atom) bool {
    const env = existingGlobalLexicalEnv(ctx) orelse return false;
    return env.hasOwnProperty(atom_id);
}

pub fn globalLexicalHasForGlobal(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom) bool {
    const env = existingGlobalLexicalEnvForGlobal(ctx, global) orelse return false;
    return env.hasOwnProperty(atom_id);
}

pub fn globalLexicalValue(ctx: *core.JSContext, atom_id: core.Atom) ?core.JSValue {
    const env = existingGlobalLexicalEnv(ctx) orelse return null;
    if (env.getOwnDataPropertyValue(atom_id)) |value| return value;
    if (!env.hasOwnProperty(atom_id)) return null;
    return try env.getProperty(atom_id);
}

/// Return a fresh ref to the VarRef cell backing a top-level lexical binding
/// in ctx.lexicals (qjs JS_PROP_VARREF slot -> pr->u.var_ref). The caller owns
/// the returned ref. Returns null if the binding is absent or not a cell slot
/// (so callers fall back to the legacy data-property path).
pub fn globalLexicalCell(ctx: *core.JSContext, atom_id: core.Atom) ?core.JSValue {
    const env = existingGlobalLexicalEnv(ctx) orelse return null;
    const index = env.findProperty(atom_id) orelse return null;
    const cell = env.asVarRefAt(index) orelse return null;
    return cell.valueRef().dup();
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
            if (env.asVarRefAt(index)) |cell| return cell.valueRef().dup();
        }
    }

    while (global.findProperty(atom_id)) |index| {
        const flags = global.propFlagsAt(index);
        if (flags.isAutoInit()) {
            const descriptor = (try global.getOwnProperty(ctx.runtime, atom_id)) orelse return error.InvalidBytecode;
            descriptor.destroy(ctx.runtime);
            // A failed builder must have returned its error and kept the
            // placeholder retryable. A successful read cannot leave the same
            // slot in AUTOINIT form.
            if (global.findProperty(atom_id)) |materialized_index| {
                if (global.propFlagsAt(materialized_index).isAutoInit()) return error.InvalidBytecode;
            }
            continue;
        }
        if (global.asVarRefAt(index)) |cell| return cell.valueRef().dup();
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
    errdefer env.value().free(ctx.runtime);
    try global.setGlobalUninitializedVars(ctx.runtime, env);
    return env;
}

/// qjs js_global_object_get_uninitialized_var (quickjs.c:17069-17096): return
/// the shared UNINITIALIZED cell for `atom_id`, creating and filing it in the
/// side table when absent. The caller owns the returned ref; the table slot
/// holds its own ref. The fresh cell's value carries the UNINITIALIZED
/// sentinel (js_create_var_ref(ctx, TRUE)); is_lexical/is_const stay false.
pub fn globalObjectGetUninitializedVar(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom) !core.JSValue {
    const rt = ctx.runtime;
    const env = try globalUninitializedVarsEnv(ctx, global);
    if (env.findProperty(atom_id)) |index| {
        if (env.asVarRefAt(index)) |cell| return cell.valueRef().dup();
    }
    const cell = try core.VarRef.createClosed(rt, core.JSValue.uninitialized());
    // qjs JS_PROP_C_W_E | JS_PROP_VARREF (17088).
    // appendPreparedPropertyEntry consumes the cell slot on both success and
    // failure, so no caller-side errdefer may release it again.
    try env.appendPreparedPropertyEntry(rt, atom_id, core.property.Flags.varRef(true, true, true), .{ .var_ref = cell });
    return cell.valueRef().dup();
}

/// qjs js_global_object_find_uninitialized_var (quickjs.c:17098-17123): if a
/// parked cell exists for `atom_id`, remove it from the side table and hand it
/// to the new declaration so every earlier capture aliases the new binding
/// (non-lexical reuse resets the value to undefined). Returns a fresh owned
/// ref, or null when no parked cell exists (caller creates a fresh cell).
pub fn globalObjectFindUninitializedVar(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom, is_lexical: bool) ?core.JSValue {
    const rt = ctx.runtime;
    const env = global.globalUninitializedVars() orelse return null;
    const index = env.findProperty(atom_id) orelse return null;
    const cell = env.asVarRefAt(index) orelse return null;
    const cell_value = cell.valueRef().dup();
    _ = env.deleteProperty(rt, atom_id);
    if (!is_lexical) {
        const old_value = cell.varRefValueSlot().*;
        cell.varRefValueSlot().* = core.JSValue.undefinedValue();
        old_value.free(rt);
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
            const desc = (try global.getOwnProperty(rt, atom_id)) orelse return error.OutOfMemory;
            desc.destroy(rt);
            if (global.propFlagsAt(initial_index).isAutoInit()) return error.OutOfMemory;
            continue;
        }

        var next_flags = initial_flags.withKind(.var_ref);
        if (is_function and initial_flags.configurable) {
            next_flags = core.property.Flags.varRef(true, true, configurable);
        }
        if (global.asVarRefAt(initial_index)) |cell| {
            if (next_flags.bits() != initial_flags.bits()) {
                try global.replaceOwnPropertyWithVarRefCell(rt, atom_id, initial_index, next_flags, cell);
            }
            cell.varRefIsConstSlot().* = !next_flags.writable;
            cell.varRefIsDeletableSlot().* = next_flags.configurable;
            return cell.valueRef().dup();
        }
        if (initial_flags.isAccessor() and (!is_function or !initial_flags.configurable)) return null;

        // initialClosureVarRef parked this exact unresolved-global cell in the
        // side table. Keep the table ref until the shape clone/slot replacement
        // succeeds; this makes OOM rollback automatic.
        const cell_value = try globalObjectGetUninitializedVar(ctx, global, atom_id);
        errdefer cell_value.free(rt);
        const cell = core.VarRef.fromValue(cell_value) orelse unreachable;
        try global.replaceOwnPropertyWithVarRefCell(rt, atom_id, initial_index, next_flags, cell);
        const parked = global.globalUninitializedVars() orelse return error.InvalidBytecode;
        if (!parked.deleteProperty(rt, atom_id)) return error.InvalidBytecode;
        return cell_value;
    }

    // qjs js_closure_define_global_var tail (quickjs.c:17186-17193): "if there
    // is a corresponding uninitialized variable, use it" — a capture parked in
    // the side table before this declaration is reused (value reset to
    // undefined), so every earlier capture aliases the new property cell.
    const cell_value = globalObjectFindUninitializedVar(ctx, global, atom_id, false) orelse blk: {
        const fresh = try core.VarRef.createClosed(rt, core.JSValue.undefinedValue());
        break :blk fresh.valueRef();
    };
    const cell = core.VarRef.fromValue(cell_value) orelse unreachable;
    // appendPreparedPropertyEntry consumes cell_value on both paths.
    try global.appendPreparedPropertyEntry(
        rt,
        atom_id,
        core.property.Flags.varRef(true, true, configurable),
        .{ .var_ref = cell },
    );
    cell.varRefIsDeletableSlot().* = configurable;
    return cell.valueRef().dup();
}

/// qjs js_closure_define_global_var for one non-lexical GLOBAL_DECL slot: ensure
/// the global object owns the VARREF property cell and bind this exact closure
/// slot before the next declaration is constructed.
pub fn defineGlobalDeclVarCell(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    ref_idx: u16,
    atom_id: core.Atom,
    configurable: bool,
    is_function: bool,
) !bool {
    if (ref_idx >= function.closureVar().len) return false;
    const declaration = function.closureVar()[ref_idx];
    if (declaration.closureType() != .global_decl or declaration.isLexical()) return false;
    if (!atomIdOrNameEql(ctx.runtime, declaration.var_name, atom_id)) return false;
    const cell_value = (try ensureGlobalObjectVarRefCell(ctx, global, atom_id, configurable, is_function)) orelse return false;
    defer cell_value.free(ctx.runtime);
    if (ref_idx >= frame.var_refs.len) {
        try frame_mod.ensureVarRefsCapacity(ctx, frame, ref_idx);
    }
    const old_slot = slot_ops.varRefSlot(frame, ref_idx);
    slot_ops.storeVarRefSlot(frame, ref_idx, cell_value.dup());
    old_slot.free(ctx.runtime);

    var rebound = true;
    const local_count = @min(function.varDefs().len, frame.locals.len);
    const global_cell = core.VarRef.fromValue(cell_value) orelse return error.InvalidBytecode;
    for (function.varDefs()[0..local_count], 0..) |vd, local_idx| {
        if (!atomIdOrNameEql(ctx.runtime, vd.var_name, atom_id)) continue;
        if (!varDefIsEvalHoistedVar(vd)) continue;
        // This is a compatibility mirror used by direct eval lookup. Keep the
        // frame plane raw; the authoritative global identity remains in the
        // typed frame.var_refs/global property cell.
        value_slot.replaceBorrowed(ctx.runtime, &frame.locals[local_idx], global_cell.varRefValue());
        rebound = true;
    }
    return rebound;
}

/// Create-or-fetch the VarRef cell for a top-level lexical in ctx.lexicals,
/// stored as a JS_PROP_VARREF slot (qjs js_closure_define_global_var, lexical
/// arm, quickjs.c:17134-17162). Returns a fresh ref the caller owns (for
/// frame.var_refs[idx]). The slot holds its own ref; the cell starts
/// uninitialized (TDZ) like qjs js_create_var_ref.
pub fn ensureGlobalLexicalCell(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom, is_const: bool) !core.JSValue {
    const env = try globalLexicalEnv(ctx);
    if (env.findProperty(atom_id)) |index| {
        if (env.asVarRefAt(index)) |cell| return cell.valueRef().dup();
    }
    const rt = ctx.runtime;
    // qjs quickjs.c:17148-17162: "if there is a corresponding global variable,
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
            global.prop_values[gidx].slot.var_ref = new_cell;
            // Keep one rollback ref because appendPreparedPropertyEntry consumes
            // the transferred property ref even when its shape allocation fails.
            const rollback_cell = old_cell.dupCell();
            var rollback_cell_owned = true;
            errdefer if (rollback_cell_owned) {
                old_cell.varRefValueSlot().* = new_cell.varRefValueSlot().*;
                new_cell.varRefValueSlot().* = core.JSValue.undefinedValue();
                old_cell.is_lexical = old_is_lexical;
                old_cell.varRefIsConstSlot().* = old_is_const;
                global.prop_values[gidx].slot.var_ref = rollback_cell;
                new_cell.freeCell(rt);
                rollback_cell_owned = false;
            };
            // add_var_ref (17210-17223): the old cell becomes the lexical cell.
            old_cell.is_lexical = true;
            old_cell.varRefIsConstSlot().* = is_const;
            try env.appendPreparedPropertyEntry(rt, atom_id, core.property.Flags.varRef(!is_const, false, false), .{ .var_ref = old_cell });
            rollback_cell.freeCell(rt);
            rollback_cell_owned = false;
            return old_cell.valueRef().dup();
        }
    }
    // qjs 17193: reuse a parked uninitialized capture cell if one exists (the
    // value stays UNINITIALIZED for the lexical TDZ window), else fresh.
    const cell_value = globalObjectFindUninitializedVar(ctx, global, atom_id, true) orelse blk: {
        const fresh = try core.VarRef.createClosed(rt, core.JSValue.uninitialized());
        break :blk fresh.valueRef();
    };
    const cell = core.VarRef.fromValue(cell_value) orelse unreachable;
    cell.varRefIsConstSlot().* = is_const;
    cell.is_lexical = true;
    // appendPreparedPropertyEntry consumes cell_value on both paths.
    try env.appendPreparedPropertyEntry(rt, atom_id, core.property.Flags.varRef(!is_const, false, false), .{ .var_ref = cell });
    return cell.valueRef().dup();
}

pub fn globalLexicalValueForGlobal(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom) ?core.JSValue {
    const env = existingGlobalLexicalEnvForGlobal(ctx, global) orelse return null;
    if (env.getOwnDataPropertyValue(atom_id)) |value| return value;
    const index = env.findProperty(atom_id) orelse return null;
    const cell = env.asVarRefAt(index) orelse return null;
    return cell.varRefValue().dup();
}

pub fn defineGlobalLexicalValue(ctx: *core.JSContext, atom_id: core.Atom, value: core.JSValue, is_const: bool) !void {
    const env = try globalLexicalEnv(ctx);
    if (!env.hasOwnProperty(atom_id)) {
        const rt = ctx.runtime;
        try env.defineOwnPropertyAssumingNew(rt, atom_id, core.Descriptor.data(value, !is_const, false, false));
    }
}

/// qjs js_closure_define_global_var PASS2 for a top-level script let/const:
/// run after PASS1 has succeeded. Creates the ctx.lexicals VARREF cell and
/// rebinds this exact GLOBAL_DECL slot to it, preserving QuickJS pass-2 closure
/// order. Returns false for a malformed/non-lexical slot so the caller can use
/// its non-GLOBAL_DECL fallback.
pub fn defineGlobalDeclLexicalCell(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    ref_idx: u16,
    atom_id: core.Atom,
    is_const: bool,
) !bool {
    if (ref_idx >= function.closureVar().len) return false;
    const declaration = function.closureVar()[ref_idx];
    if (declaration.closureType() != .global_decl or !declaration.isLexical() or declaration.var_name != atom_id) return false;
    const cell_value = try ensureGlobalLexicalCell(ctx, global, atom_id, is_const);
    if (ref_idx >= frame.var_refs.len) {
        try frame_mod.ensureVarRefsCapacity(ctx, frame, ref_idx);
    }
    const old_slot = slot_ops.varRefSlot(frame, ref_idx);
    slot_ops.storeVarRefSlot(frame, ref_idx, cell_value);
    old_slot.free(ctx.runtime);
    return true;
}

pub fn setGlobalLexicalValue(ctx: *core.JSContext, atom_id: core.Atom, value: core.JSValue) !bool {
    const env = existingGlobalLexicalEnv(ctx) orelse return false;
    if (env.findProperty(atom_id)) |index| {
        // qjs JS_SetPropertyInternal VARREF: write through cell->pvalue,
        // const guarded by cell->is_const. Shared cell => no write loss.
        if (env.asVarRefAt(index)) |cell| {
            if (cell.is_const) return error.TypeError;
            cell.setVarRefValue(ctx.runtime, value.dup());
            return true;
        }
    }
    if (!env.hasOwnProperty(atom_id)) return false;
    const rt = ctx.runtime;
    if (initializeGlobalLexicalValue(rt, env, atom_id, value)) return true;
    if (try env.setOwnWritableDataProperty(rt, atom_id, value)) return true;
    env.setProperty(rt, atom_id, value) catch |err| switch (err) {
        error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
        else => return err,
    };
    return true;
}

pub fn setGlobalLexicalValueForGlobal(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom, value: core.JSValue) !bool {
    const env = existingGlobalLexicalEnvForGlobal(ctx, global) orelse return false;
    if (!env.hasOwnProperty(atom_id)) return false;
    const rt = ctx.runtime;
    if (initializeGlobalLexicalValue(rt, env, atom_id, value)) return true;
    if (try env.setOwnWritableDataProperty(rt, atom_id, value)) return true;
    env.setProperty(rt, atom_id, value) catch |err| switch (err) {
        error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
        else => return err,
    };
    return true;
}

pub fn setGlobalLexicalValueForFastPathOwned(ctx: *core.JSContext, atom_id: core.Atom, value: core.JSValue) !bool {
    const env = existingGlobalLexicalEnv(ctx) orelse return false;
    const index = env.findProperty(atom_id) orelse return false;
    return env.setOwnDataPropertyAtForLexicalSyncOwned(ctx.runtime, index, atom_id, value);
}

pub fn initializeGlobalLexicalValue(rt: *core.JSRuntime, env: *core.Object, atom_id: core.Atom, value: core.JSValue) bool {
    for (env.shapeProps(), 0..) |prop, index| {
        if (prop.atom_id == core.atom.null_atom) continue;
        if (!atomIdOrNameEql(rt, prop.atom_id, atom_id)) continue;
        switch (env.propKindAt(index)) {
            .data => {
                const stored = &env.prop_values[index].slot.data;
                if (!stored.isUninitialized()) return false;
                const next = value.dup();
                const old_value = stored.*;
                stored.* = next;
                // Initialising a binding in a long-lived environment object is
                // an old-to-young edge like any other property store.
                rt.gc.generationalBarrier(&env.header, next.cycleMarkHeader());
                old_value.free(rt);
                return true;
            },
            .var_ref => {
                const cell = env.prop_values[index].slot.var_ref;
                if (!cell.varRefValue().isUninitialized()) return false;
                cell.setVarRefValue(rt, value.dup());
                return true;
            },
            .accessor, .auto_init => return false,
        }
    }
    return false;
}

fn varDefIsEvalHoistedVar(vd: bytecode.function_bytecode.BytecodeVarDef) bool {
    if (vd.hasScope() or vd.isLexical()) return false;
    return vd.varKind() == .normal or
        vd.varKind() == .function_decl or
        vd.varKind() == .new_function_decl;
}

pub fn indirectEval(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    eval_global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len == 0) return core.JSValue.undefinedValue();
    if (!args[0].isString()) return args[0].dup();
    var source = std.ArrayList(u8).empty;
    defer source.deinit(ctx.runtime.memory.allocator);
    try string_ops.appendSourceStringUtf8(ctx.runtime, &source, args[0]);

    const context_global = ctx.global;
    const use_global_lexicals = context_global == null or context_global.? != eval_global;
    const keep_active_lexicals = context_global == null;
    const saved_lexicals = ctx.lexicals;
    if (use_global_lexicals) ctx.lexicals = eval_global.globalLexicals(ctx.runtime);

    const EvalResult = @typeInfo(@TypeOf(indirectEval)).@"fn".return_type.?;
    const result: EvalResult = blk: {
        const compile_realm = ctx.runtime.contextForGlobalIncludingConstructing(eval_global) orelse break :blk error.InvalidBuiltinRegistry;
        var compiled = parser.compile(.{ .realm = compile_realm }, source.items, .{ .mode = .eval_indirect, .filename = "<eval>", .strict = false }) catch |err| break :blk err;
        defer compiled.deinit();
        if (compiled.syntax_error) |*parse_error| {
            // Compile-error surface: own fileName/lineNumber/columnNumber +
            // leading stack line (build_backtrace filename branch,
            // quickjs.c:7553-7570).
            const parse_filename = ctx.runtime.atoms.name(parse_error.filename) orelse "<eval>";
            _ = error_stack_ops.throwParseSyntaxError(ctx, eval_global, parse_filename, parse_error.position.line, parse_error.position.column, parse_error.message) catch |err| break :blk err;
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
        defer root_function_value.free(ctx.runtime);
        var root_values = [_]core.runtime.ValueRootValue{
            .{ .value = &root_function_value },
        };
        var root_frame = core.runtime.ValueRootFrame{
            .values = &root_values,
        };
        root_frame.activate(ctx.runtime);
        defer root_frame.deactivate(ctx.runtime);
        const root_function_object = object_ops.functionObjectFromValue(root_function_value) orelse break :blk error.InvalidBytecode;
        const root_bytecode_value = root_function_object.functionBytecode() orelse break :blk error.InvalidBytecode;
        const function = functionBytecodeFromValue(root_bytecode_value) orelse break :blk error.InvalidBytecode;
        var nested_stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.runtime.stackSize());
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
            .global_declarations_prevalidated = true,
        }) catch |err| exception_ops.normalizeEvalRuntimeError(err);
    };

    if (use_global_lexicals) {
        var rooted_result = result catch |err| {
            try call_mod.restoreEvalGlobalLexicals(ctx, eval_global, saved_lexicals, keep_active_lexicals);
            return err;
        };
        errdefer rooted_result.free(ctx.runtime);
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
        const saved_trigger_fn = self.rt.memory.trigger_gc_fn;
        const saved_trigger_ctx = self.rt.memory.trigger_gc_ctx;
        self.rt.memory.trigger_gc_fn = null;
        self.rt.memory.trigger_gc_ctx = null;
        defer {
            self.rt.memory.trigger_gc_fn = saved_trigger_fn;
            self.rt.memory.trigger_gc_ctx = saved_trigger_ctx;
        }
        _ = self.rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {}; // engine-frames-active trigger
    }
};

pub fn freeArgs(rt: *core.JSRuntime, args: []core.JSValue) void {
    for (args) |arg| arg.free(rt);
    if (args.len != 0) rt.memory.free(core.JSValue, args);
}

test "argsFromArrayLike roots initialized prefix while reading source" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try zjs_vm.contextGlobal(ctx);

    const source = try core.Object.create(rt, core.class.ids.object, null);
    var source_alive = true;
    defer if (source_alive) source.value().free(rt);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-args-from-array-like-prefix-root");
    const symbol_value = try rt.symbolValue(symbol_atom);
    try source.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(symbol_value, true, true, true));
    symbol_value.free(rt);
    try source.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(2), true, false, true));
    try source.defineAutoInitPropertyWithRealm(
        rt,
        core.atom.atomFromUInt32(1),
        "lazyArgsFromArrayLikeValue",
        0,
        core.property.Flags.data(true, true, true),
        global,
    );

    const Probe = struct {
        rt: *core.JSRuntime,
        atom_id: u32,
        saw_symbol: bool = false,
        trace_failed: bool = false,

        fn trigger(context: ?*anyopaque, size: usize) void {
            _ = size;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const saved_trigger_fn = self.rt.memory.trigger_gc_fn;
            const saved_trigger_ctx = self.rt.memory.trigger_gc_ctx;
            self.rt.memory.trigger_gc_fn = null;
            self.rt.memory.trigger_gc_ctx = null;
            defer {
                self.rt.memory.trigger_gc_fn = saved_trigger_fn;
                self.rt.memory.trigger_gc_ctx = saved_trigger_ctx;
            }
            _ = self.rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {}; // engine-frames-active trigger
            self.saw_symbol = self.rt.atoms.name(self.atom_id) != null;
        }
    };

    const saved_trigger_fn = rt.memory.trigger_gc_fn;
    const saved_trigger_ctx = rt.memory.trigger_gc_ctx;
    var probe = Probe{
        .rt = rt,
        .atom_id = symbol_atom,
    };
    rt.memory.trigger_gc_fn = Probe.trigger;
    rt.memory.trigger_gc_ctx = &probe;
    defer {
        rt.memory.trigger_gc_fn = saved_trigger_fn;
        rt.memory.trigger_gc_ctx = saved_trigger_ctx;
    }

    const args = try array_ops.argsFromArrayLike(ctx, null, global, source.value(), null, null);
    var args_alive = true;
    defer if (args_alive) freeArgs(rt, args);

    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expect(!probe.trace_failed);
    try std.testing.expect(probe.saw_symbol);

    freeArgs(rt, args);
    args_alive = false;
    source.value().free(rt);
    source_alive = false;
    _ = rt.runObjectCycleRemoval();
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
    copy_argv: bool,
) !core.JSValue {
    // A bytecode constructor takes the JS_CallConstructorInternal poll above
    // and then a second JS_CallInternal poll, both in the caller Realm. Only
    // after this point does the bytecode body switch to its function Realm.
    const interrupt_global = ctx.global orelse global;
    try exception_ops.pollInterrupt(ctx, interrupt_global);
    return callFunctionBytecodeModeStateAfterInterruptPoll(ctx, func, current_function_value, this_value, args, var_refs, output, interrupt_global, true, null, null, null, new_target_value, copy_argv, false) catch |err| {
        if (err == error.DerivedThisUninitialized) {
            // `global` is already the final bytecode callee's realm, while
            // `ctx` is still JS_CallConstructorInternal's caller_ctx. QuickJS
            // materializes OP_get_loc_checkthis in that caller context before
            // returning through the construct boundary (quickjs.c:18717-18728).
            const caller_global = ctx.global orelse return error.InvalidBuiltinRegistry;
            try throwRuntimeErrorForGlobal(ctx, caller_global, err);
        }
        return err;
    };
}

pub fn callFunctionBytecodeModeState(
    ctx: *core.JSContext,
    func: core.JSValue,
    current_function_value: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const *core.VarRef,
    output: ?*std.Io.Writer,
    global: *core.Object,
    defer_generators: bool,
    generator_state: ?*core.Object,
    resume_value: ?core.JSValue,
    stop_before_pc: ?usize,
    new_target_value: core.JSValue,
) HostError!core.JSValue {
    const caller_global = ctx.global orelse global;
    if (generator_state != null) {
        // QuickJS async_func_resume checks native SP with alloca_size=0
        // before entering the inner JS_CallInternal interrupt poll.
        const call_depth_guard = try vm_call.enterCallDepth(ctx, caller_global, 0);
        defer call_depth_guard.deinit();
        try exception_ops.pollInterrupt(ctx, caller_global);
        return callFunctionBytecodeModeStateAfterInterruptPoll(
            ctx,
            func,
            current_function_value,
            this_value,
            args,
            var_refs,
            output,
            caller_global,
            defer_generators,
            generator_state,
            resume_value,
            stop_before_pc,
            new_target_value,
            false,
            true,
        );
    }

    try exception_ops.pollInterrupt(ctx, caller_global);
    return callFunctionBytecodeModeStateAfterInterruptPoll(
        ctx,
        func,
        current_function_value,
        this_value,
        args,
        var_refs,
        output,
        caller_global,
        defer_generators,
        generator_state,
        resume_value,
        stop_before_pc,
        new_target_value,
        false,
        false,
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
    defer_generators: bool,
    generator_state: ?*core.Object,
    resume_value: ?core.JSValue,
    stop_before_pc: ?usize,
    new_target_value: core.JSValue,
    copy_argv: bool,
    call_depth_precharged: bool,
) HostError!core.JSValue {
    const fb = functionBytecodeFromValue(func) orelse return error.TypeError;
    const deferred_heap_entry = generator_state == null and
        ((defer_generators and
            (fb.functionKind() == .generator or fb.functionKind() == .async_generator)) or
            fb.functionKind() == .async);
    const heap_resident_frame = fb.functionKind() != .normal or generator_state != null;
    const planned_stack_bytes = if (heap_resident_frame)
        0
    else
        vm_call.bytecodeFrameAllocaSize(fb, args.len, copy_argv);
    var call_depth_guard: ?vm_call.CallDepthGuard = null;
    if (!call_depth_precharged and !deferred_heap_entry) {
        call_depth_guard = try vm_call.enterCallDepth(
            ctx,
            global,
            planned_stack_bytes,
        );
    }
    defer if (call_depth_guard) |guard| guard.deinit();

    const function_ctx = fb.realmContext() orelse return error.InvalidBuiltinRegistry;
    const function_global = function_ctx.global orelse return error.InvalidBuiltinRegistry;
    if (defer_generators and (fb.functionKind() == .generator or fb.functionKind() == .async_generator)) {
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

    const nested = fb;

    const fb_runtime_strict = fb.isStrictMode() or fb.runtimeStrictMode();
    if (fb.functionKind() == .async and generator_state == null) {
        var boxed_this: ?core.JSValue = null;
        defer if (boxed_this) |value| value.free(function_ctx.runtime);
        const effective_this = try coerceCallThis(function_ctx, function_global, fb_runtime_strict, this_value, &boxed_this);
        return promise_ops.asyncFunctionStart(
            function_ctx,
            func,
            current_function_value,
            effective_this,
            args,
            var_refs,
            output,
            function_global,
            false,
            ctx,
            global,
        );
    }
    const stop_on_yield = fb.functionKind() == .generator or fb.functionKind() == .async_generator;

    // Mirror QuickJS JS_CallInternal: non-suspending bytecode frames carve
    // their operand stack from the contiguous per-runtime VM stack arena
    // instead of heap-allocating per call. Generator/async resumption swaps
    // heap buffers in and out of the stack, so those keep heap mode.
    const arena_eligible = fb.functionKind() == .normal and generator_state == null;
    const arena_mark = if (arena_eligible) ctx.runtime.vm_stack.mark() else null;
    defer if (arena_mark) |mark| ctx.runtime.vm_stack.restore(mark);
    const operand_window: ?[]core.JSValue = if (arena_eligible)
        ctx.runtime.vm_stack.carve(&ctx.runtime.memory, @as(usize, fb.stack_size) + 1)
    else
        null;
    var nested_stack = if (operand_window) |window|
        stack_mod.Stack.initArenaWindow(&ctx.runtime.memory, ctx.runtime.vm_stack_arena_policy, window)
    else
        stack_mod.Stack.init(&ctx.runtime.memory, ctx.runtime.stackSize());
    defer if (generator_state) |generator| generator.finalizeGeneratorExecutionCompletion(ctx.runtime);
    defer nested_stack.deinit(ctx.runtime);
    // Async-generator bodies return their raw suspension/completion value to
    // the queue machine (exec/async_generator.zig execBody) — no promise
    // wrapping here (qjs async_func_resume returns the raw value/ret code,
    // quickjs.c:20951).
    return runWithCallEnvAfterInterruptPoll(.{
        .ctx = ctx,
        .stack = &nested_stack,
        .function = nested,
        .initial_this_value = this_value,
        .args = args,
        .var_refs = var_refs,
        .output = output,
        .global = global,
        .strict_unresolved_get_var = fb_runtime_strict,
        .stop_on_yield = stop_on_yield,
        .generator_state = generator_state,
        .resume_value = resume_value,
        .stop_before_pc = stop_before_pc,
        .current_function_value = current_function_value,
        .new_target_value = new_target_value,
        .call_depth_precharged = call_depth_precharged or call_depth_guard != null,
        .copy_argv = copy_argv,
    });
}

pub fn runGeneratorParameterInit(
    ctx: *core.JSContext,
    fb: *const bytecode.FunctionBytecode,
    nested: *const bytecode.FunctionBytecode,
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
    var nested_stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.runtime.stackSize());
    defer object.finalizeGeneratorExecutionCompletion(ctx.runtime);
    defer nested_stack.deinit(ctx.runtime);
    // Canonical generators suspend on their explicit OP_initial_yield after
    // parameter initialization. Ordinary async functions have no such opcode:
    // keep their resident frame parked at pc 0 until the promise driver starts
    // the body. Legacy mutable-bytecode and empty packed fixtures likewise
    // retain their pc-0 entry contract without reintroducing a production
    // bytecode scan.
    const stop_before_pc: ?usize = if (fb.functionKind() == .async or
        fb.legacyBytecodeAdapter() != null or
        fb.byteCode().len == 0)
        0
    else
        null;
    const env: zjs_vm.CallEnv = .{
        .ctx = call_entry_ctx,
        .stack = &nested_stack,
        .function = nested,
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
    var call_depth_guard: ?vm_call.CallDepthGuard = null;
    if (!call_depth_precharged) {
        call_depth_guard = try vm_call.enterCallDepth(
            call_entry_ctx,
            call_entry_global,
            0,
        );
    }
    defer if (call_depth_guard) |guard| guard.deinit();
    try exception_ops.pollInterrupt(call_entry_ctx, call_entry_global);
    return runWithCallEnvAfterInterruptPoll(env);
}

pub fn generatorNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    if (!receiver.isObject()) return null;
    const object = property_ops.expectObject(receiver) catch return null;
    if (object.class_id != core.class.ids.generator and object.class_id != core.class.ids.async_generator) return null;
    if (object.class_id == core.class.ids.async_generator) {
        // Async generators enqueue a request and return its promise (mirrors
        // js_async_generator_next GEN_MAGIC_NEXT, quickjs.c:21706); a call
        // arriving while EXECUTING only appends — never a TypeError.
        return try async_generator.asyncGeneratorEnqueue(ctx, output, global, object, args, 0);
    }
    const payload = object.generatorPayloadPtr();
    if (payload.executing) return error.TypeError;
    const generator_global = object.generatorFunctionRealmGlobalPtr() orelse global;
    if (payload.done) {
        const done_result = try iterator_ops.createIteratorResult(ctx.runtime, generator_global, core.JSValue.undefinedValue(), true);
        defer done_result.free(ctx.runtime);
        return done_result.dup();
    }
    const execution = payload.execution orelse return error.TypeError;
    const function_value = generatorFunctionBytecodeFromExecution(object, execution) orelse return error.TypeError;
    const current_function_value = if (execution.current_function.isUndefined()) receiver else execution.current_function;
    const resume_value = if (execution.suspended.pc != 0 and args.len > 0) args[0] else core.JSValue.undefinedValue();
    payload.executing = true;
    defer payload.executing = false;
    const result = callFunctionBytecodeModeState(
        ctx,
        function_value,
        current_function_value,
        execution.this_value,
        execution.suspended.storage.frame.args,
        execution.suspended.storage.frame.var_refs,
        output,
        generator_global,
        false,
        object,
        resume_value,
        null,
        core.JSValue.undefinedValue(),
    ) catch |err| {
        object.completeGeneratorExecution(ctx.runtime);
        return err;
    };
    defer result.free(ctx.runtime);
    if (payload.just_yielded and generatorHasYieldStarResult(payload)) {
        return result.dup();
    }
    return try iterator_ops.createIteratorResult(ctx.runtime, generator_global, result, !payload.just_yielded);
}

/// A raw generator step result: the yielded/returned value + done flag, with no
/// `{value, done}` iterator-result object built. The caller owns `value`.
pub const GeneratorValueDone = struct {
    value: core.JSValue,
    done: bool,
};

inline fn generatorFunctionBytecodeFromExecution(object: *core.Object, execution: *const core.object.GeneratorExecutionState) ?core.JSValue {
    const current = execution.current_function;
    if (current.isFunctionBytecode()) return current;
    const current_object = object_ops.objectFromValue(current) orelse return null;
    if (current_object == object) return null;
    return current_object.functionBytecode();
}

inline fn generatorHasYieldStarResult(payload: *const core.object.GeneratorPayload) bool {
    if (payload.yield_star_suspended) return true;
    const execution = payload.execution orelse return false;
    return !execution.yield_star_iterator.isUndefined();
}

/// Resume a SYNC generator one step and return (value, done) WITHOUT allocating the
/// iterator-result object, so a for-of consumer can skip it (qjs JS_IteratorNext2
/// built-in fast path, quickjs.c:16548). Returns null if `receiver` is not a sync
/// generator (caller falls back to the generic protocol). This is a parallel impl of
/// `generatorNext`'s sync path — kept separate so the hot, widely-used generatorNext
/// (.next() / spread / destructuring / yield*) stays byte-for-byte untouched; BOTH paths
/// are exercised by the test262 generator suite, so any divergence is caught. The
/// yield*-delegation case (result is ALREADY an iterator-result object) is unwrapped here
/// with the same done-then-conditional-value reads the generic for-of would do.
pub fn syncGeneratorStep(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
) !?GeneratorValueDone {
    if (!receiver.isObject()) return null;
    const object = property_ops.expectObject(receiver) catch return null;
    if (object.class_id != core.class.ids.generator) return null; // sync generators only
    const payload = object.generatorPayloadPtr();
    if (payload.executing) return error.TypeError;
    const generator_global = object.generatorFunctionRealmGlobalPtr() orelse global;
    if (payload.done) return .{ .value = core.JSValue.undefinedValue(), .done = true };
    const execution = payload.execution orelse return error.TypeError;
    const function_value = generatorFunctionBytecodeFromExecution(object, execution) orelse return error.TypeError;
    const current_function_value = if (execution.current_function.isUndefined()) receiver else execution.current_function;
    const resume_value = if (execution.suspended.pc != 0 and args.len > 0) args[0] else core.JSValue.undefinedValue();
    payload.executing = true;
    defer payload.executing = false;
    const result = callFunctionBytecodeModeState(
        ctx,
        function_value,
        current_function_value,
        execution.this_value,
        execution.suspended.storage.frame.args,
        execution.suspended.storage.frame.var_refs,
        output,
        generator_global,
        false,
        object,
        resume_value,
        null,
        core.JSValue.undefinedValue(),
    ) catch |err| {
        object.completeGeneratorExecution(ctx.runtime);
        return err;
    };
    if (payload.just_yielded and generatorHasYieldStarResult(payload)) {
        // yield* passthrough: `result` is already an iterator-result object — unwrap it
        // exactly as the generic for-of step would (read .done, then .value only if !done).
        defer result.free(ctx.runtime);
        const done_key = core.atom.predefinedId("done", .string).?;
        const done_value = try object_ops.getValueProperty(ctx, output, global, result, done_key, null, null);
        defer done_value.free(ctx.runtime);
        const done = value_ops.isTruthy(done_value);
        if (done) return .{ .value = core.JSValue.undefinedValue(), .done = true };
        const value_key = core.atom.predefinedId("value", .string).?;
        const value = try object_ops.getValueProperty(ctx, output, global, result, value_key, null, null);
        return .{ .value = value, .done = false };
    }
    return .{ .value = result, .done = !payload.just_yielded };
}

pub fn generatorYieldStarSuspended(rt: *core.JSRuntime, object: *core.Object) bool {
    _ = rt;
    return object.generatorYieldStarSuspended();
}

pub fn setGeneratorYieldStarSuspended(rt: *core.JSRuntime, object: *core.Object, value: bool) !void {
    _ = rt;
    object.generatorYieldStarSuspendedSlot().* = value;
}

pub fn generatorResumeCompletionType(rt: *core.JSRuntime, object: *core.Object) i32 {
    _ = rt;
    return object.generatorResumeCompletionType();
}

pub fn setGeneratorResumeCompletionType(rt: *core.JSRuntime, object: *core.Object, value: i32) !void {
    _ = rt;
    object.generatorResumeCompletionTypeSlot().* = value;
}

pub fn resumeGeneratorYieldStarCompletion(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    resume_value: core.JSValue,
    completion_type: i32,
) !core.JSValue {
    const function_value = object.generatorFunctionBytecode() orelse return error.TypeError;
    const current_function_value = object.generatorCurrentFunction() orelse receiver;
    try setGeneratorResumeCompletionType(ctx.runtime, object, completion_type);
    object.generatorExecutingSlot().* = true;
    defer object.generatorExecutingSlot().* = false;
    const result = callFunctionBytecodeModeState(
        ctx,
        function_value,
        current_function_value,
        object.generatorThis() orelse core.JSValue.undefinedValue(),
        object.generatorArgs(),
        object.generatorCaptures(),
        output,
        global,
        false,
        object,
        resume_value,
        null,
        core.JSValue.undefinedValue(),
    ) catch |err| {
        object.completeGeneratorExecution(ctx.runtime);
        return err;
    };
    defer result.free(ctx.runtime);
    const done = !object.generatorJustYielded();
    if (done) object.completeGeneratorExecution(ctx.runtime);
    if (object.generatorJustYielded() and generatorYieldStarSuspended(ctx.runtime, object)) return result.dup();
    return try iterator_ops.createIteratorResult(ctx.runtime, global, result, done);
}

pub fn generatorReturn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    if (!receiver.isObject()) return null;
    const object = property_ops.expectObject(receiver) catch return null;
    if (object.class_id != core.class.ids.generator and object.class_id != core.class.ids.async_generator) return null;
    if (object.class_id == core.class.ids.async_generator) {
        // Mirrors js_async_generator_next GEN_MAGIC_RETURN (quickjs.c:21706):
        // enqueue and return the request promise; the compiled return leg
        // awaits the argument before finalizer cleanup and settlement.
        return try async_generator.asyncGeneratorEnqueue(ctx, output, global, object, args, 1);
    }
    const payload = object.generatorPayloadPtr();
    if (payload.executing) return error.TypeError;
    const generator_global = object.generatorFunctionRealmGlobalPtr() orelse global;
    var return_value = if (args.len > 0) args[0].dup() else core.JSValue.undefinedValue();
    defer return_value.free(ctx.runtime);
    if (generatorYieldStarSuspended(ctx.runtime, object)) {
        return try resumeGeneratorYieldStarCompletion(ctx, output, generator_global, receiver, object, return_value, 1);
    }
    if (object.generatorYieldStarIterator() != null) {
        const step = generatorYieldStarReturnStep(ctx, output, generator_global, object, return_value) catch |err| {
            if (try resumeGeneratorCatchForRuntimeError(ctx, output, generator_global, receiver, object, err)) |handled| return handled;
            return err;
        };
        switch (step) {
            .yield_result => |result| {
                return result;
            },
            .complete => |value| {
                return_value.free(ctx.runtime);
                return_value = value;
            },
        }
    }
    if (object.generatorPc() != 0 and payload.started) {
        const execution = payload.execution orelse return error.TypeError;
        const function_value = generatorFunctionBytecodeFromExecution(object, execution) orelse return error.TypeError;
        const current_function_value = if (execution.current_function.isUndefined()) receiver else execution.current_function;
        payload.resume_completion_type = 1;
        payload.executing = true;
        defer payload.executing = false;
        const result = callFunctionBytecodeModeState(
            ctx,
            function_value,
            current_function_value,
            execution.this_value,
            execution.suspended.storage.frame.args,
            execution.suspended.storage.frame.var_refs,
            output,
            generator_global,
            false,
            object,
            return_value,
            null,
            core.JSValue.undefinedValue(),
        ) catch |err| {
            object.completeGeneratorExecution(ctx.runtime);
            return err;
        };
        defer result.free(ctx.runtime);
        const done = !payload.just_yielded;
        if (done) object.completeGeneratorExecution(ctx.runtime);
        if (!done and generatorHasYieldStarResult(payload)) return result.dup();
        return try iterator_ops.createIteratorResult(ctx.runtime, generator_global, result, done);
    }
    object.completeGeneratorExecution(ctx.runtime);
    return try iterator_ops.createIteratorResult(ctx.runtime, generator_global, return_value, true);
}

pub fn resumeGeneratorCatchForRuntimeError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    err: anytype,
) !?core.JSValue {
    if (object.class_id == core.class.ids.async_generator) return null;
    if (object.generatorPc() == 0 or !object.generatorStarted()) return null;
    const execution = object.generatorPayloadPtr().execution orelse return null;
    if (execution.suspended.catchTarget() == null) return null;
    const function_value = object.generatorFunctionBytecode() orelse return null;
    const thrown = try exception_ops.runtimeErrorValueForGeneratorCatch(ctx, global, err);
    defer thrown.free(ctx.runtime);
    const current_function_value = object.generatorCurrentFunction() orelse receiver;
    object.generatorResumeCompletionTypeSlot().* = 2;
    object.generatorJustYieldedSlot().* = false;
    const result = callFunctionBytecodeModeState(
        ctx,
        function_value,
        current_function_value,
        object.generatorThis() orelse core.JSValue.undefinedValue(),
        object.generatorArgs(),
        object.generatorCaptures(),
        output,
        global,
        false,
        object,
        thrown,
        null,
        core.JSValue.undefinedValue(),
    ) catch |resume_err| {
        object.completeGeneratorExecution(ctx.runtime);
        return resume_err;
    };
    defer result.free(ctx.runtime);
    const done = !object.generatorJustYielded();
    if (done) object.completeGeneratorExecution(ctx.runtime);
    const result_value = generatorCatchResumeResultValue(result);
    return try iterator_ops.createIteratorResult(ctx.runtime, global, result_value, done);
}

pub const GeneratorYieldStarReturnStep = union(enum) {
    yield_result: core.JSValue,
    complete: core.JSValue,
};

pub const GeneratorYieldStarThrowStep = union(enum) {
    yield_result: core.JSValue,
    complete: core.JSValue,
};

pub fn generatorYieldStarReturnStep(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    generator: *core.Object,
    return_arg: core.JSValue,
) !GeneratorYieldStarReturnStep {
    const iterator_value = (generator.generatorYieldStarIterator() orelse return error.TypeError).dup();
    defer iterator_value.free(ctx.runtime);
    const return_key = try ctx.runtime.internAtom("return");
    defer ctx.runtime.atoms.free(return_key);
    const return_method = try object_ops.getValueProperty(ctx, output, global, iterator_value, return_key, null, null);
    defer return_method.free(ctx.runtime);

    if (return_method.isUndefined() or return_method.isNull()) {
        generator.clearGeneratorYieldStarIterator(ctx.runtime);
        return .{ .complete = return_arg.dup() };
    }
    if (!isCallableValue(return_method)) return error.TypeError;

    const result_value = try callValueOrBytecodeRoot(ctx, output, global, iterator_value, return_method, &.{return_arg}, null, null);
    errdefer result_value.free(ctx.runtime);
    const result = property_ops.expectObject(result_value) catch return error.TypeError;

    const done_key = core.atom.predefinedId("done", .string).?;
    const done_value = try object_ops.getValueProperty(ctx, output, global, result.value(), done_key, null, null);
    defer done_value.free(ctx.runtime);
    const is_done = value_ops.isTruthy(done_value);

    if (!is_done) {
        generator.generatorJustYieldedSlot().* = true;
        return .{ .yield_result = result_value };
    }

    const value_key = core.atom.predefinedId("value", .string).?;
    const value = try object_ops.getValueProperty(ctx, output, global, result.value(), value_key, null, null);
    errdefer value.free(ctx.runtime);
    result_value.free(ctx.runtime);
    generator.clearGeneratorYieldStarIterator(ctx.runtime);
    return .{ .complete = value };
}

pub fn generatorYieldStarThrowStep(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    generator: *core.Object,
    thrown: core.JSValue,
) !GeneratorYieldStarThrowStep {
    const iterator_value = (generator.generatorYieldStarIterator() orelse return error.TypeError).dup();
    defer iterator_value.free(ctx.runtime);
    const throw_key = try ctx.runtime.internAtom("throw");
    defer ctx.runtime.atoms.free(throw_key);
    const throw_method = try object_ops.getValueProperty(ctx, output, global, iterator_value, throw_key, null, null);
    defer throw_method.free(ctx.runtime);

    if (throw_method.isUndefined() or throw_method.isNull()) {
        try generatorYieldStarCloseForMissingThrow(ctx, output, global, iterator_value);
        generator.clearGeneratorYieldStarIterator(ctx.runtime);
        return error.TypeError;
    }
    if (!isCallableValue(throw_method)) return error.TypeError;

    const result_value = try callValueOrBytecodeRoot(ctx, output, global, iterator_value, throw_method, &.{thrown}, null, null);
    errdefer result_value.free(ctx.runtime);
    const result = property_ops.expectObject(result_value) catch return error.TypeError;

    const done_key = core.atom.predefinedId("done", .string).?;
    const done_value = try object_ops.getValueProperty(ctx, output, global, result.value(), done_key, null, null);
    defer done_value.free(ctx.runtime);
    const is_done = value_ops.isTruthy(done_value);

    if (!is_done) {
        generator.generatorJustYieldedSlot().* = true;
        return .{ .yield_result = result_value };
    }

    const value_key = core.atom.predefinedId("value", .string).?;
    const value = try object_ops.getValueProperty(ctx, output, global, result.value(), value_key, null, null);
    errdefer value.free(ctx.runtime);
    result_value.free(ctx.runtime);
    generator.clearGeneratorYieldStarIterator(ctx.runtime);
    return .{ .complete = value };
}

pub fn generatorYieldStarCloseForMissingThrow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
) !void {
    const return_key = try ctx.runtime.internAtom("return");
    defer ctx.runtime.atoms.free(return_key);
    const return_method = try object_ops.getValueProperty(ctx, output, global, iterator_value, return_key, null, null);
    defer return_method.free(ctx.runtime);
    if (return_method.isUndefined() or return_method.isNull()) return;
    if (!isCallableValue(return_method)) return error.TypeError;
    const result = try callValueOrBytecodeRoot(ctx, output, global, iterator_value, return_method, &.{}, null, null);
    defer result.free(ctx.runtime);
    _ = property_ops.expectObject(result) catch return error.TypeError;
}

pub fn generatorThrow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    const object = property_ops.expectObject(receiver) catch return null;
    if (object.class_id != core.class.ids.generator and object.class_id != core.class.ids.async_generator) return null;
    if (object.class_id == core.class.ids.async_generator) {
        // Mirrors js_async_generator_next GEN_MAGIC_THROW (quickjs.c:21706).
        return try async_generator.asyncGeneratorEnqueue(ctx, output, global, object, args, 2);
    }
    const payload = object.generatorPayloadPtr();
    if (payload.executing) return error.TypeError;
    const generator_global = object.generatorFunctionRealmGlobalPtr() orelse global;
    const thrown = if (args.len > 0) args[0] else core.JSValue.undefinedValue();
    if (generatorYieldStarSuspended(ctx.runtime, object)) {
        return try resumeGeneratorYieldStarCompletion(ctx, output, generator_global, receiver, object, thrown, 2);
    }

    if (object.generatorYieldStarIterator() != null) {
        const step = generatorYieldStarThrowStep(ctx, output, generator_global, object, thrown) catch |err| {
            if (try resumeGeneratorCatchForRuntimeError(ctx, output, generator_global, receiver, object, err)) |handled| return handled;
            object.completeGeneratorExecution(ctx.runtime);
            return err;
        };
        switch (step) {
            .yield_result => |result| return result,
            .complete => |value| {
                defer value.free(ctx.runtime);
                const function_value = object.generatorFunctionBytecode() orelse return error.TypeError;
                const fb = functionBytecodeFromValue(function_value) orelse return error.TypeError;
                const current_function_value = object.generatorCurrentFunction() orelse receiver;
                object.generatorPcSlot().* = generatorPcAfterYieldStar(fb, object.generatorPc()) orelse return error.InvalidBytecode;
                object.generatorJustYieldedSlot().* = false;
                const result = callFunctionBytecodeModeState(
                    ctx,
                    function_value,
                    current_function_value,
                    object.generatorThis() orelse core.JSValue.undefinedValue(),
                    object.generatorArgs(),
                    object.generatorCaptures(),
                    output,
                    generator_global,
                    false,
                    object,
                    value,
                    null,
                    core.JSValue.undefinedValue(),
                ) catch |err| {
                    object.completeGeneratorExecution(ctx.runtime);
                    return err;
                };
                defer result.free(ctx.runtime);
                const done = !object.generatorJustYielded();
                if (done) object.completeGeneratorExecution(ctx.runtime);
                return try iterator_ops.createIteratorResult(ctx.runtime, generator_global, result, done);
            },
        }
    }

    if (object.generatorPc() != 0 and object.generatorStarted()) {
        const function_value = object.generatorFunctionBytecode() orelse return error.TypeError;
        const current_function_value = object.generatorCurrentFunction() orelse receiver;
        object.generatorResumeCompletionTypeSlot().* = 2;
        object.generatorJustYieldedSlot().* = false;
        const result = callFunctionBytecodeModeState(
            ctx,
            function_value,
            current_function_value,
            object.generatorThis() orelse core.JSValue.undefinedValue(),
            object.generatorArgs(),
            object.generatorCaptures(),
            output,
            generator_global,
            false,
            object,
            thrown,
            null,
            core.JSValue.undefinedValue(),
        ) catch |err| {
            object.completeGeneratorExecution(ctx.runtime);
            return err;
        };
        defer result.free(ctx.runtime);
        const done = !object.generatorJustYielded();
        if (done) object.completeGeneratorExecution(ctx.runtime);
        const result_value = generatorCatchResumeResultValue(result);
        return try iterator_ops.createIteratorResult(ctx.runtime, generator_global, result_value, done);
    }

    object.completeGeneratorExecution(ctx.runtime);
    _ = ctx.throwValue(thrown.dup());
    return error.JSException;
}

pub fn generatorCatchResumeResultValue(result: core.JSValue) core.JSValue {
    return if (result.isCatchOffset()) core.JSValue.undefinedValue() else result;
}

pub fn generatorPcAfterYieldStar(fb: *const bytecode.FunctionBytecode, pc: usize) ?usize {
    if (pc >= fb.byteCode().len) return null;
    const op_id = fb.byteCode()[pc];
    if (op_id != op.yield_star and op_id != op.async_yield_star) return null;
    const size = bytecode.opcode.sizeOf(op_id);
    if (size == 0 or pc + size > fb.byteCode().len) return null;
    return pc + size;
}

pub fn isDirectIteratorClass(class_id: core.class.ClassId) bool {
    return class_id == core.class.ids.array_iterator or
        class_id == core.class.ids.string_iterator or
        class_id == core.class.ids.map_iterator or
        class_id == core.class.ids.set_iterator or
        class_id == core.class.ids.regexp_string_iterator or
        class_id == core.class.ids.generator or
        class_id == core.class.ids.iterator_wrap;
}

pub fn wrapIteratorFromIterator(ctx: *core.JSContext, global: *core.Object, iterator: core.JSValue, next_method: ?core.JSValue) !core.JSValue {
    var rooted_iterator = iterator;
    var rooted_next_method = next_method orelse core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &rooted_iterator, &rooted_next_method });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    const iterator_object = object_ops.objectFromValue(rooted_iterator) orelse return error.TypeError;
    const prototype = try object_ops.wrapForValidIteratorPrototype(ctx.runtime, global);
    const wrapper = try core.Object.create(ctx.runtime, core.class.ids.iterator_wrap, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &wrapper.header);
    try wrapper.setOptionalValueSlot(ctx.runtime, wrapper.iteratorTargetSlot(), rooted_iterator.dup());
    if (next_method != null) {
        try wrapper.setOptionalValueSlot(ctx.runtime, wrapper.iteratorNextSlot(), rooted_next_method.dup());
        return wrapper.value();
    }
    if (iterator_object.cachedIteratorNext(ctx.runtime)) |cached_next_method| {
        try wrapper.setOptionalValueSlot(ctx.runtime, wrapper.iteratorNextSlot(), cached_next_method.dup());
        iterator_object.clearCachedIteratorNext(ctx.runtime);
    }
    return wrapper.value();
}

test "wrapIteratorFromIterator roots direct function bytecode next method while creating wrapper" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    global.class_id = core.class.ids.global_object;
    _ = try global.ensureGlobalPayload(rt);
    core.gc.retain(&global.header);
    ctx.global = global;
    const iterator = try core.Object.create(rt, core.class.ids.object, null);
    defer iterator.value().free(rt);

    const prototype = try core.Object.create(rt, core.class.ids.object, null);
    defer prototype.value().free(rt);
    try builtin_glue.storeRealmValue(rt, global, .wrap_for_valid_iterator_prototype, prototype.value());

    const fb = try bytecode.FunctionBytecode.createFixture(rt, .{
        .flags = .{ .func_kind = .generator },
        .cpool_count = 1,
    });
    var fb_published = false;
    errdefer if (!fb_published) fb.destroyUnpublishedFixture(rt);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-wrap-iterator-next-bytecode-symbol");
    fb.cpoolSlice()[0] = try rt.symbolValue(symbol_atom);
    fb.publishFixtureNoFail(rt);
    fb_published = true;

    var next_method = core.JSValue.functionBytecode(&fb.header);
    var next_method_alive = true;
    defer if (next_method_alive) next_method.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const wrapper_value = try wrapIteratorFromIterator(ctx, global, iterator.value(), next_method);
    var wrapper_alive = true;
    defer if (wrapper_alive) wrapper_value.free(rt);
    const wrapper = object_ops.objectFromValue(wrapper_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = wrapper.iteratorNext() orelse return error.TypeError;
    try std.testing.expect(stored.same(next_method));

    wrapper_value.free(rt);
    wrapper_alive = false;
    next_method.free(rt);
    next_method_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn pollGCSafePoint(ctx: *core.JSContext) !void {
    _ = ctx.runtime.gcSafepoint(null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PayloadMarkFailed => return error.OutOfMemory,
    };
}

pub fn runNextOsTimer(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) HostError!bool {
    if (ctx.hostEventLoop()) |host_event_loop| {
        return host_event_loop.runNextTimer(ctx, output, global) catch |err| return @errorCast(err);
    }
    return false;
}

pub fn runNextOsRwHandler(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) HostError!bool {
    if (ctx.hostEventLoop()) |host_event_loop| {
        return host_event_loop.runNextRwHandler(ctx, output, global) catch |err| return @errorCast(err);
    }
    return false;
}

pub fn enqueuePendingMicrotask(ctx: *core.JSContext, callback: core.JSValue) !void {
    try promise_ops.enqueuePendingPromiseJob(ctx, callback);
}

test "iterator_ops.createIteratorResult roots direct function bytecode value while creating result" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    global.class_id = core.class.ids.global_object;
    _ = try global.ensureGlobalPayload(rt);
    core.gc.retain(&global.header);
    ctx.global = global;

    const fb = try bytecode.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
    var fb_published = false;
    errdefer if (!fb_published) fb.destroyUnpublishedFixture(rt);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-iterator-result-bytecode-symbol");
    fb.cpoolSlice()[0] = try rt.symbolValue(symbol_atom);
    fb.publishFixtureNoFail(rt);
    fb_published = true;

    var result_value = core.JSValue.functionBytecode(&fb.header);
    var result_alive = true;
    defer if (result_alive) result_value.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const iterator_result_value = try iterator_ops.createIteratorResult(rt, global, result_value, false);
    var iterator_result_alive = true;
    defer if (iterator_result_alive) iterator_result_value.free(rt);
    const iterator_result = object_ops.objectFromValue(iterator_result_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_atom = try rt.internAtom("value");
    defer rt.atoms.free(value_atom);
    {
        const stored = try iterator_result.getProperty(value_atom);
        defer stored.free(rt);
        try std.testing.expect(stored.same(result_value));
    }

    iterator_result_value.free(rt);
    iterator_result_alive = false;
    result_value.free(rt);
    result_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn throwTypeErrorIntrinsicForGlobal(rt: *core.JSRuntime, global: *core.Object) !core.JSValue {
    if (global.cachedThrowTypeErrorIntrinsic(rt)) |stored| return stored.dup();

    const thrower = try core.function.nativeFunctionForGlobal(rt, global, "", 0);
    errdefer thrower.free(rt);
    const thrower_object = try property_ops.expectObject(thrower);
    try thrower_object.setFunctionRealmGlobalPtr(rt, global);
    if (object_ops.functionPrototypeFromGlobal(rt, global)) |function_prototype| {
        try thrower_object.setPrototype(rt, function_prototype);
    }

    try thrower_object.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(0), false, false, false));
    const empty_name = try value_ops.createStringValue(rt, "");
    defer empty_name.free(rt);
    try thrower_object.defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.data(empty_name, false, false, false));
    try thrower_object.addThrowTypeErrorIntrinsicFunction(rt);
    try thrower_object.freeze(rt);

    try object_ops.installFunctionPrototypeThrowTypeErrorAccessors(rt, global, thrower);
    const cached_thrower = try global.cachedThrowTypeErrorIntrinsicSlot(rt);
    try global.setOptionalValueSlot(rt, cached_thrower, thrower.dup());
    return thrower;
}

pub fn throwTypeErrorIntrinsic(ctx: *core.JSContext, global: *core.Object, _: *core.Object) !core.JSValue {
    const error_value = try exception_ops.createNamedError(ctx, global, "TypeError", "invalid property access");
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
    const header = value.objectHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

pub fn isFunctionLikeClass(class_id: core.class.ClassId) bool {
    return class_id == core.class.ids.c_function or
        class_id == core.class.ids.c_function_data or
        class_id == core.class.ids.c_closure or
        core.class.isBytecodeFunctionClass(class_id) or
        class_id == core.class.ids.bound_function;
}

pub fn isConstructibleFunctionBytecode(fb: *const bytecode.FunctionBytecode) bool {
    return fb.hasPrototype() and
        fb.functionKind() == .normal;
}

pub fn isConstructibleBytecodeFunctionObject(function_object: *const core.Object, fb: *const bytecode.FunctionBytecode) bool {
    return switch (function_object.class_id) {
        core.class.ids.bytecode_function => isConstructibleFunctionBytecode(fb),
        core.class.ids.generator_function,
        core.class.ids.async_function,
        core.class.ids.async_generator_function,
        => false,
        else => false,
    };
}

test "four-class bytecode constructability follows class and function flags" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
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
            errdefer object.value().free(runtime);

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
        defer function_object.value().free(rt);
        try std.testing.expect(isFunctionLikeClass(case.class_id));
        try std.testing.expectEqual(case.expected_constructor, try isConstructorLike(ctx, function_object.value()));
    }
}

pub fn isConstructorLike(ctx: *core.JSContext, value: core.JSValue) error{OutOfMemory}!bool {
    if (value.isFunctionBytecode()) {
        const fb = functionBytecodeFromValue(value) orelse return false;
        return isConstructibleFunctionBytecode(fb);
    }
    if (object_ops.functionObjectFromValue(value)) |function_object| {
        const function_value = function_object.functionBytecode() orelse return false;
        const fb = functionBytecodeFromValue(function_value) orelse return false;
        return isConstructibleBytecodeFunctionObject(function_object, fb);
    }
    if (object_ops.callableObjectFromValue(value)) |function_object| {
        if (function_object.class_id == core.class.ids.bound_function) {
            const target = function_object.boundTarget() orelse return false;
            return isConstructorLike(ctx, target);
        }
        if (function_object.class_id == core.class.ids.c_function_data) return false;
        if (function_object.flags.is_html_dda) return false;
        if (function_object.hostFunctionKind() == core.host_function.ids.external_host) {
            return function_object.hasOwnProperty(core.atom.ids.prototype);
        }
        if (function_object.class_id == core.class.ids.c_closure) return true;
        // A function carrying a construct-capable builtin native id (Date/
        // RegExp/String) is a constructor regardless of its dispatch name
        // (Phase 6b-3e: replaces the `date.isConstructorRecord` short circuit
        // with the generic table probe, which also covers RegExp/String).
        if (core.function.decodeNativeBuiltinId(function_object.nativeFunctionId())) |native_ref| {
            if (builtin_dispatch.isConstructRecordRef(ctx.runtime, native_ref)) return true;
        }
        // The native-record name lookup allocates; an allocation failure
        // must surface as OOM instead of misclassifying a real constructor
        // as "not a constructor" (found by test-oom injection). Non-OOM
        // lookup failures keep the conservative `false`.
        const name = call_mod.nativeFunctionNameForVm(ctx.runtime, function_object) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        defer ctx.runtime.memory.allocator.free(name);
        return isBuiltinConstructorName(name);
    }
    return object_ops.proxyTargetIsConstructor(ctx, value);
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
    const combined = try rt.memory.alloc(core.JSValue, bound_count + args.len);
    errdefer rt.memory.free(core.JSValue, combined);
    var filled: usize = 0;
    errdefer {
        var index: usize = 0;
        while (index < filled) : (index += 1) combined[index].free(rt);
    }
    for (bound_args, 0..) |arg, index| {
        combined[index] = arg.dup();
        filled += 1;
    }
    for (args, 0..) |arg, arg_index| {
        combined[bound_count + arg_index] = arg.dup();
        filled += 1;
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
        ctx.runtime.memory.allocator,
        "private class field '{s}' does not exist",
        .{atom_name},
    );
    defer ctx.runtime.memory.allocator.free(message);
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

    if (ctx.runtime.atoms.name(atom_id)) |name| {
        const message = try std.fmt.allocPrint(ctx.runtime.memory.allocator, "'{s}' is read-only", .{name});
        defer ctx.runtime.memory.allocator.free(message);
        return exception_ops.throwTypeErrorMessage(ctx, global, message);
    }
    return exception_ops.throwTypeErrorMessage(ctx, global, "property is read-only");
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
    target_value: core.JSValue,
    target: *core.Object,
    receiver_value: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!bool {
    _ = target_value;
    if (target.proxyTarget() != null) {
        return object_ops.proxySetValueProperty(ctx, output, global, receiver_value, target, atom_id, value, caller_function, caller_frame);
    }
    const receiver_object = object_ops.objectFromValue(receiver_value) orelse target;
    if (try array_ops.typedArrayPrototypeSet(ctx, output, global, receiver_value, receiver_object, target.getPrototype(), atom_id, value, caller_function, caller_frame)) |ok| return ok;
    if (value_ops.atomNameEql(ctx.runtime, atom_id, "__proto__")) {
        _ = try object_ops.objectProtoSetterCall(ctx, output, global, receiver_value, value, caller_function, caller_frame);
        return true;
    }
    if (try target.getOwnProperty(ctx.runtime, atom_id)) |own_desc| {
        defer own_desc.destroy(ctx.runtime);
        return object_ops.setWithOwnDescriptor(ctx, output, global, receiver_value, atom_id, value, own_desc, caller_function, caller_frame);
    }
    if (target.getPrototype()) |prototype| {
        return ordinarySetWithReceiver(ctx, output, global, prototype.value(), prototype, receiver_value, atom_id, value, caller_function, caller_frame);
    }
    return object_ops.setWithOwnDescriptor(ctx, output, global, receiver_value, atom_id, value, core.Descriptor.data(core.JSValue.undefinedValue(), true, true, true), caller_function, caller_frame);
}

pub fn definePropertiesCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 2) return error.TypeError;
    const target = property_ops.expectObject(args[0]) catch return @as(?core.JSValue, try exception_ops.throwTypeErrorMessage(ctx, global, "not an object"));
    try definePropertiesOnTarget(ctx, output, global, target, args[1], caller_function, caller_frame);
    return args[0].dup();
}

const math_ops = @import("math_ops.zig");

pub const IntegrityLevel = enum {
    sealed,
    frozen,
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
    if (properties_arg.isNull() or properties_arg.isUndefined()) return error.TypeError;
    const properties_value = if (object_ops.objectFromValue(properties_arg)) |_| properties_arg.dup() else try object_ops.primitiveObjectForAccess(ctx.runtime, global, properties_arg);
    defer properties_value.free(ctx.runtime);
    const properties = object_ops.objectFromValue(properties_value) orelse return error.TypeError;

    const keys = try object_ops.objectRestOwnKeys(ctx, output, global, properties);
    defer core.Object.freeKeys(ctx.runtime, keys);

    var pending = std.ArrayList(object_ops.PendingPropertyDescriptor).empty;
    defer {
        for (pending.items) |item| item.destroy(ctx.runtime);
        pending.deinit(ctx.runtime.memory.allocator);
    }

    for (keys) |key| {
        const prop_desc = try object_ops.objectRestOwnPropertyDescriptor(ctx, output, global, properties, key) orelse continue;
        defer prop_desc.destroy(ctx.runtime);
        if (prop_desc.enumerable != true) continue;

        const desc_value = try object_ops.getValueProperty(ctx, output, global, properties_value, key, caller_function, caller_frame);
        defer desc_value.free(ctx.runtime);
        const desc_object = object_ops.objectFromValue(desc_value) orelse return error.TypeError;
        const desc = try object_ops.descriptorFromObject(ctx, output, global, desc_value, desc_object, target, key, caller_function, caller_frame);
        errdefer desc.destroy(ctx.runtime);
        const pending_key = ctx.runtime.atoms.dup(key);
        var pending_key_owned = true;
        errdefer if (pending_key_owned) ctx.runtime.atoms.free(pending_key);
        try pending.append(ctx.runtime.memory.allocator, .{ .atom_id = pending_key, .desc = desc });
        pending_key_owned = false;
    }

    for (pending.items) |item| {
        const defined = if (target.proxyTarget() != null)
            object_ops.proxyDefineOwnProperty(ctx, output, global, target, item.atom_id, item.desc, caller_function, caller_frame) catch |err| switch (err) {
                error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
                error.InvalidLength => return error.RangeError,
                else => return err,
            }
        else blk: {
            if (try core.typed_array.typedArrayDefineOwnProperty(ctx.runtime, target, item.atom_id, item.desc)) |ok| {
                break :blk ok;
            } else {
                target.defineOwnProperty(ctx.runtime, item.atom_id, item.desc) catch |err| switch (err) {
                    error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
                    error.InvalidLength => return error.RangeError,
                    else => return err,
                };
                break :blk true;
            }
        };
        if (!defined) return error.TypeError;
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
        defer desc.destroy(ctx.runtime);
        if (desc.kind != .accessor) return false;
        if (desc.setter.isUndefined()) return error.AccessorWithoutSetter;
        const result = try callValueOrBytecodeSyncInternalOutlined(ctx, output, global, receiver, desc.setter, &.{value}, caller_function, caller_frame);
        result.free(ctx.runtime);
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
    defer rhs.free(ctx.runtime);
    const lhs = try stack.pop();
    defer lhs.free(ctx.runtime);
    const object = property_ops.expectObject(rhs) catch {
        _ = exception_ops.throwTypeErrorMessage(ctx, global, "invalid 'in' operand") catch |err| return err;
        return error.TypeError;
    };
    const key = try object_ops.toPropertyKeyAtom(ctx, output, global, lhs, caller_function, caller_frame);
    defer ctx.runtime.atoms.free(key);
    const found = if (object.proxyTarget() != null)
        try object_ops.hasValueProperty(ctx, output, global, rhs, object, key, caller_function, caller_frame)
    else
        try object_ops.ordinaryHasValueProperty(ctx, output, global, object, key, false, caller_function, caller_frame);
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
    defer rhs.free(ctx.runtime);
    const lhs = try stack.pop();
    defer lhs.free(ctx.runtime);
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
) !bool {
    _ = property_ops.expectObject(rhs) catch {
        _ = exception_ops.throwTypeErrorMessage(ctx, global, "invalid 'instanceof' right operand") catch |err| return err;
        return error.TypeError;
    };
    // qjs names this atom as the constant JS_ATOM_Symbol_hasInstance
    // (quickjs.c:8139). Resolve it at comptime rather than hashing the spelling
    // through the predefined-symbol map on every `instanceof`.
    const has_instance = try instanceofMethod(ctx, output, global, rhs, caller_function, caller_frame);
    defer has_instance.free(ctx.runtime);
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
    const has_instance_atom = (comptime core.atom.predefinedId("Symbol.hasInstance", .symbol)) orelse return error.TypeError;
    const fast = object_ops.probeNamedDataProperty(ctx.runtime, rhs, has_instance_atom);
    if (fast.slot) |slot| return slot.*.dup();
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
    const has_instance_atom = (comptime core.atom.predefinedId("Symbol.hasInstance", .symbol)) orelse return error.TypeError;
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
) !bool {
    if (!has_instance.isUndefined() and !has_instance.isNull()) {
        const result = try callValueOrBytecodeRoot(ctx, output, global, rhs, has_instance, &.{lhs}, caller_function, caller_frame);
        defer result.free(ctx.runtime);
        return coercion_ops.valueTruthy(result);
    }
    if (!isCallableValue(rhs)) {
        _ = exception_ops.throwTypeErrorMessage(ctx, global, "invalid 'instanceof' right operand") catch |err| return err;
        return error.TypeError;
    }
    if (!lhs.isObject()) {
        return false;
    }
    const object = try property_ops.expectObject(lhs);
    const proto_value = try object_ops.getValueProperty(ctx, output, global, rhs, core.atom.ids.prototype, caller_function, caller_frame);
    defer proto_value.free(ctx.runtime);
    if (!proto_value.isObject()) {
        return error.TypeError;
    }
    const proto = try property_ops.expectObject(proto_value);
    var current = try object_ops.objectGetPrototypeOfStep(ctx, output, global, object, caller_function, caller_frame);
    while (current) |candidate| {
        if (candidate == proto) {
            return true;
        }
        current = try object_ops.objectGetPrototypeOfStep(ctx, output, global, candidate, caller_function, caller_frame);
    }
    return false;
}

pub fn constructorNameEqlLocal(rt: *core.JSRuntime, object: *core.Object, expected: []const u8) !bool {
    const name_value = nativeFunctionNameValueLocal(rt, object) catch return false;
    defer name_value.free(rt);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &bytes, name_value);
    return std.mem.eql(u8, bytes.items, expected);
}

pub fn nativeFunctionNameValueLocal(rt: *core.JSRuntime, object: *core.Object) !core.JSValue {
    const dispatch_atom = object.nativeDispatchName();
    if (dispatch_atom != core.atom.null_atom) {
        const dispatch_name = try rt.atoms.toStringValue(rt, dispatch_atom);
        if (dispatch_name.isString()) return dispatch_name;
        dispatch_name.free(rt);
    }
    const name_value = try object.getProperty(core.atom.ids.name);
    if (!name_value.isString()) {
        name_value.free(rt);
        return error.TypeError;
    }
    return name_value;
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
    const unscopables_atom = core.atom.predefinedId("Symbol.unscopables", .symbol) orelse return false;
    const unscopables = try object_ops.getValueProperty(ctx, output, global, object_value, unscopables_atom, caller_function, caller_frame);
    defer unscopables.free(ctx.runtime);
    if (!unscopables.isObject()) return false;
    const blocked = try object_ops.getValueProperty(ctx, output, global, unscopables, atom_id, caller_function, caller_frame);
    defer blocked.free(ctx.runtime);
    return coercion_ops.valueTruthy(blocked);
}

pub fn lookupFrameVarRef(ctx: *core.JSContext, global: *core.Object, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, atom_id: core.Atom) ?core.JSValue {
    const rt = ctx.runtime;
    const count = @min(function.varRefNamesLen(), frame.var_refs.len);
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const name = function.varRefName(idx);
        if (!atomIdOrNameEql(rt, name, atom_id)) continue;
        if (closureVarIsNonLexicalGlobalSentinel(function, idx)) {
            if (globalLexicalValueForGlobal(ctx, global, atom_id)) |lexical_value| return lexical_value;
            continue;
        }
        const slot = slot_ops.varRefSlot(frame, idx);
        if (slot_ops.adapterIsDeletedEvalBinding(slot)) continue;
        const value = slot_ops.adapterValueDup(slot);
        // Non-lexical bindings have no TDZ. An UNINITIALIZED cell here is a
        // parked global/eval placeholder (including an alias of a deleted eval
        // binding), so the name lookup must continue to the next environment.
        // Lexical cells remain visible so the caller can report their TDZ.
        if (!function.varRefIsLexicalAt(idx) and value.isUninitialized()) {
            value.free(rt);
            continue;
        }
        return value;
    }
    return null;
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
    defer bytes.deinit(rt.memory.allocator);
    if (prefix) |text| {
        try bytes.appendSlice(rt.memory.allocator, text);
        try bytes.append(rt.memory.allocator, ' ');
    }
    if (core.atom.isTaggedInt(atom_id)) {
        var buf: [10]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{core.atom.atomToUInt32(atom_id)}) catch unreachable;
        try bytes.appendSlice(rt.memory.allocator, text);
        return value_ops.createStringValue(rt, bytes.items);
    }
    const atom_name = rt.atoms.name(atom_id) orelse "";
    if (rt.atoms.isPublicSymbol(atom_id)) {
        if (core.symbol.description(&rt.atoms, atom_id)) |description| {
            try bytes.append(rt.memory.allocator, '[');
            try bytes.appendSlice(rt.memory.allocator, description);
            try bytes.append(rt.memory.allocator, ']');
        }
    } else {
        try bytes.appendSlice(rt.memory.allocator, atom_name);
    }
    return value_ops.createStringValue(rt, bytes.items);
}

pub fn mappedArgumentsValue(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) ?core.JSValue {
    if (object.class_id != core.class.ids.mapped_arguments) return null;
    const index = core.array.arrayIndexFromAtom(&rt.atoms, atom_id) orelse return null;
    const refs = object.argumentsVarRefs();
    if (index >= refs.len) return null;
    const cell = refs[index] orelse return null;
    if (!object.hasOwnProperty(atom_id)) return null;
    return cell.varRefValue().dup();
}

pub fn setMappedArgumentsValue(ctx: *core.JSContext, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !bool {
    if (object.class_id != core.class.ids.mapped_arguments) return false;
    const index = core.array.arrayIndexFromAtom(&ctx.runtime.atoms, atom_id) orelse return false;
    const refs = object.argumentsVarRefsMut();
    if (index >= refs.len) return false;
    const cell = refs[index] orelse return false;
    if (!object.hasOwnProperty(atom_id)) {
        refs[index] = null;
        cell.release(ctx.runtime);
        return false;
    }
    cell.setVarRefValue(ctx.runtime, value.dup());
    return true;
}

pub fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
