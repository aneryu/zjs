const std = @import("std");
const build_options = @import("build_options");

test "zjs CLI behavior" {
    const allocator = std.testing.allocator;
    const zjs_path = build_options.zjs_executable_path;

    // 1. Basic Eval
    {
        const result = try std.process.run(allocator, std.testing.io, .{
            .argv = &[_][]const u8{ zjs_path, "-e", "console.log(1 + 1);" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const exit_code = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
        try std.testing.expectEqual(@as(u8, 0), exit_code);
        try std.testing.expectEqualStrings("2\n", result.stdout);
        try std.testing.expectEqualStrings("", result.stderr);
    }

    // 2. Exception throws exit non-zero
    {
        const result = try std.process.run(allocator, std.testing.io, .{
            .argv = &[_][]const u8{ zjs_path, "-e", "throw new Error('boom');" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const exit_code = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
        try std.testing.expectEqual(@as(u8, 1), exit_code);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "boom") != null);
    }

    // 3. No arguments usage error
    {
        const result = try std.process.run(allocator, std.testing.io, .{
            .argv = &[_][]const u8{zjs_path},
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const exit_code = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
        try std.testing.expectEqual(@as(u8, 2), exit_code);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "usage:") != null);
    }

    // 4. Run JS File and script arguments
    {
        const root_dir = ".zig-cache/smoke-cli-test";
        const temp_filename = root_dir ++ "/temp_smoke_args.js";

        std.Io.Dir.cwd().deleteTree(std.testing.io, root_dir) catch {};
        defer std.Io.Dir.cwd().deleteTree(std.testing.io, root_dir) catch {};
        try std.Io.Dir.cwd().createDirPath(std.testing.io, root_dir);

        const script_content =
            \\console.log(scriptArgs instanceof Array);
            \\console.log(scriptArgs.length);
            \\console.log(scriptArgs[0]);
            \\console.log(scriptArgs[1]);
            \\console.log(argv0);
        ;
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{
            .sub_path = temp_filename,
            .data = script_content,
        });

        const result = try std.process.run(allocator, std.testing.io, .{
            .argv = &[_][]const u8{ zjs_path, temp_filename, "foo", "bar" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const exit_code = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
        try std.testing.expectEqual(@as(u8, 0), exit_code);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "true") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "3\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "temp_smoke_args.js") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "foo") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "zjs") != null);
    }
}
