//! Exec integration tests: realms_modules.
const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const core = zjs.core;
const helpers = @import("../harness.zig");
const property_ops = zjs.exec.property_ops;
const object_ops = zjs.exec.object_ops;
const common = @import("common.zig");
const CrossRealmNativeProbe = common.CrossRealmNativeProbe;
const crossRealmNativeProbe = common.crossRealmNativeProbe;
const expectRejectedPromiseNamedError = common.expectRejectedPromiseNamedError;

const ExternalNamedErrorProbe = struct {
    fn call(_: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
        return error.HostProbeFailure;
    }
};

test "FinalizationRegistry cleanup job keeps registry realm before invoking callback realm" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const registry_facade = try zjs.JSContext.create(rt, .{});
    var registry_facade_alive = true;
    defer if (registry_facade_alive) registry_facade.destroy();
    const registry_realm = registry_facade.core;
    _ = try zjs.globalObjectPtr(registry_facade);

    const callback_facade = try zjs.JSContext.create(rt, .{});
    var callback_facade_alive = true;
    defer if (callback_facade_alive) callback_facade.destroy();
    const callback_realm = callback_facade.core;
    const callback_global = try zjs.globalObjectPtr(callback_facade);
    try std.testing.expect(registry_realm != callback_realm);

    var probe: CrossRealmNativeProbe = .{};
    const callback = try core.function.nativeFunction(callback_realm, "finalizationRealmProbe", 1);
    const callback_object = try core.Object.expect(callback);
    try helpers.TestEngine.installLegacyProbeEntry(rt, callback_object, &probe, crossRealmNativeProbe);

    const registry_value = try object_ops.constructFinalizationRegistryWithPrototype(
        registry_realm,
        callback,
        null,
    );
    const registry = try core.Object.expect(registry_value);
    // The registry is held only by this Zig local once both facades are
    // destroyed (deliberately — the test observes the registry keeping its
    // realms alive on its own). Name it for the tracing sweep; `target`
    // stays unrooted because its collection is the event under test.
    var registry_slot: ?*core.Object = registry;
    var registry_roots = core.runtime.rootObjects(.{&registry_slot});
    registry_roots.activate(rt);
    defer registry_roots.deactivate(rt);
    try std.testing.expectEqual(registry_realm, registry.finalizationRegistryRealmContext().?);
    try std.testing.expectEqual(callback_realm, callback_object.nativeFunctionRealm().?);

    // Drop both public construction owners before GC. The registry and
    // callback carriers must independently keep their construction Realms
    // alive through enqueue and invocation.
    registry_facade.destroy();
    registry_facade_alive = false;
    callback_facade.destroy();
    callback_facade_alive = false;

    const target = try core.Object.create(rt, core.class.ids.object, null);
    try registry.appendFinalizationRegistryCell(
        rt,
        target.value(),
        core.JSValue.int32(73),
        core.JSValue.undefinedValue(),
    );
    _ = try rt.forceGC(null);

    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.countKind(.finalization));
    try std.testing.expectEqual(registry_realm, rt.job_queue.jobs[0].realm.borrow().?);
    const queued_payload = switch (rt.job_queue.jobs[0].payload) {
        .finalization => |payload| payload,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(?i32, 73), queued_payload.held_value.as(.int));

    // The job starts with the registry construction realm, but the final call
    // still follows the callback C_FUNCTION's independent RealmRef.
    try std.testing.expectEqual(
        .exception,
        try engine.exec.promise_ops.drainOnePendingJob(registry_realm, null),
    );
    try std.testing.expectEqual(callback_realm, probe.seen_realm.?);
    try std.testing.expectEqual(callback_global, probe.seen_global.?);
    try std.testing.expectEqual(@as(usize, 0), rt.job_queue.countKind(.finalization));
    registry_realm.clearException();
}

test "event-loop caller reaches external C function with one callee realm view" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    _ = try js.eval(
        \\(function () {
        \\    globalThis.__calleeRealm = $262.createRealm().global;
        \\    globalThis.__callerRealm = $262.createRealm().global;
        \\})();
    );

    const loop_global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const callee_key = try js.runtime.internAtom("__calleeRealm");
    const caller_key = try js.runtime.internAtom("__callerRealm");
    const callee_value = try loop_global.getProperty(callee_key);
    const caller_value = try loop_global.getProperty(caller_key);
    const callee_global = try core.Object.expect(callee_value);
    const caller_global = try core.Object.expect(caller_value);
    const callee_realm = js.runtime.contexts.forGlobal(callee_global, .include_constructing) orelse return error.TestUnexpectedResult;
    const caller_realm = js.runtime.contexts.forGlobal(caller_global, .include_constructing) orelse return error.TestUnexpectedResult;
    try std.testing.expect(callee_realm != caller_realm);
    try std.testing.expect(callee_realm != js.context);
    try std.testing.expect(caller_realm != js.context);

    var probe: CrossRealmNativeProbe = .{};
    const native_value = try core.function.nativeFunction(callee_realm, "realmProbe", 0);
    const native_object = try core.Object.expect(native_value);
    try helpers.TestEngine.installLegacyProbeEntry(js.runtime, native_object, &probe, crossRealmNativeProbe);

    const escaped_key = try js.runtime.internAtom("__escapedNative");
    try caller_global.defineOwnProperty(
        js.runtime,
        escaped_key,
        core.Descriptor.data(native_value, .all),
    );

    var caller_wrapper = zjs.borrowContext(caller_realm);
    _ = try caller_wrapper.eval(
        \\globalThis.__eventLoopWrapper = function () {
        \\    globalThis.__caller_body_ran = true;
        \\    try {
        \\        __escapedNative();
        \\    } catch (error) {
        \\        globalThis.__callee_error = error;
        \\    }
        \\};
    , .{});
    const wrapper_key = try js.runtime.internAtom("__eventLoopWrapper");
    const wrapper_value = try caller_global.getProperty(wrapper_key);

    try js.event_loop.enqueueTimer(js.context, 1, wrapper_value, 0);
    try std.testing.expect(try js.event_loop.runNextTimer(js.context, null, loop_global));

    try std.testing.expectEqual(callee_realm, probe.seen_realm.?);
    try std.testing.expectEqual(callee_global, probe.seen_global.?);
    const mutation_key = try js.runtime.internAtom("__native_realm_mutation");
    const callee_mutation = try callee_global.getProperty(mutation_key);
    const caller_mutation = try caller_global.getProperty(mutation_key);
    const loop_mutation = try loop_global.getProperty(mutation_key);
    try std.testing.expectEqual(@as(?i32, 1), callee_mutation.as(.int));
    try std.testing.expect(caller_mutation.is(.undefined_value));
    try std.testing.expect(loop_mutation.is(.undefined_value));

    const error_key = try js.runtime.internAtom("__callee_error");
    const caught_error = try caller_global.getProperty(error_key);
    const caught_object = try core.Object.expect(caught_error);
    const type_error_value = try callee_global.getProperty(core.atom.predefinedId("TypeError", .string).?);
    const type_error_constructor = try core.Object.expect(type_error_value);
    const type_error_prototype_value = try type_error_constructor.getProperty(core.atom.ids.prototype);
    const type_error_prototype = try core.Object.expect(type_error_prototype_value);
    try std.testing.expectEqual(type_error_prototype, caught_object.getPrototype().?);

    const body_ran_key = try js.runtime.internAtom("__caller_body_ran");
    const body_ran = try caller_global.getProperty(body_ran_key);
    try std.testing.expectEqual(true, body_ran.as(.boolean).?);
}

test "true C function without its RealmRef fails the final-arm invariant" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);

    const function_value = try core.function.nativeFunction(js.context, "missingRealm", 0);
    const function_object = try core.Object.expect(function_value);
    function_object.hostFunctionKindSlot().* = core.host_function.ids.output;
    // Strip the payload's realm edge (the runtime-teardown release helper
    // went with realm refcounting); the plain-pointer RealmRef just forgets it.
    function_object.forgetNativeFunctionRealmForTest();

    try std.testing.expectError(
        error.InvalidBuiltinRegistry,
        engine.exec.call_runtime.callValueOrBytecodeRoot(
            js.context,
            null,
            global,
            core.JSValue.undefinedValue(),
            function_value,
            &.{},
            null,
            null,
        ),
    );
}

test "bundled output writer failure is a catchable named Error" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);

    const function_value = try core.function.nativeFunction(js.context, "legacyPrint", 1);
    const function_object = try core.Object.expect(function_value);
    function_object.hostFunctionKindSlot().* = core.host_function.ids.output;
    function_object.installNativeEntry(&@import("zjs_host").output.output_host_entry);
    const name = try js.runtime.internAtom("legacyPrint");
    try global.defineOwnProperty(
        js.runtime,
        name,
        core.Descriptor.data(function_value, .all),
    );

    var output_buffer: [0]u8 = .{};
    var output = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalWithOptions(
        "globalThis.__legacyOutputError = 'not caught'; try { legacyPrint('full'); } catch (error) { globalThis.__legacyOutputError = error.name + ':' + error.message; }",
        .{ .output = &output },
    );
    const caught_name = try js.runtime.internAtom("__legacyOutputError");
    const caught = try global.getProperty(caught_name);
    try helpers.expectStringValueBytes(caught, "Error:WriteFailed");
}

test "native host error sentinel always has a pending named JS exception" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);

    const result = engine.exec.builtin_dispatch.nativeFromBits(
        engine.exec.builtin_dispatch.nativeFromHostError(
            js.context,
            global,
            error.WriteFailed,
        ),
    );
    try std.testing.expect(result.is(.exception));
    try std.testing.expect(js.context.hasException());
    var exception = try js.takeExceptionInfo();
    defer exception.deinit();
    const message = try exception.getMessage(std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("Error: WriteFailed", message);
}

test "generator creation avoids a second payload copy of rooted input slices" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);

    const argument = (try core.Object.create(js.runtime, core.class.ids.object, null)).value();
    _ = try js.eval("globalThis.__argumentGenerator = function* () {};");
    const argument_key = try js.runtime.internAtom("__argumentGenerator");
    const argument_generator = try global.getProperty(argument_key);
    const argument_values = [_]core.JSValue{argument};

    _ = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        argument_generator,
        &argument_values,
        null,
        null,
    );
    _ = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        argument_generator,
        &.{},
        null,
        null,
    );
    // Keep one final-prototype root Shape live. A qjs-style detached generator
    // construction then needs two fixed creates (public Object + compact
    // payload) and one variable allocation containing execution state + stack;
    // it must not allocate a temporary null-prototype Shape or stack buffer.

    var alloc_calls = js.runtime.allocation_diagnostics.alloc_calls;
    var create_calls = js.runtime.allocation_diagnostics.create_calls;
    _ = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        argument_generator,
        &.{},
        null,
        null,
    );
    const no_argument_alloc_count = js.runtime.allocation_diagnostics.alloc_calls - alloc_calls;
    const no_argument_create_count = js.runtime.allocation_diagnostics.create_calls - create_calls;
    try std.testing.expectEqual(@as(usize, 2), no_argument_create_count);
    try std.testing.expectEqual(@as(usize, 1), no_argument_alloc_count);

    alloc_calls = js.runtime.allocation_diagnostics.alloc_calls;
    create_calls = js.runtime.allocation_diagnostics.create_calls;
    _ = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        argument_generator,
        &argument_values,
        null,
        null,
    );
    const argument_alloc_count = js.runtime.allocation_diagnostics.alloc_calls - alloc_calls;
    const argument_create_count = js.runtime.allocation_diagnostics.create_calls - create_calls;
    // Args/locals/var-ref windows enlarge the same variable-sized execution
    // allocation; the construction root borrows the caller slice until those
    // resident windows have been initialized and parked.
    try std.testing.expectEqual(no_argument_alloc_count, argument_alloc_count);
    try std.testing.expectEqual(no_argument_create_count, argument_create_count);

    _ = try js.eval("globalThis.__captureGenerator = (function () { var captured = {}; return function* () { yield captured; }; })();");
    const capture_key = try js.runtime.internAtom("__captureGenerator");
    const capture_generator = try global.getProperty(capture_key);
    _ = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        capture_generator,
        &.{},
        null,
        null,
    );

    alloc_calls = js.runtime.allocation_diagnostics.alloc_calls;
    create_calls = js.runtime.allocation_diagnostics.create_calls;
    _ = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        argument_generator,
        &.{},
        null,
        null,
    );
    const no_capture_alloc_count = js.runtime.allocation_diagnostics.alloc_calls - alloc_calls;
    const no_capture_create_count = js.runtime.allocation_diagnostics.create_calls - create_calls;

    alloc_calls = js.runtime.allocation_diagnostics.alloc_calls;
    create_calls = js.runtime.allocation_diagnostics.create_calls;
    _ = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        capture_generator,
        &.{},
        null,
        null,
    );
    const capture_alloc_count = js.runtime.allocation_diagnostics.alloc_calls - alloc_calls;
    const capture_create_count = js.runtime.allocation_diagnostics.create_calls - create_calls;
    try std.testing.expectEqual(no_capture_alloc_count, capture_alloc_count);
    try std.testing.expectEqual(no_capture_create_count, capture_create_count);
}

test "Engine generator return propagates an explicit finally throw" {
    try helpers.expectPrints(
        \\var syncError = new Error('sync');
        \\function* syncGenerator() {
        \\  try { yield 1; } finally { throw syncError; }
        \\}
        \\var syncIterator = syncGenerator();
        \\syncIterator.next();
        \\try {
        \\  syncIterator.return('sent');
        \\  print('sync-resolved');
        \\} catch (error) {
        \\  print('sync-rejected', error === syncError);
        \\}
        \\var asyncError = new Error('async');
        \\async function* asyncGenerator() {
        \\  try { yield 1; } finally { throw asyncError; }
        \\}
        \\var asyncIterator = asyncGenerator();
        \\asyncIterator.next().then(function() {
        \\  return asyncIterator.return('sent');
        \\}).then(function() {
        \\  print('async-resolved');
        \\}, function(error) {
        \\  print('async-rejected', error === asyncError);
        \\  return asyncIterator.next();
        \\}).then(function(result) {
        \\  print('async-closed', result.value, result.done);
        \\});
    , "sync-rejected true\nasync-rejected true\nasync-closed undefined true\n");
}

test "async generator return awaits for-await iterator close before completing" {
    try helpers.expectPrints(
        \\var closeCalls = 0;
        \\var awaitCalls = 0;
        \\var iterable = {};
        \\iterable[Symbol.asyncIterator] = function() {
        \\  return {
        \\    next: function() { return Promise.resolve({ value: 1, done: false }); },
        \\    return: function() {
        \\      closeCalls++;
        \\      return { then: function(resolve) { awaitCalls++; resolve({ done: true }); } };
        \\    }
        \\  };
        \\};
        \\async function* values() {
        \\  for await (var value of iterable) yield value;
        \\}
        \\var iterator = values();
        \\iterator.next().then(function() {
        \\  return iterator.return(9);
        \\}).then(function(result) {
        \\  print(result.value, result.done, closeCalls, awaitCalls);
        \\}, function(error) {
        \\  print("rejected", error.name, closeCalls, awaitCalls);
        \\});
    , "9 true 1 1\n");
}

test "async generator return closes an inner iterator before its enclosing finally" {
    try helpers.expectPrints(
        \\const events = [];
        \\const iterable = {
        \\  [Symbol.asyncIterator]() {
        \\    return {
        \\      next() { return Promise.resolve({ value: 1, done: false }); },
        \\      return() { events.push("return"); return Promise.resolve({ done: true }); },
        \\    };
        \\  },
        \\};
        \\async function* values() {
        \\  try {
        \\    for await (const value of iterable) yield value;
        \\  } finally {
        \\    events.push("finally");
        \\  }
        \\}
        \\const generator = values();
        \\generator.next().then(function() {
        \\  return generator.return(9);
        \\}).then(function(returned) {
        \\  print(events.join(","), returned.value, returned.done);
        \\});
    , "return,finally 9 true\n");
}

test "async generator return awaits its value once before a yielding finalizer" {
    try helpers.expectPrints(
        \\let awaitCount = 0;
        \\const returned = { then(resolve) { awaitCount++; resolve(7); } };
        \\async function* values() {
        \\  try { yield 1; }
        \\  finally { yield 2; }
        \\}
        \\const iterator = values();
        \\iterator.next().then(function() {
        \\  return iterator.return(returned);
        \\}).then(function(finalizerYield) {
        \\  print(finalizerYield.value, finalizerYield.done, awaitCount);
        \\  return iterator.next();
        \\}).then(function(completion) {
        \\  print(completion.value, completion.done, awaitCount);
        \\});
    , "2 false 1\n7 true 1\n");
}

test "EventLoop drain returns timer exception while Context runJobs leaves host events pending" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    js.context.preserve_uncaught_exception = true;

    _ = try js.eval("var __zjs_timer_throw = function() { throw new Error('timer boom'); };");
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const callback_key = try js.runtime.internAtom("__zjs_timer_throw");
    const callback = try global.getProperty(callback_key);

    try js.event_loop.enqueueTimer(@ptrCast(js.context), 1, callback, 0);

    try js.runJobs();
    try std.testing.expect(!js.context.hasException());
    try std.testing.expectError(error.JSException, js.event_loop.drain());
    try std.testing.expect(js.context.hasException());

    var exception = try js.takeExceptionInfo();
    defer exception.deinit();
}

test "external host arbitrary errors retain their Zig error name" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var probe: u8 = 0;
    try js.defineGlobalExternalHostFunction(
        "hostNamedError",
        0,
        &probe,
        ExternalNamedErrorProbe.call,
        null,
    );

    _ = try js.eval(
        "try { hostNamedError(); } catch (error) { globalThis.__hostNamedError = error.name + ':' + error.message; }",
    );
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const result_name = try js.runtime.internAtom("__hostNamedError");
    const caught = try global.getProperty(result_name);
    try helpers.expectStringValueBytes(caught, "Error:HostProbeFailure");
}

test "dynamic import failures preserve unsupported not-found and host I/O mappings" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);

    const unsupported_specifier = try engine.exec.value_ops.createStringValue(js.runtime, "./unsupported.mjs");
    const unsupported = try engine.exec.module_graph.enqueueDynamicImportJob(
        js.context,
        global,
        null,
        "/fixture/main.mjs",
        unsupported_specifier,
    );
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null)) == .success);
    try expectRejectedPromiseNamedError(&js, unsupported, "TypeError", "dynamic import is not supported");

    const dir = ".zig-cache/q16-host-errors";
    const main_path = dir ++ "/main.mjs";
    const large_path = dir ++ "/large.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = large_path,
        .data = "export const value = 123;",
    });

    var state = engine.exec.module_graph.DynamicImportState{
        .runtime = js.runtime,
        .output = null,
        .env = .{ .io = std.testing.io, .allocator = std.testing.allocator, .max_source_size = 8 },
    };
    defer state.deinit();
    var loader_scope = try engine.exec.module_graph.installDynamicImport(&state);
    defer loader_scope.deinit();

    const missing_specifier = try engine.exec.value_ops.createStringValue(js.runtime, "./missing.mjs");
    const missing = try engine.exec.module_graph.enqueueDynamicImportJob(
        js.context,
        global,
        null,
        main_path,
        missing_specifier,
    );
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null)) == .success);
    const missing_path = try std.fs.path.resolve(std.testing.allocator, &.{ dir, "missing.mjs" });
    defer std.testing.allocator.free(missing_path);
    const missing_message = try std.fmt.allocPrint(
        std.testing.allocator,
        "could not load module filename '{s}'",
        .{missing_path},
    );
    defer std.testing.allocator.free(missing_message);
    try expectRejectedPromiseNamedError(&js, missing, "ReferenceError", missing_message);

    const large_specifier = try engine.exec.value_ops.createStringValue(js.runtime, "./large.mjs");
    const too_large = try engine.exec.module_graph.enqueueDynamicImportJob(
        js.context,
        global,
        null,
        main_path,
        large_specifier,
    );
    try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(js.context, null)) == .success);
    try expectRejectedPromiseNamedError(&js, too_large, "Error", "could not load module '.zig-cache/q16-host-errors/large.mjs': StreamTooLong");
}

test "static module read failures are named JS exceptions" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/q16-static-host-error";
    const main_path = dir ++ "/main.mjs";
    const large_path = dir ++ "/large.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = large_path,
        .data = "export const value = 123;",
    });
    var output_buffer: [1]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expectError(
        error.JSException,
        js.evalModuleGraph(
            "import './large.mjs';",
            &output,
            main_path,
            std.testing.io,
            std.testing.allocator,
            8,
        ),
    );
    try std.testing.expect(js.context.hasException());
    var exception = try js.takeExceptionInfo();
    defer exception.deinit();
    const message = try exception.getMessage(std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("Error: could not load module '.zig-cache/q16-static-host-error/large.mjs': StreamTooLong", message);
}

test "stalled module host progress is a named InternalError" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var output_buffer: [1]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expectError(
        error.JSException,
        js.evalModuleGraph(
            "await new Promise(() => {});",
            &output,
            "q16-stalled-module.mjs",
            std.testing.io,
            std.testing.allocator,
            1024,
        ),
    );
    try std.testing.expect(js.context.hasException());
    var exception = try js.takeExceptionInfo();
    defer exception.deinit();
    const message = try exception.getMessage(std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings(
        "InternalError: unsettled top-level await: no pending job or host task can settle it",
        message,
    );
}

test "missing synthetic modules report the request-order dependency first" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // main imports a.mjs, mid.json, b.mjs. a.mjs imports first.json and
    // b.mjs imports second.json. Request-order postorder reads first.json
    // before second.json and before the parent's mid.json.
    const dir = ".zig-cache/m2-synthetic-order";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dir ++ "/a.mjs",
        .data = "import './first.json' with { type: 'json' };\nexport {};\n",
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dir ++ "/b.mjs",
        .data = "import './second.json' with { type: 'json' };\nexport {};\n",
    });

    var output_buffer: [1]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expectError(
        error.JSException,
        js.evalModuleGraph(
            \\import './a.mjs';
            \\import './mid.json' with { type: 'json' };
            \\import './b.mjs';
        ,
            &output,
            dir ++ "/main.mjs",
            std.testing.io,
            std.testing.allocator,
            4096,
        ),
    );
    try std.testing.expect(js.context.hasException());
    var exception = try js.takeExceptionInfo();
    defer exception.deinit();
    const message = try exception.getMessage(std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings(
        "ReferenceError: could not load module filename '.zig-cache/m2-synthetic-order/first.json'",
        message,
    );
}

test "host module graph syntax diagnostics do not write to program output" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const modules = [_]helpers.MemoryModule{
        .{
            .specifier = "./bad.js",
            .path = "/fixture/bad.js",
            .source = "export const = ;",
        },
    };
    var host = helpers.MemoryModules{ .modules = &modules };

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expectError(
        error.SyntaxError,
        js.evalModuleGraphInMemory(
            "import './bad.js';",
            &stream,
            "/fixture/main.mjs",
            &host,
            std.testing.allocator,
        ),
    );
    try std.testing.expectEqualStrings("", stream.buffered());
}

test "module graph evaluates block var declarations as module bindings" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalModuleGraph(
        \\if (true) {
        \\  var proto = {};
        \\  print(typeof proto);
        \\  print(proto !== null);
        \\}
    ,
        &output,
        "block-var-module.mjs",
        std.testing.io,
        std.testing.allocator,
        2048,
    );

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("object\ntrue\n", output.buffered());
}

test "module evaluation does not skip a body-leading function expression" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalModuleGraph(
        \\print((function () { return 42; })());
    ,
        &output,
        "module-leading-function-expression.mjs",
        std.testing.io,
        std.testing.allocator,
        2048,
    );

    try std.testing.expectEqualStrings("42\n", output.buffered());
}

test "module evaluation does not mistake a body-leading this branch for a hoist prologue" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalModuleGraph(
        \\if (this) print('bad');
        \\print('ok');
    ,
        &output,
        "module-leading-this-branch.mjs",
        std.testing.io,
        std.testing.allocator,
        2048,
    );

    try std.testing.expectEqualStrings("ok\n", output.buffered());
}

test "module cycles initialize wide function declaration closures before evaluation" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var module_a: std.ArrayList(u8) = .empty;
    defer module_a.deinit(std.testing.allocator);
    try module_a.appendSlice(std.testing.allocator, "import { pre } from './b.mjs';\n");
    for (0..257) |index| {
        var line_buffer: [80]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &line_buffer,
            "export function f{d}() {{ return {d}; }}\n",
            .{ index, index },
        );
        try module_a.appendSlice(std.testing.allocator, line);
    }
    try module_a.appendSlice(std.testing.allocator, "export const observed = pre;\n");

    const modules = [_]helpers.MemoryModule{
        .{
            .specifier = "./a.mjs",
            .path = "/fixture/a.mjs",
            .source = module_a.items,
        },
        .{
            .specifier = "./b.mjs",
            .path = "/fixture/b.mjs",
            .source =
            \\import { f255, f256 } from './a.mjs';
            \\export const pre = (() => {
            \\  try { return typeof f255 + ',' + typeof f256; }
            \\  catch (error) { return typeof f255 + ',' + error.name; }
            \\})();
            ,
        },
    };
    var host = helpers.MemoryModules{ .modules = &modules };

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalModuleGraphInMemory(
        \\import { observed } from './a.mjs';
        \\print(observed);
    ,
        &output,
        "/fixture/main.mjs",
        &host,
        std.testing.allocator,
    );

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("function,function\n", output.buffered());
}

test "module cycles do not hoist a body-leading named function expression" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const modules = [_]helpers.MemoryModule{
        .{
            .specifier = "./a.mjs",
            .path = "/fixture/a.mjs",
            .source =
            \\import { observed } from './b.mjs';
            \\export const value = function inner() { return 1; };
            \\export const result = observed;
            ,
        },
        .{
            .specifier = "./b.mjs",
            .path = "/fixture/b.mjs",
            .source =
            \\import { value } from './a.mjs';
            \\let observed;
            \\try { observed = typeof value; }
            \\catch (error) { observed = error.name; }
            \\export { observed };
            ,
        },
    };
    var host = helpers.MemoryModules{ .modules = &modules };

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalModuleGraphInMemory(
        \\import { result } from './a.mjs';
        \\print(result);
    ,
        &output,
        "/fixture/main.mjs",
        &host,
        std.testing.allocator,
    );

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("ReferenceError\n", output.buffered());
}

test "W1e: module namespace exposes sorted immutable live export properties" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const modules = [_]helpers.MemoryModule{
        .{
            .specifier = "./namespace-source.mjs",
            .path = "/fixture/namespace-source.mjs",
            .source =
            \\export function update(next) { omega = next; }
            \\export let omega = 2;
            \\export const alpha = 1;
            ,
        },
    };
    var host = helpers.MemoryModules{ .modules = &modules };

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalModuleGraphInMemory(
        \\import * as namespace from './namespace-source.mjs';
        \\
        \\assert.sameValue(Object.getPrototypeOf(namespace), null);
        \\assert.sameValue(namespace.omega, 2);
        \\namespace.update(7);
        \\assert.sameValue(namespace.omega, 7);
        \\
        \\const descriptor = Object.getOwnPropertyDescriptor(namespace, "omega");
        \\assert.sameValue(descriptor.value, 7);
        \\assert.sameValue(descriptor.writable, true);
        \\assert.sameValue(descriptor.enumerable, true);
        \\assert.sameValue(descriptor.configurable, false);
        \\
        \\let assignmentRejected = false;
        \\try { namespace.omega = 9; }
        \\catch (error) { assignmentRejected = error instanceof TypeError; }
        \\assert.sameValue(assignmentRejected, true);
        \\assert.sameValue(Reflect.set(namespace, "omega", 9), false);
        \\
        \\let defineRejected = false;
        \\try { Object.defineProperty(namespace, "omega", { value: 9 }); }
        \\catch (error) { defineRejected = error instanceof TypeError; }
        \\assert.sameValue(defineRejected, true);
        \\
        \\let deleteRejected = false;
        \\try { delete namespace.omega; }
        \\catch (error) { deleteRejected = error instanceof TypeError; }
        \\assert.sameValue(deleteRejected, true);
        \\assert.sameValue(namespace.omega, 7);
        \\
        \\const keys = Reflect.ownKeys(namespace);
        \\assert.sameValue(keys.length, 4);
        \\assert.sameValue(keys[0], "alpha");
        \\assert.sameValue(keys[1], "omega");
        \\assert.sameValue(keys[2], "update");
        \\assert.sameValue(keys[3], Symbol.toStringTag);
    ,
        &output,
        "/fixture/main.mjs",
        &host,
        std.testing.allocator,
    );

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("", output.buffered());
}

test "module namespace has and super set preserve uninitialized export semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const modules = [_]helpers.MemoryModule{
        .{
            .specifier = "./self.mjs",
            .path = "/fixture/main.mjs",
            .source = "",
        },
    };
    var host = helpers.MemoryModules{ .modules = &modules };

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalModuleGraphInMemory(
        \\import * as namespace from './self.mjs';
        \\
        \\assert.sameValue('value' in namespace, true);
        \\assert.sameValue(Reflect.has(namespace, 'value'), true);
        \\
        \\class Base { constructor() { return namespace; } }
        \\class Derived extends Base {
        \\  constructor() {
        \\    super();
        \\    super.value = 14;
        \\  }
        \\}
        \\assert.throws(ReferenceError, function() { new Derived(); });
        \\
        \\class NonWritableBase { constructor() { return namespace; } }
        \\Object.defineProperty(NonWritableBase.prototype, 'value', {
        \\  value: 0,
        \\  writable: false,
        \\});
        \\class NonWritableDerived extends NonWritableBase {
        \\  constructor() {
        \\    super();
        \\    super.value = 14;
        \\  }
        \\}
        \\assert.throws(TypeError, function() { new NonWritableDerived(); });
        \\
        \\export let value = 42;
    ,
        &output,
        "/fixture/main.mjs",
        &host,
        std.testing.allocator,
    );

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("", output.buffered());
}

test "W1e: named aliases and namespace reexports share live canonical bindings" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const modules = [_]helpers.MemoryModule{
        .{
            .specifier = "./binding-source.mjs",
            .path = "/fixture/binding-source.mjs",
            .source =
            \\export let value = 3;
            \\export const token = {};
            \\export function setValue(next) { value = next; }
            ,
        },
        .{
            .specifier = "./binding-bridge.mjs",
            .path = "/fixture/binding-bridge.mjs",
            .source =
            \\export * as namespace from './binding-source.mjs';
            \\export { value as alias, token, setValue } from './binding-source.mjs';
            ,
        },
    };
    var host = helpers.MemoryModules{ .modules = &modules };

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalModuleGraphInMemory(
        \\import { alias, token, setValue, namespace as reexportedNamespace } from './binding-bridge.mjs';
        \\import { value as directAlias, token as directToken } from './binding-source.mjs';
        \\import * as directNamespace from './binding-source.mjs';
        \\
        \\assert.sameValue(alias, 3);
        \\assert.sameValue(alias, directAlias);
        \\assert.sameValue(token, directToken);
        \\assert.sameValue(token, directNamespace.token);
        \\assert.sameValue(reexportedNamespace, directNamespace);
        \\
        \\setValue(41);
        \\assert.sameValue(alias, 41);
        \\assert.sameValue(directAlias, 41);
        \\assert.sameValue(directNamespace.value, 41);
        \\assert.sameValue(reexportedNamespace.value, 41);
        \\assert.sameValue(reexportedNamespace.token, token);
    ,
        &output,
        "/fixture/main.mjs",
        &host,
        std.testing.allocator,
    );

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("", output.buffered());
}

test "W1e: missing indirect export precedes bad import wiring" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const modules = [_]helpers.MemoryModule{
        .{
            .specifier = "./empty.mjs",
            .path = "/fixture/empty.mjs",
            .source = "export const present = 1;",
        },
        .{
            .specifier = "./link-failures.mjs",
            .path = "/fixture/link-failures.mjs",
            .source =
            \\export { missingIndirect as indirectFirst } from './empty.mjs';
            \\import { badImport } from './empty.mjs';
            \\export const marker = typeof badImport;
            ,
        },
    };
    var host = helpers.MemoryModules{ .modules = &modules };

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    // QuickJS js_inner_module_linking validates every indirect export before
    // wiring import_entries. Its error call uses the re-exporting module and
    // public export name, so this must not report badImport or empty.mjs.
    try std.testing.expectError(
        error.SyntaxError,
        js.evalModuleGraphInMemory(
            "import './link-failures.mjs';",
            &output,
            "/fixture/main.mjs",
            &host,
            std.testing.allocator,
        ),
    );
    try std.testing.expect(js.context.hasException());

    var exception = try js.takeExceptionInfo();
    defer exception.deinit();
    const message = try exception.getMessage(std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings(
        "SyntaxError: Could not find export 'indirectFirst' in module '/fixture/link-failures.mjs'",
        message,
    );
    try std.testing.expectEqualStrings("", output.buffered());
}

test "W1e: one host source load spans declaration body TLA resume and dynamic import" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const modules = [_]helpers.MemoryModule{
        .{
            .specifier = "./single-load.mjs",
            .path = "/fixture/single-load.mjs",
            .source =
            \\globalThis.__w1eSingleLoadRuns = (globalThis.__w1eSingleLoadRuns || 0) + 1;
            \\globalThis.__w1eSingleLoadPhases = ["body"];
            \\export function read() { return value; }
            \\export let value = 1;
            \\await 0;
            \\value = 2;
            \\globalThis.__w1eSingleLoadPhases.push("resume");
            ,
        },
    };
    var host = helpers.MemoryModules{ .modules = &modules };

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalModuleGraphInMemory(
        \\import * as staticNamespace from './single-load.mjs';
        \\
        \\assert.sameValue(staticNamespace.value, 2);
        \\assert.sameValue(staticNamespace.read(), 2);
        \\assert.sameValue(globalThis.__w1eSingleLoadRuns, 1);
        \\assert.sameValue(globalThis.__w1eSingleLoadPhases.join(","), "body,resume");
        \\
        \\const dynamicNamespace = await import('./single-load.mjs');
        \\assert.sameValue(dynamicNamespace, staticNamespace);
        \\assert.sameValue(dynamicNamespace.value, 2);
        \\assert.sameValue(dynamicNamespace.read(), 2);
        \\assert.sameValue(globalThis.__w1eSingleLoadRuns, 1);
        \\assert.sameValue(globalThis.__w1eSingleLoadPhases.join(","), "body,resume");
    ,
        &output,
        "/fixture/main.mjs",
        &host,
        std.testing.allocator,
    );

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expect(host.resolve_calls > 0);
    // Resolution may be repeated for normalization, but handing source to the
    // compiler is a one-shot host operation for one canonical module record.
    try std.testing.expectEqual(@as(usize, 1), host.read_calls);
    try std.testing.expectEqualStrings("", output.buffered());
}

fn retainedModuleExportCell(
    record: *const core.module.ModuleRecord,
    export_name: core.Atom,
) ?*core.VarRef {
    for (record.exports, 0..) |entry, index| {
        if (entry.export_name != export_name) continue;
        const value = record.retainedExportCellValue(@intCast(index)) orelse return null;
        return core.VarRef.fromValue(value);
    }
    return null;
}

test "same module specifier keeps record cells namespace import meta and error state per Realm" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const realm_b = try core.JSContext.create(js.runtime, .{});
    defer realm_b.destroy();
    var facade_a = zjs.borrowContext(js.context);
    var facade_b = zjs.borrowContext(realm_b);
    const filename = "w1e-shared-module-identity.mjs";

    try std.testing.expectError(
        error.JSException,
        facade_a.eval(
            \\globalThis.__w1eRuns = (globalThis.__w1eRuns || 0) + 1;
            \\export let value = 11;
            \\export function realmFunction() { return value; }
            \\export const meta = import.meta;
            \\throw new Error("realm A only");
        , .{ .mode = .module, .filename = filename }),
    );
    if (js.context.hasException()) {
        _ = js.context.takeException();
    }

    _ = try facade_b.eval(
        \\globalThis.__w1eRuns = (globalThis.__w1eRuns || 0) + 1;
        \\export let value = 22;
        \\export function realmFunction() { return value; }
        \\export const meta = import.meta;
    , .{ .mode = .module, .filename = filename });

    const module_name = try js.runtime.internAtom(filename);
    const record_a = js.context.modules.find(module_name) orelse return error.TestUnexpectedResult;
    const record_b = realm_b.modules.find(module_name) orelse return error.TestUnexpectedResult;
    try std.testing.expect(record_a != record_b);
    try std.testing.expectEqual(core.module.Status.errored, record_a.status);
    try std.testing.expectEqual(core.module.Status.evaluated, record_b.status);
    try std.testing.expect(record_a.eval_exception != null);
    try std.testing.expect(record_b.eval_exception == null);

    const meta_a = record_a.import_meta orelse return error.TestUnexpectedResult;
    const meta_b = record_b.import_meta orelse return error.TestUnexpectedResult;
    try std.testing.expect(!meta_a.same(meta_b));

    const value_name = try js.runtime.internAtom("value");
    const value_a_cell = retainedModuleExportCell(record_a, value_name) orelse return error.TestUnexpectedResult;
    const value_b_cell = retainedModuleExportCell(record_b, value_name) orelse return error.TestUnexpectedResult;
    try std.testing.expect(value_a_cell != value_b_cell);

    const function_name = try js.runtime.internAtom("realmFunction");
    const function_a_cell = retainedModuleExportCell(record_a, function_name) orelse return error.TestUnexpectedResult;
    const function_b_cell = retainedModuleExportCell(record_b, function_name) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!function_a_cell.varRefValue().same(function_b_cell.varRefValue()));

    const namespace_a = try engine.exec.module.moduleNamespaceValue(js.context, module_name);
    const namespace_b = try engine.exec.module.moduleNamespaceValue(realm_b, module_name);
    try std.testing.expect(!namespace_a.same(namespace_b));

    const runs_name = try js.runtime.internAtom("__w1eRuns");
    const global_a = try engine.exec.zjs_vm.contextGlobal(js.context);
    const global_b = try engine.exec.zjs_vm.contextGlobal(realm_b);
    const runs_a = try global_a.getProperty(runs_name);
    const runs_b = try global_b.getProperty(runs_name);
    try std.testing.expectEqual(@as(?i32, 1), runs_a.as(.int));
    try std.testing.expectEqual(@as(?i32, 1), runs_b.as(.int));
}

test "context module eval does not rerun evaluated or errored records" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const evaluated_filename = "context-eval-evaluated-once.mjs";
    const first = try js.evalWithOptions(
        \\globalThis.__contextEvaluatedRuns =
        \\  (globalThis.__contextEvaluatedRuns || 0) + 1;
        \\export const value = 1;
    , .{ .mode = .module, .filename = evaluated_filename });
    try std.testing.expect(first.is(.undefined_value));

    const second = try js.evalWithOptions(
        \\globalThis.__contextEvaluatedRuns += 100;
        \\export const value = 2;
    , .{ .mode = .module, .filename = evaluated_filename });
    try std.testing.expect(second.is(.undefined_value));

    const evaluated_name = try js.runtime.internAtom("__contextEvaluatedRuns");
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const evaluated_runs = try global.getProperty(evaluated_name);
    try std.testing.expectEqual(@as(?i32, 1), evaluated_runs.as(.int));

    const errored_filename = "context-eval-errored-once.mjs";
    try std.testing.expectError(
        error.JSException,
        js.evalWithOptions(
            \\globalThis.__contextErroredRuns =
            \\  (globalThis.__contextErroredRuns || 0) + 1;
            \\throw new Error("cached context module failure");
        , .{ .mode = .module, .filename = errored_filename }),
    );
    const errored_name = try js.runtime.internAtom(errored_filename);
    const errored_record = js.context.modules.find(errored_name) orelse
        return error.TestUnexpectedResult;
    const cached_exception = errored_record.eval_exception orelse
        return error.TestUnexpectedResult;
    const first_exception = js.context.takeException();
    try std.testing.expect(first_exception.same(cached_exception));

    try std.testing.expectError(
        error.JSException,
        js.evalWithOptions(
            \\globalThis.__contextErroredRuns += 100;
            \\export const value = 2;
        , .{ .mode = .module, .filename = errored_filename }),
    );
    const second_exception = js.context.takeException();
    try std.testing.expect(second_exception.same(cached_exception));

    const errored_runs_name = try js.runtime.internAtom("__contextErroredRuns");
    const errored_runs = try global.getProperty(errored_runs_name);
    try std.testing.expectEqual(@as(?i32, 1), errored_runs.as(.int));
}

test "context module eval resumes TLA from its reaction FIFO position" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.evalWithOptions(
        \\const actual = [];
        \\let resolveAwaited;
        \\const awaited = new Promise(resolve => resolveAwaited = resolve);
        \\awaited.then(() => actual.push("before"));
        \\Promise.resolve().then(() => {
        \\  awaited.then(() => actual.push("after"));
        \\  resolveAwaited(42);
        \\});
        \\const value = await awaited;
        \\actual.push("module:" + value);
        \\let rejection = "not caught";
        \\try {
        \\  await Promise.reject(new Error("tla rejection"));
        \\} catch (error) {
        \\  rejection = error.message;
        \\}
        \\Promise.resolve().then(() => {
        \\  globalThis.__contextTlaResult =
        \\    actual.join(",") + "|" + rejection;
        \\});
    , .{ .mode = .module, .filename = "context-eval-tla-fifo.mjs" });

    _ = try js.eval(
        \\assert.sameValue(
        \\  globalThis.__contextTlaResult,
        \\  "before,module:42,after|tla rejection"
        \\);
    );
}

test "Runtime loader keeps same-path TLA continuations and waiters in parent and child Realms" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var parent_facade = zjs.borrowContext(js.context);
    _ = try zjs.globalObjectPtr(&parent_facade);

    const dir = ".zig-cache/w1e-cross-realm-tla";
    const main_path = dir ++ "/main.js";
    const module_path = dir ++ "/shared.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = module_path,
        .data =
        \\globalThis.__w1eTlaRuns = (globalThis.__w1eTlaRuns || 0) + 1;
        \\await 0;
        \\globalThis.__w1eTlaRuns += 10;
        \\export const value = globalThis.__w1eTlaRuns;
        ,
    });

    var state = engine.exec.module_graph.DynamicImportState{
        .runtime = js.runtime,
        .output = null,
        .env = .{ .io = std.testing.io, .allocator = std.testing.allocator, .max_source_size = 4096 },
    };
    defer state.deinit();
    var loader_scope = try engine.exec.module_graph.installDynamicImport(&state);
    defer loader_scope.deinit();

    const child_holder = try engine.exec.call.createRealmObject(js.context);
    const child_record = try property_ops.expectObject(child_holder);
    const child = child_record.realmContext() orelse return error.TestUnexpectedResult;
    @import("zjs_host").file_modules.install(child);
    const parent_global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const child_global = try engine.exec.zjs_vm.contextGlobal(child);

    const specifier = try engine.exec.value_ops.createStringValue(js.runtime, "./shared.mjs");
    const parent_first = try engine.exec.module_graph.enqueueDynamicImportJob(js.context, parent_global, null, main_path, specifier);
    const child_first = try engine.exec.module_graph.enqueueDynamicImportJob(child, child_global, null, main_path, specifier);
    const parent_second = try engine.exec.module_graph.enqueueDynamicImportJob(js.context, parent_global, null, main_path, specifier);
    const child_second = try engine.exec.module_graph.enqueueDynamicImportJob(child, child_global, null, main_path, specifier);

    // The first import in each Realm creates one TLA continuation and waiter;
    // the second sees that Realm's evaluating record and adds only a waiter.
    // All four dynamic-import jobs precede the Promise reactions they enqueue.
    for (0..4) |_| {
        try std.testing.expect((try engine.exec.promise_ops.drainOnePendingJob(child, null)) == .success);
    }
    try std.testing.expectEqual(@as(usize, 2), state.continuations.items.len);
    try std.testing.expectEqual(@as(usize, 4), state.waiters.items.len);
    try std.testing.expect(state.continuations.items[0].realm.borrow() == js.context);
    try std.testing.expect(state.continuations.items[1].realm.borrow() == child);
    try std.testing.expect(state.waiters.items[0].realm.borrow() == js.context);
    try std.testing.expect(state.waiters.items[1].realm.borrow() == child);
    try std.testing.expect(state.waiters.items[2].realm.borrow() == js.context);
    try std.testing.expect(state.waiters.items[3].realm.borrow() == child);

    // The facade selects only the Runtime. Each continuation resumes and each
    // same-path waiter settles through its own retained Realm.
    try state.runJobs(child);
    try std.testing.expectEqual(@as(usize, 0), state.continuations.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.waiters.items.len);

    const PromiseResult = struct {
        fn get(value: core.JSValue) !core.JSValue {
            const promise = try property_ops.expectObject(value);
            if (promise.promiseIsRejected()) return error.TestUnexpectedResult;
            return promise.promiseResult() orelse error.TestUnexpectedResult;
        }
    };
    const parent_namespace_first = try PromiseResult.get(parent_first);
    const parent_namespace_second = try PromiseResult.get(parent_second);
    const child_namespace_first = try PromiseResult.get(child_first);
    const child_namespace_second = try PromiseResult.get(child_second);
    try std.testing.expect(parent_namespace_first.same(parent_namespace_second));
    try std.testing.expect(child_namespace_first.same(child_namespace_second));
    try std.testing.expect(!parent_namespace_first.same(child_namespace_first));

    const runs_name = try js.runtime.internAtom("__w1eTlaRuns");
    const parent_runs = try parent_global.getProperty(runs_name);
    const child_runs = try child_global.getProperty(runs_name);
    try std.testing.expectEqual(@as(?i32, 11), parent_runs.as(.int));
    try std.testing.expectEqual(@as(?i32, 11), child_runs.as(.int));

    const resolved_path = try std.fs.path.resolve(std.testing.allocator, &.{module_path});
    defer std.testing.allocator.free(resolved_path);
    const module_name = try js.runtime.internAtom(resolved_path);
    const parent_module = js.context.modules.find(module_name) orelse return error.TestUnexpectedResult;
    const child_module = child.modules.find(module_name) orelse return error.TestUnexpectedResult;
    try std.testing.expect(parent_module != child_module);
    try std.testing.expectEqual(core.module.Status.evaluated, parent_module.status);
    try std.testing.expectEqual(core.module.Status.evaluated, child_module.status);
}

test "module top-level await resumes in Promise reaction FIFO order" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalModuleGraph(
        \\var actual = [];
        \\Promise.resolve(0)
        \\  .then(() => actual.push("tick 1"))
        \\  .then(() => actual.push("tick 2"))
        \\  .then(() => actual.push("tick 3"))
        \\  .then(() => actual.push("tick 4"))
        \\  .then(() => print("done:" + actual.join(",")));
        \\await 1;
        \\actual.push("await 1");
        \\await 2;
        \\actual.push("await 2");
        \\await 3;
        \\actual.push("await 3");
        \\await 4;
        \\actual.push("await 4");
    ,
        &output,
        "module-tla-promise-fifo.mjs",
        std.testing.io,
        std.testing.allocator,
        4096,
    );

    try std.testing.expectEqualStrings(
        "done:tick 1,await 1,tick 2,await 2,tick 3,await 3,tick 4,await 4\n",
        output.buffered(),
    );
}

test "module await reaction keeps its position on the awaited Promise" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalModuleGraph(
        \\let resolveAwaited;
        \\const awaited = new Promise((resolve) => resolveAwaited = resolve);
        \\const actual = [];
        \\awaited.then(() => actual.push("before"));
        \\Promise.resolve().then(() => {
        \\  awaited.then(() => actual.push("after"));
        \\  resolveAwaited();
        \\});
        \\await awaited;
        \\actual.push("module");
        \\Promise.resolve().then(() => print(actual.join(",")));
    ,
        &output,
        "module-await-reaction-position.mjs",
        std.testing.io,
        std.testing.allocator,
        4096,
    );

    try std.testing.expectEqualStrings("before,module,after\n", output.buffered());
}

test "module TLA resumption allocates nothing from the loader allocator" {
    const ArmableOneShotAllocator = struct {
        backing: std.mem.Allocator,
        armed: bool = false,
        induced: bool = false,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
            };
        }

        fn arm(self: *@This()) void {
            self.armed = true;
            self.induced = false;
        }

        fn disarm(self: *@This()) void {
            self.armed = false;
        }

        fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.armed and !self.induced) {
                self.induced = true;
                return null;
            }
            return self.backing.rawAlloc(len, alignment, ret_addr);
        }

        fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.backing.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.backing.rawFree(memory, alignment, ret_addr);
        }
    };

    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // Per-process scratch dir: the Debug and gc-stress shards of the merge
    // gate run this test concurrently and must not share one directory.
    const dir = helpers.scratchDirForProcess(".zig-cache/module-tla-continuation-oom-retry-test");
    var scratch_buf1: [192]u8 = undefined;
    var scratch_buf2: [192]u8 = undefined;
    var scratch_buf3: [192]u8 = undefined;
    const main_path = try std.fmt.bufPrint(&scratch_buf1, "{s}/main.js", .{dir});
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = try std.fmt.bufPrint(&scratch_buf2, "{s}/a.mjs", .{dir}),
        .data =
        \\globalThis.__aRetry = (globalThis.__aRetry || 0) + 1;
        \\await 1;
        \\globalThis.__aRetry += 10;
        \\await 2;
        \\globalThis.__aRetry += 100;
        \\export const value = "a";
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = try std.fmt.bufPrint(&scratch_buf3, "{s}/b.mjs", .{dir}),
        .data =
        \\globalThis.__bRetry = (globalThis.__bRetry || 0) + 1;
        \\await 1;
        \\globalThis.__bRetry += 10;
        \\await 2;
        \\globalThis.__bRetry += 100;
        \\export const value = "b";
        ,
    });

    var injector = ArmableOneShotAllocator{ .backing = std.testing.allocator };
    var state = engine.exec.module_graph.DynamicImportState{
        .runtime = js.runtime,
        .output = null,
        .env = .{ .io = std.testing.io, .allocator = injector.allocator(), .max_source_size = 4096 },
    };
    defer state.deinit();
    var dynamic_import_scope = try engine.exec.module_graph.installDynamicImport(&state);
    defer dynamic_import_scope.deinit();

    _ = try js.evalWithOptions(
        \\globalThis.__paRetry = import("./a.mjs");
        \\globalThis.__pbRetry = import("./b.mjs");
    , .{ .filename = main_path });
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    // Script eval drains the two dynamic-import jobs, but TLA resumptions stay
    // in the loader state's owned continuation FIFO until state.runJobs().
    try std.testing.expectEqual(@as(usize, 2), state.continuations.items.len);
    for (state.continuations.items, [_][]const u8{ "/a.mjs", "/b.mjs" }) |entry, suffix| {
        try std.testing.expect(std.mem.endsWith(u8, js.runtime.atoms.name(entry.record.module_name).?, suffix));
    }
    const a_counter_atom = try js.runtime.internAtom("__aRetry");
    const b_counter_atom = try js.runtime.internAtom("__bRetry");

    // A resumed body takes the list slot it left, and a settled module
    // without async parents needs no work list: a loader allocation failure
    // can never strand an exposed import Promise mid-resumption.
    injector.arm();
    try state.runJobs(js.context);
    try std.testing.expect(!injector.induced);
    injector.disarm();
    try std.testing.expectEqual(@as(usize, 0), state.continuations.items.len);

    const a_counter = try global.getProperty(a_counter_atom);
    try std.testing.expectEqual(@as(?i32, 111), a_counter.as(.int));
    const b_counter = try global.getProperty(b_counter_atom);
    try std.testing.expectEqual(@as(?i32, 111), b_counter.as(.int));

    inline for (.{ "__paRetry", "__pbRetry" }) |name| {
        const promise_atom = try js.runtime.internAtom(name);
        const promise_value = try global.getProperty(promise_atom);
        const promise = try property_ops.expectObject(promise_value);
        try std.testing.expect(promise.promiseResult() != null);
        try std.testing.expect(!promise.promiseIsRejected());
    }
}

test "async module dependency does not preempt an independent sibling" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // Per-process scratch dir: the Debug and gc-stress shards of the merge
    // gate run this test concurrently and must not share one directory.
    const dir = helpers.scratchDirForProcess(".zig-cache/module-async-sibling-order-test");
    var scratch_buf1: [192]u8 = undefined;
    var scratch_buf2: [192]u8 = undefined;
    var scratch_buf3: [192]u8 = undefined;
    var scratch_buf4: [192]u8 = undefined;
    const main_path = try std.fmt.bufPrint(&scratch_buf1, "{s}/main.mjs", .{dir});
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = try std.fmt.bufPrint(&scratch_buf2, "{s}/b.mjs", .{dir}),
        .data = "globalThis.__moduleOrder = globalThis.__moduleOrder || [];\n" ++
            "globalThis.__moduleOrder.push('b-start');\n" ++
            "await 0;\n" ++
            "globalThis.__moduleOrder.push('b-end');\n",
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = try std.fmt.bufPrint(&scratch_buf3, "{s}/a.mjs", .{dir}),
        .data = "import './b.mjs';\nglobalThis.__moduleOrder.push('a');\n",
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = try std.fmt.bufPrint(&scratch_buf4, "{s}/c.mjs", .{dir}),
        .data = "globalThis.__moduleOrder = globalThis.__moduleOrder || [];\n" ++
            "globalThis.__moduleOrder.push('c');\n",
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = main_path,
        .data = "import './a.mjs';\n" ++
            "import './c.mjs';\n" ++
            "print(globalThis.__moduleOrder.join(','));\n",
    });

    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(source);
    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalModuleGraph(
        source,
        &output,
        main_path,
        std.testing.io,
        std.testing.allocator,
        4096,
    );

    try std.testing.expectEqualStrings("b-start,c,b-end,a\n", output.buffered());
}

test "import bytes module creates a Uint8Array over a plain ArrayBuffer" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // Per-process scratch dir: the Debug and gc-stress shards of the merge
    // gate run this test concurrently and must not share one directory.
    const dir = helpers.scratchDirForProcess(".zig-cache/module-import-bytes-test");
    var scratch_buf1: [192]u8 = undefined;
    var scratch_buf2: [192]u8 = undefined;
    const bytes_path = try std.fmt.bufPrint(&scratch_buf1, "{s}/payload.bin", .{dir});
    const main_path = try std.fmt.bufPrint(&scratch_buf2, "{s}/main.mjs", .{dir});
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = bytes_path, .data = "ABC" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = main_path, .data =
        \\import value from "./payload.bin" with { type: "bytes" };
        \\print(value instanceof Uint8Array);
        \\print(value.buffer instanceof ArrayBuffer);
        \\print(value.length);
        \\print(value[0]);
        \\print("immutable" in value.buffer, value.buffer.resizable);
        \\value[0] = 97;
        \\print(value[0]);
    });

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(2048));
    defer std.testing.allocator.free(source);
    _ = try js.evalModuleGraph(source, &output, main_path, std.testing.io, std.testing.allocator, 2048);

    try std.testing.expectEqualStrings("true\ntrue\n3\n65\nfalse false\n97\n", output.buffered());
}
