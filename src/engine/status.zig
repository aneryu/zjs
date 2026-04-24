const source = @import("source.zig");
const std = @import("std");

pub const PortState = enum {
    not_started,
    in_progress,
    validated,
    out_of_scope,
};

pub const Subsystem = enum {
    source_baseline,
    core_runtime,
    frontend,
    bytecode,
    exec,
    builtins,
    libs,
    cli_tooling,
};

pub const SubsystemStatus = struct {
    subsystem: Subsystem,
    phase: u8,
    state: PortState,
    zig_paths: []const []const u8,
    quickjs_sources: []const []const u8,

    pub fn subsystemName(self: SubsystemStatus) []const u8 {
        return @tagName(self.subsystem);
    }

    pub fn hasSourceMapping(self: SubsystemStatus) bool {
        return self.quickjs_sources.len > 0 and source.hasMappingFor(self.subsystemName());
    }
};

pub const records = [_]SubsystemStatus{
    .{
        .subsystem = .source_baseline,
        .phase = 1,
        .state = .validated,
        .zig_paths = &.{ "src/engine/source.zig", "src/engine/status.zig" },
        .quickjs_sources = &.{
            "quickjs/quickjs.c",
            "quickjs/quickjs.h",
            "quickjs/quickjs-opcode.h",
            "quickjs/quickjs-atom.h",
        },
    },
    .{
        .subsystem = .core_runtime,
        .phase = 2,
        .state = .validated,
        .zig_paths = &.{"src/engine/core"},
        .quickjs_sources = &.{ "quickjs/quickjs.c", "quickjs/quickjs.h", "quickjs/list.h" },
    },
    .{
        .subsystem = .frontend,
        .phase = 5,
        .state = .not_started,
        .zig_paths = &.{"src/engine/frontend"},
        .quickjs_sources = &.{ "quickjs/quickjs.c", "quickjs/libregexp.c" },
    },
    .{
        .subsystem = .bytecode,
        .phase = 4,
        .state = .not_started,
        .zig_paths = &.{"src/engine/bytecode"},
        .quickjs_sources = &.{ "quickjs/quickjs.c", "quickjs/quickjs-opcode.h" },
    },
    .{
        .subsystem = .exec,
        .phase = 6,
        .state = .not_started,
        .zig_paths = &.{"src/engine/exec"},
        .quickjs_sources = &.{ "quickjs/quickjs.c", "quickjs/quickjs-opcode.h" },
    },
    .{
        .subsystem = .builtins,
        .phase = 7,
        .state = .not_started,
        .zig_paths = &.{"src/engine/builtins"},
        .quickjs_sources = &.{ "quickjs/quickjs.c", "quickjs/libregexp.c", "quickjs/libbf.c", "quickjs/dtoa.c" },
    },
    .{
        .subsystem = .libs,
        .phase = 7,
        .state = .not_started,
        .zig_paths = &.{"src/engine/libs"},
        .quickjs_sources = &.{ "quickjs/libregexp.c", "quickjs/libunicode.c", "quickjs/libbf.c", "quickjs/dtoa.c" },
    },
    .{
        .subsystem = .cli_tooling,
        .phase = 8,
        .state = .not_started,
        .zig_paths = &.{ "src/cli", "src/tools" },
        .quickjs_sources = &.{ "quickjs/run-test262.c", "quickjs/test262.conf" },
    },
};

pub fn recordFor(subsystem: Subsystem) ?SubsystemStatus {
    for (records) |record| {
        if (record.subsystem == subsystem) return record;
    }
    return null;
}

pub fn validatedRecordsHaveMappings() bool {
    for (records) |record| {
        if (record.state == .validated and !record.hasSourceMapping()) return false;
    }
    return true;
}

pub fn stateName(state: PortState) []const u8 {
    return @tagName(state);
}

pub fn subsystemCount() usize {
    return records.len;
}

test "validated status cannot exist without QuickJS source mapping" {
    try std.testing.expect(validatedRecordsHaveMappings());
}
