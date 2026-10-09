//! Exec integration tests: string_boundary.
const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const core = zjs.core;
const helpers = @import("../harness.zig");
const bytecode = zjs.bytecode;
const property_ops = zjs.exec.property_ops;
const object_ops = zjs.exec.object_ops;
const array_ops = zjs.exec.array_ops;
const inline_calls = zjs.exec.inline_calls;
const common = @import("common.zig");
const InterruptTestState = common.InterruptTestState;

test "a finished call's argument window is not traced when the operand top returns to it" {
    // From a runtime fuzz: `G()` in the for-of published its callee window
    // at operand slot 3 and never retired it; `Array.from(e)` later set the
    // top back to slot 3, so every collection during the native call traced
    // a dead slot (a freed nursery extent: `containsExtent` assert).
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const nursery_enabled = js.runtime.gc.nursery.enabled;
    defer js.runtime.gc.nursery.enabled = nursery_enabled;
    js.runtime.gc.nursery.enabled = true;
    const stress = core.gc.forensics.stress_cadence;
    defer core.gc.forensics.stress_cadence = stress;
    core.gc.forensics.stress_cadence = 64;
    _ = try js.eval(
        \\var nn = 0;
        \\function G() { $262.gc(); }
        \\c = null, d = 1, e = "e";
        \\[...e];
        \\for (i = 0; i < 1791; i++) { d = [d]; }
        \\for (q of d) { G(); e = q; break; }
        \\for (i = 0; i < 1116; i++) { e = [e]; }
        \\e = { [Symbol.iterator]() { return { next() { return { done: ++nn > 100000 }; } }; } };
        \\if (Array.from(e).length !== 100000) throw new Error("length");
    );
    try std.testing.expect(!js.context.hasException());
}

test "number parsing preserves coercion order and prefix semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    _ = try js.evalWithOutput(
        \\const trace = [];
        \\const input = { [Symbol.toPrimitive](hint) { trace.push(hint); return " 0x10tail"; } };
        \\const radix = { valueOf() { trace.push("radix"); return 16; } };
        \\print(parseInt(input, radix), trace.join(","));
        \\trace.length = 0;
        \\try { parseInt({ toString() { trace.push("input"); throw "failed"; } }, radix); }
        \\catch (e) { print(e, trace.join(",")); }
        \\print(parseFloat({ toString() { return " -12.5e1x"; } }));
        \\print(Number.parseInt("\u3000-0xffz"), Number.parseFloat("\ufeffInfinity"));
        \\print(parseInt("9007199254740993"), parseFloat("9007199254740993"));
        \\print(Object.is(parseInt("-0"), -0), Object.is(parseFloat("-0"), -0));
    , &output.writer);
    try std.testing.expectEqualStrings("16 string,radix\nfailed input\n-125\n-255 Infinity\n9007199254740992 9007199254740992\ntrue true\n", output.written());
}

test "JSON rawJSON preserves rope source code units without materialization" {
    const units = [_]u16{ '"', 0xe9, 0x100, 0xd83d, 0xde00, '\\', 'u', 'd', '8', '0', '0', '"' };
    for (1..units.len) |split| {
        const rt = try core.JSRuntime.create(std.testing.allocator, .{});
        defer rt.destroy();
        var roots = core.runtime.ExactValueRoots(3){};
        try roots.activate(rt);
        defer roots.deactivate();
        const input = try roots.ref(0);
        const right = try roots.ref(1);
        const output = try roots.ref(2);
        try input.set(rt, (try core.string.String.createUtf16(rt, units[0..split])).value());
        try right.set(rt, (try core.string.String.createUtf16(rt, units[split..])).value());
        try input.set(rt, (try core.string.String.createRope(rt, try input.get(rt), try right.get(rt))).value());
        try output.set(rt, try zjs.exec.json_ops.rawJSON(rt, try input.get(rt)));
        const object = core.Object.fromHeader((try output.get(rt)).cycleMarkHeader().?);
        const text = try object.getProperty(core.atom.ids.rawJSON);
        try std.testing.expectEqual(units.len, core.string.stringValueLenUnchecked(text));
        for (units, 0..) |unit, index| try std.testing.expectEqual(unit, core.string.stringValueCodeUnitAtUnchecked(text, index));
        try std.testing.expect(!(try input.get(rt)).ropeBody().?.isLinearized());
    }
}

test "JSON rawJSON native allocation failures release roots and native buffers" {
    var failures: usize = 0;
    var succeeded = false;
    for (0..128) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.JSRuntime.create(failing.allocator(), .{});
        defer rt.destroy();
        rt.setGCThreshold(std.math.maxInt(usize));
        const source = "\"" ++ "\\u0100" ** 100 ++ "\"";
        const input = (try core.string.String.createAscii(rt, source)).value();
        failing.fail_index = failing.alloc_index + offset;
        failing.resize_fail_index = failing.resize_index;
        const attempt = zjs.exec.json_ops.rawJSON(rt, input);
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        if (attempt) |result| {
            const object = core.Object.fromHeader(result.cycleMarkHeader().?);
            const text = try object.getProperty(core.atom.ids.rawJSON);
            try std.testing.expect(core.string.asFlat(text).?.eqlBytes(source));
            succeeded = true;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
        }
        try std.testing.expect(rt.active_value_roots == null);
        try std.testing.expect(rt.active_no_gc_scope == null);
        if (succeeded) break;
    }
    // The backing testing allocator checks partial native buffers on teardown;
    // any published partial objects remain the collector's responsibility.
    try std.testing.expect(succeeded and failures > 1);
}

test "JSON stringify call serializes a directly supplied object" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
    const object = try core.Object.createPlainObject(rt, null);
    try object.defineOwnProperty(rt, core.atom.ids.value, core.Descriptor.data(core.JSValue.int32(7), .all));
    const result = try zjs.exec.json_ops.jsonStringifyCall(ctx, null, global, &.{object.value()}, null, null);
    try std.testing.expect(core.string.asFlat(result).?.eqlBytes("{\"value\":7}"));
}

test "JSON stringify call streams rope keys and preserves gap code units" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
    var roots = core.runtime.ExactValueRoots(5){};
    try roots.activate(rt);
    defer roots.deactivate();
    const value = try roots.ref(0);
    const key = try roots.ref(1);
    const space = try roots.ref(2);
    const replacer = try roots.ref(3);
    const temporary = try roots.ref(4);
    try value.set(rt, (try core.Object.createPlainObject(rt, null)).value());
    try core.Object.fromHeader((try value.get(rt)).cycleMarkHeader().?).defineOwnProperty(rt, core.atom.ids.value, core.Descriptor.data(core.JSValue.int32(7), .all));
    try temporary.set(rt, (try core.string.String.createAscii(rt, "val")).value());
    try key.set(rt, (try core.string.String.createAscii(rt, "ue")).value());
    try key.set(rt, (try core.string.String.createRope(rt, try temporary.get(rt), try key.get(rt))).value());
    try space.set(rt, (try core.string.String.createUtf16(rt, &.{ 0xd800, ' ' })).value());
    try replacer.set(rt, (try core.Object.createArray(rt, null)).value());
    for (0..2) |index| {
        try core.Object.fromHeader((try replacer.get(rt)).cycleMarkHeader().?).defineOwnProperty(rt, core.Atom.taggedInt(@intCast(index)), core.Descriptor.data(try key.get(rt), .all));
    }
    const args = [_]core.JSValue{ try value.get(rt), try replacer.get(rt), try space.get(rt) };
    try temporary.set(rt, try zjs.exec.json_ops.jsonStringifyCall(ctx, null, global, &args, null, null));
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try core.string.appendValueUtf8(rt, &bytes, try temporary.get(rt));
    try std.testing.expectEqualStrings("{\n\xed\xa0\x80 \"value\": 7\n}", bytes.items);
    try std.testing.expect(!(try key.get(rt)).ropeBody().?.isLinearized());
}

test "JSON stringify cycle stack allows repeated sibling references" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var stream = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stream.deinit();
    _ = try js.evalWithOutput(
        \\const shared = {v: 1};
        \\print(JSON.stringify({a: shared, b: shared}, (k, v) => v));
        \\print(JSON.stringify([shared, shared]));
        \\const parent = {child: {}};
        \\parent.child.back = parent;
        \\for (const replacer of [undefined, (k, v) => v]) {
        \\  try { JSON.stringify(parent, replacer); print("missed cycle"); }
        \\  catch (e) { print(e.name, e.message); }
        \\}
        \\print(JSON.stringify({ok: 2}, (k, v) => v));
    , &stream.writer);
    try std.testing.expectEqualStrings(
        "{\"a\":{\"v\":1},\"b\":{\"v\":1}}\n" ++
            "[{\"v\":1},{\"v\":1}]\n" ++
            "TypeError circular reference\nTypeError circular reference\n" ++
            "{\"ok\":2}\n",
        stream.written(),
    );
}

test "JSON stringify gap reads rope without materialization" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
    const left = try core.string.String.createAscii(rt, "abcde");
    const right = try core.string.String.createAscii(rt, "fghijk");
    const rope = try core.string.String.createRope(rt, left.value(), right.value());
    var gap = try zjs.exec.json_ops.jsonStringifyGap(ctx, null, global, rope.value(), null, null);
    defer gap.deinit(rt.nativeAllocator());
    try std.testing.expectEqualStrings("abcdefghij", gap.items);
    try std.testing.expect(!rope.isLinearized());
}

test "JSON stringify gap preserves the tenth UTF16 code unit" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
    const units = [_]u16{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 0xd83d, 0xde00 };
    const space = try core.string.String.createUtf16(rt, &units);
    var gap = try zjs.exec.json_ops.jsonStringifyGap(ctx, null, global, space.value(), null, null);
    defer gap.deinit(rt.nativeAllocator());
    try std.testing.expectEqualStrings("abcdefghi\xed\xa0\xbd", gap.items);
}

test "JSON stringify gap handles every rope split without JS allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const left = try roots.ref(0);
    const right = try roots.ref(1);
    const input = try roots.ref(2);
    const units = [_]u16{ 0xe9, 0x100, 0xd83d, 0xde00, 0xd800, 'x', 0xdc00, 0, 'z', 0xd83d, 0xde00 };
    for (0..units.len + 1) |split| {
        try left.set(rt, (try core.string.String.createUtf16(rt, units[0..split])).value());
        try right.set(rt, (try core.string.String.createUtf16(rt, units[split..])).value());
        try input.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value());
        const epoch = rt.gc.collection_epoch;
        const heap_bytes = rt.gc.heap_budget.bytes;
        rt.setMemoryLimit(0);
        defer rt.setMemoryLimit(null);
        var gap = try zjs.exec.json_ops.jsonStringifyGap(ctx, null, global, try input.get(rt), null, null);
        defer gap.deinit(rt.nativeAllocator());
        try std.testing.expectEqualStrings("\xc3\xa9\xc4\x80\xf0\x9f\x98\x80\xed\xa0\x80x\xed\xb0\x80\x00z\xed\xa0\xbd", gap.items);
        try std.testing.expect(!(try input.get(rt)).ropeBody().?.isLinearized());
        try std.testing.expectEqual(epoch, rt.gc.collection_epoch);
        try std.testing.expectEqual(heap_bytes, rt.gc.heap_budget.bytes);
        try std.testing.expect(rt.active_no_gc_scope == null);
    }
}

test "JSON stringify property list reads rope without materialization" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const left = try roots.ref(0);
    const right = try roots.ref(1);
    const input = try roots.ref(2);
    try left.set(rt, (try core.string.String.createUtf16(rt, &.{ 'k', 0xd83d })).value());
    try right.set(rt, (try core.string.String.createUtf16(rt, &.{ 0xde00, 0xd800 })).value());
    try input.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value());
    const rope = try input.get(rt);
    const replacer = try array_ops.createArrayFromArgs(rt, global, &.{ rope, rope });
    const list = try zjs.exec.json_ops.jsonStringifyPropertyList(ctx, null, global, replacer, null, null);
    defer rt.nativeAllocator().free(list.items);
    try std.testing.expect(list.has_property_list);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("k\xf0\x9f\x98\x80\xed\xa0\x80", rt.atoms.name(list.items[0]).?);
    try std.testing.expect(!(try input.get(rt)).ropeBody().?.isLinearized());
}

test "JSON stringify gap obeys code unit and numeric limits end to end" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var stream = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stream.deinit();
    _ = try js.evalWithOutput(
        \\for (const space of ["abcdefghi\ud83d\ude00", "\ud800x\udc00", NaN, Infinity, -Infinity, 3.9]) {
        \\  print(JSON.stringify(JSON.stringify({a:1}, null, space)));
        \\}
    , &stream.writer);
    // ECMA-262 JSON.stringify steps 7–8; matches the local QuickJS probe.
    try std.testing.expectEqualStrings(
        "\"{\\nabcdefghi\\ud83d\\\"a\\\": 1\\n}\"\n" ++
            "\"{\\n\\ud800x\\udc00\\\"a\\\": 1\\n}\"\n" ++
            "\"{\\\"a\\\":1}\"\n" ++
            "\"{\\n          \\\"a\\\": 1\\n}\"\n" ++
            "\"{\\\"a\\\":1}\"\n" ++
            "\"{\\n   \\\"a\\\": 1\\n}\"\n",
        stream.written(),
    );
}

test "json boundary parser handles immediate results without JS allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const text = (try core.string.String.createAscii(rt, "42")).value();
    rt.setMemoryLimit(0);
    const parsed = try engine.exec.json_ops.parse(rt, null, text);
    try std.testing.expectEqual(@as(i32, 42), parsed.as(.int).?);
}

test "regexp legacy statics materialization survives allocation GC" {
    const Probe = struct {
        rt: *core.JSRuntime,
        calls: usize = 0,
        failure: ?anyerror = null,
        fn run(raw: ?*anyopaque, _: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.rt.collectForTest() catch |err| {
                self.failure = err;
                return;
            };
            self.calls += 1;
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval("/old/.exec('old');");
    const rt = js.runtime;
    const global = try js.context.globalObject();
    const long_len = 1 << 20;
    const bytes = try rt.nativeAllocator().alloc(u8, long_len + 8);
    defer rt.nativeAllocator().free(bytes);
    @memset(bytes, 'x');
    @memcpy(bytes[0..2], "LL");
    @memcpy(bytes[long_len + 2 ..], "abCDRR");
    var roots = core.runtime.ExactValueRoots(1){};
    try roots.activate(rt);
    defer roots.deactivate();
    const source = try roots.ref(0);
    try source.set(rt, (try core.string.String.createLatin1(rt, bytes)).value());
    const unset = std.math.maxInt(usize);
    const captures = [_]usize{ 2, long_len + 2, long_len + 2, long_len + 4 } ++ [_]usize{unset} ** 14 ++ [_]usize{ long_len + 4, long_len + 6, unset, unset };
    // Ten groups: the last one ("CD") lies beyond $1..$9, so lastParen
    // needs its own rooted slot.
    const found = engine.exec.string_ops.RegExpMatch{ .index = 2, .len = long_len + 4, .capture_slots = &captures, .capture_count = 10 };
    try std.testing.expect(engine.exec.string_ops.encodeRegExpLegacyCaptureSlice(2, long_len) == null);
    var probe = Probe{ .rt = rt };
    _ = rt.gc.heap_budget.installProbe(.{ .run = Probe.run, .context = &probe });
    defer rt.gc.heap_budget.restoreProbe(null);
    const before = rt.active_value_roots;
    try engine.exec.string_ops.updateRegExpLegacyStaticsForMatch(rt, global, try source.get(rt), &found, bytes.len);
    rt.gc.heap_budget.restoreProbe(null);
    if (probe.failure) |err| return err;
    try std.testing.expect(probe.calls >= 3);
    try std.testing.expect(rt.active_value_roots == before);
    _ = try rt.collectForTest();
    const legacy = global.installedRealmRegExpLegacyStatics(rt).?;
    try std.testing.expect(!legacy.lazy_no_capture_match);
    try std.testing.expectEqual(@as(usize, long_len + 4), core.string.stringValueLenUnchecked(legacy.last_match.?));
    try std.testing.expectEqual(@as(usize, long_len), core.string.stringValueLenUnchecked(legacy.captures[0].?));
    try std.testing.expect(core.string.asFlat(legacy.captures[1].?).?.eqlBytes("ab"));
    try std.testing.expectEqual(@as(u8, 9), legacy.capture_slot_count);
    for (legacy.captures[2..]) |capture| try std.testing.expect(capture == null);
    try std.testing.expect(core.string.asFlat(legacy.last_paren.?).?.eqlBytes("CD"));
    try std.testing.expect(core.string.asFlat(legacy.left_context.?).?.eqlBytes("LL"));
    try std.testing.expect(core.string.asFlat(legacy.right_context.?).?.eqlBytes("RR"));
}

test "regexp legacy statics preserve previous snapshot on context OOM" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval("/(old)/.exec('old');");
    const rt = js.runtime;
    const global = try js.context.globalObject();
    const legacy = global.installedRealmRegExpLegacyStatics(rt).?;
    try std.testing.expect(legacy.lazy_no_capture_match);
    const old_input = legacy.input.?;
    const old_capture = legacy.captures[0].?;
    var roots = core.runtime.ExactValueRoots(2){};
    try roots.activate(rt);
    defer roots.deactivate();
    const source = try roots.ref(0);
    const matched = try roots.ref(1);
    try source.set(rt, (try core.string.String.createAscii(rt, "LLnewRR")).value());
    try matched.set(rt, (try core.string.String.createAscii(rt, "new")).value());
    const captures = [_]usize{ 2, 5 };
    const found = engine.exec.string_ops.RegExpMatch{ .index = 2, .len = 3, .capture_slots = &captures, .capture_count = 1 };
    var values: [9]?core.JSValue = @splat(null);
    values[0] = try matched.get(rt);
    const before = rt.active_value_roots;
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.updateRegExpLegacyStaticsForMatchValues(rt, global, try source.get(rt), &found, 7, try matched.get(rt), &values, try matched.get(rt)));
    try std.testing.expect(rt.active_value_roots == before);
    try std.testing.expect(legacy.lazy_no_capture_match);
    try std.testing.expect(legacy.input.?.same(old_input));
    try std.testing.expect(legacy.captures[0].?.same(old_capture));
    rt.setMemoryLimit(null);
    try engine.exec.string_ops.updateRegExpLegacyStaticsForMatchValues(rt, global, try source.get(rt), &found, 7, try matched.get(rt), &values, try matched.get(rt));
    try std.testing.expect(!legacy.lazy_no_capture_match);
    try std.testing.expect(core.string.asFlat(legacy.last_match.?).?.eqlBytes("new"));
    try std.testing.expect(core.string.asFlat(legacy.left_context.?).?.eqlBytes("LL"));
    try std.testing.expect(core.string.asFlat(legacy.right_context.?).?.eqlBytes("RR"));
    const no_captures = engine.exec.string_ops.RegExpMatch{ .index = 0, .len = 7 };
    try engine.exec.string_ops.updateRegExpLegacyStaticsForMatch(rt, global, try source.get(rt), &no_captures, 7);
    try std.testing.expect(legacy.lazy_no_capture_match);
    try std.testing.expectEqual(@as(u8, 0), legacy.capture_slot_count);
    try std.testing.expect(legacy.captures[0] == null and legacy.last_paren == null);
    try std.testing.expect(legacy.last_match == null and legacy.left_context == null and legacy.right_context == null);
    try std.testing.expect(rt.active_value_roots == before);
}

test "regexp capture result survives GC at each allocation" {
    const Probe = struct {
        rt: *core.JSRuntime,
        calls: usize = 0,
        fail_at: ?usize = null,
        failure: ?anyerror = null,
        fn run(raw: ?*anyopaque, _: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            if (self.fail_at == self.calls) self.rt.setMemoryLimit(0);
            _ = self.rt.collectForTest() catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]?usize{ null, 1, 4, 8 }) |fail_at| {
            var js = try helpers.TestEngine.init(std.testing.allocator);
            defer js.deinit();
            const rt = js.runtime;
            defer rt.setMemoryLimit(null);
            _ = try js.eval("0;");
            rt.gc.nursery.enabled = nursery;
            var roots = core.runtime.ExactValueRoots(2){};
            try roots.activate(rt);
            defer roots.deactivate();
            const input = try roots.ref(0);
            const result = try roots.ref(1);
            try input.set(rt, (try core.string.String.createUtf16(rt, &.{ 'x', 'x', 'a', 0x100, 'y', 'y' })).value());
            var compiled = try engine.exec.regexp_ops.compileWithRuntime(rt, "(?<letter>a)(\xc4\x80)", "d");
            defer compiled.deinit(rt.nativeAllocator());
            const captures = [_]usize{ 2, 3, 3, 4 };
            const found = engine.exec.string_ops.RegExpMatch{ .index = 2, .len = 2, .capture_slots = &captures, .capture_bytecode = compiled.bytecode, .capture_count = 2, .has_named_captures = true };
            var probe = Probe{ .rt = rt, .fail_at = fail_at };
            const previous_probe = rt.gc.heap_budget.installProbe(.{ .run = Probe.run, .context = &probe });
            defer rt.gc.heap_budget.restoreProbe(previous_probe);
            const before = rt.active_value_roots;
            const pins_before = rt.gc.pins.count();
            const created = engine.exec.string_ops.createRegExpMatchArrayFromValue(rt, try js.context.globalObject(), try input.get(rt), &found, 6, true);
            rt.gc.heap_budget.restoreProbe(null);
            if (probe.failure) |err| return err;
            try std.testing.expect(rt.active_value_roots == before);
            try std.testing.expectEqual(pins_before, rt.gc.pins.count());
            if (fail_at) |allocation| {
                try std.testing.expect(probe.calls >= allocation);
                try std.testing.expectError(error.OutOfMemory, created);
                rt.setMemoryLimit(null);
                _ = try rt.collectForTest();
                continue;
            }
            try result.set(rt, try created);
            try std.testing.expect(probe.calls >= 6);
            _ = try rt.collectForTest();
            const letter = try rt.internAtom("letter");
            const array = core.value_semantics.objectFromValue(try result.get(rt)).?;
            try std.testing.expectEqual(@as(u32, 3), array.arrayLength());
            try std.testing.expectEqual(@as(u16, 0x100), core.string.stringValueCodeUnitAtUnchecked(try array.getProperty(core.Atom.taggedInt(0)), 1));
            const groups = core.value_semantics.objectFromValue(try array.getProperty(comptime core.atom.predefinedId("groups", .string).?)).?;
            try std.testing.expect(core.string.asFlat(try groups.getProperty(letter)).?.eqlBytes("a"));
            const indices = core.value_semantics.objectFromValue(try array.getProperty(comptime core.atom.predefinedId("indices", .string).?)).?;
            const pair = core.value_semantics.objectFromValue(try indices.getProperty(core.Atom.taggedInt(0))).?;
            try std.testing.expectEqual(@as(i32, 2), (try pair.getProperty(core.Atom.taggedInt(0))).as(.int).?);
            try std.testing.expectEqual(@as(i32, 4), (try pair.getProperty(core.Atom.taggedInt(1))).as(.int).?);
        }
    }
}

test "regexp capture property writers unwind native pin OOM" {
    for ([_]bool{ false, true }) |named| {
        const rt = try core.JSRuntime.create(std.testing.allocator, .{});
        defer rt.destroy();
        var roots = core.runtime.ExactValueRoots(2){};
        try roots.activate(rt);
        defer roots.deactivate();
        const owner = try roots.ref(0);
        const value = try roots.ref(1);
        try owner.set(rt, (if (named) try core.Object.createPlainObject(rt, null) else try core.Object.createArray(rt, null)).value());
        try value.set(rt, (try core.Object.createPlainObject(rt, null)).value());
        const before = rt.active_value_roots;
        const pins = rt.gc.pins.count();
        rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
        defer rt.setNativeBytesLimitForTest(null);
        const object = core.value_semantics.objectFromValue(try owner.get(rt)).?;
        if (named) {
            try std.testing.expectError(error.OutOfMemory, engine.exec.object_ops.defineFreshNonIndexDataProperty(rt, object, core.atom.ids.value, try value.get(rt), .all));
            try std.testing.expect(!object.hasOwnProperty(core.atom.ids.value));
        } else {
            try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.defineSplitValueElement(rt, object, 0, try value.get(rt)));
            try std.testing.expectEqual(@as(u32, 0), object.arrayLength());
        }
        try std.testing.expect(rt.active_value_roots == before);
        try std.testing.expectEqual(pins, rt.gc.pins.count());
    }
}

test "regexp execution retains converted input across lastIndex callback GC" {
    const Probe = struct {
        rt: *core.JSRuntime,
        input: ?*core.gc.Header = null,
        calls: usize = 0,
        lost: bool = false,
        fn make(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const value = (try core.string.String.createUtf16(self.rt, &.{ 'a', 0x100 })).value();
            self.input = value.cycleMarkHeader().?;
            return value;
        }
        fn collect(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = try self.rt.collectForTest();
            if (!self.rt.gc.containsHeader(self.input orelse return error.MissingRegExpInput)) {
                self.lost = true;
                return error.LostRegExpInput;
            }
            self.calls += 1;
            return core.JSValue.undefinedValue();
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var probe = Probe{ .rt = js.runtime };
    try js.defineGlobalExternalHostFunction("execInput", 0, &probe, Probe.make, null);
    try js.defineGlobalExternalHostFunction("execCollect", 0, &probe, Probe.collect, null);
    js.runtime.forcePreciseRootScanForTest();
    defer js.runtime.restoreDefaultRootScanForTest();
    const before = js.runtime.active_value_roots;
    const result = js.eval(
        \\var rx = /a\u0100/g;
        \\for (const method of ['exec', 'test']) {
        \\  rx.lastIndex = { valueOf() { execCollect(); return 0; } };
        \\  const result = rx[method]({ toString: execInput });
        \\  assert.sameValue(method === 'exec' ? result[0] : result, method === 'exec' ? 'a\u0100' : true);
        \\  assert.sameValue(rx.lastIndex, 2);
        \\  rx.lastIndex = { valueOf() { execCollect(); throw 19; } };
        \\  let caught = false;
        \\  try { rx[method]({ toString: execInput }); } catch (e) { caught = true; assert.sameValue(e, 19); }
        \\  assert.sameValue(caught, true);
        \\}
    );
    try std.testing.expect(!probe.lost);
    _ = try result;
    try std.testing.expectEqual(@as(usize, 4), probe.calls);
    try std.testing.expect(js.runtime.active_value_roots == before);
}

test "regexp execution propagates rope materialization OOM" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const rt = js.runtime;
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const receiver = try roots.ref(0);
    const source = try roots.ref(1);
    const right = try roots.ref(2);
    try receiver.set(rt, try js.evalWithOptions("/a/", .{ .filename = "<repl>" }));
    try source.set(rt, (try core.string.String.createAscii(rt, "a")).value());
    try right.set(rt, (try core.string.String.createUtf16(rt, &.{0x100})).value());
    try source.set(rt, (try core.string.String.createRope(rt, try source.get(rt), try right.get(rt))).value());
    const before = rt.active_value_roots;
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, engine.exec.regexp_ops.regExpTestFastNoResult(js.context, try js.context.globalObject(), core.value_semantics.objectFromValue(try receiver.get(rt)).?, try source.get(rt)));
    try std.testing.expectError(error.OutOfMemory, engine.exec.regexp_ops.regExpExecResult(js.context, null, try js.context.globalObject(), try receiver.get(rt), core.value_semantics.objectFromValue(try receiver.get(rt)).?, try source.get(rt), true, null, null));
    try std.testing.expect(!(try source.get(rt)).ropeBody().?.isLinearized());
    try std.testing.expect(rt.active_value_roots == before);
}

test "regexp execution retains bytecode snapshot during interrupt reentry" {
    const Probe = struct {
        receiver: *core.Object,
        replacement: core.JSValue,
        compiled: []const u8,
        old_program: *core.gc.Header,
        calls: usize = 0,
        lost: bool = false,
        failure: ?anyerror = null,
        fn interrupt(rt: *core.JSRuntime, raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            if (self.calls != 1) return false;
            self.receiver.setRegexpProgram(rt, self.replacement, self.compiled) catch |err| {
                self.failure = err;
                return true;
            };
            _ = rt.collectForTest() catch |err| {
                self.failure = err;
                return true;
            };
            self.lost = !rt.gc.containsHeader(self.old_program);
            // Stop before another bytecode read if the snapshot was lost.
            return self.lost;
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const rt = js.runtime;
    _ = try js.eval("0;");
    rt.forcePreciseRootScanForTest();
    defer rt.restoreDefaultRootScanForTest();
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const receiver = try roots.ref(0);
    const input = try roots.ref(1);
    const source = try roots.ref(2);
    var compiled = try engine.exec.regexp_ops.compileWithRuntime(rt, "c$", "");
    defer compiled.deinit(rt.nativeAllocator());
    for ([_]bool{ false, true }) |exec_result| {
        try source.set(rt, (try core.string.String.createAscii(rt, "^(a+)+b$")).value());
        try receiver.set(rt, try engine.exec.regexp_ops.constructWithPrototype(rt, try source.get(rt), core.JSValue.undefinedValue(), null));
        try source.set(rt, (try core.string.String.createAscii(rt, "c$")).value());
        try input.set(rt, (try core.string.String.createAscii(rt, "a" ** 16 ++ "c")).value());
        const object = core.value_semantics.objectFromValue(try receiver.get(rt)).?;
        var probe = Probe{ .receiver = object, .replacement = try source.get(rt), .compiled = compiled.bytecode, .old_program = object.regexpCompiledBytecodeValue().?.cycleMarkHeader().? };
        const before = rt.active_value_roots;
        rt.setInterruptHandler(Probe.interrupt, &probe);
        defer rt.setInterruptHandler(null, null);
        if (exec_result) {
            const result = try engine.exec.regexp_ops.regExpExecResult(js.context, null, try js.context.globalObject(), try receiver.get(rt), object, try input.get(rt), true, null, null);
            try std.testing.expect(result != null and result.?.is(.null_value));
        } else {
            const result = try engine.exec.regexp_ops.regExpTestFastNoResult(js.context, try js.context.globalObject(), object, try input.get(rt));
            try std.testing.expectEqual(@as(?bool, false), result);
        }
        if (probe.failure) |err| return err;
        try std.testing.expect(probe.calls > 0);
        try std.testing.expect(!probe.lost);
        try std.testing.expect(rt.active_value_roots == before);
        try std.testing.expect(core.string.asFlat(object.regexpSource().?).?.eqlBytes("c$"));
    }
}

test "regexp compile OOM preserves source and compiled program together" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const rt = js.runtime;
    rt.forcePreciseRootScanForTest();
    defer rt.restoreDefaultRootScanForTest();
    var roots = core.runtime.ExactValueRoots(5){};
    try roots.activate(rt);
    defer roots.deactivate();
    const receiver = try roots.ref(0);
    const source = try roots.ref(1);
    const right = try roots.ref(2);
    const flags = try roots.ref(3);
    const old_source = try roots.ref(4);
    try receiver.set(rt, try js.evalWithOptions("/old/", .{ .filename = "<repl>" }));
    try old_source.set(rt, core.value_semantics.objectFromValue(try receiver.get(rt)).?.regexpSource().?);
    const old_bytecode = try std.testing.allocator.dupe(u8, core.value_semantics.objectFromValue(try receiver.get(rt)).?.regexpCompiledBytecode());
    defer std.testing.allocator.free(old_bytecode);
    // A large source with a compact character-class program lets the old
    // bytecode allocation succeed, then makes source materialization fail.
    const prefix = "[" ++ "a" ** 16384;
    try source.set(rt, (try core.string.String.createAscii(rt, prefix)).value());
    try right.set(rt, (try core.string.String.createUtf16(rt, &.{ 0x100, ']' })).value());
    try source.set(rt, (try core.string.String.createRope(rt, try source.get(rt), try right.get(rt))).value());
    try flags.set(rt, (try core.string.String.createAscii(rt, "g")).value());
    var compiled = try engine.exec.regexp_ops.compileWithRuntime(rt, prefix ++ "\xc4\x80]", "g");
    defer compiled.deinit(rt.nativeAllocator());
    _ = try rt.collectForTest();
    const base = rt.gc.heap_budget.bytes;
    _ = try core.string.String.createLatin1(rt, compiled.bytecode);
    const bytecode_charge = rt.gc.heap_budget.bytes - base;
    _ = try rt.collectForTest();
    try std.testing.expectEqual(base, rt.gc.heap_budget.bytes);
    const before = rt.active_value_roots;
    rt.setMemoryLimit(base + bytecode_charge);
    defer rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, engine.exec.regexp_ops.regExpCompile(js.context, null, try js.context.globalObject(), try receiver.get(rt), &.{ try source.get(rt), try flags.get(rt) }, null, null));
    const object = core.value_semantics.objectFromValue(try receiver.get(rt)).?;
    try std.testing.expect(object.regexpSource().?.same(try old_source.get(rt)));
    try std.testing.expectEqualSlices(u8, old_bytecode, object.regexpCompiledBytecode());
    try std.testing.expect(!(try source.get(rt)).ropeBody().?.isLinearized());
    try std.testing.expect(rt.active_value_roots == before);
}

test "regexp compile commits program before read-only lastIndex throws" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    // RegExpInitialize publishes its internal slots before the strict Set of
    // lastIndex (ECMA-262 22.2.3.3). A lastIndex throw must not roll them back.
    _ = try js.eval(
        \\for (const clone of [false, true]) {
        \\  const r = /old/;
        \\  r.lastIndex = 7;
        \\  Object.defineProperty(r, 'lastIndex', { writable: false });
        \\  assert.throws(TypeError, function () {
        \\    if (clone) r.compile(/new/g); else r.compile('new', 'g');
        \\  });
        \\  assert.sameValue(r.source, 'new');
        \\  assert.sameValue(r.global, true);
        \\  assert.sameValue(r.lastIndex, 7);
        \\  const copy = new RegExp(r);
        \\  assert.sameValue(copy.test('new'), true);
        \\  assert.sameValue(copy.test('old'), false);
        \\}
    );
}

test "regexp compile retains converted source across flags callback GC" {
    const Probe = struct {
        rt: *core.JSRuntime,
        source: ?*core.gc.Header = null,
        calls: usize = 0,
        lost: bool = false,
        fn make(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const value = (try core.string.String.createUtf16(self.rt, &.{ 'a', 0x100 })).value();
            self.source = value.cycleMarkHeader().?;
            return value;
        }
        fn collect(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = try self.rt.collectForTest();
            if (!self.rt.gc.containsHeader(self.source orelse return error.MissingRegExpSource)) {
                self.lost = true;
                return error.LostRegExpSource;
            }
            self.calls += 1;
            return core.JSValue.undefinedValue();
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var probe = Probe{ .rt = js.runtime };
    try js.defineGlobalExternalHostFunction("compileSource", 0, &probe, Probe.make, null);
    try js.defineGlobalExternalHostFunction("compileCollect", 0, &probe, Probe.collect, null);
    js.runtime.forcePreciseRootScanForTest();
    defer js.runtime.restoreDefaultRootScanForTest();
    const root_head = js.runtime.active_value_roots;
    const result = js.eval(
        \\var rx = /old/;
        \\assert.sameValue(rx.compile({ toString: compileSource },
        \\  { toString() { compileCollect(); return 'g'; } }), rx);
        \\assert.sameValue(rx.source, 'a\u0100');
        \\assert.sameValue(rx.global, true);
        \\assert.sameValue(rx.test('a\u0100'), true);
        \\try { rx.compile({ toString: compileSource },
        \\  { toString() { compileCollect(); throw 17; } }); }
        \\catch (e) { assert.sameValue(e, 17); }
        \\assert.sameValue(rx.source, 'a\u0100');
    );
    try std.testing.expect(!probe.lost);
    _ = try result;
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expect(js.runtime.active_value_roots == root_head);
}

test "string boundary regexp source publication preserves old value on OOM" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(4){};
    try roots.activate(rt);
    defer roots.deactivate();
    const owner = try roots.ref(0);
    const left = try roots.ref(1);
    const right = try roots.ref(2);
    const source = try roots.ref(3);
    try owner.set(rt, (try core.Object.create(rt, core.class.ids.regexp, null)).value());
    try left.set(rt, (try core.string.String.createAscii(rt, "old-source")).value());
    try core.value_semantics.objectFromValue(try owner.get(rt)).?.setRegexpSource(rt, try left.get(rt));
    try left.set(rt, (try core.string.String.createAscii(rt, "new-")).value());
    try right.set(rt, (try core.string.String.createUtf16(rt, &.{0x100})).value());
    const rope = try core.string.String.createRope(rt, try left.get(rt), try right.get(rt));
    try source.set(rt, rope.value());
    const before = rt.active_value_roots;
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, core.value_semantics.objectFromValue(try owner.get(rt)).?.setRegexpSource(rt, try source.get(rt)));
    try std.testing.expect(core.string.asFlat(core.value_semantics.objectFromValue(try owner.get(rt)).?.regexpSource().?).?.eqlBytes("old-source"));
    try std.testing.expect(!rope.isLinearized());
    try std.testing.expect(rt.active_value_roots == before);
    rt.setMemoryLimit(null);
    try core.value_semantics.objectFromValue(try owner.get(rt)).?.setRegexpSource(rt, try source.get(rt));
    const stored = core.value_semantics.objectFromValue(try owner.get(rt)).?.regexpSource().?;
    try std.testing.expect(core.string.asFlat(stored) != null);
    try std.testing.expectEqual(@as(usize, 5), core.string.stringValueLenUnchecked(stored));
    try std.testing.expectEqual(@as(u16, 0x100), core.string.stringValueCodeUnitAtUnchecked(stored, 4));
    try std.testing.expect(rt.active_value_roots == before);
}

test "date boundary constructor retains later arguments and coerced values" {
    const Probe = struct {
        rt: *core.JSRuntime,
        later_id: ?usize = null,
        calls: usize = 0,
        lost: bool = false,
        fn collect(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = try self.rt.collectForTest();
            self.calls += 1;
            if (self.later_id != null and self.rt.liveObjectFromWeakIdentity(self.later_id.?) == null) {
                self.lost = true;
                return error.LostDateConstructorInput;
            }
            return core.JSValue.int32(if (self.calls == 1) 1970 else 0);
        }
    };
    for ([_]bool{ false, true }) |multiple| {
        var js = try helpers.TestEngine.init(std.testing.allocator);
        defer js.deinit();
        const rt = js.runtime;
        const global = try js.context.globalObject();
        var probe = Probe{ .rt = rt };
        try js.defineGlobalExternalHostFunction("dateConstructorCollect", 0, &probe, Probe.collect, null);
        const inputs = setup: {
            var roots = core.runtime.ExactValueRoots(4){};
            try roots.activate(rt);
            defer roots.deactivate();
            const new_target = try roots.ref(0);
            const first = try roots.ref(1);
            const later = try roots.ref(2);
            const constructor = try roots.ref(3);
            // new.target's `prototype` getter runs after the arguments were
            // converted (§21.4.2.1) and collects once more.
            _ = try js.eval(
                \\globalThis.dateNewTarget = (function () {
                \\  const p = Object.create(Date.prototype);
                \\  const f = function () {}.bind();
                \\  Object.defineProperty(f, "prototype", { get() { dateConstructorCollect(); globalThis.dateProto = p; return p; } });
                \\  return f;
                \\})();
            );
            try new_target.set(rt, try global.getProperty(try rt.internAtom("dateNewTarget")));
            try constructor.set(rt, try global.getProperty(try rt.internAtom("Date")));
            const method = try global.getProperty(try rt.internAtom("dateConstructorCollect"));
            for ([_]core.runtime.MutableRootedValueRef{ first, later }) |root| {
                try root.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                try core.Object.fromHeader((try root.get(rt)).cycleMarkHeader().?).defineOwnProperty(rt, core.atom.ids.valueOf, core.Descriptor.data(method, .all));
            }
            if (multiple) probe.later_id = try rt.registerWeakObjectIdentity(core.Object.fromHeader((try later.get(rt)).cycleMarkHeader().?));
            break :setup [_]core.JSValue{ try new_target.get(rt), try first.get(rt), try later.get(rt), try constructor.get(rt) };
        };
        const before = rt.active_value_roots;
        const result = engine.exec.call_runtime.constructValueOrBytecodeWithNewTarget(js.context, null, global, inputs[3], inputs[1..@as(usize, if (multiple) 3 else 2)], null, null, inputs[0]);
        try std.testing.expect(!probe.lost);
        const date = core.Object.fromHeader((try result).cycleMarkHeader().?);
        const expected_prototype = try global.getProperty(try rt.internAtom("dateProto"));
        try std.testing.expectEqual(expected_prototype.bits, date.getPrototype().?.value().bits);
        try std.testing.expectEqual(@as(usize, if (multiple) 3 else 2), probe.calls);
        try std.testing.expect(rt.active_value_roots == before);
    }
}

test "date boundary setters retain receiver across argument coercion" {
    const Probe = struct {
        rt: *core.JSRuntime,
        receiver: ?*core.gc.Header = null,
        lost: bool = false,
        calls: usize = 0,
        fn collect(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = try self.rt.collectForTest();
            self.calls += 1;
            if (!self.rt.gc.containsHeader(self.receiver.?)) {
                self.lost = true;
                return error.LostDateReceiver;
            }
            return core.JSValue.int32(23);
        }
    };
    for (0..3) |mode| {
        var js = try helpers.TestEngine.init(std.testing.allocator);
        defer js.deinit();
        const rt = js.runtime;
        const global = try js.context.globalObject();
        var probe = Probe{ .rt = rt };
        try js.defineGlobalExternalHostFunction("dateRootCollect", 0, &probe, Probe.collect, null);
        const input = setup: {
            var roots = core.runtime.ExactValueRoots(2){};
            try roots.activate(rt);
            defer roots.deactivate();
            const arg = try roots.ref(0);
            const date = try roots.ref(1);
            try arg.set(rt, (try core.Object.createPlainObject(rt, null)).value());
            const method = try global.getProperty(try rt.internAtom("dateRootCollect"));
            try core.Object.fromHeader((try arg.get(rt)).cycleMarkHeader().?).defineOwnProperty(rt, core.atom.ids.valueOf, core.Descriptor.data(method, .all));
            try date.set(rt, try engine.exec.date_ops.construct(rt, &.{core.JSValue.int32(0)}));
            break :setup [_]core.JSValue{ try date.get(rt), try arg.get(rt) };
        };
        probe.receiver = input[0].cycleMarkHeader().?;
        const before = rt.active_value_roots;
        const result: ?core.JSValue = switch (mode) {
            0 => try engine.exec.date_ops.dateSetTime(js.context, null, global, input[0], input[1..]),
            1 => try engine.exec.date_ops.dateSetYear(js.context, null, global, input[0], input[1..]),
            else => try engine.exec.date_ops.dateExtendedPrototypeCall(js.context, null, global, input[0], .set_hours, input[1..]),
        };
        try std.testing.expect(!probe.lost);
        try std.testing.expect(result.?.isNumber());
        try std.testing.expectEqual(@as(usize, 1), probe.calls);
        try std.testing.expect(rt.active_value_roots == before);
    }
}

test "date boundary rope parsing and numeric conversion do not materialize" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const source = try roots.ref(0);
    const right = try roots.ref(1);
    const date = try roots.ref(2);
    try date.set(rt, try engine.exec.date_ops.construct(rt, &.{core.JSValue.int32(0)}));
    for (0..3) |mode| {
        const left_bytes: []const u8 = switch (mode) {
            0 => "1970-01-",
            1 => "19",
            else => "1",
        };
        const right_bytes: []const u8 = switch (mode) {
            0 => "01T00:00:00.000Z",
            1 => "70",
            else => "23",
        };
        try source.set(rt, (try core.string.String.createAscii(rt, left_bytes)).value());
        try right.set(rt, (try core.string.String.createAscii(rt, right_bytes)).value());
        const rope = try core.string.String.createRope(rt, try source.get(rt), try right.get(rt));
        try source.set(rt, rope.value());
        const first = switch (mode) {
            0 => try engine.exec.date_ops.staticCall(rt, .parse, &.{try source.get(rt)}),
            1 => try engine.exec.date_ops.staticCall(rt, .utc, &.{ try source.get(rt), core.JSValue.int32(0), core.JSValue.int32(1) }),
            else => try engine.exec.date_ops.methodCallArgs(rt, try date.get(rt), .set_time, &.{try source.get(rt)}),
        };
        try std.testing.expectEqual(@as(f64, if (mode == 2) 123 else 0), engine.exec.value_ops.numberValue(first).?);
        try std.testing.expect(!rope.isLinearized());
        const epoch = rt.gc.collection_epoch;
        const native_bytes = rt.allocation_diagnostics.allocated_bytes;
        rt.setMemoryLimit(0);
        defer rt.setMemoryLimit(null);
        rt.setNativeBytesLimitForTest(native_bytes);
        defer rt.setNativeBytesLimitForTest(null);
        const repeated = switch (mode) {
            0 => try engine.exec.date_ops.staticCall(rt, .parse, &.{try source.get(rt)}),
            1 => try engine.exec.date_ops.staticCall(rt, .utc, &.{ try source.get(rt), core.JSValue.int32(0), core.JSValue.int32(1) }),
            else => try engine.exec.date_ops.methodCallArgs(rt, try date.get(rt), .set_time, &.{try source.get(rt)}),
        };
        try std.testing.expectEqual(first.bits, repeated.bits);
        try std.testing.expect(!rope.isLinearized());
        try std.testing.expectEqual(epoch, rt.gc.collection_epoch);
        try std.testing.expectEqual(native_bytes, rt.allocation_diagnostics.allocated_bytes);
        rt.setMemoryLimit(null);
        rt.setNativeBytesLimitForTest(null);
    }
}

test "date boundary parsing preserves bounded UTF16 conversion across leaves" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(2){};
    try roots.activate(rt);
    defer roots.deactivate();
    const source = try roots.ref(0);
    const right = try roots.ref(1);
    var units: [129]u16 = @splat(' ');
    for ("Thu, 01 Jan 1970 00:00:00 GMT", 0..) |byte, index| units[index] = byte;
    // The parser buffers 127 code units; the whitespace suffix past it is
    // checked in place and never enters the buffer, even when it forces wide
    // rope storage (U+3000 IDEOGRAPHIC SPACE).
    units[128] = 0x3000;
    for ([_]usize{ 5, 23, 126, 127, 128 }) |split| {
        try source.set(rt, (try core.string.String.createUtf16(rt, units[0..split])).value());
        try right.set(rt, (try core.string.String.createUtf16(rt, units[split..])).value());
        const rope = try core.string.String.createRope(rt, try source.get(rt), try right.get(rt));
        try source.set(rt, rope.value());
        rt.setMemoryLimit(0);
        defer rt.setMemoryLimit(null);
        const epoch = rt.gc.collection_epoch;
        const parsed = try engine.exec.date_ops.staticCall(rt, .parse, &.{try source.get(rt)});
        try std.testing.expectEqual(@as(f64, 0), engine.exec.value_ops.numberValue(parsed).?);
        try std.testing.expect(!rope.isLinearized());
        try std.testing.expectEqual(epoch, rt.gc.collection_epoch);
        rt.setMemoryLimit(null);
    }
    try source.set(rt, (try core.string.String.createUtf16(rt, &.{0x2212})).value());
    try right.set(rt, (try core.string.String.createAscii(rt, "000001-01-01")).value());
    const rope = try core.string.String.createRope(rt, try source.get(rt), try right.get(rt));
    try source.set(rt, rope.value());
    const parsed = try engine.exec.date_ops.staticCall(rt, .parse, &.{try source.get(rt)});
    try std.testing.expectEqual(@as(f64, -62198755200000), engine.exec.value_ops.numberValue(parsed).?);
    try std.testing.expect(!rope.isLinearized());
    try core.string.ensureFlat(rt, source.readOnly(), right);
    const cached = try engine.exec.date_ops.staticCall(rt, .parse, &.{try source.get(rt)});
    try std.testing.expectEqual(parsed.bits, cached.bits);
}

test "string boundary URI paths preserve rope input without materialization" {
    const cases = [_]struct { mode: u8, left: []const u16, right: []const u16, expected: []const u8 }{
        .{ .mode = 1, .left = &.{ 'a', 0xd83d }, .right = &.{ 0xde00, '/' }, .expected = "a%F0%9F%98%80/" },
        .{ .mode = 2, .left = &.{ 'a', 0xd83d }, .right = &.{ 0xde00, '/' }, .expected = "a%F0%9F%98%80%2F" },
        .{ .mode = 3, .left = &.{ 0x100, '%', '2' }, .right = &.{ '3', 0xd83d, 0xde00 }, .expected = "\xc4\x80%23\xf0\x9f\x98\x80" },
        .{ .mode = 4, .left = &.{ 0x100, '%', '2' }, .right = &.{ '3', 0xd83d, 0xde00 }, .expected = "\xc4\x80#\xf0\x9f\x98\x80" },
        .{ .mode = 5, .left = &.{0xd83d}, .right = &.{ 0xde00, '/' }, .expected = "%uD83D%uDE00/" },
        .{ .mode = 6, .left = &.{ '%', 'u', 'D', '8' }, .right = &.{ '3', 'D', '%', 'u', 'D', 'E', '0', '0', '/' }, .expected = "\xf0\x9f\x98\x80/" },
    };
    for (cases) |case| {
        const rt = try core.JSRuntime.create(std.testing.allocator, .{});
        defer rt.destroy();
        const ctx = try core.JSContext.create(rt, .{});
        defer ctx.destroy();
        var roots = core.runtime.ExactValueRoots(2){};
        try roots.activate(rt);
        defer roots.deactivate();
        const source = try roots.ref(0);
        const right = try roots.ref(1);
        try source.set(rt, (try core.string.String.createUtf16(rt, case.left)).value());
        try right.set(rt, (try core.string.String.createUtf16(rt, case.right)).value());
        const rope = try core.string.String.createRope(rt, try source.get(rt), try right.get(rt));
        try source.set(rt, rope.value());
        const result = switch (case.mode) {
            5 => try engine.exec.uri_ops.escape(rt, try source.get(rt)),
            6 => try engine.exec.uri_ops.unescape(rt, try source.get(rt)),
            else => try engine.exec.uri_ops.call(ctx, null, case.mode, try source.get(rt)),
        };
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.nativeAllocator());
        try core.string.appendValueUtf8(rt, &bytes, result);
        try std.testing.expectEqualStrings(case.expected, bytes.items);
        try std.testing.expect(!rope.isLinearized());
        rt.setMemoryLimit(0);
        defer rt.setMemoryLimit(null);
        const before = rt.active_value_roots;
        const failed = switch (case.mode) {
            5 => engine.exec.uri_ops.escape(rt, try source.get(rt)),
            6 => engine.exec.uri_ops.unescape(rt, try source.get(rt)),
            else => engine.exec.uri_ops.call(ctx, null, case.mode, try source.get(rt)),
        };
        try std.testing.expectError(error.OutOfMemory, failed);
        try std.testing.expect(!rope.isLinearized());
        try std.testing.expect(rt.active_value_roots == before and rt.active_no_gc_scope == null);
        rt.setMemoryLimit(null);
        const native_bytes = rt.allocation_diagnostics.allocated_bytes;
        rt.setNativeBytesLimitForTest(native_bytes);
        defer rt.setNativeBytesLimitForTest(null);
        const native_failed = switch (case.mode) {
            5 => engine.exec.uri_ops.escape(rt, try source.get(rt)),
            6 => engine.exec.uri_ops.unescape(rt, try source.get(rt)),
            else => engine.exec.uri_ops.call(ctx, null, case.mode, try source.get(rt)),
        };
        try std.testing.expectError(error.OutOfMemory, native_failed);
        rt.setNativeBytesLimitForTest(null);
        try std.testing.expectEqual(native_bytes, rt.allocation_diagnostics.allocated_bytes);
        try std.testing.expect(rt.active_no_gc_scope == null);
        try std.testing.expect(!rope.isLinearized());
        try core.string.ensureFlat(rt, source.readOnly(), right);
        try std.testing.expect(rope.isLinearized());
        // A cached rope remains a rope-tagged input; its projection must not
        // accidentally go through a flat-only or byte-string fallback.
        const cached_result = switch (case.mode) {
            5 => try engine.exec.uri_ops.escape(rt, try source.get(rt)),
            6 => try engine.exec.uri_ops.unescape(rt, try source.get(rt)),
            else => try engine.exec.uri_ops.call(ctx, null, case.mode, try source.get(rt)),
        };
        bytes.clearRetainingCapacity();
        try core.string.appendValueUtf8(rt, &bytes, cached_result);
        try std.testing.expectEqualStrings(case.expected, bytes.items);
    }
}

test "string boundary URI malformed and unchanged ropes need no materialization" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    var roots = core.runtime.ExactValueRoots(2){};
    try roots.activate(rt);
    defer roots.deactivate();
    const source = try roots.ref(0);
    const right = try roots.ref(1);
    for ([_][]const u16{ &.{0xdc00}, &.{0xd800}, &.{ 0xd800, 'a' } }) |suffix| {
        try source.set(rt, (try core.string.String.createAscii(rt, "a")).value());
        try right.set(rt, (try core.string.String.createUtf16(rt, suffix)).value());
        const rope = try core.string.String.createRope(rt, try source.get(rt), try right.get(rt));
        try source.set(rt, rope.value());
        rt.setMemoryLimit(0);
        defer rt.setMemoryLimit(null);
        const epoch = rt.gc.collection_epoch;
        try std.testing.expectError(error.URIError, engine.exec.uri_ops.call(ctx, null, 2, try source.get(rt)));
        // With no escapes, decode must return even an unpaired surrogate as
        // the original string, without allocating a flat representation.
        const unchanged = try engine.exec.uri_ops.call(ctx, null, 4, try source.get(rt));
        try std.testing.expectEqual((try source.get(rt)).bits, unchanged.bits);
        try std.testing.expect(!rope.isLinearized());
        try std.testing.expectEqual(epoch, rt.gc.collection_epoch);
        try std.testing.expect(rt.active_no_gc_scope == null);
        rt.setMemoryLimit(null);
    }
    try source.set(rt, (try core.string.String.createAscii(rt, "%")).value());
    try right.set(rt, (try core.string.String.createUtf16(rt, &.{ '4', '1', 0xd800 })).value());
    const rope = try core.string.String.createRope(rt, try source.get(rt), try right.get(rt));
    try source.set(rt, rope.value());
    const decoded = try engine.exec.uri_ops.call(ctx, null, 4, try source.get(rt));
    try std.testing.expectEqual(@as(usize, 2), core.string.stringValueLenUnchecked(decoded));
    try std.testing.expectEqual(@as(u16, 'A'), core.string.stringValueCodeUnitAtUnchecked(decoded, 0));
    try std.testing.expectEqual(@as(u16, 0xd800), core.string.stringValueCodeUnitAtUnchecked(decoded, 1));
    try std.testing.expect(!rope.isLinearized());
}

test "string boundary regexp escape preserves rope input" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const left = try roots.ref(0);
    const right = try roots.ref(1);
    const source = try roots.ref(2);
    try left.set(rt, (try core.string.String.createUtf16(rt, &.{ 'a', '.', 0xd83d })).value());
    try right.set(rt, (try core.string.String.createUtf16(rt, &.{ 0xde00, 0xd800, '-', ' ' })).value());
    const rope = try core.string.String.createRope(rt, try left.get(rt), try right.get(rt));
    try source.set(rt, rope.value());
    const result = try engine.exec.regexp_ops.escape(rt, &.{try source.get(rt)});
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try engine.exec.string_ops.appendSourceStringUtf8(rt, &bytes, result);
    try std.testing.expectEqualStrings("\\x61\\.\xf0\x9f\x98\x80\\ud800\\x2d\\x20", bytes.items);
    try std.testing.expect(!rope.isLinearized());
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, engine.exec.regexp_ops.escape(rt, &.{try source.get(rt)}));
    try std.testing.expect(!rope.isLinearized());
    try std.testing.expect(rt.active_no_gc_scope == null);
    rt.setMemoryLimit(null);
    const native_bytes = rt.allocation_diagnostics.allocated_bytes;
    rt.setNativeBytesLimitForTest(native_bytes);
    defer rt.setNativeBytesLimitForTest(null);
    try std.testing.expectError(error.OutOfMemory, engine.exec.regexp_ops.escape(rt, &.{try source.get(rt)}));
    rt.setNativeBytesLimitForTest(null);
    try std.testing.expectEqual(native_bytes, rt.allocation_diagnostics.allocated_bytes);
    try std.testing.expect(rt.active_no_gc_scope == null);
    try std.testing.expect(!rope.isLinearized());
}

test "value boundary pending exception classification avoids rope materialization" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const left = try roots.ref(0);
    const right = try roots.ref(1);
    const source = try roots.ref(2);
    try left.set(rt, (try core.string.String.createAscii(rt, "Type")).value());
    try right.set(rt, (try core.string.String.createUtf16(rt, &.{ 'E', 'r', 'r', 'o', 'r' })).value());
    const rope = try core.string.String.createRope(rt, try left.get(rt), try right.get(rt));
    try source.set(rt, rope.value());
    const object = try core.Object.createPlainObject(rt, null);
    try object.defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.data(try source.get(rt), .all));
    _ = ctx.throwValue(object.value());
    const pending = rt.exception.value;
    const epoch = rt.gc.collection_epoch;
    try std.testing.expect(engine.exec.exception_ops.pendingExceptionMatchesError(ctx, error.TypeError));
    try std.testing.expect(!rope.isLinearized());
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
    defer rt.setNativeBytesLimitForTest(null);
    try std.testing.expect(engine.exec.exception_ops.pendingExceptionMatchesError(ctx, error.TypeError));
    try std.testing.expect(!engine.exec.exception_ops.pendingExceptionMatchesError(ctx, error.RangeError));
    try std.testing.expect(engine.exec.exception_ops.pendingExceptionMatchesError(ctx, error.JSException));
    try std.testing.expect(pending.same(rt.exception.value));
    try std.testing.expectEqual(epoch, rt.gc.collection_epoch);
    try std.testing.expect(!rope.isLinearized());
}

test "value boundary property key ready probe avoids rope materialization" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const left = try roots.ref(0);
    const right = try roots.ref(1);
    const source = try roots.ref(2);
    try left.set(rt, (try core.string.String.createAscii(rt, "property-")).value());
    try right.set(rt, (try core.string.String.createAscii(rt, "key")).value());
    const rope = try core.string.String.createRope(rt, try left.get(rt), try right.get(rt));
    try source.set(rt, rope.value());
    const epoch = rt.gc.collection_epoch;
    try std.testing.expect(property_ops.propertyKeyAtomIfReady(try source.get(rt)) == null);
    try std.testing.expect(!rope.isLinearized());
    try std.testing.expectEqual(epoch, rt.gc.collection_epoch);
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try std.testing.expect(property_ops.propertyKeyAtomIfReady(try source.get(rt)) == null);
    try std.testing.expectError(error.OutOfMemory, property_ops.propertyKeyAtom(rt, try source.get(rt)));
    try std.testing.expect(!rope.isLinearized());
    rt.setMemoryLimit(null);
    const key = try property_ops.propertyKeyAtom(rt, try source.get(rt));
    try std.testing.expectEqualStrings("property-key", rt.atoms.name(key).?);
    try std.testing.expectEqual(key, property_ops.propertyKeyAtomIfReady(try source.get(rt)).?);
}

test "value boundary native method OOM retains installation target" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval("0;");
    const rt = js.runtime;
    const target = try core.Object.createPlainObject(rt, null);
    const header = target.gcHeader();
    const before = rt.active_value_roots;
    rt.forcePreciseRootScanForTest();
    defer rt.restoreDefaultRootScanForTest();
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, core.function.defineNativeMethod(js.context, target, "rootedNativeMethod", 2));
    try std.testing.expect(rt.gc.containsHeader(header));
    try std.testing.expect(rt.active_value_roots == before);
    rt.setMemoryLimit(null);
    const method = try core.function.defineNativeMethod(js.context, target, "rootedNativeMethod", 2);
    const key = try rt.internAtom("rootedNativeMethod");
    try std.testing.expect((try target.getProperty(key)).same(method));
    try std.testing.expect(rt.active_value_roots == before);
}

test "string boundary iterator completion OOM retains receiver and target" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval("0;");
    const rt = js.runtime;
    const source = (try core.string.String.createAscii(rt, "iterator-source")).value();
    const value = try engine.exec.string_ops.stringIterator(js.context, source);
    const iterator = core.value_semantics.objectFromValue(value).?;
    iterator.iteratorIndexSlot().* = core.string.stringValueLenUnchecked(source);
    const header = iterator.gcHeader();
    const source_header = source.cycleMarkHeader().?;
    const before = rt.active_value_roots;
    rt.forcePreciseRootScanForTest();
    defer rt.restoreDefaultRootScanForTest();
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.stringIteratorNext(rt, null, value));
    try std.testing.expect(rt.gc.containsHeader(header));
    try std.testing.expect(rt.gc.containsHeader(source_header));
    try std.testing.expect(iterator.iteratorTargetSlot().* != null);
    try std.testing.expect(rt.active_value_roots == before);
    rt.setMemoryLimit(null);
    const result = try engine.exec.string_ops.stringIteratorNext(rt, null, value);
    const completed = core.value_semantics.objectFromValue(result).?;
    try std.testing.expectEqual(true, (try completed.getProperty(core.atom.ids.done)).as(.boolean).?);
    try std.testing.expect(iterator.iteratorTargetSlot().* == null);
    try std.testing.expect(rt.active_value_roots == before);
}

test "string boundary case conversion propagates rope OOM and retries" {
    for ([_]u32{ 2, 3 }) |method| {
        const rt = try core.JSRuntime.create(std.testing.allocator, .{});
        defer rt.destroy();
        var roots = core.runtime.ExactValueRoots(3){};
        try roots.activate(rt);
        defer roots.deactivate();
        const left = try roots.ref(0);
        const right = try roots.ref(1);
        const source = try roots.ref(2);
        try left.set(rt, (try core.string.String.createUtf16(rt, &.{ 'A', 0x3a3 })).value());
        try right.set(rt, (try core.string.String.createUtf16(rt, &.{ ' ', 0xdf, 0xd800 })).value());
        const rope = try core.string.String.createRope(rt, try left.get(rt), try right.get(rt));
        try source.set(rt, rope.value());
        const before = rt.active_value_roots;
        rt.setMemoryLimit(0);
        defer rt.setMemoryLimit(null);
        try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.unicodeCaseString(rt, try source.get(rt), method == 3));
        try std.testing.expect(!rope.isLinearized());
        try std.testing.expect(rt.active_value_roots == before);
        try std.testing.expect(rt.active_no_gc_scope == null);
        rt.setMemoryLimit(null);
        const result = try engine.exec.string_ops.unicodeCaseString(rt, try source.get(rt), method == 3);
        var units = std.ArrayList(u16).empty;
        defer units.deinit(rt.nativeAllocator());
        try engine.exec.string_ops.appendStringValueUnits(rt, &units, result);
        const expected: []const u16 = if (method == 2) &.{ 'A', 0x3a3, ' ', 'S', 'S', 0xd800 } else &.{ 'a', 0x3c2, ' ', 0xdf, 0xd800 };
        try std.testing.expectEqualSlices(u16, expected, units.items);
        // With the cached flat input, heap failure occurs at result creation
        // after the Unicode scan has ended its borrow.
        rt.setMemoryLimit(0);
        try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.unicodeCaseString(rt, try source.get(rt), method == 3));
        rt.setMemoryLimit(null);
        const native_bytes = rt.allocation_diagnostics.allocated_bytes;
        rt.setNativeBytesLimitForTest(native_bytes);
        defer rt.setNativeBytesLimitForTest(null);
        try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.unicodeCaseString(rt, try source.get(rt), method == 3));
        rt.setNativeBytesLimitForTest(null);
        try std.testing.expectEqual(native_bytes, rt.allocation_diagnostics.allocated_bytes);
        try std.testing.expect(rt.active_no_gc_scope == null);
        try std.testing.expect(rt.active_value_roots == before);
    }
}

test "string boundary split propagates rope OOM and retries" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const left = try roots.ref(0);
    const right = try roots.ref(1);
    const source = try roots.ref(2);
    try left.set(rt, (try core.string.String.createUtf16(rt, &.{ 0x100, ',' })).value());
    try right.set(rt, (try core.string.String.createUtf16(rt, &.{ 0xd800, ',' })).value());
    const rope = try core.string.String.createRope(rt, try left.get(rt), try right.get(rt));
    try source.set(rt, rope.value());
    try left.set(rt, (try core.string.String.createAscii(rt, ",")).value());
    const before = rt.active_value_roots;
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.methodCall(rt, try source.get(rt), 27, &.{try left.get(rt)}));
    try std.testing.expect(!rope.isLinearized());
    try std.testing.expect(rt.active_value_roots == before);
    rt.setMemoryLimit(null);
    const result = try engine.exec.string_ops.methodCall(rt, try source.get(rt), 27, &.{try left.get(rt)});
    const array = core.value_semantics.objectFromValue(result).?;
    try std.testing.expectEqual(@as(i32, 3), (try array.getProperty(core.atom.ids.length)).as(.int).?);
    try std.testing.expectEqual(@as(u16, 0x100), core.string.stringValueCodeUnitAtUnchecked(try array.getProperty(core.Atom.taggedInt(0)), 0));
    try std.testing.expectEqual(@as(u16, 0xd800), core.string.stringValueCodeUnitAtUnchecked(try array.getProperty(core.Atom.taggedInt(1)), 0));
    try std.testing.expectEqual(@as(usize, 0), core.string.stringValueLenUnchecked(try array.getProperty(core.Atom.taggedInt(2))));
    try std.testing.expect(rt.active_value_roots == before);
}

test "string boundary wrapper and repeat preserve rope input" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const left = try roots.ref(0);
    const right = try roots.ref(1);
    const source = try roots.ref(2);
    try left.set(rt, (try core.string.String.createAscii(rt, "a")).value());
    try right.set(rt, (try core.string.String.createUtf16(rt, &.{ 0x100, 0xd800 })).value());
    const rope = try core.string.String.createRope(rt, try left.get(rt), try right.get(rt));
    try source.set(rt, rope.value());
    const wrapped = try engine.exec.string_ops.constructWithPrototype(rt, &.{try source.get(rt)}, null);
    const object = core.value_semantics.objectFromValue(wrapped).?;
    try std.testing.expect(object.objectData().?.same(try source.get(rt)));
    try std.testing.expectEqual(@as(i32, 3), (try object.getProperty(core.atom.ids.length)).as(.int).?);
    try std.testing.expectEqual(@as(u16, 0xd800), core.string.stringValueCodeUnitAtUnchecked(try object.getProperty(core.Atom.taggedInt(2)), 0));
    try std.testing.expect(!rope.isLinearized());
    const repeated = try engine.exec.string_ops.methodCall(rt, try source.get(rt), 33, &.{core.JSValue.int32(3)});
    var units = std.ArrayList(u16).empty;
    defer units.deinit(rt.nativeAllocator());
    try engine.exec.string_ops.appendStringValueUnits(rt, &units, repeated);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 0x100, 0xd800, 'a', 0x100, 0xd800, 'a', 0x100, 0xd800 }, units.items);
    try std.testing.expect(!rope.isLinearized());
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.constructWithPrototype(rt, &.{try source.get(rt)}, null));
    try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.methodCall(rt, try source.get(rt), 33, &.{core.JSValue.int32(3)}));
    try std.testing.expect(!rope.isLinearized());
    try std.testing.expect(rt.active_no_gc_scope == null);
}

test "primitive boxing boundary preserves rope during property access" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try engine.exec.zjs_vm.contextGlobal(ctx);
    var roots = core.runtime.ExactValueRoots(2){};
    try roots.activate(rt);
    defer roots.deactivate();
    const input = try roots.ref(0);
    const right = try roots.ref(1);
    try input.set(rt, (try core.string.String.createAscii(rt, "a")).value());
    try right.set(rt, (try core.string.String.createUtf16(rt, &.{ 0x100, 0xd800 })).value());
    try input.set(rt, (try core.string.String.createRope(rt, try input.get(rt), try right.get(rt))).value());
    const result = try object_ops.primitiveObjectForAccess(rt, global, try input.get(rt));
    const wrapper = core.Object.fromHeader(result.refHeader().?);
    try std.testing.expect(wrapper.objectData().?.same(try input.get(rt)));
    try std.testing.expectEqual(@as(?i32, 3), (try wrapper.getProperty(core.atom.ids.length)).as(.int));
    try std.testing.expect(!(try input.get(rt)).ropeBody().?.isLinearized());
}

test "primitive boxing boundary shares UTF16 indices and descriptors" {
    const units = [_]u16{ 'A', 0xe9, 0x100, 0xd83d, 0xde00, 0xd800, 0xdc00, 0 };
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try engine.exec.zjs_vm.contextGlobal(ctx);
    const prototype = object_ops.primitivePrototypeFromRealmOrGlobal(rt, global, .string_prototype, comptime core.atom.predefinedId("String", .string).?).?;
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const input = try roots.ref(0);
    const right = try roots.ref(1);
    const output = try roots.ref(2);
    for (0..3) |mode| {
        for (0..(if (mode == 0) @as(usize, 1) else units.len + 1)) |split| {
            try input.set(rt, (try core.string.String.createUtf16(rt, if (mode == 0) &units else units[0..split])).value());
            if (mode != 0) {
                try right.set(rt, (try core.string.String.createUtf16(rt, units[split..])).value());
                try input.set(rt, (try core.string.String.createRope(rt, try input.get(rt), try right.get(rt))).value());
                if (mode == 2) try core.string.ensureFlat(rt, input.readOnly(), right);
            }
            for ([_]bool{ false, true }) |access| {
                try output.set(rt, if (access) try object_ops.primitiveObjectForAccess(rt, global, try input.get(rt)) else try engine.exec.call.primitiveWrapper(ctx, core.class.ids.string, try input.get(rt), prototype));
                const object = core.Object.fromHeader((try output.get(rt)).refHeader().?);
                try std.testing.expect(object.getPrototype() == prototype);
                const length = (try object.getOwnProperty(rt, core.atom.ids.length)).?;
                try std.testing.expectEqual(@as(?i32, units.len), length.value.as(.int));
                try std.testing.expect(!length.writable.? and !length.enumerable.? and !length.configurable.?);
                for (units, 0..) |unit, index| {
                    const descriptor = (try object.getOwnProperty(rt, core.Atom.taggedInt(@intCast(index)))).?;
                    try std.testing.expect(descriptor.enumerable.? and !descriptor.writable.? and !descriptor.configurable.?);
                    try std.testing.expectEqual(@as(usize, 1), core.string.stringValueLenUnchecked(descriptor.value));
                    try std.testing.expectEqual(unit, core.string.stringValueCodeUnitAtUnchecked(descriptor.value, 0));
                    if (unit < 0x100) try std.testing.expect(descriptor.value.same((try rt.singleByteString(@intCast(unit))).value()));
                }
                if (mode != 0) try std.testing.expectEqual(mode == 2, (try input.get(rt)).ropeBody().?.isLinearized());
            }
        }
    }
}

test "primitive boxing boundary cleans partial wrappers on native allocation failure" {
    const units = [_]u16{0x100} ** 256;
    var saw_failure = false;
    var saw_success = false;
    for (0..128) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.JSRuntime.create(failing.allocator(), .{});
        defer rt.destroy();
        const global = try core.Object.createPlainObject(rt, null);
        const prototype = try core.Object.createPlainObject(rt, null);
        const constructor = try core.Object.createPlainObject(rt, null);
        try constructor.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(prototype.value(), .all));
        try global.defineOwnProperty(rt, comptime core.atom.predefinedId("String", .string).?, core.Descriptor.data(constructor.value(), .all));
        const input = (try core.string.String.createUtf16(rt, &units)).value();
        const before = rt.active_value_roots;
        failing.fail_index = failing.alloc_index + offset;
        failing.resize_fail_index = failing.resize_index;
        const result = object_ops.primitiveObjectForAccess(rt, global, input);
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        try std.testing.expect(rt.active_value_roots == before);
        if (result) |value| {
            try std.testing.expectEqual(@as(?i32, units.len), (try core.Object.fromHeader(value.refHeader().?).getProperty(core.atom.ids.length)).as(.int));
            saw_success = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            saw_failure = true;
        }
    }
    try std.testing.expect(saw_failure);
    try std.testing.expect(saw_success);
}

test "string boundary searches propagate source and needle materialization OOM" {
    for ([_]u32{ 4, 28, 5, 6, 7 }) |method| {
        const rt = try core.JSRuntime.create(std.testing.allocator, .{});
        defer rt.destroy();
        var roots = core.runtime.ExactValueRoots(4){};
        try roots.activate(rt);
        defer roots.deactivate();
        const left = try roots.ref(0);
        const right = try roots.ref(1);
        const source = try roots.ref(2);
        const needle = try roots.ref(3);
        try left.set(rt, (try core.string.String.createAscii(rt, "ab")).value());
        try right.set(rt, (try core.string.String.createAscii(rt, "ab")).value());
        const source_rope = try core.string.String.createRope(rt, try left.get(rt), try right.get(rt));
        try source.set(rt, source_rope.value());
        try left.set(rt, (try core.string.String.createAscii(rt, "a")).value());
        try right.set(rt, (try core.string.String.createAscii(rt, "b")).value());
        const needle_rope = try core.string.String.createRope(rt, try left.get(rt), try right.get(rt));
        try needle.set(rt, needle_rope.value());
        rt.setMemoryLimit(0);
        defer rt.setMemoryLimit(null);
        try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.methodCall(rt, try source.get(rt), method, &.{try needle.get(rt)}));
        try std.testing.expect(!source_rope.isLinearized());
        try std.testing.expect(!needle_rope.isLinearized());
        rt.setMemoryLimit(null);
        try core.string.ensureFlat(rt, source.readOnly(), left);
        rt.setMemoryLimit(0);
        try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.methodCall(rt, try source.get(rt), method, &.{try needle.get(rt)}));
        try std.testing.expect(!needle_rope.isLinearized());
        try std.testing.expect(rt.active_no_gc_scope == null);
        rt.setMemoryLimit(null);
        const result = try engine.exec.string_ops.methodCall(rt, try source.get(rt), method, &.{try needle.get(rt)});
        if (method == 4 or method == 28) {
            try std.testing.expectEqual(@as(i32, if (method == 4) 0 else 2), result.as(.int).?);
        } else try std.testing.expectEqual(true, result.as(.boolean).?);
    }
}

test "string boundary rope metadata trim and wellformed scans avoid flattening" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(4){};
    try roots.activate(rt);
    defer roots.deactivate();
    const left = try roots.ref(0);
    const right = try roots.ref(1);
    const input = try roots.ref(2);
    const owner = try roots.ref(3);
    try left.set(rt, (try core.string.String.createUtf16(rt, &.{ ' ', 0xd800 })).value());
    try right.set(rt, (try core.string.String.createUtf16(rt, &.{ 0xdc00, 0xdc01, ' ' })).value());
    const rope = try core.string.String.createRope(rt, try left.get(rt), try right.get(rt));
    try input.set(rt, rope.value());
    try owner.set(rt, (try core.Object.create(rt, core.class.ids.string, null)).value());
    const object = core.value_semantics.objectFromValue(try owner.get(rt)).?;
    try object.setOptionalValueSlot(rt, object.objectDataSlot(), try input.get(rt));
    try std.testing.expect(engine.exec.string_ops.stringAtomId(try input.get(rt)) == null);
    try std.testing.expect(engine.exec.string_ops.stringObjectHasIndexProperty(rt, object, core.Atom.taggedInt(4)));
    try std.testing.expect(!engine.exec.string_ops.stringObjectHasIndexProperty(rt, object, core.Atom.taggedInt(5)));
    try std.testing.expect(!rope.isLinearized());
    const methods = [_]u32{ 8, 21, 22, 38, 39 };
    for (methods) |method| {
        const result = try engine.exec.string_ops.methodCall(rt, try input.get(rt), method, &.{});
        if (method == 38) {
            try std.testing.expectEqual(false, result.as(.boolean).?);
        } else {
            var units = std.ArrayList(u16).empty;
            defer units.deinit(rt.nativeAllocator());
            try engine.exec.string_ops.appendStringValueUnits(rt, &units, result);
            const expected: []const u16 = switch (method) {
                8 => &.{ 0xd800, 0xdc00, 0xdc01 },
                21 => &.{ 0xd800, 0xdc00, 0xdc01, ' ' },
                22 => &.{ ' ', 0xd800, 0xdc00, 0xdc01 },
                else => &.{ ' ', 0xd800, 0xdc00, 0xfffd, ' ' },
            };
            try std.testing.expectEqualSlices(u16, expected, units.items);
        }
        try std.testing.expect(!rope.isLinearized());
    }
    const epoch = rt.gc.collection_epoch;
    const allocations = rt.allocation_diagnostics.allocation_count;
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try std.testing.expect(engine.exec.string_ops.stringAtomId(try input.get(rt)) == null);
    try std.testing.expect(engine.exec.string_ops.stringObjectHasIndexProperty(rt, object, core.Atom.taggedInt(4)));
    try std.testing.expectEqual(false, (try engine.exec.string_ops.methodCall(rt, try input.get(rt), 38, &.{})).as(.boolean).?);
    try std.testing.expectEqual(epoch, rt.gc.collection_epoch);
    try std.testing.expectEqual(allocations, rt.allocation_diagnostics.allocation_count);
    try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.methodCall(rt, try input.get(rt), 8, &.{}));
    try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.methodCall(rt, try input.get(rt), 39, &.{}));
    try std.testing.expect(!rope.isLinearized());
    try std.testing.expect(rt.active_no_gc_scope == null);
    rt.setMemoryLimit(null);
    try core.string.ensureFlat(rt, input.readOnly(), right);
    const flat = core.string.asFlat(try right.get(rt)).?;
    const atom = try flat.internAtom(rt);
    try std.testing.expectEqual(atom, engine.exec.string_ops.stringAtomId(try input.get(rt)).?);
    try std.testing.expectEqual(atom, engine.exec.string_ops.stringAtomId(try right.get(rt)).?);
}

test "string boundary conversion chains retain converted source" {
    const Probe = struct {
        rt: *core.JSRuntime,
        source: ?*core.gc.Header = null,
        calls: usize = 0,
        lost: bool = false,
        fn make(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const value = (try core.string.String.createUtf16(self.rt, &.{ 'e', 0x301 })).value();
            self.source = value.cycleMarkHeader().?;
            return value;
        }
        fn collect(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = try self.rt.collectForTest();
            if (!self.rt.gc.containsHeader(self.source orelse return error.MissingUnicodeSource)) {
                self.lost = true;
                return error.LostUnicodeSource;
            }
            self.calls += 1;
            return core.JSValue.undefinedValue();
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var probe = Probe{ .rt = js.runtime };
    try js.defineGlobalExternalHostFunction("unicodeSource", 0, &probe, Probe.make, null);
    try js.defineGlobalExternalHostFunction("unicodeCollect", 0, &probe, Probe.collect, null);
    js.runtime.forcePreciseRootScanForTest();
    defer js.runtime.restoreDefaultRootScanForTest();
    const root_head = js.runtime.active_value_roots;
    const result = js.eval(
        \\assert.sameValue(String.prototype.normalize.call({ toString: unicodeSource },
        \\  { toString() { unicodeCollect(); return 'NFC'; } }), '\u00e9');
        \\assert.sameValue(String.prototype.localeCompare.call({ toString: unicodeSource },
        \\  { toString() { unicodeCollect(); return '\u00e9'; } }), 0);
        \\for (const name of ['indexOf', 'lastIndexOf', 'includes', 'startsWith', 'endsWith']) {
        \\  const result = String.prototype[name].call({ toString: unicodeSource },
        \\    { get [Symbol.match]() { unicodeCollect(); return false; },
        \\      toString() { unicodeCollect(); return 'e'; } },
        \\    { valueOf() { unicodeCollect(); return name === 'endsWith' ? 1 : 0; } });
        \\  assert.sameValue(result, name === 'indexOf' || name === 'lastIndexOf' ? 0 : true);
        \\}
        \\assert.throws(RangeError, function () {
        \\  String.prototype.normalize.call({ toString: unicodeSource },
        \\    { toString() { unicodeCollect(); return 'invalid'; } });
        \\});
        \\try { String.prototype.localeCompare.call({ toString: unicodeSource },
        \\  { toString() { unicodeCollect(); throw 17; } }); } catch (e) { assert.sameValue(e, 17); }
        \\try { String.prototype.indexOf.call({ toString: unicodeSource }, 'e',
        \\  { valueOf() { unicodeCollect(); throw 18; } }); } catch (e) { assert.sameValue(e, 18); }
    );
    try std.testing.expect(!probe.lost);
    _ = try result;
    try std.testing.expectEqual(@as(usize, 18), probe.calls);
    try std.testing.expect(js.runtime.active_value_roots == root_head);
}

test "string boundary generic regexp replace retains source across callbacks" {
    const Probe = struct {
        rt: *core.JSRuntime,
        source: ?*core.gc.Header = null,
        calls: usize = 0,
        fn make(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const value = (try core.string.String.createAscii(self.rt, "abc")).value();
            self.source = value.cycleMarkHeader().?;
            return value;
        }
        fn collect(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = try self.rt.collectForTest();
            if (!self.rt.gc.containsHeader(self.source orelse return error.MissingReplaceSource))
                return error.LostReplaceSource;
            self.calls += 1;
            return core.JSValue.undefinedValue();
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var probe = Probe{ .rt = js.runtime };
    try js.defineGlobalExternalHostFunction("replaceSource", 0, &probe, Probe.make, null);
    try js.defineGlobalExternalHostFunction("replaceCollect", 0, &probe, Probe.collect, null);
    js.runtime.forcePreciseRootScanForTest();
    defer js.runtime.restoreDefaultRootScanForTest();
    _ = try js.eval(
        \\const rx = { get flags() { replaceCollect(); return ''; },
        \\  exec() { return { 0: 'b', length: 1, index: 1 }; } };
        \\assert.sameValue(RegExp.prototype[Symbol.replace].call(rx,
        \\  { toString: replaceSource }, function () { replaceCollect(); return 'X'; }), 'aXc');
        \\rx.exec = function () { return { 0: 'b', length: 1, index: 1,
        \\  groups: { get x() { replaceCollect(); return { toString() { replaceCollect(); return 'X'; } }; } } }; };
        \\assert.sameValue(RegExp.prototype[Symbol.replace].call(rx,
        \\  { toString: replaceSource }, '$<x>$<x>'), 'aXXc');
    );
    try std.testing.expectEqual(@as(usize, 7), probe.calls);
}

const matchAllDispatchFixture =
    \\let log = [];
    \\const receiver = { toString() { log.push('coerce'); return 'a'; } };
    \\const regexp = {
    \\  get [Symbol.match]() { log.push('match'); return true; },
    \\  get flags() { log.push('flags'); return { toString() { log.push('flagsString'); return 'g'; } }; },
    \\  get [Symbol.matchAll]() { log.push('method'); return function (v) { log.push('call'); print(v === receiver); return 7; }; }
    \\};
    \\print(String.prototype.matchAll.call(receiver, regexp));
    \\print(log.join(','));
    \\log = [];
    \\const invalid = { get [Symbol.match]() { log.push('match'); return false; },
    \\  get [Symbol.matchAll]() { log.push('method'); return 42; } };
    \\try { String.prototype.matchAll.call(receiver, invalid); } catch (e) { print(e.name); }
    \\print(log.join(','));
    \\let sourceCalls = 0, patternCalls = 0;
    \\const fallback = String.prototype.matchAll.call({ toString() { sourceCalls++; return 'aba'; } },
    \\  { toString() { patternCalls++; return 'a'; } });
    \\print(fallback.next().value[0], sourceCalls, patternCalls);
;

test "string boundary matchAll dispatch preserves receiver and observable order" {
    try helpers.expectPrints(matchAllDispatchFixture, "true\n7\nmatch,flags,flagsString,method,call\nTypeError\nmatch,method\na 1 1\n");
}

test "string boundary matchAll dispatch roots converted source across pattern GC" {
    const Probe = struct {
        rt: *core.JSRuntime,
        source: ?*core.gc.Header = null,
        calls: usize = 0,
        fn create(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const value = (try core.string.String.createAscii(self.rt, "aba")).value();
            self.source = value.cycleMarkHeader().?;
            return value;
        }
        fn collect(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = try self.rt.collectForTest();
            if (!self.rt.gc.containsHeader(self.source orelse return error.MissingMatchAllSource))
                return error.LostMatchAllSource;
            self.calls += 1;
            return core.JSValue.undefinedValue();
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var probe = Probe{ .rt = js.runtime };
    try js.defineGlobalExternalHostFunction("matchAllSource", 0, &probe, Probe.create, null);
    try js.defineGlobalExternalHostFunction("matchAllCollect", 0, &probe, Probe.collect, null);
    js.runtime.forcePreciseRootScanForTest();
    defer js.runtime.restoreDefaultRootScanForTest();
    _ = try js.eval(
        \\const iterator = String.prototype.matchAll.call({ toString: matchAllSource },
        \\  { toString() { matchAllCollect(); return 'a'; } });
        \\assert.sameValue(iterator.next().value.index, 0);
        \\assert.sameValue(iterator.next().value.index, 2);
        \\assert.sameValue(iterator.next().done, true);
    );
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "string boundary regexp iterator completion OOM preserves retry state" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const rt = js.runtime;
    const value = try js.evalWithOptions(
        \\RegExp.prototype[Symbol.matchAll].call({ flags: 'g', lastIndex: 0,
        \\  constructor: { [Symbol.species]: function () {
        \\    return { lastIndex: 0, exec() { return null; } };
        \\  } }
        \\}, 'completion-input')
    , .{ .filename = "<repl>" });
    const iterator = core.value_semantics.objectFromValue(value).?;
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const before = rt.active_value_roots;
    rt.forcePreciseRootScanForTest();
    defer rt.restoreDefaultRootScanForTest();
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.regExpStringIteratorNext(js.context, null, global, value, null, null));
    try std.testing.expect(rt.active_value_roots == before);
    try std.testing.expect(rt.gc.containsHeader(iterator.gcHeader()));
    try std.testing.expectEqual(@as(usize, 0), iterator.iteratorIndexSlot().*);
    try std.testing.expect(iterator.iteratorTargetSlot().* != null);
    try std.testing.expect(iterator.iteratorData() != null);
    rt.setMemoryLimit(null);
    const result = (try engine.exec.string_ops.regExpStringIteratorNext(js.context, null, global, value, null, null)).?;
    const completed = core.value_semantics.objectFromValue(result).?;
    try std.testing.expectEqual(true, (try completed.getProperty(core.atom.ids.done)).as(.boolean).?);
    try std.testing.expectEqual(@as(usize, 1), iterator.iteratorIndexSlot().*);
    try std.testing.expect(iterator.iteratorTargetSlot().* == null);
    try std.testing.expect(iterator.iteratorData() == null);
}

test "string boundary regexp iterator next retains exec result across coercion GC" {
    const Probe = struct {
        rt: *core.JSRuntime,
        result: ?*core.gc.Header = null,
        lost: bool = false,
        calls: usize = 0,
        fn remember(raw: *anyopaque, call: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.result = call.args[0].cycleMarkHeader().?;
            return call.args[0];
        }
        fn collect(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = try self.rt.collectForTest();
            self.calls += 1;
            if (!self.rt.gc.containsHeader(self.result orelse return error.MissingIteratorMatch)) {
                self.lost = true;
                return error.LostIteratorMatch;
            }
            return core.JSValue.undefinedValue();
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var probe = Probe{ .rt = js.runtime };
    try js.defineGlobalExternalHostFunction("nextRemember", 1, &probe, Probe.remember, null);
    try js.defineGlobalExternalHostFunction("nextCollect", 0, &probe, Probe.collect, null);
    js.runtime.forcePreciseRootScanForTest();
    defer js.runtime.restoreDefaultRootScanForTest();
    const execution = js.eval(
        \\let nextIndex = -1;
        \\function Matcher() { this.n = 0; }
        \\Matcher.prototype.exec = function () {
        \\  if (this.n++) return null;
        \\  return nextRemember({ get 0() { return { toString() { nextCollect(); return ''; } }; } });
        \\};
        \\Object.defineProperty(Matcher.prototype, 'lastIndex', {
        \\  get() { nextCollect(); return { valueOf() { nextCollect(); return 0; } }; },
        \\  set(v) { nextIndex = v; }
        \\});
        \\const rx = { flags: 'gu', lastIndex: 0, constructor: { [Symbol.species]: Matcher } };
        \\const iterator = RegExp.prototype[Symbol.matchAll].call(rx, '\ud83d\ude00');
        \\const first = iterator.next();
        \\assert.sameValue(first.done, false);
        \\assert.sameValue(typeof first.value, 'object');
        \\assert.sameValue(nextIndex, 2);
        \\assert.sameValue(iterator.next().done, true);
        \\assert.sameValue(iterator.next().done, true);
    );
    try std.testing.expect(!probe.lost);
    _ = try execution;
    try std.testing.expectEqual(@as(usize, 3), probe.calls);
}

test "string boundary regexp iterator prototype survives allocation GC and OOM" {
    const Probe = struct {
        rt: *core.JSRuntime,
        calls: usize = 0,
        failure: ?anyerror = null,
        fn run(raw: ?*anyopaque, _: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.rt.collectForTest() catch |err| {
                self.failure = err;
                return;
            };
            self.calls += 1;
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const rt = js.runtime;
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    var probe = Probe{ .rt = rt };
    const previous_probe = rt.gc.heap_budget.installProbe(.{ .run = Probe.run, .context = &probe });
    defer rt.gc.heap_budget.restoreProbe(previous_probe);
    const proto = try engine.exec.string_ops.regExpStringIteratorPrototype(js.context, global);
    if (probe.failure) |err| return err;
    try std.testing.expect(probe.calls >= 2);
    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol).?;
    try std.testing.expect((try proto.getProperty(tag_atom)).asStringBodyRaw().?.eqlBytes("RegExp String Iterator"));
    const next_atom = core.atom.predefinedId("next", .string).?;
    try std.testing.expect(engine.exec.call_runtime.isCallableValue(try proto.getProperty(next_atom)));
    rt.gc.heap_budget.restoreProbe(null);
    const object = try core.Object.createPlainObject(rt, null);
    const header = object.gcHeader();
    rt.forcePreciseRootScanForTest();
    defer rt.restoreDefaultRootScanForTest();
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, engine.exec.iterator_ops.defineToStringTag(rt, object, "Owned Iterator"));
    try std.testing.expect(rt.gc.containsHeader(header));
    rt.setMemoryLimit(null);
    try engine.exec.iterator_ops.defineToStringTag(rt, object, "Owned Iterator");
    try std.testing.expect((try object.getProperty(tag_atom)).asStringBodyRaw().?.eqlBytes("Owned Iterator"));
}

test "string boundary regexp search retains source across callbacks" {
    try testRegExpMatchSearchRoots(false);
}

test "string boundary regexp match retains source across callbacks" {
    try testRegExpMatchSearchRoots(true);
}

fn testRegExpMatchSearchRoots(comptime match: bool) !void {
    const Probe = struct {
        rt: *core.JSRuntime,
        source: ?*core.gc.Header = null,
        previous: ?*core.gc.Header = null,
        lost: bool = false,
        calls: usize = 0,
        fn make(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const source = if (match) try core.string.String.createUtf16(self.rt, &.{ 0xd83d, 0xde00 }) else try core.string.String.createAscii(self.rt, "fresh-regexp-input");
            self.source = source.header();
            return source.value();
        }
        fn makePrevious(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const object = try core.Object.createPlainObject(self.rt, null);
            self.previous = object.gcHeader();
            return object.value();
        }
        fn collect(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = try self.rt.collectForTest();
            self.calls += 1;
            if (!self.rt.gc.containsHeader(self.source orelse return error.MissingRegExpSource)) {
                self.lost = true;
                return error.LostRegExpSource;
            }
            if (self.previous) |previous| if (!self.rt.gc.containsHeader(previous)) {
                self.lost = true;
                return error.LostPreviousLastIndex;
            };
            return core.JSValue.undefinedValue();
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var probe = Probe{ .rt = js.runtime };
    try js.defineGlobalExternalHostFunction("regexpFresh", 0, &probe, Probe.make, null);
    try js.defineGlobalExternalHostFunction("regexpCollect", 0, &probe, Probe.collect, null);
    try js.defineGlobalExternalHostFunction("regexpPrevious", 0, &probe, Probe.makePrevious, null);
    js.runtime.forcePreciseRootScanForTest();
    defer js.runtime.restoreDefaultRootScanForTest();
    const execution = js.eval(if (match)
        \\let n = 0, nextIndex = -1;
        \\const rx = {
        \\  get lastIndex() { regexpCollect(); return { valueOf() { regexpCollect(); return 0; } }; },
        \\  set lastIndex(v) { nextIndex = v; },
        \\  get flags() { regexpCollect(); return 'gu'; },
        \\  get exec() { regexpCollect(); return function () {
        \\    regexpCollect(); if (n >= 2) return null; const text = n++ === 0 ? 'found' : '';
        \\    return { get 0() { regexpCollect(); return { toString() { regexpCollect(); return text; } }; } };
        \\  }; }
        \\};
        \\const result = RegExp.prototype[Symbol.match].call(rx, { toString: regexpFresh });
        \\assert.sameValue(result.length, 2); assert.sameValue(result[0], 'found');
        \\assert.sameValue(result[1], ''); assert.sameValue(nextIndex, 2);
    else
        \\let first = true, restored = false;
        \\const rx = {
        \\  get lastIndex() { regexpCollect(); if (first) { first = false; return regexpPrevious(); } return 0; },
        \\  set lastIndex(v) { regexpCollect(); if (typeof v === 'object') restored = true; },
        \\  get exec() { regexpCollect(); return function () {
        \\    regexpCollect(); return { get index() { regexpCollect(); return 2; } };
        \\  }; }
        \\};
        \\assert.sameValue(RegExp.prototype[Symbol.search].call(rx, { toString: regexpFresh }), 2);
        \\assert.sameValue(restored, true);
    );
    try std.testing.expect(!probe.lost);
    _ = try execution;
    try std.testing.expectEqual(@as(usize, if (match) 13 else 7), probe.calls);
}

test "string boundary ASCII suffix keeps rope source unmaterialized" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const a = try core.string.String.createAscii(rt, "u");
    const b = try core.string.String.createAscii(rt, "i");
    const rope = try core.string.String.createRope(rt, a.value(), b.value());
    rt.forcePreciseRootScanForTest();
    defer rt.restoreDefaultRootScanForTest();
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, engine.exec.value_ops.appendAsciiSuffixOwned(rt, rope.value(), "y"));
    try std.testing.expect(!rope.isLinearized());
    rt.setMemoryLimit(null);
    const result = try engine.exec.value_ops.appendAsciiSuffixOwned(rt, rope.value(), "y");
    try std.testing.expect(result.asStringBodyRaw().?.eqlBytes("uiy"));
    try std.testing.expect(!rope.isLinearized());
}

test "string boundary regexp split snapshots limit before source coercion" {
    const Probe = struct {
        rt: *core.JSRuntime,
        arguments: ?*[2]core.JSValue = null,
        fn coerce(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.arguments.?[1] = core.JSValue.int32(0);
            return (try core.string.String.createAscii(self.rt, "abc")).value();
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var probe = Probe{ .rt = js.runtime };
    try js.defineGlobalExternalHostFunction("splitReuseArguments", 0, &probe, Probe.coerce, null);
    const input = try js.evalWithOptions("({ toString: splitReuseArguments })", .{ .filename = "<repl>" });
    const rx = try js.evalWithOptions("/x/", .{ .filename = "<repl>" });
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    var arguments = [_]core.JSValue{ input, core.JSValue.int32(1) };
    probe.arguments = &arguments;
    const result = try engine.exec.string_ops.regExpSymbolSplit(js.context, null, global, rx, &arguments, null, null);
    const array = core.value_semantics.objectFromValue(result).?;
    try std.testing.expect((try array.getProperty(core.Atom.taggedInt(0))).asStringBodyRaw().?.eqlBytes("abc"));
    try std.testing.expectEqual(@as(i32, 0), arguments[1].as(.int).?);
}

test "string boundary regexp split species retains converted source" {
    try testRegExpSpeciesRoots(false);
}

test "string boundary regexp matchAll species retains source through publication" {
    try testRegExpSpeciesRoots(true);
}

fn testRegExpSpeciesRoots(comptime match_all: bool) !void {
    const Probe = struct {
        rt: *core.JSRuntime,
        victim: ?*core.gc.Header = null,
        calls: usize = 0,
        lost: bool = false,
        fn make(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const source = try core.string.String.createAscii(self.rt, "fresh-split-source");
            self.victim = source.header();
            return source.value();
        }
        fn collect(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = try self.rt.collectForTest();
            self.calls += 1;
            if (!self.rt.gc.containsHeader(self.victim orelse return error.MissingSplitSource)) {
                self.lost = true;
                return error.LostSplitSource;
            }
            return core.JSValue.undefinedValue();
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var probe = Probe{ .rt = js.runtime };
    try js.defineGlobalExternalHostFunction("splitFresh", 0, &probe, Probe.make, null);
    try js.defineGlobalExternalHostFunction("splitStageCollect", 0, &probe, Probe.collect, null);
    js.runtime.forcePreciseRootScanForTest();
    defer js.runtime.restoreDefaultRootScanForTest();
    const evaluation = js.eval(if (match_all)
        \\const pattern = {
        \\  get constructor() { splitStageCollect(); return {
        \\    get [Symbol.species]() { splitStageCollect(); return function () {
        \\      splitStageCollect(); return {
        \\        set lastIndex(v) { splitStageCollect(); assert.sameValue(v, 3); },
        \\        exec(input) { splitStageCollect(); assert.sameValue(input, 'fresh-split-source'); return null; }
        \\      };
        \\    }; }
        \\  }; },
        \\  get flags() { splitStageCollect(); return { toString() { splitStageCollect(); return 'g'; } }; },
        \\  get lastIndex() { splitStageCollect(); return { valueOf() { splitStageCollect(); return 3; } }; }
        \\};
        \\const result = RegExp.prototype[Symbol.matchAll].call(pattern, { toString() { return splitFresh(); } });
        \\splitStageCollect();
        \\assert.sameValue(result.next().done, true);
    else
        \\const pattern = {
        \\  get constructor() { splitStageCollect(); return {
        \\    get [Symbol.species]() { splitStageCollect(); return function () {
        \\      splitStageCollect(); return { lastIndex: 0, exec() { return null; } };
        \\    }; }
        \\  }; },
        \\  get flags() { splitStageCollect(); return ''; }
        \\};
        \\const result = RegExp.prototype[Symbol.split].call(pattern,
        \\  { toString() { return splitFresh(); } },
        \\  { valueOf() { splitStageCollect(); return 10; } });
        \\assert.sameValue(result.length, 1);
        \\assert.sameValue(result[0], 'fresh-split-source');
    );
    try std.testing.expect(!probe.lost);
    _ = try evaluation;
    try std.testing.expectEqual(@as(usize, if (match_all) 10 else 5), probe.calls);
}

test "string boundary regexp split avoids implicit rope materialization" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const rt = js.runtime;
    const splitter = try js.evalWithOptions("({ lastIndex: 0, exec() { return null; } })", .{ .filename = "<repl>" });
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const a = try core.string.String.createUtf16(rt, &.{ 'a', 0xd83d });
    const b = try core.string.String.createUtf16(rt, &.{ 0xde00, 'b' });
    const source = try core.string.String.createRope(rt, a.value(), b.value());
    rt.forcePreciseRootScanForTest();
    defer rt.restoreDefaultRootScanForTest();
    const threshold = rt.gc.heap_budget.gc_threshold;
    defer rt.setGCThreshold(threshold);
    rt.setGCThreshold(0);
    const epoch = rt.gc.collection_epoch;
    const result = try engine.exec.string_ops.regExpSymbolSplitGeneric(js.context, null, global, splitter, source.value(), 20, true, null, null);
    try std.testing.expect(rt.gc.collection_epoch > epoch);
    try std.testing.expect(result.is(.object));
    try std.testing.expect(!source.isLinearized());
    const array = core.value_semantics.objectFromValue(result).?;
    const first = try array.getProperty(core.Atom.taggedInt(0));
    try std.testing.expectEqual(source.value().bits, first.bits);
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.regExpSymbolSplitGeneric(js.context, null, global, splitter, source.value(), 20, true, null, null));
}

test "string boundary regexp split retains values across observable callbacks" {
    const Probe = struct {
        rt: *core.JSRuntime,
        calls: usize = 0,
        fn collect(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = try self.rt.collectForTest();
            self.calls += 1;
            return core.JSValue.undefinedValue();
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const rt = js.runtime;
    var probe = Probe{ .rt = rt };
    try js.defineGlobalExternalHostFunction("splitCollect", 0, &probe, Probe.collect, null);
    const splitter = try js.evalWithOptions(
        \\({ p: 0,
        \\   set lastIndex(v) { splitCollect(); this.p = v; },
        \\   get lastIndex() { splitCollect(); const p = this.p;
        \\     return { valueOf() { splitCollect(); return p; } }; },
        \\   get exec() { splitCollect(); return function () {
        \\     splitCollect(); if (this.p !== 1) return null; this.p = 2;
        \\     return {
        \\       get length() { splitCollect(); return { valueOf() { splitCollect(); return 2; } }; },
        \\       get 1() { splitCollect(); return { capture: true }; }
        \\     };
        \\   }; }
        \\ })
    , .{ .filename = "<repl>" });
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const source = try core.string.String.createAscii(rt, "axb");
    rt.forcePreciseRootScanForTest();
    defer rt.restoreDefaultRootScanForTest();
    const result = try engine.exec.string_ops.regExpSymbolSplitGeneric(js.context, null, global, splitter, source.value(), 20, true, null, null);
    const array = core.value_semantics.objectFromValue(result).?;
    try std.testing.expect((try array.getProperty(core.Atom.taggedInt(0))).asStringBodyRaw().?.eqlBytes("a"));
    try std.testing.expect((try array.getProperty(core.Atom.taggedInt(1))).is(.object));
    try std.testing.expect((try array.getProperty(core.Atom.taggedInt(2))).asStringBodyRaw().?.eqlBytes("b"));
    try std.testing.expectEqual(@as(usize, 14), probe.calls);
}

test "string boundary regexp fast replace propagates rope OOM" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const rt = js.runtime;
    const rx = try js.evalWithOptions("(() => { const r = /a/g; r.test('a'); return r; })()", .{ .filename = "<repl>" });
    const rx_object = core.value_semantics.objectFromValue(rx) orelse return error.ExpectedRegExp;
    try std.testing.expectEqual(core.class.ids.regexp, rx_object.class_id);
    try std.testing.expect(engine.exec.regexp_ops.regExpLastIndexCanSkipCoercion(rx_object));
    try std.testing.expect(rx_object.regexpCompiledBytecode().len != 0);
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const regexp = try roots.ref(0);
    const source = try roots.ref(1);
    const replacement = try roots.ref(2);
    try regexp.set(rt, rx);
    const a = try core.string.String.createUtf8(rt, "a");
    const b = try core.string.String.createUtf8(rt, "b");
    try source.set(rt, (try core.string.String.createRope(rt, a.value(), b.value())).value());
    try replacement.set(rt, (try core.string.String.createUtf8(rt, "x")).value());
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.regExpReplaceFast(js.context, null, global, try regexp.get(rt), try source.get(rt), try replacement.get(rt), null, null));
    rt.setMemoryLimit(null);
    const result = (try engine.exec.string_ops.regExpReplaceFast(js.context, null, global, try regexp.get(rt), try source.get(rt), try replacement.get(rt), null, null)).?;
    try std.testing.expect(result.asStringBodyRaw().?.eqlBytes("xb"));
    const x = try core.string.String.createUtf8(rt, "x");
    const substitution = try core.string.String.createUtf8(rt, "$&");
    try replacement.set(rt, (try core.string.String.createRope(rt, x.value(), substitution.value())).value());
    rt.setMemoryLimit(0);
    try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.regExpReplaceFast(js.context, null, global, try regexp.get(rt), try source.get(rt), try replacement.get(rt), null, null));
    rt.setMemoryLimit(null);
    const retried = (try engine.exec.string_ops.regExpReplaceFast(js.context, null, global, try regexp.get(rt), try source.get(rt), try replacement.get(rt), null, null)).?;
    try std.testing.expect(retried.asStringBodyRaw().?.eqlBytes("xab"));
    try std.testing.expect(rt.active_no_gc_scope == null);
}

test "string boundary regexp fast replace owns roots during materialization GC" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const rt = js.runtime;
    const rx = try js.evalWithOptions("/a/g", .{ .filename = "<repl>" });
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const a = try core.string.String.createUtf8(rt, "a");
    const b = try core.string.String.createUtf8(rt, "b");
    const source = try core.string.String.createRope(rt, a.value(), b.value());
    const replacement = try core.string.String.createRope(rt, b.value(), a.value());
    rt.forcePreciseRootScanForTest();
    defer rt.restoreDefaultRootScanForTest();
    const threshold = rt.gc.heap_budget.gc_threshold;
    defer rt.setGCThreshold(threshold);
    rt.setGCThreshold(0);
    const epoch = rt.gc.collection_epoch;
    const result = (try engine.exec.string_ops.regExpReplaceFast(js.context, null, global, rx, source.value(), replacement.value(), null, null)).?;
    try std.testing.expect(rt.gc.collection_epoch > epoch);
    try std.testing.expect(result.asStringBodyRaw().?.eqlBytes("bab"));
    try std.testing.expect(rt.active_no_gc_scope == null);
}

test "root tracing rejects JavaScript callback entry" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval("globalThis.traceCallback = function () { return 42; };");
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const key = try js.runtime.internAtom("traceCallback");
    const callee = try global.getProperty(key);
    var site = try engine.exec.call_site.CallSite.init(js.context, null, global, core.JSValue.undefinedValue(), callee);
    defer site.deinit();
    const Probe = struct {
        site: *engine.exec.call_site.CallSite,
        fn value(_: *anyopaque, _: *core.JSValue) core.runtime.RootTraceError!void {}
        fn object(_: *anyopaque, _: *?*core.Object) core.runtime.RootTraceError!void {}
        fn trace(raw: *anyopaque, _: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (std.c.getenv("ZJS_TRACE_JS_INJECT")) |env| {
                if (std.mem.eql(u8, std.mem.span(env), "1")) {
                    _ = self.site.call(&.{}) catch return error.PayloadMarkFailed;
                } else {
                    const site_ptr = self.site;
                    _ = engine.exec.call_runtime.callValueOrBytecodeDispatchAfterInterruptPoll(
                        site_ptr.ctx,
                        null,
                        site_ptr.global,
                        site_ptr.this_value,
                        site_ptr.callee,
                        &.{},
                        null,
                        null,
                        .copy,
                    ) catch return error.PayloadMarkFailed;
                }
            }
        }
    };
    var probe = Probe{ .site = &site };
    const provider = core.runtime.RootProvider{ .context = &probe, .trace = Probe.trace };
    try js.runtime.registerRootProvider(provider);
    defer js.runtime.unregisterRootProvider(provider);
    var visitor = core.runtime.RootVisitor{ .readonly = .observe, .context = &probe, .visit_value = Probe.value, .visit_object = Probe.object };
    try js.runtime.roots.traceProviders(&visitor);
    try std.testing.expectEqual(@as(?i32, 42), (try site.call(&.{})).as(.int));
}

test "string boundary rope queries and unit copy do not materialize" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const left = try roots.ref(0);
    const right = try roots.ref(1);
    const input = try roots.ref(2);
    try left.set(rt, (try core.string.String.createAscii(rt, "ab")).value());
    try right.set(rt, (try core.string.String.createUtf16(rt, &.{ 'c', 0x100 })).value());
    const rope = try core.string.String.createRope(rt, try left.get(rt), try right.get(rt));
    try input.set(rt, rope.value());
    const allocations = rt.allocation_diagnostics.allocation_count;
    const collections = rt.gc.collection_epoch;
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try std.testing.expectEqual(@as(usize, 4), core.string.stringValueLen(try input.get(rt)));
    try std.testing.expect(!engine.exec.string_ops.isEmptyStringValue(rt, try input.get(rt)));
    try std.testing.expect(try engine.exec.string_ops.stringValueContainsByte(rt, try input.get(rt), 'c'));
    try std.testing.expect(!engine.exec.string_ops.stringValueContainsUnitByte(try input.get(rt), 'z'));
    try std.testing.expect(!engine.exec.string_ops.stringValueUnitsEqualBytes(try input.get(rt), "abc?"));
    try std.testing.expectEqual(allocations, rt.allocation_diagnostics.allocation_count);
    var units = std.ArrayList(u16).empty;
    defer units.deinit(rt.nativeAllocator());
    try engine.exec.string_ops.appendStringValueUnits(rt, &units, try input.get(rt));
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b', 'c', 0x100 }, units.items);
    try std.testing.expect(!rope.isLinearized());
    try std.testing.expectEqual(collections, rt.gc.collection_epoch);
    rt.setMemoryLimit(null);
    try right.set(rt, (try core.string.String.createAscii(rt, "cd")).value());
    const narrow_rope = try core.string.String.createRope(rt, try left.get(rt), try right.get(rt));
    try input.set(rt, narrow_rope.value());
    rt.setMemoryLimit(0);
    try std.testing.expect(engine.exec.string_ops.stringValueUnitsEqualBytes(try input.get(rt), "abcd"));
    try std.testing.expect(!engine.exec.string_ops.stringValueUnitsEqualBytes(try input.get(rt), "abc"));
    try std.testing.expect(!engine.exec.string_ops.stringValueUnitsEqualBytes(try input.get(rt), "abcde"));
    try std.testing.expect(!narrow_rope.isLinearized());
}

test "string boundary slices preserve rope inputs without materialization" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const rt = js.runtime;
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const left = try roots.ref(0);
    const right = try roots.ref(1);
    const input = try roots.ref(2);
    try left.set(rt, (try core.string.String.createAscii(rt, "ab")).value());
    try right.set(rt, (try core.string.String.createUtf16(rt, &.{ 0x100, 0xd83d, 0xde00, 'z' })).value());
    try input.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value());
    const before = rt.allocation_diagnostics.allocation_count;
    const entire = try engine.exec.string_ops.stringSliceValue(rt, try input.get(rt), 0, 6);
    try std.testing.expectEqual((try input.get(rt)).bits, entire.bits);
    try std.testing.expect(!(try input.get(rt)).ropeBody().?.isLinearized());
    try std.testing.expectEqual(before, rt.allocation_diagnostics.allocation_count);
    for ([_]u32{ 1, 32 }) |method_id| {
        const result = try engine.exec.string_ops.stringNumericArgsMethod(js.context, null, global, try input.get(rt), method_id, &.{ core.JSValue.int32(1), core.JSValue.int32(5) }, null, null);
        var actual = std.ArrayList(u16).empty;
        defer actual.deinit(rt.nativeAllocator());
        try engine.exec.string_ops.appendStringValueUnits(rt, &actual, result);
        try std.testing.expectEqualSlices(u16, &.{ 'b', 0x100, 0xd83d, 0xde00 }, actual.items);
        try std.testing.expect(!(try input.get(rt)).ropeBody().?.isLinearized());
    }
    const units = [_]u16{ 'a', 'b', 0x100, 0xd83d, 0xde00, 'z' };
    for (0..2) |cached| {
        if (cached != 0) try core.string.ensureFlat(rt, input.readOnly(), right);
        for (0..8) |start| {
            for (0..10) |len| {
                const result = try engine.exec.string_ops.stringSliceValue(rt, try input.get(rt), start, len);
                var actual = std.ArrayList(u16).empty;
                defer actual.deinit(rt.nativeAllocator());
                try engine.exec.string_ops.appendStringValueUnits(rt, &actual, result);
                const lo = @min(start, units.len);
                const count = @min(len, units.len - lo);
                try std.testing.expectEqualSlices(u16, units[lo..][0..count], actual.items);
                if (cached == 0) try std.testing.expect(!(try input.get(rt)).ropeBody().?.isLinearized());
                // A narrow substring of a wide source retains Latin1 storage.
                if (start == 0 and len == 2) try std.testing.expect(!core.string.asFlat(result).?.isWide());
            }
        }
    }
    const suffix = try engine.exec.string_ops.stringSliceValue(rt, try input.get(rt), 5, std.math.maxInt(usize));
    try std.testing.expect(core.string.asFlat(suffix).?.eqlBytes("z"));
    const empty = try engine.exec.string_ops.stringSliceValue(rt, try input.get(rt), std.math.maxInt(usize), std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), core.string.stringValueLenUnchecked(empty));
}

test "string boundary slices preserve code units and bounds" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval(
        \\var s = 'a\ud83d\ude00\u00e9\u0100z';
        \\assert.sameValue(s.slice(1, 3), '\ud83d\ude00');
        \\assert.sameValue(s.substring(2, 3), '\ude00');
        \\assert.sameValue(s.substring(4, 3), '\u00e9');
        \\assert.sameValue(s.slice(-2, Infinity), '\u0100z');
        \\assert.sameValue(s.slice(100), '');
        \\assert.sameValue(s.substring(-100, 1), 'a');
        \\assert.sameValue(s.slice(4, 1), '');
        \\assert.sameValue(s.slice(-Infinity), s);
        \\assert.sameValue(s.substring(NaN, undefined), s);
        \\assert.sameValue(s.substr(2, 2), '\ude00\u00e9');
    );
}

test "string boundary slice constructor roots parent during allocation failure" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.forcePreciseRootScanForTest();
    defer rt.restoreDefaultRootScanForTest();
    const parent = try core.string.String.createAscii(rt, "unrooted-slice-parent");
    const header = parent.header();
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    const epoch = rt.gc.collection_epoch;
    try std.testing.expectError(error.OutOfMemory, core.string.String.createSlice(rt, parent, 1, 10));
    try std.testing.expect(rt.gc.collection_epoch > epoch);
    try std.testing.expect(rt.gc.containsHeader(header));
    rt.setMemoryLimit(null);
    const retried = try core.string.String.createSlice(rt, parent, 1, 10);
    try std.testing.expect(retried.eqlBytes("nrooted-sl"));
    try std.testing.expect(rt.active_no_gc_scope == null);
}

test "string boundary slice conversions retain source across index callbacks" {
    const Probe = struct {
        rt: *core.JSRuntime,
        victim: ?*core.gc.Header = null,
        lost: bool = false,
        calls: usize = 0,
        fn make(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const string = try core.string.String.createAscii(self.rt, "fresh-slice");
            self.victim = string.header();
            return string.value();
        }
        fn collect(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = try self.rt.collectForTest();
            self.calls += 1;
            if (!self.rt.gc.containsHeader(self.victim orelse return error.MissingSliceSource)) {
                self.lost = true;
                return error.LostSliceSource;
            }
            return core.JSValue.undefinedValue();
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var probe = Probe{ .rt = js.runtime };
    try js.defineGlobalExternalHostFunction("sliceMake", 0, &probe, Probe.make, null);
    try js.defineGlobalExternalHostFunction("sliceCollect", 0, &probe, Probe.collect, null);
    js.runtime.forcePreciseRootScanForTest();
    defer js.runtime.restoreDefaultRootScanForTest();
    const result = js.eval(
        \\for (var method of ['slice', 'substring']) {
        \\  var result = String.prototype[method].call(
        \\    { toString() { return sliceMake(); } },
        \\    { valueOf() { sliceCollect(); return 1; } },
        \\    { valueOf() { sliceCollect(); return 4; } });
        \\  assert.sameValue(result, 'res');
        \\}
    );
    try std.testing.expect(!probe.lost);
    _ = try result;
    try std.testing.expectEqual(@as(usize, 4), probe.calls);
}

test "string boundary concat protects converted parts across coercion GC" {
    const Probe = struct {
        rt: *core.JSRuntime,
        victims: [64]*core.gc.Header = undefined,
        count: usize = 0,
        lost: bool = false,
        fn make(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = try self.rt.collectForTest();
            for (self.victims[0..self.count]) |header| {
                if (!self.rt.gc.containsHeader(header)) {
                    self.lost = true;
                    return error.LostConcatPart;
                }
            }
            const string = try core.string.String.createAscii(self.rt, "part");
            self.victims[self.count] = string.header();
            self.count += 1;
            return string.value();
        }
    };
    for ([_]usize{ 1, 31, 32, 40 }) |count| {
        var js = try helpers.TestEngine.init(std.testing.allocator);
        defer js.deinit();
        var probe = Probe{ .rt = js.runtime };
        try js.defineGlobalExternalHostFunction("concatMake", 0, &probe, Probe.make, null);
        js.runtime.forcePreciseRootScanForTest();
        defer js.runtime.restoreDefaultRootScanForTest();
        const code = try std.fmt.allocPrint(std.testing.allocator,
            \\var args = [];
            \\for (var i = 0; i < {d}; i++) args.push({{ toString() {{ return concatMake(); }} }});
            \\String.prototype.concat.apply({{ toString() {{ return concatMake(); }} }}, args);
        , .{count});
        defer std.testing.allocator.free(code);
        const result = js.evalWithOptions(code, .{ .filename = "<repl>" });
        try std.testing.expect(!probe.lost);
        const value = try result;
        try std.testing.expectEqual(count + 1, probe.count);
        try std.testing.expectEqual((count + 1) * 4, core.string.stringValueLenUnchecked(value));
        var expected = std.ArrayList(u8).empty;
        defer expected.deinit(std.testing.allocator);
        for (0..count + 1) |_| try expected.appendSlice(std.testing.allocator, "part");
        try std.testing.expect(core.string.asFlat(value).?.eqlBytes(expected.items));
    }
}

test "string boundary concat leaves ropes unmaterialized across direct and large calls" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const rt = js.runtime;
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const left = try roots.ref(0);
    const right = try roots.ref(1);
    const input = try roots.ref(2);
    try left.set(rt, (try core.string.String.createAscii(rt, "a")).value());
    try right.set(rt, (try core.string.String.createUtf16(rt, &.{ 0x100, 0xd800 })).value());
    try input.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value());
    for ([_]usize{ 0, 1, 31, 32, 40 }) |count| {
        var args: [40]core.JSValue = undefined;
        @memset(args[0..count], try input.get(rt));
        const result = try engine.exec.string_ops.stringConcat(js.context, null, global, try input.get(rt), args[0..count], null, null);
        try std.testing.expect(!(try input.get(rt)).ropeBody().?.isLinearized());
        var actual = std.ArrayList(u16).empty;
        defer actual.deinit(rt.nativeAllocator());
        try engine.exec.string_ops.appendStringValueUnits(rt, &actual, result);
        try std.testing.expectEqual((count + 1) * 3, actual.items.len);
        for (0..count + 1) |index| try std.testing.expectEqualSlices(u16, &.{ 'a', 0x100, 0xd800 }, actual.items[index * 3 ..][0..3]);
    }
}

test "string boundary concat preserves primitive formatting conversion order and abrupt completion" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval(
        \\assert.sameValue('x'.concat(-2147483648, ':', 2147483647, 0, '\u00e9'), 'x-2147483648:21474836470\u00e9');
        \\assert.sameValue(''.concat(), '');
        \\assert.sameValue('\u0100'.concat('\ud83d', '\ude00', '\ud800'), '\u0100\ud83d\ude00\ud800');
        \\var order = '';
        \\var first = { toString() { order += 'a'; return '\u00e9'; } };
        \\var stop = { toString() { order += 'b'; throw 42; } };
        \\var last = { toString() { order += 'c'; return 'late'; } };
        \\try { ''.concat(first, stop, last); } catch (e) { assert.sameValue(e, 42); }
        \\assert.sameValue(order, 'ab');
        \\order = '';
        \\assert.sameValue(String.prototype.concat.call(first, 12, null, undefined, true), '\u00e912nullundefinedtrue');
        \\assert.sameValue(order, 'a');
        \\var caught = false;
        \\try { String.prototype.concat.call(null, first); } catch (e) { caught = e instanceof TypeError; }
        \\assert.sameValue(caught, true);
        \\assert.sameValue(order, 'a');
        \\caught = false;
        \\try { ''.concat(Symbol('x'), last); } catch (e) { caught = e instanceof TypeError; }
        \\assert.sameValue(caught, true);
        \\assert.sameValue(order, 'a');
    );
}

test "string boundary concat OOM restores roots and preserves inputs" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const rt = js.runtime;
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    var roots = core.runtime.ExactValueRoots(1){};
    try roots.activate(rt);
    defer roots.deactivate();
    const input = try roots.ref(0);
    try input.set(rt, (try core.string.String.createAscii(rt, "concat-input")).value());
    var args: [40]core.JSValue = @splat(try input.get(rt));
    const frame = rt.active_value_roots;
    const native_bytes = rt.allocation_diagnostics.allocated_bytes;
    rt.setNativeBytesLimitForTest(native_bytes);
    defer rt.setNativeBytesLimitForTest(null);
    try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.stringConcat(js.context, null, global, try input.get(rt), &args, null, null));
    rt.setNativeBytesLimitForTest(null);
    try std.testing.expect(rt.active_value_roots == frame);
    try std.testing.expectEqual(native_bytes, rt.allocation_diagnostics.allocated_bytes);
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    const epoch = rt.gc.collection_epoch;
    try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.stringConcat(js.context, null, global, try input.get(rt), &args, null, null));
    try std.testing.expect(rt.gc.collection_epoch > epoch);
    try std.testing.expect(rt.active_value_roots == frame);
    try std.testing.expect(core.string.asFlat(try input.get(rt)).?.eqlBytes("concat-input"));
    try std.testing.expect(rt.active_no_gc_scope == null);
    rt.setMemoryLimit(null);
    const result = try engine.exec.string_ops.stringConcat(js.context, null, global, try input.get(rt), &args, null, null);
    try std.testing.expectEqual(@as(usize, 41 * 12), core.string.stringValueLenUnchecked(result));
}

test "string boundary padding keeps converted source alive across coercion GC" {
    const Probe = struct {
        rt: *core.JSRuntime,
        victim: ?*core.gc.Header = null,
        collections: usize = 0,
        fn make(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const string = try core.string.String.createAscii(self.rt, "fresh-pad-source");
            self.victim = string.header();
            return string.value();
        }
        fn collect(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = try self.rt.collectForTest();
            self.collections += 1;
            if (!self.rt.gc.containsHeader(self.victim orelse return error.MissingPadSource)) return error.LostPadSource;
            return core.JSValue.undefinedValue();
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var probe = Probe{ .rt = js.runtime };
    try js.defineGlobalExternalHostFunction("padMake", 0, &probe, Probe.make, null);
    try js.defineGlobalExternalHostFunction("padCollect", 0, &probe, Probe.collect, null);
    js.runtime.forcePreciseRootScanForTest();
    defer js.runtime.restoreDefaultRootScanForTest();
    const result = try js.evalWithOptions(
        \\var order = '';
        \\var padded = String.prototype.padStart.call(
        \\  { toString() { order += 's'; return padMake(); } },
        \\  { valueOf() { order += 'n'; padCollect(); return 20; } },
        \\  { toString() { order += 'f'; padCollect(); return 'ab'; } });
        \\assert.sameValue(order, 'snf');
        \\padded;
    , .{ .filename = "<repl>" });
    try std.testing.expectEqual(@as(usize, 2), probe.collections);
    try std.testing.expect(core.string.asFlat(result).?.eqlBytes("ababfresh-pad-source"));
}

test "string boundary padding does not flatten rope inputs" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const rt = js.runtime;
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const left = try roots.ref(0);
    const right = try roots.ref(1);
    const source = try roots.ref(2);
    try left.set(rt, (try core.string.String.createAscii(rt, "ab")).value());
    try right.set(rt, (try core.string.String.createUtf16(rt, &.{ 0x100, 0xd800 })).value());
    try source.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value());
    const before = rt.allocation_diagnostics.allocation_count;
    const result = try engine.exec.string_ops.stringPad(js.context, null, global, try source.get(rt), 34, &.{core.JSValue.int32(0)}, null, null);
    try std.testing.expectEqual((try source.get(rt)).bits, result.bits);
    try std.testing.expect(!(try source.get(rt)).ropeBody().?.isLinearized());
    try std.testing.expectEqual(before, rt.allocation_diagnostics.allocation_count);

    // Reuse the same rope for source and filler. The filler prefix ends at a
    // partial leaf: padding counts code units, not Unicode scalar values.
    for ([_]u32{ 34, 35 }) |method| {
        const padded = try engine.exec.string_ops.stringPad(js.context, null, global, try source.get(rt), method, &.{ core.JSValue.int32(11), try source.get(rt) }, null, null);
        var units = std.ArrayList(u16).empty;
        defer units.deinit(rt.nativeAllocator());
        try engine.exec.string_ops.appendStringValueUnits(rt, &units, padded);
        const expected: []const u16 = if (method == 34)
            &.{ 'a', 'b', 0x100, 0xd800, 'a', 'b', 0x100, 'a', 'b', 0x100, 0xd800 }
        else
            &.{ 'a', 'b', 0x100, 0xd800, 'a', 'b', 0x100, 0xd800, 'a', 'b', 0x100 };
        try std.testing.expectEqualSlices(u16, expected, units.items);
        try std.testing.expect(!(try source.get(rt)).ropeBody().?.isLinearized());
    }
    const native_bytes = rt.allocation_diagnostics.allocated_bytes;
    rt.setNativeBytesLimitForTest(native_bytes);
    defer rt.setNativeBytesLimitForTest(null);
    try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.stringPad(js.context, null, global, try source.get(rt), 34, &.{ core.JSValue.int32(12), try source.get(rt) }, null, null));
    rt.setNativeBytesLimitForTest(null);
    try std.testing.expectEqual(native_bytes, rt.allocation_diagnostics.allocated_bytes);
    try std.testing.expect(rt.active_no_gc_scope == null);
    // Final result allocation is the only GC allocation. Its failure must
    // leave both the input and the caller's root frame usable.
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    const epoch = rt.gc.collection_epoch;
    try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.stringPad(js.context, null, global, try source.get(rt), 35, &.{ core.JSValue.int32(12), try source.get(rt) }, null, null));
    try std.testing.expect(rt.gc.collection_epoch > epoch);
    try std.testing.expect(!(try source.get(rt)).ropeBody().?.isLinearized());
    try std.testing.expect(rt.active_no_gc_scope == null);
}

test "string boundary padding preserves coercion order early returns and code units" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval(
        \\var order = '';
        \\var source = { toString() { order += 's'; return 'abc'; } };
        \\var length = { valueOf() { order += 'n'; return 2; } };
        \\var fill = { toString() { order += 'f'; throw 42; } };
        \\assert.sameValue(String.prototype.padEnd.call(source, length, fill), 'abc');
        \\assert.sameValue(order, 'sn');
        \\assert.sameValue('abc'.padStart(Infinity, ''), 'abc');
        \\assert.sameValue('a'.padEnd(3), 'a  ');
        \\assert.sameValue('a'.padStart(4, '\u00e9'), '\u00e9\u00e9\u00e9a');
        \\assert.sameValue('x'.padStart(4, '\ud83d\ude00'), '\ud83d\ude00\ud83dx');
        \\assert.sameValue('x'.padEnd(4, '\ud83d\ude00'), 'x\ud83d\ude00\ud83d');
        \\var caught = false;
        \\try { String.prototype.padStart.call(null, length, fill); } catch (e) { caught = e instanceof TypeError; }
        \\assert.sameValue(caught, true);
        \\assert.sameValue(order, 'sn');
        \\try { 'a'.padStart(3, fill); } catch (e) { assert.sameValue(e, 42); }
        \\assert.sameValue(order, 'snf');
    );
}

test "waitAsync roots arguments across coercion GC and preserves conversion order" {
    const Probe = struct {
        rt: *core.JSRuntime,
        collections: usize = 0,
        fn collect(raw: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = try self.rt.collectForTest();
            self.collections += 1;
            return core.JSValue.undefinedValue();
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var probe = Probe{ .rt = js.runtime };
    try js.defineGlobalExternalHostFunction("waiterCollect", 0, &probe, Probe.collect, null);
    js.runtime.forcePreciseRootScanForTest();
    defer js.runtime.restoreDefaultRootScanForTest();
    _ = try js.eval(
        \\var order = '';
        \\function conversion(tag, value) {
        \\  return { valueOf() { waiterCollect(); order += tag; return value; } };
        \\}
        \\var pending = Atomics.waitAsync(new Int32Array(new SharedArrayBuffer(4)),
        \\  conversion('i', 0), conversion('e', 0), conversion('t', Infinity));
        \\assert.sameValue(order, 'iet');
        \\assert.sameValue(pending.async, true);
        \\assert.sameValue(pending.value instanceof Promise, true);
        \\order = '';
        \\var unequal = Atomics.waitAsync(new Int32Array(new SharedArrayBuffer(4)),
        \\  conversion('i', 0), conversion('e', 1), conversion('t', Infinity));
        \\assert.sameValue(order, 'iet');
        \\assert.sameValue(unequal.async, false);
        \\assert.sameValue(unequal.value, 'not-equal');
        \\order = '';
        \\var timed = Atomics.waitAsync(new Int32Array(new SharedArrayBuffer(4)),
        \\  conversion('i', 0), conversion('e', 0), conversion('t', 0));
        \\assert.sameValue(order, 'iet');
        \\assert.sameValue(timed.async, false);
        \\assert.sameValue(timed.value, 'timed-out');
    );
    try std.testing.expectEqual(@as(usize, 9), probe.collections);
}

test "string boundary replaceAll reborrows after coercion and replacement GC" {
    const Probe = struct {
        rt: *core.JSRuntime,
        collections: usize = 0,
        fn make(ptr: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            var roots = core.runtime.ExactValueRoots(2){};
            try roots.activate(self.rt);
            defer roots.deactivate();
            const left = try roots.ref(0);
            const right = try roots.ref(1);
            try left.set(self.rt, (try core.string.String.createAscii(self.rt, "ab")).value());
            try right.set(self.rt, (try core.string.String.createAscii(self.rt, "a")).value());
            return (try core.string.String.createRope(self.rt, try left.get(self.rt), try right.get(self.rt))).value();
        }
        fn collect(ptr: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            _ = try self.rt.collectForTest();
            self.collections += 1;
            return core.JSValue.undefinedValue();
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var probe = Probe{ .rt = js.runtime };
    try js.defineGlobalExternalHostFunction("boundaryMakeRope", 0, &probe, Probe.make, null);
    try js.defineGlobalExternalHostFunction("boundaryCollect", 0, &probe, Probe.collect, null);
    js.runtime.forcePreciseRootScanForTest();
    defer js.runtime.restoreDefaultRootScanForTest();
    const result = try js.evalWithOptions(
        \\String.prototype.replaceAll.call(
        \\  { toString() { return boundaryMakeRope(); } },
        \\  { toString() { boundaryCollect(); return 'a'; } },
        \\  function(match, pos, source) {
        \\    boundaryCollect();
        \\    assert.sameValue(match, 'a');
        \\    assert.sameValue(source, 'aba');
        \\    assert.sameValue(pos === 0 || pos === 2, true);
        \\    return { toString() { boundaryCollect(); return boundaryMakeRope(); } };
        \\  });
    , .{ .filename = "<repl>" });
    try std.testing.expectEqual(@as(usize, 5), probe.collections);
    try std.testing.expect(core.string.asFlat(result).?.eqlBytes("abababa"));
}

const ReplaceCaptureGcProbe = struct {
    rt: *core.JSRuntime,
    victim: ?*core.gc.Header = null,
    collections: usize = 0,
    alive: bool = false,

    fn make(ptr: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const string = try core.string.String.createUtf8(self.rt, "fresh replacement capture");
        self.victim = string.header();
        return string.value();
    }

    fn collect(ptr: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = try self.rt.collectForTest();
        self.collections += 1;
        self.alive = self.rt.gc.containsHeader(self.victim orelse return error.MissingCapture);
        return core.JSValue.undefinedValue();
    }
};

test "replacement captures survive groups getter precise GC" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var probe = ReplaceCaptureGcProbe{ .rt = js.runtime };
    try js.defineGlobalExternalHostFunction("makeCapture", 0, &probe, ReplaceCaptureGcProbe.make, null);
    try js.defineGlobalExternalHostFunction("collectCapture", 0, &probe, ReplaceCaptureGcProbe.collect, null);
    var result_value = core.JSValue.undefinedValue();
    var source = core.JSValue.undefinedValue();
    var roots = core.runtime.rootValues(.{ &result_value, &source });
    roots.activate(js.runtime);
    defer roots.deactivate(js.runtime);
    source = try js.evalWithOptions("'a'", .{ .filename = "<repl>" });
    result_value = try js.evalWithOptions(
        \\({ 0: 'a', index: 0, length: 2,
        \\   get 1() { return makeCapture(); },
        \\   get groups() { collectCapture(); return undefined; } })
    , .{ .filename = "<repl>" });
    try std.testing.expect(result_value.is(.object));
    js.runtime.forcePreciseRootScanForTest();
    defer js.runtime.restoreDefaultRootScanForTest();
    const match = try engine.exec.string_ops.captureReplaceMatch(js.context, null, js.context.global.?, result_value, source, null, null);
    defer js.runtime.nativeAllocator().free(match.captures);
    // Check registry membership before dereferencing the potentially reclaimed value.
    try std.testing.expectEqual(@as(usize, 1), probe.collections);
    try std.testing.expect(probe.alive);
    try std.testing.expectEqual(@as(usize, 1), match.captures.len);
    try std.testing.expect(match.captures[0].asStringBodyRaw().?.eqlBytes("fresh replacement capture"));
}

test "replacement captures release storage on getter and coercion errors" {
    const cases = [_][]const u8{
        "({ 0: 'a', index: 0, length: 1, get groups() { throw 7; } })",
        "({ 0: 'a', 1: 'b', index: 0, length: 2, get groups() { throw 7; } })",
        "({ 0: 'a', 1: 'b', index: 0, length: 3, get 2() { throw 7; } })",
        "({ 0: 'a', 1: { toString() { throw 7; } }, index: 0, length: 2 })",
    };
    for (cases) |script| {
        var js = try helpers.TestEngine.init(std.testing.allocator);
        // Runtime teardown checks outstanding native allocations for each path.
        defer js.deinit();
        var result_value = core.JSValue.undefinedValue();
        var source = core.JSValue.undefinedValue();
        var roots = core.runtime.rootValues(.{ &result_value, &source });
        roots.activate(js.runtime);
        defer roots.deactivate(js.runtime);
        source = try js.evalWithOptions("'a'", .{ .filename = "<repl>" });
        result_value = try js.evalWithOptions(script, .{ .filename = "<repl>" });
        try std.testing.expect(result_value.is(.object));
        try std.testing.expectError(error.JSException, engine.exec.string_ops.captureReplaceMatch(js.context, null, js.context.global.?, result_value, source, null, null));
        const exception = js.context.takeException();
        try std.testing.expect(exception.is(.int));
        try std.testing.expectEqual(@as(?i32, 7), exception.as(.int));
    }
}

test "replacement captures release storage when match append fails" {
    const Probe = struct {
        calls: usize = 0,

        fn arm(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            const rt = invocation.realm.runtime;
            rt.suppressLimitCollectionForTest(true);
            rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
            return core.JSValue.undefinedValue();
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    defer js.runtime.suppressLimitCollectionForTest(false);
    defer js.runtime.setNativeBytesLimitForTest(null);
    var probe = Probe{};
    try js.defineGlobalExternalHostFunction("failMatchAppend", 0, &probe, Probe.arm, null);
    var rx = core.JSValue.undefinedValue();
    var source = core.JSValue.undefinedValue();
    var replacement = core.JSValue.undefinedValue();
    var roots = core.runtime.rootValues(.{ &rx, &source, &replacement });
    roots.activate(js.runtime);
    defer roots.deactivate(js.runtime);
    source = try js.evalWithOptions("'a'", .{ .filename = "<repl>" });
    replacement = try js.evalWithOptions("'x'", .{ .filename = "<repl>" });
    rx = try js.evalWithOptions(
        \\({ flags: '', exec() {
        \\    return { 0: 'a', 1: 'b', index: 0, length: 2,
        \\             get groups() { failMatchAppend(); } };
        \\} })
    , .{ .filename = "<repl>" });
    // The groups getter runs after capture allocation. The next allocation is
    // the first matches.append; Runtime teardown detects unadopted captures.
    try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.regExpSymbolReplaceGeneric(js.context, null, js.context.global.?, rx, source, replacement, null, null));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "replacement captures report exhausted root generations as OOM" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var source = core.JSValue.undefinedValue();
    var result_value = core.JSValue.undefinedValue();
    var roots = core.runtime.rootValues(.{ &source, &result_value });
    roots.activate(js.runtime);
    defer roots.deactivate(js.runtime);
    source = try js.evalWithOptions("'a'", .{ .filename = "<repl>" });
    result_value = try js.evalWithOptions("({0: 'a', index: 0, length: 1})", .{ .filename = "<repl>" });
    const saved = js.runtime.roots.exact_root_generation;
    js.runtime.roots.exact_root_generation = std.math.maxInt(u64);
    defer js.runtime.roots.exact_root_generation = saved;
    try std.testing.expectError(error.OutOfMemory, engine.exec.string_ops.captureReplaceMatch(js.context, null, js.context.global.?, result_value, source, null, null));
    try std.testing.expect(js.runtime.roots.active_exact_roots == null);
}

test "dense parameter arrays rest keeps contiguous storage and independent values" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const result = try js.evalWithOptions(
        \\function collect(first, ...rest) { return rest; }
        \\const marker = { value: 37 };
        \\const a = collect(0, marker, undefined, 9);
        \\const b = collect(0, marker, undefined, 9);
        \\assert.sameValue(a === b, false);
        \\assert.sameValue(a[0], marker);
        \\assert.sameValue(1 in a, true);
        \\assert.sameValue(a.length, 3);
        \\assert.sameValue(Object.getPrototypeOf(a), Array.prototype);
        \\assert.sameValue(collect().length, 0);
        \\assert.sameValue(collect(0).length, 0);
        \\a;
    , .{ .filename = "<repl>" });
    try std.testing.expect(result.is(.object));
    const array = helpers.objectFromValue(result);
    try std.testing.expectEqual(core.object.ArrayStorageMode.dense, array.arrayElementStorageMode());
    try std.testing.expectEqual(@as(usize, 3), array.arrayElements().len);
    try std.testing.expectEqual(@as(u32, 0), array.shape_ref.prop_count);
}

test "dense parameter arrays spread keeps contiguous storage for array and custom iterator" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    for ([_][]const u8{
        "[0, ...[1, 2, 3], 4]",
        "[0, ...{ [Symbol.iterator]() { let i=0; return { next() { return {value: ++i, done: i>3}; } }; } }, 4]",
    }) |source| {
        const result = try js.evalWithOptions(source, .{ .filename = "<repl>" });
        try std.testing.expect(result.is(.object));
        const array = helpers.objectFromValue(result);
        try std.testing.expectEqual(core.object.ArrayStorageMode.dense, array.arrayElementStorageMode());
        try std.testing.expectEqual(@as(usize, 5), array.arrayElements().len);
        for (array.arrayElements(), 0..) |value, index| {
            try std.testing.expectEqual(@as(?i32, @intCast(index)), value.as(.int));
        }
    }
}

// One deliberate departure from the qjs-generated text: qjs prints regexp
// flags by bit index over "gimsuydv", so a named-group pattern (flag bit 7)
// comes out as `/(?<n>x)/v`; zjs prints the flags the regexp actually has.
test "print / console.log dump objects like QuickJS JS_PrintValue (qjs-generated expectations, 36 shapes)" {
    // Expected text is the output of the pinned QuickJS yardstick binary on
    // the same source (tools: print_inspector.zig mirrors quickjs.c
    // Stacks are assigned explicitly because qjs and zjs
    // differ in the eval frame text, not in the dump.
    try helpers.expectPrints(
        \\(function () {
        \\print({ a: 1, b: "s", c: null, d: undefined, e: true, f: 1.5, g: -0, h: NaN, i: 1e21, j: 123n, k: -Infinity });
        \\print([ 1, 2, 3 ], [], {}, [ [ 1, [ 2, [ 3 ] ] ] ], { a: { b: { c: 1 } } });
        \\var c = { name: "c" }; c.self = c; c.arr = [c, { inner: c }]; print(c);
        \\print([1,,3], new Array(3), [1,2,,]);
        \\var sp = [1,2,3]; sp[10] = 4; var ap = [1,2]; ap.foo = "bar"; print(sp, ap);
        \\print("raw top-level string", { s: "quote\"d 'single' \\ back\nnl\ttab\x01ctl\x7fé\u{1F600}\ud800" });
        \\print({ "key with space": 1, "0": 2, 5: 3, "$ok_1": 4, "1abc": 5, "": 6, "é": 7 });
        \\var sym = Symbol("sd"); var o = {}; o[sym] = 1; o[Symbol()] = 2; print(o, sym, Symbol(), Symbol.iterator);
        \\print({ get g() { return 1; }, set s(v) {}, get gs() { return 1; }, set gs(v) {} });
        \\var e1 = new Error("boom"); Object.defineProperty(e1, "stack", { value: "    at fake (f.js:1:1)\n", writable: true, enumerable: false, configurable: true }); print(e1);
        \\var e2 = new TypeError("t"); Object.defineProperty(e2, "stack", { value: "    at fake", writable: true, enumerable: false, configurable: true }); e2.code = 42; print(e2);
        \\var e3 = new RangeError(""); Object.defineProperty(e3, "stack", { value: "    at fake", writable: true, enumerable: false, configurable: true }); print(e3, { e: e3 });
        \\class Foo { constructor() { this.x = 1; } m() {} } print(new Foo(), Foo, Foo.prototype.m);
        \\print(function named() {}, function () {}, () => 1, async function af() {}, function* gen() {}, class {}, Math.max);
        \\var bf = function base() {}; print(bf.bind(null), (() => 1).bind(null));
        \\var fp = function fp() {}; fp.extra = 1; print(fp);
        \\print(new Map([["a", 1], [{ k: 1 }, [2]]]), new Set([1, "two", { three: 3 }]), new Map(), new Set());
        \\var m = new Map([[1,1],[2,2],[3,3]]); m.delete(2); print(m);
        \\print(new Date(0), new Date(NaN), new Date(Date.UTC(2026, 8, 6, 12, 30, 0, 7)));
        \\print(/ab+c/gi, /a\/b[/]\n/su, new RegExp(""), new RegExp("a/b"), /x/dy, /(?<n>x)/);
        \\print(new Uint8Array([1, 2, 3]), new Float64Array([1.5, -0, NaN]), new Int8Array(0), new BigInt64Array([1n, -2n]), new Float32Array([0.1]), new Uint8ClampedArray([300]), new Int16Array([-2]));
        \\print(new ArrayBuffer(4), new DataView(new ArrayBuffer(2)), new Proxy({ a: 1 }, {}), new Proxy(function () {}, {}));
        \\print(Object.create(null), Object.assign(Object.create(null), { z: 1 }));
        \\print(new Number(1), new String("s"), new Boolean(false), Object(Symbol("q")), Object(1n));
        \\print(Promise.resolve(1), new WeakMap(), new WeakSet(), new WeakRef({}));
        \\(function () { print(arguments); })(1, "a");
        \\(function () { "use strict"; print(arguments); })(1, "a");
        \\print([1, 2, 3].values(), (function* () {})(), new Map().entries());
        \\var deep = {}; var cur = deep; for (var i = 0; i < 12; i++) { cur.n = {}; cur = cur.n; } print(deep);
        \\var big = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101]; print(big);
        \\var bigo = {}; for (var i = 0; i < 101; i++) bigo["k" + i] = i; print(bigo);
        \\print({ s: "z".repeat(1002) }, { s: "y".repeat(1001) });
        \\print(Object.defineProperty({ vis: 1 }, "hidden", { value: 2, enumerable: false }));
        \\print(undefined, null, true, 1, -0, 1.25, 10n, -5n, "top", Symbol("t"), 2 ** 53, 1e-7);
        \\print(new (class Bar extends Array {})(), [undefined, null, function () {}, Symbol("in")]);
        \\print({ nested: { arr: [ { deep: [1] } ] } }, Math, JSON);
        \\})();
    ,
        \\{ a: 1, b: "s", c: null, d: undefined, e: true, f: 1.5, g: -0, h: NaN, i: 1e+21, j: 123n, k: -Infinity }
        \\[ 1, 2, 3 ] [  ] {  } [ [ 1, [Array] ] ] { a: { b: [Object] } }
        \\{ name: "c", self: [circular 0], arr: [ [circular 0], [Object] ] }
        \\[ 0: 1, 2: 3 ] [ <3 empty items> ] [ 1, 2, <1 empty item> ]
        \\[ 0: 1, 1: 2, 2: 3, 10: 4 ] [ 1, 2, foo: "bar" ]
        \\raw top-level string { s: "quote\"d 'single' \\ back\nnl\ttab\u0001ctl\u007fé😀\ud800" }
        \\{ "key with space": 1, 0: 2, 5: 3, $ok_1: 4, "1abc": 5, "": 6, "é": 7 }
        \\{ sd: 1, "": 2 } Symbol(sd) Symbol("") Symbol("Symbol.iterator")
        \\{ g: [Getter], s: [Setter], gs: [Getter/Setter] }
        \\Error: boom
        \\    at fake (f.js:1:1)
        \\TypeError: t
        \\    at fake { code: 42 }
        \\RangeError
        \\    at fake { e: RangeError
        \\    at fake }
        \\{ x: 1 } [Function Foo] [Function m]
        \\[Function named] [Function (anonymous)] [Function (anonymous)] [Function af] [Function gen] [Function (anonymous)] [Function max]
        \\[Function bound base] [Function bound ]
        \\[Function fp] { extra: 1 }
        \\Map(2) { "a" => 1, { k: 1 } => [ 2 ] } Set(3) { 1, "two", { three: 3 } } Map(0) {  } Set(0) {  }
        \\Map(2) { 1 => 1, 3 => 3 }
        \\1970-01-01T00:00:00.000Z Date {  } 2026-09-06T12:30:00.007Z
        \\/ab+c/gi /a\/b[/]\n/su /(?:)/ /a\/b/ /x/yd /(?<n>x)/
        \\Uint8Array(3) [ 1, 2, 3 ] Float64Array(3) [ 1.5, -0, NaN ] Int8Array(0) [  ] BigInt64Array(2) [ 1, -2 ] Float32Array(1) [ 0.10000000149011612 ] Uint8ClampedArray(1) [ 255 ] Int16Array(1) [ -2 ]
        \\ArrayBuffer {  } DataView {  } Object {  } Object {  }
        \\{  } { z: 1 }
        \\Number {  } String {  } Boolean {  } Symbol {  } BigInt {  }
        \\Promise {  } WeakMap {  } WeakSet {  } WeakRef {  }
        \\Arguments {  }
        \\Arguments {  }
        \\"Array Iterator" {  } Generator {  } "Map Iterator" {  }
        \\{ n: { n: [Object] } }
        \\[ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, ... 2 more items ]
        \\{ k0: 0, k1: 1, k2: 2, k3: 3, k4: 4, k5: 5, k6: 6, k7: 7, k8: 8, k9: 9, k10: 10, k11: 11, k12: 12, k13: 13, k14: 14, k15: 15, k16: 16, k17: 17, k18: 18, k19: 19, k20: 20, k21: 21, k22: 22, k23: 23, k24: 24, k25: 25, k26: 26, k27: 27, k28: 28, k29: 29, k30: 30, k31: 31, k32: 32, k33: 33, k34: 34, k35: 35, k36: 36, k37: 37, k38: 38, k39: 39, k40: 40, k41: 41, k42: 42, k43: 43, k44: 44, k45: 45, k46: 46, k47: 47, k48: 48, k49: 49, k50: 50, k51: 51, k52: 52, k53: 53, k54: 54, k55: 55, k56: 56, k57: 57, k58: 58, k59: 59, k60: 60, k61: 61, k62: 62, k63: 63, k64: 64, k65: 65, k66: 66, k67: 67, k68: 68, k69: 69, k70: 70, k71: 71, k72: 72, k73: 73, k74: 74, k75: 75, k76: 76, k77: 77, k78: 78, k79: 79, k80: 80, k81: 81, k82: 82, k83: 83, k84: 84, k85: 85, k86: 86, k87: 87, k88: 88, k89: 89, k90: 90, k91: 91, k92: 92, k93: 93, k94: 94, k95: 95, k96: 96, k97: 97, k98: 98, k99: 99, ... 1 more item }
        \\{ s: "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"... 2 more characters } { s: "yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy"... 1 more character }
        \\{ vis: 1 }
        \\undefined null true 1 -0 1.25 10n -5n top Symbol(t) 9007199254740992 1e-7
        \\[  ] [ undefined, null, [Function (anonymous)], Symbol(in) ]
        \\{ nested: { arr: [Array] } } {  } {  }
        \\
    );
}

test "no-suspend async uses a same-Machine completion boundary" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    inline_calls.resetMachineTestMetrics();
    _ = try js.eval(
        \\async function leaf(x) { return x + 1; }
        \\var result = leaf(41);
        \\assert.sameValue(result instanceof Promise, true);
        \\assert.sameValue(Object.prototype.toString.call(leaf), "[object AsyncFunction]");
        \\assert.throws(TypeError, function () { new leaf(); });
    );
    try std.testing.expectEqual(@as(usize, 1), inline_calls.machineTestMetrics().same_machine_async_calls);
}

test "no-suspend async preserves parameter exceptions finally aliases and nested boundaries" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    inline_calls.resetMachineTestMetrics();
    _ = try js.eval(
        \\function fail(x) { throw x; }
        \\async function parameters(a = 1, f = () => a) { var a = 2; return [f(), a]; }
        \\async function bad(x = fail('parameter')) { throw 'body'; }
        \\assert.throws(Error, function () { bad((function () { throw Error('argument'); })()); });
        \\let p;
        \\try { p = bad(); } catch (_) { throw Error('synchronous parameter throw'); }
        \\async function outer(n) { if (n) return outer(n - 1); return 17; }
        \\async function final(x) { try { if (x) throw 3; return 4; } finally { if (x) return 5; } }
        \\const receiver = { value: 21, async method(a) { return this.value + a; } };
        \\async function alias(a) { let change = () => a++; change(); arguments[0]++; return a; }
        \\Promise.all([parameters(), p.catch(e => e), outer(20), final(false), final(true), receiver.method(21), alias(5)]).then(v => {
        \\    assert.sameValue(v[0][0], 1); assert.sameValue(v[0][1], 2);
        \\    assert.sameValue(v[1], 'parameter'); assert.sameValue(v[2], 17);
        \\    assert.sameValue(v[3], 4); assert.sameValue(v[4], 5);
        \\    assert.sameValue(v[5], 42); assert.sameValue(v[6], 7);
        \\    globalThis.e2BoundaryDone = true;
        \\});
    );
    // 1 parameter + 1 rejected parameter + 21 recursive + 2 finally + method + alias.
    try std.testing.expectEqual(@as(usize, 27), inline_calls.machineTestMetrics().same_machine_async_calls);
    try js.runJobs();
    _ = try js.eval("assert.sameValue(e2BoundaryDone, true);");
}

test "no-suspend async leaves suspension eval host-observed cadence and wrappers on fallback" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    inline_calls.resetMachineTestMetrics();
    _ = try js.eval(
        \\async function suspended() { await 0; return 1; }
        \\async function dynamic() { return eval('2'); }
        \\async function leaf() { return 3; }
        \\suspended(); dynamic(); leaf.bind(null)(); new Proxy(leaf, {})();
    );
    try std.testing.expectEqual(@as(usize, 0), inline_calls.machineTestMetrics().same_machine_async_calls);
    try js.runJobs();
    var interrupt = InterruptTestState{};
    js.runtime.setInterruptHandler(InterruptTestState.run, &interrupt);
    defer js.runtime.setInterruptHandler(null, null);
    _ = try js.eval("leaf();");
    try std.testing.expectEqual(@as(usize, 0), inline_calls.machineTestMetrics().same_machine_async_calls);
}

test "no-suspend async completion roots survive declared-only GC before and after frame pop" {
    const Probe = struct {
        running: usize = 0,
        completing: usize = 0,
        fn call(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const rt = invocation.realm.runtime;
            const active = inline_calls.activeInvocation(rt) orelse return error.TestUnexpectedResult;
            const store = &active.machine.async_completions;
            try std.testing.expect(store.count != 0);
            const slot = store.at(store.count - 1);
            try std.testing.expect(slot.promise.is(.object));
            if (slot.value.is(.undefined_value)) self.running += 1 else self.completing += 1;
            const old_major = rt.gc.stats.cycle_gc_count;
            _ = try rt.collectForTest();
            try std.testing.expect(rt.gc.stats.cycle_gc_count > old_major);
            return core.JSValue.undefinedValue();
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var probe = Probe{};
    try js.ensureTest262GlobalsInstalled();
    try js.defineGlobalExternalHostFunction("__e2BoundaryGC", 0, &probe, Probe.call, null);
    inline_calls.resetMachineTestMetrics();
    _ = try js.eval(
        \\async function nested() { return 8; }
        \\async function work() {
        \\    __e2BoundaryGC();
        \\    return { marker: 'alive', get then() {
        \\        __e2BoundaryGC();
        \\        nested();
        \\        return null;
        \\    }};
        \\}
        \\work().then(v => { assert.sameValue(v.marker, 'alive'); globalThis.e2RootsDone = true; });
    );
    try std.testing.expectEqual(@as(usize, 1), probe.running);
    try std.testing.expectEqual(@as(usize, 1), probe.completing);
    try std.testing.expectEqual(@as(usize, 2), inline_calls.machineTestMetrics().same_machine_async_calls);
    try js.runJobs();
    _ = try js.eval("assert.sameValue(e2RootsDone, true);");
}

test "no-suspend async final code policy includes hidden suspension and excludes nested bodies" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval(
        \\async function e2Plain() { return 1; }
        \\async function e2Nested() { return async function () { await 0; }; }
        \\async function e2ForAwait(xs) { for await (const x of xs) {} }
        \\async function e2Await() { await 0; }
        \\async function e2Eval() { return eval('1'); }
    );
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const Policy = bytecode.function_bytecode.AsyncExecutionPolicy;
    const rows = .{
        .{ "e2Plain", Policy.no_suspend },     .{ "e2Nested", Policy.no_suspend },
        .{ "e2ForAwait", Policy.may_suspend }, .{ "e2Await", Policy.may_suspend },
        .{ "e2Eval", Policy.unknown },
    };
    inline for (rows) |row| {
        const value = try global.getProperty(try js.runtime.internAtom(row[0]));
        const obj = try core.Object.expect(value);
        const fb = obj.bytecodeFunctionStoragePtr().function_bytecode.?;
        try std.testing.expectEqual(@as(u16, @intFromEnum(row[1])), fb.hotExtensionCanonical().?.async_execution_policy);
        try std.testing.expectEqual(@as(@TypeOf(fb.functionKind()), .async), fb.functionKind());
    }
}

test "no-suspend async transfers post-body OOM to FIFO without replay" {
    const Probe = struct {
        calls: usize = 0,
        fn call(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            const rt = invocation.realm.runtime;
            const active = inline_calls.activeInvocation(rt) orelse return error.TestUnexpectedResult;
            const store = &active.machine.async_completions;
            try std.testing.expectEqual(@as(u32, 1), store.count);
            const slot = store.at(0);
            try std.testing.expect(slot.value.is(.object)); // Callee already popped.
            const promise = try core.Object.expect(slot.promise);
            const ops = engine.exec.promise_ops;
            const undefined_value = core.JSValue.undefinedValue();
            const reaction = try ops.promiseReactionRecord(rt, undefined_value, undefined_value, undefined_value, undefined_value);
            try ops.appendPromiseReaction(rt, promise, reaction);
            rt.suppressLimitCollectionForTest(true);
            // Getter frame teardown returns accounted bytes; zero keeps the
            // following settlement allocation failing after that teardown.
            rt.setNativeBytesLimitForTest(0);
            return undefined_value;
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    defer js.runtime.setNativeBytesLimitForTest(null);
    defer js.runtime.suppressLimitCollectionForTest(false);
    var probe = Probe{};
    try js.ensureTest262GlobalsInstalled();
    try js.defineGlobalExternalHostFunction("__e2CompletionOOM", 0, &probe, Probe.call, null);
    _ = try js.eval(
        \\var e2OomPromise, e2OomBodyCount = 0, e2OomGetterCount = 0;
        \\async function e2OomWork() {
        \\    e2OomBodyCount++;
        \\    return {marker: 42, get then() { e2OomGetterCount++; return __e2CompletionOOM(); }};
        \\}
    );
    inline_calls.resetMachineTestMetrics();
    // TestEngine.eval also drains jobs. The body has finished and the FIFO
    // retry is published; that immediate drain must fail while the limit is
    // still armed and preserve the same settlement for a later retry.
    try std.testing.expectError(error.OutOfMemory, js.eval("e2OomPromise = e2OomWork();"));
    try std.testing.expectEqual(@as(usize, 1), inline_calls.machineTestMetrics().same_machine_async_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), js.runtime.job_queue.jobs.len);
    try std.testing.expectEqual(core.jobs.Kind.promise_settlement, std.meta.activeTag(js.runtime.job_queue.jobs[0].payload));
    js.runtime.setNativeBytesLimitForTest(null);
    js.runtime.suppressLimitCollectionForTest(false);
    _ = try js.runtime.collectForTest();
    try js.runJobs();
    _ = try js.eval(
        \\assert.sameValue(e2OomBodyCount, 1); assert.sameValue(e2OomGetterCount, 1);
        \\e2OomPromise.then(v => { assert.sameValue(v.marker, 42); globalThis.e2OomDone = true; });
    );
    try js.runJobs();
    _ = try js.eval("assert.sameValue(e2OomDone, true);");
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "P-Cap intrinsic then preserves independent results and pending handlers" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const ops = engine.exec.promise_ops;
    ops.resetThenCapabilityTestMetrics();
    _ = try js.eval(
        \\var wake, pending = new Promise(r => { wake = r; });
        \\var first = pending.then(v => { globalThis.pcapFirst = v; return v + 1; });
        \\var second = Promise.resolve(8).then(v => { globalThis.pcapSecond = v; });
        \\assert.sameValue(first === pending, false);
        \\assert.sameValue(first === second, false);
        \\assert.sameValue(Object.getPrototypeOf(first), Promise.prototype);
        \\wake(41);
    );
    try std.testing.expectEqual(@as(usize, 2), ops.thenCapabilityTestMetrics().intrinsic);
    try std.testing.expectEqual(@as(usize, 2), ops.thenCapabilityTestMetrics().intrinsic_settle);
    try std.testing.expectEqual(@as(usize, 0), ops.thenCapabilityTestMetrics().fallback);
    _ = try js.eval("assert.sameValue(pcapFirst, 41); assert.sameValue(pcapSecond, 8);");
}

test "P-Cap species observation keeps custom capability handshake" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const ops = engine.exec.promise_ops;
    ops.resetThenCapabilityTestMetrics();
    _ = try js.eval(
        \\var pcapLog = [], marker = {}, source = Promise.resolve(3);
        \\function C(executor) {
        \\    pcapLog.push('construct');
        \\    executor(v => pcapLog.push('resolve:' + v), e => pcapLog.push('reject:' + e));
        \\    return marker;
        \\}
        \\Object.defineProperty(source, 'constructor', {get() {
        \\    pcapLog.push('constructor');
        \\    return {get [Symbol.species]() { pcapLog.push('species'); return C; }};
        \\}});
        \\var result = source.then(v => { pcapLog.push('handler'); return v + 4; });
        \\assert.sameValue(result, marker);
    );
    try std.testing.expectEqual(@as(usize, 0), ops.thenCapabilityTestMetrics().intrinsic);
    try std.testing.expectEqual(@as(usize, 1), ops.thenCapabilityTestMetrics().fallback);
    _ = try js.eval("assert.sameValue(pcapLog.join(','), 'constructor,species,construct,handler,resolve:7');");
}

test "P-Cap intrinsic prototype survives species replacing global Promise" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const ops = engine.exec.promise_ops;
    ops.resetThenCapabilityTestMetrics();
    _ = try js.eval(
        \\var originalPromise = Promise, pcapSpeciesGets = 0, pcapResult;
        \\var source = originalPromise.resolve(9);
        \\source.constructor = {get [Symbol.species]() {
        \\    pcapSpeciesGets++;
        \\    globalThis.Promise = function Replacement() { throw Error('replacement called'); };
        \\    return originalPromise;
        \\}};
        \\var child = source.then(v => { pcapResult = v; });
        \\assert.sameValue(Object.getPrototypeOf(child), originalPromise.prototype);
        \\assert.sameValue(pcapSpeciesGets, 1);
        \\globalThis.Promise = originalPromise;
    );
    try std.testing.expectEqual(@as(usize, 1), ops.thenCapabilityTestMetrics().intrinsic);
    try std.testing.expectEqual(@as(usize, 0), ops.thenCapabilityTestMetrics().fallback);
    _ = try js.eval("assert.sameValue(pcapResult, 9);");
}

test "P-Cap thenable resolution identity thrower and FIFO preserve single observation" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const ops = engine.exec.promise_ops;
    ops.resetThenCapabilityTestMetrics();
    _ = try js.eval(
        \\var pcapOrder = [], pcapGetter = 0, pcapThen = 0, pcapSelf, pcapThrower;
        \\var p = Promise.resolve(1), self;
        \\self = p.then(() => self);
        \\self.catch(e => { pcapSelf = e instanceof TypeError; });
        \\p.then(() => { pcapOrder.push('handler'); return {get then() {
        \\    pcapGetter++; return function(resolve, reject) { pcapThen++; pcapOrder.push('then'); resolve(42); reject(0); };
        \\}}; }).then(v => { assert.sameValue(v, 42); pcapOrder.push('result'); });
        \\p.then(() => { pcapOrder.push('peer'); });
        \\Promise.reject('reason').then().catch(e => { pcapThrower = e; });
        \\p.then().then(v => { assert.sameValue(v, 1); });
    );
    try std.testing.expectEqual(@as(usize, 9), ops.thenCapabilityTestMetrics().intrinsic);
    try std.testing.expectEqual(@as(usize, 0), ops.thenCapabilityTestMetrics().fallback);
    _ = try js.eval(
        \\assert.sameValue(pcapOrder.join(','), 'handler,peer,then,result');
        \\assert.sameValue(pcapGetter, 1); assert.sameValue(pcapThen, 1);
        \\assert.sameValue(pcapSelf, true); assert.sameValue(pcapThrower, 'reason');
    );
}

test "P-Cap foreign species falls back and delayed foreign settlement keeps self error realm" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const ops = engine.exec.promise_ops;
    ops.resetThenCapabilityTestMetrics();
    _ = try js.eval(
        \\var pcapForeign = $262.createRealm();
        \\var source = Promise.resolve(1);
        \\source.constructor = {[Symbol.species]: pcapForeign.global.Promise};
        \\var foreignChild = source.then(v => v + 1);
        \\assert.sameValue(Object.getPrototypeOf(foreignChild), pcapForeign.global.Promise.prototype);
        \\pcapForeign.evalScript('globalThis.pending = new Promise(r => { globalThis.wake = r; });');
        \\var foreignSource = pcapForeign.global.pending, local, pcapRealmOK = false;
        \\// Select the local intrinsic while the pending source will settle in the foreign Realm.
        \\foreignSource.constructor = {[Symbol.species]: Promise};
        \\local = Promise.prototype.then.call(foreignSource, () => local);
        \\local.catch(e => { pcapRealmOK = e instanceof TypeError && !(e instanceof pcapForeign.global.TypeError); });
        \\pcapForeign.evalScript('wake(1);');
    );
    try std.testing.expectEqual(@as(usize, 1), ops.thenCapabilityTestMetrics().fallback);
    try std.testing.expectEqual(@as(usize, 2), ops.thenCapabilityTestMetrics().intrinsic);
    _ = try js.eval("assert.sameValue(pcapRealmOK, true);");
}

test "P-Cap post-handler and post-getter OOM retain FIFO completion without replay" {
    const Probe = struct {
        calls: usize = 0,
        fn call(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            const rt = invocation.realm.runtime;
            _ = try rt.collectForTest();
            rt.suppressLimitCollectionForTest(true);
            rt.setNativeBytesLimitForTest(0);
            return core.JSValue.int32(42);
        }
    };
    for ([_]bool{ false, true }) |getter| {
        var js = try helpers.TestEngine.init(std.testing.allocator);
        defer js.deinit();
        defer js.runtime.setNativeBytesLimitForTest(null);
        defer js.runtime.suppressLimitCollectionForTest(false);
        var probe = Probe{};
        try js.ensureTest262GlobalsInstalled();
        try js.defineGlobalExternalHostFunction("__pcapArmOOM", 0, &probe, Probe.call, null);
        _ = try js.eval(
            \\var pcapBodyCalls = 0, pcapGetterCalls = 0, pcapFinal, pcapChild;
            \\function primitive() { pcapBodyCalls++; return __pcapArmOOM(); }
            \\function objectResult() { pcapBodyCalls++; return {marker: 42, get then() { pcapGetterCalls++; __pcapArmOOM(); return null; }}; }
        );
        const ops = engine.exec.promise_ops;
        ops.resetThenCapabilityTestMetrics();
        try std.testing.expectError(error.OutOfMemory, js.eval(if (getter)
            "pcapChild = Promise.resolve(1).then(objectResult); pcapChild.then(v => { pcapFinal = v.marker; });"
        else
            "pcapChild = Promise.resolve(1).then(primitive); pcapChild.then(v => { pcapFinal = v; });"));
        try std.testing.expectEqual(@as(usize, 1), probe.calls);
        try std.testing.expectEqual(@as(usize, 2), ops.thenCapabilityTestMetrics().intrinsic);
        try std.testing.expectEqual(@as(usize, 1), ops.thenCapabilityTestMetrics().intrinsic_settle);
        try std.testing.expectEqual(@as(usize, 1), js.runtime.job_queue.jobs.len);
        try std.testing.expectEqual(core.jobs.Kind.promise_settlement, std.meta.activeTag(js.runtime.job_queue.jobs[0].payload));
        js.runtime.setNativeBytesLimitForTest(null);
        js.runtime.suppressLimitCollectionForTest(false);
        _ = try js.runtime.collectForTest();
        try js.runJobs();
        try std.testing.expectEqual(@as(usize, 2), ops.thenCapabilityTestMetrics().intrinsic_settle);
        _ = try js.eval(if (getter)
            "assert.sameValue(pcapBodyCalls, 1); assert.sameValue(pcapGetterCalls, 1); assert.sameValue(pcapFinal, 42);"
        else
            "assert.sameValue(pcapBodyCalls, 1); assert.sameValue(pcapGetterCalls, 0); assert.sameValue(pcapFinal, 42);");
        try std.testing.expectEqual(@as(usize, 1), probe.calls);
    }
}

test "P-Cap retries reserved reaction phase before then getter without replaying handler" {
    const Probe = struct {
        calls: usize = 0,
        fn call(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            invocation.realm.runtime.suppressLimitCollectionForTest(true);
            invocation.realm.runtime.setNativeBytesLimitForTest(0);
            return core.JSValue.undefinedValue();
        }
        fn tail(_: *core.JSContext, _: []const core.JSValue) core.JSValue {
            return core.JSValue.undefinedValue();
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    defer js.runtime.setNativeBytesLimitForTest(null);
    defer js.runtime.suppressLimitCollectionForTest(false);
    var probe = Probe{};
    try js.ensureTest262GlobalsInstalled();
    try js.defineGlobalExternalHostFunction("__pcapReserveOOM", 0, &probe, Probe.call, null);
    _ = try js.eval(
        \\var pcapReserveGetter = 0, pcapReserveChild;
        \\var pcapReserveObject = {marker: 73, get then() { pcapReserveGetter++; return null; }};
        \\function pcapSchedule() {
        \\    pcapReserveChild = Promise.resolve(1).then(() => { __pcapReserveOOM(); return pcapReserveObject; });
        \\}
    );
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const schedule = try global.getProperty(try js.runtime.internAtom("pcapSchedule"));
    const ops = engine.exec.promise_ops;
    ops.resetThenCapabilityTestMetrics();
    // Invoke without the TestEngine.eval auto-drain, then fill the current
    // queue capacity. The unlinked head is reserved for retry, so the
    // resolution's extra durable slot must grow and actually hit OOM.
    _ = try engine.exec.call_runtime.callValueOrBytecodeRoot(js.context, null, global, core.JSValue.undefinedValue(), schedule, &.{}, null, null);
    while (js.runtime.job_queue.jobs.len < js.runtime.job_queue.capacity) {
        try js.runtime.job_queue.enqueueFunc(js.context, Probe.tail, &.{});
    }
    const queued = js.runtime.job_queue.jobs.len;
    try std.testing.expectError(error.OutOfMemory, ops.drainOnePendingJob(js.context, null));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), ops.thenCapabilityTestMetrics().intrinsic);
    try std.testing.expectEqual(@as(usize, 1), ops.thenCapabilityTestMetrics().intrinsic_retry);
    try std.testing.expectEqual(queued, js.runtime.job_queue.jobs.len);
    try std.testing.expectEqual(core.jobs.PromiseReactionPhase.resolve, js.runtime.job_queue.jobs[0].payload.promise_reaction.phase);
    const getter_key = try js.runtime.internAtom("pcapReserveGetter");
    try std.testing.expectEqual(@as(?i32, 0), (try global.getProperty(getter_key)).as(.int));
    js.runtime.setNativeBytesLimitForTest(null);
    js.runtime.suppressLimitCollectionForTest(false);
    _ = try js.runtime.collectForTest();
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), ops.thenCapabilityTestMetrics().intrinsic_settle);
    _ = try js.eval("assert.sameValue(pcapReserveGetter, 1);");
}

test "fulfilled await preserves FIFO and bypasses an overridden then" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval(
        \\var directOrder = [], directThen = Promise.prototype.then;
        \\Promise.prototype.then = function () { throw new Error('observable then'); };
        \\async function directSequence() {
        \\    directOrder.push('start');
        \\    await 0;
        \\    directOrder.push('first');
        \\    await 1;
        \\    directOrder.push('second');
        \\}
        \\directSequence();
        \\directThen.call(Promise.resolve(), () => directOrder.push('then'));
        \\directOrder.push('sync');
    );
    _ = try js.eval("if (directOrder.join(',') !== 'start,sync,first,then,second') throw new Error(directOrder);");
}

test "fulfilled await preserves the registration and body realms" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var parent_facade = zjs.borrowContext(js.context);
    const parent_global = try zjs.globalObjectPtr(&parent_facade);
    var child_holder = try engine.exec.call.createRealmObject(js.context);
    var child_root = core.runtime.rootValues(.{&child_holder});
    child_root.activate(js.runtime);
    defer child_root.deactivate(js.runtime);
    const child = (try core.Object.expect(child_holder)).realmContext().?;
    const child_global = try engine.exec.zjs_vm.contextGlobal(child);
    var child_facade = zjs.borrowContext(child);
    _ = try child_facade.eval("globalThis.foreignDirect = async function () { await 0; return new Error('foreign'); };", .{});
    const function = try child_global.getProperty(try js.runtime.internAtom("foreignDirect"));
    var output = try engine.exec.call_runtime.callValueOrBytecodeRoot(js.context, null, parent_global, core.JSValue.undefinedValue(), function, &.{}, null, null);
    var roots = core.runtime.rootValues(.{&output});
    roots.activate(js.runtime);
    defer roots.deactivate(js.runtime);
    try std.testing.expectEqual(@as(usize, 1), js.runtime.job_queue.jobs.len);
    const job = &js.runtime.job_queue.jobs[0];
    try std.testing.expectEqual(core.jobs.Kind.async_resume, std.meta.activeTag(job.payload));
    try std.testing.expectEqual(js.context, job.realm.borrow().?);
    try std.testing.expectEqual(core.jobs.RunOneStatus.success, try engine.exec.promise_ops.drainOnePendingJob(child, null));
    const promise = try core.Object.expect(output);
    try std.testing.expect(!promise.promiseIsRejected());
    const result = try core.Object.expect(promise.promiseResult().?);
    try std.testing.expectEqual(object_ops.constructorPrototypeFromGlobal(js.runtime, child_global, "Error").?, result.getPrototype().?);
}

test "fulfilled await does not replay a resumed body after allocation failure" {
    const Probe = struct {
        calls: usize = 0,
        fn call(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            invocation.realm.runtime.suppressLimitCollectionForTest(true);
            invocation.realm.runtime.setNativeBytesLimitForTest(0);
            return core.JSValue.undefinedValue();
        }
    };
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    defer js.runtime.setNativeBytesLimitForTest(null);
    defer js.runtime.suppressLimitCollectionForTest(false);
    var probe = Probe{};
    try js.defineGlobalExternalHostFunction("directResumeOOM", 0, &probe, Probe.call, null);
    _ = try js.eval("globalThis.directFail = async function () { await 0; directResumeOOM(); return {marker: 42}; };");
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const function = try global.getProperty(try js.runtime.internAtom("directFail"));
    var output = try engine.exec.call_runtime.callValueOrBytecodeRoot(js.context, null, global, core.JSValue.undefinedValue(), function, &.{}, null, null);
    var roots = core.runtime.rootValues(.{&output});
    roots.activate(js.runtime);
    defer roots.deactivate(js.runtime);
    try std.testing.expectEqual(core.jobs.Kind.async_resume, std.meta.activeTag(js.runtime.job_queue.jobs[0].payload));
    _ = try engine.exec.promise_ops.drainOnePendingJob(js.context, null);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), js.runtime.job_queue.jobs.len);
    const promise = try core.Object.expect(output);
    try std.testing.expect(promise.promiseIsRejected());
    try std.testing.expect(promise.promiseResult() != null);
    core.promise.markHandled(js.context, promise);
    engine.exec.promise_ops.clearHandledRejectionException(js.context);
    js.runtime.setNativeBytesLimitForTest(null);
    js.runtime.suppressLimitCollectionForTest(false);
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "string index boundary preserves conversion order and exceptional indices" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval(
        \\const order = [];
        \\const receiver = {toString() { order.push('string'); return 'a😀z'; }};
        \\const index = {valueOf() { order.push('index'); $262.gc(); return 1; }};
        \\assert.sameValue(String.prototype.charCodeAt.call(receiver, index), 0xd83d);
        \\assert.sameValue(order.join(','), 'string,index');
        \\assert.sameValue(String.prototype.codePointAt.call(receiver, index), 0x1f600);
        \\assert.sameValue(String.prototype.at.call(receiver, {valueOf(){ $262.gc(); return -1; }}), 'z');
        \\assert.sameValue('abc'.charCodeAt(NaN), 97);
        \\assert.sameValue('abc'.charCodeAt(Infinity), NaN);
        \\assert.sameValue('abc'.charCodeAt(-1), NaN);
        \\assert.throws(TypeError, () => 'abc'.charCodeAt(Symbol()));
        \\assert.throws(TypeError, () => 'abc'.charCodeAt(1n));
        \\assert.throws(RangeError, () => String.prototype.charCodeAt.call(receiver, {valueOf(){ throw new RangeError(); }}));
    );
}

test "string index boundary test262 messages preserve rope representation" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try js.ensureTest262GlobalsInstalled();
    const rt = js.runtime;
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    var roots = core.runtime.ExactValueRoots(2){};
    try roots.activate(rt);
    defer roots.deactivate();
    const left = try roots.ref(0);
    const right = try roots.ref(1);
    try left.set(rt, (try core.string.String.createUtf16(rt, &.{ 'A', 0xe9, 0xd83d })).value());
    try right.set(rt, (try core.string.String.createUtf16(rt, &.{ 0xde00, 'Z' })).value());
    try left.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value());
    try global.defineOwnProperty(rt, core.atom.ids.value, core.Descriptor.data(try left.get(rt), .all));
    const result = try js.evalWithOptions("new Test262Error(value).message === value", .{ .filename = "<repl>" });
    try std.testing.expectEqual(@as(?bool, true), result.as(.boolean));
    try std.testing.expect(!(try left.get(rt)).ropeBody().?.isLinearized());
}

test "host string boundary prints ropes without materializing" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try engine.exec.zjs_vm.contextGlobal(ctx);
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const source = try roots.ref(0);
    const right = try roots.ref(1);
    const object = try roots.ref(2);
    const units = [_]u16{ 'A', 0xe9, 0x100, 0xd83d, 0xde00, 'Z' };
    for (0..4) |mode| {
        try source.set(rt, (try core.string.String.createUtf16(rt, units[0..4])).value());
        try right.set(rt, (try core.string.String.createUtf16(rt, units[4..])).value());
        try source.set(rt, switch (mode) {
            0 => (try core.string.String.createUtf16(rt, &units)).value(),
            3 => (try core.string.createTailBufferRope(rt, core.string.asFlat(try source.get(rt)).?, core.string.asFlat(try right.get(rt)).?)).value(),
            else => (try core.string.String.createRope(rt, try source.get(rt), try right.get(rt))).value(),
        });
        if (mode == 2) try core.string.ensureFlat(rt, source.readOnly(), right);
        try object.set(rt, (try core.Object.createPlainObject(rt, null)).value());
        try core.Object.fromHeader((try object.get(rt)).refHeader().?).defineOwnProperty(rt, core.atom.ids.value, core.Descriptor.data(try source.get(rt), .all));
        rt.setMemoryLimit(0);
        defer rt.setMemoryLimit(null);
        var no_gc = core.runtime.NoGcScope{};
        no_gc.activate(rt);
        defer no_gc.deactivate();
        var bytes: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try @import("zjs_host").output.printHostArgument(ctx, global, null, &writer, try source.get(rt));
        try std.testing.expectEqualStrings("AéĀ😀Z", writer.buffered());
        writer.end = 0;
        try @import("zjs_host").output.printHostArgument(ctx, global, null, &writer, try object.get(rt));
        try std.testing.expectEqualStrings("{ value: \"AéĀ😀Z\" }", writer.buffered());
        if (mode == 1) try std.testing.expect(!(try source.get(rt)).ropeBody().?.isLinearized());
        if (mode == 3) try std.testing.expect((try source.get(rt)).ropeBody().?.buffer != null);
    }
}

test "host string boundary writer reentry keeps input alive" {
    const Sink = struct {
        writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
        destination: *std.Io.Writer,
        rt: *core.JSRuntime,
        input: core.JSValue,
        failure: ?anyerror = null,
        calls: usize = 0,
        fail_write: bool,
        fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *@This() = @fieldParentPtr("writer", writer);
            self.reenter() catch |err| {
                self.failure = err;
                return error.WriteFailed;
            };
            if (self.fail_write) return error.WriteFailed;
            return self.destination.writeSplat(data, splat);
        }
        fn reenter(self: *@This()) !void {
            self.calls += 1;
            _ = try self.rt.collectForTest();
            if (!self.rt.gc.containsHeader(self.input.cycleMarkHeader().?)) return error.LostOutputInput;
            if (self.calls == 1) {
                var roots = core.runtime.ExactValueRoots(2){};
                try roots.activate(self.rt);
                defer roots.deactivate();
                const input = try roots.ref(0);
                const result = try roots.ref(1);
                try input.set(self.rt, self.input);
                try core.string.ensureFlat(self.rt, input.readOnly(), result);
                _ = try self.rt.collectForTest();
            }
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |fail_write| {
            const rt = try core.JSRuntime.create(std.testing.allocator, .{});
            defer rt.destroy();
            rt.gc.nursery.enabled = nursery;
            rt.gc.scheduler.host_quiescent = true;
            const ctx = try core.JSContext.create(rt, .{});
            defer ctx.destroy();
            const global = try engine.exec.zjs_vm.contextGlobal(ctx);
            const input = setup: {
                var roots = core.runtime.ExactValueRoots(2){};
                try roots.activate(rt);
                defer roots.deactivate();
                const left = try roots.ref(0);
                const right = try roots.ref(1);
                try left.set(rt, (try core.string.String.createUtf16(rt, &.{ 'A', 0xe9, 0xd83d })).value());
                try right.set(rt, (try core.string.String.createUtf16(rt, &.{ 0xde00, 'Z' })).value());
                break :setup (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value();
            };
            var bytes: [64]u8 = undefined;
            var destination = std.Io.Writer.fixed(&bytes);
            var sink = Sink{ .rt = rt, .input = input, .destination = &destination, .fail_write = fail_write };
            const result = @import("zjs_host").output.printHostArgument(ctx, global, null, &sink.writer, input);
            if (sink.failure) |err| return err;
            if (fail_write) {
                try std.testing.expectError(error.WriteFailed, result);
            } else {
                try result;
                try std.testing.expectEqualStrings("Aé😀Z", destination.buffered());
            }
            try std.testing.expect(sink.calls > 0);
            try std.testing.expect(rt.active_value_roots == null);
        }
    }
}

test "host string boundary base64 reads ropes without materializing" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const rt = js.runtime;
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    try @import("zjs_host").globals.install(js.context, global);
    var roots = core.runtime.ExactValueRoots(2){};
    try roots.activate(rt);
    defer roots.deactivate();
    const left = try roots.ref(0);
    const right = try roots.ref(1);
    for ([_]bool{ false, true }) |decode| {
        try left.set(rt, (try core.string.String.createAscii(rt, if (decode) "Qe" else "A")).value());
        try right.set(rt, (try core.string.String.createLatin1(rt, if (decode) "k=" else "\xe9")).value());
        try left.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value());
        try global.defineOwnProperty(rt, core.atom.ids.value, core.Descriptor.data(try left.get(rt), .all));
        const result = try js.evalWithOptions(if (decode) "atob(value) === 'A\\u00e9'" else "btoa(value) === 'Qek='", .{ .filename = "<repl>" });
        try std.testing.expectEqual(@as(?bool, true), result.as(.boolean));
        try std.testing.expect(!(try left.get(rt)).ropeBody().?.isLinearized());
    }
}

test "print writes top-level strings raw including latin1 high bytes" {
    try helpers.expectPrints(
        \\print("ascii", String.fromCharCode(0xC9), { s: String.fromCharCode(0xC9) });
    ,
        "ascii É { s: \"É\" }\n",
    );
}

test "all-cold fused pushes keep their leftover opcode" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // `(a | 0)` compiles to `push_0` + `or` and `(b >> 2)` to `push_2` + `sar`;
    // resolve_labels fuses each pair's first half into a ONE-byte fused opcode
    // whose handler re-enters the leftover `or` / `sar`.
    _ = try js.eval(
        \\globalThis.__coldFusedPushes = function (a, b) { return (a | 0) + (b >> 2); };
    );
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const key = try js.runtime.internAtom("__coldFusedPushes");
    const function_value = try global.getProperty(key);
    const function_object = try property_ops.expectObject(function_value);
    const stored_bytecode = function_object.functionBytecode() orelse return error.InvalidFunctionBytecode;
    const function = engine.exec.call_runtime.functionBytecodeFromValue(stored_bytecode) orelse
        return error.InvalidFunctionBytecode;

    var stack = engine.exec.stack.Stack.init(js.runtime, js.context.stackLimit());
    defer stack.deinit(js.runtime);

    // A `stop_before_pc` past the last instruction never fires, but it does pin
    // the L0 frame to the ALL-COLD dispatch table, which is the only route that
    // reaches `op_push_0_or_cold` / `op_push_2_sar_cold`. Both fused opcodes are
    // one byte, so `Vm.publish` already parks `frame.pc` on the leftover
    // `or` / `sar`; an extra `frame.pc += 1` in those handlers would skip it and
    // strand the pushed `0` / `2` on the operand stack.
    const result = try engine.exec.zjs_vm.runWithCallEnv(.{
        .ctx = js.context,
        .stack = &stack,
        .function = function,
        .initial_this_value = global.value(),
        .args = &.{ core.JSValue.int32(5), core.JSValue.int32(24) },
        .global = global,
        .current_function_value = function_value,
        .stop_before_pc = function.byteCode().len + 1,
    });
    try std.testing.expectEqual(@as(?i32, 11), result.as(.int));
}
