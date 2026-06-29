//! Global variable read/write/define opcode handlers and their fused fast paths.

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const dtoa = @import("../libs/number_format.zig");
const unicode_lib = @import("../libs/unicode.zig");
const frame_mod = @import("frame.zig");
const property_ic = @import("property_ic.zig");
const property_ops = @import("property_ops.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const call_runtime = @import("call_runtime.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const builtin_glue = @import("builtin_glue.zig");
const call_mod = @import("call.zig");
const eval_ops = @import("eval_ops.zig");
const exception_ops = @import("vm_exception_ops.zig");
const object_ops = @import("object_ops.zig");
const slot_ops = @import("slot_ops.zig");
const string_ops = @import("string_ops.zig");
const objectFromValue = object_ops.objectFromValue;
const readInt = call_runtime.readInt;
const varRefCellFromValue = slot_ops.varRefCellFromValue;

// Helpers that remain in vm_property.zig (shared with the leftover handlers).
const property_vm = @import("vm_property.zig");
const vm_property_locals = @import("vm_property_locals.zig");
const CollectionHostOutputKey = property_vm.CollectionHostOutputKey;
const CollectionHostOutputKeyOperand = property_vm.CollectionHostOutputKeyOperand;
const DecodedImmediateInt32 = property_vm.DecodedImmediateInt32;
const FastGlobalReadValue = property_vm.FastGlobalReadValue;
const LocalPut = property_vm.LocalPut;
const NumberStaticLiteralResult = property_vm.NumberStaticLiteralResult;
const Step = property_vm.Step;
const StoredGlobalDataValue = property_vm.StoredGlobalDataValue;
const StringNumberConstArg = property_vm.StringNumberConstArg;
const StringNumberConstCall = property_vm.StringNumberConstCall;
const TypedArrayLengthPrintGet = property_vm.TypedArrayLengthPrintGet;
const TypedArrayLengthPrintStore = property_vm.TypedArrayLengthPrintStore;
const arg = vm_property_locals.arg;
const atomAsciiText = property_vm.atomAsciiText;
const atomStringValueForFastPath = property_vm.atomStringValueForFastPath;
const backwardGotoTarget = property_vm.backwardGotoTarget;
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
const globalVarAtom = property_vm.globalVarAtom;
const hasObjectBinding = property_vm.hasObjectBinding;
const immediateInt32Operand = property_vm.immediateInt32Operand;
const isHostOutputFunctionValue = property_vm.isHostOutputFunctionValue;
const localReadableBorrowed = property_vm.localReadableBorrowed;
const slotValueBorrowed = property_vm.slotValueBorrowed;
const storeLocalCompletionBorrowedValue = property_vm.storeLocalCompletionBorrowedValue;
const stringFromValue = property_vm.stringFromValue;
const varRefReadableBorrowed = property_vm.varRefReadableBorrowed;
const varRefReadableBorrowedForFastPath = property_vm.varRefReadableBorrowedForFastPath;

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
const atom_number = core.atom.predefinedId("Number", .string).?;
const atom_print = core.atom.predefinedId("print", .string).?;
const atom_string = core.atom.predefinedId("String", .string).?;

pub inline fn hasDynamicGlobalOverlay(
    frame: *const frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) bool {
    return !eval_with_object.isUndefined() or
        eval_local_names.len != 0 or
        eval_var_ref_names.len != 0 or
        frame.evalLocalNames().len != 0 or
        frame.evalVarRefNames().len != 0;
}

inline fn closureVarAt(function: *const bytecode.Bytecode, idx: u16) ?bytecode.function_def.ClosureVar {
    if (idx >= function.closure_var.len) return null;
    return function.closure_var[idx];
}

/// Threaded-dispatch wrapper of property_vm.parentFunctionEvalBindingShadowsGlobal
/// keyed by the OP_get_var/OP_put_var operand index (zjs_vm.zig's register-resident
/// lanes hold the index, not the resolved atom). Resolves the atom and defers to the
/// shared check; top-level code and ordinary closures early-out before any name
/// comparison, so the var_ref fast lane keeps its perf for the common case.
pub inline fn parentEvalShadowsGlobalForIdx(
    rt: *core.JSRuntime,
    frame: *const frame_mod.Frame,
    function: *const bytecode.Bytecode,
    idx: u16,
) bool {
    if (!property_vm.frameClosureHasEvalParent(frame)) return false;
    const atom_id = globalVarAtom(function, idx) orelse return false;
    return property_vm.parentFunctionEvalBindingShadowsGlobal(rt, frame, atom_id);
}

/// A global lexical (let/const) shadows the global `var`/object binding of the
/// same name (qjs's separate global_var_obj lexical environment takes precedence
/// over global_obj). The bound var_ref cell is therefore NOT authoritative when a
/// like-named global lexical exists, so the fast lane must defer to the slow path
/// (which consults the lexical env first). Cheap when there are no global lexicals
/// (`ctx.lexicals == null`): a single null check, before any atom resolution.
pub inline fn globalLexicalShadowsGlobalForIdx(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    idx: u16,
) bool {
    if (ctx.lexicals == null) return false;
    const atom_id = globalVarAtom(function, idx) orelse return false;
    return call_runtime.globalLexicalHasForGlobal(ctx, global, atom_id);
}

fn throwGlobalTdz(
    ctx: *core.JSContext,
    global: *core.Object,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const err = exception_ops.throwTdzReference(ctx);
    if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
    return err;
}

inline fn inactiveGlobalOverlayState(
    ctx: *const core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *const frame_mod.Frame,
    atom_id: core.Atom,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) bool {
    if (atom_id == core.atom.ids.undefined_ or atom_id == core.atom.ids.arguments) return false;
    if (!eval_with_object.isUndefined()) return false;
    if (ctx.lexicals) |env| {
        if (env.shapeProps().len != 0) return false;
    }
    if (!frame.current_function.isUndefined()) return false;
    if (eval_local_names.len != 0 or eval_var_ref_names.len != 0) return false;
    if (frame.evalLocalNames().len != 0 or frame.evalVarRefNames().len != 0) return false;
    if (function.var_ref_names.len != 0 and frame.var_refs.len != 0 and frameHasVarRefBinding(function, frame, atom_id)) return false;
    return true;
}

inline fn cachedGlobalDataSlotIndex(
    function: *const bytecode.Bytecode,
    global: *core.Object,
    site_pc: usize,
    atom_id: core.Atom,
) ?usize {
    const slot = function.icSlotForPc(site_pc) orelse return null;
    if (slot.state == .mono) {
        const entry = slot.entries[0];
        if (entry.holder_shape_ref == null and
            entry.shape_ref == global.shape_ref and
            entry.atom_id == atom_id and
            entry.version == global.shape_ref.version)
        {
            return entry.slot_index;
        }
        return null;
    }
    return switch (slot.lookupOwnDataResult(global, atom_id)) {
        .hit => |index| index,
        .miss, .invalidated => null,
    };
}

inline fn cachedGlobalDataValue(
    function: *const bytecode.Bytecode,
    global: *core.Object,
    site_pc: usize,
    atom_id: core.Atom,
) ?core.JSValue {
    const index = cachedGlobalDataSlotIndex(function, global, site_pc, atom_id) orelse return null;
    if (index >= global.properties.len) return null;
    return global.asDataAt(index);
}

inline fn pushBorrowedFast(stack: *stack_mod.Stack, value: core.JSValue) !void {
    if (stack.values.len < stack.capacity) {
        stack.pushAssumeCapacity(value);
    } else {
        try stack.push(value);
    }
}

inline fn setCachedGlobalWritableDataAtOwned(
    rt: *core.JSRuntime,
    global: *core.Object,
    atom_id: core.Atom,
    index: usize,
    value: core.JSValue,
) bool {
    const props = global.shapeProps();
    if (index >= props.len) return false;
    const flags = core.property.Flags.fromBits(props[index].flags);
    if (!flags.writable or flags.deleted or flags.kind != .data) return false;
    const entry = &global.properties[index];
    const old_slot = entry.slot;
    entry.slot = .{ .data = value };
    core.object.destroyPropertySlot(rt, atom_id, flags, old_slot);
    return true;
}

pub noinline fn getVar(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
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
    eval_with_object: core.JSValue,
) !Step {
    const site_pc = frame.pc - 1;
    const ref_idx = readInt(u16, function.code[frame.pc..][0..2]);
    const atom_id = globalVarAtom(function, ref_idx) orelse return error.InvalidBytecode;
    frame.pc += 2;
    if (!hasDynamicGlobalOverlay(frame, eval_local_names, eval_var_ref_names, eval_with_object)) {
        if (ref_idx < frame.var_refs.len) {
            if (varRefCellFromValue(frame.var_refs[ref_idx])) |cell| {
                if (!cell.varRefIsDeletedSlot().*) {
                    const value = cell.pvalue.*;
                    if (!value.isUninitialized()) {
                        if (core.VarRef.fromValue(value) == null and
                            !call_runtime.globalLexicalHasForGlobal(ctx, global, atom_id) and
                            !(property_vm.frameClosureHasEvalParent(frame) and property_vm.parentFunctionEvalBindingShadowsGlobal(ctx.runtime, frame, atom_id)))
                        {
                            try stack.push(value);
                            return .done;
                        }
                    } else if (closureVarAt(function, ref_idx)) |cv| {
                        if (cv.is_lexical) return try throwGlobalTdz(ctx, global, stack, frame, catch_target);
                    } else if (cell.is_lexical) {
                        return try throwGlobalTdz(ctx, global, stack, frame, catch_target);
                    }
                }
            }
        } else if (closureVarAt(function, ref_idx)) |cv| {
            if (cv.is_lexical) return try throwGlobalTdz(ctx, global, stack, frame, catch_target);
        }
    }
    const opcode_profile = ctx.runtime.opcode_profile;
    if (opcode_profile == null) {
        if (cachedGlobalDataValue(function, global, site_pc, atom_id)) |value| {
            if (inactiveGlobalOverlayState(ctx, function, frame, atom_id, eval_local_names, eval_var_ref_names, eval_with_object)) {
                try pushBorrowedFast(stack, value);
                return .done;
            }
        }
    } else {
        core.profile.recordGlobalLookup();
    }
    if (atom_id == core.atom.ids.undefined_ and canUseFastGlobalUndefinedLookup(function, frame, eval_local_names, eval_var_ref_names, eval_with_object)) {
        if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |lex_value| {
            lex_value.free(ctx.runtime);
        } else {
            try stack.pushOwned(core.JSValue.undefinedValue());
            return .done;
        }
    }
    if (fastInstalledGlobalDataValueForAtomAtPc(ctx, function, global, frame, site_pc, atom_id, eval_local_names, eval_var_ref_names, eval_with_object)) |value| {
        return try useFastGlobalDataValue(ctx, output, stack, function, global, frame, catch_target, site_pc, atom_id, value, eval_local_names, eval_var_ref_names, eval_with_object);
    }
    if (canUseFastGlobalVarLookup(function, atom_id, frame, eval_local_names, eval_var_ref_names, eval_with_object)) {
        if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |lex_value| {
            if (lex_value.isUninitialized()) {
                lex_value.free(ctx.runtime);
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                return error.ReferenceError;
            }
            errdefer lex_value.free(ctx.runtime);
            try stack.pushOwned(lex_value);
            return .done;
        }
        if (globalDataPropertyValueForFastPath(ctx.runtime, global, function, site_pc, atom_id)) |value| {
            return try useFastGlobalDataValue(ctx, output, stack, function, global, frame, catch_target, site_pc, atom_id, value, eval_local_names, eval_var_ref_names, eval_with_object);
        }
    }
    const value = value: {
        const prefer_eval_arguments = atom_id == core.atom.ids.arguments and
            call_runtime.frameCurrentFunctionIsArrow(frame);
        if (prefer_eval_arguments) {
            if (call_runtime.lookupFrameLocalValue(ctx.runtime, function, frame, atom_id)) |slot_value| {
                if (slot_value.isUninitialized()) {
                    slot_value.free(ctx.runtime);
                    if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                    return error.ReferenceError;
                }
                break :value slot_value;
            }
            if (call_runtime.lookupFrameVarRef(ctx, global, function, frame, atom_id)) |slot_value| {
                if (slot_value.isUninitialized()) {
                    slot_value.free(ctx.runtime);
                    if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                    return error.ReferenceError;
                }
                break :value slot_value;
            }
            if (call_runtime.lookupFrameFirstEvalBindingValue(ctx.runtime, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, frame, atom_id)) |slot_value| {
                if (slot_value.isUninitialized()) {
                    slot_value.free(ctx.runtime);
                    if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                    return error.ReferenceError;
                }
                break :value slot_value;
            }
        } else {
            if (object_ops.withObjectBindingValue(ctx, output, global, eval_with_object, atom_id, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            }) |with_value| {
                break :value with_value;
            }
            if (call_runtime.lookupEvalBindingValue(ctx.runtime, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, frame, atom_id)) |slot_value| {
                if (slot_value.isUninitialized()) {
                    slot_value.free(ctx.runtime);
                    if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                    return error.ReferenceError;
                }
                break :value slot_value;
            }
            if (call_runtime.lookupFrameVarRef(ctx, global, function, frame, atom_id)) |slot_value| {
                if (slot_value.isUninitialized()) {
                    slot_value.free(ctx.runtime);
                    if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                    return error.ReferenceError;
                }
                break :value slot_value;
            }
        }
        if (call_runtime.lookupParentFunctionEvalBindingValue(ctx.runtime, frame, atom_id)) |slot_value| {
            if (slot_value.isUninitialized()) {
                slot_value.free(ctx.runtime);
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                return error.ReferenceError;
            }
            break :value slot_value;
        }
        if (atom_id == core.atom.ids.undefined_) break :value core.JSValue.undefinedValue();
        if (atom_id == core.atom.ids.arguments and eval_ops.directEvalShouldExposeImplicitArguments(frame)) {
            break :value try object_ops.frameArgumentsObject(ctx, global, frame);
        }
        if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |lex_value| {
            if (lex_value.isUninitialized()) {
                lex_value.free(ctx.runtime);
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
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
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            if (!has_global_binding) {
                if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                return error.ReferenceError;
            }
        }
        break :value try object_ops.getValueProperty(ctx, output, global, global_value, atom_id, function, frame);
    };
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
    return .done;
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

fn printHostOutputAtomLiteral(rt: *core.JSRuntime, output: ?*std.Io.Writer, atom_id: core.Atom) !void {
    const writer = output orelse return;
    if (core.atom.isTaggedInt(atom_id)) {
        try writer.print("{d}\n", .{core.atom.atomToUInt32(atom_id)});
        return;
    }
    try writer.writeAll(rt.atoms.name(atom_id) orelse "");
    try writer.writeByte('\n');
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
    if (global.hasExoticMethods()) return null;
    for (global.shapeProps(), 0..) |prop, property_index| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted or prop.atom_id != atom_id) continue;
        if (prop_flags.isAccessor()) return null;
        return switch (global.propKindAt(property_index)) {
            .data => .{ .value = global.properties[property_index].slot.data, .owned = false },
            .auto_init => .{ .value = global.getProperty(atom_id), .owned = true },
            .var_ref, .accessor => null,
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
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) !Step {
    _ = ctx;
    _ = output;
    _ = global;
    _ = catch_target;
    _ = site_pc;
    _ = atom_id;
    _ = eval_local_names;
    _ = eval_var_ref_names;
    _ = eval_with_object;
    const value_int = value.asInt32();
    if (value_int != null) {}
    if (value_int != null or value.asShortBigInt() != null) {} else {
        if (value.isString()) {} else if (nextOpCanStartGlobalUriCall1(function, frame)) {}
    }
    try stack.push(value);
    return .done;
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
    return native_ref.domain == .string and native_ref.id == @intFromEnum(method_ids.string.ConstructorMethod.call);
}

fn nextOpIsPostUpdate(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame) bool {
    if (frame.pc >= function.code.len) return false;
    return function.code[frame.pc] == op.post_inc or function.code[frame.pc] == op.post_dec;
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
) ?core.JSValue {
    if (!canUseFastGlobalVarLookup(function, atom_id, frame, eval_local_names, eval_var_ref_names, eval_with_object)) return null;
    if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |lexical_value| {
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
        op.get_var, op.get_var_undef => frame.pc + 4 <= code.len and code[frame.pc + 3] == op.call1,
        else => false,
    };
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
) ?core.JSValue {
    const get = decodeGlobalDataGet(function, pc.*) orelse return null;
    const value = fastGlobalDataValueForAtomAtPc(ctx, function, global, frame, pc.*, get.atom, eval_local_names, eval_var_ref_names, eval_with_object) orelse return null;
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
    _ = global;
    _ = eval_local_names;
    _ = eval_var_ref_names;
    _ = eval_with_object;
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
                    try stack.pushOwned(result);
                    return;
                }
            }
        }
    }
    try stack.pushOwned(rhs_value);
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

pub noinline fn putVar(
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
) !Step {
    const ref_idx = readInt(u16, function.code[frame.pc..][0..2]);
    const atom_id = globalVarAtom(function, ref_idx) orelse return error.InvalidBytecode;
    frame.pc += 2;
    const value = try stack.pop();
    if (!hasDynamicGlobalOverlay(frame, eval_local_names, eval_var_ref_names, eval_with_object)) {
        if (ref_idx < frame.var_refs.len) {
            if (varRefCellFromValue(frame.var_refs[ref_idx])) |cell| {
                if (!cell.varRefIsDeletedSlot().*) {
                    const current = cell.pvalue.*;
                    if (!current.isUninitialized()) {
                        if (core.VarRef.fromValue(current) == null and !cell.varRefIsFunctionNameSlot().* and
                            !call_runtime.globalLexicalHasForGlobal(ctx, global, atom_id) and
                            !(property_vm.frameClosureHasEvalParent(frame) and property_vm.parentFunctionEvalBindingShadowsGlobal(ctx.runtime, frame, atom_id)))
                        {
                            if (cell.varRefIsConstSlot().*) {
                                value.free(ctx.runtime);
                                _ = exception_ops.throwTypeErrorMessage(ctx, global, "invalid assignment to const variable") catch |err| {
                                    if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                                    return err;
                                };
                                return error.TypeError;
                            }
                            errdefer value.free(ctx.runtime);
                            try cell.setVarRefValue(ctx.runtime, value);
                            return .done;
                        }
                    } else if (closureVarAt(function, ref_idx)) |cv| {
                        if (cv.is_lexical) {
                            value.free(ctx.runtime);
                            return try throwGlobalTdz(ctx, global, stack, frame, catch_target);
                        }
                    } else if (cell.is_lexical) {
                        value.free(ctx.runtime);
                        return try throwGlobalTdz(ctx, global, stack, frame, catch_target);
                    }
                }
            }
        } else if (closureVarAt(function, ref_idx)) |cv| {
            if (cv.is_lexical) {
                value.free(ctx.runtime);
                return try throwGlobalTdz(ctx, global, stack, frame, catch_target);
            }
        }
    }
    const opcode_profile = ctx.runtime.opcode_profile;
    if (opcode_profile != null) core.profile.recordGlobalLookup();
    if (opcode_profile == null) {
        const site_pc = frame.pc - 3;
        if (cachedGlobalDataSlotIndex(function, global, site_pc, atom_id)) |index| {
            if (inactiveGlobalOverlayState(ctx, function, frame, atom_id, eval_local_names, eval_var_ref_names, eval_with_object) and
                setCachedGlobalWritableDataAtOwned(ctx.runtime, global, atom_id, index, value))
            {
                return .continue_loop;
            }
        }
    }
    const runtime_strict = function.flags.is_strict or function.flags.runtime_strict;
    if (canUseFastGlobalVarWrite(ctx, function, atom_id, frame, eval_local_names, eval_var_ref_names, eval_with_object)) {
        if (call_runtime.setGlobalLexicalValueForFastPathOwned(ctx, atom_id, value) catch |err| {
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
    if (try assignDirectEvalGlobalNamedSlot(ctx, global, function, eval_local_names, eval_local_slots, atom_id, value)) return .continue_loop;
    if (try call_runtime.setNamedSlotValue(ctx, global, eval_local_names, eval_local_slots, atom_id, value)) return .continue_loop;
    if (!frame.evalVarRefsRepublished()) {
        if (call_runtime.setNamedVarRefValue(ctx, eval_var_ref_names, eval_var_refs, atom_id, value, runtime_strict or strict_unresolved_get_var, false) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        }) return .continue_loop;
    }
    if (try call_runtime.setNamedSlotValue(ctx, global, frame.evalLocalNames(), frame.evalLocalSlots(), atom_id, value)) return .continue_loop;
    if (call_runtime.setNamedVarRefValue(ctx, frame.evalVarRefNames(), frame.evalVarRefs(), atom_id, value, runtime_strict or strict_unresolved_get_var, false) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    }) return .continue_loop;
    if (atom_id == core.atom.ids.arguments and eval_ops.directEvalShouldExposeImplicitArguments(frame)) {
        const old_value = frame.argumentsObject();
        (try frame.ensureCold(&ctx.runtime.memory)).arguments_object = value;
        if (old_value) |stored| stored.free(ctx.runtime);
        return .continue_loop;
    }
    const updated_global_lexical = call_runtime.setGlobalLexicalValueForGlobal(ctx, global, atom_id, value) catch |err| {
        value.free(ctx.runtime);
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    if (updated_global_lexical) {
        try syncFrameVarRefMirror(ctx, function, frame, atom_id, value);
        value.free(ctx.runtime);
        return .continue_loop;
    }
    if (runtime_strict or strict_unresolved_get_var) {
        const global_value = global.value().dup();
        defer global_value.free(ctx.runtime);
        const has_global_binding = hasObjectBinding(ctx, output, global, global_value, global, atom_id, function, frame) catch |err| {
            value.free(ctx.runtime);
            if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
        if (!has_global_binding) {
            value.free(ctx.runtime);
            if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
            return error.ReferenceError;
        }
    }
    if (is_eval_code and
        eval_global_var_bindings and
        !runtime_strict and
        evalFunctionDeclaresGlobalVar(ctx.runtime, function, atom_id) and
        globalOwnAccessorWithoutSetter(ctx.runtime, global, atom_id))
    {
        value.free(ctx.runtime);
        return .continue_loop;
    }
    if (try global.setOwnWritableDataProperty(ctx.runtime, atom_id, value)) {
        try syncFrameVarRefMirror(ctx, function, frame, atom_id, value);
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
    _ = object_ops.setValueProperty(ctx, output, global, global_value, atom_id, value, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    try syncFrameVarRefMirror(ctx, function, frame, atom_id, value);
    return .done;
}

fn assignDirectEvalGlobalNamedSlot(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    names: []const core.Atom,
    slots: []core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
) !bool {
    if (!value_ops.atomNameEql(ctx.runtime, function.name, "<eval>")) return false;
    if (!evalFunctionDeclaresGlobalVar(ctx.runtime, function, atom_id)) return false;

    for (names, 0..) |name, idx| {
        if (!call_runtime.atomIdOrNameEql(ctx.runtime, name, atom_id) or idx >= slots.len) continue;
        if (!slot_ops.evalLocalSlotIsEvalVarCell(slots[idx])) continue;
        defer value.free(ctx.runtime);
        if (!try global.setOwnWritableDataProperty(ctx.runtime, atom_id, value)) {
            if (!global.hasOwnProperty(atom_id)) {
                try slot_ops.defineGlobalFunctionBindingValue(ctx.runtime, global, atom_id, value, true);
            }
        }
        const next_value = global.getProperty(atom_id);
        try slot_ops.setSlotValue(ctx, &slots[idx], next_value);
        return true;
    }
    return false;
}

fn globalOwnRejectedNonStrictSet(global: *core.Object, atom_id: core.Atom) bool {
    if (global.hasExoticMethods()) return false;
    for (global.shapeProps(), 0..) |prop, property_index| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted or prop.atom_id != atom_id) continue;
        if (prop_flags.isAccessor()) {
            return global.properties[property_index].slot.accessor.setterIsUndefined();
        }
        return switch (global.propKindAt(property_index)) {
            .data => !prop_flags.writable,
            .var_ref, .auto_init, .accessor => false,
        };
    }
    return false;
}

fn globalWritableDataWriteFastOwned(ctx: *core.JSContext, global: *core.Object, function: *const bytecode.Bytecode, frame: *frame_mod.Frame, atom_id: core.Atom, value: core.JSValue) !bool {
    const rt = ctx.runtime;
    const site_pc = frame.pc - 3;
    return setGlobalWritableDataStoreForFastPathOwned(rt, ctx.lexicals, global, function, site_pc, atom_id, value);
}

fn syncFrameVarRefMirror(ctx: *core.JSContext, function: *const bytecode.Bytecode, frame: *frame_mod.Frame, atom_id: core.Atom, value: core.JSValue) !void {
    var frame_ref_value = value.dup();
    if (!try call_runtime.setFrameVarRefValue(ctx, function, frame, atom_id, frame_ref_value)) {
        frame_ref_value.free(ctx.runtime);
    }
}

fn numberStaticLiteralResultAt(
    rt: *core.JSRuntime,
    function: *const bytecode.Bytecode,
    native_id: u32,
    pc: usize,
) ?NumberStaticLiteralResult {
    const code = function.code;
    const number_static = method_ids.number.StaticMethod;
    const number_parse = core.number;
    return switch (native_id) {
        @intFromEnum(number_static.parse_int) => blk: {
            if (pc + 5 > code.len or code[pc] != op.push_atom_value) return null;
            const string_atom = readInt(u32, code[pc + 1 ..][0..4]);
            var atom_buf: [10]u8 = undefined;
            const text = atomAsciiText(rt, string_atom, &atom_buf) orelse return null;
            const radix_operand = immediateInt32Operand(code, pc + 5) orelse return null;
            if (radix_operand.next_pc + 3 > code.len or code[radix_operand.next_pc] != op.call_method) return null;
            if (readInt(u16, code[radix_operand.next_pc + 1 ..][0..2]) != 2) return null;
            break :blk .{
                .number = number_parse.parseIntLatin1Bytes(text, radix_operand.value),
                .next_pc = radix_operand.next_pc + 3,
            };
        },
        @intFromEnum(number_static.parse_float) => blk: {
            if (pc + 8 > code.len or code[pc] != op.push_atom_value) return null;
            const string_atom = readInt(u32, code[pc + 1 ..][0..4]);
            var atom_buf: [10]u8 = undefined;
            const text = atomAsciiText(rt, string_atom, &atom_buf) orelse return null;
            const call_pc = pc + 5;
            if (code[call_pc] != op.call_method) return null;
            if (readInt(u16, code[call_pc + 1 ..][0..2]) != 1) return null;
            break :blk .{
                .number = number_parse.parseFloatLatin1Bytes(text),
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
    if (frame.evalLocalNames().len != 0 or frame.evalVarRefNames().len != 0) return false;
    return true;
}

fn evalFunctionDeclaresGlobalVar(rt: *core.JSRuntime, function: *const bytecode.Bytecode, atom_id: core.Atom) bool {
    for (function.global_vars) |gv| {
        if (gv.is_lexical) continue;
        if (call_runtime.atomIdOrNameEql(rt, gv.var_name, atom_id)) return true;
    }
    return false;
}

fn globalOwnAccessorWithoutSetter(rt: *core.JSRuntime, global: *core.Object, atom_id: core.Atom) bool {
    const desc = global.getOwnProperty(rt, atom_id) orelse return false;
    defer desc.destroy(rt);
    return desc.kind == .accessor and desc.setter.isUndefined();
}

fn globalVarIsFunction(gv: core.function_bytecode.GlobalVar) bool {
    return gv.cpool_idx >= 0 or gv.force_init;
}

fn shouldSkipRuntimeStrictGlobalFunctionVar(
    function: *const bytecode.Bytecode,
    is_eval_code: bool,
    gv: core.function_bytecode.GlobalVar,
) bool {
    return function.flags.runtime_strict and !is_eval_code and globalVarIsFunction(gv);
}

fn validateGlobalVarDeclaration(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    gv: core.function_bytecode.GlobalVar,
    is_eval_code: bool,
) !void {
    if (shouldSkipRuntimeStrictGlobalFunctionVar(function, is_eval_code, gv)) return;

    const atom_id = gv.var_name;
    const has_global_lexical = call_runtime.globalLexicalHasForGlobal(ctx, global, atom_id);
    if (global.getOwnProperty(ctx.runtime, atom_id)) |desc| {
        defer desc.destroy(ctx.runtime);
        if (gv.is_lexical) {
            if (desc.configurable != true) return error.SyntaxError;
        } else if (globalVarIsFunction(gv) and desc.configurable != true) {
            if (desc.kind == .accessor or desc.writable != true or desc.enumerable != true) return error.TypeError;
        }
    } else if (!gv.is_lexical and !global.isExtensible()) {
        return error.TypeError;
    }
    if (has_global_lexical) return error.SyntaxError;
}

fn defineGlobalVarDeclaration(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    gv: core.function_bytecode.GlobalVar,
    is_eval_code: bool,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
) !void {
    const atom_id = gv.var_name;
    if (gv.cpool_idx >= 0) {
        const cpool_idx: usize = @intCast(gv.cpool_idx);
        const function_value = function.constants.get(cpool_idx) orelse return error.InvalidBytecode;
        defer function_value.free(ctx.runtime);
        const func_val = try object_ops.createBytecodeFunctionObject(ctx, frame, function, global, function_value, atom_id, op.fclosure8, true, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, &.{});
        defer func_val.free(ctx.runtime);

        var local_value = func_val.dup();
        const updated_frame_local = try call_runtime.setFrameLocalValue(ctx, function, frame, atom_id, local_value);
        if (!updated_frame_local) local_value.free(ctx.runtime);
        var frame_ref_value = func_val.dup();
        if (!try call_runtime.setFrameVarRefValue(ctx, function, frame, atom_id, frame_ref_value)) frame_ref_value.free(ctx.runtime);
        var eval_local_value = func_val.dup();
        const updated_eval_local = try call_runtime.setNamedSlotValue(ctx, global, eval_local_names, eval_local_slots, atom_id, eval_local_value);
        if (!updated_eval_local) eval_local_value.free(ctx.runtime);
        var eval_ref_value = func_val.dup();
        const updated_eval_ref = try call_runtime.setNamedVarRefValue(ctx, eval_var_ref_names, eval_var_refs, atom_id, eval_ref_value, function.flags.is_strict, true);
        if (!updated_eval_ref) eval_ref_value.free(ctx.runtime);

        if (function.flags.runtime_strict and !is_eval_code) return;
        try slot_ops.defineGlobalFunctionBindingValue(ctx.runtime, global, atom_id, func_val, gv.is_configurable);
        return;
    }

    if (shouldSkipRuntimeStrictGlobalFunctionVar(function, is_eval_code, gv)) return;

    if (gv.is_lexical) {
        // qjs js_closure_define_global_var PASS2: create the shared ctx.lexicals
        // VARREF cell and alias it into frame.var_refs for a top-level script
        // let/const (.global_decl var-ref). Falls back to a plain lexical data
        // property for module/eval paths.
        if (!try call_runtime.defineGlobalDeclLexicalCell(ctx, function, frame, atom_id, gv.is_const)) {
            try call_runtime.defineGlobalLexicalValue(ctx, global, atom_id, core.JSValue.uninitialized(), gv.is_const);
        }
    } else if (!global.hasOwnProperty(atom_id)) {
        const desc = core.Descriptor.data(core.JSValue.undefinedValue(), true, true, gv.is_configurable);
        const define_result = if (!global.hasExoticMethods() and !global.flags.is_array and global.isExtensible())
            global.defineOwnPropertyAssumingNew(ctx.runtime, atom_id, desc)
        else
            global.defineOwnProperty(ctx.runtime, atom_id, desc);
        define_result catch |err| switch (err) {
            error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
            else => return err,
        };
    }
}

pub fn instantiateGlobalVarDeclarations(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    is_eval_code: bool,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
) !void {
    if (function.global_vars.len == 0) return;
    for (function.global_vars) |gv| {
        try validateGlobalVarDeclaration(ctx, global, function, gv, is_eval_code);
    }
    if (!is_eval_code) {
        for (function.global_vars) |gv| {
            if (gv.is_lexical) continue;
            if (shouldSkipRuntimeStrictGlobalFunctionVar(function, is_eval_code, gv)) continue;
            _ = try call_runtime.defineGlobalDeclVarCell(ctx, global, function, frame, gv.var_name, gv.is_configurable);
        }
    }
    for (function.global_vars) |gv| {
        try defineGlobalVarDeclaration(ctx, global, function, frame, gv, is_eval_code, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs);
    }
}

fn fastLengthValue(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    if (value.isString()) {
        const string_value = value.asStringBody() orelse return error.TypeError;
        return core.JSValue.int32(@intCast(string_value.len()));
    }
    const object = objectFromValue(value) orelse return error.TypeError;
    if (object.proxyTarget() != null) return error.TypeError;
    if (object.flags.is_array) {
        if (object.arrayLength() <= @as(u32, @intCast(std.math.maxInt(i32)))) {
            return core.JSValue.int32(@intCast(object.arrayLength()));
        }
        return core.JSValue.float64(@floatFromInt(object.arrayLength()));
    }
    if (core.object.isTypedArrayObject(object)) {
        return core.JSValue.int32(@intCast(try core.object.typedArrayLength(rt, object)));
    }
    return error.TypeError;
}

pub noinline fn globalDefinition(
    ctx: *core.JSContext,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
) !Step {
    switch (opc) {
        op.put_var_init => {
            const ref_idx = readInt(u16, function.code[frame.pc..][0..2]);
            const atom_id = globalVarAtom(function, ref_idx) orelse return error.InvalidBytecode;
            frame.pc += 2;
            const value = try stack.pop();
            var value_owned = true;
            defer if (value_owned) value.free(ctx.runtime);
            if (!function.flags.is_indirect_eval) {
                const fast_global_lexical = call_runtime.setGlobalLexicalValueForFastPathOwned(ctx, atom_id, value) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
                if (fast_global_lexical) {
                    value_owned = false;
                    return .continue_loop;
                }
                const updated_global_lexical = call_runtime.setGlobalLexicalValueForGlobal(ctx, global, atom_id, value) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
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
