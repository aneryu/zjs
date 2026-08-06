//! QCP-1 compiler-v2 (`compiler-v2-qjs` branch): the zjs identity-native
//! compiler, using selected QuickJS production mechanisms in place of the
//! legacy absolute-PC Phase 1/2/3 pipeline. The switch ruling made
//! `v2` + `short` the production default; the absolute `code-load >= 0.58`
//! bar it once waited on is SUPERSEDED (docs/qcp1_switch_decision.md §0).
//!
//! Production shape (target):
//!   compact temporary bytecode (no per-instruction object IR)
//!   + parser-native LabelId / LabelSlot / RelocEntry
//!   + resolve_variables_v2 with exact LabelId block-CFG liveness
//!     (a legacy-style instruction CFG is the Debug/ReleaseSafe proof oracle)
//!   + resolve_labels_v2 + single layout-selectable final emission (jump
//!     threading, pc2line generated directly at output positions)
//!
//! Selection: -Dzjs_compiler=v2 (default) |legacy|dual (dual compiles both,
//! compares via compare.zig, executes the v2 product). Final layout:
//! -Dzjs_v2_layout=short (default) |plain (A/B diagnostic instrument).
//! Both are named in the build's configuration signature; see
//! src/config_signature.zig and `zig build config-signature-check`.
//!
//! Correctness contract is NORMALIZED EQUIVALENCE, not byte identity:
//! structural tier (flags/counts/pools/stack size/atom balance), normalized
//! bytecode tier (semantic opcode + target ordinal + resolved operand +
//! atom + source position), execution tier (test262 / force-GC / OOM /
//! altrepr remain final authority).

const std = @import("std");
const bytecode = @import("../bytecode.zig");

pub const cfg = @import("cfg.zig");
pub const coverage = @import("coverage.zig");
pub const test_entry = @import("test_entry.zig");
pub const labels = @import("labels.zig");
pub const builder = @import("builder.zig");
pub const resolve_variables = @import("resolve_variables.zig");
pub const resolve_labels = @import("resolve_labels.zig");
pub const compare = @import("compare.zig");

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

/// QCP-1 v2 per-function lowering: resolve_variables_v2 then resolve_labels_v2,
/// installing final executable code/atoms/source slots on `function` (the
/// finalize "lowered" carrier). Tree recursion and the packed FunctionBytecode
/// ABI stay in pipeline_finalize (createFunctionBytecode), which dispatches
/// here for every FunctionDef that carries a v2 builder.
pub fn compileFunctionV2(
    function: *bytecode.Bytecode,
    fd: *bytecode.function_def.FunctionDef,
    ledger: ?*compare.Ledger,
) resolve_variables.Error!void {
    return compileFunctionV2Impl(false, function, fd, ledger);
}

/// Packed FunctionBytecode finalization variant.  The outer finalize choke
/// point performs the final code/atom/var-ref proof in one fused traversal
/// before publishing the artifact; direct callers use `compileFunctionV2` and
/// retain resolve_labels' self-contained output validation.
pub fn compileFunctionV2ForPackedFinalize(
    function: *bytecode.Bytecode,
    fd: *bytecode.function_def.FunctionDef,
    ledger: ?*compare.Ledger,
) resolve_variables.Error!void {
    return compileFunctionV2Impl(true, function, fd, ledger);
}

fn compileFunctionV2Impl(
    comptime packed_finalize_validates_code: bool,
    function: *bytecode.Bytecode,
    fd: *bytecode.function_def.FunctionDef,
    ledger: ?*compare.Ledger,
) resolve_variables.Error!void {
    var product = try resolve_variables.run(function, fd);
    defer product.deinitUncommitted();
    var input_labels_unbound: usize = 0;
    var input_source_markers: usize = 0;
    if (ledger != null) {
        const input = fd.v2_builder orelse return error.InvalidBytecode;
        for (input.label_slots[0..input.label_len]) |slot|
            input_labels_unbound += @intFromBool(!slot.flags.bound);
        input_source_markers = input.source_len;
    }
    releaseConsumedBuilder(fd);
    // Only dual compilation pays for the diagnostic walks. Ordinary v2 mode
    // passes null and performs exactly the S3 -> S4 pipeline work.
    const live_relocs = if (ledger != null) try countLiveRelocs(&product) else 0;
    if (comptime packed_finalize_validates_code) {
        try resolve_labels.runForPackedFinalize(resolve_labels.default_layout, function, fd, &product);
    } else {
        try resolve_labels.run(resolve_labels.default_layout, function, fd, &product);
    }
    if (ledger) |out| {
        try addLedger(&out.functions_lowered, 1);
        try addLedger(&out.labels_created, product.label_len);
        try addLedger(&out.labels_unbound, input_labels_unbound);
        // The S3 product is the first relocation ledger after exact-CFG dead
        // stripping. Counting its label-bearing instructions therefore counts
        // the exact live subset; S4 must consume every one before returning.
        try addLedger(&out.relocs_created, live_relocs);
        try addLedger(&out.relocs_applied, live_relocs);
        try addLedger(&out.source_markers, input_source_markers);
        try addLedger(&out.source_events_emitted, countEncodedSourceEvents(function));
        try addLedger(&out.closure_sources_threaded, fd.closure_var.len);
    }

    if (comptime cfg.audit_oracles) {
        emitIdentityHealth();
        emitAnchorSplit();
    }
}

/// RELEASE AT THE CONSUMPTION POINT. `resolve_variables.run` is the last
/// reader of the compact stream (dual's ledger scalars are taken above, at
/// the same instant), so the producer becomes inert here: its slice fields
/// reset to empty, capacity 0, backings freed, and the FunctionDef no longer
/// names it. `FunctionDef.deinit` stays as the parse-time / error-path
/// backstop only. This lives with the CONSUMER, so it moves with the
/// consumer when builder ownership relocates into a `V2Emitter`.
fn releaseConsumedBuilder(fd: *bytecode.function_def.FunctionDef) void {
    const consumed = fd.v2_builder orelse return;
    fd.v2_builder = null;
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

fn countEncodedSourceEvents(function: *const bytecode.Bytecode) usize {
    var count: usize = 0;
    var last_pc: u32 = 0;
    var last_line = function.line_num;
    var last_col = function.col_num;
    for (function.source_loc_slots) |slot| {
        if (slot.line_num < 0 or slot.pc < last_pc) continue;
        if (slot.line_num == last_line and slot.col_num == last_col) continue;
        count +|= 1;
        last_pc = slot.pc;
        last_line = slot.line_num;
        last_col = slot.col_num;
    }
    return count;
}

fn addLedger(slot: *usize, amount: anytype) resolve_variables.Error!void {
    slot.* = std.math.add(usize, slot.*, @intCast(amount)) catch
        return error.BytecodeOverflow;
}

fn countLiveRelocs(product: *const resolve_variables.ResolvedProduct) resolve_variables.Error!usize {
    var count: usize = 0;
    var pc: usize = 0;
    const code = product.code[0..product.code_len];
    while (pc < code.len) {
        const op_id = code[pc];
        const size: usize = bytecode.opcode.sizeOf(op_id);
        if (size == 0 or size > code.len - pc) return error.InvalidBytecode;
        switch (bytecode.opcode.formatOf(op_id)) {
            .label, .label8, .label16, .label_u16, .atom_label_u8, .atom_label_u16 => count = std.math.add(usize, count, 1) catch return error.BytecodeOverflow,
            else => {},
        }
        pc += size;
    }
    return count;
}

test {
    _ = @import("cfg.zig");
    _ = labels;
    _ = builder;
    _ = resolve_variables;
    _ = resolve_labels;
    _ = compare;
    _ = compileFunctionV2;
    _ = @import("compare.zig");
    _ = @import("tests.zig");
}
