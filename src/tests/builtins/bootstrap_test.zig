const std = @import("std");
const engine = @import("quickjs_zig_engine");
const helpers = @import("helpers.zig");

const builtins = engine.builtins;
const core = engine.core;
const exec = engine.exec;

test "intrinsic bootstrap registers global builtin domains through object properties" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var intrinsics = try builtins.Intrinsics.init(rt);
    defer intrinsics.deinit(rt);

    for (builtins.domains) |name| {
        const atom_id = try rt.internAtom(name);
        defer rt.atoms.free(atom_id);
        try std.testing.expect(intrinsics.global.hasOwnProperty(atom_id));
        const desc = intrinsics.global.getOwnProperty(atom_id).?;
        defer desc.destroy(rt);
        try std.testing.expectEqual(true, desc.writable.?);
        try std.testing.expectEqual(false, desc.enumerable.?);
        try std.testing.expectEqual(true, desc.configurable.?);
    }

    const map_atom = try rt.internAtom("Map");
    defer rt.atoms.free(map_atom);
    const map_ctor = intrinsics.global.getProperty(map_atom);
    defer map_ctor.free(rt);
    try helpers.expectObjectClass(map_ctor, core.class.ids.c_function);
    const map_ctor_object: *core.Object = @fieldParentPtr("header", map_ctor.refHeader().?);
    const prototype_atom = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_atom);
    const prototype_desc = map_ctor_object.getOwnProperty(prototype_atom).?;
    defer prototype_desc.destroy(rt);
    try std.testing.expectEqual(false, prototype_desc.writable.?);
    try std.testing.expectEqual(false, prototype_desc.enumerable.?);
    try std.testing.expectEqual(false, prototype_desc.configurable.?);
    try helpers.expectObjectClass(prototype_desc.value, core.class.ids.object);
    const map_proto: *core.Object = @fieldParentPtr("header", prototype_desc.value.refHeader().?);
    const set_atom = try rt.internAtom("set");
    defer rt.atoms.free(set_atom);
    const set_desc = map_proto.getOwnProperty(set_atom).?;
    defer set_desc.destroy(rt);
    try std.testing.expectEqual(true, set_desc.writable.?);
    try std.testing.expectEqual(false, set_desc.enumerable.?);
    try std.testing.expectEqual(true, set_desc.configurable.?);
    try helpers.expectObjectClass(set_desc.value, core.class.ids.c_function);
}

test "host global bootstrap installs and tears down builtin plus host domains" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    global.is_global = true;
    defer global.value().free(rt);

    try exec.call.installHostGlobals(rt, global);
}

test "engine eval host globals and throw intrinsic tear down cleanly" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const value = try js.evalWithOutput("print(1);", &output);
    defer value.free(js.runtime);

    try std.testing.expect(value.isUndefined());
    try std.testing.expectEqualStrings("1\n", output.buffered());
}

var promise_jobs: usize = 0;

fn countPromiseJob(_: *core.JSContext, args: []const core.JSValue) core.JSValue {
    promise_jobs += 1;
    if (args.len >= 1) promise_jobs += @intCast(args[0].asInt32().?);
    return core.JSValue.undefinedValue();
}

test "promise enqueues reactions and executes jobs via engine" {
    var js = try engine.harness.Engine.init(std.testing.allocator);
    defer js.deinit();

    promise_jobs = 0;
    try builtins.promise.enqueueReaction(js.context, countPromiseJob, &.{core.JSValue.int32(2)});
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 3), promise_jobs);
}
