const std = @import("std");

const atom = @import("atom.zig");
const bytecode = @import("../bytecode/root.zig");
const class = @import("class.zig");
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
    /// contexts enable it; validation and embedding-style contexts keep it off.
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

    pub fn runtimePtr(self: *JSContext) *JSRuntime {
        return self.runtime;
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
            self.class_prototypes = next;
            if (old.len != 0) self.runtime.memory.free(JSValue, old);
        }
        return &self.class_prototypes[index];
    }

    pub fn setClassPrototype(self: *JSContext, class_id: class.ClassId, prototype: *Object) !void {
        const slot = try self.ensureClassPrototypeSlot(class_id);
        const old = slot.*;
        slot.* = prototype.value().dup();
        old.free(self.runtime);
    }

    pub fn classPrototypeObject(self: *JSContext, class_id: class.ClassId) ?*Object {
        const index: usize = @intCast(class_id);
        if (index >= self.class_prototypes.len) return null;
        const value = self.class_prototypes[index];
        if (!value.isObject()) return null;
        const header = value.refHeader() orelse return null;
        if (header.kind != .object) return null;
        return @fieldParentPtr("header", header);
    }

    pub fn deinit(self: *JSContext) void {
        const rt = self.runtime;
        rt.unregisterRootProvider(self.rootProvider());
        self.host_event_loop = null;
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
        if (self.host_event_loop) |host_event_loop| {
            try host_event_loop.traceRoots(visitor);
        }
    }

    pub fn globalObject(self: *JSContext) !*Object {
        return exec.zjs_vm.contextGlobal(self);
    }

    pub fn toString(self: *JSContext, value: JSValue) !JSValue {
        const global = try self.globalObject();
        return exec.shared.toStringForAnnexB(self, null, global, value, null, null);
    }

    pub fn arrayBuffer(self: *JSContext, store: *JSValue.Bytes.Store) !JSValue {
        return store.toArrayBuffer(self);
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

    pub fn runJobs(self: *JSContext, output: ?*std.Io.Writer) !void {
        self.runtime.job_queue.runAll();
        const global_object = try self.globalObject();
        exec.zjs_vm.drainPendingPromiseJobs(self, output, global_object) catch |err| {
            if (self.hasException() or self.hasUnhandledRejection()) return;
            return err;
        };
    }

    pub fn takePendingException(self: *JSContext) JSValue {
        if (self.hasUnhandledRejection()) {
            const rejection = self.takeUnhandledRejection();
            if (self.hasException()) self.clearException();
            return rejection;
        }
        return self.takeException();
    }

    pub fn defineGlobalFunction(
        self: *JSContext,
        name: []const u8,
        length: i32,
        ptr: *anyopaque,
        call: @import("host_function.zig").ExternalCallFn,
        finalizer: ?@import("host_function.zig").ExternalFinalizer,
    ) !void {
        const rt = self.runtime;
        const global_object = try self.globalObject();

        const id = try rt.registerExternalHostFunction(.{
            .ptr = ptr,
            .call = call,
            .finalizer = finalizer,
        });

        const function_value = try @import("../builtins/function.zig").nativeFunction(rt, name, length);
        errdefer function_value.free(rt);

        const function_object = try exec.property_ops.expectObject(function_value);
        function_object.hostFunctionKindSlot().* = @import("host_function.zig").ids.external_host;
        function_object.externalHostFunctionIdSlot().* = id;
        try function_object.setFunctionRealmGlobalPtr(rt, global_object);

        const property_name = try rt.internAtom(name);
        defer rt.atoms.free(property_name);
        try global_object.defineOwnProperty(rt, property_name, @import("descriptor.zig").Descriptor.data(function_value, true, false, true));
    }

    pub fn formatException(self: *JSContext, exc: JSValue, allocator: std.mem.Allocator) ![]const u8 {
        const rt = self.runtime;
        if (exc.isObject()) {
            const header = exc.refHeader() orelse return error.InvalidEngineState;
            const object: *Object = @fieldParentPtr("header", header);

            const name_opt = try getPropertyString(rt, object, "name", allocator);
            errdefer if (name_opt) |n| allocator.free(n);
            const msg_opt = try getPropertyString(rt, object, "message", allocator);
            errdefer if (msg_opt) |m| allocator.free(m);

            if (name_opt) |name| {
                if (msg_opt) |msg| {
                    defer allocator.free(name);
                    defer allocator.free(msg);
                    return try std.fmt.allocPrint(allocator, "{s}: {s}", .{ name, msg });
                }
                return name;
            } else if (msg_opt) |msg| {
                return msg;
            }
        }

        var temp_list = std.ArrayList(u8).empty;
        defer temp_list.deinit(rt.memory.allocator);
        try exec.value_ops.appendValueString(rt, &temp_list, exc);
        return try allocator.dupe(u8, temp_list.items);
    }

    pub fn formatExceptionStack(self: *JSContext, exc: JSValue, allocator: std.mem.Allocator) !?[]const u8 {
        const rt = self.runtime;
        if (!exc.isObject()) return null;
        const header = exc.refHeader() orelse return null;
        const object: *Object = @fieldParentPtr("header", header);
        return try getPropertyString(rt, object, "stack", allocator);
    }
};

fn getPropertyString(rt: *JSRuntime, obj: *Object, name: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const val = obj.getProperty(key);
    defer val.free(rt);
    if (!val.isString()) return null;

    var temp_list = std.ArrayList(u8).empty;
    defer temp_list.deinit(rt.memory.allocator);
    try exec.value_ops.appendRawString(rt, &temp_list, val);
    return try allocator.dupe(u8, temp_list.items);
}

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
