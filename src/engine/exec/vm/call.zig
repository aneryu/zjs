const std = @import("std");

const bytecode = @import("../../bytecode/root.zig");
const builtins = @import("../../builtins/root.zig");
const core = @import("../../core/root.zig");
const frame_mod = @import("../frame.zig");
const collection_vm = @import("collection.zig");
const property_ops = @import("../property_ops.zig");
const shared_vm = @import("shared.zig");
const stack_mod = @import("../stack.zig");
const value_ops = @import("../value_ops.zig");

const op = bytecode.opcode.op;

pub const TailCallMethodResult = union(enum) {
    handled,
    return_value: core.Value,
};

pub fn closure(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.Value,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.Value,
    comptime handleCatchableRuntimeError: anytype,
    comptime pushFunctionClosure: anytype,
) !void {
    const index: u32 = if (opc == op.fclosure) blk: {
        const value = readInt(u32, function.code[frame.pc..][0..4]);
        frame.pc += 4;
        break :blk value;
    } else blk: {
        const value: u32 = function.code[frame.pc];
        frame.pc += 1;
        break :blk value;
    };
    if (try tryFuseImmediateSimpleArrayMapClosure(ctx, output, global, stack, function, frame, catch_target, index, handleCatchableRuntimeError)) return;
    try pushFunctionClosure(ctx, frame, stack, function, global, index, opc, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs);
}

fn tryFuseImmediateSimpleArrayMapClosure(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    index: usize,
    comptime handleCatchableRuntimeError: anytype,
) !bool {
    if (frame.pc + 3 > function.code.len) return false;
    if (function.code[frame.pc] != op.call_method) return false;
    if (readInt(u16, function.code[frame.pc + 1 ..][0..2]) != 1) return false;
    if (stack.values.len < 2) return false;

    const callback = function.constants.get(index) orelse return error.InvalidBytecode;
    defer callback.free(ctx.runtime);
    const callback_bytecode = shared_vm.functionBytecodeFromValue(callback) orelse return false;
    if (callback_bytecode.simple_numeric_kind != .arg0_const) return false;

    const receiver = stack.values[stack.values.len - 2];
    const method = stack.values[stack.values.len - 1];
    const method_object = shared_vm.callableObjectFromValue(method) orelse return false;
    const native_ref = core.function.decodeNativeBuiltinId(method_object.nativeFunctionIdSlot().*) orelse return false;
    const map_id = @intFromEnum(builtins.array.PrototypeMethod.map);
    if (native_ref.domain != .array or native_ref.id != map_id) return false;

    const args = [_]core.Value{callback};
    if (try shared_vm.qjsArrayMapSimpleNumericArg0DefaultSpeciesFastCall(ctx.runtime, global, receiver, callback)) |fast_value| {
        errdefer fast_value.free(ctx.runtime);
        const method_owned = try stack.pop();
        method_owned.free(ctx.runtime);
        const receiver_owned = try stack.pop();
        receiver_owned.free(ctx.runtime);
        try stack.pushOwned(fast_value);
        frame.pc += 3;
        return true;
    }
    const result = shared_vm.qjsArrayPrototypeNativeRecord(ctx, output, global, receiver, method_object, map_id, args[0..], function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return true;
        return err;
    };
    const value = result orelse return false;
    errdefer value.free(ctx.runtime);

    const method_owned = try stack.pop();
    method_owned.free(ctx.runtime);
    const receiver_owned = try stack.pop();
    receiver_owned.free(ctx.runtime);
    try stack.pushOwned(value);
    frame.pc += 3;
    return true;
}

pub fn call(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
    comptime execCall: anytype,
) !void {
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
    if (try tryFastSimpleStringCall(ctx, stack, argc)) return;
    if (try tryFastSimpleNumericCall(ctx, stack, argc)) return;
    try execCall(ctx, stack, function, frame, catch_target, argc, output, global);
}

fn tryFastSimpleStringCall(
    ctx: *core.Context,
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

fn simpleStringCallableKind(func: core.Value) ?bytecode.function.SimpleStringKind {
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
    ctx: *core.Context,
    stack: *stack_mod.Stack,
    argc: u16,
) !bool {
    if (argc == 0 or argc > 2) return false;
    const frame_len = @as(usize, argc) + 1;
    if (stack.values.len < frame_len) return false;
    const base = stack.values.len - frame_len;
    const func = stack.values[base];
    const simple = simpleNumericCallable(func) orelse return false;
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
    capture0: ?core.Value = null,
};

fn simpleNumericCallable(func: core.Value) ?SimpleNumericCallable {
    if (func.isFunctionBytecode()) {
        const fb = shared_vm.functionBytecodeFromValue(func) orelse return null;
        return simpleNumericCallableFromBytecode(fb, null);
    }
    const object = shared_vm.functionObjectFromValue(func) orelse return null;
    const function_value = object.functionBytecodeSlot().* orelse return null;
    const fb = shared_vm.functionBytecodeFromValue(function_value) orelse return null;
    const captures = object.functionCapturesSlot().*;
    const capture0 = if (captures.len != 0) shared_vm.slotValueBorrow(captures[0]) else null;
    return simpleNumericCallableFromBytecode(fb, capture0);
}

fn simpleNumericCallableFromBytecode(fb: *const bytecode.FunctionBytecode, capture0: ?core.Value) ?SimpleNumericCallable {
    return switch (fb.simple_numeric_kind) {
        .arg0_const => .{ .kind = .arg0_const, .binop = fb.simple_numeric_op, .rhs = fb.simple_numeric_rhs },
        .arg0_arg1 => .{ .kind = .arg0_arg1, .binop = fb.simple_numeric_op, .rhs = 0 },
        .capture0_arg0 => .{ .kind = .capture0_arg0, .binop = fb.simple_numeric_op, .rhs = 0, .capture0 = capture0 orelse return null },
        .none => null,
    };
}

fn simpleNumericCallResult(rt: *core.Runtime, simple: SimpleNumericCallable, args: []const core.Value) !core.Value {
    return switch (simple.kind) {
        .arg0_const => {
            if (args.len == 0 or !args[0].isNumber()) return error.NotSimpleNumericCall;
            return simpleNumericBinary(rt, simple.binop, args[0], core.Value.int32(simple.rhs));
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
        .none => error.NotSimpleNumericCall,
    };
}

fn simpleNumericBinary(rt: *core.Runtime, binop: u8, lhs: core.Value, rhs: core.Value) !core.Value {
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

fn fastInt32Add(lhs: i32, rhs: i32) core.Value {
    const result = @addWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.Value.int32(result[0]);
    return value_ops.numberToValue(@as(f64, @floatFromInt(lhs)) + @as(f64, @floatFromInt(rhs)));
}

fn fastInt32Sub(lhs: i32, rhs: i32) core.Value {
    const result = @subWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.Value.int32(result[0]);
    return value_ops.numberToValue(@as(f64, @floatFromInt(lhs)) - @as(f64, @floatFromInt(rhs)));
}

fn fastInt32Mul(lhs: i32, rhs: i32) core.Value {
    if ((lhs == 0 and rhs < 0) or (rhs == 0 and lhs < 0)) return core.Value.float64(-0.0);
    const result = @mulWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.Value.int32(result[0]);
    return value_ops.numberToValue(@as(f64, @floatFromInt(lhs)) * @as(f64, @floatFromInt(rhs)));
}

fn primitiveMathNumber(value: core.Value) ?f64 {
    if (value.tag == core.Tag.int) return @floatFromInt(value.asInt32().?);
    if (value.tag == core.Tag.float64) return value.asFloat64().?;
    if (value.asBool()) |bool_value| return if (bool_value) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isUndefined()) return std.math.nan(f64);
    return null;
}

pub fn tailCall(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime execCall: anytype,
) !core.Value {
    const argc = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    try execCall(ctx, stack, function, frame, catch_target, argc, output, global);
    if (stack.peek()) |value| return value;
    return core.Value.undefinedValue();
}

pub fn callMethod(
    ctx: *core.Context,
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
) !void {
    const argc = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    var inline_args: [4]core.Value = undefined;
    const args_buf: []core.Value = if (argc <= inline_args.len)
        inline_args[0..argc]
    else
        try ctx.runtime.memory.alloc(core.Value, argc);
    defer if (argc > inline_args.len) ctx.runtime.memory.free(core.Value, args_buf);
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
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return;
        return err;
    };
    if (fast_result) |value| {
        if (dropUnusedCallResult(ctx, function, frame, value)) return;
        errdefer value.free(ctx.runtime);
        try stack.pushOwned(value);
        return;
    }
    const maybe_array_result = qjsArrayMethodFastCall(ctx, output, global, obj, func, args_buf, function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return;
        return err;
    };
    const result = if (maybe_array_result) |array_result|
        array_result
    else
        callValueOrBytecodeClassMode(ctx, output, global, obj, func, args_buf, function, frame, isCurrentSuperConstructor(ctx, frame, func)) catch |err| {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return;
            return err;
        };
    if (dropUnusedCallResult(ctx, function, frame, result)) return;
    errdefer result.free(ctx.runtime);
    try stack.pushOwned(result);
}

fn dropUnusedCallResult(
    ctx: *core.Context,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    value: core.Value,
) bool {
    if (frame.pc >= function.code.len or function.code[frame.pc] != op.drop) return false;
    frame.pc += 1;
    value.free(ctx.runtime);
    return true;
}

pub fn tailCallMethod(
    ctx: *core.Context,
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
    var inline_args: [4]core.Value = undefined;
    const args_buf: []core.Value = if (argc <= inline_args.len)
        inline_args[0..argc]
    else
        try ctx.runtime.memory.alloc(core.Value, argc);
    defer if (argc > inline_args.len) ctx.runtime.memory.free(core.Value, args_buf);
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
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.Value,
    func: core.Value,
    args: []const core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.Value {
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
            @intFromEnum(builtins.number.StaticMethod.parse_int) => return @as(?core.Value, try shared_vm.qjsGlobalParseInt(ctx, output, global, args, caller_function, caller_frame)),
            @intFromEnum(builtins.number.StaticMethod.parse_float) => return @as(?core.Value, try shared_vm.qjsGlobalParseFloat(ctx, output, global, args, caller_function, caller_frame)),
            else => {},
        },
        .string => switch (native_ref.id) {
            @intFromEnum(builtins.string.StaticMethod.from_char_code) => {
                return @as(?core.Value, try shared_vm.qjsStringFromCharCode(ctx, output, global, args));
            },
            @intFromEnum(builtins.string.PrototypeMethod.substring) => {
                if (try fastStringSubstringPrimitive(ctx.runtime, this_value, args)) |value| return value;
            },
            else => {},
        },
        .date => switch (native_ref.id) {
            @intFromEnum(builtins.date.StaticMethod.now) => return @as(?core.Value, try builtins.date.staticCall(ctx.runtime, native_ref.id, &.{})),
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
        .json => return @as(?core.Value, try shared_vm.qjsJsonCallForNativeRecord(ctx, output, global, native_ref.id, args, caller_function, caller_frame)),
        else => {},
    }
    return null;
}

fn fastStringSubstringPrimitive(
    rt: *core.Runtime,
    this_value: core.Value,
    args: []const core.Value,
) !?core.Value {
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

fn mathMinMaxPrimitive(args: []const core.Value, is_max: bool) ?core.Value {
    if (args.len == 0) return core.Value.float64(if (is_max) -std.math.inf(f64) else std.math.inf(f64));
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
    ctx: *core.Context,
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
) !void {
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
            break :blk try constructValueOrBytecodeWithNewTarget(ctx, output, global, func, apply_args, function, frame, this_value);
        }
        break :blk try constructValueOrBytecodeWithNewTarget(ctx, output, global, func, apply_args, function, frame, func);
    } else try callValueOrBytecodeClassMode(ctx, output, global, effective_this, func, apply_args, function, frame, allow_class_constructor_call);
    if (is_new != 0) {
        stack.pushOwned(result) catch |err| {
            result.free(ctx.runtime);
            return err;
        };
        return;
    }
    defer result.free(ctx.runtime);
    if (allow_class_constructor_call and frame.function.flags.is_derived_class_constructor) {
        if (varRefSlotIsUninitialized(frame.this_value)) {
            const next_this = if (result.isObject()) result else frame.constructor_this_value;
            setSlotValue(ctx, &frame.this_value, next_this.dup());
            initializeCurrentConstructorClassInstanceElements(ctx, output, global, function, frame) catch |err| {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return;
                return err;
            };
        } else {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return;
            return error.ReferenceError;
        }
        try pushSlotValue(stack, frame.this_value);
        return;
    } else if (is_arrow_super_constructor) {
        if (arrow_super_this) |this_value_for_arrow| {
            if (!this_value_for_arrow.isUninitialized()) {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return;
                return error.ReferenceError;
            }
        }
        const next_this = if (result.isObject())
            result
        else if (arrow_constructor_this) |value|
            value
        else
            result;
        setCurrentArrowLexicalThis(ctx, frame, next_this.dup());
        try stack.push(next_this);
        return;
    }
    try stack.push(result);
}

pub fn constructor(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime popDuplicateConstructorTarget: anytype,
    comptime constructValueOrBytecode: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !void {
    const argc = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    var inline_args: [4]core.Value = undefined;
    const args_buf: []core.Value = if (argc <= inline_args.len)
        inline_args[0..argc]
    else
        try ctx.runtime.memory.alloc(core.Value, argc);
    defer if (argc > inline_args.len) ctx.runtime.memory.free(core.Value, args_buf);
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
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return;
        return err;
    };
    if (fused_typed_array_result) |result| {
        errdefer result.free(ctx.runtime);
        try stack.pushOwned(result);
        return;
    }
    const result = constructValueOrBytecode(ctx, output, global, func, args_buf, function, frame, new_target) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return;
        return err;
    };
    errdefer result.free(ctx.runtime);
    if (frame.function.flags.is_derived_class_constructor and shared_vm.isCurrentSuperConstructor(ctx, frame, func)) {
        if (shared_vm.functionObjectFromValue(frame.current_function)) |function_object| {
            if (function_object.functionHomeObjectSlot().*) |home_object| {
                const instance_object = try property_ops.expectObject(result);
                shared_vm.initializeClassPrivateMethods(ctx.runtime, instance_object, home_object) catch |err| {
                    if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return;
                    return err;
                };
            }
        }
    }
    try stack.pushOwned(result);
}

pub fn checkCtor(frame: *frame_mod.Frame) !void {
    if (frame.new_target.isUndefined()) return error.TypeError;
}

pub fn checkCtorReturn(ctx: *core.Context, stack: *stack_mod.Stack) !void {
    _ = ctx;
    const value = stack.peekBorrowed() orelse return error.StackUnderflow;
    if (value.isObject()) {
        try stack.pushOwned(core.Value.boolean(false));
    } else if (value.isUndefined()) {
        try stack.pushOwned(core.Value.boolean(true));
    } else {
        return error.TypeError;
    }
}

pub fn initCtor(
    ctx: *core.Context,
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

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
