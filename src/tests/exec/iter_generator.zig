const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;
const op = engine.bytecode.opcode.op;

const helpers = @import("exec_helpers.zig");
const oom_helpers = @import("oom_helpers.zig");
const makeFunction = helpers.makeFunction;
const runFunction = helpers.runFunction;
test "typed array by-copy methods reject detached and invalid receivers" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var detachedBuffer = new ArrayBuffer(8);
        \\var detachedView = new Uint8Array(detachedBuffer, 0, 1);
        \\detachedBuffer.transfer();
        \\assert.throws(TypeError, function() { detachedView.toReversed(); });
        \\assert.throws(TypeError, function() { detachedView.toSorted(); });
        \\assert.throws(TypeError, function() { TypedArray.prototype.toReversed.call({ length: 1, 0: 1 }); });
        \\assert.throws(TypeError, function() { TypedArray.prototype.toSorted.call({ length: 1, 0: 1 }); });
        \\assert.throws(TypeError, function() { TypedArray.prototype.with.call({ length: 1, 0: 1 }, 0, 1); });
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array accessors reject non-typed-array receivers and float holes become NaN" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var getter = Object.getOwnPropertyDescriptor(TypedArray.prototype, "byteLength").get;
        \\assert.throws(TypeError, function() { getter.call(new ArrayBuffer(8)); });
        \\var floats = new Float32Array([0, 1, , 3, "4", undefined]);
        \\assert.sameValue(floats.at(2), NaN);
        \\assert.sameValue(floats.at(4), 4);
        \\assert.sameValue(floats.at(5), NaN);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array intrinsic species accessor is installed" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var desc = Object.getOwnPropertyDescriptor(TypedArray, Symbol.species);
        \\assert.sameValue(desc.set, undefined);
        \\assert.sameValue(typeof desc.get, "function");
        \\assert.sameValue(desc.enumerable, false);
        \\assert.sameValue(desc.configurable, true);
        \\assert.sameValue(desc.get.length, 0);
        \\assert.sameValue(desc.get.name, "get [Symbol.species]");
        \\assert.sameValue(Object.hasOwn(desc.get, "call"), false);
        \\var marker = {};
        \\assert.sameValue(desc.get.call(marker), marker);
        \\assert.sameValue(Object.hasOwn(Uint8Array, Symbol.species), false);
        \\assert.sameValue(Object.hasOwn(Float16Array, Symbol.species), false);
        \\assert.sameValue(Uint8Array[Symbol.species], Uint8Array);
        \\assert.sameValue(Float16Array[Symbol.species], Float16Array);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "species accessors inherit Function.prototype.call" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\for (var C of [Promise, Map, Set, TypedArray]) {
        \\  var getter = Object.getOwnPropertyDescriptor(C, Symbol.species).get;
        \\  assert.sameValue(Object.hasOwn(getter, "call"), false);
        \\  assert.sameValue(getter.call(C), C);
        \\}
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array intrinsic length and invocation semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var desc = Object.getOwnPropertyDescriptor(TypedArray, "length");
        \\assert.sameValue(desc.value, 0);
        \\assert.sameValue(desc.writable, false);
        \\assert.sameValue(desc.enumerable, false);
        \\assert.sameValue(desc.configurable, true);
        \\assert.throws(TypeError, function() { TypedArray(); });
        \\assert.throws(TypeError, function() { new TypedArray(); });
        \\assert.throws(TypeError, function() { TypedArray(1); });
        \\assert.throws(TypeError, function() { new TypedArray(1); });
        \\assert.throws(TypeError, function() { TypedArray(new Int8Array(4)); });
        \\assert.throws(TypeError, function() { new TypedArray(new ArrayBuffer(4)); });
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "ArrayBuffer slice uses relative integer offsets" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var buffer = new ArrayBuffer(8);
        \\assert.sameValue(buffer.slice(-5, 6).byteLength, 3);
        \\assert.sameValue(buffer.slice(-12, 6).byteLength, 6);
        \\assert.sameValue(buffer.slice(-Infinity, 6).byteLength, 6);
        \\assert.sameValue(buffer.slice(2, -4).byteLength, 2);
        \\assert.sameValue(buffer.slice(2, -10).byteLength, 0);
        \\assert.sameValue(buffer.slice(2, -Infinity).byteLength, 0);
        \\assert.sameValue(buffer.slice(6, undefined).byteLength, 2);
        \\assert.sameValue(buffer.slice(10, 8).byteLength, 0);
        \\assert.sameValue(buffer.slice(0x100000000, 7).byteLength, 0);
        \\assert.sameValue(buffer.slice(+Infinity, 6).byteLength, 0);
        \\assert.sameValue(buffer.slice(1, 12).byteLength, 7);
        \\assert.sameValue(buffer.slice(2, 0x100000000).byteLength, 6);
        \\assert.sameValue(buffer.slice(3, +Infinity).byteLength, 5);
        \\var log = "";
        \\buffer.slice({
        \\    valueOf: function() {
        \\        log += "start-";
        \\        return 0;
        \\    }
        \\}, {
        \\    valueOf: function() {
        \\        log += "end";
        \\        return 8;
        \\    }
        \\});
        \\assert.sameValue(log, "start-end");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "ArrayBuffer slice honors species constructor and result validation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var replacement;
        \\var speciesConstructor = {};
        \\speciesConstructor[Symbol.species] = function(length) {
        \\    replacement = new ArrayBuffer(length);
        \\    return replacement;
        \\};
        \\var buffer = new ArrayBuffer(8);
        \\buffer.constructor = speciesConstructor;
        \\assert.sameValue(buffer.slice(), replacement);
        \\
        \\speciesConstructor[Symbol.species] = function() { return {}; };
        \\assert.throws(TypeError, function() { buffer.slice(); });
        \\speciesConstructor[Symbol.species] = function() { return buffer; };
        \\assert.throws(TypeError, function() { buffer.slice(); });
        \\speciesConstructor[Symbol.species] = function() { return new ArrayBuffer(4); };
        \\assert.throws(TypeError, function() { buffer.slice(); });
        \\speciesConstructor[Symbol.species] = function() { return new ArrayBuffer(10); };
        \\assert.sameValue(buffer.slice().byteLength, 10);
        \\
        \\speciesConstructor[Symbol.species] = {};
        \\assert.throws(TypeError, function() { buffer.slice(); });
        \\buffer.constructor = 1;
        \\assert.throws(TypeError, function() { buffer.slice(); });
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "ArrayBuffer constructor uses ToIndex and maxByteLength option ordering" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var valueOfCalls = 0;
        \\var buffer = new ArrayBuffer({
        \\    valueOf: function() {
        \\        valueOfCalls += 1;
        \\        return 42;
        \\    }
        \\});
        \\assert.sameValue(buffer.byteLength, 42);
        \\assert.sameValue(valueOfCalls, 1);
        \\
        \\var toStringCalls = 0;
        \\buffer = new ArrayBuffer({
        \\    toString: function() {
        \\        toStringCalls += 1;
        \\        return "7";
        \\    }
        \\});
        \\assert.sameValue(buffer.byteLength, 7);
        \\assert.sameValue(toStringCalls, 1);
        \\
        \\assert.throws(Test262Error, function() {
        \\    new ArrayBuffer({
        \\        valueOf: function() {
        \\            throw new Test262Error();
        \\        }
        \\    });
        \\});
        \\
        \\assert.throws(Test262Error, function() {
        \\    new ArrayBuffer(0, {
        \\        get maxByteLength() {
        \\            throw new Test262Error();
        \\        }
        \\    });
        \\});
        \\assert.throws(RangeError, function() {
        \\    new ArrayBuffer(10, { maxByteLength: 0 });
        \\});
        \\
        \\function DummyError() {}
        \\var newTarget = Object.defineProperty(function(){}.bind(null), "prototype", {
        \\    get: function() {
        \\        throw new DummyError();
        \\    }
        \\});
        \\assert.throws(RangeError, function() {
        \\    Reflect.construct(ArrayBuffer, [10, { maxByteLength: 0 }], newTarget);
        \\});
        \\assert.throws(DummyError, function() {
        \\    Reflect.construct(ArrayBuffer, [7 * 1125899906842624], newTarget);
        \\});
        \\assert.throws(RangeError, function() {
        \\    new ArrayBuffer(7 * 1125899906842624);
        \\});
        \\assert.throws(RangeError, function() {
        \\    new ArrayBuffer(9007199254740992 - 1);
        \\});
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "ArrayBuffer resize and transfer coerce new lengths through valueOf before toString" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function badLength(log) {
        \\    return {
        \\        valueOf: function() {
        \\            log.push("valueOf");
        \\            return {};
        \\        },
        \\        toString: function() {
        \\            log.push("toString");
        \\            return {};
        \\        }
        \\    };
        \\}
        \\
        \\var resizeLog = [];
        \\var resizable = new ArrayBuffer(0, { maxByteLength: 4 });
        \\assert.throws(TypeError, function() { resizable.resize(badLength(resizeLog)); });
        \\assert.sameValue(resizeLog.join(","), "valueOf,toString");
        \\
        \\var transferLog = [];
        \\var fixed = new ArrayBuffer(0);
        \\assert.throws(TypeError, function() { fixed.transfer(badLength(transferLog)); });
        \\assert.sameValue(transferLog.join(","), "valueOf,toString");
        \\
        \\var fixedLengthLog = [];
        \\var fixedAgain = new ArrayBuffer(0);
        \\assert.throws(TypeError, function() { fixedAgain.transferToFixedLength(badLength(fixedLengthLog)); });
        \\assert.sameValue(fixedLengthLog.join(","), "valueOf,toString");
        \\
        \\var growLog = [];
        \\var growable = new SharedArrayBuffer(0, { maxByteLength: 4 });
        \\assert.throws(TypeError, function() { growable.grow(badLength(growLog)); });
        \\assert.sameValue(growLog.join(","), "valueOf,toString");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "global parseInt and parseFloat use observable string and radix coercion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    assert.sameValue(parseInt("\u00A01"), 1);
        \\    assert.sameValue(Number.parseInt("\u00A0-1"), -1);
        \\
        \\    var log = [];
        \\    var input = {
        \\        toString: function() {
        \\            log.push("toString");
        \\            return "11";
        \\        },
        \\        valueOf: function() {
        \\            log.push("valueOf");
        \\            return "10";
        \\        }
        \\    };
        \\    var radix = {
        \\        valueOf: function() {
        \\            log.push("radix.valueOf");
        \\            return 2;
        \\        },
        \\        toString: function() {
        \\            log.push("radix.toString");
        \\            return 10;
        \\        }
        \\    };
        \\    assert.sameValue(parseInt(input, radix), 3);
        \\    assert.sameValue(log.join(","), "toString,radix.valueOf");
        \\
        \\    assert.sameValue(parseFloat({ toString: function() { return "1.5x"; }, valueOf: function() { return "7"; } }), 1.5);
        \\    assert.throws(TypeError, function() {
        \\        Number.parseFloat({ toString: function() { return {}; }, valueOf: function() { return {}; } });
        \\    });
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "global and Number parse aliases stay realm-local under lazy materialization" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var r1 = $262.createRealm().global;
        \\    var r2 = $262.createRealm().global;
        \\    assert.sameValue(r1.parseInt, r1.Number.parseInt);
        \\    assert.sameValue(r2.Number.parseInt, r2.parseInt);
        \\    assert.sameValue(r1.parseInt === r2.Number.parseInt, false);
        \\
        \\    var r3 = $262.createRealm().global;
        \\    r3.parseInt = function() { return 99; };
        \\    assert.sameValue(r3.Number.parseInt("10"), 10);
        \\    assert.sameValue(r3.Number.parseInt === r3.parseInt, false);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Reflect namespace materializes lazily with realm-local functions" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var desc = Object.getOwnPropertyDescriptor(globalThis, "Reflect");
        \\    assert.sameValue(desc.writable, true);
        \\    assert.sameValue(desc.enumerable, false);
        \\    assert.sameValue(desc.configurable, true);
        \\    assert.sameValue(typeof desc.value, "object");
        \\    assert.sameValue(Object.prototype.toString.call(Reflect), "[object Reflect]");
        \\
        \\    var applyDesc = Object.getOwnPropertyDescriptor(Reflect, "apply");
        \\    assert.sameValue(applyDesc.writable, true);
        \\    assert.sameValue(applyDesc.enumerable, false);
        \\    assert.sameValue(applyDesc.configurable, true);
        \\    assert.sameValue(applyDesc.value.length, 3);
        \\    assert.sameValue(Object.getPrototypeOf(applyDesc.value), Function.prototype);
        \\    assert.sameValue(Reflect.apply(function(a, b) { return a + b; }, null, [2, 3]), 5);
        \\    assert.sameValue(Reflect.setPrototypeOf({}, null), true);
        \\    assert.sameValue(Reflect.defineProperty({}, "x", { value: 1 }), true);
        \\
        \\    var r1 = $262.createRealm().global;
        \\    var r2 = $262.createRealm().global;
        \\    assert.sameValue(Object.getPrototypeOf(r1.Reflect.apply), r1.Function.prototype);
        \\    assert.sameValue(Object.getPrototypeOf(r2.Reflect.apply), r2.Function.prototype);
        \\    assert.sameValue(r1.Reflect.apply === r2.Reflect.apply, false);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "String match and search fall back through RegExpCreate and well-known invoke" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var matchLog = [];
        \\    var matcher = {
        \\        toString: function() {
        \\            matchLog.push("toString");
        \\            return "\\d";
        \\        }
        \\    };
        \\    matcher[Symbol.match] = null;
        \\    assert.sameValue("ab3c".match(matcher)[0], "3");
        \\    assert.sameValue(matchLog.join(","), "toString");
        \\
        \\    var originalMatch = RegExp.prototype[Symbol.match];
        \\    var seenThis;
        \\    try {
        \\        RegExp.prototype[Symbol.match] = function(value) {
        \\            seenThis = this;
        \\            assert.sameValue(value, "target");
        \\            return "custom";
        \\        };
        \\        assert.sameValue("target".match("source"), "custom");
        \\        assert.sameValue(seenThis instanceof RegExp, true);
        \\        assert.sameValue(seenThis.source, "source");
        \\    } finally {
        \\        RegExp.prototype[Symbol.match] = originalMatch;
        \\    }
        \\
        \\    var searcher = { toString: function() { return "\\d"; } };
        \\    searcher[Symbol.search] = null;
        \\    assert.sameValue("ab3c".search(searcher), 2);
        \\    assert.sameValue("--undefined--".search(), 0);
        \\
        \\    var calls = 0;
        \\    var replacement = { toString: function() { calls += 1; return "b"; } };
        \\    assert.sameValue("".replace("a", replacement), "");
        \\    assert.sameValue(calls, 1);
        \\    assert.sameValue("o\u0308".localeCompare("ö"), 0);
        \\    assert.sameValue("Å".localeCompare("A\u030A"), 0);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "String prototype is a String object and toString valueOf reject non-strings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    assert.sameValue(String.prototype == "", true);
        \\    assert.sameValue(Object.prototype.isPrototypeOf(String.prototype), true);
        \\    var stringToString = String.prototype.toString;
        \\    var stringValueOf = String.prototype.valueOf;
        \\    assert.sameValue(stringToString.call("abc"), "abc");
        \\    assert.sameValue(stringValueOf.call(new String("abc")), "abc");
        \\    assert.sameValue(String.prototype.charAt.call("ABC", -1), "");
        \\    assert.sameValue(String.prototype.charAt.call({ toString: function() { return "ABC"; } }, -1), "");
        \\    assert.throws(TypeError, function() { stringToString.call(false); });
        \\    assert.throws(TypeError, function() { stringToString.call({ toString: function() { return "x"; } }); });
        \\    assert.throws(TypeError, function() { stringValueOf.call(1); });
        \\    assert.throws(TypeError, function() { stringValueOf.call(["x"]); });
        \\    assert.throws(Test262Error, function() {
        \\        String.prototype[Symbol.iterator].call({
        \\            toString: function() { throw new Test262Error(); }
        \\        });
        \\    });
        \\    assert.throws(TypeError, function() { String.prototype[Symbol.iterator].call(null); });
        \\    assert.throws(TypeError, function() { String.prototype[Symbol.iterator].call(undefined); });
        \\
        \\    delete String.prototype.toString;
        \\    assert.sameValue(String.prototype.toString(), "[object String]");
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "ArrayBuffer immutable transfer methods preserve required coercion ordering" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var buffer = new ArrayBuffer(4);
        \\var immutable = buffer.transferToImmutable();
        \\assert.sameValue(buffer.detached, true);
        \\assert.sameValue(immutable.byteLength, 4);
        \\assert.throws(TypeError, function() { immutable.transfer(); });
        \\
        \\var resizeCalls = [];
        \\assert.throws(TypeError, function() {
        \\    immutable.resize({
        \\        valueOf: function() {
        \\            resizeCalls.push("resize");
        \\            return 0;
        \\        }
        \\    });
        \\});
        \\assert.sameValue(resizeCalls.join(","), "");
        \\
        \\var transferCalls = [];
        \\assert.throws(TypeError, function() {
        \\    immutable.transfer({
        \\        valueOf: function() {
        \\            transferCalls.push("transfer");
        \\            return 1;
        \\        }
        \\    });
        \\});
        \\assert.sameValue(transferCalls.join(","), "transfer");
        \\
        \\var fixedCalls = [];
        \\assert.throws(TypeError, function() {
        \\    immutable.transferToFixedLength({
        \\        valueOf: function() {
        \\            fixedCalls.push("fixed");
        \\            return 1;
        \\        }
        \\    });
        \\});
        \\assert.sameValue(fixedCalls.join(","), "fixed");
        \\
        \\var transferToImmutableCalls = [];
        \\assert.throws(TypeError, function() {
        \\    immutable.transferToImmutable({
        \\        valueOf: function() {
        \\            transferToImmutableCalls.push("transferToImmutable");
        \\            return 1;
        \\        }
        \\    });
        \\});
        \\assert.sameValue(transferToImmutableCalls.join(","), "transferToImmutable");
        \\
        \\var resizableForFixed = new ArrayBuffer(4, { maxByteLength: 8 });
        \\var fixedBeyondMax = resizableForFixed.transferToFixedLength(9);
        \\assert.sameValue(resizableForFixed.detached, true);
        \\assert.sameValue(fixedBeyondMax.byteLength, 9);
        \\assert.sameValue(fixedBeyondMax.resizable, false);
        \\assert.sameValue(fixedBeyondMax.maxByteLength, 9);
        \\
        \\var original = new ArrayBuffer(4);
        \\var copy = original.sliceToImmutable(1, 3);
        \\assert.sameValue(original.detached, false);
        \\assert.sameValue(copy.byteLength, 2);
        \\var sliceCalls = [];
        \\assert.throws(TypeError, function() {
        \\    copy.slice({
        \\        valueOf: function() {
        \\            sliceCalls.push("slice");
        \\            return 0;
        \\        }
        \\    }, 1);
        \\});
        \\assert.sameValue(sliceCalls.join(","), "");
        \\assert.throws(TypeError, function() {
        \\    copy.sliceToImmutable({
        \\        valueOf: function() {
        \\            sliceCalls.push("sliceToImmutable");
        \\            return 0;
        \\        }
        \\    }, 1);
        \\});
        \\assert.sameValue(sliceCalls.join(","), "");
        \\var detachedForSlice = new ArrayBuffer(4);
        \\detachedForSlice.transfer();
        \\assert.throws(TypeError, function() {
        \\    detachedForSlice.slice({
        \\        valueOf: function() {
        \\            sliceCalls.push("detached");
        \\            return 0;
        \\        }
        \\    }, 1);
        \\});
        \\assert.sameValue(sliceCalls.join(","), "");
        \\var detachedSpeciesSource = new ArrayBuffer(4);
        \\detachedSpeciesSource.constructor = {
        \\    [Symbol.species]: function(length) {
        \\        var out = new ArrayBuffer(length);
        \\        out.transfer();
        \\        return out;
        \\    }
        \\};
        \\assert.throws(TypeError, function() { detachedSpeciesSource.slice(0, 0); });
        \\var detachedResizable = new ArrayBuffer(4, { maxByteLength: 8 });
        \\detachedResizable.transfer();
        \\var resizeCalls = [];
        \\assert.throws(TypeError, function() {
        \\    detachedResizable.resize({
        \\        valueOf: function() {
        \\            resizeCalls.push("resize");
        \\            return 2;
        \\        }
        \\    });
        \\});
        \\assert.sameValue(resizeCalls.join(","), "resize");
        \\var protoCheck = original.sliceToImmutable(0, 1);
        \\var copyPrototype = {};
        \\assert.sameValue(Reflect.setPrototypeOf(protoCheck, copyPrototype), true);
        \\assert.sameValue(Object.getPrototypeOf(protoCheck), copyPrototype);
        \\var view = new DataView(copy);
        \\var setCalls = [];
        \\assert.throws(TypeError, function() {
        \\    view.setUint8({
        \\        valueOf: function() {
        \\            setCalls.push("offset");
        \\            return 0;
        \\        }
        \\    }, 1);
        \\});
        \\assert.sameValue(setCalls.join(","), "");
        \\
        \\var typed = new Uint8Array(copy);
        \\var indexedSetCalls = [];
        \\assert.sameValue(Reflect.set(typed, "0", {
        \\    valueOf: function() {
        \\        indexedSetCalls.push("reflect");
        \\        return 7;
        \\    }
        \\}), false);
        \\assert.sameValue(indexedSetCalls.join(","), "reflect");
        \\typed[0] = {
        \\    valueOf: function() {
        \\            indexedSetCalls.push("assign");
        \\            return 7;
        \\        }
        \\};
        \\assert.sameValue(indexedSetCalls.join(","), "reflect,assign");
        \\assert.sameValue(Reflect.set(typed, "100", {
        \\    valueOf: function() {
        \\        indexedSetCalls.push("reflect-oob");
        \\        return 8;
        \\    }
        \\}), true);
        \\typed[100] = {
        \\    valueOf: function() {
        \\            indexedSetCalls.push("assign-oob");
        \\            return 8;
        \\        }
        \\};
        \\assert.sameValue(indexedSetCalls.join(","), "reflect,assign,reflect-oob,assign-oob");
        \\assert.sameValue(typed[0], 0);
        \\var big = new BigInt64Array(new ArrayBuffer(8).transferToImmutable());
        \\assert.throws(SyntaxError, function() {
        \\    Reflect.set(big, "100", {
        \\        valueOf: function() {
        \\            return "not a bigint";
        \\        }
        \\    });
        \\});
        \\
        \\var defineCalls = [];
        \\assert.throws(TypeError, function() {
        \\    Object.defineProperty(typed, "0", {
        \\        value: {
        \\            valueOf: function() {
        \\                defineCalls.push("define");
        \\                return 9;
        \\            }
        \\        }
        \\    });
        \\});
        \\assert.sameValue(defineCalls.join(","), "");
        \\assert.sameValue(typed[0], 0);
        \\
        \\var speciesConstructor = {};
        \\speciesConstructor[Symbol.species] = function() { return original.sliceToImmutable(); };
        \\original.constructor = speciesConstructor;
        \\assert.throws(TypeError, function() { original.slice(); });
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "array and typed array iterators share ArrayIteratorPrototype and validate typed array receivers" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var ta = new Uint8Array([1, 2, 3]);
        \\    var valueIter = ta.values();
        \\    assert.sameValue(valueIter.next().value, 1);
        \\    var keyIter = ta.keys();
        \\    assert.sameValue(keyIter.next().value, 0);
        \\    var entryIter = ta.entries();
        \\    assert.sameValue(entryIter.next().value[1], 1);
        \\    var rab = new ArrayBuffer(4, { maxByteLength: 5 });
        \\    var fixed = new Uint8Array(rab, 1, 2);
        \\    rab.resize(2);
        \\    assert.throws(TypeError, function() { fixed.values(); });
        \\    var iter = Array.prototype.values.call(fixed);
        \\    assert.throws(TypeError, function() { iter.next(); });
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array set coerces primitive sources and reads array-like values lazily" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var ta = new Uint8Array([1, 2, 3, 4, 5]);
        \\    ta.set("678", 1);
        \\    assert.sameValue(ta[0], 1);
        \\    assert.sameValue(ta[1], 6);
        \\    assert.sameValue(ta[2], 7);
        \\    assert.sameValue(ta[3], 8);
        \\    assert.sameValue(ta[4], 5);
        \\
        \\    var sample = new Uint8Array(5);
        \\    var obj = { length: 5, 1: 7, 2: 7, 3: 7, 4: 7 };
        \\    Object.defineProperty(obj, 0, {
        \\        get: function() {
        \\            obj[1] = 43;
        \\            obj[2] = 44;
        \\            obj[3] = 45;
        \\            obj[4] = 46;
        \\            return 42;
        \\        }
        \\    });
        \\    sample.set(obj);
        \\    assert.sameValue(sample[0], 42);
        \\    assert.sameValue(sample[1], 43);
        \\    assert.sameValue(sample[2], 44);
        \\    assert.sameValue(sample[3], 45);
        \\    assert.sameValue(sample[4], 46);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array set applies Uint8Clamped conversion for array-like and typed sources" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var clamped = new Uint8ClampedArray([1, 1, 1, 1, 1]);
        \\    clamped.set([256, -1, 0.5, 0.50000001, Infinity]);
        \\    assert.sameValue(clamped[0], 255);
        \\    assert.sameValue(clamped[1], 0);
        \\    assert.sameValue(clamped[2], 0);
        \\    assert.sameValue(clamped[3], 1);
        \\    assert.sameValue(clamped[4], 255);
        \\
        \\    var fromFloat64 = new Uint8ClampedArray([0, 0, 0]);
        \\    fromFloat64.set(new Float64Array([65536, -127, 0.6]));
        \\    assert.sameValue(fromFloat64[0], 255);
        \\    assert.sameValue(fromFloat64[1], 0);
        \\    assert.sameValue(fromFloat64[2], 1);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array copyWithin validates receivers and preserves float payload bytes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    assert.throws(TypeError, function() {
        \\        TypedArray.prototype.copyWithin.call({ length: 3, 0: 1, 1: 2, 2: 3 }, 1, 0);
        \\    });
        \\
        \\    var buffer = new ArrayBuffer(8);
        \\    var bytes = new Uint8Array(buffer);
        \\    bytes.set([0, 0, 192, 127, 1, 2, 3, 4]);
        \\    var floats = new Float32Array(buffer);
        \\    floats.copyWithin(1, 0, 1);
        \\    assert.sameValue(bytes[4], bytes[0]);
        \\    assert.sameValue(bytes[5], bytes[1]);
        \\    assert.sameValue(bytes[6], bytes[2]);
        \\    assert.sameValue(bytes[7], bytes[3]);
        \\
        \\    var rab = new ArrayBuffer(4, { maxByteLength: 16 });
        \\    var fixed = new Uint8Array(rab, 0, 4);
        \\    fixed.set([0, 1, 2, 3]);
        \\    assert.throws(TypeError, function() {
        \\        fixed.copyWithin({ valueOf: function() { rab.resize(2); return 2; } }, 0, 1);
        \\    });
        \\
        \\    rab.resize(4);
        \\    var tracking = new Uint8Array(rab);
        \\    tracking.set([0, 1, 2, 3]);
        \\    var growTarget = {
        \\        valueOf: function() {
        \\            rab.resize(6);
        \\            tracking[4] = 4;
        \\            tracking[5] = 5;
        \\            return 0;
        \\        }
        \\    };
        \\    tracking.copyWithin(growTarget, 2);
        \\    assert.sameValue(tracking.length, 6);
        \\    assert.sameValue(tracking[0], 2);
        \\    assert.sameValue(tracking[1], 3);
        \\    assert.sameValue(tracking[2], 2);
        \\    assert.sameValue(tracking[3], 3);
        \\    assert.sameValue(tracking[4], 4);
        \\    assert.sameValue(tracking[5], 5);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array fill coerces once and revalidates after side effects" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    assert.throws(TypeError, function() {
        \\        TypedArray.prototype.fill.call({ length: 2, 0: 1, 1: 2 }, 0);
        \\    });
        \\
        \\    var big = new BigInt64Array(2);
        \\    var next = 1n;
        \\    big.fill({ valueOf: function() { return next++; } });
        \\    assert.sameValue(next, 2n);
        \\    assert.sameValue(big[0], 1n);
        \\    assert.sameValue(big[1], 1n);
        \\
        \\    var rab = new ArrayBuffer(4, { maxByteLength: 8 });
        \\    var fixed = new Uint8Array(rab, 0, 4);
        \\    assert.throws(TypeError, function() {
        \\        fixed.fill(3, { valueOf: function() { rab.resize(2); return 1; } }, 3);
        \\    });
        \\
        \\    rab.resize(4);
        \\    var tracking = new Uint8Array(rab);
        \\    tracking.fill({ valueOf: function() { rab.resize(2); return 7; } });
        \\    assert.sameValue(tracking.length, 2);
        \\    assert.sameValue(tracking[0], 7);
        \\    assert.sameValue(tracking[1], 7);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array subarray passes species arguments and validates result type" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var fixed = new Uint8Array([40, 41, 42]);
        \\    var fixedArgs;
        \\    fixed.constructor = {};
        \\    fixed.constructor[Symbol.species] = function(buffer, offset, length) {
        \\        fixedArgs = Array.prototype.slice.call(arguments);
        \\        return new Uint8Array(buffer, offset, length);
        \\    };
        \\    var fixedResult = fixed.subarray(1);
        \\    assert.sameValue(fixedArgs.length, 3);
        \\    assert.sameValue(fixedArgs[0], fixed.buffer);
        \\    assert.sameValue(fixedArgs[1], 1);
        \\    assert.sameValue(fixedArgs[2], 2);
        \\    assert.sameValue(fixedResult[0], 41);
        \\
        \\    var trackBuffer = new ArrayBuffer(4, { maxByteLength: 8 });
        \\    var tracking = new Uint8Array(trackBuffer, 0);
        \\    var trackingArgs;
        \\    tracking.constructor = {};
        \\    tracking.constructor[Symbol.species] = function(buffer, offset) {
        \\        trackingArgs = Array.prototype.slice.call(arguments);
        \\        return new Uint8Array(buffer, offset);
        \\    };
        \\    tracking.subarray(1);
        \\    assert.sameValue(trackingArgs.length, 2);
        \\    assert.sameValue(trackingArgs[0], trackBuffer);
        \\    assert.sameValue(trackingArgs[1], 1);
        \\
        \\    fixed.constructor[Symbol.species] = function() { return {}; };
        \\    assert.throws(TypeError, function() { fixed.subarray(0); });
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array map and filter honor species timing" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var filterSample = new Uint8Array([1, 2]);
        \\    var filterCalls = 0;
        \\    var constructorAfterCallbacks = false;
        \\    Object.defineProperty(filterSample, "constructor", {
        \\        get: function() {
        \\            constructorAfterCallbacks = filterCalls === 2;
        \\            return {
        \\                [Symbol.species]: function() {
        \\                    return new Uint8Array(2);
        \\                }
        \\            };
        \\        }
        \\    });
        \\    var filtered = filterSample.filter(function() {
        \\        filterCalls++;
        \\        return true;
        \\    });
        \\    assert.sameValue(filterCalls, 2);
        \\    assert.sameValue(constructorAfterCallbacks, true);
        \\    assert.sameValue(filtered.length, 2);
        \\    assert.sameValue(filtered[0], 1);
        \\    assert.sameValue(filtered[1], 2);
        \\
        \\    var mapSample = new Uint8Array([1, 2]);
        \\    mapSample.constructor = {
        \\        [Symbol.species]: function() {
        \\            return new Uint8Array(2);
        \\        }
        \\    };
        \\    var mapped = mapSample.map(function(v) { return v + 1; });
        \\    assert.sameValue(Uint8Array[Symbol.species], Uint8Array);
        \\    assert.sameValue(mapped.length, 2);
        \\    assert.sameValue(mapped[0], 2);
        \\    assert.sameValue(mapped[1], 3);
        \\
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array search reduce and reverse basic semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var sample = new Uint8Array([0, 1, 2, 1]);
        \\    assert.sameValue(sample.includes(2), true);
        \\    assert.sameValue(sample.indexOf(1), 1);
        \\    assert.sameValue(sample.lastIndexOf(1), 3);
        \\
        \\    var seen = [];
        \\    sample.reduce(function(prev, next, index) {
        \\        seen.push(next);
        \\        return prev + next + index;
        \\    }, 0);
        \\    assert.sameValue(seen.length, 4);
        \\    assert.sameValue(seen[0], 0);
        \\    assert.sameValue(seen[1], 1);
        \\    assert.sameValue(seen[2], 2);
        \\    assert.sameValue(seen[3], 1);
        \\
        \\    sample.reverse();
        \\    assert.sameValue(sample[0], 1);
        \\    assert.sameValue(sample[1], 2);
        \\    assert.sameValue(sample[2], 1);
        \\    assert.sameValue(sample[3], 0);
        \\
        \\    var detachSample = new Uint8Array([5, 6]);
        \\    var detachSeen = [];
        \\    detachSample.reduce(function(prev, next, index) {
        \\        if (index === 0) detachSample.buffer.transfer();
        \\        detachSeen.push(String(next));
        \\        return prev;
        \\    }, 0);
        \\    assert.sameValue(detachSeen.join(","), "5,undefined");
        \\
        \\    var rab = new ArrayBuffer(4, { maxByteLength: 4 });
        \\    var resized = new Uint8Array(rab);
        \\    resized.set([0, 2, 4, 6]);
        \\    var resizeSeen = [];
        \\    resized.reduceRight(function(prev, next, index) {
        \\        if (index === 3) rab.resize(2);
        \\        resizeSeen.push(String(next));
        \\        return prev;
        \\    }, 0);
        \\    assert.sameValue(resizeSeen.join(","), "6,undefined,2,0");
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array iteration methods preserve live writes and fixed initial length" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var sample = new Uint8Array([42, 43, 44]);
        \\    var nextValue = 0;
        \\    sample.every(function(value, index) {
        \\        if (index > 0) {
        \\            assert.sameValue(sample[index - 1], nextValue - 1);
        \\            assert.sameValue(Reflect.set(sample, 0, 7), true);
        \\        }
        \\        assert.sameValue(Reflect.set(sample, index, nextValue), true);
        \\        nextValue += 1;
        \\        return true;
        \\    });
        \\    assert.sameValue(sample[0], 7);
        \\    assert.sameValue(sample[1], 1);
        \\    assert.sameValue(sample[2], 2);
        \\
        \\    var rab = new ArrayBuffer(4, { maxByteLength: 4 });
        \\    var tracking = new Uint8Array(rab);
        \\    tracking.set([0, 2, 4, 6]);
        \\    var seen = [];
        \\    var found = tracking.findIndex(function(value, index) {
        \\        if (index === 1) rab.resize(2);
        \\        seen.push(String(value));
        \\        return value === undefined;
        \\    });
        \\    assert.sameValue(found, 2);
        \\    assert.sameValue(seen.join(","), "0,2,undefined");
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array constructors and stringifiers preserve shared builtin semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var buffer = (new Uint8Array(4)).buffer;
        \\    assert.sameValue(Object.getPrototypeOf(buffer), ArrayBuffer.prototype);
        \\    assert.sameValue(buffer.resizable, false);
        \\    assert.sameValue(TypedArray.prototype.toString, Array.prototype.toString);
        \\
        \\    var oldToLocaleString = Number.prototype.toLocaleString;
        \\    try {
        \\        Number.prototype.toLocaleString = function() {
        \\            return oldToLocaleString.call(this);
        \\        };
        \\        assert.sameValue((new Uint8Array([42, 0])).toLocaleString(), "42,0");
        \\    } finally {
        \\        Number.prototype.toLocaleString = oldToLocaleString;
        \\    }
        \\
        \\    var unwrapped = new Uint8Array([Object(42), Object(0)]);
        \\    assert.sameValue(unwrapped[0], 42);
        \\    assert.sameValue(unwrapped[1], 0);
        \\
        \\    var bigWrapped = new BigInt64Array([Object(42n), Object(0n)]);
        \\    assert.sameValue(bigWrapped[0], 42n);
        \\    assert.sameValue(bigWrapped[1], 0n);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array ArrayBuffer prototype cache is internal metadata" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    assert.sameValue("__zjs_arraybuffer_proto" in Uint8Array, false);
        \\    assert.sameValue(Object.getOwnPropertyDescriptor(Uint8Array, "__zjs_arraybuffer_proto"), undefined);
        \\    assert.sameValue("__zjs_arraybuffer_proto" in Uint8Array.prototype, false);
        \\    assert.sameValue(Object.getOwnPropertyDescriptor(Uint8Array.prototype, "__zjs_arraybuffer_proto"), undefined);
        \\
        \\    Uint8Array.__zjs_arraybuffer_proto = { bad: true };
        \\    Uint8Array.prototype.__zjs_arraybuffer_proto = { bad: true };
        \\    var buffer = (new Uint8Array(1)).buffer;
        \\    assert.sameValue(Object.getPrototypeOf(buffer), ArrayBuffer.prototype);
        \\    assert.sameValue(delete Uint8Array.__zjs_arraybuffer_proto, true);
        \\    assert.sameValue(delete Uint8Array.prototype.__zjs_arraybuffer_proto, true);
        \\
        \\    class Sub extends Uint8Array {}
        \\    Sub.prototype.__zjs_arraybuffer_proto = { bad: true };
        \\    var subBuffer = (new Sub(1)).buffer;
        \\    assert.sameValue(Object.getPrototypeOf(subBuffer), ArrayBuffer.prototype);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array prototype-chain set stays on the ordinary receiver path" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var valueOfCalls = 0;
        \\    var value = {
        \\        valueOf: function() {
        \\            valueOfCalls++;
        \\            return 2.3;
        \\        }
        \\    };
        \\
        \\    Object.defineProperty(Int32Array.prototype, 0, {
        \\        get: function() { throw new Error("getter should be unreachable"); },
        \\        set: function(_v) { throw new Error("setter should be unreachable"); },
        \\        configurable: true
        \\    });
        \\
        \\    try {
        \\        var target = new Int32Array([0]);
        \\        var receiver = Object.create(target);
        \\        receiver[0] = value;
        \\        assert.sameValue(target[0], 0);
        \\        assert.sameValue(receiver[0], value);
        \\
        \\        receiver = Object.create(target);
        \\        receiver[1.5] = value;
        \\        assert.sameValue(receiver.hasOwnProperty("1.5"), false);
        \\        assert.sameValue(valueOfCalls, 0);
        \\
        \\        var proto = new Int32Array(10);
        \\        var obj = Object.create(proto);
        \\        var protoCalls = 0;
        \\        assert.sameValue(Reflect.set(obj, 100, {
        \\            valueOf: function() {
        \\                protoCalls++;
        \\                return 1;
        \\            }
        \\        }, proto), true);
        \\        assert.sameValue(protoCalls, 1);
        \\    } finally {
        \\        delete Int32Array.prototype[0];
        \\    }
        \\
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array ordinary noncanonical keys stay enumerable in for-in" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var ordinary = new Int8Array([0]);
        \\    assert.sameValue(Reflect.defineProperty(ordinary, "1.0", {
        \\        value: 1,
        \\        writable: true,
        \\        enumerable: true,
        \\        configurable: true
        \\    }), true);
        \\    var seen = [];
        \\    for (var key in ordinary) seen.push(key);
        \\    assert.sameValue(seen.length, 2);
        \\    assert.sameValue(seen[0], "0");
        \\    assert.sameValue(seen[1], "1.0");
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Iterator zip and zipKeyed expose joint iteration helpers" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(typeof Iterator.zip, "function");
        \\assert.sameValue(Iterator.zip.length, 1);
        \\assert.sameValue(Iterator.zip.name, "zip");
        \\assert.sameValue(typeof Iterator.zipKeyed, "function");
        \\assert.sameValue(Iterator.zip([]).next().done, true);
        \\var zipped = Iterator.zip([[1, 2], [3, 4]]);
        \\var first = zipped.next();
        \\assert.sameValue(JSON.stringify(first.value), "[1,3]");
        \\assert.sameValue(first.done, false);
        \\var second = zipped.next();
        \\assert.sameValue(JSON.stringify(second.value), "[2,4]");
        \\assert.sameValue(second.done, false);
        \\assert.sameValue(zipped.next().done, true);
        \\var longest = Iterator.zip([[1], [2, 3]], { mode: "longest", padding: ["pad"] });
        \\assert.sameValue(JSON.stringify(longest.next().value), "[1,2]");
        \\assert.sameValue(JSON.stringify(longest.next().value), "[\"pad\",3]");
        \\assert.sameValue(longest.next().done, true);
        \\var strict = Iterator.zip([[1], [2, 3]], { mode: "strict" });
        \\assert.sameValue(JSON.stringify(strict.next().value), "[1,2]");
        \\assert.throws(TypeError, function() { strict.next(); });
        \\var keyed = Iterator.zipKeyed({ a: [5, 6], b: [7, 8] });
        \\var item = keyed.next();
        \\assert.sameValue(Object.getPrototypeOf(item.value), null);
        \\assert.sameValue(item.value.a, 5);
        \\assert.sameValue(item.value.b, 7);
        \\assert.sameValue(item.done, false);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Iterator helper runtime state is internal" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var helper = Iterator.from([1, 2]).map(function(x) { return x + 1; });
        \\assert.sameValue("__zjs_iterator_helper_next" in helper, false);
        \\assert.sameValue("__zjs_iterator_callback" in helper, false);
        \\helper.__zjs_iterator_helper_next = function() {
        \\    return { done: false, value: 40 };
        \\};
        \\helper.__zjs_iterator_callback = function(x) {
        \\    return x + 1000;
        \\};
        \\var mapped = helper.next();
        \\assert.sameValue(mapped.done, false);
        \\assert.sameValue(mapped.value, 2);
        \\
        \\var flatMapped = Iterator.from([1]).flatMap(function(x) {
        \\    return [x, x + 1];
        \\});
        \\assert.sameValue("__zjs_iterator_helper_inner_next" in flatMapped, false);
        \\assert.sameValue(flatMapped.next().value, 1);
        \\flatMapped.__zjs_iterator_helper_inner_next = function() {
        \\    return { done: false, value: 999 };
        \\};
        \\assert.sameValue(flatMapped.next().value, 2);
        \\
        \\var zipped = Iterator.zip([[1], [2]]);
        \\assert.sameValue("__zjs_iterator_zip_state" in zipped, false);
        \\assert.sameValue("__zjs_iterator_zip_nexts" in zipped, false);
        \\zipped.__zjs_iterator_zip_state = 3;
        \\zipped.__zjs_iterator_zip_nexts = {};
        \\zipped.__zjs_iterator_zip_pads = {};
        \\var zippedResult = zipped.next();
        \\assert.sameValue(zippedResult.done, false);
        \\assert.sameValue(JSON.stringify(zippedResult.value), "[1,2]");
        \\
        \\var keyed = Iterator.zipKeyed({ a: [3], b: [4] });
        \\assert.sameValue("__zjs_iterator_zip_keys" in keyed, false);
        \\keyed.__zjs_iterator_zip_keys = { 0: "x", 1: "y" };
        \\var keyedResult = keyed.next();
        \\assert.sameValue(keyedResult.done, false);
        \\assert.sameValue(keyedResult.value.a, 3);
        \\assert.sameValue(keyedResult.value.b, 4);
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(keyedResult.value, "x"), false);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Iterator flatMap OOM releases inner iterator once" {
    const source =
        \\var it = Iterator.from([1]).flatMap(function(x) {
        \\    return {
        \\        [Symbol.iterator]: function() {
        \\            return {
        \\                get next() {
        \\                    var holder = [];
        \\                    for (var i = 0; i < 8; i += 1) {
        \\                        holder.push({ value: x + i });
        \\                    }
        \\                    return function() {
        \\                        return { done: true };
        \\                    };
        \\                }
        \\            };
        \\        }
        \\    };
        \\});
        \\it.next();
    ;
    var saw_oom = false;
    var saw_success = false;

    const samples = oom_helpers.defaultSampleSet(320);
    var fail_offset: usize = 0;
    while (fail_offset < samples.limit) : (fail_offset += 1) {
        if (!oom_helpers.shouldRunOffset(samples, fail_offset)) continue;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var js = try engine.Engine.init(failing.allocator());

        const warmup = try js.eval(source);
        warmup.free(js.runtime);

        var parsed = try engine.frontend.parser.parse(js.runtime, source, .{ .return_completion = true });
        var vm = engine.exec.Vm.init(js.context);

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = vm.run(&parsed.function);
        failing.fail_index = std.math.maxInt(usize);

        if (result) |value| {
            saw_success = true;
            value.free(js.runtime);
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => |unexpected| {
                vm.deinit();
                parsed.deinit();
                js.deinit();
                return unexpected;
            },
        }

        vm.deinit();
        parsed.deinit();
        js.deinit();
        if (oom_helpers.shouldStopAfterCoverage(saw_oom, saw_success)) return;
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

test "Error subclasses inherit constructor from their prototype" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\class ExpectedError extends Error {}
        \\var e = new ExpectedError("boom");
        \\assert.sameValue(Object.getPrototypeOf(e), ExpectedError.prototype);
        \\assert.sameValue(e.constructor, ExpectedError);
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(e, "constructor"), false);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "methods using arguments parse nested template getters" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function makeIterator(log, name) {
        \\    return {
        \\        next() {
        \\            assert.sameValue(arguments.length, 0);
        \\            return {
        \\                get done() {
        \\                    log.push(`done ${name}`);
        \\                    return false;
        \\                },
        \\                get value() {
        \\                    log.push(`value ${name}`);
        \\                    return 1;
        \\                },
        \\            };
        \\        },
        \\        return() {
        \\            return {};
        \\        },
        \\    };
        \\}
        \\var log = [];
        \\var iter = makeIterator(log, "zip");
        \\var step = iter.next();
        \\assert.sameValue(step.done, false);
        \\assert.sameValue(step.value, 1);
        \\assert.compareArray(log, ["done zip", "value zip"]);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "ThrowTypeError intrinsic is frozen and shared per realm" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var args = function() { "use strict"; return arguments; }();
        \\var thrower = Object.getOwnPropertyDescriptor(args, "callee").get;
        \\assert.sameValue(thrower.name, "");
        \\assert.sameValue(thrower.length, 0);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(thrower, "name").configurable, false);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(thrower, "length").configurable, false);
        \\assert.sameValue(Object.getPrototypeOf(thrower), Function.prototype);
        \\assert.sameValue(Object.isFrozen(thrower), true);
        \\assert.throws(TypeError, function() { thrower(); });
        \\var argumentsDesc = Object.getOwnPropertyDescriptor(Function.prototype, "arguments");
        \\var callerDesc = Object.getOwnPropertyDescriptor(Function.prototype, "caller");
        \\assert.sameValue(argumentsDesc.get, thrower);
        \\assert.sameValue(argumentsDesc.set, thrower);
        \\assert.sameValue(callerDesc.get, thrower);
        \\assert.sameValue(callerDesc.set, thrower);
        \\var otherArgs = function(a = 0) { return arguments; }();
        \\assert.sameValue(Object.getOwnPropertyDescriptor(otherArgs, "callee").get, thrower);
        \\var other = $262.createRealm().global;
        \\var otherThrower = other.eval("(function() { 'use strict'; return Object.getOwnPropertyDescriptor(arguments, 'callee').get; })()");
        \\assert.notSameValue(otherThrower, thrower);
        \\assert.sameValue(otherThrower, Object.getOwnPropertyDescriptor(other.Function.prototype, "arguments").get);
        \\assert.sameValue(otherThrower, Object.getOwnPropertyDescriptor(other.Function.prototype, "caller").set);
        \\assert.sameValue(Object.getPrototypeOf(otherThrower), other.Function.prototype);
        \\assert.throws(other.TypeError, function() { otherThrower(); });
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "generator runtime state is internal" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\class Base {
        \\    m() {
        \\        return 10;
        \\    }
        \\}
        \\class Derived extends Base {
        \\    *g() {
        \\        yield 1;
        \\        return super.m();
        \\    }
        \\}
        \\var generator = new Derived().g();
        \\assert.sameValue("__zjs_generator_function" in generator, false);
        \\assert.sameValue(generator.next().value, 1);
        \\function* fake() {}
        \\generator.__zjs_generator_function = fake;
        \\var resumed = generator.next();
        \\assert.sameValue(resumed.done, true);
        \\assert.sameValue(resumed.value, 10);
        \\
        \\function* yieldStar() {
        \\    yield* [1, 2];
        \\    yield 3;
        \\}
        \\var delegated = yieldStar();
        \\assert.sameValue("__zjs_generator_yield_star_suspended" in delegated, false);
        \\assert.sameValue("__zjs_generator_resume_completion" in delegated, false);
        \\assert.sameValue(delegated.next().value, 1);
        \\delegated.__zjs_generator_yield_star_suspended = true;
        \\delegated.__zjs_generator_resume_completion = 2;
        \\assert.throws(TypeError, function() {
        \\    delegated.throw("x");
        \\});
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "async generator functions use AsyncGenerator prototype topology" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\async function* g() {}
        \\var AsyncGenerator = Object.getPrototypeOf(g);
        \\var AsyncGeneratorPrototype = AsyncGenerator.prototype;
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(g, "prototype"), true);
        \\assert.sameValue(Object.getPrototypeOf(g.prototype), AsyncGeneratorPrototype);
        \\assert.sameValue(AsyncGeneratorPrototype.constructor, AsyncGenerator);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(AsyncGeneratorPrototype, "constructor").writable, false);
        \\assert.sameValue(Object.getOwnPropertyDescriptor(AsyncGeneratorPrototype, "constructor").configurable, true);
        \\assert.sameValue(AsyncGeneratorPrototype[Symbol.toStringTag], "AsyncGenerator");
        \\var AsyncIteratorPrototype = Object.getPrototypeOf(AsyncGeneratorPrototype);
        \\assert.sameValue(typeof AsyncIteratorPrototype[Symbol.asyncIterator], "function");
        \\assert.sameValue(AsyncIteratorPrototype[Symbol.asyncIterator].name, "[Symbol.asyncIterator]");
        \\assert.sameValue(AsyncIteratorPrototype[Symbol.asyncIterator].length, 0);
        \\assert.sameValue(AsyncIteratorPrototype[Symbol.asyncIterator].call(4), 4);
        \\assert.sameValue(Object.getPrototypeOf(Object.getPrototypeOf(g()))[Symbol.toStringTag], "AsyncGenerator");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "AsyncIterator prototype exposes asyncDispose" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\async function* g() {}
        \\var AsyncIteratorPrototype = Object.getPrototypeOf(Object.getPrototypeOf(g.prototype));
        \\var dispose = AsyncIteratorPrototype[Symbol.asyncDispose];
        \\assert.sameValue(typeof Symbol.asyncDispose, "symbol");
        \\assert.sameValue(typeof dispose, "function");
        \\assert.sameValue(dispose.name, "[Symbol.asyncDispose]");
        \\assert.sameValue(dispose.length, 0);
        \\var desc = Object.getOwnPropertyDescriptor(AsyncIteratorPrototype, Symbol.asyncDispose);
        \\assert.sameValue(desc.value, dispose);
        \\assert.sameValue(desc.writable, true);
        \\assert.sameValue(desc.enumerable, false);
        \\assert.sameValue(desc.configurable, true);
        \\(async function() {
        \\    assert.sameValue("__zjs_async_iterator_async_dispose" in dispose, false);
        \\    assert.sameValue(Object.getOwnPropertyDescriptor(dispose, "__zjs_async_iterator_async_dispose"), undefined);
        \\    dispose.__zjs_async_iterator_async_dispose = false;
        \\    var markerCalled = 0;
        \\    await dispose.call({
        \\        return: function(value) {
        \\            markerCalled += 1;
        \\            assert.sameValue(value, undefined);
        \\            return { done: true };
        \\        }
        \\    });
        \\    assert.sameValue(markerCalled, 1);
        \\    assert.sameValue(delete dispose.__zjs_async_iterator_async_dispose, true);
        \\    markerCalled = 0;
        \\    await dispose.call({
        \\        return: function(value) {
        \\            markerCalled += 1;
        \\            assert.sameValue(value, undefined);
        \\            return { done: true };
        \\        }
        \\    });
        \\    assert.sameValue(markerCalled, 1);
        \\    var called = 0;
        \\    await dispose.call({
        \\        return: function(value) {
        \\            called += 1;
        \\            assert.sameValue(value, undefined);
        \\            return Promise.resolve({ done: true });
        \\        }
        \\    });
        \\    assert.sameValue(called, 1);
        \\    var thrown = new Test262Error("dispose");
        \\    var getterCaught;
        \\    try {
        \\        await dispose.call({
        \\            get return() {
        \\                throw thrown;
        \\            }
        \\        });
        \\    } catch (error) {
        \\        getterCaught = error;
        \\    }
        \\    assert.sameValue(getterCaught, thrown);
        \\    var rejectedCaught;
        \\    try {
        \\        await dispose.call({
        \\            return: function() {
        \\                return Promise.reject(thrown);
        \\            }
        \\        });
        \\    } catch (error) {
        \\        rejectedCaught = error;
        \\    }
        \\    assert.sameValue(rejectedCaught, thrown);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Symbol exposes dispose and asyncDispose well-known symbols" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(typeof Symbol.dispose, "symbol");
        \\assert.sameValue(typeof Symbol.asyncDispose, "symbol");
        \\assert.sameValue(Symbol.keyFor(Symbol.dispose), undefined);
        \\assert.sameValue(Symbol.keyFor(Symbol.asyncDispose), undefined);
        \\var disposeDesc = Object.getOwnPropertyDescriptor(Symbol, "dispose");
        \\assert.sameValue(disposeDesc.value, Symbol.dispose);
        \\assert.sameValue(disposeDesc.writable, false);
        \\assert.sameValue(disposeDesc.enumerable, false);
        \\assert.sameValue(disposeDesc.configurable, false);
        \\var asyncDisposeDesc = Object.getOwnPropertyDescriptor(Symbol, "asyncDispose");
        \\assert.sameValue(asyncDisposeDesc.value, Symbol.asyncDispose);
        \\assert.sameValue(asyncDisposeDesc.writable, false);
        \\assert.sameValue(asyncDisposeDesc.enumerable, false);
        \\assert.sameValue(asyncDisposeDesc.configurable, false);
        \\var other = $262.createRealm().global.Symbol;
        \\assert.sameValue(Symbol.dispose, other.dispose);
        \\assert.sameValue(Symbol.asyncDispose, other.asyncDispose);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "destructuring assignment to const binding throws TypeError" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileWithOutputMode(
        \\const c = null;
        \\try { ([c] = [1]); print("array-ok"); } catch (e) { print(e.name); }
        \\try { ({ c } = { c: 1 }); print("object-ok"); } catch (e) { print(e.name); }
    , &output, .script, "const-destructuring-assignment.js");
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("TypeError\nTypeError\n", output.buffered());
}

test "return from catch handles const assignment thrown by callback" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const c = null;
        \\function probe(callback) {
        \\  try {
        \\    callback();
        \\  } catch (thrown) {
        \\    return thrown.constructor === TypeError && thrown.name === "TypeError";
        \\  }
        \\  return false;
        \\}
        \\assert.sameValue(probe(function() { c = 1; }), true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "async generator yield star delegates through async iterator protocol" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var log = [];
        \\var yieldedPromise = Promise.resolve("inner");
        \\var asyncIter = {
        \\    [Symbol.asyncIterator]: function() {
        \\        log.push("asyncIterator");
        \\        return this;
        \\    },
        \\    next: function(value) {
        \\        log.push("next:" + value);
        \\        return Promise.resolve({ value: yieldedPromise, done: false });
        \\    },
        \\    return: function(value) {
        \\        log.push("return:" + value);
        \\        return Promise.resolve({ value: "ret", done: true });
        \\    }
        \\};
        \\async function* values() {
        \\    yield* asyncIter;
        \\    throw new Test262Error("unreachable after delegated return");
        \\}
        \\(async function() {
        \\    var iter = values();
        \\    var first = await iter.next("ignored");
        \\    assert.sameValue(first.value, yieldedPromise);
        \\    assert.sameValue(first.done, false);
        \\    var returned = iter.return("stop");
        \\    assert.sameValue(typeof returned.then, "function");
        \\    var done = await returned;
        \\    assert.sameValue(done.value, "ret");
        \\    assert.sameValue(done.done, true);
        \\    assert.compareArray(log, ["asyncIterator", "next:undefined", "return:stop"]);
        \\
        \\    var thrownIter = values();
        \\    await thrownIter.next();
        \\    var threw = false;
        \\    try {
        \\        await thrownIter.throw("boom");
        \\    } catch (error) {
        \\        threw = error instanceof TypeError;
        \\    }
        \\    assert.sameValue(threw, true);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "async generator yield star preserves Promise species observations" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var speciesHits = 0;
        \\var speciesDesc = Object.getOwnPropertyDescriptor(Promise, Symbol.species);
        \\try {
        \\    Object.defineProperty(Promise, Symbol.species, {
        \\        get: function() {
        \\            speciesHits++;
        \\            return speciesDesc.get.call(this);
        \\        },
        \\        configurable: true,
        \\    });
        \\    async function* values() {
        \\        yield* [Promise.resolve(1)];
        \\    }
        \\    values().next().then(function(result) {
        \\        assert.sameValue(result.value, 1);
        \\        assert.sameValue(result.done, false);
        \\        assert.sameValue(speciesHits, 1);
        \\    });
        \\} finally {
        \\    Object.defineProperty(Promise, Symbol.species, speciesDesc);
        \\}
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "eval for-await uses AsyncFromSync close ordering" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(async function() {
        \\    var log = [];
        \\    var runBreak = eval("(async function(iter) { for await (const value of iter) { log.push(value); break; } })");
        \\    var breakIter = {
        \\        i: 0,
        \\        [Symbol.iterator]: function() {
        \\            log.push("sync-break");
        \\            return this;
        \\        },
        \\        next: function() {
        \\            this.i++;
        \\            return { value: Promise.resolve("v" + this.i), done: false };
        \\        },
        \\        return: function() {
        \\            log.push("close-break");
        \\            return { done: true };
        \\        },
        \\    };
        \\    await runBreak(breakIter);
        \\
        \\    var runReject = eval("(async function(iter) { try { for await (const value of iter) { log.push(value); } } catch (error) { log.push(error.message); } })");
        \\    var rejectIter = {
        \\        i: 0,
        \\        [Symbol.iterator]: function() {
        \\            log.push("sync-reject");
        \\            return this;
        \\        },
        \\        next: function() {
        \\            this.i++;
        \\            return { value: Promise.reject(new Error("boom")), done: false };
        \\        },
        \\        return: function() {
        \\            log.push("close-reject");
        \\            return { done: true };
        \\        },
        \\    };
        \\    await runReject(rejectIter);
        \\    assert.compareArray(log, ["sync-break", "v1", "close-break", "sync-reject", "close-reject", "boom"]);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "for-await AsyncFromSync stack overflow releases sync iterators once" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    try expectForAwaitStartStackOverflowCleanup(&js,
        \\for await (const value of "abc") {
        \\    break;
        \\}
    );

    const setup = try js.eval(
        \\globalThis.__zjs_for_await_iterable = {
        \\    [Symbol.iterator]: function() {
        \\        return {
        \\            next: function() {
        \\                return { done: true };
        \\            }
        \\        };
        \\    }
        \\};
    );
    setup.free(js.runtime);
    try expectForAwaitStartStackOverflowCleanup(&js,
        \\for await (const value of globalThis.__zjs_for_await_iterable) {
        \\}
    );
}

fn expectForAwaitStartStackOverflowCleanup(js: *engine.Engine, source: []const u8) !void {
    var parsed = try engine.frontend.parser.parse(js.runtime, source, .{ .mode = .module });
    defer parsed.deinit();

    var stack = engine.exec.stack.Stack.init(&js.runtime.memory, js.context.stack_limit);
    defer stack.deinit(js.runtime);
    try stack.reserveAdditional(parsed.function.stack_size);
    stack.limit = 2;

    try std.testing.expectError(error.StackOverflow, engine.exec.qjs_vm.runWithOutput(js.context, &stack, &parsed.function, null));
}

test "eval for-await closes async iterator when next rejects" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\(async function() {
        \\    var closed = 0;
        \\    var iter = {
        \\        [Symbol.asyncIterator]: function() {
        \\            return this;
        \\        },
        \\        next: function() {
        \\            return Promise.reject(new Error("next boom"));
        \\        },
        \\        return: function() {
        \\            closed++;
        \\            return { done: true };
        \\        },
        \\    };
        \\    try {
        \\        for await (const value of iter) {
        \\            void value;
        \\        }
        \\    } catch (error) {
        \\        print(error.message, closed);
        \\    }
        \\})();
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("next boom 1\n", stream.buffered());
    try std.testing.expect(!js.context.hasException());
}

test "eval for-await IteratorClose does not await rejected async return" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const previous_tracking = js.context.track_unhandled_rejections;
    js.context.track_unhandled_rejections = true;
    defer js.context.track_unhandled_rejections = previous_tracking;

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\(async function() {
        \\    var iter = {
        \\        i: 0,
        \\        [Symbol.asyncIterator]: function() { return this; },
        \\        next: function() {
        \\            this.i++;
        \\            return Promise.resolve({ value: this.i, done: false });
        \\        },
        \\        return: function() {
        \\            return Promise.reject(9);
        \\        },
        \\    };
        \\    try {
        \\        for await (const value of iter) {
        \\            void value;
        \\            break;
        \\        }
        \\    } catch (error) {
        \\        print("caught", error);
        \\    }
        \\})();
    , &stream);
    defer result.free(js.runtime);
    try js.runJobs();

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("", stream.buffered());
    try std.testing.expect(js.context.hasUnhandledRejection());
    const rejection = js.context.takeUnhandledRejection();
    defer rejection.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 9), rejection.asInt32());
    if (js.context.hasException()) {
        const thrown = js.context.takeException();
        thrown.free(js.runtime);
    }
}

test "Iterator prototype exposes intrinsic identity method and accessor descriptors" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var IteratorPrototype = Iterator.prototype;
        \\var iterator = IteratorPrototype[Symbol.iterator];
        \\assert.sameValue(iterator.name, "[Symbol.iterator]");
        \\assert.sameValue(iterator.length, 0);
        \\assert.sameValue(iterator.call(0), 0);
        \\var iteratorDesc = Object.getOwnPropertyDescriptor(IteratorPrototype, Symbol.iterator);
        \\assert.sameValue(iteratorDesc.value, iterator);
        \\assert.sameValue(iteratorDesc.writable, true);
        \\assert.sameValue(iteratorDesc.enumerable, false);
        \\assert.sameValue(iteratorDesc.configurable, true);
        \\var constructorDesc = Object.getOwnPropertyDescriptor(IteratorPrototype, "constructor");
        \\assert.sameValue(constructorDesc.value, undefined);
        \\assert.sameValue(constructorDesc.writable, undefined);
        \\assert.sameValue(constructorDesc.get.call({}), Iterator);
        \\assert.sameValue(constructorDesc.set.call({}), Iterator);
        \\var target = {};
        \\var replacement = {};
        \\assert.throws(TypeError, function() { constructorDesc.set.call(target, 1); });
        \\constructorDesc.set.call(target, replacement);
        \\assert.sameValue(target.constructor, replacement);
        \\assert.sameValue(Object.prototype.propertyIsEnumerable.call(target, "constructor"), false);
        \\var tagDesc = Object.getOwnPropertyDescriptor(IteratorPrototype, Symbol.toStringTag);
        \\assert.sameValue(tagDesc.get.call({}), "Iterator");
        \\assert.throws(TypeError, function() { tagDesc.set.call(null, "x"); });
        \\assert.throws(TypeError, function() { tagDesc.set.call(IteratorPrototype, "x"); });
        \\tagDesc.set.call(target, "CustomIterator");
        \\assert.sameValue(target[Symbol.toStringTag], "CustomIterator");
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Iterator prototype exposes dispose method and invokes return" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var IteratorPrototype = Iterator.prototype;
        \\var dispose = IteratorPrototype[Symbol.dispose];
        \\assert.sameValue(typeof dispose, "function");
        \\assert.sameValue(dispose.name, "[Symbol.dispose]");
        \\assert.sameValue(dispose.length, 0);
        \\var disposeDesc = Object.getOwnPropertyDescriptor(IteratorPrototype, Symbol.dispose);
        \\assert.sameValue(disposeDesc.value, dispose);
        \\assert.sameValue(disposeDesc.writable, true);
        \\assert.sameValue(disposeDesc.enumerable, false);
        \\assert.sameValue(disposeDesc.configurable, true);
        \\assert.sameValue(dispose.call({}), undefined);
        \\var log = [];
        \\var iter = Object.create(IteratorPrototype);
        \\iter.return = function() {
        \\    log.push(this === iter);
        \\    return { done: true, value: 1 };
        \\};
        \\assert.sameValue(dispose.call(iter), undefined);
        \\assert.sameValue(log.join(","), "true");
        \\var bad = Object.create(IteratorPrototype);
        \\bad.return = 1;
        \\assert.throws(TypeError, function() { dispose.call(bad); });
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array constructors expose spec length and static from/of write elements" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(Int8Array.length, 3);
        \\assert.sameValue(Uint8Array.length, 3);
        \\assert.sameValue(Float64Array.length, 3);
        \\var fromArray = Int8Array.from([1, 2]);
        \\assert.sameValue(fromArray.length, 2);
        \\assert.sameValue(fromArray[0], 1);
        \\assert.sameValue(fromArray[1], 2);
        \\assert.sameValue(fromArray.constructor, Int8Array);
        \\var fromArrayLike = Uint8Array.from({0: 5, 1: 6, length: 2});
        \\assert.sameValue(fromArrayLike.length, 2);
        \\assert.sameValue(fromArrayLike[0], 5);
        \\assert.sameValue(fromArrayLike[1], 6);
        \\var ofArray = Uint8Array.of(3, 4);
        \\assert.sameValue(ofArray.length, 2);
        \\assert.sameValue(ofArray[0], 3);
        \\assert.sameValue(ofArray[1], 4);
        \\assert.sameValue(ofArray.constructor, Uint8Array);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array static from and of validate constructors and result length" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    var from = Int8Array.from;
        \\    assert.throws(TypeError, function() {
        \\        from([1, 2]);
        \\    });
        \\    assert.throws(TypeError, function() {
        \\        Int8Array.from.call({ m() {} }.m, [1, 2]);
        \\    });
        \\
        \\    var fromCalls = 0;
        \\    var fromCtor = function(len) {
        \\        fromCalls += 1;
        \\        assert.sameValue(len, 2);
        \\        return new Int8Array(len);
        \\    };
        \\    var fromResult = Int8Array.from.call(fromCtor, [41, 42]);
        \\    assert.sameValue(fromCalls, 1);
        \\    assert.sameValue(fromResult.length, 2);
        \\    assert.sameValue(fromResult[0], 41);
        \\    assert.sameValue(fromResult[1], 42);
        \\
        \\    assert.throws(TypeError, function() {
        \\        Int8Array.from.call(function() {}, [1]);
        \\    });
        \\    assert.throws(TypeError, function() {
        \\        Int8Array.from.call(function() { return new Int8Array(1); }, [1, 2]);
        \\    });
        \\
        \\    var ofCalls = 0;
        \\    var ofCtor = function(len) {
        \\        ofCalls += 1;
        \\        assert.sameValue(len, 3);
        \\        return new Int8Array(len);
        \\    };
        \\    var ofResult = Int8Array.of.call(ofCtor, 4, 5, 6);
        \\    assert.sameValue(ofCalls, 1);
        \\    assert.sameValue(ofResult.length, 3);
        \\    assert.sameValue(ofResult[0], 4);
        \\    assert.sameValue(ofResult[1], 5);
        \\    assert.sameValue(ofResult[2], 6);
        \\    assert.throws(TypeError, function() {
        \\        Int8Array.of.call(function() {}, 1);
        \\    });
        \\    assert.throws(TypeError, function() {
        \\        Int8Array.of.call(function() { return new Int8Array(1); }, 1, 2);
        \\    });
        \\
        \\    var abrupt = {
        \\        valueOf() {
        \\            throw new Error("boom");
        \\        }
        \\    };
        \\    assert.throws(Error, function() {
        \\        Int8Array.from([1, abrupt, 3]);
        \\    });
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "typed array constructors reject misaligned offsets and unwrap object values" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    assert.throws(RangeError, function() {
        \\        new Uint16Array(new ArrayBuffer(3), 1);
        \\    });
        \\
        \\    var coercions = 0;
        \\    var sample = {
        \\        valueOf() {
        \\            coercions += 1;
        \\            return 7;
        \\        }
        \\    };
        \\    var coerced = new Uint8Array([sample]);
        \\    assert.sameValue(coercions, 1);
        \\    assert.sameValue(coerced[0], 7);
        \\
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Float16Array constructor and buffer views round-trip" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\    assert.sameValue(typeof Float16Array, "function");
        \\    assert.sameValue(Float16Array.BYTES_PER_ELEMENT, 2);
        \\    assert.sameValue(Float16Array.prototype.BYTES_PER_ELEMENT, 2);
        \\
        \\    var values = new Float16Array([1, 1.5, Infinity]);
        \\    assert.sameValue(values.length, 3);
        \\    assert.sameValue(values[0], 1);
        \\    assert.sameValue(values[1], 1.5);
        \\    assert.sameValue(values[2], Infinity);
        \\
        \\    var raw = new Uint16Array([0x3c00, 0x3e00]);
        \\    var viewed = new Float16Array(raw.buffer);
        \\    assert.sameValue(viewed[0], 1);
        \\    assert.sameValue(viewed[1], 1.5);
        \\})();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "VM domain helper failures surface as TypeError or invalid bytecode" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("domain-errors");
    defer rt.atoms.free(name);
    const prop = try rt.internAtom("x");
    defer rt.atoms.free(prop);

    var get_prop_function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer get_prop_function.deinit(rt);
    var get_prop_bytes: [6]u8 = undefined;
    get_prop_bytes[0] = op.null;
    get_prop_bytes[1] = op.get_field;
    std.mem.writeInt(u32, get_prop_bytes[2..6], prop, .little);
    try get_prop_function.setCode(&get_prop_bytes);
    try std.testing.expectError(error.TypeError, runFunction(rt, ctx, &get_prop_function));
    try std.testing.expect(!ctx.hasException());

    var malformed_function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer malformed_function.deinit(rt);
    try malformed_function.setCode(&.{0xff});
    try std.testing.expectError(error.InvalidBytecode, runFunction(rt, ctx, &malformed_function));
    try std.testing.expect(!ctx.hasException());
}

test "ordinary property misses do not alias minSum or propSum" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var direct = { min: 99, a: 7 };
        \\assert.sameValue(direct.min, 99);
        \\assert.sameValue(direct.a, 7);
        \\assert.sameValue(direct.minSum, undefined);
        \\assert.sameValue(direct.propSum, undefined);
        \\var inherited = Object.create({ min: 5, a: 6 });
        \\assert.sameValue(inherited.min, 5);
        \\assert.sameValue(inherited.a, 6);
        \\assert.sameValue(inherited.minSum, undefined);
        \\assert.sameValue(inherited.propSum, undefined);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "GC keeps direct eval captures, class field initializers, and generator captured values alive" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const old_threshold = js.runtime.gcThreshold();
    js.runtime.setGCThreshold(0);
    defer js.runtime.setGCThreshold(old_threshold);

    // 1. Setup the generator, async generator, and class in an IIFE.
    // The unique Symbol is strictly local to the IIFE and has no direct global references!
    // The global `result` only retains the closure, generator, object instance, and promise.
    const setup_result = try js.eval(
        \\var async_called = false;
        \\var result = (function() {
        \\    var uniqueSymbol = Symbol("gc-protected-unique-symbol");
        \\
        \\    // A generator with a direct symbol argument and local captures
        \\    function* genFn(a) {
        \\        var b = "captured-val";
        \\        yield a;
        \\        yield b;
        \\    }
        \\    var g = genFn(uniqueSymbol);
        \\
        \\    // An async generator driven to yielding a symbol
        \\    async function* asyncGenFn(a) {
        \\        yield a;
        \\    }
        \\    var ag = asyncGenFn(uniqueSymbol);
        \\    var agPromise = ag.next(); // Drive the async generator to create its internal state/promise Reaction
        \\
        \\    // Direct eval capture
        \\    var captured = uniqueSymbol;
        \\    function outer() {
        \\        return eval("captured");
        \\    }
        \\
        \\    // Class field initializers
        \\    class FieldTest {
        \\        x = uniqueSymbol;
        \\        y = this.x;
        \\    }
        \\    var ft = new FieldTest();
        \\
        \\    return {
        \\        outer: outer,
        \\        g: g,
        \\        ft: ft,
        \\        agPromise: agPromise
        \\    };
        \\})();
    );
    defer setup_result.free(js.runtime);
    try std.testing.expect(setup_result.isUndefined());

    // 2. Run one explicit cycle after setup. The threshold above forces GC during
    // setup allocations; this extra pass checks the retained object graph before
    // retrieving the values.
    // Since there are zero global references to uniqueSymbol, genFn, asyncGenFn, captured, or FieldTest,
    // they can ONLY be kept alive if our GC rooting implementation correctly protects:
    // - Suspended generator frames
    // - Direct eval closure/context variables
    // - Class field instance properties
    // - Async generator promise reactions
    _ = js.runtime.runObjectCycleRemoval();

    // 3. Verify that the captured values, generator variables, and driven async generator are perfectly alive and intact!
    const verify_result = try js.eval(
        \\var sym = result.outer();
        \\assert.sameValue(sym.description, "gc-protected-unique-symbol");
        \\
        \\assert.sameValue(result.g.next().value, sym);
        \\assert.sameValue(result.g.next().value, "captured-val");
        \\
        \\assert.sameValue(result.ft.y, sym);
        \\
        \\result.agPromise.then(function(res) {
        \\    async_called = true;
        \\    assert.sameValue(res.value, sym);
        \\});
    );
    defer verify_result.free(js.runtime);
    try std.testing.expect(verify_result.isUndefined());

    // 4. Flush job queue to execute the async generator callback and verify it ran
    try js.runJobs();

    const verify_async_result = try js.eval(
        \\assert.sameValue(async_called, true);
    );
    defer verify_async_result.free(js.runtime);
    try std.testing.expect(verify_async_result.isUndefined());
}

test "GC preserves Iterator.zip and Iterator.zipKeyed helpers and values" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const old_threshold = js.runtime.gcThreshold();
    js.runtime.setGCThreshold(0);
    defer js.runtime.setGCThreshold(old_threshold);

    const result = try js.eval(
        \\(function() {
        \\  var uniqueSymbol = Symbol("zip-gc-protected-symbol");
        \\  globalThis.__zjs_zipped_result = Iterator.zip([[uniqueSymbol], ["zip-val"]]);
        \\  globalThis.__zjs_keyed_result = Iterator.zipKeyed({ a: [uniqueSymbol], b: ["zip-keyed-val"] });
        \\})();
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    // Force cycle collection removal pass to verify everything stays live
    _ = js.runtime.runObjectCycleRemoval();

    // Verify iterator values are retained and correct!
    const verify_result = try js.eval(
        \\var zipped = globalThis.__zjs_zipped_result;
        \\var keyed = globalThis.__zjs_keyed_result;
        \\
        \\var nextZip = zipped.next();
        \\assert.sameValue(nextZip.done, false);
        \\assert.sameValue(nextZip.value[0].description, "zip-gc-protected-symbol");
        \\assert.sameValue(nextZip.value[1], "zip-val");
        \\
        \\var nextKeyed = keyed.next();
        \\assert.sameValue(nextKeyed.done, false);
        \\assert.sameValue(nextKeyed.value.a.description, "zip-gc-protected-symbol");
        \\assert.sameValue(nextKeyed.value.b, "zip-keyed-val");
        \\
        \\delete globalThis.__zjs_zipped_result;
        \\delete globalThis.__zjs_keyed_result;
    );
    defer verify_result.free(js.runtime);
    try std.testing.expect(verify_result.isUndefined());
}
