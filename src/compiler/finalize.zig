//! Finalization: js_create_function equivalent
//!
//! Mirrors `js_create_function` at `quickjs.c`.
//!
//! This walks the child_list of FunctionDefs, runs all pipeline phases,
//! and installs the final FunctionBytecode into the parent's cpool.

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const array_list_erased = @import("../core/array_list_erased.zig");
const atom = @import("../core/atom.zig");
const bigint_mod = @import("../core/bigint.zig");
const context = @import("../core/context.zig");
const runtime = @import("../core/runtime.zig");
const JSValue = @import("../core/value.zig").JSValue;
const compiler = @import("root.zig");
const Bytecode = bytecode.Bytecode;
const FunctionBytecode = bytecode.FunctionBytecode;
const FunctionDef = bytecode.FunctionDef;
const pipeline = bytecode.pipeline;
const opcode = bytecode.opcode;
const module = bytecode.module;
const CompileContext = bytecode.CompileContext;
const function_bytecode = bytecode.function_bytecode;
const function_def = bytecode.function_def;
const pipeline_pc2line = bytecode.pipeline.pc2line;
const binding_rules = bytecode.binding_rules;
const pipeline_stack_size = bytecode.pipeline.stack_size;
const dump = bytecode.dump;
const function_mod = bytecode.carrier;

const fb_mod = function_bytecode;
const bytecode_function = function_mod;
const function_def_mod = function_def;

const pc2line = pipeline_pc2line;
const stack_size = pipeline_stack_size;

pub const FinalizeError = error{
    OutOfMemory,
    InvalidBytecode,
    InvalidOpcode,
    BytecodeOverflow,
    StackUnderflow,
    StackOverflow,
    StackMismatch,
    ClosureVarNotFound,
    Pc2LineTruncated,
    Pc2LineOverflow,
};

/// JSContext for finalization.
pub const JSContext = struct {
    // For the interim Bytecode-based implementation, we just need
    // the function to process. The full FunctionDef-based version
    // will include parent/child relationship tracking.
};

fn isVarInArgumentScope(vd: function_def_mod.VarDef) bool {
    return vd.var_name == atom.ids.home_object or
        vd.var_name == atom.ids.this_active_func or
        vd.var_name == atom.ids.new_target or
        vd.var_name == atom.ids.this_ or
        vd.var_name == atom.ids.arg_var_object or
        vd.var_kind == .function_name;
}

fn captureEvalParentLocal(
    target: *function_def_mod.FunctionDef,
    owner: *function_def_mod.FunctionDef,
    local_idx: usize,
    normalize_unscoped: bool,
) FinalizeError!void {
    if (local_idx > std.math.maxInt(u16)) return error.BytecodeOverflow;
    const source_idx: u16 = @intCast(local_idx);
    if (source_idx >= owner.vars.len) return error.InvalidBytecode;
    owner.captureLocal(source_idx) catch return error.InvalidBytecode;
    const vd = owner.vars[source_idx];
    // QuickJS add_eval_variables preserves scoped binding attributes, but
    // deliberately forwards ancestor unscoped locals as non-const NORMAL
    // rows. In particular, a named-function self binding loses its
    // FUNCTION_NAME write protection only along this descendant-eval path.
    _ = binding_rules.threadClosureSource(
        target,
        owner,
        source_idx,
        function_def_mod.ClosureVar.init(.{
            .closure_type = .local,
            .is_lexical = vd.is_lexical,
            .is_const = if (normalize_unscoped) false else vd.is_const,
            .var_kind = if (normalize_unscoped) .normal else vd.var_kind,
            .var_idx = source_idx,
            .var_name = vd.var_name,
        }),
        .local,
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BytecodeOverflow => error.BytecodeOverflow,
        else => error.InvalidBytecode,
    };
}

fn captureEvalParentArg(
    target: *function_def_mod.FunctionDef,
    owner: *function_def_mod.FunctionDef,
    arg_idx: usize,
) FinalizeError!void {
    if (arg_idx > std.math.maxInt(u16)) return error.BytecodeOverflow;
    const source_idx: u16 = @intCast(arg_idx);
    if (source_idx >= owner.args.len) return error.InvalidBytecode;
    owner.captureArg(source_idx) catch return error.InvalidBytecode;
    const arg = owner.args[source_idx];
    // Ancestor arguments use the same add_eval_variables normalization:
    // lexical provenance is retained, while const/kind are ordinary.
    _ = binding_rules.threadClosureSource(
        target,
        owner,
        source_idx,
        function_def_mod.ClosureVar.init(.{
            .closure_type = .arg,
            .is_lexical = arg.is_lexical,
            .is_const = false,
            .var_kind = .normal,
            .var_idx = source_idx,
            .var_name = arg.var_name,
        }),
        .arg,
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BytecodeOverflow => error.BytecodeOverflow,
        else => error.InvalidBytecode,
    };
}

fn addEvalVariables(fd: *function_def_mod.FunctionDef) FinalizeError!void {
    if (!fd.has_eval_call) return;

    if (!fd.is_eval and !fd.is_strict_mode) {
        if (fd.var_object_idx == null) {
            fd.var_object_idx = @intCast(fd.appendVar(.{
                .var_name = atom.ids.var_object,
                .scope_level = 0,
                .scope_next = 0,
                .var_kind = .normal,
            }) catch return error.OutOfMemory);
        }
        if (fd.has_parameter_expressions and fd.arg_var_object_idx == null) {
            fd.arg_var_object_idx = @intCast(fd.appendVar(.{
                .var_name = atom.ids.arg_var_object,
                .scope_level = 0,
                .scope_next = 0,
                .var_kind = .normal,
            }) catch return error.OutOfMemory);
        }
    }

    var has_this_binding = fd.has_this_binding;
    if (has_this_binding) {
        _ = fd.ensureThisBinding() catch return error.OutOfMemory;
        _ = fd.ensureNewTargetBinding() catch return error.OutOfMemory;
        if (fd.is_derived_class_constructor) {
            _ = fd.ensureThisActiveFunctionBinding() catch return error.OutOfMemory;
        }
        if (fd.has_home_object) _ = fd.ensureHomeObjectBinding() catch return error.OutOfMemory;
    }
    var has_arguments_binding = fd.has_arguments_binding;
    if (has_arguments_binding) {
        _ = fd.ensureArgumentsBinding() catch return error.OutOfMemory;
        if (fd.has_parameter_expressions and !fd.is_strict_mode) {
            fd.ensureArgumentsArgumentBinding() catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidScope => error.InvalidBytecode,
            };
        }
    }
    if (fd.is_named_func_expr) _ = fd.ensureFuncExprSelfBinding() catch return error.OutOfMemory;

    for (fd.args, 0..) |_, arg_idx| try fd.captureArg(arg_idx);
    for (fd.vars, 0..) |vd, local_idx| {
        if (vd.scope_level != 0 or vd.var_name == atom.ids.ret or vd.var_name == atom.null_atom) continue;
        try fd.captureLocal(local_idx);
    }

    var maybe_parent = fd.parent;
    var visible_scope = fd.parent_scope_level;
    while (maybe_parent) |parent| {
        if (parent.finalization_state != .prepared) return error.InvalidBytecode;
        if (!has_this_binding and parent.has_this_binding) {
            _ = parent.ensureThisBinding() catch return error.OutOfMemory;
            _ = parent.ensureNewTargetBinding() catch return error.OutOfMemory;
            if (parent.is_derived_class_constructor) {
                _ = parent.ensureThisActiveFunctionBinding() catch return error.OutOfMemory;
            }
            if (parent.has_home_object) _ = parent.ensureHomeObjectBinding() catch return error.OutOfMemory;
            has_this_binding = true;
        }
        if (!has_arguments_binding and parent.has_arguments_binding) {
            _ = parent.ensureArgumentsBinding() catch return error.OutOfMemory;
            has_arguments_binding = true;
        }
        if (parent.is_named_func_expr) _ = parent.ensureFuncExprSelfBinding() catch return error.OutOfMemory;

        if (visible_scope < 0 or @as(usize, @intCast(visible_scope)) >= parent.scopes.len) {
            return error.InvalidBytecode;
        }
        var scope_idx = parent.scopes[@intCast(visible_scope)].first;
        var visited: usize = 0;
        while (scope_idx >= 0) {
            if (@as(usize, @intCast(scope_idx)) >= parent.vars.len or visited >= parent.vars.len) {
                return error.InvalidBytecode;
            }
            visited += 1;
            try captureEvalParentLocal(fd, parent, @intCast(scope_idx), false);
            scope_idx = parent.vars[@intCast(scope_idx)].scope_next;
        }

        if (scope_idx != function_bytecode.arg_scope_end) {
            if (scope_idx != -1) return error.InvalidBytecode;
            for (parent.args, 0..) |arg, arg_idx| {
                if (arg.var_name == atom.null_atom) continue;
                try captureEvalParentArg(fd, parent, arg_idx);
            }
            for (parent.vars, 0..) |vd, local_idx| {
                if (vd.scope_level != 0 or vd.var_name == atom.ids.ret or vd.var_name == atom.null_atom) continue;
                try captureEvalParentLocal(fd, parent, local_idx, true);
            }
        } else {
            for (parent.vars, 0..) |vd, local_idx| {
                if (vd.scope_level == 0 and isVarInArgumentScope(vd)) {
                    try captureEvalParentLocal(fd, parent, local_idx, true);
                }
            }
        }

        if (parent.is_eval) {
            for (parent.closure_var, 0..) |cv, closure_idx| {
                switch (cv.closureType()) {
                    .global, .global_ref, .global_decl => continue,
                    .local, .arg, .ref, .module_decl, .module_import => {},
                }
                if (closure_idx > std.math.maxInt(u16)) return error.BytecodeOverflow;
                _ = binding_rules.threadClosureSource(
                    fd,
                    parent,
                    @intCast(closure_idx),
                    cv,
                    .ref,
                ) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.BytecodeOverflow => error.BytecodeOverflow,
                    else => error.InvalidBytecode,
                };
            }
        }

        visible_scope = parent.parent_scope_level;
        maybe_parent = parent.parent;
    }
}

fn addGlobalVariables(fd: *function_def_mod.FunctionDef) FinalizeError!void {
    if (!fd.is_eval) return;
    var need_global_closures = true;
    if (fd.is_direct_eval and !fd.is_strict_mode) {
        for (fd.closure_var) |cv| {
            if (cv.var_name == atom.ids.var_object or cv.var_name == atom.ids.arg_var_object) {
                need_global_closures = false;
                break;
            }
        }
    }
    if (!need_global_closures) return;

    const closure_type: function_def_mod.ClosureType = if (fd.is_module) .module_decl else .global_decl;
    for (fd.global_vars, 0..) |gv, global_idx| {
        if (global_idx > std.math.maxInt(u16)) return error.BytecodeOverflow;
        const var_kind: function_def_mod.VarKind = if (gv.cpool_idx >= 0 and !gv.is_lexical)
            .global_function_decl
        else
            .normal;
        _ = fd.addClosureVar(.{
            .closure_type = closure_type,
            .is_lexical = gv.is_lexical,
            .is_const = gv.is_const,
            .var_kind = var_kind,
            .var_idx = @intCast(global_idx),
            .var_name = gv.var_name,
        }) catch return error.OutOfMemory;
    }
}

fn prepareCurrentBeforeChildren(
    fd: *function_def_mod.FunctionDef,
    root_module_record: ?*module.Record,
) FinalizeError!void {
    if (fd.finalization_state != .unprepared) return error.InvalidBytecode;
    if (fd.parent) |parent| {
        if (parent.finalization_state != .prepared) return error.InvalidBytecode;
    }

    // QCP-1 v2: resolve_variables_v2 validates its own compact input
    // (validateInput + fail-closed walk) when compileFunction consumes
    // the attached builder. There is no phase-1 code array to validate:
    // the compact Builder is the only lowering input the compiler accepts.
    if (fd.builder == null) return error.InvalidBytecode;
    fd.var_ref_count = 0;
    for (fd.vars) |*vd| {
        vd.is_captured = false;
        vd.open_binding_idx = function_bytecode.no_open_binding;
    }
    for (fd.args) |*arg| {
        arg.is_captured = false;
        arg.open_binding_idx = function_bytecode.no_open_binding;
    }
    fd.rebuildFinalScopeLinks() catch return error.InvalidBytecode;
    try addEvalVariables(fd);
    try addGlobalVariables(fd);
    if (root_module_record) |record| {
        if (!fd.is_module) return error.InvalidBytecode;
        const max_closure_count = @as(usize, std.math.maxInt(u16)) + 1;
        if (fd.closure_var.len > max_closure_count) return error.BytecodeOverflow;
        for (record.imports) |entry| {
            if (entry.var_idx >= fd.closure_var.len) return error.InvalidBytecode;
            const closure = fd.closure_var[entry.var_idx];
            if (closure.var_name != entry.local_name) return error.InvalidBytecode;
            const expected_type: function_def_mod.ClosureType = if (entry.is_namespace)
                .module_decl
            else
                .module_import;
            if (closure.closureType() != expected_type) return error.InvalidBytecode;
        }
        for (record.exports) |*entry| {
            var var_idx: ?u16 = null;
            for (fd.closure_var, 0..) |closure, index| {
                if (closure.var_name != entry.local_name) continue;
                if (index > std.math.maxInt(u16)) return error.BytecodeOverflow;
                var_idx = @intCast(index);
                break;
            }
            entry.var_idx = var_idx orelse return error.ClosureVarNotFound;
        }
    }
    fd.finalization_state = .prepared;
}

/// Prove the finalized event-driven frame contract while source metadata
/// is still available. No vars/args grouping is part of the contract:
/// every assigned index must be unique and the complete set must be dense.
fn validateOpenBindingIndices(fd: *const function_def_mod.FunctionDef, count: u16) FinalizeError!void {
    const seen = fd.memory.alloc(bool, count) catch return error.OutOfMemory;
    defer fd.memory.free(bool, seen);
    @memset(seen, false);

    var captured_count: u32 = 0;
    for (fd.vars) |vd| {
        if (!vd.is_captured) {
            if (vd.open_binding_idx != function_bytecode.no_open_binding) return error.InvalidBytecode;
            continue;
        }
        if (vd.open_binding_idx >= count) return error.InvalidBytecode;
        if (seen[vd.open_binding_idx]) return error.InvalidBytecode;
        seen[vd.open_binding_idx] = true;
        captured_count += 1;
    }
    for (fd.args) |arg| {
        if (!arg.is_captured) {
            if (arg.open_binding_idx != function_bytecode.no_open_binding) return error.InvalidBytecode;
            continue;
        }
        if (arg.open_binding_idx >= count) return error.InvalidBytecode;
        if (seen[arg.open_binding_idx]) return error.InvalidBytecode;
        seen[arg.open_binding_idx] = true;
        captured_count += 1;
    }
    if (captured_count != count or fd.var_ref_count != count) return error.InvalidBytecode;
}

/// Create a FunctionBytecode from a FunctionDef.
///
/// This mirrors `js_create_function` at `quickjs.c`. It:
/// 1. Recursively processes child functions (child_list walk)
/// 2. Runs all pipeline phases on the FunctionDef
/// 3. Allocates and populates a FunctionBytecode structure
/// 4. Returns the FunctionBytecode
///
pub fn createFunctionBytecode(fd: *function_def_mod.FunctionDef, compile_context: CompileContext) FinalizeError![]fb_mod.FunctionBytecode {
    const disasm_enabled = std.c.getenv("ZJS_DISASM") != null;
    try validateRuntimeIdentity(fd, compile_context.realm.runtime);
    try installChildFunctionBytecodes(fd, null, compile_context, disasm_enabled);
    return createFunctionBytecodeAfterChildren(fd, compile_context, disasm_enabled);
}

/// Finalize an ECMAScript module root through the same canonical
/// FunctionBytecode topology as script and eval roots. The record is
/// borrowed during finalization; its local export indices are fixed before
/// any child FunctionDef is traversed.
pub fn createModuleFunctionBytecode(
    fd: *function_def_mod.FunctionDef,
    record: *module.Record,
    compile_context: CompileContext,
) FinalizeError![]fb_mod.FunctionBytecode {
    const disasm_enabled = std.c.getenv("ZJS_DISASM") != null;
    if (!fd.is_module) return error.InvalidBytecode;
    try validateRuntimeIdentity(fd, compile_context.realm.runtime);
    if (record.memory != fd.memory or record.atoms != fd.atoms) return error.InvalidBytecode;
    try installChildFunctionBytecodes(fd, record, compile_context, disasm_enabled);
    return createFunctionBytecodeAfterChildren(fd, compile_context, disasm_enabled);
}

fn validateRuntimeIdentity(fd: *const function_def_mod.FunctionDef, rt: *runtime.JSRuntime) FinalizeError!void {
    // FunctionDef buffers and atom owners must be released by the same
    // Runtime that accounts, registers, and eventually destroys the FB.
    // Reject a mismatched public caller before any owner is moved.
    if (fd.memory != &rt.memory or fd.atoms != &rt.atoms) return error.InvalidBytecode;
}

fn validatePreLoweringArtifactShape(fd: *const function_def_mod.FunctionDef) FinalizeError!void {
    if (fd.arg_count < 0 or @as(usize, @intCast(fd.arg_count)) != fd.args.len) return error.InvalidBytecode;
    if (fd.var_count < 0 or @as(usize, @intCast(fd.var_count)) != fd.vars.len) return error.InvalidBytecode;
    if (fd.defined_arg_count < 0 or fd.defined_arg_count > fd.arg_count) return error.InvalidBytecode;
    if (fd.args.len > std.math.maxInt(u16) or
        fd.vars.len > std.math.maxInt(u16) or
        @as(usize, @intCast(fd.defined_arg_count)) > std.math.maxInt(u16))
    {
        return error.BytecodeOverflow;
    }
}

fn validateFinalArtifactShape(
    fd: *const function_def_mod.FunctionDef,
    lowered: *const bytecode_function.Bytecode,
) FinalizeError!usize {
    if (fd.arg_count < 0 or @as(usize, @intCast(fd.arg_count)) != fd.args.len) return error.InvalidBytecode;
    if (fd.var_count < 0 or @as(usize, @intCast(fd.var_count)) != fd.vars.len) return error.InvalidBytecode;
    if (fd.defined_arg_count < 0 or fd.defined_arg_count > fd.arg_count) return error.InvalidBytecode;
    if (fd.cpool_count < 0 or @as(usize, @intCast(fd.cpool_count)) != fd.cpool.len) return error.InvalidBytecode;
    if (fd.closure_var_count < 0 or @as(usize, @intCast(fd.closure_var_count)) != fd.closure_var.len) return error.InvalidBytecode;

    if (fd.args.len > std.math.maxInt(u16) or
        fd.vars.len > std.math.maxInt(u16) or
        @as(usize, @intCast(fd.defined_arg_count)) > std.math.maxInt(u16) or
        fd.cpool.len > std.math.maxInt(i32) or
        fd.closure_var.len > std.math.maxInt(i32) or
        lowered.code.len > std.math.maxInt(i32) or
        lowered.pc2line_buf.len > std.math.maxInt(i32))
    {
        return error.BytecodeOverflow;
    }
    if (fd.source_text) |source| {
        if (source.len > std.math.maxInt(i32)) return error.BytecodeOverflow;
        _ = std.math.add(usize, source.len, 1) catch return error.BytecodeOverflow;
    }
    return std.math.add(usize, fd.args.len, fd.vars.len) catch return error.BytecodeOverflow;
}

fn createFunctionBytecodeAfterChildren(
    fd: *function_def_mod.FunctionDef,
    compile_context: CompileContext,
    disasm_enabled: bool,
) FinalizeError![]fb_mod.FunctionBytecode {
    const rt = compile_context.realm.runtime;
    // Lowering publishes arg/var counts to u16 fields, so malformed or
    // oversized FunctionDefs must be rejected before it can cast them.
    try validatePreLoweringArtifactShape(fd);
    // The canonical lowering carrier has no diagnostic/name owners of its
    // own. FunctionDef remains the source of those owners until commit.
    var lowered = bytecode_function.Bytecode.init(fd.memory, fd.atoms, atom.null_atom);
    defer lowered.deinit();
    lowered.line_num = fd.line_num;
    lowered.col_num = fd.col_num;
    // Finalization policy is fixed on FunctionDef before parsing and is
    // visible to every lowering phase, not patched onto the published FB
    // afterwards. This matters for strict-only frame geometry such as
    // mapped-arguments capture decisions.
    lowered.flags.is_strict = fd.is_strict_mode;
    lowered.flags.runtime_strict = compile_context.policy.runtime_strict;
    // QCP-1 v2 lowering releases its compact producer at the consumption
    // point and transfers final buffers to `lowered`. There is no second
    // backend: an absent Builder is a compile error, not a fallback.
    if (fd.finalization_state != .prepared) return error.InvalidBytecode;
    compiler.compileFunction(&lowered, fd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidBytecode, error.NoFunctionDef, error.NoParentScope => return error.InvalidBytecode,
        error.BytecodeOverflow => return error.BytecodeOverflow,
        error.ClosureVarNotFound => return error.ClosureVarNotFound,
    };
    std.debug.assert(fd.builder == null);
    fd.consumeGlobalVars();
    fd.finalization_state = .resolved;
    fd.use_short_opcodes = true;
    try publishLoweredMetadata(&lowered, fd);

    _ = try validateFinalArtifactShape(fd, &lowered);

    // Preflight the exact packed FunctionBytecode layout before the first
    // artifact allocation. Source and pc2line remain independent moved
    // owners, matching QuickJS's debug-tail ownership.
    if (lowered.code.len == 0) return error.InvalidBytecode;
    const layout = try fb_mod.FunctionLayout.init(
        true,
        true,
        fd.cpool.len,
        fd.args.len,
        fd.vars.len,
        fd.closure_var.len,
        lowered.code.len,
        lowered.prop_site_count,
    );

    // Every fallible artifact allocation happens before owner commit.
    const fb = try fb_mod.FunctionBytecode.createProductionShell(fd.memory, layout);
    const slice = fb[0..1];
    var shell_owned = true;
    errdefer if (shell_owned) fd.memory.destroyWithFam(fb_mod.FunctionBytecode, fb, layout.famBytes());
    const dbg = fb.debugInfoMut().?;
    const hot_extension = layout.hotExtensionPtrMut(fb).?;

    // Populate owner-free FAM storage. Code bytes contain numeric atom IDs,
    // while every row/value slot is initialized with its non-owning null
    // sentinel. An allocation failure above can therefore free the single
    // raw FB allocation without touching FunctionDef's owners.
    const cpool = layout.cpoolSliceMut(fb);
    const vardefs = layout.vardefsSliceMut(fb);
    for (fd.args, vardefs[0..fd.args.len]) |arg, *out| {
        out.* = fb_mod.BytecodeVarDef.fromCompile(arg, arg.scope_next);
        out.var_name = atom.null_atom;
    }
    for (fd.vars, vardefs[fd.args.len..]) |local, *out| {
        out.* = fb_mod.BytecodeVarDef.fromCompile(local, local.scope_next);
        out.var_name = atom.null_atom;
    }

    const closure_var = layout.closureVarSliceMut(fb);
    for (fd.closure_var, closure_var) |compile_cv, *runtime_cv| {
        runtime_cv.* = compile_cv;
        runtime_cv.var_name = atom.null_atom;
    }

    const byte_code = layout.byteCodeSliceMut(fb);
    @memcpy(byte_code, lowered.code);

    // --- No-fail owner commit. No `try` or allocation is allowed below. ---
    fb.applyFlags(.{
        .is_strict_mode = fd.is_strict_mode,
        .runtime_strict_mode = compile_context.policy.runtime_strict,
        .has_prototype = fd.has_prototype,
        .has_simple_parameter_list = fd.has_simple_parameter_list,
        .is_derived_class_constructor = fd.is_derived_class_constructor,
        .need_home_object = fd.need_home_object,
        .func_kind = fd.func_kind,
        .new_target_allowed = fd.new_target_allowed,
        .super_call_allowed = fd.super_call_allowed,
        .super_allowed = fd.super_allowed,
        .arguments_allowed = fd.arguments_allowed,
        .is_direct_or_indirect_eval = fd.is_direct_eval or fd.is_indirect_eval,
    });
    fb.defined_arg_count = @intCast(fd.defined_arg_count);
    fb.stack_size = lowered.stack_size;
    fb.var_ref_count = lowered.open_var_ref_count;

    // Realm retention is an infallible refcount operation and belongs to
    // the no-fail commit, matching QuickJS's late JS_DupContext.
    fb.realm = @TypeOf(fb.realm).retain(compile_context.realm);

    fb.func_name = fd.func_name;
    fd.func_name = atom.null_atom;
    dbg.filename = fd.filename;
    fd.filename = atom.null_atom;
    hot_extension.script_or_module = fd.script_or_module;
    fd.script_or_module = atom.null_atom;

    for (fd.args, vardefs[0..fd.args.len]) |*arg, *out| {
        out.var_name = arg.var_name;
        arg.var_name = atom.null_atom;
    }
    for (fd.vars, vardefs[fd.args.len..][0..fd.vars.len]) |*local, *out| {
        out.var_name = local.var_name;
        local.var_name = atom.null_atom;
    }
    for (fd.closure_var, closure_var) |*compile_cv, *runtime_cv| {
        runtime_cv.var_name = compile_cv.var_name;
        compile_cv.var_name = atom.null_atom;
    }

    for (fd.cpool, cpool) |*source, *out| {
        out.* = source.*;
        source.* = JSValue.undefinedValue();
    }
    fd.cpool_count = 0;

    // The copied code is now authoritative for these atom owners. Clear
    // every scratch-ledger slot without changing its backing pointer or
    // capacity; lowered.deinit then frees only the raw backing allocation.
    for (lowered.atom_operands) |*owner| owner.* = atom.null_atom;

    const pc2line_buf = lowered.pc2line_buf;
    lowered.pc2line_buf = &.{};
    lowered.owns_pc2line_buf = false;
    dbg.pc2line_buf = if (pc2line_buf.len == 0) null else pc2line_buf.ptr;
    dbg.pc2line_len = @intCast(pc2line_buf.len);

    if (fd.source_text) |source| {
        dbg.source_ptr = source.ptr;
        dbg.source_len = @intCast(source.len);
        fd.source_text = null;
    }

    bytecode_function.publishExecutionFlags(fb, .{
        .materializes_arguments_object = lowered.flags.materializes_arguments_object,
        .has_mapped_arguments = lowered.flags.has_mapped_arguments,
        .leaf_returns_balanced = lowered.leaf_returns_balanced,
        .contains_direct_eval = fd.has_eval_call,
        .class_syntax_excludes_inline = fd.is_derived_class_constructor or
            fd.func_type == .class_constructor or
            fd.func_type == .derived_class_constructor,
        .is_module = fd.is_module,
    });

    // Reserved constant-pool BigInts join the heap now; the FB published
    // on the next line owns the edge that keeps them alive. Nothing
    // allocates between the two registrations.
    for (cpool) |*slot| bigint_mod.BigInt.registerReservedValue(rt, slot.*);
    shell_owned = false;
    rt.gc.addInitializedWithSizeNoFail(&fb.header, fb.heapByteSizeWithLayout(layout));

    if (disasm_enabled) {
        var disbuf: [65536]u8 = undefined;
        var diswriter = std.Io.Writer.fixed(&disbuf);
        dump.dumpFunctionBytecode(&diswriter, fb, &rt.atoms, .{ .show_raw_bytes = true }) catch {};
        std.debug.print("{s}\n", .{diswriter.buffered()});
    }
    return slice;
}

fn publishLoweredMetadata(
    function: *bytecode_function.Bytecode,
    def: *function_def_mod.FunctionDef,
) !void {
    // qjs captures every formal parameter before creating a mapped
    // arguments object. Do the same here, then assign one exact, stable
    // table index to every captured local/argument. Runtime frame sizing
    // and every identity consumer use this metadata; there is no
    // address-search or "extra capacity" fallback.
    //
    // The only arguments-object producer is the S4 prologue, emitted from
    // this exact QuickJS identity field.
    const materializes_arguments_object = def.arguments_var_idx != null;
    function.flags.materializes_arguments_object = materializes_arguments_object;
    const mapped_arguments = !def.is_strict_mode and
        !function.flags.runtime_strict and
        def.has_simple_parameter_list and
        materializes_arguments_object;
    function.flags.has_mapped_arguments = mapped_arguments;
    if (mapped_arguments) {
        for (def.args, 0..) |_, arg_idx| try def.captureArg(arg_idx);
    }
    // `no_open_binding` is the sentinel index, so 65,535 captured
    // bindings (valid indices 0...65,534) are representable.
    if (def.var_ref_count < 0 or def.var_ref_count > function_bytecode.no_open_binding) return error.BytecodeOverflow;
    function.open_var_ref_count = @intCast(def.var_ref_count);
    try validateOpenBindingIndices(def, function.open_var_ref_count);

    // Propagate locals count so the VM frame can size its `locals`
    // array; `createFunctionBytecode` copies the same lowered metadata
    // into the final GC-owned function artifact.
    function.flags.is_global_var = def.is_global_var;
    function.entry_contract = .{
        .new_target_allowed = def.new_target_allowed,
        .super_call_allowed = def.super_call_allowed,
        .super_allowed = def.super_allowed,
        .arguments_allowed = def.arguments_allowed,
    };
    if (def.var_count >= 0) {
        function.var_count = @intCast(def.var_count);
    }
    if (def.arg_count >= 0) {
        function.arg_count = @intCast(def.arg_count);
    }

    // Phase 3b: pc2line from remapped Bytecode source slots.
    try encodePc2Line(function);

    // Phase 3c: compute_stack_size over resolved QuickJS-format bytecode,
    // folding the final topology, atom-owner and var-ref proof into the
    // same walk.
    function.stack_size = try computeStackSizeForCurrentBytecode(
        function,
        &function.leaf_returns_balanced,
        .{
            .atom_owners = function.atom_operands,
            .closure_var_count = def.closure_var.len,
        },
    );
}

// Keep the final bytecode verification walk as its own compiler stage.
// Whole-program source deletion otherwise let Zig/LLVM fold this into the
// packed finalizer; the resulting backend-stall regression was the carrier
// behind QCP-1B's crypto/code-load shift. See the decision record §9.3.
noinline fn computeStackSizeForCurrentBytecode(
    function: *bytecode_function.Bytecode,
    leaf_returns_balanced: *bool,
    final_artifact: stack_size.FinalArtifactValidation,
) FinalizeError!u16 {
    // Parser compilation switches MemoryAccount.allocator to the stable,
    // accounted artifact allocator before entering finalization.
    return stack_size.compute(function.code, .{
        .scratch_allocator = function.memory.allocator,
        .returns_balanced_out = leaf_returns_balanced,
        .final_artifact = final_artifact,
    }) catch |err| switch (err) {
        // Reachable falloff is a verifier diagnosis; consumers of the
        // finalize pipeline observe the established invalid-bytecode API.
        error.ReachableFalloff => error.InvalidBytecode,
        error.InvalidFinalArtifact => error.InvalidBytecode,
        else => |other| other,
    };
}

fn encodePc2Line(function: *bytecode_function.Bytecode) !void {
    var encoded = try pc2line.encode(function.memory, function.source_loc_slots, function.line_num, function.col_num);
    defer encoded.deinit();
    // `encode` already produced the exact-sized final owner. Transfer it
    // into the lowered carrier; FunctionBytecode takes the same allocation
    // at commit, so no temporary/copy/shrink path remains.
    function.installPc2Line(encoded.bytes);
    encoded.bytes = &.{};
}

fn installChildFunctionBytecodes(
    fd: *function_def_mod.FunctionDef,
    root_module_record: ?*module.Record,
    compile_context: CompileContext,
    disasm_enabled: bool,
) FinalizeError!void {
    const rt = compile_context.realm.runtime;
    try validateRuntimeIdentity(fd, rt);
    const Frame = struct {
        function_def: *function_def_mod.FunctionDef,
        next_child: usize = 0,
    };

    var frames: std.ArrayList(Frame) = .empty;
    defer {
        // Also revoke every outstanding proof on preparation, allocation
        // or lowering failure. No proof may escape this traversal.
        for (frames.items) |frame| frame.function_def.scope_link_cache = .disabled;
        frames.deinit(fd.memory.allocator);
    }
    try prepareCurrentBeforeChildren(fd, root_module_record);
    try array_list_erased.append(&frames, fd.memory.allocator, .{ .function_def = fd });
    fd.scope_link_cache = .unproven;

    while (frames.items.len != 0) {
        const frame_index = frames.items.len - 1;
        const current = frames.items[frame_index].function_def;
        if (frames.items[frame_index].next_child < current.child_list.len) {
            const child = current.child_list[frames.items[frame_index].next_child];
            frames.items[frame_index].next_child += 1;
            try validateRuntimeIdentity(child, rt);
            const cpool_idx = child.parent_cpool_idx orelse return error.InvalidBytecode;
            if (cpool_idx >= current.cpool.len) return error.InvalidBytecode;
            try prepareCurrentBeforeChildren(child, null);
            try array_list_erased.append(&frames, fd.memory.allocator, .{ .function_def = child });
            child.scope_link_cache = .unproven;
            continue;
        }

        _ = frames.pop();
        current.scope_link_cache = .disabled;
        if (frames.items.len == 0) break;

        const parent = frames.items[frames.items.len - 1].function_def;
        const idx: usize = current.parent_cpool_idx orelse return error.InvalidBytecode;
        const fb_slice = try createFunctionBytecodeAfterChildren(current, compile_context, disasm_enabled);
        const fb = &fb_slice[0];
        const value = JSValue.functionBytecode(&fb.header);
        const old_value = parent.cpool[idx];
        parent.cpool[idx] = value;
        if (!bigint_mod.BigInt.destroyIfReservedValue(rt, old_value)) {}
    }
}

test "scope proof cache is revoked on successful and failed finalization" {
    const rt = try runtime.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const realm = try context.RealmContext.create(rt, .{});
    defer realm.destroy();
    const name = try rt.internAtom("scope-cache-cleanup");
    const Exit = enum { success, prepare_error, lowering_error };
    for ([_]Exit{ .success, .prepare_error, .lowering_error }) |exit_kind| {
        var parent = function_def_mod.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer parent.deinit(rt);
        _ = try parent.appendScope(-1);
        _ = try parent.addScopeVar(name, .normal, 0, .{});
        const input = try rt.memory.create(compiler.Builder);
        input.* = compiler.Builder.init(&rt.memory, &rt.atoms);
        parent.builder = input;
        try input.emitOp(opcode.op.return_undef);

        const child_count: usize = if (exit_kind == .lowering_error) 2 else 1;
        for (0..child_count) |child_index| {
            const child = blk: {
                const def = try rt.memory.create(function_def_mod.FunctionDef);
                errdefer rt.memory.destroy(function_def_mod.FunctionDef, def);
                def.* = function_def_mod.FunctionDef.init(&rt.memory, &rt.atoms, name);
                try parent.addChild(def);
                break :blk def;
            };
            child.parent_cpool_idx = @intCast(try parent.appendCpoolOwned(JSValue.undefinedValue()));
            _ = try child.appendScope(-1);
            if (exit_kind != .prepare_error) {
                const body = try rt.memory.create(compiler.Builder);
                body.* = compiler.Builder.init(&rt.memory, &rt.atoms);
                child.builder = body;
                try body.emitAtomOpU16Owned(opcode.op.scope_get_var, name, 0);
                try body.emitOp(opcode.op.drop);
                try body.emitOp(opcode.op.return_undef);
            }
            // The first child establishes a parent proof. A later child
            // then fails the artifact preflight after its frame is popped.
            if (child_index == 1) child.arg_count = -1;
        }

        const before = function_def_mod.ScopeProofTestCounters.validations;
        if (exit_kind == .success) {
            try installChildFunctionBytecodes(&parent, null, .{ .realm = realm }, false);
        } else {
            try std.testing.expectError(error.InvalidBytecode, installChildFunctionBytecodes(&parent, null, .{ .realm = realm }, false));
        }
        if (exit_kind != .prepare_error) {
            // The child actually reached resolution and proved its parent.
            try std.testing.expect(function_def_mod.ScopeProofTestCounters.validations >= before + 2);
        }
        try std.testing.expectEqual(function_def_mod.ScopeLinkCache.disabled, parent.scope_link_cache);
        for (parent.child_list) |child| {
            try std.testing.expectEqual(function_def_mod.ScopeLinkCache.disabled, child.scope_link_cache);
        }
    }
}
