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
/// The caller is responsible for storing the FunctionBytecode in
/// the parent's cpool and for deinit when done.
///
/// Note: This is a simplified version that doesn't yet create proper
/// Function objects for children in the cpool. That requires additional
/// infrastructure (Function object wrappers, GC integration, etc.).
pub fn createFunctionBytecode(fd: *function_def_mod.FunctionDef, rt: anytype) !*bytecode_function.FunctionBytecode {
    // First, recursively process all child functions
    // This mirrors quickjs.c:35452-35464
    for (fd.child_list) |*child_fd| {
        // Recursively create FunctionBytecode for child
        const child_fb = try createFunctionBytecode(child_fd, rt);

        // Store in parent's cpool at the child's parent_cpool_idx
        const cpool_idx = child_fd.parent_cpool_idx;
        if (cpool_idx >= 0 and cpool_idx < fd.cpool_count) {
            // Wrap FunctionBytecode pointer in Value
            // TODO: Use proper Function object wrapper when GC integration is complete
            fd.cpool[@intCast(cpool_idx)] = Value.functionBytecode(@ptrCast(child_fb));
        }
    }

    // Create a temporary Bytecode for pipeline processing
    // We'll copy the byte_code from FunctionDef to Bytecode
    var temp_bc = bytecode_function.Bytecode.init(fd.memory, fd.atoms, fd.func_name);
    defer temp_bc.deinit(rt);

    // Copy byte_code from FunctionDef to Bytecode
    if (fd.byte_code.len > 0) {
        try temp_bc.setCode(fd.byte_code);
    }

    // Copy cpool from FunctionDef to Bytecode (for now, just copy as-is)
    if (fd.cpool_count > 0) {
        for (fd.cpool) |v| {
            _ = try temp_bc.addConstant(v);
        }
    }

    // Run pipeline phases
    // Phase 2: resolve_variables
    var resolve_ctx = resolve_variables.Context.initWithFunctionDef(&temp_bc, fd);
    try resolve_variables.run(&resolve_ctx);

    // Phase 3a: resolve_labels
    var labels_ctx = resolve_labels.Context.init(&temp_bc);
    try resolve_labels.run(&labels_ctx);

    // Phase 3b: pc2line (skip for now - requires source location data)
    // Phase 3c: stack_size (skip for now - requires FunctionDef structure)

    // Allocate FunctionBytecode
    const fb = try fd.memory.alloc(bytecode_function.FunctionBytecode, 1);
    errdefer fd.memory.free(bytecode_function.FunctionBytecode, fb);
    fb[0] = bytecode_function.FunctionBytecode.init(fd.memory, fd.atoms, fd.func_name);

    // Copy metadata from FunctionDef
    fb[0].is_strict_mode = fd.is_strict_mode;
    fb[0].has_prototype = fd.has_prototype;
    fb[0].has_simple_parameter_list = fd.has_simple_parameter_list;
    fb[0].is_derived_class_constructor = fd.is_derived_class_constructor;
    fb[0].need_home_object = fd.need_home_object or (fd.home_object_var_idx >= 0);
    fb[0].func_kind = fd.func_kind;
    fb[0].new_target_allowed = fd.new_target_allowed;
    fb[0].super_call_allowed = fd.super_call_allowed;
    fb[0].super_allowed = fd.super_allowed;
    fb[0].arguments_allowed = fd.arguments_allowed;
    fb[0].backtrace_barrier = fd.backtrace_barrier;

    // Copy byte_code (from temporary Bytecode after pipeline processing)
    if (temp_bc.code.len > 0) {
        const owned = try fd.memory.alloc(u8, temp_bc.code.len);
        errdefer fd.memory.free(u8, owned);
        @memcpy(owned, temp_bc.code);
        fb[0].byte_code = owned;
    }

    // Copy metadata
    fb[0].arg_count = @intCast(fd.arg_count);
    fb[0].var_count = @intCast(fd.var_count);
    fb[0].defined_arg_count = @intCast(fd.defined_arg_count);
    fb[0].var_ref_count = @intCast(fd.var_ref_count);

    // Copy vardefs (args + vars)
    const total_vardefs = fd.arg_count + fd.var_count;
    if (total_vardefs > 0) {
        const owned = try fd.memory.alloc(function_def_mod.VarDef, @intCast(total_vardefs));
        errdefer fd.memory.free(function_def_mod.VarDef, owned);
        @memcpy(owned[0..@intCast(fd.arg_count)], fd.args);
        @memcpy(owned[@intCast(fd.arg_count)..], fd.vars);
        // Duplicate atoms
        for (owned, 0..) |*v, i| {
            owned[i].var_name = fd.atoms.dup(v.var_name);
        }
        fb[0].vardefs = owned;
    }

    // Copy closure_var
    if (fd.closure_var_count > 0) {
        const owned = try fd.memory.alloc(function_def_mod.ClosureVar, @intCast(fd.closure_var_count));
        errdefer fd.memory.free(function_def_mod.ClosureVar, owned);
        @memcpy(owned, fd.closure_var);
        // Duplicate atoms
        for (owned, 0..) |*cv, i| {
            owned[i].var_name = fd.atoms.dup(cv.var_name);
        }
        fb[0].closure_var = owned;
        fb[0].closure_var_count = @intCast(fd.closure_var_count);
    }

    // Copy cpool (now contains child Function objects as wrapped Values)
    if (fd.cpool_count > 0) {
        const owned = try fd.memory.alloc(Value, @intCast(fd.cpool_count));
        errdefer fd.memory.free(Value, owned);
        @memcpy(owned, fd.cpool);
        // Values are already wrapped (including child FunctionBytecode pointers)
        // TODO: Proper ref counting when GC integration is complete
        fb[0].cpool = owned;
        fb[0].cpool_count = fd.cpool_count;
    }

    // Copy source location
    fb[0].line_num = fd.line_num;
    fb[0].col_num = fd.col_num;

    // pc2line and source are skipped for now

    return &fb[0];
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
    // Phase 2: resolve_variables (with optional FunctionDef).
    var resolve_ctx = if (fd) |def|
        resolve_variables.Context.initWithFunctionDef(function, def)
    else
        resolve_variables.Context.init(function);
    try resolve_variables.run(&resolve_ctx);

    // Phase 3a: resolve_labels
    var labels_ctx = resolve_labels.Context.init(function);
    try resolve_labels.run(&labels_ctx);

    // Propagate locals count so the VM frame can size its `locals`
    // array. This is the simplest viable wire-up; the full §F10.5
    // `js_create_function` will populate the rich FunctionBytecode
    // header (arg_count, defined_arg_count, stack_size, ...).
    if (fd) |def| {
        if (def.var_count >= 0) {
            function.var_count = @intCast(def.var_count);
        }

        // Process child FunctionDefs recursively
        // This mirrors QuickJS js_create_function's child_list walk
        // at quickjs.c:35452-35464
        if (def.child_list.len > 0) {
            // Create FunctionBytecode for each child and store in cpool
            // Note: This requires a runtime context for Value operations
            // For now, we skip this in the Bytecode-based path
            // The full FunctionDef-based path will use createFunctionBytecode
        }
    }

    // Phase 3b (pc2line) and Phase 3c (stack_size) are skipped
    // because they require FunctionDef structure.
    // They will be added when FunctionDef is integrated.
}