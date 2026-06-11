const std = @import("std");
const bytecode = @import("../bytecode/root.zig");
const builtins = @import("../builtins/root.zig");
const core = @import("../core/root.zig");
const dtoa = @import("../libs/dtoa.zig");
const unicode_lib = @import("../libs/unicode.zig");
const frame_mod = @import("frame.zig");
const arith_vm = @import("vm_arith.zig");
const property_ic = @import("property_ic.zig");
const property_ops = @import("property_ops.zig");
const shared_vm = @import("shared.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const dataPropertyValueForFastPath = property_ic.dataPropertyValueForFastPath;
const functionOwnDataPropertyValueForFastPath = property_ic.functionOwnDataPropertyValueForFastPath;
const functionOwnNativeBuiltinRefForFastPath = property_ic.functionOwnNativeBuiltinRefForFastPath;
const setGlobalDataPropertyForFastPath = property_ic.setGlobalDataPropertyForFastPath;
const globalDataPropertyValueForFastPath = property_ic.globalDataPropertyValueForFastPath;
const globalDataPropertyValueForFastPathNoProfile = property_ic.globalDataPropertyValueForFastPathNoProfile;
const globalOwnDataPropertyValue = property_ic.globalOwnDataPropertyValue;
const ordinaryDataPropertyBorrowedValueForFastPath = property_ic.ordinaryDataPropertyBorrowedValueForFastPath;
const ordinaryDataPropertyIsUndefinedForFastPath = property_ic.ordinaryDataPropertyIsUndefinedForFastPath;
const ordinaryDataPropertyValueOrUndefinedForFastPath = property_ic.ordinaryDataPropertyValueOrUndefinedForFastPath;
const globalWritableDataStoreAvailableForFastPath = property_ic.globalWritableDataStoreAvailableForFastPath;
const globalWritableDataStoreInt32ForFastPath = property_ic.globalWritableDataStoreInt32ForFastPath;
const setObjectDataPropertyForPutFieldFastPath = property_ic.setObjectDataPropertyForPutFieldFastPath;
const setGlobalWritableDataStoreForFastPathOwned = property_ic.setGlobalWritableDataStoreForFastPathOwned;
const setPlainObjectInt32DataPropertyForFastPath = property_ic.setPlainObjectInt32DataPropertyForFastPath;
const ownDataPropertyValueMaterializedForFastPath = property_ic.ownDataPropertyValueMaterializedForFastPath;
const plainObjectInt32DataPropertiesForFastPath = property_ic.plainObjectInt32DataPropertiesForFastPath;

const op = bytecode.opcode.op;
const atom_date = core.atom.predefinedId("Date", .string).?;
const atom_array_buffer = core.atom.predefinedId("ArrayBuffer", .string).?;
const atom_math = core.atom.predefinedId("Math", .string).?;
const atom_number = core.atom.predefinedId("Number", .string).?;
const atom_print = core.atom.predefinedId("print", .string).?;
const atom_regexp = core.atom.predefinedId("RegExp", .string).?;
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

pub fn checkedLocVm(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    opc: u8,
    catch_target: *?usize,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
    comptime pushSlotValue: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    const idx = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    if (idx >= frame.locals.len or idx >= frame.locals_uninit.len) return error.InvalidBytecode;

    switch (opc) {
        op.set_loc_uninitialized => {
            frame.setLocalUninitialized(idx);
        },
        op.get_loc_check => {
            if (frame.localIsUninitialized(idx)) {
                if (varRefCellFromValue(frame.locals[idx]) != null and !shared_vm.varRefSlotIsUninitialized(frame.locals[idx])) {
                    frame.clearLocalUninitialized(idx);
                } else {
                    const err = shared_vm.throwTdzReference(ctx);
                    if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                }
            }
            if ((frame.pc >= function.code.len or function.code[frame.pc] != op.call0) and
                try tryFuseCheckedLocalFastPath(ctx, function, global, frame, stack, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return .continue_loop;
            try pushSlotValue(stack, frame.locals[idx]);
        },
        op.put_loc_check => {
            if (frame.localIsUninitialized(idx)) {
                const err = shared_vm.throwTdzReference(ctx);
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
            const is_derived_this = function.flags.is_derived_class_constructor and
                idx < function.var_names.len and
                function.var_names[idx] == 8;
            if (is_derived_this and !shared_vm.varRefSlotIsUninitialized(frame.locals[idx])) {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                return error.ReferenceError;
            }
            const value = try stack.pop();
            const constructor_this = if (is_derived_this)
                value.dup()
            else
                core.JSValue.undefinedValue();
            defer constructor_this.free(ctx.runtime);
            try setSlotValue(ctx, &frame.locals[idx], value);
            if (!constructor_this.isUndefined()) {
                try setSlotValue(ctx, &frame.this_value, constructor_this.dup());
            }
            frame.clearLocalUninitialized(idx);
            try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
        },
        else => unreachable,
    }
    return .done;
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

    if (dataPropertyValueForFastPath(function, field_pc, ctx.runtime, receiver, atom_id)) |value| {
        try stack.push(value);
        frame.pc = field_pc + 5;
        return true;
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

pub fn varRefVm(
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
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    return varRef(ctx, function, global, frame, stack, opc, catch_target, eval_global_var_bindings, is_eval_code, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, execGetVarRefMaybeTdz, execPutVarRef, execSetVarRef, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal) catch |err| {
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
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

const OptionalLocalStoreTail = struct {
    store_pc: usize,
    tail_pc: ?usize = null,
    completion_put: ?LocalPut = null,
};

const OptionalBindingStoreTail = struct {
    store_pc: usize,
    tail_pc: ?usize = null,
    completion_put: ?BindingPut = null,
};

const OptionalLocalCompletionTail = struct {
    tail_pc: usize,
    completion_put: ?LocalPut = null,
};

const DenseArrayPutTail = struct {
    tail_pc: usize,
    completion_put: ?LocalPut = null,
};

const SparseArrayLiteralLength = struct {
    length: u32,
    next_pc: usize,
};

const SparseArrayLiteralLengthLocalInit = struct {
    length: u32,
    local_idx: u16,
    next_pc: usize,
};

const StringLiteralRef = struct {
    atom: ?core.Atom = null,
    next_pc: usize,
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

pub const GlobalPropertyRangeDelta = union(enum) {
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

fn getConditionPc(code: []const u8, pc: usize, induction_idx: u16) ?usize {
    if (pc >= 1) {
        if (decodeLocalGet(code, pc - 1)) |get| {
            if (get.idx == induction_idx and get.next_pc == pc) return pc - 1;
        }
    }
    if (pc >= 2) {
        if (decodeLocalGet(code, pc - 2)) |get| {
            if (get.idx == induction_idx and get.next_pc == pc) return pc - 2;
        }
    }
    if (pc >= 3) {
        if (decodeLocalGet(code, pc - 3)) |get| {
            if (get.idx == induction_idx and get.next_pc == pc) return pc - 3;
        }
    }
    return null;
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

fn sameBindingPut(a: BindingPut, b: BindingPut) bool {
    return a.idx == b.idx and a.is_var_ref == b.is_var_ref;
}

fn localPutNextPc(put: LocalPut) usize {
    return put.operand_pc + put.consume;
}

fn bindingPutNextPc(put: BindingPut) usize {
    return put.operand_pc + put.consume;
}

fn localCompletionPutWritableForFastPath(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, put: LocalPut) bool {
    if (put.idx >= frame.locals.len or put.idx >= frame.locals_uninit.len) return false;
    if (put.checked) return false;
    if (put.idx < function.var_is_lexical.len and function.var_is_lexical[put.idx]) return false;
    if (varRefCellFromValue(frame.locals[put.idx]) != null) return false;
    if (put.idx < function.var_is_const.len and function.var_is_const[put.idx]) return false;
    return true;
}

fn bindingCompletionPutWritableForFastPath(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, put: BindingPut) bool {
    if (put.is_var_ref) return false;
    return localCompletionPutWritableForFastPath(function, frame, .{
        .idx = put.idx,
        .operand_pc = put.operand_pc,
        .consume = put.consume,
        .checked = put.checked,
    });
}

fn decodeOptionalLocalStoreTail(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, pc: usize) ?OptionalLocalStoreTail {
    const code = function.code;
    if (pc >= code.len or code[pc] != op.dup) return .{ .store_pc = pc };

    const store_pc = pc + 1;
    const accumulator_put = decodeLocalPut(code, store_pc) orelse return null;
    const next_pc = localPutNextPc(accumulator_put);
    if (next_pc < code.len and code[next_pc] == op.drop) {
        return .{ .store_pc = store_pc, .tail_pc = next_pc + 1 };
    }

    const completion_put = decodeLocalPut(code, next_pc) orelse return null;
    if (!localCompletionPutWritableForFastPath(function, frame, completion_put)) return null;
    return .{
        .store_pc = store_pc,
        .tail_pc = localPutNextPc(completion_put),
        .completion_put = completion_put,
    };
}

fn decodeOptionalBindingStoreTail(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, pc: usize) ?OptionalBindingStoreTail {
    const code = function.code;
    if (pc >= code.len or code[pc] != op.dup) return .{ .store_pc = pc };

    const store_pc = pc + 1;
    const accumulator_put = decodeBindingPut(code, store_pc) orelse return null;
    const next_pc = bindingPutNextPc(accumulator_put);
    if (next_pc < code.len and code[next_pc] == op.drop) {
        return .{ .store_pc = store_pc, .tail_pc = next_pc + 1 };
    }

    const completion_put = decodeBindingPut(code, next_pc) orelse return null;
    if (!bindingCompletionPutWritableForFastPath(function, frame, completion_put)) return null;
    return .{
        .store_pc = store_pc,
        .tail_pc = bindingPutNextPc(completion_put),
        .completion_put = completion_put,
    };
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

fn decodeDenseArrayPutTail(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, pc: usize) ?DenseArrayPutTail {
    const code = function.code;
    if (pc >= code.len) return null;
    if (code[pc] == op.put_array_el) return .{ .tail_pc = pc + 1 };
    if (code[pc] != op.insert3) return null;
    if (pc + 2 > code.len or code[pc + 1] != op.put_array_el) return null;
    const completion_tail = decodeOptionalLocalCompletionTail(function, frame, pc + 2) orelse return null;
    return .{
        .tail_pc = completion_tail.tail_pc,
        .completion_put = completion_tail.completion_put,
    };
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

fn storeBindingInt32WithCompletion(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    accumulator_put: BindingPut,
    completion_put: ?BindingPut,
    value: i32,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !void {
    try storeBindingInt32(ctx, function, global, frame, accumulator_put, value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    if (completion_put) |completion| {
        if (!sameBindingPut(accumulator_put, completion)) {
            try storeBindingInt32(ctx, function, global, frame, completion, value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
        }
    }
}

fn storeBindingOwnedValueWithCompletion(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    accumulator_put: BindingPut,
    completion_put: ?BindingPut,
    value: core.JSValue,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !void {
    if (completion_put) |completion| {
        if (!sameBindingPut(accumulator_put, completion)) {
            try storeBindingOwnedValue(ctx, function, global, frame, accumulator_put, value.dup(), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
            try storeBindingOwnedValue(ctx, function, global, frame, completion, value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
            return;
        }
    }
    try storeBindingOwnedValue(ctx, function, global, frame, accumulator_put, value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
}

fn storeLocalInt32WithCompletion(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    idx: u16,
    completion_put: ?LocalPut,
    value: i32,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !void {
    try setSlotValue(ctx, &frame.locals[idx], core.JSValue.int32(value));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
    if (completion_put) |completion| {
        if (completion.idx != idx) {
            try setSlotValue(ctx, &frame.locals[completion.idx], core.JSValue.int32(value));
            try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, completion.idx, sync_global_lexical_locals);
        }
    }
}

fn storeLocalOwnedValueWithCompletion(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    idx: u16,
    completion_put: ?LocalPut,
    value: core.JSValue,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !void {
    if (completion_put) |completion| {
        if (completion.idx != idx) {
            try setSlotValue(ctx, &frame.locals[idx], value.dup());
            try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
            try setSlotValue(ctx, &frame.locals[completion.idx], value);
            try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, completion.idx, sync_global_lexical_locals);
            return;
        }
    }
    try setSlotValue(ctx, &frame.locals[idx], value);
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
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

fn tryFuseCheckedLocalSimpleNumericCallAddStore(
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

fn tryFuseCheckedLocalAccumulatorSimpleNumericCallAddStore(
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

    var args_buf: [2]core.JSValue = undefined;
    var argc: usize = 0;
    var call_pc = callee.next_pc;
    if (call_pc >= function.code.len) return false;
    if (function.code[call_pc] != op.call0) {
        const arg0 = borrowedSimpleCallArgWithContext(ctx, function, global, frame, callee.next_pc, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
        if (arg0.next_pc >= function.code.len) return false;
        args_buf[0] = arg0.value;
        argc = 1;
        call_pc = arg0.next_pc;
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
    }

    const add_pc = call_pc + 1;
    if (add_pc >= function.code.len or function.code[add_pc] != op.add) return false;
    const store_tail = decodeOptionalLocalStoreTail(function, frame, add_pc + 1) orelse return false;
    const store = decodeLocalPut(function.code, store_tail.store_pc) orelse return false;
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

    try storeLocalOwnedValueWithCompletion(ctx, function, global, frame, store.idx, store_tail.completion_put, updated, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    if (!store.checked and store.idx < function.var_is_lexical.len and function.var_is_lexical[store.idx]) frame.clearLocalUninitialized(store.idx);
    frame.pc = store_tail.tail_pc orelse store.operand_pc + store.consume;
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

pub fn tryFuseCallResultAddGlobalStore(
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
    if (!globalWritableDataStoreAvailableForFastPath(ctx.runtime, ctx.lexicals, global, function, store_pc, store.atom)) return false;

    const lhs = stack.peekBorrowed() orelse return false;
    if (!lhs.isNumber() or !result.isNumber()) return false;

    const updated = try simpleNumericBinary(ctx.runtime, op.add, lhs, result);
    errdefer updated.free(ctx.runtime);
    if (!setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, store_pc, store.atom, updated)) {
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

pub fn decodeGlobalPut(code: []const u8, pc: usize) ?GlobalBindingPut {
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
    if (!core.string.isAsciiBytes(prefix)) return null;
    const index_get = decodeLocalGet(code, pc + 5) orelse return null;
    if (index_get.idx != local_idx) return null;
    if (index_get.next_pc >= code.len or code[index_get.next_pc] != op.add) return null;
    return .{ .prefix = prefix, .next_pc = index_get.next_pc + 1 };
}

fn parseInductionAndImmediateInt32Args(code: []const u8, pc: usize, local_idx: u16) ?InductionImmediateInt32Args {
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
        if (get.idx != local_idx) return null;
        return .{ .arg = .induction, .next_pc = get.next_pc };
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

pub fn slotValueBorrowed(slot: core.JSValue) core.JSValue {
    var current = slot;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        const cell = varRefCellFromValue(current) orelse return current;
        current = cell.varRefValueSlot().* orelse return core.JSValue.undefinedValue();
    }
    return current;
}

fn tryFuseLocalInt32CompareBranch(function: *const bytecode.Bytecode, frame: *frame_mod.Frame, idx: usize) bool {
    const code = function.code;
    const pc = frame.pc;
    if (pc >= code.len) return false;
    const opc = code[pc];
    var rhs_val: i32 = undefined;
    var rhs_len: usize = 0;
    switch (opc) {
        op.push_i32 => {
            if (pc + 5 > code.len) return false;
            rhs_val = readInt(i32, code[pc + 1 ..][0..4]);
            rhs_len = 5;
        },
        op.push_i16 => {
            if (pc + 3 > code.len) return false;
            rhs_val = @intCast(readInt(i16, code[pc + 1 ..][0..2]));
            rhs_len = 3;
        },
        op.push_i8 => {
            if (pc + 2 > code.len) return false;
            rhs_val = @intCast(@as(i8, @bitCast(code[pc + 1])));
            rhs_len = 2;
        },
        op.push_minus1 => {
            rhs_val = -1;
            rhs_len = 1;
        },
        op.push_0 => {
            rhs_val = 0;
            rhs_len = 1;
        },
        op.push_1 => {
            rhs_val = 1;
            rhs_len = 1;
        },
        op.push_2 => {
            rhs_val = 2;
            rhs_len = 1;
        },
        op.push_3 => {
            rhs_val = 3;
            rhs_len = 1;
        },
        op.push_4 => {
            rhs_val = 4;
            rhs_len = 1;
        },
        op.push_5 => {
            rhs_val = 5;
            rhs_len = 1;
        },
        op.push_6 => {
            rhs_val = 6;
            rhs_len = 1;
        },
        op.push_7 => {
            rhs_val = 7;
            rhs_len = 1;
        },
        else => return false,
    }
    if (pc + rhs_len >= code.len) return false;
    const cmp_op = code[pc + rhs_len];
    switch (cmp_op) {
        op.lt, op.lte, op.gt, op.gte, op.eq, op.neq, op.strict_eq, op.strict_neq => {},
        else => return false,
    }
    const cmp_len: usize = 1;
    if (pc + rhs_len + cmp_len >= code.len) return false;
    const br_op = code[pc + rhs_len + cmp_len];
    var is_if_true = false;
    var br_len: usize = 0;
    var branch_offset: i32 = 0;
    var branch_operand_pc: usize = 0;
    switch (br_op) {
        op.if_false8 => {
            if (pc + rhs_len + cmp_len + 2 > code.len) return false;
            is_if_true = false;
            branch_operand_pc = pc + rhs_len + cmp_len + 1;
            branch_offset = @as(i8, @bitCast(code[branch_operand_pc]));
            br_len = 2;
        },
        op.if_true8 => {
            if (pc + rhs_len + cmp_len + 2 > code.len) return false;
            is_if_true = true;
            branch_operand_pc = pc + rhs_len + cmp_len + 1;
            branch_offset = @as(i8, @bitCast(code[branch_operand_pc]));
            br_len = 2;
        },
        op.if_false => {
            if (pc + rhs_len + cmp_len + 5 > code.len) return false;
            is_if_true = false;
            branch_operand_pc = pc + rhs_len + cmp_len + 1;
            branch_offset = readInt(i32, code[branch_operand_pc..][0..4]);
            br_len = 5;
        },
        op.if_true => {
            if (pc + rhs_len + cmp_len + 5 > code.len) return false;
            is_if_true = true;
            branch_operand_pc = pc + rhs_len + cmp_len + 1;
            branch_offset = readInt(i32, code[branch_operand_pc..][0..4]);
            br_len = 5;
        },
        else => return false,
    }
    const lhs = frame.locals[idx].asInt32() orelse return false;
    const cond_passed = switch (cmp_op) {
        op.lt => lhs < rhs_val,
        op.lte => lhs <= rhs_val,
        op.gt => lhs > rhs_val,
        op.gte => lhs >= rhs_val,
        op.eq, op.strict_eq => lhs == rhs_val,
        op.neq, op.strict_neq => lhs != rhs_val,
        else => unreachable,
    };
    const take_branch = cond_passed == is_if_true;
    const instruction_len = rhs_len + cmp_len + br_len;
    if (take_branch) {
        frame.pc = @intCast(@as(i64, @intCast(branch_operand_pc)) + @as(i64, branch_offset));
    } else {
        frame.pc = pc + instruction_len;
    }
    return true;
}

fn tryFuseLocalShortBigIntCompareBranch(function: *const bytecode.Bytecode, frame: *frame_mod.Frame, idx: usize) bool {
    const code = function.code;
    const pc = frame.pc;
    if (pc >= code.len) return false;
    const opc = code[pc];
    var rhs_val: i64 = undefined;
    var rhs_len: usize = 0;
    switch (opc) {
        op.push_bigint_i32 => {
            if (pc + 5 > code.len) return false;
            rhs_val = readInt(i32, code[pc + 1 ..][0..4]);
            rhs_len = 5;
        },
        else => return false,
    }
    if (pc + rhs_len >= code.len) return false;
    const cmp_op = code[pc + rhs_len];
    switch (cmp_op) {
        op.lt, op.lte, op.gt, op.gte, op.eq, op.neq, op.strict_eq, op.strict_neq => {},
        else => return false,
    }
    const cmp_len: usize = 1;
    if (pc + rhs_len + cmp_len >= code.len) return false;
    const br_op = code[pc + rhs_len + cmp_len];
    var is_if_true = false;
    var br_len: usize = 0;
    var branch_offset: i32 = 0;
    var branch_operand_pc: usize = 0;
    switch (br_op) {
        op.if_false8 => {
            if (pc + rhs_len + cmp_len + 2 > code.len) return false;
            is_if_true = false;
            branch_operand_pc = pc + rhs_len + cmp_len + 1;
            branch_offset = @as(i8, @bitCast(code[branch_operand_pc]));
            br_len = 2;
        },
        op.if_true8 => {
            if (pc + rhs_len + cmp_len + 2 > code.len) return false;
            is_if_true = true;
            branch_operand_pc = pc + rhs_len + cmp_len + 1;
            branch_offset = @as(i8, @bitCast(code[branch_operand_pc]));
            br_len = 2;
        },
        op.if_false => {
            if (pc + rhs_len + cmp_len + 5 > code.len) return false;
            is_if_true = false;
            branch_operand_pc = pc + rhs_len + cmp_len + 1;
            branch_offset = readInt(i32, code[branch_operand_pc..][0..4]);
            br_len = 5;
        },
        op.if_true => {
            if (pc + rhs_len + cmp_len + 5 > code.len) return false;
            is_if_true = true;
            branch_operand_pc = pc + rhs_len + cmp_len + 1;
            branch_offset = readInt(i32, code[branch_operand_pc..][0..4]);
            br_len = 5;
        },
        else => return false,
    }
    const lhs = frame.locals[idx].asShortBigInt() orelse return false;
    const cond_passed = switch (cmp_op) {
        op.lt => lhs < rhs_val,
        op.lte => lhs <= rhs_val,
        op.gt => lhs > rhs_val,
        op.gte => lhs >= rhs_val,
        op.eq, op.strict_eq => lhs == rhs_val,
        op.neq, op.strict_neq => lhs != rhs_val,
        else => unreachable,
    };
    const take_branch = cond_passed == is_if_true;
    const instruction_len = rhs_len + cmp_len + br_len;
    if (take_branch) {
        frame.pc = @intCast(@as(i64, @intCast(branch_operand_pc)) + @as(i64, branch_offset));
    } else {
        frame.pc = pc + instruction_len;
    }
    return true;
}

const CheckedLocalInt32LoopCondition = struct {
    idx: u16,
    limit: i32,
    body_pc: usize,
    false_pc: usize,
};

fn decodeCheckedLocalLoopImmediateInt32(code: []const u8, pc: usize) ?ImmediateInt32 {
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
        op.push_i8 => if (pc + 2 <= code.len) .{ .value = @as(i8, @bitCast(code[pc + 1])), .next_pc = pc + 2 } else null,
        op.push_i16 => if (pc + 3 <= code.len) .{ .value = readInt(i16, code[pc + 1 ..][0..2]), .next_pc = pc + 3 } else null,
        op.push_i32 => if (pc + 5 <= code.len) .{ .value = readInt(i32, code[pc + 1 ..][0..4]), .next_pc = pc + 5 } else null,
        else => null,
    };
}

fn decodeCheckedLocalInt32LessThanLoopCondition(code: []const u8, target_pc: usize) ?CheckedLocalInt32LoopCondition {
    if (target_pc + 3 > code.len or code[target_pc] != op.get_loc_check) return null;
    const immediate = decodeCheckedLocalLoopImmediateInt32(code, target_pc + 3) orelse return null;
    if (immediate.next_pc + 2 > code.len or code[immediate.next_pc] != op.lt or code[immediate.next_pc + 1] != op.if_false8) return null;
    const branch_operand_pc = immediate.next_pc + 2;
    const branch_diff: i8 = @bitCast(code[branch_operand_pc]);
    return .{
        .idx = readInt(u16, code[target_pc + 1 ..][0..2]),
        .limit = immediate.value,
        .body_pc = branch_operand_pc + 1,
        .false_pc = @intCast(@as(i64, @intCast(branch_operand_pc)) + @as(i64, branch_diff)),
    };
}

fn decodeEmptyCheckedLocalPostIncLoopTail(code: []const u8, body_pc: usize, exit_pc: usize, condition_pc: usize, idx: u16) bool {
    if (body_pc + 10 > code.len) return false;
    if (code[body_pc] != op.get_loc_check) return false;
    if (readInt(u16, code[body_pc + 1 ..][0..2]) != idx) return false;
    if (code[body_pc + 3] != op.post_inc) return false;
    if (code[body_pc + 4] != op.put_loc_check) return false;
    if (readInt(u16, code[body_pc + 5 ..][0..2]) != idx) return false;
    if (code[body_pc + 7] != op.drop) return false;
    if (code[body_pc + 8] != op.goto8) return false;
    const operand_pc = body_pc + 9;
    const diff: i8 = @bitCast(code[operand_pc]);
    const target_pc_i64 = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
    if (target_pc_i64 < 0) return false;
    if (@as(usize, @intCast(target_pc_i64)) != condition_pc) return false;
    return operand_pc + 1 == exit_pc;
}

fn tryFuseCheckedLocalEmptyInt32Range(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    idx: u16,
    sync_global_lexical_locals: bool,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (ctx.runtime.hasInterruptHandler()) return false;
    const local_idx: usize = idx;
    if (local_idx >= frame.locals.len or local_idx >= frame.locals_uninit.len) return false;
    if (local_idx < function.var_is_const.len and function.var_is_const[local_idx]) return false;
    const condition_pc = frame.pc -| 3;
    const current = frame.locals[local_idx].asInt32() orelse return false;
    const condition = decodeCheckedLocalInt32LessThanLoopCondition(function.code, condition_pc) orelse return false;
    if (condition.idx != idx) return false;
    if (!decodeEmptyCheckedLocalPostIncLoopTail(function.code, condition.body_pc, condition.false_pc, condition_pc, idx)) return false;

    if (current < condition.limit) {
        try setSlotValue(ctx, &frame.locals[local_idx], core.JSValue.int32(condition.limit));
        try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, local_idx, sync_global_lexical_locals);
    }
    frame.pc = condition.false_pc;
    return true;
}

/// Number of failed match attempts at a bytecode site before the fusion
/// matchers stop being retried there. Shape-driven fusions match on the
/// first attempt; the slack covers matchers with runtime preconditions
/// (e.g. dense-array element kinds) that may stabilize after warm-up.
pub const fusion_cold_threshold: u8 = 16;

pub fn tryFuseCheckedLocalFastPath(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
    comptime globalLexicalValue: anytype,
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    // The matcher chain below is expensive and runs on every executed
    // get_loc_check. Sites that repeatedly fail to match go cold and are
    // skipped permanently; sites that fuse always match within the first
    // few attempts (matching is bytecode-shape driven with only shallow
    // runtime preconditions).
    const fusion_cold = function.fusion_cold;
    const fusion_site = frame.pc;
    if (fusion_site < fusion_cold.len and fusion_cold[fusion_site] >= fusion_cold_threshold) return false;

    if (allow_loop_tail_fusion and
        try tryFuseCheckedLocalEmptyInt32Range(ctx, function, global, frame, idx, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;

    const code = function.code;
    if (frame.pc < code.len) {
        switch (code[frame.pc]) {
            op.push_i32 => {
                if (frame.pc + 7 <= code.len and
                    code[frame.pc + 5] == op.lt and
                    (code[frame.pc + 6] == op.if_false8 or code[frame.pc + 6] == op.if_false))
                {
                    if (try tryFuseCheckedLocalGlobalDataStoreInductionRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalArrayPushInt32Range(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalRegExpLiteralTestConstStringCountRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalRegExpTestConstStringCountRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalMathMinMaxAddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalSimpleNumericCallAddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalInductionInt32AddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalLatin1AtomAppendRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalInvariantBindingInt32AddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalInvariantInt32LoadAddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalDenseArrayModFieldInt32AddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseLocalInt32GlobalInt32AddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                }
            },
            op.push_i16 => {
                if (frame.pc + 5 <= code.len and
                    code[frame.pc + 3] == op.lt and
                    (code[frame.pc + 4] == op.if_false8 or code[frame.pc + 4] == op.if_false))
                {
                    if (try tryFuseCheckedLocalGlobalDataStoreInductionRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalArrayPushInt32Range(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalRegExpLiteralTestConstStringCountRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalInvariantBindingInt32AddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalMathMinMaxAddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalInductionInt32AddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalLatin1AtomAppendRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalInvariantInt32LoadAddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalDenseArrayModFieldInt32AddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalMapSetLatin1PrefixInt32Range(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalMapGetLatin1PrefixInt32SumRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalArrayMapSimpleCallbackRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseLocalInt32GlobalInt32AddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                }
            },
            op.push_i8 => {
                if (frame.pc + 4 <= code.len and
                    code[frame.pc + 2] == op.lt and
                    (code[frame.pc + 3] == op.if_false8 or code[frame.pc + 3] == op.if_false))
                {
                    if (try tryFuseCheckedLocalGlobalDataStoreInductionRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalArrayPushInt32Range(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalRegExpLiteralTestConstStringCountRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalMathMinMaxAddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseCheckedLocalLatin1AtomAppendRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                    if (try tryFuseLocalInt32GlobalInt32AddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                }
            },
            op.push_bigint_i32 => {
                if (frame.pc + 7 <= code.len and
                    code[frame.pc + 5] == op.lt and
                    (code[frame.pc + 6] == op.if_false8 or code[frame.pc + 6] == op.if_false))
                {
                    if (try tryFuseCheckedLocalShortBigIntInductionAddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                }
            },
            else => {},
        }
    }

    if (try tryFuseCheckedLocalDenseArrayLengthIndexedInt32SumRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
    if (try tryFuseCheckedLocalSparseArrayLiteralLengthAddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
    if (try tryFuseCheckedLocalAccumulatorSimpleNumericCallAddStore(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
    if (frame.pc + 4 <= code.len and
        code[frame.pc] == op.get_loc_check and
        code[frame.pc + 3] == op.call1 and
        try tryFuseCheckedLocalSimpleNumericCallAddStore(ctx, function, global, frame, stack, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
    if (try tryFuseCheckedLocalDenseArrayMaskedInt32OverwriteRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
    if (try tryFuseCheckedLocalDenseArrayInt32AppendRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
    if (try tryFuseCheckedLocalDenseArrayIndexedAppend(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
    if (try tryFuseCheckedLocalDenseArrayChunkedInt32ValueAppendRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
    if (tryFuseLocalInt32CompareBranch(function, frame, idx)) return true;
    if (tryFuseLocalShortBigIntCompareBranch(function, frame, idx)) return true;

    if (frame.pc < code.len) {
        switch (code[frame.pc]) {
            op.post_inc, op.post_dec => {
                if (allow_loop_tail_fusion and
                    try arith_vm.tryFuseDroppedCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, idx, code[frame.pc], sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                if (try arith_vm.tryFuseDroppedCheckedLocalPostUpdateRead(ctx, function, global, frame, idx, code[frame.pc], sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
            },
            else => {},
        }
    }

    if (frame.pc < code.len) {
        switch (code[frame.pc]) {
            op.get_var, op.get_var_undef => {
                if (try tryFuseCheckedLocalMathMinMaxAdd(ctx, function, global, frame, idx, eval_local_names, eval_var_ref_names, eval_with_object, allow_loop_tail_fusion, sync_global_lexical_locals, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                if (try tryFuseCheckedLocalCachedGlobalInt32Add(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
            },
            op.get_loc_check => {
                if (frame.pc + 4 <= code.len) {
                    switch (code[frame.pc + 3]) {
                        op.add => {
                            if (try tryFuseCheckedLocalCheckedLocalNumericAdd(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                        },
                        op.get_field => {
                            if (try tryFuseCheckedLocalFieldInt32Add(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                        },
                        op.push_0, op.push_1, op.push_2, op.push_3, op.push_4, op.push_5, op.push_6, op.push_7 => {
                            if (try tryFuseCheckedLocalDenseArrayConstInt32Add(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                        },
                        op.get_loc_check => {
                            if (try tryFuseCheckedLocalDenseArrayIndexedInt32Add(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                            if (try tryFuseCheckedLocalDenseArrayModFieldInt32Add(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) return true;
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    if (fusion_site < fusion_cold.len) fusion_cold[fusion_site] +|= 1;
    return false;
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

pub fn pushBorrowedValueOrFuseLocalAdd(
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

fn tryFuseCheckedLocalCachedGlobalInt32Add(
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
    if (store.idx != local_idx) return false;
    if (local_idx >= frame.locals.len or local_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(local_idx)) return false;
    if (local_idx < function.var_is_const.len and function.var_is_const[local_idx]) return false;

    const atom_id = readInt(u32, code[pc + 1 ..][0..4]);
    if (ctx.lexicals != null) {
        if (globalLexicalValue(ctx, atom_id)) |lexical_value| {
            lexical_value.free(ctx.runtime);
            return false;
        }
    }
    const cached_value = globalDataPropertyValueForFastPath(ctx.runtime, global, function, pc, atom_id) orelse return false;
    const lhs = frame.locals[local_idx].asInt32() orelse return false;
    const rhs = cached_value.asInt32() orelse return false;

    if (ctx.runtime.opcode_profile != null) core.profile.recordGlobalLookup();
    try setSlotValue(ctx, &frame.locals[local_idx], fastInt32Add(lhs, rhs));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, local_idx, sync_global_lexical_locals);
    frame.pc = if (drop_pc) |drop| drop + 1 else store.operand_pc + store.consume;
    _ = try tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    return true;
}

fn tryFuseCheckedLocalRegExpTestConstStringCountRange(
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

    const condition_pc = getConditionPc(function.code, frame.pc, induction_idx) orelse return false;
    const pc = frame.pc;
    const code = function.code;
    const limit_operand = immediateInt32Operand(code, pc) orelse return false;
    if (limit_operand.next_pc >= code.len or code[limit_operand.next_pc] != op.lt) return false;
    const exit_branch = decodeFalseBranch(code, limit_operand.next_pc + 1) orelse return false;
    const limit = limit_operand.value;
    const current_i_value = localReadableBorrowed(frame, induction_idx, true) orelse return false;
    const current_i = current_i_value.asInt32() orelse return false;
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
    if (tail_get.idx != induction_idx) return false;
    if (tail_get.next_pc >= code.len or code[tail_get.next_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_get.next_pc + 1) orelse return false;
    if (tail_put.idx != induction_idx) return false;
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
    const input_value = (try atomStringValueForFastPath(ctx.runtime, input_atom)) orelse return false;
    defer input_value.free(ctx.runtime);
    const matched = try shared_vm.qjsRegExpTestFastNoResult(ctx, regexp_object, input_value) orelse return false;

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

fn tryFuseCheckedLocalRegExpLiteralTestConstStringCountRange(
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
    if (induction_idx < function.var_is_const.len and function.var_is_const[induction_idx]) return false;

    const condition_pc = getConditionPc(function.code, frame.pc, induction_idx) orelse return false;
    const code = function.code;
    const limit_operand = immediateInt32Operand(code, frame.pc) orelse return false;
    if (limit_operand.next_pc >= code.len or code[limit_operand.next_pc] != op.lt) return false;
    const exit_branch = decodeFalseBranch(code, limit_operand.next_pc + 1) orelse return false;
    const limit = limit_operand.value;
    const current_i = frame.locals[induction_idx].asInt32() orelse return false;
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }
    const iteration_count_i128 = @as(i128, limit) - @as(i128, current_i);
    if (iteration_count_i128 <= 0 or iteration_count_i128 > std.math.maxInt(i32)) return false;
    const iteration_count: i32 = @intCast(iteration_count_i128);

    const prefix_completion_tail = decodeOptionalUndefinedLocalCompletionTail(function, frame, exit_branch.true_pc) orelse return false;
    const source_ref = decodeStringLiteralRef(code, prefix_completion_tail.tail_pc) orelse return false;
    const flags_ref = decodeStringLiteralRef(code, source_ref.next_pc) orelse return false;
    const regexp_pc = flags_ref.next_pc;
    if (regexp_pc >= code.len or code[regexp_pc] != op.regexp) return false;
    const field_pc = regexp_pc + 1;
    if (field_pc + 5 > code.len or code[field_pc] != op.get_field2) return false;
    const method_atom = readInt(u32, code[field_pc + 1 ..][0..4]);
    if (!value_ops.atomNameEql(ctx.runtime, method_atom, "test")) return false;
    const input_ref = decodeStringLiteralRef(code, field_pc + 5) orelse return false;
    const call_pc = input_ref.next_pc;
    if (call_pc + 3 > code.len or code[call_pc] != op.call_method or readInt(u16, code[call_pc + 1 ..][0..2]) != 1) return false;
    const test_branch = decodeFalseBranch(code, call_pc + 3) orelse return false;

    const counter_get = decodeBindingGet(code, test_branch.true_pc) orelse return false;
    if (!counter_get.is_var_ref and counter_get.idx == induction_idx) return false;
    if (counter_get.next_pc >= code.len or code[counter_get.next_pc] != op.post_inc) return false;
    const counter_put = decodeBindingPut(code, counter_get.next_pc + 1) orelse return false;
    if (counter_put.idx != counter_get.idx or counter_put.is_var_ref != counter_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, counter_put)) return false;

    const counter_value = bindingReadableBorrowed(frame, counter_get) orelse return false;
    const current_count = counter_value.asInt32() orelse return false;

    var true_tail_pc = bindingPutNextPc(counter_put);
    const counter_completion_tail = decodeOptionalLocalCompletionTail(function, frame, true_tail_pc) orelse return false;
    true_tail_pc = counter_completion_tail.tail_pc;
    const if_completion_tail = decodeOptionalUndefinedLocalCompletionTail(function, frame, true_tail_pc) orelse return false;
    if (test_branch.false_pc != true_tail_pc and test_branch.false_pc != if_completion_tail.tail_pc) return false;
    const false_branch_runs_if_completion = test_branch.false_pc == true_tail_pc;

    var tail_pc = if_completion_tail.tail_pc;
    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (!tail_get.checked or tail_get.idx != induction_idx) return false;
    tail_pc = tail_get.next_pc;
    if (tail_pc >= code.len or code[tail_pc] != op.post_inc) return false;
    const induction_put = decodeLocalPut(code, tail_pc + 1) orelse return false;
    if (induction_put.idx != induction_idx) return false;
    tail_pc = localPutNextPc(induction_put);
    if (tail_pc >= code.len or code[tail_pc] != op.drop) return false;
    const goto_pc = tail_pc + 1;
    if (goto_pc >= code.len) return false;
    const goto_target = backwardGotoTarget(code, goto_pc + 1, code[goto_pc]) orelse return false;
    if (goto_target != condition_pc) return false;

    const regexp_proto = shared_vm.constructorPrototypeFromGlobalAtom(ctx.runtime, global, atom_regexp) orelse return false;
    if (!ownPrototypeEntryIsNativeBuiltinDefault(regexp_proto, method_atom, .regexp, @intFromEnum(builtins.regexp.PrototypeMethod.test_))) return false;

    const source_value = (try stringLiteralRefValueForFastPath(ctx.runtime, source_ref)) orelse return false;
    defer source_value.free(ctx.runtime);
    const flags_value = (try stringLiteralRefValueForFastPath(ctx.runtime, flags_ref)) orelse return false;
    defer flags_value.free(ctx.runtime);
    const input_value = (try stringLiteralRefValueForFastPath(ctx.runtime, input_ref)) orelse return false;
    defer input_value.free(ctx.runtime);
    const regexp_value = try builtins.regexp.constructPrevalidatedLiteralWithValues(ctx.runtime, source_value, flags_value, regexp_proto);
    defer regexp_value.free(ctx.runtime);
    const regexp_object = objectFromValue(regexp_value) orelse return false;
    const matched = try shared_vm.qjsRegExpTestFastNoResult(ctx, regexp_object, input_value) orelse return false;

    if (matched) {
        const final_count_i64 = @as(i64, current_count) + @as(i64, iteration_count);
        if (final_count_i64 < std.math.minInt(i32) or final_count_i64 > std.math.maxInt(i32)) return false;
        try storeBindingInt32(ctx, function, global, frame, counter_put, @intCast(final_count_i64), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
        if (counter_completion_tail.completion_put != null and if_completion_tail.completion_put == null) {
            const last_post_inc_result = final_count_i64 - 1;
            try storeLocalCompletionBorrowedValue(ctx, function, global, frame, counter_completion_tail.completion_put, core.JSValue.int32(@intCast(last_post_inc_result)), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
        } else if (prefix_completion_tail.completion_put != null and counter_completion_tail.completion_put == null and if_completion_tail.completion_put == null) {
            try storeLocalCompletionBorrowedValue(ctx, function, global, frame, prefix_completion_tail.completion_put, core.JSValue.undefinedValue(), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
        }
    } else {
        try storeLocalCompletionBorrowedValue(ctx, function, global, frame, prefix_completion_tail.completion_put, core.JSValue.undefinedValue(), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    }
    if (matched or false_branch_runs_if_completion) {
        try storeLocalCompletionBorrowedValue(ctx, function, global, frame, if_completion_tail.completion_put, core.JSValue.undefinedValue(), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    }
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

fn tryFuseCheckedLocalSimpleNumericCallAddRange(
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

    const condition_pc = getConditionPc(function.code, frame.pc, induction_idx) orelse return false;
    const pc = frame.pc;
    const code = function.code;
    if (pc + 7 > code.len or code[pc] != op.push_i32 or code[pc + 5] != op.lt) return false;
    const limit = readInt(i32, code[pc + 1 ..][0..4]);
    const exit_branch = decodeFalseBranch(code, pc + 6) orelse return false;
    const current_i_value = localReadableBorrowed(frame, induction_idx, true) orelse return false;
    const current_i = current_i_value.asInt32() orelse return false;
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
    const store_tail = decodeOptionalBindingStoreTail(function, frame, add_pc + 1) orelse return false;
    const store_pc = store_tail.store_pc;
    const accumulator_put = decodeBindingPut(code, store_pc) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

    var tail_pc = store_tail.tail_pc orelse bindingPutNextPc(accumulator_put);
    if (tail_pc < code.len and code[tail_pc] == op.close_loc) {
        if (tail_pc + 3 > code.len) return false;
        const close_idx = readInt(u16, code[tail_pc + 1 ..][0..2]);
        if (close_idx != induction_idx) return false;
        tail_pc += 3;
    }
    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (tail_get.idx != induction_idx) return false;
    tail_pc = tail_get.next_pc;
    if (tail_pc >= code.len or code[tail_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_pc + 1) orelse return false;
    if (tail_put.idx != induction_idx) return false;
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
    try storeBindingOwnedValueWithCompletion(ctx, function, global, frame, accumulator_put, store_tail.completion_put, final_value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

fn tryFuseCheckedLocalInvariantBindingInt32AddRange(
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

    const condition_pc = getConditionPc(function.code, frame.pc, induction_idx) orelse return false;
    const pc = frame.pc;
    const code = function.code;
    const limit_operand = immediateInt32Operand(code, pc) orelse return false;
    if (limit_operand.next_pc >= code.len or code[limit_operand.next_pc] != op.lt) return false;
    const exit_branch = decodeFalseBranch(code, limit_operand.next_pc + 1) orelse return false;
    const limit = limit_operand.value;
    const current_i_value = localReadableBorrowed(frame, induction_idx, true) orelse return false;
    const current_i = current_i_value.asInt32() orelse return false;
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

    const store_tail = decodeOptionalBindingStoreTail(function, frame, rhs_get.next_pc + 1) orelse return false;
    const store_pc = store_tail.store_pc;
    const accumulator_put = decodeBindingPut(code, store_pc) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

    var tail_pc = store_tail.tail_pc orelse bindingPutNextPc(accumulator_put);
    if (tail_pc < code.len and code[tail_pc] == op.close_loc) {
        if (tail_pc + 3 > code.len) return false;
        const close_idx = readInt(u16, code[tail_pc + 1 ..][0..2]);
        if (close_idx != induction_idx) return false;
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

    const lhs = (bindingReadableBorrowed(frame, accumulator_get) orelse return false).asInt32() orelse return false;
    const rhs = (bindingReadableBorrowed(frame, rhs_get) orelse return false).asInt32() orelse return false;
    const total_delta = @as(i64, rhs) * iteration_count_i64;
    const final_accumulator = @as(i64, lhs) + total_delta;
    if (final_accumulator < std.math.minInt(i32) or final_accumulator > std.math.maxInt(i32)) return false;

    try storeBindingInt32WithCompletion(ctx, function, global, frame, accumulator_put, store_tail.completion_put, @intCast(final_accumulator), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

fn tryFuseCheckedLocalInductionInt32AddRange(
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

    const condition_pc = getConditionPc(function.code, frame.pc, induction_idx) orelse return false;
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
    if (rhs_get.idx != induction_idx) return false;
    if (rhs_get.next_pc >= code.len or code[rhs_get.next_pc] != op.add) return false;

    const store_tail = decodeOptionalBindingStoreTail(function, frame, rhs_get.next_pc + 1) orelse return false;
    const store_pc = store_tail.store_pc;
    const accumulator_put = decodeBindingPut(code, store_pc) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

    var tail_pc = store_tail.tail_pc orelse bindingPutNextPc(accumulator_put);
    if (tail_pc < code.len and code[tail_pc] == op.close_loc) {
        if (tail_pc + 3 > code.len) return false;
        const close_idx = readInt(u16, code[tail_pc + 1 ..][0..2]);
        if (close_idx != induction_idx) return false;
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
    const delta = intRangeDeltaBounds(current_i, limit);
    const min_accumulator = @as(i128, accumulator) + delta.min;
    const max_accumulator = @as(i128, accumulator) + delta.max;
    if (!safeIntegerI128(min_accumulator) or !safeIntegerI128(max_accumulator)) return false;

    const final_accumulator = @as(i128, accumulator) + delta.total;
    const final_value = value_ops.numberToValue(@floatFromInt(final_accumulator));
    try storeBindingOwnedValueWithCompletion(ctx, function, global, frame, accumulator_put, store_tail.completion_put, final_value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

fn tryFuseCheckedLocalLatin1AtomAppendRange(
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

    const condition_pc = getConditionPc(function.code, frame.pc, induction_idx) orelse return false;
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

    var suffix_atom: u32 = undefined;
    var accumulator_put: BindingPut = undefined;
    var completion_put: ?BindingPut = null;
    var tail_pc: usize = undefined;
    var is_add_loc_pattern = false;

    const pc_true = exit_branch.true_pc;
    if (pc_true + 7 <= code.len and code[pc_true] == op.push_atom_value and code[pc_true + 5] == op.add_loc) {
        suffix_atom = readInt(u32, code[pc_true + 1 ..][0..5][0..4]);
        const accumulator_idx = code[pc_true + 6];
        if (accumulator_idx == induction_idx) return false;
        if (accumulator_idx >= frame.locals.len) return false;
        if (accumulator_idx < function.var_is_const.len and function.var_is_const[accumulator_idx]) return false;

        accumulator_put = .{
            .idx = accumulator_idx,
            .is_var_ref = false,
            .checked = false,
            .operand_pc = 0,
            .consume = 0,
        };
        tail_pc = pc_true + 7;
        is_add_loc_pattern = true;
    } else {
        const accumulator_get = decodeBindingGet(code, exit_branch.true_pc) orelse return false;
        if (!accumulator_get.is_var_ref and accumulator_get.idx == induction_idx) return false;
        const suffix_pc = accumulator_get.next_pc;
        if (suffix_pc + 6 > code.len or code[suffix_pc] != op.push_atom_value) return false;
        suffix_atom = readInt(u32, code[suffix_pc + 1 ..][0..4]);
        const add_pc = suffix_pc + 5;
        if (code[add_pc] != op.add) return false;

        var store_pc = add_pc + 1;
        var drop_pc: ?usize = null;
        if (store_pc < code.len and code[store_pc] == op.dup) {
            store_pc += 1;
            const candidate_store = decodeBindingPut(code, store_pc) orelse return false;
            const candidate_next_pc = candidate_store.operand_pc + candidate_store.consume;
            if (candidate_next_pc < code.len and code[candidate_next_pc] == op.drop) {
                drop_pc = candidate_next_pc;
            } else {
                const candidate_completion = decodeBindingPut(code, candidate_next_pc) orelse return false;
                if (candidate_completion.is_var_ref) return false;
                if (candidate_completion.idx >= frame.locals.len or candidate_completion.idx >= frame.locals_uninit.len) return false;
                if (candidate_completion.checked) return false;
                if (candidate_completion.idx < function.var_is_lexical.len and function.var_is_lexical[candidate_completion.idx]) return false;
                if (varRefCellFromValue(frame.locals[candidate_completion.idx]) != null) return false;
                if (candidate_completion.idx < function.var_is_const.len and function.var_is_const[candidate_completion.idx]) return false;
                completion_put = candidate_completion;
            }
        }
        accumulator_put = decodeBindingPut(code, store_pc) orelse return false;
        if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
        if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

        tail_pc = if (drop_pc) |drop|
            drop + 1
        else if (completion_put) |put|
            put.operand_pc + put.consume
        else
            accumulator_put.operand_pc + accumulator_put.consume;
    }

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

    const accumulator = if (is_add_loc_pattern)
        slotValueBorrowed(frame.locals[accumulator_put.idx])
    else
        bindingReadableBorrowed(frame, .{
            .idx = accumulator_put.idx,
            .is_var_ref = accumulator_put.is_var_ref,
            .checked = accumulator_put.checked,
            .next_pc = 0,
        }) orelse return false;

    if (!accumulator.isString()) return false;
    const repeat_count: usize = @intCast(limit - current_i);
    const final_value = try value_ops.latin1AtomRepeatedConcatValue(ctx.runtime, accumulator, suffix_atom, repeat_count) orelse return false;
    if (completion_put) |put| {
        try storeBindingOwnedValue(ctx, function, global, frame, accumulator_put, final_value.dup(), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
        try storeBindingOwnedValue(ctx, function, global, frame, put, final_value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    } else {
        try storeBindingOwnedValue(ctx, function, global, frame, accumulator_put, final_value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    }
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

fn tryFuseCheckedLocalShortBigIntInductionAddRange(
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

    const condition_pc = getConditionPc(function.code, frame.pc, induction_idx) orelse return false;
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
    if (rhs_get.idx != induction_idx) return false;
    if (rhs_get.next_pc >= code.len or code[rhs_get.next_pc] != op.add) return false;

    var store_pc = rhs_get.next_pc + 1;
    var drop_pc: ?usize = null;
    var completion_put: ?BindingPut = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const candidate_store = decodeBindingPut(code, store_pc) orelse return false;
        const candidate_next_pc = candidate_store.operand_pc + candidate_store.consume;
        if (candidate_next_pc < code.len and code[candidate_next_pc] == op.drop) {
            drop_pc = candidate_next_pc;
        } else {
            const candidate_completion = decodeBindingPut(code, candidate_next_pc) orelse return false;
            if (!bindingCompletionPutWritableForFastPath(function, frame, candidate_completion)) return false;
            completion_put = candidate_completion;
        }
    }
    const accumulator_put = decodeBindingPut(code, store_pc) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

    var tail_pc = if (drop_pc) |drop|
        drop + 1
    else if (completion_put) |put|
        put.operand_pc + put.consume
    else
        accumulator_put.operand_pc + accumulator_put.consume;
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

    const accumulator = (bindingReadableBorrowed(frame, accumulator_get) orelse return false).asShortBigInt() orelse return false;
    const delta = intRangeDeltaBoundsWide(@as(i128, current_i), @as(i128, limit));
    const min_accumulator = @as(i128, accumulator) + delta.min;
    const max_accumulator = @as(i128, accumulator) + delta.max;
    if (!fitsI64(min_accumulator) or !fitsI64(max_accumulator)) return false;

    const final_accumulator = @as(i128, accumulator) + delta.total;
    if (!fitsI64(final_accumulator)) return false;
    try storeBindingOwnedValueWithCompletion(ctx, function, global, frame, accumulator_put, completion_put, core.JSValue.shortBigInt(@intCast(final_accumulator)), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.shortBigInt(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

fn decodeSideEffectFreeArrayLiteralElement(code: []const u8, pc: usize) ?usize {
    if (immediateInt32Operand(code, pc)) |immediate| return immediate.next_pc;
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.undefined, op.null, op.push_false, op.push_true => pc + 1,
        op.push_atom_value => if (pc + 5 <= code.len) pc + 5 else null,
        else => null,
    };
}

fn decodeSparseArrayLiteralLength(rt: *core.JSRuntime, code: []const u8, start_pc: usize) ?SparseArrayLiteralLength {
    var pc = start_pc;
    var dense_count: u32 = 0;
    while (true) {
        if (pc >= code.len) return null;
        if (code[pc] == op.array_from) break;
        const next_pc = decodeSideEffectFreeArrayLiteralElement(code, pc) orelse return null;
        if (dense_count == std.math.maxInt(u16)) return null;
        dense_count += 1;
        pc = next_pc;
    }

    if (pc + 3 > code.len) return null;
    const array_from_count = readInt(u16, code[pc + 1 ..][0..2]);
    if (array_from_count != dense_count) return null;
    pc += 3;

    var length = dense_count;
    while (pc < code.len) {
        if (code[pc] == op.dup) {
            const explicit_length = immediateInt32Operand(code, pc + 1) orelse return null;
            if (explicit_length.value < 0) return null;
            const put_pc = explicit_length.next_pc;
            if (put_pc + 5 > code.len or code[put_pc] != op.put_field) return null;
            const field_atom = readInt(u32, code[put_pc + 1 ..][0..4]);
            if (field_atom != core.atom.ids.length) return null;
            const final_length: u32 = @intCast(explicit_length.value);
            if (final_length < length) return null;
            return .{ .length = final_length, .next_pc = put_pc + 5 };
        }

        const value_next_pc = decodeSideEffectFreeArrayLiteralElement(code, pc) orelse break;
        if (value_next_pc + 5 > code.len or code[value_next_pc] != op.define_field) return null;
        const field_atom = readInt(u32, code[value_next_pc + 1 ..][0..4]);
        const index = core.array.arrayIndexFromAtom(&rt.atoms, field_atom) orelse return null;
        const implied_length = index + 1;
        if (implied_length > length) length = implied_length;
        pc = value_next_pc + 5;
    }

    return .{ .length = length, .next_pc = pc };
}

fn decodePutLocCheckInit(code: []const u8, pc: usize) ?LocalPut {
    if (pc + 3 > code.len or code[pc] != op.put_loc_check_init) return null;
    return .{
        .idx = readInt(u16, code[pc + 1 ..][0..2]),
        .operand_pc = pc + 1,
        .consume = 2,
        .checked = true,
    };
}

fn decodeSparseArrayLiteralLengthLocalInit(rt: *core.JSRuntime, code: []const u8, pc: usize) ?SparseArrayLiteralLengthLocalInit {
    const literal = decodeSparseArrayLiteralLength(rt, code, pc) orelse return null;
    const local_put = decodePutLocCheckInit(code, literal.next_pc) orelse return null;
    return .{
        .length = literal.length,
        .local_idx = local_put.idx,
        .next_pc = localPutNextPc(local_put),
    };
}

fn skipOptionalCloseLocForLocal(frame: *const frame_mod.Frame, code: []const u8, pc: usize, local_idx: u16) ?usize {
    if (pc >= code.len or code[pc] != op.close_loc) return pc;
    if (pc + 3 > code.len) return null;
    const close_idx = readInt(u16, code[pc + 1 ..][0..2]);
    if (close_idx != local_idx) return pc;
    if (local_idx >= frame.locals.len or varRefCellFromValue(frame.locals[local_idx]) != null) return null;
    return pc + 3;
}

fn tryFuseCheckedLocalSparseArrayLiteralLengthAddRange(
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
    if (induction_idx < function.var_is_const.len and function.var_is_const[induction_idx]) return false;

    const condition_pc = getConditionPc(function.code, frame.pc, induction_idx) orelse return false;
    const code = function.code;
    const limit_operand = immediateInt32Operand(code, frame.pc) orelse return false;
    if (limit_operand.next_pc >= code.len or code[limit_operand.next_pc] != op.lt) return false;
    const exit_branch = decodeFalseBranch(code, limit_operand.next_pc + 1) orelse return false;
    const limit = limit_operand.value;
    const current_i = frame.locals[induction_idx].asInt32() orelse return false;
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }

    const iteration_count = @as(i128, limit) - @as(i128, current_i);
    if (iteration_count <= 0 or iteration_count > std.math.maxInt(i32)) return false;

    const literal = decodeSparseArrayLiteralLengthLocalInit(ctx.runtime, code, exit_branch.true_pc) orelse return false;
    if (literal.local_idx == induction_idx) return false;
    if (literal.local_idx >= frame.locals.len or literal.local_idx >= frame.locals_uninit.len) return false;
    if (literal.local_idx < function.var_is_lexical.len and !function.var_is_lexical[literal.local_idx]) return false;
    if (sync_global_lexical_locals and frame.global_lexical_sync_checked and
        literal.local_idx < frame.global_lexical_sync_slots.len and
        frame.global_lexical_sync_slots[literal.local_idx]) return false;

    const accumulator_get = decodeBindingGet(code, literal.next_pc) orelse return false;
    if (!accumulator_get.is_var_ref and (accumulator_get.idx == induction_idx or accumulator_get.idx == literal.local_idx)) return false;
    const literal_get = decodeLocalGet(code, accumulator_get.next_pc) orelse return false;
    if (!literal_get.checked or literal_get.idx != literal.local_idx) return false;
    if (literal_get.next_pc + 2 > code.len or code[literal_get.next_pc] != op.get_length or code[literal_get.next_pc + 1] != op.add) return false;

    const store_tail = decodeOptionalBindingStoreTail(function, frame, literal_get.next_pc + 2) orelse return false;
    const accumulator_put = decodeBindingPut(code, store_tail.store_pc) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

    var tail_pc = store_tail.tail_pc orelse bindingPutNextPc(accumulator_put);
    tail_pc = skipOptionalCloseLocForLocal(frame, code, tail_pc, literal.local_idx) orelse return false;
    tail_pc = skipOptionalCloseLocForLocal(frame, code, tail_pc, induction_idx) orelse return false;
    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (tail_get.idx != induction_idx) return false;
    tail_pc = tail_get.next_pc;
    if (tail_pc >= code.len or code[tail_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_pc + 1) orelse return false;
    if (tail_put.idx != induction_idx) return false;
    const tail_drop_pc = localPutNextPc(tail_put);
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    const goto_target = decodeGotoTarget(code, goto_pc) orelse return false;
    if (goto_target != condition_pc) return false;

    const accumulator = (bindingReadableBorrowed(frame, accumulator_get) orelse return false).asInt32() orelse return false;
    const final_accumulator = @as(i128, accumulator) + @as(i128, literal.length) * iteration_count;
    if (!safeIntegerI128(final_accumulator)) return false;

    const final_value = value_ops.numberToValue(@floatFromInt(final_accumulator));
    try storeBindingOwnedValueWithCompletion(ctx, function, global, frame, accumulator_put, store_tail.completion_put, final_value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

fn tryFuseCheckedLocalInvariantInt32LoadAddRange(
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

    const condition_pc = getConditionPc(function.code, frame.pc, induction_idx) orelse return false;
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

    const store_tail = decodeOptionalBindingStoreTail(function, frame, loaded.next_pc + 1) orelse return false;
    const store_pc = store_tail.store_pc;
    const accumulator_put = decodeBindingPut(code, store_pc) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

    var tail_pc = store_tail.tail_pc orelse bindingPutNextPc(accumulator_put);
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
    const total_delta = @as(i128, loaded.value) * iteration_count;
    const final_accumulator = @as(i128, accumulator) + total_delta;
    if (final_accumulator < std.math.minInt(i32) or final_accumulator > std.math.maxInt(i32)) return false;

    try storeBindingInt32WithCompletion(ctx, function, global, frame, accumulator_put, store_tail.completion_put, @intCast(final_accumulator), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

fn tryFuseCheckedLocalDenseArrayModFieldInt32AddRange(
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

    const condition_pc = getConditionPc(function.code, frame.pc, induction_idx) orelse return false;
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

    const store_tail = decodeOptionalBindingStoreTail(function, frame, add_pc + 1) orelse return false;
    const store_pc = store_tail.store_pc;
    const accumulator_put = decodeBindingPut(code, store_pc) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

    var tail_pc = store_tail.tail_pc orelse bindingPutNextPc(accumulator_put);
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

    const array_value = bindingReadableBorrowed(frame, array_get) orelse return false;
    const increments = denseArrayModFieldInt32Increments(ctx.runtime, array_value, field_atom, modulus) orelse return false;
    const accumulator = (bindingReadableBorrowed(frame, accumulator_get) orelse return false).asInt32() orelse return false;
    const delta = periodicNonNegativeDelta(current_i, limit, increments) orelse return false;
    const final_accumulator = @as(i128, accumulator) + delta;
    if (!safeIntegerI128(final_accumulator)) return false;

    const final_value = value_ops.numberToValue(@floatFromInt(final_accumulator));
    try storeBindingOwnedValueWithCompletion(ctx, function, global, frame, accumulator_put, store_tail.completion_put, final_value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

fn tryFuseCheckedLocalDenseArrayLengthIndexedInt32SumRange(
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
    const condition_pc = getConditionPc(function.code, frame.pc, induction_idx) orelse return false;
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

    const store_tail = decodeOptionalBindingStoreTail(function, frame, index_get.next_pc + 2) orelse return false;
    const store_pc = store_tail.store_pc;
    const accumulator_put = decodeBindingPut(code, store_pc) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

    var tail_pc = store_tail.tail_pc orelse bindingPutNextPc(accumulator_put);
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
    try storeBindingOwnedValueWithCompletion(ctx, function, global, frame, accumulator_put, store_tail.completion_put, final_value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

fn tryFuseCheckedLocalMapSetLatin1PrefixInt32Range(
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

    const condition_pc = getConditionPc(function.code, frame.pc, induction_idx) orelse return false;
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
    const completion_tail = decodeOptionalLocalCompletionTail(function, frame, value_get.next_pc + 3) orelse return false;
    const tail_pc = completion_tail.tail_pc;

    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (tail_get.idx != induction_idx) return false;
    if (tail_get.next_pc >= code.len or code[tail_get.next_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_get.next_pc + 1) orelse return false;
    if (tail_put.idx != induction_idx) return false;
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return false;

    try builtins.collection.mapSetLatin1PrefixInt32Range(ctx.runtime, map_object, key.prefix, current_i, limit);
    try storeLocalCompletionBorrowedValue(ctx, function, global, frame, completion_tail.completion_put, receiver, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

fn tryFuseCheckedLocalMapGetLatin1PrefixInt32SumRange(
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

    const condition_pc = getConditionPc(function.code, frame.pc, induction_idx) orelse return false;
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
    const store_tail = decodeOptionalBindingStoreTail(function, frame, add_pc + 1) orelse return false;
    const store_pc = store_tail.store_pc;
    const accumulator_put = decodeBindingPut(code, store_pc) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

    const tail_pc = store_tail.tail_pc orelse bindingPutNextPc(accumulator_put);
    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (tail_get.idx != induction_idx) return false;
    if (tail_get.next_pc >= code.len or code[tail_get.next_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_get.next_pc + 1) orelse return false;
    if (tail_put.idx != induction_idx) return false;
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

    try storeBindingInt32WithCompletion(ctx, function, global, frame, accumulator_put, store_tail.completion_put, @intCast(total), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

fn tryFuseCheckedLocalArrayMapSimpleCallbackRange(
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

    const condition_pc = getConditionPc(function.code, frame.pc, induction_idx) orelse return false;
    const pc = frame.pc;
    const code = function.code;
    if (pc + 7 > code.len or code[pc] != op.push_i16 or code[pc + 3] != op.lt) return false;
    const limit = @as(i32, readInt(i16, code[pc + 1 ..][0..2]));
    const exit_branch = decodeFalseBranch(code, pc + 4) orelse return false;
    const current_i_value = localReadableBorrowed(frame, induction_idx, true) orelse return false;
    const current_i = current_i_value.asInt32() orelse return false;
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

    const store_tail = decodeOptionalBindingStoreTail(function, frame, closure_pc + 3) orelse return false;
    const result_put = decodeBindingPut(code, store_tail.store_pc) orelse return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, result_put)) return false;

    var tail_pc = store_tail.tail_pc orelse bindingPutNextPc(result_put);
    if (tail_pc < code.len and code[tail_pc] == op.close_loc) {
        if (tail_pc + 3 > code.len) return false;
        const close_idx = readInt(u16, code[tail_pc + 1 ..][0..2]);
        if (close_idx != induction_idx) return false;
        tail_pc += 3;
    }
    const tail_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (tail_get.idx != induction_idx) return false;
    if (tail_get.next_pc >= code.len or code[tail_get.next_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_get.next_pc + 1) orelse return false;
    if (tail_put.idx != induction_idx) return false;
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
    try storeBindingOwnedValueWithCompletion(ctx, function, global, frame, result_put, store_tail.completion_put, mapped, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

fn tryFuseCheckedLocalGlobalDataStoreInductionRange(
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
    comptime setSlotValue: anytype,
    comptime syncTopLevelGlobalLexicalLocal: anytype,
) !bool {
    if (!allow_loop_tail_fusion or ctx.runtime.hasInterruptHandler()) return false;
    if (induction_idx >= frame.locals.len or induction_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(induction_idx)) return false;
    if (induction_idx < function.var_is_const.len and function.var_is_const[induction_idx]) return false;

    const pc = frame.pc;
    const code = function.code;
    const condition_pc = getConditionPc(code, pc, induction_idx) orelse return false;
    const limit_operand = immediateInt32Operand(code, pc) orelse return false;
    if (limit_operand.next_pc >= code.len or code[limit_operand.next_pc] != op.lt) return false;
    const exit_branch = decodeFalseBranch(code, limit_operand.next_pc + 1) orelse return false;
    const limit = limit_operand.value;

    const current_i = frame.locals[induction_idx].asInt32() orelse return false;
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }

    const value_get = decodeLocalGet(code, exit_branch.true_pc) orelse return false;
    if (!value_get.checked or value_get.idx != induction_idx) return false;

    var store_pc = value_get.next_pc;
    var assignment_result_tail = false;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        assignment_result_tail = true;
        store_pc += 1;
    }
    const store = decodeGlobalPut(code, store_pc) orelse return false;
    if (!canUseFastGlobalVarLookup(function, store.atom, frame, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    if (!globalWritableDataStoreAvailableForFastPath(ctx.runtime, ctx.lexicals, global, function, store_pc, store.atom)) return false;

    var tail_pc = store.next_pc;
    var completion_put: ?LocalPut = null;
    if (assignment_result_tail) {
        if (tail_pc < code.len and code[tail_pc] == op.drop) {
            tail_pc += 1;
        } else {
            const completion = decodeLocalPut(code, tail_pc) orelse return false;
            if (!localCompletionPutWritableForFastPath(function, frame, completion)) return false;
            completion_put = completion;
            tail_pc = localPutNextPc(completion);
        }
    }

    const induction_get = decodeLocalGet(code, tail_pc) orelse return false;
    if (!induction_get.checked or induction_get.idx != induction_idx) return false;
    tail_pc = induction_get.next_pc;
    if (tail_pc >= code.len or code[tail_pc] != op.post_inc) return false;
    const induction_store = decodeLocalPut(code, tail_pc + 1) orelse return false;
    if (induction_store.idx != induction_idx) return false;
    tail_pc = induction_store.operand_pc + induction_store.consume;
    if (tail_pc >= code.len or code[tail_pc] != op.drop) return false;
    tail_pc += 1;
    if (tail_pc >= code.len) return false;
    const goto_target = backwardGotoTarget(code, tail_pc + 1, code[tail_pc]) orelse return false;
    if (goto_target != condition_pc) return false;

    const final_global_value = @subWithOverflow(limit, 1);
    if (final_global_value[1] != 0) return false;
    const final_value = core.JSValue.int32(final_global_value[0]);
    if (!setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, store_pc, store.atom, final_value)) return false;
    try storeLocalCompletionBorrowedValue(ctx, function, global, frame, completion_put, final_value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

fn tryFuseCheckedLocalArrayPushInt32Range(
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
    if (induction_idx < function.var_is_const.len and function.var_is_const[induction_idx]) return false;

    const pc = frame.pc;
    const code = function.code;
    const condition_pc = getConditionPc(code, pc, induction_idx) orelse return false;
    const limit_operand = immediateInt32Operand(code, pc) orelse return false;
    if (limit_operand.next_pc >= code.len or code[limit_operand.next_pc] != op.lt) return false;
    const exit_branch = decodeFalseBranch(code, limit_operand.next_pc + 1) orelse return false;
    const limit = limit_operand.value;

    const current_i = frame.locals[induction_idx].asInt32() orelse return false;
    if (current_i >= limit) {
        frame.pc = exit_branch.false_pc;
        return true;
    }
    const iteration_count_i128 = @as(i128, limit) - @as(i128, current_i);
    if (iteration_count_i128 <= 0 or iteration_count_i128 > std.math.maxInt(u32)) return false;
    const iteration_count: u32 = @intCast(iteration_count_i128);

    const receiver_get = decodeBindingGet(code, exit_branch.true_pc) orelse return false;
    const field_pc = receiver_get.next_pc;
    if (field_pc + 5 > code.len or code[field_pc] != op.get_field2) return false;
    const method_atom = readInt(u32, code[field_pc + 1 ..][0..4]);
    if (!value_ops.atomNameEql(ctx.runtime, method_atom, "push")) return false;

    const value_get = decodeLocalGet(code, field_pc + 5) orelse return false;
    if (!value_get.checked or value_get.idx != induction_idx) return false;
    const call_pc = value_get.next_pc;
    if (call_pc + 3 > code.len or code[call_pc] != op.call_method or readInt(u16, code[call_pc + 1 ..][0..2]) != 1) return false;
    const completion_tail = decodeOptionalLocalCompletionTail(function, frame, call_pc + 3) orelse return false;

    var tail_pc = completion_tail.tail_pc;
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
    const induction_store = decodeLocalPut(code, tail_pc + 1) orelse return false;
    if (induction_store.idx != induction_idx) return false;
    tail_pc = induction_store.operand_pc + induction_store.consume;
    if (tail_pc >= code.len or code[tail_pc] != op.drop) return false;
    tail_pc += 1;
    if (tail_pc >= code.len) return false;
    const goto_target = backwardGotoTarget(code, tail_pc + 1, code[tail_pc]) orelse return false;
    if (goto_target != condition_pc) return false;

    const receiver = bindingReadableBorrowed(frame, receiver_get) orelse return false;
    if (!fastArrayPrototypeMethodIsDefault(receiver, method_atom, @intFromEnum(builtins.array.PrototypeMethod.push))) return false;
    const array_object = objectFromValue(receiver) orelse return false;
    if (array_object.proxyTarget() != null or array_object.exotic != null) return false;
    if (array_object.properties.len != 0) return false;

    const start_index = array_object.length;
    if (!try array_object.appendDenseArrayInt32ValueRange(ctx.runtime, start_index, current_i, iteration_count)) return false;
    const final_length_value = shared_vm.lengthIndexValue(array_object.length);
    try storeLocalCompletionBorrowedValue(ctx, function, global, frame, completion_tail.completion_put, final_length_value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

fn tryFuseLocalInt32GlobalInt32AddRange(
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
    if (pc < 3) return false;
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

    const body_pc = exit_branch.true_pc;
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
    const global_data_value = globalDataPropertyValueForFastPath(ctx.runtime, global, function, global_pc, atom_id) orelse return false;
    const rhs = global_data_value.asInt32() orelse return false;
    const lhs = frame.locals[accumulator_idx].asInt32() orelse return false;
    const total_delta = @as(i64, rhs) * iteration_count_i64;
    const final_accumulator = @as(i64, lhs) + total_delta;
    if (final_accumulator < std.math.minInt(i32) or final_accumulator > std.math.maxInt(i32)) return false;

    const store_tail = decodeOptionalLocalStoreTail(function, frame, global_pc + 6) orelse return false;
    const store_pc = store_tail.store_pc;
    const accumulator_store = decodeLocalPut(code, store_pc) orelse return false;
    if (!accumulator_store.checked or accumulator_store.idx != accumulator_idx) return false;
    var tail_pc = store_tail.tail_pc orelse localPutNextPc(accumulator_store);

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
    if (target_pc_i64 < 0 or @as(usize, @intCast(target_pc_i64)) != (getConditionPc(function.code, pc, induction_idx) orelse return false)) return false;

    try storeLocalInt32WithCompletion(ctx, function, global, frame, accumulator_idx, store_tail.completion_put, @intCast(final_accumulator), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

fn tryFuseCheckedLocalFieldInt32Add(
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
    const store_tail = decodeOptionalLocalStoreTail(function, frame, pc + 9) orelse return false;
    const store_pc = store_tail.store_pc;
    const store = decodeLocalPut(code, store_pc) orelse return false;
    if (store.idx != local_idx) return false;
    if (local_idx >= frame.locals.len or local_idx >= frame.locals_uninit.len) return false;
    if (object_idx >= frame.locals.len or object_idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(local_idx) or frame.localIsUninitialized(object_idx)) return false;
    if (local_idx < function.var_is_const.len and function.var_is_const[local_idx]) return false;
    const object_slot = frame.locals[object_idx];
    if (varRefCellFromValue(object_slot) != null) return false;

    const lhs = frame.locals[local_idx].asInt32() orelse return false;
    const atom_id = readInt(u32, code[pc + 4 ..][0..4]);
    const value = ordinaryDataPropertyBorrowedValueForFastPath(ctx.runtime, object_slot, atom_id) orelse return false;
    const rhs = value.asInt32() orelse return false;

    const updated = fastInt32Add(lhs, rhs);
    try storeLocalOwnedValueWithCompletion(ctx, function, global, frame, local_idx, store_tail.completion_put, updated, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    frame.pc = store_tail.tail_pc orelse localPutNextPc(store);
    _ = try tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    return true;
}

fn tryFuseCheckedLocalCheckedLocalNumericAdd(
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
    const store_tail = decodeOptionalLocalStoreTail(function, frame, pc + 4) orelse return false;
    const store_pc = store_tail.store_pc;
    const store = decodeLocalPut(code, store_pc) orelse return false;
    if (store.idx != local_idx) return false;
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
    try storeLocalOwnedValueWithCompletion(ctx, function, global, frame, local_idx, store_tail.completion_put, updated, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    frame.pc = store_tail.tail_pc orelse localPutNextPc(store);
    _ = try tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    return true;
}

fn tryFuseCheckedLocalDenseArrayConstInt32Add(
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
    const store_tail = decodeOptionalLocalStoreTail(function, frame, pc + 6) orelse return false;
    const store_pc = store_tail.store_pc;
    const store = decodeLocalPut(code, store_pc) orelse return false;
    if (store.idx != local_idx) return false;
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
    const updated = fastInt32Add(lhs, rhs);
    try storeLocalOwnedValueWithCompletion(ctx, function, global, frame, local_idx, store_tail.completion_put, updated, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    frame.pc = store_tail.tail_pc orelse localPutNextPc(store);
    _ = try tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    return true;
}

fn tryFuseCheckedLocalDenseArrayIndexedInt32Add(
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
    const store_tail = decodeOptionalLocalStoreTail(function, frame, pc + 8) orelse return false;
    const store_pc = store_tail.store_pc;
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
    try storeLocalOwnedValueWithCompletion(ctx, function, global, frame, store.idx, store_tail.completion_put, updated, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    if (!store.checked and store.idx < function.var_is_lexical.len and function.var_is_lexical[store.idx]) {
        frame.clearLocalUninitialized(store.idx);
    }
    frame.pc = store_tail.tail_pc orelse localPutNextPc(store);
    _ = try tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, allow_loop_tail_fusion, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    return true;
}

fn tryFuseCheckedLocalDenseArrayIndexedAppend(
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
    const put_tail = decodeDenseArrayPutTail(function, frame, append_value.next_pc) orelse return false;
    if (!try array_object.appendDenseArrayIndex(ctx.runtime, index, core.atom.atomFromUInt32(index), append_value.value)) return false;
    try storeLocalCompletionBorrowedValue(ctx, function, global, frame, put_tail.completion_put, append_value.value, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);

    frame.pc = put_tail.tail_pc;
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

    if (!(try setPlainObjectInt32DataPropertyForFastPath(ctx.runtime, object, pattern.a_atom, a))) return false;
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
    const fields = plainObjectInt32DataPropertiesForFastPath(object, pattern.a_atom, pattern.b_atom, pattern.c_atom) orelse return null;
    return .{
        .a = fields.writable,
        .b = fields.b,
        .c = fields.c,
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

fn tryFuseCheckedLocalDenseArrayChunkedInt32ValueAppendRange(
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
    const condition_pc = getConditionPc(function.code, frame.pc, value_idx) orelse return false;
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
    if (tail_get.idx != value_idx) return false;
    if (tail_get.next_pc >= code.len or code[tail_get.next_pc] != op.post_inc) return false;
    const tail_put = decodeLocalPut(code, tail_get.next_pc + 1) orelse return false;
    if (tail_put.idx != value_idx) return false;
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

fn tryFuseCheckedLocalDenseArrayMaskedInt32OverwriteRange(
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
    if (induction_idx < function.var_is_const.len and function.var_is_const[induction_idx]) return false;

    const condition_pc = getConditionPc(function.code, frame.pc, induction_idx) orelse return false;
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
    if (current_i < 0 or limit < 0) return false;

    const array_get = decodeBindingGet(code, exit_branch.true_pc) orelse return false;
    const array_value = bindingReadableBorrowed(frame, array_get) orelse return false;
    const array_object = objectFromValue(array_value) orelse return false;

    const index_get = decodeLocalGet(code, array_get.next_pc) orelse return false;
    if (index_get.idx != induction_idx) return false;
    const mask_operand = immediateInt32Operand(code, index_get.next_pc) orelse return false;
    if (mask_operand.value < 0) return false;
    if (mask_operand.next_pc >= code.len or code[mask_operand.next_pc] != op.@"and") return false;
    const value_get = decodeLocalGet(code, mask_operand.next_pc + 1) orelse return false;
    if (value_get.idx != induction_idx) return false;
    const put_tail = decodeDenseArrayPutTail(function, frame, value_get.next_pc) orelse return false;

    var tail_pc = put_tail.tail_pc;
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
    const tail_drop_pc = tail_put.operand_pc + tail_put.consume;
    if (tail_drop_pc >= code.len or code[tail_drop_pc] != op.drop) return false;
    const goto_pc = tail_drop_pc + 1;
    if (goto_pc + 2 > code.len or code[goto_pc] != op.goto8) return false;
    const goto_operand_pc = goto_pc + 1;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    const goto_target_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (goto_target_i64 < 0 or @as(usize, @intCast(goto_target_i64)) != condition_pc) return false;

    if (!try array_object.overwriteDenseArrayInt32MaskedIndexRange(ctx.runtime, @intCast(current_i), @intCast(limit), @intCast(mask_operand.value))) return false;

    try storeLocalCompletionBorrowedValue(ctx, function, global, frame, put_tail.completion_put, core.JSValue.int32(limit - 1), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

fn tryFuseCheckedLocalDenseArrayInt32AppendRange(
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

    const condition_pc = getConditionPc(function.code, frame.pc, induction_idx) orelse return false;
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
    if (index_get.idx != induction_idx) return false;
    const value_get = decodeLocalGet(code, index_get.next_pc) orelse return false;
    if (!value_get.checked or value_get.idx != induction_idx) return false;
    const put_tail = decodeDenseArrayPutTail(function, frame, value_get.next_pc) orelse return false;

    var tail_pc = put_tail.tail_pc;
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

    const start: u32 = @intCast(current_i);
    const end: u32 = @intCast(limit);
    if (!try array_object.appendDenseArrayInt32Range(ctx.runtime, start, end)) return false;

    try storeLocalCompletionBorrowedValue(ctx, function, global, frame, put_tail.completion_put, core.JSValue.int32(limit - 1), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

fn tryFuseCheckedLocalMathMinMaxAddRange(
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

    const condition_pc = getConditionPc(function.code, frame.pc, induction_idx) orelse return false;
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

    const store_tail = decodeOptionalBindingStoreTail(function, frame, add_pc + 1) orelse return false;
    const store_pc = store_tail.store_pc;
    const accumulator_put = decodeBindingPut(code, store_pc) orelse return false;
    if (accumulator_put.idx != accumulator_get.idx or accumulator_put.is_var_ref != accumulator_get.is_var_ref) return false;
    if (!bindingStoreWritableForFastPath(ctx, function, global, frame, accumulator_put)) return false;

    var tail_pc = store_tail.tail_pc orelse bindingPutNextPc(accumulator_put);
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

    const math_value = fastGlobalDataValueForRange(ctx, function, global, frame, global_atom, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue) orelse return false;
    const method_value = ownDataPropertyValueMaterializedForFastPath(ctx.runtime, math_value, method_atom) orelse return false;
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

    try storeBindingInt32WithCompletion(ctx, function, global, frame, accumulator_put, store_tail.completion_put, @intCast(final_accumulator), sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    try setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
}

fn tryFuseCheckedLocalMathMinMaxAdd(
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
    const method_value = ordinaryDataPropertyBorrowedValueForFastPath(ctx.runtime, math_value, method_atom) orelse return false;
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
    return globalOwnDataPropertyValue(global, atom_id);
}

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
    if (globalOwnDataPropertyValue(global, atom_id)) |value| return value;
    if (global.exotic != null) return null;

    const desc = global.getOwnProperty(atom_id) orelse return null;
    defer desc.destroy(ctx.runtime);
    if (desc.kind != .data or !desc.value_present) return null;

    return globalOwnDataPropertyValue(global, atom_id);
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

pub fn intRangeDeltaBounds(start: i32, limit: i32) IntRangeDeltaBounds {
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

fn fitsI64(value: i128) bool {
    return value >= @as(i128, std.math.minInt(i64)) and value <= @as(i128, std.math.maxInt(i64));
}

pub fn safeIntegerI128(value: i128) bool {
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

fn tryFuseCheckedLocalDenseArrayModFieldInt32Add(
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
    const store_tail = decodeOptionalLocalStoreTail(function, frame, pc + 15) orelse return false;
    const store_pc = store_tail.store_pc;
    const store = decodeLocalPut(code, store_pc) orelse return false;
    if (store.idx != local_idx) return false;
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
    const field_value = ordinaryDataPropertyBorrowedValueForFastPath(ctx.runtime, element, field_atom) orelse return false;
    const lhs = frame.locals[local_idx].asInt32() orelse return false;
    const rhs = field_value.asInt32() orelse return false;

    const updated = fastInt32Add(lhs, rhs);
    try storeLocalOwnedValueWithCompletion(ctx, function, global, frame, local_idx, store_tail.completion_put, updated, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal);
    frame.pc = store_tail.tail_pc orelse localPutNextPc(store);
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
    if (!globalWritableDataStoreAvailableForFastPath(ctx.runtime, ctx.lexicals, global, function, store_pc, store.atom)) return false;

    const lhs = stack.peekBorrowed() orelse return false;
    const lhs_string = stringFromValue(lhs) orelse return false;
    const lhs_bytes = lhs_string.borrowLatin1() orelse return false;
    const suffix_string = try ctx.runtime.percentHexString(@truncate(@as(u32, @bitCast(byte_i32))));
    const suffix_bytes = suffix_string.borrowLatin1() orelse return false;

    const updated_string = try core.string.String.createLatin1Concat(ctx.runtime, lhs_bytes, suffix_bytes);
    var updated_owned = true;
    errdefer if (updated_owned) updated_string.value().free(ctx.runtime);
    if (!setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, store_pc, store.atom, updated_string.value())) {
        updated_string.value().free(ctx.runtime);
        return false;
    }
    updated_owned = false;

    const lhs_owned = try stack.pop();
    lhs_owned.free(ctx.runtime);
    frame.pc = if (drop_pc) |drop| drop + 1 else store.next_pc;
    _ = tryFuseGlobalInt32PrefixTermsStore(ctx, global, function, frame, frame.pc, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue);
    return true;
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
    const stored = setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, store_pc, store_atom, updated);
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

const ImmediateInt32 = struct {
    value: i32,
    next_pc: usize,
};

const ImmediateShortBigInt = struct {
    value: i64,
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

fn immediateShortBigIntI32Operand(code: []const u8, pc: usize) ?ImmediateShortBigInt {
    if (pc + 5 > code.len or code[pc] != op.push_bigint_i32) return null;
    return .{
        .value = @intCast(readInt(i32, code[pc + 1 ..][0..4])),
        .next_pc = pc + 5,
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
pub const tryFuseMakeVarRefPercentHexGlobalStringAssignment = vm_property_ref.tryFuseMakeVarRefPercentHexGlobalStringAssignment;
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

pub fn tryFuseStringFromCharCodeInt32LocalAppend(
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
    const native_ref = functionOwnNativeBuiltinRefForFastPath(function, field_pc, ctx.runtime, string_ctor, method_atom) orelse return false;
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

pub fn atomStringValueForFastPath(rt: *core.JSRuntime, atom_id: core.Atom) !?core.JSValue {
    if (rt.atoms.kind(atom_id) != .string) return null;
    const value = try rt.atoms.toStringValue(rt, atom_id);
    if (!value.isString()) {
        value.free(rt);
        return null;
    }
    return value;
}

fn decodeStringLiteralRef(code: []const u8, pc: usize) ?StringLiteralRef {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.push_atom_value => blk: {
            if (pc + 5 > code.len) return null;
            break :blk .{
                .atom = readInt(u32, code[pc + 1 ..][0..4]),
                .next_pc = pc + 5,
            };
        },
        op.push_empty_string => .{ .next_pc = pc + 1 },
        else => null,
    };
}

fn stringLiteralRefValueForFastPath(rt: *core.JSRuntime, literal: StringLiteralRef) !?core.JSValue {
    if (literal.atom) |atom_id| return atomStringValueForFastPath(rt, atom_id);
    return (try rt.emptyString()).value().dup();
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

fn invariantInt32LoadValue(rt: *core.JSRuntime, receiver: core.JSValue, code: []const u8, pc: usize) ?InvariantInt32Load {
    if (pc >= code.len) return null;
    if (code[pc] == op.get_field) {
        if (pc + 5 > code.len) return null;
        const atom_id = readInt(u32, code[pc + 1 ..][0..4]);
        const value = ordinaryDataPropertyBorrowedValueForFastPath(rt, receiver, atom_id) orelse return null;
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

pub fn denseArrayModFieldInt32Increments(rt: *core.JSRuntime, array_value: core.JSValue, field_atom: core.Atom, modulus: usize) ?DenseArrayModFieldIncrements {
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

fn nativeBuiltinFunctionValueMatchesCollectionOwner(value: core.JSValue, expected_id: u32, owner_class: core.ClassId) bool {
    const function_object = objectFromValue(value) orelse return false;
    if (!nativeBuiltinIdMatches(function_object.nativeFunctionIdSlot().*, .collection, expected_id)) return false;
    return function_object.collectionMethodOwnerClass() == owner_class;
}

fn autoInitCollectionNativeBuiltinMatches(info: core.property.AutoInit, expected_id: u32, owner_class: core.ClassId) bool {
    if (!nativeBuiltinIdMatches(info.native_builtin_id, .collection, expected_id)) return false;
    return info.kind == .native_function and info.collection_method_owner_class == owner_class;
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

fn ownPrototypeEntryIsCollectionNativeBuiltinDefault(proto: *const core.Object, atom_id: core.Atom, expected_id: u32, owner_class: core.ClassId) bool {
    if (proto.exotic != null) return false;
    for (proto.properties) |entry| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        if (entry.flags.accessor) return false;
        return switch (entry.slot) {
            .data => |method| nativeBuiltinFunctionValueMatchesCollectionOwner(method, expected_id, owner_class),
            .auto_init => |info| autoInitCollectionNativeBuiltinMatches(info, expected_id, owner_class),
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

pub fn fastCollectionPrototypeMethodIsDefault(value: core.JSValue, atom_id: core.Atom, expected_id: u32) bool {
    const object = objectFromValue(value) orelse return false;
    if (object.hasOwnProperty(atom_id)) return false;
    const proto = object.getPrototype() orelse return false;
    return ownPrototypeEntryIsCollectionNativeBuiltinDefault(proto, atom_id, expected_id, object.class_id);
}

pub fn fastArrayPrototypeMethodIsDefault(value: core.JSValue, atom_id: core.Atom, expected_id: u32) bool {
    const object = objectFromValue(value) orelse return false;
    if (!object.is_array or object.hasOwnProperty(atom_id)) return false;
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

pub fn fastDenseArrayElementValue(value: core.JSValue, key: core.JSValue) ?core.JSValue {
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

pub fn tryFuseLocalAddWithValue(
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
