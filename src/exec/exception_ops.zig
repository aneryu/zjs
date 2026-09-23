//! JavaScript Error construction, stack capture, and native-error conversion.
//!
//! Error values returned by constructors are owned; throw helpers transfer one
//! owned value into the runtime's pending-exception slot, while promise-facing
//! conversion can build the same named value without mutating that slot. Only
//! preallocated or explicitly stackless paths omit capture. This centralizes
//! parser, host-I/O, promise, and runtime error policy around QuickJS
//! `JS_ThrowError2` and stack setup at quickjs.c.

const std = @import("std");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");

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
    try attachStackToErrorValue(ctx, global, error_value);
    return error_value;
}

/// Materialize the JS value for an engine sentinel that `runtimeErrorInfo` /
/// `promiseErrorInfo` has already classified.
///
/// Identical to `createNamedError` except for `error.OutOfMemory`, which is
/// delivered as the Realm's preallocated `InternalError: out of memory`
/// instead of building a fresh twin.
///
/// The Realm preallocates that object at bootstrap (`zjs_vm.contextGlobal`)
/// precisely so this delivery costs no allocation. Building a new one here
/// allocates three times -- the Error object, its message string, and its
/// backtrace string -- on the heap that has just refused an allocation.
/// Whether those succeed is a question about allocator luck (a free block
/// still sitting in a slab arena), not about engine state, so the identity of
/// the value a JS `catch` receives for an OOM used to depend on it: a fully
/// exhausted heap delivered `preallocated_oom_error` (every construction site
/// already falls back to it), while a heap that merely refused one request
/// delivered a fresh object. Both spellings of "the same OOM" then existed,
/// and nothing downstream could tell an out-of-memory delivery from a user
/// throw.
///
/// Two contracts in the tree already assume the stable answer: the
/// engine-production pin that OOM delivery to a JS catch allocates nothing
/// (`src/tests/oom_cap.zig`), and the OOM tier's rule that a rethrown OOM is
/// still an OOM rather than an arbitrary user exception
/// (`src/tests/oom.zig`). The OOM tier caught the divergence once its
/// injection reached the allocations the tracing collector had moved out of
/// its view: `native-callback-map-reflect-apply` catches the failure, sees it
/// is not the `RangeError` it expected, and rethrows -- and the rethrown
/// value was a freshly built `InternalError` that no longer identified itself
/// as the injected OOM.
///
/// Deliberately stack-less, by the same exemption `createNamedErrorWithoutStack`
/// documents for this object: a backtrace cannot be captured on an exhausted
/// heap, and the preallocated value is dup()ed, never rebuilt.
pub fn createSentinelError(
    ctx: *core.JSContext,
    global: *core.Object,
    err: anyerror,
    info: ErrorInfo,
) !core.JSValue {
    if (@as(anyerror, err) == error.OutOfMemory) {
        if (ctx.preallocated_oom_error) |preallocated| return preallocated;
    }
    return createNamedError(ctx, global, info.name, info.message);
}

/// Construct a named error directly on a realm-owned native-error prototype.
/// This is the QuickJS `ctx->native_error_proto[]` path: mutable constructor
/// bindings and receiver objects do not participate in Realm selection.
pub fn createNamedErrorWithPrototype(ctx: *core.JSContext, global: *core.Object, prototype: *core.Object, name: []const u8, message: []const u8) !core.JSValue {
    var rooted_prototype = prototype.value();
    var root_frame = core.runtime.rootValues(.{&rooted_prototype});
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    const rooted_object = core.value_semantics.objectFromValue(rooted_prototype) orelse return error.InvalidBuiltinRegistry;
    const object = try core.Object.create(ctx.runtime, core.class.ids.error_, rooted_object);
    const error_value = object.value();
    const message_value = try value_ops.createStringValue(ctx.runtime, message);
    try defineNonEnumValueProperty(ctx.runtime, object, core.atom.ids.message, message_value);
    try attachStackToErrorValue(ctx, global, error_value);
    // No own `name` property: it lives on `prototype`, which the caller has
    // already selected for exactly this name (same rule as
    // `errorConstructWithPrototype`). `name` is kept so the call sites stay
    // self-documenting about which error they are building.
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
    const ctor_value = try global.getProperty(ctor_key);
    return buildNamedErrorObject(rt, ctor_value, name, message);
}

/// Build the runtime's preallocated OOM catch value. Unlike normal named
/// errors, this stores an own `name`: the delivery path must remain
/// allocation-free even if `InternalError.prototype.name` has not been
/// materialized from its lazy builtin string placeholder.
pub fn createPreallocatedOutOfMemoryError(rt: *core.JSRuntime, global: *core.Object) !core.JSValue {
    const error_value = try createNamedErrorWithoutStack(rt, global, "InternalError", "out of memory");
    const error_object = objectFromValue(error_value) orelse return error.TypeError;
    const name_value = try value_ops.createStringValue(rt, "InternalError");
    try defineNonEnumValueProperty(rt, error_object, core.atom.ids.name, name_value);
    return error_value;
}

fn buildNamedErrorObject(rt: *core.JSRuntime, ctor_value: core.JSValue, name: []const u8, message: []const u8) !core.JSValue {
    var rooted_ctor_value = ctor_value;
    var root_frame = core.runtime.rootValues(.{&rooted_ctor_value});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const object = try core.Object.create(rt, core.class.ids.error_, null);
    errdefer core.Object.destroyFromHeader(rt, object.gcHeader());
    // Mirror JS_ThrowError2: the thrown error carries a
    // single own `message` data property (JS_PROP_WRITABLE|JS_PROP_CONFIGURABLE,
    // non-enumerable); `name`/`constructor` resolve through the prototype
    // installed below (qjs allocates directly on ctx->native_error_proto[]).
    const message_value = try value_ops.createStringValue(rt, message);
    try defineNonEnumValueProperty(rt, object, core.atom.ids.message, message_value);
    var prototype_installed = false;
    if (rooted_ctor_value.is(.object)) {
        const ctor = core.value_semantics.objectFromValue(rooted_ctor_value);
        if (ctor) |ctor_object| {
            const proto_value = try ctor_object.getProperty(core.atom.ids.prototype);
            if (proto_value.is(.object)) {
                const proto = core.value_semantics.objectFromValue(proto_value);
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
        try defineNonEnumValueProperty(rt, object, core.atom.ids.name, name_value);
    }
    return object.value();
}

test "buildNamedErrorObject roots direct symbol constructor while creating error object" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-error-constructor-symbol");
    const ctor_value = try rt.takeSymbolValue(symbol_atom);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const error_value = try buildNamedErrorObject(rt, ctor_value, "TypeError", "boom");
    const object = try property_ops.expectObject(error_value);

    // The ctor value stays rooted across the allocating construction even
    // though it is no longer stored as an own `constructor` property
    // (JS_ThrowError2 discipline: only `message` is an own property).
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const message_key = try rt.internAtom("message");
    {
        const stored = try object.getProperty(message_key);
        try std.testing.expect(stored.isString());
    }
    const constructor_key = try rt.internAtom("constructor");
    {
        const stored = try object.getProperty(constructor_key);
        try std.testing.expect(!stored.same(ctor_value));
    }
    // Non-object ctor (symbol) => no prototype; the degraded fallback stamps
    // an own self-describing `name`.
    const name_key = try rt.internAtom("name");
    {
        const stored = try object.getProperty(name_key);
        try std.testing.expect(stored.isString());
    }

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

/// Throw the canonical `ReferenceError` for a TDZ violation.
/// Returns `error.ReferenceError` to align with the VM sentinel convention.
pub fn throwTdzReferenceError(ctx: *core.JSContext) error{ReferenceError} {
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
/// Mirrors js_aggregate_error_constructor: a bare
/// error-class object on AggregateError.prototype whose only own property is
/// `errors` (JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE, non-enumerable) — no
/// own `message`/`name`. qjs does not run build_backtrace here either; zjs
/// still snapshots the call sites because its lazy `stack` accessor would
/// otherwise rebuild a backtrace from whichever context first reads it.
pub fn promiseAggregateError(ctx: *core.JSContext, global: *core.Object, errors: *core.Object) !core.JSValue {
    const rt = ctx.runtime;
    const ctor_key = core.atom.ids.AggregateError;
    const ctor_value = try global.getProperty(ctor_key);

    const object = try core.Object.create(rt, core.class.ids.error_, null);
    const aggregate_error = object.value();
    if (ctor_value.is(.object)) {
        if (core.value_semantics.objectFromValue(ctor_value)) |ctor_object| {
            const proto_value = try ctor_object.getProperty(core.atom.ids.prototype);
            if (proto_value.is(.object)) {
                if (core.value_semantics.objectFromValue(proto_value)) |prototype| {
                    try object.setPrototype(rt, prototype);
                }
            }
        }
    }
    try defineNonEnumValueProperty(rt, object, core.atom.ids.errors, errors.value());
    try attachStackToErrorValue(ctx, global, aggregate_error);
    return aggregate_error;
}

pub fn promiseErrorValue(ctx: *core.JSContext, global: *core.Object, err: HostError) HostError!core.JSValue {
    // QuickJS's async boundary takes the already-thrown interrupt value and
    // rejects with it. Keep this transfer local to Promise conversion:
    // admitting Interrupted to the generic pending-error matcher would let
    // generator catches and assertion helpers consume an uncatchable error.
    if (@as(anyerror, err) == error.Interrupted and ctx.exceptionIsUncatchable()) {
        return ctx.takeException();
    }
    if (pendingExceptionMatchesError(ctx, err)) return ctx.takeException();
    const error_info = promiseErrorInfo(err);
    return createSentinelError(ctx, global, err, error_info) catch |create_err| {
        // Promise jobs must be able to retain an abrupt completion after user
        // code has run. Under a fully exhausted heap, use the same allocation-
        // free OOM value as VM catch delivery so the job can advance to its
        // rejection phase instead of either disappearing or invoking user code
        // a second time on retry.
        if (create_err == error.OutOfMemory) {
            if (ctx.preallocated_oom_error) |preallocated| return preallocated;
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
    err: HostError,
    prototype: ?*core.Object,
) HostError!core.JSValue {
    if (pendingExceptionMatchesError(ctx, err)) {
        const thrown_value = ctx.runtime.current_exception;
        const promise = try core.promise.rejectedWithPrototype(ctx, thrown_value, prototype);
        ctx.clearException();
        return promise;
    }
    const error_info = runtimeErrorInfo(err) orelse return err;
    const error_value = try createSentinelError(ctx, global, err, error_info);
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
///
/// The returned sentinel is deliberately `error.StackOverflow`, not an
/// `InternalError`-shaped one: every caller is a stack/recursion budget guard
/// (`vm_call`, `inline_calls`, `builtin_dispatch`), and that is the sentinel
/// their unwind paths match on. The thrown JS value is the InternalError.
pub fn throwInternalErrorMessage(ctx: *core.JSContext, global: *core.Object, message: []const u8) !core.JSValue {
    const error_value = try createNamedError(ctx, global, "InternalError", message);
    _ = ctx.throwValue(error_value);
    return error.StackOverflow;
}

/// QuickJS `JS_ThrowInterrupted`: retain a real InternalError in the polled
/// Realm while making it uncatchable by JavaScript catch markers.
pub fn throwInterrupted(ctx: *core.JSContext, global: *core.Object) !void {
    const error_value = createNamedError(ctx, global, "InternalError", "interrupted") catch |err| {
        if (err != error.OutOfMemory) return err;
        // QuickJS marks the current exception uncatchable even when building
        // InternalError("interrupted") recursively falls into its OOM path.
        // Use the Realm's preallocated OOM object so zjs can preserve that
        // contract without allocating on the exhausted heap.
        if (!ctx.hasException()) {
            const fallback = if (ctx.preallocated_oom_error) |preallocated|
                preallocated
            else
                core.JSValue.nullValue();
            _ = ctx.throwValue(fallback);
        }
        ctx.setExceptionUncatchable(true);
        return error.Interrupted;
    };
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

/// The slow half of `pollInterrupt` for callers that inline the counter tick
/// themselves (`ctx.pollInterruptTick()`): reset, GC safepoint, interrupt
/// handler, and the throw when the handler asked for it.
pub noinline fn pollInterruptSlowLeg(ctx: *core.JSContext, global: *core.Object) core.errors.HostError!void {
    if (!ctx.pollInterruptSlowPublic()) return;
    return throwInterrupted(ctx, global) catch |err| return @errorCast(err);
}

pub fn throwReferenceErrorMessage(ctx: *core.JSContext, global: *core.Object, message: []const u8) !core.JSValue {
    const error_value = try createNamedError(ctx, global, "ReferenceError", message);
    _ = ctx.throwValue(error_value);
    return error.ReferenceError;
}

/// qjs JS_ThrowReferenceErrorNotDefined: `'name' is not
/// defined`. Every unresolved-binding exit (get_var, strict put_var, the
/// with-scope and ref-value legs) goes through here so the identifier reaches
/// the message; the bare `error.ReferenceError` sentinel (runtimeErrorInfo:
/// "not defined") is what a JS `catch` would otherwise see. Cold: called only
/// after the lookup has already failed.
pub fn throwReferenceErrorNotDefined(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom) !core.JSValue {
    const allocator = ctx.runtime.nativeAllocator();
    var index_buf: [16]u8 = undefined;
    const name: []const u8 = if (atom_id.isTaggedInt())
        std.fmt.bufPrint(&index_buf, "{d}", .{atom_id.toUInt32()}) catch unreachable
    else
        ctx.runtime.atoms.name(atom_id) orelse "";
    const message = try std.fmt.allocPrint(allocator, "'{s}' is not defined", .{name});
    defer allocator.free(message);
    return throwReferenceErrorMessage(ctx, global, message);
}

pub fn throwSyntaxErrorMessage(ctx: *core.JSContext, global: *core.Object, message: []const u8) !core.JSValue {
    const error_value = try createNamedError(ctx, global, "SyntaxError", message);
    _ = ctx.throwValue(error_value);
    return error.SyntaxError;
}

pub fn isCallSiteObject(object: *core.Object) bool {
    return object.isCallSite();
}

/// CallSite prototype methods dispatched by `.host` native-record id; the
/// receiver must be a CallSite object (the metadata lives in internal slots).
pub fn callSiteMethodById(object: *core.Object, id: core.function.HostGlobalMethod) ?core.JSValue {
    if (!isCallSiteObject(object)) return null;
    return switch (id) {
        .callsite_get_function => core.JSValue.nullValue(),
        .callsite_get_function_name => if (object.callSiteFunctionName()) |value| value else core.JSValue.nullValue(),
        .callsite_get_file_name => if (object.callSiteFile()) |value| value else core.JSValue.nullValue(),
        .callsite_get_line_number => if (object.callSiteIsNative()) core.JSValue.nullValue() else core.JSValue.int32(object.callSiteLine()),
        .callsite_get_column_number => if (object.callSiteIsNative()) core.JSValue.nullValue() else core.JSValue.int32(object.callSiteColumn()),
        .callsite_is_native => core.JSValue.boolean(object.callSiteIsNative()),
        else => null,
    };
}

fn backtraceFunctionNameAtom(ctx: *core.JSContext, fallback: core.Atom, current_function_value: core.JSValue) !core.Atom {
    const function_object = objectFromValue(current_function_value) orelse return fallback;
    const name_desc = (try function_object.getOwnProperty(ctx.runtime, core.atom.ids.name)) orelse return core.atom.ids.empty_string;
    if (name_desc.kind != .data or !name_desc.value.isString()) return core.atom.ids.empty_string;

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(ctx.runtime.nativeAllocator());
    try value_ops.appendRawString(ctx.runtime, &bytes, name_desc.value);
    return ctx.runtime.atoms.internString(bytes.items);
}

pub fn resolveBacktraceFunctionName(ctx: *core.JSContext, frame: *core.BacktraceFrame) core.Atom {
    const function_value = frame.function_value;
    if (function_value.is(.undefined_value)) return frame.function_name;
    frame.function_value = core.JSValue.undefinedValue();
    const resolved = backtraceFunctionNameAtom(ctx, frame.function_name, function_value) catch core.atom.ids.empty_string;
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
/// `current_stack_frame -> prev_frame` walk, with no per-call
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
        //; without it a frame whose call is the last
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
    const object = core.value_semantics.objectFromValue(value) orelse return rt.nativeAllocator().dupe(u8, "");
    const name_value = try object.getProperty(core.atom.ids.name);
    if (!name_value.isString()) return rt.nativeAllocator().dupe(u8, "");
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try value_ops.appendRawString(rt, &bytes, name_value);
    return rt.nativeAllocator().dupe(u8, bytes.items);
}

pub fn pendingExceptionMatchesError(ctx: *core.JSContext, err: anyerror) bool {
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
pub fn runtimeErrorInfo(err: anyerror) ?ErrorInfo {
    return switch (@as(anyerror, err)) {
        error.URIError, error.InvalidUtf8 => .{ .name = "URIError", .message = "expecting hex digit" },
        // Allocation failure under a memory limit is catchable, mirroring
        // QuickJS's InternalError "out of memory" exception; paths without a
        // JS catch handler still surface error.OutOfMemory to the embedder.
        error.OutOfMemory => .{ .name = "InternalError", .message = "out of memory" },
        // Native C-stack recursion guard (QuickJS JS_ThrowStackOverflow ->
        // InternalError "stack overflow", quickjs.c).
        error.StackOverflow => .{ .name = "InternalError", .message = "stack overflow" },
        error.Interrupted => .{ .name = "InternalError", .message = "interrupted" },
        // JS_STRING_LEN_MAX creation/concat cap (qjs quickjs.c).
        error.StringTooLong => .{ .name = "InternalError", .message = "string too long" },
        // qjs OP_check_ctor_return deliberately creates this TypeError in the
        // constructor's caller context. Keep a distinct
        // sentinel so the caller frame can materialize the exact message there.
        error.DerivedConstructorReturn => .{ .name = "TypeError", .message = "derived class constructor must return an object or undefined" },
        // qjs OP_get_loc_checkthis likewise uses caller_ctx for the implicit
        // derived-constructor return.
        error.DerivedThisUninitialized => .{ .name = "ReferenceError", .message = "this is not initialized" },
        error.TypeError => .{ .name = "TypeError", .message = "" },
        // qjs JS_CreateProperty not_extensible.
        error.NotExtensible => .{ .name = "TypeError", .message = "object is not extensible" },
        error.InvalidCharacterError => .{ .name = "InvalidCharacterError", .message = "" },
        error.SyntaxError => .{ .name = "SyntaxError", .message = "invalid syntax" },
        error.RangeError => .{ .name = "RangeError", .message = "" },
        // qjs js_bigint_new single throw site.
        error.BigIntTooLarge => .{ .name = "RangeError", .message = "BigInt is too large to allocate" },
        // qjs js_bigint_divrem division-by-zero guard.
        error.DivisionByZero => .{ .name = "RangeError", .message = "BigInt division by zero" },
        // qjs js_bigint_pow negative-exponent guard.
        error.NegativeExponent => .{ .name = "RangeError", .message = "BigInt negative exponent" },
        error.ReferenceError => .{ .name = "ReferenceError", .message = "not defined" },
        else => null,
    };
}

pub fn promiseErrorInfo(err: anyerror) ErrorInfo {
    return switch (@as(anyerror, err)) {
        error.URIError, error.InvalidUtf8 => .{ .name = "URIError", .message = "expecting hex digit" },
        error.OutOfMemory => .{ .name = "InternalError", .message = "out of memory" },
        error.StackOverflow => .{ .name = "InternalError", .message = "stack overflow" },
        error.Interrupted => .{ .name = "InternalError", .message = "interrupted" },
        error.StringTooLong => .{ .name = "InternalError", .message = "string too long" },
        error.DerivedConstructorReturn => .{ .name = "TypeError", .message = "derived class constructor must return an object or undefined" },
        error.DerivedThisUninitialized => .{ .name = "ReferenceError", .message = "this is not initialized" },
        error.TypeError => .{ .name = "TypeError", .message = "" },
        error.SyntaxError => .{ .name = "SyntaxError", .message = "invalid syntax" },
        error.RangeError => .{ .name = "RangeError", .message = "" },
        // qjs js_bigint_new single throw site.
        error.BigIntTooLarge => .{ .name = "RangeError", .message = "BigInt is too large to allocate" },
        // qjs js_bigint_divrem division-by-zero guard.
        error.DivisionByZero => .{ .name = "RangeError", .message = "BigInt division by zero" },
        // qjs js_bigint_pow negative-exponent guard.
        error.NegativeExponent => .{ .name = "RangeError", .message = "BigInt negative exponent" },
        error.ReferenceError => .{ .name = "ReferenceError", .message = "not defined" },
        else => .{ .name = "Error", .message = "" },
    };
}

/// Concrete host-I/O producer surface. Keep this exact rather than accepting
/// `anyerror`: a Zig stdlib change must make this switch fail to compile until
/// the JS conversion policy is reviewed.
pub const HostIoError = std.Io.Dir.ReadFileAllocError || std.Io.Writer.Error;

pub fn hostIoErrorInfo(err: HostIoError) ErrorInfo {
    return switch (err) {
        error.OutOfMemory => .{ .name = "InternalError", .message = "out of memory" },
        error.AccessDenied,
        error.AntivirusInterference,
        error.BadPathName,
        error.Canceled,
        error.ConnectionResetByPeer,
        error.DeviceBusy,
        error.FileBusy,
        error.FileLocksUnsupported,
        error.FileNotFound,
        error.FileTooBig,
        error.InputOutput,
        error.IsDir,
        error.LockViolation,
        error.NameTooLong,
        error.NetworkNotFound,
        error.NoDevice,
        error.NoSpaceLeft,
        error.NotDir,
        error.NotOpenForReading,
        error.PathAlreadyExists,
        error.PermissionDenied,
        error.PipeBusy,
        error.ProcessFdQuotaExceeded,
        error.ReadOnlyFileSystem,
        error.SocketUnconnected,
        error.StreamTooLong,
        error.SymLinkLoop,
        error.SystemFdQuotaExceeded,
        error.SystemResources,
        error.Unexpected,
        error.WouldBlock,
        error.WriteFailed,
        => .{ .name = "Error", .message = @errorName(err) },
    };
}

/// Build an owned rejection reason without using the pending-exception slot as
/// temporary transport.
pub fn hostErrorValue(
    ctx: *core.JSContext,
    global: *core.Object,
    err: HostIoError,
) HostError!core.JSValue {
    const info = hostIoErrorInfo(err);
    return createNamedError(ctx, global, info.name, info.message) catch |create_err|
        return @errorCast(create_err);
}

/// Convert a synchronous host-I/O failure at its producer seam. Until Q16
/// Stage 2 narrows `HostError`'s type, this dynamically returns only the hard
/// OOM control or the ordinary JS-exception transport.
pub fn throwHostError(
    ctx: *core.JSContext,
    global: *core.Object,
    err: HostIoError,
) HostError!core.JSValue {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (ctx.hasException()) return error.JSException;
    const error_value = try hostErrorValue(ctx, global, err);
    _ = ctx.throwValue(error_value);
    return error.JSException;
}

pub const module_host_stall_message = "module host made no progress";

/// A host scheduler that cannot advance a pending module evaluation is an
/// engine/host integration failure, not the dynamic-import "unsupported"
/// sentinel. Materialize it before it leaves eval.
pub fn throwModuleHostStall(
    ctx: *core.JSContext,
    global: *core.Object,
) HostError!core.JSValue {
    if (ctx.hasException()) return error.JSException;
    const error_value = try createNamedError(
        ctx,
        global,
        "InternalError",
        module_host_stall_message,
    );
    _ = ctx.throwValue(error_value);
    return error.JSException;
}

fn errorNameForRuntimeError(err: anyerror) ?[]const u8 {
    return switch (@as(anyerror, err)) {
        error.URIError, error.InvalidUtf8 => "URIError",
        error.StackOverflow => "InternalError",
        error.StringTooLong => "InternalError",
        // `runtimeErrorInfo` maps this to InternalError too, so its absence
        // here was an oversight with teeth: `pendingExceptionMatchesError`
        // would not recognize an already-pending out-of-memory exception, and
        // the caller would clear it and build a replacement -- allocating on
        // an exhausted heap and losing the original error's stack.
        error.OutOfMemory => "InternalError",
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

const objectFromValue = core.value_semantics.objectFromValue;

/// JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE (non-enumerable) data property —
/// the attribute set qjs uses for every own property it defines on error
/// objects (JS_ThrowError2 quickjs.c, js_aggregate_error_constructor
/// quickjs.c).
fn defineNonEnumValueProperty(rt: *core.JSRuntime, object: *core.Object, key: core.Atom, value: core.JSValue) !void {
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, .method));
}

/// Last-resort TDZ throw for the paths that have no realm (or whose error
/// construction itself failed): park the bare `ReferenceError` atom id in the
/// exception slot so the boundary that owns a realm can materialize the real
/// error object by name.
fn throwReferenceErrorSentinel(ctx: *core.JSContext) void {
    const reference_error_atom = comptime core.atom.predefinedId("ReferenceError", .string).?;
    _ = ctx.throwValue(core.JSValue.int32(@intCast(reference_error_atom.raw())));
}

// ----- merged from exceptions.zig -----
// Compatibility names for the core engine-error authority.
const core_errors = @import("../core/errors.zig");
pub const RuntimeError = core_errors.RuntimeError;
pub const HostError = core_errors.HostError;

// ----- merged from error_ops.zig -----
// Error-object native records and their realm-aware dispatch seam.
//
// This module owns the Error prototype/static record ids and forwards stack
// access, captureStackTrace, and `toString` to their implementation owners.
// Receiver and arguments are borrowed; returned JSValues are owned. Callable
// realm selection stays atomic through `builtin_dispatch`, matching the
// QuickJS Error prototype table and `js_error_toString` at
const builtin_dispatch = @import("builtin_dispatch.zig");
const call = @import("call.zig");
const call_runtime = @import("call_runtime.zig");
const string_ops = @import("string_ops.zig");
pub const PrototypeMethod = core.host_function.builtin_method_ids.error_object.PrototypeMethod;
pub const StaticMethod = enum(u32) {
    capture_stack_trace = 10,
};
pub const internal_entries = errorEntries: {
    const Entry = core.host_function.InternalEntry;
    break :errorEntries [_]Entry{
        errorEntry("toString", 0, @intFromEnum(PrototypeMethod.to_string)),
        errorEntry("get stack", 1, @intFromEnum(PrototypeMethod.stack_getter)),
        errorEntry("set stack", 1, @intFromEnum(PrototypeMethod.stack_setter)),
        errorEntry("captureStackTrace", 1, @intFromEnum(StaticMethod.capture_stack_trace)),
    };
};
fn errorEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&errorCall),
    };
}

fn errorCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    const ctx = realm.realm;
    const output = host_call.output;
    const id: u32 = host_call.magic;
    const args = host_call.args;
    const this_value = host_call.this_value;
    const caller_function = builtin_dispatch.callerBytecode(host_call);
    const caller_frame = builtin_dispatch.callerFrame(host_call);

    if (id == @intFromEnum(StaticMethod.capture_stack_trace)) {
        const receiver = call.thisObject(this_value) orelse return error.TypeError;
        if (!call_runtime.isCallableValue(this_value)) return error.TypeError;
        if (!try call_runtime.constructorNameEqlLocal(ctx.runtime, receiver, "Error")) return error.TypeError;
        return errorCaptureStackTrace(ctx, output, realm.global, args);
    }

    const func_obj = host_call.func_obj;
    return switch (id) {
        @intFromEnum(PrototypeMethod.to_string) => string_ops.errorToStringCall(ctx, output, realm.global, this_value, caller_function, caller_frame),
        @intFromEnum(PrototypeMethod.stack_getter) => errorStackGetter(ctx, output, realm.global, this_value),
        @intFromEnum(PrototypeMethod.stack_setter) => blk: {
            const setter_func = func_obj orelse return error.TypeError;
            break :blk errorStackSetter(ctx, output, realm.global, this_value, setter_func, args, caller_function, caller_frame);
        },
        else => error.TypeError,
    };
}

// ----- merged from error_stack_ops.zig -----
// Error.stack capture/formatting, backtrace naming and CallSite helpers.
const method_ids = core.host_function.builtin_method_ids;
const array_ops = @import("array_ops.zig");
const object_ops = @import("object_ops.zig");
const buildCallSiteArray = array_ops.buildCallSiteArray;
const buildErrorStackStringValue = string_ops.buildErrorStackStringValue;
const callValueOrBytecodeRoot = call_runtime.callValueOrBytecodeRoot;
const formatCapturedErrorStackStringValue = string_ops.formatCapturedErrorStackStringValue;
const isCallableValue = call_runtime.isCallableValue;
pub fn captureErrorStack(ctx: *core.JSContext, global: *core.Object, instance: *core.Object) !void {
    const sites = try buildCallSiteArray(ctx, global, null);
    try instance.setErrorStackSites(ctx.runtime, sites);
}

/// Value-level stack capture: attach the current VM backtrace as call sites
/// to `value` when it is an object; non-object values are ignored. This is
/// the seam used by the `exception_ops` construction primitives, which
/// capture the stack at error construction time (QuickJS `build_backtrace`
/// inside `JS_ThrowError2`).
pub fn attachStackToErrorValue(ctx: *core.JSContext, global: *core.Object, value: core.JSValue) !void {
    const object = core.value_semantics.objectFromValue(value) orelse return;
    try captureErrorStack(ctx, global, object);
}

pub fn buildErrorStackValue(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, error_value: core.JSValue, skip_name: ?[]const u8) !core.JSValue {
    if (ctx.runtime.formatting_error_stack) return buildErrorStackStringValue(ctx, global, skip_name);

    if (try errorPrepareStackTrace(global)) |prepare| {
        const sites = try buildCallSiteArray(ctx, global, skip_name);
        ctx.runtime.formatting_error_stack = true;
        defer ctx.runtime.formatting_error_stack = false;
        return callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), prepare, &.{ error_value, sites }, null, null) catch |err| {
            if (pendingExceptionMatchesError(ctx, err)) {
                _ = ctx.takeException();
                return core.JSValue.nullValue();
            }
            if (ctx.hasException()) ctx.clearException();
            if (runtimeErrorInfo(err) != null) return core.JSValue.nullValue();
            return err;
        };
    }
    return buildErrorStackStringValue(ctx, global, skip_name);
}

pub fn formatCapturedErrorStackValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    error_value: core.JSValue,
    sites_value: core.JSValue,
    site_count: usize,
) !core.JSValue {
    if (ctx.runtime.formatting_error_stack) return formatCapturedErrorStackStringValue(ctx, sites_value, site_count);

    if (try errorPrepareStackTrace(global)) |prepare| {
        const sites_arg = sites_value;
        ctx.runtime.formatting_error_stack = true;
        defer ctx.runtime.formatting_error_stack = false;
        return callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), prepare, &.{ error_value, sites_arg }, null, null) catch |err| {
            if (pendingExceptionMatchesError(ctx, err)) {
                _ = ctx.takeException();
                return core.JSValue.nullValue();
            }
            if (ctx.hasException()) ctx.clearException();
            if (runtimeErrorInfo(err) != null) return core.JSValue.nullValue();
            return err;
        };
    }
    return formatCapturedErrorStackStringValue(ctx, sites_value, site_count);
}

/// Throw the compile-error SyntaxError for a parse failure, mirroring qjs's
/// parse-error surface: build_backtrace's filename branch
/// defines own fileName/lineNumber/columnNumber data properties
/// (JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE, non-enumerable) and prepends a
/// `    at <file>:<line>:<col>` line to the stack, which for compile errors is
/// built eagerly at throw time (JS_ThrowError2 -> build_backtrace with
/// filename != NULL). zjs stores the eagerly-built string via `setErrorStack`
/// so the lazy `stack` accessor returns it verbatim.
pub fn throwParseSyntaxError(
    ctx: *core.JSContext,
    global: *core.Object,
    filename: []const u8,
    line: u32,
    col: u32,
    message: []const u8,
) !core.JSValue {
    const rt = ctx.runtime;
    const line_num: i32 = std.math.cast(i32, line) orelse std.math.maxInt(i32);
    const col_num: i32 = std.math.cast(i32, col) orelse std.math.maxInt(i32);
    const error_value = try createNamedErrorWithoutStack(rt, global, "SyntaxError", message);
    // Ownership: on construction failure below free the value; once
    // `throwValue` has stored it the exception slot owns it (the final
    // `return error.SyntaxError` is the intended result, not a failure).
    defineParseErrorSurface(ctx, global, error_value, filename, line_num, col_num) catch |err| {
        return err;
    };
    _ = ctx.throwValue(error_value);
    return error.SyntaxError;
}

fn defineParseErrorSurface(
    ctx: *core.JSContext,
    global: *core.Object,
    error_value: core.JSValue,
    filename: []const u8,
    line_num: i32,
    col_num: i32,
) !void {
    const rt = ctx.runtime;
    const instance = core.value_semantics.objectFromValue(error_value) orelse return;
    const filename_value = try value_ops.createStringValue(rt, filename);
    try instance.defineOwnProperty(rt, core.atom.ids.fileName, core.Descriptor.data(filename_value, .method));
    try instance.defineOwnProperty(rt, core.atom.ids.lineNumber, core.Descriptor.data(core.JSValue.int32(line_num), .method));
    try instance.defineOwnProperty(rt, core.atom.ids.columnNumber, core.Descriptor.data(core.JSValue.int32(col_num), .method));

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(rt.nativeAllocator());
    try bytes.print(rt.nativeAllocator(), "    at {s}:{d}:{d}\n", .{ filename, line_num, col_num });
    const frames_value = try buildErrorStackStringValue(ctx, global, null);
    try value_ops.appendRawString(rt, &bytes, frames_value);
    const stack_value = try value_ops.createStringValue(rt, bytes.items);
    try instance.setErrorStack(rt, stack_value);
}

fn errorPrepareStackTrace(global: *core.Object) !?core.JSValue {
    const error_key = core.atom.ids.Error;
    const error_value = try global.getProperty(error_key);
    const error_object = core.value_semantics.objectFromValue(error_value) orelse return null;
    const prepare_key = core.atom.ids.prepareStackTrace;
    const prepare = try error_object.getProperty(prepare_key);
    if (!isCallableValue(prepare)) {
        return null;
    }
    return prepare;
}

pub fn backtraceFunctionNameEql(ctx: *core.JSContext, entry: core.BacktraceFrame, expected: []const u8) bool {
    return std.mem.eql(u8, callSiteFunctionName(ctx, entry), expected);
}

/// Display name for a backtrace frame. Mirrors qjs build_backtrace
///: an empty name renders "<anonymous>", a top-level
/// script/eval frame renders "<eval>". qjs gets the latter for free because
/// the compiler names every top-level function def JS_ATOM__eval_
///; zjs's top-level bytecode instead carries name ==
/// filename (the name-equality is also its eval-frame detection convention,
/// e.g. vm_call.zig / eval_ops.zig), so the "<eval>" mapping is applied at
/// this rendering seam.
pub fn callSiteFunctionName(ctx: *core.JSContext, entry: core.BacktraceFrame) []const u8 {
    const name = ctx.runtime.atoms.name(entry.function_name) orelse "";
    const file = ctx.runtime.atoms.name(entry.filename) orelse "";
    if (name.len == 0) return "<anonymous>";
    if (std.mem.eql(u8, name, file)) return "<eval>";
    return name;
}

pub fn callSiteFunctionNameValue(ctx: *core.JSContext, entry: core.BacktraceFrame) !core.JSValue {
    const name = ctx.runtime.atoms.name(entry.function_name) orelse "";
    const file = ctx.runtime.atoms.name(entry.filename) orelse "";
    if (name.len == 0) return core.JSValue.nullValue();
    if (std.mem.eql(u8, name, file)) return value_ops.createStringValue(ctx.runtime, "<eval>");
    return value_ops.createStringValue(ctx.runtime, name);
}

pub fn errorStackTraceLimit(_: *core.JSRuntime, global: *core.Object) usize {
    const error_key = core.atom.ids.Error;
    const error_object = global.getOwnDataObjectBorrowed(error_key) orelse return 10;
    const limit_key = core.atom.ids.stackTraceLimit;
    const limit_value = error_object.getOwnDataPropertyValue(limit_key) orelse return 10;
    if (limit_value.is(.undefined_value) or limit_value.is(.null_value)) return 0;
    const number = value_ops.numberValue(limit_value) orelse return 10;
    if (!std.math.isFinite(number) or number <= 0) return 0;
    const truncated = @floor(number);
    if (truncated > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return std.math.maxInt(usize);
    return @intFromFloat(truncated);
}

pub fn appendBacktraceFunctionName(
    ctx: *core.JSContext,
    bytes: *std.ArrayList(u8),
    function_name: core.Atom,
    filename: core.Atom,
) !void {
    const name = ctx.runtime.atoms.name(function_name) orelse "";
    const file = ctx.runtime.atoms.name(filename) orelse "";
    if (name.len == 0) {
        try bytes.appendSlice(ctx.runtime.nativeAllocator(), "<anonymous>");
    } else if (std.mem.eql(u8, name, file)) {
        // Top-level script/eval frame (see callSiteFunctionName).
        try bytes.appendSlice(ctx.runtime.nativeAllocator(), "<eval>");
    } else {
        try bytes.appendSlice(ctx.runtime.nativeAllocator(), name);
    }
}

pub fn appendCallSiteFunctionName(rt: *core.JSRuntime, bytes: *std.ArrayList(u8), site: *core.Object) !void {
    const name_value = site.callSiteFunctionName() orelse {
        try bytes.appendSlice(rt.nativeAllocator(), "<anonymous>");
        return;
    };
    if (!name_value.isString()) {
        try bytes.appendSlice(rt.nativeAllocator(), "<anonymous>");
        return;
    }
    try value_ops.appendRawString(rt, bytes, name_value);
}

pub fn appendCallSiteFileName(rt: *core.JSRuntime, bytes: *std.ArrayList(u8), site: *core.Object) !void {
    const file_value = site.callSiteFile() orelse {
        try bytes.appendSlice(rt.nativeAllocator(), "<anonymous>");
        return;
    };
    if (!file_value.isString()) {
        try bytes.appendSlice(rt.nativeAllocator(), "<anonymous>");
        return;
    }
    try value_ops.appendRawString(rt, bytes, file_value);
}

pub fn errorStackGetter(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
) !core.JSValue {
    const object = object_ops.objectFromValue(this_value) orelse return error.TypeError;
    if (object.class_id != core.class.ids.error_) return core.JSValue.undefinedValue();
    if (object.errorStack()) |stack| return stack;
    if (object.errorStackSites()) |sites| {
        const stack = try formatCapturedErrorStackValue(ctx, output, global, this_value, sites, object.errorStackSiteCount());
        try object.setErrorStack(ctx.runtime, stack);
        return stack;
    }
    return buildErrorStackValue(ctx, output, global, this_value, null);
}

pub fn errorStackSetter(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const receiver = object_ops.objectFromValue(this_value) orelse return error.TypeError;
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (!value.isString()) return error.TypeError;

    if (ctx.nativeErrorPrototypeObject(.error_)) |error_proto| {
        if (object_ops.sameObjectIdentity(this_value, error_proto.value())) return error.TypeError;
    }

    const stack_key = core.atom.ids.stack;
    const desc = try object_ops.proxyAwareOwnPropertyDescriptor(ctx, output, global, receiver, stack_key, caller_function, caller_frame);

    if (desc == null) {
        const create_desc = core.Descriptor.data(value, .all);
        const ok = if (receiver.proxyTarget() != null)
            try object_ops.proxyDefineOwnProperty(ctx, output, global, receiver, stack_key, create_desc, caller_function, caller_frame)
        else blk: {
            receiver.defineOwnProperty(ctx.runtime, stack_key, create_desc) catch |err| switch (err) {
                error.ReadOnly, error.NotExtensible, error.IncompatibleDescriptor => break :blk false,
                error.InvalidLength => return error.RangeError,
                else => return err,
            };
            break :blk true;
        };
        if (!ok) return error.TypeError;
        return core.JSValue.undefinedValue();
    }

    const own_desc = desc.?;
    if (own_desc.kind == .accessor and object_ops.sameObjectIdentity(own_desc.setter, function_object.value()) and isErrorStackSetterValue(own_desc.setter)) {
        if (try object_ops.proxySetTrapForErrorStackSetter(ctx, output, global, this_value, receiver, stack_key, value, caller_function, caller_frame)) {
            return core.JSValue.undefinedValue();
        }
        try object_ops.defineErrorStackDataProperty(ctx, output, global, receiver, stack_key, core.Descriptor.data(value, .all), caller_function, caller_frame);
        return core.JSValue.undefinedValue();
    }

    if (receiver.proxyTarget() != null) {
        const ok = try object_ops.proxySetValueProperty(ctx, output, global, this_value, receiver, stack_key, value, caller_function, caller_frame);
        if (!ok) return error.TypeError;
        return core.JSValue.undefinedValue();
    }

    switch (own_desc.kind) {
        .accessor => {
            if (own_desc.setter.is(.undefined_value)) return error.TypeError;
            _ = try call_runtime.callValueOrBytecodeSyncInternalOutlined(ctx, output, global, this_value, own_desc.setter, &.{value}, caller_function, caller_frame);
            return core.JSValue.undefinedValue();
        },
        .data, .generic => {
            if (own_desc.kind == .data and own_desc.writable == false) return error.TypeError;
            try object_ops.defineErrorStackDataProperty(ctx, output, global, receiver, stack_key, core.Descriptor{ .kind = .data, .value = value, .value_present = true }, caller_function, caller_frame);
            return core.JSValue.undefinedValue();
        },
    }
}

fn isErrorStackSetterValue(value: core.JSValue) bool {
    const object = object_ops.objectFromValue(value) orelse return false;
    const native_ref = core.function.decodeNativeBuiltinId(object.nativeFunctionId()) orelse return false;
    return native_ref.domain == .error_object and native_ref.id == @intFromEnum(method_ids.error_object.PrototypeMethod.stack_setter);
}

pub fn errorCaptureStackTrace(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 1 or !args[0].is(.object)) return throwTypeErrorMessage(ctx, global, "not an object");
    const target = try property_ops.expectObject(args[0]);
    const skip_name = if (args.len >= 2 and isCallableValue(args[1]))
        try functionNameBytes(ctx.runtime, args[1])
    else
        null;
    defer if (skip_name) |bytes| ctx.runtime.nativeAllocator().free(bytes);
    const stack_value = try buildErrorStackValue(ctx, output, global, args[0], skip_name);
    try target.defineOwnProperty(ctx.runtime, core.atom.ids.stack, core.Descriptor.data(stack_value, .method));
    return core.JSValue.undefinedValue();
}
