//! Public Runtime/Context/Value contract and host-facing eval behavior.
const std = @import("std");
const zjs = @import("zjs");

test "defineScriptArgs materializes empty array on first read" {
    const rt = try zjs.Runtime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    try ctx.defineScriptArgs(&.{"stale"});
    try ctx.defineScriptArgs(&.{});
    try ctx.defineScriptArgs(&.{});
    const result = try ctx.eval(
        \\var desc = Object.getOwnPropertyDescriptor(globalThis, "scriptArgs");
        \\desc.writable === true &&
        \\desc.enumerable === true &&
        \\desc.configurable === true &&
        \\Array.isArray(desc.value) &&
        \\desc.value.length === 0 &&
        \\Object.getPrototypeOf(scriptArgs) === Array.prototype &&
        \\(scriptArgs.push("ok"), scriptArgs.length === 1 && scriptArgs[0] === "ok") &&
        \\delete globalThis.scriptArgs &&
        \\!("scriptArgs" in globalThis);
    , .{});
    try std.testing.expectEqual(true, result.as(.boolean).?);
}

test "defineScriptArgs installs string items" {
    const rt = try zjs.Runtime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    try ctx.defineScriptArgs(&.{ "a.js", "--flag" });
    const result = try ctx.eval(
        \\Array.isArray(scriptArgs) &&
        \\scriptArgs.length === 2 &&
        \\scriptArgs[0] === "a.js" &&
        \\scriptArgs[1] === "--flag" &&
        \\Object.getPrototypeOf(scriptArgs) === Array.prototype;
    , .{});
    try std.testing.expectEqual(true, result.as(.boolean).?);
}

test "Context.toString performs ECMAScript ToString instead of tag assertion" {
    const rt = try zjs.Runtime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    const object = try ctx.eval("({ toString() { return 'semantic-string'; } })", .{});
    try std.testing.expect(object.asString() == null);

    const converted = try ctx.toString(object);
    try std.testing.expectEqualStrings("semantic-string", converted.asString().?.units().latin1);
}

test "Runtime create has one options entry and supports the default allocator" {
    const rt = try zjs.Runtime.create(.{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    try std.testing.expectEqual(@as(?i32, 42), (try ctx.eval("21 * 2", .{})).as(.int));
    try rt.runMicrotasks();
    try std.testing.expect(rt.memoryUsage().heap_bytes > 0);
}
