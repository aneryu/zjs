//! Hit counters for the host-call dispatch fallbacks in `call.zig`. The
//! legacy string-name dispatch chain that used to live in
//! `callNativeBuiltin` (and `callObjectStatic`/`callArrayMethod`/
//! `callStringMethod`/`callPrimitiveMethod`) was instrumented with one
//! counter per name branch, measured over the full microbench suite, the
//! hotpath suite, `tests/perf/microbench.js`, and the entire test262 tree,
//! and then converged onto the integer native-record mechanism: every
//! measured-live branch was migrated to a domain/id record and the chain
//! was deleted. The surviving counter tracks calls that fall past the
//! record dispatch entirely (and therefore throw TypeError) so future
//! regressions in record coverage stay visible. New dispatch fallbacks
//! should get a tag here and a `counted(...)`/`hit(...)` call before any
//! keep-or-delete decision.
//!
//! Zero-cost by default: counting only compiles in with
//! `-Dzjs_enable_opcode_profile=true`. With that build flag, the `zjs` CLI
//! appends per-process totals to `$ZJS_HOST_DISPATCH_STATS_FILE` on exit and
//! the `--profile-opcodes` dump includes the per-site table.

const std = @import("std");
const build_options = @import("build_options");

pub const enabled = build_options.zjs_enable_opcode_profile;

/// One tag per dispatch fallback site.
pub const Site = enum(u16) {
    /// callNativeBuiltin fell past callNativeFunctionRecord with no record
    /// match; the call throws TypeError. Non-trivial counts here point at
    /// builtins missing a native-record id.
    nb_fallback_entered,
};

pub const site_count = @typeInfo(Site).@"enum".fields.len;

var hits: [site_count]u64 = @splat(0);

/// Wraps a dispatch-branch condition and forwards it unchanged. Records a
/// hit when the branch matched (`true` / non-null payload / non-error
/// payload of the same). The counter update is atomic so multi-threaded
/// embedders (and the test262 runner workers) can share the process-wide
/// table.
pub inline fn counted(comptime tag: Site, result: anytype) @TypeOf(result) {
    if (comptime enabled) {
        if (isHit(result)) _ = @atomicRmw(u64, &hits[@intFromEnum(tag)], .Add, 1, .monotonic);
    }
    return result;
}

/// Unconditional hit, for counting fallthrough entry points.
pub inline fn hit(comptime tag: Site) void {
    if (comptime enabled) _ = @atomicRmw(u64, &hits[@intFromEnum(tag)], .Add, 1, .monotonic);
}

inline fn isHit(result: anytype) bool {
    return switch (@typeInfo(@TypeOf(result))) {
        .error_union => if (result) |payload| payloadHit(payload) else |_| false,
        else => payloadHit(result),
    };
}

inline fn payloadHit(payload: anytype) bool {
    return switch (@typeInfo(@TypeOf(payload))) {
        .bool => payload,
        .optional => payload != null,
        else => @compileError("unsupported dispatch condition type: " ++ @typeName(@TypeOf(payload))),
    };
}

pub fn hitCount(tag: Site) u64 {
    return @atomicLoad(u64, &hits[@intFromEnum(tag)], .monotonic);
}

pub fn snapshot() [site_count]u64 {
    var out: [site_count]u64 = undefined;
    for (&out, 0..) |*slot, index| slot.* = @atomicLoad(u64, &hits[index], .monotonic);
    return out;
}

pub fn tagName(index: usize) []const u8 {
    return @tagName(@as(Site, @enumFromInt(index)));
}

extern "c" fn close(fd: std.c.fd_t) c_int;

var append_text_buf: [32 * 1024]u8 = undefined;

/// Append the non-zero hit counts as `name count` lines to `path`. The whole
/// payload goes out in one `O_APPEND` write so dumps from concurrently
/// exiting processes (microbench harness, spawned test262 engines) stay
/// line-intact and can be summed afterwards. Uses libc directly so the `zjs`
/// CLI can call it from an `atexit` handler.
pub fn appendToFile(path: [*:0]const u8) void {
    if (comptime !enabled) return;
    const counts = snapshot();
    var text: std.Io.Writer = .fixed(&append_text_buf);
    for (counts, 0..) |count, index| {
        if (count == 0) continue;
        text.print("{s} {d}\n", .{ tagName(index), count }) catch return;
    }
    const payload = text.buffered();
    if (payload.len == 0) return;
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true }, @as(c_int, 0o644));
    if (fd < 0) return;
    defer _ = close(fd);
    _ = std.c.write(fd, payload.ptr, payload.len);
}
