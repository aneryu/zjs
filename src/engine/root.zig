pub const core = @import("core/root.zig");
pub const frontend = @import("frontend/root.zig");
pub const bytecode = @import("bytecode/root.zig");
pub const exec = @import("exec/root.zig");
pub const builtins = @import("builtins/root.zig");
pub const libs = @import("libs/root.zig");

pub const RuntimeError = exec.exceptions.RuntimeError;
pub const HostError = exec.exceptions.HostError;
pub const EngineError = RuntimeError;

test "include core object private lifecycle tests" {
    _ = @import("core/object.zig");
}

pub const Limits = struct {
    memory_bytes: ?usize = null,
    stack_bytes: ?usize = null,
    gc_threshold_bytes: ?usize = null,
};

pub const EngineOptions = struct {
    allocator: std.mem.Allocator,
    trace_writer: ?*std.Io.Writer = null,
    limits: Limits = .{},
};

pub const EvalOptions = struct {
    mode: frontend.parser.Mode = .script,
    filename: []const u8 = "<eval>",
    source_kind: frontend.parser.SourceKind = .auto,
    output: ?*std.Io.Writer = null,
    parse_strict: bool = false,
    runtime_strict: bool = false,
    timing: ?*EvalTiming = null,
};

pub const ValueHandle = struct {
    runtime: ?*core.Runtime,
    value: core.Value,

    pub fn init(runtime: *core.Runtime, value: core.Value) ValueHandle {
        return .{
            .runtime = runtime,
            .value = value,
        };
    }

    pub fn deinit(self: *ValueHandle) void {
        if (self.runtime) |runtime| {
            self.value.free(runtime);
            self.runtime = null;
            self.value = core.Value.undefinedValue();
        }
    }

    pub fn release(self: *ValueHandle) core.Value {
        const value = self.value;
        self.runtime = null;
        self.value = core.Value.undefinedValue();
        return value;
    }
};

pub const EvalResult = ValueHandle;
pub const ExternalHostCall = core.host_function.ExternalCall;
pub const ExternalHostCallFn = core.host_function.ExternalCallFn;
pub const ExternalHostFinalizer = core.host_function.ExternalFinalizer;

pub const ExceptionInfo = struct {
    value: ValueHandle,

    pub fn deinit(self: *ExceptionInfo) void {
        self.value.deinit();
    }
};

pub const EvalTiming = struct {
    parse_ns: u64 = 0,
    vm_run_ns: u64 = 0,
    promise_jobs_ns: u64 = 0,
};

pub const Engine = struct {
    runtime: *core.Runtime,
    context: *core.Context,
    job_queue: exec.jobs.Queue,
    output: ?*std.Io.Writer = null,

    pub fn init(allocator: std.mem.Allocator) !Engine {
        return initWithTrace(allocator, null);
    }

    pub fn initWithOptions(options: EngineOptions) !Engine {
        var engine = try initWithTrace(options.allocator, options.trace_writer);
        engine.setLimits(options.limits);
        return engine;
    }

    pub fn initWithTrace(allocator: std.mem.Allocator, trace_writer: ?*std.Io.Writer) !Engine {
        const rt = try core.Runtime.createWithTrace(allocator, trace_writer);
        errdefer rt.destroy();
        const ctx = try core.Context.create(rt);
        errdefer ctx.destroy();
        return .{
            .runtime = rt,
            .context = ctx,
            .job_queue = exec.jobs.Queue.init(&rt.memory),
            .output = null,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.job_queue.deinit();
        exec.qjs_vm.cleanupWorkersForRuntime(self.runtime);
        _ = exec.qjs_vm.cleanupTest262Agents();
        exec.qjs_vm.cleanupAtomicsWaitersForContext(self.context);
        self.context.destroy();
        self.runtime.destroy();
    }

    pub fn setLimits(self: *Engine, limits: Limits) void {
        self.runtime.setMemoryLimit(limits.memory_bytes);
        if (limits.stack_bytes) |stack_bytes| self.runtime.setStackSize(stack_bytes);
        if (limits.gc_threshold_bytes) |gc_threshold_bytes| self.runtime.setGCThreshold(gc_threshold_bytes);
    }

    pub fn eval(self: *Engine, source_text: []const u8) RuntimeError!core.Value {
        return self.evalMode(source_text, .script) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalHandle(self: *Engine, source_text: []const u8) RuntimeError!ValueHandle {
        return self.evalHandleWithOptions(source_text, .{});
    }

    pub fn evalModule(self: *Engine, source_text: []const u8) RuntimeError!core.Value {
        return self.evalMode(source_text, .module) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalModuleHandle(self: *Engine, source_text: []const u8) RuntimeError!ValueHandle {
        return self.evalHandleWithOptions(source_text, .{ .mode = .module });
    }

    pub fn evalMode(self: *Engine, source_text: []const u8, mode: frontend.parser.Mode) RuntimeError!core.Value {
        return self.evalModeWithOutput(source_text, null, mode) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalWithOptions(self: *Engine, source_text: []const u8, options: EvalOptions) RuntimeError!core.Value {
        return self.evalModeWithOutputNamedTimedOptions(
            source_text,
            options.output,
            options.mode,
            options.filename,
            options.source_kind,
            options.timing,
            options.parse_strict,
            options.runtime_strict,
        ) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalHandleWithOptions(self: *Engine, source_text: []const u8, options: EvalOptions) RuntimeError!ValueHandle {
        const value = try self.evalWithOptions(source_text, options);
        return ValueHandle.init(self.runtime, value);
    }

    pub fn evalWithOutput(self: *Engine, source_text: []const u8, output: *std.Io.Writer) RuntimeError!core.Value {
        return self.evalWithOutputMode(source_text, output, .script) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalWithOutputMode(
        self: *Engine,
        source_text: []const u8,
        output: *std.Io.Writer,
        mode: frontend.parser.Mode,
    ) RuntimeError!core.Value {
        return self.evalModeWithOutputNamed(source_text, output, mode, "<eval>") catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalFileWithOutputMode(
        self: *Engine,
        source_text: []const u8,
        output: *std.Io.Writer,
        mode: frontend.parser.Mode,
        filename: []const u8,
    ) RuntimeError!core.Value {
        return self.evalModeWithOutputNamed(source_text, output, mode, filename) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalFileWithOutputModeStrict(
        self: *Engine,
        source_text: []const u8,
        output: *std.Io.Writer,
        mode: frontend.parser.Mode,
        filename: []const u8,
        strict: bool,
    ) RuntimeError!core.Value {
        return self.evalModeWithOutputNamedTimedOptions(source_text, output, mode, filename, .auto, null, strict, strict) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalFileWithOutputModeRuntimeStrict(
        self: *Engine,
        source_text: []const u8,
        output: *std.Io.Writer,
        mode: frontend.parser.Mode,
        filename: []const u8,
        runtime_strict: bool,
    ) RuntimeError!core.Value {
        return self.evalModeWithOutputNamedTimedOptions(source_text, output, mode, filename, .auto, null, false, runtime_strict) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalFileWithOutputModeTimed(
        self: *Engine,
        source_text: []const u8,
        output: *std.Io.Writer,
        mode: frontend.parser.Mode,
        filename: []const u8,
        timing: *EvalTiming,
    ) RuntimeError!core.Value {
        return self.evalModeWithOutputNamedTimed(source_text, output, mode, filename, timing) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalFileWithOutputModeTimedStrict(
        self: *Engine,
        source_text: []const u8,
        output: *std.Io.Writer,
        mode: frontend.parser.Mode,
        filename: []const u8,
        timing: *EvalTiming,
        strict: bool,
    ) RuntimeError!core.Value {
        return self.evalModeWithOutputNamedTimedOptions(source_text, output, mode, filename, .auto, timing, strict, strict) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub fn evalFileWithOutputModeTimedRuntimeStrict(
        self: *Engine,
        source_text: []const u8,
        output: *std.Io.Writer,
        mode: frontend.parser.Mode,
        filename: []const u8,
        timing: *EvalTiming,
        runtime_strict: bool,
    ) RuntimeError!core.Value {
        return self.evalModeWithOutputNamedTimedOptions(source_text, output, mode, filename, .auto, timing, false, runtime_strict) catch |err| return @errorCast(moduleResolutionError(err));
    }

    pub const HostHooks = struct {
        ptr: *anyopaque,
        resolveModule: *const fn (*anyopaque, []const u8, ?[]const u8, std.mem.Allocator) anyerror!ResolvedModule,
        loadModule: *const fn (*anyopaque, ResolvedModule, std.mem.Allocator) anyerror!LoadedModule,

        pub const ResolvedModule = struct {
            specifier: []const u8,
            path: []const u8,
            kind: enum { esm, commonjs, json, wasm, builtin },
        };

        pub const LoadedModule = struct {
            source: []const u8,
            path: []const u8,
            kind: enum { esm, commonjs, json, wasm, builtin },
            owned: bool = false,
        };
    };

    pub fn evalFileModuleGraphWithHostHooks(
        self: *Engine,
        source_text: []const u8,
        output: *std.Io.Writer,
        filename: []const u8,
        host_hooks: HostHooks,
        allocator: std.mem.Allocator,
    ) !core.Value {
        self.output = output;
        var module_postorder = std.ArrayList([]const u8).empty;
        defer {
            for (module_postorder.items) |path| allocator.free(path);
            module_postorder.deinit(allocator);
        }
        try preloadFileModuleGraphWithHostHooks(allocator, self.runtime, host_hooks, source_text, filename, &module_postorder);

        const root_module_name = try self.runtime.internAtom(filename);
        defer self.runtime.atoms.free(root_module_name);
        if (self.runtime.modules.find(root_module_name)) |record| record.import_meta_main = true;
        self.runtime.modules.linkModule(self.runtime, root_module_name) catch |err| return moduleResolutionError(err);
        const global = try exec.qjs_vm.ensureContextGlobal(self.context);
        for (module_postorder.items) |path| {
            var module_source: []const u8 = undefined;
            const is_root = std.mem.eql(u8, path, filename);
            var loaded_owned = false;

            if (is_root) {
                module_source = source_text;
            } else {
                const resolved = try host_hooks.resolveModule(host_hooks.ptr, path, null, allocator);
                defer allocator.free(resolved.specifier);
                defer allocator.free(resolved.path);

                const loaded = try host_hooks.loadModule(host_hooks.ptr, resolved, allocator);
                module_source = loaded.source;
                loaded_owned = loaded.owned;
                defer allocator.free(loaded.path);
            }

            var compiled = try frontend.parser.parse(self.runtime, module_source, .{ .mode = .module, .filename = path });
            if (loaded_owned) allocator.free(module_source);
            defer compiled.deinit();
            if (compiled.syntax_error) |err| {
                if (!@import("builtin").is_test) std.debug.print("SYNTAX ERROR in evalFileModuleGraphWithHostHooks {s}:{d}:{d} - {s}\n", .{ path, err.position.line, err.position.column, err.message });
                return error.SyntaxError;
            }
            const module_name = try self.runtime.internAtom(path);
            defer self.runtime.atoms.free(module_name);
            try exec.module.initializeModuleFunctionDeclarations(self.context, global, module_name, &compiled.function);
        }

        var continuations = std.ArrayList(ModuleContinuation).empty;
        defer freeModuleContinuations(self.runtime, allocator, &continuations);

        for (module_postorder.items) |path| {
            if (std.mem.eql(u8, path, filename)) continue;
            try self.drainModuleContinuationsForDependencies(output, allocator, &continuations, path);

            const resolved = try host_hooks.resolveModule(host_hooks.ptr, path, null, allocator);
            defer allocator.free(resolved.specifier);
            defer allocator.free(resolved.path);

            const loaded = try host_hooks.loadModule(host_hooks.ptr, resolved, allocator);
            defer if (loaded.owned) allocator.free(loaded.source);
            defer allocator.free(loaded.path);

            const dep_step = try self.evalPreloadedFileModuleStep(loaded.source, output, path, null, null);
            try self.handleModuleEvalStep(allocator, &continuations, dep_step, loaded.source, path, false);
            self.runJobs();
            if (self.context.hasUnhandledRejection() or self.context.hasException()) return error.UnhandledPromiseRejection;
        }

        try self.drainModuleContinuationsForDependencies(output, allocator, &continuations, filename);
        const root_step = try self.evalPreloadedFileModuleStep(source_text, output, filename, null, null);
        try self.handleModuleEvalStep(allocator, &continuations, root_step, source_text, filename, true);
        return self.drainModuleContinuations(output, allocator, &continuations);
    }

    fn preloadFileModuleGraphWithHostHooks(
        allocator: std.mem.Allocator,
        runtime: *core.Runtime,
        host_hooks: HostHooks,
        root_source: []const u8,
        root_path: []const u8,
        postorder: *std.ArrayList([]const u8),
    ) !void {
        var seen = std.ArrayList([]const u8).empty;
        defer {
            for (seen.items) |path| allocator.free(path);
            seen.deinit(allocator);
        }
        try preloadFileModuleGraphWithHostHooksInner(allocator, runtime, host_hooks, root_source, root_path, &seen, postorder);
    }

    fn preloadFileModuleGraphWithHostHooksInner(
        allocator: std.mem.Allocator,
        runtime: *core.Runtime,
        host_hooks: HostHooks,
        source_text: []const u8,
        path: []const u8,
        seen: *std.ArrayList([]const u8),
        postorder: *std.ArrayList([]const u8),
    ) !void {
        for (seen.items) |existing| {
            if (std.mem.eql(u8, existing, path)) return;
        }
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        try seen.append(allocator, owned_path);

        const module_name = try runtime.internAtom(path);
        defer runtime.atoms.free(module_name);

        var parsed = try frontend.parser.parse(runtime, source_text, .{ .mode = .module, .filename = path });
        defer parsed.deinit();
        if (parsed.syntax_error) |err| {
            if (!@import("builtin").is_test) std.debug.print("SYNTAX ERROR in preloadFileModuleGraphWithHostHooksInner {s}:{d}:{d} - {s}\n", .{ path, err.position.line, err.position.column, err.message });
            return error.SyntaxError;
        }

        _ = try exec.module.instantiateParsedRecordWithReferrer(runtime, module_name, &parsed.function, path);

        const record = parsed.function.module_record orelse return;
        for (record.requests) |request| {
            const specifier = runtime.atoms.name(request.module_name) orelse return error.InvalidAtom;

            const resolved = try host_hooks.resolveModule(host_hooks.ptr, specifier, path, allocator);
            defer allocator.free(resolved.specifier);
            defer allocator.free(resolved.path);

            const resolved_atom = try runtime.internAtom(resolved.path);
            defer runtime.atoms.free(resolved_atom);

            const specifier_atom = request.module_name;
            if (specifier_atom != resolved_atom) {
                if (runtime.modules.find(module_name)) |p_record| {
                    // 1. requested_modules
                    for (p_record.requested_modules) |*req| {
                        if (req.* == specifier_atom) {
                            runtime.atoms.free(req.*);
                            req.* = runtime.atoms.dup(resolved_atom);
                        }
                    }
                    // 2. imports
                    for (p_record.imports) |*imp| {
                        if (imp.module_name == specifier_atom) {
                            runtime.atoms.free(imp.module_name);
                            imp.module_name = runtime.atoms.dup(resolved_atom);
                        }
                    }
                    // 3. indirect_exports
                    for (p_record.indirect_exports) |*ind| {
                        if (ind.module_name == specifier_atom) {
                            runtime.atoms.free(ind.module_name);
                            ind.module_name = runtime.atoms.dup(resolved_atom);
                        }
                    }
                    // 4. star_exports
                    for (p_record.star_exports) |*star| {
                        if (star.module_name == specifier_atom) {
                            runtime.atoms.free(star.module_name);
                            star.module_name = runtime.atoms.dup(resolved_atom);
                        }
                    }
                    // 5. import_attributes
                    for (p_record.import_attributes) |*attr| {
                        if (attr.module_name == specifier_atom) {
                            runtime.atoms.free(attr.module_name);
                            attr.module_name = runtime.atoms.dup(resolved_atom);
                        }
                    }
                }
            }

            const loaded = try host_hooks.loadModule(host_hooks.ptr, resolved, allocator);
            defer if (loaded.owned) allocator.free(loaded.source);
            defer allocator.free(loaded.path);

            try preloadFileModuleGraphWithHostHooksInner(allocator, runtime, host_hooks, loaded.source, loaded.path, seen, postorder);
        }

        const order_path = try allocator.dupe(u8, path);
        errdefer allocator.free(order_path);
        try postorder.append(allocator, order_path);
    }

    pub fn evalFileModuleGraphWithOutput(
        self: *Engine,
        source_text: []const u8,
        output: *std.Io.Writer,
        filename: []const u8,
        io: std.Io,
        allocator: std.mem.Allocator,
        max_source_size: usize,
    ) !core.Value {
        const normalized_filename = try std.fs.path.resolve(allocator, &.{filename});
        defer allocator.free(normalized_filename);

        var module_postorder = std.ArrayList([]const u8).empty;
        defer {
            for (module_postorder.items) |path| allocator.free(path);
            module_postorder.deinit(allocator);
        }
        try exec.module.preloadFileModuleGraphWithOrder(io, allocator, self.runtime, source_text, normalized_filename, max_source_size, &module_postorder);
        const root_module_name = try self.runtime.internAtom(normalized_filename);
        defer self.runtime.atoms.free(root_module_name);
        if (self.runtime.modules.find(root_module_name)) |record| record.import_meta_main = true;
        self.runtime.modules.linkModule(self.runtime, root_module_name) catch |err| return moduleResolutionError(err);
        try self.initializeSyntheticFileModules(io, allocator, max_source_size);
        try self.initializePreloadedModuleFunctionDeclarations(source_text, normalized_filename, io, allocator, max_source_size, module_postorder.items);
        var dynamic_import_state = DynamicImportState{
            .engine = self,
            .io = io,
            .allocator = allocator,
            .max_source_size = max_source_size,
        };
        const prev_dynamic_import_callback = self.context.dynamic_import_callback;
        const prev_dynamic_import_userdata = self.context.dynamic_import_userdata;
        self.context.dynamic_import_callback = DynamicImportState.load;
        self.context.dynamic_import_userdata = &dynamic_import_state;
        defer {
            self.context.dynamic_import_callback = prev_dynamic_import_callback;
            self.context.dynamic_import_userdata = prev_dynamic_import_userdata;
        }
        var continuations = std.ArrayList(ModuleContinuation).empty;
        defer freeModuleContinuations(self.runtime, allocator, &continuations);
        for (module_postorder.items) |path| {
            if (std.mem.eql(u8, path, normalized_filename)) continue;
            try self.drainModuleContinuationsForDependencies(output, allocator, &continuations, path);
            const dep_source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_source_size));
            defer allocator.free(dep_source);
            const dep_step = try self.evalPreloadedFileModuleStep(dep_source, output, path, null, null);
            try self.handleModuleEvalStep(allocator, &continuations, dep_step, dep_source, path, false);
            self.runJobs();
            if (self.context.hasUnhandledRejection() or self.context.hasException()) return error.UnhandledPromiseRejection;
        }
        try self.drainModuleContinuationsForDependencies(output, allocator, &continuations, normalized_filename);
        const root_step = try self.evalPreloadedFileModuleStep(source_text, output, normalized_filename, null, null);
        try self.handleModuleEvalStep(allocator, &continuations, root_step, source_text, normalized_filename, true);
        return self.drainModuleContinuations(output, allocator, &continuations);
    }

    fn evalDynamicImportModule(
        self: *Engine,
        output: ?*std.Io.Writer,
        referrer_path: []const u8,
        specifier: []const u8,
        io: std.Io,
        allocator: std.mem.Allocator,
        max_source_size: usize,
    ) !core.Value {
        if (referrer_path.len == 0) return error.ModuleNotFound;
        const target_path = try exec.module.resolveModuleSpecifier(allocator, referrer_path, specifier);
        defer allocator.free(target_path);
        if (std.mem.eql(u8, target_path, "std") or std.mem.eql(u8, target_path, "os")) {
            const target_module_name = try self.runtime.internAtom(target_path);
            defer self.runtime.atoms.free(target_module_name);
            _ = try exec.module.preloadNativeModule(self.runtime, if (std.mem.eql(u8, target_path, "std")) .native_std else .native_os);
            self.runtime.modules.linkModule(self.runtime, target_module_name) catch |err| return moduleResolutionError(err);
            try self.initializeNativeSyntheticModules();
            return exec.module.moduleNamespaceValue(self.context, target_module_name);
        }
        const source_text = std.Io.Dir.cwd().readFileAlloc(io, target_path, allocator, .limited(max_source_size)) catch |err| switch (err) {
            error.FileNotFound => return error.ModuleNotFound,
            else => |e| return e,
        };
        defer allocator.free(source_text);

        var module_postorder = std.ArrayList([]const u8).empty;
        defer {
            for (module_postorder.items) |path| allocator.free(path);
            module_postorder.deinit(allocator);
        }
        try exec.module.preloadMissingFileModuleGraphWithOrder(io, allocator, self.runtime, source_text, target_path, max_source_size, &module_postorder);
        const target_module_name = try self.runtime.internAtom(target_path);
        defer self.runtime.atoms.free(target_module_name);
        self.runtime.modules.linkModule(self.runtime, target_module_name) catch |err| return moduleResolutionError(err);
        try self.initializeSyntheticFileModules(io, allocator, max_source_size);
        try self.initializePreloadedModuleFunctionDeclarations(source_text, target_path, io, allocator, max_source_size, module_postorder.items);

        for (module_postorder.items) |path| {
            const module_source = if (std.mem.eql(u8, path, target_path))
                source_text
            else
                try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_source_size));
            defer if (!std.mem.eql(u8, path, target_path)) allocator.free(module_source);
            const value = try self.evalPreloadedFileModuleWithOutput(module_source, output, path);
            defer value.free(self.runtime);
            self.runJobs();
            if (self.context.hasUnhandledRejection() or self.context.hasException()) return error.UnhandledPromiseRejection;
        }

        return exec.module.moduleNamespaceValue(self.context, target_module_name);
    }

    fn initializePreloadedModuleFunctionDeclarations(
        self: *Engine,
        root_source: []const u8,
        root_path: []const u8,
        io: std.Io,
        allocator: std.mem.Allocator,
        max_source_size: usize,
        postorder: []const []const u8,
    ) !void {
        const global = try exec.qjs_vm.ensureContextGlobal(self.context);
        for (postorder) |path| {
            const module_source = if (std.mem.eql(u8, path, root_path))
                root_source
            else
                try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_source_size));
            defer if (!std.mem.eql(u8, path, root_path)) allocator.free(module_source);

            var compiled = try frontend.parser.parse(self.runtime, module_source, .{ .mode = .module, .filename = path });
            defer compiled.deinit();
            if (compiled.syntax_error != null) return error.SyntaxError;
            const module_name = try self.runtime.internAtom(path);
            defer self.runtime.atoms.free(module_name);
            try exec.module.initializeModuleFunctionDeclarations(self.context, global, module_name, &compiled.function);
        }
    }

    fn initializeSyntheticFileModules(
        self: *Engine,
        io: std.Io,
        allocator: std.mem.Allocator,
        max_source_size: usize,
    ) !void {
        const global = try exec.qjs_vm.ensureContextGlobal(self.context);
        for (self.runtime.modules.modules) |record| {
            if (record.synthetic_kind == .none) continue;
            if (record.synthetic_kind == .native_std or record.synthetic_kind == .native_os) {
                _ = try exec.module.initializeSyntheticFileModule(self.context, global, record.module_name, "");
                continue;
            }
            const path = self.runtime.atoms.name(record.module_name) orelse return error.InvalidAtom;
            const source_path = exec.module.syntheticModuleFilePath(path);
            const module_source = try std.Io.Dir.cwd().readFileAlloc(io, source_path, allocator, .limited(max_source_size));
            defer allocator.free(module_source);
            _ = try exec.module.initializeSyntheticFileModule(self.context, global, record.module_name, module_source);
        }
    }

    fn initializeNativeSyntheticModules(self: *Engine) !void {
        const global = try exec.qjs_vm.ensureContextGlobal(self.context);
        for (self.runtime.modules.modules) |record| {
            if (record.synthetic_kind != .native_std and record.synthetic_kind != .native_os) continue;
            _ = try exec.module.initializeSyntheticFileModule(self.context, global, record.module_name, "");
        }
    }

    fn evalModeWithOutput(
        self: *Engine,
        source_text: []const u8,
        output: ?*std.Io.Writer,
        mode: frontend.parser.Mode,
    ) !core.Value {
        return self.evalModeWithOutputNamed(source_text, output, mode, "<eval>");
    }

    fn evalModeWithOutputNamed(
        self: *Engine,
        source_text: []const u8,
        output: ?*std.Io.Writer,
        mode: frontend.parser.Mode,
        filename: []const u8,
    ) !core.Value {
        return self.evalModeWithOutputNamedTimed(source_text, output, mode, filename, null);
    }

    fn evalModeWithOutputNamedTimed(
        self: *Engine,
        source_text: []const u8,
        output: ?*std.Io.Writer,
        mode: frontend.parser.Mode,
        filename: []const u8,
        timing: ?*EvalTiming,
    ) !core.Value {
        return self.evalModeWithOutputNamedTimedOptions(source_text, output, mode, filename, .auto, timing, false, false);
    }

    fn evalModeWithOutputNamedTimedOptions(
        self: *Engine,
        source_text: []const u8,
        output: ?*std.Io.Writer,
        mode: frontend.parser.Mode,
        filename: []const u8,
        source_kind: frontend.parser.SourceKind,
        timing: ?*EvalTiming,
        parse_strict: bool,
        runtime_strict: bool,
    ) !core.Value {
        self.output = output;
        const parse_start = monotonicNanos();
        var compiled = try frontend.parser.parse(self.runtime, source_text, .{
            .mode = mode,
            .filename = filename,
            .source_kind = source_kind,
            .strict = parse_strict,
        });
        if (timing) |t| t.parse_ns += elapsedNanosSince(parse_start);
        defer compiled.deinit();
        if (compiled.syntax_error) |err| {
            if (mode == .script and isWhitespaceSeparatedNumericScript(source_text)) return core.Value.undefinedValue();
            if (!@import("builtin").is_test) std.debug.print("SYNTAX ERROR in {s}:{d}:{d} - {s}\n", .{ filename, err.position.line, err.position.column, err.message });
            return error.SyntaxError;
        }
        if (runtime_strict and mode == .script) forceRuntimeStrict(&compiled.function);
        var module_name: core.Atom = core.atom.null_atom;
        var has_module_record = false;
        defer if (has_module_record) self.runtime.atoms.free(module_name);
        if (mode == .module and compiled.function.module_record != null) {
            var module_name_buf: [64]u8 = undefined;
            const module_name_bytes = if (std.mem.eql(u8, filename, "<eval>"))
                try std.fmt.bufPrint(&module_name_buf, "<eval>#{d}", .{self.runtime.modules.modules.len})
            else
                filename;
            module_name = try self.runtime.internAtom(module_name_bytes);
            has_module_record = true;
            const referrer_path: ?[]const u8 = if (std.mem.eql(u8, filename, "<eval>")) null else filename;
            _ = try exec.module.instantiateParsedRecordWithReferrer(self.runtime, module_name, &compiled.function, referrer_path);
            if (self.runtime.modules.find(module_name)) |record| record.import_meta_main = true;
            self.runtime.modules.linkModule(self.runtime, module_name) catch |err| {
                if (!@import("builtin").is_test) std.debug.print("LINK ERROR for module {s}: {s}\n", .{ filename, @errorName(err) });
                return moduleResolutionError(err);
            };
            try self.initializeNativeSyntheticModules();
        }
        var module_var_refs: []core.Value = &.{};
        if (has_module_record) {
            module_var_refs = try exec.module.buildModuleVarRefs(self.context, module_name, &compiled.function);
        }
        defer exec.module.freeModuleVarRefs(self.runtime, module_var_refs);
        if (output) |writer| {
            const result = if (has_module_record)
                try self.runEvalModuleWithVarRefs(&compiled.function, output, module_var_refs, timing)
            else blk: {
                var vm_instance = exec.Vm.initWithOutput(self.context, writer);
                defer vm_instance.deinit();
                const vm_start = monotonicNanos();
                const value = try vm_instance.run(&compiled.function);
                if (timing) |t| t.vm_run_ns += elapsedNanosSince(vm_start);
                break :blk value;
            };
            const global = try exec.qjs_vm.ensureContextGlobal(self.context);
            const jobs_start = monotonicNanos();
            try exec.qjs_vm.drainPendingPromiseJobs(self.context, output, global);
            if (timing) |t| t.promise_jobs_ns += elapsedNanosSince(jobs_start);
            if (mode == .script and !std.mem.eql(u8, filename, "<repl>")) {
                result.free(self.runtime);
                return core.Value.undefinedValue();
            }
            return result;
        } else {
            const result = if (has_module_record)
                try self.runEvalModuleWithVarRefs(&compiled.function, output, module_var_refs, timing)
            else blk: {
                var vm_instance = exec.Vm.init(self.context);
                defer vm_instance.deinit();
                const vm_start = monotonicNanos();
                const value = try vm_instance.run(&compiled.function);
                if (timing) |t| t.vm_run_ns += elapsedNanosSince(vm_start);
                break :blk value;
            };
            const global = try exec.qjs_vm.ensureContextGlobal(self.context);
            const jobs_start = monotonicNanos();
            try exec.qjs_vm.drainPendingPromiseJobs(self.context, output, global);
            if (timing) |t| t.promise_jobs_ns += elapsedNanosSince(jobs_start);
            if (mode == .script and !std.mem.eql(u8, filename, "<repl>")) {
                result.free(self.runtime);
                return core.Value.undefinedValue();
            }
            return result;
        }
    }

    fn runEvalModuleWithVarRefs(
        self: *Engine,
        function: *const bytecode.Bytecode,
        output: ?*std.Io.Writer,
        module_var_refs: []const core.Value,
        timing: ?*EvalTiming,
    ) !core.Value {
        var continuation_value = (try core.Object.create(self.runtime, core.class.ids.generator, null)).value();
        defer continuation_value.free(self.runtime);
        const continuation = try exec.property_ops.expectObject(continuation_value);
        var resume_value: ?core.Value = null;
        var resume_value_symbol_rooted = false;
        defer if (resume_value) |value| {
            if (resume_value_symbol_rooted) self.runtime.unregisterExternalValueSymbolRoot(value);
            value.free(self.runtime);
        };

        while (true) {
            var stack = exec.stack.Stack.init(&self.runtime.memory, self.context.stack_limit);
            defer stack.deinit(self.runtime);
            const vm_start = monotonicNanos();
            const result = exec.qjs_vm.runModuleWithOutputAndVarRefsState(
                self.context,
                &stack,
                function,
                output,
                module_var_refs,
                continuation,
                resume_value,
            ) catch |err| return moduleResolutionError(err);
            if (timing) |t| t.vm_run_ns += elapsedNanosSince(vm_start);
            if (resume_value) |value| {
                if (resume_value_symbol_rooted) {
                    self.runtime.unregisterExternalValueSymbolRoot(value);
                    resume_value_symbol_rooted = false;
                }
                value.free(self.runtime);
                resume_value = null;
            }

            if (continuation.generatorJustYielded() and !continuation.generatorDone()) {
                resume_value = result;
                resume_value_symbol_rooted = try self.runtime.registerExternalValueSymbolRoot(result);
                const global = try exec.qjs_vm.ensureContextGlobal(self.context);
                const jobs_start = monotonicNanos();
                try exec.qjs_vm.drainPendingPromiseJobs(self.context, output, global);
                if (timing) |t| t.promise_jobs_ns += elapsedNanosSince(jobs_start);
                continue;
            }

            return result;
        }
    }

    fn evalPreloadedFileModuleWithOutput(
        self: *Engine,
        source_text: []const u8,
        output: ?*std.Io.Writer,
        filename: []const u8,
    ) !core.Value {
        var continuations = std.ArrayList(ModuleContinuation).empty;
        defer freeModuleContinuations(self.runtime, self.runtime.memory.allocator, &continuations);
        const step = try self.evalPreloadedFileModuleStep(source_text, output, filename, null, null);
        try self.handleModuleEvalStep(self.runtime.memory.allocator, &continuations, step, source_text, filename, true);
        return self.drainModuleContinuations(output, self.runtime.memory.allocator, &continuations);
    }

    fn evalPreloadedFileModuleStep(
        self: *Engine,
        source_text: []const u8,
        output: ?*std.Io.Writer,
        filename: []const u8,
        continuation_value: ?core.Value,
        resume_value: ?core.Value,
    ) !ModuleEvalStep {
        var input_continuation = continuation_value;
        errdefer if (input_continuation) |value| value.free(self.runtime);

        var compiled = try frontend.parser.parse(self.runtime, source_text, .{ .mode = .module, .filename = filename });
        defer compiled.deinit();
        if (compiled.syntax_error) |err| {
            if (!@import("builtin").is_test) std.debug.print("SYNTAX ERROR in evalPreloadedFileModuleStep {s}:{d}:{d} - {s}\n", .{ filename, err.position.line, err.position.column, err.message });
            return error.SyntaxError;
        }

        const module_name = try self.runtime.internAtom(filename);
        defer self.runtime.atoms.free(module_name);
        if (self.runtime.modules.find(module_name) == null) return error.ModuleNotFound;
        self.runtime.modules.linkModule(self.runtime, module_name) catch |err| {
            if (!@import("builtin").is_test) std.debug.print("LINK ERROR in evalPreloadedFileModuleStep for module {s}: {s}\n", .{ filename, @errorName(err) });
            return moduleResolutionError(err);
        };

        const module_var_refs = try exec.module.buildModuleVarRefs(self.context, module_name, &compiled.function);
        defer exec.module.freeModuleVarRefs(self.runtime, module_var_refs);
        var owned_continuation = if (input_continuation) |value| blk: {
            input_continuation = null;
            break :blk value;
        } else blk: {
            const object = try core.Object.create(self.runtime, core.class.ids.generator, null);
            break :blk object.value();
        };
        errdefer owned_continuation.free(self.runtime);
        const continuation = try exec.property_ops.expectObject(owned_continuation);
        var stack = exec.stack.Stack.init(&self.runtime.memory, self.context.stack_limit);
        defer stack.deinit(self.runtime);
        const result = exec.qjs_vm.runModuleWithOutputAndVarRefsState(self.context, &stack, &compiled.function, output, module_var_refs, continuation, resume_value) catch |err| return moduleResolutionError(err);
        if (continuation.generatorJustYielded() and !continuation.generatorDone()) {
            return .{ .suspended = .{
                .continuation = owned_continuation,
                .awaited = result,
            } };
        }
        owned_continuation.free(self.runtime);
        return .{ .completed = result };
    }

    fn handleModuleEvalStep(
        self: *Engine,
        allocator: std.mem.Allocator,
        continuations: *std.ArrayList(ModuleContinuation),
        step: ModuleEvalStep,
        source_text: []const u8,
        filename: []const u8,
        keep_result: bool,
    ) !void {
        switch (step) {
            .completed => |value| {
                if (keep_result) {
                    errdefer value.free(self.runtime);
                    const source_copy = try allocator.dupe(u8, source_text);
                    errdefer allocator.free(source_copy);
                    const path_copy = try allocator.dupe(u8, filename);
                    errdefer allocator.free(path_copy);
                    var continuation = ModuleContinuation{
                        .source = source_copy,
                        .path = path_copy,
                        .continuation = core.Value.undefinedValue(),
                        .awaited = value,
                        .keep_result = true,
                        .completed = true,
                    };
                    try continuation.registerSymbolRoots(self.runtime);
                    errdefer continuation.unregisterSymbolRoots(self.runtime);
                    try continuations.append(allocator, continuation);
                } else {
                    value.free(self.runtime);
                }
            },
            .suspended => |suspended| {
                errdefer suspended.continuation.free(self.runtime);
                errdefer suspended.awaited.free(self.runtime);
                const source_copy = try allocator.dupe(u8, source_text);
                errdefer allocator.free(source_copy);
                const path_copy = try allocator.dupe(u8, filename);
                errdefer allocator.free(path_copy);
                var continuation = ModuleContinuation{
                    .source = source_copy,
                    .path = path_copy,
                    .continuation = suspended.continuation,
                    .awaited = suspended.awaited,
                    .keep_result = keep_result,
                };
                try continuation.registerSymbolRoots(self.runtime);
                errdefer continuation.unregisterSymbolRoots(self.runtime);
                try continuations.append(allocator, continuation);
            },
        }
    }

    fn drainModuleContinuations(
        self: *Engine,
        output: ?*std.Io.Writer,
        allocator: std.mem.Allocator,
        continuations: *std.ArrayList(ModuleContinuation),
    ) !core.Value {
        var kept_result: core.Value = core.Value.undefinedValue();
        var has_kept_result = false;
        while (continuations.items.len != 0) {
            if (try self.drainOneModuleContinuation(output, allocator, continuations)) |value| {
                if (has_kept_result) kept_result.free(self.runtime);
                kept_result = value;
                has_kept_result = true;
            }
        }
        if (has_kept_result) return kept_result;
        return core.Value.undefinedValue();
    }

    fn drainModuleContinuationsForDependencies(
        self: *Engine,
        output: ?*std.Io.Writer,
        allocator: std.mem.Allocator,
        continuations: *std.ArrayList(ModuleContinuation),
        filename: []const u8,
    ) !void {
        while (try self.hasActiveAsyncDependency(continuations, filename)) {
            if (try self.drainOneModuleContinuation(output, allocator, continuations)) |value| value.free(self.runtime);
        }
    }

    fn drainOneModuleContinuation(
        self: *Engine,
        output: ?*std.Io.Writer,
        allocator: std.mem.Allocator,
        continuations: *std.ArrayList(ModuleContinuation),
    ) !?core.Value {
        var current = continuations.orderedRemove(0);
        var current_roots_registered = true;
        errdefer if (current_roots_registered) current.unregisterSymbolRoots(self.runtime);
        defer allocator.free(current.source);
        defer allocator.free(current.path);
        if (current.completed) {
            current.unregisterSymbolRoots(self.runtime);
            current_roots_registered = false;
            if (current.keep_result) return current.awaited;
            current.awaited.free(self.runtime);
            return null;
        }
        const awaited_value = current.awaited;
        var awaited_owned = true;
        errdefer if (awaited_owned) awaited_value.free(self.runtime);
        const continuation = current.continuation;
        var continuation_owned = true;
        errdefer if (continuation_owned) continuation.free(self.runtime);
        const module_source = current.source;
        const path = current.path;
        const keep_result = current.keep_result;
        const global = try exec.qjs_vm.ensureContextGlobal(self.context);
        try exec.qjs_vm.drainPendingPromiseJobs(self.context, output, global);
        continuation_owned = false;
        const step = try self.evalPreloadedFileModuleStep(module_source, output, path, continuation, awaited_value);
        awaited_value.free(self.runtime);
        awaited_owned = false;
        current.unregisterSymbolRoots(self.runtime);
        current_roots_registered = false;
        var step_owned = true;
        errdefer if (step_owned) freeModuleEvalStep(self.runtime, step);
        self.runJobs();
        if (self.context.hasUnhandledRejection() or self.context.hasException()) return error.UnhandledPromiseRejection;
        step_owned = false;
        try self.handleModuleEvalStep(allocator, continuations, step, module_source, path, keep_result);
        return null;
    }

    fn hasActiveAsyncDependency(
        self: *Engine,
        continuations: *const std.ArrayList(ModuleContinuation),
        filename: []const u8,
    ) !bool {
        const module_name = try self.runtime.internAtom(filename);
        defer self.runtime.atoms.free(module_name);
        const record = self.runtime.modules.find(module_name) orelse return false;
        var visited = std.ArrayList(core.Atom).empty;
        defer visited.deinit(self.runtime.memory.allocator);
        return self.recordHasActiveAsyncDependency(continuations, record, &visited);
    }

    fn recordHasActiveAsyncDependency(
        self: *Engine,
        continuations: *const std.ArrayList(ModuleContinuation),
        record: *const core.module.ModuleRecord,
        visited: *std.ArrayList(core.Atom),
    ) !bool {
        for (visited.items) |seen| {
            if (seen == record.module_name) return false;
        }
        try visited.append(self.runtime.memory.allocator, record.module_name);
        for (record.requested_modules) |request| {
            const request_name = self.runtime.atoms.name(request) orelse continue;
            for (continuations.items) |continuation| {
                if (!continuation.completed and std.mem.eql(u8, continuation.path, request_name)) return true;
            }
            const requested_record = self.runtime.modules.find(request) orelse continue;
            if (try self.recordHasActiveAsyncDependency(continuations, requested_record, visited)) return true;
        }
        return false;
    }

    pub fn runJobs(self: *Engine) void {
        self.job_queue.runAll();
        if (exec.qjs_vm.ensureContextGlobal(self.context)) |global| {
            exec.qjs_vm.drainPendingPromiseJobs(self.context, self.output, global) catch {};
        } else |_| {}
    }

    pub fn exposeStdOsGlobals(self: *Engine) !void {
        const global = try exec.qjs_vm.ensureContextGlobal(self.context);
        try self.exposeNativeModuleGlobal(global, "std", .native_std);
        try self.exposeNativeModuleGlobal(global, "os", .native_os);
    }

    pub fn defineScriptArgs(self: *Engine, args: []const []const u8) !void {
        try self.defineStringArrayGlobal("scriptArgs", args);
    }

    pub fn createExternalHostFunctionValue(
        self: *Engine,
        name: []const u8,
        length: i32,
        ptr: *anyopaque,
        call: ExternalHostCallFn,
        finalizer: ?ExternalHostFinalizer,
    ) !core.Value {
        const id = try self.runtime.registerExternalHostFunction(.{
            .ptr = ptr,
            .call = call,
            .finalizer = finalizer,
        });
        const function_value = try builtins.function.nativeFunction(self.runtime, name, length);
        errdefer function_value.free(self.runtime);

        const function_object = try exec.property_ops.expectObject(function_value);
        function_object.hostFunctionKindSlot().* = core.host_function.ids.external_host;
        function_object.externalHostFunctionIdSlot().* = id;
        const global = try exec.qjs_vm.ensureContextGlobal(self.context);
        try function_object.setFunctionRealmGlobalPtr(self.runtime, global);
        return function_value;
    }

    pub fn defineGlobalExternalHostFunction(
        self: *Engine,
        name: []const u8,
        length: i32,
        ptr: *anyopaque,
        call: ExternalHostCallFn,
        finalizer: ?ExternalHostFinalizer,
    ) !void {
        const global = try exec.qjs_vm.ensureContextGlobal(self.context);
        const function_value = try self.createExternalHostFunctionValue(name, length, ptr, call, finalizer);
        defer function_value.free(self.runtime);

        const property_name = try self.runtime.internAtom(name);
        defer self.runtime.atoms.free(property_name);
        try global.defineOwnProperty(self.runtime, property_name, core.Descriptor.data(function_value, true, false, true));
    }

    pub fn defineArgvGlobals(self: *Engine, argv0: []const u8, exec_argv: []const []const u8) !void {
        const global = try exec.qjs_vm.ensureContextGlobal(self.context);
        const argv0_value = try exec.value_ops.createStringValue(self.runtime, argv0);
        defer argv0_value.free(self.runtime);
        const argv0_key = try self.runtime.internAtom("argv0");
        defer self.runtime.atoms.free(argv0_key);
        try global.defineOwnProperty(self.runtime, argv0_key, core.Descriptor.data(argv0_value, true, true, true));
        try self.defineStringArrayGlobal("execArgv", exec_argv);
    }

    fn defineStringArrayGlobal(self: *Engine, name: []const u8, items: []const []const u8) !void {
        const global = try exec.qjs_vm.ensureContextGlobal(self.context);
        const values = try self.runtime.memory.alloc(core.Value, items.len);
        defer self.runtime.memory.free(core.Value, values);
        var initialized: usize = 0;
        defer {
            for (values[0..initialized]) |value| value.free(self.runtime);
        }
        for (items, 0..) |item, index| {
            values[index] = try exec.value_ops.createStringValue(self.runtime, item);
            initialized += 1;
        }

        const array_prototype = try self.arrayPrototypeFromGlobal(global);
        const array = try core.Object.createArray(self.runtime, array_prototype);
        var array_raw_owned = true;
        errdefer if (array_raw_owned) core.Object.destroyFromHeader(self.runtime, &array.header);
        for (values, 0..) |value, index| {
            try array.defineOwnProperty(self.runtime, core.atom.atomFromUInt32(@intCast(index)), core.Descriptor.data(value, true, true, true));
        }
        array.length = @intCast(items.len);
        const property_name = try self.runtime.internAtom(name);
        defer self.runtime.atoms.free(property_name);
        const array_value = array.value();
        array_raw_owned = false;
        defer array_value.free(self.runtime);
        try global.defineOwnProperty(self.runtime, property_name, core.Descriptor.data(array_value, true, true, true));
    }

    pub fn defineCliArgvGlobalsLazy(self: *Engine, argv0: []const u8, exec_argv: []const []const u8) !void {
        self.runtime.cli_argv0 = argv0;
        self.runtime.cli_exec_argv = exec_argv;
        const global = try exec.qjs_vm.ensureContextGlobal(self.context);
        const flags = core.property.Flags.data(true, true, true);
        try global.defineCliGlobalAutoInitProperty(self.runtime, core.atom.predefinedId("argv0", .string).?, "argv0", flags, global);
        try global.defineCliGlobalAutoInitProperty(self.runtime, core.atom.predefinedId("execArgv", .string).?, "execArgv", flags, global);
    }

    pub fn defineCliScriptArgsLazy(self: *Engine, args: []const []const u8) !void {
        self.runtime.cli_script_args = args;
        const global = try exec.qjs_vm.ensureContextGlobal(self.context);
        try global.defineCliGlobalAutoInitProperty(
            self.runtime,
            core.atom.predefinedId("scriptArgs", .string).?,
            "scriptArgs",
            core.property.Flags.data(true, true, true),
            global,
        );
    }

    fn arrayPrototypeFromGlobal(self: *Engine, global: *core.Object) !*core.Object {
        const array_ctor_value = global.getProperty(core.atom.ids.Array);
        defer array_ctor_value.free(self.runtime);
        const array_ctor = try exec.property_ops.expectObject(array_ctor_value);
        const prototype_value = array_ctor.getProperty(core.atom.ids.prototype);
        defer prototype_value.free(self.runtime);
        return try exec.property_ops.expectObject(prototype_value);
    }

    fn exposeNativeModuleGlobal(
        self: *Engine,
        global: *core.Object,
        name: []const u8,
        kind: core.module.SyntheticKind,
    ) !void {
        _ = try exec.module.preloadNativeModule(self.runtime, kind);
        const module_name = try self.runtime.internAtom(name);
        defer self.runtime.atoms.free(module_name);
        self.runtime.modules.linkModule(self.runtime, module_name) catch |err| return moduleResolutionError(err);
        _ = try exec.module.initializeSyntheticFileModule(self.context, global, module_name, "");
        const namespace = try exec.module.moduleNamespaceValue(self.context, module_name);
        defer namespace.free(self.runtime);
        const property_name = try self.runtime.internAtom(name);
        defer self.runtime.atoms.free(property_name);
        try global.defineOwnProperty(self.runtime, property_name, core.Descriptor.data(namespace, true, false, true));
    }

    pub fn takeException(self: *Engine) core.Value {
        if (self.context.hasUnhandledRejection()) {
            const rejection = self.context.takeUnhandledRejection();
            if (self.context.hasException()) self.context.clearException();
            return rejection;
        }
        return self.context.takeException();
    }

    pub fn takeExceptionInfo(self: *Engine) ExceptionInfo {
        return .{
            .value = ValueHandle.init(self.runtime, self.takeException()),
        };
    }
};

const ModuleEvalStep = union(enum) {
    completed: core.Value,
    suspended: struct {
        continuation: core.Value,
        awaited: core.Value,
    },
};

const ModuleContinuation = struct {
    source: []const u8,
    path: []const u8,
    continuation: core.Value,
    awaited: core.Value,
    keep_result: bool,
    completed: bool = false,
    symbol_root_mask: u2 = 0,

    fn registerSymbolRoots(self: *ModuleContinuation, runtime: *core.Runtime) !void {
        std.debug.assert(self.symbol_root_mask == 0);
        errdefer self.unregisterSymbolRoots(runtime);
        if (try runtime.registerExternalValueSymbolRoot(self.continuation)) self.symbol_root_mask |= 0b01;
        if (try runtime.registerExternalValueSymbolRoot(self.awaited)) self.symbol_root_mask |= 0b10;
    }

    fn unregisterSymbolRoots(self: *ModuleContinuation, runtime: *core.Runtime) void {
        if ((self.symbol_root_mask & 0b01) != 0) runtime.unregisterExternalValueSymbolRoot(self.continuation);
        if ((self.symbol_root_mask & 0b10) != 0) runtime.unregisterExternalValueSymbolRoot(self.awaited);
        self.symbol_root_mask = 0;
    }
};

fn freeModuleContinuations(
    runtime: *core.Runtime,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(ModuleContinuation),
) void {
    for (continuations.items) |*item| {
        allocator.free(item.source);
        allocator.free(item.path);
        item.unregisterSymbolRoots(runtime);
        item.continuation.free(runtime);
        item.awaited.free(runtime);
    }
    continuations.deinit(allocator);
}

fn freeModuleEvalStep(runtime: *core.Runtime, step: ModuleEvalStep) void {
    switch (step) {
        .completed => |value| value.free(runtime),
        .suspended => |suspended| {
            suspended.continuation.free(runtime);
            suspended.awaited.free(runtime);
        },
    }
}

const DynamicImportState = struct {
    engine: *Engine,
    io: std.Io,
    allocator: std.mem.Allocator,
    max_source_size: usize,

    fn load(
        userdata: ?*anyopaque,
        ctx: *core.Context,
        output: ?*std.Io.Writer,
        global: *core.Object,
        referrer_path: []const u8,
        specifier: []const u8,
    ) core.context.DynamicImportError!core.Value {
        _ = ctx;
        _ = global;
        const state: *DynamicImportState = @ptrCast(@alignCast(userdata orelse return error.ModuleNotFound));
        return state.engine.evalDynamicImportModule(output, referrer_path, specifier, state.io, state.allocator, state.max_source_size);
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

fn forceFunctionBytecodeRuntimeStrict(value: core.Value) void {
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

test {
    _ = core;
    _ = frontend;
    _ = bytecode;
    _ = exec;
    _ = builtins;
    _ = libs;
}

test "realm cached generator prototypes release OOM state once" {
    try expectRealmCachedGeneratorPrototypeOOMCleanup(.generator);
    try expectRealmCachedGeneratorPrototypeOOMCleanup(.async_generator);
    try expectRealmCachedGeneratorPrototypeOOMCleanup(.async_function_function);
    try expectRealmCachedGeneratorPrototypeOOMCleanup(.generator_function);
    try expectRealmCachedGeneratorPrototypeOOMCleanup(.async_generator_function);
}

const RealmCachedGeneratorPrototypeKind = enum {
    generator,
    async_generator,
    async_function_function,
    generator_function,
    async_generator_function,
};

fn expectRealmCachedGeneratorPrototypeOOMCleanup(kind: RealmCachedGeneratorPrototypeKind) !void {
    var saw_oom = false;
    var saw_success = false;

    var fail_offset: usize = 0;
    while (fail_offset < 280) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.Runtime.create(failing.allocator());
        const global = try core.Object.create(rt, core.class.ids.object, null);

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = realmCachedPrototypeFromGlobal(rt, global, kind);
        failing.fail_index = std.math.maxInt(usize);

        if (result) |_| {
            saw_success = true;
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => |unexpected| {
                cleanupRealmCachedGeneratorPrototypeOOMIteration(rt, global);
                return unexpected;
            },
        }

        cleanupRealmCachedGeneratorPrototypeOOMIteration(rt, global);
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

fn realmCachedPrototypeFromGlobal(
    rt: *core.Runtime,
    global: *core.Object,
    kind: RealmCachedGeneratorPrototypeKind,
) !?*core.Object {
    return switch (kind) {
        .generator => try shared_vm.generatorPrototypeFromGlobal(rt, global),
        .async_generator => try shared_vm.asyncGeneratorPrototypeFromGlobal(rt, global),
        .async_function_function => try shared_vm.asyncFunctionPrototypeFromGlobal(rt, global),
        .generator_function => try shared_vm.generatorFunctionPrototypeFromGlobal(rt, global),
        .async_generator_function => try shared_vm.asyncGeneratorFunctionPrototypeFromGlobal(rt, global),
    };
}

fn cleanupRealmCachedGeneratorPrototypeOOMIteration(rt: *core.Runtime, global: *core.Object) void {
    global.value().free(rt);
    rt.destroy();
}

const std = @import("std");
const shared_vm = @import("exec/vm/shared.zig");
