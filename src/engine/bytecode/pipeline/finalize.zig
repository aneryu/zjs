//! Finalization: js_create_function equivalent
//!
//! Mirrors `js_create_function` at `quickjs.c:35401`.
//!
//! This walks the child_list of FunctionDefs, runs all pipeline phases,
//! and installs the final FunctionBytecode into the parent's cpool.

const std = @import("std");
const bytecode_function = @import("../function.zig");
const function_def_mod = @import("../function_def.zig");
const resolve_variables = @import("resolve_variables.zig");
const resolve_labels = @import("resolve_labels.zig");
const pc2line = @import("pc2line.zig");
const stack_size = @import("stack_size.zig");
const Value = @import("../../core/value.zig").Value;

/// Context for finalization.
pub const Context = struct {
    // For the interim Bytecode-based implementation, we just need
    // the function to process. The full FunctionDef-based version
    // will include parent/child relationship tracking.
};

/// Create a FunctionBytecode from a FunctionDef.
///
/// This mirrors `js_create_function` at `quickjs.c:35401`. It:
/// 1. Recursively processes child functions (child_list walk)
/// 2. Runs all pipeline phases on the FunctionDef
/// 3. Allocates and populates a FunctionBytecode structure
/// 4. Returns the FunctionBytecode
///
pub fn createFunctionBytecode(fd: *function_def_mod.FunctionDef, rt: anytype) anyerror![]bytecode_function.FunctionBytecode {
    try installChildFunctionBytecodes(fd, rt);

    var lowered = bytecode_function.Bytecode.init(fd.memory, fd.atoms, fd.func_name);
    defer lowered.deinit(rt);
    lowered.opcode_format = .qjs;
    try lowered.setCode(fd.byte_code);
    for (fd.atom_operands) |atom_id| try lowered.retainAtomOperand(atom_id);
    try runPhases(&lowered, fd);

    // Allocate FunctionBytecode as a single-element slice. Caller is
    // responsible for releasing the returned GC object.
    const slice = try fd.memory.alloc(bytecode_function.FunctionBytecode, 1);
    errdefer fd.memory.free(bytecode_function.FunctionBytecode, slice);
    const fb = &slice[0];
    fb.* = bytecode_function.FunctionBytecode.init(fd.memory, fd.atoms, fd.func_name);
    try rt.gc.add(&fb.header);
    fb.header.destroy_fn = bytecode_function.destroyFunctionBytecode;
    fb.header.destroy_ctx = @ptrCast(rt);

    // Copy flags and metadata
    fb.is_strict_mode = fd.is_strict_mode;
    fb.has_prototype = fd.has_prototype;
    fb.has_simple_parameter_list = fd.has_simple_parameter_list;
    fb.is_derived_class_constructor = fd.is_derived_class_constructor;
    fb.need_home_object = fd.need_home_object;
    fb.func_kind = fd.func_kind;
    fb.new_target_allowed = fd.new_target_allowed;
    fb.super_call_allowed = fd.super_call_allowed;
    fb.super_allowed = fd.super_allowed;
    fb.arguments_allowed = fd.arguments_allowed;
    fb.backtrace_barrier = fd.backtrace_barrier;

    // Copy lowered bytecode.
    if (lowered.code.len > 0) {
        fb.byte_code = try fd.memory.alloc(u8, lowered.code.len);
        @memcpy(fb.byte_code, lowered.code);
        fb.byte_code_len = @intCast(lowered.code.len);
    }

    // Copy vardefs
    if (fd.vars.len > 0) {
        fb.vardefs = try fd.memory.alloc(function_def_mod.VarDef, fd.vars.len);
        @memcpy(fb.vardefs, fd.vars);
        // Duplicate atoms
        for (fb.vardefs) |*v| {
            v.var_name = fd.atoms.dup(v.var_name);
        }
    }

    // Copy closure_var
    if (fd.closure_var.len > 0) {
        fb.closure_var = try fd.memory.alloc(function_def_mod.ClosureVar, fd.closure_var.len);
        @memcpy(fb.closure_var, fd.closure_var);
        // Duplicate atoms
        for (fb.closure_var) |*cv| {
            cv.var_name = fd.atoms.dup(cv.var_name);
        }
    }

    // Copy metadata counts
    fb.arg_count = @intCast(fd.arg_count);
    fb.var_count = @intCast(fd.var_count);
    fb.defined_arg_count = @intCast(fd.defined_arg_count);
    fb.var_ref_count = @intCast(fd.var_ref_count);
    fb.closure_var_count = @intCast(fd.closure_var_count);

    // Copy source location
    fb.line_num = fd.line_num;
    fb.col_num = fd.col_num;

    // Copy constants.
    if (fd.cpool.len > 0) {
        fb.cpool = try fd.memory.alloc(Value, fd.cpool.len);
        fb.cpool_count = @intCast(fd.cpool.len);
        for (fd.cpool, 0..) |value, idx| {
            fb.cpool[idx] = value.dup();
        }
    }

    return slice;
}

/// Run all pipeline phases on a Bytecode.
///
/// This simplified version for the interim Bytecode-based implementation:
/// 1. Run Phase 2 (resolve_variables)
/// 2. Run Phase 3a (resolve_labels)
///
/// Phase 3b (pc2line) and Phase 3c (stack_size) are skipped because
/// they work on FunctionDef, not Bytecode.
///
/// The full QuickJS-aligned version will walk parent's child_list,
/// run all phases, allocate FunctionBytecode, and install in cpool.
pub fn run(function: *bytecode_function.Bytecode) !void {
    return runWithFunctionDef(function, null);
}

/// Variant that consumes a `FunctionDef` for local-slot lookup. When
/// `fd` is non-null, `resolve_variables` lowers `scope_get_var` /
/// `scope_put_var` to `get_loc` / `put_loc` for any atom found in
/// `fd.vars`; this also propagates `fd.var_count` onto the produced
/// `Bytecode.var_count` so the VM frame can size its locals array.
/// Also processes child FunctionDefs recursively.
pub fn runWithFunctionDef(
    function: *bytecode_function.Bytecode,
    fd: ?*const function_def_mod.FunctionDef,
) !void {
    try runPhases(function, fd);
}

/// Runtime-aware variant used when the parser produced FunctionDef child
/// entries. It recursively materialises child FunctionBytecode objects and
/// installs them into the executable Bytecode constant pool so `fclosure*`
/// operands have real callees.
pub fn runWithFunctionDefRuntime(
    function: *bytecode_function.Bytecode,
    fd: ?*function_def_mod.FunctionDef,
    rt: anytype,
) !void {
    if (fd) |def| {
        try installChildFunctionBytecodes(def, rt);
        try syncFunctionDefCpool(function, def);
    }
    try runPhases(function, fd);
}

fn runPhases(
    function: *bytecode_function.Bytecode,
    fd: ?*const function_def_mod.FunctionDef,
) !void {
    // Phase 2: resolve_variables (with optional FunctionDef).
    var resolve_ctx = if (fd) |def|
        resolve_variables.Context.initWithFunctionDef(function, def)
    else
        resolve_variables.Context.init(function);
    try resolve_variables.run(&resolve_ctx);

    // Phase 3a: resolve_labels (with optional FunctionDef prologue metadata).
    var labels_ctx = if (fd) |def|
        resolve_labels.Context.initWithFunctionDef(function, def)
    else
        resolve_labels.Context.init(function);
    try resolve_labels.run(&labels_ctx);

    // Propagate locals count so the VM frame can size its `locals`
    // array. This is the simplest viable wire-up; the full §F10.5
    // `js_create_function` will populate the rich FunctionBytecode
    // header (arg_count, defined_arg_count, stack_size, ...).
    if (fd) |def| {
        if (def.var_count >= 0) {
            function.var_count = @intCast(def.var_count);
        }
        if (def.arg_count >= 0) {
            function.arg_count = @intCast(def.arg_count);
        }

    }

    // Phase 3b (pc2line) and Phase 3c (stack_size) are skipped
    // because they require FunctionDef structure.
    // They will be added when FunctionDef is integrated.
}

fn installChildFunctionBytecodes(fd: *function_def_mod.FunctionDef, rt: anytype) anyerror!void {
    for (fd.child_list) |*child| {
        const cpool_idx = child.parent_cpool_idx;
        if (cpool_idx < 0 or @as(usize, @intCast(cpool_idx)) >= fd.cpool.len) {
            return error.InvalidBytecode;
        }
        const fb_slice = try createFunctionBytecode(child, rt);
        const fb = &fb_slice[0];
        const value = Value.functionBytecode(&fb.header);
        const idx: usize = @intCast(cpool_idx);
        fd.cpool[idx].free(rt);
        fd.cpool[idx] = value;
    }
}

fn syncFunctionDefCpool(function: *bytecode_function.Bytecode, fd: *const function_def_mod.FunctionDef) !void {
    if (fd.cpool.len == 0) return;
    if (function.constants.values.len != 0) return error.InvalidBytecode;
    for (fd.cpool) |value| {
        _ = try function.addConstant(value);
    }
}
