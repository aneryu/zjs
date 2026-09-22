const std = @import("std");
const engine = @import("engine");
test "wiring proof: one Runtime type and immutable per-engine hooks" {
    comptime {
        if (engine.Runtime != engine.core.Runtime) @compileError("Runtime identity split");
    }
    const a = try engine.Runtime.create(std.testing.allocator, 4);
    defer a.destroy();
    const b = try engine.Runtime.create(std.testing.allocator, 9);
    defer b.destroy();
    try std.testing.expect(a != b);
    try std.testing.expect(a.hooks == b.hooks);
    try std.testing.expectEqual(@as(usize, 5), a.hooks.invoke(a));
    try std.testing.expectEqual(@as(usize, 10), b.hooks.invoke(b));
}
