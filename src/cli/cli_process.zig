//! Process-boundary helpers shared by the two CLI roots.
//!
//! `zjs.zig` and `run_test262.zig` are separate binaries with separate roots;
//! both use these.

const std = @import("std");

/// Print to stderr and flush, so a message written just before
/// `std.process.exit` is not lost with the buffer.
pub fn printError(io: std.Io, message: []const u8) void {
    printErrorJoin(io, &.{message});
}

/// Same flush contract as `printError`, with the pieces already rendered.
/// An unwritable stderr is not an error of its own: there is nowhere left to
/// report it, and the caller's exit status must not turn into stdout's
/// SIGPIPE status.
pub fn printErrorJoin(io: std.Io, parts: []const []const u8) void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    for (parts) |part| stderr.writeAll(part) catch return;
    stderr.flush() catch return;
}

/// Print `parts` to stderr, then exit with `code`. A failed write does not
/// change `code`.
pub fn fatal(io: std.Io, code: u8, parts: []const []const u8) noreturn {
    printErrorJoin(io, parts);
    std.process.exit(code);
}
