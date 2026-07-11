const regexp_properties = @import("../libs/unicode.zig").regexp_properties;
const std = @import("std");
const bytecode = @import("../bytecode.zig");
const bignum = @import("../libs/bigint.zig");
const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const parser = @import("../parser.zig");
const unicode_lib = @import("../libs/unicode.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call_mod = @import("call.zig");
const construct_mod = @import("construct.zig");
const date_vm = @import("date_ops.zig");
const exception_ops = @import("vm_exception_ops.zig");
const frame_mod = @import("frame.zig");
const iter_vm = @import("iterator_ops.zig");
const inline_calls = @import("inline_calls.zig");
const module_mod = @import("module.zig");
const property_ops = @import("property_ops.zig");
const zjs_vm = @import("zjs_vm.zig");
const call_vm = @import("vm_call.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");
const HostError = exceptions.HostError;
const libc = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("poll.h");
});
const op = bytecode.opcode.op;
const eval_ret_atom: core.Atom = core.atom.ids.ret;
const runWithArgs = zjs_vm.runWithArgs;
const runWithCallEnv = zjs_vm.runWithCallEnv;
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

// --- Direct eval execution moved to eval_ops.zig ---
const eval_ops = @import("eval_ops.zig");

// --- Reflect/Atomics dispatch selectors are exec-owned (VM-natured) ---
const reflect_dispatch = core.host_function.builtin_method_ids.reflect;
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
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    argc: u16,
    output: ?*std.Io.Writer,
    global: *core.Object,
    allow_inline: bool,
    req_out: *InlineCallRequest,
) !ExecCallResult {
    // Zero-copy call sequence: borrow `func` and `args` directly from the
    // operand stack (which is owned by the caller's frame) instead
    // of popping them into a duplicated, separately rooted staging buffer.
    // The region is popped and released only after the call completes, so
    // the values stay rooted for the whole call.
    const total: usize = @as(usize, argc) + 1;
    if (stack.values.len < total) return error.StackUnderflow;
    const region_base = stack.values.len - total;
    const func = stack.values[region_base];
    const args: []const core.JSValue = stack.values[region_base + 1 ..][0..argc];

    // Fast path FIRST: a plain bytecode-to-bytecode call resolves to an inline
    // target. resolveInlineTarget returns null for class constructors, so a super()
    // call (whose callee is always a constructor) never resolves here — an inline
    // result is provably NOT a super-constructor invocation, so the
    // isCurrentSuperConstructor check below is unnecessary on this path. `this`
    // binds undefined (arrow targets override with their lexical `this` inside
    // resolveInlineTarget). A non-bytecode callee (host fn / ctor) falls through to
    // the general dispatch, which handles host-output (console.log) like any other
    // host function — qjs has no per-call host-output fast path.
    if (allow_inline) {
        if (inline_calls.resolveInlineTarget(ctx, global, core.JSValue.undefinedValue(), func)) |target| {
            req_out.* = .{ .target = target, .region_base = region_base, .argc = argc };
            return .inline_call;
        }
    }

    const is_super_constructor = class_init_ops.isCurrentSuperConstructor(ctx, frame, func);
    const arrow_super_this = if (is_super_constructor and !frame.function.flags.is_derived_class_constructor)
        class_init_ops.currentArrowLexicalSuperThis(ctx.runtime, frame)
    else
        null;
    defer if (arrow_super_this) |value| value.free(ctx.runtime);
    const arrow_constructor_this = if (is_super_constructor and !frame.function.flags.is_derived_class_constructor)
        class_init_ops.currentArrowConstructorThis(ctx.runtime, frame)
    else
        null;
    defer if (arrow_constructor_this) |value| value.free(ctx.runtime);
    const is_arrow_super_constructor = is_super_constructor and arrow_super_this != null;
    const super_this = if (is_super_constructor and frame.function.flags.is_derived_class_constructor)
        frame.constructorThisValue()
    else if (arrow_constructor_this) |value|
        value
    else if (arrow_super_this) |value|
        value
    else
        core.JSValue.undefinedValue();
    const result = callValueOrBytecodeClassModePreRooted(ctx, output, global, super_this, func, args, function, frame, is_super_constructor) catch |err| {
        popOwnedStackRegion(ctx.runtime, stack, region_base);
        try forof_ops.closeStackTopForOfIteratorForPendingError(ctx, output, global, stack);
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) {
            return .continue_loop;
        }
        return err;
    };
    popOwnedStackRegion(ctx.runtime, stack, region_base);
    if (is_super_constructor and frame.function.flags.is_derived_class_constructor) {
        defer result.free(ctx.runtime);
        if (slot_ops.varRefSlotIsUninitialized(frame.this_value)) {
            const next_this = if (result.isObject()) result else frame.constructorThisValue();
            try slot_ops.setSlotValue(ctx, &frame.this_value, next_this.dup());
            class_init_ops.initializeCurrentConstructorClassInstanceElements(ctx, output, global, function, frame) catch |err| {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) {
                    return .continue_loop;
                }
                return err;
            };
        } else {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) {
                return .continue_loop;
            }
            return error.ReferenceError;
        }
        try array_ops.pushSlotValue(stack, frame.this_value);
        return .done;
    }
    if (is_arrow_super_constructor) {
        defer result.free(ctx.runtime);
        if (arrow_super_this) |this_value_for_arrow| {
            if (!this_value_for_arrow.isUninitialized()) {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) {
                    return .continue_loop;
                }
                return error.ReferenceError;
            }
        }
        const next_this = if (result.isObject())
            result
        else if (arrow_constructor_this) |value|
            value
        else
            result;
        try class_init_ops.setCurrentArrowLexicalThis(ctx, frame, next_this.dup());
        stack.pushAssumeCapacity(next_this);
        return .done;
    }
    stack.pushOwnedAssumeCapacity(result);
    return .done;
}

/// Remove the callable at `region_base`, leaving its arguments on the operand
/// stack for `initArgumentsFromStack` to transfer without duplication.
pub fn popCallFuncFromStack(rt: *core.JSRuntime, stack: *stack_mod.Stack, region_base: usize) void {
    std.debug.assert(stack.values.len > region_base);
    const func_val = stack.values[region_base];
    const argc = stack.values.len - region_base - 1;
    if (argc > 0) {
        const src = stack.values.ptr[region_base + 1 .. region_base + 1 + argc];
        const dest = stack.values.ptr[region_base .. region_base + argc];
        @memmove(dest, src);
    }
    func_val.free(rt);
    stack.values = stack.values.ptr[0 .. stack.values.len - 1];
}

/// Pop and release every owned value above `region_base` on the operand
/// stack. Used by the zero-copy call sequence to drop the borrowed
/// `func | args...` region once a call completes.
pub fn popOwnedStackRegion(rt: *core.JSRuntime, stack: *stack_mod.Stack, region_base: usize) void {
    // Mirror qjs OP_call_method teardown (quickjs.c:18232): `call_argv` is a
    // register-held local and the loop just `JS_FreeValue(call_argv[i])` — no
    // per-slot poison-store and no re-derivation of the operand-stack base.
    // `free`/`releaseAndDestroy` runs GC-release + object destructors; none of
    // those push to this operand stack, so `stack.values.ptr` is loop-invariant.
    // Holding it in a local lets LLVM keep the base in a register instead of
    // reloading `stack.values.ptr` each iteration (opaque free() otherwise
    // forces the reload). Slots above the shrunk length are logically dead —
    // every `push*` overwrites its target and GC scans only `values[0..len]` —
    // so the qjs form omits the undefined poison-store entirely.
    const base = stack.values.ptr;
    var index = stack.values.len;
    while (index > region_base) {
        index -= 1;
        base[index].free(rt);
    }
    stack.values = base[0..region_base];
}

// noinline: this is the cold exception path shared by every `*Vm` opcode wrapper.
// Inlining it splices the whole catch machinery (iterator close, error
// construction, stack unwinding) into each hot handler's frame — inflating the
// spill set the hot path must set up and tear down every call. Outlining keeps a
// single `bl` on the cold edge and shrinks every wrapper's frame.
pub noinline fn handleCatchableRuntimeError(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
    err: anytype,
) !bool {
    return tryCatchInFrame(ctx, stack, frame, catch_target, global, err);
}

/// Attempt to dispatch `err` to the current frame's catch handler. Returns
/// true when the frame has a catch target: the operand stack is trimmed to
/// the marker, the exception value is pushed, and `frame.pc` moves to the
/// handler. Errors with no handler in the current frame propagate out of
/// the dispatch loop, where the inline-call machine unwinds suspended
/// frames before the error escapes `runWithArgsState`.
pub fn tryCatchInFrame(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
    err: anytype,
) !bool {
    core.profile.recordSlowPath();
    const is_pending_exception = exception_ops.pendingExceptionMatchesError(ctx, err);
    const error_info = if (is_pending_exception) null else exception_ops.runtimeErrorInfo(err) orelse return false;
    const target = catch_target.* orelse return false;
    closeFrameDestructuringIteratorsForAbruptCompletion(ctx, null, global, stack, frame);
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
                if (ctx.runtime.preallocated_oom_error) |prealloc| break :blk prealloc.dup();
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

pub fn callValueOrBytecode(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return callValueOrBytecodeClassMode(ctx, output, global, this_value, func, args, caller_function, caller_frame, false);
}

/// Coerce a call receiver per the ordinary [[Call]] `this` boxing for a
/// callee with strictness `runtime_strict`. Returns the effective `this`
/// borrowed from `this_value`, the realm `global`, or a freshly boxed
/// primitive wrapper. When a wrapper is created, `boxed_out.*` holds the
/// owned box and the caller frees it once the frame has duplicated the
/// value. Mirrors the boxing QuickJS `JS_CallInternal` performs before
/// entering a non-strict bytecode frame; shared by the recursive slow path
/// (`callFunctionBytecodeModeState`) and the inline frame setup
/// (`inline_calls.Machine.pushFrame`) so the boxing rules live in one place.
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    // `func` is the function value; the table dispatch only needs the function
    // object (`function_object`), so the raw value is no longer consulted here.
    _ = func;
    // Route the VM hot path through the same builtins-owned internal record
    // table the slow record dispatch uses (`call.zig:callNativeFunctionRecord`),
    // so exec carries zero compile-time knowledge of the migrated builtins. The
    // VM call site only has the realm `global` object (no `globals` slot array),
    // so pass the non-null `global` with an empty `globals`. Every migrated
    // builtin handler prefers `host_call.global` when it is set and only
    // consults `host_call.globals` on the bare-runtime (`global == null`)
    // fallback, so the empty slice is never read on this path.
    if (try builtin_dispatch.callInternalRecord(ctx, output, global, &.{}, function_object, this_value, native_ref, args, caller_function, caller_frame)) |value| {
        return value;
    }
    // `.atomics` is the only native-builtin domain reachable here that is not
    // (yet) in the internal record table; keep its dedicated handler after the
    // table probe, mirroring how the slow path retains `.atomics`/`.performance`/
    // `.host`/`.promise`. Every other domain that is neither table-dispatched
    // nor handled here returns null so the caller falls through to the
    // host/promise/name dispatch exactly as before.
    if (native_ref.domain == .atomics) {
        return try qjsAtomicsCallForNativeRecord(ctx, output, global, native_ref.id, args, caller_function, caller_frame);
    }
    return null;
}

pub fn throwRuntimeErrorForGlobal(ctx: *core.JSContext, global: *core.Object, err: anytype) !void {
    if (exception_ops.pendingExceptionMatchesError(ctx, err)) return;
    const error_info = exception_ops.runtimeErrorInfo(err) orelse return;
    const error_value = try exception_ops.createNamedError(ctx, global, error_info.name, error_info.message);
    if (ctx.hasException()) ctx.clearException();
    _ = ctx.throwValue(error_value);
}

pub fn callValueOrBytecodeClassMode(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    input_this_value: core.JSValue,
    input_func: core.JSValue,
    input_args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    allow_class_constructor_call: bool,
) HostError!core.JSValue {
    const this_value = input_this_value;
    const func = input_func;
    var inline_args: [8]core.JSValue = undefined;
    var args_buffer: core.runtime.ValueRootBuffer = .{};
    defer args_buffer.deinit(ctx.runtime);
    var args: []core.JSValue = inline_args[0..0];
    if (input_args.len <= inline_args.len) {
        args = inline_args[0..input_args.len];
        @memcpy(args, input_args);
    } else {
        args_buffer = try core.runtime.ValueRootBuffer.initCopy(ctx.runtime, input_args);
        args = args_buffer.values;
    }
    return callValueOrBytecodeClassModeDispatch(ctx, output, global, this_value, func, args, caller_function, caller_frame, allow_class_constructor_call);
}

/// Variant for callers whose `this_value`, `func`, and `args` are already
/// rooted (e.g. borrowed directly from a frame-rooted operand stack).
/// Skips the defensive copy and extra value-root frame of
/// `callValueOrBytecodeClassMode`.
pub fn callValueOrBytecodeClassModePreRooted(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    allow_class_constructor_call: bool,
) HostError!core.JSValue {
    return callValueOrBytecodeClassModeDispatch(ctx, output, global, this_value, func, args, caller_function, caller_frame, allow_class_constructor_call);
}

/// Map a global URI-family function name to its `.uri` record id: the four
/// `encodeURI`/`decodeURI` variants via the core `methodId` mode selector
/// (1..4), plus the legacy `escape`/`unescape` pair. Used by the string-name
/// call fallback to route these globals through the record table.
fn uriGlobalRecordId(name: []const u8) ?u32 {
    if (core.host_function.builtin_method_id_lookup.uri.methodId(name)) |mode| return mode;
    if (std.mem.eql(u8, name, "escape")) return core.uri.escape_id;
    if (std.mem.eql(u8, name, "unescape")) return core.uri.unescape_id;
    return null;
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
    caller_function: ?*const bytecode.Bytecode,
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
    resolved_record: *const core.host_function.InternalRecord,
    native_ref: core.function.NativeBuiltinRef,
    host_function,
    internal: core.host_function.InternalCallableTag,
    name_dispatch,
};

fn vmNativeCallableDispatch(function_object: *core.Object) VmNativeCallableDispatch {
    return switch (function_object.class_id) {
        core.class.ids.bound_function => .bound_function,
        else => blk: {
            if (function_object.nativeRecord()) |record| {
                break :blk .{ .resolved_record = record };
            }
            if (core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*)) |native_ref| {
                break :blk .{ .native_ref = native_ref };
            }
            if (function_object.hostFunctionKindSlot().* != 0) break :blk .host_function;
            const tag = function_object.internalCallableTag();
            if (tag != .none) break :blk .{ .internal = tag };
            break :blk .name_dispatch;
        },
    };
}

fn callInternalCallableByTag(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    tag: core.host_function.InternalCallableTag,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    return switch (tag) {
        .none => null,
        .promise_resolving => try promise_ops.qjsPromiseResolvingFunctionCall(ctx, output, global, function_object, args, caller_function, caller_frame),
        .promise_thenable_job => try promise_ops.qjsPromiseThenableJobCall(ctx, output, global, function_object, caller_function, caller_frame),
        .promise_reaction_job => try promise_ops.qjsPromiseReactionJobCall(ctx, output, global, function_object, caller_function, caller_frame),
        .promise_capability_executor => try promise_ops.qjsPromiseCapabilityExecutorCall(ctx, function_object, args),
        .promise_combinator_element => try promise_ops.qjsPromiseCombinatorElementCall(ctx, output, global, function_object, args, caller_function, caller_frame),
        .promise_finally_callback => try promise_ops.qjsPromiseFinallyCallbackCall(ctx, output, global, function_object, args, caller_function, caller_frame),
        .async_function_resume => try promise_ops.qjsAsyncFunctionResumeCallbackCall(ctx, output, global, function_object, args, caller_function, caller_frame),
        .async_generator_resolve => try async_generator.qjsAsyncGeneratorResolveFunctionCall(ctx, output, global, function_object, args),
        .async_from_sync_iterator_close_wrap => try promise_ops.qjsAsyncFromSyncIteratorCloseWrapCall(ctx, output, global, function_object, args),
        .async_from_sync_iterator_unwrap => try promise_ops.qjsAsyncFromSyncIteratorUnwrapCall(ctx, global, function_object, args),
        .async_disposable_stack_continuation => try promise_ops.qjsAsyncDisposableStackContinuationCall(ctx, output, global, function_object, args, caller_function, caller_frame),
        .array_from_async_continuation => try array_ops.qjsArrayFromAsyncContinuationCall(ctx, output, global, function_object, args, caller_function, caller_frame),
        .throw_type_error_intrinsic => @as(?core.JSValue, try qjsThrowTypeErrorIntrinsic(ctx, global, function_object)),
    };
}

fn callValueOrBytecodeClassModeDispatch(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    allow_class_constructor_call: bool,
) HostError!core.JSValue {
    if (func.isFunctionBytecode()) {
        const fb = functionBytecodeFromValue(func) orelse return error.TypeError;
        if (allow_class_constructor_call and !fb.flags.is_class_constructor) {
            if (fb.flags.is_arrow_function or !fb.flags.has_prototype or fb.flags.func_kind == .generator or fb.flags.func_kind == .async_generator) return error.TypeError;
            const result = try callFunctionBytecodeConstruct(ctx, func, func, this_value, args, &.{}, output, global, class_init_ops.classConstructorNewTarget(func, caller_frame), core.JSValue.undefinedValue());
            if (result.isObject()) return result;
            result.free(ctx.runtime);
            return this_value.dup();
        }
        if (fb.flags.is_class_constructor) {
            if (!allow_class_constructor_call) return error.TypeError;
            const initial_this = if (fb.flags.is_derived_class_constructor) core.JSValue.uninitialized() else this_value;
            const constructor_this = if (fb.flags.is_derived_class_constructor) this_value else core.JSValue.undefinedValue();
            if (!fb.flags.is_derived_class_constructor) {
                try class_init_ops.initializeClassInstanceElements(ctx, output, global, func, this_value, fb, caller_function, caller_frame);
            }
            return callFunctionBytecodeModeState(ctx, func, func, initial_this, args, &.{}, output, global, true, null, null, null, class_init_ops.classConstructorNewTarget(func, caller_frame), constructor_this);
        }
        return callFunctionBytecode(ctx, func, func, this_value, args, &.{}, output, global);
    }
    if (object_ops.functionObjectFromValue(func)) |function_object| {
        const function_value = function_object.functionBytecodeSlot().* orelse return error.TypeError;
        const fb = functionBytecodeFromValue(function_value) orelse return error.TypeError;
        if (allow_class_constructor_call and !fb.flags.is_class_constructor) {
            if (fb.flags.is_arrow_function or !fb.flags.has_prototype or fb.flags.func_kind == .generator or fb.flags.func_kind == .async_generator) return error.TypeError;
            const function_global = object_ops.objectRealmGlobal(function_object) orelse global;
            const result = try callFunctionBytecodeConstruct(ctx, function_value, func, this_value, args, function_object.functionCapturesSlot().*, output, function_global, class_init_ops.classConstructorNewTarget(func, caller_frame), core.JSValue.undefinedValue());
            if (result.isObject()) return result;
            result.free(ctx.runtime);
            return this_value.dup();
        }
        if (fb.flags.is_class_constructor) {
            if (!allow_class_constructor_call) return throwFunctionRealmTypeErrorMessage(ctx, global, function_object, "class constructors must be invoked with 'new'");
            const initial_this = if (fb.flags.is_derived_class_constructor) core.JSValue.uninitialized() else this_value;
            const constructor_this = if (fb.flags.is_derived_class_constructor) this_value else core.JSValue.undefinedValue();
            const function_global = object_ops.objectRealmGlobal(function_object) orelse global;
            if (!fb.flags.is_derived_class_constructor) {
                try class_init_ops.initializeClassInstanceElements(ctx, output, function_global, func, this_value, fb, caller_function, caller_frame);
            }
            return callFunctionBytecodeModeState(ctx, function_value, func, initial_this, args, function_object.functionCapturesSlot().*, output, function_global, true, null, null, null, class_init_ops.classConstructorNewTarget(func, caller_frame), constructor_this);
        }
        const effective_this = function_object.functionLexicalThis() orelse this_value;
        const effective_new_target = if (fb.flags.is_arrow_function) blk: {
            if (function_object.functionArrowNewTarget()) |new_target| break :blk new_target;
            break :blk core.JSValue.undefinedValue();
        } else core.JSValue.undefinedValue();
        const function_global = object_ops.objectRealmGlobal(function_object) orelse global;
        return callFunctionBytecodeModeState(ctx, function_value, func, effective_this, args, function_object.functionCapturesSlot().*, output, function_global, true, null, null, null, effective_new_target, core.JSValue.undefinedValue());
    }
    if (object_ops.objectFromValue(func)) |object| {
        if (object.proxyTarget() != null and object_ops.proxyTargetIsCallable(func)) {
            return object_ops.callProxyApply(ctx, output, global, func, object, this_value, args, caller_function, caller_frame);
        }
    }
    if (object_ops.callableObjectFromValue(func)) |function_object| {
        switch (vmNativeCallableDispatch(function_object)) {
            .bound_function => return callBoundFunction(ctx, output, global, function_object, args, caller_function, caller_frame),
            .resolved_record => |record| {
                const function_global = object_ops.objectRealmGlobal(function_object) orelse global;
                const native_result = builtin_dispatch.callInternalRecordDirect(
                    ctx,
                    output,
                    function_global,
                    &.{},
                    function_object,
                    this_value,
                    record,
                    args,
                    caller_function,
                    caller_frame,
                ) catch |err| {
                    try throwRuntimeErrorForGlobal(ctx, function_global, err);
                    return err;
                };
                return native_result;
            },
            .native_ref => |native_ref| {
                const function_global = object_ops.objectRealmGlobal(function_object) orelse global;
                const native_result = callNativeBuiltinRecordForVm(ctx, output, function_global, func, this_value, function_object, native_ref, args, caller_function, caller_frame) catch |err| {
                    try throwRuntimeErrorForGlobal(ctx, function_global, err);
                    return err;
                };
                if (native_result) |value| return value;
            },
            .host_function => {
                if (try call_mod.callHostFunctionObjectForVm(ctx, output, global, function_object, this_value, args)) |value| return value;
            },
            .internal => |tag| {
                if (try callInternalCallableByTag(ctx, output, global, function_object, tag, args, caller_function, caller_frame)) |value| return value;
            },
            .name_dispatch => {},
        }
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
        if (allow_class_constructor_call and isBuiltinConstructorName(name)) {
            if (try class_init_ops.constructBuiltinSuperConstructor(ctx, output, global, func, name, args, caller_function, caller_frame, null)) |constructed| {
                return constructed;
            }
            return this_value.dup();
        }
        if (allow_class_constructor_call and !(try isConstructorLike(ctx, func))) return error.TypeError;
        if (std.mem.eql(u8, name, "raw")) {
            return string_ops.qjsStringRaw(ctx, output, global, args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "[Symbol.hasInstance]")) {
            return qjsFunctionHasInstanceCall(ctx, output, global, this_value, args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "sumPrecise")) {
            return math_ops.qjsMathSumPrecise(ctx, output, global, args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "register")) {
            return builtin_glue.qjsFinalizationRegistryRegister(ctx, this_value, args);
        }
        if (std.mem.eql(u8, name, "unregister")) {
            return builtin_glue.qjsFinalizationRegistryUnregister(ctx, this_value, args);
        }
        if (try disposable_ops.qjsDisposableStackMethodCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| {
            return value;
        }
        if (try promise_ops.qjsAsyncDisposableStackMethodCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| {
            return value;
        }
        // The realm-aware Promise static dispatch must stay ahead of the
        // generic native-record dispatch: the record handler reproduces the
        // host-path receiver gates, while this handler also supports custom
        // capability receivers (`Promise.resolve.call(P, ...)`).
        if (promise_ops.qjsPromiseStaticMode(name)) |mode| {
            if (try promise_ops.qjsPromiseStaticBuiltinCallee(ctx.runtime, global, function_object, name)) {
                return promise_ops.qjsPromiseStaticCall(ctx, output, global, this_value, args, mode, caller_function, caller_frame);
            }
        }
        if (try call_mod.callNativeFunctionRecord(ctx, output, global, &.{}, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
        if (try collectionPrototypeMethodByName(ctx, output, global, this_value, function_object, name, args, caller_function, caller_frame)) |value| {
            return value;
        }
        // Hot-path dispatch: a small first-byte switch routes the common
        // global builtins directly to their handlers, bypassing the long
        // `std.mem.eql` chain below. The previous chain walked ~95 checks
        // before reaching `qjsUriCallId` for `decodeURI` / `encodeURI`,
        // which dominated tight-loop URI benchmarks.
        if (name.len != 0) {
            switch (name[0]) {
                'A' => if (std.mem.eql(u8, name, "Array")) {
                    return constructArrayNativeRecordVm(ctx, output, global, function_object, array_ops.arrayPrototypeFromGlobal(ctx.runtime, global), args, caller_function, caller_frame);
                },
                'B' => if (std.mem.eql(u8, name, "BigInt")) {
                    return builtin_glue.qjsBigIntFunctionCall(ctx, output, global, args);
                },
                'N' => if (std.mem.eql(u8, name, "Number")) {
                    return builtin_glue.qjsNumberFunctionCall(ctx, output, global, args);
                },
                'O' => if (std.mem.eql(u8, name, "Object")) {
                    return construct_mod.constructValue(ctx, func, args, &.{});
                },
                'S' => if (std.mem.eql(u8, name, "String")) {
                    return string_ops.qjsStringFunctionCall(ctx, output, global, args, caller_function, caller_frame);
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
                    return string_ops.qjsStringFromCharCode(ctx, output, global, args);
                },
                'r' => if (std.mem.eql(u8, name, "raw")) {
                    return string_ops.qjsStringRaw(ctx, output, global, args, caller_function, caller_frame);
                },
                else => {},
            }
        }
        if (std.mem.eql(u8, name, "get [Symbol.species]")) return this_value.dup();
        if (std.mem.eql(u8, name, "for")) return builtin_glue.qjsSymbolFor(ctx, output, global, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "keyFor")) return builtin_glue.qjsSymbolKeyFor(ctx.runtime, args);
        if (std.mem.eql(u8, name, "Function")) return constructFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "AsyncFunction")) return promise_ops.constructAsyncFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "GeneratorFunction")) return constructGeneratorFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "AsyncGeneratorFunction")) return promise_ops.constructAsyncGeneratorFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "Object")) return construct_mod.constructValue(ctx, func, args, &.{});
        if (std.mem.eql(u8, name, "Array")) return constructArrayNativeRecordVm(ctx, output, global, function_object, array_ops.arrayPrototypeFromGlobal(ctx.runtime, global), args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "String")) return string_ops.qjsStringFunctionCall(ctx, output, global, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "Number")) return builtin_glue.qjsNumberFunctionCall(ctx, output, global, args);
        if (std.mem.eql(u8, name, "BigInt")) return builtin_glue.qjsBigIntFunctionCall(ctx, output, global, args);
        if (std.mem.eql(u8, name, "parseInt")) return builtin_glue.qjsGlobalParseInt(ctx, output, global, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "parseFloat")) return builtin_glue.qjsGlobalParseFloat(ctx, output, global, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "isNaN")) return builtin_glue.qjsGlobalIsNaNOrFinite(ctx, output, global, this_value, args, true);
        if (std.mem.eql(u8, name, "isFinite")) return builtin_glue.qjsGlobalIsNaNOrFinite(ctx, output, global, this_value, args, false);
        if (core.host_function.builtin_method_id_lookup.bigint.staticUnsignedMode(name)) |unsigned| {
            return builtin_glue.qjsBigIntAsN(ctx, output, global, args, unsigned, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "RegExp")) {
            var native_scope = builtin_dispatch.NativeBacktraceScope.init(ctx, function_object);
            native_scope.push();
            defer native_scope.deinit();
            return regexp_fastpath.qjsRegExpFunctionCall(ctx, output, global, function_object, args, caller_function, caller_frame) catch |err| {
                try builtin_dispatch.materializeRuntimeError(ctx, global, err);
                return err;
            };
        }
        if (std.mem.eql(u8, name, "DisposableStack")) return error.TypeError;
        if (std.mem.eql(u8, name, "AsyncDisposableStack")) return error.TypeError;
        if (std.mem.eql(u8, name, "AggregateError")) {
            const prototype = try object_ops.constructorPrototypeObject(ctx.runtime, func);
            const constructor_global = object_ops.objectRealmGlobal(function_object) orelse global;
            return try object_ops.qjsAggregateErrorConstructWithPrototype(ctx, output, constructor_global, prototype, args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "SuppressedError")) {
            const prototype = try object_ops.constructorPrototypeObject(ctx.runtime, func);
            return try object_ops.qjsSuppressedErrorConstructWithPrototype(ctx, output, global, prototype, args, caller_function, caller_frame);
        }
        if (exception_ops.isErrorConstructorName(name)) {
            const prototype = try object_ops.constructorPrototypeObject(ctx.runtime, func);
            return try object_ops.qjsErrorConstructWithPrototype(ctx, output, global, name, prototype, args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "isError")) return builtin_glue.qjsErrorIsError(args);
        if (std.mem.eql(u8, name, "isView")) return array_ops.qjsArrayBufferIsView(args);
        if (std.mem.eql(u8, name, "set")) {
            if (try array_ops.qjsTypedArraySetCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
        }
        if (try array_ops.qjsUint8ArrayCodecCall(ctx, output, global, this_value, name, args, caller_function, caller_frame)) |value| return value;
        if (std.mem.eql(u8, name, "next")) {
            if (try promise_ops.qjsAsyncFromSyncIteratorMethodCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
            if (try qjsIteratorHelperNext(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
            if (try qjsIteratorWrapNext(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
            if (promise_ops.isAsyncGeneratorPrototypeMethod(ctx.runtime, function_object) and !promise_ops.isAsyncGeneratorReceiver(this_value)) return promise_ops.asyncGeneratorRejectedTypeError(ctx, global);
            if (try qjsGeneratorNext(ctx, output, global, this_value, args)) |value| return value;
            if (promise_ops.isAsyncGeneratorPrototypeMethod(ctx.runtime, function_object)) return promise_ops.asyncGeneratorRejectedTypeError(ctx, global);
            if (try string_ops.qjsRegExpStringIteratorNext(ctx, output, global, this_value, caller_function, caller_frame)) |value| return value;
            {
                // Array Iterator `next` is still marker/name-dispatched rather
                // than table-dispatched. Give this legacy terminal the same
                // native-frame/error-materialization boundary as a record call.
                var native_scope = builtin_dispatch.NativeBacktraceScope.init(ctx, function_object);
                native_scope.push();
                defer native_scope.deinit();
                const next_result = array_ops.qjsArrayIteratorNext(ctx, output, global, this_value, function_object) catch |err| {
                    try builtin_dispatch.materializeRuntimeError(ctx, global, err);
                    return err;
                };
                if (next_result) |value| return value;
            }
        }
        if (std.mem.eql(u8, name, "throw")) {
            if (try promise_ops.qjsAsyncFromSyncIteratorMethodCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
            if (promise_ops.isAsyncGeneratorPrototypeMethod(ctx.runtime, function_object) and !promise_ops.isAsyncGeneratorReceiver(this_value)) return promise_ops.asyncGeneratorRejectedTypeError(ctx, global);
            if (try qjsGeneratorThrow(ctx, output, global, this_value, args)) |value| return value;
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
            if (try promise_ops.qjsAsyncIteratorAsyncDispose(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "return")) {
            if (try promise_ops.qjsAsyncFromSyncIteratorMethodCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
            if (try qjsIteratorHelperReturn(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
            if (try qjsIteratorWrapReturn(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
            if (promise_ops.isAsyncGeneratorPrototypeMethod(ctx.runtime, function_object) and !promise_ops.isAsyncGeneratorReceiver(this_value)) return promise_ops.asyncGeneratorRejectedTypeError(ctx, global);
            if (try qjsGeneratorReturn(ctx, output, global, this_value, args)) |value| return value;
            if (promise_ops.isAsyncGeneratorPrototypeMethod(ctx.runtime, function_object)) return promise_ops.asyncGeneratorRejectedTypeError(ctx, global);
        }
        if (std.mem.eql(u8, name, "fromCharCode")) {
            return string_ops.qjsStringFromCharCode(ctx, output, global, args);
        }
        if (std.mem.eql(u8, name, "fromCodePoint")) {
            return string_ops.qjsStringFromCodePoint(ctx, output, global, args);
        }
        if (std.mem.eql(u8, name, "raw")) {
            return string_ops.qjsStringRaw(ctx, output, global, args, caller_function, caller_frame);
        }
        if (core.host_function.builtin_method_id_lookup.date.staticMethodId(name)) |method_id| {
            if (object_ops.objectFromValue(this_value)) |receiver_object| {
                if (try constructorNameEqlLocal(ctx.runtime, receiver_object, "Date")) {
                    if (try date_vm.qjsDateStaticCall(ctx, output, global, this_value, method_id, args, caller_function, caller_frame)) |value| return value;
                    // parse/now fall-through (utc was handled above with VM
                    // coercion): route the static body through the record table.
                    return date_vm.callDateStaticBody(ctx, method_id, args) catch |err| switch (err) {
                        error.TypeError => error.TypeError,
                        else => err,
                    };
                }
            }
        }
        if (try array_ops.qjsArrayIteratorMethod(ctx, global, this_value, function_object)) |value| {
            return value;
        }
        if (std.mem.eql(u8, name, "apply")) {
            return qjsFunctionApplyCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "call")) {
            return qjsFunctionCallCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "get __proto__")) return object_ops.qjsObjectProtoGetterCall(ctx, output, global, this_value, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "set __proto__")) {
            const proto_arg = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return object_ops.qjsObjectProtoSetterCall(ctx, output, global, this_value, proto_arg, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "set")) {
            if (try array_ops.qjsTypedArraySetCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "deref")) {
            return builtin_glue.qjsWeakRefDeref(ctx.runtime, this_value);
        }
        if (std.mem.eql(u8, name, "join")) {
            if (try array_ops.qjsArrayJoinCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "toString")) {
            if (try string_ops.qjsArrayToStringCall(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "toLocaleString")) {
            if (try string_ops.qjsArrayToLocaleStringCall(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
        }
        if (try array_ops.qjsArrayFromCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
        if (try array_ops.qjsArrayFromAsyncCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
        if (try array_ops.qjsArrayOfCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
        if (try array_ops.qjsArrayIterationCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
        if (try array_ops.qjsArrayAtCall(ctx, output, global, this_value, func, args)) |value| return value;
        if (try array_ops.qjsArrayReduceCall(ctx, output, global, this_value, func, args, false)) |value| return value;
        if (try array_ops.qjsArrayReduceCall(ctx, output, global, this_value, func, args, true)) |value| return value;
        if (try string_ops.qjsArraySearchCall(ctx, output, global, this_value, func, args)) |value| return value;
        if (try array_ops.qjsArrayCopyWithinCall(ctx, output, global, this_value, func, args)) |value| return value;
        if (try array_ops.qjsArrayFillCall(ctx, output, global, this_value, func, args)) |value| return value;
        if (try array_ops.qjsArrayPushCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
        if (try array_ops.qjsArrayPopCall(ctx, output, global, this_value, func, caller_function, caller_frame)) |value| return value;
        if (try array_ops.qjsArrayShiftCall(ctx, output, global, this_value, func)) |value| return value;
        if (try array_ops.qjsArrayUnshiftCall(ctx, output, global, this_value, func, args)) |value| return value;
        if (try array_ops.qjsArrayReverseCall(ctx, output, global, this_value, func, caller_function, caller_frame)) |value| return value;
        if (try array_ops.qjsArraySpliceCall(ctx, output, global, this_value, func, args)) |value| return value;
        if (try array_ops.qjsTypedArraySliceSubarrayCall(ctx, output, global, this_value, func, args)) |value| return value;
        if (try array_ops.qjsArraySliceCall(ctx, output, global, this_value, func, args)) |value| return value;
        if (try array_ops.qjsArrayFlatCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
        if (try array_ops.qjsArraySortCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
        if (try array_ops.qjsArrayByCopyCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
        if (try string_ops.qjsArrayConcatCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
        if (std.mem.eql(u8, name, "slice")) {
            if (try array_ops.qjsGeneratorSlice(ctx, output, global, this_value, args)) |value| return value;
        }
        if (std.mem.eql(u8, name, "then") or std.mem.eql(u8, name, "catch") or std.mem.eql(u8, name, "finally")) {
            if (try promise_ops.qjsPromiseThen(ctx, output, global, this_value, name, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "eval")) {
            const eval_global = if (function_object.functionRealmGlobal()) |realm_value|
                property_ops.expectObject(realm_value) catch global
            else
                global;
            return indirectEval(ctx, output, eval_global, args);
        }
        if (std.mem.eql(u8, name, "throws")) return qjsAssertThrows(ctx, output, global, args, caller_function, caller_frame);
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
            // `qjsMapGetOrInsertComputed` returned null to continue the chain for
            // any other receiver) and route the body through the record table.
            if (object_ops.objectFromValue(this_value)) |receiver| {
                if (receiver.class_id == core.class.ids.map or receiver.class_id == core.class.ids.weakmap) {
                    const native_ref = core.function.NativeBuiltinRef{ .domain = .collection, .id = @intFromEnum(method_ids.collection.PrototypeMethod.get_or_insert_computed) };
                    if (try builtin_dispatch.callInternalRecord(ctx, output, global, &.{}, function_object, this_value, native_ref, args, caller_function, caller_frame)) |value| return value;
                }
            }
        }
        if (object_ops.getNumberPrototypeMethodId(ctx.runtime, function_object)) |method_id| {
            return object_ops.qjsNumberPrototypeMethod(ctx, output, global, this_value, @intCast(method_id), args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "concat") and !array_ops.isArrayMethodReceiver(this_value)) {
            return string_ops.qjsStringConcat(ctx, output, global, this_value, args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "replace")) {
            return string_ops.qjsStringReplace(ctx, output, global, this_value, args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "exec")) {
            if (try regexp_fastpath.qjsRegExpExecMethod(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "test")) {
            if (try regexp_fastpath.qjsRegExpTestMethod(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "compile")) {
            const compile_global = object_ops.objectRealmGlobal(function_object) orelse global;
            if (try regexp_fastpath.qjsRegExpCompile(ctx, output, compile_global, this_value, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "[Symbol.search]")) {
            if (try string_ops.qjsRegExpSymbolSearch(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "[Symbol.match]")) {
            if (try string_ops.qjsRegExpSymbolMatch(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "[Symbol.matchAll]")) {
            if (try string_ops.qjsRegExpSymbolMatchAll(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "[Symbol.replace]")) {
            if (try string_ops.qjsRegExpSymbolReplace(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "[Symbol.split]")) {
            if (try string_ops.qjsRegExpSymbolSplit(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
        }
        if (core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*)) |native_ref| {
            if (native_ref.domain == .regexp and
                core.host_function.builtin_method_id_lookup.regexp.accessorNameFromId(native_ref.id) != null)
            {
                // The `.regexp` accessor record runs the same `qjsRegExpAccessor`
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
            return builtin_glue.qjsDataViewGet(ctx, output, global, this_value, method_id, args) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                error.RangeError => error.RangeError,
                else => err,
            };
        }
        if (core.host_function.builtin_method_id_lookup.buffer.dataViewSetMethodId(name)) |method_id| {
            return builtin_glue.qjsDataViewSet(ctx, output, global, this_value, method_id, args) catch |err| switch (err) {
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
            return string_ops.qjsStringIterator(ctx, output, global, this_value, caller_function, caller_frame);
        }
        if (string_ops.getStringPrototypeMethodId(ctx.runtime, function_object)) |method_id| {
            return string_ops.qjsStringPrototypeMethod(ctx, output, global, this_value, method_id, args, caller_function, caller_frame) catch |err| switch (err) {
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
            return string_ops.qjsStringPrototypeMethod(ctx, output, global, this_value, method_id, args, caller_function, caller_frame) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                else => err,
            };
        }
        if (uriGlobalRecordId(name)) |id| {
            // encodeURI/decodeURI variants (`methodId` 1..4) plus the legacy
            // escape/unescape pair (`core.uri.escape_id`/`unescape_id`). Route
            // the raw input through the `.uri` record; the record handler does
            // the Annex B ToString coercion before its body.
            const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const native_ref = core.function.NativeBuiltinRef{ .domain = .uri, .id = id };
            return (try builtin_dispatch.callInternalRecord(ctx, output, global, &.{}, null, this_value, native_ref, &.{input}, caller_function, caller_frame)) orelse error.TypeError;
        }
    }
    if (!isCallableValue(func)) return exception_ops.throwTypeErrorMessage(ctx, global, "not a function");
    return call_mod.callValueWithThisGlobalsAndGlobal(ctx, output, global, &.{}, this_value, func, args);
}

test "callValueOrBytecodeClassMode roots inline args before bytecode frame allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try zjs_vm.contextGlobal(ctx);

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);
    {
        const code = try rt.memory.alloc(u8, 1);
        code[0] = op.return_undef;
        fb.byte_code = code.ptr;
        fb.byte_code_len = 1;
    }
    fb.var_count = 1;

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
            _ = self.rt.runObjectCycleRemoval();
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

    const result = try callValueOrBytecodeClassMode(
        ctx,
        null,
        global,
        core.JSValue.undefinedValue(),
        func_value,
        &args,
        null,
        null,
        false,
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

pub fn qjsFunctionHasInstanceCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
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
    caller_function: ?*const bytecode.Bytecode,
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
            if (!co.flags.is_proxy) {
                if (co.getOwnDataPropertyValue(core.atom.ids.prototype)) |v| break :blk v.dup();
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
        const next = if (candidate.flags.is_proxy or object_ops.isThrowTypeErrorIntrinsicObject(candidate))
            try object_ops.qjsObjectGetPrototypeOfStep(ctx, output, global, candidate, caller_function, caller_frame)
        else
            candidate.getPrototype();
        const parent = next orelse return false;
        if (parent == prototype) return true;
        current = parent;
    }
    return false;
}

pub fn qjsErrorStackGetter(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
) !core.JSValue {
    const object = object_ops.objectFromValue(this_value) orelse return error.TypeError;
    if (object.class_id != core.class.ids.error_) return core.JSValue.undefinedValue();
    if (object.errorStack()) |stack| return stack.dup();
    if (object.errorStackSites()) |sites| {
        const stack = try error_stack_ops.formatCapturedErrorStackValue(ctx, output, global, this_value, sites, object.errorStackSiteCount());
        errdefer stack.free(ctx.runtime);
        try object.setErrorStack(ctx.runtime, stack);
        return stack;
    }
    return error_stack_ops.buildErrorStackValue(ctx, output, global, this_value, null);
}

pub fn qjsErrorStackSetter(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const receiver = object_ops.objectFromValue(this_value) orelse return error.TypeError;
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (!value.isString()) return error.TypeError;

    const home_global = object_ops.objectRealmGlobal(function_object) orelse global;
    if (object_ops.constructorPrototypeFromGlobal(ctx.runtime, home_global, "Error")) |error_proto| {
        if (object_ops.sameObjectIdentity(this_value, error_proto.value())) return error.TypeError;
    }

    const stack_key = try ctx.runtime.internAtom("stack");
    defer ctx.runtime.atoms.free(stack_key);
    const desc = try object_ops.proxyAwareOwnPropertyDescriptor(ctx, output, global, receiver, stack_key, caller_function, caller_frame);
    defer if (desc) |item| item.destroy(ctx.runtime);

    if (desc == null) {
        const create_desc = core.Descriptor.data(value, true, true, true);
        const ok = if (receiver.proxyTarget() != null)
            try object_ops.proxyDefineOwnProperty(ctx, output, global, receiver, stack_key, create_desc, caller_function, caller_frame)
        else blk: {
            receiver.defineOwnProperty(ctx.runtime, stack_key, create_desc) catch |err| switch (err) {
                error.ReadOnly, error.NotExtensible, error.IncompatibleDescriptor => break :blk false,
                error.InvalidLength => return error.RangeError,
                else => return err,
            };
            break :blk true;
        };
        if (!ok) return error.TypeError;
        return core.JSValue.undefinedValue();
    }

    const own_desc = desc.?;
    if (own_desc.kind == .accessor and object_ops.sameObjectIdentity(own_desc.setter, function_object.value()) and isErrorStackSetterValue(own_desc.setter)) {
        if (try object_ops.proxySetTrapForErrorStackSetter(ctx, output, global, this_value, receiver, stack_key, value, caller_function, caller_frame)) {
            return core.JSValue.undefinedValue();
        }
        try object_ops.defineErrorStackDataProperty(ctx, output, global, receiver, stack_key, core.Descriptor.data(value, true, true, true), caller_function, caller_frame);
        return core.JSValue.undefinedValue();
    }

    if (receiver.proxyTarget() != null) {
        const ok = try object_ops.proxySetValueProperty(ctx, output, global, this_value, receiver, stack_key, value, caller_function, caller_frame);
        if (!ok) return error.TypeError;
        return core.JSValue.undefinedValue();
    }

    switch (own_desc.kind) {
        .accessor => {
            if (own_desc.setter.isUndefined()) return error.TypeError;
            const result = try callValueOrBytecode(ctx, output, global, this_value, own_desc.setter, &.{value}, caller_function, caller_frame);
            result.free(ctx.runtime);
            return core.JSValue.undefinedValue();
        },
        .data, .generic => {
            if (own_desc.kind == .data and own_desc.writable == false) return error.TypeError;
            try object_ops.defineErrorStackDataProperty(ctx, output, global, receiver, stack_key, core.Descriptor{ .kind = .data, .value = value, .value_present = true }, caller_function, caller_frame);
            return core.JSValue.undefinedValue();
        },
    }
}

pub fn isErrorStackSetterValue(value: core.JSValue) bool {
    const object = object_ops.objectFromValue(value) orelse return false;
    const native_ref = core.function.decodeNativeBuiltinId(object.nativeFunctionId()) orelse return false;
    return native_ref.domain == .error_object and native_ref.id == @intFromEnum(method_ids.error_object.PrototypeMethod.stack_setter);
}

pub fn throwFunctionRealmTypeError(ctx: *core.JSContext, global: *core.Object, function_object: *core.Object) !core.JSValue {
    return throwFunctionRealmTypeErrorMessage(ctx, global, function_object, "not a function");
}

/// Function.prototype.call body shared by the native-record owner and the
/// transitional name-dispatch fallback. Keeping the VM caller pair preserves
/// nested callsite/property-access context while the native record contributes
/// the surrounding `call (native)` frame.
pub fn qjsFunctionCallCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    if (!isCallableValue(this_value)) return throwFunctionRealmTypeError(ctx, global, function_object);
    const this_arg = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const call_args = if (args.len >= 1) args[1..] else &.{};
    return callValueOrBytecode(ctx, output, global, this_arg, this_value, call_args, caller_function, caller_frame);
}

/// Function.prototype.apply body. `argsFromArrayLike` is the shared
/// CreateListFromArrayLike implementation used by Reflect.apply/construct;
/// its returned owned values stay rooted for the complete target invocation.
pub fn qjsFunctionApplyCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    if (!isCallableValue(this_value)) return throwFunctionRealmTypeError(ctx, global, function_object);
    const this_arg = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const arg_array = if (args.len >= 2 and !args[1].isNull() and !args[1].isUndefined()) args[1] else {
        return callValueOrBytecode(ctx, output, global, this_arg, this_value, &.{}, caller_function, caller_frame);
    };
    if (!arg_array.isObject()) return throwFunctionRealmTypeError(ctx, global, function_object);
    if (object_ops.callableObjectFromValue(this_value)) |target_object| {
        const target_name = try call_mod.nativeFunctionNameForVm(ctx.runtime, target_object);
        defer ctx.runtime.memory.allocator.free(target_name);
        if (std.mem.eql(u8, target_name, "fromCodePoint")) return string_ops.qjsStringFromCodePointArray(ctx, output, global, arg_array);
    }
    var apply_args = try array_ops.argsFromArrayLike(ctx, output, global, arg_array, caller_function, caller_frame);
    defer freeArgs(ctx.runtime, apply_args);
    var apply_args_root = array_ops.ValueSliceRoot{};
    apply_args_root.init(ctx.runtime, &apply_args);
    defer apply_args_root.deinit();
    return callValueOrBytecode(ctx, output, global, this_arg, this_value, apply_args, caller_function, caller_frame);
}

pub fn throwFunctionRealmTypeErrorMessage(ctx: *core.JSContext, global: *core.Object, function_object: *core.Object, message: []const u8) !core.JSValue {
    const error_global = object_ops.objectRealmGlobal(function_object) orelse global;
    const error_value = try exception_ops.createNamedError(ctx, error_global, "TypeError", message);
    _ = ctx.throwValue(error_value);
    return error.JSException;
}

pub fn constructValueOrBytecode(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return constructValueOrBytecodeWithNewTarget(ctx, output, global, func, args, caller_function, caller_frame, func);
}

// Native-builtin construct-record ids for the table-dispatched constructors the
// VM construct path routes through `builtin_dispatch.callConstructRecord`. The
// VM dispatcher decodes the constructor's native id and matches against these
// instead of comparing the resolved function name, so a user function named
// "Date"/"String"/"RegExp" no longer aliases the builtin (matching the
// native-id keying `exec/construct.zig` adopted in Phase 6b-3d). The construct
// branches run the same builtin `constructWithPrototype` bodies the VM fast
// paths previously called directly; the VM-context argument coercion stays on
// the exec side (here for Date/String, inside `qjsRegExpConstructCall` for
// RegExp) and the coerced args + resolved prototype are threaded to the record.
const date_construct_id: u32 = @intFromEnum(core.host_function.builtin_method_ids.date.ConstructorMethod.construct);
const string_construct_id: u32 = @intFromEnum(core.host_function.builtin_method_ids.string.ConstructorMethod.call);
const regexp_construct_id: u32 = @intFromEnum(core.host_function.builtin_method_ids.regexp.ConstructorMethod.construct);

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
fn constructArrayNativeRecordVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: ?*core.Object,
    prototype: ?*core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
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
    caller_function: ?*const bytecode.Bytecode,
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    const prototype = try object_ops.constructorPrototypeObject(ctx.runtime, new_target);
    const string_value = if (args.len == 0)
        try value_ops.createStringValue(ctx.runtime, "")
    else
        try string_ops.toStringForAnnexB(ctx, output, global, args[0], caller_function, caller_frame);
    defer string_value.free(ctx.runtime);
    return builtin_dispatch.callConstructRecordInNativeScope(ctx, output, global, &.{}, function_object, native_ref, prototype, &.{string_value}, caller_function, caller_frame);
}

fn constructDateBuiltinNativeVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    native_ref: core.function.NativeBuiltinRef,
    new_target: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    var native_scope = builtin_dispatch.NativeBacktraceScope.init(ctx, function_object);
    native_scope.push();
    defer native_scope.deinit();

    return constructDateBuiltinNativeInScope(ctx, output, global, function_object, native_ref, new_target, args, caller_function, caller_frame) catch |err| {
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    const prototype = try object_ops.reflectConstructPrototypeVm(ctx, output, global, "Date", new_target, caller_function, caller_frame);
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
                coerced_storage[0] = try date_vm.callDateBody(ctx, args[0], 1, &.{});
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
    return builtin_dispatch.callConstructRecordInNativeScope(ctx, output, global, &.{}, function_object, native_ref, prototype, date_args, caller_function, caller_frame);
}

pub fn constructValueOrBytecodeWithNewTarget(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    new_target: core.JSValue,
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
            if (array_ops.qjsTypedArrayConstructVm(ctx, output, global, func, function_object, args, caller_function, caller_frame) catch |err| switch (err) {
                error.RangeError => return exception_ops.throwRangeErrorMessage(ctx, global, "invalid array index"),
                else => return err,
            }) |value| return value;
            return construct_mod.constructValue(ctx, func, args, &.{});
        }
        if (try array_ops.constructArrayBufferNativeRecord(ctx, output, global, func, function_object, args, new_target)) |constructed| {
            return constructed;
        }
        // Decode the constructor's native-builtin id once: the Date/String/RegExp
        // construct branches below gate on it (not the resolved function name)
        // and route their construct through the record table. Direct
        // construction (`new Date()`) reaches the per-id branches; subclass
        // `super(...)` (new_target != func) is intercepted above by
        // `constructBuiltinSuperConstructor`, exactly as for the other builtin
        // constructors.
        const construct_native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*);
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
        if (isBuiltinConstructorName(name) and !new_target.sameValue(func)) {
            if (try class_init_ops.constructBuiltinSuperConstructor(ctx, output, global, func, name, args, caller_function, caller_frame, new_target)) |constructed| {
                return constructed;
            }
        }
        if (std.mem.eql(u8, name, "Function")) return constructFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "AsyncFunction")) return promise_ops.constructAsyncFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "GeneratorFunction")) return constructGeneratorFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "AsyncGeneratorFunction")) return promise_ops.constructAsyncGeneratorFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "Symbol")) return exception_ops.throwTypeErrorMessage(ctx, global, "Symbol is not a constructor");
        if (array_ops.qjsTypedArrayConstructorName(name)) {
            if (try array_ops.qjsTypedArrayConstructFromIterable(ctx, output, global, func, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "Number")) {
            const primitive = try builtin_glue.qjsNumberFunctionCall(ctx, output, global, args);
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
            // retired `qjsDateConstructWithPrototype` inline path did (so user
            // `valueOf`/`toString`/`Symbol.toPrimitive` run with the caller
            // frame), collect the coerced primitives, then run the builtin Date
            // constructor body through the record table with the resolved
            // prototype. The single-arg date-copy and string fast paths pass the
            // argument through unchanged.
            return (try constructDateBuiltinNativeVm(ctx, output, global, function_object, native_ref, new_target, args, caller_function, caller_frame)) orelse error.TypeError;
        };
        if (std.mem.eql(u8, name, "Array")) {
            const prototype = try object_ops.constructorPrototypeObject(ctx.runtime, new_target);
            return constructArrayNativeRecordVm(ctx, output, global, function_object, prototype, args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "Promise")) return promise_ops.qjsPromiseConstruct(ctx, output, global, new_target, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "DisposableStack")) {
            const prototype = try object_ops.reflectConstructPrototypeVm(ctx, output, global, "DisposableStack", new_target, caller_function, caller_frame);
            return try object_ops.qjsDisposableStackConstructWithPrototype(ctx, global, prototype);
        }
        if (std.mem.eql(u8, name, "AsyncDisposableStack")) {
            const prototype = try object_ops.reflectConstructPrototypeVm(ctx, output, global, "AsyncDisposableStack", new_target, caller_function, caller_frame);
            return try promise_ops.qjsAsyncDisposableStackConstructWithPrototype(ctx, global, prototype);
        }
        if (construct_native_ref) |native_ref| if (native_ref.domain == .regexp and native_ref.id == regexp_construct_id) {
            // `new RegExp(...)`: `qjsRegExpConstructCall` performs the
            // observable pattern/flags coercion and resolves the instance
            // prototype after it (matching QuickJS `js_regexp_constructor` ->
            // `js_regexp_constructor_internal`); its terminal construct runs the
            // builtin RegExp constructor body through the record table.
            return regexp_fastpath.qjsRegExpConstructCall(ctx, output, global, function_object, new_target, args, caller_function, caller_frame);
        };
        if (core.host_function.builtin_method_id_lookup.collection.constructorId(name)) |kind| return builtin_glue.constructCollectionFromVm(ctx, output, global, func, kind, args);
        if (std.mem.eql(u8, name, "ArrayBuffer") or std.mem.eql(u8, name, "SharedArrayBuffer")) {
            const prototype = try object_ops.constructorPrototypeObject(ctx.runtime, new_target);
            return array_ops.qjsArrayBufferConstructWithPrototype(ctx, output, global, args, prototype, std.mem.eql(u8, name, "SharedArrayBuffer"));
        }
        if (std.mem.eql(u8, name, "DataView")) {
            const coerced = try builtin_glue.qjsDataViewConstructorArgs(ctx, output, global, args);
            const prototype = try object_ops.constructorPrototypeObject(ctx.runtime, new_target);
            return try object_ops.qjsDataViewConstructWithPrototype(ctx.runtime, args[0], coerced, prototype);
        }
        if (std.mem.eql(u8, name, "Proxy")) {
            return construct_mod.constructValue(ctx, func, args, &.{}) catch |err| switch (err) {
                error.TypeError => return exception_ops.throwTypeErrorMessage(ctx, global, "not an object"),
                else => err,
            };
        }
        if (std.mem.eql(u8, name, "DOMException")) {
            const prototype = try object_ops.constructorPrototypeObject(ctx.runtime, new_target);
            return try construct_mod.constructDOMExceptionObject(ctx.runtime, prototype, args);
        }
        if (std.mem.eql(u8, name, "AggregateError")) {
            const prototype = try object_ops.constructorPrototypeObject(ctx.runtime, new_target);
            const constructor_global = object_ops.objectRealmGlobal(function_object) orelse global;
            return try object_ops.qjsAggregateErrorConstructWithPrototype(ctx, output, constructor_global, prototype, args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "SuppressedError")) {
            const prototype = try object_ops.constructorPrototypeObject(ctx.runtime, new_target);
            return try object_ops.qjsSuppressedErrorConstructWithPrototype(ctx, output, global, prototype, args, caller_function, caller_frame);
        }
        if (exception_ops.isErrorConstructorName(name)) {
            const prototype = try object_ops.constructorPrototypeObject(ctx.runtime, new_target);
            return try object_ops.qjsErrorConstructWithPrototype(ctx, output, global, name, prototype, args, caller_function, caller_frame);
        }
        if (function_object.hostFunctionKindSlot().* == core.host_function.ids.external_host) {
            return constructExternalHostFunction(ctx, output, global, function_object, args, caller_function, caller_frame, new_target);
        }
        if (function_object.class_id == core.class.ids.c_function and !isBuiltinConstructorName(name)) return error.TypeError;
    }
    if (func.isFunctionBytecode()) {
        const fb = functionBytecodeFromValue(func) orelse return error.TypeError;
        if (fb.flags.is_arrow_function or !fb.flags.has_prototype or fb.flags.func_kind == .generator or fb.flags.func_kind == .async_generator) return error.TypeError;
        // qjs JS_CallConstructorInternal (quickjs.c:20837): a DERIVED class ctor
        // allocates NO instance and does NO prototype lookup — `this` stays
        // uninitialized (TDZ) until super() builds the object via new.target and
        // binds it. Only base/ordinary ctors get the eager js_create_from_ctor
        // instance (quickjs.c:20842).
        if (fb.flags.is_derived_class_constructor) {
            return try callFunctionBytecodeConstruct(ctx, func, func, core.JSValue.uninitialized(), args, &.{}, output, global, new_target, core.JSValue.undefinedValue());
        }
        const instance = try createConstructorInstance(ctx, output, global, new_target, caller_function, caller_frame);
        errdefer instance.free(ctx.runtime);
        try class_init_ops.initializeClassInstanceElements(ctx, output, global, func, instance, fb, caller_function, caller_frame);
        const result = try callFunctionBytecodeConstruct(ctx, func, func, instance, args, &.{}, output, global, new_target, core.JSValue.undefinedValue());
        if (result.isObject()) {
            instance.free(ctx.runtime);
            return result;
        }
        result.free(ctx.runtime);
        return instance;
    }
    if (object_ops.functionObjectFromValue(func)) |function_object| {
        const function_value = function_object.functionBytecodeSlot().* orelse return error.TypeError;
        const fb = functionBytecodeFromValue(function_value) orelse return error.TypeError;
        if (fb.flags.is_class_constructor) {
            // Special handling for class constructors (published via top-level script/module binding or direct define_class).
            // This is the VM alignment fix for the "not a constructor" bug in top-level class decl in plain .js scripts
            // (the functionObjectFromValue path was not recognizing is_class_constructor and taking the ordinary path,
            // which rejected class ctors or used wrong initial_this for derived/fields init).
            const function_global = object_ops.objectRealmGlobal(function_object) orelse global;
            // Derived class ctor: no eager instance / prototype lookup (qjs quickjs.c:20837); see above.
            if (fb.flags.is_derived_class_constructor) {
                return try callFunctionBytecodeConstruct(ctx, function_value, func, core.JSValue.uninitialized(), args, function_object.functionCapturesSlot().*, output, function_global, new_target, core.JSValue.undefinedValue());
            }
            const instance = try createBytecodeConstructorInstance(ctx, output, global, func, function_object, new_target, caller_function, caller_frame);
            errdefer instance.free(ctx.runtime);
            try class_init_ops.initializeClassInstanceElements(ctx, output, global, func, instance, fb, caller_function, caller_frame);
            const result = try callFunctionBytecodeConstruct(ctx, function_value, func, instance, args, function_object.functionCapturesSlot().*, output, function_global, new_target, core.JSValue.undefinedValue());
            if (result.isObject()) {
                instance.free(ctx.runtime);
                return result;
            }
            result.free(ctx.runtime);
            return instance;
        }
        if (fb.flags.is_arrow_function or !fb.flags.has_prototype or fb.flags.func_kind == .generator or fb.flags.func_kind == .async_generator) return error.TypeError;
        if (try constructSimpleFieldConstructor(ctx, func, function_object, fb, args, new_target)) |constructed| return constructed;
        const instance = try createBytecodeConstructorInstance(ctx, output, global, func, function_object, new_target, caller_function, caller_frame);
        errdefer instance.free(ctx.runtime);
        if (!fb.flags.is_derived_class_constructor) {
            try class_init_ops.initializeClassInstanceElements(ctx, output, global, func, instance, fb, caller_function, caller_frame);
        }
        const function_global = object_ops.objectRealmGlobal(function_object) orelse global;
        const initial_this = if (fb.flags.is_derived_class_constructor) core.JSValue.uninitialized() else instance;
        const constructor_this = if (fb.flags.is_derived_class_constructor) instance else core.JSValue.undefinedValue();
        const result = try callFunctionBytecodeConstruct(ctx, function_value, func, initial_this, args, function_object.functionCapturesSlot().*, output, function_global, new_target, constructor_this);
        if (result.isObject()) {
            instance.free(ctx.runtime);
            return result;
        }
        result.free(ctx.runtime);
        return instance;
    }
    if (object_ops.objectFromValue(func)) |object| {
        if (object.class_id == core.class.ids.object and object.proxyTarget() == null) {
            return exception_ops.throwTypeErrorMessage(ctx, global, "not a constructor");
        }
    }
    return construct_mod.constructValue(ctx, func, args, &.{});
}

fn constructExternalHostFunction(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
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

test "qjsConstructWeakRefWithPrototype roots direct symbol target while creating weak ref" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-qjs-weak-ref-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const symbol_value = try rt.symbolValue(symbol_atom);
    const weak_ref_value = try object_ops.qjsConstructWeakRefWithPrototype(rt, symbol_value, null);
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

test "qjsConstructFinalizationRegistryWithPrototype roots function bytecode cleanup while creating registry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    fb.flags.func_kind = .generator;
    try rt.gc.add(&fb.header);

    {
        const __cp = try rt.memory.alloc(core.JSValue, 1);
        fb.cpool = __cp.ptr;
        fb.cpool_count = @intCast(__cp.len);
    }
    const symbol_atom = try rt.atoms.newValueSymbol("gc-finalization-cleanup-bytecode-symbol");
    fb.cpool[0] = try rt.symbolValue(symbol_atom);
    fb.cpool_count = 1;

    var cleanup_callback = core.JSValue.functionBytecode(&fb.header);
    var cleanup_callback_alive = true;
    defer if (cleanup_callback_alive) cleanup_callback.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const registry_value = try object_ops.qjsConstructFinalizationRegistryWithPrototype(rt, cleanup_callback, null);
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

test "qjsFinalizationRegistryAppendCell roots direct symbol fields while allocating cell" {
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
    try builtin_glue.qjsFinalizationRegistryAppendCell(
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const prototype = try object_ops.reflectConstructPrototypeVm(ctx, output, global, "Object", new_target, caller_function, caller_frame);
    const instance = try core.Object.create(ctx.runtime, core.class.ids.object, prototype);
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (new_target.sameValue(func)) {
        if (function_object.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| {
            const instance = try core.Object.create(ctx.runtime, core.class.ids.object, prototype);
            errdefer core.Object.destroyFromHeader(ctx.runtime, &instance.header);
            return instance.value();
        }
    }
    return createConstructorInstance(ctx, output, global, new_target, caller_function, caller_frame);
}

const max_simple_constructor_fields = 8;

const SimpleFieldConstructorPattern = struct {
    atoms: [max_simple_constructor_fields]core.Atom = undefined,
    arg_indices: [max_simple_constructor_fields]u16 = undefined,
    len: usize = 0,
};

fn constructSimpleFieldConstructor(
    ctx: *core.JSContext,
    func: core.JSValue,
    function_object: *core.Object,
    fb: *const bytecode.FunctionBytecode,
    args: []const core.JSValue,
    new_target: core.JSValue,
) !?core.JSValue {
    if (!new_target.sameValue(func)) return null;
    const pattern = simpleFieldConstructorPattern(fb) orelse return null;
    const prototype = function_object.getOwnDataObjectBorrowed(core.atom.ids.prototype) orelse return null;
    if (prototypeChainBlocksSimpleFieldStore(prototype, pattern)) return null;

    const instance = try core.Object.create(ctx.runtime, core.class.ids.object, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &instance.header);
    for (pattern.atoms[0..pattern.len], pattern.arg_indices[0..pattern.len]) |atom_id, arg_index| {
        const value = if (arg_index < args.len) args[arg_index] else core.JSValue.undefinedValue();
        try instance.defineOwnPropertyAssumingNew(ctx.runtime, atom_id, core.Descriptor.data(value, true, true, true));
    }
    return instance.value();
}

fn simpleFieldConstructorPattern(fb: *const bytecode.FunctionBytecode) ?SimpleFieldConstructorPattern {
    if (fb.flags.is_class_constructor or fb.flags.is_derived_class_constructor) return null;
    if (fb.flags.is_arrow_function or fb.flags.func_kind != .normal or !fb.flags.has_prototype) return null;
    if (fb.var_count > 1 or fb.var_refs_len != 0 or fb.cpool_count != 0) return null;
    if (fb.classInstanceFields().len != 0 or fb.classPrivateNames().len != 0 or fb.privateBoundNames().len != 0) return null;
    if (fb.flags.super_call_allowed or fb.flags.super_allowed or fb.flags.arguments_allowed or fb.flags.is_indirect_eval) return null;

    return simpleLocalThisFieldConstructorPattern(fb) orelse simpleStackThisFieldConstructorPattern(fb);
}

fn simpleLocalThisFieldConstructorPattern(fb: *const bytecode.FunctionBytecode) ?SimpleFieldConstructorPattern {
    const code = fb.byteCode();
    var pc: usize = 0;
    var pattern = SimpleFieldConstructorPattern{};
    if (pc >= code.len or code[pc] != op.push_this) return null;
    pc += 1;
    const this_local = decodeSimpleConstructorPutLoc(code, &pc) orelse return null;
    while (pc < code.len) {
        if (code[pc] == op.return_undef) {
            pc += 1;
            return if (pc == code.len and pattern.len != 0) pattern else null;
        }
        if (pattern.len == max_simple_constructor_fields) return null;
        const local_index = decodeSimpleConstructorGetLoc(code, &pc) orelse return null;
        if (local_index != this_local) return null;
        tryAppendSimpleConstructorField(code, &pc, &pattern) orelse return null;
    }
    return null;
}

fn simpleStackThisFieldConstructorPattern(fb: *const bytecode.FunctionBytecode) ?SimpleFieldConstructorPattern {
    const code = fb.byteCode();
    var pc: usize = 0;
    var pattern = SimpleFieldConstructorPattern{};
    if (pc >= code.len or code[pc] != op.push_this) return null;
    pc += 1;
    while (pc < code.len) {
        if (code[pc] == op.return_undef) {
            pc += 1;
            return if (pc == code.len and pattern.len != 0) pattern else null;
        }
        if (pattern.len == max_simple_constructor_fields) return null;
        const keeps_this_for_next_field = if (code[pc] == op.dup) blk: {
            pc += 1;
            break :blk true;
        } else false;
        tryAppendSimpleConstructorField(code, &pc, &pattern) orelse return null;
        if (pc < code.len and code[pc] != op.return_undef and !keeps_this_for_next_field) return null;
    }
    return null;
}

fn tryAppendSimpleConstructorField(code: []const u8, pc: *usize, pattern: *SimpleFieldConstructorPattern) ?void {
    const arg_index = decodeSimpleConstructorArgGet(code, pc) orelse return null;
    if (pc.* + 5 > code.len or code[pc.*] != op.put_field) return null;
    const atom_id = readInt(u32, code[pc.* + 1 ..][0..4]);
    pc.* += 5;
    for (pattern.atoms[0..pattern.len]) |existing| {
        if (existing == atom_id) return null;
    }
    pattern.atoms[pattern.len] = atom_id;
    pattern.arg_indices[pattern.len] = arg_index;
    pattern.len += 1;
}

fn decodeSimpleConstructorPutLoc(code: []const u8, pc: *usize) ?u16 {
    if (pc.* >= code.len) return null;
    const opcode_id = code[pc.*];
    pc.* += 1;
    if (opcode_id >= op.put_loc0 and opcode_id <= op.put_loc3) {
        return @intCast(opcode_id - op.put_loc0);
    }
    if (opcode_id == op.put_loc) {
        if (pc.* + 2 > code.len) return null;
        const index = readInt(u16, code[pc.*..][0..2]);
        pc.* += 2;
        return index;
    }
    return null;
}

fn decodeSimpleConstructorGetLoc(code: []const u8, pc: *usize) ?u16 {
    if (pc.* >= code.len) return null;
    const opcode_id = code[pc.*];
    pc.* += 1;
    if (opcode_id >= op.get_loc0 and opcode_id <= op.get_loc3) {
        return @intCast(opcode_id - op.get_loc0);
    }
    if (opcode_id == op.get_loc) {
        if (pc.* + 2 > code.len) return null;
        const index = readInt(u16, code[pc.*..][0..2]);
        pc.* += 2;
        return index;
    }
    return null;
}

fn decodeSimpleConstructorArgGet(code: []const u8, pc: *usize) ?u16 {
    if (pc.* >= code.len) return null;
    const opcode_id = code[pc.*];
    pc.* += 1;
    if (opcode_id >= op.get_arg0 and opcode_id <= op.get_arg3) {
        return @intCast(opcode_id - op.get_arg0);
    }
    if (opcode_id == op.get_arg) {
        if (pc.* + 2 > code.len) return null;
        const index = readInt(u16, code[pc.*..][0..2]);
        pc.* += 2;
        return index;
    }
    return null;
}

fn prototypeChainBlocksSimpleFieldStore(prototype: *core.Object, pattern: SimpleFieldConstructorPattern) bool {
    var current: ?*core.Object = prototype;
    while (current) |object| {
        if (object.hasExoticMethods() or object.proxyTarget() != null) return true;
        for (pattern.atoms[0..pattern.len]) |atom_id| {
            if (object.hasOwnProperty(atom_id)) return true;
        }
        current = object.getPrototype();
    }
    return false;
}

pub fn constructFunctionFromSource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return constructDynamicFunctionFromSource(ctx, output, global, constructor, constructor, args, .normal, caller_function, caller_frame);
}

pub fn constructGeneratorFunctionFromSource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return constructDynamicFunctionFromSource(ctx, output, global, constructor, constructor, args, .generator, caller_function, caller_frame);
}

pub const DynamicFunctionKind = enum {
    normal,
    async_function,
    generator,
    async_generator,
};

pub fn dynamicFunctionKindFromName(name: []const u8) ?DynamicFunctionKind {
    if (std.mem.eql(u8, name, "Function")) return .normal;
    if (std.mem.eql(u8, name, "AsyncFunction")) return .async_function;
    if (std.mem.eql(u8, name, "GeneratorFunction")) return .generator;
    if (std.mem.eql(u8, name, "AsyncGeneratorFunction")) return .async_generator;
    return null;
}

pub fn constructDynamicFunctionFromSource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    new_target: core.JSValue,
    args: []const core.JSValue,
    kind: DynamicFunctionKind,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var params = std.ArrayList(u8).empty;
    defer params.deinit(ctx.runtime.memory.allocator);
    var body = std.ArrayList(u8).empty;
    defer body.deinit(ctx.runtime.memory.allocator);

    if (args.len > 0) {
        for (args[0 .. args.len - 1], 0..) |arg, idx| {
            if (idx != 0) try params.append(ctx.runtime.memory.allocator, ',');
            const string_value = try string_ops.toStringForAnnexB(ctx, output, global, arg, caller_function, caller_frame);
            defer string_value.free(ctx.runtime);
            try string_ops.appendSourceStringUtf8(ctx.runtime, &params, string_value);
        }
        const body_value = try string_ops.toStringForAnnexB(ctx, output, global, args[args.len - 1], caller_function, caller_frame);
        defer body_value.free(ctx.runtime);
        try string_ops.appendSourceStringUtf8(ctx.runtime, &body, body_value);
    }
    const function_global = dynamicFunctionRealmGlobal(constructor) orelse global;
    if ((kind == .async_function or kind == .async_generator) and try promise_ops.parameterSourceContainsAwait(ctx.runtime, params.items)) {
        return exception_ops.throwSyntaxErrorMessage(ctx, function_global, "invalid syntax");
    }

    var source = std.ArrayList(u8).empty;
    defer source.deinit(ctx.runtime.memory.allocator);
    const prefix = switch (kind) {
        .normal => "(function anonymous(",
        .async_function => "(async function anonymous(",
        .generator => "(function* anonymous(",
        .async_generator => "(async function* anonymous(",
    };
    try source.appendSlice(ctx.runtime.memory.allocator, prefix);
    try source.appendSlice(ctx.runtime.memory.allocator, params.items);
    try source.appendSlice(ctx.runtime.memory.allocator, "\n) {\n");
    if (if (kind == .normal) array_ops.nativeTypedArraySubclassBase(body.items) else null) |base_name| {
        try source.appendSlice(ctx.runtime.memory.allocator, "return ");
        try source.appendSlice(ctx.runtime.memory.allocator, base_name);
        try source.append(ctx.runtime.memory.allocator, ';');
    } else {
        try source.appendSlice(ctx.runtime.memory.allocator, body.items);
    }
    try source.appendSlice(ctx.runtime.memory.allocator, "\n})");

    const filename = switch (kind) {
        .normal => "Function",
        .async_function => "AsyncFunction",
        .generator => "GeneratorFunction",
        .async_generator => "AsyncGeneratorFunction",
    };
    var compiled = try parser.compile(ctx.runtime, source.items, .{ .mode = .eval_direct, .filename = filename, .strict = false });
    defer compiled.deinit();
    if (compiled.syntax_error) |*parse_error| {
        // Compile-error surface: own fileName/lineNumber/columnNumber +
        // leading stack line (build_backtrace filename branch,
        // quickjs.c:7553-7570).
        const parse_filename = ctx.runtime.atoms.name(parse_error.filename) orelse filename;
        return error_stack_ops.throwParseSyntaxError(ctx, function_global, parse_filename, parse_error.position.line, parse_error.position.column, parse_error.message);
    }
    var nested_stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.runtime.stack_size);
    defer nested_stack.deinit(ctx.runtime);
    // A dynamic-function compilation is a *nested* eval inside a live VM call: the
    // outer frames hold roots this nested cycle pass cannot see, so running the
    // full-heap `break_var_ref_cycles_on_exit` collection here marks live outer
    // values (e.g. an in-flight exception) as garbage and frees them. qjs never
    // runs GC on eval exit (only at allocation thresholds / explicit JS_RunGC), so
    // pass `false`; the function expression makes no var_ref cycle of its own and
    // any cycle in the result is reclaimed by the top-level collection.
    const result = try runWithArgs(ctx, &nested_stack, &compiled.function, function_global.value(), &.{}, &.{}, output, function_global, false, false, false);
    errdefer result.free(ctx.runtime);
    // `runWithArgs` returns the completion value owned, but ALSO leaves an owned
    // copy on `nested_stack`. When that stack is a `vm_stack` arena window (the
    // carved-frame fast path), the leftover slot sits ABOVE the arena watermark
    // restored on frame exit. The `new_target.prototype` read below can run a
    // proxy `get` trap whose bytecode frame re-carves the same arena and
    // overwrites that orphaned slot; `nested_stack.deinit` would then free an
    // alias'd value (e.g. a `Proxy.revocable` `revoke` closure still owned by its
    // wrapper) — a refcount under-flow that dangles into a later cycle GC. Drain
    // the stack's owned copy now so the window is empty before any further
    // bytecode runs; `result` keeps the independently-owned reference.
    for (nested_stack.values) |*slot| {
        const stale = slot.*;
        slot.* = core.JSValue.undefinedValue();
        stale.free(ctx.runtime);
    }
    nested_stack.values = nested_stack.values.ptr[0..0];
    if (object_ops.functionObjectFromValue(result)) |function_object| {
        const prototype = try object_ops.dynamicFunctionNewTargetPrototype(ctx, output, global, new_target, kind, caller_function, caller_frame);
        try function_object.setPrototype(ctx.runtime, prototype);
        try object_ops.copyRealmPrototypeKeys(ctx.runtime, constructor, function_object);
        if (function_global != global) {
            try function_object.setOptionalValueSlot(ctx.runtime, try function_object.functionRealmGlobalSlot(ctx.runtime), function_global.value().dup());
        }
    }
    return result;
}

pub fn dynamicFunctionRealmGlobal(constructor: core.JSValue) ?*core.Object {
    const constructor_object = property_ops.expectObject(constructor) catch return null;
    return object_ops.objectRealmGlobal(constructor_object);
}

pub fn functionRealmGlobal(object: *core.Object) ?*core.Object {
    if (object.proxyTarget()) |target_value| {
        const target_object = object_ops.objectFromValue(target_value) orelse return null;
        return functionRealmGlobal(target_object);
    }
    return object_ops.objectRealmGlobal(object);
}

pub fn qjsAssertThrows(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), callback, &.{}, caller_function, caller_frame);
}

pub fn qjsCollectIteratorValues(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
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
        const next = callValueOrBytecode(ctx, output, global, iterator.value(), next_method, &.{}, caller_function, caller_frame) catch |err| {
            try qjsIteratorClose(ctx, output, global, iterator.value(), caller_function, caller_frame);
            return err;
        };
        defer next.free(ctx.runtime);
        const next_object = object_ops.objectFromValue(next) orelse {
            try qjsIteratorClose(ctx, output, global, iterator.value(), caller_function, caller_frame);
            return error.TypeError;
        };
        const done = object_ops.getValueProperty(ctx, output, global, next_object.value(), core.atom.predefinedId("done", .string).?, caller_function, caller_frame) catch |err| {
            try qjsIteratorClose(ctx, output, global, iterator.value(), caller_function, caller_frame);
            return err;
        };
        defer done.free(ctx.runtime);
        if (done.asBool() == true) break;
        const item = object_ops.getValueProperty(ctx, output, global, next_object.value(), core.atom.predefinedId("value", .string).?, caller_function, caller_frame) catch |err| {
            try qjsIteratorClose(ctx, output, global, iterator.value(), caller_function, caller_frame);
            return err;
        };
        defer item.free(ctx.runtime);
        values.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(index), core.Descriptor.data(item, true, true, true)) catch |err| {
            try qjsIteratorClose(ctx, output, global, iterator.value(), caller_function, caller_frame);
            return err;
        };
    }
    values.setArrayLength(index);
    return values_value;
}

pub fn qjsIteratorClose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const return_key = try ctx.runtime.internAtom("return");
    defer ctx.runtime.atoms.free(return_key);
    const return_method = try object_ops.getValueProperty(ctx, output, global, iterator_value, return_key, caller_function, caller_frame);
    defer return_method.free(ctx.runtime);
    if (return_method.isUndefined() or return_method.isNull()) return;
    if (!isCallableValue(return_method)) return error.TypeError;
    const result = try callValueOrBytecode(ctx, output, global, iterator_value, return_method, &.{}, caller_function, caller_frame);
    result.free(ctx.runtime);
}

pub const destructuring_iterator_state_kind: u8 = 0xf0;
pub const destructuring_iterator_state_mask: u8 = 0xfc;
pub const destructuring_iterator_done_bit: u8 = 0x01;
pub const destructuring_iterator_closing_bit: u8 = 0x02;

pub fn destructuringIteratorStateFromValue(value: core.JSValue) ?*core.Object {
    const object = property_ops.expectObject(value) catch return null;
    return if (isDestructuringIteratorState(object)) object else null;
}

pub fn isDestructuringIteratorState(object: *core.Object) bool {
    return object.class_id == core.class.ids.iterator_wrap and
        ((object.iteratorKindSlot().*) & destructuring_iterator_state_mask) == destructuring_iterator_state_kind;
}

pub fn createDestructuringIteratorState(rt: *core.JSRuntime, iterator_value: core.JSValue) !*core.Object {
    var owned_iterator_value = iterator_value;
    errdefer owned_iterator_value.free(rt);
    const state = try core.Object.create(rt, core.class.ids.iterator_wrap, null);
    errdefer core.Object.destroyFromHeader(rt, &state.header);
    state.iteratorKindSlot().* = destructuring_iterator_state_kind;
    state.iteratorIndexSlot().* = 0;
    try state.setOptionalValueSlot(rt, state.iteratorTargetSlot(), owned_iterator_value);
    owned_iterator_value = core.JSValue.undefinedValue();
    return state;
}

pub fn destructuringIteratorStateDone(state: *core.Object) bool {
    return ((state.iteratorKindSlot().*) & destructuring_iterator_done_bit) != 0;
}

pub fn setDestructuringIteratorStateDone(state: *core.Object) void {
    state.iteratorKindSlot().* |= destructuring_iterator_done_bit;
}

pub fn destructuringIteratorStateClosing(state: *core.Object) bool {
    return ((state.iteratorKindSlot().*) & destructuring_iterator_closing_bit) != 0;
}

pub fn setDestructuringIteratorStateClosing(state: *core.Object) void {
    state.iteratorKindSlot().* |= destructuring_iterator_closing_bit;
}

pub fn qjsDestructuringGet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    const target_index: u32 = @intCast(args[1].asInt32() orelse return error.TypeError);
    if (destructuringIteratorStateFromValue(args[0])) |state| {
        const current_index: u32 = @intCast(state.iteratorIndexSlot().*);
        var index = current_index;
        var value = core.JSValue.undefinedValue();
        var has_value = false;
        while (index <= target_index) : (index += 1) {
            if (has_value) value.free(ctx.runtime);
            const step = destructuringIteratorStep(ctx, output, global, state) catch |err| {
                try clearDestructuringIteratorState(ctx.runtime, state);
                return err;
            };
            value = step.value;
            has_value = true;
            state.iteratorIndexSlot().* = index + 1;
        }
        return value;
    }
    if (args[0].isString()) {
        const atom_id = core.atom.atomFromUInt32(target_index);
        if (try string_ops.getStringIndexValue(ctx.runtime, args[0], atom_id)) |value| return value;
        return core.JSValue.undefinedValue();
    }
    const object = property_ops.expectObject(args[0]) catch return error.TypeError;
    if (try array_ops.arrayUsesDefaultIterator(ctx, output, global, args[0], object)) {
        return object.getProperty(core.atom.atomFromUInt32(target_index));
    }

    return error.TypeError;
}

pub fn qjsDestructuringElide(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    const target_index: u32 = @intCast(args[1].asInt32() orelse return error.TypeError);
    if (destructuringIteratorStateFromValue(args[0])) |state| {
        const current_index: u32 = @intCast(state.iteratorIndexSlot().*);
        var index = current_index;
        while (index <= target_index) : (index += 1) {
            const step = destructuringIteratorStep(ctx, output, global, state) catch |err| {
                try clearDestructuringIteratorState(ctx.runtime, state);
                return err;
            };
            state.iteratorIndexSlot().* = index + 1;
            step.value.free(ctx.runtime);
            if (step.done) break;
        }
        return core.JSValue.undefinedValue();
    }
    if (args[0].isString()) return core.JSValue.undefinedValue();
    const object = property_ops.expectObject(args[0]) catch return error.TypeError;
    if (try array_ops.arrayUsesDefaultIterator(ctx, output, global, args[0], object)) return core.JSValue.undefinedValue();

    return error.TypeError;
}

pub fn qjsDestructuringRest(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    const start_index: u32 = @intCast(args[1].asInt32() orelse return error.TypeError);
    if (destructuringIteratorStateFromValue(args[0])) |state| {
        var current_index: u32 = @intCast(state.iteratorIndexSlot().*);
        while (current_index < start_index) : (current_index += 1) {
            const skipped = destructuringIteratorStep(ctx, output, global, state) catch |err| {
                try clearDestructuringIteratorState(ctx.runtime, state);
                return err;
            };
            state.iteratorIndexSlot().* = current_index + 1;
            skipped.value.free(ctx.runtime);
            if (skipped.done) break;
        }

        const out = try core.Object.createArray(ctx.runtime, null);
        errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
        var out_value = out.value();
        var value = core.JSValue.undefinedValue();
        var root_values = [_]core.runtime.ValueRootValue{
            .{ .value = &out_value },
            .{ .value = &value },
        };
        const root_frame = core.runtime.ValueRootFrame{
            .previous = ctx.runtime.active_value_roots,
            .values = &root_values,
        };
        ctx.runtime.active_value_roots = &root_frame;
        defer ctx.runtime.active_value_roots = root_frame.previous;
        defer value.free(ctx.runtime);

        while (true) {
            const step = destructuringIteratorStep(ctx, output, global, state) catch |err| {
                try clearDestructuringIteratorState(ctx.runtime, state);
                return err;
            };
            value = step.value;
            if (step.done) {
                value.free(ctx.runtime);
                value = core.JSValue.undefinedValue();
                break;
            }
            try out.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(out.arrayLength()), core.Descriptor.data(value, true, true, true));
            value.free(ctx.runtime);
            value = core.JSValue.undefinedValue();
            current_index += 1;
            state.iteratorIndexSlot().* = current_index;
        }
        return out_value;
    }
    const object = property_ops.expectObject(args[0]) catch return error.TypeError;
    if (try array_ops.arrayUsesDefaultIterator(ctx, output, global, args[0], object)) {
        const out = try core.Object.createArray(ctx.runtime, null);
        errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
        var out_value = out.value();
        var value = core.JSValue.undefinedValue();
        var root_values = [_]core.runtime.ValueRootValue{
            .{ .value = &out_value },
            .{ .value = &value },
        };
        const root_frame = core.runtime.ValueRootFrame{
            .previous = ctx.runtime.active_value_roots,
            .values = &root_values,
        };
        ctx.runtime.active_value_roots = &root_frame;
        defer ctx.runtime.active_value_roots = root_frame.previous;
        defer value.free(ctx.runtime);

        var index = start_index;
        while (index < object.arrayLength()) : (index += 1) {
            value = object.getProperty(core.atom.atomFromUInt32(index));
            try out.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(out.arrayLength()), core.Descriptor.data(value, true, true, true));
            value.free(ctx.runtime);
            value = core.JSValue.undefinedValue();
        }
        return out_value;
    }
    return error.TypeError;
}

pub fn qjsDestructuringClose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 1) return core.JSValue.undefinedValue();
    const state = destructuringIteratorStateFromValue(args[0]) orelse return core.JSValue.undefinedValue();
    const iterator_value = (state.iteratorTargetSlot().*) orelse return core.JSValue.undefinedValue();
    if (destructuringIteratorStateDone(state)) {
        try clearDestructuringIteratorState(ctx.runtime, state);
        return core.JSValue.undefinedValue();
    }
    const iterator = try property_ops.expectObject(iterator_value);
    errdefer clearDestructuringIteratorState(ctx.runtime, state) catch {};
    setDestructuringIteratorStateClosing(state);
    setDestructuringIteratorStateDone(state);
    const return_key = try ctx.runtime.internAtom("return");
    defer ctx.runtime.atoms.free(return_key);
    const return_method = try object_ops.getValueProperty(ctx, output, global, iterator.value(), return_key, null, null);
    defer return_method.free(ctx.runtime);
    if (!isCallableValue(return_method)) {
        try clearDestructuringIteratorState(ctx.runtime, state);
        return core.JSValue.undefinedValue();
    }
    const result = try callValueOrBytecode(ctx, output, global, iterator.value(), return_method, &.{}, null, null);
    defer result.free(ctx.runtime);
    if (!result.isObject()) {
        try clearDestructuringIteratorState(ctx.runtime, state);
        return error.TypeError;
    }
    try clearDestructuringIteratorState(ctx.runtime, state);
    return core.JSValue.undefinedValue();
}

pub fn qjsDestructuringRequireIterator(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 1) return error.TypeError;
    if (destructuringIteratorStateFromValue(args[0])) |_| return args[0].dup();

    var iterator_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &iterator_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;
    defer iterator_value.free(ctx.runtime);

    const source = property_ops.expectObject(args[0]) catch {
        const iterator_method = try getIteratorMethod(ctx, output, global, args[0]);
        defer iterator_method.free(ctx.runtime);
        if (!isCallableValue(iterator_method)) return exception_ops.throwTypeErrorMessage(ctx, global, "value is not iterable");
        iterator_value = try callValueOrBytecode(ctx, output, global, args[0], iterator_method, &.{}, null, null);
        _ = try property_ops.expectObject(iterator_value);
        try cacheDestructuringIteratorNextMethod(ctx, output, global, iterator_value);
        const state = try createDestructuringIteratorState(ctx.runtime, iterator_value.dup());
        return state.value();
    };
    if (try array_ops.arrayUsesDefaultIterator(ctx, output, global, args[0], source)) return args[0].dup();
    if (source.class_id == core.class.ids.generator or source.class_id == core.class.ids.async_generator) {
        try cacheDestructuringIteratorNextMethod(ctx, output, global, source.value());
        const state = try createDestructuringIteratorState(ctx.runtime, source.value().dup());
        return state.value();
    }
    const iterator_method = try getIteratorMethod(ctx, output, global, args[0]);
    defer iterator_method.free(ctx.runtime);
    if (!isCallableValue(iterator_method)) return exception_ops.throwTypeErrorMessage(ctx, global, "value is not iterable");
    iterator_value = try callValueOrBytecode(ctx, output, global, args[0], iterator_method, &.{}, null, null);
    _ = try property_ops.expectObject(iterator_value);
    try cacheDestructuringIteratorNextMethod(ctx, output, global, iterator_value);
    const state = try createDestructuringIteratorState(ctx.runtime, iterator_value.dup());
    return state.value();
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

pub fn iteratorForValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (source_value.isString()) return core.object.stringIterator(ctx.runtime, source_value);
    const source_object = property_ops.expectObject(source_value) catch null;
    if (source_object != null and source_object.?.class_id == core.class.ids.string) return core.object.stringIterator(ctx.runtime, source_value);
    if (source_object != null and
        (source_object.?.class_id == core.class.ids.array_iterator or
            source_object.?.class_id == core.class.ids.string_iterator or
            source_object.?.class_id == core.class.ids.generator or
            source_object.?.class_id == core.class.ids.async_generator))
    {
        return source_value.dup();
    }
    const iterator_method = try getIteratorMethod(ctx, output, global, source_value);
    defer iterator_method.free(ctx.runtime);
    if (!isCallableValue(iterator_method)) return exception_ops.throwTypeErrorMessage(ctx, global, "value is not iterable");
    const iterator_value = try callValueOrBytecode(ctx, output, global, source_value, iterator_method, &.{}, caller_function, caller_frame);
    errdefer iterator_value.free(ctx.runtime);
    _ = property_ops.expectObject(iterator_value) catch return error.TypeError;
    try cacheIteratorNextMethod(ctx, output, global, iterator_value);
    return iterator_value;
}

pub fn cacheIteratorNextMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
) !void {
    try cacheIteratorNextMethodMode(ctx, output, global, iterator_value, true);
}

pub fn cacheDestructuringIteratorNextMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
) !void {
    try cacheIteratorNextMethodMode(ctx, output, global, iterator_value, false);
}

pub fn cacheIteratorNextMethodMode(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    require_callable: bool,
) !void {
    const iterator = try property_ops.expectObject(iterator_value);
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try object_ops.getValueProperty(ctx, output, global, iterator_value, next_key, null, null);
    defer next_method.free(ctx.runtime);
    if (require_callable and !isCallableValue(next_method)) return error.TypeError;
    const cached = try iterator.cachedIteratorNextSlot(ctx.runtime);
    try iterator.setOptionalValueSlot(ctx.runtime, cached, next_method.dup());
}

pub const DestructuringIteratorStep = struct {
    value: core.JSValue,
    done: bool,
};

pub const IteratorStepResult = struct {
    result: core.JSValue,
    value: core.JSValue,
    done: bool,
};

pub fn destructuringIteratorStep(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    state: *core.Object,
) !DestructuringIteratorStep {
    const iterator_value = (state.iteratorTargetSlot().*) orelse
        return .{ .value = core.JSValue.undefinedValue(), .done = true };
    const iterator = try property_ops.expectObject(iterator_value);
    const next_method = if (iterator.cachedIteratorNext(ctx.runtime)) |stored| stored.dup() else blk: {
        const next_key = try ctx.runtime.internAtom("next");
        defer ctx.runtime.atoms.free(next_key);
        break :blk try object_ops.getValueProperty(ctx, output, global, iterator_value, next_key, null, null);
    };
    defer next_method.free(ctx.runtime);
    if (!isCallableValue(next_method)) return error.TypeError;
    var next_result_value = try callValueOrBytecode(ctx, output, global, iterator_value, next_method, &.{}, null, null);
    defer next_result_value.free(ctx.runtime);
    if (object_ops.objectFromValue(next_result_value)) |promise| {
        if (promise.class_id == core.class.ids.promise) {
            if (promise.promiseIsRejected()) {
                const reason = if (promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
                _ = ctx.throwValue(reason);
                return error.JSException;
            }
            const fulfilled = if (promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
            next_result_value.free(ctx.runtime);
            next_result_value = fulfilled;
        }
    }
    const next_result = property_ops.expectObject(next_result_value) catch return error.TypeError;
    if (next_result.class_id == core.class.ids.regexp) {
        return .{ .value = core.JSValue.undefinedValue(), .done = false };
    }
    const done_key = core.atom.predefinedId("done", .string).?;
    const done = try object_ops.getValueProperty(ctx, output, global, next_result.value(), done_key, null, null);
    defer done.free(ctx.runtime);
    if (value_ops.isTruthy(done)) {
        setDestructuringIteratorStateDone(state);
        return .{ .value = core.JSValue.undefinedValue(), .done = true };
    }
    const value_key = core.atom.predefinedId("value", .string).?;
    return .{ .value = try object_ops.getValueProperty(ctx, output, global, next_result.value(), value_key, null, null), .done = false };
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
        break :blk try callValueOrBytecode(ctx, output, global, source_value, iterator_method, &.{}, null, null);
    };
    defer iterator_value.free(ctx.runtime);
    if (!iterator_value.isObject()) return error.TypeError;
    var index = start_index;
    while (true) {
        const step = try iteratorStepValue(ctx, output, global, iterator_value);
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
    const iterator_value = try callValueOrBytecode(ctx, output, global, source_value, iterator_method, &.{}, null, null);
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
        if (!target_obj.flags.is_array or target_obj.hasExoticMethods() or target_obj.proxyTarget() != null) break :fast;
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
        const step = try iteratorStepValue(ctx, output, global, iterator_value);
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

pub fn iteratorStepValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
) !DestructuringIteratorStep {
    const iterator = try property_ops.expectObject(iterator_value);
    const next_method = if (iterator.cachedIteratorNext(ctx.runtime)) |stored| stored.dup() else blk: {
        const next_key = try ctx.runtime.internAtom("next");
        defer ctx.runtime.atoms.free(next_key);
        break :blk try object_ops.getValueProperty(ctx, output, global, iterator_value, next_key, null, null);
    };
    defer next_method.free(ctx.runtime);
    if (!isCallableValue(next_method)) return error.TypeError;
    var next_result_value = try callValueOrBytecode(ctx, output, global, iterator_value, next_method, &.{}, null, null);
    defer next_result_value.free(ctx.runtime);
    if (object_ops.objectFromValue(next_result_value)) |promise| {
        if (promise.class_id == core.class.ids.promise) {
            if (promise.promiseIsRejected()) {
                const reason = if (promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
                _ = ctx.throwValue(reason);
                return error.JSException;
            }
            const fulfilled = if (promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
            next_result_value.free(ctx.runtime);
            next_result_value = fulfilled;
        }
    }
    const next_result = property_ops.expectObject(next_result_value) catch return error.TypeError;
    if (next_result.class_id == core.class.ids.regexp) {
        return .{ .value = core.JSValue.undefinedValue(), .done = false };
    }
    const done_key = core.atom.predefinedId("done", .string).?;
    const done = try object_ops.getValueProperty(ctx, output, global, next_result.value(), done_key, null, null);
    defer done.free(ctx.runtime);
    if (value_ops.isTruthy(done)) return .{ .value = core.JSValue.undefinedValue(), .done = true };
    const value_key = core.atom.predefinedId("value", .string).?;
    return .{ .value = try object_ops.getValueProperty(ctx, output, global, next_result.value(), value_key, null, null), .done = false };
}

pub fn iteratorStepResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    next_arg: core.JSValue,
) !IteratorStepResult {
    const iterator = try property_ops.expectObject(iterator_value);
    const next_method = if (iterator.cachedIteratorNext(ctx.runtime)) |stored| stored.dup() else blk: {
        const next_key = try ctx.runtime.internAtom("next");
        defer ctx.runtime.atoms.free(next_key);
        break :blk try object_ops.getValueProperty(ctx, output, global, iterator_value, next_key, null, null);
    };
    defer next_method.free(ctx.runtime);
    if (!isCallableValue(next_method)) return error.TypeError;
    const next_result_value = try callValueOrBytecode(ctx, output, global, iterator_value, next_method, &.{next_arg}, null, null);
    errdefer next_result_value.free(ctx.runtime);
    const next_result = property_ops.expectObject(next_result_value) catch return error.TypeError;
    const done_key = core.atom.predefinedId("done", .string).?;
    const done = try object_ops.getValueProperty(ctx, output, global, next_result.value(), done_key, null, null);
    defer done.free(ctx.runtime);
    const is_done = coercion_ops.valueTruthy(done);
    const value = if (is_done) blk: {
        const value_key = core.atom.predefinedId("value", .string).?;
        break :blk try object_ops.getValueProperty(ctx, output, global, next_result.value(), value_key, null, null);
    } else core.JSValue.undefinedValue();
    errdefer value.free(ctx.runtime);
    return .{ .result = next_result_value, .value = value, .done = is_done };
}

pub fn clearDestructuringIteratorState(rt: *core.JSRuntime, state: *core.Object) !void {
    if (!isDestructuringIteratorState(state)) return;
    state.clearIteratorTarget(rt);
    state.iteratorIndexSlot().* = 0;
    state.iteratorKindSlot().* = 0;
}

pub fn isCallableValue(value: core.JSValue) bool {
    return value.isFunctionBytecode() or object_ops.functionObjectFromValue(value) != null or object_ops.callableObjectFromValue(value) != null or object_ops.proxyTargetIsCallable(value);
}

pub fn qjsReflectCallForNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const reflect_mod = reflect_dispatch;
    return switch (id) {
        @intFromEnum(reflect_mod.StaticMethod.define_property) => (try object_ops.qjsDefinePropertyWithKind(ctx, output, global, args, 2, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.get_own_property_descriptor) => (try object_ops.qjsReflectGetOwnPropertyDescriptorCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.delete_property) => (try object_ops.qjsReflectDeletePropertyCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.get) => (try qjsReflectGetCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.get_prototype_of) => (try object_ops.qjsReflectGetPrototypeOfCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.set) => (try qjsReflectSetCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.set_prototype_of) => (try object_ops.qjsReflectSetPrototypeOfCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.is_extensible) => (try qjsReflectIsExtensibleCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.prevent_extensions) => (try qjsReflectPreventExtensionsCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.has) => (try qjsReflectHasCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.own_keys) => (try qjsReflectOwnKeysCall(ctx, output, global, args)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.construct) => (try qjsReflectConstructCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.apply) => try qjsReflectApplyCall(ctx, output, global, args, caller_function, caller_frame),
        else => error.TypeError,
    };
}

pub const AtomicsReadModifyOp = enum {
    add,
    @"and",
    compareExchange,
    exchange,
    load,
    @"or",
    sub,
    xor,
};

pub const AtomicsWaiterKey = struct {
    store: ?*core.object.SharedBufferStore = null,
    offset_or_ptr: usize,
};

pub const AtomicsWaiter = struct {
    key: AtomicsWaiterKey,
    notified: bool = false,
    linked: bool = false,
    cond: std.Io.Condition = .init,
    promise: ?core.JSValue = null,
    ctx: ?*core.JSContext = null,
    deadline: ?std.Io.Timestamp = null,
    next: ?*AtomicsWaiter = null,
};

pub var atomics_waiter_mutex: std.Io.Mutex = .init;
pub var atomics_waiters: ?*AtomicsWaiter = null;

pub fn qjsAtomicsCallForNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const atomics_mod = atomics_wait;
    return switch (id) {
        @intFromEnum(atomics_mod.StaticMethod.is_lock_free) => try qjsAtomicsIsLockFree(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.pause) => try qjsAtomicsPause(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.notify) => try qjsAtomicsNotify(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.wait) => try qjsAtomicsWait(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.wait_async) => try promise_ops.qjsAtomicsWaitAsync(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.store) => try qjsAtomicsStore(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.load) => try qjsAtomicsReadModifyWrite(ctx, output, global, args, .load, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.add) => try qjsAtomicsReadModifyWrite(ctx, output, global, args, .add, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.@"and") => try qjsAtomicsReadModifyWrite(ctx, output, global, args, .@"and", caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.@"or") => try qjsAtomicsReadModifyWrite(ctx, output, global, args, .@"or", caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.sub) => try qjsAtomicsReadModifyWrite(ctx, output, global, args, .sub, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.xor) => try qjsAtomicsReadModifyWrite(ctx, output, global, args, .xor, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.exchange) => try qjsAtomicsReadModifyWrite(ctx, output, global, args, .exchange, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.compare_exchange) => try qjsAtomicsReadModifyWrite(ctx, output, global, args, .compareExchange, caller_function, caller_frame),
        else => error.TypeError,
    };
}

pub fn qjsAtomicsIsLockFree(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const size_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const size = try toInt32ForAtomics(ctx, output, global, size_value, caller_function, caller_frame);
    return core.JSValue.boolean(size == 1 or size == 2 or size == 4 or size == 8);
}

pub fn qjsAtomicsPause(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    _ = caller_function;
    _ = caller_frame;
    if (args.len >= 1 and !args[0].isUndefined()) {
        if (!args[0].isNumber()) return error.TypeError;
        const number = value_ops.numberValue(args[0]) orelse std.math.nan(f64);
        if (!std.math.isFinite(number) or @trunc(number) != number) return error.TypeError;
    }
    return core.JSValue.undefinedValue();
}

pub fn qjsAtomicsReadModifyWrite(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    atomic_op: AtomicsReadModifyOp,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const view_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const view = try array_ops.atomicsTypedArray(view_value, false);
    if (atomic_op != .load) try core.object.typedArrayRejectImmutableBuffer(ctx.runtime, view);
    const index_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const index = try atomicsGetBufIndex(ctx, output, global, view, index_value, caller_function, caller_frame);

    const is_bigint = array_ops.atomicsTypedArrayIsBigInt(view);
    const value_arg = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const replacement_arg = if (args.len >= 4) args[3] else core.JSValue.undefinedValue();
    const operand = if (atomic_op == .load) @as(u64, 0) else if (is_bigint)
        try toBigIntBitsForAtomics(ctx, output, global, value_arg, caller_function, caller_frame)
    else
        try toUint32ForAtomics(ctx, output, global, value_arg, caller_function, caller_frame);
    const replacement = if (atomic_op == .compareExchange) blk: {
        break :blk if (is_bigint)
            try toBigIntBitsForAtomics(ctx, output, global, replacement_arg, caller_function, caller_frame)
        else
            try toUint32ForAtomics(ctx, output, global, replacement_arg, caller_function, caller_frame);
    } else @as(u64, 0);
    // js_atomics_op (quickjs.c:60604): LOAD coerces no operand, so qjs skips
    // the post-coercion re-check for it; every other op re-validates after
    // the operand conversions ran user code.
    if (atomic_op != .load) try atomicsRevalidateIndex(ctx.runtime, view, index);

    const bytes = try atomicsElementBytes(view, index);
    const old = atomicsReadBits(view, bytes);
    const next = switch (atomic_op) {
        .load => old,
        .add => old +% operand,
        .@"and" => old & operand,
        .@"or" => old | operand,
        .sub => old -% operand,
        .xor => old ^ operand,
        .exchange => operand,
        .compareExchange => if (old == atomicsMaskBits(view, operand)) replacement else old,
    };
    if (atomic_op != .load) atomicsWriteBits(view, bytes, next);
    return atomicsValueFromBits(ctx.runtime, view, old);
}

pub fn qjsAtomicsStore(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const view_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const view = try array_ops.atomicsTypedArray(view_value, false);
    try core.object.typedArrayRejectImmutableBuffer(ctx.runtime, view);
    const index_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const index = try atomicsGetBufIndex(ctx, output, global, view, index_value, caller_function, caller_frame);

    const value_arg = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const is_bigint = array_ops.atomicsTypedArrayIsBigInt(view);
    const stored_value = if (is_bigint)
        try toBigIntValueForAtomics(ctx, output, global, value_arg, caller_function, caller_frame)
    else
        try toIntegerValueForAtomics(ctx, output, global, value_arg, caller_function, caller_frame);
    errdefer stored_value.free(ctx.runtime);
    const bits = if (is_bigint)
        try bigintBitsForAtomics(ctx.runtime, stored_value)
    else
        try uint32FromIntegerValueForAtomics(ctx.runtime, stored_value);
    // Mirrors js_atomics_store (quickjs.c:60770-60773): re-check
    // typed_array_is_oob (TypeError) then the fresh count (RangeError) after
    // the value coercion ran user code.
    try atomicsRevalidateIndex(ctx.runtime, view, index);
    const bytes = try atomicsElementBytes(view, index);
    atomicsWriteBits(view, bytes, bits);
    return stored_value;
}

pub fn qjsAtomicsNotify(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const view_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const view = try array_ops.atomicsTypedArray(view_value, true);
    const buffer = try object_ops.atomicsBufferObject(view);
    if (buffer.class_id != core.class.ids.shared_array_buffer and buffer.arrayBufferDetached()) return error.TypeError;
    const index_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const index = try atomicsValidateAccess(ctx, output, global, view, index_value, caller_function, caller_frame);
    const count = try atomicsNotifyCount(ctx, output, global, args, caller_function, caller_frame);
    if (buffer.class_id != core.class.ids.shared_array_buffer or count == 0) return core.JSValue.int32(0);
    try atomicsValidateIndex(ctx.runtime, view, index);
    const bytes = try atomicsElementBytes(view, index);
    const key = try atomicsWaiterKey(view, bytes);
    return core.JSValue.int32(@intCast(atomicsWakeWaiters(key, count)));
}

pub fn qjsAtomicsWait(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const view_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const view = try array_ops.atomicsTypedArray(view_value, true);
    if ((try object_ops.atomicsBufferObject(view)).class_id != core.class.ids.shared_array_buffer) return error.TypeError;
    const index_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const index = try atomicsValidateAccess(ctx, output, global, view, index_value, caller_function, caller_frame);
    const expected_arg = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const expected = if (array_ops.atomicsTypedArrayIsBigInt(view))
        try toBigIntBitsForAtomics(ctx, output, global, expected_arg, caller_function, caller_frame)
    else
        try toInt32BitsForAtomics(ctx, output, global, expected_arg, caller_function, caller_frame);
    const timeout_arg = if (args.len >= 4) args[3] else core.JSValue.float64(std.math.inf(f64));
    const timeout = try toNumberForAtomics(ctx, output, global, timeout_arg, caller_function, caller_frame);
    // Mirrors js_atomics_wait (quickjs.c:60900-60901): the can-block check
    // runs after the operand coercions but BEFORE the memory load/compare, so
    // a non-blockable thread throws TypeError instead of returning
    // "not-equal".
    if (!ctx.runtime.canBlock()) return exception_ops.throwTypeErrorMessage(ctx, global, "cannot block in this thread");
    try atomicsValidateIndex(ctx.runtime, view, index);
    const bytes = try atomicsElementBytes(view, index);
    const current = atomicsReadBits(view, bytes);
    if (current != atomicsMaskBits(view, expected)) return value_ops.createStringValue(ctx.runtime, "not-equal");
    const wait_ms = atomicsWaitTimeoutMilliseconds(timeout);
    if (wait_ms == 0) return value_ops.createStringValue(ctx.runtime, "timed-out");
    const key = try atomicsWaiterKey(view, bytes);
    return atomicsWaitForNotification(ctx.runtime, key, wait_ms);
}

pub fn atomicsNotifyCount(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    if (args.len < 3 or args[2].isUndefined()) return std.math.maxInt(usize);
    const count_value = try toIntegerValueForAtomics(ctx, output, global, args[2], caller_function, caller_frame);
    defer count_value.free(ctx.runtime);
    const count_number = value_ops.numberValue(count_value) orelse return 0;
    if (std.math.isNan(count_number) or count_number <= 0) return 0;
    if (!std.math.isFinite(count_number)) return std.math.maxInt(usize);
    return @intFromFloat(@min(count_number, @as(f64, @floatFromInt(std.math.maxInt(i32)))));
}

pub fn atomicsWaitTimeoutMilliseconds(timeout: f64) ?i64 {
    if (std.math.isNan(timeout) or !std.math.isFinite(timeout)) return null;
    if (timeout <= 0) return 0;
    return @intFromFloat(@min(timeout, @as(f64, @floatFromInt(std.math.maxInt(i64)))));
}

pub fn atomicsWaiterKey(view: *core.Object, bytes: []const u8) !AtomicsWaiterKey {
    const buffer = try object_ops.atomicsBufferObject(view);
    if (buffer.class_id == core.class.ids.shared_array_buffer) {
        if (buffer.sharedByteStorageStore()) |store| {
            const base = @intFromPtr(buffer.byteStorage().ptr);
            const ptr = @intFromPtr(bytes.ptr);
            return .{ .store = store, .offset_or_ptr = ptr - base };
        }
    }
    return .{ .offset_or_ptr = @intFromPtr(bytes.ptr) };
}

pub fn atomicsWaiterKeysEqual(a: AtomicsWaiterKey, b: AtomicsWaiterKey) bool {
    return a.store == b.store and a.offset_or_ptr == b.offset_or_ptr;
}

pub fn atomicsRetainWaiterKey(key: AtomicsWaiterKey) void {
    if (key.store) |store| store.retain();
}

pub fn atomicsReleaseWaiterKey(key: *AtomicsWaiterKey) void {
    if (key.store) |store| {
        store.release();
        key.store = null;
    }
}

pub fn atomicsWakeWaiters(key: AtomicsWaiterKey, count: usize) usize {
    const io = atomicsWaiterIo();
    atomics_waiter_mutex.lockUncancelable(io);
    defer atomics_waiter_mutex.unlock(io);

    var woken: usize = 0;
    var previous: ?*AtomicsWaiter = null;
    var cursor = atomics_waiters;
    while (cursor) |waiter| {
        const next = waiter.next;
        if (!atomicsWaiterKeysEqual(waiter.key, key) or waiter.notified) {
            previous = waiter;
            cursor = next;
            continue;
        }
        waiter.notified = true;
        if (waiter.promise) |promise| {
            promise_ops.atomicsSettleAsyncWaiter(waiter, promise, "ok") catch {};
            if (previous) |prev| {
                prev.next = next;
            } else {
                atomics_waiters = next;
            }
            waiter.linked = false;
            waiter.next = null;
            promise_ops.atomicsDestroyAsyncWaiter(waiter);
        } else {
            waiter.cond.signal(io);
            previous = waiter;
        }
        woken += 1;
        if (woken == count) break;
        cursor = next;
    }
    return woken;
}

pub fn processExpiredAtomicsWaiters(ctx: *core.JSContext) !void {
    const io = atomicsWaiterIo();
    const now = std.Io.Timestamp.now(io, .awake);
    atomics_waiter_mutex.lockUncancelable(io);
    defer atomics_waiter_mutex.unlock(io);

    var previous: ?*AtomicsWaiter = null;
    var cursor = atomics_waiters;
    while (cursor) |waiter| {
        const next = waiter.next;
        const expired = waiter.ctx == ctx and waiter.promise != null and waiter.deadline != null and now.nanoseconds >= waiter.deadline.?.nanoseconds;
        if (!expired) {
            previous = waiter;
            cursor = next;
            continue;
        }
        try promise_ops.atomicsSettleAsyncWaiter(waiter, waiter.promise.?, "timed-out");
        if (previous) |prev| {
            prev.next = next;
        } else {
            atomics_waiters = next;
        }
        waiter.linked = false;
        waiter.next = null;
        promise_ops.atomicsDestroyAsyncWaiter(waiter);
        cursor = next;
    }
}

pub fn cleanupAtomicsWaitersForContext(ctx: *core.JSContext) void {
    const io = atomicsWaiterIo();
    atomics_waiter_mutex.lockUncancelable(io);
    defer atomics_waiter_mutex.unlock(io);

    var previous: ?*AtomicsWaiter = null;
    var cursor = atomics_waiters;
    while (cursor) |waiter| {
        const next = waiter.next;
        if (waiter.ctx != ctx) {
            previous = waiter;
            cursor = next;
            continue;
        }
        if (previous) |prev| {
            prev.next = next;
        } else {
            atomics_waiters = next;
        }
        waiter.linked = false;
        waiter.next = null;
        promise_ops.atomicsDestroyAsyncWaiter(waiter);
        cursor = next;
    }
}

pub fn atomicsWaitForNotification(rt: *core.JSRuntime, key: AtomicsWaiterKey, timeout_ms: ?i64) !core.JSValue {
    atomicsRetainWaiterKey(key);
    var retained_key = key;
    defer atomicsReleaseWaiterKey(&retained_key);

    var waiter = AtomicsWaiter{ .key = retained_key };
    const io = atomicsWaiterIo();
    atomics_waiter_mutex.lockUncancelable(io);
    defer atomics_waiter_mutex.unlock(io);
    atomicsLinkWaiter(&waiter);
    defer atomicsUnlinkWaiter(&waiter);

    if (timeout_ms == null) {
        while (!waiter.notified) waiter.cond.waitUncancelable(io, &atomics_waiter_mutex);
        return value_ops.createStringValue(rt, "ok");
    }

    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(std.Io.Duration.fromMilliseconds(timeout_ms.?));
    while (!waiter.notified) {
        const now = std.Io.Timestamp.now(io, .awake);
        if (now.nanoseconds >= deadline.nanoseconds) break;
        atomics_waiter_mutex.unlock(io);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        atomics_waiter_mutex.lockUncancelable(io);
    }
    return value_ops.createStringValue(rt, if (waiter.notified) "ok" else "timed-out");
}

pub fn atomicsLinkWaiter(waiter: *AtomicsWaiter) void {
    waiter.linked = true;
    waiter.next = null;
    if (atomics_waiters == null) {
        atomics_waiters = waiter;
        return;
    }
    var tail = atomics_waiters.?;
    while (tail.next) |next| tail = next;
    tail.next = waiter;
}

pub fn atomicsUnlinkWaiter(waiter: *AtomicsWaiter) void {
    if (!waiter.linked) return;
    var previous: ?*AtomicsWaiter = null;
    var cursor = atomics_waiters;
    while (cursor) |current| : (cursor = current.next) {
        if (current != waiter) {
            previous = current;
            continue;
        }
        if (previous) |prev| {
            prev.next = current.next;
        } else {
            atomics_waiters = current.next;
        }
        current.next = null;
        current.linked = false;
        return;
    }
}

pub fn atomicsWaiterIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn atomicsValidateAccess(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    index_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    const length = try core.object.typedArrayLength(ctx.runtime, object);
    const index = try toIndexForAtomics(ctx, output, global, index_value, caller_function, caller_frame);
    if (index >= length) return error.RangeError;
    return index;
}

pub fn atomicsValidateIndex(rt: *core.JSRuntime, object: *core.Object, index: usize) !void {
    const length = try core.object.typedArrayLength(rt, object);
    if (index >= length) return error.RangeError;
}

/// Mirrors js_atomics_get_buf (quickjs.c:60526) for the non-waitable Atomics
/// ops (is_waitable == 0): after the class check, a detached non-shared buffer
/// throws TypeError BEFORE ToIndex; the view length is captured BEFORE ToIndex
/// (`old_len`) so an index-coercion side effect that grows a length-tracking
/// view cannot legitimize an index that was out of bounds at validation time
/// (`idx >= old_len` -> RangeError); then RevalidateAtomicAccess re-checks
/// typed_array_is_oob (-> TypeError) and the fresh count (-> RangeError).
pub fn atomicsGetBufIndex(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    view: *core.Object,
    index_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    const buffer = try object_ops.atomicsBufferObject(view);
    if (buffer.class_id != core.class.ids.shared_array_buffer and buffer.arrayBufferDetached()) return error.TypeError;
    const old_len = try core.object.typedArrayLength(ctx.runtime, view);
    const index = try toIndexForAtomics(ctx, output, global, index_value, caller_function, caller_frame);
    if (index >= old_len) return error.RangeError;
    try atomicsRevalidateIndex(ctx.runtime, view, index);
    return index;
}

/// Mirrors the js_atomics_op (quickjs.c:60628-60631) / js_atomics_store
/// post-coercion re-check: typed_array_is_oob (detached or shrunk-resizable)
/// -> TypeError, then the fresh count -> RangeError.
pub fn atomicsRevalidateIndex(rt: *core.JSRuntime, view: *core.Object, index: usize) !void {
    if (try core.object.typedArrayDetached(view) or try core.object.typedArrayOutOfBounds(view)) return error.TypeError;
    try atomicsValidateIndex(rt, view, index);
}

pub fn atomicsElementBytes(object: *core.Object, index: usize) ![]u8 {
    const buffer = try object_ops.atomicsBufferObject(object);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    const offset = object.typedArrayByteOffset() + index * object.typedArrayElementSize();
    if (offset + object.typedArrayElementSize() > buffer.byteStorage().len) return error.RangeError;
    return buffer.byteStorage()[offset..][0..object.typedArrayElementSize()];
}

pub fn atomicsReadBits(object: *core.Object, bytes: []const u8) u64 {
    return switch (object.typedArrayElementSize()) {
        1 => bytes[0],
        2 => std.mem.readInt(u16, bytes[0..2], .little),
        4 => std.mem.readInt(u32, bytes[0..4], .little),
        8 => std.mem.readInt(u64, bytes[0..8], .little),
        else => 0,
    };
}

pub fn atomicsWriteBits(object: *core.Object, bytes: []u8, value: u64) void {
    switch (object.typedArrayElementSize()) {
        1 => bytes[0] = @truncate(value),
        2 => std.mem.writeInt(u16, bytes[0..2], @truncate(value), .little),
        4 => std.mem.writeInt(u32, bytes[0..4], @truncate(value), .little),
        8 => std.mem.writeInt(u64, bytes[0..8], value, .little),
        else => {},
    }
}

pub fn atomicsMaskBits(object: *core.Object, value: u64) u64 {
    return switch (object.typedArrayElementSize()) {
        1 => value & 0xff,
        2 => value & 0xffff,
        4 => value & 0xffff_ffff,
        else => value,
    };
}

pub fn atomicsValueFromBits(rt: *core.JSRuntime, object: *core.Object, bits: u64) !core.JSValue {
    return switch (object.typedArrayKind()) {
        1 => core.JSValue.int32(@as(i8, @bitCast(@as(u8, @truncate(bits))))),
        2 => core.JSValue.int32(@as(u8, @truncate(bits))),
        4 => core.JSValue.int32(@as(i16, @bitCast(@as(u16, @truncate(bits))))),
        5 => core.JSValue.int32(@as(u16, @truncate(bits))),
        6 => core.JSValue.int32(@as(i32, @bitCast(@as(u32, @truncate(bits))))),
        7 => atomicsNumberResult(@floatFromInt(@as(u32, @truncate(bits)))),
        11 => value_ops.createBigIntI128(rt, @as(i64, @bitCast(bits))),
        12 => value_ops.createBigIntI128(rt, @as(i128, bits)),
        else => error.TypeError,
    };
}

pub fn toIndexForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    const number = try toNumberForAtomics(ctx, output, global, value, caller_function, caller_frame);
    if (std.math.isNan(number)) return 0;
    if (!std.math.isFinite(number)) return error.RangeError;
    const truncated = @trunc(number);
    if (truncated < 0) return error.RangeError;
    return @intFromFloat(truncated);
}

pub fn toNumberForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !f64 {
    _ = caller_function;
    _ = caller_frame;
    const primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);
    if (primitive.isBigInt()) return error.TypeError;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    defer number_value.free(ctx.runtime);
    return value_ops.numberValue(number_value) orelse std.math.nan(f64);
}

pub fn toInt32ForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !i32 {
    const bits = try toUint32ForAtomics(ctx, output, global, value, caller_function, caller_frame);
    return @bitCast(@as(u32, @truncate(bits)));
}

pub fn toInt32BitsForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !u64 {
    const int_value = try toInt32ForAtomics(ctx, output, global, value, caller_function, caller_frame);
    return @as(u32, @bitCast(int_value));
}

pub fn toUint32ForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !u64 {
    const number = try toNumberForAtomics(ctx, output, global, value, caller_function, caller_frame);
    if (!std.math.isFinite(number) or std.math.isNan(number)) return 0;
    const two32 = 4294967296.0;
    var modulo = @mod(@trunc(number), two32);
    if (modulo < 0) modulo += two32;
    return @intFromFloat(modulo);
}

pub fn toIntegerValueForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const number = try toNumberForAtomics(ctx, output, global, value, caller_function, caller_frame);
    if (std.math.isNan(number) or number == 0) return core.JSValue.int32(0);
    if (!std.math.isFinite(number)) return core.JSValue.float64(number);
    return atomicsNumberResult(@trunc(number));
}

pub fn uint32FromIntegerValueForAtomics(rt: *core.JSRuntime, value: core.JSValue) !u64 {
    _ = rt;
    const number = value_ops.numberValue(value) orelse return 0;
    if (!std.math.isFinite(number) or std.math.isNan(number)) return 0;
    const two32 = 4294967296.0;
    var modulo = @mod(@trunc(number), two32);
    if (modulo < 0) modulo += two32;
    return @intFromFloat(modulo);
}

pub fn toBigIntValueForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = caller_function;
    _ = caller_frame;
    const primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);
    var big = try value_ops.toBigIntValue(ctx.runtime, primitive);
    defer big.deinit();
    return value_ops.createBigIntValue(ctx.runtime, big);
}

pub fn toBigIntBitsForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !u64 {
    const bigint_value = try toBigIntValueForAtomics(ctx, output, global, value, caller_function, caller_frame);
    defer bigint_value.free(ctx.runtime);
    return bigintBitsForAtomics(ctx.runtime, bigint_value);
}

pub fn atomicsNumberResult(value: f64) core.JSValue {
    if (std.math.isFinite(value) and @floor(value) == value and value >= @as(f64, @floatFromInt(std.math.minInt(i32))) and value <= @as(f64, @floatFromInt(std.math.maxInt(i32))) and !std.math.isNegativeZero(value)) {
        return core.JSValue.int32(@intFromFloat(value));
    }
    return core.JSValue.float64(value);
}

pub fn bigintBitsForAtomics(rt: *core.JSRuntime, value: core.JSValue) !u64 {
    var big = try value_ops.toBigIntValue(rt, value);
    defer big.deinit();
    var low: u64 = 0;
    if (big.limbs.len >= 1) low |= big.limbs[0];
    if (big.limbs.len >= 2) low |= @as(u64, big.limbs[1]) << 32;
    return if (big.negative) 0 -% low else low;
}

pub fn isAsciiWhitespace(byte: u8) bool {
    return unicode_lib.isAsciiWhitespaceByte(byte);
}

pub fn isIteratorIdentityFunction(rt: *core.JSRuntime, function_object: *core.Object) bool {
    _ = rt;
    return function_object.isIteratorIdentityFunction();
}

pub fn globalLexicalEnv(ctx: *core.JSContext) !*core.Object {
    if (ctx.lexicals) |env| return env;
    if (ctx.global) |global| {
        if (global.globalLexicals()) |env| {
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
    if (ctx.global) |global| return global.globalLexicals();
    return null;
}

pub fn existingGlobalLexicalEnvForGlobal(ctx: *core.JSContext, global: *core.Object) ?*core.Object {
    if (ctx.lexicals) |env| return env;
    if (global.globalLexicals()) |env| return env;
    if (ctx.global) |context_global| {
        if (context_global != global) return context_global.globalLexicals();
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

pub fn globalLexicalEnvHas(ctx: *core.JSContext, atom_id: core.Atom) bool {
    return globalLexicalHas(ctx, atom_id);
}

pub fn globalLexicalValue(ctx: *core.JSContext, atom_id: core.Atom) ?core.JSValue {
    const env = existingGlobalLexicalEnv(ctx) orelse return null;
    if (env.getOwnDataPropertyValue(atom_id)) |value| return value;
    if (!env.hasOwnProperty(atom_id)) return null;
    return env.getProperty(atom_id);
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

/// Return a fresh ref to the VarRef cell backing a global-object property.
/// This is the non-lexical counterpart to `globalLexicalCell`: declared
/// top-level `var`/function bindings are stored as JS_PROP_VARREF on the
/// global object so closures can alias the property cell directly.
pub fn globalObjectVarRefCell(global: *core.Object, atom_id: core.Atom) ?core.JSValue {
    const index = global.findProperty(atom_id) orelse return null;
    const cell = global.asVarRefAt(index) orelse return null;
    return cell.valueRef().dup();
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

/// Create the JS_PROP_VARREF slot backing a FRESH top-level `var`/function global.
/// An already-existing global property is left entirely untouched (see below): we
/// only materialize a cell when the binding is new, so closures can alias it.
pub fn ensureGlobalObjectVarRefCell(
    ctx: *core.JSContext,
    global: *core.Object,
    atom_id: core.Atom,
    configurable: bool,
) !?core.JSValue {
    const rt = ctx.runtime;
    if (global.findProperty(atom_id)) |initial_index| {
        if (global.propFlagsAt(initial_index).isAccessor()) return null;
        if (global.asVarRefAt(initial_index)) |cell| {
            cell.varRefIsDeletableSlot().* = global.propFlagsAt(initial_index).configurable;
            return cell.valueRef().dup();
        }
        // qjs js_closure_define_global_var (quickjs.c:17171-17205): an EXISTING
        // global property is never rebuilt into a fresh VARREF cell here. qjs
        // hands back a detached uninitialized var_ref and leaves the property's
        // slot AND its observable flags (writable/enumerable/configurable)
        // untouched — a plain `var` redeclaration keeps its descriptor, and a
        // function redeclaration's value+flags are applied afterwards by the
        // ordinary global function-binding define path
        // (slot_ops.defineGlobalFunctionBindingValue). Converting here would
        // clobber the existing descriptor, because a var_ref slot derives its
        // writable from is_const (masking the real flag). Returning null leaves
        // the frame's closure-var slot as its initial detached uninitialized
        // cell, matching qjs's detached-var_ref behaviour and routing access
        // back through the ordinary global-object property path.
        return null;
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

/// qjs js_closure_define_global_var for non-lexical script/eval globals: ensure
/// the global object owns the VARREF property cell and bind every frame view of
/// this declaration to that cell before any function object can capture it.
pub fn defineGlobalDeclVarCell(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    atom_id: core.Atom,
    configurable: bool,
) !bool {
    const cell_value = (try ensureGlobalObjectVarRefCell(ctx, global, atom_id, configurable)) orelse return false;
    defer cell_value.free(ctx.runtime);
    var rebound = false;
    var idx: usize = 0;
    while (idx < function.varRefNamesLen()) : (idx += 1) {
        const name = function.varRefName(idx);
        if (!atomIdOrNameEql(ctx.runtime, name, atom_id)) continue;
        if (!closureVarIsNonLexicalGlobalSentinel(function, idx)) continue;
        if (idx >= frame.var_refs.len) {
            try frame_mod.ensureVarRefsCapacity(ctx, frame, @intCast(idx));
        }
        const old_slot = slot_ops.varRefSlot(frame, idx);
        slot_ops.storeVarRefSlot(frame, idx, cell_value.dup());
        old_slot.free(ctx.runtime);
        rebound = true;
    }
    const local_count = @min(function.vardefs.len, frame.locals.len);
    for (function.vardefs[0..local_count], 0..) |vd, local_idx| {
        if (!atomIdOrNameEql(ctx.runtime, vd.var_name, atom_id)) continue;
        if (!varDefIsEvalHoistedVar(vd)) continue;
        const old_slot = frame.locals[local_idx];
        frame.locals[local_idx] = cell_value.dup();
        old_slot.free(ctx.runtime);
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
    if (!env.hasOwnProperty(atom_id)) return null;
    return env.getProperty(atom_id);
}

pub fn defineGlobalLexicalValue(ctx: *core.JSContext, atom_id: core.Atom, value: core.JSValue, is_const: bool) !void {
    const env = try globalLexicalEnv(ctx);
    if (!env.hasOwnProperty(atom_id)) {
        const rt = ctx.runtime;
        try env.defineOwnPropertyAssumingNew(rt, atom_id, core.Descriptor.data(value, !is_const, false, false));
    }
}

/// qjs js_closure_define_global_var PASS2 for a top-level script let/const:
/// run by the define_var opcode AFTER check_define_var (PASS1) has passed.
/// Creates the single ctx.lexicals VARREF cell and rebinds frame.var_refs[idx]
/// to alias it (replacing the TDZ placeholder initFrameVarRefs reserved), so
/// the frame and the global lexical share one cell. Returns true if the atom is
/// a .global_decl var-ref in this frame (handled here); false otherwise (caller
/// falls back to defineGlobalLexicalValue for module/eval data-property paths).
pub fn defineGlobalDeclLexicalCell(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    atom_id: core.Atom,
    is_const: bool,
) !bool {
    var idx: usize = 0;
    while (idx < function.varRefNamesLen()) : (idx += 1) {
        const name = function.varRefName(idx);
        if (name != atom_id) continue;
        if (!function.varRefIsGlobalDeclAt(idx)) return false;
        const cell_value = try ensureGlobalLexicalCell(ctx, global, atom_id, is_const);
        if (idx >= frame.var_refs.len) {
            try frame_mod.ensureVarRefsCapacity(ctx, frame, @intCast(idx));
        }
        const old_slot = slot_ops.varRefSlot(frame, idx);
        slot_ops.storeVarRefSlot(frame, idx, cell_value);
        old_slot.free(ctx.runtime);
        return true;
    }
    return false;
}

pub fn setGlobalLexicalValue(ctx: *core.JSContext, atom_id: core.Atom, value: core.JSValue) !bool {
    const env = existingGlobalLexicalEnv(ctx) orelse return false;
    if (env.findProperty(atom_id)) |index| {
        // qjs JS_SetPropertyInternal VARREF: write through cell->pvalue,
        // const guarded by cell->is_const. Shared cell => no write loss.
        if (env.asVarRefAt(index)) |cell| {
            if (cell.is_const) return error.TypeError;
            try cell.setVarRefValue(ctx.runtime, value.dup());
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
                old_value.free(rt);
                return true;
            },
            .var_ref => {
                const cell = env.prop_values[index].slot.var_ref;
                if (!cell.varRefValue().isUninitialized()) return false;
                cell.setVarRefValue(rt, value.dup()) catch return false;
                return true;
            },
            .accessor, .auto_init => return false,
        }
    }
    return false;
}

pub fn validateGlobalEvalFunctionDeclarationsFromBytecode(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    ignore_global_lexical: bool,
) !void {
    for (function.closure_var) |cv| {
        if (cv.var_kind != .function_decl and cv.var_kind != .new_function_decl) continue;
        if (!canDeclareGlobalFunction(ctx, global, cv.var_name, ignore_global_lexical)) return error.TypeError;
    }
    for (function.global_vars) |gv| {
        if (gv.cpool_idx < 0) continue;
        if (!canDeclareGlobalFunction(ctx, global, gv.var_name, ignore_global_lexical)) return error.TypeError;
    }
}

pub fn canDeclareGlobalFunction(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom, ignore_global_lexical: bool) bool {
    if (!ignore_global_lexical and globalLexicalHasForGlobal(ctx, global, atom_id)) return false;
    const rt = ctx.runtime;
    const desc = global.getOwnProperty(rt, atom_id) orelse return global.isExtensible();
    defer desc.destroy(rt);
    if (desc.configurable == true) return true;
    if (desc.kind != .data) return false;
    return desc.writable == true and desc.enumerable == true;
}

pub fn classStaticThisAtom(
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) ?core.Atom {
    const function = caller_function orelse return null;
    const frame = caller_frame orelse return null;
    const count = @min(function.vardefs.len, frame.locals.len);
    var idx = count;
    while (idx > 0) {
        idx -= 1;
        const vd = function.vardefs[idx];
        if (vd.var_kind != .class_static_this) continue;
        if (slot_ops.varRefSlotIsUninitialized(frame.locals[idx])) continue;
        return vd.var_name;
    }
    return null;
}

pub fn classStaticThisValue(
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: *frame_mod.Frame,
    atom_id: core.Atom,
) ?core.JSValue {
    const function = caller_function orelse return null;
    const count = @min(function.vardefs.len, caller_frame.locals.len);
    for (function.vardefs[0..count], 0..) |vd, idx| {
        if (vd.var_name != atom_id) continue;
        const value = caller_frame.locals[idx];
        if (slot_ops.varRefSlotIsUninitialized(value)) continue;
        return value;
    }
    return null;
}

test "direct eval private bound names release preserves memory account" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const function_name = try rt.internAtom("privateBoundCaller");
    defer rt.atoms.free(function_name);
    const private_name = try rt.atoms.newSymbol("privateBoundName", .private);
    defer rt.atoms.free(private_name);

    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, function_name);
    defer function.deinit(rt);
    function.private_bound_names = try rt.memory.alloc(core.Atom, 1);
    function.private_bound_names[0] = rt.atoms.dup(private_name);

    const before_bytes = rt.memory.allocated_bytes;
    const before_allocations = rt.memory.allocation_count;
    const names = try eval_ops.directEvalPrivateBoundNames(rt, &function);
    if (names.len != 0) rt.memory.free(core.Atom, names);
    try std.testing.expectEqual(before_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(before_allocations, rt.memory.allocation_count);
}

pub fn directEvalCallerAllowsNewTarget(caller_frame: ?*frame_mod.Frame, eval_in_class_field_initializer: bool) bool {
    if (eval_in_class_field_initializer) return true;
    const outer_frame = caller_frame orelse return false;
    if (outer_frame.current_function.isUndefined()) return false;
    if (functionBytecodeFromValue(outer_frame.current_function)) |fb| return fb.flags.new_target_allowed;
    if (object_ops.objectFromValue(outer_frame.current_function)) |function_object| {
        const stored = function_object.functionBytecodeSlot().* orelse return false;
        const fb = functionBytecodeFromValue(stored) orelse return false;
        return fb.flags.new_target_allowed;
    }
    return false;
}

pub fn directEvalLocalVisibleAtScope(
    function: *const bytecode.Bytecode,
    vd: bytecode.function_bytecode.VarDef,
    eval_scope_index: u16,
) bool {
    if (vd.var_name == core.atom.ids.with_object) {
        return directEvalScopeChainContains(function, eval_scope_index, vd.scope_level);
    }
    if (!vd.is_lexical and vd.var_kind != .catch_) return true;
    return directEvalScopeChainContains(function, eval_scope_index, vd.scope_level);
}

pub fn directEvalScopeChainContains(
    function: *const bytecode.Bytecode,
    eval_scope_index: u16,
    target_scope: i32,
) bool {
    if (target_scope < 0) return false;
    const scope_parents = function.scope_parents;
    if (scope_parents.len == 0) return true;
    var scope_idx: i32 = @intCast(eval_scope_index);
    while (scope_idx >= 0 and @as(usize, @intCast(scope_idx)) < scope_parents.len) {
        if (scope_idx == target_scope) return true;
        scope_idx = scope_parents[@intCast(scope_idx)];
    }
    return false;
}

fn varDefIsEvalHoistedVar(vd: bytecode.function_bytecode.VarDef) bool {
    if (vd.scope_level != 0 or vd.is_lexical) return false;
    return vd.var_kind == .normal or
        vd.var_kind == .function_decl or
        vd.var_kind == .new_function_decl;
}

fn restoreEvalGlobalLexicals(
    ctx: *core.JSContext,
    global: *core.Object,
    saved_lexicals: ?*core.Object,
    keep_active_lexicals: bool,
) !void {
    const active_lexicals = ctx.lexicals;
    try global.setGlobalLexicals(ctx.runtime, active_lexicals);
    ctx.lexicals = if (keep_active_lexicals) active_lexicals else saved_lexicals;
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
    if (use_global_lexicals) ctx.lexicals = eval_global.globalLexicals();

    const EvalResult = @typeInfo(@TypeOf(indirectEval)).@"fn".return_type.?;
    const result: EvalResult = blk: {
        const regexp_literal = simpleEvalRegExpLiteral(ctx, eval_global, source.items) catch |err| break :blk err;
        if (regexp_literal) |value| break :blk value;
        var compiled = parser.compile(ctx.runtime, source.items, .{ .mode = .eval_indirect, .filename = "<eval>", .strict = false }) catch |err| break :blk err;
        defer compiled.deinit();
        if (compiled.syntax_error) |*parse_error| {
            // Compile-error surface: own fileName/lineNumber/columnNumber +
            // leading stack line (build_backtrace filename branch,
            // quickjs.c:7553-7570).
            const parse_filename = ctx.runtime.atoms.name(parse_error.filename) orelse "<eval>";
            _ = error_stack_ops.throwParseSyntaxError(ctx, eval_global, parse_filename, parse_error.position.line, parse_error.position.column, parse_error.message) catch |err| break :blk err;
            break :blk error.SyntaxError;
        }
        if (!compiled.function.flags.is_strict) {
            validateGlobalEvalFunctionDeclarationsFromBytecode(ctx, eval_global, &compiled.function, true) catch |err| break :blk err;
        }
        var nested_stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.runtime.stack_size);
        defer nested_stack.deinit(ctx.runtime);
        break :blk runWithCallEnv(.{
            .ctx = ctx,
            .stack = &nested_stack,
            .function = &compiled.function,
            .initial_this_value = eval_global.value(),
            .output = output,
            .global = eval_global,
            .break_var_ref_cycles_on_exit = true,
            .eval_global_var_bindings = !compiled.function.flags.is_strict,
            .is_eval_code = true,
        }) catch |err| exception_ops.normalizeEvalRuntimeError(err);
    };

    if (use_global_lexicals) {
        var rooted_result = result catch |err| {
            try restoreEvalGlobalLexicals(ctx, eval_global, saved_lexicals, keep_active_lexicals);
            return err;
        };
        errdefer rooted_result.free(ctx.runtime);
        var root_values = [_]core.runtime.ValueRootValue{
            .{ .value = &rooted_result },
        };
        const root_frame = core.runtime.ValueRootFrame{
            .previous = ctx.runtime.active_value_roots,
            .values = &root_values,
        };
        ctx.runtime.active_value_roots = &root_frame;
        defer ctx.runtime.active_value_roots = root_frame.previous;
        try restoreEvalGlobalLexicals(ctx, eval_global, saved_lexicals, keep_active_lexicals);
        return rooted_result;
    }
    return result;
}

pub fn simpleEvalRegExpLiteral(ctx: *core.JSContext, global: *core.Object, source: []const u8) !?core.JSValue {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '/') return null;
    if (trimmed.len >= 2 and (trimmed[1] == '*' or trimmed[1] == '/')) return null;
    const literal = parser.lexer.scanRegExpLiteral(trimmed, 0) catch return null;
    if (literal.end_offset != trimmed.len) return null;
    if (containsUtf8LineSeparator(literal.pattern)) return null;
    // Route the scanned pattern/flags through the RegExp construct record (the
    // validating `.construct` branch) instead of naming `regexp_ops`: the
    // lexer scan does not fully validate the regex grammar, so the construct
    // record's validation is required, matching the retired `constructLiteral`.
    const pattern_value = try value_ops.createStringValue(ctx.runtime, literal.pattern);
    defer pattern_value.free(ctx.runtime);
    const flags_value = try value_ops.createStringValue(ctx.runtime, literal.flags);
    defer flags_value.free(ctx.runtime);
    const regexp_args = [_]core.JSValue{ pattern_value, flags_value };
    const regexp_construct_ref = core.function.NativeBuiltinRef{ .domain = .regexp, .id = regexp_construct_id };
    return try constructBuiltinNativeRecordVm(ctx, null, global, null, regexp_construct_ref, object_ops.constructorPrototypeFromGlobal(ctx.runtime, global, "RegExp"), &regexp_args, null, null);
}

pub fn containsUtf8LineSeparator(bytes: []const u8) bool {
    var index: usize = 0;
    while (index + 2 < bytes.len) : (index += 1) {
        if (bytes[index] == 0xe2 and bytes[index + 1] == 0x80 and
            (bytes[index + 2] == 0xa8 or bytes[index + 2] == 0xa9)) return true;
    }
    return false;
}

pub fn evalSimpleCallerExpression(
    ctx: *core.JSContext,
    source: []const u8,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const frame = caller_frame orelse return null;
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (string_ops.simpleEvalStringLiteral(ctx.runtime, trimmed)) |value| return value;
    if (std.mem.eql(u8, trimmed, "this")) return eval_ops.directEvalThisValue(caller_function, caller_frame).dup();
    if (std.mem.startsWith(u8, trimmed, "delete ")) {
        _ = frame;
        return null;
    }
    if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
        const lhs = std.mem.trim(u8, trimmed[0..eq], " \t\r\n");
        const rhs = std.mem.trim(u8, trimmed[eq + 1 ..], " \t\r\n");
        if (isSimpleIdentifierName(lhs) and isSimpleIntegerLiteral(rhs) and callerFunctionNameEql(ctx.runtime, caller_function, lhs)) {
            if (caller_function) |function| {
                if (function.flags.is_strict) return error.TypeError;
            }
            return core.JSValue.undefinedValue();
        }
    }
    return null;
}

pub fn isSimpleIdentifierName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!unicode_lib.isAsciiIdentifierStartByte(name[0])) return false;
    for (name[1..]) |ch| {
        if (!unicode_lib.isAsciiIdentifierPartByte(ch)) return false;
    }
    return true;
}

pub fn isSimpleIntegerLiteral(text: []const u8) bool {
    _ = std.fmt.parseInt(i32, text, 10) catch return false;
    return true;
}

pub fn callerFunctionNameEql(rt: *core.JSRuntime, caller_function: ?*const bytecode.Bytecode, name: []const u8) bool {
    const function = caller_function orelse return false;
    const function_name = rt.atoms.name(function.name) orelse return false;
    return std.mem.eql(u8, function_name, name);
}

pub fn callerFunctionHasBinding(
    rt: *core.JSRuntime,
    caller_function: ?*const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    name: []const u8,
) bool {
    const function = caller_function orelse return false;
    const local_count = @min(function.vardefs.len, frame.locals.len);
    for (function.vardefs[0..local_count]) |vd| {
        if (value_ops.atomNameEql(rt, vd.var_name, name)) return true;
    }
    const ref_count = @min(function.varRefNamesLen(), frame.var_refs.len);
    var ref_idx: usize = 0;
    while (ref_idx < ref_count) : (ref_idx += 1) {
        const atom_id = function.varRefName(ref_idx);
        if (value_ops.atomNameEql(rt, atom_id, name)) return true;
    }
    return false;
}

pub fn functionHasFrameBinding(
    rt: *core.JSRuntime,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    atom_id: core.Atom,
) bool {
    const local_count = @min(function.vardefs.len, frame.locals.len);
    for (function.vardefs[0..local_count]) |vd| {
        if (vd.var_name == atom_id or atomNamesEqual(rt, vd.var_name, atom_id)) return true;
    }
    const ref_count = @min(function.varRefNamesLen(), frame.var_refs.len);
    var idx: usize = 0;
    while (idx < ref_count) : (idx += 1) {
        const binding = function.varRefName(idx);
        if (slot_ops.varRefSlotIsUninitialized(slot_ops.varRefSlot(frame, idx)) and closureVarIsNonLexicalGlobalSentinel(function, idx)) continue;
        if (binding == atom_id or atomNamesEqual(rt, binding, atom_id)) return true;
    }
    return false;
}

pub fn atomNamesEqual(rt: *core.JSRuntime, a: core.Atom, b: core.Atom) bool {
    const a_name = rt.atoms.name(a) orelse return false;
    const b_name = rt.atoms.name(b) orelse return false;
    return std.mem.eql(u8, a_name, b_name);
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
        _ = self.rt.runObjectCycleRemoval();
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
    try source.defineAutoInitProperty(rt, core.atom.atomFromUInt32(1), "lazyArgsFromArrayLikeValue", 0, core.property.Flags.data(true, true, true));

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
            _ = self.rt.runObjectCycleRemoval();
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

pub fn callFunctionBytecode(
    ctx: *core.JSContext,
    func: core.JSValue,
    current_function_value: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const *core.VarRef,
    output: ?*std.Io.Writer,
    global: *core.Object,
) !core.JSValue {
    return callFunctionBytecodeMode(ctx, func, current_function_value, this_value, args, var_refs, output, global, true);
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
    constructor_this_value: core.JSValue,
) !core.JSValue {
    return callFunctionBytecodeModeState(ctx, func, current_function_value, this_value, args, var_refs, output, global, true, null, null, null, new_target_value, constructor_this_value);
}

pub fn callFunctionBytecodeMode(
    ctx: *core.JSContext,
    func: core.JSValue,
    current_function_value: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const *core.VarRef,
    output: ?*std.Io.Writer,
    global: *core.Object,
    defer_generators: bool,
) !core.JSValue {
    return callFunctionBytecodeModeState(ctx, func, current_function_value, this_value, args, var_refs, output, global, defer_generators, null, null, null, core.JSValue.undefinedValue(), core.JSValue.undefinedValue());
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
    constructor_this_value: core.JSValue,
) HostError!core.JSValue {
    const fb = functionBytecodeFromValue(func) orelse return error.TypeError;
    if (defer_generators and (fb.flags.func_kind == .generator or fb.flags.func_kind == .async_generator)) {
        return object_ops.createGeneratorObject(ctx, func, current_function_value, this_value, args, var_refs, output, global, fb.flags.func_kind == .async_generator);
    }

    var nested_base = bytecode.makeBytecodeView(fb, &ctx.runtime.memory, &ctx.runtime.atoms);
    const nested: *const bytecode.Bytecode = &nested_base;

    var boxed_this: ?core.JSValue = null;
    defer if (boxed_this) |value| value.free(ctx.runtime);
    const fb_runtime_strict = fb.flags.is_strict_mode or fb.flags.runtime_strict_mode;
    const effective_this = try coerceCallThis(ctx, global, fb_runtime_strict, this_value, &boxed_this);
    if (fb.flags.func_kind == .async and generator_state == null) {
        return promise_ops.qjsAsyncFunctionStart(ctx, func, current_function_value, effective_this, args, var_refs, output, global);
    }
    const stop_on_yield = fb.flags.func_kind == .generator or fb.flags.func_kind == .async_generator;

    // Mirror QuickJS JS_CallInternal: non-suspending bytecode frames carve
    // their operand stack from the contiguous per-runtime VM stack arena
    // instead of heap-allocating per call. Generator/async resumption swaps
    // heap buffers in and out of the stack, so those keep heap mode.
    const arena_mark = ctx.runtime.vm_stack.mark();
    defer ctx.runtime.vm_stack.restore(arena_mark);
    const arena_eligible = fb.flags.func_kind == .normal and generator_state == null;
    const operand_window: ?[]core.JSValue = if (arena_eligible)
        ctx.runtime.vm_stack.carve(&ctx.runtime.memory, @as(usize, fb.stack_size) + 1)
    else
        null;
    var nested_stack = if (operand_window) |window|
        stack_mod.Stack.initArenaWindow(&ctx.runtime.memory, ctx.runtime.stack_size, window)
    else
        stack_mod.Stack.init(&ctx.runtime.memory, ctx.runtime.stack_size);
    defer nested_stack.deinit(ctx.runtime);
    // Async-generator bodies return their raw suspension/completion value to
    // the queue machine (exec/async_generator.zig execBody) — no promise
    // wrapping here (qjs async_func_resume returns the raw value/ret code,
    // quickjs.c:20951).
    return runWithCallEnv(.{
        .ctx = ctx,
        .stack = &nested_stack,
        .function = nested,
        .initial_this_value = effective_this,
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
        .constructor_this_value = constructor_this_value,
    });
}

pub fn runGeneratorParameterInit(
    ctx: *core.JSContext,
    fb: *const bytecode.FunctionBytecode,
    object: *core.Object,
    current_function_value: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const *core.VarRef,
    output: ?*std.Io.Writer,
    global: *core.Object,
) !core.JSValue {
    var nested = bytecode.Bytecode.init(&ctx.runtime.memory, &ctx.runtime.atoms, fb.func_name);
    defer nested.deinit(ctx.runtime);
    nested.atoms.replace(&nested.filename, fb.filename);
    nested.line_num = fb.lineNum();
    nested.col_num = fb.colNum();
    nested.arg_count = fb.arg_count;
    nested.var_count = fb.var_count;
    nested.stack_size = fb.stack_size;
    nested.flags.is_strict = fb.flags.is_strict_mode;
    nested.flags.runtime_strict = fb.flags.runtime_strict_mode;
    nested.flags.has_simple_parameter_list = fb.flags.has_simple_parameter_list;
    try nested.setCode(fb.byteCode());
    // Rebuild the nested view's atom-operand retention array by walking the
    // FB's inline atoms (the FB no longer keeps a standalone array).
    var atom_it = fb.atomOperandIterator();
    while (atom_it.next()) |atom_id| {
        try nested.retainAtomOperand(atom_id);
    }
    if (fb.argNames().len > 0) {
        nested.arg_names = try ctx.runtime.memory.alloc(core.Atom, fb.argNames().len);
        for (fb.argNames(), 0..) |atom_id, idx| {
            nested.arg_names[idx] = ctx.runtime.atoms.dup(atom_id);
        }
    }
    if (fb.varDefs().len > 0) {
        nested.vardefs = try ctx.runtime.memory.alloc(bytecode.function_def.VarDef, fb.varDefs().len);
        for (fb.varDefs(), 0..) |v, idx| {
            nested.vardefs[idx] = v;
            nested.vardefs[idx].var_name = ctx.runtime.atoms.dup(v.var_name);
        }
    }
    if (fb.closureVar().len > 0) {
        // The FB no longer keeps a standalone var-ref name array; the var-ref
        // names are `closure_var[i].var_name`. Mirror them here so the nested
        // compile-time Bytecode's var_ref_names matches the view accessors.
        nested.var_ref_names = try ctx.runtime.memory.alloc(core.Atom, fb.closureVar().len);
        for (fb.closureVar(), 0..) |cv, idx| {
            nested.var_ref_names[idx] = ctx.runtime.atoms.dup(cv.var_name);
        }
    }
    if (fb.closureVar().len > 0) {
        nested.closure_var = try ctx.runtime.memory.alloc(bytecode.function_def.ClosureVar, fb.closureVar().len);
        for (fb.closureVar(), 0..) |cv, idx| {
            nested.closure_var[idx] = cv;
            nested.closure_var[idx].var_name = ctx.runtime.atoms.dup(cv.var_name);
        }
    }
    for (fb.cpoolSlice()) |value| {
        _ = try nested.addConstant(value);
    }

    var nested_stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.runtime.stack_size);
    defer nested_stack.deinit(ctx.runtime);
    return runWithCallEnv(.{
        .ctx = ctx,
        .stack = &nested_stack,
        .function = &nested,
        .initial_this_value = this_value,
        .args = args,
        .var_refs = var_refs,
        .output = output,
        .global = global,
        .strict_unresolved_get_var = true,
        .generator_state = object,
        .stop_before_pc = fb.generatorBodyPc(),
        .current_function_value = current_function_value,
    });
}

pub fn qjsGeneratorNext(
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
    if (object.generatorExecuting()) return error.TypeError;
    const generator_global = object_ops.objectRealmGlobal(object) orelse global;
    if (object.generatorDone()) {
        const done_result = try createIteratorResult(ctx.runtime, generator_global, core.JSValue.undefinedValue(), true);
        defer done_result.free(ctx.runtime);
        return done_result.dup();
    }
    if (takeGeneratorPendingReturn(object)) |pending| {
        // Suspended at a yield inside a finally block entered via .return(v): finish
        // the finally range, then complete with the pending return value (qjs
        // js_generator_next GEN_MAGIC_RETURN, quickjs.c:21077).
        const step = try resumeGeneratorPendingReturnStep(ctx, output, generator_global, receiver, object, pending, args);
        if (!step.done and (object.generatorYieldStarIterator() != null or generatorYieldStarSuspended(ctx.runtime, object))) {
            return step.value;
        }
        defer step.value.free(ctx.runtime);
        return try createIteratorResult(ctx.runtime, generator_global, step.value, step.done);
    }
    const function_value = object.functionBytecodeSlot().* orelse return error.TypeError;
    const stored_current_function = if (object.generatorCurrentFunction()) |value| value.dup() else null;
    defer if (stored_current_function) |value| value.free(ctx.runtime);
    const current_function_value = stored_current_function orelse receiver;
    const resume_value = if (object.generatorPc() != 0 and args.len > 0) args[0] else core.JSValue.undefinedValue();
    object.generatorExecutingSlot().* = true;
    defer object.generatorExecutingSlot().* = false;
    const result = callFunctionBytecodeModeState(
        ctx,
        function_value,
        current_function_value,
        object.generatorThis() orelse core.JSValue.undefinedValue(),
        object.generatorArgs(),
        object.functionCapturesSlot().*,
        output,
        generator_global,
        false,
        object,
        resume_value,
        null,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    ) catch |err| {
        object.generatorDoneSlot().* = true;
        return err;
    };
    defer result.free(ctx.runtime);
    if (object.generatorJustYielded() and
        (object.generatorYieldStarIterator() != null or generatorYieldStarSuspended(ctx.runtime, object)))
    {
        return result.dup();
    }
    return try createIteratorResult(ctx.runtime, generator_global, result, !object.generatorJustYielded());
}

/// A raw generator step result: the yielded/returned value + done flag, with no
/// `{value, done}` iterator-result object built. The caller owns `value`.
pub const GeneratorValueDone = struct {
    value: core.JSValue,
    done: bool,
};

/// Resume a SYNC generator one step and return (value, done) WITHOUT allocating the
/// iterator-result object, so a for-of consumer can skip it (qjs JS_IteratorNext2
/// built-in fast path, quickjs.c:16548). Returns null if `receiver` is not a sync
/// generator (caller falls back to the generic protocol). This is a parallel impl of
/// `qjsGeneratorNext`'s sync path — kept separate so the hot, widely-used qjsGeneratorNext
/// (.next() / spread / destructuring / yield*) stays byte-for-byte untouched; BOTH paths
/// are exercised by the test262 generator suite, so any divergence is caught. The
/// yield*-delegation case (result is ALREADY an iterator-result object) is unwrapped here
/// with the same done-then-conditional-value reads the generic for-of would do.
pub fn qjsSyncGeneratorStep(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
) !?GeneratorValueDone {
    if (!receiver.isObject()) return null;
    const object = property_ops.expectObject(receiver) catch return null;
    if (object.class_id != core.class.ids.generator) return null; // sync generators only
    if (object.generatorExecuting()) return error.TypeError;
    const generator_global = object_ops.objectRealmGlobal(object) orelse global;
    if (object.generatorDone()) return .{ .value = core.JSValue.undefinedValue(), .done = true };
    // Pending return completion stashed by .return(v) suspended in a finally block:
    // fall back to the generic protocol, whose .next() call lands in qjsGeneratorNext
    // and threads the completion through the finally.
    if (object.generatorResumeCompletionType() == 1) return null;
    const function_value = object.functionBytecodeSlot().* orelse return error.TypeError;
    const stored_current_function = if (object.generatorCurrentFunction()) |value| value.dup() else null;
    defer if (stored_current_function) |value| value.free(ctx.runtime);
    const current_function_value = stored_current_function orelse receiver;
    const resume_value = if (object.generatorPc() != 0 and args.len > 0) args[0] else core.JSValue.undefinedValue();
    object.generatorExecutingSlot().* = true;
    defer object.generatorExecutingSlot().* = false;
    const result = callFunctionBytecodeModeState(
        ctx,
        function_value,
        current_function_value,
        object.generatorThis() orelse core.JSValue.undefinedValue(),
        object.generatorArgs(),
        object.functionCapturesSlot().*,
        output,
        generator_global,
        false,
        object,
        resume_value,
        null,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    ) catch |err| {
        object.generatorDoneSlot().* = true;
        return err;
    };
    if (object.generatorJustYielded() and
        (object.generatorYieldStarIterator() != null or generatorYieldStarSuspended(ctx.runtime, object)))
    {
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
    return .{ .value = result, .done = !object.generatorJustYielded() };
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
    const function_value = object.functionBytecodeSlot().* orelse return error.TypeError;
    try setGeneratorResumeCompletionType(ctx.runtime, object, completion_type);
    object.generatorExecutingSlot().* = true;
    defer object.generatorExecutingSlot().* = false;
    const result = callFunctionBytecodeModeState(
        ctx,
        function_value,
        receiver,
        object.generatorThis() orelse core.JSValue.undefinedValue(),
        object.generatorArgs(),
        object.functionCapturesSlot().*,
        output,
        global,
        false,
        object,
        resume_value,
        null,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    ) catch |err| {
        object.generatorDoneSlot().* = true;
        return err;
    };
    defer result.free(ctx.runtime);
    const done = !object.generatorJustYielded();
    if (done) object.generatorDoneSlot().* = true;
    if (object.generatorJustYielded() and generatorYieldStarSuspended(ctx.runtime, object)) return result.dup();
    return try createIteratorResult(ctx.runtime, global, result, done);
}

/// Pending return completion stash. When `.return(v)` enters a finally block and the
/// finally itself yields, the pending return completion must survive the suspension so
/// the following `.next()` can complete `{value: v, done: true}`. Mirror qjs
/// js_generator_next GEN_MAGIC_RETURN (quickjs.c:21109: `sf->cur_sp[-1] = ret;
/// sf->cur_sp[0] = JS_NewInt32(ctx, magic)` — the completion value and its magic live
/// on the generator's own saved stack): the value plus an int32 stop-pc marker are
/// pushed onto the generator's saved operand stack (GC-traced and freed with the
/// generator payload) and `resume_completion_type` is set to 1 = GEN_MAGIC_RETURN.
/// Every resume entry point must consume the stash first (`takeGeneratorPendingReturn`)
/// so the saved stack regains the exact shape the suspended bytecode expects.
pub fn stashGeneratorPendingReturn(
    rt: *core.JSRuntime,
    generator: *core.Object,
    pending_value: core.JSValue,
    stop_pc: usize,
) !void {
    const values = generator.generatorStack();
    const capacity = generator.generatorStackCapacity();
    if (values.len + 2 > capacity) {
        var next_capacity: usize = if (capacity == 0) 8 else capacity;
        while (next_capacity < values.len + 2) next_capacity *= 2;
        const next = try rt.memory.alloc(core.JSValue, next_capacity);
        @memcpy(next[0..values.len], values);
        generator.generatorStackSlot().* = next[0..values.len];
        generator.generatorStackCapacitySlot().* = next_capacity;
        if (capacity != 0) {
            rt.memory.free(core.JSValue, values.ptr[0..capacity]);
        } else if (values.len != 0) {
            rt.memory.free(core.JSValue, values);
        }
    }
    const stack = generator.generatorStack();
    stack.ptr[stack.len] = pending_value.dup();
    stack.ptr[stack.len + 1] = core.JSValue.int32(@intCast(stop_pc));
    generator.generatorStackSlot().* = stack.ptr[0 .. stack.len + 2];
    generator.generatorResumeCompletionTypeSlot().* = 1; // GEN_MAGIC_RETURN
}

pub const GeneratorPendingReturn = struct {
    /// Owned by the caller.
    value: core.JSValue,
    stop_pc: usize,
};

/// Pop the pending return completion stashed by `stashGeneratorPendingReturn`, if any.
/// Outside an active resume, `resume_completion_type == 1` only ever means a stashed
/// pending return (the transient yield-star magic is consumed within the same resume,
/// guarded by the executing flag).
pub fn takeGeneratorPendingReturn(generator: *core.Object) ?GeneratorPendingReturn {
    if (generator.generatorResumeCompletionType() != 1) return null;
    generator.generatorResumeCompletionTypeSlot().* = 0;
    const values = generator.generatorStack();
    std.debug.assert(values.len >= 2);
    const marker = values[values.len - 1];
    const value = values[values.len - 2];
    generator.generatorStackSlot().* = values.ptr[0 .. values.len - 2];
    return .{ .value = value, .stop_pc = @intCast(marker.asInt32() orelse 0) };
}

/// Resume a generator suspended at a yield INSIDE a finally block that was entered via
/// `.return(v)`: run the rest of the finally range and complete with the pending return
/// value once the range finishes (qjs threads this natively through OP_return / OP_ret
/// with the completion on the generator stack, js_generator_next quickjs.c:21077).
/// Takes ownership of `pending.value`; the returned value is owned by the caller.
fn resumeGeneratorPendingReturnStep(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    generator_global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    pending: GeneratorPendingReturn,
    args: []const core.JSValue,
) !GeneratorValueDone {
    const pending_value = pending.value;
    defer pending_value.free(ctx.runtime);
    const function_value = object.functionBytecodeSlot().* orelse return error.TypeError;
    const stored_current_function = if (object.generatorCurrentFunction()) |value| value.dup() else null;
    defer if (stored_current_function) |value| value.free(ctx.runtime);
    const current_function_value = stored_current_function orelse receiver;
    const resume_value = if (args.len > 0) args[0] else core.JSValue.undefinedValue();
    object.generatorExecutingSlot().* = true;
    defer object.generatorExecutingSlot().* = false;
    const result = callFunctionBytecodeModeState(
        ctx,
        function_value,
        current_function_value,
        object.generatorThis() orelse core.JSValue.undefinedValue(),
        object.generatorArgs(),
        object.functionCapturesSlot().*,
        output,
        generator_global,
        false,
        object,
        resume_value,
        pending.stop_pc,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    ) catch |err| {
        object.generatorDoneSlot().* = true;
        return err;
    };
    defer result.free(ctx.runtime);
    if (object.generatorJustYielded()) {
        // Suspended again inside the finally (plain yield or yield* delegation):
        // keep the pending return completion stashed. This is safe because every
        // resume entry point pops the stash before restoring the saved stack.
        try stashGeneratorPendingReturn(ctx.runtime, object, pending_value, pending.stop_pc);
        return .{ .value = result.dup(), .done = false };
    }
    object.generatorDoneSlot().* = true;
    const value = if (result.isUndefined()) pending_value.dup() else result.dup();
    return .{ .value = value, .done = true };
}

pub fn qjsGeneratorReturn(
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
        // enqueue and return the request promise; the argument is awaited by
        // the queue machine before the finally range runs / the request settles.
        return try async_generator.asyncGeneratorEnqueue(ctx, output, global, object, args, 1);
    }
    if (object.generatorExecuting()) return error.TypeError;
    const generator_global = object_ops.objectRealmGlobal(object) orelse global;
    // A fresh .return(v) replaces any pending return completion stashed by an earlier
    // return that suspended inside a finally block (qjs: the new completion resumes at
    // the yield and the old stack slots unwind with the frame).
    if (takeGeneratorPendingReturn(object)) |pending| pending.value.free(ctx.runtime);
    try closeGeneratorDestructuringIterators(ctx, output, generator_global, object);
    var return_value = if (args.len > 0) args[0].dup() else core.JSValue.undefinedValue();
    defer return_value.free(ctx.runtime);
    if (generatorYieldStarSuspended(ctx.runtime, object)) {
        return try resumeGeneratorYieldStarCompletion(ctx, output, generator_global, receiver, object, return_value, 1);
    }
    if (object.generatorYieldStarIterator() != null) {
        const step = qjsGeneratorYieldStarReturnStep(ctx, output, generator_global, object, return_value) catch |err| {
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
    if (object.generatorPc() != 0) {
        const function_value = object.functionBytecodeSlot().* orelse return error.TypeError;
        const fb = functionBytecodeFromValue(function_value) orelse return error.TypeError;
        if (findGeneratorReturnFinallyTarget(fb, @intCast(object.generatorPc()))) |finally_range| {
            object.generatorPcSlot().* = finally_range.start;
            object.generatorJustYieldedSlot().* = false;
            const result = callFunctionBytecodeModeState(
                ctx,
                function_value,
                receiver,
                object.generatorThis() orelse core.JSValue.undefinedValue(),
                object.generatorArgs(),
                object.functionCapturesSlot().*,
                output,
                generator_global,
                false,
                object,
                core.JSValue.undefinedValue(),
                finally_range.stop,
                core.JSValue.undefinedValue(),
                core.JSValue.undefinedValue(),
            ) catch |err| {
                object.generatorDoneSlot().* = true;
                return err;
            };
            defer result.free(ctx.runtime);
            const done = !object.generatorJustYielded();
            if (done) object.generatorDoneSlot().* = true;
            if (!done) {
                // The finally block itself yielded: preserve the pending return
                // completion across the suspension (qjs js_generator_next
                // GEN_MAGIC_RETURN, quickjs.c:21109).
                try stashGeneratorPendingReturn(ctx.runtime, object, return_value, finally_range.stop);
                if (object.generatorYieldStarIterator() != null or generatorYieldStarSuspended(ctx.runtime, object)) {
                    // yield* passthrough: `result` is already an iterator-result object.
                    return result.dup();
                }
            }
            const iterator_value = if (done and result.isUndefined()) return_value else result;
            return try createIteratorResult(ctx.runtime, generator_global, iterator_value, done);
        }
    }
    object.generatorDoneSlot().* = true;
    return try createIteratorResult(ctx.runtime, generator_global, return_value, true);
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
    const function_value = object.functionBytecodeSlot().* orelse return null;
    const fb = functionBytecodeFromValue(function_value) orelse return null;
    const catch_target = findEnclosingCatchTarget(fb, @intCast(object.generatorPc())) orelse return null;
    const thrown = try exception_ops.runtimeErrorValueForGeneratorCatch(ctx, global, err);
    defer thrown.free(ctx.runtime);
    object.generatorPcSlot().* = catch_target;
    object.generatorJustYieldedSlot().* = false;
    const result = callFunctionBytecodeModeState(
        ctx,
        function_value,
        receiver,
        object.generatorThis() orelse core.JSValue.undefinedValue(),
        object.generatorArgs(),
        object.functionCapturesSlot().*,
        output,
        global,
        false,
        object,
        thrown,
        null,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    ) catch |resume_err| {
        object.generatorDoneSlot().* = true;
        return resume_err;
    };
    defer result.free(ctx.runtime);
    const done = !object.generatorJustYielded();
    if (done) object.generatorDoneSlot().* = true;
    const result_value = generatorCatchResumeResultValue(result);
    return try createIteratorResult(ctx.runtime, global, result_value, done);
}

pub const GeneratorYieldStarReturnStep = union(enum) {
    yield_result: core.JSValue,
    complete: core.JSValue,
};

pub const GeneratorYieldStarThrowStep = union(enum) {
    yield_result: core.JSValue,
    complete: core.JSValue,
};

pub fn qjsGeneratorYieldStarReturnStep(
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
        generator.clearOptionalValueSlot(ctx.runtime, generator.generatorYieldStarIteratorSlot());
        return .{ .complete = return_arg.dup() };
    }
    if (!isCallableValue(return_method)) return error.TypeError;

    const result_value = try callValueOrBytecode(ctx, output, global, iterator_value, return_method, &.{return_arg}, null, null);
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
    generator.clearOptionalValueSlot(ctx.runtime, generator.generatorYieldStarIteratorSlot());
    return .{ .complete = value };
}

pub fn qjsGeneratorYieldStarThrowStep(
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
        try qjsGeneratorYieldStarCloseForMissingThrow(ctx, output, global, iterator_value);
        generator.clearOptionalValueSlot(ctx.runtime, generator.generatorYieldStarIteratorSlot());
        return error.TypeError;
    }
    if (!isCallableValue(throw_method)) return error.TypeError;

    const result_value = try callValueOrBytecode(ctx, output, global, iterator_value, throw_method, &.{thrown}, null, null);
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
    generator.clearOptionalValueSlot(ctx.runtime, generator.generatorYieldStarIteratorSlot());
    return .{ .complete = value };
}

pub fn qjsGeneratorYieldStarCloseForMissingThrow(
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
    const result = try callValueOrBytecode(ctx, output, global, iterator_value, return_method, &.{}, null, null);
    defer result.free(ctx.runtime);
    _ = property_ops.expectObject(result) catch return error.TypeError;
}

pub fn qjsGeneratorYieldStarReturn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    generator: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    const return_arg = if (args.len > 0) args[0] else core.JSValue.undefinedValue();
    const step = try qjsGeneratorYieldStarReturnStep(ctx, output, global, generator, return_arg);
    switch (step) {
        .yield_result => |result| return result,
        .complete => |value| {
            defer value.free(ctx.runtime);
            generator.generatorDoneSlot().* = true;
            return try createIteratorResult(ctx.runtime, global, value, true);
        },
    }
}

pub fn qjsGeneratorThrow(
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
    if (object.generatorExecuting()) return error.TypeError;
    const generator_global = object_ops.objectRealmGlobal(object) orelse global;
    const thrown = if (args.len > 0) args[0] else core.JSValue.undefinedValue();
    // A throw injected at a yield inside a finally block discards any pending return
    // completion stashed there (qjs: the exception unwinds the frame and the stacked
    // completion slots are freed with it).
    if (takeGeneratorPendingReturn(object)) |pending| pending.value.free(ctx.runtime);

    if (generatorYieldStarSuspended(ctx.runtime, object)) {
        return try resumeGeneratorYieldStarCompletion(ctx, output, generator_global, receiver, object, thrown, 2);
    }

    if (object.generatorYieldStarIterator() != null) {
        const step = qjsGeneratorYieldStarThrowStep(ctx, output, generator_global, object, thrown) catch |err| {
            if (try resumeGeneratorCatchForRuntimeError(ctx, output, generator_global, receiver, object, err)) |handled| return handled;
            object.generatorDoneSlot().* = true;
            return err;
        };
        switch (step) {
            .yield_result => |result| return result,
            .complete => |value| {
                defer value.free(ctx.runtime);
                const function_value = object.functionBytecodeSlot().* orelse return error.TypeError;
                const fb = functionBytecodeFromValue(function_value) orelse return error.TypeError;
                object.generatorPcSlot().* = generatorPcAfterYieldStar(fb, object.generatorPc()) orelse return error.InvalidBytecode;
                object.generatorJustYieldedSlot().* = false;
                const result = callFunctionBytecodeModeState(
                    ctx,
                    function_value,
                    receiver,
                    object.generatorThis() orelse core.JSValue.undefinedValue(),
                    object.generatorArgs(),
                    object.functionCapturesSlot().*,
                    output,
                    generator_global,
                    false,
                    object,
                    value,
                    null,
                    core.JSValue.undefinedValue(),
                    core.JSValue.undefinedValue(),
                ) catch |err| {
                    object.generatorDoneSlot().* = true;
                    return err;
                };
                defer result.free(ctx.runtime);
                const done = !object.generatorJustYielded();
                if (done) object.generatorDoneSlot().* = true;
                return try createIteratorResult(ctx.runtime, generator_global, result, done);
            },
        }
    }

    if (object.generatorPc() != 0 and object.generatorStarted()) {
        const function_value = object.functionBytecodeSlot().* orelse return error.TypeError;
        const fb = functionBytecodeFromValue(function_value) orelse return error.TypeError;
        if (findEnclosingCatchTarget(fb, @intCast(object.generatorPc()))) |catch_target| {
            object.generatorPcSlot().* = catch_target;
            object.generatorJustYieldedSlot().* = false;
            const result = callFunctionBytecodeModeState(
                ctx,
                function_value,
                receiver,
                object.generatorThis() orelse core.JSValue.undefinedValue(),
                object.generatorArgs(),
                object.functionCapturesSlot().*,
                output,
                generator_global,
                false,
                object,
                thrown,
                null,
                core.JSValue.undefinedValue(),
                core.JSValue.undefinedValue(),
            ) catch |err| {
                object.generatorDoneSlot().* = true;
                return err;
            };
            defer result.free(ctx.runtime);
            const done = !object.generatorJustYielded();
            if (done) object.generatorDoneSlot().* = true;
            const result_value = generatorCatchResumeResultValue(result);
            return try createIteratorResult(ctx.runtime, generator_global, result_value, done);
        }
    }

    object.generatorDoneSlot().* = true;
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

pub const GeneratorReturnFinallyRange = struct {
    start: usize,
    stop: usize,
};

pub fn findGeneratorReturnFinallyTarget(fb: *const bytecode.FunctionBytecode, start_pc: u32) ?GeneratorReturnFinallyRange {
    var pc: usize = 0;
    var found: ?GeneratorReturnFinallyRange = null;
    while (pc < start_pc and pc < fb.byteCode().len) {
        const op_id = fb.byteCode()[pc];
        if (op_id == op.@"catch") {
            if (pc + 5 > fb.byteCode().len) return found;
            const operand_pc = pc + 1;
            const diff = readInt(i32, fb.byteCode()[operand_pc..][0..4]);
            const target = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            if (target > start_pc and target <= fb.byteCode().len) {
                if (findGeneratorReturnFinallyTargetFromCatch(fb, @intCast(target))) |candidate| {
                    if (found == null or candidate.stop > found.?.stop) {
                        found = candidate;
                    }
                }
            }
        }
        const size = bytecode.opcode.sizeOf(op_id);
        if (size == 0) return found;
        pc += size;
    }
    return found;
}

pub fn findGeneratorReturnFinallyTargetFromCatch(fb: *const bytecode.FunctionBytecode, catch_target: usize) ?GeneratorReturnFinallyRange {
    const rethrow_pc = findThrowFrom(fb, catch_target) orelse return null;
    if (rethrow_pc <= catch_target) return null;
    if (findForwardGotoTargetInRange(fb, catch_target, rethrow_pc)) |normal_finally_target| {
        if (normal_finally_target > rethrow_pc) {
            return .{ .start = normal_finally_target, .stop = fb.byteCode().len };
        }
    }
    return .{ .start = catch_target, .stop = rethrow_pc };
}

pub fn findForwardGotoTargetInRange(fb: *const bytecode.FunctionBytecode, start_pc: usize, end_pc: usize) ?usize {
    var pc = start_pc;
    var found: ?usize = null;
    while (pc < end_pc and pc < fb.byteCode().len) {
        const op_id = fb.byteCode()[pc];
        if (forwardGotoTarget(fb, pc)) |target| {
            if (target > pc and target <= fb.byteCode().len) found = @intCast(target);
        }
        const size = bytecode.opcode.sizeOf(op_id);
        if (size == 0) return found;
        pc += size;
    }
    return found;
}

pub fn findEnclosingCatchTarget(fb: *const bytecode.FunctionBytecode, start_pc: u32) ?usize {
    var pc: usize = 0;
    var found: ?usize = null;
    while (pc < start_pc and pc < fb.byteCode().len) {
        const op_id = fb.byteCode()[pc];
        if (op_id == op.@"catch") {
            if (pc + 5 > fb.byteCode().len) return found;
            const operand_pc = pc + 1;
            const diff = readInt(i32, fb.byteCode()[operand_pc..][0..4]);
            const target = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            if (target > start_pc and target <= fb.byteCode().len) found = @intCast(target);
        }
        const size = bytecode.opcode.sizeOf(op_id);
        if (size == 0) return null;
        pc += size;
    }
    return found;
}

pub fn findThrowFrom(fb: *const bytecode.FunctionBytecode, start_pc: usize) ?usize {
    var pc = start_pc;
    while (pc < fb.byteCode().len) {
        const op_id = fb.byteCode()[pc];
        if (op_id == op.throw) return pc;
        const size = bytecode.opcode.sizeOf(op_id);
        if (size == 0) return null;
        pc += size;
    }
    return null;
}

pub fn forwardGotoTarget(fb: *const bytecode.FunctionBytecode, pc: usize) ?u32 {
    const op_id = fb.byteCode()[pc];
    return switch (op_id) {
        op.goto8 => blk: {
            if (pc + 1 >= fb.byteCode().len) break :blk null;
            const operand_pc = pc + 1;
            const diff: i8 = @bitCast(fb.byteCode()[operand_pc]);
            const target = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            break :blk if (target > @as(i64, @intCast(pc)) and target <= @as(i64, @intCast(fb.byteCode().len))) @as(u32, @intCast(target)) else null;
        },
        op.goto16 => blk: {
            if (pc + 3 > fb.byteCode().len) break :blk null;
            const operand_pc = pc + 1;
            const diff = readInt(i16, fb.byteCode()[operand_pc..][0..2]);
            const target = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            break :blk if (target > @as(i64, @intCast(pc)) and target <= @as(i64, @intCast(fb.byteCode().len))) @as(u32, @intCast(target)) else null;
        },
        op.goto => blk: {
            if (pc + 5 > fb.byteCode().len) break :blk null;
            const operand_pc = pc + 1;
            const diff = readInt(i32, fb.byteCode()[operand_pc..][0..4]);
            const target = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            break :blk if (target > @as(i64, @intCast(pc)) and target <= @as(i64, @intCast(fb.byteCode().len))) @as(u32, @intCast(target)) else null;
        },
        else => null,
    };
}

pub fn closeGeneratorDestructuringIterators(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    generator: *core.Object,
) !void {
    try closeDestructuringIteratorsInValues(ctx, output, global, generator.generatorStack());
    try closeDestructuringIteratorsInValues(ctx, output, global, generator.generatorFrameLocals());
    try closeDestructuringIteratorsInValues(ctx, output, global, generator.generatorFrameArgs());
    // frame_var_refs: every element is a VarRef cell (typed slots), never a
    // destructuring-iterator-state Object — the pre-typed scan over the slots
    // was a provable no-op (expectObject rejects the var_ref GC kind), so the
    // typed slice is simply skipped.
}

pub fn closeDestructuringIteratorsInValues(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    values: []const core.JSValue,
) !void {
    for (values) |value| {
        const object = property_ops.expectObject(value) catch continue;
        if (!isDestructuringIteratorState(object)) continue;
        if (destructuringIteratorStateClosing(object)) continue;
        const close_arg = value.dup();
        defer close_arg.free(ctx.runtime);
        const close_result = try qjsDestructuringClose(ctx, output, global, &.{close_arg});
        close_result.free(ctx.runtime);
    }
}

pub fn closeDestructuringIteratorsInValuesForAbruptCompletion(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    values: []const core.JSValue,
) void {
    for (values) |value| {
        const object = property_ops.expectObject(value) catch continue;
        if (!isDestructuringIteratorState(object)) continue;
        if (destructuringIteratorStateClosing(object)) continue;
        const close_arg = value.dup();
        defer close_arg.free(ctx.runtime);
        const pending_exception = if (ctx.hasException()) ctx.takeException() else null;
        defer if (pending_exception) |pending| pending.free(ctx.runtime);
        const close_result = qjsDestructuringClose(ctx, output, global, &.{close_arg}) catch {
            if (ctx.hasException()) ctx.clearException();
            if (pending_exception) |pending| _ = ctx.throwValue(pending.dup());
            clearDestructuringIteratorState(ctx.runtime, object) catch {};
            continue;
        };
        close_result.free(ctx.runtime);
        if (ctx.hasException()) ctx.clearException();
        if (pending_exception) |pending| _ = ctx.throwValue(pending.dup());
    }
}

pub fn closeFrameDestructuringIteratorsForAbruptCompletion(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *const stack_mod.Stack,
    frame: *const frame_mod.Frame,
) void {
    closeDestructuringIteratorsInValuesForAbruptCompletion(ctx, output, global, stack.values);
    closeDestructuringIteratorsInValuesForAbruptCompletion(ctx, output, global, frame.locals);
    closeDestructuringIteratorsInValuesForAbruptCompletion(ctx, output, global, frame.args);
    // frame.var_refs: typed cell slots are never iterator-state Objects (the
    // pre-typed slot scan was a provable no-op) — skipped.
}

pub fn qjsIteratorCallForNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    switch (id) {
        @intFromEnum(method_ids.iterator.AccessorMethod.constructor_getter),
        @intFromEnum(method_ids.iterator.AccessorMethod.constructor_setter),
        @intFromEnum(method_ids.iterator.AccessorMethod.to_string_tag_getter),
        @intFromEnum(method_ids.iterator.AccessorMethod.to_string_tag_setter),
        => return @as(?core.JSValue, try object_ops.qjsIteratorPrototypeAccessor(ctx, global, receiver, args, id)),
        else => {},
    }
    if (try qjsIteratorStaticCall(ctx, output, global, args, id, caller_function, caller_frame)) |value| return value;
    return object_ops.qjsIteratorPrototypeMethodCall(ctx, output, global, receiver, args, id, caller_function, caller_frame);
}

pub fn qjsIteratorStaticCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    method_id: u32,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return switch (method_id) {
        @intFromEnum(method_ids.iterator.StaticMethod.from) => try qjsIteratorFromCall(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.StaticMethod.concat) => try string_ops.qjsIteratorConcatCall(ctx, output, global, args),
        @intFromEnum(method_ids.iterator.StaticMethod.zip) => try qjsIteratorZipCall(ctx, output, global, args, false, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.StaticMethod.zip_keyed) => try qjsIteratorZipCall(ctx, output, global, args, true, caller_function, caller_frame),
        else => null,
    };
}

pub fn qjsIteratorFromCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return iter_vm.qjsIteratorFromCall(
        ctx,
        output,
        global,
        args,
        caller_function,
        caller_frame,
    );
}

pub fn qjsIteratorZipCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    keyed: bool,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return iter_vm.qjsIteratorZipCall(
        ctx,
        output,
        global,
        args,
        keyed,
        caller_function,
        caller_frame,
    );
}

pub fn qjsIteratorZipModeFromOptions(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    options: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !iter_vm.IteratorZipMode {
    return iter_vm.qjsIteratorZipModeFromOptions(ctx, output, global, options, caller_function, caller_frame);
}

pub fn qjsIteratorZipCollectIndexed(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterables_iterator: core.JSValue,
    iterables_next: core.JSValue,
    iters: *core.Object,
    nexts: *core.Object,
    pads: *core.Object,
    padding: core.JSValue,
    mode: iter_vm.IteratorZipMode,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    return iter_vm.qjsIteratorZipCollectIndexed(
        ctx,
        output,
        global,
        iterables_iterator,
        iterables_next,
        iters,
        nexts,
        pads,
        padding,
        mode,
        caller_function,
        caller_frame,
    );
}

pub fn qjsIteratorZipCollectKeyed(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterables: *core.Object,
    iters: *core.Object,
    nexts: *core.Object,
    pads: *core.Object,
    keys: *core.Object,
    padding: core.JSValue,
    mode: iter_vm.IteratorZipMode,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    return iter_vm.qjsIteratorZipCollectKeyed(
        ctx,
        output,
        global,
        iterables,
        iters,
        nexts,
        pads,
        keys,
        padding,
        mode,
        caller_function,
        caller_frame,
    );
}

pub fn qjsIteratorZipNextMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return iter_vm.qjsIteratorZipNextMethod(
        ctx,
        output,
        global,
        iterator_value,
        caller_function,
        caller_frame,
    );
}

pub fn qjsIteratorZipCreateHelper(
    rt: *core.JSRuntime,
    global: *core.Object,
    iters: *core.Object,
    nexts: *core.Object,
    pads: *core.Object,
    keys: ?*core.Object,
    count: usize,
    mode: iter_vm.IteratorZipMode,
    keyed: bool,
) !core.JSValue {
    return iter_vm.qjsIteratorZipCreateHelper(rt, global, iters, nexts, pads, keys, count, mode, keyed);
}

pub fn qjsIteratorZipStoreIndex(rt: *core.JSRuntime, object: *core.Object, index: usize, value: core.JSValue) !void {
    try iter_vm.qjsIteratorZipStoreIndex(rt, object, index, value);
}

pub fn qjsIteratorZipGetIndex(object: *core.Object, index: usize) core.JSValue {
    return iter_vm.qjsIteratorZipGetIndex(object, index);
}

pub fn qjsIteratorZipSetIndex(rt: *core.JSRuntime, object: *core.Object, index: usize, value: core.JSValue) !void {
    try iter_vm.qjsIteratorZipSetIndex(rt, object, index, value);
}

pub fn qjsIteratorZipCloseWithCompletion(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    completion: *iter_vm.IteratorZipCompletion,
    iterator_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) void {
    iter_vm.qjsIteratorZipCloseWithCompletion(ctx, output, global, completion, iterator_value, caller_function, caller_frame);
}

pub fn qjsIteratorZipCloseAllWithCompletion(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    completion: *iter_vm.IteratorZipCompletion,
    iters: *core.Object,
    count: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    try iter_vm.qjsIteratorZipCloseAllWithCompletion(ctx, output, global, completion, iters, count, caller_function, caller_frame);
}

pub fn qjsIteratorZipClose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    try iter_vm.qjsIteratorZipClose(ctx, output, global, iterator_value, caller_function, caller_frame);
}

pub fn iteratorCloseWithCompletionAndPropagate(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    err: anytype,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError {
    var completion = iter_vm.IteratorZipCompletion.initThrow(ctx, err);
    defer completion.deinit(ctx.runtime);
    qjsIteratorZipCloseWithCompletion(ctx, output, global, &completion, iterator_value, caller_function, caller_frame);
    completion.restore(ctx);
    return completion.err orelse err;
}

pub fn qjsIteratorZipCloseAllAndPropagate(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iters: *core.Object,
    count: usize,
    err: anytype,
    extra_iterator: ?core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError {
    return iter_vm.qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, extra_iterator, caller_function, caller_frame);
}

pub fn iteratorFromSourceForIteratorFrom(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !iter_vm.IteratorFromResult {
    if (source.isString()) {
        const iterator_method = try getIteratorMethod(ctx, output, global, source);
        defer iterator_method.free(ctx.runtime);
        const iterator = try callValueOrBytecode(ctx, output, global, source, iterator_method, &.{}, caller_function, caller_frame);
        errdefer iterator.free(ctx.runtime);
        return .{ .iterator = iterator };
    }

    const source_object = object_ops.objectFromValue(source) orelse return error.TypeError;
    if (object_ops.iteratorIsOnIteratorPrototypeChain(ctx.runtime, global, source)) {
        return .{ .iterator = source.dup() };
    }

    const iterator_method = try getIteratorMethod(ctx, output, global, source);
    defer iterator_method.free(ctx.runtime);
    if (!iterator_method.isUndefined() and !iterator_method.isNull()) {
        if (!isCallableValue(iterator_method)) return error.TypeError;
        const iterator = try callValueOrBytecode(ctx, output, global, source, iterator_method, &.{}, caller_function, caller_frame);
        errdefer iterator.free(ctx.runtime);
        _ = object_ops.objectFromValue(iterator) orelse return error.TypeError;
        return .{ .iterator = iterator };
    }

    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try object_ops.getValueProperty(ctx, output, global, source, next_key, caller_function, caller_frame);
    errdefer next_method.free(ctx.runtime);
    return .{ .iterator = source_object.value().dup(), .next_method = next_method, .wrap = true };
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
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_iterator },
        .{ .value = &rooted_next_method },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

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
    const iterator = try core.Object.create(rt, core.class.ids.object, null);
    defer iterator.value().free(rt);

    const prototype = try core.Object.create(rt, core.class.ids.object, null);
    defer prototype.value().free(rt);
    try builtin_glue.storeRealmValue(rt, global, .wrap_for_valid_iterator_prototype, prototype.value());

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    fb.flags.func_kind = .generator;
    try rt.gc.add(&fb.header);

    {
        const __cp = try rt.memory.alloc(core.JSValue, 1);
        fb.cpool = __cp.ptr;
        fb.cpool_count = @intCast(__cp.len);
    }
    const symbol_atom = try rt.atoms.newValueSymbol("gc-wrap-iterator-next-bytecode-symbol");
    fb.cpool[0] = try rt.symbolValue(symbol_atom);
    fb.cpool_count = 1;

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

pub fn qjsIteratorWrapNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (function_object.functionIteratorWrapMethod() != 1) return null;
    const wrapper = object_ops.objectFromValue(receiver) orelse return error.TypeError;
    if (wrapper.class_id != core.class.ids.iterator_wrap) return error.TypeError;
    const iterator = (wrapper.iteratorTargetSlot().*) orelse return error.TypeError;
    const next_method = if (wrapper.iteratorNext()) |stored| stored.dup() else blk: {
        const next_key = try ctx.runtime.internAtom("next");
        defer ctx.runtime.atoms.free(next_key);
        const method = try object_ops.getValueProperty(ctx, output, global, iterator, next_key, caller_function, caller_frame);
        errdefer method.free(ctx.runtime);
        if (!isCallableValue(method)) return error.TypeError;
        break :blk method;
    };
    defer next_method.free(ctx.runtime);
    const result = try callValueOrBytecode(ctx, output, global, iterator, next_method, &.{}, caller_function, caller_frame);
    errdefer result.free(ctx.runtime);
    _ = object_ops.objectFromValue(result) orelse return error.TypeError;
    return result;
}

pub fn qjsIteratorWrapReturn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (function_object.functionIteratorWrapMethod() != 2) return null;
    const wrapper = object_ops.objectFromValue(receiver) orelse return error.TypeError;
    if (wrapper.class_id != core.class.ids.iterator_wrap) return error.TypeError;
    const iterator = (wrapper.iteratorTargetSlot().*) orelse return error.TypeError;
    const return_key = try ctx.runtime.internAtom("return");
    defer ctx.runtime.atoms.free(return_key);
    const return_method = try object_ops.getValueProperty(ctx, output, global, iterator, return_key, caller_function, caller_frame);
    defer return_method.free(ctx.runtime);
    if (return_method.isUndefined() or return_method.isNull()) {
        return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
    }
    if (!isCallableValue(return_method)) return error.TypeError;
    const result = try callValueOrBytecode(ctx, output, global, iterator, return_method, &.{}, caller_function, caller_frame);
    errdefer result.free(ctx.runtime);
    _ = object_ops.objectFromValue(result) orelse return error.TypeError;
    return result;
}

pub fn qjsIteratorHelperNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return iter_vm.qjsIteratorHelperNext(
        ctx,
        output,
        global,
        receiver,
        function_object,
        caller_function,
        caller_frame,
    );
}

pub fn qjsIteratorHelperReturn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return iter_vm.qjsIteratorHelperReturn(
        ctx,
        output,
        global,
        receiver,
        function_object,
        caller_function,
        caller_frame,
    );
}

pub fn pollGCSafePoint(ctx: *core.JSContext) !void {
    _ = ctx.runtime.gcSafepoint(null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PayloadMarkFailed => return error.OutOfMemory,
    };
}

pub fn enqueueOsTimer(ctx: *core.JSContext, id: i64, callback: core.JSValue, delay_ms: u64, repeats: bool) HostError!void {
    const host_event_loop = ctx.hostEventLoop() orelse return error.TypeError;
    host_event_loop.enqueueTimer(ctx, id, callback, delay_ms, repeats) catch |err| return @errorCast(err);
}

pub fn clearOsTimer(ctx: *core.JSContext, id: i64) void {
    if (ctx.hostEventLoop()) |host_event_loop| {
        host_event_loop.clearTimer(ctx, id);
    }
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

pub fn createIteratorResult(rt: *core.JSRuntime, global: *core.Object, value: core.JSValue, done: bool) !core.JSValue {
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const object = try core.Object.create(rt, core.class.ids.object, object_ops.objectPrototypeFromGlobal(rt, global));
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    // qjs js_create_iterator_result (quickjs.c:16768) keys on the predefined
    // JS_ATOM_value / JS_ATOM_done constants; use the interned atom ids directly
    // instead of re-interning the "value"/"done" byte strings per result (this
    // runs once per generator/iterator step, a hot path).
    try object.defineOwnProperty(rt, core.atom.ids.value, core.Descriptor.data(rooted_value, true, true, true));
    try object.defineOwnProperty(rt, core.atom.ids.done, core.Descriptor.data(core.JSValue.boolean(done), true, true, true));
    return object.value();
}

test "createIteratorResult roots direct function bytecode value while creating result" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    {
        const __cp = try rt.memory.alloc(core.JSValue, 1);
        fb.cpool = __cp.ptr;
        fb.cpool_count = @intCast(__cp.len);
    }
    const symbol_atom = try rt.atoms.newValueSymbol("gc-iterator-result-bytecode-symbol");
    fb.cpool[0] = try rt.symbolValue(symbol_atom);
    fb.cpool_count = 1;

    var result_value = core.JSValue.functionBytecode(&fb.header);
    var result_alive = true;
    defer if (result_alive) result_value.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const iterator_result_value = try createIteratorResult(rt, global, result_value, false);
    var iterator_result_alive = true;
    defer if (iterator_result_alive) iterator_result_value.free(rt);
    const iterator_result = object_ops.objectFromValue(iterator_result_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_atom = try rt.internAtom("value");
    defer rt.atoms.free(value_atom);
    {
        const stored = iterator_result.getProperty(value_atom);
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
    if (global.cachedThrowTypeErrorIntrinsic()) |stored| return stored.dup();

    const thrower = try core.function.nativeFunction(rt, "", 0);
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

pub fn qjsThrowTypeErrorIntrinsic(ctx: *core.JSContext, global: *core.Object, function_object: *core.Object) !core.JSValue {
    const error_global = object_ops.objectRealmGlobal(function_object) orelse global;
    const error_value = try exception_ops.createNamedError(ctx, error_global, "TypeError", "invalid property access");
    _ = ctx.throwValue(error_value);
    return error.JSException;
}

pub fn currentFrameFunctionIsStrict(frame: *frame_mod.Frame) bool {
    if (frame.function.flags.is_strict or frame.function.flags.runtime_strict) return true;
    const fb = if (functionBytecodeFromValue(frame.current_function)) |bytecode_value|
        bytecode_value
    else if (object_ops.objectFromValue(frame.current_function)) |function_object|
        if (function_object.functionBytecodeSlot().*) |stored| functionBytecodeFromValue(stored) else null
    else
        null;
    if (fb) |function_bytecode| return function_bytecode.flags.is_strict_mode or function_bytecode.flags.runtime_strict_mode;
    return false;
}

pub fn functionBytecodeFromValue(value: core.JSValue) ?*const bytecode.FunctionBytecode {
    const header = value.objectHeader() orelse return null;
    const aligned: *align(16) @TypeOf(header.*) = @alignCast(header);
    return @fieldParentPtr("header", aligned);
}

pub fn isFunctionLikeClass(class_id: core.class.ClassId) bool {
    return class_id == core.class.ids.c_function or
        class_id == core.class.ids.c_closure or
        class_id == core.class.ids.bytecode_function or
        class_id == core.class.ids.bound_function;
}

pub fn isConstructorLike(ctx: *core.JSContext, value: core.JSValue) error{OutOfMemory}!bool {
    if (value.isFunctionBytecode()) {
        const fb = functionBytecodeFromValue(value) orelse return false;
        return !fb.flags.is_arrow_function and fb.flags.has_prototype and fb.flags.func_kind != .generator and fb.flags.func_kind != .async_generator;
    }
    if (object_ops.functionObjectFromValue(value)) |function_object| {
        const function_value = function_object.functionBytecodeSlot().* orelse return false;
        const fb = functionBytecodeFromValue(function_value) orelse return false;
        return !fb.flags.is_arrow_function and fb.flags.has_prototype and fb.flags.func_kind != .generator and fb.flags.func_kind != .async_generator;
    }
    if (object_ops.callableObjectFromValue(value)) |function_object| {
        if (function_object.class_id == core.class.ids.bound_function) {
            const target = function_object.boundTarget() orelse return false;
            return isConstructorLike(ctx, target);
        }
        if (function_object.flags.is_html_dda) return false;
        if (function_object.hostFunctionKindSlot().* == core.host_function.ids.external_host) {
            return function_object.hasOwnProperty(core.atom.ids.prototype);
        }
        if (function_object.class_id == core.class.ids.c_closure) return true;
        // A function carrying a construct-capable builtin native id (Date/
        // RegExp/String) is a constructor regardless of its dispatch name
        // (Phase 6b-3e: replaces the `date.isConstructorRecord` short circuit
        // with the generic table probe, which also covers RegExp/String).
        if (core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*)) |native_ref| {
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const target = object.boundTarget() orelse return error.TypeError;
    const bound_this = object.boundThis() orelse return error.TypeError;
    const combined = try boundFunctionArgs(ctx.runtime, object, args);
    defer freeArgs(ctx.runtime, combined);
    return callValueOrBytecode(ctx, output, global, bound_this, target, combined, caller_function, caller_frame);
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

pub fn setFailureShouldThrow(caller_function: ?*const bytecode.Bytecode) bool {
    if (caller_function) |function| return functionRuntimeStrict(function);
    return false;
}

pub fn functionRuntimeStrict(function: *const bytecode.Bytecode) bool {
    return function.flags.is_strict or function.flags.runtime_strict;
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!bool {
    _ = target_value;
    if (target.proxyTarget() != null) {
        return object_ops.proxySetValueProperty(ctx, output, global, receiver_value, target, atom_id, value, caller_function, caller_frame);
    }
    const receiver_object = object_ops.objectFromValue(receiver_value) orelse target;
    if (try array_ops.typedArrayPrototypeSet(ctx, output, global, receiver_value, receiver_object, target.getPrototype(), atom_id, value, caller_function, caller_frame)) |ok| return ok;
    if (value_ops.atomNameEql(ctx.runtime, atom_id, "__proto__")) {
        _ = try object_ops.qjsObjectProtoSetterCall(ctx, output, global, receiver_value, value, caller_function, caller_frame);
        return true;
    }
    if (target.getOwnProperty(ctx.runtime, atom_id)) |own_desc| {
        defer own_desc.destroy(ctx.runtime);
        return object_ops.setWithOwnDescriptor(ctx, output, global, receiver_value, atom_id, value, own_desc, caller_function, caller_frame);
    }
    if (target.getPrototype()) |prototype| {
        return ordinarySetWithReceiver(ctx, output, global, prototype.value(), prototype, receiver_value, atom_id, value, caller_function, caller_frame);
    }
    return object_ops.setWithOwnDescriptor(ctx, output, global, receiver_value, atom_id, value, core.Descriptor.data(core.JSValue.undefinedValue(), true, true, true), caller_function, caller_frame);
}

pub fn qjsReflectSetCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    const set_value = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const object = property_ops.expectObject(args[0]) catch return error.TypeError;
    const key_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const atom_id = try object_ops.toPropertyKeyAtom(ctx, output, global, key_value, caller_function, caller_frame);
    defer ctx.runtime.atoms.free(atom_id);
    if (object.class_id == core.class.ids.module_ns) return core.JSValue.boolean(false);
    if (!object.flags.is_array or atom_id != core.atom.ids.length) {
        const receiver_value = if (args.len >= 4) args[3] else args[0];
        if (object.proxyTarget() != null) {
            const ok = try object_ops.proxySetValueProperty(ctx, output, global, receiver_value, object, atom_id, set_value, caller_function, caller_frame);
            return core.JSValue.boolean(ok);
        }
        if (core.object.isTypedArrayObject(object)) {
            switch (try core.object.typedArrayCanonicalNumericIndex(ctx.runtime, atom_id)) {
                .none => {},
                .invalid => {
                    if (object_ops.sameObjectIdentity(receiver_value, args[0])) {
                        const coerced = try array_ops.coerceTypedArrayElementInput(ctx, output, global, set_value);
                        defer coerced.free(ctx.runtime);
                        try core.typed_array.typedArrayCoerceElementValue(ctx.runtime, object, coerced);
                    }
                    return core.JSValue.boolean(true);
                },
                .index => |index| {
                    if (object_ops.sameObjectIdentity(receiver_value, args[0])) {
                        const coerced = try array_ops.coerceTypedArrayElementForSet(ctx, output, global, object, set_value);
                        defer coerced.free(ctx.runtime);
                        if (!try core.object.typedArrayIndexValid(ctx.runtime, object, index)) return core.JSValue.boolean(true);
                        if (try core.object.typedArrayImmutableBuffer(ctx.runtime, object)) return core.JSValue.boolean(false);
                        _ = try core.typed_array.typedArraySetElement(ctx.runtime, object, index, coerced);
                        return core.JSValue.boolean(true);
                    }
                    if (!try core.object.typedArrayIndexValid(ctx.runtime, object, index)) return core.JSValue.boolean(true);
                    const receiver_object = object_ops.objectFromValue(receiver_value) orelse return core.JSValue.boolean(false);
                    const ok = try array_ops.typedArrayReflectSetReceiverOwn(ctx, output, global, receiver_value, receiver_object, atom_id, set_value, caller_function, caller_frame);
                    return core.JSValue.boolean(ok);
                },
            }
        }
        if (object_ops.objectFromValue(receiver_value)) |receiver_object| {
            if (try array_ops.typedArrayPrototypeSet(ctx, output, global, receiver_value, receiver_object, object.getPrototype(), atom_id, set_value, caller_function, caller_frame)) |ok| {
                return core.JSValue.boolean(ok);
            }
        }
        const ok = try ordinarySetWithReceiver(ctx, output, global, args[0], object, receiver_value, atom_id, set_value, caller_function, caller_frame);
        return core.JSValue.boolean(ok);
    }
    const value_to_set = try array_ops.arrayLengthAssignmentValue(ctx, output, global, object, atom_id, set_value, caller_function, caller_frame);
    defer if (!value_to_set.same(set_value)) value_to_set.free(ctx.runtime);
    object.setProperty(ctx.runtime, atom_id, value_to_set) catch |err| switch (err) {
        error.ReadOnly, error.AccessorWithoutSetter, error.NotExtensible, error.IncompatibleDescriptor => return core.JSValue.boolean(false),
        error.InvalidLength => return error.RangeError,
        else => return err,
    };
    return core.JSValue.boolean(true);
}

pub fn qjsDefinePropertiesCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 2) return error.TypeError;
    const target = property_ops.expectObject(args[0]) catch return @as(?core.JSValue, try exception_ops.throwTypeErrorMessage(ctx, global, "not an object"));
    try qjsDefinePropertiesOnTarget(ctx, output, global, target, args[1], caller_function, caller_frame);
    return args[0].dup();
}

const math_ops = @import("math_ops.zig");

pub const IntegrityLevel = enum {
    sealed,
    frozen,
};

pub fn qjsReflectIsExtensibleCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    if (!args[0].isObject()) return error.TypeError;
    return object_ops.qjsObjectIsExtensibleCall(ctx, output, global, args, caller_function, caller_frame);
}

pub fn qjsReflectPreventExtensionsCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    const object = object_ops.objectFromValue(args[0]) orelse return error.TypeError;
    if (object.proxyTarget() != null) {
        return core.JSValue.boolean(try object_ops.proxyAwarePreventExtensions(ctx, output, global, object, caller_function, caller_frame));
    }
    object.preventExtensions();
    return core.JSValue.boolean(true);
}

pub fn qjsReflectConstructCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 2 or !(try isConstructorLike(ctx, args[0]))) return error.TypeError;
    const new_target = if (args.len >= 3) args[2] else args[0];
    if (!(try isConstructorLike(ctx, new_target))) return error.TypeError;
    var construct_args = try array_ops.argsFromArrayLike(ctx, output, global, args[1], caller_function, caller_frame);
    defer freeArgs(ctx.runtime, construct_args);
    var construct_args_root = array_ops.ValueSliceRoot{};
    construct_args_root.init(ctx.runtime, &construct_args);
    defer construct_args_root.deinit();
    if (object_ops.objectFromValue(args[0])) |target| {
        if (target.proxyTarget() == null) {
            const target_name = try call_mod.nativeFunctionNameForVm(ctx.runtime, target);
            defer ctx.runtime.memory.allocator.free(target_name);
            if (construct_mod.typedArrayElement(target_name) != null) {
                try array_ops.qjsTypedArrayValidateConstructArgsPreAllocate(ctx, output, global, construct_args);
            }
        }
    }
    return try constructValueOrBytecodeWithNewTarget(ctx, output, global, args[0], construct_args, caller_function, caller_frame, new_target);
}

pub const ReflectConstructResolution = struct {
    target: core.JSValue,
    new_target: core.JSValue,
    args: []const core.JSValue,
    owned_args: []core.JSValue = &.{},
};

pub fn qjsReflectConstructGenericCallable(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target_value: core.JSValue,
    new_target_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    const resolved = try promise_ops.qjsReflectConstructResolveBound(ctx.runtime, target_value, new_target_value, args);
    defer if (resolved.owned_args.len != 0) freeArgs(ctx.runtime, resolved.owned_args);
    var rooted_owned_args = resolved.owned_args;
    var owned_args_root = array_ops.ValueSliceRoot{};
    if (rooted_owned_args.len != 0) owned_args_root.init(ctx.runtime, &rooted_owned_args);
    defer owned_args_root.deinit();
    const resolved_args: []const core.JSValue = if (rooted_owned_args.len != 0) rooted_owned_args else resolved.args;

    if (object_ops.objectFromValue(resolved.target)) |target_object| {
        const target_name = call_mod.nativeFunctionNameForVm(ctx.runtime, target_object) catch "";
        defer if (target_name.len != 0) ctx.runtime.memory.allocator.free(target_name);
        if (std.mem.eql(u8, target_name, "Array")) {
            const prototype = try object_ops.reflectConstructPrototypeVm(ctx, output, global, "Array", resolved.new_target, caller_function, caller_frame);
            return try constructArrayNativeRecordVm(ctx, output, global, target_object, prototype, resolved_args, caller_function, caller_frame);
        }
    }

    const prototype = try object_ops.reflectConstructPrototypeVm(ctx, output, global, "Object", resolved.new_target, caller_function, caller_frame);

    if (object_ops.objectFromValue(resolved.target)) |proxy| {
        if (proxy.proxyTarget() != null) {
            return try object_ops.constructProxy(ctx, output, global, resolved.target, proxy, resolved_args, caller_function, caller_frame, resolved.new_target);
        }
    }

    if (resolved.target.isFunctionBytecode()) {
        const fb = functionBytecodeFromValue(resolved.target) orelse return error.TypeError;
        if (fb.flags.is_arrow_function or !fb.flags.has_prototype or fb.flags.func_kind == .generator or fb.flags.func_kind == .async_generator) {
            return error.TypeError;
        }
        const instance_object = try core.Object.create(ctx.runtime, core.class.ids.object, prototype);
        const instance = instance_object.value();
        errdefer instance.free(ctx.runtime);
        if (!fb.flags.is_derived_class_constructor) {
            try class_init_ops.initializeClassInstanceElements(ctx, output, global, resolved.target, instance, fb, caller_function, caller_frame);
        }
        const initial_this = if (fb.flags.is_derived_class_constructor) core.JSValue.uninitialized() else instance;
        const constructor_this = if (fb.flags.is_derived_class_constructor) instance else core.JSValue.undefinedValue();
        const result = try callFunctionBytecodeConstruct(ctx, resolved.target, resolved.target, initial_this, resolved_args, &.{}, output, global, resolved.new_target, constructor_this);
        if (result.isObject()) {
            instance.free(ctx.runtime);
            return result;
        }
        result.free(ctx.runtime);
        return instance;
    }

    if (object_ops.functionObjectFromValue(resolved.target)) |function_object| {
        const function_value = function_object.functionBytecodeSlot().* orelse return error.TypeError;
        const fb = functionBytecodeFromValue(function_value) orelse return error.TypeError;
        if (fb.flags.is_arrow_function or !fb.flags.has_prototype or fb.flags.func_kind == .generator or fb.flags.func_kind == .async_generator) {
            return error.TypeError;
        }
        const instance_object = try core.Object.create(ctx.runtime, core.class.ids.object, prototype);
        const instance = instance_object.value();
        errdefer instance.free(ctx.runtime);
        if (!fb.flags.is_derived_class_constructor) {
            try class_init_ops.initializeClassInstanceElements(ctx, output, global, resolved.target, instance, fb, caller_function, caller_frame);
        }
        const function_global = object_ops.objectRealmGlobal(function_object) orelse global;
        const initial_this = if (fb.flags.is_derived_class_constructor) core.JSValue.uninitialized() else instance;
        const constructor_this = if (fb.flags.is_derived_class_constructor) instance else core.JSValue.undefinedValue();
        const result = try callFunctionBytecodeConstruct(ctx, function_value, resolved.target, initial_this, resolved_args, function_object.functionCapturesSlot().*, output, function_global, resolved.new_target, constructor_this);
        if (result.isObject()) {
            instance.free(ctx.runtime);
            return result;
        }
        result.free(ctx.runtime);
        return instance;
    }

    return null;
}

pub fn qjsReflectHasCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 2) return error.TypeError;
    const object = object_ops.objectFromValue(args[0]) orelse return error.TypeError;
    const key = try object_ops.toPropertyKeyAtom(ctx, output, global, args[1], caller_function, caller_frame);
    defer ctx.runtime.atoms.free(key);
    const found = if (object.proxyTarget() != null)
        try object_ops.hasValueProperty(ctx, output, global, args[0], object, key, caller_function, caller_frame)
    else
        try object_ops.ordinaryHasValueProperty(ctx, output, global, object, key, false, caller_function, caller_frame);
    return core.JSValue.boolean(found);
}

pub fn qjsReflectApplyCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (args.len < 1 or !isCallableValue(args[0])) return exception_ops.throwTypeErrorMessage(ctx, global, "not a function");
    if (args.len < 3) return error.TypeError;
    var apply_args = try array_ops.argsFromArrayLike(ctx, output, global, args[2], caller_function, caller_frame);
    defer freeArgs(ctx.runtime, apply_args);
    var apply_args_root = array_ops.ValueSliceRoot{};
    apply_args_root.init(ctx.runtime, &apply_args);
    defer apply_args_root.deinit();
    return callValueOrBytecode(ctx, output, global, args[1], args[0], apply_args, caller_function, caller_frame);
}

pub fn closeIteratorForFromEntriesAbrupt(
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
    const out = try callValueOrBytecode(ctx, output, global, iterator_value, return_method, &.{}, null, null);
    out.free(ctx.runtime);
}

pub fn qjsDefinePropertiesOnTarget(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target: *core.Object,
    properties_arg: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
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
        const desc = try object_ops.qjsDescriptorFromObject(ctx, output, global, desc_value, desc_object, target, key, caller_function, caller_frame);
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

pub fn qjsReflectGetCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 2) return error.TypeError;
    const object = object_ops.objectFromValue(args[0]) orelse return error.TypeError;
    const atom_id = try object_ops.toPropertyKeyAtom(ctx, output, global, args[1], caller_function, caller_frame);
    defer ctx.runtime.atoms.free(atom_id);
    const receiver = if (args.len >= 3) args[2] else args[0];
    return try object_ops.getValuePropertyWithReceiver(ctx, output, global, args[0], object, receiver, atom_id, caller_function, caller_frame);
}

pub fn qjsReflectOwnKeysCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    const object = property_ops.expectObject(args[0]) catch return error.TypeError;
    const keys = try object_ops.objectRestOwnKeys(ctx, output, global, object);
    defer core.Object.freeKeys(ctx.runtime, keys);
    const out = try core.Object.createArray(ctx.runtime, null);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
    for (keys) |key| {
        const key_value = try object_ops.proxyTrapKeyValue(ctx.runtime, key);
        defer key_value.free(ctx.runtime);
        try out.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(out.arrayLength()), core.Descriptor.data(key_value, true, true, true));
    }
    return out.value();
}

pub fn callAccessorSetter(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (try object_ops.findPropertyDescriptor(ctx.runtime, object, atom_id)) |desc| {
        defer desc.destroy(ctx.runtime);
        if (desc.kind != .accessor) return false;
        if (desc.setter.isUndefined()) return error.AccessorWithoutSetter;
        const result = try callValueOrBytecode(ctx, output, global, receiver, desc.setter, &.{value}, caller_function, caller_frame);
        result.free(ctx.runtime);
        return true;
    }
    return false;
}

pub fn clearPrivateNameRemap(rt: *core.JSRuntime, object: *core.Object) void {
    if (object.privateRemapFrom().len == 0 and object.privateRemapTo().len == 0) return;
    const from_slot = object.privateRemapFromSlot();
    const to_slot = object.privateRemapToSlot();
    const old_from = from_slot.*;
    const old_to = to_slot.*;
    from_slot.* = &.{};
    to_slot.* = &.{};
    for (old_from) |atom_id| rt.atoms.free(atom_id);
    if (old_from.len != 0) rt.memory.free(core.Atom, old_from);
    for (old_to) |atom_id| rt.atoms.free(atom_id);
    if (old_to.len != 0) rt.memory.free(core.Atom, old_to);
}

pub const PrivateNameRemapSnapshot = struct {
    from: []core.Atom = &.{},
    to: []core.Atom = &.{},

    pub fn capture(rt: *core.JSRuntime, object: *const core.Object) !PrivateNameRemapSnapshot {
        const old_from = object.privateRemapFrom();
        const old_to = object.privateRemapTo();
        std.debug.assert(old_from.len == old_to.len);
        if (old_from.len == 0) return .{};

        const from = try rt.memory.alloc(core.Atom, old_from.len);
        errdefer rt.memory.free(core.Atom, from);
        const to = try rt.memory.alloc(core.Atom, old_to.len);
        errdefer rt.memory.free(core.Atom, to);

        for (old_from, 0..) |atom_id, index| from[index] = rt.atoms.dup(atom_id);
        for (old_to, 0..) |atom_id, index| to[index] = rt.atoms.dup(atom_id);
        return .{ .from = from, .to = to };
    }

    pub fn restore(self: *PrivateNameRemapSnapshot, rt: *core.JSRuntime, object: *core.Object) void {
        clearPrivateNameRemap(rt, object);
        if (self.from.len != 0) {
            object.privateRemapFromSlot().* = self.from;
            object.privateRemapToSlot().* = self.to;
            self.from = &.{};
            self.to = &.{};
        }
    }

    pub fn deinit(self: *PrivateNameRemapSnapshot, rt: *core.JSRuntime) void {
        for (self.from) |atom_id| rt.atoms.free(atom_id);
        if (self.from.len != 0) rt.memory.free(core.Atom, self.from);
        for (self.to) |atom_id| rt.atoms.free(atom_id);
        if (self.to.len != 0) rt.memory.free(core.Atom, self.to);
        self.from = &.{};
        self.to = &.{};
    }
};

pub fn appendPrivateNameRemap(rt: *core.JSRuntime, object: *core.Object, from_atom: core.Atom, to_atom: core.Atom) !void {
    const from_slot = try object.privateRemapFromSlotEnsured(rt);
    const to_slot = try object.privateRemapToSlotEnsured(rt);
    for (from_slot.*, 0..) |existing, idx| {
        if (existing != from_atom) continue;
        const retained = rt.atoms.dup(to_atom);
        const old = to_slot.*[idx];
        to_slot.*[idx] = retained;
        rt.atoms.free(old);
        return;
    }

    const new_len = from_slot.*.len + 1;
    const from = try rt.memory.alloc(core.Atom, new_len);
    errdefer rt.memory.free(core.Atom, from);
    const to = try rt.memory.alloc(core.Atom, new_len);
    errdefer rt.memory.free(core.Atom, to);
    @memcpy(from[0..from_slot.*.len], from_slot.*);
    @memcpy(to[0..to_slot.*.len], to_slot.*);
    from[new_len - 1] = rt.atoms.dup(from_atom);
    to[new_len - 1] = rt.atoms.dup(to_atom);
    const old_from = from_slot.*;
    const old_to = to_slot.*;
    from_slot.* = from;
    to_slot.* = to;
    if (old_from.len != 0) rt.memory.free(core.Atom, old_from);
    if (old_to.len != 0) rt.memory.free(core.Atom, old_to);
}

pub fn installLexicalPrivateNameRemap(
    rt: *core.JSRuntime,
    object: *core.Object,
    caller_frame: ?*frame_mod.Frame,
    bound_names: []const core.Atom,
) !void {
    if (bound_names.len == 0) return;
    var snapshot = try PrivateNameRemapSnapshot.capture(rt, object);
    defer snapshot.deinit(rt);
    errdefer snapshot.restore(rt, object);

    for (bound_names) |atom_id| {
        const mapped = remapPrivateAtomFromFrame(rt, caller_frame, atom_id);
        if (mapped != atom_id) try appendPrivateNameRemap(rt, object, atom_id, mapped);
    }
}

pub fn installFreshPrivateNameRemap(rt: *core.JSRuntime, object: *core.Object, old_names: []const core.Atom) !void {
    if (old_names.len == 0) return;
    var snapshot = try PrivateNameRemapSnapshot.capture(rt, object);
    defer snapshot.deinit(rt);
    errdefer snapshot.restore(rt, object);

    for (old_names) |old_atom| {
        const name = rt.atoms.name(old_atom) orelse return error.TypeError;
        const fresh_atom = try rt.atoms.newSymbol(name, .private);
        defer rt.atoms.free(fresh_atom);
        try appendPrivateNameRemap(rt, object, old_atom, fresh_atom);
    }
}

pub fn copyPrivateNameRemap(rt: *core.JSRuntime, dst: *core.Object, src: *const core.Object) !void {
    if (src.privateRemapFrom().len == 0) return;
    const from = try rt.memory.alloc(core.Atom, src.privateRemapFrom().len);
    errdefer rt.memory.free(core.Atom, from);
    const to = try rt.memory.alloc(core.Atom, src.privateRemapTo().len);
    errdefer rt.memory.free(core.Atom, to);
    var initialized: usize = 0;
    errdefer {
        for (from[0..initialized]) |atom_id| rt.atoms.free(atom_id);
        for (to[0..initialized]) |atom_id| rt.atoms.free(atom_id);
    }
    for (src.privateRemapFrom(), 0..) |atom_id, idx| {
        from[idx] = rt.atoms.dup(atom_id);
        to[idx] = rt.atoms.dup(src.privateRemapTo()[idx]);
        initialized += 1;
    }
    const from_slot = try dst.privateRemapFromSlotEnsured(rt);
    const to_slot = try dst.privateRemapToSlotEnsured(rt);
    const old_from = from_slot.*;
    const old_to = to_slot.*;
    from_slot.* = from;
    to_slot.* = to;
    for (old_from) |atom_id| rt.atoms.free(atom_id);
    if (old_from.len != 0) rt.memory.free(core.Atom, old_from);
    for (old_to) |atom_id| rt.atoms.free(atom_id);
    if (old_to.len != 0) rt.memory.free(core.Atom, old_to);
}

pub fn remapPrivateAtomFromFrame(rt: *core.JSRuntime, caller_frame: ?*frame_mod.Frame, atom_id: core.Atom) core.Atom {
    if (rt.atoms.kind(atom_id) != .private) return atom_id;
    const frame = caller_frame orelse return atom_id;
    const function_object = object_ops.objectFromValue(frame.current_function) orelse return atom_id;
    const function_atom = object_ops.remapPrivateAtomFromObject(rt, function_object, atom_id);
    if (function_atom != atom_id) return function_atom;
    const home_object = function_object.functionHomeObjectSlot().* orelse return atom_id;
    return object_ops.remapPrivateAtomFromObject(rt, home_object, atom_id);
}

pub fn remapPrivateAtomForOperation(
    rt: *core.JSRuntime,
    caller_frame: ?*frame_mod.Frame,
    object: ?*const core.Object,
    atom_id: core.Atom,
) core.Atom {
    const frame_atom = remapPrivateAtomFromFrame(rt, caller_frame, atom_id);
    if (frame_atom != atom_id) return frame_atom;
    if (object) |target| return object_ops.remapPrivateAtomFromObject(rt, target, atom_id);
    return atom_id;
}

pub fn inOp(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    output: ?*std.Io.Writer,
    global: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const rhs = try stack.pop();
    defer rhs.free(ctx.runtime);
    const lhs = try stack.pop();
    defer lhs.free(ctx.runtime);
    _ = property_ops.expectObject(rhs) catch {
        _ = exception_ops.throwTypeErrorMessage(ctx, global, "invalid 'instanceof' right operand") catch |err| return err;
        return error.TypeError;
    };
    const has_instance_atom = core.atom.predefinedId("Symbol.hasInstance", .symbol) orelse return error.TypeError;
    const has_instance = try object_ops.getValueProperty(ctx, output, global, rhs, has_instance_atom, caller_function, caller_frame);
    defer has_instance.free(ctx.runtime);
    if (!has_instance.isUndefined() and !has_instance.isNull()) {
        const result = try callValueOrBytecode(ctx, output, global, rhs, has_instance, &.{lhs}, caller_function, caller_frame);
        defer result.free(ctx.runtime);
        stack.pushOwnedAssumeCapacity(core.JSValue.boolean(coercion_ops.valueTruthy(result)));
        return;
    }
    if (!isCallableValue(rhs)) {
        _ = exception_ops.throwTypeErrorMessage(ctx, global, "invalid 'instanceof' right operand") catch |err| return err;
        return error.TypeError;
    }
    if (!lhs.isObject()) {
        stack.pushOwnedAssumeCapacity(core.JSValue.boolean(false));
        return;
    }
    const object = try property_ops.expectObject(lhs);
    const proto_value = try object_ops.getValueProperty(ctx, output, global, rhs, core.atom.ids.prototype, caller_function, caller_frame);
    defer proto_value.free(ctx.runtime);
    if (!proto_value.isObject()) {
        return error.TypeError;
    }
    const proto = try property_ops.expectObject(proto_value);
    var current = try object_ops.qjsObjectGetPrototypeOfStep(ctx, output, global, object, caller_function, caller_frame);
    while (current) |candidate| {
        if (candidate == proto) {
            stack.pushOwnedAssumeCapacity(core.JSValue.boolean(true));
            return;
        }
        current = try object_ops.qjsObjectGetPrototypeOfStep(ctx, output, global, candidate, caller_function, caller_frame);
    }
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(false));
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
    const name_value = object.getProperty(core.atom.ids.name);
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
    caller_function: ?*const bytecode.Bytecode,
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

pub fn lookupFrameVarRef(ctx: *core.JSContext, global: *core.Object, function: *const bytecode.Bytecode, frame: *frame_mod.Frame, atom_id: core.Atom) ?core.JSValue {
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
        if (slot_ops.varRefSlotIsDeletedEvalBinding(slot)) continue;
        const value = slot_ops.slotValueDup(slot);
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

pub fn closureVarIsNonLexicalGlobalSentinel(function: *const bytecode.Bytecode, idx: usize) bool {
    if (idx >= function.closure_var.len) return false;
    const cv = function.closure_var[idx];
    if (cv.is_lexical) return false;
    return switch (cv.closure_type) {
        .global, .global_ref, .global_decl => true,
        else => false,
    };
}

pub fn lookupFrameLocalValue(rt: *core.JSRuntime, function: *const bytecode.Bytecode, frame: *frame_mod.Frame, atom_id: core.Atom) ?core.JSValue {
    const count = @min(function.vardefs.len, frame.locals.len);
    for (function.vardefs[0..count], 0..) |vd, idx| {
        if (!atomIdOrNameEql(rt, vd.var_name, atom_id)) continue;
        if (vd.scope_level != 0) continue;
        return slot_ops.slotValueDup(frame.locals[idx]);
    }
    return null;
}

pub fn atomIdOrNameEql(rt: *core.JSRuntime, left: core.Atom, right: core.Atom) bool {
    if (left == right) return true;
    const left_name = rt.atoms.name(left) orelse return false;
    const right_name = rt.atoms.name(right) orelse return false;
    return std.mem.eql(u8, left_name, right_name);
}

pub fn setFrameLocalValue(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    atom_id: core.Atom,
    value: core.JSValue,
) !bool {
    const count = @min(function.vardefs.len, frame.locals.len);
    for (function.vardefs[0..count], 0..) |vd, idx| {
        if (vd.var_name != atom_id) continue;
        if (!varDefIsEvalHoistedVar(vd)) continue;
        try slot_ops.setSlotValue(ctx, &frame.locals[idx], value);
        return true;
    }
    return false;
}

pub fn setFrameVarRefValue(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    atom_id: core.Atom,
    value: core.JSValue,
) !bool {
    var idx: usize = 0;
    while (idx < function.varRefNamesLen()) : (idx += 1) {
        const name = function.varRefName(idx);
        if (name != atom_id) continue;
        if (idx >= frame.var_refs.len) try frame_mod.ensureVarRefsCapacity(ctx, frame, @intCast(idx));
        if (closureVarIsNonLexicalGlobalSentinel(function, idx) and slot_ops.varRefSlotIsUninitialized(slot_ops.varRefSlot(frame, idx))) {
            return false;
        }
        try slot_ops.setVarRefSlotValue(ctx, frame, idx, value);
        return true;
    }
    return false;
}

pub fn functionNameValueFromAtom(rt: *core.JSRuntime, atom_id: core.Atom, prefix: ?[]const u8) !core.JSValue {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    if (prefix) |text| {
        try bytes.appendSlice(rt.memory.allocator, text);
        try bytes.append(rt.memory.allocator, ' ');
    }
    if (core.atom.isTaggedInt(atom_id)) {
        var buf: [10]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d}", .{core.atom.atomToUInt32(atom_id)});
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
    if (refs[index].isUninitialized()) return null;
    if (!object.hasOwnProperty(atom_id)) return null;
    const cell = slot_ops.varRefCellFromValue(refs[index]) orelse return refs[index].dup();
    return cell.varRefValue().dup();
}

pub fn setMappedArgumentsValue(ctx: *core.JSContext, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !bool {
    if (object.class_id != core.class.ids.mapped_arguments) return false;
    const index = core.array.arrayIndexFromAtom(&ctx.runtime.atoms, atom_id) orelse return false;
    const refs = object.argumentsVarRefsSlot();
    if (index >= refs.*.len) return false;
    if (refs.*[index].isUninitialized()) return false;
    if (!object.hasOwnProperty(atom_id)) {
        const old_value = refs.*[index];
        refs.*[index] = core.JSValue.uninitialized();
        old_value.free(ctx.runtime);
        return false;
    }
    if (slot_ops.varRefCellFromValue(refs.*[index])) |cell| {
        const next_value = value.dup();
        try cell.setVarRefValue(ctx.runtime, next_value);
        return true;
    }
    const next_value = value.dup();
    errdefer next_value.free(ctx.runtime);
    const old_value = refs.*[index];
    refs.*[index] = next_value;
    old_value.free(ctx.runtime);
    return true;
}

pub fn qjsErrorCaptureStackTrace(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 1 or !args[0].isObject()) return exception_ops.throwTypeErrorMessage(ctx, global, "not an object");
    const target = try property_ops.expectObject(args[0]);
    const skip_name = if (args.len >= 2 and isCallableValue(args[1]))
        try exception_ops.functionNameBytes(ctx.runtime, args[1])
    else
        null;
    defer if (skip_name) |bytes| ctx.runtime.memory.allocator.free(bytes);
    const stack_value = try error_stack_ops.buildErrorStackValue(ctx, output, global, args[0], skip_name);
    defer stack_value.free(ctx.runtime);
    try object_ops.defineDataProperty(ctx.runtime, target, "stack", stack_value, true, false, true);
    return core.JSValue.undefinedValue();
}

pub fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
