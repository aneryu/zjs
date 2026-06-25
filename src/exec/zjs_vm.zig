//! QuickJS-aligned VM dispatcher for bytecode produced by
//! `frontend/zjs_parser.zig`, tracked by the current semantic
//! alignment plans.
//!
//! This is the only VM dispatcher after the parser-rewrite M2 swap.
//!
//! The dispatcher handles QuickJS-format opcodes emitted by the parser after
//! the bytecode pipeline has removed temporary opcodes.

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
const value_ops_mod = @import("value_ops.zig");
const HostError = exceptions.HostError;

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
    entry_stop_before_pc: ?usize,
) ?u8 {
    // qjs-aligned straight-line fetch: no interrupt poll (moved to the branch
    // opcodes) and NO error union — returns a plain `?u8` so the fetched
    // opcode stays in a register instead of materializing a `!?u8`
    // {error,optional,value} struct on the stack each dispatch.
    if (entry_stop_before_pc != null) return null;
    if (frame.pc >= function.code.len) return null;
    const opc = function.code[frame.pc];
    frame.pc += 1;
    return opc;
}

/// Publish the register-resident window back into canonical frame/stack before a
/// cold opcode (or the prologue) reads them. `reg_ip -> frame.pc` (byte offset),
/// `reg_sp -> stack.values` (live operand length). The prologue then re-derives
/// the registers from canonical state on cold re-entry.
inline fn syncDown(
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    reg_ip: [*]const u8,
    reg_base: [*]core.JSValue,
    reg_sp: [*]core.JSValue,
) void {
    frame.pc = (@intFromPtr(reg_ip) - @intFromPtr(function.code.ptr));
    stack.values = reg_base[0 .. (@intFromPtr(reg_sp) - @intFromPtr(reg_base)) / @sizeOf(core.JSValue)];
}

/// Threaded post-call / post-return resume: reload the dispatch loop's per-level
/// locals + registers from the machine's top inline Entry and fetch the next
/// opcode, WITHOUT re-entering the cold prologue (no `switched` branch, no
/// fall-through bound check, no generator stop check). Used by the inline call /
/// return arms while in the inline regime (the 10 inline-invariant locals are
/// already established), so a deep recursion resumes straight into the next
/// opcode — qjs's post-OP_call `*sp++ = ret; opcode = *pc++; BREAK`
/// (quickjs.c:18199-18201) is the structural analog. Returns the opcode to
/// `continue :sw`; advances `reg_ip` and `frame.pc` past it.
inline fn reloadInlineTopFrame(
    machine: *inline_calls.Machine,
    function: *(*const bytecode.Bytecode),
    stack: *(*stack_mod.Stack),
    frame: *(*frame_mod.Frame),
    catch_target: *(*?usize),
    eval_var_ref_names: *[]const core.Atom,
    eval_var_refs: *[]core.JSValue,
    strict_unresolved_get_var: *bool,
    reg_ip: *[*]const u8,
    reg_code_end: *[*]const u8,
    reg_base: *[*]core.JSValue,
    reg_sp: *[*]core.JSValue,
    reg_var_buf: *[*]core.JSValue,
    reg_arg_buf: *[*]core.JSValue,
) u8 {
    const entry = machine.topEntry();
    function.* = entry.function;
    stack.* = &entry.stack;
    frame.* = &entry.frame;
    catch_target.* = &entry.catch_target;
    eval_var_ref_names.* = entry.frame.evalVarRefNames();
    eval_var_refs.* = entry.frame.evalVarRefs();
    strict_unresolved_get_var.* = entry.function.flags.is_strict or entry.function.flags.runtime_strict;
    reg_ip.* = entry.function.code.ptr + entry.frame.pc;
    reg_code_end.* = entry.function.code.ptr + entry.function.code.len;
    reg_base.* = entry.stack.values.ptr;
    reg_sp.* = entry.stack.values.ptr + entry.stack.values.len;
    reg_var_buf.* = entry.frame.locals.ptr;
    reg_arg_buf.* = entry.frame.args.ptr;
    machine.switched = false;
    const next = reg_ip.*[0];
    reg_ip.* += 1;
    entry.frame.pc += 1;
    return next;
}

const LocalOperand = struct {
    idx: u16,
    consume: u8,
};

inline fn decodeLocalOperand(opc: u8, reg_ip: [*]const u8) LocalOperand {
    return switch (opc) {
        op.get_loc, op.put_loc, op.set_loc => .{
            .idx = std.mem.readInt(u16, reg_ip[0..2], .little),
            .consume = 2,
        },
        op.get_loc8, op.put_loc8, op.set_loc8 => .{
            .idx = @intCast(reg_ip[0]),
            .consume = 1,
        },
        op.get_loc0, op.get_loc1, op.get_loc2, op.get_loc3 => .{
            .idx = @intCast(opc - op.get_loc0),
            .consume = 0,
        },
        op.put_loc0, op.put_loc1, op.put_loc2, op.put_loc3 => .{
            .idx = @intCast(opc - op.put_loc0),
            .consume = 0,
        },
        op.set_loc0, op.set_loc1, op.set_loc2, op.set_loc3 => .{
            .idx = @intCast(opc - op.set_loc0),
            .consume = 0,
        },
        else => unreachable,
    };
}

inline fn localStoreNeedsSlowSync(frame: *const frame_mod.Frame, idx: u16, sync_global_lexical_locals: bool) bool {
    if (!sync_global_lexical_locals) return false;
    if (!frame.globalLexicalSyncChecked()) return true;
    const slots = frame.globalLexicalSyncSlots();
    return idx < slots.len and slots[idx];
}

inline fn localFastPathNeedsGeneratorStopBoundary(stop_before_pc: ?usize) bool {
    // Generator.return() resumes through try/catch/finally cleanup with a
    // stop-before-PC boundary. A threaded local fast path would fetch the
    // boundary opcode directly and skip the prologue check that saves the
    // generator state, so route locals through the slow handler while active.
    return stop_before_pc != null;
}

inline fn isDerivedConstructorThisLocal(function: *const bytecode.Bytecode, idx: u16) bool {
    return function.flags.is_derived_class_constructor and
        idx < function.var_names.len and
        function.var_names[idx] == 8;
}

inline fn dispatchFastInt32Add(lhs: i32, rhs: i32) core.JSValue {
    const result = @addWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.JSValue.int32(result[0]);
    return value_ops_mod.numberToValue(@as(f64, @floatFromInt(lhs)) + @as(f64, @floatFromInt(rhs)));
}

inline fn dispatchFastInt32Sub(lhs: i32, rhs: i32) core.JSValue {
    const result = @subWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.JSValue.int32(result[0]);
    return value_ops_mod.numberToValue(@as(f64, @floatFromInt(lhs)) - @as(f64, @floatFromInt(rhs)));
}

inline fn dispatchFastInt32Mul(lhs: i32, rhs: i32) core.JSValue {
    if ((lhs == 0 and rhs < 0) or (rhs == 0 and lhs < 0)) return core.JSValue.float64(-0.0);
    const result = @mulWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.JSValue.int32(result[0]);
    return value_ops_mod.numberToValue(@as(f64, @floatFromInt(lhs)) * @as(f64, @floatFromInt(rhs)));
}

inline fn dispatchFastInt32Mod(lhs: i32, rhs: i32) core.JSValue {
    if (rhs == 0) return core.JSValue.float64(std.math.nan(f64));
    if (rhs == -1) return if (lhs < 0) core.JSValue.float64(-0.0) else core.JSValue.int32(0);
    const r = @rem(lhs, rhs);
    // The remainder's sign follows the dividend: when it is zero and the
    // dividend is negative, the result is -0 (a float), not int32 +0.
    if (r == 0 and lhs < 0) return core.JSValue.float64(-0.0);
    return core.JSValue.int32(r);
}

inline fn dispatchFastBinaryInt32(binop: u8, lhs: i32, rhs: i32) ?core.JSValue {
    return switch (binop) {
        op.add => dispatchFastInt32Add(lhs, rhs),
        op.sub => dispatchFastInt32Sub(lhs, rhs),
        op.mul => dispatchFastInt32Mul(lhs, rhs),
        op.div => value_ops_mod.numberToValue(@as(f64, @floatFromInt(lhs)) / @as(f64, @floatFromInt(rhs))),
        op.mod => dispatchFastInt32Mod(lhs, rhs),
        op.shl => core.JSValue.int32(lhs << @intCast(rhs & 31)),
        op.sar => core.JSValue.int32(lhs >> @intCast(rhs & 31)),
        op.shr => value_ops_mod.numberToValue(@floatFromInt(@as(u32, @bitCast(lhs)) >> @intCast(rhs & 31))),
        op.@"and" => core.JSValue.int32(lhs & rhs),
        op.@"or" => core.JSValue.int32(lhs | rhs),
        op.xor => core.JSValue.int32(lhs ^ rhs),
        else => null,
    };
}

inline fn dispatchFieldOwnDataIcValue(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    receiver: core.JSValue,
    atom_id: core.Atom,
) ?core.JSValue {
    const object = class_vm.objectFromValue(receiver) orelse return null;
    const slot = function.icSlotForPc(site_pc) orelse return null;
    if (slot.state != .mono) return null;
    const entry = slot.entries[0];
    if (entry.holder_shape_ref != null or
        entry.shape_ref != object.shape_ref or
        entry.atom_id != atom_id or
        entry.version != object.shape_ref.version)
    {
        return null;
    }
    if (entry.slot_index >= object.properties.len) return null;
    return switch (object.properties[entry.slot_index].slot) {
        .data => |stored| stored,
        .var_ref, .auto_init, .accessor, .deleted => null,
    };
}

inline fn dispatchFieldOwnDataIcStoreOwned(
    rt: *core.JSRuntime,
    function: *const bytecode.Bytecode,
    site_pc: usize,
    receiver: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
) bool {
    const object = class_vm.objectFromValue(receiver) orelse return false;
    if (object.needsSlowPropertyAccess() or object.hasExoticMethods()) return false;
    const slot = function.icSlotForPc(site_pc) orelse return false;
    if (slot.state != .mono) return false;
    const entry = slot.entries[0];
    if (entry.holder_shape_ref != null or
        entry.shape_ref != object.shape_ref or
        entry.atom_id != atom_id or
        entry.version != object.shape_ref.version)
    {
        return false;
    }
    if (entry.slot_index >= object.shapeProps().len) return false;
    const prop = object.shapeProps()[entry.slot_index];
    const prop_flags = core.property.Flags.fromBits(prop.flags);
    if (prop.atom_id != atom_id or prop_flags.deleted or prop_flags.accessor or !prop_flags.writable) return false;
    const property_entry = &object.properties[entry.slot_index];
    return switch (property_entry.slot) {
        .data => blk: {
            const old_slot = property_entry.slot;
            property_entry.slot = .{ .data = value };
            core.object.destroyPropertySlot(rt, atom_id, old_slot);
            break :blk true;
        },
        .var_ref, .auto_init, .accessor, .deleted => false,
    };
}

inline fn dispatchFastUpdateInt32(opcode_id: u8, value: i32) core.JSValue {
    return switch (opcode_id) {
        op.post_inc, op.inc_loc => dispatchFastInt32Add(value, 1),
        op.post_dec, op.dec_loc => dispatchFastInt32Sub(value, 1),
        else => unreachable,
    };
}

/// Branch-opcode fetch: polls for interrupts (the loop back-edge poll point)
/// before the threaded fetch. Used by goto / if_* arms.
inline fn nextOpcodePoll(
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

    const use_inline_frame_storage = entry_generator_state == null and !entry_function.flags.is_generator and !entry_function.flags.is_async;
    const frame_arena: ?*core.VmStackArena = if (use_inline_frame_storage) &ctx.runtime.vm_stack else null;
    const need_original_args = argumentsNeedsOriginalSnapshot(entry_function);
    const frame_arg_count = frame_mod.frameArgCount(entry_function, args.len);
    const open_var_ref_count = frame_mod.frameOpenVarRefStorageCount(entry_function, frame_arg_count);
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
    try call_vm.initFrameLocals(ctx, entry_function, &frame_storage, entry_eval_local_names, entry_eval_local_slots, use_inline_frame_storage, frame_windows);
    try frame_storage.initArguments(&ctx.runtime.memory, frame_arena, args, use_inline_frame_storage, need_original_args, frame_windows);
    if (frame_windows.open_var_refs) |open_refs| frame_storage.installOpenVarRefSlots(open_refs) else if (open_var_ref_count != 0) try frame_storage.ensureOpenVarRefSlots(&ctx.runtime.memory, frame_arena, use_inline_frame_storage);
    try call_vm.initFrameVarRefs(ctx, global, entry_function, &frame_storage, var_refs, use_inline_frame_storage, frame_windows);
    if (entry_generator_state == null) {
        try vm_property_globals.instantiateGlobalVarDeclarations(ctx, global, entry_function, &frame_storage, entry_is_eval_code, entry_eval_local_names, entry_eval_local_slots, frame_storage.evalVarRefNames(), frame_storage.evalVarRefs());
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
    var eval_var_ref_names = frame_storage.evalVarRefNames();
    var eval_var_refs = frame_storage.evalVarRefs();
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
    // For an inline (depth>0) frame these 10 per-level locals are always the same
    // constants (no eval, no generator, not eval-code). They only change at the
    // L0<->inline boundary, so the prologue sets them ONCE on entering the inline
    // regime and skips them on every inline->inline frame switch — fib recurses
    // deep, so almost every switch is inline->inline. Reset to false whenever the
    // depth==0 (L0) branch runs so the next inline entry re-establishes them.
    var inline_invariants_set = false;

    var interrupt_poller = control_vm.InterruptPoller.init(ctx.runtime);
    // `opc` lives across `continue :sw` threaded re-dispatch so combined arms
    // (get_loc0..3, binary, get_var, ...) read the *current* opcode, not the
    // stale one the labeled switch was originally entered with.
    var opc: u8 = undefined;
    // ---- Register-resident hot state (reverse-migrated from dispatchRecursive) ----
    // `reg_ip` is the C-local instruction pointer LLVM keeps in a register — qjs's
    // `*pc++`. It mirrors `frame.pc` and is (re)derived as `function.code.ptr +
    // frame.pc` at the single canonical reload point below (which runs after the
    // `machine.switched` frame-identity refresh and on every cold re-entry). Hot
    // arms advance `reg_ip` directly; cold arms publish it back via `frame.pc`.
    var reg_ip: [*]const u8 = undefined;
    // Operand-stack window (qjs's `base`/`sp`) + locals pointer (`var_buf`),
    // register-resident across `continue :sw` threading. Re-derived from
    // stack.values / frame.locals at the canonical reload point below.
    var reg_base: [*]core.JSValue = undefined;
    var reg_sp: [*]core.JSValue = undefined;
    var reg_var_buf: [*]core.JSValue = undefined;
    // qjs keeps arg_buf register-resident (a JS_CallInternal local); mirror it
    // so threaded get_arg0..3 read args without reloading frame.args from memory.
    var reg_arg_buf: [*]core.JSValue = undefined;
    var reg_code_end: [*]const u8 = undefined;
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
                eval_var_ref_names = frame_storage.evalVarRefNames();
                eval_var_refs = frame_storage.evalVarRefs();
                eval_with_object = entry_eval_with_object;
                eval_global_var_bindings = entry_eval_global_var_bindings;
                is_eval_code = entry_is_eval_code;
                sync_global_lexical_locals = entry_sync_global_lexical_locals;
                strict_unresolved_get_var = entry_strict_unresolved_get_var;
                generator_state = entry_generator_state;
                stop_on_yield = entry_stop_on_yield;
                stop_before_pc = entry_stop_before_pc;
                suspend_on_module_await = entry_suspend_on_module_await;
                // Left the inline regime: the next inline entry must re-establish
                // the inline invariants (L0 may be eval/generator/eval-code).
                inline_invariants_set = false;
            } else {
                const entry = machine.topEntry();
                function = entry.function;
                stack = &entry.stack;
                frame = &entry.frame;
                catch_target = &entry.catch_target;
                eval_var_ref_names = entry.frame.evalVarRefNames();
                eval_var_refs = entry.frame.evalVarRefs();
                strict_unresolved_get_var = entry.function.flags.is_strict or entry.function.flags.runtime_strict;
                // The 10 inline-invariant locals are identical for every inline
                // frame; set them once when entering the inline regime, then skip
                // on every inline->inline switch (the common deep-recursion case).
                if (!inline_invariants_set) {
                    eval_local_names = &.{};
                    eval_local_slots = &.{};
                    eval_with_object = core.JSValue.undefinedValue();
                    eval_global_var_bindings = false;
                    is_eval_code = false;
                    sync_global_lexical_locals = false;
                    generator_state = null;
                    stop_on_yield = false;
                    stop_before_pc = null;
                    suspend_on_module_await = false;
                    inline_invariants_set = true;
                }
            }
        }
        // Canonical register reload: runs after the switched-block frame refresh and
        // on every cold (prologue) re-entry. Hot threaded arms (`continue :sw`) skip
        // the prologue entirely, so they never pay this — they carry the registers live.
        reg_ip = function.code.ptr + frame.pc;
        reg_code_end = function.code.ptr + function.code.len;
        reg_base = stack.values.ptr;
        reg_sp = stack.values.ptr + stack.values.len;
        reg_var_buf = frame.locals.ptr;
        reg_arg_buf = frame.args.ptr;
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

        opc = reg_ip[0];
        reg_ip += 1;
        frame.pc += 1;
        const opcode_profile_scope = profile_vm.enterOpcode(ctx.runtime, opc);
        defer opcode_profile_scope.deinit();
        sw: switch (opc) {
            // ---- Push constants ----
            op.push_i32 => {
                if (comptime thread_dispatch) {
                    const value = std.mem.readInt(i32, reg_ip[0..4], .little);
                    reg_ip += 4;
                    reg_sp[0] = core.JSValue.int32(value);
                    reg_sp += 1;
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                try value_vm.pushInt32Operand(stack, function, frame);
            },
            op.push_bigint_i32 => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.pushBigIntI32Operand(stack, function, frame);
            },
            op.push_i16 => {
                if (comptime thread_dispatch) {
                    const value = std.mem.readInt(i16, reg_ip[0..2], .little);
                    reg_ip += 2;
                    reg_sp[0] = core.JSValue.int32(value);
                    reg_sp += 1;
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.pushI16OperandVm(ctx, stack, function, frame, .{
                    .global = global,
                    .eval_local_names = eval_local_names,
                    .eval_var_ref_names = eval_var_ref_names,
                    .eval_with_object = eval_with_object,
                });
            },
            op.push_i8 => {
                if (comptime thread_dispatch) {
                    const value: i8 = @bitCast(reg_ip[0]);
                    reg_ip += 1;
                    reg_sp[0] = core.JSValue.int32(value);
                    reg_sp += 1;
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.pushI8Operand(stack, function, frame);
            },
            op.push_minus1, op.push_0, op.push_1, op.push_2, op.push_3, op.push_4, op.push_5, op.push_6, op.push_7 => {
                const value: i32 = switch (opc) {
                    op.push_minus1 => -1,
                    op.push_0 => 0,
                    op.push_1 => 1,
                    op.push_2 => 2,
                    op.push_3 => 3,
                    op.push_4 => 4,
                    op.push_5 => 5,
                    op.push_6 => 6,
                    op.push_7 => 7,
                    else => unreachable,
                };
                if (comptime thread_dispatch) {
                    reg_sp[0] = core.JSValue.int32(value);
                    reg_sp += 1;
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.pushSmallIntMaybeFuse(stack, function, frame, value);
            },
            op.push_const => {
                if (comptime thread_dispatch) push_const_int32_fast: {
                    const index: usize = @intCast(std.mem.readInt(u32, reg_ip[0..4], .little));
                    if (index >= function.constants.values.len) break :push_const_int32_fast;
                    const value = function.constants.values[index].asInt32() orelse break :push_const_int32_fast;
                    reg_ip += 4;
                    reg_sp[0] = core.JSValue.int32(value);
                    reg_sp += 1;
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.pushConst(ctx, stack, function, frame, opc);
            },
            op.push_const8 => {
                if (comptime thread_dispatch) push_const8_int32_fast: {
                    const index: usize = reg_ip[0];
                    if (index >= function.constants.values.len) break :push_const8_int32_fast;
                    const value = function.constants.values[index].asInt32() orelse break :push_const8_int32_fast;
                    reg_ip += 1;
                    reg_sp[0] = core.JSValue.int32(value);
                    reg_sp += 1;
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.pushConst8(ctx, stack, function, frame, opc);
            },
            op.private_symbol => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.pushPrivateSymbol(ctx, stack, function, frame);
            },
            op.regexp => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try regexp_vm.pushLiteral(ctx, stack, constructorPrototypeFromGlobal(ctx.runtime, global, "RegExp"));
            },
            op.fclosure, op.fclosure8 => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try call_vm.closure(ctx, output, global, stack, function, frame, catch_target, opc, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.undefined => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.pushUndefined(stack);
            },
            op.null => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.pushNull(stack);
            },
            op.push_false => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.pushBoolean(stack, false);
            },
            op.push_true => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.pushBoolean(stack, true);
            },

            // ---- Locals (F10.1b / F10.2 short-forms) ----
            // get_loc / put_loc / set_loc lowered from scope_get_var /
            // scope_put_var by `resolve_variables` when the atom
            // resolves to a `VarDef` in the parser's `function_def`.
            // `selectShortLoc` picks the shortest encoding:
            //   - idx ∈ [0, 4)    → 1-byte short form (idx in opcode)
            //   - idx ∈ [4, 256)  → 2-byte u8-form (`get_loc8`, ...)
            //   - idx ∈ [256, 2^16) → 3-byte u16-form
            // qjs-aligned local fast path: plain locals are direct var_buf[idx]
            // reads/writes. Var-ref cells, RHS var-ref values, eval/global
            // sync, and other uncommon cases fall through to the chain-aware
            // handlers.
            op.get_loc, op.put_loc, op.set_loc, op.get_loc8, op.put_loc8, op.set_loc8, op.get_loc0, op.get_loc1, op.get_loc2, op.get_loc3, op.put_loc0, op.put_loc1, op.put_loc2, op.put_loc3, op.set_loc0, op.set_loc1, op.set_loc2, op.set_loc3 => {
                if (comptime thread_dispatch) local_fast: {
                    if (localFastPathNeedsGeneratorStopBoundary(stop_before_pc)) break :local_fast;
                    const operand = decodeLocalOperand(opc, reg_ip);
                    const idx = operand.idx;
                    const old_v = reg_var_buf[idx];
                    if (slot_ops.varRefCellFromValue(old_v) != null) break :local_fast;

                    switch (opc) {
                        op.get_loc, op.get_loc8, op.get_loc0, op.get_loc1, op.get_loc2, op.get_loc3 => {
                            reg_ip += operand.consume;
                            reg_sp[0] = old_v.dup();
                            reg_sp += 1;
                        },
                        op.put_loc, op.put_loc8, op.put_loc0, op.put_loc1, op.put_loc2, op.put_loc3 => {
                            if (localStoreNeedsSlowSync(frame, idx, sync_global_lexical_locals)) break :local_fast;
                            const value = (reg_sp - 1)[0];
                            if (slot_ops.varRefCellFromValue(value) != null) break :local_fast;
                            reg_ip += operand.consume;
                            reg_sp -= 1;
                            reg_var_buf[idx] = value;
                            old_v.free(ctx.runtime);
                        },
                        op.set_loc, op.set_loc8, op.set_loc0, op.set_loc1, op.set_loc2, op.set_loc3 => {
                            if (localStoreNeedsSlowSync(frame, idx, sync_global_lexical_locals)) break :local_fast;
                            const value = (reg_sp - 1)[0];
                            if (slot_ops.varRefCellFromValue(value) != null) break :local_fast;
                            const assigned = value.dup();
                            reg_ip += operand.consume;
                            reg_var_buf[idx] = assigned;
                            old_v.free(ctx.runtime);
                        },
                        else => unreachable,
                    }
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try vm_property_locals.loc(ctx, function, global, frame, stack, opc, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object);
            },

            // Hot single-byte argument reads inlined into the dispatch (skip
            // vm_property_locals.arg()'s call + re-switch), mirroring qjs's
            // inlined OP_get_arg0..3. get_arg0 is the 2nd hottest opcode in
            // recursive/call-heavy code (fib).
            op.get_arg0, op.get_arg1, op.get_arg2, op.get_arg3 => {
                if (comptime thread_dispatch) get_arg_fast: {
                    // qjs OP_get_arg0..3 (quickjs.c): `*sp++ = JS_DupValue(arg_buf[idx])`.
                    // arg_buf is register-resident; the compiler only emits get_argN
                    // for idx < arg_count and frame.args is padded to arg_count, so
                    // reg_arg_buf[idx] is always in bounds. A captured arg (var-ref
                    // cell) falls through to the slow path's cell-aware deref.
                    const v = reg_arg_buf[opc - op.get_arg0];
                    if (slot_ops.varRefCellFromValue(v) != null) break :get_arg_fast;
                    reg_sp[0] = v.dup();
                    reg_sp += 1;
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try slot_ops.execGetArg(ctx, frame, stack, @as(u16, @intCast(opc - op.get_arg0)), 0, opc);
            },
            op.get_arg, op.put_arg, op.set_arg, op.put_arg0, op.put_arg1, op.put_arg2, op.put_arg3, op.set_arg0, op.set_arg1, op.set_arg2, op.set_arg3 => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try vm_property_locals.arg(ctx, function, frame, stack, opc);
            },

            // qjs OP_get_var_ref(_check) inline (quickjs.c:18627): val=*var_refs[idx]->pvalue;
            // push dup. Uninitialized(TDZ)/deleted/non-cell fall through to the noinline handler.
            op.get_var_ref, op.get_var_ref_check => {
                if (comptime thread_dispatch) get_var_ref_fast: {
                    const idx = std.mem.readInt(u16, reg_ip[0..2], .little);
                    if (idx >= frame.var_refs.len) break :get_var_ref_fast;
                    const cell = slot_ops.varRefCellFromValue(frame.var_refs.ptr[idx]) orelse break :get_var_ref_fast;
                    if (cell.is_deleted) break :get_var_ref_fast;
                    const v = cell.pvalue.*;
                    if (v.isUninitialized()) break :get_var_ref_fast;
                    // Imported module bindings wrap the exporting module's cell
                    // in a const cell (createConstVarRefCell), so a single deref
                    // yields another var_ref cell, not the value. The slow path
                    // chases the chain (slotValueBorrow); route there.
                    if (core.VarRef.fromValue(v) != null) break :get_var_ref_fast;
                    reg_ip += 2;
                    reg_sp[0] = v.dup();
                    reg_sp += 1;
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_locals.varRefVm(ctx, function, global, frame, stack, opc, catch_target, eval_global_var_bindings, is_eval_code, eval_local_names, eval_var_ref_names, eval_with_object)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.get_var_ref0, op.get_var_ref1, op.get_var_ref2, op.get_var_ref3 => {
                if (comptime thread_dispatch) get_var_ref_short_fast: {
                    const idx: u16 = opc - op.get_var_ref0;
                    if (idx >= frame.var_refs.len) break :get_var_ref_short_fast;
                    const cell = slot_ops.varRefCellFromValue(frame.var_refs.ptr[idx]) orelse break :get_var_ref_short_fast;
                    if (cell.is_deleted) break :get_var_ref_short_fast;
                    const v = cell.pvalue.*;
                    if (v.isUninitialized()) break :get_var_ref_short_fast;
                    // See get_var_ref above: an imported binding's cell wraps the
                    // exporting module's cell; route the chained deref to the slow path.
                    if (core.VarRef.fromValue(v) != null) break :get_var_ref_short_fast;
                    reg_sp[0] = v.dup();
                    reg_sp += 1;
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_locals.varRefVm(ctx, function, global, frame, stack, opc, catch_target, eval_global_var_bindings, is_eval_code, eval_local_names, eval_var_ref_names, eval_with_object)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            // qjs OP_put_var_ref(_check) inline (quickjs.c:18638): set_value(var_ref->pvalue, sp[-1]).
            // const / deleted / function-name / (check:)uninitialized fall through to the handler.
            op.put_var_ref, op.put_var_ref_check => {
                if (comptime thread_dispatch) put_var_ref_fast: {
                    const idx = std.mem.readInt(u16, reg_ip[0..2], .little);
                    if (idx >= frame.var_refs.len) break :put_var_ref_fast;
                    const cell = slot_ops.varRefCellFromValue(frame.var_refs.ptr[idx]) orelse break :put_var_ref_fast;
                    if (cell.is_deleted or cell.is_const or cell.is_function_name) break :put_var_ref_fast;
                    // A top-level function declaration stores its closure through
                    // put_var_ref and must also be published as a global object
                    // property (qjs js_closure_define_global_var non-lexical: the
                    // var_ref cell IS a JS_PROP_VARREF on ctx->global_obj, so the
                    // write is seen via globalThis). zjs publishes it separately in
                    // the slow handler (publishTopLevelFunctionVarRef), so defer any
                    // object store to it; primitive stores keep the inline fast path.
                    if ((reg_sp - 1)[0].isObject()) break :put_var_ref_fast;
                    const cur = cell.pvalue.*;
                    if (opc == op.put_var_ref_check and cur.isUninitialized()) break :put_var_ref_fast;
                    // A chained cell (imported binding) must store through the
                    // final cell, not clobber the inner cell pointer; defer to slow.
                    if (core.VarRef.fromValue(cur) != null) break :put_var_ref_fast;
                    reg_ip += 2;
                    reg_sp -= 1;
                    cell.pvalue.* = reg_sp[0];
                    cur.free(ctx.runtime);
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_locals.varRefVm(ctx, function, global, frame, stack, opc, catch_target, eval_global_var_bindings, is_eval_code, eval_local_names, eval_var_ref_names, eval_with_object)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.put_var_ref0, op.put_var_ref1, op.put_var_ref2, op.put_var_ref3 => {
                if (comptime thread_dispatch) put_var_ref_short_fast: {
                    const idx: u16 = opc - op.put_var_ref0;
                    if (idx >= frame.var_refs.len) break :put_var_ref_short_fast;
                    const cell = slot_ops.varRefCellFromValue(frame.var_refs.ptr[idx]) orelse break :put_var_ref_short_fast;
                    if (cell.is_deleted or cell.is_const or cell.is_function_name) break :put_var_ref_short_fast;
                    // Top-level function declarations store their closure here and
                    // must also be published as a global property (see put_var_ref
                    // above). Defer object stores to the slow handler so
                    // publishTopLevelFunctionVarRef runs; primitives stay inline.
                    if ((reg_sp - 1)[0].isObject()) break :put_var_ref_short_fast;
                    const cur = cell.pvalue.*;
                    // A chained cell (imported binding) must store through the
                    // final cell, not clobber the inner cell pointer; defer to slow.
                    if (core.VarRef.fromValue(cur) != null) break :put_var_ref_short_fast;
                    reg_sp -= 1;
                    cell.pvalue.* = reg_sp[0];
                    cur.free(ctx.runtime);
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_locals.varRefVm(ctx, function, global, frame, stack, opc, catch_target, eval_global_var_bindings, is_eval_code, eval_local_names, eval_var_ref_names, eval_with_object)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.put_var_ref_check_init, op.set_var_ref, op.set_var_ref0, op.set_var_ref1, op.set_var_ref2, op.set_var_ref3 => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_locals.varRefVm(ctx, function, global, frame, stack, opc, catch_target, eval_global_var_bindings, is_eval_code, eval_local_names, eval_var_ref_names, eval_with_object)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- TDZ (Temporal Dead Zone) for let/const ----
            // Emitted by resolve_variables for lexical locals:
            //   set_loc_uninitialized: mark slot as in-TDZ (prologue).
            //   get_loc_check/get_loc_checkthis: read; throw ReferenceError if in TDZ.
            //   put_loc_check: write; throw ReferenceError if in TDZ.
            //   set_loc_check: write while preserving the stack value; throw if in TDZ.
            //   put_loc_check_init: write + clear TDZ flag.
            // qjs-aligned inline fast path: a `get_loc_check` on a plain
            // (non-var-ref) initialized slot is a direct `var_buf[idx]` read
            // and push. Refcounted plain values are duplicated in-place; only
            // var-ref / TDZ slots fall through to the full handler.
            op.get_loc_check, op.get_loc_checkthis => {
                if (comptime thread_dispatch) get_loc_check_fast: {
                    if (localFastPathNeedsGeneratorStopBoundary(stop_before_pc)) break :get_loc_check_fast;
                    const idx = std.mem.readInt(u16, reg_ip[0..2], .little);
                    const slot = reg_var_buf[idx];
                    if (slot_ops.varRefCellFromValue(slot) != null) break :get_loc_check_fast;
                    if (slot.isUninitialized()) break :get_loc_check_fast;
                    reg_ip += 2;
                    reg_sp[0] = slot.dup();
                    reg_sp += 1;
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_locals.checkedLocVm(ctx, function, global, frame, stack, opc, catch_target, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object)) {
                    .done => continue,
                    .continue_loop => continue,
                }
            },
            // qjs-aligned inline fast path: `var_buf[idx] = sp[-1]; sp--` for a
            // plain initialized, non-const, non-synced slot. Var-ref / const /
            // TDZ / top-level-global-lexical slots fall through to the full
            // handler.
            op.put_loc_check => {
                if (comptime thread_dispatch) put_loc_check_fast: {
                    if (localFastPathNeedsGeneratorStopBoundary(stop_before_pc)) break :put_loc_check_fast;
                    const idx = std.mem.readInt(u16, reg_ip[0..2], .little);
                    const old_v = reg_var_buf[idx];
                    if (slot_ops.varRefCellFromValue(old_v) != null) break :put_loc_check_fast;
                    if (old_v.isUninitialized()) break :put_loc_check_fast;
                    if (idx < function.var_is_const.len and function.var_is_const[idx]) break :put_loc_check_fast;
                    if (localStoreNeedsSlowSync(frame, idx, sync_global_lexical_locals)) break :put_loc_check_fast;
                    const value = (reg_sp - 1)[0];
                    if (slot_ops.varRefCellFromValue(value) != null) break :put_loc_check_fast;

                    reg_ip += 2;
                    reg_sp -= 1;
                    reg_var_buf[idx] = value;
                    old_v.free(ctx.runtime);
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_locals.checkedLocVm(ctx, function, global, frame, stack, opc, catch_target, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object)) {
                    .done => continue,
                    .continue_loop => continue,
                }
            },
            op.set_loc_check => {
                if (comptime thread_dispatch) set_loc_check_fast: {
                    if (localFastPathNeedsGeneratorStopBoundary(stop_before_pc)) break :set_loc_check_fast;
                    const idx = std.mem.readInt(u16, reg_ip[0..2], .little);
                    const old_v = reg_var_buf[idx];
                    if (slot_ops.varRefCellFromValue(old_v) != null) break :set_loc_check_fast;
                    if (old_v.isUninitialized()) break :set_loc_check_fast;
                    if (localStoreNeedsSlowSync(frame, idx, sync_global_lexical_locals)) break :set_loc_check_fast;
                    const value = (reg_sp - 1)[0];
                    if (slot_ops.varRefCellFromValue(value) != null) break :set_loc_check_fast;
                    const assigned = value.dup();

                    reg_ip += 2;
                    reg_var_buf[idx] = assigned;
                    old_v.free(ctx.runtime);
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_locals.checkedLocVm(ctx, function, global, frame, stack, opc, catch_target, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.put_loc_check_init => {
                if (comptime thread_dispatch) put_loc_check_init_fast: {
                    if (localFastPathNeedsGeneratorStopBoundary(stop_before_pc)) break :put_loc_check_init_fast;
                    const idx = std.mem.readInt(u16, reg_ip[0..2], .little);
                    const old_v = reg_var_buf[idx];
                    if (slot_ops.varRefCellFromValue(old_v) != null) break :put_loc_check_init_fast;
                    if (isDerivedConstructorThisLocal(function, idx)) break :put_loc_check_init_fast;
                    if (localStoreNeedsSlowSync(frame, idx, sync_global_lexical_locals)) break :put_loc_check_init_fast;
                    const value = (reg_sp - 1)[0];
                    if (slot_ops.varRefCellFromValue(value) != null) break :put_loc_check_init_fast;

                    reg_ip += 2;
                    reg_sp -= 1;
                    reg_var_buf[idx] = value;
                    old_v.free(ctx.runtime);
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_locals.checkedLocVm(ctx, function, global, frame, stack, opc, catch_target, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.set_loc_uninitialized => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_locals.checkedLocVm(ctx, function, global, frame, stack, opc, catch_target, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.push_atom_value => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.pushAtomValue(ctx, stack, function, frame);
            },
            op.push_empty_string => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.pushEmptyString(ctx, stack);
            },
            op.to_propkey => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_field.toPropKeyVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.set_name, op.set_name_computed => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try vm_property_field.setName(ctx, output, global, stack, function, frame, opc);
            },

            // ---- Stack manipulation ----
            op.drop => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try value_vm.drop(ctx.runtime, stack)) {
                    .value => {},
                    .catch_target => |target| {
                        catch_target.* = target;
                        continue;
                    },
                }
            },
            op.nip_catch => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.nipCatch(ctx.runtime, stack);
            },
            op.dup => {
                if (comptime thread_dispatch) {
                    // OP_dup: push an OWNED copy of the top — byte-identical to
                    // value_vm.dup (pushAssumeCapacity(peekBorrowed)), where
                    // pushAssumeCapacity RETAINS refcounted values
                    // (`if (v.requiresRefCount()) v.dup() else v`). Missing this
                    // retain under-refs the object -> premature free.
                    const v = (reg_sp - 1)[0];
                    reg_sp[0] = if (v.requiresRefCount()) v.dup() else v;
                    reg_sp += 1;
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.dup(ctx, stack, opc);
            },
            op.swap => {
                if (comptime thread_dispatch) {
                    const tmp = (reg_sp - 2)[0];
                    (reg_sp - 2)[0] = (reg_sp - 1)[0];
                    (reg_sp - 1)[0] = tmp;
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.swap(ctx, stack);
            },

            // ---- Return ----
            op.@"return" => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                if (machine.depth == 0) return control_vm.returnTop(ctx, stack, frame, generator_state);
                try machine.popReturn(try control_vm.returnTop(ctx, stack, frame, null));
                // Threaded resume into the caller (still inline): reload + dispatch
                // its next opcode, skipping the cold prologue. qjs resumes the caller
                // inline after JS_CallInternal returns (no per-return interrupt poll).
                if (machine.depth > 0 and inline_invariants_set) {
                    opc = reloadInlineTopFrame(machine, &function, &stack, &frame, &catch_target, &eval_var_ref_names, &eval_var_refs, &strict_unresolved_get_var, &reg_ip, &reg_code_end, &reg_base, &reg_sp, &reg_var_buf, &reg_arg_buf);
                    continue :sw opc;
                }
                continue;
            },
            op.return_undef => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                if (machine.depth == 0) return control_vm.returnUndefined(ctx, frame, generator_state);
                try machine.popReturn(try control_vm.returnUndefined(ctx, frame, null));
                if (machine.depth > 0 and inline_invariants_set) {
                    opc = reloadInlineTopFrame(machine, &function, &stack, &frame, &catch_target, &eval_var_ref_names, &eval_var_refs, &strict_unresolved_get_var, &reg_ip, &reg_code_end, &reg_base, &reg_sp, &reg_var_buf, &reg_arg_buf);
                    continue :sw opc;
                }
                continue;
            },
            op.return_async => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                if (machine.depth == 0) return control_vm.returnTop(ctx, stack, frame, generator_state);
                try machine.popReturn(try control_vm.returnTop(ctx, stack, frame, null));
                if (machine.depth > 0 and inline_invariants_set) {
                    opc = reloadInlineTopFrame(machine, &function, &stack, &frame, &catch_target, &eval_var_ref_names, &eval_var_refs, &strict_unresolved_get_var, &reg_ip, &reg_code_end, &reg_base, &reg_sp, &reg_var_buf, &reg_arg_buf);
                    continue :sw opc;
                }
                continue;
            },

            // ---- Binary arithmetic ----
            op.add, op.sub, op.mul, op.div, op.mod, op.pow, op.shl, op.sar, op.shr, op.@"and", op.@"or", op.xor => {
                if (comptime thread_dispatch) bin_int_fast: {
                    // Register-resident int32 fast path operating directly on
                    // reg_sp (mirrors the lean op.lt arm), avoiding the sp_len
                    // round-trip (ptr-diff divide + by-pointer helper + reg_sp
                    // recompute) the prior window-helper path paid.
                    if (opc == op.pow) break :bin_int_fast;
                    const a = (reg_sp - 2)[0].asInt32() orelse break :bin_int_fast;
                    const b = (reg_sp - 1)[0].asInt32() orelse break :bin_int_fast;
                    const result = dispatchFastBinaryInt32(opc, a, b) orelse break :bin_int_fast;
                    (reg_sp - 2)[0] = result;
                    reg_sp -= 1;
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                if (comptime thread_dispatch) bin_float_fast: {
                    // Inline float64 fast path mirroring qjs's OP_add/sub/mul
                    // `JS_TAG_IS_FLOAT64` branch (quickjs.c:19710-19728): for two
                    // number operands where the int32 path above did not apply
                    // (≥1 float64, or an int32 add/sub/mul that overflowed), compute
                    // in f64 and canonicalize EXACTLY like value_ops.binaryNumber
                    // (numberToValue), avoiding the binaryVm→toPrimitive→binary
                    // call cascade + pop/defer-free traffic. Only the float-math
                    // ops qualify: bitwise/shift need ToInt32 (not float math) and
                    // pow has no fast path; `add` with a string operand is excluded
                    // because asNumber() is null for strings (→ slow stringAdd).
                    switch (opc) {
                        op.add, op.sub, op.mul, op.div, op.mod => {},
                        else => break :bin_float_fast,
                    }
                    const fa = (reg_sp - 2)[0].asNumber() orelse break :bin_float_fast;
                    const fb = (reg_sp - 1)[0].asNumber() orelse break :bin_float_fast;
                    const fout = switch (opc) {
                        op.add => fa + fb,
                        op.sub => fa - fb,
                        op.mul => fa * fb,
                        op.div => fa / fb,
                        op.mod => @rem(fa, fb),
                        else => unreachable,
                    };
                    (reg_sp - 2)[0] = value_ops_mod.numberToValue(fout);
                    reg_sp -= 1;
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                // Inline int32 fast path: replaces binaryVm->binary call frames
                // and pop/defer-free traffic for the common two-int operand case.
                // Semantically identical to binary()'s int32 branch. pow is
                // excluded (no int fast path there).
                if (comptime !thread_dispatch) {
                    if (opc != op.pow and arith_vm.tryInt32Binary(stack, opc)) {
                        continue;
                    }
                }
                switch (try arith_vm.binaryVm(ctx, stack, frame, catch_target, opc, output, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Comparisons ----
            // `op.lt` gets a dedicated arm: it's the hottest comparison (loop
            // conditions) and a dedicated dispatch-table entry hardcodes `a < b`,
            // dropping the runtime opcode-family selection qjs avoids by having
            // one handler per comparison opcode.
            op.lt => {
                if (comptime thread_dispatch) lt_fast: {
                    const a = (reg_sp - 2)[0].asInt32() orelse break :lt_fast;
                    const b = (reg_sp - 1)[0].asInt32() orelse break :lt_fast;
                    (reg_sp - 2)[0] = core.JSValue.boolean(a < b);
                    reg_sp -= 1;
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try arith_vm.compareVm(ctx, stack, frame, catch_target, opc, output, global)) {
                    .done => continue,
                    .continue_loop => continue,
                }
            },
            op.lte, op.gt, op.gte, op.eq, op.neq, op.strict_eq, op.strict_neq => {
                if (comptime thread_dispatch) lt_fast: {
                    // Register-resident int32 compare: `sp[-2] = (sp[-2] ? sp[-1]); sp--`.

                    const a = (reg_sp - 2)[0].asInt32() orelse break :lt_fast;
                    const b = (reg_sp - 1)[0].asInt32() orelse break :lt_fast;
                    const r = switch (opc) {
                        op.lte => a <= b,
                        op.gt => a > b,
                        op.gte => a >= b,
                        op.eq, op.strict_eq => a == b,
                        op.neq, op.strict_neq => a != b,
                        else => return error.InvalidBytecode,
                    };
                    (reg_sp - 2)[0] = core.JSValue.boolean(r);
                    reg_sp -= 1;
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try arith_vm.compareVm(ctx, stack, frame, catch_target, opc, output, global)) {
                    .done => continue,
                    .continue_loop => continue,
                }
            },
            op.in, op.instanceof => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_field.inOrInstanceof(ctx, output, global, stack, function, frame, catch_target, opc)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.private_in => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try class_vm.privateInVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Unary ----
            op.neg, op.plus => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try arith_vm.unaryVm(ctx, stack, frame, catch_target, opc, output, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.not => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try arith_vm.bitNotVm(ctx, stack, frame, catch_target, output, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.lnot => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.logicalNot(ctx.runtime, stack);
            },
            // inc/dec stay grouped: the 2-way `opc == op.inc` discrimination is
            // a single compare, cheaper than the code-duplication a split costs
            // (measured: splitting these *added* ~3 insn/iter).
            op.inc, op.dec => {
                if (comptime thread_dispatch) inc_fast: {
                    // Register-resident int32 fast path: `sp[-1] ±= 1` in place.

                    const iv = (reg_sp - 1)[0].asInt32() orelse break :inc_fast;
                    const res = if (opc == op.inc) @addWithOverflow(iv, 1) else @subWithOverflow(iv, 1);
                    if (res[1] != 0) break :inc_fast;
                    (reg_sp - 1)[0] = core.JSValue.int32(res[0]);
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try arith_vm.unaryVm(ctx, stack, frame, catch_target, opc, output, global)) {
                    .done => continue,
                    .continue_loop => continue,
                }
            },

            // ---- Control flow ----
            op.goto => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                control_vm.jump32(function, frame);
            },
            op.goto16 => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                control_vm.jump16(function, frame);
            },
            op.goto8 => {
                if (comptime thread_dispatch) {
                    // Threaded path keeps registers live across the jump (like
                    // if_false8) — no unconditional syncDown; the bare poll only
                    // matters when an interrupt handler is installed.
                    const operand_pc = @intFromPtr(reg_ip) - @intFromPtr(function.code.ptr);
                    const diff: i8 = @bitCast(reg_ip[0]);
                    reg_ip = function.code.ptr + @as(usize, @intCast(@as(i64, @intCast(operand_pc)) + @as(i64, diff)));
                    if (diff < 0) {
                        // Backward jump (loop): target precedes the operand and
                        // can never reach code-end — no fall-off check needed.
                        // A poll that throws re-enters the canonical exception /
                        // try-catch path, which reads frame.pc and trims
                        // stack.values — so publish them first. Gated on an
                        // installed interrupt handler: with none, poll can't throw
                        // and the loop stays fully register-resident.
                        if (interrupt_poller.active) {
                            @branchHint(.unlikely);
                            syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                            try interrupt_poller.poll(ctx.runtime);
                        }
                    } else if (@intFromPtr(reg_ip) >= @intFromPtr(reg_code_end)) {
                        // Forward `goto`-to-end (eval / if-else completion leaves
                        // code that jumps just past the last instruction): route
                        // to the canonical fall-off completion path.
                        syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                        continue;
                    }
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                control_vm.jump8(function, frame);
            },
            op.if_false => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try control_vm.branch32(ctx, stack, function, frame, false);
            },
            op.if_true => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try control_vm.branch32(ctx, stack, function, frame, true);
            },
            op.if_false8 => {
                if (comptime thread_dispatch) {
                    const operand_pc = @intFromPtr(reg_ip) - @intFromPtr(function.code.ptr);
                    const diff: i8 = @bitCast(reg_ip[0]);
                    reg_ip += 1;
                    reg_sp -= 1;
                    const value = reg_sp[0];
                    const truthy = value.asBool() orelse value_ops_mod.isTruthy(value);
                    value.free(ctx.runtime);
                    if (!truthy) {
                        reg_ip = function.code.ptr + @as(usize, @intCast(@as(i64, @intCast(operand_pc)) + @as(i64, diff)));
                        if (diff < 0) {
                            // Backward branch: target precedes operand, never code-end.
                            // Sync canonical state before a fallible poll so an
                            // interrupt's catch/unwind sees live pc+stack (see
                            // goto8); gated on an installed handler.
                            if (interrupt_poller.active) {
                                @branchHint(.unlikely);
                                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                                try interrupt_poller.poll(ctx.runtime);
                            }
                        } else if (@intFromPtr(reg_ip) >= @intFromPtr(reg_code_end)) {
                            // Forward branch-to-end: canonical fall-off completion.
                            syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                            continue;
                        }
                    }
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                try control_vm.branch8(ctx, stack, function, frame, false);
            },
            op.if_true8 => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try control_vm.branch8(ctx, stack, function, frame, true);
            },
            op.gosub => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try control_vm.gosub(function, frame, stack);
            },
            op.ret => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try control_vm.ret(ctx, function, frame, stack);
            },

            // ---- Variable access ----
            op.get_var, op.get_var_undef => {
                if (comptime thread_dispatch) get_var_fast: {
                    if (localFastPathNeedsGeneratorStopBoundary(stop_before_pc)) break :get_var_fast;
                    if (vm_property_globals.hasDynamicGlobalOverlay(frame, eval_local_names, eval_var_ref_names, eval_with_object)) break :get_var_fast;
                    const idx = std.mem.readInt(u16, reg_ip[0..2], .little);
                    if (idx >= frame.var_refs.len) break :get_var_fast;
                    const cell = slot_ops.varRefCellFromValue(frame.var_refs.ptr[idx]) orelse break :get_var_fast;
                    if (cell.is_deleted) break :get_var_fast;
                    const v = cell.pvalue.*;
                    if (v.isUninitialized()) break :get_var_fast;
                    if (core.VarRef.fromValue(v) != null) break :get_var_fast;
                    if (vm_property_globals.globalLexicalShadowsGlobalForIdx(ctx, global, function, idx)) break :get_var_fast;
                    if (vm_property_globals.parentEvalShadowsGlobalForIdx(ctx.runtime, frame, function, idx)) break :get_var_fast;
                    reg_ip += 2;
                    reg_sp[0] = v.dup();
                    reg_sp += 1;
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_globals.getVar(ctx, output, global, stack, function, frame, catch_target, opc, sync_global_lexical_locals, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, eval_with_object)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.make_loc_ref, op.make_arg_ref, op.make_var_ref_ref => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try vm_property_ref.makeSlotRef(ctx, stack, function, frame, opc);
            },
            op.make_var_ref => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_ref.makeVarRefVm(ctx, output, global, stack, function, frame, catch_target, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.get_ref_value => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_ref.getRefValueVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.put_ref_value => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_ref.putRefValueVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.put_var => {
                if (comptime thread_dispatch) put_var_fast: {
                    if (localFastPathNeedsGeneratorStopBoundary(stop_before_pc)) break :put_var_fast;
                    if (vm_property_globals.hasDynamicGlobalOverlay(frame, eval_local_names, eval_var_ref_names, eval_with_object)) break :put_var_fast;
                    const idx = std.mem.readInt(u16, reg_ip[0..2], .little);
                    if (idx >= frame.var_refs.len) break :put_var_fast;
                    const cell = slot_ops.varRefCellFromValue(frame.var_refs.ptr[idx]) orelse break :put_var_fast;
                    if (cell.is_deleted or cell.is_const or cell.is_function_name) break :put_var_fast;
                    const cur = cell.pvalue.*;
                    if (cur.isUninitialized()) break :put_var_fast;
                    if (core.VarRef.fromValue(cur) != null) break :put_var_fast;
                    if (vm_property_globals.globalLexicalShadowsGlobalForIdx(ctx, global, function, idx)) break :put_var_fast;
                    if (vm_property_globals.parentEvalShadowsGlobalForIdx(ctx.runtime, frame, function, idx)) break :put_var_fast;
                    reg_ip += 2;
                    reg_sp -= 1;
                    cell.pvalue.* = reg_sp[0];
                    cur.free(ctx.runtime);
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_globals.putVar(ctx, output, global, stack, function, frame, catch_target, strict_unresolved_get_var, eval_global_var_bindings, is_eval_code, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, eval_with_object)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.with_get_var, op.with_delete_var, op.with_make_ref, op.with_get_ref => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_ref.withGetOrDelete(ctx, output, global, stack, function, frame, catch_target, opc)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.with_put_var => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_ref.withPut(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.to_object => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try value_vm.toObjectVm(ctx, stack, frame, catch_target, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Object properties ----
            op.get_field, op.get_field2 => {
                if (comptime thread_dispatch) get_field_ic_fast: {
                    if (reg_sp == reg_base) break :get_field_ic_fast;
                    const operand_pc = (@intFromPtr(reg_ip) - @intFromPtr(function.code.ptr));
                    if (operand_pc == 0) break :get_field_ic_fast;
                    const site_pc = operand_pc - 1;
                    const atom_id = std.mem.readInt(u32, reg_ip[0..4], .little);
                    const receiver = (reg_sp - 1)[0];
                    const value = dispatchFieldOwnDataIcValue(function, site_pc, receiver, atom_id) orelse break :get_field_ic_fast;
                    reg_ip += 4;
                    if (opc == op.get_field) {
                        (reg_sp - 1)[0] = value.dup();
                        receiver.free(ctx.runtime);
                    } else {
                        reg_sp[0] = value.dup();
                        reg_sp += 1;
                    }
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_field.field(ctx, output, global, stack, function, frame, catch_target, opc, sync_global_lexical_locals)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.put_field => {
                if (comptime thread_dispatch) put_field_ic_fast: {
                    if (@intFromPtr(reg_sp) - @intFromPtr(reg_base) < 2 * @sizeOf(core.JSValue)) break :put_field_ic_fast;
                    const operand_pc = (@intFromPtr(reg_ip) - @intFromPtr(function.code.ptr));
                    if (operand_pc == 0) break :put_field_ic_fast;
                    const site_pc = operand_pc - 1;
                    const atom_id = std.mem.readInt(u32, reg_ip[0..4], .little);
                    const receiver = (reg_sp - 2)[0];
                    const value = (reg_sp - 1)[0];
                    if (!dispatchFieldOwnDataIcStoreOwned(ctx.runtime, function, site_pc, receiver, atom_id, value)) break :put_field_ic_fast;
                    reg_ip += 4;
                    reg_sp -= 2;
                    receiver.free(ctx.runtime);
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_field.field(ctx, output, global, stack, function, frame, catch_target, opc, sync_global_lexical_locals)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.get_private_field => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_private.getPrivateFieldVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.put_private_field => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_private.putPrivateFieldVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.define_private_field => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_private.definePrivateFieldVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Array elements ----
            op.get_array_el, op.get_array_el2, op.get_array_el3, op.put_array_el => {
                if (comptime thread_dispatch) array_el_fast: {
                    // qjs OP_get_array_el / OP_put_array_el dense fast paths.
                    // el2/el3 (different stack shapes) stay on the slow arm.
                    if (opc == op.get_array_el) {
                        // n_pop=2,n_push=1. Byte-identical to the arrayElement
                        // dense leg: pop key+obj (free both), pushOwned the dup'd
                        // element. fastDenseArrayElementValue gates on object +
                        // non-negative int key + fast-array-in-bounds.
                        const obj = (reg_sp - 2)[0];
                        const key = (reg_sp - 1)[0];
                        const val = vm_property_field.fastDenseArrayElementValue(obj, key) orelse break :array_el_fast;
                        key.free(ctx.runtime);
                        obj.free(ctx.runtime);
                        (reg_sp - 2)[0] = val;
                        reg_sp -= 1;
                        opc = reg_ip[0];
                        reg_ip += 1;
                        continue :sw opc;
                    } else if (opc == op.put_array_el) {
                        // n_pop=3,n_push=0. In-bounds dense store only (the
                        // non-erroring setFastArrayElementDup leg of the slow
                        // path's putDenseArrayElementFast); out-of-bounds /
                        // append / grow / typed-array / proxy break to slow.
                        // Matches the slow path: it dups the value into the slot,
                        // frees the old element, and the caller frees obj/key/val.
                        const value = (reg_sp - 1)[0];
                        const key = (reg_sp - 2)[0];
                        const idx_i32 = key.asInt32() orelse break :array_el_fast;
                        if (idx_i32 < 0) break :array_el_fast;
                        const obj = (reg_sp - 3)[0];
                        const object = class_vm.objectFromValue(obj) orelse break :array_el_fast;
                        if (!object.setFastArrayElementDup(ctx.runtime, @intCast(idx_i32), value)) break :array_el_fast;
                        value.free(ctx.runtime);
                        key.free(ctx.runtime);
                        obj.free(ctx.runtime);
                        reg_sp -= 3;
                        opc = reg_ip[0];
                        reg_ip += 1;
                        continue :sw opc;
                    }
                    break :array_el_fast;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_field.arrayElement(ctx, output, global, stack, function, frame, catch_target, opc)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Super ----
            op.get_super => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try class_vm.getSuper(ctx, stack, frame);
            },
            op.get_super_value => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try class_vm.getSuperValue(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.put_super_value => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try class_vm.putSuperValue(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Calls ----
            op.call, op.call0, op.call1, op.call2, op.call3 => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try call_vm.call(ctx, output, global, stack, function, frame, catch_target, opc)) {
                    .done => {},
                    .continue_loop => continue,
                    .inline_call => |request| {
                        machine.pushCall(global, stack, request.target, request.region_base, request.argc, request.layout) catch |err| {
                            try closeStackTopForOfIteratorForPendingError(ctx, output, global, stack);
                            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) continue;
                            return err;
                        };
                        // Threaded resume into the callee while already deep in the
                        // inline regime (invariants established): reload + dispatch
                        // straight into the callee's first opcode, skipping the cold
                        // prologue. The first push from L0 (invariants not yet set)
                        // falls through to `continue` so the prologue establishes them.
                        if (inline_invariants_set) {
                            try interrupt_poller.poll(ctx.runtime); // qjs polls at call entry
                            opc = reloadInlineTopFrame(machine, &function, &stack, &frame, &catch_target, &eval_var_ref_names, &eval_var_refs, &strict_unresolved_get_var, &reg_ip, &reg_code_end, &reg_base, &reg_sp, &reg_var_buf, &reg_arg_buf);
                            continue :sw opc;
                        }
                        continue;
                    },
                }
            },
            op.tail_call => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try call_vm.tailCall(ctx, output, global, stack, function, frame, catch_target, machine.depth > 0)) {
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
                }
            },
            op.eval => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try eval_module_vm.directEval(ctx, stack, function, frame, catch_target, output, global, eval_class_field_initializer_flag, eval_parameter_initializer_flag, machine.depth > 0)) {
                    .done => {},
                    .continue_loop => continue,
                    // Non-%eval% callee in tail position: proper tail call via
                    // frame reuse, mirroring the op.tail_call leg.
                    .tail_inline => |request| {
                        try machine.tailCallReuse(global, stack, request.target, request.region_base, request.argc, request.layout);
                        continue;
                    },
                }
            },
            op.apply_eval => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try eval_module_vm.applyEval(ctx, stack, function, frame, catch_target, output, global, eval_class_field_initializer_flag, eval_parameter_initializer_flag)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.import => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try eval_module_vm.dynamicImport(ctx, output, global, stack, function, frame);
            },
            op.call_method => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try call_vm.callMethod(ctx, output, global, stack, function, frame, catch_target, true)) {
                    .done => {},
                    .continue_loop => continue,
                    // Method call to a plain bytecode function: run it as an inline
                    // frame (receiver becomes `this`), mirroring the op.call leg.
                    .inline_call => |request| {
                        machine.pushCall(global, stack, request.target, request.region_base, request.argc, request.layout) catch |err| {
                            try closeStackTopForOfIteratorForPendingError(ctx, output, global, stack);
                            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) continue;
                            return err;
                        };
                        // Threaded resume into the callee while already deep in the
                        // inline regime (invariants established): reload + dispatch
                        // straight into the callee's first opcode, skipping the cold
                        // prologue. The first push from L0 (invariants not yet set)
                        // falls through to `continue` so the prologue establishes them.
                        if (inline_invariants_set) {
                            try interrupt_poller.poll(ctx.runtime); // qjs polls at call entry
                            opc = reloadInlineTopFrame(machine, &function, &stack, &frame, &catch_target, &eval_var_ref_names, &eval_var_refs, &strict_unresolved_get_var, &reg_ip, &reg_code_end, &reg_base, &reg_sp, &reg_var_buf, &reg_arg_buf);
                            continue :sw opc;
                        }
                        continue;
                    },
                }
            },
            op.tail_call_method => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try call_vm.tailCallMethod(ctx, output, global, stack, function, frame, catch_target, machine.depth > 0)) {
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
                }
            },

            // ---- Object/array literals ----
            op.object => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try literal_vm.object(ctx, stack, global);
            },
            op.array_from => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try literal_vm.arrayFrom(ctx, stack, function, frame, global);
            },
            op.define_field => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try literal_vm.defineField(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.set_proto => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try literal_vm.setProto(ctx, stack);
            },
            op.set_home_object => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try class_vm.setHomeObject(ctx, stack);
            },
            op.define_class, op.define_class_computed => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try class_vm.defineClass(ctx, output, global, stack, function, frame, catch_target, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, opc == op.define_class_computed)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.define_array_el => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try literal_vm.defineArrayEl(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.define_method => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try class_vm.defineMethod(ctx, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.define_method_computed => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try class_vm.defineMethodComputed(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.append => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try literal_vm.appendSpreadValuesVm(ctx, output, global, stack, opc, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.copy_data_properties => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                const mask = function.code[frame.pc];
                frame.pc += 1;
                switch (try literal_vm.copyDataProperties(ctx, output, global, stack, mask, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Generators (F9) ----
            op.initial_yield => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try gen_async_vm.initialYield(ctx, stack, frame, generator_state, stop_on_yield)) {
                    .none => {},
                    .continue_loop => continue,
                    .return_value => |value| return value,
                }
            },
            op.yield => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try gen_async_vm.yieldValue(ctx, stack, frame, generator_state, stop_on_yield)) {
                    .none => {},
                    .continue_loop => continue,
                    .return_value => |value| return value,
                }
            },
            op.yield_star, op.async_yield_star => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                const yield_star_result = try gen_async_vm.yieldStar(ctx, output, global, stack, function, frame, generator_state, stop_on_yield, catch_target);
                switch (yield_star_result) {
                    .none => {},
                    .continue_loop => continue,
                    .return_value => |value| return value,
                }
            },
            op.await => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                const await_result = try gen_async_vm.awaitValue(ctx, output, global, stack, function, frame, generator_state, suspend_on_module_await, stop_on_yield, catch_target);
                switch (await_result) {
                    .none => {},
                    .continue_loop => continue,
                    .return_value => |value| return value,
                }
            },

            // ---- Global variable operations ----
            op.put_var_init => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_globals.globalDefinition(ctx, global, stack, function, frame, catch_target, opc)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Special object (prologue) ----
            op.special_object => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try literal_vm.specialObject(ctx, stack, function, frame, global, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs);
            },

            // ---- Typeof ----
            op.typeof => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.typeOf(ctx, stack);
            },
            op.typeof_is_undefined => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.typeOfIsUndefined(ctx.runtime, stack);
            },
            op.typeof_is_function => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.typeOfIsFunction(ctx.runtime, stack);
            },

            // ---- Throw ----
            op.throw => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try control_vm.throwTop(ctx, output, global, stack, frame, catch_target)) {
                    .handled => continue,
                }
            },
            op.throw_error => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try control_vm.throwErrorVm(ctx, stack, function, frame, catch_target, global)) {
                    .handled => continue,
                }
            },
            op.@"catch" => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try control_vm.catchTarget(function, frame, stack, catch_target);
            },
            op.check_ctor => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try call_vm.checkCtorVm(ctx, stack, frame, catch_target, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.check_ctor_return => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try call_vm.checkCtorReturnVm(ctx, stack, frame, catch_target, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.init_ctor => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try call_vm.initCtorVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.check_brand => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try class_vm.checkBrandVm(ctx, stack, frame, catch_target, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.add_brand => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try class_vm.addBrandVm(ctx, stack, frame, catch_target, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.close_loc => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try vm_property_locals.closeLoc(ctx, function, frame);
            },

            // ---- NOP ----
            op.nop => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                control_vm.nop();
            },

            // ---- Push this ----
            op.push_this => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try value_vm.pushThisVm(ctx, stack, frame, catch_target, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Delete ----
            op.delete_var => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try vm_property_ref.deleteVar(ctx, global, stack, function, frame, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs);
            },
            op.delete => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try vm_property_ref.deletePropertyVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Additional stack manipulation ----
            op.nip => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.nip(ctx, stack);
            },
            op.nip1 => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.nip1(ctx, stack);
            },
            op.dup1 => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.dup1(ctx, stack);
            },
            op.dup2 => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.dup2(ctx, stack);
            },
            op.dup3 => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.dup3(ctx, stack);
            },
            op.insert2 => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.insert2(ctx, stack);
            },
            op.insert3 => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.insert3(ctx, stack);
            },
            op.insert4 => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.insert4(ctx, stack);
            },
            op.rot3l => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.rot3l(ctx, stack);
            },
            op.rot3r => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.rot3r(ctx, stack);
            },
            op.rot4l => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.rot4l(ctx, stack);
            },
            op.rot5l => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.rot5l(ctx, stack);
            },
            op.perm3 => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.perm3(ctx, stack);
            },
            op.perm4 => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.perm4(ctx, stack);
            },
            op.perm5 => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.perm5(ctx, stack);
            },
            op.swap2 => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.swap2(ctx, stack);
            },
            op.is_undefined_or_null => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.isUndefinedOrNull(ctx.runtime, stack);
            },
            op.is_undefined => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.isUndefined(ctx.runtime, stack);
            },
            op.is_null => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try value_vm.isNull(ctx.runtime, stack);
            },
            op.get_length => {
                if (comptime thread_dispatch) get_length_fast: {
                    // qjs OP_get_field is_length inline: a plain Array's .length
                    // is an exotic own data property (never a getter), so read
                    // arrayLength() directly instead of getValueProperty. Strings
                    // / typed-arrays / proxies / generic objects / length getters
                    // break to the slow getLength. Matches it: pop receiver
                    // (free), pushOwned the length (a fresh number, no refcount).
                    const value = (reg_sp - 1)[0];
                    const object = class_vm.objectFromValue(value) orelse break :get_length_fast;
                    if (!object.flags.is_array) break :get_length_fast;
                    const len = object.arrayLength();
                    const len_val = if (len <= @as(u32, std.math.maxInt(i32)))
                        core.JSValue.int32(@intCast(len))
                    else
                        value_ops_mod.numberToValue(@as(f64, @floatFromInt(len)));
                    value.free(ctx.runtime);
                    (reg_sp - 1)[0] = len_val;
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try literal_vm.getLength(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.post_inc, op.post_dec => {
                if (comptime thread_dispatch) post_update_fast: {
                    const old_v = (reg_sp - 1)[0];
                    const int_value = old_v.asInt32() orelse break :post_update_fast;
                    reg_sp[0] = dispatchFastUpdateInt32(opc, int_value);
                    reg_sp += 1;
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try arith_vm.postUpdateVm(ctx, stack, frame, catch_target, opc, output, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.inc_loc, op.dec_loc => {
                if (comptime thread_dispatch) update_local_fast: {
                    if (localFastPathNeedsGeneratorStopBoundary(stop_before_pc)) break :update_local_fast;
                    const idx: u16 = reg_ip[0];
                    if (idx >= frame.locals.len) break :update_local_fast;
                    if (localStoreNeedsSlowSync(frame, idx, sync_global_lexical_locals)) break :update_local_fast;
                    const old_v = reg_var_buf[idx];
                    if (slot_ops.varRefCellFromValue(old_v) != null) break :update_local_fast;
                    const int_value = old_v.asInt32() orelse break :update_local_fast;
                    reg_ip += 1;
                    reg_var_buf[idx] = dispatchFastUpdateInt32(opc, int_value);
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try arith_vm.updateLocalVm(ctx, stack, function, global, frame, catch_target, opc, output, sync_global_lexical_locals)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.add_loc => {
                if (comptime thread_dispatch) add_local_fast: {
                    // qjs OP_add_loc: local[idx] += sp[-1]; sp--. Threaded int32
                    // fast path mirrors inc_loc (same local-store guards) plus the
                    // rhs pop; fastInt32Add folds overflow to a double, so no extra
                    // break needed. Both operands int32 here (no refcount).
                    if (localFastPathNeedsGeneratorStopBoundary(stop_before_pc)) break :add_local_fast;
                    const idx: u16 = reg_ip[0];
                    if (idx >= frame.locals.len) break :add_local_fast;
                    if (localStoreNeedsSlowSync(frame, idx, sync_global_lexical_locals)) break :add_local_fast;
                    const old_v = reg_var_buf[idx];
                    if (slot_ops.varRefCellFromValue(old_v) != null) break :add_local_fast;
                    const lhs = old_v.asInt32() orelse break :add_local_fast;
                    const rhs = (reg_sp - 1)[0].asInt32() orelse break :add_local_fast;
                    reg_ip += 1;
                    reg_sp -= 1;
                    reg_var_buf[idx] = arith_vm.fastInt32Add(lhs, rhs);
                    opc = reg_ip[0];
                    reg_ip += 1;
                    continue :sw opc;
                }
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try arith_vm.addLocalVm(ctx, stack, function, global, frame, catch_target, output, sync_global_lexical_locals)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.apply => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try call_vm.apply(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Rest / spread ----
            op.rest => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try literal_vm.rest(ctx, stack, function, frame);
            },

            // ---- Iterator protocol ----
            op.for_of_start, op.for_await_of_start => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try iter_vm.forOfStartVm(ctx, output, global, stack, function, frame, catch_target, opc == op.for_await_of_start)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.for_in_start => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try iter_vm.forInStartVm(ctx, output, global, stack, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.iterator_next => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try iter_vm.iteratorNextVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.iterator_check_object => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try iter_vm.iteratorCheckObjectVm(ctx, stack, frame, catch_target, global)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.iterator_get_value_done => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try iter_vm.iteratorGetValueDoneVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.iterator_call => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try iter_vm.iteratorCallVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.for_of_next => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try iter_vm.forOfNextVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.for_await_of_next => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try iter_vm.forAwaitOfNextVm(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.for_in_next => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                try iter_vm.forInNext(ctx, output, global, stack);
            },
            op.iterator_close => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try iter_vm.iteratorCloseVm(ctx, output, global, stack, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Constructor ----
            op.call_constructor => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                switch (try call_vm.constructor(ctx, output, global, stack, function, frame, catch_target)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            op.invalid => {
                syncDown(function, frame, stack, reg_ip, reg_base, reg_sp);
                return error.InvalidBytecode;
            },

            // Dense 256-entry dispatch table (qjs-aligned: `[OP_COUNT..255] =
            // &&case_default`). Opcodes 0..243 are all defined; 244..255 are
            // currently gaps. Listing them explicitly (instead of `else`) makes the
            // switch exhaustive over u8, so the compiler emits a single dense
            // jump table with no opcode range check, while still routing invalid
            // bytecode to error (the contract `src/tests/builtins.zig` asserts).
            244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 254, 255 => return error.InvalidBytecode,
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
