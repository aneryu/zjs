//! QuickJS-aligned VM dispatcher for bytecode produced by
//! `frontend/zjs_parser.zig`, tracked by the current semantic
//! alignment plans.
//!
//! This is the only VM dispatcher after the parser-rewrite M2 swap.
//!
//! The dispatcher handles QuickJS-format opcodes emitted by the parser after
//! the bytecode pipeline has removed temporary opcodes.

const fusion_stats = @import("vm_fusion_stats.zig");
const builtin = @import("builtin");
const std = @import("std");

const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const frontend = @import("../frontend/root.zig");
const call_mod = @import("call.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");
const arith_vm = @import("vm_arith.zig");
const call_vm = @import("vm_call.zig");
const class_vm = @import("object_ops.zig");
const control_vm = @import("vm_control.zig");
const date_vm = @import("date_ops.zig");
const eval_module_vm = @import("vm_eval_module.zig");
const exception_ops = @import("vm_exception_ops.zig");
const exceptions = @import("exceptions.zig");
const gen_async_vm = @import("vm_gen_async.zig");
const inline_calls = @import("inline_calls.zig");
const call_internal = @import("call_internal.zig");
const tailcall_dispatch = @import("tailcall_dispatch.zig");
const iter_vm = @import("iterator_ops.zig");
const literal_vm = @import("vm_literal.zig");
const vm_property_field = @import("vm_property_field.zig");
const vm_property_globals = @import("vm_property_globals.zig");
const vm_property_locals = @import("vm_property_locals.zig");
const slot_ops = @import("slot_ops.zig");
const vm_property_private = @import("vm_property_private.zig");
const vm_property_ref = @import("vm_property_ref.zig");
const profile_vm = @import("vm_profile.zig");
const regexp_vm = @import("vm_regexp.zig");
const call_runtime = @import("call_runtime.zig");
const array_ops = @import("array_ops.zig");
const forof_ops = @import("forof_ops.zig");
const promise_ops = @import("promise_ops.zig");
const value_vm = @import("vm_value.zig");
const HostError = exceptions.HostError;

/// True when EITHER register-resident dispatcher routes inline calls off the
/// Machine. The inline-call arms below use it as their comptime gate.
const recurse_or_tailcall_enabled = call_internal.recursive_dispatch_enabled or tailcall_dispatch.tailcall_dispatch_enabled;
/// Comptime-select the tail-call dispatcher (preferred) or the recursive one for
/// an inline-eligible callee. Mirrors `call_internal.recurseInlineCall`'s shape.
inline fn recurseInline(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    request: call_runtime.InlineCallRequest,
) HostError!call_internal.RecurseOutcome {
    if (comptime tailcall_dispatch.tailcall_dispatch_enabled)
        return tailcall_dispatch.recurseInlineCallTC(ctx, output, global, stack, frame, catch_target, request);
    return call_internal.recurseInlineCall(ctx, output, global, stack, frame, catch_target, request);
}

const op = bytecode.opcode.op;
const build_options = @import("build_options");
const eval_class_field_initializer_flag: u16 = 0x8000;
const eval_parameter_initializer_flag: u16 = 0x4000;
const eval_ret_atom: core.Atom = 82;

/// Threaded (computed-goto-style) dispatch is enabled only when per-opcode
/// profiling is compiled out, because threaded arms bypass the per-iteration
/// `enterOpcode` scope. QuickJS dispatches the same way (`goto *dispatch[*pc++]`).
const thread_dispatch = !build_options.zjs_enable_opcode_profile;

/// Hot-path opcode fetch used by threaded dispatch arms. Mirrors the cheap part
/// of the main loop prologue (interrupt poll + fetch) but skips the
/// `machine.switched` reload, which only matters after a call/return changes
/// frame depth. Returns null for the cases that must re-enter the full prologue
/// loop: function-boundary fall-through and generator single-step
/// (`entry_stop_before_pc != null`); the caller then does a bare `continue`.
inline fn nextOpcode(
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    poller: *control_vm.InterruptPoller,
    rt: *core.JSRuntime,
    entry_stop_before_pc: ?usize,
) !?u8 {
    if (entry_stop_before_pc != null) return null;
    if (frame.pc >= function.code.len) return null;
    try poller.poll(rt);
    const opc = function.code[frame.pc];
    frame.pc += 1;
    return opc;
}

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
    return runWithArgs(ctx, stack, function, this_value, &.{}, &.{}, output, global_object, true, false, false, &.{}, &.{}, &.{}, &.{});
}

pub fn runWithOutputAndVarRefs(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    output: ?*std.Io.Writer,
    var_refs: []const core.JSValue,
) !core.JSValue {
    const global_object = try contextGlobal(ctx);
    const this_value = if (function.flags.is_module or function.flags.runtime_strict) core.JSValue.undefinedValue() else global_object.value();
    return runWithArgs(ctx, stack, function, this_value, &.{}, var_refs, output, global_object, false, false, false, &.{}, &.{}, &.{}, &.{});
}

pub fn runModuleWithOutputAndVarRefsState(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    output: ?*std.Io.Writer,
    var_refs: []const core.JSValue,
    module_state: *core.Object,
    resume_value: ?core.JSValue,
) !core.JSValue {
    const global_object = try contextGlobal(ctx);
    return runWithArgsState(ctx, stack, function, core.JSValue.undefinedValue(), &.{}, var_refs, output, global_object, false, false, false, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, module_state, resume_value, null, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), false, false, core.JSValue.undefinedValue(), true, true);
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
        ctx.runtime.preallocated_oom_error = exception_ops.createNamedErrorWithoutStack(
            ctx.runtime,
            global_object,
            "InternalError",
            "out of memory",
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
    var_refs: []const core.JSValue,
    output: ?*std.Io.Writer,
    global: *core.Object,
    break_var_ref_cycles_on_exit: bool,
    strict_unresolved_get_var: bool,
    stop_on_yield: bool,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    input_eval_var_refs: []const core.JSValue,
) !core.JSValue {
    return runWithArgsState(ctx, stack, function, initial_this_value, args, var_refs, output, global, break_var_ref_cycles_on_exit, strict_unresolved_get_var, stop_on_yield, eval_local_names, eval_local_slots, eval_var_ref_names, input_eval_var_refs, &.{}, &.{}, &.{}, &.{}, null, null, null, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), false, false, core.JSValue.undefinedValue(), true, false) catch |err| {
        if (!ctx.preserve_uncaught_exception and err != error.JSException and ctx.hasException()) ctx.clearException();
        return err;
    };
}

const argumentsNeedsOriginalSnapshot = frame_mod.argumentsNeedsOriginalSnapshot;

/// Per-invocation interpreter entry state. Replaces the former 25-parameter
/// `runWithArgsState` surface; eval/generator/module-await flags live here.
pub const CallEnv = struct {
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    initial_this_value: core.JSValue = core.JSValue.undefinedValue(),
    args: []const core.JSValue = &.{},
    var_refs: []const core.JSValue = &.{},
    output: ?*std.Io.Writer = null,
    global: *core.Object,
    break_var_ref_cycles_on_exit: bool = false,
    strict_unresolved_get_var: bool = false,
    stop_on_yield: bool = false,
    eval_local_names: []const core.Atom = &.{},
    eval_local_slots: []core.JSValue = &.{},
    eval_var_ref_names: []const core.Atom = &.{},
    eval_var_refs: []const core.JSValue = &.{},
    inherited_eval_local_names: []const core.Atom = &.{},
    inherited_eval_local_slots: []core.JSValue = &.{},
    inherited_eval_var_ref_names: []const core.Atom = &.{},
    inherited_eval_var_refs: []const core.JSValue = &.{},
    generator_state: ?*core.Object = null,
    resume_value: ?core.JSValue = null,
    stop_before_pc: ?usize = null,
    current_function_value: core.JSValue = core.JSValue.undefinedValue(),
    new_target_value: core.JSValue = core.JSValue.undefinedValue(),
    constructor_this_value: core.JSValue = core.JSValue.undefinedValue(),
    eval_global_var_bindings: bool = false,
    is_eval_code: bool = false,
    eval_with_object: core.JSValue = core.JSValue.undefinedValue(),
    sync_global_lexical_locals: bool = false,
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
        env.eval_local_names,
        env.eval_local_slots,
        env.eval_var_ref_names,
        env.eval_var_refs,
        env.inherited_eval_local_names,
        env.inherited_eval_local_slots,
        env.inherited_eval_var_ref_names,
        env.inherited_eval_var_refs,
        env.generator_state,
        env.resume_value,
        env.stop_before_pc,
        env.current_function_value,
        env.new_target_value,
        env.constructor_this_value,
        env.eval_global_var_bindings,
        env.is_eval_code,
        env.eval_with_object,
        env.sync_global_lexical_locals,
        env.suspend_on_module_await,
    );
}

pub fn runWithArgsState(
    ctx: *core.JSContext,
    entry_stack: *stack_mod.Stack,
    entry_function: *const bytecode.Bytecode,
    initial_this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const core.JSValue,
    output: ?*std.Io.Writer,
    global: *core.Object,
    break_var_ref_cycles_on_exit: bool,
    entry_strict_unresolved_get_var: bool,
    entry_stop_on_yield: bool,
    entry_eval_local_names: []const core.Atom,
    entry_eval_local_slots: []core.JSValue,
    input_eval_var_ref_names: []const core.Atom,
    input_eval_var_refs: []const core.JSValue,
    inherited_eval_local_names: []const core.Atom,
    inherited_eval_local_slots: []core.JSValue,
    inherited_eval_var_ref_names: []const core.Atom,
    inherited_eval_var_refs: []const core.JSValue,
    entry_generator_state: ?*core.Object,
    resume_value: ?core.JSValue,
    entry_stop_before_pc: ?usize,
    current_function_value: core.JSValue,
    new_target_value: core.JSValue,
    constructor_this_value: core.JSValue,
    entry_eval_global_var_bindings: bool,
    entry_is_eval_code: bool,
    entry_eval_with_object: core.JSValue,
    entry_sync_global_lexical_locals: bool,
    entry_suspend_on_module_await: bool,
) HostError!core.JSValue {
    const call_depth_guard = try call_vm.enterCallDepth(ctx, global);
    defer call_depth_guard.deinit();
    const call_profile_guard = call_vm.enterCallProfile(ctx.runtime);
    defer call_profile_guard.deinit();
    try ctx.pushBacktraceFrameLazyName(entry_function.name, entry_function.filename, entry_function.line_num, entry_function.col_num, entry_function, exception_ops.resolveBacktraceLocation, current_function_value);
    defer ctx.popBacktraceFrame();

    // Frame storage (locals/args/var_refs) may be carved from the VM stack
    // arena; reclaim the watermark after the frame has released its values.
    const frame_arena_mark = ctx.runtime.vm_stack.mark();
    defer ctx.runtime.vm_stack.restore(frame_arena_mark);

    var frame_storage = frame_mod.Frame.init(entry_function);
    ctx.borrowBacktracePc(&frame_storage.pc);
    defer {
        if (break_var_ref_cycles_on_exit) _ = ctx.runtime.runObjectCycleRemoval();
    }
    defer frame_storage.deinit(&ctx.runtime.memory, ctx.runtime);
    var frame_eval_var_refs = try frame_storage.initCallBindings(ctx.runtime, .{
        .initial_this_value = initial_this_value,
        .current_function_value = current_function_value,
        .new_target_value = new_target_value,
        .constructor_this_value = constructor_this_value,
        .eval_local_names = entry_eval_local_names,
        .eval_local_slots = entry_eval_local_slots,
        .input_eval_var_ref_names = input_eval_var_ref_names,
        .input_eval_var_refs = input_eval_var_refs,
        .inherited_eval_local_names = inherited_eval_local_names,
        .inherited_eval_local_slots = inherited_eval_local_slots,
        .inherited_eval_var_ref_names = inherited_eval_var_ref_names,
        .inherited_eval_var_refs = inherited_eval_var_refs,
    });
    defer frame_eval_var_refs.deinit(ctx.runtime);

    var frame_roots = frame_mod.FrameRootScope{};
    frame_roots.init(ctx.runtime, entry_stack, &frame_storage, &frame_eval_var_refs);
    defer frame_roots.deinit();

    const use_inline_frame_storage = entry_generator_state == null and !entry_function.flags.is_generator and !entry_function.flags.is_async;
    const frame_arena: ?*core.VmStackArena = if (use_inline_frame_storage) &ctx.runtime.vm_stack else null;
    try call_vm.initFrameLocals(ctx, entry_function, &frame_storage, entry_eval_local_names, entry_eval_local_slots, use_inline_frame_storage);
    try frame_storage.initArguments(&ctx.runtime.memory, frame_arena, args, use_inline_frame_storage, argumentsNeedsOriginalSnapshot(entry_function));
    try call_vm.initFrameVarRefs(ctx, global, entry_function, &frame_storage, var_refs, use_inline_frame_storage);

    const resume_state = try gen_async_vm.resumeExecutionState(ctx, entry_stack, entry_function, &frame_storage, entry_generator_state, resume_value);
    try reserveEntryFrameCapacity(entry_stack, entry_function);
    errdefer {
        closeFrameDestructuringIteratorsForAbruptCompletion(ctx, output, global, entry_stack, &frame_storage);
    }
    var catch_target_storage: ?usize = try gen_async_vm.completeResumeState(ctx, output, global, entry_stack, entry_function, &frame_storage, resume_state, resume_value);

    var machine = inline_calls.Machine.init(ctx, output, global, &frame_storage, entry_stack, &catch_target_storage);
    defer machine.deinit();

    var loop_state = LoopState{
        .ctx = ctx,
        .output = output,
        .global = global,
        .machine = &machine,
        .entry_function = entry_function,
        .entry_stack = entry_stack,
        .frame_storage = &frame_storage,
        .catch_target_storage = &catch_target_storage,
        .entry_eval_local_names = entry_eval_local_names,
        .entry_eval_local_slots = entry_eval_local_slots,
        .entry_eval_with_object = entry_eval_with_object,
        .entry_eval_global_var_bindings = entry_eval_global_var_bindings,
        .entry_is_eval_code = entry_is_eval_code,
        .entry_sync_global_lexical_locals = entry_sync_global_lexical_locals,
        .entry_strict_unresolved_get_var = entry_strict_unresolved_get_var,
        .entry_generator_state = entry_generator_state,
        .entry_stop_on_yield = entry_stop_on_yield,
        .entry_stop_before_pc = entry_stop_before_pc,
        .entry_suspend_on_module_await = entry_suspend_on_module_await,
    };
    while (true) {
        return dispatchLoop(&loop_state) catch |err| {
            // The error escaped the current frame without an in-frame
            // handler. Unwind suspended inline frames (mirroring how the
            // error would propagate through the recursive call chain) and
            // resume the loop when an outer frame catches it.
            if (machine.depth > 0 and try machine.unwindForError(global, err)) continue;
            return err;
        };
    }
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

/// Per-invocation dispatch loop state shared between `runWithArgsState` and
/// `dispatchLoop`. Holds the level-0 (recursive entry) execution context;
/// the loop's current-level locals are re-derived from it and the inline
/// machine whenever the active frame changes.
const LoopState = struct {
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    machine: *inline_calls.Machine,
    entry_function: *const bytecode.Bytecode,
    entry_stack: *stack_mod.Stack,
    frame_storage: *frame_mod.Frame,
    catch_target_storage: *?usize,
    entry_eval_local_names: []const core.Atom,
    entry_eval_local_slots: []core.JSValue,
    entry_eval_with_object: core.JSValue,
    entry_eval_global_var_bindings: bool,
    entry_is_eval_code: bool,
    entry_sync_global_lexical_locals: bool,
    entry_strict_unresolved_get_var: bool,
    entry_generator_state: ?*core.Object,
    entry_stop_on_yield: bool,
    entry_stop_before_pc: ?usize,
    entry_suspend_on_module_await: bool,
};

fn dispatchLoop(loop_state: *LoopState) HostError!core.JSValue {
    const ctx = loop_state.ctx;
    const output = loop_state.output;
    const global = loop_state.global;
    const machine = loop_state.machine;
    const entry_function = loop_state.entry_function;
    const entry_stack = loop_state.entry_stack;
    const frame_storage = loop_state.frame_storage;
    const entry_eval_local_names = loop_state.entry_eval_local_names;
    const entry_eval_local_slots = loop_state.entry_eval_local_slots;
    const entry_eval_with_object = loop_state.entry_eval_with_object;
    const entry_eval_global_var_bindings = loop_state.entry_eval_global_var_bindings;
    const entry_is_eval_code = loop_state.entry_is_eval_code;
    const entry_sync_global_lexical_locals = loop_state.entry_sync_global_lexical_locals;
    const entry_strict_unresolved_get_var = loop_state.entry_strict_unresolved_get_var;
    const entry_generator_state = loop_state.entry_generator_state;
    const entry_stop_on_yield = loop_state.entry_stop_on_yield;
    const entry_stop_before_pc = loop_state.entry_stop_before_pc;
    const entry_suspend_on_module_await = loop_state.entry_suspend_on_module_await;

    // Per-level execution context. Plain bytecode-to-bytecode calls push
    // inline frames on `machine` and retarget these locals instead of
    // recursing; `machine.switched` marks them stale. The forced refresh
    // below realigns them after an unwind-resume re-enters the loop at a
    // non-level-0 frame.
    var function = entry_function;
    var stack = entry_stack;
    var frame: *frame_mod.Frame = frame_storage;
    var catch_target: *?usize = loop_state.catch_target_storage;
    var eval_local_names = entry_eval_local_names;
    var eval_local_slots = entry_eval_local_slots;
    var eval_var_ref_names = frame_storage.eval_var_ref_names;
    var eval_var_refs = frame_storage.eval_var_refs;
    var eval_with_object = entry_eval_with_object;
    var eval_global_var_bindings = entry_eval_global_var_bindings;
    var is_eval_code = entry_is_eval_code;
    var sync_global_lexical_locals = entry_sync_global_lexical_locals;
    var strict_unresolved_get_var = entry_strict_unresolved_get_var;
    var generator_state = entry_generator_state;
    var stop_on_yield = entry_stop_on_yield;
    var stop_before_pc = entry_stop_before_pc;
    var suspend_on_module_await = entry_suspend_on_module_await;
    machine.switched = true;

    var interrupt_poller = control_vm.InterruptPoller.init(ctx.runtime);
    // `opc` lives across `continue :sw` threaded re-dispatch so combined arms
    // (get_loc0..3, binary, get_var, ...) read the *current* opcode, not the
    // stale one the labeled switch was originally entered with.
    var opc: u8 = undefined;
    while (true) {
        if (machine.switched) {
            machine.switched = false;
            if (machine.depth == 0) {
                function = entry_function;
                stack = entry_stack;
                frame = frame_storage;
                catch_target = loop_state.catch_target_storage;
                eval_local_names = entry_eval_local_names;
                eval_local_slots = entry_eval_local_slots;
                eval_var_ref_names = frame_storage.eval_var_ref_names;
                eval_var_refs = frame_storage.eval_var_refs;
                eval_with_object = entry_eval_with_object;
                eval_global_var_bindings = entry_eval_global_var_bindings;
                is_eval_code = entry_is_eval_code;
                sync_global_lexical_locals = entry_sync_global_lexical_locals;
                strict_unresolved_get_var = entry_strict_unresolved_get_var;
                generator_state = entry_generator_state;
                stop_on_yield = entry_stop_on_yield;
                stop_before_pc = entry_stop_before_pc;
                suspend_on_module_await = entry_suspend_on_module_await;
            } else {
                const entry = machine.topEntry();
                function = &entry.view;
                stack = &entry.stack;
                frame = &entry.frame;
                catch_target = &entry.catch_target;
                eval_local_names = &.{};
                eval_local_slots = &.{};
                eval_var_ref_names = entry.frame.eval_var_ref_names;
                eval_var_refs = entry.frame.eval_var_refs;
                eval_with_object = core.JSValue.undefinedValue();
                eval_global_var_bindings = false;
                is_eval_code = false;
                sync_global_lexical_locals = false;
                strict_unresolved_get_var = entry.view.flags.is_strict or entry.view.flags.runtime_strict;
                generator_state = null;
                stop_on_yield = false;
                stop_before_pc = null;
                suspend_on_module_await = false;
            }
        }
        if (frame.pc >= function.code.len) {
            if (machine.depth == 0) break;
            const fallthrough_value = stack.peek() orelse core.JSValue.undefinedValue();
            const result = try control_vm.finishFunctionReturn(ctx, frame, fallthrough_value);
            try machine.popReturn(result);
            continue;
        }
        try interrupt_poller.poll(ctx.runtime);
        if (generator_state != null and entry_stop_before_pc != null) {
            if (try gen_async_vm.stopBeforePc(ctx, stack, frame, generator_state, stop_before_pc)) |result| return result;
        }

        opc = function.code[frame.pc];
        frame.pc += 1;
        const opcode_profile_scope = profile_vm.enterOpcode(ctx.runtime, opc);
        defer opcode_profile_scope.deinit();
        sw: switch (opc) {
            // ---- Push constants ----
            op.push_i32 => {
                try value_vm.pushInt32Operand(stack, function, frame);
                if (comptime thread_dispatch) {
                    if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; }
                    continue;
                }
            },
            op.push_bigint_i32 => try value_vm.pushBigIntI32Operand(stack, function, frame),
            op.push_i16 => {
                try value_vm.pushI16OperandVm(ctx, stack, function, frame, .{
                    .global = global,
                    .eval_local_names = eval_local_names,
                    .eval_var_ref_names = eval_var_ref_names,
                    .eval_with_object = eval_with_object,
                });
            },
            op.push_i8 => { try value_vm.pushI8Operand(stack, function, frame); if (comptime thread_dispatch) { if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; } continue; } },
            op.push_minus1 => { try value_vm.pushSmallIntMaybeFuse(stack, function, frame, -1); if (comptime thread_dispatch) { if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; } continue; } },
            op.push_0 => { try value_vm.pushSmallIntMaybeFuse(stack, function, frame, 0); if (comptime thread_dispatch) { if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; } continue; } },
            op.push_1 => { try value_vm.pushSmallIntMaybeFuse(stack, function, frame, 1); if (comptime thread_dispatch) { if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; } continue; } },
            op.push_2 => { try value_vm.pushSmallIntMaybeFuse(stack, function, frame, 2); if (comptime thread_dispatch) { if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; } continue; } },
            op.push_3 => { try value_vm.pushSmallIntMaybeFuse(stack, function, frame, 3); if (comptime thread_dispatch) { if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; } continue; } },
            op.push_4 => { try value_vm.pushSmallIntMaybeFuse(stack, function, frame, 4); if (comptime thread_dispatch) { if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; } continue; } },
            op.push_5 => { try value_vm.pushSmallIntMaybeFuse(stack, function, frame, 5); if (comptime thread_dispatch) { if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; } continue; } },
            op.push_6 => { try value_vm.pushSmallIntMaybeFuse(stack, function, frame, 6); if (comptime thread_dispatch) { if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; } continue; } },
            op.push_7 => { try value_vm.pushSmallIntMaybeFuse(stack, function, frame, 7); if (comptime thread_dispatch) { if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; } continue; } },
            op.push_const => try value_vm.pushConst(ctx, stack, function, frame, opc),
            op.push_const8 => try value_vm.pushConst8(ctx, stack, function, frame, opc),
            op.private_symbol => try value_vm.pushPrivateSymbol(ctx, stack, function, frame),
            op.regexp => try regexp_vm.pushLiteral(ctx, stack, constructorPrototypeFromGlobal(ctx.runtime, global, "RegExp")),
            op.fclosure, op.fclosure8 => switch (try call_vm.closure(ctx, output, global, stack, function, frame, catch_target, opc, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs)) {
                .done => {},
                .continue_loop => continue,
            },
            op.undefined => try value_vm.pushUndefined(stack),
            op.null => try value_vm.pushNull(stack),
            op.push_false => try value_vm.pushBoolean(stack, false),
            op.push_true => try value_vm.pushBoolean(stack, true),

            // ---- Locals (F10.1b / F10.2 short-forms) ----
            // get_loc / put_loc / set_loc lowered from scope_get_var /
            // scope_put_var by `resolve_variables` when the atom
            // resolves to a `VarDef` in the parser's `function_def`.
            // `selectShortLoc` picks the shortest encoding:
            //   - idx ∈ [0, 4)    → 1-byte short form (idx in opcode)
            //   - idx ∈ [4, 256)  → 2-byte u8-form (`get_loc8`, ...)
            //   - idx ∈ [256, 2^16) → 3-byte u16-form
            // Hot single-byte local store opcodes get dedicated inline arms
            // (no fusion cascade applies to put_loc0..3) that skip
            // vm_property_locals.loc()'s 11-arg call + 19-way re-dispatch,
            // mirroring qjs's inlined OP_put_loc0..3.
            op.put_loc0 => {
                try slot_ops.execPutLoc(ctx, function, global, frame, stack, 0, 0, opc, sync_global_lexical_locals);
                if (comptime thread_dispatch) {
                    if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; }
                    continue;
                }
            },
            op.put_loc1 => {
                try slot_ops.execPutLoc(ctx, function, global, frame, stack, 1, 0, opc, sync_global_lexical_locals);
                if (comptime thread_dispatch) {
                    if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; }
                    continue;
                }
            },
            op.put_loc2 => try slot_ops.execPutLoc(ctx, function, global, frame, stack, 2, 0, opc, sync_global_lexical_locals),
            op.put_loc3 => try slot_ops.execPutLoc(ctx, function, global, frame, stack, 3, 0, opc, sync_global_lexical_locals),

            op.get_loc, op.put_loc, op.set_loc, op.get_loc8, op.put_loc8, op.set_loc8, op.get_loc0, op.get_loc1, op.get_loc2, op.get_loc3, op.set_loc0, op.set_loc1, op.set_loc2, op.set_loc3, op.get_loc0_loc1 => {
                try vm_property_locals.loc(ctx, function, global, frame, stack, opc, stop_before_pc == null, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object);
                if (comptime thread_dispatch) {
                    if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; }
                    continue;
                }
            },

            // Hot single-byte argument reads inlined into the dispatch (skip
            // vm_property_locals.arg()'s call + re-switch), mirroring qjs's
            // inlined OP_get_arg0..3. get_arg0 is the 2nd hottest opcode in
            // recursive/call-heavy code (fib).
            op.get_arg0 => {
                try slot_ops.execGetArg(ctx, frame, stack, 0, 0, opc);
                if (comptime thread_dispatch) {
                    if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| {
                        opc = n;
                        continue :sw n;
                    }
                    continue;
                }
            },
            op.get_arg1 => {
                try slot_ops.execGetArg(ctx, frame, stack, 1, 0, opc);
                if (comptime thread_dispatch) {
                    if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| {
                        opc = n;
                        continue :sw n;
                    }
                    continue;
                }
            },
            op.get_arg2 => {
                try slot_ops.execGetArg(ctx, frame, stack, 2, 0, opc);
                if (comptime thread_dispatch) {
                    if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| {
                        opc = n;
                        continue :sw n;
                    }
                    continue;
                }
            },
            op.get_arg3 => {
                try slot_ops.execGetArg(ctx, frame, stack, 3, 0, opc);
                if (comptime thread_dispatch) {
                    if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| {
                        opc = n;
                        continue :sw n;
                    }
                    continue;
                }
            },
            op.get_arg, op.put_arg, op.set_arg, op.put_arg0, op.put_arg1, op.put_arg2, op.put_arg3, op.set_arg0, op.set_arg1, op.set_arg2, op.set_arg3 => try vm_property_locals.arg(ctx, function, frame, stack, opc),

            op.get_var_ref, op.get_var_ref_check, op.put_var_ref, op.put_var_ref_check, op.put_var_ref_check_init, op.set_var_ref, op.get_var_ref0, op.get_var_ref1, op.get_var_ref2, op.get_var_ref3, op.put_var_ref0, op.put_var_ref1, op.put_var_ref2, op.put_var_ref3, op.set_var_ref0, op.set_var_ref1, op.set_var_ref2, op.set_var_ref3 => {
                switch (try vm_property_locals.varRefVm(ctx, function, global, frame, stack, opc, catch_target, eval_global_var_bindings, is_eval_code, eval_local_names, eval_var_ref_names, eval_with_object)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- TDZ (Temporal Dead Zone) for let/const ----
            // Emitted by resolve_variables for lexical locals:
            //   set_loc_uninitialized: mark slot as in-TDZ (prologue).
            //   get_loc_check: read; throw ReferenceError if in TDZ.
            //   put_loc_check: write; throw ReferenceError if in TDZ.
            //   put_loc_check_init: write + clear TDZ flag.
            op.set_loc_uninitialized, op.get_loc_check, op.put_loc_check, op.put_loc_check_init => {
                switch (try vm_property_locals.checkedLocVm(ctx, function, global, frame, stack, opc, catch_target, stop_before_pc == null, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.push_atom_value => {
                try value_vm.pushAtomValue(ctx, stack, function, frame);
            },
            op.push_empty_string => try value_vm.pushEmptyString(ctx, stack),
            op.to_propkey => switch (try vm_property_field.toPropKeyVm(ctx, output, global, stack, function, frame, catch_target)) {
                .done => {},
                .continue_loop => continue,
            },
            op.to_propkey2 => switch (try vm_property_field.toPropKey2Vm(ctx, output, global, stack, function, frame, catch_target)) {
                .done => {},
                .continue_loop => continue,
            },
            op.set_name, op.set_name_computed => try vm_property_field.setName(ctx, output, global, stack, function, frame, opc),

            // ---- Stack manipulation ----
            op.drop => switch (try value_vm.drop(ctx.runtime, stack)) {
                .value => {},
                .catch_target => |target| {
                    catch_target.* = target;
                    continue;
                },
            },
            op.nip_catch => try value_vm.nipCatch(ctx.runtime, stack),
            op.dup => { try value_vm.dup(ctx, stack, opc); if (comptime thread_dispatch) { if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; } continue; } },
            op.swap => try value_vm.swap(ctx, stack),

            // ---- Return ----
            op.@"return" => {
                if (machine.depth == 0) return control_vm.returnTop(ctx, stack, frame, generator_state);
                try machine.popReturn(try control_vm.returnTop(ctx, stack, frame, null));
                continue;
            },
            op.return_undef => {
                if (machine.depth == 0) return control_vm.returnUndefined(ctx, frame, generator_state);
                try machine.popReturn(try control_vm.returnUndefined(ctx, frame, null));
                continue;
            },
            op.return_async => {
                if (machine.depth == 0) return control_vm.returnTop(ctx, stack, frame, generator_state);
                try machine.popReturn(try control_vm.returnTop(ctx, stack, frame, null));
                continue;
            },

            // ---- Binary arithmetic ----
            op.add, op.sub, op.mul, op.div, op.mod, op.pow, op.shl, op.sar, op.shr, op.@"and", op.@"or", op.xor => {
                // Inline int32 fast path: replaces binaryVm->binary call frames
                // and pop/defer-free traffic for the common two-int operand case.
                // Semantically identical to binary()'s int32 branch (shared
                // fastBinaryInt32). pow is excluded (no int fast path there).
                if (opc != op.pow and arith_vm.tryInt32Binary(stack, opc)) {
                    if (comptime thread_dispatch) {
                        if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; }
                    }
                    continue;
                }
                if (fusion_stats.fusions_enabled and opc == op.add) {
                    // Fusion failures (string-append OOM in particular) must
                    // reach the frame's catch handler just like the unfused
                    // `binaryVm` path would.
                    const fused_local_append = arith_vm.tryFuseLocalStringAppend(ctx, stack, function, global, frame, sync_global_lexical_locals) catch |err| {
                        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) continue;
                        return err;
                    };
                    if (fusion_stats.fusions_enabled and fusion_stats.counted(.tryFuseLocalStringAppend, fused_local_append)) continue;
                    const fused_global_append = arith_vm.tryFuseGlobalStringAppend(ctx, stack, function, global, frame, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object) catch |err| {
                        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) continue;
                        return err;
                    };
                    if (fusion_stats.fusions_enabled and fusion_stats.counted(.tryFuseGlobalStringAppend, fused_global_append)) continue;
                    const fused_global_add = arith_vm.tryFuseGlobalDataAdd(ctx, stack, function, global, frame, eval_local_names, eval_var_ref_names, eval_with_object) catch |err| {
                        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) continue;
                        return err;
                    };
                    if (fusion_stats.fusions_enabled and fusion_stats.counted(.tryFuseGlobalDataAdd, fused_global_add)) continue;
                }
                switch (try arith_vm.binaryVm(ctx, stack, frame, catch_target, opc, output, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Comparisons ----
            op.lt, op.lte, op.gt, op.gte, op.eq, op.neq, op.strict_eq, op.strict_neq => {
                // Inline int32 fast path (mirrors compare()'s int32 branch).
                if (arith_vm.tryInt32Compare(stack, opc)) {
                    if (comptime thread_dispatch) {
                        if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; }
                    }
                    continue;
                }
                switch (try arith_vm.compareVm(ctx, stack, frame, catch_target, opc, output, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.in, op.instanceof => switch (try vm_property_field.inOrInstanceof(ctx, output, global, stack, function, frame, catch_target, opc)) {
                .done => {},
                .continue_loop => continue,
            },
            op.private_in => {
                switch (try class_vm.privateInVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Unary ----
            op.neg, op.plus => {
                switch (try arith_vm.unaryVm(ctx, stack, frame, catch_target, opc, output, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.not => {
                switch (try arith_vm.bitNotVm(ctx, stack, frame, catch_target, output, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.lnot => try value_vm.logicalNot(ctx.runtime, stack),
            op.inc, op.dec => {
                switch (try arith_vm.unaryVm(ctx, stack, frame, catch_target, opc, output, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Control flow ----
            op.goto => {
                if (fusion_stats.fusions_enabled and stop_before_pc == null and fusion_stats.counted(.tryFuseBackwardGotoGlobalDataInt32CompareFalseBranch, vm_property_globals.tryFuseBackwardGotoGlobalDataInt32CompareFalseBranch(ctx, global, function, frame, op.goto, eval_local_names, eval_var_ref_names, eval_with_object))) continue;
                control_vm.jump32(function, frame);
                if (comptime thread_dispatch) {
                    if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; }
                    continue;
                }
            },
            op.goto16 => {
                if (fusion_stats.fusions_enabled and stop_before_pc == null and fusion_stats.counted(.tryFuseBackwardGotoGlobalDataInt32CompareFalseBranch, vm_property_globals.tryFuseBackwardGotoGlobalDataInt32CompareFalseBranch(ctx, global, function, frame, op.goto16, eval_local_names, eval_var_ref_names, eval_with_object))) continue;
                control_vm.jump16(function, frame);
                if (comptime thread_dispatch) {
                    if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; }
                    continue;
                }
            },
            op.goto8 => {
                if (fusion_stats.fusions_enabled and stop_before_pc == null and fusion_stats.counted(.tryFuseGoto8LocalLessThanFalseBranch, control_vm.tryFuseGoto8LocalLessThanFalseBranch(function, frame))) continue;
                if (fusion_stats.fusions_enabled and stop_before_pc == null and fusion_stats.counted(.tryFuseBackwardGotoGlobalDataInt32CompareFalseBranch, vm_property_globals.tryFuseBackwardGotoGlobalDataInt32CompareFalseBranch(ctx, global, function, frame, op.goto8, eval_local_names, eval_var_ref_names, eval_with_object))) continue;
                control_vm.jump8(function, frame);
                if (comptime thread_dispatch) {
                    if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; }
                    continue;
                }
            },
            op.if_false => try control_vm.branch32(ctx, stack, function, frame, false),
            op.if_true => try control_vm.branch32(ctx, stack, function, frame, true),
            op.if_false8 => { try control_vm.branch8(ctx, stack, function, frame, false); if (comptime thread_dispatch) { if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; } continue; } },
            op.if_true8 => { try control_vm.branch8(ctx, stack, function, frame, true); if (comptime thread_dispatch) { if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; } continue; } },
            op.gosub => try control_vm.gosub(function, frame, stack),
            op.ret => try control_vm.ret(ctx, function, frame, stack),

            // ---- Variable access ----
            op.get_var, op.get_var_undef => switch (try vm_property_globals.getVar(ctx, output, global, stack, function, frame, catch_target, opc, sync_global_lexical_locals, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, eval_with_object)) {
                .done => if (comptime thread_dispatch) {
                    if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; }
                    continue;
                },
                .continue_loop => continue,
            },
            op.make_loc_ref, op.make_arg_ref, op.make_var_ref_ref => try vm_property_ref.makeSlotRef(ctx, stack, function, frame, opc),
            op.make_var_ref => {
                switch (try vm_property_ref.makeVarRefVm(ctx, output, global, stack, function, frame, catch_target, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.get_ref_value => {
                switch (try vm_property_ref.getRefValueVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.put_ref_value => {
                switch (try vm_property_ref.putRefValueVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.put_var => switch (try vm_property_globals.putVar(ctx, output, global, stack, function, frame, catch_target, strict_unresolved_get_var, eval_global_var_bindings, is_eval_code, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, eval_with_object)) {
                .done => if (comptime thread_dispatch) {
                    if (try nextOpcode(function, frame, &interrupt_poller, ctx.runtime, entry_stop_before_pc)) |n| { opc = n; continue :sw n; }
                    continue;
                },
                .continue_loop => continue,
            },
            op.with_get_var, op.with_delete_var, op.with_make_ref, op.with_get_ref, op.with_get_ref_undef => switch (try vm_property_ref.withGetOrDelete(ctx, output, global, stack, function, frame, catch_target, opc)) {
                .done => {},
                .continue_loop => continue,
            },
            op.with_put_var => switch (try vm_property_ref.withPut(ctx, output, global, stack, function, frame, catch_target)) {
                .done => {},
                .continue_loop => continue,
            },
            op.to_object => switch (try value_vm.toObjectVm(ctx, stack, frame, catch_target, global)) {
                .done => {},
                .continue_loop => continue,
            },

            // ---- Object properties ----
            op.get_field, op.get_field2, op.put_field => switch (try vm_property_field.field(ctx, output, global, stack, function, frame, catch_target, opc, sync_global_lexical_locals)) {
                .done => {},
                .continue_loop => continue,
            },
            op.get_private_field => {
                switch (try vm_property_private.getPrivateFieldVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.put_private_field => {
                switch (try vm_property_private.putPrivateFieldVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.define_private_field => {
                switch (try vm_property_private.definePrivateFieldVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Array elements ----
            op.get_array_el, op.get_array_el2, op.put_array_el => switch (try vm_property_field.arrayElement(ctx, output, global, stack, function, frame, catch_target, opc)) {
                .done => {},
                .continue_loop => continue,
            },

            // ---- Super ----
            op.get_super => try class_vm.getSuper(ctx, stack, frame),
            op.get_super_value => switch (try class_vm.getSuperValue(ctx, output, global, stack, function, frame, catch_target)) {
                .done => {},
                .continue_loop => continue,
            },
            op.put_super_value => switch (try class_vm.putSuperValue(ctx, output, global, stack, function, frame, catch_target)) {
                .done => {},
                .continue_loop => continue,
            },

            // ---- Calls ----
            op.call, op.call0, op.call1, op.call2, op.call3 => {
                switch (try call_vm.call(ctx, output, global, stack, function, frame, catch_target, opc)) {
                    .done => {},
                    .continue_loop => continue,
                    .inline_call => |request| {
                        if (comptime recurse_or_tailcall_enabled) {
                            // S2a-v3: near the native cap, absorb deep recursion on
                            // the Machine (no native growth); else native recurse.
                            if (call_vm.nativeDepthNearCap(ctx)) {
                                machine.pushCall(global, stack, request.target, request.region_base, request.argc, request.layout) catch |err| {
                                    try closeStackTopForOfIteratorForPendingError(ctx, output, global, stack);
                                    if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) continue;
                                    return err;
                                };
                                continue;
                            }
                            // S2a pivot: native recursion instead of an inline Machine frame.
                            switch (try recurseInline(ctx, output, global, stack, frame, catch_target, request)) {
                                .value => |v| stack.pushOwnedAssumeCapacity(v),
                                .caught => continue,
                            }
                        } else {
                            machine.pushCall(global, stack, request.target, request.region_base, request.argc, request.layout) catch |err| {
                                try closeStackTopForOfIteratorForPendingError(ctx, output, global, stack);
                                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) continue;
                                return err;
                            };
                            continue;
                        }
                    },
                }
            },
            op.tail_call => switch (try call_vm.tailCall(ctx, output, global, stack, function, frame, catch_target, machine.depth > 0)) {
                .handled => continue,
                .return_value => |value| {
                    if (machine.depth == 0) return value;
                    try machine.popReturn(value);
                    continue;
                },
                // Proper tail call: replace the current inline frame, keeping
                // the logical call depth constant. Errors are OOM-class (the
                // depth slot was just vacated) and propagate via the outer
                // unwind, like an error thrown by the callee on entry.
                .tail_inline => |request| {
                    try machine.tailCallReuse(global, stack, request.target, request.region_base, request.argc, request.layout);
                    continue;
                },
            },
            op.eval => switch (try eval_module_vm.directEval(ctx, stack, function, frame, catch_target, output, global, eval_class_field_initializer_flag, eval_parameter_initializer_flag, machine.depth > 0)) {
                .done => {},
                .continue_loop => continue,
                // Non-%eval% callee in tail position: proper tail call via
                // frame reuse, mirroring the op.tail_call leg.
                .tail_inline => |request| {
                    try machine.tailCallReuse(global, stack, request.target, request.region_base, request.argc, request.layout);
                    continue;
                },
            },
            op.apply_eval => switch (try eval_module_vm.applyEval(ctx, stack, function, frame, catch_target, output, global, eval_class_field_initializer_flag, eval_parameter_initializer_flag)) {
                .done => {},
                .continue_loop => continue,
            },
            op.import => try eval_module_vm.dynamicImport(ctx, output, global, stack, function, frame),
            op.prepare_call_prop_atom => switch (try call_vm.prepareCallPropAtom(ctx, output, global, stack, function, frame, catch_target)) {
                .done => {},
                .continue_loop => continue,
            },
            op.call_prepared => switch (try call_vm.callPrepared(ctx, output, global, stack, function, frame, catch_target, true)) {
                .done => {},
                .continue_loop => continue,
                // Prepared property call to a plain bytecode function: run it as
                // an inline frame (receiver becomes `this`), mirroring op.call.
                .inline_call => |request| {
                    if (comptime recurse_or_tailcall_enabled) {
                        if (call_vm.nativeDepthNearCap(ctx)) {
                            machine.pushCall(global, stack, request.target, request.region_base, request.argc, request.layout) catch |err| {
                                try closeStackTopForOfIteratorForPendingError(ctx, output, global, stack);
                                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) continue;
                                return err;
                            };
                            continue;
                        }
                        switch (try recurseInline(ctx, output, global, stack, frame, catch_target, request)) {
                            .value => |v| stack.pushOwnedAssumeCapacity(v),
                            .caught => continue,
                        }
                    } else {
                        machine.pushCall(global, stack, request.target, request.region_base, request.argc, request.layout) catch |err| {
                            try closeStackTopForOfIteratorForPendingError(ctx, output, global, stack);
                            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) continue;
                            return err;
                        };
                        continue;
                    }
                },
            },
            op.call_method => switch (try call_vm.callMethod(ctx, output, global, stack, function, frame, catch_target, true)) {
                .done => {},
                .continue_loop => continue,
                // Method call to a plain bytecode function: run it as an inline
                // frame (receiver becomes `this`), mirroring the op.call leg.
                .inline_call => |request| {
                    if (comptime recurse_or_tailcall_enabled) {
                        if (call_vm.nativeDepthNearCap(ctx)) {
                            machine.pushCall(global, stack, request.target, request.region_base, request.argc, request.layout) catch |err| {
                                try closeStackTopForOfIteratorForPendingError(ctx, output, global, stack);
                                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) continue;
                                return err;
                            };
                            continue;
                        }
                        switch (try recurseInline(ctx, output, global, stack, frame, catch_target, request)) {
                            .value => |v| stack.pushOwnedAssumeCapacity(v),
                            .caught => continue,
                        }
                    } else {
                        machine.pushCall(global, stack, request.target, request.region_base, request.argc, request.layout) catch |err| {
                            try closeStackTopForOfIteratorForPendingError(ctx, output, global, stack);
                            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) continue;
                            return err;
                        };
                        continue;
                    }
                },
            },
            op.tail_call_method => switch (try call_vm.tailCallMethod(ctx, output, global, stack, function, frame, catch_target, machine.depth > 0)) {
                .handled => continue,
                .return_value => |value| {
                    if (machine.depth == 0) return value;
                    try machine.popReturn(value);
                    continue;
                },
                // Tail-positioned method call to a plain bytecode function:
                // reuse the current inline frame with the receiver as `this`,
                // mirroring the op.tail_call leg.
                .tail_inline => |request| {
                    try machine.tailCallReuse(global, stack, request.target, request.region_base, request.argc, request.layout);
                    continue;
                },
            },

            // ---- Object/array literals ----
            op.object => try literal_vm.object(ctx, stack, global),
            op.array_from => try literal_vm.arrayFrom(ctx, stack, function, frame, global),
            op.define_field => switch (try literal_vm.defineField(ctx, output, global, stack, function, frame, catch_target)) {
                .done => {},
                .continue_loop => continue,
            },
            op.set_proto => try literal_vm.setProto(ctx, stack),
            op.set_home_object => try class_vm.setHomeObject(ctx, stack),
            op.define_class, op.define_class_computed => {
                switch (try class_vm.defineClass(ctx, output, global, stack, function, frame, catch_target, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, opc == op.define_class_computed)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.define_array_el => switch (try literal_vm.defineArrayEl(ctx, output, global, stack, function, frame, catch_target)) {
                .done => {},
                .continue_loop => continue,
            },
            op.define_method => {
                switch (try class_vm.defineMethod(ctx, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.define_method_computed => {
                switch (try class_vm.defineMethodComputed(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.append => switch (try literal_vm.appendSpreadValuesVm(ctx, output, global, stack, opc, frame, catch_target)) {
                .done => {},
                .continue_loop => continue,
            },
            op.copy_data_properties => {
                const mask = function.code[frame.pc];
                frame.pc += 1;
                switch (try literal_vm.copyDataProperties(ctx, output, global, stack, mask, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Generators (F9) ----
            op.initial_yield => switch (try gen_async_vm.initialYield(ctx, stack, frame, generator_state, stop_on_yield)) {
                .none => {},
                .continue_loop => continue,
                .return_value => |value| return value,
            },
            op.yield => switch (try gen_async_vm.yieldValue(ctx, stack, frame, generator_state, stop_on_yield)) {
                .none => {},
                .continue_loop => continue,
                .return_value => |value| return value,
            },
            op.yield_star, op.async_yield_star => {
                const yield_star_result = try gen_async_vm.yieldStar(ctx, output, global, stack, function, frame, generator_state, stop_on_yield, catch_target);
                switch (yield_star_result) {
                    .none => {},
                    .continue_loop => continue,
                    .return_value => |value| return value,
                }
            },
            op.await => {
                const await_result = try gen_async_vm.awaitValue(ctx, output, global, stack, function, frame, generator_state, suspend_on_module_await, stop_on_yield, catch_target);
                switch (await_result) {
                    .none => {},
                    .continue_loop => continue,
                    .return_value => |value| return value,
                }
            },

            // ---- Global variable operations ----
            op.check_define_var, op.define_var, op.define_func, op.put_var_init => switch (try vm_property_globals.globalDefinition(ctx, global, stack, function, frame, catch_target, opc, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, eval_global_var_bindings, is_eval_code)) {
                .done => {},
                .continue_loop => continue,
            },

            // ---- Special object (prologue) ----
            op.special_object => try literal_vm.specialObject(ctx, stack, function, frame, global, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs),

            // ---- Typeof ----
            op.typeof => try value_vm.typeOf(ctx, stack),
            op.typeof_is_undefined => try value_vm.typeOfIsUndefined(ctx.runtime, stack),
            op.typeof_is_function => try value_vm.typeOfIsFunction(ctx.runtime, stack),

            // ---- Throw ----
            op.throw => switch (try control_vm.throwTop(ctx, output, global, stack, frame, catch_target)) {
                .handled => continue,
            },
            op.throw_error => switch (try control_vm.throwErrorVm(ctx, stack, function, frame, catch_target, global)) {
                .handled => continue,
            },
            op.@"catch" => try control_vm.catchTarget(function, frame, stack, catch_target),
            op.check_ctor => {
                switch (try call_vm.checkCtorVm(ctx, stack, frame, catch_target, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.check_ctor_return => {
                switch (try call_vm.checkCtorReturnVm(ctx, stack, frame, catch_target, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.init_ctor => {
                switch (try call_vm.initCtorVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.check_brand => {
                switch (try class_vm.checkBrandVm(ctx, stack, frame, catch_target, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.add_brand => {
                switch (try class_vm.addBrandVm(ctx, stack, frame, catch_target, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.close_loc => try vm_property_locals.closeLoc(ctx, function, frame),

            // ---- NOP ----
            op.nop => control_vm.nop(),

            // ---- Push this ----
            op.push_this => switch (try value_vm.pushThisVm(ctx, stack, frame, catch_target, global)) {
                .done => {},
                .continue_loop => continue,
            },

            // ---- Delete ----
            op.delete_var => try vm_property_ref.deleteVar(ctx, global, stack, function, frame, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs),
            op.delete => switch (try vm_property_ref.deletePropertyVm(ctx, output, global, stack, function, frame, catch_target)) {
                .done => {},
                .continue_loop => continue,
            },

            // ---- Additional stack manipulation ----
            op.nip => try value_vm.nip(ctx, stack),
            op.nip1 => try value_vm.nip1(ctx, stack),
            op.dup1 => try value_vm.dup1(ctx, stack),
            op.dup2 => try value_vm.dup2(ctx, stack),
            op.dup3 => try value_vm.dup3(ctx, stack),
            op.insert2 => try value_vm.insert2(ctx, stack),
            op.insert3 => try value_vm.insert3(ctx, stack),
            op.insert4 => try value_vm.insert4(ctx, stack),
            op.rot3l => try value_vm.rot3l(ctx, stack),
            op.rot3r => try value_vm.rot3r(ctx, stack),
            op.rot4l => try value_vm.rot4l(ctx, stack),
            op.rot5l => try value_vm.rot5l(ctx, stack),
            op.perm3 => try value_vm.perm3(ctx, stack),
            op.perm4 => try value_vm.perm4(ctx, stack),
            op.perm5 => try value_vm.perm5(ctx, stack),
            op.swap2 => try value_vm.swap2(ctx, stack),
            op.is_undefined_or_null => try value_vm.isUndefinedOrNull(ctx.runtime, stack),
            op.is_undefined => try value_vm.isUndefined(ctx.runtime, stack),
            op.is_null => try value_vm.isNull(ctx.runtime, stack),
            op.get_length => switch (try literal_vm.getLength(ctx, output, global, stack, function, frame, catch_target)) {
                .done => {},
                .continue_loop => continue,
            },
            op.post_inc, op.post_dec => {
                switch (try arith_vm.postUpdateVm(ctx, stack, frame, catch_target, opc, output, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.inc_loc, op.dec_loc => {
                switch (try arith_vm.updateLocalVm(ctx, stack, function, global, frame, catch_target, opc, output, sync_global_lexical_locals)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.add_loc => {
                switch (try arith_vm.addLocalVm(ctx, stack, function, global, frame, catch_target, output, sync_global_lexical_locals)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.apply => {
                switch (try call_vm.apply(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Rest / spread ----
            op.rest => try literal_vm.rest(ctx, stack, function, frame),

            // ---- Iterator protocol ----
            op.for_of_start, op.for_await_of_start => {
                switch (try iter_vm.forOfStartVm(ctx, output, global, stack, function, frame, catch_target, opc == op.for_await_of_start)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.for_in_start => {
                switch (try iter_vm.forInStartVm(ctx, output, global, stack, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.iterator_next => {
                switch (try iter_vm.iteratorNextVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.iterator_check_object => {
                switch (try iter_vm.iteratorCheckObjectVm(ctx, stack, frame, catch_target, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.iterator_get_value_done => {
                switch (try iter_vm.iteratorGetValueDoneVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.iterator_call => {
                switch (try iter_vm.iteratorCallVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.for_of_next => {
                switch (try iter_vm.forOfNextVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.for_in_next => try iter_vm.forInNext(ctx, output, global, stack),
            op.iterator_close => {
                switch (try iter_vm.iteratorCloseVm(ctx, output, global, stack, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Constructor ----
            op.call_constructor => switch (try call_vm.constructor(ctx, output, global, stack, function, frame, catch_target)) {
                .done => {},
                .continue_loop => continue,
            },

            op.invalid => return error.InvalidBytecode,

            else => return error.InvalidBytecode,
        }
    }

    const value = stack.peek() orelse core.JSValue.undefinedValue();
    return control_vm.finishFunctionReturn(ctx, frame, value);
}

// ---- Helpers ----
// ---- Shared helper aliases ----
const closeStackTopForOfIteratorForPendingError = forof_ops.closeStackTopForOfIteratorForPendingError;
const constructorPrototypeFromGlobal = class_vm.constructorPrototypeFromGlobal;
const handleCatchableRuntimeError = call_runtime.handleCatchableRuntimeError;
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
