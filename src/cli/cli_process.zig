//! Process-boundary helpers shared by the two CLI roots.
//!
//! `zjs.zig` and `run_test262.zig` are separate binaries with separate roots;
//! both use these.

const std = @import("std");

/// Copy `std.process.Args` into a plain slice owned by `arena`.
pub fn argsToSlice(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    const raw_args = try args.toSlice(arena);
    const result = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, i| result[i] = arg;
    return result;
}

/// Print to stderr and flush, so a message written just before
/// `std.process.exit` is not lost with the buffer.
pub fn printError(io: std.Io, message: []const u8) !void {
    return printErrorJoin(io, &.{message});
}

/// Same flush contract as `printError`, with the pieces already rendered.
/// An unwritable stderr is not an error of its own: there is nowhere left to
/// report it, and the caller's exit status must not turn into stdout's
/// SIGPIPE status.
pub fn printErrorJoin(io: std.Io, parts: []const []const u8) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    for (parts) |part| stderr.writeAll(part) catch return;
    stderr.flush() catch return;
}
