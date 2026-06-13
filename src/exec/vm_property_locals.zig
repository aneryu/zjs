//! Local/arg/var-ref slot opcode handlers (get/put/set_loc, get/put_arg, var_ref forms, close_loc).

const fusion_stats = @import("vm_fusion_stats.zig");
const std = @import("std");
const bytecode = @import("../bytecode/root.zig");
const builtins = @import("../builtins/root.zig");
const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const frame_mod = @import("frame.zig");
const arith_vm = @import("vm_arith.zig");
const property_ic = @import("property_ic.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const call_runtime = @import("call_runtime.zig");
const array_ops = @import("array_ops.zig");
const exception_ops = @import("vm_exception_ops.zig");
const object_ops = @import("object_ops.zig");
const regexp_fastpath = @import("regexp_fastpath.zig");
const slot_ops = @import("slot_ops.zig");
const objectFromValue = object_ops.objectFromValue;
const readInt = call_runtime.readInt;
const varRefCellFromValue = slot_ops.varRefCellFromValue;

// Helpers that remain in vm_property.zig (shared with the leftover handlers).
const property_vm = @import("vm_property.zig");
const vm_property_globals = @import("vm_property_globals.zig");
const BindingGet = property_vm.BindingGet;
const BindingPut = property_vm.BindingPut;
const BorrowedCallable = property_vm.BorrowedCallable;
const ImmediateInt32 = property_vm.ImmediateInt32;
const InductionImmediateInt32Args = property_vm.InductionImmediateInt32Args;
const IntRangeDeltaBounds = property_vm.IntRangeDeltaBounds;
const LocalPut = property_vm.LocalPut;
const SimpleNumericRangeArg = property_vm.SimpleNumericRangeArg;
const SimpleNumericRangeCall = property_vm.SimpleNumericRangeCall;
const Step = property_vm.Step;
const atomStringValueForFastPath = property_vm.atomStringValueForFastPath;
const backwardGotoTarget = property_vm.backwardGotoTarget;
const bindingReadableBorrowed = property_vm.bindingReadableBorrowed;
const bindingStoreWritableForFastPath = property_vm.bindingStoreWritableForFastPath;
const borrowedSimpleCallArg = property_vm.borrowedSimpleCallArg;
const borrowedSimpleCallArgWithContext = property_vm.borrowedSimpleCallArgWithContext;
const borrowedSimpleCallable = property_vm.borrowedSimpleCallable;
const canFuseGlobalDataWrite = property_vm.canFuseGlobalDataWrite;
const canUseFastGlobalVarLookup = property_vm.canUseFastGlobalVarLookup;
const decodeBindingGet = property_vm.decodeBindingGet;
const decodeBindingPut = property_vm.decodeBindingPut;
const decodeFalseBranch = property_vm.decodeFalseBranch;
const decodeFieldAtom = property_vm.decodeFieldAtom;
const decodeGlobalPut = property_vm.decodeGlobalPut;
const decodeGotoTarget = property_vm.decodeGotoTarget;
const decodeLocalGet = property_vm.decodeLocalGet;
const decodeLocalPut = property_vm.decodeLocalPut;
const decodeLoopLimitGet = property_vm.decodeLoopLimitGet;
const decodeOptionalLocalCompletionTail = property_vm.decodeOptionalLocalCompletionTail;
const decodeOptionalUndefinedLocalCompletionTail = property_vm.decodeOptionalUndefinedLocalCompletionTail;
const decodeStringSliceConstLocalStore = property_vm.decodeStringSliceConstLocalStore;
const decodeVarRefGet = property_vm.decodeVarRefGet;
const decodeVarRefPut = property_vm.decodeVarRefPut;
const denseArrayModFieldInt32Increments = property_vm.denseArrayModFieldInt32Increments;
const fastArrayPrototypeMethodIsDefault = property_vm.fastArrayPrototypeMethodIsDefault;
const fastCollectionPrototypeMethodIsDefault = property_vm.fastCollectionPrototypeMethodIsDefault;
const fastGlobalDataValueForAtomAtPc = property_vm.fastGlobalDataValueForAtomAtPc;
const fastInstalledGlobalDataValueForAtomAtPc = property_vm.fastInstalledGlobalDataValueForAtomAtPc;
const fastInt32Add = property_vm.fastInt32Add;
const fastRegExpPrototypeMethodIsDefault = property_vm.fastRegExpPrototypeMethodIsDefault;
const frameHasVarRefBinding = property_vm.frameHasVarRefBinding;
const fusion_cold_threshold = property_vm.fusion_cold_threshold;
const immediateInt32Operand = property_vm.immediateInt32Operand;
const intRangeDeltaBounds = property_vm.intRangeDeltaBounds;
const intRangeDeltaBoundsWide = property_vm.intRangeDeltaBoundsWide;
const linearRangeDeltaBounds = property_vm.linearRangeDeltaBounds;
const localCompletionPutWritableForFastPath = property_vm.localCompletionPutWritableForFastPath;
const localPutNextPc = property_vm.localPutNextPc;
const localReadableBorrowed = property_vm.localReadableBorrowed;
const loopLimitReadableInt32 = property_vm.loopLimitReadableInt32;
const mathMinMaxInductionRangeSum = property_vm.mathMinMaxInductionRangeSum;
const mathMinMaxPrimitive2 = property_vm.mathMinMaxPrimitive2;
const ownPrototypeEntryIsNativeBuiltinDefault = property_vm.ownPrototypeEntryIsNativeBuiltinDefault;
const periodicNonNegativeDelta = property_vm.periodicNonNegativeDelta;
const safeIntegerI128 = property_vm.safeIntegerI128;
const sameBinding = property_vm.sameBinding;
const simpleNumericBinary = property_vm.simpleNumericBinary;
const simpleNumericFunctionResult = property_vm.simpleNumericFunctionResult;
const simpleNumericRangeCallable = property_vm.simpleNumericRangeCallable;
const simpleNumericRangeLinearTerm = property_vm.simpleNumericRangeLinearTerm;
const simpleStringCallableKind = property_vm.simpleStringCallableKind;
const slotValueBorrowed = property_vm.slotValueBorrowed;
const storeBindingOwnedValue = property_vm.storeBindingOwnedValue;
const storeLocalCompletionBorrowedValue = property_vm.storeLocalCompletionBorrowedValue;
const storeStringSliceConstLocal = property_vm.storeStringSliceConstLocal;
const stringFromCharCodeInt32Arg = property_vm.stringFromCharCodeInt32Arg;
const stringFromValue = property_vm.stringFromValue;
const tryFuseDroppedLocalPostUpdateGoto8AtPc = property_vm.tryFuseDroppedLocalPostUpdateGoto8AtPc;
const tryFuseDroppedLocalPostUpdateGoto8FromGet = property_vm.tryFuseDroppedLocalPostUpdateGoto8FromGet;
const tryFuseFollowingLocalStringLengthGtConstSliceConstBranch = property_vm.tryFuseFollowingLocalStringLengthGtConstSliceConstBranch;
const tryFuseGlobalInt32PrefixTermsStore = vm_property_globals.tryFuseGlobalInt32PrefixTermsStore;
const tryFuseLocalInt32LessThanArgFalseBranchFromGet = property_vm.tryFuseLocalInt32LessThanArgFalseBranchFromGet;
const tryFuseLocalStringLengthGtConstSliceConstBranchFromGet = property_vm.tryFuseLocalStringLengthGtConstSliceConstBranchFromGet;
const varRefReadableBorrowed = property_vm.varRefReadableBorrowed;
const varRefStoreWritableForFastPath = property_vm.varRefStoreWritableForFastPath;

const dataPropertyValueForFastPath = property_ic.dataPropertyValueForFastPath;
const functionOwnNativeBuiltinRefForFastPath = property_ic.functionOwnNativeBuiltinRefForFastPath;
const globalDataPropertyValueForFastPath = property_ic.globalDataPropertyValueForFastPath;
const globalOwnDataPropertyValue = property_ic.globalOwnDataPropertyValue;
const ordinaryDataPropertyBorrowedValueForFastPath = property_ic.ordinaryDataPropertyBorrowedValueForFastPath;
const globalWritableDataStoreAvailableForFastPath = property_ic.globalWritableDataStoreAvailableForFastPath;
const setGlobalWritableDataStoreForFastPathOwned = property_ic.setGlobalWritableDataStoreForFastPathOwned;
const setPlainObjectInt32DataPropertyForFastPath = property_ic.setPlainObjectInt32DataPropertyForFastPath;
const ownDataPropertyValueMaterializedForFastPath = property_ic.ownDataPropertyValueMaterializedForFastPath;
const plainObjectInt32DataPropertiesForFastPath = property_ic.plainObjectInt32DataPropertiesForFastPath;
const op = bytecode.opcode.op;
const atom_math = core.atom.predefinedId("Math", .string).?;
const atom_regexp = core.atom.predefinedId("RegExp", .string).?;
const atom_string = core.atom.predefinedId("String", .string).?;

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
) !void {
    switch (opc) {
        op.get_loc => {
            const idx = readInt(u16, function.code[frame.pc..][0..2]);
            if (fusion_stats.counted(.tryFuseDroppedLocalPostUpdateGoto8FromGet, try tryFuseDroppedLocalPostUpdateGoto8FromGet(ctx, function, global, frame, idx, frame.pc + 2, allow_loop_tail_fusion, sync_global_lexical_locals))) return;
            if (fusion_stats.counted(.tryFuseLocalInt32LessThanArgFalseBranchFromGet, tryFuseLocalInt32LessThanArgFalseBranchFromGet(function, frame, idx, frame.pc + 2, false))) return;
            if (fusion_stats.counted(.tryFuseLocalStringFromCharCodeInt32AppendFromGet, try tryFuseLocalStringFromCharCodeInt32AppendFromGet(ctx, function, global, frame, idx, frame.pc + 2, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object))) return;
            if (fusion_stats.counted(.tryFuseLocalStringLengthGtConstSliceConstBranchFromGet, try tryFuseLocalStringLengthGtConstSliceConstBranchFromGet(ctx, function, global, frame, idx, frame.pc + 2, sync_global_lexical_locals))) return;
            try slot_ops.execGetLoc(ctx, frame, stack, idx, 2, opc);
        },
        op.put_loc => try slot_ops.execPutLoc(ctx, function, global, frame, stack, readInt(u16, function.code[frame.pc..][0..2]), 2, opc, sync_global_lexical_locals),
        op.set_loc => try slot_ops.execSetLoc(ctx, function, global, frame, stack, readInt(u16, function.code[frame.pc..][0..2]), 2, opc, sync_global_lexical_locals),

        op.get_loc8 => {
            const idx = function.code[frame.pc];
            if (fusion_stats.counted(.tryFuseDroppedLocalPostUpdateGoto8FromGet, try tryFuseDroppedLocalPostUpdateGoto8FromGet(ctx, function, global, frame, idx, frame.pc + 1, allow_loop_tail_fusion, sync_global_lexical_locals))) return;
            if (fusion_stats.counted(.tryFuseLocalInt32LessThanArgFalseBranchFromGet, tryFuseLocalInt32LessThanArgFalseBranchFromGet(function, frame, idx, frame.pc + 1, false))) return;
            if (fusion_stats.counted(.tryFuseLocalStringFromCharCodeInt32AppendFromGet, try tryFuseLocalStringFromCharCodeInt32AppendFromGet(ctx, function, global, frame, idx, frame.pc + 1, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object))) return;
            if (fusion_stats.counted(.tryFuseLocalStringLengthGtConstSliceConstBranchFromGet, try tryFuseLocalStringLengthGtConstSliceConstBranchFromGet(ctx, function, global, frame, idx, frame.pc + 1, sync_global_lexical_locals))) return;
            try slot_ops.execGetLoc(ctx, frame, stack, idx, 1, opc);
        },
        op.put_loc8 => try slot_ops.execPutLoc(ctx, function, global, frame, stack, function.code[frame.pc], 1, opc, sync_global_lexical_locals),
        op.set_loc8 => try slot_ops.execSetLoc(ctx, function, global, frame, stack, function.code[frame.pc], 1, opc, sync_global_lexical_locals),

        op.get_loc0 => {
            if (fusion_stats.counted(.tryFuseDroppedLocalPostUpdateGoto8FromGet, try tryFuseDroppedLocalPostUpdateGoto8FromGet(ctx, function, global, frame, 0, frame.pc, allow_loop_tail_fusion, sync_global_lexical_locals))) return;
            if (fusion_stats.counted(.tryFuseShortLocalDenseArrayLengthIndexedInt32SumRange, try tryFuseShortLocalDenseArrayLengthIndexedInt32SumRange(ctx, function, global, frame, 0, allow_loop_tail_fusion, sync_global_lexical_locals))) return;
            if (fusion_stats.counted(.tryFuseLocalInt32LessThanArgFalseBranchFromGet, tryFuseLocalInt32LessThanArgFalseBranchFromGet(function, frame, 0, frame.pc, false))) return;
            if (fusion_stats.counted(.tryFuseLocalStringFromCharCodeInt32AppendFromGet, try tryFuseLocalStringFromCharCodeInt32AppendFromGet(ctx, function, global, frame, 0, frame.pc, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object))) return;
            if (fusion_stats.counted(.tryFuseLocalStringLengthGtConstSliceConstBranchFromGet, try tryFuseLocalStringLengthGtConstSliceConstBranchFromGet(ctx, function, global, frame, 0, frame.pc, sync_global_lexical_locals))) return;
            if (fusion_stats.counted(.tryFuseLocalFieldGet, try tryFuseLocalFieldGet(ctx, function, frame, stack, 0, frame.pc, false))) return;
            try slot_ops.execGetLoc(ctx, frame, stack, 0, 0, opc);
        },
        op.get_loc1 => {
            if (fusion_stats.counted(.tryFuseDroppedLocalPostUpdateGoto8FromGet, try tryFuseDroppedLocalPostUpdateGoto8FromGet(ctx, function, global, frame, 1, frame.pc, allow_loop_tail_fusion, sync_global_lexical_locals))) return;
            if (fusion_stats.counted(.tryFuseShortLocal0Local1Int32ArithmeticStoreRange, try tryFuseShortLocal0Local1Int32ArithmeticStoreRange(ctx, function, global, frame, 1, allow_loop_tail_fusion, sync_global_lexical_locals))) return;
            if (fusion_stats.counted(.tryFuseShortLocal0Local1DenseArrayMulAndMaskAppendRange, try tryFuseShortLocal0Local1DenseArrayMulAndMaskAppendRange(ctx, function, global, frame, 1, allow_loop_tail_fusion, sync_global_lexical_locals))) return;
            if (fusion_stats.counted(.tryFuseShortLocalDenseArrayLengthIndexedInt32SumRange, try tryFuseShortLocalDenseArrayLengthIndexedInt32SumRange(ctx, function, global, frame, 1, allow_loop_tail_fusion, sync_global_lexical_locals))) return;
            if (fusion_stats.counted(.tryFuseLocalInt32LessThanArgFalseBranchFromGet, tryFuseLocalInt32LessThanArgFalseBranchFromGet(function, frame, 1, frame.pc, false))) return;
            if (fusion_stats.counted(.tryFuseLocalStringFromCharCodeInt32AppendFromGet, try tryFuseLocalStringFromCharCodeInt32AppendFromGet(ctx, function, global, frame, 1, frame.pc, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object))) return;
            if (fusion_stats.counted(.tryFuseLocalStringLengthGtConstSliceConstBranchFromGet, try tryFuseLocalStringLengthGtConstSliceConstBranchFromGet(ctx, function, global, frame, 1, frame.pc, sync_global_lexical_locals))) return;
            if (fusion_stats.counted(.tryFuseLocalFieldGet, try tryFuseLocalFieldGet(ctx, function, frame, stack, 1, frame.pc, false))) return;
            try slot_ops.execGetLoc(ctx, frame, stack, 1, 0, opc);
        },
        op.get_loc2 => {
            if (fusion_stats.counted(.tryFuseDroppedLocalPostUpdateGoto8FromGet, try tryFuseDroppedLocalPostUpdateGoto8FromGet(ctx, function, global, frame, 2, frame.pc, allow_loop_tail_fusion, sync_global_lexical_locals))) return;
            if (fusion_stats.counted(.tryFuseShortLocalObjectFieldUpdateAccumulateRange, try tryFuseShortLocalObjectFieldUpdateAccumulateRange(ctx, function, global, frame, 2, allow_loop_tail_fusion, sync_global_lexical_locals))) return;
            if (fusion_stats.counted(.tryFuseShortLocalDenseArrayLengthIndexedInt32SumRange, try tryFuseShortLocalDenseArrayLengthIndexedInt32SumRange(ctx, function, global, frame, 2, allow_loop_tail_fusion, sync_global_lexical_locals))) return;
            if (fusion_stats.counted(.tryFuseLocalInt32LessThanArgFalseBranchFromGet, tryFuseLocalInt32LessThanArgFalseBranchFromGet(function, frame, 2, frame.pc, false))) return;
            if (fusion_stats.counted(.tryFuseLocalStringFromCharCodeInt32AppendFromGet, try tryFuseLocalStringFromCharCodeInt32AppendFromGet(ctx, function, global, frame, 2, frame.pc, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object))) return;
            if (fusion_stats.counted(.tryFuseLocalStringLengthGtConstSliceConstBranchFromGet, try tryFuseLocalStringLengthGtConstSliceConstBranchFromGet(ctx, function, global, frame, 2, frame.pc, sync_global_lexical_locals))) return;
            if (fusion_stats.counted(.tryFuseLocalFieldGet, try tryFuseLocalFieldGet(ctx, function, frame, stack, 2, frame.pc, false))) return;
            try slot_ops.execGetLoc(ctx, frame, stack, 2, 0, opc);
        },
        op.get_loc3 => {
            if (fusion_stats.counted(.tryFuseDroppedLocalPostUpdateGoto8FromGet, try tryFuseDroppedLocalPostUpdateGoto8FromGet(ctx, function, global, frame, 3, frame.pc, allow_loop_tail_fusion, sync_global_lexical_locals))) return;
            if (fusion_stats.counted(.tryFuseShortLocalDenseArrayLengthIndexedInt32SumRange, try tryFuseShortLocalDenseArrayLengthIndexedInt32SumRange(ctx, function, global, frame, 3, allow_loop_tail_fusion, sync_global_lexical_locals))) return;
            if (fusion_stats.counted(.tryFuseLocalInt32LessThanArgFalseBranchFromGet, tryFuseLocalInt32LessThanArgFalseBranchFromGet(function, frame, 3, frame.pc, false))) return;
            if (fusion_stats.counted(.tryFuseLocalStringFromCharCodeInt32AppendFromGet, try tryFuseLocalStringFromCharCodeInt32AppendFromGet(ctx, function, global, frame, 3, frame.pc, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object))) return;
            if (fusion_stats.counted(.tryFuseLocalStringLengthGtConstSliceConstBranchFromGet, try tryFuseLocalStringLengthGtConstSliceConstBranchFromGet(ctx, function, global, frame, 3, frame.pc, sync_global_lexical_locals))) return;
            if (fusion_stats.counted(.tryFuseLocalFieldGet, try tryFuseLocalFieldGet(ctx, function, frame, stack, 3, frame.pc, false))) return;
            try slot_ops.execGetLoc(ctx, frame, stack, 3, 0, opc);
        },
        op.put_loc0 => try slot_ops.execPutLoc(ctx, function, global, frame, stack, 0, 0, opc, sync_global_lexical_locals),
        op.put_loc1 => try slot_ops.execPutLoc(ctx, function, global, frame, stack, 1, 0, opc, sync_global_lexical_locals),
        op.put_loc2 => try slot_ops.execPutLoc(ctx, function, global, frame, stack, 2, 0, opc, sync_global_lexical_locals),
        op.put_loc3 => try slot_ops.execPutLoc(ctx, function, global, frame, stack, 3, 0, opc, sync_global_lexical_locals),
        op.set_loc0 => try slot_ops.execSetLoc(ctx, function, global, frame, stack, 0, 0, opc, sync_global_lexical_locals),
        op.set_loc1 => try slot_ops.execSetLoc(ctx, function, global, frame, stack, 1, 0, opc, sync_global_lexical_locals),
        op.set_loc2 => try slot_ops.execSetLoc(ctx, function, global, frame, stack, 2, 0, opc, sync_global_lexical_locals),
        op.set_loc3 => try slot_ops.execSetLoc(ctx, function, global, frame, stack, 3, 0, opc, sync_global_lexical_locals),
        op.get_loc0_loc1 => {
            if (fusion_stats.counted(.tryFuseLocal0Local1DenseArrayIndexedAppend, try tryFuseLocal0Local1DenseArrayIndexedAppend(ctx, function, frame))) return;
            try slot_ops.execGetLoc(ctx, frame, stack, 0, 0, opc);
            try slot_ops.execGetLoc(ctx, frame, stack, 1, 0, opc);
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
) !void {
    switch (opc) {
        op.get_arg => try slot_ops.execGetArg(ctx, frame, stack, readInt(u16, function.code[frame.pc..][0..2]), 2, opc),
        op.put_arg => try slot_ops.execPutArg(ctx, frame, stack, readInt(u16, function.code[frame.pc..][0..2]), 2, opc),
        op.set_arg => try slot_ops.execSetArg(ctx, frame, stack, readInt(u16, function.code[frame.pc..][0..2]), 2, opc),
        op.get_arg0 => try slot_ops.execGetArg(ctx, frame, stack, 0, 0, opc),
        op.get_arg1 => try slot_ops.execGetArg(ctx, frame, stack, 1, 0, opc),
        op.get_arg2 => try slot_ops.execGetArg(ctx, frame, stack, 2, 0, opc),
        op.get_arg3 => try slot_ops.execGetArg(ctx, frame, stack, 3, 0, opc),
        op.put_arg0 => try slot_ops.execPutArg(ctx, frame, stack, 0, 0, opc),
        op.put_arg1 => try slot_ops.execPutArg(ctx, frame, stack, 1, 0, opc),
        op.put_arg2 => try slot_ops.execPutArg(ctx, frame, stack, 2, 0, opc),
        op.put_arg3 => try slot_ops.execPutArg(ctx, frame, stack, 3, 0, opc),
        op.set_arg0 => try slot_ops.execSetArg(ctx, frame, stack, 0, 0, opc),
        op.set_arg1 => try slot_ops.execSetArg(ctx, frame, stack, 1, 0, opc),
        op.set_arg2 => try slot_ops.execSetArg(ctx, frame, stack, 2, 0, opc),
        op.set_arg3 => try slot_ops.execSetArg(ctx, frame, stack, 3, 0, opc),
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
                if (varRefCellFromValue(frame.locals[idx]) != null and !slot_ops.varRefSlotIsUninitialized(frame.locals[idx])) {
                    frame.clearLocalUninitialized(idx);
                } else {
                    const err = exception_ops.throwTdzReference(ctx);
                    if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                }
            }
            if ((frame.pc >= function.code.len or function.code[frame.pc] != op.call0) and
                fusion_stats.counted(.tryFuseCheckedLocalFastPath, try tryFuseCheckedLocalFastPath(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object))) return .continue_loop;
            try array_ops.pushSlotValue(stack, frame.locals[idx]);
        },
        op.put_loc_check => {
            if (frame.localIsUninitialized(idx)) {
                const err = exception_ops.throwTdzReference(ctx);
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            }
            const value = try stack.pop();
            if (idx < function.var_is_const.len and function.var_is_const[idx]) {
                value.free(ctx.runtime);
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
                return error.TypeError;
            }
            try slot_ops.setSlotValue(ctx, &frame.locals[idx], value);
            try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
        },
        op.put_loc_check_init => {
            const is_derived_this = function.flags.is_derived_class_constructor and
                idx < function.var_names.len and
                function.var_names[idx] == 8;
            if (is_derived_this and !slot_ops.varRefSlotIsUninitialized(frame.locals[idx])) {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                return error.ReferenceError;
            }
            const value = try stack.pop();
            const constructor_this = if (is_derived_this)
                value.dup()
            else
                core.JSValue.undefinedValue();
            defer constructor_this.free(ctx.runtime);
            try slot_ops.setSlotValue(ctx, &frame.locals[idx], value);
            if (!constructor_this.isUndefined()) {
                try slot_ops.setSlotValue(ctx, &frame.this_value, constructor_this.dup());
            }
            frame.clearLocalUninitialized(idx);
            try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
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
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) !Step {
    switch (opc) {
        op.get_var_ref, op.get_var_ref_check => {
            if (frame.pc + 2 > function.code.len) return error.TypeError;
            const idx = readInt(u16, function.code[frame.pc..][0..2]);
            const next_pc = frame.pc + 2;
            if (!canStartLongVarRefGetFusion(opc, function.code, next_pc) and try tryFastDirectVarRefGet(frame, stack, idx, 2)) return .done;
            if (canStartGlobalCall1(function.code, next_pc) and fusion_stats.counted(.tryFuseVarRefSimpleStringCall1GlobalIntArgument, try tryFuseVarRefSimpleStringCall1GlobalIntArgument(ctx, function, global, frame, stack, idx, 2, eval_local_names, eval_var_ref_names, eval_with_object))) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, frame, stack, idx, 2, catch_target, global)) return .continue_loop;
        },
        op.put_var_ref, op.put_var_ref_check, op.put_var_ref_check_init => {
            if (frame.pc + 2 > function.code.len) return error.TypeError;
            try slot_ops.execPutVarRef(ctx, function, global, frame, stack, readInt(u16, function.code[frame.pc..][0..2]), 2, opc, eval_global_var_bindings, is_eval_code);
        },
        op.set_var_ref => {
            if (frame.pc + 2 > function.code.len) return error.TypeError;
            try slot_ops.execSetVarRef(ctx, frame, stack, readInt(u16, function.code[frame.pc..][0..2]), 2, opc);
        },

        op.get_var_ref0 => {
            if (!canStartShortVarRefGetFusion(function.code, frame.pc) and try tryFastDirectVarRefGet(frame, stack, 0, 0)) return .done;
            if (canStartGlobalCall1(function.code, frame.pc) and fusion_stats.counted(.tryFuseVarRefSimpleStringCall1GlobalIntArgument, try tryFuseVarRefSimpleStringCall1GlobalIntArgument(ctx, function, global, frame, stack, 0, 0, eval_local_names, eval_var_ref_names, eval_with_object))) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, frame, stack, 0, 0, catch_target, global)) return .continue_loop;
        },
        op.get_var_ref1 => {
            if (!canStartShortVarRefGetFusion(function.code, frame.pc) and try tryFastDirectVarRefGet(frame, stack, 1, 0)) return .done;
            if (canStartGlobalCall1(function.code, frame.pc) and fusion_stats.counted(.tryFuseVarRefSimpleStringCall1GlobalIntArgument, try tryFuseVarRefSimpleStringCall1GlobalIntArgument(ctx, function, global, frame, stack, 1, 0, eval_local_names, eval_var_ref_names, eval_with_object))) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, frame, stack, 1, 0, catch_target, global)) return .continue_loop;
        },
        op.get_var_ref2 => {
            if (!canStartShortVarRefGetFusion(function.code, frame.pc) and try tryFastDirectVarRefGet(frame, stack, 2, 0)) return .done;
            if (canStartGlobalCall1(function.code, frame.pc) and fusion_stats.counted(.tryFuseVarRefSimpleStringCall1GlobalIntArgument, try tryFuseVarRefSimpleStringCall1GlobalIntArgument(ctx, function, global, frame, stack, 2, 0, eval_local_names, eval_var_ref_names, eval_with_object))) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, frame, stack, 2, 0, catch_target, global)) return .continue_loop;
        },
        op.get_var_ref3 => {
            if (!canStartShortVarRefGetFusion(function.code, frame.pc) and try tryFastDirectVarRefGet(frame, stack, 3, 0)) return .done;
            if (canStartGlobalCall1(function.code, frame.pc) and fusion_stats.counted(.tryFuseVarRefSimpleStringCall1GlobalIntArgument, try tryFuseVarRefSimpleStringCall1GlobalIntArgument(ctx, function, global, frame, stack, 3, 0, eval_local_names, eval_var_ref_names, eval_with_object))) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, frame, stack, 3, 0, catch_target, global)) return .continue_loop;
        },
        op.put_var_ref0 => try slot_ops.execPutVarRef(ctx, function, global, frame, stack, 0, 0, opc, eval_global_var_bindings, is_eval_code),
        op.put_var_ref1 => try slot_ops.execPutVarRef(ctx, function, global, frame, stack, 1, 0, opc, eval_global_var_bindings, is_eval_code),
        op.put_var_ref2 => try slot_ops.execPutVarRef(ctx, function, global, frame, stack, 2, 0, opc, eval_global_var_bindings, is_eval_code),
        op.put_var_ref3 => try slot_ops.execPutVarRef(ctx, function, global, frame, stack, 3, 0, opc, eval_global_var_bindings, is_eval_code),
        op.set_var_ref0 => try slot_ops.execSetVarRef(ctx, frame, stack, 0, 0, opc),
        op.set_var_ref1 => try slot_ops.execSetVarRef(ctx, frame, stack, 1, 0, opc),
        op.set_var_ref2 => try slot_ops.execSetVarRef(ctx, frame, stack, 2, 0, opc),
        op.set_var_ref3 => try slot_ops.execSetVarRef(ctx, frame, stack, 3, 0, opc),
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
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) !Step {
    return varRef(ctx, function, global, frame, stack, opc, catch_target, eval_global_var_bindings, is_eval_code, eval_local_names, eval_var_ref_names, eval_with_object) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
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

const SimpleNumericArg0ConstCall = struct {
    binop: u8,
    rhs: i32,
};

const Latin1PrefixIntLocalKey = struct {
    prefix: []const u8,
    next_pc: usize,
};

const InvariantInt32Load = struct {
    value: i32,
    next_pc: usize,
};

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

fn sameBindingPut(a: BindingPut, b: BindingPut) bool {
    return a.idx == b.idx and a.is_var_ref == b.is_var_ref;
}

fn bindingPutNextPc(put: BindingPut) usize {
    return put.operand_pc + put.consume;
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

fn storeBindingInt32(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    binding: BindingPut,
    value: i32,
    sync_global_lexical_locals: bool,
) !void {
    if (binding.is_var_ref) {
        try slot_ops.setSlotValue(ctx, &frame.var_refs[binding.idx], core.JSValue.int32(value));
    } else {
        try slot_ops.setSlotValue(ctx, &frame.locals[binding.idx], core.JSValue.int32(value));
        try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, binding.idx, sync_global_lexical_locals);
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
) !void {
    try storeBindingInt32(ctx, function, global, frame, accumulator_put, value, sync_global_lexical_locals);
    if (completion_put) |completion| {
        if (!sameBindingPut(accumulator_put, completion)) {
            try storeBindingInt32(ctx, function, global, frame, completion, value, sync_global_lexical_locals);
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
) !void {
    if (completion_put) |completion| {
        if (!sameBindingPut(accumulator_put, completion)) {
            try storeBindingOwnedValue(ctx, function, global, frame, accumulator_put, value.dup(), sync_global_lexical_locals);
            try storeBindingOwnedValue(ctx, function, global, frame, completion, value, sync_global_lexical_locals);
            return;
        }
    }
    try storeBindingOwnedValue(ctx, function, global, frame, accumulator_put, value, sync_global_lexical_locals);
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
) !void {
    try slot_ops.setSlotValue(ctx, &frame.locals[idx], core.JSValue.int32(value));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
    if (completion_put) |completion| {
        if (completion.idx != idx) {
            try slot_ops.setSlotValue(ctx, &frame.locals[completion.idx], core.JSValue.int32(value));
            try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, completion.idx, sync_global_lexical_locals);
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
) !void {
    if (completion_put) |completion| {
        if (completion.idx != idx) {
            try slot_ops.setSlotValue(ctx, &frame.locals[idx], value.dup());
            try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
            try slot_ops.setSlotValue(ctx, &frame.locals[completion.idx], value);
            try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, completion.idx, sync_global_lexical_locals);
            return;
        }
    }
    try slot_ops.setSlotValue(ctx, &frame.locals[idx], value);
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
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

fn simpleNumericArg0ConstCallable(func: core.JSValue) ?SimpleNumericArg0ConstCall {
    const fb = if (func.isFunctionBytecode())
        call_runtime.functionBytecodeFromValue(func) orelse return null
    else blk: {
        const object = object_ops.functionObjectFromValue(func) orelse return null;
        const function_value = object.functionBytecodeSlot().* orelse return null;
        break :blk call_runtime.functionBytecodeFromValue(function_value) orelse return null;
    };
    if (fb.simple_numeric_kind != .arg0_const) return null;
    return .{ .binop = fb.simple_numeric_op, .rhs = fb.simple_numeric_rhs };
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
        try slot_ops.setSlotValue(ctx, &frame.locals[local_idx], core.JSValue.int32(condition.limit));
        try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, local_idx, sync_global_lexical_locals);
    }
    frame.pc = condition.false_pc;
    return true;
}

pub fn tryFuseCheckedLocalFastPath(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
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
        fusion_stats.counted(.tryFuseCheckedLocalEmptyInt32Range, try tryFuseCheckedLocalEmptyInt32Range(ctx, function, global, frame, idx, sync_global_lexical_locals))) return true;

    const code = function.code;
    if (frame.pc < code.len) {
        switch (code[frame.pc]) {
            op.push_i32 => {
                if (frame.pc + 7 <= code.len and
                    code[frame.pc + 5] == op.lt and
                    (code[frame.pc + 6] == op.if_false8 or code[frame.pc + 6] == op.if_false))
                {
                    if (fusion_stats.counted(.tryFuseCheckedLocalGlobalDataStoreInductionRange, try tryFuseCheckedLocalGlobalDataStoreInductionRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalArrayPushInt32Range, try tryFuseCheckedLocalArrayPushInt32Range(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalRegExpLiteralTestConstStringCountRange, try tryFuseCheckedLocalRegExpLiteralTestConstStringCountRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalMathMinMaxAddRange, try tryFuseCheckedLocalMathMinMaxAddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalSimpleNumericCallAddRange, try tryFuseCheckedLocalSimpleNumericCallAddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalInductionInt32AddRange, try tryFuseCheckedLocalInductionInt32AddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalLatin1AtomAppendRange, try tryFuseCheckedLocalLatin1AtomAppendRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalInvariantBindingInt32AddRange, try tryFuseCheckedLocalInvariantBindingInt32AddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalInvariantInt32LoadAddRange, try tryFuseCheckedLocalInvariantInt32LoadAddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalDenseArrayModFieldInt32AddRange, try tryFuseCheckedLocalDenseArrayModFieldInt32AddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                    if (fusion_stats.counted(.tryFuseLocalInt32GlobalInt32AddRange, try tryFuseLocalInt32GlobalInt32AddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object))) return true;
                }
            },
            op.push_i16 => {
                if (frame.pc + 5 <= code.len and
                    code[frame.pc + 3] == op.lt and
                    (code[frame.pc + 4] == op.if_false8 or code[frame.pc + 4] == op.if_false))
                {
                    if (fusion_stats.counted(.tryFuseCheckedLocalGlobalDataStoreInductionRange, try tryFuseCheckedLocalGlobalDataStoreInductionRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalArrayPushInt32Range, try tryFuseCheckedLocalArrayPushInt32Range(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalRegExpLiteralTestConstStringCountRange, try tryFuseCheckedLocalRegExpLiteralTestConstStringCountRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalInvariantBindingInt32AddRange, try tryFuseCheckedLocalInvariantBindingInt32AddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalMathMinMaxAddRange, try tryFuseCheckedLocalMathMinMaxAddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalInductionInt32AddRange, try tryFuseCheckedLocalInductionInt32AddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalLatin1AtomAppendRange, try tryFuseCheckedLocalLatin1AtomAppendRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalInvariantInt32LoadAddRange, try tryFuseCheckedLocalInvariantInt32LoadAddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalDenseArrayModFieldInt32AddRange, try tryFuseCheckedLocalDenseArrayModFieldInt32AddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalMapSetLatin1PrefixInt32Range, try tryFuseCheckedLocalMapSetLatin1PrefixInt32Range(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalMapGetLatin1PrefixInt32SumRange, try tryFuseCheckedLocalMapGetLatin1PrefixInt32SumRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalArrayMapSimpleCallbackRange, try tryFuseCheckedLocalArrayMapSimpleCallbackRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                    if (fusion_stats.counted(.tryFuseLocalInt32GlobalInt32AddRange, try tryFuseLocalInt32GlobalInt32AddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object))) return true;
                }
            },
            op.push_i8 => {
                if (frame.pc + 4 <= code.len and
                    code[frame.pc + 2] == op.lt and
                    (code[frame.pc + 3] == op.if_false8 or code[frame.pc + 3] == op.if_false))
                {
                    if (fusion_stats.counted(.tryFuseCheckedLocalGlobalDataStoreInductionRange, try tryFuseCheckedLocalGlobalDataStoreInductionRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalArrayPushInt32Range, try tryFuseCheckedLocalArrayPushInt32Range(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalRegExpLiteralTestConstStringCountRange, try tryFuseCheckedLocalRegExpLiteralTestConstStringCountRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalMathMinMaxAddRange, try tryFuseCheckedLocalMathMinMaxAddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object))) return true;
                    if (fusion_stats.counted(.tryFuseCheckedLocalLatin1AtomAppendRange, try tryFuseCheckedLocalLatin1AtomAppendRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                    if (fusion_stats.counted(.tryFuseLocalInt32GlobalInt32AddRange, try tryFuseLocalInt32GlobalInt32AddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object))) return true;
                }
            },
            op.push_bigint_i32 => {
                if (frame.pc + 7 <= code.len and
                    code[frame.pc + 5] == op.lt and
                    (code[frame.pc + 6] == op.if_false8 or code[frame.pc + 6] == op.if_false))
                {
                    if (fusion_stats.counted(.tryFuseCheckedLocalShortBigIntInductionAddRange, try tryFuseCheckedLocalShortBigIntInductionAddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                }
            },
            else => {},
        }
    }

    if (fusion_stats.counted(.tryFuseCheckedLocalDenseArrayLengthIndexedInt32SumRange, try tryFuseCheckedLocalDenseArrayLengthIndexedInt32SumRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
    if (fusion_stats.counted(.tryFuseCheckedLocalSparseArrayLiteralLengthAddRange, try tryFuseCheckedLocalSparseArrayLiteralLengthAddRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
    if (fusion_stats.counted(.tryFuseCheckedLocalDenseArrayInt32AppendRange, try tryFuseCheckedLocalDenseArrayInt32AppendRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
    if (fusion_stats.counted(.tryFuseCheckedLocalDenseArrayChunkedInt32ValueAppendRange, try tryFuseCheckedLocalDenseArrayChunkedInt32ValueAppendRange(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
    if (fusion_stats.counted(.tryFuseLocalInt32CompareBranch, tryFuseLocalInt32CompareBranch(function, frame, idx))) return true;
    if (fusion_stats.counted(.tryFuseLocalShortBigIntCompareBranch, tryFuseLocalShortBigIntCompareBranch(function, frame, idx))) return true;

    if (frame.pc < code.len) {
        switch (code[frame.pc]) {
            op.post_inc, op.post_dec => {
                if (allow_loop_tail_fusion and
                    fusion_stats.counted(.tryFuseDroppedCheckedLocalPostUpdateReadAndGoto8Condition, try arith_vm.tryFuseDroppedCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, idx, code[frame.pc], sync_global_lexical_locals))) return true;
                if (fusion_stats.counted(.tryFuseDroppedCheckedLocalPostUpdateRead, try arith_vm.tryFuseDroppedCheckedLocalPostUpdateRead(ctx, function, global, frame, idx, code[frame.pc], sync_global_lexical_locals))) return true;
            },
            else => {},
        }
    }

    if (frame.pc < code.len) {
        switch (code[frame.pc]) {
            op.get_var, op.get_var_undef => {},
            op.get_loc_check => {
                if (frame.pc + 4 <= code.len) {
                    switch (code[frame.pc + 3]) {
                        op.add => {
                            if (fusion_stats.counted(.tryFuseCheckedLocalCheckedLocalNumericAdd, try tryFuseCheckedLocalCheckedLocalNumericAdd(ctx, function, global, frame, idx, allow_loop_tail_fusion, sync_global_lexical_locals))) return true;
                        },
                        op.get_field => {},
                        op.push_0, op.push_1, op.push_2, op.push_3, op.push_4, op.push_5, op.push_6, op.push_7 => {},
                        op.get_loc_check => {},
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

fn tryFuseCheckedLocalRegExpLiteralTestConstStringCountRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
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

    const regexp_proto = object_ops.constructorPrototypeFromGlobalAtom(ctx.runtime, global, atom_regexp) orelse return false;
    if (!ownPrototypeEntryIsNativeBuiltinDefault(regexp_proto, method_atom, .regexp, @intFromEnum(method_ids.regexp.PrototypeMethod.test_))) return false;

    const source_value = (try stringLiteralRefValueForFastPath(ctx.runtime, source_ref)) orelse return false;
    defer source_value.free(ctx.runtime);
    const flags_value = (try stringLiteralRefValueForFastPath(ctx.runtime, flags_ref)) orelse return false;
    defer flags_value.free(ctx.runtime);
    const input_value = (try stringLiteralRefValueForFastPath(ctx.runtime, input_ref)) orelse return false;
    defer input_value.free(ctx.runtime);
    const regexp_value = try builtins.regexp.constructPrevalidatedLiteralWithValues(ctx.runtime, source_value, flags_value, regexp_proto);
    defer regexp_value.free(ctx.runtime);
    const regexp_object = objectFromValue(regexp_value) orelse return false;
    const matched = try regexp_fastpath.qjsRegExpTestFastNoResult(ctx, regexp_object, input_value) orelse return false;

    if (matched) {
        const final_count_i64 = @as(i64, current_count) + @as(i64, iteration_count);
        if (final_count_i64 < std.math.minInt(i32) or final_count_i64 > std.math.maxInt(i32)) return false;
        try storeBindingInt32(ctx, function, global, frame, counter_put, @intCast(final_count_i64), sync_global_lexical_locals);
        if (counter_completion_tail.completion_put != null and if_completion_tail.completion_put == null) {
            const last_post_inc_result = final_count_i64 - 1;
            try storeLocalCompletionBorrowedValue(ctx, function, global, frame, counter_completion_tail.completion_put, core.JSValue.int32(@intCast(last_post_inc_result)), sync_global_lexical_locals);
        } else if (prefix_completion_tail.completion_put != null and counter_completion_tail.completion_put == null and if_completion_tail.completion_put == null) {
            try storeLocalCompletionBorrowedValue(ctx, function, global, frame, prefix_completion_tail.completion_put, core.JSValue.undefinedValue(), sync_global_lexical_locals);
        }
    } else {
        try storeLocalCompletionBorrowedValue(ctx, function, global, frame, prefix_completion_tail.completion_put, core.JSValue.undefinedValue(), sync_global_lexical_locals);
    }
    if (matched or false_branch_runs_if_completion) {
        try storeLocalCompletionBorrowedValue(ctx, function, global, frame, if_completion_tail.completion_put, core.JSValue.undefinedValue(), sync_global_lexical_locals);
    }
    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
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
    const callee = borrowedSimpleCallable(ctx, function, global, frame, accumulator_get.next_pc, eval_local_names, eval_var_ref_names, eval_with_object) orelse return false;
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
    try storeBindingOwnedValueWithCompletion(ctx, function, global, frame, accumulator_put, store_tail.completion_put, final_value, sync_global_lexical_locals);
    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
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

    try storeBindingInt32WithCompletion(ctx, function, global, frame, accumulator_put, store_tail.completion_put, @intCast(final_accumulator), sync_global_lexical_locals);
    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
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
    try storeBindingOwnedValueWithCompletion(ctx, function, global, frame, accumulator_put, store_tail.completion_put, final_value, sync_global_lexical_locals);
    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
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
        try storeBindingOwnedValue(ctx, function, global, frame, accumulator_put, final_value.dup(), sync_global_lexical_locals);
        try storeBindingOwnedValue(ctx, function, global, frame, put, final_value, sync_global_lexical_locals);
    } else {
        try storeBindingOwnedValue(ctx, function, global, frame, accumulator_put, final_value, sync_global_lexical_locals);
    }
    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
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
    if (!core.JSValue.shortBigIntFits(final_accumulator)) return false;
    try storeBindingOwnedValueWithCompletion(ctx, function, global, frame, accumulator_put, completion_put, core.JSValue.shortBigInt(@intCast(final_accumulator)), sync_global_lexical_locals);
    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.shortBigInt(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
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
    try storeBindingOwnedValueWithCompletion(ctx, function, global, frame, accumulator_put, store_tail.completion_put, final_value, sync_global_lexical_locals);
    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
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

    try storeBindingInt32WithCompletion(ctx, function, global, frame, accumulator_put, store_tail.completion_put, @intCast(final_accumulator), sync_global_lexical_locals);
    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
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
    try storeBindingOwnedValueWithCompletion(ctx, function, global, frame, accumulator_put, store_tail.completion_put, final_value, sync_global_lexical_locals);
    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
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
) !bool {
    const condition_pc = getConditionPc(function.code, frame.pc, induction_idx) orelse return false;
    return fusion_stats.counted(.tryFuseLocalDenseArrayLengthIndexedInt32SumRangeAt, try tryFuseLocalDenseArrayLengthIndexedInt32SumRangeAt(ctx, function, global, frame, induction_idx, condition_pc, allow_loop_tail_fusion, sync_global_lexical_locals));
}

fn tryFuseShortLocalDenseArrayLengthIndexedInt32SumRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
) !bool {
    const condition_pc = if (frame.pc >= 1) frame.pc - 1 else return false;
    return fusion_stats.counted(.tryFuseLocalDenseArrayLengthIndexedInt32SumRangeAt, try tryFuseLocalDenseArrayLengthIndexedInt32SumRangeAt(ctx, function, global, frame, induction_idx, condition_pc, allow_loop_tail_fusion, sync_global_lexical_locals));
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
    if (!array_object.flags.is_array or array_object.arrayElementStorageMode() != .dense) return false;
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
    try storeBindingOwnedValueWithCompletion(ctx, function, global, frame, accumulator_put, store_tail.completion_put, final_value, sync_global_lexical_locals);
    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
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
    if (!fastCollectionPrototypeMethodIsDefault(receiver, method_atom, @intFromEnum(method_ids.collection.PrototypeMethod.set))) return false;

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
    try storeLocalCompletionBorrowedValue(ctx, function, global, frame, completion_tail.completion_put, receiver, sync_global_lexical_locals);
    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
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
    if (!fastCollectionPrototypeMethodIsDefault(receiver, method_atom, @intFromEnum(method_ids.collection.PrototypeMethod.get))) return false;

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

    try storeBindingInt32WithCompletion(ctx, function, global, frame, accumulator_put, store_tail.completion_put, @intCast(total), sync_global_lexical_locals);
    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
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
        if (!array_object.flags.is_array) return false;
    } else return false;
    if (receiver_get.next_pc + 7 > code.len or code[receiver_get.next_pc] != op.get_field2) return false;
    const method_atom = readInt(u32, code[receiver_get.next_pc + 1 ..][0..4]);
    if (!fastArrayPrototypeMethodIsDefault(receiver, method_atom, @intFromEnum(method_ids.array.PrototypeMethod.map))) return false;

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

    const mapped = try array_ops.qjsArrayMapSimpleNumericArg0DefaultSpeciesFastCall(ctx.runtime, global, receiver, callback) orelse return false;
    errdefer mapped.free(ctx.runtime);
    try storeBindingOwnedValueWithCompletion(ctx, function, global, frame, result_put, store_tail.completion_put, mapped, sync_global_lexical_locals);
    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
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
    try storeLocalCompletionBorrowedValue(ctx, function, global, frame, completion_put, final_value, sync_global_lexical_locals);
    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
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
    if (!fastArrayPrototypeMethodIsDefault(receiver, method_atom, @intFromEnum(method_ids.array.PrototypeMethod.push))) return false;
    const array_object = objectFromValue(receiver) orelse return false;
    if (array_object.proxyTarget() != null or array_object.exotic != null) return false;
    if (array_object.properties.len != 0) return false;

    const start_index = array_object.length;
    if (!try array_object.appendDenseArrayInt32ValueRange(ctx.runtime, start_index, current_i, iteration_count)) return false;
    const final_length_value = array_ops.lengthIndexValue(array_object.length);
    try storeLocalCompletionBorrowedValue(ctx, function, global, frame, completion_tail.completion_put, final_length_value, sync_global_lexical_locals);
    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
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
        if (call_runtime.globalLexicalValue(ctx, atom_id)) |lexical_value| {
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

    try storeLocalInt32WithCompletion(ctx, function, global, frame, accumulator_idx, store_tail.completion_put, @intCast(final_accumulator), sync_global_lexical_locals);
    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
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
    try storeLocalOwnedValueWithCompletion(ctx, function, global, frame, local_idx, store_tail.completion_put, updated, sync_global_lexical_locals);
    frame.pc = store_tail.tail_pc orelse localPutNextPc(store);
    _ = fusion_stats.counted(.tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition, try tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, allow_loop_tail_fusion, sync_global_lexical_locals));
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

fn tryFuseShortLocal0Local1Int32ArithmeticStoreRange(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    induction_idx: u16,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
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

    try slot_ops.setSlotValue(ctx, &frame.locals[0], core.JSValue.int32(accumulator));
    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, 0, sync_global_lexical_locals);
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
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
    try slot_ops.setSlotValue(ctx, &frame.locals[1], accumulator_value);
    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, 1, sync_global_lexical_locals);
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
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

    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
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

    try slot_ops.setSlotValue(ctx, &frame.locals[length_idx], core.JSValue.int32(@intCast(next_length_i64)));
    try slot_ops.setSlotValue(ctx, &frame.locals[value_idx], core.JSValue.int32(@intCast(next_value_i64)));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, length_idx, sync_global_lexical_locals);
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, value_idx, sync_global_lexical_locals);
    frame.pc = if (hit_chunk) chunk_branch.true_pc else if (capped_for_interrupt) condition_pc else exit_branch.false_pc;
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

    try storeLocalCompletionBorrowedValue(ctx, function, global, frame, put_tail.completion_put, core.JSValue.int32(limit - 1), sync_global_lexical_locals);
    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
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

    const math_value = fastGlobalDataValueForRange(ctx, function, global, frame, global_atom, eval_local_names, eval_var_ref_names, eval_with_object) orelse return false;
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

    try storeBindingInt32WithCompletion(ctx, function, global, frame, accumulator_put, store_tail.completion_put, @intCast(final_accumulator), sync_global_lexical_locals);
    try slot_ops.setSlotValue(ctx, &frame.locals[induction_idx], core.JSValue.int32(limit));
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, induction_idx, sync_global_lexical_locals);
    frame.pc = exit_branch.false_pc;
    return true;
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
) ?core.JSValue {
    if (!eval_with_object.isUndefined()) return null;
    if (frameHasVarRefBinding(function, frame, atom_id)) return null;
    if (eval_local_names.len != 0 or eval_var_ref_names.len != 0) return null;
    if (frame.eval_local_names.len != 0 or frame.eval_var_ref_names.len != 0) return null;
    if (call_runtime.globalLexicalValue(ctx, atom_id)) |lexical_value| {
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

fn fitsI64(value: i128) bool {
    return value >= @as(i128, std.math.minInt(i64)) and value <= @as(i128, std.math.maxInt(i64));
}

fn tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    allow_loop_tail_fusion: bool,
    sync_global_lexical_locals: bool,
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
    if (fusion_stats.counted(.tryFuseDroppedCheckedLocalPostUpdateReadAndGoto8Condition, try arith_vm.tryFuseDroppedCheckedLocalPostUpdateReadAndGoto8Condition(ctx, function, global, frame, loop_idx, update_op, sync_global_lexical_locals))) {
        return true;
    }
    frame.pc = saved_pc;
    return false;
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
    const arg_value = fastGlobalDataValueForAtomAtPc(ctx, function, global, frame, arg_pc, arg_atom, eval_local_names, eval_var_ref_names, eval_with_object) orelse return false;
    const arg_i32 = arg_value.asInt32() orelse return false;

    const result = try simpleStringCallResultFromInt32(ctx.runtime, kind, arg_i32) orelse return false;
    var result_owned = true;
    errdefer if (result_owned) result.free(ctx.runtime);

    frame.pc = arg_pc + 6;
    try stack.pushOwned(result);
    result_owned = false;
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

const ImmediateShortBigInt = struct {
    value: i64,
    next_pc: usize,
};

fn immediateShortBigIntI32Operand(code: []const u8, pc: usize) ?ImmediateShortBigInt {
    if (pc + 5 > code.len or code[pc] != op.push_bigint_i32) return null;
    return .{
        .value = @intCast(readInt(i32, code[pc + 1 ..][0..4])),
        .next_pc = pc + 5,
    };
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
) !bool {
    const code = function.code;
    if (global_pc + 10 > code.len) return false;
    const global_op = code[global_pc];
    if (global_op != op.get_var and global_op != op.get_var_undef) return false;
    const global_atom = readInt(u32, code[global_pc + 1 ..][0..4]);
    if (global_atom != atom_string) return false;

    const string_ctor = fastInstalledGlobalDataValueForAtomAtPc(ctx, function, global, frame, global_pc, global_atom, eval_local_names, eval_var_ref_names, eval_with_object) orelse return false;
    const field_pc = global_pc + 5;
    if (code[field_pc] != op.get_field2) return false;
    const method_atom = readInt(u32, code[field_pc + 1 ..][0..4]);
    const native_ref = functionOwnNativeBuiltinRefForFastPath(function, field_pc, ctx.runtime, string_ctor, method_atom) orelse return false;
    if (native_ref.domain != .string or native_ref.id != @intFromEnum(method_ids.string.StaticMethod.from_char_code)) return false;

    const argument = stringFromCharCodeInt32Arg(function, frame, field_pc + 5) orelse return false;
    if (argument.next_pc + 3 > code.len or code[argument.next_pc] != op.call_method) return false;
    if (readInt(u16, code[argument.next_pc + 1 ..][0..2]) != 1) return false;

    return try tryStoreStringFromCharCodeInt32LocalAppend(ctx, function, global, frame, local_idx, argument.value, argument.next_pc + 3, allow_loop_tail_fusion, sync_global_lexical_locals);
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
    if (lhs_string.isRope()) return false;
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
        try slot_ops.setSlotValue(ctx, &frame.locals[local_idx], replacement);
    }
    if (local_idx < function.var_is_lexical.len and function.var_is_lexical[local_idx]) {
        frame.clearLocalUninitialized(local_idx);
    }
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, local_idx, sync_global_lexical_locals);
    frame.pc = if (drop_pc) |drop| drop + 1 else store.operand_pc + store.consume;
    _ = fusion_stats.counted(.tryFuseFollowingLocalStringLengthGtConstSliceConstBranch, try tryFuseFollowingLocalStringLengthGtConstSliceConstBranch(ctx, function, global, frame, local_idx, sync_global_lexical_locals));
    _ = fusion_stats.counted(.tryFuseDroppedLocalPostUpdateGoto8AtPc, try tryFuseDroppedLocalPostUpdateGoto8AtPc(ctx, function, global, frame, frame.pc, allow_loop_tail_fusion, sync_global_lexical_locals));
    return true;
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
    if (!object.flags.is_array or object.arrayElementStorageMode() != .dense) return null;
    if (index >= @as(usize, @intCast(object.length))) return null;
    const elements = object.arrayElements();
    if (index >= elements.len) return null;
    const element = elements[index] orelse return null;
    return .{ .value = element.asInt32() orelse return null, .next_pc = pc + 2 };
}

fn denseArrayInt32RangeDelta(object: *core.Object, start: usize, limit: usize) ?IntRangeDeltaBounds {
    if (start > limit) return null;
    if (object.proxyTarget() != null or object.exotic != null) return null;
    if (!object.flags.is_array or object.arrayElementStorageMode() != .dense) return null;
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

pub fn closeLoc(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !void {
    const idx = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    try slot_ops.closeLocalVarRef(ctx, frame, idx);
}
