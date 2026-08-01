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

pub const LabelId = labels.LabelId;
pub const LabelSlot = labels.LabelSlot;
pub const RelocEntry = labels.RelocEntry;
pub const Builder = builder.Builder;
pub const ResolvedProduct = resolve_variables.ResolvedProduct;

/// QCP-1 v2 pipeline entry: resolve_variables_v2 now; resolve_labels_v2 lands
/// next stage, so its Stage 4 stub returns the resolved product unchanged.
pub fn compileFunctionV2(
    function: *bytecode.Bytecode,
    fd: *bytecode.function_def.FunctionDef,
) resolve_variables.Error!ResolvedProduct {
    var product = try resolve_variables.run(function, fd);
    resolveLabelsV2Stub(&product);
    return product;
}

/// QCP-1 Stage 4 placeholder. Label relocation and short-op emission will be
/// installed here without changing the Stage 3 product ownership boundary.
fn resolveLabelsV2Stub(product: *ResolvedProduct) void {
    _ = product;
}

test {
    _ = @import("cfg.zig");
    _ = labels;
    _ = builder;
    _ = resolve_variables;
    _ = compileFunctionV2;
    _ = @import("tests.zig");
}
