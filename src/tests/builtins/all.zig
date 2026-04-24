const std = @import("std");
const engine = @import("quickjs_zig_engine");

const builtins = engine.builtins;
const core = engine.core;
const libs = engine.libs;

test "support libraries cover unicode dtoa bignum and regexp basics" {
    try std.testing.expect(libs.unicode.isIdentifierStart('A'));
    try std.testing.expect(libs.unicode.isIdentifierContinue('9'));
    try std.testing.expectEqual(@as(u8, 'A'), libs.unicode.toUpperAscii('a'));
    try std.testing.expect(libs.unicode.equalsIgnoreAsciiCase("AbC", "aBc"));

    const n = try libs.dtoa.parseNumber("12.5");
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12.5", try libs.dtoa.formatNumber(&buf, n));

    const big = (try libs.bignum.parseBase10("40")).add(libs.bignum.BigInt.fromInt(2));
    try std.testing.expectEqual(@as(i128, 42), big.value);
    try std.testing.expectError(error.DivisionByZero, big.div(libs.bignum.BigInt.fromInt(0)));

    const program = try libs.regexp.compile("abc", .{ .ignore_case = true });
    const match = program.exec("xxAbCy").?;
    try std.testing.expectEqual(@as(usize, 2), match.start);
    try std.testing.expectEqual(@as(usize, 5), match.end);
}

test "intrinsic bootstrap registers global builtin domains through object properties" {
    const rt = try core.Runtime.create(std.testing.allocator);
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
}

test "object function array string number boolean symbol bigint math date json regexp error promise collections" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const obj = try builtins.object.create(rt, null);
    defer obj.value().free(rt);
    const key = try rt.internAtom("x");
    defer rt.atoms.free(key);
    try obj.defineOwnProperty(rt, key, core.Descriptor.data(core.Value.int32(1), true, true, true));
    const keys = try builtins.object.keys(rt, obj);
    defer core.Object.freeKeys(rt, keys);
    try std.testing.expectEqual(@as(usize, 1), keys.len);

    const this_value = core.Value.int32(7);
    try std.testing.expectEqual(@as(?i32, 7), builtins.function.applyReturnThis(this_value).asInt32());
    try std.testing.expect(builtins.array.isArrayIndex("42"));
    try std.testing.expectEqual(@as(u32, 43), builtins.array.lengthAfterSet(42, 1));

    var upper: [8]u8 = undefined;
    try std.testing.expectEqualStrings("ABC", builtins.string.toUpperAscii(&upper, "abc"));
    try std.testing.expectEqualStrings("b", builtins.string.charAt("abc", 1));
    try std.testing.expectEqual(@as(f64, 3.5), try builtins.number.parseFloat("3.5"));
    try std.testing.expectEqualStrings("false", builtins.boolean.toString(false));

    const sym = try rt.atoms.newSymbol("desc", .symbol);
    defer rt.atoms.free(sym);
    try std.testing.expectEqualStrings("desc", builtins.symbol.description(&rt.atoms, sym).?);

    try std.testing.expectEqual(@as(i128, 12), builtins.bigint.add(.{ .value = 5 }, .{ .value = 7 }).value);
    try std.testing.expectEqual(@as(f64, 2.0), builtins.math.abs(-2.0));
    try std.testing.expectEqual(@as(i64, 1), builtins.date.dayFromTime(builtins.date.ms_per_day));

    var json_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("42", try builtins.json.stringifyInt(&json_buf, 42));
    try std.testing.expectEqual(@as(i32, 42), try builtins.json.parseInt("42"));

    const re = try libs.regexp.compile("x", .{});
    try std.testing.expect(builtins.regexp.matches(re, "xyz"));
    try std.testing.expectEqualStrings("boom", builtins.error_.create("boom").message);
    try std.testing.expect(builtins.collection.sameValueZero(core.Value.int32(1), core.Value.int32(1)));
}

var promise_jobs: usize = 0;

fn countPromiseJob() void {
    promise_jobs += 1;
}

test "promise buffers reflect proxy iterator and atomics helpers" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    promise_jobs = 0;
    try builtins.promise.enqueueReaction(&js.job_queue, countPromiseJob);
    js.runJobs();
    try std.testing.expectEqual(@as(usize, 1), promise_jobs);

    var bytes = [_]u8{ 1, 2, 3 };
    var buffer = builtins.buffer.ArrayBuffer{ .bytes = &bytes };
    try std.testing.expectEqual(@as(usize, 3), buffer.byteLength());
    buffer.detach();
    try std.testing.expectEqual(@as(usize, 0), buffer.byteLength());

    var proxy = builtins.reflect_proxy.RevocableProxy{};
    proxy.revoke();
    try std.testing.expect(proxy.revoked);

    var index: usize = 0;
    try std.testing.expectEqual(@as(usize, 0), builtins.iterator.next(&index, 2).value_index);
    try std.testing.expect(!builtins.iterator.next(&index, 2).done);
    try std.testing.expect(builtins.iterator.next(&index, 2).done);
    try std.testing.expect(builtins.atomics.isLockFree(4));
    try std.testing.expect(!builtins.atomics.isLockFree(3));
}
