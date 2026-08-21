//! Local/arg/var-ref slot opcode handlers (get/put/set_loc, get/put_arg, var_ref forms, close_loc).

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const vm_arith = @import("vm_arith.zig");
const property_direct = @import("property_direct.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const call_runtime = @import("call_runtime.zig");
const array_ops = @import("array_ops.zig");
const exception_ops = @import("exception_ops.zig");
const object_ops = @import("object_ops.zig");
const regexp_fastpath = @import("regexp_fastpath.zig");
const slot_ops = @import("slot_ops.zig");
const value_slot = @import("value_slot.zig");
const objectFromValue = object_ops.objectFromValue;
const readInt = call_runtime.readInt;

// Helpers that remain in vm_property.zig (shared with the leftover handlers).
const vm_property = @import("vm_property.zig");
const vm_property_globals = @import("vm_property_globals.zig");
const BindingGet = vm_property.BindingGet;
const BindingPut = vm_property.BindingPut;
const ImmediateInt32 = vm_property.ImmediateInt32;
const IntRangeDeltaBounds = vm_property.IntRangeDeltaBounds;
const LocalPut = vm_property.LocalPut;
const Step = vm_property.Step;
const atomStringValueForFastPath = vm_property.atomStringValueForFastPath;
const backwardGotoTarget = vm_property.backwardGotoTarget;
const bindingReadableBorrowed = vm_property.bindingReadableBorrowed;
const bindingStoreWritableForFastPath = vm_property.bindingStoreWritableForFastPath;
const canFuseGlobalDataWrite = vm_property.canFuseGlobalDataWrite;
const canUseFastGlobalVarLookup = vm_property.canUseFastGlobalVarLookup;
const decodeBindingGet = vm_property.decodeBindingGet;
const decodeBindingPut = vm_property.decodeBindingPut;
const decodeFalseBranch = vm_property.decodeFalseBranch;
const decodeFieldAtom = vm_property.decodeFieldAtom;
const decodeGlobalPut = vm_property.decodeGlobalPut;
const decodeGotoTarget = vm_property.decodeGotoTarget;
const decodeLocalGet = vm_property.decodeLocalGet;
const decodeLocalPut = vm_property.decodeLocalPut;
const decodeLoopLimitGet = vm_property.decodeLoopLimitGet;
const decodeOptionalLocalCompletionTail = vm_property.decodeOptionalLocalCompletionTail;
const decodeOptionalUndefinedLocalCompletionTail = vm_property.decodeOptionalUndefinedLocalCompletionTail;
const decodeStringSliceConstLocalStore = vm_property.decodeStringSliceConstLocalStore;
const denseArrayModFieldInt32Increments = vm_property.denseArrayModFieldInt32Increments;
const fastArrayPrototypeMethodIsDefault = vm_property.fastArrayPrototypeMethodIsDefault;
const fastCollectionPrototypeMethodIsDefault = vm_property.fastCollectionPrototypeMethodIsDefault;
const fastGlobalDataValueForAtomAtPc = vm_property.fastGlobalDataValueForAtomAtPc;
const fastInstalledGlobalDataValueForAtomAtPc = vm_property.fastInstalledGlobalDataValueForAtomAtPc;
const checkedInt32Add = vm_property.checkedInt32Add;
const fastRegExpPrototypeMethodIsDefault = vm_property.fastRegExpPrototypeMethodIsDefault;
const frameHasVarRefBinding = vm_property.frameHasVarRefBinding;
const immediateInt32Operand = vm_property.immediateInt32Operand;
const intRangeDeltaBounds = vm_property.intRangeDeltaBounds;
const intRangeDeltaBoundsWide = vm_property.intRangeDeltaBoundsWide;
const linearRangeDeltaBounds = vm_property.linearRangeDeltaBounds;
const localCompletionPutWritableForFastPath = vm_property.localCompletionPutWritableForFastPath;
const localPutNextPc = vm_property.localPutNextPc;
const localReadableBorrowed = vm_property.localReadableBorrowed;
const loopLimitReadableInt32 = vm_property.loopLimitReadableInt32;
const mathMinMaxInductionRangeSum = vm_property.mathMinMaxInductionRangeSum;
const mathMinMaxPrimitive2 = vm_property.mathMinMaxPrimitive2;
const ownPrototypeEntryIsNativeBuiltinDefault = vm_property.ownPrototypeEntryIsNativeBuiltinDefault;
const periodicNonNegativeDelta = vm_property.periodicNonNegativeDelta;
const safeIntegerI128 = vm_property.safeIntegerI128;
const sameBinding = vm_property.sameBinding;
const storeBindingOwnedValue = vm_property.storeBindingOwnedValue;
const storeLocalCompletionBorrowedValue = vm_property.storeLocalCompletionBorrowedValue;
const storeStringSliceConstLocal = vm_property.storeStringSliceConstLocal;
const stringFromCharCodeInt32Arg = vm_property.stringFromCharCodeInt32Arg;
const stringFromValue = vm_property.stringFromValue;
const varRefReadableBorrowed = vm_property.varRefReadableBorrowed;
const varRefStoreWritableForFastPath = vm_property.varRefStoreWritableForFastPath;

const dataPropertyValueForFastPath = property_direct.dataPropertyValueForFastPath;
const functionOwnNativeBuiltinRefForFastPath = property_direct.functionOwnNativeBuiltinRefForFastPath;
const globalDataPropertyValueForFastPath = property_direct.globalDataPropertyValueForFastPath;
const globalOwnDataPropertyValue = property_direct.globalOwnDataPropertyValue;
const ordinaryDataPropertyBorrowedValueForFastPath = property_direct.ordinaryDataPropertyBorrowedValueForFastPath;
const globalWritableDataStoreAvailableForFastPath = property_direct.globalWritableDataStoreAvailableForFastPath;
const setGlobalWritableDataStoreForFastPathOwned = property_direct.setGlobalWritableDataStoreForFastPathOwned;
const setPlainObjectInt32DataPropertyForFastPath = property_direct.setPlainObjectInt32DataPropertyForFastPath;
const ownDataPropertyValueMaterializedForFastPath = property_direct.ownDataPropertyValueMaterializedForFastPath;
const plainObjectInt32DataPropertiesForFastPath = property_direct.plainObjectInt32DataPropertiesForFastPath;
const op = bytecode.opcode.op;
pub noinline fn loc(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    opc: u8,
) !void {
    switch (opc) {
        op.get_loc => {
            const idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
            try slot_ops.execGetLoc(ctx, frame, stack, idx, 2, opc);
        },
        op.put_loc => try slot_ops.execPutLoc(ctx, frame, stack, readInt(u16, function.byteCode()[frame.pc..][0..2]), 2, opc),
        op.set_loc => try slot_ops.execSetLoc(ctx, frame, stack, readInt(u16, function.byteCode()[frame.pc..][0..2]), 2, opc),

        op.get_loc8 => {
            const idx = function.byteCode()[frame.pc];
            try slot_ops.execGetLoc(ctx, frame, stack, idx, 1, opc);
        },
        op.put_loc8 => try slot_ops.execPutLoc(ctx, frame, stack, function.byteCode()[frame.pc], 1, opc),
        op.set_loc8 => try slot_ops.execSetLoc(ctx, frame, stack, function.byteCode()[frame.pc], 1, opc),

        op.get_loc0 => {
            try slot_ops.execGetLoc(ctx, frame, stack, 0, 0, opc);
        },
        op.get_loc1 => {
            try slot_ops.execGetLoc(ctx, frame, stack, 1, 0, opc);
        },
        op.get_loc2 => {
            try slot_ops.execGetLoc(ctx, frame, stack, 2, 0, opc);
        },
        op.get_loc3 => {
            try slot_ops.execGetLoc(ctx, frame, stack, 3, 0, opc);
        },
        op.put_loc0 => try slot_ops.execPutLoc(ctx, frame, stack, 0, 0, opc),
        op.put_loc1 => try slot_ops.execPutLoc(ctx, frame, stack, 1, 0, opc),
        op.put_loc2 => try slot_ops.execPutLoc(ctx, frame, stack, 2, 0, opc),
        op.put_loc3 => try slot_ops.execPutLoc(ctx, frame, stack, 3, 0, opc),
        op.set_loc0 => try slot_ops.execSetLoc(ctx, frame, stack, 0, 0, opc),
        op.set_loc1 => try slot_ops.execSetLoc(ctx, frame, stack, 1, 0, opc),
        op.set_loc2 => try slot_ops.execSetLoc(ctx, frame, stack, 2, 0, opc),
        op.set_loc3 => try slot_ops.execSetLoc(ctx, frame, stack, 3, 0, opc),
        else => unreachable,
    }
}

pub noinline fn arg(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    opc: u8,
) !void {
    switch (opc) {
        op.get_arg => try slot_ops.execGetArg(ctx, frame, stack, readInt(u16, function.byteCode()[frame.pc..][0..2]), 2, opc),
        op.put_arg => try slot_ops.execPutArg(ctx, frame, stack, readInt(u16, function.byteCode()[frame.pc..][0..2]), 2, opc),
        op.set_arg => try slot_ops.execSetArg(ctx, frame, stack, readInt(u16, function.byteCode()[frame.pc..][0..2]), 2, opc),
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

pub noinline fn checkedLocVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    function: *const bytecode.FunctionBytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    opc: u8,
    catch_target: *?usize,
) !Step {
    const idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
    frame.pc += 2;
    if (idx >= frame.locals.len) return error.InvalidBytecode;

    switch (opc) {
        op.set_loc_uninitialized => {
            // A lexical reset starts a new binding instance. Detach any cell
            // from the previous instance before publishing the TDZ sentinel.
            try frame.closeLocalBinding(ctx.runtime, idx);
            value_slot.replaceOwned(ctx.runtime, &frame.locals[idx], core.JSValue.uninitialized());
        },
        op.get_loc_check => {
            if (frame.locals[idx].isUninitialized()) {
                const is_derived_this = function.isDerivedClassConstructor() and
                    idx < function.varDefs().len and
                    function.varDefs()[idx].var_name == core.atom.ids.this_;
                const err = if (is_derived_this) blk: {
                    _ = exception_ops.throwReferenceErrorMessage(ctx, global, "this is not initialized") catch |err| break :blk err;
                    unreachable;
                } else exception_ops.throwTdzReferenceError(ctx);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            }
            try stack.push(frame.locals[idx]);
        },
        op.get_loc_checkthis => {
            if (frame.locals[idx].isUninitialized()) {
                // This opcode is the compiler-generated implicit return after
                // derived-constructor return unwinding. QuickJS constructs its
                // ReferenceError in caller_ctx, so leave it as a distinct
                // sentinel for the caller frame instead of materializing here.
                return error.DerivedThisUninitialized;
            }
            try stack.push(frame.locals[idx]);
        },
        op.put_loc_check => {
            if (frame.locals[idx].isUninitialized()) {
                const err = exception_ops.throwTdzReferenceError(ctx);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            }
            const value = try stack.pop();
            if (idx < function.varDefs().len and function.varDefs()[idx].isConst()) {
                value.free(ctx.runtime);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
                return error.TypeError;
            }
            value_slot.replaceOwned(ctx.runtime, &frame.locals[idx], value);
        },
        op.set_loc_check => {
            if (frame.locals[idx].isUninitialized()) {
                const err = exception_ops.throwTdzReferenceError(ctx);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            }
            const value = stack.peek() orelse return error.StackUnderflow;
            value_slot.replaceOwned(ctx.runtime, &frame.locals[idx], value);
        },
        op.put_loc_check_init => {
            // Only derived `this` has once-only init semantics (double-super ->
            // "'this' can be initialized only once"). put_loc_check_init is also
            // emitted for other lexical inits (e.g. AnnexB block-function var
            // copies) that legitimately overwrite an already-set slot, so the
            // once-only error must stay gated on the derived-this binding.
            const is_derived_this = function.isDerivedClassConstructor() and
                idx < function.varDefs().len and
                function.varDefs()[idx].var_name == core.atom.ids.this_;
            if (is_derived_this and !frame.locals[idx].isUninitialized()) {
                _ = exception_ops.throwReferenceErrorMessage(ctx, global, "'this' can be initialized only once") catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
                unreachable;
            }
            const value = try stack.pop();
            value_slot.replaceOwned(ctx.runtime, &frame.locals[idx], value);
        },
        else => unreachable,
    }
    return .done;
}

pub fn varRef(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    function: *const bytecode.FunctionBytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    opc: u8,
    catch_target: *?usize,
) !Step {
    switch (opc) {
        op.get_var_ref, op.get_var_ref_check => {
            if (frame.pc + 2 > function.byteCode().len) return error.TypeError;
            const idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
            if (try tryFastDirectVarRefGet(function, frame, stack, idx, 2)) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, output, function, frame, stack, idx, 2, catch_target, global)) return .continue_loop;
        },
        op.put_var_ref, op.put_var_ref_check, op.put_var_ref_check_init => {
            if (frame.pc + 2 > function.byteCode().len) return error.TypeError;
            const idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
            try slot_ops.execPutVarRef(ctx, function, global, frame, stack, idx, 2, opc);
        },
        op.set_var_ref => {
            if (frame.pc + 2 > function.byteCode().len) return error.TypeError;
            try slot_ops.execSetVarRef(ctx, frame, stack, readInt(u16, function.byteCode()[frame.pc..][0..2]), 2, opc);
        },

        op.get_var_ref0 => {
            if (try tryFastDirectVarRefGet(function, frame, stack, 0, 0)) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, output, function, frame, stack, 0, 0, catch_target, global)) return .continue_loop;
        },
        op.get_var_ref1 => {
            if (try tryFastDirectVarRefGet(function, frame, stack, 1, 0)) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, output, function, frame, stack, 1, 0, catch_target, global)) return .continue_loop;
        },
        op.get_var_ref2 => {
            if (try tryFastDirectVarRefGet(function, frame, stack, 2, 0)) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, output, function, frame, stack, 2, 0, catch_target, global)) return .continue_loop;
        },
        op.get_var_ref3 => {
            if (try tryFastDirectVarRefGet(function, frame, stack, 3, 0)) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, output, function, frame, stack, 3, 0, catch_target, global)) return .continue_loop;
        },
        op.put_var_ref0 => try slot_ops.execPutVarRef(ctx, function, global, frame, stack, 0, 0, opc),
        op.put_var_ref1 => try slot_ops.execPutVarRef(ctx, function, global, frame, stack, 1, 0, opc),
        op.put_var_ref2 => try slot_ops.execPutVarRef(ctx, function, global, frame, stack, 2, 0, opc),
        op.put_var_ref3 => try slot_ops.execPutVarRef(ctx, function, global, frame, stack, 3, 0, opc),
        op.set_var_ref0 => try slot_ops.execSetVarRef(ctx, frame, stack, 0, 0, opc),
        op.set_var_ref1 => try slot_ops.execSetVarRef(ctx, frame, stack, 1, 0, opc),
        op.set_var_ref2 => try slot_ops.execSetVarRef(ctx, frame, stack, 2, 0, opc),
        op.set_var_ref3 => try slot_ops.execSetVarRef(ctx, frame, stack, 3, 0, opc),
        else => unreachable,
    }
    return .done;
}

pub noinline fn varRefVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    function: *const bytecode.FunctionBytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    opc: u8,
    catch_target: *?usize,
) !Step {
    return varRef(ctx, output, function, global, frame, stack, opc, catch_target) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
}

fn tryFastDirectVarRefGet(function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, stack: *stack_mod.Stack, idx: u16, consume: u8) !bool {
    if (call_runtime.closureVarIsNonLexicalGlobalSentinel(function, idx)) return false;
    const value = varRefReadableBorrowed(frame, idx) orelse return false;
    frame.pc += consume;
    try stack.push(value);
    return true;
}

pub noinline fn closeLoc(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    const idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
    frame.pc += 2;
    try frame.closeLocalBinding(ctx.runtime, idx);
}
