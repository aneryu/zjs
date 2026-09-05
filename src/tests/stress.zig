//! Long-running stress tier: deep-recursion stack exhaustion and randomized
//! bigint kernel sweeps. These were the five slowest tests in the tree
//! (~47s of a ~53s unified run, 2026-08-29) and are separated so
//! checkpoint-gate and the per-change `zig build test` close-out (see
//! docs/verification-policy.md) keep fast feedback. Coverage is unchanged
//! at the outer tiers: the engine-production gate, primary-platform CI,
//! and the per-merge-batch gate run this file through `test-stress`; the
//! ReleaseSafe phase close should invoke `zig build test test-stress
//! -Doptimize=ReleaseSafe`.
const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const core = zjs.core;
const bytecode = zjs.bytecode;
const op = zjs.bytecode.opcode.op;
const helpers = @import("helpers.zig");
const createTailOpcodeFixture = helpers.createTailOpcodeFixture;

test "raw tail call opcodes share the bounded tail-chain stack contract" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    js.runtime.setNativeStackSize(128 * 1024);

    const plain_code = [_]u8{
        op.special_object,
        bytecode.opcode.special_object_subtype.current_function,
        op.call,
        0,
        0,
        op.@"return",
    };
    const method_code = [_]u8{
        op.push_this,
        op.special_object,
        bytecode.opcode.special_object_subtype.current_function,
        op.tail_call_method,
        0,
        0,
    };
    const plain = try createTailOpcodeFixture(&js, "__w2RawTail", &plain_code, 1);
    const method = try createTailOpcodeFixture(&js, "__w2RawMethodTail", &method_code, 2);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const plain_key = try js.runtime.internAtom("__w2RawTail");
    defer js.runtime.atoms.free(plain_key);
    const method_key = try js.runtime.internAtom("__w2RawMethodTail");
    defer js.runtime.atoms.free(method_key);
    try global.defineOwnProperty(
        js.runtime,
        plain_key,
        core.Descriptor.data(plain, true, true, true),
    );
    try global.defineOwnProperty(
        js.runtime,
        method_key,
        core.Descriptor.data(method, true, true, true),
    );

    const baseline_call_depth = js.runtime.hot.call_depth;
    const baseline_native_depth = js.runtime.hot.native_call_depth;
    const baseline_tail_bytes = js.runtime.hot.active_bytecode_stack_bytes;
    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function __w2InvokeRaw(fn) { return 1 + fn(); }
        \\function __w2ExpectRaw(label, fn) {
        \\    try { __w2InvokeRaw(fn); print(label + ":missing"); }
        \\    catch (e) { print(label + ":" + e.name + ":" + e.message); }
        \\}
        \\__w2ExpectRaw("plain", __w2RawTail);
        \\__w2ExpectRaw("method", __w2RawMethodTail);
        \\print("recovered:" + (20 + 22));
    , &stream);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "plain:InternalError:stack overflow\n" ++
            "method:InternalError:stack overflow\n" ++
            "recovered:42\n",
        stream.buffered(),
    );
    try std.testing.expectEqual(baseline_call_depth, js.runtime.hot.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.hot.native_call_depth);
    try std.testing.expectEqual(baseline_tail_bytes, js.runtime.hot.active_bytecode_stack_bytes);
}

test "sloppy tail recursion still overflows like QuickJS" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function f(n) { if (n <= 0) return 0; return f(n - 1); }
        \\var threw = false;
        \\try { f(200000); } catch (e) {
        \\  threw = e instanceof InternalError && String(e.message).indexOf("stack overflow") >= 0;
        \\}
        \\assert.sameValue(threw, true);
    );
    try std.testing.expect(result.isUndefined());
}

test "missing-argument abrupt teardown releases supplied args and pads exactly once" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Release-balance side: a frame that throws mid-body dies through general
    // teardown, whose args release walks the FULL `arg_count` window — the
    // supplied refcounted prefix exactly once (double free corrupts rc, missed
    // free strands the object) and the undefined pads as tag-test no-ops.
    // Covers supplied-prefix (argc=1 < 2), all-missing (argc=0 < 2), the
    // plain/strict/method entry arms, and the deep-recursion overflow unwind
    // (every live frame's window released during the exception walk; the
    // engine keeps running afterwards).
    _ = try js.eval(
        \\function padThrow(a, b) { return a.x + null.missing + String(b); }
        \\function strictPadThrow(a, b) { "use strict"; return a.x + null.missing + String(b); }
        \\const padThrowRecv = { m: function (a, b) { return a.x + null.missing + String(b); } };
        \\function padOverflow(n, unused) { return padOverflow(n + 1) + (unused === undefined ? 1 : 0); }
        \\function exercisePaddedLeafThrow() {
        \\    for (let i = 0; i < 256; i++) {
        \\        try { padThrow({ x: 1 }); } catch (error) {}
        \\        try { padThrow(); } catch (error) {}
        \\        try { strictPadThrow({ x: 2 }); } catch (error) {}
        \\        try { padThrowRecv.m({ x: 3 }); } catch (error) {}
        \\    }
        \\    let overflow_caught = false;
        \\    try { padOverflow(0); } catch (error) { overflow_caught = true; }
        \\    if (!overflow_caught) throw new Error("overflow not raised");
        \\    if (padThrowRecv.m !== padThrowRecv.m) throw new Error("machine wedged");
        \\    return true;
        \\}
        \\exercisePaddedLeafThrow();
    );
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval("exercisePaddedLeafThrow()");
    _ = js.runtime.runObjectCycleRemoval();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "strict arrow tails stay constant while method recursion exhausts the logical stack budget" {

    // In a STRICT script, plain / arrow `return f()` is a proper tail call
    // and stays in constant stack. Method tails (`return this.m()`) still
    // grow a logical frame, so deep method recursion remains a catchable
    // stack overflow. Prove the runtime is usable after each catch.

    try helpers.expectPrints(
        \\"use strict";
        \\function expectStackOverflow(run) {
        \\  try {
        \\    run();
        \\    print("missing overflow");
        \\  } catch (error) {
        \\    print(error.name + ": " + error.message);
        \\  }
        \\}
        \\const arrowRecurse = (n) => n === 0 ? 0 : arrowRecurse(n - 1);
        \\print("arrow:" + arrowRecurse(40000));
        \\const machine = {
        \\  even(n) { return n === 0 ? "even" : this.odd(n - 1); },
        \\  odd(n) { return n === 0 ? "odd" : this.even(n - 1); },
        \\};
        \\expectStackOverflow(() => machine.even(40000));
        \\const counter = { loop(n) { return n === 0 ? 0 : this.loop(n - 1); } };
        \\expectStackOverflow(() => counter.loop(40000));
        \\print("recovered");
    , "arrow:0\n" ++
        "InternalError: stack overflow\n" ++
        "InternalError: stack overflow\n" ++
        "recovered\n");
}

/// Independent reference for `subMulAt`, written from the definition rather
/// than from the kernel's formulation: compute `numerator - divisor * qhat`
/// with an explicit per-limb signed borrow in `i128`, which shares no
/// arithmetic shape with the fused wrapping chain under test.
fn referenceSubMul(
    numerator: []engine.libs.bigint.Limb,
    divisor: []const engine.libs.bigint.Limb,
    qhat: engine.libs.bigint.Limb,
) bool {
    const Limb = engine.libs.bigint.Limb;
    var borrow: i128 = 0;
    for (divisor, 0..) |limb, i| {
        const product: u128 = @as(u128, limb) * @as(u128, qhat);
        var value: i128 = @as(i128, numerator[i]) - @as(i128, @intCast(product & std.math.maxInt(Limb))) - borrow;
        borrow = @intCast(product >> 64);
        while (value < 0) {
            value += @as(i128, 1) << 64;
            borrow += 1;
        }
        numerator[i] = @intCast(value);
    }
    var top: i128 = @as(i128, numerator[divisor.len]) - borrow;
    var negative = false;
    while (top < 0) {
        top += @as(i128, 1) << 64;
        negative = true;
    }
    numerator[divisor.len] = @intCast(@as(u128, @intCast(top)) & std.math.maxInt(Limb));
    return negative;
}

test "fused multiply-subtract matches the reference limb for limb" {
    const bigint = engine.libs.bigint;
    const Limb = bigint.Limb;
    const alloc = std.testing.allocator;

    // The kernel's borrow is a full limb rather than a 0/1 flag, so the whole
    // point of this test is that the fused wrapping chain and a plain
    // definitional computation agree on every limb and on the underflow flag.
    var prng = std.Random.DefaultPrng.init(0x604D3);
    const random = prng.random();

    const qhats = [_]Limb{ 0, 1, 2, 255, std.math.maxInt(Limb), std.math.maxInt(Limb) - 1, @as(Limb, 1) << 63 };
    for (2..33) |nb| {
        const divisor = try alloc.alloc(Limb, nb);
        defer alloc.free(divisor);
        const under_test = try alloc.alloc(Limb, nb + 1);
        defer alloc.free(under_test);
        const reference = try alloc.alloc(Limb, nb + 1);
        defer alloc.free(reference);

        for (0..7) |pattern| {
            for (qhats) |qhat| {
                for (divisor, 0..) |*l, i| l.* = switch (pattern) {
                    0 => 0,
                    1 => std.math.maxInt(Limb),
                    2 => if (i % 2 == 0) 0xAAAA_AAAA_AAAA_AAAA else 0x5555_5555_5555_5555,
                    3 => if (i == nb - 1) std.math.maxInt(Limb) else 0,
                    4 => 1,
                    5 => @as(Limb, 1) << 63,
                    else => random.int(Limb),
                };
                for (under_test, 0..) |*l, i| l.* = switch (pattern) {
                    0 => std.math.maxInt(Limb),
                    1 => 0,
                    3 => if (i == 0) std.math.maxInt(Limb) else 0,
                    else => random.int(Limb),
                };
                @memcpy(reference, under_test);
                const got = bigint.subMulAt(under_test, divisor, qhat);
                const want = referenceSubMul(reference, divisor, qhat);
                try std.testing.expectEqual(want, got);
                try std.testing.expectEqualSlices(Limb, reference, under_test);
            }
        }
    }

    // Random sweep across widths, weighted toward the shapes the division loop
    // actually produces.
    for (0..500_000) |_| {
        const nb = random.intRangeAtMost(usize, 2, 16);
        const divisor = try alloc.alloc(Limb, nb);
        defer alloc.free(divisor);
        const under_test = try alloc.alloc(Limb, nb + 1);
        defer alloc.free(under_test);
        const reference = try alloc.alloc(Limb, nb + 1);
        defer alloc.free(reference);
        for (divisor) |*l| l.* = random.int(Limb);
        divisor[nb - 1] |= @as(Limb, 1) << 63;
        for (under_test) |*l| l.* = random.int(Limb);
        // The real loop only ever calls this with the window's top limb at most
        // the divisor's top limb, so bias toward that while still covering more.
        if (random.boolean()) under_test[nb] = random.uintAtMost(Limb, divisor[nb - 1]);
        const qhat = switch (random.intRangeAtMost(usize, 0, 3)) {
            0 => std.math.maxInt(Limb),
            1 => random.int(Limb) | (@as(Limb, 1) << 63),
            2 => random.uintAtMost(Limb, 0xFFFF),
            else => random.int(Limb),
        };
        @memcpy(reference, under_test);
        const got = bigint.subMulAt(under_test, divisor, qhat);
        const want = referenceSubMul(reference, divisor, qhat);
        try std.testing.expectEqual(want, got);
        try std.testing.expectEqualSlices(Limb, reference, under_test);
    }
}
