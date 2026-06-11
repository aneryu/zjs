//! Property field and array-element opcode handlers (get/put_field, get/put_array_el, in/instanceof, to_prop_key).

const std = @import("std");
const bytecode = @import("../bytecode/root.zig");
const builtins = @import("../builtins/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const property_ic = @import("property_ic.zig");
const property_ops = @import("property_ops.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const shared_vm = @import("shared.zig");
const objectFromValue = shared_vm.objectFromValue;
const readInt = shared_vm.readInt;
const varRefCellFromValue = shared_vm.varRefCellFromValue;

// Helpers that remain in vm_property.zig (shared with the leftover handlers).
const property_vm = @import("vm_property.zig");
const BindingGet = property_vm.BindingGet;
const BindingPut = property_vm.BindingPut;
const DecodedFalseBranch = property_vm.DecodedFalseBranch;
const GlobalBindingGet = property_vm.GlobalBindingGet;
const GlobalBindingPut = property_vm.GlobalBindingPut;
const InductionImmediateInt32Args = property_vm.InductionImmediateInt32Args;
const LoopLimitGet = property_vm.LoopLimitGet;
const Step = property_vm.Step;
const atomAsciiText = property_vm.atomAsciiText;
const atomStringValueForFastPath = property_vm.atomStringValueForFastPath;
const bindingReadableBorrowed = property_vm.bindingReadableBorrowed;
const bindingStoreWritableForFastPath = property_vm.bindingStoreWritableForFastPath;
const borrowedSimpleCallArg = property_vm.borrowedSimpleCallArg;
const decodeBindingGet = property_vm.decodeBindingGet;
const decodeBindingPut = property_vm.decodeBindingPut;
const decodeFalseBranch = property_vm.decodeFalseBranch;
const decodeGlobalPut = property_vm.decodeGlobalPut;
const decodeGotoTarget = property_vm.decodeGotoTarget;
const decodeLocalGet = property_vm.decodeLocalGet;
const decodeLocalPut = property_vm.decodeLocalPut;
const decodeLoopLimitGet = property_vm.decodeLoopLimitGet;
const decodeOptionalLocalCompletionTail = property_vm.decodeOptionalLocalCompletionTail;
const decodeStringSliceConstLocalStore = property_vm.decodeStringSliceConstLocalStore;
const fastArrayPrototypeMethodIsDefault = property_vm.fastArrayPrototypeMethodIsDefault;
const fastDenseArrayElementValue = property_vm.fastDenseArrayElementValue;
const fastRegExpPrototypeMethodIsDefault = property_vm.fastRegExpPrototypeMethodIsDefault;
const finishUndefinedCallResult = property_vm.finishUndefinedCallResult;
const frameHasVarRefBinding = property_vm.frameHasVarRefBinding;
const immediateInt32Operand = property_vm.immediateInt32Operand;
const isHostOutputFunctionValue = property_vm.isHostOutputFunctionValue;
const loopLimitReadableInt32 = property_vm.loopLimitReadableInt32;
const mathMinMaxInductionRangeSum = property_vm.mathMinMaxInductionRangeSum;
const mathMinMaxPrimitive2 = property_vm.mathMinMaxPrimitive2;
const pushBorrowedValueOrFuseLocalAdd = property_vm.pushBorrowedValueOrFuseLocalAdd;
const sameBinding = property_vm.sameBinding;
const simpleNumericBinary = property_vm.simpleNumericBinary;
const slotValueBorrowed = property_vm.slotValueBorrowed;
const storeBindingOwnedValue = property_vm.storeBindingOwnedValue;
const storeLocalCompletionBorrowedValue = property_vm.storeLocalCompletionBorrowedValue;
const storeStringSliceConstLocal = property_vm.storeStringSliceConstLocal;
const stringFromCharCodeInt32Arg = property_vm.stringFromCharCodeInt32Arg;
const tryFuseLocalAddWithValue = property_vm.tryFuseLocalAddWithValue;
const tryFuseStringFromCharCodeInt32LocalAppend = property_vm.tryFuseStringFromCharCodeInt32LocalAppend;
const varRefReadableBorrowed = property_vm.varRefReadableBorrowed;

const dataPropertyValueForFastPath = property_ic.dataPropertyValueForFastPath;
const functionOwnDataPropertyValueForFastPath = property_ic.functionOwnDataPropertyValueForFastPath;
const functionOwnNativeBuiltinRefForFastPath = property_ic.functionOwnNativeBuiltinRefForFastPath;
const globalOwnDataPropertyValue = property_ic.globalOwnDataPropertyValue;
const ordinaryDataPropertyValueOrUndefinedForFastPath = property_ic.ordinaryDataPropertyValueOrUndefinedForFastPath;
const setObjectDataPropertyForPutFieldFastPath = property_ic.setObjectDataPropertyForPutFieldFastPath;
const ownDataPropertyValueMaterializedForFastPath = property_ic.ownDataPropertyValueMaterializedForFastPath;
const op = bytecode.opcode.op;
const atom_math = core.atom.predefinedId("Math", .string).?;
const RegExpLoopGet = RegExpMatchGet;
const RegExpLoopPut = RegExpMatchPut;

const RegExpExecLengthLoop = struct {
    input_get: RegExpLoopGet,
    match_put: RegExpMatchPut,
    accumulator_get: RegExpLoopGet,
    accumulator_put: RegExpLoopPut,
    success_pc: usize,
    false_pc: usize,
    receiver_pc: usize,
    stack_drop_count: u8 = 1,
};

const RegExpMatchGet = union(enum) {
    binding: BindingGet,
    global: GlobalBindingGet,
};

const RegExpMatchPut = union(enum) {
    binding: BindingPut,
    global: GlobalBindingPut,
};

const RegExpExecCaptureLengthSumLoop = struct {
    input_get: BindingGet,
    match_put: BindingPut,
    accumulator_get: BindingGet,
    accumulator_put: BindingPut,
    induction_get: BindingGet,
    loop_limit: LoopLimitGet,
    capture_indexes: [8]u8,
    capture_count: usize,
    tail_pc: usize,
    false_pc: usize,
};

const RegExpExecCountLoop = struct {
    input_get: RegExpLoopGet,
    match_put: RegExpMatchPut,
    accumulator_get: RegExpLoopGet,
    accumulator_put: RegExpLoopPut,
    success_pc: usize,
    false_pc: usize,
    receiver_pc: usize,
    stack_drop_count: u8 = 1,
};

const RegExpExecCaptureLengthWhileLoop = struct {
    input_get: RegExpLoopGet,
    match_put: RegExpMatchPut,
    accumulator_get: RegExpLoopGet,
    accumulator_put: RegExpLoopPut,
    capture_indexes: [8]u8,
    capture_count: usize,
    success_pc: usize,
    false_pc: usize,
    receiver_pc: usize,
    stack_drop_count: u8 = 1,
};

fn tryFuseBooleanIfFalseBranch(function: *const bytecode.Bytecode, frame: *frame_mod.Frame, branch_pc: usize, condition: bool) bool {
    const code = function.code;
    if (branch_pc >= code.len) return false;
    return switch (code[branch_pc]) {
        op.if_false8 => {
            if (branch_pc + 2 > code.len) return false;
            const operand_pc = branch_pc + 1;
            const diff: i8 = @bitCast(code[operand_pc]);
            frame.pc = if (condition)
                operand_pc + 1
            else
                @intCast(@as(i64, @intCast(operand_pc)) + @as(i64, diff));
            return true;
        },
        op.if_false => {
            if (branch_pc + 5 > code.len) return false;
            const operand_pc = branch_pc + 1;
            const diff = readInt(i32, code[operand_pc..][0..4]);
            frame.pc = if (condition)
                operand_pc + 4
            else
                @intCast(@as(i64, @intCast(operand_pc)) + @as(i64, diff));
            return true;
        },
        else => false,
    };
}

fn sameBindingGetPut(get: BindingGet, put: BindingPut) bool {
    return get.idx == put.idx and get.is_var_ref == put.is_var_ref;
}

fn canUseRegExpLoopGlobalData(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *const frame_mod.Frame,
    atom_id: core.Atom,
    eval_local_names: []const core.Atom,
    eval_with_object: core.JSValue,
) bool {
    _ = global;
    if (atom_id == core.atom.ids.undefined_ or atom_id == core.atom.ids.arguments) return false;
    if (!frame.current_function.isUndefined()) return false;
    if (!eval_with_object.isUndefined()) return false;
    if (eval_local_names.len != 0) return false;
    if (frame.eval_local_names.len != 0 or frame.eval_var_ref_names.len != 0) return false;
    if (frameHasVarRefBinding(function, frame, atom_id)) return false;
    if (shared_vm.globalLexicalHas(ctx, atom_id)) return false;
    return true;
}

fn regExpLoopFrameVarRefIndex(rt: *core.JSRuntime, function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, atom_id: core.Atom) ?u16 {
    const count = @min(frame.var_refs.len, function.var_ref_names.len);
    for (function.var_ref_names[0..count], 0..) |name, idx| {
        if (!shared_vm.atomIdOrNameEql(rt, name, atom_id)) continue;
        if (idx > std.math.maxInt(u16)) return null;
        return @intCast(idx);
    }
    return null;
}

fn regExpLoopNamedVarRefIndex(rt: *core.JSRuntime, names: []const core.Atom, refs: []const core.JSValue, atom_id: core.Atom) ?usize {
    for (names, 0..) |name, idx| {
        if (idx >= refs.len) return null;
        if (!shared_vm.atomIdOrNameEql(rt, name, atom_id)) continue;
        return idx;
    }
    return null;
}

fn regExpLoopNamedVarRefStoreWritable(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, idx: u16) bool {
    if (idx >= frame.var_refs.len) return false;
    const slot = frame.var_refs[idx];
    if (varRefCellFromValue(slot)) |cell| {
        if (cell.varRefIsDeletedSlot().* or cell.varRefIsFunctionNameSlot().* or cell.varRefIsConstSlot().*) return false;
        const stored = cell.varRefValueSlot().* orelse return false;
        return !stored.isUninitialized();
    }
    if (slot.isUninitialized()) return false;
    if (idx < function.var_ref_is_const.len and function.var_ref_is_const[idx]) return false;
    return true;
}

fn namedVarRefReadableBorrowed(refs: []const core.JSValue, idx: usize) ?core.JSValue {
    if (idx >= refs.len) return null;
    const slot = refs[idx];
    if (varRefCellFromValue(slot)) |cell| {
        if (cell.varRefIsDeletedSlot().*) return null;
        const value = slotValueBorrowed(slot);
        if (value.isUninitialized()) return null;
        return value;
    }
    if (slot.isUninitialized()) return null;
    return slot;
}

fn namedVarRefStoreWritable(refs: []const core.JSValue, idx: usize) bool {
    if (idx >= refs.len) return false;
    const slot = refs[idx];
    const cell = varRefCellFromValue(slot) orelse return false;
    if (cell.varRefIsDeletedSlot().* or cell.varRefIsFunctionNameSlot().* or cell.varRefIsConstSlot().*) return false;
    const stored = cell.varRefValueSlot().* orelse return false;
    return !stored.isUninitialized();
}

fn storeNamedVarRefOwnedValue(rt: *core.JSRuntime, refs: []const core.JSValue, idx: usize, value: core.JSValue) !void {
    const cell = varRefCellFromValue(refs[idx]).?;
    errdefer value.free(rt);
    try cell.setVarRefValue(rt, value);
}

fn globalDataStoreWritableForFastPath(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *const frame_mod.Frame,
    atom_id: core.Atom,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    eval_with_object: core.JSValue,
) bool {
    if (!eval_with_object.isUndefined() or eval_local_names.len != 0 or frame.eval_local_names.len != 0 or frame.eval_var_ref_names.len != 0) return false;
    if (regExpLoopNamedVarRefIndex(ctx.runtime, eval_var_ref_names, eval_var_refs, atom_id)) |idx| {
        return namedVarRefStoreWritable(eval_var_refs, idx);
    }
    if (regExpLoopFrameVarRefIndex(ctx.runtime, function, frame, atom_id)) |idx| {
        return regExpLoopNamedVarRefStoreWritable(function, frame, idx);
    }
    if (!canUseRegExpLoopGlobalData(ctx, function, global, frame, atom_id, eval_local_names, eval_with_object)) return false;
    const desc = global.getOwnProperty(atom_id) orelse return false;
    defer desc.destroy(ctx.runtime);
    return desc.kind == .data and (desc.writable orelse false);
}

fn regExpLoopReadableBorrowed(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *const frame_mod.Frame,
    binding: RegExpLoopGet,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    eval_with_object: core.JSValue,
) ?core.JSValue {
    return switch (binding) {
        .binding => |get| bindingReadableBorrowed(frame, get),
        .global => |get| blk: {
            if (!eval_with_object.isUndefined() or eval_local_names.len != 0 or frame.eval_local_names.len != 0 or frame.eval_var_ref_names.len != 0) return null;
            if (regExpLoopNamedVarRefIndex(ctx.runtime, eval_var_ref_names, eval_var_refs, get.atom)) |idx| {
                break :blk namedVarRefReadableBorrowed(eval_var_refs, idx) orelse return null;
            }
            if (regExpLoopFrameVarRefIndex(ctx.runtime, function, frame, get.atom)) |idx| {
                break :blk varRefReadableBorrowed(frame, idx) orelse return null;
            }
            if (!canUseRegExpLoopGlobalData(ctx, function, global, frame, get.atom, eval_local_names, eval_with_object)) return null;
            break :blk globalOwnDataPropertyValue(global, get.atom) orelse return null;
        },
    };
}

fn regExpMatchStoreWritableForFastPath(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    binding: RegExpMatchPut,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    eval_with_object: core.JSValue,
) bool {
    return switch (binding) {
        .binding => |put| bindingStoreWritableForFastPath(ctx, function, global, frame, put),
        .global => |put| globalDataStoreWritableForFastPath(ctx, function, global, frame, put.atom, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object),
    };
}

fn storeRegExpLoopOwnedValue(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    binding: RegExpLoopPut,
    value: core.JSValue,
    sync_global_lexical_locals: bool,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !void {
    switch (binding) {
        .binding => |put| try storeBindingOwnedValue(ctx, function, global, frame, put, value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal),
        .global => |put| {
            if (regExpLoopNamedVarRefIndex(ctx.runtime, eval_var_ref_names, eval_var_refs, put.atom)) |idx| {
                try storeNamedVarRefOwnedValue(ctx.runtime, eval_var_refs, idx, value);
                return;
            }
            if (regExpLoopFrameVarRefIndex(ctx.runtime, function, frame, put.atom)) |idx| {
                try setSlotValue(ctx, &frame.var_refs[idx], value);
                return;
            }
            defer value.free(ctx.runtime);
            const stored = try global.setOwnWritableDataProperty(ctx.runtime, put.atom, value);
            std.debug.assert(stored);
        },
    }
}

fn storeRegExpMatchNull(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    binding: RegExpMatchPut,
    sync_global_lexical_locals: bool,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !void {
    switch (binding) {
        .binding => |put| try storeBindingOwnedValue(ctx, function, global, frame, put, core.JSValue.nullValue(), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal),
        .global => |put| {
            if (regExpLoopNamedVarRefIndex(ctx.runtime, eval_var_ref_names, eval_var_refs, put.atom)) |idx| {
                try storeNamedVarRefOwnedValue(ctx.runtime, eval_var_refs, idx, core.JSValue.nullValue());
                return;
            }
            if (regExpLoopFrameVarRefIndex(ctx.runtime, function, frame, put.atom)) |idx| {
                try setSlotValue(ctx, &frame.var_refs[idx], core.JSValue.nullValue());
                return;
            }
            const stored = try global.setOwnWritableDataProperty(ctx.runtime, put.atom, core.JSValue.nullValue());
            std.debug.assert(stored);
        },
    }
}

fn decodeRegExpMatchGet(code: []const u8, pc: usize) ?RegExpMatchGet {
    if (decodeBindingGet(code, pc)) |get| return .{ .binding = get };
    if (pc + 5 <= code.len and (code[pc] == op.get_var or code[pc] == op.get_var_undef)) {
        return .{ .global = .{
            .atom = readInt(u32, code[pc + 1 ..][0..4]),
            .next_pc = pc + 5,
        } };
    }
    return null;
}

fn decodeRegExpMatchPut(code: []const u8, pc: usize) ?RegExpMatchPut {
    if (decodeBindingPut(code, pc)) |put| return .{ .binding = put };
    if (decodeGlobalPut(code, pc)) |put| return .{ .global = put };
    return null;
}

fn decodeMakeVarRef(code: []const u8, pc: usize) ?GlobalBindingGet {
    if (pc + 5 > code.len or code[pc] != op.make_var_ref) return null;
    return .{
        .atom = readInt(u32, code[pc + 1 ..][0..4]),
        .next_pc = pc + 5,
    };
}

fn regExpMatchGetNextPc(get: RegExpMatchGet) usize {
    return switch (get) {
        .binding => |binding| binding.next_pc,
        .global => |global| global.next_pc,
    };
}

fn regExpMatchPutNextPc(put: RegExpMatchPut) usize {
    return switch (put) {
        .binding => |binding| binding.operand_pc + binding.consume,
        .global => |global| global.next_pc,
    };
}

fn sameRegExpMatchGetPut(get: RegExpMatchGet, put: RegExpMatchPut) bool {
    return switch (get) {
        .binding => |get_binding| switch (put) {
            .binding => |put_binding| sameBindingGetPut(get_binding, put_binding),
            .global => false,
        },
        .global => |get_global| switch (put) {
            .binding => false,
            .global => |put_global| get_global.atom == put_global.atom,
        },
    };
}

fn sameRegExpMatchGet(a: RegExpMatchGet, b: RegExpMatchGet) bool {
    return switch (a) {
        .binding => |a_binding| switch (b) {
            .binding => |b_binding| sameBinding(a_binding, b_binding),
            .global => false,
        },
        .global => |a_global| switch (b) {
            .binding => false,
            .global => |b_global| a_global.atom == b_global.atom,
        },
    };
}

fn regExpLoopGetConflictsWithMatchPut(get: RegExpLoopGet, put: RegExpMatchPut) bool {
    return sameRegExpMatchGetPut(get, put);
}

fn parseInductionAndImmediateInt32ArgsUnchecked(code: []const u8, pc: usize, local_idx: u16) ?InductionImmediateInt32Args {
    if (decodeLocalGet(code, pc)) |arg0_get| {
        if (arg0_get.idx != local_idx) return null;
        const arg1 = immediateInt32Operand(code, arg0_get.next_pc) orelse return null;
        return .{ .immediate = arg1.value, .next_pc = arg1.next_pc };
    }
    const arg0 = immediateInt32Operand(code, pc) orelse return null;
    const arg1_get = decodeLocalGet(code, arg0.next_pc) orelse return null;
    if (arg1_get.idx != local_idx) return null;
    return .{ .immediate = arg0.value, .next_pc = arg1_get.next_pc };
}

pub fn toPropKey(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime toPropertyKeyValue: anytype,
) !void {
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const key = try toPropertyKeyValue(ctx, output, global, value, function, frame);
    errdefer key.free(ctx.runtime);
    try stack.pushOwned(key);
}

pub fn toPropKeyVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime toPropertyKeyValue: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    toPropKey(ctx, output, global, stack, function, frame, toPropertyKeyValue) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn toPropKey2(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime toPropertyKeyValue: anytype,
) !void {
    if (stack.values.len < 2) return error.StackUnderflow;
    const receiver = stack.values[stack.values.len - 2];
    if (receiver.isUndefined() or receiver.isNull()) return error.TypeError;

    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const key = try toPropertyKeyValue(ctx, output, global, value, function, frame);
    errdefer key.free(ctx.runtime);
    try stack.pushOwned(key);
}

pub fn toPropKey2Vm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime toPropertyKeyValue: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    toPropKey2(ctx, output, global, stack, function, frame, toPropertyKeyValue) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn setName(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    opc: u8,
    comptime toPropertyKeyAtom: anytype,
    comptime functionNameValueFromAtom: anytype,
    comptime defineFunctionNameProperty: anytype,
) !void {
    switch (opc) {
        op.set_name => {
            const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
            frame.pc += 4;
            if (stack.values.len == 0) return error.StackUnderflow;
            const value = try stackValueFromTop(stack, 0);
            defer value.free(ctx.runtime);
            if (value.isObject()) {
                const object = try property_ops.expectObject(value);
                const name_value = try functionNameValueFromAtom(ctx.runtime, atom_id, null);
                defer name_value.free(ctx.runtime);
                try defineFunctionNameProperty(ctx.runtime, object, name_value);
            }
        },
        op.set_name_computed => {
            if (stack.values.len < 2) return error.StackUnderflow;
            const value = stack.values[stack.values.len - 1].dup();
            defer value.free(ctx.runtime);
            const key = stack.values[stack.values.len - 2].dup();
            defer key.free(ctx.runtime);
            if (value.isObject()) {
                const object = try property_ops.expectObject(value);
                const atom_id = try toPropertyKeyAtom(ctx, output, global, key, function, frame);
                defer ctx.runtime.atoms.free(atom_id);
                const name_value = try functionNameValueFromAtom(ctx.runtime, atom_id, null);
                defer name_value.free(ctx.runtime);
                try defineFunctionNameProperty(ctx.runtime, object, name_value);
            }
        },
        else => unreachable,
    }
}

pub fn inOrInstanceof(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
    comptime inOp: anytype,
    comptime instanceofOp: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    const err = if (opc == op.in)
        inOp(ctx, stack, output, global, function, frame)
    else
        instanceofOp(ctx, stack, output, global, function, frame);
    err catch |runtime_err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, runtime_err)) return .continue_loop;
        return runtime_err;
    };
    return .done;
}

pub fn field(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    eval_with_object: core.JSValue,
    comptime getValueProperty: anytype,
    comptime setValueProperty: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
    comptime closeStackTopForOfIteratorForPendingError: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    switch (opc) {
        op.get_field => {
            const site_pc = frame.pc - 5;
            const obj = try stack.pop();
            defer obj.free(ctx.runtime);
            if (try tryFuseRegExpLiteralLastIndexZeroLoopFromField(ctx, global, function, frame, stack, obj, atom_id, site_pc, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
            if (dataPropertyValueForFastPath(function, site_pc, ctx.runtime, obj, atom_id)) |value| {
                try pushBorrowedValueOrFuseLocalAdd(ctx, stack, function, global, frame, value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
                return .done;
            }
            if (ordinaryDataPropertyValueOrUndefinedForFastPath(ctx.runtime, obj, atom_id)) |value| {
                try pushBorrowedValueOrFuseLocalAdd(ctx, stack, function, global, frame, value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
                return .done;
            }
            if (fastRegExpPrototypeMethodValue(ctx.runtime, obj, atom_id)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            if (functionOwnDataPropertyValueForFastPath(ctx.runtime, obj, atom_id)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            if (fastCollectionPrototypeMethodValue(ctx.runtime, obj, atom_id)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            const value = getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                try closeStackTopForOfIteratorForPendingError(ctx, output, global, stack, frame);
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            errdefer value.free(ctx.runtime);
            try stack.pushOwned(value);
        },
        op.get_field2 => {
            const site_pc = frame.pc - 5;
            const obj = try stackValueFromTop(stack, 0);
            defer obj.free(ctx.runtime);
            if (try tryFuseRegExpTestConstStringFromField2(ctx, function, frame, stack, obj, atom_id)) return .done;
            if (try tryFuseRegExpExecLengthLoopFromField2(ctx, output, global, function, frame, stack, obj, atom_id, site_pc, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
            if (try tryFuseRegExpExecCountLoopFromField2(ctx, output, global, function, frame, stack, obj, atom_id, site_pc, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
            if (try tryFuseRegExpExecCaptureLengthWhileLoopFromField2(ctx, output, global, function, frame, stack, obj, atom_id, site_pc, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
            if (try tryFuseRegExpExecCaptureLengthSumLoopFromField2(ctx, output, global, function, frame, stack, obj, atom_id, site_pc, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
            if (try tryFuseRegExpExecStringBindingFromField2(ctx, output, global, function, frame, stack, obj, atom_id, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
            if (try tryFuseDateNowCallFromField2(ctx, function, frame, stack, obj, atom_id, site_pc)) return .done;
            if (try tryFuseNumberStaticLiteralCallFromField2(ctx, output, function, frame, stack, obj, atom_id, site_pc)) return .done;
            if (try tryFuseMathMinMaxAddRangeFromField2(ctx, function, global, frame, stack, obj, atom_id, site_pc, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
            if (try tryFuseMathMinMaxPrimitiveCallFromField2(ctx, function, frame, stack, obj, atom_id)) return .done;
            if (try tryFuseStringFromCharCodeInt32CallFromField2(ctx, function, global, frame, stack, obj, atom_id, site_pc, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
            if (try tryFuseStringSliceConstLocalStoreFromField2(ctx, function, global, frame, stack, obj, atom_id, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
            if (try tryFuseArrayPushCallFromField2(ctx, function, global, frame, stack, obj, atom_id, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
            if (dataPropertyValueForFastPath(function, site_pc, ctx.runtime, obj, atom_id)) |value| {
                try stack.push(value);
                return .done;
            }
            if (ordinaryDataPropertyValueOrUndefinedForFastPath(ctx.runtime, obj, atom_id)) |value| {
                try stack.push(value);
                return .done;
            }
            if (fastRegExpPrototypeMethodValue(ctx.runtime, obj, atom_id)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            if (functionOwnDataPropertyValueForFastPath(ctx.runtime, obj, atom_id)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            if (fastCollectionPrototypeMethodValue(ctx.runtime, obj, atom_id)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            const value = getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                try closeStackTopForOfIteratorForPendingError(ctx, output, global, stack, frame);
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            errdefer value.free(ctx.runtime);
            try stack.pushOwned(value);
        },
        op.put_field => {
            const site_pc = frame.pc - 5;
            const value = try stack.pop();
            defer value.free(ctx.runtime);
            const obj = try stack.pop();
            defer obj.free(ctx.runtime);
            if (setArrayLengthForPutFieldFastPath(ctx.runtime, obj, atom_id, value)) return .done;
            if (try setObjectDataPropertyForPutFieldFastPath(ctx.runtime, function, site_pc, obj, atom_id, value)) return .done;
            const result = setValueProperty(ctx, output, global, obj, atom_id, value, function, frame) catch |err| {
                try closeStackTopForOfIteratorForPendingError(ctx, output, global, stack, frame);
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            result.free(ctx.runtime);
        },
        else => unreachable,
    }
    return .done;
}

fn setArrayLengthForPutFieldFastPath(
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
) bool {
    if (atom_id != core.atom.ids.length) return false;
    const length = value.asInt32() orelse return false;
    if (length < 0) return false;
    const object = objectFromValue(receiver) orelse return false;
    if (!object.is_array or object.exotic != null or object.proxyTarget() != null) return false;
    if (!object.length_writable) return false;
    const new_len: u32 = @intCast(length);
    if (new_len < object.length) {
        if (object.arrayElementStorageMode() != .dense) return false;
        for (object.properties) |entry| {
            if (entry.flags.deleted) continue;
            const index = core.array.arrayIndexFromAtom(&rt.atoms, entry.atom_id) orelse continue;
            if (index >= new_len) return false;
        }
        object.truncateArrayElements(rt, new_len);
    }
    object.length = new_len;
    return true;
}

fn tryFuseMathMinMaxPrimitiveCallFromField2(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    atom_id: core.Atom,
) !bool {
    const method = ownDataPropertyValueMaterializedForFastPath(ctx.runtime, receiver, atom_id) orelse return false;
    const method_object = objectFromValue(method) orelse return false;
    const native_ref = core.function.decodeNativeBuiltinId(method_object.nativeFunctionIdSlot().*) orelse return false;
    if (native_ref.domain != .math) return false;
    const is_max = switch (native_ref.id) {
        7 => false,
        8 => true,
        else => return false,
    };

    const arg0 = borrowedSimpleCallArg(frame, function, frame.pc) orelse return false;
    const arg1 = borrowedSimpleCallArg(frame, function, arg0.next_pc) orelse return false;
    const code = function.code;
    if (arg1.next_pc + 3 > code.len or code[arg1.next_pc] != op.call_method) return false;
    if (readInt(u16, code[arg1.next_pc + 1 ..][0..2]) != 2) return false;

    const result_number = mathMinMaxPrimitive2(arg0.value, arg1.value, is_max) orelse return false;
    const dropped_receiver = try stack.pop();
    dropped_receiver.free(ctx.runtime);
    const result = value_ops.numberToValue(result_number);
    errdefer result.free(ctx.runtime);
    try stack.pushOwned(result);
    frame.pc = arg1.next_pc + 3;
    return true;
}

fn tryFuseMathMinMaxAddRangeFromField2(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    atom_id: core.Atom,
    site_pc: usize,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (ctx.runtime.hasInterruptHandler()) return false;
    if (site_pc < 11) return false;
    const code = function.code;
    const condition_pc = site_pc - 11;
    const body_pc = site_pc - 6;
    const condition_get = decodeLocalGet(code, condition_pc) orelse return false;
    if (condition_get.idx != 1) return false;
    if (condition_get.next_pc != condition_pc + 1) return false;

    const limit_get = decodeLoopLimitGet(code, condition_get.next_pc) orelse return false;
    switch (limit_get.limit) {
        .binding => |binding| if (binding.idx == 0 or binding.idx == condition_get.idx) return false,
        .immediate, .arg => {},
    }
    if (limit_get.next_pc >= code.len or code[limit_get.next_pc] != op.lt) return false;
    const exit_branch = decodeFalseBranch(code, limit_get.next_pc + 1) orelse return false;
    if (exit_branch.true_pc != body_pc) return false;

    const accumulator_get = decodeLocalGet(code, body_pc) orelse return false;
    if (accumulator_get.idx != 0) return false;
    if (accumulator_get.next_pc + 5 != site_pc) return false;
    const global_op = code[accumulator_get.next_pc];
    if (global_op != op.get_var and global_op != op.get_var_undef) return false;
    const global_atom = readInt(u32, code[accumulator_get.next_pc + 1 ..][0..4]);
    if (global_atom != atom_math) return false;

    const native_ref = mathMinMaxNativeRefFromReceiver(ctx.runtime, receiver, atom_id) orelse return false;
    const is_max = switch (native_ref.id) {
        7 => false,
        8 => true,
        else => return false,
    };

    const args = parseInductionAndImmediateInt32ArgsUnchecked(code, frame.pc, condition_get.idx) orelse return false;
    const call_pc = args.next_pc;
    if (call_pc + 4 > code.len or code[call_pc] != op.call_method) return false;
    if (readInt(u16, code[call_pc + 1 ..][0..2]) != 2) return false;
    const add_pc = call_pc + 3;
    if (add_pc >= code.len or code[add_pc] != op.add) return false;
    const accumulator_put = decodeLocalPut(code, add_pc + 1) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx) return false;
    if (accumulator_put.idx < function.var_is_const.len and function.var_is_const[accumulator_put.idx]) return false;

    const tail_get = decodeLocalGet(code, accumulator_put.operand_pc + accumulator_put.consume) orelse return false;
    if (tail_get.idx != condition_get.idx) return false;
    if (tail_get.next_pc >= code.len or code[tail_get.next_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_get.next_pc + 1) orelse return false;
    if (tail_put.idx != condition_get.idx) return false;
    if (tail_put.idx < function.var_is_const.len and function.var_is_const[tail_put.idx]) return false;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return false;
    if (goto_operand_pc + 1 != exit_branch.false_pc) return false;

    if (frame.locals.len < 2 or frame.locals_uninit.len < 2) return false;
    if (frame.localIsUninitialized(0) or frame.localIsUninitialized(condition_get.idx)) return false;
    const current_i = slotValueBorrowed(frame.locals[condition_get.idx]).asInt32() orelse return false;
    const limit = loopLimitReadableInt32(frame, limit_get.limit) orelse return false;
    if (current_i >= limit) return false;

    const accumulator = slotValueBorrowed(frame.locals[0]).asInt32() orelse return false;
    const total_delta = mathMinMaxInductionRangeSum(current_i, limit, args.immediate, is_max);
    const final_accumulator = @as(i128, accumulator) + total_delta;
    if (final_accumulator < std.math.minInt(i32) or final_accumulator > std.math.maxInt(i32)) return false;

    const dropped_receiver = try stack.pop();
    dropped_receiver.free(ctx.runtime);
    const dropped_accumulator = try stack.pop();
    dropped_accumulator.free(ctx.runtime);
    try setSlotValue(ctx, &frame.locals[0], core.JSValue.int32(@intCast(final_accumulator)));
    try setSlotValue(ctx, &frame.locals[condition_get.idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, 0, sync_global_lexical_locals);
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, condition_get.idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

fn mathMinMaxNativeRefFromReceiver(rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom) ?core.function.NativeBuiltinRef {
    const method = ownDataPropertyValueMaterializedForFastPath(rt, receiver, atom_id) orelse return null;
    const method_object = objectFromValue(method) orelse return null;
    const native_ref = core.function.decodeNativeBuiltinId(method_object.nativeFunctionIdSlot().*) orelse return null;
    return if (native_ref.domain == .math) native_ref else null;
}

fn tryFuseStringFromCharCodeInt32CallFromField2(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    atom_id: core.Atom,
    site_pc: usize,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const native_ref = functionOwnNativeBuiltinRefForFastPath(function, site_pc, ctx.runtime, receiver, atom_id) orelse return false;
    if (native_ref.domain != .string or native_ref.id != @intFromEnum(builtins.string.StaticMethod.from_char_code)) return false;

    const argument = stringFromCharCodeInt32Arg(function, frame, frame.pc) orelse return false;
    const code = function.code;
    if (argument.next_pc + 3 > code.len or code[argument.next_pc] != op.call_method) return false;
    if (readInt(u16, code[argument.next_pc + 1 ..][0..2]) != 1) return false;

    if (try tryFuseStringFromCharCodeInt32LocalAppend(ctx, function, global, frame, stack, argument.value, argument.next_pc + 3, true, false, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;

    const dropped_receiver = try stack.pop();
    dropped_receiver.free(ctx.runtime);
    const result = try stringFromCharCodeInt32Value(ctx.runtime, argument.value);
    errdefer result.free(ctx.runtime);
    try stack.pushOwned(result);
    frame.pc = argument.next_pc + 3;
    return true;
}

fn tryFuseStringSliceConstLocalStoreFromField2(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    atom_id: core.Atom,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const decoded = decodeStringSliceConstLocalStore(ctx, function, global, frame, receiver, atom_id, frame.pc) orelse return false;
    if (stack.values.len == 0) return false;
    try storeStringSliceConstLocal(ctx, function, global, frame, receiver, decoded, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    const receiver_owned = try stack.pop();
    receiver_owned.free(ctx.runtime);
    return true;
}

fn stringFromCharCodeInt32Value(rt: *core.JSRuntime, code: i32) !core.JSValue {
    const unit: u16 = @intCast(@as(u32, @bitCast(code)) & 0xffff);
    if (unit <= 0xff) {
        const byte: u8 = @intCast(unit);
        if (try rt.singleByteString(byte)) |cached| return cached.value().dup();
        return (try core.string.String.createAscii(rt, &.{byte})).value();
    }
    return (try core.string.String.createUtf16(rt, &.{unit})).value();
}

fn tryFuseDateNowCallFromField2(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    atom_id: core.Atom,
    site_pc: usize,
) !bool {
    const pc = frame.pc;
    if (pc + 3 > function.code.len or function.code[pc] != op.call_method) return false;
    if (readInt(u16, function.code[pc + 1 ..][0..2]) != 0) return false;

    const native_ref = functionOwnNativeBuiltinRefForFastPath(function, site_pc, ctx.runtime, receiver, atom_id) orelse return false;
    if (native_ref.domain != .date or native_ref.id != @intFromEnum(builtins.date.StaticMethod.now)) return false;

    const dropped_receiver = try stack.pop();
    dropped_receiver.free(ctx.runtime);
    const result = try builtins.date.staticCall(ctx.runtime, native_ref.id, &.{});
    errdefer result.free(ctx.runtime);
    try stack.pushOwned(result);
    frame.pc = pc + 3;
    return true;
}

fn tryFuseNumberStaticLiteralCallFromField2(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    atom_id: core.Atom,
    site_pc: usize,
) !bool {
    const pc = frame.pc;
    const native_ref = functionOwnNativeBuiltinRefForFastPath(function, site_pc, ctx.runtime, receiver, atom_id) orelse return false;
    if (native_ref.domain != .number) return false;

    const code = function.code;
    const number_mod = builtins.number;
    var call_end_pc: usize = undefined;
    const result_number = switch (native_ref.id) {
        @intFromEnum(number_mod.StaticMethod.parse_int) => blk: {
            if (pc + 5 > code.len or code[pc] != op.push_atom_value) return false;
            const string_atom = readInt(u32, code[pc + 1 ..][0..4]);
            var atom_buf: [10]u8 = undefined;
            const text = atomAsciiText(ctx.runtime, string_atom, &atom_buf) orelse return false;
            const radix_operand = immediateInt32Operand(code, pc + 5) orelse return false;
            if (radix_operand.next_pc + 3 > code.len or code[radix_operand.next_pc] != op.call_method) return false;
            if (readInt(u16, code[radix_operand.next_pc + 1 ..][0..2]) != 2) return false;
            call_end_pc = radix_operand.next_pc + 3;
            break :blk number_mod.parseIntLatin1Bytes(text, radix_operand.value);
        },
        @intFromEnum(number_mod.StaticMethod.parse_float) => blk: {
            if (pc + 8 > code.len or code[pc] != op.push_atom_value) return false;
            const string_atom = readInt(u32, code[pc + 1 ..][0..4]);
            var atom_buf: [10]u8 = undefined;
            const text = atomAsciiText(ctx.runtime, string_atom, &atom_buf) orelse return false;
            const call_pc = pc + 5;
            if (code[call_pc] != op.call_method) return false;
            if (readInt(u16, code[call_pc + 1 ..][0..2]) != 1) return false;
            call_end_pc = call_pc + 3;
            break :blk number_mod.parseFloatLatin1Bytes(text);
        },
        else => return false,
    };

    const dropped_receiver = try stack.pop();
    dropped_receiver.free(ctx.runtime);
    const result = value_ops.numberToValue(result_number);
    errdefer result.free(ctx.runtime);
    if (call_end_pc < code.len and code[call_end_pc] == op.call1 and stack.values.len >= 1) {
        const outer_callee = try stackValueFromTop(stack, 0);
        defer outer_callee.free(ctx.runtime);
        if (isHostOutputFunctionValue(ctx.runtime, outer_callee)) {
            const dropped_callee = try stack.pop();
            dropped_callee.free(ctx.runtime);
            defer result.free(ctx.runtime);
            try shared_vm.printHostOutputArgs(ctx.runtime, output, &.{result});
            try finishUndefinedCallResult(stack, function, frame, call_end_pc + 1);
            return true;
        }
    }
    try stack.pushOwned(result);
    frame.pc = call_end_pc;
    return true;
}

pub fn arrayElement(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
    sync_global_lexical_locals: bool,
    comptime toPropertyKeyAtom: anytype,
    comptime toPropertyKeyValue: anytype,
    comptime getValueProperty: anytype,
    comptime setValueProperty: anytype,
    comptime putDenseArrayElementFast: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
    comptime throwNullishComputedPropertyTypeError: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    switch (opc) {
        op.get_array_el => {
            const key = try stack.pop();
            defer key.free(ctx.runtime);
            const obj = try stack.pop();
            defer obj.free(ctx.runtime);
            if (obj.isNull() or obj.isUndefined()) {
                _ = throwNullishComputedPropertyTypeError(ctx, global, obj, key) catch |err| {
                    if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
                unreachable;
            }
            if (fastDenseArrayElementValue(obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                if (try tryFuseLocalAddWithValue(ctx, stack, function, global, frame, value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) {
                    value.free(ctx.runtime);
                    return .done;
                }
                try stack.pushOwned(value);
                return .done;
            }
            if (fastStringIndexValue(ctx.runtime, obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                if (try tryFuseLocalAddWithValue(ctx, stack, function, global, frame, value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) {
                    value.free(ctx.runtime);
                    return .done;
                }
                try stack.pushOwned(value);
                return .done;
            }
            if (fastInt32TypedArrayElementValue(obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                if (try tryFuseLocalAddWithValue(ctx, stack, function, global, frame, value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) {
                    value.free(ctx.runtime);
                    return .done;
                }
                try stack.pushOwned(value);
                return .done;
            }
            const atom_id = toPropertyKeyAtom(ctx, output, global, key, function, frame) catch |err| {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            defer ctx.runtime.atoms.free(atom_id);
            const value = getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            errdefer value.free(ctx.runtime);
            try stack.pushOwned(value);
        },
        op.get_array_el2 => {
            const key = try stackValueFromTop(stack, 0);
            defer key.free(ctx.runtime);
            const obj = try stackValueFromTop(stack, 1);
            defer obj.free(ctx.runtime);
            if (obj.isNull() or obj.isUndefined()) {
                _ = throwNullishComputedPropertyTypeError(ctx, global, obj, key) catch |err| {
                    if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
                unreachable;
            }
            if (fastDenseArrayElementValue(obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                const old_value = stack.values[stack.values.len - 1];
                stack.values[stack.values.len - 1] = value;
                old_value.free(ctx.runtime);
                return .done;
            }
            if (fastStringIndexValue(ctx.runtime, obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                const old_value = stack.values[stack.values.len - 1];
                stack.values[stack.values.len - 1] = value;
                old_value.free(ctx.runtime);
                return .done;
            }
            if (fastInt32TypedArrayElementValue(obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                const old_value = stack.values[stack.values.len - 1];
                stack.values[stack.values.len - 1] = value;
                old_value.free(ctx.runtime);
                return .done;
            }
            const key_value = toPropertyKeyValue(ctx, output, global, key, function, frame) catch |err| {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            defer key_value.free(ctx.runtime);
            const atom_id = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
            defer ctx.runtime.atoms.free(atom_id);
            const value = getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            errdefer value.free(ctx.runtime);
            const old_value = stack.values[stack.values.len - 1];
            stack.values[stack.values.len - 1] = value;
            old_value.free(ctx.runtime);
        },
        op.put_array_el => {
            const value = try stack.pop();
            defer value.free(ctx.runtime);
            const key = try stack.pop();
            defer key.free(ctx.runtime);
            const obj = try stack.pop();
            defer obj.free(ctx.runtime);
            if (obj.isNull() or obj.isUndefined()) {
                _ = throwNullishComputedPropertyTypeError(ctx, global, obj, key) catch |err| {
                    if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
                unreachable;
            }
            if (try putInt32TypedArrayElementFast(ctx.runtime, obj, key, value)) return .continue_loop;
            if (try putDenseArrayElementFast(ctx.runtime, obj, key, value)) return .continue_loop;
            const key_value = toPropertyKeyValue(ctx, output, global, key, function, frame) catch |err| {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            defer key_value.free(ctx.runtime);
            if (try putDenseArrayElementFast(ctx.runtime, obj, key_value, value)) return .continue_loop;
            const atom_id = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
            defer ctx.runtime.atoms.free(atom_id);
            const result = setValueProperty(ctx, output, global, obj, atom_id, value, function, frame) catch |err| {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            result.free(ctx.runtime);
        },
        else => unreachable,
    }
    return .done;
}

fn fastInt32TypedArrayElementValue(obj: core.JSValue, key: core.JSValue) ?core.JSValue {
    const object = objectFromValue(obj) orelse return null;
    const key_int = key.asInt32() orelse return null;
    if (key_int < 0) return null;
    if (object.typedArrayKind() != 6 or object.typedArrayElementSize() != 4) return null;
    const fixed_len = object.typedArrayFixedLength() orelse return null;
    const buffer_value = object.typedArrayBuffer() orelse return null;
    const buffer = objectFromValue(buffer_value) orelse return null;
    if (buffer.class_id != core.class.ids.array_buffer and buffer.class_id != core.class.ids.shared_array_buffer) return null;
    if (buffer.arrayBufferDetached()) return core.JSValue.undefinedValue();

    const bytes = buffer.byteStorage();
    const byte_offset = object.typedArrayByteOffset();
    if (byte_offset > bytes.len) return core.JSValue.undefinedValue();
    const byte_len = std.math.mul(usize, @as(usize, fixed_len), @as(usize, 4)) catch return null;
    if (byte_len > bytes.len - byte_offset) return core.JSValue.undefinedValue();
    const index: u32 = @intCast(key_int);
    if (index >= fixed_len) return core.JSValue.undefinedValue();
    const offset = byte_offset + @as(usize, index) * 4;
    return core.JSValue.int32(std.mem.readInt(i32, bytes[offset..][0..4], .little));
}

fn putInt32TypedArrayElementFast(rt: *core.JSRuntime, obj: core.JSValue, key: core.JSValue, value: core.JSValue) !bool {
    _ = rt;
    const object = objectFromValue(obj) orelse return false;
    const key_int = key.asInt32() orelse return false;
    if (key_int < 0) return false;
    const value_int = value.asInt32() orelse return false;
    if (object.typedArrayKind() != 6 or object.typedArrayElementSize() != 4) return false;
    const fixed_len = object.typedArrayFixedLength() orelse return false;
    const buffer_value = object.typedArrayBuffer() orelse return false;
    const buffer = objectFromValue(buffer_value) orelse return false;
    if (buffer.class_id != core.class.ids.array_buffer and buffer.class_id != core.class.ids.shared_array_buffer) return false;
    if (buffer.arrayBufferImmutable()) return false;
    if (buffer.arrayBufferDetached()) return true;

    const bytes = buffer.byteStorage();
    const byte_offset = object.typedArrayByteOffset();
    if (byte_offset > bytes.len) return true;
    const byte_len = std.math.mul(usize, @as(usize, fixed_len), @as(usize, 4)) catch return false;
    if (byte_len > bytes.len - byte_offset) return true;
    const index: u32 = @intCast(key_int);
    if (index >= fixed_len) return true;
    const offset = byte_offset + @as(usize, index) * 4;
    std.mem.writeInt(i32, bytes[offset..][0..4], value_int, .little);
    return true;
}

fn tryFuseRegExpTestConstStringFromField2(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    method_atom: core.Atom,
) !bool {
    if (!value_ops.atomNameEql(ctx.runtime, method_atom, "test")) return false;
    const code = function.code;
    const pc = frame.pc;
    if (pc + 8 > code.len) return false;
    if (code[pc] != op.push_atom_value) return false;
    const input_atom = readInt(u32, code[pc + 1 ..][0..4]);
    if (code[pc + 5] != op.call_method or readInt(u16, code[pc + 6 ..][0..2]) != 1) return false;

    const regexp_object = objectFromValue(receiver) orelse return false;
    if (regexp_object.class_id != core.class.ids.regexp) return false;
    if (!fastRegExpPrototypeMethodIsDefault(ctx.runtime, receiver, method_atom, @intFromEnum(builtins.regexp.PrototypeMethod.test_))) return false;

    const input_value = (try atomStringValueForFastPath(ctx.runtime, input_atom)) orelse return false;
    defer input_value.free(ctx.runtime);
    const matched = try shared_vm.qjsRegExpTestFastNoResult(ctx, regexp_object, input_value) orelse return false;

    const stacked_receiver = try stack.pop();
    stacked_receiver.free(ctx.runtime);
    const next_pc = pc + 8;
    if (tryFuseBooleanIfFalseBranch(function, frame, next_pc, matched)) return true;
    try stack.pushOwned(core.JSValue.boolean(matched));
    frame.pc = next_pc;
    return true;
}

fn tryFuseArrayPushCallFromField2(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    method_atom: core.Atom,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!value_ops.atomNameEql(ctx.runtime, method_atom, "push")) return false;
    if (!fastArrayPrototypeMethodIsDefault(receiver, method_atom, @intFromEnum(builtins.array.PrototypeMethod.push))) return false;

    const object = objectFromValue(receiver) orelse return false;
    if (object.proxyTarget() != null or object.exotic != null) return false;
    if (object.length >= core.array.max_array_length) return false;

    const code = function.code;
    const call_arg = borrowedSimpleCallArg(frame, function, frame.pc) orelse return false;
    const call_pc = call_arg.next_pc;
    if (call_pc + 3 > code.len or code[call_pc] != op.call_method) return false;
    if (readInt(u16, code[call_pc + 1 ..][0..2]) != 1) return false;

    const index = object.length;
    if (!try object.appendDenseArrayIndex(ctx.runtime, index, core.atom.atomFromUInt32(index), call_arg.value)) return false;
    const result = shared_vm.lengthIndexValue(index + 1);

    const stacked_receiver = try stack.pop();
    stacked_receiver.free(ctx.runtime);

    const after_call_pc = call_pc + 3;
    if (decodeOptionalLocalCompletionTail(function, frame, after_call_pc)) |completion_tail| {
        try storeLocalCompletionBorrowedValue(ctx, function, global, frame, completion_tail.completion_put, result, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
        frame.pc = completion_tail.tail_pc;
        return true;
    }

    try stack.pushOwned(result);
    frame.pc = after_call_pc;
    return true;
}

const RegExpLiteralLastIndexZeroLoop = struct {
    regexp_put: RegExpLoopPut,
    accumulator_get: RegExpLoopGet,
    accumulator_put: RegExpLoopPut,
    induction_get: RegExpLoopGet,
    induction_put: RegExpLoopPut,
    limit: i32,
    false_pc: usize,
};

fn tryFuseRegExpLiteralLastIndexZeroLoopFromField(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    atom_id: core.Atom,
    field_pc: usize,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    eval_with_object: core.JSValue,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (atom_id != core.atom.ids.lastIndex) return false;
    const regexp_object = objectFromValue(receiver) orelse return false;
    if (regexp_object.class_id != core.class.ids.regexp) return false;
    const last_index = regexp_object.regexpLastIndex() orelse return false;
    if ((last_index.asInt32() orelse return false) != 0) return false;

    const loop = decodeRegExpLiteralLastIndexZeroLoop(function.code, frame.pc, field_pc) orelse return false;
    if (!regExpMatchStoreWritableForFastPath(ctx, function, global, frame, loop.regexp_put, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object)) return false;
    if (!regExpMatchStoreWritableForFastPath(ctx, function, global, frame, loop.accumulator_put, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object)) return false;
    if (!regExpMatchStoreWritableForFastPath(ctx, function, global, frame, loop.induction_put, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object)) return false;

    const regexp_get: RegExpLoopGet = switch (loop.regexp_put) {
        .binding => |put| .{ .binding = .{ .idx = put.idx, .next_pc = 0, .is_var_ref = put.is_var_ref, .checked = put.checked } },
        .global => |put| .{ .global = .{ .atom = put.atom, .next_pc = 0 } },
    };
    const stored_receiver = regExpLoopReadableBorrowed(ctx, function, global, frame, regexp_get, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object) orelse return false;
    if (!stored_receiver.same(receiver)) return false;

    const accumulator_stack = stack.peekBorrowed() orelse return false;
    if (accumulator_stack.asInt32() == null) return false;
    const accumulator_value = regExpLoopReadableBorrowed(ctx, function, global, frame, loop.accumulator_get, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object) orelse return false;
    if (!accumulator_value.same(accumulator_stack)) return false;
    const induction_value = regExpLoopReadableBorrowed(ctx, function, global, frame, loop.induction_get, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object) orelse return false;
    const induction = induction_value.asInt32() orelse return false;
    if (induction >= loop.limit) return false;

    const dropped_accumulator = try stack.pop();
    dropped_accumulator.free(ctx.runtime);
    try storeRegExpLoopOwnedValue(ctx, function, global, frame, loop.induction_put, core.JSValue.int32(loop.limit), sync_global_lexical_locals, eval_var_ref_names, eval_var_refs, setSlotValue, syncTopLevelGlobalLexicalLocal);
    frame.pc = loop.false_pc;
    return true;
}

fn decodeRegExpLiteralLastIndexZeroLoop(code: []const u8, after_field_pc: usize, field_pc: usize) ?RegExpLiteralLastIndexZeroLoop {
    if (after_field_pc >= code.len or code[after_field_pc] != op.add) return null;
    var accumulator_put_pc = after_field_pc + 1;
    var accumulator_drop_pc: ?usize = null;
    if (accumulator_put_pc < code.len and code[accumulator_put_pc] == op.dup) {
        accumulator_put_pc += 1;
        const candidate_put = decodeRegExpMatchPut(code, accumulator_put_pc) orelse return null;
        const candidate_drop_pc = regExpMatchPutNextPc(candidate_put);
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return null;
        accumulator_drop_pc = candidate_drop_pc;
    }
    const accumulator_put = decodeRegExpMatchPut(code, accumulator_put_pc) orelse return null;
    const after_accumulator_put = if (accumulator_drop_pc) |drop_pc| drop_pc + 1 else regExpMatchPutNextPc(accumulator_put);
    const induction_get = decodeRegExpMatchGet(code, after_accumulator_put) orelse return null;
    const post_inc_pc = regExpMatchGetNextPc(induction_get);
    if (post_inc_pc >= code.len or code[post_inc_pc] != op.post_inc) return null;
    const induction_put = decodeRegExpMatchPut(code, post_inc_pc + 1) orelse return null;
    if (!sameRegExpMatchGetPut(induction_get, induction_put)) return null;
    const after_induction_put = regExpMatchPutNextPc(induction_put);
    if (after_induction_put >= code.len or code[after_induction_put] != op.drop) return null;
    const condition_pc = decodeGotoTarget(code, after_induction_put + 1) orelse return null;

    const condition_get = decodeRegExpMatchGet(code, condition_pc) orelse return null;
    if (!sameRegExpMatchGet(condition_get, induction_get)) return null;
    const limit_operand = immediateInt32Operand(code, regExpMatchGetNextPc(condition_get)) orelse return null;
    if (limit_operand.next_pc >= code.len or code[limit_operand.next_pc] != op.lt) return null;
    const branch = decodeFalseBranch(code, limit_operand.next_pc + 1) orelse return null;
    const literal_pc = branch.true_pc;

    if (literal_pc + 6 > code.len or code[literal_pc] != op.push_atom_value) return null;
    const flags_pc = literal_pc + 5;
    const regexp_pc = switch (code[flags_pc]) {
        op.push_atom_value => blk: {
            if (flags_pc + 6 > code.len or code[flags_pc + 5] != op.regexp) return null;
            break :blk flags_pc + 5;
        },
        op.push_empty_string => blk: {
            if (flags_pc + 2 > code.len or code[flags_pc + 1] != op.regexp) return null;
            break :blk flags_pc + 1;
        },
        else => return null,
    };
    const regexp_put = decodeRegExpMatchPut(code, regexp_pc + 1) orelse return null;
    const accumulator_get = decodeRegExpMatchGet(code, regExpMatchPutNextPc(regexp_put)) orelse return null;
    if (!sameRegExpMatchGetPut(accumulator_get, accumulator_put)) return null;
    const regexp_get = decodeRegExpMatchGet(code, regExpMatchGetNextPc(accumulator_get)) orelse return null;
    if (regExpMatchGetNextPc(regexp_get) != field_pc) return null;
    if (!sameRegExpMatchGetPut(regexp_get, regexp_put)) return null;
    if (sameRegExpMatchGet(accumulator_get, induction_get)) return null;
    if (regExpLoopGetConflictsWithMatchPut(accumulator_get, regexp_put)) return null;
    if (regExpLoopGetConflictsWithMatchPut(induction_get, regexp_put)) return null;

    return .{
        .regexp_put = regexp_put,
        .accumulator_get = accumulator_get,
        .accumulator_put = accumulator_put,
        .induction_get = induction_get,
        .induction_put = induction_put,
        .limit = limit_operand.value,
        .false_pc = branch.false_pc,
    };
}

fn decodeRegExpExecLengthLoop(code: []const u8, pc: usize) ?RegExpExecLengthLoop {
    const input_get = decodeRegExpMatchGet(code, pc) orelse return null;
    const call_pc = regExpMatchGetNextPc(input_get);
    if (call_pc + 3 > code.len or code[call_pc] != op.call_method or readInt(u16, code[call_pc + 1 ..][0..2]) != 1) return null;
    const after_call_pc = call_pc + 3;
    var ref_assignment = false;
    var match_put: ?RegExpMatchPut = null;
    const after_match_put = blk: {
        if (after_call_pc < code.len and code[after_call_pc] == op.dup) {
            const put = decodeRegExpMatchPut(code, after_call_pc + 1) orelse return null;
            match_put = put;
            break :blk regExpMatchPutNextPc(put);
        }
        if (after_call_pc + 2 <= code.len and code[after_call_pc] == op.insert3 and code[after_call_pc + 1] == op.put_ref_value) {
            ref_assignment = true;
            break :blk after_call_pc + 2;
        }
        return null;
    };
    if (after_match_put + 2 > code.len or code[after_match_put] != op.null or code[after_match_put + 1] != op.strict_neq) return null;
    const branch = decodeFalseBranch(code, after_match_put + 2) orelse return null;

    const accumulator_get = decodeRegExpMatchGet(code, branch.true_pc) orelse return null;
    const match_get = decodeRegExpMatchGet(code, regExpMatchGetNextPc(accumulator_get)) orelse return null;
    if (ref_assignment) {
        match_put = switch (match_get) {
            .global => |global_get| .{ .global = .{ .atom = global_get.atom, .next_pc = 0 } },
            .binding => return null,
        };
    }
    const resolved_match_put = match_put orelse return null;
    if (!sameRegExpMatchGetPut(match_get, resolved_match_put)) return null;
    if (regExpLoopGetConflictsWithMatchPut(input_get, resolved_match_put)) return null;
    if (regExpLoopGetConflictsWithMatchPut(accumulator_get, resolved_match_put)) return null;
    if (sameRegExpMatchGet(input_get, accumulator_get)) return null;
    var scan = regExpMatchGetNextPc(match_get);
    if (scan + 4 > code.len or code[scan] != op.push_0 or code[scan + 1] != op.get_array_el or code[scan + 2] != op.get_length or code[scan + 3] != op.add) return null;
    scan += 4;
    var drop_pc: ?usize = null;
    if (scan < code.len and code[scan] == op.dup) {
        scan += 1;
        const candidate_put = decodeRegExpMatchPut(code, scan) orelse return null;
        const candidate_drop_pc = regExpMatchPutNextPc(candidate_put);
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return null;
        drop_pc = candidate_drop_pc;
    }
    const accumulator_put = decodeRegExpMatchPut(code, scan) orelse return null;
    if (!sameRegExpMatchGetPut(accumulator_get, accumulator_put)) return null;
    const goto_pc = if (drop_pc) |drop| drop + 1 else regExpMatchPutNextPc(accumulator_put);
    const success_pc = decodeGotoTarget(code, goto_pc) orelse return null;
    var receiver_pc = success_pc;
    if (ref_assignment) {
        const ref_get = decodeMakeVarRef(code, success_pc) orelse return null;
        const global_put = switch (resolved_match_put) {
            .global => |global| global,
            .binding => return null,
        };
        if (ref_get.atom != global_put.atom) return null;
        receiver_pc = ref_get.next_pc;
    }
    return .{
        .input_get = input_get,
        .match_put = resolved_match_put,
        .accumulator_get = accumulator_get,
        .accumulator_put = accumulator_put,
        .success_pc = success_pc,
        .false_pc = branch.false_pc,
        .receiver_pc = receiver_pc,
        .stack_drop_count = if (ref_assignment) 3 else 1,
    };
}

fn decodeRegExpExecLoopCallPrefix(code: []const u8, pc: usize) ?struct {
    input_get: RegExpLoopGet,
    match_put: ?RegExpMatchPut,
    branch: DecodedFalseBranch,
    ref_assignment: bool,
    stack_drop_count: u8,
} {
    const input_get = decodeRegExpMatchGet(code, pc) orelse return null;
    const call_pc = regExpMatchGetNextPc(input_get);
    if (call_pc + 3 > code.len or code[call_pc] != op.call_method or readInt(u16, code[call_pc + 1 ..][0..2]) != 1) return null;
    const after_call_pc = call_pc + 3;
    var ref_assignment = false;
    var match_put: ?RegExpMatchPut = null;
    const after_match_put = blk: {
        if (after_call_pc < code.len and code[after_call_pc] == op.dup) {
            const put = decodeRegExpMatchPut(code, after_call_pc + 1) orelse return null;
            match_put = put;
            break :blk regExpMatchPutNextPc(put);
        }
        if (after_call_pc + 2 <= code.len and code[after_call_pc] == op.insert3 and code[after_call_pc + 1] == op.put_ref_value) {
            ref_assignment = true;
            break :blk after_call_pc + 2;
        }
        return null;
    };
    if (after_match_put + 2 > code.len or code[after_match_put] != op.null or code[after_match_put + 1] != op.strict_neq) return null;
    const branch = decodeFalseBranch(code, after_match_put + 2) orelse return null;

    return .{
        .input_get = input_get,
        .match_put = match_put,
        .branch = branch,
        .ref_assignment = ref_assignment,
        .stack_drop_count = if (ref_assignment) 3 else 1,
    };
}

fn decodeRegExpLoopReceiverPcForTail(code: []const u8, success_pc: usize, match_put: RegExpMatchPut, stack_drop_count: u8) ?usize {
    if (stack_drop_count == 3) {
        const ref_get = decodeMakeVarRef(code, success_pc) orelse return null;
        const global_put = switch (match_put) {
            .global => |global| global,
            .binding => return null,
        };
        if (ref_get.atom != global_put.atom) return null;
        return ref_get.next_pc;
    }
    return success_pc;
}

fn decodeRegExpExecCountLoop(code: []const u8, pc: usize) ?RegExpExecCountLoop {
    const prefix = decodeRegExpExecLoopCallPrefix(code, pc) orelse return null;
    var match_put = prefix.match_put;
    const accumulator_get = decodeRegExpMatchGet(code, prefix.branch.true_pc) orelse return null;
    if (sameRegExpMatchGet(prefix.input_get, accumulator_get)) return null;

    const post_inc_pc = regExpMatchGetNextPc(accumulator_get);
    if (post_inc_pc >= code.len or code[post_inc_pc] != op.post_inc) return null;
    const accumulator_put = decodeRegExpMatchPut(code, post_inc_pc + 1) orelse return null;
    if (!sameRegExpMatchGetPut(accumulator_get, accumulator_put)) return null;
    const drop_pc = regExpMatchPutNextPc(accumulator_put);
    if (drop_pc >= code.len or code[drop_pc] != op.drop) return null;
    const success_pc = decodeGotoTarget(code, drop_pc + 1) orelse return null;
    if (prefix.ref_assignment) {
        const ref_get = decodeMakeVarRef(code, success_pc) orelse return null;
        match_put = .{ .global = .{ .atom = ref_get.atom, .next_pc = 0 } };
    }
    const resolved_match_put = match_put orelse return null;
    if (sameRegExpMatchGetPut(accumulator_get, resolved_match_put)) return null;
    if (regExpLoopGetConflictsWithMatchPut(prefix.input_get, resolved_match_put)) return null;
    const receiver_pc = decodeRegExpLoopReceiverPcForTail(code, success_pc, resolved_match_put, prefix.stack_drop_count) orelse return null;

    return .{
        .input_get = prefix.input_get,
        .match_put = resolved_match_put,
        .accumulator_get = accumulator_get,
        .accumulator_put = accumulator_put,
        .success_pc = success_pc,
        .false_pc = prefix.branch.false_pc,
        .receiver_pc = receiver_pc,
        .stack_drop_count = prefix.stack_drop_count,
    };
}

fn decodeRegExpCaptureLengthTerm(code: []const u8, pc: usize, match_put: RegExpMatchPut) ?struct { capture_index: u8, next_pc: usize } {
    const match_get = decodeRegExpMatchGet(code, pc) orelse return null;
    if (!sameRegExpMatchGetPut(match_get, match_put)) return null;
    const index_value = immediateInt32Operand(code, regExpMatchGetNextPc(match_get)) orelse return null;
    if (index_value.value < 0 or index_value.value > 255) return null;
    if (index_value.next_pc + 2 > code.len or code[index_value.next_pc] != op.get_array_el or code[index_value.next_pc + 1] != op.get_length) return null;
    return .{ .capture_index = @intCast(index_value.value), .next_pc = index_value.next_pc + 2 };
}

fn decodeRegExpCaptureLengthTermAny(code: []const u8, pc: usize) ?struct { match_get: RegExpMatchGet, capture_index: u8, next_pc: usize } {
    const match_get = decodeRegExpMatchGet(code, pc) orelse return null;
    const index_value = immediateInt32Operand(code, regExpMatchGetNextPc(match_get)) orelse return null;
    if (index_value.value < 0 or index_value.value > 255) return null;
    if (index_value.next_pc + 2 > code.len or code[index_value.next_pc] != op.get_array_el or code[index_value.next_pc + 1] != op.get_length) return null;
    return .{ .match_get = match_get, .capture_index = @intCast(index_value.value), .next_pc = index_value.next_pc + 2 };
}

fn decodeRegExpExecCaptureLengthWhileLoop(code: []const u8, pc: usize) ?RegExpExecCaptureLengthWhileLoop {
    const prefix = decodeRegExpExecLoopCallPrefix(code, pc) orelse return null;
    var match_put = prefix.match_put;
    const accumulator_get = decodeRegExpMatchGet(code, prefix.branch.true_pc) orelse return null;
    if (sameRegExpMatchGet(prefix.input_get, accumulator_get)) return null;

    var capture_indexes: [8]u8 = undefined;
    var capture_count: usize = 0;
    var scan = regExpMatchGetNextPc(accumulator_get);
    if (match_put == null) {
        const first = decodeRegExpCaptureLengthTermAny(code, scan) orelse return null;
        const global_get = switch (first.match_get) {
            .global => |global| global,
            .binding => return null,
        };
        match_put = .{ .global = .{ .atom = global_get.atom, .next_pc = 0 } };
        capture_indexes[capture_count] = first.capture_index;
        scan = first.next_pc;
    } else {
        const first = decodeRegExpCaptureLengthTerm(code, scan, match_put.?) orelse return null;
        capture_indexes[capture_count] = first.capture_index;
        scan = first.next_pc;
    }
    capture_count += 1;
    const resolved_match_put = match_put orelse return null;
    if (sameRegExpMatchGetPut(accumulator_get, resolved_match_put)) return null;
    if (regExpLoopGetConflictsWithMatchPut(prefix.input_get, resolved_match_put)) return null;

    while (capture_count < capture_indexes.len) {
        if (decodeRegExpCaptureLengthTerm(code, scan, resolved_match_put)) |next_term| {
            scan = next_term.next_pc;
            if (scan >= code.len or code[scan] != op.add) return null;
            capture_indexes[capture_count] = next_term.capture_index;
            capture_count += 1;
            scan += 1;
            continue;
        }
        break;
    }

    if (scan >= code.len or code[scan] != op.add) return null;
    scan += 1;
    var drop_pc: ?usize = null;
    if (scan < code.len and code[scan] == op.dup) {
        scan += 1;
        const candidate_put = decodeRegExpMatchPut(code, scan) orelse return null;
        const candidate_drop_pc = regExpMatchPutNextPc(candidate_put);
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return null;
        drop_pc = candidate_drop_pc;
    }
    const accumulator_put = decodeRegExpMatchPut(code, scan) orelse return null;
    if (!sameRegExpMatchGetPut(accumulator_get, accumulator_put)) return null;
    const goto_pc = if (drop_pc) |drop| drop + 1 else regExpMatchPutNextPc(accumulator_put);
    const success_pc = decodeGotoTarget(code, goto_pc) orelse return null;
    const receiver_pc = decodeRegExpLoopReceiverPcForTail(code, success_pc, resolved_match_put, prefix.stack_drop_count) orelse return null;

    return .{
        .input_get = prefix.input_get,
        .match_put = resolved_match_put,
        .accumulator_get = accumulator_get,
        .accumulator_put = accumulator_put,
        .capture_indexes = capture_indexes,
        .capture_count = capture_count,
        .success_pc = success_pc,
        .false_pc = prefix.branch.false_pc,
        .receiver_pc = receiver_pc,
        .stack_drop_count = prefix.stack_drop_count,
    };
}

fn tryFuseRegExpExecLengthLoopFromField2(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    method_atom: core.Atom,
    field_pc: usize,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    eval_with_object: core.JSValue,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!value_ops.atomNameEql(ctx.runtime, method_atom, "exec")) return false;
    const loop = decodeRegExpExecLengthLoop(function.code, frame.pc) orelse return false;
    if (!regExpMatchStoreWritableForFastPath(ctx, function, global, frame, loop.match_put, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object)) return false;
    if (!regExpMatchStoreWritableForFastPath(ctx, function, global, frame, loop.accumulator_put, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object)) return false;

    const regexp_object = objectFromValue(receiver) orelse return false;
    if (regexp_object.class_id != core.class.ids.regexp) return false;
    if (!fastRegExpPrototypeMethodIsDefault(ctx.runtime, receiver, method_atom, @intFromEnum(builtins.regexp.PrototypeMethod.exec))) return false;

    const input_value = regExpLoopReadableBorrowed(ctx, function, global, frame, loop.input_get, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object) orelse return false;
    if (!input_value.isString()) return false;
    const accumulator_value = regExpLoopReadableBorrowed(ctx, function, global, frame, loop.accumulator_get, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object) orelse return false;
    if (!accumulator_value.isNumber()) return false;

    if (try tryFuseRegExpExecWholeLengthLoop(ctx, output, global, function, frame, stack, receiver, regexp_object, input_value, accumulator_value, loop, field_pc, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object, setSlotValue, syncTopLevelGlobalLexicalLocal)) {
        return true;
    }
    if (loop.stack_drop_count != 1) return false;

    const result = try shared_vm.qjsRegExpExecNoCaptureLengthForLoop(ctx, output, global, receiver, regexp_object, input_value, function, frame);
    if (result == .unsupported) return false;
    const stacked_receiver = try stack.pop();
    stacked_receiver.free(ctx.runtime);
    switch (result) {
        .unsupported => unreachable,
        .no_match => {
            try storeRegExpMatchNull(ctx, function, global, frame, loop.match_put, sync_global_lexical_locals, eval_var_ref_names, eval_var_refs, setSlotValue, syncTopLevelGlobalLexicalLocal);
            frame.pc = loop.false_pc;
            return true;
        },
        .matched => |len| {
            const len_value = if (len <= @as(usize, @intCast(std.math.maxInt(i32))))
                core.JSValue.int32(@intCast(len))
            else
                core.JSValue.float64(@floatFromInt(len));
            const updated = try simpleNumericBinary(ctx.runtime, op.add, accumulator_value, len_value);
            errdefer updated.free(ctx.runtime);
            try storeRegExpLoopOwnedValue(ctx, function, global, frame, loop.accumulator_put, updated, sync_global_lexical_locals, eval_var_ref_names, eval_var_refs, setSlotValue, syncTopLevelGlobalLexicalLocal);
            frame.pc = loop.success_pc;
            return true;
        },
    }
}

fn tryFuseRegExpExecWholeLengthLoop(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    regexp_object: *core.Object,
    input_value: core.JSValue,
    accumulator_value: core.JSValue,
    loop: RegExpExecLengthLoop,
    field_pc: usize,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    eval_with_object: core.JSValue,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const receiver_get = decodeRegExpMatchGet(function.code, loop.receiver_pc) orelse return false;
    if (regExpMatchGetNextPc(receiver_get) != field_pc) return false;
    const loop_receiver = regExpLoopReadableBorrowed(ctx, function, global, frame, receiver_get, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object) orelse return false;
    if (!loop_receiver.same(receiver)) return false;

    const accumulator = accumulator_value.asInt32() orelse return false;
    if (accumulator < 0) return false;
    const input_len = try shared_vm.stringLengthIndex(ctx.runtime, input_value);
    const remaining = @as(usize, @intCast(std.math.maxInt(i32) - accumulator));
    if (input_len > remaining) return false;

    const result = try shared_vm.qjsRegExpExecNoCaptureLengthLoopAll(ctx, output, global, receiver, regexp_object, input_value, function, frame);
    if (result == .unsupported) return false;
    var drop_count = loop.stack_drop_count;
    while (drop_count != 0) : (drop_count -= 1) {
        const stacked = try stack.pop();
        stacked.free(ctx.runtime);
    }
    switch (result) {
        .unsupported => unreachable,
        .done => |sum| {
            const updated = core.JSValue.int32(accumulator + @as(i32, @intCast(sum)));
            try storeRegExpMatchNull(ctx, function, global, frame, loop.match_put, sync_global_lexical_locals, eval_var_ref_names, eval_var_refs, setSlotValue, syncTopLevelGlobalLexicalLocal);
            try storeRegExpLoopOwnedValue(ctx, function, global, frame, loop.accumulator_put, updated, sync_global_lexical_locals, eval_var_ref_names, eval_var_refs, setSlotValue, syncTopLevelGlobalLexicalLocal);
            frame.pc = loop.false_pc;
            return true;
        },
    }
}

fn tryFuseRegExpExecCountLoopFromField2(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    method_atom: core.Atom,
    field_pc: usize,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    eval_with_object: core.JSValue,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!value_ops.atomNameEql(ctx.runtime, method_atom, "exec")) return false;
    const loop = decodeRegExpExecCountLoop(function.code, frame.pc) orelse return false;
    if (!regExpMatchStoreWritableForFastPath(ctx, function, global, frame, loop.match_put, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object)) return false;
    if (!regExpMatchStoreWritableForFastPath(ctx, function, global, frame, loop.accumulator_put, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object)) return false;

    const regexp_object = objectFromValue(receiver) orelse return false;
    if (regexp_object.class_id != core.class.ids.regexp) return false;
    if (!fastRegExpPrototypeMethodIsDefault(ctx.runtime, receiver, method_atom, @intFromEnum(builtins.regexp.PrototypeMethod.exec))) return false;

    const loop_receiver_get = decodeRegExpMatchGet(function.code, loop.receiver_pc) orelse return false;
    if (regExpMatchGetNextPc(loop_receiver_get) != field_pc) return false;
    const loop_receiver = regExpLoopReadableBorrowed(ctx, function, global, frame, loop_receiver_get, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object) orelse return false;
    if (!loop_receiver.same(receiver)) return false;

    const input_value = regExpLoopReadableBorrowed(ctx, function, global, frame, loop.input_get, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object) orelse return false;
    if (!input_value.isString()) return false;
    const accumulator_value = regExpLoopReadableBorrowed(ctx, function, global, frame, loop.accumulator_get, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object) orelse return false;
    if (!accumulator_value.isNumber()) return false;

    const result = try shared_vm.qjsRegExpExecNoCaptureCountLoopAll(ctx, output, global, receiver, regexp_object, input_value, function, frame);
    if (result == .unsupported) return false;
    var drop_count = loop.stack_drop_count;
    while (drop_count != 0) : (drop_count -= 1) {
        const stacked = try stack.pop();
        stacked.free(ctx.runtime);
    }
    switch (result) {
        .unsupported => unreachable,
        .done => |count| {
            const count_value = if (count <= @as(usize, @intCast(std.math.maxInt(i32))))
                core.JSValue.int32(@intCast(count))
            else
                core.JSValue.float64(@floatFromInt(count));
            const updated = try simpleNumericBinary(ctx.runtime, op.add, accumulator_value, count_value);
            errdefer updated.free(ctx.runtime);
            try storeRegExpMatchNull(ctx, function, global, frame, loop.match_put, sync_global_lexical_locals, eval_var_ref_names, eval_var_refs, setSlotValue, syncTopLevelGlobalLexicalLocal);
            try storeRegExpLoopOwnedValue(ctx, function, global, frame, loop.accumulator_put, updated, sync_global_lexical_locals, eval_var_ref_names, eval_var_refs, setSlotValue, syncTopLevelGlobalLexicalLocal);
            frame.pc = loop.false_pc;
            return true;
        },
    }
}

fn tryFuseRegExpExecCaptureLengthWhileLoopFromField2(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    method_atom: core.Atom,
    field_pc: usize,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    eval_with_object: core.JSValue,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!value_ops.atomNameEql(ctx.runtime, method_atom, "exec")) return false;
    const loop = decodeRegExpExecCaptureLengthWhileLoop(function.code, frame.pc) orelse return false;
    if (!regExpMatchStoreWritableForFastPath(ctx, function, global, frame, loop.match_put, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object)) return false;
    if (!regExpMatchStoreWritableForFastPath(ctx, function, global, frame, loop.accumulator_put, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object)) return false;

    const regexp_object = objectFromValue(receiver) orelse return false;
    if (regexp_object.class_id != core.class.ids.regexp) return false;
    if (!fastRegExpPrototypeMethodIsDefault(ctx.runtime, receiver, method_atom, @intFromEnum(builtins.regexp.PrototypeMethod.exec))) return false;

    const loop_receiver_get = decodeRegExpMatchGet(function.code, loop.receiver_pc) orelse return false;
    if (regExpMatchGetNextPc(loop_receiver_get) != field_pc) return false;
    const loop_receiver = regExpLoopReadableBorrowed(ctx, function, global, frame, loop_receiver_get, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object) orelse return false;
    if (!loop_receiver.same(receiver)) return false;

    const input_value = regExpLoopReadableBorrowed(ctx, function, global, frame, loop.input_get, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object) orelse return false;
    if (!input_value.isString()) return false;
    const accumulator_value = regExpLoopReadableBorrowed(ctx, function, global, frame, loop.accumulator_get, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object) orelse return false;
    if (!accumulator_value.isNumber()) return false;

    const result = try shared_vm.qjsRegExpExecCaptureLengthSumLoopAll(ctx, output, global, receiver, regexp_object, input_value, loop.capture_indexes[0..loop.capture_count], function, frame);
    if (result == .unsupported) return false;
    var drop_count = loop.stack_drop_count;
    while (drop_count != 0) : (drop_count -= 1) {
        const stacked = try stack.pop();
        stacked.free(ctx.runtime);
    }
    switch (result) {
        .unsupported => unreachable,
        .done => |sum| {
            const sum_value = if (sum <= @as(usize, @intCast(std.math.maxInt(i32))))
                core.JSValue.int32(@intCast(sum))
            else
                core.JSValue.float64(@floatFromInt(sum));
            const updated = try simpleNumericBinary(ctx.runtime, op.add, accumulator_value, sum_value);
            errdefer updated.free(ctx.runtime);
            try storeRegExpMatchNull(ctx, function, global, frame, loop.match_put, sync_global_lexical_locals, eval_var_ref_names, eval_var_refs, setSlotValue, syncTopLevelGlobalLexicalLocal);
            try storeRegExpLoopOwnedValue(ctx, function, global, frame, loop.accumulator_put, updated, sync_global_lexical_locals, eval_var_ref_names, eval_var_refs, setSlotValue, syncTopLevelGlobalLexicalLocal);
            frame.pc = loop.false_pc;
            return true;
        },
    }
}

fn decodeCaptureLengthTerm(code: []const u8, pc: usize, match_put: BindingPut) ?struct { capture_index: u8, next_pc: usize } {
    const match_get = decodeBindingGet(code, pc) orelse return null;
    if (!sameBindingGetPut(match_get, match_put)) return null;
    const index_value = immediateInt32Operand(code, match_get.next_pc) orelse return null;
    if (index_value.value < 0 or index_value.value > 255) return null;
    if (index_value.next_pc + 2 > code.len or code[index_value.next_pc] != op.get_array_el or code[index_value.next_pc + 1] != op.get_length) return null;
    return .{ .capture_index = @intCast(index_value.value), .next_pc = index_value.next_pc + 2 };
}

fn decodeRegExpExecCaptureLengthSumLoop(code: []const u8, pc: usize, field_pc: usize) ?RegExpExecCaptureLengthSumLoop {
    const input_get = decodeBindingGet(code, pc) orelse return null;
    const call_pc = input_get.next_pc;
    if (call_pc + 3 > code.len or code[call_pc] != op.call_method or readInt(u16, code[call_pc + 1 ..][0..2]) != 1) return null;
    const match_put = decodeBindingPut(code, call_pc + 3) orelse return null;
    const after_match_put = match_put.operand_pc + match_put.consume;
    const accumulator_get = decodeBindingGet(code, after_match_put) orelse return null;
    if (sameBindingGetPut(input_get, match_put)) return null;
    if (sameBindingGetPut(accumulator_get, match_put)) return null;
    if (sameBinding(input_get, accumulator_get)) return null;

    var capture_indexes: [8]u8 = undefined;
    var capture_count: usize = 0;
    var scan = accumulator_get.next_pc;
    const first = decodeCaptureLengthTerm(code, scan, match_put) orelse return null;
    capture_indexes[capture_count] = first.capture_index;
    capture_count += 1;
    scan = first.next_pc;

    while (capture_count < capture_indexes.len) {
        if (decodeCaptureLengthTerm(code, scan, match_put)) |next_term| {
            scan = next_term.next_pc;
            if (scan >= code.len or code[scan] != op.add) return null;
            capture_indexes[capture_count] = next_term.capture_index;
            capture_count += 1;
            scan += 1;
            continue;
        }
        break;
    }

    if (scan >= code.len or code[scan] != op.add) return null;
    const accumulator_put = decodeBindingPut(code, scan + 1) orelse return null;
    if (!sameBindingGetPut(accumulator_get, accumulator_put)) return null;
    const tail_pc = accumulator_put.operand_pc + accumulator_put.consume;

    const tail_get = decodeBindingGet(code, tail_pc) orelse return null;
    if (tail_get.next_pc >= code.len or code[tail_get.next_pc] != op.post_inc) return null;
    const tail_put = decodeBindingPut(code, tail_get.next_pc + 1) orelse return null;
    if (!sameBindingGetPut(tail_get, tail_put)) return null;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return null;
    const goto_pc = tail_drop_pc + 1;
    const condition_pc = decodeGotoTarget(code, goto_pc) orelse return null;
    const induction_get = decodeBindingGet(code, condition_pc) orelse return null;
    if (!sameBinding(induction_get, tail_get)) return null;
    const limit_get = decodeLoopLimitGet(code, induction_get.next_pc) orelse return null;
    if (limit_get.next_pc >= code.len or code[limit_get.next_pc] != op.lt) return null;
    const loop_branch = decodeFalseBranch(code, limit_get.next_pc + 1) orelse return null;
    if (loop_branch.true_pc > field_pc or field_pc - loop_branch.true_pc > 8) return null;
    const false_pc = loop_branch.false_pc;
    const exit_get = decodeBindingGet(code, false_pc) orelse return null;
    if (!sameBinding(exit_get, accumulator_get)) return null;
    if (exit_get.next_pc >= code.len or code[exit_get.next_pc] != op.@"return") return null;

    return .{
        .input_get = input_get,
        .match_put = match_put,
        .accumulator_get = accumulator_get,
        .accumulator_put = accumulator_put,
        .induction_get = induction_get,
        .loop_limit = limit_get.limit,
        .capture_indexes = capture_indexes,
        .capture_count = capture_count,
        .tail_pc = tail_pc,
        .false_pc = false_pc,
    };
}

fn tryFuseRegExpExecCaptureLengthSumLoopFromField2(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    method_atom: core.Atom,
    field_pc: usize,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!value_ops.atomNameEql(ctx.runtime, method_atom, "exec")) return false;
    const loop = decodeRegExpExecCaptureLengthSumLoop(function.code, frame.pc, field_pc) orelse return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, loop.match_put)) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, loop.accumulator_put)) return false;

    const regexp_object = objectFromValue(receiver) orelse return false;
    if (regexp_object.class_id != core.class.ids.regexp) return false;
    if (!fastRegExpPrototypeMethodIsDefault(ctx.runtime, receiver, method_atom, @intFromEnum(builtins.regexp.PrototypeMethod.exec))) return false;

    const input_value = bindingReadableBorrowed(frame, loop.input_get) orelse return false;
    if (!input_value.isString()) return false;
    const accumulator_value = bindingReadableBorrowed(frame, loop.accumulator_get) orelse return false;
    if (!accumulator_value.isNumber()) return false;

    const result = try shared_vm.qjsRegExpExecCaptureLengthSumForLoop(ctx, output, global, receiver, regexp_object, input_value, loop.capture_indexes[0..loop.capture_count], function, frame);
    if (result == .unsupported) return false;
    const stacked_receiver = try stack.pop();
    stacked_receiver.free(ctx.runtime);
    switch (result) {
        .unsupported => unreachable,
        .matched => |sum| {
            if (bindingReadableBorrowed(frame, loop.induction_get)) |induction_value| {
                if (induction_value.asInt32()) |current_i| {
                    if (loopLimitReadableInt32(frame, loop.loop_limit)) |limit_i| {
                        const remaining_i64 = @as(i64, limit_i) - @as(i64, current_i);
                        if (remaining_i64 > 1 and remaining_i64 <= std.math.maxInt(i32)) {
                            const accumulator_i = accumulator_value.asInt32();
                            if (accumulator_i) |accumulator| {
                                if (accumulator >= 0) {
                                    const remaining: usize = @intCast(remaining_i64);
                                    const product = std.math.mul(usize, sum, remaining) catch return false;
                                    const available = @as(usize, @intCast(std.math.maxInt(i32) - accumulator));
                                    if (product <= available) {
                                        const updated = core.JSValue.int32(accumulator + @as(i32, @intCast(product)));
                                        try storeBindingOwnedValue(ctx, function, global, frame, loop.accumulator_put, updated, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
                                        frame.pc = loop.false_pc;
                                        return true;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            const sum_value = if (sum <= @as(usize, @intCast(std.math.maxInt(i32))))
                core.JSValue.int32(@intCast(sum))
            else
                core.JSValue.float64(@floatFromInt(sum));
            const updated = try simpleNumericBinary(ctx.runtime, op.add, accumulator_value, sum_value);
            errdefer updated.free(ctx.runtime);
            try storeBindingOwnedValue(ctx, function, global, frame, loop.accumulator_put, updated, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
            frame.pc = loop.tail_pc;
            return true;
        },
    }
}

fn tryFuseRegExpExecStringBindingFromField2(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    method_atom: core.Atom,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!value_ops.atomNameEql(ctx.runtime, method_atom, "exec")) return false;
    const code = function.code;
    const pc = frame.pc;
    const input_get = decodeBindingGet(code, pc) orelse return false;
    const call_pc = input_get.next_pc;
    if (call_pc + 3 > code.len or code[call_pc] != op.call_method or readInt(u16, code[call_pc + 1 ..][0..2]) != 1) return false;
    const after_call_pc = call_pc + 3;
    const assignment_put = blk: {
        if (after_call_pc >= code.len or code[after_call_pc] != op.dup) break :blk null;
        const put = decodeBindingPut(code, after_call_pc + 1) orelse break :blk null;
        if (!bindingStoreWritableForFastPath(ctx, function, global, frame, put)) return false;
        break :blk put;
    };

    const regexp_object = objectFromValue(receiver) orelse return false;
    if (regexp_object.class_id != core.class.ids.regexp) return false;
    if (!fastRegExpPrototypeMethodIsDefault(ctx.runtime, receiver, method_atom, @intFromEnum(builtins.regexp.PrototypeMethod.exec))) return false;

    const input_value = bindingReadableBorrowed(frame, input_get) orelse return false;
    if (!input_value.isString()) return false;
    const result = (try shared_vm.qjsRegExpExecResult(ctx, output, global, receiver, regexp_object, input_value, true, function, frame)) orelse return false;
    var result_owned = true;
    errdefer if (result_owned) result.free(ctx.runtime);

    const stacked_receiver = try stack.pop();
    stacked_receiver.free(ctx.runtime);
    if (assignment_put) |put| {
        const stack_value = result.dup();
        var stack_value_owned = true;
        errdefer if (stack_value_owned) stack_value.free(ctx.runtime);
        try storeBindingOwnedValue(ctx, function, global, frame, put, result, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
        result_owned = false;
        try stack.pushOwned(stack_value);
        stack_value_owned = false;
        frame.pc = put.operand_pc + put.consume;
    } else {
        try stack.pushOwned(result);
        result_owned = false;
        frame.pc = after_call_pc;
    }
    return true;
}

fn fastRegExpPrototypeMethodValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    const object = objectFromValue(value) orelse return null;
    if (object.class_id != core.class.ids.regexp) return null;
    const name = rt.atoms.name(atom_id) orelse return null;
    const expected_id: u32 = if (std.mem.eql(u8, name, "test"))
        @intFromEnum(builtins.regexp.PrototypeMethod.test_)
    else if (std.mem.eql(u8, name, "exec"))
        @intFromEnum(builtins.regexp.PrototypeMethod.exec)
    else
        return null;

    if (object.hasOwnProperty(atom_id)) return null;
    const proto = object.getPrototype() orelse return null;
    const lookup = proto.getOwnDataPropertyLookup(atom_id) orelse return null;
    const method = lookup.value;
    const function_object = objectFromValue(method) orelse {
        method.free(rt);
        return null;
    };
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*) orelse {
        method.free(rt);
        return null;
    };
    if (native_ref.domain != .regexp or native_ref.id != expected_id) {
        method.free(rt);
        return null;
    }
    return method;
}

fn fastCollectionPrototypeMethodValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    const object = objectFromValue(value) orelse return null;
    const name = rt.atoms.name(atom_id) orelse return null;
    const expected_id = builtins.collection.fastPrototypeMethodIdForClass(object.class_id, name) orelse return null;
    if (object.hasOwnProperty(atom_id)) return null;
    const proto = object.getPrototype() orelse return null;
    const lookup = proto.getOwnDataPropertyLookup(atom_id) orelse return null;
    const method = lookup.value;
    const function_object = objectFromValue(method) orelse {
        method.free(rt);
        return null;
    };
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*) orelse {
        method.free(rt);
        return null;
    };
    if (native_ref.domain != .collection or native_ref.id != expected_id) {
        method.free(rt);
        return null;
    }
    return method;
}

fn fastStringIndexValue(rt: *core.JSRuntime, value: core.JSValue, key: core.JSValue) ?core.JSValue {
    if (!value.isString() or key.tag != core.Tag.int) return null;
    const index_i32 = key.asInt32().?;
    if (index_i32 < 0) return null;
    const header = value.refHeader() orelse return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    const index: usize = @intCast(index_i32);
    if (index >= string_value.len()) return null;
    const unit = string_value.codeUnitAt(index);
    if (unit <= 0x7f) {
        const cached = rt.cachedSingleByteString(@intCast(unit)) orelse return null;
        return cached.value().dup();
    }
    return null;
}

fn stackValueFromTop(stack: *const stack_mod.Stack, offset: u8) !core.JSValue {
    const index_from_top: usize = offset;
    if (index_from_top >= stack.values.len) return error.StackUnderflow;
    return stack.values[stack.values.len - 1 - index_from_top].dup();
}
