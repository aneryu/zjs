//! Core integration tests: value_boundary.
const std = @import("std");
const zjs = @import("zjs");
const core = zjs.core;

test "value boundary array length conversion does not materialize rope" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const array = try roots.ref(0);
    const input = try roots.ref(1);
    const right = try roots.ref(2);
    try array.set(rt, (try core.Object.createArray(rt, null)).value());
    try input.set(rt, (try core.string.String.createAscii(rt, "2")).value());
    try right.set(rt, (try core.string.String.createAscii(rt, "3")).value());
    try input.set(rt, (try core.string.String.createRope(rt, try input.get(rt), try right.get(rt))).value());
    const object = core.Object.fromHeader((try array.get(rt)).refHeader().?);
    try object.defineOwnProperty(rt, core.atom.ids.length, .{ .value = try input.get(rt), .value_present = true });
    try std.testing.expectEqual(@as(u32, 23), object.arrayLength());
    try std.testing.expect(!(try input.get(rt)).ropeBody().?.isLinearized());
}

test "value boundary array length preserves conversion and OOM state across leaves" {
    const cases = [_]struct { units: []const u16, length: ?u32 }{
        .{ .units = &.{ ' ', '0', 'x', '1', '0', ' ' }, .length = 16 },
        .{ .units = &.{ '1', 'e', '2' }, .length = 100 },
        .{ .units = &.{ '-', '0' }, .length = 0 },
        .{ .units = &.{}, .length = 0 },
        .{ .units = &.{ '4', '2', '9', '4', '9', '6', '7', '2', '9', '5' }, .length = 4294967295 },
        .{ .units = &.{ '4', '2', '9', '4', '9', '6', '7', '2', '9', '6' }, .length = null },
        .{ .units = &.{ '3', '.', '5' }, .length = null },
        .{ .units = &.{ 'N', 'a', 'N' }, .length = null },
        .{ .units = &.{ '1', 0 }, .length = null },
        .{ .units = &.{ '1', 0x100 }, .length = null },
    };
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(4){};
    try roots.activate(rt);
    defer roots.deactivate();
    const array = try roots.ref(0);
    const input = try roots.ref(1);
    const right = try roots.ref(2);
    const wrapper = try roots.ref(3);
    try array.set(rt, (try core.Object.createArray(rt, null)).value());
    try wrapper.set(rt, (try core.Object.create(rt, core.class.ids.string, null)).value());
    for (cases) |case| {
        for (0..case.units.len + 1) |split| {
            for ([_]bool{ false, true }) |cached| {
                try input.set(rt, (try core.string.String.createUtf16(rt, case.units[0..split])).value());
                try right.set(rt, (try core.string.String.createUtf16(rt, case.units[split..])).value());
                try input.set(rt, (try core.string.String.createRope(rt, try input.get(rt), try right.get(rt))).value());
                if (cached) try core.string.ensureFlat(rt, input.readOnly(), right);
                const boxed = core.Object.fromHeader((try wrapper.get(rt)).refHeader().?);
                try boxed.setOptionalValueSlot(rt, boxed.objectDataSlot(), try input.get(rt));
                rt.setMemoryLimit(0);
                defer rt.setMemoryLimit(null);
                const native_before = rt.allocation_diagnostics.allocated_bytes;
                const epoch = rt.gc.collection_epoch;
                var borrow = core.runtime.NoGcScope{};
                borrow.activate(rt);
                defer borrow.deactivate();
                for ([_]core.JSValue{ try input.get(rt), try wrapper.get(rt) }) |value| {
                    const object = core.Object.fromHeader((try array.get(rt)).refHeader().?);
                    object.setArrayLength(7);
                    rt.setNativeBytesLimitForTest(native_before);
                    defer rt.setNativeBytesLimitForTest(null);
                    if (case.units.len != 0) {
                        try std.testing.expectError(error.OutOfMemory, object.defineOwnProperty(rt, core.atom.ids.length, .{ .value = value, .value_present = true }));
                        try std.testing.expectEqual(@as(u32, 7), object.arrayLength());
                    }
                    rt.setNativeBytesLimitForTest(null);
                    const result = object.defineOwnProperty(rt, core.atom.ids.length, .{ .value = value, .value_present = true });
                    if (case.length) |length| {
                        try result;
                        try std.testing.expectEqual(length, object.arrayLength());
                    } else {
                        try std.testing.expectError(error.InvalidArrayLength, result);
                        try std.testing.expectEqual(@as(u32, 7), object.arrayLength());
                    }
                }
                try std.testing.expectEqual(cached, (try input.get(rt)).ropeBody().?.isLinearized());
                try std.testing.expectEqual(epoch, rt.gc.collection_epoch);
                try std.testing.expectEqual(native_before, rt.allocation_diagnostics.allocated_bytes);
            }
        }
    }
}

test "value boundary URI probe does not materialize rope input" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(2){};
    try roots.activate(rt);
    defer roots.deactivate();
    const input = try roots.ref(0);
    const right = try roots.ref(1);
    try input.set(rt, (try core.string.String.createAscii(rt, "%F0%9F")).value());
    try right.set(rt, (try core.string.String.createAscii(rt, "%98%80")).value());
    try input.set(rt, (try core.string.String.createRope(rt, try input.get(rt), try right.get(rt))).value());
    const pair = core.uri.decodeSingleFourByteEscapeUnits(try input.get(rt)).?;
    try std.testing.expectEqual(@as(u16, 0xd83d), pair.high);
    try std.testing.expectEqual(@as(u16, 0xde00), pair.low);
    try std.testing.expect(!(try input.get(rt)).ropeBody().?.isLinearized());
}

test "value boundary URI probe preserves grammar across rope leaves without allocation" {
    const cases = [_][]const u8{
        "%F0%9F%98%80", "%F0%90%80%80", "%F4%8F%BF%BF", "%f0%9f%98%80",
        "%F0%80%80%80", "%F4%90%80%80", "%F5%80%80%80", "%F0%41%80%80",
        "%F0%9G%98%80", "%E0%A0%80%80", "%F0%9F%98",    "%F0%9F%98%80x",
        "",
    };
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(2){};
    try roots.activate(rt);
    defer roots.deactivate();
    const input = try roots.ref(0);
    const right = try roots.ref(1);
    for (cases) |bytes| {
        for (0..bytes.len + 1) |split| {
            for ([_]bool{ false, true }) |cached| {
                try input.set(rt, (try core.string.String.createAscii(rt, bytes[0..split])).value());
                try right.set(rt, (try core.string.String.createAscii(rt, bytes[split..])).value());
                try input.set(rt, (try core.string.String.createRope(rt, try input.get(rt), try right.get(rt))).value());
                if (cached) try core.string.ensureFlat(rt, input.readOnly(), right);
                rt.setMemoryLimit(0);
                defer rt.setMemoryLimit(null);
                rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
                defer rt.setNativeBytesLimitForTest(null);
                const epoch = rt.gc.collection_epoch;
                var borrow = core.runtime.NoGcScope{};
                borrow.activate(rt);
                defer borrow.deactivate();
                const expected = core.uri.decodeSingleFourByteEscapeUnitsFromAscii(bytes);
                const actual = core.uri.decodeSingleFourByteEscapeUnits(try input.get(rt));
                try std.testing.expectEqualDeep(expected, actual);
                try std.testing.expectEqual(cached, (try input.get(rt)).ropeBody().?.isLinearized());
                try std.testing.expectEqual(epoch, rt.gc.collection_epoch);
            }
        }
    }
    try std.testing.expectEqual(@as(?core.uri.FourByteEscapeUnits, null), core.uri.decodeSingleFourByteEscapeUnits(core.JSValue.int32(12)));
}

test "value boundary truthiness reads rope length without materialization" {
    const samples = [_][]const u16{ &.{}, &.{0}, &.{0xd800} };
    for (samples) |units| {
        for (0..3) |mode| {
            const rt = try core.JSRuntime.create(std.testing.allocator, .{});
            defer rt.destroy();
            var roots = core.runtime.ExactValueRoots(2){};
            try roots.activate(rt);
            defer roots.deactivate();
            const input = try roots.ref(0);
            const temporary = try roots.ref(1);
            try input.set(rt, (try core.string.String.createUtf16(rt, units)).value());
            if (mode != 0) {
                try temporary.set(rt, (try core.string.String.createAscii(rt, "")).value());
                try input.set(rt, (try core.string.String.createRope(rt, try input.get(rt), try temporary.get(rt))).value());
                if (mode == 2) try core.string.ensureFlat(rt, input.readOnly(), temporary);
            }
            rt.setMemoryLimit(0);
            rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
            defer rt.setNativeBytesLimitForTest(null);
            const epoch = rt.gc.collection_epoch;
            var borrow = core.runtime.NoGcScope{};
            borrow.activate(rt);
            defer borrow.deactivate();
            try std.testing.expectEqual(units.len != 0, core.value_semantics.toBoolean(try input.get(rt)));
            try std.testing.expectEqual(epoch, rt.gc.collection_epoch);
            if (mode != 0) try std.testing.expectEqual(mode == 2, (try input.get(rt)).ropeBody().?.isLinearized());
        }
    }
}

test "value boundary number parsers do not materialize rope input" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(2){};
    try roots.activate(rt);
    defer roots.deactivate();
    const input = try roots.ref(0);
    const right = try roots.ref(1);
    for ([_]bool{ false, true }) |integer| {
        try input.set(rt, (try core.string.String.createAscii(rt, "12")).value());
        try right.set(rt, (try core.string.String.createAscii(rt, ".5tail")).value());
        try input.set(rt, (try core.string.String.createRope(rt, try input.get(rt), try right.get(rt))).value());
        const number = if (integer) try core.number.parseIntValue(rt, try input.get(rt), null) else try core.number.parseFloatValue(rt, try input.get(rt));
        try std.testing.expectEqual(@as(f64, if (integer) 12 else 12.5), number);
        try std.testing.expect(!(try input.get(rt)).ropeBody().?.isLinearized());
    }
}

test "value boundary number parsing preserves prefixes and whitespace across leaves" {
    const Case = struct { units: []const u16, radix: i32 = 0, integer: f64, float: f64 };
    const cases = [_]Case{
        .{ .units = &.{ 0xa0, '1', '2', '.', '5', 'e', '1', 'x' }, .integer = 12, .float = 125 },
        .{ .units = &.{ 0x3000, '-', '0', 'x', 'f', 'f', 'z' }, .integer = -255, .float = -0.0 },
        .{ .units = &.{ 0xfeff, 'I', 'n', 'f', 'i', 'n', 'i', 't', 'y' }, .integer = std.math.nan(f64), .float = std.math.inf(f64) },
        .{ .units = &.{ '9', '0', '0', '7', '1', '9', '9', '2', '5', '4', '7', '4', '0', '9', '9', '3' }, .integer = 9007199254740992, .float = 9007199254740992 },
        .{ .units = &.{ '1', '0' }, .radix = 36, .integer = 36, .float = 10 },
        .{ .units = &.{ '1', '0' }, .radix = 1, .integer = std.math.nan(f64), .float = 10 },
        .{ .units = &.{ '1', '2', 0xd83d, 0xde00 }, .integer = 12, .float = 12 },
        .{ .units = &.{ 0xc2, 0xa0, '1' }, .integer = std.math.nan(f64), .float = std.math.nan(f64) },
        .{ .units = &.{ '-', '0' }, .integer = -0.0, .float = -0.0 },
    };
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(2){};
    try roots.activate(rt);
    defer roots.deactivate();
    const input = try roots.ref(0);
    const right = try roots.ref(1);
    for (cases) |case| {
        for (0..case.units.len + 1) |split| {
            try input.set(rt, (try core.string.String.createUtf16(rt, case.units[0..split])).value());
            try right.set(rt, (try core.string.String.createUtf16(rt, case.units[split..])).value());
            try input.set(rt, (try core.string.String.createRope(rt, try input.get(rt), try right.get(rt))).value());
            rt.setMemoryLimit(0);
            defer rt.setMemoryLimit(null);
            const epoch = rt.gc.collection_epoch;
            const native_before = rt.allocation_diagnostics.allocated_bytes;
            const numbers = [_]f64{
                try core.number.parseIntValue(rt, try input.get(rt), core.JSValue.int32(case.radix)),
                try core.number.parseFloatValue(rt, try input.get(rt)),
            };
            for (numbers, [_]f64{ case.integer, case.float }) |actual, expected| {
                if (std.math.isNan(expected)) {
                    try std.testing.expect(std.math.isNan(actual));
                } else try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(actual)));
            }
            try std.testing.expect(!(try input.get(rt)).ropeBody().?.isLinearized());
            try std.testing.expectEqual(epoch, rt.gc.collection_epoch);
            try std.testing.expectEqual(native_before, rt.allocation_diagnostics.allocated_bytes);
        }
    }
    rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
    defer rt.setNativeBytesLimitForTest(null);
    const before = rt.active_value_roots;
    try std.testing.expectError(error.OutOfMemory, core.number.parseIntValue(rt, try input.get(rt), null));
    try std.testing.expectError(error.OutOfMemory, core.number.parseFloatValue(rt, try input.get(rt)));
    try std.testing.expect(rt.active_value_roots == before);
    try std.testing.expect(rt.active_no_gc_scope == null);
}

test "value boundary collection prefix lookup does not materialize rope keys" {
    const units = [_]u16{ 0xe9, 'k', 'e', 'y', '-', '1', '7' };
    for ([_]bool{ false, true }) |indexed| {
        for ([_]bool{ false, true }) |cached| {
            for (0..units.len + 1) |split| {
                const rt = try core.JSRuntime.create(std.testing.allocator, .{});
                defer rt.destroy();
                var roots = core.runtime.ExactValueRoots(3){};
                try roots.activate(rt);
                defer roots.deactivate();
                const map = try roots.ref(0);
                const key = try roots.ref(1);
                const right = try roots.ref(2);
                try map.set(rt, (try core.Object.create(rt, core.class.ids.map, null)).value());
                try key.set(rt, (try core.string.String.createUtf16(rt, units[0..split])).value());
                try right.set(rt, (try core.string.String.createUtf16(rt, units[split..])).value());
                try key.set(rt, (try core.string.String.createRope(rt, try key.get(rt), try right.get(rt))).value());
                if (cached) try core.string.ensureFlat(rt, key.readOnly(), right);
                const object = core.Object.fromHeader((try map.get(rt)).cycleMarkHeader().?);
                if (indexed) for (0..16) |index| {
                    try core.collection.appendStrongEntryOwned(rt, object, .{ .key = core.JSValue.int32(@intCast(index)), .value = core.JSValue.nullValue() });
                };
                try core.collection.appendStrongEntryOwned(rt, object, .{ .key = try key.get(rt), .value = core.JSValue.int32(42) });
                try std.testing.expectEqual(indexed, object.collectionBucketHeads().len != 0);
                rt.setMemoryLimit(0);
                rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
                defer rt.setNativeBytesLimitForTest(null);
                var borrow = core.runtime.NoGcScope{};
                borrow.activate(rt);
                defer borrow.deactivate();
                try std.testing.expectEqual(@as(i32, 42), core.collection.mapGetLatin1PrefixIntValue(object, "\xe9key", -17).?.as(.int).?);
                try std.testing.expect(core.collection.mapGetLatin1PrefixIntValue(object, "\xe9key", -18) == null);
                try std.testing.expect(core.collection.mapGetLatin1PrefixIntValue(object, "\xe9Key", -17) == null);
                try std.testing.expectEqual(cached, (try key.get(rt)).ropeBody().?.isLinearized());
            }
        }
    }
}

test "json boundary quoting streams across rope leaves" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const left = try roots.ref(0);
    const right = try roots.ref(1);
    const input = try roots.ref(2);
    const units = [_]u16{ 'a', '"', '\\', 0, 8, 9, 10, 12, 13, 31, 0xe9, 0x100, 0xd83d, 0xde00, 0xd800, 'x', 0xdc00, 0xd800, 0xd801 };
    const expected = "\"a\\\"\\\\\\u0000\\b\\t\\n\\f\\r\\u001f\xc3\xa9\xc4\x80\xf0\x9f\x98\x80\\ud800x\\udc00\\ud800\\ud801\"";
    for (0..units.len + 1) |split| {
        try left.set(rt, (try core.string.String.createUtf16(rt, units[0..split])).value());
        try right.set(rt, (try core.string.String.createUtf16(rt, units[split..])).value());
        const rope = try core.string.String.createRope(rt, try left.get(rt), try right.get(rt));
        try input.set(rt, rope.value());
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.nativeAllocator());
        const epoch = rt.gc.collection_epoch;
        rt.setMemoryLimit(0);
        defer rt.setMemoryLimit(null);
        try core.json.appendJsonStringValue(rt, &bytes, try input.get(rt));
        try std.testing.expectEqualStrings(expected, bytes.items);
        try std.testing.expect(!rope.isLinearized());
        try std.testing.expectEqual(epoch, rt.gc.collection_epoch);
        try std.testing.expect(rt.active_no_gc_scope == null);
    }
}

test "json boundary quoting unwinds native output allocation failures" {
    var failures: usize = 0;
    var succeeded = false;
    for (0..32) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.JSRuntime.create(failing.allocator(), .{});
        defer rt.destroy();
        var roots = core.runtime.ExactValueRoots(3){};
        try roots.activate(rt);
        defer roots.deactivate();
        const left = try roots.ref(0);
        const right = try roots.ref(1);
        const input = try roots.ref(2);
        const prefix = [_]u16{0xd800} ** 128 ++ [_]u16{0xd83d};
        try left.set(rt, (try core.string.String.createUtf16(rt, &prefix)).value());
        try right.set(rt, (try core.string.String.createUtf16(rt, &.{ 0xde00, 0, 0xdc00, 0xd800 })).value());
        const rope = try core.string.String.createRope(rt, try left.get(rt), try right.get(rt));
        try input.set(rt, rope.value());
        const epoch = rt.gc.collection_epoch;
        const native_before = rt.allocation_diagnostics.allocated_bytes;
        rt.setMemoryLimit(0);
        defer rt.setMemoryLimit(null);
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.nativeAllocator());
        failing.fail_index = failing.alloc_index + offset;
        // Force buffer growth through allocation so every growth point is
        // covered even when the backing allocator can resize in place.
        failing.resize_fail_index = failing.resize_index;
        const result = core.json.appendJsonStringValue(rt, &bytes, try input.get(rt));
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        if (result) |_| {
            try std.testing.expectEqualStrings("\"" ++ "\\ud800" ** 128 ++ "\xf0\x9f\x98\x80\\u0000\\udc00\\ud800\"", bytes.items);
            succeeded = true;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
        }
        bytes.clearAndFree(rt.nativeAllocator());
        try std.testing.expectEqual(native_before, rt.allocation_diagnostics.allocated_bytes);
        try std.testing.expect(!rope.isLinearized());
        try std.testing.expectEqual(epoch, rt.gc.collection_epoch);
        try std.testing.expect(rt.active_no_gc_scope == null);
        if (succeeded) break;
    }
    try std.testing.expect(succeeded and failures >= 2);
}
