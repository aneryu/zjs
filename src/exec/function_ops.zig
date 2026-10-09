//! Function builtin records, dynamic-function construction, and standard-constructor [[Construct]].
//!
//! Call receivers and arguments are borrowed; created functions, compiled roots,
//! and returned completion values carry owned references and are explicitly
//! rooted across observable prototype work. Generic call/apply execution remains
//! in `call_runtime.zig`; this module owns the Function-domain record seam and
//! dynamic source compilation. The builtin table maps to QuickJS
//! `js_function_proto_funcs`.

const std = @import("std");
const zjs_vm = @import("zjs_vm.zig");
const runWithCallEnv = zjs_vm.runWithCallEnv;
const stack_mod = @import("stack.zig");
const object_ops = @import("object_ops.zig");
const parser = @import("../parser.zig");
const string_ops = @import("string_ops.zig");
const frame_mod = @import("frame.zig");
const bytecode = @import("../bytecode.zig");

const core = @import("../core/root.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call = @import("call.zig");
const call_runtime = @import("call_runtime.zig");
const array_ops = @import("array_ops.zig");
const builtin_glue = @import("builtin_glue.zig");
const coercion_ops = @import("value_ops.zig");
const exception_ops = @import("exception_ops.zig");
const disposable_ops = @import("disposable_ops.zig");
const promise_ops = @import("promise_ops.zig");
const regexp_fastpath = @import("regexp_ops.zig");
const constructCollectionWithPrototypeFromVm = object_ops.constructCollectionWithPrototypeFromVm;
const constructPrimitiveWrapperWithPrototype = object_ops.constructPrimitiveWrapperWithPrototype;
const isCallableValue = call_runtime.isCallableValue;
const objectRealmGlobal = object_ops.objectRealmGlobal;
const aggregateErrorConstructWithPrototype = object_ops.aggregateErrorConstructWithPrototype;
const arrayBufferMaxByteLengthOption = array_ops.arrayBufferMaxByteLengthOption;
const asyncDisposableStackConstructWithPrototype = disposable_ops.asyncDisposableStackConstructWithPrototype;
const canBeHeldWeakly = core.symbol.canBeHeldWeakly;
const constructFinalizationRegistryWithPrototype = object_ops.constructFinalizationRegistryWithPrototype;
const constructWeakRefWithPrototype = object_ops.constructWeakRefWithPrototype;
const dataViewConstructWithPrototype = object_ops.dataViewConstructWithPrototype;
const dataViewConstructorArgs = builtin_glue.dataViewConstructorArgs;
const disposableStackConstructWithPrototype = object_ops.disposableStackConstructWithPrototype;
const errorConstructWithPrototype = object_ops.errorConstructWithPrototype;
const promiseConstructWithPrototype = promise_ops.promiseConstructWithPrototype;
const regExpConstructCall = regexp_fastpath.regExpConstructCall;
const suppressedErrorConstructWithPrototype = object_ops.suppressedErrorConstructWithPrototype;
const typedArrayConstructToIndex = array_ops.typedArrayConstructToIndex;
const reflectConstructPrototypeVm = object_ops.reflectConstructPrototypeVm;
const throwRangeErrorMessage = exception_ops.throwRangeErrorMessage;
const valueTruthy = coercion_ops.valueTruthy;
const HostError = exception_ops.HostError;

pub const PrototypeMethod = enum(u32) {
    to_string = 1,
    bind = 2,
    call = 3,
    apply = 4,
    has_instance = 5,
};

/// `.function` domain callables that are not Function.prototype methods.
pub const IntrinsicMethod = enum(u32) {
    /// Global `eval` called indirectly. Direct eval never reaches this record:
    /// `OP_eval` recognizes the realm's intrinsic `eval` by identity.
    eval = 10,
    /// `%Function.prototype%` is itself callable and returns undefined.
    function_prototype = 11,
};

/// Whether `record` is the default `Function.prototype[@@hasInstance]`
/// (qjs:41395 `JS_CFUNC_DEF("[Symbol.hasInstance]", 1, js_function_hasInstance)`).
/// qjs compares the C function pointer (`js_function_hasInstance`); this
/// compares the entry's code target, which only the table's
/// `[Symbol.hasInstance]` record carries — not a name or shape cache.
pub inline fn recordIsDefaultHasInstance(record: *const core.NativeEntry) bool {
    return record.target == default_has_instance_target;
}

/// NB2: the comptime adapter is memoized per declaration, so the table's
/// `[Symbol.hasInstance]` entry and this constant share one thunk pointer.
const default_has_instance_target = builtin_dispatch.entryFromInternal(functionHasInstanceEntry()).target;

/// Declaration + dispatch table for the `.function` native-builtin domain
/// (QuickJS `js_function_proto_funcs` analogue, quickjs.c).
pub const internal_entries = [_]core.host_function.InternalEntry{
    functionCallEntry(),
    functionApplyEntry(),
    functionEntry("toString", 0, @intFromEnum(PrototypeMethod.to_string)),
    functionEntry("bind", 1, @intFromEnum(PrototypeMethod.bind)),
    // qjs:41395 `JS_CFUNC_DEF("[Symbol.hasInstance]", 1, js_function_hasInstance)`.
    // Every `instanceof` whose RHS does not override `Symbol.hasInstance` lands
    // here.
    //
    // `JS_CFUNC_DEF` is `JS_CFUNC_generic`, not `JS_CFUNC_MAGIC_DEF`: qjs gives
    // this method its own C function rather than a magic selector into a shared
    // body. Mirror that -- a dedicated `.generic` entry keeps the 24M-call
    // `instanceof` path out of `functionCall`'s magic switch, which the hot
    // `apply`/`bind`/`toString` trio shares.
    functionHasInstanceEntry(),
    functionEntry("eval", 1, @intFromEnum(IntrinsicMethod.eval)),
    functionEntry("", 0, @intFromEnum(IntrinsicMethod.function_prototype)),
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

/// The exec-direct ABI (NB2-B) for a Function.prototype method body: the realm
/// pair, output and VM caller pair arrive by parameter, so no
/// NativeCallEnvironment recovery is needed.
fn directEntry(comptime body: anytype) fn (*core.JSContext, core.JSValue, [*]const core.JSValue, u32, *const core.NativeEntry, ?*core.Object) callconv(.c) core.JSValue {
    return struct {
        fn entry(
            ctx: *core.JSContext,
            this_value: core.JSValue,
            argv: [*]const core.JSValue,
            argc: u32,
            _: *const core.NativeEntry,
            _: ?*core.Object,
        ) callconv(.c) core.JSValue {
            const global = ctx.global orelse return builtin_dispatch.hostErrorToValue(ctx, null, error.InvalidBuiltinRegistry);
            const caller = builtin_dispatch.vmCallerView(ctx);
            return builtin_dispatch.hostResultToValue(
                ctx,
                body(ctx, caller.output, global, this_value, argv[0..argc], caller.caller_function, caller.caller_frame),
            );
        }
    }.entry;
}

const functionHasInstanceDirect = directEntry(call_runtime.functionHasInstanceCall);
const functionCallDirect = directEntry(call_runtime.functionCallCall);
const functionApplyDirect = directEntry(call_runtime.functionApplyCall);

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
pub const call_entry_target = builtin_dispatch.entryFromInternal(functionCallEntry()).target;
pub const apply_entry_target = builtin_dispatch.entryFromInternal(functionApplyEntry()).target;

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

/// Shared record handler for the remaining `.function` methods. Function.call,
/// Function.apply and `[Symbol.hasInstance]` use their own qjs-style
/// function-list entries because they are hot forwarding primitives; the bodies stay in exec because they read engine call/frame
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
            return call.functionBindCall(ctx, host_call.output, realm.global, host_call.this_value, host_call.args);
        },
        @intFromEnum(IntrinsicMethod.function_prototype) => core.JSValue.undefinedValue(),
        @intFromEnum(IntrinsicMethod.eval) => {
            const realm = try builtin_dispatch.callableRealm(host_call);
            return call_runtime.indirectEval(realm.realm, host_call.output, realm.global, host_call.args, builtin_dispatch.callerBytecode(host_call));
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

pub const DynamicFunctionKind = enum {
    normal,
    async_function,
    generator,
    async_generator,
};

/// The dynamic-function program compiled to exactly one function expression
/// spanning `expected_source_len` bytes (the whole text minus its parens).
fn isSingleDynamicFunction(root: *const bytecode.FunctionBytecode, expected_source_len: usize) bool {
    var child: ?*const bytecode.FunctionBytecode = null;
    for (root.cpoolSlice()) |value| {
        const function = call_runtime.functionBytecodeFromValue(value) orelse continue;
        if (child != null) return false;
        child = function;
    }
    const function = child orelse return false;
    const debug = function.debugInfo() orelse return true;
    return debug.source_ptr == null or @as(usize, @intCast(@max(debug.source_len, 0))) == expected_source_len;
}

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
    defer params.deinit(ctx.runtime.nativeAllocator());
    var body = std.ArrayList(u8).empty;
    defer body.deinit(ctx.runtime.nativeAllocator());

    if (args.len > 0) {
        for (args[0 .. args.len - 1], 0..) |arg, idx| {
            if (idx != 0) try params.append(ctx.runtime.nativeAllocator(), ',');
            const string_value = try string_ops.toStringForAnnexB(ctx, output, global, arg, caller_function, caller_frame);
            try string_ops.appendSourceStringUtf8(ctx.runtime, &params, string_value);
        }
        const body_value = try string_ops.toStringForAnnexB(ctx, output, global, args[args.len - 1], caller_function, caller_frame);
        try string_ops.appendSourceStringUtf8(ctx.runtime, &body, body_value);
    }
    const compile_realm = try call_runtime.functionRealmContext(ctx, constructor);
    const function_global = compile_realm.global orelse return error.InvalidBuiltinRegistry;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(ctx.runtime.nativeAllocator());
    const prefix = switch (kind) {
        .normal => "(function anonymous(",
        .async_function => "(async function anonymous(",
        .generator => "(function* anonymous(",
        .async_generator => "(async function* anonymous(",
    };
    try source.appendSlice(ctx.runtime.nativeAllocator(), prefix);
    try source.appendSlice(ctx.runtime.nativeAllocator(), params.items);
    try source.appendSlice(ctx.runtime.nativeAllocator(), "\n) {\n");
    try source.appendSlice(ctx.runtime.nativeAllocator(), body.items);
    try source.appendSlice(ctx.runtime.nativeAllocator(), "\n})");

    const filename = switch (kind) {
        .normal => "Function",
        .async_function => "AsyncFunction",
        .generator => "GeneratorFunction",
        .async_generator => "AsyncGeneratorFunction",
    };
    // CreateDynamicFunction: [[ScriptOrModule]] is the active one, so a
    // dynamic import() in the body resolves against the calling module.
    const script_or_module = if (caller_function) |outer_function| outer_function.scriptOrModule() else null;
    var compiled = try parser.compile(.{ .realm = compile_realm }, source.items, .{ .mode = .eval_direct, .filename = filename, .script_or_module = script_or_module, .strict = false });
    defer compiled.deinit();
    if (compiled.syntax_error) |*parse_error| {
        // Compile-error surface: own fileName/lineNumber/columnNumber +
        // leading stack line (build_backtrace filename branch,
        // quickjs.c).
        const parse_filename = ctx.runtime.atoms.name(parse_error.filename) orelse filename;
        return exception_ops.throwParseSyntaxError(ctx, function_global, parse_filename, parse_error.position.line, parse_error.position.column, parse_error.message);
    }
    const root_fb = compiled.functionBytecode() orelse return error.InvalidBytecode;
    // CreateDynamicFunction parses the parameters and the body on their own.
    // Concatenated text can otherwise hide a comment or template spanning the
    // two, or a body that closes the function early and runs code at
    // construction: require the parameters to parse alone and the whole text
    // to be exactly one function expression.
    {
        var params_source = std.ArrayList(u8).empty;
        defer params_source.deinit(ctx.runtime.nativeAllocator());
        try params_source.appendSlice(ctx.runtime.nativeAllocator(), prefix);
        try params_source.appendSlice(ctx.runtime.nativeAllocator(), params.items);
        try params_source.appendSlice(ctx.runtime.nativeAllocator(), "\n) {\n})");
        var params_compiled = try parser.compile(.{ .realm = compile_realm }, params_source.items, .{ .mode = .eval_direct, .filename = filename, .strict = false });
        defer params_compiled.deinit();
        if (params_compiled.syntax_error) |*parse_error| {
            const parse_filename = ctx.runtime.atoms.name(parse_error.filename) orelse filename;
            return exception_ops.throwParseSyntaxError(ctx, function_global, parse_filename, parse_error.position.line, parse_error.position.column, parse_error.message);
        }
    }
    if (!isSingleDynamicFunction(root_fb, source.items.len - "()".len)) {
        return exception_ops.throwSyntaxErrorMessage(ctx, function_global, "invalid function body");
    }
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
    var nested_stack = stack_mod.Stack.init(ctx.runtime, ctx.runtime.stackSize());
    defer nested_stack.deinit(ctx.runtime);
    // A dynamic-function compilation is a *nested* eval inside a live VM call: the
    // outer frames hold roots this nested cycle pass cannot see, so running the
    // full-heap `break_var_ref_cycles_on_exit` collection here marks live outer
    // values (e.g. an in-flight exception) as garbage and frees them. qjs never
    // runs GC on eval exit (only at allocation thresholds / explicit JS_RunGC), so
    // leave `break_var_ref_cycles_on_exit` at its default false; the function
    // expression makes no var_ref cycle of its own and any cycle in the result
    // is reclaimed by the top-level collection.
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
    });
    // `runWithCallEnv` returns the completion value but also leaves a copy on
    // `nested_stack`. When that stack is a `vm_stack` arena window (the
    // carved-frame fast path), the leftover slot sits ABOVE the arena watermark
    // restored on frame exit, and the `new_target.prototype` read below can run
    // a proxy `get` trap whose frame re-carves the same arena. Empty the window
    // before any further bytecode runs; `result` keeps the value.
    for (nested_stack.liveValues()) |*slot| {
        slot.* = core.JSValue.undefinedValue();
    }
    nested_stack.setLen(0);
    if (object_ops.functionObjectFromValue(result)) |function_object| {
        const prototype = try object_ops.dynamicFunctionNewTargetPrototype(ctx, output, global, new_target, kind, caller_function, caller_frame);
        try function_object.setPrototype(ctx.runtime, prototype);
    }
    return result;
}

// ----- Standard-constructor [[Construct]] helpers -----

fn constructIteratorWithNewTarget(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    new_target: core.JSValue,
) !core.JSValue {
    if (new_target.sameValue(constructor)) return exception_ops.throwTypeErrorMessage(ctx, global, "Iterator is an abstract class");
    const prototype = try reflectConstructPrototypeVm(ctx, output, global, "Iterator", new_target, caller_function, caller_frame);
    const instance = try core.Object.create(ctx.runtime, core.class.ids.object, prototype);
    return instance.value();
}

fn numberConstructWithNewTarget(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    new_target: core.JSValue,
) !core.JSValue {
    const primitive = try builtin_glue.numberFunctionCall(ctx, output, global, args);
    const prototype = try reflectConstructPrototypeVm(ctx, output, global, "Number", new_target, caller_function, caller_frame);
    return try constructPrimitiveWrapperWithPrototype(ctx.runtime, core.class.ids.number, prototype, primitive);
}

fn booleanConstructWithNewTarget(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    new_target: core.JSValue,
) !core.JSValue {
    const primitive = core.JSValue.boolean(args.len >= 1 and valueTruthy(args[0]));
    const prototype = try reflectConstructPrototypeVm(ctx, output, global, "Boolean", new_target, caller_function, caller_frame);
    return try constructPrimitiveWrapperWithPrototype(ctx.runtime, core.class.ids.boolean, prototype, primitive);
}

fn weakRefConstructWithNewTarget(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    new_target: core.JSValue,
) !core.JSValue {
    const target = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (!canBeHeldWeakly(ctx.runtime, target)) return exception_ops.throwTypeErrorMessage(ctx, global, "invalid target");
    const prototype = try reflectConstructPrototypeVm(ctx, output, global, "WeakRef", new_target, caller_function, caller_frame);
    return try constructWeakRefWithPrototype(ctx.runtime, target, prototype);
}

fn finalizationRegistryConstructWithNewTarget(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    new_target: core.JSValue,
) !core.JSValue {
    const cleanup_callback = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (!isCallableValue(cleanup_callback)) return error.NotAFunction;
    const prototype = try reflectConstructPrototypeVm(ctx, output, global, "FinalizationRegistry", new_target, caller_function, caller_frame);
    return try constructFinalizationRegistryWithPrototype(ctx, cleanup_callback, prototype);
}

/// [[Construct]] of a standard constructor, for a direct `new C()` and for a
/// foreign `new.target` (derived-class `super(...)`, `Reflect.construct`)
/// alike. Null for `.none`: the caller continues with its own dispatch.
pub fn constructBuiltin(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: *core.Object,
    kind: core.host_function.NativeConstructorKind,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    new_target: core.JSValue,
) !?core.JSValue {
    const name = kind.name();
    const constructor_value = constructor.value();
    switch (kind) {
        .none => return null,
        .symbol => return try exception_ops.throwTypeErrorMessage(ctx, global, "Symbol is not a constructor"),
        .bigint => return try exception_ops.throwTypeErrorMessage(ctx, global, "BigInt is not a constructor"),
        // §23.2.1.1: the abstract constructor throws before reading newTarget.
        .typed_array => return try exception_ops.throwTypeErrorMessage(ctx, global, "abstract class TypedArray not directly constructable"),
        .iterator => return try constructIteratorWithNewTarget(ctx, output, global, constructor_value, caller_function, caller_frame, new_target),
        .function => return try constructDynamicFunctionFromSource(ctx, output, global, constructor_value, new_target, args, .normal, caller_function, caller_frame),
        .async_function => return try constructDynamicFunctionFromSource(ctx, output, global, constructor_value, new_target, args, .async_function, caller_function, caller_frame),
        .generator_function => return try constructDynamicFunctionFromSource(ctx, output, global, constructor_value, new_target, args, .generator, caller_function, caller_frame),
        .async_generator_function => return try constructDynamicFunctionFromSource(ctx, output, global, constructor_value, new_target, args, .async_generator, caller_function, caller_frame),
        .array_buffer, .shared_array_buffer => {
            const byte_length = if (args.len >= 1)
                try typedArrayConstructToIndex(ctx, output, global, args[0])
            else
                @as(usize, 0);
            const max_byte_length = try arrayBufferMaxByteLengthOption(ctx, output, global, args, byte_length);
            const prototype = try reflectConstructPrototypeVm(ctx, output, global, name, new_target, caller_function, caller_frame);
            if (kind == .shared_array_buffer) {
                return try core.typed_array.sharedArrayBufferConstructLength(ctx.runtime, byte_length, max_byte_length, prototype);
            }
            return try core.typed_array.arrayBufferConstructLength(ctx.runtime, byte_length, max_byte_length, prototype);
        },
        .data_view => {
            const coerced = try dataViewConstructorArgs(ctx, output, global, args);
            const prototype = try reflectConstructPrototypeVm(ctx, output, global, name, new_target, caller_function, caller_frame);
            return try dataViewConstructWithPrototype(ctx.runtime, args[0], coerced, prototype);
        },
        .regexp => return try regExpConstructCall(ctx, output, global, constructor, new_target, args, caller_function, caller_frame),
        .promise => return try constructPromiseNativeVm(ctx, output, global, constructor, new_target, args, caller_function, caller_frame),
        .number => return try numberConstructWithNewTarget(ctx, output, global, args, caller_function, caller_frame, new_target),
        .boolean => return try booleanConstructWithNewTarget(ctx, output, global, args, caller_function, caller_frame, new_target),
        .weak_ref => return try weakRefConstructWithNewTarget(ctx, output, global, args, caller_function, caller_frame, new_target),
        .finalization_registry => return try finalizationRegistryConstructWithNewTarget(ctx, output, global, args, caller_function, caller_frame, new_target),
        .int8_array,
        .uint8_array,
        .uint8_clamped_array,
        .int16_array,
        .uint16_array,
        .int32_array,
        .uint32_array,
        .float16_array,
        .float32_array,
        .float64_array,
        .bigint64_array,
        .biguint64_array,
        => return array_ops.typedArrayConstructVm(ctx, output, global, new_target, constructor, args, caller_function, caller_frame) catch |err| switch (err) {
            // Name a bare RangeError; keep one that already has a message.
            error.RangeError => if (ctx.hasException()) return err else return try exception_ops.throwRangeErrorMessage(ctx, global, "invalid array index"),
            else => return err,
        },
        .proxy => {
            const target = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const handler = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
            return @as(?core.JSValue, object_ops.constructProxyInstance(ctx, target, handler) catch |err| switch (err) {
                error.TypeError => return @as(?core.JSValue, try exception_ops.throwTypeErrorMessage(ctx, global, "not an object")),
                else => return err,
            });
        },
        // Their arguments are converted before the prototype is read
        // (§21.4.2.1, §22.1.1.1); the direct-construct bodies own that order.
        .string, .date => {
            const native_ref = core.function.decodeNativeBuiltinId(constructor.nativeFunctionId()) orelse return error.InvalidBuiltinRegistry;
            return if (kind == .string)
                try call_runtime.constructNativeInScope(call_runtime.constructStringBuiltinNativeInScope, ctx, output, global, constructor, native_ref, new_target, args, caller_function, caller_frame)
            else
                try call_runtime.constructNativeInScope(call_runtime.constructDateBuiltinNativeInScope, ctx, output, global, constructor, native_ref, new_target, args, caller_function, caller_frame);
        },
        .object,
        .array,
        .error_,
        .eval_error,
        .range_error,
        .reference_error,
        .syntax_error,
        .type_error,
        .uri_error,
        .internal_error,
        .aggregate_error,
        .suppressed_error,
        .disposable_stack,
        .async_disposable_stack,
        .map,
        .set,
        .weak_map,
        .weak_set,
        => {},
    }

    const prototype = try reflectConstructPrototypeVm(ctx, output, global, name, new_target, caller_function, caller_frame);
    switch (kind) {
        .object => {
            const instance = try core.Object.create(ctx.runtime, core.class.ids.object, prototype);
            return instance.value();
        },
        .array => return try call_runtime.constructArrayNativeRecordVm(ctx, output, global, constructor, prototype, args, caller_function, caller_frame),
        .aggregate_error => {
            const constructor_global = objectRealmGlobal(constructor) orelse global;
            return try aggregateErrorConstructWithPrototype(ctx, output, constructor_global, prototype, args, caller_function, caller_frame);
        },
        .suppressed_error => return try suppressedErrorConstructWithPrototype(ctx, output, global, prototype, args, caller_function, caller_frame),
        .error_,
        .eval_error,
        .range_error,
        .reference_error,
        .syntax_error,
        .type_error,
        .uri_error,
        .internal_error,
        => return try errorConstructWithPrototype(ctx, output, global, prototype, args, caller_function, caller_frame),
        .disposable_stack => return try disposableStackConstructWithPrototype(ctx, prototype),
        .async_disposable_stack => return try asyncDisposableStackConstructWithPrototype(ctx, global, prototype),
        .map, .set, .weak_map, .weak_set => return try constructCollectionWithPrototypeFromVm(ctx, output, global, collectionConstructorId(kind), args, prototype),
        else => unreachable,
    }
}

/// The `builtin_method_ids.collection.ConstructorKind` of a Map / Set /
/// WeakMap / WeakSet constructor.
fn collectionConstructorId(kind: core.host_function.NativeConstructorKind) u32 {
    const Collection = core.host_function.builtin_method_id_lookup.collection.ConstructorKind;
    const collection: Collection = switch (kind) {
        .map => .map,
        .set => .set,
        .weak_map => .weak_map,
        .weak_set => .weak_set,
        else => unreachable, // the caller's arm admits only the four collections
    };
    return @intFromEnum(collection);
}

/// `new Promise(executor)`: GetPrototypeFromConstructor runs a VM `[[Get]]`
/// (an accessor or Proxy `newTarget.prototype`) inside the Promise native frame.
fn constructPromiseNativeVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    new_target: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    try builtin_dispatch.preflightCFunctionCall(ctx, global, function_object, 1);
    var native_scope = builtin_dispatch.NativeBacktraceScope.init(ctx, function_object);
    native_scope.push();
    defer native_scope.deinit();

    return constructPromiseInScope(ctx, output, global, new_target, args, caller_function, caller_frame) catch |err| {
        try builtin_dispatch.materializeRuntimeError(ctx, global, err);
        return err;
    };
}

fn constructPromiseInScope(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    new_target: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const executor = if (args.len >= 1)
        args[0]
    else
        return exception_ops.throwTypeErrorMessage(ctx, global, "not a function");
    if (!isCallableValue(executor)) return exception_ops.throwTypeErrorMessage(ctx, global, "not a function");

    const prototype = try reflectConstructPrototypeVm(ctx, output, global, "Promise", new_target, caller_function, caller_frame);
    return promiseConstructWithPrototype(ctx, output, global, prototype, args, caller_function, caller_frame);
}
