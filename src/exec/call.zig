const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const bytecode_opcode = @import("../bytecode/opcode.zig");
const function_bytecode = @import("../bytecode/function.zig");
const closure_mod = @import("closure.zig");
const construct_mod = @import("construct.zig");
const frame_mod = @import("frame.zig");
const globals_mod = core.global_slots;
const host_dispatch_stats = @import("host_dispatch_stats.zig");
const property_ops = @import("property_ops.zig");
const value_ops = @import("value_ops.zig");
const call_runtime = @import("call_runtime.zig");
const array_ops = @import("array_ops.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const coercion_ops = @import("coercion_ops.zig");
const disposable_ops = @import("disposable_ops.zig");
const exception_ops = @import("vm_exception_ops.zig");
const math_ops = @import("math_ops.zig");
const object_ops = @import("object_ops.zig");
const promise_ops = @import("promise_ops.zig");
const reflect_ops = @import("reflect_ops.zig");
const dtoa = @import("../libs/number_format.zig");
const unicode = @import("../libs/unicode.zig");
const std = @import("std");
const exceptions = @import("exceptions.zig");
const HostError = exceptions.HostError;
const PrintError = HostError || error{InvalidRadix};

// Construct ref for the String wrapper boxing path (`primitiveWrapper`). The
// String constructor record's construct branch forwards `args`/`new_target` to
// `constructWithPrototype`, so routing boxing through it (Phase 6b-3 STEP 6)
// keeps exec free of a direct `builtins.string.constructWithPrototype` call.
const string_construct_ref = core.function.NativeBuiltinRef{
    .domain = .string,
    .id = @intFromEnum(core.host_function.builtin_method_ids.string.ConstructorMethod.call),
};

fn hostResult(result: anytype) HostError!switch (@typeInfo(@TypeOf(result))) {
    .error_union => |info| info.payload,
    else => @compileError("hostResult expects an error union"),
} {
    return result catch |err| return @errorCast(err);
}

fn restoreEvalGlobalLexicals(
    ctx: *core.JSContext,
    global: *core.Object,
    saved_lexicals: ?*core.Object,
    keep_active_lexicals: bool,
) !void {
    const active_lexicals = ctx.lexicals;
    try global.setGlobalLexicals(ctx.runtime, active_lexicals);
    ctx.lexicals = if (keep_active_lexicals) active_lexicals else saved_lexicals;
}

pub fn returnThis(this_value: core.JSValue) core.JSValue {
    return this_value.dup();
}

/// QuickJS source map: JS_CallInternal() dispatches callable objects after the
/// VM has prepared callee/argument values. This Zig slice currently owns the
/// host callables installed for the CLI-visible global object.
pub fn hostGlobalOwnPropertyCapacity(rt: *core.JSRuntime) usize {
    return rt.standardGlobalOwnPropertyCapacity() + 6; // print, globalThis, NaN, Infinity, undefined, console
}

pub fn contextGlobalOwnPropertyCapacity(rt: *core.JSRuntime) usize {
    return hostGlobalOwnPropertyCapacity(rt) + 1; // scriptArgs, installed by the public CLI host setup
}

pub fn installHostGlobals(rt: *core.JSRuntime, global: *core.Object) !void {
    try global.reserveOwnPropertyCapacityAssumingPlain(rt, hostGlobalOwnPropertyCapacity(rt));
    const output_external_id = try registerOutputExternalHostFunction(rt);
    try definePredefinedExternalHostFunction(rt, global, "print", hostFunctionLength(.output), output_external_id);
    try rt.installStandardGlobals(global);
    try defineGlobalThisProperty(rt, global);
    try defineNumberConstantPropertyAssumingNew(rt, global, "NaN", std.math.nan(f64));
    try defineNumberConstantPropertyAssumingNew(rt, global, "Infinity", std.math.inf(f64));
    try global.defineOwnPropertyAssumingNew(rt, core.atom.ids.undefined_, core.Descriptor.data(core.JSValue.undefinedValue(), false, false, false));

    try defineConsoleObject(rt, global, output_external_id);
}

fn defineConsoleObject(rt: *core.JSRuntime, global: *core.Object, output_external_id: u32) !void {
    const key = predefinedStringAtom("console");
    try global.defineConsoleAutoInitProperty(
        rt,
        key,
        core.property.Flags.data(true, true, true),
        core.host_function.ids.external_host,
        output_external_id,
    );
}

pub fn callValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    callee: core.JSValue,
    args: []const core.JSValue,
) HostError!core.JSValue {
    return callValueWithThisAndGlobals(ctx, output, &.{}, core.JSValue.undefinedValue(), callee, args);
}

pub fn callValueWithGlobals(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    globals: []globals_mod.Slot,
    callee: core.JSValue,
    args: []const core.JSValue,
) !core.JSValue {
    return callValueWithThisAndGlobals(ctx, output, globals, core.JSValue.undefinedValue(), callee, args);
}

pub fn callValueWithThis(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    this_value: core.JSValue,
    callee: core.JSValue,
    args: []const core.JSValue,
) !core.JSValue {
    return callValueWithThisAndGlobals(ctx, output, &.{}, this_value, callee, args);
}

pub fn callValueWithThisAndGlobals(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    globals: []globals_mod.Slot,
    this_value: core.JSValue,
    callee: core.JSValue,
    args: []const core.JSValue,
) !core.JSValue {
    return callValueWithThisGlobalsAndGlobal(ctx, output, null, globals, this_value, callee, args);
}

pub fn callValueWithThisGlobalsAndGlobal(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    input_this_value: core.JSValue,
    input_callee: core.JSValue,
    input_args: []const core.JSValue,
) !core.JSValue {
    var this_value = input_this_value;
    var callee = input_callee;
    var inline_args: [8]core.JSValue = undefined;
    var args_buffer: core.runtime.ValueRootBuffer = .{};
    defer args_buffer.deinit(ctx.runtime);
    var args: []core.JSValue = inline_args[0..0];
    if (input_args.len <= inline_args.len) {
        args = inline_args[0..input_args.len];
        @memcpy(args, input_args);
    } else {
        args_buffer = try core.runtime.ValueRootBuffer.initCopy(ctx.runtime, input_args);
        args = args_buffer.values;
    }
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &this_value },
        .{ .value = &callee },
    };
    var root_slices = [_]core.runtime.ValueRootSlice{
        .{ .mutable = &args },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
        .slices = &root_slices,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    if (thisObject(callee)) |proxy| {
        if (proxy.proxyTarget() != null and object_ops.proxyTargetIsCallable(callee)) {
            return object_ops.callProxyApply(ctx, output, global orelse return error.TypeError, callee, proxy, this_value, args, null, null);
        }
    }
    const object = expectCallableObject(callee) orelse return error.TypeError;
    if (object.class_id == core.class.ids.bound_function) {
        return callBoundFunction(ctx, output, global, globals, object, args);
    }
    if (try promiseResolvingFunctionCall(ctx.runtime, object, args)) |value| return value;
    if (try promiseCapabilityExecutorCall(ctx.runtime, object, args)) |value| return value;
    if (try promiseCombinatorElementCall(ctx, output, global, globals, object, args)) |value| return value;
    if (object.hostFunctionKindSlot().* != 0) {
        const record = hostFunctionRecordFromId(object.hostFunctionKindSlot().*) orelse return error.TypeError;
        return callHostFunction(ctx, output, global, globals, object, this_value, args, record, .{});
    }
    if (object.class_id == core.class.ids.bytecode_function or
        object.class_id == core.class.ids.generator_function or
        object.class_id == core.class.ids.async_function or
        object.class_id == core.class.ids.async_generator_function)
    {
        return call_runtime.callValueOrBytecode(ctx, output, global orelse return error.TypeError, this_value, callee, args, null, null);
    }
    if (object.class_id == core.class.ids.c_closure) {
        const closure_kind = closure_mod.closureKind(ctx.runtime, callee) catch 0;
        if (closure_kind == 51) {
            const encoded = try closure_mod.closureValue(ctx.runtime, callee);
            return construct_mod.constructCollectionClosure(ctx, encoded, globals);
        }
        return closure_mod.callWithThis(ctx.runtime, callee, this_value, args, globals) catch |err| switch (err) {
            else => err,
        };
    }
    return callNativeBuiltin(ctx, output, global, globals, this_value, object, args);
}

pub fn printValue(rt: *core.JSRuntime, writer: *std.Io.Writer, value: core.JSValue) PrintError!void {
    if (value.isSymbol()) {
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(rt.memory.allocator);
        try value_ops.appendValueString(rt, &buffer, value);
        try writer.writeAll(buffer.items);
    } else if (value.asInt32()) |int_value| {
        var int_buf: [32]u8 = undefined;
        try writer.writeAll(dtoa.formatInt32(&int_buf, int_value));
    } else if (value_ops.numberValue(value)) |float_value| {
        if (std.math.isNan(float_value)) {
            try writer.writeAll("NaN");
        } else if (std.math.isPositiveInf(float_value)) {
            try writer.writeAll("Infinity");
        } else if (std.math.isNegativeInf(float_value)) {
            try writer.writeAll("-Infinity");
        } else if (std.math.isNegativeZero(float_value)) {
            try writer.writeAll("0");
        } else {
            var float_buf: [64]u8 = undefined;
            try writer.writeAll(try value_ops.formatFiniteNumber(&float_buf, float_value));
        }
    } else if (value.asShortBigInt()) |bigint_value| {
        var bigint_buf: [32]u8 = undefined;
        try writer.writeAll(dtoa.formatInt64(&bigint_buf, bigint_value));
    } else if (value.isBigInt()) {
        var big = try value_ops.cloneBigIntValue(rt, value);
        defer big.deinit();
        const text = try big.formatBase10Alloc(rt.memory.allocator);
        defer rt.memory.allocator.free(text);
        try writer.writeAll(text);
    } else if (value.asBool()) |bool_value| {
        try writer.writeAll(if (bool_value) "true" else "false");
    } else if (value.isUndefined()) {
        try writer.writeAll("undefined");
    } else if (value.isNull()) {
        try writer.writeAll("null");
    } else if (value.isString()) {
        try printString(rt, writer, value);
    } else if (value.isObject()) {
        const header = value.refHeader() orelse return writer.writeAll("[object Object]");
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (isFunctionClass(object_value.class_id)) {
            try printNativeFunction(rt, writer, object_value);
        } else if (object_value.class_id == core.class.ids.array_buffer) {
            try writer.writeAll("[object ArrayBuffer]");
        } else if (object_value.class_id == core.class.ids.promise) {
            try writer.writeAll("[object Promise]");
        } else if (object_value.flags.is_array) {
            try printArray(rt, writer, object_value);
        } else {
            try writer.writeAll("[object Object]");
        }
    } else {
        try writer.writeAll("[object Object]");
    }
}

// Engine-internal host callables dispatched by id. Host/embedder native
// functions never extend this enum: they go through the `external_host`
// id + per-runtime `ExternalRecord` registry (see docs/api-boundary.md).
// The id values are frozen; gaps left by the deleted legacy qjs:std/qjs:os
// cluster stay unused.
pub const HostFunction = enum(i32) {
    output = core.host_function.ids.output,
    dstr_get = 15,
    dstr_close = 16,
    dstr_rest = 17,
    dstr_obj_rest = 18,
    dstr_elide = 19,
    dstr_require_iterator = 109,
    using_create_disposable_stack = 111,
    using_add_sync_resource = 112,
    using_dispose_sync_stack = 113,
    using_dispose_sync_stack_for_throw = 114,
    using_create_async_disposable_stack = 115,
    using_add_async_resource = 116,
    using_dispose_async_stack = 117,
    using_dispose_async_stack_for_throw = 118,
    external_host = core.host_function.ids.external_host,
};

const HostCallFlags = struct {
    constructor: bool = false,
};

const HostCall = struct {
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    func_obj: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    flags: HostCallFlags,
};

const HostNativeFn = *const fn (HostCall) HostError!core.JSValue;

const HostFunctionRecord = struct {
    length: i32,
    call: HostNativeFn,
};

const max_host_function_id = @max(
    @intFromEnum(HostFunction.using_dispose_async_stack_for_throw),
    @intFromEnum(HostFunction.external_host),
);

const host_function_records: [max_host_function_id + 1]?HostFunctionRecord = records: {
    var records = [_]?HostFunctionRecord{null} ** (max_host_function_id + 1);
    records[@intFromEnum(HostFunction.output)] = .{ .length = 1, .call = hostCallOutput };
    records[@intFromEnum(HostFunction.dstr_get)] = .{ .length = 2, .call = hostCallDstrGet };
    records[@intFromEnum(HostFunction.dstr_elide)] = .{ .length = 2, .call = hostCallDstrElide };
    records[@intFromEnum(HostFunction.dstr_rest)] = .{ .length = 2, .call = hostCallDstrRest };
    records[@intFromEnum(HostFunction.dstr_obj_rest)] = .{ .length = 1, .call = hostCallDstrObjectRest };
    records[@intFromEnum(HostFunction.dstr_close)] = .{ .length = 1, .call = hostCallDstrClose };
    records[@intFromEnum(HostFunction.dstr_require_iterator)] = .{ .length = 1, .call = hostCallDstrRequireIterator };
    records[@intFromEnum(HostFunction.using_create_disposable_stack)] = .{ .length = 0, .call = hostCallUsingCreateDisposableStack };
    records[@intFromEnum(HostFunction.using_add_sync_resource)] = .{ .length = 2, .call = hostCallUsingAddSyncResource };
    records[@intFromEnum(HostFunction.using_dispose_sync_stack)] = .{ .length = 1, .call = hostCallUsingDisposeSyncStack };
    records[@intFromEnum(HostFunction.using_dispose_sync_stack_for_throw)] = .{ .length = 2, .call = hostCallUsingDisposeSyncStackForThrow };
    records[@intFromEnum(HostFunction.using_create_async_disposable_stack)] = .{ .length = 0, .call = hostCallUsingCreateAsyncDisposableStack };
    records[@intFromEnum(HostFunction.using_add_async_resource)] = .{ .length = 2, .call = hostCallUsingAddAsyncResource };
    records[@intFromEnum(HostFunction.using_dispose_async_stack)] = .{ .length = 1, .call = hostCallUsingDisposeAsyncStack };
    records[@intFromEnum(HostFunction.using_dispose_async_stack_for_throw)] = .{ .length = 2, .call = hostCallUsingDisposeAsyncStackForThrow };
    records[@intFromEnum(HostFunction.external_host)] = .{ .length = 0, .call = hostCallExternalHostFunction };
    break :records records;
};

fn hostFunctionRecord(kind: HostFunction) HostFunctionRecord {
    return host_function_records[@intCast(@intFromEnum(kind))].?;
}

fn hostFunctionRecordFromId(value: i32) ?HostFunctionRecord {
    if (value < 0 or value > max_host_function_id) return null;
    return host_function_records[@intCast(value)];
}

fn callHostFunction(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    func_obj: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    record: HostFunctionRecord,
    flags: HostCallFlags,
) !core.JSValue {
    return record.call(.{
        .ctx = ctx,
        .output = output,
        .global = global,
        .globals = globals,
        .func_obj = func_obj,
        .this_value = this_value,
        .args = args,
        .flags = flags,
    });
}

fn hostCallExternalHostFunction(call: HostCall) HostError!core.JSValue {
    const id = call.func_obj.externalHostFunctionId();
    const record = call.ctx.runtime.externalHostFunction(id) orelse return error.TypeError;
    return record.call(record.ptr, .{
        .ctx = call.ctx,
        .output = call.output,
        .global = call.global,
        .func_obj = call.func_obj,
        .this_value = call.this_value,
        .args = call.args,
    }) catch |err| return throwExternalHostError(call, err);
}

fn throwExternalHostError(call: HostCall, err: anyerror) HostError!core.JSValue {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.ProcessExit) return error.ProcessExit;
    if (err == error.Interrupted) return error.Interrupted;
    if (err == error.Timeout) return error.Timeout;
    if (err == error.StackOverflow) return error.StackOverflow;
    if (err == error.UnhandledPromiseRejection) return error.UnhandledPromiseRejection;
    if (call.ctx.hasException()) return error.JSException;

    const global = call.global orelse
        call.func_obj.functionRealmGlobalPtr() orelse
        call.ctx.global orelse
        return externalHostError(err);
    const error_info = externalHostErrorInfo(err);
    const error_value = try hostResult(exception_ops.createNamedError(
        call.ctx,
        global,
        error_info.name,
        error_info.message,
    ));
    if (call.ctx.hasException()) call.ctx.clearException();
    _ = call.ctx.throwValue(error_value);
    return error.JSException;
}

fn externalHostErrorInfo(err: anyerror) struct { name: []const u8, message: []const u8 } {
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "TypeError")) return .{ .name = "TypeError", .message = "" };
    if (std.mem.eql(u8, name, "RangeError")) return .{ .name = "RangeError", .message = "" };
    if (std.mem.eql(u8, name, "SyntaxError")) return .{ .name = "SyntaxError", .message = "" };
    if (std.mem.eql(u8, name, "ReferenceError")) return .{ .name = "ReferenceError", .message = "" };
    if (std.mem.eql(u8, name, "EvalError")) return .{ .name = "EvalError", .message = "" };
    if (std.mem.eql(u8, name, "URIError") or std.mem.eql(u8, name, "InvalidUtf8")) return .{ .name = "URIError", .message = "" };
    return .{ .name = "Error", .message = name };
}

fn externalHostError(err: anyerror) HostError {
    return switch (err) {
        error.AccessorWithoutSetter => error.AccessorWithoutSetter,
        error.AmbiguousExport => error.AmbiguousExport,
        error.AwaitOutsideAsyncFunction => error.AwaitOutsideAsyncFunction,
        error.BigIntTooLarge => error.BigIntTooLarge,
        error.BytecodeCorrupt => error.BytecodeCorrupt,
        error.BytecodeOverflow => error.BytecodeOverflow,
        error.ClosureVarNotFound => error.ClosureVarNotFound,
        error.CodepointTooLarge => error.CodepointTooLarge,
        error.DivisionByZero => error.DivisionByZero,
        error.DuplicateClass => error.DuplicateClass,
        error.EvalError => error.EvalError,
        error.IncompatibleDescriptor => error.IncompatibleDescriptor,
        error.Interrupted => error.Interrupted,
        error.InvalidAssignmentTarget => error.InvalidAssignmentTarget,
        error.InvalidAtom => error.InvalidAtom,
        error.InvalidBytecode => error.InvalidBytecode,
        error.InvalidBuiltinRegistry => error.InvalidBuiltinRegistry,
        error.InvalidCharacter => error.InvalidCharacter,
        error.InvalidCharacterError => error.InvalidCharacterError,
        error.InvalidClassId => error.InvalidClassId,
        error.InvalidEscape => error.InvalidEscape,
        error.InvalidIdentifier => error.InvalidIdentifier,
        error.InvalidLength => error.InvalidLength,
        error.InvalidLhs => error.InvalidLhs,
        error.InvalidNumber => error.InvalidNumber,
        error.InvalidNumberLiteral => error.InvalidNumberLiteral,
        error.InvalidOpcode => error.InvalidOpcode,
        error.InvalidPattern => error.InvalidPattern,
        error.InvalidPrivateName => error.InvalidPrivateName,
        error.InvalidRadix => error.InvalidRadix,
        error.InvalidRegExp => error.InvalidRegExp,
        error.InvalidUnicodeEscape => error.InvalidUnicodeEscape,
        error.InvalidUtf8 => error.InvalidUtf8,
        error.LegacyOctalInStrictMode => error.LegacyOctalInStrictMode,
        error.MissingExport => error.MissingExport,
        error.ModuleLinkFailed => error.ModuleLinkFailed,
        error.ModuleNotFound => error.ModuleNotFound,
        error.NegativeExponent => error.NegativeExponent,
        error.NotExtensible => error.NotExtensible,
        error.NotRegExpLiteral => error.NotRegExpLiteral,
        error.OutOfMemory => error.OutOfMemory,
        error.Overflow => error.Overflow,
        error.Pc2LineOverflow => error.Pc2LineOverflow,
        error.Pc2LineTruncated => error.Pc2LineTruncated,
        error.ProcessExit => error.ProcessExit,
        error.PrototypeCycle => error.PrototypeCycle,
        error.RangeError => error.RangeError,
        error.ReadOnly => error.ReadOnly,
        error.ReferenceError => error.ReferenceError,
        error.StackMismatch => error.StackMismatch,
        error.StackOverflow => error.StackOverflow,
        error.StackUnderflow => error.StackUnderflow,
        error.SyntaxError => error.SyntaxError,
        error.SystemError => error.SystemError,
        error.JSException => error.JSException,
        error.Timeout => error.Timeout,
        error.TooManyJobArgs => error.TooManyJobArgs,
        error.TypeError => error.TypeError,
        error.URIError => error.URIError,
        error.UnhandledPromiseRejection => error.UnhandledPromiseRejection,
        error.UnterminatedComment => error.UnterminatedComment,
        error.UnterminatedRegExp => error.UnterminatedRegExp,
        error.UnterminatedString => error.UnterminatedString,
        error.UnterminatedTemplate => error.UnterminatedTemplate,
        error.UnexpectedEof => error.UnexpectedEof,
        error.UnexpectedToken => error.UnexpectedToken,
        error.UnsupportedSimpleJson => error.UnsupportedSimpleJson,
        error.Utf8CannotEncodeSurrogateHalf => error.Utf8CannotEncodeSurrogateHalf,
        error.Utf8EncodesSurrogateHalf => error.Utf8EncodesSurrogateHalf,
        error.YieldOutsideGenerator => error.YieldOutsideGenerator,
        error.HtmlCommentInModule => error.HtmlCommentInModule,
        error.AccessDenied => error.AccessDenied,
        error.AntivirusInterference => error.AntivirusInterference,
        error.BadPathName => error.BadPathName,
        error.BrokenPipe => error.BrokenPipe,
        error.Canceled => error.Canceled,
        error.ConnectionRefused => error.ConnectionRefused,
        error.ConnectionResetByPeer => error.ConnectionResetByPeer,
        error.CurrentDirUnlinked => error.CurrentDirUnlinked,
        error.DeviceBusy => error.DeviceBusy,
        error.DiskQuota => error.DiskQuota,
        error.FileBusy => error.FileBusy,
        error.FileNotFound => error.FileNotFound,
        error.FileLocksUnsupported => error.FileLocksUnsupported,
        error.FileSystem => error.FileSystem,
        error.FileTooBig => error.FileTooBig,
        error.InputOutput => error.InputOutput,
        error.InvalidHandle => error.InvalidHandle,
        error.InvalidName => error.InvalidName,
        error.InvalidPath => error.InvalidPath,
        error.InvalidWtf8 => error.InvalidWtf8,
        error.IsDir => error.IsDir,
        error.LockViolation => error.LockViolation,
        error.LockedMemoryLimitExceeded => error.LockedMemoryLimitExceeded,
        error.NameTooLong => error.NameTooLong,
        error.NetworkNotFound => error.NetworkNotFound,
        error.NoDevice => error.NoDevice,
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.NotDir => error.NotDir,
        error.NotOpenForReading => error.NotOpenForReading,
        error.NotOpenForWriting => error.NotOpenForWriting,
        error.OperationUnsupported => error.OperationUnsupported,
        error.PathAlreadyExists => error.PathAlreadyExists,
        error.PermissionDenied => error.PermissionDenied,
        error.PipeBusy => error.PipeBusy,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.ProcessNotFound => error.ProcessNotFound,
        error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
        error.SharingViolation => error.SharingViolation,
        error.SocketNotConnected => error.SocketNotConnected,
        error.SocketUnconnected => error.SocketUnconnected,
        error.StreamTooLong => error.StreamTooLong,
        error.SymLinkLoop => error.SymLinkLoop,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        error.SystemResources => error.SystemResources,
        error.ThreadQuotaExceeded => error.ThreadQuotaExceeded,
        error.Unexpected => error.Unexpected,
        error.WouldBlock => error.WouldBlock,
        error.WriteFailed => error.WriteFailed,
        else => error.TypeError,
    };
}

pub fn callHostFunctionObjectForVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    const kind = object.hostFunctionKindSlot().*;
    if (kind == 0) return null;
    if (!hostFunctionCanDispatchFromVmWithoutGlobals(kind)) return null;
    const record = hostFunctionRecordFromId(kind) orelse return error.TypeError;
    return try callHostFunction(ctx, output, global, &.{}, object, this_value, args, record, .{});
}

fn hostFunctionCanDispatchFromVmWithoutGlobals(kind: i32) bool {
    return switch (kind) {
        @intFromEnum(HostFunction.output),
        @intFromEnum(HostFunction.dstr_get)...@intFromEnum(HostFunction.dstr_elide),
        @intFromEnum(HostFunction.dstr_require_iterator),
        @intFromEnum(HostFunction.using_create_disposable_stack)...@intFromEnum(HostFunction.using_dispose_async_stack_for_throw),
        @intFromEnum(HostFunction.external_host),
        => true,
        else => false,
    };
}

fn definePredefinedExternalHostFunction(
    rt: *core.JSRuntime,
    target: *core.Object,
    comptime name: []const u8,
    length: i32,
    external_id: u32,
) !void {
    try target.defineHostAutoInitPropertyWithExternalId(
        rt,
        predefinedStringAtom(name),
        name,
        length,
        core.property.Flags.data(true, true, true),
        core.host_function.ids.external_host,
        false,
        null,
        external_id,
    );
}

fn predefinedStringAtom(comptime name: []const u8) core.Atom {
    return comptime core.atom.predefinedId(name, .string).?;
}

fn createHostFunction(rt: *core.JSRuntime, kind: HostFunction) !*core.Object {
    const function_object = try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.c_function, null, 0);
    errdefer function_object.value().free(rt);
    function_object.hostFunctionKindSlot().* = @intFromEnum(kind);
    return function_object;
}

pub fn internalDestructuringHelperFunction(rt: *core.JSRuntime, subtype: u8) !?core.JSValue {
    const helper = internalDestructuringHelperForSubtype(subtype) orelse return null;
    if (rt.internal_destructuring_helpers[helper.slot]) |cached| return cached.dup();
    const function_object = try createHostFunction(rt, helper.kind);
    const value = function_object.value();
    rt.internal_destructuring_helpers[helper.slot] = value;
    return value.dup();
}

fn internalDestructuringHelperForSubtype(subtype: u8) ?struct { slot: usize, kind: HostFunction } {
    const special = bytecode_opcode.special_object_subtype;
    return switch (subtype) {
        special.dstr_get => .{ .slot = 0, .kind = .dstr_get },
        special.dstr_elide => .{ .slot = 1, .kind = .dstr_elide },
        special.dstr_rest => .{ .slot = 2, .kind = .dstr_rest },
        special.dstr_obj_rest => .{ .slot = 3, .kind = .dstr_obj_rest },
        special.dstr_close => .{ .slot = 4, .kind = .dstr_close },
        special.dstr_require_iterator => .{ .slot = 5, .kind = .dstr_require_iterator },
        special.using_create_disposable_stack => .{ .slot = 6, .kind = .using_create_disposable_stack },
        special.using_add_sync_resource => .{ .slot = 7, .kind = .using_add_sync_resource },
        special.using_dispose_sync_stack => .{ .slot = 8, .kind = .using_dispose_sync_stack },
        special.using_dispose_sync_stack_for_throw => .{ .slot = 9, .kind = .using_dispose_sync_stack_for_throw },
        special.using_create_async_disposable_stack => .{ .slot = 10, .kind = .using_create_async_disposable_stack },
        special.using_add_async_resource => .{ .slot = 11, .kind = .using_add_async_resource },
        special.using_dispose_async_stack => .{ .slot = 12, .kind = .using_dispose_async_stack },
        special.using_dispose_async_stack_for_throw => .{ .slot = 13, .kind = .using_dispose_async_stack_for_throw },
        else => null,
    };
}

pub fn defineObjectProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, true, true, true));
}

fn defineGlobalThisProperty(rt: *core.JSRuntime, global: *core.Object) !void {
    try global.defineOwnPropertyAssumingNew(rt, core.atom.predefinedId("globalThis", .string).?, core.Descriptor.data(global.value(), true, false, true));
}

pub fn defineIntProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: i32) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(value), true, true, true));
}

fn defineConstantProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, false, false, false));
}

fn defineConstantPropertyAssumingNew(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnPropertyAssumingNew(rt, key, core.Descriptor.data(value, false, false, false));
}

fn defineNumberConstantProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: f64) !void {
    try defineConstantProperty(rt, object, name, value_ops.numberToValue(value));
}

fn defineNumberConstantPropertyAssumingNew(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: f64) !void {
    const key = core.atom.predefinedId(name, .string) orelse {
        try defineConstantPropertyAssumingNew(rt, object, name, value_ops.numberToValue(value));
        return;
    };
    try object.defineOwnPropertyAssumingNew(rt, key, core.Descriptor.data(value_ops.numberToValue(value), false, false, false));
}

fn hostFunctionLength(kind: HostFunction) i32 {
    return hostFunctionRecord(kind).length;
}

fn promiseObjectFromValue(value: core.JSValue) ?*core.Object {
    const object = thisObject(value) orelse return null;
    if (object.class_id != core.class.ids.promise) return null;
    return object;
}

pub fn expectCallableObject(value: core.JSValue) ?*core.Object {
    const header = value.refHeader() orelse return null;
    if (!value.isObject()) return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.c_function and
        object.class_id != core.class.ids.bytecode_function and
        object.class_id != core.class.ids.c_closure and
        object.class_id != core.class.ids.bound_function) return null;
    return object;
}

fn promiseResolvingFunctionCall(rt: *core.JSRuntime, function_object: *core.Object, args: []const core.JSValue) !?core.JSValue {
    const target_value = function_object.functionPromiseResolvingTarget() orelse return null;
    const target = thisObject(target_value) orelse return core.JSValue.undefinedValue();
    if (target.class_id != core.class.ids.promise) return core.JSValue.undefinedValue();
    if (target.promiseResult() != null) return core.JSValue.undefinedValue();
    const reject = function_object.functionPromiseResolvingReject();
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    try target.setPromiseResult(rt, value.dup());
    target.promiseIsRejectedSlot().* = reject;
    return core.JSValue.undefinedValue();
}

fn promiseCapabilityExecutorCall(rt: *core.JSRuntime, function_object: *core.Object, args: []const core.JSValue) !?core.JSValue {
    const slot_value = function_object.functionPromiseCapabilitySlot() orelse return null;
    const slot = thisObject(slot_value) orelse return error.TypeError;
    const current_resolve = slot.promiseCapabilityResolve();
    const current_reject = slot.promiseCapabilityReject();
    if ((current_resolve != null and !current_resolve.?.isUndefined()) or
        (current_reject != null and !current_reject.?.isUndefined()))
    {
        return error.TypeError;
    }
    const resolve = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const reject = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    try slot.setPromiseCapability(rt, resolve.dup(), reject.dup());
    return core.JSValue.undefinedValue();
}

const PromiseCombinatorCallbackMode = enum(u8) {
    all_resolve = 1,
    all_settled_fulfill = 2,
    all_settled_reject = 3,
    any_reject = 4,
};

fn promiseCombinatorElementCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    function_object: *core.Object,
    args: []const core.JSValue,
) HostError!?core.JSValue {
    const mode: PromiseCombinatorCallbackMode = switch (function_object.functionPromiseCombinatorMode()) {
        0 => return null,
        @intFromEnum(PromiseCombinatorCallbackMode.all_resolve) => .all_resolve,
        @intFromEnum(PromiseCombinatorCallbackMode.all_settled_fulfill) => .all_settled_fulfill,
        @intFromEnum(PromiseCombinatorCallbackMode.all_settled_reject) => .all_settled_reject,
        @intFromEnum(PromiseCombinatorCallbackMode.any_reject) => .any_reject,
        else => return error.TypeError,
    };
    if (function_object.functionPromiseCombinatorCalled()) return core.JSValue.undefinedValue();
    (try function_object.functionPromiseCombinatorCalledSlot(ctx.runtime)).* = true;

    const state_value = function_object.functionPromiseCombinatorState() orelse return error.TypeError;
    const state = thisObject(state_value) orelse return error.TypeError;
    const values_value = state.promiseCombinatorValues() orelse return error.TypeError;
    const values = thisObject(values_value) orelse return error.TypeError;
    const index = function_object.functionPromiseCombinatorIndex();
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();

    switch (mode) {
        .all_resolve => try setArrayIndex(ctx.runtime, values, index, value),
        .all_settled_fulfill, .all_settled_reject => {
            const record = try createPromiseSettlementRecord(ctx.runtime, mode == .all_settled_reject, value);
            defer record.free(ctx.runtime);
            try setArrayIndex(ctx.runtime, values, index, record);
        },
        .any_reject => try setArrayIndex(ctx.runtime, values, index, value),
    }

    const remaining = state.promiseCombinatorRemaining();
    const next_remaining = remaining - 1;
    (try state.promiseCombinatorRemainingSlot(ctx.runtime)).* = next_remaining;
    if (next_remaining != 0) return core.JSValue.undefinedValue();

    const resolve_value = state.promiseCombinatorResolve() orelse return error.TypeError;
    const reject_value = state.promiseCombinatorReject() orelse return error.TypeError;
    switch (mode) {
        .all_resolve, .all_settled_fulfill, .all_settled_reject => {
            const result = try callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, core.JSValue.undefinedValue(), resolve_value, &.{values_value});
            result.free(ctx.runtime);
        },
        .any_reject => {
            const aggregate_error = try createPromiseAggregateError(ctx.runtime, try activeGlobalObject(ctx.runtime, global, globals), values);
            defer aggregate_error.free(ctx.runtime);
            const result = try callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, core.JSValue.undefinedValue(), reject_value, &.{aggregate_error});
            result.free(ctx.runtime);
        },
    }
    return core.JSValue.undefinedValue();
}

const PromiseCapability = struct {
    promise: core.JSValue,
    resolve: core.JSValue,
    reject: core.JSValue,

    fn deinit(self: PromiseCapability, rt: *core.JSRuntime) void {
        self.promise.free(rt);
        self.resolve.free(rt);
        self.reject.free(rt);
    }

    fn releaseCallbacks(self: PromiseCapability, rt: *core.JSRuntime) core.JSValue {
        self.resolve.free(rt);
        self.reject.free(rt);
        return self.promise;
    }
};

const PromiseIterator = struct {
    iterator: core.JSValue,
    next_method: core.JSValue,
    done: bool = false,

    fn deinit(self: PromiseIterator, rt: *core.JSRuntime) void {
        self.iterator.free(rt);
        self.next_method.free(rt);
    }
};

const PromiseCombinatorMode = enum {
    all,
    race,
    all_settled,
    any,
};

pub fn activeGlobalObject(rt: *core.JSRuntime, global: ?*core.Object, globals: []globals_mod.Slot) !?*core.Object {
    if (global) |global_object| return global_object;
    const global_value = try globals_mod.getByName(rt, globals, "globalThis");
    defer global_value.free(rt);
    return thisObject(global_value);
}

pub fn functionPrototypeFromGlobal(rt: *core.JSRuntime, global: ?*core.Object) ?*core.Object {
    const global_object = global orelse return null;
    const ctor_key = rt.internAtom("Function") catch return null;
    defer rt.atoms.free(ctor_key);
    const ctor_value = global_object.getProperty(ctor_key);
    defer ctor_value.free(rt);
    const ctor_object = thisObject(ctor_value) orelse return null;
    return constructorPrototype(rt, ctor_object);
}

fn createPromiseBuiltinFunction(rt: *core.JSRuntime, global: ?*core.Object, name: []const u8, length: i32) !core.JSValue {
    const function = try core.function.nativeFunction(rt, name, length);
    errdefer function.free(rt);
    const function_object = thisObject(function) orelse return error.TypeError;
    if (global) |global_object| {
        try function_object.setFunctionRealmGlobalPtr(rt, global_object);
        if (functionPrototypeFromGlobal(rt, global_object)) |function_proto| {
            function_object.setPrototype(rt, function_proto) catch {};
        }
    }
    return function;
}

fn createPromiseCapability(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    constructor_value: core.JSValue,
    constructor_object: *core.Object,
) !PromiseCapability {
    var promise_val = core.JSValue.undefinedValue();
    var resolve_val = core.JSValue.undefinedValue();
    var reject_val = core.JSValue.undefinedValue();
    var capability_slot_val = core.JSValue.undefinedValue();
    var executor_val = core.JSValue.undefinedValue();

    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &promise_val },
        .{ .value = &resolve_val },
        .{ .value = &reject_val },
        .{ .value = &capability_slot_val },
        .{ .value = &executor_val },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    defer promise_val.free(ctx.runtime);
    defer resolve_val.free(ctx.runtime);
    defer reject_val.free(ctx.runtime);
    defer capability_slot_val.free(ctx.runtime);
    defer executor_val.free(ctx.runtime);

    if (try constructorNameEql(ctx.runtime, constructor_object, "Promise")) {
        const active_global = try activeGlobalObject(ctx.runtime, global, globals);
        promise_val = try core.promise.constructWithPrototype(ctx.runtime, constructorPrototype(ctx.runtime, constructor_object));
        resolve_val = try createPromiseBuiltinFunction(ctx.runtime, active_global, "", 1);
        reject_val = try createPromiseBuiltinFunction(ctx.runtime, active_global, "", 1);
        const resolve_object = thisObject(resolve_val) orelse return error.TypeError;
        const reject_object = thisObject(reject_val) orelse return error.TypeError;
        try resolve_object.setInternalCallableTag(ctx.runtime, .promise_resolving);
        try resolve_object.setFunctionPromiseResolvingTarget(ctx.runtime, promise_val.dup());
        (try resolve_object.functionPromiseResolvingRejectSlot(ctx.runtime)).* = false;
        try reject_object.setInternalCallableTag(ctx.runtime, .promise_resolving);
        try reject_object.setFunctionPromiseResolvingTarget(ctx.runtime, promise_val.dup());
        (try reject_object.functionPromiseResolvingRejectSlot(ctx.runtime)).* = true;
        return .{
            .promise = promise_val.dup(),
            .resolve = resolve_val.dup(),
            .reject = reject_val.dup(),
        };
    }

    const active_global = try activeGlobalObject(ctx.runtime, global, globals);
    const capability_slot = try core.Object.create(ctx.runtime, core.class.ids.object, null);
    capability_slot_val = capability_slot.value();

    executor_val = try createPromiseBuiltinFunction(ctx.runtime, active_global, "", 2);
    const executor_object = thisObject(executor_val) orelse return error.TypeError;
    try executor_object.setInternalCallableTag(ctx.runtime, .promise_capability_executor);
    try executor_object.setFunctionPromiseCapabilitySlot(ctx.runtime, capability_slot_val.dup());

    const instance = try core.Object.create(ctx.runtime, core.class.ids.object, constructorPrototype(ctx.runtime, constructor_object));
    promise_val = instance.value();

    const call_result = try callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, promise_val, constructor_value, &.{executor_val});
    defer call_result.free(ctx.runtime);
    if (call_result.isObject()) {
        const next_promise_val = call_result.dup();
        promise_val.free(ctx.runtime);
        promise_val = next_promise_val;
    }

    resolve_val = if (capability_slot.promiseCapabilityResolve()) |stored| stored.dup() else core.JSValue.undefinedValue();
    reject_val = if (capability_slot.promiseCapabilityReject()) |stored| stored.dup() else core.JSValue.undefinedValue();
    if (!isCallableObjectValue(resolve_val) or !isCallableObjectValue(reject_val)) return error.TypeError;
    return .{
        .promise = promise_val.dup(),
        .resolve = resolve_val.dup(),
        .reject = reject_val.dup(),
    };
}

test "createPromiseCapability roots builtin promise capability under GC" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);

    const constructor_value = try core.function.nativeFunction(rt, "Promise", 1);
    var constructor_alive = true;
    defer if (constructor_alive) constructor_value.free(rt);
    const constructor = thisObject(constructor_value) orelse return error.TypeError;

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const capability = try createPromiseCapability(ctx, null, global, &.{}, constructor_value, constructor);
    defer capability.deinit(rt);

    const promise = promiseObjectFromValue(capability.promise) orelse return error.TypeError;
    const resolve_object = thisObject(capability.resolve) orelse return error.TypeError;
    const reject_object = thisObject(capability.reject) orelse return error.TypeError;
    try std.testing.expect(resolve_object.functionPromiseResolvingTarget().?.same(promise.value()));
    try std.testing.expect(reject_object.functionPromiseResolvingTarget().?.same(promise.value()));
    try std.testing.expect(!resolve_object.functionPromiseResolvingReject());
    try std.testing.expect(reject_object.functionPromiseResolvingReject());

    constructor_value.free(rt);
    constructor_alive = false;
    _ = rt.runObjectCycleRemoval();
}

pub fn getValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    receiver: core.JSValue,
    key: core.Atom,
) !core.JSValue {
    const receiver_value = try objectStaticToObjectValue(ctx, global, receiver);
    defer receiver_value.free(ctx.runtime);
    const object = try expectObjectArg(receiver_value);
    var cursor: ?*core.Object = object;
    while (cursor) |current| : (cursor = current.getPrototype()) {
        const desc = current.getOwnProperty(ctx.runtime, key) orelse continue;
        defer desc.destroy(ctx.runtime);
        return switch (desc.kind) {
            .data => desc.value.dup(),
            .generic => core.JSValue.undefinedValue(),
            .accessor => if (desc.getter.isUndefined())
                core.JSValue.undefinedValue()
            else blk: {
                if (try activeGlobalObject(ctx.runtime, global, globals)) |active_global| {
                    break :blk try call_runtime.callValueOrBytecode(ctx, output, active_global, receiver_value, desc.getter, &.{}, null, null);
                }
                break :blk try callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, receiver_value, desc.getter, &.{});
            },
        };
    }
    return core.JSValue.undefinedValue();
}

fn getValuePropertyProxyAware(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    receiver: core.JSValue,
    key: core.Atom,
) !core.JSValue {
    if (try activeGlobalObject(ctx.runtime, global, globals)) |global_object| {
        return object_ops.getValueProperty(ctx, output, global_object, receiver, key, null, null);
    }
    return getValueProperty(ctx, output, global, globals, receiver, key);
}

fn hasOwnPropertyProxyAware(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    object: *core.Object,
    key: core.Atom,
) !bool {
    if (try activeGlobalObject(ctx.runtime, global, globals)) |global_object| {
        const desc = try object_ops.proxyAwareOwnPropertyDescriptor(ctx, output, global_object, object, key, null, null);
        if (desc) |own_desc| {
            own_desc.destroy(ctx.runtime);
            return true;
        }
        return false;
    }
    return object.hasOwnProperty(key);
}

fn getPromiseIterator(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    iterable: core.JSValue,
) !PromiseIterator {
    if (iterable.isString()) {
        const iterator = try core.object.stringIterator(ctx.runtime, iterable);
        errdefer iterator.free(ctx.runtime);
        const next_key = try ctx.runtime.internAtom("next");
        defer ctx.runtime.atoms.free(next_key);
        const next_method = try getValueProperty(ctx, output, global, globals, iterator, next_key);
        errdefer next_method.free(ctx.runtime);
        if (!isCallableObjectValue(next_method)) return error.TypeError;
        return .{ .iterator = iterator, .next_method = next_method };
    }
    if (thisObject(iterable)) |iterable_object| {
        if (iterable_object.class_id == core.class.ids.string) {
            const iterator = try core.object.stringIterator(ctx.runtime, iterable);
            errdefer iterator.free(ctx.runtime);
            const next_key = try ctx.runtime.internAtom("next");
            defer ctx.runtime.atoms.free(next_key);
            const next_method = try getValueProperty(ctx, output, global, globals, iterator, next_key);
            errdefer next_method.free(ctx.runtime);
            if (!isCallableObjectValue(next_method)) return error.TypeError;
            return .{ .iterator = iterator, .next_method = next_method };
        }
    }

    const iterator_key = core.atom.predefinedId("Symbol.iterator", .symbol) orelse return error.TypeError;
    const iterator_method = try getValueProperty(ctx, output, global, globals, iterable, iterator_key);
    defer iterator_method.free(ctx.runtime);
    if (!isCallableObjectValue(iterator_method)) return error.TypeError;
    const iterator = try callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, iterable, iterator_method, &.{});
    errdefer iterator.free(ctx.runtime);
    _ = try expectObjectArg(iterator);
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try getValueProperty(ctx, output, global, globals, iterator, next_key);
    errdefer next_method.free(ctx.runtime);
    if (!isCallableObjectValue(next_method)) return error.TypeError;
    return .{ .iterator = iterator, .next_method = next_method };
}

fn promiseIteratorStepValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    iterator: *PromiseIterator,
) !?core.JSValue {
    const next_result = callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, iterator.iterator, iterator.next_method, &.{}) catch |err| {
        iterator.done = true;
        return err;
    };
    errdefer next_result.free(ctx.runtime);
    const next_object = expectObjectArg(next_result) catch {
        iterator.done = true;
        return error.TypeError;
    };
    const done_key = core.atom.predefinedId("done", .string) orelse return error.TypeError;
    const done_value = getValueProperty(ctx, output, global, globals, next_result, done_key) catch |err| {
        iterator.done = true;
        return err;
    };
    defer done_value.free(ctx.runtime);
    if (value_ops.isTruthy(done_value)) {
        iterator.done = true;
        next_result.free(ctx.runtime);
        return null;
    }
    _ = next_object;
    const value_key = core.atom.predefinedId("value", .string) orelse return error.TypeError;
    const value = getValueProperty(ctx, output, global, globals, next_result, value_key) catch |err| {
        iterator.done = true;
        return err;
    };
    next_result.free(ctx.runtime);
    return value;
}

fn promiseIteratorClose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    iterator: core.JSValue,
) !void {
    const return_key = try ctx.runtime.internAtom("return");
    defer ctx.runtime.atoms.free(return_key);
    const return_method = try getValueProperty(ctx, output, global, globals, iterator, return_key);
    defer return_method.free(ctx.runtime);
    if (return_method.isUndefined() or return_method.isNull()) return;
    if (!isCallableObjectValue(return_method)) return error.TypeError;
    const result = try callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, iterator, return_method, &.{});
    result.free(ctx.runtime);
}

fn promiseErrorValue(ctx: *core.JSContext, global: ?*core.Object, err: anytype) !core.JSValue {
    if (ctx.hasException()) return ctx.takeException();
    const name = runtimeErrorName(err);
    if (global) |global_object| {
        const ctor_key = try ctx.runtime.internAtom(name);
        defer ctx.runtime.atoms.free(ctor_key);
        const ctor_value = global_object.getProperty(ctor_key);
        defer ctor_value.free(ctx.runtime);
        const ctor_object = thisObject(ctor_value) orelse return constructSimpleError(ctx.runtime, null, name, "");
        return construct_mod.constructErrorObject(ctx.runtime, name, ctor_object.value(), constructorPrototype(ctx.runtime, ctor_object), &.{});
    }
    return constructSimpleError(ctx.runtime, null, name, "");
}

fn constructSimpleError(rt: *core.JSRuntime, prototype: ?*core.Object, name: []const u8, message: []const u8) !core.JSValue {
    const instance = try core.Object.create(rt, core.class.ids.error_, prototype);
    errdefer core.Object.destroyFromHeader(rt, &instance.header);
    const name_value = try value_ops.createStringValue(rt, name);
    defer name_value.free(rt);
    const message_value = try value_ops.createStringValue(rt, message);
    defer message_value.free(rt);
    try defineObjectProperty(rt, instance, "name", name_value);
    if (message.len != 0) try defineObjectProperty(rt, instance, "message", message_value);
    return instance.value();
}

fn rejectPromiseCapability(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    reject_value: core.JSValue,
    reason: core.JSValue,
) !void {
    const result = try callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, core.JSValue.undefinedValue(), reject_value, &.{reason});
    result.free(ctx.runtime);
}

fn setArrayIndex(rt: *core.JSRuntime, array: *core.Object, index: u32, value: core.JSValue) !void {
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(index), core.Descriptor.data(value, true, true, true));
    if (array.arrayLength() <= index) array.setArrayLength(index + 1);
}

fn createPromiseSettlementRecord(rt: *core.JSRuntime, rejected: bool, payload: core.JSValue) !core.JSValue {
    var rooted_payload = payload;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_payload },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const record = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &record.header);
    const status = try value_ops.createStringValue(rt, if (rejected) "rejected" else "fulfilled");
    defer status.free(rt);
    try defineObjectProperty(rt, record, "status", status);
    try defineObjectProperty(rt, record, if (rejected) "reason" else "value", rooted_payload);
    return record.value();
}

test "createPromiseSettlementRecord roots direct symbol payload while defining status" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-call-promise-settlement-record-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const payload_value = try rt.symbolValue(symbol_atom);
    const record_value = try createPromiseSettlementRecord(rt, false, payload_value);
    var record_alive = true;
    defer if (record_alive) record_value.free(rt);
    const record = thisObject(record_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_atom = try rt.internAtom("value");
    defer rt.atoms.free(value_atom);
    {
        const value = record.getProperty(value_atom);
        defer value.free(rt);
        try std.testing.expect(value.same(payload_value));
    }

    record_value.free(rt);
    record_alive = false;
    payload_value.free(rt);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn createPromiseAggregateError(rt: *core.JSRuntime, global: ?*core.Object, errors: *core.Object) !core.JSValue {
    var prototype: ?*core.Object = null;
    if (global) |global_object| {
        const ctor_key = try rt.internAtom("AggregateError");
        defer rt.atoms.free(ctor_key);
        const ctor_value = global_object.getProperty(ctor_key);
        defer ctor_value.free(rt);
        if (thisObject(ctor_value)) |ctor_object| {
            prototype = constructorPrototype(rt, ctor_object);
        }
    }
    const instance = try core.Object.create(rt, core.class.ids.error_, prototype);
    errdefer core.Object.destroyFromHeader(rt, &instance.header);
    const name_value = try value_ops.createStringValue(rt, "AggregateError");
    defer name_value.free(rt);
    try defineObjectProperty(rt, instance, "name", name_value);
    try defineObjectProperty(rt, instance, "errors", errors.value());
    return instance.value();
}

fn createPromiseCombinatorState(
    rt: *core.JSRuntime,
    resolve_value: core.JSValue,
    reject_value: core.JSValue,
    values: *core.Object,
) !*core.Object {
    var rooted_resolve = resolve_value;
    var rooted_reject = reject_value;
    var rooted_values = values.value();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_resolve },
        .{ .value = &rooted_reject },
        .{ .value = &rooted_values },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const state = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &state.header);
    try state.setPromiseCombinatorResolve(rt, rooted_resolve.dup());
    try state.setPromiseCombinatorReject(rt, rooted_reject.dup());
    try state.setPromiseCombinatorValues(rt, rooted_values.dup());
    (try state.promiseCombinatorRemainingSlot(rt)).* = 1;
    return state;
}

test "createPromiseCombinatorState roots direct function bytecode resolve while creating state" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const values = try core.Object.create(rt, core.class.ids.array, null);
    defer values.value().free(rt);

    const fb_slice = try rt.memory.alloc(function_bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = function_bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-promise-combinator-state-resolve-bytecode-symbol");
    fb.cpool[0] = try rt.symbolValue(symbol_atom);
    fb.cpool_count = 1;

    var resolve_value = core.JSValue.functionBytecode(&fb.header);
    var resolve_alive = true;
    defer if (resolve_alive) resolve_value.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const state = try createPromiseCombinatorState(rt, resolve_value, core.JSValue.undefinedValue(), values);
    var state_alive = true;
    defer if (state_alive) core.Object.destroyFromHeader(rt, &state.header);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = state.promiseCombinatorResolve() orelse return error.TypeError;
    try std.testing.expect(stored.same(resolve_value));

    core.Object.destroyFromHeader(rt, &state.header);
    state_alive = false;
    resolve_value.free(rt);
    resolve_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn createPromiseCombinatorCallback(
    rt: *core.JSRuntime,
    global: ?*core.Object,
    mode: PromiseCombinatorCallbackMode,
    state: *core.Object,
    index: u32,
) !core.JSValue {
    const callback = try createPromiseBuiltinFunction(rt, global, "", 1);
    errdefer callback.free(rt);
    const callback_object = thisObject(callback) orelse return error.TypeError;
    try callback_object.setInternalCallableTag(rt, .promise_combinator_element);
    (try callback_object.functionPromiseCombinatorModeSlot(rt)).* = @intFromEnum(mode);
    try callback_object.setFunctionPromiseCombinatorState(rt, state.value().dup());
    (try callback_object.functionPromiseCombinatorIndexSlot(rt)).* = index;
    (try callback_object.functionPromiseCombinatorCalledSlot(rt)).* = false;
    return callback;
}

fn promiseCombinatorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    constructor_value: core.JSValue,
    constructor_object: *core.Object,
    args: []const core.JSValue,
    mode: PromiseCombinatorMode,
) !core.JSValue {
    var capability = try createPromiseCapability(ctx, output, global, globals, constructor_value, constructor_object);
    errdefer capability.deinit(ctx.runtime);

    const active_global = try activeGlobalObject(ctx.runtime, global, globals);
    const resolve_key = try ctx.runtime.internAtom("resolve");
    defer ctx.runtime.atoms.free(resolve_key);
    const promise_resolve = try getValueProperty(ctx, output, global, globals, constructor_value, resolve_key);
    defer promise_resolve.free(ctx.runtime);
    if (!isCallableObjectValue(promise_resolve)) {
        const reason = try promiseErrorValue(ctx, active_global, error.TypeError);
        defer reason.free(ctx.runtime);
        try rejectPromiseCapability(ctx, output, global, globals, capability.reject, reason);
        return capability.releaseCallbacks(ctx.runtime);
    }

    const iterable = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    var iterator = getPromiseIterator(ctx, output, global, globals, iterable) catch |err| {
        const reason = try promiseErrorValue(ctx, active_global, err);
        defer reason.free(ctx.runtime);
        try rejectPromiseCapability(ctx, output, global, globals, capability.reject, reason);
        return capability.releaseCallbacks(ctx.runtime);
    };
    defer iterator.deinit(ctx.runtime);

    const values = if (mode != .race) try core.Object.createArray(ctx.runtime, null) else null;
    const values_value = if (values) |array| array.value() else null;
    defer if (values_value) |value| value.free(ctx.runtime);
    const state = if (values) |array| try createPromiseCombinatorState(ctx.runtime, capability.resolve, capability.reject, array) else null;
    const state_value = if (state) |state_object| state_object.value() else null;
    defer if (state_value) |value| value.free(ctx.runtime);

    var index: u32 = 0;
    while (true) {
        const next_value = promiseIteratorStepValue(ctx, output, global, globals, &iterator) catch |err| {
            const reason = try promiseErrorValue(ctx, active_global, err);
            defer reason.free(ctx.runtime);
            try rejectPromiseCapability(ctx, output, global, globals, capability.reject, reason);
            return capability.releaseCallbacks(ctx.runtime);
        };
        if (next_value == null) break;
        defer next_value.?.free(ctx.runtime);

        if (state) |state_object| {
            const remaining = state_object.promiseCombinatorRemaining();
            (try state_object.promiseCombinatorRemainingSlot(ctx.runtime)).* = remaining + 1;
            const array_object = values.?;
            try setArrayIndex(ctx.runtime, array_object, index, core.JSValue.undefinedValue());
        }

        const next_promise = callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, constructor_value, promise_resolve, &.{next_value.?}) catch |err| {
            if (!iterator.done) {
                promiseIteratorClose(ctx, output, global, globals, iterator.iterator) catch {};
            }
            const reason = try promiseErrorValue(ctx, active_global, err);
            defer reason.free(ctx.runtime);
            try rejectPromiseCapability(ctx, output, global, globals, capability.reject, reason);
            return capability.releaseCallbacks(ctx.runtime);
        };
        defer next_promise.free(ctx.runtime);

        const then_key = try ctx.runtime.internAtom("then");
        defer ctx.runtime.atoms.free(then_key);
        const then_value = getValueProperty(ctx, output, global, globals, next_promise, then_key) catch |err| {
            if (!iterator.done) {
                promiseIteratorClose(ctx, output, global, globals, iterator.iterator) catch {};
            }
            const reason = try promiseErrorValue(ctx, active_global, err);
            defer reason.free(ctx.runtime);
            try rejectPromiseCapability(ctx, output, global, globals, capability.reject, reason);
            return capability.releaseCallbacks(ctx.runtime);
        };
        defer then_value.free(ctx.runtime);
        if (!isCallableObjectValue(then_value)) {
            if (!iterator.done) {
                promiseIteratorClose(ctx, output, global, globals, iterator.iterator) catch {};
            }
            const reason = try promiseErrorValue(ctx, active_global, error.TypeError);
            defer reason.free(ctx.runtime);
            try rejectPromiseCapability(ctx, output, global, globals, capability.reject, reason);
            return capability.releaseCallbacks(ctx.runtime);
        }

        const on_fulfilled = switch (mode) {
            .all => try createPromiseCombinatorCallback(ctx.runtime, active_global, .all_resolve, state.?, index),
            .all_settled => try createPromiseCombinatorCallback(ctx.runtime, active_global, .all_settled_fulfill, state.?, index),
            .any => capability.resolve.dup(),
            .race => capability.resolve.dup(),
        };
        defer on_fulfilled.free(ctx.runtime);
        const on_rejected = switch (mode) {
            .all => capability.reject.dup(),
            .all_settled => try createPromiseCombinatorCallback(ctx.runtime, active_global, .all_settled_reject, state.?, index),
            .any => try createPromiseCombinatorCallback(ctx.runtime, active_global, .any_reject, state.?, index),
            .race => capability.reject.dup(),
        };
        defer on_rejected.free(ctx.runtime);

        const then_args = [_]core.JSValue{ on_fulfilled, on_rejected };
        const then_result = callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, next_promise, then_value, &then_args) catch |err| {
            if (!iterator.done) {
                promiseIteratorClose(ctx, output, global, globals, iterator.iterator) catch {};
            }
            const reason = try promiseErrorValue(ctx, active_global, err);
            defer reason.free(ctx.runtime);
            try rejectPromiseCapability(ctx, output, global, globals, capability.reject, reason);
            return capability.releaseCallbacks(ctx.runtime);
        };
        then_result.free(ctx.runtime);
        index += 1;
    }

    if (state) |state_object| {
        const remaining = state_object.promiseCombinatorRemaining();
        const next_remaining = remaining - 1;
        (try state_object.promiseCombinatorRemainingSlot(ctx.runtime)).* = next_remaining;
        if (next_remaining == 0) {
            switch (mode) {
                .all, .all_settled => {
                    const result = try callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, core.JSValue.undefinedValue(), capability.resolve, &.{values.?.value()});
                    result.free(ctx.runtime);
                },
                .any => {
                    const aggregate_error = try createPromiseAggregateError(ctx.runtime, active_global, values.?);
                    defer aggregate_error.free(ctx.runtime);
                    const result = try callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, core.JSValue.undefinedValue(), capability.reject, &.{aggregate_error});
                    result.free(ctx.runtime);
                },
                .race => unreachable,
            }
        }
    }
    return capability.releaseCallbacks(ctx.runtime);
}

fn callNativeBuiltin(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    this_value: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
) HostError!core.JSValue {
    if (try callNativeFunctionRecord(ctx, output, global, globals, this_value, function_object, args, null, null)) |value| return value;
    // Every dispatchable builtin is reachable through the integer
    // record mechanism; the legacy string-name chain that used to live
    // here was measured cold and removed (see host_dispatch_stats).
    host_dispatch_stats.hit(.nb_fallback_entered);
    return error.TypeError;
}

pub fn callNativeFunctionRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    this_value: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const function_bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*) orelse return null;
    if (try builtin_dispatch.callInternalRecord(ctx, output, global, globals, function_object, this_value, native_ref, args, caller_function, caller_frame)) |value| return value;
    return switch (native_ref.domain) {
        // Migrated to the internal record table (rt.internal_builtins);
        // reaching here means the id is not installed, which only happens
        // for corrupt ids.
        .math, .json, .uri, .number, .date, .error_object, .function, .primitive, .iterator, .collection, .reflect, .buffer, .string, .object, .array, .regexp => error.TypeError,
        .performance => try callPerformanceNativeFunctionRecord(ctx, native_ref.id),
        .atomics => {
            if (global) |global_object| return try call_runtime.qjsAtomicsCallForNativeRecord(ctx, output, global_object, native_ref.id, args, caller_function, caller_frame);
            return error.TypeError;
        },
        .host => try callHostGlobalNativeFunctionRecord(ctx, global, this_value, function_object, native_ref.id, args),
        .promise => try callPromiseStaticNativeFunctionRecord(ctx, output, global, globals, this_value, function_object, native_ref.id, args),
    };
}

/// `.host` native-builtin domain: host/web globals with no spec namespace
/// (HTML btoa/atob/queueMicrotask, the zjs `gc` helper, navigator accessors,
/// host constructor stubs, the shared species getter, and CallSite methods).
/// Replaces the retired string-name dispatch branches in `callNativeBuiltin`.
fn callHostGlobalNativeFunctionRecord(
    ctx: *core.JSContext,
    global: ?*core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    id: u32,
    args: []const core.JSValue,
) HostError!core.JSValue {
    return switch (id) {
        @intFromEnum(core.function.HostGlobalMethod.btoa) => try globalBtoa(ctx, global, args),
        @intFromEnum(core.function.HostGlobalMethod.atob) => try globalAtob(ctx, global, args),
        @intFromEnum(core.function.HostGlobalMethod.queue_microtask) => try globalQueueMicrotask(ctx, global, args),
        @intFromEnum(core.function.HostGlobalMethod.gc) => globalGc(ctx),
        @intFromEnum(core.function.HostGlobalMethod.navigator_user_agent_get) => try value_ops.createStringValue(ctx.runtime, core.function.navigator_user_agent),
        @intFromEnum(core.function.HostGlobalMethod.dom_exception_ctor_call) => {
            const active_global = global orelse function_object.functionRealmGlobalPtr() orelse return error.TypeError;
            return exception_ops.throwTypeErrorMessage(ctx, active_global, "constructor requires 'new'");
        },
        @intFromEnum(core.function.HostGlobalMethod.species_getter) => this_value.dup(),
        @intFromEnum(core.function.HostGlobalMethod.callsite_get_function),
        @intFromEnum(core.function.HostGlobalMethod.callsite_get_function_name),
        @intFromEnum(core.function.HostGlobalMethod.callsite_get_file_name),
        @intFromEnum(core.function.HostGlobalMethod.callsite_get_line_number),
        @intFromEnum(core.function.HostGlobalMethod.callsite_get_column_number),
        @intFromEnum(core.function.HostGlobalMethod.callsite_is_native),
        => {
            const receiver = thisObject(this_value) orelse return error.TypeError;
            return exception_ops.qjsCallSiteMethodById(ctx.runtime, receiver, @enumFromInt(id)) orelse error.TypeError;
        },
        else => error.TypeError,
    };
}

/// `.promise` native-builtin domain: the Promise static methods when invoked
/// through the host record path. The VM keeps its own realm-aware static
/// dispatch; this handler replaces the retired string-name fallback and so
/// mirrors that branch exactly, including its receiver gates.
fn callPromiseStaticNativeFunctionRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    this_value: core.JSValue,
    function_object: *core.Object,
    id: u32,
    args: []const core.JSValue,
) HostError!core.JSValue {
    // Combinators on the realm's own Promise statics run through the
    // capability machinery (element callbacks, custom capability support);
    // everything else takes the prototype-directed static call below.
    const combinator: ?PromiseCombinatorMode = switch (id) {
        @intFromEnum(method_ids.promise.LegacyStaticMethod.all) => .all,
        @intFromEnum(method_ids.promise.LegacyStaticMethod.race) => .race,
        @intFromEnum(method_ids.promise.LegacyStaticMethod.all_settled) => .all_settled,
        @intFromEnum(method_ids.promise.LegacyStaticMethod.any) => .any,
        else => null,
    };
    if (combinator) |mode| {
        const combinator_name: []const u8 = switch (mode) {
            .all => "all",
            .race => "race",
            .all_settled => "allSettled",
            .any => "any",
        };
        const is_static_builtin = if (try activeGlobalObject(ctx.runtime, global, globals)) |global_object|
            try promise_ops.qjsPromiseStaticBuiltinCallee(ctx.runtime, global_object, function_object, combinator_name)
        else
            false;
        if (is_static_builtin) {
            const combinator_receiver = thisObject(this_value) orelse return error.TypeError;
            if (!isCallableObjectValue(this_value)) return error.TypeError;
            if (try constructorNameEql(ctx.runtime, combinator_receiver, "Promise")) {
                return promiseCombinatorCall(ctx, output, global, globals, this_value, combinator_receiver, args, mode);
            }
        }
    }
    const receiver = thisObject(this_value) orelse return error.TypeError;
    if (!call_runtime.isCallableValue(this_value)) return error.TypeError;
    if (!try constructorNameEql(ctx.runtime, receiver, "Promise")) return error.TypeError;
    if (id == @intFromEnum(method_ids.promise.LegacyStaticMethod.try_)) {
        const promise_proto = constructorPrototype(ctx.runtime, receiver);
        const callback = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const callback_args = if (args.len >= 1) args[1..] else args[0..0];
        const result = callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, core.JSValue.undefinedValue(), callback, callback_args) catch {
            const reason = core.JSValue.undefinedValue();
            return core.promise.rejectedWithPrototype(ctx.runtime, reason, promise_proto);
        };
        defer result.free(ctx.runtime);
        return core.promise.fulfilledWithPrototype(ctx.runtime, result, promise_proto);
    }
    const payload: ?core.JSValue = if (args.len >= 1) args[0] else null;
    return core.promise.staticCallWithPrototype(ctx, id, payload, constructorPrototype(ctx.runtime, receiver), global) catch |err| switch (err) {
        error.TypeError => error.TypeError,
        else => err,
    };
}

/// `Function.prototype.bind` body. Stays in exec because `createBoundFunction`
/// and its proxy-aware property helpers are call.zig internals (covered by the
/// in-file tests); the `.function` builtins record handler delegates here. The
/// VM's own bind fast path (call_runtime.callNativeBuiltinRecordForVm) also
/// routes back through this via callNativeFunctionRecord (BOTH).
pub fn qjsFunctionBindCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    this_value: core.JSValue,
    args: []const core.JSValue,
) HostError!core.JSValue {
    if (thisObject(this_value) == null or !call_runtime.isCallableValue(this_value)) return error.TypeError;
    const bound_this = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const bound_args = if (args.len >= 1) args[1..] else args[0..0];
    return createBoundFunction(ctx, output, global, globals, this_value, bound_this, bound_args);
}

fn callPerformanceNativeFunctionRecord(ctx: *core.JSContext, id: u32) !core.JSValue {
    return switch (id) {
        1 => core.JSValue.float64(performanceNowMs() - ctx.runtime.performance_time_origin_ms),
        else => error.TypeError,
    };
}

pub fn createRealmObject(rt: *core.JSRuntime) HostError!core.JSValue {
    const realm = try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.object, null, 1);
    errdefer realm.value().free(rt);
    const realm_global = try core.Object.createWithOwnPropertyCapacity(
        rt,
        core.class.ids.object,
        null,
        rt.standardGlobalOwnPropertyCapacity() + 1,
    );
    var realm_global_owned = true;
    errdefer if (realm_global_owned) realm_global.value().free(rt);
    realm_global.flags.is_global = true;
    try rt.installStandardGlobals(realm_global);
    try defineGlobalThisProperty(rt, realm_global);
    try tagRealmEval(rt, realm_global);
    try tagRealmFunctionConstructor(rt, realm_global);
    try tagRealmRegExpAccessorErrors(rt, realm_global);
    try defineObjectProperty(rt, realm, "global", realm_global.value());
    realm_global.value().free(rt);
    realm_global_owned = false;
    return realm.value();
}

fn tagRealmEval(rt: *core.JSRuntime, realm_global: *core.Object) !void {
    const eval_key = try rt.internAtom("eval");
    defer rt.atoms.free(eval_key);
    const eval_value = realm_global.getProperty(eval_key);
    defer eval_value.free(rt);
    const eval_object = expectObjectArg(eval_value) catch return;
    const slot = try eval_object.functionRealmGlobalSlot(rt);
    try eval_object.setOptionalValueSlot(rt, slot, realm_global.value().dup());
}

fn tagRealmFunctionConstructor(rt: *core.JSRuntime, realm_global: *core.Object) !void {
    const function_key = try rt.internAtom("Function");
    defer rt.atoms.free(function_key);
    const function_value = realm_global.getProperty(function_key);
    defer function_value.free(rt);
    const function_object = expectObjectArg(function_value) catch return;
    try function_object.setFunctionRealmGlobalPtr(rt, realm_global);
    const realm_prototype_names = [_][]const u8{ "Object", "Number", "Boolean", "Array", "Iterator", "Map", "Set", "WeakMap", "WeakSet", "RegExp" };
    for (realm_prototype_names) |name| {
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        const value = realm_global.getProperty(key);
        defer value.free(rt);
        const object = try expectObjectArg(value);
        if (constructorPrototype(rt, object)) |proto| {
            const realm_key = try realmPrototypeKey(rt, name);
            defer rt.memory.allocator.free(realm_key);
            try defineObjectProperty(rt, function_object, realm_key, proto.value());
        }
    }
}

fn tagRealmRegExpAccessorErrors(rt: *core.JSRuntime, realm_global: *core.Object) !void {
    const regexp_key = try rt.internAtom("RegExp");
    defer rt.atoms.free(regexp_key);
    const regexp_value = realm_global.getProperty(regexp_key);
    defer regexp_value.free(rt);
    const regexp_object = expectObjectArg(regexp_value) catch return;
    const proto = constructorPrototype(rt, regexp_object) orelse return;
    const type_error_key = try rt.internAtom("TypeError");
    defer rt.atoms.free(type_error_key);
    const type_error_value = realm_global.getProperty(type_error_key);
    defer type_error_value.free(rt);
    const accessors = [_][]const u8{ "source", "flags", "global", "ignoreCase", "multiline", "dotAll", "unicode", "sticky", "hasIndices", "unicodeSets" };
    for (accessors) |name| {
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        const desc = proto.getOwnProperty(rt, key) orelse continue;
        defer desc.destroy(rt);
        if (desc.kind != .accessor or desc.getter.isUndefined()) continue;
        const getter_object = expectObjectArg(desc.getter) catch continue;
        const slot = try getter_object.functionRealmTypeErrorConstructorSlot(rt);
        try getter_object.setOptionalValueSlot(rt, slot, type_error_value.dup());
    }
}

const ValueSliceRoot = array_ops.ValueSliceRoot;

// The `reflect construct roots argument list while resolving prototype` test,
// the `host global bootstrap ...` test, and the matching `engine eval host
// globals ...` test in `zjs_vm.zig` were relocated to `src/tests/exec.zig`
// during Phase 6b-3 STEP 7B. They build a bare `core.JSRuntime` and install the
// standard globals, which now flows through `rt.installStandardGlobals` and so
// needs the builtins installer registered first; exec source cannot name the
// builtins registry, so the bootstrap-integration tests live in the test tree
// (which may import builtins) instead.

pub fn realmPrototypeKey(rt: *core.JSRuntime, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(rt.memory.allocator, "__realm_{s}_proto", .{name});
}

/// Bare-runtime (no realm global) `Object.*` static fallback. Reached only via
/// the `.object` builtins record handler (`builtins.object.objectCall`) when the
/// host record path supplies no realm global; the realm path takes
/// `builtins.object.objectCallForNativeRecord` instead. Stays in call.zig because
/// it leans on the shared call.zig property/descriptor helper web
/// (`expectObjectArg`, `descriptorFromObject`, `objectStaticToObjectValue`, ...)
/// that the rest of this file owns — the BOTH split keeps the core here and the
/// thin dispatch entry in builtins.
pub fn callObjectStatic(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    const rt = ctx.runtime;
    if (id == @intFromEnum(method_ids.object.StaticMethod.assign)) {
        if (args.len < 1) return error.TypeError;
        const target_value = try objectStaticToObjectValue(ctx, global, args[0]);
        errdefer target_value.free(rt);
        const target = try expectObjectArg(target_value);
        for (args[1..]) |source_arg| {
            if (source_arg.isNull() or source_arg.isUndefined()) continue;
            const source_value = try objectStaticToObjectValue(ctx, global, source_arg);
            defer source_value.free(rt);
            const source = try expectObjectArg(source_value);
            const keys = try source.ownKeys(rt);
            defer core.Object.freeKeys(rt, keys);
            for (keys) |key| {
                const desc = source.getOwnProperty(rt, key) orelse continue;
                defer desc.destroy(rt);
                if (desc.enumerable != true) continue;
                const value = try objectAssignGet(ctx, output, global, globals, source_value, desc);
                defer value.free(rt);
                try objectAssignSet(ctx, output, global, globals, target_value, target, key, value);
            }
        }
        return target_value;
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.create)) {
        if (args.len < 1) return error.TypeError;
        const proto: ?*core.Object = if (args[0].isNull())
            null
        else
            try expectObjectArg(args[0]);
        const object = try core.Object.create(rt, core.class.ids.object, proto);
        errdefer core.Object.destroyFromHeader(rt, &object.header);
        object.flags.null_prototype = args[0].isNull();
        if (args.len >= 2 and !args[1].isUndefined()) {
            try definePropertiesFromObject(rt, object, args[1]);
        }
        return object.value();
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.is)) {
        const lhs = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const rhs = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
        return core.JSValue.boolean(lhs.sameValue(rhs));
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.keys)) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(ctx, global, args[0]);
        defer object_value.free(rt);
        return core.object.ownEntriesArray(rt, object_value, .keys);
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.values)) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(ctx, global, args[0]);
        defer object_value.free(rt);
        return core.object.ownEntriesArray(rt, object_value, .values);
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.entries)) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(ctx, global, args[0]);
        defer object_value.free(rt);
        return core.object.ownEntriesArray(rt, object_value, .entries);
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.get_own_property_descriptor)) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(ctx, global, args[0]);
        defer object_value.free(rt);
        const object = try expectObjectArg(object_value);
        const key_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
        const key = try atomFromPropertyKey(rt, key_value);
        defer rt.atoms.free(key);
        var desc = object.getOwnProperty(rt, key) orelse return core.JSValue.undefinedValue();
        materializeMappedArgumentsDescriptorValue(rt, object, key, &desc);
        defer desc.destroy(rt);
        return descriptorObject(rt, desc);
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.get_own_property_descriptors)) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(ctx, global, args[0]);
        defer object_value.free(rt);
        const object = try expectObjectArg(object_value);
        const keys = try object.ownKeys(rt);
        defer core.Object.freeKeys(rt, keys);
        const out = try core.Object.create(rt, core.class.ids.object, null);
        errdefer core.Object.destroyFromHeader(rt, &out.header);
        for (keys) |key| {
            var desc = object.getOwnProperty(rt, key) orelse continue;
            materializeMappedArgumentsDescriptorValue(rt, object, key, &desc);
            defer desc.destroy(rt);
            const desc_value = try descriptorObject(rt, desc);
            defer desc_value.free(rt);
            try out.defineOwnProperty(rt, key, core.Descriptor.data(desc_value, true, true, true));
        }
        return out.value();
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.get_own_property_names)) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(ctx, global, args[0]);
        defer object_value.free(rt);
        const object = try expectObjectArg(object_value);
        const keys = try object.ownKeys(rt);
        defer core.Object.freeKeys(rt, keys);
        const out = try core.Object.createArray(rt, null);
        errdefer core.Object.destroyFromHeader(rt, &out.header);
        var out_index: u32 = 0;
        for (keys) |key| {
            const name_value = try atomToStringValue(rt, key);
            defer name_value.free(rt);
            try out.defineOwnProperty(rt, core.atom.atomFromUInt32(out_index), core.Descriptor.data(name_value, true, true, true));
            out_index += 1;
        }
        return out.value();
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.get_own_property_symbols)) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(ctx, global, args[0]);
        defer object_value.free(rt);
        const object = try expectObjectArg(object_value);
        const keys = try object.ownKeys(rt);
        defer core.Object.freeKeys(rt, keys);
        const out = try core.Object.createArray(rt, null);
        errdefer core.Object.destroyFromHeader(rt, &out.header);
        for (keys) |key| {
            if (!rt.atoms.isPublicSymbol(key)) continue;
            try out.defineOwnProperty(rt, core.atom.atomFromUInt32(out.arrayLength()), core.Descriptor.data(try rt.symbolValue(key), true, true, true));
        }
        return out.value();
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.has_own)) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(ctx, global, args[0]);
        defer object_value.free(rt);
        const object = try expectObjectArg(object_value);
        const key_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
        const key = try atomFromPropertyKey(rt, key_value);
        defer rt.atoms.free(key);
        if (object.getOwnProperty(rt, key)) |desc| {
            desc.destroy(rt);
            return core.JSValue.boolean(true);
        }
        return core.JSValue.boolean(false);
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.get_prototype_of)) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(ctx, global, args[0]);
        defer object_value.free(rt);
        const object = try expectObjectArg(object_value);
        if (object.getPrototype()) |prototype| return prototype.value().dup();
        return core.JSValue.nullValue();
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.set_prototype_of)) {
        if (args.len < 2) return error.TypeError;
        if (args[0].isNull() or args[0].isUndefined()) return error.TypeError;
        const prototype: ?*core.Object = if (args[1].isNull())
            null
        else
            try expectObjectArg(args[1]);
        const object = thisObject(args[0]) orelse return args[0].dup();
        object.setPrototype(rt, prototype) catch |err| switch (err) {
            error.PrototypeCycle, error.NotExtensible => return error.TypeError,
            else => return err,
        };
        return args[0].dup();
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.is_extensible)) {
        const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const object = thisObject(target_value) orelse return core.JSValue.boolean(false);
        return core.JSValue.boolean(object.isExtensible());
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.prevent_extensions)) {
        const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const object = thisObject(target_value) orelse return target_value.dup();
        object.preventExtensions();
        return target_value.dup();
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.seal)) {
        const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const object = thisObject(target_value) orelse return target_value.dup();
        try object.seal(rt);
        return target_value.dup();
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.is_sealed)) {
        const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const object = thisObject(target_value) orelse return core.JSValue.boolean(true);
        return core.JSValue.boolean(try objectIsSealed(rt, object));
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.is_frozen)) {
        const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const object = thisObject(target_value) orelse return core.JSValue.boolean(true);
        return core.JSValue.boolean(try objectIsFrozen(rt, object));
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.freeze)) {
        const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const object = thisObject(target_value) orelse return target_value.dup();
        try object.freeze(rt);
        return target_value.dup();
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.define_property)) {
        if (args.len < 3) return error.TypeError;
        const object = try expectObjectArg(args[0]);
        const key = try atomFromPropertyKey(rt, args[1]);
        defer rt.atoms.free(key);
        const desc_object = try expectObjectArg(args[2]);
        const desc = try descriptorFromObject(rt, desc_object);
        defer desc.destroy(rt);
        object.defineOwnProperty(rt, key, desc) catch |err| switch (err) {
            error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
            error.InvalidLength => return error.RangeError,
            else => return err,
        };
        return object.value().dup();
    }
    if (id == @intFromEnum(method_ids.object.StaticMethod.define_properties)) {
        if (args.len < 2) return error.TypeError;
        const object = try expectObjectArg(args[0]);
        try definePropertiesFromObject(rt, object, args[1]);
        return object.value().dup();
    }
    return error.TypeError;
}

fn objectStaticToObjectValue(ctx: *core.JSContext, global: ?*core.Object, value: core.JSValue) !core.JSValue {
    const rt = ctx.runtime;
    if (value.isNull() or value.isUndefined()) return error.TypeError;
    if (value.isObject()) return value.dup();
    const class_id: core.class.ClassId = if (value.isString())
        core.class.ids.string
    else if (value.isNumber())
        core.class.ids.number
    else if (value.asBool() != null)
        core.class.ids.boolean
    else if (value.isBigInt())
        core.class.ids.big_int
    else if (value.isSymbol())
        core.class.ids.symbol
    else
        core.class.ids.object;
    if (class_id == core.class.ids.object) {
        const object = try core.Object.create(rt, core.class.ids.object, null);
        return object.value();
    }
    return primitiveWrapper(ctx, class_id, value, primitivePrototypeFromGlobal(rt, global, class_id));
}

fn objectAssignGet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    receiver: core.JSValue,
    desc: core.Descriptor,
) HostError!core.JSValue {
    return switch (desc.kind) {
        .data => desc.value.dup(),
        .generic => core.JSValue.undefinedValue(),
        .accessor => {
            if (desc.getter.isUndefined()) return core.JSValue.undefinedValue();
            return callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, receiver, desc.getter, &.{});
        },
    };
}

fn objectAssignSet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    target_value: core.JSValue,
    target: *core.Object,
    key: core.Atom,
    value: core.JSValue,
) !void {
    if (target.getOwnProperty(ctx.runtime, key)) |desc| {
        defer desc.destroy(ctx.runtime);
        switch (desc.kind) {
            .accessor => {
                if (desc.setter.isUndefined()) return error.TypeError;
                const result = try callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, target_value, desc.setter, &.{value});
                result.free(ctx.runtime);
                return;
            },
            .data => {
                if (desc.writable == false) return error.TypeError;
            },
            .generic => {},
        }
    } else {
        var proto = target.getPrototype();
        while (proto) |prototype| : (proto = prototype.getPrototype()) {
            if (prototype.getOwnProperty(ctx.runtime, key)) |desc| {
                defer desc.destroy(ctx.runtime);
                switch (desc.kind) {
                    .accessor => {
                        if (desc.setter.isUndefined()) return error.TypeError;
                        const result = try callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, target_value, desc.setter, &.{value});
                        result.free(ctx.runtime);
                        return;
                    },
                    .data => {
                        if (desc.writable == false) return error.TypeError;
                    },
                    .generic => {},
                }
                break;
            }
        }
    }
    target.setProperty(ctx.runtime, key, value) catch |err| switch (err) {
        error.ReadOnly, error.AccessorWithoutSetter, error.NotExtensible, error.IncompatibleDescriptor => return error.TypeError,
        error.InvalidLength => return error.RangeError,
        else => return err,
    };
}

fn objectIsSealed(rt: *core.JSRuntime, object: *core.Object) !bool {
    if (object.isExtensible()) return false;
    const keys = try object.ownKeys(rt);
    defer core.Object.freeKeys(rt, keys);
    for (keys) |key| {
        const desc = object.getOwnProperty(rt, key) orelse continue;
        defer desc.destroy(rt);
        if (desc.configurable == true) return false;
    }
    return true;
}

fn objectIsFrozen(rt: *core.JSRuntime, object: *core.Object) !bool {
    if (!try objectIsSealed(rt, object)) return false;
    const keys = try object.ownKeys(rt);
    defer core.Object.freeKeys(rt, keys);
    for (keys) |key| {
        const desc = object.getOwnProperty(rt, key) orelse continue;
        defer desc.destroy(rt);
        if (desc.kind == .data and desc.writable == true) return false;
    }
    return true;
}

/// Bare-runtime (no realm global) `Object.prototype.*` fallback, dispatched by
/// the `prototypeMethodOrdinal` mapping. Like `callObjectStatic`, this is the
/// `global == null` branch of the `.object` builtins record handler and stays in
/// call.zig alongside the shared property helpers it depends on.
pub fn objectPrototypeMethodCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    method: i32,
    this_value: core.JSValue,
    args: []const core.JSValue,
) !core.JSValue {
    return switch (method) {
        1 => objectPrototypeToString(ctx.runtime, this_value),
        2 => {
            const to_string_key = try ctx.runtime.internAtom("toString");
            defer ctx.runtime.atoms.free(to_string_key);
            const receiver_value = try objectStaticToObjectValue(ctx, global, this_value);
            defer receiver_value.free(ctx.runtime);
            const receiver = try expectObjectArg(receiver_value);
            const method_value = receiver.getProperty(to_string_key);
            defer method_value.free(ctx.runtime);
            return callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, receiver_value, method_value, &.{});
        },
        3 => objectPrototypeValueOf(ctx, global, this_value),
        4 => objectPrototypeHasOwn(ctx, global, this_value, args),
        5 => objectPrototypeIsPrototypeOf(ctx, global, this_value, args),
        6 => objectPrototypePropertyIsEnumerable(ctx, global, this_value, args),
        7 => objectPrototypeDefineAccessor(ctx, global, this_value, args, true),
        8 => objectPrototypeDefineAccessor(ctx, global, this_value, args, false),
        9 => objectPrototypeLookupAccessor(ctx, global, this_value, args, true),
        10 => objectPrototypeLookupAccessor(ctx, global, this_value, args, false),
        else => error.TypeError,
    };
}

fn objectPrototypeToString(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue {
    if (receiver.isUndefined()) return value_ops.createStringValue(rt, "[object Undefined]");
    if (receiver.isNull()) return value_ops.createStringValue(rt, "[object Null]");
    if (receiver.asBool() != null) return value_ops.createStringValue(rt, "[object Boolean]");
    if (receiver.isNumber()) return value_ops.createStringValue(rt, "[object Number]");
    if (receiver.isString()) return value_ops.createStringValue(rt, "[object String]");
    if (receiver.isBigInt()) return value_ops.createStringValue(rt, "[object BigInt]");
    if (receiver.isSymbol()) return value_ops.createStringValue(rt, "[object Symbol]");
    return objectToString(rt, receiver);
}

fn objectPrototypeValueOf(ctx: *core.JSContext, global: ?*core.Object, receiver: core.JSValue) !core.JSValue {
    return objectStaticToObjectValue(ctx, global, receiver);
}

fn objectPrototypeHasOwn(ctx: *core.JSContext, global: ?*core.Object, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const rt = ctx.runtime;
    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const key = try atomFromPropertyKey(rt, key_value);
    defer rt.atoms.free(key);
    const receiver_value = try objectStaticToObjectValue(ctx, global, receiver);
    defer receiver_value.free(rt);
    const object = try expectObjectArg(receiver_value);
    if (object.getOwnProperty(rt, key)) |desc| {
        desc.destroy(rt);
        return core.JSValue.boolean(true);
    }
    return core.JSValue.boolean(false);
}

fn objectPrototypePropertyIsEnumerable(ctx: *core.JSContext, global: ?*core.Object, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const rt = ctx.runtime;
    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const key = try atomFromPropertyKey(rt, key_value);
    defer rt.atoms.free(key);
    const receiver_value = try objectStaticToObjectValue(ctx, global, receiver);
    defer receiver_value.free(rt);
    const object = try expectObjectArg(receiver_value);
    const desc = object.getOwnProperty(rt, key) orelse return core.JSValue.boolean(false);
    defer desc.destroy(rt);
    return core.JSValue.boolean(desc.enumerable orelse false);
}

fn objectPrototypeIsPrototypeOf(ctx: *core.JSContext, global: ?*core.Object, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const value_object = thisObject(value) orelse return core.JSValue.boolean(false);
    const receiver_value = try objectStaticToObjectValue(ctx, global, receiver);
    defer receiver_value.free(ctx.runtime);
    const object = try expectObjectArg(receiver_value);
    var proto = value_object.getPrototype();
    while (proto) |candidate| : (proto = candidate.getPrototype()) {
        if (candidate == object) return core.JSValue.boolean(true);
    }
    return core.JSValue.boolean(false);
}

fn objectPrototypeDefineAccessor(ctx: *core.JSContext, global: ?*core.Object, receiver: core.JSValue, args: []const core.JSValue, getter: bool) !core.JSValue {
    const rt = ctx.runtime;
    const receiver_value = try objectStaticToObjectValue(ctx, global, receiver);
    defer receiver_value.free(rt);
    const object = try expectObjectArg(receiver_value);
    const accessor_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    if (!isCallableObjectValue(accessor_value)) return error.TypeError;
    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const key = try atomFromPropertyKey(rt, key_value);
    defer rt.atoms.free(key);
    const desc = if (getter)
        core.Descriptor.accessor(accessor_value, core.JSValue.undefinedValue(), true, true)
    else
        core.Descriptor.accessor(core.JSValue.undefinedValue(), accessor_value, true, true);
    object.defineOwnProperty(rt, key, desc) catch |err| switch (err) {
        error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
        error.InvalidLength => return error.RangeError,
        else => return err,
    };
    return core.JSValue.undefinedValue();
}

fn objectPrototypeLookupAccessor(ctx: *core.JSContext, global: ?*core.Object, receiver: core.JSValue, args: []const core.JSValue, getter: bool) !core.JSValue {
    const rt = ctx.runtime;
    const receiver_value = try objectStaticToObjectValue(ctx, global, receiver);
    defer receiver_value.free(rt);
    const object = try expectObjectArg(receiver_value);
    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const key = try atomFromPropertyKey(rt, key_value);
    defer rt.atoms.free(key);
    var cursor: ?*core.Object = object;
    while (cursor) |current| : (cursor = current.getPrototype()) {
        const desc = current.getOwnProperty(rt, key) orelse continue;
        defer desc.destroy(rt);
        if (desc.kind != .accessor) return core.JSValue.undefinedValue();
        return if (getter) desc.getter.dup() else desc.setter.dup();
    }
    return core.JSValue.undefinedValue();
}

pub fn isCallableObjectValue(value: core.JSValue) bool {
    const object = thisObject(value) orelse return false;
    return object.class_id == core.class.ids.c_function or
        object.class_id == core.class.ids.c_closure or
        object.class_id == core.class.ids.bound_function or
        object.class_id == core.class.ids.bytecode_function;
}

pub fn primitiveWrapper(ctx: *core.JSContext, class_id: core.class.ClassId, primitive: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    const rt = ctx.runtime;
    if (class_id == core.class.ids.string) {
        // Route `new String(primitive)` / `Object(stringPrimitive)` boxing
        // through the String construct record (Phase 6b-3 STEP 6) instead of
        // naming `builtins.string.constructWithPrototype`: the record's
        // construct branch forwards `args`/`new_target` straight to that body.
        return (try builtin_dispatch.callConstructRecord(ctx, null, null, &.{}, null, string_construct_ref, prototype, &.{primitive}, null, null)) orelse error.TypeError;
    }
    var rooted_primitive = primitive;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_primitive },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const object = try core.Object.create(rt, class_id, prototype);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    try object.setOptionalValueSlot(rt, object.objectDataSlot(), rooted_primitive.dup());
    return object.value();
}

test "primitiveWrapper roots direct symbol while creating call wrapper" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-call-wrapper-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const symbol_value = try rt.symbolValue(symbol_atom);
    const wrapper_value = try primitiveWrapper(ctx, core.class.ids.symbol, symbol_value, null);
    var wrapper_alive = true;
    defer if (wrapper_alive) wrapper_value.free(rt);
    const wrapper = property_ops.expectObject(wrapper_value) catch return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = wrapper.objectData() orelse return error.TypeError;
    try std.testing.expect(stored.same(symbol_value));

    wrapper_value.free(rt);
    wrapper_alive = false;
    symbol_value.free(rt);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn primitivePrototypeFromGlobal(rt: *core.JSRuntime, global: ?*core.Object, class_id: core.class.ClassId) ?*core.Object {
    const global_object = global orelse return null;
    const name = switch (class_id) {
        core.class.ids.string => "String",
        core.class.ids.number => "Number",
        core.class.ids.boolean => "Boolean",
        core.class.ids.symbol => "Symbol",
        core.class.ids.big_int => "BigInt",
        else => return null,
    };
    const key = rt.internAtom(name) catch return null;
    defer rt.atoms.free(key);
    const constructor_value = global_object.getProperty(key);
    defer constructor_value.free(rt);
    const constructor = thisObject(constructor_value) orelse return null;
    return constructorPrototype(rt, constructor);
}

fn defineDataPropertyWithFlags(
    rt: *core.JSRuntime,
    object: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    writable: bool,
    enumerable: bool,
    configurable: bool,
) !void {
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, writable, enumerable, configurable));
}

fn boundFunctionNameValue(rt: *core.JSRuntime, target_name: core.JSValue) !core.JSValue {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try bytes.appendSlice(rt.memory.allocator, "bound ");
    if (target_name.isString()) {
        try value_ops.appendRawString(rt, &bytes, target_name);
    }
    return value_ops.createStringValue(rt, bytes.items);
}

fn boundFunctionLengthValue(target_length: core.JSValue, bound_arg_count: usize) core.JSValue {
    const number = value_ops.numberValue(target_length) orelse return core.JSValue.int32(0);
    if (std.math.isNan(number) or std.math.isNegativeInf(number)) return core.JSValue.int32(0);
    if (std.math.isPositiveInf(number)) return core.JSValue.float64(std.math.inf(f64));
    var integer = @trunc(number);
    if (integer == 0 or std.math.isNegativeZero(integer)) integer = 0;
    if (integer < 0) return core.JSValue.int32(0);
    const remaining = integer - @as(f64, @floatFromInt(bound_arg_count));
    return value_ops.numberToValue(if (remaining > 0) remaining else 0);
}

fn createBoundFunction(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    target: core.JSValue,
    bound_this: core.JSValue,
    bound_args: []const core.JSValue,
) !core.JSValue {
    const rt = ctx.runtime;
    var rooted_target = target;
    var rooted_bound_this = bound_this;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_target },
        .{ .value = &rooted_bound_this },
    };
    var rooted_bound_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, bound_args);
    defer rooted_bound_args_buffer.deinit(rt);
    const rooted_bound_args = rooted_bound_args_buffer.values;
    var root_slices = [_]core.runtime.ValueRootSlice{
        rooted_bound_args_buffer.slice(),
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
        .slices = &root_slices,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const target_object = thisObject(rooted_target) orelse return error.TypeError;
    const length_value = if (try hasOwnPropertyProxyAware(ctx, output, global, globals, target_object, core.atom.ids.length)) blk: {
        const target_length = try getValuePropertyProxyAware(ctx, output, global, globals, rooted_target, core.atom.ids.length);
        defer target_length.free(rt);
        break :blk boundFunctionLengthValue(target_length, rooted_bound_args.len);
    } else core.JSValue.int32(0);
    defer length_value.free(rt);
    const target_name = try getValuePropertyProxyAware(ctx, output, global, globals, rooted_target, core.atom.ids.name);
    defer target_name.free(rt);
    const name_value = try boundFunctionNameValue(rt, target_name);
    defer name_value.free(rt);

    const object = try core.Object.create(rt, core.class.ids.bound_function, target_object.getPrototype());
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    try object.setOptionalValueSlot(rt, object.boundTargetSlot(), rooted_target.dup());
    try object.setOptionalValueSlot(rt, object.boundThisSlot(), rooted_bound_this.dup());
    if (target_object.functionRealmGlobalPtr()) |realm_global| try object.setFunctionRealmGlobalPtr(rt, realm_global);
    if (target_object.functionRealmGlobal()) |realm_value| try object.setOptionalValueSlot(rt, try object.functionRealmGlobalSlot(rt), realm_value.dup());
    if (rooted_bound_args.len != 0) {
        const owned_bound_args = try rt.memory.alloc(core.JSValue, rooted_bound_args.len);
        var rooted_owned_bound_args: []core.JSValue = owned_bound_args[0..0];
        var owned_bound_args_root = ValueSliceRoot{};
        owned_bound_args_root.init(rt, &rooted_owned_bound_args);
        defer owned_bound_args_root.deinit();
        var initialized: usize = 0;
        var bound_args_owned = true;
        errdefer if (bound_args_owned) {
            for (owned_bound_args[0..initialized]) |*stored| {
                stored.free(rt);
                stored.* = core.JSValue.undefinedValue();
            }
            rooted_owned_bound_args = &.{};
            rt.memory.free(core.JSValue, owned_bound_args);
        };
        for (rooted_bound_args, 0..) |arg, index| {
            owned_bound_args[index] = arg.dup();
            initialized += 1;
            rooted_owned_bound_args = owned_bound_args[0..initialized];
        }
        bound_args_owned = false;
        object.boundArgsSlot().* = owned_bound_args;
        rooted_owned_bound_args = &.{};
    }
    try defineDataPropertyWithFlags(rt, object, core.atom.ids.name, name_value, false, false, true);
    try defineDataPropertyWithFlags(rt, object, core.atom.ids.length, length_value, false, false, true);
    return object.value();
}

test "createBoundFunction roots bound this and args while creating function" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const target = try core.function.nativeFunction(rt, "target", 0);
    defer target.free(rt);

    const this_atom = try rt.atoms.newValueSymbol("gc-bound-this-symbol");
    const this_value = try rt.symbolValue(this_atom);
    const arg_atom = try rt.atoms.newValueSymbol("gc-bound-arg-symbol");
    const arg_value = try rt.symbolValue(arg_atom);
    const bound_args = [_]core.JSValue{arg_value};
    var globals = [_]globals_mod.Slot{};

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const bound_value = try createBoundFunction(
        ctx,
        null,
        null,
        globals[0..],
        target,
        this_value,
        &bound_args,
    );
    var bound_alive = true;
    defer if (bound_alive) bound_value.free(rt);
    const bound = thisObject(bound_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(this_atom) != null);
    try std.testing.expect(rt.atoms.name(arg_atom) != null);
    try std.testing.expect(bound.boundThis().?.same(this_value));
    try std.testing.expectEqual(@as(usize, 1), bound.boundArgs().len);
    try std.testing.expect(bound.boundArgs()[0].same(arg_value));

    bound_value.free(rt);
    bound_alive = false;
    this_value.free(rt);
    arg_value.free(rt);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(this_atom) == null);
    try std.testing.expect(rt.atoms.name(arg_atom) == null);
}

test "callValueWithThisGlobalsAndGlobal roots inline args before bound argument merge" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const target = try core.function.nativeFunction(rt, "get [Symbol.species]", 0);
    defer target.free(rt);
    const target_object = thisObject(target) orelse return error.TypeError;
    target_object.nativeFunctionIdSlot().* = core.function.nativeBuiltinId(.host, @intFromEnum(core.function.HostGlobalMethod.species_getter));

    var globals = [_]globals_mod.Slot{};
    const bound_value = try createBoundFunction(
        ctx,
        null,
        null,
        globals[0..],
        target,
        core.JSValue.undefinedValue(),
        &.{},
    );
    var bound_alive = true;
    defer if (bound_alive) bound_value.free(rt);

    const arg_atom = try rt.atoms.newValueSymbol("gc-call-legacy-inline-arg-root");
    const arg_value = try rt.symbolValue(arg_atom);
    const args = [_]core.JSValue{arg_value};

    const Trigger = struct {
        rt: *core.JSRuntime,
        atom_id: u32,
        saw_arg: bool = false,
        trace_failed: bool = false,

        fn trigger(context: ?*anyopaque, size: usize) void {
            _ = size;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const saved_trigger_fn = self.rt.memory.trigger_gc_fn;
            const saved_trigger_ctx = self.rt.memory.trigger_gc_ctx;
            self.rt.memory.trigger_gc_fn = null;
            self.rt.memory.trigger_gc_ctx = null;
            defer {
                self.rt.memory.trigger_gc_fn = saved_trigger_fn;
                self.rt.memory.trigger_gc_ctx = saved_trigger_ctx;
            }
            _ = self.rt.runObjectCycleRemoval();
            self.saw_arg = self.rt.atoms.name(self.atom_id) != null;
        }
    };

    const saved_trigger_fn = rt.memory.trigger_gc_fn;
    const saved_trigger_ctx = rt.memory.trigger_gc_ctx;
    var trigger = Trigger{
        .rt = rt,
        .atom_id = arg_atom,
    };
    rt.memory.trigger_gc_fn = Trigger.trigger;
    rt.memory.trigger_gc_ctx = &trigger;
    defer {
        rt.memory.trigger_gc_fn = saved_trigger_fn;
        rt.memory.trigger_gc_ctx = saved_trigger_ctx;
    }

    const result = try callValueWithThisGlobalsAndGlobal(
        ctx,
        null,
        null,
        globals[0..],
        core.JSValue.undefinedValue(),
        bound_value,
        &args,
    );
    defer result.free(rt);
    rt.memory.trigger_gc_fn = saved_trigger_fn;
    rt.memory.trigger_gc_ctx = saved_trigger_ctx;

    try std.testing.expect(!trigger.trace_failed);
    try std.testing.expect(trigger.saw_arg);

    bound_value.free(rt);
    bound_alive = false;
    arg_value.free(rt);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(arg_atom) == null);
}

fn callBoundFunction(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    object: *core.Object,
    args: []const core.JSValue,
) HostError!core.JSValue {
    const target = object.boundTarget() orelse return error.TypeError;
    const bound_this = object.boundThis() orelse return error.TypeError;
    const combined = try call_runtime.boundFunctionArgs(ctx.runtime, object, args);
    defer call_runtime.freeArgs(ctx.runtime, combined);
    return callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, bound_this, target, combined);
}

fn objectToString(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue {
    const object = try expectObjectArg(receiver);
    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return value_ops.createStringValue(rt, "[object Object]");
    const tag_value = object.getProperty(tag_atom);
    defer tag_value.free(rt);
    if (tag_value.isString()) {
        var tag = std.ArrayList(u8).empty;
        defer tag.deinit(rt.memory.allocator);
        try value_ops.appendRawString(rt, &tag, tag_value);
        var out = std.ArrayList(u8).empty;
        defer out.deinit(rt.memory.allocator);
        try out.appendSlice(rt.memory.allocator, "[object ");
        try out.appendSlice(rt.memory.allocator, tag.items);
        try out.appendSlice(rt.memory.allocator, "]");
        return value_ops.createStringValue(rt, out.items);
    }
    return value_ops.createStringValue(rt, defaultObjectTag(object));
}

fn finalizationRegistryAppendCell(
    rt: *core.JSRuntime,
    receiver: *core.Object,
    target: core.JSValue,
    held_value: core.JSValue,
    unregister_token: core.JSValue,
) !void {
    try receiver.appendFinalizationRegistryCell(rt, target, held_value, unregister_token);
}

fn defaultObjectTag(object: *core.Object) []const u8 {
    if (object.flags.is_array) return "[object Array]";
    return switch (object.class_id) {
        core.class.ids.c_function,
        core.class.ids.bytecode_function,
        core.class.ids.bound_function,
        core.class.ids.c_function_data,
        core.class.ids.c_closure,
        => "[object Function]",
        core.class.ids.map => "[object Map]",
        core.class.ids.set => "[object Set]",
        core.class.ids.weakmap => "[object WeakMap]",
        core.class.ids.weakset => "[object WeakSet]",
        core.class.ids.promise => "[object Promise]",
        core.class.ids.array_buffer => "[object ArrayBuffer]",
        core.class.ids.date => "[object Date]",
        core.class.ids.regexp => "[object RegExp]",
        core.class.ids.string => "[object String]",
        core.class.ids.number => "[object Number]",
        core.class.ids.boolean => "[object Boolean]",
        core.class.ids.big_int => "[object BigInt]",
        core.class.ids.symbol => "[object Symbol]",
        core.class.ids.arguments, core.class.ids.mapped_arguments => "[object Arguments]",
        else => "[object Object]",
    };
}

pub fn nativeFunctionName(rt: *core.JSRuntime, function_object: *core.Object) ![]u8 {
    const name_value = try nativeFunctionNameValue(rt, function_object, false);
    defer name_value.free(rt);
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &buffer, name_value);
    return buffer.toOwnedSlice(rt.memory.allocator);
}

pub fn nativeFunctionNameForVm(rt: *core.JSRuntime, function_object: *core.Object) ![]u8 {
    return nativeFunctionDispatchName(rt, function_object);
}

pub fn functionToStringValue(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    if (value.isFunctionBytecode()) {
        const bytecode = functionBytecodeFromValue(value) orelse return error.TypeError;
        return functionBytecodeToStringValue(rt, bytecode, null);
    }

    const object = thisObject(value) orelse return error.TypeError;
    if (object.flags.is_proxy) {
        if (object.proxyHandler() == null) return error.TypeError;
        const target = object.proxyTarget() orelse return error.TypeError;
        if (!isFunctionToStringCallable(target)) return error.TypeError;
        return nativeFunctionSourceValue(rt, null);
    }
    if (object.class_id == core.class.ids.bytecode_function) {
        const stored = object.functionBytecodeSlot().* orelse return nativeFunctionSourceValue(rt, object);
        const bytecode = functionBytecodeFromValue(stored) orelse return nativeFunctionSourceValue(rt, object);
        return functionBytecodeToStringValue(rt, bytecode, object);
    }
    if (object.class_id == core.class.ids.bound_function) {
        return nativeFunctionSourceValue(rt, null);
    }
    if (isFunctionClass(object.class_id)) {
        if (object.functionSource()) |source| return source.dup();
        return nativeFunctionSourceValue(rt, object);
    }
    return error.TypeError;
}

/// Borrowed-bytes counterpart to `nativeFunctionNameForVm`. Returns the
/// internal dispatch-name bytes when available; otherwise falls back to
/// the visible `name` property and returns that string value as the owner.
/// Callers may always `free(name_value, rt)` after the slice is no longer
/// needed. Returns `null` if the fallback visible name is absent or stored
/// as utf16 (in which case callers fall back to the allocating path).
///
/// The hot dispatch loop in `qjs_vm.zig` calls this many millions of times
/// in tight builtin-dispatch loops; avoiding the per-call `ArrayList(u8)` alloc and
/// `toOwnedSlice` here removes ~5µs from every native-function call on
/// the latin1 fast path.
pub fn nativeFunctionDispatchNameRef(
    rt: *core.JSRuntime,
    function_object: *core.Object,
) ?struct { name: []const u8, name_value: core.JSValue } {
    const dispatch_atom = function_object.nativeDispatchName();
    if (dispatch_atom != core.atom.null_atom) {
        if (rt.atoms.name(dispatch_atom)) |bytes| {
            return .{ .name = bytes, .name_value = core.JSValue.undefinedValue() };
        }
    }
    const name_value = function_object.getProperty(core.atom.ids.name);
    if (!name_value.isString()) {
        name_value.free(rt);
        return null;
    }
    const bytes = stringLatin1BytesRef(name_value) orelse {
        name_value.free(rt);
        return null;
    };
    return .{ .name = bytes, .name_value = name_value };
}

/// Borrow latin1 bytes from a string `JSValue` without copying. Returns
/// `null` if the value is not a latin1 string (utf16 strings carry no
/// usable byte slice for ASCII-only dispatch comparisons).
fn stringLatin1BytesRef(value: core.JSValue) ?[]const u8 {
    const string_value = value.asStringBody() orelse return null;
    return switch (string_value.resolveData()) {
        .latin1 => |bytes| bytes,
        .utf16 => null,
    };
}

fn nativeFunctionDispatchName(rt: *core.JSRuntime, function_object: *core.Object) ![]u8 {
    const dispatch_atom = function_object.nativeDispatchName();
    if (dispatch_atom != core.atom.null_atom) {
        if (rt.atoms.name(dispatch_atom)) |bytes| {
            return try rt.memory.allocator.dupe(u8, bytes);
        }
    }
    const name_value = try nativeFunctionNameValue(rt, function_object, true);
    defer name_value.free(rt);
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &buffer, name_value);
    return buffer.toOwnedSlice(rt.memory.allocator);
}

fn nativeFunctionNameValue(rt: *core.JSRuntime, function_object: *core.Object, prefer_dispatch_name: bool) !core.JSValue {
    if (prefer_dispatch_name) return call_runtime.nativeFunctionNameValueLocal(rt, function_object);
    const name_value = function_object.getProperty(core.atom.ids.name);
    if (!name_value.isString()) {
        name_value.free(rt);
        return error.TypeError;
    }
    return name_value;
}

const functionBytecodeFromValue = call_runtime.functionBytecodeFromValue;

fn functionBytecodeToStringValue(
    rt: *core.JSRuntime,
    bytecode: *const function_bytecode.FunctionBytecode,
    object: ?*core.Object,
) !core.JSValue {
    if (bytecode.source) |source| return value_ops.createStringValue(rt, source);
    if (object) |function_object| {
        if (function_object.functionSource()) |source| return source.dup();
        return nativeFunctionSourceValue(rt, function_object);
    }
    return nativeFunctionSourceValue(rt, null);
}

fn nativeFunctionSourceValue(rt: *core.JSRuntime, object: ?*core.Object) !core.JSValue {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try buffer.appendSlice(rt.memory.allocator, "function");
    if (object) |function_object| {
        const name_value = nativeFunctionNameValue(rt, function_object, false) catch null;
        if (name_value) |stored_name| {
            defer stored_name.free(rt);
            try appendNativeFunctionSourceName(rt, &buffer, stored_name);
        }
    }
    try buffer.appendSlice(rt.memory.allocator, "() {\n    [native code]\n}");
    return value_ops.createStringValue(rt, buffer.items);
}

fn appendNativeFunctionSourceName(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), stored_name: core.JSValue) !void {
    var name_buffer = std.ArrayList(u8).empty;
    defer name_buffer.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &name_buffer, stored_name);

    const source_name = nativeFunctionSourceName(name_buffer.items) orelse return;
    try buffer.append(rt.memory.allocator, ' ');
    try buffer.appendSlice(rt.memory.allocator, source_name);
}

fn nativeFunctionSourceName(name: []const u8) ?[]const u8 {
    if (name.len == 0) return name;
    if (std.mem.startsWith(u8, name, "get ")) {
        const property_name = name["get ".len..];
        return if (isNativeFunctionPropertyName(property_name)) name else "get";
    }
    if (std.mem.startsWith(u8, name, "set ")) {
        const property_name = name["set ".len..];
        return if (isNativeFunctionPropertyName(property_name)) name else "set";
    }
    return if (isNativeFunctionPropertyName(name)) name else null;
}

fn isNativeFunctionPropertyName(name: []const u8) bool {
    return call_runtime.isSimpleIdentifierName(name) or isNativeFunctionComputedPropertyName(name);
}

fn isNativeFunctionComputedPropertyName(name: []const u8) bool {
    if (name.len < 2 or name[0] != '[') return false;

    var index: usize = 1;
    var depth: usize = 1;
    var quote: u8 = 0;
    var escaped = false;
    while (index < name.len) : (index += 1) {
        const ch = name[index];
        if (quote != 0) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == quote) {
                quote = 0;
            } else if (ch == '\n' or ch == '\r') {
                return false;
            }
            continue;
        }

        switch (ch) {
            '\'', '"' => quote = ch,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return index == name.len - 1;
            },
            else => {},
        }
    }
    return false;
}

fn isFunctionToStringCallable(value: core.JSValue) bool {
    if (value.isFunctionBytecode()) return true;
    const object = thisObject(value) orelse return false;
    if (object.class_id == core.class.ids.bytecode_function or isFunctionClass(object.class_id)) return true;
    if (!object.flags.is_proxy or object.proxyHandler() == null) return false;
    const target = object.proxyTarget() orelse return false;
    return isFunctionToStringCallable(target);
}

pub fn thisObject(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

const constructorNameEql = call_runtime.constructorNameEqlLocal;

pub fn constructorPrototype(rt: *core.JSRuntime, object: *core.Object) ?*core.Object {
    const prototype_value = object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    if (!prototype_value.isObject()) return null;
    const header = prototype_value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn hostOutputValues(rt: *core.JSRuntime, output: ?*std.Io.Writer, values: []const core.JSValue) HostError!core.JSValue {
    if (output) |writer| {
        var i: usize = 0;
        while (i < values.len) : (i += 1) {
            if (i != 0) try writer.writeByte(' ');
            try hostResult(printValue(rt, writer, values[i]));
        }
        try writer.writeByte('\n');
    }
    return core.JSValue.undefinedValue();
}

var output_external_host_context: u8 = 0;

fn registerOutputExternalHostFunction(rt: *core.JSRuntime) !u32 {
    return rt.registerExternalHostFunction(.{
        .ptr = @ptrCast(&output_external_host_context),
        .call = externalHostOutput,
    });
}

pub fn isOutputExternalHostFunction(rt: *core.JSRuntime, object: *const core.Object) bool {
    if (object.hostFunctionKind() != core.host_function.ids.external_host) return false;
    return isOutputExternalHostFunctionId(rt, object.externalHostFunctionId());
}

pub fn isOutputExternalHostFunctionId(rt: *core.JSRuntime, id: u32) bool {
    const record = rt.externalHostFunction(id) orelse return false;
    return record.ptr == @as(*anyopaque, @ptrCast(&output_external_host_context)) and record.call == externalHostOutput;
}

fn externalHostOutput(_: *anyopaque, call: core.host_function.ExternalCall) anyerror!core.JSValue {
    const ctx: *core.JSContext = @ptrCast(@alignCast(call.ctx));
    return hostOutputValues(ctx.runtime, call.output, call.args);
}

fn hostCallOutput(call: HostCall) HostError!core.JSValue {
    return hostOutputValues(call.ctx.runtime, call.output, call.args);
}

pub fn runNextOsSignalHandler(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) HostError!bool {
    if (ctx.hostEventLoop()) |host_event_loop| {
        return host_event_loop.runNextSignalHandler(ctx, output, global) catch |err| return @errorCast(err);
    }
    return false;
}

fn hostIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn performanceNowMs() f64 {
    const ns = std.Io.Clock.Timestamp.now(hostIo(), .awake).raw.toNanoseconds();
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn globalBtoa(ctx: *core.JSContext, global: ?*core.Object, args: []const core.JSValue) !core.JSValue {
    const input_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = try value_ops.toStringValue(ctx.runtime, input_value);
    defer string_value.free(ctx.runtime);
    var bytes = stringToLatin1Bytes(ctx.runtime, string_value, 0xff) catch |err| switch (err) {
        error.InvalidCharacter => return throwInvalidCharacter(ctx, global, "String contains an invalid character"),
        else => |other| return other,
    };
    defer bytes.deinit(ctx.runtime.memory.allocator);
    var encoded = try hostResult(array_ops.encodeBase64Bytes(ctx.runtime, bytes.items, .base64, false));
    defer encoded.deinit(ctx.runtime.memory.allocator);
    return value_ops.createStringValue(ctx.runtime, encoded.items);
}

fn globalAtob(ctx: *core.JSContext, global: ?*core.Object, args: []const core.JSValue) !core.JSValue {
    const input_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = try value_ops.toStringValue(ctx.runtime, input_value);
    defer string_value.free(ctx.runtime);
    var bytes = stringToLatin1Bytes(ctx.runtime, string_value, 0x7f) catch |err| switch (err) {
        error.InvalidCharacter => return throwInvalidCharacter(ctx, global, "The string to be decoded is not correctly encoded"),
        else => |other| return other,
    };
    defer bytes.deinit(ctx.runtime.memory.allocator);
    var decoded = array_ops.decodeBase64Bytes(ctx.runtime, bytes.items, .base64, .loose) catch |err| switch (err) {
        error.SyntaxError => return throwInvalidCharacter(ctx, global, "The string to be decoded is not correctly encoded"),
        else => |other| return other,
    };
    defer decoded.deinit(ctx.runtime.memory.allocator);
    const string = try core.string.String.createAscii(ctx.runtime, decoded.items);
    return string.value();
}

const Latin1StringError = error{ InvalidCharacter, TypeError } || std.mem.Allocator.Error;

fn stringToLatin1Bytes(rt: *core.JSRuntime, value: core.JSValue, max_unit: u16) Latin1StringError!std.ArrayList(u8) {
    const string_value = value.asStringBody() orelse return error.TypeError;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(rt.memory.allocator);
    try string_value.ensureFlat(rt);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| {
            for (bytes) |byte| {
                if (byte > max_unit) return error.InvalidCharacter;
            }
            try out.appendSlice(rt.memory.allocator, bytes);
        },
        .utf16 => |units| {
            try out.ensureTotalCapacity(rt.memory.allocator, units.len);
            for (units) |unit| {
                if (unit > max_unit) return error.InvalidCharacter;
                out.appendAssumeCapacity(@intCast(unit));
            }
        },
    }
    return out;
}

fn throwInvalidCharacter(ctx: *core.JSContext, global: ?*core.Object, message: []const u8) !core.JSValue {
    const error_global = global orelse ctx.global orelse return error.TypeError;
    const error_value = try createDOMExceptionValue(ctx, error_global, "InvalidCharacterError", message);
    _ = ctx.throwValue(error_value);
    return error.InvalidCharacterError;
}

fn createDOMExceptionValue(ctx: *core.JSContext, global: *core.Object, name: []const u8, message: []const u8) !core.JSValue {
    const rt = ctx.runtime;
    const ctor_key = try rt.internAtom("DOMException");
    defer rt.atoms.free(ctor_key);
    const ctor_value = global.getProperty(ctor_key);
    defer ctor_value.free(rt);
    if (!ctor_value.isObject()) return try hostResult(exception_ops.createNamedError(ctx, global, name, message));
    const proto_value = expectObjectArg(ctor_value) catch return try hostResult(exception_ops.createNamedError(ctx, global, name, message));
    const prototype_value = proto_value.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    const prototype = if (prototype_value.isObject()) expectObjectArg(prototype_value) catch null else null;
    const message_value = try value_ops.createStringValue(rt, message);
    defer message_value.free(rt);
    const name_value = try value_ops.createStringValue(rt, name);
    defer name_value.free(rt);
    return construct_mod.constructDOMExceptionObject(rt, prototype, &.{ message_value, name_value });
}

fn globalQueueMicrotask(ctx: *core.JSContext, global: ?*core.Object, args: []const core.JSValue) !core.JSValue {
    const active_global = global orelse ctx.global orelse return error.TypeError;
    const callback = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (!call_runtime.isCallableValue(callback)) return try hostResult(exception_ops.throwTypeErrorMessage(ctx, active_global, "not a function"));
    try hostResult(call_runtime.enqueuePendingMicrotask(ctx, callback));
    return core.JSValue.undefinedValue();
}

fn globalGc(ctx: *core.JSContext) core.JSValue {
    _ = ctx.runtime.runObjectCycleRemoval();
    return core.JSValue.undefinedValue();
}

fn hostCallDstrGet(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(call_runtime.qjsDestructuringGet(call.ctx, call.output, global, call.args));
}

fn hostCallDstrElide(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(call_runtime.qjsDestructuringElide(call.ctx, call.output, global, call.args));
}

fn hostCallDstrRest(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(call_runtime.qjsDestructuringRest(call.ctx, call.output, global, call.args));
}

fn hostCallDstrObjectRest(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(object_ops.qjsDestructuringObjectRest(call.ctx, call.output, global, call.args));
}

fn hostCallDstrClose(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(call_runtime.qjsDestructuringClose(call.ctx, call.output, global, call.args));
}

fn hostCallDstrRequireIterator(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(call_runtime.qjsDestructuringRequireIterator(call.ctx, call.output, global, call.args));
}

fn hostCallUsingCreateDisposableStack(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(disposable_ops.qjsUsingCreateDisposableStack(call.ctx, global));
}

fn hostCallUsingAddSyncResource(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(disposable_ops.qjsUsingAddSyncResource(call.ctx, call.output, global, call.args));
}

fn hostCallUsingDisposeSyncStack(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(disposable_ops.qjsUsingDisposeSyncStack(call.ctx, call.output, global, call.args));
}

fn hostCallUsingDisposeSyncStackForThrow(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(disposable_ops.qjsUsingDisposeSyncStackForThrow(call.ctx, call.output, global, call.args));
}

fn hostCallUsingCreateAsyncDisposableStack(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(promise_ops.qjsUsingCreateAsyncDisposableStack(call.ctx, global));
}

fn hostCallUsingAddAsyncResource(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(promise_ops.qjsUsingAddAsyncResource(call.ctx, call.output, global, call.args));
}

fn hostCallUsingDisposeAsyncStack(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(promise_ops.qjsUsingDisposeAsyncStack(call.ctx, call.output, global, call.args));
}

fn hostCallUsingDisposeAsyncStackForThrow(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(promise_ops.qjsUsingDisposeAsyncStackForThrow(call.ctx, call.output, global, call.args));
}

fn materializeMappedArgumentsDescriptorValue(
    rt: *core.JSRuntime,
    object: *core.Object,
    key: core.Atom,
    desc: *core.Descriptor,
) void {
    if (desc.kind != .data) return;
    if (object.class_id != core.class.ids.mapped_arguments) return;
    const index = core.array.arrayIndexFromAtom(&rt.atoms, key) orelse return;
    if (index >= object.argumentsVarRefs().len) return;
    const mapped = object.argumentsVarRefs()[index];
    if (mapped.isUninitialized()) return;
    const value = if (varRefCellFromValue(mapped)) |cell|
        cell.varRefValue().dup()
    else
        mapped.dup();
    const old_value = desc.value;
    desc.value = value;
    old_value.free(rt);
    desc.value_present = true;
}

pub fn materializeMappedArgumentsDescriptorValueForVm(
    rt: *core.JSRuntime,
    object: *core.Object,
    key: core.Atom,
    desc: *core.Descriptor,
) !void {
    materializeMappedArgumentsDescriptorValue(rt, object, key, desc);
}

fn varRefCellFromValue(value: core.JSValue) ?*core.VarRef {
    return core.VarRef.fromValue(value);
}

pub fn descriptorFromObject(rt: *core.JSRuntime, object: *core.Object) !core.Descriptor {
    const has_get = try expectedHas(rt, object, "get");
    const has_set = try expectedHas(rt, object, "set");
    const has_value = try expectedHas(rt, object, "value");
    const has_writable = try expectedHas(rt, object, "writable");
    const enumerable = try optionalBoolProperty(rt, object, "enumerable");
    const configurable = try optionalBoolProperty(rt, object, "configurable");
    if (has_get or has_set) {
        const getter = if (has_get) try expectedValue(rt, object, "get") else core.JSValue.undefinedValue();
        errdefer getter.free(rt);
        const setter = if (has_set) try expectedValue(rt, object, "set") else core.JSValue.undefinedValue();
        errdefer setter.free(rt);
        return .{
            .kind = .accessor,
            .getter = getter,
            .setter = setter,
            .enumerable = enumerable,
            .configurable = configurable,
        };
    }
    if (has_value or has_writable) {
        const value = if (has_value) try expectedValue(rt, object, "value") else core.JSValue.undefinedValue();
        errdefer value.free(rt);
        return .{
            .kind = .data,
            .value = value,
            .value_present = has_value,
            .writable = try optionalBoolProperty(rt, object, "writable"),
            .enumerable = enumerable,
            .configurable = configurable,
        };
    }
    return core.Descriptor.generic(enumerable, configurable);
}

fn descriptorObject(rt: *core.JSRuntime, desc: core.Descriptor) !core.JSValue {
    var desc_value = desc.value;
    var desc_getter = desc.getter;
    var desc_setter = desc.setter;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &desc_value },
        .{ .value = &desc_getter },
        .{ .value = &desc_setter },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const object = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    if (desc.kind == .data) try defineObjectProperty(rt, object, "value", desc_value);
    if (desc.kind == .accessor) {
        try defineObjectProperty(rt, object, "get", desc_getter);
        try defineObjectProperty(rt, object, "set", desc_setter);
    }
    if (desc.writable) |flag| try defineBoolProperty(rt, object, "writable", flag);
    if (desc.enumerable) |flag| try defineBoolProperty(rt, object, "enumerable", flag);
    if (desc.configurable) |flag| try defineBoolProperty(rt, object, "configurable", flag);
    return object.value();
}

test "descriptorObject roots direct symbol value while creating descriptor object" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-call-descriptor-object-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const symbol_value = try rt.symbolValue(symbol_atom);
    const descriptor_value = try descriptorObject(
        rt,
        core.Descriptor.data(symbol_value, true, true, true),
    );
    var descriptor_alive = true;
    defer if (descriptor_alive) descriptor_value.free(rt);
    const descriptor = thisObject(descriptor_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_key = try rt.internAtom("value");
    defer rt.atoms.free(value_key);
    {
        const stored = descriptor.getProperty(value_key);
        defer stored.free(rt);
        try std.testing.expect(stored.same(symbol_value));
    }

    descriptor_value.free(rt);
    descriptor_alive = false;
    symbol_value.free(rt);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn expectedHas(rt: *core.JSRuntime, object: *core.Object, name: []const u8) !bool {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    return object.hasProperty(key);
}

fn expectedValue(rt: *core.JSRuntime, object: *core.Object, name: []const u8) !core.JSValue {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    return object.getProperty(key);
}

fn optionalBoolProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8) !?bool {
    if (!try expectedHas(rt, object, name)) return null;
    const value = try expectedValue(rt, object, name);
    defer value.free(rt);
    return value.asBool() orelse false;
}

fn definePropertiesFromObject(rt: *core.JSRuntime, object: *core.Object, properties_value: core.JSValue) !void {
    const properties = try expectObjectArg(properties_value);
    const keys = try properties.ownKeys(rt);
    defer core.Object.freeKeys(rt, keys);
    for (keys) |key| {
        const desc_value = properties.getProperty(key);
        defer desc_value.free(rt);
        if (desc_value.isUndefined()) continue;
        const desc_object = try expectObjectArg(desc_value);
        const desc = try descriptorFromObject(rt, desc_object);
        defer desc.destroy(rt);
        object.defineOwnProperty(rt, key, desc) catch |err| switch (err) {
            error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
            error.InvalidLength => return error.RangeError,
            else => return err,
        };
    }
}

fn atomFromPropertyKey(rt: *core.JSRuntime, value: core.JSValue) HostError!core.Atom {
    return try hostResult(property_ops.propertyKeyAtom(rt, value));
}

fn atomToStringValue(rt: *core.JSRuntime, atom_id: core.Atom) !core.JSValue {
    return rt.atoms.toStringValue(rt, atom_id);
}

fn defineBoolProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: bool) !void {
    try defineObjectProperty(rt, object, name, core.JSValue.boolean(value));
}

pub fn expectObjectArg(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}

pub fn errorNameMatchesConstructorForVm(err: anytype, constructor_name: []const u8) bool {
    return errorNameMatchesConstructor(err, constructor_name);
}

fn errorNameMatchesConstructor(err: anytype, constructor_name: []const u8) bool {
    const err_name = @errorName(err);
    return (std.mem.eql(u8, err_name, "TypeError") and std.mem.eql(u8, constructor_name, "TypeError")) or
        (std.mem.eql(u8, err_name, "SyntaxError") and std.mem.eql(u8, constructor_name, "SyntaxError")) or
        (std.mem.eql(u8, err_name, "RangeError") and std.mem.eql(u8, constructor_name, "RangeError")) or
        (std.mem.eql(u8, err_name, "EvalError") and std.mem.eql(u8, constructor_name, "EvalError")) or
        (std.mem.eql(u8, err_name, "ReferenceError") and std.mem.eql(u8, constructor_name, "ReferenceError"));
}

fn runtimeErrorName(err: anytype) []const u8 {
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "TypeError")) return "TypeError";
    if (std.mem.eql(u8, name, "RangeError")) return "RangeError";
    if (std.mem.eql(u8, name, "ReferenceError")) return "ReferenceError";
    if (std.mem.eql(u8, name, "SyntaxError")) return "SyntaxError";
    if (std.mem.eql(u8, name, "URIError") or std.mem.eql(u8, name, "InvalidUtf8")) return "URIError";
    return "Error";
}

fn printArray(rt: *core.JSRuntime, writer: *std.Io.Writer, object: *core.Object) PrintError!void {
    var index: u32 = 0;
    while (index < object.arrayLength()) : (index += 1) {
        if (index != 0) try writer.writeByte(',');
        const value = object.getProperty(core.atom.atomFromUInt32(index));
        defer value.free(rt);
        try printValue(rt, writer, value);
    }
}

fn printString(rt: *core.JSRuntime, writer: *std.Io.Writer, value: core.JSValue) !void {
    const string_value = value.asStringBody() orelse return writer.writeAll("[string]");
    try string_value.ensureFlat(rt);
    switch (string_value.resolveData()) {
        // latin1 is ISO-8859-1 (each byte is a U+0000..U+00FF code point), so a
        // byte 0x80..0xFF must be UTF-8-encoded (2 bytes), not written raw —
        // otherwise `console.log(String.fromCharCode(0xC9))` emits an invalid
        // byte instead of `É`. ASCII runs are written in bulk.
        .latin1 => |bytes| {
            var start: usize = 0;
            var i: usize = 0;
            while (i < bytes.len) : (i += 1) {
                const byte = bytes[i];
                if (byte >= 0x80) {
                    if (i > start) try writer.writeAll(bytes[start..i]);
                    try writer.writeAll(&[_]u8{ 0xc0 | (byte >> 6), 0x80 | (byte & 0x3f) });
                    start = i + 1;
                }
            }
            if (bytes.len > start) try writer.writeAll(bytes[start..]);
        },
        .utf16 => |units| {
            var it = std.unicode.Utf16LeIterator.init(units);
            while (it.nextCodepoint() catch null) |codepoint| {
                var utf8_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch continue;
                try writer.writeAll(utf8_buf[0..len]);
            }
        },
    }
}

fn isFunctionClass(class_id: core.ClassId) bool {
    return class_id == core.class.ids.c_function or
        class_id == core.class.ids.bytecode_function or
        class_id == core.class.ids.bound_function or
        class_id == core.class.ids.c_function_data or
        class_id == core.class.ids.c_closure;
}

fn printNativeFunction(rt: *core.JSRuntime, writer: *std.Io.Writer, object: *core.Object) !void {
    if (object.functionSource()) |source| {
        try printString(rt, writer, source);
        return;
    }

    const name_key = try rt.internAtom("name");
    defer rt.atoms.free(name_key);
    const name_value = object.getProperty(name_key);
    defer name_value.free(rt);

    try writer.print("function ", .{});
    if (name_value.isString()) try printString(rt, writer, name_value);
    try writer.print("() {{\n    [native code]\n}}", .{});
}

pub fn qjsEvalGlobalScriptSource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source: []const u8,
    filename: []const u8,
) !core.JSValue {
    const frontend = @import("../frontend/root.zig");
    const stack_mod = @import("stack.zig");
    const zjs_vm = @import("zjs_vm.zig");

    const context_global = ctx.global;
    const use_global_lexicals = context_global == null or context_global.? != global;
    const keep_active_lexicals = context_global == null;
    const saved_lexicals = ctx.lexicals;
    if (use_global_lexicals) ctx.lexicals = global.globalLexicals();

    const EvalResult = @typeInfo(@TypeOf(qjsEvalGlobalScriptSource)).@"fn".return_type.?;
    const result: EvalResult = blk: {
        var compiled = frontend.parser.parse(ctx.runtime, source, .{ .mode = .script, .filename = filename, .strict = false, .return_completion = true }) catch |err| break :blk err;
        defer compiled.deinit();
        if (compiled.syntax_error != null) break :blk error.SyntaxError;
        var nested_stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.runtime.stack_size);
        defer nested_stack.deinit(ctx.runtime);
        break :blk zjs_vm.runWithArgsState(ctx, &nested_stack, &compiled.function, global.value(), &.{}, &.{}, output, global, true, false, false, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, null, null, null, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), false, false, core.JSValue.undefinedValue(), true, false) catch |err| exception_ops.normalizeEvalRuntimeError(err);
    };

    if (use_global_lexicals) {
        var rooted_result = result catch |err| {
            try restoreEvalGlobalLexicals(ctx, global, saved_lexicals, keep_active_lexicals);
            return err;
        };
        errdefer rooted_result.free(ctx.runtime);
        var root_values = [_]core.runtime.ValueRootValue{
            .{ .value = &rooted_result },
        };
        const root_frame = core.runtime.ValueRootFrame{
            .previous = ctx.runtime.active_value_roots,
            .values = &root_values,
        };
        ctx.runtime.active_value_roots = &root_frame;
        defer ctx.runtime.active_value_roots = root_frame.previous;
        try restoreEvalGlobalLexicals(ctx, global, saved_lexicals, keep_active_lexicals);
        return rooted_result;
    }
    return result;
}
