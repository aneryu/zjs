const std = @import("std");

const atom = @import("atom.zig");
const bytecode = @import("../bytecode/root.zig");
const exec = @import("../exec/root.zig");
const parser = @import("../frontend/parser.zig");
const Object = @import("object.zig").Object;
const exception = @import("exception.zig");
const runtime_mod = @import("runtime.zig");
const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;

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

pub const ContextEvalOptions = struct {
    mode: parser.Mode = .script,
    filename: []const u8 = "<eval>",
    source_kind: parser.SourceKind = .auto,
    output: ?*std.Io.Writer = null,
    parse_strict: bool = false,
    runtime_strict: bool = false,
    return_completion: bool = true,
    discard_script_result: bool = false,
    timing: ?*ContextEvalTiming = null,
};

pub const EvalOptions = ContextEvalOptions;

pub const OsTimer = struct {
    id: i64,
    callback: JSValue,
    timeout_ms: u64,
    delay_ms: u64,
    repeats: bool,
    callback_symbol_rooted: bool = false,

    pub fn init(ctx: *JSContext, id: i64, callback: JSValue, timeout_ms: u64, delay_ms: u64, repeats: bool) !OsTimer {
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

    pub fn deinit(self: OsTimer, rt: *JSRuntime) void {
        if (self.callback_symbol_rooted) rt.unregisterExternalValueSymbolRoot(self.callback);
        self.callback.free(rt);
    }

    pub fn traceRoots(self: *OsTimer, visitor: *runtime_mod.RootVisitor) runtime_mod.RootTraceError!void {
        try visitor.value(&self.callback);
    }
};

pub const OsRwHandler = struct {
    fd: i32,
    read_callback: JSValue = JSValue.nullValue(),
    write_callback: JSValue = JSValue.nullValue(),
    symbol_root_mask: u2 = 0,

    pub fn deinit(self: OsRwHandler, rt: *JSRuntime) void {
        if ((self.symbol_root_mask & 0b01) != 0) rt.unregisterExternalValueSymbolRoot(self.read_callback);
        if ((self.symbol_root_mask & 0b10) != 0) rt.unregisterExternalValueSymbolRoot(self.write_callback);
        self.read_callback.free(rt);
        self.write_callback.free(rt);
    }

    pub fn setCallback(self: *OsRwHandler, rt: *JSRuntime, write_handler: bool, callback: JSValue) !void {
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

    pub fn clearCallback(self: *OsRwHandler, rt: *JSRuntime, write_handler: bool) void {
        const bit: u2 = if (write_handler) 0b10 else 0b01;
        const slot = if (write_handler) &self.write_callback else &self.read_callback;
        const old_callback = slot.*;
        const old_rooted = (self.symbol_root_mask & bit) != 0;
        slot.* = JSValue.nullValue();
        self.symbol_root_mask &= ~bit;
        if (old_rooted) rt.unregisterExternalValueSymbolRoot(old_callback);
        old_callback.free(rt);
    }

    pub fn traceRoots(self: *OsRwHandler, visitor: *runtime_mod.RootVisitor) runtime_mod.RootTraceError!void {
        try visitor.value(&self.read_callback);
        try visitor.value(&self.write_callback);
    }
};

pub const OsSignalHandler = struct {
    sig: u32,
    callback: JSValue,
    callback_symbol_rooted: bool = false,

    pub fn deinit(self: OsSignalHandler, rt: *JSRuntime) void {
        if (self.callback_symbol_rooted) rt.unregisterExternalValueSymbolRoot(self.callback);
        self.callback.free(rt);
    }

    pub fn init(ctx: *JSContext, sig: u32, callback: JSValue) !OsSignalHandler {
        var handler = OsSignalHandler{
            .sig = sig,
            .callback = callback.dup(),
        };
        errdefer handler.callback.free(ctx.runtime);
        handler.callback_symbol_rooted = try ctx.runtime.registerExternalValueSymbolRoot(callback);
        return handler;
    }

    pub fn setCallback(self: *OsSignalHandler, rt: *JSRuntime, callback: JSValue) !void {
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

    pub fn traceRoots(self: *OsSignalHandler, visitor: *runtime_mod.RootVisitor) runtime_mod.RootTraceError!void {
        try visitor.value(&self.callback);
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

pub const JSContext = struct {
    pub const Options = ContextOptions;
    pub const EvalOptions = ContextEvalOptions;
    pub const EvalTiming = ContextEvalTiming;

    runtime: *JSRuntime,
    exception_slot: exception.ExceptionSlot = .{},
    unhandled_rejection_slot: exception.ExceptionSlot = .{},
    unhandled_rejection_promise_slot: exception.ExceptionSlot = .{},
    stack_limit: usize = 0,
    call_depth: usize = 0,
    preserve_uncaught_exception: bool = false,
    /// Host-controlled QuickJS-style unhandled rejection tracking. Normal CLI
    /// contexts enable it; test262 and embedding-style contexts keep it off.
    track_unhandled_rejections: bool = false,
    formatting_error_stack: bool = false,
    backtrace_frames: []BacktraceFrame = &.{},
    backtrace_capacity: usize = 0,
    class_prototypes: []JSValue = &.{},
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
        const prototypes = try rt.memory.alloc(JSValue, rt.classes.records.len);
        errdefer rt.memory.free(JSValue, prototypes);
        self.* = .{
            .runtime = rt,
            .stack_limit = options.stack_size orelse rt.stackSize(),
            .track_unhandled_rejections = options.track_unhandled_rejections,
            .class_prototypes = prototypes,
            .dynamic_import_callback = options.dynamic_import_callback,
            .dynamic_import_userdata = options.dynamic_import_userdata,
        };
        @memset(self.class_prototypes, JSValue.nullValue());
        var provider_registered = false;
        errdefer {
            if (provider_registered) rt.unregisterRootProvider(self.rootProvider());
            rt.memory.free(JSValue, self.class_prototypes);
            self.class_prototypes = &.{};
        }
        try rt.registerRootProvider(self.rootProvider());
        provider_registered = true;
    }

    pub fn deinit(self: *JSContext) void {
        const rt = self.runtime;
        rt.unregisterRootProvider(self.rootProvider());
        self.exception_slot.clear(rt);
        self.unhandled_rejection_slot.clear(rt);
        self.unhandled_rejection_promise_slot.clear(rt);
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
            slot.* = JSValue.nullValue();
            value.free(rt);
        }
        if (class_prototypes.len != 0) rt.memory.free(JSValue, class_prototypes);
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
        try visitor.value(&self.unhandled_rejection_slot.value);
        try visitor.value(&self.unhandled_rejection_promise_slot.value);
        try visitor.value(&self.eval_function);
        try visitor.values(self.class_prototypes);
        try visitor.optionalObject(&self.global);
        try visitor.optionalObject(&self.lexicals);
        for (self.pending_promise_jobs) |*job| {
            try job.traceRoots(visitor);
        }
        for (self.os_timers) |*timer| {
            try timer.traceRoots(visitor);
        }
        for (self.os_rw_handlers) |*handler| {
            try handler.traceRoots(visitor);
        }
        for (self.os_signal_handlers) |*handler| {
            try handler.traceRoots(visitor);
        }
    }

    pub fn globalObject(self: *JSContext) !*Object {
        return exec.zjs_vm.contextGlobal(self);
    }

    pub fn eval(self: *JSContext, source_text: []const u8, options: ContextEvalOptions) !JSValue {
        const rt = self.runtime;
        const parse_start = monotonicNanos();
        var compiled = try parser.parse(rt, source_text, .{
            .mode = options.mode,
            .filename = options.filename,
            .source_kind = options.source_kind,
            .strict = options.parse_strict,
            .return_completion = options.mode == .script and options.return_completion,
        });
        if (options.timing) |timing| timing.parse_ns += elapsedNanosSince(parse_start);
        defer compiled.deinit();
        if (compiled.syntax_error) |err| {
            if (options.mode == .script and isWhitespaceSeparatedNumericScript(source_text)) return JSValue.undefinedValue();
            const exception_ops = @import("../exec/vm_exception_ops.zig");
            const global = try self.globalObject();
            var msg_buf = std.ArrayList(u8).empty;
            defer msg_buf.deinit(rt.memory.allocator);
            try msg_buf.print(rt.memory.allocator, "SYNTAX ERROR in {s}:{d}:{d} - {s}", .{ options.filename, err.position.line, err.position.column, err.message });
            const error_val = try exception_ops.createNamedError(rt, global, "SyntaxError", msg_buf.items);
            _ = self.throwValue(error_val);
            return error.SyntaxError;
        }
        if (options.runtime_strict and options.mode == .script) forceRuntimeStrict(&compiled.function);

        var module_name: atom.Atom = atom.null_atom;
        var has_module_record = false;
        defer if (has_module_record) rt.atoms.free(module_name);
        if (options.mode == .module and compiled.function.module_record != null) {
            var module_name_buf: [64]u8 = undefined;
            const module_name_bytes = if (std.mem.eql(u8, options.filename, "<eval>"))
                try std.fmt.bufPrint(&module_name_buf, "<eval>#{d}", .{rt.modules.modules.len})
            else
                options.filename;
            module_name = try rt.internAtom(module_name_bytes);
            has_module_record = true;
            const referrer_path: ?[]const u8 = if (std.mem.eql(u8, options.filename, "<eval>")) null else options.filename;
            _ = try exec.module.instantiateParsedRecordWithReferrer(rt, module_name, &compiled.function, referrer_path);
            if (rt.modules.find(module_name)) |record| record.import_meta_main = true;
            rt.modules.linkModule(rt, module_name) catch |err| {
                const exception_ops = @import("../exec/vm_exception_ops.zig");
                const global = try self.globalObject();
                var msg_buf = std.ArrayList(u8).empty;
                defer msg_buf.deinit(rt.memory.allocator);
                try msg_buf.print(rt.memory.allocator, "LINK ERROR for module {s}: {s}", .{ options.filename, @errorName(err) });
                const error_val = try exception_ops.createNamedError(rt, global, "SyntaxError", msg_buf.items);
                _ = self.throwValue(error_val);
                return moduleResolutionError(err);
            };
            try self.initializeNativeSyntheticModules();
        }

        var module_var_refs: []JSValue = &.{};
        if (has_module_record) {
            module_var_refs = try exec.module.buildModuleVarRefs(self, module_name, &compiled.function);
        }
        defer exec.module.freeModuleVarRefs(rt, module_var_refs);

        const result = if (has_module_record)
            try self.runEvalModuleWithVarRefs(&compiled.function, options.output, module_var_refs, options.timing)
        else blk: {
            const vm_start = monotonicNanos();
            const value = if (options.output) |writer| blk_output: {
                var vm_instance = exec.Vm.initWithOutput(self, writer);
                defer vm_instance.deinit();
                break :blk_output try vm_instance.run(&compiled.function);
            } else blk_no_output: {
                var vm_instance = exec.Vm.init(self);
                defer vm_instance.deinit();
                break :blk_no_output try vm_instance.run(&compiled.function);
            };
            if (options.timing) |timing| timing.vm_run_ns += elapsedNanosSince(vm_start);
            break :blk value;
        };

        const global_object = try exec.zjs_vm.contextGlobal(self);
        const jobs_start = monotonicNanos();
        try exec.zjs_vm.drainPendingPromiseJobs(self, options.output, global_object);
        if (options.timing) |timing| timing.promise_jobs_ns += elapsedNanosSince(jobs_start);

        if (options.mode == .script and options.discard_script_result) {
            result.free(rt);
            return JSValue.undefinedValue();
        }
        return result;
    }

    fn initializeNativeSyntheticModules(self: *JSContext) !void {
        const global_object = try exec.zjs_vm.contextGlobal(self);
        for (self.runtime.modules.modules) |record| {
            if (record.synthetic_kind != .native_std and record.synthetic_kind != .native_os) continue;
            _ = try exec.module.initializeSyntheticFileModule(self, global_object, record.module_name, "");
        }
    }

    fn runEvalModuleWithVarRefs(
        self: *JSContext,
        function: *const bytecode.Bytecode,
        output: ?*std.Io.Writer,
        module_var_refs: []const JSValue,
        timing: ?*ContextEvalTiming,
    ) !JSValue {
        const rt = self.runtime;
        var continuation_value = (try Object.create(rt, @import("class.zig").ids.generator, null)).value();
        defer continuation_value.free(rt);
        const continuation = try exec.property_ops.expectObject(continuation_value);
        var resume_value: ?JSValue = null;
        var resume_value_symbol_rooted = false;
        defer if (resume_value) |value| {
            if (resume_value_symbol_rooted) rt.unregisterExternalValueSymbolRoot(value);
            value.free(rt);
        };

        while (true) {
            var stack = exec.stack.Stack.init(&rt.memory, self.stack_limit);
            defer stack.deinit(rt);
            const vm_start = monotonicNanos();
            const result = exec.zjs_vm.runModuleWithOutputAndVarRefsState(
                self,
                &stack,
                function,
                output,
                module_var_refs,
                continuation,
                resume_value,
            ) catch |err| return moduleResolutionError(err);
            if (timing) |item| item.vm_run_ns += elapsedNanosSince(vm_start);
            if (resume_value) |value| {
                if (resume_value_symbol_rooted) {
                    rt.unregisterExternalValueSymbolRoot(value);
                    resume_value_symbol_rooted = false;
                }
                value.free(rt);
                resume_value = null;
            }

            if (continuation.generatorJustYielded() and !continuation.generatorDone()) {
                resume_value = result;
                resume_value_symbol_rooted = try rt.registerExternalValueSymbolRoot(result);
                const global_object = try exec.zjs_vm.contextGlobal(self);
                const jobs_start = monotonicNanos();
                try exec.zjs_vm.drainPendingPromiseJobs(self, output, global_object);
                if (timing) |item| item.promise_jobs_ns += elapsedNanosSince(jobs_start);
                continue;
            }

            return result;
        }
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

    pub fn ensureOsTimerCapacity(self: *JSContext, min_capacity: usize) !void {
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

    pub fn removeOsTimerAt(self: *JSContext, index: usize) void {
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

    pub fn ensureOsRwHandlerCapacity(self: *JSContext, min_capacity: usize) !void {
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

    pub fn removeOsRwHandlerAt(self: *JSContext, index: usize) void {
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

    pub fn ensureOsSignalHandlerCapacity(self: *JSContext, min_capacity: usize) !void {
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

    pub fn removeOsSignalHandlerAt(self: *JSContext, index: usize) void {
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

    pub fn recordUnhandledPromiseRejection(self: *JSContext, promise: ?JSValue, value: JSValue) void {
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

    pub fn hasUnhandledRejection(self: JSContext) bool {
        return self.unhandled_rejection_slot.hasException();
    }

    pub fn takeUnhandledRejection(self: *JSContext) JSValue {
        self.unhandled_rejection_promise_slot.clear(self.runtime);
        return self.unhandled_rejection_slot.take();
    }

    pub fn clearUnhandledRejection(self: *JSContext) void {
        self.unhandled_rejection_slot.clear(self.runtime);
        self.unhandled_rejection_promise_slot.clear(self.runtime);
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

    pub fn popBacktraceFrame(self: *JSContext) void {
        if (self.backtrace_frames.len == 0) return;
        const idx = self.backtrace_frames.len - 1;
        const entry = self.backtrace_frames[idx];
        self.backtrace_frames = self.backtrace_frames.ptr[0..idx];
        self.runtime.atoms.free(entry.function_name);
        self.runtime.atoms.free(entry.filename);
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
};

fn moduleResolutionError(err: anytype) (@TypeOf(err) || error{SyntaxError}) {
    return switch (err) {
        error.MissingExport, error.AmbiguousExport => error.SyntaxError,
        else => err,
    };
}

fn forceRuntimeStrict(function: *bytecode.Bytecode) void {
    function.flags.runtime_strict = true;
    for (function.constants.values) |value| forceFunctionBytecodeRuntimeStrict(value);
}

fn forceFunctionBytecodeRuntimeStrict(value: JSValue) void {
    if (!value.isFunctionBytecode()) return;
    const header = value.objectHeader() orelse return;
    const function_bytecode: *bytecode.FunctionBytecode = @fieldParentPtr("header", header);
    function_bytecode.runtime_strict_mode = true;
    for (function_bytecode.cpool) |child| forceFunctionBytecodeRuntimeStrict(child);
}

fn isWhitespaceSeparatedNumericScript(source_text: []const u8) bool {
    var saw_digit = false;
    var saw_space_after_digit = false;
    for (source_text) |ch| {
        if (std.ascii.isDigit(ch)) {
            if (saw_space_after_digit) return true;
            saw_digit = true;
        } else if (std.ascii.isWhitespace(ch)) {
            if (saw_digit) saw_space_after_digit = true;
        } else {
            return false;
        }
    }
    return false;
}

fn elapsedNanosSince(start: u64) u64 {
    const end = monotonicNanos();
    return if (end > start) end - start else 0;
}

fn monotonicNanos() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
