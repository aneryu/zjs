//! QuickJS-aligned VM dispatcher for bytecode produced by
//! `parser.zig`, tracked by the current semantic
//! alignment plans.
//!
//! This is the only VM dispatcher after the parser-rewrite M2 swap.
//!
//! The dispatcher handles QuickJS-format opcodes emitted by the parser after
//! the bytecode pipeline has removed temporary opcodes.

const builtin = @import("builtin");
const std = @import("std");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const parser = @import("../parser.zig");
const call_mod = @import("call.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");
const call_vm = @import("vm_call.zig");
const class_vm = @import("object_ops.zig");
const exception_ops = @import("vm_exception_ops.zig");
const exceptions = @import("exceptions.zig");
const gen_async_vm = @import("vm_gen_async.zig");
const inline_calls = @import("inline_calls.zig");
const vm_property_globals = @import("vm_property_globals.zig");
const call_runtime = @import("call_runtime.zig");
const tailcall_dispatch = @import("tailcall_dispatch.zig");
comptime {
    _ = tailcall_dispatch;
}
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
    // Modules keep their explicit legacy owner/state machine until W1e. Every
    // canonical ordinary FB, including a borrowed embedding/test input, enters
    // through a real root function object. A borrowed caller duplicates at this
    // outer boundary; the closure2 attach itself still consumes exactly one
    // owned reference without an internal dup/free round trip.
    if (!function.isModule() and function.legacyBytecodeAdapter() == null) {
        const realm = function.realmContext() orelse return error.InvalidBuiltinRegistry;
        const global_object = try contextGlobal(realm);
        const owned_function = core.JSValue.functionBytecode(@constCast(&function.header)).dup();
        var root_function_value = try class_vm.createRootBytecodeFunctionObject(
            realm,
            global_object,
            owned_function,
            .root_global,
        );
        defer root_function_value.free(ctx.runtime);
        var root_values = [_]core.runtime.ValueRootValue{
            .{ .value = &root_function_value },
        };
        const root_frame = core.runtime.ValueRootFrame{
            .previous = ctx.runtime.active_value_roots,
            .values = &root_values,
        };
        ctx.runtime.active_value_roots = &root_frame;
        defer ctx.runtime.active_value_roots = root_frame.previous;
        const root_function_object = class_vm.functionObjectFromValue(root_function_value) orelse return error.InvalidBytecode;
        const this_value = if (function.runtimeStrictMode()) core.JSValue.undefinedValue() else global_object.value();
        return runWithCallEnv(.{
            .ctx = realm,
            .stack = stack,
            .function = function,
            .initial_this_value = this_value,
            .var_refs = root_function_object.functionCaptures(),
            .output = output,
            .global = global_object,
            .break_var_ref_cycles_on_exit = true,
            .strict_unresolved_get_var = function.isStrictMode(),
            .current_function_value = root_function_value,
            .direct_eval_vars_reach_global = true,
            .global_declarations_prevalidated = true,
        }) catch |err| {
            if (!realm.preserve_uncaught_exception and err != error.JSException and err != error.Interrupted and realm.hasException()) realm.clearException();
            return err;
        };
    }

    const global_object = try contextGlobal(ctx);
    const this_value = if (function.isModule() or function.runtimeStrictMode()) core.JSValue.undefinedValue() else global_object.value();
    return runWithArgs(ctx, stack, function, this_value, &.{}, &.{}, output, global_object, true, false, false);
}

pub fn runWithOutputAndVarRefs(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    output: ?*std.Io.Writer,
    var_refs: []const *core.VarRef,
) !core.JSValue {
    const global_object = try contextGlobal(ctx);
    const this_value = if (function.isModule() or function.runtimeStrictMode()) core.JSValue.undefinedValue() else global_object.value();
    return runWithArgs(ctx, stack, function, this_value, &.{}, var_refs, output, global_object, false, false, false);
}

/// QuickJS module linking invokes the same module bytecode used for normal
/// evaluation, but with `this === true`. The compiler-emitted entry gate runs
/// only declaration instantiation and returns before the module body.
pub fn runModuleInstantiationWithVarRefs(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    var_refs: []const *core.VarRef,
) !core.JSValue {
    if (!function.isModule()) return error.InvalidBytecode;
    const global_object = try contextGlobal(ctx);
    return runWithArgs(
        ctx,
        stack,
        function,
        core.JSValue.boolean(true),
        &.{},
        var_refs,
        null,
        global_object,
        false,
        false,
        false,
    );
}

pub fn runModuleWithOutputAndVarRefsState(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    output: ?*std.Io.Writer,
    var_refs: []const *core.VarRef,
    module_state: *core.Object,
    resume_value: ?core.JSValue,
) !core.JSValue {
    return runModuleWithOutputAndVarRefsStateAtPc(ctx, stack, function, output, var_refs, module_state, resume_value, 0);
}

pub fn runModuleWithOutputAndVarRefsStateAtPc(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    output: ?*std.Io.Writer,
    var_refs: []const *core.VarRef,
    module_state: *core.Object,
    resume_value: ?core.JSValue,
    initial_pc: usize,
) !core.JSValue {
    const global_object = try contextGlobal(ctx);
    // Module continuations use caller-owned standalone stack storage. Finalize
    // their execution record after the Frame unwinds; FAM-backed states must
    // instead wait for the wrapper that owns the borrowed Stack window.
    const finalize_completion = !module_state.generatorStackUsesCombinedStorage();
    defer if (finalize_completion) module_state.finalizeGeneratorExecutionCompletion(ctx.runtime);
    return runWithCallEnv(.{
        .ctx = ctx,
        .stack = stack,
        .function = function,
        .var_refs = var_refs,
        .output = output,
        .global = global_object,
        .generator_state = module_state,
        .resume_value = resume_value,
        .suspend_on_module_await = true,
        .initial_pc = initial_pc,
    });
}

/// Lazily build and cache the per-context global object. Subsequent
/// eval calls reuse this object, matching QuickJS semantics where
/// `JS_Eval` shares the per-context globals across invocations.
/// Building the global object eagerly installs every standard
/// constructor (Object, Array, String, ..., 43 specs and ~362
/// methods) plus generic host helpers such as `print` and `console`;
/// keeping it cached avoids paying that cost on every eval call.
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
    errdefer global_object.value().free(ctx.runtime);
    _ = try global_object.ensureGlobalPayload(ctx.runtime);
    // Associate the global while the Realm remains construction-only. Bootstrap
    // accessors can resolve that private association, but public Runtime/GC
    // traversal cannot observe it until finishConstruction's commit below.
    ctx.global = global_object;
    errdefer {
        ctx.rollbackIntrinsicBootstrap();
        ctx.global = null;
    }
    try call_mod.installHostGlobals(ctx.runtime, global_object);
    const thrower = try throwTypeErrorIntrinsicForGlobal(ctx.runtime, global_object);
    thrower.free(ctx.runtime);
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
    const old_eval = ctx.eval_function;
    ctx.eval_function = next_eval;
    old_eval.free(ctx.runtime);
    try ctx.finishConstruction();
    return global_object;
}

pub fn runWithArgs(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    initial_this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const *core.VarRef,
    output: ?*std.Io.Writer,
    global: *core.Object,
    break_var_ref_cycles_on_exit: bool,
    strict_unresolved_get_var: bool,
    stop_on_yield: bool,
) !core.JSValue {
    const result = if (function.legacyBytecodeAdapter() == null and !function.isModule())
        runCanonicalRootWithArgs(
            ctx,
            stack,
            function,
            initial_this_value,
            args,
            var_refs,
            output,
            global,
            break_var_ref_cycles_on_exit,
            strict_unresolved_get_var,
            stop_on_yield,
        )
    else
        runWithCallEnv(.{
            .ctx = ctx,
            .stack = stack,
            .function = function,
            .initial_this_value = initial_this_value,
            .args = args,
            .var_refs = var_refs,
            .output = output,
            .global = global,
            .break_var_ref_cycles_on_exit = break_var_ref_cycles_on_exit,
            .strict_unresolved_get_var = strict_unresolved_get_var,
            .stop_on_yield = stop_on_yield,
        });
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
    return supplied.cells[index].retain();
}

/// Compatibility entry for embedders/tests that execute a borrowed canonical
/// FB with explicit args/captures. It now constructs the same real root
/// function/current-function used by parser.Result consumers; the bare-frame
/// cell builder remains reachable only through the W1e legacy adapter.
fn runCanonicalRootWithArgs(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    initial_this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const *core.VarRef,
    output: ?*std.Io.Writer,
    global: *core.Object,
    break_var_ref_cycles_on_exit: bool,
    strict_unresolved_get_var: bool,
    stop_on_yield: bool,
) HostError!core.JSValue {
    const realm = function.realmContext() orelse return error.InvalidBuiltinRegistry;
    const realm_global = realm.global orelse return error.InvalidBuiltinRegistry;
    if (realm.runtime != ctx.runtime or realm_global != global) return error.InvalidBuiltinRegistry;
    if (var_refs.len != 0 and var_refs.len != function.closureVar().len) return error.InvalidBytecode;

    var supplied = SuppliedRootCaptures{ .cells = var_refs };
    const capture_source: class_vm.ClosureCaptureSource = if (var_refs.len == 0)
        .root_global
    else
        .{ .custom = .{
            .context = @ptrCast(&supplied),
            .resolve = resolveSuppliedRootCapture,
        } };
    const owned_function = core.JSValue.functionBytecode(@constCast(&function.header)).dup();
    var root_function_value = try class_vm.createRootBytecodeFunctionObject(
        realm,
        realm_global,
        owned_function,
        capture_source,
    );
    defer root_function_value.free(ctx.runtime);
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &root_function_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;
    const root_object = class_vm.functionObjectFromValue(root_function_value) orelse return error.InvalidBytecode;

    return runWithCallEnv(.{
        .ctx = realm,
        .stack = stack,
        .function = function,
        .initial_this_value = initial_this_value,
        .args = args,
        .var_refs = root_object.functionCaptures(),
        .output = output,
        .global = realm_global,
        .break_var_ref_cycles_on_exit = break_var_ref_cycles_on_exit,
        .strict_unresolved_get_var = strict_unresolved_get_var,
        .stop_on_yield = stop_on_yield,
        .current_function_value = root_function_value,
        .direct_eval_vars_reach_global = true,
        .global_declarations_prevalidated = true,
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
    global_declarations_prevalidated: bool = false,
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

pub fn runWithCallEnv(env: CallEnv) HostError!core.JSValue {
    if (env.generator_state != null and !env.call_depth_precharged) {
        // async_func_resume performs js_check_stack_overflow(rt, 0) before
        // its inner JS_CallInternal poll. Cover generator/async/module
        // resident entries that do not already carry an outer guard.
        var precharged = env;
        precharged.global = env.ctx.global orelse env.global;
        const call_depth_guard = try call_vm.enterCallDepth(
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
        call_vm.qjsBytecodeFrameAllocaSize(
            env.function,
            env.args.len,
            env.copy_argv,
        );
    var call_depth_guard: ?call_vm.CallDepthGuard = null;
    if (!env.call_depth_precharged) {
        call_depth_guard = try call_vm.enterCallDepth(
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
    return runWithArgsState(
        effective.ctx,
        effective.stack,
        effective.function,
        effective.initial_this_value,
        effective.args,
        effective.var_refs,
        effective.output,
        effective.global,
        effective.break_var_ref_cycles_on_exit,
        effective.strict_unresolved_get_var,
        effective.stop_on_yield,
        effective.generator_state,
        effective.resume_value,
        effective.stop_before_pc,
        effective.current_function_value,
        effective.new_target_value,
        effective.eval_global_var_bindings,
        effective.direct_eval_vars_reach_global,
        effective.is_eval_code,
        effective.global_declarations_prevalidated,
        effective.suspend_on_module_await,
        effective.initial_pc,
        effective.prepared_entry_frame,
    );
}

fn runWithArgsState(
    ctx: *core.JSContext,
    entry_stack: *stack_mod.Stack,
    entry_function: *const bytecode.FunctionBytecode,
    initial_this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const *core.VarRef,
    output: ?*std.Io.Writer,
    global: *core.Object,
    break_var_ref_cycles_on_exit: bool,
    entry_strict_unresolved_get_var: bool,
    entry_stop_on_yield: bool,
    entry_generator_state: ?*core.Object,
    resume_value: ?core.JSValue,
    entry_stop_before_pc: ?usize,
    current_function_value: core.JSValue,
    new_target_value: core.JSValue,
    entry_eval_global_var_bindings: bool,
    entry_direct_eval_vars_reach_global: bool,
    entry_is_eval_code: bool,
    entry_global_declarations_prevalidated: bool,
    entry_suspend_on_module_await: bool,
    entry_initial_pc: usize,
    entry_prepared_frame: ?*const PreparedEntryFrame,
) HostError!core.JSValue {
    const call_profile_guard = call_vm.enterCallProfile(ctx.runtime);
    defer call_profile_guard.deinit();

    // Ordinary canonical entry always has the real function object built by
    // closure2. Generator/async execution may instead carry its explicit
    // resident state, and legacy module/fixture adapters keep their W1e seam.
    if (entry_function.legacyBytecodeAdapter() == null and
        entry_generator_state == null and
        current_function_value.isUndefined()) return error.InvalidBytecode;

    // qjs js_closure2 PASS1 (quickjs.c:17280-17296): validate the complete
    // GLOBAL_DECL table before creating a single declaration cell. Direct eval
    // already ran this pass before constructing its caller-capture array.
    if (entry_function.isGlobalVar() and !entry_global_declarations_prevalidated) {
        try vm_property_globals.validateGlobalVarDeclarations(ctx, global, entry_function, entry_is_eval_code);
    }

    // Frame storage (locals/args/var_refs) may be carved from the VM stack
    // arena; reclaim the watermark after the frame has released its values.
    const frame_arena_mark = ctx.runtime.vm_stack.mark();
    defer ctx.runtime.vm_stack.restore(frame_arena_mark);

    const resident_binding_shell = entry_generator_state != null;
    var frame_storage = if (resident_binding_shell) blk: {
        // Generator/async functions are not constructors; arrow new.target is
        // an ordinary capture. A resident shell therefore never needs the cold
        // new-target slot moved out of the hot Frame header.
        std.debug.assert(new_target_value.isUndefined());
        break :blk frame_mod.Frame.initResidentExecution(
            entry_function,
            initial_this_value,
            current_function_value,
            entry_generator_state.?.generatorActualArgCount(),
        );
    } else frame_mod.Frame.init(entry_function);
    defer {
        if (break_var_ref_cycles_on_exit) _ = ctx.runtime.runObjectCycleRemoval();
    }
    defer {
        if (entry_generator_state == null or !frame_storage.isEmptyResidentExecutionShell()) {
            frame_storage.deinit(&ctx.runtime.memory, ctx.runtime);
        }
    }
    var catch_target_storage: ?usize = null;
    const l0_state = inline_calls.L0State{
        .level = .{
            .frame = &frame_storage,
            .stack = entry_stack,
            .catch_target = &catch_target_storage,
        },
        .eval_global_var_bindings = entry_eval_global_var_bindings,
        .direct_eval_vars_reach_global = entry_direct_eval_vars_reach_global,
        .is_eval_code = entry_is_eval_code,
        .strict_unresolved_get_var = entry_strict_unresolved_get_var,
        .generator_state = entry_generator_state,
        .stop_on_yield = entry_stop_on_yield,
        .stop_before_pc = entry_stop_before_pc,
        .suspend_on_module_await = entry_suspend_on_module_await,
    };
    // Construct Machine at its final address before publishing the invocation
    // Adapter that points to it. Machine is the resolver's only execution-state
    // source; the separate link preserves Machine's existing hot layout. It must
    // not move until the link is popped.
    var machine = inline_calls.Machine.init(ctx, output, global, &l0_state);
    var active_backtrace_frame = core.ActiveBacktraceFrame{
        .data = &machine,
        .resolver = inline_calls.resolveMachineBacktrace,
    };
    ctx.pushActiveBacktraceFrame(&active_backtrace_frame);
    defer ctx.popActiveBacktraceFrame(&active_backtrace_frame);
    // Register after the pop defer so inline frames are drained while this
    // invocation is still observable; the L0 Frame is destroyed afterwards.
    defer machine.deinit();

    if (entry_generator_state == null) {
        try frame_storage.initCallBindings(ctx.runtime, .{
            .initial_this_value = initial_this_value,
            .current_function_value = current_function_value,
            .new_target_value = new_target_value,
        });
    }
    // A generator/async resume with a resident frame immediately frees any slab built
    // here and swaps in the generator's PRESERVED buffers (vm_gen_async.zig), so
    // allocating + initializing a throwaway slab + re-duping args + rebuilding var_refs is
    // pure waste — qjs allocates the generator frame ONCE at creation and resumes on it
    // (JS_CALL_FLAG_GENERATOR early-out, quickjs.c:17790). `has_frame`, not pc, is the
    // discriminator: internal marker-less generators have a valid resident frame at pc 0.
    //
    // The unmapped `arguments` snapshot is also creation-only. If the bytecode can observe
    // `arguments`, its prologue materializes that object before the first suspension and
    // parks it in the hidden arguments local, which is part of the preserved locals window.
    // Rebuilding `original_args` on every started resume therefore created a second snapshot
    // only for resumeExecutionStateRaw to release it immediately. The preserved buffers cover
    // locals/args/var_refs for every started resume; the only remaining initArguments output
    // is the mapped-arguments count (frame.args is already the preserved buffer), which we
    // set directly — identical to what initArguments would store (`actual_arg_count = args.len`).
    const skip_resume_slab = if (entry_generator_state) |gen| gen.generatorExecutionState().has_frame else false;
    if (!skip_resume_slab) {
        try initFreshEntryFrame(ctx, entry_stack, entry_function, &frame_storage, global, args, var_refs, entry_generator_state, entry_prepared_frame);
    }
    if (entry_generator_state == null and entry_function.isGlobalVar() and !entry_global_declarations_prevalidated) {
        try vm_property_globals.instantiateGlobalVarDeclarationCells(ctx, global, entry_function, &frame_storage, entry_is_eval_code);
    }

    frame_storage.pc = entry_initial_pc;
    const resume_state = try gen_async_vm.resumeExecutionState(ctx, entry_stack, entry_function, &frame_storage, entry_generator_state, resume_value);
    // If execution completes or fails, clear the payload's non-owning aliases
    // before the live Frame/Stack defers release their buffers. A yield/await
    // republished ownership already, so this is a no-op on suspension.
    defer gen_async_vm.finishExecutionStateRun(ctx.runtime, entry_stack, &frame_storage, entry_generator_state);
    // A parked frame already passed this full-capacity guard on its creation
    // run, and GeneratorExecutionState retains (or grows) that same backing.
    // QuickJS likewise resumes its preallocated stack directly.
    if (!skip_resume_slab) try reserveEntryFrameCapacity(entry_stack, entry_function);
    catch_target_storage = try gen_async_vm.completeResumeState(ctx, output, global, entry_stack, entry_function, &frame_storage, resume_state, resume_value);
    // Marker-less internal generator bytecode has no parameter/body boundary to
    // execute toward. Park its fully initialized frame before dispatch at pc 0.
    if (entry_stop_before_pc) |stop_pc| {
        if (frame_storage.pc == stop_pc) {
            if (try gen_async_vm.stopBeforePc(ctx, entry_stack, &frame_storage, entry_generator_state, catch_target_storage, stop_pc)) |stopped| return stopped;
        }
    }

    while (true) {
        return runTC(&machine) catch |err| {
            // The error escaped the current frame without an in-frame
            // handler. Unwind suspended inline frames (mirroring how the
            // error would propagate through the recursive call chain) and
            // resume the loop when an outer frame catches it.
            if (machine.depth > 0 and try machine.unwindForError(global, err)) continue;
            return err;
        };
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
    global: *core.Object,
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
    const slab = if (entry_prepared_frame) |prepared| blk: {
        frame_storage.installResidentStorage(prepared.slab.storage);
        break :blk prepared.slab;
    } else if (resident_frame_storage.len != 0) blk: {
        const windows = frame_mod.FrameSlab.partitionStorage(
            resident_frame_storage,
            frame_arg_count,
            frame_mod.originalArgCount(args.len, need_original_args),
            entry_function.var_count,
            0,
            frame_mod.frameVarRefStorageCount(entry_function, var_refs),
            open_var_ref_count,
        );
        frame_storage.installResidentStorage(resident_frame_storage);
        break :blk windows;
    } else if (frame_arena) |arena| blk: {
        if (frame_mod.FrameSlab.carve(
            &ctx.runtime.memory,
            arena,
            frame_arg_count,
            frame_mod.originalArgCount(args.len, need_original_args),
            entry_function.var_count,
            @as(usize, entry_function.stack_size) + 1,
            frame_mod.frameVarRefStorageCount(entry_function, var_refs),
            open_var_ref_count,
        )) |windows| break :blk windows;
        const heap_windows = try frame_mod.FrameSlab.allocHeap(
            &ctx.runtime.memory,
            frame_arg_count,
            frame_mod.originalArgCount(args.len, need_original_args),
            entry_function.var_count,
            0,
            frame_mod.frameVarRefStorageCount(entry_function, var_refs),
            open_var_ref_count,
        );
        frame_storage.installOwnedStorage(heap_windows.storage);
        break :blk heap_windows;
    } else blk: {
        const heap_windows = try frame_mod.FrameSlab.allocHeap(
            &ctx.runtime.memory,
            frame_arg_count,
            frame_mod.originalArgCount(args.len, need_original_args),
            entry_function.var_count,
            0,
            frame_mod.frameVarRefStorageCount(entry_function, var_refs),
            open_var_ref_count,
        );
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
        entry_stack.* = stack_mod.Stack.initArenaWindow(&ctx.runtime.memory, ctx.runtime.vm_stack_arena_policy, slab.stack);
    }
    try call_vm.initFrameLocals(ctx, entry_function, frame_storage, use_inline_frame_storage, frame_windows);
    try frame_storage.initArguments(&ctx.runtime.memory, frame_arena, args, use_inline_frame_storage, need_original_args, frame_windows);
    if (frame_windows.open_var_refs) |open_refs| try frame_storage.installOpenVarRefSlots(open_refs) else if (open_var_ref_count != 0) try frame_storage.ensureOpenVarRefSlots(&ctx.runtime.memory, frame_arena, use_inline_frame_storage);
    try call_vm.initFrameVarRefs(ctx, global, entry_function, frame_storage, var_refs, use_inline_frame_storage, frame_windows);
}

/// Tail-call dispatcher entry: build the hot `Vm` caches from the Machine's
/// single current-level seam and run the handler chain.
fn runTC(m: *inline_calls.Machine) HostError!core.JSValue {
    const level = m.currentLevel();
    const func = level.function();
    var vm = tailcall_dispatch.Vm{
        .ctx = m.ctx,
        .function = func,
        .global = m.global,
        .frame = level.frame,
        .stack = level.stack,
        .machine = m,
        .output = m.output,
        .code_base = func.byteCode().ptr,
        .catch_target = level.catch_target,
    };
    return tailcall_dispatch.run(&vm);
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
pub const qjsArraySortCall = array_ops.qjsArraySortCall;
pub const qjsArrayByCopyCall = array_ops.qjsArrayByCopyCall;
pub const drainPendingPromiseJobs = promise_ops.drainPendingPromiseJobs;
pub const cleanupAtomicsWaitersForContext = call_runtime.cleanupAtomicsWaitersForContext;
const throwTypeErrorIntrinsicForGlobal = call_runtime.throwTypeErrorIntrinsicForGlobal;
pub const getValueProperty = class_vm.getValueProperty;

// `engine eval host globals and throw intrinsic tear down cleanly` was relocated
// to `src/tests/exec.zig` in Phase 6b-3 STEP 7B: it bootstraps a bare runtime's
// standard globals through `rt.installStandardGlobals`, with the installer
// registered through the runtime bootstrap seam.
