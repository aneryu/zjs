//! Global variable read/write/define opcode handlers and their fused fast paths.

const std = @import("std");
const bytecode = @import("../bytecode/root.zig");
const builtins = @import("../builtins/root.zig");
const core = @import("../core/root.zig");
const dtoa = @import("../libs/dtoa.zig");
const unicode_lib = @import("../libs/unicode.zig");
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
const CollectionHostOutputKey = property_vm.CollectionHostOutputKey;
const CollectionHostOutputKeyOperand = property_vm.CollectionHostOutputKeyOperand;
const DecodedImmediateInt32 = property_vm.DecodedImmediateInt32;
const FastGlobalReadValue = property_vm.FastGlobalReadValue;
const GlobalPropertyRangeDelta = property_vm.GlobalPropertyRangeDelta;
const GlobalSimpleNumericRangeArg = property_vm.GlobalSimpleNumericRangeArg;
const LocalPut = property_vm.LocalPut;
const NumberStaticLiteralResult = property_vm.NumberStaticLiteralResult;
const SimpleNumericRangeArg = property_vm.SimpleNumericRangeArg;
const Step = property_vm.Step;
const StoredGlobalDataValue = property_vm.StoredGlobalDataValue;
const StringNumberConstArg = property_vm.StringNumberConstArg;
const StringNumberConstCall = property_vm.StringNumberConstCall;
const StringSubstringImmediateCall = property_vm.StringSubstringImmediateCall;
const TypedArrayLengthPrintGet = property_vm.TypedArrayLengthPrintGet;
const TypedArrayLengthPrintStore = property_vm.TypedArrayLengthPrintStore;
const UriCall1Argument = property_vm.UriCall1Argument;
const UriFourByteRangePlan = property_vm.UriFourByteRangePlan;
const UriStrictEqBranch = property_vm.UriStrictEqBranch;
const UriStrictEqIntArg = property_vm.UriStrictEqIntArg;
const arg = property_vm.arg;
const atomAsciiText = property_vm.atomAsciiText;
const atomStringValueForFastPath = property_vm.atomStringValueForFastPath;
const backwardGotoTarget = property_vm.backwardGotoTarget;
const borrowedSimpleCallArgWithContext = property_vm.borrowedSimpleCallArgWithContext;
const borrowedSimpleCallable = property_vm.borrowedSimpleCallable;
const canFinishWithUndefinedAt = property_vm.canFinishWithUndefinedAt;
const canFuseGlobalDataWrite = property_vm.canFuseGlobalDataWrite;
const canUseFastGlobalVarLookup = property_vm.canUseFastGlobalVarLookup;
const canUseInstalledGlobalDataIc = property_vm.canUseInstalledGlobalDataIc;
const decodeFalseBranch = property_vm.decodeFalseBranch;
const decodeFieldAtom = property_vm.decodeFieldAtom;
const decodeGlobalDataGet = property_vm.decodeGlobalDataGet;
const decodeGlobalPut = property_vm.decodeGlobalPut;
const decodeLocalGet = property_vm.decodeLocalGet;
const decodeOptionalLocalCompletionTail = property_vm.decodeOptionalLocalCompletionTail;
const decodeOptionalUndefinedLocalCompletionTail = property_vm.decodeOptionalUndefinedLocalCompletionTail;
const decodeVarRefGet = property_vm.decodeVarRefGet;
const decodeVarRefPut = property_vm.decodeVarRefPut;
const denseArrayModFieldInt32Increments = property_vm.denseArrayModFieldInt32Increments;
const fastArrayPrototypeMethodIsDefault = property_vm.fastArrayPrototypeMethodIsDefault;
const fastCollectionPrototypeMethodIsDefault = property_vm.fastCollectionPrototypeMethodIsDefault;
const fastDenseArrayElementValue = property_vm.fastDenseArrayElementValue;
const fastGlobalDataValueForAtomAtPc = property_vm.fastGlobalDataValueForAtomAtPc;
const fastInstalledGlobalDataValueForAtomAtPc = property_vm.fastInstalledGlobalDataValueForAtomAtPc;
const fastInt32Add = property_vm.fastInt32Add;
const fastInt32Mul = property_vm.fastInt32Mul;
const fastInt32Sub = property_vm.fastInt32Sub;
const fastStringPrototypeMethodIsDefault = property_vm.fastStringPrototypeMethodIsDefault;
const finishUndefinedCallResult = property_vm.finishUndefinedCallResult;
const frameHasVarRefBinding = property_vm.frameHasVarRefBinding;
const functionFrameBindingShadowsGlobal = property_vm.functionFrameBindingShadowsGlobal;
const hasObjectBinding = property_vm.hasObjectBinding;
const immediateInt32Operand = property_vm.immediateInt32Operand;
const intRangeDeltaBounds = property_vm.intRangeDeltaBounds;
const isHostOutputFunctionValue = property_vm.isHostOutputFunctionValue;
const linearRangeDeltaBounds = property_vm.linearRangeDeltaBounds;
const localReadableBorrowed = property_vm.localReadableBorrowed;
const periodicNonNegativeDelta = property_vm.periodicNonNegativeDelta;
const pushBorrowedValueOrFuseLocalAdd = property_vm.pushBorrowedValueOrFuseLocalAdd;
const safeIntegerI128 = property_vm.safeIntegerI128;
const simpleNumericFunctionResult = property_vm.simpleNumericFunctionResult;
const simpleNumericRangeCallable = property_vm.simpleNumericRangeCallable;
const simpleNumericRangeLinearTerm = property_vm.simpleNumericRangeLinearTerm;
const simpleStringCallableKind = property_vm.simpleStringCallableKind;
const slotValueBorrowed = property_vm.slotValueBorrowed;
const storeLocalCompletionBorrowedValue = property_vm.storeLocalCompletionBorrowedValue;
const stringFromCharCodeInt32Arg = property_vm.stringFromCharCodeInt32Arg;
const stringFromValue = property_vm.stringFromValue;
const tryFuseCallResultAddGlobalStore = property_vm.tryFuseCallResultAddGlobalStore;
const tryFuseLocalAddWithValue = property_vm.tryFuseLocalAddWithValue;
const tryFuseStringFromCharCodeInt32LocalAppend = property_vm.tryFuseStringFromCharCodeInt32LocalAppend;
const varRefReadableBorrowed = property_vm.varRefReadableBorrowed;

const functionOwnNativeBuiltinRefForFastPath = property_ic.functionOwnNativeBuiltinRefForFastPath;
const globalDataPropertyValueForFastPath = property_ic.globalDataPropertyValueForFastPath;
const globalDataPropertyValueForFastPathNoProfile = property_ic.globalDataPropertyValueForFastPathNoProfile;
const globalWritableDataStoreAvailableForFastPath = property_ic.globalWritableDataStoreAvailableForFastPath;
const globalWritableDataStoreInt32ForFastPath = property_ic.globalWritableDataStoreInt32ForFastPath;
const ordinaryDataPropertyBorrowedValueForFastPath = property_ic.ordinaryDataPropertyBorrowedValueForFastPath;
const ordinaryDataPropertyIsUndefinedForFastPath = property_ic.ordinaryDataPropertyIsUndefinedForFastPath;
const ordinaryDataPropertyValueOrUndefinedForFastPath = property_ic.ordinaryDataPropertyValueOrUndefinedForFastPath;
const setGlobalDataPropertyForFastPath = property_ic.setGlobalDataPropertyForFastPath;
const setGlobalWritableDataStoreForFastPathOwned = property_ic.setGlobalWritableDataStoreForFastPathOwned;

const op = bytecode.opcode.op;
const atom_date = core.atom.predefinedId("Date", .string).?;
const atom_array_buffer = core.atom.predefinedId("ArrayBuffer", .string).?;
const atom_number = core.atom.predefinedId("Number", .string).?;
const atom_print = core.atom.predefinedId("print", .string).?;
const atom_string = core.atom.predefinedId("String", .string).?;

fn tryFuseGlobalSimpleNumericCallAddStore(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    callee: core.JSValue,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) !bool {
    const arg0 = borrowedSimpleCallArgWithContext(ctx, function, global, frame, frame.pc, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
    if (arg0.next_pc >= function.code.len) return false;

    var args_buf: [2]core.JSValue = undefined;
    args_buf[0] = arg0.value;
    var argc: usize = 1;
    var call_pc = arg0.next_pc;
    switch (function.code[call_pc]) {
        op.call1 => {},
        else => {
            const arg1 = borrowedSimpleCallArgWithContext(ctx, function, global, frame, arg0.next_pc, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
            if (arg1.next_pc >= function.code.len or function.code[arg1.next_pc] != op.call2) return false;
            args_buf[1] = arg1.value;
            argc = 2;
            call_pc = arg1.next_pc;
        },
    }

    const result = try simpleNumericFunctionResult(ctx.runtime, callee, args_buf[0..argc]) orelse return false;
    var result_owned = true;
    errdefer if (result_owned) result.free(ctx.runtime);
    if (try tryFuseCallResultAddGlobalStore(ctx, function, global, frame, stack, call_pc, result, &result_owned, eval_local_names, eval_var_ref_names, eval_with_object)) return true;
    result.free(ctx.runtime);
    result_owned = false;
    return false;
}

fn tryFuseGlobalSimpleNumericCallAddRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    accumulator_atom: core.Atom,
    accumulator_value: core.JSValue,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) !bool {
    if (ctx.runtime.hasInterruptHandler()) return false;
    if (!canUseFastGlobalVarLookup(function, accumulator_atom, frame, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    const accumulator = accumulator_value.asInt32() orelse return false;
    const code = function.code;
    const body_pc = if (frame.pc >= 5) frame.pc - 5 else return false;

    const callee = borrowedSimpleCallable(ctx, function, global, frame, frame.pc, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
    const arg0 = decodeSimpleNumericGlobalRangeArg(code, callee.next_pc) orelse return false;
    var global_args_buf: [2]GlobalSimpleNumericRangeArg = undefined;
    global_args_buf[0] = arg0.arg;
    var argc: usize = 1;
    var call_pc = arg0.next_pc;
    if (call_pc >= code.len) return false;
    switch (code[call_pc]) {
        op.call1 => {},
        else => {
            const arg1 = decodeSimpleNumericGlobalRangeArg(code, call_pc) orelse return false;
            if (arg1.next_pc >= code.len or code[arg1.next_pc] != op.call2) return false;
            global_args_buf[1] = arg1.arg;
            argc = 2;
            call_pc = arg1.next_pc;
        },
    }

    const add_pc = call_pc + 1;
    if (add_pc >= code.len or code[add_pc] != op.add) return false;
    var store_pc = add_pc + 1;
    var tail_pc: usize = undefined;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const store = decodeGlobalPut(code, store_pc) orelse return false;
        if (store.atom != accumulator_atom) return false;
        if (store.next_pc >= code.len or code[store.next_pc] != op.drop) return false;
        tail_pc = store.next_pc + 1;
    } else {
        const store = decodeGlobalPut(code, store_pc) orelse return false;
        if (store.atom != accumulator_atom) return false;
        tail_pc = store.next_pc;
    }
    if (!canFuseGlobalDataWrite(function, frame, accumulator_atom, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    if (!globalWritableDataStoreAvailableForFastPath(ctx.runtime, ctx.lexicals, global, function, store_pc, accumulator_atom)) return false;

    const induction_get = decodeGlobalDataGet(code, tail_pc) orelse return false;
    if (induction_get.atom == accumulator_atom) return false;
    if (!canUseFastGlobalVarLookup(function, induction_get.atom, frame, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    const update_pc = induction_get.next_pc;
    if (update_pc >= code.len or code[update_pc] != op.post_inc) return false;
    const induction_put_pc = update_pc + 1;
    const induction_put = decodeGlobalPut(code, induction_put_pc) orelse return false;
    if (induction_put.atom != induction_get.atom) return false;
    if (induction_put.next_pc >= code.len or code[induction_put.next_pc] != op.drop) return false;
    if (!canFuseGlobalDataWrite(function, frame, induction_get.atom, eval_local_names, eval_var_ref_names, eval_with_object)) return false;

    const goto_pc = induction_put.next_pc + 1;
    if (goto_pc >= code.len) return false;
    const condition_pc = backwardGotoTarget(code, goto_pc + 1, code[goto_pc]) orelse return false;
    const condition_get = decodeGlobalDataGet(code, condition_pc) orelse return false;
    if (condition_get.atom != induction_get.atom) return false;
    const limit = immediateInt32Operand(code, condition_get.next_pc) orelse return false;
    if (limit.next_pc >= code.len or code[limit.next_pc] != op.lt) return false;
    const branch = decodeFalseBranch(code, limit.next_pc + 1) orelse return false;
    if (branch.true_pc != body_pc or condition_pc >= body_pc) return false;

    const current_i = globalWritableDataStoreInt32ForFastPath(ctx.runtime, ctx.lexicals, global, function, induction_put_pc, induction_get.atom) orelse return false;
    if (current_i >= limit.value) {
        frame.pc = branch.false_pc;
        return true;
    }
    const iteration_count_i128 = @as(i128, limit.value) - @as(i128, current_i);
    if (iteration_count_i128 <= 0 or iteration_count_i128 > std.math.maxInt(i32)) return false;

    var args_buf: [2]SimpleNumericRangeArg = undefined;
    for (global_args_buf[0..argc], 0..) |range_arg, idx| {
        args_buf[idx] = switch (range_arg) {
            .global => |atom| blk: {
                if (atom != induction_get.atom) return false;
                break :blk .induction;
            },
            .int32 => |value| .{ .int32 = value },
        };
    }
    const simple = simpleNumericRangeCallable(callee.value) orelse return false;
    const linear = simpleNumericRangeLinearTerm(simple, args_buf[0..argc]) orelse return false;
    const delta = linearRangeDeltaBounds(@as(i128, current_i), @as(i128, limit.value), linear.coefficient, linear.offset) orelse return false;
    const min_accumulator = @as(i128, accumulator) + delta.min;
    const max_accumulator = @as(i128, accumulator) + delta.max;
    if (!safeIntegerI128(min_accumulator) or !safeIntegerI128(max_accumulator)) return false;
    const final_accumulator = @as(i128, accumulator) + delta.total;

    const accumulator_next = value_ops.numberToValue(@floatFromInt(final_accumulator));
    if (!setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, store_pc, accumulator_atom, accumulator_next)) {
        accumulator_next.free(ctx.runtime);
        return false;
    }
    const induction_next = core.JSValue.int32(limit.value);
    if (!setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, induction_put_pc, induction_get.atom, induction_next)) {
        return false;
    }
    frame.pc = branch.false_pc;
    return true;
}

fn tryFuseGlobalInductionInt32AddRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    accumulator_atom: core.Atom,
    accumulator_value: core.JSValue,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (ctx.runtime.hasInterruptHandler()) return false;
    if (!canUseFastGlobalVarLookup(function, accumulator_atom, frame, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    const accumulator = accumulator_value.asInt32() orelse return false;
    const code = function.code;
    const body_pc = if (frame.pc >= 5) frame.pc - 5 else return false;

    const induction_get = decodeGlobalDataGet(code, frame.pc) orelse return false;
    if (induction_get.atom == accumulator_atom) return false;
    if (!canUseFastGlobalVarLookup(function, induction_get.atom, frame, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    if (induction_get.next_pc >= code.len or code[induction_get.next_pc] != op.add) return false;

    var store_pc = induction_get.next_pc + 1;
    var completion_put: ?LocalPut = null;
    var tail_pc: usize = undefined;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const store = decodeGlobalPut(code, store_pc) orelse return false;
        if (store.atom != accumulator_atom) return false;
        const completion_tail = decodeOptionalLocalCompletionTail(function, frame, store.next_pc) orelse return false;
        completion_put = completion_tail.completion_put;
        tail_pc = completion_tail.tail_pc;
    } else {
        const store = decodeGlobalPut(code, store_pc) orelse return false;
        if (store.atom != accumulator_atom) return false;
        tail_pc = store.next_pc;
    }
    if (!canFuseGlobalDataWrite(function, frame, accumulator_atom, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    if (!globalWritableDataStoreAvailableForFastPath(ctx.runtime, ctx.lexicals, global, function, store_pc, accumulator_atom)) return false;

    const tail_get = decodeGlobalDataGet(code, tail_pc) orelse return false;
    if (tail_get.atom != induction_get.atom) return false;
    if (tail_get.next_pc >= code.len or code[tail_get.next_pc] != op.post_inc) return false;
    const induction_put_pc = tail_get.next_pc + 1;
    const induction_put = decodeGlobalPut(code, induction_put_pc) orelse return false;
    if (induction_put.atom != induction_get.atom) return false;
    if (induction_put.next_pc >= code.len or code[induction_put.next_pc] != op.drop) return false;
    if (!canFuseGlobalDataWrite(function, frame, induction_get.atom, eval_local_names, eval_var_ref_names, eval_with_object)) return false;

    const goto_pc = induction_put.next_pc + 1;
    if (goto_pc >= code.len) return false;
    const condition_pc = backwardGotoTarget(code, goto_pc + 1, code[goto_pc]) orelse return false;
    const condition_get = decodeGlobalDataGet(code, condition_pc) orelse return false;
    if (condition_get.atom != induction_get.atom) return false;
    const limit = immediateInt32Operand(code, condition_get.next_pc) orelse return false;
    if (limit.next_pc >= code.len or code[limit.next_pc] != op.lt) return false;
    const branch = decodeFalseBranch(code, limit.next_pc + 1) orelse return false;
    if (branch.true_pc != body_pc or condition_pc >= body_pc) return false;

    const current_i = globalWritableDataStoreInt32ForFastPath(ctx.runtime, ctx.lexicals, global, function, induction_put_pc, induction_get.atom) orelse return false;
    if (current_i >= limit.value) {
        frame.pc = branch.false_pc;
        return true;
    }
    const delta = intRangeDeltaBounds(current_i, limit.value);
    const min_accumulator = @as(i128, accumulator) + delta.min;
    const max_accumulator = @as(i128, accumulator) + delta.max;
    if (!safeIntegerI128(min_accumulator) or !safeIntegerI128(max_accumulator)) return false;

    const final_accumulator = @as(i128, accumulator) + delta.total;
    const final_value = value_ops.numberToValue(@floatFromInt(final_accumulator));
    var completion_value: core.JSValue = undefined;
    var has_completion_value = false;
    if (completion_put != null) {
        completion_value = final_value.dup();
        has_completion_value = true;
    }
    if (!setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, store_pc, accumulator_atom, final_value)) {
        final_value.free(ctx.runtime);
        if (has_completion_value) {
            completion_value.free(ctx.runtime);
        }
        return false;
    }
    if (has_completion_value) {
        defer completion_value.free(ctx.runtime);
        try storeLocalCompletionBorrowedValue(ctx, function, global, frame, completion_put, completion_value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    }

    const induction_next = core.JSValue.int32(limit.value);
    if (!setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, induction_put_pc, induction_get.atom, induction_next)) {
        return false;
    }
    frame.pc = branch.false_pc;
    return true;
}

fn tryFuseGlobalPropertyReadAddRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    accumulator_atom: core.Atom,
    accumulator_value: core.JSValue,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) !bool {
    if (ctx.runtime.hasInterruptHandler()) return false;
    const accumulator = accumulator_value.asInt32() orelse return false;
    const code = function.code;
    const body_pc = if (frame.pc >= 5) frame.pc - 5 else return false;

    const receiver_get = decodeGlobalDataGet(code, frame.pc) orelse return false;
    const receiver_value = fastGlobalDataValueForAtomAtPc(ctx, function, global, frame, frame.pc, receiver_get.atom, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
    const delta: GlobalPropertyRangeDelta, const add_pc: usize, const index_atom: ?core.Atom = blk: {
        if (decodeFieldAtom(code, receiver_get.next_pc, op.get_field)) |field_get| {
            if (field_get.next_pc >= code.len or code[field_get.next_pc] != op.add) return false;
            const field_value = ordinaryDataPropertyBorrowedValueForFastPath(ctx.runtime, receiver_value, field_get.atom) orelse return false;
            break :blk .{ .{ .constant = field_value.asInt32() orelse return false }, field_get.next_pc, null };
        }

        const index_get = decodeGlobalDataGet(code, receiver_get.next_pc) orelse return false;
        const modulus = immediateInt32Operand(code, index_get.next_pc) orelse return false;
        if (modulus.value <= 0) return false;
        if (modulus.next_pc + 2 > code.len or code[modulus.next_pc] != op.mod or code[modulus.next_pc + 1] != op.get_array_el) return false;
        const field_get = decodeFieldAtom(code, modulus.next_pc + 2, op.get_field) orelse return false;
        if (field_get.next_pc >= code.len or code[field_get.next_pc] != op.add) return false;
        const increments = denseArrayModFieldInt32Increments(ctx.runtime, receiver_value, field_get.atom, @intCast(modulus.value)) orelse return false;
        break :blk .{ .{ .periodic = increments }, field_get.next_pc, index_get.atom };
    };

    var store_pc = add_pc + 1;
    var tail_pc: usize = undefined;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const store = decodeGlobalPut(code, store_pc) orelse return false;
        if (store.atom != accumulator_atom) return false;
        if (store.next_pc >= code.len or code[store.next_pc] != op.drop) return false;
        tail_pc = store.next_pc + 1;
    } else {
        const store = decodeGlobalPut(code, store_pc) orelse return false;
        if (store.atom != accumulator_atom) return false;
        tail_pc = store.next_pc;
    }
    if (!globalWritableDataStoreAvailableForFastPath(ctx.runtime, ctx.lexicals, global, function, store_pc, accumulator_atom)) return false;

    const induction_get = decodeGlobalDataGet(code, tail_pc) orelse return false;
    if (induction_get.atom == accumulator_atom) return false;
    if (index_atom) |atom| {
        if (atom != induction_get.atom) return false;
    }
    const update_pc = induction_get.next_pc;
    if (update_pc >= code.len or code[update_pc] != op.post_inc) return false;
    const induction_put_pc = update_pc + 1;
    const induction_put = decodeGlobalPut(code, induction_put_pc) orelse return false;
    if (induction_put.atom != induction_get.atom) return false;
    if (induction_put.next_pc >= code.len or code[induction_put.next_pc] != op.drop) return false;
    const goto_pc = induction_put.next_pc + 1;
    if (goto_pc >= code.len) return false;
    const condition_pc = backwardGotoTarget(code, goto_pc + 1, code[goto_pc]) orelse return false;

    const condition_get = decodeGlobalDataGet(code, condition_pc) orelse return false;
    if (condition_get.atom != induction_get.atom) return false;
    const limit = immediateInt32Operand(code, condition_get.next_pc) orelse return false;
    if (limit.next_pc >= code.len or code[limit.next_pc] != op.lt) return false;
    const branch = decodeFalseBranch(code, limit.next_pc + 1) orelse return false;
    if (branch.true_pc != body_pc or condition_pc >= body_pc) return false;

    const current_i = globalWritableDataStoreInt32ForFastPath(ctx.runtime, ctx.lexicals, global, function, induction_put_pc, induction_get.atom) orelse return false;
    if (current_i >= limit.value) {
        frame.pc = branch.false_pc;
        return true;
    }

    const count = @as(i128, limit.value) - @as(i128, current_i);
    const delta_value = switch (delta) {
        .constant => |field_int| count * @as(i128, field_int),
        .periodic => |increments| periodicNonNegativeDelta(current_i, limit.value, increments) orelse return false,
    };
    const total = @as(i128, accumulator) + delta_value;
    if (!safeIntegerI128(total)) return false;

    const accumulator_next = value_ops.numberToValue(@floatFromInt(total));
    if (!setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, store_pc, accumulator_atom, accumulator_next)) {
        accumulator_next.free(ctx.runtime);
        return false;
    }
    const induction_next = core.JSValue.int32(limit.value);
    if (!setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, induction_put_pc, induction_get.atom, induction_next)) {
        return false;
    }
    frame.pc = branch.false_pc;
    return true;
}

fn decodeSimpleNumericGlobalRangeArg(code: []const u8, pc: usize) ?struct { arg: GlobalSimpleNumericRangeArg, next_pc: usize } {
    if (decodeGlobalDataGet(code, pc)) |get| {
        return .{ .arg = .{ .global = get.atom }, .next_pc = get.next_pc };
    }
    const immediate = immediateInt32Operand(code, pc) orelse return null;
    return .{ .arg = .{ .int32 = immediate.value }, .next_pc = immediate.next_pc };
}

fn isSimpleNumericCallableCandidate(func: core.JSValue) bool {
    return func.isFunctionBytecode() or shared_vm.functionObjectFromValue(func) != null;
}

pub fn getVar(
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
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    eval_with_object: core.JSValue,
    comptime frameCurrentFunctionIsArrow: anytype,
    comptime lookupFrameLocalValue: anytype,
    comptime lookupFrameVarRef: anytype,
    comptime lookupFrameFirstEvalBindingValue: anytype,
    comptime withObjectBindingValue: anytype,
    comptime lookupEvalBindingValue: anytype,
    comptime lookupParentFunctionEvalBindingValue: anytype,
    comptime directEvalShouldExposeImplicitArguments: anytype,
    comptime frameArgumentsObject: anytype,
    comptime globalLexicalValue: anytype,
    comptime getValueProperty: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    const site_pc = frame.pc - 1;
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    if (ctx.runtime.opcode_profile != null) core.profile.recordGlobalLookup();
    if (atom_id == core.atom.ids.undefined_ and canUseFastGlobalUndefinedLookup(function, frame, eval_local_names, eval_var_ref_names, eval_with_object)) {
        if (globalLexicalValue(ctx, atom_id)) |lex_value| {
            lex_value.free(ctx.runtime);
        } else {
            try stack.pushOwned(core.JSValue.undefinedValue());
            return .done;
        }
    }
    if (fastInstalledGlobalDataValueForAtomAtPc(ctx, function, global, frame, site_pc, atom_id, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) |value| {
        return try useFastGlobalDataValue(ctx, output, stack, function, global, frame, catch_target, site_pc, atom_id, value, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal, handleCatchableRuntimeError);
    }
    if (canUseFastGlobalVarLookup(function, atom_id, frame, eval_local_names, eval_var_ref_names, eval_with_object)) {
        if (globalLexicalValue(ctx, atom_id)) |lex_value| {
            if (lex_value.isUninitialized()) {
                lex_value.free(ctx.runtime);
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                return error.ReferenceError;
            }
            try pushValueOrFuseLocalAdd(ctx, stack, function, global, frame, lex_value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
            return .done;
        }
        if (try tryFuseTypedArrayArrayBufferLengthPrintFromGlobalGet(ctx, output, global, stack, function, frame, atom_id, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return .done;
        if (try tryFuseHostOutputAutoInitAtomCall1(ctx, output, global, stack, function, frame, atom_id, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return .done;
        if (globalDataPropertyValueForFastPath(ctx.runtime, global, function, site_pc, atom_id)) |value| {
            return try useFastGlobalDataValue(ctx, output, stack, function, global, frame, catch_target, site_pc, atom_id, value, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal, handleCatchableRuntimeError);
        }
    }
    const value = value: {
        const prefer_eval_arguments = atom_id == core.atom.ids.arguments and
            frameCurrentFunctionIsArrow(frame);
        if (prefer_eval_arguments) {
            if (lookupFrameLocalValue(ctx.runtime, function, frame, atom_id)) |slot_value| {
                if (slot_value.isUninitialized()) {
                    slot_value.free(ctx.runtime);
                    if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                    return error.ReferenceError;
                }
                break :value slot_value;
            }
            if (lookupFrameVarRef(ctx.runtime, function, frame, atom_id)) |slot_value| {
                if (slot_value.isUninitialized()) {
                    slot_value.free(ctx.runtime);
                    if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                    return error.ReferenceError;
                }
                break :value slot_value;
            }
            if (lookupFrameFirstEvalBindingValue(ctx.runtime, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, frame, atom_id)) |slot_value| {
                if (slot_value.isUninitialized()) {
                    slot_value.free(ctx.runtime);
                    if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                    return error.ReferenceError;
                }
                break :value slot_value;
            }
        } else {
            if (withObjectBindingValue(ctx, output, global, eval_with_object, atom_id, function, frame) catch |err| {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            }) |with_value| {
                break :value with_value;
            }
            if (lookupEvalBindingValue(ctx.runtime, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, frame, atom_id)) |slot_value| {
                if (slot_value.isUninitialized()) {
                    slot_value.free(ctx.runtime);
                    if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                    return error.ReferenceError;
                }
                break :value slot_value;
            }
            if (lookupFrameVarRef(ctx.runtime, function, frame, atom_id)) |slot_value| {
                if (slot_value.isUninitialized()) {
                    slot_value.free(ctx.runtime);
                    if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                    return error.ReferenceError;
                }
                break :value slot_value;
            }
        }
        if (lookupParentFunctionEvalBindingValue(ctx.runtime, frame, atom_id)) |slot_value| {
            if (slot_value.isUninitialized()) {
                slot_value.free(ctx.runtime);
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                return error.ReferenceError;
            }
            break :value slot_value;
        }
        if (atom_id == core.atom.ids.undefined_) break :value core.JSValue.undefinedValue();
        if (atom_id == core.atom.ids.arguments and directEvalShouldExposeImplicitArguments(frame)) {
            break :value try frameArgumentsObject(ctx, global, frame);
        }
        if (globalLexicalValue(ctx, atom_id)) |lex_value| {
            if (lex_value.isUninitialized()) {
                lex_value.free(ctx.runtime);
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                return error.ReferenceError;
            }
            break :value lex_value;
        }
        if (global.getOwnDataPropertyValue(atom_id)) |global_data_value| {
            break :value global_data_value;
        }
        const global_value = global.value().dup();
        defer global_value.free(ctx.runtime);
        if (opc == op.get_var) {
            const has_global_binding = hasObjectBinding(ctx, output, global, global_value, global, atom_id, function, frame) catch |err| {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            if (!has_global_binding) {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                return error.ReferenceError;
            }
        }
        break :value try getValueProperty(ctx, output, global, global_value, atom_id, function, frame);
    };
    if (atom_id == atom_string and
        try tryFuseGlobalStringFromCharCodeInt32LocalAppend(ctx, function, global, frame, stack, value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal))
    {
        value.free(ctx.runtime);
        return .done;
    }
    if (isSimpleNumericCallableCandidate(value) and
        try tryFuseGlobalSimpleNumericCallAddStore(ctx, function, global, frame, stack, value, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue))
    {
        value.free(ctx.runtime);
        return .done;
    }
    try pushValueOrFuseLocalAdd(ctx, stack, function, global, frame, value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    return .done;
}

fn tryFuseTypedArrayArrayBufferLengthPrintFromGlobalGet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    typed_array_atom: core.Atom,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) !bool {
    if (stack.len() != 0) return false;
    const code = function.code;
    var pc = frame.pc;
    if (pc < 5) return false;
    const typed_array_get_pc = pc - 5;
    if (pc + 7 > code.len or code[pc] != op.dup or code[pc + 1] != op.get_var) return false;
    const array_buffer_get_pc = pc + 1;
    const array_buffer_atom = readInt(u32, code[pc + 2 ..][0..4]);
    if (array_buffer_atom != atom_array_buffer) return false;
    pc += 6;
    if (pc >= code.len or code[pc] != op.dup) return false;
    pc += 1;

    const byte_length = decodeImmediateNonNegativeInt32(code, pc) orelse return false;
    pc = byte_length.next_pc;
    if (pc + 6 > code.len or code[pc] != op.call_constructor or readInt(u16, code[pc + 1 ..][0..2]) != 1) return false;
    pc += 3;
    if (code[pc] != op.call_constructor or readInt(u16, code[pc + 1 ..][0..2]) != 1) return false;
    pc += 3;

    const store = decodeTypedArrayLengthPrintStore(code, pc) orelse return false;
    pc = store.next_pc;
    if (!decodeDefaultPrintGet(ctx.runtime, global, code, &pc)) return false;
    const local_get = decodeTypedArrayLengthPrintGet(code, pc) orelse return false;
    if (local_get.idx != store.local_index) return false;
    pc = local_get.next_pc;
    if (pc + 3 > code.len or code[pc] != op.get_length or code[pc + 1] != op.call1 or code[pc + 2] != op.drop) return false;
    const after_drop = pc + 3;
    if (!nextInstructionReturnsUndefined(code, after_drop)) return false;

    const typed_array_ctor = fastGlobalReadValueForAtomAtPc(ctx, function, global, frame, typed_array_get_pc, typed_array_atom, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
    defer typed_array_ctor.deinit(ctx.runtime);
    const typed_array_object = objectFromValue(typed_array_ctor.value) orelse return false;
    const element_size_u32 = typed_array_object.typedArrayElementSize();
    if (element_size_u32 == 0 or typed_array_object.typedArrayKind() == 0) return false;

    const array_buffer_ctor = fastGlobalReadValueForAtomAtPc(ctx, function, global, frame, array_buffer_get_pc, array_buffer_atom, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
    defer array_buffer_ctor.deinit(ctx.runtime);
    const array_buffer_object = objectFromValue(array_buffer_ctor.value) orelse return false;
    const native_ref = core.function.decodeNativeBuiltinId(array_buffer_object.nativeFunctionIdSlot().*) orelse return false;
    if (native_ref.domain != .buffer or native_ref.id != @intFromEnum(builtins.buffer.ConstructorMethod.array_buffer)) return false;

    const element_size: i32 = @intCast(element_size_u32);
    if (@mod(byte_length.value, element_size) != 0) return false;
    const typed_length = @divExact(byte_length.value, element_size);
    if (typed_length < 0 or typed_length > std.math.maxInt(i32)) return false;

    try shared_vm.printHostOutputArgs(ctx.runtime, output, &.{core.JSValue.int32(typed_length)});
    if (canFinishWithUndefinedAt(function, after_drop)) {
        try stack.pushOwned(core.JSValue.undefinedValue());
        frame.pc = code.len;
    } else {
        frame.pc = after_drop;
    }
    return true;
}

fn decodeImmediateNonNegativeInt32(code: []const u8, pc: usize) ?DecodedImmediateInt32 {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
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
            if (value < 0) return null;
            break :blk .{ .value = value, .next_pc = pc + 2 };
        },
        op.push_i16 => blk: {
            if (pc + 3 > code.len) return null;
            const value = readInt(i16, code[pc + 1 ..][0..2]);
            if (value < 0) return null;
            break :blk .{ .value = value, .next_pc = pc + 3 };
        },
        op.push_i32 => blk: {
            if (pc + 5 > code.len) return null;
            const value = readInt(i32, code[pc + 1 ..][0..4]);
            if (value < 0) return null;
            break :blk .{ .value = value, .next_pc = pc + 5 };
        },
        else => null,
    };
}

fn decodeTypedArrayLengthPrintStore(code: []const u8, pc: usize) ?TypedArrayLengthPrintStore {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.put_loc0 => .{ .local_index = 0, .next_pc = pc + 1 },
        op.put_loc1 => .{ .local_index = 1, .next_pc = pc + 1 },
        op.put_loc2 => .{ .local_index = 2, .next_pc = pc + 1 },
        op.put_loc3 => .{ .local_index = 3, .next_pc = pc + 1 },
        op.put_loc, op.put_loc_check, op.put_loc_check_init => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .local_index = readInt(u16, code[pc + 1 ..][0..2]), .next_pc = pc + 3 };
        },
        op.put_loc8 => blk: {
            if (pc + 2 > code.len) return null;
            break :blk .{ .local_index = code[pc + 1], .next_pc = pc + 2 };
        },
        op.put_var_ref0 => .{ .local_index = 0, .next_pc = pc + 1 },
        op.put_var_ref1 => .{ .local_index = 1, .next_pc = pc + 1 },
        op.put_var_ref2 => .{ .local_index = 2, .next_pc = pc + 1 },
        op.put_var_ref3 => .{ .local_index = 3, .next_pc = pc + 1 },
        op.put_var_ref, op.put_var_ref_check, op.put_var_ref_check_init => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .local_index = readInt(u16, code[pc + 1 ..][0..2]), .next_pc = pc + 3 };
        },
        else => null,
    };
}

fn decodeTypedArrayLengthPrintGet(code: []const u8, pc: usize) ?TypedArrayLengthPrintGet {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.get_loc0 => .{ .idx = 0, .next_pc = pc + 1 },
        op.get_loc1 => .{ .idx = 1, .next_pc = pc + 1 },
        op.get_loc2 => .{ .idx = 2, .next_pc = pc + 1 },
        op.get_loc3 => .{ .idx = 3, .next_pc = pc + 1 },
        op.get_loc, op.get_loc_check => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .idx = readInt(u16, code[pc + 1 ..][0..2]), .next_pc = pc + 3 };
        },
        op.get_loc8 => blk: {
            if (pc + 2 > code.len) return null;
            break :blk .{ .idx = code[pc + 1], .next_pc = pc + 2 };
        },
        op.get_var_ref0 => .{ .idx = 0, .next_pc = pc + 1 },
        op.get_var_ref1 => .{ .idx = 1, .next_pc = pc + 1 },
        op.get_var_ref2 => .{ .idx = 2, .next_pc = pc + 1 },
        op.get_var_ref3 => .{ .idx = 3, .next_pc = pc + 1 },
        op.get_var_ref, op.get_var_ref_check => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .idx = readInt(u16, code[pc + 1 ..][0..2]), .next_pc = pc + 3 };
        },
        else => null,
    };
}

fn decodeDefaultPrintGet(rt: *core.JSRuntime, global: *core.Object, code: []const u8, pc: *usize) bool {
    if (pc.* + 5 > code.len or code[pc.*] != op.get_var) return false;
    const print_atom = readInt(u32, code[pc.* + 1 ..][0..4]);
    if (print_atom != atom_print) return false;
    if (!globalHostOutputAutoInit(rt, global, print_atom)) return false;
    pc.* += 5;
    return true;
}

fn nextInstructionReturnsUndefined(code: []const u8, pc: usize) bool {
    if (pc >= code.len) return false;
    if (code[pc] == op.return_undef) return true;
    return pc + 2 <= code.len and code[pc] == op.undefined and code[pc + 1] == op.return_async;
}

fn tryFuseHostOutputAutoInitAtomCall1(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    atom_id: core.Atom,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) !bool {
    if (atom_id != atom_print) return false;
    if (!globalHostOutputAutoInit(ctx.runtime, global, atom_id)) return false;
    return try tryFuseHostOutputCall1(ctx, output, global, stack, function, frame, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue);
}

fn tryFuseHostOutputCall1(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) !bool {
    if (try tryFuseHostOutputAtomLiteralCall1(ctx, output, stack, function, frame)) return true;
    if (try tryFuseHostOutputStringNumberConstCall1(ctx, output, global, stack, function, frame, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return true;
    if (try tryFuseHostOutputStringLocalNumberCall1(ctx, output, global, stack, function, frame, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return true;
    if (try tryFuseHostOutputNumberStaticLiteralCall1(ctx, output, global, stack, function, frame, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return true;
    if (try tryFuseHostOutputLocalInt32AddCall1(ctx, output, stack, function, frame)) return true;
    if (try tryFuseHostOutputLocalSimpleNumericCall0Call1(ctx, output, stack, function, frame)) return true;
    if (try tryFuseHostOutputLocalCall1(ctx, output, stack, function, frame)) return true;
    if (try tryFuseHostOutputTypeofLocalCall1(ctx, output, stack, function, frame)) return true;
    if (try tryFuseHostOutputLocalFieldStrictEqUndefinedCall1(ctx, output, global, stack, function, frame, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return true;
    if (try tryFuseHostOutputLocalImmediateCompareCall1(ctx, output, stack, function, frame)) return true;
    if (try tryFuseHostOutputLocalLengthCall1(ctx, output, stack, function, frame)) return true;
    if (try tryFuseHostOutputLocalFieldCall1(ctx, output, stack, function, frame)) return true;
    if (try tryFuseHostOutputLocalDenseElementCall1(ctx, output, stack, function, frame)) return true;
    if (try tryFuseHostOutputLocalStringSubstringCall1(ctx, output, global, stack, function, frame)) return true;
    if (try tryFuseHostOutputLocalDenseArrayPopCall1(ctx, output, stack, function, frame)) return true;
    if (try tryFuseHostOutputLocalDenseArrayJoinCall1(ctx, output, stack, function, frame)) return true;
    if (try tryFuseHostOutputLocalCollectionReadCall1(ctx, output, global, stack, function, frame)) return true;
    return false;
}

fn tryFuseHostOutputAtomLiteralCall1(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !bool {
    if (frame.pc + 6 > function.code.len) return false;
    if (function.code[frame.pc] != op.push_atom_value or function.code[frame.pc + 5] != op.call1) return false;

    const arg_atom = readInt(u32, function.code[frame.pc + 1 ..][0..4]);
    try printHostOutputAtomLiteral(ctx.runtime, output, arg_atom);
    try finishUndefinedCallResult(stack, function, frame, frame.pc + 6);
    return true;
}

fn printHostOutputAtomLiteral(rt: *core.JSRuntime, output: ?*std.Io.Writer, atom_id: core.Atom) !void {
    const writer = output orelse return;
    if (core.atom.isTaggedInt(atom_id)) {
        try writer.print("{d}\n", .{core.atom.atomToUInt32(atom_id)});
        return;
    }
    try writer.writeAll(rt.atoms.name(atom_id) orelse "");
    try writer.writeByte('\n');
}

fn tryFuseHostOutputStringNumberConstCall1(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) !bool {
    const pc = frame.pc;
    const code = function.code;
    if (pc + 5 > code.len) return false;
    const callee_op = code[pc];
    if (callee_op != op.get_var and callee_op != op.get_var_undef) return false;
    const callee_atom = readInt(u32, code[pc + 1 ..][0..4]);
    if (callee_atom != atom_string) return false;
    if (!canUseFastGlobalVarLookup(function, callee_atom, frame, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    if (globalLexicalValue(ctx, callee_atom)) |lex_value| {
        lex_value.free(ctx.runtime);
        return false;
    }
    const callee = globalDataPropertyValueForFastPath(ctx.runtime, global, function, pc, callee_atom) orelse return false;
    if (!isStringConstructorValue(callee)) return false;

    const string_arg = stringNumberConstArgAt(function, pc + 5) orelse return false;
    if (string_arg.next_pc >= code.len or code[string_arg.next_pc] != op.call1) return false;

    try printHostOutputStringifiedNumber(output, string_arg.value);
    try finishUndefinedCallResult(stack, function, frame, string_arg.next_pc + 1);
    return true;
}

fn tryFuseHostOutputStringLocalNumberCall1(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) !bool {
    const pc = frame.pc;
    const code = function.code;
    if (pc + 5 > code.len) return false;
    const callee_op = code[pc];
    if (callee_op != op.get_var and callee_op != op.get_var_undef) return false;
    const callee_atom = readInt(u32, code[pc + 1 ..][0..4]);
    if (callee_atom != atom_string) return false;
    if (!canUseFastGlobalVarLookup(function, callee_atom, frame, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    if (globalLexicalValue(ctx, callee_atom)) |lex_value| {
        lex_value.free(ctx.runtime);
        return false;
    }
    const callee = globalDataPropertyValueForFastPath(ctx.runtime, global, function, pc, callee_atom) orelse return false;
    if (!isStringConstructorValue(callee)) return false;

    const local_get = decodeLocalGet(code, pc + 5) orelse return false;
    if (local_get.next_pc + 1 >= code.len or code[local_get.next_pc] != op.call1 or code[local_get.next_pc + 1] != op.call1) return false;
    const input = localReadableBorrowed(frame, local_get.idx, local_get.checked) orelse return false;
    if (input.asInt32() == null and input.asFloat64() == null) return false;

    try printHostOutputStringifiedNumber(output, input);
    try finishUndefinedCallResult(stack, function, frame, local_get.next_pc + 2);
    return true;
}

fn tryFuseHostOutputNumberStaticLiteralCall1(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) !bool {
    const pc = frame.pc;
    const code = function.code;
    if (pc + 10 > code.len) return false;
    const callee_op = code[pc];
    if (callee_op != op.get_var and callee_op != op.get_var_undef) return false;
    const callee_atom = readInt(u32, code[pc + 1 ..][0..4]);
    if (callee_atom != atom_number) return false;
    if (!canUseFastGlobalVarLookup(function, callee_atom, frame, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    if (globalLexicalValue(ctx, callee_atom)) |lex_value| {
        lex_value.free(ctx.runtime);
        return false;
    }

    const field_pc = pc + 5;
    if (code[field_pc] != op.get_field2) return false;
    const method_atom = readInt(u32, code[field_pc + 1 ..][0..4]);
    const number_value = globalDataOrAutoInitValueForReadFastPath(ctx.runtime, global, function, pc, callee_atom) orelse return false;
    defer number_value.deinit(ctx.runtime);
    const native_ref = functionOwnNativeBuiltinRefForFastPath(function, field_pc, ctx.runtime, number_value.value, method_atom) orelse return false;
    if (native_ref.domain != .number) return false;
    const parsed = numberStaticLiteralResultAt(ctx.runtime, function, native_ref.id, field_pc + 5) orelse return false;
    if (parsed.next_pc >= code.len or code[parsed.next_pc] != op.call1) return false;

    const result = value_ops.numberToValue(parsed.number);
    try printHostOutputStringifiedNumber(output, result);
    result.free(ctx.runtime);
    try finishUndefinedCallResult(stack, function, frame, parsed.next_pc + 1);
    return true;
}

fn tryFuseHostOutputLocalInt32AddCall1(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !bool {
    const code = function.code;
    const lhs_get = decodeLocalGet(code, frame.pc) orelse return false;
    const rhs_get = decodeLocalGet(code, lhs_get.next_pc) orelse return false;
    const add_pc = rhs_get.next_pc;
    if (add_pc + 1 >= code.len or code[add_pc] != op.add or code[add_pc + 1] != op.call1) return false;

    const lhs_value = localReadableBorrowed(frame, lhs_get.idx, lhs_get.checked) orelse return false;
    const rhs_value = localReadableBorrowed(frame, rhs_get.idx, rhs_get.checked) orelse return false;
    const lhs = lhs_value.asInt32() orelse return false;
    const rhs = rhs_value.asInt32() orelse return false;
    const result = fastInt32Add(lhs, rhs);
    defer result.free(ctx.runtime);

    try printHostOutputStringifiedNumber(output, result);
    try finishUndefinedCallResult(stack, function, frame, add_pc + 2);
    return true;
}

fn tryFuseHostOutputLocalCall1(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !bool {
    const code = function.code;
    const local_get = decodeLocalGet(code, frame.pc) orelse return false;
    if (local_get.next_pc >= code.len or code[local_get.next_pc] != op.call1) return false;

    const value = localReadableBorrowed(frame, local_get.idx, local_get.checked) orelse return false;
    try shared_vm.printHostOutputArgs(ctx.runtime, output, &.{value});
    try finishUndefinedCallResult(stack, function, frame, local_get.next_pc + 1);
    return true;
}

fn tryFuseHostOutputLocalSimpleNumericCall0Call1(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !bool {
    const code = function.code;
    const local_get = decodeLocalGet(code, frame.pc) orelse return false;
    if (local_get.next_pc + 2 > code.len or code[local_get.next_pc] != op.call0 or code[local_get.next_pc + 1] != op.call1) return false;

    const callable = localReadableBorrowed(frame, local_get.idx, local_get.checked) orelse return false;
    const result = try simpleNumericFunctionResult(ctx.runtime, callable, &.{}) orelse return false;
    defer result.free(ctx.runtime);

    try shared_vm.printHostOutputArgs(ctx.runtime, output, &.{result});
    try finishUndefinedCallResult(stack, function, frame, local_get.next_pc + 2);
    return true;
}

fn tryFuseHostOutputTypeofLocalCall1(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !bool {
    const code = function.code;
    const local_get = decodeLocalGet(code, frame.pc) orelse return false;
    if (local_get.next_pc >= code.len or code[local_get.next_pc] != op.typeof) return false;
    const call_pc = local_get.next_pc + 1;
    if (call_pc >= code.len or code[call_pc] != op.call1) return false;

    const value = localReadableBorrowed(frame, local_get.idx, local_get.checked) orelse return false;
    const type_name = try value_ops.typeOf(ctx.runtime, value);
    defer type_name.free(ctx.runtime);
    try shared_vm.printHostOutputArgs(ctx.runtime, output, &.{type_name});
    try finishUndefinedCallResult(stack, function, frame, call_pc + 1);
    return true;
}

fn tryFuseHostOutputLocalFieldStrictEqUndefinedCall1(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) !bool {
    _ = global;
    const code = function.code;
    const local_get = decodeLocalGet(code, frame.pc) orelse return false;
    if (local_get.next_pc + 5 > code.len or code[local_get.next_pc] != op.get_field) return false;
    const field_atom = readInt(u32, code[local_get.next_pc + 1 ..][0..4]);
    const undefined_pc = local_get.next_pc + 5;
    if (undefined_pc + 6 > code.len) return false;
    const undefined_op = code[undefined_pc];
    if (undefined_op != op.get_var and undefined_op != op.get_var_undef) return false;
    if (readInt(u32, code[undefined_pc + 1 ..][0..4]) != core.atom.ids.undefined_) return false;
    const cmp_pc = undefined_pc + 5;
    const cmp_op = code[cmp_pc];
    if (cmp_op != op.strict_eq and cmp_op != op.strict_neq) return false;
    const call_pc = cmp_pc + 1;
    if (call_pc >= code.len or code[call_pc] != op.call1) return false;
    if (!canUseFastGlobalUndefinedLookup(function, frame, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    if (globalLexicalValue(ctx, core.atom.ids.undefined_)) |lex_value| {
        lex_value.free(ctx.runtime);
        return false;
    }

    const receiver = localReadableBorrowed(frame, local_get.idx, local_get.checked) orelse return false;
    const is_undefined = ordinaryDataPropertyIsUndefinedForFastPath(ctx.runtime, receiver, field_atom) orelse return false;
    const result_value = core.JSValue.boolean(if (cmp_op == op.strict_eq) is_undefined else !is_undefined);
    try shared_vm.printHostOutputArgs(ctx.runtime, output, &.{result_value});
    try finishUndefinedCallResult(stack, function, frame, call_pc + 1);
    return true;
}

fn tryFuseHostOutputLocalImmediateCompareCall1(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !bool {
    const code = function.code;
    const local_get = decodeLocalGet(code, frame.pc) orelse return false;
    const rhs = immediateInt32Operand(code, local_get.next_pc) orelse return false;
    if (rhs.next_pc >= code.len) return false;
    const cmp_op = code[rhs.next_pc];
    if (cmp_op != op.lt and cmp_op != op.lte and cmp_op != op.gt and cmp_op != op.gte and cmp_op != op.eq and cmp_op != op.neq and cmp_op != op.strict_eq and cmp_op != op.strict_neq) return false;
    const call_pc = rhs.next_pc + 1;
    if (call_pc >= code.len or code[call_pc] != op.call1) return false;

    const lhs_value = localReadableBorrowed(frame, local_get.idx, local_get.checked) orelse return false;
    const lhs = value_ops.numberValue(lhs_value) orelse return false;
    const rhs_number: f64 = @floatFromInt(rhs.value);
    const result = switch (cmp_op) {
        op.lt => lhs < rhs_number,
        op.lte => lhs <= rhs_number,
        op.gt => lhs > rhs_number,
        op.gte => lhs >= rhs_number,
        op.eq, op.strict_eq => lhs == rhs_number,
        op.neq, op.strict_neq => lhs != rhs_number,
        else => unreachable,
    };
    const result_value = core.JSValue.boolean(result);
    try shared_vm.printHostOutputArgs(ctx.runtime, output, &.{result_value});
    try finishUndefinedCallResult(stack, function, frame, call_pc + 1);
    return true;
}

fn tryFuseHostOutputLocalLengthCall1(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !bool {
    const code = function.code;
    const local_get = decodeLocalGet(code, frame.pc) orelse return false;
    if (local_get.next_pc >= code.len or code[local_get.next_pc] != op.get_length) return false;
    const call_pc = local_get.next_pc + 1;
    if (call_pc >= code.len or code[call_pc] != op.call1) return false;

    const receiver = localReadableBorrowed(frame, local_get.idx, local_get.checked) orelse return false;
    const length = fastLengthValue(ctx.runtime, receiver) catch return false;
    try shared_vm.printHostOutputArgs(ctx.runtime, output, &.{length});
    try finishUndefinedCallResult(stack, function, frame, call_pc + 1);
    return true;
}

fn tryFuseHostOutputLocalFieldCall1(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !bool {
    const code = function.code;
    const local_get = decodeLocalGet(code, frame.pc) orelse return false;
    if (local_get.next_pc + 6 > code.len or code[local_get.next_pc] != op.get_field) return false;
    const field_atom = readInt(u32, code[local_get.next_pc + 1 ..][0..4]);
    const call_pc = local_get.next_pc + 5;
    if (code[call_pc] != op.call1) return false;

    const receiver = localReadableBorrowed(frame, local_get.idx, local_get.checked) orelse return false;
    const value = ordinaryDataPropertyValueOrUndefinedForFastPath(ctx.runtime, receiver, field_atom) orelse return false;
    try shared_vm.printHostOutputArgs(ctx.runtime, output, &.{value});
    try finishUndefinedCallResult(stack, function, frame, call_pc + 1);
    return true;
}

fn tryFuseHostOutputLocalDenseElementCall1(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !bool {
    const code = function.code;
    const local_get = decodeLocalGet(code, frame.pc) orelse return false;
    const key_operand = immediateInt32Operand(code, local_get.next_pc) orelse return false;
    if (key_operand.next_pc >= code.len or code[key_operand.next_pc] != op.get_array_el) return false;
    const call_pc = key_operand.next_pc + 1;
    if (call_pc >= code.len or code[call_pc] != op.call1) return false;

    const receiver = localReadableBorrowed(frame, local_get.idx, local_get.checked) orelse return false;
    const value = fastDenseArrayElementValue(receiver, core.JSValue.int32(key_operand.value)) orelse return false;
    defer value.free(ctx.runtime);
    try shared_vm.printHostOutputArgs(ctx.runtime, output, &.{value});
    try finishUndefinedCallResult(stack, function, frame, call_pc + 1);
    return true;
}

fn tryFuseHostOutputLocalStringSubstringCall1(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !bool {
    const code = function.code;
    const receiver_get = decodeLocalGet(code, frame.pc) orelse return false;
    const field_pc = receiver_get.next_pc;
    if (field_pc + 5 > code.len or code[field_pc] != op.get_field2) return false;
    const method_atom = readInt(u32, code[field_pc + 1 ..][0..4]);
    if (!fastStringPrototypeMethodIsDefault(ctx.runtime, global, method_atom, @intFromEnum(builtins.string.PrototypeMethod.substring))) return false;

    const receiver = localReadableBorrowed(frame, receiver_get.idx, receiver_get.checked) orelse return false;
    const string_value = stringFromValue(receiver) orelse return false;
    const decoded = decodeStringSubstringImmediateCall(code, field_pc + 5, string_value.len()) orelse return false;
    const call_pc = decoded.call_pc + 3;
    if (call_pc >= code.len or code[call_pc] != op.call1) return false;

    const result = try shared_vm.stringSliceValue(ctx.runtime, receiver, decoded.start, decoded.end - decoded.start);
    defer result.free(ctx.runtime);
    try shared_vm.printHostOutputArgs(ctx.runtime, output, &.{result});
    try finishUndefinedCallResult(stack, function, frame, call_pc + 1);
    return true;
}

fn decodeStringSubstringImmediateCall(code: []const u8, pc: usize, string_len: usize) ?StringSubstringImmediateCall {
    const len_i64 = std.math.cast(i64, string_len) orelse return null;
    if (pc + 3 <= code.len and code[pc] == op.call_method and readInt(u16, code[pc + 1 ..][0..2]) == 0) {
        return .{ .start = 0, .end = string_len, .call_pc = pc };
    }

    const start_arg = immediateInt32Operand(code, pc) orelse return null;
    const start_raw: i64 = start_arg.value;
    var end_raw: i64 = len_i64;
    var call_pc = start_arg.next_pc;
    var argc: u16 = 1;
    if (!(call_pc + 3 <= code.len and code[call_pc] == op.call_method and readInt(u16, code[call_pc + 1 ..][0..2]) == 1)) {
        const end_arg = immediateInt32Operand(code, start_arg.next_pc) orelse return null;
        end_raw = end_arg.value;
        call_pc = end_arg.next_pc;
        argc = 2;
    }
    if (call_pc + 3 > code.len or code[call_pc] != op.call_method or readInt(u16, code[call_pc + 1 ..][0..2]) != argc) return null;

    const start = clampSubstringIndex(start_raw, len_i64);
    const end = clampSubstringIndex(end_raw, len_i64);
    return .{
        .start = @min(start, end),
        .end = @max(start, end),
        .call_pc = call_pc,
    };
}

fn clampSubstringIndex(value: i64, len: i64) usize {
    return @intCast(@max(@as(i64, 0), @min(value, len)));
}

fn tryFuseHostOutputLocalDenseArrayJoinCall1(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !bool {
    const code = function.code;
    const receiver_get = decodeLocalGet(code, frame.pc) orelse return false;
    const field_pc = receiver_get.next_pc;
    if (field_pc + 5 > code.len or code[field_pc] != op.get_field2) return false;
    const method_atom = readInt(u32, code[field_pc + 1 ..][0..4]);
    if (!value_ops.atomNameEql(ctx.runtime, method_atom, "join")) return false;

    const receiver = localReadableBorrowed(frame, receiver_get.idx, receiver_get.checked) orelse return false;
    if (!fastArrayPrototypeMethodIsDefault(receiver, method_atom, @intFromEnum(builtins.array.PrototypeMethod.join))) return false;
    const receiver_object = objectFromValue(receiver) orelse return false;

    const arg_pc = field_pc + 5;
    var separator: core.JSValue = undefined;
    var separator_owned = false;
    defer if (separator_owned) separator.free(ctx.runtime);

    const method_call_pc = blk: {
        if (arg_pc + 3 <= code.len and code[arg_pc] == op.call_method and readInt(u16, code[arg_pc + 1 ..][0..2]) == 0) {
            break :blk arg_pc;
        }
        if (arg_pc + 8 > code.len or code[arg_pc] != op.push_atom_value) return false;
        const separator_atom = readInt(u32, code[arg_pc + 1 ..][0..4]);
        separator = (try atomStringValueForFastPath(ctx.runtime, separator_atom)) orelse return false;
        separator_owned = true;
        const call_pc = arg_pc + 5;
        if (code[call_pc] != op.call_method or readInt(u16, code[call_pc + 1 ..][0..2]) != 1) return false;
        break :blk call_pc;
    };
    const call_pc = method_call_pc + 3;
    if (call_pc >= code.len or code[call_pc] != op.call1) return false;

    const args = if (separator_owned) &[_]core.JSValue{separator} else &[_]core.JSValue{};
    const joined = try shared_vm.qjsFastDensePrimitiveArrayJoin(ctx.runtime, receiver_object, args) orelse return false;
    defer joined.free(ctx.runtime);

    try shared_vm.printHostOutputArgs(ctx.runtime, output, &.{joined});
    try finishUndefinedCallResult(stack, function, frame, call_pc + 1);
    return true;
}

fn tryFuseHostOutputLocalDenseArrayPopCall1(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !bool {
    const code = function.code;
    const receiver_get = decodeLocalGet(code, frame.pc) orelse return false;
    const field_pc = receiver_get.next_pc;
    if (field_pc + 8 > code.len or code[field_pc] != op.get_field2) return false;
    const method_atom = readInt(u32, code[field_pc + 1 ..][0..4]);
    if (!value_ops.atomNameEql(ctx.runtime, method_atom, "pop")) return false;
    if (code[field_pc + 5] != op.call_method or readInt(u16, code[field_pc + 6 ..][0..2]) != 0) return false;
    const call_pc = field_pc + 8;
    if (call_pc >= code.len or code[call_pc] != op.call1) return false;

    const receiver = localReadableBorrowed(frame, receiver_get.idx, receiver_get.checked) orelse return false;
    if (!fastArrayPrototypeMethodIsDefault(receiver, method_atom, @intFromEnum(builtins.array.PrototypeMethod.pop))) return false;
    const receiver_object = objectFromValue(receiver) orelse return false;
    const value = shared_vm.qjsFastDensePrimitiveArrayPop(receiver_object) orelse return false;
    defer value.free(ctx.runtime);

    try shared_vm.printHostOutputArgs(ctx.runtime, output, &.{value});
    try finishUndefinedCallResult(stack, function, frame, call_pc + 1);
    return true;
}

fn tryFuseHostOutputLocalCollectionReadCall1(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !bool {
    _ = global;
    const code = function.code;
    const receiver_get = decodeLocalGet(code, frame.pc) orelse return false;
    const field_pc = receiver_get.next_pc;
    if (field_pc + 5 > code.len or code[field_pc] != op.get_field2) return false;

    const method_atom = readInt(u32, code[field_pc + 1 ..][0..4]);
    const receiver = localReadableBorrowed(frame, receiver_get.idx, receiver_get.checked) orelse return false;
    const receiver_object = objectFromValue(receiver) orelse return false;
    const method = collectionHostOutputReadMethod(ctx.runtime, receiver_object.class_id, method_atom) orelse return false;
    if (!fastCollectionPrototypeMethodIsDefault(receiver, method_atom, @intFromEnum(method))) return false;

    const key_operand = decodeCollectionHostOutputKeyOperand(code, field_pc + 5) orelse return false;
    const method_call_pc = key_operand.next_pc;
    if (method_call_pc + 4 > code.len or code[method_call_pc] != op.call_method) return false;
    if (readInt(u16, code[method_call_pc + 1 ..][0..2]) != 1) return false;
    const call_pc = method_call_pc + 3;
    if (call_pc >= code.len or code[call_pc] != op.call1) return false;

    const key = try materializeCollectionHostOutputKey(ctx.runtime, frame, key_operand) orelse return false;
    defer key.deinit(ctx.runtime);
    const value = try builtins.collection.readOnlyMethodCallObject(ctx.runtime, receiver_object, method, key.value);
    defer value.free(ctx.runtime);
    try shared_vm.printHostOutputArgs(ctx.runtime, output, &.{value});
    try finishUndefinedCallResult(stack, function, frame, call_pc + 1);
    return true;
}

fn decodeCollectionHostOutputKeyOperand(code: []const u8, pc: usize) ?CollectionHostOutputKeyOperand {
    if (pc + 5 <= code.len and code[pc] == op.push_atom_value) {
        return .{
            .kind = .atom,
            .atom = readInt(u32, code[pc + 1 ..][0..4]),
            .next_pc = pc + 5,
        };
    }
    if (decodeLocalGet(code, pc)) |get| {
        return .{
            .kind = .local,
            .local_idx = get.idx,
            .local_checked = get.checked,
            .next_pc = get.next_pc,
        };
    }
    if (immediateInt32Operand(code, pc)) |immediate| {
        return .{
            .kind = .int32,
            .int32 = immediate.value,
            .next_pc = immediate.next_pc,
        };
    }
    return null;
}

fn materializeCollectionHostOutputKey(
    rt: *core.JSRuntime,
    frame: *const frame_mod.Frame,
    operand: CollectionHostOutputKeyOperand,
) !?CollectionHostOutputKey {
    return switch (operand.kind) {
        .atom => .{
            .value = try rt.atoms.toStringValue(rt, operand.atom),
            .owned = true,
        },
        .local => .{
            .value = localReadableBorrowed(frame, operand.local_idx, operand.local_checked) orelse return null,
            .owned = false,
        },
        .int32 => .{
            .value = core.JSValue.int32(operand.int32),
            .owned = false,
        },
    };
}

fn collectionHostOutputReadMethod(
    rt: *core.JSRuntime,
    class_id: core.ClassId,
    atom_id: core.Atom,
) ?builtins.collection.PrototypeMethod {
    return switch (class_id) {
        core.class.ids.map, core.class.ids.weakmap => {
            if (value_ops.atomNameEql(rt, atom_id, "get")) return .get;
            if (value_ops.atomNameEql(rt, atom_id, "has")) return .has;
            return null;
        },
        core.class.ids.set, core.class.ids.weakset => {
            if (value_ops.atomNameEql(rt, atom_id, "has")) return .has;
            return null;
        },
        else => null,
    };
}

fn globalHostOutputAutoInit(rt: *core.JSRuntime, global: *core.Object, atom_id: core.Atom) bool {
    if (global.exotic != null) return false;
    for (global.properties) |*entry| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        if (entry.flags.accessor) return false;
        return switch (entry.slot) {
            .auto_init => |info| info.host_function_kind == core.host_function.ids.output or
                (info.host_function_kind == core.host_function.ids.external_host and
                    shared_vm.isOutputExternalHostFunctionId(rt, info.external_host_function_id)),
            .data, .accessor, .deleted => false,
        };
    }
    return false;
}

fn globalDataOrAutoInitValueForReadFastPath(
    rt: *core.JSRuntime,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    site_pc: usize,
    atom_id: core.Atom,
) ?FastGlobalReadValue {
    if (globalDataPropertyValueForFastPath(rt, global, function, site_pc, atom_id)) |value| {
        return .{ .value = value, .owned = false };
    }
    if (global.exotic != null) return null;
    for (global.properties) |*entry| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        if (entry.flags.accessor) return null;
        return switch (entry.slot) {
            .data => |stored| .{ .value = stored, .owned = false },
            .auto_init => .{ .value = global.getProperty(atom_id), .owned = true },
            .accessor, .deleted => null,
        };
    }
    return null;
}

fn useFastGlobalDataValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    site_pc: usize,
    atom_id: core.Atom,
    value: core.JSValue,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    if (atom_id == atom_print and isHostOutputFunctionValue(ctx.runtime, value) and
        try tryFuseHostOutputCall1(ctx, output, global, stack, function, frame, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return .done;
    if (atom_id == atom_date and try tryFuseGlobalDateNowCall(ctx, stack, function, frame, value)) return .done;
    if (atom_id == atom_string and try tryFuseGlobalStringCall1NumberConst(ctx.runtime, stack, function, frame, value)) return .done;
    if (atom_id == atom_string and
        try tryFuseGlobalStringFromCharCodeInt32LocalAppend(ctx, function, global, frame, stack, value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
    if (try tryFuseGlobalInductionInt32AddRange(ctx, function, global, frame, atom_id, value, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
    if (try tryFuseGlobalSimpleNumericCallAddRange(ctx, function, global, frame, atom_id, value, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return .done;
    if (isSimpleNumericCallableCandidate(value) and
        try tryFuseGlobalSimpleNumericCallAddStore(ctx, function, global, frame, stack, value, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return .done;
    if (try tryFuseGlobalPropertyReadAddRange(ctx, function, global, frame, atom_id, value, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return .done;
    const value_int = value.asInt32();
    if (value_int != null) {
        if (tryFuseGlobalDataInt32CompareFalseBranch(function, frame, value)) return .done;
        if (try tryFuseGlobalDataInt32ImmediateBinary(ctx, global, stack, function, frame, atom_id, value, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return .done;
    }
    if (value_int != null or value.asShortBigInt() != null) {
        if (nextOpIsPostUpdate(function, frame) and
            try tryFuseDroppedGlobalDataPostUpdateFromValue(ctx, global, function, frame, site_pc, atom_id, value)) return .done;
    } else {
        if (value.isString()) {
            if (try tryFuseGlobalStringPercentHexAddStore(ctx, stack, function, global, frame, catch_target, value, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal, handleCatchableRuntimeError)) |step| return step;
            if (try tryFuseGlobalUriCall1WithStringArgument(ctx, stack, function, frame, catch_target, global, value, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, handleCatchableRuntimeError)) |step| return step;
        } else if (nextOpCanStartGlobalUriCall1(function, frame)) {
            if (try tryFuseGlobalUriCall1(ctx, stack, function, frame, catch_target, global, value, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, handleCatchableRuntimeError)) |step| return step;
        }
    }
    try pushBorrowedValueOrFuseLocalAdd(ctx, stack, function, global, frame, value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    return .done;
}

fn tryFuseGlobalStringCall1NumberConst(
    rt: *core.JSRuntime,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    callee: core.JSValue,
) !bool {
    if (!isStringConstructorValue(callee)) return false;
    const result = stringNumberConstCall1At(rt, function, frame.pc) orelse return false;
    errdefer result.value.free(rt);
    try stack.pushOwned(result.value);
    frame.pc = result.next_pc;
    return true;
}

fn stringNumberConstArgAt(function: *const bytecode.Bytecode, pc: usize) ?StringNumberConstArg {
    const code = function.code;
    if (pc >= code.len) return null;
    if (immediateInt32Operand(code, pc)) |immediate| {
        if (immediate.next_pc >= code.len or code[immediate.next_pc] != op.call1) return null;
        return .{ .value = core.JSValue.int32(immediate.value), .next_pc = immediate.next_pc + 1 };
    }
    const const_index: usize, const call_pc: usize = switch (code[pc]) {
        op.push_const8 => blk: {
            if (pc + 2 > code.len) return null;
            break :blk .{ code[pc + 1], pc + 2 };
        },
        op.push_const => blk: {
            if (pc + 5 > code.len) return null;
            break :blk .{ readInt(u32, code[pc + 1 ..][0..4]), pc + 5 };
        },
        else => return null,
    };
    if (call_pc >= code.len or code[call_pc] != op.call1) return null;
    if (const_index >= function.constants.values.len) return null;
    const input = function.constants.values[const_index];
    if (input.asInt32() == null and input.asFloat64() == null) return null;
    return .{ .value = input, .next_pc = call_pc + 1 };
}

fn printHostOutputStringifiedNumber(output: ?*std.Io.Writer, value: core.JSValue) !void {
    const writer = output orelse return;
    if (value.asInt32()) |int_value| {
        var buffer: [32]u8 = undefined;
        try writer.writeAll(dtoa.formatInt32(&buffer, int_value));
        try writer.writeByte('\n');
        return;
    }
    const float_value = value.asFloat64() orelse return;
    if (std.math.isNan(float_value)) {
        try writer.writeAll("NaN\n");
        return;
    }
    if (std.math.isPositiveInf(float_value)) {
        try writer.writeAll("Infinity\n");
        return;
    }
    if (std.math.isNegativeInf(float_value)) {
        try writer.writeAll("-Infinity\n");
        return;
    }
    if (float_value == 0 and std.math.isNegativeInf(1.0 / float_value)) {
        try writer.writeAll("0\n");
        return;
    }
    var buffer: [64]u8 = undefined;
    try writer.writeAll(try value_ops.formatFiniteNumber(&buffer, float_value));
    try writer.writeByte('\n');
}

fn stringNumberConstCall1At(rt: *core.JSRuntime, function: *const bytecode.Bytecode, pc: usize) ?StringNumberConstCall {
    const code = function.code;
    if (pc >= code.len) return null;
    if (immediateInt32Operand(code, pc)) |immediate| {
        if (immediate.next_pc >= code.len or code[immediate.next_pc] != op.call1) return null;
        const input = core.JSValue.int32(immediate.value);
        const value = value_ops.toStringValue(rt, input) catch return null;
        return .{ .value = value, .next_pc = immediate.next_pc + 1 };
    }
    const const_index: usize, const call_pc: usize = switch (code[pc]) {
        op.push_const8 => blk: {
            if (pc + 2 > code.len) return null;
            break :blk .{ code[pc + 1], pc + 2 };
        },
        op.push_const => blk: {
            if (pc + 5 > code.len) return null;
            break :blk .{ readInt(u32, code[pc + 1 ..][0..4]), pc + 5 };
        },
        else => return null,
    };
    if (call_pc >= code.len or code[call_pc] != op.call1) return null;

    const input = function.constants.get(const_index) orelse return null;
    defer input.free(rt);
    if (input.isObject() or input.isSymbol()) return null;
    if (input.asInt32() == null and input.asFloat64() == null) return null;

    const value = value_ops.toStringValue(rt, input) catch return null;
    return .{ .value = value, .next_pc = call_pc + 1 };
}

fn isStringConstructorValue(value: core.JSValue) bool {
    const object = objectFromValue(value) orelse return false;
    const native_ref = core.function.decodeNativeBuiltinId(object.nativeFunctionIdSlot().*) orelse return false;
    return native_ref.domain == .string and native_ref.id == @intFromEnum(builtins.string.ConstructorMethod.call);
}

fn pushValueOrFuseLocalAdd(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    value: core.JSValue,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !void {
    errdefer value.free(ctx.runtime);
    if (try tryFuseLocalAddWithValue(ctx, stack, function, global, frame, value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) {
        value.free(ctx.runtime);
        return;
    }
    try stack.pushOwned(value);
}

fn nextOpIsPostUpdate(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame) bool {
    if (frame.pc >= function.code.len) return false;
    return function.code[frame.pc] == op.post_inc or function.code[frame.pc] == op.post_dec;
}

fn tryFuseDroppedGlobalDataPostUpdateFromValue(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    site_pc: usize,
    atom_id: core.Atom,
    old: core.JSValue,
) !bool {
    if (frame.pc + 7 > function.code.len) return false;
    const update_op = function.code[frame.pc];
    if (update_op != op.post_inc and update_op != op.post_dec) return false;
    if (function.code[frame.pc + 1] != op.put_var) return false;
    if (function.code[frame.pc + 6] != op.drop) return false;
    const store_atom = readInt(u32, function.code[frame.pc + 2 ..][0..4]);
    if (store_atom != atom_id) return false;

    const updated = blk: {
        if (old.asInt32()) |old_int| {
            break :blk switch (update_op) {
                op.post_inc => fastInt32Add(old_int, 1),
                op.post_dec => fastInt32Sub(old_int, 1),
                else => unreachable,
            };
        }
        if (old.asShortBigInt()) |old_bigint| {
            if (value_ops.shortBigIntUnary(update_op, old_bigint)) |fast| break :blk fast;
        }
        return false;
    };
    errdefer updated.free(ctx.runtime);
    if (!setGlobalDataPropertyForFastPath(ctx.runtime, global, function, site_pc, atom_id, updated)) {
        updated.free(ctx.runtime);
        return false;
    }
    const updated_int_for_branch = updated.asInt32();
    frame.pc += 7;
    updated.free(ctx.runtime);
    if (updated_int_for_branch) |updated_int| {
        _ = tryFuseFollowingGlobalInt32Goto16Condition(ctx, function, frame, atom_id, updated_int);
    }
    return true;
}

fn tryFuseFollowingGlobalInt32Goto16Condition(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    atom_id: core.Atom,
    lhs: i32,
) bool {
    if (ctx.runtime.hasInterruptHandler()) return false;
    const code = function.code;
    if (frame.pc + 3 > code.len or code[frame.pc] != op.goto16) return false;
    const goto_operand_pc = frame.pc + 1;
    const goto_diff = readInt(i16, code[goto_operand_pc..][0..2]);
    const target_pc_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (target_pc_i64 < 0) return false;
    const target_pc: usize = @intCast(target_pc_i64);
    if (target_pc + 10 > code.len) return false;
    const read_op = code[target_pc];
    if (read_op != op.get_var and read_op != op.get_var_undef) return false;
    const read_atom = readInt(u32, code[target_pc + 1 ..][0..4]);
    if (read_atom != atom_id) return false;
    const rhs = immediateInt32Operand(code, target_pc + 5) orelse return false;
    if (rhs.next_pc >= code.len) return false;
    const cmp_op = code[rhs.next_pc];
    const result = switch (cmp_op) {
        op.lt => lhs < rhs.value,
        op.lte => lhs <= rhs.value,
        op.gt => lhs > rhs.value,
        op.gte => lhs >= rhs.value,
        else => return false,
    };
    const branch_pc = rhs.next_pc + 1;
    if (branch_pc >= code.len) return false;
    switch (code[branch_pc]) {
        op.if_false8 => {
            if (branch_pc + 2 > code.len) return false;
            const operand_pc = branch_pc + 1;
            const diff: i8 = @bitCast(code[operand_pc]);
            const false_pc_i64 = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            if (false_pc_i64 < 0) return false;
            frame.pc = if (result) operand_pc + 1 else @intCast(false_pc_i64);
            return true;
        },
        op.if_false => {
            if (branch_pc + 5 > code.len) return false;
            const operand_pc = branch_pc + 1;
            const diff = readInt(i32, code[operand_pc..][0..4]);
            const false_pc_i64 = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            if (false_pc_i64 < 0) return false;
            frame.pc = if (result) operand_pc + 4 else @intCast(false_pc_i64);
            return true;
        },
        else => return false,
    }
}

fn fastGlobalReadValueForAtomAtPc(
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
) ?FastGlobalReadValue {
    if (!canUseFastGlobalVarLookup(function, atom_id, frame, eval_local_names, eval_var_ref_names, eval_with_object)) return null;
    if (globalLexicalValue(ctx, atom_id)) |lexical_value| {
        lexical_value.free(ctx.runtime);
        return null;
    }
    return globalDataOrAutoInitValueForReadFastPath(ctx.runtime, global, function, site_pc, atom_id);
}

fn fastGlobalDataValueForAtomAtPcNoProfile(
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
    return globalDataPropertyValueForFastPathNoProfile(ctx.runtime, global, function, site_pc, atom_id);
}

fn nextOpCanStartGlobalUriCall1(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame) bool {
    if (frame.pc >= function.code.len) return false;
    const code = function.code;
    return switch (code[frame.pc]) {
        op.push_atom_value => frame.pc + 6 <= code.len and code[frame.pc + 5] == op.call1,
        op.get_var_ref, op.get_var_ref_check => frame.pc + 4 <= code.len and code[frame.pc + 3] == op.call1,
        op.get_var_ref0, op.get_var_ref1, op.get_var_ref2, op.get_var_ref3 => frame.pc + 1 <= code.len and code[frame.pc + 1] == op.call1,
        op.get_var, op.get_var_undef => frame.pc + 6 <= code.len and code[frame.pc + 5] == op.call1,
        else => false,
    };
}

fn tryFuseGlobalDateNowCall(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    receiver: core.JSValue,
) !bool {
    const pc = frame.pc;
    const code = function.code;
    if (pc + 8 > code.len or code[pc] != op.get_field2) return false;
    if (code[pc + 5] != op.call_method) return false;
    if (readInt(u16, code[pc + 6 ..][0..2]) != 0) return false;

    const atom_id = readInt(u32, code[pc + 1 ..][0..4]);
    const native_ref = functionOwnNativeBuiltinRefForFastPath(function, pc, ctx.runtime, receiver, atom_id) orelse return false;
    if (native_ref.domain != .date or native_ref.id != @intFromEnum(builtins.date.StaticMethod.now)) return false;

    const result = try builtins.date.staticCall(ctx.runtime, native_ref.id, &.{});
    errdefer result.free(ctx.runtime);
    try stack.pushOwned(result);
    frame.pc = pc + 8;
    return true;
}

fn tryFuseGlobalUriCall1(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
    callee: core.JSValue,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
    comptime setSlotValue: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !?Step {
    const function_object = objectFromValue(callee) orelse return null;
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*) orelse return null;
    if (native_ref.domain != .uri) return null;

    const call_arg = try uriCall1StringArgument(ctx, function, frame, global, globalLexicalValue) orelse return null;
    defer if (call_arg.owned) call_arg.value.free(ctx.runtime);

    if (try tryFuseUriDecodeSingleFourByteStrictEqFromCharCode(ctx, stack, function, frame, catch_target, global, native_ref.id, call_arg.value, call_arg.next_pc, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, handleCatchableRuntimeError)) |step| return step;

    const result = builtins.uri.call(ctx.runtime, native_ref.id, call_arg.value) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    errdefer result.free(ctx.runtime);
    try stack.pushOwned(result);
    frame.pc = call_arg.next_pc;
    return .done;
}

fn tryFuseGlobalUriCall1AtCurrentPc(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
    comptime setSlotValue: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !?Step {
    const pc = frame.pc;
    const code = function.code;
    if (pc + 5 > code.len) return null;
    const callee_op = code[pc];
    if (callee_op != op.get_var and callee_op != op.get_var_undef) return null;

    const callee_atom = readInt(u32, code[pc + 1 ..][0..4]);
    const callee = fastGlobalDataValueForAtomAtPc(ctx, function, global, frame, pc, callee_atom, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return null;
    frame.pc = pc + 5;
    if (try tryFuseGlobalUriCall1(ctx, stack, function, frame, catch_target, global, callee, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, handleCatchableRuntimeError)) |step| return step;
    frame.pc = pc;
    return null;
}

fn tryFuseGlobalUriCall1WithStringArgument(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
    argument: core.JSValue,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !?Step {
    if (!argument.isString()) return null;
    const code = function.code;
    if (frame.pc + 6 > code.len) return null;
    const callee_op = code[frame.pc];
    if (callee_op != op.get_var and callee_op != op.get_var_undef) return null;
    if (code[frame.pc + 5] != op.call1) return null;

    const callee_atom = readInt(u32, code[frame.pc + 1 ..][0..4]);
    if (!canUseFastGlobalVarLookup(function, callee_atom, frame, eval_local_names, eval_var_ref_names, eval_with_object)) return null;
    if (globalLexicalValue(ctx, callee_atom)) |lex_value| {
        lex_value.free(ctx.runtime);
        return null;
    }
    const callee = globalDataPropertyValueForFastPath(ctx.runtime, global, function, frame.pc, callee_atom) orelse return null;
    const function_object = objectFromValue(callee) orelse return null;
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*) orelse return null;
    if (native_ref.domain != .uri) return null;

    const result = builtins.uri.call(ctx.runtime, native_ref.id, argument) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    errdefer result.free(ctx.runtime);
    try stack.pushOwned(result);
    frame.pc += 6;
    return .done;
}

fn tryFuseGlobalDataInt32CompareFalseBranch(
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    value: core.JSValue,
) bool {
    const lhs = value.asInt32() orelse return false;
    const immediate = immediateInt32Operand(function.code, frame.pc) orelse return false;
    if (immediate.next_pc + 2 > function.code.len) return false;
    const cmp_op = function.code[immediate.next_pc];
    const result = int32ImmediateCompare(lhs, cmp_op, immediate.value) orelse return false;
    const branch_pc = immediate.next_pc + 1;
    const branch_op = function.code[branch_pc];
    switch (branch_op) {
        op.if_false8 => {
            if (branch_pc + 2 > function.code.len) return false;
            const operand_pc = branch_pc + 1;
            const diff: i8 = @bitCast(function.code[operand_pc]);
            frame.pc = if (result)
                operand_pc + 1
            else
                @intCast(@as(i64, @intCast(operand_pc)) + @as(i64, diff));
            return true;
        },
        op.if_false => {
            if (branch_pc + 5 > function.code.len) return false;
            const operand_pc = branch_pc + 1;
            const diff = readInt(i32, function.code[operand_pc..][0..4]);
            frame.pc = if (result)
                operand_pc + 4
            else
                @intCast(@as(i64, @intCast(operand_pc)) + @as(i64, diff));
            return true;
        },
        else => return false,
    }
}

pub fn tryFuseBackwardGotoGlobalDataInt32CompareFalseBranch(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    goto_opc: u8,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) bool {
    const operand_pc = frame.pc;
    const target_pc = backwardGotoTarget(function.code, operand_pc, goto_opc) orelse return false;
    const global_get = decodeGlobalDataGet(function.code, target_pc) orelse return false;
    if (!canUseInstalledGlobalDataIc(ctx, function, global_get.atom, frame, eval_local_names, eval_var_ref_names, eval_with_object, global)) return false;
    const lhs_value = globalDataPropertyValueForFastPath(ctx.runtime, global, function, target_pc, global_get.atom) orelse return false;
    const lhs = lhs_value.asInt32() orelse return false;

    const immediate = immediateInt32Operand(function.code, global_get.next_pc) orelse return false;
    if (immediate.next_pc >= function.code.len) return false;
    const result = int32ImmediateCompare(lhs, function.code[immediate.next_pc], immediate.value) orelse return false;
    const branch = decodeFalseBranch(function.code, immediate.next_pc + 1) orelse return false;
    frame.pc = if (result) branch.true_pc else branch.false_pc;
    return true;
}

fn int32ImmediateCompare(lhs: i32, cmp_op: u8, rhs: i32) ?bool {
    return switch (cmp_op) {
        op.lt => lhs < rhs,
        op.lte => lhs <= rhs,
        op.gt => lhs > rhs,
        op.gte => lhs >= rhs,
        else => null,
    };
}

fn tryFuseGlobalDataInt32ImmediateBinary(
    ctx: *core.JSContext,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    source_atom: core.Atom,
    value: core.JSValue,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) !bool {
    var current = value.asInt32() orelse return false;
    const source_value = current;
    var pc = frame.pc;
    var consumed = false;
    while (true) {
        const immediate = immediateInt32Operand(function.code, pc) orelse break;
        if (immediate.next_pc >= function.code.len) break;
        const result = fastInt32ImmediateBinary(function.code[immediate.next_pc], current, immediate.value) orelse break;
        consumed = true;
        pc = immediate.next_pc + 1;
        current = result.asInt32() orelse {
            frame.pc = pc;
            try pushImmediateBinaryResultMaybeFuseStackBinaryOrGlobalStore(ctx, global, stack, function, frame, result, eval_local_names, eval_var_ref_names, eval_with_object);
            return true;
        };
    }
    if (!consumed) return false;
    frame.pc = pc;
    if (tryFuseGlobalDataValueStore(ctx, global, function, frame, core.JSValue.int32(current), eval_local_names, eval_var_ref_names, eval_with_object)) |stored| {
        if (stored.atom != source_atom) {
            _ = tryFuseFollowingSameGlobalDataInt32ImmediateBinaryStore(ctx, global, function, frame, source_atom, source_value, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue);
        }
        return true;
    }
    try pushImmediateBinaryResultMaybeFuseStackBinaryOrGlobalStore(ctx, global, stack, function, frame, core.JSValue.int32(current), eval_local_names, eval_var_ref_names, eval_with_object);
    return true;
}

pub fn tryFuseGlobalInt32PrefixTermsStore(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    start_pc: usize,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) bool {
    const start = immediateInt32Operand(function.code, start_pc) orelse return false;
    var current = start.value;
    var pc = start.next_pc;
    var consumed_global_term = false;

    while (tryFoldImmediateInt32At(function.code, &pc, &current)) |result| {
        current = result.asInt32() orelse return false;
    }
    while (tryFoldFollowingImmediateInt32Term(function.code, &pc, &current)) |result| {
        current = result.asInt32() orelse return false;
    }
    while (tryFoldFollowingGlobalInt32Term(ctx, global, function, frame, &pc, &current, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) |result| {
        current = result.asInt32() orelse return false;
        consumed_global_term = true;
    }
    if (!consumed_global_term) return false;

    const saved_pc = frame.pc;
    frame.pc = pc;
    if (tryFuseGlobalDataValueStore(ctx, global, function, frame, core.JSValue.int32(current), eval_local_names, eval_var_ref_names, eval_with_object)) |stored| {
        while (tryFuseFollowingSameGlobalDataInt32ImmediateBinaryStore(ctx, global, function, frame, stored.atom, current, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) {}
        return true;
    }
    frame.pc = saved_pc;
    return false;
}

fn tryFoldImmediateInt32At(code: []const u8, pc: *usize, current: *const i32) ?core.JSValue {
    const immediate = immediateInt32Operand(code, pc.*) orelse return null;
    if (immediate.next_pc >= code.len) return null;
    const result = fastInt32ImmediateBinary(code[immediate.next_pc], current.*, immediate.value) orelse return null;
    pc.* = immediate.next_pc + 1;
    return result;
}

fn tryFoldFollowingImmediateInt32Term(code: []const u8, pc: *usize, current: *const i32) ?core.JSValue {
    const rhs = immediateInt32Operand(code, pc.*) orelse return null;
    var rhs_value = rhs.value;
    var rhs_pc = rhs.next_pc;
    while (tryFoldImmediateInt32At(code, &rhs_pc, &rhs_value)) |rhs_result| {
        rhs_value = rhs_result.asInt32() orelse return null;
    }
    if (rhs_pc >= code.len) return null;
    const result = fastInt32ImmediateBinary(code[rhs_pc], current.*, rhs_value) orelse return null;
    pc.* = rhs_pc + 1;
    return result;
}

fn tryFoldFollowingGlobalInt32Term(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    pc: *usize,
    current: *const i32,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) ?core.JSValue {
    const get = decodeGlobalDataGet(function.code, pc.*) orelse return null;
    const value = fastGlobalDataValueForAtomAtPc(ctx, function, global, frame, pc.*, get.atom, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return null;
    var rhs_value = value.asInt32() orelse return null;
    var rhs_pc = get.next_pc;
    while (tryFoldImmediateInt32At(function.code, &rhs_pc, &rhs_value)) |rhs_result| {
        rhs_value = rhs_result.asInt32() orelse return null;
    }
    if (rhs_pc >= function.code.len) return null;
    const result = fastInt32ImmediateBinary(function.code[rhs_pc], current.*, rhs_value) orelse return null;
    pc.* = rhs_pc + 1;
    return result;
}

fn tryFuseFollowingSameGlobalDataInt32ImmediateBinaryStore(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    source_atom: core.Atom,
    source_value: i32,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) bool {
    const start_pc = frame.pc;
    const source_get = decodeGlobalDataGet(function.code, start_pc) orelse return false;
    if (source_get.atom != source_atom) return false;
    const borrowed = fastGlobalDataValueForAtomAtPc(ctx, function, global, frame, start_pc, source_atom, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
    const current_source = borrowed.asInt32() orelse return false;
    if (current_source != source_value) return false;

    var current = source_value;
    var pc = source_get.next_pc;
    var consumed = false;
    while (true) {
        const immediate = immediateInt32Operand(function.code, pc) orelse break;
        if (immediate.next_pc >= function.code.len) break;
        const result = fastInt32ImmediateBinary(function.code[immediate.next_pc], current, immediate.value) orelse break;
        current = result.asInt32() orelse return false;
        consumed = true;
        pc = immediate.next_pc + 1;
    }
    if (!consumed) return false;

    frame.pc = pc;
    if (tryFuseGlobalDataValueStore(ctx, global, function, frame, core.JSValue.int32(current), eval_local_names, eval_var_ref_names, eval_with_object) != null) return true;
    frame.pc = start_pc;
    return false;
}

fn tryFuseGlobalDataValueStore(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    value: core.JSValue,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) ?StoredGlobalDataValue {
    const rt = ctx.runtime;
    if (frame.pc + 5 > function.code.len or function.code[frame.pc] != op.put_var) return null;
    const store_pc = frame.pc;
    const atom_id = readInt(u32, function.code[frame.pc + 1 ..][0..4]);
    if (!canFuseGlobalDataWrite(function, frame, atom_id, eval_local_names, eval_var_ref_names, eval_with_object)) return null;
    if (!setGlobalWritableDataStoreForFastPathOwned(rt, ctx.lexicals, global, function, store_pc, atom_id, value)) return null;
    frame.pc += 5;
    return .{ .atom = atom_id };
}

fn pushImmediateBinaryResultMaybeFuseStackBinaryOrGlobalStore(
    ctx: *core.JSContext,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    rhs_value: core.JSValue,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) !void {
    const rhs = rhs_value.asInt32() orelse {
        try stack.pushOwned(rhs_value);
        return;
    };
    if (frame.pc < function.code.len) {
        if (stack.peekBorrowed()) |lhs_value| {
            if (lhs_value.asInt32()) |lhs| {
                if (fastInt32ImmediateBinary(function.code[frame.pc], lhs, rhs)) |result| {
                    const lhs_owned = try stack.pop();
                    defer lhs_owned.free(ctx.runtime);
                    frame.pc += 1;
                    if (tryFuseGlobalDataValueStore(ctx, global, function, frame, result, eval_local_names, eval_var_ref_names, eval_with_object) != null) {
                        return;
                    }
                    try stack.pushOwned(result);
                    return;
                }
            }
        }
    }
    try stack.pushOwned(rhs_value);
}

fn tryFuseGlobalUriFourByteDecodeCountRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    prefix_value: core.JSValue,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (ctx.runtime.hasInterruptHandler()) return false;
    const prefix_string = stringFromValue(prefix_value) orelse return false;
    const prefix_bytes = prefix_string.borrowLatin1() orelse return false;
    if (prefix_bytes.len != 9 or prefix_bytes[0] != '%' or prefix_bytes[3] != '%' or prefix_bytes[6] != '%') return false;
    const byte0 = percentHexByte(prefix_bytes[1], prefix_bytes[2]) orelse return false;
    const byte1 = percentHexByte(prefix_bytes[4], prefix_bytes[5]) orelse return false;
    const byte2 = percentHexByte(prefix_bytes[7], prefix_bytes[8]) orelse return false;
    if (byte0 != 0xf0 or byte1 != 0xa0 or byte2 < 0x80 or byte2 > 0xbf) return false;

    const plan = decodeUriFourByteRangePlan(ctx, function, global, frame, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
    const current_b3_value = fastGlobalDataValueForAtomAtPcNoProfile(ctx, function, global, frame, plan.index_b3_get_pc, plan.index_b3_atom, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
    const current_b3 = current_b3_value.asInt32() orelse return false;
    if (current_b3 != byte2) return false;

    const current_b4 = globalWritableDataStoreInt32ForFastPath(ctx.runtime, ctx.lexicals, global, function, plan.induction_put_pc, plan.induction_atom) orelse return false;
    if (current_b4 < 0x80 or current_b4 > plan.limit or plan.limit > 0xbf) return false;
    const iteration_count_i64 = @as(i64, plan.limit) - @as(i64, current_b4) + 1;
    if (iteration_count_i64 <= 0 or iteration_count_i64 > std.math.maxInt(i32)) return false;
    const iteration_count: i32 = @intCast(iteration_count_i64);

    const count_current = globalWritableDataStoreInt32ForFastPath(ctx.runtime, ctx.lexicals, global, function, plan.count_put_pc, plan.count_atom) orelse return false;
    const count_next_overflow = @addWithOverflow(count_current, iteration_count);
    if (count_next_overflow[1] != 0) return false;
    const count_next = count_next_overflow[0];

    const final_b4 = plan.limit;
    const codepoint: i32 =
        (@as(i32, byte0 & 0x07) * 0x40000) +
        (@as(i32, byte1 & 0x3f) * 0x1000) +
        (@as(i32, byte2 & 0x3f) * 0x40) +
        (final_b4 & 0x3f);
    if (codepoint < 0x10000 or codepoint > 0x10ffff) return false;
    const pair = shared_vm.surrogatePairFromCodePoint(@intCast(codepoint));
    const low: i32 = @intCast(pair.low);
    const high: i32 = @intCast(pair.high);
    const final_induction = @addWithOverflow(final_b4, 1);
    if (final_induction[1] != 0) return false;

    if (!globalWritableDataStoreAvailableForFastPath(ctx.runtime, ctx.lexicals, global, function, plan.string_store_pc, plan.string_store_atom)) return false;
    if (!globalWritableDataStoreAvailableForFastPath(ctx.runtime, ctx.lexicals, global, function, plan.index_put_pc, plan.index_atom)) return false;
    if (!globalWritableDataStoreAvailableForFastPath(ctx.runtime, ctx.lexicals, global, function, plan.low_put_pc, plan.low_atom)) return false;
    if (!globalWritableDataStoreAvailableForFastPath(ctx.runtime, ctx.lexicals, global, function, plan.high_put_pc, plan.high_atom)) return false;
    if (!globalWritableDataStoreAvailableForFastPath(ctx.runtime, ctx.lexicals, global, function, plan.count_put_pc, plan.count_atom)) return false;
    if (!globalWritableDataStoreAvailableForFastPath(ctx.runtime, ctx.lexicals, global, function, plan.induction_put_pc, plan.induction_atom)) return false;

    const suffix_string = try ctx.runtime.percentHexString(@intCast(final_b4));
    const suffix_bytes = suffix_string.borrowLatin1() orelse return false;
    const final_string = try core.string.String.createLatin1Concat(ctx.runtime, prefix_bytes, suffix_bytes);
    var final_string_owned = true;
    errdefer if (final_string_owned) final_string.value().free(ctx.runtime);
    if (!setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, plan.string_store_pc, plan.string_store_atom, final_string.value())) {
        final_string.value().free(ctx.runtime);
        return false;
    }
    final_string_owned = false;
    if (!setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, plan.index_put_pc, plan.index_atom, core.JSValue.int32(codepoint))) return false;
    if (!setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, plan.low_put_pc, plan.low_atom, core.JSValue.int32(low))) return false;
    if (!setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, plan.high_put_pc, plan.high_atom, core.JSValue.int32(high))) return false;
    if (!setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, plan.count_put_pc, plan.count_atom, core.JSValue.int32(count_next))) return false;
    if (!setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, plan.induction_put_pc, plan.induction_atom, core.JSValue.int32(final_induction[0]))) return false;
    if (plan.high_completion_put) |completion_put| {
        try setSlotValue(ctx, &frame.locals[completion_put.idx], core.JSValue.undefinedValue());
        try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, completion_put.idx, sync_global_lexical_locals);
    }
    if (plan.branch_completion_put) |completion_put| {
        try setSlotValue(ctx, &frame.locals[completion_put.idx], core.JSValue.undefinedValue());
        try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, completion_put.idx, sync_global_lexical_locals);
    }
    if (plan.count_completion_put) |completion_put| {
        try setSlotValue(ctx, &frame.locals[completion_put.idx], core.JSValue.int32(count_next - 1));
        try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, completion_put.idx, sync_global_lexical_locals);
    }
    if (plan.induction_completion_put) |completion_put| {
        try setSlotValue(ctx, &frame.locals[completion_put.idx], core.JSValue.int32(final_b4));
        try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, completion_put.idx, sync_global_lexical_locals);
    }
    frame.pc = plan.exit_pc;
    return true;
}

fn decodeUriFourByteRangePlan(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) ?UriFourByteRangePlan {
    const code = function.code;
    const callee_get = decodeVarRefGet(code, frame.pc) orelse return null;
    const callee = varRefReadableBorrowed(frame, callee_get.idx) orelse return null;
    if (simpleStringCallableKind(callee) != .percent_hex_byte) return null;

    const induction_get = decodeGlobalDataGet(code, callee_get.next_pc) orelse return null;
    var pc = induction_get.next_pc;
    if (pc + 2 > code.len or code[pc] != op.call1 or code[pc + 1] != op.add) return null;
    const string_store_pc = pc + 2;
    const string_store = decodeGlobalPut(code, string_store_pc) orelse return null;
    pc = string_store.next_pc;

    pc = expectImmediateInt32(code, pc, 240) orelse return null;
    pc = expectImmediateInt32(code, pc, 7) orelse return null;
    pc = expectOp(code, pc, op.@"and") orelse return null;
    pc = expectImmediateInt32(code, pc, 0x40000) orelse return null;
    pc = expectOp(code, pc, op.mul) orelse return null;
    pc = expectImmediateInt32(code, pc, 160) orelse return null;
    pc = expectImmediateInt32(code, pc, 0x3f) orelse return null;
    pc = expectOp(code, pc, op.@"and") orelse return null;
    pc = expectImmediateInt32(code, pc, 0x1000) orelse return null;
    pc = expectOp(code, pc, op.mul) orelse return null;
    pc = expectOp(code, pc, op.add) orelse return null;
    const index_b3_get_pc = pc;
    const index_b3_get = decodeGlobalDataGet(code, pc) orelse return null;
    pc = index_b3_get.next_pc;
    pc = expectImmediateInt32(code, pc, 0x3f) orelse return null;
    pc = expectOp(code, pc, op.@"and") orelse return null;
    pc = expectImmediateInt32(code, pc, 0x40) orelse return null;
    pc = expectOp(code, pc, op.mul) orelse return null;
    pc = expectOp(code, pc, op.add) orelse return null;
    const index_b4_get = decodeGlobalDataGet(code, pc) orelse return null;
    if (index_b4_get.atom != induction_get.atom) return null;
    pc = index_b4_get.next_pc;
    pc = expectImmediateInt32(code, pc, 0x3f) orelse return null;
    pc = expectOp(code, pc, op.@"and") orelse return null;
    pc = expectOp(code, pc, op.add) orelse return null;
    const index_put_pc = pc;
    const index_put = decodeGlobalPut(code, pc) orelse return null;
    pc = index_put.next_pc;

    const low_index_get = decodeGlobalDataGet(code, pc) orelse return null;
    if (low_index_get.atom != index_put.atom) return null;
    pc = low_index_get.next_pc;
    pc = expectImmediateInt32(code, pc, 0x10000) orelse return null;
    pc = expectOp(code, pc, op.sub) orelse return null;
    pc = expectImmediateInt32(code, pc, 0x03ff) orelse return null;
    pc = expectOp(code, pc, op.@"and") orelse return null;
    pc = expectImmediateInt32(code, pc, 0xdc00) orelse return null;
    pc = expectOp(code, pc, op.add) orelse return null;
    const low_put_pc = pc;
    const low_put = decodeGlobalPut(code, pc) orelse return null;
    pc = low_put.next_pc;

    const high_index_get = decodeGlobalDataGet(code, pc) orelse return null;
    if (high_index_get.atom != index_put.atom) return null;
    pc = high_index_get.next_pc;
    pc = expectImmediateInt32(code, pc, 0x10000) orelse return null;
    pc = expectOp(code, pc, op.sub) orelse return null;
    pc = expectImmediateInt32(code, pc, 10) orelse return null;
    pc = expectOp(code, pc, op.sar) orelse return null;
    pc = expectImmediateInt32(code, pc, 0x03ff) orelse return null;
    pc = expectOp(code, pc, op.@"and") orelse return null;
    pc = expectImmediateInt32(code, pc, 0xd800) orelse return null;
    pc = expectOp(code, pc, op.add) orelse return null;
    const high_put_pc = pc;
    const high_put = decodeGlobalPut(code, pc) orelse return null;
    pc = high_put.next_pc;
    const high_completion_tail = decodeOptionalUndefinedLocalCompletionTail(function, frame, pc) orelse return null;
    pc = high_completion_tail.tail_pc;

    const uri_get = decodeGlobalDataGet(code, pc) orelse return null;
    const uri_callee = fastGlobalDataValueForAtomAtPcNoProfile(ctx, function, global, frame, pc, uri_get.atom, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return null;
    const uri_object = objectFromValue(uri_callee) orelse return null;
    const uri_native_ref = core.function.decodeNativeBuiltinId(uri_object.nativeFunctionIdSlot().*) orelse return null;
    if (uri_native_ref.domain != .uri or (uri_native_ref.id != 3 and uri_native_ref.id != 4)) return null;
    pc = uri_get.next_pc;
    const uri_arg_get = decodeGlobalDataGet(code, pc) orelse return null;
    if (uri_arg_get.atom != string_store.atom) return null;
    pc = uri_arg_get.next_pc;
    pc = expectOp(code, pc, op.call1) orelse return null;

    const string_get = decodeGlobalDataGet(code, pc) orelse return null;
    if (string_get.atom != atom_string) return null;
    const string_ctor = fastGlobalDataValueForAtomAtPcNoProfile(ctx, function, global, frame, pc, string_get.atom, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return null;
    pc = string_get.next_pc;
    const method = decodeFieldAtom(code, pc, op.get_field2) orelse return null;
    const native_ref = functionOwnNativeBuiltinRefForFastPath(function, pc, ctx.runtime, string_ctor, method.atom) orelse return null;
    if (native_ref.domain != .string or native_ref.id != @intFromEnum(builtins.string.StaticMethod.from_char_code)) return null;
    pc = method.next_pc;
    const high_get = decodeGlobalDataGet(code, pc) orelse return null;
    if (high_get.atom != high_put.atom) return null;
    pc = high_get.next_pc;
    const low_get = decodeGlobalDataGet(code, pc) orelse return null;
    if (low_get.atom != low_put.atom) return null;
    pc = low_get.next_pc;
    if (pc + 4 > code.len or code[pc] != op.call_method or readInt(u16, code[pc + 1 ..][0..2]) != 2) return null;
    pc += 3;
    pc = expectOp(code, pc, op.strict_eq) orelse return null;
    const eq_branch = decodeFalseBranch(code, pc) orelse return null;

    const branch_completion_tail = decodeOptionalUndefinedLocalCompletionTail(function, frame, eq_branch.true_pc) orelse return null;
    const count_get = decodeGlobalDataGet(code, branch_completion_tail.tail_pc) orelse return null;
    if (count_get.next_pc >= code.len or code[count_get.next_pc] != op.post_inc) return null;
    const count_put_pc = count_get.next_pc + 1;
    const count_put = decodeGlobalPut(code, count_put_pc) orelse return null;
    if (count_put.atom != count_get.atom) return null;
    const count_tail = decodeOptionalLocalCompletionTail(function, frame, count_put.next_pc) orelse return null;
    if (count_tail.tail_pc != eq_branch.false_pc) return null;

    const tail_get = decodeGlobalDataGet(code, eq_branch.false_pc) orelse return null;
    if (tail_get.atom != induction_get.atom) return null;
    if (tail_get.next_pc >= code.len or code[tail_get.next_pc] != op.post_inc) return null;
    const induction_put_pc = tail_get.next_pc + 1;
    const induction_put = decodeGlobalPut(code, induction_put_pc) orelse return null;
    if (induction_put.atom != induction_get.atom) return null;
    const induction_tail = decodeOptionalLocalCompletionTail(function, frame, induction_put.next_pc) orelse return null;
    const goto_pc = induction_tail.tail_pc;
    if (goto_pc >= code.len) return null;
    const condition_pc = backwardGotoTarget(code, goto_pc + 1, code[goto_pc]) orelse return null;
    const condition_get = decodeGlobalDataGet(code, condition_pc) orelse return null;
    if (condition_get.atom != induction_get.atom) return null;
    const limit = immediateInt32Operand(code, condition_get.next_pc) orelse return null;
    if (limit.next_pc >= code.len or code[limit.next_pc] != op.lte) return null;
    const exit_branch = decodeFalseBranch(code, limit.next_pc + 1) orelse return null;
    if (exit_branch.true_pc != frame.pc - 5) return null;

    return .{
        .induction_atom = induction_get.atom,
        .induction_put_pc = induction_put_pc,
        .string_store_atom = string_store.atom,
        .string_store_pc = string_store_pc,
        .index_atom = index_put.atom,
        .index_put_pc = index_put_pc,
        .low_atom = low_put.atom,
        .low_put_pc = low_put_pc,
        .high_atom = high_put.atom,
        .high_put_pc = high_put_pc,
        .high_completion_put = high_completion_tail.completion_put,
        .branch_completion_put = branch_completion_tail.completion_put,
        .count_atom = count_get.atom,
        .count_put_pc = count_put_pc,
        .count_completion_put = count_tail.completion_put,
        .induction_completion_put = induction_tail.completion_put,
        .index_b3_atom = index_b3_get.atom,
        .index_b3_get_pc = index_b3_get_pc,
        .limit = limit.value,
        .exit_pc = exit_branch.false_pc,
    };
}

fn expectOp(code: []const u8, pc: usize, expected: u8) ?usize {
    if (pc >= code.len or code[pc] != expected) return null;
    return pc + 1;
}

fn expectImmediateInt32(code: []const u8, pc: usize, expected: i32) ?usize {
    const immediate = immediateInt32Operand(code, pc) orelse return null;
    if (immediate.value != expected) return null;
    return immediate.next_pc;
}

fn percentHexByte(high: u8, low: u8) ?u8 {
    const high_value = percentHexNibble(high) orelse return null;
    const low_value = percentHexNibble(low) orelse return null;
    return (high_value << 4) | low_value;
}

fn percentHexNibble(byte: u8) ?u8 {
    return unicode_lib.asciiUpperHexDigitValueByte(byte);
}

fn tryFuseGlobalStringPercentHexAddStore(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    lhs: core.JSValue,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !?Step {
    if (try tryFuseGlobalUriFourByteDecodeCountRange(ctx, function, global, frame, lhs, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;

    const callee_get = decodeVarRefGet(function.code, frame.pc) orelse return null;
    const callee = varRefReadableBorrowed(frame, callee_get.idx) orelse return null;
    if (simpleStringCallableKind(callee) != .percent_hex_byte) return null;

    const arg_get = decodeGlobalDataGet(function.code, callee_get.next_pc) orelse return null;
    const arg_value = fastGlobalDataValueForAtomAtPc(ctx, function, global, frame, callee_get.next_pc, arg_get.atom, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return null;
    const arg_i32 = arg_value.asInt32() orelse return null;

    const call_pc = arg_get.next_pc;
    if (call_pc + 2 > function.code.len or function.code[call_pc] != op.call1 or function.code[call_pc + 1] != op.add) return null;
    const store_pc = call_pc + 2;
    const store = decodeGlobalPut(function.code, store_pc) orelse return null;
    if (!canFuseGlobalDataWrite(function, frame, store.atom, eval_local_names, eval_var_ref_names, eval_with_object)) return null;
    if (!globalWritableDataStoreAvailableForFastPath(ctx.runtime, ctx.lexicals, global, function, store_pc, store.atom)) return null;

    const lhs_string = stringFromValue(lhs) orelse return null;
    const lhs_bytes = lhs_string.borrowLatin1() orelse return null;

    const suffix_string = try ctx.runtime.percentHexString(@truncate(@as(u32, @bitCast(arg_i32))));
    const suffix_bytes = suffix_string.borrowLatin1() orelse return null;
    const updated_string = try core.string.String.createLatin1Concat(ctx.runtime, lhs_bytes, suffix_bytes);
    var updated_owned = true;
    errdefer if (updated_owned) updated_string.value().free(ctx.runtime);
    if (!setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, store_pc, store.atom, updated_string.value())) {
        updated_string.value().free(ctx.runtime);
        return null;
    }
    updated_owned = false;

    frame.pc = store.next_pc;
    _ = tryFuseGlobalInt32PrefixTermsStore(ctx, global, function, frame, frame.pc, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue);
    if (try tryFuseGlobalUriCall1AtCurrentPc(ctx, stack, function, frame, catch_target, global, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, handleCatchableRuntimeError)) |step| return step;
    return .done;
}

pub fn tryFuseAtomPercentHexGlobalStringStore(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) !bool {
    if (frame.pc + 4 > function.code.len) return false;
    const prefix_atom = readInt(u32, function.code[frame.pc..][0..4]);
    var prefix_buf: [16]u8 = undefined;
    const prefix = atomAsciiText(ctx.runtime, prefix_atom, &prefix_buf) orelse return false;
    return try tryFusePercentHexGlobalStringStoreAfterPrefix(ctx, global, function, frame, prefix, frame.pc + 4, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue);
}

fn tryFusePercentHexGlobalStringStoreAfterPrefix(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    prefix: []const u8,
    callee_pc: usize,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) !bool {
    const callee_get = decodeVarRefGet(function.code, callee_pc) orelse return false;
    const callee = varRefReadableBorrowed(frame, callee_get.idx) orelse return false;
    if (simpleStringCallableKind(callee) != .percent_hex_byte) return false;

    const arg_get = decodeGlobalDataGet(function.code, callee_get.next_pc) orelse return false;
    const arg_value = fastGlobalDataValueForAtomAtPc(ctx, function, global, frame, callee_get.next_pc, arg_get.atom, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
    const arg_i32 = arg_value.asInt32() orelse return false;

    const call_pc = arg_get.next_pc;
    if (call_pc + 2 > function.code.len or function.code[call_pc] != op.call1 or function.code[call_pc + 1] != op.add) return false;
    const store_pc = call_pc + 2;
    const store = decodeGlobalPut(function.code, store_pc) orelse return false;
    if (!canFuseGlobalDataWrite(function, frame, store.atom, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    if (!globalWritableDataStoreAvailableForFastPath(ctx.runtime, ctx.lexicals, global, function, store_pc, store.atom)) return false;

    const suffix_string = try ctx.runtime.percentHexString(@truncate(@as(u32, @bitCast(arg_i32))));
    const suffix_bytes = suffix_string.borrowLatin1() orelse return false;
    const updated_string = try core.string.String.createLatin1Concat(ctx.runtime, prefix, suffix_bytes);
    var updated_owned = true;
    errdefer if (updated_owned) updated_string.value().free(ctx.runtime);
    if (!setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, store_pc, store.atom, updated_string.value())) {
        updated_string.value().free(ctx.runtime);
        return false;
    }
    updated_owned = false;

    frame.pc = store.next_pc;
    _ = tryFuseGlobalInt32PrefixTermsStore(ctx, global, function, frame, frame.pc, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue);
    return true;
}

fn fastInt32ImmediateBinary(opcode_id: u8, lhs: i32, rhs: i32) ?core.JSValue {
    return switch (opcode_id) {
        op.add => fastInt32Add(lhs, rhs),
        op.sub => fastInt32Sub(lhs, rhs),
        op.mul => fastInt32Mul(lhs, rhs),
        op.sar => core.JSValue.int32(lhs >> @intCast(rhs & 31)),
        op.@"and" => core.JSValue.int32(lhs & rhs),
        op.@"or" => core.JSValue.int32(lhs | rhs),
        op.xor => core.JSValue.int32(lhs ^ rhs),
        else => null,
    };
}

fn tryFuseUriDecodeSingleFourByteStrictEqFromCharCode(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
    uri_mode: u32,
    argument: core.JSValue,
    after_uri_call_pc: usize,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
    comptime setSlotValue: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !?Step {
    if (uri_mode != 3 and uri_mode != 4) return null;
    const code = function.code;
    var pc = after_uri_call_pc;
    if (pc + 11 > code.len) return null;
    const string_op = code[pc];
    if (string_op != op.get_var and string_op != op.get_var_undef) return null;
    const string_atom = readInt(u32, code[pc + 1 ..][0..4]);
    if (string_atom != atom_string) return null;
    const string_ctor = fastGlobalDataValueForAtomAtPcNoProfile(ctx, function, global, frame, pc, string_atom, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return null;
    pc += 5;

    if (pc + 5 > code.len or code[pc] != op.get_field2) return null;
    const method_atom = readInt(u32, code[pc + 1 ..][0..4]);
    const native_ref = functionOwnNativeBuiltinRefForFastPath(function, pc, ctx.runtime, string_ctor, method_atom) orelse return null;
    if (native_ref.domain != .string or native_ref.id != @intFromEnum(builtins.string.StaticMethod.from_char_code)) return null;
    pc += 5;

    const high_arg = uriStrictEqIntArg(ctx, function, global, frame, pc, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return null;
    const low_arg = uriStrictEqIntArg(ctx, function, global, frame, high_arg.next_pc, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return null;
    const call_pc = low_arg.next_pc;
    if (call_pc + 4 > code.len or code[call_pc] != op.call_method) return null;
    if (readInt(u16, code[call_pc + 1 ..][0..2]) != 2) return null;
    const strict_eq_pc = call_pc + 3;
    if (code[strict_eq_pc] != op.strict_eq) return null;

    const units = builtins.uri.decodeSingleFourByteEscapeUnits(argument) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    } orelse return null;
    const expected_high: u16 = @intCast(@as(u32, @bitCast(high_arg.value)) & 0xffff);
    const expected_low: u16 = @intCast(@as(u32, @bitCast(low_arg.value)) & 0xffff);
    const matched = units.high == expected_high and units.low == expected_low;
    if (tryFuseUriStrictEqBranchCount(ctx, function, global, frame, strict_eq_pc, matched, eval_local_names, eval_var_ref_names, eval_with_object, setSlotValue)) return .done;
    try stack.pushOwned(core.JSValue.boolean(matched));
    frame.pc = strict_eq_pc + 1;
    return .done;
}

fn tryFuseUriStrictEqBranchCount(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    strict_eq_pc: usize,
    matched: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime setSlotValue: anytype,
) bool {
    const branch_pc = strict_eq_pc + 1;
    if (branch_pc >= function.code.len) return false;
    const code = function.code;
    const branch: UriStrictEqBranch = switch (code[branch_pc]) {
        op.if_false8 => blk: {
            if (branch_pc + 2 > code.len) return false;
            const operand_pc = branch_pc + 1;
            const diff: i8 = @bitCast(code[operand_pc]);
            const target_i64 = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            if (target_i64 < 0) return false;
            break :blk .{ .true_pc = operand_pc + 1, .false_pc = @as(usize, @intCast(target_i64)) };
        },
        op.if_false => blk: {
            if (branch_pc + 5 > code.len) return false;
            const operand_pc = branch_pc + 1;
            const diff = readInt(i32, code[operand_pc..][0..4]);
            const target_i64 = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            if (target_i64 < 0) return false;
            break :blk .{ .true_pc = operand_pc + 4, .false_pc = @as(usize, @intCast(target_i64)) };
        },
        else => return false,
    };
    if (!matched) {
        frame.pc = branch.false_pc;
        _ = tryFuseFollowingDroppedGlobalDataPostUpdateAndGoto16Condition(ctx, function, global, frame, eval_local_names, eval_var_ref_names, eval_with_object);
        return true;
    }

    if (tryFuseUriStrictEqVarRefPostInc(ctx, function, frame, branch, setSlotValue)) return true;
    if (tryFuseUriStrictEqGlobalDataPostInc(ctx, function, global, frame, branch, eval_local_names, eval_var_ref_names, eval_with_object)) return true;
    return false;
}

fn tryFuseUriStrictEqVarRefPostInc(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    branch: UriStrictEqBranch,
    comptime setSlotValue: anytype,
) bool {
    _ = setSlotValue;
    const code = function.code;
    const get = decodeVarRefGet(code, branch.true_pc) orelse return false;
    if (get.next_pc >= code.len or code[get.next_pc] != op.post_inc) return false;
    const put = decodeVarRefPut(code, get.next_pc + 1) orelse return false;
    if (put.idx != get.idx) return false;
    const drop_pc = put.operand_pc + put.consume;
    if (drop_pc >= code.len or code[drop_pc] != op.drop) return false;
    if (drop_pc + 1 != branch.false_pc) return false;
    if (put.idx >= frame.var_refs.len) return false;
    if (varRefCellFromValue(frame.var_refs[put.idx])) |cell| {
        if (cell.varRefIsDeletedSlot().* or cell.varRefIsFunctionNameSlot().* or cell.varRefIsConstSlot().*) return false;
        return false;
    }
    const current = (varRefReadableBorrowed(frame, get.idx) orelse return false).asInt32() orelse return false;
    const old_value = frame.var_refs[put.idx];
    frame.var_refs[put.idx] = fastInt32Add(current, 1);
    old_value.free(ctx.runtime);
    frame.pc = branch.false_pc;
    return true;
}

fn tryFuseUriStrictEqGlobalDataPostInc(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    branch: UriStrictEqBranch,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) bool {
    const code = function.code;
    const get = decodeGlobalDataGet(code, branch.true_pc) orelse return false;
    if (get.next_pc >= code.len or code[get.next_pc] != op.post_inc) return false;
    const put_pc = get.next_pc + 1;
    const put = decodeGlobalPut(code, put_pc) orelse return false;
    if (put.atom != get.atom) return false;
    if (put.next_pc >= code.len or code[put.next_pc] != op.drop) return false;
    if (put.next_pc + 1 != branch.false_pc) return false;
    if (!canUseFastGlobalVarLookup(function, get.atom, frame, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    const current = globalWritableDataStoreInt32ForFastPath(ctx.runtime, ctx.lexicals, global, function, put_pc, put.atom) orelse return false;
    if (!setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, put_pc, put.atom, fastInt32Add(current, 1))) return false;
    frame.pc = branch.false_pc;
    _ = tryFuseFollowingDroppedGlobalDataPostUpdateAndGoto16Condition(ctx, function, global, frame, eval_local_names, eval_var_ref_names, eval_with_object);
    return true;
}

fn tryFuseFollowingDroppedGlobalDataPostUpdateAndGoto16Condition(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) bool {
    const code = function.code;
    const start_pc = frame.pc;
    const get = decodeGlobalDataGet(code, start_pc) orelse return false;
    if (!canUseFastGlobalVarLookup(function, get.atom, frame, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    if (get.next_pc >= code.len) return false;
    const update_op = code[get.next_pc];
    if (update_op != op.post_inc and update_op != op.post_dec) return false;
    const put_pc = get.next_pc + 1;
    const put = decodeGlobalPut(code, put_pc) orelse return false;
    if (put.atom != get.atom) return false;
    if (put.next_pc >= code.len or code[put.next_pc] != op.drop) return false;

    const current = globalWritableDataStoreInt32ForFastPath(ctx.runtime, ctx.lexicals, global, function, put_pc, put.atom) orelse return false;
    const updated = switch (update_op) {
        op.post_inc => fastInt32Add(current, 1),
        op.post_dec => fastInt32Sub(current, 1),
        else => unreachable,
    };
    const updated_int = updated.asInt32();
    if (!setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, put_pc, put.atom, updated)) {
        updated.free(ctx.runtime);
        return false;
    }
    frame.pc = put.next_pc + 1;
    if (updated_int) |int_value| {
        _ = tryFuseFollowingGlobalInt32Goto16Condition(ctx, function, frame, get.atom, int_value);
    }
    return true;
}

fn uriStrictEqIntArg(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    pc: usize,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) ?UriStrictEqIntArg {
    if (pc >= function.code.len) return null;
    const code = function.code;
    switch (code[pc]) {
        op.get_loc_check => {
            if (pc + 3 > code.len) return null;
            const idx = readInt(u16, code[pc + 1 ..][0..2]);
            if (idx >= frame.locals.len or idx >= frame.locals_uninit.len) return null;
            if (frame.localIsUninitialized(idx)) return null;
            const value = slotValueBorrowed(frame.locals[idx]);
            return .{ .value = value.asInt32() orelse return null, .next_pc = pc + 3 };
        },
        op.get_var, op.get_var_undef => {
            if (pc + 5 > code.len) return null;
            const atom_id = readInt(u32, code[pc + 1 ..][0..4]);
            const value = fastGlobalDataValueForAtomAtPcNoProfile(ctx, function, global, frame, pc, atom_id, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return null;
            return .{ .value = value.asInt32() orelse return null, .next_pc = pc + 5 };
        },
        op.get_var_ref, op.get_var_ref_check => {
            if (pc + 3 > code.len) return null;
            const idx = readInt(u16, code[pc + 1 ..][0..2]);
            const value = varRefReadableBorrowed(frame, idx) orelse return null;
            return .{ .value = value.asInt32() orelse return null, .next_pc = pc + 3 };
        },
        op.get_var_ref0 => {
            const value = varRefReadableBorrowed(frame, 0) orelse return null;
            return .{ .value = value.asInt32() orelse return null, .next_pc = pc + 1 };
        },
        op.get_var_ref1 => {
            const value = varRefReadableBorrowed(frame, 1) orelse return null;
            return .{ .value = value.asInt32() orelse return null, .next_pc = pc + 1 };
        },
        op.get_var_ref2 => {
            const value = varRefReadableBorrowed(frame, 2) orelse return null;
            return .{ .value = value.asInt32() orelse return null, .next_pc = pc + 1 };
        },
        op.get_var_ref3 => {
            const value = varRefReadableBorrowed(frame, 3) orelse return null;
            return .{ .value = value.asInt32() orelse return null, .next_pc = pc + 1 };
        },
        else => {
            const immediate = immediateInt32Operand(code, pc) orelse return null;
            return .{ .value = immediate.value, .next_pc = immediate.next_pc };
        },
    }
}

fn uriCall1StringArgument(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    global: *core.Object,
    comptime globalLexicalValue: anytype,
) !?UriCall1Argument {
    if (frame.pc >= function.code.len) return null;
    const code = function.code;
    switch (code[frame.pc]) {
        op.push_atom_value => {
            if (frame.pc + 6 > code.len or code[frame.pc + 5] != op.call1) return null;
            const atom_id = readInt(u32, code[frame.pc + 1 ..][0..4]);
            const value = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
            return .{ .value = value, .next_pc = frame.pc + 6, .owned = true };
        },
        op.get_var_ref, op.get_var_ref_check => {
            if (frame.pc + 4 > code.len or code[frame.pc + 3] != op.call1) return null;
            const idx = readInt(u16, code[frame.pc + 1 ..][0..2]);
            return uriCall1VarRefStringArgument(frame, idx, frame.pc + 4);
        },
        op.get_var_ref0 => return uriCall1VarRefStringArgument(frame, 0, frame.pc + 2),
        op.get_var_ref1 => return uriCall1VarRefStringArgument(frame, 1, frame.pc + 2),
        op.get_var_ref2 => return uriCall1VarRefStringArgument(frame, 2, frame.pc + 2),
        op.get_var_ref3 => return uriCall1VarRefStringArgument(frame, 3, frame.pc + 2),
        op.get_var, op.get_var_undef => {
            if (frame.pc + 6 > code.len or code[frame.pc + 5] != op.call1) return null;
            const atom_id = readInt(u32, code[frame.pc + 1 ..][0..4]);
            return uriCall1GlobalStringArgument(ctx, function, frame, global, atom_id, frame.pc, frame.pc + 6, globalLexicalValue);
        },
        else => return null,
    }
}

fn uriCall1VarRefStringArgument(frame: *const frame_mod.Frame, idx: usize, next_pc: usize) ?UriCall1Argument {
    if (idx >= frame.var_refs.len) return null;
    const value = frame.var_refs[idx];
    if (varRefCellFromValue(value)) |cell| {
        if (cell.varRefIsDeletedSlot().*) return null;
        const stored = cell.varRefValueSlot().* orelse return null;
        if (!stored.isString() or stored.isUninitialized()) return null;
        return .{ .value = stored, .next_pc = next_pc, .owned = false };
    }
    if (!value.isString() or value.isUninitialized()) return null;
    return .{ .value = value, .next_pc = next_pc, .owned = false };
}

fn uriCall1GlobalStringArgument(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    global: *core.Object,
    atom_id: core.Atom,
    site_pc: usize,
    next_pc: usize,
    comptime globalLexicalValue: anytype,
) ?UriCall1Argument {
    if (atom_id == core.atom.ids.undefined_ or atom_id == core.atom.ids.arguments) return null;
    if (frameHasVarRefBinding(function, frame, atom_id)) return null;
    if (globalLexicalValue(ctx, atom_id)) |value| {
        value.free(ctx.runtime);
        return null;
    }
    const value = globalDataPropertyValueForFastPathNoProfile(ctx.runtime, global, function, site_pc, atom_id) orelse return null;
    if (!value.isString()) return null;
    return .{ .value = value, .next_pc = next_pc, .owned = false };
}

pub fn putVar(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    strict_unresolved_get_var: bool,
    eval_global_var_bindings: bool,
    is_eval_code: bool,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    eval_with_object: core.JSValue,
    comptime setNamedSlotValue: anytype,
    comptime setNamedVarRefValue: anytype,
    comptime directEvalShouldExposeImplicitArguments: anytype,
    comptime setGlobalLexicalValue: anytype,
    comptime setValueProperty: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    if (ctx.runtime.opcode_profile != null) core.profile.recordGlobalLookup();
    const value = try stack.pop();
    const runtime_strict = function.flags.is_strict or function.flags.runtime_strict;
    if (canUseFastGlobalVarWrite(ctx, function, atom_id, frame, eval_local_names, eval_var_ref_names, eval_with_object)) {
        if (shared_vm.setGlobalLexicalValueForFastPathOwned(ctx, atom_id, value) catch |err| {
            value.free(ctx.runtime);
            return err;
        }) {
            return .continue_loop;
        }
        if (globalWritableDataWriteFastOwned(ctx, global, function, frame, atom_id, value) catch |err| {
            value.free(ctx.runtime);
            return err;
        }) {
            return .continue_loop;
        }
    }
    if (try setNamedSlotValue(ctx, eval_local_names, eval_local_slots, atom_id, value)) return .continue_loop;
    if (!frame.eval_var_refs_republished) {
        if (setNamedVarRefValue(ctx, eval_var_ref_names, eval_var_refs, atom_id, value, runtime_strict or strict_unresolved_get_var, false) catch |err| {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        }) return .continue_loop;
    }
    if (try setNamedSlotValue(ctx, frame.eval_local_names, frame.eval_local_slots, atom_id, value)) return .continue_loop;
    if (setNamedVarRefValue(ctx, frame.eval_var_ref_names, frame.eval_var_refs, atom_id, value, runtime_strict or strict_unresolved_get_var, false) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    }) return .continue_loop;
    if (atom_id == core.atom.ids.arguments and directEvalShouldExposeImplicitArguments(frame)) {
        const old_value = frame.arguments_object;
        frame.arguments_object = value;
        if (old_value) |stored| stored.free(ctx.runtime);
        return .continue_loop;
    }
    const updated_global_lexical = setGlobalLexicalValue(ctx, atom_id, value) catch |err| {
        value.free(ctx.runtime);
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    if (updated_global_lexical) {
        value.free(ctx.runtime);
        return .continue_loop;
    }
    if (runtime_strict or strict_unresolved_get_var) {
        const global_value = global.value().dup();
        defer global_value.free(ctx.runtime);
        const has_global_binding = hasObjectBinding(ctx, output, global, global_value, global, atom_id, function, frame) catch |err| {
            value.free(ctx.runtime);
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
        if (!has_global_binding) {
            value.free(ctx.runtime);
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
            return error.ReferenceError;
        }
    }
    if (is_eval_code and
        eval_global_var_bindings and
        !runtime_strict and
        evalFunctionDeclaresGlobalVar(function, atom_id) and
        globalOwnAccessorWithoutSetter(ctx.runtime, global, atom_id))
    {
        value.free(ctx.runtime);
        return .continue_loop;
    }
    if (try global.setOwnWritableDataProperty(ctx.runtime, atom_id, value)) {
        value.free(ctx.runtime);
        return .continue_loop;
    }
    if (!runtime_strict and globalOwnRejectedNonStrictSet(global, atom_id)) {
        value.free(ctx.runtime);
        return .continue_loop;
    }
    defer value.free(ctx.runtime);
    const global_value = global.value().dup();
    defer global_value.free(ctx.runtime);
    _ = setValueProperty(ctx, output, global, global_value, atom_id, value, function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

fn globalOwnRejectedNonStrictSet(global: *core.Object, atom_id: core.Atom) bool {
    if (global.exotic != null) return false;
    for (global.properties) |*entry| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        if (entry.flags.accessor) {
            return switch (entry.slot) {
                .accessor => |accessor| accessor.setter.isUndefined(),
                .data, .auto_init, .deleted => false,
            };
        }
        return switch (entry.slot) {
            .data => !entry.flags.writable,
            .auto_init, .accessor, .deleted => false,
        };
    }
    return false;
}

fn globalWritableDataWriteFastOwned(ctx: *core.JSContext, global: *core.Object, function: *const bytecode.Bytecode, frame: *frame_mod.Frame, atom_id: core.Atom, value: core.JSValue) !bool {
    const rt = ctx.runtime;
    const site_pc = frame.pc - 5;
    return setGlobalWritableDataStoreForFastPathOwned(rt, ctx.lexicals, global, function, site_pc, atom_id, value);
}

fn tryFuseGlobalStringFromCharCodeInt32LocalAppend(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const code = function.code;
    const field_pc = frame.pc;
    if (field_pc + 5 > code.len or code[field_pc] != op.get_field2) return false;
    const method_atom = readInt(u32, code[field_pc + 1 ..][0..4]);
    const native_ref = functionOwnNativeBuiltinRefForFastPath(function, field_pc, ctx.runtime, receiver, method_atom) orelse return false;
    if (native_ref.domain != .string or native_ref.id != @intFromEnum(builtins.string.StaticMethod.from_char_code)) return false;

    const argument = stringFromCharCodeInt32Arg(function, frame, field_pc + 5) orelse return false;
    if (argument.next_pc + 3 > code.len or code[argument.next_pc] != op.call_method) return false;
    if (readInt(u16, code[argument.next_pc + 1 ..][0..2]) != 1) return false;

    return try tryFuseStringFromCharCodeInt32LocalAppend(ctx, function, global, frame, stack, argument.value, argument.next_pc + 3, false, false, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
}

fn numberStaticLiteralResultAt(
    rt: *core.JSRuntime,
    function: *const bytecode.Bytecode,
    native_id: u32,
    pc: usize,
) ?NumberStaticLiteralResult {
    const code = function.code;
    const number_mod = builtins.number;
    return switch (native_id) {
        @intFromEnum(number_mod.StaticMethod.parse_int) => blk: {
            if (pc + 5 > code.len or code[pc] != op.push_atom_value) return null;
            const string_atom = readInt(u32, code[pc + 1 ..][0..4]);
            var atom_buf: [10]u8 = undefined;
            const text = atomAsciiText(rt, string_atom, &atom_buf) orelse return null;
            const radix_operand = immediateInt32Operand(code, pc + 5) orelse return null;
            if (radix_operand.next_pc + 3 > code.len or code[radix_operand.next_pc] != op.call_method) return null;
            if (readInt(u16, code[radix_operand.next_pc + 1 ..][0..2]) != 2) return null;
            break :blk .{
                .number = number_mod.parseIntLatin1Bytes(text, radix_operand.value),
                .next_pc = radix_operand.next_pc + 3,
            };
        },
        @intFromEnum(number_mod.StaticMethod.parse_float) => blk: {
            if (pc + 8 > code.len or code[pc] != op.push_atom_value) return null;
            const string_atom = readInt(u32, code[pc + 1 ..][0..4]);
            var atom_buf: [10]u8 = undefined;
            const text = atomAsciiText(rt, string_atom, &atom_buf) orelse return null;
            const call_pc = pc + 5;
            if (code[call_pc] != op.call_method) return null;
            if (readInt(u16, code[call_pc + 1 ..][0..2]) != 1) return null;
            break :blk .{
                .number = number_mod.parseFloatLatin1Bytes(text),
                .next_pc = call_pc + 3,
            };
        },
        else => null,
    };
}

fn canUseFastGlobalVarWrite(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    atom_id: core.Atom,
    frame: *const frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) bool {
    if (!canFuseGlobalDataWrite(function, frame, atom_id, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    if (!frame.current_function.isUndefined() and functionFrameBindingShadowsGlobal(ctx.runtime, function, frame, atom_id)) return false;
    return true;
}

fn canUseFastGlobalUndefinedLookup(
    function: *const bytecode.Bytecode,
    frame: *const frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) bool {
    if (!eval_with_object.isUndefined()) return false;
    if (!frame.current_function.isUndefined()) return false;
    if (frameHasVarRefBinding(function, frame, core.atom.ids.undefined_)) return false;
    if (eval_local_names.len != 0 or eval_var_ref_names.len != 0) return false;
    if (frame.eval_local_names.len != 0 or frame.eval_var_ref_names.len != 0) return false;
    return true;
}

fn evalFunctionDeclaresGlobalVar(function: *const bytecode.Bytecode, atom_id: core.Atom) bool {
    var pc: usize = 0;
    while (pc + 6 <= function.code.len) : (pc += 1) {
        const opc = function.code[pc];
        if (opc != op.check_define_var and opc != op.define_var) continue;
        const declared_atom = readInt(u32, function.code[pc + 1 ..][0..4]);
        if (declared_atom != atom_id) continue;
        const flags = function.code[pc + 5];
        const is_lexical = (flags & (1 << 7)) != 0;
        if (!is_lexical) return true;
    }
    return false;
}

fn globalOwnAccessorWithoutSetter(rt: *core.JSRuntime, global: *core.Object, atom_id: core.Atom) bool {
    const desc = global.getOwnProperty(atom_id) orelse return false;
    defer desc.destroy(rt);
    return desc.kind == .accessor and desc.setter.isUndefined();
}

fn fastLengthValue(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    if (value.isString()) {
        const header = value.refHeader() orelse return error.TypeError;
        const string_value: *core.string.String = @fieldParentPtr("header", header);
        return core.JSValue.int32(@intCast(string_value.len()));
    }
    const object = objectFromValue(value) orelse return error.TypeError;
    if (object.proxyTarget() != null) return error.TypeError;
    if (object.flags.is_array) {
        if (object.length <= @as(u32, @intCast(std.math.maxInt(i32)))) {
            return core.JSValue.int32(@intCast(object.length));
        }
        return core.JSValue.float64(@floatFromInt(object.length));
    }
    if (builtins.buffer.isTypedArrayObject(object)) {
        return core.JSValue.int32(@intCast(try builtins.buffer.typedArrayLength(rt, object)));
    }
    return error.TypeError;
}

pub fn globalDefinition(
    ctx: *core.JSContext,
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
    eval_global_var_bindings: bool,
    is_eval_code: bool,
    comptime globalLexicalHas: anytype,
    comptime defineGlobalLexicalValue: anytype,
    comptime setFrameLocalValue: anytype,
    comptime setFrameVarRefValue: anytype,
    comptime setNamedSlotValue: anytype,
    comptime setNamedVarRefValue: anytype,
    comptime defineGlobalFunctionBindingValue: anytype,
    comptime setGlobalLexicalValue: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    switch (opc) {
        op.check_define_var => {
            const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
            const flags = function.code[frame.pc + 4];
            frame.pc += 5;
            const is_lexical = (flags & (1 << 7)) != 0;
            const is_function_var = (flags & (1 << 6)) != 0;
            if (function.flags.runtime_strict and !is_eval_code and is_function_var) return .done;
            const has_global_lexical = globalLexicalHas(ctx, atom_id);
            var has_own_global_property = false;
            if (global.getOwnProperty(atom_id)) |desc| {
                has_own_global_property = true;
                defer desc.destroy(ctx.runtime);
                if (is_lexical) {
                    if (desc.configurable != true) return error.SyntaxError;
                } else if (is_function_var and desc.configurable != true) {
                    if (desc.kind == .accessor or desc.writable != true or desc.enumerable != true) return error.TypeError;
                }
            } else if (!is_lexical and !global.isExtensible()) {
                return error.TypeError;
            }
            if (has_global_lexical) return error.SyntaxError;
            if (function.global_var_names.len == 1 and frame.pc + 6 <= function.code.len and function.code[frame.pc] == op.define_var) {
                const define_atom = readInt(u32, function.code[frame.pc + 1 ..][0..4]);
                const define_flags = function.code[frame.pc + 5];
                if (define_atom == atom_id and define_flags == flags) {
                    const is_const = (flags & (1 << 4)) != 0;
                    if (is_lexical) {
                        try defineGlobalLexicalValue(ctx, global, atom_id, core.JSValue.uninitialized(), is_const);
                    } else if (!has_own_global_property) {
                        const configurable = (flags & (1 << 5)) != 0;
                        const define_desc = core.Descriptor.data(core.JSValue.undefinedValue(), true, true, configurable);
                        if (global.exotic == null and !global.flags.is_array and global.isExtensible()) {
                            try global.defineOwnPropertyAssumingNew(ctx.runtime, atom_id, define_desc);
                        } else if (!global.hasOwnProperty(atom_id)) {
                            global.defineOwnProperty(ctx.runtime, atom_id, define_desc) catch |err| switch (err) {
                                error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
                                else => return err,
                            };
                        }
                    }
                    frame.pc += 6;
                    if (is_lexical and frame.pc + 3 <= function.code.len and function.code[frame.pc] == op.set_loc_uninitialized) {
                        const local_idx = readInt(u16, function.code[frame.pc + 1 ..][0..2]);
                        if (local_idx >= frame.locals.len or local_idx >= frame.locals_uninit.len) return error.InvalidBytecode;
                        frame.setLocalUninitialized(local_idx);
                        frame.pc += 3;
                    }
                }
            }
        },
        op.define_var => {
            const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
            const flags = function.code[frame.pc + 4];
            frame.pc += 5;
            const is_lexical = (flags & (1 << 7)) != 0;
            const is_const = (flags & (1 << 4)) != 0;
            const is_function_var = (flags & (1 << 6)) != 0;
            if (function.flags.runtime_strict and !is_eval_code and is_function_var) return .done;
            if (is_lexical) {
                try defineGlobalLexicalValue(ctx, global, atom_id, core.JSValue.uninitialized(), is_const);
            } else if (!global.hasOwnProperty(atom_id)) {
                const configurable = (flags & (1 << 5)) != 0;
                const desc = core.Descriptor.data(core.JSValue.undefinedValue(), true, true, configurable);
                const define_result = if (global.exotic == null and !global.flags.is_array and global.isExtensible())
                    global.defineOwnPropertyAssumingNew(ctx.runtime, atom_id, desc)
                else
                    global.defineOwnProperty(ctx.runtime, atom_id, desc);
                define_result catch |err| switch (err) {
                    error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
                    else => return err,
                };
            }
        },
        op.define_func => {
            const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
            const flags = function.code[frame.pc + 4];
            frame.pc += 5;
            const func_val = try stack.pop();
            defer func_val.free(ctx.runtime);
            const configurable = (flags & (1 << 5)) != 0;
            const global_function_binding = (flags & (1 << 4)) != 0;
            var local_value = func_val.dup();
            const updated_frame_local = try setFrameLocalValue(ctx, function, frame, atom_id, local_value);
            if (!updated_frame_local) local_value.free(ctx.runtime);
            var frame_ref_value = func_val.dup();
            if (!try setFrameVarRefValue(ctx, function, frame, atom_id, frame_ref_value)) frame_ref_value.free(ctx.runtime);
            var eval_local_value = func_val.dup();
            const updated_eval_local = try setNamedSlotValue(ctx, eval_local_names, eval_local_slots, atom_id, eval_local_value);
            if (!updated_eval_local) eval_local_value.free(ctx.runtime);
            var eval_ref_value = func_val.dup();
            const updated_eval_ref = try setNamedVarRefValue(ctx, eval_var_ref_names, eval_var_refs, atom_id, eval_ref_value, function.flags.is_strict, true);
            if (!updated_eval_ref) eval_ref_value.free(ctx.runtime);
            if (is_eval_code and !eval_global_var_bindings) return .continue_loop;
            if (global_function_binding) {
                try defineGlobalFunctionBindingValue(ctx.runtime, global, atom_id, func_val, configurable);
            } else if (global.hasOwnProperty(atom_id)) {
                global.setProperty(ctx.runtime, atom_id, func_val) catch |err| switch (err) {
                    error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
                    else => return err,
                };
            } else {
                global.defineOwnProperty(ctx.runtime, atom_id, core.Descriptor.data(func_val, true, true, configurable)) catch |err| switch (err) {
                    error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
                    else => return err,
                };
            }
        },
        op.put_var_init => {
            const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
            frame.pc += 4;
            const value = try stack.pop();
            var value_owned = true;
            defer if (value_owned) value.free(ctx.runtime);
            if (!function.flags.is_indirect_eval) {
                const fast_global_lexical = shared_vm.setGlobalLexicalValueForFastPathOwned(ctx, atom_id, value) catch |err| {
                    if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
                if (fast_global_lexical) {
                    value_owned = false;
                    return .continue_loop;
                }
                const updated_global_lexical = setGlobalLexicalValue(ctx, atom_id, value) catch |err| {
                    if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
                if (updated_global_lexical) return .continue_loop;
            }
            try property_ops.setProperty(ctx.runtime, global, atom_id, value);
        },
        else => unreachable,
    }
    return .done;
}
