const std = @import("std");

const atom = @import("atom.zig");
const class = @import("class.zig");
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Descriptor = @import("descriptor.zig").Descriptor;
const exception = @import("exception.zig");
const runtime_mod = @import("runtime.zig");
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
    dynamic_import_callback: ?DynamicImportCallback = null,
    dynamic_import_userdata: ?*anyopaque = null,
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

pub const PendingPromiseJob = struct {
    sequence: u64 = 0,
    value: JSValue = JSValue.undefinedValue(),
    value_symbol_rooted: bool = false,

    pub fn init(ctx: *JSContext, sequence: u64, value: JSValue) !PendingPromiseJob {
        var job = PendingPromiseJob{
            .sequence = sequence,
            .value = value.dup(),
        };
        errdefer job.value.free(ctx.runtime);
        job.value_symbol_rooted = try ctx.runtime.registerExternalValueSymbolRoot(value);
        return job;
    }

    pub fn deinit(self: PendingPromiseJob, rt: *JSRuntime) void {
        if (self.value_symbol_rooted) rt.unregisterExternalValueSymbolRoot(self.value);
        self.value.free(rt);
    }

    pub fn traceRoots(self: *PendingPromiseJob, visitor: *runtime_mod.RootVisitor) runtime_mod.RootTraceError!void {
        try visitor.value(&self.value);
    }
};

const class_prototype_inline_capacity: usize = class.ids.init_count;

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
    pub const Options = ContextOptions;
    pub const EvalOptions = ContextEvalOptions;
    pub const EvalTiming = ContextEvalTiming;

    runtime: *JSRuntime,
    exception_slot: exception.ExceptionSlot = .{},
    /// Not-yet-handled rejected promises, in rejection order. Mirrors the qjs
    /// CLI host tracker list (js_std_promise_rejection_tracker's
    /// rejected_promise_list, quickjs-libc.c:4240-4269, driven by the
    /// per-promise is_handled transitions in fulfill_or_reject_promise
    /// quickjs.c:53451 and perform_promise_then quickjs.c:54224): one entry
    /// per promise, appended when it rejects unhandled, removed when that
    /// same promise later gets handled; every remaining entry is reported.
    unhandled_rejections: []UnhandledRejectionEntry = &.{},
    unhandled_rejections_capacity: usize = 0,
    stack_limit: usize = 0,
    /// Logical JS call depth (recursive interpreter entries + inline frames).
    call_depth: usize = 0,
    /// Native interpreter recursion depth only (excludes inline frames, which
    /// consume no native stack). Guards against native stack exhaustion.
    native_call_depth: usize = 0,
    preserve_uncaught_exception: bool = false,
    /// Host-controlled QuickJS-style unhandled rejection tracking. Normal CLI
    /// contexts enable it; validation and embedding-style contexts keep it off.
    track_unhandled_rejections: bool = false,
    formatting_error_stack: bool = false,
    backtrace_frames: []BacktraceFrame = &.{},
    backtrace_capacity: usize = 0,
    current_backtrace_frame: ?*ActiveBacktraceFrame = null,
    /// Exec-owned, stack-local state for the currently running typed native
    /// function. Core deliberately keeps this opaque: native cproto handlers
    /// receive their public ABI arguments directly, while exec can recover
    /// realm/VM state without putting an exec-specific argument pack in the
    /// runtime record table. Nested native calls save and restore this link.
    active_native_call: ?*const anyopaque = null,
    class_prototypes: []JSValue = &.{},
    class_prototypes_inline: [class_prototype_inline_capacity]JSValue = @splat(JSValue.nullValue()),
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
    dynamic_import_callback: ?DynamicImportCallback = null,
    dynamic_import_userdata: ?*anyopaque = null,
    host_event_loop: ?HostEventLoop = null,
    pending_promise_jobs: []PendingPromiseJob = &.{},
    pending_promise_jobs_capacity: usize = 0,

    /// Returns an owned context. Caller must release it with `destroy`.
    pub fn create(rt: *JSRuntime) !*JSContext {
        return createWithOptions(rt, .{});
    }

    /// Returns an owned context. Caller must release it with `destroy`.
    pub fn createWithOptions(rt: *JSRuntime, options: ContextOptions) !*JSContext {
        const ctx = try rt.memory.create(JSContext);
        errdefer rt.memory.destroy(JSContext, ctx);
        try ctx.init(rt, options);
        return ctx;
    }

    pub fn init(self: *JSContext, rt: *JSRuntime, options: ContextOptions) !void {
        self.* = .{
            .runtime = rt,
            .stack_limit = options.stack_size orelse rt.stackSize(),
            .track_unhandled_rejections = options.track_unhandled_rejections,
            .dynamic_import_callback = options.dynamic_import_callback,
            .dynamic_import_userdata = options.dynamic_import_userdata,
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
        var provider_registered = false;
        errdefer {
            if (provider_registered) rt.unregisterRootProvider(self.rootProvider());
            self.deinitClassPrototypeSlots();
        }
        try rt.registerRootProvider(self.rootProvider());
        provider_registered = true;
    }

    pub fn runtimePtr(self: *JSContext) *JSRuntime {
        return self.runtime;
    }

    pub fn setStackLimit(self: *JSContext, size: usize) void {
        self.stack_limit = size;
    }

    pub fn stackLimit(self: JSContext) usize {
        return self.stack_limit;
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

    pub fn deinit(self: *JSContext) void {
        const rt = self.runtime;
        rt.unregisterRootProvider(self.rootProvider());
        self.host_event_loop = null;
        self.exception_slot.clear(rt);
        self.clearUnhandledRejection();
        const old_eval = self.eval_function;
        self.eval_function = JSValue.nullValue();
        const old_lexicals = self.lexicals;
        self.lexicals = null;
        const old_global = self.global;
        self.global = null;
        old_eval.free(rt);
        if (old_lexicals) |lexicals| lexicals.value().free(rt);
        if (old_global) |global| global.value().free(rt);
        const pending_promise_jobs = self.pending_promise_jobs;
        const pending_promise_jobs_capacity = self.pending_promise_jobs_capacity;
        self.pending_promise_jobs = &.{};
        self.pending_promise_jobs_capacity = 0;
        for (pending_promise_jobs) |job| job.deinit(rt);
        if (pending_promise_jobs_capacity != 0) rt.memory.free(PendingPromiseJob, pending_promise_jobs.ptr[0..pending_promise_jobs_capacity]);
        const backtrace_frames = self.backtrace_frames;
        const backtrace_capacity = self.backtrace_capacity;
        self.backtrace_frames = &.{};
        self.backtrace_capacity = 0;
        for (backtrace_frames) |frame| {
            rt.atoms.free(frame.function_name);
            rt.atoms.free(frame.filename);
            frame.function_value.free(rt);
        }
        if (backtrace_capacity != 0) rt.memory.free(BacktraceFrame, backtrace_frames.ptr[0..backtrace_capacity]);
        self.deinitClassPrototypeSlots();
    }

    pub fn destroy(self: *JSContext) void {
        const rt = self.runtime;
        self.deinit();
        rt.memory.destroy(JSContext, self);
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
        try visitor.value(&self.exception_slot.value);
        for (self.unhandled_rejections) |*entry| {
            try visitor.value(&entry.promise);
            try visitor.value(&entry.reason);
        }
        try visitor.value(&self.eval_function);
        try visitor.values(self.class_prototypes);
        try visitor.optionalObject(&self.global);
        try visitor.optionalObject(&self.lexicals);
        for (self.pending_promise_jobs) |*job| {
            try job.traceRoots(visitor);
        }
        if (self.host_event_loop) |host_event_loop| {
            try host_event_loop.traceRoots(visitor);
        }
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

    pub fn ensurePendingPromiseJobCapacity(self: *JSContext, min_capacity: usize) !void {
        if (self.pending_promise_jobs_capacity >= min_capacity) return;
        var next_capacity = if (self.pending_promise_jobs_capacity == 0) @as(usize, 4) else self.pending_promise_jobs_capacity * 2;
        while (next_capacity < min_capacity) : (next_capacity *= 2) {}
        const next = try self.runtime.memory.alloc(PendingPromiseJob, next_capacity);
        errdefer self.runtime.memory.free(PendingPromiseJob, next);
        const old_jobs = self.pending_promise_jobs;
        const old_capacity = self.pending_promise_jobs_capacity;
        @memcpy(next[0..old_jobs.len], old_jobs);
        self.pending_promise_jobs = next[0..old_jobs.len];
        self.pending_promise_jobs_capacity = next_capacity;
        if (old_capacity != 0) {
            self.runtime.memory.free(PendingPromiseJob, old_jobs.ptr[0..old_capacity]);
        }
    }

    pub fn peekPendingPromiseJobSequence(self: JSContext) ?u64 {
        if (self.pending_promise_jobs.len == 0) return null;
        return self.pending_promise_jobs[0].sequence;
    }

    pub fn takePendingPromiseJob(self: *JSContext) ?PendingPromiseJob {
        if (self.pending_promise_jobs.len == 0) return null;
        const job = self.pending_promise_jobs[0];
        const old_len = self.pending_promise_jobs.len;
        if (old_len == 1) {
            const old_jobs = self.pending_promise_jobs.ptr[0..self.pending_promise_jobs_capacity];
            self.pending_promise_jobs = &.{};
            self.pending_promise_jobs_capacity = 0;
            self.runtime.memory.free(PendingPromiseJob, old_jobs);
            return job;
        }
        @memmove(self.pending_promise_jobs[0 .. old_len - 1], self.pending_promise_jobs[1..old_len]);
        self.pending_promise_jobs = self.pending_promise_jobs.ptr[0 .. old_len - 1];
        return job;
    }

    pub fn throwValue(self: *JSContext, value: JSValue) JSValue {
        self.exception_slot.set(self.runtime, value);
        return JSValue.exception();
    }

    pub fn hasException(self: JSContext) bool {
        return self.exception_slot.hasException();
    }

    pub fn takeException(self: *JSContext) JSValue {
        return self.exception_slot.take();
    }

    pub fn clearException(self: *JSContext) void {
        self.exception_slot.clear(self.runtime);
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
        if (!self.exception_slot.hasException()) {
            self.exception_slot.set(self.runtime, value.dup());
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
        frame.previous = self.current_backtrace_frame;
        self.current_backtrace_frame = frame;
    }

    pub fn popActiveBacktraceFrame(self: *JSContext, frame: *ActiveBacktraceFrame) void {
        std.debug.assert(self.current_backtrace_frame == frame);
        self.current_backtrace_frame = frame.previous;
        frame.previous = null;
    }

    pub fn snapshotBacktraceFrames(self: *JSContext) ![]BacktraceFrame {
        // Each active node now resolves a whole frame GROUP (a VM invocation's
        // inline Entry chain + its L0 frame), enumerated innermost-first via the
        // indexed resolver until it returns null. A `backtrace_barrier` frame
        // stops the entire walk (and is itself excluded), matching qjs.
        var active_count: usize = 0;
        {
            var active = self.current_backtrace_frame;
            count: while (active) |frame| {
                var index: usize = 0;
                while (frame.resolver(frame.data, index)) |snapshot| : (index += 1) {
                    if (snapshot.backtrace_barrier) break :count;
                    active_count += 1;
                }
                active = frame.previous;
            }
        }

        const total = self.backtrace_frames.len + active_count;
        if (total == 0) return &.{};
        const frames = try self.runtime.memory.alloc(BacktraceFrame, total);

        for (self.backtrace_frames, 0..) |frame, idx| {
            frames[idx] = self.dupBacktraceFrame(frame);
        }

        // Fill the active section so the innermost frame lands LAST (the array
        // order is [persistent (outer)..., oldest-active...innermost]), the same
        // order the previous per-node walk produced.
        var active_index = active_count;
        {
            var active = self.current_backtrace_frame;
            fill: while (active) |frame| {
                var index: usize = 0;
                while (frame.resolver(frame.data, index)) |snapshot| : (index += 1) {
                    if (snapshot.backtrace_barrier) break :fill;
                    active_index -= 1;
                    frames[self.backtrace_frames.len + active_index] = self.dupActiveBacktraceFrameFromSnapshot(snapshot);
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
        if (self.backtrace_frames.len == self.backtrace_capacity) {
            var next_capacity: usize = if (self.backtrace_capacity == 0) 16 else self.backtrace_capacity * 2;
            if (next_capacity < self.backtrace_frames.len + 1) next_capacity = self.backtrace_frames.len + 1;
            const next = try self.runtime.memory.alloc(BacktraceFrame, next_capacity);
            const old_frames = self.backtrace_frames;
            const old_capacity = self.backtrace_capacity;
            @memcpy(next[0..old_frames.len], old_frames);
            self.backtrace_frames = next[0..old_frames.len];
            self.backtrace_capacity = next_capacity;
            if (old_capacity != 0) self.runtime.memory.free(BacktraceFrame, old_frames.ptr[0..old_capacity]);
        }
        const stored_function_value = if (function_value.isObject()) function_value.dup() else JSValue.undefinedValue();
        self.backtrace_frames.ptr[self.backtrace_frames.len] = .{
            .function_name = self.runtime.atoms.dup(function_name),
            .filename = self.runtime.atoms.dup(filename),
            .line_num = line_num,
            .col_num = col_num,
            .location_data = location_data,
            .location_resolver = location_resolver,
            .function_value = stored_function_value,
        };
        self.backtrace_frames = self.backtrace_frames.ptr[0 .. self.backtrace_frames.len + 1];
    }

    pub fn popBacktraceFrame(self: *JSContext) void {
        if (self.backtrace_frames.len == 0) return;
        const idx = self.backtrace_frames.len - 1;
        const entry = self.backtrace_frames[idx];
        self.backtrace_frames = self.backtrace_frames.ptr[0..idx];
        self.runtime.atoms.free(entry.function_name);
        self.runtime.atoms.free(entry.filename);
        entry.function_value.free(self.runtime);
    }

    pub fn updateBacktracePc(self: *JSContext, pc: usize) void {
        if (self.backtrace_frames.len == 0) return;
        const idx = self.backtrace_frames.len - 1;
        self.backtrace_frames[idx].pc_source = null;
        self.backtrace_frames[idx].pc = pc;
    }

    pub fn borrowBacktracePc(self: *JSContext, pc_source: *const usize) void {
        if (self.backtrace_frames.len == 0) return;
        self.backtrace_frames[self.backtrace_frames.len - 1].pc_source = pc_source;
    }

    pub fn updateBacktraceLocation(self: *JSContext, pc: usize, line_num: i32, col_num: i32) void {
        if (self.backtrace_frames.len == 0) return;
        const idx = self.backtrace_frames.len - 1;
        self.backtrace_frames[idx].pc_source = null;
        self.backtrace_frames[idx].pc = pc;
        self.backtrace_frames[idx].line_num = line_num;
        self.backtrace_frames[idx].col_num = col_num;
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
