//! F2.5 Opcode alignment test.
//!
//! Locks the auto-generated `op` constants in `bytecode/opcode.zig` to the
//! QuickJS opcode header. Asserts:
//!
//! 1. Every name in `tests/fixtures/quickjs-opcode.h` exists in the generated
//!    `op` struct with the matching index.
//! 2. The opcode header SHA-1 has not drifted from the locked QuickJS baseline
//!    revision.
//!
//! When `tests/fixtures/quickjs-opcode.h` legitimately changes, regenerate
//! `src/engine/bytecode/opcodes_generated.zig` and bump the SHA constant below
//! to match the new file.

const std = @import("std");
const engine = @import("quickjs_zig_engine");

const opcode = engine.bytecode.opcode;

/// SHA-1 of `tests/fixtures/quickjs-opcode.h` at QuickJS baseline
/// `1209015f46958bcb2dc127847f8810d52371252f`.
const expected_opcode_header_sha1 = "4d7e310780bfae82a75e30e3d69ce91a2ec6ac66";

fn loadOpcodeHeader(allocator: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        opcode.quickjs_opcode_path,
        allocator,
        .limited(1024 * 1024),
    );
}

fn computeSha1Hex(bytes: []const u8) [40]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(bytes);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);
    var hex: [40]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return hex;
}

test "F2.5 quickjs-opcode.h SHA-1 matches locked baseline" {
    const source = try loadOpcodeHeader(std.testing.allocator);
    defer std.testing.allocator.free(source);
    const actual = computeSha1Hex(source);
    try std.testing.expectEqualStrings(expected_opcode_header_sha1, &actual);
}

test "F2.5 every parsed entry has a matching op constant at the correct index" {
    const source = try loadOpcodeHeader(std.testing.allocator);
    defer std.testing.allocator.free(source);
    const table = opcode.parse(source);

    try std.testing.expect(table.count > 0);

    // The local `ParsedTable` numbers entries sequentially in file order
    // (DEFs 0..178, defs 179..196, then short DEFs 197..263). QuickJS's
    // `OPCodeEnum` instead skips defs from the DEF counting, so DEF short
    // ids start at OP_nop+1 = 179, while def temp ids overlap that same
    // range (`quickjs.c:1155`). We translate from local file-position
    // index to QuickJS id below.
    const temp_op_count = table.short_start - table.temp_start;
    var def_seen: u8 = 0;
    var temp_seen: u8 = 0;
    for (table.all()) |entry| {
        const op_index = lookupOpIndex(entry.name) orelse {
            std.debug.print(
                "missing op constant for QuickJS opcode '{s}'\n",
                .{entry.name},
            );
            return error.MissingOpConstant;
        };
        switch (entry.kind) {
            .normal, .short => {
                try std.testing.expectEqual(def_seen, op_index);
                def_seen += 1;
            },
            .temp => {
                try std.testing.expectEqual(
                    opcode.op.op_temp_start + temp_seen,
                    op_index,
                );
                temp_seen += 1;
            },
        }
    }
    try std.testing.expectEqual(@as(u8, @intCast(temp_op_count)), temp_seen);
    try std.testing.expectEqual(opcode.op.op_count, @as(u16, def_seen));
}

test "F2.5 representative opcode indices match QuickJS table" {
    // Spot checks anchored at well-known QuickJS indices to detect any drift
    // in the generated table without scanning every name. These map to
    // `tests/fixtures/quickjs-opcode.h` line offsets and serve as stable
    // opcode-table anchor points.
    try std.testing.expectEqual(@as(u8, 0), opcode.op.invalid);
    try std.testing.expectEqual(@as(u8, 1), opcode.op.push_i32);
    try std.testing.expectEqual(@as(u8, 2), opcode.op.push_const);
    try std.testing.expectEqual(@as(u8, 6), opcode.op.undefined);
    try std.testing.expectEqual(@as(u8, 7), opcode.op.null);
    try std.testing.expectEqual(@as(u8, 9), opcode.op.push_false);
    try std.testing.expectEqual(@as(u8, 10), opcode.op.push_true);
    try std.testing.expectEqual(@as(u8, 14), opcode.op.drop);
    try std.testing.expectEqual(@as(u8, 17), opcode.op.dup);
    try std.testing.expectEqual(@as(u8, 27), opcode.op.swap);
    try std.testing.expectEqual(@as(u8, 33), opcode.op.call_constructor);
    try std.testing.expectEqual(@as(u8, 34), opcode.op.call);
    try std.testing.expectEqual(@as(u8, 36), opcode.op.call_method);
    try std.testing.expectEqual(@as(u8, 64), opcode.op.get_field);
    try std.testing.expectEqual(@as(u8, 66), opcode.op.put_field);
    try std.testing.expectEqual(@as(u8, 70), opcode.op.get_array_el);
    try std.testing.expectEqual(@as(u8, 196), opcode.op.source_loc);
}

/// Resolve an opcode name (as seen in `quickjs-opcode.h`) to its `op` index.
/// Mirrors a `comptime` lookup against the auto-generated struct.
fn lookupOpIndex(name: []const u8) ?u8 {
    const decls = @typeInfo(opcode.op).@"struct".decls;
    inline for (decls) |decl| {
        if (std.mem.eql(u8, decl.name, name)) {
            return @field(opcode.op, decl.name);
        }
    }
    return null;
}
