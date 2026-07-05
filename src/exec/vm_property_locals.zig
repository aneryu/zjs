//! Local/arg/var-ref slot opcode handlers (get/put/set_loc, get/put_arg, var_ref forms, close_loc).

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const core = @import("../core/root.zig");
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
const ImmediateInt32 = property_vm.ImmediateInt32;
const IntRangeDeltaBounds = property_vm.IntRangeDeltaBounds;
const LocalPut = property_vm.LocalPut;
const Step = property_vm.Step;
const atomStringValueForFastPath = property_vm.atomStringValueForFastPath;
const backwardGotoTarget = property_vm.backwardGotoTarget;
const bindingReadableBorrowed = property_vm.bindingReadableBorrowed;
const bindingStoreWritableForFastPath = property_vm.bindingStoreWritableForFastPath;
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
const denseArrayModFieldInt32Increments = property_vm.denseArrayModFieldInt32Increments;
const fastArrayPrototypeMethodIsDefault = property_vm.fastArrayPrototypeMethodIsDefault;
const fastCollectionPrototypeMethodIsDefault = property_vm.fastCollectionPrototypeMethodIsDefault;
const fastGlobalDataValueForAtomAtPc = property_vm.fastGlobalDataValueForAtomAtPc;
const fastInstalledGlobalDataValueForAtomAtPc = property_vm.fastInstalledGlobalDataValueForAtomAtPc;
const fastInt32Add = property_vm.fastInt32Add;
const fastRegExpPrototypeMethodIsDefault = property_vm.fastRegExpPrototypeMethodIsDefault;
const frameHasVarRefBinding = property_vm.frameHasVarRefBinding;
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
const slotValueBorrowed = property_vm.slotValueBorrowed;
const storeBindingOwnedValue = property_vm.storeBindingOwnedValue;
const storeLocalCompletionBorrowedValue = property_vm.storeLocalCompletionBorrowedValue;
const storeStringSliceConstLocal = property_vm.storeStringSliceConstLocal;
const stringFromCharCodeInt32Arg = property_vm.stringFromCharCodeInt32Arg;
const stringFromValue = property_vm.stringFromValue;
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

pub noinline fn loc(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    opc: u8,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) !void {
    _ = eval_local_names;
    _ = eval_var_ref_names;
    _ = eval_with_object;
    switch (opc) {
        op.get_loc => {
            const idx = readInt(u16, function.code[frame.pc..][0..2]);
            try slot_ops.execGetLoc(ctx, frame, stack, idx, 2, opc);
        },
        op.put_loc => try slot_ops.execPutLoc(ctx, function, global, frame, stack, readInt(u16, function.code[frame.pc..][0..2]), 2, opc),
        op.set_loc => try slot_ops.execSetLoc(ctx, function, global, frame, stack, readInt(u16, function.code[frame.pc..][0..2]), 2, opc),

        op.get_loc8 => {
            const idx = function.code[frame.pc];
            try slot_ops.execGetLoc(ctx, frame, stack, idx, 1, opc);
        },
        op.put_loc8 => try slot_ops.execPutLoc(ctx, function, global, frame, stack, function.code[frame.pc], 1, opc),
        op.set_loc8 => try slot_ops.execSetLoc(ctx, function, global, frame, stack, function.code[frame.pc], 1, opc),

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
        op.put_loc0 => try slot_ops.execPutLoc(ctx, function, global, frame, stack, 0, 0, opc),
        op.put_loc1 => try slot_ops.execPutLoc(ctx, function, global, frame, stack, 1, 0, opc),
        op.put_loc2 => try slot_ops.execPutLoc(ctx, function, global, frame, stack, 2, 0, opc),
        op.put_loc3 => try slot_ops.execPutLoc(ctx, function, global, frame, stack, 3, 0, opc),
        op.set_loc0 => try slot_ops.execSetLoc(ctx, function, global, frame, stack, 0, 0, opc),
        op.set_loc1 => try slot_ops.execSetLoc(ctx, function, global, frame, stack, 1, 0, opc),
        op.set_loc2 => try slot_ops.execSetLoc(ctx, function, global, frame, stack, 2, 0, opc),
        op.set_loc3 => try slot_ops.execSetLoc(ctx, function, global, frame, stack, 3, 0, opc),
        else => unreachable,
    }
}

pub noinline fn arg(
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

pub noinline fn checkedLocVm(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    opc: u8,
    catch_target: *?usize,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) !Step {
    _ = eval_local_names;
    _ = eval_var_ref_names;
    _ = eval_with_object;
    const idx = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    if (idx >= frame.locals.len) return error.InvalidBytecode;

    switch (opc) {
        op.set_loc_uninitialized => {
            // Mirror the slot's TDZ state in its value tag (lets the dispatch
            // fast paths test the tag instead of the side bitmap). Free the old
            // binding first: on block re-entry (loop) the slot may hold the
            // previous iteration's value/var-ref cell, which a captured closure
            // still references via its own dup — we only drop the slot's share.
            const cur_binding = frame.locals[idx];
            if (slot_ops.varRefCellFromValue(cur_binding)) |cell| {
                try cell.setVarRefValue(ctx.runtime, core.JSValue.uninitialized());
            } else {
                frame.locals[idx] = core.JSValue.uninitialized();
                cur_binding.free(ctx.runtime);
            }
        },
        op.get_loc_check, op.get_loc_checkthis => {
            if (slot_ops.varRefSlotIsUninitialized(frame.locals[idx])) {
                const err = exception_ops.throwTdzReference(ctx);
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            }
            try array_ops.pushSlotValue(stack, frame.locals[idx]);
        },
        op.put_loc_check => {
            if (slot_ops.varRefSlotIsUninitialized(frame.locals[idx])) {
                const err = exception_ops.throwTdzReference(ctx);
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            }
            const value = try stack.pop();
            if (idx < function.vardefs.len and function.vardefs[idx].is_const) {
                value.free(ctx.runtime);
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
                return error.TypeError;
            }
            try slot_ops.setSlotValue(ctx, &frame.locals[idx], value);
        },
        op.set_loc_check => {
            if (slot_ops.varRefSlotIsUninitialized(frame.locals[idx])) {
                const err = exception_ops.throwTdzReference(ctx);
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            }
            const value = stack.peek() orelse return error.StackUnderflow;
            try slot_ops.setSlotValue(ctx, &frame.locals[idx], value);
        },
        op.put_loc_check_init => {
            const is_derived_this = function.flags.is_derived_class_constructor and
                idx < function.vardefs.len and
                function.vardefs[idx].var_name == 8;
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
        },
        else => unreachable,
    }
    return .done;
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
    _ = eval_local_names;
    _ = eval_var_ref_names;
    _ = eval_with_object;
    switch (opc) {
        op.get_var_ref, op.get_var_ref_check => {
            if (frame.pc + 2 > function.code.len) return error.TypeError;
            const idx = readInt(u16, function.code[frame.pc..][0..2]);
            if (try tryFastDirectVarRefGet(function, frame, stack, idx, 2)) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, function, frame, stack, idx, 2, catch_target, global)) return .continue_loop;
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
            if (try tryFastDirectVarRefGet(function, frame, stack, 0, 0)) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, function, frame, stack, 0, 0, catch_target, global)) return .continue_loop;
        },
        op.get_var_ref1 => {
            if (try tryFastDirectVarRefGet(function, frame, stack, 1, 0)) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, function, frame, stack, 1, 0, catch_target, global)) return .continue_loop;
        },
        op.get_var_ref2 => {
            if (try tryFastDirectVarRefGet(function, frame, stack, 2, 0)) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, function, frame, stack, 2, 0, catch_target, global)) return .continue_loop;
        },
        op.get_var_ref3 => {
            if (try tryFastDirectVarRefGet(function, frame, stack, 3, 0)) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, function, frame, stack, 3, 0, catch_target, global)) return .continue_loop;
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

pub noinline fn varRefVm(
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

fn tryFastDirectVarRefGet(function: *const bytecode.Bytecode, frame: *frame_mod.Frame, stack: *stack_mod.Stack, idx: u16, consume: u8) !bool {
    if (call_runtime.closureVarIsNonLexicalGlobalSentinel(function, idx)) return false;
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
) !void {
    _ = function;
    _ = global;
    if (binding.is_var_ref) {
        try slot_ops.setVarRefSlotValue(ctx, frame, binding.idx, core.JSValue.int32(value));
    } else {
        try slot_ops.setSlotValue(ctx, &frame.locals[binding.idx], core.JSValue.int32(value));
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
) !void {
    try storeBindingInt32(ctx, function, global, frame, accumulator_put, value);
    if (completion_put) |completion| {
        if (!sameBindingPut(accumulator_put, completion)) {
            try storeBindingInt32(ctx, function, global, frame, completion, value);
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
) !void {
    _ = function;
    _ = global;
    if (completion_put) |completion| {
        if (!sameBindingPut(accumulator_put, completion)) {
            try storeBindingOwnedValue(ctx, frame, accumulator_put, value.dup());
            try storeBindingOwnedValue(ctx, frame, completion, value);
            return;
        }
    }
    try storeBindingOwnedValue(ctx, frame, accumulator_put, value);
}

fn storeLocalInt32WithCompletion(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    idx: u16,
    completion_put: ?LocalPut,
    value: i32,
) !void {
    _ = function;
    _ = global;
    try slot_ops.setSlotValue(ctx, &frame.locals[idx], core.JSValue.int32(value));
    if (completion_put) |completion| {
        if (completion.idx != idx) {
            try slot_ops.setSlotValue(ctx, &frame.locals[completion.idx], core.JSValue.int32(value));
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
) !void {
    _ = function;
    _ = global;
    if (completion_put) |completion| {
        if (completion.idx != idx) {
            try slot_ops.setSlotValue(ctx, &frame.locals[idx], value.dup());
            try slot_ops.setSlotValue(ctx, &frame.locals[completion.idx], value);
            return;
        }
    }
    try slot_ops.setSlotValue(ctx, &frame.locals[idx], value);
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
    if (first_value_idx >= frame.locals.len) return null;
    if (slot_ops.varRefSlotIsUninitialized(frame.locals[first_value_idx])) return null;
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
    if (frame.evalLocalNames().len != 0 or frame.evalVarRefNames().len != 0) return null;
    if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |lexical_value| {
        lexical_value.free(ctx.runtime);
        return null;
    }
    if (globalOwnDataPropertyValue(global, atom_id)) |value| return value;
    if (global.hasExoticMethods()) return null;

    const desc = global.getOwnProperty(ctx.runtime, atom_id) orelse return null;
    defer desc.destroy(ctx.runtime);
    if (desc.kind != .data or !desc.value_present) return null;

    return globalOwnDataPropertyValue(global, atom_id);
}

fn fitsI64(value: i128) bool {
    return value >= @as(i128, std.math.minInt(i64)) and value <= @as(i128, std.math.maxInt(i64));
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
    if (object.proxyTarget() != null or object.hasExoticMethods()) return null;
    if (!object.flags.is_array or object.arrayElementStorageMode() != .dense) return null;
    if (index >= @as(usize, @intCast(object.arrayLength()))) return null;
    const elements = object.arrayElements();
    if (index >= elements.len) return null;
    const element = elements[index];
    return .{ .value = element.asInt32() orelse return null, .next_pc = pc + 2 };
}

fn denseArrayInt32RangeDelta(object: *core.Object, start: usize, limit: usize) ?IntRangeDeltaBounds {
    if (start > limit) return null;
    if (object.proxyTarget() != null or object.hasExoticMethods()) return null;
    if (!object.flags.is_array or object.arrayElementStorageMode() != .dense) return null;
    if (limit > @as(usize, @intCast(object.arrayLength()))) return null;
    const elements = object.arrayElements();
    if (limit > elements.len) return null;

    var total: i128 = 0;
    var min_delta: i128 = 0;
    var max_delta: i128 = 0;
    for (elements[start..limit]) |value| {
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

pub noinline fn closeLoc(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !void {
    const idx = readInt(u16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    try slot_ops.closeLocalVarRef(ctx, frame, idx);
}
