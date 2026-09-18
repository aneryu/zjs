//! Shared GC VERIFY/AUDIT stderr writer.
//!
//! Leftover `std.debug.print` instantiations for arena / doomed-reclaim /
//! block-heap audit lines share one label + unsigned-number walk. Call sites
//! keep the field mapping; this is not a format language. Not on `core/root`
//! or the public embedder API. CLI `writeCounterLine` stays CLI-only.

const std = @import("std");

pub const Part = union(enum) {
    text: []const u8,
    dec: u64,
    hex: u64,
};

/// Zig `{}` / `{any}` for `bool`.
pub inline fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

/// Zig `{x:0>width}`: lowercase hex, no prefix, zero-padded to a minimum width.
pub noinline fn hexPad(value: u64, width: u8, buf: *[16]u8) []const u8 {
    std.debug.assert(width >= 1 and width <= 16);
    const raw = formatHex(value, buf);
    if (raw.len >= width) return raw;
    const pad = @as(usize, width) - raw.len;
    const start = buf.len - raw.len - pad;
    @memset(buf[start .. buf.len - raw.len], '0');
    return buf[start..];
}

/// Same stderr lock and ignore-errors contract as `std.debug.print`.
pub fn print(parts: []const Part) void {
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    const writer = &stderr.file_writer.interface;
    write(writer, parts) catch return;
    writer.flush() catch return;
}

/// Writes leftover audit labels and unsigned numbers. `{d}` / `{x}` digits
/// match `std.fmt` (no prefix, no padding, no leading zeros except zero).
pub noinline fn write(writer: *std.Io.Writer, parts: []const Part) std.Io.Writer.Error!void {
    var dec_buf: [20]u8 = undefined;
    var hex_buf: [16]u8 = undefined;
    for (parts) |part| {
        switch (part) {
            .text => |text| try writer.writeAll(text),
            .dec => |value| try writer.writeAll(formatDec(value, &dec_buf)),
            .hex => |value| try writer.writeAll(formatHex(value, &hex_buf)),
        }
    }
}

fn formatDec(value: u64, buf: *[20]u8) []const u8 {
    var rest = value;
    var i: usize = buf.len;
    while (true) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(rest % 10));
        rest /= 10;
        if (rest == 0) break;
    }
    return buf[i..];
}

fn formatHex(value: u64, buf: *[16]u8) []const u8 {
    const digits = "0123456789abcdef";
    var rest = value;
    var i: usize = buf.len;
    while (true) {
        i -= 1;
        buf[i] = digits[@intCast(rest & 0xf)];
        rest >>= 4;
        if (rest == 0) break;
    }
    return buf[i..];
}
fn expectAuditPrintMatchesFmt(
    comptime fmt: []const u8,
    args: anytype,
    parts: []const Part,
) !void {
    var expected_buf: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, fmt, args);
    var actual_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&actual_buf);
    try write(&writer, parts);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "gc_audit_print leftover formats match debug.print digits" {

    try expectAuditPrintMatchesFmt(
        "gc: {s} AUDIT: {s}\n",
        .{ "ADDRESS INDEX", "OutOfMemory" },
        &.{
            .{ .text = "gc: " },
            .{ .text = "ADDRESS INDEX" },
            .{ .text = " AUDIT: " },
            .{ .text = "OutOfMemory" },
            .{ .text = "\n" },
        },
    );
    try expectAuditPrintMatchesFmt(
        "gc: ARENA AUDIT: {d} free blocks read live, {d} live objects unresolvable\n",
        .{ @as(usize, 3), @as(usize, 11) },
        &.{
            .{ .text = "gc: ARENA AUDIT: " },
            .{ .dec = 3 },
            .{ .text = " free blocks read live, " },
            .{ .dec = 11 },
            .{ .text = " live objects unresolvable\n" },
        },
    );
    try expectAuditPrintMatchesFmt(
        "gc: DOOMED RECLAIM AUDIT: {s} block=0x{x} allocated_count={d}\n",
        .{ "AllocCountMismatch", @as(usize, 0x7fabc0), @as(u32, 17) },
        &.{
            .{ .text = "gc: DOOMED RECLAIM AUDIT: " },
            .{ .text = "AllocCountMismatch" },
            .{ .text = " block=0x" },
            .{ .hex = 0x7fabc0 },
            .{ .text = " allocated_count=" },
            .{ .dec = 17 },
            .{ .text = "\n" },
        },
    );
    try expectAuditPrintMatchesFmt(
        "gc: BLOCK HEAP AUDIT free head out of range block=0x{x} head={d} cells={d}\n",
        .{ @as(usize, 0x1000), @as(u32, 64), @as(u32, 32) },
        &.{
            .{ .text = "gc: BLOCK HEAP AUDIT free head out of range block=0x" },
            .{ .hex = 0x1000 },
            .{ .text = " head=" },
            .{ .dec = 64 },
            .{ .text = " cells=" },
            .{ .dec = 32 },
            .{ .text = "\n" },
        },
    );
    try expectAuditPrintMatchesFmt(
        "gc: BLOCK HEAP AUDIT free link names allocated cell block=0x{x} link={d} walked={d}\n",
        .{ @as(usize, 0x20), @as(u32, 7), @as(u32, 4) },
        &.{
            .{ .text = "gc: BLOCK HEAP AUDIT free link names allocated cell block=0x" },
            .{ .hex = 0x20 },
            .{ .text = " link=" },
            .{ .dec = 7 },
            .{ .text = " walked=" },
            .{ .dec = 4 },
            .{ .text = "\n" },
        },
    );
    try expectAuditPrintMatchesFmt(
        "gc: BLOCK HEAP AUDIT free poison mismatch block=0x{x} link={d} raw=0x{x} walked={d} head={d} bump={d} allocated={d}\n",
        .{ @as(usize, 0xabcdef), @as(u32, 9), @as(u32, 0xdead), @as(u32, 2), @as(u32, 1), @as(u32, 8), @as(u32, 3) },
        &.{
            .{ .text = "gc: BLOCK HEAP AUDIT free poison mismatch block=0x" },
            .{ .hex = 0xabcdef },
            .{ .text = " link=" },
            .{ .dec = 9 },
            .{ .text = " raw=0x" },
            .{ .hex = 0xdead },
            .{ .text = " walked=" },
            .{ .dec = 2 },
            .{ .text = " head=" },
            .{ .dec = 1 },
            .{ .text = " bump=" },
            .{ .dec = 8 },
            .{ .text = " allocated=" },
            .{ .dec = 3 },
            .{ .text = "\n" },
        },
    );
    try expectAuditPrintMatchesFmt(
        "gc: BLOCK HEAP AUDIT incomplete free chain block=0x{x} walked={d} expected={d} head={d} bump={d} allocated={d}\n",
        .{ @as(usize, 0xf0), @as(u32, 5), @as(u32, 6), @as(u32, 0), @as(u32, 9), @as(u32, 3) },
        &.{
            .{ .text = "gc: BLOCK HEAP AUDIT incomplete free chain block=0x" },
            .{ .hex = 0xf0 },
            .{ .text = " walked=" },
            .{ .dec = 5 },
            .{ .text = " expected=" },
            .{ .dec = 6 },
            .{ .text = " head=" },
            .{ .dec = 0 },
            .{ .text = " bump=" },
            .{ .dec = 9 },
            .{ .text = " allocated=" },
            .{ .dec = 3 },
            .{ .text = "\n" },
        },
    );
    try expectAuditPrintMatchesFmt(
        "VERIFY-MAJOR condemned-but-reachable source={s} kind={s}\n",
        .{ "precise", "object" },
        &.{
            .{ .text = "VERIFY-MAJOR condemned-but-reachable source=" },
            .{ .text = "precise" },
            .{ .text = " kind=" },
            .{ .text = "object" },
            .{ .text = "\n" },
        },
    );
    try expectAuditPrintMatchesFmt(
        "VERIFY-MAJOR {d} precise, {d} conservative-only condemned-but-reachable\n",
        .{ @as(usize, 2), @as(usize, 5) },
        &.{
            .{ .text = "VERIFY-MAJOR " },
            .{ .dec = 2 },
            .{ .text = " precise, " },
            .{ .dec = 5 },
            .{ .text = " conservative-only condemned-but-reachable\n" },
        },
    );
    try expectAuditPrintMatchesFmt(
        "VERIFY-MINOR setup failed: {s}\n",
        .{"OutOfMemory"},
        &.{
            .{ .text = "VERIFY-MINOR setup failed: " },
            .{ .text = "OutOfMemory" },
            .{ .text = "\n" },
        },
    );
    try expectAuditPrintMatchesFmt(
        "VERIFY-MINOR condemned-but-reachable source={s} kind=object class={d} payload={s}\n",
        .{ "precise", @as(u16, 12), "array" },
        &.{
            .{ .text = "VERIFY-MINOR condemned-but-reachable source=" },
            .{ .text = "precise" },
            .{ .text = " kind=object class=" },
            .{ .dec = 12 },
            .{ .text = " payload=" },
            .{ .text = "array" },
            .{ .text = "\n" },
        },
    );
    try expectAuditPrintMatchesFmt(
        "VERIFY-MINOR {d} of {d} condemned objects are reachable by a full trace ({d} precise, {d} conservative-only)\n",
        .{ @as(usize, 4), @as(usize, 9), @as(usize, 1), @as(usize, 3) },
        &.{
            .{ .text = "VERIFY-MINOR " },
            .{ .dec = 4 },
            .{ .text = " of " },
            .{ .dec = 9 },
            .{ .text = " condemned objects are reachable by a full trace (" },
            .{ .dec = 1 },
            .{ .text = " precise, " },
            .{ .dec = 3 },
            .{ .text = " conservative-only)\n" },
        },
    );
    const Kind = enum { shape, object };
    try expectAuditPrintMatchesFmt(
        "gc: ARENA AUDIT live object at 0x{x} (kind {any}) does not resolve\n",
        .{ @as(usize, 0xabc), Kind.shape },
        &.{
            .{ .text = "gc: ARENA AUDIT live object at 0x" },
            .{ .hex = 0xabc },
            .{ .text = " (kind ." },
            .{ .text = @tagName(Kind.shape) },
            .{ .text = ") does not resolve\n" },
        },
    );
    try expectAuditPrintMatchesFmt(
        "MINOR-AUDIT-WHERE owner_class={d} payload={s} where={s} atom={s} nprops={d} owner_marked={}\n",
        .{ @as(u16, 4), "array", "prop_data", "x", @as(u32, 3), true },
        &.{
            .{ .text = "MINOR-AUDIT-WHERE owner_class=" },
            .{ .dec = 4 },
            .{ .text = " payload=" },
            .{ .text = "array" },
            .{ .text = " where=" },
            .{ .text = "prop_data" },
            .{ .text = " atom=" },
            .{ .text = "x" },
            .{ .text = " nprops=" },
            .{ .dec = 3 },
            .{ .text = " owner_marked=" },
            .{ .text = boolText(true) },
            .{ .text = "\n" },
        },
    );
    try expectAuditPrintMatchesFmt(
        "MINOR-AUDIT owner={s}/ptr{x} owner_young={} owner_remembered={} -> child kind={s} class={d}/{s} child_young={} child_marked={}\n",
        .{ "object", @as(usize, 0x10), false, true, "string", @as(u32, 0), "-", true, false },
        &.{
            .{ .text = "MINOR-AUDIT owner=" },
            .{ .text = "object" },
            .{ .text = "/ptr" },
            .{ .hex = 0x10 },
            .{ .text = " owner_young=" },
            .{ .text = boolText(false) },
            .{ .text = " owner_remembered=" },
            .{ .text = boolText(true) },
            .{ .text = " -> child kind=" },
            .{ .text = "string" },
            .{ .text = " class=" },
            .{ .dec = 0 },
            .{ .text = "/" },
            .{ .text = "-" },
            .{ .text = " child_young=" },
            .{ .text = boolText(true) },
            .{ .text = " child_marked=" },
            .{ .text = boolText(false) },
            .{ .text = "\n" },
        },
    );
    try expectAuditPrintMatchesFmt(
        "gc: BLOCK CELL AUDIT young cell 0x{x} index {d} in unlisted block 0x{x} (flags=0x{x}, block_flags=0x{x}, marked={any}, doomed=0x{x}, doomed_cursor={d}, doomed_word=0x{x})\n",
        .{ @as(usize, 0x20), @as(u32, 3), @as(usize, 0x40), @as(u8, 0x11), @as(u8, 0x2), true, @as(u64, 0x8), @as(u32, 1), @as(u64, 0xff) },
        &.{
            .{ .text = "gc: BLOCK CELL AUDIT young cell 0x" },
            .{ .hex = 0x20 },
            .{ .text = " index " },
            .{ .dec = 3 },
            .{ .text = " in unlisted block 0x" },
            .{ .hex = 0x40 },
            .{ .text = " (flags=0x" },
            .{ .hex = 0x11 },
            .{ .text = ", block_flags=0x" },
            .{ .hex = 0x2 },
            .{ .text = ", marked=" },
            .{ .text = boolText(true) },
            .{ .text = ", doomed=0x" },
            .{ .hex = 0x8 },
            .{ .text = ", doomed_cursor=" },
            .{ .dec = 1 },
            .{ .text = ", doomed_word=0x" },
            .{ .hex = 0xff },
            .{ .text = ")\n" },
        },
    );
    try expectAuditPrintMatchesFmt(
        "gc: TGC S4-d FINALIZER-BIT AUDIT: object=0x{x} class_id={d} payload={s} weak_id={} borrowed={} reached teardown unstamped\n",
        .{ @as(usize, 0xabc), @as(u16, 1), "none", true, false },
        &.{
            .{ .text = "gc: TGC S4-d FINALIZER-BIT AUDIT: object=0x" },
            .{ .hex = 0xabc },
            .{ .text = " class_id=" },
            .{ .dec = 1 },
            .{ .text = " payload=" },
            .{ .text = "none" },
            .{ .text = " weak_id=" },
            .{ .text = boolText(true) },
            .{ .text = " borrowed=" },
            .{ .text = boolText(false) },
            .{ .text = " reached teardown unstamped\n" },
        },
    );
    try expectAuditPrintMatchesFmt(
        "UNBARRIERED-STORE site={s} hit={d} owner_kind={s} owner_class={d} child_kind={s}\n",
        .{ "set_property_data_overwrite", @as(usize, 2), "object", @as(u32, 7), "string" },
        &.{
            .{ .text = "UNBARRIERED-STORE site=" },
            .{ .text = "set_property_data_overwrite" },
            .{ .text = " hit=" },
            .{ .dec = 2 },
            .{ .text = " owner_kind=" },
            .{ .text = "object" },
            .{ .text = " owner_class=" },
            .{ .dec = 7 },
            .{ .text = " child_kind=" },
            .{ .text = "string" },
            .{ .text = "\n" },
        },
    );
    try expectAuditPrintMatchesFmt(
        "gc: ARENA AUDIT free block at 0x{x} reads heap_accounted (kind {any}, lifetime_word 0x{x})\n",
        .{ @as(usize, 0x50), Kind.object, @as(u32, 0x11) },
        &.{
            .{ .text = "gc: ARENA AUDIT free block at 0x" },
            .{ .hex = 0x50 },
            .{ .text = " reads heap_accounted (kind ." },
            .{ .text = @tagName(Kind.object) },
            .{ .text = ", lifetime_word 0x" },
            .{ .hex = 0x11 },
            .{ .text = ")\n" },
        },
    );
    try expectAuditPrintMatchesFmt(
        "gc: PROPERTY STORAGE AUDIT: array owner class={d} fast_array={} capacity={d} young={} cell=0x{x}\n",
        .{ @as(u16, 8), true, @as(u32, 16), false, @as(usize, 0x90) },
        &.{
            .{ .text = "gc: PROPERTY STORAGE AUDIT: array owner class=" },
            .{ .dec = 8 },
            .{ .text = " fast_array=" },
            .{ .text = boolText(true) },
            .{ .text = " capacity=" },
            .{ .dec = 16 },
            .{ .text = " young=" },
            .{ .text = boolText(false) },
            .{ .text = " cell=0x" },
            .{ .hex = 0x90 },
            .{ .text = "\n" },
        },
    );
    var alloc_info_buf: [16]u8 = undefined;
    var flags_buf: [16]u8 = undefined;
    var lifetime_buf: [16]u8 = undefined;
    try expectAuditPrintMatchesFmt(
        "gc: REPRESENTATION HEADER population={s} header=0x{x} kind={s} size_class={d} alloc_info=0x{x:0>2} flags=0x{x:0>2} lifetime=0x{x:0>8} error={s}\n",
        .{ "live", @as(usize, 0xabc), "object", @as(u8, 3), @as(u8, 0xa), @as(u8, 0), @as(u32, 0x11), "DoomedBitForFreeCell" },
        &.{
            .{ .text = "gc: REPRESENTATION HEADER population=" },
            .{ .text = "live" },
            .{ .text = " header=0x" },
            .{ .hex = 0xabc },
            .{ .text = " kind=" },
            .{ .text = "object" },
            .{ .text = " size_class=" },
            .{ .dec = 3 },
            .{ .text = " alloc_info=0x" },
            .{ .text = hexPad(0xa, 2, &alloc_info_buf) },
            .{ .text = " flags=0x" },
            .{ .text = hexPad(0, 2, &flags_buf) },
            .{ .text = " lifetime=0x" },
            .{ .text = hexPad(0x11, 8, &lifetime_buf) },
            .{ .text = " error=" },
            .{ .text = "DoomedBitForFreeCell" },
            .{ .text = "\n" },
        },
    );
}

test "gc_audit_print hexPad matches zero-padded hex widths" {
    const cases = .{
        .{ 0, 2, "{x:0>2}" },
        .{ 0xa, 2, "{x:0>2}" },
        .{ 0xff, 2, "{x:0>2}" },
        .{ 0x100, 2, "{x:0>2}" },
        .{ 0, 4, "{x:0>4}" },
        .{ 0x1, 4, "{x:0>4}" },
        .{ 0x1f, 4, "{x:0>4}" },
        .{ 0x7f, 4, "{x:0>4}" },
        .{ 0xffff, 4, "{x:0>4}" },
        .{ 0x10000, 4, "{x:0>4}" },
        .{ 0, 8, "{x:0>8}" },
        .{ 0x11, 8, "{x:0>8}" },
        .{ 0xffffffff, 8, "{x:0>8}" },
        .{ std.math.maxInt(u64), 8, "{x:0>8}" },
    };
    inline for (cases) |case| {
        var expected_buf: [32]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, case[2], .{@as(u64, case[0])});
        var actual_buf: [16]u8 = undefined;
        const actual = hexPad(case[0], case[1], &actual_buf);
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "gc_audit_print handles full unsigned range and writer errors" {
    const max_u64 = std.math.maxInt(u64);
    try expectAuditPrintMatchesFmt(
        "zero {d} hex {x} max {d} hexmax {x}\n",
        .{ @as(u64, 0), @as(u64, 0), max_u64, max_u64 },
        &.{
            .{ .text = "zero " },
            .{ .dec = 0 },
            .{ .text = " hex " },
            .{ .hex = 0 },
            .{ .text = " max " },
            .{ .dec = max_u64 },
            .{ .text = " hexmax " },
            .{ .hex = max_u64 },
            .{ .text = "\n" },
        },
    );
    try expectAuditPrintMatchesFmt(
        "{d} {d} {d} {x} {x} {x}",
        .{ @as(u64, 1), @as(u64, 9), @as(u64, 10), @as(u64, 0xa), @as(u64, 0xff), @as(u64, 0x1000) },
        &.{
            .{ .dec = 1 },
            .{ .text = " " },
            .{ .dec = 9 },
            .{ .text = " " },
            .{ .dec = 10 },
            .{ .text = " " },
            .{ .hex = 0xa },
            .{ .text = " " },
            .{ .hex = 0xff },
            .{ .text = " " },
            .{ .hex = 0x1000 },
        },
    );

    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer[0..1]);
    try std.testing.expectError(error.WriteFailed, write(&writer, &.{
        .{ .text = "gc: " },
        .{ .dec = 12 },
    }));
    writer = std.Io.Writer.fixed(buffer[0..5]);
    try std.testing.expectError(error.WriteFailed, write(&writer, &.{
        .{ .text = "gc: " },
        .{ .dec = 12 },
        .{ .text = " more" },
    }));
    writer = std.Io.Writer.fixed(buffer[0..8]);
    try std.testing.expectError(error.WriteFailed, write(&writer, &.{
        .{ .text = "prefix " },
        .{ .dec = max_u64 },
    }));
}
