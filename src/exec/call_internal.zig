//! Recursive, register-resident bytecode dispatcher — the radical rewrite core.
//! See `scratch/perf/ARCH-RECURSIVE-REWRITE.md`. comptime-gated behind
//! `build_options.zjs_recursive_dispatch` (default OFF); built up incrementally.
//! `pc` is a C-local mirror of frame.pc (LLVM register-allocates it); hot
//! operand-decoders inline on it, every other opcode syncs frame.pc and
//! delegates to the same handler dispatchLoop uses (drop the sync to migrate).
//! WIP: call_method/call_prepared/eval @panic on inline_call/tail_inline (need
//! native-recursion integration); no per-opcode interrupt poll yet.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");
const exception_ops = @import("vm_exception_ops.zig");
const HostError = @import("exceptions.zig").HostError;

const value_vm = @import("vm_value.zig");
const inline_calls = @import("inline_calls.zig");
const array_ops = @import("array_ops.zig");
const forof_ops = @import("forof_ops.zig");
const call_vm = @import("vm_call.zig");
const regexp_vm = @import("vm_regexp.zig");
const class_vm = @import("object_ops.zig");
const arith_vm = @import("vm_arith.zig");
const control_vm = @import("vm_control.zig");
const call_runtime = @import("call_runtime.zig");
const eval_module_vm = @import("vm_eval_module.zig");
const value_ops = @import("value_ops.zig");
const vm_property_locals = @import("vm_property_locals.zig");
const vm_property_ref = @import("vm_property_ref.zig");
const vm_property_globals = @import("vm_property_globals.zig");
const vm_property_field = @import("vm_property_field.zig");
const vm_property_private = @import("vm_property_private.zig");
const literal_vm = @import("vm_literal.zig");
const iter_vm = @import("iterator_ops.zig");
const slot_ops = @import("slot_ops.zig");

const op = bytecode.opcode.op;
pub const recursive_dispatch_enabled = build_options.zjs_recursive_dispatch;

const eval_class_field_initializer_flag: u16 = 0x8000;
const eval_parameter_initializer_flag: u16 = 0x4000;

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn relativePc(operand_pc: usize, diff: i32) usize {
    return @intCast(@as(i64, @intCast(operand_pc)) + @as(i64, diff));
}

inline fn plainLocalSlotFastPath(
    function: *const bytecode.Bytecode,
    idx: usize,
    old_value: core.JSValue,
    value: core.JSValue,
) bool {
    if (idx < function.var_is_lexical.len and function.var_is_lexical[idx]) return false;
    if (slot_ops.varRefCellFromValue(old_value) != null) return false;
    if (slot_ops.varRefCellFromValue(value) != null) return false;
    return true;
}

inline fn tryFastPutLoc(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: usize,
) bool {
    if (stack.values.len == 0) return false;
    const value = stack.values[stack.values.len - 1];
    const old_value = frame.locals[idx];
    if (!plainLocalSlotFastPath(function, idx, old_value, value)) return false;

    // Move the owned stack slot into the local, matching execPutLoc -> setSlotValue
    // for a plain local slot. The stack slot is consumed by shrinking the slice.
    frame.locals[idx] = value;
    stack.values = stack.values.ptr[0 .. stack.values.len - 1];
    old_value.free(ctx.runtime);
    return true;
}

inline fn tryFastSetLoc(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: usize,
) bool {
    if (stack.values.len == 0) return false;
    const value = stack.values[stack.values.len - 1];
    const old_value = frame.locals[idx];
    if (!plainLocalSlotFastPath(function, idx, old_value, value)) return false;

    frame.locals[idx] = if (value.requiresRefCount()) value.dup() else value;
    old_value.free(ctx.runtime);
    return true;
}

inline fn tryFastGetField(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    atom_id: core.Atom,
) bool {
    if (stack.values.len == 0) return false;
    const top_index = stack.values.len - 1;
    const receiver = stack.values[top_index];
    const value = vm_property_field.qjsGetFieldFast(ctx.runtime, receiver, atom_id) orelse return false;
    stack.values[top_index] = if (value.requiresRefCount()) value.dup() else value;
    receiver.free(ctx.runtime);
    return true;
}

inline fn tryFastGetField2(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    atom_id: core.Atom,
) bool {
    if (stack.values.len == 0) return false;
    const receiver = stack.values[stack.values.len - 1];
    const value = vm_property_field.qjsGetFieldFast(ctx.runtime, receiver, atom_id) orelse return false;
    stack.pushAssumeCapacity(value);
    return true;
}

inline fn tryFastPutField(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    atom_id: core.Atom,
) bool {
    if (stack.values.len < 2) return false;
    const value_index = stack.values.len - 1;
    const obj_index = stack.values.len - 2;
    const value = stack.values[value_index];
    const obj = stack.values[obj_index];
    if (!vm_property_field.qjsPutFieldFast(ctx.runtime, obj, atom_id, value)) return false;

    stack.values = stack.values.ptr[0..obj_index];
    obj.free(ctx.runtime);
    value.free(ctx.runtime);
    return true;
}

/// Frame-setup wrapper that runs a NORMAL-kind bytecode function through the
/// recursive `dispatchRecursive`. Mirrors `runWithArgsState`'s setup (lines
/// 294-339) minus the inline-`Machine` loop and the generator/eval-code state,
/// which never apply to a normal-kind callee (`resumeExecutionState` /
/// `completeResumeState` are no-ops when `generator_state == null`, returning an
/// empty resume state and a null catch target). Nested JS→JS calls recurse
/// natively because the call opcodes run with `allow_inline=false`, routing back
/// through `callFunctionBytecodeModeState` → `callInternal`. Gated to
/// `recursive_dispatch_enabled` from `callFunctionBytecodeModeState`.
pub fn callInternal(
    ctx: *core.JSContext,
    entry_stack: *stack_mod.Stack,
    entry_function: *const bytecode.Bytecode,
    initial_this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const core.JSValue,
    output: ?*std.Io.Writer,
    global: *core.Object,
    input_eval_var_ref_names: []const core.Atom,
    input_eval_var_refs: []const core.JSValue,
    current_function_value: core.JSValue,
    new_target_value: core.JSValue,
    constructor_this_value: core.JSValue,
) HostError!core.JSValue {
    const call_depth_guard = try call_vm.enterCallDepth(ctx, global);
    defer call_depth_guard.deinit();
    const call_profile_guard = call_vm.enterCallProfile(ctx.runtime);
    defer call_profile_guard.deinit();
    try ctx.pushBacktraceFrameLazyName(entry_function.name, entry_function.filename, entry_function.line_num, entry_function.col_num, entry_function, exception_ops.resolveBacktraceLocation, current_function_value);
    defer ctx.popBacktraceFrame();

    // Frame storage (locals/args/var_refs) is carved from the VM stack arena;
    // reclaim the watermark after the frame has released its values.
    const frame_arena_mark = ctx.runtime.vm_stack.mark();
    defer ctx.runtime.vm_stack.restore(frame_arena_mark);

    var frame_storage = frame_mod.Frame.init(entry_function);
    ctx.borrowBacktracePc(&frame_storage.pc);
    defer frame_storage.deinit(&ctx.runtime.memory, ctx.runtime);
    var frame_eval_var_refs = try frame_storage.initCallBindings(ctx.runtime, .{
        .initial_this_value = initial_this_value,
        .current_function_value = current_function_value,
        .new_target_value = new_target_value,
        .constructor_this_value = constructor_this_value,
        .eval_local_names = &.{},
        .eval_local_slots = &.{},
        .input_eval_var_ref_names = input_eval_var_ref_names,
        .input_eval_var_refs = input_eval_var_refs,
        .inherited_eval_local_names = &.{},
        .inherited_eval_local_slots = &.{},
        .inherited_eval_var_ref_names = &.{},
        .inherited_eval_var_refs = &.{},
    });
    defer frame_eval_var_refs.deinit(ctx.runtime);

    var frame_roots = frame_mod.FrameRootScope{};
    frame_roots.init(ctx.runtime, entry_stack, &frame_storage, &frame_eval_var_refs);
    defer frame_roots.deinit();

    const use_inline_frame_storage = !entry_function.flags.is_generator and !entry_function.flags.is_async;
    const frame_arena: ?*core.VmStackArena = if (use_inline_frame_storage) &ctx.runtime.vm_stack else null;
    try call_vm.initFrameLocals(ctx, entry_function, &frame_storage, &.{}, &.{}, use_inline_frame_storage);
    try frame_storage.initArguments(&ctx.runtime.memory, frame_arena, args, use_inline_frame_storage, frame_mod.argumentsNeedsOriginalSnapshot(entry_function));
    try call_vm.initFrameVarRefs(ctx, global, entry_function, &frame_storage, var_refs, use_inline_frame_storage);

    try reserveEntryFrameCapacity(entry_stack, entry_function);
    errdefer call_runtime.closeFrameDestructuringIteratorsForAbruptCompletion(ctx, output, global, entry_stack, &frame_storage);

    // Slow-path entry: not a trampoline, so pass allow_tail_signal=false (a tail
    // call recurses through recurseInlineCall, which IS a trampoline — so the
    // callee's own tail chain is still TCO'd; only this single frame adds one
    // native level). dispatchRecursive therefore never yields `.tail` here.
    return switch (try dispatchRecursive(ctx, entry_function, global, &frame_storage, entry_stack, output, false)) {
        .returned => |value| value,
        .tail => unreachable,
    };
}

fn reserveEntryFrameCapacity(entry_stack: *stack_mod.Stack, entry_function: *const bytecode.Bytecode) !void {
    const frame_stack_size: usize = if (comptime builtin.mode == .Debug)
        // Some colocated tests hand-build bytecode without finalize's stack-size
        // pass; keep those Debug-only fixtures checked at entry. ReleaseFast
        // relies on finalized bytecode's verified stack_size.
        if (entry_function.stack_size == 0 and entry_function.code.len != 0)
            entry_function.code.len
        else
            entry_function.stack_size
    else
        entry_function.stack_size;
    try entry_stack.reserveFrameCapacity(frame_stack_size);
}

/// Result of running an inline-eligible callee via native recursion.
pub const RecurseOutcome = union(enum) {
    /// The callee returned `value` (owned by the caller). A regular call pushes
    /// it onto the operand stack; a tail call returns it as its own result.
    value: core.JSValue,
    /// The callee threw and THIS (caller) frame caught it — `frame.pc` is the
    /// catch target. The caller continues its dispatch loop.
    caught,
};

/// What a single `dispatchRecursive` frame produced. Returned to the caller's
/// trampoline (`recurseInlineCall`) so a proper tail call can REUSE the native
/// frame (constant stack depth) instead of recursing — the TCO trampoline.
pub const Outcome = union(enum) {
    /// The frame ran to a `return` / fall-off; `value` is owned by the caller.
    returned: core.JSValue,
    /// The frame hit a proper tail call; the trampoline tears this frame down
    /// and re-enters with `request`'s target (the call region is still live on
    /// the just-finished frame's operand stack). Only produced when the caller
    /// passed `allow_tail_signal = true`.
    tail: call_runtime.InlineCallRequest,
};

/// Run an inline-eligible bytecode call (`request`, resolved by
/// `resolveInlineTarget`) as a NATIVE Zig recursion into `dispatchRecursive`,
/// reusing the Machine's zero-copy frame setup (`setupInlineEntry`) — this is
/// the S2a pivot replacing `machine.pushCall`. Native depth is bounded by
/// `enterCallDepth` (catchable RangeError before stack overflow). On a callee
/// error, the error is routed through the CURRENT frame's catch handler
/// (mirroring `Machine.unwindForError` one level): caught → `.caught`,
/// otherwise the error propagates (the caller frame's own recursion catch / the
/// top-level handles it). NOTE (S2a-v1): no TCO trampoline yet — a tail call
/// recurses like a regular call (deep tail recursion is bounded by the native
/// depth cap, same limitation as S1; the trampoline is S2a-v2).
pub fn recurseInlineCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    caller_stack: *stack_mod.Stack,
    caller_frame: *frame_mod.Frame,
    caller_catch_target: *?usize,
    request: call_runtime.InlineCallRequest,
) HostError!RecurseOutcome {
    const source: inline_calls.Machine.ArgsSource = switch (request.layout) {
        .plain, .method => .{ .stack_region = .{
            .stack = caller_stack,
            .region_base = request.region_base,
            .argc = request.argc,
            .has_receiver = request.layout == .method,
        } },
        .prepared => .{ .prepared = .{
            .stack = caller_stack,
            .region_base = request.region_base,
            .argc = request.argc,
        } },
    };

    const depth_guard = call_vm.enterCallDepth(ctx, global) catch |err| {
        return routeCalleeError(ctx, output, global, caller_stack, caller_frame, caller_catch_target, err);
    };
    defer depth_guard.deinit();

    var entry: inline_calls.Entry = undefined;
    inline_calls.Machine.setupInlineEntry(ctx, global, &entry, request.target, source) catch |err| {
        return routeCalleeError(ctx, output, global, caller_stack, caller_frame, caller_catch_target, err);
    };
    // setupInlineEntry has consumed (popped + freed) the call region from
    // caller_stack; `entry` owns the new frame/stack carved from the arena.
    // TCO TRAMPOLINE: a proper tail call from the running frame replaces `entry`
    // in place (reusing the native frame + the held depth slot = constant native
    // stack depth), instead of recursing — so 100k strict tail calls don't blow
    // the C stack. Mirrors inline_calls.Machine.tailCallReuse.
    while (true) {
        const outcome = dispatchRecursive(ctx, &entry.view, global, &entry.frame, &entry.stack, output, true) catch |err| {
            call_runtime.closeFrameDestructuringIteratorsForAbruptCompletion(ctx, output, global, &entry.stack, &entry.frame);
            inline_calls.Machine.teardownInlineEntry(ctx, &entry);
            return routeCalleeError(ctx, output, global, caller_stack, caller_frame, caller_catch_target, err);
        };
        switch (outcome) {
            .returned => |result| {
                inline_calls.Machine.teardownInlineEntry(ctx, &entry);
                return .{ .value = result };
            },
            .tail => |tail_req| {
                // Tail call region [callable,args] (or [recv,callable,args] for a
                // method tail call) is still live on the just-finished frame's
                // operand stack. Move it out before tearing the frame down, then
                // re-enter with the tail target.
                const has_receiver = tail_req.layout == .method;
                const total = @as(usize, tail_req.argc) + 1 + @as(usize, @intFromBool(has_receiver));
                var inline_buf: [10]core.JSValue = undefined;
                const moved: []core.JSValue = if (total <= inline_buf.len)
                    inline_buf[0..total]
                else
                    try ctx.runtime.memory.alloc(core.JSValue, total);
                defer if (total > inline_buf.len) ctx.runtime.memory.free(core.JSValue, moved);
                @memcpy(moved, entry.stack.values[tail_req.region_base..][0..total]);
                entry.stack.values = entry.stack.values.ptr[0..tail_req.region_base];
                // `moved` now owns the region; free whatever setupInlineEntry does
                // not transfer (transferred slots are nulled to undefined).
                defer for (moved) |v| v.free(ctx.runtime);
                inline_calls.Machine.teardownInlineEntry(ctx, &entry);
                inline_calls.Machine.setupInlineEntry(ctx, global, &entry, tail_req.target, .{ .moved = .{ .values = moved, .has_receiver = has_receiver } }) catch |err| {
                    return routeCalleeError(ctx, output, global, caller_stack, caller_frame, caller_catch_target, err);
                };
                // loop: re-run dispatchRecursive on the reused frame.
            },
        }
    }
}

/// Shared error-unwind for `recurseInlineCall`: close any pending for-of
/// iterator on the caller stack, then try the caller frame's catch handler.
/// Returns `.caught` when handled (caller resumes at `frame.pc`), else the
/// error propagates. Mirrors the `catch` legs of the dispatch-loop call arms.
pub fn routeCalleeError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    caller_stack: *stack_mod.Stack,
    caller_frame: *frame_mod.Frame,
    caller_catch_target: *?usize,
    err: HostError,
) HostError!RecurseOutcome {
    try forof_ops.closeStackTopForOfIteratorForPendingError(ctx, output, global, caller_stack);
    if (try call_runtime.handleCatchableRuntimeError(ctx, caller_stack, caller_frame, caller_catch_target, global, err)) {
        return .caught;
    }
    return err;
}

pub fn dispatchRecursive(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    output: ?*std.Io.Writer,
    // When true (the recurseInlineCall trampoline), a proper tail call returns
    // `.tail` so the trampoline reuses the native frame (TCO). When false (the
    // callInternal slow-path entry, which is not a trampoline), a tail call
    // recurses like a regular call (one extra native frame, then the callee's
    // own trampoline TCOs its tail calls).
    allow_tail_signal: bool,
) HostError!Outcome {
    const code = function.code;
    var pc: usize = frame.pc;
    var catch_target_storage: ?usize = null;
    const catch_target: *?usize = &catch_target_storage;
    // Loops are made interruptible by polling on backward jumps (mirroring
    // QuickJS's backward-branch poll); the straight-line path stays poll-free.
    var interrupt_poller = control_vm.InterruptPoller.init(ctx.runtime);
    // S2a-v3 heap fallback: this frame's native depth is fixed for its lifetime
    // (sub-calls increment then restore it), so decide ONCE whether to inline
    // (native recurse) or hand calls to the slow heap path. Near the native cap,
    // a call goes slow → callFunctionBytecodeModeState routes it to the Machine.
    const allow_inline_calls = !call_vm.nativeDepthNearCap(ctx);
    while (true) {
        if (pc >= code.len) {
            frame.pc = pc;
            return .{ .returned = try control_vm.finishFunctionReturn(ctx, frame, stack.peek() orelse core.JSValue.undefinedValue()) };
        }
        const opc = code[pc];
        pc += 1;
switch (opc) {
    // ===================================================================
    // Pushes that decode an immediate operand (INLINE on C-local pc)
    // ===================================================================
    // Immediate pushes use assumeCapacity: every push is counted in the
    // verifier's stack_size and the frame stack is presized to stack_size+1
    // (reserveEntryFrameCapacity), so the bounds check is redundant — mirrors
    // qjs's bare `*sp++` and the get_loc inline above.
    op.push_i32 => {
        const v = readInt(i32, code[pc..][0..4]);
        pc += 4;
        stack.pushOwnedAssumeCapacity(core.JSValue.int32(v));
    },
    op.push_i16 => {
        const v: i32 = readInt(i16, code[pc..][0..2]);
        pc += 2;
        stack.pushOwnedAssumeCapacity(core.JSValue.int32(v));
    },
    op.push_i8 => {
        const v: i32 = @as(i8, @bitCast(code[pc]));
        pc += 1;
        stack.pushOwnedAssumeCapacity(core.JSValue.int32(v));
    },
    op.push_bigint_i32 => {
        const v = readInt(i32, code[pc..][0..4]);
        pc += 4;
        stack.pushOwnedAssumeCapacity(core.JSValue.shortBigInt(v));
    },

    // ---- Small-int / literal pushes (no operand; plain unfused push) ----
    op.push_minus1 => stack.pushOwnedAssumeCapacity(core.JSValue.int32(-1)),
    op.push_0 => stack.pushOwnedAssumeCapacity(core.JSValue.int32(0)),
    op.push_1 => stack.pushOwnedAssumeCapacity(core.JSValue.int32(1)),
    op.push_2 => stack.pushOwnedAssumeCapacity(core.JSValue.int32(2)),
    op.push_3 => stack.pushOwnedAssumeCapacity(core.JSValue.int32(3)),
    op.push_4 => stack.pushOwnedAssumeCapacity(core.JSValue.int32(4)),
    op.push_5 => stack.pushOwnedAssumeCapacity(core.JSValue.int32(5)),
    op.push_6 => stack.pushOwnedAssumeCapacity(core.JSValue.int32(6)),
    op.push_7 => stack.pushOwnedAssumeCapacity(core.JSValue.int32(7)),
    op.@"undefined" => stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue()),
    op.@"null" => stack.pushOwnedAssumeCapacity(core.JSValue.nullValue()),
    op.push_false => stack.pushOwnedAssumeCapacity(core.JSValue.boolean(false)),
    op.push_true => stack.pushOwnedAssumeCapacity(core.JSValue.boolean(true)),

    // ---- Constant-table / atom pushes (DELEGATE: operand decode + fusion) ----
    op.push_const => {
        frame.pc = pc;
        try value_vm.pushConst(ctx, stack, function, frame, opc);
        pc = frame.pc;
    },
    op.push_const8 => {
        frame.pc = pc;
        try value_vm.pushConst8(ctx, stack, function, frame, opc);
        pc = frame.pc;
    },
    op.push_atom_value => {
        frame.pc = pc;
        try value_vm.pushAtomValueVm(ctx, stack, function, frame, .{
            .global_env = .{
                .global = global,
                .eval_local_names = &.{},
                .eval_var_ref_names = frame.eval_var_ref_names,
                .eval_with_object = core.JSValue.undefinedValue(),
            },
            .regexp_prototype = class_vm.constructorPrototypeFromGlobal(ctx.runtime, global, "RegExp"),
        });
        pc = frame.pc;
    },
    op.push_empty_string => {
        frame.pc = pc;
        try value_vm.pushEmptyString(ctx, stack);
        pc = frame.pc;
    },
    op.private_symbol => {
        frame.pc = pc;
        try value_vm.pushPrivateSymbol(ctx, stack, function, frame);
        pc = frame.pc;
    },
    op.regexp => {
        frame.pc = pc;
        try regexp_vm.pushLiteral(ctx, stack, class_vm.constructorPrototypeFromGlobal(ctx.runtime, global, "RegExp"));
        pc = frame.pc;
    },
    op.fclosure, op.fclosure8 => {
        frame.pc = pc;
        const step = try call_vm.closure(ctx, output, global, stack, function, frame, catch_target, opc, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },

    // ===================================================================
    // Stack manipulation (DELEGATE; pure-stack, no operand)
    // ===================================================================
    op.drop => {
        // Fast path: a plain (non catch-marker) top is popped + freed inline
        // (free is a no-op for ints). Catch markers carry the try-region target
        // and delegate to the full handler.
        const top = stack.values[stack.values.len - 1];
        if (top.isCatchOffset()) {
            frame.pc = pc;
            switch (try value_vm.drop(ctx.runtime, stack)) {
                .value => {},
                .catch_target => |target| {
                    catch_target.* = target;
                    pc = frame.pc;
                    continue;
                },
            }
            pc = frame.pc;
        } else {
            stack.values.len -= 1;
            top.free(ctx.runtime);
        }
    },
    op.nip_catch => {
        frame.pc = pc;
        try value_vm.nipCatch(ctx.runtime, stack);
        pc = frame.pc;
    },
    op.nip => {
        frame.pc = pc;
        try value_vm.nip(ctx, stack);
        pc = frame.pc;
    },
    op.nip1 => {
        frame.pc = pc;
        try value_vm.nip1(ctx, stack);
        pc = frame.pc;
    },
    op.dup => {
        frame.pc = pc;
        try value_vm.dup(ctx, stack, opc);
        pc = frame.pc;
    },
    op.dup1 => {
        frame.pc = pc;
        try value_vm.dup1(ctx, stack);
        pc = frame.pc;
    },
    op.dup2 => {
        frame.pc = pc;
        try value_vm.dup2(ctx, stack);
        pc = frame.pc;
    },
    op.dup3 => {
        frame.pc = pc;
        try value_vm.dup3(ctx, stack);
        pc = frame.pc;
    },
    op.swap => {
        frame.pc = pc;
        try value_vm.swap(ctx, stack);
        pc = frame.pc;
    },
    op.swap2 => {
        frame.pc = pc;
        try value_vm.swap2(ctx, stack);
        pc = frame.pc;
    },
    op.insert2 => {
        frame.pc = pc;
        try value_vm.insert2(ctx, stack);
        pc = frame.pc;
    },
    op.insert3 => {
        frame.pc = pc;
        try value_vm.insert3(ctx, stack);
        pc = frame.pc;
    },
    op.insert4 => {
        frame.pc = pc;
        try value_vm.insert4(ctx, stack);
        pc = frame.pc;
    },
    op.perm3 => {
        frame.pc = pc;
        try value_vm.perm3(ctx, stack);
        pc = frame.pc;
    },
    op.perm4 => {
        frame.pc = pc;
        try value_vm.perm4(ctx, stack);
        pc = frame.pc;
    },
    op.perm5 => {
        frame.pc = pc;
        try value_vm.perm5(ctx, stack);
        pc = frame.pc;
    },
    op.rot3l => {
        frame.pc = pc;
        try value_vm.rot3l(ctx, stack);
        pc = frame.pc;
    },
    op.rot3r => {
        frame.pc = pc;
        try value_vm.rot3r(ctx, stack);
        pc = frame.pc;
    },
    op.rot4l => {
        frame.pc = pc;
        try value_vm.rot4l(ctx, stack);
        pc = frame.pc;
    },
    op.rot5l => {
        frame.pc = pc;
        try value_vm.rot5l(ctx, stack);
        pc = frame.pc;
    },

    // ===================================================================
    // Locals / args / var-refs (all DELEGATE; operand decode in handler)
    // ===================================================================
    // S2b: hot local GETs inline the leaned body directly — skip the `loc`
    // dispatcher (its per-op switch + the comptime-gated fusion scans) AND the
    // execGetLoc call AND the frame.pc round-trip. GC-free (presized-stack
    // assumeCapacity push + a verifier-trusted frame.locals[idx] read, no bounds
    // check), so no frame.pc publish is needed. This is the #1 crypto opcode.
    op.get_loc0 => array_ops.pushSlotValueAssumeCapacity(stack, frame.locals[0]),
    op.get_loc1 => array_ops.pushSlotValueAssumeCapacity(stack, frame.locals[1]),
    op.get_loc2 => array_ops.pushSlotValueAssumeCapacity(stack, frame.locals[2]),
    op.get_loc3 => array_ops.pushSlotValueAssumeCapacity(stack, frame.locals[3]),
    op.get_loc8 => {
        const idx = code[pc];
        pc += 1;
        array_ops.pushSlotValueAssumeCapacity(stack, frame.locals[idx]);
    },
    op.get_loc => {
        const idx = readInt(u16, code[pc..][0..2]);
        pc += 2;
        array_ops.pushSlotValueAssumeCapacity(stack, frame.locals[idx]);
    },
    op.put_loc => {
        const idx = readInt(u16, code[pc..][0..2]);
        if (tryFastPutLoc(ctx, function, frame, stack, idx)) {
            pc += 2;
        } else {
            frame.pc = pc;
            try vm_property_locals.loc(ctx, function, global, frame, stack, opc, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
            pc = frame.pc;
        }
    },
    op.set_loc => {
        const idx = readInt(u16, code[pc..][0..2]);
        if (tryFastSetLoc(ctx, function, frame, stack, idx)) {
            pc += 2;
        } else {
            frame.pc = pc;
            try vm_property_locals.loc(ctx, function, global, frame, stack, opc, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
            pc = frame.pc;
        }
    },
    op.put_loc8 => {
        const idx = code[pc];
        if (tryFastPutLoc(ctx, function, frame, stack, idx)) {
            pc += 1;
        } else {
            frame.pc = pc;
            try vm_property_locals.loc(ctx, function, global, frame, stack, opc, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
            pc = frame.pc;
        }
    },
    op.set_loc8 => {
        const idx = code[pc];
        if (tryFastSetLoc(ctx, function, frame, stack, idx)) {
            pc += 1;
        } else {
            frame.pc = pc;
            try vm_property_locals.loc(ctx, function, global, frame, stack, opc, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
            pc = frame.pc;
        }
    },
    op.set_loc0 => {
        if (!tryFastSetLoc(ctx, function, frame, stack, 0)) {
            frame.pc = pc;
            try vm_property_locals.loc(ctx, function, global, frame, stack, opc, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
            pc = frame.pc;
        }
    },
    op.set_loc1 => {
        if (!tryFastSetLoc(ctx, function, frame, stack, 1)) {
            frame.pc = pc;
            try vm_property_locals.loc(ctx, function, global, frame, stack, opc, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
            pc = frame.pc;
        }
    },
    op.set_loc2 => {
        if (!tryFastSetLoc(ctx, function, frame, stack, 2)) {
            frame.pc = pc;
            try vm_property_locals.loc(ctx, function, global, frame, stack, opc, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
            pc = frame.pc;
        }
    },
    op.set_loc3 => {
        if (!tryFastSetLoc(ctx, function, frame, stack, 3)) {
            frame.pc = pc;
            try vm_property_locals.loc(ctx, function, global, frame, stack, opc, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
            pc = frame.pc;
        }
    },
    op.get_loc0_loc1 => {
        frame.pc = pc;
        try vm_property_locals.loc(ctx, function, global, frame, stack, opc, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
        pc = frame.pc;
    },
    op.put_loc0 => {
        if (!tryFastPutLoc(ctx, function, frame, stack, 0)) {
            frame.pc = pc;
            try slot_ops.execPutLoc(ctx, function, global, frame, stack, 0, 0, opc, false);
            pc = frame.pc;
        }
    },
    op.put_loc1 => {
        if (!tryFastPutLoc(ctx, function, frame, stack, 1)) {
            frame.pc = pc;
            try slot_ops.execPutLoc(ctx, function, global, frame, stack, 1, 0, opc, false);
            pc = frame.pc;
        }
    },
    op.put_loc2 => {
        if (!tryFastPutLoc(ctx, function, frame, stack, 2)) {
            frame.pc = pc;
            try slot_ops.execPutLoc(ctx, function, global, frame, stack, 2, 0, opc, false);
            pc = frame.pc;
        }
    },
    op.put_loc3 => {
        if (!tryFastPutLoc(ctx, function, frame, stack, 3)) {
            frame.pc = pc;
            try slot_ops.execPutLoc(ctx, function, global, frame, stack, 3, 0, opc, false);
            pc = frame.pc;
        }
    },
    // S2b: hot arg GETs inline the leaned body (skip the `arg` dispatcher + the
    // execGetArg call + frame.pc round-trip). Variadic bound: an arg index past
    // the actual arg count reads undefined (args may be fewer than declared).
    // GC-free presized-stack push, so no frame.pc publish needed.
    op.get_arg0 => array_ops.pushSlotValueAssumeCapacity(stack, if (frame.args.len > 0) frame.args[0] else core.JSValue.undefinedValue()),
    op.get_arg1 => array_ops.pushSlotValueAssumeCapacity(stack, if (frame.args.len > 1) frame.args[1] else core.JSValue.undefinedValue()),
    op.get_arg2 => array_ops.pushSlotValueAssumeCapacity(stack, if (frame.args.len > 2) frame.args[2] else core.JSValue.undefinedValue()),
    op.get_arg3 => array_ops.pushSlotValueAssumeCapacity(stack, if (frame.args.len > 3) frame.args[3] else core.JSValue.undefinedValue()),
    op.get_arg => {
        const idx = readInt(u16, code[pc..][0..2]);
        pc += 2;
        array_ops.pushSlotValueAssumeCapacity(stack, if (idx < frame.args.len) frame.args[idx] else core.JSValue.undefinedValue());
    },
    op.put_arg, op.set_arg, op.put_arg0, op.put_arg1, op.put_arg2, op.put_arg3, op.set_arg0, op.set_arg1, op.set_arg2, op.set_arg3 => {
        frame.pc = pc;
        try vm_property_locals.arg(ctx, function, frame, stack, opc);
        pc = frame.pc;
    },
    op.get_var_ref, op.get_var_ref_check, op.put_var_ref, op.put_var_ref_check, op.put_var_ref_check_init, op.set_var_ref, op.get_var_ref0, op.get_var_ref1, op.get_var_ref2, op.get_var_ref3, op.put_var_ref0, op.put_var_ref1, op.put_var_ref2, op.put_var_ref3, op.set_var_ref0, op.set_var_ref1, op.set_var_ref2, op.set_var_ref3 => {
        frame.pc = pc;
        const step = try vm_property_locals.varRefVm(ctx, function, global, frame, stack, opc, catch_target, false, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.set_loc_uninitialized, op.get_loc_check, op.put_loc_check, op.put_loc_check_init => {
        frame.pc = pc;
        const step = try vm_property_locals.checkedLocVm(ctx, function, global, frame, stack, opc, catch_target, true, false, &.{}, frame.eval_var_ref_names, core.JSValue.undefinedValue());
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.close_loc => {
        frame.pc = pc;
        try vm_property_locals.closeLoc(ctx, function, frame);
        pc = frame.pc;
    },
    op.make_loc_ref, op.make_arg_ref, op.make_var_ref_ref => {
        frame.pc = pc;
        try vm_property_ref.makeSlotRef(ctx, stack, function, frame, opc);
        pc = frame.pc;
    },
    op.make_var_ref => {
        frame.pc = pc;
        const step = try vm_property_ref.makeVarRefVm(ctx, output, global, stack, function, frame, catch_target, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },

    // ===================================================================
    // Arithmetic / compare / logic (int32 fast path INLINE; slow DELEGATE)
    // ===================================================================
    op.add, op.sub, op.mul, op.div, op.mod, op.pow, op.shl, op.sar, op.shr, op.@"and", op.@"or", op.xor => {
        if (opc != op.pow and arith_vm.tryInt32Binary(stack, opc)) continue;
        frame.pc = pc;
        switch (try arith_vm.binaryVm(ctx, stack, frame, catch_target, opc, output, global)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.lt, op.lte, op.gt, op.gte, op.eq, op.neq, op.strict_eq, op.strict_neq => {
        if (arith_vm.tryInt32Compare(stack, opc)) continue;
        frame.pc = pc;
        switch (try arith_vm.compareVm(ctx, stack, frame, catch_target, opc, output, global)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.neg, op.plus, op.inc, op.dec => {
        frame.pc = pc;
        switch (try arith_vm.unaryVm(ctx, stack, frame, catch_target, opc, output, global)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.not => {
        frame.pc = pc;
        switch (try arith_vm.bitNotVm(ctx, stack, frame, catch_target, output, global)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.lnot => try value_vm.logicalNot(ctx.runtime, stack),
    op.post_inc, op.post_dec => {
        // Int32 fast path: leave the old value on the stack and push old±1 on
        // top (mirrors postUpdate's int branch). Overflow folds to float via
        // fastInt32Add. GC-free. Non-int delegates.
        const top = stack.values[stack.values.len - 1];
        if (top.asInt32()) |oi| {
            const updated = if (opc == op.post_inc) arith_vm.fastInt32Add(oi, 1) else arith_vm.fastInt32Sub(oi, 1);
            stack.pushOwnedAssumeCapacity(updated);
        } else {
            frame.pc = pc;
            switch (try arith_vm.postUpdateVm(ctx, stack, frame, catch_target, opc, output, global)) {
                .done => {},
                .continue_loop => {},
            }
            pc = frame.pc;
        }
    },
    op.inc_loc, op.dec_loc => {
        // Int32 fast path: a local holding an int32 is a plain slot (NOT a
        // var-ref cell — a cell is an object), so update it in place with no
        // dup/free and no global-lexical sync (dispatchRecursive runs only
        // normal-kind frames, which have no top-level global-lexical locals).
        // Overflow folds to a float via fastInt32Add. Anything else (cell,
        // bigint, coercible object) delegates to the full handler.
        const idx = code[pc];
        if (frame.locals[idx].asInt32()) |iv| {
            pc += 1;
            frame.locals[idx] = if (opc == op.inc_loc) arith_vm.fastInt32Add(iv, 1) else arith_vm.fastInt32Sub(iv, 1);
        } else {
            frame.pc = pc;
            switch (try arith_vm.updateLocalVm(ctx, stack, function, global, frame, catch_target, opc, output, false)) {
                .done => {},
                .continue_loop => {},
            }
            pc = frame.pc;
        }
    },
    op.add_loc => {
        frame.pc = pc;
        switch (try arith_vm.addLocalVm(ctx, stack, function, global, frame, catch_target, output, false)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.typeof => try value_vm.typeOf(ctx, stack),
    op.typeof_is_undefined => try value_vm.typeOfIsUndefined(ctx.runtime, stack),
    op.typeof_is_function => try value_vm.typeOfIsFunction(ctx.runtime, stack),
    op.is_undefined_or_null => try value_vm.isUndefinedOrNull(ctx.runtime, stack),
    op.is_undefined => try value_vm.isUndefined(ctx.runtime, stack),
    op.is_null => try value_vm.isNull(ctx.runtime, stack),
    op.in, op.instanceof => {
        frame.pc = pc;
        switch (try vm_property_field.inOrInstanceof(ctx, output, global, stack, function, frame, catch_target, opc)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.private_in => {
        frame.pc = pc;
        switch (try class_vm.privateInVm(ctx, output, global, stack, function, frame, catch_target)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.delete => {
        frame.pc = pc;
        switch (try vm_property_ref.deletePropertyVm(ctx, output, global, stack, function, frame, catch_target)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.delete_var => {
        frame.pc = pc;
        try vm_property_ref.deleteVar(ctx, global, stack, function, frame, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs);
        pc = frame.pc;
    },

    // ===================================================================
    // Control flow (jumps/branches INLINE on C-local pc; throw DELEGATE)
    // ===================================================================
    op.goto => {
        const operand_pc = pc;
        const diff = readInt(i32, code[pc..][0..4]);
        pc = relativePc(operand_pc, diff);
        if (diff < 0) try interrupt_poller.poll(ctx.runtime);
    },
    op.goto16 => {
        const operand_pc = pc;
        const diff: i32 = readInt(i16, code[pc..][0..2]);
        pc = relativePc(operand_pc, diff);
        if (diff < 0) try interrupt_poller.poll(ctx.runtime);
    },
    op.goto8 => {
        const operand_pc = pc;
        const diff: i32 = @as(i8, @bitCast(code[pc]));
        pc = relativePc(operand_pc, diff);
        if (diff < 0) try interrupt_poller.poll(ctx.runtime);
    },
    op.if_false, op.if_true => {
        const operand_pc = pc;
        const diff = readInt(i32, code[pc..][0..4]);
        pc += 4;
        const value = try stack.pop();
        defer value.free(ctx.runtime);
        const truthy = value.asBool() orelse value_ops.isTruthy(value);
        const branch_if_true = (opc == op.if_true);
        if (truthy == branch_if_true) {
            pc = relativePc(operand_pc, diff);
            if (diff < 0) try interrupt_poller.poll(ctx.runtime);
        }
    },
    op.if_false8, op.if_true8 => {
        const operand_pc = pc;
        const diff: i32 = @as(i8, @bitCast(code[pc]));
        pc += 1;
        const value = try stack.pop();
        defer value.free(ctx.runtime);
        const truthy = value.asBool() orelse value_ops.isTruthy(value);
        const branch_if_true = (opc == op.if_true8);
        if (truthy == branch_if_true) {
            pc = relativePc(operand_pc, diff);
            if (diff < 0) try interrupt_poller.poll(ctx.runtime);
        }
    },
    op.gosub => {
        const operand_pc = pc;
        const diff = readInt(i32, code[pc..][0..4]);
        const return_pc = pc + 4;
        if (return_pc > @as(usize, @intCast(std.math.maxInt(i32)))) return error.InvalidBytecode;
        try stack.pushOwned(core.JSValue.int32(@intCast(return_pc)));
        pc = relativePc(operand_pc, diff);
    },
    op.ret => {
        const target = try stack.pop();
        defer target.free(ctx.runtime);
        const pc_i32 = target.asInt32() orelse return error.InvalidBytecode;
        if (pc_i32 < 0) return error.InvalidBytecode;
        const target_pc: usize = @intCast(pc_i32);
        if (target_pc >= code.len) return error.InvalidBytecode;
        pc = target_pc;
    },
    op.nop => control_vm.nop(),

    // ---- Return ----
    op.@"return" => {
        frame.pc = pc;
        return .{ .returned = try control_vm.returnTop(ctx, stack, frame, null) };
    },
    op.return_undef => {
        frame.pc = pc;
        return .{ .returned = try control_vm.returnUndefined(ctx, frame, null) };
    },

    // ---- Throw / catch ----
    op.throw => {
        frame.pc = pc;
        switch (try control_vm.throwTop(ctx, output, global, stack, frame, catch_target)) {
            .handled => {},
        }
        pc = frame.pc;
        continue;
    },
    op.throw_error => {
        frame.pc = pc;
        switch (try control_vm.throwErrorVm(ctx, stack, function, frame, catch_target, global)) {
            .handled => {},
        }
        pc = frame.pc;
        continue;
    },
    op.@"catch" => {
        frame.pc = pc;
        try control_vm.catchTarget(function, frame, stack, catch_target);
        pc = frame.pc;
    },

    // ===================================================================
    // Calls (DELEGATE to the out-of-line recursive call resolution)
    // ===================================================================
    op.call, op.call0, op.call1, op.call2, op.call3 => {
        const argc: u16 = switch (opc) {
            op.call => blk: {
                const v = readInt(u16, code[pc..][0..2]);
                pc += 2;
                break :blk v;
            },
            op.call0 => 0,
            op.call1 => 1,
            op.call2 => 2,
            op.call3 => 3,
            else => unreachable,
        };
        frame.pc = pc;
        // S2a: a plain-bytecode callee runs as a NATIVE recursion via
        // recurseInlineCall (reusing the Machine's zero-copy setup), not the
        // dup-heavy slow path.
        switch (try call_runtime.execCall(ctx, stack, function, frame, catch_target, argc, output, global, allow_inline_calls)) {
            .done => {},
            .continue_loop => {
                pc = frame.pc;
                continue;
            },
            .inline_call => |request| switch (try recurseInlineCall(ctx, output, global, stack, frame, catch_target, request)) {
                .value => |v| stack.pushOwnedAssumeCapacity(v),
                .caught => {
                    pc = frame.pc;
                    continue;
                },
            },
        }
        pc = frame.pc;
    },
    op.tail_call => {
        frame.pc = pc;
        switch (try call_vm.tailCall(ctx, output, global, stack, function, frame, catch_target, allow_inline_calls)) {
            .handled => {
                pc = frame.pc;
                continue;
            },
            .return_value => |value| {
                return .{ .returned = value };
            },
            // Proper tail call. Under a trampoline (allow_tail_signal) signal it
            // up so the native frame is reused (constant depth). Otherwise (the
            // callInternal slow-path entry) recurse and return the callee value.
            .tail_inline => |request| {
                if (allow_tail_signal) return .{ .tail = request };
                switch (try recurseInlineCall(ctx, output, global, stack, frame, catch_target, request)) {
                    .value => |v| return .{ .returned = v },
                    .caught => {
                        pc = frame.pc;
                        continue;
                    },
                }
            },
        }
    },
    op.tail_call_method => {
        frame.pc = pc;
        switch (try call_vm.tailCallMethod(ctx, output, global, stack, function, frame, catch_target, allow_inline_calls)) {
            .handled => {
                pc = frame.pc;
                continue;
            },
            .return_value => |value| {
                return .{ .returned = value };
            },
            .tail_inline => |request| {
                if (allow_tail_signal) return .{ .tail = request };
                switch (try recurseInlineCall(ctx, output, global, stack, frame, catch_target, request)) {
                    .value => |v| return .{ .returned = v },
                    .caught => {
                        pc = frame.pc;
                        continue;
                    },
                }
            },
        }
    },
    op.call_method => {
        frame.pc = pc;
        switch (try call_vm.callMethod(ctx, output, global, stack, function, frame, catch_target, allow_inline_calls)) {
            .done => {},
            .continue_loop => {
                pc = frame.pc;
                continue;
            },
            .inline_call => |request| switch (try recurseInlineCall(ctx, output, global, stack, frame, catch_target, request)) {
                .value => |v| stack.pushOwnedAssumeCapacity(v),
                .caught => {
                    pc = frame.pc;
                    continue;
                },
            },
        }
        pc = frame.pc;
    },
    op.call_prepared => {
        frame.pc = pc;
        switch (try call_vm.callPrepared(ctx, output, global, stack, function, frame, catch_target, allow_inline_calls)) {
            .done => {},
            .continue_loop => {
                pc = frame.pc;
                continue;
            },
            .inline_call => |request| switch (try recurseInlineCall(ctx, output, global, stack, frame, catch_target, request)) {
                .value => |v| stack.pushOwnedAssumeCapacity(v),
                .caught => {
                    pc = frame.pc;
                    continue;
                },
            },
        }
        pc = frame.pc;
    },
    op.prepare_call_prop_atom => {
        frame.pc = pc;
        switch (try call_vm.prepareCallPropAtom(ctx, output, global, stack, function, frame, catch_target)) {
            .done => {},
            .continue_loop => {
                pc = frame.pc;
                continue;
            },
        }
        pc = frame.pc;
    },
    op.call_constructor => {
        frame.pc = pc;
        switch (try call_vm.constructor(ctx, output, global, stack, function, frame, catch_target)) {
            .done => {},
            .continue_loop => {
                pc = frame.pc;
                continue;
            },
        }
        pc = frame.pc;
    },
    op.apply => {
        frame.pc = pc;
        switch (try call_vm.apply(ctx, output, global, stack, function, frame, catch_target)) {
            .done => {},
            .continue_loop => {
                pc = frame.pc;
                continue;
            },
        }
        pc = frame.pc;
    },
    op.apply_eval => {
        frame.pc = pc;
        switch (try eval_module_vm.applyEval(ctx, stack, function, frame, catch_target, output, global, eval_class_field_initializer_flag, eval_parameter_initializer_flag)) {
            .done => {},
            .continue_loop => {
                pc = frame.pc;
                continue;
            },
        }
        pc = frame.pc;
    },
    op.eval => {
        frame.pc = pc;
        // A non-%eval% callee (the identifier `eval` shadowed by a normal
        // function) in tail position yields `.tail_inline` — handle it like a
        // tail call so eval-named tail recursion (test262 tco-non-eval-*) TCOs
        // via the trampoline instead of growing the native stack.
        switch (try eval_module_vm.directEval(ctx, stack, function, frame, catch_target, output, global, eval_class_field_initializer_flag, eval_parameter_initializer_flag, allow_inline_calls)) {
            .done => {},
            .continue_loop => {
                pc = frame.pc;
                continue;
            },
            .tail_inline => |request| {
                if (allow_tail_signal) return .{ .tail = request };
                switch (try recurseInlineCall(ctx, output, global, stack, frame, catch_target, request)) {
                    .value => |v| return .{ .returned = v },
                    .caught => {
                        pc = frame.pc;
                        continue;
                    },
                }
            },
        }
        pc = frame.pc;
    },
    op.import => {
        frame.pc = pc;
        try eval_module_vm.dynamicImport(ctx, output, global, stack, function, frame);
        pc = frame.pc;
    },

    // ---- ctor / brand helpers (DELEGATE) ----
    op.check_ctor => {
        frame.pc = pc;
        switch (try call_vm.checkCtorVm(ctx, stack, frame, catch_target, global)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.check_ctor_return => {
        frame.pc = pc;
        switch (try call_vm.checkCtorReturnVm(ctx, stack, frame, catch_target, global)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.init_ctor => {
        frame.pc = pc;
        switch (try call_vm.initCtorVm(ctx, output, global, stack, function, frame, catch_target)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.check_brand => {
        frame.pc = pc;
        switch (try class_vm.checkBrandVm(ctx, stack, frame, catch_target, global)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },
    op.add_brand => {
        frame.pc = pc;
        switch (try class_vm.addBrandVm(ctx, stack, frame, catch_target, global)) {
            .done => {},
            .continue_loop => {},
        }
        pc = frame.pc;
    },

    // ===================================================================
    // Variables / globals / property access (DELEGATE)
    // ===================================================================
    op.get_var, op.get_var_undef => {
        frame.pc = pc;
        const step = try vm_property_globals.getVar(ctx, output, global, stack, function, frame, catch_target, opc, false, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs, core.JSValue.undefinedValue());
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.put_var => {
        frame.pc = pc;
        const step = try vm_property_globals.putVar(ctx, output, global, stack, function, frame, catch_target, function.flags.is_strict or function.flags.runtime_strict, false, false, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs, core.JSValue.undefinedValue());
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.check_define_var, op.define_var, op.define_func, op.put_var_init => {
        frame.pc = pc;
        const step = try vm_property_globals.globalDefinition(ctx, global, stack, function, frame, catch_target, opc, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs, false, false);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.get_field, op.get_field2, op.put_field => {
        const atom_id = readInt(u32, code[pc..][0..4]);
        const handled = switch (opc) {
            op.get_field => tryFastGetField(ctx, stack, atom_id),
            op.get_field2 => tryFastGetField2(ctx, stack, atom_id),
            op.put_field => tryFastPutField(ctx, stack, atom_id),
            else => unreachable,
        };
        if (handled) {
            pc += 4;
        } else {
            frame.pc = pc;
            const step = try vm_property_field.field(ctx, output, global, stack, function, frame, catch_target, opc, false);
            pc = frame.pc;
            switch (step) {
                .done => {},
                .continue_loop => continue,
            }
        }
    },
    op.get_array_el, op.get_array_el2, op.put_array_el => {
        frame.pc = pc;
        const step = try vm_property_field.arrayElement(ctx, output, global, stack, function, frame, catch_target, opc);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.to_propkey => {
        frame.pc = pc;
        const step = try vm_property_field.toPropKeyVm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.to_propkey2 => {
        frame.pc = pc;
        const step = try vm_property_field.toPropKey2Vm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.set_name, op.set_name_computed => {
        frame.pc = pc;
        try vm_property_field.setName(ctx, output, global, stack, function, frame, opc);
        pc = frame.pc;
    },
    op.get_ref_value => {
        frame.pc = pc;
        const step = try vm_property_ref.getRefValueVm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.put_ref_value => {
        frame.pc = pc;
        const step = try vm_property_ref.putRefValueVm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.get_private_field => {
        frame.pc = pc;
        const step = try vm_property_private.getPrivateFieldVm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.put_private_field => {
        frame.pc = pc;
        const step = try vm_property_private.putPrivateFieldVm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.define_private_field => {
        frame.pc = pc;
        const step = try vm_property_private.definePrivateFieldVm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },

    // ---- with-statement opcodes (a normal function body may contain `with`) ----
    op.with_get_var, op.with_delete_var, op.with_make_ref, op.with_get_ref, op.with_get_ref_undef => {
        frame.pc = pc;
        const step = try vm_property_ref.withGetOrDelete(ctx, output, global, stack, function, frame, catch_target, opc);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.with_put_var => {
        frame.pc = pc;
        const step = try vm_property_ref.withPut(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },

    // ===================================================================
    // Object / array literals, super, this, iterators (DELEGATE)
    // (define_field / get_super / get_super_value / put_super_value /
    //  get_length appeared in two draft categories — merged here once)
    // ===================================================================
    op.object => {
        frame.pc = pc;
        try literal_vm.object(ctx, stack, global);
        pc = frame.pc;
    },
    op.array_from => {
        frame.pc = pc;
        try literal_vm.arrayFrom(ctx, stack, function, frame, global);
        pc = frame.pc;
    },
    op.append => {
        frame.pc = pc;
        const step = try literal_vm.appendSpreadValuesVm(ctx, output, global, stack, opc, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.rest => {
        frame.pc = pc;
        try literal_vm.rest(ctx, stack, function, frame);
        pc = frame.pc;
    },
    op.define_field => {
        frame.pc = pc;
        const step = try literal_vm.defineField(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.define_array_el => {
        frame.pc = pc;
        const step = try literal_vm.defineArrayEl(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.set_proto => {
        frame.pc = pc;
        try literal_vm.setProto(ctx, stack);
        pc = frame.pc;
    },
    op.set_home_object => {
        frame.pc = pc;
        try class_vm.setHomeObject(ctx, stack);
        pc = frame.pc;
    },
    op.copy_data_properties => {
        const mask = code[pc];
        pc += 1;
        frame.pc = pc;
        const step = try literal_vm.copyDataProperties(ctx, output, global, stack, mask, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.define_method => {
        frame.pc = pc;
        const step = try class_vm.defineMethod(ctx, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.define_method_computed => {
        frame.pc = pc;
        const step = try class_vm.defineMethodComputed(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.define_class, op.define_class_computed => {
        frame.pc = pc;
        const step = try class_vm.defineClass(ctx, output, global, stack, function, frame, catch_target, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs, opc == op.define_class_computed);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.special_object => {
        frame.pc = pc;
        try literal_vm.specialObject(ctx, stack, function, frame, global, &.{}, &.{}, frame.eval_var_ref_names, frame.eval_var_refs);
        pc = frame.pc;
    },
    op.get_super => {
        frame.pc = pc;
        try class_vm.getSuper(ctx, stack, frame);
        pc = frame.pc;
    },
    op.get_super_value => {
        frame.pc = pc;
        const step = try class_vm.getSuperValue(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.put_super_value => {
        frame.pc = pc;
        const step = try class_vm.putSuperValue(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.get_length => {
        frame.pc = pc;
        const step = try literal_vm.getLength(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.to_object => {
        frame.pc = pc;
        const step = try value_vm.toObjectVm(ctx, stack, frame, catch_target, global);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.push_this => {
        frame.pc = pc;
        const step = try value_vm.pushThisVm(ctx, stack, frame, catch_target, global);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.for_of_start, op.for_await_of_start => {
        frame.pc = pc;
        const step = try iter_vm.forOfStartVm(ctx, output, global, stack, function, frame, catch_target, opc == op.for_await_of_start);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.for_in_start => {
        frame.pc = pc;
        const step = try iter_vm.forInStartVm(ctx, output, global, stack, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.iterator_next => {
        frame.pc = pc;
        const step = try iter_vm.iteratorNextVm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.iterator_check_object => {
        frame.pc = pc;
        const step = try iter_vm.iteratorCheckObjectVm(ctx, stack, frame, catch_target, global);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.iterator_get_value_done => {
        frame.pc = pc;
        const step = try iter_vm.iteratorGetValueDoneVm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.iterator_call => {
        frame.pc = pc;
        const step = try iter_vm.iteratorCallVm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.for_of_next => {
        frame.pc = pc;
        const step = try iter_vm.forOfNextVm(ctx, output, global, stack, function, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },
    op.for_in_next => {
        frame.pc = pc;
        try iter_vm.forInNext(ctx, output, global, stack);
        pc = frame.pc;
    },
    op.iterator_close => {
        frame.pc = pc;
        const step = try iter_vm.iteratorCloseVm(ctx, output, global, stack, frame, catch_target);
        pc = frame.pc;
        switch (step) {
            .done => {},
            .continue_loop => continue,
        }
    },

    // ===================================================================
    // Generator / async opcodes: a normal-kind frame never executes these
    // ===================================================================
    op.initial_yield, op.yield, op.yield_star, op.async_yield_star, op.await, op.return_async => @panic("dispatchRecursive: generator opcode in normal frame"),

    // ===================================================================
    // Invalid / unknown
    // ===================================================================
    op.invalid => return error.InvalidBytecode,
    else => return error.InvalidBytecode,
}    }
}

comptime {
    if (recursive_dispatch_enabled) {
        _ = &callInternal;
        _ = &dispatchRecursive;
    }
}
