const std = @import("std");

const atom = @import("atom.zig");
const Object = @import("object.zig").Object;
const exception = @import("exception.zig");
const runtime_mod = @import("runtime.zig");
const Runtime = runtime_mod.Runtime;
const Value = @import("value.zig").Value;

pub const BacktraceFrame = struct {
    function_name: atom.Atom,
    filename: atom.Atom,
    line_num: i32,
    col_num: i32,
    pc: usize = 0,
    pc_source: ?*const usize = null,
    location_data: ?*const anyopaque = null,
    location_resolver: ?BacktraceLocationResolver = null,

    pub fn location(self: BacktraceFrame) BacktraceLocation {
        const current_pc = if (self.pc_source) |pc_source| pc_source.* -| 1 else self.pc;
        if (self.location_resolver) |resolver| return resolver(self.location_data, current_pc);
        return .{ .line_num = self.line_num, .col_num = self.col_num };
    }
};

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
    NotSimpleNumericCall,
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
    SymLinkLoop,
    SyntaxError,
    SystemError,
    SystemFdQuotaExceeded,
    SystemResources,
    Test262Error,
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
    ctx: *Context,
    output: ?*std.Io.Writer,
    global: *Object,
    referrer_path: []const u8,
    specifier: []const u8,
) DynamicImportError!Value;

pub const OsTimer = struct {
    id: i64,
    callback: Value,
    timeout_ms: u64,
    delay_ms: u64,
    repeats: bool,
    callback_symbol_rooted: bool = false,

    pub fn init(ctx: *Context, id: i64, callback: Value, timeout_ms: u64, delay_ms: u64, repeats: bool) !OsTimer {
        var timer = OsTimer{
            .id = id,
            .callback = callback.dup(),
            .timeout_ms = timeout_ms,
            .delay_ms = delay_ms,
            .repeats = repeats,
        };
        errdefer timer.callback.free(ctx.runtime);
        timer.callback_symbol_rooted = try ctx.runtime.registerExternalValueSymbolRoot(callback);
        return timer;
    }

    pub fn deinit(self: OsTimer, rt: *Runtime) void {
        if (self.callback_symbol_rooted) rt.unregisterExternalValueSymbolRoot(self.callback);
        self.callback.free(rt);
    }
};

pub const OsRwHandler = struct {
    fd: i32,
    read_callback: Value = Value.nullValue(),
    write_callback: Value = Value.nullValue(),
    symbol_root_mask: u2 = 0,

    pub fn deinit(self: OsRwHandler, rt: *Runtime) void {
        if ((self.symbol_root_mask & 0b01) != 0) rt.unregisterExternalValueSymbolRoot(self.read_callback);
        if ((self.symbol_root_mask & 0b10) != 0) rt.unregisterExternalValueSymbolRoot(self.write_callback);
        self.read_callback.free(rt);
        self.write_callback.free(rt);
    }

    pub fn setCallback(self: *OsRwHandler, rt: *Runtime, write_handler: bool, callback: Value) !void {
        const next_callback = callback.dup();
        var next_rooted = false;
        errdefer next_callback.free(rt);
        next_rooted = try rt.registerExternalValueSymbolRoot(callback);
        errdefer if (next_rooted) rt.unregisterExternalValueSymbolRoot(next_callback);

        const bit: u2 = if (write_handler) 0b10 else 0b01;
        const slot = if (write_handler) &self.write_callback else &self.read_callback;
        const old_callback = slot.*;
        const old_rooted = (self.symbol_root_mask & bit) != 0;
        slot.* = next_callback;
        if (next_rooted) {
            self.symbol_root_mask |= bit;
        } else {
            self.symbol_root_mask &= ~bit;
        }
        if (old_rooted) rt.unregisterExternalValueSymbolRoot(old_callback);
        old_callback.free(rt);
    }

    pub fn clearCallback(self: *OsRwHandler, rt: *Runtime, write_handler: bool) void {
        const bit: u2 = if (write_handler) 0b10 else 0b01;
        const slot = if (write_handler) &self.write_callback else &self.read_callback;
        const old_callback = slot.*;
        const old_rooted = (self.symbol_root_mask & bit) != 0;
        slot.* = Value.nullValue();
        self.symbol_root_mask &= ~bit;
        if (old_rooted) rt.unregisterExternalValueSymbolRoot(old_callback);
        old_callback.free(rt);
    }
};

pub const OsSignalHandler = struct {
    sig: u32,
    callback: Value,
    callback_symbol_rooted: bool = false,

    pub fn deinit(self: OsSignalHandler, rt: *Runtime) void {
        if (self.callback_symbol_rooted) rt.unregisterExternalValueSymbolRoot(self.callback);
        self.callback.free(rt);
    }

    pub fn init(ctx: *Context, sig: u32, callback: Value) !OsSignalHandler {
        var handler = OsSignalHandler{
            .sig = sig,
            .callback = callback.dup(),
        };
        errdefer handler.callback.free(ctx.runtime);
        handler.callback_symbol_rooted = try ctx.runtime.registerExternalValueSymbolRoot(callback);
        return handler;
    }

    pub fn setCallback(self: *OsSignalHandler, rt: *Runtime, callback: Value) !void {
        const next_callback = callback.dup();
        var next_rooted = false;
        errdefer next_callback.free(rt);
        next_rooted = try rt.registerExternalValueSymbolRoot(callback);
        errdefer if (next_rooted) rt.unregisterExternalValueSymbolRoot(next_callback);

        const old_callback = self.callback;
        const old_rooted = self.callback_symbol_rooted;
        self.callback = next_callback;
        self.callback_symbol_rooted = next_rooted;
        if (old_rooted) rt.unregisterExternalValueSymbolRoot(old_callback);
        old_callback.free(rt);
    }
};

pub const PendingPromiseJob = struct {
    sequence: u64 = 0,
    value: Value = Value.undefinedValue(),
    value_symbol_rooted: bool = false,

    pub fn init(ctx: *Context, sequence: u64, value: Value) !PendingPromiseJob {
        var job = PendingPromiseJob{
            .sequence = sequence,
            .value = value.dup(),
        };
        errdefer job.value.free(ctx.runtime);
        job.value_symbol_rooted = try ctx.runtime.registerExternalValueSymbolRoot(value);
        return job;
    }

    pub fn deinit(self: PendingPromiseJob, rt: *Runtime) void {
        if (self.value_symbol_rooted) rt.unregisterExternalValueSymbolRoot(self.value);
        self.value.free(rt);
    }
};

pub const Context = struct {
    runtime: *Runtime,
    exception_slot: exception.ExceptionSlot = .{},
    unhandled_rejection_slot: exception.ExceptionSlot = .{},
    unhandled_rejection_promise_slot: exception.ExceptionSlot = .{},
    gc_root_values: [4]runtime_mod.ValueRootValue = undefined,
    gc_root_slices: [1]runtime_mod.ValueRootSlice = undefined,
    gc_root_frame: runtime_mod.ValueRootFrame = .{},
    stack_limit: usize = 0,
    call_depth: usize = 0,
    preserve_uncaught_exception: bool = false,
    /// Host-controlled QuickJS-style unhandled rejection tracking. Normal CLI
    /// contexts enable it; test262 and embedding-style contexts keep it off.
    track_unhandled_rejections: bool = false,
    formatting_error_stack: bool = false,
    backtrace_frames: []BacktraceFrame = &.{},
    backtrace_capacity: usize = 0,
    class_prototypes: []Value = &.{},
    /// Cached global object, populated lazily by the eval entry path.
    /// Sharing the global across `eval` calls matches QuickJS semantics
    /// (`JS_Eval` reuses the per-context globals) and skips the ~300ms
    /// per-eval rebuild of every standard constructor / prototype /
    /// host helper. Owned by the context: freed in `destroy`.
    cached_global: ?*Object = null,
    /// Original global `eval` object for QuickJS-style OP_eval dispatch.
    /// Direct-eval syntax only evaluates as direct eval when the resolved
    /// callee is this object; otherwise OP_eval falls back to an ordinary call.
    intrinsic_eval: Value = Value.nullValue(),
    dynamic_import_callback: ?DynamicImportCallback = null,
    dynamic_import_userdata: ?*anyopaque = null,
    pending_promise_jobs: []PendingPromiseJob = &.{},
    pending_promise_jobs_capacity: usize = 0,
    os_timers: []OsTimer = &.{},
    os_timers_capacity: usize = 0,
    os_rw_handlers: []OsRwHandler = &.{},
    os_rw_handlers_capacity: usize = 0,
    os_signal_handlers: []OsSignalHandler = &.{},
    os_signal_handlers_capacity: usize = 0,
    next_os_timer_id: i64 = 1,
    exit_code: ?u8 = null,

    /// Returns an owned context. Caller must release it with `destroy`.
    pub fn create(rt: *Runtime) !*Context {
        const ctx = try rt.memory.create(Context);
        errdefer rt.memory.destroy(Context, ctx);
        const prototypes = try rt.memory.alloc(Value, rt.classes.records.len);
        errdefer rt.memory.free(Value, prototypes);
        ctx.* = .{
            .runtime = rt,
            .stack_limit = rt.stackSize(),
            .class_prototypes = prototypes,
        };
        @memset(ctx.class_prototypes, Value.nullValue());
        ctx.initGCRootFrame();
        try rt.registerContextValueRoots(&ctx.gc_root_frame);
        return ctx;
    }

    pub fn destroy(self: *Context) void {
        const rt = self.runtime;
        self.exception_slot.clear(rt);
        self.unhandled_rejection_slot.clear(rt);
        self.unhandled_rejection_promise_slot.clear(rt);
        const old_intrinsic_eval = self.intrinsic_eval;
        self.intrinsic_eval = Value.nullValue();
        const old_cached_global = self.cached_global;
        self.cached_global = null;
        old_intrinsic_eval.free(rt);
        if (old_cached_global) |global| global.value().free(rt);
        const pending_promise_jobs = self.pending_promise_jobs;
        const pending_promise_jobs_capacity = self.pending_promise_jobs_capacity;
        self.pending_promise_jobs = &.{};
        self.pending_promise_jobs_capacity = 0;
        for (pending_promise_jobs) |job| job.deinit(rt);
        if (pending_promise_jobs_capacity != 0) rt.memory.free(PendingPromiseJob, pending_promise_jobs.ptr[0..pending_promise_jobs_capacity]);
        const os_timers = self.os_timers;
        const os_timers_capacity = self.os_timers_capacity;
        self.os_timers = &.{};
        self.os_timers_capacity = 0;
        for (os_timers) |timer| timer.deinit(rt);
        if (os_timers_capacity != 0) rt.memory.free(OsTimer, os_timers.ptr[0..os_timers_capacity]);
        const os_rw_handlers = self.os_rw_handlers;
        const os_rw_handlers_capacity = self.os_rw_handlers_capacity;
        self.os_rw_handlers = &.{};
        self.os_rw_handlers_capacity = 0;
        for (os_rw_handlers) |handler| handler.deinit(rt);
        if (os_rw_handlers_capacity != 0) rt.memory.free(OsRwHandler, os_rw_handlers.ptr[0..os_rw_handlers_capacity]);
        const os_signal_handlers = self.os_signal_handlers;
        const os_signal_handlers_capacity = self.os_signal_handlers_capacity;
        self.os_signal_handlers = &.{};
        self.os_signal_handlers_capacity = 0;
        for (os_signal_handlers) |handler| handler.deinit(rt);
        if (os_signal_handlers_capacity != 0) rt.memory.free(OsSignalHandler, os_signal_handlers.ptr[0..os_signal_handlers_capacity]);
        const backtrace_frames = self.backtrace_frames;
        const backtrace_capacity = self.backtrace_capacity;
        self.backtrace_frames = &.{};
        self.backtrace_capacity = 0;
        for (backtrace_frames) |frame| {
            rt.atoms.free(frame.function_name);
            rt.atoms.free(frame.filename);
        }
        if (backtrace_capacity != 0) rt.memory.free(BacktraceFrame, backtrace_frames.ptr[0..backtrace_capacity]);
        const class_prototypes = self.class_prototypes;
        self.class_prototypes = &.{};
        for (class_prototypes) |*slot| {
            const value = slot.*;
            slot.* = Value.nullValue();
            value.free(rt);
        }
        if (class_prototypes.len != 0) rt.memory.free(Value, class_prototypes);
        rt.unregisterContextValueRoots(&self.gc_root_frame);
        rt.memory.destroy(Context, self);
    }

    fn initGCRootFrame(self: *Context) void {
        self.gc_root_values = .{
            .{ .value = &self.exception_slot.value },
            .{ .value = &self.unhandled_rejection_slot.value },
            .{ .value = &self.unhandled_rejection_promise_slot.value },
            .{ .value = &self.intrinsic_eval },
        };
        self.gc_root_slices = .{
            .{ .mutable = &self.class_prototypes },
        };
        self.gc_root_frame = .{
            .slices = &self.gc_root_slices,
            .values = &self.gc_root_values,
        };
    }

    pub fn ensurePendingPromiseJobCapacity(self: *Context, min_capacity: usize) !void {
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

    pub fn peekPendingPromiseJobSequence(self: Context) ?u64 {
        if (self.pending_promise_jobs.len == 0) return null;
        return self.pending_promise_jobs[0].sequence;
    }

    pub fn takePendingPromiseJob(self: *Context) ?PendingPromiseJob {
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

    pub fn ensureOsTimerCapacity(self: *Context, min_capacity: usize) !void {
        if (self.os_timers_capacity >= min_capacity) return;
        var next_capacity = if (self.os_timers_capacity == 0) @as(usize, 2) else self.os_timers_capacity * 2;
        while (next_capacity < min_capacity) : (next_capacity *= 2) {}
        const next = try self.runtime.memory.alloc(OsTimer, next_capacity);
        errdefer self.runtime.memory.free(OsTimer, next);
        const old_timers = self.os_timers;
        const old_capacity = self.os_timers_capacity;
        @memcpy(next[0..old_timers.len], old_timers);
        self.os_timers = next[0..old_timers.len];
        self.os_timers_capacity = next_capacity;
        if (old_capacity != 0) {
            self.runtime.memory.free(OsTimer, old_timers.ptr[0..old_capacity]);
        }
    }

    pub fn removeOsTimerAt(self: *Context, index: usize) void {
        std.debug.assert(index < self.os_timers.len);
        const old_len = self.os_timers.len;
        const removed = self.os_timers[index];
        if (index + 1 < old_len) {
            @memmove(self.os_timers[index .. old_len - 1], self.os_timers[index + 1 .. old_len]);
        }
        self.os_timers = self.os_timers.ptr[0 .. old_len - 1];
        if (self.os_timers.len == 0 and self.os_timers_capacity != 0) {
            const old_timers = self.os_timers.ptr[0..self.os_timers_capacity];
            self.os_timers = &.{};
            self.os_timers_capacity = 0;
            self.runtime.memory.free(OsTimer, old_timers);
        }
        removed.deinit(self.runtime);
    }

    pub fn ensureOsRwHandlerCapacity(self: *Context, min_capacity: usize) !void {
        if (self.os_rw_handlers_capacity >= min_capacity) return;
        var next_capacity = if (self.os_rw_handlers_capacity == 0) @as(usize, 2) else self.os_rw_handlers_capacity * 2;
        while (next_capacity < min_capacity) : (next_capacity *= 2) {}
        const next = try self.runtime.memory.alloc(OsRwHandler, next_capacity);
        errdefer self.runtime.memory.free(OsRwHandler, next);
        const old_handlers = self.os_rw_handlers;
        const old_capacity = self.os_rw_handlers_capacity;
        @memcpy(next[0..old_handlers.len], old_handlers);
        self.os_rw_handlers = next[0..old_handlers.len];
        self.os_rw_handlers_capacity = next_capacity;
        if (old_capacity != 0) {
            self.runtime.memory.free(OsRwHandler, old_handlers.ptr[0..old_capacity]);
        }
    }

    pub fn removeOsRwHandlerAt(self: *Context, index: usize) void {
        std.debug.assert(index < self.os_rw_handlers.len);
        const old_len = self.os_rw_handlers.len;
        const removed = self.os_rw_handlers[index];
        if (index + 1 < old_len) {
            @memmove(self.os_rw_handlers[index .. old_len - 1], self.os_rw_handlers[index + 1 .. old_len]);
        }
        self.os_rw_handlers = self.os_rw_handlers.ptr[0 .. old_len - 1];
        if (self.os_rw_handlers.len == 0 and self.os_rw_handlers_capacity != 0) {
            const old_handlers = self.os_rw_handlers.ptr[0..self.os_rw_handlers_capacity];
            self.os_rw_handlers = &.{};
            self.os_rw_handlers_capacity = 0;
            self.runtime.memory.free(OsRwHandler, old_handlers);
        }
        removed.deinit(self.runtime);
    }

    pub fn ensureOsSignalHandlerCapacity(self: *Context, min_capacity: usize) !void {
        if (self.os_signal_handlers_capacity >= min_capacity) return;
        var next_capacity = if (self.os_signal_handlers_capacity == 0) @as(usize, 2) else self.os_signal_handlers_capacity * 2;
        while (next_capacity < min_capacity) : (next_capacity *= 2) {}
        const next = try self.runtime.memory.alloc(OsSignalHandler, next_capacity);
        errdefer self.runtime.memory.free(OsSignalHandler, next);
        const old_handlers = self.os_signal_handlers;
        const old_capacity = self.os_signal_handlers_capacity;
        @memcpy(next[0..old_handlers.len], old_handlers);
        self.os_signal_handlers = next[0..old_handlers.len];
        self.os_signal_handlers_capacity = next_capacity;
        if (old_capacity != 0) {
            self.runtime.memory.free(OsSignalHandler, old_handlers.ptr[0..old_capacity]);
        }
    }

    pub fn removeOsSignalHandlerAt(self: *Context, index: usize) void {
        std.debug.assert(index < self.os_signal_handlers.len);
        const old_len = self.os_signal_handlers.len;
        const removed = self.os_signal_handlers[index];
        if (index + 1 < old_len) {
            @memmove(self.os_signal_handlers[index .. old_len - 1], self.os_signal_handlers[index + 1 .. old_len]);
        }
        self.os_signal_handlers = self.os_signal_handlers.ptr[0 .. old_len - 1];
        if (self.os_signal_handlers.len == 0 and self.os_signal_handlers_capacity != 0) {
            const old_handlers = self.os_signal_handlers.ptr[0..self.os_signal_handlers_capacity];
            self.os_signal_handlers = &.{};
            self.os_signal_handlers_capacity = 0;
            self.runtime.memory.free(OsSignalHandler, old_handlers);
        }
        removed.deinit(self.runtime);
    }

    pub fn throwValue(self: *Context, value: Value) Value {
        self.exception_slot.set(self.runtime, value);
        return Value.exception();
    }

    pub fn hasException(self: Context) bool {
        return self.exception_slot.hasException();
    }

    pub fn takeException(self: *Context) Value {
        return self.exception_slot.take();
    }

    pub fn clearException(self: *Context) void {
        self.exception_slot.clear(self.runtime);
    }

    pub fn recordUnhandledRejection(self: *Context, value: Value) void {
        self.recordUnhandledPromiseRejection(null, value);
    }

    pub fn recordUnhandledPromiseRejection(self: *Context, promise: ?Value, value: Value) void {
        self.unhandled_rejection_slot.set(self.runtime, value.dup());
        if (promise) |promise_value| {
            self.unhandled_rejection_promise_slot.set(self.runtime, promise_value.dup());
        } else {
            self.unhandled_rejection_promise_slot.clear(self.runtime);
        }
        if (!self.exception_slot.hasException()) {
            self.exception_slot.set(self.runtime, value.dup());
        }
    }

    pub fn hasUnhandledRejection(self: Context) bool {
        return self.unhandled_rejection_slot.hasException();
    }

    pub fn takeUnhandledRejection(self: *Context) Value {
        self.unhandled_rejection_promise_slot.clear(self.runtime);
        return self.unhandled_rejection_slot.take();
    }

    pub fn clearUnhandledRejection(self: *Context) void {
        self.unhandled_rejection_slot.clear(self.runtime);
        self.unhandled_rejection_promise_slot.clear(self.runtime);
    }

    pub fn classPrototypeSlotCount(self: Context) usize {
        return self.class_prototypes.len;
    }

    pub fn pushBacktraceFrame(
        self: *Context,
        function_name: atom.Atom,
        filename: atom.Atom,
        line_num: i32,
        col_num: i32,
    ) !void {
        try self.pushBacktraceFrameWithResolver(function_name, filename, line_num, col_num, null, null);
    }

    pub fn pushBacktraceFrameWithResolver(
        self: *Context,
        function_name: atom.Atom,
        filename: atom.Atom,
        line_num: i32,
        col_num: i32,
        location_data: ?*const anyopaque,
        location_resolver: ?BacktraceLocationResolver,
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
        self.backtrace_frames.ptr[self.backtrace_frames.len] = .{
            .function_name = self.runtime.atoms.dup(function_name),
            .filename = self.runtime.atoms.dup(filename),
            .line_num = line_num,
            .col_num = col_num,
            .location_data = location_data,
            .location_resolver = location_resolver,
        };
        self.backtrace_frames = self.backtrace_frames.ptr[0 .. self.backtrace_frames.len + 1];
    }

    pub fn popBacktraceFrame(self: *Context) void {
        if (self.backtrace_frames.len == 0) return;
        const idx = self.backtrace_frames.len - 1;
        const entry = self.backtrace_frames[idx];
        self.backtrace_frames = self.backtrace_frames.ptr[0..idx];
        self.runtime.atoms.free(entry.function_name);
        self.runtime.atoms.free(entry.filename);
    }

    pub fn updateBacktracePc(self: *Context, pc: usize) void {
        if (self.backtrace_frames.len == 0) return;
        const idx = self.backtrace_frames.len - 1;
        self.backtrace_frames[idx].pc_source = null;
        self.backtrace_frames[idx].pc = pc;
    }

    pub fn borrowBacktracePc(self: *Context, pc_source: *const usize) void {
        if (self.backtrace_frames.len == 0) return;
        self.backtrace_frames[self.backtrace_frames.len - 1].pc_source = pc_source;
    }

    pub fn updateBacktraceLocation(self: *Context, pc: usize, line_num: i32, col_num: i32) void {
        if (self.backtrace_frames.len == 0) return;
        const idx = self.backtrace_frames.len - 1;
        self.backtrace_frames[idx].pc_source = null;
        self.backtrace_frames[idx].pc = pc;
        self.backtrace_frames[idx].line_num = line_num;
        self.backtrace_frames[idx].col_num = col_num;
    }
};
