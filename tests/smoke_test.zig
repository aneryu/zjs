//! Runs executable smoke tests for CLI behavior and profiling artifacts.
const std = @import("std");
const build_options = @import("build_options");
const ProfileCase = struct {
    name: []const u8,
    source: []const u8,
    expected_stdout_prefix: []const u8,
    // Total-dispatch shape band, recalibrated 2026-07-31 (D0). The ceiling
    // is the de-fusing tripwire (one extra dispatch per iteration moves the
    // total by the iteration count); the floor keeps the gate anti-vacuous
    // (an all-zero profile must never pass). Recalibrate on purpose, never
    // loosen into a vacuum.
    max_opcodes: u64,
    min_opcodes: u64,
};

fn resolvedPath(buf: *[1024]u8, configured: []const u8) []const u8 {
    if (std.Io.Dir.cwd().openFile(std.testing.io, configured, .{})) |file| {
        file.close(std.testing.io);
        return configured;
    } else |_| {
        return std.fmt.bufPrint(buf, "../../{s}", .{configured}) catch configured;
    }
}

fn profileOpcodeCount(stdout: []const u8) !u64 {
    const needle = "opcodes executed: ";
    const start = (std.mem.indexOf(u8, stdout, needle) orelse return error.MissingOpcodeCount) + needle.len;
    var end = start;
    while (end < stdout.len and std.ascii.isDigit(stdout[end])) : (end += 1) {}
    if (end == start) return error.MissingOpcodeCount;
    return try std.fmt.parseInt(u64, stdout[start..end], 10);
}

test "bundled host globals and bitmap GC tear down in an executable" {
    const allocator = std.testing.allocator;
    var path: [1024]u8 = undefined;
    // A Zig test enables carrier auditing and cannot exercise the executable's
    // bitmap-only reclamation path. Keep --leak-check's Runtime assertion on.
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ resolvedPath(&path, build_options.zjs_executable_path), "--leak-check", "-e", "print(atob(btoa('host'))); queueMicrotask(() => console.log('job')); gc();" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("host\njob\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "zjs CLI behavior" {
    const allocator = std.testing.allocator;
    var zjs_path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedPath(&zjs_path_buf, build_options.zjs_executable_path);

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

    // 2b. Parser errors must not be converted into source-shaped completion
    // values by the engine entrypoint.
    {
        const result = try std.process.run(allocator, std.testing.io, .{
            .argv = &[_][]const u8{ zjs_path, "-e", "1 2" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const exit_code = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
        try std.testing.expectEqual(@as(u8, 1), exit_code);
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "SyntaxError") != null);
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

    // 5. CLI string append loops keep the top-level range fast-path shape.
    // Recalibrated 2026-07-31: opcode counting is total table dispatches now
    // (the old assertion that `add` never appears was written for the
    // retired cold-entry-only semantics and had been passing vacuously on
    // an all-zero profile). Runs against the profiling binary; the default
    // binary fails --profile-opcodes closed by contract (checked in 5b).
    if (build_options.smoke_profile_checks) {
        var profile_path_buf: [1024]u8 = undefined;
        const zjs_profile_path = resolvedPath(&profile_path_buf, build_options.zjs_profile_executable_path);
        const result = try std.process.run(allocator, std.testing.io, .{
            .argv = &[_][]const u8{
                zjs_profile_path,
                "--profile-opcodes",
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
        // Exactly one string-append add dispatch per iteration; the fused
        // range path must not add per-iteration dispatch overhead beyond
        // the measured shape (30,019 total at recalibration).
        const opcodes = try profileOpcodeCount(result.stdout);
        try std.testing.expect(opcodes >= 10_000);
        try std.testing.expect(opcodes <= 32_000);
    }

    // 5b. The default binary must fail --profile-opcodes closed instead of
    // emitting an all-zero profile (the 2026-07-31 D0 contract).
    {
        const result = try std.process.run(allocator, std.testing.io, .{
            .argv = &[_][]const u8{
                zjs_path,
                "--profile-opcodes",
                "-e",
                "print(1);",
            },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        const exit_code = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
        if (build_options.smoke_profile_checks) {
            try std.testing.expectEqual(@as(u8, 2), exit_code);
            try std.testing.expect(std.mem.indexOf(u8, result.stderr, "requires a profiling build") != null);
        } else {
            // The non-profile `zjs` is built without profiling scopes, so
            // the same fail-closed contract applies.
            try std.testing.expectEqual(@as(u8, 2), exit_code);
        }
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

    // 9. Printing an object with var-ref-backed properties (the global
    // object) prints each binding's value, not the reference cell.
    {
        const result = try std.process.run(allocator, std.testing.io, .{
            .argv = &[_][]const u8{ zjs_path, "-e", "var cliPrintedGlobal = 7; print(String(globalThis).length > 0); print(globalThis);" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const exit_code = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
        try std.testing.expectEqual(@as(u8, 0), exit_code);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "cliPrintedGlobal: 7") != null);
        try std.testing.expectEqualStrings("", result.stderr);
    }

    // 11. A full collection inside a Proxy trap keeps the trap's fresh keys
    // alive (Object.keys holds them in a native list), and a WeakRef keeps
    // its target until the end of the job that created it.
    {
        const source =
            \\var h = { ownKeys() { return ["k_" + 1, "k_" + 2]; }, getOwnPropertyDescriptor() { gc(); return { value: 1, enumerable: true, configurable: true }; } };
            \\var refs = []; for (var i = 0; i < 20; i++) refs.push(new WeakRef({ i })); gc();
            \\console.log(Object.keys(new Proxy({}, h)).join(), refs.filter((r) => r.deref() !== undefined).length);
        ;
        const result = try std.process.run(allocator, std.testing.io, .{ .argv = &[_][]const u8{ zjs_path, "-e", source } });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        const exit_code = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
        try std.testing.expectEqual(@as(u8, 0), exit_code);
        try std.testing.expectEqualStrings("k_1,k_2 20\n", result.stdout);
    }

    // 12. One module record per file: `./x.mjs` and its absolute path are the
    // same module, and import() inside `new Function` resolves against the
    // calling module. Columns count code points; a lone CR ends a line.
    {
        const root_dir = ".zig-cache/smoke-cli-module-identity";
        std.Io.Dir.cwd().deleteTree(std.testing.io, root_dir) catch {};
        defer std.Io.Dir.cwd().deleteTree(std.testing.io, root_dir) catch {};
        try std.Io.Dir.cwd().createDirPath(std.testing.io, root_dir ++ "/sub");
        var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = try std.Io.Dir.cwd().realPathFile(std.testing.io, ".", &cwd_buffer);
        const main_source = try std.fmt.allocPrint(allocator,
            \\import * as a from "./x.mjs";
            \\import * as b from "{s}/{s}/x.mjs";
            \\const viaFunction = await new Function("return import('./sub/y.mjs')")();
            \\print(a === b, globalThis.count, viaFunction.default);
        , .{ cwd_buffer[0..cwd_len], root_dir });
        defer allocator.free(main_source);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_dir ++ "/main.mjs", .data = main_source });
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_dir ++ "/x.mjs", .data = "globalThis.count = (globalThis.count ?? 0) + 1;" });
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_dir ++ "/sub/y.mjs", .data = "export default \"sub\";" });
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_dir ++ "/cr.js", .data = "var u = \"\u{65e5}\u{672c}\"; var x = 1;\rthrow new Error(\"cr\");" });

        const main_result = try std.process.run(allocator, std.testing.io, .{ .argv = &[_][]const u8{ zjs_path, root_dir ++ "/main.mjs" } });
        defer allocator.free(main_result.stdout);
        defer allocator.free(main_result.stderr);
        try std.testing.expectEqualStrings("true 1 sub\n", main_result.stdout);

        const cr_result = try std.process.run(allocator, std.testing.io, .{ .argv = &[_][]const u8{ zjs_path, "-s", root_dir ++ "/cr.js" } });
        defer allocator.free(cr_result.stdout);
        defer allocator.free(cr_result.stderr);
        try std.testing.expect(std.mem.indexOf(u8, cr_result.stderr, "cr.js:2:") != null);
    }

    // 13. console.error/warn go to stderr; a failed stdout write with an
    // unhandled rejection exits 141 without crashing in teardown; the
    // evaluation's own error wins over a pending rejection.
    {
        const Case = struct { source: []const u8, close_stdout: bool, exit_code: u8, stdout: []const u8, stderr_contains: []const u8 };
        const cases = [_]Case{
            .{ .source = "print('a'); console.error('b'); console.warn('w'); console.log('c')", .close_stdout = false, .exit_code = 0, .stdout = "a\nc\n", .stderr_contains = "b\nw\n" },
            .{ .source = "Promise.reject(1); 10n / 0n", .close_stdout = false, .exit_code = 1, .stdout = "", .stderr_contains = "RangeError" },
        };
        for (cases) |case| {
            const result = try std.process.run(allocator, std.testing.io, .{ .argv = &[_][]const u8{ zjs_path, "-e", case.source } });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            const exit_code = switch (result.term) {
                .exited => |code| code,
                else => 255,
            };
            try std.testing.expectEqual(case.exit_code, exit_code);
            try std.testing.expectEqualStrings(case.stdout, result.stdout);
            try std.testing.expect(std.mem.indexOf(u8, result.stderr, case.stderr_contains) != null);
        }
    }

    // 10. Invalid UTF-8 inside a string literal is a SyntaxError; `async` /
    // `abstract` followed by a line break is not an export modifier.
    {
        const root_dir = ".zig-cache/smoke-cli-source-edges";
        std.Io.Dir.cwd().deleteTree(std.testing.io, root_dir) catch {};
        defer std.Io.Dir.cwd().deleteTree(std.testing.io, root_dir) catch {};
        try std.Io.Dir.cwd().createDirPath(std.testing.io, root_dir);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_dir ++ "/bad_utf8.js", .data = "print(1); var s = \"\xff\";" });
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_dir ++ "/dep.mjs", .data = "var abstract = 7; export default abstract\nclass A {}\n" });
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_dir ++ "/main.mjs", .data = "import d from \"./dep.mjs\"; print(d);" });
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_dir ++ "/async_export.mjs", .data = "export async\nfunction f() {}\n" });

        const Case = struct { file: []const u8, exit_code: u8, stdout: []const u8, stderr_contains: []const u8 };
        const cases = [_]Case{
            .{ .file = root_dir ++ "/bad_utf8.js", .exit_code = 1, .stdout = "", .stderr_contains = "invalid UTF-8 in source" },
            .{ .file = root_dir ++ "/main.mjs", .exit_code = 0, .stdout = "7\n", .stderr_contains = "" },
            .{ .file = root_dir ++ "/async_export.mjs", .exit_code = 1, .stdout = "", .stderr_contains = "SyntaxError" },
        };
        for (cases) |case| {
            const result = try std.process.run(allocator, std.testing.io, .{ .argv = &[_][]const u8{ zjs_path, case.file } });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            const exit_code = switch (result.term) {
                .exited => |code| code,
                else => 255,
            };
            try std.testing.expectEqual(case.exit_code, exit_code);
            try std.testing.expectEqualStrings(case.stdout, result.stdout);
            try std.testing.expect(std.mem.indexOf(u8, result.stderr, case.stderr_contains) != null);
        }
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

        {
            const result = try std.process.run(allocator, std.testing.io, .{
                .argv = &[_][]const u8{ zjs_path, temp_filename },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);

            const exit_code = switch (result.term) {
                .exited => |code| code,
                else => 255,
            };
            // Files default to module: undeclared assignment is a ReferenceError.
            try std.testing.expectEqual(@as(u8, 1), exit_code);
            try std.testing.expect(std.mem.indexOf(u8, result.stderr, "ReferenceError") != null);
        }

        {
            const result = try std.process.run(allocator, std.testing.io, .{
                .argv = &[_][]const u8{ zjs_path, "-s", temp_filename },
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

    // 9. A file path is a module even without import/export or -m.
    {
        const root_dir = ".zig-cache/smoke-cli-default-module";
        const temp_filename = root_dir ++ "/import_meta.js";

        std.Io.Dir.cwd().deleteTree(std.testing.io, root_dir) catch {};
        defer std.Io.Dir.cwd().deleteTree(std.testing.io, root_dir) catch {};
        try std.Io.Dir.cwd().createDirPath(std.testing.io, root_dir);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{
            .sub_path = temp_filename,
            .data = "console.log(typeof import.meta.url);\n",
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
        try std.testing.expectEqualStrings("string\n", result.stdout);
        try std.testing.expectEqualStrings("", result.stderr);
    }
    // 9b. A path with a `:` is still a file URL in import.meta.url.
    if (@import("builtin").os.tag != .windows) {
        const root_dir = ".zig-cache/smoke-cli-colon-path";
        const temp_filename = root_dir ++ "/a:b.mjs";

        std.Io.Dir.cwd().deleteTree(std.testing.io, root_dir) catch {};
        defer std.Io.Dir.cwd().deleteTree(std.testing.io, root_dir) catch {};
        try std.Io.Dir.cwd().createDirPath(std.testing.io, root_dir);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{
            .sub_path = temp_filename,
            .data = "console.log(import.meta.url);\n",
        });

        const result = try std.process.run(allocator, std.testing.io, .{
            .argv = &[_][]const u8{ zjs_path, temp_filename },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try std.testing.expect(std.mem.startsWith(u8, result.stdout, "file:///"));
        try std.testing.expect(std.mem.endsWith(u8, result.stdout, "/smoke-cli-colon-path/a:b.mjs\n"));
        try std.testing.expectEqualStrings("", result.stderr);
    }
}

test "prepared method calls capture callee before argument side effects" {
    const allocator = std.testing.allocator;
    var zjs_path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedPath(&zjs_path_buf, build_options.zjs_executable_path);
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
    // Requires real opcode counting: release smoke runs this against the
    // zjs-profile artifact; the dev inner loop skips it explicitly (it
    // deliberately builds no ReleaseFast engine).
    if (!build_options.smoke_profile_checks) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var zjs_path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedPath(&zjs_path_buf, build_options.zjs_profile_executable_path);

    const cases = [_]ProfileCase{
        .{
            .name = "int_sum",
            .source = "let sum = 0; for (let i = 0; i < 2000; i++) sum += i; print(sum);",
            .expected_stdout_prefix = "1999000\n",
            .max_opcodes = 32000, // measured 30018 at recalibration
            .min_opcodes = 10000,
        },
        .{
            .name = "array_read",
            .source = "let tab = [3]; let sum = 0; for (let i = 0; i < 2000; i++) sum += tab[0]; print(sum);",
            .expected_stdout_prefix = "6000\n",
            .max_opcodes = 36000, // measured 34021 at recalibration
            .min_opcodes = 10000,
        },
        .{
            .name = "global_read_loop",
            .source = "var x = 1; let s = 0; for (let i = 0; i < 2000; i++) s += x; print(s);",
            .expected_stdout_prefix = "2000\n",
            .max_opcodes = 32000, // measured 30020 at recalibration
            .min_opcodes = 10000,
        },
        .{
            .name = "global_write_loop",
            .source = "\"use strict\"; var g = 0; for (let i = 0; i < 2000; i++) g = i; print(g);",
            .expected_stdout_prefix = "1999\n",
            .max_opcodes = 28000, // measured 26020 at recalibration
            .min_opcodes = 10000,
        },
        .{
            .name = "prop_read_mono",
            .source = "const o = { a: 1, b: 2, c: 3 }; let s = 0; for (let i = 0; i < 2000; i++) s += o.b; print(s);",
            .expected_stdout_prefix = "4000\n",
            .max_opcodes = 34000, // measured 32026 at recalibration
            .min_opcodes = 10000,
        },
        .{
            .name = "prop_read_poly3",
            .source = "const a = { x: 1, y: 0 }; const b = { y: 0, x: 2 }; const c = { z: 0, x: 3 }; const arr = [a, b, c]; let s = 0; for (let i = 0; i < 2000; i++) s += arr[i % 3].x; print(s);",
            .expected_stdout_prefix = "3999\n",
            .max_opcodes = 43000, // measured 40041 at recalibration
            .min_opcodes = 10000,
        },
        .{
            .name = "proto_read",
            .source = "const p = { x: 1 }; const o = Object.create(p); let s = 0; for (let i = 0; i < 2000; i++) s += o.x; print(s);",
            .expected_stdout_prefix = "2000\n",
            .max_opcodes = 34000, // measured 32027 at recalibration
            .min_opcodes = 10000,
        },
        .{
            .name = "func_call",
            .source = "function f(x) { return x + 1; } let s = 0; for (let i = 0; i < 40000; i++) s += f(i); print(s);",
            .expected_stdout_prefix = "800020000\n",
            .max_opcodes = 880000, // measured 840020 at recalibration
            .min_opcodes = 400000,
        },
        .{
            .name = "call2_loop",
            .source = "function f(a, b) { return a + b; } let s = 0; for (let i = 0; i < 40000; i++) s += f(i, 1); print(s);",
            .expected_stdout_prefix = "800020000\n",
            .max_opcodes = 924000, // measured 880020 at recalibration
            .min_opcodes = 400000,
        },
        .{
            .name = "closure_call_loop",
            .source = "function make(x) { return function(y) { return x + y; }; } const f = make(1); let s = 0; for (let i = 0; i < 40000; i++) s += f(i); print(s);",
            .expected_stdout_prefix = "800020000\n",
            .max_opcodes = 880000, // measured 840026 at recalibration
            .min_opcodes = 400000,
        },
        .{
            .name = "math_min",
            .source = "let s = 0; for (let i = 0; i < 40000; i++) s += Math.min(i, 500); print(s);",
            .expected_stdout_prefix = "19874750\n",
            .max_opcodes = 800000, // measured 760018 at recalibration
            .min_opcodes = 400000,
        },
        .{
            .name = "map_string_keys",
            .source = "const m = new Map(); for (let i = 0; i < 10000; i++) m.set(\"k\" + i, i); let s = 0; for (let i = 0; i < 10000; i++) s += m.get(\"k\" + i); print(s);",
            .expected_stdout_prefix = "49995000\n",
            .max_opcodes = 390000, // measured 370031 at recalibration
            .min_opcodes = 100000,
        },
    };

    for (cases) |case| {
        const result = try std.process.run(allocator, std.testing.io, .{
            .argv = &[_][]const u8{
                zjs_path,
                "--profile-opcodes",
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

        const opcodes = try profileOpcodeCount(result.stdout);
        try std.testing.expect(opcodes >= case.min_opcodes);
        try std.testing.expect(opcodes <= case.max_opcodes);
    }
}

fn parseBlockCensusRow(text: []const u8) ![14]u64 {
    var fields: [14]u64 = undefined;
    var tokens = std.mem.tokenizeScalar(u8, text, ' ');
    var index: usize = 0;
    while (tokens.next()) |token| : (index += 1) {
        try std.testing.expect(index < fields.len);
        fields[index] = try std.fmt.parseInt(u64, token, 10);
    }
    try std.testing.expectEqual(fields.len, index);
    return fields;
}

test "CLI nonempty block census rows reconcile with totals" {
    var path_buffer: [1024]u8 = undefined;
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{
            resolvedPath(&path_buffer, build_options.zjs_executable_path),       "--gc-stats", "--gc-block-census", "-e",
            "const a=[]; for(let i=0;i<5000;i++) a.push({i}); print(a.length);",
        },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "5000\n"));
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var sum: [14]u64 = @splat(0);
    var total: ?[14]u64 = null;
    var row_count: usize = 0;
    var last_cell_bytes: u64 = 0;
    while (lines.next()) |line| {
        const row_prefix = "gc: block census row ";
        const total_prefix = "gc: block census total ";
        if (std.mem.startsWith(u8, line, row_prefix)) {
            const row = try parseBlockCensusRow(line[row_prefix.len..]);
            try std.testing.expect(row[0] > last_cell_bytes);
            try std.testing.expect(row[1] > 0 and row[2] > 0);
            try std.testing.expect(row[3] <= row[2]);
            try std.testing.expectEqual(row[3] * 1000 / row[2], row[4]);
            try std.testing.expectEqual(row[1], row[5] + row[6] + row[7] + row[8]);
            for (row, 0..) |value, i| sum[i] += value;
            last_cell_bytes = row[0];
            row_count += 1;
        } else if (std.mem.startsWith(u8, line, total_prefix)) {
            try std.testing.expect(total == null);
            total = try parseBlockCensusRow(line[total_prefix.len..]);
        }
    }
    try std.testing.expect(row_count > 0 and total != null);
    const totals = total.?;
    try std.testing.expectEqual(@as(u64, 0), totals[0]);
    try std.testing.expect(totals[3] > 0);
    try std.testing.expectEqual(totals[3] * 1000 / totals[2], totals[4]);
    for (totals, 0..) |value, i| {
        if (i != 0 and i != 4) try std.testing.expectEqual(sum[i], value);
    }
}

test "zjs writes stdout at the shared file offset instead of overwriting it" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedPath(&path_buf, build_options.zjs_executable_path);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // One descriptor shared by the shell-like writer and both children, as
    // in `{ echo; zjs a.js; zjs b.js; } > out`.
    const out = try tmp.dir.createFile(io, "out.txt", .{ .read = true });
    defer out.close(io);
    try out.writeStreamingAll(io, "shell-line\n");
    for ([_][]const u8{ "print('first-longer-line')", "print('second')" }) |source| {
        var child = try std.process.spawn(io, .{
            .argv = &.{ zjs_path, "-e", source },
            .stdout = .{ .file = out },
        });
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
    }

    const written = try tmp.dir.readFileAlloc(io, "out.txt", allocator, .limited(1024));
    defer allocator.free(written);
    try std.testing.expectEqualStrings("shell-line\nfirst-longer-line\nsecond\n", written);
}

test "zjs lets an importer handle a rejection its dependency left unhandled" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedPath(&path_buf, build_options.zjs_executable_path);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "dep.mjs", .data = "globalThis.p = Promise.reject(new Error('x'));\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.mjs", .data = "import './dep.mjs'; console.log('main runs'); p.catch(e => console.log('handled', e.message));\n" });
    var main_path_buf: [256]u8 = undefined;
    const main_path = try std.fmt.bufPrint(&main_path_buf, ".zig-cache/tmp/{s}/main.mjs", .{tmp.sub_path});

    const result = try std.process.run(allocator, io, .{ .argv = &.{ zjs_path, "-m", main_path } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("main runs\nhandled x\n", result.stdout);
}

test "zjs keeps a failed JSON module import from breaking later imports" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedPath(&path_buf, build_options.zjs_executable_path);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.json", .data = "{ not json" });
    try tmp.dir.writeFile(io, .{ .sub_path = "z.mjs", .data = "export const z = 5;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.mjs", .data =
        \\try { await import('./bad.json', { with: { type: 'json' } }); } catch (e) { console.log('bad', e.name); }
        \\const m = await import('./z.mjs');
        \\console.log('z', m.z);
        \\
    });
    var main_path_buf: [256]u8 = undefined;
    const main_path = try std.fmt.bufPrint(&main_path_buf, ".zig-cache/tmp/{s}/main.mjs", .{tmp.sub_path});

    const result = try std.process.run(allocator, io, .{ .argv = &.{ zjs_path, "-m", main_path } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("bad SyntaxError\nz 5\n", result.stdout);
}

test "zjs re-imports a module whose JSON dependency failed with the same error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedPath(&path_buf, build_options.zjs_executable_path);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.json", .data = "{ not json" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.mjs", .data =
        \\import data from './bad.json' with { type: 'json' };
        \\console.log('a body runs');
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.mjs", .data =
        \\for (let i = 0; i < 3; i++) {
        \\  try { await import('./a.mjs'); console.log('loaded', i); } catch (e) { console.log('error', i, e.name); }
        \\}
        \\
    });
    var main_path_buf: [256]u8 = undefined;
    const main_path = try std.fmt.bufPrint(&main_path_buf, ".zig-cache/tmp/{s}/main.mjs", .{tmp.sub_path});

    const result = try std.process.run(allocator, io, .{ .argv = &.{ zjs_path, "-m", main_path } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("error 0 SyntaxError\nerror 1 SyntaxError\nerror 2 SyntaxError\n", result.stdout);
}

test "zjs loads a file whose name looks like a synthetic module tag as JavaScript" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedPath(&path_buf, build_options.zjs_executable_path);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "evil", .data = "hello" });
    try tmp.dir.writeFile(io, .{ .sub_path = "evil#type=text", .data = "export default 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.mjs", .data =
        \\import v from './evil#type=text';
        \\const d = await import('./evil#type=text');
        \\console.log(typeof v, typeof d.default);
        \\
    });
    var main_path_buf: [256]u8 = undefined;
    const main_path = try std.fmt.bufPrint(&main_path_buf, ".zig-cache/tmp/{s}/main.mjs", .{tmp.sub_path});

    const result = try std.process.run(allocator, io, .{ .argv = &.{ zjs_path, "-m", main_path } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("number number\n", result.stdout);
}

test "zjs runs a script whose file name is not UTF-8" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedPath(&path_buf, build_options.zjs_executable_path);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Error objects build their stack from the file name; it used to fail
    // strict UTF-8 decoding and replace every error with a URIError.
    try tmp.dir.writeFile(io, .{ .sub_path = "\xfd.js", .data =
        \\try { null.x; } catch (e) { print("caught", e.constructor.name); }
        \\print(new Error("e").stack.split("\n")[0].startsWith("    at <eval> ("));
        \\
    });
    var main_path_buf: [256]u8 = undefined;
    const main_path = try std.fmt.bufPrint(&main_path_buf, ".zig-cache/tmp/{s}/\xfd.js", .{tmp.sub_path});

    const result = try std.process.run(allocator, io, .{ .argv = &.{ zjs_path, "-s", main_path } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("caught TypeError\ntrue\n", result.stdout);
}

test "zjs keeps its exit status when stderr cannot be written" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedPath(&path_buf, build_options.zjs_executable_path);
    // Only an unwritable stdout exits like SIGPIPE (141).
    const cases = [_]struct { script: []const u8, status: u8 }{
        .{ .script = "exec \"$0\" missing-file.js 2>/dev/full", .status = 1 },
        .{ .script = "exec \"$0\" -e 'Promise.reject(1)' 2>/dev/full", .status = 1 },
        .{ .script = "exec \"$0\" 2>/dev/full", .status = 2 },
    };
    for (cases) |case| {
        const result = try std.process.run(allocator, io, .{ .argv = &.{ "sh", "-c", case.script, zjs_path } });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = case.status }, result.term);
    }
}

test "zjs --native-stack-size 0 still bounds native recursion by the thread stack" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedPath(&path_buf, build_options.zjs_executable_path);
    const result = try std.process.run(allocator, io, .{ .argv = &.{ zjs_path, "--native-stack-size", "0", "-e", "try { JSON.parse('['.repeat(1e7)); } catch (e) { print(e.constructor.name); }" } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("InternalError\n", result.stdout);
}

test "zjs accepts TypeScript export merging, typed using, default overloads and type-only re-exports" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedPath(&path_buf, build_options.zjs_executable_path);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "def.ts", .data =
        \\export default function (): number;
        \\export default function (a?: any) { return 3; }
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "side.ts", .data =
        \\console.log("side");
        \\export type X = number;
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.ts", .data =
        \\export { type X } from "./side.ts";
        \\import f from "./def.ts";
        \\export class Foo { x = 1 }
        \\export namespace Foo { export const tag = "ns"; export interface Opts {} }
        \\export function F() { return 1 }
        \\export namespace F { export const k = 2 }
        \\export namespace N { export const a = 1 }
        \\export namespace N { export const b = 2 }
        \\{ using x: { [Symbol.dispose](): void } = { [Symbol.dispose]() { console.log("disposed") } }; }
        \\const n: any = 5;
        \\console.log(new Foo().x, Foo.tag, F(), F.k, N.a, N.b, f(), n as number ** 2);
        \\
    });
    var main_path_buf: [256]u8 = undefined;
    const main_path = try std.fmt.bufPrint(&main_path_buf, ".zig-cache/tmp/{s}/main.ts", .{tmp.sub_path});

    const result = try std.process.run(allocator, io, .{ .argv = &.{ zjs_path, main_path } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqualStrings("side\ndisposed\n1 ns 1 2 1 2 3 25\n", result.stdout);
}

test "zjs rejects unsupported import attribute keys with SyntaxError" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedPath(&path_buf, build_options.zjs_executable_path);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "data.json", .data = "{\"a\":1}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "static.mjs", .data = "import d from './data.json' with { type: 'json', foo: 'x' };\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.mjs", .data =
        \\const name = (p) => p.then(() => 'ok', (e) => e.name);
        \\console.log(await name(import('./data.json', { with: { foo: 'x' } })),
        \\  await name(import('./data.json', { with: { foo: 1 } })),
        \\  await name(import('./static.mjs')),
        \\  (await import('./data.json', { with: { type: 'json' } })).default.a);
        \\
    });
    var main_path_buf: [256]u8 = undefined;
    const main_path = try std.fmt.bufPrint(&main_path_buf, ".zig-cache/tmp/{s}/main.mjs", .{tmp.sub_path});

    const result = try std.process.run(allocator, io, .{ .argv = &.{ zjs_path, "-m", main_path } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("SyntaxError TypeError SyntaxError 1\n", result.stdout);
}

test "zjs host globals convert arguments and print lone surrogates" {
    const allocator = std.testing.allocator;
    var path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedPath(&path_buf, build_options.zjs_executable_path);
    const source =
        \\const name = (f) => { try { return f(); } catch (e) { return e.name; } };
        \\print("a\ud800b", /😀a/u);
        \\print(btoa({ toString() { print("to-btoa"); return "x"; } }), atob({ toString() { print("to-atob"); return "YQ=="; } }), name(() => atob("Y\vQ==")), name(() => btoa()));
        \\print(new DOMException({ toString() { return "m"; } }).message);
    ;
    const result = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ zjs_path, "-e", source } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("a\u{FFFD}b /\u{1F600}a/u\nto-btoa\nto-atob\neA== a InvalidCharacterError TypeError\nm\n", result.stdout);
}

test "zjs reports thrown primitives and rejected primitives by value" {
    const allocator = std.testing.allocator;
    var path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedPath(&path_buf, build_options.zjs_executable_path);
    const Case = struct { source: []const u8, stderr: []const u8 };
    for ([_]Case{
        .{ .source = "throw 42", .stderr = "42\n" },
        .{ .source = "throw 'str'", .stderr = "str\n" },
        .{ .source = "throw Symbol('s')", .stderr = "Symbol(s)\n" },
        .{ .source = "Promise.reject(2.5)", .stderr = "Possibly unhandled promise rejection: 2.5\n" },
    }) |case| {
        const result = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ zjs_path, "-e", case.source } });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
        try std.testing.expectEqualStrings(case.stderr, result.stderr);
    }
}

test "zjs reports top-level engine errors as JS errors" {
    const allocator = std.testing.allocator;
    var path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedPath(&path_buf, build_options.zjs_executable_path);
    const Case = struct { argv: []const []const u8, stderr: []const u8 };
    for ([_]Case{
        .{ .argv = &.{ "-e", "10n / 0n" }, .stderr = "RangeError: BigInt division by zero\n    at <eval> (<eval>:1:5)\n" },
        .{ .argv = &.{ "-I", "missing-include.js", "-e", "1" }, .stderr = "zjs: unable to read missing-include.js: FileNotFound\n" },
    }) |case| {
        var argv: [8][]const u8 = undefined;
        argv[0] = zjs_path;
        @memcpy(argv[1..][0..case.argv.len], case.argv);
        const result = try std.process.run(allocator, std.testing.io, .{ .argv = argv[0 .. case.argv.len + 1] });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
        try std.testing.expectEqualStrings(case.stderr, result.stderr);
    }
}

test "zjs catches out-of-memory from literal creation" {
    const allocator = std.testing.allocator;
    var path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedPath(&path_buf, build_options.zjs_executable_path);
    for ([_][]const u8{ "a.push({ x: 1 })", "a.push([])" }) |step| {
        var source_buf: [128]u8 = undefined;
        const source = try std.fmt.bufPrint(&source_buf, "var a = []; try {{ for (;;) {s}; }} catch (e) {{ a = null; print(e.name); }}", .{step});
        const result = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ zjs_path, "--memory-limit", "2000", "-e", source } });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expectEqualStrings("InternalError\n", result.stdout);
    }
}

test "zjs host output keeps prints from user code run while printing or converting" {
    // console.error writes to stderr, but a print() from Error.prepareStackTrace
    // (run while formatting) belongs to stdout; DOMException's ToString
    // conversions print through the invocation's writer too.
    const allocator = std.testing.allocator;
    var path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedPath(&path_buf, build_options.zjs_executable_path);
    const source =
        \\Error.prepareStackTrace = () => { print("P"); return "S"; };
        \\console.error(new Error("x"));
        \\Error.prepareStackTrace = undefined;
        \\const o = { toString() { print("T"); return "m"; } };
        \\new DOMException(o, o);
    ;
    const result = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ zjs_path, "-e", source } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("P\nT\nT\n", result.stdout);
    try std.testing.expectEqualStrings("Error: x\nS\n", result.stderr);
}

test "zjs accepts --can-block with -e as its usage line advertises" {
    const allocator = std.testing.allocator;
    var path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedPath(&path_buf, build_options.zjs_executable_path);
    const result = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ zjs_path, "--can-block", "-e", "print(1)" } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("1\n", result.stdout);
}

test "zjs -s reports an implementation-limit compile error with its filename" {
    // The SyntaxError's filename is borrowed from the atom table, which
    // nothing roots once compilation returned; a 65,536-local function
    // collected it while the error was built and reported
    // "URIError: expecting hex digit" instead.
    const allocator = std.testing.allocator;
    var path_buf: [1024]u8 = undefined;
    const zjs_path = resolvedPath(&path_buf, build_options.zjs_executable_path);
    const root_dir = ".zig-cache/smoke-compile-limit";
    const script_path = root_dir ++ "/too_many_locals.js";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root_dir);

    var source = std.ArrayList(u8).empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "function f() {");
    for (0..65536) |i| try source.print(allocator, "var v{d};", .{i});
    try source.appendSlice(allocator, "}\n");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = script_path, .data = source.items });

    const result = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ zjs_path, "-s", script_path } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
    try std.testing.expect(std.mem.startsWith(u8, result.stderr, "SyntaxError: implementation limit exceeded"));
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "too_many_locals.js") != null);
}
