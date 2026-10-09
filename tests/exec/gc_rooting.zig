//! Exec integration tests: gc_rooting.
const native_alloc = @import("zjs").core.runtime.native_allocation;
const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const core = zjs.core;
const helpers = @import("../harness.zig");
const bytecode = zjs.bytecode;
const op = zjs.bytecode.opcode.op;
const object_ops = zjs.exec.object_ops;
const array_ops = zjs.exec.array_ops;
const common = @import("common.zig");
const makeFixture = common.makeFixture;
const runFixture = common.runFixture;
const globalFunctionBytecode = common.globalFunctionBytecode;

// ---------------------------------------------------------------------------
// C0 late-encoding pilot (opcode-design.md 11.7 D7/D11): to_propkey's final
// encoding is {using, sub.to_propkey}; the direct id 112 is an executable
// alias for the migration window only.
// ---------------------------------------------------------------------------

test "C0: final artifacts carry the carrier encoding and no direct to_propkey" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    _ = try js.eval("function c0ComputedKey(k){ return { [k]: 1 }; }");

    const fb = try globalFunctionBytecode(js, "c0ComputedKey");
    const code = fb.byteCode();
    var pc: usize = 0;
    var carrier_count: usize = 0;
    var direct_count: usize = 0;
    while (pc < code.len) {
        const op_id = code[pc];
        const size = bytecode.opcode.sizeOf(op_id);
        try std.testing.expect(size != 0 and pc + size <= code.len);
        if (op_id == op.ext0 and code[pc + 1] == bytecode.opcode.ext0_sub.to_propkey)
            carrier_count += 1;
        if (op_id == op.to_propkey) direct_count += 1;
        pc += size;
    }
    try std.testing.expectEqual(@as(usize, 1), carrier_count);
    try std.testing.expectEqual(@as(usize, 0), direct_count);
}

test "C0: a throw inside key coercion attributes the frame to the carrier's source pc" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalWithOptions(
        \\function maker(bad){
        \\  return { [bad]: 1 };
        \\}
        \\var boom = { [Symbol.toPrimitive]: function(){ throw new Error("bt"); } };
        \\var captured;
        \\try { maker(boom); } catch (e) { captured = e.stack; }
        \\assert.sameValue(captured.indexOf("at maker (c0tpk.js:2:") >= 0, true, captured);
        \\assert.sameValue(captured.indexOf("at <eval> (c0tpk.js:") >= 0, true, captured);
    , .{ .filename = "c0tpk.js" });
    try std.testing.expect(result.is(.undefined_value));
}

test "C0 closed: the carrier encoding executes and the quarantined direct id is rejected" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    // Non-object keys pass through the handler unconverted (the atom
    // conversion happens at the consuming define). The full coercion
    // matrix is the JS fixture suite's job.
    const carrier = try makeFixture(rt, ctx, .{ .code = &.{
        op.undefined, op.ext0, bytecode.opcode.ext0_sub.to_propkey, op.@"return",
    } });
    defer carrier.release(rt);
    const carrier_result = try runFixture(rt, ctx, carrier.fb);
    try std.testing.expect(carrier_result.is(.undefined_value));

    // 11.0 end state: the reclaimed direct byte must not survive final
    // validation -- the stack pass rejects it at decode.
    try std.testing.expectError(
        error.InvalidOpcode,
        makeFixture(rt, ctx, .{ .code = &.{ op.undefined, op.to_propkey, op.@"return" } }),
    );
}

test "C0/D7: an unknown carrier tag is rejected by the artifact proof and by dispatch" {
    // The tag after the last resident opens the gap below the add range:
    // no resident claims it and it is not an add hint.
    const bad_code = [_]u8{ op.undefined, op.ext0, engine.bytecode.opcode.ext0_sub.iterator_step + 1, op.@"return" };

    // The final-artifact proof refuses it outright.
    try std.testing.expectError(error.InvalidFinalArtifact, engine.bytecode.pipeline.stack_size.compute(&bad_code, .{
        .scratch_allocator = std.testing.allocator,
        .final_artifact = .{ .atom_owners = &.{}, .closure_var_count = 0 },
    }));

    // And if a stream reaches dispatch anyway, the executor rejects it.
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const function = try makeFixture(rt, ctx, .{ .code = &bad_code });
    defer function.release(rt);
    try std.testing.expectError(error.InvalidBytecode, runFixture(rt, ctx, function.fb));
}

test "C1-1: computed-name function naming rides the carrier encoding" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Semantics: name inference through the carrier form, for string,
    // derived-string and symbol keys (test262 covers the full matrix; this
    // pins the engine-local path end to end).
    const result = try js.eval(
        \\function mk(k){ return { [k]: function(){} }; }
        \\assert.sameValue(mk("nm").nm.name, "nm");
        \\assert.sameValue(mk("a" + "b").ab.name, "ab");
        \\var s = Symbol("sy");
        \\assert.sameValue(Object.getOwnPropertySymbols(mk(s)).length, 1);
        \\assert.sameValue(mk(s)[s].name, "[sy]");
    );
    try std.testing.expect(result.is(.undefined_value));

    // Artifact shape: the carrier pair once, the direct id never.
    const fb = try globalFunctionBytecode(js, "mk");
    const code = fb.byteCode();
    var pc: usize = 0;
    var carrier_count: usize = 0;
    var direct_count: usize = 0;
    while (pc < code.len) {
        const op_id = code[pc];
        const size = bytecode.opcode.sizeOf(op_id);
        try std.testing.expect(size != 0 and pc + size <= code.len);
        if (op_id == op.ext0 and code[pc + 1] == bytecode.opcode.ext0_sub.set_name_computed)
            carrier_count += 1;
        if (op_id == op.set_name_computed) direct_count += 1;
        pc += size;
    }
    try std.testing.expectEqual(@as(usize, 1), carrier_count);
    try std.testing.expectEqual(@as(usize, 0), direct_count);
}

// --- TGC S3-b: native atom roots -----------
//
// The switch is off, so `AtomTable.sweepDead` runs as the §2.6 shadow audit:
// at every major it reports each entry `ref_count` still holds that no trace
// edge or root reached. For a native frame holding a bare id that reading is
// exactly "the id was NOT `mark_epoch == epoch` while the frame held it" --
// and it is the stronger form, because it fires at every major inside the
// window instead of one sampled instant.
//
// Allocation-point collections are what production actually takes mid-window,
// so the probe rides the heap-budget probe seam and runs a real major from
// there. `.engine_active` keeps the conservative stack scan in play, which
// cannot help: an atom id is a bare `u32`, indistinguishable from any other
// integer.

const S3MajorAtEveryAllocationProbe = struct {
    rt: *core.JSRuntime,
    active: bool = false,
    majors: usize = 0,

    fn trigger(context: ?*anyopaque, size: usize) void {
        _ = size;
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (!self.active) return;
        const before = self.rt.gc.block_heap.mark_epoch;
        _ = self.rt.collectFull() catch {};
        if (self.rt.gc.block_heap.mark_epoch != before) self.majors += 1;
    }
};

test "TGC S3: JSON.parse object keys stay reachable across majors taken mid-parse" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    // Spellings that are not predefined atoms, so each key really becomes a
    // dynamic entry the parser holds as a bare `Atom` while it recurses into
    // the value. The `\u` escape keeps the first source off the
    // SimpleJsonParser fast path, so both parse loops are covered.
    const sources = [_][]const u8{
        "{\"zjsS3JsonKeyAlpha\":{\"zjsS3JsonKeyBeta\":[1,2,3,4,5,6,7,8]},\"zjsS3JsonKeyGamma\":\"\\u0041\"}",
        "{\"zjsS3JsonSimpleKey\":1,\"zjsS3JsonSimpleOther\":2,\"zjsS3JsonSimpleThird\":3}",
    };

    var probe = S3MajorAtEveryAllocationProbe{ .rt = rt };
    const saved_trigger_fn = rt.gc.heap_budget.installProbe(.{ .run = S3MajorAtEveryAllocationProbe.trigger, .context = &probe });
    defer rt.gc.heap_budget.restoreProbe(saved_trigger_fn);

    for (sources) |source| {
        var text = (try core.string.String.createAscii(rt, source)).value();
        var text_roots = core.runtime.rootValues(.{&text});
        text_roots.activate(rt);
        defer text_roots.deactivate(rt);

        rt.atoms.atom_audit_stale_edge = 0;
        probe.majors = 0;
        probe.active = true;
        const parsed = engine.exec.json_ops.parse(rt, null, text) catch |err| {
            probe.active = false;
            return err;
        };
        probe.active = false;

        var parsed_value = parsed;
        var parsed_roots = core.runtime.rootValues(.{&parsed_value});
        parsed_roots.activate(rt);
        defer parsed_roots.deactivate(rt);

        // Guard against a vacuous pass. The heap-budget probe's collectFull
        // advances block_heap.mark_epoch while JSON.parse is allocating.
        try std.testing.expect(probe.majors > 0);
        try std.testing.expectEqual(@as(usize, 0), rt.atoms.atom_audit_stale_edge);

        // The keys survived as property names, not merely as audit-clean
        // entries: every own key still resolves to a spelling.
        const object = object_ops.objectFromValue(parsed_value) orelse return error.TestUnexpectedResult;
        const keys = try object.ownKeys(rt);
        defer core.Object.freeKeys(rt, keys);
        try std.testing.expect(keys.len >= 2);
        for (keys) |key| try std.testing.expect(rt.atoms.name(key) != null);
    }
}

test "TGC S3-c: operand-stack strings stay rooted while a later push materializes its atom" {
    if (comptime native_alloc.force_gc_on_allocation_enabled) return error.SkipZigTest;
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    rt.forcePreciseRootScanForTest();

    // Interning does NOT materialize `entry.str`; the first OP_push_atom_value
    // for each id does, and that arm allocates. The resident handler used to
    // run it with the operand stack unpublished -- `Stack.liveValues` stops at
    // `top_ptr` -- so the materialization of push k collected the bodies of
    // pushes 0..k-1, which were sitting above it, and the destroy handshake
    // unbound each from its entry. `op_array_from` has published for exactly
    // this reason since it was written; `op_push_atom_value` had not. Before
    // TGC S3-c the victims survived by accident: `AtomTable.traceRoots`
    // reported every `entries[].str` as a strong root.
    //
    // The observation is made INSIDE the window: a collection forced at every
    // allocation may never reduce the number of materialized bodies, because
    // the only thing holding them is the operand stack under the push cursor.
    const spellings = [_][]const u8{
        "zjsS3PushRoot0", "zjsS3PushRoot1", "zjsS3PushRoot2", "zjsS3PushRoot3",
        "zjsS3PushRoot4", "zjsS3PushRoot5", "zjsS3PushRoot6", "zjsS3PushRoot7",
    };
    var ids: [spellings.len]core.Atom = undefined;
    var code: [spellings.len * 5 + 1]u8 = undefined;
    var offset: usize = 0;
    for (spellings, &ids) |spelling, *id| {
        id.* = try rt.internAtom(spelling);
        try std.testing.expect(rt.atoms.cachedString(id.*) == null);
        code[offset] = op.push_atom_value;
        std.mem.writeInt(u32, code[offset + 1 ..][0..4], id.*.raw(), .little);
        offset += 5;
    }
    code[offset] = op.return_undef;
    offset += 1;

    // The fixture is a legacy `Bytecode`, not a traced `FunctionBytecode`, so
    // its inline atom operands carry no tracer edge; the forced majors below
    // would retire the entries themselves and every push would hand back
    // `undefined`. A real script's ids ride the FunctionBytecode's edge.
    var rooted_ids: []core.Atom = ids[0..];
    var id_roots = core.runtime.rootAtomList(&rooted_ids);
    id_roots.activate(rt);
    defer id_roots.deactivate(rt);

    const function = try makeFixture(rt, ctx, .{ .code = code[0..offset] });
    defer function.release(rt);

    // Warm up UNARMED: the first run installs the host globals, and that
    // install is not collection-safe. It touches no atom under test.
    {
        const warmup = try makeFixture(rt, ctx, .{ .code = &.{ op.push_i32, 1, 0, 0, 0, op.@"return" } });
        defer warmup.release(rt);
        const warmed = try runFixture(rt, ctx, warmup.fb);
        try std.testing.expectEqual(@as(i32, 1), warmed.as(.int).?);
    }

    const Probe = struct {
        rt: *core.JSRuntime,
        ids: []const core.Atom,
        majors: usize = 0,
        peak_cached: usize = 0,
        regressed: bool = false,
        armed: bool = false,

        fn trigger(context: ?*anyopaque, _: usize) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (!self.armed) return;
            self.armed = false;
            defer self.armed = true;
            self.majors += 1;
            _ = self.rt.collectFull() catch {};
            var cached: usize = 0;
            for (self.ids) |id| {
                if (self.rt.atoms.cachedString(id) != null) cached += 1;
            }
            if (cached < self.peak_cached) self.regressed = true;
            self.peak_cached = @max(self.peak_cached, cached);
        }
    };
    var probe = Probe{ .rt = rt, .ids = ids[0..] };
    const saved_fn = rt.gc.heap_budget.installProbe(.{ .run = Probe.trigger, .context = &probe });
    probe.armed = true;
    const outcome = runFixture(rt, ctx, function.fb);
    probe.armed = false;
    rt.gc.heap_budget.restoreProbe(saved_fn);
    _ = try outcome;

    // Guards against a vacuous pass: the window has to have been collected in,
    // and all eight bodies have to have been materialized.
    try std.testing.expect(probe.majors > 0);
    // The last push's body is minted after the last forced collection, so the
    // highest count an observation can see is seven.
    try std.testing.expectEqual(spellings.len - 1, probe.peak_cached);
    try std.testing.expect(!probe.regressed);

    _ = try rt.collectForTest();
}

// ---------------------------------------------------------------------------
// TGC S3-d "publish before allocating" regression set.
//
// `Stack.liveValues` stops at the published `stack.top_ptr`, and a resident
// dispatch handler advances only the register `sp`, so every operand pushed
// since the last publish is outside the precise root set until the handler
// syncs the boundary. Each test below drives one handler whose slow arm
// allocates, with a string materialized into an operand slot ABOVE the stale
// published top. The observable is the atom table's materialized body: the
// destroy handshake unbinds `entry.str`, so a collected body turns
// `cachedString` back into null. Same instrument as the S3-c push_atom_value
// test above.
// ---------------------------------------------------------------------------

/// Forces a major at every heap allocation and watches one atom's materialized
/// body. `seen` records that the body existed at some observation; `regressed`
/// records that a LATER observation found it gone.
const PublishRootProbe = struct {
    rt: *core.JSRuntime,
    id: core.Atom,
    majors: usize = 0,
    seen: bool = false,
    regressed: bool = false,
    armed: bool = false,

    fn trigger(context: ?*anyopaque, _: usize) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (!self.armed) return;
        self.armed = false;
        defer self.armed = true;
        self.majors += 1;
        _ = self.rt.collectFull() catch {};
        if (self.rt.atoms.cachedString(self.id) != null) {
            self.seen = true;
        } else if (self.seen) {
            self.regressed = true;
        }
    }
};

/// Run `function` with the conservative native-stack net switched off and a
/// major forced at every allocation, so only the precise operand-stack roots
/// can keep the victim body alive. The realm is warmed unarmed first: the
/// host-global install is not collection-safe and touches nothing under test.
fn runUnderPublishProbe(
    rt: *core.JSRuntime,
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    probe: *PublishRootProbe,
) !core.JSValue {
    {
        const warmup = try makeFixture(rt, ctx, .{ .code = &.{ op.push_i32, 1, 0, 0, 0, op.@"return" } });
        defer warmup.release(rt);
        const warmed = try runFixture(rt, ctx, warmup.fb);
        try std.testing.expectEqual(@as(i32, 1), warmed.as(.int).?);
    }

    rt.forcePreciseRootScanForTest();
    const saved_fn = rt.gc.heap_budget.installProbe(.{ .run = PublishRootProbe.trigger, .context = probe });
    probe.armed = true;
    var vm = engine.exec.Vm.init(ctx);
    defer vm.deinit();
    const outcome = vm.run(function);
    probe.armed = false;
    rt.gc.heap_budget.restoreProbe(saved_fn);
    rt.restoreDefaultRootScanForTest();
    return outcome;
}

test "TGC S3-d: an inline call's argument region stays rooted while the callee frame is pushed" {
    if (comptime native_alloc.force_gc_on_allocation_enabled) return error.SkipZigTest;
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    // `op_call1` retreats the operand top to the call region and hands the
    // slots above it to `Stack.pendingCallRegion` -- the window that exists
    // precisely because the retreated operands are invisible to both
    // `liveValues` and the conservative pass. It used to compute that window's
    // high end from the STALE published `top_ptr`, which at a register-resident
    // call site sits below the freshly pushed operands, so the argument fell
    // outside the published span and `Machine.pushPlainCall`'s first-use arena
    // allocation collected it.
    const victim_atom = try rt.internAtom("zjsH4CallArgVictim");
    try std.testing.expect(rt.atoms.cachedString(victim_atom) == null);

    const callee_name = try rt.internAtom("zjsH4Id");
    const callee_fb = try bytecode.FunctionBytecode.createFixture(rt, .{
        .name = callee_name,
        .realm = ctx,
        .flags = .{ .has_simple_parameter_list = true, .func_kind = .normal },
        .arg_count = 1,
        .defined_arg_count = 1,
        .stack_size = 4,
        .byte_code = &.{ op.get_arg0, op.@"return" },
    });
    callee_fb.publishFixtureNoFail(rt);

    const global = try engine.exec.zjs_vm.contextGlobal(ctx);
    const callee = try object_ops.createRootBytecodeFunctionObject(
        ctx,
        global,
        core.JSValue.functionBytecode(&callee_fb.header),
        .root_global,
    );

    var code: [12]u8 = undefined;
    code[0] = op.push_const;
    std.mem.writeInt(u32, code[1..5], 0, .little);
    code[5] = op.push_atom_value;
    std.mem.writeInt(u32, code[6..10], victim_atom.raw(), .little);
    code[10] = op.call1;
    code[11] = op.@"return";
    const function = try makeFixture(rt, ctx, .{ .code = code[0..], .cpool = &.{callee} });
    defer function.release(rt);

    // A legacy `Bytecode` fixture carries no tracer edge for its inline atom
    // operands (see the S3-c test), so the forced majors would retire the atom
    // entry itself instead of exercising the operand root.
    var rooted_ids = [_]core.Atom{victim_atom};
    var rooted_slice: []core.Atom = rooted_ids[0..];
    var id_roots = core.runtime.rootAtomList(&rooted_slice);
    id_roots.activate(rt);
    defer id_roots.deactivate(rt);

    var probe = PublishRootProbe{ .rt = rt, .id = victim_atom };
    const result = try runUnderPublishProbe(rt, ctx, function.fb, &probe);

    // Non-vacuity: the body has to have been minted and observed inside the
    // window (`seen`), and the window has to have been collected in
    // (`majors`). `regressed` is the failure the publish gap produced.
    try std.testing.expect(probe.majors > 0);
    try std.testing.expect(probe.seen);
    try std.testing.expect(!probe.regressed);
    try helpers.expectStringValueBytes(result, "zjsH4CallArgVictim");

    _ = try rt.collectForTest();
}

test "TGC S3-d: op_put_array_el's cold arm publishes before the dense grow allocates" {
    if (comptime native_alloc.force_gc_on_allocation_enabled) return error.SkipZigTest;
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    // `op_put_array_el_cold` reaches `setFastArrayElement`
    // / the dense append / the sparse and typed-array writers, every one of
    // which can allocate. It ran entirely off the register-resident `sp`, so
    // the operands the expression had already evaluated -- here the string in
    // slot 0 -- sat above the stale `top_ptr` while the array's storage grew.
    const victim_atom = try rt.internAtom("zjsH4PutArrayVictim");
    try std.testing.expect(rt.atoms.cachedString(victim_atom) == null);

    const global = try engine.exec.zjs_vm.contextGlobal(ctx);
    // A zero-capacity fast array: index 0 misses both the in-bounds arm and the
    // no-grow append arm, so the store falls to the cold twin and grows.
    const array = try array_ops.createArrayFromArgs(rt, global, &.{});

    var code: [18]u8 = undefined;
    code[0] = op.push_atom_value;
    std.mem.writeInt(u32, code[1..5], victim_atom.raw(), .little);
    code[5] = op.push_const;
    std.mem.writeInt(u32, code[6..10], 0, .little);
    code[10] = op.push_0;
    code[11] = op.push_1;
    code[12] = op.put_array_el;
    code[13] = op.@"return";
    const function = try makeFixture(rt, ctx, .{ .code = code[0..14], .cpool = &.{array} });
    defer function.release(rt);

    var rooted_ids = [_]core.Atom{victim_atom};
    var rooted_slice: []core.Atom = rooted_ids[0..];
    var id_roots = core.runtime.rootAtomList(&rooted_slice);
    id_roots.activate(rt);
    defer id_roots.deactivate(rt);

    var probe = PublishRootProbe{ .rt = rt, .id = victim_atom };
    const result = try runUnderPublishProbe(rt, ctx, function.fb, &probe);

    try std.testing.expect(probe.majors > 0);
    try std.testing.expect(probe.seen);
    try std.testing.expect(!probe.regressed);
    try helpers.expectStringValueBytes(result, "zjsH4PutArrayVictim");

    _ = try rt.collectForTest();
}

test "TGC S3-d: the string-primitive get_field2 arm publishes before the auto-init resolver allocates" {
    if (comptime native_alloc.force_gc_on_allocation_enabled) return error.SkipZigTest;
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    // `op_get_field2_primitive`'s second arm calls the MATERIALIZING
    // String.prototype resolver (`getFastStringPrimitiveDataProperty`), which
    // allocates the auto-init entry. It ran unpublished, so both the receiver
    // in `sp - 1` and everything pushed before it were outside the root set.
    const victim_atom = try rt.internAtom("zjsH4StrFieldVictim");
    const method_atom = try rt.internAtom("charCodeAt");
    try std.testing.expect(rt.atoms.cachedString(victim_atom) == null);

    var code: [16]u8 = undefined;
    code[0] = op.push_atom_value;
    std.mem.writeInt(u32, code[1..5], victim_atom.raw(), .little);
    code[5] = op.get_field2;
    std.mem.writeInt(u32, code[6..10], method_atom.raw(), .little);
    // W1: `get_field2` is `atom_cache_u8`; this hand-built stream has no
    // `prop_sites` tail, so the site carries the no-cache index.
    code[10] = bytecode.PropSiteCache.no_cache_idx;
    code[11] = op.drop;
    code[12] = op.@"return";
    const function = try makeFixture(rt, ctx, .{ .code = code[0..13] });
    defer function.release(rt);

    var rooted_ids = [_]core.Atom{ victim_atom, method_atom };
    var rooted_slice: []core.Atom = rooted_ids[0..];
    var id_roots = core.runtime.rootAtomList(&rooted_slice);
    id_roots.activate(rt);
    defer id_roots.deactivate(rt);

    var probe = PublishRootProbe{ .rt = rt, .id = victim_atom };
    const result = try runUnderPublishProbe(rt, ctx, function.fb, &probe);

    try std.testing.expect(probe.majors > 0);
    try std.testing.expect(probe.seen);
    try std.testing.expect(!probe.regressed);
    try helpers.expectStringValueBytes(result, "zjsH4StrFieldVictim");

    _ = try rt.collectForTest();
}

test "an unresolved binding names its identifier in the ReferenceError message (qjs JS_ThrowReferenceErrorNotDefined)" {
    try helpers.expectPrints(
        \\try { zjsUndeclaredRead; } catch (e) { print(e.name + ": " + e.message + " " + (e instanceof ReferenceError)); }
        \\try { zjsUndeclaredCall(); } catch (e) { print(e.message); }
        \\try { zjsUndeclaredMember.x; } catch (e) { print(e.message); }
        \\try { (function () { "use strict"; zjsUndeclaredAssign = 1; })(); } catch (e) { print(e.message); }
        \\try { (function () { "use strict"; zjsUndeclaredUpdate++; })(); } catch (e) { print(e.message); }
        \\try { (function () { zjsUndeclaredInner; })(); } catch (e) { print(e.message); }
        \\print(typeof zjsUndeclaredTypeof, delete zjsUndeclaredDelete);
        \\zjsSloppyAssign = 1; print(zjsSloppyAssign);
    ,
        \\ReferenceError: 'zjsUndeclaredRead' is not defined true
        \\'zjsUndeclaredCall' is not defined
        \\'zjsUndeclaredMember' is not defined
        \\'zjsUndeclaredAssign' is not defined
        \\'zjsUndeclaredUpdate' is not defined
        \\'zjsUndeclaredInner' is not defined
        \\undefined true
        \\1
        \\
    );
}
