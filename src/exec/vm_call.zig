const fusion_stats = @import("vm_fusion_stats.zig");
const std = @import("std");

const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const frame_mod = @import("frame.zig");
const collection_vm = @import("array_ops.zig");
const property_ops = @import("property_ops.zig");
const call_runtime = @import("call_runtime.zig");
const exception_ops = @import("vm_exception_ops.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const class_init_ops = @import("class_init_ops.zig");
const forof_ops = @import("forof_ops.zig");
const inline_calls = @import("inline_calls.zig");
const object_ops = @import("object_ops.zig");
const regexp_fastpath = @import("regexp_fastpath.zig");
const slot_ops = @import("slot_ops.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const op = bytecode.opcode.op;

pub const Step = enum { done, continue_loop };

/// Step result for opcodes that may request an inline bytecode call to be
/// pushed by the dispatch loop.
pub const CallStep = union(enum) {
    done,
    continue_loop,
    inline_call: call_runtime.InlineCallRequest,
};

pub const TailCallMethodResult = union(enum) {
    handled,
    return_value: core.JSValue,
    /// Eligible bytecode method target for tail-call frame reuse; the
    /// dispatch loop replaces the current inline frame (the receiver becomes
    /// the reused frame's `this`) instead of recursing.
    tail_inline: call_runtime.InlineCallRequest,
};

pub const TailCallResult = union(enum) {
    handled,
    return_value: core.JSValue,
    /// Eligible bytecode target for tail-call frame reuse; the dispatch
    /// loop replaces the current inline frame instead of recursing.
    tail_inline: call_runtime.InlineCallRequest,
};

const PreparedPropertyTarget = union(enum) {
    native: frame_mod.PreparedNativeCallTarget,
    value: core.JSValue,
};

const PreparedNativeLookup = struct {
    target: frame_mod.PreparedNativeCallTarget,
    holder: *core.Object,
    index: usize,
};

pub const CallDepthGuard = struct {
    ctx: *core.JSContext,

    pub fn deinit(self: CallDepthGuard) void {
        self.ctx.call_depth -= 1;
        self.ctx.native_call_depth -= 1;
    }
};

pub const CallProfileGuard = struct {
    rt: *core.JSRuntime,
    previous: ?*core.profile.OpcodeProfile,

    pub fn deinit(self: CallProfileGuard) void {
        if (self.rt.opcode_profile != null) {
            _ = core.profile.activate(self.previous);
        }
    }
};

pub fn enterCallDepth(ctx: *core.JSContext, global: *core.Object) !CallDepthGuard {
    if (ctx.native_call_depth >= maxNativeJsCallDepth(ctx) or ctx.call_depth >= maxLogicalJsCallDepth(ctx)) {
        _ = exception_ops.throwRangeErrorMessage(ctx, global, "Maximum call stack size exceeded") catch |err| return err;
        return error.RangeError;
    }
    ctx.call_depth += 1;
    ctx.native_call_depth += 1;
    return .{ .ctx = ctx };
}

/// Depth accounting for inline (same interpreter loop) call frames.
pub fn enterInlineCallDepth(ctx: *core.JSContext, global: *core.Object) !void {
    if (ctx.call_depth >= maxLogicalJsCallDepth(ctx)) {
        _ = exception_ops.throwRangeErrorMessage(ctx, global, "Maximum call stack size exceeded") catch |err| return err;
        return error.RangeError;
    }
    ctx.call_depth += 1;
}

pub fn enterCallProfile(rt: *core.JSRuntime) CallProfileGuard {
    const previous = if (rt.opcode_profile) |opcode_profile|
        core.profile.activate(opcode_profile)
    else
        null;
    if (rt.opcode_profile) |profile| profile.recordCallFrame();
    return .{ .rt = rt, .previous = previous };
}

pub fn linkDerivedConstructorThisLocal(ctx: *core.JSContext, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
    if (!function.flags.is_derived_class_constructor) return;
    const count = @min(function.var_names.len, frame.locals.len);
    for (function.var_names[0..count], 0..) |atom_id, idx| {
        if (!value_ops.atomNameEql(ctx.runtime, atom_id, "this")) continue;
        const this_cell = try slot_ops.ensureVarRefCell(ctx, &frame.this_value);
        const old_value = frame.locals[idx];
        frame.locals[idx] = this_cell;
        old_value.free(ctx.runtime);
        return;
    }
}

pub fn initFrameLocals(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    use_inline_storage: bool,
) !void {
    if (function.var_count == 0) return;
    var storage_transferred = false;
    errdefer if (!storage_transferred) frame.releaseOwnedStorage(&ctx.runtime.memory, ctx.runtime);

    const locals = blk: {
        if (use_inline_storage and function.var_count <= frame.inline_locals.len) {
            break :blk frame.inline_locals[0..function.var_count];
        }
        if (use_inline_storage) {
            if (ctx.runtime.vm_stack.carve(&ctx.runtime.memory, function.var_count)) |window| break :blk window;
        }
        frame.locals_on_heap = true;
        break :blk try ctx.runtime.memory.alloc(core.JSValue, function.var_count);
    };
    @memset(locals, core.JSValue.undefinedValue());
    frame.locals = locals;

    const uninit = if (use_inline_storage and function.var_count <= frame.inline_locals_uninit.len)
        frame.inline_locals_uninit[0..function.var_count]
    else blk: {
        frame.locals_uninit_on_heap = true;
        break :blk try ctx.runtime.memory.alloc(bool, function.var_count);
    };
    @memset(uninit, false);
    frame.locals_uninit = uninit;

    if (value_ops.atomNameEql(ctx.runtime, function.name, "<eval>")) {
        call_runtime.initializeEvalFrameLocals(ctx, function, frame, eval_local_names, eval_local_slots);
    }
    try linkDerivedConstructorThisLocal(ctx, function, frame);
    storage_transferred = true;
}

pub fn initFrameVarRefs(ctx: *core.JSContext, global: *core.Object, function: *const bytecode.Bytecode, frame: *frame_mod.Frame, var_refs: []const core.JSValue, use_inline_storage: bool) !void {
    if (var_refs.len > 0) {
        const owned_refs = if (use_inline_storage and var_refs.len <= frame.inline_var_refs.len)
            frame.inline_var_refs[0..var_refs.len]
        else blk: {
            if (use_inline_storage) {
                if (ctx.runtime.vm_stack.carve(&ctx.runtime.memory, var_refs.len)) |window| break :blk window;
            }
            frame.var_refs_on_heap = true;
            break :blk try ctx.runtime.memory.alloc(core.JSValue, var_refs.len);
        };
        for (var_refs, 0..) |value, idx| owned_refs[idx] = value.dup();
        frame.var_refs = owned_refs;
        return;
    }

    if (function.var_ref_names.len == 0) return;
    const owned_refs = if (use_inline_storage and function.var_ref_names.len <= frame.inline_var_refs.len)
        frame.inline_var_refs[0..function.var_ref_names.len]
    else blk: {
        if (use_inline_storage) {
            if (ctx.runtime.vm_stack.carve(&ctx.runtime.memory, function.var_ref_names.len)) |window| break :blk window;
        }
        frame.var_refs_on_heap = true;
        break :blk try ctx.runtime.memory.alloc(core.JSValue, function.var_ref_names.len);
    };
    errdefer if (frame.var_refs_on_heap) ctx.runtime.memory.free(core.JSValue, owned_refs);
    var initialized: usize = 0;
    errdefer {
        for (owned_refs[0..initialized]) |*val| val.free(ctx.runtime);
    }
    for (function.var_ref_names, 0..) |var_name, idx| {
        const val = call_runtime.globalLexicalValue(ctx, var_name) orelse global.getProperty(var_name);
        const cell = try core.Object.create(ctx.runtime, core.class.ids.object, null);
        errdefer core.Object.destroyFromHeader(ctx.runtime, &cell.header);
        try cell.initVarRefPayload(ctx.runtime, val);
        owned_refs[idx] = cell.value();
        initialized += 1;
    }
    frame.var_refs = owned_refs;
}

pub fn closure(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
) !Step {
    const index: u32 = if (opc == op.fclosure) blk: {
        const value = readInt(u32, function.code[frame.pc..][0..4]);
        frame.pc += 4;
        break :blk value;
    } else blk: {
        const value: u32 = function.code[frame.pc];
        frame.pc += 1;
        break :blk value;
    };
    if (fusion_stats.counted(.tryFuseImmediateSimpleArrayMapClosure, try tryFuseImmediateSimpleArrayMapClosure(ctx, output, global, stack, function, frame, catch_target, index))) |step| return step;
    try collection_vm.pushFunctionClosure(ctx, frame, stack, function, global, index, opc, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs);
    return .done;
}

fn tryFuseImmediateSimpleArrayMapClosure(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    index: usize,
) !?Step {
    if (frame.pc + 3 > function.code.len) return null;
    if (function.code[frame.pc] != op.call_method) return null;
    if (readInt(u16, function.code[frame.pc + 1 ..][0..2]) != 1) return null;
    if (stack.values.len < 2) return null;

    const callback = function.constants.get(index) orelse return error.InvalidBytecode;
    defer callback.free(ctx.runtime);
    const callback_bytecode = call_runtime.functionBytecodeFromValue(callback) orelse return null;
    if (callback_bytecode.simple_numeric_kind != .arg0_const) return null;

    const receiver = stack.values[stack.values.len - 2];
    const method = stack.values[stack.values.len - 1];
    const method_object = object_ops.callableObjectFromValue(method) orelse return null;
    const native_ref = core.function.decodeNativeBuiltinId(method_object.nativeFunctionIdSlot().*) orelse return null;
    const map_id = @intFromEnum(method_ids.array.PrototypeMethod.map);
    if (native_ref.domain != .array or native_ref.id != map_id) return null;

    const args = [_]core.JSValue{callback};
    if (try collection_vm.qjsArrayMapSimpleNumericArg0DefaultSpeciesFastCall(ctx.runtime, global, receiver, callback)) |fast_value| {
        errdefer fast_value.free(ctx.runtime);
        const method_owned = try stack.pop();
        method_owned.free(ctx.runtime);
        const receiver_owned = try stack.pop();
        receiver_owned.free(ctx.runtime);
        try stack.pushOwned(fast_value);
        frame.pc += 3;
        return .done;
    }
    const result = collection_vm.qjsArrayPrototypeNativeRecord(ctx, output, global, receiver, method_object, map_id, args[0..], function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    const value = result orelse return null;
    errdefer value.free(ctx.runtime);

    const method_owned = try stack.pop();
    method_owned.free(ctx.runtime);
    const receiver_owned = try stack.pop();
    receiver_owned.free(ctx.runtime);
    try stack.pushOwned(value);
    frame.pc += 3;
    return .done;
}

fn tryFastMathCall(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    argc: u16,
) !bool {
    if (stack.values.len < @as(usize, argc) + 1) return false;
    const base = stack.values.len - (@as(usize, argc) + 1);
    const func = stack.values[base];
    if (!func.isObject()) return false;
    const object = object_ops.functionObjectFromValue(func) orelse return false;
    const native_ref = core.function.decodeNativeBuiltinId(object.nativeFunctionIdSlot().*) orelse return false;
    if (native_ref.domain != .math) return false;

    const result = switch (native_ref.id) {
        1 => blk: { // Math.abs
            if (argc != 1) return false;
            const arg = stack.values[base + 1];
            if (arg.asInt32()) |val| {
                if (val == std.math.minInt(i32)) {
                    break :blk core.JSValue.float64(@abs(@as(f64, @floatFromInt(val))));
                } else {
                    break :blk core.JSValue.int32(@intCast(@abs(val)));
                }
            }
            if (arg.asFloat64()) |val| break :blk core.JSValue.float64(@abs(val));
            return false;
        },
        2 => blk: { // Math.floor
            if (argc != 1) return false;
            const arg = stack.values[base + 1];
            if (arg.asInt32()) |val| break :blk core.JSValue.int32(val);
            if (arg.asFloat64()) |val| break :blk core.JSValue.float64(@floor(val));
            return false;
        },
        7 => blk: { // Math.min
            if (argc == 1) {
                const arg = stack.values[base + 1];
                if (arg.isNumber()) break :blk arg.dup();
            } else if (argc == 2) {
                const arg0 = stack.values[base + 1];
                const arg1 = stack.values[base + 2];
                if (arg0.asInt32()) |v0| {
                    if (arg1.asInt32()) |v1| {
                        break :blk core.JSValue.int32(@min(v0, v1));
                    }
                }
                if (arg0.asFloat64()) |v0| {
                    if (arg1.asFloat64()) |v1| {
                        break :blk core.JSValue.float64(@min(v0, v1));
                    }
                }
            }
            return false;
        },
        8 => blk: { // Math.max
            if (argc == 1) {
                const arg = stack.values[base + 1];
                if (arg.isNumber()) break :blk arg.dup();
            } else if (argc == 2) {
                const arg0 = stack.values[base + 1];
                const arg1 = stack.values[base + 2];
                if (arg0.asInt32()) |v0| {
                    if (arg1.asInt32()) |v1| {
                        break :blk core.JSValue.int32(@max(v0, v1));
                    }
                }
                if (arg0.asFloat64()) |v0| {
                    if (arg1.asFloat64()) |v1| {
                        break :blk core.JSValue.float64(@max(v0, v1));
                    }
                }
            }
            return false;
        },
        else => return false,
    };

    var remaining = @as(usize, argc) + 1;
    while (remaining > 0) {
        remaining -= 1;
        const val = try stack.pop();
        val.free(ctx.runtime);
    }
    try stack.pushOwned(result);
    return true;
}

pub fn call(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
) !CallStep {
    const argc = switch (opc) {
        op.call => blk: {
            const value = readInt(u16, function.code[frame.pc..][0..2]);
            frame.pc += 2;
            break :blk value;
        },
        op.call0 => 0,
        op.call1 => 1,
        op.call2 => 2,
        op.call3 => 3,
        else => unreachable,
    };
    // Speculative builtin-call fast paths (Math.abs / percent-hex / simple
    // numeric callee). These are the call-site analogue of the tryFuse*
    // microbench fast paths and tax every ordinary call when they miss, so they
    // share the fusion comptime gate (default off): an ordinary bytecode-function
    // call goes straight to execCall.
    if (comptime fusion_stats.fusions_enabled) {
        if (try tryFastMathCall(ctx, stack, argc)) return .done;
        if (try tryFastSimpleStringCall(ctx, stack, argc)) return .done;
        if (try tryFastSimpleNumericCall(ctx, stack, argc)) return .done;
    }
    return switch (try call_runtime.execCall(ctx, stack, function, frame, catch_target, argc, output, global, true)) {
        .done => .done,
        .continue_loop => .continue_loop,
        .inline_call => |request| .{ .inline_call = request },
    };
}

fn tryFastSimpleStringCall(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    argc: u16,
) !bool {
    if (argc != 1) return false;
    if (stack.values.len < 2) return false;
    const base = stack.values.len - 2;
    const func = stack.values[base];
    const kind = simpleStringCallableKind(func) orelse return false;
    const arg = stack.values[base + 1];
    const byte_i32 = arg.asInt32() orelse return false;

    const result = switch (kind) {
        .percent_hex_byte => blk: {
            const byte: u8 = @truncate(@as(u32, @bitCast(byte_i32)));
            const cached = try ctx.runtime.percentHexString(byte);
            break :blk cached.value().dup();
        },
        .none => return false,
    };
    errdefer result.free(ctx.runtime);

    var remaining: usize = 2;
    while (remaining > 0) {
        remaining -= 1;
        const value = try stack.pop();
        value.free(ctx.runtime);
    }
    try stack.pushOwned(result);
    return true;
}

fn simpleStringCallableKind(func: core.JSValue) ?bytecode.function.SimpleStringKind {
    if (func.isFunctionBytecode()) {
        const fb = call_runtime.functionBytecodeFromValue(func) orelse return null;
        return if (fb.simple_string_kind == .none) null else fb.simple_string_kind;
    }
    const object = object_ops.functionObjectFromValue(func) orelse return null;
    const function_value = object.functionBytecodeSlot().* orelse return null;
    const fb = call_runtime.functionBytecodeFromValue(function_value) orelse return null;
    return if (fb.simple_string_kind == .none) null else fb.simple_string_kind;
}

fn tryFastSimpleNumericCall(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    argc: u16,
) !bool {
    if (argc > 2) return false;
    const frame_len = @as(usize, argc) + 1;
    if (stack.values.len < frame_len) return false;
    const base = stack.values.len - frame_len;
    const func = stack.values[base];
    const simple = simpleNumericCallable(func) orelse return false;
    if (argc == 0 and simple.kind != .capture0_post_inc_return) return false;
    const args = stack.values[base + 1 .. stack.values.len];
    const result = simpleNumericCallResult(ctx.runtime, simple, args) catch |err| switch (err) {
        error.NotSimpleNumericCall => return false,
        else => return err,
    };
    errdefer result.free(ctx.runtime);
    var remaining = frame_len;
    while (remaining > 0) {
        remaining -= 1;
        const value = try stack.pop();
        value.free(ctx.runtime);
    }
    try stack.pushOwned(result);
    return true;
}

const SimpleNumericCallable = struct {
    kind: bytecode.function.SimpleNumericKind,
    binop: u8,
    rhs: i32,
    capture0: ?core.JSValue = null,
    capture0_slot: ?core.JSValue = null,
};

fn simpleNumericCallable(func: core.JSValue) ?SimpleNumericCallable {
    if (func.isFunctionBytecode()) {
        const fb = call_runtime.functionBytecodeFromValue(func) orelse return null;
        return simpleNumericCallableFromBytecode(fb, null, null);
    }
    const object = object_ops.functionObjectFromValue(func) orelse return null;
    const function_value = object.functionBytecodeSlot().* orelse return null;
    const fb = call_runtime.functionBytecodeFromValue(function_value) orelse return null;
    const captures = object.functionCapturesSlot().*;
    const capture0_slot = if (captures.len != 0) captures[0] else null;
    const capture0 = if (capture0_slot) |slot| slot_ops.slotValueBorrow(slot) else null;
    return simpleNumericCallableFromBytecode(fb, capture0, capture0_slot);
}

fn simpleNumericCallableFromBytecode(fb: *const bytecode.FunctionBytecode, capture0: ?core.JSValue, capture0_slot: ?core.JSValue) ?SimpleNumericCallable {
    return switch (fb.simple_numeric_kind) {
        .arg0_const => .{ .kind = .arg0_const, .binop = fb.simple_numeric_op, .rhs = fb.simple_numeric_rhs },
        .arg0_arg1 => .{ .kind = .arg0_arg1, .binop = fb.simple_numeric_op, .rhs = 0 },
        .capture0_arg0 => .{ .kind = .capture0_arg0, .binop = fb.simple_numeric_op, .rhs = 0, .capture0 = capture0 orelse return null },
        .capture0_post_inc_return => .{ .kind = .capture0_post_inc_return, .binop = 0, .rhs = 0, .capture0_slot = capture0_slot orelse return null },
        .none => null,
    };
}

fn simpleNumericCallResult(rt: *core.JSRuntime, simple: SimpleNumericCallable, args: []const core.JSValue) !core.JSValue {
    return switch (simple.kind) {
        .arg0_const => {
            if (args.len == 0 or !args[0].isNumber()) return error.NotSimpleNumericCall;
            return simpleNumericBinary(rt, simple.binop, args[0], core.JSValue.int32(simple.rhs));
        },
        .arg0_arg1 => {
            if (args.len < 2 or !args[0].isNumber() or !args[1].isNumber()) return error.NotSimpleNumericCall;
            return simpleNumericBinary(rt, simple.binop, args[0], args[1]);
        },
        .capture0_arg0 => {
            if (args.len == 0 or !args[0].isNumber()) return error.NotSimpleNumericCall;
            const captured = simple.capture0 orelse return error.NotSimpleNumericCall;
            if (!captured.isNumber()) return error.NotSimpleNumericCall;
            return simpleNumericBinary(rt, simple.binop, captured, args[0]);
        },
        .capture0_post_inc_return => try simpleCapture0PostIncReturn(rt, simple.capture0_slot orelse return error.NotSimpleNumericCall),
        .none => error.NotSimpleNumericCall,
    };
}

fn simpleCapture0PostIncReturn(rt: *core.JSRuntime, capture0_slot: core.JSValue) !core.JSValue {
    const cell = slot_ops.varRefCellFromValue(capture0_slot) orelse return error.NotSimpleNumericCall;
    if (cell.varRefIsDeletedSlot().* or cell.varRefIsFunctionNameSlot().* or cell.varRefIsConstSlot().*) return error.NotSimpleNumericCall;
    const slot = cell.varRefValueSlot();
    const current_value = slot.* orelse return error.NotSimpleNumericCall;
    const current = current_value.asInt32() orelse return error.NotSimpleNumericCall;
    const updated = fastInt32Add(current, 1);
    try cell.setVarRefValue(rt, updated);
    return updated;
}

fn simpleNumericBinary(rt: *core.JSRuntime, binop: u8, lhs: core.JSValue, rhs: core.JSValue) !core.JSValue {
    if (lhs.asInt32()) |lhs_int| {
        if (rhs.asInt32()) |rhs_int| {
            return switch (binop) {
                op.add => fastInt32Add(lhs_int, rhs_int),
                op.sub => fastInt32Sub(lhs_int, rhs_int),
                op.mul => fastInt32Mul(lhs_int, rhs_int),
                else => try value_ops.binary(rt, binop, lhs, rhs),
            };
        }
    }
    return try value_ops.binary(rt, binop, lhs, rhs);
}

fn fastInt32Add(lhs: i32, rhs: i32) core.JSValue {
    const result = @addWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.JSValue.int32(result[0]);
    return value_ops.numberToValue(@as(f64, @floatFromInt(lhs)) + @as(f64, @floatFromInt(rhs)));
}

fn fastInt32Sub(lhs: i32, rhs: i32) core.JSValue {
    const result = @subWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.JSValue.int32(result[0]);
    return value_ops.numberToValue(@as(f64, @floatFromInt(lhs)) - @as(f64, @floatFromInt(rhs)));
}

fn fastInt32Mul(lhs: i32, rhs: i32) core.JSValue {
    if ((lhs == 0 and rhs < 0) or (rhs == 0 and lhs < 0)) return core.JSValue.float64(-0.0);
    const result = @mulWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.JSValue.int32(result[0]);
    return value_ops.numberToValue(@as(f64, @floatFromInt(lhs)) * @as(f64, @floatFromInt(rhs)));
}

pub fn tailCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    allow_inline: bool,
) !TailCallResult {
    const argc = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    switch (try call_runtime.execCall(ctx, stack, function, frame, catch_target, argc, output, global, allow_inline)) {
        .done => {},
        .continue_loop => return .handled,
        .inline_call => |request| return .{ .tail_inline = request },
    }
    if (stack.peek()) |value| return .{ .return_value = value };
    return .{ .return_value = core.JSValue.undefinedValue() };
}

pub fn prepareCallPropAtom(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    if (frame.pc + 4 > function.code.len) return error.InvalidBytecode;
    const site_id_u32 = readInt(u32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    if (site_id_u32 >= function.call_sites.len or site_id_u32 > std.math.maxInt(u16)) return error.InvalidBytecode;
    const site_id: u16 = @intCast(site_id_u32);
    const site = function.call_sites[site_id];
    if (site.kind != .prop_atom) return error.InvalidBytecode;

    const receiver = stack.peek() orelse return error.StackUnderflow;
    defer receiver.free(ctx.runtime);
    const target = preparePropertyCallTarget(ctx, output, global, receiver, site, function, frame) catch |err| {
        try forof_ops.closeStackTopForOfIteratorForPendingErrorWithFrame(ctx, output, global, stack, frame);
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    switch (target) {
        .native => |native| {
            if (try tryCallPreparedNativeNoArg(ctx, output, global, stack, function, frame, catch_target, receiver, native)) |step| {
                return step;
            }
            try frame.pushPreparedNativeCall(&ctx.runtime.memory, site_id, stack.values.len, native);
        },
        .value => |value| {
            errdefer value.free(ctx.runtime);
            try frame.pushPreparedValueCall(&ctx.runtime.memory, site_id, stack.values.len, value);
        },
    }
    return .done;
}

fn tryCallPreparedNativeNoArg(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    receiver: core.JSValue,
    native: frame_mod.PreparedNativeCallTarget,
) !?Step {
    if (frame.pc + 3 > function.code.len or function.code[frame.pc] != op.call_prepared) return null;
    const argc = readInt(u16, function.code[frame.pc + 1 ..][0..2]);
    if (argc != 0) return null;
    frame.pc += 3;

    const args: []const core.JSValue = &.{};
    const result = callPreparedNativeTarget(ctx, output, global, receiver, native, args, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        discardPreparedCallInputs(ctx.runtime, stack, 0) catch {};
        return err;
    };
    errdefer result.free(ctx.runtime);
    try discardPreparedCallInputs(ctx.runtime, stack, 0);
    if (dropUnusedCallResult(ctx, function, frame, result)) return .done;
    try stack.pushOwned(result);
    return .done;
}

pub fn callPrepared(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !CallStep {
    if (frame.pc + 2 > function.code.len) return error.InvalidBytecode;
    const argc = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    if (stack.values.len < @as(usize, argc) + 1) return error.StackUnderflow;
    const args_start = stack.values.len - argc;
    const receiver_index = args_start - 1;
    const receiver = stack.values[receiver_index];
    const args = stack.values[args_start..];
    const target = frame.popPreparedCallTarget() orelse return error.InvalidBytecode;

    var rooted_func = core.JSValue.undefinedValue();
    var rooted_func_active = false;
    defer if (rooted_func_active) rooted_func.free(ctx.runtime);

    const result = switch (target) {
        .native => |native| callPreparedNativeTarget(ctx, output, global, receiver, native, args, function, frame) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
            discardPreparedCallInputs(ctx.runtime, stack, argc) catch {};
            return err;
        },
        .value => |func| blk: {
            rooted_func = func;
            rooted_func_active = true;
            // Inline frame fast path: a prepared property call to a plain
            // bytecode function runs as an inline frame (like op.call_method),
            // so method-position recursion gets the logical call-depth limit and
            // its tail calls reuse frames. The prepared rewrite moved the
            // callable off-stack (freeing the slot stack_size budgeted for the
            // original call_method shape `[receiver, callable, args...]`), so
            // pushing it back on top as `[receiver, args..., callable]` stays
            // within budget and keeps it rooted until the dispatch loop's
            // pushCall duplicates it. Ownership transfers to the stack
            // (rooted_func_active = false); the .prepared push consumes it.
            if (inline_calls.resolveInlineTarget(global, receiver, rooted_func)) |inline_target| {
                stack.pushOwned(rooted_func) catch |err| {
                    discardPreparedCallInputs(ctx.runtime, stack, argc) catch {};
                    return err;
                };
                rooted_func_active = false;
                return .{ .inline_call = .{ .target = inline_target, .region_base = receiver_index, .argc = argc, .layout = .prepared } };
            }
            const fast_result = fastNativeMethodCall(ctx, output, global, receiver, rooted_func, args, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                discardPreparedCallInputs(ctx.runtime, stack, argc) catch {};
                return err;
            };
            if (fast_result) |value| break :blk value;
            const maybe_array_result = collection_vm.qjsArrayMethodFastCall(ctx, output, global, receiver, rooted_func, args, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                discardPreparedCallInputs(ctx.runtime, stack, argc) catch {};
                return err;
            };
            if (maybe_array_result) |value| break :blk value;
            break :blk call_runtime.callValueOrBytecodeClassMode(ctx, output, global, receiver, rooted_func, args, function, frame, class_init_ops.isCurrentSuperConstructor(ctx, frame, rooted_func)) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                discardPreparedCallInputs(ctx.runtime, stack, argc) catch {};
                return err;
            };
        },
    };
    errdefer result.free(ctx.runtime);
    try discardPreparedCallInputs(ctx.runtime, stack, argc);
    if (dropUnusedCallResult(ctx, function, frame, result)) return .done;
    try stack.pushOwned(result);
    return .done;
}

pub fn callMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !CallStep {
    const argc = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    if (try tryFastSimpleNumericMethodCall(ctx, stack, argc)) return .done;
    // Inline frame fast path: a method call whose callable is a plain bytecode
    // function runs as an inline frame (like op.call), so method-position
    // recursion gets the logical call-depth limit instead of the shallow
    // native-recursion limit, and its tail-positioned method calls become
    // frame-reusing proper tail calls. Receiver, callable, and args stay on the
    // operand stack (zero-copy) at `[receiver, callable, args...]` until the
    // dispatch loop pushes the frame; the receiver becomes the callee's `this`
    // (arrow targets use their lexical `this`). Native builtin methods — the
    // common case — are not inline-eligible and fall through to the fast native
    // dispatch below. Class constructors (super() targets) are rejected by
    // `resolveInlineTarget`, so this never shadows the super-constructor path.
    {
        const total = @as(usize, argc) + 2;
        if (stack.values.len >= total) {
            const region_base = stack.values.len - total;
            const receiver = stack.values[region_base];
            const method = stack.values[region_base + 1];
            if (inline_calls.resolveInlineTarget(global, receiver, method)) |target| {
                return .{ .inline_call = .{ .target = target, .region_base = region_base, .argc = argc, .layout = .method } };
            }
        }
    }
    var inline_args: [4]core.JSValue = undefined;
    const args_buf: []core.JSValue = if (argc <= inline_args.len)
        inline_args[0..argc]
    else
        try ctx.runtime.memory.alloc(core.JSValue, argc);
    defer if (argc > inline_args.len) ctx.runtime.memory.free(core.JSValue, args_buf);
    var remaining: usize = argc;
    while (remaining > 0) {
        remaining -= 1;
        args_buf[remaining] = try stack.pop();
    }
    defer for (args_buf) |arg| arg.free(ctx.runtime);
    const func = try stack.pop();
    defer func.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    const fast_result = fastNativeMethodCall(ctx, output, global, obj, func, args_buf, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    if (fast_result) |value| {
        if (dropUnusedCallResult(ctx, function, frame, value)) return .done;
        errdefer value.free(ctx.runtime);
        try stack.pushOwned(value);
        return .done;
    }
    const maybe_array_result = collection_vm.qjsArrayMethodFastCall(ctx, output, global, obj, func, args_buf, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    const result = if (maybe_array_result) |array_result|
        array_result
    else
        call_runtime.callValueOrBytecodeClassMode(ctx, output, global, obj, func, args_buf, function, frame, class_init_ops.isCurrentSuperConstructor(ctx, frame, func)) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
    if (dropUnusedCallResult(ctx, function, frame, result)) return .done;
    errdefer result.free(ctx.runtime);
    try stack.pushOwned(result);
    return .done;
}

fn tryFastSimpleNumericMethodCall(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    argc: u16,
) !bool {
    if (argc != 0) return false;
    const frame_len = @as(usize, argc) + 2;
    if (stack.values.len < frame_len) return false;
    const base = stack.values.len - frame_len;
    const func = stack.values[base + 1];
    const result = (try simplePreIncVarRef0CallResult(ctx.runtime, func)) orelse return false;
    errdefer result.free(ctx.runtime);
    var remaining = frame_len;
    while (remaining > 0) {
        remaining -= 1;
        const value = try stack.pop();
        value.free(ctx.runtime);
    }
    try stack.pushOwned(result);
    return true;
}

fn simplePreIncVarRef0CallResult(rt: *core.JSRuntime, func: core.JSValue) !?core.JSValue {
    const object = object_ops.functionObjectFromValue(func) orelse return null;
    const function_value = object.functionBytecodeSlot().* orelse return null;
    const fb = call_runtime.functionBytecodeFromValue(function_value) orelse return null;
    if (fb.is_class_constructor or fb.func_kind != .normal) return null;
    if (fb.var_count != 0 or fb.cpool_count != 0) return null;
    if (!isPreIncVarRef0ReturnBytecode(fb.byte_code)) return null;

    const captures = object.functionCapturesSlot().*;
    if (captures.len == 0) return null;
    const cell = slot_ops.varRefCellFromValue(captures[0]) orelse return null;
    if (cell.varRefIsDeletedSlot().* or cell.varRefIsFunctionNameSlot().* or cell.varRefIsConstSlot().*) return null;
    const slot = cell.varRefValueSlot();
    const current_value = slot.* orelse return null;
    const current = current_value.asInt32() orelse return null;
    const updated = fastInt32Add(current, 1);
    try cell.setVarRefValue(rt, updated);
    return updated;
}

fn isPreIncVarRef0ReturnBytecode(code: []const u8) bool {
    var pc: usize = 0;
    if (!readVarRef0Get(code, &pc)) return false;
    if (pc >= code.len or code[pc] != op.inc) return false;
    pc += 1;
    if (pc < code.len and code[pc] == op.dup) pc += 1;
    if (!readVarRef0Put(code, &pc)) return false;
    if (pc >= code.len or code[pc] != op.@"return") return false;
    pc += 1;
    return pc == code.len;
}

fn readVarRef0Get(code: []const u8, pc: *usize) bool {
    if (pc.* >= code.len) return false;
    return switch (code[pc.*]) {
        op.get_var_ref0 => blk: {
            pc.* += 1;
            break :blk true;
        },
        op.get_var_ref, op.get_var_ref_check => blk: {
            if (pc.* + 3 > code.len) break :blk false;
            if (readInt(u16, code[pc.* + 1 ..][0..2]) != 0) break :blk false;
            pc.* += 3;
            break :blk true;
        },
        else => false,
    };
}

fn readVarRef0Put(code: []const u8, pc: *usize) bool {
    if (pc.* >= code.len) return false;
    return switch (code[pc.*]) {
        op.put_var_ref0 => blk: {
            pc.* += 1;
            break :blk true;
        },
        op.put_var_ref, op.put_var_ref_check, op.put_var_ref_check_init => blk: {
            if (pc.* + 3 > code.len) break :blk false;
            if (readInt(u16, code[pc.* + 1 ..][0..2]) != 0) break :blk false;
            pc.* += 3;
            break :blk true;
        },
        else => false,
    };
}

fn preparePropertyCallTarget(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    site: bytecode.function.CallSite,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !PreparedPropertyTarget {
    if (cachedPreparedNativeCallTarget(function, site, receiver)) |native| {
        return .{ .native = native };
    }
    if (autoInitNativeTargetForReceiver(ctx.runtime, global, receiver, site.atom_id)) |lookup| {
        installPreparedNativeCallIc(function, site, ctx.runtime, receiver, lookup.holder, lookup.index);
        return .{ .native = lookup.target };
    }
    const value = try object_ops.getValueProperty(ctx, output, global, receiver, site.atom_id, function, frame);
    return .{ .value = value };
}

fn autoInitNativeTargetForReceiver(
    rt: *core.JSRuntime,
    global: *core.Object,
    receiver: core.JSValue,
    atom_id: core.Atom,
) ?PreparedNativeLookup {
    if (objectFromValue(receiver)) |object| {
        return autoInitNativeTargetInObjectChain(receiver, object, atom_id);
    }
    const prototype = primitivePrototypeForCall(rt, global, receiver) orelse return null;
    return autoInitNativeTargetInObjectChain(receiver, prototype, atom_id);
}

fn autoInitNativeTargetInObjectChain(
    receiver: core.JSValue,
    start: *core.Object,
    atom_id: core.Atom,
) ?PreparedNativeLookup {
    var cursor: ?*core.Object = start;
    while (cursor) |object| {
        if (object.proxyTarget() != null or object.exotic != null) return null;
        if (object.findProperty(atom_id)) |index| {
            const target = preparedNativeTargetFromAutoInitEntry(receiver, object, index, atom_id) orelse return null;
            return .{ .target = target, .holder = object, .index = index };
        }
        cursor = object.getPrototype();
    }
    return null;
}

fn cachedPreparedNativeCallTarget(
    function: *const bytecode.Bytecode,
    site: bytecode.function.CallSite,
    receiver: core.JSValue,
) ?frame_mod.PreparedNativeCallTarget {
    const object = objectFromValue(receiver) orelse return null;
    if (object.proxyTarget() != null or object.exotic != null) return null;
    const slot = function.icSlotForPc(site.prepare_pc) orelse return null;

    switch (slot.lookupOwnDataResult(object, site.atom_id)) {
        .hit => |index| {
            if (preparedNativeTargetFromAutoInitEntry(receiver, object, index, site.atom_id)) |target| return target;
        },
        .miss, .invalidated => {},
    }
    switch (slot.lookupProtoDataResult(object, site.atom_id)) {
        .hit => |hit| {
            if (preparedNativeTargetFromAutoInitEntry(receiver, hit.holder, hit.slot_index, site.atom_id)) |target| return target;
        },
        .miss, .invalidated => {},
    }
    return null;
}

fn preparedNativeTargetFromAutoInitEntry(
    receiver: core.JSValue,
    holder: *core.Object,
    index: usize,
    atom_id: core.Atom,
) ?frame_mod.PreparedNativeCallTarget {
    if (holder.proxyTarget() != null or holder.exotic != null) return null;
    if (index >= holder.shapeProps().len) return null;
    const prop = holder.shapeProps()[index];
    const prop_flags = core.property.Flags.fromBits(prop.flags);
    if (prop_flags.deleted or prop_flags.accessor or prop.atom_id != atom_id) return null;
    return switch (holder.properties[index].slot) {
        .auto_init => |info| {
            const native_ref = core.function.decodeNativeBuiltinId(info.native_builtin_id) orelse return null;
            if (!nativeBuiltinSupportedWithoutFunctionObject(receiver, native_ref, info)) return null;
            return .{ .native_ref = native_ref, .auto_init = info };
        },
        .data, .accessor, .deleted => null,
    };
}

fn installPreparedNativeCallIc(
    function: *const bytecode.Bytecode,
    site: bytecode.function.CallSite,
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    holder: *core.Object,
    index: usize,
) void {
    const object = objectFromValue(receiver) orelse return;
    if (object.proxyTarget() != null or object.exotic != null) return;
    if (holder.proxyTarget() != null or holder.exotic != null) return;
    const slot = function.icSlotForPc(site.prepare_pc) orelse return;
    if (holder == object) {
        _ = slot.installOwnData(&rt.shapes, object, site.atom_id, index);
    } else {
        _ = slot.installProtoData(&rt.shapes, object, holder, site.atom_id, index);
    }
}

fn primitivePrototypeForCall(rt: *core.JSRuntime, global: *core.Object, receiver: core.JSValue) ?*core.Object {
    if (receiver.isString()) return object_ops.constructorPrototypeFromGlobal(rt, global, "String");
    if (receiver.isNumber()) return object_ops.constructorPrototypeFromGlobal(rt, global, "Number");
    if (receiver.isBool()) return object_ops.constructorPrototypeFromGlobal(rt, global, "Boolean");
    if (receiver.isBigInt()) return object_ops.constructorPrototypeFromGlobal(rt, global, "BigInt");
    if (receiver.isSymbol()) return object_ops.constructorPrototypeFromGlobal(rt, global, "Symbol");
    return null;
}

fn nativeBuiltinSupportedWithoutFunctionObject(
    receiver: core.JSValue,
    native_ref: core.function.NativeBuiltinRef,
    info: core.property.AutoInit,
) bool {
    return switch (native_ref.domain) {
        .math => true,
        .date => native_ref.id == @intFromEnum(method_ids.date.StaticMethod.now),
        .number => native_ref.id == @intFromEnum(method_ids.number.StaticMethod.parse_int) or
            native_ref.id == @intFromEnum(method_ids.number.StaticMethod.parse_float),
        .string => native_ref.id == @intFromEnum(method_ids.string.StaticMethod.from_char_code) or
            native_ref.id == @intFromEnum(method_ids.string.PrototypeMethod.substring),
        .regexp => native_ref.id == @intFromEnum(method_ids.regexp.PrototypeMethod.test_) or
            native_ref.id == @intFromEnum(method_ids.regexp.PrototypeMethod.exec),
        .json, .uri => true,
        .collection => collectionNativeSupportedWithoutFunctionObject(native_ref.id, info),
        .array => arrayNativeSupportedWithoutFunctionObject(receiver, native_ref.id),
        else => false,
    };
}

fn arrayNativeSupportedWithoutFunctionObject(receiver: core.JSValue, id: u32) bool {
    _ = receiver;
    return switch (id) {
        @intFromEnum(method_ids.array.PrototypeMethod.push),
        @intFromEnum(method_ids.array.PrototypeMethod.pop),
        => true,
        else => false,
    };
}

fn collectionNativeSupportedWithoutFunctionObject(id: u32, info: core.property.AutoInit) bool {
    if (info.collection_method_owner_class == core.class.invalid_class_id) return false;
    return switch (id) {
        @intFromEnum(method_ids.collection.PrototypeMethod.set),
        @intFromEnum(method_ids.collection.PrototypeMethod.get),
        @intFromEnum(method_ids.collection.PrototypeMethod.has),
        @intFromEnum(method_ids.collection.PrototypeMethod.delete),
        @intFromEnum(method_ids.collection.PrototypeMethod.clear),
        @intFromEnum(method_ids.collection.PrototypeMethod.add),
        @intFromEnum(method_ids.collection.PrototypeMethod.keys),
        @intFromEnum(method_ids.collection.PrototypeMethod.values),
        @intFromEnum(method_ids.collection.PrototypeMethod.entries),
        @intFromEnum(method_ids.collection.PrototypeMethod.get_or_insert),
        @intFromEnum(method_ids.collection.PrototypeMethod.size_getter),
        => true,
        else => false,
    };
}

fn callPreparedNativeTarget(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    target: frame_mod.PreparedNativeCallTarget,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const native_ref = target.native_ref;
    switch (native_ref.domain) {
        // Domains whose record handlers are safe to invoke without a
        // materialized function object: route the prepared (no-func-object)
        // call through the same builtins-owned internal record table the slow
        // record dispatch (`call.zig`) and the VM fast path
        // (`call_runtime.callNativeBuiltinRecordForVm`) use, so exec carries
        // zero compile-time knowledge of these builtins. Math is now uniform
        // with the rest: the retired prepared hybrid called
        // `builtins.math.preparedOpCall` directly to dodge the record table's
        // indirect call, but the QuickJS uniform model (grill 2026-06-13) keeps
        // exactly one dispatch path, so `.math` goes through the table like any
        // other domain — `builtins/math.zig`'s record handler `mathOpCall`
        // already delegates to the same `preparedOpCall`, so the single source
        // of truth is unchanged. The prepared call site has no function object
        // (pass `func_obj = null`) and only the realm `global` (no `globals`
        // slot array, so pass an empty slice; every handler here prefers
        // `host_call.global` and only consults `globals` on the bare-runtime
        // `global == null` fallback, which never triggers on this path). Every
        // id of these domains that the prepared-call gate
        // (`nativeBuiltinSupportedWithoutFunctionObject`) admits is table-backed
        // with `prepared_call_ok = true`, so the table dispatch is
        // authoritative; the `error.TypeError` fall-through mirrors the
        // corrupt-id behavior of the retired per-domain switch.
        .math, .date, .number, .string, .json, .uri => {
            return (try builtin_dispatch.callInternalRecord(ctx, output, global, &.{}, null, receiver, native_ref, args, caller_function, caller_frame)) orelse error.TypeError;
        },
        // RegExp keeps its dedicated branch: the `.regexp` record handler
        // (`builtins.regexp.regexpCall`) requires a materialized function object
        // (`host_call.func_obj orelse return error.TypeError`), which the
        // prepared call site does not have, so it must not go through the table.
        .regexp => switch (native_ref.id) {
            @intFromEnum(method_ids.regexp.PrototypeMethod.test_) => {
                if (try regexp_fastpath.qjsRegExpTestMethod(ctx, output, global, receiver, args, caller_function, caller_frame)) |value| return value;
            },
            @intFromEnum(method_ids.regexp.PrototypeMethod.exec) => {
                if (try regexp_fastpath.qjsRegExpExecMethod(ctx, output, global, receiver, args, caller_function, caller_frame)) |value| return value;
            },
            else => {},
        },
        // Collection keeps a thin dedicated branch only for the AutoInit
        // owner-class gate, which is keyed on the prepared `auto_init` record
        // (not a materialized function object). Past that gate the prepared call
        // routes through the same record table as every other domain: the
        // collection record handler's func-object-free path replicates the
        // dropped-result fast path (`callerResultIsDropped`) and the realm
        // dispatch the retired `methodCallDroppedResult`/`methodCallObjectWithGlobal`
        // pair performed, so exec carries no compile-time knowledge of the builtin.
        .collection => if (try callPreparedCollectionNativeTarget(ctx, output, global, receiver, target, args, caller_function, caller_frame)) |value| return value,
        // Array now joins the uniform path: route the prepared (no-func-object)
        // call through the same builtins-owned record table the slow record
        // dispatch and the VM fast path use, so exec carries zero compile-time
        // knowledge of `push`/`pop`. The prepared-call gate
        // (`arrayNativeSupportedWithoutFunctionObject`) only admits `push`/`pop`,
        // and the `.array` record handler (`builtins.array.arrayCall`) routes
        // exactly those two ids to their func-object-free implementations when
        // `func_obj == null`; every other Array method record returns the
        // corrupt-id `error.TypeError` under null func_obj, which never fires
        // here because the gate blocks it. The prepared site has no function
        // object (pass `func_obj = null`) and only the realm `global` (no
        // `globals` slot array, so pass an empty slice).
        .array => return (try builtin_dispatch.callInternalRecord(ctx, output, global, &.{}, null, receiver, native_ref, args, caller_function, caller_frame)) orelse error.TypeError,
        else => {},
    }
    return error.TypeError;
}

fn callPreparedCollectionNativeTarget(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    target: frame_mod.PreparedNativeCallTarget,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const info = target.auto_init orelse return null;
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (info.collection_method_owner_class != core.class.invalid_class_id and object.class_id != info.collection_method_owner_class) {
        return error.TypeError;
    }
    // Owner class validated from the prepared record; dispatch the body through
    // the collection record table. With no function object and the realm
    // `global`, the handler takes its func-object-free path: it honors the
    // dropped-result fast path (the retired `methodCallDroppedResult`) and
    // otherwise runs `methodCallObjectWithGlobal(ctx, global, object, id, args,
    // &.{})`, exactly as this branch did when it named the builtin directly.
    return (try builtin_dispatch.callInternalRecord(ctx, output, global, &.{}, null, receiver, target.native_ref, args, caller_function, caller_frame)) orelse error.TypeError;
}

fn objectFromValue(value: core.JSValue) ?*core.Object {
    return property_ops.expectObject(value) catch null;
}

fn discardPreparedCallInputs(rt: *core.JSRuntime, stack: *stack_mod.Stack, argc: u16) !void {
    var remaining: usize = @as(usize, argc) + 1;
    while (remaining != 0) : (remaining -= 1) {
        const value = try stack.pop();
        value.free(rt);
    }
}

fn dropUnusedCallResult(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    value: core.JSValue,
) bool {
    if (frame.pc >= function.code.len or function.code[frame.pc] != op.drop) return false;
    frame.pc += 1;
    value.free(ctx.runtime);
    return true;
}

pub fn tailCallMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    allow_inline: bool,
) !TailCallMethodResult {
    const argc = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    // Inline frame-reuse fast path: a tail-positioned method call whose
    // callable is a plain bytecode function reuses the current inline frame
    // instead of recursing, mirroring op.tail_call. The receiver, callable,
    // and args stay on the operand stack (zero-copy) at
    // `[region_base ..][receiver, callable, args...]` until the dispatch loop
    // moves them into the reused frame; `resolveInlineTarget` binds the
    // receiver as the callee's `this` (or the arrow's lexical `this`). Native
    // builtin methods — the common case — are not inline-eligible and fall
    // through to the fast native dispatch below.
    if (allow_inline) {
        const total = @as(usize, argc) + 2;
        if (stack.values.len >= total) {
            const region_base = stack.values.len - total;
            const receiver = stack.values[region_base];
            const method = stack.values[region_base + 1];
            if (inline_calls.resolveInlineTarget(global, receiver, method)) |target| {
                return .{ .tail_inline = .{ .target = target, .region_base = region_base, .argc = argc, .layout = .method } };
            }
        }
    }
    var inline_args: [4]core.JSValue = undefined;
    const args_buf: []core.JSValue = if (argc <= inline_args.len)
        inline_args[0..argc]
    else
        try ctx.runtime.memory.alloc(core.JSValue, argc);
    defer if (argc > inline_args.len) ctx.runtime.memory.free(core.JSValue, args_buf);
    var remaining: usize = argc;
    while (remaining > 0) {
        remaining -= 1;
        args_buf[remaining] = try stack.pop();
    }
    defer for (args_buf) |arg| arg.free(ctx.runtime);
    const func = try stack.pop();
    defer func.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    const fast_result = fastNativeMethodCall(ctx, output, global, obj, func, args_buf, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .handled;
        return err;
    };
    if (fast_result) |value| {
        return .{ .return_value = value };
    }
    const maybe_array_result = collection_vm.qjsArrayMethodFastCall(ctx, output, global, obj, func, args_buf, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .handled;
        return err;
    };
    const result = if (maybe_array_result) |array_result|
        array_result
    else
        call_runtime.callValueOrBytecode(ctx, output, global, obj, func, args_buf, function, frame) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .handled;
            return err;
        };
    return .{ .return_value = result };
}

fn fastNativeMethodCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    // QuickJS uniform dispatch: the `call_method` / `call_prepared` opcode hot
    // path routes through the same builtins-owned internal record table the slow
    // record dispatch (`call.zig:callNativeFunctionRecord`) and the plain-call
    // VM fast path (`call_runtime.callNativeBuiltinRecordForVm`) use, so exec
    // carries zero compile-time knowledge of the migrated builtins. The retired
    // per-domain hot subset (math min/max primitives, the URI string fast path,
    // Number.parse{Int,Float}, String.fromCharCode / substring primitive, the
    // Array prototype hub, the collection / regexp / JSON record glue) is gone:
    // every one of those domains is table-backed, and the table handler is the
    // complete implementation, so a table HIT returns the final value here.
    //
    // This call site holds the materialized function object (pass non-null
    // `func_obj = function_object`). Resolve the realm global from the function
    // object (`objectRealmGlobal`, falling back to the caller `global`) exactly
    // as the plain-call VM fast path does before
    // `callNativeBuiltinRecordForVm` — a cross-realm method call
    // (`other.Object.keys(...)`) must create its result and throw its errors in
    // the callee's realm, not the caller's. The pre-table per-domain switch
    // never routed the realm-sensitive `.object` domain here (it fell through to
    // the realm-correct generic dispatch), so this resolution preserves that
    // behavior under the unified path. No `globals` slot array exists at this
    // site, so pass an empty slice; migrated handlers prefer `host_call.global`
    // and only consult `globals` on the bare-runtime `global == null` fallback,
    // which never triggers here.
    //
    // A table MISS returns null so the caller falls through to the array
    // fast-array storage fallback (`qjsArrayMethodFastCall`, which keeps the
    // name-based TypedArray slice/subarray path that has no native-builtin id)
    // and then the generic value/bytecode dispatch — the same fall-through the
    // non-table domains (`.atomics` / `.performance` / `.host` / `.promise`)
    // already relied on.
    const function_object = property_ops.expectObject(func) catch return null;
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*) orelse return null;
    const function_global = object_ops.objectRealmGlobal(function_object) orelse global;
    return builtin_dispatch.callInternalRecord(ctx, output, function_global, &.{}, function_object, this_value, native_ref, args, caller_function, caller_frame);
}

pub fn apply(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const is_new = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    const array_value = try stack.pop();
    defer array_value.free(ctx.runtime);
    const this_value = try stack.pop();
    defer this_value.free(ctx.runtime);
    const func = try stack.pop();
    defer func.free(ctx.runtime);
    const apply_args = try collection_vm.argsFromArray(ctx.runtime, array_value);
    defer call_runtime.freeArgs(ctx.runtime, apply_args);
    const allow_class_constructor_call = class_init_ops.isCurrentSuperConstructor(ctx, frame, func);
    const arrow_super_this = if (allow_class_constructor_call and !frame.function.flags.is_derived_class_constructor)
        class_init_ops.currentArrowLexicalSuperThis(ctx.runtime, frame)
    else
        null;
    defer if (arrow_super_this) |value| value.free(ctx.runtime);
    const arrow_constructor_this = if (allow_class_constructor_call and !frame.function.flags.is_derived_class_constructor)
        class_init_ops.currentArrowConstructorThis(ctx.runtime, frame)
    else
        null;
    defer if (arrow_constructor_this) |value| value.free(ctx.runtime);
    const is_arrow_super_constructor = allow_class_constructor_call and arrow_super_this != null;
    const effective_this = if (allow_class_constructor_call and frame.function.flags.is_derived_class_constructor)
        frame.constructor_this_value
    else if (arrow_constructor_this) |value|
        value
    else if (arrow_super_this) |value|
        value
    else
        this_value;
    const result = if (is_new != 0) blk: {
        if (allow_class_constructor_call) {
            break :blk call_runtime.constructValueOrBytecodeWithNewTarget(ctx, output, global, func, apply_args, function, frame, this_value) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
        }
        break :blk call_runtime.constructValueOrBytecodeWithNewTarget(ctx, output, global, func, apply_args, function, frame, func) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
    } else call_runtime.callValueOrBytecodeClassMode(ctx, output, global, effective_this, func, apply_args, function, frame, allow_class_constructor_call) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    if (is_new != 0) {
        stack.pushOwned(result) catch |err| {
            result.free(ctx.runtime);
            return err;
        };
        return .done;
    }
    defer result.free(ctx.runtime);
    if (allow_class_constructor_call and frame.function.flags.is_derived_class_constructor) {
        if (slot_ops.varRefSlotIsUninitialized(frame.this_value)) {
            const next_this = if (result.isObject()) result else frame.constructor_this_value;
            try slot_ops.setSlotValue(ctx, &frame.this_value, next_this.dup());
            class_init_ops.initializeCurrentConstructorClassInstanceElements(ctx, output, global, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
        } else {
            if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
            return error.ReferenceError;
        }
        try collection_vm.pushSlotValue(stack, frame.this_value);
        return .done;
    } else if (is_arrow_super_constructor) {
        if (arrow_super_this) |this_value_for_arrow| {
            if (!this_value_for_arrow.isUninitialized()) {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
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
        try stack.push(next_this);
        return .done;
    }
    try stack.push(result);
    return .done;
}

pub fn constructor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const argc = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    var inline_args: [4]core.JSValue = undefined;
    const args_buf: []core.JSValue = if (argc <= inline_args.len)
        inline_args[0..argc]
    else
        try ctx.runtime.memory.alloc(core.JSValue, argc);
    defer if (argc > inline_args.len) ctx.runtime.memory.free(core.JSValue, args_buf);
    var remaining: usize = argc;
    while (remaining > 0) {
        remaining -= 1;
        args_buf[remaining] = try stack.pop();
    }
    defer for (args_buf) |arg| arg.free(ctx.runtime);
    const top = try stack.pop();
    const has_explicit_new_target = stack.len() != 0;
    const new_target = top;
    const func = if (has_explicit_new_target)
        stack.pop() catch |err| {
            top.free(ctx.runtime);
            return err;
        }
    else
        top;
    defer if (has_explicit_new_target) new_target.free(ctx.runtime);
    defer func.free(ctx.runtime);
    const fused_typed_array_result = fusion_stats.counted(.tryFuseTypedArrayFromArrayBufferConstructorSequence, collection_vm.tryFuseTypedArrayFromArrayBufferConstructorSequence(
        ctx,
        stack,
        function,
        frame,
        func,
        new_target,
        args_buf,
    )) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    if (fused_typed_array_result) |result| {
        errdefer result.free(ctx.runtime);
        try stack.pushOwned(result);
        return .done;
    }
    const result = call_runtime.constructValueOrBytecodeWithNewTarget(ctx, output, global, func, args_buf, function, frame, new_target) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    errdefer result.free(ctx.runtime);
    if (frame.function.flags.is_derived_class_constructor and class_init_ops.isCurrentSuperConstructor(ctx, frame, func)) {
        if (object_ops.functionObjectFromValue(frame.current_function)) |function_object| {
            if (function_object.functionHomeObjectSlot().*) |home_object| {
                const instance_object = try property_ops.expectObject(result);
                class_init_ops.initializeClassPrivateMethods(ctx.runtime, instance_object, home_object) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
            }
        }
    }
    try stack.pushOwned(result);
    return .done;
}

pub fn checkCtor(frame: *frame_mod.Frame) !void {
    if (frame.new_target.isUndefined()) return error.TypeError;
}

pub fn checkCtorVm(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
) !Step {
    checkCtor(frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn checkCtorReturn(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    const value = stack.peekBorrowed() orelse return error.StackUnderflow;
    if (value.isObject()) {
        try stack.pushOwned(core.JSValue.boolean(false));
    } else if (value.isUndefined()) {
        try stack.pushOwned(core.JSValue.boolean(true));
    } else {
        return error.TypeError;
    }
}

pub fn checkCtorReturnVm(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
) !Step {
    checkCtorReturn(ctx, stack) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn initCtor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !void {
    if (frame.new_target.isUndefined()) return error.TypeError;
    const function_object = try property_ops.expectObject(frame.current_function);
    const super = function_object.functionSuperConstructor() orelse return error.TypeError;
    const args = if (frame.original_args.len != 0)
        frame.original_args[0..@min(frame.actual_arg_count, frame.original_args.len)]
    else
        frame.args[0..@min(frame.actual_arg_count, frame.args.len)];
    const result = try call_runtime.constructValueOrBytecodeWithNewTarget(ctx, output, global, super, args, function, frame, frame.new_target);
    errdefer result.free(ctx.runtime);
    if (function_object.functionHomeObjectSlot().*) |home_object| {
        const instance_object = try property_ops.expectObject(result);
        try class_init_ops.initializeClassPrivateMethods(ctx.runtime, instance_object, home_object);
    }
    try stack.pushOwned(result);
}

pub fn initCtorVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    initCtor(ctx, output, global, stack, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

fn maxNativeJsCallDepth(ctx: *const core.JSContext) usize {
    return @max(@as(usize, 16), ctx.stack_limit / 16384);
}

fn maxLogicalJsCallDepth(ctx: *const core.JSContext) usize {
    return ctx.stack_limit;
}

fn maxJsCallDepth(ctx: *const core.JSContext) usize {
    return maxNativeJsCallDepth(ctx);
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
