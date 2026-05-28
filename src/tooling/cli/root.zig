//! MVP CLI command model and diagnostics.
//!
//! Only supports `fun` (REPL) and `fun <file> [...args]`. Subcommands like
//! `run`/`eval`/`repl` are deliberately treated as file paths.
//!
//! See docs/runtime-mvp.md (CLI Contract).

const std = @import("std");
const Io = std.Io;

pub const Command = union(enum) {
    help,
    version,
    repl,
    run_file: struct {
        path: []const u8,
        args: []const []const u8,
    },
};

pub fn parseCommand(args: []const []const u8) Command {
    if (args.len <= 1) return .repl;

    const command = args[1];
    if (isAny(command, &.{ "help", "--help", "-h" })) return .help;
    if (isAny(command, &.{ "version", "--version", "-v" })) return .version;

    return .{
        .run_file = .{
            .path = command,
            .args = args[2..],
        },
    };
}

pub fn printHelp(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.writeAll(
        \\fun 0.0.0
        \\
        \\Usage:
        \\  fun
        \\  fun [file.js|file.ts] [...args]
        \\  fun --version
        \\  fun --help
        \\
        \\This is the initial shell for a Zig JS/TS runtime. Parsing and execution
        \\are intentionally not implemented yet.
        \\
    );
}

pub fn printPending(command: Command, writer: *Io.Writer) Io.Writer.Error!void {
    switch (command) {
        .help, .version => {},
        .repl => try writer.writeAll("repl is not implemented yet\n"),
        .run_file => |run| {
            try writer.print("run is not implemented yet: {s}\n", .{run.path});
            if (run.args.len > 0) {
                try writer.writeAll("arguments:\n");
                for (run.args, 0..) |arg, i| {
                    try writer.print("  arg[{d}]: {s}\n", .{ i, arg });
                }
            }
        },
    }
}

fn isAny(value: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

test "parse version command" {
    try std.testing.expectEqual(Command.version, parseCommand(&.{ "fun", "--version" }));
}

test "parse run command" {
    const explicit = parseCommand(&.{ "fun", "app.ts", "foo", "bar" });
    try std.testing.expectEqualStrings("app.ts", explicit.run_file.path);
    try std.testing.expectEqual(2, explicit.run_file.args.len);
    try std.testing.expectEqualStrings("foo", explicit.run_file.args[0]);
    try std.testing.expectEqualStrings("bar", explicit.run_file.args[1]);

    const implicit = parseCommand(&.{ "fun", "app.js" });
    try std.testing.expectEqualStrings("app.js", implicit.run_file.path);
    try std.testing.expectEqual(0, implicit.run_file.args.len);
}

test "parse no-arguments as repl" {
    try std.testing.expectEqual(Command.repl, parseCommand(&.{"fun"}));
}
