const std = @import("std");
const build_options = @import("build_options");

const ProfileCase = struct {
    name: []const u8,
    source: []const u8,
    expected_stdout_prefix: []const u8,
    max_opcodes: u64,
};

fn resolvedZjsPath(buf: *[1024]u8) []const u8 {
    const configured_path = build_options.zjs_executable_path;
    if (std.Io.Dir.cwd().openFile(std.testing.io, configured_path, .{})) |file| {
        file.close(std.testing.io);
        return configured_path;
    } else |_| {
        return std.fmt.bufPrint(buf, "../../{s}", .{configured_path}) catch configured_path;
    }
}

fn perfOpcodeCount(stderr: []const u8) !u64 {
    const needle = "\"opcodes_executed\": ";
    const start = (std.mem.indexOf(u8, stderr, needle) orelse return error.MissingOpcodeCount) + needle.len;
    var end = start;
    while (end < stderr.len and std.ascii.isDigit(stderr[end])) : (end += 1) {}
    if (end == start) return error.MissingOpcodeCount;
    return try std.fmt.parseInt(u64, stderr[start..end], 10);
}

test "zjs CLI behavior" {
    const allocator = std.testing.allocator;
    var zjs_path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedZjsPath(&zjs_path_buf);

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
            \\console.log(typeof argv0);
            \\console.log(typeof execArgv);
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
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "undefined\nundefined") != null);
    }

    // 5. CLI string append loops should hit the top-level range fast path.
    {
        const result = try std.process.run(allocator, std.testing.io, .{
            .argv = &[_][]const u8{
                zjs_path,
                "--profile-opcodes",
                "--perf-json",
                "-e",
                "let s = ''; for (let i = 0; i < 2000; i++) s += 'x'; print(s.length);",
            },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const exit_code = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
        try std.testing.expectEqual(@as(u8, 0), exit_code);
        try std.testing.expect(std.mem.startsWith(u8, result.stdout, "2000\n"));
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "ZJS opcode profile") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "\"name\": \"add\"") == null);
    }

    // 6. Prepared native Math calls must route sumPrecise through its iterable-aware implementation.
    {
        const result = try std.process.run(allocator, std.testing.io, .{
            .argv = &[_][]const u8{
                zjs_path,
                "-e",
                "console.log(Math.sumPrecise([1, 2, 3])); console.log(Object.is(Math.sumPrecise([]), -0));",
            },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const exit_code = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
        try std.testing.expectEqual(@as(u8, 0), exit_code);
        try std.testing.expectEqualStrings("6\ntrue\n", result.stdout);
        try std.testing.expectEqualStrings("", result.stderr);
    }

    // 7. Phase-1 closure opcodes must not collide with temporary scope opcodes.
    {
        const result = try std.process.run(allocator, std.testing.io, .{
            .argv = &[_][]const u8{
                zjs_path,
                "-e",
                "var a, b; class A {} class B extends A { method() { a = (() => super.x)(); b = 2; } } A.prototype.x = 1; new B().method(); console.log(a); console.log(b);",
            },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const exit_code = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
        try std.testing.expectEqual(@as(u8, 0), exit_code);
        try std.testing.expectEqualStrings("1\n2\n", result.stdout);
        try std.testing.expectEqualStrings("", result.stderr);
    }

    // 8. Script and eval entrypoints use ordinary sloppy-mode assignment semantics.
    {
        const result = try std.process.run(allocator, std.testing.io, .{
            .argv = &[_][]const u8{ zjs_path, "-e", "cliSloppyGlobal = 1; console.log(cliSloppyGlobal, globalThis.cliSloppyGlobal);" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const exit_code = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
        try std.testing.expectEqual(@as(u8, 0), exit_code);
        try std.testing.expectEqualStrings("1 1\n", result.stdout);
        try std.testing.expectEqualStrings("", result.stderr);
    }

    {
        const root_dir = ".zig-cache/smoke-cli-sloppy-file";
        const temp_filename = root_dir ++ "/sloppy_assignment.js";

        std.Io.Dir.cwd().deleteTree(std.testing.io, root_dir) catch {};
        defer std.Io.Dir.cwd().deleteTree(std.testing.io, root_dir) catch {};
        try std.Io.Dir.cwd().createDirPath(std.testing.io, root_dir);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{
            .sub_path = temp_filename,
            .data = "fileSloppyGlobal = 2; console.log(fileSloppyGlobal, globalThis.fileSloppyGlobal);",
        });

        const result = try std.process.run(allocator, std.testing.io, .{
            .argv = &[_][]const u8{ zjs_path, temp_filename },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const exit_code = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
        try std.testing.expectEqual(@as(u8, 0), exit_code);
        try std.testing.expectEqualStrings("2 2\n", result.stdout);
        try std.testing.expectEqualStrings("", result.stderr);
    }
}

test "prepared method calls capture callee before argument side effects" {
    const allocator = std.testing.allocator;
    var zjs_path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedZjsPath(&zjs_path_buf);
    const source =
        \\let log = "";
        \\let old = function(x) { log += "old" + x; };
        \\let obj = { f: old };
        \\obj.f((obj.f = function() { log += "new"; }, log += "a"));
        \\try { ({ f: 1 }).f(log += "b"); } catch (e) { log += "T"; }
        \\console.log(log);
        \\console.log(Date.now() > 0, Number.parseFloat("1.5"), "abcdef".substring(1, 3), /b/.test("abc"));
    ;

    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &[_][]const u8{ zjs_path, "-e", source },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exit_code = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("aoldabT\ntrue 1.5 bc true\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "CLI top-level range fast paths collapse completion-store loops" {
    const allocator = std.testing.allocator;
    var zjs_path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedZjsPath(&zjs_path_buf);

    const cases = [_]ProfileCase{
        .{
            .name = "int_sum",
            .source = "let sum = 0; for (let i = 0; i < 2000; i++) sum += i; print(sum);",
            .expected_stdout_prefix = "1999000\n",
            .max_opcodes = 120,
        },
        .{
            .name = "array_read",
            .source = "let tab = [3]; let sum = 0; for (let i = 0; i < 2000; i++) sum += tab[0]; print(sum);",
            .expected_stdout_prefix = "6000\n",
            .max_opcodes = 120,
        },
        .{
            .name = "global_read_loop",
            .source = "var x = 1; let s = 0; for (let i = 0; i < 2000; i++) s += x; print(s);",
            .expected_stdout_prefix = "2000\n",
            .max_opcodes = 120,
        },
        .{
            .name = "global_write_loop",
            .source = "\"use strict\"; var g = 0; for (let i = 0; i < 2000; i++) g = i; print(g);",
            .expected_stdout_prefix = "1999\n",
            .max_opcodes = 120,
        },
        .{
            .name = "prop_read_mono",
            .source = "const o = { a: 1, b: 2, c: 3 }; let s = 0; for (let i = 0; i < 2000; i++) s += o.b; print(s);",
            .expected_stdout_prefix = "4000\n",
            .max_opcodes = 120,
        },
        .{
            .name = "prop_read_poly3",
            .source = "const a = { x: 1, y: 0 }; const b = { y: 0, x: 2 }; const c = { z: 0, x: 3 }; const arr = [a, b, c]; let s = 0; for (let i = 0; i < 2000; i++) s += arr[i % 3].x; print(s);",
            .expected_stdout_prefix = "3999\n",
            .max_opcodes = 120,
        },
        .{
            .name = "proto_read",
            .source = "const p = { x: 1 }; const o = Object.create(p); let s = 0; for (let i = 0; i < 2000; i++) s += o.x; print(s);",
            .expected_stdout_prefix = "2000\n",
            .max_opcodes = 120,
        },
        .{
            .name = "func_call",
            .source = "function f(x) { return x + 1; } let s = 0; for (let i = 0; i < 40000; i++) s += f(i); print(s);",
            .expected_stdout_prefix = "800020000\n",
            .max_opcodes = 140,
        },
        .{
            .name = "call2_loop",
            .source = "function f(a, b) { return a + b; } let s = 0; for (let i = 0; i < 40000; i++) s += f(i, 1); print(s);",
            .expected_stdout_prefix = "800020000\n",
            .max_opcodes = 140,
        },
        .{
            .name = "closure_call_loop",
            .source = "function make(x) { return function(y) { return x + y; }; } const f = make(1); let s = 0; for (let i = 0; i < 40000; i++) s += f(i); print(s);",
            .expected_stdout_prefix = "800020000\n",
            .max_opcodes = 160,
        },
        .{
            .name = "math_min",
            .source = "let s = 0; for (let i = 0; i < 40000; i++) s += Math.min(i, 500); print(s);",
            .expected_stdout_prefix = "19874750\n",
            .max_opcodes = 120,
        },
        .{
            .name = "map_string_keys",
            .source = "const m = new Map(); for (let i = 0; i < 10000; i++) m.set(\"k\" + i, i); let s = 0; for (let i = 0; i < 10000; i++) s += m.get(\"k\" + i); print(s);",
            .expected_stdout_prefix = "49995000\n",
            .max_opcodes = 180,
        },
    };

    for (cases) |case| {
        const result = try std.process.run(allocator, std.testing.io, .{
            .argv = &[_][]const u8{
                zjs_path,
                "--profile-opcodes",
                "--perf-json",
                "-e",
                case.source,
            },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const exit_code = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
        try std.testing.expectEqual(@as(u8, 0), exit_code);
        try std.testing.expect(std.mem.startsWith(u8, result.stdout, case.expected_stdout_prefix));

        const opcodes = try perfOpcodeCount(result.stderr);
        try std.testing.expect(opcodes <= case.max_opcodes);
    }
}
