const std = @import("std");
const bytecode = @import("../bytecode/root.zig");
const builtins = @import("../builtins/root.zig");
const core = @import("../core/root.zig");
const dtoa = @import("../libs/dtoa.zig");
const frame_mod = @import("frame.zig");
const arith_vm = @import("vm_arith.zig");
const property_ops = @import("property_ops.zig");
const shared_vm = @import("shared.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const op = bytecode.opcode.op;
const atom_date = core.atom.predefinedId("Date", .string).?;
const atom_array_buffer = core.atom.predefinedId("ArrayBuffer", .string).?;
const atom_math = core.atom.predefinedId("Math", .string).?;
const atom_number = core.atom.predefinedId("Number", .string).?;
const atom_print = core.atom.predefinedId("print", .string).?;
const atom_string = core.atom.predefinedId("String", .string).?;

pub const Step = enum { done, continue_loop };

pub fn loc(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    opc: u8,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
    comptime execGetLoc: anytype,
    comptime execPutLoc: anytype,
    comptime execSetLoc: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !void {
    switch (opc) {
        op.get_loc => {
            const idx = readInt(u16, function.code[frame.pc..][0..2]);
            if (try tryFuseDroppedLocalPostUpdateGoto8FromGet(ctx, function, global, frame, idx, frame.pc + 2, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (tryFuseLocalInt32LessThanArgFalseBranchFromGet(function, frame, idx, frame.pc + 2, false)) return;
            if (try tryFuseLocalStringFromCharCodeInt32AppendFromGet(ctx, function, global, frame, idx, frame.pc + 2, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseLocalStringLengthGtConstSliceConstBranchFromGet(ctx, function, global, frame, idx, frame.pc + 2, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseLocalStringSliceConstLocalStoreFromGet(ctx, function, global, frame, idx, frame.pc + 2, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            try execGetLoc(ctx, frame, stack, idx, 2, opc);
        },
        op.put_loc => try execPutLoc(ctx, function, global, frame, stack, readInt(u16, function.code[frame.pc..][0..2]), 2, opc, sync_global_lexical_locals),
        op.set_loc => try execSetLoc(ctx, function, global, frame, stack, readInt(u16, function.code[frame.pc..][0..2]), 2, opc, sync_global_lexical_locals),

        op.get_loc8 => {
            const idx = function.code[frame.pc];
            if (try tryFuseDroppedLocalPostUpdateGoto8FromGet(ctx, function, global, frame, idx, frame.pc + 1, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (tryFuseLocalInt32LessThanArgFalseBranchFromGet(function, frame, idx, frame.pc + 1, false)) return;
            if (try tryFuseLocalStringFromCharCodeInt32AppendFromGet(ctx, function, global, frame, idx, frame.pc + 1, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseLocalStringLengthGtConstSliceConstBranchFromGet(ctx, function, global, frame, idx, frame.pc + 1, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseLocalStringSliceConstLocalStoreFromGet(ctx, function, global, frame, idx, frame.pc + 1, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            try execGetLoc(ctx, frame, stack, idx, 1, opc);
        },
        op.put_loc8 => try execPutLoc(ctx, function, global, frame, stack, function.code[frame.pc], 1, opc, sync_global_lexical_locals),
        op.set_loc8 => try execSetLoc(ctx, function, global, frame, stack, function.code[frame.pc], 1, opc, sync_global_lexical_locals),

        op.get_loc0 => {
            if (try tryFuseDroppedLocalPostUpdateGoto8FromGet(ctx, function, global, frame, 0, frame.pc, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseShortLocalDenseArrayLengthIndexedInt32SumRange(ctx, function, global, frame, 0, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseLocalAccumulatorSimpleNumericCallAddStore(ctx, function, global, frame, 0, false, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (tryFuseLocalInt32LessThanArgFalseBranchFromGet(function, frame, 0, frame.pc, false)) return;
            if (try tryFuseLocalStringFromCharCodeInt32AppendFromGet(ctx, function, global, frame, 0, frame.pc, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseLocalStringLengthGtConstSliceConstBranchFromGet(ctx, function, global, frame, 0, frame.pc, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseLocalStringSliceConstLocalStoreFromGet(ctx, function, global, frame, 0, frame.pc, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseLocalFieldGet(ctx, function, frame, stack, 0, frame.pc, false)) return;
            try execGetLoc(ctx, frame, stack, 0, 0, opc);
        },
        op.get_loc1 => {
            if (try tryFuseDroppedLocalPostUpdateGoto8FromGet(ctx, function, global, frame, 1, frame.pc, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseShortLocal0Local1Int32ArithmeticStoreRange(ctx, function, global, frame, 1, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseShortLocal0Local1DenseArrayMulAndMaskAppendRange(ctx, function, global, frame, 1, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseShortLocalDenseArrayLengthIndexedInt32SumRange(ctx, function, global, frame, 1, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseLocalAccumulatorSimpleNumericCallAddStore(ctx, function, global, frame, 1, false, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (tryFuseLocalInt32LessThanArgFalseBranchFromGet(function, frame, 1, frame.pc, false)) return;
            if (try tryFuseLocalStringFromCharCodeInt32AppendFromGet(ctx, function, global, frame, 1, frame.pc, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseLocalStringLengthGtConstSliceConstBranchFromGet(ctx, function, global, frame, 1, frame.pc, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseLocalStringSliceConstLocalStoreFromGet(ctx, function, global, frame, 1, frame.pc, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseLocalFieldGet(ctx, function, frame, stack, 1, frame.pc, false)) return;
            try execGetLoc(ctx, frame, stack, 1, 0, opc);
        },
        op.get_loc2 => {
            if (try tryFuseDroppedLocalPostUpdateGoto8FromGet(ctx, function, global, frame, 2, frame.pc, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseShortLocalObjectFieldUpdateAccumulateRange(ctx, function, global, frame, 2, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseShortLocalDenseArrayLengthIndexedInt32SumRange(ctx, function, global, frame, 2, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseLocalAccumulatorSimpleNumericCallAddStore(ctx, function, global, frame, 2, false, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (tryFuseLocalInt32LessThanArgFalseBranchFromGet(function, frame, 2, frame.pc, false)) return;
            if (try tryFuseLocalStringFromCharCodeInt32AppendFromGet(ctx, function, global, frame, 2, frame.pc, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseLocalStringLengthGtConstSliceConstBranchFromGet(ctx, function, global, frame, 2, frame.pc, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseLocalStringSliceConstLocalStoreFromGet(ctx, function, global, frame, 2, frame.pc, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseLocalFieldGet(ctx, function, frame, stack, 2, frame.pc, false)) return;
            try execGetLoc(ctx, frame, stack, 2, 0, opc);
        },
        op.get_loc3 => {
            if (try tryFuseDroppedLocalPostUpdateGoto8FromGet(ctx, function, global, frame, 3, frame.pc, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseShortLocalDenseArrayLengthIndexedInt32SumRange(ctx, function, global, frame, 3, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseLocalAccumulatorSimpleNumericCallAddStore(ctx, function, global, frame, 3, false, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (tryFuseLocalInt32LessThanArgFalseBranchFromGet(function, frame, 3, frame.pc, false)) return;
            if (try tryFuseLocalStringFromCharCodeInt32AppendFromGet(ctx, function, global, frame, 3, frame.pc, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseLocalStringLengthGtConstSliceConstBranchFromGet(ctx, function, global, frame, 3, frame.pc, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseLocalStringSliceConstLocalStoreFromGet(ctx, function, global, frame, 3, frame.pc, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
            if (try tryFuseLocalFieldGet(ctx, function, frame, stack, 3, frame.pc, false)) return;
            try execGetLoc(ctx, frame, stack, 3, 0, opc);
        },
        op.put_loc0 => try execPutLoc(ctx, function, global, frame, stack, 0, 0, opc, sync_global_lexical_locals),
        op.put_loc1 => try execPutLoc(ctx, function, global, frame, stack, 1, 0, opc, sync_global_lexical_locals),
        op.put_loc2 => try execPutLoc(ctx, function, global, frame, stack, 2, 0, opc, sync_global_lexical_locals),
        op.put_loc3 => try execPutLoc(ctx, function, global, frame, stack, 3, 0, opc, sync_global_lexical_locals),
        op.set_loc0 => try execSetLoc(ctx, function, global, frame, stack, 0, 0, opc, sync_global_lexical_locals),
        op.set_loc1 => try execSetLoc(ctx, function, global, frame, stack, 1, 0, opc, sync_global_lexical_locals),
        op.set_loc2 => try execSetLoc(ctx, function, global, frame, stack, 2, 0, opc, sync_global_lexical_locals),
        op.set_loc3 => try execSetLoc(ctx, function, global, frame, stack, 3, 0, opc, sync_global_lexical_locals),
        op.get_loc0_loc1 => {
            if (try tryFuseLocal0Local1DenseArrayIndexedAppend(ctx, function, frame)) return;
            if (tryFuseLocal0Local1Int32ArithmeticStore(function, frame)) return;
            try execGetLoc(ctx, frame, stack, 0, 0, opc);
            try execGetLoc(ctx, frame, stack, 1, 0, opc);
        },
        else => unreachable,
    }
}

pub fn arg(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    opc: u8,
    comptime execGetArg: anytype,
    comptime execPutArg: anytype,
    comptime execSetArg: anytype,
) !void {
    switch (opc) {
        op.get_arg => try execGetArg(ctx, frame, stack, readInt(u16, function.code[frame.pc..][0..2]), 2, opc),
        op.put_arg => try execPutArg(ctx, frame, stack, readInt(u16, function.code[frame.pc..][0..2]), 2, opc),
        op.set_arg => try execSetArg(ctx, frame, stack, readInt(u16, function.code[frame.pc..][0..2]), 2, opc),
        op.get_arg0 => try execGetArg(ctx, frame, stack, 0, 0, opc),
        op.get_arg1 => try execGetArg(ctx, frame, stack, 1, 0, opc),
        op.get_arg2 => try execGetArg(ctx, frame, stack, 2, 0, opc),
        op.get_arg3 => try execGetArg(ctx, frame, stack, 3, 0, opc),
        op.put_arg0 => try execPutArg(ctx, frame, stack, 0, 0, opc),
        op.put_arg1 => try execPutArg(ctx, frame, stack, 1, 0, opc),
        op.put_arg2 => try execPutArg(ctx, frame, stack, 2, 0, opc),
        op.put_arg3 => try execPutArg(ctx, frame, stack, 3, 0, opc),
        op.set_arg0 => try execSetArg(ctx, frame, stack, 0, 0, opc),
        op.set_arg1 => try execSetArg(ctx, frame, stack, 1, 0, opc),
        op.set_arg2 => try execSetArg(ctx, frame, stack, 2, 0, opc),
        op.set_arg3 => try execSetArg(ctx, frame, stack, 3, 0, opc),
        else => unreachable,
    }
}

fn tryFuseLocalFieldGet(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    local_idx: u16,
    field_pc: usize,
    checked: bool,
) !bool {
    const code = function.code;
    if (field_pc + 5 > code.len or code[field_pc] != op.get_field) return false;
    const receiver = localReadableBorrowed(frame, local_idx, checked) orelse return false;
    const atom_id = readInt(u32, code[field_pc + 1 ..][0..4]);

    if (cachedOwnDataPropertyValue(function, field_pc, ctx.runtime, receiver, atom_id)) |value| {
        try stack.push(value);
        frame.pc = field_pc + 5;
        return true;
    }
    if (cachedProtoDataPropertyValue(function, field_pc, ctx.runtime, receiver, atom_id)) |value| {
        try stack.push(value);
        frame.pc = field_pc + 5;
        return true;
    }
    switch (fastOwnOrdinaryDataPropertyLookup(ctx.runtime, receiver, atom_id)) {
        .value => |lookup| {
            installOwnDataIc(function, field_pc, ctx.runtime, receiver, atom_id, lookup.index);
            try stack.push(lookup.value);
            frame.pc = field_pc + 5;
            return true;
        },
        .missing, .slow => {},
    }
    switch (fastImmediatePrototypeDataPropertyLookup(ctx.runtime, receiver, atom_id)) {
        .value => |lookup| {
            installProtoDataIc(function, field_pc, ctx.runtime, receiver, atom_id, lookup.holder, lookup.index);
            try stack.push(lookup.value);
            frame.pc = field_pc + 5;
            return true;
        },
        .missing, .slow => {},
    }
    return false;
}

pub fn varRef(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    opc: u8,
    catch_target: *?usize,
    eval_global_var_bindings: bool,
    is_eval_code: bool,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime execGetVarRefMaybeTdz: anytype,
    comptime execPutVarRef: anytype,
    comptime execSetVarRef: anytype,
    comptime globalLexicalValue: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !Step {
    switch (opc) {
        op.get_var_ref, op.get_var_ref_check => {
            if (frame.pc + 2 > function.code.len) return error.TypeError;
            const idx = readInt(u16, function.code[frame.pc..][0..2]);
            const next_pc = frame.pc + 2;
            if (!canStartLongVarRefGetFusion(opc, function.code, next_pc) and try tryFastDirectVarRefGet(frame, stack, idx, 2)) return .done;
            if (opc == op.get_var_ref_check and canStartVarRefOrLocalGet(function.code, next_pc) and try tryFuseDroppedVarRefNumericAdd(ctx, function, global, frame, idx, 2, setSlotValue)) return .done;
            if (canStartBorrowedSimpleCallable(function.code, next_pc) and try tryFuseVarRefAccumulatorSimpleNumericCallAddStore(ctx, function, global, frame, idx, 2, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
            if (canStartGlobalCall1(function.code, next_pc) and try tryFuseVarRefSimpleStringCall1GlobalIntArgument(ctx, function, global, frame, stack, idx, 2, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return .done;
            if (canStartBorrowedSimpleCallArg(function.code, next_pc) and try tryFuseVarRefSimpleNumericCall(ctx, function, global, frame, stack, idx, 2, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
            if (try execGetVarRefMaybeTdz(ctx, frame, stack, idx, 2, catch_target, global)) return .continue_loop;
        },
        op.put_var_ref, op.put_var_ref_check, op.put_var_ref_check_init => {
            if (frame.pc + 2 > function.code.len) return error.TypeError;
            try execPutVarRef(ctx, function, global, frame, stack, readInt(u16, function.code[frame.pc..][0..2]), 2, opc, eval_global_var_bindings, is_eval_code);
        },
        op.set_var_ref => {
            if (frame.pc + 2 > function.code.len) return error.TypeError;
            try execSetVarRef(ctx, frame, stack, readInt(u16, function.code[frame.pc..][0..2]), 2, opc);
        },

        op.get_var_ref0 => {
            if (!canStartShortVarRefGetFusion(function.code, frame.pc) and try tryFastDirectVarRefGet(frame, stack, 0, 0)) return .done;
            if (canStartBorrowedSimpleCallable(function.code, frame.pc) and try tryFuseVarRefAccumulatorSimpleNumericCallAddStore(ctx, function, global, frame, 0, 0, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
            if (canStartGlobalCall1(function.code, frame.pc) and try tryFuseVarRefSimpleStringCall1GlobalIntArgument(ctx, function, global, frame, stack, 0, 0, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return .done;
            if (canStartBorrowedSimpleCallArg(function.code, frame.pc) and try tryFuseVarRefSimpleNumericCall(ctx, function, global, frame, stack, 0, 0, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
            if (try execGetVarRefMaybeTdz(ctx, frame, stack, 0, 0, catch_target, global)) return .continue_loop;
        },
        op.get_var_ref1 => {
            if (!canStartShortVarRefGetFusion(function.code, frame.pc) and try tryFastDirectVarRefGet(frame, stack, 1, 0)) return .done;
            if (canStartBorrowedSimpleCallable(function.code, frame.pc) and try tryFuseVarRefAccumulatorSimpleNumericCallAddStore(ctx, function, global, frame, 1, 0, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
            if (canStartGlobalCall1(function.code, frame.pc) and try tryFuseVarRefSimpleStringCall1GlobalIntArgument(ctx, function, global, frame, stack, 1, 0, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return .done;
            if (canStartBorrowedSimpleCallArg(function.code, frame.pc) and try tryFuseVarRefSimpleNumericCall(ctx, function, global, frame, stack, 1, 0, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
            if (try execGetVarRefMaybeTdz(ctx, frame, stack, 1, 0, catch_target, global)) return .continue_loop;
        },
        op.get_var_ref2 => {
            if (!canStartShortVarRefGetFusion(function.code, frame.pc) and try tryFastDirectVarRefGet(frame, stack, 2, 0)) return .done;
            if (canStartBorrowedSimpleCallable(function.code, frame.pc) and try tryFuseVarRefAccumulatorSimpleNumericCallAddStore(ctx, function, global, frame, 2, 0, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
            if (canStartGlobalCall1(function.code, frame.pc) and try tryFuseVarRefSimpleStringCall1GlobalIntArgument(ctx, function, global, frame, stack, 2, 0, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return .done;
            if (canStartBorrowedSimpleCallArg(function.code, frame.pc) and try tryFuseVarRefSimpleNumericCall(ctx, function, global, frame, stack, 2, 0, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
            if (try execGetVarRefMaybeTdz(ctx, frame, stack, 2, 0, catch_target, global)) return .continue_loop;
        },
        op.get_var_ref3 => {
            if (!canStartShortVarRefGetFusion(function.code, frame.pc) and try tryFastDirectVarRefGet(frame, stack, 3, 0)) return .done;
            if (canStartBorrowedSimpleCallable(function.code, frame.pc) and try tryFuseVarRefAccumulatorSimpleNumericCallAddStore(ctx, function, global, frame, 3, 0, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
            if (canStartGlobalCall1(function.code, frame.pc) and try tryFuseVarRefSimpleStringCall1GlobalIntArgument(ctx, function, global, frame, stack, 3, 0, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return .done;
            if (canStartBorrowedSimpleCallArg(function.code, frame.pc) and try tryFuseVarRefSimpleNumericCall(ctx, function, global, frame, stack, 3, 0, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
            if (try execGetVarRefMaybeTdz(ctx, frame, stack, 3, 0, catch_target, global)) return .continue_loop;
        },
        op.put_var_ref0 => try execPutVarRef(ctx, function, global, frame, stack, 0, 0, opc, eval_global_var_bindings, is_eval_code),
        op.put_var_ref1 => try execPutVarRef(ctx, function, global, frame, stack, 1, 0, opc, eval_global_var_bindings, is_eval_code),
        op.put_var_ref2 => try execPutVarRef(ctx, function, global, frame, stack, 2, 0, opc, eval_global_var_bindings, is_eval_code),
        op.put_var_ref3 => try execPutVarRef(ctx, function, global, frame, stack, 3, 0, opc, eval_global_var_bindings, is_eval_code),
        op.set_var_ref0 => try execSetVarRef(ctx, frame, stack, 0, 0, opc),
        op.set_var_ref1 => try execSetVarRef(ctx, frame, stack, 1, 0, opc),
        op.set_var_ref2 => try execSetVarRef(ctx, frame, stack, 2, 0, opc),
        op.set_var_ref3 => try execSetVarRef(ctx, frame, stack, 3, 0, opc),
        else => unreachable,
    }
    return .done;
}

fn canStartLongVarRefGetFusion(opc: u8, code: []const u8, pc: usize) bool {
    return (opc == op.get_var_ref_check and canStartVarRefOrLocalGet(code, pc)) or
        canStartShortVarRefGetFusion(code, pc);
}

fn canStartShortVarRefGetFusion(code: []const u8, pc: usize) bool {
    return canStartBorrowedSimpleCallable(code, pc) or
        canStartGlobalCall1(code, pc) or
        canStartBorrowedSimpleCallArg(code, pc);
}

fn tryFastDirectVarRefGet(frame: *frame_mod.Frame, stack: *stack_mod.Stack, idx: u16, consume: u8) !bool {
    const value = varRefReadableBorrowed(frame, idx) orelse return false;
    frame.pc += consume;
    try stack.push(value);
    return true;
}

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

const BindingGet = struct {
    idx: u16,
    next_pc: usize,
    is_var_ref: bool,
    checked: bool = false,
};

const BindingPut = struct {
    idx: u16,
    opc: u8 = 0,
    operand_pc: usize,
    consume: u8,
    is_var_ref: bool,
    checked: bool = false,
};

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

const GlobalBindingGet = struct {
    atom: core.Atom,
    next_pc: usize,
};

const GlobalBindingPut = struct {
    atom: core.Atom,
    next_pc: usize,
};

const RegExpMatchGet = union(enum) {
    binding: BindingGet,
    global: GlobalBindingGet,
};

const RegExpMatchPut = union(enum) {
    binding: BindingPut,
    global: GlobalBindingPut,
};

const RegExpLoopGet = RegExpMatchGet;
const RegExpLoopPut = RegExpMatchPut;

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

const LoopLimitGet = union(enum) {
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

const LocalPut = struct {
    idx: u16,
    operand_pc: usize,
    consume: u8,
    checked: bool,
};

const FieldAtom = struct {
    atom: core.Atom,
    next_pc: usize,
};

const DecodedFalseBranch = struct {
    true_pc: usize,
    false_pc: usize,
};

const SimpleNumericArg0ConstCall = struct {
    binop: u8,
    rhs: i32,
};

const SimpleNumericRangeCall = struct {
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

const SimpleNumericRangeArg = union(enum) {
    induction,
    int32: i32,
};

const GlobalSimpleNumericRangeArg = union(enum) {
    global: core.Atom,
    int32: i32,
};

const SimpleNumericLinearTerm = struct {
    coefficient: i128,
    offset: i128,
};

const Latin1PrefixIntLocalKey = struct {
    prefix: []const u8,
    next_pc: usize,
};

const InductionImmediateInt32Args = struct {
    immediate: i32,
    next_pc: usize,
};

const InvariantInt32Load = struct {
    value: i32,
    next_pc: usize,
};

const IntRangeDeltaBounds = struct {
    total: i128,
    min: i128,
    max: i128,
};

const DenseArrayModFieldIncrements = struct {
    values: [8]i32,
    len: usize,
};

const GlobalPropertyRangeDelta = union(enum) {
    constant: i32,
    periodic: DenseArrayModFieldIncrements,
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

fn decodeFalseBranch(code: []const u8, branch_pc: usize) ?DecodedFalseBranch {
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

fn tryFuseVarRefSimpleNumericCall(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    func_idx: u16,
    consume: u8,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const arg0_pc = frame.pc + consume;
    if (arg0_pc >= function.code.len) return false;

    const func = varRefReadableBorrowed(frame, func_idx) orelse return false;
    const arg0 = borrowedSimpleCallArgWithContext(ctx, function, global, frame, arg0_pc, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
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

    const result = try simpleNumericFunctionResult(ctx.runtime, func, args_buf[0..argc]) orelse return false;
    var result_owned = true;
    errdefer if (result_owned) result.free(ctx.runtime);
    if (try tryFuseVarRefCallResultAddStore(ctx, function, global, frame, stack, call_pc, result, &result_owned, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
    if (try tryFuseCallResultAddGlobalStore(ctx, function, global, frame, stack, call_pc, result, &result_owned, eval_local_names, eval_var_ref_names, eval_with_object)) return true;
    try stack.pushOwned(result);
    result_owned = false;
    frame.pc = call_pc + 1;
    return true;
}

const BorrowedCallable = struct {
    value: core.JSValue,
    next_pc: usize,
};

fn tryFuseVarRefAccumulatorSimpleNumericCallAddStore(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    accumulator_idx: u16,
    consume: u8,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    var callee_pc = frame.pc + consume;
    if (callee_pc < function.code.len and function.code[callee_pc] == op.dup) callee_pc += 1;
    const callee = borrowedSimpleCallable(ctx, function, global, frame, callee_pc, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
    const arg0 = borrowedSimpleCallArgWithContext(ctx, function, global, frame, callee.next_pc, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
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

    const add_pc = call_pc + 1;
    if (add_pc >= function.code.len or function.code[add_pc] != op.add) return false;
    var store_pc = add_pc + 1;
    var drop_pc: ?usize = null;
    if (store_pc < function.code.len and function.code[store_pc] == op.dup) {
        store_pc += 1;
        const decoded_store = decodeVarRefPut(function.code, store_pc) orelse return false;
        const candidate_drop_pc = decoded_store.operand_pc + decoded_store.consume;
        if (candidate_drop_pc >= function.code.len or function.code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const store = decodeVarRefPut(function.code, store_pc) orelse return false;
    if (store.idx != accumulator_idx) return false;
    if (!varRefStoreWritableForFastPath(ctx, function, global, frame, store)) return false;

    const lhs = varRefReadableBorrowed(frame, accumulator_idx) orelse return false;
    if (!lhs.isNumber()) return false;
    const result = try simpleNumericFunctionResult(ctx.runtime, callee.value, args_buf[0..argc]) orelse return false;
    defer result.free(ctx.runtime);
    if (!result.isNumber()) return false;
    const updated = try simpleNumericBinary(ctx.runtime, op.add, lhs, result);
    errdefer updated.free(ctx.runtime);

    try setSlotValue(ctx, &frame.var_refs[store.idx], updated);
    frame.pc = if (drop_pc) |drop| drop + 1 else store.operand_pc + store.consume;
    _ = try tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    return true;
}

fn borrowedSimpleCallable(
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

fn borrowedSimpleCallableNoGlobal(
    frame: *const frame_mod.Frame,
    function: *const bytecode.Bytecode,
    pc: usize,
) ?BorrowedCallable {
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
    return null;
}

fn decodeLocalGet(code: []const u8, pc: usize) ?LocalGet {
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

fn localReadableBorrowed(frame: *const frame_mod.Frame, idx: u16, checked: bool) ?core.JSValue {
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

fn decodeFieldAtom(code: []const u8, pc: usize, expected_op: u8) ?FieldAtom {
    if (pc + 5 > code.len or code[pc] != expected_op) return null;
    return .{
        .atom = readInt(u32, code[pc + 1 ..][0..4]),
        .next_pc = pc + 5,
    };
}

fn bindingReadableBorrowed(frame: *const frame_mod.Frame, binding: BindingGet) ?core.JSValue {
    return if (binding.is_var_ref)
        varRefReadableBorrowed(frame, binding.idx)
    else
        localReadableBorrowed(frame, binding.idx, binding.checked);
}

fn sameBinding(a: BindingGet, b: BindingGet) bool {
    return a.idx == b.idx and a.is_var_ref == b.is_var_ref;
}

fn sameBindingGetPut(get: BindingGet, put: BindingPut) bool {
    return get.idx == put.idx and get.is_var_ref == put.is_var_ref;
}

fn decodeGotoTarget(code: []const u8, goto_pc: usize) ?usize {
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

fn decodeLoopLimitGet(code: []const u8, pc: usize) ?struct { limit: LoopLimitGet, next_pc: usize } {
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

fn loopLimitReadableInt32(frame: *const frame_mod.Frame, limit: LoopLimitGet) ?i32 {
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

fn bindingStoreWritableForFastPath(
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
            const lookup = globalOwnDataPropertyBorrowedLookup(global, get.atom) orelse return null;
            break :blk lookup.value;
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

fn storeBindingInt32(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    binding: BindingPut,
    value: i32,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !void {
    if (binding.is_var_ref) {
        try setSlotValue(ctx, &frame.var_refs[binding.idx], core.JSValue.int32(value));
    } else {
        try setSlotValue(ctx, &frame.locals[binding.idx], core.JSValue.int32(value));
        try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, binding.idx, sync_global_lexical_locals);
    }
}

fn storeBindingOwnedValue(
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

fn asciiBytes(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte > 0x7f) return false;
    }
    return true;
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

pub fn tryFuseCheckedLocalSimpleNumericCallAddStore(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    func_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (func_idx >= frame.locals.len or func_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(func_idx)) return false;
    const func = slotValueBorrowed(frame.locals[func_idx]);
    if (func.isUninitialized()) return false;

    const arg0 = borrowedSimpleCallArg(frame, function, frame.pc) orelse return false;
    if (arg0.next_pc >= function.code.len) return false;
    var args_buf: [2]core.JSValue = undefined;
    args_buf[0] = arg0.value;
    var argc: usize = 1;
    var call_pc = arg0.next_pc;
    switch (function.code[call_pc]) {
        op.call1 => {},
        else => {
            const arg1 = borrowedSimpleCallArg(frame, function, arg0.next_pc) orelse return false;
            if (arg1.next_pc >= function.code.len or function.code[arg1.next_pc] != op.call2) return false;
            args_buf[1] = arg1.value;
            argc = 2;
            call_pc = arg1.next_pc;
        },
    }

    const result = try simpleNumericFunctionResult(ctx.runtime, func, args_buf[0..argc]) orelse return false;
    var result_owned = true;
    errdefer if (result_owned) result.free(ctx.runtime);
    if (try tryFuseVarRefCallResultAddStore(ctx, function, global, frame, stack, call_pc, result, &result_owned, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
    result.free(ctx.runtime);
    result_owned = false;
    return false;
}

pub fn tryFuseCheckedLocalAccumulatorSimpleNumericCallAddStore(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    accumulator_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    var callee_pc = frame.pc;
    if (callee_pc < function.code.len and function.code[callee_pc] == op.dup) callee_pc += 1;
    const callee = borrowedSimpleCallable(ctx, function, global, frame, callee_pc, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
    const arg0 = borrowedSimpleCallArgWithContext(ctx, function, global, frame, callee.next_pc, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
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

    const add_pc = call_pc + 1;
    if (add_pc >= function.code.len or function.code[add_pc] != op.add) return false;
    var store_pc = add_pc + 1;
    var drop_pc: ?usize = null;
    if (store_pc < function.code.len and function.code[store_pc] == op.dup) {
        store_pc += 1;
        const decoded_store = decodeLocalPut(function.code, store_pc) orelse return false;
        const candidate_drop_pc = decoded_store.operand_pc + decoded_store.consume;
        if (candidate_drop_pc >= function.code.len or function.code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const store = decodeLocalPut(function.code, store_pc) orelse return false;
    if (store.idx != accumulator_idx) return false;
    if (store.idx >= frame.locals.len or store.idx >= frame.locals_uninit.len) return false;
    if (store.checked) {
        if (frame.localIsUninitialized(store.idx)) return false;
        if (store.idx < function.var_is_const.len and function.var_is_const[store.idx]) return false;
    }

    const lhs = localReadableBorrowed(frame, accumulator_idx, true) orelse return false;
    if (!lhs.isNumber()) return false;
    const result = try simpleNumericFunctionResult(ctx.runtime, callee.value, args_buf[0..argc]) orelse return false;
    defer result.free(ctx.runtime);
    if (!result.isNumber()) return false;
    const updated = try simpleNumericBinary(ctx.runtime, op.add, lhs, result);
    errdefer updated.free(ctx.runtime);

    try setSlotValue(ctx, &frame.locals[store.idx], updated);
    if (!store.checked and store.idx < function.var_is_lexical.len and function.var_is_lexical[store.idx]) {
        frame.clearLocalUninitialized(store.idx);
    }
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, store.idx, sync_global_lexical_locals);
    frame.pc = if (drop_pc) |drop| drop + 1 else store.operand_pc + store.consume;
    _ = try tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    return true;
}

fn tryFuseLocalAccumulatorSimpleNumericCallAddStore(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    accumulator_idx: u16,
    checked: bool,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    var callee_pc = frame.pc;
    if (callee_pc < function.code.len and function.code[callee_pc] == op.dup) callee_pc += 1;
    const callee = borrowedSimpleCallableNoGlobal(frame, function, callee_pc) orelse return false;
    const arg0 = borrowedSimpleCallArg(frame, function, callee.next_pc) orelse return false;
    if (arg0.next_pc >= function.code.len) return false;

    var args_buf: [2]core.JSValue = undefined;
    args_buf[0] = arg0.value;
    var argc: usize = 1;
    var call_pc = arg0.next_pc;
    switch (function.code[call_pc]) {
        op.call1 => {},
        else => {
            const arg1 = borrowedSimpleCallArg(frame, function, arg0.next_pc) orelse return false;
            if (arg1.next_pc >= function.code.len or function.code[arg1.next_pc] != op.call2) return false;
            args_buf[1] = arg1.value;
            argc = 2;
            call_pc = arg1.next_pc;
        },
    }

    const add_pc = call_pc + 1;
    if (add_pc >= function.code.len or function.code[add_pc] != op.add) return false;
    var store_pc = add_pc + 1;
    var drop_pc: ?usize = null;
    if (store_pc < function.code.len and function.code[store_pc] == op.dup) {
        store_pc += 1;
        const decoded_store = decodeLocalPut(function.code, store_pc) orelse return false;
        const candidate_drop_pc = decoded_store.operand_pc + decoded_store.consume;
        if (candidate_drop_pc >= function.code.len or function.code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const store = decodeLocalPut(function.code, store_pc) orelse return false;
    if (store.idx != accumulator_idx) return false;
    if (store.idx >= frame.locals.len or store.idx >= frame.locals_uninit.len) return false;
    if (store.checked) {
        if (frame.localIsUninitialized(store.idx)) return false;
        if (store.idx < function.var_is_const.len and function.var_is_const[store.idx]) return false;
    }

    const lhs = localReadableBorrowed(frame, accumulator_idx, checked) orelse return false;
    if (!lhs.isNumber()) return false;
    const result = try simpleNumericFunctionResult(ctx.runtime, callee.value, args_buf[0..argc]) orelse return false;
    defer result.free(ctx.runtime);
    if (!result.isNumber()) return false;
    const updated = try simpleNumericBinary(ctx.runtime, op.add, lhs, result);
    errdefer updated.free(ctx.runtime);

    try setSlotValue(ctx, &frame.locals[store.idx], updated);
    if (!store.checked and store.idx < function.var_is_lexical.len and function.var_is_lexical[store.idx]) {
        frame.clearLocalUninitialized(store.idx);
    }
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, store.idx, sync_global_lexical_locals);
    frame.pc = if (drop_pc) |drop| drop + 1 else store.operand_pc + store.consume;
    _ = try tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    return true;
}

fn tryFuseVarRefCallResultAddStore(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    call_pc: usize,
    result: core.JSValue,
    result_owned: *bool,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const add_pc = call_pc + 1;
    if (add_pc >= function.code.len or function.code[add_pc] != op.add) return false;
    var store_pc = add_pc + 1;
    var drop_pc: ?usize = null;
    if (store_pc < function.code.len and function.code[store_pc] == op.dup) {
        store_pc += 1;
        const candidate_drop_pc = if (decodeVarRefPut(function.code, store_pc)) |decoded_store|
            decoded_store.operand_pc + decoded_store.consume
        else if (decodeLocalPut(function.code, store_pc)) |decoded_store|
            decoded_store.operand_pc + decoded_store.consume
        else
            return false;
        if (candidate_drop_pc >= function.code.len or function.code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const lhs = stack.peekBorrowed() orelse return false;
    if (!lhs.isNumber() or !result.isNumber()) return false;

    const var_ref_store = decodeVarRefPut(function.code, store_pc);
    const local_store = if (var_ref_store == null) decodeLocalPut(function.code, store_pc) else null;
    if (var_ref_store) |store| {
        if (!varRefStoreWritableForFastPath(ctx, function, global, frame, store)) return false;
    } else if (local_store) |store| {
        if (store.idx >= frame.locals.len or store.idx >= frame.locals_uninit.len) return false;
        if (store.checked) {
            if (frame.localIsUninitialized(store.idx)) return false;
            if (store.idx < function.var_is_const.len and function.var_is_const[store.idx]) return false;
        }
    } else return false;

    const updated = try simpleNumericBinary(ctx.runtime, op.add, lhs, result);
    errdefer updated.free(ctx.runtime);
    if (var_ref_store) |store| {
        const lhs_owned = try stack.pop();
        defer lhs_owned.free(ctx.runtime);
        result_owned.* = false;
        defer result.free(ctx.runtime);
        try setSlotValue(ctx, &frame.var_refs[store.idx], updated);
        frame.pc = if (drop_pc) |drop| drop + 1 else store.operand_pc + store.consume;
        _ = try tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
        return true;
    }
    if (local_store) |store| {
        const lhs_owned = try stack.pop();
        defer lhs_owned.free(ctx.runtime);
        result_owned.* = false;
        defer result.free(ctx.runtime);
        try setSlotValue(ctx, &frame.locals[store.idx], updated);
        if (!store.checked and store.idx < function.var_is_lexical.len and function.var_is_lexical[store.idx]) {
            frame.clearLocalUninitialized(store.idx);
        }
        try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, store.idx, sync_global_lexical_locals);
        frame.pc = if (drop_pc) |drop| drop + 1 else store.operand_pc + store.consume;
        _ = try tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
        return true;
    }
    unreachable;
}

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
    const accumulator_store_index = globalWritableDataStoreIndexForFastPath(ctx, global, function, store_pc, accumulator_atom) orelse return false;

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

    const induction_store_index = globalWritableDataStoreIndexForFastPath(ctx, global, function, induction_put_pc, induction_get.atom) orelse return false;
    const induction_value = globalOwnDataPropertyBorrowedAt(global, induction_store_index, induction_get.atom) orelse return false;
    const current_i = induction_value.asInt32() orelse return false;
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
    if (!setGlobalOwnWritableDataPropertyAtOwned(ctx.runtime, global, accumulator_store_index, accumulator_atom, accumulator_next)) {
        accumulator_next.free(ctx.runtime);
        return false;
    }
    const induction_next = core.JSValue.int32(limit.value);
    if (!setGlobalOwnWritableDataPropertyAtOwned(ctx.runtime, global, induction_store_index, induction_get.atom, induction_next)) {
        return false;
    }
    frame.pc = branch.false_pc;
    return true;
}

fn tryFuseCallResultAddGlobalStore(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    call_pc: usize,
    result: core.JSValue,
    result_owned: *bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) !bool {
    const add_pc = call_pc + 1;
    if (add_pc >= function.code.len or function.code[add_pc] != op.add) return false;

    var store_pc = add_pc + 1;
    var drop_pc: ?usize = null;
    if (store_pc < function.code.len and function.code[store_pc] == op.dup) {
        store_pc += 1;
        const decoded_store = decodeGlobalPut(function.code, store_pc) orelse return false;
        if (decoded_store.next_pc >= function.code.len or function.code[decoded_store.next_pc] != op.drop) return false;
        drop_pc = decoded_store.next_pc;
    }
    const store = decodeGlobalPut(function.code, store_pc) orelse return false;
    if (!canFuseGlobalDataWrite(function, frame, store.atom, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    if (ctx.lexicals) |env| {
        if (env.hasOwnProperty(store.atom)) return false;
    }
    const store_index = globalWritableDataStoreIndexForFastPath(ctx, global, function, store_pc, store.atom) orelse return false;

    const lhs = stack.peekBorrowed() orelse return false;
    if (!lhs.isNumber() or !result.isNumber()) return false;

    const updated = try simpleNumericBinary(ctx.runtime, op.add, lhs, result);
    errdefer updated.free(ctx.runtime);
    if (!setGlobalOwnWritableDataPropertyAtOwned(ctx.runtime, global, store_index, store.atom, updated)) {
        updated.free(ctx.runtime);
        return false;
    }

    const lhs_owned = try stack.pop();
    defer lhs_owned.free(ctx.runtime);
    result_owned.* = false;
    defer result.free(ctx.runtime);
    frame.pc = if (drop_pc) |drop| drop + 1 else store.next_pc;
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
            const field_value = fastOrdinaryDataPropertyBorrowedValue(ctx.runtime, receiver_value, field_get.atom) orelse return false;
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
    const accumulator_store_index = globalWritableDataStoreIndexForFastPath(ctx, global, function, store_pc, accumulator_atom) orelse return false;

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

    const induction_store_index = globalWritableDataStoreIndexForFastPath(ctx, global, function, induction_put_pc, induction_get.atom) orelse return false;
    const induction_value = globalOwnDataPropertyBorrowedAt(global, induction_store_index, induction_get.atom) orelse return false;
    const current_i = induction_value.asInt32() orelse return false;
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
    if (!setGlobalOwnWritableDataPropertyAtOwned(ctx.runtime, global, accumulator_store_index, accumulator_atom, accumulator_next)) {
        accumulator_next.free(ctx.runtime);
        return false;
    }
    const induction_next = core.JSValue.int32(limit.value);
    if (!setGlobalOwnWritableDataPropertyAtOwned(ctx.runtime, global, induction_store_index, induction_get.atom, induction_next)) {
        return false;
    }
    frame.pc = branch.false_pc;
    return true;
}

fn decodeVarRefPut(code: []const u8, pc: usize) ?VarRefPut {
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

fn decodeVarRefGet(code: []const u8, pc: usize) ?VarRefGet {
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

fn decodeBindingGet(code: []const u8, pc: usize) ?BindingGet {
    if (decodeVarRefGet(code, pc)) |get| {
        return .{ .idx = get.idx, .next_pc = get.next_pc, .is_var_ref = true };
    }
    if (decodeLocalGet(code, pc)) |get| {
        return .{ .idx = get.idx, .next_pc = get.next_pc, .is_var_ref = false, .checked = get.checked };
    }
    return null;
}

fn decodeBindingPut(code: []const u8, pc: usize) ?BindingPut {
    if (decodeVarRefPut(code, pc)) |put| {
        return .{ .idx = put.idx, .opc = put.opc, .operand_pc = put.operand_pc, .consume = put.consume, .is_var_ref = true };
    }
    if (decodeLocalPut(code, pc)) |put| {
        return .{ .idx = put.idx, .operand_pc = put.operand_pc, .consume = put.consume, .is_var_ref = false, .checked = put.checked };
    }
    return null;
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

fn decodeGlobalPut(code: []const u8, pc: usize) ?GlobalBindingPut {
    if (pc + 5 > code.len or code[pc] != op.put_var) return null;
    return .{
        .atom = readInt(u32, code[pc + 1 ..][0..4]),
        .next_pc = pc + 5,
    };
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

fn decodeLatin1PrefixIntLocalKey(ctx: *core.JSContext, code: []const u8, pc: usize, local_idx: u16) ?Latin1PrefixIntLocalKey {
    if (pc + 6 > code.len or code[pc] != op.push_atom_value) return null;
    const prefix_atom = readInt(u32, code[pc + 1 ..][0..4]);
    const prefix = ctx.runtime.atoms.name(prefix_atom) orelse return null;
    if (!asciiBytes(prefix)) return null;
    const index_get = decodeLocalGet(code, pc + 5) orelse return null;
    if (!index_get.checked or index_get.idx != local_idx) return null;
    if (index_get.next_pc >= code.len or code[index_get.next_pc] != op.add) return null;
    return .{ .prefix = prefix, .next_pc = index_get.next_pc + 1 };
}

fn parseInductionAndImmediateInt32Args(code: []const u8, pc: usize, local_idx: u16) ?InductionImmediateInt32Args {
    if (decodeLocalGet(code, pc)) |arg0_get| {
        if (!arg0_get.checked or arg0_get.idx != local_idx) return null;
        const arg1 = immediateInt32Operand(code, arg0_get.next_pc) orelse return null;
        return .{ .immediate = arg1.value, .next_pc = arg1.next_pc };
    }
    const arg0 = immediateInt32Operand(code, pc) orelse return null;
    const arg1_get = decodeLocalGet(code, arg0.next_pc) orelse return null;
    if (!arg1_get.checked or arg1_get.idx != local_idx) return null;
    return .{ .immediate = arg0.value, .next_pc = arg1_get.next_pc };
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

fn decodeSimpleNumericRangeArg(code: []const u8, pc: usize, local_idx: u16) ?struct { arg: SimpleNumericRangeArg, next_pc: usize } {
    if (decodeLocalGet(code, pc)) |get| {
        if (!get.checked or get.idx != local_idx) return null;
        return .{ .arg = .induction, .next_pc = get.next_pc };
    }
    const immediate = immediateInt32Operand(code, pc) orelse return null;
    return .{ .arg = .{ .int32 = immediate.value }, .next_pc = immediate.next_pc };
}

fn decodeSimpleNumericGlobalRangeArg(code: []const u8, pc: usize) ?struct { arg: GlobalSimpleNumericRangeArg, next_pc: usize } {
    if (decodeGlobalDataGet(code, pc)) |get| {
        return .{ .arg = .{ .global = get.atom }, .next_pc = get.next_pc };
    }
    const immediate = immediateInt32Operand(code, pc) orelse return null;
    return .{ .arg = .{ .int32 = immediate.value }, .next_pc = immediate.next_pc };
}

fn canStartVarRefOrLocalGet(code: []const u8, pc: usize) bool {
    if (pc >= code.len) return false;
    return switch (code[pc]) {
        op.get_var_ref,
        op.get_var_ref_check,
        op.get_var_ref0,
        op.get_var_ref1,
        op.get_var_ref2,
        op.get_var_ref3,
        op.get_loc,
        op.get_loc8,
        op.get_loc_check,
        op.get_loc0,
        op.get_loc1,
        op.get_loc2,
        op.get_loc3,
        => true,
        else => false,
    };
}

fn canStartBorrowedSimpleCallable(code: []const u8, pc: usize) bool {
    if (pc >= code.len) return false;
    if (code[pc] == op.dup) return canStartBorrowedSimpleCallable(code, pc + 1);
    return switch (code[pc]) {
        op.get_var,
        op.get_var_undef,
        => pc + 5 <= code.len,
        op.get_var_ref,
        op.get_var_ref_check,
        op.get_loc,
        op.get_loc_check,
        => pc + 3 <= code.len,
        op.get_var_ref0,
        op.get_var_ref1,
        op.get_var_ref2,
        op.get_var_ref3,
        op.get_loc0,
        op.get_loc1,
        op.get_loc2,
        op.get_loc3,
        => true,
        op.get_loc8 => pc + 2 <= code.len,
        else => false,
    };
}

fn canStartBorrowedSimpleCallArg(code: []const u8, pc: usize) bool {
    if (pc >= code.len) return false;
    return switch (code[pc]) {
        op.get_var,
        op.get_var_undef,
        => pc + 5 <= code.len,
        op.get_var_ref, op.get_var_ref_check, op.get_loc, op.get_loc_check, op.push_i16 => pc + 3 <= code.len,
        op.get_loc8, op.push_i8 => pc + 2 <= code.len,
        op.push_i32 => pc + 5 <= code.len,
        op.get_var_ref0,
        op.get_var_ref1,
        op.get_var_ref2,
        op.get_var_ref3,
        op.get_loc0,
        op.get_loc1,
        op.get_loc2,
        op.get_loc3,
        op.push_minus1,
        op.push_0,
        op.push_1,
        op.push_2,
        op.push_3,
        op.push_4,
        op.push_5,
        op.push_6,
        op.push_7,
        => true,
        else => false,
    };
}

fn canStartGlobalCall1(code: []const u8, pc: usize) bool {
    return pc + 6 <= code.len and (code[pc] == op.get_var or code[pc] == op.get_var_undef) and code[pc + 5] == op.call1;
}

fn decodeLocalPut(code: []const u8, pc: usize) ?LocalPut {
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

fn borrowedSimpleCallArg(frame: *const frame_mod.Frame, function: *const bytecode.Bytecode, pc: usize) ?BorrowedArg {
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

fn borrowedSimpleCallArgWithContext(
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

fn varRefReadableBorrowed(frame: *const frame_mod.Frame, idx: u16) ?core.JSValue {
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

fn borrowedVarRefOrLocalRhs(frame: *const frame_mod.Frame, code: []const u8, pc: usize) ?struct { value: core.JSValue, next_pc: usize } {
    if (decodeVarRefGet(code, pc)) |rhs| {
        return .{
            .value = varRefReadableBorrowed(frame, rhs.idx) orelse return null,
            .next_pc = rhs.next_pc,
        };
    }
    if (decodeLocalGet(code, pc)) |rhs| {
        return .{
            .value = localReadableBorrowed(frame, rhs.idx, rhs.checked) orelse return null,
            .next_pc = rhs.next_pc,
        };
    }
    return null;
}

fn fastNumericAddBorrowed(rt: *core.JSRuntime, lhs: core.JSValue, rhs: core.JSValue) !?core.JSValue {
    if (lhs.asInt32()) |lhs_int| {
        if (rhs.asInt32()) |rhs_int| return fastInt32Add(lhs_int, rhs_int);
    }
    if (lhs.asShortBigInt()) |lhs_bigint| {
        if (rhs.asShortBigInt()) |rhs_bigint| {
            return value_ops.shortBigIntBinary(op.add, lhs_bigint, rhs_bigint);
        }
    }
    if (!lhs.isNumber() or !rhs.isNumber()) return null;
    return try value_ops.binary(rt, op.add, lhs, rhs);
}

fn tryFuseDroppedVarRefNumericAdd(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    lhs_idx: u16,
    consume: u8,
    comptime setSlotValue: anytype,
) !bool {
    const pc = frame.pc + consume;
    const code = function.code;
    const rhs = borrowedVarRefOrLocalRhs(frame, code, pc) orelse return false;
    if (rhs.next_pc + 2 > code.len or code[rhs.next_pc] != op.add or code[rhs.next_pc + 1] != op.dup) return false;

    const store = decodeVarRefPut(code, rhs.next_pc + 2) orelse return false;
    if (store.idx != lhs_idx) return false;
    const drop_pc = store.operand_pc + store.consume;
    if (drop_pc >= code.len or code[drop_pc] != op.drop) return false;
    if (!varRefStoreWritableForFastPath(ctx, function, global, frame, store)) return false;

    const lhs = varRefReadableBorrowed(frame, lhs_idx) orelse return false;
    const updated = try fastNumericAddBorrowed(ctx.runtime, lhs, rhs.value) orelse return false;
    errdefer updated.free(ctx.runtime);

    try setSlotValue(ctx, &frame.var_refs[store.idx], updated);
    frame.pc = drop_pc + 1;
    return true;
}

fn varRefStoreWritableForFastPath(
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

fn isSimpleNumericCallableCandidate(func: core.JSValue) bool {
    return func.isFunctionBytecode() or shared_vm.functionObjectFromValue(func) != null;
}

fn simpleNumericFunctionResult(rt: *core.JSRuntime, func: core.JSValue, args: []const core.JSValue) !?core.JSValue {
    if (func.isFunctionBytecode()) {
        const fb = shared_vm.functionBytecodeFromValue(func) orelse return null;
        return try simpleNumericBytecodeResult(rt, fb, args, &.{});
    }
    const object = shared_vm.functionObjectFromValue(func) orelse return null;
    const function_value = object.functionBytecodeSlot().* orelse return null;
    const fb = shared_vm.functionBytecodeFromValue(function_value) orelse return null;
    return try simpleNumericBytecodeResult(rt, fb, args, object.functionCapturesSlot().*);
}

fn simpleNumericArg0ConstCallable(func: core.JSValue) ?SimpleNumericArg0ConstCall {
    const fb = if (func.isFunctionBytecode())
        shared_vm.functionBytecodeFromValue(func) orelse return null
    else blk: {
        const object = shared_vm.functionObjectFromValue(func) orelse return null;
        const function_value = object.functionBytecodeSlot().* orelse return null;
        break :blk shared_vm.functionBytecodeFromValue(function_value) orelse return null;
    };
    if (fb.simple_numeric_kind != .arg0_const) return null;
    return .{ .binop = fb.simple_numeric_op, .rhs = fb.simple_numeric_rhs };
}

fn simpleNumericRangeCallable(func: core.JSValue) ?SimpleNumericRangeCall {
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
        .none => null,
    };
}

fn simpleNumericRangeLinearTerm(simple: SimpleNumericRangeCall, args: []const SimpleNumericRangeArg) ?SimpleNumericLinearTerm {
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
        .none => null,
    };
}

fn simpleNumericRangeArgIsInduction(range_arg: SimpleNumericRangeArg) bool {
    return switch (range_arg) {
        .induction => true,
        .int32 => false,
    };
}

fn simpleNumericRangeCallAliasesBinding(simple: SimpleNumericRangeCall, frame: *const frame_mod.Frame, binding: BindingGet) bool {
    if (simple.kind != .capture0_arg0) return false;
    if (varRefCellFromValue(simple.capture0_slot) == null) return false;
    const raw_binding = if (binding.is_var_ref) blk: {
        if (binding.idx >= frame.var_refs.len) return false;
        break :blk frame.var_refs[binding.idx];
    } else blk: {
        if (binding.idx >= frame.locals.len) return false;
        break :blk frame.locals[binding.idx];
    };
    return simple.capture0_slot.same(raw_binding);
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

fn slotValueBorrowed(slot: core.JSValue) core.JSValue {
    var current = slot;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        const cell = varRefCellFromValue(current) orelse return current;
        current = cell.varRefValueSlot().* orelse return core.JSValue.undefinedValue();
    }
    return current;
}

pub fn lexicalTdz(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    opc: u8,
    catch_target: *?usize,
    sync_global_lexical_locals: bool,
    comptime ensureLocalsCapacity: anytype,
    comptime throwTdzReference: anytype,
    comptime handleCatchableRuntimeError: anytype,
    comptime pushSlotValue: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !Step {
    const idx = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    _ = ensureLocalsCapacity;
    if (idx >= frame.locals.len or idx >= frame.locals_uninit.len) return error.InvalidBytecode;
    switch (opc) {
        op.set_loc_uninitialized => frame.setLocalUninitialized(idx),
        op.get_loc_check => {
            if (frame.localIsUninitialized(idx)) {
                const err = throwTdzReference(ctx);
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            }
            try pushSlotValue(stack, frame.locals[idx]);
        },
        op.put_loc_check => {
            if (frame.localIsUninitialized(idx)) {
                const err = throwTdzReference(ctx);
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            }
            const value = try stack.pop();
            if (idx < function.var_is_const.len and function.var_is_const[idx]) {
                value.free(ctx.runtime);
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
                return error.TypeError;
            }
            try setSlotValue(ctx, &frame.locals[idx], value);
            try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
        },
        op.put_loc_check_init => {
            const value = try stack.pop();
            try setSlotValue(ctx, &frame.locals[idx], value);
            frame.clearLocalUninitialized(idx);
            try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
        },
        else => unreachable,
    }
    return .done;
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
    if (fastInstalledGlobalDataLookupForAtomAtPc(ctx, function, global, frame, site_pc, atom_id, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) |global_data| {
        return try useFastGlobalDataValue(ctx, stack, function, global, frame, catch_target, atom_id, global_data, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal, handleCatchableRuntimeError);
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
        if (cachedOwnDataPropertyLookupForObject(function, site_pc, ctx.runtime, global, atom_id)) |cached| {
            return try useFastGlobalDataValue(ctx, stack, function, global, frame, catch_target, atom_id, .{ .index = cached.index, .value = cached.value }, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal, handleCatchableRuntimeError);
        }
        if (declaredGlobalVarDataBorrowedLookup(global, function, atom_id)) |declared| {
            installOwnDataIcForObject(function, site_pc, ctx.runtime, global, atom_id, declared.index);
            return try useFastGlobalDataValue(ctx, stack, function, global, frame, catch_target, atom_id, declared, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal, handleCatchableRuntimeError);
        }
        if (globalOwnDataPropertyBorrowedLookup(global, atom_id)) |global_data| {
            installOwnDataIcForObject(function, site_pc, ctx.runtime, global, atom_id, global_data.index);
            return try useFastGlobalDataValue(ctx, stack, function, global, frame, catch_target, atom_id, global_data, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal, handleCatchableRuntimeError);
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
    if (pc + 7 > code.len or code[pc] != op.dup or code[pc + 1] != op.get_var) return false;
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
    if (!decodeDefaultPrintGet(global, code, &pc)) return false;
    const local_get = decodeTypedArrayLengthPrintGet(code, pc) orelse return false;
    if (local_get.idx != store.local_index) return false;
    pc = local_get.next_pc;
    if (pc + 3 > code.len or code[pc] != op.get_length or code[pc + 1] != op.call1 or code[pc + 2] != op.drop) return false;
    const after_drop = pc + 3;
    if (!nextInstructionReturnsUndefined(code, after_drop)) return false;

    const typed_array_ctor = fastGlobalDataValueForAtom(ctx, function, global, frame, typed_array_atom, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
    const typed_array_object = objectFromValue(typed_array_ctor) orelse return false;
    const element_size_u32 = typed_array_object.typedArrayElementSize();
    if (element_size_u32 == 0 or typed_array_object.typedArrayKind() == 0) return false;

    const array_buffer_ctor = fastGlobalDataValueForAtom(ctx, function, global, frame, atom_array_buffer, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
    const array_buffer_object = objectFromValue(array_buffer_ctor) orelse return false;
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

const DecodedImmediateInt32 = struct {
    value: i32,
    next_pc: usize,
};

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

const TypedArrayLengthPrintStore = struct {
    local_index: u16,
    next_pc: usize,
};

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

const TypedArrayLengthPrintGet = struct {
    idx: u16,
    next_pc: usize,
};

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

fn decodeDefaultPrintGet(global: *core.Object, code: []const u8, pc: *usize) bool {
    if (pc.* + 5 > code.len or code[pc.*] != op.get_var) return false;
    const print_atom = readInt(u32, code[pc.* + 1 ..][0..4]);
    if (print_atom != atom_print) return false;
    if (!globalHostOutputAutoInit(global, print_atom)) return false;
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
    if (!globalHostOutputAutoInit(global, atom_id)) return false;

    if (try tryFuseHostOutputAtomLiteralCall1(ctx, output, stack, function, frame)) return true;
    if (try tryFuseHostOutputStringNumberConstCall1(ctx, output, global, stack, function, frame, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return true;
    if (try tryFuseHostOutputStringLocalNumberCall1(ctx, output, global, stack, function, frame, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return true;
    if (try tryFuseHostOutputNumberStaticLiteralCall1(ctx, output, global, stack, function, frame, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return true;
    if (try tryFuseHostOutputLocalCall1(ctx, output, stack, function, frame)) return true;
    if (try tryFuseHostOutputTypeofLocalCall1(ctx, output, stack, function, frame)) return true;
    if (try tryFuseHostOutputLocalFieldStrictEqUndefinedCall1(ctx, output, global, stack, function, frame, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue)) return true;
    if (try tryFuseHostOutputLocalImmediateCompareCall1(ctx, output, stack, function, frame)) return true;
    if (try tryFuseHostOutputLocalLengthCall1(ctx, output, stack, function, frame)) return true;
    if (try tryFuseHostOutputLocalFieldCall1(ctx, output, stack, function, frame)) return true;
    if (try tryFuseHostOutputLocalDenseElementCall1(ctx, output, stack, function, frame)) return true;
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
    const callee_lookup = globalOwnDataPropertyBorrowedLookup(global, callee_atom) orelse return false;
    if (!isStringConstructorValue(callee_lookup.value)) return false;

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
    const callee_lookup = globalOwnDataPropertyBorrowedLookup(global, callee_atom) orelse return false;
    if (!isStringConstructorValue(callee_lookup.value)) return false;

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
    const number_lookup = globalOwnDataPropertyBorrowedLookup(global, callee_atom) orelse return false;

    const field_pc = pc + 5;
    if (code[field_pc] != op.get_field2) return false;
    const method_atom = readInt(u32, code[field_pc + 1 ..][0..4]);
    const native_ref = fastFunctionOwnNativeBuiltinIdAtPc(function, field_pc, ctx.runtime, number_lookup.value, method_atom) orelse return false;
    if (native_ref.domain != .number) return false;
    const parsed = numberStaticLiteralResultAt(ctx.runtime, function, native_ref.id, field_pc + 5) orelse return false;
    if (parsed.next_pc >= code.len or code[parsed.next_pc] != op.call1) return false;

    const result = value_ops.numberToValue(parsed.number);
    try printHostOutputStringifiedNumber(output, result);
    result.free(ctx.runtime);
    try finishUndefinedCallResult(stack, function, frame, parsed.next_pc + 1);
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
    const is_undefined = switch (fastOrdinaryDataPropertyLookup(ctx.runtime, receiver, field_atom)) {
        .value => |property_value| property_value.isUndefined(),
        .undefined => true,
        .slow => return false,
    };
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
    const value = switch (fastOrdinaryDataPropertyLookup(ctx.runtime, receiver, field_atom)) {
        .value => |property_value| property_value,
        .undefined => core.JSValue.undefinedValue(),
        .slow => return false,
    };
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

fn finishUndefinedCallResult(
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    next_pc: usize,
) !void {
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

fn canFinishWithUndefinedAt(function: *const bytecode.Bytecode, pc: usize) bool {
    if (function.flags.is_generator or function.flags.is_async) return false;
    const code = function.code;
    if (pc >= code.len) return false;
    if (code[pc] == op.return_undef) return true;
    return pc + 2 == code.len and code[pc] == op.undefined and code[pc + 1] == op.return_async;
}

fn globalHostOutputAutoInit(global: *core.Object, atom_id: core.Atom) bool {
    if (global.exotic != null) return false;
    for (global.properties) |*entry| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        if (entry.flags.accessor) return false;
        return switch (entry.slot) {
            .auto_init => |info| info.host_function_kind == core.host_function.ids.output,
            .data, .accessor, .deleted => false,
        };
    }
    return false;
}

fn useFastGlobalDataValue(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    atom_id: core.Atom,
    global_data: BorrowedGlobalDataLookup,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    const value = global_data.value;
    if (atom_id == atom_date and try tryFuseGlobalDateNowCall(ctx, stack, function, frame, value)) return .done;
    if (atom_id == atom_string and try tryFuseGlobalStringCall1NumberConst(ctx.runtime, stack, function, frame, value)) return .done;
    if (atom_id == atom_string and
        try tryFuseGlobalStringFromCharCodeInt32LocalAppend(ctx, function, global, frame, stack, value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .done;
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
            try tryFuseDroppedGlobalDataPostUpdateFromValue(ctx, global, function, frame, atom_id, global_data.index, value)) return .done;
    } else {
        if (value.isString()) {
            if (try tryFuseGlobalStringPercentHexAddStore(ctx, stack, function, global, frame, catch_target, value, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, handleCatchableRuntimeError)) |step| return step;
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

const StringNumberConstCall = struct {
    value: core.JSValue,
    next_pc: usize,
};

const StringNumberConstArg = struct {
    value: core.JSValue,
    next_pc: usize,
};

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

fn pushBorrowedValueOrFuseLocalAdd(
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
    if (try tryFuseLocalAddWithValue(ctx, stack, function, global, frame, value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return;
    try stack.push(value);
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
    atom_id: core.Atom,
    property_index: usize,
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
    if (!setGlobalOwnWritableDataPropertyAt(ctx.runtime, global, property_index, atom_id, updated)) {
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

pub fn tryFuseCheckedLocalCachedGlobalInt32Add(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    local_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime globalLexicalValue: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const pc = frame.pc;
    const code = function.code;
    if (pc + 8 > code.len) return false;
    const global_read_op = code[pc];
    if (global_read_op != op.get_var and global_read_op != op.get_var_undef) return false;
    if (code[pc + 5] != op.add) return false;
    var store_pc = pc + 6;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const decoded_store = decodeLocalPut(code, store_pc) orelse return false;
        const candidate_drop_pc = decoded_store.operand_pc + decoded_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const store = decodeLocalPut(code, store_pc) orelse return false;
    if (!store.checked or store.idx != local_idx) return false;
    if (local_idx >= frame.locals.len or local_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(local_idx)) return false;
    if (local_idx < function.var_is_const.len and function.var_is_const[local_idx]) return false;

    const atom_id = readInt(u32, code[pc + 1 ..][0..4]);
    const cached: BorrowedGlobalDataLookup = cached: {
        if (ctx.lexicals != null) {
            if (globalLexicalValue(ctx, atom_id)) |lexical_value| {
                lexical_value.free(ctx.runtime);
                return false;
            }
        }
        if (cachedOwnDataPropertyLookupForObject(function, pc, ctx.runtime, global, atom_id)) |own_data| {
            break :cached .{ .index = own_data.index, .value = own_data.value };
        }
        if (declaredGlobalVarDataBorrowedLookup(global, function, atom_id)) |declared| {
            installOwnDataIcForObject(function, pc, ctx.runtime, global, atom_id, declared.index);
            break :cached declared;
        }
        const global_data = globalOwnDataPropertyBorrowedLookup(global, atom_id) orelse return false;
        installOwnDataIcForObject(function, pc, ctx.runtime, global, atom_id, global_data.index);
        break :cached global_data;
    };
    const lhs = frame.locals[local_idx].asInt32() orelse return false;
    const rhs = cached.value.asInt32() orelse return false;

    if (ctx.runtime.opcode_profile != null) core.profile.recordGlobalLookup();
    try setSlotValue(ctx, &frame.locals[local_idx], fastInt32Add(lhs, rhs));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, local_idx, sync_global_lexical_locals);
    frame.pc = if (drop_pc) |drop| drop + 1 else store.operand_pc + store.consume;
    _ = try tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    return true;
}

pub fn tryFuseCheckedLocalRegExpTestConstStringCountRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!allow_loop_tail_fusion or ctx.runtime.hasInterruptHandler()) return false;
    if (induction_idx >= frame.locals.len or induction_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(induction_idx)) return false;

    const condition_pc = if (frame.pc >= 3) frame.pc - 3 else return false;
    const pc = frame.pc;
    const code = function.code;
    if (pc + 7 > code.len or code[pc] != op.push_i32 or code[pc + 5] != op.lt) return false;
    const limit = readInt(i32, code[pc + 1 ..][0..4]);
    const exit_branch = decodeFalseBranch(code, pc + 6) orelse return false;
    const current_i = frame.locals[induction_idx].asInt32() orelse return false;
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }
    const iteration_count_i64 = @as(i64, limit) - @as(i64, current_i);
    if (iteration_count_i64 <= 0 or iteration_count_i64 > std.math.maxInt(i32)) return false;
    const iteration_count: i32 = @intCast(iteration_count_i64);

    const receiver_get = decodeBindingGet(code, exit_branch.true_pc) orelse return false;
    if (receiver_get.next_pc + 11 > code.len or code[receiver_get.next_pc] != op.get_field2) return false;
    const method_atom = readInt(u32, code[receiver_get.next_pc + 1 ..][0..4]);
    if (!value_ops.atomNameEql(ctx.runtime, method_atom, "test")) return false;
    const input_pc = receiver_get.next_pc + 5;
    if (code[input_pc] != op.push_atom_value) return false;
    const input_atom = readInt(u32, code[input_pc + 1 ..][0..4]);
    const call_pc = input_pc + 5;
    if (call_pc + 4 > code.len or code[call_pc] != op.call_method or readInt(u16, code[call_pc + 1 ..][0..2]) != 1) return false;
    const test_branch = decodeFalseBranch(code, call_pc + 3) orelse return false;

    const counter_get = decodeBindingGet(code, test_branch.true_pc) orelse return false;
    if (counter_get.next_pc >= code.len or code[counter_get.next_pc] != op.post_inc) return false;
    const counter_put = decodeBindingPut(code, counter_get.next_pc + 1) orelse return false;
    if (counter_put.idx != counter_get.idx or counter_put.is_var_ref != counter_get.is_var_ref) return false;
    const counter_drop_pc = counter_put.operand_pc + counter_put.consume;
    if (counter_drop_pc >= code.len or code[counter_drop_pc] != op.drop) return false;
    if (counter_drop_pc + 1 != test_branch.false_pc) return false;

    const tail_get = decodeLocalGet(code, test_branch.false_pc) orelse return false;
    if (!tail_get.checked or tail_get.idx != induction_idx) return false;
    if (tail_get.next_pc >= code.len or code[tail_get.next_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_get.next_pc + 1) orelse return false;
    if (!tail_put.checked or tail_put.idx != induction_idx) return false;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return false;

    const receiver = bindingReadableBorrowed(frame, receiver_get) orelse return false;
    const regexp_object = objectFromValue(receiver) orelse return false;
    if (regexp_object.class_id != core.class.ids.regexp) return false;
    if (!fastRegExpPrototypeMethodIsDefault(ctx.runtime, receiver, method_atom, @intFromEnum(builtins.regexp.PrototypeMethod.test_))) return false;
    const input_bytes = ctx.runtime.atoms.name(input_atom) orelse return false;
    const matched = try shared_vm.qjsRegExpTestFastNoResultLatin1(ctx, regexp_object, input_bytes) orelse return false;

    if (counter_put.is_var_ref) {
        if (counter_put.idx >= frame.var_refs.len) return false;
        if (varRefCellFromValue(frame.var_refs[counter_put.idx])) |cell| {
            if (cell.varRefIsDeletedSlot().* or cell.varRefIsFunctionNameSlot().* or cell.varRefIsConstSlot().*) return false;
        }
    } else {
        if (counter_put.idx >= frame.locals.len or counter_put.idx >= frame.locals_uninit.len) return false;
        if (frame.localIsUninitialized(counter_put.idx)) return false;
        if (counter_put.idx < function.var_is_const.len and function.var_is_const[counter_put.idx]) return false;
    }
    if (matched) {
        const current_count = (bindingReadableBorrowed(frame, counter_get) orelse return false).asInt32() orelse return false;
        const next_count_i64 = @as(i64, current_count) + @as(i64, iteration_count);
        if (next_count_i64 < std.math.minInt(i32) or next_count_i64 > std.math.maxInt(i32)) return false;
        if (counter_get.is_var_ref) {
            try setSlotValue(ctx, &frame.var_refs[counter_get.idx], core.JSValue.int32(@intCast(next_count_i64)));
        } else {
            try setSlotValue(ctx, &frame.locals[counter_get.idx], core.JSValue.int32(@intCast(next_count_i64)));
            try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, counter_get.idx, sync_global_lexical_locals);
        }
    }
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

pub fn tryFuseCheckedLocalSimpleNumericCallAddRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!allow_loop_tail_fusion or ctx.runtime.hasInterruptHandler()) return false;
    if (eval_local_names.len != 0 or eval_var_ref_names.len != 0) return false;
    if (frame.eval_local_names.len != 0 or frame.eval_var_ref_names.len != 0) return false;
    if (!eval_with_object.isUndefined()) return false;
    if (induction_idx >= frame.locals.len or induction_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(induction_idx)) return false;

    const condition_pc = if (frame.pc >= 3) frame.pc - 3 else return false;
    const pc = frame.pc;
    const code = function.code;
    if (pc + 7 > code.len or code[pc] != op.push_i32 or code[pc + 5] != op.lt) return false;
    const limit = readInt(i32, code[pc + 1 ..][0..4]);
    const exit_branch = decodeFalseBranch(code, pc + 6) orelse return false;
    const current_i = frame.locals[induction_idx].asInt32() orelse return false;
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }
    const iteration_count_i128 = @as(i128, limit) - @as(i128, current_i);
    if (iteration_count_i128 <= 0 or iteration_count_i128 > std.math.maxInt(i32)) return false;

    const accumulator_get = decodeBindingGet(code, exit_branch.true_pc) orelse return false;
    const callee = borrowedSimpleCallable(ctx, function, global, frame, accumulator_get.next_pc, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
    const arg0 = decodeSimpleNumericRangeArg(code, callee.next_pc, induction_idx) orelse return false;
    var args_buf: [2]SimpleNumericRangeArg = undefined;
    args_buf[0] = arg0.arg;
    var argc: usize = 1;
    var call_pc = arg0.next_pc;
    if (call_pc >= code.len) return false;
    switch (code[call_pc]) {
        op.call1 => {},
        else => {
            const arg1 = decodeSimpleNumericRangeArg(code, call_pc, induction_idx) orelse return false;
            if (arg1.next_pc >= code.len or code[arg1.next_pc] != op.call2) return false;
            args_buf[1] = arg1.arg;
            argc = 2;
            call_pc = arg1.next_pc;
        },
    }
    const add_pc = call_pc + 1;
    if (add_pc >= code.len or code[add_pc] != op.add) return false;
    var store_pc = add_pc + 1;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const candidate_store = decodeBindingPut(code, store_pc) orelse return false;
        const candidate_drop_pc = candidate_store.operand_pc + candidate_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const accumulator_put = decodeBindingPut(code, store_pc) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

    var tail_pc = if (drop_pc) |drop| drop + 1 else accumulator_put.operand_pc + accumulator_put.consume;
    if (tail_pc < code.len and code[tail_pc] == op.close_loc) {
        if (tail_pc + 3 > code.len) return false;
        const close_idx = readInt(u16, code[tail_pc + 1 ..][0..2]);
        if (close_idx != induction_idx) return false;
        if (varRefCellFromValue(frame.locals[induction_idx]) != null) return false;
        tail_pc += 3;
    }
    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (!tail_get.checked or tail_get.idx != induction_idx) return false;
    tail_pc = tail_get.next_pc;
    if (tail_pc >= code.len or code[tail_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_pc + 1) orelse return false;
    if (!tail_put.checked or tail_put.idx != induction_idx) return false;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return false;

    const accumulator = (bindingReadableBorrowed(frame, accumulator_get) orelse return false).asInt32() orelse return false;
    const simple = simpleNumericRangeCallable(callee.value) orelse return false;
    if (simpleNumericRangeCallAliasesBinding(simple, frame, accumulator_get)) return false;
    if (simpleNumericRangeCallAliasesBinding(simple, frame, .{ .idx = induction_idx, .next_pc = 0, .is_var_ref = false, .checked = true })) return false;
    const linear = simpleNumericRangeLinearTerm(simple, args_buf[0..argc]) orelse return false;
    const delta = linearRangeDeltaBounds(@as(i128, current_i), @as(i128, limit), linear.coefficient, linear.offset) orelse return false;
    const min_accumulator = @as(i128, accumulator) + delta.min;
    const max_accumulator = @as(i128, accumulator) + delta.max;
    if (!safeIntegerI128(min_accumulator) or !safeIntegerI128(max_accumulator)) return false;
    const final_accumulator = @as(i128, accumulator) + delta.total;

    const final_value = value_ops.numberToValue(@floatFromInt(final_accumulator));
    try storeBindingOwnedValue(ctx, function, global, frame, accumulator_put, final_value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

pub fn tryFuseCheckedLocalInvariantBindingInt32AddRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!allow_loop_tail_fusion or ctx.runtime.hasInterruptHandler()) return false;
    if (induction_idx >= frame.locals.len or induction_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(induction_idx)) return false;

    const condition_pc = if (frame.pc >= 3) frame.pc - 3 else return false;
    const pc = frame.pc;
    const code = function.code;
    const limit_operand = immediateInt32Operand(code, pc) orelse return false;
    if (limit_operand.next_pc >= code.len or code[limit_operand.next_pc] != op.lt) return false;
    const exit_branch = decodeFalseBranch(code, limit_operand.next_pc + 1) orelse return false;
    const limit = limit_operand.value;
    const current_i = frame.locals[induction_idx].asInt32() orelse return false;
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }
    const iteration_count_i64 = @as(i64, limit) - @as(i64, current_i);
    if (iteration_count_i64 <= 0 or iteration_count_i64 > std.math.maxInt(u32)) return false;

    const accumulator_get = decodeBindingGet(code, exit_branch.true_pc) orelse return false;
    if (!accumulator_get.is_var_ref and accumulator_get.idx == induction_idx) return false;
    const rhs_get = decodeBindingGet(code, accumulator_get.next_pc) orelse return false;
    if (!rhs_get.is_var_ref and rhs_get.idx == induction_idx) return false;
    if (rhs_get.is_var_ref == accumulator_get.is_var_ref and rhs_get.idx == accumulator_get.idx) return false;
    if (rhs_get.next_pc >= code.len or code[rhs_get.next_pc] != op.add) return false;

    var store_pc = rhs_get.next_pc + 1;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const candidate_store = decodeBindingPut(code, store_pc) orelse return false;
        const candidate_drop_pc = candidate_store.operand_pc + candidate_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const accumulator_put = decodeBindingPut(code, store_pc) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

    var tail_pc = if (drop_pc) |drop| drop + 1 else accumulator_put.operand_pc + accumulator_put.consume;
    if (tail_pc < code.len and code[tail_pc] == op.close_loc) {
        if (tail_pc + 3 > code.len) return false;
        const close_idx = readInt(u16, code[tail_pc + 1 ..][0..2]);
        if (close_idx != induction_idx) return false;
        if (varRefCellFromValue(frame.locals[induction_idx]) != null) return false;
        tail_pc += 3;
    }
    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (!tail_get.checked or tail_get.idx != induction_idx) return false;
    tail_pc = tail_get.next_pc;
    if (tail_pc >= code.len or code[tail_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_pc + 1) orelse return false;
    if (!tail_put.checked or tail_put.idx != induction_idx) return false;
    if (induction_idx < function.var_is_const.len and function.var_is_const[induction_idx]) return false;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return false;

    const lhs = (bindingReadableBorrowed(frame, accumulator_get) orelse return false).asInt32() orelse return false;
    const rhs = (bindingReadableBorrowed(frame, rhs_get) orelse return false).asInt32() orelse return false;
    const total_delta = @as(i64, rhs) * iteration_count_i64;
    const final_accumulator = @as(i64, lhs) + total_delta;
    if (final_accumulator < std.math.minInt(i32) or final_accumulator > std.math.maxInt(i32)) return false;

    try storeBindingInt32(ctx, function, global, frame, accumulator_put, @intCast(final_accumulator), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

pub fn tryFuseCheckedLocalInductionInt32AddRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!allow_loop_tail_fusion or ctx.runtime.hasInterruptHandler()) return false;
    if (induction_idx >= frame.locals.len or induction_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(induction_idx)) return false;

    const condition_pc = if (frame.pc >= 3) frame.pc - 3 else return false;
    const pc = frame.pc;
    const code = function.code;
    const limit_operand = immediateInt32Operand(code, pc) orelse return false;
    if (limit_operand.next_pc >= code.len or code[limit_operand.next_pc] != op.lt) return false;
    const exit_branch = decodeFalseBranch(code, limit_operand.next_pc + 1) orelse return false;
    const limit = limit_operand.value;
    const current_i = frame.locals[induction_idx].asInt32() orelse return false;
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }

    const accumulator_get = decodeBindingGet(code, exit_branch.true_pc) orelse return false;
    if (!accumulator_get.is_var_ref and accumulator_get.idx == induction_idx) return false;
    const rhs_get = decodeLocalGet(code, accumulator_get.next_pc) orelse return false;
    if (!rhs_get.checked or rhs_get.idx != induction_idx) return false;
    if (rhs_get.next_pc >= code.len or code[rhs_get.next_pc] != op.add) return false;

    var store_pc = rhs_get.next_pc + 1;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const candidate_store = decodeBindingPut(code, store_pc) orelse return false;
        const candidate_drop_pc = candidate_store.operand_pc + candidate_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const accumulator_put = decodeBindingPut(code, store_pc) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

    var tail_pc = if (drop_pc) |drop| drop + 1 else accumulator_put.operand_pc + accumulator_put.consume;
    if (tail_pc < code.len and code[tail_pc] == op.close_loc) {
        if (tail_pc + 3 > code.len) return false;
        const close_idx = readInt(u16, code[tail_pc + 1 ..][0..2]);
        if (close_idx != induction_idx) return false;
        if (varRefCellFromValue(frame.locals[induction_idx]) != null) return false;
        tail_pc += 3;
    }
    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (!tail_get.checked or tail_get.idx != induction_idx) return false;
    tail_pc = tail_get.next_pc;
    if (tail_pc >= code.len or code[tail_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_pc + 1) orelse return false;
    if (!tail_put.checked or tail_put.idx != induction_idx) return false;
    if (induction_idx < function.var_is_const.len and function.var_is_const[induction_idx]) return false;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return false;

    const accumulator = (bindingReadableBorrowed(frame, accumulator_get) orelse return false).asInt32() orelse return false;
    const delta = intRangeDeltaBounds(current_i, limit);
    const min_accumulator = @as(i128, accumulator) + delta.min;
    const max_accumulator = @as(i128, accumulator) + delta.max;
    if (!safeIntegerI128(min_accumulator) or !safeIntegerI128(max_accumulator)) return false;

    const final_accumulator = @as(i128, accumulator) + delta.total;
    const final_value = value_ops.numberToValue(@floatFromInt(final_accumulator));
    try storeBindingOwnedValue(ctx, function, global, frame, accumulator_put, final_value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

pub fn tryFuseCheckedLocalLatin1AtomAppendRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!allow_loop_tail_fusion or ctx.runtime.hasInterruptHandler()) return false;
    if (induction_idx >= frame.locals.len or induction_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(induction_idx)) return false;

    const condition_pc = if (frame.pc >= 3) frame.pc - 3 else return false;
    const pc = frame.pc;
    const code = function.code;
    const limit_operand = immediateInt32Operand(code, pc) orelse return false;
    if (limit_operand.next_pc >= code.len or code[limit_operand.next_pc] != op.lt) return false;
    const exit_branch = decodeFalseBranch(code, limit_operand.next_pc + 1) orelse return false;
    const limit = limit_operand.value;
    const current_i = frame.locals[induction_idx].asInt32() orelse return false;
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }

    const accumulator_get = decodeBindingGet(code, exit_branch.true_pc) orelse return false;
    if (!accumulator_get.is_var_ref and accumulator_get.idx == induction_idx) return false;
    const suffix_pc = accumulator_get.next_pc;
    if (suffix_pc + 6 > code.len or code[suffix_pc] != op.push_atom_value) return false;
    const suffix_atom = readInt(u32, code[suffix_pc + 1 ..][0..4]);
    const add_pc = suffix_pc + 5;
    if (code[add_pc] != op.add) return false;

    var store_pc = add_pc + 1;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const candidate_store = decodeBindingPut(code, store_pc) orelse return false;
        const candidate_drop_pc = candidate_store.operand_pc + candidate_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const accumulator_put = decodeBindingPut(code, store_pc) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

    var tail_pc = if (drop_pc) |drop| drop + 1 else accumulator_put.operand_pc + accumulator_put.consume;
    if (tail_pc < code.len and code[tail_pc] == op.close_loc) {
        if (tail_pc + 3 > code.len) return false;
        const close_idx = readInt(u16, code[tail_pc + 1 ..][0..2]);
        if (close_idx != induction_idx) return false;
        if (varRefCellFromValue(frame.locals[induction_idx]) != null) return false;
        tail_pc += 3;
    }
    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (!tail_get.checked or tail_get.idx != induction_idx) return false;
    tail_pc = tail_get.next_pc;
    if (tail_pc >= code.len or code[tail_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_pc + 1) orelse return false;
    if (!tail_put.checked or tail_put.idx != induction_idx) return false;
    if (induction_idx < function.var_is_const.len and function.var_is_const[induction_idx]) return false;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return false;

    const accumulator = bindingReadableBorrowed(frame, accumulator_get) orelse return false;
    if (!accumulator.isString()) return false;
    const repeat_count: usize = @intCast(limit - current_i);
    const final_value = try value_ops.latin1AtomRepeatedConcatValue(ctx.runtime, accumulator, suffix_atom, repeat_count) orelse return false;
    try storeBindingOwnedValue(ctx, function, global, frame, accumulator_put, final_value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

pub fn tryFuseCheckedLocalShortBigIntInductionAddRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!allow_loop_tail_fusion or ctx.runtime.hasInterruptHandler()) return false;
    if (induction_idx >= frame.locals.len or induction_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(induction_idx)) return false;

    const condition_pc = if (frame.pc >= 3) frame.pc - 3 else return false;
    const pc = frame.pc;
    const code = function.code;
    const limit_operand = immediateShortBigIntI32Operand(code, pc) orelse return false;
    if (limit_operand.next_pc >= code.len or code[limit_operand.next_pc] != op.lt) return false;
    const exit_branch = decodeFalseBranch(code, limit_operand.next_pc + 1) orelse return false;
    const limit = limit_operand.value;
    const current_i = frame.locals[induction_idx].asShortBigInt() orelse return false;
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }

    const accumulator_get = decodeBindingGet(code, exit_branch.true_pc) orelse return false;
    if (!accumulator_get.is_var_ref and accumulator_get.idx == induction_idx) return false;
    const rhs_get = decodeLocalGet(code, accumulator_get.next_pc) orelse return false;
    if (!rhs_get.checked or rhs_get.idx != induction_idx) return false;
    if (rhs_get.next_pc >= code.len or code[rhs_get.next_pc] != op.add) return false;

    var store_pc = rhs_get.next_pc + 1;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const candidate_store = decodeBindingPut(code, store_pc) orelse return false;
        const candidate_drop_pc = candidate_store.operand_pc + candidate_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const accumulator_put = decodeBindingPut(code, store_pc) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

    var tail_pc = if (drop_pc) |drop| drop + 1 else accumulator_put.operand_pc + accumulator_put.consume;
    if (tail_pc < code.len and code[tail_pc] == op.close_loc) {
        if (tail_pc + 3 > code.len) return false;
        const close_idx = readInt(u16, code[tail_pc + 1 ..][0..2]);
        if (close_idx != induction_idx) return false;
        if (varRefCellFromValue(frame.locals[induction_idx]) != null) return false;
        tail_pc += 3;
    }
    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (!tail_get.checked or tail_get.idx != induction_idx) return false;
    tail_pc = tail_get.next_pc;
    if (tail_pc >= code.len or code[tail_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_pc + 1) orelse return false;
    if (!tail_put.checked or tail_put.idx != induction_idx) return false;
    if (induction_idx < function.var_is_const.len and function.var_is_const[induction_idx]) return false;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return false;

    const accumulator = (bindingReadableBorrowed(frame, accumulator_get) orelse return false).asShortBigInt() orelse return false;
    const delta = intRangeDeltaBoundsWide(@as(i128, current_i), @as(i128, limit));
    const min_accumulator = @as(i128, accumulator) + delta.min;
    const max_accumulator = @as(i128, accumulator) + delta.max;
    if (!fitsI64(min_accumulator) or !fitsI64(max_accumulator)) return false;

    const final_accumulator = @as(i128, accumulator) + delta.total;
    if (!fitsI64(final_accumulator)) return false;
    try storeBindingOwnedValue(ctx, function, global, frame, accumulator_put, core.JSValue.shortBigInt(@intCast(final_accumulator)), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.shortBigInt(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

pub fn tryFuseCheckedLocalInvariantInt32LoadAddRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!allow_loop_tail_fusion or ctx.runtime.hasInterruptHandler()) return false;
    if (induction_idx >= frame.locals.len or induction_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(induction_idx)) return false;

    const condition_pc = if (frame.pc >= 3) frame.pc - 3 else return false;
    const pc = frame.pc;
    const code = function.code;
    const limit_operand = immediateInt32Operand(code, pc) orelse return false;
    if (limit_operand.next_pc >= code.len or code[limit_operand.next_pc] != op.lt) return false;
    const exit_branch = decodeFalseBranch(code, limit_operand.next_pc + 1) orelse return false;
    const limit = limit_operand.value;
    const current_i = frame.locals[induction_idx].asInt32() orelse return false;
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }
    const iteration_count = @as(i128, limit) - @as(i128, current_i);
    if (iteration_count <= 0) return false;

    const accumulator_get = decodeBindingGet(code, exit_branch.true_pc) orelse return false;
    const receiver_get = decodeBindingGet(code, accumulator_get.next_pc) orelse return false;
    const receiver = bindingReadableBorrowed(frame, receiver_get) orelse return false;
    const loaded = invariantInt32LoadValue(ctx.runtime, receiver, code, receiver_get.next_pc) orelse return false;
    if (loaded.next_pc >= code.len or code[loaded.next_pc] != op.add) return false;

    var store_pc = loaded.next_pc + 1;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const candidate_store = decodeBindingPut(code, store_pc) orelse return false;
        const candidate_drop_pc = candidate_store.operand_pc + candidate_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const accumulator_put = decodeBindingPut(code, store_pc) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

    var tail_pc = if (drop_pc) |drop| drop + 1 else accumulator_put.operand_pc + accumulator_put.consume;
    if (tail_pc < code.len and code[tail_pc] == op.close_loc) {
        if (tail_pc + 3 > code.len) return false;
        const close_idx = readInt(u16, code[tail_pc + 1 ..][0..2]);
        if (close_idx != induction_idx) return false;
        if (varRefCellFromValue(frame.locals[induction_idx]) != null) return false;
        tail_pc += 3;
    }
    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (!tail_get.checked or tail_get.idx != induction_idx) return false;
    tail_pc = tail_get.next_pc;
    if (tail_pc >= code.len or code[tail_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_pc + 1) orelse return false;
    if (!tail_put.checked or tail_put.idx != induction_idx) return false;
    if (induction_idx < function.var_is_const.len and function.var_is_const[induction_idx]) return false;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return false;

    const accumulator = (bindingReadableBorrowed(frame, accumulator_get) orelse return false).asInt32() orelse return false;
    const total_delta = @as(i128, loaded.value) * iteration_count;
    const final_accumulator = @as(i128, accumulator) + total_delta;
    if (final_accumulator < std.math.minInt(i32) or final_accumulator > std.math.maxInt(i32)) return false;

    try storeBindingInt32(ctx, function, global, frame, accumulator_put, @intCast(final_accumulator), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

pub fn tryFuseCheckedLocalDenseArrayModFieldInt32AddRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!allow_loop_tail_fusion or ctx.runtime.hasInterruptHandler()) return false;
    if (induction_idx >= frame.locals.len or induction_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(induction_idx)) return false;

    const condition_pc = if (frame.pc >= 3) frame.pc - 3 else return false;
    const pc = frame.pc;
    const code = function.code;
    const limit_operand = immediateInt32Operand(code, pc) orelse return false;
    if (limit_operand.next_pc >= code.len or code[limit_operand.next_pc] != op.lt) return false;
    const exit_branch = decodeFalseBranch(code, limit_operand.next_pc + 1) orelse return false;
    const limit = limit_operand.value;
    const current_i = frame.locals[induction_idx].asInt32() orelse return false;
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }
    if (current_i < 0) return false;

    const accumulator_get = decodeBindingGet(code, exit_branch.true_pc) orelse return false;
    const array_get = decodeBindingGet(code, accumulator_get.next_pc) orelse return false;
    const induction_get = decodeLocalGet(code, array_get.next_pc) orelse return false;
    if (!induction_get.checked or induction_get.idx != induction_idx) return false;
    const modulus = smallPushOpcodeIndex(code[induction_get.next_pc]) orelse return false;
    if (modulus == 0) return false;
    const mod_pc = induction_get.next_pc + 1;
    if (mod_pc + 7 > code.len or code[mod_pc] != op.mod or code[mod_pc + 1] != op.get_array_el or code[mod_pc + 2] != op.get_field) return false;
    const field_atom = readInt(u32, code[mod_pc + 3 ..][0..4]);
    const add_pc = mod_pc + 7;
    if (add_pc >= code.len or code[add_pc] != op.add) return false;

    var store_pc = add_pc + 1;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const candidate_store = decodeBindingPut(code, store_pc) orelse return false;
        const candidate_drop_pc = candidate_store.operand_pc + candidate_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const accumulator_put = decodeBindingPut(code, store_pc) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

    var tail_pc = if (drop_pc) |drop| drop + 1 else accumulator_put.operand_pc + accumulator_put.consume;
    if (tail_pc < code.len and code[tail_pc] == op.close_loc) {
        if (tail_pc + 3 > code.len) return false;
        const close_idx = readInt(u16, code[tail_pc + 1 ..][0..2]);
        if (close_idx != induction_idx) return false;
        if (varRefCellFromValue(frame.locals[induction_idx]) != null) return false;
        tail_pc += 3;
    }
    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (!tail_get.checked or tail_get.idx != induction_idx) return false;
    tail_pc = tail_get.next_pc;
    if (tail_pc >= code.len or code[tail_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_pc + 1) orelse return false;
    if (!tail_put.checked or tail_put.idx != induction_idx) return false;
    if (induction_idx < function.var_is_const.len and function.var_is_const[induction_idx]) return false;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return false;

    const array_value = bindingReadableBorrowed(frame, array_get) orelse return false;
    const increments = denseArrayModFieldInt32Increments(ctx.runtime, array_value, field_atom, modulus) orelse return false;
    const accumulator = (bindingReadableBorrowed(frame, accumulator_get) orelse return false).asInt32() orelse return false;
    const delta = periodicNonNegativeDelta(current_i, limit, increments) orelse return false;
    const final_accumulator = @as(i128, accumulator) + delta;
    if (!safeIntegerI128(final_accumulator)) return false;

    const final_value = value_ops.numberToValue(@floatFromInt(final_accumulator));
    try storeBindingOwnedValue(ctx, function, global, frame, accumulator_put, final_value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

pub fn tryFuseCheckedLocalDenseArrayLengthIndexedInt32SumRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const condition_pc = if (frame.pc >= 3) frame.pc - 3 else return false;
    return try tryFuseLocalDenseArrayLengthIndexedInt32SumRangeAt(ctx, function, global, frame, induction_idx, condition_pc, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
}

fn tryFuseShortLocalDenseArrayLengthIndexedInt32SumRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const condition_pc = if (frame.pc >= 1) frame.pc - 1 else return false;
    return try tryFuseLocalDenseArrayLengthIndexedInt32SumRangeAt(ctx, function, global, frame, induction_idx, condition_pc, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
}

fn tryFuseLocalDenseArrayLengthIndexedInt32SumRangeAt(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    condition_pc: usize,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!allow_loop_tail_fusion or ctx.runtime.hasInterruptHandler()) return false;
    if (induction_idx >= frame.locals.len or induction_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(induction_idx)) return false;

    const pc = frame.pc;
    const code = function.code;
    const bound_array_get = decodeBindingGet(code, pc) orelse return false;
    if (!bound_array_get.is_var_ref and bound_array_get.idx == induction_idx) return false;
    if (bound_array_get.next_pc + 2 > code.len or code[bound_array_get.next_pc] != op.get_length or code[bound_array_get.next_pc + 1] != op.lt) return false;
    const exit_branch = decodeFalseBranch(code, bound_array_get.next_pc + 2) orelse return false;

    const current_i = frame.locals[induction_idx].asInt32() orelse return false;
    if (current_i < 0) return false;
    const array_value = bindingReadableBorrowed(frame, bound_array_get) orelse return false;
    const array_object = objectFromValue(array_value) orelse return false;
    if (array_object.proxyTarget() != null or array_object.exotic != null) return false;
    if (!array_object.is_array or array_object.arrayElementStorageMode() != .dense) return false;
    if (array_object.length > @as(u32, @intCast(std.math.maxInt(i32)))) return false;
    const limit: i32 = @intCast(array_object.length);
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }

    const accumulator_get = decodeBindingGet(code, exit_branch.true_pc) orelse return false;
    if (!accumulator_get.is_var_ref and accumulator_get.idx == induction_idx) return false;
    if (sameBinding(accumulator_get, bound_array_get)) return false;
    const body_array_get = decodeBindingGet(code, accumulator_get.next_pc) orelse return false;
    if (!sameBinding(body_array_get, bound_array_get)) return false;
    const index_get = decodeLocalGet(code, body_array_get.next_pc) orelse return false;
    if (index_get.idx != induction_idx) return false;
    if (index_get.next_pc + 2 > code.len or code[index_get.next_pc] != op.get_array_el or code[index_get.next_pc + 1] != op.add) return false;

    var store_pc = index_get.next_pc + 2;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const candidate_store = decodeBindingPut(code, store_pc) orelse return false;
        const candidate_drop_pc = candidate_store.operand_pc + candidate_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const accumulator_put = decodeBindingPut(code, store_pc) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

    var tail_pc = if (drop_pc) |drop| drop + 1 else accumulator_put.operand_pc + accumulator_put.consume;
    if (tail_pc < code.len and code[tail_pc] == op.close_loc) {
        if (tail_pc + 3 > code.len) return false;
        const close_idx = readInt(u16, code[tail_pc + 1 ..][0..2]);
        if (close_idx != induction_idx) return false;
        if (varRefCellFromValue(frame.locals[induction_idx]) != null) return false;
        tail_pc += 3;
    }
    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (tail_get.idx != induction_idx) return false;
    tail_pc = tail_get.next_pc;
    if (tail_pc >= code.len or code[tail_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_pc + 1) orelse return false;
    if (tail_put.idx != induction_idx) return false;
    if (induction_idx < function.var_is_const.len and function.var_is_const[induction_idx]) return false;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return false;

    const accumulator = (bindingReadableBorrowed(frame, accumulator_get) orelse return false).asInt32() orelse return false;
    const delta = denseArrayInt32RangeDelta(array_object, @intCast(current_i), @intCast(limit)) orelse return false;
    const min_accumulator = @as(i128, accumulator) + delta.min;
    const max_accumulator = @as(i128, accumulator) + delta.max;
    if (!safeIntegerI128(min_accumulator) or !safeIntegerI128(max_accumulator)) return false;
    const final_accumulator = @as(i128, accumulator) + delta.total;

    const final_value = value_ops.numberToValue(@floatFromInt(final_accumulator));
    try storeBindingOwnedValue(ctx, function, global, frame, accumulator_put, final_value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

pub fn tryFuseCheckedLocalMapSetLatin1PrefixInt32Range(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    comptime setSlotValue: anytype,
) !bool {
    _ = global;
    if (!allow_loop_tail_fusion or ctx.runtime.hasInterruptHandler()) return false;
    if (induction_idx >= frame.locals.len or induction_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(induction_idx)) return false;

    const condition_pc = if (frame.pc >= 3) frame.pc - 3 else return false;
    const pc = frame.pc;
    const code = function.code;
    if (pc + 7 > code.len or code[pc] != op.push_i16 or code[pc + 3] != op.lt) return false;
    const limit = @as(i32, readInt(i16, code[pc + 1 ..][0..2]));
    const exit_branch = decodeFalseBranch(code, pc + 4) orelse return false;
    const current_i = frame.locals[induction_idx].asInt32() orelse return false;
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }
    if (current_i < 0) return false;

    const receiver_get = decodeBindingGet(code, exit_branch.true_pc) orelse return false;
    const receiver = bindingReadableBorrowed(frame, receiver_get) orelse return false;
    const map_object = objectFromValue(receiver) orelse return false;
    if (map_object.class_id != core.class.ids.map) return false;
    if (receiver_get.next_pc + 8 > code.len or code[receiver_get.next_pc] != op.get_field2) return false;
    const method_atom = readInt(u32, code[receiver_get.next_pc + 1 ..][0..4]);
    if (!fastCollectionPrototypeMethodIsDefault(receiver, method_atom, @intFromEnum(builtins.collection.PrototypeMethod.set))) return false;

    const key = decodeLatin1PrefixIntLocalKey(ctx, code, receiver_get.next_pc + 5, induction_idx) orelse return false;
    const value_get = decodeLocalGet(code, key.next_pc) orelse return false;
    if (!value_get.checked or value_get.idx != induction_idx) return false;
    if (value_get.next_pc + 4 > code.len or code[value_get.next_pc] != op.call_method or readInt(u16, code[value_get.next_pc + 1 ..][0..2]) != 2) return false;
    var tail_pc = value_get.next_pc + 3;
    if (tail_pc >= code.len or code[tail_pc] != op.drop) return false;
    tail_pc += 1;

    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (!tail_get.checked or tail_get.idx != induction_idx) return false;
    if (tail_get.next_pc >= code.len or code[tail_get.next_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_get.next_pc + 1) orelse return false;
    if (!tail_put.checked or tail_put.idx != induction_idx) return false;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return false;

    try builtins.collection.mapSetLatin1PrefixInt32Range(ctx.runtime, map_object, key.prefix, current_i, limit);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    frame.pc = exit_branch.false_pc;
    return true;
}

pub fn tryFuseCheckedLocalMapGetLatin1PrefixInt32SumRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!allow_loop_tail_fusion or ctx.runtime.hasInterruptHandler()) return false;
    if (induction_idx >= frame.locals.len or induction_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(induction_idx)) return false;

    const condition_pc = if (frame.pc >= 3) frame.pc - 3 else return false;
    const pc = frame.pc;
    const code = function.code;
    if (pc + 7 > code.len or code[pc] != op.push_i16 or code[pc + 3] != op.lt) return false;
    const limit = @as(i32, readInt(i16, code[pc + 1 ..][0..2]));
    const exit_branch = decodeFalseBranch(code, pc + 4) orelse return false;
    const current_i = frame.locals[induction_idx].asInt32() orelse return false;
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }
    if (current_i < 0) return false;

    const accumulator_get = decodeBindingGet(code, exit_branch.true_pc) orelse return false;
    const receiver_get = decodeBindingGet(code, accumulator_get.next_pc) orelse return false;
    const receiver = bindingReadableBorrowed(frame, receiver_get) orelse return false;
    const map_object = objectFromValue(receiver) orelse return false;
    if (map_object.class_id != core.class.ids.map) return false;
    if (receiver_get.next_pc + 8 > code.len or code[receiver_get.next_pc] != op.get_field2) return false;
    const method_atom = readInt(u32, code[receiver_get.next_pc + 1 ..][0..4]);
    if (!fastCollectionPrototypeMethodIsDefault(receiver, method_atom, @intFromEnum(builtins.collection.PrototypeMethod.get))) return false;

    const key = decodeLatin1PrefixIntLocalKey(ctx, code, receiver_get.next_pc + 5, induction_idx) orelse return false;
    if (key.next_pc + 4 > code.len or code[key.next_pc] != op.call_method or readInt(u16, code[key.next_pc + 1 ..][0..2]) != 1) return false;
    const add_pc = key.next_pc + 3;
    if (add_pc >= code.len or code[add_pc] != op.add) return false;
    var store_pc = add_pc + 1;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const candidate_store = decodeBindingPut(code, store_pc) orelse return false;
        const candidate_drop_pc = candidate_store.operand_pc + candidate_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const accumulator_put = decodeBindingPut(code, store_pc) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

    const tail_pc = if (drop_pc) |drop| drop + 1 else accumulator_put.operand_pc + accumulator_put.consume;
    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (!tail_get.checked or tail_get.idx != induction_idx) return false;
    if (tail_get.next_pc >= code.len or code[tail_get.next_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_get.next_pc + 1) orelse return false;
    if (!tail_put.checked or tail_put.idx != induction_idx) return false;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return false;

    var total = @as(i64, (bindingReadableBorrowed(frame, accumulator_get) orelse return false).asInt32() orelse return false);
    var index = current_i;
    while (index < limit) : (index += 1) {
        const value = builtins.collection.mapGetLatin1PrefixIntValue(map_object, key.prefix, index) orelse return false;
        defer value.free(ctx.runtime);
        const int_value = value.asInt32() orelse return false;
        total += int_value;
        if (total < std.math.minInt(i32) or total > std.math.maxInt(i32)) return false;
    }

    try storeBindingInt32(ctx, function, global, frame, accumulator_put, @intCast(total), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

pub fn tryFuseCheckedLocalArrayMapSimpleCallbackRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!allow_loop_tail_fusion or ctx.runtime.hasInterruptHandler()) return false;
    if (induction_idx >= frame.locals.len or induction_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(induction_idx)) return false;

    const condition_pc = if (frame.pc >= 3) frame.pc - 3 else return false;
    const pc = frame.pc;
    const code = function.code;
    if (pc + 7 > code.len or code[pc] != op.push_i16 or code[pc + 3] != op.lt) return false;
    const limit = @as(i32, readInt(i16, code[pc + 1 ..][0..2]));
    const exit_branch = decodeFalseBranch(code, pc + 4) orelse return false;
    const current_i = frame.locals[induction_idx].asInt32() orelse return false;
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }

    const receiver_get = decodeBindingGet(code, exit_branch.true_pc) orelse return false;
    const receiver = bindingReadableBorrowed(frame, receiver_get) orelse return false;
    if (objectFromValue(receiver)) |array_object| {
        if (!array_object.is_array) return false;
    } else return false;
    if (receiver_get.next_pc + 7 > code.len or code[receiver_get.next_pc] != op.get_field2) return false;
    const method_atom = readInt(u32, code[receiver_get.next_pc + 1 ..][0..4]);
    if (!fastArrayPrototypeMethodIsDefault(receiver, method_atom, @intFromEnum(builtins.array.PrototypeMethod.map))) return false;

    var closure_pc = receiver_get.next_pc + 5;
    const callback_index: u32 = switch (code[closure_pc]) {
        op.fclosure8 => index: {
            if (closure_pc + 2 > code.len) return false;
            const index_value: u32 = code[closure_pc + 1];
            closure_pc += 2;
            break :index index_value;
        },
        op.fclosure => index: {
            if (closure_pc + 5 > code.len) return false;
            const index_value = readInt(u32, code[closure_pc + 1 ..][0..4]);
            closure_pc += 5;
            break :index index_value;
        },
        else => return false,
    };
    if (closure_pc + 4 > code.len or code[closure_pc] != op.call_method or readInt(u16, code[closure_pc + 1 ..][0..2]) != 1) return false;
    const callback = function.constants.get(callback_index) orelse return error.InvalidBytecode;
    defer callback.free(ctx.runtime);
    if (simpleNumericArg0ConstCallable(callback) == null) return false;

    var store_pc = closure_pc + 3;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const candidate_store = decodeBindingPut(code, store_pc) orelse return false;
        const candidate_drop_pc = candidate_store.operand_pc + candidate_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const result_put = decodeBindingPut(code, store_pc) orelse return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, result_put)) return false;

    var tail_pc = if (drop_pc) |drop| drop + 1 else result_put.operand_pc + result_put.consume;
    if (tail_pc < code.len and code[tail_pc] == op.close_loc) {
        if (tail_pc + 3 > code.len) return false;
        const close_idx = readInt(u16, code[tail_pc + 1 ..][0..2]);
        if (close_idx != induction_idx) return false;
        if (varRefCellFromValue(frame.locals[induction_idx]) != null) return false;
        tail_pc += 3;
    }
    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (!tail_get.checked or tail_get.idx != induction_idx) return false;
    if (tail_get.next_pc >= code.len or code[tail_get.next_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_get.next_pc + 1) orelse return false;
    if (!tail_put.checked or tail_put.idx != induction_idx) return false;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return false;

    const mapped = try shared_vm.qjsArrayMapSimpleNumericArg0DefaultSpeciesFastCall(ctx.runtime, global, receiver, callback) orelse return false;
    errdefer mapped.free(ctx.runtime);
    try storeBindingOwnedValue(ctx, function, global, frame, result_put, mapped, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

pub fn tryFuseLocalInt32GlobalInt32AddRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!allow_loop_tail_fusion or ctx.runtime.hasInterruptHandler()) return false;
    if (induction_idx >= frame.locals.len or induction_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(induction_idx)) return false;
    if (eval_local_names.len != 0 or eval_var_ref_names.len != 0) return false;
    if (frame.eval_local_names.len != 0 or frame.eval_var_ref_names.len != 0) return false;
    if (!eval_with_object.isUndefined() or !frame.current_function.isUndefined()) return false;

    const pc = frame.pc;
    const code = function.code;
    if (pc < 3 or pc + 8 > code.len) return false;
    if (code[pc] != op.push_i32 or code[pc + 5] != op.lt or code[pc + 6] != op.if_false8) return false;
    const limit = readInt(i32, code[pc + 1 ..][0..4]);
    const branch_operand_pc = pc + 7;
    const branch_diff: i8 = @bitCast(code[branch_operand_pc]);
    const exit_pc_i64 = @as(i64, @intCast(branch_operand_pc)) + @as(i64, branch_diff);
    if (exit_pc_i64 < 0) return false;
    const exit_pc: usize = @intCast(exit_pc_i64);

    const current_i = frame.locals[induction_idx].asInt32() orelse return false;
    if (current_i >= limit) {
        frame.pc = exit_pc;
        return true;
    }
    const iteration_count_i64 = @as(i64, limit) - @as(i64, current_i);
    if (iteration_count_i64 <= 0 or iteration_count_i64 > std.math.maxInt(u32)) return false;

    const body_pc = pc + 8;
    const accumulator_get = decodeLocalGet(code, body_pc) orelse return false;
    if (!accumulator_get.checked) return false;
    const accumulator_idx = accumulator_get.idx;
    if (accumulator_idx >= frame.locals.len or accumulator_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(accumulator_idx)) return false;
    if (accumulator_idx < function.var_is_const.len and function.var_is_const[accumulator_idx]) return false;

    const global_pc = accumulator_get.next_pc;
    if (global_pc + 6 > code.len) return false;
    const global_read_op = code[global_pc];
    if (global_read_op != op.get_var and global_read_op != op.get_var_undef) return false;
    if (code[global_pc + 5] != op.add) return false;
    const atom_id = readInt(u32, code[global_pc + 1 ..][0..4]);
    if (ctx.lexicals != null) {
        if (globalLexicalValue(ctx, atom_id)) |lexical_value| {
            lexical_value.free(ctx.runtime);
            return false;
        }
    }
    const global_data: BorrowedGlobalDataLookup = cached: {
        if (cachedOwnDataPropertyLookupForObject(function, global_pc, ctx.runtime, global, atom_id)) |own_data| {
            break :cached .{ .index = own_data.index, .value = own_data.value };
        }
        if (declaredGlobalVarDataBorrowedLookup(global, function, atom_id)) |declared| {
            installOwnDataIcForObject(function, global_pc, ctx.runtime, global, atom_id, declared.index);
            break :cached declared;
        }
        const own_data = globalOwnDataPropertyBorrowedLookup(global, atom_id) orelse return false;
        installOwnDataIcForObject(function, global_pc, ctx.runtime, global, atom_id, own_data.index);
        break :cached own_data;
    };
    const rhs = global_data.value.asInt32() orelse return false;
    const lhs = frame.locals[accumulator_idx].asInt32() orelse return false;
    const total_delta = @as(i64, rhs) * iteration_count_i64;
    const final_accumulator = @as(i64, lhs) + total_delta;
    if (final_accumulator < std.math.minInt(i32) or final_accumulator > std.math.maxInt(i32)) return false;

    var store_pc = global_pc + 6;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const decoded_store = decodeLocalPut(code, store_pc) orelse return false;
        const candidate_drop_pc = decoded_store.operand_pc + decoded_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const accumulator_store = decodeLocalPut(code, store_pc) orelse return false;
    if (!accumulator_store.checked or accumulator_store.idx != accumulator_idx) return false;
    var tail_pc = if (drop_pc) |drop| drop + 1 else accumulator_store.operand_pc + accumulator_store.consume;

    const induction_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (!induction_get.checked or induction_get.idx != induction_idx) return false;
    tail_pc = induction_get.next_pc;
    if (tail_pc >= code.len or code[tail_pc] != op.post_inc) return false;
    tail_pc += 1;
    const induction_store = decodeLocalPut(code, tail_pc) orelse return false;
    if (!induction_store.checked or induction_store.idx != induction_idx) return false;
    if (induction_idx < function.var_is_const.len and function.var_is_const[induction_idx]) return false;
    tail_pc = induction_store.operand_pc + induction_store.consume;
    if (tail_pc >= code.len or code[tail_pc] != op.drop) return false;
    tail_pc += 1;
    if (tail_pc + 2 > code.len or code[tail_pc] != op.goto8) return false;
    const goto_operand_pc = tail_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const target_pc_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (target_pc_i64 < 0 or @as(usize, @intCast(target_pc_i64)) != pc - 3) return false;

    try setSlotValue(ctx, &frame.locals[accumulator_idx], core.JSValue.int32(@intCast(final_accumulator)));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, accumulator_idx, sync_global_lexical_locals);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_pc;
    return true;
}

pub fn tryFuseCheckedLocalFieldInt32Add(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    local_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const pc = frame.pc;
    const code = function.code;
    if (pc + 12 > code.len) return false;
    if (code[pc] != op.get_loc_check) return false;
    const object_idx = readInt(u16, code[pc + 1 ..][0..2]);
    if (code[pc + 3] != op.get_field) return false;
    if (code[pc + 8] != op.add) return false;
    var store_pc = pc + 9;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const decoded_store = decodeLocalPut(code, store_pc) orelse return false;
        const candidate_drop_pc = decoded_store.operand_pc + decoded_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const store = decodeLocalPut(code, store_pc) orelse return false;
    if (!store.checked or store.idx != local_idx) return false;
    if (local_idx >= frame.locals.len or local_idx >= frame.locals_uninit.len) return false;
    if (object_idx >= frame.locals.len or object_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(local_idx) or frame.localIsUninitialized(object_idx)) return false;
    if (local_idx < function.var_is_const.len and function.var_is_const[local_idx]) return false;
    const object_slot = frame.locals[object_idx];
    if (varRefCellFromValue(object_slot) != null) return false;

    const lhs = frame.locals[local_idx].asInt32() orelse return false;
    const atom_id = readInt(u32, code[pc + 4 ..][0..4]);
    const value = fastOrdinaryDataPropertyBorrowedValue(ctx.runtime, object_slot, atom_id) orelse return false;
    const rhs = value.asInt32() orelse return false;

    try setSlotValue(ctx, &frame.locals[local_idx], fastInt32Add(lhs, rhs));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, local_idx, sync_global_lexical_locals);
    frame.pc = if (drop_pc) |drop| drop + 1 else store.operand_pc + store.consume;
    _ = try tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    return true;
}

pub fn tryFuseCheckedLocalCheckedLocalNumericAdd(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    local_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const pc = frame.pc;
    const code = function.code;
    if (pc + 5 > code.len) return false;
    if (code[pc] != op.get_loc_check) return false;
    const rhs_idx = readInt(u16, code[pc + 1 ..][0..2]);
    if (code[pc + 3] != op.add) return false;
    var store_pc = pc + 4;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const decoded_store = decodeLocalPut(code, store_pc) orelse return false;
        const candidate_drop_pc = decoded_store.operand_pc + decoded_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const store = decodeLocalPut(code, store_pc) orelse return false;
    if (!store.checked or store.idx != local_idx) return false;
    if (local_idx >= frame.locals.len or local_idx >= frame.locals_uninit.len) return false;
    if (rhs_idx >= frame.locals.len or rhs_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(local_idx) or frame.localIsUninitialized(rhs_idx)) return false;
    if (local_idx < function.var_is_const.len and function.var_is_const[local_idx]) return false;

    const lhs = frame.locals[local_idx];
    const rhs = frame.locals[rhs_idx];
    const updated = blk: {
        if (lhs.asInt32()) |lhs_int| {
            if (rhs.asInt32()) |rhs_int| break :blk fastInt32Add(lhs_int, rhs_int);
        }
        if (lhs.asShortBigInt()) |lhs_bigint| {
            if (rhs.asShortBigInt()) |rhs_bigint| {
                if (value_ops.shortBigIntBinary(op.add, lhs_bigint, rhs_bigint)) |fast| break :blk fast;
            }
        }
        if (!lhs.isNumber() or !rhs.isNumber()) return false;
        break :blk try value_ops.binary(ctx.runtime, op.add, lhs, rhs);
    };
    errdefer updated.free(ctx.runtime);
    try setSlotValue(ctx, &frame.locals[local_idx], updated);
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, local_idx, sync_global_lexical_locals);
    frame.pc = if (drop_pc) |drop| drop + 1 else store.operand_pc + store.consume;
    _ = try tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    return true;
}

pub fn tryFuseCheckedLocalDenseArrayConstInt32Add(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    local_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const pc = frame.pc;
    const code = function.code;
    if (pc + 9 > code.len) return false;
    if (code[pc] != op.get_loc_check) return false;
    const array_idx = readInt(u16, code[pc + 1 ..][0..2]);
    const index = smallPushOpcodeIndex(code[pc + 3]) orelse return false;
    if (code[pc + 4] != op.get_array_el or code[pc + 5] != op.add) return false;
    var store_pc = pc + 6;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const decoded_store = decodeLocalPut(code, store_pc) orelse return false;
        const candidate_drop_pc = decoded_store.operand_pc + decoded_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const store = decodeLocalPut(code, store_pc) orelse return false;
    if (!store.checked or store.idx != local_idx) return false;
    if (local_idx >= frame.locals.len or local_idx >= frame.locals_uninit.len) return false;
    if (array_idx >= frame.locals.len or array_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(local_idx) or frame.localIsUninitialized(array_idx)) return false;
    if (local_idx < function.var_is_const.len and function.var_is_const[local_idx]) return false;

    const array_slot = frame.locals[array_idx];
    if (varRefCellFromValue(array_slot) != null) return false;
    const array_object = objectFromValue(array_slot) orelse return false;
    if (array_object.proxyTarget() != null or array_object.exotic != null) return false;
    if (!array_object.is_array or array_object.arrayElementStorageMode() != .dense) return false;
    if (index >= @as(usize, @intCast(array_object.length))) return false;
    const elements = array_object.arrayElements();
    if (index >= elements.len) return false;
    const element = elements[index] orelse return false;

    const lhs = frame.locals[local_idx].asInt32() orelse return false;
    const rhs = element.asInt32() orelse return false;
    try setSlotValue(ctx, &frame.locals[local_idx], fastInt32Add(lhs, rhs));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, local_idx, sync_global_lexical_locals);
    frame.pc = if (drop_pc) |drop| drop + 1 else store.operand_pc + store.consume;
    _ = try tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    return true;
}

pub fn tryFuseCheckedLocalDenseArrayIndexedInt32Add(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    local_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const pc = frame.pc;
    const code = function.code;
    if (pc + 9 > code.len) return false;
    if (code[pc] != op.get_loc_check) return false;
    const array_idx = readInt(u16, code[pc + 1 ..][0..2]);
    if (code[pc + 3] != op.get_loc_check) return false;
    const index_idx = readInt(u16, code[pc + 4 ..][0..2]);
    if (code[pc + 6] != op.get_array_el or code[pc + 7] != op.add) return false;
    var store_pc = pc + 8;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const decoded_store = decodeLocalPut(code, store_pc) orelse return false;
        const candidate_drop_pc = decoded_store.operand_pc + decoded_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const store = decodeLocalPut(code, store_pc) orelse return false;
    if (store.idx != local_idx) return false;

    if (local_idx >= frame.locals.len or local_idx >= frame.locals_uninit.len) return false;
    if (array_idx >= frame.locals.len or array_idx >= frame.locals_uninit.len) return false;
    if (index_idx >= frame.locals.len or index_idx >= frame.locals_uninit.len) return false;
    if (store.idx >= frame.locals.len or store.idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(local_idx) or frame.localIsUninitialized(array_idx) or frame.localIsUninitialized(index_idx)) return false;
    if (store.checked and store.idx < function.var_is_const.len and function.var_is_const[store.idx]) return false;

    const array_slot = slotValueBorrowed(frame.locals[array_idx]);
    if (array_slot.isUninitialized()) return false;
    const array_object = objectFromValue(array_slot) orelse return false;
    if (array_object.proxyTarget() != null or array_object.exotic != null) return false;
    if (!array_object.is_array or array_object.arrayElementStorageMode() != .dense) return false;

    const index_value = slotValueBorrowed(frame.locals[index_idx]);
    const index_i32 = index_value.asInt32() orelse return false;
    if (index_i32 < 0) return false;
    const element_index: usize = @intCast(index_i32);
    const elements = array_object.arrayElements();
    if (element_index >= elements.len) return false;
    const rhs = elements[element_index] orelse return false;

    const lhs = slotValueBorrowed(frame.locals[local_idx]);
    if (!lhs.isNumber() or !rhs.isNumber()) return false;
    const updated = try simpleNumericBinary(ctx.runtime, op.add, lhs, rhs);
    errdefer updated.free(ctx.runtime);
    try setSlotValue(ctx, &frame.locals[store.idx], updated);
    if (!store.checked and store.idx < function.var_is_lexical.len and function.var_is_lexical[store.idx]) {
        frame.clearLocalUninitialized(store.idx);
    }
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, store.idx, sync_global_lexical_locals);
    frame.pc = if (drop_pc) |drop| drop + 1 else store.operand_pc + store.consume;
    _ = try tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    return true;
}

pub fn tryFuseCheckedLocalDenseArrayIndexedAppend(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    array_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const pc = frame.pc;
    const code = function.code;
    const index_get = decodeLocalGet(code, pc) orelse return false;
    if (!index_get.checked) return false;
    const value_get = decodeLocalGet(code, index_get.next_pc) orelse return false;
    if (!value_get.checked) return false;
    const index_idx = index_get.idx;
    const value_idx = value_get.idx;

    if (array_idx >= frame.locals.len or array_idx >= frame.locals_uninit.len) return false;
    if (index_idx >= frame.locals.len or index_idx >= frame.locals_uninit.len) return false;
    if (value_idx >= frame.locals.len or value_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(array_idx) or frame.localIsUninitialized(index_idx) or frame.localIsUninitialized(value_idx)) return false;

    const array_slot = slotValueBorrowed(frame.locals[array_idx]);
    if (array_slot.isUninitialized()) return false;
    const array_object = objectFromValue(array_slot) orelse return false;

    const index_value = slotValueBorrowed(frame.locals[index_idx]);
    const index_i32 = index_value.asInt32() orelse return false;
    if (index_i32 < 0) return false;
    const index: u32 = @intCast(index_i32);
    if (index > core.atom.max_int_atom) return false;

    const append_value = denseArrayAppendValueFromBytecode(frame, function, value_idx, value_get.next_pc) orelse return false;
    if (append_value.next_pc >= code.len or code[append_value.next_pc] != op.put_array_el) return false;
    if (!try array_object.appendDenseArrayIndex(ctx.runtime, index, core.atom.atomFromUInt32(index), append_value.value)) return false;

    frame.pc = append_value.next_pc + 1;
    _ = try tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    return true;
}

fn tryFuseLocal0Local1DenseArrayIndexedAppend(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !bool {
    const code = function.code;
    const value_get = decodeLocalGet(code, frame.pc) orelse return false;

    if (frame.locals.len < 2 or frame.locals_uninit.len < 2) return false;
    if (frame.localIsUninitialized(0) or frame.localIsUninitialized(1)) return false;
    const array_slot = slotValueBorrowed(frame.locals[0]);
    if (array_slot.isUninitialized()) return false;
    const array_object = objectFromValue(array_slot) orelse return false;

    const index_value = slotValueBorrowed(frame.locals[1]);
    const index_i32 = index_value.asInt32() orelse return false;
    if (index_i32 < 0) return false;
    const index: u32 = @intCast(index_i32);
    if (index > core.atom.max_int_atom) return false;

    const append_value = denseArrayAppendValueFromBytecode(frame, function, value_get.idx, value_get.next_pc) orelse return false;
    if (append_value.next_pc >= code.len or code[append_value.next_pc] != op.put_array_el) return false;
    if (!try array_object.appendDenseArrayIndex(ctx.runtime, index, core.atom.atomFromUInt32(index), append_value.value)) return false;

    frame.pc = append_value.next_pc + 1;
    return true;
}

fn tryFuseLocal0Local1Int32ArithmeticStore(
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) bool {
    const code = function.code;
    const multiplier = immediateInt32Operand(code, frame.pc) orelse return false;
    if (multiplier.next_pc >= code.len or code[multiplier.next_pc] != op.mul) return false;
    const induction_get = decodeLocalGet(code, multiplier.next_pc + 1) orelse return false;
    if (induction_get.idx != 1) return false;
    const shift = immediateInt32Operand(code, induction_get.next_pc) orelse return false;
    if (shift.next_pc + 4 > code.len or code[shift.next_pc] != op.shr or code[shift.next_pc + 1] != op.xor or code[shift.next_pc + 2] != op.add) return false;
    const or_mask = immediateInt32Operand(code, shift.next_pc + 3) orelse return false;
    if (or_mask.next_pc >= code.len or code[or_mask.next_pc] != op.@"or") return false;
    const store = decodeLocalPut(code, or_mask.next_pc + 1) orelse return false;
    if (store.idx != 0) return false;
    if (store.checked or (store.idx < function.var_is_const.len and function.var_is_const[store.idx])) return false;

    if (frame.locals.len < 2 or frame.locals_uninit.len < 2) return false;
    if (frame.localIsUninitialized(0) or frame.localIsUninitialized(1)) return false;
    const accumulator = slotValueBorrowed(frame.locals[0]).asInt32() orelse return false;
    const induction = slotValueBorrowed(frame.locals[1]).asInt32() orelse return false;

    const product_exact = @as(i128, induction) * @as(i128, multiplier.value);
    // Outside this range JS multiplication may round before bitwise ToInt32.
    if (!safeIntegerI128(product_exact)) return false;
    const product: i32 = @truncate(product_exact);
    const logical_shift: i32 = @bitCast(@as(u32, @bitCast(induction)) >> @intCast(shift.value & 31));
    const term = product ^ logical_shift;
    const updated = (accumulator +% term) | or_mask.value;

    frame.locals[0] = core.JSValue.int32(updated);
    frame.pc = store.operand_pc + store.consume;
    return true;
}

fn tryFuseShortLocal0Local1Int32ArithmeticStoreRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (induction_idx != 1) return false;
    if (!allow_loop_tail_fusion or ctx.runtime.hasInterruptHandler()) return false;
    if (frame.locals.len < 2 or frame.locals_uninit.len < 2) return false;
    if (frame.localIsUninitialized(0) or frame.localIsUninitialized(1)) return false;

    const condition_pc = if (frame.pc >= 1) frame.pc - 1 else return false;
    const pc = frame.pc;
    const code = function.code;
    const limit_get = decodeLoopLimitGet(code, pc) orelse return false;
    switch (limit_get.limit) {
        .binding => |binding| if (binding.idx == 0 or binding.idx == induction_idx) return false,
        .immediate, .arg => {},
    }
    if (limit_get.next_pc >= code.len or code[limit_get.next_pc] != op.lt) return false;
    const exit_branch = decodeFalseBranch(code, limit_get.next_pc + 1) orelse return false;

    const current_i = slotValueBorrowed(frame.locals[induction_idx]).asInt32() orelse return false;
    const limit = loopLimitReadableInt32(frame, limit_get.limit) orelse return false;
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }
    if (current_i < 0 or limit < 0) return false;

    if (exit_branch.true_pc >= code.len or code[exit_branch.true_pc] != op.get_loc0_loc1) return false;
    const multiplier = immediateInt32Operand(code, exit_branch.true_pc + 1) orelse return false;
    if (multiplier.next_pc >= code.len or code[multiplier.next_pc] != op.mul) return false;
    const induction_get = decodeLocalGet(code, multiplier.next_pc + 1) orelse return false;
    if (induction_get.idx != induction_idx) return false;
    const shift = immediateInt32Operand(code, induction_get.next_pc) orelse return false;
    if (shift.next_pc + 4 > code.len or code[shift.next_pc] != op.shr or code[shift.next_pc + 1] != op.xor or code[shift.next_pc + 2] != op.add) return false;
    const or_mask = immediateInt32Operand(code, shift.next_pc + 3) orelse return false;
    if (or_mask.value != 0) return false;
    if (or_mask.next_pc >= code.len or code[or_mask.next_pc] != op.@"or") return false;
    const accumulator_store = decodeLocalPut(code, or_mask.next_pc + 1) orelse return false;
    if (accumulator_store.checked or accumulator_store.idx != 0) return false;
    if (accumulator_store.idx < function.var_is_const.len and function.var_is_const[accumulator_store.idx]) return false;

    var tail_pc = accumulator_store.operand_pc + accumulator_store.consume;
    if (tail_pc < code.len and code[tail_pc] == op.close_loc) {
        if (tail_pc + 3 > code.len) return false;
        const close_idx = readInt(u16, code[tail_pc + 1 ..][0..2]);
        if (close_idx != induction_idx) return false;
        if (varRefCellFromValue(frame.locals[induction_idx]) != null) return false;
        tail_pc += 3;
    }
    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (tail_get.idx != induction_idx) return false;
    if (tail_get.next_pc >= code.len or code[tail_get.next_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_get.next_pc + 1) orelse return false;
    if (tail_put.idx != induction_idx) return false;
    if (induction_idx < function.var_is_const.len and function.var_is_const[induction_idx]) return false;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return false;

    var accumulator = slotValueBorrowed(frame.locals[0]).asInt32() orelse return false;
    var i = current_i;
    while (i < limit) : (i += 1) {
        const product_exact = @as(i128, i) * @as(i128, multiplier.value);
        if (!safeIntegerI128(product_exact)) return false;
        const product: i32 = @truncate(product_exact);
        const logical_shift: i32 = @bitCast(@as(u32, @bitCast(i)) >> @intCast(shift.value & 31));
        accumulator = accumulator +% (product ^ logical_shift);
    }

    try setSlotValue(ctx, &frame.locals[0], core.JSValue.int32(accumulator));
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, 0, sync_global_lexical_locals);
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

const DenseArrayAppendValue = struct {
    value: core.JSValue,
    next_pc: usize,
};

const ObjectFieldUpdateAccumulatePattern = struct {
    a_atom: core.Atom,
    b_atom: core.Atom,
    c_atom: core.Atom,
    mask: i32,
    false_pc: usize,
};

const ObjectFieldUpdateAccumulateSlots = struct {
    a_index: usize,
    a: i32,
    b: i32,
    c: i32,
};

fn tryFuseShortLocalObjectFieldUpdateAccumulateRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (induction_idx != 2) return false;
    if (!allow_loop_tail_fusion or ctx.runtime.hasInterruptHandler()) return false;
    if (frame.locals.len < 3 or frame.locals_uninit.len < 3) return false;
    if (frame.localIsUninitialized(0) or frame.localIsUninitialized(1) or frame.localIsUninitialized(induction_idx)) return false;
    if (1 < function.var_is_const.len and function.var_is_const[1]) return false;
    if (induction_idx < function.var_is_const.len and function.var_is_const[induction_idx]) return false;

    const condition_pc = if (frame.pc >= 1) frame.pc - 1 else return false;
    const code = function.code;
    const limit_get = decodeLoopLimitGet(code, frame.pc) orelse return false;
    switch (limit_get.limit) {
        .binding => |binding| if (binding.idx == 0 or binding.idx == 1 or binding.idx == induction_idx) return false,
        .immediate, .arg => {},
    }
    if (limit_get.next_pc >= code.len or code[limit_get.next_pc] != op.lt) return false;
    const exit_branch = decodeFalseBranch(code, limit_get.next_pc + 1) orelse return false;

    const current_i = slotValueBorrowed(frame.locals[induction_idx]).asInt32() orelse return false;
    const limit = loopLimitReadableInt32(frame, limit_get.limit) orelse return false;
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }
    if (current_i < 0 or limit < 0) return false;

    const pattern = decodeObjectFieldUpdateAccumulateLoop(code, exit_branch.true_pc, exit_branch.false_pc, condition_pc, induction_idx) orelse return false;
    const object = objectFromValue(slotValueBorrowed(frame.locals[0])) orelse return false;
    const slots = objectFieldUpdateAccumulateSlots(object, pattern) orelse return false;

    var a = slots.a;
    const b = slots.b;
    const c = slots.c;
    var accumulator: i128 = slotValueBorrowed(frame.locals[1]).asInt32() orelse return false;
    var i = current_i;
    while (i < limit) : (i += 1) {
        a = (a +% b +% i) & pattern.mask;
        accumulator += @as(i128, a) + @as(i128, c);
        if (!safeIntegerI128(accumulator)) return false;
    }

    if (!(try setOwnDataPropertyAt(ctx.runtime, object, slots.a_index, pattern.a_atom, core.JSValue.int32(a)))) return false;
    const accumulator_value = value_ops.numberToValue(@floatFromInt(accumulator));
    errdefer accumulator_value.free(ctx.runtime);
    try setSlotValue(ctx, &frame.locals[1], accumulator_value);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, 1, sync_global_lexical_locals);
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = pattern.false_pc;
    return true;
}

fn decodeObjectFieldUpdateAccumulateLoop(
    code: []const u8,
    body_pc: usize,
    false_pc: usize,
    condition_pc: usize,
    induction_idx: u16,
) ?ObjectFieldUpdateAccumulatePattern {
    const receiver_for_put = decodeLocalGet(code, body_pc) orelse return null;
    if (receiver_for_put.idx != 0) return null;
    const receiver_for_a = decodeLocalGet(code, receiver_for_put.next_pc) orelse return null;
    if (receiver_for_a.idx != 0) return null;
    const a_get = decodeFieldAtom(code, receiver_for_a.next_pc, op.get_field) orelse return null;
    const receiver_for_b = decodeLocalGet(code, a_get.next_pc) orelse return null;
    if (receiver_for_b.idx != 0) return null;
    const b_get = decodeFieldAtom(code, receiver_for_b.next_pc, op.get_field) orelse return null;
    if (b_get.next_pc >= code.len or code[b_get.next_pc] != op.add) return null;
    const induction_get = decodeLocalGet(code, b_get.next_pc + 1) orelse return null;
    if (induction_get.idx != induction_idx) return null;
    if (induction_get.next_pc >= code.len or code[induction_get.next_pc] != op.add) return null;
    const mask = immediateInt32Operand(code, induction_get.next_pc + 1) orelse return null;
    if (mask.value < 0) return null;
    if (mask.next_pc >= code.len or code[mask.next_pc] != op.@"and") return null;
    const a_put = decodeFieldAtom(code, mask.next_pc + 1, op.put_field) orelse return null;
    if (a_put.atom != a_get.atom) return null;

    const accumulator_get = decodeLocalGet(code, a_put.next_pc) orelse return null;
    if (accumulator_get.idx != 1) return null;
    const receiver_for_a_sum = decodeLocalGet(code, accumulator_get.next_pc) orelse return null;
    if (receiver_for_a_sum.idx != 0) return null;
    const a_sum_get = decodeFieldAtom(code, receiver_for_a_sum.next_pc, op.get_field) orelse return null;
    if (a_sum_get.atom != a_get.atom) return null;
    const receiver_for_c = decodeLocalGet(code, a_sum_get.next_pc) orelse return null;
    if (receiver_for_c.idx != 0) return null;
    const c_get = decodeFieldAtom(code, receiver_for_c.next_pc, op.get_field) orelse return null;
    if (c_get.next_pc + 2 > code.len or code[c_get.next_pc] != op.add or code[c_get.next_pc + 1] != op.add) return null;
    const accumulator_put = decodeLocalPut(code, c_get.next_pc + 2) orelse return null;
    if (accumulator_put.idx != 1) return null;

    var tail_pc = accumulator_put.operand_pc + accumulator_put.consume;
    if (tail_pc < code.len and code[tail_pc] == op.close_loc) {
        if (tail_pc + 3 > code.len) return null;
        const close_idx = readInt(u16, code[tail_pc + 1 ..][0..2]);
        if (close_idx != induction_idx) return null;
        tail_pc += 3;
    }
    const tail_get = decodeLocalGet(code, tail_pc) orelse return null;
    if (tail_get.idx != induction_idx) return null;
    if (tail_get.next_pc >= code.len or code[tail_get.next_pc] != op.post_inc) return null;
    const tail_put = decodeLocalPut(code, tail_get.next_pc + 1) orelse return null;
    if (tail_put.idx != induction_idx) return null;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return null;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return null;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return null;
    if (goto_operand_pc + 1 != false_pc) return null;
    if (a_get.atom == b_get.atom or a_get.atom == c_get.atom) return null;

    return .{
        .a_atom = a_get.atom,
        .b_atom = b_get.atom,
        .c_atom = c_get.atom,
        .mask = mask.value,
        .false_pc = false_pc,
    };
}

fn objectFieldUpdateAccumulateSlots(
    object: *core.Object,
    pattern: ObjectFieldUpdateAccumulatePattern,
) ?ObjectFieldUpdateAccumulateSlots {
    if (object.proxyTarget() != null or object.exotic != null) return null;
    if (object.class_id != core.class.ids.object or object.is_array or object.is_global) return null;
    const a_lookup = fastOwnOrdinaryDataPropertyLookupForObject(object, pattern.a_atom);
    const b_lookup = fastOwnOrdinaryDataPropertyLookupForObject(object, pattern.b_atom);
    const c_lookup = fastOwnOrdinaryDataPropertyLookupForObject(object, pattern.c_atom);
    const a = switch (a_lookup) {
        .value => |lookup| lookup,
        .missing, .slow => return null,
    };
    const b = switch (b_lookup) {
        .value => |lookup| lookup,
        .missing, .slow => return null,
    };
    const c = switch (c_lookup) {
        .value => |lookup| lookup,
        .missing, .slow => return null,
    };
    if (a.index >= object.properties.len or !object.properties[a.index].flags.writable) return null;
    return .{
        .a_index = a.index,
        .a = a.value.asInt32() orelse return null,
        .b = b.value.asInt32() orelse return null,
        .c = c.value.asInt32() orelse return null,
    };
}

const DenseArrayMulAndMaskFormula = struct {
    multiplier: i32,
    mask: i32,
    next_pc: usize,
};

fn denseArrayAppendValueFromBytecode(
    frame: *const frame_mod.Frame,
    function: *const bytecode.Bytecode,
    first_value_idx: u16,
    first_value_next_pc: usize,
) ?DenseArrayAppendValue {
    if (first_value_idx >= frame.locals.len or first_value_idx >= frame.locals_uninit.len) return null;
    if (frame.localIsUninitialized(first_value_idx)) return null;
    const value = slotValueBorrowed(frame.locals[first_value_idx]);
    if (value.isUninitialized()) return null;

    const code = function.code;
    if (first_value_next_pc < code.len and code[first_value_next_pc] == op.put_array_el) {
        return .{ .value = value, .next_pc = first_value_next_pc };
    }

    const source = value.asInt32() orelse return null;
    const multiplier = immediateInt32Operand(code, first_value_next_pc) orelse return null;
    if (multiplier.value < 0) return null;
    if (multiplier.next_pc >= code.len or code[multiplier.next_pc] != op.mul) return null;
    const mask = immediateInt32Operand(code, multiplier.next_pc + 1) orelse return null;
    if (mask.value < 0) return null;
    if (mask.next_pc >= code.len or code[mask.next_pc] != op.@"and") return null;

    const product = std.math.mul(i32, source, multiplier.value) catch return null;
    return .{
        .value = core.JSValue.int32(product & mask.value),
        .next_pc = mask.next_pc + 1,
    };
}

fn denseArrayMulAndMaskFormulaFromBytecode(code: []const u8, pc: usize) ?DenseArrayMulAndMaskFormula {
    const multiplier = immediateInt32Operand(code, pc) orelse return null;
    if (multiplier.value < 0) return null;
    if (multiplier.next_pc >= code.len or code[multiplier.next_pc] != op.mul) return null;
    const mask = immediateInt32Operand(code, multiplier.next_pc + 1) orelse return null;
    if (mask.value < 0) return null;
    if (mask.next_pc >= code.len or code[mask.next_pc] != op.@"and") return null;
    return .{
        .multiplier = multiplier.value,
        .mask = mask.value,
        .next_pc = mask.next_pc + 1,
    };
}

fn tryFuseShortLocal0Local1DenseArrayMulAndMaskAppendRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (induction_idx != 1) return false;
    if (!allow_loop_tail_fusion or ctx.runtime.hasInterruptHandler()) return false;
    if (frame.locals.len < 2 or frame.locals_uninit.len < 2) return false;
    if (frame.localIsUninitialized(0) or frame.localIsUninitialized(1)) return false;

    const condition_pc = if (frame.pc >= 1) frame.pc - 1 else return false;
    const pc = frame.pc;
    const code = function.code;
    const limit_get = decodeLoopLimitGet(code, pc) orelse return false;
    if (limit_get.next_pc >= code.len or code[limit_get.next_pc] != op.lt) return false;
    const exit_branch = decodeFalseBranch(code, limit_get.next_pc + 1) orelse return false;

    const current_i = frame.locals[induction_idx].asInt32() orelse return false;
    const limit = loopLimitReadableInt32(frame, limit_get.limit) orelse return false;
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }
    if (current_i < 0 or limit < 0) return false;

    if (exit_branch.true_pc >= code.len or code[exit_branch.true_pc] != op.get_loc0_loc1) return false;
    const value_get = decodeLocalGet(code, exit_branch.true_pc + 1) orelse return false;
    if (value_get.idx != induction_idx) return false;
    const formula = denseArrayMulAndMaskFormulaFromBytecode(code, value_get.next_pc) orelse return false;
    if (formula.next_pc >= code.len or code[formula.next_pc] != op.put_array_el) return false;

    var tail_pc = formula.next_pc + 1;
    if (tail_pc < code.len and code[tail_pc] == op.close_loc) {
        if (tail_pc + 3 > code.len) return false;
        const close_idx = readInt(u16, code[tail_pc + 1 ..][0..2]);
        if (close_idx != induction_idx) return false;
        if (varRefCellFromValue(frame.locals[induction_idx]) != null) return false;
        tail_pc += 3;
    }
    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (tail_get.idx != induction_idx) return false;
    if (tail_get.next_pc >= code.len or code[tail_get.next_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_get.next_pc + 1) orelse return false;
    if (tail_put.idx != induction_idx) return false;
    if (induction_idx < function.var_is_const.len and function.var_is_const[induction_idx]) return false;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return false;

    const array_slot = slotValueBorrowed(frame.locals[0]);
    if (array_slot.isUninitialized()) return false;
    const array_object = objectFromValue(array_slot) orelse return false;
    if (!try array_object.appendDenseArrayInt32MulAndMaskRange(ctx.runtime, @intCast(current_i), @intCast(limit), formula.multiplier, formula.mask)) return false;

    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

pub fn tryFuseCheckedLocalDenseArrayChunkedInt32ValueAppendRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    value_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!allow_loop_tail_fusion) return false;
    if (value_idx >= frame.locals.len or value_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(value_idx)) return false;
    if (value_idx < function.var_is_const.len and function.var_is_const[value_idx]) return false;

    const code = function.code;
    const condition_pc = if (frame.pc >= 3) frame.pc - 3 else return false;
    const pc = frame.pc;
    const end_get = decodeLocalGet(code, pc) orelse return false;
    if (end_get.next_pc >= code.len or code[end_get.next_pc] != op.lte) return false;
    const exit_branch = decodeFalseBranch(code, end_get.next_pc + 1) orelse return false;

    const current_value = slotValueBorrowed(frame.locals[value_idx]).asInt32() orelse return false;
    const end_value = (localReadableBorrowed(frame, end_get.idx, end_get.checked) orelse return false).asInt32() orelse return false;
    if (current_value > end_value) {
        frame.pc = exit_branch.false_pc;
        return true;
    }

    const array_get = decodeLocalGet(code, exit_branch.true_pc) orelse return false;
    const array_value = localReadableBorrowed(frame, array_get.idx, array_get.checked) orelse return false;
    const array_object = objectFromValue(array_value) orelse return false;

    const length_get = decodeLocalGet(code, array_get.next_pc) orelse return false;
    const length_idx = length_get.idx;
    if (length_idx >= frame.locals.len or length_idx >= frame.locals_uninit.len) return false;
    if (length_idx < function.var_is_const.len and function.var_is_const[length_idx]) return false;
    const length_value = (localReadableBorrowed(frame, length_idx, length_get.checked) orelse return false).asInt32() orelse return false;
    if (length_value < 0) return false;
    if (length_get.next_pc >= code.len or code[length_get.next_pc] != op.post_inc) return false;

    const length_put = decodeLocalPut(code, length_get.next_pc + 1) orelse return false;
    if (!length_put.checked or length_put.idx != length_idx) return false;
    const value_get = decodeLocalGet(code, length_put.operand_pc + length_put.consume) orelse return false;
    if (!value_get.checked or value_get.idx != value_idx) return false;
    if (value_get.next_pc >= code.len or code[value_get.next_pc] != op.put_array_el) return false;

    const length_test_get = decodeLocalGet(code, value_get.next_pc + 1) orelse return false;
    if (!length_test_get.checked or length_test_get.idx != length_idx) return false;
    const chunk_get = decodeLocalGet(code, length_test_get.next_pc) orelse return false;
    const chunk_value = (localReadableBorrowed(frame, chunk_get.idx, chunk_get.checked) orelse return false).asInt32() orelse return false;
    if (chunk_value <= length_value) return false;
    if (chunk_get.next_pc >= code.len or code[chunk_get.next_pc] != op.strict_eq) return false;
    const chunk_branch = decodeFalseBranch(code, chunk_get.next_pc + 1) orelse return false;

    const tail_get = decodeLocalGet(code, chunk_branch.false_pc) orelse return false;
    if (!tail_get.checked or tail_get.idx != value_idx) return false;
    if (tail_get.next_pc >= code.len or code[tail_get.next_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_get.next_pc + 1) orelse return false;
    if (!tail_put.checked or tail_put.idx != value_idx) return false;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return false;

    const remaining_range = @as(i64, end_value) - @as(i64, current_value) + 1;
    const remaining_chunk = @as(i64, chunk_value) - @as(i64, length_value);
    if (remaining_range <= 0 or remaining_chunk <= 0) return false;
    const raw_count_i64 = @min(remaining_range, remaining_chunk);
    const capped_for_interrupt = ctx.runtime.hasInterruptHandler() and raw_count_i64 > 16_384;
    const count_i64 = if (capped_for_interrupt) 16_384 else raw_count_i64;
    if (count_i64 <= 0 or count_i64 > std.math.maxInt(u32)) return false;
    const count: u32 = @intCast(count_i64);

    const hit_chunk = !capped_for_interrupt and remaining_chunk <= remaining_range;
    const next_length_i64 = @as(i64, length_value) + count_i64;
    if (next_length_i64 > std.math.maxInt(i32)) return false;
    const next_value_adjust: i64 = if (hit_chunk) 1 else 0;
    const next_value_i64 = @as(i64, current_value) + count_i64 - next_value_adjust;
    if (next_value_i64 < std.math.minInt(i32) or next_value_i64 > std.math.maxInt(i32)) return false;

    if (!try array_object.appendDenseArrayInt32ValueRange(ctx.runtime, @intCast(length_value), current_value, count)) return false;

    try setSlotValue(ctx, &frame.locals[length_idx], core.JSValue.int32(@intCast(next_length_i64)));
    try setSlotValue(ctx, &frame.locals[value_idx], core.JSValue.int32(@intCast(next_value_i64)));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, length_idx, sync_global_lexical_locals);
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, value_idx, sync_global_lexical_locals);
    frame.pc = if (hit_chunk) chunk_branch.true_pc else if (capped_for_interrupt) condition_pc else exit_branch.false_pc;
    return true;
}

pub fn tryFuseCheckedLocalDenseArrayInt32AppendRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!allow_loop_tail_fusion or ctx.runtime.hasInterruptHandler()) return false;
    if (induction_idx >= frame.locals.len or induction_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(induction_idx)) return false;

    const condition_pc = if (frame.pc >= 3) frame.pc - 3 else return false;
    const pc = frame.pc;
    const code = function.code;
    const limit_operand = immediateInt32Operand(code, pc) orelse return false;
    if (limit_operand.next_pc >= code.len or code[limit_operand.next_pc] != op.lt) return false;
    const exit_branch = decodeFalseBranch(code, limit_operand.next_pc + 1) orelse return false;

    const current_i = frame.locals[induction_idx].asInt32() orelse return false;
    const limit = limit_operand.value;
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }
    if (current_i < 0) return false;

    const array_get = decodeBindingGet(code, exit_branch.true_pc) orelse return false;
    const array_value = bindingReadableBorrowed(frame, array_get) orelse return false;
    const array_object = objectFromValue(array_value) orelse return false;

    const index_get = decodeLocalGet(code, array_get.next_pc) orelse return false;
    if (!index_get.checked or index_get.idx != induction_idx) return false;
    const value_get = decodeLocalGet(code, index_get.next_pc) orelse return false;
    if (!value_get.checked or value_get.idx != induction_idx) return false;
    if (value_get.next_pc >= code.len or code[value_get.next_pc] != op.put_array_el) return false;

    var tail_pc = value_get.next_pc + 1;
    if (tail_pc < code.len and code[tail_pc] == op.close_loc) {
        if (tail_pc + 3 > code.len) return false;
        const close_idx = readInt(u16, code[tail_pc + 1 ..][0..2]);
        if (close_idx != induction_idx) return false;
        if (varRefCellFromValue(frame.locals[induction_idx]) != null) return false;
        tail_pc += 3;
    }
    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (!tail_get.checked or tail_get.idx != induction_idx) return false;
    if (tail_get.next_pc >= code.len or code[tail_get.next_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_get.next_pc + 1) orelse return false;
    if (!tail_put.checked or tail_put.idx != induction_idx) return false;
    if (induction_idx < function.var_is_const.len and function.var_is_const[induction_idx]) return false;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return false;

    const start: u32 = @intCast(current_i);
    const end: u32 = @intCast(limit);
    if (!try array_object.appendDenseArrayInt32Range(ctx.runtime, start, end)) return false;

    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

pub fn tryFuseCheckedLocalMathMinMaxAddRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!allow_loop_tail_fusion or ctx.runtime.hasInterruptHandler()) return false;
    if (induction_idx >= frame.locals.len or induction_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(induction_idx)) return false;

    const condition_pc = if (frame.pc >= 3) frame.pc - 3 else return false;
    const pc = frame.pc;
    const code = function.code;
    const limit_operand = immediateInt32Operand(code, pc) orelse return false;
    if (limit_operand.next_pc >= code.len or code[limit_operand.next_pc] != op.lt) return false;
    const exit_branch = decodeFalseBranch(code, limit_operand.next_pc + 1) orelse return false;

    const current_i = frame.locals[induction_idx].asInt32() orelse return false;
    const limit = limit_operand.value;
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }

    const accumulator_get = decodeBindingGet(code, exit_branch.true_pc) orelse return false;
    const global_pc = accumulator_get.next_pc;
    if (global_pc + 10 > code.len) return false;
    const global_op = code[global_pc];
    if (global_op != op.get_var and global_op != op.get_var_undef) return false;
    const global_atom = readInt(u32, code[global_pc + 1 ..][0..4]);
    if (global_atom != atom_math) return false;
    const field_pc = global_pc + 5;
    if (code[field_pc] != op.get_field2) return false;
    const method_atom = readInt(u32, code[field_pc + 1 ..][0..4]);

    const args_pc = field_pc + 5;
    const parsed_args = parseInductionAndImmediateInt32Args(code, args_pc, induction_idx) orelse return false;
    const call_pc = parsed_args.next_pc;
    if (call_pc + 4 > code.len or code[call_pc] != op.call_method) return false;
    if (readInt(u16, code[call_pc + 1 ..][0..2]) != 2) return false;
    const add_pc = call_pc + 3;
    if (add_pc >= code.len or code[add_pc] != op.add) return false;

    var store_pc = add_pc + 1;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const candidate_store = decodeBindingPut(code, store_pc) orelse return false;
        const candidate_drop_pc = candidate_store.operand_pc + candidate_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const accumulator_put = decodeBindingPut(code, store_pc) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

    var tail_pc = if (drop_pc) |drop| drop + 1 else accumulator_put.operand_pc + accumulator_put.consume;
    if (tail_pc < code.len and code[tail_pc] == op.close_loc) {
        if (tail_pc + 3 > code.len) return false;
        const close_idx = readInt(u16, code[tail_pc + 1 ..][0..2]);
        if (close_idx != induction_idx) return false;
        if (varRefCellFromValue(frame.locals[induction_idx]) != null) return false;
        tail_pc += 3;
    }
    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (!tail_get.checked or tail_get.idx != induction_idx) return false;
    if (tail_get.next_pc >= code.len or code[tail_get.next_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_get.next_pc + 1) orelse return false;
    if (!tail_put.checked or tail_put.idx != induction_idx) return false;
    if (induction_idx < function.var_is_const.len and function.var_is_const[induction_idx]) return false;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return false;

    const math_value = fastGlobalDataValueForRange(ctx, function, global, frame, global_atom, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
    const method_value = fastOwnDataPropertyBorrowedValueMaterialized(ctx.runtime, math_value, method_atom) orelse return false;
    const function_object = objectFromValue(method_value) orelse return false;
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*) orelse return false;
    if (native_ref.domain != .math) return false;
    const is_max = switch (native_ref.id) {
        7 => false,
        8 => true,
        else => return false,
    };

    const accumulator = (bindingReadableBorrowed(frame, accumulator_get) orelse return false).asInt32() orelse return false;
    const total_delta = mathMinMaxInductionRangeSum(current_i, limit, parsed_args.immediate, is_max);
    const final_accumulator = @as(i128, accumulator) + total_delta;
    if (final_accumulator < std.math.minInt(i32) or final_accumulator > std.math.maxInt(i32)) return false;

    try storeBindingInt32(ctx, function, global, frame, accumulator_put, @intCast(final_accumulator), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

pub fn tryFuseCheckedLocalMathMinMaxAdd(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    local_idx: u16,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime globalLexicalValue: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const pc = frame.pc;
    const code = function.code;
    if (pc + 5 > code.len) return false;
    const global_op = code[pc];
    if (global_op != op.get_var and global_op != op.get_var_undef) return false;
    const global_atom = readInt(u32, code[pc + 1 ..][0..4]);
    if (global_atom != atom_math) return false;

    const field_pc = pc + 5;
    if (field_pc + 5 > code.len or code[field_pc] != op.get_field2) return false;
    const method_atom = readInt(u32, code[field_pc + 1 ..][0..4]);
    const arg0 = borrowedSimpleCallArg(frame, function, field_pc + 5) orelse return false;
    const arg1 = borrowedSimpleCallArg(frame, function, arg0.next_pc) orelse return false;
    const call_pc = arg1.next_pc;
    if (call_pc + 4 > code.len or code[call_pc] != op.call_method) return false;
    if (readInt(u16, code[call_pc + 1 ..][0..2]) != 2) return false;
    const add_pc = call_pc + 3;
    if (code[add_pc] != op.add) return false;
    var store_pc = add_pc + 1;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const decoded_store = decodeLocalPut(code, store_pc) orelse return false;
        const candidate_drop_pc = decoded_store.operand_pc + decoded_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const store = decodeLocalPut(code, store_pc) orelse return false;
    if (store.idx != local_idx) return false;

    if (local_idx >= frame.locals.len or local_idx >= frame.locals_uninit.len) return false;
    if (store.idx >= frame.locals.len or store.idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(local_idx)) return false;
    if (store.checked and store.idx < function.var_is_const.len and function.var_is_const[store.idx]) return false;

    const math_value = fastGlobalDataValueForAtom(ctx, function, global, frame, global_atom, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
    const method_value = fastOrdinaryDataPropertyBorrowedValue(ctx.runtime, math_value, method_atom) orelse return false;
    const function_object = objectFromValue(method_value) orelse return false;
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*) orelse return false;
    if (native_ref.domain != .math) return false;
    const is_max = switch (native_ref.id) {
        7 => false,
        8 => true,
        else => return false,
    };

    const math_number = mathMinMaxPrimitive2(arg0.value, arg1.value, is_max) orelse return false;
    const rhs = value_ops.numberToValue(math_number);
    const lhs = slotValueBorrowed(frame.locals[local_idx]);
    if (!lhs.isNumber()) return false;
    const updated = try simpleNumericBinary(ctx.runtime, op.add, lhs, rhs);
    errdefer updated.free(ctx.runtime);

    if (ctx.runtime.opcode_profile != null) core.profile.recordGlobalLookup();
    try setSlotValue(ctx, &frame.locals[store.idx], updated);
    if (!store.checked and store.idx < function.var_is_lexical.len and function.var_is_lexical[store.idx]) {
        frame.clearLocalUninitialized(store.idx);
    }
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, store.idx, sync_global_lexical_locals);
    frame.pc = if (drop_pc) |drop| drop + 1 else store.operand_pc + store.consume;
    _ = try tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    return true;
}

fn fastGlobalDataValueForAtom(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
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
    const global_data = globalOwnDataPropertyBorrowedLookup(global, atom_id) orelse return null;
    return global_data.value;
}

fn fastGlobalDataValueForAtomAtPc(
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
    if (cachedOwnDataPropertyLookupForObject(function, site_pc, ctx.runtime, global, atom_id)) |cached| {
        return cached.value;
    }
    if (declaredGlobalVarDataBorrowedLookup(global, function, atom_id)) |declared| {
        installOwnDataIcForObject(function, site_pc, ctx.runtime, global, atom_id, declared.index);
        return declared.value;
    }
    const global_data = globalOwnDataPropertyBorrowedLookup(global, atom_id) orelse return null;
    installOwnDataIcForObject(function, site_pc, ctx.runtime, global, atom_id, global_data.index);
    return global_data.value;
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
    if (cachedOwnDataPropertyLookupForObjectNoProfile(function, site_pc, global, atom_id)) |cached| {
        return cached.value;
    }
    if (declaredGlobalVarDataBorrowedLookup(global, function, atom_id)) |declared| {
        installOwnDataIcForObject(function, site_pc, ctx.runtime, global, atom_id, declared.index);
        return declared.value;
    }
    const global_data = globalOwnDataPropertyBorrowedLookup(global, atom_id) orelse return null;
    installOwnDataIcForObject(function, site_pc, ctx.runtime, global, atom_id, global_data.index);
    return global_data.value;
}

fn fastInstalledGlobalDataValueForAtomAtPc(
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
    const global_data = fastInstalledGlobalDataLookupForAtomAtPc(ctx, function, global, frame, site_pc, atom_id, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return null;
    return global_data.value;
}

fn fastInstalledGlobalDataLookupForAtomAtPc(
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
) ?BorrowedGlobalDataLookup {
    if (!canUseInstalledGlobalDataIc(ctx, function, atom_id, frame, eval_local_names, eval_var_ref_names, eval_with_object, global)) return null;
    if (!frame.current_function.isUndefined() and functionFrameBindingShadowsGlobal(ctx.runtime, function, frame, atom_id)) return null;
    if (globalLexicalValue(ctx, atom_id)) |lexical_value| {
        lexical_value.free(ctx.runtime);
        return null;
    }
    if (cachedOwnDataPropertyLookupForObject(function, site_pc, ctx.runtime, global, atom_id)) |cached| {
        return .{ .index = cached.index, .value = cached.value };
    }
    if (declaredGlobalVarDataBorrowedLookup(global, function, atom_id)) |declared| {
        installOwnDataIcForObject(function, site_pc, ctx.runtime, global, atom_id, declared.index);
        return declared;
    }
    const global_data = globalOwnDataPropertyBorrowedLookup(global, atom_id) orelse return null;
    installOwnDataIcForObject(function, site_pc, ctx.runtime, global, atom_id, global_data.index);
    return global_data;
}

fn fastGlobalDataValueForRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *const frame_mod.Frame,
    atom_id: core.Atom,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) ?core.JSValue {
    if (!eval_with_object.isUndefined()) return null;
    if (frameHasVarRefBinding(function, frame, atom_id)) return null;
    if (eval_local_names.len != 0 or eval_var_ref_names.len != 0) return null;
    if (frame.eval_local_names.len != 0 or frame.eval_var_ref_names.len != 0) return null;
    if (globalLexicalValue(ctx, atom_id)) |lexical_value| {
        lexical_value.free(ctx.runtime);
        return null;
    }
    if (globalOwnDataPropertyBorrowedLookup(global, atom_id)) |global_data| return global_data.value;
    if (global.exotic != null) return null;

    const desc = global.getOwnProperty(atom_id) orelse return null;
    defer desc.destroy(ctx.runtime);
    if (desc.kind != .data or !desc.value_present) return null;

    const global_data = globalOwnDataPropertyBorrowedLookup(global, atom_id) orelse return null;
    return global_data.value;
}

fn mathMinMaxPrimitive2(arg0: core.JSValue, arg1: core.JSValue, is_max: bool) ?f64 {
    const a = primitiveMathNumber(arg0) orelse return null;
    const b = primitiveMathNumber(arg1) orelse return null;
    if (std.math.isNan(a)) return a;
    if (std.math.isNan(b)) return b;
    return if (is_max) mathFmax(a, b) else mathFmin(a, b);
}

fn mathMinMaxInductionRangeSum(start: i32, limit: i32, immediate: i32, is_max: bool) i128 {
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

fn intRangeDeltaBounds(start: i32, limit: i32) IntRangeDeltaBounds {
    return intRangeDeltaBoundsWide(@as(i128, start), @as(i128, limit));
}

fn intRangeDeltaBoundsWide(first: i128, limit: i128) IntRangeDeltaBounds {
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

fn linearRangeDeltaBounds(first: i128, limit: i128, coefficient: i128, offset: i128) ?IntRangeDeltaBounds {
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

fn fitsI64(value: i128) bool {
    return value >= @as(i128, std.math.minInt(i64)) and value <= @as(i128, std.math.maxInt(i64));
}

fn safeIntegerI128(value: i128) bool {
    const max_safe_integer: i128 = 9007199254740991;
    return value >= -max_safe_integer and value <= max_safe_integer;
}

fn primitiveMathNumber(value: core.JSValue) ?f64 {
    if (value.tag == core.Tag.int) return @floatFromInt(value.asInt32().?);
    if (value.tag == core.Tag.float64) return value.asFloat64().?;
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

fn tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!allow_loop_tail_fusion) return false;
    const saved_pc = frame.pc;
    const code = function.code;
    if (saved_pc + 4 > code.len) return false;
    if (code[saved_pc] != op.get_loc_check) return false;
    const loop_idx = readInt(u16, code[saved_pc + 1 ..][0..2]);
    const update_op = code[saved_pc + 3];
    if (update_op != op.post_inc and update_op != op.post_dec) return false;

    frame.pc = saved_pc + 3;
    if (try arith_vm.tryFuseDroppedCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, loop_idx, update_op, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) {
        return true;
    }
    frame.pc = saved_pc;
    return false;
}

fn tryFuseDroppedLocalPostUpdateGoto8FromGet(
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
    _ = tryFuseLocalInt32LessThanArgFalseBranchAtPc(function, frame, target_pc);
    return true;
}

fn tryFuseDroppedLocalPostUpdateGoto8AtPc(
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
    return try tryFuseDroppedLocalPostUpdateGoto8FromGet(ctx, function, global, frame, get.idx, get.next_pc, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
}

fn tryFuseLocalInt32LessThanArgFalseBranchAtPc(
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    pc: usize,
) bool {
    const get = decodeLocalGet(function.code, pc) orelse return false;
    return tryFuseLocalInt32LessThanArgFalseBranchFromGet(function, frame, get.idx, get.next_pc, get.checked);
}

fn tryFuseLocalInt32LessThanArgFalseBranchFromGet(
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

pub fn tryFuseCheckedLocalDenseArrayModFieldInt32Add(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    local_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const pc = frame.pc;
    const code = function.code;
    if (pc + 16 > code.len) return false;
    if (code[pc] != op.get_loc_check) return false;
    const array_idx = readInt(u16, code[pc + 1 ..][0..2]);
    if (code[pc + 3] != op.get_loc_check) return false;
    const index_idx = readInt(u16, code[pc + 4 ..][0..2]);
    const modulus = smallPushOpcodeIndex(code[pc + 6]) orelse return false;
    if (modulus == 0) return false;
    if (code[pc + 7] != op.mod or code[pc + 8] != op.get_array_el or code[pc + 9] != op.get_field) return false;
    if (code[pc + 14] != op.add) return false;
    var store_pc = pc + 15;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const decoded_store = decodeLocalPut(code, store_pc) orelse return false;
        const candidate_drop_pc = decoded_store.operand_pc + decoded_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const store = decodeLocalPut(code, store_pc) orelse return false;
    if (!store.checked or store.idx != local_idx) return false;
    if (local_idx >= frame.locals.len or local_idx >= frame.locals_uninit.len) return false;
    if (array_idx >= frame.locals.len or array_idx >= frame.locals_uninit.len) return false;
    if (index_idx >= frame.locals.len or index_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(local_idx) or frame.localIsUninitialized(array_idx) or frame.localIsUninitialized(index_idx)) return false;
    if (local_idx < function.var_is_const.len and function.var_is_const[local_idx]) return false;

    const array_slot = frame.locals[array_idx];
    if (varRefCellFromValue(array_slot) != null) return false;
    const array_object = objectFromValue(array_slot) orelse return false;
    if (array_object.proxyTarget() != null or array_object.exotic != null) return false;
    if (!array_object.is_array or array_object.arrayElementStorageMode() != .dense) return false;

    const index_value = frame.locals[index_idx].asInt32() orelse return false;
    if (index_value < 0) return false;
    const element_index: usize = @intCast(@rem(index_value, @as(i32, @intCast(modulus))));
    if (element_index >= @as(usize, @intCast(array_object.length))) return false;
    const elements = array_object.arrayElements();
    if (element_index >= elements.len) return false;
    const element = elements[element_index] orelse return false;

    const field_atom = readInt(u32, code[pc + 10 ..][0..4]);
    const field_value = fastOrdinaryDataPropertyBorrowedValue(ctx.runtime, element, field_atom) orelse return false;
    const lhs = frame.locals[local_idx].asInt32() orelse return false;
    const rhs = field_value.asInt32() orelse return false;

    try setSlotValue(ctx, &frame.locals[local_idx], fastInt32Add(lhs, rhs));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, local_idx, sync_global_lexical_locals);
    frame.pc = if (drop_pc) |drop| drop + 1 else store.operand_pc + store.consume;
    _ = try tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    return true;
}

fn smallPushOpcodeIndex(opc: u8) ?usize {
    return switch (opc) {
        op.push_0 => 0,
        op.push_1 => 1,
        op.push_2 => 2,
        op.push_3 => 3,
        op.push_4 => 4,
        op.push_5 => 5,
        op.push_6 => 6,
        op.push_7 => 7,
        else => null,
    };
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
    const native_ref = fastFunctionOwnNativeBuiltinIdAtPc(function, pc, ctx.runtime, receiver, atom_id) orelse return false;
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
    const callee = globalOwnDataPropertyBorrowedLookup(global, callee_atom) orelse return null;
    const function_object = objectFromValue(callee.value) orelse return null;
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
    const lhs_value = if (cachedOwnDataPropertyLookupForObject(function, target_pc, ctx.runtime, global, global_get.atom)) |lookup|
        lookup.value
    else lookup: {
        const global_data = globalOwnDataPropertyBorrowedLookup(global, global_get.atom) orelse return false;
        installOwnDataIcForObject(function, target_pc, ctx.runtime, global, global_get.atom, global_data.index);
        break :lookup global_data.value;
    };
    const lhs = lhs_value.asInt32() orelse return false;

    const immediate = immediateInt32Operand(function.code, global_get.next_pc) orelse return false;
    if (immediate.next_pc >= function.code.len) return false;
    const result = int32ImmediateCompare(lhs, function.code[immediate.next_pc], immediate.value) orelse return false;
    const branch = decodeFalseBranch(function.code, immediate.next_pc + 1) orelse return false;
    frame.pc = if (result) branch.true_pc else branch.false_pc;
    return true;
}

fn backwardGotoTarget(code: []const u8, operand_pc: usize, goto_opc: u8) ?usize {
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
    const store_index = globalWritableDataStoreIndexForFastPath(ctx, global, function, store_pc, atom_id) orelse return null;
    if (!setGlobalOwnWritableDataPropertyAtOwned(rt, global, store_index, atom_id, value)) return null;
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

fn tryFuseVarRefSimpleStringCall1GlobalIntArgument(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    var_ref_idx: u16,
    consume: u8,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) !bool {
    const callee = varRefReadableBorrowed(frame, var_ref_idx) orelse return false;
    const kind = simpleStringCallableKind(callee) orelse return false;
    const arg_pc = frame.pc + consume;
    const code = function.code;
    if (arg_pc + 6 > code.len) return false;
    const arg_op = code[arg_pc];
    if (arg_op != op.get_var and arg_op != op.get_var_undef) return false;
    if (code[arg_pc + 5] != op.call1) return false;

    const arg_atom = readInt(u32, code[arg_pc + 1 ..][0..4]);
    const arg_value = fastGlobalDataValueForAtomAtPc(ctx, function, global, frame, arg_pc, arg_atom, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
    const arg_i32 = arg_value.asInt32() orelse return false;
    if (kind == .percent_hex_byte and
        try tryFuseStackAddPercentHexGlobalStore(ctx, function, global, frame, stack, arg_i32, arg_pc + 6, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue))
    {
        return true;
    }

    const result = try simpleStringCallResultFromInt32(ctx.runtime, kind, arg_i32) orelse return false;
    var result_owned = true;
    errdefer if (result_owned) result.free(ctx.runtime);

    frame.pc = arg_pc + 6;
    if (try tryFuseStackAddGlobalStore(ctx, function, global, frame, stack, result, &result_owned, eval_local_names, eval_var_ref_names, eval_with_object)) return true;
    try stack.pushOwned(result);
    result_owned = false;
    return true;
}

fn tryFuseStackAddPercentHexGlobalStore(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    byte_i32: i32,
    add_pc: usize,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
) !bool {
    const code = function.code;
    if (add_pc >= code.len or code[add_pc] != op.add) return false;
    var store_pc = add_pc + 1;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const candidate = decodeGlobalPut(code, store_pc) orelse return false;
        if (candidate.next_pc >= code.len or code[candidate.next_pc] != op.drop) return false;
        drop_pc = candidate.next_pc;
    }
    const store = decodeGlobalPut(code, store_pc) orelse return false;
    if (!canFuseGlobalDataWrite(function, frame, store.atom, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    if (ctx.lexicals) |env| {
        if (env.hasOwnProperty(store.atom)) return false;
    }
    const store_index = globalWritableDataStoreIndexForFastPath(ctx, global, function, store_pc, store.atom) orelse return false;

    const lhs = stack.peekBorrowed() orelse return false;
    const lhs_string = stringFromValue(lhs) orelse return false;
    const lhs_bytes = lhs_string.borrowLatin1() orelse return false;
    const suffix_string = try ctx.runtime.percentHexString(@truncate(@as(u32, @bitCast(byte_i32))));
    const suffix_bytes = suffix_string.borrowLatin1() orelse return false;

    const updated_string = try core.string.String.createLatin1Concat(ctx.runtime, lhs_bytes, suffix_bytes);
    var updated_owned = true;
    errdefer if (updated_owned) updated_string.value().free(ctx.runtime);
    if (!setGlobalOwnWritableDataPropertyAtOwned(ctx.runtime, global, store_index, store.atom, updated_string.value())) return false;
    updated_owned = false;

    const lhs_owned = try stack.pop();
    lhs_owned.free(ctx.runtime);
    frame.pc = if (drop_pc) |drop| drop + 1 else store.next_pc;
    _ = tryFuseGlobalInt32PrefixTermsStore(ctx, global, function, frame, frame.pc, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue);
    return true;
}

fn tryFuseGlobalStringPercentHexAddStore(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    lhs: core.JSValue,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
    comptime setSlotValue: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !?Step {
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
    const store_index = globalWritableDataStoreIndexForFastPath(ctx, global, function, store_pc, store.atom) orelse return null;

    const lhs_string = stringFromValue(lhs) orelse return null;
    const lhs_bytes = lhs_string.borrowLatin1() orelse return null;

    const suffix_string = try ctx.runtime.percentHexString(@truncate(@as(u32, @bitCast(arg_i32))));
    const suffix_bytes = suffix_string.borrowLatin1() orelse return null;
    const updated_string = try core.string.String.createLatin1Concat(ctx.runtime, lhs_bytes, suffix_bytes);
    var updated_owned = true;
    errdefer if (updated_owned) updated_string.value().free(ctx.runtime);
    if (!setGlobalOwnWritableDataPropertyAtOwned(ctx.runtime, global, store_index, store.atom, updated_string.value())) return null;
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
    const store_index = globalWritableDataStoreIndexForFastPath(ctx, global, function, store_pc, store.atom) orelse return false;

    const suffix_string = try ctx.runtime.percentHexString(@truncate(@as(u32, @bitCast(arg_i32))));
    const suffix_bytes = suffix_string.borrowLatin1() orelse return false;
    const updated_string = try core.string.String.createLatin1Concat(ctx.runtime, prefix, suffix_bytes);
    var updated_owned = true;
    errdefer if (updated_owned) updated_string.value().free(ctx.runtime);
    if (!setGlobalOwnWritableDataPropertyAtOwned(ctx.runtime, global, store_index, store.atom, updated_string.value())) return false;
    updated_owned = false;

    frame.pc = store.next_pc;
    _ = tryFuseGlobalInt32PrefixTermsStore(ctx, global, function, frame, frame.pc, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue);
    return true;
}

fn tryFuseStackAddGlobalStore(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    rhs: core.JSValue,
    rhs_owned: *bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) !bool {
    if (frame.pc + 6 > function.code.len or function.code[frame.pc] != op.add or function.code[frame.pc + 1] != op.put_var) return false;
    const store_atom = readInt(u32, function.code[frame.pc + 2 ..][0..4]);
    if (!canUseFastGlobalVarLookup(function, store_atom, frame, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    const lhs = stack.peekBorrowed() orelse return false;
    if (!lhs.isString() and !rhs.isString()) return false;

    const updated = try value_ops.binary(ctx.runtime, op.add, lhs, rhs);
    errdefer updated.free(ctx.runtime);
    const store_pc = frame.pc + 1;
    const stored = stored: {
        if (ctx.lexicals) |env| {
            if (env.hasOwnProperty(store_atom)) break :stored false;
        }
        if (cachedOwnDataPropertyLookupForObject(function, store_pc, ctx.runtime, global, store_atom)) |cached| {
            break :stored setGlobalOwnWritableDataPropertyAtOwned(ctx.runtime, global, cached.index, store_atom, updated);
        }
        if (declaredGlobalVarDataBorrowedLookup(global, function, store_atom)) |lookup| {
            installOwnDataIcForObject(function, store_pc, ctx.runtime, global, store_atom, lookup.index);
            break :stored setGlobalOwnWritableDataPropertyAtOwned(ctx.runtime, global, lookup.index, store_atom, updated);
        }
        const lookup = globalOwnDataPropertyBorrowedLookup(global, store_atom) orelse break :stored false;
        installOwnDataIcForObject(function, store_pc, ctx.runtime, global, store_atom, lookup.index);
        break :stored setGlobalOwnWritableDataPropertyAtOwned(ctx.runtime, global, lookup.index, store_atom, updated);
    };
    if (!stored) return false;
    const lhs_owned = try stack.pop();
    defer lhs_owned.free(ctx.runtime);
    rhs_owned.* = false;
    defer rhs.free(ctx.runtime);
    frame.pc += 6;
    return true;
}

fn simpleStringCallResultFromInt32(rt: *core.JSRuntime, kind: bytecode.function.SimpleStringKind, value: i32) !?core.JSValue {
    return switch (kind) {
        .percent_hex_byte => blk: {
            const byte: u8 = @truncate(@as(u32, @bitCast(value)));
            const cached = try rt.percentHexString(byte);
            break :blk cached.value().dup();
        },
        .none => null,
    };
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

const ImmediateInt32 = struct {
    value: i32,
    next_pc: usize,
};

const ImmediateShortBigInt = struct {
    value: i64,
    next_pc: usize,
};

const StoredGlobalDataValue = struct {
    atom: core.Atom,
};

fn immediateInt32Operand(code: []const u8, pc: usize) ?ImmediateInt32 {
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

fn immediateShortBigIntI32Operand(code: []const u8, pc: usize) ?ImmediateShortBigInt {
    if (pc + 5 > code.len or code[pc] != op.push_bigint_i32) return null;
    return .{
        .value = @intCast(readInt(i32, code[pc + 1 ..][0..4])),
        .next_pc = pc + 5,
    };
}

const UriCall1Argument = struct {
    value: core.JSValue,
    next_pc: usize,
    owned: bool,
};

const UriStrictEqIntArg = struct {
    value: i32,
    next_pc: usize,
};

const UriStrictEqBranch = struct {
    true_pc: usize,
    false_pc: usize,
};

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
    const native_ref = fastFunctionOwnNativeBuiltinIdAtPc(function, pc, ctx.runtime, string_ctor, method_atom) orelse return null;
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
    const store_index = globalWritableDataStoreIndexForFastPath(ctx, global, function, put_pc, put.atom) orelse return false;
    const current_value = globalOwnDataPropertyBorrowedAt(global, store_index, get.atom) orelse return false;
    const current = current_value.asInt32() orelse return false;
    if (!setGlobalOwnWritableDataPropertyAtOwned(ctx.runtime, global, store_index, put.atom, fastInt32Add(current, 1))) return false;
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

    const store_index = globalWritableDataStoreIndexForFastPath(ctx, global, function, put_pc, put.atom) orelse return false;
    const current_value = globalOwnDataPropertyBorrowedAt(global, store_index, get.atom) orelse return false;
    const current = current_value.asInt32() orelse return false;
    const updated = switch (update_op) {
        op.post_inc => fastInt32Add(current, 1),
        op.post_dec => fastInt32Sub(current, 1),
        else => unreachable,
    };
    const updated_int = updated.asInt32();
    if (!setGlobalOwnWritableDataPropertyAtOwned(ctx.runtime, global, store_index, put.atom, updated)) {
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
    const value = if (cachedOwnDataPropertyLookupForObjectNoProfile(function, site_pc, global, atom_id)) |cached|
        cached.value
    else lookup: {
        const global_data = globalOwnDataPropertyBorrowedLookup(global, atom_id) orelse return null;
        installOwnDataIcForObject(function, site_pc, ctx.runtime, global, atom_id, global_data.index);
        break :lookup global_data.value;
    };
    if (!value.isString()) return null;
    return .{ .value = value, .next_pc = next_pc, .owned = false };
}

fn setGlobalOwnWritableDataPropertyAt(rt: *core.JSRuntime, global: *core.Object, index: usize, atom_id: core.Atom, new_value: core.JSValue) bool {
    if (global.exotic != null or index >= global.properties.len) return false;
    const entry = &global.properties[index];
    if (entry.atom_id != atom_id or entry.flags.deleted or entry.flags.accessor or !entry.flags.writable) return false;
    switch (entry.slot) {
        .data => {},
        .auto_init, .accessor, .deleted => return false,
    }
    const next_value = core.object.dupPropertyDataValue(&rt.atoms, atom_id, new_value);
    const old_slot = entry.slot;
    entry.slot = .{ .data = next_value };
    core.object.destroyPropertySlot(rt, entry.atom_id, old_slot);
    return true;
}

fn setGlobalOwnWritableDataPropertyAtOwned(rt: *core.JSRuntime, global: *core.Object, index: usize, atom_id: core.Atom, new_value: core.JSValue) bool {
    if (global.exotic != null or index >= global.properties.len) return false;
    const entry = &global.properties[index];
    if (entry.atom_id != atom_id or entry.flags.deleted or entry.flags.accessor or !entry.flags.writable) return false;
    switch (entry.slot) {
        .data => {},
        .auto_init, .accessor, .deleted => return false,
    }
    const old_slot = entry.slot;
    entry.slot = .{ .data = new_value };
    core.object.destroyPropertySlot(rt, entry.atom_id, old_slot);
    return true;
}

fn declaredGlobalVarDataBorrowedLookup(global: *core.Object, function: *const bytecode.Bytecode, atom_id: core.Atom) ?BorrowedGlobalDataLookup {
    for (function.global_var_names) |name| {
        if (name != atom_id) continue;
        return globalOwnDataPropertyBorrowedLookup(global, atom_id);
    }
    return null;
}

const BorrowedGlobalDataLookup = struct {
    index: usize,
    value: core.JSValue,
};

fn globalOwnDataPropertyBorrowedLookup(global: *core.Object, atom_id: core.Atom) ?BorrowedGlobalDataLookup {
    if (global.exotic != null) return null;
    for (global.properties, 0..) |*entry, index| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        if (entry.flags.accessor) return null;
        return switch (entry.slot) {
            .data => |stored| .{ .index = index, .value = stored },
            .auto_init, .accessor, .deleted => null,
        };
    }
    return null;
}

fn globalOwnDataPropertyBorrowedAt(global: *core.Object, index: usize, atom_id: core.Atom) ?core.JSValue {
    if (global.exotic != null or index >= global.properties.len) return null;
    const entry = &global.properties[index];
    if (entry.atom_id != atom_id or entry.flags.deleted or entry.flags.accessor) return null;
    return switch (entry.slot) {
        .data => |stored| stored,
        .auto_init, .accessor, .deleted => null,
    };
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
    if (canUseFastGlobalVarLookup(function, atom_id, frame, eval_local_names, eval_var_ref_names, eval_with_object)) {
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
    const index = globalWritableDataStoreIndexForFastPath(ctx, global, function, site_pc, atom_id) orelse return false;
    return setGlobalOwnWritableDataPropertyAtOwned(rt, global, index, atom_id, value);
}

fn globalWritableDataStoreIndexForFastPath(ctx: *core.JSContext, global: *core.Object, function: *const bytecode.Bytecode, site_pc: usize, atom_id: core.Atom) ?usize {
    const rt = ctx.runtime;
    if (ctx.lexicals) |env| {
        if (env.hasOwnProperty(atom_id)) return null;
    }
    if (cachedOwnDataPropertyLookupForObject(function, site_pc, rt, global, atom_id)) |cached| {
        return globalWritableDataPropertyIndex(global, cached.index, atom_id);
    }
    if (declaredGlobalVarDataBorrowedLookup(global, function, atom_id)) |lookup| {
        const index = globalWritableDataPropertyIndex(global, lookup.index, atom_id) orelse return null;
        installOwnDataIcForObject(function, site_pc, rt, global, atom_id, lookup.index);
        return index;
    }
    const lookup = globalOwnDataPropertyBorrowedLookup(global, atom_id) orelse return null;
    const index = globalWritableDataPropertyIndex(global, lookup.index, atom_id) orelse return null;
    installOwnDataIcForObject(function, site_pc, rt, global, atom_id, lookup.index);
    return index;
}

fn globalWritableDataPropertyIndex(global: *core.Object, index: usize, atom_id: core.Atom) ?usize {
    if (global.exotic != null or index >= global.properties.len) return null;
    const entry = &global.properties[index];
    if (entry.atom_id != atom_id or entry.flags.deleted or entry.flags.accessor or !entry.flags.writable) return null;
    return switch (entry.slot) {
        .data => index,
        .auto_init, .accessor, .deleted => null,
    };
}

pub fn withGetOrDelete(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
    comptime hasPropertyForWith: anytype,
    comptime isBlockedByUnscopables: anytype,
    comptime getValueProperty: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    const diff = readInt(i32, function.code[frame.pc + 4 ..][0..4]);
    const operand_pc = frame.pc;
    frame.pc += 9;
    const obj_value = stack.peek() orelse return error.StackUnderflow;
    defer obj_value.free(ctx.runtime);
    const object = property_ops.expectObject(obj_value) catch {
        const dropped = try stack.pop();
        dropped.free(ctx.runtime);
        return .continue_loop;
    };
    const has_binding = hasPropertyForWith(ctx, output, global, obj_value, atom_id, function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    const blocked = if (has_binding)
        isBlockedByUnscopables(ctx, output, global, obj_value, atom_id, function, frame) catch |err| {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        }
    else
        false;
    if (!has_binding or blocked) {
        const dropped = try stack.pop();
        dropped.free(ctx.runtime);
        return .continue_loop;
    }
    const still_has_binding = if (opc == op.with_make_ref)
        true
    else
        hasPropertyForWith(ctx, output, global, obj_value, atom_id, function, frame) catch |err| {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
    if (opc == op.with_get_var and !still_has_binding) {
        const dropped = try stack.pop();
        dropped.free(ctx.runtime);
        if (function.flags.is_strict) {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
            return error.ReferenceError;
        }
        try stack.pushOwned(core.JSValue.undefinedValue());
        frame.pc = @intCast(@as(i64, @intCast(operand_pc + 4)) + diff);
        return .continue_loop;
    }
    switch (opc) {
        op.with_get_var => {
            const value = try getValueProperty(ctx, output, global, obj_value, atom_id, function, frame);
            errdefer value.free(ctx.runtime);
            const dropped = try stack.pop();
            dropped.free(ctx.runtime);
            try stack.pushOwned(value);
        },
        op.with_delete_var => {
            const deleted = object.deleteProperty(ctx.runtime, atom_id);
            if (!deleted and function.flags.is_strict) {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
                return error.TypeError;
            }
            const dropped = try stack.pop();
            dropped.free(ctx.runtime);
            try stack.pushOwned(core.JSValue.boolean(deleted));
        },
        op.with_get_ref => {
            const value = try getValueProperty(ctx, output, global, obj_value, atom_id, function, frame);
            errdefer value.free(ctx.runtime);
            try stack.pushOwned(value);
        },
        op.with_get_ref_undef => {
            const value = try getValueProperty(ctx, output, global, obj_value, atom_id, function, frame);
            var value_owned = true;
            errdefer if (value_owned) value.free(ctx.runtime);
            try stack.reserveAdditional(1);
            const dropped = try stack.pop();
            dropped.free(ctx.runtime);
            stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
            stack.pushOwnedAssumeCapacity(value);
            value_owned = false;
        },
        op.with_make_ref => {
            const key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
            errdefer key_value.free(ctx.runtime);
            try stack.pushOwned(key_value);
        },
        else => unreachable,
    }
    frame.pc = @intCast(@as(i64, @intCast(operand_pc + 4)) + diff);
    return .done;
}

pub fn makeSlotRef(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    opc: u8,
    comptime ensureVarRefsCapacity: anytype,
    comptime ensureVarRefCell: anytype,
    comptime ensureLocalVarRefCell: anytype,
) !void {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    const idx = readInt(u16, function.code[frame.pc + 4 ..][0..2]);
    frame.pc += 6;

    const ref_value = switch (opc) {
        op.make_loc_ref => blk: {
            if (idx >= frame.locals.len) return error.InvalidBytecode;
            const is_lexical = idx < function.var_is_lexical.len and function.var_is_lexical[idx];
            break :blk try ensureLocalVarRefCell(ctx, frame, idx, is_lexical);
        },
        op.make_arg_ref => blk: {
            if (idx >= frame.args.len) return error.InvalidBytecode;
            break :blk try ensureVarRefCell(ctx, &frame.args[idx]);
        },
        op.make_var_ref_ref => blk: {
            try ensureVarRefsCapacity(ctx, frame, idx);
            break :blk try ensureVarRefCell(ctx, &frame.var_refs[idx]);
        },
        else => unreachable,
    };
    defer ref_value.free(ctx.runtime);
    const key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
    errdefer key_value.free(ctx.runtime);
    try stack.push(ref_value);
    try stack.pushOwned(key_value);
}

pub fn makeVarRef(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
) !void {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    if (try makeEvalBindingRef(ctx, eval_local_names, eval_local_slots, atom_id)) |ref_value| {
        defer ref_value.free(ctx.runtime);
        const key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
        errdefer key_value.free(ctx.runtime);
        try stack.push(ref_value);
        try stack.pushOwned(key_value);
        return;
    }
    if (!frame.eval_var_refs_republished) {
        if (makeEvalVarRef(ctx.runtime, eval_var_ref_names, eval_var_refs, atom_id)) |ref_value| {
            defer ref_value.free(ctx.runtime);
            const key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
            errdefer key_value.free(ctx.runtime);
            try stack.push(ref_value);
            try stack.pushOwned(key_value);
            return;
        }
    }
    if (try makeEvalBindingRef(ctx, frame.eval_local_names, frame.eval_local_slots, atom_id)) |ref_value| {
        defer ref_value.free(ctx.runtime);
        const key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
        errdefer key_value.free(ctx.runtime);
        try stack.push(ref_value);
        try stack.pushOwned(key_value);
        return;
    }
    if (makeEvalVarRef(ctx.runtime, frame.eval_var_ref_names, frame.eval_var_refs, atom_id)) |ref_value| {
        defer ref_value.free(ctx.runtime);
        const key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
        errdefer key_value.free(ctx.runtime);
        try stack.push(ref_value);
        try stack.pushOwned(key_value);
        return;
    }
    const global_value = global.value();
    const has_global_binding = try hasObjectBinding(ctx, output, global, global_value, global, atom_id, function, frame);
    const object_value = if (shared_vm.existingGlobalLexicalEnv(ctx)) |env|
        if (env.hasOwnProperty(atom_id))
            env.value()
        else if (has_global_binding)
            global_value
        else
            core.JSValue.undefinedValue()
    else if (has_global_binding)
        global_value
    else
        core.JSValue.undefinedValue();
    const key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
    defer key_value.free(ctx.runtime);
    try stack.push(object_value);
    try stack.push(key_value);
}

pub fn tryFuseMakeVarRefPercentHexGlobalStringAssignment(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
) !bool {
    _ = eval_local_slots;
    _ = eval_var_refs;
    const code = function.code;
    if (frame.pc + 4 > code.len) return false;
    if (eval_local_names.len != 0 or eval_var_ref_names.len != 0) return false;
    if (frame.eval_local_names.len != 0 or frame.eval_var_ref_names.len != 0) return false;

    const store_atom = readInt(u32, code[frame.pc..][0..4]);
    const lhs_pc = frame.pc + 4;
    if (!globalReferenceAtomCanUseFastData(ctx, function, global, frame, store_atom)) return false;
    const store_lookup = globalOwnDataPropertyBorrowedLookup(global, store_atom) orelse return false;
    const store_index = globalWritableDataPropertyIndex(global, store_lookup.index, store_atom) orelse return false;

    const lhs_get = decodeGlobalDataGet(code, lhs_pc) orelse return false;
    if (!globalReferenceAtomCanUseFastData(ctx, function, global, frame, lhs_get.atom)) return false;
    const lhs = (globalOwnDataPropertyBorrowedLookup(global, lhs_get.atom) orelse return false).value;
    const lhs_string = stringFromValue(lhs) orelse return false;
    const lhs_bytes = lhs_string.borrowLatin1() orelse return false;

    const callee_get = decodeVarRefGet(code, lhs_get.next_pc) orelse return false;
    const callee = varRefReadableBorrowed(frame, callee_get.idx) orelse return false;
    if (simpleStringCallableKind(callee) != .percent_hex_byte) return false;

    const arg_get = decodeGlobalDataGet(code, callee_get.next_pc) orelse return false;
    if (!globalReferenceAtomCanUseFastData(ctx, function, global, frame, arg_get.atom)) return false;
    const arg_value = (globalOwnDataPropertyBorrowedLookup(global, arg_get.atom) orelse return false).value;
    const arg_i32 = arg_value.asInt32() orelse return false;

    const call_pc = arg_get.next_pc;
    if (call_pc + 3 > code.len or code[call_pc] != op.call1 or code[call_pc + 1] != op.add or code[call_pc + 2] != op.put_ref_value) return false;

    const suffix_string = try ctx.runtime.percentHexString(@truncate(@as(u32, @bitCast(arg_i32))));
    const suffix_bytes = suffix_string.borrowLatin1() orelse return false;
    const updated_string = try core.string.String.createLatin1Concat(ctx.runtime, lhs_bytes, suffix_bytes);
    var updated_owned = true;
    errdefer if (updated_owned) updated_string.value().free(ctx.runtime);
    if (!setGlobalOwnWritableDataPropertyAtOwned(ctx.runtime, global, store_index, store_atom, updated_string.value())) return false;
    updated_owned = false;

    frame.pc = call_pc + 3;
    return true;
}

fn globalReferenceAtomCanUseFastData(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *const frame_mod.Frame,
    atom_id: core.Atom,
) bool {
    if (atom_id == core.atom.ids.undefined_ or atom_id == core.atom.ids.arguments) return false;
    if (!frame.current_function.isUndefined()) return false;
    if (frameHasVarRefBinding(function, frame, atom_id)) return false;
    _ = global;
    if (ctx.lexicals) |env| {
        if (env.hasOwnProperty(atom_id)) return false;
    }
    return true;
}

fn decodeGlobalDataGet(code: []const u8, pc: usize) ?GlobalBindingGet {
    if (pc + 5 > code.len) return null;
    const opc = code[pc];
    if (opc != op.get_var and opc != op.get_var_undef) return null;
    return .{
        .atom = readInt(u32, code[pc + 1 ..][0..4]),
        .next_pc = pc + 5,
    };
}

fn makeEvalBindingRef(
    ctx: *core.JSContext,
    names: []const core.Atom,
    slots: []core.JSValue,
    atom_id: core.Atom,
) !?core.JSValue {
    for (names, 0..) |name, idx| {
        if (idx >= slots.len) continue;
        if (!shared_vm.atomIdOrNameEql(ctx.runtime, name, atom_id)) continue;
        return try shared_vm.ensureVarRefCell(ctx, &slots[idx]);
    }
    return null;
}

fn makeEvalVarRef(
    rt: *core.JSRuntime,
    names: []const core.Atom,
    refs: []const core.JSValue,
    atom_id: core.Atom,
) ?core.JSValue {
    for (names, 0..) |name, idx| {
        if (idx >= refs.len) continue;
        if (!shared_vm.atomIdOrNameEql(rt, name, atom_id)) continue;
        if (varRefCellFromValue(refs[idx]) == null) return null;
        return refs[idx].dup();
    }
    return null;
}

pub fn getRefValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime slotValueDup: anytype,
    comptime toPropertyKeyAtom: anytype,
    comptime getValueProperty: anytype,
) !void {
    if (stack.values.len < 2) return error.StackUnderflow;
    const obj = stack.values[stack.values.len - 2].dup();
    defer obj.free(ctx.runtime);
    const key = stack.values[stack.values.len - 1].dup();
    defer key.free(ctx.runtime);
    if (obj.isUndefined()) return error.ReferenceError;
    if (varRefCellFromValue(obj) != null) {
        const value = slotValueDup(obj);
        errdefer value.free(ctx.runtime);
        if (value.isUninitialized()) return error.ReferenceError;
        try stack.pushOwned(value);
        return;
    }
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key, function, frame);
    defer ctx.runtime.atoms.free(atom_id);
    const value = try getValueProperty(ctx, output, global, obj, atom_id, function, frame);
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
}

pub fn putRefValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime setSlotValue: anytype,
    comptime toPropertyKeyAtom: anytype,
    comptime setValueProperty: anytype,
) !void {
    const value = try stack.pop();
    errdefer value.free(ctx.runtime);
    const key = try stack.pop();
    defer key.free(ctx.runtime);
    var obj = try stack.pop();
    defer obj.free(ctx.runtime);

    const runtime_strict = function.flags.is_strict or function.flags.runtime_strict;
    if (obj.isUndefined()) {
        if (runtime_strict) return error.ReferenceError;
        const global_value = global.value().dup();
        obj.free(ctx.runtime);
        obj = global_value;
    }
    if (varRefCellFromValue(obj)) |cell| {
        if (cell.varRefIsFunctionNameSlot().*) {
            if (!runtime_strict) {
                value.free(ctx.runtime);
                return;
            }
            _ = shared_vm.throwTypeErrorMessage(ctx, global, "invalid assignment to const variable") catch |err| return err;
            return error.TypeError;
        }
        if (cell.varRefIsConstSlot().*) {
            _ = shared_vm.throwTypeErrorMessage(ctx, global, "invalid assignment to const variable") catch |err| return err;
            return error.TypeError;
        }
        var ref_slot = obj.dup();
        defer ref_slot.free(ctx.runtime);
        try setSlotValue(ctx, &ref_slot, value);
        return;
    }
    defer value.free(ctx.runtime);
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key, function, frame);
    defer ctx.runtime.atoms.free(atom_id);
    if (runtime_strict) {
        const object = try property_ops.expectObject(obj);
        if (!try hasObjectBinding(ctx, output, global, obj, object, atom_id, function, frame)) return error.ReferenceError;
    }
    const result = try setValueProperty(ctx, output, global, obj, atom_id, value, function, frame);
    result.free(ctx.runtime);
}

fn hasObjectBinding(
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

pub fn getPrivateField(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime toPropertyKeyAtom: anytype,
    comptime getValueProperty: anytype,
) !void {
    const key = try stack.pop();
    defer key.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key, function, frame);
    defer ctx.runtime.atoms.free(atom_id);
    const value = try getValueProperty(ctx, output, global, obj, atom_id, function, frame);
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
}

pub fn putPrivateField(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime toPropertyKeyAtom: anytype,
    comptime setValueProperty: anytype,
) !void {
    const key = try stack.pop();
    defer key.free(ctx.runtime);
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key, function, frame);
    defer ctx.runtime.atoms.free(atom_id);
    const result = try setValueProperty(ctx, output, global, obj, atom_id, value, function, frame);
    result.free(ctx.runtime);
}

pub fn definePrivateField(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime toPropertyKeyAtom: anytype,
    comptime defineClassFieldDataProperty: anytype,
) !void {
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const key = try stack.pop();
    defer key.free(ctx.runtime);
    const obj = stack.peek() orelse return error.StackUnderflow;
    defer obj.free(ctx.runtime);
    const object = try property_ops.expectObject(obj);
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key, function, frame);
    defer ctx.runtime.atoms.free(atom_id);
    try defineClassFieldDataProperty(ctx.runtime, object, atom_id, value);
}

pub fn withPut(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime hasPropertyForWith: anytype,
    comptime setValueProperty: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    const diff = readInt(i32, function.code[frame.pc + 4 ..][0..4]);
    const operand_pc = frame.pc;
    frame.pc += 9;
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    if (obj.isUndefined()) return .continue_loop;
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    _ = hasPropertyForWith(ctx, output, global, obj, atom_id, function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    const result = setValueProperty(ctx, output, global, obj, atom_id, value, function, frame) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    frame.pc = @intCast(@as(i64, @intCast(operand_pc + 4)) + diff);
    result.free(ctx.runtime);
    return .done;
}

pub fn deleteVar(
    ctx: *core.JSContext,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    comptime deleteEvalBinding: anytype,
) !void {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    if (deleteEvalBinding(ctx.runtime, function, frame, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, atom_id)) |deleted| {
        try stack.pushOwned(core.JSValue.boolean(deleted));
    } else if (global.hasProperty(atom_id)) {
        try stack.pushOwned(core.JSValue.boolean(global.deleteProperty(ctx.runtime, atom_id)));
    } else {
        try stack.pushOwned(core.JSValue.boolean(true));
    }
}

pub fn deletePropertyVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime deleteValueProperty: anytype,
    comptime functionHasFrameBinding: anytype,
    comptime typedArrayCanonicalDelete: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    const prop = try stack.pop();
    defer prop.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    if (obj.isNull() or obj.isUndefined()) {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
        return error.TypeError;
    } else if (!obj.isObject()) {
        try stack.pushOwned(core.JSValue.boolean(true));
    } else {
        const object = try property_ops.expectObject(obj);
        const atom_id = try property_ops.propertyKeyAtom(ctx.runtime, prop);
        defer ctx.runtime.atoms.free(atom_id);
        const deleted = if (object.proxyTarget() != null) blk: {
            break :blk deleteValueProperty(ctx, output, global, obj, object, atom_id, function, frame) catch |err| {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
        } else if (object == global and functionHasFrameBinding(ctx.runtime, function, frame, atom_id))
            false
        else if (object.is_array and atom_id == core.atom.ids.length)
            false
        else if (try typedArrayCanonicalDelete(ctx.runtime, object, atom_id)) |typed_deleted|
            typed_deleted
        else
            object.deleteProperty(ctx.runtime, atom_id);
        if (!deleted and function.flags.is_strict) {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
            return error.TypeError;
        }
        try stack.pushOwned(core.JSValue.boolean(deleted));
    }
    return .done;
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
            if (cachedOwnDataPropertyValue(function, site_pc, ctx.runtime, obj, atom_id)) |value| {
                try pushBorrowedValueOrFuseLocalAdd(ctx, stack, function, global, frame, value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
                return .done;
            }
            if (cachedProtoDataPropertyValue(function, site_pc, ctx.runtime, obj, atom_id)) |value| {
                try pushBorrowedValueOrFuseLocalAdd(ctx, stack, function, global, frame, value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
                return .done;
            }
            switch (fastOwnOrdinaryDataPropertyLookup(ctx.runtime, obj, atom_id)) {
                .value => |lookup| {
                    installOwnDataIc(function, site_pc, ctx.runtime, obj, atom_id, lookup.index);
                    try pushBorrowedValueOrFuseLocalAdd(ctx, stack, function, global, frame, lookup.value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
                    return .done;
                },
                .missing, .slow => {},
            }
            switch (fastImmediatePrototypeDataPropertyLookup(ctx.runtime, obj, atom_id)) {
                .value => |lookup| {
                    installProtoDataIc(function, site_pc, ctx.runtime, obj, atom_id, lookup.holder, lookup.index);
                    try pushBorrowedValueOrFuseLocalAdd(ctx, stack, function, global, frame, lookup.value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
                    return .done;
                },
                .missing, .slow => {},
            }
            switch (fastOrdinaryDataPropertyLookup(ctx.runtime, obj, atom_id)) {
                .value => |value| {
                    try pushBorrowedValueOrFuseLocalAdd(ctx, stack, function, global, frame, value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
                    return .done;
                },
                .undefined => {
                    try stack.pushOwned(core.JSValue.undefinedValue());
                    return .done;
                },
                .slow => {},
            }
            if (fastRegExpPrototypeMethodValue(ctx.runtime, obj, atom_id)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            if (fastFunctionOwnDataPropertyValue(ctx.runtime, obj, atom_id)) |value| {
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
            if (cachedOwnDataPropertyValue(function, site_pc, ctx.runtime, obj, atom_id)) |value| {
                try stack.push(value);
                return .done;
            }
            if (cachedProtoDataPropertyValue(function, site_pc, ctx.runtime, obj, atom_id)) |value| {
                try stack.push(value);
                return .done;
            }
            switch (fastOwnOrdinaryDataPropertyLookup(ctx.runtime, obj, atom_id)) {
                .value => |lookup| {
                    installOwnDataIc(function, site_pc, ctx.runtime, obj, atom_id, lookup.index);
                    try stack.push(lookup.value);
                    return .done;
                },
                .missing, .slow => {},
            }
            switch (fastImmediatePrototypeDataPropertyLookup(ctx.runtime, obj, atom_id)) {
                .value => |lookup| {
                    installProtoDataIc(function, site_pc, ctx.runtime, obj, atom_id, lookup.holder, lookup.index);
                    try stack.push(lookup.value);
                    return .done;
                },
                .missing, .slow => {},
            }
            switch (fastOrdinaryDataPropertyLookup(ctx.runtime, obj, atom_id)) {
                .value => |value| {
                    try stack.push(value);
                    return .done;
                },
                .undefined => {
                    try stack.pushOwned(core.JSValue.undefinedValue());
                    return .done;
                },
                .slow => {},
            }
            if (fastRegExpPrototypeMethodValue(ctx.runtime, obj, atom_id)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            if (fastFunctionOwnDataPropertyValue(ctx.runtime, obj, atom_id)) |value| {
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
            if (try setCachedOwnDataProperty(ctx.runtime, function, site_pc, obj, atom_id, value)) return .done;
            if (try tryFastSetObjectDataPropertyForPutField(ctx.runtime, obj, atom_id, value)) {
                installOwnDataIcAfterWrite(function, site_pc, ctx.runtime, obj, atom_id);
                return .done;
            }
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

fn tryFastSetObjectDataPropertyForPutField(rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom, value: core.JSValue) !bool {
    if (rt.atoms.kind(atom_id) == .private) return false;
    const object = objectFromValue(receiver) orelse return false;
    if (object.proxyTarget() != null or object.exotic != null) return false;
    if (builtins.buffer.isTypedArrayObject(object)) return false;
    if (object.is_array) {
        if (atom_id == core.atom.ids.length or core.array.arrayIndexFromAtom(&rt.atoms, atom_id) != null) return false;
    }
    if (object.class_id == core.class.ids.regexp and atom_id == core.atom.ids.lastIndex and object.regexpLastIndex() != null) return false;
    return try object.setOrDefineOwnDataPropertyForSimpleSet(rt, atom_id, value);
}

fn tryFuseMathMinMaxPrimitiveCallFromField2(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    receiver: core.JSValue,
    atom_id: core.Atom,
) !bool {
    const method = fastOwnDataPropertyBorrowedValueMaterialized(ctx.runtime, receiver, atom_id) orelse return false;
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
    const method = fastOwnDataPropertyBorrowedValueMaterialized(rt, receiver, atom_id) orelse return null;
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
    const native_ref = fastFunctionOwnNativeBuiltinIdAtPc(function, site_pc, ctx.runtime, receiver, atom_id) orelse return false;
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
    const native_ref = fastFunctionOwnNativeBuiltinIdAtPc(function, field_pc, ctx.runtime, receiver, method_atom) orelse return false;
    if (native_ref.domain != .string or native_ref.id != @intFromEnum(builtins.string.StaticMethod.from_char_code)) return false;

    const argument = stringFromCharCodeInt32Arg(function, frame, field_pc + 5) orelse return false;
    if (argument.next_pc + 3 > code.len or code[argument.next_pc] != op.call_method) return false;
    if (readInt(u16, code[argument.next_pc + 1 ..][0..2]) != 1) return false;

    return try tryFuseStringFromCharCodeInt32LocalAppend(ctx, function, global, frame, stack, argument.value, argument.next_pc + 3, false, false, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
}

fn tryFuseStringFromCharCodeInt32LocalAppend(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    char_code: i32,
    add_pc: usize,
    receiver_on_stack: bool,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const unit: u16 = @intCast(@as(u32, @bitCast(char_code)) & 0xffff);
    if (unit > 0xff) return false;
    const code = function.code;
    if (add_pc >= code.len or code[add_pc] != op.add) return false;

    var store_pc = add_pc + 1;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const candidate_store = decodeLocalPut(code, store_pc) orelse return false;
        const candidate_drop_pc = candidate_store.operand_pc + candidate_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const store = decodeLocalPut(code, store_pc) orelse return false;
    const idx = store.idx;
    if (idx >= frame.locals.len or idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(idx)) return false;
    if (idx < function.var_is_const.len and function.var_is_const[idx]) return false;
    const required_stack: usize = if (receiver_on_stack) 2 else 1;
    if (stack.values.len < required_stack) return false;

    const lhs_index = stack.values.len - required_stack;
    const lhs = stack.values[lhs_index];
    if (!frame.locals[idx].same(lhs)) return false;
    const has_global_sync_mirror =
        sync_global_lexical_locals and
        frame.global_lexical_sync_checked and
        idx < frame.global_lexical_sync_slots.len and
        frame.global_lexical_sync_slots[idx];
    const max_ref_count: usize = if (has_global_sync_mirror) 3 else 2;
    const lhs_string = stringFromValue(lhs) orelse return false;
    const byte: u8 = @intCast(unit);
    const lhs_header = lhs.refHeader() orelse return false;
    const appended_in_place = @as(usize, @intCast(lhs_header.rc)) <= max_ref_count and
        try lhs_string.appendLatin1InPlace(ctx.runtime, &.{byte});
    var replacement = core.JSValue.undefinedValue();
    var replacement_owned = false;
    errdefer if (replacement_owned) replacement.free(ctx.runtime);
    if (!appended_in_place) {
        const lhs_bytes = lhs_string.borrowLatin1() orelse return false;
        replacement = (try core.string.String.createLatin1Concat(ctx.runtime, lhs_bytes, &.{byte})).value();
        replacement_owned = true;
    }

    if (receiver_on_stack) {
        const receiver_owned = try stack.pop();
        receiver_owned.free(ctx.runtime);
    }
    const lhs_owned = try stack.pop();
    lhs_owned.free(ctx.runtime);
    if (replacement_owned) {
        try setSlotValue(ctx, &frame.locals[idx], replacement);
        replacement_owned = false;
    }
    frame.pc = if (drop_pc) |drop| drop + 1 else store.operand_pc + store.consume;
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
    _ = try tryFuseFollowingLocalStringLengthGtConstSliceConstBranch(ctx, function, global, frame, idx, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    _ = try tryFuseDroppedLocalPostUpdateGoto8AtPc(ctx, function, global, frame, frame.pc, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    return true;
}

fn tryFuseLocalStringFromCharCodeInt32AppendFromGet(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    local_idx: u16,
    global_pc: usize,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const code = function.code;
    if (global_pc + 10 > code.len) return false;
    const global_op = code[global_pc];
    if (global_op != op.get_var and global_op != op.get_var_undef) return false;
    const global_atom = readInt(u32, code[global_pc + 1 ..][0..4]);
    if (global_atom != atom_string) return false;

    const string_ctor = fastInstalledGlobalDataValueForAtomAtPc(ctx, function, global, frame, global_pc, global_atom, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
    const field_pc = global_pc + 5;
    if (code[field_pc] != op.get_field2) return false;
    const method_atom = readInt(u32, code[field_pc + 1 ..][0..4]);
    const native_ref = fastFunctionOwnNativeBuiltinIdAtPc(function, field_pc, ctx.runtime, string_ctor, method_atom) orelse return false;
    if (native_ref.domain != .string or native_ref.id != @intFromEnum(builtins.string.StaticMethod.from_char_code)) return false;

    const argument = stringFromCharCodeInt32Arg(function, frame, field_pc + 5) orelse return false;
    if (argument.next_pc + 3 > code.len or code[argument.next_pc] != op.call_method) return false;
    if (readInt(u16, code[argument.next_pc + 1 ..][0..2]) != 1) return false;

    return try tryStoreStringFromCharCodeInt32LocalAppend(ctx, function, global, frame, local_idx, argument.value, argument.next_pc + 3, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
}

fn tryStoreStringFromCharCodeInt32LocalAppend(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    local_idx: u16,
    char_code: i32,
    add_pc: usize,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const unit: u16 = @intCast(@as(u32, @bitCast(char_code)) & 0xffff);
    if (unit > 0xff) return false;
    const code = function.code;
    if (add_pc >= code.len or code[add_pc] != op.add) return false;

    var store_pc = add_pc + 1;
    var drop_pc: ?usize = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const candidate_store = decodeLocalPut(code, store_pc) orelse return false;
        const candidate_drop_pc = candidate_store.operand_pc + candidate_store.consume;
        if (candidate_drop_pc >= code.len or code[candidate_drop_pc] != op.drop) return false;
        drop_pc = candidate_drop_pc;
    }
    const store = decodeLocalPut(code, store_pc) orelse return false;
    if (store.idx != local_idx) return false;
    if (local_idx >= frame.locals.len or local_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(local_idx)) return false;
    if (local_idx < function.var_is_const.len and function.var_is_const[local_idx]) return false;

    const lhs = slotValueBorrowed(frame.locals[local_idx]);
    const lhs_string = stringFromValue(lhs) orelse return false;
    const byte: u8 = @intCast(unit);
    const has_global_sync_mirror =
        sync_global_lexical_locals and
        frame.global_lexical_sync_checked and
        local_idx < frame.global_lexical_sync_slots.len and
        frame.global_lexical_sync_slots[local_idx];
    const max_ref_count: usize = if (has_global_sync_mirror) 2 else 1;
    const lhs_header = lhs.refHeader() orelse return false;
    const appended_in_place = @as(usize, @intCast(lhs_header.rc)) <= max_ref_count and
        try lhs_string.appendLatin1InPlace(ctx.runtime, &.{byte});
    if (!appended_in_place) {
        const lhs_bytes = lhs_string.borrowLatin1() orelse return false;
        const replacement = (try core.string.String.createLatin1Concat(ctx.runtime, lhs_bytes, &.{byte})).value();
        try setSlotValue(ctx, &frame.locals[local_idx], replacement);
    }
    if (local_idx < function.var_is_lexical.len and function.var_is_lexical[local_idx]) {
        frame.clearLocalUninitialized(local_idx);
    }
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, local_idx, sync_global_lexical_locals);
    frame.pc = if (drop_pc) |drop| drop + 1 else store.operand_pc + store.consume;
    _ = try tryFuseFollowingLocalStringLengthGtConstSliceConstBranch(ctx, function, global, frame, local_idx, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    _ = try tryFuseDroppedLocalPostUpdateGoto8AtPc(ctx, function, global, frame, frame.pc, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    return true;
}

fn tryFuseFollowingLocalStringLengthGtConstSliceConstBranch(
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
    return try tryFuseLocalStringLengthGtConstSliceConstBranchFromGet(ctx, function, global, frame, local_idx, get.next_pc, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
}

const StringSliceConstLocalStore = struct {
    start: usize,
    len: usize,
    store: LocalPut,
};

fn decodeStringSliceConstLocalStore(
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

fn storeStringSliceConstLocal(
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

fn tryFuseLocalStringLengthGtConstSliceConstBranchFromGet(
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

fn tryFuseLocalStringSliceConstLocalStoreFromGet(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    local_idx: u16,
    field_pc: usize,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    const code = function.code;
    if (field_pc + 5 > code.len or code[field_pc] != op.get_field2) return false;
    const receiver = localReadableBorrowed(frame, local_idx, false) orelse return false;
    const atom_id = readInt(u32, code[field_pc + 1 ..][0..4]);
    const decoded = decodeStringSliceConstLocalStore(ctx, function, global, frame, receiver, atom_id, field_pc + 5) orelse return false;
    try storeStringSliceConstLocal(ctx, function, global, frame, receiver, decoded, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
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

const StringFromCharCodeInt32Arg = struct {
    value: i32,
    next_pc: usize,
};

fn stringFromCharCodeInt32Arg(
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

    const native_ref = fastFunctionOwnNativeBuiltinIdAtPc(function, site_pc, ctx.runtime, receiver, atom_id) orelse return false;
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
    const native_ref = fastFunctionOwnNativeBuiltinIdAtPc(function, site_pc, ctx.runtime, receiver, atom_id) orelse return false;
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
        if (isHostOutputFunctionValue(outer_callee)) {
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

const NumberStaticLiteralResult = struct {
    number: f64,
    next_pc: usize,
};

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

fn isHostOutputFunctionValue(value: core.JSValue) bool {
    const object = objectFromValue(value) orelse return false;
    return object.hostFunctionKindSlot().* == core.host_function.ids.output;
}

fn atomAsciiText(rt: *core.JSRuntime, atom_id: core.Atom, buffer: []u8) ?[]const u8 {
    if (core.atom.isTaggedInt(atom_id)) {
        return std.fmt.bufPrint(buffer, "{d}", .{core.atom.atomToUInt32(atom_id)}) catch return null;
    }
    if (rt.atoms.kind(atom_id) != .string) return null;
    const text = rt.atoms.name(atom_id) orelse return null;
    if (!asciiBytes(text)) return null;
    return text;
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

fn putInt32TypedArrayElementFast(rt: *core.JSRuntime, obj: core.JSValue, key: core.JSValue, value: core.JSValue) !bool {
    const object = objectFromValue(obj) orelse return false;
    if (!builtins.buffer.isTypedArrayObject(object)) return false;
    const key_int = key.asInt32() orelse return false;
    if (key_int < 0) return false;
    const value_int = value.asInt32() orelse return false;
    return try builtins.buffer.typedArraySetInt32IndexFast(rt, object, @intCast(key_int), value_int);
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

    const input_bytes = ctx.runtime.atoms.name(input_atom) orelse return false;
    const matched = try shared_vm.qjsRegExpTestFastNoResultLatin1(ctx, regexp_object, input_bytes) orelse return false;

    const stacked_receiver = try stack.pop();
    stacked_receiver.free(ctx.runtime);
    const next_pc = pc + 8;
    if (tryFuseBooleanIfFalseBranch(function, frame, next_pc, matched)) return true;
    try stack.pushOwned(core.JSValue.boolean(matched));
    frame.pc = next_pc;
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

fn canUseFastGlobalVarLookup(
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

fn canUseInstalledGlobalDataIc(
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

fn functionFrameBindingShadowsGlobal(rt: *core.JSRuntime, function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, atom_id: core.Atom) bool {
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

fn canFuseGlobalDataWrite(
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

fn frameHasVarRefBinding(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, atom_id: core.Atom) bool {
    const count = @min(frame.var_refs.len, function.var_ref_names.len);
    for (function.var_ref_names[0..count]) |name| {
        if (name == atom_id) return true;
    }
    return false;
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

fn fastOrdinaryDataPropertyBorrowedValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    return switch (fastOrdinaryDataPropertyLookup(rt, value, atom_id)) {
        .value => |property_value| property_value,
        .undefined, .slow => null,
    };
}

fn invariantInt32LoadValue(rt: *core.JSRuntime, receiver: core.JSValue, code: []const u8, pc: usize) ?InvariantInt32Load {
    if (pc >= code.len) return null;
    if (code[pc] == op.get_field) {
        if (pc + 5 > code.len) return null;
        const atom_id = readInt(u32, code[pc + 1 ..][0..4]);
        const value = fastOrdinaryDataPropertyBorrowedValue(rt, receiver, atom_id) orelse return null;
        return .{ .value = value.asInt32() orelse return null, .next_pc = pc + 5 };
    }

    const index = smallPushOpcodeIndex(code[pc]) orelse return null;
    if (pc + 2 > code.len or code[pc + 1] != op.get_array_el) return null;
    const object = objectFromValue(receiver) orelse return null;
    if (object.proxyTarget() != null or object.exotic != null) return null;
    if (!object.is_array or object.arrayElementStorageMode() != .dense) return null;
    if (index >= @as(usize, @intCast(object.length))) return null;
    const elements = object.arrayElements();
    if (index >= elements.len) return null;
    const element = elements[index] orelse return null;
    return .{ .value = element.asInt32() orelse return null, .next_pc = pc + 2 };
}

fn denseArrayInt32RangeDelta(object: *core.Object, start: usize, limit: usize) ?IntRangeDeltaBounds {
    if (start > limit) return null;
    if (object.proxyTarget() != null or object.exotic != null) return null;
    if (!object.is_array or object.arrayElementStorageMode() != .dense) return null;
    if (limit > @as(usize, @intCast(object.length))) return null;
    const elements = object.arrayElements();
    if (limit > elements.len) return null;

    var total: i128 = 0;
    var min_delta: i128 = 0;
    var max_delta: i128 = 0;
    for (elements[start..limit]) |maybe_element| {
        const value = maybe_element orelse return null;
        total += value.asInt32() orelse return null;
        min_delta = @min(min_delta, total);
        max_delta = @max(max_delta, total);
    }
    return .{
        .total = total,
        .min = min_delta,
        .max = max_delta,
    };
}

fn denseArrayModFieldInt32Increments(rt: *core.JSRuntime, array_value: core.JSValue, field_atom: core.Atom, modulus: usize) ?DenseArrayModFieldIncrements {
    const array_object = objectFromValue(array_value) orelse return null;
    if (array_object.proxyTarget() != null or array_object.exotic != null) return null;
    if (!array_object.is_array or array_object.arrayElementStorageMode() != .dense) return null;
    if (modulus > @as(usize, @intCast(array_object.length))) return null;
    const elements = array_object.arrayElements();
    if (modulus > elements.len) return null;
    var increments = DenseArrayModFieldIncrements{ .values = undefined, .len = modulus };
    if (modulus > increments.values.len) return null;
    for (0..modulus) |index| {
        const element = elements[index] orelse return null;
        const field_value = fastOrdinaryDataPropertyBorrowedValue(rt, element, field_atom) orelse return null;
        const int_value = field_value.asInt32() orelse return null;
        if (int_value < 0) return null;
        increments.values[index] = int_value;
    }
    return increments;
}

fn periodicNonNegativeDelta(start: i32, limit: i32, increments: DenseArrayModFieldIncrements) ?i128 {
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

fn fastOwnDataPropertyBorrowedValueMaterialized(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    if (rt.atoms.kind(atom_id) == .private) return null;
    const object = objectFromValue(value) orelse return null;
    if (object.proxyTarget() != null or object.exotic != null) return null;
    if (object.class_id != core.class.ids.object and !object.is_global) return null;

    switch (fastOwnOrdinaryDataPropertyBorrowedValue(object, atom_id)) {
        .value => |stored| return stored,
        .missing => return null,
        .slow => {},
    }

    const desc = object.getOwnProperty(atom_id) orelse return null;
    defer desc.destroy(rt);
    if (desc.kind != .data or !desc.value_present) return null;

    return switch (fastOwnOrdinaryDataPropertyBorrowedValue(object, atom_id)) {
        .value => |stored| stored,
        .missing, .slow => null,
    };
}

fn fastLengthValue(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    if (value.isString()) {
        const header = value.refHeader() orelse return error.TypeError;
        const string_value: *core.string.String = @fieldParentPtr("header", header);
        return core.JSValue.int32(@intCast(string_value.len()));
    }
    const object = objectFromValue(value) orelse return error.TypeError;
    if (object.proxyTarget() != null) return error.TypeError;
    if (object.is_array) {
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

fn fastOrdinaryDataPropertyLookup(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) FastOrdinaryDataLookupResult {
    if (rt.atoms.kind(atom_id) == .private) return .slow;
    var cursor = objectFromValue(value) orelse return .slow;
    while (true) {
        if (cursor.proxyTarget() != null or cursor.exotic != null) return .slow;
        if (cursor.is_array) {
            if (atom_id == core.atom.ids.length or core.array.arrayIndexFromAtom(&rt.atoms, atom_id) != null) return .slow;
        } else if (cursor.class_id != core.class.ids.object and !cursor.is_global) return .slow;
        switch (fastOwnOrdinaryDataPropertyBorrowedValue(cursor, atom_id)) {
            .value => |property_value| return .{ .value = property_value },
            .missing => cursor = cursor.getPrototype() orelse {
                if (cursor.is_array) return .slow;
                return .undefined;
            },
            .slow => return .slow,
        }
    }
}

const FastOrdinaryDataLookupResult = union(enum) {
    value: core.JSValue,
    undefined,
    slow,
};

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

fn ownPrototypeEntryIsNativeBuiltinDefault(proto: *const core.Object, atom_id: core.Atom, domain: core.function.NativeBuiltinDomain, expected_id: u32) bool {
    if (proto.exotic != null) return false;
    for (proto.properties) |entry| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        if (entry.flags.accessor) return false;
        return switch (entry.slot) {
            .data => |method| nativeBuiltinFunctionValueMatches(method, domain, expected_id),
            .auto_init => |info| autoInitNativeBuiltinMatches(info, domain, expected_id),
            .accessor, .deleted => false,
        };
    }
    return false;
}

fn fastRegExpPrototypeMethodIsDefault(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom, expected_id: u32) bool {
    _ = rt;
    const object = objectFromValue(value) orelse return false;
    if (object.class_id != core.class.ids.regexp) return false;
    if (object.hasOwnProperty(atom_id)) return false;
    const proto = object.getPrototype() orelse return false;
    return ownPrototypeEntryIsNativeBuiltinDefault(proto, atom_id, .regexp, expected_id);
}

fn fastCollectionPrototypeMethodIsDefault(value: core.JSValue, atom_id: core.Atom, expected_id: u32) bool {
    const object = objectFromValue(value) orelse return false;
    if (object.hasOwnProperty(atom_id)) return false;
    const proto = object.getPrototype() orelse return false;
    return ownPrototypeEntryIsNativeBuiltinDefault(proto, atom_id, .collection, expected_id);
}

fn fastArrayPrototypeMethodIsDefault(value: core.JSValue, atom_id: core.Atom, expected_id: u32) bool {
    const object = objectFromValue(value) orelse return false;
    if (!object.is_array or object.hasOwnProperty(atom_id)) return false;
    const proto = object.getPrototype() orelse return false;
    return ownPrototypeEntryIsNativeBuiltinDefault(proto, atom_id, .array, expected_id);
}

fn fastStringPrototypeMethodIsDefault(rt: *core.JSRuntime, global: *core.Object, atom_id: core.Atom, expected_id: u32) bool {
    if (!value_ops.atomNameEql(rt, atom_id, "slice")) return false;
    const proto = shared_vm.constructorPrototypeFromGlobalAtom(rt, global, atom_string) orelse return false;
    return ownPrototypeEntryIsNativeBuiltinDefault(proto, atom_id, .string, expected_id);
}

fn fastCollectionPrototypeMethodValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    const object = objectFromValue(value) orelse return null;
    const expected_id = expectedCollectionMethodId(rt, object.class_id, atom_id) orelse return null;
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

fn expectedCollectionMethodId(rt: *core.JSRuntime, class_id: core.ClassId, atom_id: core.Atom) ?u32 {
    const name = rt.atoms.name(atom_id) orelse return null;
    return switch (class_id) {
        core.class.ids.map, core.class.ids.weakmap => {
            if (std.mem.eql(u8, name, "set")) return @intFromEnum(builtins.collection.PrototypeMethod.set);
            if (std.mem.eql(u8, name, "get")) return @intFromEnum(builtins.collection.PrototypeMethod.get);
            if (std.mem.eql(u8, name, "has")) return @intFromEnum(builtins.collection.PrototypeMethod.has);
            if (std.mem.eql(u8, name, "delete")) return @intFromEnum(builtins.collection.PrototypeMethod.delete);
            return null;
        },
        core.class.ids.set, core.class.ids.weakset => {
            if (std.mem.eql(u8, name, "add")) return @intFromEnum(builtins.collection.PrototypeMethod.add);
            if (std.mem.eql(u8, name, "has")) return @intFromEnum(builtins.collection.PrototypeMethod.has);
            if (std.mem.eql(u8, name, "delete")) return @intFromEnum(builtins.collection.PrototypeMethod.delete);
            return null;
        },
        else => null,
    };
}

fn fastFunctionOwnDataPropertyValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    const object = objectFromValue(value) orelse return null;
    if (!isFunctionLikeClassId(object.class_id)) return null;
    if (atom_id == core.atom.ids.arguments or value_ops.atomNameEql(rt, atom_id, "caller")) return null;
    return object.getOwnDataPropertyValue(atom_id);
}

fn fastFunctionOwnNativeBuiltinIdAtPc(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    value: core.JSValue,
    atom_id: core.Atom,
) ?core.function.NativeBuiltinRef {
    const object = objectFromValue(value) orelse return null;
    if (!isFunctionLikeClassId(object.class_id)) return null;
    if (atom_id == core.atom.ids.arguments or value_ops.atomNameEql(rt, atom_id, "caller")) return null;
    if (object.exotic != null) return null;

    if (cachedOwnDataPropertyLookupForObjectNoProfile(function, site_pc, object, atom_id)) |lookup| {
        return nativeBuiltinRefFromFunctionValue(lookup.value);
    }

    for (object.properties, 0..) |entry, index| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        if (entry.flags.accessor) return null;
        switch (entry.slot) {
            .data => |stored| {
                const native_ref = nativeBuiltinRefFromFunctionValue(stored) orelse return null;
                installOwnDataIcForObject(function, site_pc, rt, object, atom_id, index);
                return native_ref;
            },
            .auto_init => {
                const materialized = object.getProperty(atom_id);
                defer materialized.free(rt);
                const native_ref = nativeBuiltinRefFromFunctionValue(materialized) orelse return null;
                if (index < object.properties.len) {
                    const current = object.properties[index];
                    if (!current.flags.deleted and
                        !current.flags.accessor and
                        current.atom_id == atom_id)
                    {
                        switch (current.slot) {
                            .data => installOwnDataIcForObject(function, site_pc, rt, object, atom_id, index),
                            .auto_init, .accessor, .deleted => {},
                        }
                    }
                }
                return native_ref;
            },
            .accessor, .deleted => return null,
        }
    }
    return null;
}

fn nativeBuiltinRefFromFunctionValue(value: core.JSValue) ?core.function.NativeBuiltinRef {
    const function_object = objectFromValue(value) orelse return null;
    return core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*);
}

fn isFunctionLikeClassId(class_id: core.ClassId) bool {
    return class_id == core.class.ids.c_function or
        class_id == core.class.ids.bytecode_function or
        class_id == core.class.ids.bound_function or
        class_id == core.class.ids.c_function_data or
        class_id == core.class.ids.c_closure;
}

const FastOwnDataResult = union(enum) {
    value: core.JSValue,
    missing,
    slow,
};

const FastOwnDataLookup = union(enum) {
    value: BorrowedOwnDataLookup,
    missing,
    slow,
};

const BorrowedOwnDataLookup = struct {
    index: usize,
    value: core.JSValue,
};

const BorrowedProtoDataLookup = struct {
    holder: *core.Object,
    index: usize,
    value: core.JSValue,
};

const FastProtoDataLookup = union(enum) {
    value: BorrowedProtoDataLookup,
    missing,
    slow,
};

fn cachedOwnDataPropertyValue(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
) ?core.JSValue {
    const object = cacheableOwnDataReceiver(rt, receiver, atom_id) orelse return null;
    const lookup = cachedOwnDataPropertyLookupForObject(function, site_pc, rt, object, atom_id) orelse return null;
    return lookup.value;
}

fn cachedProtoDataPropertyValue(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
) ?core.JSValue {
    const object = cacheableOwnDataReceiver(rt, receiver, atom_id) orelse return null;
    const lookup = cachedProtoDataPropertyLookupForObject(function, site_pc, rt, object, atom_id) orelse return null;
    return lookup.value;
}

fn installOwnDataIc(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
    index: usize,
) void {
    const object = cacheableOwnDataReceiver(rt, receiver, atom_id) orelse return;
    installOwnDataIcForObject(function, site_pc, rt, object, atom_id, index);
}

fn installOwnDataIcAfterWrite(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
) void {
    switch (fastOwnOrdinaryDataPropertyLookup(rt, receiver, atom_id)) {
        .value => |lookup| installOwnDataIc(function, site_pc, rt, receiver, atom_id, lookup.index),
        .missing, .slow => {},
    }
}

fn installProtoDataIc(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
    holder: *core.Object,
    index: usize,
) void {
    const object = cacheableOwnDataReceiver(rt, receiver, atom_id) orelse return;
    if (!cacheableNamedDataObject(rt, holder, atom_id)) return;
    const slot = icSlot(function, site_pc) orelse return;
    recordOwnDataIcInstall(rt, slot.installProtoData(&rt.shapes, object, holder, atom_id, index));
}

fn setCachedOwnDataProperty(
    rt: *core.JSRuntime,
    function: *const bytecode.Bytecode,
    site_pc: usize,
    receiver: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
) !bool {
    const object = cacheableOwnDataReceiver(rt, receiver, atom_id) orelse return false;
    const cached = cachedOwnDataPropertyLookupForObject(function, site_pc, rt, object, atom_id) orelse return false;
    return try setOwnDataPropertyAt(rt, object, cached.index, atom_id, value);
}

fn cachedOwnDataPropertyLookupForObject(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    object: *core.Object,
    atom_id: core.Atom,
) ?BorrowedOwnDataLookup {
    const slot = icSlot(function, site_pc) orelse return null;
    const index = switch (slot.lookupOwnDataResult(object, atom_id)) {
        .hit => |index| index,
        .miss => {
            recordOwnDataIcMiss(rt);
            return null;
        },
        .invalidated => {
            recordOwnDataIcInvalidate(rt);
            return null;
        },
    };
    const value = ownDataPropertyBorrowedAt(object, index, atom_id) orelse {
        recordOwnDataIcInvalidate(rt);
        return null;
    };
    recordOwnDataIcHit(rt);
    return .{ .index = index, .value = value };
}

fn cachedOwnDataPropertyLookupForObjectNoProfile(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    object: *core.Object,
    atom_id: core.Atom,
) ?BorrowedOwnDataLookup {
    const slot = icSlot(function, site_pc) orelse return null;
    const index = switch (slot.lookupOwnDataResult(object, atom_id)) {
        .hit => |index| index,
        .miss, .invalidated => return null,
    };
    const value = ownDataPropertyBorrowedAt(object, index, atom_id) orelse return null;
    return .{ .index = index, .value = value };
}

fn cachedProtoDataPropertyLookupForObject(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    object: *core.Object,
    atom_id: core.Atom,
) ?BorrowedProtoDataLookup {
    const slot = icSlot(function, site_pc) orelse return null;
    const hit = switch (slot.lookupProtoDataResult(object, atom_id)) {
        .hit => |hit| hit,
        .miss => {
            recordOwnDataIcMiss(rt);
            return null;
        },
        .invalidated => {
            recordOwnDataIcInvalidate(rt);
            return null;
        },
    };
    const value = ownDataPropertyBorrowedAt(hit.holder, hit.slot_index, atom_id) orelse {
        recordOwnDataIcInvalidate(rt);
        return null;
    };
    recordOwnDataIcHit(rt);
    return .{ .holder = hit.holder, .index = hit.slot_index, .value = value };
}

fn installOwnDataIcForObject(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    object: *core.Object,
    atom_id: core.Atom,
    index: usize,
) void {
    if (rt.atoms.kind(atom_id) == .private) return;
    const slot = icSlot(function, site_pc) orelse return;
    recordOwnDataIcInstall(rt, slot.installOwnData(&rt.shapes, object, atom_id, index));
}

fn recordOwnDataIcHit(rt: *core.JSRuntime) void {
    const profile = rt.opcode_profile orelse return;
    profile.recordIcHit(core.profile.activeOpcode());
}

fn recordOwnDataIcMiss(rt: *core.JSRuntime) void {
    const profile = rt.opcode_profile orelse return;
    profile.recordIcMiss(core.profile.activeOpcode());
}

fn recordOwnDataIcInvalidate(rt: *core.JSRuntime) void {
    const profile = rt.opcode_profile orelse return;
    profile.recordIcInvalidate(core.profile.activeOpcode());
}

fn recordOwnDataIcInstall(rt: *core.JSRuntime, result: bytecode.ic.InstallResult) void {
    _ = rt;
    const profile = core.profile.active() orelse return;
    const opcode = core.profile.activeOpcode();
    switch (result) {
        .unchanged, .installed_mono, .updated => {},
        .promoted_poly => profile.recordIcPromotePoly(opcode),
        .promoted_mega => profile.recordIcPromoteMega(opcode),
    }
}

fn icSlot(function: *const bytecode.Bytecode, site_pc: usize) ?*bytecode.ic.Slot {
    return function.icSlotForPc(site_pc);
}

fn cacheableOwnDataReceiver(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?*core.Object {
    if (rt.atoms.kind(atom_id) == .private) return null;
    const object = objectFromValue(value) orelse return null;
    if (!cacheableNamedDataObject(rt, object, atom_id)) return null;
    return object;
}

fn cacheableNamedDataObject(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) bool {
    if (object.proxyTarget() != null or object.exotic != null) return false;
    if (object.is_array) {
        if (atom_id == core.atom.ids.length or core.array.arrayIndexFromAtom(&rt.atoms, atom_id) != null) return false;
    } else if (object.class_id != core.class.ids.object and !object.is_global and object.class_id < core.class.ids.init_count) return false;
    return true;
}

fn fastOwnOrdinaryDataPropertyLookup(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) FastOwnDataLookup {
    const object = cacheableOwnDataReceiver(rt, value, atom_id) orelse return .slow;
    return fastOwnOrdinaryDataPropertyLookupForObject(object, atom_id);
}

fn fastImmediatePrototypeDataPropertyLookup(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) FastProtoDataLookup {
    const object = cacheableOwnDataReceiver(rt, value, atom_id) orelse return .slow;
    switch (fastOwnOrdinaryDataPropertyLookupForObject(object, atom_id)) {
        .value, .slow => return .slow,
        .missing => {},
    }
    const holder = object.getPrototype() orelse return .missing;
    if (!cacheableNamedDataObject(rt, holder, atom_id)) return .slow;
    return switch (fastOwnOrdinaryDataPropertyLookupForObject(holder, atom_id)) {
        .value => |lookup| .{ .value = .{ .holder = holder, .index = lookup.index, .value = lookup.value } },
        .missing => .missing,
        .slow => .slow,
    };
}

fn fastOwnOrdinaryDataPropertyLookupForObject(object: *core.Object, atom_id: core.Atom) FastOwnDataLookup {
    for (object.properties, 0..) |*entry, index| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        if (entry.flags.accessor) return .slow;
        return switch (entry.slot) {
            .data => |stored| .{ .value = .{ .index = index, .value = stored } },
            .auto_init, .accessor => .slow,
            .deleted => .missing,
        };
    }
    return .missing;
}

fn ownDataPropertyBorrowedAt(object: *core.Object, index: usize, atom_id: core.Atom) ?core.JSValue {
    if (object.exotic != null or index >= object.properties.len) return null;
    const entry = &object.properties[index];
    if (entry.atom_id != atom_id or entry.flags.deleted or entry.flags.accessor) return null;
    return switch (entry.slot) {
        .data => |stored| stored,
        .auto_init, .accessor, .deleted => null,
    };
}

fn setOwnDataPropertyAt(rt: *core.JSRuntime, object: *core.Object, index: usize, atom_id: core.Atom, value: core.JSValue) !bool {
    if (object.exotic != null or index >= object.properties.len) return false;
    const entry = &object.properties[index];
    if (entry.atom_id != atom_id or entry.flags.deleted or entry.flags.accessor or !entry.flags.writable) return false;
    return switch (entry.slot) {
        .data => |*stored| {
            if (atom_id != core.atom.ids.Private_brand and !stored.requiresRefCount() and !value.requiresRefCount()) {
                stored.* = value;
                return true;
            }
            const next_value = core.object.dupPropertyDataValue(&rt.atoms, atom_id, value);
            errdefer core.object.destroyPropertySlot(rt, entry.atom_id, .{ .data = next_value });
            try rt.writeBarrierValueAt(&object.header, next_value, stored);
            const old_value = stored.*;
            stored.* = next_value;
            core.object.destroyPropertySlot(rt, entry.atom_id, .{ .data = old_value });
            return true;
        },
        .auto_init, .accessor, .deleted => false,
    };
}

fn fastOwnOrdinaryDataPropertyBorrowedValue(object: *core.Object, atom_id: core.Atom) FastOwnDataResult {
    for (object.properties) |*entry| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        if (entry.flags.accessor) return .slow;
        return switch (entry.slot) {
            .data => |stored| .{ .value = stored },
            .auto_init, .accessor => .slow,
            .deleted => .missing,
        };
    }
    return .missing;
}

fn fastDenseArrayElementValue(value: core.JSValue, key: core.JSValue) ?core.JSValue {
    const index_i32 = key.asInt32() orelse return null;
    if (index_i32 < 0) return null;
    const object = objectFromValue(value) orelse return null;
    if (object.proxyTarget() != null or object.exotic != null) return null;
    if (!object.is_array or object.arrayElementStorageMode() != .dense) return null;
    const index: u32 = @intCast(index_i32);
    const atom_id = core.atom.atomFromUInt32(index);
    if (object.properties.len != 0 and object.findProperty(atom_id) != null) return null;
    const elements = object.arrayElements();
    if (@as(usize, @intCast(index_i32)) >= elements.len) return null;
    if (elements[@intCast(index_i32)]) |stored| return stored.dup();
    return null;
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

fn tryFuseLocalAddWithValue(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    rhs: core.JSValue,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (frame.pc + 2 > function.code.len) return false;
    if (function.code[frame.pc] != op.add) return false;
    const lhs = stack.peekBorrowed() orelse return false;
    const store = decodeLocalPut(function.code, frame.pc + 1);
    const var_ref_store = if (store == null) decodeVarRefPut(function.code, frame.pc + 1) else null;
    if (store == null and var_ref_store == null) return false;

    if (store) |local_store| {
        if (local_store.idx >= frame.locals.len or local_store.idx >= frame.locals_uninit.len) return false;
        if (frame.localIsUninitialized(local_store.idx)) return false;
        if (local_store.checked and local_store.idx < function.var_is_const.len and function.var_is_const[local_store.idx]) return false;
        if (!frame.locals[local_store.idx].same(lhs)) return false;
    } else if (var_ref_store) |ref_store| {
        if (!varRefStoreWritableForFastPath(ctx, function, global, frame, ref_store)) return false;
        const stored = varRefReadableBorrowed(frame, ref_store.idx) orelse return false;
        if (!stored.same(lhs)) return false;
    }

    const updated = blk: {
        if (lhs.asInt32()) |lhs_int| {
            if (rhs.asInt32()) |rhs_int| break :blk fastInt32Add(lhs_int, rhs_int);
        }
        if (lhs.asShortBigInt()) |lhs_bigint| {
            if (rhs.asShortBigInt()) |rhs_bigint| {
                if (value_ops.shortBigIntBinary(op.add, lhs_bigint, rhs_bigint)) |fast| break :blk fast;
            }
        }
        if (lhs.isString() and rhs.isString()) {
            const has_global_sync_mirror =
                sync_global_lexical_locals and
                frame.global_lexical_sync_checked and
                (if (store) |local_store| local_store.idx < frame.global_lexical_sync_slots.len and frame.global_lexical_sync_slots[local_store.idx] else false);
            const max_ref_count: usize = if (has_global_sync_mirror) 3 else 2;

            if (try value_ops.tryAppendStringInPlace(ctx.runtime, lhs, rhs, max_ref_count)) {
                break :blk lhs.dup();
            } else {
                break :blk try value_ops.binary(ctx.runtime, op.add, lhs, rhs);
            }
        }
        if (!lhs.isNumber() or !rhs.isNumber()) return false;
        break :blk try value_ops.binary(ctx.runtime, op.add, lhs, rhs);
    };

    const lhs_owned = try stack.pop();
    lhs_owned.free(ctx.runtime);
    if (store) |local_store| {
        try setSlotValue(ctx, &frame.locals[local_store.idx], updated);
        try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, local_store.idx, sync_global_lexical_locals);
        frame.pc = local_store.operand_pc + local_store.consume;
    } else if (var_ref_store) |ref_store| {
        try setSlotValue(ctx, &frame.var_refs[ref_store.idx], updated);
        frame.pc = ref_store.operand_pc + ref_store.consume;
    }
    return true;
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

fn objectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn stringFromValue(value: core.JSValue) ?*core.string.String {
    if (!value.isString()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
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
                        if (global.exotic == null and !global.is_array and global.isExtensible()) {
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
                const define_result = if (global.exotic == null and !global.is_array and global.isExtensible())
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
            defer value.free(ctx.runtime);
            if (!function.flags.is_indirect_eval) {
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

pub fn closeLoc(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime closeLocalVarRef: anytype,
) !void {
    const idx = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    try closeLocalVarRef(ctx, frame, idx);
}

fn stackValueFromTop(stack: *const stack_mod.Stack, offset: u8) !core.JSValue {
    const index_from_top: usize = offset;
    if (index_from_top >= stack.values.len) return error.StackUnderflow;
    return stack.values[stack.values.len - 1 - index_from_top].dup();
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

test "fast own data property replacement retains private brand atom" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const object = try core.Object.create(rt, core.class.ids.object, null);
    defer object.value().free(rt);

    const brand = try rt.atoms.newSymbol("fastPrivateBrandReplacement", .private);
    try object.defineOwnProperty(
        rt,
        core.atom.ids.Private_brand,
        core.Descriptor.data(core.JSValue.symbol(brand), true, true, true),
    );
    rt.atoms.free(brand);
    try std.testing.expect(rt.atoms.name(brand) != null);

    try std.testing.expect(try setOwnDataPropertyAt(rt, object, 0, core.atom.ids.Private_brand, core.JSValue.symbol(brand)));
    try std.testing.expect(rt.atoms.name(brand) != null);
    const stored = object.getProperty(core.atom.ids.Private_brand);
    try std.testing.expectEqual(@as(?core.Atom, brand), stored.asSymbolAtom());
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

// --- Combined from legacy property_ops.zig ---

pub fn getProperty(object: *core.Object, atom_id: core.Atom) core.JSValue {
    return object.getProperty(atom_id);
}

pub fn setProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !void {
    try object.setProperty(rt, atom_id, value);
}

pub fn defineDataProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !void {
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, true, true, true));
}

pub fn deleteProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) bool {
    return object.deleteProperty(rt, atom_id);
}

pub fn getPropertyValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) !core.JSValue {
    const object_value = try expectObject(value);
    if (object_value.is_global and value_ops.atomNameEql(rt, atom_id, "globalThis")) return object_value.value().dup();
    return object_value.getProperty(atom_id);
}

pub fn setPropertyValue(rt: *core.JSRuntime, object_value: core.JSValue, atom_id: core.Atom, value: core.JSValue) !core.JSValue {
    const object = try expectObject(object_value);
    try object.setProperty(rt, atom_id, value);
    return core.JSValue.undefinedValue();
}

pub fn optionalGetPropertyValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) !core.JSValue {
    _ = rt;
    if (value.isNull() or value.isUndefined()) return core.JSValue.undefinedValue();
    const object_value = try expectObject(value);
    return object_value.getProperty(atom_id);
}

pub fn getIndexValue(value: core.JSValue, index: u32) !core.JSValue {
    const object_value = try expectObject(value);
    return object_value.getProperty(core.atom.atomFromUInt32(index));
}

pub fn propertyIn(rt: *core.JSRuntime, object_value: core.JSValue, key_value: core.JSValue) !core.JSValue {
    const object = try expectObject(object_value);
    const key = try propertyKeyAtom(rt, key_value);
    defer rt.atoms.free(key);
    var found = object.hasProperty(key);
    if (!found and value_ops.atomNameEql(rt, key, "toString")) found = true;
    return core.JSValue.boolean(found);
}

pub fn instanceOfObject(value: core.JSValue) core.JSValue {
    return core.JSValue.boolean(value.isObject());
}

pub fn instanceOfArray(value: core.JSValue) core.JSValue {
    const header = value.refHeader() orelse return core.JSValue.boolean(false);
    if (!value.isObject()) return core.JSValue.boolean(false);
    const object: *core.Object = @fieldParentPtr("header", header);
    return core.JSValue.boolean(object.is_array);
}

pub fn instanceOf(rt: *core.JSRuntime, value: core.JSValue, constructor_value: core.JSValue) !core.JSValue {
    const header = value.refHeader() orelse return core.JSValue.boolean(false);
    if (!value.isObject()) return core.JSValue.boolean(false);
    const object: *core.Object = @fieldParentPtr("header", header);

    const constructor_header = constructor_value.refHeader() orelse return error.TypeError;
    if (!constructor_value.isObject()) return error.TypeError;
    const constructor: *core.Object = @fieldParentPtr("header", constructor_header);
    const prototype_key = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_key);
    const prototype_value = constructor.getProperty(prototype_key);
    defer prototype_value.free(rt);
    const prototype_header = prototype_value.refHeader() orelse return error.TypeError;
    if (!prototype_value.isObject()) return error.TypeError;
    const prototype: *core.Object = @fieldParentPtr("header", prototype_header);

    var cursor = object.getPrototype();
    while (cursor) |candidate| {
        if (candidate == prototype) return core.JSValue.boolean(true);
        cursor = candidate.getPrototype();
    }
    return core.JSValue.boolean(false);
}

pub fn propertyKeyAtom(rt: *core.JSRuntime, value: core.JSValue) !core.Atom {
    if (value.asSymbolAtom()) |atom_id| return rt.atoms.dup(atom_id);
    if (value.isString()) {
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.memory.allocator);
        try value_ops.appendRawString(rt, &bytes, value);
        return rt.internAtom(bytes.items);
    }
    if (value.asInt32()) |index| {
        if (index >= 0) return core.atom.atomFromUInt32(@intCast(index));
    }
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try value_ops.appendValueString(rt, &bytes, value);
    return rt.internAtom(bytes.items);
}

pub fn expectObject(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}
