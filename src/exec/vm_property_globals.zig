//! Global variable read/write/define opcode handlers and their fused fast paths.

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const property_direct = @import("property_direct.zig");
const property_ops = @import("property_ops.zig");
const stack_mod = @import("stack.zig");
const Vm = @import("tailcall_dispatch.zig").Vm;
const HostError = @import("exceptions.zig").HostError;

const call_runtime = @import("call_runtime.zig");
const exception_ops = @import("exception_ops.zig");
const object_ops = @import("object_ops.zig");
const slot_ops = @import("slot_ops.zig");
const dispatch = @import("tailcall_dispatch.zig");
const readInt = call_runtime.readInt;

// Helpers that remain in vm_property.zig (shared with the leftover handlers).
const vm_property = @import("vm_property.zig");
const canFuseGlobalDataWrite = vm_property.canFuseGlobalDataWrite;
const canUseFastGlobalVarLookup = vm_property.canUseFastGlobalVarLookup;
const fastInstalledGlobalDataValueForAtomAtPc = vm_property.fastInstalledGlobalDataValueForAtomAtPc;
const frameHasVarRefBinding = vm_property.frameHasVarRefBinding;
const functionFrameBindingShadowsGlobal = vm_property.functionFrameBindingShadowsGlobal;
const globalVarAtom = vm_property.globalVarAtom;
const hasObjectBinding = vm_property.hasObjectBinding;

const globalDataPropertyValueForFastPath = property_direct.globalDataPropertyValueForFastPath;
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
) HostError!void {
    const err = exception_ops.throwTdzReferenceError(ctx);
    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
    return err;
}

/// qjs OP_get_var slow arm: an uninitialized cell for a
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
) HostError!void {
    const value = value: {
        if (function.runtimeStrictMode()) {
            if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |lexical_value| {
                if (!lexical_value.is(.uninitialized)) break :value lexical_value;
            }
        }
        if (global.getOwnDataPropertyValue(atom_id)) |global_data_value| {
            break :value global_data_value;
        }
        const global_value = global.value();
        if (opc == op.get_var) {
            const has_global_binding = hasObjectBinding(ctx, output, global, global_value, global, atom_id, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                return err;
            };
            if (!has_global_binding) {
                _ = exception_ops.throwReferenceErrorNotDefined(ctx, global, atom_id) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                    return err;
                };
                return error.ReferenceError;
            }
        }
        break :value try object_ops.getValueProperty(ctx, output, global, global_value, atom_id, function, frame);
    };
    try stack.pushOwned(value);
}

pub noinline fn getVar(vm: *Vm, opc: u8) HostError!void {
    const ctx = vm.ctx;
    const output = vm.output;
    const global = vm.global;
    const stack = vm.stack;
    const function = vm.function;
    const frame = vm.frame;
    const catch_target = vm.catch_target;
    const site_pc = frame.pc - 1;
    const ref_idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
    const atom_id = globalVarAtom(function, ref_idx) orelse return error.InvalidBytecode;
    frame.pc += 2;
    if (ref_idx < frame.var_refs.len) {
        {
            // Slot is a cell by type (phase D); the non-cell arm is gone.
            const cell = slot_ops.varRefSlotCell(frame, ref_idx);
            const value = cell.pvalue.*;
            if (!value.is(.uninitialized)) {
                // The bound cell is authoritative: a global lexical shadowing
                // this name would have performed definition-time cell surgery /
                // parked-cell reuse (qjs js_closure_define_global_var,
                // quickjs.c + 17186-17205), so no per-read lexical
                // check is needed (qjs OP_get_var has none, 18461-18488).
                // Guard #7 retired: cell values are never cells (the
                // direct-eval const view pvalue-aliases its target), so
                // `value` is the plain value already.
                try stack.push(value);
                return;
            } else {
                // qjs OP_get_var uninitialized arm:
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
        if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |_| {} else {
            try stack.pushOwned(core.JSValue.undefinedValue());
            return;
        }
    }
    if (fastInstalledGlobalDataValueForAtomAtPc(ctx, function, global, frame, site_pc, atom_id)) |value| {
        try stack.push(value);
        return;
    }
    if (canUseFastGlobalVarLookup(function, atom_id, frame)) {
        if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |lex_value| {
            if (lex_value.is(.uninitialized)) {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.ReferenceError)) return;
                return error.ReferenceError;
            }
            try stack.pushOwned(lex_value);
            return;
        }
        if (globalDataPropertyValueForFastPath(ctx.runtime, global, function, site_pc, atom_id)) |value| {
            try stack.push(value);
            return;
        }
    }
    const value = value: {
        if (atom_id == core.atom.ids.undefined_) break :value core.JSValue.undefinedValue();
        if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |lex_value| {
            if (lex_value.is(.uninitialized)) {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.ReferenceError)) return;
                return error.ReferenceError;
            }
            break :value lex_value;
        }
        if (global.getOwnDataPropertyValue(atom_id)) |global_data_value| {
            break :value global_data_value;
        }
        const global_value = global.value();
        if (opc == op.get_var) {
            const has_global_binding = hasObjectBinding(ctx, output, global, global_value, global, atom_id, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                return err;
            };
            if (!has_global_binding) {
                _ = exception_ops.throwReferenceErrorNotDefined(ctx, global, atom_id) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                    return err;
                };
                return error.ReferenceError;
            }
        }
        break :value try object_ops.getValueProperty(ctx, output, global, global_value, atom_id, function, frame);
    };
    try stack.pushOwned(value);
}

pub noinline fn putVar(vm: *Vm) HostError!void {
    const ctx = vm.ctx;
    const output = vm.output;
    const global = vm.global;
    const stack = vm.stack;
    const function = vm.function;
    const frame = vm.frame;
    const catch_target = vm.catch_target;
    const strict_unresolved_get_var = dispatch.strictUnresolvedGetVar(vm);
    const eval_global_var_bindings = dispatch.evalGlobalVarBindings(vm);
    const is_eval_code = dispatch.isEvalCode(vm);
    const ref_idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
    const atom_id = globalVarAtom(function, ref_idx) orelse return error.InvalidBytecode;
    frame.pc += 2;
    const value = try stack.pop();
    if (ref_idx < frame.var_refs.len) {
        {
            // Slot is a cell by type (phase D); the non-cell arm is gone.
            const cell = slot_ops.varRefSlotCell(frame, ref_idx);
            const current = cell.pvalue.*;
            // qjs OP_put_var: the exceptional arm is
            // keyed on `uninitialized || is_const`, and inside it on the
            // CELL's is_lexical (unlike OP_get_var's cv-keyed check) — a
            // lexical cell throws (TDZ ReferenceError while uninitialized,
            // read-only TypeError for const), a non-lexical cell (deleted
            // binding / undeclared global) falls to the global-object set
            // below (JS_HasProperty strict check + JS_SetPropertyInternal).
            // The write-through arm needs no per-write lexical check: a
            // shadowing global lexical performed definition-time cell
            // surgery, so the bound cell IS the lexical binding.
            if (current.is(.uninitialized) or cell.varRefIsConstSlot().*) {
                if (cell.is_lexical and core.VarRef.fromValue(current) == null) {
                    if (current.is(.uninitialized)) {
                        return try throwGlobalTdzReferenceError(ctx, output, global, stack, frame, catch_target);
                    }
                    // qjs JS_ThrowTypeErrorReadOnly (18507); zjs reports
                    // the const violation through the same catchable
                    // TypeError channel the lexical-env write used.
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.TypeError)) return;
                    return error.TypeError;
                }
                // Non-lexical cell: fall to the global-object set below.
            } else if (core.VarRef.fromValue(current) == null and
                !cell.varRefIsFunctionNameSlot().*)
            {
                cell.setVarRefValue(ctx.runtime, value);
                return;
            }
        }
    } else if (closureVarAt(function, ref_idx)) |cv| {
        if (cv.isLexical()) {
            return try throwGlobalTdzReferenceError(ctx, output, global, stack, frame, catch_target);
        }
    }
    const opcode_profile = ctx.runtime.opcode_profile;
    if (opcode_profile != null) core.profile.recordGlobalLookup();
    const runtime_strict = function.isStrictMode() or function.runtimeStrictMode();
    if (canUseFastGlobalVarWrite(ctx, function, atom_id, frame)) {
        if (call_runtime.setGlobalLexicalValueForFastPathOwned(ctx, atom_id, value) catch |err| {
            return err;
        }) {
            return;
        }
        if (setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, frame.pc - 3, atom_id, value)) {
            return;
        }
    }
    const updated_global_lexical = call_runtime.setGlobalLexicalValueForGlobal(ctx, global, atom_id, value) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
        return err;
    };
    if (updated_global_lexical) {
        return;
    }
    {
        // qjs OP_put_var always performs JS_HasProperty on the global object
        // before its SetProperty slow leg. Only the
        // missing-binding throw is strict-only; skipping HasProperty in sloppy
        // mode loses observable Proxy/exotic-global `has` traps.
        const global_value = global.value();
        const has_global_binding = hasObjectBinding(ctx, output, global, global_value, global, atom_id, function, frame) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
            return err;
        };
        if (!has_global_binding and (runtime_strict or strict_unresolved_get_var)) {
            _ = exception_ops.throwReferenceErrorNotDefined(ctx, global, atom_id) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                return err;
            };
            return error.ReferenceError;
        }
    }
    if (is_eval_code and
        eval_global_var_bindings and
        !runtime_strict and
        evalFunctionDeclaresGlobalVar(ctx.runtime, function, atom_id) and
        (try globalOwnAccessorWithoutSetter(ctx.runtime, global, atom_id)))
    {
        return;
    }
    if (try global.setOwnWritableDataProperty(ctx.runtime, atom_id, value)) {
        return;
    }
    if (!runtime_strict and globalOwnRejectedNonStrictSet(global, atom_id)) {
        return;
    }
    const global_value = global.value();
    _ = object_ops.setValueProperty(ctx, output, global, global_value, atom_id, value, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
        return err;
    };
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
    return desc.kind == .accessor and desc.setter.is(.undefined_value);
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
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    ctx.global = global;
    _ = try global.ensureGlobalPayload(rt);

    const binding_name = try rt.internAtom("qjs-pass1-auto-init-binding");
    try global.defineAutoInitPropertyWithRealm(
        rt,
        binding_name,
        "qjs-pass1-auto-init-binding",
        0,
        core.property.Flags.data(.method),
        global,
    );
    const property_index = global.findProperty(binding_name) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(core.property.Kind.auto_init, global.propKindAt(property_index));

    const function = try bytecode.FunctionBytecode.createFixture(rt, .{ .closure_var_count = 1 });
    defer function.destroyUnpublishedFixture(rt);
    function.closureVar()[0] = core.function_bytecode.BytecodeClosureVar.init(.{
        .closure_type = .global_decl,
        .var_idx = 0,
        .var_name = binding_name,
    });

    try validateGlobalVarDeclarations(ctx, global, function, true);
    try std.testing.expectEqual(core.property.Kind.auto_init, global.propKindAt(property_index));
}

pub noinline fn globalDefinition(vm: *Vm, opc: u8) HostError!void {
    const ctx = vm.ctx;
    const global = vm.global;
    const frame = vm.frame;
    const eval_global_var_bindings = dispatch.evalGlobalVarBindings(vm);
    switch (opc) {
        op.put_var_init => {
            const ref_idx = readInt(u16, vm.function.byteCode()[frame.pc..][0..2]);
            const atom_id = globalVarAtom(vm.function, ref_idx) orelse return error.InvalidBytecode;
            frame.pc += 2;
            const value = try vm.stack.pop();
            // Whether this initialization targets the eval global-variable
            // environment is an L0 entry fact, not a property of every nested
            // function compiled from the same source. QuickJS's finalized FB
            // therefore needs only its combined eval marker.
            if (!eval_global_var_bindings) {
                const fast_global_lexical = call_runtime.setGlobalLexicalValueForFastPathOwned(ctx, atom_id, value) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, vm.output, vm.stack, frame, vm.catch_target, global, err)) return;
                    return err;
                };
                if (fast_global_lexical) {
                    return;
                }
                const updated_global_lexical = call_runtime.setGlobalLexicalValueForGlobal(ctx, global, atom_id, value) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, vm.output, vm.stack, frame, vm.catch_target, global, err)) return;
                    return err;
                };
                if (updated_global_lexical) return;
            }
            try property_ops.setProperty(ctx.runtime, global, atom_id, value);
        },
        else => unreachable,
    }
}
