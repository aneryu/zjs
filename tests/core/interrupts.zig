//! Core integration tests: interrupts.
const std = @import("std");
const zjs = @import("zjs");
const common = @import("common.zig");
const BytesStoreState = common.BytesStoreState;

const InterruptState = @import("../harness/interrupts.zig").State;

const HostFinalizerState = struct {
    calls: usize = 0,

    fn call(c: *zjs.native.Call) zjs.JSValue {
        _ = c;
        return zjs.JSValue.undefinedValue();
    }

    fn finalize(ptr: *anyopaque) void {
        const self: *HostFinalizerState = @ptrCast(@alignCast(ptr));
        self.calls += 1;
    }
};

test "production embedding memory limit reports allocation failure without leaking" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
    defer rt.setNativeBytesLimitForTest(null);

    try std.testing.expectError(error.OutOfMemory, ctx.eval("({ payload: new Array(32).fill('x') });", .{}));
}

test "production embedding public API allocation failures keep host ownership intact" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const object = try ctx.eval("({ answer: 42 })", .{});

    const persistent_before = rt.roots.persistent_root_slots.items.len;
    const local_before = rt.roots.local_root_slots.items.len;

    // Collect first, THEN pin the native cap to what is left.
    //
    // The cap is exactly the current footprint. A native cap does not collect,
    // so this only stays a failing allocation if nothing in the call allocates
    // less than the pinned total. The explicit collection makes that footprint
    // the live set rather than whatever garbage the previous test left behind.
    _ = try rt.collectForTest();

    rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
    defer rt.setNativeBytesLimitForTest(null);

    if (rt.createPersistentValue(object)) |handle| {
        var owned = handle;
        owned.deinit();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expectEqual(persistent_before, rt.roots.persistent_root_slots.items.len);
    try std.testing.expectEqual(local_before, rt.roots.local_root_slots.items.len);

    if (ctx.createString("must allocate")) |_| {
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expectEqual(persistent_before, rt.roots.persistent_root_slots.items.len);
    try std.testing.expectEqual(local_before, rt.roots.local_root_slots.items.len);

    var finalizer_state = HostFinalizerState{};
    if (ctx.createFunction(
        "AllocationBlockedHostFn",
        zjs.native.managed(HostFinalizerState.call),
        .{ .state = @ptrCast(&finalizer_state), .finalize = HostFinalizerState.finalize },
    )) |_| {
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expectEqual(@as(usize, 0), finalizer_state.calls);

    var bytes_state = BytesStoreState{ .allocator = std.testing.allocator };
    const backing = try std.testing.allocator.alloc(u8, 2);
    @memcpy(backing, &[_]u8{ 1, 2 });
    var store = zjs.JSValue.Bytes.Store.owned(backing, .{
        .deinit = BytesStoreState.deinit,
        .context = &bytes_state,
    });
    defer store.release();

    if (ctx.arrayBuffer(&store)) |_| {
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expectEqual(@as(usize, 0), bytes_state.calls);
    try std.testing.expectEqual(@as(usize, 2), store.bytes.len);
}

test "production embedding interrupt handler aborts unbounded execution" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var state = InterruptState{ .stop = true };
    rt.setInterruptHandler(InterruptState.poll, &state);
    defer rt.setInterruptHandler(null, null);

    try std.testing.expectError(error.Interrupted, ctx.eval("while (true) {}", .{}));
    try std.testing.expect(state.hits > 0);
}

test "production embedding interrupt while resuming an async function settles it" {
    // Each `await 0` resumes the function from an async-resume job. Sweep the
    // countdown across two iterations' polls: an interrupt there used to be
    // swallowed and the function dropped with its promise pending forever.
    // `eval` drains the microtasks, so the loop only ends by interrupt.
    var countdown: usize = 0;
    while (countdown < 6) : (countdown += 1) {
        const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
        defer rt.destroy();
        const ctx = try zjs.JSContext.create(rt, .{});
        defer ctx.destroy();
        var state = InterruptState{ .remaining = countdown };
        rt.setInterruptHandler(InterruptState.poll, &state);
        defer rt.setInterruptHandler(null, null);
        const result = ctx.eval(
            \\globalThis.state = "pending";
            \\(async function () { for (;;) await 0; })().catch(() => { state = "rejected"; });
        , .{});
        rt.setInterruptHandler(null, null);
        if (result) |_| {} else |err| {
            try std.testing.expectEqual(error.Interrupted, err);
            continue;
        }
        // Inside the body the interrupt rejects the function's promise, as
        // a promise job does with one; the function is never just dropped.
        try rt.runMicrotasks();
        try std.testing.expectEqual(@as(?bool, true), (try ctx.eval("state === \"rejected\"", .{})).as(.boolean));
    }
}

test "production embedding interrupt reaches a global replace made of short matches" {
    // Each match takes a few backtrack steps; the executor's poll countdown
    // must carry across matches for the builtin to observe the interrupt.
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();
    _ = try ctx.eval("globalThis.input = 'a,'.repeat(200000);", .{});
    var state = InterruptState{ .remaining = 0 };
    rt.setInterruptHandler(InterruptState.poll, &state);
    defer rt.setInterruptHandler(null, null);
    try std.testing.expectError(error.Interrupted, ctx.eval("input.replace(/,/g, '').length", .{}));
}

test "production embedding interrupt reaches long native loops" {
    // Each operation runs well past one native poll interval without calling
    // back into JavaScript, so only its own loop poll can observe the handler
    // (the countdown lets the eval's entry poll pass).
    const Case = struct { setup: []const u8, run: []const u8 };
    const cases = [_]Case{
        .{ .setup = "var a = []; a.length = 100000;", .run = "a.join()" },
        .{ .setup = "var a = []; a.length = 100000;", .run = "a.forEach(Math.abs)" },
        .{ .setup = "var o = { length: 100000 };", .run = "Array.prototype.copyWithin.call(o, 0, 1)" },
        .{ .setup = "var o = { length: 100000 };", .run = "Array.from(o)" },
        .{ .setup = "var a = []; for (var i = 0; i < 20000; i++) a.push(20000 - i);", .run = "a.sort()" },
        .{ .setup = "var a = new Array(100000).fill(1);", .run = "a.join()" },
        .{ .setup = "var j = '[' + '1,'.repeat(100000) + '1]';", .run = "JSON.parse(j)" },
        .{ .setup = "var j = '[' + '{\"k\":1},'.repeat(20000) + '{}]';", .run = "JSON.parse(j)" },
        .{ .setup = "var rows = []; for (var i = 0; i < 20000; i++) rows.push({ k: i });", .run = "JSON.stringify(rows)" },
        .{ .setup = "var s = '\\u00e9'.repeat(100000);", .run = "encodeURIComponent(s)" },
        .{ .setup = "var s = '%41'.repeat(100000);", .run = "decodeURIComponent(s)" },
        .{ .setup = "", .run = "''.padStart(1000000, 'ab')" },
        .{ .setup = "var s = 'a'.repeat(100000);", .run = "s.replaceAll('a', 'b')" },
        .{ .setup = "var s = 'a'.repeat(100000);", .run = "s.split('')" },
    };
    for (cases) |case| {
        const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
        defer rt.destroy();
        const ctx = try zjs.JSContext.create(rt, .{});
        defer ctx.destroy();
        _ = try ctx.eval(case.setup, .{});
        var state = InterruptState{ .remaining = 3 };
        rt.setInterruptHandler(InterruptState.poll, &state);
        try std.testing.expectError(error.Interrupted, ctx.eval(case.run, .{}));
        rt.setInterruptHandler(null, null);
        // An interrupted sort leaves the array a permutation of itself.
        try std.testing.expectEqual(@as(?bool, true), (try ctx.eval("typeof a !== 'object' || a.length !== 20000 || (new Set(a).size === 20000 && a.every((v) => v >= 1 && v <= 20000))", .{})).as(.boolean));
    }
}

test "production embedding interrupt reaches the compiler and bulk native work" {
    // Compiling, BigInt arithmetic and conversion, and bulk string and
    // object work run in native code that cannot call back into JavaScript;
    // their own polls (or their work charged to the countdown, for a loop of
    // calls too short to reach the VM's poll) must stop them, and the
    // interruption stays uncatchable.
    const Case = struct { setup: []const u8, run: []const u8 };
    const cases = [_]Case{
        .{ .setup = "var src = 'x = 1;\\n'.repeat(20000);", .run = "Function(src)" },
        .{ .setup = "var src = 'x = 1;\\n'.repeat(20000);", .run = "eval(src)" },
        .{ .setup = "var src = 'x = 1;\\n'.repeat(20000);", .run = "(0, eval)(src)" },
        .{ .setup = "var b = (1n << 100000n) - 1n;", .run = "String(b)" },
        .{ .setup = "var b = (1n << 100000n) - 1n;", .run = "b.toString(7)" },
        // The parser names a BigInt literal property in base 10.
        .{ .setup = "var src = 'return { 0x' + ((1n << 100000n) - 1n).toString(16) + 'n: 1 }';", .run = "Function(src)" },
        .{ .setup = "var b = (1n << 100000n) - 1n;", .run = "for (var i = 0; i < 100; i++) b * b" },
        .{ .setup = "var s = '9'.repeat(100000);", .run = "BigInt(s)" },
        .{ .setup = "var s = ' '.repeat(100000);", .run = "s.trim()" },
        .{ .setup = "var s = 'a'.repeat(4000000);", .run = "s.toUpperCase()" },
        .{ .setup = "var s = 'a'.repeat(100000);", .run = "s.localeCompare(s)" },
        .{ .setup = "var s = 'a'.repeat(1000000);", .run = "for (var i = 0; i < 100; i++) s.startsWith('b')" },
        .{ .setup = "var f = Function('x'.repeat(1000000));", .run = "for (var i = 0; i < 100; i++) f.toString()" },
        .{ .setup = "", .run = "'ab'.repeat(5000000)" },
        .{ .setup = "", .run = "new Uint8Array(10000000).fill(1)" },
        .{ .setup = "var t = new Float64Array(20000);", .run = "t.toReversed()" },
        .{ .setup = "var t = new Float64Array(20000);", .run = "t.with(0, 1)" },
        .{ .setup = "var o = {}; for (var i = 0; i < 20000; i++) o['k' + i] = i;", .run = "Object.keys(o)" },
        .{ .setup = "var o = {}; for (var i = 0; i < 20000; i++) o['k' + i] = i;", .run = "Object.assign({}, o)" },
        .{ .setup = "var a = new Set(), b = new Set(); for (var i = 0; i < 20000; i++) { a.add(i); b.add(-i); }", .run = "a.union(b)" },
        .{ .setup = "var a = new Array(20000).fill(1);", .run = "[...a]" },
        // A trap-less Proxy makes these prototype chains endless.
        .{ .setup = "var a = { q: 1 }; Object.setPrototypeOf(a, Object.create(new Proxy(a, {})));", .run = "a instanceof function F() {}" },
        .{ .setup = "var a = { q: 1 }; Object.setPrototypeOf(a, Object.create(new Proxy(a, {})));", .run = "({}).isPrototypeOf(a)" },
        .{ .setup = "var a = { q: 1 }; Object.setPrototypeOf(a, Object.create(new Proxy(a, {})));", .run = "for (var k in a);" },
    };
    for (cases) |case| {
        const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
        defer rt.destroy();
        const ctx = try zjs.JSContext.create(rt, .{});
        defer ctx.destroy();
        _ = try ctx.eval(case.setup, .{});
        const run = try std.fmt.allocPrint(std.testing.allocator, "var caught = false; try {{ {s}; }} catch (e) {{ caught = true; }}", .{case.run});
        defer std.testing.allocator.free(run);
        var state = InterruptState{ .remaining = 3 };
        rt.setInterruptHandler(InterruptState.poll, &state);
        try std.testing.expectError(error.Interrupted, ctx.eval(run, .{}));
        rt.setInterruptHandler(null, null);
        try std.testing.expectEqual(@as(?bool, false), (try ctx.eval("caught", .{})).as(.boolean));
    }
}

test "production embedding eval of a module under a loaded filename is a TypeError" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();
    _ = try ctx.eval("globalThis.runs = 1; export const a = 1;", .{ .mode = .module, .filename = "a.mjs" });
    // The second source used to be ignored in favour of the loaded record.
    try std.testing.expectError(error.JSException, ctx.eval("globalThis.runs = 2;", .{ .mode = .module, .filename = "a.mjs" }));
    const thrown = ctx.takeException();
    const text = try ctx.formatException(thrown, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("TypeError: module 'a.mjs' is already loaded; evaluate new module source under a new filename", text);
    try std.testing.expectEqual(@as(?i32, 1), (try ctx.eval("runs", .{})).as(.int));
    // Unnamed modules skip a `<eval>#N` the embedder already used.
    _ = try ctx.eval("export const b = 1;", .{ .mode = .module, .filename = "<eval>#1" });
    _ = try ctx.eval("globalThis.runs = 3;", .{ .mode = .module });
    _ = try ctx.eval("globalThis.runs += 1;", .{ .mode = .module });
    try std.testing.expectEqual(@as(?i32, 4), (try ctx.eval("runs", .{})).as(.int));
}

test "String.prototype.repeat copies whole repetitions past its poll slice" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();
    // 7 does not divide the copy slice; an unaligned copy broke the period.
    try std.testing.expectEqual(@as(?bool, true), (try ctx.eval("var u = 'abcdefg'; u.repeat(400000) === new Array(400001).join(u) && '\\u00e9z\\u4e00'.repeat(500000) === new Array(500001).join('\\u00e9z\\u4e00')", .{})).as(.boolean));
}

test "production embedding interrupt at any compile poll leaves the realm usable" {
    // Sweep the stop across every poll of one compile -- parser, variable
    // and label resolution, stack sizing -- until it completes.
    var countdown: usize = 0;
    while (true) : (countdown += 1) {
        try std.testing.expect(countdown < 1000);
        const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
        defer rt.destroy();
        const ctx = try zjs.JSContext.create(rt, .{});
        defer ctx.destroy();
        _ = try ctx.eval("var src = 'if (x) { x = [x, x + 1]; }\\n'.repeat(3000); var x = 0;", .{});
        var state = InterruptState{ .remaining = countdown };
        rt.setInterruptHandler(InterruptState.poll, &state);
        const result = ctx.eval("var f; try { f = Function(src); } catch (e) { f = e; }", .{});
        rt.setInterruptHandler(null, null);
        if (result) |_| {
            try std.testing.expectEqual(@as(?bool, true), (try ctx.eval("typeof f === 'function' && f() === undefined && x === 0", .{})).as(.boolean));
            break;
        } else |err| try std.testing.expectEqual(error.Interrupted, err);
        try std.testing.expectEqual(@as(?bool, true), (try ctx.eval("f === undefined", .{})).as(.boolean));
        try std.testing.expectEqual(@as(?i32, 3), (try ctx.eval("Function('return 1 + 2')()", .{})).as(.int));
    }
}

test "production embedding interrupt and termination stop a blocked Atomics.wait" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{ .can_block = true });
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();
    _ = try ctx.eval("var view = new Int32Array(new SharedArrayBuffer(4));", .{});
    var state = InterruptState{ .remaining = 3 };
    rt.setInterruptHandler(InterruptState.poll, &state);
    // Without a timeout this would block forever.
    try std.testing.expectError(error.Interrupted, ctx.eval("Atomics.wait(view, 0, 0)", .{}));
    rt.setInterruptHandler(null, null);
    // The waiter was removed: a later notify finds nobody.
    try std.testing.expectEqual(@as(?i32, 0), (try ctx.eval("Atomics.notify(view, 0)", .{})).as(.int));
}

test "production embedding interrupt inside a dispose callback stays uncatchable" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    // Disposal collects ordinary throws into its completion; an interruption
    // must not be collected, run later callbacks, or reach the JS catch. The
    // countdown lets the setup run so the interrupt lands in the dispose loop.
    var state = InterruptState{ .remaining = 1000 };
    rt.setInterruptHandler(InterruptState.poll, &state);
    defer rt.setInterruptHandler(null, null);
    try std.testing.expectError(error.Interrupted, ctx.eval(
        \\globalThis.reached = false;
        \\globalThis.caught = false;
        \\try { using a = { [Symbol.dispose]() { reached = true; } }; using b = { [Symbol.dispose]() { for (;;) {} } }; } catch (e) { caught = true; }
    , .{}));
    state.remaining = 1000;
    try std.testing.expectError(error.Interrupted, ctx.eval(
        \\try { const s = new DisposableStack(); s.defer(() => { for (;;) {} }); s.dispose(); } catch (e) { caught = true; }
    , .{}));
    rt.setInterruptHandler(null, null);
    try std.testing.expectEqual(@as(?bool, true), (try ctx.eval("reached === false && caught === false", .{})).as(.boolean));
}

test "production embedding interrupt handler aborts conditional-only backedge" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var state = InterruptState{ .stop = true };
    rt.setInterruptHandler(InterruptState.poll, &state);
    defer rt.setInterruptHandler(null, null);

    // A do/while loop closes with OP_if_true8 rather than OP_goto8. Conditional
    // branches must therefore poll just like unconditional backedges do.
    try std.testing.expectError(error.Interrupted, ctx.eval("do {} while (true);", .{}));
    try std.testing.expect(state.hits > 0);
}

test "production embedding interrupt handler aborts a recursion-only call loop" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var state = InterruptState{ .stop = true };
    rt.setInterruptHandler(InterruptState.poll, &state);
    defer rt.setInterruptHandler(null, null);

    // There is no bytecode backedge in recurse: interruption depends on the
    // bytecode-call entry poll, matching QuickJS JS_CallInternal's poll point.
    try std.testing.expectError(
        error.Interrupted,
        ctx.eval("function recurse() { return 1 + recurse(); } recurse();", .{}),
    );
    try std.testing.expect(state.hits > 0);
}
