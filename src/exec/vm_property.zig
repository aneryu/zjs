const fusion_stats = @import("vm_fusion_stats.zig");
const std = @import("std");
const bytecode = @import("../bytecode/root.zig");
const builtins = @import("../builtins/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const property_ic = @import("property_ic.zig");
const property_ops = @import("property_ops.zig");
const shared_vm = @import("shared.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const globalDataPropertyValueForFastPath = property_ic.globalDataPropertyValueForFastPath;
const ordinaryDataPropertyBorrowedValueForFastPath = property_ic.ordinaryDataPropertyBorrowedValueForFastPath;
const globalWritableDataStoreAvailableForFastPath = property_ic.globalWritableDataStoreAvailableForFastPath;
const setGlobalWritableDataStoreForFastPathOwned = property_ic.setGlobalWritableDataStoreForFastPathOwned;

const op = bytecode.opcode.op;
const atom_string = core.atom.predefinedId("String", .string).?;

pub const Step = enum { done, continue_loop };

const BorrowedArg = struct {
    value: core.JSValue,
    next_pc: usize,
};

const VarRefPut = struct {
    idx: u16,
    opc: u8,
    operand_pc: usize,
    consume: u8,
};

const VarRefGet = struct {
    idx: u16,
    next_pc: usize,
};

pub const BindingGet = struct {
    idx: u16,
    next_pc: usize,
    is_var_ref: bool,
    checked: bool = false,
};

pub const BindingPut = struct {
    idx: u16,
    opc: u8 = 0,
    operand_pc: usize,
    consume: u8,
    is_var_ref: bool,
    checked: bool = false,
};

const OptionalLocalCompletionTail = struct {
    tail_pc: usize,
    completion_put: ?LocalPut = null,
};

pub const GlobalBindingGet = struct {
    atom: core.Atom,
    next_pc: usize,
};

pub const GlobalBindingPut = struct {
    atom: core.Atom,
    next_pc: usize,
};

pub const LoopLimitGet = union(enum) {
    immediate: i32,
    binding: BindingGet,
    arg: u16,
};

const LocalGet = struct {
    idx: u16,
    next_pc: usize,
    checked: bool,
};

const ArgGet = struct {
    idx: u16,
    next_pc: usize,
};

pub const LocalPut = struct {
    idx: u16,
    operand_pc: usize,
    consume: u8,
    checked: bool,
};

const FieldAtom = struct {
    atom: core.Atom,
    next_pc: usize,
};

pub const DecodedFalseBranch = struct {
    true_pc: usize,
    false_pc: usize,
};

pub const SimpleNumericRangeCall = struct {
    kind: bytecode.function.SimpleNumericKind,
    binop: u8,
    rhs: i32 = 0,
    capture0: i32 = 0,
    capture0_slot: core.JSValue = core.JSValue.undefinedValue(),
};

const SimpleNumericRangeSource = struct {
    fb: *const bytecode.FunctionBytecode,
    captures: []const core.JSValue,
};

pub const SimpleNumericRangeArg = union(enum) {
    induction,
    int32: i32,
};

pub const GlobalSimpleNumericRangeArg = union(enum) {
    global: core.Atom,
    int32: i32,
};

const SimpleNumericLinearTerm = struct {
    coefficient: i128,
    offset: i128,
};

pub const InductionImmediateInt32Args = struct {
    immediate: i32,
    next_pc: usize,
};

pub const IntRangeDeltaBounds = struct {
    total: i128,
    min: i128,
    max: i128,
};

const DenseArrayModFieldIncrements = struct {
    values: [8]i32,
    len: usize,
};

pub const GlobalPropertyRangeDelta = union(enum) {
    constant: i32,
    periodic: DenseArrayModFieldIncrements,
};

pub fn decodeFalseBranch(code: []const u8, branch_pc: usize) ?DecodedFalseBranch {
    if (branch_pc >= code.len) return null;
    return switch (code[branch_pc]) {
        op.if_false8 => blk: {
            if (branch_pc + 2 > code.len) return null;
            const operand_pc = branch_pc + 1;
            const diff: i8 = @bitCast(code[operand_pc]);
            const target_i64 = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            if (target_i64 < 0) return null;
            break :blk .{ .true_pc = operand_pc + 1, .false_pc = @intCast(target_i64) };
        },
        op.if_false => blk: {
            if (branch_pc + 5 > code.len) return null;
            const operand_pc = branch_pc + 1;
            const diff = readInt(i32, code[operand_pc..][0..4]);
            const target_i64 = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            if (target_i64 < 0) return null;
            break :blk .{ .true_pc = operand_pc + 4, .false_pc = @intCast(target_i64) };
        },
        else => null,
    };
}

pub const BorrowedCallable = struct {
    value: core.JSValue,
    next_pc: usize,
};

pub fn borrowedSimpleCallable(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    pc: usize,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) ?BorrowedCallable {
    if (pc >= function.code.len) return null;
    const code = function.code;
    return switch (code[pc]) {
        op.get_var_ref0 => if (varRefReadableBorrowed(frame, 0)) |value| .{ .value = value, .next_pc = pc + 1 } else null,
        op.get_var_ref1 => if (varRefReadableBorrowed(frame, 1)) |value| .{ .value = value, .next_pc = pc + 1 } else null,
        op.get_var_ref2 => if (varRefReadableBorrowed(frame, 2)) |value| .{ .value = value, .next_pc = pc + 1 } else null,
        op.get_var_ref3 => if (varRefReadableBorrowed(frame, 3)) |value| .{ .value = value, .next_pc = pc + 1 } else null,
        op.get_var_ref, op.get_var_ref_check => blk: {
            if (pc + 3 > code.len) return null;
            const idx = readInt(u16, code[pc + 1 ..][0..2]);
            const value = varRefReadableBorrowed(frame, idx) orelse return null;
            break :blk .{ .value = value, .next_pc = pc + 3 };
        },
        op.get_var, op.get_var_undef => blk: {
            if (pc + 5 > code.len) return null;
            const atom_id = readInt(u32, code[pc + 1 ..][0..4]);
            const value = fastGlobalDataValueForAtomAtPc(ctx, function, global, frame, pc, atom_id, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return null;
            break :blk .{ .value = value, .next_pc = pc + 5 };
        },
        else => if (decodeLocalGet(code, pc)) |get| blk: {
            const value = localReadableBorrowed(frame, get.idx, get.checked) orelse return null;
            break :blk .{ .value = value, .next_pc = get.next_pc };
        } else null,
    };
}

pub fn decodeLocalGet(code: []const u8, pc: usize) ?LocalGet {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.get_loc0 => .{ .idx = 0, .next_pc = pc + 1, .checked = false },
        op.get_loc1 => .{ .idx = 1, .next_pc = pc + 1, .checked = false },
        op.get_loc2 => .{ .idx = 2, .next_pc = pc + 1, .checked = false },
        op.get_loc3 => .{ .idx = 3, .next_pc = pc + 1, .checked = false },
        op.get_loc8 => blk: {
            if (pc + 2 > code.len) return null;
            break :blk .{ .idx = code[pc + 1], .next_pc = pc + 2, .checked = false };
        },
        op.get_loc => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .idx = readInt(u16, code[pc + 1 ..][0..2]), .next_pc = pc + 3, .checked = false };
        },
        op.get_loc_check => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .idx = readInt(u16, code[pc + 1 ..][0..2]), .next_pc = pc + 3, .checked = true };
        },
        else => null,
    };
}

fn decodeArgGet(code: []const u8, pc: usize) ?ArgGet {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.get_arg0 => .{ .idx = 0, .next_pc = pc + 1 },
        op.get_arg1 => .{ .idx = 1, .next_pc = pc + 1 },
        op.get_arg2 => .{ .idx = 2, .next_pc = pc + 1 },
        op.get_arg3 => .{ .idx = 3, .next_pc = pc + 1 },
        op.get_arg => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .idx = readInt(u16, code[pc + 1 ..][0..2]), .next_pc = pc + 3 };
        },
        else => null,
    };
}

pub fn localReadableBorrowed(frame: *const frame_mod.Frame, idx: u16, checked: bool) ?core.JSValue {
    if (idx >= frame.locals.len or idx >= frame.locals_uninit.len) return null;
    if (checked and frame.localIsUninitialized(idx)) return null;
    const value = slotValueBorrowed(frame.locals[idx]);
    if (value.isUninitialized()) return null;
    return value;
}

fn argReadableBorrowed(frame: *const frame_mod.Frame, idx: u16) ?core.JSValue {
    if (idx >= frame.args.len) return null;
    return slotValueBorrowed(frame.args[idx]);
}

pub fn decodeFieldAtom(code: []const u8, pc: usize, expected_op: u8) ?FieldAtom {
    if (pc + 5 > code.len or code[pc] != expected_op) return null;
    return .{
        .atom = readInt(u32, code[pc + 1 ..][0..4]),
        .next_pc = pc + 5,
    };
}

pub fn bindingReadableBorrowed(frame: *const frame_mod.Frame, binding: BindingGet) ?core.JSValue {
    return if (binding.is_var_ref)
        varRefReadableBorrowed(frame, binding.idx)
    else
        localReadableBorrowed(frame, binding.idx, binding.checked);
}

pub fn sameBinding(a: BindingGet, b: BindingGet) bool {
    return a.idx == b.idx and a.is_var_ref == b.is_var_ref;
}

pub fn localPutNextPc(put: LocalPut) usize {
    return put.operand_pc + put.consume;
}

pub fn localCompletionPutWritableForFastPath(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, put: LocalPut) bool {
    if (put.idx >= frame.locals.len or put.idx >= frame.locals_uninit.len) return false;
    if (put.checked) return false;
    if (put.idx < function.var_is_lexical.len and function.var_is_lexical[put.idx]) return false;
    if (varRefCellFromValue(frame.locals[put.idx]) != null) return false;
    if (put.idx < function.var_is_const.len and function.var_is_const[put.idx]) return false;
    return true;
}

pub fn decodeOptionalLocalCompletionTail(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, pc: usize) ?OptionalLocalCompletionTail {
    const code = function.code;
    if (pc >= code.len) return null;
    if (code[pc] == op.drop) return .{ .tail_pc = pc + 1 };

    const completion_put = decodeLocalPut(code, pc) orelse return null;
    if (!localCompletionPutWritableForFastPath(function, frame, completion_put)) return null;
    return .{
        .tail_pc = localPutNextPc(completion_put),
        .completion_put = completion_put,
    };
}

pub fn decodeOptionalUndefinedLocalCompletionTail(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, pc: usize) ?OptionalLocalCompletionTail {
    const code = function.code;
    if (pc >= code.len or code[pc] != op.undefined) return .{ .tail_pc = pc };
    return decodeOptionalLocalCompletionTail(function, frame, pc + 1);
}

pub fn decodeGotoTarget(code: []const u8, goto_pc: usize) ?usize {
    if (goto_pc >= code.len) return null;
    return switch (code[goto_pc]) {
        op.goto8 => blk: {
            if (goto_pc + 2 > code.len) return null;
            const operand_pc = goto_pc + 1;
            const diff: i8 = @bitCast(code[operand_pc]);
            const target_i64 = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            if (target_i64 < 0) return null;
            break :blk @intCast(target_i64);
        },
        op.goto => blk: {
            if (goto_pc + 5 > code.len) return null;
            const operand_pc = goto_pc + 1;
            const diff = readInt(i32, code[operand_pc..][0..4]);
            const target_i64 = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            if (target_i64 < 0) return null;
            break :blk @intCast(target_i64);
        },
        else => null,
    };
}

fn decodeSimpleLoopOperandEnd(code: []const u8, pc: usize) ?usize {
    if (decodeBindingGet(code, pc)) |get| return get.next_pc;
    if (immediateInt32Operand(code, pc)) |immediate| return immediate.next_pc;
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.get_arg0, op.get_arg1, op.get_arg2, op.get_arg3 => pc + 1,
        op.get_arg => if (pc + 3 <= code.len) pc + 3 else null,
        else => null,
    };
}

fn decodeLoopFalsePcForBody(code: []const u8, condition_pc: usize, body_field_pc: usize) ?usize {
    var pc = decodeSimpleLoopOperandEnd(code, condition_pc) orelse return null;
    pc = decodeSimpleLoopOperandEnd(code, pc) orelse return null;
    if (pc >= code.len or code[pc] != op.lt) return null;
    const branch = decodeFalseBranch(code, pc + 1) orelse return null;
    if (branch.true_pc > body_field_pc or body_field_pc - branch.true_pc > 8) return null;
    return branch.false_pc;
}

pub fn decodeLoopLimitGet(code: []const u8, pc: usize) ?struct { limit: LoopLimitGet, next_pc: usize } {
    if (decodeBindingGet(code, pc)) |binding| return .{ .limit = .{ .binding = binding }, .next_pc = binding.next_pc };
    if (immediateInt32Operand(code, pc)) |immediate| return .{ .limit = .{ .immediate = immediate.value }, .next_pc = immediate.next_pc };
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.get_arg0 => .{ .limit = .{ .arg = 0 }, .next_pc = pc + 1 },
        op.get_arg1 => .{ .limit = .{ .arg = 1 }, .next_pc = pc + 1 },
        op.get_arg2 => .{ .limit = .{ .arg = 2 }, .next_pc = pc + 1 },
        op.get_arg3 => .{ .limit = .{ .arg = 3 }, .next_pc = pc + 1 },
        op.get_arg => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .limit = .{ .arg = readInt(u16, code[pc + 1 ..][0..2]) }, .next_pc = pc + 3 };
        },
        else => null,
    };
}

pub fn loopLimitReadableInt32(frame: *const frame_mod.Frame, limit: LoopLimitGet) ?i32 {
    const value = switch (limit) {
        .immediate => |value| return value,
        .binding => |binding| bindingReadableBorrowed(frame, binding) orelse return null,
        .arg => |idx| blk: {
            if (idx >= frame.args.len) return null;
            break :blk slotValueBorrowed(frame.args[idx]);
        },
    };
    if (value.isUninitialized()) return null;
    return value.asInt32();
}

pub fn bindingStoreWritableForFastPath(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    binding: BindingPut,
) bool {
    _ = global;
    if (binding.is_var_ref) {
        if (binding.idx >= frame.var_refs.len) return false;
        const slot = frame.var_refs[binding.idx];
        if (varRefCellFromValue(slot)) |cell| {
            if (cell.varRefIsDeletedSlot().* or cell.varRefIsFunctionNameSlot().* or cell.varRefIsConstSlot().*) return false;
            const stored = cell.varRefValueSlot().* orelse return false;
            return !stored.isUninitialized();
        }
        if (slot.isUninitialized()) return false;
        if (binding.idx < function.var_ref_is_const.len and function.var_ref_is_const[binding.idx]) return false;
        if (binding.opc == op.put_var_ref_check and binding.idx < function.var_ref_names.len and shared_vm.globalLexicalHas(ctx, function.var_ref_names[binding.idx])) return false;
        return true;
    }
    if (binding.idx >= frame.locals.len or binding.idx >= frame.locals_uninit.len) return false;
    if (binding.checked) {
        if (frame.localIsUninitialized(binding.idx)) return false;
        if (binding.idx < function.var_is_const.len and function.var_is_const[binding.idx]) return false;
    }
    return true;
}

pub fn storeBindingOwnedValue(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    binding: BindingPut,
    value: core.JSValue,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !void {
    if (binding.is_var_ref) {
        try setSlotValue(ctx, &frame.var_refs[binding.idx], value);
    } else {
        try setSlotValue(ctx, &frame.locals[binding.idx], value);
        try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, binding.idx, sync_global_lexical_locals);
    }
}

pub fn storeLocalCompletionBorrowedValue(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    completion_put: ?LocalPut,
    value: core.JSValue,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !void {
    if (completion_put) |completion| {
        try setSlotValue(ctx, &frame.locals[completion.idx], value.dup());
        try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, completion.idx, sync_global_lexical_locals);
    }
}

fn varRefGlobalLexicalWritable(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    var_ref_idx: u16,
) bool {
    if (var_ref_idx >= function.var_ref_names.len) return false;
    const env = shared_vm.existingGlobalLexicalEnv(ctx) orelse return false;
    const desc = env.getOwnProperty(function.var_ref_names[var_ref_idx]) orelse return false;
    return desc.kind == .data and (desc.writable orelse false);
}

pub fn decodeVarRefPut(code: []const u8, pc: usize) ?VarRefPut {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.put_var_ref0 => .{ .idx = 0, .opc = op.put_var_ref0, .operand_pc = pc + 1, .consume = 0 },
        op.put_var_ref1 => .{ .idx = 1, .opc = op.put_var_ref1, .operand_pc = pc + 1, .consume = 0 },
        op.put_var_ref2 => .{ .idx = 2, .opc = op.put_var_ref2, .operand_pc = pc + 1, .consume = 0 },
        op.put_var_ref3 => .{ .idx = 3, .opc = op.put_var_ref3, .operand_pc = pc + 1, .consume = 0 },
        op.put_var_ref, op.put_var_ref_check => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{
                .idx = readInt(u16, code[pc + 1 ..][0..2]),
                .opc = code[pc],
                .operand_pc = pc + 1,
                .consume = 2,
            };
        },
        else => null,
    };
}

pub fn decodeVarRefGet(code: []const u8, pc: usize) ?VarRefGet {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.get_var_ref0 => .{ .idx = 0, .next_pc = pc + 1 },
        op.get_var_ref1 => .{ .idx = 1, .next_pc = pc + 1 },
        op.get_var_ref2 => .{ .idx = 2, .next_pc = pc + 1 },
        op.get_var_ref3 => .{ .idx = 3, .next_pc = pc + 1 },
        op.get_var_ref, op.get_var_ref_check => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{
                .idx = readInt(u16, code[pc + 1 ..][0..2]),
                .next_pc = pc + 3,
            };
        },
        else => null,
    };
}

pub fn decodeBindingGet(code: []const u8, pc: usize) ?BindingGet {
    if (decodeVarRefGet(code, pc)) |get| {
        return .{ .idx = get.idx, .next_pc = get.next_pc, .is_var_ref = true };
    }
    if (decodeLocalGet(code, pc)) |get| {
        return .{ .idx = get.idx, .next_pc = get.next_pc, .is_var_ref = false, .checked = get.checked };
    }
    return null;
}

pub fn decodeBindingPut(code: []const u8, pc: usize) ?BindingPut {
    if (decodeVarRefPut(code, pc)) |put| {
        return .{ .idx = put.idx, .opc = put.opc, .operand_pc = put.operand_pc, .consume = put.consume, .is_var_ref = true };
    }
    if (decodeLocalPut(code, pc)) |put| {
        return .{ .idx = put.idx, .operand_pc = put.operand_pc, .consume = put.consume, .is_var_ref = false, .checked = put.checked };
    }
    return null;
}

pub fn decodeGlobalPut(code: []const u8, pc: usize) ?GlobalBindingPut {
    if (pc + 5 > code.len or code[pc] != op.put_var) return null;
    return .{
        .atom = readInt(u32, code[pc + 1 ..][0..4]),
        .next_pc = pc + 5,
    };
}

pub fn decodeLocalPut(code: []const u8, pc: usize) ?LocalPut {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.put_loc0 => .{ .idx = 0, .operand_pc = pc + 1, .consume = 0, .checked = false },
        op.put_loc1 => .{ .idx = 1, .operand_pc = pc + 1, .consume = 0, .checked = false },
        op.put_loc2 => .{ .idx = 2, .operand_pc = pc + 1, .consume = 0, .checked = false },
        op.put_loc3 => .{ .idx = 3, .operand_pc = pc + 1, .consume = 0, .checked = false },
        op.put_loc8 => blk: {
            if (pc + 2 > code.len) return null;
            break :blk .{ .idx = code[pc + 1], .operand_pc = pc + 1, .consume = 1, .checked = false };
        },
        op.put_loc => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .idx = readInt(u16, code[pc + 1 ..][0..2]), .operand_pc = pc + 1, .consume = 2, .checked = false };
        },
        op.put_loc_check => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .idx = readInt(u16, code[pc + 1 ..][0..2]), .operand_pc = pc + 1, .consume = 2, .checked = true };
        },
        else => null,
    };
}

pub fn borrowedSimpleCallArg(frame: *const frame_mod.Frame, function: *const bytecode.Bytecode, pc: usize) ?BorrowedArg {
    if (pc >= function.code.len) return null;
    const code = function.code;
    if (decodeVarRefGet(code, pc)) |get| {
        return .{
            .value = varRefReadableBorrowed(frame, get.idx) orelse return null,
            .next_pc = get.next_pc,
        };
    }
    if (decodeLocalGet(code, pc)) |get| {
        return .{
            .value = localReadableBorrowed(frame, get.idx, get.checked) orelse return null,
            .next_pc = get.next_pc,
        };
    }
    switch (code[pc]) {
        op.push_minus1 => return .{ .value = core.JSValue.int32(-1), .next_pc = pc + 1 },
        op.push_0 => return .{ .value = core.JSValue.int32(0), .next_pc = pc + 1 },
        op.push_1 => return .{ .value = core.JSValue.int32(1), .next_pc = pc + 1 },
        op.push_2 => return .{ .value = core.JSValue.int32(2), .next_pc = pc + 1 },
        op.push_3 => return .{ .value = core.JSValue.int32(3), .next_pc = pc + 1 },
        op.push_4 => return .{ .value = core.JSValue.int32(4), .next_pc = pc + 1 },
        op.push_5 => return .{ .value = core.JSValue.int32(5), .next_pc = pc + 1 },
        op.push_6 => return .{ .value = core.JSValue.int32(6), .next_pc = pc + 1 },
        op.push_7 => return .{ .value = core.JSValue.int32(7), .next_pc = pc + 1 },
        op.push_i8 => {
            if (pc + 2 > code.len) return null;
            const value: i8 = @bitCast(code[pc + 1]);
            return .{ .value = core.JSValue.int32(value), .next_pc = pc + 2 };
        },
        op.push_i16 => {
            if (pc + 3 > code.len) return null;
            return .{ .value = core.JSValue.int32(readInt(i16, code[pc + 1 ..][0..2])), .next_pc = pc + 3 };
        },
        op.push_i32 => {
            if (pc + 5 > code.len) return null;
            return .{ .value = core.JSValue.int32(readInt(i32, code[pc + 1 ..][0..4])), .next_pc = pc + 5 };
        },
        else => return null,
    }
}

pub fn borrowedSimpleCallArgWithContext(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    pc: usize,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) ?BorrowedArg {
    if (pc >= function.code.len) return null;
    const code = function.code;
    if (code[pc] == op.get_var or code[pc] == op.get_var_undef) {
        if (pc + 5 > code.len) return null;
        const atom_id = readInt(u32, code[pc + 1 ..][0..4]);
        const value = fastGlobalDataValueForAtomAtPc(ctx, function, global, frame, pc, atom_id, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return null;
        return .{ .value = value, .next_pc = pc + 5 };
    }
    return borrowedSimpleCallArg(frame, function, pc);
}

pub fn varRefReadableBorrowed(frame: *const frame_mod.Frame, idx: u16) ?core.JSValue {
    if (idx >= frame.var_refs.len) return null;
    const slot = frame.var_refs[idx];
    if (varRefCellFromValue(slot)) |cell| {
        if (cell.varRefIsDeletedSlot().*) return null;
        const value = slotValueBorrowed(slot);
        if (value.isUninitialized()) return null;
        return value;
    }
    if (slot.isUninitialized()) return null;
    return slot;
}

pub fn varRefStoreWritableForFastPath(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    store: VarRefPut,
) bool {
    _ = global;
    if (store.idx >= frame.var_refs.len) return false;
    const slot = frame.var_refs[store.idx];
    if (varRefCellFromValue(slot)) |cell| {
        if (cell.varRefIsDeletedSlot().* or cell.varRefIsFunctionNameSlot().* or cell.varRefIsConstSlot().*) return false;
        const stored = cell.varRefValueSlot().* orelse return false;
        return !stored.isUninitialized();
    }
    if (slot.isUninitialized()) return false;
    if (store.opc == op.put_var_ref_check) {
        if (store.idx < function.var_ref_names.len and shared_vm.globalLexicalHas(ctx, function.var_ref_names[store.idx])) return false;
        if (store.idx < function.var_ref_is_const.len and function.var_ref_is_const[store.idx]) return false;
    }
    return true;
}

pub fn simpleNumericFunctionResult(rt: *core.JSRuntime, func: core.JSValue, args: []const core.JSValue) !?core.JSValue {
    if (func.isFunctionBytecode()) {
        const fb = shared_vm.functionBytecodeFromValue(func) orelse return null;
        return try simpleNumericBytecodeResult(rt, fb, args, &.{});
    }
    const object = shared_vm.functionObjectFromValue(func) orelse return null;
    const function_value = object.functionBytecodeSlot().* orelse return null;
    const fb = shared_vm.functionBytecodeFromValue(function_value) orelse return null;
    return try simpleNumericBytecodeResult(rt, fb, args, object.functionCapturesSlot().*);
}

pub fn simpleNumericRangeCallable(func: core.JSValue) ?SimpleNumericRangeCall {
    const callable: SimpleNumericRangeSource = if (func.isFunctionBytecode())
        SimpleNumericRangeSource{
            .fb = shared_vm.functionBytecodeFromValue(func) orelse return null,
            .captures = @as([]const core.JSValue, &.{}),
        }
    else blk: {
        const object = shared_vm.functionObjectFromValue(func) orelse return null;
        const function_value = object.functionBytecodeSlot().* orelse return null;
        break :blk SimpleNumericRangeSource{
            .fb = shared_vm.functionBytecodeFromValue(function_value) orelse return null,
            .captures = @as([]const core.JSValue, object.functionCapturesSlot().*),
        };
    };
    const fb = callable.fb;
    const captures = callable.captures;
    return switch (fb.simple_numeric_kind) {
        .arg0_const => .{ .kind = .arg0_const, .binop = fb.simple_numeric_op, .rhs = fb.simple_numeric_rhs },
        .arg0_arg1 => .{ .kind = .arg0_arg1, .binop = fb.simple_numeric_op },
        .capture0_arg0 => blk: {
            if (captures.len == 0) return null;
            const capture_slot = captures[0];
            const captured = slotValueBorrowed(capture_slot).asInt32() orelse return null;
            break :blk .{
                .kind = .capture0_arg0,
                .binop = fb.simple_numeric_op,
                .capture0 = captured,
                .capture0_slot = capture_slot,
            };
        },
        .capture0_post_inc_return => null,
        .none => null,
    };
}

fn simpleNumericBytecodeResult(
    rt: *core.JSRuntime,
    fb: *const bytecode.FunctionBytecode,
    args: []const core.JSValue,
    captures: []const core.JSValue,
) !?core.JSValue {
    return switch (fb.simple_numeric_kind) {
        .arg0_const => {
            if (args.len == 0 or !args[0].isNumber()) return null;
            return try simpleNumericBinary(rt, fb.simple_numeric_op, args[0], core.JSValue.int32(fb.simple_numeric_rhs));
        },
        .arg0_arg1 => {
            if (args.len < 2 or !args[0].isNumber() or !args[1].isNumber()) return null;
            return try simpleNumericBinary(rt, fb.simple_numeric_op, args[0], args[1]);
        },
        .capture0_arg0 => {
            if (args.len == 0 or !args[0].isNumber() or captures.len == 0) return null;
            const captured = slotValueBorrowed(captures[0]);
            if (!captured.isNumber()) return null;
            return try simpleNumericBinary(rt, fb.simple_numeric_op, captured, args[0]);
        },
        .capture0_post_inc_return => try simpleCapture0PostIncReturn(rt, captures, args),
        .none => null,
    };
}

fn simpleCapture0PostIncReturn(rt: *core.JSRuntime, captures: []const core.JSValue, args: []const core.JSValue) !?core.JSValue {
    if (args.len != 0 or captures.len == 0) return null;
    const cell = varRefCellFromValue(captures[0]) orelse return null;
    if (cell.varRefIsDeletedSlot().* or cell.varRefIsFunctionNameSlot().* or cell.varRefIsConstSlot().*) return null;
    const slot = cell.varRefValueSlot();
    const current_value = slot.* orelse return null;
    const current = current_value.asInt32() orelse return null;
    const updated = fastInt32Add(current, 1);
    try cell.setVarRefValue(rt, updated);
    return updated;
}

pub fn simpleNumericRangeLinearTerm(simple: SimpleNumericRangeCall, args: []const SimpleNumericRangeArg) ?SimpleNumericLinearTerm {
    if (simple.binop != op.add and simple.binop != op.sub) return null;
    return switch (simple.kind) {
        .arg0_const => {
            if (args.len == 0 or !simpleNumericRangeArgIsInduction(args[0])) return null;
            return .{
                .coefficient = 1,
                .offset = switch (simple.binop) {
                    op.add => simple.rhs,
                    op.sub => -@as(i128, simple.rhs),
                    else => unreachable,
                },
            };
        },
        .arg0_arg1 => {
            if (args.len < 2) return null;
            return switch (args[0]) {
                .induction => switch (args[1]) {
                    .int32 => |rhs| .{
                        .coefficient = 1,
                        .offset = switch (simple.binop) {
                            op.add => rhs,
                            op.sub => -@as(i128, rhs),
                            else => unreachable,
                        },
                    },
                    .induction => null,
                },
                .int32 => |lhs| switch (args[1]) {
                    .induction => .{
                        .coefficient = switch (simple.binop) {
                            op.add => 1,
                            op.sub => -1,
                            else => unreachable,
                        },
                        .offset = lhs,
                    },
                    .int32 => null,
                },
            };
        },
        .capture0_arg0 => {
            if (args.len == 0 or !simpleNumericRangeArgIsInduction(args[0])) return null;
            return .{
                .coefficient = switch (simple.binop) {
                    op.add => 1,
                    op.sub => -1,
                    else => unreachable,
                },
                .offset = simple.capture0,
            };
        },
        .capture0_post_inc_return => null,
        .none => null,
    };
}

fn simpleNumericRangeArgIsInduction(range_arg: SimpleNumericRangeArg) bool {
    return switch (range_arg) {
        .induction => true,
        .int32 => false,
    };
}

pub fn simpleNumericBinary(rt: *core.JSRuntime, binop: u8, lhs: core.JSValue, rhs: core.JSValue) !core.JSValue {
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

pub fn slotValueBorrowed(slot: core.JSValue) core.JSValue {
    var current = slot;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        const cell = varRefCellFromValue(current) orelse return current;
        current = cell.varRefValueSlot().* orelse return core.JSValue.undefinedValue();
    }
    return current;
}

/// Number of failed match attempts at a bytecode site before the fusion
/// matchers stop being retried there. Shape-driven fusions match on the
/// first attempt; the slack covers matchers with runtime preconditions
/// (e.g. dense-array element kinds) that may stabilize after warm-up.
pub const fusion_cold_threshold: u8 = 16;

pub const DecodedImmediateInt32 = struct {
    value: i32,
    next_pc: usize,
};

pub const TypedArrayLengthPrintStore = struct {
    local_index: u16,
    next_pc: usize,
};

pub const TypedArrayLengthPrintGet = struct {
    idx: u16,
    next_pc: usize,
};

pub const StringSubstringImmediateCall = struct {
    start: usize,
    end: usize,
    call_pc: usize,
};

const CollectionHostOutputKeyKind = enum { atom, local, int32 };

pub const CollectionHostOutputKeyOperand = struct {
    kind: CollectionHostOutputKeyKind,
    atom: core.Atom = core.atom.null_atom,
    local_idx: u16 = 0,
    local_checked: bool = false,
    int32: i32 = 0,
    next_pc: usize,
};

pub const CollectionHostOutputKey = struct {
    value: core.JSValue,
    owned: bool,

    pub fn deinit(self: CollectionHostOutputKey, rt: *core.JSRuntime) void {
        if (self.owned) self.value.free(rt);
    }
};

pub fn finishUndefinedCallResult(
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    next_pc: usize,
) !void {
    if (canFinishUndefinedCompletionTail(function, next_pc)) {
        try stack.pushOwned(core.JSValue.undefinedValue());
        frame.pc = function.code.len;
        return;
    }
    if (next_pc < function.code.len and function.code[next_pc] == op.drop) {
        const after_drop = next_pc + 1;
        if (canFinishWithUndefinedAt(function, after_drop)) {
            try stack.pushOwned(core.JSValue.undefinedValue());
            frame.pc = function.code.len;
            return;
        }
        frame.pc = after_drop;
        return;
    }
    try stack.pushOwned(core.JSValue.undefinedValue());
    frame.pc = next_pc;
}

fn canFinishUndefinedCompletionTail(function: *const bytecode.Bytecode, pc: usize) bool {
    if (function.flags.is_generator or function.flags.is_async) return false;
    const code = function.code;
    if (pc + 4 == code.len and
        code[pc] == op.put_loc0 and
        code[pc + 1] == op.undefined and
        code[pc + 2] == op.put_loc0 and
        code[pc + 3] == op.get_loc0) return true;
    if (pc + 3 == code.len and
        code[pc] == op.undefined and
        code[pc + 1] == op.put_loc0 and
        code[pc + 2] == op.get_loc0) return true;
    if (pc + 2 == code.len and
        code[pc] == op.undefined and
        code[pc + 1] == op.put_loc0) return true;
    if (pc + 2 == code.len and
        code[pc] == op.put_loc0 and
        code[pc + 1] == op.get_loc0) return true;
    return false;
}

pub fn canFinishWithUndefinedAt(function: *const bytecode.Bytecode, pc: usize) bool {
    if (function.flags.is_generator or function.flags.is_async) return false;
    const code = function.code;
    if (pc >= code.len) return false;
    if (code[pc] == op.return_undef) return true;
    return pc + 2 == code.len and code[pc] == op.undefined and code[pc + 1] == op.return_async;
}

pub const FastGlobalReadValue = struct {
    value: core.JSValue,
    owned: bool,

    pub fn deinit(self: FastGlobalReadValue, rt: *core.JSRuntime) void {
        if (self.owned) self.value.free(rt);
    }
};

pub const StringNumberConstCall = struct {
    value: core.JSValue,
    next_pc: usize,
};

pub const StringNumberConstArg = struct {
    value: core.JSValue,
    next_pc: usize,
};

pub fn fastGlobalDataValueForAtomAtPc(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    site_pc: usize,
    atom_id: core.Atom,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) ?core.JSValue {
    if (!canUseFastGlobalVarLookup(function, atom_id, frame, eval_local_names, eval_var_ref_names, eval_with_object)) return null;
    if (globalLexicalValue(ctx, atom_id)) |lexical_value| {
        lexical_value.free(ctx.runtime);
        return null;
    }
    return globalDataPropertyValueForFastPath(ctx.runtime, global, function, site_pc, atom_id);
}

pub fn fastInstalledGlobalDataValueForAtomAtPc(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    site_pc: usize,
    atom_id: core.Atom,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) ?core.JSValue {
    if (!canUseInstalledGlobalDataIc(ctx, function, atom_id, frame, eval_local_names, eval_var_ref_names, eval_with_object, global)) return null;
    if (!frame.current_function.isUndefined() and functionFrameBindingShadowsGlobal(ctx.runtime, function, frame, atom_id)) return null;
    if (globalLexicalValue(ctx, atom_id)) |lexical_value| {
        lexical_value.free(ctx.runtime);
        return null;
    }
    return globalDataPropertyValueForFastPath(ctx.runtime, global, function, site_pc, atom_id);
}

pub fn mathMinMaxPrimitive2(arg0: core.JSValue, arg1: core.JSValue, is_max: bool) ?f64 {
    const a = primitiveMathNumber(arg0) orelse return null;
    const b = primitiveMathNumber(arg1) orelse return null;
    if (std.math.isNan(a)) return a;
    if (std.math.isNan(b)) return b;
    return if (is_max) mathFmax(a, b) else mathFmin(a, b);
}

pub fn mathMinMaxInductionRangeSum(start: i32, limit: i32, immediate: i32, is_max: bool) i128 {
    const first: i128 = start;
    const last: i128 = @as(i128, limit) - 1;
    const clamp: i128 = immediate;
    if (is_max) {
        const const_last = @min(last, clamp - 1);
        const const_count = if (first <= const_last) const_last - first + 1 else 0;
        const linear_first = @max(first, clamp);
        return const_count * clamp + intRangeSum(linear_first, last);
    }

    const linear_last = @min(last, clamp);
    const const_first = @max(first, clamp + 1);
    const const_count = if (const_first <= last) last - const_first + 1 else 0;
    return intRangeSum(first, linear_last) + const_count * clamp;
}

fn intRangeSum(first: i128, last: i128) i128 {
    if (first > last) return 0;
    const count = last - first + 1;
    return @divExact(count * (first + last), 2);
}

pub fn intRangeDeltaBounds(start: i32, limit: i32) IntRangeDeltaBounds {
    return intRangeDeltaBoundsWide(@as(i128, start), @as(i128, limit));
}

pub fn intRangeDeltaBoundsWide(first: i128, limit: i128) IntRangeDeltaBounds {
    const last = limit - 1;
    const total = intRangeSum(first, last);
    var min_delta = @min(@as(i128, 0), total);
    const max_delta = @max(@as(i128, 0), total);
    if (first < 0 and last >= 0) {
        min_delta = @min(min_delta, intRangeSum(first, -1));
    }
    return .{
        .total = total,
        .min = min_delta,
        .max = max_delta,
    };
}

pub fn linearRangeDeltaBounds(first: i128, limit: i128, coefficient: i128, offset: i128) ?IntRangeDeltaBounds {
    if (first >= limit) return .{ .total = 0, .min = 0, .max = 0 };
    if (coefficient != 1 and coefficient != -1) return null;

    const total = linearRangePrefixSum(first, limit, coefficient, offset);
    var min_delta = @min(@as(i128, 0), total);
    var max_delta = @max(@as(i128, 0), total);
    const zero_i = if (coefficient == 1) -offset else offset;
    const count = limit - first;
    const candidates = [_]i128{
        zero_i - first - 1,
        zero_i - first,
        zero_i - first + 1,
        zero_i - first + 2,
    };
    for (candidates) |candidate| {
        const k = std.math.clamp(candidate, 0, count);
        const delta = linearRangePrefixSum(first, first + k, coefficient, offset);
        min_delta = @min(min_delta, delta);
        max_delta = @max(max_delta, delta);
    }
    return .{
        .total = total,
        .min = min_delta,
        .max = max_delta,
    };
}

fn linearRangePrefixSum(first: i128, limit: i128, coefficient: i128, offset: i128) i128 {
    if (first >= limit) return 0;
    const count = limit - first;
    return coefficient * intRangeSum(first, limit - 1) + offset * count;
}

pub fn safeIntegerI128(value: i128) bool {
    const max_safe_integer: i128 = 9007199254740991;
    return value >= -max_safe_integer and value <= max_safe_integer;
}

fn primitiveMathNumber(value: core.JSValue) ?f64 {
    if (value.isInt()) return @floatFromInt(value.asInt32().?);
    if (value.isFloat64()) return value.asFloat64().?;
    if (value.asBool()) |bool_value| return if (bool_value) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isUndefined()) return std.math.nan(f64);
    return null;
}

fn mathFmin(a: f64, b: f64) f64 {
    if (a == 0 and b == 0) return @bitCast(@as(u64, @bitCast(a)) | @as(u64, @bitCast(b)));
    return if (a < b) a else b;
}

fn mathFmax(a: f64, b: f64) f64 {
    if (a == 0 and b == 0) return @bitCast(@as(u64, @bitCast(a)) & @as(u64, @bitCast(b)));
    return if (a < b) b else a;
}

pub fn tryFuseDroppedLocalPostUpdateGoto8FromGet(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    idx: u16,
    next_pc: usize,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!allow_loop_tail_fusion) return false;
    const code = function.code;
    if (next_pc >= code.len) return false;
    const update_op = code[next_pc];
    if (update_op != op.post_inc and update_op != op.post_dec) return false;

    const store = decodeLocalPut(code, next_pc + 1) orelse return false;
    if (store.idx != idx) return false;
    if (idx >= frame.locals.len or idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(idx)) return false;
    if (idx < function.var_is_const.len and function.var_is_const[idx]) return false;

    const drop_pc = store.operand_pc + store.consume;
    if (drop_pc >= code.len or code[drop_pc] != op.drop) return false;
    const goto_pc = drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const target_pc = backwardGotoTarget(code, goto_pc + 1, op.goto8) orelse return false;

    const old_int = slotValueBorrowed(frame.locals[idx]).asInt32() orelse return false;
    const updated_int = switch (update_op) {
        op.post_inc => blk: {
            const updated = @addWithOverflow(old_int, 1);
            if (updated[1] != 0) return false;
            break :blk updated[0];
        },
        op.post_dec => blk: {
            const updated = @subWithOverflow(old_int, 1);
            if (updated[1] != 0) return false;
            break :blk updated[0];
        },
        else => unreachable,
    };

    try setSlotValue(ctx, &frame.locals[idx], core.JSValue.int32(updated_int));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
    frame.pc = target_pc;
    _ = fusion_stats.counted(.tryFuseLocalInt32LessThanArgFalseBranchAtPc, tryFuseLocalInt32LessThanArgFalseBranchAtPc(function, frame, target_pc));
    return true;
}

pub fn tryFuseDroppedLocalPostUpdateGoto8AtPc(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    pc: usize,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const get = decodeLocalGet(function.code, pc) orelse return false;
    return fusion_stats.counted(.tryFuseDroppedLocalPostUpdateGoto8FromGet, try tryFuseDroppedLocalPostUpdateGoto8FromGet(ctx, function, global, frame, get.idx, get.next_pc, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal));
}

fn tryFuseLocalInt32LessThanArgFalseBranchAtPc(
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    pc: usize,
) bool {
    const get = decodeLocalGet(function.code, pc) orelse return false;
    return fusion_stats.counted(.tryFuseLocalInt32LessThanArgFalseBranchFromGet, tryFuseLocalInt32LessThanArgFalseBranchFromGet(function, frame, get.idx, get.next_pc, get.checked));
}

pub fn tryFuseLocalInt32LessThanArgFalseBranchFromGet(
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    local_idx: u16,
    next_pc: usize,
    checked: bool,
) bool {
    const code = function.code;
    const arg_get = decodeArgGet(code, next_pc) orelse return false;
    if (arg_get.next_pc >= code.len or code[arg_get.next_pc] != op.lt) return false;
    const branch = decodeFalseBranch(code, arg_get.next_pc + 1) orelse return false;

    const lhs = (localReadableBorrowed(frame, local_idx, checked) orelse return false).asInt32() orelse return false;
    const rhs = (argReadableBorrowed(frame, arg_get.idx) orelse return false).asInt32() orelse return false;
    frame.pc = if (lhs < rhs) branch.true_pc else branch.false_pc;
    return true;
}

pub fn backwardGotoTarget(code: []const u8, operand_pc: usize, goto_opc: u8) ?usize {
    const target_i64: i64 = switch (goto_opc) {
        op.goto8 => blk: {
            if (operand_pc >= code.len) return null;
            const diff: i8 = @bitCast(code[operand_pc]);
            break :blk @as(i64, @intCast(operand_pc)) + @as(i64, diff);
        },
        op.goto16 => blk: {
            if (operand_pc + 2 > code.len) return null;
            const diff = readInt(i16, code[operand_pc..][0..2]);
            break :blk @as(i64, @intCast(operand_pc)) + @as(i64, diff);
        },
        op.goto => blk: {
            if (operand_pc + 4 > code.len) return null;
            const diff = readInt(i32, code[operand_pc..][0..4]);
            break :blk @as(i64, @intCast(operand_pc)) + @as(i64, diff);
        },
        else => return null,
    };
    if (target_i64 < 0) return null;
    const target: usize = @intCast(target_i64);
    if (target >= operand_pc) return null;
    return target;
}

pub const UriFourByteRangePlan = struct {
    induction_atom: core.Atom,
    induction_put_pc: usize,
    string_store_atom: core.Atom,
    string_store_pc: usize,
    index_atom: core.Atom,
    index_put_pc: usize,
    low_atom: core.Atom,
    low_put_pc: usize,
    high_atom: core.Atom,
    high_put_pc: usize,
    high_completion_put: ?LocalPut = null,
    branch_completion_put: ?LocalPut = null,
    count_atom: core.Atom,
    count_put_pc: usize,
    count_completion_put: ?LocalPut = null,
    induction_completion_put: ?LocalPut = null,
    index_b3_atom: core.Atom,
    index_b3_get_pc: usize,
    limit: i32,
    exit_pc: usize,
};

pub fn simpleStringCallableKind(func: core.JSValue) ?bytecode.function.SimpleStringKind {
    if (func.isFunctionBytecode()) {
        const fb = shared_vm.functionBytecodeFromValue(func) orelse return null;
        return if (fb.simple_string_kind == .none) null else fb.simple_string_kind;
    }
    const object = shared_vm.functionObjectFromValue(func) orelse return null;
    const function_value = object.functionBytecodeSlot().* orelse return null;
    const fb = shared_vm.functionBytecodeFromValue(function_value) orelse return null;
    return if (fb.simple_string_kind == .none) null else fb.simple_string_kind;
}

pub const ImmediateInt32 = struct {
    value: i32,
    next_pc: usize,
};

pub const StoredGlobalDataValue = struct {
    atom: core.Atom,
};

pub fn immediateInt32Operand(code: []const u8, pc: usize) ?ImmediateInt32 {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.push_minus1 => .{ .value = -1, .next_pc = pc + 1 },
        op.push_0 => .{ .value = 0, .next_pc = pc + 1 },
        op.push_1 => .{ .value = 1, .next_pc = pc + 1 },
        op.push_2 => .{ .value = 2, .next_pc = pc + 1 },
        op.push_3 => .{ .value = 3, .next_pc = pc + 1 },
        op.push_4 => .{ .value = 4, .next_pc = pc + 1 },
        op.push_5 => .{ .value = 5, .next_pc = pc + 1 },
        op.push_6 => .{ .value = 6, .next_pc = pc + 1 },
        op.push_7 => .{ .value = 7, .next_pc = pc + 1 },
        op.push_i8 => blk: {
            if (pc + 2 > code.len) return null;
            const value: i8 = @bitCast(code[pc + 1]);
            break :blk .{ .value = value, .next_pc = pc + 2 };
        },
        op.push_i16 => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .value = readInt(i16, code[pc + 1 ..][0..2]), .next_pc = pc + 3 };
        },
        op.push_i32 => blk: {
            if (pc + 5 > code.len) return null;
            break :blk .{ .value = readInt(i32, code[pc + 1 ..][0..4]), .next_pc = pc + 5 };
        },
        else => null,
    };
}

pub const UriCall1Argument = struct {
    value: core.JSValue,
    next_pc: usize,
    owned: bool,
};

pub const UriStrictEqIntArg = struct {
    value: i32,
    next_pc: usize,
};

pub const UriStrictEqBranch = struct {
    true_pc: usize,
    false_pc: usize,
};

// --- With-statement and reference opcode handlers moved to vm_property_ref.zig ---
pub const vm_property_ref = @import("vm_property_ref.zig");
pub const withGetOrDelete = vm_property_ref.withGetOrDelete;
pub const makeSlotRef = vm_property_ref.makeSlotRef;
pub const makeVarRef = vm_property_ref.makeVarRef;
pub const makeVarRefVm = vm_property_ref.makeVarRefVm;
pub const getRefValue = vm_property_ref.getRefValue;
pub const getRefValueVm = vm_property_ref.getRefValueVm;
pub const putRefValue = vm_property_ref.putRefValue;
pub const putRefValueVm = vm_property_ref.putRefValueVm;
pub const withPut = vm_property_ref.withPut;
pub const deleteVar = vm_property_ref.deleteVar;
pub const deletePropertyVm = vm_property_ref.deletePropertyVm;

pub fn decodeGlobalDataGet(code: []const u8, pc: usize) ?GlobalBindingGet {
    if (pc + 5 > code.len) return null;
    const opc = code[pc];
    if (opc != op.get_var and opc != op.get_var_undef) return null;
    return .{
        .atom = readInt(u32, code[pc + 1 ..][0..4]),
        .next_pc = pc + 5,
    };
}

pub fn hasObjectBinding(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    atom_id: core.Atom,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !bool {
    return shared_vm.hasValueProperty(ctx, output, global, receiver, object, atom_id, function, frame);
}

// --- Private-field opcode handlers moved to vm_property_private.zig ---
pub const vm_property_private = @import("vm_property_private.zig");
pub const getPrivateField = vm_property_private.getPrivateField;
pub const getPrivateFieldVm = vm_property_private.getPrivateFieldVm;
pub const putPrivateField = vm_property_private.putPrivateField;
pub const putPrivateFieldVm = vm_property_private.putPrivateFieldVm;
pub const definePrivateField = vm_property_private.definePrivateField;
pub const definePrivateFieldVm = vm_property_private.definePrivateFieldVm;

pub fn tryFuseFollowingLocalStringLengthGtConstSliceConstBranch(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    local_idx: u16,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const get = decodeLocalGet(function.code, frame.pc) orelse return false;
    if (get.checked or get.idx != local_idx) return false;
    return fusion_stats.counted(.tryFuseLocalStringLengthGtConstSliceConstBranchFromGet, try tryFuseLocalStringLengthGtConstSliceConstBranchFromGet(ctx, function, global, frame, local_idx, get.next_pc, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal));
}

const StringSliceConstLocalStore = struct {
    start: usize,
    len: usize,
    store: LocalPut,
};

pub fn decodeStringSliceConstLocalStore(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *const frame_mod.Frame,
    receiver: core.JSValue,
    atom_id: core.Atom,
    arg_pc: usize,
) ?StringSliceConstLocalStore {
    const string_value = stringFromValue(receiver) orelse return null;
    if (!fastStringPrototypeMethodIsDefault(ctx.runtime, global, atom_id, @intFromEnum(builtins.string.PrototypeMethod.slice))) return null;

    const code = function.code;
    const start_arg = immediateInt32Operand(code, arg_pc) orelse return null;
    const call_pc = start_arg.next_pc;
    if (call_pc + 3 > code.len or code[call_pc] != op.call_method) return null;
    if (readInt(u16, code[call_pc + 1 ..][0..2]) != 1) return null;

    const store = decodeLocalPut(code, call_pc + 3) orelse return null;
    if (store.idx >= frame.locals.len or store.idx >= frame.locals_uninit.len) return null;
    if (frame.localIsUninitialized(store.idx)) return null;
    if (store.idx < function.var_is_const.len and function.var_is_const[store.idx]) return null;

    const input_len = string_value.len();
    const input_len_i64 = std.math.cast(i64, input_len) orelse return null;
    var start = @as(i64, start_arg.value);
    if (start < 0) {
        start = @max(input_len_i64 + start, 0);
    } else {
        start = @min(start, input_len_i64);
    }
    const slice_start: usize = @intCast(start);
    return .{
        .start = slice_start,
        .len = input_len - slice_start,
        .store = store,
    };
}

pub fn storeStringSliceConstLocal(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    receiver: core.JSValue,
    decoded: StringSliceConstLocalStore,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !void {
    const result = try shared_vm.stringSliceValue(ctx.runtime, receiver, decoded.start, decoded.len);
    var result_owned = true;
    errdefer if (result_owned) result.free(ctx.runtime);

    try setSlotValue(ctx, &frame.locals[decoded.store.idx], result);
    result_owned = false;
    if (decoded.store.idx < function.var_is_lexical.len and function.var_is_lexical[decoded.store.idx]) {
        frame.clearLocalUninitialized(decoded.store.idx);
    }
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, decoded.store.idx, sync_global_lexical_locals);
    frame.pc = decoded.store.operand_pc + decoded.store.consume;
}

pub fn tryFuseLocalStringLengthGtConstSliceConstBranchFromGet(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    local_idx: u16,
    length_pc: usize,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const code = function.code;
    if (length_pc >= code.len or code[length_pc] != op.get_length) return false;
    const receiver = localReadableBorrowed(frame, local_idx, false) orelse return false;
    const string_value = stringFromValue(receiver) orelse return false;

    const threshold = immediateInt32Operand(code, length_pc + 1) orelse return false;
    if (threshold.next_pc + 1 > code.len or code[threshold.next_pc] != op.gt) return false;
    const branch = decodeFalseBranch(code, threshold.next_pc + 1) orelse return false;

    const body_receiver_get = decodeLocalGet(code, branch.true_pc) orelse return false;
    if (body_receiver_get.idx != local_idx) return false;
    if (body_receiver_get.next_pc + 5 > code.len or code[body_receiver_get.next_pc] != op.get_field2) return false;
    const method_atom = readInt(u32, code[body_receiver_get.next_pc + 1 ..][0..4]);
    const decoded = decodeStringSliceConstLocalStore(ctx, function, global, frame, receiver, method_atom, body_receiver_get.next_pc + 5) orelse return false;
    if (decoded.store.idx != local_idx) return false;
    if (decoded.store.operand_pc + decoded.store.consume != branch.false_pc) return false;

    if (@as(i64, @intCast(string_value.len())) > @as(i64, threshold.value)) {
        try storeStringSliceConstLocal(ctx, function, global, frame, receiver, decoded, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    } else {
        frame.pc = branch.false_pc;
    }
    return true;
}

const StringFromCharCodeInt32Arg = struct {
    value: i32,
    next_pc: usize,
};

pub fn stringFromCharCodeInt32Arg(
    function: *const bytecode.Bytecode,
    frame: *const frame_mod.Frame,
    pc: usize,
) ?StringFromCharCodeInt32Arg {
    const code = function.code;
    const first = immediateInt32Operand(code, pc) orelse return null;
    if (first.next_pc < code.len and code[first.next_pc] == op.call_method) {
        return .{ .value = first.value, .next_pc = first.next_pc };
    }

    const rhs_get = decodeLocalGet(code, first.next_pc) orelse return null;
    const rhs_value = (localReadableBorrowed(frame, rhs_get.idx, rhs_get.checked) orelse return null).asInt32() orelse return null;
    if (rhs_value < 0) return null;

    const divisor = immediateInt32Operand(code, rhs_get.next_pc) orelse return null;
    if (divisor.value <= 0) return null;
    if (divisor.next_pc + 2 > code.len or code[divisor.next_pc] != op.mod or code[divisor.next_pc + 1] != op.add) return null;

    const remainder = @rem(rhs_value, divisor.value);
    return .{
        .value = std.math.add(i32, first.value, remainder) catch return null,
        .next_pc = divisor.next_pc + 2,
    };
}

pub const NumberStaticLiteralResult = struct {
    number: f64,
    next_pc: usize,
};

pub fn isHostOutputFunctionValue(rt: *core.JSRuntime, value: core.JSValue) bool {
    const object = objectFromValue(value) orelse return false;
    return object.hostFunctionKindSlot().* == core.host_function.ids.output or
        shared_vm.isOutputExternalHostFunction(rt, object);
}

pub fn atomAsciiText(rt: *core.JSRuntime, atom_id: core.Atom, buffer: []u8) ?[]const u8 {
    if (core.atom.isTaggedInt(atom_id)) {
        return std.fmt.bufPrint(buffer, "{d}", .{core.atom.atomToUInt32(atom_id)}) catch return null;
    }
    if (rt.atoms.kind(atom_id) != .string) return null;
    const text = rt.atoms.name(atom_id) orelse return null;
    if (!core.string.isAsciiBytes(text)) return null;
    return text;
}

pub fn atomStringValueForFastPath(rt: *core.JSRuntime, atom_id: core.Atom) !?core.JSValue {
    if (rt.atoms.kind(atom_id) != .string) return null;
    const value = try rt.atoms.toStringValue(rt, atom_id);
    if (!value.isString()) {
        value.free(rt);
        return null;
    }
    return value;
}

pub fn canUseFastGlobalVarLookup(
    function: *const bytecode.Bytecode,
    atom_id: core.Atom,
    frame: *const frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) bool {
    if (atom_id == core.atom.ids.undefined_ or atom_id == core.atom.ids.arguments) return false;
    if (!eval_with_object.isUndefined()) return false;
    if (!frame.current_function.isUndefined()) return false;
    if (frameHasVarRefBinding(function, frame, atom_id)) return false;
    if (eval_local_names.len != 0 or eval_var_ref_names.len != 0) return false;
    if (frame.eval_local_names.len != 0 or frame.eval_var_ref_names.len != 0) return false;
    return true;
}

pub fn canUseInstalledGlobalDataIc(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    atom_id: core.Atom,
    frame: *const frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    global: *const core.Object,
) bool {
    if (atom_id == core.atom.ids.undefined_ or atom_id == core.atom.ids.arguments) return false;
    if (!eval_with_object.isUndefined()) return false;
    if (frameHasVarRefBinding(function, frame, atom_id)) return false;
    if (eval_local_names.len != 0 or eval_var_ref_names.len != 0) return false;
    if (frame.eval_local_names.len != 0 or frame.eval_var_ref_names.len != 0) return false;
    _ = global;
    if (ctx.lexicals) |env| {
        if (env.hasOwnProperty(atom_id)) return false;
    }
    return true;
}

pub fn functionFrameBindingShadowsGlobal(rt: *core.JSRuntime, function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, atom_id: core.Atom) bool {
    if (shared_vm.atomIdOrNameEql(rt, function.name, atom_id)) return true;
    if (functionHasDynamicScopeBindings(function, frame)) return true;
    if (functionLocalOrArgBindingShadowsGlobal(rt, function, frame, atom_id)) return true;
    if (parentFunctionEvalBindingShadowsGlobal(rt, frame, atom_id)) return true;
    return false;
}

fn functionHasDynamicScopeBindings(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame) bool {
    if (function.var_ref_names.len != 0 or frame.var_refs.len != 0) return true;
    const function_object = objectFromValue(frame.current_function) orelse return false;
    if (function_object.functionCapturesSlot().*.len != 0) return true;
    if (function_object.functionEvalLocalNamesSlot().*.len != 0) return true;
    if (function_object.functionEvalParentFunction() != null) return true;
    return false;
}

fn functionLocalOrArgBindingShadowsGlobal(rt: *core.JSRuntime, function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, atom_id: core.Atom) bool {
    const arg_count = @min(function.arg_names.len, frame.args.len);
    for (function.arg_names[0..arg_count]) |name| {
        if (shared_vm.atomIdOrNameEql(rt, name, atom_id)) return true;
    }
    const local_count = @min(function.var_names.len, frame.locals.len);
    for (function.var_names[0..local_count]) |name| {
        if (shared_vm.atomIdOrNameEql(rt, name, atom_id)) return true;
    }
    return false;
}

fn parentFunctionEvalBindingShadowsGlobal(rt: *core.JSRuntime, frame: *const frame_mod.Frame, atom_id: core.Atom) bool {
    const function_object = objectFromValue(frame.current_function) orelse return false;
    const parent_value = function_object.functionEvalParentFunction() orelse return false;
    const parent_object = objectFromValue(parent_value) orelse return false;
    const names = parent_object.functionEvalLocalNamesSlot().*;
    const refs = parent_object.functionEvalLocalRefsSlot().*;
    const count = @min(names.len, refs.len);
    for (names[0..count]) |name| {
        if (shared_vm.atomIdOrNameEql(rt, name, atom_id)) return true;
    }
    return false;
}

pub fn canFuseGlobalDataWrite(
    function: *const bytecode.Bytecode,
    frame: *const frame_mod.Frame,
    atom_id: core.Atom,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) bool {
    if (atom_id == core.atom.ids.undefined_ or atom_id == core.atom.ids.arguments) return false;
    if (!eval_with_object.isUndefined()) return false;
    if (frameHasVarRefBinding(function, frame, atom_id)) return false;
    if (eval_local_names.len != 0 or eval_var_ref_names.len != 0) return false;
    if (frame.eval_local_names.len != 0 or frame.eval_var_ref_names.len != 0) return false;
    return true;
}

pub fn frameHasVarRefBinding(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, atom_id: core.Atom) bool {
    const count = @min(frame.var_refs.len, function.var_ref_names.len);
    for (function.var_ref_names[0..count]) |name| {
        if (name == atom_id) return true;
    }
    return false;
}

pub fn denseArrayModFieldInt32Increments(rt: *core.JSRuntime, array_value: core.JSValue, field_atom: core.Atom, modulus: usize) ?DenseArrayModFieldIncrements {
    const array_object = objectFromValue(array_value) orelse return null;
    if (array_object.proxyTarget() != null or array_object.exotic != null) return null;
    if (!array_object.flags.is_array or array_object.arrayElementStorageMode() != .dense) return null;
    if (modulus > @as(usize, @intCast(array_object.length))) return null;
    const elements = array_object.arrayElements();
    if (modulus > elements.len) return null;
    var increments = DenseArrayModFieldIncrements{ .values = undefined, .len = modulus };
    if (modulus > increments.values.len) return null;
    for (0..modulus) |index| {
        const element = elements[index] orelse return null;
        const field_value = ordinaryDataPropertyBorrowedValueForFastPath(rt, element, field_atom) orelse return null;
        const int_value = field_value.asInt32() orelse return null;
        if (int_value < 0) return null;
        increments.values[index] = int_value;
    }
    return increments;
}

pub fn periodicNonNegativeDelta(start: i32, limit: i32, increments: DenseArrayModFieldIncrements) ?i128 {
    if (increments.len == 0 or start < 0 or limit < start) return null;
    const values = increments.values[0..increments.len];
    var cycle_sum: i128 = 0;
    for (values) |value| cycle_sum += value;
    const count: usize = @intCast(@as(i64, limit) - @as(i64, start));
    const full_cycles = count / values.len;
    var total = @as(i128, @intCast(full_cycles)) * cycle_sum;
    const remainder = count % values.len;
    var index = @as(usize, @intCast(@rem(start, @as(i32, @intCast(values.len)))));
    for (0..remainder) |_| {
        total += values[index];
        index = (index + 1) % values.len;
    }
    return total;
}

fn nativeBuiltinIdMatches(native_builtin_id: i32, domain: core.function.NativeBuiltinDomain, expected_id: u32) bool {
    const native_ref = core.function.decodeNativeBuiltinId(native_builtin_id) orelse return false;
    return native_ref.domain == domain and native_ref.id == expected_id;
}

fn nativeBuiltinFunctionValueMatches(value: core.JSValue, domain: core.function.NativeBuiltinDomain, expected_id: u32) bool {
    const function_object = objectFromValue(value) orelse return false;
    return nativeBuiltinIdMatches(function_object.nativeFunctionIdSlot().*, domain, expected_id);
}

fn autoInitNativeBuiltinMatches(info: core.property.AutoInit, domain: core.function.NativeBuiltinDomain, expected_id: u32) bool {
    return info.kind == .native_function and nativeBuiltinIdMatches(info.native_builtin_id, domain, expected_id);
}

fn nativeBuiltinFunctionValueMatchesCollectionOwner(value: core.JSValue, expected_id: u32, owner_class: core.ClassId) bool {
    const function_object = objectFromValue(value) orelse return false;
    if (!nativeBuiltinIdMatches(function_object.nativeFunctionIdSlot().*, .collection, expected_id)) return false;
    return function_object.collectionMethodOwnerClass() == owner_class;
}

fn autoInitCollectionNativeBuiltinMatches(info: core.property.AutoInit, expected_id: u32, owner_class: core.ClassId) bool {
    if (!nativeBuiltinIdMatches(info.native_builtin_id, .collection, expected_id)) return false;
    return info.kind == .native_function and info.collection_method_owner_class == owner_class;
}

pub fn ownPrototypeEntryIsNativeBuiltinDefault(proto: *const core.Object, atom_id: core.Atom, domain: core.function.NativeBuiltinDomain, expected_id: u32) bool {
    if (proto.exotic != null) return false;
    for (proto.shapeProps(), 0..) |prop, property_index| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted or prop.atom_id != atom_id) continue;
        if (prop_flags.accessor) return false;
        return switch (proto.properties[property_index].slot) {
            .data => |method| nativeBuiltinFunctionValueMatches(method, domain, expected_id),
            .auto_init => |info| autoInitNativeBuiltinMatches(info, domain, expected_id),
            .accessor, .deleted => false,
        };
    }
    return false;
}

fn ownPrototypeEntryIsCollectionNativeBuiltinDefault(proto: *const core.Object, atom_id: core.Atom, expected_id: u32, owner_class: core.ClassId) bool {
    if (proto.exotic != null) return false;
    for (proto.shapeProps(), 0..) |prop, property_index| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted or prop.atom_id != atom_id) continue;
        if (prop_flags.accessor) return false;
        return switch (proto.properties[property_index].slot) {
            .data => |method| nativeBuiltinFunctionValueMatchesCollectionOwner(method, expected_id, owner_class),
            .auto_init => |info| autoInitCollectionNativeBuiltinMatches(info, expected_id, owner_class),
            .accessor, .deleted => false,
        };
    }
    return false;
}

pub fn fastRegExpPrototypeMethodIsDefault(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom, expected_id: u32) bool {
    _ = rt;
    const object = objectFromValue(value) orelse return false;
    if (object.class_id != core.class.ids.regexp) return false;
    if (object.hasOwnProperty(atom_id)) return false;
    const proto = object.getPrototype() orelse return false;
    return ownPrototypeEntryIsNativeBuiltinDefault(proto, atom_id, .regexp, expected_id);
}

pub fn fastCollectionPrototypeMethodIsDefault(value: core.JSValue, atom_id: core.Atom, expected_id: u32) bool {
    const object = objectFromValue(value) orelse return false;
    if (object.hasOwnProperty(atom_id)) return false;
    const proto = object.getPrototype() orelse return false;
    return ownPrototypeEntryIsCollectionNativeBuiltinDefault(proto, atom_id, expected_id, object.class_id);
}

pub fn fastArrayPrototypeMethodIsDefault(value: core.JSValue, atom_id: core.Atom, expected_id: u32) bool {
    const object = objectFromValue(value) orelse return false;
    if (!object.flags.is_array or object.hasOwnProperty(atom_id)) return false;
    const proto = object.getPrototype() orelse return false;
    return ownPrototypeEntryIsNativeBuiltinDefault(proto, atom_id, .array, expected_id);
}

pub fn fastStringPrototypeMethodIsDefault(rt: *core.JSRuntime, global: *core.Object, atom_id: core.Atom, expected_id: u32) bool {
    const expected_name = switch (expected_id) {
        @intFromEnum(builtins.string.PrototypeMethod.slice) => "slice",
        @intFromEnum(builtins.string.PrototypeMethod.substring) => "substring",
        else => return false,
    };
    if (!value_ops.atomNameEql(rt, atom_id, expected_name)) return false;
    const proto = shared_vm.constructorPrototypeFromGlobalAtom(rt, global, atom_string) orelse return false;
    return ownPrototypeEntryIsNativeBuiltinDefault(proto, atom_id, .string, expected_id);
}

pub fn fastDenseArrayElementValue(value: core.JSValue, key: core.JSValue) ?core.JSValue {
    const index_i32 = key.asInt32() orelse return null;
    if (index_i32 < 0) return null;
    const object = objectFromValue(value) orelse return null;
    if (object.proxyTarget() != null or object.exotic != null) return null;
    if (!object.flags.is_array or object.arrayElementStorageMode() != .dense) return null;
    const index: u32 = @intCast(index_i32);
    const atom_id = core.atom.atomFromUInt32(index);
    if (object.properties.len != 0 and object.findProperty(atom_id) != null) return null;
    const elements = object.arrayElements();
    if (@as(usize, @intCast(index_i32)) >= elements.len) return null;
    if (elements[@intCast(index_i32)]) |stored| return stored.dup();
    return null;
}

pub fn fastInt32Add(lhs: i32, rhs: i32) core.JSValue {
    const result = @addWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.JSValue.int32(result[0]);
    return value_ops.numberToValue(@as(f64, @floatFromInt(lhs)) + @as(f64, @floatFromInt(rhs)));
}

pub fn fastInt32Sub(lhs: i32, rhs: i32) core.JSValue {
    const result = @subWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.JSValue.int32(result[0]);
    return value_ops.numberToValue(@as(f64, @floatFromInt(lhs)) - @as(f64, @floatFromInt(rhs)));
}

pub fn fastInt32Mul(lhs: i32, rhs: i32) core.JSValue {
    if ((lhs == 0 and rhs < 0) or (rhs == 0 and lhs < 0)) return core.JSValue.float64(-0.0);
    const result = @mulWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.JSValue.int32(result[0]);
    return value_ops.numberToValue(@as(f64, @floatFromInt(lhs)) * @as(f64, @floatFromInt(rhs)));
}

fn objectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

pub fn stringFromValue(value: core.JSValue) ?*core.string.String {
    if (!value.isString()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn varRefCellFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_payload_kind != .var_ref) return null;
    return object;
}

fn testHasPropertyForWith(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    key: core.Atom,
    caller_function: *const bytecode.Bytecode,
    caller_frame: *frame_mod.Frame,
) !bool {
    _ = ctx;
    _ = output;
    _ = global;
    _ = caller_function;
    _ = caller_frame;
    const object = property_ops.expectObject(value) catch return false;
    return object.hasProperty(key);
}

fn testIsBlockedByUnscopables(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    key: core.Atom,
    caller_function: *const bytecode.Bytecode,
    caller_frame: *frame_mod.Frame,
) !bool {
    _ = ctx;
    _ = output;
    _ = global;
    _ = value;
    _ = key;
    _ = caller_function;
    _ = caller_frame;
    return false;
}

fn testGetValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    key: core.Atom,
    caller_function: *const bytecode.Bytecode,
    caller_frame: *frame_mod.Frame,
) !core.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    _ = caller_function;
    _ = caller_frame;
    const object = property_ops.expectObject(value) catch return error.TypeError;
    return object.getProperty(key);
}

fn testHandleCatchableRuntimeError(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
    err: anytype,
) !bool {
    _ = ctx;
    _ = stack;
    _ = frame;
    _ = catch_target;
    _ = global;
    return err;
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

// --- Global variable read/write/define opcode handlers moved to vm_property_globals.zig ---
pub const vm_property_globals = @import("vm_property_globals.zig");
pub const getVar = vm_property_globals.getVar;
pub const putVar = vm_property_globals.putVar;
pub const globalDefinition = vm_property_globals.globalDefinition;
pub const tryFuseBackwardGotoGlobalDataInt32CompareFalseBranch = vm_property_globals.tryFuseBackwardGotoGlobalDataInt32CompareFalseBranch;
pub const tryFuseGlobalInt32PrefixTermsStore = vm_property_globals.tryFuseGlobalInt32PrefixTermsStore;
pub const tryFuseAtomPercentHexGlobalStringStore = vm_property_globals.tryFuseAtomPercentHexGlobalStringStore;

// --- Local/arg/var-ref slot opcode handlers moved to vm_property_locals.zig ---
pub const vm_property_locals = @import("vm_property_locals.zig");
pub const loc = vm_property_locals.loc;
pub const arg = vm_property_locals.arg;
pub const checkedLocVm = vm_property_locals.checkedLocVm;
pub const varRef = vm_property_locals.varRef;
pub const varRefVm = vm_property_locals.varRefVm;
pub const closeLoc = vm_property_locals.closeLoc;

// --- Property field and array-element opcode handlers moved to vm_property_field.zig ---
pub const vm_property_field = @import("vm_property_field.zig");
pub const toPropKey = vm_property_field.toPropKey;
pub const toPropKeyVm = vm_property_field.toPropKeyVm;
pub const toPropKey2 = vm_property_field.toPropKey2;
pub const toPropKey2Vm = vm_property_field.toPropKey2Vm;
pub const setName = vm_property_field.setName;
pub const field = vm_property_field.field;
pub const arrayElement = vm_property_field.arrayElement;
pub const inOrInstanceof = vm_property_field.inOrInstanceof;
