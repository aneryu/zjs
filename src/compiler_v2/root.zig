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

const std = @import("std");
const bytecode = @import("../bytecode.zig");

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
    const input = fd.v2_builder orelse return error.InvalidBytecode;
    var product = try resolve_variables.run(function, fd);
    defer product.deinitUncommitted();
    // Only dual compilation pays for the diagnostic walks. Ordinary v2 mode
    // passes null and performs exactly the S3 -> S4 pipeline work.
    const live_relocs = if (ledger != null) try countLiveRelocs(&product) else 0;
    try resolve_labels.run(function, fd, &product);

    if (ledger) |out| {
        try addLedger(&out.functions_lowered, 1);
        try addLedger(&out.labels_created, product.label_len);
        var unbound: usize = 0;
        for (input.label_slots[0..input.label_len]) |slot|
            unbound += @intFromBool(!slot.flags.bound);
        try addLedger(&out.labels_unbound, unbound);
        // The S3 product is the first relocation ledger after exact-CFG dead
        // stripping. Counting its label-bearing instructions therefore counts
        // the exact live subset; S4 must consume every one before returning.
        try addLedger(&out.relocs_created, live_relocs);
        try addLedger(&out.relocs_applied, live_relocs);
        try addLedger(&out.source_markers, input.source_len);
        try addLedger(&out.source_events_emitted, countEncodedSourceEvents(function));
        try addLedger(&out.closure_sources_threaded, fd.closure_var.len);
    }
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
