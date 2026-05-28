//! Thin process entry point.
//!
//! Only does argument parsing, stdio setup, and command dispatch.
//! All real behavior lives behind `src/root.zig`.
//!
//! See docs/architecture.md and docs/runtime-mvp.md (CLI contract).

const std = @import("std");
const Io = std.Io;

const fun = @import("fun");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    defer stderr.flush() catch {};

    const command = fun.parseCommand(args);

    switch (command) {
        .help => try fun.printHelp(stdout),
        .version => try stdout.print("{s}\n", .{fun.version}),
        .run_file, .repl => try fun.cli.printPending(command, stdout),
    }
}

test "imports runtime module" {
    try std.testing.expect(fun.version.len > 0);
}
