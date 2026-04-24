const std = @import("std");
const engine = @import("quickjs_zig_engine");

test "QuickJS source baseline is recorded" {
    try std.testing.expectEqualStrings(
        "64e64ebb1dd61505c256285a699c65c42941c5ed",
        engine.source.quickjs_commit,
    );
    try std.testing.expect(engine.source.included_reference_files.len >= 15);
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

test "validated statuses require source mappings" {
    try std.testing.expect(engine.status.validatedRecordsHaveMappings());
}

test "bootstrap root exposes only metadata and empty namespaces" {
    try std.testing.expectEqualStrings("core_runtime", engine.core.subsystem_name);
    try std.testing.expectEqualStrings("frontend", engine.frontend.subsystem_name);
    try std.testing.expectEqualStrings("bytecode", engine.bytecode.subsystem_name);
    try std.testing.expectEqualStrings("exec", engine.exec.subsystem_name);
    try std.testing.expectEqualStrings("builtins", engine.builtins.subsystem_name);
    try std.testing.expectEqualStrings("libs", engine.libs.subsystem_name);
}
