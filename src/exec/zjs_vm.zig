//! QuickJS-aligned VM dispatcher for bytecode produced by
//! `parser.zig`, tracked by the current semantic
//! alignment plans.
//!
//! This is the only VM dispatcher after the parser-rewrite M2 swap.
//!
//! The dispatcher handles QuickJS-format opcodes emitted by the parser after
//! the bytecode pipeline has removed temporary opcodes.

const builtin = @import("builtin");
const atomics_ops = @import("atomics_ops.zig");
const std = @import("std");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const call_mod = @import("call.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");
const vm_call = @import("vm_opcodes.zig");
const object_ops = @import("object_ops.zig");
const exception_ops = @import("exception_ops.zig");
const exceptions = @import("exception_ops.zig");
const vm_gen_async = @import("vm_opcodes.zig");
const inline_calls = @import("inline_calls.zig");
const active_invocation_trace = if (core.runtime.value_root_frames_enabled)
    @import("inline_calls.zig")
else
    struct {};
const vm_property_globals = @import("vm_property.zig");
const call_runtime = @import("call_runtime.zig");
const tailcall_dispatch = @import("tailcall_dispatch.zig");
const array_ops = @import("array_ops.zig");
const promise_ops = @import("promise_ops.zig");
const HostError = exceptions.HostError;

/// Execute QuickJS-format bytecode.
pub fn run(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
) !core.JSValue {
    return runWithOutput(ctx, stack, function, null);
}

pub fn runWithOutput(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    output: ?*std.Io.Writer,
) !core.JSValue {
    // Modules keep their explicit owner/state machine. Every ordinary FB,
    // including a borrowed embedding/test input, enters through a real root
    // function object. A borrowed caller duplicates at this outer boundary;
    // the closure2 attach itself still consumes exactly one owned reference
    // without an internal dup/free round trip.
    if (!function.isModule()) {
        const realm = function.realmContext() orelse return error.InvalidBuiltinRegistry;
        const global_object = try contextGlobal(realm);
        const owned_function = core.JSValue.functionBytecode(@constCast(&function.header));
        var root_function_value = try object_ops.createRootBytecodeFunctionObject(
            realm,
            global_object,
            owned_function,
            .root_global,
        );
        var root_frame = core.runtime.rootValues(.{&root_function_value});
        root_frame.activate(ctx.runtime);
        defer root_frame.deactivate(ctx.runtime);
        const root_function_object = object_ops.functionObjectFromValue(root_function_value) orelse return error.InvalidBytecode;
        const this_value = if (function.runtimeStrictMode()) core.JSValue.undefinedValue() else global_object.value();
        return runWithCallEnv(.{
            .ctx = realm,
            .stack = stack,
            .function = function,
            .initial_this_value = this_value,
            .var_refs = root_function_object.functionCaptures(),
            .output = output,
            .global = global_object,
            .strict_unresolved_get_var = function.isStrictMode(),
            .current_function_value = root_function_value,
            .direct_eval_vars_reach_global = true,
        }) catch |err| {
            if (!realm.preserve_uncaught_exception and err != error.JSException and err != error.Interrupted and realm.hasException()) realm.clearException();
            return err;
        };
    }

    const global_object = try contextGlobal(ctx);
    const this_value = if (function.isModule() or function.runtimeStrictMode()) core.JSValue.undefinedValue() else global_object.value();
    return runWithArgs(.{
        .ctx = ctx,
        .stack = stack,
        .function = function,
        .initial_this_value = this_value,
        .output = output,
        .global = global_object,
        .break_var_ref_cycles_on_exit = true,
    });
}

/// Lazily build and cache the per-context global object. Subsequent
/// eval calls reuse this object, matching QuickJS semantics where
/// `JS_Eval` shares the per-context globals across invocations.
/// Building the global object eagerly installs every standard
/// constructor (Object, Array, String, ..., 43 specs and ~362
/// methods) plus generic host helpers such as `print` and `console`;
/// keeping it cached avoids paying that cost on every eval call.
/// Register-only fast arm of `contextGlobal` for the embedder call path: a
/// live context's global needs no bootstrap check.
pub inline fn contextGlobalFast(ctx: *core.JSContext) !*core.Object {
    if (ctx.global) |existing| {
        if (ctx.isLive()) return existing;
    }
    return contextGlobal(ctx);
}

pub fn contextGlobal(ctx: *core.JSContext) !*core.Object {
    if (ctx.global) |existing| {
        if (!ctx.isLive()) try ctx.publishLive();
        return existing;
    }
    const global_object = try core.Object.createWithOwnPropertyCapacity(
        ctx.runtime,
        core.class.ids.global_object,
        null,
        call_mod.contextGlobalOwnPropertyCapacity(ctx.runtime),
    );
    _ = try global_object.ensureGlobalPayload(ctx.runtime);
    // Associate the global while the Realm remains construction-only. Bootstrap
    // accessors can resolve that private association, but public Runtime/GC
    // traversal cannot observe it until finishConstruction's commit below.
    ctx.global = global_object;
    errdefer {
        ctx.rollbackIntrinsicBootstrap();
        ctx.global = null;
    }
    try call_mod.installEngineGlobals(ctx, global_object);
    _ = try throwTypeErrorIntrinsicForGlobal(ctx.runtime, global_object);
    if (ctx.preallocated_oom_error == null) {
        // Preallocate the out-of-memory catch value while the heap still has
        // room; when a memory limit is later exhausted, the catch machinery
        // can throw this object without allocating (QuickJS analogue).
        // Stack-less by design (the documented exemption on
        // `createNamedErrorWithoutStack`): a backtrace captured here would
        // describe startup, and the exhausted-heap delivery path
        // (`tryCatchInFrame`) must not allocate one.
        ctx.preallocated_oom_error = exception_ops.createPreallocatedOutOfMemoryError(
            ctx.runtime,
            global_object,
        ) catch null;
    }
    const next_eval = try global_object.getProperty(core.atom.predefinedId("eval", .string).?);
    ctx.eval_function = next_eval;
    try ctx.finishConstruction();
    return global_object;
}

/// Embedder/test entry: run `env.function` as a root with explicit args and
/// captures. Only the ctx/stack/function/this/args/var_refs/output/global
/// and the three exit-behaviour flags of `env` are consulted; the remaining
/// fields are owned by the canonical root builder.
pub fn runWithArgs(env: CallEnv) !core.JSValue {
    const ctx = env.ctx;
    const result = if (!env.function.isModule())
        runCanonicalRootWithArgs(env)
    else
        runWithCallEnv(env);
    return result catch |err| {
        if (!ctx.preserve_uncaught_exception and err != error.JSException and err != error.Interrupted and ctx.hasException()) ctx.clearException();
        return err;
    };
}

const SuppliedRootCaptures = struct {
    cells: []const *core.VarRef,
};

fn resolveSuppliedRootCapture(
    opaque_context: ?*anyopaque,
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.FunctionBytecode,
    index: usize,
    cv: bytecode.function_bytecode.BytecodeClosureVar,
) HostError!*core.VarRef {
    _ = ctx;
    _ = global;
    _ = function;
    _ = cv;
    const supplied: *SuppliedRootCaptures = @ptrCast(@alignCast(opaque_context orelse return error.InvalidBytecode));
    if (index >= supplied.cells.len) return error.InvalidBytecode;
    return supplied.cells[index];
}

/// Compatibility entry for embedders/tests that execute a borrowed canonical
/// FB with explicit args/captures. It now constructs the same real root
/// function/current-function used by parser.Result consumers; the bare-frame
/// cell builder remains reachable only through the W1e legacy adapter.
fn runCanonicalRootWithArgs(env: CallEnv) HostError!core.JSValue {
    const ctx = env.ctx;
    const function = env.function;
    const var_refs = env.var_refs;
    const realm = function.realmContext() orelse return error.InvalidBuiltinRegistry;
    const realm_global = realm.global orelse return error.InvalidBuiltinRegistry;
    if (realm.runtime != ctx.runtime or realm_global != env.global) return error.InvalidBuiltinRegistry;
    if (var_refs.len != 0 and var_refs.len != function.closureVar().len) return error.InvalidBytecode;

    var supplied = SuppliedRootCaptures{ .cells = var_refs };
    const capture_source: object_ops.ClosureCaptureSource = if (var_refs.len == 0)
        .root_global
    else
        .{ .custom = .{
            .context = @ptrCast(&supplied),
            .resolve = resolveSuppliedRootCapture,
        } };
    const owned_function = core.JSValue.functionBytecode(@constCast(&function.header));
    var root_function_value = try object_ops.createRootBytecodeFunctionObject(
        realm,
        realm_global,
        owned_function,
        capture_source,
    );
    var root_frame = core.runtime.rootValues(.{&root_function_value});
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);
    const root_object = object_ops.functionObjectFromValue(root_function_value) orelse return error.InvalidBytecode;

    return runWithCallEnv(.{
        .ctx = realm,
        .stack = env.stack,
        .function = function,
        .initial_this_value = env.initial_this_value,
        .args = env.args,
        .var_refs = root_object.functionCaptures(),
        .output = env.output,
        .global = realm_global,
        .break_var_ref_cycles_on_exit = env.break_var_ref_cycles_on_exit,
        .strict_unresolved_get_var = env.strict_unresolved_get_var,
        .stop_on_yield = env.stop_on_yield,
        .current_function_value = root_function_value,
        .direct_eval_vars_reach_global = true,
    });
}

const argumentsNeedsOriginalSnapshot = frame_mod.argumentsNeedsOriginalSnapshot;

/// Per-invocation interpreter entry state. Replaces the former 30-parameter
/// `runWithArgsState` surface; eval/generator/module-await flags live here.
pub const PreparedEntryFrame = struct {
    slab: frame_mod.FrameSlab,
    need_original_args: bool,
};

pub const CallEnv = struct {
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    initial_this_value: core.JSValue = core.JSValue.undefinedValue(),
    args: []const core.JSValue = &.{},
    var_refs: []const *core.VarRef = &.{},
    output: ?*std.Io.Writer = null,
    global: *core.Object,
    break_var_ref_cycles_on_exit: bool = false,
    strict_unresolved_get_var: bool = false,
    stop_on_yield: bool = false,
    generator_state: ?*core.Object = null,
    resume_value: ?core.JSValue = null,
    stop_before_pc: ?usize = null,
    current_function_value: core.JSValue = core.JSValue.undefinedValue(),
    new_target_value: core.JSValue = core.JSValue.undefinedValue(),
    eval_global_var_bindings: bool = false,
    /// Invocation-root variable-environment fact inherited by a direct eval.
    /// Unlike `eval_global_var_bindings`, this is true for ordinary scripts
    /// but false in nested ordinary function calls.
    direct_eval_vars_reach_global: bool = false,
    is_eval_code: bool = false,
    /// The real root function object already completed closure2 pass 1 and
    /// installed its final GLOBAL_DECL cells. Legacy bare-root entries leave
    /// this false and perform both steps inside runWithArgsState.
    suspend_on_module_await: bool = false,
    initial_pc: usize = 0,
    prepared_entry_frame: ?*const PreparedEntryFrame = null,
    /// The surrounding bytecode call machinery already performed and owns
    /// the caller-Realm stack preflight/accounting guard.
    call_depth_precharged: bool = false,
    /// Mirrors JS_CALL_FLAG_COPY_ARGV for standalone/C-API-style entries.
    /// Inline opcode calls always use the default flags=0 contract.
    copy_argv: bool = false,
};

/// Keep the realm global at a fixed address for the length of an invocation.
///
/// The interpreter carries `global` as a bare pointer and reads it from 113
/// places, none of which is a root the collector can rewrite. Threading a slot
/// through all of them is the right end state (T6); until then, one pin at the
/// entry buys the same guarantee for the whole invocation. It costs a hash
/// operation only while the copying young generation is on, and only until the
/// global's first promotion, after which it is not in the nursery at all.
fn pinGlobalForInvocation(env: CallEnv) ?*core.Object {
    const rt = env.ctx.runtime;
    if (!rt.gc.nursery.enabled) return null;
    if (!core.gc.Registry.isNurseryHeader(env.global.gcHeader())) return null;
    rt.gc.pins.pin(rt, env.global.gcHeader()) catch return null;
    return env.global;
}

fn unpinGlobalForInvocation(env: CallEnv, pinned: ?*core.Object) void {
    const object = pinned orelse return;
    env.ctx.runtime.gc.pins.unpin(object.gcHeader());
}

pub fn runWithCallEnv(env: CallEnv) HostError!core.JSValue {
    const pinned_global = pinGlobalForInvocation(env);
    defer unpinGlobalForInvocation(env, pinned_global);
    if (env.generator_state != null and !env.call_depth_precharged) {
        // async_func_resume performs js_check_stack_overflow(rt, 0) before
        // its inner JS_CallInternal poll. Cover generator/async/module
        // resident entries that do not already carry an outer guard.
        var precharged = env;
        precharged.global = env.ctx.global orelse env.global;
        const call_depth_guard = try vm_call.enterCallDepth(
            precharged.ctx,
            precharged.global,
            0,
        );
        defer call_depth_guard.deinit();
        try exception_ops.pollInterrupt(precharged.ctx, precharged.global);
        precharged.call_depth_precharged = true;
        return runWithCallEnvAfterInterruptPoll(precharged);
    }
    try exception_ops.pollInterrupt(env.ctx, env.global);
    return runWithCallEnvAfterInterruptPoll(env);
}

/// Final bytecode entry after its caller-side `JS_CallInternal` poll has
/// already completed. This named boundary prevents cross-Realm calls from
/// charging both caller and callee before the body starts.
pub fn runWithCallEnvAfterInterruptPoll(env: CallEnv) HostError!core.JSValue {
    // QuickJS performs the bytecode-frame stack guard in the caller Realm
    // immediately after the caller-side interrupt poll, and only then switches
    // to b->realm. Keep both the error prototype and precedence identical.
    // Generator/async execution uses the heap-resident JSAsyncFunctionState
    // frame from its first parameter-init run onward. QuickJS checks native
    // SP with alloca_size=0 for both that initial resume and later resumes.
    const planned_stack_bytes = if (env.generator_state != null)
        0
    else
        vm_call.bytecodeFrameAllocaSize(
            env.function,
            env.args.len,
            env.copy_argv,
        );
    var call_depth_guard: ?vm_call.CallDepthGuard = null;
    if (!env.call_depth_precharged) {
        call_depth_guard = try vm_call.enterCallDepth(
            env.ctx,
            env.global,
            planned_stack_bytes,
        );
    }
    defer if (call_depth_guard) |guard| guard.deinit();

    var effective = env;
    if (env.function.realmContext()) |realm| {
        // Canonical FunctionBytecode carries its publication RealmRef. Switch
        // only after caller-side Bound/Proxy work, interrupt poll, and planned
        // stack guard, matching qjs `ctx = b->realm`.
        effective.ctx = realm;
        effective.global = realm.global orelse return error.InvalidBuiltinRegistry;
    }
    return runWithArgsState(effective);
}

fn runWithArgsState(env: CallEnv) HostError!core.JSValue {

    // Ordinary canonical entry always has the real function object built by
    // closure2. Generator/async execution may instead carry its explicit
    // resident state.
    if (env.generator_state == null and
        env.current_function_value.is(.undefined_value)) return error.InvalidBytecode;

    // Frame storage (locals/env.args/env.var_refs) may be carved from the VM stack
    // arena; reclaim the watermark after the frame has released its values.
    const frame_arena_mark = env.ctx.runtime.vm_stack.mark();
    defer env.ctx.runtime.vm_stack.restore(frame_arena_mark);

    const resident_binding_shell = env.generator_state != null;
    var frame_storage = if (resident_binding_shell) blk: {
        // Generator/async functions are not constructors; arrow new.target is
        // an ordinary capture. A resident shell therefore never needs the cold
        // new-target slot moved out of the hot Frame header.
        std.debug.assert(env.new_target_value.is(.undefined_value));
        break :blk frame_mod.Frame.initResidentExecution(
            env.function,
            env.initial_this_value,
            env.current_function_value,
            env.generator_state.?.generatorActualArgCount(),
        );
    } else frame_mod.Frame.init(env.function);
    defer {
        // This collection fires while engine native frames are live — most
        // importantly while the invocation's RETURN VALUE is held only by
        // native locals on its way out. The tracing collector must scan
        // engine-active here (conservative in test builds too), or a precise
        // sweep reclaims the value being returned (watchpoint-proven: the
        // constructed Map was destroyFromHeader'd by this very collection).
        // Runtime teardown and host-explicit cycle removal keep the
        // declared-roots contract; this exit seam is the engine-active case.
        if (env.break_var_ref_cycles_on_exit)
            _ = env.ctx.runtime.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {};
    }
    defer {
        if (env.generator_state == null or !frame_storage.isEmptyResidentExecutionShell()) {
            frame_storage.deinit(env.ctx.runtime.nativeAllocator(), env.ctx.runtime);
        }
    }
    var catch_target_storage: ?usize = null;
    var l0_state = inline_calls.L0State{
        .level = .{
            .frame = &frame_storage,
            .stack = env.stack,
            .catch_target = &catch_target_storage,
        },
        .eval_global_var_bindings = env.eval_global_var_bindings,
        .direct_eval_vars_reach_global = env.direct_eval_vars_reach_global,
        .is_eval_code = env.is_eval_code,
        .strict_unresolved_get_var = env.strict_unresolved_get_var,
        .generator_state = env.generator_state,
        .stop_on_yield = env.stop_on_yield,
        .stop_before_pc = env.stop_before_pc,
        .suspend_on_module_await = env.suspend_on_module_await,
    };
    // Construct Machine at its final address before publishing either borrowed
    // execution authority. Machine must not move until both scopes are gone.
    var machine = inline_calls.Machine.init(env.ctx, env.output, env.global, &l0_state);
    var root_backtrace_view = inline_calls.MachineBacktraceView.root(&machine);
    var active_backtrace_frame = core.ActiveBacktraceFrame{
        .data = &root_backtrace_view,
        .resolver = inline_calls.resolveMachineBacktraceView,
    };
    env.ctx.pushActiveBacktraceFrame(&active_backtrace_frame);
    defer env.ctx.popActiveBacktraceFrame(&active_backtrace_frame);

    var invocation = inline_calls.ActiveInvocation{
        .machine = &machine,
        .current_backtrace_view = &root_backtrace_view,
    };
    if (comptime core.runtime.value_root_frames_enabled) {
        invocation.header = .{ .traceRoots = active_invocation_trace.traceRoots };
        invocation.previous = inline_calls.activeInvocation(env.ctx.runtime);
    }
    const previous_invocation = env.ctx.runtime.active_invocation;
    env.ctx.runtime.active_invocation = &invocation;
    defer env.ctx.runtime.active_invocation = previous_invocation;
    // Register last so inline frames are drained while both the invocation
    // authority and its backtrace view remain observable.
    defer machine.deinit();

    if (env.generator_state == null) {
        try frame_storage.initCallBindings(env.ctx.runtime, .{
            .initial_this_value = env.initial_this_value,
            .current_function_value = env.current_function_value,
            .new_target_value = env.new_target_value,
        });
    }
    // A generator/async resume with a resident frame immediately frees any slab built
    // here and swaps in the generator's PRESERVED buffers (vm_gen_async.zig), so
    // allocating + initializing a throwaway slab + re-duping env.args + rebuilding env.var_refs is
    // pure waste — qjs allocates the generator frame ONCE at creation and resumes on it
    // (JS_CALL_FLAG_GENERATOR early-out, quickjs.c). `has_frame`, not pc, is the
    // discriminator: internal marker-less generators have a valid resident frame at pc 0.
    //
    // The unmapped `arguments` snapshot is also creation-only. If the bytecode can observe
    // `arguments`, its prologue materializes that object before the first suspension and
    // parks it in the hidden arguments local, which is part of the preserved locals window.
    // Rebuilding `original_args` on every started resume therefore created a second snapshot
    // only for resumeExecutionStateRaw to release it immediately. The preserved buffers cover
    // locals/env.args/env.var_refs for every started resume; the only remaining initArguments env.output
    // is the mapped-arguments count (frame.args is already the preserved buffer), which we
    // set directly — identical to what initArguments would store (`actual_arg_count = env.args.len`).
    const skip_resume_slab = if (env.generator_state) |gen| gen.generatorExecutionState().has_frame else false;
    if (!skip_resume_slab) {
        try initFreshEntryFrame(env.ctx, env.stack, env.function, &frame_storage, env.args, env.var_refs, env.generator_state, env.prepared_entry_frame);
    }

    frame_storage.pc = env.initial_pc;
    const resume_state = try vm_gen_async.resumeExecutionState(env.ctx, env.stack, env.function, &frame_storage, env.generator_state, env.resume_value);
    // If execution completes or fails, clear the payload's non-owning aliases
    // before the live Frame/Stack defers release their buffers. A yield/await
    // republished ownership already, so this is a no-op on suspension.
    defer vm_gen_async.finishExecutionStateRun(env.ctx.runtime, env.stack, &frame_storage, env.generator_state);
    // A parked frame already passed this full-capacity guard on its creation
    // run, and GeneratorExecutionState retains (or grows) that same backing.
    // QuickJS likewise resumes its preallocated stack directly.
    if (!skip_resume_slab) try reserveEntryFrameCapacity(env.stack, env.function);
    catch_target_storage = try vm_gen_async.completeResumeState(env.ctx, env.output, env.global, env.stack, env.function, &frame_storage, resume_state, env.resume_value);
    // Markerless internal generator bytecode has no OP_initial_yield boundary to
    // execute toward. Park its fully initialized frame before dispatch at pc 0.
    if (env.stop_before_pc) |stop_pc| {
        if (frame_storage.pc == stop_pc) {
            if (try vm_gen_async.stopBeforePc(env.ctx, env.stack, &frame_storage, env.generator_state, catch_target_storage, stop_pc)) |stopped| return stopped;
        }
    }

    while (true) {
        runTC(&machine) catch |err| {
            // The error escaped the current frame without an in-frame
            // handler. Unwind suspended inline frames (mirroring how the
            // error would propagate through the recursive call chain) and
            // resume the loop when an outer frame catches it.
            if (machine.depth > 0 and try machine.unwindForError(env.global, err)) continue;
            return err;
        };
        return machine.vm.return_value;
    }
}

/// First-entry-only frame/slab construction. A resumed generator already owns
/// all of these windows in its execution state, so keeping this allocation and
/// partitioning state in `runWithArgsState` needlessly enlarged every resume's
/// native stack frame. Keep the cold setup out of line while both paths still
/// join the single interpreter entry below.
noinline fn initFreshEntryFrame(
    ctx: *core.JSContext,
    entry_stack: *stack_mod.Stack,
    entry_function: *const bytecode.FunctionBytecode,
    frame_storage: *frame_mod.Frame,
    args: []const core.JSValue,
    var_refs: []const *core.VarRef,
    entry_generator_state: ?*core.Object,
    entry_prepared_frame: ?*const PreparedEntryFrame,
) HostError!void {
    const use_inline_frame_storage = entry_generator_state == null and !entry_function.isGenerator() and !entry_function.isAsync();
    const frame_arena: ?*core.VmStackArena = if (use_inline_frame_storage) &ctx.runtime.vm_stack else null;
    const need_original_args = if (entry_prepared_frame) |prepared|
        prepared.need_original_args
    else
        argumentsNeedsOriginalSnapshot(entry_function);
    const frame_arg_count = if (entry_prepared_frame) |prepared|
        prepared.slab.args.len
    else
        frame_mod.frameArgCount(entry_function, args.len);
    const open_var_ref_count = if (entry_prepared_frame) |prepared|
        prepared.slab.open_var_refs.len
    else
        frame_mod.frameOpenVarRefStorageCount(entry_function);
    const resident_frame_storage: []core.JSValue = if (entry_prepared_frame) |prepared|
        prepared.slab.storage
    else if (entry_generator_state) |generator|
        generator.generatorCombinedFrameStorage()
    else
        &.{};
    const stack_count = if (entry_stack.capacity == 0)
        @as(usize, entry_function.stack_size) + 1
    else
        0;
    const slab_layout: frame_mod.SlabLayout = .{
        .args = frame_arg_count,
        .original_args = frame_mod.originalArgCount(args.len, need_original_args),
        .locals = entry_function.var_count,
        .var_refs = frame_mod.frameVarRefStorageCount(entry_function, var_refs),
        .open_var_refs = open_var_ref_count,
    };
    const slab = if (entry_prepared_frame) |prepared| blk: {
        frame_storage.installResidentStorage(prepared.slab.storage);
        break :blk prepared.slab;
    } else if (resident_frame_storage.len != 0) blk: {
        const windows = frame_mod.FrameSlab.partition(resident_frame_storage, slab_layout);
        frame_storage.installResidentStorage(resident_frame_storage);
        break :blk windows;
    } else if (frame_arena) |arena| blk: {
        // The arena slab carries the operand stack; a heap fallback keeps it
        // separate (`.stack = 0`), as in the arena-less entry below.
        var arena_layout = slab_layout;
        arena_layout.stack = stack_count;
        if (frame_mod.FrameSlab.carve(ctx.runtime, arena, arena_layout)) |windows| break :blk windows;
        const heap_windows = try frame_mod.FrameSlab.allocHeap(ctx.runtime.nativeAllocator(), slab_layout);
        frame_storage.installOwnedStorage(heap_windows.storage);
        break :blk heap_windows;
    } else blk: {
        const heap_windows = try frame_mod.FrameSlab.allocHeap(ctx.runtime.nativeAllocator(), slab_layout);
        frame_storage.installOwnedStorage(heap_windows.storage);
        break :blk heap_windows;
    };
    const frame_windows = frame_mod.FrameStorageWindows{
        .args = if (slab.args.len != 0) slab.args else null,
        .original_args = if (slab.original_args.len != 0) slab.original_args else null,
        .locals = if (slab.locals.len != 0) slab.locals else null,
        .var_refs = if (slab.var_refs.len != 0) slab.var_refs else null,
        .open_var_refs = if (slab.open_var_refs.len != 0) slab.open_var_refs else null,
    };
    if (entry_stack.capacity == 0 and slab.stack.len != 0) {
        entry_stack.* = stack_mod.Stack.initFrameWindow(ctx.runtime, ctx.runtime.vm_stack_frame_storage, slab.stack);
    }
    try vm_call.initFrameLocals(ctx, entry_function, frame_storage, use_inline_frame_storage, frame_windows);
    try frame_storage.initArguments(ctx.runtime, frame_arena, args, need_original_args, frame_windows);
    if (frame_windows.open_var_refs) |open_refs| try frame_storage.installOpenVarRefSlots(open_refs) else if (open_var_ref_count != 0) try frame_storage.ensureOpenVarRefSlots(ctx.runtime, frame_arena);
    try vm_call.initFrameVarRefs(ctx, entry_function, frame_storage, var_refs, use_inline_frame_storage, frame_windows);
}

/// Tail-call dispatcher entry: publish the Machine's current level into its
/// resident `Vm` (native-boundary design section 6.2) and run the handler
/// chain. Only the per-level fields are written here; `ctx/rt/global/output`
/// and the resident handler tables were set when the Machine was created or
/// re-targeted, and outcome/property payloads are published by their
/// consumers before being read.
fn runTC(m: *inline_calls.Machine) HostError!void {
    const level = m.currentLevel();
    const func = level.function();
    const vm = &m.vm;
    std.debug.assert(vm.ctx == m.ctx and vm.rt == m.ctx.runtime and vm.global == m.global);
    vm.machine = m;
    vm.function = func;
    // The Vm is Machine-resident: a stale `prop_sites` mirror from the
    // previous function would alias its cache sites by index (the hit arm
    // does not re-check the atom), so every `function` publish carries it.
    vm.publishPropSites(func);
    vm.frame = level.frame;
    vm.stack = level.stack;
    vm.code_base = func.byteCode().ptr;
    vm.catch_target = level.catch_target;
    return tailcall_dispatch.runDispatchLoop(vm);
}

/// Drive a callback Entry on an already-active Machine until its
/// `.native_boundary` continuation returns control to the native builtin.
/// Errors may be caught within the callback segment; an uncaught error is
/// bounded at the fence and returned without consulting the suspended outer
/// bytecode frame.
pub inline fn runActiveInvocationUntilNativeBoundary(
    invocation: *inline_calls.ActiveInvocation,
    scope: anytype,
) HostError!void {
    const machine = invocation.machine;
    const fence_depth = scope.fenceDepth();
    std.debug.assert(machine.depth > fence_depth);
    runTC(machine) catch |err|
        return runActiveInvocationAfterNativeBoundaryError(machine, fence_depth, scope.expectedTop(), err);
    std.debug.assert(machine.depth == fence_depth);
    std.debug.assert(scope.expectedTop() == null or machine.top == scope.expectedTop());
}

/// `runActiveInvocationUntilNativeBoundary` for an Entry the caller just
/// pushed: the per-level fields are published from the pusher's registers
/// instead of being re-derived through the Machine.
pub inline fn runPushedEntryUntilNativeBoundary(
    invocation: *inline_calls.ActiveInvocation,
    scope: anytype,
    entry: *inline_calls.Entry,
    target: *const inline_calls.InlineTarget,
) HostError!void {
    const machine = invocation.machine;
    const fence_depth = scope.fenceDepth();
    std.debug.assert(machine.depth > fence_depth);
    const vm = &machine.vm;
    std.debug.assert(vm.ctx == machine.ctx and vm.rt == machine.ctx.runtime and vm.global == machine.global);
    // A fresh frame starts at pc 0: the first opcode is at `code_base`,
    // which the publication hands back in a register.
    const entry_pc = vm.publishPushedEntry(machine, entry, target);
    tailcall_dispatch.runDispatchLoopPublished(vm, entry_pc) catch |err|
        return runActiveInvocationAfterNativeBoundaryError(machine, fence_depth, scope.expectedTop(), err);
    std.debug.assert(machine.depth == fence_depth);
    std.debug.assert(scope.expectedTop() == null or machine.top == scope.expectedTop());
}

/// Callback throws are uncommon but require the complete bounded-unwind loop.
/// Keep that machinery out of the successful synchronous-return driver so a
/// short callback pays one `runTC` call and one outcome check.
noinline fn runActiveInvocationAfterNativeBoundaryError(
    machine: *inline_calls.Machine,
    fence_depth: usize,
    expected_top: ?*inline_calls.Entry,
    initial_err: HostError,
) HostError!void {
    var pending_err = initial_err;
    while (true) {
        if (machine.depth <= fence_depth or
            !try machine.unwindForErrorToDepth(
                machine.global,
                fence_depth,
                pending_err,
            ))
        {
            std.debug.assert(machine.depth == fence_depth);
            std.debug.assert(expected_top == null or machine.top == expected_top);
            return pending_err;
        }
        runTC(machine) catch |err| {
            pending_err = err;
            continue;
        };
        std.debug.assert(machine.depth == fence_depth);
        std.debug.assert(expected_top == null or machine.top == expected_top);
        return;
    }
}

fn reserveEntryFrameCapacity(entry_stack: *stack_mod.Stack, entry_function: *const bytecode.FunctionBytecode) !void {
    const frame_stack_size: usize = if (comptime builtin.mode == .Debug)
        // Some colocated tests hand-build bytecode without running finalize's
        // stack-size pass. Keep those Debug-only fixtures checked at entry;
        // ReleaseFast relies on finalized bytecode's verified stack_size.
        if (entry_function.stack_size == 0 and entry_function.byteCode().len != 0)
            entry_function.byteCode().len
        else
            entry_function.stack_size
    else
        entry_function.stack_size;
    try entry_stack.reserveFrameCapacity(frame_stack_size);
}

// ---- Helpers ----
// ---- Shared helper aliases ----
pub const arraySortCall = array_ops.arraySortCall;
pub const arrayByCopyCall = array_ops.arrayByCopyCall;
pub const drainPendingPromiseJobs = promise_ops.drainPendingPromiseJobs;
pub const cleanupAtomicsWaitersForContext = atomics_ops.cleanupAtomicsWaitersForContext;
const throwTypeErrorIntrinsicForGlobal = call_runtime.throwTypeErrorIntrinsicForGlobal;
pub const getValueProperty = object_ops.getValueProperty;

// `engine eval host globals and throw intrinsic tear down cleanly` was relocated
// to `tests/exec.zig` in Phase 6b-3 STEP 7B: it bootstraps a bare runtime's
// standard globals through `rt.installStandardGlobals`, with the installer
// registered through the runtime bootstrap seam.
