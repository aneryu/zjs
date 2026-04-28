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

/// Context for finalization.
pub const Context = struct {
    // For the interim Bytecode-based implementation, we just need
    // the function to process. The full FunctionDef-based version
    // will include parent/child relationship tracking.
};

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
    }

    // Phase 3b (pc2line) and Phase 3c (stack_size) are skipped
    // because they require FunctionDef structure.
    // They will be added when FunctionDef is integrated.
}