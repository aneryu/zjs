//! Direct/indirect eval execution, eval binding capture decisions and eval-local plumbing.

const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const frontend = @import("../frontend/root.zig");
const inline_calls = @import("inline_calls.zig");
const stack_mod = @import("stack.zig");
const std = @import("std");
const value_ops = @import("value_ops.zig");
const zjs_vm = @import("zjs_vm.zig");

const op = bytecode.opcode.op;
const runWithArgsState = zjs_vm.runWithArgsState;

const call_runtime = @import("call_runtime.zig");
const array_ops = @import("array_ops.zig");
const exception_ops = @import("vm_exception_ops.zig");
const object_ops = @import("object_ops.zig");
const slot_ops = @import("slot_ops.zig");
const string_ops = @import("string_ops.zig");

// Helpers that remain in call_runtime.zig (generic utilities outside the eval
// cluster).
const InlineCallRequest = call_runtime.InlineCallRequest;
const ValueSliceRoot = array_ops.ValueSliceRoot;
const appendPrivateBoundName = call_runtime.appendPrivateBoundName;
const appendPrivateBoundNamesFromObject = object_ops.appendPrivateBoundNamesFromObject;
const appendPrivateBoundNamesFromValue = call_runtime.appendPrivateBoundNamesFromValue;
const appendSourceStringUtf8 = string_ops.appendSourceStringUtf8;
const argsFromArray = array_ops.argsFromArray;
const atomIdOrNameEql = call_runtime.atomIdOrNameEql;
const atomListToMemorySlice = array_ops.atomListToMemorySlice;
const callValueOrBytecode = call_runtime.callValueOrBytecode;
const callerFunctionHasArg = call_runtime.callerFunctionHasArg;
const callerFunctionHasLexicalLocal = call_runtime.callerFunctionHasLexicalLocal;
const classStaticThisAtom = call_runtime.classStaticThisAtom;
const classStaticThisValue = call_runtime.classStaticThisValue;
const closureVarIsNonLexicalGlobalSentinel = call_runtime.closureVarIsNonLexicalGlobalSentinel;
const createDirectEvalVarRefCells = call_runtime.createDirectEvalVarRefCells;
const createDirectEvalVisibleLocalBindings = call_runtime.createDirectEvalVisibleLocalBindings;
const directEvalCallerAllowsNewTarget = call_runtime.directEvalCallerAllowsNewTarget;
const directEvalCallerAllowsSuperProperty = object_ops.directEvalCallerAllowsSuperProperty;
const directEvalVarDeclarationNames = call_runtime.directEvalVarDeclarationNames;
const directEvalWithObject = object_ops.directEvalWithObject;
const evalFunctionDeclarationNames = call_runtime.evalFunctionDeclarationNames;
const evalSimpleCallerExpression = call_runtime.evalSimpleCallerExpression;
const freeArgs = call_runtime.freeArgs;
const freeAtomSlice = array_ops.freeAtomSlice;
const freeValueSlice = array_ops.freeValueSlice;
const functionBytecodeFromValue = call_runtime.functionBytecodeFromValue;
const handleCatchableRuntimeError = call_runtime.handleCatchableRuntimeError;
const normalizeEvalRuntimeError = exception_ops.normalizeEvalRuntimeError;
const objectFromValue = object_ops.objectFromValue;
const publishDirectEvalVarRefs = call_runtime.publishDirectEvalVarRefs;
const setNamedVarRefValue = call_runtime.setNamedVarRefValue;
const simpleEvalRegExpLiteral = call_runtime.simpleEvalRegExpLiteral;
const simpleVarDeclarationName = call_runtime.simpleVarDeclarationName;
const validateGlobalEvalFunctionDeclarations = call_runtime.validateGlobalEvalFunctionDeclarations;
const varRefCellFromValue = slot_ops.varRefCellFromValue;

const DirectEvalOuterVarRefs = struct {
    names: []core.Atom,
    refs: []core.JSValue,
};

fn namedRefValue(
    rt: *core.JSRuntime,
    names: []const core.Atom,
    refs: []const core.JSValue,
    atom_id: core.Atom,
) ?core.JSValue {
    for (names, 0..) |name, idx| {
        if (idx >= refs.len) continue;
        if (atomIdOrNameEql(rt, name, atom_id)) return refs[idx].dup();
    }
    return null;
}

pub fn functionBytecodeHasDirectEval(fb: *const bytecode.FunctionBytecode, rt: *core.JSRuntime) bool {
    _ = rt;
    var pc: usize = 0;
    while (pc < fb.byte_code.len) {
        const opc = fb.byte_code[pc];
        if (opc == op.eval or opc == op.apply_eval) return true;
        const size = bytecode.opcode.sizeOf(opc);
        pc += if (size == 0) 1 else size;
    }
    return false;
}

pub fn functionBytecodeUsesImportMeta(fb: *const bytecode.FunctionBytecode) bool {
    var pc: usize = 0;
    while (pc < fb.byte_code.len) {
        const opc = fb.byte_code[pc];
        if (opc == op.special_object and pc + 1 < fb.byte_code.len and fb.byte_code[pc + 1] == 4) return true;
        const size = bytecode.opcode.sizeOf(opc);
        pc += if (size == 0) 1 else size;
    }
    return false;
}

fn createDirectEvalOuterVarRefs(
    ctx: *core.JSContext,
    global: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !DirectEvalOuterVarRefs {
    const function = caller_function orelse return .{ .names = &.{}, .refs = &.{} };
    const frame = caller_frame orelse return .{ .names = &.{}, .refs = &.{} };
    const count = @min(function.var_ref_names.len, frame.var_refs.len);
    if (count == 0) return .{ .names = &.{}, .refs = &.{} };

    var visible_count: usize = 0;
    for (function.var_ref_names[0..count], 0..) |atom_id, idx| {
        if (closureVarIsNonLexicalGlobalSentinel(function, idx) and global.hasOwnProperty(atom_id)) continue;
        visible_count += 1;
    }
    if (visible_count == 0) return .{ .names = &.{}, .refs = &.{} };

    const names = try ctx.runtime.memory.alloc(core.Atom, visible_count);
    errdefer ctx.runtime.memory.free(core.Atom, names);
    const refs = try ctx.runtime.memory.alloc(core.JSValue, visible_count);
    var rooted_refs: []core.JSValue = refs[0..0];
    var refs_root = ValueSliceRoot{};
    refs_root.init(ctx.runtime, &rooted_refs);
    defer refs_root.deinit();

    var initialized_names: usize = 0;
    var initialized_refs: usize = 0;
    errdefer {
        for (names[0..initialized_names]) |atom_id| ctx.runtime.atoms.free(atom_id);
        for (refs[0..initialized_refs]) |*value| {
            value.free(ctx.runtime);
            value.* = core.JSValue.undefinedValue();
        }
        rooted_refs = &.{};
        ctx.runtime.memory.free(core.JSValue, refs);
    }

    for (function.var_ref_names[0..count], 0..) |atom_id, idx| {
        if (closureVarIsNonLexicalGlobalSentinel(function, idx) and global.hasOwnProperty(atom_id)) continue;
        names[initialized_names] = ctx.runtime.atoms.dup(atom_id);
        initialized_names += 1;
        refs[initialized_refs] = frame.var_refs[idx].dup();
        initialized_refs += 1;
        rooted_refs = refs[0..initialized_refs];
    }
    return .{ .names = names, .refs = refs };
}

fn initialDirectEvalFrameVarRef(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    idx: usize,
) !core.JSValue {
    if (idx < function.closure_var.len) {
        const cv = function.closure_var[idx];
        const initial_value = switch (cv.closure_type) {
            .global, .global_ref, .global_decl => core.JSValue.uninitialized(),
            .module_decl, .module_import => core.JSValue.uninitialized(),
            .local, .arg, .ref => call_runtime.globalLexicalValueForGlobal(ctx, global, cv.var_name) orelse global.getProperty(cv.var_name),
        };
        var initial_owned = initial_value;
        errdefer initial_owned.free(ctx.runtime);
        const cell = try core.VarRef.createClosed(ctx.runtime, initial_owned);
        initial_owned = core.JSValue.undefinedValue();
        cell.varRefIsConstSlot().* = cv.is_const;
        cell.varRefIsFunctionNameSlot().* = cv.var_kind == .function_name;
        return cell.valueRef();
    }

    const atom_id = function.var_ref_names[idx];
    var initial_value = call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id) orelse global.getProperty(atom_id);
    errdefer initial_value.free(ctx.runtime);
    const cell = try core.VarRef.createClosed(ctx.runtime, initial_value);
    initial_value = core.JSValue.undefinedValue();
    return cell.valueRef();
}

fn directEvalFrameVarRefName(function: *const bytecode.Bytecode, idx: usize) ?core.Atom {
    if (idx < function.var_ref_names.len) return function.var_ref_names[idx];
    if (idx < function.closure_var.len) return function.closure_var[idx].var_name;
    return null;
}

fn createDirectEvalFrameVarRefs(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    eval_var_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    outer_var_refs: DirectEvalOuterVarRefs,
) ![]core.JSValue {
    const count = @max(function.closure_var.len, function.var_ref_names.len);
    if (count == 0) return &.{};

    const refs = try ctx.runtime.memory.alloc(core.JSValue, count);
    var rooted_refs: []core.JSValue = refs[0..0];
    var refs_root = ValueSliceRoot{};
    refs_root.init(ctx.runtime, &rooted_refs);
    defer refs_root.deinit();

    var initialized: usize = 0;
    errdefer {
        for (refs[0..initialized]) |*value| {
            value.free(ctx.runtime);
            value.* = core.JSValue.undefinedValue();
        }
        rooted_refs = &.{};
        ctx.runtime.memory.free(core.JSValue, refs);
    }

    while (initialized < count) : (initialized += 1) {
        const atom_id = directEvalFrameVarRefName(function, initialized);
        refs[initialized] = if (atom_id) |name|
            namedRefValue(ctx.runtime, eval_var_names, eval_var_refs, name) orelse
                namedRefValue(ctx.runtime, outer_var_refs.names, outer_var_refs.refs, name) orelse
                try initialDirectEvalFrameVarRef(ctx, global, function, initialized)
        else
            try initialDirectEvalFrameVarRef(ctx, global, function, initialized);
        rooted_refs = refs[0 .. initialized + 1];
    }
    return refs;
}

pub fn evalBytecodeHasVarDeclarations(rt: *core.JSRuntime, function: *const bytecode.Bytecode) bool {
    if (!value_ops.atomNameEql(rt, function.name, "<eval>")) return false;
    for (function.var_names) |atom_id| {
        if (!value_ops.atomNameEql(rt, atom_id, "<ret>")) return true;
    }
    return false;
}

pub fn shouldSkipDirectEvalLocalCapture(
    fb: *const bytecode.FunctionBytecode,
    slot: core.JSValue,
    skip_values: []const core.JSValue,
) bool {
    const value = if (varRefCellFromValue(slot)) |cell|
        cell.varRefValue()
    else
        slot;
    if (value.isUninitialized()) return true;
    if (!fb.super_allowed) return false;
    if (!value.isObject()) return false;
    for (skip_values) |skip_value| {
        if (skip_value.same(value)) return true;
    }
    return false;
}

pub fn functionBytecodeUsesAtom(rt: *core.JSRuntime, fb: *const bytecode.FunctionBytecode, atom_id: core.Atom) bool {
    for (fb.atom_operands) |operand| {
        if (atomIdOrNameEql(rt, operand, atom_id)) return true;
    }
    for (fb.var_ref_names) |name| {
        if (atomIdOrNameEql(rt, name, atom_id)) return true;
    }
    return false;
}

pub fn functionBytecodeHasClosureVarName(rt: *core.JSRuntime, fb: *const bytecode.FunctionBytecode, atom_id: core.Atom) bool {
    for (fb.closure_var) |cv| {
        if (atomIdOrNameEql(rt, cv.var_name, atom_id)) return true;
    }
    return false;
}

pub fn shouldSkipDirectEvalScopeCaptureName(
    rt: *core.JSRuntime,
    captures_direct_eval_scope: bool,
    fb: *const bytecode.FunctionBytecode,
    atom_id: core.Atom,
) bool {
    if (!captures_direct_eval_scope) return false;
    if (fb.func_name == core.atom.ids.empty_string) return false;
    return atomIdOrNameEql(rt, fb.func_name, atom_id);
}

pub fn appendFunctionEvalLocal(ctx: *core.JSContext, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !void {
    const old_function_names = object.functionEvalLocalNames();
    const old_function_refs = object.functionEvalLocalRefs();
    for (old_function_names, 0..) |name, idx| {
        if (!atomIdOrNameEql(ctx.runtime, name, atom_id) or idx >= old_function_refs.len) continue;
        const next = value.dup();
        const ref_slot = &old_function_refs[idx];
        const old_value = ref_slot.*;
        ref_slot.* = next;
        old_value.free(ctx.runtime);
        return;
    }

    const old_len = old_function_names.len;
    const names = try ctx.runtime.memory.alloc(core.Atom, old_len + 1);
    errdefer ctx.runtime.memory.free(core.Atom, names);
    const refs = try ctx.runtime.memory.alloc(core.JSValue, old_len + 1);
    errdefer ctx.runtime.memory.free(core.JSValue, refs);
    var rooted_refs: []core.JSValue = refs[0..0];
    var refs_root = ValueSliceRoot{};
    refs_root.init(ctx.runtime, &rooted_refs);
    defer refs_root.deinit();

    for (old_function_names, 0..) |name, idx| names[idx] = name;
    for (old_function_refs, 0..) |stored, idx| refs[idx] = stored;
    rooted_refs = refs[0..old_len];
    names[old_len] = ctx.runtime.atoms.dup(atom_id);
    var name_owned = true;
    errdefer if (name_owned) ctx.runtime.atoms.free(names[old_len]);
    refs[old_len] = value.dup();
    rooted_refs = refs[0 .. old_len + 1];
    var value_owned = true;
    errdefer if (value_owned) {
        refs[old_len].free(ctx.runtime);
        refs[old_len] = core.JSValue.undefinedValue();
        rooted_refs = refs[0..old_len];
    };

    const names_slot = try object.functionEvalLocalNamesSlot(ctx.runtime);
    const refs_slot = try object.functionEvalLocalRefsSlot(ctx.runtime);
    const old_names = names_slot.*;
    const old_refs = refs_slot.*;
    name_owned = false;
    value_owned = false;
    names_slot.* = names;
    refs_slot.* = refs;
    if (old_names.len != 0) ctx.runtime.memory.free(core.Atom, old_names);
    if (old_refs.len != 0) ctx.runtime.memory.free(core.JSValue, old_refs);
}

pub const ExecEvalResult = union(enum) {
    done,
    continue_loop,
    /// A direct-eval call whose callee is not %eval% sitting in tail
    /// position: an ordinary call eligible for tail-call frame reuse.
    tail_inline: InlineCallRequest,
};

pub fn execDirectEval(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    argc: u16,
    output: ?*std.Io.Writer,
    global: *core.Object,
    eval_in_class_field_initializer: bool,
    eval_in_parameter_initializer: bool,
    allow_tail_inline: bool,
) !ExecEvalResult {
    // `return eval(...)` lowers to `eval ; return`. When the callee is not
    // %eval%, the call is an ordinary one (12.3.4.1 step 9 evaluates it
    // with the tailCall flag); request frame reuse like op.tail_call.
    if (allow_tail_inline and frame.pc < function.code.len and function.code[frame.pc] == op.@"return") {
        const total = @as(usize, argc) + 1;
        if (stack.values.len >= total) {
            const region_base = stack.values.len - total;
            const func_borrowed = stack.values[region_base];
            if (!isContextIntrinsicEval(ctx, func_borrowed)) {
                // `eval(...)` is a plain call: no receiver, `this` is undefined.
                if (inline_calls.resolveInlineTarget(ctx, global, core.JSValue.undefinedValue(), func_borrowed)) |target| {
                    return .{ .tail_inline = .{ .target = target, .region_base = region_base, .argc = argc } };
                }
            }
        }
    }

    var args: []core.JSValue = &.{};
    if (argc != 0) args = try ctx.runtime.memory.alloc(core.JSValue, argc);
    defer if (args.len != 0) ctx.runtime.memory.free(core.JSValue, args);

    var filled_start: usize = args.len;
    errdefer {
        var i = filled_start;
        while (i < args.len) : (i += 1) args[i].free(ctx.runtime);
    }
    var remaining: usize = argc;
    while (remaining > 0) {
        remaining -= 1;
        args[remaining] = try stack.pop();
        filled_start = remaining;
    }
    filled_start = args.len;
    defer {
        for (args) |arg| arg.free(ctx.runtime);
    }

    var func = try stack.pop();
    defer func.free(ctx.runtime);
    var rooted_args = args;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &func },
    };
    var root_slices = [_]core.runtime.ValueRootSlice{
        .{ .mutable = &rooted_args },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
        .slices = &root_slices,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const result = if (isContextIntrinsicEval(ctx, func))
        directEval(ctx, output, global, rooted_args, function, frame, eval_in_class_field_initializer, eval_in_parameter_initializer) catch |err| {
            const eval_err = normalizeEvalRuntimeError(err);
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, eval_err)) {
                return .continue_loop;
            }
            return eval_err;
        }
    else
        callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), func, rooted_args, function, frame) catch |err| {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) {
                return .continue_loop;
            }
            return err;
        };
    defer result.free(ctx.runtime);
    try stack.push(result);
    return .done;
}

pub fn isContextIntrinsicEval(ctx: *core.JSContext, func: core.JSValue) bool {
    return func.isObject() and func.same(ctx.eval_function);
}

pub fn execApplyEval(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    output: ?*std.Io.Writer,
    global: *core.Object,
    eval_in_class_field_initializer: bool,
    eval_in_parameter_initializer: bool,
) !ExecEvalResult {
    var arg_array = try stack.pop();
    defer arg_array.free(ctx.runtime);
    var func = try stack.pop();
    defer func.free(ctx.runtime);
    var value_roots = [_]core.runtime.ValueRootValue{
        .{ .value = &arg_array },
        .{ .value = &func },
    };
    const value_root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &value_roots,
    };
    ctx.runtime.active_value_roots = &value_root_frame;
    defer ctx.runtime.active_value_roots = value_root_frame.previous;

    var args = try argsFromArray(ctx.runtime, arg_array);
    defer freeArgs(ctx.runtime, args);
    var args_root = ValueSliceRoot{};
    args_root.init(ctx.runtime, &args);
    defer args_root.deinit();
    const result = if (isContextIntrinsicEval(ctx, func))
        directEval(ctx, output, global, args, function, frame, eval_in_class_field_initializer, eval_in_parameter_initializer) catch |err| {
            const eval_err = normalizeEvalRuntimeError(err);
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, eval_err)) {
                return .continue_loop;
            }
            return eval_err;
        }
    else
        callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), func, args, function, frame) catch |err| {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) {
                return .continue_loop;
            }
            return err;
        };
    defer result.free(ctx.runtime);
    try stack.push(result);
    return .done;
}

pub fn directEval(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    eval_in_class_field_initializer: bool,
    eval_in_parameter_initializer: bool,
) !core.JSValue {
    if (args.len == 0) return core.JSValue.undefinedValue();
    if (!args[0].isString()) return args[0].dup();
    var source = std.ArrayList(u8).empty;
    defer source.deinit(ctx.runtime.memory.allocator);
    try appendSourceStringUtf8(ctx.runtime, &source, args[0]);
    if (try simpleEvalRegExpLiteral(ctx, global, source.items)) |value| return value;
    if (try evalSimpleCallerExpression(ctx, source.items, caller_function, caller_frame)) |value| return value;
    const caller_strict = if (caller_function) |outer_function| outer_function.flags.is_strict else false;
    if (caller_function) |outer_function| {
        if (!outer_function.flags.has_simple_parameter_list) {
            if (simpleVarDeclarationName(source.items)) |name| {
                const caller_has_arguments_binding = if (caller_frame) |outer_frame|
                    directEvalShouldExposeImplicitArguments(outer_frame)
                else
                    false;
                if ((std.mem.eql(u8, name, "arguments") and caller_has_arguments_binding) or
                    callerFunctionHasArg(ctx.runtime, outer_function, name))
                {
                    return error.SyntaxError;
                }
            }
        }
        if (!caller_strict) if (simpleVarDeclarationName(source.items)) |name| {
            if (!eval_in_parameter_initializer and callerFunctionHasLexicalLocal(ctx.runtime, outer_function, name)) return error.SyntaxError;
        };
    }
    const eval_global_var_bindings = if (caller_frame) |outer_frame|
        outer_frame.current_function.isUndefined()
    else
        true;
    const eval_allows_new_target = directEvalCallerAllowsNewTarget(caller_frame, eval_in_class_field_initializer);
    const eval_allows_super_property = directEvalCallerAllowsSuperProperty(caller_frame, eval_in_class_field_initializer);
    const eval_class_static_field_this_atom = classStaticThisAtom(ctx.runtime, caller_function, caller_frame);
    const eval_private_bound_names = try directEvalPrivateBoundNames(ctx.runtime, caller_function, caller_frame);
    defer if (eval_private_bound_names.len != 0) ctx.runtime.memory.free(core.Atom, eval_private_bound_names);
    var compiled = try frontend.parser.parse(ctx.runtime, source.items, .{
        .mode = .eval_direct,
        .filename = "<eval>",
        .strict = caller_strict,
        .eval_global_var_bindings = eval_global_var_bindings,
        .eval_in_class_field_initializer = eval_in_class_field_initializer,
        .eval_allows_new_target = eval_allows_new_target,
        .eval_allows_super_property = eval_allows_super_property,
        .eval_class_static_field_this_atom = eval_class_static_field_this_atom,
        .eval_private_bound_names = eval_private_bound_names,
    });
    defer compiled.deinit();
    if (compiled.syntax_error != null) return error.SyntaxError;
    const eval_strict = compiled.function.flags.is_strict;
    if (eval_global_var_bindings and !eval_strict) {
        try validateGlobalEvalFunctionDeclarations(ctx, global, source.items, false);
    }
    var nested_stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.runtime.stack_size);
    defer nested_stack.deinit(ctx.runtime);
    var empty_locals: [0]core.JSValue = .{};
    const inherited_local_names = if (caller_frame) |outer_frame| outer_frame.eval_local_names else &.{};
    const inherited_locals = if (caller_frame) |outer_frame| outer_frame.eval_local_slots else empty_locals[0..];
    const inherited_ref_names = if (caller_frame) |outer_frame| outer_frame.eval_var_ref_names else &.{};
    const inherited_refs = if (caller_frame) |outer_frame| outer_frame.eval_var_refs else &.{};
    const outer_var_refs = try createDirectEvalOuterVarRefs(ctx, global, caller_function, caller_frame);
    defer freeAtomSlice(ctx.runtime, outer_var_refs.names);
    defer freeValueSlice(ctx.runtime, outer_var_refs.refs);
    var outer_var_refs_root = ValueSliceRoot{};
    var rooted_outer_var_refs = outer_var_refs.refs;
    outer_var_refs_root.init(ctx.runtime, &rooted_outer_var_refs);
    defer outer_var_refs_root.deinit();
    const base_outer_local_names = if (caller_function) |outer_function| outer_function.var_names else &.{};
    const base_outer_locals = if (caller_frame) |outer_frame| outer_frame.locals else empty_locals[0..];
    var direct_eval_local_names: []core.Atom = &.{};
    var direct_eval_local_slots: []core.JSValue = &.{};
    defer freeAtomSlice(ctx.runtime, direct_eval_local_names);
    defer freeValueSlice(ctx.runtime, direct_eval_local_slots);
    var direct_eval_local_slots_root = ValueSliceRoot{};
    direct_eval_local_slots_root.init(ctx.runtime, &direct_eval_local_slots);
    defer direct_eval_local_slots_root.deinit();
    if (caller_function) |outer_function| {
        if (caller_frame) |outer_frame| {
            const bindings = try createDirectEvalVisibleLocalBindings(ctx, global, outer_function, outer_frame, eval_in_parameter_initializer, eval_global_var_bindings);
            direct_eval_local_names = bindings.names;
            direct_eval_local_slots = bindings.slots;
        }
    }
    const outer_local_names = if (direct_eval_local_names.len != 0) direct_eval_local_names else if (eval_global_var_bindings) &.{} else base_outer_local_names;
    const outer_locals = if (direct_eval_local_names.len != 0) direct_eval_local_slots else if (eval_global_var_bindings) empty_locals[0..] else base_outer_locals;
    var eval_function_names: []core.Atom = &.{};
    if (!eval_strict) {
        if (try evalFunctionDeclarationNames(ctx.runtime, source.items)) |names| {
            eval_function_names = names;
        }
    }
    defer freeAtomSlice(ctx.runtime, eval_function_names);
    var eval_var_names: []core.Atom = &.{};
    if (!eval_strict) {
        eval_var_names = try directEvalVarDeclarationNames(ctx.runtime, global, &compiled.function, source.items, caller_function, eval_function_names, eval_global_var_bindings);
    }
    defer if (!eval_strict) freeAtomSlice(ctx.runtime, eval_var_names);
    var eval_var_refs = try createDirectEvalVarRefCells(ctx, eval_var_names, caller_function, caller_frame, eval_in_parameter_initializer);
    defer freeValueSlice(ctx.runtime, eval_var_refs);
    var eval_var_refs_root = ValueSliceRoot{};
    eval_var_refs_root.init(ctx.runtime, &eval_var_refs);
    defer eval_var_refs_root.deinit();
    if (eval_global_var_bindings) {
        try initializeDirectEvalGlobalVarRefs(ctx, global, eval_var_names, eval_var_refs);
    }
    var direct_eval_frame_var_refs = try createDirectEvalFrameVarRefs(ctx, global, &compiled.function, eval_var_names, eval_var_refs, outer_var_refs);
    defer freeValueSlice(ctx.runtime, direct_eval_frame_var_refs);
    var direct_eval_frame_var_refs_root = ValueSliceRoot{};
    direct_eval_frame_var_refs_root.init(ctx.runtime, &direct_eval_frame_var_refs);
    defer direct_eval_frame_var_refs_root.deinit();
    var combined_eval_local_names: []core.Atom = &.{};
    var combined_eval_local_slots: []core.JSValue = &.{};
    defer freeAtomSlice(ctx.runtime, combined_eval_local_names);
    defer freeValueSlice(ctx.runtime, combined_eval_local_slots);
    var rooted_combined_eval_local_slots: []core.JSValue = &.{};
    var combined_eval_local_slots_root = ValueSliceRoot{};
    combined_eval_local_slots_root.init(ctx.runtime, &rooted_combined_eval_local_slots);
    defer combined_eval_local_slots_root.deinit();
    if (eval_var_names.len != 0) {
        const outer_count = @min(outer_local_names.len, outer_locals.len);
        const eval_count = @min(eval_var_names.len, eval_var_refs.len);
        var retained_outer_count: usize = 0;
        for (outer_local_names[0..outer_count]) |atom_id| {
            if (directEvalVisibleBindingExists(ctx.runtime, eval_var_names[0..eval_count], atom_id)) continue;
            retained_outer_count += 1;
        }
        if (retained_outer_count + eval_count != 0) {
            const combined_count = retained_outer_count + eval_count;
            combined_eval_local_names = try ctx.runtime.memory.alloc(core.Atom, combined_count);
            errdefer {
                ctx.runtime.memory.free(core.Atom, combined_eval_local_names);
                combined_eval_local_names = &.{};
            }
            combined_eval_local_slots = try ctx.runtime.memory.alloc(core.JSValue, combined_count);
            errdefer {
                ctx.runtime.memory.free(core.JSValue, combined_eval_local_slots);
                combined_eval_local_slots = &.{};
            }
            var combined_idx: usize = 0;
            errdefer {
                for (combined_eval_local_names[0..combined_idx]) |atom_id| ctx.runtime.atoms.free(atom_id);
                for (combined_eval_local_slots[0..combined_idx]) |*value| {
                    value.free(ctx.runtime);
                    value.* = core.JSValue.undefinedValue();
                }
                rooted_combined_eval_local_slots = &.{};
            }
            for (outer_local_names[0..outer_count], 0..) |atom_id, idx| {
                if (directEvalVisibleBindingExists(ctx.runtime, eval_var_names[0..eval_count], atom_id)) continue;
                combined_eval_local_names[combined_idx] = ctx.runtime.atoms.dup(atom_id);
                combined_eval_local_slots[combined_idx] = outer_locals[idx].dup();
                combined_idx += 1;
                rooted_combined_eval_local_slots = combined_eval_local_slots[0..combined_idx];
            }
            for (eval_var_names[0..eval_count], 0..) |atom_id, idx| {
                combined_eval_local_names[combined_idx] = ctx.runtime.atoms.dup(atom_id);
                combined_eval_local_slots[combined_idx] = eval_var_refs[idx].dup();
                combined_idx += 1;
                rooted_combined_eval_local_slots = combined_eval_local_slots[0..combined_idx];
            }
        }
    }
    const run_eval_local_names = if (combined_eval_local_names.len != 0) combined_eval_local_names else outer_local_names;
    const run_eval_local_slots = if (combined_eval_local_names.len != 0) combined_eval_local_slots else outer_locals;
    const eval_this = directEvalThisValue(ctx.runtime, caller_function, caller_frame);
    const eval_new_target = if (eval_allows_new_target) blk: {
        if (caller_frame) |outer_frame| break :blk outer_frame.new_target;
        break :blk core.JSValue.undefinedValue();
    } else core.JSValue.undefinedValue();
    const eval_current_function = blk: {
        if (caller_frame) |outer_frame| break :blk outer_frame.current_function;
        break :blk core.JSValue.undefinedValue();
    };
    const eval_with_object = directEvalWithObject(ctx.runtime, caller_function, caller_frame);
    defer eval_with_object.free(ctx.runtime);
    const result = try runWithArgsState(ctx, &nested_stack, &compiled.function, eval_this, &.{}, direct_eval_frame_var_refs, output, global, false, eval_strict, false, run_eval_local_names, run_eval_local_slots, outer_var_refs.names, outer_var_refs.refs, inherited_local_names, inherited_locals, inherited_ref_names, inherited_refs, null, null, null, eval_current_function, eval_new_target, core.JSValue.undefinedValue(), eval_global_var_bindings, true, eval_with_object, false, false);
    errdefer result.free(ctx.runtime);
    try publishDirectEvalVarRefs(ctx, global, caller_frame, eval_var_names, eval_var_refs, eval_in_parameter_initializer, eval_global_var_bindings);
    return result;
}

fn initializeDirectEvalGlobalVarRefs(
    ctx: *core.JSContext,
    global: *core.Object,
    names: []const core.Atom,
    refs: []const core.JSValue,
) !void {
    const count = @min(names.len, refs.len);
    for (names[0..count]) |atom_id| {
        if (global.getOwnProperty(ctx.runtime, atom_id)) |desc| {
            defer desc.destroy(ctx.runtime);
            const value = global.getProperty(atom_id);
            if (!try setNamedVarRefValue(ctx, names, refs, atom_id, value, false, true)) {
                value.free(ctx.runtime);
            }
        }
    }
}

pub fn directEvalThisValue(
    rt: *core.JSRuntime,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) core.JSValue {
    const outer_frame = caller_frame orelse return core.JSValue.undefinedValue();
    if (classStaticThisAtom(rt, caller_function, caller_frame)) |atom_id| {
        if (classStaticThisValue(caller_function, outer_frame, atom_id)) |value| return value;
    }
    return outer_frame.this_value;
}

pub fn directEvalPrivateBoundNames(
    rt: *core.JSRuntime,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) ![]core.Atom {
    var atoms = std.ArrayList(core.Atom).empty;
    errdefer atoms.deinit(rt.memory.allocator);
    if (caller_function) |function| {
        for (function.private_bound_names) |atom_id| {
            try appendPrivateBoundName(rt, &atoms, atom_id);
        }
        for (function.atom_operands) |atom_id| {
            try appendPrivateBoundName(rt, &atoms, atom_id);
        }
    }
    if (caller_frame) |frame| {
        try appendPrivateBoundNamesFromValue(rt, &atoms, frame.this_value);
        if (objectFromValue(frame.current_function)) |function_object| {
            if (function_object.functionHomeObjectSlot().*) |home_object| {
                try appendPrivateBoundNamesFromObject(rt, &atoms, home_object);
            }
        }
    }
    return try atomListToMemorySlice(rt, &atoms);
}

pub fn directEvalVisibleBindingExists(rt: *core.JSRuntime, names: []const core.Atom, atom_id: core.Atom) bool {
    for (names) |existing| {
        if (atomIdOrNameEql(rt, existing, atom_id)) return true;
    }
    return false;
}

pub fn directEvalVisibleLocalNameCount(rt: *core.JSRuntime, names: []const core.Atom, atom_id: core.Atom) usize {
    var count: usize = 0;
    for (names) |existing| {
        if (atomIdOrNameEql(rt, existing, atom_id)) count += 1;
    }
    return count;
}

pub fn directEvalShouldExposeImplicitArguments(caller_frame: *frame_mod.Frame) bool {
    if (caller_frame.current_function.isUndefined()) return false;
    if (functionBytecodeFromValue(caller_frame.current_function)) |fb| return !fb.is_arrow_function;
    if (objectFromValue(caller_frame.current_function)) |function_object| {
        const stored = function_object.functionBytecodeSlot().* orelse return false;
        const fb = functionBytecodeFromValue(stored) orelse return false;
        return !fb.is_arrow_function;
    }
    return false;
}
