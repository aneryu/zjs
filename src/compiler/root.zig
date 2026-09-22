//! The compiler: compact temporary bytecode, parser-native LabelId /
//! LabelSlot / RelocEntry, resolve_variables with qjs label bookkeeping, then
//! resolve_labels with a layout-selectable final emission.
//!
//! Final layout: -Dzjs_compiler_layout=short (default) | plain (A/B
//! diagnostic).

const std = @import("std");
const bytecode = @import("../bytecode.zig");

pub const test_entry = @import("test_entry.zig");
pub const labels = @import("labels.zig");
pub const builder = @import("builder.zig");
pub const temp_stream = @import("temp_stream.zig");
pub const resolve_variables = @import("resolve_variables.zig");
pub const resolve_labels = @import("resolve_labels.zig");

pub const LabelId = labels.LabelId;
pub const LabelSlot = labels.LabelSlot;
pub const RelocEntry = labels.RelocEntry;
pub const Builder = builder.Builder;
pub const ResolvedProduct = resolve_variables.ResolvedProduct;

/// Per-function lowering: resolve_variables then resolve_labels, installing
/// final executable code/atoms/source slots on `function` (the finalize
/// "lowered" carrier). Tree recursion and the packed FunctionBytecode ABI
/// stay in pipeline_finalize (createFunctionBytecode), which dispatches here
/// for every FunctionDef that carries a builder.
/// Packed FunctionBytecode finalization: the outer finalize choke point
/// performs the final code/atom/var-ref proof in one fused traversal before
/// publishing the artifact.
///
/// This is an architectural phase boundary, not a speculative inline hint.
/// Removing unrelated legacy state changed Zig/LLVM whole-program inlining and
/// folded lowering into the packed finalizer, regressing crypto/code-load.
/// Keep the boundary explicit; see docs/qcp1_switch_decision.md §9.3.
pub noinline fn compileFunction(
    function: *bytecode.Bytecode,
    fd: *bytecode.function_def.FunctionDef,
) resolve_variables.Error!void {
    var product = try resolve_variables.run(function, fd);
    defer product.deinitUncommitted();
    releaseConsumedBuilder(fd);
    try resolve_labels.run(resolve_labels.default_layout, function, fd, &product);
}

/// RELEASE AT THE CONSUMPTION POINT. `resolve_variables.run` is the last
/// reader of the compact stream, so the producer becomes inert here: its
/// slice fields reset to empty, capacity 0, backings freed, and the
/// FunctionDef no longer names it. `FunctionDef.deinit` stays as the
/// parse-time / error-path backstop only. This lives with the consumer.
fn releaseConsumedBuilder(fd: *bytecode.function_def.FunctionDef) void {
    const consumed = fd.builder orelse return;
    fd.builder = null;
    consumed.deinit();
    std.debug.assert(consumed.code_capacity == 0 and consumed.atom_capacity == 0 and
        consumed.label_capacity == 0 and consumed.reloc_capacity == 0 and
        consumed.source_capacity == 0);
    fd.allocator.destroy(consumed);
}

test {
    _ = labels;
    _ = builder;
    _ = temp_stream;
    _ = resolve_variables;
    _ = resolve_labels;
    _ = compileFunction;
}
