//! Bytecode: the stable import surface (`@import("bytecode.zig")`) over the
//! ISA table (`bytecode/opcode.zig`), the compile-time carriers
//! (`bytecode/function_def.zig`, `bytecode/carrier.zig`, `bytecode/module.zig`),
//! the GC-managed `FunctionBytecode` the VM runs
//! (`bytecode/function_bytecode.zig`), the finalize pipeline
//! (`compiler/binding_rules.zig`, `compiler/stack_size.zig`,
//! `compiler/finalize.zig`, `bytecode/pc2line.zig`) and the disassembler
//! (`bytecode/dump.zig`). The compile policy/context types live here.

pub const subsystem_name = "bytecode";

const std = @import("std");
const context = @import("core/context.zig");

pub const Bytecode = carrier.Bytecode;
pub const FunctionBytecode = function_bytecode.FunctionBytecode;
pub const FunctionLayout = function_bytecode.FunctionLayout;
pub const PropSiteCache = function_bytecode.PropSiteCache;
pub const CallFacts = function_bytecode.CallFacts;
pub const FunctionDef = function_def.FunctionDef;

pub const pipeline = struct {
    pub const pc2line = @import("bytecode/pc2line.zig");
    pub const stack_size = @import("compiler/stack_size.zig");
    pub const finalize = @import("compiler/finalize.zig");
};

/// Instruction catalog: physical ids (`op`) and the two views of the
/// 178..196 overlap (temp vs short). Use `sizeOf` / `sizeOfPhase1`;
/// never index `opcode_info` with a raw id.
pub const opcode = @import("bytecode/opcode.zig");

pub const module = @import("bytecode/module.zig");

/// Grammar facts fixed when bytecode is entered and inherited by a direct
/// eval. Variable-environment, `arguments`, and `this` binding identity is
/// deliberately absent: canonical roots are real function objects, and final
/// vardef/closure topology is the sole authority for those bindings.
///
/// The four `*_allowed` bits mirror JSFunctionBytecode exactly.
pub const EntryContract = packed struct(u8) {
    new_target_allowed: bool = false,
    super_call_allowed: bool = false,
    super_allowed: bool = false,
    arguments_allowed: bool = false,
    _reserved: u4 = 0,

    comptime {
        if (@sizeOf(@This()) != 1) @compileError("EntryContract must remain one byte");
    }
};

/// Immutable semantic policy shared by one root compilation and every child
/// FunctionDef finalized beneath it.
pub const CompilePolicy = struct {
    runtime_strict: bool = false,
};

/// Optional compile-phase diagnostics. This state is owned by the caller and
/// remains on its stack; neither parser nor published bytecode retains it.
pub const CompileTiming = struct {
    frontend_ns: u64 = 0,
    finalize_ns: u64 = 0,
};

/// Production compilation authority. The borrowed realm is retained once by
/// every FunctionBytecode at publication, matching QuickJS's
/// `b->realm = JS_DupContext(ctx)` for both roots and recursively-finalized
/// children. The context itself is non-owning; published artifacts own their
/// independent `RealmRef`s.
pub const CompileContext = struct {
    realm: *context.RealmContext,
    policy: CompilePolicy = .{},
    timing: ?*CompileTiming = null,

    pub inline fn artifactAllocator(self: CompileContext) std.mem.Allocator {
        return self.realm.runtime.memory.persistent_allocator;
    }
};

pub const function_bytecode = @import("bytecode/function_bytecode.zig");

pub const function_def = @import("bytecode/function_def.zig");

pub const binding_rules = @import("compiler/binding_rules.zig");

pub const carrier = @import("bytecode/carrier.zig");

pub const dump = @import("bytecode/dump.zig");

// Historical sparse representations are retained only for equivalence tests.
// Production decoding uses the direct authoritative tables above.
const SparseDecodeTestOracle = struct {
    const logical = opcode.logical;
    const OperandLayout = opcode.decode.OperandLayout;
    const layout_table = opcode.decode.layout_table;
    const layout_table_len = opcode.decode.layout_table_len;

    const no_layout = std.math.maxInt(u16);

    fn layoutsEqual(a: OperandLayout, b: OperandLayout) bool {
        if (a.len != b.len or a.atom_slot != b.atom_slot or a.var_ref_slot != b.var_ref_slot) return false;
        // Unused slots are undefined; compare only the initialized prefix.
        for (a.slots[0..a.len], 0..) |slot, i| {
            if (!std.meta.eql(slot, b.slots[i])) return false;
        }
        return true;
    }

    // Keep the original table as the compile-time authority, but store
    // each distinct runtime layout once. Layouts remain immutable.
    const runtime_layouts = blk: {
        @setEvalBranchQuota(2000000);
        var rows: [layout_table_len]OperandLayout = undefined;
        var count: usize = 0;
        var indices = [_]u16{no_layout} ** layout_table_len;
        for (layout_table, 0..) |optional, form| {
            const layout = optional orelse continue;
            var index: usize = 0;
            while (index < count and !layoutsEqual(layout, rows[index])) : (index += 1) {}
            if (index == count) {
                if (count == no_layout) @compileError("too many operand layouts");
                rows[count] = layout;
                count += 1;
            }
            indices[form] = @intCast(index);
        }
        const Pool = struct { rows: [count]OperandLayout, indices: [layout_table_len]u16 };
        break :blk Pool{ .rows = rows[0..count].*, .indices = indices };
    };

    fn layoutOf(form: logical.LogicalOpcode) *const OperandLayout {
        const index = runtime_layouts.indices[@intFromEnum(form)];
        std.debug.assert(index != no_layout);
        return &runtime_layouts.rows[index];
    }

    const no_dynamic_shape = std.math.maxInt(u8);
    const dynamic_shape_indices = blk: {
        if (logical.dynamic_stack.len >= no_dynamic_shape) @compileError("too many dynamic stack shapes");
        var indices = [_]u8{no_dynamic_shape} ** 512;
        for (logical.dynamic_stack, 0..) |d, i| indices[@intFromEnum(d.form)] = @intCast(i);
        break :blk indices;
    };

    fn dynamicShape(form: logical.LogicalOpcode) ?logical.DynamicStack.Shape {
        const index = dynamic_shape_indices[@intFromEnum(form)];
        if (index == no_dynamic_shape) return null;
        return logical.dynamic_stack[index].shape;
    }
};

test "operand layout pool preserves every declared layout and absent row" {
    const D = opcode.decode;
    for (D.layout_table, 0..) |optional, id| {
        if (optional) |expected| {
            for ([_]*const D.OperandLayout{
                D.layoutOf(@enumFromInt(id)),
                SparseDecodeTestOracle.layoutOf(@enumFromInt(id)),
            }) |actual| {
                try std.testing.expectEqual(expected.len, actual.len);
                try std.testing.expectEqual(expected.atom_slot, actual.atom_slot);
                try std.testing.expectEqual(expected.var_ref_slot, actual.var_ref_slot);
                for (expected.slots[0..expected.len], 0..) |slot, i| {
                    try std.testing.expectEqualDeep(slot, actual.slots[i]);
                }
            }
        } else {
            try std.testing.expectEqual(SparseDecodeTestOracle.no_layout, SparseDecodeTestOracle.runtime_layouts.indices[id]);
        }
    }
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(D.Header));
}

test "dynamic shape index preserves all declared effects and absent forms" {
    const D = opcode.decode;
    for (D.dynamic_by_form, 0..) |expected, id| {
        const index = SparseDecodeTestOracle.dynamic_shape_indices[id];
        if (expected) |shape| {
            try std.testing.expect(index != SparseDecodeTestOracle.no_dynamic_shape);
            try std.testing.expectEqualDeep(shape, opcode.logical.dynamic_stack[index].shape);
        } else {
            try std.testing.expectEqual(SparseDecodeTestOracle.no_dynamic_shape, index);
        }
    }
    for (std.enums.values(opcode.logical.LogicalOpcode)) |form| {
        try std.testing.expectEqualDeep(D.dynamic_by_form[@intFromEnum(form)], D.dynamicShape(form));
        try std.testing.expectEqualDeep(D.dynamic_by_form[@intFromEnum(form)], SparseDecodeTestOracle.dynamicShape(form));
    }
}

// Unified-suite tests only (`build_options.zjs_unified_test_suite`).
comptime {
    if (@import("builtin").is_test and @import("build_options").zjs_unified_test_suite) {
        _ = @import("bytecode/tests.zig");
    }
}
