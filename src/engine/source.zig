const std = @import("std");

pub const quickjs_commit = "64e64ebb1dd61505c256285a699c65c42941c5ed";

pub const ReferenceRole = enum {
    core_engine,
    support_library,
    validation_tooling,
};

pub const ReferenceFile = struct {
    path: []const u8,
    role: ReferenceRole,
};

pub const included_reference_files = [_]ReferenceFile{
    .{ .path = "quickjs/quickjs.c", .role = .core_engine },
    .{ .path = "quickjs/quickjs.h", .role = .core_engine },
    .{ .path = "quickjs/quickjs-opcode.h", .role = .core_engine },
    .{ .path = "quickjs/quickjs-atom.h", .role = .core_engine },
    .{ .path = "quickjs/list.h", .role = .support_library },
    .{ .path = "quickjs/cutils.h", .role = .support_library },
    .{ .path = "quickjs/libregexp.c", .role = .support_library },
    .{ .path = "quickjs/libregexp-opcode.h", .role = .support_library },
    .{ .path = "quickjs/libunicode.c", .role = .support_library },
    .{ .path = "quickjs/libunicode-table.h", .role = .support_library },
    .{ .path = "quickjs/libbf.c", .role = .support_library },
    .{ .path = "quickjs/libbf.h", .role = .support_library },
    .{ .path = "quickjs/dtoa.c", .role = .support_library },
    .{ .path = "quickjs/run-test262.c", .role = .validation_tooling },
    .{ .path = "quickjs/test262.conf", .role = .validation_tooling },
};

pub const excluded_components = [_][]const u8{
    "qjsc",
    "quickjs-libc",
    "QuickJS std module",
    "QuickJS os module",
    "Full QuickJS C ABI compatibility",
};

pub const SourceMapping = struct {
    subsystem: []const u8,
    zig_paths: []const []const u8,
    quickjs_sources: []const []const u8,
};

pub const source_mappings = [_]SourceMapping{
    .{
        .subsystem = "source_baseline",
        .zig_paths = &.{ "src/engine/source.zig", "src/engine/status.zig" },
        .quickjs_sources = &.{
            "quickjs/quickjs.c",
            "quickjs/quickjs.h",
            "quickjs/quickjs-opcode.h",
            "quickjs/quickjs-atom.h",
            "quickjs/list.h",
            "quickjs/cutils.h",
            "quickjs/libregexp.c",
            "quickjs/libunicode.c",
            "quickjs/libbf.c",
            "quickjs/dtoa.c",
            "quickjs/run-test262.c",
            "quickjs/test262.conf",
        },
    },
    .{
        .subsystem = "core_runtime",
        .zig_paths = &.{"src/engine/core"},
        .quickjs_sources = &.{ "quickjs/quickjs.c", "quickjs/quickjs.h", "quickjs/list.h" },
    },
    .{
        .subsystem = "object_property",
        .zig_paths = &.{
            "src/engine/core/object.zig",
            "src/engine/core/property.zig",
            "src/engine/core/descriptor.zig",
            "src/engine/core/array.zig",
            "src/engine/core/shape.zig",
        },
        .quickjs_sources = &.{ "quickjs/quickjs.c", "quickjs/quickjs.h" },
    },
    .{
        .subsystem = "frontend",
        .zig_paths = &.{"src/engine/frontend"},
        .quickjs_sources = &.{ "quickjs/quickjs.c", "quickjs/libregexp.c" },
    },
    .{
        .subsystem = "bytecode",
        .zig_paths = &.{"src/engine/bytecode"},
        .quickjs_sources = &.{ "quickjs/quickjs.c", "quickjs/quickjs-opcode.h" },
    },
    .{
        .subsystem = "exec",
        .zig_paths = &.{"src/engine/exec"},
        .quickjs_sources = &.{ "quickjs/quickjs.c", "quickjs/quickjs-opcode.h" },
    },
    .{
        .subsystem = "builtins",
        .zig_paths = &.{"src/engine/builtins"},
        .quickjs_sources = &.{ "quickjs/quickjs.c", "quickjs/libregexp.c", "quickjs/libbf.c", "quickjs/dtoa.c" },
    },
    .{
        .subsystem = "libs",
        .zig_paths = &.{"src/engine/libs"},
        .quickjs_sources = &.{ "quickjs/libregexp.c", "quickjs/libunicode.c", "quickjs/libbf.c", "quickjs/dtoa.c" },
    },
    .{
        .subsystem = "cli_tooling",
        .zig_paths = &.{ "src/cli", "src/tools" },
        .quickjs_sources = &.{ "quickjs/run-test262.c", "quickjs/test262.conf" },
    },
};

pub fn hasMappingFor(subsystem: []const u8) bool {
    for (source_mappings) |mapping| {
        if (std.mem.eql(u8, mapping.subsystem, subsystem)) return true;
    }
    return false;
}
