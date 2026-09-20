//! Exercises built-in objects, native handlers, and observable realm semantics.
const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const core = zjs.core;
const op = zjs.bytecode.opcode.op;

const helpers = @import("helpers.zig");

const runFunction = helpers.runFunction;
const objectFromValue = helpers.objectFromValue;
const expectActiveSetStrings = helpers.expectActiveSetStrings;

test "bare Math scalar fallback shares qjs edge semantics" {
    const math = engine.exec.math_ops;

    const rounded = try math.call(4, &.{core.JSValue.float64(-0.1)});
    try std.testing.expect(std.math.isNegativeZero(rounded));

    const powered = try math.call(6, &.{
        core.JSValue.int32(-1),
        core.JSValue.float64(std.math.inf(f64)),
    });
    try std.testing.expect(std.math.isNan(powered));

    const minimum = try math.call(7, &.{
        core.JSValue.int32(0),
        core.JSValue.float64(-0.0),
    });
    const maximum = try math.call(8, &.{
        core.JSValue.float64(-0.0),
        core.JSValue.int32(0),
    });
    try std.testing.expect(std.math.isNegativeZero(minimum));
    try std.testing.expect(!std.math.isNegativeZero(maximum));
    try std.testing.expectError(error.TypeError, math.call(9, &.{}));
}

test "Math min max induction range fast path preserves observable method lookup" {
    try helpers.expectPrints(
        \\let minSum = 0;
        \\for (let i = 0; i < 1000; i++) minSum += Math.min(i, 50);
        \\print(minSum);
        \\let maxSum = 0;
        \\for (let i = -3; i < 1000; i++) maxSum += Math.max(i, 4);
        \\print(maxSum);
        \\let reversed = 0;
        \\for (let i = -5; i < 5; i++) reversed += Math.min(2, i);
        \\print(reversed);
        \\let savedMin = Math.min;
        \\let calls = 0;
        \\Math.min = function(a, b) { calls++; return b - a; };
        \\let slow = 0;
        \\for (let i = 0; i < 1000; i++) slow += Math.min(i, 3);
        \\Math.min = savedMin;
        \\print(calls, slow);
    , "48725\n499522\n-8\n1000 -496500\n");
}

test "induction int32 sum range fast path preserves safe number results" {
    try helpers.expectPrints(
        \\let sum = 0;
        \\for (let i = 0; i < 60000; i++) sum += i;
        \\print(sum);
        \\let large = 0;
        \\for (let i = 0; i < 1000000; i++) large += i;
        \\print(large, typeof large);
        \\let offset = 10;
        \\for (let i = -3; i < 4; i++) offset += i;
        \\print(offset);
    , "1799970000\n499999500000 number\n10\n");
}

test "latin1 string literal append range fast path preserves fallbacks" {
    try helpers.expectPrints(
        \\let s = "a";
        \\for (let i = 0; i < 5; i++) s += "xy";
        \\print(s);
        \\let skipped = "z";
        \\for (let i = 3; i < 1; i++) skipped += "x";
        \\print(skipped);
        \\let calls = 0;
        \\let dynamic = { toString: function() { calls++; return "q"; } };
        \\for (let i = 0; i < 4; i++) dynamic += "x";
        \\print(calls, dynamic);
        \\let wide = "";
        \\for (let i = 0; i < 3; i++) wide += "é";
        \\print(wide.length, wide.charCodeAt(0), wide.charCodeAt(1), wide.charCodeAt(2));
    , "axyxyxyxyxy\nz\n1 qxxxx\n3 233 233 233\n");
}

test "latin1 string literal append range fast path collapses loop opcodes" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let s = "";
        \\for (let i = 0; i < 2000; i++) s += "x";
        \\print(s.length);
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("2000\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.add]);
}

test "latin1 string literal append range fast path accepts i8 loop limits" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let s = "";
        \\for (let i = 0; i < 50; i++) s += "x";
        \\print(s.length);
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("50\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.add]);
}

test "host output Number static literal fast path materializes lazy constructor" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(Number.parseInt("12345", 10));
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("12345\n", stream.buffered());
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.get_field2]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.call1]);
}

test "empty script eval uses root entry without user call opcodes" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    const result = try js.eval("");

    try std.testing.expect(result.is(.undefined_value));
    // The root evaluator is not a bytecode `call` instruction, so entering its
    // generic VM path does not increment the user-call profile counters.
    try std.testing.expectEqual(@as(u64, 0), profile.totalOpcodeCount());
    try std.testing.expectEqual(@as(u64, 0), profile.call_frame_count);
}

test "short BigInt induction sum range fast path preserves exact results" {
    try helpers.expectPrints(
        \\let x = 0n;
        \\for (let i = 0n; i < 10000n; i++) x += i;
        \\print(x, typeof x);
        \\let y = 10n;
        \\for (let i = -3n; i < 4n; i++) y += i;
        \\print(y);
        \\let large = 9223372036854775806n;
        \\for (let i = 0n; i < 3n; i++) large += i;
        \\print(large);
        \\let skipped = 7n;
        \\for (let i = 5n; i < 3n; i++) skipped += i;
        \\print(skipped);
    , "49995000n bigint\n10n\n9223372036854775809n\n7n\n");
}

test "simple numeric bytecode call range fast path preserves side effect fallback" {
    try helpers.expectPrints(
        \\function add(a, b) { return a + b; }
        \\let direct = 0;
        \\for (let i = 0; i < 1000; i++) direct += add(i, 1);
        \\print(direct);
        \\function make(x) { return function(y) { return x + y; }; }
        \\const closure = make(1);
        \\let closed = 0;
        \\for (let i = 0; i < 1000; i++) closed += closure(i);
        \\print(closed);
        \\let calls = 0;
        \\function observed(a, b) { calls++; return a + b; }
        \\let slow = 0;
        \\for (let i = 0; i < 1000; i++) slow += observed(i, 1);
        \\print(calls, slow);
        \\function aliasCase() {
        \\  let captured = 1;
        \\  const reader = function(y) { return captured + y; };
        \\  for (let i = 0; i < 5; i++) captured += reader(i);
        \\  return captured;
        \\}
        \\print(aliasCase());
    , "500500\n500500\n1000 500500\n58\n");
}

test "invariant int32 property and dense array range fast path preserves observable reads" {
    try helpers.expectPrints(
        \\let own = { a: 1, b: 2 };
        \\let ownSum = 0;
        \\for (let i = 0; i < 1000; i++) ownSum += own.a;
        \\print(ownSum);
        \\let proto = { a: 7 };
        \\let child = Object.create(proto);
        \\let protoSum = 0;
        \\for (let i = 0; i < 1000; i++) protoSum += child.a;
        \\print(protoSum);
        \\let tab = [3];
        \\let arraySum = 0;
        \\for (let i = 0; i < 1000; i++) arraySum += tab[0];
        \\print(arraySum);
        \\let calls = 0;
        \\let guarded = {};
        \\Object.defineProperty(guarded, "a", { get: function() { calls++; return 2; } });
        \\let guardedSum = 0;
        \\for (let i = 0; i < 1000; i++) guardedSum += guarded.a;
        \\print(calls, guardedSum);
        \\let arrayCalls = 0;
        \\Object.defineProperty(Array.prototype, "0", { get: function() { arrayCalls++; return 4; }, configurable: true });
        \\let hole = [];
        \\let holeSum = 0;
        \\for (let i = 0; i < 1000; i++) holeSum += hole[0];
        \\delete Array.prototype[0];
        \\print(arrayCalls, holeSum);
    , "1000\n7000\n3000\n1000 2000\n1000 4000\n");
}

test "dense array modulo field range fast path preserves observable reads" {
    try helpers.expectPrints(
        \\const a = { x: 1, y: 0 };
        \\const b = { y: 0, x: 2 };
        \\const c = { z: 0, x: 3 };
        \\const arr = [a, b, c];
        \\let s = 0;
        \\for (let i = 0; i < 1000; i++) s += arr[i % 3].x;
        \\print(s);
        \\let calls = 0;
        \\const guarded = {};
        \\Object.defineProperty(guarded, "x", { get: function() { calls++; return 5; } });
        \\const observed = [{ x: 1 }, guarded, { x: 3 }];
        \\let observedSum = 0;
        \\for (let i = 0; i < 9; i++) observedSum += observed[i % 3].x;
        \\print(calls, observedSum);
        \\const signed = [{ x: 1 }, { x: -2 }, { x: 3 }];
        \\let signedSum = 0;
        \\for (let i = 0; i < 6; i++) signedSum += signed[i % 3].x;
        \\print(signedSum);
    , "1999\n3 27\n4\n");
}

test "dense array length indexed sum range fast path preserves observable reads" {
    try helpers.expectPrints(
        \\const direct = [];
        \\for (let i = 0; i < 1000; i++) direct[i] = i;
        \\let directSum = 0;
        \\for (let i = 0; i < direct.length; i++) directSum += direct[i];
        \\print(directSum);
        \\const signed = [-2, 3, -4];
        \\let signedSum = 0;
        \\for (let i = 0; i < signed.length; i++) signedSum += signed[i];
        \\print(signedSum);
        \\let calls = 0;
        \\Object.defineProperty(Array.prototype, "0", { get: function() { calls++; return 5; }, configurable: true });
        \\const hole = [, 2];
        \\let holeSum = 0;
        \\for (let i = 0; i < hole.length; i++) holeSum += hole[i];
        \\delete Array.prototype[0];
        \\print(calls, holeSum);
    , "499500\n-3\n1 7\n");
}

test "array named property simple set cache observes prototype changes" {
    try helpers.expectPrints(
        \\let first = [1];
        \\first.a = 1;
        \\print(first.a);
        \\let setterCount = 0;
        \\Object.defineProperty(Array.prototype, "a", {
        \\  set: function(v) { setterCount = v; },
        \\  configurable: true
        \\});
        \\let second = [2];
        \\second.a = 7;
        \\print(second.a);
        \\print(setterCount);
        \\delete Array.prototype.a;
        \\let third = [3];
        \\third.a = 9;
        \\print(third.a);
    , "1\nundefined\n7\n9\n");
}

test "Array.prototype.push fast path observes inherited indexed setter" {
    try helpers.expectPrints(
        \\let seen = 0;
        \\Object.defineProperty(Array.prototype, "2", {
        \\  set: function(v) { seen = v; },
        \\  configurable: true
        \\});
        \\let array = [1, 2];
        \\let result = array.push(3);
        \\print(seen);
        \\print(result);
        \\print(array.length);
        \\print(array[2]);
        \\print(Object.prototype.hasOwnProperty.call(array, "2"));
        \\delete Array.prototype[2];
    , "3\n3\n3\nundefined\nfalse\n");
}

test "array dense writers distinguish own Set holes and CreateDataProperty" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    function hasOwn(object, key) {
        \\        return Object.prototype.hasOwnProperty.call(object, key);
        \\    }
        \\    var payload = { marker: "payload" };
        \\    var owners = [Array.prototype, Object.prototype];
        \\    for (var ownerIndex = 0; ownerIndex < owners.length; ownerIndex++) {
        \\        var owner = owners[ownerIndex];
        \\        var seen;
        \\        Object.defineProperty(owner, "1", {
        \\            set: function (value) { seen = value; },
        \\            configurable: true
        \\        });
        \\        try {
        \\            var existing = [0, 1];
        \\            existing[1] = payload;
        \\            assert.sameValue(seen, undefined);
        \\            assert.sameValue(existing[1], payload);
        \\            assert.sameValue(hasOwn(existing, "1"), true);
        \\            var hole = new Array(2);
        \\            hole[1] = payload;
        \\            assert.sameValue(seen, payload);
        \\            assert.sameValue(hasOwn(hole, "1"), false);
        \\            assert.sameValue(hole.length, 2);
        \\            seen = undefined;
        \\            var defined = new Array(2);
        \\            Object.defineProperty(defined, "1", {
        \\                value: payload,
        \\                writable: true,
        \\                enumerable: true,
        \\                configurable: true
        \\            });
        \\            assert.sameValue(seen, undefined);
        \\            assert.sameValue(defined[1], payload);
        \\            assert.sameValue(hasOwn(defined, "1"), true);
        \\
        \\            var literal = [0, payload];
        \\            var constructed = new Array(0, payload);
        \\            var fromResult = Array.from([0, payload]);
        \\            var ofResult = Array.of(0, payload);
        \\            var mapped = [0, 1].map(function () { return payload; });
        \\            var created = [literal, constructed, fromResult, ofResult, mapped];
        \\            for (var createdIndex = 0; createdIndex < created.length; createdIndex++) {
        \\                assert.sameValue(created[createdIndex][1], payload);
        \\                assert.sameValue(hasOwn(created[createdIndex], "1"), true);
        \\            }
        \\            assert.sameValue(seen, undefined);
        \\        } finally {
        \\            delete owner[1];
        \\        }
        \\    }
        \\})();
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "push splice fill and unshift preserve prototype and payload semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    function hasOwn(object, key) {
        \\        return Object.prototype.hasOwnProperty.call(object, key);
        \\    }
        \\    function run(owner, payload) {
        \\        var seen;
        \\        Object.defineProperty(owner, "1", {
        \\            set: function (value) { seen = value; },
        \\            configurable: true
        \\        });
        \\        try {
        \\            var pushed = [10];
        \\            assert.sameValue(pushed.push(payload), 2);
        \\            assert.sameValue(seen, payload);
        \\            assert.sameValue(hasOwn(pushed, "1"), false);
        \\            assert.sameValue(pushed.length, 2);
        \\
        \\            seen = undefined;
        \\            var spliced = [10];
        \\            var removed = spliced.splice(1, 0, payload);
        \\            assert.sameValue(removed.length, 0);
        \\            assert.sameValue(seen, payload);
        \\            assert.sameValue(hasOwn(spliced, "1"), false);
        \\            assert.sameValue(spliced.length, 2);
        \\
        \\            seen = undefined;
        \\            var filled = new Array(2);
        \\            filled[0] = 10;
        \\            assert.sameValue(filled.fill(payload, 1, 2), filled);
        \\            assert.sameValue(seen, payload);
        \\            assert.sameValue(hasOwn(filled, "1"), false);
        \\            assert.sameValue(filled.length, 2);
        \\
        \\            seen = undefined;
        \\            var unshifted = [10];
        \\            assert.sameValue(unshifted.unshift(payload), 2);
        \\            assert.sameValue(seen, 10);
        \\            assert.sameValue(unshifted[0], payload);
        \\            assert.sameValue(hasOwn(unshifted, "1"), false);
        \\            assert.sameValue(unshifted.length, 2);
        \\        } finally {
        \\            delete owner[1];
        \\        }
        \\    }
        \\
        \\    var owners = [Array.prototype, Object.prototype];
        \\    var payloads = [{ marker: "object" }, Symbol("symbol payload")];
        \\    for (var ownerIndex = 0; ownerIndex < owners.length; ownerIndex++) {
        \\        for (var payloadIndex = 0; payloadIndex < payloads.length; payloadIndex++) {
        \\            run(owners[ownerIndex], payloads[payloadIndex]);
        \\        }
        \\    }
        \\})();
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "array indexed setter guards follow the receiver realm" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    function hasOwn(object, key) {
        \\        return Object.prototype.hasOwnProperty.call(object, key);
        \\    }
        \\    var other = $262.createRealm().global;
        \\    var payload = { marker: "cross-realm" };
        \\    var localSeen;
        \\    Object.defineProperty(Array.prototype, "1", {
        \\        set: function (value) { localSeen = value; },
        \\        configurable: true
        \\    });
        \\    try {
        \\        var foreignClean = other.eval("[10]");
        \\        assert.sameValue(other.Array.prototype.push.call(foreignClean, payload), 2);
        \\        assert.sameValue(localSeen, undefined);
        \\        assert.sameValue(foreignClean[1], payload);
        \\        assert.sameValue(hasOwn(foreignClean, "1"), true);
        \\
        \\        var localPolluted = [10];
        \\        assert.sameValue(other.Array.prototype.push.call(localPolluted, payload), 2);
        \\        assert.sameValue(localSeen, payload);
        \\        assert.sameValue(hasOwn(localPolluted, "1"), false);
        \\    } finally {
        \\        delete Array.prototype[1];
        \\    }
        \\
        \\    var foreignSeen;
        \\    other.Object.defineProperty(other.Object.prototype, "1", {
        \\        set: function (value) { foreignSeen = value; },
        \\        configurable: true
        \\    });
        \\    try {
        \\        var localClean = [10];
        \\        assert.sameValue(Array.prototype.push.call(localClean, payload), 2);
        \\        assert.sameValue(foreignSeen, undefined);
        \\        assert.sameValue(localClean[1], payload);
        \\        assert.sameValue(hasOwn(localClean, "1"), true);
        \\
        \\        var foreignPolluted = other.eval("[10]");
        \\        assert.sameValue(Array.prototype.push.call(foreignPolluted, payload), 2);
        \\        assert.sameValue(foreignSeen, payload);
        \\        assert.sameValue(hasOwn(foreignPolluted, "1"), false);
        \\    } finally {
        \\        delete other.Object.prototype[1];
        \\    }
        \\})();
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "array dense append guard distinguishes custom proxy and null prototypes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    function hasOwn(object, key) {
        \\        return Object.prototype.hasOwnProperty.call(object, key);
        \\    }
        \\    var customPayload = { marker: "custom" };
        \\    var customSeen;
        \\    var customPrototype = Object.create(Array.prototype);
        \\    Object.defineProperty(customPrototype, "1", {
        \\        set: function (value) { customSeen = value; },
        \\        configurable: true
        \\    });
        \\    var customArray = [10];
        \\    Object.setPrototypeOf(customArray, customPrototype);
        \\    assert.sameValue(Array.prototype.push.call(customArray, customPayload), 2);
        \\    assert.sameValue(customSeen, customPayload);
        \\    assert.sameValue(hasOwn(customArray, "1"), false);
        \\    var proxyPayload = Symbol("proxy payload");
        \\    var proxyKeys = [];
        \\    var proxySeen;
        \\    var proxyPrototype = new Proxy(Array.prototype, {
        \\        set: function (target, key, value, receiver) {
        \\            proxyKeys.push(String(key));
        \\            proxySeen = value;
        \\            return Reflect.set(target, key, value, receiver);
        \\        }
        \\    });
        \\    var proxyArray = [10];
        \\    Object.setPrototypeOf(proxyArray, proxyPrototype);
        \\    assert.sameValue(Array.prototype.push.call(proxyArray, proxyPayload), 2);
        \\    assert.sameValue(proxyKeys.join(","), "1");
        \\    assert.sameValue(proxySeen, proxyPayload);
        \\    assert.sameValue(proxyArray[1], proxyPayload);
        \\    assert.sameValue(hasOwn(proxyArray, "1"), true);
        \\    var nullPayload = { marker: "null" };
        \\    var nullArray = [10];
        \\    Object.setPrototypeOf(nullArray, null);
        \\    assert.sameValue(Array.prototype.push.call(nullArray, nullPayload), 2);
        \\    assert.sameValue(nullArray[1], nullPayload);
        \\    assert.sameValue(hasOwn(nullArray, "1"), true);
        \\})();
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "standard Array prototype guard publication and invalidation are realm local" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\globalThis.__arrayGuardOther = $262.createRealm().global;
        \\globalThis.__arrayGuardPrototypeMutation = $262.createRealm().global;
        \\globalThis.__arrayGuardFailedPrototypeMutation = $262.createRealm().global;
        \\globalThis.__arrayGuardOomMutation = $262.createRealm().global;
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const other_key = try js.runtime.internAtom("__arrayGuardOther");
    const other_value = try global.getProperty(other_key);
    const other_global = try core.Object.expect(other_value);
    const prototype_mutation_key = try js.runtime.internAtom("__arrayGuardPrototypeMutation");
    const prototype_mutation_value = try global.getProperty(prototype_mutation_key);
    const prototype_mutation_global = try core.Object.expect(prototype_mutation_value);
    const failed_prototype_mutation_key = try js.runtime.internAtom("__arrayGuardFailedPrototypeMutation");
    const failed_prototype_mutation_value = try global.getProperty(failed_prototype_mutation_key);
    const failed_prototype_mutation_global = try core.Object.expect(failed_prototype_mutation_value);
    const oom_mutation_key = try js.runtime.internAtom("__arrayGuardOomMutation");
    const oom_mutation_value = try global.getProperty(oom_mutation_key);
    const oom_mutation_global = try core.Object.expect(oom_mutation_value);

    const local_array_value = global.cachedRealmValue(js.runtime, .array_prototype) orelse return error.TestUnexpectedResult;
    const other_array_value = other_global.cachedRealmValue(js.runtime, .array_prototype) orelse return error.TestUnexpectedResult;
    const prototype_mutation_array_value = prototype_mutation_global.cachedRealmValue(js.runtime, .array_prototype) orelse return error.TestUnexpectedResult;
    const failed_prototype_mutation_array_value = failed_prototype_mutation_global.cachedRealmValue(js.runtime, .array_prototype) orelse return error.TestUnexpectedResult;
    const oom_mutation_array_value = oom_mutation_global.cachedRealmValue(js.runtime, .array_prototype) orelse return error.TestUnexpectedResult;
    const oom_mutation_object_value = oom_mutation_global.cachedRealmValue(js.runtime, .object_prototype) orelse return error.TestUnexpectedResult;
    const local_array = try core.Object.expect(local_array_value);
    const other_array = try core.Object.expect(other_array_value);
    const prototype_mutation_array = try core.Object.expect(prototype_mutation_array_value);
    const failed_prototype_mutation_array = try core.Object.expect(failed_prototype_mutation_array_value);
    const oom_mutation_array = try core.Object.expect(oom_mutation_array_value);
    const oom_mutation_object = try core.Object.expect(oom_mutation_object_value);
    try std.testing.expect(local_array.isStandardArrayPrototype());
    try std.testing.expect(other_array.isStandardArrayPrototype());
    try std.testing.expect(prototype_mutation_array.isStandardArrayPrototype());
    try std.testing.expect(failed_prototype_mutation_array.isStandardArrayPrototype());
    try std.testing.expect(oom_mutation_array.isStandardArrayPrototype());

    // Force the property mutation to allocate by sharing the current shape.
    // Guard invalidation must happen before that allocation and remain sticky
    // even though the indexed property itself is rolled back on OOM.
    const pinned_oom_shape = oom_mutation_object.shape_ref;
    pinned_oom_shape.markShared();
    const index_zero = core.Atom.taggedInt(0);
    // Injecting an allocation failure, not testing the collector: see
    // `suppressLimitCollectionForTest`.
    js.runtime.suppressLimitCollectionForTest(true);
    defer js.runtime.suppressLimitCollectionForTest(false);
    js.runtime.setMemoryLimit(js.runtime.memory.allocated_bytes);
    defer js.runtime.setMemoryLimit(null);
    try std.testing.expectError(
        error.OutOfMemory,
        oom_mutation_object.defineOwnProperty(
            js.runtime,
            index_zero,
            core.Descriptor.data(core.JSValue.int32(1), .all),
        ),
    );
    js.runtime.setMemoryLimit(null);
    try std.testing.expect(!oom_mutation_object.hasOwnProperty(index_zero));
    try std.testing.expect(!oom_mutation_array.isStandardArrayPrototype());
    try std.testing.expect(local_array.isStandardArrayPrototype());
    try std.testing.expect(other_array.isStandardArrayPrototype());

    // QuickJS's realm guard invalidation is deliberately narrower than the
    // full ArrayIndex grammar: only tagged integer atoms (0...INT32_MAX)
    // poison the marker. A high index string and a non-canonical numeric name
    // still update ordinary lookup summaries without disabling dense append.
    _ = try js.eval(
        \\__arrayGuardOther.Object.defineProperty(__arrayGuardOther.Object.prototype, "2147483648", { value: 1, configurable: true });
        \\delete __arrayGuardOther.Object.prototype["2147483648"];
        \\__arrayGuardOther.Object.defineProperty(__arrayGuardOther.Array.prototype, "2147483648", { value: 1, configurable: true });
        \\delete __arrayGuardOther.Array.prototype["2147483648"];
        \\__arrayGuardOther.Object.defineProperty(__arrayGuardOther.Object.prototype, "01", { value: 1, configurable: true });
        \\delete __arrayGuardOther.Object.prototype["01"];
        \\__arrayGuardOther.Object.defineProperty(__arrayGuardOther.Array.prototype, "named", { value: 1, configurable: true });
        \\delete __arrayGuardOther.Array.prototype.named;
        \\var __arrayGuardSymbol = __arrayGuardOther.Symbol("guard");
        \\__arrayGuardOther.Object.defineProperty(__arrayGuardOther.Array.prototype, __arrayGuardSymbol, { value: 1, configurable: true });
        \\delete __arrayGuardOther.Array.prototype[__arrayGuardSymbol];
    );
    try std.testing.expect(other_array.isStandardArrayPrototype());

    _ = try js.eval(
        \\Object.defineProperty(Array.prototype, "0", { value: 1, configurable: true });
        \\delete Array.prototype[0];
    );
    try std.testing.expect(!local_array.isStandardArrayPrototype());
    try std.testing.expect(other_array.isStandardArrayPrototype());
    try std.testing.expect(prototype_mutation_array.isStandardArrayPrototype());

    _ = try js.eval(
        \\__arrayGuardOther.eval("Object.defineProperty(Object.prototype, '0', { value: 2, configurable: true }); delete Object.prototype[0];");
    );
    try std.testing.expect(!local_array.isStandardArrayPrototype());
    try std.testing.expect(!other_array.isStandardArrayPrototype());
    try std.testing.expect(prototype_mutation_array.isStandardArrayPrototype());

    _ = try js.eval(
        \\__arrayGuardPrototypeMutation.Object.setPrototypeOf(
        \\    __arrayGuardPrototypeMutation.Array.prototype,
        \\    __arrayGuardPrototypeMutation.Object.getPrototypeOf(__arrayGuardPrototypeMutation.Array.prototype)
        \\);
    );
    try std.testing.expect(prototype_mutation_array.isStandardArrayPrototype());

    _ = try js.eval(
        \\__arrayGuardFailedPrototypeMutation.Object.preventExtensions(__arrayGuardFailedPrototypeMutation.Array.prototype);
        \\var __arrayGuardMutationRejected = false;
        \\try {
        \\    __arrayGuardFailedPrototypeMutation.Object.setPrototypeOf(__arrayGuardFailedPrototypeMutation.Array.prototype, null);
        \\} catch (error) {
        \\    __arrayGuardMutationRejected = error.name === "TypeError";
        \\}
        \\if (!__arrayGuardMutationRejected) throw new Error("expected cross-realm TypeError");
    );
    try std.testing.expect(failed_prototype_mutation_array.isStandardArrayPrototype());

    _ = try js.eval(
        \\__arrayGuardPrototypeMutation.Object.setPrototypeOf(__arrayGuardPrototypeMutation.Array.prototype, null);
    );
    try std.testing.expect(!prototype_mutation_array.isStandardArrayPrototype());
}

test "Array.prototype.push field2 fast path preserves observable guards" {
    try helpers.expectPrints(
        \\let fast = [];
        \\for (let i = 0; i < 8; i++) fast.push(i);
        \\print(fast.length, fast[0], fast[7]);
        \\print(eval("let completion=[]; for (let i=0; i<4; i++) completion.push(i);"));
        \\print(eval("let skipped=[]; for (let i=4; i<4; i++) skipped.push(i);"));
        \\let saved = Array.prototype.push;
        \\try {
        \\  let calls = 0;
        \\  Array.prototype.push = function(v) { calls++; return 123; };
        \\  let custom = [];
        \\  print(custom.push(9), custom.length, calls);
        \\  let customLoop = [];
        \\  for (let i = 0; i < 3; i++) customLoop.push(i);
        \\  print(customLoop.length, calls);
        \\} finally {
        \\  Array.prototype.push = saved;
        \\}
        \\let own = [];
        \\own.push = function(v) { return 77; };
        \\print(own.push(1), own.length);
        \\let locked = [];
        \\Object.defineProperty(locked, "length", { writable: false });
        \\try { locked.push(1); print("locked-ok"); } catch (e) { print(e instanceof TypeError, locked.length); }
        \\let lockedLoop = [];
        \\Object.defineProperty(lockedLoop, "length", { writable: false });
        \\try { for (let i = 0; i < 2; i++) lockedLoop.push(i); print("locked-loop-ok"); } catch (e) { print(e instanceof TypeError, lockedLoop.length); }
    , "8 0 7\n4\nundefined\n123 0 1\n0 4\n77 0\ntrue 0\ntrue 0\n");
}

test "RegExp literal test range fast path preserves observable guards" {
    try helpers.expectPrints(
        \\let c = 0;
        \\for (let i = 0; i < 8; i++) if (/a+b/.test("aaab")) c++;
        \\print(c);
        \\let miss = 0;
        \\for (let i = 0; i < 8; i++) if (/z+/.test("aaab")) miss++;
        \\print(miss);
        \\let saved = RegExp.prototype.test;
        \\try {
        \\  let calls = 0;
        \\  RegExp.prototype.test = function(s) { calls++; return false; };
        \\  let custom = 0;
        \\  for (let i = 0; i < 3; i++) if (/a+b/.test("aaab")) custom++;
        \\  print(custom, calls);
        \\} finally {
        \\  RegExp.prototype.test = saved;
        \\}
        \\let globalFlag = 0;
        \\for (let i = 0; i < 3; i++) if (/a/g.test("a")) globalFlag++;
        \\print(globalFlag);
    , "8\n0\n0 3\n3\n");
}

test "sparse array literal fast paths preserve holes and length semantics" {
    try helpers.expectPrints(
        \\"use strict";
        \\let a = [1, , 3];
        \\print(a.length, 0 in a, 1 in a, 2 in a, a[1] === undefined);
        \\let b = [, ,];
        \\print(b.length, 0 in b, 1 in b);
        \\let c = [1];
        \\Object.defineProperty(c, "0", { configurable: false });
        \\try { c.length = 0; print("shrink-ok"); } catch (e) { print("shrink-err"); }
        \\print(c.length, c[0]);
        \\c.length = 2;
        \\print(c.length, c[0]);
        \\let calls = 0;
        \\function sideEffect() { calls++; return 3; }
        \\let sum = 0;
        \\for (let i = 0; i < 4; i++) { const d = [1, , sideEffect()]; sum += d.length; }
        \\print(sum, calls);
    , "3 true false true true\n2 false false\nshrink-err\n1 1\n2 1\n12 4\n");
}

test "sparse array literal length add range fast path collapses loop opcodes" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var profile = core.OpcodeProfile{};
    js.runtime.setOpcodeProfile(&profile);
    defer js.runtime.setOpcodeProfile(null);

    // The opcode-shape assertions below do not depend on the trip count.
    // Under ZJS_GC_STRESS every safepoint collects, and 50 000 trips made this
    // the slowest test of the gc-stress run (46 s on its shard); a tenth of
    // the count exercises the same path.
    const iterations: usize = if (core.gc.stress_collect) 5_000 else 50_000;
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\let s = 0;
        \\for (let i = 0; i < {d}; i++) {{ const a = [1, , 3]; s += a.length; }}
        \\print(s);
    , .{iterations});
    defer std.testing.allocator.free(source);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{d}\n", .{iterations * 3});
    defer std.testing.allocator.free(expected);

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(source, &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings(expected, stream.buffered());
    try std.testing.expect(profile.totalOpcodeCount() <= 20);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.array_from]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.define_field]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.get_length]);
    try std.testing.expectEqual(@as(u64, 0), profile.count[op.add]);
}

test "collection constructors iterate their array argument, not index it" {
    // new Set/Map/WeakSet/WeakMap took a dense indexed read whenever the
    // argument was an Array, keyed on isArray() alone. So an array carrying
    // its own @@iterator, or a patched %ArrayIteratorPrototype%.next, was
    // silently indexed — while spread, for-of, Array.from, destructuring and
    // yield* in the SAME process honoured it. The dense read now happens only
    // behind the guard that spread already used.
    // A dedicated engine, not the shared one: draining a generator-backed
    // iterable into a collection on the process-lifetime engine trips a
    // pre-existing use-after-free in a LATER test (STATUS.md, "Known
    // defects"). That defect is independent of what this test covers.
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const a = [1, 2, 3];
        \\a[Symbol.iterator] = function* () { yield 9; yield 8; };
        \\print(JSON.stringify([...new Set(a)]));
        \\const pairs = [[1, "a"]];
        \\pairs[Symbol.iterator] = function* () { yield [7, "z"]; };
        \\print(JSON.stringify([...new Map(pairs)]));
        \\const AIP = Object.getPrototypeOf([].values());
        \\const saved = AIP.next;
        \\let n = 0;
        \\AIP.next = function () { return n++ < 2 ? { done: false, value: 100 + n } : { done: true }; };
        \\const patched = JSON.stringify([...new Set([1, 2, 3])]);
        \\AIP.next = saved;
        \\print(patched);
        \\print(JSON.stringify([...new Set([1, 2, 2, 3])]), JSON.stringify([...new Set([1, , 3])]));
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings(
        \\[9,8]
        \\[[7,"z"]]
        \\[101,102]
        \\[1,2,3] [1,null,3]
        \\
    , stream.buffered());
}

test "collection constructors do not bulk fill past an overridable adder" {
    // The dense bulk fill for `new Set(array)` calls the adder once per element
    // but advances the iterator's cursor only once, at the end, and skips
    // IteratorClose when an adder throws. Both are observable as soon as the
    // adder is user code: a subclass `add` that peeks at the iterator saw a
    // cursor still at 0 (`peek 1` instead of `peek 2`, and every element rather
    // than every other one), and a subclass `add` that throws let the error
    // escape without running the iterator's `return`. The guard now also
    // requires the adder to be the builtin, which is what makes a whole batch
    // unobservable; QuickJS agrees line for line with the expectation below.
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const it = [1, 2, 3][Symbol.iterator]();
        \\let peeked = null;
        \\const seen = [];
        \\class Peeker extends Set {
        \\  add(v) {
        \\    seen.push(v);
        \\    if (peeked === null) peeked = it.next().value;
        \\    return super.add(v);
        \\  }
        \\}
        \\new Peeker(it);
        \\print(peeked, JSON.stringify(seen));
        \\let closed = 0;
        \\const it2 = [1, 2, 3][Symbol.iterator]();
        \\it2.return = function () { closed++; return { done: true }; };
        \\class Thrower extends Set { add() { throw new Error("boom"); } }
        \\try { new Thrower(it2); } catch (e) {}
        \\print(closed);
        \\print(JSON.stringify([...new Set([1, 2, 3])]));
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings(
        \\2 [1,3]
        \\1
        \\[1,2,3]
        \\
    , stream.buffered());
}

test "builtin iterator prototypes survive replacing globalThis.Iterator" {
    // %IteratorPrototype% is a realm intrinsic. It used to be resolved by
    // walking the writable `globalThis.Iterator` binding and reading
    // `.prototype`, so the first thing every Iterator-Helpers polyfill does --
    // assign that binding -- detached every lazily-built builtin iterator
    // prototype from it. `[...map.entries()]` threw TypeError and
    // `Array.from(str.matchAll(re))` silently returned []. Deleting the
    // binding was worse: two copies of the resolver invented two DIFFERENT
    // synthetic bases, so Map and Array iterators stopped sharing one.

    try helpers.expectPrints(
        \\const saved = globalThis.Iterator;
        \\const grandparent = (it) => Object.getPrototypeOf(Object.getPrototypeOf(it));
        \\globalThis.Iterator = { prototype: { FAKE: 1 } };
        \\print(JSON.stringify([...new Map([[1, 2]]).entries()]));
        \\print(JSON.stringify([...new Set([1]).values()]), JSON.stringify([...[3, 4].values()]));
        \\print(JSON.stringify([...("ab")[Symbol.iterator]()]), Array.from("a".matchAll(/a/g)).length);
        \\print(grandparent(new Map().entries()) === grandparent([1].values()));
        \\delete globalThis.Iterator;
        \\print(JSON.stringify([...new Map([[5, 6]]).entries()]), JSON.stringify([...[9].values()]));
        \\print(grandparent(new Set().values()) === grandparent("x"[Symbol.iterator]()));
        \\globalThis.Iterator = saved;
    ,
        \\[[1,2]]
        \\[1] [3,4]
        \\["a","b"] 1
        \\true
        \\[[5,6]] [9]
        \\true
        \\
    );
}

test "Array.of and Array.from run a Proxy constructor's construct trap" {
    // IsConstructor(C) had two implementations in the tree. The one the
    // Array.of / Array.from / Array.fromAsync / %TypedArray% static entries
    // used fell off its last branch with `class_id == c_closure`, so every
    // Proxy answered false: the trap never fired and a plain Array was
    // fabricated instead of the constructor's result. They now share the one
    // implementation that has a Proxy arm.

    try helpers.expectPrints(
        \\function probe(run) {
        \\  let hits = 0;
        \\  const P = new Proxy(function C() { this.tag = "t"; }, {
        \\    construct(t, a, nt) { hits++; return Reflect.construct(t, a, nt); }
        \\  });
        \\  const r = run(P);
        \\  return hits + ":" + r.tag + ":" + r.length;
        \\}
        \\print(probe((P) => Array.of.call(P, 1, 2)));
        \\print(probe((P) => Array.from.call(P, [7, 8])));
        \\print(Array.of.call(new Proxy(Array, {}), 1).length);
        \\print(Array.of.call(new Proxy(() => {}, {}), 1) instanceof Array);
    , "1:t:2\n1:t:2\n1\ntrue\n");
}

test "array for-of fast path preserves iterator observability" {
    try helpers.expectPrints(
        \\let s = 0;
        \\for (let x of [1, 2, 3]) s += x;
        \\print(s);
        \\let a = [1, , 3];
        \\Object.prototype[1] = 9;
        \\let inherited = 0;
        \\for (let x of a) inherited += x;
        \\delete Object.prototype[1];
        \\print(inherited);
        \\let calls = 0;
        \\const proto = Object.getPrototypeOf([][Symbol.iterator]());
        \\const saved = proto.next;
        \\proto.next = function() { calls++; return saved.call(this); };
        \\let patched = 0;
        \\for (let x of [4, 5]) patched += x;
        \\proto.next = saved;
        \\print(patched, calls);
        \\let keys = "";
        \\for (let k of [10, 20].keys()) keys += k;
        \\print(keys);
    , "6\n13\n9 3\n01\n");
}

test "dense array indexed append range preserves ordinary set guards" {
    try helpers.expectPrints(
        \\let fast = [];
        \\for (let i = 0; i < 8; i++) fast[i] = i;
        \\let sum = 0;
        \\for (let i = 0; i < fast.length; i++) sum += fast[i];
        \\print(fast.length, sum, fast[7]);
        \\print(eval("let completionArray=[]; for (let i=0; i<4; i++) completionArray[i]=i;"));
        \\print(eval("let skippedArray=[]; for (let i=4; i<4; i++) skippedArray[i]=i;"));
        \\print(eval("let contentArray=[]; for (let i=0; i<4; i++) contentArray[i]=i; contentArray.join(',');"));
        \\let masked = [];
        \\let maskedSum = 0;
        \\for (let i = 0; i < 8; i++) masked[i] = (i * 7) & 255;
        \\for (let i = 0; i < masked.length; i++) maskedSum += masked[i];
        \\print(masked.length, masked[0], masked[7], maskedSum);
        \\function varMasked() {
        \\  var values = [];
        \\  for (var i = 0; i < 8; i++) values[i] = (i * 7) & 255;
        \\  return values.length + ":" + values[0] + ":" + values[7];
        \\}
        \\print(varMasked());
        \\let seen = "";
        \\Object.defineProperty(Array.prototype, "0", {
        \\  set: function(v) { seen += v + ":"; },
        \\  get: function() { return 99; },
        \\  configurable: true
        \\});
        \\let guarded = [];
        \\for (let i = 0; i < 2; i++) guarded[i] = i;
        \\print(seen);
        \\print(guarded.length);
        \\print(guarded[0]);
        \\print(Object.prototype.hasOwnProperty.call(guarded, "0"));
        \\let maskedGuarded = [];
        \\for (let i = 0; i < 2; i++) maskedGuarded[i] = (i * 7) & 255;
        \\print(seen);
        \\print(maskedGuarded.length);
        \\print(maskedGuarded[0]);
        \\print(Object.prototype.hasOwnProperty.call(maskedGuarded, "0"));
        \\print(maskedGuarded[1]);
        \\function varMaskedGuarded() {
        \\  var values = [];
        \\  for (var i = 0; i < 2; i++) values[i] = (i * 7) & 255;
        \\  print(seen);
        \\  print(values.length);
        \\  print(values[0]);
        \\  print(Object.prototype.hasOwnProperty.call(values, "0"));
        \\  print(values[1]);
        \\}
        \\varMaskedGuarded();
        \\let overwrite = [0,1,2,3,4,5,6,7];
        \\for (let i = 0; i < 1000; i++) overwrite[i & 7] = i;
        \\print(overwrite[0], overwrite[7], overwrite.join(","));
        \\print(eval("let overwriteEval=[0,1,2,3,4,5,6,7]; for (let i=0; i<10; i++) overwriteEval[i&7]=i;"));
        \\let guardedOverwrite = [,1,2,3,4,5,6,7];
        \\for (let i = 0; i < 8; i++) guardedOverwrite[i & 7] = i;
        \\print(seen);
        \\print(guardedOverwrite.length);
        \\print(guardedOverwrite[0]);
        \\print(Object.prototype.hasOwnProperty.call(guardedOverwrite, "0"));
        \\print(guardedOverwrite[7]);
        \\delete Array.prototype[0];
    , "8 28 7\n3\nundefined\n0,1,2,3\n8 0 49 196\n8:0:49\n0:\n2\n99\nfalse\n0:0:\n2\n99\nfalse\n7\n0:0:0:\n2\n99\nfalse\n7\n992 999 992,993,994,995,996,997,998,999\n9\n0:0:0:0:\n8\n99\nfalse\n7\n");
}

test "array map simple callback range preserves closed induction and completion" {
    try helpers.expectPrints(
        \\const a = [1,2,3,4,5,6,7,8,9,10];
        \\let out;
        \\for (let i = 0; i < 100; i++) out = a.map(x => x + 1);
        \\print(out.length, out[0], out[9]);
        \\print(eval("const e=[1,2]; let r; for (let j=0; j<4; j++) r=e.map(x=>x+1);"));
        \\print(eval("const s=[1,2]; let r; for (let k=4; k<4; k++) r=s.map(x=>x+1);"));
    , "10 2 11\n[ 2, 3 ]\nundefined\n");
}

test "global var induction add range preserves completion" {
    try helpers.expectPrints(
        \\var sum = 0;
        \\for (var i = 0; i < 1000; i++) sum += i;
        \\print(sum, i);
        \\print(eval("var evalSum=0; for (var j=0; j<4; j++) evalSum += j;"));
        \\print(eval("var skippedSum=0; for (var k=4; k<4; k++) skippedSum += k;"));
    , "499500 1000\n6\nundefined\n");
}

test "global write induction range preserves strict writable semantics" {
    try helpers.expectPrints(
        \\"use strict";
        \\var g = -1;
        \\for (let i = 0; i < 1000; i++) g = i;
        \\print(g);
        \\var skipped = 7;
        \\for (let j = 5; j < 5; j++) skipped = j;
        \\print(skipped);
        \\Object.defineProperty(globalThis, "roGlobalLoop", { value: 1, writable: false, configurable: true });
        \\try {
        \\  for (let k = 0; k < 3; k++) roGlobalLoop = k;
        \\} catch (e) {
        \\  print(e.name, roGlobalLoop);
        \\}
        \\delete globalThis.roGlobalLoop;
        \\print(eval("var eg = -1; for (let i = 0; i < 4; i++) eg = i;"));
        \\print(eval("var eg2 = -1; for (let j = 4; j < 4; j++) eg2 = j;"));
    , "999\n7\nTypeError 1\n3\nundefined\n");
}

test "short BigInt induction add range preserves completion" {
    try helpers.expectPrints(
        \\let x = 0n;
        \\for (let i = 0n; i < 4n; i++) x += i;
        \\print(x);
        \\print(eval("let y=0n; for (let j=0n; j<4n; j++) y += j;"));
        \\print(eval("let z=0n; for (let k=4n; k<4n; k++) z += k;"));
    , "6n\n6n\nundefined\n");
}

const EscapedEvalImportHost = struct {
    expected_referrer: []const u8,
    saw_expected_referrer: bool = false,
};

fn escapedEvalImportResolve(
    ptr: *anyopaque,
    specifier: []const u8,
    referrer: ?[]const u8,
    allocator: std.mem.Allocator,
) anyerror!helpers.TestEngine.HostHooks.ResolvedModule {
    const host: *EscapedEvalImportHost = @ptrCast(@alignCast(ptr));
    const dep_path = "/fixture/scripts/dep.js";
    if (std.mem.eql(u8, specifier, "./dep.js")) {
        host.saw_expected_referrer = if (referrer) |path|
            std.mem.eql(u8, path, host.expected_referrer)
        else
            false;
    } else if (!std.mem.eql(u8, specifier, dep_path)) {
        return error.ModuleNotFound;
    }
    return .{
        .specifier = try allocator.dupe(u8, specifier),
        .path = try allocator.dupe(u8, dep_path),
        .kind = .esm,
    };
}

fn escapedEvalImportLoad(
    _: *anyopaque,
    resolved: helpers.TestEngine.HostHooks.ResolvedModule,
    allocator: std.mem.Allocator,
) anyerror!helpers.TestEngine.HostHooks.LoadedModule {
    const dep_path = "/fixture/scripts/dep.js";
    if (!std.mem.eql(u8, resolved.path, dep_path)) return error.ModuleNotFound;
    return .{
        .source = "export const answer = 42;",
        .path = try allocator.dupe(u8, dep_path),
        .kind = .esm,
        .owned = false,
    };
}

test "escaped direct eval function keeps script referrer for dynamic import" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const root_path = "/fixture/scripts/main.mjs";
    var host = EscapedEvalImportHost{ .expected_referrer = root_path };
    const hooks = helpers.TestEngine.HostHooks{
        .ptr = &host,
        .resolveModule = escapedEvalImportResolve,
        .loadModule = escapedEvalImportLoad,
    };

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithHostHooks(
        \\var escaped;
        \\function createLoader() {
        \\  escaped = eval("eval(\"(function load(){ return import('./dep.js'); })\")");
        \\}
        \\createLoader();
        \\escaped().then(
        \\  function(namespace) { print(namespace.answer); },
        \\  function(error) { print(error.name); }
        \\);
    ,
        &stream,
        root_path,
        hooks,
        std.testing.allocator,
    );

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expect(host.saw_expected_referrer);
    try std.testing.expectEqualStrings("42\n", stream.buffered());
}

test "escaped direct eval function keeps eval stack filename" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [1]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileWithOutputMode(
        \\function createThrower() {
        \\  return eval("(function evalThrower(){ throw new Error('boom'); })");
        \\}
        \\var escaped = createThrower();
        \\var stack;
        \\try { escaped(); } catch (error) { stack = error.stack; }
        \\assert.sameValue(typeof stack, "string");
        \\assert.sameValue(stack.indexOf("<eval>") >= 0, true);
    ,
        &stream,
        .script,
        "/fixture/scripts/original.js",
    );

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("", stream.buffered());
}

test "direct and indirect eval regexp literals share the generic parser semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function checkPair(exact, terminated) {
        \\  assert.sameValue(exact.source, terminated.source);
        \\  assert.sameValue(exact.flags, terminated.flags);
        \\  assert.sameValue(exact !== terminated, true);
        \\  assert.sameValue(Object.getPrototypeOf(exact), Object.getPrototypeOf(terminated));
        \\}
        \\checkPair(eval("/a/gi"), eval("/a/gi;"));
        \\const indirect = (0, eval);
        \\checkPair(indirect("/b/m"), indirect("/b/m;"));
        \\for (const source of ["/(/", "/(/;"]) {
        \\  let syntax = false;
        \\  try { eval(source); } catch (error) { syntax = error instanceof SyntaxError; }
        \\  assert.sameValue(syntax, true);
        \\}
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "direct eval expression completion does not depend on a source terminator" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function probe() {
        \\  assert.sameValue(eval('"value"'), eval('"value";'));
        \\  assert.sameValue(eval("this"), eval("this;"));
        \\}
        \\probe.call({ marker: 1 });
        \\const sloppy = (function named() {
        \\  const exact = eval("named = 0");
        \\  const terminated = eval("named = 0;");
        \\  return [exact, terminated, typeof named];
        \\})();
        \\assert.sameValue(sloppy[0], 0);
        \\assert.sameValue(sloppy[1], 0);
        \\assert.sameValue(sloppy[2], "function");
        \\for (const source of ["named = 0", "named = 0;"]) {
        \\  let typeError = false;
        \\  try { (function named() { "use strict"; eval(source); })(); }
        \\  catch (error) { typeError = error instanceof TypeError; }
        \\  assert.sameValue(typeError, true);
        \\}
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "test262 frontmatter comments do not change engine strict mode" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [8]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\/*---
        \\flags: [onlyStrict]
        \\---*/
        \\function acceptsEval(eval) { return eval; }
        \\print(acceptsEval(1));
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("1\n", stream.buffered());
}

test "Engine function global data IC preserves binding guards" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\globalThis.__zjsGlobalDataIcRead = 1;
        \\function __zjsGlobalDataIcReadFn() { return __zjsGlobalDataIcRead; }
        \\assert.sameValue(__zjsGlobalDataIcReadFn(), 1);
        \\assert.sameValue(__zjsGlobalDataIcReadFn(), 1);
        \\globalThis.__zjsGlobalDataIcRead = 7;
        \\assert.sameValue(__zjsGlobalDataIcReadFn(), 7);
        \\
        \\globalThis.__zjsGlobalDataIcAccessor = 1;
        \\function __zjsGlobalDataIcAccessorFn() { return __zjsGlobalDataIcAccessor; }
        \\assert.sameValue(__zjsGlobalDataIcAccessorFn(), 1);
        \\assert.sameValue(__zjsGlobalDataIcAccessorFn(), 1);
        \\var __zjsGlobalDataIcAccessorCalls = 0;
        \\Object.defineProperty(globalThis, "__zjsGlobalDataIcAccessor", {
        \\    get: function() { __zjsGlobalDataIcAccessorCalls++; return 42; },
        \\    configurable: true
        \\});
        \\assert.sameValue(__zjsGlobalDataIcAccessorFn(), 42);
        \\assert.sameValue(__zjsGlobalDataIcAccessorCalls, 1);
        \\delete globalThis.__zjsGlobalDataIcAccessor;
        \\
        \\let __zjsGlobalDataIcLexical = 3;
        \\globalThis.__zjsGlobalDataIcLexical = 1;
        \\function __zjsGlobalDataIcLexicalFn() { return __zjsGlobalDataIcLexical; }
        \\assert.sameValue(__zjsGlobalDataIcLexicalFn(), 3);
        \\assert.sameValue(globalThis.__zjsGlobalDataIcLexical, 1);
        \\delete globalThis.__zjsGlobalDataIcLexical;
        \\
        \\globalThis.__zjsGlobalDataIcSelf = 5;
        \\var __zjsGlobalDataIcSelfRef = function __zjsGlobalDataIcSelf() {
        \\    return __zjsGlobalDataIcSelf === __zjsGlobalDataIcSelfRef;
        \\};
        \\assert.sameValue(__zjsGlobalDataIcSelfRef(), true);
        \\assert.sameValue(globalThis.__zjsGlobalDataIcSelf, 5);
        \\delete globalThis.__zjsGlobalDataIcSelf;
        \\
        \\globalThis.__zjsGlobalDataIcEval = 1;
        \\function __zjsGlobalDataIcEvalFn() {
        \\    assert.sameValue(__zjsGlobalDataIcEval, 1);
        \\    assert.sameValue(__zjsGlobalDataIcEval, 1);
        \\    eval('var __zjsGlobalDataIcEval = 9;');
        \\    __zjsGlobalDataIcEval = 10;
        \\    return __zjsGlobalDataIcEval;
        \\}
        \\assert.sameValue(__zjsGlobalDataIcEvalFn(), 10);
        \\assert.sameValue(globalThis.__zjsGlobalDataIcEval, 1);
        \\delete globalThis.__zjsGlobalDataIcEval;
        \\
        \\globalThis.__zjsGlobalDataIcRedefine = 10;
        \\function __zjsGlobalDataIcRedefineFn() { return __zjsGlobalDataIcRedefine; }
        \\assert.sameValue(__zjsGlobalDataIcRedefineFn(), 10);
        \\assert.sameValue(__zjsGlobalDataIcRedefineFn(), 10);
        \\assert.sameValue(delete globalThis.__zjsGlobalDataIcRedefine, true);
        \\globalThis.__zjsGlobalDataIcRedefine = 22;
        \\assert.sameValue(__zjsGlobalDataIcRedefineFn(), 22);
        \\delete globalThis.__zjsGlobalDataIcRedefine;
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Engine global function declarations publish through construction-time VarRef cells" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\(0, eval)('Object.defineProperty(globalThis, "__qjsFunctionData", { value: 1, writable: false, enumerable: false, configurable: true })');
        \\(0, eval)('function __qjsFunctionData(){ return 11; }');
        \\var dataDesc = Object.getOwnPropertyDescriptor(globalThis, "__qjsFunctionData");
        \\assert.sameValue(__qjsFunctionData(), 11);
        \\assert.sameValue(dataDesc.writable, true);
        \\assert.sameValue(dataDesc.enumerable, true);
        \\assert.sameValue(dataDesc.configurable, true);
        \\(0, eval)('Object.defineProperty(globalThis, "__qjsFunctionAccessor", { get: function(){ return 1; }, configurable: true })');
        \\(0, eval)('function __qjsFunctionAccessor(){ return 12; }');
        \\var accessorDesc = Object.getOwnPropertyDescriptor(globalThis, "__qjsFunctionAccessor");
        \\assert.sameValue(__qjsFunctionAccessor(), 12);
        \\assert.sameValue(accessorDesc.writable, true);
        \\assert.sameValue(accessorDesc.enumerable, true);
        \\assert.sameValue(accessorDesc.configurable, true);
        \\(0, eval)('Object.defineProperty(globalThis, "__qjsFunctionFixed", { value: 1, writable: true, enumerable: true, configurable: false })');
        \\(0, eval)('function __qjsFunctionFixed(){ return 13; }');
        \\var fixedDesc = Object.getOwnPropertyDescriptor(globalThis, "__qjsFunctionFixed");
        \\assert.sameValue(__qjsFunctionFixed(), 13);
        \\assert.sameValue(fixedDesc.writable, true);
        \\assert.sameValue(fixedDesc.enumerable, true);
        \\assert.sameValue(fixedDesc.configurable, false);
    );

    _ = try js.eval(
        \\Object.defineProperty(globalThis, "__qjsScriptFunction", { value: 1, writable: false, enumerable: false, configurable: true });
    );
    _ = try js.eval(
        \\function __qjsScriptFunction(){ return 14; }
        \\var scriptDesc = Object.getOwnPropertyDescriptor(globalThis, "__qjsScriptFunction");
        \\assert.sameValue(__qjsScriptFunction(), 14);
        \\assert.sameValue(scriptDesc.writable, true);
        \\assert.sameValue(scriptDesc.enumerable, true);
        \\assert.sameValue(scriptDesc.configurable, false);
    );
}

test "cross-realm construction uses class prototype state without observable realm keys" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var R = $262.createRealm().global;
        \\    function realmKeys(value) {
        \\        return Object.getOwnPropertyNames(value).filter(function (name) {
        \\            return name.indexOf("__realm_") === 0;
        \\        });
        \\    }
        \\    var f = R.Function("return Object");
        \\    assert.sameValue(f(), R.Object);
        \\    assert.sameValue(Object.getPrototypeOf(f), R.Function.prototype);
        \\    assert.sameValue(realmKeys(R.Function).length, 0);
        \\    assert.sameValue(realmKeys(f).length, 0);
        \\    assert.sameValue(Object.keys(R.Function).filter(function (name) {
        \\        return name.indexOf("__realm_") === 0;
        \\    }).length, 0);
        \\    assert.sameValue(Object.keys(f).filter(function (name) {
        \\        return name.indexOf("__realm_") === 0;
        \\    }).length, 0);
        \\    var fakePrototype = {};
        \\    Object.defineProperty(R.Function, "__realm_Object_proto", {
        \\        value: fakePrototype,
        \\        writable: true,
        \\        enumerable: true,
        \\        configurable: true,
        \\    });
        \\    var copied = R.Function("return 1");
        \\    assert.sameValue(Object.prototype.hasOwnProperty.call(copied, "__realm_Object_proto"), false);
        \\    var gets = 0;
        \\    var newTarget = new Proxy(copied, {
        \\        get: function (target, key) {
        \\            gets++;
        \\            if (key === "prototype") return 0;
        \\            return target[key];
        \\        },
        \\    });
        \\    var value = Reflect.construct(Object, [], newTarget);
        \\    assert.sameValue(gets, 1);
        \\    assert.sameValue(Object.getPrototypeOf(value), R.Object.prototype);
        \\    assert.notSameValue(Object.getPrototypeOf(value), fakePrototype);
        \\    assert.sameValue(R.Function.__realm_Object_proto, fakePrototype);
        \\})();
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "Object RegExp and TypedArray use their C function Realm state" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var R = $262.createRealm().global;
        \\    assert.sameValue(Object.getPrototypeOf(R.Object("x")), R.String.prototype);
        \\    assert.sameValue(Object.getPrototypeOf(R.Object(1)), R.Number.prototype);
        \\    assert.sameValue(Object.getPrototypeOf(R.Object(true)), R.Boolean.prototype);
        \\    assert.sameValue(Object.getPrototypeOf(R.Object(1n)), R.BigInt.prototype);
        \\    var remoteSymbol = R.Symbol("remote");
        \\    assert.sameValue(Object.getPrototypeOf(R.Object(remoteSymbol)), R.Symbol.prototype);
        \\
        \\    var originalTypeErrorPrototype = R.TypeError.prototype;
        \\    var sourceGetter = Object.getOwnPropertyDescriptor(R.RegExp.prototype, "source").get;
        \\    R.TypeError = function ReplacementTypeError() {};
        \\    var regexpError;
        \\    try { sourceGetter.call({}); } catch (error) { regexpError = error; }
        \\    assert.sameValue(Object.getPrototypeOf(regexpError), originalTypeErrorPrototype);
        \\    assert.notSameValue(Object.getPrototypeOf(regexpError), TypeError.prototype);
        \\
        \\    function NewTarget() {}
        \\    NewTarget.prototype = { marker: "result" };
        \\    var typed = Reflect.construct(R.Uint8Array, [4], NewTarget);
        \\    var bufferGetter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(R.Uint8Array.prototype), "buffer").get;
        \\    var backing = bufferGetter.call(typed);
        \\    assert.sameValue(Object.getPrototypeOf(typed), NewTarget.prototype);
        \\    assert.sameValue(Object.getPrototypeOf(backing), R.ArrayBuffer.prototype);
        \\    assert.notSameValue(Object.getPrototypeOf(backing), ArrayBuffer.prototype);
        \\})();
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "native builtin records use callee realm for errors and created objects" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var other = $262.createRealm().global;
        \\    var obj = {};
        \\    var wrapped = other.Object.create(obj);
        \\    assert.throws(TypeError, function () {
        \\        Object.setPrototypeOf(obj, wrapped);
        \\    });
        \\    assert.throws(other.TypeError, function () {
        \\        other.Object.setPrototypeOf(obj, wrapped);
        \\    });
        \\    var keys = other.Object.keys({ a: 1 });
        \\    assert.sameValue(Object.getPrototypeOf(keys), other.Array.prototype);
        \\})();
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "collection callback adapter materializes errors in its explicit realm" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const caller = try core.JSContext.create(rt);
    defer caller.destroy();
    const caller_global = try engine.exec.zjs_vm.contextGlobal(caller);
    const callback_realm = try core.JSContext.create(rt);
    defer callback_realm.destroy();
    const callback_global = try engine.exec.zjs_vm.contextGlobal(callback_realm);

    const callback = try engine.exec.closure.create(rt, .throws_type_error);

    const callback_host = engine.exec.collection_adapter.host(callback_realm, &.{});
    try std.testing.expectError(
        error.JSException,
        callback_host.callWithThis(callback, core.JSValue.undefinedValue(), &.{}),
    );
    try std.testing.expect(callback_realm.hasException());

    const error_value = callback_realm.takeException();
    const error_object = try core.Object.expect(error_value);
    const caller_type_error = engine.exec.object_ops.constructorPrototypeFromGlobal(rt, caller_global, "TypeError") orelse
        return error.TestUnexpectedResult;
    const callback_type_error = engine.exec.object_ops.constructorPrototypeFromGlobal(rt, callback_global, "TypeError") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(callback_type_error, error_object.getPrototype().?);
    try std.testing.expect(caller_type_error != callback_type_error);
}

test "constructor static prototype and accessor handlers keep their callee realm" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var other = $262.createRealm().global;
        \\    try {
        \\        new other.Array(1.5);
        \\        throw new Test262Error("expected foreign Array constructor to throw");
        \\    } catch (error) {
        \\        assert.sameValue(Object.getPrototypeOf(error), other.RangeError.prototype);
        \\        assert.sameValue(error instanceof RangeError, false);
        \\    }
        \\    var parse = other.JSON.parse;
        \\    try {
        \\        parse("{");
        \\        throw new Test262Error("expected foreign JSON.parse to throw");
        \\    } catch (error) {
        \\        assert.sameValue(Object.getPrototypeOf(error), other.SyntaxError.prototype);
        \\        assert.sameValue(error instanceof SyntaxError, false);
        \\    }
        \\    var promise = other.Promise.resolve(1);
        \\    assert.sameValue(Object.getPrototypeOf(promise), other.Promise.prototype);
        \\    var capability = other.Promise.withResolvers();
        \\    assert.sameValue(Object.getPrototypeOf(capability.resolve), other.Function.prototype);
        \\    assert.sameValue(Object.getPrototypeOf(capability.reject), other.Function.prototype);
        \\    try {
        \\        other.Reflect.get(null, "x");
        \\        throw new Test262Error("expected foreign Reflect.get to throw");
        \\    } catch (error) {
        \\        assert.sameValue(Object.getPrototypeOf(error), other.TypeError.prototype);
        \\        assert.sameValue(error instanceof TypeError, false);
        \\    }
        \\    var toFixed = other.Number.prototype.toFixed;
        \\    try {
        \\        toFixed.call(1, -1);
        \\        throw new Test262Error("expected foreign Number.prototype.toFixed to throw");
        \\    } catch (error) {
        \\        assert.sameValue(Object.getPrototypeOf(error), other.RangeError.prototype);
        \\        assert.sameValue(error instanceof RangeError, false);
        \\    }
        \\    var toUpperCase = other.String.prototype.toUpperCase;
        \\    try {
        \\        toUpperCase.call(null);
        \\        throw new Test262Error("expected foreign String.prototype.toUpperCase to throw");
        \\    } catch (error) {
        \\        assert.sameValue(Object.getPrototypeOf(error), other.TypeError.prototype);
        \\        assert.sameValue(error instanceof TypeError, false);
        \\    }
        \\    var sourceGetter = Object.getOwnPropertyDescriptor(other.RegExp.prototype, "source").get;
        \\    try {
        \\        sourceGetter.call({});
        \\        throw new Test262Error("expected foreign RegExp source getter to throw");
        \\    } catch (error) {
        \\        assert.sameValue(Object.getPrototypeOf(error), other.TypeError.prototype);
        \\        assert.sameValue(error instanceof TypeError, false);
        \\    }
        \\    var iterator = other.eval("[1].values()");
        \\    var iteratorPrototype = other.eval("Object.getPrototypeOf([].values())");
        \\    assert.sameValue(Object.getPrototypeOf(iterator), iteratorPrototype);
        \\    assert.sameValue(Object.getPrototypeOf(iterator.next), other.Function.prototype);
        \\    assert.sameValue(Object.prototype.hasOwnProperty.call(iterator, "next"), false);
        \\})();
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "bound and proxy wrappers defer realm switching to the final target" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var other = $262.createRealm().global;
        \\    other.eval("globalThis.realmFunction = function () { return Array; }");
        \\    var bound = other.realmFunction.bind(null);
        \\    var proxy = new Proxy(other.realmFunction, {});
        \\    assert.sameValue(bound(), other.Array);
        \\    assert.sameValue(proxy(), other.Array);
        \\    var trapped = new Proxy(other.realmFunction, {
        \\        apply: function () { return Array; }
        \\    });
        \\    var trappedResult = trapped();
        \\    assert.sameValue(trappedResult, Array);
        \\    assert.notSameValue(trappedResult, other.Array);
        \\    var revoked = Proxy.revocable(other.realmFunction, {});
        \\    revoked.revoke();
        \\    try {
        \\        revoked.proxy();
        \\        throw new Error("expected revoked proxy call to throw");
        \\    } catch (error) {
        \\        assert.sameValue(Object.getPrototypeOf(error), TypeError.prototype);
        \\        assert.sameValue(error instanceof other.TypeError, false);
        \\    }
        \\})();
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Array species compares exact realm intrinsics without skipping wrapper gets" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var other = $262.createRealm().global;
        \\    other.eval("globalThis.NamedArray = function Array(length) { this.length = length; };");
        \\    function Species(length) { this.length = length; }
        \\    function identity(value) { return value; }
        \\
        \\    var namedGets = 0;
        \\    Object.defineProperty(other.NamedArray, Symbol.species, {
        \\        configurable: true,
        \\        get: function () { namedGets++; return Species; }
        \\    });
        \\    var named = [1, 2];
        \\    named.constructor = other.NamedArray;
        \\    var namedResult = named.map(identity);
        \\    assert.sameValue(namedGets, 1);
        \\    assert.sameValue(Object.getPrototypeOf(namedResult), Species.prototype);
        \\    assert.sameValue(namedResult.length, 2);
        \\
        \\    var foreignIntrinsicGets = 0;
        \\    Object.defineProperty(other.Array, Symbol.species, {
        \\        configurable: true,
        \\        get: function () { foreignIntrinsicGets++; return Species; }
        \\    });
        \\    var foreignIntrinsic = [3];
        \\    foreignIntrinsic.constructor = other.Array;
        \\    var foreignIntrinsicResult = foreignIntrinsic.map(identity);
        \\    assert.sameValue(foreignIntrinsicGets, 0);
        \\    assert.sameValue(Object.getPrototypeOf(foreignIntrinsicResult), Array.prototype);
        \\
        \\    var proxyGets = [];
        \\    var foreignArrayProxy = new Proxy(other.Array, {
        \\        get: function (target, key, receiver) {
        \\            proxyGets.push(key === Symbol.species ? "species" : String(key));
        \\            if (key === Symbol.species) return Species;
        \\            return Reflect.get(target, key, receiver);
        \\        }
        \\    });
        \\    var proxied = [4];
        \\    proxied.constructor = foreignArrayProxy;
        \\    var proxiedResult = proxied.map(identity);
        \\    assert.sameValue(proxyGets.join(","), "species");
        \\    assert.sameValue(Object.getPrototypeOf(proxiedResult), Species.prototype);
        \\
        \\    var boundGets = 0;
        \\    var foreignArrayBound = other.Array.bind(null);
        \\    Object.defineProperty(foreignArrayBound, Symbol.species, {
        \\        configurable: true,
        \\        get: function () { boundGets++; return Species; }
        \\    });
        \\    var bounded = [5];
        \\    bounded.constructor = foreignArrayBound;
        \\    var boundedResult = bounded.map(identity);
        \\    assert.sameValue(boundGets, 1);
        \\    assert.sameValue(Object.getPrototypeOf(boundedResult), Species.prototype);
        \\
        \\    var revoked = Proxy.revocable(other.Array, {});
        \\    var revokedInput = [6];
        \\    revokedInput.constructor = revoked.proxy;
        \\    revoked.revoke();
        \\    assert.throws(TypeError, function () { revokedInput.map(identity); });
        \\
        \\    var activeGets = 0;
        \\    var activeHolder = {};
        \\    Object.defineProperty(activeHolder, Symbol.species, {
        \\        get: function () { activeGets++; return Array; }
        \\    });
        \\    var active = [7];
        \\    active.constructor = activeHolder;
        \\    var activeResult = active.map(identity);
        \\    assert.sameValue(activeGets, 1);
        \\    assert.sameValue(Object.getPrototypeOf(activeResult), Array.prototype);
        \\})();
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Array species does not confuse a foreign native named Array with the intrinsic" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    _ = try js.eval(
        \\globalThis.__arraySpeciesRealmHandle = $262.createRealm();
        \\globalThis.__arraySpeciesForeignGlobal = __arraySpeciesRealmHandle.global;
        \\globalThis.__arraySpeciesResultCtor = function Species(length) { this.length = length; };
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const foreign_global_atom = try js.runtime.internAtom("__arraySpeciesForeignGlobal");
    const foreign_global_value = try global.getProperty(foreign_global_atom);
    const foreign_global = try core.Object.expect(foreign_global_value);
    const foreign_realm = js.runtime.contextForGlobalIncludingConstructing(foreign_global) orelse return error.TestUnexpectedResult;

    // Before the identity fix this ordinary C_FUNCTION was suppressed solely
    // because its internal dispatch name happened to be "Array". It owns the
    // foreign FunctionRealm, but it is not that realm's intrinsic %Array%.
    const fake_array = try core.function.nativeFunction(foreign_realm, "Array", 1);
    const fake_array_object = try core.Object.expect(fake_array);
    const species_ctor_atom = try js.runtime.internAtom("__arraySpeciesResultCtor");
    const species_ctor = try global.getProperty(species_ctor_atom);
    const species_atom = core.atom.predefinedId("Symbol.species", .symbol) orelse return error.TestUnexpectedResult;
    try fake_array_object.defineOwnProperty(js.runtime, species_atom, core.Descriptor.data(species_ctor, .method));

    const fake_array_atom = try js.runtime.internAtom("__arraySpeciesNamedNative");
    try global.defineOwnProperty(js.runtime, fake_array_atom, core.Descriptor.data(fake_array, .method));

    const result = try js.eval(
        \\var input = [1, 2];
        \\input.constructor = __arraySpeciesNamedNative;
        \\var output = input.map(function (value) { return value; });
        \\assert.sameValue(Object.getPrototypeOf(output), __arraySpeciesResultCtor.prototype);
        \\assert.sameValue(output.length, 2);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "TypedArray iterator methods accept cross-realm typed array receivers" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var other = $262.createRealm().global;
        \\    var local = new Uint8Array([42, 36]);
        \\    var remote = new other.Uint8Array([42, 36]);
        \\    assert.sameValue([...Uint8Array.prototype.values.call(remote)].toString(), "42,36");
        \\    assert.sameValue([...other.Uint8Array.prototype.values.call(local)].toString(), "42,36");
        \\    assert.sameValue([...Uint8Array.prototype.keys.call(remote)].toString(), "0,1");
        \\    assert.sameValue([...other.Uint8Array.prototype.entries.call(local)].toString(), "0,42,1,36");
        \\})();
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "TypedArray iterator methods reject proxy-wrapped shared typed array receivers" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function (global) {
        \\    const {Object, Reflect, SharedArrayBuffer, WeakMap} = global;
        \\    const {apply: Reflect_apply, construct: Reflect_construct} = Reflect;
        \\    const {get: WeakMap_prototype_get, has: WeakMap_prototype_has} = WeakMap.prototype;
        \\    const sharedConstructors = new WeakMap();
        \\    function sharedConstructor(baseConstructor) {
        \\        class SharedTypedArray extends Object.getPrototypeOf(baseConstructor) {
        \\            constructor(...args) {
        \\                var array = Reflect_construct(baseConstructor, args);
        \\                var {buffer, byteOffset, length} = array;
        \\                var sharedBuffer = new SharedArrayBuffer(buffer.byteLength);
        \\                var sharedArray = Reflect_construct(baseConstructor, [sharedBuffer, byteOffset, length], new.target);
        \\                for (var i = 0; i < length; i++) sharedArray[i] = array[i];
        \\                return sharedArray;
        \\            }
        \\        }
        \\        sharedConstructors.set(SharedTypedArray, baseConstructor);
        \\        return SharedTypedArray;
        \\    }
        \\    function isSharedConstructor(constructor) {
        \\        return Reflect_apply(WeakMap_prototype_has, sharedConstructors, [constructor]);
        \\    }
        \\    var constructors = [Uint8Array];
        \\    if (typeof SharedArrayBuffer === "function") constructors.push(sharedConstructor(Uint8Array));
        \\    for (var constructor of constructors) {
        \\        if (isSharedConstructor(constructor)) {
        \\            assert.sameValue(Reflect_apply(WeakMap_prototype_get, sharedConstructors, [constructor]), Uint8Array);
        \\        }
        \\        var invalidReceiver = new Proxy(new constructor(), {});
        \\        assert.throws(TypeError, function () {
        \\            constructor.prototype.values.call(invalidReceiver);
        \\        });
        \\    }
        \\})(this);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "TypedArray array-like construction does not replay coercions after fast path bailout" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var calls = 0;
        \\var value = {
        \\  valueOf: function() {
        \\    calls++;
        \\    return 7;
        \\  }
        \\};
        \\var source = {};
        \\source.length = 2;
        \\source[0] = value;
        \\source.x = 1;
        \\source[1] = 8;
        \\var typed = new Int8Array(source);
        \\assert.sameValue(calls, 1);
        \\assert.sameValue(typed[0], 7);
        \\assert.sameValue(typed[1], 8);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "TypedArray defineProperty value conversion may detach buffer" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var ta = new Int8Array([17]);
        \\assert.sameValue(Reflect.defineProperty(ta, 0, {
        \\    value: {
        \\        valueOf: function() {
        \\            ta.buffer.transfer();
        \\            return 42;
        \\        }
        \\    }
        \\}), true);
        \\assert.sameValue(ta[0], undefined);
        \\
        \\var big = new BigInt64Array([17n]);
        \\assert.sameValue(Reflect.defineProperty(big, 0, {
        \\    value: {
        \\        valueOf: function() {
        \\            big.buffer.transfer();
        \\            return 42n;
        \\        }
        \\    }
        \\}), true);
        \\assert.sameValue(big[0], undefined);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "TypedArray and species accessors follow inherited QuickJS shape" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var typedDesc = Object.getOwnPropertyDescriptor(TypedArray, Symbol.species);
        \\assert.sameValue(typedDesc.set, undefined);
        \\assert.sameValue(typeof typedDesc.get, "function");
        \\assert.sameValue(typedDesc.enumerable, false);
        \\assert.sameValue(typedDesc.configurable, true);
        \\assert.sameValue(typedDesc.get.length, 0);
        \\assert.sameValue(typedDesc.get.name, "get [Symbol.species]");
        \\assert.sameValue(Object.hasOwn(typedDesc.get, "call"), false);
        \\assert.sameValue(typedDesc.get.call(Uint8Array), Uint8Array);
        \\assert.sameValue(Object.hasOwn(Uint8Array, Symbol.species), false);
        \\assert.sameValue(Object.hasOwn(Float16Array, Symbol.species), false);
        \\assert.sameValue(Uint8Array[Symbol.species], Uint8Array);
        \\assert.sameValue(Float16Array[Symbol.species], Float16Array);
        \\var arrayGetter = Object.getOwnPropertyDescriptor(Array, Symbol.species).get;
        \\assert.sameValue(Object.hasOwn(arrayGetter, "call"), false);
        \\assert.sameValue(arrayGetter.call(Array), Array);
        \\for (var C of [Promise, Map, Set]) {
        \\    var getter = Object.getOwnPropertyDescriptor(C, Symbol.species).get;
        \\    assert.sameValue(Object.hasOwn(getter, "call"), false);
        \\    assert.sameValue(getter.call(C), C);
        \\}
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Date/Function prototype auto-init install preserves toPrimitive and hasInstance descriptors" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var dateDesc = Object.getOwnPropertyDescriptor(Date.prototype, Symbol.toPrimitive);
        \\assert.sameValue(typeof dateDesc.value, "function");
        \\assert.sameValue(dateDesc.value.length, 1);
        \\assert.sameValue(dateDesc.writable, false);
        \\assert.sameValue(dateDesc.enumerable, false);
        \\assert.sameValue(dateDesc.configurable, true);
        \\assert.sameValue((new Date(0))[Symbol.toPrimitive]("number"), 0);
        \\
        \\var hasInstanceDesc = Object.getOwnPropertyDescriptor(Function.prototype, Symbol.hasInstance);
        \\assert.sameValue(typeof hasInstanceDesc.value, "function");
        \\assert.sameValue(hasInstanceDesc.value.length, 1);
        \\assert.sameValue(hasInstanceDesc.writable, false);
        \\assert.sameValue(hasInstanceDesc.enumerable, false);
        \\assert.sameValue(hasInstanceDesc.configurable, false);
        \\function C() {}
        \\assert.sameValue(new C() instanceof C, true);
        \\assert.sameValue(1 instanceof C, false);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Lazy standard native accessors preserve descriptors and receiver markers" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var symbolDesc = Object.getOwnPropertyDescriptor(Symbol.prototype, "description");
        \\assert.sameValue(typeof symbolDesc.get, "function");
        \\assert.sameValue(symbolDesc.get.name, "get description");
        \\assert.sameValue(symbolDesc.get.length, 0);
        \\assert.sameValue(symbolDesc.set, undefined);
        \\assert.sameValue(symbolDesc.enumerable, false);
        \\assert.sameValue(symbolDesc.configurable, true);
        \\assert.sameValue(symbolDesc.get.call(Symbol("lazy-symbol")), "lazy-symbol");
        \\
        \\var mapSizeDesc = Object.getOwnPropertyDescriptor(Map.prototype, "size");
        \\assert.sameValue(typeof mapSizeDesc.get, "function");
        \\assert.sameValue(mapSizeDesc.get.name, "get size");
        \\assert.sameValue(mapSizeDesc.get.length, 0);
        \\assert.sameValue(mapSizeDesc.set, undefined);
        \\assert.sameValue(mapSizeDesc.get.call(new Map([["k", 1]])), 1);
        \\assert.throws(TypeError, function() { mapSizeDesc.get.call(new Set([1])); });
        \\
        \\var setSizeDesc = Object.getOwnPropertyDescriptor(Set.prototype, "size");
        \\assert.sameValue(typeof setSizeDesc.get, "function");
        \\assert.sameValue(setSizeDesc.get.name, "get size");
        \\assert.sameValue(setSizeDesc.get.length, 0);
        \\assert.sameValue(setSizeDesc.set, undefined);
        \\assert.sameValue(setSizeDesc.get.call(new Set([1, 2])), 2);
        \\assert.throws(TypeError, function() { setSizeDesc.get.call(new Map()); });
        \\
        \\var disposedDesc = Object.getOwnPropertyDescriptor(DisposableStack.prototype, "disposed");
        \\assert.sameValue(typeof disposedDesc.get, "function");
        \\assert.sameValue(disposedDesc.get.name, "get disposed");
        \\assert.sameValue(disposedDesc.get.length, 0);
        \\assert.sameValue(disposedDesc.set, undefined);
        \\assert.sameValue(disposedDesc.get.call(new DisposableStack()), false);
        \\assert.throws(TypeError, function() { disposedDesc.get.call({}); });
        \\
        \\var asyncDisposedDesc = Object.getOwnPropertyDescriptor(AsyncDisposableStack.prototype, "disposed");
        \\assert.sameValue(typeof asyncDisposedDesc.get, "function");
        \\assert.sameValue(asyncDisposedDesc.get.name, "get disposed");
        \\assert.sameValue(asyncDisposedDesc.get.length, 0);
        \\assert.sameValue(asyncDisposedDesc.set, undefined);
        \\assert.sameValue(asyncDisposedDesc.get.call(new AsyncDisposableStack()), false);
        \\assert.throws(TypeError, function() { asyncDisposedDesc.get.call({}); });
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "typed array instances keep concrete class identity" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var int32 = new Int32Array(new ArrayBuffer(16));
        \\assert.sameValue(Object.getPrototypeOf(int32), Int32Array.prototype);
        \\assert.sameValue(Object.prototype.toString.call(int32), "[object Int32Array]");
        \\var uint8 = new Uint8Array(4);
        \\assert.sameValue(Object.getPrototypeOf(uint8), Uint8Array.prototype);
        \\assert.sameValue(Object.prototype.toString.call(uint8), "[object Uint8Array]");
        \\var float64 = new Float64Array([1, 2]);
        \\assert.sameValue(Object.getPrototypeOf(float64), Float64Array.prototype);
        \\assert.sameValue(Object.prototype.toString.call(float64), "[object Float64Array]");
        \\var big = new BigUint64Array([1n]);
        \\assert.sameValue(Object.getPrototypeOf(big), BigUint64Array.prototype);
        \\assert.sameValue(Object.prototype.toString.call(big), "[object BigUint64Array]");
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "RegExp lazy native accessors preserve descriptor and mutation semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var sourceDesc = Object.getOwnPropertyDescriptor(RegExp.prototype, "source");
        \\assert.sameValue(typeof sourceDesc.get, "function");
        \\assert.sameValue(sourceDesc.get.name, "get source");
        \\assert.sameValue(sourceDesc.get.length, 0);
        \\assert.sameValue(sourceDesc.set, undefined);
        \\assert.sameValue(sourceDesc.enumerable, false);
        \\assert.sameValue(sourceDesc.configurable, true);
        \\assert.sameValue(sourceDesc.get.call(/ab+c/i), "ab+c");
        \\assert.sameValue(/ab+c/i.source, "ab+c");
        \\assert.sameValue(/ab+c/i.flags, "i");
        \\
        \\var speciesDesc = Object.getOwnPropertyDescriptor(RegExp, Symbol.species);
        \\assert.sameValue(typeof speciesDesc.get, "function");
        \\assert.sameValue(speciesDesc.get.name, "get [Symbol.species]");
        \\assert.sameValue(speciesDesc.get.length, 0);
        \\assert.sameValue(speciesDesc.set, undefined);
        \\assert.sameValue(speciesDesc.get.call(RegExp), RegExp);
        \\
        \\(function() {
        \\  "use strict";
        \\  var threw = false;
        \\  try { RegExp.prototype.unicodeSets = 1; } catch (e) { threw = e instanceof TypeError; }
        \\  assert.sameValue(threw, true);
        \\})();
        \\var unicodeSetsDesc = Object.getOwnPropertyDescriptor(RegExp.prototype, "unicodeSets");
        \\assert.sameValue(typeof unicodeSetsDesc.get, "function");
        \\assert.sameValue(unicodeSetsDesc.set, undefined);
        \\
        \\Object.defineProperty(RegExp.prototype, "dotAll", {});
        \\var dotAllDesc = Object.getOwnPropertyDescriptor(RegExp.prototype, "dotAll");
        \\assert.sameValue(typeof dotAllDesc.get, "function");
        \\assert.sameValue(dotAllDesc.set, undefined);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Buffer and TypedArray lazy native accessors preserve descriptor semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var buffer = new ArrayBuffer(8);
        \\var byteLengthDesc = Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "byteLength");
        \\assert.sameValue(typeof byteLengthDesc.get, "function");
        \\assert.sameValue(byteLengthDesc.get.name, "get byteLength");
        \\assert.sameValue(byteLengthDesc.get.length, 0);
        \\assert.sameValue(byteLengthDesc.set, undefined);
        \\assert.sameValue(byteLengthDesc.get.call(buffer), 8);
        \\assert.sameValue(buffer.byteLength, 8);
        \\
        \\var arrayBufferSpecies = Object.getOwnPropertyDescriptor(ArrayBuffer, Symbol.species);
        \\assert.sameValue(typeof arrayBufferSpecies.get, "function");
        \\assert.sameValue(arrayBufferSpecies.get.name, "get [Symbol.species]");
        \\assert.sameValue(arrayBufferSpecies.get.call(ArrayBuffer), ArrayBuffer);
        \\
        \\(function() {
        \\  "use strict";
        \\  var threw = false;
        \\  try { ArrayBuffer.prototype.resizable = 1; } catch (e) { threw = e instanceof TypeError; }
        \\  assert.sameValue(threw, true);
        \\})();
        \\
        \\var view = new DataView(buffer, 2, 4);
        \\var viewOffsetDesc = Object.getOwnPropertyDescriptor(DataView.prototype, "byteOffset");
        \\assert.sameValue(typeof viewOffsetDesc.get, "function");
        \\assert.sameValue(viewOffsetDesc.get.name, "get byteOffset");
        \\assert.sameValue(viewOffsetDesc.set, undefined);
        \\assert.sameValue(viewOffsetDesc.get.call(view), 2);
        \\
        \\var typed = new Uint8Array(buffer);
        \\var typedLengthDesc = Object.getOwnPropertyDescriptor(TypedArray.prototype, "length");
        \\assert.sameValue(typeof typedLengthDesc.get, "function");
        \\assert.sameValue(typedLengthDesc.get.name, "get length");
        \\assert.sameValue(typedLengthDesc.set, undefined);
        \\assert.sameValue(typedLengthDesc.get.call(typed), 8);
        \\var tagDesc = Object.getOwnPropertyDescriptor(TypedArray.prototype, Symbol.toStringTag);
        \\assert.sameValue(typeof tagDesc.get, "function");
        \\assert.sameValue(tagDesc.get.name, "get [Symbol.toStringTag]");
        \\assert.sameValue(tagDesc.set, undefined);
        \\assert.sameValue(tagDesc.get.call(typed), "Uint8Array");
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "standard constructors publish final prototype graphs and eager metadata" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function assertDataDescriptor(object, key, value, writable, enumerable, configurable) {
        \\    var descriptor = Object.getOwnPropertyDescriptor(object, key);
        \\    assert.sameValue(descriptor.value, value);
        \\    assert.sameValue(descriptor.writable, writable);
        \\    assert.sameValue(descriptor.enumerable, enumerable);
        \\    assert.sameValue(descriptor.configurable, configurable);
        \\}
        \\
        \\var constructors = [
        \\    [Object, "Object", 1, Function.prototype, null],
        \\    [Function, "Function", 1, Function.prototype, Object.prototype],
        \\    [Array, "Array", 1, Function.prototype, Object.prototype],
        \\    [Error, "Error", 1, Function.prototype, Object.prototype],
        \\    [TypeError, "TypeError", 1, Error, Error.prototype],
        \\    [DOMException, "DOMException", 0, Function.prototype, Error.prototype],
        \\    [Map, "Map", 0, Function.prototype, Object.prototype],
        \\    [Int8Array, "Int8Array", 3, TypedArray, TypedArray.prototype]
        \\];
        \\for (var entry of constructors) {
        \\    var constructor = entry[0];
        \\    assert.sameValue(Object.getPrototypeOf(constructor), entry[3]);
        \\    assert.sameValue(Object.getPrototypeOf(constructor.prototype), entry[4]);
        \\    assertDataDescriptor(constructor, "name", entry[1], false, false, true);
        \\    assertDataDescriptor(constructor, "length", entry[2], false, false, true);
        \\    assertDataDescriptor(constructor, "prototype", constructor.prototype, false, false, false);
        \\    assertDataDescriptor(constructor.prototype, "constructor", constructor, true, false, true);
        \\}
        \\assert.sameValue(typeof Function.prototype, "function");
        \\assert.sameValue(Function.prototype.name, "");
        \\assert.sameValue(Function.prototype.length, 0);
        \\assert.sameValue(Object.getPrototypeOf(Function.prototype), Object.prototype);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Function and Reflect apply preserve target classes and argument shapes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function signature() {
        \\    return arguments.length + ":" + arguments[0] + ":"
        \\        + arguments[arguments.length - 1];
        \\}
        \\var counts = [0, 1, 8, 9, 16, 64];
        \\for (var countIndex = 0; countIndex < counts.length; countIndex++) {
        \\    var count = counts[countIndex];
        \\    var dense = Array(count);
        \\    for (var index = 0; index < count; index++) dense[index] = index + 1;
        \\    var expected = count === 0
        \\        ? "0:undefined:undefined"
        \\        : count + ":1:" + count;
        \\    assert.sameValue(signature.apply(null, dense), expected);
        \\    assert.sameValue(Reflect.apply(signature, null, dense), expected);
        \\}
        \\assert.sameValue(signature.apply(null), "0:undefined:undefined");
        \\assert.sameValue(signature.apply(null, null), "0:undefined:undefined");
        \\assert.sameValue(signature.apply(null, undefined), "0:undefined:undefined");
        \\assert.sameValue(Reflect.apply(signature, null, []), "0:undefined:undefined");
        \\
        \\function sloppyThis() { return this === globalThis; }
        \\function strictThis() { "use strict"; return this; }
        \\assert.sameValue(sloppyThis.apply(null, []), true);
        \\assert.sameValue(strictThis.apply(null, []), null);
        \\var arrowOwner = {
        \\    make: function() { return () => this; }
        \\};
        \\var lexicalArrow = arrowOwner.make();
        \\assert.sameValue(lexicalArrow.apply({ ignored: true }, []), arrowOwner);
        \\function closureFactory(offset) {
        \\    return function(value) { return offset + value; };
        \\}
        \\assert.sameValue(closureFactory(40).apply(null, [2]), 42);
        \\
        \\assert.sameValue(Math.max.apply(null, [3, 9, 4]), 9);
        \\function boundTarget(left, right) {
        \\    return this.base + left + right;
        \\}
        \\var bound = boundTarget.bind({ base: 10 }, 20);
        \\assert.sameValue(bound.apply({ base: 1000 }, [12]), 42);
        \\var trapOrder = [];
        \\var proxied = new Proxy(boundTarget, {
        \\    apply: function(target, receiver, list) {
        \\        trapOrder.push(receiver.base, list.length, list[0], list[1]);
        \\        return Reflect.apply(target, receiver, list);
        \\    }
        \\});
        \\assert.sameValue(proxied.apply({ base: 30 }, [5, 7]), 42);
        \\assert.sameValue(trapOrder.join(","), "30,2,5,7");
        \\class ApplyClass {}
        \\assert.throws(TypeError, function() { ApplyClass.apply(null, []); });
        \\
        \\var other = $262.createRealm().global;
        \\var foreign = other.eval(
        \\    "(function foreign(value) { return this.base + value; })"
        \\);
        \\assert.sameValue(foreign.apply({ base: 40 }, [2]), 42);
        \\async function asyncTarget(value) { return value + 1; }
        \\var asyncResult = asyncTarget.apply(null, [41]);
        \\assert.sameValue(asyncResult instanceof Promise, true);
        \\function* generatorTarget(value) { yield value + 1; }
        \\var generatorResult = generatorTarget.apply(null, [41]);
        \\assert.sameValue(generatorResult.next().value, 42);
        \\
        \\function helper(value) { return value + 1; }
        \\function callbackToHelper(value) { return helper(value); }
        \\assert.sameValue(callbackToHelper.apply(null, [41]), 42);
        \\function reentrantApply(value) {
        \\    if (value === 0) return 40;
        \\    return reentrantApply.apply(null, [value - 1]) + 1;
        \\}
        \\assert.sameValue(reentrantApply.apply(null, [2]), 42);
        \\assert.sameValue(
        \\    (function() { return signature.apply(null, arguments); })(1, 2, 3),
        \\    "3:1:3"
        \\);
        \\
        \\var genericOrder = [];
        \\var generic = {
        \\    get length() {
        \\        genericOrder.push("length");
        \\        return 2;
        \\    },
        \\    get 0() {
        \\        genericOrder.push("0");
        \\        this.extra = 99;
        \\        return 20;
        \\    },
        \\    get 1() {
        \\        genericOrder.push("1");
        \\        return 22;
        \\    },
        \\    get 2() {
        \\        genericOrder.push("2");
        \\        return this.extra;
        \\    }
        \\};
        \\assert.sameValue(
        \\    Reflect.apply(function(a, b) { return a + b; }, null, generic),
        \\    42
        \\);
        \\assert.sameValue(genericOrder.join(","), "length,0,1");
        \\
        \\globalThis.__nativeApplyIndirect = 0;
        \\function indirectApplyProbe() {
        \\    var hiddenFromIndirectEval = 1;
        \\    return (0, eval).apply(null, [
        \\        "globalThis.__nativeApplyIndirect = 42; typeof hiddenFromIndirectEval;"
        \\    ]);
        \\}
        \\assert.sameValue(indirectApplyProbe(), "undefined");
        \\assert.sameValue(globalThis.__nativeApplyIndirect, 42);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Promise.finally callbacks keep internal state off user properties" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var savedFulfill;
        \\var savedReject;
        \\var cleanupCount = 0;
        \\var p = new Promise(function() {});
        \\p.then = function(onFulfilled, onRejected) {
        \\    savedFulfill = onFulfilled;
        \\    savedReject = onRejected;
        \\    return Promise.prototype.then.call(this, onFulfilled, onRejected);
        \\};
        \\p.finally(function() {
        \\    cleanupCount += 1;
        \\    print("cleanup", cleanupCount);
        \\    return "cleanup-result";
        \\});
        \\assert.sameValue("__zjs_promise_finally_mode" in savedFulfill, false);
        \\assert.sameValue("__zjs_promise_finally_callback" in savedFulfill, false);
        \\assert.sameValue("__zjs_promise_finally_constructor" in savedFulfill, false);
        \\assert.sameValue("__zjs_promise_finally_mode" in savedReject, false);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(savedFulfill, "__zjs_promise_finally_mode"), undefined);
        \\assert.sameValue(savedFulfill.__zjs_promise_finally_mode, undefined);
        \\savedFulfill.__zjs_promise_finally_callback = function() {
        \\    print("tampered");
        \\    return "bad";
        \\};
        \\savedFulfill.__zjs_promise_finally_payload = "bad";
        \\savedFulfill("direct");
        \\print("after direct");
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("cleanup 1\nafter direct\n", stream.buffered());
    try std.testing.expect(!js.context.hasException());
}

test "Object constructor record preserves call and construct semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const value = { marker: 1 };
        \\assert.sameValue(Object.prototype.hasOwnProperty("Object"), false);
        \\assert.sameValue(Object(value), value);
        \\assert.sameValue(Object.call(null, value), value);
        \\assert.sameValue(Object(value, 2, 3), value);
        \\assert.sameValue(Object() instanceof Object, true);
        \\assert.sameValue(Object(null) instanceof Object, true);
        \\assert.sameValue(Object(undefined) instanceof Object, true);
        \\assert.sameValue(Object(7).valueOf(), 7);
        \\assert.sameValue(Object(true).valueOf(), true);
        \\assert.sameValue(Object("z").valueOf(), "z");
        \\assert.sameValue(Object(1n).valueOf(), 1n);
        \\const symbol = Symbol("s");
        \\assert.sameValue(Object(symbol).valueOf(), symbol);
        \\const renamed = Object;
        \\const originalName = Object.getOwnPropertyDescriptor(renamed, "name");
        \\Object.defineProperty(renamed, "name", { value: "RenamedObject" });
        \\assert.sameValue(renamed(value), value);
        \\assert.sameValue(new renamed(value), value);
        \\function NewTarget() {}
        \\const reflected = Reflect.construct(renamed, [value], NewTarget);
        \\assert.sameValue(reflected === value, false);
        \\assert.sameValue(Object.getPrototypeOf(reflected), NewTarget.prototype);
        \\class ObjectSubclass extends renamed {}
        \\const subclassed = new ObjectSubclass(value);
        \\assert.sameValue(subclassed === value, false);
        \\assert.sameValue(Object.getPrototypeOf(subclassed), ObjectSubclass.prototype);
        \\Object.defineProperty(renamed, "name", originalName);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "property compaction preserves enumeration order across interleaved deletes" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const object = {};
        \\for (let i = 0; i < 16; i++) object["p" + i] = i * 10;
        \\for (let i = 0; i < 16; i += 2) delete object["p" + i];
        \\assert.sameValue(Object.keys(object).join(","), "p1,p3,p5,p7,p9,p11,p13,p15");
        \\assert.sameValue(Object.keys(object).map(k => object[k]).join(","), "10,30,50,70,90,110,130,150");
        \\for (let i = 16; i < 24; i++) object["p" + i] = i * 10;
        \\for (let i = 1; i < 16; i += 2) delete object["p" + i];
        \\assert.sameValue(Object.keys(object).join(","), "p16,p17,p18,p19,p20,p21,p22,p23");
        \\object.p3 = 303;
        \\assert.sameValue(Object.keys(object).join(","), "p16,p17,p18,p19,p20,p21,p22,p23,p3");
        \\assert.sameValue(Object.keys(object).map(k => k + ":" + object[k]).join("|"), "p16:160|p17:170|p18:180|p19:190|p20:200|p21:210|p22:220|p23:230|p3:303");
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "shared engine baseline restore survives compacting global deletes" {
    const js = helpers.sharedTestEngine();

    _ = try js.eval(
        \\const root = globalThis;
        \\const names = Object.getOwnPropertyNames(root);
        \\const descriptor = Object.getOwnPropertyDescriptor;
        \\for (const name of names) {
        \\    const current = descriptor(root, name);
        \\    if (current && current.configurable) delete root[name];
        \\}
    );
    try std.testing.expect(js.context.global.?.shape_ref.deletedPropCount() < 8);

    helpers.endSharedTest();
    defer helpers.endSharedTest();
    const check = try js.eval(
        \\assert.sameValue(typeof Object, "function");
        \\assert.sameValue(typeof Array, "function");
        \\assert.sameValue(typeof globalThis, "object");
        \\assert.sameValue(typeof print, "function");
        \\assert.sameValue(eval("1 + 1"), 2);
    );
    try std.testing.expect(check.is(.undefined_value));
}

test "native cproto distinguishes construct-only and callable constructors" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\assert.throws(TypeError, function() { Map(); });
        \\assert.throws(TypeError, function() { Set(); });
        \\assert.throws(TypeError, function() { WeakMap(); });
        \\assert.throws(TypeError, function() { WeakSet(); });
        \\assert.sameValue(Array(1).length, 1);
        \\assert.sameValue(String(1), "1");
        \\assert.sameValue(RegExp("x").source, "x");
        \\assert.sameValue(typeof Date(), "string");
        \\assert.sameValue(Object(null) instanceof Object, true);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "WeakMap and WeakSet accept non-registered symbols as weak keys" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const key = Symbol("weak");
        \\const other = Symbol("weak");
        \\const map = new WeakMap([[key, 1]]);
        \\assert.sameValue(map.get(key), 1);
        \\assert.sameValue(map.has(other), false);
        \\assert.sameValue(map.set(other, 2), map);
        \\assert.sameValue(map.get(other), 2);
        \\assert.sameValue(map.delete(key), true);
        \\assert.sameValue(map.has(key), false);
        \\const set = new WeakSet([key]);
        \\assert.sameValue(set.has(key), true);
        \\assert.sameValue(set.add(other), set);
        \\assert.sameValue(set.has(other), true);
        \\assert.sameValue(set.delete(key), true);
        \\assert.sameValue(set.has(key), false);
        \\assert.throws(TypeError, function () { map.set(Symbol.for("registered"), 3); });
        \\assert.throws(TypeError, function () { set.add(Symbol.for("registered")); });
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "host WeakMap mutation closure rejects registered symbol keys" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const map_value = try engine.exec.collection_ops.constructBare(rt, 3);
    const map_object = objectFromValue(map_value);

    const closure_value = try engine.exec.closure.create(rt, .mutates_map_key3_then_throws);

    const registered_atom = try rt.atoms.internGlobalSymbol("registered");

    const map_name = try rt.internAtom("map");
    const key_name = try rt.internAtom("obj3");

    var globals = [_]engine.exec.globals.Slot{
        .{ .name = map_name, .value = map_value },
        .{ .name = key_name, .value = try rt.symbolValue(registered_atom) },
    };

    if (engine.exec.closure.call(rt, closure_value, &.{}, globals[0..])) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(error.TypeError, err);
    }
    try std.testing.expectEqual(@as(usize, 0), map_object.weakCollectionEntries().len);
}

test "host WeakMap mutation closure links entries into existing weak index" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const map_value = try engine.exec.collection_ops.constructBare(rt, 3);
    const map_object = objectFromValue(map_value);

    var keys: [8]*core.Object = undefined;
    var key_count: usize = 0;
    defer {}

    for (&keys, 0..) |*slot, index| {
        const key = try core.Object.create(rt, core.class.ids.object, null);
        slot.* = key;
        key_count += 1;
        _ = try engine.exec.collection_ops.methodCall(rt, map_value, 1, &.{ key.value(), core.JSValue.int32(@intCast(index)) });
    }
    try std.testing.expectEqual(@as(usize, 8), map_object.weakCollectionEntries().len);
    try std.testing.expect(map_object.collectionBucketHeads().len != 0);

    const mutation_key = try core.Object.create(rt, core.class.ids.object, null);

    const closure_value = try engine.exec.closure.create(rt, .mutates_map_key3_then_throws);

    const map_name = try rt.internAtom("map");
    const key_name = try rt.internAtom("obj3");

    var globals = [_]engine.exec.globals.Slot{
        .{ .name = map_name, .value = map_value },
        .{ .name = key_name, .value = mutation_key.value() },
    };

    try std.testing.expectError(error.JSException, engine.exec.closure.call(rt, closure_value, &.{}, globals[0..]));

    try std.testing.expectEqual(@as(usize, 9), map_object.weakCollectionEntries().len);
    const get_result = try engine.exec.collection_ops.methodCall(rt, map_value, 2, &.{mutation_key.value()});
    try helpers.expectStringValueBytes(get_result, "mutated");
}

// Test-side stand-in for the retired engine `__setlike_mode` fixture: a
// CallbackHost whose `keys` call mutates the base set mid-operation (delete
// "b"/"c", re-add "b", add "d") before returning the real key array
// ["x","b","c","c"]. The set-like object itself is a plain object carrying
// real `size`/`has`/`keys` properties.
fn symmetricDifferenceMutatingKeysHost(
    ctx: *core.JSContext,
    callback: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    globals: []engine.exec.globals.Slot,
) core.host_function.CallbackError!core.JSValue {
    _ = callback;
    _ = this_value;
    return symmetricDifferenceMutatingKeysImpl(ctx.runtime, args, globals) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => error.OutOfMemory,
        error.Interrupted => error.Interrupted,
        error.ProcessExit => error.ProcessExit,
        error.StackOverflow => error.StackOverflow,
        error.Timeout => error.Timeout,
        error.UnhandledPromiseRejection => error.UnhandledPromiseRejection,
        error.JSException => if (ctx.hasException()) error.JSException else blk: {
            _ = engine.exec.builtin_dispatch.nativeFromHostError(ctx, ctx.global, err);
            break :blk error.JSException;
        },
        else => blk: {
            _ = engine.exec.builtin_dispatch.nativeFromHostError(ctx, ctx.global, err);
            break :blk error.JSException;
        },
    };
}

fn symmetricDifferenceMutatingKeysImpl(
    rt: *core.JSRuntime,
    args: []const core.JSValue,
    globals: []engine.exec.globals.Slot,
) !core.JSValue {
    // `has` (one argument) is never reached by symmetricDifference; only the
    // zero-argument `keys` call arrives here.
    if (args.len != 0) return core.JSValue.boolean(false);

    const base_set_value = try engine.exec.globals.getByName(rt, globals, "baseSet");
    inline for (.{ "b", "c" }) |name| {
        const value = (try core.string.String.createUtf8(rt, name)).value();
        _ = try engine.exec.collection_ops.methodCall(rt, base_set_value, 4, &.{value});
    }
    inline for (.{ "b", "d" }) |name| {
        const value = (try core.string.String.createUtf8(rt, name)).value();
        _ = try engine.exec.collection_ops.methodCall(rt, base_set_value, 6, &.{value});
    }

    const array = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, array.gcHeader());
    comptime var index: u32 = 0;
    inline for (.{ "x", "b", "c", "c" }) |name| {
        const value = (try core.string.String.createUtf8(rt, name)).value();
        try array.defineOwnProperty(rt, core.Atom.taggedInt(index), core.Descriptor.data(value, .all));
        index += 1;
    }
    return array.value();
}

test "Set combinator results use the realm intrinsic prototype after global mutation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var IntrinsicSet = Set;
        \\function checkSetCombinators() {
        \\  var left = new IntrinsicSet([1, 2]);
        \\  var right = new IntrinsicSet([2, 3]);
        \\  var results = [
        \\    [left.union(right), [1, 2, 3]],
        \\    [left.intersection(right), [2]],
        \\    [left.difference(right), [1]],
        \\    [left.symmetricDifference(right), [1, 3]]
        \\  ];
        \\  for (var i = 0; i < results.length; i++) {
        \\    assert.sameValue(Object.getPrototypeOf(results[i][0]), IntrinsicSet.prototype);
        \\    assert.compareArray([...results[i][0]], results[i][1]);
        \\  }
        \\}
        \\try {
        \\  globalThis.Set = function Polyfill() {};
        \\  checkSetCombinators();
        \\  delete globalThis.Set;
        \\  checkSetCombinators();
        \\} finally {
        \\  globalThis.Set = IntrinsicSet;
        \\}
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Map.groupBy result uses the realm intrinsic prototype after global mutation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var IntrinsicMap = Map;
        \\function checkGroupBy() {
        \\  var grouped = IntrinsicMap.groupBy([1, 2, 3, 4], function(value) {
        \\    return value % 2 ? "odd" : "even";
        \\  });
        \\  assert.sameValue(Object.getPrototypeOf(grouped), IntrinsicMap.prototype);
        \\  assert.sameValue(grouped.size, 2);
        \\  assert.compareArray(grouped.get("odd"), [1, 3]);
        \\  assert.compareArray(grouped.get("even"), [2, 4]);
        \\}
        \\try {
        \\  globalThis.Map = function Polyfill() {};
        \\  checkGroupBy();
        \\  delete globalThis.Map;
        \\  checkGroupBy();
        \\} finally {
        \\  globalThis.Map = IntrinsicMap;
        \\}
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "RegExp call and String RegExpCreate use the realm intrinsic after global mutation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var IntrinsicRegExp = RegExp;
        \\function checkRegExpCreate() {
        \\  var called = IntrinsicRegExp("abc", "i");
        \\  assert.sameValue(Object.getPrototypeOf(called), IntrinsicRegExp.prototype);
        \\  assert.sameValue(called.source, "abc");
        \\  assert.sameValue(called.flags, "i");
        \\  var constructed = new IntrinsicRegExp("xyz");
        \\  assert.sameValue(Object.getPrototypeOf(constructed), IntrinsicRegExp.prototype);
        \\  var matches = [..."aba".matchAll("a")];
        \\  assert.sameValue(matches.length, 2);
        \\  assert.sameValue(matches[0][0], "a");
        \\  assert.sameValue(matches[1][0], "a");
        \\  var matched = "abc".match("b");
        \\  assert.sameValue(matched[0], "b");
        \\  assert.sameValue("abc".search("b"), 1);
        \\}
        \\try {
        \\  globalThis.RegExp = function Polyfill() {};
        \\  checkRegExpCreate();
        \\  delete globalThis.RegExp;
        \\  checkRegExpCreate();
        \\} finally {
        \\  globalThis.RegExp = IntrinsicRegExp;
        \\}
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "native Error Reflect.construct fallback uses the realm intrinsic after global mutation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function Fake() {}
        \\Fake.prototype = 1;
        \\function checkNativeError(intrinsic, expectedName) {
        \\  var thrown = Reflect.construct(intrinsic, ["msg"], Fake);
        \\  assert.sameValue(Object.getPrototypeOf(thrown), intrinsic.prototype);
        \\  assert.sameValue(thrown.name, expectedName);
        \\  assert.sameValue(thrown.message, "msg");
        \\}
        \\var IntrinsicTypeError = TypeError;
        \\var IntrinsicRangeError = RangeError;
        \\var IntrinsicEvalError = EvalError;
        \\try {
        \\  globalThis.TypeError = function Polyfill() {};
        \\  globalThis.RangeError = function Polyfill() {};
        \\  globalThis.EvalError = function Polyfill() {};
        \\  checkNativeError(IntrinsicTypeError, "TypeError");
        \\  checkNativeError(IntrinsicRangeError, "RangeError");
        \\  checkNativeError(IntrinsicEvalError, "EvalError");
        \\  delete globalThis.TypeError;
        \\  delete globalThis.RangeError;
        \\  delete globalThis.EvalError;
        \\  checkNativeError(IntrinsicTypeError, "TypeError");
        \\  checkNativeError(IntrinsicRangeError, "RangeError");
        \\  checkNativeError(IntrinsicEvalError, "EvalError");
        \\} finally {
        \\  globalThis.TypeError = IntrinsicTypeError;
        \\  globalThis.RangeError = IntrinsicRangeError;
        \\  globalThis.EvalError = IntrinsicEvalError;
        \\}
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Error.prototype.stack setter still recognizes the intrinsic after global mutation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var IntrinsicError = Error;
        \\var proto = IntrinsicError.prototype;
        \\function expectSetterRejects() {
        \\  var threw = false;
        \\  try {
        \\    proto.stack = "hijack";
        \\  } catch (e) {
        \\    threw = true;
        \\    assert.sameValue(e.name, "TypeError");
        \\  }
        \\  assert.sameValue(threw, true);
        \\  var desc = Object.getOwnPropertyDescriptor(proto, "stack");
        \\  assert.sameValue(typeof desc.get, "function");
        \\  assert.sameValue(typeof desc.set, "function");
        \\}
        \\expectSetterRejects();
        \\try {
        \\  globalThis.Error = function Polyfill() {};
        \\  expectSetterRejects();
        \\  delete globalThis.Error;
        \\  expectSetterRejects();
        \\} finally {
        \\  globalThis.Error = IntrinsicError;
        \\}
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "DisposableStack.move and dispose keep realm intrinsic prototypes after global mutation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var IntrinsicDisposableStack = DisposableStack;
        \\var IntrinsicAsyncDisposableStack = AsyncDisposableStack;
        \\var IntrinsicSuppressedError = SuppressedError;
        \\function checkMoveAndDispose() {
        \\  var stack = new IntrinsicDisposableStack();
        \\  var moved = stack.move();
        \\  assert.sameValue(Object.getPrototypeOf(moved), IntrinsicDisposableStack.prototype);
        \\  assert.sameValue(stack.disposed, true);
        \\  var asyncStack = new IntrinsicAsyncDisposableStack();
        \\  var asyncMoved = asyncStack.move();
        \\  assert.sameValue(Object.getPrototypeOf(asyncMoved), IntrinsicAsyncDisposableStack.prototype);
        \\  assert.sameValue(asyncStack.disposed, true);
        \\  var disposing = new IntrinsicDisposableStack();
        \\  disposing.use({ [Symbol.dispose]: function () { throw 1; } });
        \\  disposing.use({ [Symbol.dispose]: function () { throw 2; } });
        \\  var thrown = false;
        \\  try {
        \\    disposing.dispose();
        \\  } catch (e) {
        \\    thrown = true;
        \\    assert.sameValue(Object.getPrototypeOf(e), IntrinsicSuppressedError.prototype);
        \\    assert.sameValue(e.name, "SuppressedError");
        \\  }
        \\  assert.sameValue(thrown, true);
        \\}
        \\try {
        \\  globalThis.DisposableStack = function Polyfill() {};
        \\  globalThis.AsyncDisposableStack = function Polyfill() {};
        \\  globalThis.SuppressedError = function Polyfill() {};
        \\  checkMoveAndDispose();
        \\  delete globalThis.DisposableStack;
        \\  delete globalThis.AsyncDisposableStack;
        \\  delete globalThis.SuppressedError;
        \\  checkMoveAndDispose();
        \\} finally {
        \\  globalThis.DisposableStack = IntrinsicDisposableStack;
        \\  globalThis.AsyncDisposableStack = IntrinsicAsyncDisposableStack;
        \\  globalThis.SuppressedError = IntrinsicSuppressedError;
        \\}
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "JSON.parse uses realm intrinsic Object/Array prototypes after global mutation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var IntrinsicObject = Object;
        \\var IntrinsicArray = Array;
        \\var getProto = Object.getPrototypeOf;
        \\function checkJson() {
        \\  var parsed = JSON.parse('{"a":[1,2]}');
        \\  assert.sameValue(getProto(parsed), IntrinsicObject.prototype);
        \\  assert.sameValue(getProto(parsed.a), IntrinsicArray.prototype);
        \\  assert.sameValue(parsed.a.length, 2);
        \\  assert.sameValue(parsed.a[0], 1);
        \\  assert.sameValue(parsed.a[1], 2);
        \\}
        \\try {
        \\  globalThis.Object = function Polyfill() {};
        \\  globalThis.Array = function Polyfill() {};
        \\  checkJson();
        \\  delete globalThis.Object;
        \\  delete globalThis.Array;
        \\  checkJson();
        \\} finally {
        \\  globalThis.Object = IntrinsicObject;
        \\  globalThis.Array = IntrinsicArray;
        \\}
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "TypedArray Reflect.construct fallback uses the realm intrinsic after global mutation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var IntrinsicUint8Array = Uint8Array;
        \\function Fake() {}
        \\Fake.prototype = 1;
        \\function checkTypedArray() {
        \\  var view = Reflect.construct(IntrinsicUint8Array, [4], Fake);
        \\  assert.sameValue(Object.getPrototypeOf(view), IntrinsicUint8Array.prototype);
        \\  assert.sameValue(view.length, 4);
        \\}
        \\try {
        \\  globalThis.Uint8Array = function Polyfill() {};
        \\  checkTypedArray();
        \\  delete globalThis.Uint8Array;
        \\  checkTypedArray();
        \\} finally {
        \\  globalThis.Uint8Array = IntrinsicUint8Array;
        \\}
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Set.prototype.symmetricDifference tracks receiver mutations from a set-like keys call" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const callback_ctx = try core.JSContext.create(rt);
    defer callback_ctx.destroy();
    _ = try engine.exec.zjs_vm.contextGlobal(callback_ctx);

    const base_set_value = try engine.exec.collection_ops.constructBare(rt, 2);
    const base_set = objectFromValue(base_set_value);

    inline for (.{ "a", "b", "c", "d", "e", "q" }) |name| {
        const value = (try core.string.String.createUtf8(rt, name)).value();
        _ = try engine.exec.collection_ops.methodCall(rt, base_set_value, 6, &.{value});
    }

    const setlike = try core.Object.create(rt, core.class.ids.object, null);
    const setlike_value = setlike.value();

    const size_key = try rt.internAtom("size");
    try setlike.defineOwnProperty(rt, size_key, core.Descriptor.data(core.JSValue.int32(4), .all));

    const noop = try engine.exec.closure.create(rt, .returns_undefined);

    const has_key = try rt.internAtom("has");
    try setlike.defineOwnProperty(rt, has_key, core.Descriptor.data(noop, .all));

    const keys_key = try rt.internAtom("keys");
    try setlike.defineOwnProperty(rt, keys_key, core.Descriptor.data(noop, .all));

    const base_set_name = try rt.internAtom("baseSet");
    var globals = [_]engine.exec.globals.Slot{
        .{ .name = base_set_name, .value = base_set_value },
    };

    const host = core.host_function.CallbackHost{
        .ctx = callback_ctx,
        .globals = globals[0..],
        .call = &symmetricDifferenceMutatingKeysHost,
    };
    const result_value = try engine.exec.collection_ops.methodCallWithCallbackHost(rt, base_set_value, 20, &.{setlike_value}, host);
    const result_set = objectFromValue(result_value);

    try expectActiveSetStrings(result_set, &.{ "a", "c", "d", "e", "q", "x" });
    try expectActiveSetStrings(base_set, &.{ "a", "d", "e", "q", "b" });
}

test "host map closure releases appended value when entry allocation fails" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const map_value = try engine.exec.collection_ops.constructBare(rt, 1);
    const map_object = objectFromValue(map_value);

    inline for (.{ 10, 11, 12, 13, 14, 15, 16, 17 }) |key| {
        _ = try engine.exec.collection_ops.methodCall(rt, map_value, 1, &.{ core.JSValue.int32(key), core.JSValue.int32(key) });
    }
    try std.testing.expectEqual(@as(usize, 8), map_object.collectionEntries().len);
    try std.testing.expectEqual(@as(usize, 8), map_object.collectionEntriesCapacity());

    const closure_value = try engine.exec.closure.create(rt, .mutates_map_key1_then_throws);

    const map_name = try rt.internAtom("map");
    var globals = [_]engine.exec.globals.Slot{
        .{ .name = map_name, .value = map_value },
    };

    // TGC S4-b: sweep first -- storage cells are collected carriers, so the
    // limit-triggered retry collection would otherwise drop the account below
    // the captured baseline.
    _ = rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {};
    const old_bytes = rt.memory.allocated_bytes;
    const old_allocations = rt.memory.allocation_count;
    rt.setMemoryLimit(old_bytes + @sizeOf(core.string.String) + "mutated".len);
    try std.testing.expectError(error.OutOfMemory, engine.exec.closure.call(rt, closure_value, &.{}, globals[0..]));
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(old_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(old_allocations, rt.memory.allocation_count);
    try std.testing.expectEqual(@as(usize, 8), map_object.collectionEntries().len);
    try std.testing.expectEqual(@as(usize, 8), map_object.collectionActiveCount());
}

test "host map closure rolls back appended entry when size update fails" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const map_value = try engine.exec.collection_ops.constructBare(rt, 1);
    const map_object = objectFromValue(map_value);

    _ = try engine.exec.collection_ops.methodCall(rt, map_value, 1, &.{ core.JSValue.int32(1), core.JSValue.int32(11) });

    try fillOwnPropertyStorageForFailure(rt, map_object);
    try std.testing.expect(map_object.deleteProperty(rt, core.atom.predefinedId("size", .string).?));

    const closure_value = try engine.exec.closure.create(rt, .mutates_map_key3_then_throws);

    const map_name = try rt.internAtom("map");
    var globals = [_]engine.exec.globals.Slot{
        .{ .name = map_name, .value = map_value },
    };

    const old_len = map_object.collectionEntries().len;
    const old_active = map_object.collectionActiveCount();
    // TGC S4-b: sweep first -- storage cells are collected carriers, so the
    // limit-triggered retry collection would otherwise drop the account below
    // the captured baseline.
    _ = rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {};
    const old_bytes = rt.memory.allocated_bytes;

    rt.setMemoryLimit(old_bytes + @sizeOf(core.string.String) + "mutated".len);
    try std.testing.expectError(error.OutOfMemory, engine.exec.closure.call(rt, closure_value, &.{}, globals[0..]));
    rt.setMemoryLimit(null);

    const entries_slot = map_object.collectionEntriesSlot();
    const observed_len = entries_slot.items.len;
    const observed_active = map_object.collectionActiveCount();
    if (entries_slot.items.len > old_len) {
        entries_slot.items[old_len] = .{ .key = core.JSValue.undefinedValue(), .value = core.JSValue.undefinedValue(), .active = false };
        entries_slot.items = entries_slot.items.ptr[0..old_len];
        map_object.collectionActiveCountSlot().* = old_active;
        map_object.clearCollectionIndex(rt);
    }

    try std.testing.expectEqual(old_len, observed_len);
    try std.testing.expectEqual(old_active, observed_active);
    try std.testing.expectEqual(old_bytes, rt.memory.allocated_bytes);
}

test "Set.prototype.isDisjointFrom propagates IteratorClose errors on early false" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\var closeError = new Test262Error("close-disjoint");
        \\var returnCalls = 0;
        \\var other = {
        \\  size: 1,
        \\  has: function() { return false; },
        \\  keys: function() {
        \\    return {
        \\      next: function() { return { done: false, value: 2 }; },
        \\      return: function() { returnCalls++; throw closeError; }
        \\    };
        \\  }
        \\};
        \\try {
        \\  new Set([1, 2, 3]).isDisjointFrom(other);
        \\  throw new Test262Error("expected IteratorClose to throw");
        \\} catch (error) {
        \\  assert.sameValue(error, closeError);
        \\}
        \\assert.sameValue(returnCalls, 1);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Set.prototype.isSupersetOf propagates IteratorClose errors on early false" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\var closeError = new Test262Error("close-superset");
        \\var returnCalls = 0;
        \\var other = {
        \\  size: 0,
        \\  has: function() { return true; },
        \\  keys: function() {
        \\    return {
        \\      next: function() { return { done: false, value: 99 }; },
        \\      return: function() { returnCalls++; throw closeError; }
        \\    };
        \\  }
        \\};
        \\try {
        \\  new Set([1]).isSupersetOf(other);
        \\  throw new Test262Error("expected IteratorClose to throw");
        \\} catch (error) {
        \\  assert.sameValue(error, closeError);
        \\}
        \\assert.sameValue(returnCalls, 1);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Set relation IteratorClose rejects a non-object return result" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\var returnCalls = 0;
        \\var other = {
        \\  size: 1,
        \\  has: function() { return false; },
        \\  keys: function() {
        \\    return {
        \\      next: function() { return { done: false, value: 2 }; },
        \\      return: function() { returnCalls++; return 42; }
        \\    };
        \\  }
        \\};
        \\assert.throws(TypeError, function() {
        \\  new Set([1, 2, 3]).isDisjointFrom(other);
        \\});
        \\assert.sameValue(returnCalls, 1);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Set relation next abrupt completion does not close the iterator" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\var nextError = new Test262Error("next-error");
        \\var returnCalls = 0;
        \\var other = {
        \\  size: 1,
        \\  has: function() { return false; },
        \\  keys: function() {
        \\    return {
        \\      next: function() { throw nextError; },
        \\      return: function() {
        \\        returnCalls++;
        \\        throw new Test262Error("close-error");
        \\      }
        \\    };
        \\  }
        \\};
        \\var thrown;
        \\try {
        \\  new Set([1, 2, 3]).isDisjointFrom(other);
        \\} catch (error) {
        \\  thrown = error;
        \\}
        \\assert.sameValue(thrown, nextError);
        \\assert.sameValue(returnCalls, 0);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Set.prototype.union uses GetSetRecord order for set-like classes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var observedOrder = [];
        \\function observableIterator() {
        \\  var values = ["a", "b", "c"];
        \\  var index = 0;
        \\  return {
        \\    get next() {
        \\      observedOrder.push("getting next");
        \\      return function() {
        \\        observedOrder.push("calling next");
        \\        return {
        \\          get done() {
        \\            observedOrder.push("getting done");
        \\            return index >= values.length;
        \\          },
        \\          get value() {
        \\            observedOrder.push("getting value");
        \\            return values[index++];
        \\          }
        \\        };
        \\      };
        \\    }
        \\  };
        \\}
        \\class MySetLike {
        \\  get size() {
        \\    observedOrder.push("getting size");
        \\    return {
        \\      valueOf: function() {
        \\        observedOrder.push("ToNumber(size)");
        \\        return 2;
        \\      }
        \\    };
        \\  }
        \\  get has() {
        \\    observedOrder.push("getting has");
        \\    return function() {
        \\      throw new Test262Error("union should not invoke has");
        \\    };
        \\  }
        \\  get keys() {
        \\    observedOrder.push("getting keys");
        \\    return function() {
        \\      observedOrder.push("calling keys");
        \\      return observableIterator();
        \\    };
        \\  }
        \\}
        \\var expectedOrder = [
        \\  "getting size",
        \\  "ToNumber(size)",
        \\  "getting has",
        \\  "getting keys",
        \\  "calling keys",
        \\  "getting next",
        \\  "calling next",
        \\  "getting done",
        \\  "getting value",
        \\  "calling next",
        \\  "getting done",
        \\  "getting value",
        \\  "calling next",
        \\  "getting done",
        \\  "getting value",
        \\  "calling next",
        \\  "getting done"
        \\];
        \\var combined = new Set(["a", "d"]).union(new MySetLike());
        \\assert.compareArray([...combined], ["a", "d", "b", "c"]);
        \\assert.compareArray(observedOrder, expectedOrder);
        \\var coercionCalls = 0;
        \\assert.throws(TypeError, function() {
        \\  new Set([1, 2]).union({
        \\    size: { valueOf: function() { coercionCalls++; return NaN; } },
        \\    has: function() {},
        \\    keys: function() { return observableIterator(); }
        \\  });
        \\});
        \\assert.sameValue(coercionCalls, 1);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Set.prototype.intersection consumes set-like keys as a direct iterator" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var log = [];
        \\var keysIterator = {};
        \\Object.defineProperty(keysIterator, Symbol.iterator, {
        \\  get: function() {
        \\    log.push("get @@iterator");
        \\    return function() { return keysIterator; };
        \\  }
        \\});
        \\Object.defineProperty(keysIterator, "next", {
        \\  get: function() {
        \\    log.push("get next");
        \\    return function() {
        \\      log.push("call next");
        \\      return { done: true };
        \\    };
        \\  }
        \\});
        \\var setLike = {
        \\  size: 0,
        \\  has: function() {
        \\    throw new Test262Error("intersection should not call has when other is smaller");
        \\  },
        \\  keys: function() {
        \\    log.push("call keys");
        \\    return keysIterator;
        \\  }
        \\};
        \\var result = new Set([1]).intersection(setLike);
        \\assert.compareArray([...result], []);
        \\assert.compareArray(log, ["call keys", "get next", "call next"]);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Set union methods copy receiver after reading set-like keys next" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function setLikeThatReplaces(set) {
        \\  return {
        \\    size: 0,
        \\    has: function() {
        \\      throw new Test262Error("set-like has should not be called");
        \\    },
        \\    keys: function() {
        \\      return {
        \\        get next() {
        \\          set.clear();
        \\          set.add(4);
        \\          return function() {
        \\            return { done: true };
        \\          };
        \\        }
        \\      };
        \\    }
        \\  };
        \\}
        \\var unionBase = new Set([1, 2, 3]);
        \\assert.compareArray([...unionBase.union(setLikeThatReplaces(unionBase))], [4]);
        \\var symmetricBase = new Set([1, 2, 3]);
        \\assert.compareArray([...symmetricBase.symmetricDifference(setLikeThatReplaces(symmetricBase))], [4]);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Set.prototype.difference has branch ignores entries appended by receiver mutation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var seen = [];
        \\var set = new Set([1, 2, 3, 4]);
        \\var setLike = {
        \\  size: 100,
        \\  has: function(value) {
        \\    seen.push(value);
        \\    if (seen.length === 1) {
        \\      set.clear();
        \\      set.add(11);
        \\      set.add(22);
        \\    }
        \\    return true;
        \\  },
        \\  keys: function() {
        \\    throw new Test262Error("difference should not call keys when other is larger");
        \\  }
        \\};
        \\assert.compareArray([...set.difference(setLike)], []);
        \\assert.compareArray([...set], [11, 22]);
        \\assert.compareArray(seen, [1, 2, 3, 4]);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "URI globals use observable string coercion and reject malformed UTF-8" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var object = {
        \\  valueOf: function() { return "^"; },
        \\  toString: function() { return " "; }
        \\};
        \\assert.sameValue(encodeURI(object), "%20");
        \\assert.sameValue(encodeURIComponent(object), "%20");
        \\assert.sameValue(decodeURI({ toString: function() { return "%5E"; } }), "^");
        \\assert.sameValue(decodeURIComponent({ toString: function() { return "%5E"; } }), "^");
        \\var originalFromCharCode = String.fromCharCode;
        \\String.fromCharCode = function() { return "patched"; };
        \\assert.sameValue(decodeURI("%F0%A0%80%80") === String.fromCharCode(0xD840, 0xDC00), false);
        \\String.fromCharCode = originalFromCharCode;
        \\var threw = false;
        \\try { decodeURIComponent("%ED%A0%80"); } catch (e) { threw = e instanceof URIError; }
        \\assert.sameValue(threw, true);
        \\assert.sameValue(encodeURI(), "undefined");
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "URI four byte decode range preserves globals and completion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function decimalToPercentHexString(n) {
        \\  var hex = "0123456789ABCDEF";
        \\  return "%" + hex[(n >> 4) & 0xf] + hex[n & 0xf];
        \\}
        \\var count = 0;
        \\for (var indexB3 = 0x80; indexB3 <= 0x80; indexB3++) {
        \\  var hexB1_B2_B3 = "%F0%A0" + decimalToPercentHexString(indexB3);
        \\  for (var indexB4 = 0x80; indexB4 <= 0x83; indexB4++) {
        \\    var hexB1_B2_B3_B4 = hexB1_B2_B3 + decimalToPercentHexString(indexB4);
        \\    var index = (0xF0 & 0x07) * 0x40000 + (0xA0 & 0x3F) * 0x1000 + (indexB3 & 0x3F) * 0x40 + (indexB4 & 0x3F);
        \\    var L = ((index - 0x10000) & 0x03FF) + 0xDC00;
        \\    var H = (((index - 0x10000) >> 10) & 0x03FF) + 0xD800;
        \\    if (decodeURIComponent(hexB1_B2_B3_B4) === String.fromCharCode(H, L)) count++;
        \\  }
        \\}
        \\assert.sameValue(count, 4);
        \\assert.sameValue(indexB3, 0x81);
        \\assert.sameValue(indexB4, 0x84);
        \\assert.sameValue(hexB1_B2_B3, "%F0%A0%80");
        \\assert.sameValue(hexB1_B2_B3_B4, "%F0%A0%80%83");
        \\assert.sameValue(index, 131075);
        \\assert.sameValue(H, 55360);
        \\assert.sameValue(L, 56323);
        \\assert.sameValue(eval(`
        \\function d(n) {
        \\  var hex = "0123456789ABCDEF";
        \\  return "%" + hex[(n >> 4) & 0xf] + hex[n & 0xf];
        \\}
        \\var c = 0;
        \\for (var b3 = 0x80; b3 <= 0x80; b3++) {
        \\  var h3 = "%F0%A0" + d(b3);
        \\  for (var b4 = 0x80; b4 <= 0x83; b4++) {
        \\    var h4 = h3 + d(b4);
        \\    var cp = (0xF0 & 0x07) * 0x40000 + (0xA0 & 0x3F) * 0x1000 + (b3 & 0x3F) * 0x40 + (b4 & 0x3F);
        \\    var lo = ((cp - 0x10000) & 0x03FF) + 0xDC00;
        \\    var hi = (((cp - 0x10000) >> 10) & 0x03FF) + 0xD800;
        \\    if (decodeURI(h4) === String.fromCharCode(hi, lo)) c++;
        \\  }
        \\}
        \\`), 3);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "URI decodeUriUnits walks latin1 and utf16 widths" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // ASCII-only "%XX" uses decodeStringDataFast. A leading non-ASCII
    // unit forces decodeUriUnits for both latin1 and utf16 storage.
    const result = try js.eval(
        \\assert.sameValue(decodeURI(String.fromCharCode(0xA0) + "%41"), String.fromCharCode(0xA0, 0x41));
        \\assert.sameValue(decodeURI(String.fromCharCode(0x100) + "%41"), String.fromCharCode(0x100, 0x41));
        \\assert.sameValue(decodeURI(String.fromCharCode(0xA0) + "%23"), String.fromCharCode(0xA0) + "%23");
        \\assert.sameValue(decodeURIComponent(String.fromCharCode(0xA0) + "%23"), String.fromCharCode(0xA0, 0x23));
        \\assert.sameValue(decodeURI(String.fromCharCode(0x100) + "%23"), String.fromCharCode(0x100) + "%23");
        \\assert.sameValue(decodeURIComponent(String.fromCharCode(0x100) + "%23"), String.fromCharCode(0x100, 0x23));
        \\assert.sameValue(
        \\  decodeURI(String.fromCharCode(0xA0) + "%F0%A0%80%80"),
        \\  String.fromCharCode(0xA0, 0xD840, 0xDC00)
        \\);
        \\var latin1Bad = false;
        \\try { decodeURI(String.fromCharCode(0xA0) + "%ZZ"); } catch (e) { latin1Bad = e instanceof URIError; }
        \\assert.sameValue(latin1Bad, true);
        \\var utf16Bad = false;
        \\try { decodeURI(String.fromCharCode(0x100) + "%ZZ"); } catch (e) { utf16Bad = e instanceof URIError; }
        \\assert.sameValue(utf16Bad, true);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "ArrayBuffer construct args share maxByteLength walk" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var ab = new ArrayBuffer(8, { maxByteLength: 16 });
        \\assert.sameValue(ab.byteLength, 8);
        \\assert.sameValue(ab.maxByteLength, 16);
        \\assert.sameValue(ab.resizable, true);
        \\assert.sameValue(ab instanceof ArrayBuffer, true);
        \\var sab = new SharedArrayBuffer(8, { maxByteLength: 16 });
        \\assert.sameValue(sab.byteLength, 8);
        \\assert.sameValue(sab.maxByteLength, 16);
        \\assert.sameValue(sab.growable, true);
        \\assert.sameValue(sab instanceof SharedArrayBuffer, true);
        \\assert.sameValue(sab instanceof ArrayBuffer, false);
        \\assert.sameValue(new ArrayBuffer(4).resizable, false);
        \\var abRange = false;
        \\try { new ArrayBuffer(8, { maxByteLength: 4 }); } catch (e) { abRange = e instanceof RangeError; }
        \\assert.sameValue(abRange, true);
        \\var sabRange = false;
        \\try { new SharedArrayBuffer(8, { maxByteLength: 4 }); } catch (e) { sabRange = e instanceof RangeError; }
        \\assert.sameValue(sabRange, true);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "destructured parameter default class keeps initialized parameter bindings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let f = ([cls = class {}, named = class Named {}]) => {
        \\  assert.sameValue(cls.name, "cls");
        \\  assert.sameValue(named.name, "Named");
        \\};
        \\f([]);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "top-level lexical destructuring reuses its predeclared global cells" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let { first } = { first: 1 };
        \\const [second] = [2];
        \\assert.sameValue(first, 1);
        \\assert.sameValue(second, 2);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "for-of var destructuring predeclares generic binding patterns" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var seen = 0;
        \\for (var [first = 23] of [[undefined]]) seen += first;
        \\for (var { value: second } of [{ value: 19 }]) seen += second;
        \\assert.sameValue(seen, 42);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "block function closures keep the current lexical binding cells" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function outer() {
        \\  {
        \\    let z = 4;
        \\    const v = 6;
        \\    function read() { return z + v; }
        \\    assert.sameValue(read(), 10);
        \\  }
        \\}
        \\outer();
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "nested assignment patterns preserve yield identifier and expression grammar" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var yield = "key";
        \\var direct = {};
        \\[[direct[yield]]] = [[22]];
        \\assert.sameValue(direct.key, 22);
        \\var suspended = {};
        \\var iterator = (function* () {
        \\  [[suspended[yield]]] = [[23]];
        \\})();
        \\assert.sameValue(iterator.next().done, false);
        \\assert.sameValue(suspended.key, undefined);
        \\assert.sameValue(iterator.next("key").done, true);
        \\assert.sameValue(suspended.key, 23);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "class field initializers inherit QuickJS arguments grammar" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\for (const source of [
        \\  "class C { static value = arguments; }",
        \\  "class C { static value = () => arguments; }",
        \\  "class C { value = arguments; }",
        \\]) {
        \\  let syntax = false;
        \\  try { eval(source); } catch (error) { syntax = error instanceof SyntaxError; }
        \\  assert.sameValue(syntax, true);
        \\}
        \\class Allowed { static method() { return arguments.length; } }
        \\assert.sameValue(Allowed.method(1, 2), 2);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "captured derived this binding can only be initialized once" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let callSuperAgain;
        \\class Base {}
        \\class Derived extends Base {
        \\  constructor() {
        \\    super();
        \\    callSuperAgain = () => super();
        \\  }
        \\}
        \\new Derived();
        \\assert.throws(ReferenceError, callSuperAgain);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "class name binding is in TDZ throughout its heritage expression" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\for (const source of [
        \\  "class Inner extends Inner {}",
        \\  "class Inner extends (Inner) {}",
        \\  "var Outer = class Inner extends Inner {}",
        \\]) {
        \\  assert.throws(ReferenceError, () => eval(source));
        \\}
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "class computed names observe the class name TDZ" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function expectComputedNameTdz(run) {
        \\  var threw = false;
        \\  try { run(); } catch (e) { threw = e instanceof ReferenceError; }
        \\  assert.sameValue(threw, true);
        \\}
        \\expectComputedNameTdz(() => { class C { [C]() {} } });
        \\expectComputedNameTdz(() => { var B = class C { [C]() {} }; });
        \\expectComputedNameTdz(() => { class C { static [C]() {} } });
        \\var named = class C { m() { return C; } };
        \\assert.sameValue(named.prototype.m(), named);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Array and String iterator prototypes inherit @@iterator from Iterator.prototype" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function expectIteratorChain(iterator) {
        \\  var proto1 = Object.getPrototypeOf(iterator);
        \\  var proto2 = Object.getPrototypeOf(proto1);
        \\  assert.sameValue(proto2.hasOwnProperty(Symbol.iterator), true);
        \\  assert.sameValue(proto1.hasOwnProperty(Symbol.iterator), false);
        \\  assert.sameValue(iterator.hasOwnProperty(Symbol.iterator), false);
        \\  assert.sameValue(iterator[Symbol.iterator](), iterator);
        \\}
        \\expectIteratorChain([][Symbol.iterator]());
        \\expectIteratorChain(""[Symbol.iterator]());
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "Object.assign writes through a proxy set trap" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var set = [];
        \\var p = new Proxy({}, { set: function (o, k, v) { set.push(k); o[k] = v; return true; }});
        \\Object.assign(p, { foo: 1, bar: 2 });
        \\assert.sameValue(set + "", "foo,bar");
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "String match and search Get a proxy matcher then ToPrimitive" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function expectWellKnownThenToPrimitive(run, wellKnown) {
        \\  var get = [];
        \\  var proxied = {};
        \\  proxied[Symbol.toPrimitive] = Function();
        \\  var p = new Proxy(proxied, { get: function (o, k) { get.push(k); return o[k]; }});
        \\  run(p);
        \\  assert.sameValue(get[0], wellKnown);
        \\  assert.sameValue(get[1], Symbol.toPrimitive);
        \\  assert.sameValue(get.length, 2);
        \\}
        \\expectWellKnownThenToPrimitive((p) => "".match(p), Symbol.match);
        \\expectWellKnownThenToPrimitive((p) => "".search(p), Symbol.search);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "class static blocks use their installed receiver as the super home object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function Parent() {}
        \\Parent.inherited = 42;
        \\let observed;
        \\class Child extends Parent {
        \\  static { observed = super.inherited; }
        \\}
        \\assert.sameValue(observed, 42);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "body function declarations reuse same-name parameter bindings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function declarationWins(x) {
        \\  assert.sameValue(typeof x, "function");
        \\  assert.sameValue(x(), 42);
        \\  function x() { return 42; }
        \\}
        \\declarationWins();
        \\function declarationWinsArguments(arguments) {
        \\  assert.sameValue(typeof arguments, "function");
        \\  function arguments() {}
        \\}
        \\declarationWinsArguments(1);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "parameter-expression and body environments classify body functions by recorded scope" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const f = (p = eval("var arguments = 'parameter'"), read = () => arguments) => {
        \\  function arguments() { return "body"; }
        \\  assert.sameValue(arguments(), "body");
        \\  assert.sameValue(read(), "parameter");
        \\};
        \\f();
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "eval source conversion combines valid UTF-16 surrogate pairs" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const rawUnicodePattern = eval(`/\uD83D\uDC38/u`);
        \\assert.sameValue(rawUnicodePattern.test("\u{1F438}"), true);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "invalid opcode reports invalid bytecode without context exception" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    helpers.registerStandardGlobalsBare(rt);
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var function = try helpers.makeUncheckedFunction(rt, &.{255});
    defer function.deinit(rt);
    try std.testing.expectError(error.InvalidBytecode, runFunction(rt, ctx, &function));
    try std.testing.expect(!ctx.hasException());
}

test "module top-level await works in object computed property names" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\let o = { [await 9]: 9 };
        \\assert.sameValue(o[await 9], 9);
        \\assert.sameValue(o[String(await 9)], 9);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "module top-level await works in class computed fields inside try" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\try {
        \\  let C = class {
        \\    [await 9] = 9;
        \\    static [await 9] = 9;
        \\  };
        \\  let c = new C();
        \\  assert.sameValue(c[await 9], 9);
        \\  assert.sameValue(C[await 9], 9);
        \\  assert.sameValue(c[String(await 9)], 9);
        \\  assert.sameValue(C[String(await 9)], 9);
        \\} catch (e) {
        \\  throw e;
        \\}
    );

    try std.testing.expect(result.is(.undefined_value));
}

fn fillOwnPropertyStorageForFailure(rt: *core.JSRuntime, object: *core.Object) !void {
    var index: usize = 0;
    while (object.shape_ref.prop_count < object.shape_ref.props().len or object.shape_ref.prop_count < object.shape_ref.props().len) : (index += 1) {
        if (index > 512) return error.TestUnexpectedResult;
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "fill_{d}", .{index});
        const atom_id = try rt.internAtom(name);
        try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(core.JSValue.int32(@intCast(index)), .all));
    }
}

test "Math.min/max and hasOwnProperty exec_direct arms keep the qjs semantics on the miss legs" {
    // Expected text generated by the pinned qjs yardstick
    // (/home/aneryu/quickjs-zjs-ref/qjs) on the same source: the number
    // fast leg (int32 / float64, NaN, signed zero) and every miss leg
    // (ToNumber on strings / booleans / nullish / objects, Symbol
    // TypeError; proxy trap, typed-array canonical index, primitive
    // receivers, arguments, key ToPrimitive, null receiver ordering).
    try helpers.expectPrints(
        \\var max = Math.max, min = Math.min;
        \\print(max(1, 7, 3), min(1, 7, 3), max(4), min(4), max(), min());
        \\print(max(1.5, 2, 0.25), min(1.5, 2, 0.25), max(2.0, 1), min(2.5, 3.5));
        \\print(max(1, NaN, 9), min(NaN, 2), max(1, 2, NaN));
        \\print(1 / max(-0, 0), 1 / min(0, -0), 1 / max(-0, -0), 1 / min(0, 0));
        \\print(max(1, "5", 2), min("3", 1), max(true, 0), min(null, 1), max(undefined, 1), min(1, undefined));
        \\var calls = [];
        \\var boxed = { valueOf: function() { calls.push("v"); return 8; } };
        \\print(max(1, boxed, 3), min(boxed, 1), calls.join(","));
        \\print(max(2147483647, 1), min(-2147483648, 0), max(1e300, 1), min(-1e300, 1));
        \\try { max(1, Symbol()); } catch (e) { print(e instanceof TypeError); }
        \\var o = { k: 1, 0: "zero" };
        \\print(o.hasOwnProperty("k"), o.hasOwnProperty("m"), o.hasOwnProperty(0), o.hasOwnProperty(1), o.hasOwnProperty("0"), o.hasOwnProperty(-1));
        \\print(o.hasOwnProperty("toString"), Object.prototype.hasOwnProperty("toString"), o.hasOwnProperty(), o.hasOwnProperty(undefined));
        \\var u = { undefined: 1 };
        \\print(u.hasOwnProperty(), u.hasOwnProperty("undefined"));
        \\var sym = Symbol("s");
        \\var so = {}; so[sym] = 1;
        \\print(so.hasOwnProperty(sym), o.hasOwnProperty(sym));
        \\var arr = [1, , 3];
        \\print(arr.hasOwnProperty(0), arr.hasOwnProperty(1), arr.hasOwnProperty(2), arr.hasOwnProperty("length"), arr.hasOwnProperty(3));
        \\print("abc".hasOwnProperty(1), "abc".hasOwnProperty(3), "abc".hasOwnProperty("length"), (5).hasOwnProperty("x"));
        \\var ta = new Uint8Array(2);
        \\print(ta.hasOwnProperty(0), ta.hasOwnProperty(1), ta.hasOwnProperty(2), ta.hasOwnProperty("-0"), ta.hasOwnProperty("1.5"));
        \\var trapped = [];
        \\var px = new Proxy({ a: 1 }, { getOwnPropertyDescriptor: function(t, k) { trapped.push(String(k)); return Reflect.getOwnPropertyDescriptor(t, k); } });
        \\print(px.hasOwnProperty("a"), px.hasOwnProperty("b"), trapped.join(","));
        \\var keyCalls = [];
        \\var key = { toString: function() { keyCalls.push("ts"); return "k"; } };
        \\print(o.hasOwnProperty(key), keyCalls.join(","));
        \\function f() { return arguments.hasOwnProperty(0) + "/" + arguments.hasOwnProperty(1) + "/" + arguments.hasOwnProperty("length"); }
        \\print(f(1));
        \\var getterHit = 0;
        \\var g = Object.defineProperty({}, "acc", { get: function() { getterHit++; return 1; }, configurable: true });
        \\print(g.hasOwnProperty("acc"), getterHit);
        \\try { Object.prototype.hasOwnProperty.call(null, "k"); } catch (e) { print(e instanceof TypeError); }
        \\try { Object.prototype.hasOwnProperty.call(undefined, "k"); } catch (e) { print(e instanceof TypeError); }
        \\var order = [];
        \\try { Object.prototype.hasOwnProperty.call(null, { toString: function() { order.push("key"); return "k"; } }); } catch (e) { order.push(e.constructor.name); }
        \\print(order.join(","));
        \\var big = {}; for (var i = 0; i < 40; i++) big["p" + i] = i;
        \\print(big.hasOwnProperty("p39"), big.hasOwnProperty("p40"), big.hasOwnProperty("p" + 7));
        \\print(Object.hasOwn(o, "k"), o.propertyIsEnumerable("k"));
    , "7 1 4 4 -Infinity Infinity\n" ++
        "2 0.25 2 2.5\n" ++
        "NaN NaN NaN\n" ++
        "Infinity -Infinity -Infinity Infinity\n" ++
        "5 1 1 0 NaN NaN\n" ++
        "8 1 v,v\n" ++
        "2147483647 -2147483648 1e+300 -1e+300\n" ++
        "true\n" ++
        "true false true false true false\n" ++
        "false true false false\n" ++
        "true true\n" ++
        "true false\n" ++
        "true false true true false\n" ++
        "true false true false\n" ++
        "true true false false false\n" ++
        "true false a,b\n" ++
        "true ts\n" ++
        "true/false/true\n" ++
        "true 0\n" ++
        "true\n" ++
        "true\n" ++
        "key,TypeError\n" ++
        "true false true\n" ++
        "true true\n");
}
