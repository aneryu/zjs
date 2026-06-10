const std = @import("std");

const bytecode = @import("../bytecode/root.zig");
const builtins = @import("../builtins/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const collection_vm = @import("array_ops.zig");
const property_ops = @import("property_ops.zig");
const shared_vm = @import("shared.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const op = bytecode.opcode.op;

pub const Step = enum { done, continue_loop };

pub const TailCallMethodResult = union(enum) {
    handled,
    return_value: core.JSValue,
};

pub const TailCallResult = TailCallMethodResult;

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
    if (ctx.call_depth >= maxJsCallDepth(ctx)) {
        _ = shared_vm.throwRangeErrorMessage(ctx, global, "Maximum call stack size exceeded") catch |err| return err;
        return error.RangeError;
    }
    ctx.call_depth += 1;
    return .{ .ctx = ctx };
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
        const this_cell = try shared_vm.ensureVarRefCell(ctx, &frame.this_value);
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

    const locals = if (use_inline_storage and function.var_count <= frame.inline_locals.len)
        frame.inline_locals[0..function.var_count]
    else blk: {
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
        shared_vm.initializeEvalFrameLocals(ctx, function, frame, eval_local_names, eval_local_slots);
    }
    try linkDerivedConstructorThisLocal(ctx, function, frame);
    storage_transferred = true;
}

pub fn initFrameVarRefs(ctx: *core.JSContext, global: *core.Object, function: *const bytecode.Bytecode, frame: *frame_mod.Frame, var_refs: []const core.JSValue, use_inline_storage: bool) !void {
    if (var_refs.len > 0) {
        const owned_refs = if (use_inline_storage and var_refs.len <= frame.inline_var_refs.len)
            frame.inline_var_refs[0..var_refs.len]
        else blk: {
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
        frame.var_refs_on_heap = true;
        break :blk try ctx.runtime.memory.alloc(core.JSValue, function.var_ref_names.len);
    };
    errdefer if (frame.var_refs_on_heap) ctx.runtime.memory.free(core.JSValue, owned_refs);
    var initialized: usize = 0;
    errdefer {
        for (owned_refs[0..initialized]) |*val| val.free(ctx.runtime);
    }
    for (function.var_ref_names, 0..) |var_name, idx| {
        const val = shared_vm.globalLexicalValue(ctx, var_name) orelse global.getProperty(var_name);
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
    comptime handleCatchableRuntimeError: anytype,
    comptime pushFunctionClosure: anytype,
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
    if (try tryFuseImmediateSimpleArrayMapClosure(ctx, output, global, stack, function, frame, catch_target, index, handleCatchableRuntimeError)) |step| return step;
    try pushFunctionClosure(ctx, frame, stack, function, global, index, opc, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs);
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
    comptime handleCatchableRuntimeError: anytype,
) !?Step {
    if (frame.pc + 3 > function.code.len) return null;
    if (function.code[frame.pc] != op.call_method) return null;
    if (readInt(u16, function.code[frame.pc + 1 ..][0..2]) != 1) return null;
    if (stack.values.len < 2) return null;

    const callback = function.constants.get(index) orelse return error.InvalidBytecode;
    defer callback.free(ctx.runtime);
    const callback_bytecode = shared_vm.functionBytecodeFromValue(callback) orelse return null;
    if (callback_bytecode.simple_numeric_kind != .arg0_const) return null;

    const receiver = stack.values[stack.values.len - 2];
    const method = stack.values[stack.values.len - 1];
    const method_object = shared_vm.callableObjectFromValue(method) orelse return null;
    const native_ref = core.function.decodeNativeBuiltinId(method_object.nativeFunctionIdSlot().*) orelse return null;
    const map_id = @intFromEnum(builtins.array.PrototypeMethod.map);
    if (native_ref.domain != .array or native_ref.id != map_id) return null;

    const args = [_]core.JSValue{callback};
    if (try shared_vm.qjsArrayMapSimpleNumericArg0DefaultSpeciesFastCall(ctx.runtime, global, receiver, callback)) |fast_value| {
        errdefer fast_value.free(ctx.runtime);
        const method_owned = try stack.pop();
        method_owned.free(ctx.runtime);
        const receiver_owned = try stack.pop();
        receiver_owned.free(ctx.runtime);
        try stack.pushOwned(fast_value);
        frame.pc += 3;
        return .done;
    }
    const result = shared_vm.qjsArrayPrototypeNativeRecord(ctx, output, global, receiver, method_object, map_id, args[0..], function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
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
    const object = shared_vm.functionObjectFromValue(func) orelse return false;
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
    comptime execCall: anytype,
) !Step {
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
    if (try tryFastMathCall(ctx, stack, argc)) return .done;
    if (try tryFastSimpleStringCall(ctx, stack, argc)) return .done;
    if (try tryFastSimpleNumericCall(ctx, stack, argc)) return .done;
    return switch (try execCall(ctx, stack, function, frame, catch_target, argc, output, global)) {
        .done => .done,
        .continue_loop => .continue_loop,
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
        const fb = shared_vm.functionBytecodeFromValue(func) orelse return null;
        return if (fb.simple_string_kind == .none) null else fb.simple_string_kind;
    }
    const object = shared_vm.functionObjectFromValue(func) orelse return null;
    const function_value = object.functionBytecodeSlot().* orelse return null;
    const fb = shared_vm.functionBytecodeFromValue(function_value) orelse return null;
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
        const fb = shared_vm.functionBytecodeFromValue(func) orelse return null;
        return simpleNumericCallableFromBytecode(fb, null, null);
    }
    const object = shared_vm.functionObjectFromValue(func) orelse return null;
    const function_value = object.functionBytecodeSlot().* orelse return null;
    const fb = shared_vm.functionBytecodeFromValue(function_value) orelse return null;
    const captures = object.functionCapturesSlot().*;
    const capture0_slot = if (captures.len != 0) captures[0] else null;
    const capture0 = if (capture0_slot) |slot| shared_vm.slotValueBorrow(slot) else null;
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
    const cell = shared_vm.varRefCellFromValue(capture0_slot) orelse return error.NotSimpleNumericCall;
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

fn primitiveMathNumber(value: core.JSValue) ?f64 {
    if (value.tag == core.Tag.int) return @floatFromInt(value.asInt32().?);
    if (value.tag == core.Tag.float64) return value.asFloat64().?;
    if (value.asBool()) |bool_value| return if (bool_value) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isUndefined()) return std.math.nan(f64);
    return null;
}

pub fn tailCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime execCall: anytype,
) !TailCallResult {
    const argc = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    switch (try execCall(ctx, stack, function, frame, catch_target, argc, output, global)) {
        .done => {},
        .continue_loop => return .handled,
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
    comptime getValueProperty: anytype,
    comptime closeStackTopForOfIteratorForPendingError: anytype,
    comptime handleCatchableRuntimeError: anytype,
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
    const target = preparePropertyCallTarget(ctx, output, global, receiver, site, function, frame, getValueProperty) catch |err| {
        try closeStackTopForOfIteratorForPendingError(ctx, output, global, stack, frame);
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    switch (target) {
        .native => |native| {
            if (try tryCallPreparedNativeNoArg(ctx, output, global, stack, function, frame, catch_target, receiver, native, handleCatchableRuntimeError)) |step| {
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
    comptime handleCatchableRuntimeError: anytype,
) !?Step {
    if (frame.pc + 3 > function.code.len or function.code[frame.pc] != op.call_prepared) return null;
    const argc = readInt(u16, function.code[frame.pc + 1 ..][0..2]);
    if (argc != 0) return null;
    frame.pc += 3;

    const args: []const core.JSValue = &.{};
    const result = callPreparedNativeTarget(ctx, output, global, receiver, native, args, function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
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
    comptime qjsArrayMethodFastCall: anytype,
    comptime callValueOrBytecodeClassMode: anytype,
    comptime isCurrentSuperConstructor: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
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
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
            discardPreparedCallInputs(ctx.runtime, stack, argc) catch {};
            return err;
        },
        .value => |func| blk: {
            rooted_func = func;
            rooted_func_active = true;
            const fast_result = fastNativeMethodCall(ctx, output, global, receiver, rooted_func, args, function, frame) catch |err| {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                discardPreparedCallInputs(ctx.runtime, stack, argc) catch {};
                return err;
            };
            if (fast_result) |value| break :blk value;
            const maybe_array_result = qjsArrayMethodFastCall(ctx, output, global, receiver, rooted_func, args, function, frame) catch |err| {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                discardPreparedCallInputs(ctx.runtime, stack, argc) catch {};
                return err;
            };
            if (maybe_array_result) |value| break :blk value;
            break :blk callValueOrBytecodeClassMode(ctx, output, global, receiver, rooted_func, args, function, frame, isCurrentSuperConstructor(ctx, frame, rooted_func)) catch |err| {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
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
    comptime qjsArrayMethodFastCall: anytype,
    comptime callValueOrBytecodeClassMode: anytype,
    comptime isCurrentSuperConstructor: anytype,
    comptime handleCatchableRuntimeError: anytype,
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
    const func = try stack.pop();
    defer func.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    const fast_result = fastNativeMethodCall(ctx, output, global, obj, func, args_buf, function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    if (fast_result) |value| {
        if (dropUnusedCallResult(ctx, function, frame, value)) return .done;
        errdefer value.free(ctx.runtime);
        try stack.pushOwned(value);
        return .done;
    }
    const maybe_array_result = qjsArrayMethodFastCall(ctx, output, global, obj, func, args_buf, function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    const result = if (maybe_array_result) |array_result|
        array_result
    else
        callValueOrBytecodeClassMode(ctx, output, global, obj, func, args_buf, function, frame, isCurrentSuperConstructor(ctx, frame, func)) catch |err| {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
    if (dropUnusedCallResult(ctx, function, frame, result)) return .done;
    errdefer result.free(ctx.runtime);
    try stack.pushOwned(result);
    return .done;
}

fn preparePropertyCallTarget(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    site: bytecode.function.CallSite,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime getValueProperty: anytype,
) !PreparedPropertyTarget {
    if (cachedPreparedNativeCallTarget(function, site, receiver)) |native| {
        return .{ .native = native };
    }
    if (autoInitNativeTargetForReceiver(ctx.runtime, global, receiver, site.atom_id)) |lookup| {
        installPreparedNativeCallIc(function, site, ctx.runtime, receiver, lookup.holder, lookup.index);
        return .{ .native = lookup.target };
    }
    const value = try getValueProperty(ctx, output, global, receiver, site.atom_id, function, frame);
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
    if (index >= holder.properties.len) return null;
    const entry = holder.properties[index];
    if (entry.flags.deleted or entry.flags.accessor or entry.atom_id != atom_id) return null;
    return switch (entry.slot) {
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
    if (receiver.isString()) return shared_vm.constructorPrototypeFromGlobal(rt, global, "String");
    if (receiver.isNumber()) return shared_vm.constructorPrototypeFromGlobal(rt, global, "Number");
    if (receiver.isBool()) return shared_vm.constructorPrototypeFromGlobal(rt, global, "Boolean");
    if (receiver.isBigInt()) return shared_vm.constructorPrototypeFromGlobal(rt, global, "BigInt");
    if (receiver.isSymbol()) return shared_vm.constructorPrototypeFromGlobal(rt, global, "Symbol");
    return null;
}

fn nativeBuiltinSupportedWithoutFunctionObject(
    receiver: core.JSValue,
    native_ref: core.function.NativeBuiltinRef,
    info: core.property.AutoInit,
) bool {
    return switch (native_ref.domain) {
        .math => true,
        .date => native_ref.id == @intFromEnum(builtins.date.StaticMethod.now),
        .number => native_ref.id == @intFromEnum(builtins.number.StaticMethod.parse_int) or
            native_ref.id == @intFromEnum(builtins.number.StaticMethod.parse_float),
        .string => native_ref.id == @intFromEnum(builtins.string.StaticMethod.from_char_code) or
            native_ref.id == @intFromEnum(builtins.string.PrototypeMethod.substring),
        .regexp => native_ref.id == @intFromEnum(builtins.regexp.PrototypeMethod.test_) or
            native_ref.id == @intFromEnum(builtins.regexp.PrototypeMethod.exec),
        .json, .uri => true,
        .collection => collectionNativeSupportedWithoutFunctionObject(native_ref.id, info),
        .array => arrayNativeSupportedWithoutFunctionObject(receiver, native_ref.id),
        else => false,
    };
}

fn arrayNativeSupportedWithoutFunctionObject(receiver: core.JSValue, id: u32) bool {
    _ = receiver;
    return switch (id) {
        @intFromEnum(builtins.array.PrototypeMethod.push),
        @intFromEnum(builtins.array.PrototypeMethod.pop),
        => true,
        else => false,
    };
}

fn collectionNativeSupportedWithoutFunctionObject(id: u32, info: core.property.AutoInit) bool {
    if (info.collection_method_owner_class == core.class.invalid_class_id) return false;
    return switch (id) {
        @intFromEnum(builtins.collection.PrototypeMethod.set),
        @intFromEnum(builtins.collection.PrototypeMethod.get),
        @intFromEnum(builtins.collection.PrototypeMethod.has),
        @intFromEnum(builtins.collection.PrototypeMethod.delete),
        @intFromEnum(builtins.collection.PrototypeMethod.clear),
        @intFromEnum(builtins.collection.PrototypeMethod.add),
        @intFromEnum(builtins.collection.PrototypeMethod.keys),
        @intFromEnum(builtins.collection.PrototypeMethod.values),
        @intFromEnum(builtins.collection.PrototypeMethod.entries),
        @intFromEnum(builtins.collection.PrototypeMethod.get_or_insert),
        @intFromEnum(builtins.collection.PrototypeMethod.size_getter),
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
        .math => {
            if (native_ref.id == 37) return shared_vm.qjsMathSumPrecise(ctx, output, global, args, caller_function, caller_frame);
            return shared_vm.qjsMathCall(ctx, output, global, native_ref.id, args);
        },
        .date => if (native_ref.id == @intFromEnum(builtins.date.StaticMethod.now)) {
            return builtins.date.staticCall(ctx.runtime, native_ref.id, args);
        },
        .number => switch (native_ref.id) {
            @intFromEnum(builtins.number.StaticMethod.parse_int) => return shared_vm.qjsGlobalParseInt(ctx, output, global, args, caller_function, caller_frame),
            @intFromEnum(builtins.number.StaticMethod.parse_float) => return shared_vm.qjsGlobalParseFloat(ctx, output, global, args, caller_function, caller_frame),
            else => {},
        },
        .string => switch (native_ref.id) {
            @intFromEnum(builtins.string.StaticMethod.from_char_code) => return shared_vm.qjsStringFromCharCode(ctx, output, global, args),
            @intFromEnum(builtins.string.PrototypeMethod.substring) => return shared_vm.qjsStringPrototypeMethod(ctx, output, global, receiver, 1, args, caller_function, caller_frame),
            else => {},
        },
        .regexp => switch (native_ref.id) {
            @intFromEnum(builtins.regexp.PrototypeMethod.test_) => {
                if (try shared_vm.qjsRegExpTestMethod(ctx, output, global, receiver, args, caller_function, caller_frame)) |value| return value;
            },
            @intFromEnum(builtins.regexp.PrototypeMethod.exec) => {
                if (try shared_vm.qjsRegExpExecMethod(ctx, output, global, receiver, args, caller_function, caller_frame)) |value| return value;
            },
            else => {},
        },
        .json => return shared_vm.qjsJsonCallForNativeRecord(ctx, output, global, native_ref.id, args, caller_function, caller_frame),
        .uri => return shared_vm.qjsUriCallForNativeRecord(ctx, output, global, native_ref.id, args, caller_function, caller_frame),
        .collection => if (try callPreparedCollectionNativeTarget(ctx, global, receiver, target, args, caller_function, caller_frame)) |value| return value,
        .array => if (try collection_vm.qjsArrayPreparedNativeCall(ctx, output, global, receiver, native_ref.id, args, caller_function, caller_frame)) |value| return value,
        else => {},
    }
    return error.TypeError;
}

fn callPreparedCollectionNativeTarget(
    ctx: *core.JSContext,
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
    if (preparedCallResultIsDropped(caller_function, caller_frame)) {
        const handled = try builtins.collection.methodCallDroppedResult(ctx.runtime, object, target.native_ref.id, args);
        if (handled) return core.JSValue.undefinedValue();
    }
    return try builtins.collection.methodCallObjectWithGlobal(ctx, global, object, target.native_ref.id, args, &.{});
}

fn preparedCallResultIsDropped(caller_function: ?*const bytecode.Bytecode, caller_frame: ?*frame_mod.Frame) bool {
    const function = caller_function orelse return false;
    const frame = caller_frame orelse return false;
    return frame.pc < function.code.len and function.code[frame.pc] == op.drop;
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
    comptime qjsArrayMethodFastCall: anytype,
    comptime callValueOrBytecode: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !TailCallMethodResult {
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
    const func = try stack.pop();
    defer func.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    const fast_result = fastNativeMethodCall(ctx, output, global, obj, func, args_buf, function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .handled;
        return err;
    };
    if (fast_result) |value| {
        return .{ .return_value = value };
    }
    const maybe_array_result = qjsArrayMethodFastCall(ctx, output, global, obj, func, args_buf, function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .handled;
        return err;
    };
    const result = if (maybe_array_result) |array_result|
        array_result
    else
        callValueOrBytecode(ctx, output, global, obj, func, args_buf, function, frame) catch |err| {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .handled;
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
    const function_object = property_ops.expectObject(func) catch return null;
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*) orelse return null;
    switch (native_ref.domain) {
        .math => switch (native_ref.id) {
            7 => if (mathMinMaxPrimitive(args, false)) |val| return val,
            8 => if (mathMinMaxPrimitive(args, true)) |val| return val,
            else => {},
        },
        .uri => {
            if (args.len >= 1 and args[0].isString()) {
                return builtins.uri.call(ctx.runtime, native_ref.id, args[0]) catch |err| switch (err) {
                    error.TypeError, error.URIError => err,
                    else => err,
                };
            }
        },
        .number => switch (native_ref.id) {
            @intFromEnum(builtins.number.StaticMethod.parse_int) => return @as(?core.JSValue, try shared_vm.qjsGlobalParseInt(ctx, output, global, args, caller_function, caller_frame)),
            @intFromEnum(builtins.number.StaticMethod.parse_float) => return @as(?core.JSValue, try shared_vm.qjsGlobalParseFloat(ctx, output, global, args, caller_function, caller_frame)),
            else => {},
        },
        .string => switch (native_ref.id) {
            @intFromEnum(builtins.string.StaticMethod.from_char_code) => {
                return @as(?core.JSValue, try shared_vm.qjsStringFromCharCode(ctx, output, global, args));
            },
            @intFromEnum(builtins.string.PrototypeMethod.substring) => {
                if (try fastStringSubstringPrimitive(ctx.runtime, this_value, args)) |value| return value;
            },
            else => {},
        },
        .date => switch (native_ref.id) {
            @intFromEnum(builtins.date.StaticMethod.now) => return @as(?core.JSValue, try builtins.date.staticCall(ctx.runtime, native_ref.id, &.{})),
            else => {},
        },
        .array => {
            if (try shared_vm.qjsArrayPrototypeNativeRecord(ctx, output, global, this_value, function_object, native_ref.id, args, caller_function, caller_frame)) |value| return value;
        },
        .regexp => switch (native_ref.id) {
            @intFromEnum(builtins.regexp.PrototypeMethod.test_) => {
                if (try shared_vm.qjsRegExpTestMethod(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
            },
            @intFromEnum(builtins.regexp.PrototypeMethod.exec) => {
                if (try shared_vm.qjsRegExpExecMethod(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
            },
            else => {},
        },
        .collection => {
            if (try collection_vm.qjsCollectionNativeRecord(ctx, output, global, this_value, function_object, native_ref.id, args, caller_function, caller_frame)) |value| return value;
        },
        .json => return @as(?core.JSValue, try shared_vm.qjsJsonCallForNativeRecord(ctx, output, global, native_ref.id, args, caller_function, caller_frame)),
        else => {},
    }
    return null;
}

fn fastStringSubstringPrimitive(
    rt: *core.JSRuntime,
    this_value: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    if (!this_value.isString() or args.len > 2) return null;
    const header = this_value.refHeader() orelse return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    const len_i64: i64 = @intCast(string_value.len());

    const start_raw: i64 = if (args.len >= 1 and !args[0].isUndefined())
        args[0].asInt32() orelse return null
    else
        0;
    const end_raw: i64 = if (args.len >= 2 and !args[1].isUndefined())
        args[1].asInt32() orelse return null
    else
        len_i64;

    const start: usize = @intCast(@max(@as(i64, 0), @min(start_raw, len_i64)));
    const end: usize = @intCast(@max(@as(i64, 0), @min(end_raw, len_i64)));
    const lo = @min(start, end);
    const hi = @max(start, end);
    if (lo == 0 and hi == string_value.len()) return this_value.dup();

    const out = try core.string.String.createSlice(rt, string_value, lo, hi - lo);
    return out.value();
}

fn mathMinMaxPrimitive(args: []const core.JSValue, is_max: bool) ?core.JSValue {
    if (args.len == 0) return core.JSValue.float64(if (is_max) -std.math.inf(f64) else std.math.inf(f64));
    var result = if (is_max) -std.math.inf(f64) else std.math.inf(f64);
    for (args) |arg| {
        const number = primitiveMathNumber(arg) orelse return null;
        if (!std.math.isNan(result)) {
            result = if (std.math.isNan(number))
                number
            else if (is_max)
                mathFmax(result, number)
            else
                mathFmin(result, number);
        }
    }
    return value_ops.numberToValue(result);
}

fn mathFmin(a: f64, b: f64) f64 {
    if (a == 0 and b == 0) return @bitCast(@as(u64, @bitCast(a)) | @as(u64, @bitCast(b)));
    return if (a < b) a else b;
}

fn mathFmax(a: f64, b: f64) f64 {
    if (a == 0 and b == 0) return @bitCast(@as(u64, @bitCast(a)) & @as(u64, @bitCast(b)));
    return if (a < b) b else a;
}

pub fn apply(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime argsFromArray: anytype,
    comptime freeArgs: anytype,
    comptime isCurrentSuperConstructor: anytype,
    comptime currentArrowLexicalSuperThis: anytype,
    comptime currentArrowConstructorThis: anytype,
    comptime constructValueOrBytecodeWithNewTarget: anytype,
    comptime callValueOrBytecodeClassMode: anytype,
    comptime varRefSlotIsUninitialized: anytype,
    comptime setSlotValue: anytype,
    comptime pushSlotValue: anytype,
    comptime initializeCurrentConstructorClassInstanceElements: anytype,
    comptime setCurrentArrowLexicalThis: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    const is_new = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    const array_value = try stack.pop();
    defer array_value.free(ctx.runtime);
    const this_value = try stack.pop();
    defer this_value.free(ctx.runtime);
    const func = try stack.pop();
    defer func.free(ctx.runtime);
    const apply_args = try argsFromArray(ctx.runtime, array_value);
    defer freeArgs(ctx.runtime, apply_args);
    const allow_class_constructor_call = isCurrentSuperConstructor(ctx, frame, func);
    const arrow_super_this = if (allow_class_constructor_call and !frame.function.flags.is_derived_class_constructor)
        currentArrowLexicalSuperThis(ctx.runtime, frame)
    else
        null;
    defer if (arrow_super_this) |value| value.free(ctx.runtime);
    const arrow_constructor_this = if (allow_class_constructor_call and !frame.function.flags.is_derived_class_constructor)
        currentArrowConstructorThis(ctx.runtime, frame)
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
            break :blk constructValueOrBytecodeWithNewTarget(ctx, output, global, func, apply_args, function, frame, this_value) catch |err| {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
        }
        break :blk constructValueOrBytecodeWithNewTarget(ctx, output, global, func, apply_args, function, frame, func) catch |err| {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
    } else callValueOrBytecodeClassMode(ctx, output, global, effective_this, func, apply_args, function, frame, allow_class_constructor_call) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
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
        if (varRefSlotIsUninitialized(frame.this_value)) {
            const next_this = if (result.isObject()) result else frame.constructor_this_value;
            try setSlotValue(ctx, &frame.this_value, next_this.dup());
            initializeCurrentConstructorClassInstanceElements(ctx, output, global, function, frame) catch |err| {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
        } else {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
            return error.ReferenceError;
        }
        try pushSlotValue(stack, frame.this_value);
        return .done;
    } else if (is_arrow_super_constructor) {
        if (arrow_super_this) |this_value_for_arrow| {
            if (!this_value_for_arrow.isUninitialized()) {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                return error.ReferenceError;
            }
        }
        const next_this = if (result.isObject())
            result
        else if (arrow_constructor_this) |value|
            value
        else
            result;
        try setCurrentArrowLexicalThis(ctx, frame, next_this.dup());
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
    comptime popDuplicateConstructorTarget: anytype,
    comptime constructValueOrBytecode: anytype,
    comptime handleCatchableRuntimeError: anytype,
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
    const new_target = if (has_explicit_new_target) top else top.dup();
    const func = if (has_explicit_new_target)
        stack.pop() catch |err| {
            top.free(ctx.runtime);
            return err;
        }
    else
        top;
    defer new_target.free(ctx.runtime);
    defer func.free(ctx.runtime);
    _ = popDuplicateConstructorTarget;
    const fused_typed_array_result = shared_vm.tryFuseTypedArrayFromArrayBufferConstructorSequence(
        ctx,
        output,
        global,
        stack,
        function,
        frame,
        func,
        new_target,
        args_buf,
    ) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    if (fused_typed_array_result) |result| {
        errdefer result.free(ctx.runtime);
        try stack.pushOwned(result);
        return .done;
    }
    const result = constructValueOrBytecode(ctx, output, global, func, args_buf, function, frame, new_target) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    errdefer result.free(ctx.runtime);
    if (frame.function.flags.is_derived_class_constructor and shared_vm.isCurrentSuperConstructor(ctx, frame, func)) {
        if (shared_vm.functionObjectFromValue(frame.current_function)) |function_object| {
            if (function_object.functionHomeObjectSlot().*) |home_object| {
                const instance_object = try property_ops.expectObject(result);
                shared_vm.initializeClassPrivateMethods(ctx.runtime, instance_object, home_object) catch |err| {
                    if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
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
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    checkCtor(frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
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
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    checkCtorReturn(ctx, stack) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
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
    comptime constructValueOrBytecode: anytype,
) !void {
    if (frame.new_target.isUndefined()) return error.TypeError;
    const function_object = try property_ops.expectObject(frame.current_function);
    const super = function_object.functionSuperConstructor() orelse return error.TypeError;
    const args = if (frame.original_args.len != 0)
        frame.original_args[0..@min(frame.actual_arg_count, frame.original_args.len)]
    else
        frame.args[0..@min(frame.actual_arg_count, frame.args.len)];
    const result = try constructValueOrBytecode(ctx, output, global, super, args, function, frame, frame.new_target);
    errdefer result.free(ctx.runtime);
    if (function_object.functionHomeObjectSlot().*) |home_object| {
        const instance_object = try property_ops.expectObject(result);
        try shared_vm.initializeClassPrivateMethods(ctx.runtime, instance_object, home_object);
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
    comptime constructValueOrBytecode: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    initCtor(ctx, output, global, stack, function, frame, constructValueOrBytecode) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

fn maxJsCallDepth(ctx: *const core.JSContext) usize {
    return @max(@as(usize, 16), ctx.stack_limit / 16384);
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
