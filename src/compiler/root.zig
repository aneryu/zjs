//! The compiler: compact temporary bytecode, parser-native LabelId /
//! LabelSlot / RelocEntry, resolve_variables with exact LabelId block-CFG
//! liveness, then resolve_labels with a layout-selectable final emission.
//!
//! Final layout: -Dzjs_compiler_layout=short (default) | plain (A/B
//! diagnostic).
//!
//! Correctness rests on the compiler's own invariants — CFG identity
//! oracles, boundary uniqueness, the atom-ownership audit and the escape
//! assertions — plus execution (test262 / force-GC / OOM).

const std = @import("std");
const bytecode = @import("../bytecode.zig");

pub const cfg = @import("cfg.zig");
pub const test_entry = @import("test_entry.zig");
pub const labels = @import("labels.zig");
pub const builder = @import("builder.zig");
pub const resolve_variables = @import("resolve_variables.zig");
pub const resolve_labels = @import("resolve_labels.zig");

pub const LabelId = labels.LabelId;
pub const LabelSlot = labels.LabelSlot;
pub const RelocEntry = labels.RelocEntry;
pub const Builder = builder.Builder;
pub const ResolvedProduct = resolve_variables.ResolvedProduct;
pub const DiffBucket = cfg.DiffBucket;
pub const oracle_report_enabled = cfg.audit_oracles;

/// Scratch-only: format the corpus-level oracle report. Returns an empty
/// slice when the counters are comptime-erased (ReleaseFast).
pub fn formatOracleReport(buffer: []u8) []const u8 {
    if (comptime !cfg.audit_oracles) return "";
    return cfg.formatOracleReport(buffer, cfg.oracleReportSnapshot());
}

/// Per-function lowering: resolve_variables then resolve_labels, installing
/// final executable code/atoms/source slots on `function` (the finalize
/// "lowered" carrier). Tree recursion and the packed FunctionBytecode ABI
/// stay in pipeline_finalize (createFunctionBytecode), which dispatches here
/// for every FunctionDef that carries a builder.
pub fn compileFunction(
    function: *bytecode.Bytecode,
    fd: *bytecode.function_def.FunctionDef,
) resolve_variables.Error!void {
    return compileFunctionImpl(false, function, fd);
}

/// Packed FunctionBytecode finalization variant.  The outer finalize choke
/// point performs the final code/atom/var-ref proof in one fused traversal
/// before publishing the artifact; direct callers use `compileFunction` and
/// retain resolve_labels' self-contained output validation.
///
/// This is an architectural phase boundary, not a speculative inline hint.
/// Removing unrelated legacy state changed Zig/LLVM whole-program inlining and
/// folded lowering into the packed finalizer, regressing crypto/code-load.
/// Keep the boundary explicit; see docs/qcp1_switch_decision.md §9.3.
pub noinline fn compileFunctionForPackedFinalize(
    function: *bytecode.Bytecode,
    fd: *bytecode.function_def.FunctionDef,
) resolve_variables.Error!void {
    return compileFunctionImpl(true, function, fd);
}

fn compileFunctionImpl(
    comptime packed_finalize_validates_code: bool,
    function: *bytecode.Bytecode,
    fd: *bytecode.function_def.FunctionDef,
) resolve_variables.Error!void {
    var product = try resolve_variables.run(function, fd);
    defer product.deinitUncommitted();
    releaseConsumedBuilder(fd);
    if (comptime packed_finalize_validates_code) {
        try resolve_labels.runForPackedFinalize(resolve_labels.default_layout, function, fd, &product);
    } else {
        try resolve_labels.run(resolve_labels.default_layout, function, fd, &product);
    }

    if (comptime cfg.audit_oracles) {
        emitIdentityHealth();
        emitAnchorSplit();
    }
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
    fd.memory.destroy(Builder, consumed);
}

fn emitIdentityHealth() void {
    if (std.c.getenv("ZJS_V2_IDENTITY_HEALTH") == null) return;
    var buffer: [512]u8 = undefined;
    const health = cfg.formatIdentityHealth(&buffer, cfg.fanoutCensusSnapshot());
    std.debug.print("{s}\n", .{health});
}

/// F3 anchor-split classification report. `ZJS_V2_ANCHOR_SPLIT` prints the
/// cumulative class totals after every function (take the last line);
/// `ZJS_V2_ANCHOR_EXEMPLARS` additionally prints each retained exemplar ONCE,
/// at the compile that first captured it, so the whole run emits at most
/// `cfg.anchor_exemplar_capacity` exemplar lines.
var reported_anchor_exemplars: u32 = 0;

fn emitAnchorSplit() void {
    if (std.c.getenv("ZJS_V2_ANCHOR_EXEMPLARS") != null) {
        while (reported_anchor_exemplars < cfg.anchor_exemplar_len) {
            var line_buffer: [512]u8 = undefined;
            const exemplar = cfg.anchor_exemplars[reported_anchor_exemplars];
            reported_anchor_exemplars += 1;
            std.debug.print("{s}\n", .{cfg.formatAnchorExemplar(&line_buffer, exemplar)});
        }
    }
    if (std.c.getenv("ZJS_V2_ANCHOR_SPLIT") == null) return;
    var buffer: [1024]u8 = undefined;
    std.debug.print("{s}\n", .{cfg.formatAnchorSplit(&buffer, cfg.anchorSplitSnapshot())});
}

test {
    _ = @import("cfg.zig");
    _ = labels;
    _ = builder;
    _ = resolve_variables;
    _ = resolve_labels;
    _ = compileFunction;
    _ = @import("tests.zig");
}
