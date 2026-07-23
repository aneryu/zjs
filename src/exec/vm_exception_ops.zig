const std = @import("std");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const error_stack_ops = @import("error_stack_ops.zig");
const exceptions = @import("exceptions.zig");
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const value_ops = @import("value_ops.zig");

const SourceLocation = core.BacktraceLocation;

pub const ErrorInfo = struct { name: []const u8, message: []const u8 };

/// Construct a named error from `global`'s constructor for `name` and
/// capture its `.stack` call sites from the current VM backtrace. This is
/// the single construction primitive for engine-thrown named errors; the
/// stack capture lives here so every construction site gets it (QuickJS
/// runs `build_backtrace` inside the `JS_ThrowError2` choke point). Paths
/// that must not capture a stack go through `createNamedErrorWithoutStack`
/// and are documented there.
pub fn createNamedError(ctx: *core.JSContext, global: *core.Object, name: []const u8, message: []const u8) !core.JSValue {
    const error_value = try createNamedErrorWithoutStack(ctx.runtime, global, name, message);
    errdefer error_value.free(ctx.runtime);
    try error_stack_ops.attachStackToErrorValue(ctx, global, error_value);
    return error_value;
}

/// `createNamedError` for a directly supplied constructor value (used for
/// realm-specific intrinsic constructors); also captures `.stack` at
/// construction. `global` only drives the stack capture policy
/// (`Error.stackTraceLimit` and the CallSite array prototype).
pub fn createNamedErrorWithConstructor(ctx: *core.JSContext, global: *core.Object, ctor_value: core.JSValue, name: []const u8, message: []const u8) !core.JSValue {
    const error_value = try buildNamedErrorObject(ctx.runtime, ctor_value, name, message);
    errdefer error_value.free(ctx.runtime);
    try error_stack_ops.attachStackToErrorValue(ctx, global, error_value);
    return error_value;
}

/// Construct a named error directly on a realm-owned native-error prototype.
/// This is the QuickJS `ctx->native_error_proto[]` path: mutable constructor
/// bindings and receiver objects do not participate in Realm selection.
pub fn createNamedErrorWithPrototype(ctx: *core.JSContext, global: *core.Object, prototype: *core.Object, name: []const u8, message: []const u8) !core.JSValue {
    var rooted_prototype = prototype.value().dup();
    defer rooted_prototype.free(ctx.runtime);
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_prototype },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const rooted_object = property_ops.expectObject(rooted_prototype) catch return error.InvalidBuiltinRegistry;
    const object = try core.Object.create(ctx.runtime, core.class.ids.error_, rooted_object);
    const error_value = object.value();
    errdefer error_value.free(ctx.runtime);
    const message_value = try value_ops.createStringValue(ctx.runtime, message);
    defer message_value.free(ctx.runtime);
    try defineNonEnumValueProperty(ctx.runtime, object, "message", message_value);
    try error_stack_ops.attachStackToErrorValue(ctx, global, error_value);
    _ = name;
    return error_value;
}

/// Raw, stack-less variant of `createNamedError`. Every user-observable
/// throw path must construct through the stack-attaching primitives above.
/// The only allowed uses of this entry are:
/// - the preallocated out-of-memory error (`JSRuntime.preallocated_oom_error`):
///   it is built once at startup while memory is plentiful and delivered via
///   an allocation-free `dup()` once the heap is exhausted, so it can neither
///   capture a meaningful backtrace at construction time nor allocate one at
///   delivery time (QuickJS likewise skips the backtrace for its preallocated
///   OOM exception);
/// - the embedding API `JSContext.createError` when the embedder explicitly
///   opts out via `ErrorOptions.capture_stack = false`.
pub fn createNamedErrorWithoutStack(rt: *core.JSRuntime, global: *core.Object, name: []const u8, message: []const u8) !core.JSValue {
    const ctor_key = try rt.internAtom(name);
    defer rt.atoms.free(ctor_key);
    const ctor_value = try global.getProperty(ctor_key);
    defer ctor_value.free(rt);
    return buildNamedErrorObject(rt, ctor_value, name, message);
}

/// Build the runtime's preallocated OOM catch value. Unlike normal named
/// errors, this stores an own `name`: the delivery path must remain
/// allocation-free even if `InternalError.prototype.name` has not been
/// materialized from its lazy builtin string placeholder.
pub fn createPreallocatedOutOfMemoryError(rt: *core.JSRuntime, global: *core.Object) !core.JSValue {
    const error_value = try createNamedErrorWithoutStack(rt, global, "InternalError", "out of memory");
    errdefer error_value.free(rt);
    const error_object = objectFromValue(error_value) orelse return error.TypeError;
    const name_value = try value_ops.createStringValue(rt, "InternalError");
    defer name_value.free(rt);
    try defineNonEnumValueProperty(rt, error_object, "name", name_value);
    return error_value;
}

fn buildNamedErrorObject(rt: *core.JSRuntime, ctor_value: core.JSValue, name: []const u8, message: []const u8) !core.JSValue {
    var rooted_ctor_value = ctor_value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_ctor_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const object = try core.Object.create(rt, core.class.ids.error_, null);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    // Mirror JS_ThrowError2 (quickjs.c:7637-7658): the thrown error carries a
    // single own `message` data property (JS_PROP_WRITABLE|JS_PROP_CONFIGURABLE,
    // non-enumerable); `name`/`constructor` resolve through the prototype
    // installed below (qjs allocates directly on ctx->native_error_proto[]).
    const message_value = try value_ops.createStringValue(rt, message);
    defer message_value.free(rt);
    try defineNonEnumValueProperty(rt, object, "message", message_value);
    var prototype_installed = false;
    if (rooted_ctor_value.isObject()) {
        const ctor = property_ops.expectObject(rooted_ctor_value) catch null;
        if (ctor) |ctor_object| {
            const proto_value = try ctor_object.getProperty(core.atom.ids.prototype);
            defer proto_value.free(rt);
            if (proto_value.isObject()) {
                const proto = property_ops.expectObject(proto_value) catch null;
                if (proto) |prototype| {
                    try object.setPrototype(rt, prototype);
                    prototype_installed = true;
                }
            }
        }
    }
    if (!prototype_installed) {
        // Degraded fallback for names with no realm constructor (e.g. the
        // zjs-specific InvalidCharacterError): keep a self-describing own
        // `name` so `e.name` still identifies the error class. qjs cannot
        // reach this state — every JSErrorEnum has a native_error_proto.
        const name_value = try value_ops.createStringValue(rt, name);
        defer name_value.free(rt);
        try defineNonEnumValueProperty(rt, object, "name", name_value);
    }
    return object.value();
}

test "buildNamedErrorObject roots direct symbol constructor while creating error object" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-error-constructor-symbol");
    const ctor_value = try rt.symbolValue(symbol_atom);
    var ctor_alive = true;
    defer if (ctor_alive) ctor_value.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const error_value = try buildNamedErrorObject(rt, ctor_value, "TypeError", "boom");
    var error_alive = true;
    defer if (error_alive) error_value.free(rt);
    const object = try property_ops.expectObject(error_value);

    // The ctor value stays rooted across the allocating construction even
    // though it is no longer stored as an own `constructor` property
    // (JS_ThrowError2 discipline: only `message` is an own property).
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const message_key = try rt.internAtom("message");
    defer rt.atoms.free(message_key);
    {
        const stored = try object.getProperty(message_key);
        defer stored.free(rt);
        try std.testing.expect(stored.isString());
    }
    const constructor_key = try rt.internAtom("constructor");
    defer rt.atoms.free(constructor_key);
    {
        const stored = try object.getProperty(constructor_key);
        defer stored.free(rt);
        try std.testing.expect(!stored.same(ctor_value));
    }
    // Non-object ctor (symbol) => no prototype; the degraded fallback stamps
    // an own self-describing `name`.
    const name_key = try rt.internAtom("name");
    defer rt.atoms.free(name_key);
    {
        const stored = try object.getProperty(name_key);
        defer stored.free(rt);
        try std.testing.expect(stored.isString());
    }
    ctor_value.free(rt);
    ctor_alive = false;

    error_value.free(rt);
    error_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

/// Throw the canonical `ReferenceError` for a TDZ violation.
/// Returns `error.ReferenceError` to align with the VM sentinel convention.
pub fn throwTdzReference(ctx: *core.JSContext) error{ReferenceError} {
    const global = ctx.global orelse {
        throwReferenceErrorSentinel(ctx);
        return error.ReferenceError;
    };
    // QuickJS constructs engine-thrown errors directly on the current
    // realm's native_error_proto[] entry. A self-describing null-prototype
    // object is sufficient for runner name matching but fails observable
    // `instanceof ReferenceError`, so use the realm-owned intrinsic rather
    // than the mutable global constructor binding.
    const prototype = ctx.nativeErrorPrototypeObject(.reference_error) orelse {
        throwReferenceErrorSentinel(ctx);
        return error.ReferenceError;
    };
    const error_value = createNamedErrorWithPrototype(
        ctx,
        global,
        prototype,
        "ReferenceError",
        "Cannot access 'x' before initialization",
    ) catch {
        // Preserve the allocation-failure-hardened TDZ path. The caller still
        // receives the ReferenceError sentinel and can materialize or replace
        // it at its existing exception boundary.
        throwReferenceErrorSentinel(ctx);
        return error.ReferenceError;
    };
    _ = ctx.throwValue(error_value);
    return error.ReferenceError;
}

pub fn normalizeEvalRuntimeError(err: anytype) (@TypeOf(err) || error{TypeError}) {
    return switch (err) {
        error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => error.TypeError,
        else => err,
    };
}

pub fn runtimeErrorValueForGeneratorCatch(ctx: *core.JSContext, global: *core.Object, err: anytype) !core.JSValue {
    if (pendingExceptionMatchesError(ctx, err)) return ctx.takeException();
    const value = switch (@as(anyerror, err)) {
        error.TypeError => try createNamedError(ctx, global, "TypeError", ""),
        error.RangeError => try createNamedError(ctx, global, "RangeError", ""),
        error.ReferenceError => try createNamedError(ctx, global, "ReferenceError", "not defined"),
        error.SyntaxError => try createNamedError(ctx, global, "SyntaxError", "invalid syntax"),
        else => {
            if (ctx.hasException()) ctx.clearException();
            return err;
        },
    };
    if (ctx.hasException()) ctx.clearException();
    return value;
}

/// Internally built AggregateError for Promise.any/allSettled rejection.
/// Mirrors js_aggregate_error_constructor (quickjs.c:41582): a bare
/// error-class object on AggregateError.prototype whose only own property is
/// `errors` (JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE, non-enumerable) — no
/// own `message`/`name`. qjs does not run build_backtrace here either; zjs
/// still snapshots the call sites because its lazy `stack` accessor would
/// otherwise rebuild a backtrace from whichever context first reads it.
pub fn qjsPromiseAggregateError(ctx: *core.JSContext, global: *core.Object, errors: *core.Object) !core.JSValue {
    const rt = ctx.runtime;
    const ctor_key = try rt.internAtom("AggregateError");
    defer rt.atoms.free(ctor_key);
    const ctor_value = try global.getProperty(ctor_key);
    defer ctor_value.free(rt);

    const object = try core.Object.create(rt, core.class.ids.error_, null);
    const aggregate_error = object.value();
    errdefer aggregate_error.free(rt);
    if (ctor_value.isObject()) {
        if (property_ops.expectObject(ctor_value) catch null) |ctor_object| {
            const proto_value = try ctor_object.getProperty(core.atom.ids.prototype);
            defer proto_value.free(rt);
            if (proto_value.isObject()) {
                if (property_ops.expectObject(proto_value) catch null) |prototype| {
                    try object.setPrototype(rt, prototype);
                }
            }
        }
    }
    try defineNonEnumValueProperty(rt, object, "errors", errors.value());
    try error_stack_ops.attachStackToErrorValue(ctx, global, aggregate_error);
    return aggregate_error;
}

pub fn qjsPromiseErrorValue(ctx: *core.JSContext, global: *core.Object, err: anytype) exceptions.HostError!core.JSValue {
    if (pendingExceptionMatchesError(ctx, err)) return ctx.takeException();
    const error_info = promiseErrorInfo(err);
    return createNamedError(ctx, global, error_info.name, error_info.message) catch |create_err| {
        // Promise jobs must be able to retain an abrupt completion after user
        // code has run. Under a fully exhausted heap, use the same allocation-
        // free OOM value as VM catch delivery so the job can advance to its
        // rejection phase instead of either disappearing or invoking user code
        // a second time on retry.
        if (create_err == error.OutOfMemory) {
            if (ctx.preallocated_oom_error) |preallocated| return preallocated.dup();
            // Construction-only/bare contexts may not yet have installed the
            // zjs preallocated safety object. Match QuickJS's recursive-OOM
            // escape hatch: retain a non-allocating null abrupt value rather
            // than losing an already-started Promise job.
            return core.JSValue.nullValue();
        }
        return @errorCast(create_err);
    };
}

pub fn rejectedPromiseForRuntimeError(
    ctx: *core.JSContext,
    global: *core.Object,
    err: anytype,
    prototype: ?*core.Object,
) !core.JSValue {
    if (pendingExceptionMatchesError(ctx, err)) {
        const thrown_value = ctx.runtime.current_exception;
        const promise = try core.promise.rejectedWithPrototype(ctx, thrown_value, prototype);
        ctx.clearException();
        return promise;
    }
    const error_info = runtimeErrorInfo(err) orelse return err;
    const error_value = try createNamedError(ctx, global, error_info.name, error_info.message);
    defer error_value.free(ctx.runtime);
    const promise = try core.promise.rejectedWithPrototype(ctx, error_value, prototype);
    if (ctx.hasException()) ctx.clearException();
    return promise;
}

/// Throw a `TypeError` with `message`: construct (stack attached by the
/// primitive), set the context exception, and return the VM sentinel.
pub fn throwTypeErrorMessage(ctx: *core.JSContext, global: *core.Object, message: []const u8) !core.JSValue {
    const error_value = try createNamedError(ctx, global, "TypeError", message);
    _ = ctx.throwValue(error_value);
    return error.TypeError;
}

pub fn throwRangeErrorMessage(ctx: *core.JSContext, global: *core.Object, message: []const u8) !core.JSValue {
    const error_value = try createNamedError(ctx, global, "RangeError", message);
    _ = ctx.throwValue(error_value);
    return error.RangeError;
}

/// Throw an `InternalError` with `message` (mirrors QuickJS `JS_ThrowInternalError`).
pub fn throwInternalErrorMessage(ctx: *core.JSContext, global: *core.Object, message: []const u8) !core.JSValue {
    const error_value = try createNamedError(ctx, global, "InternalError", message);
    _ = ctx.throwValue(error_value);
    return error.StackOverflow;
}

/// QuickJS `JS_ThrowInterrupted`: retain a real InternalError in the polled
/// Realm while making it uncatchable by JavaScript catch markers.
pub fn throwInterrupted(ctx: *core.JSContext, global: *core.Object) !void {
    const error_value = try createNamedError(ctx, global, "InternalError", "interrupted");
    _ = ctx.throwValue(error_value);
    ctx.setExceptionUncatchable(true);
    return error.Interrupted;
}

/// One semantic call/jump poll. Counter ownership and cadence live in the
/// RealmContext; error construction stays in exec because it needs that
/// Realm's InternalError intrinsic.
pub inline fn pollInterrupt(ctx: *core.JSContext, global: *core.Object) !void {
    if (!ctx.pollInterrupt()) return;
    return throwInterrupted(ctx, global);
}

/// Throw `InternalError "stack overflow"` and return the native-recursion
/// sentinel. Mirrors QuickJS `JS_ThrowStackOverflow` (quickjs.c:7789-7791). The
/// `error.StackOverflow` sentinel is mapped back to this InternalError by
/// `runtimeErrorInfo`/`promiseErrorInfo` for any path that does not observe the
/// already-thrown value directly.
pub fn throwStackOverflow(ctx: *core.JSContext, global: *core.Object) !core.JSValue {
    const error_value = try createNamedError(ctx, global, "InternalError", "stack overflow");
    _ = ctx.throwValue(error_value);
    return error.StackOverflow;
}

pub fn throwReferenceErrorMessage(ctx: *core.JSContext, global: *core.Object, message: []const u8) !core.JSValue {
    const error_value = try createNamedError(ctx, global, "ReferenceError", message);
    _ = ctx.throwValue(error_value);
    return error.ReferenceError;
}

pub fn throwSyntaxErrorMessage(ctx: *core.JSContext, global: *core.Object, message: []const u8) !core.JSValue {
    const error_value = try createNamedError(ctx, global, "SyntaxError", message);
    _ = ctx.throwValue(error_value);
    return error.SyntaxError;
}

pub fn isCallSiteObject(rt: *core.JSRuntime, object: *core.Object) bool {
    _ = rt;
    return object.isCallSite();
}

/// CallSite prototype methods dispatched by `.host` native-record id; the
/// receiver must be a CallSite object (the metadata lives in internal slots).
pub fn qjsCallSiteMethodById(rt: *core.JSRuntime, object: *core.Object, id: core.function.HostGlobalMethod) ?core.JSValue {
    if (!isCallSiteObject(rt, object)) return null;
    return switch (id) {
        .callsite_get_function => core.JSValue.nullValue(),
        .callsite_get_function_name => if (object.callSiteFunctionName()) |value| value.dup() else core.JSValue.nullValue(),
        .callsite_get_file_name => if (object.callSiteFile()) |value| value.dup() else core.JSValue.nullValue(),
        .callsite_get_line_number => if (object.callSiteIsNative()) core.JSValue.nullValue() else core.JSValue.int32(object.callSiteLine()),
        .callsite_get_column_number => if (object.callSiteIsNative()) core.JSValue.nullValue() else core.JSValue.int32(object.callSiteColumn()),
        .callsite_is_native => core.JSValue.boolean(object.callSiteIsNative()),
        else => null,
    };
}

pub fn backtraceFunctionNameAtom(ctx: *core.JSContext, fallback: core.Atom, current_function_value: core.JSValue) !core.Atom {
    const function_object = objectFromValue(current_function_value) orelse return ctx.runtime.atoms.dup(fallback);
    const name_desc = (try function_object.getOwnProperty(ctx.runtime, core.atom.ids.name)) orelse return ctx.runtime.atoms.dup(core.atom.ids.empty_string);
    defer name_desc.destroy(ctx.runtime);
    if (name_desc.kind != .data or !name_desc.value.isString()) return ctx.runtime.atoms.dup(core.atom.ids.empty_string);

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendRawString(ctx.runtime, &bytes, name_desc.value);
    return ctx.runtime.atoms.internString(bytes.items);
}

/// Resolve the display name of a backtrace frame, caching the result in
/// place. Frames pushed with a lazy function value defer the `name` property
/// read and atom interning to the first materialization, keeping the per-call
/// hot path free of property lookups and interning.
/// Returns a borrowed atom valid while the frame entry is alive.
pub fn resolvedBacktraceFunctionNameAt(ctx: *core.JSContext, index: usize) core.Atom {
    const frame = &ctx.runtime.backtrace_frames[index];
    return resolveBacktraceFunctionName(ctx, frame);
}

pub fn resolveBacktraceFunctionName(ctx: *core.JSContext, frame: *core.BacktraceFrame) core.Atom {
    const function_value = frame.function_value;
    if (function_value.isUndefined()) return frame.function_name;
    frame.function_value = core.JSValue.undefinedValue();
    defer function_value.free(ctx.runtime);
    const resolved = backtraceFunctionNameAtom(ctx, frame.function_name, function_value) catch ctx.runtime.atoms.dup(core.atom.ids.empty_string);
    ctx.runtime.atoms.free(frame.function_name);
    frame.function_name = resolved;
    return frame.function_name;
}

pub fn resolveBacktraceLocation(data: ?*const anyopaque, target_pc: usize) core.BacktraceLocation {
    const function: *const bytecode.FunctionBytecode = @ptrCast(@alignCast(data orelse return .{ .line_num = 1, .col_num = 1 }));
    if (function.pc2lineBuf().len == 0) {
        return .{ .line_num = function.lineNum(), .col_num = function.colNum() };
    }
    // A present full-debug buffer is authoritative. QuickJS find_line_num
    // returns 0:0 for any malformed header or transition; falling back to a
    // valid header here would conceal a corrupt artifact.
    return sourceLocationFromPc2Line(function, target_pc) orelse .{ .line_num = 0, .col_num = 0 };
}

/// Snapshot one live VM frame for the backtrace walk. The Machine-owned
/// per-invocation resolver (inline_calls.zig) walks the Entry chain + L0 frame
/// directly — faithful to qjs's single
/// `current_stack_frame -> prev_frame` walk (quickjs.c:7571), with no per-call
/// parallel backtrace node.
pub fn frameBacktraceSnapshot(frame: *const frame_mod.Frame) core.ActiveBacktraceSnapshot {
    const function = frame.function;
    return .{
        .function_name = function.funcName(),
        .filename = function.filenameAtom(),
        .line_num = function.lineNum(),
        .col_num = function.colNum(),
        // The published frame.pc is the resume/return address (it points past
        // the currently-executing instruction, like qjs sf->cur_pc). Back off
        // one byte so the line/col lookup lands inside that instruction —
        // mirrors build_backtrace's `sf->cur_pc - b->byte_code_buf - 1`
        // (quickjs.c:7595); without it a frame whose call is the last
        // statement maps past the call (even one line past EOF).
        .pc = frame.pc -| 1,
        .location_data = function,
        .location_resolver = resolveBacktraceLocation,
        .function_value = frame.current_function,
    };
}

pub fn isErrorConstructorName(name: []const u8) bool {
    return core.error_names.isErrorConstructorName(name);
}

pub fn functionNameBytes(rt: *core.JSRuntime, value: core.JSValue) ![]u8 {
    const object = property_ops.expectObject(value) catch return rt.memory.allocator.dupe(u8, "");
    const name_value = try object.getProperty(core.atom.ids.name);
    defer name_value.free(rt);
    if (!name_value.isString()) return rt.memory.allocator.dupe(u8, "");
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &bytes, name_value);
    return rt.memory.allocator.dupe(u8, bytes.items);
}

pub fn pendingExceptionMatchesError(ctx: *core.JSContext, err: anytype) bool {
    if (!ctx.hasException()) return false;
    if (@as(anyerror, err) == error.JSException) return true;
    const expected = errorNameForRuntimeError(err) orelse return false;
    const object = objectFromValue(ctx.runtime.current_exception) orelse return false;
    return objectDataStringPropertyMatches(object, core.atom.ids.name, expected);
}

/// Error dispatch is already handling an abrupt completion, so it cannot
/// allocate merely to materialize the standard lazy `name` string. Walk only
/// data/VARREF facts and immutable string-constant AUTOINIT descriptors; an
/// accessor or other lazy builder is not an authoritative internal error name.
fn objectDataStringPropertyMatches(object: *core.Object, atom_id: core.Atom, expected: []const u8) bool {
    var cursor: ?*core.Object = object;
    while (cursor) |current| : (cursor = current.getPrototype()) {
        const lookup = current.findOwnPropertySlotTrusted(atom_id) orelse continue;
        if (lookup.flags.deleted) continue;
        const value = switch (lookup.flags.kind) {
            .data => lookup.entry.slot.data,
            .var_ref => lookup.entry.slot.var_ref.varRefValue(),
            .auto_init => {
                const info = core.property.autoInit(lookup.entry.slot.auto_init);
                return info.kind == .string_constant and std.mem.eql(u8, info.name, expected);
            },
            .accessor => return false,
        };
        const string = value.asStringBody() orelse return false;
        return stringBodyEqualsAscii(string, expected);
    }
    return false;
}

fn stringBodyEqualsAscii(string: *core.string.String, expected: []const u8) bool {
    switch (string.resolveData()) {
        .latin1 => |bytes| return std.mem.eql(u8, bytes, expected),
        .utf16 => |units| {
            if (units.len != expected.len) return false;
            for (units, expected) |unit, byte| {
                if (unit != byte) return false;
            }
            return true;
        },
    }
}

// Fallback messages for sentinel errors that reach the catch machinery with
// no pending exception object. Throw sites that know the real reason should
// use the message-carrying throw*Message helpers; these defaults must stay
// neutral because they cover every remaining source of the sentinel. The
// URIError text is kept: every URIError sentinel comes from the URI builtins
// and the hex-digit failure is the dominant source (matching the qjs text).
pub fn runtimeErrorInfo(err: anytype) ?ErrorInfo {
    return switch (@as(anyerror, err)) {
        error.URIError, error.InvalidUtf8 => .{ .name = "URIError", .message = "expecting hex digit" },
        // Allocation failure under a memory limit is catchable, mirroring
        // QuickJS's InternalError "out of memory" exception; paths without a
        // JS catch handler still surface error.OutOfMemory to the embedder.
        error.OutOfMemory => .{ .name = "InternalError", .message = "out of memory" },
        // Native C-stack recursion guard (QuickJS JS_ThrowStackOverflow ->
        // InternalError "stack overflow", quickjs.c:7789-7791).
        error.StackOverflow => .{ .name = "InternalError", .message = "stack overflow" },
        error.Interrupted => .{ .name = "InternalError", .message = "interrupted" },
        // JS_STRING_LEN_MAX creation/concat cap (qjs quickjs.c:4078/4368/4655/4898).
        error.StringTooLong => .{ .name = "InternalError", .message = "string too long" },
        // qjs OP_check_ctor_return deliberately creates this TypeError in the
        // constructor's caller context (quickjs.c:18273-18278). Keep a distinct
        // sentinel so the caller frame can materialize the exact message there.
        error.DerivedConstructorReturn => .{ .name = "TypeError", .message = "derived class constructor must return an object or undefined" },
        // qjs OP_get_loc_checkthis likewise uses caller_ctx for the implicit
        // derived-constructor return (quickjs.c:18717-18728).
        error.DerivedThisUninitialized => .{ .name = "ReferenceError", .message = "this is not initialized" },
        error.TypeError => .{ .name = "TypeError", .message = "" },
        // qjs JS_CreateProperty not_extensible (quickjs.c:10144).
        error.NotExtensible => .{ .name = "TypeError", .message = "object is not extensible" },
        error.InvalidCharacterError => .{ .name = "InvalidCharacterError", .message = "" },
        error.SyntaxError => .{ .name = "SyntaxError", .message = "invalid syntax" },
        error.RangeError => .{ .name = "RangeError", .message = "" },
        // qjs js_bigint_new single throw site (quickjs.c:11593-11594).
        error.BigIntTooLarge => .{ .name = "RangeError", .message = "BigInt is too large to allocate" },
        // qjs js_bigint_divrem division-by-zero guard (quickjs.c:11888).
        error.DivisionByZero => .{ .name = "RangeError", .message = "BigInt division by zero" },
        // qjs js_bigint_pow negative-exponent guard (quickjs.c:12113).
        error.NegativeExponent => .{ .name = "RangeError", .message = "BigInt negative exponent" },
        error.ReferenceError => .{ .name = "ReferenceError", .message = "not defined" },
        else => null,
    };
}

pub fn promiseErrorInfo(err: anytype) ErrorInfo {
    return switch (@as(anyerror, err)) {
        error.URIError, error.InvalidUtf8 => .{ .name = "URIError", .message = "expecting hex digit" },
        error.OutOfMemory => .{ .name = "InternalError", .message = "out of memory" },
        error.StackOverflow => .{ .name = "InternalError", .message = "stack overflow" },
        error.StringTooLong => .{ .name = "InternalError", .message = "string too long" },
        error.DerivedConstructorReturn => .{ .name = "TypeError", .message = "derived class constructor must return an object or undefined" },
        error.DerivedThisUninitialized => .{ .name = "ReferenceError", .message = "this is not initialized" },
        error.TypeError => .{ .name = "TypeError", .message = "" },
        error.SyntaxError => .{ .name = "SyntaxError", .message = "invalid syntax" },
        error.RangeError => .{ .name = "RangeError", .message = "" },
        // qjs js_bigint_new single throw site (quickjs.c:11593-11594).
        error.BigIntTooLarge => .{ .name = "RangeError", .message = "BigInt is too large to allocate" },
        // qjs js_bigint_divrem division-by-zero guard (quickjs.c:11888).
        error.DivisionByZero => .{ .name = "RangeError", .message = "BigInt division by zero" },
        // qjs js_bigint_pow negative-exponent guard (quickjs.c:12113).
        error.NegativeExponent => .{ .name = "RangeError", .message = "BigInt negative exponent" },
        error.ReferenceError => .{ .name = "ReferenceError", .message = "not defined" },
        else => .{ .name = "Error", .message = "" },
    };
}

fn errorNameForRuntimeError(err: anytype) ?[]const u8 {
    return switch (@as(anyerror, err)) {
        error.URIError, error.InvalidUtf8 => "URIError",
        error.StackOverflow => "InternalError",
        error.StringTooLong => "InternalError",
        error.DerivedConstructorReturn, error.TypeError => "TypeError",
        error.DerivedThisUninitialized, error.ReferenceError => "ReferenceError",
        error.InvalidCharacterError => "InvalidCharacterError",
        error.SyntaxError => "SyntaxError",
        error.RangeError, error.BigIntTooLarge, error.DivisionByZero, error.NegativeExponent => "RangeError",
        else => null,
    };
}

fn sourceLocationFromPc2Line(function: *const bytecode.FunctionBytecode, target_pc: usize) ?SourceLocation {
    const bytes = function.pc2lineBuf();
    const pc = std.math.cast(u32, target_pc) orelse return null;
    const location = bytecode.pipeline.pc2line.findSourceLocation(bytes, pc) catch return null;
    return .{ .line_num = location.line_num, .col_num = location.col_num };
}

fn objectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn defineValueProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, true, true, true));
}

/// JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE (non-enumerable) data property —
/// the attribute set qjs uses for every own property it defines on error
/// objects (JS_ThrowError2 quickjs.c:7652, js_aggregate_error_constructor
/// quickjs.c:41593).
fn defineNonEnumValueProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, true, false, true));
}

fn throwReferenceErrorSentinel(ctx: *core.JSContext) void {
    const reference_error_atom: u32 = 209;
    _ = ctx.throwValue(core.JSValue.int32(@intCast(reference_error_atom)));
}
