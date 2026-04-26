const std = @import("std");
const engine = @import("quickjs_zig_engine");

test "QuickJS source baseline is recorded" {
    try std.testing.expectEqualStrings(
        "64e64ebb1dd61505c256285a699c65c42941c5ed",
        engine.source.quickjs_commit,
    );
    try std.testing.expect(engine.source.hasReferenceFile("quickjs/quickjs.c"));
    try std.testing.expect(engine.source.hasReferenceFile("quickjs/libregexp.c"));
    try std.testing.expect(engine.source.hasReferenceFile("quickjs/libunicode.c"));
    try std.testing.expect(engine.source.hasReferenceFile("quickjs/dtoa.c"));
    try std.testing.expect(engine.source.hasReferenceFile("quickjs/qjs.c"));
    try std.testing.expect(engine.source.hasReferenceFile("quickjs/run-test262.c"));
    try std.testing.expect(engine.source.excluded_components.len >= 5);
}

test "all status records have source ownership" {
    try std.testing.expect(engine.status.records.len == engine.status.subsystemCount());
    for (engine.status.records) |record| {
        try std.testing.expect(record.zig_paths.len > 0);
        try std.testing.expect(record.quickjs_sources.len > 0);
        try std.testing.expect(record.hasSourceMapping());
    }
}

test "active statuses require source mappings" {
    try std.testing.expect(engine.status.activeRecordsHaveMappings());
}

test "semantic complete statuses do not mask known architecture gaps" {
    for (engine.status.records) |record| {
        if (record.state == .semantic_complete) {
            try std.testing.expect(!engine.status.hasKnownSemanticGap(record.subsystem));
        }
    }
}

test "bootstrap root exposes only metadata and empty namespaces" {
    try std.testing.expectEqualStrings("core_runtime", engine.core.subsystem_name);
    try std.testing.expectEqualStrings("frontend", engine.frontend.subsystem_name);
    try std.testing.expectEqualStrings("bytecode", engine.bytecode.subsystem_name);
    try std.testing.expectEqualStrings("exec", engine.exec.subsystem_name);
    try std.testing.expectEqualStrings("builtins", engine.builtins.subsystem_name);
    try std.testing.expectEqualStrings("libs", engine.libs.subsystem_name);
}
