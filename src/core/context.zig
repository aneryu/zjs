const std = @import("std");

const atom = @import("atom.zig");
const class = @import("class.zig");
const module = @import("module.zig");
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Descriptor = @import("descriptor.zig").Descriptor;
const gc = @import("gc.zig");
const runtime_mod = @import("runtime.zig");
const property = @import("property.zig");
const shape = @import("shape.zig");
const string = @import("string.zig");
const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;
const function_mod = @import("function.zig");

pub const BacktraceFrame = struct {
    function_name: atom.Atom,
    filename: atom.Atom,
    line_num: i32,
    col_num: i32,
    pc: usize = 0,
    pc_source: ?*const usize = null,
    location_data: ?*const anyopaque = null,
    location_resolver: ?BacktraceLocationResolver = null,
    /// Owned function value used to resolve the display name lazily when a
    /// backtrace is materialized. Undefined when `function_name` is already
    /// authoritative. Resolution caches into `function_name` and clears this.
    function_value: JSValue = JSValue.undefinedValue(),
    is_native: bool = false,

    pub fn currentPc(self: BacktraceFrame) usize {
        return if (self.pc_source) |pc_source| pc_source.* -| 1 else self.pc;
    }

    pub fn location(self: BacktraceFrame) BacktraceLocation {
        const pc = self.currentPc();
        if (self.location_resolver) |resolver| return resolver(self.location_data, pc);
        return .{ .line_num = self.line_num, .col_num = self.col_num };
    }
};

pub const ActiveBacktraceFrame = struct {
    previous: ?*ActiveBacktraceFrame = null,
    data: ?*const anyopaque,
    resolver: ActiveBacktraceResolver,
};

pub const ActiveBacktraceSnapshot = struct {
    function_name: atom.Atom,
    filename: atom.Atom,
    line_num: i32,
    col_num: i32,
    pc: usize = 0,
    location_data: ?*const anyopaque = null,
    location_resolver: ?BacktraceLocationResolver = null,
    function_value: JSValue = JSValue.undefinedValue(),
    backtrace_barrier: bool = false,
    is_native: bool = false,
};

/// Resolves the active frame at `index` within this node's frame group
/// (index 0 = innermost; null past the last frame). One node now represents a
/// whole VM invocation — its inline Machine Entry chain (innermost first) then
/// the L0 frame — so the backtrace walk indexes the live Entry chain directly
/// instead of a per-call parallel node, faithful to qjs's single prev_frame
/// walk (quickjs.c:7571).
pub const ActiveBacktraceResolver = *const fn (?*const anyopaque, usize) ?ActiveBacktraceSnapshot;

pub const BacktraceLocation = struct {
    line_num: i32,
    col_num: i32,
};

pub const BacktraceLocationResolver = *const fn (?*const anyopaque, usize) BacktraceLocation;

pub const DynamicImportError = error{
    AccessDenied,
    AccessorWithoutSetter,
    AmbiguousExport,
    AntivirusInterference,
    AwaitOutsideAsyncFunction,
    BadPathName,
    BigIntTooLarge,
    BrokenPipe,
    BytecodeCorrupt,
    BytecodeOverflow,
    Canceled,
    ClosureVarNotFound,
    CodepointTooLarge,
    ConnectionRefused,
    ConnectionResetByPeer,
    CurrentDirUnlinked,
    DeviceBusy,
    DiskQuota,
    DivisionByZero,
    DuplicateClass,
    DerivedConstructorReturn,
    DerivedThisUninitialized,
    EvalError,
    FileBusy,
    FileLocksUnsupported,
    FileNotFound,
    FileSystem,
    FileTooBig,
    HtmlCommentInModule,
    IncompatibleDescriptor,
    InputOutput,
    Interrupted,
    InvalidAssignmentTarget,
    InvalidAtom,
    InvalidBuiltinRegistry,
    InvalidBytecode,
    InvalidCharacter,
    InvalidCharacterError,
    InvalidClassId,
    InvalidEscape,
    InvalidHandle,
    InvalidIdentifier,
    InvalidLength,
    InvalidLhs,
    InvalidName,
    InvalidNumber,
    InvalidNumberLiteral,
    InvalidOpcode,
    InvalidPath,
    InvalidPattern,
    InvalidPrivateName,
    InvalidRadix,
    InvalidRegExp,
    InvalidUnicodeEscape,
    InvalidUtf8,
    InvalidWtf8,
    IsDir,
    LegacyOctalInStrictMode,
    LockViolation,
    LockedMemoryLimitExceeded,
    MissingExport,
    ModuleLinkFailed,
    ModuleNotFound,
    NameTooLong,
    NegativeExponent,
    NetworkNotFound,
    NoDevice,
    NoSpaceLeft,
    NotDir,
    NotExtensible,
    NotOpenForReading,
    NotOpenForWriting,
    NotRegExpLiteral,
    OperationUnsupported,
    OutOfMemory,
    Overflow,
    PathAlreadyExists,
    Pc2LineOverflow,
    Pc2LineTruncated,
    PermissionDenied,
    PipeBusy,
    ProcessExit,
    ProcessFdQuotaExceeded,
    ProcessNotFound,
    PrototypeCycle,
    RangeError,
    ReadOnly,
    ReadOnlyFileSystem,
    ReferenceError,
    SharingViolation,
    SocketNotConnected,
    SocketUnconnected,
    StackMismatch,
    StackOverflow,
    StackUnderflow,
    StreamTooLong,
    StringTooLong,
    SymLinkLoop,
    SyntaxError,
    SystemError,
    SystemFdQuotaExceeded,
    SystemResources,
    JSException,
    ThreadQuotaExceeded,
    Timeout,
    TooManyJobArgs,
    TypeError,
    URIError,
    Unexpected,
    UnexpectedEof,
    UnexpectedToken,
    UnhandledPromiseRejection,
    UnsupportedSimpleJson,
    UnterminatedComment,
    UnterminatedRegExp,
    UnterminatedString,
    UnterminatedTemplate,
    Utf8CannotEncodeSurrogateHalf,
    Utf8EncodesSurrogateHalf,
    WouldBlock,
    WriteFailed,
    YieldOutsideGenerator,
};

pub const DynamicImportCallback = *const fn (
    userdata: ?*anyopaque,
    ctx: *JSContext,
    output: ?*std.Io.Writer,
    global: *Object,
    referrer_path: []const u8,
    specifier: []const u8,
) DynamicImportError!JSValue;

pub const ContextOptions = struct {
    stack_size: ?usize = null,
    track_unhandled_rejections: bool = false,
};

pub const Options = ContextOptions;

pub const ContextEvalTiming = struct {
    parse_ns: u64 = 0,
    vm_run_ns: u64 = 0,
    promise_jobs_ns: u64 = 0,
};

pub const EvalTiming = ContextEvalTiming;

pub const EvalMode = enum {
    script,
    module,
    eval_direct,
    eval_indirect,
};

pub const EvalSourceKind = enum {
    auto,
    javascript,
    typescript,
};

pub const ContextEvalOptions = struct {
    mode: EvalMode = .script,
    filename: []const u8 = "<eval>",
    source_kind: EvalSourceKind = .auto,
    output: ?*std.Io.Writer = null,
    parse_strict: bool = false,
    runtime_strict: bool = false,
    return_completion: bool = true,
    discard_script_result: bool = false,
    timing: ?*ContextEvalTiming = null,
};

pub const EvalOptions = ContextEvalOptions;

pub const ExternalFunctionOptions = struct {
    with_prototype: bool = false,
    realm_global: ?*Object = null,
};

pub const DataPropertyOptions = struct {
    writable: bool = true,
    enumerable: bool = true,
    configurable: bool = true,
};

pub const PropertyAccessOptions = struct {
    output: ?*std.Io.Writer = null,
    realm_global: ?*Object = null,
};

pub const PropertyDescriptor = Descriptor;

pub const FunctionCallOptions = struct {
    this_value: ?JSValue = null,
    output: ?*std.Io.Writer = null,
    realm_global: ?*Object = null,
};

pub const ErrorOptions = struct {
    realm_global: ?*Object = null,
    capture_stack: bool = true,
};

pub const ScriptEvalOptions = struct {
    output: ?*std.Io.Writer = null,
    realm_global: ?*Object = null,
    filename: []const u8 = "<evalScript>",
};

pub const SharedArrayBufferRef = struct {
    store: ?*anyopaque = null,
    max_byte_length: ?usize = null,

    pub fn retain(self: SharedArrayBufferRef) SharedArrayBufferRef {
        const store = self.sharedStore() orelse return .{};
        store.retain();
        return self;
    }

    pub fn release(self: *SharedArrayBufferRef) void {
        const store = self.sharedStore() orelse return;
        self.store = null;
        self.max_byte_length = null;
        store.release();
    }

    pub fn sharedStore(self: SharedArrayBufferRef) ?*object_mod.SharedBufferStore {
        const ptr = self.store orelse return null;
        return @ptrCast(@alignCast(ptr));
    }
};

pub const SignalDisposition = enum {
    default,
    ignore,
};

pub const HostEventLoop = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        traceRoots: *const fn (*anyopaque, *runtime_mod.RootVisitor) runtime_mod.RootTraceError!void,
        setExitCode: *const fn (*anyopaque, u8) void,
        exitCode: *const fn (*anyopaque) ?u8,
        nextTimerId: *const fn (*anyopaque) i64,
        enqueueTimer: *const fn (*anyopaque, *JSContext, i64, JSValue, u64, bool) anyerror!void,
        clearTimer: *const fn (*anyopaque, *JSContext, i64) void,
        runNextTimer: *const fn (*anyopaque, *JSContext, ?*std.Io.Writer, *Object) anyerror!bool,
        setRwHandler: *const fn (*anyopaque, *JSContext, i32, bool, JSValue) anyerror!void,
        clearRwHandler: *const fn (*anyopaque, *JSContext, i32, bool) void,
        runNextRwHandler: *const fn (*anyopaque, *JSContext, ?*std.Io.Writer, *Object) anyerror!bool,
        setSignalHandler: *const fn (*anyopaque, *JSContext, u32, JSValue) anyerror!void,
        clearSignalHandler: *const fn (*anyopaque, *JSContext, u32, SignalDisposition) void,
        runNextSignalHandler: *const fn (*anyopaque, *JSContext, ?*std.Io.Writer, *Object) anyerror!bool,
    };

    pub fn traceRoots(self: HostEventLoop, visitor: *runtime_mod.RootVisitor) runtime_mod.RootTraceError!void {
        try self.vtable.traceRoots(self.ptr, visitor);
    }

    pub fn setExitCode(self: HostEventLoop, code: u8) void {
        self.vtable.setExitCode(self.ptr, code);
    }

    pub fn exitCode(self: HostEventLoop) ?u8 {
        return self.vtable.exitCode(self.ptr);
    }

    pub fn nextTimerId(self: HostEventLoop) i64 {
        return self.vtable.nextTimerId(self.ptr);
    }

    pub fn enqueueTimer(self: HostEventLoop, ctx: *JSContext, id: i64, callback: JSValue, delay_ms: u64, repeats: bool) !void {
        try self.vtable.enqueueTimer(self.ptr, ctx, id, callback, delay_ms, repeats);
    }

    pub fn clearTimer(self: HostEventLoop, ctx: *JSContext, id: i64) void {
        self.vtable.clearTimer(self.ptr, ctx, id);
    }

    pub fn runNextTimer(self: HostEventLoop, ctx: *JSContext, output: ?*std.Io.Writer, global: *Object) !bool {
        return self.vtable.runNextTimer(self.ptr, ctx, output, global);
    }

    pub fn setRwHandler(self: HostEventLoop, ctx: *JSContext, fd: i32, write_handler: bool, callback: JSValue) !void {
        try self.vtable.setRwHandler(self.ptr, ctx, fd, write_handler, callback);
    }

    pub fn clearRwHandler(self: HostEventLoop, ctx: *JSContext, fd: i32, write_handler: bool) void {
        self.vtable.clearRwHandler(self.ptr, ctx, fd, write_handler);
    }

    pub fn runNextRwHandler(self: HostEventLoop, ctx: *JSContext, output: ?*std.Io.Writer, global: *Object) !bool {
        return self.vtable.runNextRwHandler(self.ptr, ctx, output, global);
    }

    pub fn setSignalHandler(self: HostEventLoop, ctx: *JSContext, sig: u32, callback: JSValue) !void {
        try self.vtable.setSignalHandler(self.ptr, ctx, sig, callback);
    }

    pub fn clearSignalHandler(self: HostEventLoop, ctx: *JSContext, sig: u32, disposition: SignalDisposition) void {
        self.vtable.clearSignalHandler(self.ptr, ctx, sig, disposition);
    }

    pub fn runNextSignalHandler(self: HostEventLoop, ctx: *JSContext, output: ?*std.Io.Writer, global: *Object) !bool {
        return self.vtable.runNextSignalHandler(self.ptr, ctx, output, global);
    }
};

const class_prototype_inline_capacity: usize = class.ids.init_count;

/// QuickJS `JSErrorEnum` subset whose intrinsic prototypes live in
/// `JSContext.native_error_proto[]`. These are realm state, independent of the
/// mutable constructor bindings on the global object.
pub const NativeErrorKind = enum(u8) {
    error_,
    eval_error,
    range_error,
    reference_error,
    syntax_error,
    type_error,
    uri_error,
    internal_error,
    aggregate_error,
    suppressed_error,
    count,
};

const native_error_kind_count: usize = @intFromEnum(NativeErrorKind.count);

pub const RealmPublicationState = enum {
    constructing,
    live,
    finalizing,
};

/// One tracked unhandled rejection: the rejected promise (undefined when the
/// producer had no promise object at hand) plus its reason. Mirrors the qjs
/// CLI JSRejectedPromiseEntry (quickjs-libc.c:147-151).
pub const UnhandledRejectionEntry = struct {
    promise: JSValue = JSValue.undefinedValue(),
    reason: JSValue = JSValue.undefinedValue(),

    pub fn deinit(self: UnhandledRejectionEntry, rt: *JSRuntime) void {
        self.promise.free(rt);
        self.reason.free(rt);
    }
};

pub const JSContext = struct {
    pub const gc_kind_tag: u8 = @intFromEnum(gc.GcKind.realm_context);
    pub const Options = ContextOptions;
    pub const EvalOptions = ContextEvalOptions;
    pub const EvalTiming = ContextEvalTiming;

    comptime {
        std.debug.assert(@offsetOf(@This(), "header") == 0);
    }

    /// QuickJS `JSContext.header`: realm identity is itself a refcounted cycle
    /// collector node.  Keep this first; `MemoryAccount` places the common RC
    /// metadata immediately before it.
    header: gc.GCObjectHeader align(16) = .{},
    runtime: *JSRuntime,
    /// Independent, non-owning membership in `JSRuntime.context_*`.  The GC
    /// header links above are reserved exclusively for the collector.
    runtime_prev: ?*JSContext = null,
    runtime_next: ?*JSContext = null,
    construction_prev: ?*JSContext = null,
    construction_next: ?*JSContext = null,
    publication_state: RealmPublicationState = .constructing,
    construction_complete: bool = false,
    /// Realm-local module map. Every linked record's list base-ref is an owned
    /// Context -> ModuleRecord GC edge; record addresses stay stable.
    modules: module.Registry,
    /// Not-yet-handled rejected promises, in rejection order. Mirrors the qjs
    /// CLI host tracker list (js_std_promise_rejection_tracker's
    /// rejected_promise_list, quickjs-libc.c:4240-4269, driven by the
    /// per-promise is_handled transitions in fulfill_or_reject_promise
    /// quickjs.c:53451 and perform_promise_then quickjs.c:54224): one entry
    /// per promise, appended when it rejects unhandled, removed when that
    /// same promise later gets handled; every remaining entry is reported.
    unhandled_rejections: []UnhandledRejectionEntry = &.{},
    unhandled_rejections_capacity: usize = 0,
    preserve_uncaught_exception: bool = false,
    /// Host-controlled QuickJS-style unhandled rejection tracking. Normal CLI
    /// contexts enable it; validation and embedding-style contexts keep it off.
    track_unhandled_rejections: bool = false,
    class_prototypes: []JSValue = &.{},
    class_prototypes_inline: [class_prototype_inline_capacity]JSValue = @splat(JSValue.nullValue()),
    native_error_prototypes: [native_error_kind_count]JSValue = @splat(JSValue.nullValue()),
    cached_function_proto: ?*Object = null,
    cached_promise_proto: ?*Object = null,
    cached_values: [@intFromEnum(object_mod.RealmValueSlot.count)]?JSValue = @splat(null),
    /// QuickJS's five context-owned initial shapes. Values live in each fresh
    /// object's property cells; the realm owns only these immutable layouts.
    array_shape: ?*shape.Shape = null,
    arguments_shape: ?*shape.Shape = null,
    mapped_arguments_shape: ?*shape.Shape = null,
    regexp_shape: ?*shape.Shape = null,
    regexp_result_shape: ?*shape.Shape = null,
    regexp_legacy_statics: ?*object_mod.RegExpLegacyStatics = null,
    random_state: u64 = 0x1234_5678_9abc_def0,
    /// QuickJS `JSContext.interrupt_counter`. The raw context allocation is
    /// zero-filled, so the first semantic poll takes the slow arm and resets
    /// this to `interrupt_counter_reset`; later callbacks are exactly one reset
    /// interval apart. Runtime handler installation never mutates this state.
    interrupt_counter: i32 = 0,
    preallocated_oom_error: ?JSValue = null,
    /// Global object, populated lazily by the eval entry path.
    /// Sharing the global across `eval` calls matches QuickJS semantics
    /// (`JS_Eval` reuses the per-context globals) and skips rebuilding every
    /// standard constructor / prototype / host helper on each eval call. Owned
    /// by the context: freed in `destroy`.
    global: ?*Object = null,
    /// Top-level lexical environment for script `let` / `const` bindings.
    /// `var` and function declarations still live on `global`.
    lexicals: ?*Object = null,
    /// Original global `eval` object for QuickJS-style OP_eval dispatch.
    /// Direct-eval syntax only evaluates as direct eval when the resolved
    /// callee is this object; otherwise OP_eval falls back to an ordinary call.
    eval_function: JSValue = JSValue.nullValue(),
    host_event_loop: ?HostEventLoop = null,

    /// Returns an owned context. Caller must release it with `destroy`.
    pub fn create(rt: *JSRuntime) !*JSContext {
        return createWithOptions(rt, .{});
    }

    /// Returns an owned context. Caller must release it with `destroy`.
    pub fn createWithOptions(rt: *JSRuntime, options: ContextOptions) !*JSContext {
        return createWithPublication(rt, options, true);
    }

    /// Engine bootstrap constructor: the GC header is registered immediately,
    /// but the realm stays off every public/live traversal until `publishLive`.
    pub fn createConstructingWithOptions(rt: *JSRuntime, options: ContextOptions) !*JSContext {
        return createWithPublication(rt, options, false);
    }

    fn createWithPublication(rt: *JSRuntime, options: ContextOptions, publish_immediately: bool) !*JSContext {
        try rt.requireOwnerThread();
        const ctx = try rt.createRuntime(JSContext);
        var initialized = false;
        errdefer if (initialized) ctx.destroy() else rt.destroyRuntime(JSContext, ctx);
        try ctx.initConstructing(rt, options);
        initialized = true;
        if (publish_immediately) try ctx.finishConstruction();
        return ctx;
    }

    fn initConstructing(self: *JSContext, rt: *JSRuntime, options: ContextOptions) !void {
        if (options.stack_size) |stack_size| rt.setStackSize(stack_size);
        self.* = .{
            .header = .{},
            .runtime = rt,
            .track_unhandled_rejections = options.track_unhandled_rejections,
            .modules = module.Registry.init(&rt.memory, &rt.atoms, &rt.gc),
            .random_state = runtime_mod.newRealmRandomSeed(),
        };
        const initial_len = rt.classes.records.len;
        if (initial_len <= self.class_prototypes_inline.len) {
            self.class_prototypes = self.class_prototypes_inline[0..initial_len];
        } else {
            const prototypes = try rt.memory.alloc(JSValue, initial_len);
            errdefer rt.memory.free(JSValue, prototypes);
            @memset(prototypes, JSValue.nullValue());
            self.class_prototypes = prototypes;
        }
        errdefer self.deinitClassPrototypeSlots();
        try rt.gc.addInitializedWithSize(&self.header, @sizeOf(JSContext));
        rt.linkConstructingContext(self);
    }

    pub fn publishLive(self: *JSContext) !void {
        self.runtime.assertOwnerThread();
        switch (self.publication_state) {
            .live => return,
            .constructing => {},
            .finalizing => return error.InvalidBuiltinRegistry,
        }
        if (!self.construction_complete) return error.InvalidBuiltinRegistry;
        // This is the sole fallible step. If it triggers collection, the realm
        // remains absent from every live traversal.
        try self.runtime.registerRootProvider(self.rootProvider());
        self.runtime.unlinkConstructingContext(self);
        self.publication_state = .live;
        self.runtime.linkContext(self);
    }

    /// Checked publication boundary for embedders that cannot statically prove
    /// the Runtime owner thread. Engine bootstrap uses the asserting form above
    /// so this contract error does not widen JavaScript execution errors.
    pub fn publishLiveChecked(self: *JSContext) !void {
        try self.runtime.requireOwnerThread();
        return self.publishLive();
    }

    pub fn finishConstruction(self: *JSContext) !void {
        self.runtime.assertOwnerThread();
        if (self.publication_state == .live) return;
        if (self.publication_state != .constructing) return error.InvalidBuiltinRegistry;
        self.construction_complete = true;
        try self.publishLive();
    }

    pub fn finishConstructionChecked(self: *JSContext) !void {
        try self.runtime.requireOwnerThread();
        return self.finishConstruction();
    }

    pub fn publicationState(self: *const JSContext) RealmPublicationState {
        return self.publication_state;
    }

    pub fn isLive(self: *const JSContext) bool {
        return self.publication_state == .live;
    }

    pub fn runtimePtr(self: *JSContext) *JSRuntime {
        return self.runtime;
    }

    pub fn setStackLimit(self: *JSContext, size: usize) void {
        self.runtime.setStackSize(size);
    }

    pub fn stackLimit(self: JSContext) usize {
        return self.runtime.stackSize();
    }

    pub const interrupt_counter_reset: i32 = 10_000;

    /// Advance this Realm's persistent interrupt cadence. Returns true only
    /// when the Runtime handler requests termination. The counter advances and
    /// resets even while no handler is installed.
    pub inline fn pollInterrupt(self: *JSContext) bool {
        self.interrupt_counter -= 1;
        if (self.interrupt_counter > 0) return false;
        return self.pollInterruptSlow();
    }

    noinline fn pollInterruptSlow(self: *JSContext) bool {
        self.interrupt_counter = interrupt_counter_reset;
        return self.runtime.runInterruptHandler();
    }

    pub fn setTrackUnhandledRejections(self: *JSContext, enabled: bool) void {
        self.track_unhandled_rejections = enabled;
    }

    pub fn tracksUnhandledRejections(self: JSContext) bool {
        return self.track_unhandled_rejections;
    }

    pub fn setPreserveUncaughtException(self: *JSContext, enabled: bool) void {
        self.preserve_uncaught_exception = enabled;
    }

    pub fn preservesUncaughtException(self: JSContext) bool {
        return self.preserve_uncaught_exception;
    }

    pub fn setHostEventLoop(self: *JSContext, host_event_loop: HostEventLoop) void {
        self.host_event_loop = host_event_loop;
    }

    pub fn clearHostEventLoop(self: *JSContext, ptr: *anyopaque) void {
        if (self.host_event_loop) |host_event_loop| {
            if (host_event_loop.ptr == ptr) self.host_event_loop = null;
        }
    }

    pub fn hostEventLoop(self: *JSContext) ?HostEventLoop {
        return self.host_event_loop;
    }

    fn usingInlineClassPrototypes(self: *const JSContext) bool {
        return self.class_prototypes.ptr == self.class_prototypes_inline[0..].ptr;
    }

    fn deinitClassPrototypeSlots(self: *JSContext) void {
        const rt = self.runtime;
        const class_prototypes = self.class_prototypes;
        const using_inline = self.usingInlineClassPrototypes();
        self.class_prototypes = &.{};
        for (class_prototypes) |*slot| {
            const value = slot.*;
            slot.* = JSValue.nullValue();
            value.free(rt);
        }
        if (!using_inline and class_prototypes.len != 0) {
            rt.memory.free(JSValue, class_prototypes);
        }
    }

    pub fn ensureClassPrototypeSlot(self: *JSContext, class_id: class.ClassId) !*JSValue {
        self.runtime.assertOwnerThread();
        const index: usize = @intCast(class_id);
        if (index >= self.class_prototypes.len) {
            var next_len = if (self.class_prototypes.len == 0) @as(usize, 1) else self.class_prototypes.len + self.class_prototypes.len / 2;
            while (next_len <= index) : (next_len += next_len / 2 + 1) {}

            const next = try self.runtime.memory.alloc(JSValue, next_len);
            errdefer self.runtime.memory.free(JSValue, next);
            @memcpy(next[0..self.class_prototypes.len], self.class_prototypes);
            @memset(next[self.class_prototypes.len..], JSValue.nullValue());

            const old = self.class_prototypes;
            const old_using_inline = self.usingInlineClassPrototypes();
            self.class_prototypes = next;
            if (old_using_inline) {
                @memset(old, JSValue.nullValue());
            } else if (old.len != 0) {
                self.runtime.memory.free(JSValue, old);
            }
        }
        return &self.class_prototypes[index];
    }

    pub fn setClassPrototype(self: *JSContext, class_id: class.ClassId, prototype: *Object) !void {
        const slot = try self.ensureClassPrototypeSlot(class_id);
        const old = slot.*;
        slot.* = prototype.value().dup();
        old.free(self.runtime);
    }

    pub fn clearClassPrototype(self: *JSContext, class_id: class.ClassId) void {
        self.runtime.assertOwnerThread();
        const index: usize = @intCast(class_id);
        if (index >= self.class_prototypes.len) return;
        const old = self.class_prototypes[index];
        self.class_prototypes[index] = JSValue.nullValue();
        old.free(self.runtime);
    }

    pub fn classPrototypeObject(self: *JSContext, class_id: class.ClassId) ?*Object {
        const index: usize = @intCast(class_id);
        if (index >= self.class_prototypes.len) return null;
        const value = self.class_prototypes[index];
        if (!value.isObject()) return null;
        const header = value.refHeader() orelse return null;
        if (header.meta().kind != .object) return null;
        return @fieldParentPtr("header", header);
    }

    pub fn setNativeErrorPrototype(self: *JSContext, kind: NativeErrorKind, prototype: *Object) void {
        self.runtime.assertOwnerThread();
        std.debug.assert(kind != .count);
        const slot = &self.native_error_prototypes[@intFromEnum(kind)];
        const old = slot.*;
        slot.* = prototype.value().dup();
        old.free(self.runtime);
    }

    pub fn nativeErrorPrototypeObject(self: *JSContext, kind: NativeErrorKind) ?*Object {
        if (kind == .count) return null;
        const value = self.native_error_prototypes[@intFromEnum(kind)];
        if (!value.isObject()) return null;
        const header = value.refHeader() orelse return null;
        if (header.meta().kind != .object) return null;
        return @fieldParentPtr("header", header);
    }

    pub fn initializeInitialShapes(
        self: *JSContext,
        object_prototype: ?*Object,
        array_prototype: ?*Object,
        regexp_prototype: ?*Object,
    ) !void {
        if (self.array_shape != null) return;
        std.debug.assert(self.arguments_shape == null);
        std.debug.assert(self.mapped_arguments_shape == null);
        std.debug.assert(self.regexp_shape == null);
        std.debug.assert(self.regexp_result_shape == null);

        const data_hidden = property.Flags.data(true, false, true).bits();
        const arguments_properties = [_]shape.InitialProperty{
            .{ .atom_id = atom.ids.length, .flags = data_hidden },
            .{ .atom_id = comptime atom.predefinedId("Symbol.iterator", .symbol).?, .flags = data_hidden },
            .{ .atom_id = comptime atom.predefinedId("callee", .string).?, .flags = property.Flags.accessorFlags(false, false).bits() },
        };
        const mapped_arguments_properties = [_]shape.InitialProperty{
            .{ .atom_id = atom.ids.length, .flags = data_hidden },
            .{ .atom_id = comptime atom.predefinedId("Symbol.iterator", .symbol).?, .flags = data_hidden },
            .{ .atom_id = comptime atom.predefinedId("callee", .string).?, .flags = data_hidden },
        };
        const regexp_properties = [_]shape.InitialProperty{
            .{ .atom_id = atom.ids.lastIndex, .flags = property.Flags.data(true, false, false).bits() },
        };
        // Array length is scalar storage in zjs, so the array and RegExp-result
        // shapes omit QuickJS's ordinary length cell while preserving the same
        // realm-owned shape identities and named-property order.
        const regexp_result_properties = [_]shape.InitialProperty{
            .{ .atom_id = comptime atom.predefinedId("index", .string).?, .flags = property.Flags.data(true, true, true).bits() },
            .{ .atom_id = comptime atom.predefinedId("input", .string).?, .flags = property.Flags.data(true, true, true).bits() },
            .{ .atom_id = comptime atom.predefinedId("groups", .string).?, .flags = property.Flags.data(true, true, true).bits() },
        };

        const array_shape = try self.runtime.shapes.createInitialShape(array_prototype, &.{});
        errdefer self.runtime.shapes.release(array_shape);
        const arguments_shape = try self.runtime.shapes.createInitialShape(object_prototype, &arguments_properties);
        errdefer self.runtime.shapes.release(arguments_shape);
        const mapped_arguments_shape = try self.runtime.shapes.createInitialShape(object_prototype, &mapped_arguments_properties);
        errdefer self.runtime.shapes.release(mapped_arguments_shape);
        const regexp_shape = try self.runtime.shapes.createInitialShape(regexp_prototype, &regexp_properties);
        errdefer self.runtime.shapes.release(regexp_shape);
        const regexp_result_shape = try self.runtime.shapes.createInitialShape(array_prototype, &regexp_result_properties);
        errdefer self.runtime.shapes.release(regexp_result_shape);

        self.array_shape = array_shape;
        self.arguments_shape = arguments_shape;
        self.mapped_arguments_shape = mapped_arguments_shape;
        self.regexp_shape = regexp_shape;
        self.regexp_result_shape = regexp_result_shape;
    }

    fn releaseInitialShape(self: *JSContext, slot: *?*shape.Shape) void {
        const owned = slot.* orelse return;
        slot.* = null;
        if (self.runtime.gc.phase == .remove_cycles and owned.header.metaConst().flags.cycle_visited) return;
        self.runtime.shapes.release(owned);
    }

    fn clearIntrinsicBootstrapValues(self: *JSContext) void {
        const rt = self.runtime;
        const old_eval = self.eval_function;
        self.eval_function = JSValue.nullValue();
        old_eval.free(rt);
        if (self.cached_function_proto) |prototype| prototype.value().free(rt);
        self.cached_function_proto = null;
        if (self.cached_promise_proto) |prototype| prototype.value().free(rt);
        self.cached_promise_proto = null;
        for (&self.cached_values) |*slot| {
            if (slot.*) |value| value.free(rt);
            slot.* = null;
        }
        for (&self.native_error_prototypes) |*slot| {
            const value = slot.*;
            slot.* = JSValue.nullValue();
            value.free(rt);
        }
        self.releaseInitialShape(&self.array_shape);
        self.releaseInitialShape(&self.arguments_shape);
        self.releaseInitialShape(&self.mapped_arguments_shape);
        self.releaseInitialShape(&self.regexp_shape);
        self.releaseInitialShape(&self.regexp_result_shape);
        if (self.preallocated_oom_error) |value| value.free(rt);
        self.preallocated_oom_error = null;
    }

    /// Roll back only the Realm-owned state published by intrinsic/global
    /// bootstrap. The candidate global remains associated while this runs so
    /// native-function Realm lookups stay valid during recursive release.
    /// Dynamic class prototype slots belong to embedders and survive a retry;
    /// the standard prefix is rebuilt with the next candidate global.
    pub fn rollbackIntrinsicBootstrap(self: *JSContext) void {
        self.runtime.assertOwnerThread();
        std.debug.assert(self.publication_state != .finalizing);
        std.debug.assert(self.lexicals == null);
        std.debug.assert(self.regexp_legacy_statics == null);
        self.clearIntrinsicBootstrapValues();
        const builtin_count = @min(self.class_prototypes.len, @as(usize, @intCast(class.ids.init_count)));
        for (self.class_prototypes[0..builtin_count]) |*slot| {
            const value = slot.*;
            slot.* = JSValue.nullValue();
            value.free(self.runtime);
        }
        if (self.publication_state == .constructing) self.construction_complete = false;
    }

    fn deinitResources(self: *JSContext) void {
        const rt = self.runtime;
        rt.assertOwnerThread();
        switch (self.publication_state) {
            .constructing => rt.unlinkConstructingContext(self),
            .live => {
                rt.unlinkContext(self);
                rt.unregisterRootProvider(self.rootProvider());
            },
            .finalizing => unreachable,
        }
        self.publication_state = .finalizing;
        // Drop Realm -> ModuleRecord base refs before releasing globals and
        // intrinsics: module records may themselves own values in this Realm.
        self.modules.deinit(rt);
        self.host_event_loop = null;
        self.clearUnhandledRejection();
        const old_lexicals = self.lexicals;
        self.lexicals = null;
        const old_global = self.global;
        self.global = null;
        if (old_lexicals) |lexicals| lexicals.value().free(rt);
        if (old_global) |global| global.value().free(rt);
        self.clearIntrinsicBootstrapValues();
        if (self.regexp_legacy_statics) |legacy| {
            legacy.destroy(rt);
            rt.destroyRuntime(object_mod.RegExpLegacyStatics, legacy);
            self.regexp_legacy_statics = null;
        }
        self.deinitClassPrototypeSlots();
    }

    pub fn destroy(self: *JSContext) void {
        self.runtime.assertOwnerThread();
        gc.release(self.runtime, &self.header);
    }

    /// Checked release entry for hosts that cannot statically guarantee the
    /// Runtime owner thread. A wrong-thread call does not decrement the Realm.
    pub fn tryDestroy(self: *JSContext) runtime_mod.RuntimeMutationError!void {
        try self.runtime.requireOwnerThread();
        gc.release(self.runtime, &self.header);
    }

    pub fn destroyFromHeader(rt: *JSRuntime, header: *gc.Header) void {
        rt.assertOwnerThread();
        const self: *JSContext = @alignCast(@fieldParentPtr("header", header));
        self.deinitResources();
        if (rt.gc.phase == .remove_cycles) {
            rt.gc.deferCycleStructFree(header);
            return;
        }
        rt.destroyRuntime(JSContext, self);
    }

    pub fn freeCycleDeferredStruct(rt: *JSRuntime, header: *gc.Header) void {
        rt.assertOwnerThread();
        const self: *JSContext = @alignCast(@fieldParentPtr("header", header));
        rt.destroyRuntime(JSContext, self);
    }

    pub fn dupValue(self: *JSContext, value: JSValue) JSValue {
        return self.runtime.dupValue(value);
    }

    pub fn freeValue(self: *JSContext, value: JSValue) void {
        self.runtime.freeValue(value);
    }

    pub fn createValueHandle(self: *JSContext, value: JSValue) !runtime_mod.JSValueHandle {
        return self.runtime.createValueHandle(value);
    }

    pub fn takeValueHandle(self: *JSContext, value: JSValue) !runtime_mod.JSValueHandle {
        return self.runtime.takeValueHandle(value);
    }

    pub fn traceRoots(self: *JSContext, visitor: *runtime_mod.RootVisitor) runtime_mod.RootTraceError!void {
        if (self.publication_state != .live) return;
        for (self.unhandled_rejections) |*entry| {
            try visitor.value(&entry.promise);
            try visitor.value(&entry.reason);
        }
        try visitor.value(&self.eval_function);
        if (self.preallocated_oom_error) |*value| try visitor.value(value);
        try visitor.values(self.class_prototypes);
        try visitor.values(&self.native_error_prototypes);
        if (self.cached_function_proto) |prototype| {
            var rooted: ?*Object = prototype;
            try visitor.optionalObject(&rooted);
            self.cached_function_proto = rooted;
        }
        if (self.cached_promise_proto) |prototype| {
            var rooted: ?*Object = prototype;
            try visitor.optionalObject(&rooted);
            self.cached_promise_proto = rooted;
        }
        for (&self.cached_values) |*slot| if (slot.*) |*value| try visitor.value(value);
        if (self.regexp_legacy_statics) |legacy| {
            if (legacy.input) |*value| try visitor.value(value);
            if (legacy.last_match) |*value| try visitor.value(value);
            if (legacy.last_paren) |*value| try visitor.value(value);
            if (legacy.left_context) |*value| try visitor.value(value);
            if (legacy.right_context) |*value| try visitor.value(value);
            for (&legacy.captures) |*slot| if (slot.*) |*value| try visitor.value(value);
        }
        try visitor.optionalObject(&self.global);
        try visitor.optionalObject(&self.lexicals);
        if (self.host_event_loop) |host_event_loop| {
            try host_event_loop.traceRoots(visitor);
        }
    }

    /// Infallible owned-edge enumeration used by the RC cycle collector.  The
    /// runtime context-list link is deliberately absent: it is membership, not
    /// ownership.
    pub fn traceChildEdgesNoFail(self: *JSContext, visitor: anytype) void {
        if (self.publication_state == .finalizing) return;
        self.modules.traceChildEdgesNoFail(visitor);
        for (self.unhandled_rejections) |*entry| {
            visitor.visitValue(&entry.promise);
            visitor.visitValue(&entry.reason);
        }
        visitor.visitValue(&self.eval_function);
        if (self.preallocated_oom_error) |*value| visitor.visitValue(value);
        for (self.class_prototypes) |*prototype| visitor.visitValue(prototype);
        for (&self.native_error_prototypes) |*prototype| visitor.visitValue(prototype);
        visitor.visitObject(&self.cached_function_proto);
        visitor.visitObject(&self.cached_promise_proto);
        if (self.array_shape) |owned| visitor.visitShape(owned);
        if (self.arguments_shape) |owned| visitor.visitShape(owned);
        if (self.mapped_arguments_shape) |owned| visitor.visitShape(owned);
        if (self.regexp_shape) |owned| visitor.visitShape(owned);
        if (self.regexp_result_shape) |owned| visitor.visitShape(owned);
        for (&self.cached_values) |*slot| if (slot.*) |*value| visitor.visitValue(value);
        if (self.regexp_legacy_statics) |legacy| {
            if (legacy.input) |*value| visitor.visitValue(value);
            if (legacy.last_match) |*value| visitor.visitValue(value);
            if (legacy.last_paren) |*value| visitor.visitValue(value);
            if (legacy.left_context) |*value| visitor.visitValue(value);
            if (legacy.right_context) |*value| visitor.visitValue(value);
            for (&legacy.captures) |*slot| if (slot.*) |*value| visitor.visitValue(value);
        }
        visitor.visitObject(&self.global);
        visitor.visitObject(&self.lexicals);
    }

    pub fn arrayBuffer(self: *JSContext, store: *JSValue.Bytes.Store) !JSValue {
        return store.toArrayBuffer(self);
    }

    fn rootProvider(self: *JSContext) runtime_mod.RootProvider {
        return .{
            .context = self,
            .trace = traceRootProvider,
        };
    }

    fn traceRootProvider(context: *anyopaque, visitor: *runtime_mod.RootVisitor) runtime_mod.RootTraceError!void {
        const self: *JSContext = @ptrCast(@alignCast(context));
        try self.traceRoots(visitor);
    }

    pub fn throwValue(self: *JSContext, value: JSValue) JSValue {
        const old = self.runtime.current_exception;
        self.runtime.current_exception = JSValue.uninitialized();
        self.runtime.current_exception_uncatchable = false;
        old.free(self.runtime);
        self.runtime.current_exception = value;
        return JSValue.exception();
    }

    pub fn setExceptionUncatchable(self: *JSContext, uncatchable: bool) void {
        std.debug.assert(!uncatchable or self.hasException());
        self.runtime.current_exception_uncatchable = uncatchable;
    }

    pub fn exceptionIsUncatchable(self: JSContext) bool {
        return self.hasException() and self.runtime.current_exception_uncatchable;
    }

    pub fn hasException(self: JSContext) bool {
        return !self.runtime.current_exception.isUninitialized();
    }

    pub fn takeException(self: *JSContext) JSValue {
        if (!self.hasException()) return JSValue.undefinedValue();
        const result = self.runtime.current_exception;
        self.runtime.current_exception = JSValue.uninitialized();
        self.runtime.current_exception_uncatchable = false;
        return result;
    }

    pub fn clearException(self: *JSContext) void {
        const old = self.runtime.current_exception;
        self.runtime.current_exception = JSValue.uninitialized();
        self.runtime.current_exception_uncatchable = false;
        old.free(self.runtime);
    }

    pub fn recordUnhandledRejection(self: *JSContext, value: JSValue) void {
        self.recordUnhandledPromiseRejection(null, value);
    }

    /// Mirrors the qjs CLI tracker's !is_handled branch
    /// (js_std_promise_rejection_tracker quickjs-libc.c:4248-4258): append a
    /// (promise, reason) entry unless this promise is already tracked; every
    /// unhandled rejection is reported once, in rejection order. Allocation
    /// failure silently drops the entry, exactly as the qjs CLI's unchecked
    /// malloc does.
    pub fn recordUnhandledPromiseRejection(self: *JSContext, promise: ?JSValue, value: JSValue) void {
        if (promise) |promise_value| {
            for (self.unhandled_rejections) |entry| {
                if (entry.promise.same(promise_value)) return;
            }
        }
        self.appendUnhandledRejection(promise, value) catch return;
        if (!self.hasException()) {
            _ = self.throwValue(value.dup());
        }
    }

    fn appendUnhandledRejection(self: *JSContext, promise: ?JSValue, value: JSValue) !void {
        const index = self.unhandled_rejections.len;
        if (index + 1 > self.unhandled_rejections_capacity) {
            var next_capacity = if (self.unhandled_rejections_capacity == 0) @as(usize, 4) else self.unhandled_rejections_capacity * 2;
            while (next_capacity < index + 1) : (next_capacity *= 2) {}
            const next = try self.runtime.memory.alloc(UnhandledRejectionEntry, next_capacity);
            const old = self.unhandled_rejections;
            const old_capacity = self.unhandled_rejections_capacity;
            @memcpy(next[0..old.len], old);
            self.unhandled_rejections = next[0..old.len];
            self.unhandled_rejections_capacity = next_capacity;
            if (old_capacity != 0) self.runtime.memory.free(UnhandledRejectionEntry, old.ptr[0..old_capacity]);
        }
        self.unhandled_rejections = self.unhandled_rejections.ptr[0 .. index + 1];
        self.unhandled_rejections[index] = .{
            .promise = if (promise) |promise_value| promise_value.dup() else JSValue.undefinedValue(),
            .reason = value.dup(),
        };
    }

    /// Mirrors the tracker's is_handled branch (js_std_promise_rejection_tracker
    /// quickjs-libc.c:4259-4268): handling a promise unreports THAT promise
    /// only — entries for other promises stay tracked (even with a sameValue
    /// reason).
    pub fn removeUnhandledPromiseRejection(self: *JSContext, promise_value: JSValue) void {
        const entries = self.unhandled_rejections;
        for (entries, 0..) |entry, index| {
            if (!entry.promise.same(promise_value)) continue;
            entry.deinit(self.runtime);
            const old_len = entries.len;
            if (index + 1 < old_len) {
                @memmove(entries[index .. old_len - 1], entries[index + 1 .. old_len]);
            }
            self.unhandled_rejections = entries[0 .. old_len - 1];
            return;
        }
    }

    pub fn hasUnhandledRejection(self: JSContext) bool {
        return self.unhandled_rejections.len != 0;
    }

    /// Pops the OLDEST tracked rejection and returns its reason (owned by the
    /// caller); reporting loops call this until the list drains, matching
    /// js_std_promise_rejection_check's in-order walk (quickjs-libc.c:4281).
    pub fn takeUnhandledRejection(self: *JSContext) JSValue {
        const entries = self.unhandled_rejections;
        if (entries.len == 0) return JSValue.undefinedValue();
        const entry = entries[0];
        if (entries.len > 1) {
            @memmove(entries[0 .. entries.len - 1], entries[1..entries.len]);
        }
        self.unhandled_rejections = entries[0 .. entries.len - 1];
        entry.promise.free(self.runtime);
        return entry.reason;
    }

    pub fn clearUnhandledRejection(self: *JSContext) void {
        const rt = self.runtime;
        const entries = self.unhandled_rejections;
        const capacity = self.unhandled_rejections_capacity;
        self.unhandled_rejections = &.{};
        self.unhandled_rejections_capacity = 0;
        for (entries) |entry| entry.deinit(rt);
        if (capacity != 0) rt.memory.free(UnhandledRejectionEntry, entries.ptr[0..capacity]);
    }

    pub fn classPrototypeSlotCount(self: JSContext) usize {
        return self.class_prototypes.len;
    }

    pub fn pushBacktraceFrame(
        self: *JSContext,
        function_name: atom.Atom,
        filename: atom.Atom,
        line_num: i32,
        col_num: i32,
    ) !void {
        try self.pushBacktraceFrameWithResolver(function_name, filename, line_num, col_num, null, null);
    }

    pub fn pushBacktraceFrameWithResolver(
        self: *JSContext,
        function_name: atom.Atom,
        filename: atom.Atom,
        line_num: i32,
        col_num: i32,
        location_data: ?*const anyopaque,
        location_resolver: ?BacktraceLocationResolver,
    ) !void {
        try self.pushBacktraceFrameLazyName(function_name, filename, line_num, col_num, location_data, location_resolver, JSValue.undefinedValue());
    }

    pub fn pushActiveBacktraceFrame(self: *JSContext, frame: *ActiveBacktraceFrame) void {
        frame.previous = self.runtime.current_backtrace_frame;
        self.runtime.current_backtrace_frame = frame;
    }

    pub fn popActiveBacktraceFrame(self: *JSContext, frame: *ActiveBacktraceFrame) void {
        std.debug.assert(self.runtime.current_backtrace_frame == frame);
        self.runtime.current_backtrace_frame = frame.previous;
        frame.previous = null;
    }

    pub fn snapshotBacktraceFrames(self: *JSContext) ![]BacktraceFrame {
        // Each active node now resolves a whole frame GROUP (a VM invocation's
        // inline Entry chain + its L0 frame), enumerated innermost-first via the
        // indexed resolver until it returns null. A `backtrace_barrier` frame
        // stops the entire walk (and is itself excluded), matching qjs.
        var active_count: usize = 0;
        {
            var active = self.runtime.current_backtrace_frame;
            count: while (active) |frame| {
                var index: usize = 0;
                while (frame.resolver(frame.data, index)) |snapshot| : (index += 1) {
                    if (snapshot.backtrace_barrier) break :count;
                    active_count += 1;
                }
                active = frame.previous;
            }
        }

        const total = self.runtime.backtrace_frames.len + active_count;
        if (total == 0) return &.{};
        const frames = try self.runtime.memory.alloc(BacktraceFrame, total);

        for (self.runtime.backtrace_frames, 0..) |frame, idx| {
            frames[idx] = self.dupBacktraceFrame(frame);
        }

        // Fill the active section so the innermost frame lands LAST (the array
        // order is [persistent (outer)..., oldest-active...innermost]), the same
        // order the previous per-node walk produced.
        var active_index = active_count;
        {
            var active = self.runtime.current_backtrace_frame;
            fill: while (active) |frame| {
                var index: usize = 0;
                while (frame.resolver(frame.data, index)) |snapshot| : (index += 1) {
                    if (snapshot.backtrace_barrier) break :fill;
                    active_index -= 1;
                    frames[self.runtime.backtrace_frames.len + active_index] = self.dupActiveBacktraceFrameFromSnapshot(snapshot);
                }
                active = frame.previous;
            }
        }
        return frames;
    }

    pub fn freeBacktraceFrameSnapshot(self: *JSContext, frames: []BacktraceFrame) void {
        for (frames) |frame| {
            self.runtime.atoms.free(frame.function_name);
            self.runtime.atoms.free(frame.filename);
            frame.function_value.free(self.runtime);
        }
        if (frames.len != 0) self.runtime.memory.free(BacktraceFrame, frames);
    }

    fn dupBacktraceFrame(self: *JSContext, frame: BacktraceFrame) BacktraceFrame {
        return .{
            .function_name = self.runtime.atoms.dup(frame.function_name),
            .filename = self.runtime.atoms.dup(frame.filename),
            .line_num = frame.line_num,
            .col_num = frame.col_num,
            .pc = frame.currentPc(),
            .location_data = frame.location_data,
            .location_resolver = frame.location_resolver,
            .function_value = if (frame.function_value.isObject()) frame.function_value.dup() else JSValue.undefinedValue(),
            .is_native = frame.is_native,
        };
    }

    fn dupActiveBacktraceFrameFromSnapshot(self: *JSContext, snapshot: ActiveBacktraceSnapshot) BacktraceFrame {
        return .{
            .function_name = self.runtime.atoms.dup(snapshot.function_name),
            .filename = self.runtime.atoms.dup(snapshot.filename),
            .line_num = snapshot.line_num,
            .col_num = snapshot.col_num,
            .pc = snapshot.pc,
            .location_data = snapshot.location_data,
            .location_resolver = snapshot.location_resolver,
            .function_value = if (snapshot.function_value.isObject()) snapshot.function_value.dup() else JSValue.undefinedValue(),
            .is_native = snapshot.is_native,
        };
    }

    /// Push a backtrace frame whose display name is resolved lazily from
    /// `function_value` (an object) only when a backtrace is materialized.
    /// `function_name` stays the fallback for non-object function values.
    pub fn pushBacktraceFrameLazyName(
        self: *JSContext,
        function_name: atom.Atom,
        filename: atom.Atom,
        line_num: i32,
        col_num: i32,
        location_data: ?*const anyopaque,
        location_resolver: ?BacktraceLocationResolver,
        function_value: JSValue,
    ) !void {
        if (self.runtime.backtrace_frames.len == self.runtime.backtrace_capacity) {
            var next_capacity: usize = if (self.runtime.backtrace_capacity == 0) 16 else self.runtime.backtrace_capacity * 2;
            if (next_capacity < self.runtime.backtrace_frames.len + 1) next_capacity = self.runtime.backtrace_frames.len + 1;
            const next = try self.runtime.memory.alloc(BacktraceFrame, next_capacity);
            const old_frames = self.runtime.backtrace_frames;
            const old_capacity = self.runtime.backtrace_capacity;
            @memcpy(next[0..old_frames.len], old_frames);
            self.runtime.backtrace_frames = next[0..old_frames.len];
            self.runtime.backtrace_capacity = next_capacity;
            if (old_capacity != 0) self.runtime.memory.free(BacktraceFrame, old_frames.ptr[0..old_capacity]);
        }
        const stored_function_value = if (function_value.isObject()) function_value.dup() else JSValue.undefinedValue();
        self.runtime.backtrace_frames.ptr[self.runtime.backtrace_frames.len] = .{
            .function_name = self.runtime.atoms.dup(function_name),
            .filename = self.runtime.atoms.dup(filename),
            .line_num = line_num,
            .col_num = col_num,
            .location_data = location_data,
            .location_resolver = location_resolver,
            .function_value = stored_function_value,
        };
        self.runtime.backtrace_frames = self.runtime.backtrace_frames.ptr[0 .. self.runtime.backtrace_frames.len + 1];
    }

    pub fn popBacktraceFrame(self: *JSContext) void {
        if (self.runtime.backtrace_frames.len == 0) return;
        const idx = self.runtime.backtrace_frames.len - 1;
        const entry = self.runtime.backtrace_frames[idx];
        self.runtime.backtrace_frames = self.runtime.backtrace_frames.ptr[0..idx];
        self.runtime.atoms.free(entry.function_name);
        self.runtime.atoms.free(entry.filename);
        entry.function_value.free(self.runtime);
    }

    pub fn updateBacktracePc(self: *JSContext, pc: usize) void {
        if (self.runtime.backtrace_frames.len == 0) return;
        const idx = self.runtime.backtrace_frames.len - 1;
        self.runtime.backtrace_frames[idx].pc_source = null;
        self.runtime.backtrace_frames[idx].pc = pc;
    }

    pub fn borrowBacktracePc(self: *JSContext, pc_source: *const usize) void {
        if (self.runtime.backtrace_frames.len == 0) return;
        self.runtime.backtrace_frames[self.runtime.backtrace_frames.len - 1].pc_source = pc_source;
    }

    pub fn updateBacktraceLocation(self: *JSContext, pc: usize, line_num: i32, col_num: i32) void {
        if (self.runtime.backtrace_frames.len == 0) return;
        const idx = self.runtime.backtrace_frames.len - 1;
        self.runtime.backtrace_frames[idx].pc_source = null;
        self.runtime.backtrace_frames[idx].pc = pc;
        self.runtime.backtrace_frames[idx].line_num = line_num;
        self.runtime.backtrace_frames[idx].col_num = col_num;
    }

    pub fn takePendingException(self: *JSContext) JSValue {
        if (self.hasUnhandledRejection()) {
            const rejection = self.takeUnhandledRejection();
            if (self.hasException()) self.clearException();
            return rejection;
        }
        return self.takeException();
    }

    pub fn globalObject(self: *JSContext) !*Object {
        if (self.global) |existing| return existing;
        if (self.runtime.materialize_context_global_cb) |cb| {
            return cb(self);
        }
        return error.InvalidBuiltinRegistry;
    }
};

/// Realm identity.  zjs keeps the public `JSContext` spelling for API
/// compatibility; the two names intentionally denote the same QuickJS-style
/// GC object, not a wrapper and a separate realm record.
pub const RealmContext = JSContext;

/// One owning context reference, matching `JS_DupContext` / `JS_FreeContext`.
/// Runtime context-list membership is deliberately not represented here.
pub const RealmRef = extern struct {
    ptr: ?*RealmContext = null,

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(?*RealmContext));
    }

    pub fn takeOwned(ctx: *RealmContext) RealmRef {
        return .{ .ptr = ctx };
    }

    pub fn retain(ctx: *RealmContext) RealmRef {
        gc.retain(&ctx.header);
        return .{ .ptr = ctx };
    }

    pub fn clone(self: RealmRef) RealmRef {
        if (self.ptr) |ctx| gc.retain(&ctx.header);
        return self;
    }

    pub fn borrow(self: RealmRef) ?*RealmContext {
        return self.ptr;
    }

    pub fn deinit(self: *RealmRef) void {
        const ctx = self.ptr orelse return;
        self.ptr = null;
        gc.release(ctx.runtime, &ctx.header);
    }
};
