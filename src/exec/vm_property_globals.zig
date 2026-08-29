//! Global variable read/write/define opcode handlers and their fused fast paths.

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const property_direct = @import("property_direct.zig");
const property_ops = @import("property_ops.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const call_runtime = @import("call_runtime.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const builtin_glue = @import("builtin_glue.zig");
const exception_ops = @import("exception_ops.zig");
const object_ops = @import("object_ops.zig");
const slot_ops = @import("slot_ops.zig");
const string_ops = @import("string_ops.zig");
const objectFromValue = object_ops.objectFromValue;
const readInt = call_runtime.readInt;
const varRefCellFromValue = slot_ops.varRefCellFromValue;

// Helpers that remain in vm_property.zig (shared with the leftover handlers).
const vm_property = @import("vm_property.zig");
const vm_property_locals = @import("vm_property_locals.zig");
const CollectionHostOutputKey = vm_property.CollectionHostOutputKey;
const CollectionHostOutputKeyOperand = vm_property.CollectionHostOutputKeyOperand;
const DecodedImmediateInt32 = vm_property.DecodedImmediateInt32;
const FastGlobalReadValue = vm_property.FastGlobalReadValue;
const LocalPut = vm_property.LocalPut;
const NumberStaticLiteralResult = vm_property.NumberStaticLiteralResult;
const Step = vm_property.Step;
const StoredGlobalDataValue = vm_property.StoredGlobalDataValue;
const StringNumberConstArg = vm_property.StringNumberConstArg;
const StringNumberConstCall = vm_property.StringNumberConstCall;
const TypedArrayLengthPrintGet = vm_property.TypedArrayLengthPrintGet;
const TypedArrayLengthPrintStore = vm_property.TypedArrayLengthPrintStore;
const arg = vm_property_locals.arg;
const atomAsciiText = vm_property.atomAsciiText;
const atomStringValueForFastPath = vm_property.atomStringValueForFastPath;
const backwardGotoTarget = vm_property.backwardGotoTarget;
const canFinishWithUndefinedAt = vm_property.canFinishWithUndefinedAt;
const canFuseGlobalDataWrite = vm_property.canFuseGlobalDataWrite;
const canUseFastGlobalVarLookup = vm_property.canUseFastGlobalVarLookup;
const canUseInstalledGlobalDataIc = vm_property.canUseInstalledGlobalDataIc;
const decodeFalseBranch = vm_property.decodeFalseBranch;
const decodeFieldAtom = vm_property.decodeFieldAtom;
const decodeGlobalDataGet = vm_property.decodeGlobalDataGet;
const decodeGlobalPut = vm_property.decodeGlobalPut;
const decodeLocalGet = vm_property.decodeLocalGet;
const decodeOptionalLocalCompletionTail = vm_property.decodeOptionalLocalCompletionTail;
const fastArrayPrototypeMethodIsDefault = vm_property.fastArrayPrototypeMethodIsDefault;
const fastCollectionPrototypeMethodIsDefault = vm_property.fastCollectionPrototypeMethodIsDefault;
const fastDenseArrayElementValue = vm_property.fastDenseArrayElementValue;
const fastGlobalDataValueForAtomAtPc = vm_property.fastGlobalDataValueForAtomAtPc;
const fastInstalledGlobalDataValueForAtomAtPc = vm_property.fastInstalledGlobalDataValueForAtomAtPc;
const checkedInt32Add = vm_property.checkedInt32Add;
const checkedInt32Mul = vm_property.checkedInt32Mul;
const checkedInt32Sub = vm_property.checkedInt32Sub;
const fastStringPrototypeMethodIsDefault = vm_property.fastStringPrototypeMethodIsDefault;
const finishUndefinedCallResult = vm_property.finishUndefinedCallResult;
const frameHasVarRefBinding = vm_property.frameHasVarRefBinding;
const functionFrameBindingShadowsGlobal = vm_property.functionFrameBindingShadowsGlobal;
const globalVarAtom = vm_property.globalVarAtom;
const hasObjectBinding = vm_property.hasObjectBinding;
const immediateInt32Operand = vm_property.immediateInt32Operand;
const isHostOutputFunctionValue = vm_property.isHostOutputFunctionValue;
const localReadableBorrowed = vm_property.localReadableBorrowed;
const slotValueBorrowed = vm_property.slotValueBorrowed;
const storeLocalCompletionBorrowedValue = vm_property.storeLocalCompletionBorrowedValue;
const stringFromValue = vm_property.stringFromValue;
const varRefReadableBorrowed = vm_property.varRefReadableBorrowed;
const varRefReadableBorrowedForFastPath = vm_property.varRefReadableBorrowedForFastPath;

const functionOwnNativeBuiltinRefForFastPath = property_direct.functionOwnNativeBuiltinRefForFastPath;
const globalDataPropertyValueForFastPath = property_direct.globalDataPropertyValueForFastPath;
const globalDataPropertyValueForFastPathNoProfile = property_direct.globalDataPropertyValueForFastPathNoProfile;
const globalWritableDataStoreAvailableForFastPath = property_direct.globalWritableDataStoreAvailableForFastPath;
const globalWritableDataStoreInt32ForFastPath = property_direct.globalWritableDataStoreInt32ForFastPath;
const ordinaryDataPropertyBorrowedValueForFastPath = property_direct.ordinaryDataPropertyBorrowedValueForFastPath;
const ordinaryDataPropertyIsUndefinedForFastPath = property_direct.ordinaryDataPropertyIsUndefinedForFastPath;
const ordinaryDataPropertyValueOrUndefinedForFastPath = property_direct.ordinaryDataPropertyValueOrUndefinedForFastPath;
const setGlobalDataPropertyForFastPath = property_direct.setGlobalDataPropertyForFastPath;
const setGlobalWritableDataStoreForFastPathOwned = property_direct.setGlobalWritableDataStoreForFastPathOwned;

const op = bytecode.opcode.op;
inline fn closureVarAt(function: *const bytecode.FunctionBytecode, idx: u16) ?bytecode.function_bytecode.BytecodeClosureVar {
    if (idx >= function.closureVar().len) return null;
    return function.closureVar()[idx];
}

fn throwGlobalTdzReferenceError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const err = exception_ops.throwTdzReferenceError(ctx);
    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
    return err;
}

/// qjs OP_get_var slow arm (quickjs.c:18474-18480): an uninitialized cell for a
/// non-lexical closure var resolves via JS_GetPropertyInternal on the global
/// OBJECT — proto chain and getters included, the lexical env never consulted.
/// `op.get_var` throws ReferenceError when no binding exists; `op.get_var_undef`
/// (typeof) yields undefined (qjs `opcode - OP_get_var_undef` throw flag).
fn getVarFromGlobalObject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
    atom_id: core.Atom,
) !Step {
    const value = value: {
        if (function.runtimeStrictMode()) {
            if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |lexical_value| {
                if (!lexical_value.isUninitialized()) break :value lexical_value;
                lexical_value.free(ctx.runtime);
            }
        }
        if (global.getOwnDataPropertyValue(atom_id)) |global_data_value| {
            break :value global_data_value;
        }
        const global_value = global.value().dup();
        defer global_value.free(ctx.runtime);
        if (opc == op.get_var) {
            const has_global_binding = hasObjectBinding(ctx, output, global, global_value, global, atom_id, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            if (!has_global_binding) {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                return error.ReferenceError;
            }
        }
        break :value try object_ops.getValueProperty(ctx, output, global, global_value, atom_id, function, frame);
    };
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
    return .done;
}

pub noinline fn getVar(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
) !Step {
    const site_pc = frame.pc - 1;
    const ref_idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
    const atom_id = globalVarAtom(function, ref_idx) orelse return error.InvalidBytecode;
    frame.pc += 2;
    if (ref_idx < frame.var_refs.len) {
        {
            // Slot is a cell by type (phase D); the non-cell arm is gone.
            const cell = slot_ops.varRefSlotCell(frame, ref_idx);
            const value = cell.pvalue.*;
            if (!value.isUninitialized()) {
                // The bound cell is authoritative: a global lexical shadowing
                // this name would have performed definition-time cell surgery /
                // parked-cell reuse (qjs js_closure_define_global_var,
                // quickjs.c:17148-17162 + 17186-17205), so no per-read lexical
                // check is needed (qjs OP_get_var has none, 18461-18488).
                // Guard #7 retired: cell values are never cells (the
                // direct-eval const view pvalue-aliases its target), so
                // `value` is the plain value already.
                try stack.push(value);
                return .done;
            } else {
                // qjs OP_get_var uninitialized arm (quickjs.c:18469-18483):
                // a lexical closure var in its TDZ window throws; everything
                // else — undeclared global, deleted binding parked at
                // UNINITIALIZED (remove_global_object_property, 9289-9309),
                // or a lexical-shadow TDZ window reached through an old
                // non-lexical capture — resolves through the plain global
                // OBJECT (JS_GetPropertyInternal(ctx->global_obj, ...)),
                // never the lexical env.
                const cv_is_lexical = if (closureVarAt(function, ref_idx)) |cv| cv.isLexical() else false;
                if (cv_is_lexical and !cell.varRefIsDeletableSlot().*) {
                    return try throwGlobalTdzReferenceError(ctx, output, global, stack, frame, catch_target);
                }
                return try getVarFromGlobalObject(ctx, output, global, stack, function, frame, catch_target, opc, atom_id);
            }
        }
    } else if (closureVarAt(function, ref_idx)) |cv| {
        if (cv.isLexical()) return try throwGlobalTdzReferenceError(ctx, output, global, stack, frame, catch_target);
    }
    const opcode_profile = ctx.runtime.opcode_profile;
    if (opcode_profile != null) {
        core.profile.recordGlobalLookup();
    }
    if (atom_id == core.atom.ids.undefined_ and canUseFastGlobalUndefinedLookup(function, frame)) {
        if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |lex_value| {
            lex_value.free(ctx.runtime);
        } else {
            try stack.pushOwned(core.JSValue.undefinedValue());
            return .done;
        }
    }
    if (fastInstalledGlobalDataValueForAtomAtPc(ctx, function, global, frame, site_pc, atom_id)) |value| {
        return try useFastGlobalDataValue(ctx, output, stack, function, global, frame, catch_target, site_pc, atom_id, value);
    }
    if (canUseFastGlobalVarLookup(function, atom_id, frame)) {
        if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |lex_value| {
            if (lex_value.isUninitialized()) {
                lex_value.free(ctx.runtime);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                return error.ReferenceError;
            }
            errdefer lex_value.free(ctx.runtime);
            try stack.pushOwned(lex_value);
            return .done;
        }
        if (globalDataPropertyValueForFastPath(ctx.runtime, global, function, site_pc, atom_id)) |value| {
            return try useFastGlobalDataValue(ctx, output, stack, function, global, frame, catch_target, site_pc, atom_id, value);
        }
    }
    const value = value: {
        if (atom_id == core.atom.ids.undefined_) break :value core.JSValue.undefinedValue();
        if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |lex_value| {
            if (lex_value.isUninitialized()) {
                lex_value.free(ctx.runtime);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
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
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            if (!has_global_binding) {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
                return error.ReferenceError;
            }
        }
        break :value try object_ops.getValueProperty(ctx, output, global, global_value, atom_id, function, frame);
    };
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
    return .done;
}

fn useFastGlobalDataValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    site_pc: usize,
    atom_id: core.Atom,
    value: core.JSValue,
) !Step {
    _ = ctx;
    _ = output;
    _ = global;
    _ = catch_target;
    _ = site_pc;
    _ = atom_id;
    const value_int = value.asInt32();
    if (value_int != null) {}
    if (value_int != null or value.asShortBigInt() != null) {} else {
        if (value.isString()) {} else if (nextOpCanStartGlobalUriCall1(function, frame)) {}
    }
    try stack.push(value);
    return .done;
}

fn nextOpCanStartGlobalUriCall1(function: *const bytecode.FunctionBytecode, frame: *const frame_mod.Frame) bool {
    if (frame.pc >= function.byteCode().len) return false;
    const code = function.byteCode();
    return switch (code[frame.pc]) {
        op.push_atom_value => frame.pc + 6 <= code.len and code[frame.pc + 5] == op.call1,
        op.get_var_ref, op.get_var_ref_check => frame.pc + 4 <= code.len and code[frame.pc + 3] == op.call1,
        op.get_var_ref0, op.get_var_ref1, op.get_var_ref2, op.get_var_ref3 => frame.pc + 1 <= code.len and code[frame.pc + 1] == op.call1,
        op.get_var, op.get_var_undef => frame.pc + 4 <= code.len and code[frame.pc + 3] == op.call1,
        else => false,
    };
}

pub noinline fn putVar(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    strict_unresolved_get_var: bool,
    eval_global_var_bindings: bool,
    is_eval_code: bool,
) !Step {
    const ref_idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
    const atom_id = globalVarAtom(function, ref_idx) orelse return error.InvalidBytecode;
    frame.pc += 2;
    const value = try stack.pop();
    if (ref_idx < frame.var_refs.len) {
        {
            // Slot is a cell by type (phase D); the non-cell arm is gone.
            const cell = slot_ops.varRefSlotCell(frame, ref_idx);
            const current = cell.pvalue.*;
            // qjs OP_put_var (quickjs.c:18490-18525): the exceptional arm is
            // keyed on `uninitialized || is_const`, and inside it on the
            // CELL's is_lexical (unlike OP_get_var's cv-keyed check) — a
            // lexical cell throws (TDZ ReferenceError while uninitialized,
            // read-only TypeError for const), a non-lexical cell (deleted
            // binding / undeclared global) falls to the global-object set
            // below (JS_HasProperty strict check + JS_SetPropertyInternal).
            // The write-through arm needs no per-write lexical check: a
            // shadowing global lexical performed definition-time cell
            // surgery, so the bound cell IS the lexical binding.
            if (current.isUninitialized() or cell.varRefIsConstSlot().*) {
                if (cell.is_lexical and core.VarRef.fromValue(current) == null) {
                    value.free(ctx.runtime);
                    if (current.isUninitialized()) {
                        return try throwGlobalTdzReferenceError(ctx, output, global, stack, frame, catch_target);
                    }
                    // qjs JS_ThrowTypeErrorReadOnly (18507); zjs reports
                    // the const violation through the same catchable
                    // TypeError channel the lexical-env write used.
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
                    return error.TypeError;
                }
                // Non-lexical cell: fall to the global-object set below.
            } else if (core.VarRef.fromValue(current) == null and
                !cell.varRefIsFunctionNameSlot().*)
            {
                errdefer value.free(ctx.runtime);
                cell.setVarRefValue(ctx.runtime, value);
                return .done;
            }
        }
    } else if (closureVarAt(function, ref_idx)) |cv| {
        if (cv.isLexical()) {
            value.free(ctx.runtime);
            return try throwGlobalTdzReferenceError(ctx, output, global, stack, frame, catch_target);
        }
    }
    const opcode_profile = ctx.runtime.opcode_profile;
    if (opcode_profile != null) core.profile.recordGlobalLookup();
    const runtime_strict = function.isStrictMode() or function.runtimeStrictMode();
    if (canUseFastGlobalVarWrite(ctx, function, atom_id, frame)) {
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
    const updated_global_lexical = call_runtime.setGlobalLexicalValueForGlobal(ctx, global, atom_id, value) catch |err| {
        value.free(ctx.runtime);
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    if (updated_global_lexical) {
        value.free(ctx.runtime);
        return .continue_loop;
    }
    {
        // qjs OP_put_var always performs JS_HasProperty on the global object
        // before its SetProperty slow leg (quickjs.c:18511-18521).  Only the
        // missing-binding throw is strict-only; skipping HasProperty in sloppy
        // mode loses observable Proxy/exotic-global `has` traps.
        const global_value = global.value().dup();
        defer global_value.free(ctx.runtime);
        const has_global_binding = hasObjectBinding(ctx, output, global, global_value, global, atom_id, function, frame) catch |err| {
            value.free(ctx.runtime);
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
        if (!has_global_binding and (runtime_strict or strict_unresolved_get_var)) {
            value.free(ctx.runtime);
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
            return error.ReferenceError;
        }
    }
    if (is_eval_code and
        eval_global_var_bindings and
        !runtime_strict and
        evalFunctionDeclaresGlobalVar(ctx.runtime, function, atom_id) and
        (try globalOwnAccessorWithoutSetter(ctx.runtime, global, atom_id)))
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
    _ = object_ops.setValueProperty(ctx, output, global, global_value, atom_id, value, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

fn globalOwnRejectedNonStrictSet(global: *core.Object, atom_id: core.Atom) bool {
    if (global.hasExoticMethods()) return false;
    for (global.shapeProps(), 0..) |prop, property_index| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted or prop.atom_id != atom_id) continue;
        if (prop_flags.isAccessor()) {
            return global.propertyEntry(property_index).*.slot.accessor.setterIsUndefined();
        }
        return switch (global.propKindAt(property_index)) {
            .data => !prop_flags.writable,
            .var_ref, .auto_init, .accessor => false,
        };
    }
    return false;
}

fn globalWritableDataWriteFastOwned(ctx: *core.JSContext, global: *core.Object, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, atom_id: core.Atom, value: core.JSValue) !bool {
    const rt = ctx.runtime;
    const site_pc = frame.pc - 3;
    return setGlobalWritableDataStoreForFastPathOwned(rt, ctx.lexicals, global, function, site_pc, atom_id, value);
}

fn canUseFastGlobalVarWrite(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    atom_id: core.Atom,
    frame: *const frame_mod.Frame,
) bool {
    if (!canFuseGlobalDataWrite(function, frame, atom_id)) return false;
    if (functionFrameBindingShadowsGlobal(ctx.runtime, function, frame, atom_id)) return false;
    return true;
}

fn canUseFastGlobalUndefinedLookup(
    function: *const bytecode.FunctionBytecode,
    frame: *const frame_mod.Frame,
) bool {
    if (frameHasVarRefBinding(function, frame, core.atom.ids.undefined_)) return false;
    return true;
}

fn evalFunctionDeclaresGlobalVar(rt: *core.JSRuntime, function: *const bytecode.FunctionBytecode, atom_id: core.Atom) bool {
    for (function.closureVar()) |cv| {
        if (cv.closureType() != .global_decl or cv.isLexical()) continue;
        if (call_runtime.atomIdOrNameEql(rt, cv.var_name, atom_id)) return true;
    }
    return false;
}

fn globalOwnAccessorWithoutSetter(rt: *core.JSRuntime, global: *core.Object, atom_id: core.Atom) !bool {
    const desc = (try global.getOwnProperty(rt, atom_id)) orelse return false;
    defer desc.destroy(rt);
    return desc.kind == .accessor and desc.setter.isUndefined();
}

fn globalDeclIsFunction(cv: core.function_bytecode.BytecodeClosureVar) bool {
    return cv.closureType() == .global_decl and cv.varKind() == .global_function_decl;
}

fn validateGlobalVarDeclaration(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.FunctionBytecode,
    cv: core.function_bytecode.BytecodeClosureVar,
    is_eval_code: bool,
) !void {
    _ = function;
    _ = is_eval_code;

    const atom_id = cv.var_name;
    const has_global_lexical = call_runtime.globalLexicalHasForGlobal(ctx, global, atom_id);
    const own_flags: ?core.property.Flags = flags: {
        const index = global.findProperty(atom_id) orelse break :flags null;
        const flags = global.propFlagsAt(index);
        break :flags if (flags.deleted) null else flags;
    };
    if (own_flags) |flags| {
        // JS_CheckDefineGlobalVar reads the raw shape entry: it does not invoke
        // exotic hooks or materialize JS_PROP_AUTOINIT during PASS1. PASS2's
        // js_closure_define_global_var performs auto-init before cell surgery.
        if (cv.isLexical()) {
            if (!flags.configurable) return error.SyntaxError;
        } else if (globalDeclIsFunction(cv) and !flags.configurable) {
            if (flags.isAccessor() or !flags.writable or !flags.enumerable) return error.TypeError;
        }
    } else if (!cv.isLexical() and !global.isExtensible()) {
        return error.TypeError;
    }
    if (has_global_lexical) return error.SyntaxError;
}

/// qjs js_closure2 PASS1: GlobalVar is compile-only and has already been
/// lowered into one GLOBAL_DECL ClosureVar per declaration. Validation consumes
/// only that final descriptor table, exactly like JSFunctionBytecode.
pub fn validateGlobalVarDeclarations(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.FunctionBytecode,
    is_eval_code: bool,
) !void {
    for (function.closureVar()) |cv| {
        if (cv.closureType() != .global_decl) continue;
        try validateGlobalVarDeclaration(ctx, global, function, cv, is_eval_code);
    }
}

test "QuickJS global declaration validation does not materialize auto-init properties" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    ctx.global = global;
    _ = try global.ensureGlobalPayload(rt);

    const binding_name = try rt.internAtom("qjs-pass1-auto-init-binding");
    defer rt.atoms.free(binding_name);
    try global.defineAutoInitPropertyWithRealm(
        rt,
        binding_name,
        "qjs-pass1-auto-init-binding",
        0,
        core.property.Flags.data(true, false, true),
        global,
    );
    const property_index = global.findProperty(binding_name) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(core.property.Kind.auto_init, global.propKindAt(property_index));

    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    defer function.deinit(rt);
    function.flags.is_global_var = true;
    function.closure_var = try rt.memory.alloc(core.function_bytecode.BytecodeClosureVar, 1);
    function.closure_var[0] = core.function_bytecode.BytecodeClosureVar.init(.{
        .closure_type = .global_decl,
        .var_idx = 0,
        .var_name = rt.atoms.dup(binding_name),
    });

    var execution_adapter: bytecode.LegacyExecutionAdapter = undefined;
    const execution_function = execution_adapter.init(&function);
    try validateGlobalVarDeclarations(ctx, global, execution_function, true);
    try std.testing.expectEqual(core.property.Kind.auto_init, global.propKindAt(property_index));
}

/// qjs js_closure2 PASS2: bind every GLOBAL_DECL cell in closure order. Function
/// values are intentionally absent here; the fclosure/put_var_ref bytecode
/// prologue runs only after this whole pass finishes.
pub fn instantiateGlobalVarDeclarationCells(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    is_eval_code: bool,
) !void {
    for (function.closureVar(), 0..) |cv, idx| {
        if (cv.closureType() != .global_decl) continue;
        const ref_idx = std.math.cast(u16, idx) orelse return error.InvalidBytecode;
        if (cv.isLexical()) {
            if (!try call_runtime.defineGlobalDeclLexicalCell(ctx, global, function, frame, ref_idx, cv.var_name, cv.isConst())) {
                try call_runtime.defineGlobalLexicalValue(ctx, cv.var_name, core.JSValue.uninitialized(), cv.isConst());
            }
        } else {
            _ = try call_runtime.defineGlobalDeclVarCell(ctx, global, function, frame, ref_idx, cv.var_name, is_eval_code, globalDeclIsFunction(cv));
        }
    }
}

pub noinline fn globalDefinition(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    eval_global_var_bindings: bool,
    opc: u8,
) !Step {
    switch (opc) {
        op.put_var_init => {
            const ref_idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
            const atom_id = globalVarAtom(function, ref_idx) orelse return error.InvalidBytecode;
            frame.pc += 2;
            const value = try stack.pop();
            var value_owned = true;
            defer if (value_owned) value.free(ctx.runtime);
            // Whether this initialization targets the eval global-variable
            // environment is an L0 entry fact, not a property of every nested
            // function compiled from the same source. QuickJS's finalized FB
            // therefore needs only its combined eval marker.
            if (!eval_global_var_bindings) {
                const fast_global_lexical = call_runtime.setGlobalLexicalValueForFastPathOwned(ctx, atom_id, value) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
                if (fast_global_lexical) {
                    value_owned = false;
                    return .continue_loop;
                }
                const updated_global_lexical = call_runtime.setGlobalLexicalValueForGlobal(ctx, global, atom_id, value) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
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
