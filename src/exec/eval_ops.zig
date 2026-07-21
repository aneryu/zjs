//! Direct/indirect eval execution, compiler seed construction and indexed cell setup.

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const parser = @import("../parser.zig");
const inline_calls = @import("inline_calls.zig");
const stack_mod = @import("stack.zig");
const std = @import("std");
const zjs_vm = @import("zjs_vm.zig");

const op = bytecode.opcode.op;
const runWithCallEnv = zjs_vm.runWithCallEnv;

const call_runtime = @import("call_runtime.zig");
const array_ops = @import("array_ops.zig");
const error_stack_ops = @import("error_stack_ops.zig");
const exception_ops = @import("vm_exception_ops.zig");
const object_ops = @import("object_ops.zig");
const string_ops = @import("string_ops.zig");
const vm_property_globals = @import("vm_property_globals.zig");

// Helpers that remain in call_runtime.zig (generic utilities outside the eval
// cluster).
const InlineCallRequest = call_runtime.InlineCallRequest;
const ValueSliceRoot = array_ops.ValueSliceRoot;
const CellSliceRoot = array_ops.CellSliceRoot;
const appendSourceStringUtf8 = string_ops.appendSourceStringUtf8;
const argsFromArray = array_ops.argsFromArray;
const atomIdOrNameEql = call_runtime.atomIdOrNameEql;
const callValueOrBytecode = call_runtime.callValueOrBytecode;
const classStaticThisAtom = call_runtime.classStaticThisAtom;
const classStaticThisValue = call_runtime.classStaticThisValue;
const freeArgs = call_runtime.freeArgs;
const functionBytecodeFromValue = call_runtime.functionBytecodeFromValue;
const handleCatchableRuntimeError = call_runtime.handleCatchableRuntimeError;
const normalizeEvalRuntimeError = exception_ops.normalizeEvalRuntimeError;
const objectFromValue = object_ops.objectFromValue;

fn appendEvalClosureSeed(
    rt: *core.JSRuntime,
    seeds: *std.ArrayList(parser.EvalClosureSeed),
    atom_id: core.Atom,
    closure_type: bytecode.function_bytecode.ClosureType,
    var_idx: u16,
    is_lexical: bool,
    is_const: bool,
    var_kind: bytecode.function_bytecode.VarKind,
) !void {
    if (atom_id == core.atom.null_atom) return;
    // qjs add_closure_variables copies every visible scoped binding, argument,
    // unscoped local, and inherited closure row in order. Same-name bindings
    // are distinct identities; lookup-first-match supplies shadowing later.
    try seeds.append(rt.memory.allocator, .{
        .var_name = atom_id,
        .closure_type = closure_type,
        .var_idx = var_idx,
        .is_lexical = is_lexical,
        .is_const = is_const,
        .var_kind = var_kind,
    });
}

fn directEvalVarIsInParameterScope(vd: bytecode.function_bytecode.BytecodeVarDef) bool {
    return vd.var_name == core.atom.ids.home_object or
        vd.var_name == core.atom.ids.this_active_func or
        vd.var_name == core.atom.ids.new_target or
        vd.var_name == core.atom.ids.this_ or
        vd.var_name == core.atom.ids.arg_var_object or
        vd.varKind() == .function_name;
}

const DirectEvalClosureSeed = struct {
    values: []parser.EvalClosureSeed = &.{},
    is_arg_scope: bool = false,
};

fn createDirectEvalClosureSeed(
    rt: *core.JSRuntime,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    eval_scope_head: i32,
) !DirectEvalClosureSeed {
    const function = caller_function orelse return .{};
    const frame = caller_frame orelse return .{};

    var seeds = std.ArrayList(parser.EvalClosureSeed).empty;
    errdefer seeds.deinit(rt.memory.allocator);

    const local_count = @min(function.vardefs.len, frame.locals.len);
    const locals = function.vardefs[0..local_count];

    // qjs add_closure_variables starts at the adjusted operand, follows the
    // finalized scope_next chain, and adds only rows carrying has_scope.
    var chain_index = eval_scope_head;
    var visited: usize = 0;
    while (chain_index >= 0) {
        if (@as(usize, @intCast(chain_index)) >= locals.len or visited >= locals.len) {
            return error.InvalidBytecode;
        }
        visited += 1;
        const local_index: usize = @intCast(chain_index);
        const vd = locals[local_index];
        if (vd.hasScope()) {
            try appendEvalClosureSeed(rt, &seeds, vd.var_name, .local, @intCast(local_index), vd.isLexical(), vd.isConst(), vd.varKind());
        }
        chain_index = vd.scope_next;
    }
    if (chain_index != -1 and chain_index != bytecode.function_bytecode.arg_scope_end) return error.InvalidBytecode;
    const is_arg_scope = chain_index == bytecode.function_bytecode.arg_scope_end;

    if (!is_arg_scope) {
        const arg_count = @min(function.argdefs.len, frame.args.len);
        for (function.argdefs[0..arg_count], 0..) |arg, arg_index| {
            try appendEvalClosureSeed(rt, &seeds, arg.var_name, .arg, @intCast(arg_index), false, false, .normal);
        }
        for (locals, 0..) |vd, local_index| {
            if (vd.hasScope() or vd.var_name == core.atom.ids.ret) continue;
            try appendEvalClosureSeed(rt, &seeds, vd.var_name, .local, @intCast(local_index), vd.isLexical(), vd.isConst(), vd.varKind());
        }
    } else {
        // Argument-scope eval sees only QuickJS's pseudo parameter bindings;
        // ordinary arguments and body locals belong to the later body scope.
        for (locals, 0..) |vd, local_index| {
            if (vd.hasScope() or !directEvalVarIsInParameterScope(vd)) continue;
            try appendEvalClosureSeed(rt, &seeds, vd.var_name, .local, @intCast(local_index), vd.isLexical(), vd.isConst(), vd.varKind());
        }
    }

    for (function.closure_var, 0..) |cv, idx| {
        switch (cv.closureType()) {
            // qjs add_closure_variables omits every global family entry from
            // a direct-eval seed; the eval unit resolves those names against
            // its own global environment. Module declarations/imports remain
            // ordinary live cells and are intentionally forwarded.
            .global, .global_ref, .global_decl => continue,
            // QuickJS forwards these rows by finalized table identity. The
            // final JSClosureVar has no source-depth field; the eval compiler
            // receives an opaque REF seed and threads any nested consumers by
            // table order and var_idx.
            .local, .arg, .ref, .module_decl, .module_import => {},
        }
        try appendEvalClosureSeed(rt, &seeds, cv.var_name, .ref, @intCast(idx), cv.isLexical(), cv.isConst(), cv.varKind());
    }

    if (seeds.items.len == 0) {
        seeds.deinit(rt.memory.allocator);
        return .{ .is_arg_scope = is_arg_scope };
    }
    const owned = try rt.memory.alloc(parser.EvalClosureSeed, seeds.items.len);
    @memcpy(owned, seeds.items);
    seeds.deinit(rt.memory.allocator);
    return .{ .values = owned, .is_arg_scope = is_arg_scope };
}

pub fn functionBytecodeHasDirectEval(fb: *const bytecode.FunctionBytecode, rt: *core.JSRuntime) bool {
    _ = rt;
    var pc: usize = 0;
    while (pc < fb.byteCode().len) {
        const opc = fb.byteCode()[pc];
        if (opc == op.eval or opc == op.apply_eval) return true;
        const size = bytecode.opcode.sizeOf(opc);
        pc += if (size == 0) 1 else size;
    }
    return false;
}

pub fn functionBytecodeUsesImportMeta(fb: *const bytecode.FunctionBytecode) bool {
    var pc: usize = 0;
    while (pc < fb.byteCode().len) {
        const opc = fb.byteCode()[pc];
        if (opc == op.special_object and pc + 1 < fb.byteCode().len and fb.byteCode()[pc + 1] == 4) return true;
        const size = bytecode.opcode.sizeOf(opc);
        pc += if (size == 0) 1 else size;
    }
    return false;
}

/// The direct-eval frame's view of an outer var_ref slot. Normally the slot
/// cell itself (rc++). For a read-only closure var whose shared cell
/// carries no const flag — a module import slot directly aliases the
/// EXPORTING module's live cell (qjs js_inner_module_linking form,
/// quickjs.c:30765-30777) and must not have importer-side const-ness stamped
/// Direct eval shares the exact outer cell. Read-only semantics belong to the
/// eval bytecode's ClosureVar descriptor (checked by execPutVarRef), not to a
/// wrapper cell that would give one binding two runtime identities.
fn directEvalOuterVarRefView(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    idx: usize,
) !*core.VarRef {
    _ = ctx;
    if (idx >= function.closure_var.len or idx >= frame.var_refs.len) return error.InvalidBytecode;
    return frame.var_refs[idx].retain();
}

fn initialDirectEvalFrameVarRef(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    idx: usize,
) !*core.VarRef {
    if (idx < function.closure_var.len) {
        const cv = function.closure_var[idx];
        switch (cv.closureType()) {
            .global, .global_ref, .global_decl => {
                if (call_runtime.globalLexicalCell(ctx, cv.var_name)) |cell_value| return ownedCellFromValue(ctx.runtime, cell_value);
                if (call_runtime.globalObjectVarRefCell(global, cv.var_name)) |cell_value| return ownedCellFromValue(ctx.runtime, cell_value);
                return ownedCellFromValue(ctx.runtime, try call_runtime.globalObjectGetUninitializedVar(ctx, global, cv.var_name));
            },
            .local, .arg, .ref, .module_decl, .module_import => {},
        }
        const initial_value = switch (cv.closureType()) {
            .global, .global_ref, .global_decl => unreachable,
            .module_decl, .module_import => core.JSValue.uninitialized(),
            .local, .arg, .ref => call_runtime.globalLexicalValueForGlobal(ctx, global, cv.var_name) orelse global.getProperty(cv.var_name),
        };
        var initial_owned = initial_value;
        errdefer initial_owned.free(ctx.runtime);
        const cell = try core.VarRef.createClosed(ctx.runtime, initial_owned);
        initial_owned = core.JSValue.undefinedValue();
        cell.varRefIsConstSlot().* = cv.isConst();
        cell.varRefIsFunctionNameSlot().* = cv.varKind() == .function_name;
        return cell;
    }

    const atom_id = function.varRefName(idx);
    if (call_runtime.globalLexicalCell(ctx, atom_id)) |cell_value| return ownedCellFromValue(ctx.runtime, cell_value);
    if (call_runtime.globalObjectVarRefCell(global, atom_id)) |cell_value| return ownedCellFromValue(ctx.runtime, cell_value);
    return ownedCellFromValue(ctx.runtime, try call_runtime.globalObjectGetUninitializedVar(ctx, global, atom_id));
}

fn ownedCellFromValue(rt: *core.JSRuntime, owned: core.JSValue) !*core.VarRef {
    return core.VarRef.fromValue(owned) orelse {
        owned.free(rt);
        return error.InvalidBytecode;
    };
}

fn directEvalSeedFrameVarRef(
    ctx: *core.JSContext,
    global: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    eval_global_var_bindings: bool,
    cv: bytecode.function_bytecode.BytecodeClosureVar,
) !?*core.VarRef {
    const outer_function = caller_function orelse return null;
    const outer_frame = caller_frame orelse return null;
    return switch (cv.closureType()) {
        .local => blk: {
            const local_idx: usize = cv.var_idx;
            if (local_idx >= outer_function.vardefs.len or local_idx >= outer_frame.locals.len) return error.InvalidBytecode;
            const vd = outer_function.vardefs[local_idx];
            if (eval_global_var_bindings and
                !vd.hasScope() and
                call_runtime.globalLexicalHasForGlobal(ctx, global, vd.var_name) and
                directEvalVisibleLocalNameCount(ctx.runtime, outer_function.vardefs[0..@min(outer_function.vardefs.len, outer_frame.locals.len)], vd.var_name) == 1)
            {
                break :blk null;
            }
            break :blk try outer_frame.captureLocal(ctx.runtime, local_idx);
        },
        .arg => blk: {
            const arg_idx: usize = cv.var_idx;
            if (arg_idx >= outer_frame.args.len) return error.InvalidBytecode;
            break :blk try outer_frame.captureArg(ctx.runtime, arg_idx);
        },
        .ref => blk: {
            if (cv.var_idx >= outer_function.varRefNamesLen() or cv.var_idx >= outer_frame.var_refs.len) return error.InvalidBytecode;
            break :blk try directEvalOuterVarRefView(ctx, outer_function, outer_frame, cv.var_idx);
        },
        .global_ref, .global_decl, .global, .module_decl, .module_import => null,
    };
}

fn createDirectEvalFrameVarRefs(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    eval_global_var_bindings: bool,
) ![]*core.VarRef {
    const count = @max(function.closure_var.len, function.varRefNamesLen());
    if (count == 0) return &.{};

    // Slot-typed direct-eval frame refs are selected by the compiler's indexed
    // closure seed. Fresh cells cover unresolved/global fallbacks.
    const refs = try ctx.runtime.memory.alloc(*core.VarRef, count);
    var rooted_refs: []*core.VarRef = refs[0..0];
    var refs_root = CellSliceRoot{};
    refs_root.init(ctx.runtime, &rooted_refs);
    defer refs_root.deinit();

    var initialized: usize = 0;
    errdefer {
        for (refs[0..initialized]) |cell| cell.freeCell(ctx.runtime);
        rooted_refs = &.{};
        ctx.runtime.memory.free(*core.VarRef, refs);
    }

    while (initialized < count) : (initialized += 1) {
        const cv = if (initialized < function.closure_var.len) function.closure_var[initialized] else null;
        // The compiler-selected (closure_type,var_idx) pair is authoritative.
        const indexed_cell = if (cv) |closure_var|
            try directEvalSeedFrameVarRef(ctx, global, caller_function, caller_frame, eval_global_var_bindings, closure_var)
        else
            null;
        const cell = indexed_cell orelse
            try initialDirectEvalFrameVarRef(ctx, global, function, initialized);
        refs[initialized] = cell;
        rooted_refs = refs[0 .. initialized + 1];
    }
    return refs;
}

fn freeDirectEvalFrameVarRefs(rt: *core.JSRuntime, refs: []*core.VarRef) void {
    for (refs) |cell| cell.freeCell(rt);
    if (refs.len != 0) rt.memory.free(*core.VarRef, refs);
}

pub fn functionBytecodeUsesAtom(rt: *core.JSRuntime, fb: *const bytecode.FunctionBytecode, atom_id: core.Atom) bool {
    // Atom operands live inline in the bytecode (no side array); walk them.
    var it = fb.atomOperandIterator();
    while (it.next()) |operand| {
        if (atomIdOrNameEql(rt, operand, atom_id)) return true;
    }
    for (fb.closureVar()) |cv| {
        const name = cv.var_name;
        if (atomIdOrNameEql(rt, name, atom_id)) return true;
    }
    return false;
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
    eval_scope_head: i32,
    eval_in_class_field_initializer: bool,
    allow_tail_inline: bool,
) !ExecEvalResult {
    // `return eval(...)` lowers to `eval ; return`. When the callee is not
    // %eval%, the call is an ordinary one (12.3.4.1 step 9 evaluates it
    // with the tailCall flag); request frame reuse like op.tail_call.
    if (allow_tail_inline and frame.pc < function.code.len and function.code[frame.pc] == op.@"return") {
        const total = @as(usize, argc) + 1;
        if (stack.len() >= total) {
            const region_base = stack.len() - total;
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
        directEval(ctx, output, global, rooted_args, function, frame, eval_scope_head, eval_in_class_field_initializer) catch |err| {
            const eval_err = normalizeEvalRuntimeError(err);
            if (try handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, eval_err)) {
                return .continue_loop;
            }
            return eval_err;
        }
    else
        callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), func, rooted_args, function, frame) catch |err| {
            if (try handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) {
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
    eval_scope_head: i32,
    eval_in_class_field_initializer: bool,
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
        directEval(ctx, output, global, args, function, frame, eval_scope_head, eval_in_class_field_initializer) catch |err| {
            const eval_err = normalizeEvalRuntimeError(err);
            if (try handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, eval_err)) {
                return .continue_loop;
            }
            return eval_err;
        }
    else
        callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), func, args, function, frame) catch |err| {
            if (try handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) {
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
    eval_scope_head: i32,
    eval_in_class_field_initializer: bool,
) !core.JSValue {
    if (args.len == 0) return core.JSValue.undefinedValue();
    if (!args[0].isString()) return args[0].dup();
    var source = std.ArrayList(u8).empty;
    defer source.deinit(ctx.runtime.memory.allocator);
    try appendSourceStringUtf8(ctx.runtime, &source, args[0]);
    const caller_strict = if (caller_function) |outer_function| outer_function.flags.is_strict else false;
    var caller_entry = if (caller_function) |outer_function|
        outer_function.entry_contract
    else
        bytecode.EntryContract{
            .var_environment = .global,
            .arguments_allowed = true,
            .has_this_binding = true,
        };
    // QuickJS executes field initializers as a dedicated bytecode function
    // whose grammar capabilities are {new.target, super.prop} but not
    // {super(), arguments}. zjs still carries this source context on the eval
    // opcode for inline field-initializer forms, so normalize it into the same
    // entry contract before compiling the eval.
    if (eval_in_class_field_initializer) {
        caller_entry.new_target_allowed = true;
        caller_entry.super_call_allowed = false;
        caller_entry.super_allowed = true;
        caller_entry.arguments_allowed = false;
    }
    const requested_eval_global_var_bindings = caller_entry.directEvalVarsReachGlobal();
    const eval_allows_new_target = caller_entry.new_target_allowed;
    const eval_allows_super_call = caller_entry.super_call_allowed;
    const eval_allows_super_property = caller_entry.super_allowed;
    const eval_arguments_allowed = caller_entry.arguments_allowed;
    const eval_class_static_field_this_atom = classStaticThisAtom(caller_function, caller_frame);
    const eval_private_bound_names = try directEvalPrivateBoundNames(ctx.runtime, caller_function);
    defer if (eval_private_bound_names.len != 0) ctx.runtime.memory.free(core.Atom, eval_private_bound_names);
    const eval_seed = try createDirectEvalClosureSeed(ctx.runtime, caller_function, caller_frame, eval_scope_head);
    defer if (eval_seed.values.len != 0) ctx.runtime.memory.free(parser.EvalClosureSeed, eval_seed.values);
    const eval_script_or_module = if (caller_function) |outer_function|
        outer_function.script_or_module
    else
        null;
    var compiled = try parser.compile(ctx.runtime, source.items, .{
        .mode = .eval_direct,
        .filename = "<eval>",
        .script_or_module = eval_script_or_module,
        .strict = caller_strict,
        .eval_global_var_bindings = requested_eval_global_var_bindings,
        .eval_in_parameter_initializer = eval_seed.is_arg_scope,
        .eval_in_class_field_initializer = eval_in_class_field_initializer,
        .eval_allows_new_target = eval_allows_new_target,
        .eval_allows_super_call = eval_allows_super_call,
        .eval_allows_super_property = eval_allows_super_property,
        .eval_arguments_allowed = eval_arguments_allowed,
        .eval_class_static_field_this_atom = eval_class_static_field_this_atom,
        .eval_private_bound_names = eval_private_bound_names,
        .eval_closure_seed = eval_seed.values,
    });
    defer compiled.deinit();
    if (compiled.syntax_error) |*parse_error| {
        // qjs parse errors throw with the compile-error surface: own
        // fileName/lineNumber/columnNumber and a leading `at file:line:col`
        // stack line (build_backtrace filename branch, quickjs.c:7553-7570).
        const parse_filename = ctx.runtime.atoms.name(parse_error.filename) orelse "<eval>";
        return error_stack_ops.throwParseSyntaxError(ctx, global, parse_filename, parse_error.position.line, parse_error.position.column, parse_error.message);
    }
    const eval_strict = compiled.function.flags.is_strict;
    const eval_global_var_bindings = requested_eval_global_var_bindings and !eval_strict;
    // qjs js_closure2 PASS1 validates every GLOBAL_DECL descriptor before
    // creating any VarRef cell. Caller-lexical conflicts are not host-scanned:
    // resolve_variables emitted their leading throw bytecode, preserving qjs's
    // compile-time declaration-environment walk and exception timing.
    try vm_property_globals.validateGlobalVarDeclarations(ctx, global, &compiled.function, true);
    var nested_stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.runtime.stackSize());
    defer nested_stack.deinit(ctx.runtime);
    var direct_eval_frame_var_refs = try createDirectEvalFrameVarRefs(ctx, global, &compiled.function, caller_function, caller_frame, eval_global_var_bindings);
    defer freeDirectEvalFrameVarRefs(ctx.runtime, direct_eval_frame_var_refs);
    var direct_eval_frame_var_refs_root = CellSliceRoot{};
    direct_eval_frame_var_refs_root.init(ctx.runtime, &direct_eval_frame_var_refs);
    defer direct_eval_frame_var_refs_root.deinit();
    const eval_this = try directEvalThisValue(ctx, global, caller_function, caller_frame);
    const eval_new_target = if (eval_allows_new_target)
        directEvalNewTargetValue(caller_function, caller_frame)
    else
        core.JSValue.undefinedValue();
    const eval_current_function = blk: {
        if (caller_frame) |outer_frame| break :blk outer_frame.current_function;
        break :blk core.JSValue.undefinedValue();
    };
    const result = try runWithCallEnv(.{
        .ctx = ctx,
        .stack = &nested_stack,
        .function = &compiled.function,
        .initial_this_value = eval_this,
        .var_refs = direct_eval_frame_var_refs,
        .output = output,
        .global = global,
        .strict_unresolved_get_var = eval_strict,
        .current_function_value = eval_current_function,
        .new_target_value = eval_new_target,
        .eval_global_var_bindings = eval_global_var_bindings,
        .is_eval_code = true,
        .global_declarations_prevalidated = true,
    });
    errdefer result.free(ctx.runtime);
    return result;
}

pub fn directEvalThisValue(
    ctx: *core.JSContext,
    global: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const outer_frame = caller_frame orelse return core.JSValue.undefinedValue();
    if (capturedArrowSpecialValue(caller_function, outer_frame, core.atom.ids.this_)) |value| return value;
    if (classStaticThisAtom(caller_function, caller_frame)) |atom_id| {
        if (classStaticThisValue(caller_function, outer_frame, atom_id)) |value| return value;
    }
    if (caller_function) |function| {
        if (function.flags.is_derived_class_constructor) {
            const local_count = @min(function.vardefs.len, outer_frame.locals.len);
            for (function.vardefs[0..local_count], 0..) |vd, idx| {
                if (vd.var_name == core.atom.ids.this_) return outer_frame.locals[idx];
            }
            return error.InvalidBytecode;
        }
    }
    return object_ops.materializeFrameThisBinding(ctx, global, outer_frame);
}

fn capturedArrowSpecialValue(
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: *frame_mod.Frame,
    name: core.Atom,
) ?core.JSValue {
    const function = caller_function orelse return null;
    if (!function.flags.is_arrow_function) return null;
    for (function.closure_var, 0..) |capture, index| {
        if (capture.var_name == name and index < caller_frame.var_refs.len) {
            return caller_frame.var_refs[index].varRefValue();
        }
    }
    return null;
}

fn directEvalNewTargetValue(
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) core.JSValue {
    const frame = caller_frame orelse return core.JSValue.undefinedValue();
    return capturedArrowSpecialValue(caller_function, frame, core.atom.ids.new_target) orelse frame.newTargetValue();
}

pub fn directEvalPrivateBoundNames(
    rt: *core.JSRuntime,
    caller_function: ?*const bytecode.Bytecode,
) ![]core.Atom {
    const function = caller_function orelse return &.{};
    if (function.private_bound_names.len == 0) return &.{};
    const names = try rt.memory.alloc(core.Atom, function.private_bound_names.len);
    @memcpy(names, function.private_bound_names);
    return names;
}

pub fn directEvalVisibleLocalNameCount(rt: *core.JSRuntime, vardefs: []const bytecode.function_bytecode.BytecodeVarDef, atom_id: core.Atom) usize {
    var count: usize = 0;
    for (vardefs) |vd| {
        if (atomIdOrNameEql(rt, vd.var_name, atom_id)) count += 1;
    }
    return count;
}

pub fn directEvalShouldExposeImplicitArguments(caller_frame: *frame_mod.Frame) bool {
    if (functionBytecodeFromValue(caller_frame.current_function)) |fb| return fb.flags.has_arguments_binding;
    if (objectFromValue(caller_frame.current_function)) |function_object| {
        const stored = function_object.functionBytecode() orelse return false;
        const fb = functionBytecodeFromValue(stored) orelse return false;
        return fb.flags.has_arguments_binding;
    }
    return false;
}
