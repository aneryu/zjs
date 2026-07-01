const std = @import("std");
const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const frame_mod = @import("frame.zig");
const property_ic = @import("property_ic.zig");
const property_ops = @import("property_ops.zig");
const call_runtime = @import("call_runtime.zig");
const call_mod = @import("call.zig");
const object_ops = @import("object_ops.zig");
const slot_ops = @import("slot_ops.zig");
const string_ops = @import("string_ops.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const globalDataPropertyValueForFastPath = property_ic.globalDataPropertyValueForFastPath;
const ordinaryDataPropertyBorrowedValueForFastPath = property_ic.ordinaryDataPropertyBorrowedValueForFastPath;
const globalWritableDataStoreAvailableForFastPath = property_ic.globalWritableDataStoreAvailableForFastPath;
const setGlobalWritableDataStoreForFastPathOwned = property_ic.setGlobalWritableDataStoreForFastPathOwned;

const op = bytecode.opcode.op;
const atom_string = core.atom.predefinedId("String", .string).?;

pub const Step = enum { done, continue_loop };

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

pub const IntRangeDeltaBounds = struct {
    total: i128,
    min: i128,
    max: i128,
};

const DenseArrayModFieldIncrements = struct {
    values: [8]i32,
    len: usize,
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
    if (idx >= frame.locals.len) return null;
    if (checked and slot_ops.varRefSlotIsUninitialized(frame.locals[idx])) return null;
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
    if (put.idx >= frame.locals.len) return false;
    if (put.checked) return false;
    if (put.idx < function.vardefs.len and function.vardefs[put.idx].is_lexical) return false;
    if (varRefCellFromValue(frame.locals[put.idx]) != null) return false;
    if (put.idx < function.vardefs.len and function.vardefs[put.idx].is_const) return false;
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
    if (binding.is_var_ref) {
        if (binding.idx >= frame.var_refs.len) return false;
        const slot = frame.var_refs[binding.idx];
        if (varRefCellFromValue(slot)) |cell| {
            if (cell.varRefIsDeletedSlot().* or cell.varRefIsFunctionNameSlot().* or cell.varRefIsConstSlot().*) return false;
            const stored = cell.varRefValue();
            return !stored.isUninitialized();
        }
        if (slot.isUninitialized()) return false;
        if (function.varRefIsConstAt(binding.idx)) return false;
        if (binding.opc == op.put_var_ref_check and binding.idx < function.varRefNamesLen() and call_runtime.globalLexicalHasForGlobal(ctx, global, function.varRefName(binding.idx))) return false;
        return true;
    }
    if (binding.idx >= frame.locals.len) return false;
    if (binding.checked) {
        if (slot_ops.varRefSlotIsUninitialized(frame.locals[binding.idx])) return false;
        if (binding.idx < function.vardefs.len and function.vardefs[binding.idx].is_const) return false;
    }
    return true;
}

pub fn storeBindingOwnedValue(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    binding: BindingPut,
    value: core.JSValue,
) !void {
    if (binding.is_var_ref) {
        try slot_ops.setSlotValue(ctx, &frame.var_refs[binding.idx], value);
    } else {
        try slot_ops.setSlotValue(ctx, &frame.locals[binding.idx], value);
    }
}

pub fn storeLocalCompletionBorrowedValue(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    completion_put: ?LocalPut,
    value: core.JSValue,
) !void {
    if (completion_put) |completion| {
        try slot_ops.setSlotValue(ctx, &frame.locals[completion.idx], value.dup());
    }
}

fn varRefGlobalLexicalWritable(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    var_ref_idx: u16,
) bool {
    if (var_ref_idx >= function.varRefNamesLen()) return false;
    const env = call_runtime.existingGlobalLexicalEnv(ctx) orelse return false;
    const desc = env.getOwnProperty(ctx.runtime, function.varRefName(var_ref_idx)) orelse return false;
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

pub fn globalVarAtom(function: *const bytecode.Bytecode, idx: u16) ?core.Atom {
    if (idx < function.closure_var.len) return function.closure_var[idx].var_name;
    if (idx >= function.varRefNamesLen()) return null;
    return function.varRefName(idx);
}

pub fn decodeGlobalPut(function: *const bytecode.Bytecode, pc: usize) ?GlobalBindingPut {
    const code = function.code;
    if (pc + 3 > code.len or code[pc] != op.put_var) return null;
    const ref_idx = readInt(u16, code[pc + 1 ..][0..2]);
    return .{
        .atom = globalVarAtom(function, ref_idx) orelse return null,
        .next_pc = pc + 3,
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

pub fn varRefReadableBorrowedForFastPath(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, idx: u16) ?core.JSValue {
    if (call_runtime.closureVarIsNonLexicalGlobalSentinel(function, idx)) return null;
    return varRefReadableBorrowed(frame, idx);
}

pub fn varRefStoreWritableForFastPath(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    store: VarRefPut,
) bool {
    if (store.idx >= frame.var_refs.len) return false;
    const slot = frame.var_refs[store.idx];
    if (varRefCellFromValue(slot)) |cell| {
        if (cell.varRefIsDeletedSlot().* or cell.varRefIsFunctionNameSlot().* or cell.varRefIsConstSlot().*) return false;
        const stored = cell.varRefValue();
        return !stored.isUninitialized();
    }
    if (slot.isUninitialized()) return false;
    if (store.opc == op.put_var_ref_check) {
        if (store.idx < function.varRefNamesLen() and call_runtime.globalLexicalHasForGlobal(ctx, global, function.varRefName(store.idx))) return false;
        if (function.varRefIsConstAt(store.idx)) return false;
    }
    return true;
}

pub fn slotValueBorrowed(slot: core.JSValue) core.JSValue {
    var current = slot;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        const cell = varRefCellFromValue(current) orelse return current;
        current = cell.varRefValue();
    }
    return current;
}

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
) ?core.JSValue {
    if (!canUseFastGlobalVarLookup(function, atom_id, frame, eval_local_names, eval_var_ref_names, eval_with_object)) return null;
    if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |lexical_value| {
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
) ?core.JSValue {
    if (!canUseInstalledGlobalDataIc(ctx, function, atom_id, frame, eval_local_names, eval_var_ref_names, eval_with_object, global)) return null;
    if (!frame.current_function.isUndefined() and functionFrameBindingShadowsGlobal(ctx.runtime, function, frame, atom_id)) return null;
    if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |lexical_value| {
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

// --- With-statement and reference opcode handlers moved to vm_property_ref.zig ---
const vm_property_ref = @import("vm_property_ref.zig");

pub fn decodeGlobalDataGet(function: *const bytecode.Bytecode, pc: usize) ?GlobalBindingGet {
    const code = function.code;
    if (pc + 3 > code.len) return null;
    const opc = code[pc];
    if (opc != op.get_var and opc != op.get_var_undef) return null;
    const ref_idx = readInt(u16, code[pc + 1 ..][0..2]);
    return .{
        .atom = globalVarAtom(function, ref_idx) orelse return null,
        .next_pc = pc + 3,
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
    return object_ops.hasValueProperty(ctx, output, global, receiver, object, atom_id, function, frame);
}

// --- Private-field opcode handlers moved to vm_property_private.zig ---
const vm_property_private = @import("vm_property_private.zig");

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
    if (!fastStringPrototypeMethodIsDefault(ctx.runtime, global, atom_id, @intFromEnum(method_ids.string.PrototypeMethod.slice))) return null;

    const code = function.code;
    const start_arg = immediateInt32Operand(code, arg_pc) orelse return null;
    const call_pc = start_arg.next_pc;
    if (call_pc + 3 > code.len or code[call_pc] != op.call_method) return null;
    if (readInt(u16, code[call_pc + 1 ..][0..2]) != 1) return null;

    const store = decodeLocalPut(code, call_pc + 3) orelse return null;
    if (store.idx >= frame.locals.len) return null;
    if (slot_ops.varRefSlotIsUninitialized(frame.locals[store.idx])) return null;
    if (store.idx < function.vardefs.len and function.vardefs[store.idx].is_const) return null;

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
    frame: *frame_mod.Frame,
    receiver: core.JSValue,
    decoded: StringSliceConstLocalStore,
) !void {
    const result = try string_ops.stringSliceValue(ctx.runtime, receiver, decoded.start, decoded.len);
    var result_owned = true;
    errdefer if (result_owned) result.free(ctx.runtime);

    try slot_ops.setSlotValue(ctx, &frame.locals[decoded.store.idx], result);
    result_owned = false;
    frame.pc = decoded.store.operand_pc + decoded.store.consume;
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
        call_mod.isOutputExternalHostFunction(rt, object);
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
    if (frame.evalLocalNames().len != 0 or frame.evalVarRefNames().len != 0) return false;
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
    if (frame.evalLocalNames().len != 0 or frame.evalVarRefNames().len != 0) return false;
    _ = global;
    if (ctx.lexicals) |env| {
        if (env.hasOwnProperty(atom_id)) return false;
    }
    return true;
}

pub fn functionFrameBindingShadowsGlobal(rt: *core.JSRuntime, function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, atom_id: core.Atom) bool {
    if (call_runtime.atomIdOrNameEql(rt, function.name, atom_id)) return true;
    if (functionHasDynamicScopeBindings(function, frame)) return true;
    if (functionLocalOrArgBindingShadowsGlobal(rt, function, frame, atom_id)) return true;
    if (parentFunctionEvalBindingShadowsGlobal(rt, frame, atom_id)) return true;
    return false;
}

fn functionHasDynamicScopeBindings(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame) bool {
    if (function.varRefNamesLen() != 0 or frame.var_refs.len != 0) return true;
    const function_object = objectFromValue(frame.current_function) orelse return false;
    if (function_object.functionCapturesSlot().*.len != 0) return true;
    if (function_object.functionEvalLocalNames().len != 0) return true;
    if (function_object.functionEvalParentFunction() != null) return true;
    return false;
}

fn functionLocalOrArgBindingShadowsGlobal(rt: *core.JSRuntime, function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, atom_id: core.Atom) bool {
    const arg_count = @min(function.arg_names.len, frame.args.len);
    for (function.arg_names[0..arg_count]) |name| {
        if (call_runtime.atomIdOrNameEql(rt, name, atom_id)) return true;
    }
    const local_count = @min(function.vardefs.len, frame.locals.len);
    for (function.vardefs[0..local_count]) |vd| {
        if (call_runtime.atomIdOrNameEql(rt, vd.var_name, atom_id)) return true;
    }
    return false;
}

/// Cheap per-frame-constant precondition for parentFunctionEvalBindingShadowsGlobal:
/// only a closure created inside a direct eval carries an eval-parent link. The
/// var_ref fast lanes call this first — fully inlined (one tag test + one header
/// deref + one field load, no call to objectFromValue) so the common case
/// (top-level code, ordinary closures) short-circuits to a single register test
/// before resolving the atom or making the heavier name-comparison call.
pub inline fn frameClosureHasEvalParent(frame: *const frame_mod.Frame) bool {
    const cf = frame.current_function;
    if (!cf.isObject()) return false;
    const header = cf.refHeader() orelse return false;
    const function_object: *core.Object = @fieldParentPtr("header", header);
    return function_object.functionEvalParentFunction() != null;
}

/// True when this closure's enclosing (eval-containing) function introduced a
/// runtime `var` binding with the same name — qjs's var_object_test
/// (quickjs.c:33158-33167): a free var captured from a parent fd that owns a
/// `_var_`/`_arg_var_` object resolves to that dynamic binding BEFORE the global
/// cell. The global var_ref fast lane must defer to the slow scope-walk
/// (lookupParentFunctionEvalBindingValue) whenever this holds. Gate calls behind
/// frameClosureHasEvalParent so non-eval frames never reach the name walk.
pub fn parentFunctionEvalBindingShadowsGlobal(rt: *core.JSRuntime, frame: *const frame_mod.Frame, atom_id: core.Atom) bool {
    const function_object = objectFromValue(frame.current_function) orelse return false;
    const parent_value = function_object.functionEvalParentFunction() orelse return false;
    const parent_object = objectFromValue(parent_value) orelse return false;
    const names = parent_object.functionEvalLocalNames();
    const refs = parent_object.functionEvalLocalRefs();
    const count = @min(names.len, refs.len);
    for (names[0..count]) |name| {
        if (call_runtime.atomIdOrNameEql(rt, name, atom_id)) return true;
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
    if (frame.evalLocalNames().len != 0 or frame.evalVarRefNames().len != 0) return false;
    return true;
}

pub fn frameHasVarRefBinding(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, atom_id: core.Atom) bool {
    const count = @min(frame.var_refs.len, function.varRefNamesLen());
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const name = function.varRefName(idx);
        if (name == atom_id) return true;
    }
    return false;
}

pub fn denseArrayModFieldInt32Increments(rt: *core.JSRuntime, array_value: core.JSValue, field_atom: core.Atom, modulus: usize) ?DenseArrayModFieldIncrements {
    const array_object = objectFromValue(array_value) orelse return null;
    if (array_object.proxyTarget() != null or array_object.hasExoticMethods()) return null;
    if (!array_object.flags.is_array or array_object.arrayElementStorageMode() != .dense) return null;
    if (modulus > @as(usize, @intCast(array_object.arrayLength()))) return null;
    const elements = array_object.arrayElements();
    if (modulus > elements.len) return null;
    var increments = DenseArrayModFieldIncrements{ .values = undefined, .len = modulus };
    if (modulus > increments.values.len) return null;
    for (0..modulus) |index| {
        const element = elements[index];
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
    if (proto.hasExoticMethods()) return false;
    for (proto.shapeProps(), 0..) |prop, property_index| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted or prop.atom_id != atom_id) continue;
        if (prop_flags.isAccessor()) return false;
        return switch (proto.properties[property_index].slot) {
            .data => |method| nativeBuiltinFunctionValueMatches(method, domain, expected_id),
            .auto_init => |info| autoInitNativeBuiltinMatches(info, domain, expected_id),
            .accessor, .deleted => false,
        };
    }
    return false;
}

fn ownPrototypeEntryIsCollectionNativeBuiltinDefault(proto: *const core.Object, atom_id: core.Atom, expected_id: u32, owner_class: core.ClassId) bool {
    if (proto.hasExoticMethods()) return false;
    for (proto.shapeProps(), 0..) |prop, property_index| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted or prop.atom_id != atom_id) continue;
        if (prop_flags.isAccessor()) return false;
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
        @intFromEnum(method_ids.string.PrototypeMethod.slice) => "slice",
        @intFromEnum(method_ids.string.PrototypeMethod.substring) => "substring",
        else => return false,
    };
    if (!value_ops.atomNameEql(rt, atom_id, expected_name)) return false;
    const proto = object_ops.constructorPrototypeFromGlobalAtom(rt, global, atom_string) orelse return false;
    return ownPrototypeEntryIsNativeBuiltinDefault(proto, atom_id, .string, expected_id);
}

pub fn fastDenseArrayElementValue(value: core.JSValue, key: core.JSValue) ?core.JSValue {
    const index_i32 = key.asInt32() orelse return null;
    if (index_i32 < 0) return null;
    const object = objectFromValue(value) orelse return null;
    const index: u32 = @intCast(index_i32);
    return object.fastArrayElementDup(index);
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

fn varRefCellFromValue(value: core.JSValue) ?*core.VarRef {
    return core.VarRef.fromValue(value);
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

// --- Global variable read/write/define opcode handlers moved to vm_property_globals.zig ---
const vm_property_globals = @import("vm_property_globals.zig");

// --- Local/arg/var-ref slot opcode handlers moved to vm_property_locals.zig ---
const vm_property_locals = @import("vm_property_locals.zig");

// --- Property field and array-element opcode handlers moved to vm_property_field.zig ---
const vm_property_field = @import("vm_property_field.zig");
