//! Function builtin records, dynamic-function construction, and source metadata.
//!
//! Call receivers and arguments are borrowed; created functions, compiled roots,
//! and returned completion values carry owned references and are explicitly
//! rooted across observable prototype work. Generic call/apply execution remains
//! in `call_runtime.zig`; this module owns the Function-domain record seam and
//! dynamic source compilation. The builtin table maps to QuickJS
//! `js_function_proto_funcs` at quickjs.c:41390.

const std = @import("std");
const zjs_vm = @import("zjs_vm.zig");
const runWithCallEnv = zjs_vm.runWithCallEnv;
const stack_mod = @import("stack.zig");
const object_ops = @import("object_ops.zig");
const parser = @import("../parser.zig");
const string_ops = @import("string_ops.zig");
const frame_mod = @import("frame.zig");
const error_stack_ops = @import("error_stack_ops.zig");
const bytecode = @import("../bytecode.zig");

const core = @import("../core/root.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const native_legacy = @import("native_legacy.zig");
const call = @import("call.zig");
const call_runtime = @import("call_runtime.zig");
const exceptions = @import("exceptions.zig");

const HostError = exceptions.HostError;

pub const PrototypeMethod = enum(u32) {
    to_string = 1,
    bind = 2,
    call = 3,
    apply = 4,
    has_instance = 5,
};

/// Identity of the realm-installed default `Function.prototype[@@hasInstance]`
/// record (qjs:41395 `JS_CFUNC_DEF("[Symbol.hasInstance]", 1, js_function_hasInstance)`).
/// Pointer compare against the densified table slot — not a name or shape cache.
pub fn isDefaultHasInstanceRecord(rt: *core.JSRuntime, record: *const core.NativeEntry) bool {
    const expected = rt.internalBuiltinRecord(
        @intCast(@intFromEnum(core.function.NativeBuiltinDomain.function)),
        @intFromEnum(PrototypeMethod.has_instance),
    );
    return if (expected) |slot| record == slot else false;
}

/// qjs compares the C function pointer (`js_function_hasInstance`, 41379).
/// Same identity as `isDefaultHasInstanceRecord` without the runtime table.
pub inline fn recordIsDefaultHasInstance(record: *const core.NativeEntry) bool {
    return record.target == default_has_instance_target;
}

/// NB2: the comptime adapter is memoized per declaration, so the table's
/// `[Symbol.hasInstance]` entry and this constant share one thunk pointer.
const default_has_instance_target = native_legacy.entryFromInternal(functionHasInstanceEntry()).target;

/// Declaration + dispatch table for the `.function` native-builtin domain
/// (QuickJS `js_function_proto_funcs` analogue, quickjs.c:41390).
pub const internal_entries = [_]core.host_function.InternalEntry{
    functionCallEntry(),
    functionApplyEntry(),
    functionEntry("toString", 0, @intFromEnum(PrototypeMethod.to_string)),
    functionEntry("bind", 1, @intFromEnum(PrototypeMethod.bind)),
    // qjs:41395 `JS_CFUNC_DEF("[Symbol.hasInstance]", 1, js_function_hasInstance)`.
    // Every `instanceof` whose RHS does not override `Symbol.hasInstance` lands
    // here, so it must resolve by record id rather than by name cascade.
    //
    // `JS_CFUNC_DEF` is `JS_CFUNC_generic`, not `JS_CFUNC_MAGIC_DEF`: qjs gives
    // this method its own C function rather than a magic selector into a shared
    // body. Mirror that -- a dedicated `.generic` entry keeps the 24M-call
    // `instanceof` path out of `functionCall`'s magic switch, which the hot
    // `apply`/`bind`/`toString` trio shares.
    functionHasInstanceEntry(),
};

fn functionHasInstanceEntry() core.host_function.InternalEntry {
    return .{
        .name = "[Symbol.hasInstance]",
        .length = 1,
        .id = @intFromEnum(PrototypeMethod.has_instance),
        .magic = 0,
        .cproto = .generic,
        .native_function = .{ .generic = &functionHasInstance },
        .managed = &functionHasInstanceDirect,
    };
}

/// Exec-direct ABI twin of `functionHasInstance` (NB2-B): identical body
/// routing, but the realm pair, output, and VM caller pair arrive by
/// parameter, so no NativeCallEnvironment recovery is needed. Declared
/// separately because `functionHasInstanceCall` carries an inferred error
/// set and the direct ABI requires the exact `HostError` surface.
fn functionHasInstanceDirect(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    argv: [*]const core.JSValue,
    argc: u32,
    _: *const core.NativeEntry,
    _: ?*core.Object,
) callconv(.c) core.JSValue {
    const args = argv[0..argc];
    const global = ctx.global orelse return builtin_dispatch.hostErrorToValue(ctx, null, error.InvalidBuiltinRegistry);
    const caller = builtin_dispatch.vmCallerView(ctx);
    const output = caller.output;
    const caller_function = caller.caller_function;
    const caller_frame = caller.caller_frame;
    return builtin_dispatch.hostResultToValue(
        ctx,
        call_runtime.functionHasInstanceCall(ctx, output, global, this_value, args, caller_function, caller_frame),
    );
}

fn functionCallDirect(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    argv: [*]const core.JSValue,
    argc: u32,
    _: *const core.NativeEntry,
    _: ?*core.Object,
) callconv(.c) core.JSValue {
    const args = argv[0..argc];
    const global = ctx.global orelse return builtin_dispatch.hostErrorToValue(ctx, null, error.InvalidBuiltinRegistry);
    const caller = builtin_dispatch.vmCallerView(ctx);
    const output = caller.output;
    const caller_function = caller.caller_function;
    const caller_frame = caller.caller_frame;
    return builtin_dispatch.hostResultToValue(
        ctx,
        call_runtime.functionCallCall(ctx, output, global, this_value, args, caller_function, caller_frame),
    );
}

fn functionApplyDirect(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    argv: [*]const core.JSValue,
    argc: u32,
    _: *const core.NativeEntry,
    _: ?*core.Object,
) callconv(.c) core.JSValue {
    const args = argv[0..argc];
    const global = ctx.global orelse return builtin_dispatch.hostErrorToValue(ctx, null, error.InvalidBuiltinRegistry);
    const caller = builtin_dispatch.vmCallerView(ctx);
    const output = caller.output;
    const caller_function = caller.caller_function;
    const caller_frame = caller.caller_frame;
    return builtin_dispatch.hostResultToValue(
        ctx,
        call_runtime.functionApplyCall(ctx, output, global, this_value, args, caller_function, caller_frame),
    );
}

/// qjs:41379 `js_function_hasInstance` -> `JS_OrdinaryIsInstanceOf(ctx,
/// argv[0], this_val)`. The receiver is the constructor, the first argument the
/// probed value.
fn functionHasInstance(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, 0) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == host_call.ctx);
    return call_runtime.functionHasInstanceCall(
        host_call.ctx,
        host_call.output,
        realm.global,
        host_call.this_value,
        host_call.args,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    );
}

fn functionEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&functionCall),
    };
}

fn functionCallEntry() core.host_function.InternalEntry {
    const id = @intFromEnum(PrototypeMethod.call);
    return .{
        .name = "call",
        .length = 1,
        .id = id,
        .magic = @intCast(id),
        .forwards_call = true,
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&functionCallRecord),
        // NB2-B: same shape as apply — the body consumes only the direct-ABI
        // parameter set, so the non-forwarding dispatch paths (e.g.
        // `fastNativeMethodCall`) skip the environment round-trip too.
        .managed = &functionCallDirect,
    };
}

/// qjs:41392 `JS_CFUNC_MAGIC_DEF("apply", 2, js_function_apply, 0)`: apply is
/// a dedicated C function in qjs, not a selector into a shared body. Mirror
/// that with its own record handler so the hot apply path skips the
/// `functionCall` magic switch. `forwards_call` routes it, like `call`, to
/// `op_call_method`'s window-rewrite arms (design §5.4): the VM tells the two
/// apart by `apply_entry_target`, spreads a dense argument list into the
/// operand window itself, and leaves every other array-like to this body.
fn functionApplyEntry() core.host_function.InternalEntry {
    const id = @intFromEnum(PrototypeMethod.apply);
    return .{
        .name = "apply",
        .length = 2,
        .id = id,
        .magic = @intCast(id),
        .forwards_call = true,
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&functionApplyRecord),
        // NB2-B (qjs:17563 `js_call_c_function` has no env side-channel):
        // the flat apply body takes the whole call state by parameter, so the
        // hot record dispatch skips the NativeCallEnvironment stores and the
        // `active_native_call` save/set/restore. `functionApplyRecord` stays
        // as the env-path shim for any dispatcher that still owns one.
        .managed = &functionApplyDirect,
    };
}

test "Function.call has a dedicated native record handler" {
    var call_handler: ?core.host_function.NativeGenericMagicFn = null;
    for (internal_entries) |entry| {
        if (entry.id == @intFromEnum(PrototypeMethod.call)) {
            const native = entry.native_function orelse continue;
            call_handler = switch (native) {
                .generic_magic => |handler| handler,
                else => null,
            };
        }
    }
    try std.testing.expect(call_handler != null);
    try std.testing.expect(call_handler.? == &functionCallRecord);
    for (internal_entries) |entry| {
        if (entry.id == @intFromEnum(PrototypeMethod.call)) {
            try std.testing.expect(entry.forwards_call);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

/// NB2 §5.4: identity of the two forwarding entries for the VM's window-rewrite
/// arms -- the target code pointer, exactly qjs's `js_function_call` /
/// `js_function_apply` C-pointer identity (the `default_has_instance_target`
/// precedent), never the name. The comptime adapter is memoized per
/// declaration, so the realm's table entry and these constants share one
/// pointer.
pub const call_entry_target = native_legacy.entryFromInternal(functionCallEntry()).target;
pub const apply_entry_target = native_legacy.entryFromInternal(functionApplyEntry()).target;

test "call/apply entry identity is the target code pointer" {
    try std.testing.expect(call_entry_target != apply_entry_target);
    try std.testing.expect(call_entry_target != default_has_instance_target);
    try std.testing.expect(apply_entry_target != default_has_instance_target);
    try std.testing.expect(@intFromPtr(call_entry_target) == @intFromPtr(&functionCallDirect));
    try std.testing.expect(@intFromPtr(apply_entry_target) == @intFromPtr(&functionApplyDirect));
}

test "Function.apply has a dedicated forwarding native record handler" {
    var apply_handler: ?core.host_function.NativeGenericMagicFn = null;
    for (internal_entries) |entry| {
        if (entry.id == @intFromEnum(PrototypeMethod.apply)) {
            const native = entry.native_function orelse continue;
            apply_handler = switch (native) {
                .generic_magic => |handler| handler,
                else => null,
            };
        }
    }
    try std.testing.expect(apply_handler != null);
    try std.testing.expect(apply_handler.? == &functionApplyRecord);
    for (internal_entries) |entry| {
        if (entry.id == @intFromEnum(PrototypeMethod.apply)) {
            // apply takes op_call_method's forwarding branch (design §5.4);
            // the VM's apply arm is selected by `apply_entry_target`.
            try std.testing.expect(entry.forwards_call);
            // NB2-B: the hot record dispatch must take the exec-direct ABI
            // (no NativeCallEnvironment round-trip) straight into the flat
            // apply body.
            try std.testing.expect(entry.managed != null);
            try std.testing.expect(entry.managed.? == &functionApplyDirect);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

/// Shared record handler for the remaining `.function` methods. Function.call
/// uses its own qjs-style function-list entry because it is a hot forwarding
/// primitive; the bodies stay in exec because they read engine call/frame
/// internals.
fn functionCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const ctx = host_call.ctx;
    const id: u32 = host_call.magic;
    return switch (id) {
        @intFromEnum(PrototypeMethod.to_string) => call.functionToStringValue(ctx.runtime, host_call.this_value),
        @intFromEnum(PrototypeMethod.bind) => {
            const realm = try builtin_dispatch.callableRealm(host_call);
            std.debug.assert(realm.realm == ctx);
            return call.functionBindCall(ctx, host_call.output, realm.global, &.{}, host_call.this_value, host_call.args);
        },
        else => error.TypeError,
    };
}

/// Dedicated apply record handler (qjs:41213 `js_function_apply`, magic 0).
/// Same shape as `functionCallRecord`: recover the exec environment, resolve
/// the callable realm once, then run the flat apply body.
fn functionApplyRecord(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == host_call.ctx);
    return call_runtime.functionApplyCall(
        host_call.ctx,
        host_call.output,
        realm.global,
        host_call.this_value,
        host_call.args,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    );
}

fn functionCallRecord(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == host_call.ctx);
    return call_runtime.functionCallCall(
        host_call.ctx,
        host_call.output,
        realm.global,
        host_call.this_value,
        host_call.args,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    );
}

test "constructFunctionFromSource roots function and source while compiling source text" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    @import("standard_globals.zig").configureRuntime(rt);
    const global = try zjs_vm.contextGlobal(ctx);
    const constructor = try global.getProperty(core.atom.ids.Function);
    const body = try core.string.String.createUtf8(rt, "return 1");

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const function_value = try constructFunctionFromSource(ctx, null, global, constructor, &.{body.value()}, null, null);
    const function_object = object_ops.functionObjectFromValue(function_value) orelse return error.TypeError;
    const stored = function_object.functionBytecode() orelse return error.TypeError;
    const function = call_runtime.functionBytecodeFromValue(stored) orelse return error.TypeError;
    const source = function.sourceText() orelse return error.TypeError;
    try std.testing.expect(std.mem.indexOf(u8, source, "return 1") != null);
}

pub fn constructFunctionFromSource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return constructDynamicFunctionFromSource(ctx, output, global, constructor, constructor, args, .normal, caller_function, caller_frame);
}

pub fn constructGeneratorFunctionFromSource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return constructDynamicFunctionFromSource(ctx, output, global, constructor, constructor, args, .generator, caller_function, caller_frame);
}

pub const DynamicFunctionKind = enum {
    normal,
    async_function,
    generator,
    async_generator,
};

pub fn constructDynamicFunctionFromSource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    new_target: core.JSValue,
    args: []const core.JSValue,
    kind: DynamicFunctionKind,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var params = std.ArrayList(u8).empty;
    defer params.deinit(ctx.runtime.memory.allocator);
    var body = std.ArrayList(u8).empty;
    defer body.deinit(ctx.runtime.memory.allocator);

    if (args.len > 0) {
        for (args[0 .. args.len - 1], 0..) |arg, idx| {
            if (idx != 0) try params.append(ctx.runtime.memory.allocator, ',');
            const string_value = try string_ops.toStringForAnnexB(ctx, output, global, arg, caller_function, caller_frame);
            try string_ops.appendSourceStringUtf8(ctx.runtime, &params, string_value);
        }
        const body_value = try string_ops.toStringForAnnexB(ctx, output, global, args[args.len - 1], caller_function, caller_frame);
        try string_ops.appendSourceStringUtf8(ctx.runtime, &body, body_value);
    }
    const compile_realm = try call_runtime.functionRealmContext(ctx, constructor);
    const function_global = compile_realm.global orelse return error.InvalidBuiltinRegistry;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(ctx.runtime.memory.allocator);
    const prefix = switch (kind) {
        .normal => "(function anonymous(",
        .async_function => "(async function anonymous(",
        .generator => "(function* anonymous(",
        .async_generator => "(async function* anonymous(",
    };
    try source.appendSlice(ctx.runtime.memory.allocator, prefix);
    try source.appendSlice(ctx.runtime.memory.allocator, params.items);
    try source.appendSlice(ctx.runtime.memory.allocator, "\n) {\n");
    try source.appendSlice(ctx.runtime.memory.allocator, body.items);
    try source.appendSlice(ctx.runtime.memory.allocator, "\n})");

    const filename = switch (kind) {
        .normal => "Function",
        .async_function => "AsyncFunction",
        .generator => "GeneratorFunction",
        .async_generator => "AsyncGeneratorFunction",
    };
    var compiled = try parser.compile(.{ .realm = compile_realm }, source.items, .{ .mode = .eval_direct, .filename = filename, .strict = false });
    defer compiled.deinit();
    if (compiled.syntax_error) |*parse_error| {
        // Compile-error surface: own fileName/lineNumber/columnNumber +
        // leading stack line (build_backtrace filename branch,
        // quickjs.c:7553-7570).
        const parse_filename = ctx.runtime.atoms.name(parse_error.filename) orelse filename;
        return error_stack_ops.throwParseSyntaxError(ctx, function_global, parse_filename, parse_error.position.line, parse_error.position.column, parse_error.message);
    }
    _ = compiled.functionBytecode() orelse return error.InvalidBytecode;
    const owned_root = compiled.takeFunctionBytecodeValue() orelse return error.InvalidBytecode;
    var root_function_value = try object_ops.createRootBytecodeFunctionObject(
        compile_realm,
        function_global,
        owned_root,
        .root_global,
    );
    var root_frame = core.runtime.rootValues(.{&root_function_value});
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);
    const root_function_object = object_ops.functionObjectFromValue(root_function_value) orelse return error.InvalidBytecode;
    const root_bytecode_value = root_function_object.functionBytecode() orelse return error.InvalidBytecode;
    const function = call_runtime.functionBytecodeFromValue(root_bytecode_value) orelse return error.InvalidBytecode;
    var nested_stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.runtime.stackSize());
    defer nested_stack.deinit(ctx.runtime);
    // A dynamic-function compilation is a *nested* eval inside a live VM call: the
    // outer frames hold roots this nested cycle pass cannot see, so running the
    // full-heap `break_var_ref_cycles_on_exit` collection here marks live outer
    // values (e.g. an in-flight exception) as garbage and frees them. qjs never
    // runs GC on eval exit (only at allocation thresholds / explicit JS_RunGC), so
    // pass `false`; the function expression makes no var_ref cycle of its own and
    // any cycle in the result is reclaimed by the top-level collection.
    const result = try runWithCallEnv(.{
        .ctx = compile_realm,
        .stack = &nested_stack,
        .function = function,
        .initial_this_value = function_global.value(),
        .var_refs = root_function_object.functionCaptures(),
        .output = output,
        .global = function_global,
        .current_function_value = root_function_value,
        .is_eval_code = true,
        .global_declarations_prevalidated = true,
    });
    // `runWithArgs` returns the completion value owned, but ALSO leaves an owned
    // copy on `nested_stack`. When that stack is a `vm_stack` arena window (the
    // carved-frame fast path), the leftover slot sits ABOVE the arena watermark
    // restored on frame exit. The `new_target.prototype` read below can run a
    // proxy `get` trap whose bytecode frame re-carves the same arena and
    // overwrites that orphaned slot; `nested_stack.deinit` would then free an
    // alias'd value (e.g. a `Proxy.revocable` `revoke` closure still owned by its
    // wrapper) — a refcount under-flow that dangles into a later cycle GC. Drain
    // the stack's owned copy now so the window is empty before any further
    // bytecode runs; `result` keeps the independently-owned reference.
    for (nested_stack.liveValues()) |*slot| {
        slot.* = core.JSValue.undefinedValue();
    }
    nested_stack.setLen(0);
    if (object_ops.functionObjectFromValue(result)) |function_object| {
        var prototype = try object_ops.dynamicFunctionNewTargetPrototype(ctx, output, global, new_target, kind, caller_function, caller_frame);
        defer prototype.deinit(ctx.runtime);
        try function_object.setPrototype(ctx.runtime, prototype.object());
    }
    return result;
}
