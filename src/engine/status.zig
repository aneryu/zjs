const source = @import("source.zig");
const std = @import("std");

pub const PortState = enum {
    not_started,
    in_progress,
    source_mapped,
    fixture_validated,
    baseline_validated,
    semantic_complete,
    out_of_scope,
};

pub const Subsystem = enum {
    source_baseline,
    core_runtime,
    object_property,
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
        .state = .semantic_complete,
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
        .state = .fixture_validated,
        .zig_paths = &.{"src/engine/core"},
        .quickjs_sources = &.{ "quickjs/quickjs.c", "quickjs/quickjs.h", "quickjs/list.h" },
    },
    .{
        .subsystem = .object_property,
        .phase = 3,
        .state = .fixture_validated,
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
        .subsystem = .frontend,
        .phase = 5,
        .state = .baseline_validated,
        .zig_paths = &.{
            "src/engine/frontend/token.zig",
            "src/engine/frontend/lexer.zig",
            "src/engine/frontend/parser.zig",
            "src/engine/frontend/regexp_literal.zig",
            "src/engine/frontend/source_pos.zig",
            "src/engine/bytecode/emitter.zig",
        },
        .quickjs_sources = &.{ "quickjs/quickjs.c", "quickjs/libregexp.c" },
    },
    .{
        .subsystem = .bytecode,
        .phase = 4,
        .state = .fixture_validated,
        .zig_paths = &.{
            "src/engine/bytecode/opcode.zig",
            "src/engine/bytecode/format.zig",
            "src/engine/bytecode/function.zig",
            "src/engine/bytecode/constant.zig",
            "src/engine/bytecode/scope.zig",
            "src/engine/bytecode/module.zig",
            "src/engine/bytecode/debug.zig",
        },
        .quickjs_sources = &.{ "quickjs/quickjs.c", "quickjs/quickjs-opcode.h" },
    },
    .{
        .subsystem = .exec,
        .phase = 6,
        .state = .baseline_validated,
        .zig_paths = &.{
            "src/engine/exec/vm.zig",
            "src/engine/exec/frame.zig",
            "src/engine/exec/stack.zig",
            "src/engine/exec/call.zig",
            "src/engine/exec/construct.zig",
            "src/engine/exec/property_ops.zig",
            "src/engine/exec/exceptions.zig",
            "src/engine/exec/iterator.zig",
            "src/engine/exec/eval.zig",
            "src/engine/exec/module.zig",
            "src/engine/exec/promise.zig",
            "src/engine/exec/jobs.zig",
            "src/engine/exec/value_ops.zig",
            "src/engine/exec/globals.zig",
            "src/engine/exec/closure.zig",
            "src/engine/exec/test262_helpers.zig",
        },
        .quickjs_sources = &.{ "quickjs/quickjs.c", "quickjs/quickjs-opcode.h" },
    },
    .{
        .subsystem = .builtins,
        .phase = 7,
        .state = .fixture_validated,
        .zig_paths = &.{ "src/engine/builtins", "src/engine/libs" },
        .quickjs_sources = &.{ "quickjs/quickjs.c", "quickjs/libregexp.c", "quickjs/dtoa.c" },
    },
    .{
        .subsystem = .libs,
        .phase = 7,
        .state = .fixture_validated,
        .zig_paths = &.{"src/engine/libs"},
        .quickjs_sources = &.{ "quickjs/libregexp.c", "quickjs/libunicode.c", "quickjs/quickjs.c", "quickjs/dtoa.c" },
    },
    .{
        .subsystem = .cli_tooling,
        .phase = 8,
        .state = .baseline_validated,
        .zig_paths = &.{ "src/cli", "src/tools" },
        .quickjs_sources = &.{ "quickjs/qjs.c", "quickjs/run-test262.c", "quickjs/test262.conf" },
    },
};

pub fn recordFor(subsystem: Subsystem) ?SubsystemStatus {
    for (records) |record| {
        if (record.subsystem == subsystem) return record;
    }
    return null;
}

pub fn activeRecordsHaveMappings() bool {
    for (records) |record| {
        if (requiresSourceMapping(record.state) and !record.hasSourceMapping()) return false;
    }
    return true;
}

pub fn validatedRecordsHaveMappings() bool {
    return activeRecordsHaveMappings();
}

pub fn requiresSourceMapping(state: PortState) bool {
    return switch (state) {
        .not_started, .out_of_scope => false,
        .in_progress, .source_mapped, .fixture_validated, .baseline_validated, .semantic_complete => true,
    };
}

pub fn hasKnownSemanticGap(subsystem: Subsystem) bool {
    return switch (subsystem) {
        .core_runtime,
        .frontend,
        .exec,
        .builtins,
        .libs,
        => true,
        .source_baseline,
        .object_property,
        .bytecode,
        .cli_tooling,
        => false,
    };
}

pub fn stateName(state: PortState) []const u8 {
    return @tagName(state);
}

pub fn subsystemCount() usize {
    return records.len;
}

test "active status cannot exist without QuickJS source mapping" {
    try std.testing.expect(activeRecordsHaveMappings());
}

test "semantic complete status cannot hide known architecture gaps" {
    for (records) |record| {
        if (record.state == .semantic_complete) {
            try std.testing.expect(!hasKnownSemanticGap(record.subsystem));
        }
    }
}
