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
    function: *const bytecode.Bytecode,
) !core.JSValue {
    return runWithOutput(ctx, stack, function, null);
}

pub fn runWithOutput(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    output: ?*std.Io.Writer,
) !core.JSValue {
    const global_object = try contextGlobal(ctx);
    const this_value = if (function.flags.is_module or function.flags.runtime_strict) core.JSValue.undefinedValue() else global_object.value();
    return runWithArgs(ctx, stack, function, this_value, &.{}, &.{}, output, global_object, true, false, false);
}

/// Host eval-mode entry (`ctx.eval(.eval_direct/.eval_indirect)`). Runs the
/// compiled eval source through the EVAL runner contract — `is_eval_code = true`
/// with eval-specific declaration instantiation — exactly as the in-VM `eval()` builtin
/// (`eval_ops.zig` runWithCallEnv site). The script runner (`runWithOutput`)
/// uses the SCRIPT contract, which would materialise a `ctx.lexicals` property
/// instead of the eval frame-local. qjs keeps top-level `let`/`const`/`class`
/// in a `JS_EVAL_TYPE_DIRECT`/`INDIRECT` eval as `add_scope_var` frame locals
/// (discarded with the eval frame; no global cell, no env property —
/// `quickjs.c:24362-24372` requires GLOBAL/MODULE for the cell). With
/// `eval_global_var_bindings = (mode == .eval_indirect)` an indirect eval still
/// registers its top-level `var`/function declarations on the global object as
/// configurable data properties (non-lexical), matching the in-VM builtin and
/// `parser.zig:176`.
pub fn runEvalWithOutput(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    output: ?*std.Io.Writer,
    eval_global_var_bindings: bool,
) !core.JSValue {
    const global_object = try contextGlobal(ctx);
    const this_value = if (function.flags.is_module or function.flags.runtime_strict) core.JSValue.undefinedValue() else global_object.value();
    return runWithCallEnv(.{
        .ctx = ctx,
        .stack = stack,
        .function = function,
        .initial_this_value = this_value,
        .output = output,
        .global = global_object,
        .break_var_ref_cycles_on_exit = true,
        .eval_global_var_bindings = eval_global_var_bindings,
        .is_eval_code = true,
    }) catch |err| {
        if (!ctx.preserve_uncaught_exception and err != error.JSException and ctx.hasException()) ctx.clearException();
        return err;
    };
}

pub fn runWithOutputAndVarRefs(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    output: ?*std.Io.Writer,
    var_refs: []const *core.VarRef,
) !core.JSValue {
    const global_object = try contextGlobal(ctx);
    const this_value = if (function.flags.is_module or function.flags.runtime_strict) core.JSValue.undefinedValue() else global_object.value();
    return runWithArgs(ctx, stack, function, this_value, &.{}, var_refs, output, global_object, false, false, false);
}

pub fn runModuleWithOutputAndVarRefsState(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
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
    function: *const bytecode.Bytecode,
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
    if (ctx.global) |existing| return existing;
    const global_object = try core.Object.createWithOwnPropertyCapacity(
        ctx.runtime,
        core.class.ids.object,
        null,
        call_mod.contextGlobalOwnPropertyCapacity(ctx.runtime),
    );
    errdefer global_object.value().free(ctx.runtime);
    global_object.flags.is_global = true;
    try call_mod.installHostGlobals(ctx.runtime, global_object);
    const thrower = try throwTypeErrorIntrinsicForGlobal(ctx.runtime, global_object);
    thrower.free(ctx.runtime);
    if (ctx.runtime.preallocated_oom_error == null) {
        // Preallocate the out-of-memory catch value while the heap still has
        // room; when a memory limit is later exhausted, the catch machinery
        // can throw this object without allocating (QuickJS analogue).
        // Stack-less by design (the documented exemption on
        // `createNamedErrorWithoutStack`): a backtrace captured here would
        // describe startup, and the exhausted-heap delivery path
        // (`tryCatchInFrame`) must not allocate one.
        ctx.runtime.preallocated_oom_error = exception_ops.createPreallocatedOutOfMemoryError(
            ctx.runtime,
            global_object,
        ) catch null;
    }
    const next_eval = global_object.getProperty(core.atom.predefinedId("eval", .string).?);
    const old_eval = ctx.eval_function;
    ctx.eval_function = next_eval;
    ctx.global = global_object;
    old_eval.free(ctx.runtime);
    return global_object;
}

pub fn runWithArgs(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    initial_this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const *core.VarRef,
    output: ?*std.Io.Writer,
    global: *core.Object,
    break_var_ref_cycles_on_exit: bool,
    strict_unresolved_get_var: bool,
    stop_on_yield: bool,
) !core.JSValue {
    return runWithCallEnv(.{
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
    }) catch |err| {
        if (!ctx.preserve_uncaught_exception and err != error.JSException and ctx.hasException()) ctx.clearException();
        return err;
    };
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
    function: *const bytecode.Bytecode,
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
    constructor_this_value: core.JSValue = core.JSValue.undefinedValue(),
    eval_global_var_bindings: bool = false,
    is_eval_code: bool = false,
    suspend_on_module_await: bool = false,
    initial_pc: usize = 0,
    prepared_entry_frame: ?*const PreparedEntryFrame = null,
};

pub fn runWithCallEnv(env: CallEnv) HostError!core.JSValue {
    return runWithArgsState(
        env.ctx,
        env.stack,
        env.function,
        env.initial_this_value,
        env.args,
        env.var_refs,
        env.output,
        env.global,
        env.break_var_ref_cycles_on_exit,
        env.strict_unresolved_get_var,
        env.stop_on_yield,
        env.generator_state,
        env.resume_value,
        env.stop_before_pc,
        env.current_function_value,
        env.new_target_value,
        env.constructor_this_value,
        env.eval_global_var_bindings,
        env.is_eval_code,
        env.suspend_on_module_await,
        env.initial_pc,
        env.prepared_entry_frame,
    );
}

fn runWithArgsState(
    ctx: *core.JSContext,
    entry_stack: *stack_mod.Stack,
    entry_function: *const bytecode.Bytecode,
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
    constructor_this_value: core.JSValue,
    entry_eval_global_var_bindings: bool,
    entry_is_eval_code: bool,
    entry_suspend_on_module_await: bool,
    entry_initial_pc: usize,
    entry_prepared_frame: ?*const PreparedEntryFrame,
) HostError!core.JSValue {
    const call_depth_guard = try call_vm.enterCallDepth(ctx, global);
    defer call_depth_guard.deinit();
    const call_profile_guard = call_vm.enterCallProfile(ctx.runtime);
    defer call_profile_guard.deinit();

    // Frame storage (locals/args/var_refs) may be carved from the VM stack
    // arena; reclaim the watermark after the frame has released its values.
    const frame_arena_mark = ctx.runtime.vm_stack.mark();
    defer ctx.runtime.vm_stack.restore(frame_arena_mark);

    const resident_binding_shell = entry_generator_state != null and constructor_this_value.isUndefined();
    var frame_storage = if (resident_binding_shell)
        frame_mod.Frame.initResidentExecution(
            entry_function,
            initial_this_value,
            current_function_value,
            new_target_value,
            entry_generator_state.?.generatorActualArgCount(),
        )
    else
        frame_mod.Frame.init(entry_function);
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

    const call_bindings = frame_mod.CallBindingInputs{
        .initial_this_value = initial_this_value,
        .current_function_value = current_function_value,
        .new_target_value = new_target_value,
        .constructor_this_value = constructor_this_value,
    };
    if (entry_generator_state != null and !resident_binding_shell) {
        // The resident execution state owns these two values for the entire
        // VM run. Borrow them exactly like qjs's JSAsyncFunctionState frame;
        // completion is finalized only after this live Frame has unwound.
        try frame_storage.initCallBindingValues(&ctx.runtime.memory, call_bindings, .{
            .this_value = .borrow,
            .current_function = .borrow,
        });
    } else if (entry_generator_state == null) {
        try frame_storage.initCallBindings(ctx.runtime, call_bindings);
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
    if (entry_generator_state == null) {
        try vm_property_globals.instantiateGlobalVarDeclarations(ctx, global, entry_function, &frame_storage, entry_is_eval_code, entry_eval_global_var_bindings);
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
    errdefer {
        closeFrameDestructuringIteratorsForAbruptCompletion(ctx, output, global, entry_stack, &frame_storage);
    }
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
    entry_function: *const bytecode.Bytecode,
    frame_storage: *frame_mod.Frame,
    global: *core.Object,
    args: []const core.JSValue,
    var_refs: []const *core.VarRef,
    entry_generator_state: ?*core.Object,
    entry_prepared_frame: ?*const PreparedEntryFrame,
) HostError!void {
    const use_inline_frame_storage = entry_generator_state == null and !entry_function.flags.is_generator and !entry_function.flags.is_async;
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
        frame_mod.frameOpenVarRefStorageCount(entry_function, frame_arg_count);
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
        entry_stack.* = stack_mod.Stack.initArenaWindow(&ctx.runtime.memory, ctx.runtime.stack_size, slab.stack);
    }
    try call_vm.initFrameLocals(ctx, entry_function, frame_storage, use_inline_frame_storage, frame_windows);
    try frame_storage.initArguments(&ctx.runtime.memory, frame_arena, args, use_inline_frame_storage, need_original_args, frame_windows);
    if (frame_windows.open_var_refs) |open_refs| frame_storage.installOpenVarRefSlots(open_refs) else if (open_var_ref_count != 0) try frame_storage.ensureOpenVarRefSlots(&ctx.runtime.memory, frame_arena, use_inline_frame_storage);
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
        .code_base = func.code.ptr,
        .code_end = func.code.ptr + func.code.len,
        .stack_base = level.stack.values.ptr,
        .arg_buf = level.frame.args.ptr,
        .catch_target = level.catch_target,
        .poller = .init(m.ctx.runtime),
    };
    return tailcall_dispatch.run(&vm);
}

fn reserveEntryFrameCapacity(entry_stack: *stack_mod.Stack, entry_function: *const bytecode.Bytecode) !void {
    const frame_stack_size: usize = if (comptime builtin.mode == .Debug)
        // Some colocated tests hand-build bytecode without running finalize's
        // stack-size pass. Keep those Debug-only fixtures checked at entry;
        // ReleaseFast relies on finalized bytecode's verified stack_size.
        if (entry_function.stack_size == 0 and entry_function.code.len != 0)
            entry_function.code.len
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
const closeFrameDestructuringIteratorsForAbruptCompletion = call_runtime.closeFrameDestructuringIteratorsForAbruptCompletion;
pub const drainPendingPromiseJobs = promise_ops.drainPendingPromiseJobs;
pub const cleanupAtomicsWaitersForContext = call_runtime.cleanupAtomicsWaitersForContext;
const throwTypeErrorIntrinsicForGlobal = call_runtime.throwTypeErrorIntrinsicForGlobal;
pub const getValueProperty = class_vm.getValueProperty;

// `engine eval host globals and throw intrinsic tear down cleanly` was relocated
// to `src/tests/exec.zig` in Phase 6b-3 STEP 7B: it bootstraps a bare runtime's
// standard globals through `rt.installStandardGlobals`, which needs the builtins
// installer registered, and exec source must not name the builtins registry.
