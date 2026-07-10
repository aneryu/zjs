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
    const global_object = try contextGlobal(ctx);
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
) HostError!core.JSValue {
    const call_depth_guard = try call_vm.enterCallDepth(ctx, global);
    defer call_depth_guard.deinit();
    const call_profile_guard = call_vm.enterCallProfile(ctx.runtime);
    defer call_profile_guard.deinit();

    // Frame storage (locals/args/var_refs) may be carved from the VM stack
    // arena; reclaim the watermark after the frame has released its values.
    const frame_arena_mark = ctx.runtime.vm_stack.mark();
    defer ctx.runtime.vm_stack.restore(frame_arena_mark);

    var frame_storage = frame_mod.Frame.init(entry_function);
    defer {
        if (break_var_ref_cycles_on_exit) _ = ctx.runtime.runObjectCycleRemoval();
    }
    defer frame_storage.deinit(&ctx.runtime.memory, ctx.runtime);
    // Single backtrace node for this whole VM invocation (qjs's
    // `current_stack_frame` granularity). It covers the L0 frame during the
    // pre-dispatch setup below (machine == null, depth 0) and walks the inline
    // Machine's Entry chain once `machine` is attached after init — replacing
    // the former per-inline-call backtrace push/pop.
    var machine_backtrace = inline_calls.MachineBacktrace{ .l0_frame = &frame_storage };
    var active_backtrace_frame = core.ActiveBacktraceFrame{
        .data = &machine_backtrace,
        .resolver = inline_calls.resolveMachineBacktrace,
    };
    ctx.pushActiveBacktraceFrame(&active_backtrace_frame);
    defer ctx.popActiveBacktraceFrame(&active_backtrace_frame);
    try frame_storage.initCallBindings(ctx.runtime, .{
        .initial_this_value = initial_this_value,
        .current_function_value = current_function_value,
        .new_target_value = new_target_value,
        .constructor_this_value = constructor_this_value,
    });
    const use_inline_frame_storage = entry_generator_state == null and !entry_function.flags.is_generator and !entry_function.flags.is_async;
    const frame_arena: ?*core.VmStackArena = if (use_inline_frame_storage) &ctx.runtime.vm_stack else null;
    const need_original_args = argumentsNeedsOriginalSnapshot(entry_function);
    const frame_arg_count = frame_mod.frameArgCount(entry_function, args.len);
    const open_var_ref_count = frame_mod.frameOpenVarRefStorageCount(entry_function, frame_arg_count);
    // A STARTED generator/async resume (pc != 0) immediately frees any frame slab built
    // here and swaps in the generator's PRESERVED buffers (vm_gen_async.zig:157-173), so
    // allocating + initializing a throwaway slab + re-duping args + rebuilding var_refs is
    // pure waste — qjs allocates the generator frame ONCE at creation and resumes on it
    // (JS_CALL_FLAG_GENERATOR early-out, quickjs.c:17790). First creation (pc == 0) still
    // builds the slab (it becomes the generator's working frame), so gate on pc != 0.
    //
    // EXCEPT a generator that needs the UNMAPPED `arguments` snapshot (strict / non-simple
    // params): `initArguments` rebuilds `original_args` from generatorArgs on EVERY resume
    // (it is NOT preserved in the generator frame buffers — resumeExecutionStateRaw clears
    // it at line 164), so those keep the full path. For every other started resume the
    // preserved buffers cover locals/args/var_refs; the only remaining initArguments output
    // is the mapped-arguments count (frame.args is already the preserved buffer), which we
    // set directly — identical to what initArguments would store (`actual_arg_count = args.len`).
    const is_started_resume = if (entry_generator_state) |gen| gen.generatorPc() != 0 else false;
    const skip_resume_slab = is_started_resume and !need_original_args;
    if (!skip_resume_slab) {
        const slab = if (frame_arena) |arena| blk: {
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
        try call_vm.initFrameLocals(ctx, entry_function, &frame_storage, use_inline_frame_storage, frame_windows);
        try frame_storage.initArguments(&ctx.runtime.memory, frame_arena, args, use_inline_frame_storage, need_original_args, frame_windows);
        if (frame_windows.open_var_refs) |open_refs| frame_storage.installOpenVarRefSlots(open_refs) else if (open_var_ref_count != 0) try frame_storage.ensureOpenVarRefSlots(&ctx.runtime.memory, frame_arena, use_inline_frame_storage);
        try call_vm.initFrameVarRefs(ctx, global, entry_function, &frame_storage, var_refs, use_inline_frame_storage, frame_windows);
    } else {
        // Skipped the slab; resumeExecutionStateRaw installs the preserved frame.args. The
        // mapped `arguments` object still reads frame.actual_arg_count, so set it the same way
        // initArguments would have (args == generatorArgs() here, so this is byte-identical).
        frame_storage.actual_arg_count = args.len;
    }
    if (entry_generator_state == null) {
        try vm_property_globals.instantiateGlobalVarDeclarations(ctx, global, entry_function, &frame_storage, entry_is_eval_code, entry_eval_global_var_bindings);
    }

    const resume_state = try gen_async_vm.resumeExecutionState(ctx, entry_stack, entry_function, &frame_storage, entry_generator_state, resume_value);
    try reserveEntryFrameCapacity(entry_stack, entry_function);
    errdefer {
        closeFrameDestructuringIteratorsForAbruptCompletion(ctx, output, global, entry_stack, &frame_storage);
    }
    var catch_target_storage: ?usize = try gen_async_vm.completeResumeState(ctx, output, global, entry_stack, entry_function, &frame_storage, resume_state, resume_value);

    var machine = inline_calls.Machine.init(ctx, output, global, &frame_storage, entry_stack, &catch_target_storage);
    defer machine.deinit();
    machine_backtrace.machine = &machine;

    var loop_state = LoopState{
        .ctx = ctx,
        .output = output,
        .global = global,
        .machine = &machine,
        .entry_function = entry_function,
        .entry_stack = entry_stack,
        .frame_storage = &frame_storage,
        .catch_target_storage = &catch_target_storage,
        .entry_eval_global_var_bindings = entry_eval_global_var_bindings,
        .entry_is_eval_code = entry_is_eval_code,
        .entry_strict_unresolved_get_var = entry_strict_unresolved_get_var,
        .entry_generator_state = entry_generator_state,
        .entry_stop_on_yield = entry_stop_on_yield,
        .entry_stop_before_pc = entry_stop_before_pc,
        .entry_suspend_on_module_await = entry_suspend_on_module_await,
    };
    while (true) {
        return runTC(&loop_state) catch |err| {
            // The error escaped the current frame without an in-frame
            // handler. Unwind suspended inline frames (mirroring how the
            // error would propagate through the recursive call chain) and
            // resume the loop when an outer frame catches it.
            if (machine.depth > 0 and try machine.unwindForError(global, err)) continue;
            return err;
        };
    }
}

/// Tail-call dispatcher entry: build the `Vm` bundle from the loop state's CURRENT
/// top frame (L0 frame_storage at depth 0, else machine.topEntry()) and run the
/// handler chain. Replaces the old monolithic switch dispatcher.
fn runTC(loop_state: *LoopState) HostError!core.JSValue {
    const m = loop_state.machine;
    const use_inline = m.depth != 0;
    const func = if (use_inline) m.topEntry().function else loop_state.entry_function;
    const fr = if (use_inline) &m.topEntry().frame else loop_state.frame_storage;
    const st = if (use_inline) &m.topEntry().stack else loop_state.entry_stack;
    const ct = if (use_inline) &m.topEntry().catch_target else loop_state.catch_target_storage;
    var vm = tailcall_dispatch.Vm{
        .ctx = loop_state.ctx,
        .function = func,
        .global = loop_state.global,
        .frame = fr,
        .stack = st,
        .machine = m,
        .output = loop_state.output,
        .code_base = func.code.ptr,
        .code_end = func.code.ptr + func.code.len,
        .stack_base = st.values.ptr,
        .arg_buf = fr.args.ptr,
        .catch_target = ct,
        .l0_function = loop_state.entry_function,
        .l0_frame = loop_state.frame_storage,
        .l0_stack = loop_state.entry_stack,
        .l0_catch_target = loop_state.catch_target_storage,
        .poller = .init(loop_state.ctx.runtime),
        .l0 = .{
            .is_eval_code = loop_state.entry_is_eval_code,
            .eval_global_var_bindings = loop_state.entry_eval_global_var_bindings,
            .strict_unresolved_get_var = loop_state.entry_strict_unresolved_get_var,
            .generator_state = loop_state.entry_generator_state,
            .stop_on_yield = loop_state.entry_stop_on_yield,
            .stop_before_pc = loop_state.entry_stop_before_pc,
            .suspend_on_module_await = loop_state.entry_suspend_on_module_await,
        },
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

/// Per-invocation state shared between `runWithArgsState` and `runTC`. Holds
/// the level-0 execution context; `runTC` derives the current top frame from it
/// and the inline machine.
const LoopState = struct {
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    machine: *inline_calls.Machine,
    entry_function: *const bytecode.Bytecode,
    entry_stack: *stack_mod.Stack,
    frame_storage: *frame_mod.Frame,
    catch_target_storage: *?usize,
    entry_eval_global_var_bindings: bool,
    entry_is_eval_code: bool,
    entry_strict_unresolved_get_var: bool,
    entry_generator_state: ?*core.Object,
    entry_stop_on_yield: bool,
    entry_stop_before_pc: ?usize,
    entry_suspend_on_module_await: bool,
};

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
