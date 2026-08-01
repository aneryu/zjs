//! QCP-1 compiler-v2 (`compiler-v2-qjs` branch): the zjs identity-native
//! compiler, using selected QuickJS production mechanisms while replacing the
//! legacy absolute-PC Phase 1/2/3 pipeline wholesale once the final
//! performance gate (code-load >= 0.58 vs pinned qjs) passes.
//!
//! Production shape (target):
//!   compact temporary bytecode (no per-instruction object IR)
//!   + parser-native LabelId / LabelSlot / RelocEntry
//!   + resolve_variables_v2 with exact LabelId block-CFG liveness
//!     (a legacy-style instruction CFG is the Debug/ReleaseSafe proof oracle)
//!   + resolve_labels_v2 + single final emission (short opcodes, jump
//!     threading, pc2line generated directly at output positions)
//!
//! Selection: -Dzjs_compiler=legacy|v2|dual (dual compiles both, compares
//! via compare.zig, executes the v2 product).
//!
//! Correctness contract is NORMALIZED EQUIVALENCE, not byte identity:
//! structural tier (flags/counts/pools/stack size/atom balance), normalized
//! bytecode tier (semantic opcode + target ordinal + resolved operand +
//! atom + source position), execution tier (test262 / force-GC / OOM /
//! altrepr remain final authority).

const bytecode = @import("../bytecode.zig");

pub const labels = @import("labels.zig");
pub const builder = @import("builder.zig");
pub const resolve_variables = @import("resolve_variables.zig");
pub const resolve_labels = @import("resolve_labels.zig");

pub const LabelId = labels.LabelId;
pub const LabelSlot = labels.LabelSlot;
pub const RelocEntry = labels.RelocEntry;
pub const Builder = builder.Builder;
pub const ResolvedProduct = resolve_variables.ResolvedProduct;

/// QCP-1 v2 per-function lowering: resolve_variables_v2 then resolve_labels_v2,
/// installing final executable code/atoms/source slots on `function` (the
/// finalize "lowered" carrier). Tree recursion and the packed FunctionBytecode
/// ABI stay in pipeline_finalize (createFunctionBytecode), which dispatches
/// here for every FunctionDef that carries a v2 builder.
pub fn compileFunctionV2(
    function: *bytecode.Bytecode,
    fd: *bytecode.function_def.FunctionDef,
) resolve_variables.Error!void {
    var product = try resolve_variables.run(function, fd);
    defer product.deinitUncommitted();
    try resolve_labels.run(function, fd, &product);
}

test {
    _ = @import("cfg.zig");
    _ = labels;
    _ = builder;
    _ = resolve_variables;
    _ = resolve_labels;
    _ = compileFunctionV2;
    _ = @import("tests.zig");
}
