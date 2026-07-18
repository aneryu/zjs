const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;

const core = zjs.core;
const QjsLexer = zjs.parser.Lexer;
const parser_core = zjs.parser.Parser;
const ParseState = parser_core.ParseState;
const bytecode = zjs.bytecode;
const function_def = zjs.bytecode.function_def;
const op = zjs.bytecode.opcode.op;
const property_ops = zjs.exec.property_ops;
const object_ops = zjs.exec.object_ops;
const frame_mod = zjs.exec.frame;
const inline_calls = zjs.exec.inline_calls;

const makeFunction = helpers.makeFunction;
const runFunction = helpers.runFunction;
const countJob = helpers.countJob;
const countJobArgs = helpers.countJobArgs;

fn localIndexNamed(rt: *core.JSRuntime, function: *const bytecode.FunctionBytecode, name: []const u8) ?usize {
    for (function.varDefs(), 0..) |vd, idx| {
        const bytes = rt.atoms.name(vd.var_name) orelse continue;
        if (std.mem.eql(u8, bytes, name)) return idx;
    }
    return null;
}

test "var-ref growth promotes borrowed captures to owned cells" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("frame-borrowed-var-ref-growth-test");
    defer rt.atoms.free(name);
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    const captured = try core.VarRef.createClosed(rt, core.JSValue.int32(41));
    defer captured.freeCell(rt);
    var captures = [_]*core.VarRef{captured};
    var exec_frame = frame_mod.Frame.init(&function);
    defer exec_frame.deinit(&rt.memory, rt);
    exec_frame.var_refs = &captures;
    exec_frame.ownership.var_refs = .borrowed;

    try frame_mod.ensureVarRefsCapacity(ctx, &exec_frame, 1);
    try std.testing.expectEqual(@as(usize, 2), exec_frame.var_refs.len);
    try std.testing.expectEqual(captured, exec_frame.var_refs[0]);
    try std.testing.expectEqual(frame_mod.Ownership.owned, exec_frame.ownership.var_refs);
}

test "var-ref growth rejects an owned composite frame slab" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("frame-composite-var-ref-growth-test");
    defer rt.atoms.free(name);
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    const slab = try frame_mod.FrameSlab.allocHeap(&rt.memory, 0, 0, 0, 1, 1, 0);
    slab.stack[0] = core.JSValue.undefinedValue();
    slab.var_refs[0] = try core.VarRef.createClosed(rt, core.JSValue.int32(7));
    var exec_frame = frame_mod.Frame.init(&function);
    defer exec_frame.deinit(&rt.memory, rt);
    exec_frame.installOwnedStorage(slab.storage);
    exec_frame.var_refs = slab.var_refs;

    const storage_ptr = exec_frame.storage_values.ptr;
    const var_refs_ptr = exec_frame.var_refs.ptr;
    try std.testing.expectError(error.InvalidBytecode, frame_mod.ensureVarRefsCapacity(ctx, &exec_frame, 1));
    try std.testing.expectEqual(storage_ptr, exec_frame.storage_values.ptr);
    try std.testing.expectEqual(var_refs_ptr, exec_frame.var_refs.ptr);
}

test "local growth rejects an owned composite frame slab" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("frame-composite-local-growth-test");
    defer rt.atoms.free(name);
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    const slab = try frame_mod.FrameSlab.allocHeap(&rt.memory, 0, 0, 1, 1, 0, 0);
    slab.locals[0] = core.JSValue.int32(3);
    slab.stack[0] = core.JSValue.undefinedValue();
    var exec_frame = frame_mod.Frame.init(&function);
    defer exec_frame.deinit(&rt.memory, rt);
    exec_frame.installOwnedStorage(slab.storage);
    exec_frame.locals = slab.locals;

    const storage_ptr = exec_frame.storage_values.ptr;
    const locals_ptr = exec_frame.locals.ptr;
    try std.testing.expectError(error.InvalidBytecode, exec_frame.setLocal(&rt.memory, rt, 1, core.JSValue.int32(4)));
    try std.testing.expectEqual(storage_ptr, exec_frame.storage_values.ptr);
    try std.testing.expectEqual(locals_ptr, exec_frame.locals.ptr);
}

test "arg aliases reject missing open-ref storage without cellifying the slot" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const name = try js.runtime.internAtom("frame-arg-open-ref-capacity-test");
    defer js.runtime.atoms.free(name);
    var function = bytecode.Bytecode.init(&js.runtime.memory, &js.runtime.atoms, name);
    defer function.deinit(js.runtime);
    function.flags.has_simple_parameter_list = true;
    function.flags.has_mapped_arguments = true;
    function.arg_count = 1;
    function.open_var_ref_count = 1;
    function.arg_open_binding_indices = try js.runtime.memory.alloc(u16, 1);
    @constCast(function.arg_open_binding_indices)[0] = 0;

    var args = [_]core.JSValue{core.JSValue.int32(41)};
    var no_open_refs = [_]?*core.VarRef{};
    var exec_frame = frame_mod.Frame.init(&function);
    defer exec_frame.deinit(&js.runtime.memory, js.runtime);
    exec_frame.args = &args;
    exec_frame.actual_arg_count = args.len;
    exec_frame.open_var_refs = &no_open_refs;
    exec_frame.ownership.storage = .borrowed;

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    var rejected = false;
    if (object_ops.createArgumentsObject(js.context, global, &exec_frame, true)) |unexpected| {
        unexpected.free(js.runtime);
        args[0].free(js.runtime);
        args[0] = core.JSValue.int32(41);
    } else |err| {
        try std.testing.expectEqual(error.InvalidBytecode, err);
        rejected = true;
    }
    try std.testing.expect(rejected);
    try std.testing.expectEqual(@as(?i32, 41), args[0].asInt32());
    try std.testing.expect(core.VarRef.fromValue(args[0]) == null);

    var occupied_value = core.JSValue.int32(7);
    const occupied_ref = try core.VarRef.createOpen(js.runtime, &occupied_value);
    var full_open_refs = [_]?*core.VarRef{occupied_ref};
    exec_frame.open_var_refs = &full_open_refs;
    rejected = false;
    if (object_ops.createArgumentsObject(js.context, global, &exec_frame, true)) |unexpected| {
        unexpected.free(js.runtime);
    } else |err| {
        try std.testing.expectEqual(error.InvalidBytecode, err);
        rejected = true;
    }
    try std.testing.expect(rejected);
    try std.testing.expectEqual(@as(?i32, 41), args[0].asInt32());
    try std.testing.expect(core.VarRef.fromValue(args[0]) == null);
    try std.testing.expectEqual(occupied_ref, full_open_refs[0].?);

    const malformed_cell = try core.VarRef.createClosed(js.runtime, args[0]);
    args[0] = malformed_cell.valueRef();
    rejected = false;
    if (object_ops.createArgumentsObject(js.context, global, &exec_frame, true)) |unexpected| {
        unexpected.free(js.runtime);
    } else |err| {
        try std.testing.expectEqual(error.InvalidBytecode, err);
        rejected = true;
    }
    try std.testing.expect(rejected);
    try std.testing.expectEqual(malformed_cell, core.VarRef.fromValue(args[0]).?);
    args[0].free(js.runtime);
    args[0] = core.JSValue.int32(41);
}

test "local growth rejects moving storage after an open binding is published" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("frame-open-local-growth-test");
    defer rt.atoms.free(name);
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    var locals = [_]core.JSValue{core.JSValue.int32(7)};
    const open_ref = try core.VarRef.createOpen(rt, &locals[0]);
    var open_refs = [_]?*core.VarRef{open_ref};
    var exec_frame = frame_mod.Frame.init(&function);
    defer exec_frame.deinit(&rt.memory, rt);
    exec_frame.locals = &locals;
    exec_frame.open_var_refs = &open_refs;
    exec_frame.ownership.storage = .borrowed;

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.InvalidBytecode, exec_frame.setLocal(&rt.memory, rt, 1, core.JSValue.int32(8)));
    rt.setMemoryLimit(null);
    try exec_frame.setLocal(&rt.memory, rt, 0, core.JSValue.int32(9));
    try std.testing.expectEqual(@as(?i32, 9), open_ref.varRefValue().asInt32());
}

test "call-binding OOM leaves input references with the caller" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("frame-call-binding-oom-test");
    defer rt.atoms.free(name);
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    const held = try core.Object.create(rt, core.class.ids.object, null);
    defer held.value().free(rt);
    var exec_frame = frame_mod.Frame.init(&function);
    defer exec_frame.deinit(&rt.memory, rt);
    const initial_refs = held.header.meta().rc;

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    const result = exec_frame.initCallBindings(rt, .{
        .initial_this_value = held.value(),
        .current_function_value = held.value(),
        .new_target_value = core.JSValue.undefinedValue(),
        .constructor_this_value = held.value(),
    });
    rt.setMemoryLimit(null);

    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(initial_refs, held.header.meta().rc);
}

test "original-args cold-state OOM does not retain copied references" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("frame-original-args-oom-test");
    defer rt.atoms.free(name);
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    const held = try core.Object.create(rt, core.class.ids.object, null);
    defer held.value().free(rt);
    var source_args = [_]core.JSValue{held.value().dup()};
    defer source_args[0].free(rt);
    var original_args = [_]core.JSValue{core.JSValue.undefinedValue()};
    defer original_args[0].free(rt);
    var exec_frame = frame_mod.Frame.init(&function);
    defer exec_frame.deinit(&rt.memory, rt);
    const initial_refs = held.header.meta().rc;

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    const result = exec_frame.initArgumentsBorrowedSlots(
        &rt.memory,
        &source_args,
        false,
        true,
        .{ .original_args = &original_args },
    );
    rt.setMemoryLimit(null);

    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(initial_refs, held.header.meta().rc);
}

test "strict generator resident frame supports qjs argument counts beyond u16 storage" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function* manyArgs() {
        \\    "use strict";
        \\    return arguments.length;
        \\}
        \\assert.sameValue(manyArgs.apply(null, Array(40000)).next().value, 40000);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

pub const helpers = struct {
    /// Install the standard + host globals on a bare `core.JSRuntime` global for
    /// tests that build a runtime directly (bypassing the binding-layer context
    /// create that wires the installer). The deep setup interface keeps the
    /// installer callback and its capacity invariant together. Idempotent.
    pub fn registerStandardGlobalsBare(rt: *core.JSRuntime) void {
        engine.exec.standard_globals.configureRuntime(rt);
    }

    pub fn installHostGlobalsBare(rt: *core.JSRuntime, global: *core.Object) !void {
        const exec_call = engine.exec.call;
        registerStandardGlobalsBare(rt);
        try exec_call.installHostGlobals(rt, global);
    }

    pub fn makeFunction(rt: *core.JSRuntime, code: []const u8) !engine.bytecode.Bytecode {
        const name = try rt.internAtom("exec");
        defer rt.atoms.free(name);
        var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        errdefer function.deinit(rt);
        try setCodeAndStackSize(&function, code);
        return function;
    }

    pub fn makeUncheckedFunction(rt: *core.JSRuntime, code: []const u8) !engine.bytecode.Bytecode {
        const name = try rt.internAtom("exec");
        defer rt.atoms.free(name);
        var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        errdefer function.deinit(rt);
        try function.setCode(code);
        return function;
    }

    pub fn setCodeAndStackSize(function: *engine.bytecode.Bytecode, code: []const u8) !void {
        try function.setCode(code);
        function.stack_size = try engine.bytecode.pipeline.stack_size.compute(function.code, .{});
    }

    pub fn runFunction(rt: *core.JSRuntime, ctx: *core.JSContext, function: *const engine.bytecode.Bytecode) !core.JSValue {
        registerStandardGlobalsBare(rt);
        var vm_instance = engine.exec.Vm.init(ctx);
        defer vm_instance.deinit();
        return vm_instance.run(function);
    }

    pub fn objectFromValue(value: core.JSValue) *core.Object {
        const header = value.refHeader().?;
        return @fieldParentPtr("header", header);
    }

    pub fn expectActiveSetStrings(object: *core.Object, comptime expected: []const []const u8) !void {
        var active_index: usize = 0;
        for (object.collectionEntriesSlot().*) |entry| {
            if (!entry.active) continue;
            try std.testing.expect(active_index < expected.len);
            try expectStringValueBytes(entry.key, expected[active_index]);
            active_index += 1;
        }
        try std.testing.expectEqual(expected.len, active_index);
    }

    pub fn expectStringValueBytes(value: core.JSValue, expected: []const u8) !void {
        try std.testing.expect(value.isString());
        const string = value.asStringBody().?;
        switch (string.resolveData()) {
            .latin1 => |bytes| try std.testing.expectEqualStrings(expected, bytes),
            .utf16 => |units| {
                try std.testing.expectEqual(expected.len, units.len);
                for (expected, units) |byte, unit| {
                    try std.testing.expectEqual(@as(u16, byte), unit);
                }
            },
        }
    }

    pub var job_counter: usize = 0;

    pub fn countJob(_: *core.JSContext, _: []const core.JSValue) core.JSValue {
        job_counter += 1;
        return core.JSValue.undefinedValue();
    }

    pub fn countJobArgs(ctx: *core.JSContext, args: []const core.JSValue) core.JSValue {
        _ = ctx;
        for (args) |arg| job_counter += @intCast(arg.asInt32().?);
        return core.JSValue.int32(@intCast(args.len));
    }

    // -----------------------------------------------------------------
    // Shared test engine pattern
    // -----------------------------------------------------------------
    //
    // Each `test "X" {}` block traditionally does:
    //
    //     var js = try helpers.TestEngine.init(std.testing.allocator);
    //     defer js.deinit();
    //     ...
    //
    // That pays ~195us (Debug) / ~50us (ReleaseSafe) per test for
    // `installHostGlobals`, which dominates the per-test wall time for
    // tests whose actual eval body is small. The shared-engine pattern
    // below builds the Engine once per test BINARY (using a stable
    // allocator independent of `std.testing.allocator`, which is reset
    // between tests), and resets only the per-eval mutable state in
    // between tests:
    //
    //     const js = helpers.sharedTestEngine();
    //     defer helpers.endSharedTest();
    //     ...
    //
    // `endSharedTest` clears the pending exception slot, drains the
    // job queue, drops the global lexical environment (let / const
    // declarations from the previous test), and marks any user-added
    // global properties (`var x = ...`, `function f() {}`, ...) as
    // deleted so the next test sees a clean global beyond
    // `installHostGlobals`. Tests that mutate built-in objects (e.g.
    // `Promise.resolve = ...`) or rely on freshly built closures
    // referencing the previous test's eval scope still need a fresh
    // `helpers.TestEngine.init` per call; the shared-engine pattern is
    // safe for tests that only declare new locals / vars / functions
    // and read the standard globals.
    //
    // The shared Engine uses `std.heap.page_allocator` so the Engine's
    // internal allocations outlive any single test's
    // `std.testing.allocator_instance` (which is freshly initialized for
    // each test by the Zig test runner). Tests can still allocate their
    // own stack buffers / `std.ArrayList` instances with
    // `std.testing.allocator`; those are independent of the engine and
    // continue to be leak-checked the usual way.

    const module_graph = engine.exec.module_graph;
    const RuntimeError = engine.exec.exceptions.RuntimeError;

    const Limits = struct {
        memory_bytes: ?usize = null,
        stack_bytes: ?usize = null,
        gc_threshold_bytes: ?usize = null,
    };

    const ExceptionInfo = struct {
        value: core.JSValueHandle,

        pub fn deinit(self: *ExceptionInfo) void {
            self.value.deinit();
        }

        pub fn getMessage(self: ExceptionInfo, allocator: std.mem.Allocator) ![]const u8 {
            const rt = self.value.runtime orelse return error.InvalidEngineState;
            const value = self.value.get();
            if (value.isObject()) {
                const header = value.refHeader() orelse return error.InvalidEngineState;
                const object: *core.Object = @fieldParentPtr("header", header);

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
            try engine.exec.value_ops.appendValueString(rt, &temp_list, value);
            return try allocator.dupe(u8, temp_list.items);
        }

        pub fn getStack(self: ExceptionInfo, allocator: std.mem.Allocator) !?[]const u8 {
            const rt = self.value.runtime orelse return error.InvalidEngineState;
            const value = self.value.get();
            if (!value.isObject()) return null;
            const header = value.refHeader() orelse return null;
            const object: *core.Object = @fieldParentPtr("header", header);
            return try getPropertyString(rt, object, "stack", allocator);
        }
    };

    fn getPropertyString(rt: *core.JSRuntime, obj: *core.Object, name: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        const val = obj.getProperty(key);
        defer val.free(rt);
        if (!val.isString()) return null;

        var temp_list = std.ArrayList(u8).empty;
        defer temp_list.deinit(rt.memory.allocator);
        try engine.exec.value_ops.appendRawString(rt, &temp_list, val);
        return try allocator.dupe(u8, temp_list.items);
    }

    const EngineOptions = struct {
        allocator: std.mem.Allocator,
        trace_writer: ?*std.Io.Writer = null,
        limits: Limits = .{},
    };

    const EvalOptions = core.context.ContextEvalOptions;

    pub const TestEngine = struct {
        allocator: std.mem.Allocator,
        runtime: *core.JSRuntime,
        context: *core.JSContext,
        event_loop: *engine.runtime.EventLoop,

        pub const HostHooks = module_graph.HostHooks;

        pub fn init(allocator: std.mem.Allocator) !TestEngine {
            return initWithOptions(.{ .allocator = allocator });
        }

        pub fn initWithOptions(options: EngineOptions) !TestEngine {
            const rt = try core.JSRuntime.createWithOptions(options.allocator, .{
                .trace_writer = options.trace_writer,
                .memory_limit = options.limits.memory_bytes,
                .gc_threshold = options.limits.gc_threshold_bytes orelse core.runtime.default_gc_threshold,
                .stack_size = options.limits.stack_bytes orelse core.runtime.default_stack_size,
            });
            errdefer rt.destroy();
            registerStandardGlobalsBare(rt);
            rt.setNativeStackSize(core.runtime.default_native_stack_size * 4);
            const ctx = try core.JSContext.create(rt);
            errdefer ctx.destroy();
            const event_loop = try options.allocator.create(engine.runtime.EventLoop);
            errdefer options.allocator.destroy(event_loop);
            event_loop.* = engine.runtime.EventLoop.init(@ptrCast(ctx), .{});
            event_loop.install();
            return .{
                .allocator = options.allocator,
                .runtime = rt,
                .context = ctx,
                .event_loop = event_loop,
            };
        }

        pub fn deinit(self: *TestEngine) void {
            const wrapper: *zjs.JSContext = @ptrCast(self.context);
            wrapper.runJobs(null) catch {};
            self.event_loop.deinit();
            self.allocator.destroy(self.event_loop);
            const run_test262 = @import("../cli/run_test262.zig");
            _ = run_test262.cleanupTest262Agents(self.runtime);
            engine.exec.zjs_vm.cleanupAtomicsWaitersForContext(self.context);
            self.context.destroy();
            self.runtime.destroy();
        }

        pub fn eval(self: *TestEngine, source_text: []const u8) RuntimeError!core.JSValue {
            return self.evalMode(source_text, .script);
        }

        pub fn evalHandle(self: *TestEngine, source_text: []const u8) RuntimeError!core.JSValueHandle {
            return self.evalHandleWithOptions(source_text, .{});
        }

        pub fn evalModule(self: *TestEngine, source_text: []const u8) RuntimeError!core.JSValue {
            return self.evalMode(source_text, .module);
        }

        pub fn evalModuleHandle(self: *TestEngine, source_text: []const u8) RuntimeError!core.JSValueHandle {
            return self.evalHandleWithOptions(source_text, .{ .mode = .module });
        }

        pub fn evalMode(self: *TestEngine, source_text: []const u8, mode: core.EvalMode) RuntimeError!core.JSValue {
            return self.evalWithOptions(source_text, .{ .mode = mode });
        }

        pub fn ensureTest262GlobalsInstalled(self: *TestEngine) !void {
            if (self.context.global == null) {
                const global_obj = try engine.exec.zjs_vm.contextGlobal(self.context);
                const run_test262 = @import("../cli/run_test262.zig");
                try run_test262.installTest262Globals(self.runtime, @ptrCast(self.context), global_obj);
            }
        }

        pub fn evalWithOptions(self: *TestEngine, source_text: []const u8, options: EvalOptions) RuntimeError!core.JSValue {
            const filename = options.filename;
            const mode = options.mode;
            self.ensureTest262GlobalsInstalled() catch |err| return @errorCast(err);
            return (@as(*zjs.JSContext, @ptrCast(self.context))).eval(source_text, .{
                .mode = mode,
                .filename = filename,
                .source_kind = options.source_kind,
                .output = options.output,
                .parse_strict = options.parse_strict,
                .runtime_strict = options.runtime_strict,
                .return_completion = mode == .script and std.mem.eql(u8, filename, "<repl>"),
                .discard_script_result = mode == .script and !std.mem.eql(u8, filename, "<repl>"),
                .timing = options.timing,
            }) catch |err| return @errorCast(moduleResolutionError(err));
        }

        pub fn evalHandleWithOptions(self: *TestEngine, source_text: []const u8, options: EvalOptions) RuntimeError!core.JSValueHandle {
            const value = try self.evalWithOptions(source_text, options);
            return try core.JSValueHandle.init(self.runtime, value);
        }

        pub fn createPersistentValue(self: *TestEngine, value: core.JSValue) !core.JSValueHandle {
            return self.runtime.createPersistentValue(value);
        }

        pub fn evalWithOutput(self: *TestEngine, source_text: []const u8, output: *std.Io.Writer) RuntimeError!core.JSValue {
            return self.evalWithOptions(source_text, .{ .output = output });
        }

        pub fn evalWithOutputMode(self: *TestEngine, source_text: []const u8, output: *std.Io.Writer, mode: core.EvalMode) RuntimeError!core.JSValue {
            return self.evalWithOptions(source_text, .{ .output = output, .mode = mode, .filename = "<eval>" });
        }

        pub fn evalFileWithOutputMode(self: *TestEngine, source_text: []const u8, output: *std.Io.Writer, mode: core.EvalMode, filename: []const u8) RuntimeError!core.JSValue {
            return self.evalWithOptions(source_text, .{ .output = output, .mode = mode, .filename = filename });
        }

        pub fn evalFileWithOutputModeStrict(self: *TestEngine, source_text: []const u8, output: *std.Io.Writer, mode: core.EvalMode, filename: []const u8, strict: bool) RuntimeError!core.JSValue {
            return self.evalWithOptions(source_text, .{ .output = output, .mode = mode, .filename = filename, .parse_strict = strict, .runtime_strict = strict });
        }

        pub fn evalFileWithOutputModeRuntimeStrict(self: *TestEngine, source_text: []const u8, output: *std.Io.Writer, mode: core.EvalMode, filename: []const u8, runtime_strict: bool) RuntimeError!core.JSValue {
            return self.evalWithOptions(source_text, .{ .output = output, .mode = mode, .filename = filename, .runtime_strict = runtime_strict });
        }

        pub fn evalFileModuleGraphWithHostHooks(
            self: *TestEngine,
            source_text: []const u8,
            output: *std.Io.Writer,
            filename: []const u8,
            host_hooks: module_graph.HostHooks,
            allocator: std.mem.Allocator,
        ) !core.JSValue {
            try self.ensureTest262GlobalsInstalled();
            return module_graph.evalFileModuleGraphWithHostHooks(self.runtime, self.context, source_text, output, filename, host_hooks, allocator);
        }

        pub fn evalFileModuleGraphWithOutput(
            self: *TestEngine,
            source_text: []const u8,
            output: *std.Io.Writer,
            filename: []const u8,
            io: std.Io,
            allocator: std.mem.Allocator,
            max_source_size: usize,
        ) !core.JSValue {
            try self.ensureTest262GlobalsInstalled();
            return module_graph.evalFileModuleGraphWithOutput(self.runtime, self.context, source_text, output, filename, io, allocator, max_source_size);
        }

        pub fn runJobs(self: *TestEngine) !void {
            try (@as(*zjs.JSContext, @ptrCast(self.context))).runJobs(null);
        }

        pub fn createExternalHostFunctionValue(
            self: *TestEngine,
            name: []const u8,
            length: i32,
            ptr: *anyopaque,
            call: core.host_function.ExternalCallFn,
            finalizer: ?core.host_function.ExternalFinalizer,
        ) !core.JSValue {
            const id = try self.runtime.registerExternalHostFunction(.{
                .ptr = ptr,
                .call = call,
                .finalizer = finalizer,
            });
            const function_value = try engine.core.function.nativeFunction(self.runtime, name, length);
            errdefer function_value.free(self.runtime);

            const function_object = try engine.exec.property_ops.expectObject(function_value);
            function_object.hostFunctionKindSlot().* = core.host_function.ids.external_host;
            function_object.externalHostFunctionIdSlot().* = id;
            const global_object = try engine.exec.zjs_vm.contextGlobal(self.context);
            try function_object.setFunctionRealmGlobalPtr(self.runtime, global_object);
            return function_value;
        }

        pub fn defineGlobalExternalHostFunction(
            self: *TestEngine,
            name: []const u8,
            length: i32,
            ptr: *anyopaque,
            call: core.host_function.ExternalCallFn,
            finalizer: ?core.host_function.ExternalFinalizer,
        ) !void {
            const global_object = try engine.exec.zjs_vm.contextGlobal(self.context);
            const function_value = try self.createExternalHostFunctionValue(name, length, ptr, call, finalizer);
            defer function_value.free(self.runtime);

            const property_name = try self.runtime.internAtom(name);
            defer self.runtime.atoms.free(property_name);
            try global_object.defineOwnProperty(self.runtime, property_name, core.Descriptor.data(function_value, true, false, true));
        }

        pub fn takeException(self: *TestEngine) core.JSValue {
            return self.context.takePendingException();
        }

        pub fn takeExceptionInfo(self: *TestEngine) !ExceptionInfo {
            return .{
                .value = try core.JSValueHandle.init(self.runtime, self.takeException()),
            };
        }
    };

    fn moduleResolutionError(err: anytype) (@TypeOf(err) || error{SyntaxError}) {
        return switch (err) {
            error.MissingExport, error.AmbiguousExport => error.SyntaxError,
            else => err,
        };
    }

    var shared_engine_storage: ?TestEngine = null;
    var shared_engine_baseline_property_count: usize = 0;
    var shared_engine_baseline_shape_prop_count: usize = 0;
    var shared_engine_baseline_shape_hash: u32 = 0;
    var shared_engine_baseline_shape_deleted_count: usize = 0;
    var shared_engine_baseline_properties: ?[]core.property.Entry = null;
    var shared_engine_baseline_shape_props: ?[]core.shape.Property = null;

    pub fn sharedTestEngine() *TestEngine {
        if (shared_engine_storage == null) {
            shared_engine_storage = TestEngine.init(std.heap.page_allocator) catch unreachable;
            const eng = &shared_engine_storage.?;
            // Force the global object build (`installHostGlobals`) by
            // running an empty eval. This lets us snapshot the post-install
            // property count so subsequent `endSharedTest()` calls can
            // remove user-added globals (`var x = ...`, `function f() {}`,
            // ...) without rebuilding the entire standard-globals
            // namespace.
            const sentinel = eng.eval(";") catch unreachable;
            sentinel.free(eng.runtime);
            if (eng.context.hasException()) {
                const thrown = eng.context.takeException();
                thrown.free(eng.runtime);
            }
            if (eng.context.hasUnhandledRejection()) {
                const thrown = eng.context.takeUnhandledRejection();
                thrown.free(eng.runtime);
            }
            if (eng.context.global) |g| {
                shared_engine_baseline_property_count = g.shape_ref.prop_count;
                shared_engine_baseline_shape_prop_count = g.shape_ref.prop_count;
                shared_engine_baseline_shape_hash = g.shape_ref.hash;
                shared_engine_baseline_shape_deleted_count = g.shape_ref.deleted_prop_count;

                // Snapshot the baseline property entries (value slots only;
                // key atoms and flags are snapshotted with the shape props
                // below).
                shared_engine_baseline_properties = std.heap.page_allocator.alloc(core.property.Entry, g.shape_ref.prop_count) catch unreachable;
                for (g.propertyEntries(), 0..) |entry, idx| {
                    // Dup the slot using its kind (read from the shape flags); the
                    // value cell is untagged so dup/destroy need the flags.
                    shared_engine_baseline_properties.?[idx] = .{ .slot = entry.slot.dup(g.propFlagsAt(idx)) };
                }

                shared_engine_baseline_shape_props = std.heap.page_allocator.alloc(core.shape.Property, g.shape_ref.prop_count) catch unreachable;
                for (g.shape_ref.props()[0..g.shape_ref.prop_count], 0..) |prop, idx| {
                    shared_engine_baseline_shape_props.?[idx] = prop;
                    shared_engine_baseline_shape_props.?[idx].hash_next = core.shape.no_property_index;
                    if (prop.atom_id != core.atom.null_atom) {
                        _ = eng.runtime.atoms.dup(prop.atom_id);
                    }
                }
            }
        }
        return &shared_engine_storage.?;
    }

    pub fn endSharedTest() void {
        const eng = if (shared_engine_storage) |*e| e else return;
        // Clear any exception still sitting on the context from a test
        // that returned via `try` without explicitly taking it.
        if (eng.context.hasException()) {
            const thrown = eng.context.takeException();
            thrown.free(eng.runtime);
        }
        if (eng.context.hasUnhandledRejection()) {
            const thrown = eng.context.takeUnhandledRejection();
            thrown.free(eng.runtime);
        }
        // Drain pending jobs so the next test starts with an empty queue;
        // tests that schedule a promise via `Promise.resolve(...)` and
        // return without awaiting would otherwise leak the job into the
        // next test.
        eng.runtime.job_queue.runAll();
        if (eng.context.hasException()) {
            const thrown = eng.context.takeException();
            thrown.free(eng.runtime);
        }
        if (eng.context.hasUnhandledRejection()) {
            const thrown = eng.context.takeUnhandledRejection();
            thrown.free(eng.runtime);
        }
        engine.exec.zjs_vm.cleanupAtomicsWaitersForContext(eng.context);
        if (eng.context.global) |global| {
            // Reset global lexical bindings (let / const) so the next
            // test can re-declare any name without triggering a
            // redeclaration SyntaxError.
            if (eng.context.lexicals) |env| {
                eng.context.lexicals = null;
                env.value().free(eng.runtime);
            }
            // Suppress allocation-triggered GC for the whole property restore.
            // Restoring slots and shape flags is a multi-step swap that passes
            // through transient states where a slot's arm and the live shape's
            // `Flags.kind` disagree (e.g. a materialized `.data` slot while the
            // baseline flags being restored say `.auto_init`). Under
            // `-Dzjs_force_gc=true` the `restorePropertyLayout` storage alloc
            // would otherwise run the cycle collector against that half-applied
            // state and trace the wrong union arm. Making the restore atomic
            // w.r.t. GC keeps the slot/flag pair consistent throughout.
            const saved_trigger_fn = eng.runtime.memory.trigger_gc_fn;
            const saved_trigger_ctx = eng.runtime.memory.trigger_gc_ctx;
            eng.runtime.memory.trigger_gc_fn = null;
            eng.runtime.memory.trigger_gc_ctx = null;
            defer {
                eng.runtime.memory.trigger_gc_fn = saved_trigger_fn;
                eng.runtime.memory.trigger_gc_ctx = saved_trigger_ctx;
            }

            // Remove any user-added properties (`var x = ...`,
            // `function f()`, ...) so the next test sees a clean global.
            // Standard globals (`Object`, `Array`, ...) and host helpers
            // (`print`, ...) installed by `installHostGlobals` live at
            // indices below `shared_engine_baseline_property_count` and
            // are kept.
            const baseline = shared_engine_baseline_property_count;
            if (global.shape_ref.prop_count > baseline) {
                for (global.propertyEntries()[baseline..], baseline..) |*entry, idx| {
                    // Untagged value cell: destroy needs the kind (current shape
                    // flags are still valid; restorePropertyLayout runs below).
                    entry.slot.destroy(global.propFlagsAt(idx), eng.runtime);
                    // `deleted` is a flag, not a slot arm: leave a harmless cell.
                    entry.slot = .{ .data = core.JSValue.undefinedValue() };
                }
                // Count shrink to baseline is handled by restorePropertyLayout
                // below (the per-object count now lives in shape.prop_count).
            }

            // Restore baseline properties below baseline to their original states
            if (shared_engine_baseline_properties) |baselines| {
                // First, destroy current values below baseline using the CURRENT
                // shape flags (the layout has not been restored yet).
                for (global.propertyEntries()[0..baseline], 0..) |entry, idx| {
                    entry.slot.destroy(global.propFlagsAt(idx), eng.runtime);
                }
                // Second, restore baseline values, dupping with the BASELINE
                // flags snapshotted alongside the baseline slots (1:1 by index).
                const baseline_shape_props = shared_engine_baseline_shape_props.?;
                for (baselines, 0..) |base, idx| {
                    const base_flags = core.property.Flags.fromBits(baseline_shape_props[idx].flags);
                    global.prop_values[idx] = .{ .slot = base.slot.dup(base_flags) };
                }
            }

            if (shared_engine_baseline_shape_props) |baseline_shape_props| {
                eng.runtime.shapes.restorePropertyLayout(
                    &global.shape_ref,
                    baseline_shape_props[0..shared_engine_baseline_shape_prop_count],
                    shared_engine_baseline_shape_hash,
                    shared_engine_baseline_shape_deleted_count,
                ) catch unreachable;
            }
        }
    }
};

pub const vm_helpers = struct {
    pub fn parseAndRun(rt: *core.JSRuntime, ctx: *core.JSContext, src: []const u8) !core.JSValue {
        const name = try rt.internAtom("test");
        defer rt.atoms.free(name);
        var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer function.deinit(rt);

        var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, src);
        var state = try ParseState.init(&lex, &function);
        defer state.deinit(rt);
        try parser_core.parseExpr(&state);

        // Run the FunctionDef-backed finalize pipeline so locals are lowered
        // to get_loc / put_loc instead of falling back to global get_var /
        // put_var.
        try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);

        helpers.registerStandardGlobalsBare(rt);
        var vm = engine.exec.Vm.init(ctx);
        defer vm.deinit();
        return vm.run(&function);
    }

    pub fn parseAndRunWithTopLevelChildren(rt: *core.JSRuntime, ctx: *core.JSContext, src: []const u8) !core.JSValue {
        const name = try rt.internAtom("test");
        defer rt.atoms.free(name);
        var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer function.deinit(rt);

        var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, src);
        var state = try ParseState.init(&lex, &function);
        defer state.deinit(rt);
        state.top_level_functions_as_children = true;
        try parser_core.parseExpr(&state);

        try engine.bytecode.pipeline.finalize.runWithFunctionDefRuntime(&function, &state.function_def, rt);

        helpers.registerStandardGlobalsBare(rt);
        var vm = engine.exec.Vm.init(ctx);
        defer vm.deinit();
        return vm.run(&function);
    }

    pub fn expectStringBytes(value: core.JSValue, expected: []const u8) !void {
        try std.testing.expect(value.isString());
        const string_value = value.asStringBody().?;
        try std.testing.expect(string_value.eqlBytes(expected));
    }

    pub fn expectSingleCodeUnit(value: core.JSValue, expected: u16) !void {
        try std.testing.expect(value.isString());
        const string_value = value.asStringBody().?;
        try std.testing.expectEqual(@as(usize, 1), string_value.len());
        try std.testing.expectEqual(expected, string_value.codeUnitAt(0));
    }

    pub fn parseStmtAndRun(rt: *core.JSRuntime, ctx: *core.JSContext, src: []const u8) !core.JSValue {
        const name = try rt.internAtom("test");
        defer rt.atoms.free(name);
        var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer function.deinit(rt);

        var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, src);
        var state = try ParseState.init(&lex, &function);
        defer state.deinit(rt);

        try state.enableEvalReturn();
        while (state.token.val != engine.parser.token.TOK_EOF) {
            try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });
        }
        try state.finalizeEvalReturn();

        try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);

        helpers.registerStandardGlobalsBare(rt);
        var vm = engine.exec.Vm.init(ctx);
        defer vm.deinit();
        return vm.run(&function);
    }

    pub fn parseStmtAndRunWithTopLevelChildren(rt: *core.JSRuntime, ctx: *core.JSContext, src: []const u8) !core.JSValue {
        const name = try rt.internAtom("test");
        defer rt.atoms.free(name);
        var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer function.deinit(rt);

        var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, src);
        var state = try ParseState.init(&lex, &function);
        defer state.deinit(rt);
        state.top_level_functions_as_children = true;

        try state.enableEvalReturn();
        while (state.token.val != engine.parser.token.TOK_EOF) {
            try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });
        }
        try state.finalizeEvalReturn();

        try engine.bytecode.pipeline.finalize.runWithFunctionDefRuntime(&function, &state.function_def, rt);

        helpers.registerStandardGlobalsBare(rt);
        var vm = engine.exec.Vm.init(ctx);
        defer vm.deinit();
        return vm.run(&function);
    }
};

// ================== core_native.zig ==================

test "vm executes push constants arithmetic comparisons and return" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var function = try makeFunction(rt, &.{
        op.push_i32, 2,           0, 0, 0,
        op.push_i32, 3,           0, 0, 0,
        op.add,      op.push_i32, 6, 0, 0,
        0,           op.lt,
    });
    defer function.deinit(rt);

    const result = try runFunction(rt, ctx, &function);
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "vm executes stack constants source locations and return_undef" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var function = try makeFunction(rt, &.{
        op.undefined, op.null, op.push_true, op.push_false, op.drop, op.return_undef,
    });
    defer function.deinit(rt);

    const result = try runFunction(rt, ctx, &function);
    defer result.free(rt);
    try std.testing.expect(result.isUndefined());
    try std.testing.expect(result.isUndefined());
}

test "frame setLocal handles self-assignment without dropping object" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    defer function.deinit(rt);
    var frame = engine.exec.frame.Frame.init(&function);
    defer frame.deinit(&rt.memory, rt);

    const object = try core.Object.create(rt, core.class.ids.object, null);
    try frame.setLocal(&rt.memory, rt, 0, object.value());
    object.value().free(rt);

    try std.testing.expectEqual(@as(i32, 1), object.header.meta().rc);
    const current = frame.locals[0];
    try frame.setLocal(&rt.memory, rt, 0, current);

    try std.testing.expectEqual(@as(i32, 1), object.header.meta().rc);
    try std.testing.expectEqual(&object.header, frame.locals[0].refHeader().?);
}

test "lookupFrameVarRef tolerates synthetic var-ref name mirrors" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);

    const binding_name = try rt.internAtom("synthetic-var-ref");
    defer rt.atoms.free(binding_name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    defer function.deinit(rt);
    function.var_ref_names = try rt.memory.alloc(core.Atom, 1);
    function.var_ref_names[0] = rt.atoms.dup(binding_name);

    const cell = try core.VarRef.createClosed(rt, core.JSValue.uninitialized());
    var var_refs = [_]*core.VarRef{cell};
    var frame = engine.exec.frame.Frame.init(&function);
    frame.var_refs = &var_refs;
    defer frame.deinit(&rt.memory, rt);

    const result = engine.exec.call_runtime.lookupFrameVarRef(ctx, global, &function, &frame, binding_name);
    defer if (result) |value| value.free(rt);
    try std.testing.expect(result == null);
}

test "VM roots frame this symbol before derived constructor var-ref allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try engine.exec.zjs_vm.contextGlobal(ctx);

    const this_name = try rt.internAtom("this");
    defer rt.atoms.free(this_name);

    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    defer function.deinit(rt);
    function.flags.is_derived_class_constructor = true;
    function.var_count = 1;
    function.stack_size = 1;
    function.vardefs = try rt.memory.alloc(function_def.VarDef, 1);
    function.vardefs[0] = .{
        .var_name = rt.atoms.dup(this_name),
        .scope_level = 0,
        .is_captured = true,
        .open_binding_idx = 0,
    };
    function.open_var_ref_count = 1;
    try helpers.setCodeAndStackSize(&function, &.{ op.get_loc0, op.drop, op.return_undef });

    const this_symbol = try rt.atoms.newValueSymbol("gc-vm-frame-this-before-roots");
    rt.setGCThreshold(0);

    var stack = engine.exec.stack.Stack.init(&rt.memory, rt.stackSize());
    defer stack.deinit(rt);

    const result = try engine.exec.zjs_vm.runWithCallEnv(.{
        .ctx = ctx,
        .stack = &stack,
        .function = &function,
        .initial_this_value = try rt.symbolValue(this_symbol),
        .global = global,
    });
    defer result.free(rt);

    try std.testing.expectEqual(this_symbol, result.asSymbolAtom().?);
    try std.testing.expect(rt.atoms.name(this_symbol) != null);
}

test "derived constructor arrow and direct eval observe the same this value" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [32]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\new class extends class {} {
        \\  constructor() {
        \\    super();
        \\    print(this === (() => this)(), this === eval("this"));
        \\  }
        \\}();
    , &output);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true true\n", output.buffered());
}

test "derived constructor direct eval this shortcut preserves TDZ" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [96]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\new class extends Object {
        \\  constructor() {
        \\    let shortcut = "no", full = "no";
        \\    try { eval("this"); } catch (error) { shortcut = error.name; }
        \\    try { eval("this;"); } catch (error) { full = error.name; }
        \\    print(shortcut, full);
        \\    super();
        \\  }
        \\}();
    , &output);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("ReferenceError ReferenceError\n", output.buffered());
}

test "bound function call skips zero-length combined args allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const target = try engine.exec.closure.create(rt, 13, 0, 0, 0);
    defer target.free(rt);
    const bound = try core.Object.create(rt, core.class.ids.bound_function, null);
    defer bound.value().free(rt);
    bound.boundTargetSlot().* = target.dup();
    bound.boundThisSlot().* = core.JSValue.undefinedValue();

    const base_bytes = rt.memory.allocated_bytes;
    const base_allocations = rt.memory.allocation_count;

    const result = try engine.exec.call.callValue(ctx, null, bound.value(), &.{});
    defer result.free(rt);
    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqual(base_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(base_allocations, rt.memory.allocation_count);
}

test "constant pool execution retains returned constants" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("const-return");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    const str = try core.string.String.createAscii(rt, "hello");
    const value = str.value();
    _ = try function.addConstant(value);
    value.free(rt);
    try helpers.setCodeAndStackSize(&function, &.{ op.push_const, 0, 0, 0, 0 });

    const result = try runFunction(rt, ctx, &function);
    defer result.free(rt);
    try std.testing.expect(result.isString());
}

test "property ops use shared object semantics" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const obj = try core.Object.create(rt, core.class.ids.object, null);
    defer obj.value().free(rt);
    const key = try rt.internAtom("x");
    defer rt.atoms.free(key);

    try engine.exec.property_ops.defineDataProperty(rt, obj, key, core.JSValue.int32(9));
    try engine.exec.property_ops.setProperty(rt, obj, key, core.JSValue.int32(10));
    const value = engine.exec.property_ops.getProperty(obj, key);
    try std.testing.expectEqual(@as(?i32, 10), value.asInt32());

    const direct_value = try engine.exec.property_ops.getPropertyValue(rt, obj.value(), key);
    defer direct_value.free(rt);
    try std.testing.expectEqual(@as(?i32, 10), direct_value.asInt32());

    const key_string_obj = try core.string.String.createUtf8(rt, "x");
    const key_string = key_string_obj.value();
    defer key_string.free(rt);
    const in_result = try engine.exec.property_ops.propertyIn(rt, obj.value(), key_string);
    try std.testing.expectEqual(true, in_result.asBool().?);

    const optional_result = try engine.exec.property_ops.optionalGetPropertyValue(rt, core.JSValue.nullValue(), key);
    try std.testing.expect(optional_result.isUndefined());

    try std.testing.expect(engine.exec.property_ops.deleteProperty(rt, obj, key));
}

test "value ops own primitive VM semantics" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const sum = try engine.exec.value_ops.binary(rt, op.add, core.JSValue.int32(2), core.JSValue.int32(3));
    defer sum.free(rt);
    try std.testing.expectEqual(@as(?i32, 5), sum.asInt32());

    const suffix_obj = try core.string.String.createUtf8(rt, "px");
    const suffix = suffix_obj.value();
    defer suffix.free(rt);
    const joined = try engine.exec.value_ops.binary(rt, op.add, core.JSValue.int32(2), suffix);
    defer joined.free(rt);

    var joined_text = std.ArrayList(u8).empty;
    defer joined_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &joined_text, joined);
    try std.testing.expectEqualStrings("2px", joined_text.items);

    const int_string = try engine.exec.value_ops.toStringValue(rt, core.JSValue.int32(7));
    defer int_string.free(rt);
    var int_string_text = std.ArrayList(u8).empty;
    defer int_string_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &int_string_text, int_string);
    try std.testing.expectEqualStrings("7", int_string_text.items);

    const empty_obj = try core.string.String.createUtf8(rt, "");
    const empty = empty_obj.value();
    defer empty.free(rt);

    const empty_suffix = try engine.exec.value_ops.binary(rt, op.add, empty, core.JSValue.int32(7));
    defer empty_suffix.free(rt);
    var empty_suffix_text = std.ArrayList(u8).empty;
    defer empty_suffix_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &empty_suffix_text, empty_suffix);
    try std.testing.expectEqualStrings("7", empty_suffix_text.items);

    const empty_prefix = try engine.exec.value_ops.binary(rt, op.add, core.JSValue.int32(7), empty);
    defer empty_prefix.free(rt);
    var empty_prefix_text = std.ArrayList(u8).empty;
    defer empty_prefix_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &empty_prefix_text, empty_prefix);
    try std.testing.expectEqualStrings("7", empty_prefix_text.items);

    const one_obj = try core.string.String.createUtf8(rt, "1");
    const one_string = one_obj.value();
    defer one_string.free(rt);

    const same_string = try engine.exec.value_ops.toStringValue(rt, one_string);
    defer same_string.free(rt);
    try std.testing.expect(same_string.same(one_string));

    const boxed_one = try engine.exec.string_builtin_ops.constructWithPrototype(rt, &.{one_string}, null);
    defer boxed_one.free(rt);
    const boxed_one_object: *core.Object = @fieldParentPtr("header", boxed_one.refHeader().?);
    const boxed_one_data = boxed_one_object.objectData() orelse return error.TypeError;
    try std.testing.expect(boxed_one_data.same(one_string));

    const symbol_atom = try rt.atoms.newSymbol("boxed", .symbol);
    defer rt.atoms.free(symbol_atom);
    try std.testing.expectError(error.TypeError, engine.exec.string_builtin_ops.constructWithPrototype(rt, &.{try rt.symbolValue(symbol_atom)}, null));

    const name = try rt.internAtom("loose-eq");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    _ = try function.addConstant(one_string);
    try helpers.setCodeAndStackSize(&function, &.{
        op.push_i32,   1, 0, 0, 0,
        op.push_const, 0, 0, 0, 0,
        op.eq,
    });
    const eq_result = try runFunction(rt, ctx, &function);
    defer eq_result.free(rt);
    try std.testing.expectEqual(true, eq_result.asBool().?);

    try std.testing.expectEqual(false, engine.exec.value_ops.toBooleanValue(core.JSValue.int32(0)).asBool().?);
}

test "closure helper stores closure state outside the VM" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const closure_value = try engine.exec.closure.create(rt, 2, 0, 0, 0);
    defer closure_value.free(rt);
    const first = try engine.exec.closure.call(rt, closure_value, &.{}, &.{});
    defer first.free(rt);
    const second = try engine.exec.closure.call(rt, closure_value, &.{}, &.{});
    defer second.free(rt);

    try std.testing.expectEqual(@as(?i32, 1), first.asInt32());
    try std.testing.expectEqual(@as(?i32, 2), second.asInt32());
}

test "M1.3: returned closure can update and return captured counter" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try vm_helpers.parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  function counter() {
        \\    let n = 0;
        \\    return function next() { n++; return n; };
        \\  }
        \\  var next = counter();
        \\  return next() * 100 + next() * 10 + next();
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 123), result.asInt32().?);
}

test "checked local replacement preserves int fast moves and refcounted fallbacks" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try vm_helpers.parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function () {
        \\  let value = 1;
        \\  value = 2;
        \\  value = "left";
        \\  value = "right";
        \\  value = 3;
        \\  return value;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(?i32, 3), result.asInt32());
}

test "a bytecode call at logical end completes through function falloff" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    // This script's outer bytecode ends with the ordinary call. The return from
    // `identity` therefore resumes at code_end and must take the dispatcher's
    // falloff path; there is no real continuation opcode to dispatch directly.
    const result = try vm_helpers.parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function identity(value) { return value; })(42)
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(?i32, 42), result.asInt32());
}

test "TDZ: closure update and return of captured const throws TypeError" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    try std.testing.expectError(error.TypeError, vm_helpers.parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\const k = 11;
        \\function f() { k++; return k; }
        \\f();
    ));
}

test "forward-ref top-level lexical captured through a nested closure resolves after init" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    // `mk` is declared textually before `const G`, and only the inner closure
    // names G. The forward-capture retrofit must thread a closure-var chain
    // through `mk` (which never names G itself) down to the inner function;
    // otherwise the reference falls back to a global lookup and reads
    // undefined. Mirrors QuickJS, which resolves the whole tree post-parse.
    const result = try vm_helpers.parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\function mk() { return function inner() { return G; }; }
        \\const G = 42;
        \\mk()();
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "forward-ref lexical captured through nested closure still honors TDZ before init" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    // The retrofitted chain must capture the binding's cell (not a snapshot):
    // calling the closure before `const G` is initialized throws ReferenceError
    // (TDZ), and the same closure reads 42 once initialized. Result encodes
    // 2 = ReferenceError thrown pre-init.
    const result = try vm_helpers.parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\function mk() { return function inner() { return G; }; }
        \\const early = mk();
        \\let code = 0;
        \\try { early(); code = 1; } catch (e) { code = (e instanceof ReferenceError) ? 2 : 3; }
        \\const G = 42;
        \\code;
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 2), result.asInt32().?);
}

test "global closure get before top-level lexical initialization honors TDZ" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var let_output_buffer: [64]u8 = undefined;
    var let_output = std.Io.Writer.fixed(&let_output_buffer);
    const let_result = try js.evalWithOutput(
        \\function f() { return x + 1; }
        \\try { f(); print("no"); } catch (e) { print(e.name); }
        \\let x;
    , &let_output);
    defer let_result.free(js.runtime);
    try std.testing.expect(let_result.isUndefined());
    try std.testing.expectEqualStrings("ReferenceError\n", let_output.buffered());

    var const_output_buffer: [64]u8 = undefined;
    var const_output = std.Io.Writer.fixed(&const_output_buffer);
    const const_result = try js.evalWithOutput(
        \\function f() { return y + 1; }
        \\try { f(); print("no"); } catch (e) { print(e.name); }
        \\const y = 1;
    , &const_output);
    defer const_result.free(js.runtime);
    try std.testing.expect(const_result.isUndefined());
    try std.testing.expectEqualStrings("ReferenceError\n", const_output.buffered());
}

test "global closure set before top-level lexical initialization honors TDZ" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function f() { x = 1; }
        \\try { f(); print("no"); } catch (e) { print(e.name); }
        \\let x;
    , &output);
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("ReferenceError\n", output.buffered());
}

test "global closure update before top-level lexical initialization honors TDZ" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function f() { x++; }
        \\try { f(); print("no"); } catch (e) { print(e.name); }
        \\let x;
    , &output);
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("ReferenceError\n", output.buffered());
}

test "Annex B block function updates existing global function binding" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\{
        \\  function f() { return "inner declaration"; }
        \\}
        \\function f() {
        \\  return "outer declaration";
        \\}
        \\print(f());
    , &output);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("inner declaration\n", output.buffered());
}

test "Annex B eval block function updates global function binding mirrors" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var direct_output_buffer: [64]u8 = undefined;
    var direct_output = std.Io.Writer.fixed(&direct_output_buffer);
    const direct_result = try js.evalWithOutput(
        \\{
        \\  function f() { return "first declaration"; }
        \\}
        \\eval('{ function f() { return "second declaration"; } }');
        \\print(f());
    , &direct_output);
    defer direct_result.free(js.runtime);
    try std.testing.expect(direct_result.isUndefined());
    try std.testing.expectEqualStrings("second declaration\n", direct_output.buffered());

    var indirect_output_buffer: [64]u8 = undefined;
    var indirect_output = std.Io.Writer.fixed(&indirect_output_buffer);
    const indirect_result = try js.evalWithOutput(
        \\(0, eval)('{ function g() { return "inner declaration"; } } print(g()); function g() { return "outer declaration"; }');
    , &indirect_output);
    defer indirect_result.free(js.runtime);
    try std.testing.expect(indirect_result.isUndefined());
    try std.testing.expectEqualStrings("inner declaration\n", indirect_output.buffered());
}

test "Annex B direct eval global function does not block later script lexical declaration" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const eval_result = try js.eval(
        \\eval('if (true) { function test262Fn() {} }');
    );
    defer eval_result.free(js.runtime);
    try std.testing.expect(eval_result.isUndefined());

    const lexical_result = try js.eval(
        \\let test262Fn = 1;
    );
    defer lexical_result.free(js.runtime);
    try std.testing.expect(lexical_result.isUndefined());

    var output_buffer: [16]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const read_result = try js.evalWithOutput(
        \\print(test262Fn);
    , &output);
    defer read_result.free(js.runtime);
    try std.testing.expect(read_result.isUndefined());
    try std.testing.expectEqualStrings("1\n", output.buffered());
}

test "sloppy global assignment creates deletable object property" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var this_output_buffer: [64]u8 = undefined;
    var this_output = std.Io.Writer.fixed(&this_output_buffer);
    const this_result = try js.evalWithOutput(
        \\x = 1;
        \\print(delete this.x);
        \\print(Object.prototype.hasOwnProperty.call(this, "x"));
    , &this_output);
    defer this_result.free(js.runtime);
    try std.testing.expect(this_result.isUndefined());
    try std.testing.expectEqualStrings("true\nfalse\n", this_output.buffered());

    var global_output_buffer: [64]u8 = undefined;
    var global_output = std.Io.Writer.fixed(&global_output_buffer);
    const global_result = try js.evalWithOutput(
        \\y = 1;
        \\print(delete globalThis.y);
        \\print(Object.prototype.hasOwnProperty.call(globalThis, "y"));
    , &global_output);
    defer global_result.free(js.runtime);
    try std.testing.expect(global_result.isUndefined());
    try std.testing.expectEqualStrings("true\nfalse\n", global_output.buffered());
}

test "forward-ref top-level lexical threads through three closure levels" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    // Two intermediate functions, neither naming G, must each receive a
    // propagated closure-var link so the innermost arrow resolves G.
    const result = try vm_helpers.parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\function a() { return function b() { return () => G; }; }
        \\const G = 7;
        \\a()()();
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 7), result.asInt32().?);
}

test "top-level function declarations use wide closure operands past 255 constants" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var source = std.ArrayList(u8).empty;
    defer source.deinit(std.testing.allocator);
    for (0..260) |index| {
        var line_buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "function f{d}() {{ return {d}; }}\n", .{ index, index });
        try source.appendSlice(std.testing.allocator, line);
    }
    try source.appendSlice(std.testing.allocator, "f259();");

    const result = try vm_helpers.parseStmtAndRunWithTopLevelChildren(rt, ctx, source.items);
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 259), result.asInt32().?);
}

test "test262 helpers own SameValue assertions" {
    const run_test262 = @import("../cli/run_test262.zig");
    const same_nan = try run_test262.assertSameValue(core.JSValue.float64(std.math.nan(f64)), core.JSValue.float64(std.math.nan(f64)));
    try std.testing.expect(same_nan.isUndefined());
    try std.testing.expectError(error.JSException, run_test262.assertSameValue(core.JSValue.int32(1), core.JSValue.int32(2)));
}

test "call subsystem installs and invokes host globals" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);
    const run_test262 = @import("../cli/run_test262.zig");
    try run_test262.installTest262Globals(rt, @ptrCast(ctx), global);

    const print_key = try rt.internAtom("print");
    defer rt.atoms.free(print_key);
    const print = global.getProperty(print_key);
    defer print.free(rt);
    const print_object: *core.Object = @fieldParentPtr("header", print.refHeader().?);
    const host_function_key = try rt.internAtom("__host_function");
    defer rt.atoms.free(host_function_key);
    try std.testing.expect(print_object.getOwnProperty(rt, host_function_key) == null);
    try std.testing.expectEqual(core.host_function.ids.external_host, print_object.hostFunctionKindSlot().*);
    try std.testing.expect(print_object.externalHostFunctionId() != 0);

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const args = [_]core.JSValue{ core.JSValue.int32(1), core.JSValue.boolean(true) };
    const result = try engine.exec.call.callValue(ctx, &stream, print, &args);
    defer result.free(rt);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1 true\n", stream.buffered());

    const console_key = try rt.internAtom("console");
    defer rt.atoms.free(console_key);
    const log_key = try rt.internAtom("log");
    defer rt.atoms.free(log_key);
    const console_value = global.getProperty(console_key);
    defer console_value.free(rt);
    const console_object: *core.Object = @fieldParentPtr("header", console_value.refHeader().?);
    const log = console_object.getProperty(log_key);
    defer log.free(rt);
    const log_object: *core.Object = @fieldParentPtr("header", log.refHeader().?);
    try std.testing.expectEqual(core.host_function.ids.external_host, log_object.hostFunctionKindSlot().*);
    try std.testing.expectEqual(print_object.externalHostFunctionId(), log_object.externalHostFunctionId());

    const log_args = [_]core.JSValue{ core.JSValue.int32(2), core.JSValue.boolean(false) };
    const log_result = try engine.exec.call.callValue(ctx, &stream, log, &log_args);
    defer log_result.free(rt);
    try std.testing.expect(log_result.isUndefined());
    try std.testing.expectEqualStrings("1 true\n2 false\n", stream.buffered());

    const assert_key = try rt.internAtom("assert");
    defer rt.atoms.free(assert_key);
    const same_value_key = try rt.internAtom("sameValue");
    defer rt.atoms.free(same_value_key);
    const assert_object_value = global.getProperty(assert_key);
    defer assert_object_value.free(rt);
    const assert_object_header = assert_object_value.refHeader().?;
    const assert_object: *core.Object = @fieldParentPtr("header", assert_object_header);
    const same_value = assert_object.getProperty(same_value_key);
    defer same_value.free(rt);

    const same_args = [_]core.JSValue{ core.JSValue.float64(std.math.nan(f64)), core.JSValue.float64(std.math.nan(f64)) };
    const same_result = try engine.exec.call.callValue(ctx, null, same_value, &same_args);
    defer same_result.free(rt);
    try std.testing.expect(same_result.isUndefined());
    const mismatch_args = [_]core.JSValue{ core.JSValue.int32(1), core.JSValue.int32(2) };
    try std.testing.expectError(error.JSException, engine.exec.call.callValue(ctx, null, same_value, &mismatch_args));

    const test262_key = try rt.internAtom("Test262Error");
    defer rt.atoms.free(test262_key);
    const test262_ctor = global.getProperty(test262_key);
    defer test262_ctor.free(rt);
    const test262_error = try engine.exec.call.callValue(ctx, null, test262_ctor, &.{});
    defer test262_error.free(rt);
    try std.testing.expect(test262_error.isObject());

    const map_value = try engine.exec.collection_ops.construct(rt, 1);
    defer map_value.free(rt);
    const map_object: *core.Object = @fieldParentPtr("header", map_value.refHeader().?);
    const set_key = try rt.internAtom("set");
    defer rt.atoms.free(set_key);
    const get_key = try rt.internAtom("get");
    defer rt.atoms.free(get_key);
    const map_set = map_object.getProperty(set_key);
    defer map_set.free(rt);
    const map_get = map_object.getProperty(get_key);
    defer map_get.free(rt);
    const stored_key_obj = try core.string.String.createUtf8(rt, "key");
    const stored_key = stored_key_obj.value();
    defer stored_key.free(rt);
    const stored_value_obj = try core.string.String.createUtf8(rt, "value");
    const stored_value = stored_value_obj.value();
    defer stored_value.free(rt);
    const set_args = [_]core.JSValue{ stored_key, stored_value };
    const set_result = try engine.exec.call.callValueWithThis(ctx, null, map_value, map_set, &set_args);
    defer set_result.free(rt);
    try std.testing.expect(set_result.same(map_value));
    try std.testing.expectError(error.TypeError, engine.exec.call.callValue(ctx, null, map_set, &set_args));
    const get_result = try engine.exec.call.callValueWithThis(ctx, null, map_value, map_get, &.{stored_key});
    defer get_result.free(rt);
    var get_text = std.ArrayList(u8).empty;
    defer get_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &get_text, get_result);
    try std.testing.expectEqualStrings("value", get_text.items);
}

test "native builtin record dispatch is independent from dispatch-name strings" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const math_key = try rt.internAtom("Math");
    defer rt.atoms.free(math_key);
    const abs_key = try rt.internAtom("abs");
    defer rt.atoms.free(abs_key);
    const math_value = global.getProperty(math_key);
    defer math_value.free(rt);
    const math_object: *core.Object = @fieldParentPtr("header", math_value.refHeader().?);
    const abs_value = math_object.getProperty(abs_key);
    defer abs_value.free(rt);
    const abs_object: *core.Object = @fieldParentPtr("header", abs_value.refHeader().?);
    try std.testing.expect(abs_object.nativeFunctionIdSlot().* != 0);
    const abs_record = abs_object.nativeRecord() orelse return error.InvalidBuiltinRegistry;
    try std.testing.expectEqual(core.host_function.NativeCProto.f_f, abs_record.cproto);
    try std.testing.expect(abs_record.native_function != null);

    const atan2_key = try rt.internAtom("atan2");
    defer rt.atoms.free(atan2_key);
    const atan2_value = math_object.getProperty(atan2_key);
    defer atan2_value.free(rt);
    const atan2_object: *core.Object = @fieldParentPtr("header", atan2_value.refHeader().?);
    const atan2_record = atan2_object.nativeRecord() orelse return error.InvalidBuiltinRegistry;
    try std.testing.expectEqual(core.host_function.NativeCProto.f_f_f, atan2_record.cproto);
    try std.testing.expect(atan2_record.native_function != null);

    const fake = try engine.core.function.nativeFunction(rt, "notMathAbs", 1);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = abs_object.nativeFunctionIdSlot().*;

    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notMathAbs", dispatch_name);

    const args = [_]core.JSValue{core.JSValue.int32(-8)};
    const result = try engine.exec.call.callValue(ctx, null, fake, &args);
    defer result.free(rt);
    try std.testing.expectEqual(@as(f64, 8.0), engine.exec.value_ops.numberValue(result).?);

    // Plain op_call must prefer the resolved record memo. The encoded id is a
    // bootstrap key, not work to repeat after the function object is bound.
    fake_object.nativeRecordSlot().* = abs_record;
    fake_object.nativeFunctionIdSlot().* = 0;
    const memo_result = try engine.exec.call.callValue(ctx, null, fake, &args);
    defer memo_result.free(rt);
    try std.testing.expectEqual(@as(f64, 8.0), engine.exec.value_ops.numberValue(memo_result).?);

    const fake_key = try rt.internAtom("fake");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.parser.compile(rt, "print(fake(-8));", .{ .mode = .script, .filename = "native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [16]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("8\n", output.buffered());
}

test "bytecode call view memo is shared by the function bytecode" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function memoizedBytecodeView(value) {
        \\    return value + 1;
        \\}
        \\assert.sameValue(memoizedBytecodeView(1), 2);
        \\assert.sameValue(memoizedBytecodeView(2), 3);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    const global = js.context.global.?;
    const name = try js.runtime.internAtom("memoizedBytecodeView");
    defer js.runtime.atoms.free(name);
    const function_value = global.getProperty(name);
    defer function_value.free(js.runtime);
    const function_object = engine.exec.object_ops.functionObjectFromValue(function_value) orelse
        return error.InvalidFunctionBytecode;
    const fb = function_object.bytecodeFunctionStoragePtr().function_bytecode orelse
        return error.InvalidFunctionBytecode;
    const cached_view = fb.cached_view orelse
        return error.InvalidFunctionBytecode;
    const rerun = try js.eval(
        \\assert.sameValue(memoizedBytecodeView(3), 4);
        \\Promise.resolve(4)
        \\    .then(function(value) {
        \\        var holder = { method: memoizedBytecodeView };
        \\        return holder.method(value);
        \\    })
        \\    .then(function(value) {
        \\        assert.sameValue(value, 5);
        \\    });
        \\undefined;
    );
    defer rerun.free(js.runtime);
    try std.testing.expectEqual(cached_view, fb.cached_view.?);
}

test "Math cproto dispatch preserves observable ToNumber semantics" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var log = "";
        \\var lhs = { valueOf() { log += "l"; return -3; } };
        \\var rhs = { valueOf() { log += "r"; return 4; } };
        \\print(Math.abs(lhs));
        \\print(Math.atan2(lhs, rhs) === Math.atan2(-3, 4));
        \\print(log);
        \\print(Number.isNaN(Math.abs()));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("3\ntrue\nllr\ntrue\n", stream.buffered());
}

test "local add_loc retains string snapshots while using a rope tail" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function build() {
        \\  var text = "";
        \\  for (var i = 0; i < 4096; i++) text += "ab";
        \\  return text;
        \\}
        \\function verifySnapshot() {
        \\  var text = "";
        \\  var snapshot;
        \\  for (var i = 0; i < 4096; i++) {
        \\    if (i === 2048) snapshot = text;
        \\    text += "ab";
        \\  }
        \\  return snapshot.length;
        \\}
        \\if (verifySnapshot() !== 4096) throw new Error("snapshot mutated");
        \\globalThis.__rope_tail_probe = build();
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    const global = js.context.global orelse return error.TypeError;
    const probe_atom = try js.runtime.internAtom("__rope_tail_probe");
    defer js.runtime.atoms.free(probe_atom);
    const text = global.getProperty(probe_atom);
    defer text.free(js.runtime);
    const rope = text.ropeBody() orelse return error.TypeError;
    try std.testing.expectEqual(@as(usize, 8192), rope.len_());
    try std.testing.expect(rope.tailLen() >= 2048);
    var chain_depth: usize = 1;
    var cursor = rope;
    while (cursor.left.ropeBody()) |left| {
        chain_depth += 1;
        if (chain_depth > 8) break;
        cursor = left;
    }
    try std.testing.expect(chain_depth <= 4);
}

test "checked lexical string accumulation keeps rope depth bounded" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function build() {
        \\  let text = "";
        \\  let snapshot;
        \\  for (var i = 0; i < 8192; i++) {
        \\    if (i === 4096) snapshot = text;
        \\    text += "ab";
        \\  }
        \\  if (snapshot.length !== 8192) throw new Error("snapshot mutated");
        \\  return text;
        \\}
        \\globalThis.__checked_lexical_rope_probe = build();
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    const global = js.context.global orelse return error.TypeError;
    const probe_atom = try js.runtime.internAtom("__checked_lexical_rope_probe");
    defer js.runtime.atoms.free(probe_atom);
    const text = global.getProperty(probe_atom);
    defer text.free(js.runtime);
    const rope = text.ropeBody() orelse return error.TypeError;
    try std.testing.expectEqual(@as(usize, 16384), rope.len_());

    // QJS caps rope depth and rebalances; zjs may use its private growable tail,
    // but must likewise avoid retaining one wrapper node per `+=` iteration.
    var left_depth: usize = 1;
    var cursor = rope;
    while (cursor.left.ropeBody()) |left| {
        left_depth += 1;
        if (left_depth > 64) break;
        cursor = left;
    }
    try std.testing.expect(left_depth <= 64);
}

test "computed reads with cached string atoms preserve exotic and prototype semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const proto = { get hot() { return 7; } };
        \\const object = Object.create(proto);
        \\assert.sameValue(object["hot"], 7);
        \\let trapCalls = 0;
        \\const proxy = new Proxy(object, {
        \\  get(target, key, receiver) {
        \\    trapCalls++;
        \\    return Reflect.get(target, key, receiver);
        \\  }
        \\});
        \\assert.sameValue(proxy["hot"], 7);
        \\assert.sameValue(trapCalls, 1);
        \\assert.sameValue([11]["0"], 11);
        \\assert.sameValue("ab"["1"], "b");
        \\assert.sameValue(new Uint8Array([9])["0"], 9);
        \\const dynamic = "dynamic" + "Key";
        \\const keyed = { dynamicKey: 13 };
        \\assert.sameValue(keyed[dynamic], 13);
        \\assert.sameValue(keyed[dynamic], 13);
        \\let holder;
        \\const recycledKey = "recycled_key_" + 12345;
        \\holder = {};
        \\holder[recycledKey] = 1;
        \\const invariantTarget = {};
        \\const recyclingProxy = new Proxy(invariantTarget, {
        \\  get(target, key) {
        \\    delete holder[recycledKey];
        \\    holder = null;
        \\    const replacementKey = "replacement_key_" + 67890;
        \\    Object.defineProperty(target, replacementKey, {
        \\      value: 123,
        \\      configurable: false,
        \\      writable: false
        \\    });
        \\    return 456;
        \\  }
        \\});
        \\assert.sameValue(recyclingProxy[recycledKey], 456);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "native dispatch metadata is internal and ignores user properties" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var f = Object.prototype.isPrototypeOf;
        \\print("__zjs_native_name" in f);
        \\print(Object.getOwnPropertyDescriptor(f, "__zjs_native_name") === undefined);
        \\f.__zjs_native_name = "notIsPrototypeOf";
        \\print(f.call(Object.prototype, {}));
        \\print(delete f.__zjs_native_name);
        \\print(f.call(Object.prototype, {}));
        \\var a = [];
        \\Array.prototype.push.__zjs_native_name = "notPush";
        \\print(Array.prototype.push.call(a, 1));
        \\print(delete Array.prototype.push.__zjs_native_name);
        \\print(Array.prototype.push.call(a, 2));
        \\print(a.length);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\ntrue\ntrue\ntrue\n1\ntrue\n2\n2\n", stream.buffered());
}

test "scope resolver skips popped lexical shadow for destructured parameter" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function f({ comment, items }) {
        \\  { let comment = null; }
        \\  for (let i = 0; i < items.length; ++i) {
        \\    let comment = "inner";
        \\  }
        \\  return comment;
        \\}
        \\assert.sameValue(f({ comment: "ok", items: [1] }), "ok");
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "__zjs-prefixed user properties are ordinary own properties" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var o = {};
        \\o.__zjs_user = 1;
        \\Object.defineProperty(o, "__zjs_non_enum", { value: 2, enumerable: false, configurable: true });
        \\print(Object.getOwnPropertyNames(o).join("|"));
        \\print(Object.getOwnPropertyDescriptors(o).__zjs_user.value);
        \\print(Object.getOwnPropertyDescriptor(o, "__zjs_non_enum").value);
        \\print(Reflect.ownKeys(o).join("|"));
        \\print(Object.keys(o).join("|"));
        \\print("__zjs_user" in o);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("__zjs_user|__zjs_non_enum\n1\n2\n__zjs_user|__zjs_non_enum\n__zjs_user\ntrue\n", stream.buffered());
}

test "array species fast path markers are internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var getter = Object.getOwnPropertyDescriptor(Array, Symbol.species).get;
        \\print("__zjs_array_constructor" in Array);
        \\print(Object.getOwnPropertyDescriptor(Array, "__zjs_array_constructor") === undefined);
        \\print("__zjs_array_species_getter" in getter);
        \\print(Object.getOwnPropertyDescriptor(getter, "__zjs_array_species_getter") === undefined);
        \\Array.__zjs_array_constructor = 0;
        \\getter.__zjs_array_species_getter = 0;
        \\var mapped = [1, 2].map(function(value) { return value + 1; });
        \\print(mapped instanceof Array);
        \\print(mapped.join(","));
        \\print(delete Array.__zjs_array_constructor);
        \\print(delete getter.__zjs_array_species_getter);
        \\print([3].filter(function() { return true; }).join(","));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\nfalse\ntrue\ntrue\n2,3\ntrue\ntrue\n3\n", stream.buffered());
}

test "auto-init builtin markers are internal and ignore user properties" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function check(fn, marker, run) {
        \\  print(marker in fn);
        \\  print(Object.getOwnPropertyDescriptor(fn, marker) === undefined);
        \\  fn[marker] = 0;
        \\  print(run());
        \\  print(delete fn[marker]);
        \\  print(run());
        \\}
        \\check(Object.assign, "__zjs_object_static", function() {
        \\  var target = {};
        \\  Object.assign(target, { x: 1 });
        \\  return target.x;
        \\});
        \\check(Object.defineProperty, "__zjs_define_property_kind", function() {
        \\  var object = {};
        \\  Object.defineProperty(object, "x", { value: 1 });
        \\  return object.x;
        \\});
        \\check(Object.prototype.hasOwnProperty, "__zjs_object_method", function() {
        \\  return Object.prototype.hasOwnProperty.call({ x: 1 }, "x");
        \\});
        \\check(String.prototype.includes, "__zjs_string_method", function() {
        \\  return "abc".includes("b");
        \\});
        \\check(Number.prototype.toFixed, "__zjs_number_method", function() {
        \\  return (7).toFixed(0);
        \\});
        \\check(RegExp.prototype.test, "__zjs_regexp_method", function() {
        \\  return /a/.test("a");
        \\});
        \\check(RegExp.escape, "__zjs_regexp_escape", function() {
        \\  return RegExp.escape("a+b") === "\\x61\\+b";
        \\});
        \\check(JSON.parse, "__zjs_json_static", function() {
        \\  return JSON.parse("{\"x\":1}").x;
        \\});
        \\check(JSON.stringify, "__zjs_json_static", function() {
        \\  return JSON.stringify({ x: 1 });
        \\});
        \\check(Reflect.apply, "__zjs_reflect_static", function() {
        \\  return Reflect.apply(function(x) { return x + 1; }, null, [2]);
        \\});
        \\check(Reflect.setPrototypeOf, "__zjs_reflect_set_prototype_of", function() {
        \\  var proto = { x: 1 };
        \\  var object = {};
        \\  return Reflect.setPrototypeOf(object, proto) && object.x;
        \\});
        \\check(Reflect.defineProperty, "__zjs_define_property_kind", function() {
        \\  var object = {};
        \\  return Reflect.defineProperty(object, "x", { value: 1 }) && object.x;
        \\});
        \\check(Atomics.isLockFree, "__zjs_atomics_static", function() {
        \\  return Atomics.isLockFree(4);
        \\});
        \\check(Array.prototype.concat, "__zjs_array_concat", function() {
        \\  return [1].concat([2]).join(",");
        \\});
        \\check(ArrayBuffer.prototype.slice, "__zjs_buffer_method_kind", function() {
        \\  return new ArrayBuffer(4).slice(1).byteLength;
        \\});
        \\check(SharedArrayBuffer.prototype.slice, "__zjs_buffer_method_kind", function() {
        \\  return new SharedArrayBuffer(4).slice(1).byteLength;
        \\});
        \\check(Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "byteLength").get, "__zjs_buffer_accessor_kind", function() {
        \\  return new ArrayBuffer(4).byteLength;
        \\});
        \\check(Object.getOwnPropertyDescriptor(SharedArrayBuffer.prototype, "byteLength").get, "__zjs_buffer_accessor_kind", function() {
        \\  return new SharedArrayBuffer(4).byteLength;
        \\});
        \\check(Object.getOwnPropertyDescriptor(DataView.prototype, "byteLength").get, "__zjs_dataview_accessor", function() {
        \\  return new DataView(new ArrayBuffer(6), 1, 3).byteLength;
        \\});
        \\check(Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Uint8Array.prototype), "length").get, "__zjs_typedarray_accessor", function() {
        \\  return new Uint8Array(5).length;
        \\});
        \\check(Uint8Array.prototype.slice, "__zjs_typedarray_method", function() {
        \\  return new Uint8Array([1, 2]).slice(1)[0];
        \\});
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "false\ntrue\n1\ntrue\n1\n" ++
            "false\ntrue\n1\ntrue\n1\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\n7\ntrue\n7\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\n1\ntrue\n1\n" ++
            "false\ntrue\n{\"x\":1}\ntrue\n{\"x\":1}\n" ++
            "false\ntrue\n3\ntrue\n3\n" ++
            "false\ntrue\n1\ntrue\n1\n" ++
            "false\ntrue\n1\ntrue\n1\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\n1,2\ntrue\n1,2\n" ++
            "false\ntrue\n3\ntrue\n3\n" ++
            "false\ntrue\n3\ntrue\n3\n" ++
            "false\ntrue\n4\ntrue\n4\n" ++
            "false\ntrue\n4\ntrue\n4\n" ++
            "false\ntrue\n3\ntrue\n3\n" ++
            "false\ntrue\n5\ntrue\n5\n" ++
            "false\ntrue\n2\ntrue\n2\n",
        stream.buffered(),
    );
}

test "immutable prototype marker is internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print("__zjs_immutable_prototype" in Object.prototype);
        \\print(Object.getOwnPropertyDescriptor(Object.prototype, "__zjs_immutable_prototype") === undefined);
        \\Object.prototype.__zjs_immutable_prototype = false;
        \\print(Reflect.setPrototypeOf(Object.prototype, {}));
        \\try { Object.setPrototypeOf(Object.prototype, {}); print("no throw"); } catch (e) { print(e.name); }
        \\print(delete Object.prototype.__zjs_immutable_prototype);
        \\print(Reflect.setPrototypeOf(Object.prototype, null));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\nfalse\nTypeError\ntrue\ntrue\n", stream.buffered());
}

test "builtin dispatch function markers are internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function check(fn, marker, run) {
        \\  print(marker in fn);
        \\  print(Object.getOwnPropertyDescriptor(fn, marker) === undefined);
        \\  fn[marker] = 0;
        \\  print(run());
        \\  print(delete fn[marker]);
        \\  print(run());
        \\}
        \\check(Function.prototype.toString, "__zjs_function_to_string", function() {
        \\  return typeof Function.prototype.toString.call(Array.prototype.push);
        \\});
        \\check(Error.prototype.toString, "__zjs_error_to_string", function() {
        \\  return Error.prototype.toString.call({ name: "E", message: "m" });
        \\});
        \\var constructorDesc = Object.getOwnPropertyDescriptor(Iterator.prototype, "constructor");
        \\var tagDesc = Object.getOwnPropertyDescriptor(Iterator.prototype, Symbol.toStringTag);
        \\check(constructorDesc.get, "__zjs_iterator_accessor", function() {
        \\  return constructorDesc.get.call(Iterator.prototype) === Iterator;
        \\});
        \\check(tagDesc.get, "__zjs_iterator_accessor", function() {
        \\  return tagDesc.get.call(Iterator.prototype);
        \\});
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "false\ntrue\nstring\ntrue\nstring\n" ++
            "false\ntrue\nE: m\ntrue\nE: m\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\nIterator\ntrue\nIterator\n",
        stream.buffered(),
    );
}

test "proxy revocation target is internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var r = Proxy.revocable({ x: 1 }, {});
        \\var revoke = r.revoke;
        \\print("__zjs_revoke_proxy" in revoke);
        \\print(Object.getOwnPropertyDescriptor(revoke, "__zjs_revoke_proxy") === undefined);
        \\revoke.__zjs_revoke_proxy = null;
        \\print(revoke.__zjs_revoke_proxy === null);
        \\revoke();
        \\var threw = false;
        \\try {
        \\  r.proxy.x;
        \\} catch (e) {
        \\  threw = e instanceof TypeError;
        \\}
        \\print(threw);
        \\print(delete revoke.__zjs_revoke_proxy);
        \\print("__zjs_revoke_proxy" in revoke);
        \\var r2 = Proxy.revocable({ y: 2 }, {});
        \\print(delete r2.revoke.__zjs_revoke_proxy);
        \\r2.revoke();
        \\var threw2 = false;
        \\try {
        \\  r2.proxy.y;
        \\} catch (e) {
        \\  threw2 = e instanceof TypeError;
        \\}
        \\print(threw2);
        \\r2.revoke();
        \\print("done");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\ntrue\ntrue\ntrue\nfalse\ntrue\ntrue\ndone\n", stream.buffered());
}

test "regexp accessor realm TypeError constructor is internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var getter = Object.getOwnPropertyDescriptor(RegExp.prototype, "source").get;
        \\print("__zjs_realm_TypeError" in getter);
        \\print(Object.getOwnPropertyDescriptor(getter, "__zjs_realm_TypeError") === undefined);
        \\function Fake(message) {
        \\  this.message = message;
        \\}
        \\Fake.prototype = Object.create(Error.prototype);
        \\Fake.prototype.constructor = Fake;
        \\getter.__zjs_realm_TypeError = Fake;
        \\try {
        \\  getter.call({});
        \\} catch (e) {
        \\  print(e.constructor === Fake);
        \\  print(e instanceof TypeError);
        \\}
        \\print(delete getter.__zjs_realm_TypeError);
        \\try {
        \\  getter.call({});
        \\} catch (e) {
        \\  print(e instanceof TypeError);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\nfalse\ntrue\ntrue\ntrue\n", stream.buffered());
}

test "throw type error intrinsic marker is internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\"use strict";
        \\print("__zjs_throw_type_error_intrinsic" in globalThis);
        \\print(Object.getOwnPropertyDescriptor(globalThis, "__zjs_throw_type_error_intrinsic") === undefined);
        \\globalThis.__zjs_throw_type_error_intrinsic = function() { return 1; };
        \\print("__zjs_throw_type_error_intrinsic" in globalThis);
        \\print(delete globalThis.__zjs_throw_type_error_intrinsic);
        \\print("__zjs_throw_type_error_intrinsic" in globalThis);
        \\var thrower = Object.getOwnPropertyDescriptor(Function.prototype, "arguments").get;
        \\print(typeof thrower);
        \\print("__zjs_throw_type_error_function_proto" in thrower);
        \\print(Object.getOwnPropertyDescriptor(thrower, "__zjs_throw_type_error_function_proto") === undefined);
        \\var assignType = "none";
        \\try {
        \\  thrower.__zjs_throw_type_error_function_proto = false;
        \\} catch (e) {
        \\  assignType = e.name;
        \\}
        \\print(assignType);
        \\print("__zjs_throw_type_error_function_proto" in thrower);
        \\print(delete thrower.__zjs_throw_type_error_function_proto);
        \\var threw = false;
        \\try {
        \\  thrower();
        \\} catch (e) {
        \\  threw = e instanceof TypeError;
        \\}
        \\print(threw);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\ntrue\ntrue\nfalse\nfunction\nfalse\ntrue\nTypeError\nfalse\ntrue\ntrue\n", stream.buffered());

    const probe_result = try js.eval("globalThis.__thrower_probe = Object.getOwnPropertyDescriptor(Function.prototype, \"arguments\").get;");
    defer probe_result.free(js.runtime);
    try std.testing.expect(js.context.global != null);
    const global = js.context.global.?;
    const probe_key = try js.runtime.internAtom("__thrower_probe");
    defer js.runtime.atoms.free(probe_key);
    const thrower_value = global.getProperty(probe_key);
    defer thrower_value.free(js.runtime);
    const thrower_object = try property_ops.expectObject(thrower_value);
    const dispatch_atom = thrower_object.nativeDispatchName();
    try std.testing.expect(dispatch_atom != core.atom.null_atom);
    const dispatch_name = js.runtime.atoms.name(dispatch_atom);
    try std.testing.expect(dispatch_name != null);
    try std.testing.expectEqualStrings("", dispatch_name.?);
}

test "async generator prototype method marker is internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\async function* g() {}
        \\var AsyncGeneratorPrototype = Object.getPrototypeOf(g.prototype);
        \\var next = AsyncGeneratorPrototype.next;
        \\print("__zjs_async_generator_method" in next);
        \\print(Object.getOwnPropertyDescriptor(next, "__zjs_async_generator_method") === undefined);
        \\next.__zjs_async_generator_method = 0;
        \\print("__zjs_async_generator_method" in next);
        \\print(delete next.__zjs_async_generator_method);
        \\print("__zjs_async_generator_method" in next);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\ntrue\ntrue\nfalse\n", stream.buffered());
}

test "generator instances inherit shared prototype methods" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function* syncGenerator() { yield 1; }
        \\var syncA = syncGenerator();
        \\var syncB = syncGenerator();
        \\var GeneratorPrototype = Object.getPrototypeOf(syncGenerator.prototype);
        \\var arrayIteratorForNativeRecord = [][Symbol.iterator]();
        \\print(Object.getOwnPropertyNames(syncA).length);
        \\print(syncA.next === GeneratorPrototype.next);
        \\print(syncA.return === GeneratorPrototype.return);
        \\print(syncA.throw === GeneratorPrototype.throw);
        \\print(syncA.next === syncB.next);
        \\print(syncA.next.length);
        \\print(typeof syncA.slice);
        \\var calls = 0;
        \\var overridden = syncGenerator();
        \\var builtinNext = overridden.next;
        \\overridden.next = function() {
        \\  calls++;
        \\  return builtinNext.call(this);
        \\};
        \\var values = [];
        \\for (var value of overridden) values.push(value);
        \\print(calls + ":" + values.join(","));
        \\var customGeneratorPrototype = Object.create(GeneratorPrototype);
        \\syncGenerator.prototype = customGeneratorPrototype;
        \\var customSync = syncGenerator();
        \\print(Object.getPrototypeOf(customSync) === customGeneratorPrototype);
        \\print(customSync.next === GeneratorPrototype.next);
        \\syncGenerator.prototype = 1;
        \\print(Object.getPrototypeOf(syncGenerator()) === GeneratorPrototype);
        \\async function* asyncGenerator() { yield 1; }
        \\var asyncA = asyncGenerator();
        \\var asyncB = asyncGenerator();
        \\var AsyncGeneratorPrototype = Object.getPrototypeOf(asyncGenerator.prototype);
        \\print(Object.getOwnPropertyNames(asyncA).length);
        \\print(asyncA.next === AsyncGeneratorPrototype.next);
        \\print(asyncA.return === AsyncGeneratorPrototype.return);
        \\print(asyncA.throw === AsyncGeneratorPrototype.throw);
        \\print(asyncA.next === asyncB.next);
        \\print(asyncA.next.length);
        \\print(typeof asyncA.slice);
        \\var customAsyncGeneratorPrototype = Object.create(AsyncGeneratorPrototype);
        \\asyncGenerator.prototype = customAsyncGeneratorPrototype;
        \\print(Object.getPrototypeOf(asyncGenerator()) === customAsyncGeneratorPrototype);
        \\asyncGenerator.prototype = null;
        \\print(Object.getPrototypeOf(asyncGenerator()) === AsyncGeneratorPrototype);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "0\ntrue\ntrue\ntrue\ntrue\n1\nundefined\n2:1\ntrue\ntrue\ntrue\n0\ntrue\ntrue\ntrue\ntrue\n1\nundefined\ntrue\ntrue\n",
        stream.buffered(),
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const sync_key = try js.runtime.internAtom("syncA");
    defer js.runtime.atoms.free(sync_key);
    const sync_value = global.getProperty(sync_key);
    defer sync_value.free(js.runtime);
    const sync_object = try property_ops.expectObject(sync_value);
    try std.testing.expect(!js.runtime.borrowedReferenceHolderRegistered(sync_object));
    try std.testing.expectEqual(global, engine.exec.object_ops.objectRealmGlobal(sync_object).?);

    const generator_prototype_key = try js.runtime.internAtom("GeneratorPrototype");
    defer js.runtime.atoms.free(generator_prototype_key);
    const generator_prototype_value = global.getProperty(generator_prototype_key);
    defer generator_prototype_value.free(js.runtime);
    const generator_prototype = try property_ops.expectObject(generator_prototype_value);
    const IntrinsicMethod = core.host_function.builtin_method_ids.iterator.IntrinsicMethod;
    const generator_methods = [_]struct { name: []const u8, id: u32 }{
        .{ .name = "next", .id = @intFromEnum(IntrinsicMethod.generator_next) },
        .{ .name = "return", .id = @intFromEnum(IntrinsicMethod.generator_return) },
        .{ .name = "throw", .id = @intFromEnum(IntrinsicMethod.generator_throw) },
    };
    for (generator_methods) |method| {
        const key = try js.runtime.internAtom(method.name);
        defer js.runtime.atoms.free(key);
        const value = generator_prototype.getProperty(key);
        defer value.free(js.runtime);
        const function_object = try property_ops.expectObject(value);
        const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*) orelse return error.InvalidBuiltinRegistry;
        try std.testing.expectEqual(core.function.NativeBuiltinDomain.iterator, native_ref.domain);
        try std.testing.expectEqual(method.id, native_ref.id);
        try std.testing.expect(function_object.nativeRecord() != null);
    }

    const array_iterator_key = try js.runtime.internAtom("arrayIteratorForNativeRecord");
    defer js.runtime.atoms.free(array_iterator_key);
    const array_iterator_value = global.getProperty(array_iterator_key);
    defer array_iterator_value.free(js.runtime);
    const array_iterator = try property_ops.expectObject(array_iterator_value);
    const next_key = try js.runtime.internAtom("next");
    defer js.runtime.atoms.free(next_key);
    const next_value = array_iterator.getProperty(next_key);
    defer next_value.free(js.runtime);
    const next_function = try property_ops.expectObject(next_value);
    const next_ref = core.function.decodeNativeBuiltinId(next_function.nativeFunctionIdSlot().*) orelse return error.InvalidBuiltinRegistry;
    try std.testing.expectEqual(core.function.NativeBuiltinDomain.iterator, next_ref.domain);
    try std.testing.expectEqual(@intFromEnum(IntrinsicMethod.array_iterator_next), next_ref.id);
    try std.testing.expect(next_function.nativeRecord() != null);
}

test "generator object uses the prototype selected after parameter initialization" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\var GeneratorPrototype = Object.getPrototypeOf(function* () {}.prototype);
        \\var syncPrototype = Object.create(GeneratorPrototype);
        \\function* syncGenerator(value = (syncGenerator.prototype = syncPrototype)) {}
        \\if (Object.getPrototypeOf(syncGenerator()) !== syncPrototype) throw new Error("sync prototype order");
        \\var AsyncGeneratorPrototype = Object.getPrototypeOf(async function* () {}.prototype);
        \\var asyncPrototype = Object.create(AsyncGeneratorPrototype);
        \\async function* asyncGenerator(value = (asyncGenerator.prototype = asyncPrototype)) {}
        \\if (Object.getPrototypeOf(asyncGenerator()) !== asyncPrototype) throw new Error("async prototype order");
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "generator completion resumes keep the original function home object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\class Base {
        \\  get marker() { return 41; }
        \\}
        \\class Derived extends Base {
        \\  *viaReturn() {
        \\    try { yield 0; }
        \\    finally { yield super.marker; }
        \\  }
        \\  *viaThrow() {
        \\    try { yield 0; }
        \\    catch (value) { yield super.marker + value; }
        \\  }
        \\  *viaYieldStar() {
        \\    yield* [0];
        \\    return super.marker;
        \\  }
        \\}
        \\const instance = new Derived();
        \\const returned = instance.viaReturn();
        \\assert.sameValue(returned.next().value, 0);
        \\let step = returned.return(99);
        \\assert.sameValue(step.value, 41);
        \\assert.sameValue(step.done, false);
        \\step = returned.next();
        \\assert.sameValue(step.value, 99);
        \\assert.sameValue(step.done, true);
        \\const thrown = instance.viaThrow();
        \\assert.sameValue(thrown.next().value, 0);
        \\step = thrown.throw(1);
        \\assert.sameValue(step.value, 42);
        \\assert.sameValue(step.done, false);
        \\assert.sameValue(thrown.next().done, true);
        \\const delegated = instance.viaYieldStar();
        \\assert.sameValue(delegated.next().value, 0);
        \\step = delegated.next();
        \\assert.sameValue(step.value, 41);
        \\assert.sameValue(step.done, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "resident generator resumes preserve nested catch and finally targets" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function* afterNested() {
        \\  try {
        \\    yield 1;
        \\    try { yield 2; throw 3; } catch (error) { yield error; }
        \\    yield 4;
        \\  } finally { yield 5; }
        \\}
        \\let iterator = afterNested();
        \\assert.sameValue(iterator.next().value, 1);
        \\assert.sameValue(iterator.next().value, 2);
        \\assert.sameValue(iterator.next().value, 3);
        \\assert.sameValue(iterator.next().value, 4);
        \\assert.sameValue(iterator.throw(6).value, 5);
        \\let caught;
        \\try { iterator.next(); } catch (error) { caught = error; }
        \\assert.sameValue(caught, 6);
        \\function* beforeNested() {
        \\  try {
        \\    yield 1;
        \\    try { yield 2; } catch (error) { yield error; }
        \\  } finally { yield 3; }
        \\}
        \\iterator = beforeNested();
        \\assert.sameValue(iterator.next().value, 1);
        \\assert.sameValue(iterator.throw(7).value, 3);
        \\try { iterator.next(); } catch (error) { caught = error; }
        \\assert.sameValue(caught, 7);
        \\function* plainFinally() {
        \\  try { yield 1; } finally { yield 2; }
        \\}
        \\iterator = plainFinally();
        \\assert.sameValue(iterator.next().value, 1);
        \\assert.sameValue(iterator.throw(8).value, 2);
        \\try { iterator.next(); } catch (error) { caught = error; }
        \\assert.sameValue(caught, 8);
        \\function* inner() { return yield 1; }
        \\function* delegate(iterable) { return yield* iterable; }
        \\iterator = delegate(inner());
        \\assert.sameValue(iterator.next().value, 1);
        \\try { iterator.throw(9); } catch (error) { caught = error; }
        \\assert.sameValue(caught, 9);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "surviving var references keep resident local slots bare" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function* referenceStorage(scope) {
        \\  var target;
        \\  with (scope) { target = 41; }
        \\  yield target;
        \\  target += 1;
        \\  return target;
        \\}
        \\globalThis.__referenceStorage = referenceStorage({});
        \\__referenceStorage.next();
    );
    defer result.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const key = try js.runtime.internAtom("__referenceStorage");
    defer js.runtime.atoms.free(key);
    const value = global.getProperty(key);
    defer value.free(js.runtime);
    const generator = try property_ops.expectObject(value);
    const function_value = generator.generatorFunctionBytecode() orelse return error.TypeError;
    const function = engine.exec.call_runtime.functionBytecodeFromValue(function_value) orelse return error.TypeError;
    const target_idx = localIndexNamed(js.runtime, function, "target") orelse return error.TypeError;
    const state = generator.generatorExecutionState();

    try std.testing.expect(function.open_var_ref_count > 0);
    try std.testing.expect(function.varDefs()[target_idx].is_captured);
    try std.testing.expect(!function.varDefs()[target_idx].is_lexical);
    try std.testing.expectEqual(@as(?i32, 41), state.storage.frame.locals[target_idx].asInt32());
    try std.testing.expect(core.VarRef.fromValue(state.storage.frame.locals[target_idx]) == null);
    var found_open_alias = false;
    for (state.storage.frame.open_var_refs) |maybe_ref| {
        const ref = maybe_ref orelse continue;
        if (ref.is_open and ref.pvalue == &state.storage.frame.locals[target_idx]) found_open_alias = true;
    }
    try std.testing.expect(found_open_alias);

    const completion = try js.eval(
        \\const step = __referenceStorage.next();
        \\assert.sameValue(step.value, 42);
        \\assert.sameValue(step.done, true);
    );
    defer completion.free(js.runtime);
    try std.testing.expect(completion.isUndefined());
}

test "direct eval captures only bindings visible at its call scope" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function* scopedEvalStorage() {
        \\  { let sibling = 10; globalThis.__siblingValue = sibling; }
        \\  var visible = 1;
        \\  { let active = 2; eval("visible = active"); yield visible; }
        \\}
        \\globalThis.__scopedEvalStorage = scopedEvalStorage();
    );
    defer result.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const key = try js.runtime.internAtom("__scopedEvalStorage");
    defer js.runtime.atoms.free(key);
    const value = global.getProperty(key);
    defer value.free(js.runtime);
    const generator = try property_ops.expectObject(value);
    const function_value = generator.generatorFunctionBytecode() orelse return error.TypeError;
    const function = engine.exec.call_runtime.functionBytecodeFromValue(function_value) orelse return error.TypeError;
    const sibling_idx = localIndexNamed(js.runtime, function, "sibling") orelse return error.TypeError;
    const visible_idx = localIndexNamed(js.runtime, function, "visible") orelse return error.TypeError;
    const active_idx = localIndexNamed(js.runtime, function, "active") orelse return error.TypeError;

    try std.testing.expect(!function.varDefs()[sibling_idx].is_captured);
    try std.testing.expect(function.varDefs()[visible_idx].is_captured);
    try std.testing.expect(function.varDefs()[active_idx].is_captured);
    const view = bytecode.asBytecodeView(function, js.runtime);
    try std.testing.expect(view.localOpenBindingIndex(sibling_idx) == null);
    try std.testing.expect(view.localOpenBindingIndex(visible_idx) != null);
    try std.testing.expect(view.localOpenBindingIndex(active_idx) != null);
}

test "suspended generators retain one resident execution owner across resumes" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function* residentGenerator(argument) {
        \\  let local = { local: true };
        \\  try {
        \\    yield local;
        \\    yield argument;
        \\  } catch (error) {
        \\    yield error;
        \\  }
        \\}
        \\globalThis.__residentGenerator = residentGenerator({ argument: true });
        \\let first = __residentGenerator.next();
        \\assert.sameValue(first.value.local, true);
        \\assert.sameValue(first.done, false);
        \\let second = __residentGenerator.next();
        \\assert.sameValue(second.value.argument, true);
        \\assert.sameValue(second.done, false);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const key = try js.runtime.internAtom("__residentGenerator");
    defer js.runtime.atoms.free(key);
    const value = global.getProperty(key);
    defer value.free(js.runtime);
    const generator = try property_ops.expectObject(value);
    const generator_function = generator.generatorFunctionBytecode() orelse return error.TypeError;
    try std.testing.expect(inline_calls.resolveInlineTarget(
        js.context,
        global,
        core.JSValue.undefinedValue(),
        generator_function,
    ) == null);
    const state = generator.generatorExecutionState();
    try std.testing.expect(!generator.generatorDone());
    try std.testing.expect(state.has_frame);
    try std.testing.expect(!state.running_aliases);
    try std.testing.expect(state.resident_storage_owner);
    try std.testing.expect(state.catchTarget() != null);
    try std.testing.expect(generator.generatorStackUsesCombinedStorage());
    try std.testing.expect(generator.generatorFrameUsesCombinedStorage());
    try std.testing.expect(state.storage.frame.args.len != 0);
    try std.testing.expect(state.storage.frame.locals.len != 0);
    const completion = try js.eval(
        \\let finalStep = __residentGenerator.next();
        \\assert.sameValue(finalStep.value, undefined);
        \\assert.sameValue(finalStep.done, true);
    );
    defer completion.free(js.runtime);
    try std.testing.expect(completion.isUndefined());
    try std.testing.expect(generator.generatorDone());
    try std.testing.expect(!generator.generatorExecutionState().has_frame);
    try std.testing.expect(generator.generatorExecutionState().storage.isEmpty());
}

test "completed generators eagerly release their resident execution state" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function make(captured) {
        \\  return function* generator(argument) { yield captured; return argument; };
        \\}
        \\const generator = make({ captured: true });
        \\globalThis.__returnedGenerator = generator.call({ receiver: true }, { argument: true });
        \\let step = __returnedGenerator.return(7);
        \\assert.sameValue(step.value, 7);
        \\assert.sameValue(step.done, true);
        \\step = __returnedGenerator.next();
        \\assert.sameValue(step.value, undefined);
        \\assert.sameValue(step.done, true);
        \\step = __returnedGenerator.return(8);
        \\assert.sameValue(step.value, 8);
        \\assert.sameValue(step.done, true);
        \\let thrown;
        \\try { __returnedGenerator.throw(9); } catch (value) { thrown = value; }
        \\assert.sameValue(thrown, 9);
        \\globalThis.__normallyCompletedGenerator = generator({ argument: true });
        \\__normallyCompletedGenerator.next();
        \\step = __normallyCompletedGenerator.next();
        \\assert.sameValue(step.done, true);
        \\globalThis.__thrownGenerator = generator({ argument: true });
        \\try { __thrownGenerator.throw(10); } catch (value) { thrown = value; }
        \\assert.sameValue(thrown, 10);
    );
    defer result.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const names = [_][]const u8{
        "__returnedGenerator",
        "__normallyCompletedGenerator",
        "__thrownGenerator",
    };
    for (names) |name| {
        const key = try js.runtime.internAtom(name);
        defer js.runtime.atoms.free(key);
        const value = global.getProperty(key);
        defer value.free(js.runtime);
        const generator_object = try property_ops.expectObject(value);
        try std.testing.expect(generator_object.generatorDone());
        try std.testing.expect(!generator_object.generatorExecutionState().has_frame);
        try std.testing.expect(generator_object.generatorExecutionState().storage.isEmpty());
        try std.testing.expectEqual(@as(usize, 0), generator_object.generatorPc());
        try std.testing.expectEqual(@as(usize, 0), generator_object.generatorArgs().len);
        try std.testing.expectEqual(@as(usize, 0), generator_object.generatorCaptures().len);
        try std.testing.expect(generator_object.generatorThis() == null);
        try std.testing.expect(generator_object.generatorCurrentFunction() == null);
    }
}

test "iterator helper method marker is internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function printLayout(label, helper) {
        \\  var proto = Object.getPrototypeOf(helper);
        \\  print(label);
        \\  print(Object.prototype.toString.call(helper));
        \\  print("own:" + Object.getOwnPropertyNames(helper).join(","));
        \\  print("proto:" + Object.getOwnPropertyNames(proto).join(","));
        \\  print(helper.hasOwnProperty("next"));
        \\  print(typeof proto.next);
        \\  print(helper.next === proto.next);
        \\}
        \\function check(fn, marker, run) {
        \\  print(marker in fn);
        \\  print(Object.getOwnPropertyDescriptor(fn, marker) === undefined);
        \\  fn[marker] = 0;
        \\  print(marker in fn);
        \\  print(run());
        \\  print(delete fn[marker]);
        \\  print(marker in fn);
        \\  print(run());
        \\}
        \\var helper = Iterator.from([1]).map(function(x) { return x + 1; });
        \\printLayout("map", helper);
        \\printLayout("concat", Iterator.concat([1]));
        \\printLayout("zip", Iterator.zip([[1], [2]]));
        \\var next = helper.next;
        \\check(next, "__zjs_iterator_helper_method", function() {
        \\  var h = Iterator.from([1]).map(function(x) { return x + 1; });
        \\  return next.call(h).value;
        \\});
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "map\n[object Iterator Helper]\nown:\nproto:next,return\nfalse\nfunction\ntrue\n" ++
            "concat\n[object Iterator Concat]\nown:\nproto:next,return\nfalse\nfunction\ntrue\n" ++
            "zip\n[object Iterator Helper]\nown:next,return\nproto:next,return\ntrue\nfunction\nfalse\n" ++
            "false\ntrue\ntrue\n2\ntrue\nfalse\n2\n",
        stream.buffered(),
    );
}

test "Iterator.from follows QuickJS wrapper selection" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var count = 0;
        \\var iterable = {
        \\  [Symbol.iterator]: function() { return this; },
        \\  get next() {
        \\    count++;
        \\    return function() { return { done: true, value: 1 }; };
        \\  },
        \\};
        \\var fromIterable = Iterator.from(iterable);
        \\print(fromIterable === iterable);
        \\print(count);
        \\fromIterable.next();
        \\print(count);
        \\print(typeof fromIterable.map);
        \\var sealed = Object.preventExtensions({
        \\  next: function() { return { done: true }; },
        \\});
        \\var wrapped = Iterator.from(sealed);
        \\print(wrapped === sealed);
        \\var wrapProto = Object.getPrototypeOf(wrapped);
        \\print("__zjs_iterator_wrap_method" in wrapProto.next);
        \\print(Object.getOwnPropertyDescriptor(wrapProto.next, "__zjs_iterator_wrap_method") === undefined);
        \\print("__zjs_iterator_wrap_method" in wrapProto.return);
        \\print(Object.getOwnPropertyDescriptor(wrapProto.return, "__zjs_iterator_wrap_method") === undefined);
        \\wrapProto.next.__zjs_iterator_wrap_method = 2;
        \\print(wrapped.next().done);
        \\print(wrapped.next().value);
        \\print(delete wrapProto.next.__zjs_iterator_wrap_method);
        \\print(wrapped.next().value);
        \\wrapProto.return.__zjs_iterator_wrap_method = 1;
        \\print(wrapped.return().done);
        \\print(delete wrapProto.return.__zjs_iterator_wrap_method);
        \\print(wrapped.return().done);
        \\print("__zjs_iterator_next" in wrapped);
        \\print(Object.getOwnPropertyDescriptor(wrapped, "__zjs_iterator_next") === undefined);
        \\wrapped.__zjs_iterator_next = function() { return { done: false, value: 99 }; };
        \\print(wrapped.next().value);
        \\print(delete wrapped.__zjs_iterator_next);
        \\print("__zjs_iterator_next" in wrapped);
        \\var bad = Iterator.from({ next: 1 });
        \\print(typeof bad);
        \\try {
        \\  bad.next();
        \\} catch (e) {
        \\  print(e.name);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\n0\n1\nundefined\nfalse\nfalse\ntrue\nfalse\ntrue\ntrue\nundefined\ntrue\nundefined\ntrue\ntrue\ntrue\nfalse\ntrue\nundefined\ntrue\nfalse\nobject\nTypeError\n", stream.buffered());
}

test "number native builtin records cover static and prototype dispatch" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const number_key = try rt.internAtom("Number");
    defer rt.atoms.free(number_key);
    const is_integer_key = try rt.internAtom("isInteger");
    defer rt.atoms.free(is_integer_key);
    const prototype_key = core.atom.ids.prototype;
    const to_fixed_key = try rt.internAtom("toFixed");
    defer rt.atoms.free(to_fixed_key);

    const number_value = global.getProperty(number_key);
    defer number_value.free(rt);
    const number_object: *core.Object = @fieldParentPtr("header", number_value.refHeader().?);

    const is_integer_value = number_object.getProperty(is_integer_key);
    defer is_integer_value.free(rt);
    const is_integer_object: *core.Object = @fieldParentPtr("header", is_integer_value.refHeader().?);
    try std.testing.expect(is_integer_object.nativeFunctionIdSlot().* != 0);

    const fake_static = try engine.core.function.nativeFunction(rt, "notNumberIsInteger", 1);
    defer fake_static.free(rt);
    const fake_static_object: *core.Object = @fieldParentPtr("header", fake_static.refHeader().?);
    fake_static_object.nativeFunctionIdSlot().* = is_integer_object.nativeFunctionIdSlot().*;
    const static_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_static_object);
    defer rt.memory.allocator.free(static_dispatch_name);
    try std.testing.expectEqualStrings("notNumberIsInteger", static_dispatch_name);
    const static_args = [_]core.JSValue{core.JSValue.float64(3.5)};
    const static_result = try engine.exec.call.callValue(ctx, null, fake_static, &static_args);
    defer static_result.free(rt);
    try std.testing.expectEqual(false, static_result.asBool().?);

    const prototype_value = number_object.getProperty(prototype_key);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);
    const to_fixed_value = prototype_object.getProperty(to_fixed_key);
    defer to_fixed_value.free(rt);
    const to_fixed_object: *core.Object = @fieldParentPtr("header", to_fixed_value.refHeader().?);
    try std.testing.expect(to_fixed_object.nativeFunctionIdSlot().* != 0);

    const fake_proto = try engine.core.function.nativeFunction(rt, "notNumberToFixed", 1);
    defer fake_proto.free(rt);
    const fake_proto_object: *core.Object = @fieldParentPtr("header", fake_proto.refHeader().?);
    fake_proto_object.nativeFunctionIdSlot().* = to_fixed_object.nativeFunctionIdSlot().*;
    const proto_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_proto_object);
    defer rt.memory.allocator.free(proto_dispatch_name);
    try std.testing.expectEqualStrings("notNumberToFixed", proto_dispatch_name);
    const fixed_args = [_]core.JSValue{core.JSValue.int32(2)};
    const proto_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, core.JSValue.float64(1.25), fake_proto, &fixed_args);
    defer proto_result.free(rt);
    const proto_string = proto_result.asStringBody().?;
    try std.testing.expect(proto_string.eqlBytes("1.25"));

    const fake_static_key = try rt.internAtom("fakeStatic");
    defer rt.atoms.free(fake_static_key);
    try global.defineOwnProperty(rt, fake_static_key, core.Descriptor.data(fake_static, true, false, true));
    const fake_proto_key = try rt.internAtom("fakeProto");
    defer rt.atoms.free(fake_proto_key);
    try global.defineOwnProperty(rt, fake_proto_key, core.Descriptor.data(fake_proto, true, false, true));

    var parsed = try engine.parser.compile(rt, "print(fakeStatic(3.5)); print(fakeProto.call(1.25, 2));", .{ .mode = .script, .filename = "number-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [32]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("false\n1.25\n", output.buffered());
}

test "string static native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const string_key = try rt.internAtom("String");
    defer rt.atoms.free(string_key);
    const from_code_point_key = try rt.internAtom("fromCodePoint");
    defer rt.atoms.free(from_code_point_key);
    const string_value = global.getProperty(string_key);
    defer string_value.free(rt);
    const string_object: *core.Object = @fieldParentPtr("header", string_value.refHeader().?);
    const from_code_point_value = string_object.getProperty(from_code_point_key);
    defer from_code_point_value.free(rt);
    const from_code_point_object: *core.Object = @fieldParentPtr("header", from_code_point_value.refHeader().?);
    try std.testing.expect(from_code_point_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.core.function.nativeFunction(rt, "notStringFromCodePoint", 1);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = from_code_point_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notStringFromCodePoint", dispatch_name);

    const args = [_]core.JSValue{core.JSValue.int32(0x41)};
    const result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, core.JSValue.undefinedValue(), fake, &args);
    defer result.free(rt);
    const result_string = result.asStringBody().?;
    try std.testing.expect(result_string.eqlBytes("A"));

    const fake_key = try rt.internAtom("fakeStringStatic");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.parser.compile(rt, "print(fakeStringStatic({ valueOf: function(){ return 0x42; } }));", .{ .mode = .script, .filename = "string-static-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [8]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("B\n", output.buffered());
}

test "string prototype native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const string_key = try rt.internAtom("String");
    defer rt.atoms.free(string_key);
    const index_of_key = try rt.internAtom("indexOf");
    defer rt.atoms.free(index_of_key);
    const string_value = global.getProperty(string_key);
    defer string_value.free(rt);
    const string_object: *core.Object = @fieldParentPtr("header", string_value.refHeader().?);
    const prototype_value = string_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);
    const index_of_value = prototype_object.getProperty(index_of_key);
    defer index_of_value.free(rt);
    const index_of_object: *core.Object = @fieldParentPtr("header", index_of_value.refHeader().?);
    try std.testing.expect(index_of_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.core.function.nativeFunction(rt, "notStringIndexOf", 1);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = index_of_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notStringIndexOf", dispatch_name);

    const needle_string = try core.string.String.createUtf8(rt, "n");
    defer needle_string.value().free(rt);
    const receiver_string = try core.string.String.createUtf8(rt, "banana");
    defer receiver_string.value().free(rt);
    const direct_args = [_]core.JSValue{ needle_string.value(), core.JSValue.int32(3) };
    const direct_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver_string.value(), fake, &direct_args);
    defer direct_result.free(rt);
    try std.testing.expectEqual(@as(i32, 4), direct_result.asInt32().?);

    const fake_key = try rt.internAtom("fakeStringIndexOf");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.parser.compile(rt, "print(fakeStringIndexOf.call('banana', 'n', { valueOf: function(){ return 3; } }));", .{ .mode = .script, .filename = "string-prototype-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [8]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("4\n", output.buffered());
}

test "String case conversion records preserve coercion and Unicode semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var hints = [];
        \\var receiver = {};
        \\receiver[Symbol.toPrimitive] = function(hint) {
        \\    hints.push(hint);
        \\    return "aßΣ";
        \\};
        \\assert.sameValue(String.prototype.toUpperCase.call(receiver), "ASSΣ");
        \\assert.sameValue(hints.join(","), "string");
        \\assert.sameValue("AΣ".toLowerCase(), "aς");
        \\assert.sameValue("AΣA".toLowerCase(), "aσa");
        \\assert.sameValue("\uD801\uDC28".toUpperCase(), "\uD801\uDC00");
        \\assert.sameValue(String.prototype.toLowerCase.call(new String("ABC")), "abc");
        \\var upper = String.prototype.toUpperCase;
        \\Object.defineProperty(upper, "name", { value: "renamed" });
        \\assert.sameValue(upper.call("ab"), "AB");
        \\assert.throws(TypeError, function() {
        \\    String.prototype.toUpperCase.call(Symbol("x"));
        \\});
        \\var other = $262.createRealm().global;
        \\assert.throws(other.TypeError, function() {
        \\    other.String.prototype.toUpperCase.call(Symbol("x"));
        \\});
    );
    defer result.free(js.runtime);

    const pure_source = try core.string.String.createUtf8(js.runtime, "ABC");
    defer pure_source.value().free(js.runtime);
    const pure_result = try engine.exec.string_ops.callStringBody(js.context, pure_source.value(), 3, &.{});
    defer pure_result.free(js.runtime);
    try std.testing.expect((pure_result.asStringBody() orelse return error.TestUnexpectedResult).eqlBytes("abc"));

    try std.testing.expect(result.isUndefined());
}

test "date static native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const date_key = try rt.internAtom("Date");
    defer rt.atoms.free(date_key);
    const utc_key = try rt.internAtom("UTC");
    defer rt.atoms.free(utc_key);
    const date_value = global.getProperty(date_key);
    defer date_value.free(rt);
    const date_object: *core.Object = @fieldParentPtr("header", date_value.refHeader().?);
    const utc_value = date_object.getProperty(utc_key);
    defer utc_value.free(rt);
    const utc_object: *core.Object = @fieldParentPtr("header", utc_value.refHeader().?);
    try std.testing.expect(utc_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.core.function.nativeFunction(rt, "notDateUTC", 7);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = utc_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notDateUTC", dispatch_name);

    const args = [_]core.JSValue{ core.JSValue.int32(2024), core.JSValue.int32(0), core.JSValue.int32(1) };
    const result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, core.JSValue.undefinedValue(), fake, &args);
    defer result.free(rt);
    try std.testing.expectEqual(@as(f64, 1704067200000), engine.exec.value_ops.numberValue(result).?);

    const fake_key = try rt.internAtom("fakeDateUTC");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.parser.compile(rt, "print(fakeDateUTC({ valueOf: function(){ return 2024; } }, 0, 1));", .{ .mode = .script, .filename = "date-static-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [24]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("1704067200000\n", output.buffered());
}

test "date constructor native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const date_key = try rt.internAtom("Date");
    defer rt.atoms.free(date_key);
    const date_value = global.getProperty(date_key);
    defer date_value.free(rt);
    const date_object: *core.Object = @fieldParentPtr("header", date_value.refHeader().?);
    try std.testing.expect(date_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.core.function.nativeFunction(rt, "notDateConstructor", 7);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = date_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notDateConstructor", dispatch_name);

    const prototype_value = date_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    try fake_object.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(prototype_value, true, false, true));

    const call_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, core.JSValue.undefinedValue(), fake, &.{});
    defer call_result.free(rt);
    var call_buffer = std.ArrayList(u8).empty;
    defer call_buffer.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &call_buffer, call_result);
    // Local-time toString shape (offset varies with the host timezone).
    try std.testing.expect(std.mem.indexOf(u8, call_buffer.items, "GMT+") != null or
        std.mem.indexOf(u8, call_buffer.items, "GMT-") != null);

    const construct_result = try engine.exec.construct.constructValue(ctx, fake, &.{core.JSValue.int32(1)}, &.{});
    defer construct_result.free(rt);
    const construct_ms = try engine.exec.date_ops.methodCall(rt, construct_result, 1);
    defer construct_ms.free(rt);
    try std.testing.expectEqual(@as(f64, 1), engine.exec.value_ops.numberValue(construct_ms).?);

    const fake_key = try rt.internAtom("fakeDateConstructor");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.parser.compile(rt,
        \\const d = new fakeDateConstructor({ valueOf: function(){ return 2; } });
        \\print(d instanceof Date);
        \\print(d.getTime());
        \\print(fakeDateConstructor().indexOf('GMT') >= 0);
        \\print(Reflect.construct(fakeDateConstructor, [3], Date).getTime());
    , .{ .mode = .script, .filename = "date-constructor-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("true\n2\ntrue\n3\n", output.buffered());
}

test "constructValue AggregateError releases copied errors array owner" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("AggregateError");
    defer rt.atoms.free(name);
    const constructor = try engine.exec.construct.functionObject(rt, name);
    defer constructor.free(rt);

    const source = try core.Object.createArray(rt, null);
    defer source.value().free(rt);
    try source.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(core.JSValue.int32(1), true, true, true));
    try source.defineOwnProperty(rt, core.atom.atomFromUInt32(1), core.Descriptor.data(core.JSValue.int32(2), true, true, true));
    source.setArrayLength(2);
    try source.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(2), true, false, false));

    const baseline_objects = rt.gc.liveCount();
    const result = try engine.exec.construct.constructValue(ctx, constructor, &.{source.value()}, &.{});
    result.free(rt);
    _ = rt.runObjectCycleRemoval();

    try std.testing.expectEqual(baseline_objects, rt.gc.liveCount());
}

test "date prototype native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const date_key = try rt.internAtom("Date");
    defer rt.atoms.free(date_key);
    const set_time_key = try rt.internAtom("setTime");
    defer rt.atoms.free(set_time_key);
    const date_value = global.getProperty(date_key);
    defer date_value.free(rt);
    const date_object: *core.Object = @fieldParentPtr("header", date_value.refHeader().?);
    const prototype_value = date_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);
    const set_time_value = prototype_object.getProperty(set_time_key);
    defer set_time_value.free(rt);
    const set_time_object: *core.Object = @fieldParentPtr("header", set_time_value.refHeader().?);
    try std.testing.expect(set_time_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.core.function.nativeFunction(rt, "notDateSetTime", 1);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = set_time_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notDateSetTime", dispatch_name);

    const direct_receiver = try engine.exec.date_ops.construct(rt, &.{core.JSValue.int32(0)});
    defer direct_receiver.free(rt);
    const direct_args = [_]core.JSValue{core.JSValue.int32(1)};
    const direct_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_receiver, fake, &direct_args);
    defer direct_result.free(rt);
    try std.testing.expectEqual(@as(f64, 1), engine.exec.value_ops.numberValue(direct_result).?);

    const fake_key = try rt.internAtom("fakeDateSetTime");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.parser.compile(rt, "const d = new Date(0); print(fakeDateSetTime.call(d, { valueOf: function(){ return 1704067200000; } })); print(d.getTime());", .{ .mode = .script, .filename = "date-prototype-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [48]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("1704067200000\n1704067200000\n", output.buffered());
}

test "array static native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const array_key = try rt.internAtom("Array");
    defer rt.atoms.free(array_key);
    const is_array_key = try rt.internAtom("isArray");
    defer rt.atoms.free(is_array_key);
    const from_key = try rt.internAtom("from");
    defer rt.atoms.free(from_key);
    const array_value = global.getProperty(array_key);
    defer array_value.free(rt);
    const array_object: *core.Object = @fieldParentPtr("header", array_value.refHeader().?);
    const is_array_value = array_object.getProperty(is_array_key);
    defer is_array_value.free(rt);
    const is_array_object: *core.Object = @fieldParentPtr("header", is_array_value.refHeader().?);
    try std.testing.expect(is_array_object.nativeFunctionIdSlot().* != 0);
    const from_value = array_object.getProperty(from_key);
    defer from_value.free(rt);
    const from_object: *core.Object = @fieldParentPtr("header", from_value.refHeader().?);
    try std.testing.expect(from_object.nativeFunctionIdSlot().* != 0);

    const fake_is_array = try engine.core.function.nativeFunction(rt, "notArrayIsArray", 1);
    defer fake_is_array.free(rt);
    const fake_is_array_object: *core.Object = @fieldParentPtr("header", fake_is_array.refHeader().?);
    fake_is_array_object.nativeFunctionIdSlot().* = is_array_object.nativeFunctionIdSlot().*;
    const is_array_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_is_array_object);
    defer rt.memory.allocator.free(is_array_dispatch_name);
    try std.testing.expectEqualStrings("notArrayIsArray", is_array_dispatch_name);

    const direct_array = try engine.exec.array_builtin_ops.construct(rt, &.{core.JSValue.int32(1)});
    defer direct_array.free(rt);
    const direct_is_array_args = [_]core.JSValue{direct_array};
    const is_array_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, core.JSValue.undefinedValue(), fake_is_array, &direct_is_array_args);
    defer is_array_result.free(rt);
    try std.testing.expectEqual(true, is_array_result.asBool().?);

    const fake_from = try engine.core.function.nativeFunction(rt, "notArrayFrom", 1);
    defer fake_from.free(rt);
    const fake_from_object: *core.Object = @fieldParentPtr("header", fake_from.refHeader().?);
    fake_from_object.nativeFunctionIdSlot().* = from_object.nativeFunctionIdSlot().*;
    const from_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_from_object);
    defer rt.memory.allocator.free(from_dispatch_name);
    try std.testing.expectEqualStrings("notArrayFrom", from_dispatch_name);

    const direct_from_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, array_value, fake_from, &direct_is_array_args);
    defer direct_from_result.free(rt);
    const direct_from_array: *core.Object = @fieldParentPtr("header", direct_from_result.refHeader().?);
    try std.testing.expect(direct_from_array.isArray());
    try std.testing.expectEqual(@as(u32, 1), direct_from_array.arrayLength());

    const fake_is_array_key = try rt.internAtom("fakeArrayIsArray");
    defer rt.atoms.free(fake_is_array_key);
    try global.defineOwnProperty(rt, fake_is_array_key, core.Descriptor.data(fake_is_array, true, false, true));
    const fake_from_key = try rt.internAtom("fakeArrayFrom");
    defer rt.atoms.free(fake_from_key);
    try global.defineOwnProperty(rt, fake_from_key, core.Descriptor.data(fake_from, true, false, true));

    var parsed = try engine.parser.compile(rt, "print(fakeArrayIsArray([])); print(fakeArrayFrom.call(Array, [7, 8]).join(','));", .{ .mode = .script, .filename = "array-static-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [24]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("true\n7,8\n", output.buffered());
}

test "array prototype native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const array_key = try rt.internAtom("Array");
    defer rt.atoms.free(array_key);
    const prototype_key = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_key);
    const to_string_key = try rt.internAtom("toString");
    defer rt.atoms.free(to_string_key);
    const join_key = try rt.internAtom("join");
    defer rt.atoms.free(join_key);
    const map_key = try rt.internAtom("map");
    defer rt.atoms.free(map_key);
    const values_key = try rt.internAtom("values");
    defer rt.atoms.free(values_key);
    const array_value = global.getProperty(array_key);
    defer array_value.free(rt);
    const array_object: *core.Object = @fieldParentPtr("header", array_value.refHeader().?);
    const prototype_value = array_object.getProperty(prototype_key);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);

    const to_string_value = prototype_object.getProperty(to_string_key);
    defer to_string_value.free(rt);
    const to_string_object: *core.Object = @fieldParentPtr("header", to_string_value.refHeader().?);
    try std.testing.expect(to_string_object.nativeFunctionIdSlot().* != 0);
    const join_value = prototype_object.getProperty(join_key);
    defer join_value.free(rt);
    const join_object: *core.Object = @fieldParentPtr("header", join_value.refHeader().?);
    try std.testing.expect(join_object.nativeFunctionIdSlot().* != 0);
    const map_value = prototype_object.getProperty(map_key);
    defer map_value.free(rt);
    const map_object: *core.Object = @fieldParentPtr("header", map_value.refHeader().?);
    try std.testing.expect(map_object.nativeFunctionIdSlot().* != 0);
    const values_value = prototype_object.getProperty(values_key);
    defer values_value.free(rt);
    const values_object: *core.Object = @fieldParentPtr("header", values_value.refHeader().?);
    try std.testing.expect(values_object.nativeFunctionIdSlot().* != 0);

    const fake_join = try engine.core.function.nativeFunction(rt, "notArrayJoin", 1);
    defer fake_join.free(rt);
    const fake_join_object: *core.Object = @fieldParentPtr("header", fake_join.refHeader().?);
    fake_join_object.nativeFunctionIdSlot().* = join_object.nativeFunctionIdSlot().*;
    const join_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_join_object);
    defer rt.memory.allocator.free(join_dispatch_name);
    try std.testing.expectEqualStrings("notArrayJoin", join_dispatch_name);

    const direct_array = try engine.exec.array_builtin_ops.constructWithPrototype(rt, &.{ core.JSValue.int32(1), core.JSValue.int32(2) }, prototype_object);
    defer direct_array.free(rt);
    const separator = (try core.string.String.createUtf8(rt, ":")).value();
    defer separator.free(rt);
    const join_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_array, fake_join, &.{separator});
    defer join_result.free(rt);
    var join_text = std.ArrayList(u8).empty;
    defer join_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &join_text, join_result);
    try std.testing.expectEqualStrings("1:2", join_text.items);

    const fake_to_string = try engine.core.function.nativeFunction(rt, "notArrayToString", 0);
    defer fake_to_string.free(rt);
    const fake_to_string_object: *core.Object = @fieldParentPtr("header", fake_to_string.refHeader().?);
    fake_to_string_object.nativeFunctionIdSlot().* = to_string_object.nativeFunctionIdSlot().*;
    const to_string_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_array, fake_to_string, &.{});
    defer to_string_result.free(rt);
    var to_string_text = std.ArrayList(u8).empty;
    defer to_string_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &to_string_text, to_string_result);
    try std.testing.expectEqualStrings("1,2", to_string_text.items);

    const fake_map = try engine.core.function.nativeFunction(rt, "notArrayMap", 1);
    defer fake_map.free(rt);
    const fake_map_object: *core.Object = @fieldParentPtr("header", fake_map.refHeader().?);
    fake_map_object.nativeFunctionIdSlot().* = map_object.nativeFunctionIdSlot().*;
    const fake_values = try engine.core.function.nativeFunction(rt, "notArrayValues", 0);
    defer fake_values.free(rt);
    const fake_values_object: *core.Object = @fieldParentPtr("header", fake_values.refHeader().?);
    fake_values_object.nativeFunctionIdSlot().* = values_object.nativeFunctionIdSlot().*;

    const fake_map_key = try rt.internAtom("fakeArrayMap");
    defer rt.atoms.free(fake_map_key);
    try global.defineOwnProperty(rt, fake_map_key, core.Descriptor.data(fake_map, true, false, true));
    const fake_values_key = try rt.internAtom("fakeArrayValues");
    defer rt.atoms.free(fake_values_key);
    try global.defineOwnProperty(rt, fake_values_key, core.Descriptor.data(fake_values, true, false, true));

    var parsed = try engine.parser.compile(rt, "print(fakeArrayMap.call([1,2], function(v){ return v + 1; }).join(',')); const it = fakeArrayValues.call([9]); print(it.next().value);", .{ .mode = .script, .filename = "array-prototype-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [24]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("2,3\n9\n", output.buffered());
}

test "collection native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const map_key = try rt.internAtom("Map");
    defer rt.atoms.free(map_key);
    const set_key = try rt.internAtom("Set");
    defer rt.atoms.free(set_key);
    const prototype_key = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_key);
    const group_by_key = try rt.internAtom("groupBy");
    defer rt.atoms.free(group_by_key);
    const map_set_key = try rt.internAtom("set");
    defer rt.atoms.free(map_set_key);
    const map_for_each_key = try rt.internAtom("forEach");
    defer rt.atoms.free(map_for_each_key);
    const set_union_key = try rt.internAtom("union");
    defer rt.atoms.free(set_union_key);
    const set_values_key = try rt.internAtom("values");
    defer rt.atoms.free(set_values_key);

    const map_value = global.getProperty(map_key);
    defer map_value.free(rt);
    const map_object: *core.Object = @fieldParentPtr("header", map_value.refHeader().?);
    const group_by_value = map_object.getProperty(group_by_key);
    defer group_by_value.free(rt);
    const group_by_object: *core.Object = @fieldParentPtr("header", group_by_value.refHeader().?);
    try std.testing.expect(group_by_object.nativeFunctionIdSlot().* != 0);
    const map_prototype_value = map_object.getProperty(prototype_key);
    defer map_prototype_value.free(rt);
    const map_prototype_object: *core.Object = @fieldParentPtr("header", map_prototype_value.refHeader().?);
    const map_set_value = map_prototype_object.getProperty(map_set_key);
    defer map_set_value.free(rt);
    const map_set_object: *core.Object = @fieldParentPtr("header", map_set_value.refHeader().?);
    try std.testing.expect(map_set_object.nativeFunctionIdSlot().* != 0);
    const map_for_each_value = map_prototype_object.getProperty(map_for_each_key);
    defer map_for_each_value.free(rt);
    const map_for_each_object: *core.Object = @fieldParentPtr("header", map_for_each_value.refHeader().?);
    try std.testing.expect(map_for_each_object.nativeFunctionIdSlot().* != 0);

    const set_value = global.getProperty(set_key);
    defer set_value.free(rt);
    const set_object: *core.Object = @fieldParentPtr("header", set_value.refHeader().?);
    const set_prototype_value = set_object.getProperty(prototype_key);
    defer set_prototype_value.free(rt);
    const set_prototype_object: *core.Object = @fieldParentPtr("header", set_prototype_value.refHeader().?);
    const set_union_value = set_prototype_object.getProperty(set_union_key);
    defer set_union_value.free(rt);
    const set_union_object: *core.Object = @fieldParentPtr("header", set_union_value.refHeader().?);
    try std.testing.expect(set_union_object.nativeFunctionIdSlot().* != 0);
    const set_values_value = set_prototype_object.getProperty(set_values_key);
    defer set_values_value.free(rt);
    const set_values_object: *core.Object = @fieldParentPtr("header", set_values_value.refHeader().?);
    try std.testing.expect(set_values_object.nativeFunctionIdSlot().* != 0);

    const fake_map_set = try engine.core.function.nativeFunction(rt, "notMapSet", 2);
    defer fake_map_set.free(rt);
    const fake_map_set_object: *core.Object = @fieldParentPtr("header", fake_map_set.refHeader().?);
    fake_map_set_object.nativeFunctionIdSlot().* = map_set_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_map_set_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notMapSet", dispatch_name);

    const direct_map = try engine.exec.collection_ops.constructWithPrototype(rt, 1, map_prototype_object);
    defer direct_map.free(rt);
    const direct_key = (try core.string.String.createUtf8(rt, "direct")).value();
    defer direct_key.free(rt);
    const direct_args = [_]core.JSValue{ direct_key, core.JSValue.int32(7) };
    const direct_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_map, fake_map_set, &direct_args);
    defer direct_result.free(rt);
    try std.testing.expect(direct_result.same(direct_map));
    const direct_get_result = try engine.exec.collection_ops.methodCall(rt, direct_map, 2, &.{direct_key});
    defer direct_get_result.free(rt);
    try std.testing.expectEqual(@as(?i32, 7), direct_get_result.asInt32());

    const fake_group_by = try engine.core.function.nativeFunction(rt, "notMapGroupBy", 2);
    defer fake_group_by.free(rt);
    const fake_group_by_object: *core.Object = @fieldParentPtr("header", fake_group_by.refHeader().?);
    fake_group_by_object.nativeFunctionIdSlot().* = group_by_object.nativeFunctionIdSlot().*;
    const fake_map_for_each = try engine.core.function.nativeFunction(rt, "notMapForEach", 1);
    defer fake_map_for_each.free(rt);
    const fake_map_for_each_object: *core.Object = @fieldParentPtr("header", fake_map_for_each.refHeader().?);
    fake_map_for_each_object.nativeFunctionIdSlot().* = map_for_each_object.nativeFunctionIdSlot().*;
    const fake_set_union = try engine.core.function.nativeFunction(rt, "notSetUnion", 1);
    defer fake_set_union.free(rt);
    const fake_set_union_object: *core.Object = @fieldParentPtr("header", fake_set_union.refHeader().?);
    fake_set_union_object.nativeFunctionIdSlot().* = set_union_object.nativeFunctionIdSlot().*;
    const fake_set_values = try engine.core.function.nativeFunction(rt, "notSetValues", 0);
    defer fake_set_values.free(rt);
    const fake_set_values_object: *core.Object = @fieldParentPtr("header", fake_set_values.refHeader().?);
    fake_set_values_object.nativeFunctionIdSlot().* = set_values_object.nativeFunctionIdSlot().*;

    const fake_map_set_key = try rt.internAtom("fakeMapSet");
    defer rt.atoms.free(fake_map_set_key);
    try global.defineOwnProperty(rt, fake_map_set_key, core.Descriptor.data(fake_map_set, true, false, true));
    const fake_group_by_key = try rt.internAtom("fakeMapGroupBy");
    defer rt.atoms.free(fake_group_by_key);
    try global.defineOwnProperty(rt, fake_group_by_key, core.Descriptor.data(fake_group_by, true, false, true));
    const fake_map_for_each_key = try rt.internAtom("fakeMapForEach");
    defer rt.atoms.free(fake_map_for_each_key);
    try global.defineOwnProperty(rt, fake_map_for_each_key, core.Descriptor.data(fake_map_for_each, true, false, true));
    const fake_set_union_key = try rt.internAtom("fakeSetUnion");
    defer rt.atoms.free(fake_set_union_key);
    try global.defineOwnProperty(rt, fake_set_union_key, core.Descriptor.data(fake_set_union, true, false, true));
    const fake_set_values_key = try rt.internAtom("fakeSetValues");
    defer rt.atoms.free(fake_set_values_key);
    try global.defineOwnProperty(rt, fake_set_values_key, core.Descriptor.data(fake_set_values, true, false, true));

    var parsed = try engine.parser.compile(rt, "const grouped = fakeMapGroupBy.call(Map, ['aa', 'b'], function(v) { return v.length; }); print(grouped.get(2)[0]); const m = new Map(); fakeMapSet.call(m, 'a', 1); print(m.get('a')); fakeMapForEach.call(m, function(value, key) { print(key + ':' + value); }); const left = new Set(); left.add(1); const right = new Set(); right.add(2); const union = fakeSetUnion.call(left, right); print(Array.from(fakeSetValues.call(union)).join(','));", .{ .mode = .script, .filename = "collection-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [32]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("aa\n1\na:1\n1,2\n", output.buffered());
}

test "buffer native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const array_buffer_key = try rt.internAtom("ArrayBuffer");
    defer rt.atoms.free(array_buffer_key);
    const shared_array_buffer_key = try rt.internAtom("SharedArrayBuffer");
    defer rt.atoms.free(shared_array_buffer_key);
    const data_view_key = try rt.internAtom("DataView");
    defer rt.atoms.free(data_view_key);
    const prototype_key = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_key);
    const is_view_key = try rt.internAtom("isView");
    defer rt.atoms.free(is_view_key);
    const slice_key = try rt.internAtom("slice");
    defer rt.atoms.free(slice_key);
    const byte_length_key = try rt.internAtom("byteLength");
    defer rt.atoms.free(byte_length_key);
    const get_uint8_key = try rt.internAtom("getUint8");
    defer rt.atoms.free(get_uint8_key);
    const set_uint8_key = try rt.internAtom("setUint8");
    defer rt.atoms.free(set_uint8_key);

    const array_buffer_value = global.getProperty(array_buffer_key);
    defer array_buffer_value.free(rt);
    const array_buffer_object: *core.Object = @fieldParentPtr("header", array_buffer_value.refHeader().?);
    const is_view_value = array_buffer_object.getProperty(is_view_key);
    defer is_view_value.free(rt);
    const is_view_object: *core.Object = @fieldParentPtr("header", is_view_value.refHeader().?);
    try std.testing.expect(is_view_object.nativeFunctionIdSlot().* != 0);
    const array_buffer_prototype_value = array_buffer_object.getProperty(prototype_key);
    defer array_buffer_prototype_value.free(rt);
    const array_buffer_prototype_object: *core.Object = @fieldParentPtr("header", array_buffer_prototype_value.refHeader().?);
    const array_buffer_slice_value = array_buffer_prototype_object.getProperty(slice_key);
    defer array_buffer_slice_value.free(rt);
    const array_buffer_slice_object: *core.Object = @fieldParentPtr("header", array_buffer_slice_value.refHeader().?);
    try std.testing.expect(array_buffer_slice_object.nativeFunctionIdSlot().* != 0);
    const array_buffer_byte_length_desc = array_buffer_prototype_object.getOwnProperty(rt, byte_length_key).?;
    defer array_buffer_byte_length_desc.destroy(rt);
    const array_buffer_byte_length_getter: *core.Object = @fieldParentPtr("header", array_buffer_byte_length_desc.getter.refHeader().?);
    try std.testing.expect(array_buffer_byte_length_getter.nativeFunctionIdSlot().* != 0);

    const shared_array_buffer_value = global.getProperty(shared_array_buffer_key);
    defer shared_array_buffer_value.free(rt);
    const shared_array_buffer_object: *core.Object = @fieldParentPtr("header", shared_array_buffer_value.refHeader().?);
    const shared_array_buffer_prototype_value = shared_array_buffer_object.getProperty(prototype_key);
    defer shared_array_buffer_prototype_value.free(rt);
    const shared_array_buffer_prototype_object: *core.Object = @fieldParentPtr("header", shared_array_buffer_prototype_value.refHeader().?);
    const shared_array_buffer_slice_value = shared_array_buffer_prototype_object.getProperty(slice_key);
    defer shared_array_buffer_slice_value.free(rt);
    const shared_array_buffer_slice_object: *core.Object = @fieldParentPtr("header", shared_array_buffer_slice_value.refHeader().?);
    try std.testing.expect(shared_array_buffer_slice_object.nativeFunctionIdSlot().* != 0);

    const data_view_value = global.getProperty(data_view_key);
    defer data_view_value.free(rt);
    const data_view_object: *core.Object = @fieldParentPtr("header", data_view_value.refHeader().?);
    const data_view_prototype_value = data_view_object.getProperty(prototype_key);
    defer data_view_prototype_value.free(rt);
    const data_view_prototype_object: *core.Object = @fieldParentPtr("header", data_view_prototype_value.refHeader().?);
    const get_uint8_value = data_view_prototype_object.getProperty(get_uint8_key);
    defer get_uint8_value.free(rt);
    const get_uint8_object: *core.Object = @fieldParentPtr("header", get_uint8_value.refHeader().?);
    try std.testing.expect(get_uint8_object.nativeFunctionIdSlot().* != 0);
    const set_uint8_value = data_view_prototype_object.getProperty(set_uint8_key);
    defer set_uint8_value.free(rt);
    const set_uint8_object: *core.Object = @fieldParentPtr("header", set_uint8_value.refHeader().?);
    try std.testing.expect(set_uint8_object.nativeFunctionIdSlot().* != 0);
    const data_view_byte_length_desc = data_view_prototype_object.getOwnProperty(rt, byte_length_key).?;
    defer data_view_byte_length_desc.destroy(rt);
    const data_view_byte_length_getter: *core.Object = @fieldParentPtr("header", data_view_byte_length_desc.getter.refHeader().?);
    try std.testing.expect(data_view_byte_length_getter.nativeFunctionIdSlot().* != 0);

    const fake_is_view = try engine.core.function.nativeFunction(rt, "notArrayBufferIsView", 1);
    defer fake_is_view.free(rt);
    const fake_is_view_object: *core.Object = @fieldParentPtr("header", fake_is_view.refHeader().?);
    fake_is_view_object.nativeFunctionIdSlot().* = is_view_object.nativeFunctionIdSlot().*;
    const fake_array_buffer_slice = try engine.core.function.nativeFunction(rt, "notArrayBufferSlice", 2);
    defer fake_array_buffer_slice.free(rt);
    const fake_array_buffer_slice_object: *core.Object = @fieldParentPtr("header", fake_array_buffer_slice.refHeader().?);
    fake_array_buffer_slice_object.nativeFunctionIdSlot().* = array_buffer_slice_object.nativeFunctionIdSlot().*;
    const fake_array_buffer_byte_length = try engine.core.function.nativeFunction(rt, "notArrayBufferByteLength", 0);
    defer fake_array_buffer_byte_length.free(rt);
    const fake_array_buffer_byte_length_object: *core.Object = @fieldParentPtr("header", fake_array_buffer_byte_length.refHeader().?);
    fake_array_buffer_byte_length_object.nativeFunctionIdSlot().* = array_buffer_byte_length_getter.nativeFunctionIdSlot().*;
    const fake_shared_array_buffer_slice = try engine.core.function.nativeFunction(rt, "notSharedArrayBufferSlice", 2);
    defer fake_shared_array_buffer_slice.free(rt);
    const fake_shared_array_buffer_slice_object: *core.Object = @fieldParentPtr("header", fake_shared_array_buffer_slice.refHeader().?);
    fake_shared_array_buffer_slice_object.nativeFunctionIdSlot().* = shared_array_buffer_slice_object.nativeFunctionIdSlot().*;
    const fake_data_view_get_uint8 = try engine.core.function.nativeFunction(rt, "notDataViewGetUint8", 1);
    defer fake_data_view_get_uint8.free(rt);
    const fake_data_view_get_uint8_object: *core.Object = @fieldParentPtr("header", fake_data_view_get_uint8.refHeader().?);
    fake_data_view_get_uint8_object.nativeFunctionIdSlot().* = get_uint8_object.nativeFunctionIdSlot().*;
    const fake_data_view_set_uint8 = try engine.core.function.nativeFunction(rt, "notDataViewSetUint8", 2);
    defer fake_data_view_set_uint8.free(rt);
    const fake_data_view_set_uint8_object: *core.Object = @fieldParentPtr("header", fake_data_view_set_uint8.refHeader().?);
    fake_data_view_set_uint8_object.nativeFunctionIdSlot().* = set_uint8_object.nativeFunctionIdSlot().*;
    const fake_data_view_byte_length = try engine.core.function.nativeFunction(rt, "notDataViewByteLength", 0);
    defer fake_data_view_byte_length.free(rt);
    const fake_data_view_byte_length_object: *core.Object = @fieldParentPtr("header", fake_data_view_byte_length.refHeader().?);
    fake_data_view_byte_length_object.nativeFunctionIdSlot().* = data_view_byte_length_getter.nativeFunctionIdSlot().*;

    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_array_buffer_slice_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notArrayBufferSlice", dispatch_name);

    const direct_buffer = try engine.exec.buffer_ops.arrayBufferConstructArgs(rt, &.{core.JSValue.int32(6)}, array_buffer_prototype_object);
    defer direct_buffer.free(rt);
    const direct_slice_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_buffer, fake_array_buffer_slice, &.{ core.JSValue.int32(1), core.JSValue.int32(4) });
    defer direct_slice_result.free(rt);
    const direct_slice_object: *core.Object = @fieldParentPtr("header", direct_slice_result.refHeader().?);
    try std.testing.expectEqual(@as(usize, 3), direct_slice_object.byteStorage().len);
    const direct_length_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_buffer, fake_array_buffer_byte_length, &.{});
    defer direct_length_result.free(rt);
    try std.testing.expectEqual(@as(?i32, 6), direct_length_result.asInt32());

    const fake_is_view_key = try rt.internAtom("fakeArrayBufferIsView");
    defer rt.atoms.free(fake_is_view_key);
    try global.defineOwnProperty(rt, fake_is_view_key, core.Descriptor.data(fake_is_view, true, false, true));
    const fake_array_buffer_slice_key = try rt.internAtom("fakeArrayBufferSlice");
    defer rt.atoms.free(fake_array_buffer_slice_key);
    try global.defineOwnProperty(rt, fake_array_buffer_slice_key, core.Descriptor.data(fake_array_buffer_slice, true, false, true));
    const fake_array_buffer_byte_length_key = try rt.internAtom("fakeArrayBufferByteLength");
    defer rt.atoms.free(fake_array_buffer_byte_length_key);
    try global.defineOwnProperty(rt, fake_array_buffer_byte_length_key, core.Descriptor.data(fake_array_buffer_byte_length, true, false, true));
    const fake_shared_array_buffer_slice_key = try rt.internAtom("fakeSharedArrayBufferSlice");
    defer rt.atoms.free(fake_shared_array_buffer_slice_key);
    try global.defineOwnProperty(rt, fake_shared_array_buffer_slice_key, core.Descriptor.data(fake_shared_array_buffer_slice, true, false, true));
    const fake_data_view_get_uint8_key = try rt.internAtom("fakeDataViewGetUint8");
    defer rt.atoms.free(fake_data_view_get_uint8_key);
    try global.defineOwnProperty(rt, fake_data_view_get_uint8_key, core.Descriptor.data(fake_data_view_get_uint8, true, false, true));
    const fake_data_view_set_uint8_key = try rt.internAtom("fakeDataViewSetUint8");
    defer rt.atoms.free(fake_data_view_set_uint8_key);
    try global.defineOwnProperty(rt, fake_data_view_set_uint8_key, core.Descriptor.data(fake_data_view_set_uint8, true, false, true));
    const fake_data_view_byte_length_key = try rt.internAtom("fakeDataViewByteLength");
    defer rt.atoms.free(fake_data_view_byte_length_key);
    try global.defineOwnProperty(rt, fake_data_view_byte_length_key, core.Descriptor.data(fake_data_view_byte_length, true, false, true));

    var parsed = try engine.parser.compile(rt,
        \\const b = new ArrayBuffer(6);
        \\print(fakeArrayBufferIsView(new DataView(b)));
        \\print(fakeArrayBufferSlice.call(b, 1, 4).byteLength);
        \\print(fakeArrayBufferByteLength.call(b));
        \\const s = new SharedArrayBuffer(5);
        \\print(fakeSharedArrayBufferSlice.call(s, 1, 3).byteLength);
        \\const v = new DataView(b);
        \\fakeDataViewSetUint8.call(v, 0, 77);
        \\print(fakeDataViewGetUint8.call(v, 0));
        \\print(fakeDataViewByteLength.call(v));
    , .{ .mode = .script, .filename = "buffer-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [40]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("true\n3\n6\n2\n77\n6\n", output.buffered());
}

test "typed array accessor native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const typed_array_key = try rt.internAtom("TypedArray");
    defer rt.atoms.free(typed_array_key);
    const prototype_key = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_key);
    const byte_length_key = try rt.internAtom("byteLength");
    defer rt.atoms.free(byte_length_key);
    const length_key = try rt.internAtom("length");
    defer rt.atoms.free(length_key);

    const typed_array_value = global.getProperty(typed_array_key);
    defer typed_array_value.free(rt);
    const typed_array_object: *core.Object = @fieldParentPtr("header", typed_array_value.refHeader().?);
    const prototype_value = typed_array_object.getProperty(prototype_key);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);

    const byte_length_desc = prototype_object.getOwnProperty(rt, byte_length_key).?;
    defer byte_length_desc.destroy(rt);
    const byte_length_getter: *core.Object = @fieldParentPtr("header", byte_length_desc.getter.refHeader().?);
    try std.testing.expect(byte_length_getter.nativeFunctionIdSlot().* != 0);
    const length_desc = prototype_object.getOwnProperty(rt, length_key).?;
    defer length_desc.destroy(rt);
    const length_getter: *core.Object = @fieldParentPtr("header", length_desc.getter.refHeader().?);
    try std.testing.expect(length_getter.nativeFunctionIdSlot().* != 0);
    const tag_desc = prototype_object.getOwnProperty(rt, core.atom.predefinedId("Symbol.toStringTag", .symbol).?).?;
    defer tag_desc.destroy(rt);
    const tag_getter: *core.Object = @fieldParentPtr("header", tag_desc.getter.refHeader().?);
    try std.testing.expect(tag_getter.nativeFunctionIdSlot().* != 0);

    const fake_byte_length = try engine.core.function.nativeFunction(rt, "notTypedArrayByteLength", 0);
    defer fake_byte_length.free(rt);
    const fake_byte_length_object: *core.Object = @fieldParentPtr("header", fake_byte_length.refHeader().?);
    fake_byte_length_object.nativeFunctionIdSlot().* = byte_length_getter.nativeFunctionIdSlot().*;
    const fake_length = try engine.core.function.nativeFunction(rt, "notTypedArrayLength", 0);
    defer fake_length.free(rt);
    const fake_length_object: *core.Object = @fieldParentPtr("header", fake_length.refHeader().?);
    fake_length_object.nativeFunctionIdSlot().* = length_getter.nativeFunctionIdSlot().*;
    const fake_tag = try engine.core.function.nativeFunction(rt, "notTypedArrayTag", 0);
    defer fake_tag.free(rt);
    const fake_tag_object: *core.Object = @fieldParentPtr("header", fake_tag.refHeader().?);
    fake_tag_object.nativeFunctionIdSlot().* = tag_getter.nativeFunctionIdSlot().*;

    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_byte_length_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notTypedArrayByteLength", dispatch_name);

    const direct_buffer = try engine.exec.buffer_ops.arrayBufferConstructArgs(rt, &.{core.JSValue.int32(8)}, null);
    defer direct_buffer.free(rt);
    const direct_typed_array = try engine.exec.buffer_ops.typedArrayConstructWithOptions(rt, 1, 2, direct_buffer, &.{direct_buffer}, prototype_object);
    defer direct_typed_array.free(rt);
    const direct_byte_length = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_typed_array, fake_byte_length, &.{});
    defer direct_byte_length.free(rt);
    try std.testing.expectEqual(@as(?i32, 8), direct_byte_length.asInt32());
    const direct_length = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, direct_typed_array, fake_length, &.{});
    defer direct_length.free(rt);
    try std.testing.expectEqual(@as(?i32, 8), direct_length.asInt32());

    const fake_byte_length_key = try rt.internAtom("fakeTypedArrayByteLength");
    defer rt.atoms.free(fake_byte_length_key);
    try global.defineOwnProperty(rt, fake_byte_length_key, core.Descriptor.data(fake_byte_length, true, false, true));
    const fake_length_key = try rt.internAtom("fakeTypedArrayLength");
    defer rt.atoms.free(fake_length_key);
    try global.defineOwnProperty(rt, fake_length_key, core.Descriptor.data(fake_length, true, false, true));
    const fake_tag_key = try rt.internAtom("fakeTypedArrayTag");
    defer rt.atoms.free(fake_tag_key);
    try global.defineOwnProperty(rt, fake_tag_key, core.Descriptor.data(fake_tag, true, false, true));

    var parsed = try engine.parser.compile(rt,
        \\const ta = new Uint8Array([1, 2, 3, 4]);
        \\print(fakeTypedArrayByteLength.call(ta));
        \\print(fakeTypedArrayLength.call(ta));
        \\print(fakeTypedArrayTag.call(ta));
        \\print(fakeTypedArrayTag.call({}));
    , .{ .mode = .script, .filename = "typed-array-accessor-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [32]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("4\n4\nUint8Array\nundefined\n", output.buffered());
}

test "regexp static native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const regexp_key = try rt.internAtom("RegExp");
    defer rt.atoms.free(regexp_key);
    const escape_key = try rt.internAtom("escape");
    defer rt.atoms.free(escape_key);
    const regexp_value = global.getProperty(regexp_key);
    defer regexp_value.free(rt);
    const regexp_object: *core.Object = @fieldParentPtr("header", regexp_value.refHeader().?);
    const escape_value = regexp_object.getProperty(escape_key);
    defer escape_value.free(rt);
    const escape_object: *core.Object = @fieldParentPtr("header", escape_value.refHeader().?);
    try std.testing.expect(escape_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.core.function.nativeFunction(rt, "notRegExpEscape", 1);
    defer fake.free(rt);
    const fake_object: *core.Object = @fieldParentPtr("header", fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = escape_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.memory.allocator.free(dispatch_name);
    try std.testing.expectEqualStrings("notRegExpEscape", dispatch_name);

    const dot = try core.string.String.createUtf8(rt, ".");
    defer dot.value().free(rt);
    const direct_args = [_]core.JSValue{dot.value()};
    const direct_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, core.JSValue.undefinedValue(), fake, &direct_args);
    defer direct_result.free(rt);
    try std.testing.expect(direct_result.isString());
    const direct_result_string = direct_result.asStringBody().?;
    try std.testing.expect(direct_result_string.eqlBytes("\\."));

    const fake_key = try rt.internAtom("fakeRegExpEscape");
    defer rt.atoms.free(fake_key);
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, true, false, true));

    var parsed = try engine.parser.compile(rt, "print(fakeRegExpEscape('.')); print(fakeRegExpEscape('a+b'));", .{ .mode = .script, .filename = "regexp-static-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [24]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("\\.\n\\x61\\+b\n", output.buffered());
}

test "regexp prototype native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const regexp_key = try rt.internAtom("RegExp");
    defer rt.atoms.free(regexp_key);
    const exec_key = try rt.internAtom("exec");
    defer rt.atoms.free(exec_key);
    const test_key = try rt.internAtom("test");
    defer rt.atoms.free(test_key);
    const to_string_key = try rt.internAtom("toString");
    defer rt.atoms.free(to_string_key);
    const regexp_value = global.getProperty(regexp_key);
    defer regexp_value.free(rt);
    const regexp_object: *core.Object = @fieldParentPtr("header", regexp_value.refHeader().?);
    const prototype_value = regexp_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);
    const exec_value = prototype_object.getProperty(exec_key);
    defer exec_value.free(rt);
    const exec_object: *core.Object = @fieldParentPtr("header", exec_value.refHeader().?);
    try std.testing.expect(exec_object.nativeFunctionIdSlot().* != 0);
    const test_value = prototype_object.getProperty(test_key);
    defer test_value.free(rt);
    const test_object: *core.Object = @fieldParentPtr("header", test_value.refHeader().?);
    try std.testing.expect(test_object.nativeFunctionIdSlot().* != 0);
    const to_string_value = prototype_object.getProperty(to_string_key);
    defer to_string_value.free(rt);
    const to_string_object: *core.Object = @fieldParentPtr("header", to_string_value.refHeader().?);
    try std.testing.expect(to_string_object.nativeFunctionIdSlot().* != 0);

    const fake_exec = try engine.core.function.nativeFunction(rt, "notRegExpExec", 1);
    defer fake_exec.free(rt);
    const fake_exec_object: *core.Object = @fieldParentPtr("header", fake_exec.refHeader().?);
    fake_exec_object.nativeFunctionIdSlot().* = exec_object.nativeFunctionIdSlot().*;
    const exec_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_exec_object);
    defer rt.memory.allocator.free(exec_dispatch_name);
    try std.testing.expectEqualStrings("notRegExpExec", exec_dispatch_name);

    const fake_test = try engine.core.function.nativeFunction(rt, "notRegExpTest", 1);
    defer fake_test.free(rt);
    const fake_test_object: *core.Object = @fieldParentPtr("header", fake_test.refHeader().?);
    fake_test_object.nativeFunctionIdSlot().* = test_object.nativeFunctionIdSlot().*;
    const test_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_test_object);
    defer rt.memory.allocator.free(test_dispatch_name);
    try std.testing.expectEqualStrings("notRegExpTest", test_dispatch_name);

    const fake_to_string = try engine.core.function.nativeFunction(rt, "notRegExpToString", 0);
    defer fake_to_string.free(rt);
    const fake_to_string_object: *core.Object = @fieldParentPtr("header", fake_to_string.refHeader().?);
    fake_to_string_object.nativeFunctionIdSlot().* = to_string_object.nativeFunctionIdSlot().*;
    const to_string_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_to_string_object);
    defer rt.memory.allocator.free(to_string_dispatch_name);
    try std.testing.expectEqualStrings("notRegExpToString", to_string_dispatch_name);

    const pattern_string = try core.string.String.createUtf8(rt, "a");
    defer pattern_string.value().free(rt);
    const flags_string = try core.string.String.createUtf8(rt, "");
    defer flags_string.value().free(rt);
    const receiver = try engine.exec.regexp_ops.constructWithPrototype(rt, pattern_string.value(), flags_string.value(), prototype_object);
    defer receiver.free(rt);
    const input_string = try core.string.String.createUtf8(rt, "cat");
    defer input_string.value().free(rt);
    const direct_args = [_]core.JSValue{input_string.value()};
    const exec_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_exec, &direct_args);
    defer exec_result.free(rt);
    const exec_array: *core.Object = @fieldParentPtr("header", exec_result.refHeader().?);
    try std.testing.expect(exec_array.isArray());
    const first_match = exec_array.getProperty(core.atom.atomFromUInt32(0));
    defer first_match.free(rt);
    try std.testing.expect(first_match.isString());
    const first_match_string = first_match.asStringBody().?;
    try std.testing.expect(first_match_string.eqlBytes("a"));
    const index_key = try rt.internAtom("index");
    defer rt.atoms.free(index_key);
    const index_value = exec_array.getProperty(index_key);
    defer index_value.free(rt);
    try std.testing.expectEqual(@as(i32, 1), index_value.asInt32().?);

    const test_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_test, &direct_args);
    defer test_result.free(rt);
    try std.testing.expectEqual(true, test_result.asBool().?);

    const to_string_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_to_string, &.{});
    defer to_string_result.free(rt);
    try std.testing.expect(to_string_result.isString());
    const to_string_result_string = to_string_result.asStringBody().?;
    try std.testing.expect(to_string_result_string.eqlBytes("/a/"));

    const fake_exec_key = try rt.internAtom("fakeRegExpExec");
    defer rt.atoms.free(fake_exec_key);
    try global.defineOwnProperty(rt, fake_exec_key, core.Descriptor.data(fake_exec, true, false, true));
    const fake_test_key = try rt.internAtom("fakeRegExpTest");
    defer rt.atoms.free(fake_test_key);
    try global.defineOwnProperty(rt, fake_test_key, core.Descriptor.data(fake_test, true, false, true));
    const fake_to_string_key = try rt.internAtom("fakeRegExpToString");
    defer rt.atoms.free(fake_to_string_key);
    try global.defineOwnProperty(rt, fake_to_string_key, core.Descriptor.data(fake_to_string, true, false, true));

    var parsed = try engine.parser.compile(rt, "const r = /a/; const m = fakeRegExpExec.call(r, 'cat'); print(m[0] + ':' + m.index); print(fakeRegExpTest.call(r, 'cat')); print(fakeRegExpToString.call(r));", .{ .mode = .script, .filename = "regexp-prototype-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [32]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("a:1\ntrue\n/a/\n", output.buffered());
}

test "regexp symbol native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const regexp_key = try rt.internAtom("RegExp");
    defer rt.atoms.free(regexp_key);
    const regexp_value = global.getProperty(regexp_key);
    defer regexp_value.free(rt);
    const regexp_object: *core.Object = @fieldParentPtr("header", regexp_value.refHeader().?);
    const prototype_value = regexp_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);

    const search_value = prototype_object.getProperty(core.atom.predefinedId("Symbol.search", .symbol).?);
    defer search_value.free(rt);
    const search_object: *core.Object = @fieldParentPtr("header", search_value.refHeader().?);
    try std.testing.expect(search_object.nativeFunctionIdSlot().* != 0);
    const match_value = prototype_object.getProperty(core.atom.predefinedId("Symbol.match", .symbol).?);
    defer match_value.free(rt);
    const match_object: *core.Object = @fieldParentPtr("header", match_value.refHeader().?);
    try std.testing.expect(match_object.nativeFunctionIdSlot().* != 0);
    const match_all_value = prototype_object.getProperty(core.atom.predefinedId("Symbol.matchAll", .symbol).?);
    defer match_all_value.free(rt);
    const match_all_object: *core.Object = @fieldParentPtr("header", match_all_value.refHeader().?);
    try std.testing.expect(match_all_object.nativeFunctionIdSlot().* != 0);
    const replace_value = prototype_object.getProperty(core.atom.predefinedId("Symbol.replace", .symbol).?);
    defer replace_value.free(rt);
    const replace_object: *core.Object = @fieldParentPtr("header", replace_value.refHeader().?);
    try std.testing.expect(replace_object.nativeFunctionIdSlot().* != 0);
    const split_value = prototype_object.getProperty(core.atom.predefinedId("Symbol.split", .symbol).?);
    defer split_value.free(rt);
    const split_object: *core.Object = @fieldParentPtr("header", split_value.refHeader().?);
    try std.testing.expect(split_object.nativeFunctionIdSlot().* != 0);

    const fake_search = try engine.core.function.nativeFunction(rt, "notRegExpSearch", 1);
    defer fake_search.free(rt);
    const fake_search_object: *core.Object = @fieldParentPtr("header", fake_search.refHeader().?);
    fake_search_object.nativeFunctionIdSlot().* = search_object.nativeFunctionIdSlot().*;
    const search_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_search_object);
    defer rt.memory.allocator.free(search_dispatch_name);
    try std.testing.expectEqualStrings("notRegExpSearch", search_dispatch_name);

    const fake_match = try engine.core.function.nativeFunction(rt, "notRegExpMatch", 1);
    defer fake_match.free(rt);
    const fake_match_object: *core.Object = @fieldParentPtr("header", fake_match.refHeader().?);
    fake_match_object.nativeFunctionIdSlot().* = match_object.nativeFunctionIdSlot().*;
    const fake_match_all = try engine.core.function.nativeFunction(rt, "notRegExpMatchAll", 1);
    defer fake_match_all.free(rt);
    const fake_match_all_object: *core.Object = @fieldParentPtr("header", fake_match_all.refHeader().?);
    fake_match_all_object.nativeFunctionIdSlot().* = match_all_object.nativeFunctionIdSlot().*;
    const fake_replace = try engine.core.function.nativeFunction(rt, "notRegExpReplace", 2);
    defer fake_replace.free(rt);
    const fake_replace_object: *core.Object = @fieldParentPtr("header", fake_replace.refHeader().?);
    fake_replace_object.nativeFunctionIdSlot().* = replace_object.nativeFunctionIdSlot().*;
    const fake_split = try engine.core.function.nativeFunction(rt, "notRegExpSplit", 2);
    defer fake_split.free(rt);
    const fake_split_object: *core.Object = @fieldParentPtr("header", fake_split.refHeader().?);
    fake_split_object.nativeFunctionIdSlot().* = split_object.nativeFunctionIdSlot().*;

    const pattern_string = try core.string.String.createUtf8(rt, "a");
    defer pattern_string.value().free(rt);
    const flags_string = try core.string.String.createUtf8(rt, "");
    defer flags_string.value().free(rt);
    const receiver = try engine.exec.regexp_ops.constructWithPrototype(rt, pattern_string.value(), flags_string.value(), prototype_object);
    defer receiver.free(rt);
    const input_string = try core.string.String.createUtf8(rt, "cat");
    defer input_string.value().free(rt);
    const replacement_string = try core.string.String.createUtf8(rt, "o");
    defer replacement_string.value().free(rt);

    const one_arg = [_]core.JSValue{input_string.value()};
    const search_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_search, &one_arg);
    defer search_result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), search_result.asInt32().?);

    const match_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_match, &one_arg);
    defer match_result.free(rt);
    const match_array: *core.Object = @fieldParentPtr("header", match_result.refHeader().?);
    const match_zero = match_array.getProperty(core.atom.atomFromUInt32(0));
    defer match_zero.free(rt);
    try std.testing.expect(match_zero.isString());
    const match_zero_string = match_zero.asStringBody().?;
    try std.testing.expect(match_zero_string.eqlBytes("a"));

    const match_all_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_match_all, &one_arg);
    defer match_all_result.free(rt);
    const match_all_iterator: *core.Object = @fieldParentPtr("header", match_all_result.refHeader().?);
    try std.testing.expectEqual(core.class.ids.regexp_string_iterator, match_all_iterator.class_id);

    const replace_args = [_]core.JSValue{ input_string.value(), replacement_string.value() };
    const replace_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_replace, &replace_args);
    defer replace_result.free(rt);
    try std.testing.expect(replace_result.isString());
    const replace_result_string = replace_result.asStringBody().?;
    try std.testing.expect(replace_result_string.eqlBytes("cot"));

    const split_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_split, &one_arg);
    defer split_result.free(rt);
    const split_array: *core.Object = @fieldParentPtr("header", split_result.refHeader().?);
    try std.testing.expect(split_array.isArray());
    try std.testing.expectEqual(@as(u32, 2), split_array.arrayLength());

    const fake_search_key = try rt.internAtom("fakeRegExpSearch");
    defer rt.atoms.free(fake_search_key);
    try global.defineOwnProperty(rt, fake_search_key, core.Descriptor.data(fake_search, true, false, true));
    const fake_match_key = try rt.internAtom("fakeRegExpMatch");
    defer rt.atoms.free(fake_match_key);
    try global.defineOwnProperty(rt, fake_match_key, core.Descriptor.data(fake_match, true, false, true));
    const fake_match_all_key = try rt.internAtom("fakeRegExpMatchAll");
    defer rt.atoms.free(fake_match_all_key);
    try global.defineOwnProperty(rt, fake_match_all_key, core.Descriptor.data(fake_match_all, true, false, true));
    const fake_replace_key = try rt.internAtom("fakeRegExpReplace");
    defer rt.atoms.free(fake_replace_key);
    try global.defineOwnProperty(rt, fake_replace_key, core.Descriptor.data(fake_replace, true, false, true));
    const fake_split_key = try rt.internAtom("fakeRegExpSplit");
    defer rt.atoms.free(fake_split_key);
    try global.defineOwnProperty(rt, fake_split_key, core.Descriptor.data(fake_split, true, false, true));

    var parsed = try engine.parser.compile(rt,
        \\const r = /a/;
        \\print(fakeRegExpSearch.call(r, 'cat'));
        \\print(fakeRegExpMatch.call(r, 'cat')[0]);
        \\print(fakeRegExpMatchAll.call(r, 'cat').next().value[0]);
        \\print(fakeRegExpReplace.call(r, 'cat', 'o'));
        \\print(fakeRegExpSplit.call(r, 'cat').join('|'));
    , .{ .mode = .script, .filename = "regexp-symbol-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [48]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("1\na\na\ncot\nc|t\n", output.buffered());
}

test "regexp accessor native builtin records ignore dispatch names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try helpers.installHostGlobalsBare(rt, global);

    const regexp_key = try rt.internAtom("RegExp");
    defer rt.atoms.free(regexp_key);
    const regexp_value = global.getProperty(regexp_key);
    defer regexp_value.free(rt);
    const regexp_object: *core.Object = @fieldParentPtr("header", regexp_value.refHeader().?);
    const prototype_value = regexp_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    const prototype_object: *core.Object = @fieldParentPtr("header", prototype_value.refHeader().?);

    const source_key = try rt.internAtom("source");
    defer rt.atoms.free(source_key);
    const source_desc = prototype_object.getOwnProperty(rt, source_key).?;
    defer source_desc.destroy(rt);
    const source_getter: *core.Object = @fieldParentPtr("header", source_desc.getter.refHeader().?);
    try std.testing.expect(source_getter.nativeFunctionIdSlot().* != 0);
    const global_key = try rt.internAtom("global");
    defer rt.atoms.free(global_key);
    const global_desc = prototype_object.getOwnProperty(rt, global_key).?;
    defer global_desc.destroy(rt);
    const global_getter: *core.Object = @fieldParentPtr("header", global_desc.getter.refHeader().?);
    try std.testing.expect(global_getter.nativeFunctionIdSlot().* != 0);

    const fake_source = try engine.core.function.nativeFunction(rt, "notRegExpSourceGetter", 0);
    defer fake_source.free(rt);
    const fake_source_object: *core.Object = @fieldParentPtr("header", fake_source.refHeader().?);
    fake_source_object.nativeFunctionIdSlot().* = source_getter.nativeFunctionIdSlot().*;
    const source_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_source_object);
    defer rt.memory.allocator.free(source_dispatch_name);
    try std.testing.expectEqualStrings("notRegExpSourceGetter", source_dispatch_name);

    const fake_global = try engine.core.function.nativeFunction(rt, "notRegExpGlobalGetter", 0);
    defer fake_global.free(rt);
    const fake_global_object: *core.Object = @fieldParentPtr("header", fake_global.refHeader().?);
    fake_global_object.nativeFunctionIdSlot().* = global_getter.nativeFunctionIdSlot().*;

    const pattern_string = try core.string.String.createUtf8(rt, "a/b");
    defer pattern_string.value().free(rt);
    const flags_string = try core.string.String.createUtf8(rt, "g");
    defer flags_string.value().free(rt);
    const receiver = try engine.exec.regexp_ops.constructWithPrototype(rt, pattern_string.value(), flags_string.value(), prototype_object);
    defer receiver.free(rt);

    const source_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_source, &.{});
    defer source_result.free(rt);
    try std.testing.expect(source_result.isString());
    const source_string = source_result.asStringBody().?;
    try std.testing.expect(source_string.eqlBytes("a\\/b"));

    const global_result = try engine.exec.call.callValueWithThisGlobalsAndGlobal(ctx, null, global, &.{}, receiver, fake_global, &.{});
    defer global_result.free(rt);
    try std.testing.expectEqual(true, global_result.asBool().?);

    const fake_source_key = try rt.internAtom("fakeRegExpSourceGetter");
    defer rt.atoms.free(fake_source_key);
    try global.defineOwnProperty(rt, fake_source_key, core.Descriptor.data(fake_source, true, false, true));
    const fake_global_key = try rt.internAtom("fakeRegExpGlobalGetter");
    defer rt.atoms.free(fake_global_key);
    try global.defineOwnProperty(rt, fake_global_key, core.Descriptor.data(fake_global, true, false, true));

    var parsed = try engine.parser.compile(rt,
        \\const r = /a\/b/g;
        \\print(fakeRegExpSourceGetter.call(r));
        \\print(fakeRegExpGlobalGetter.call(r));
    , .{ .mode = .script, .filename = "regexp-accessor-native-record-dispatch.js" });
    defer parsed.deinit();
    var stack = engine.exec.stack.Stack.init(&rt.memory, ctx.stack_limit);
    defer stack.deinit(rt);
    var output_buffer: [24]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const vm_result = try engine.exec.zjs_vm.runWithArgs(ctx, &stack, &parsed.function, global.value(), &.{}, &.{}, &output, global, true, false, false);
    defer vm_result.free(rt);
    try std.testing.expect(vm_result.isUndefined());
    try std.testing.expectEqualStrings("a\\/b\ntrue\n", output.buffered());
}

test "vm collection constructors use registered prototype methods" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    helpers.registerStandardGlobalsBare(rt);
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("collection-prototype");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    const map_atom = try rt.internAtom("Map");
    defer rt.atoms.free(map_atom);
    var bytes: [7]u8 = undefined;
    bytes[0] = op.get_var;
    std.mem.writeInt(u16, bytes[1..3], 0, .little);
    bytes[3] = op.dup;
    bytes[4] = op.call_constructor;
    std.mem.writeInt(u16, bytes[5..7], 0, .little);
    function.var_ref_names = try rt.memory.alloc(core.Atom, 1);
    function.var_ref_names[0] = rt.atoms.dup(map_atom);
    try helpers.setCodeAndStackSize(&function, &bytes);

    var vm_instance = engine.exec.Vm.init(ctx);
    defer vm_instance.deinit();
    const result = try vm_instance.run(&function);
    defer result.free(rt);

    const object: *core.Object = @fieldParentPtr("header", result.refHeader().?);
    const set_key = try rt.internAtom("set");
    defer rt.atoms.free(set_key);
    try std.testing.expect(object.getPrototype() != null);
    try std.testing.expect(!object.hasOwnProperty(set_key));
    try std.testing.expect(object.hasProperty(set_key));
    try std.testing.expect(object.getPrototype().?.hasOwnProperty(set_key));
}

test "finite number formatting keeps simple decimal fast path semantics" {
    var buffer: [64]u8 = undefined;

    try std.testing.expectEqualStrings("12.5", try engine.exec.value_ops.formatFiniteNumber(&buffer, 12.5));
    try std.testing.expectEqualStrings("-12.5", try engine.exec.value_ops.formatFiniteNumber(&buffer, -12.5));
    try std.testing.expectEqualStrings("1", try engine.exec.value_ops.formatFiniteNumber(&buffer, 1.0));
    try std.testing.expectEqualStrings("0.1", try engine.exec.value_ops.formatFiniteNumber(&buffer, 0.1));
    try std.testing.expectEqualStrings("1e+21", try engine.exec.value_ops.formatFiniteNumber(&buffer, 1e21));
}

// ================== engine_smoke.zig ==================

test "qjs alignment C1 for-head lexical self-reference observes TDZ" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let caught = false;
        \\try {
        \\  for (let i = i; false; ) {}
        \\} catch (error) {
        \\  caught = error instanceof ReferenceError;
        \\}
        \\assert.sameValue(caught, true);
        \\let emptyHeadCaught = false;
        \\try {
        \\  for (let j = j; ; ) { break; }
        \\} catch (error) {
        \\  emptyHeadCaught = error instanceof ReferenceError;
        \\}
        \\assert.sameValue(emptyHeadCaught, true);
        \\let closureCaught = false;
        \\try {
        \\  for (let k = (() => k)(); false; ) {}
        \\} catch (error) {
        \\  closureCaught = error instanceof ReferenceError;
        \\}
        \\assert.sameValue(closureCaught, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "qjs alignment C2 string for-of observes patched iterator" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const saved = String.prototype[Symbol.iterator];
        \\try {
        \\  let calls = 0;
        \\  String.prototype[Symbol.iterator] = function() {
        \\    calls++;
        \\    let done = false;
        \\    return {
        \\      next() {
        \\        if (done) return { done: true };
        \\        done = true;
        \\        return { done: false, value: "X" };
        \\      }
        \\    };
        \\  };
        \\  let primitive = "";
        \\  for (const value of "ab") primitive += value;
        \\  let wrapped = "";
        \\  for (const value of new String("cd")) wrapped += value;
        \\  assert.sameValue(primitive, "X");
        \\  assert.sameValue(wrapped, "X");
        \\  assert.sameValue(calls, 2);
        \\} finally {
        \\  String.prototype[Symbol.iterator] = saved;
        \\}
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "qjs alignment C3 in operator respects null prototype" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const bare = Object.create(null);
        \\assert.sameValue("toString" in bare, false);
        \\assert.sameValue("toString" in {}, true);
        \\bare.toString = 1;
        \\assert.sameValue("toString" in bare, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "qjs alignment C4 Array instanceof follows prototype chain" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\Object.defineProperty(Array, Symbol.hasInstance, {
        \\  value: undefined,
        \\  configurable: true
        \\});
        \\try {
        \\  const detached = [];
        \\  Object.setPrototypeOf(detached, null);
        \\  assert.sameValue(detached instanceof Array, false);
        \\  assert.sameValue([] instanceof Array, true);
        \\} finally {
        \\  delete Array[Symbol.hasInstance];
        \\}
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "local reference-tail lowering preserves binding semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function compoundAssignment() {
        \\  var x = 1;
        \\  function rhs() { x = 10; return 2; }
        \\  x += rhs();
        \\  return x;
        \\}
        \\assert.sameValue(compoundAssignment(), 3);
        \\function declarationAssignment() {
        \\  var x = 1;
        \\  function rhs() { x = 10; return 2; }
        \\  var x = rhs();
        \\  return x;
        \\}
        \\assert.sameValue(declarationAssignment(), 2);
        \\function capturedLocal() {
        \\  var x = 0;
        \\  const read = () => x;
        \\  var x = 3;
        \\  return read();
        \\}
        \\assert.sameValue(capturedLocal(), 3);
        \\function dynamicWith() {
        \\  var x = 1;
        \\  const scope = { x: 2 };
        \\  with (scope) { x = 3; }
        \\  return x + ":" + scope.x;
        \\}
        \\assert.sameValue(dynamicWith(), "1:3");
        \\function directEval() {
        \\  var x = 1;
        \\  var x = eval("x = 5; 2");
        \\  return x;
        \\}
        \\assert.sameValue(directEval(), 2);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "qjs alignment const local writes throw from resolved bytecode" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function beforeDeclaration() { x = 1; const x = 2; }
        \\let beforeCaught = false;
        \\let beforeMessage = "";
        \\try { beforeDeclaration(); } catch (error) {
        \\  beforeCaught = error instanceof TypeError;
        \\  beforeMessage = error.message;
        \\}
        \\assert.sameValue(beforeCaught, true);
        \\assert.sameValue(beforeMessage, "'x' is read-only");
        \\let rhsCalls = 0;
        \\let compoundCaught = false;
        \\let compoundMessage = "";
        \\function compoundConst() {
        \\  const fixed = 1;
        \\  try { fixed += (rhsCalls = 1); } catch (error) {
        \\    compoundCaught = error instanceof TypeError;
        \\    compoundMessage = error.message;
        \\  }
        \\}
        \\compoundConst();
        \\assert.sameValue(compoundCaught, true);
        \\assert.sameValue(compoundMessage, "'fixed' is read-only");
        \\assert.sameValue(rhsCalls, 1);
        \\function sloppyName() {
        \\  return (function named() { named = 0; return typeof named; })();
        \\}
        \\assert.sameValue(sloppyName(), "function");
        \\let strictNameCaught = false;
        \\try {
        \\  (function named() { "use strict"; named = 0; })();
        \\} catch (error) {
        \\  strictNameCaught = error instanceof TypeError;
        \\}
        \\assert.sameValue(strictNameCaught, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine eval executes test262 helpers through generic call paths" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval("assert.sameValue(1 + 1, 2, 'sum');");
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    try std.testing.expectError(error.JSException, js.eval("assert.sameValue(1, 2);"));
    try std.testing.expectError(error.JSException, js.eval("throw new Test262Error('boom');"));
}

test "shared test engine reset rebuilds global shape hash buckets" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval("assert.sameValue(1 + 1, 2, 'sum');");
    result.free(js.runtime);
    try std.testing.expectError(error.JSException, js.eval("assert.sameValue(1, 2);"));
    try std.testing.expectError(error.JSException, js.eval("throw new Test262Error('boom');"));
    helpers.endSharedTest();

    const clean = helpers.sharedTestEngine();
    var output_buffer: [16]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const clean_result = try clean.evalWithOutput(
        \\"use strict";
        \\print(this === globalThis);
    , &stream);
    defer clean_result.free(clean.runtime);

    try std.testing.expect(clean_result.isUndefined());
    try std.testing.expectEqualStrings("true\n", stream.buffered());
}

test "Engine eval strips TypeScript source kind before execution" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalWithOptions(
        \\type Label = string;
        \\interface Box { value: number }
        \\const value: number = 41;
        \\function add(input: number): number { return input + 1; }
        \\assert.sameValue(add(value), 42 as number);
    , .{ .source_kind = .typescript });
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval strips TypeScript method annotations" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalWithOptions(
        \\class C { m(x: number): number { return x; } }
        \\const object = { m(x: number): number { return x + 1; } };
        \\assert.sameValue(new C().m(41), 41);
        \\assert.sameValue(object.m(41), 42);
    , .{ .source_kind = .typescript });
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval preserves as and satisfies runtime property names in TypeScript files" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalWithOptions(
        \\const obj = { as: 1, satisfies: 2 };
        \\assert.sameValue(obj.as + obj.satisfies, 3);
    , .{ .source_kind = .typescript });
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval supports TypeScript parameter properties" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var result = try js.evalWithOptions(
        \\class Box {
        \\    constructor(public value: number) {}
        \\}
        \\const b = new Box(42);
        \\b.value === 42 ? 42 : 0
    , .{ .source_kind = .typescript, .mode = .eval_indirect });
    defer result.free(js.runtime);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32());
}

test "Engine eval strips TypeScript automatically for ts filenames" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalWithOptions(
        \\const value: number = 42;
        \\assert.sameValue(value, 42);
    , .{ .filename = "sample.ts" });
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "CallSite metadata is internal" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\Error.prepareStackTrace = function(err, sites) {
        \\    var site = sites[0];
        \\    assert.sameValue("__zjs_callsite" in site, false);
        \\    assert.sameValue("__zjs_callsite_line" in site, false);
        \\    assert.sameValue(typeof site.getFunction, "function");
        \\    assert.sameValue(typeof site.getThis, "undefined");
        \\    assert.sameValue(site.hasOwnProperty("getFunction"), false);
        \\    assert.sameValue(site.toString(), "[object CallSite]");
        \\    assert.sameValue(Object.prototype.toString.call(site), "[object CallSite]");
        \\    assert.sameValue(site[Symbol.toStringTag], "CallSite");
        \\    var name = site.getFunctionName();
        \\    var file = site.getFileName();
        \\    var line = site.getLineNumber();
        \\    var column = site.getColumnNumber();
        \\    site.__zjs_callsite_function = "fakeFn";
        \\    site.__zjs_callsite_file = "fake.js";
        \\    site.__zjs_callsite_line = 999;
        \\    site.__zjs_callsite_column = 777;
        \\    assert.sameValue(site.getFunctionName(), name);
        \\    assert.sameValue(site.getFileName(), file);
        \\    assert.sameValue(site.getLineNumber(), line);
        \\    assert.sameValue(site.getColumnNumber(), column);
        \\    assert.sameValue(site.toString().indexOf("fake"), -1);
        \\    return "ok";
        \\};
        \\function inner() {
        \\    return new Error("x").stack;
        \\}
        \\assert.sameValue(inner(), "ok");
        \\Error.prepareStackTrace = undefined;
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error stack uses object method runtime names" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var object = {
        \\    return() {
        \\        return new Error("x").stack;
        \\    }
        \\};
        \\var stack = object.return();
        \\assert.sameValue(stack.indexOf("at return") >= 0, true);
        \\assert.sameValue(stack.indexOf("    at return"), 0);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "native builtin errors capture a native callsite" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var defaultStack;
        \\try {
        \\    [].map(null);
        \\} catch (error) {
        \\    defaultStack = error.stack;
        \\}
        \\assert.sameValue(defaultStack.indexOf("    at map (native)"), 0);
        \\var callStack;
        \\try {
        \\    Array.prototype.map.call([], null);
        \\} catch (error) {
        \\    callStack = error.stack;
        \\}
        \\assert.sameValue(callStack.indexOf("    at map (native)\n    at call (native)"), 0);
        \\function forwardedCallTarget() { return new Error("forwarded").stack; }
        \\var forwardedCallStack = forwardedCallTarget.call(undefined);
        \\var forwardedFirstNewline = forwardedCallStack.indexOf("\n");
        \\assert.sameValue(forwardedCallStack.indexOf("    at forwardedCallTarget"), 0);
        \\assert.sameValue(forwardedCallStack.slice(forwardedFirstNewline + 1).indexOf("    at call (native)"), 0);
        \\function forwardedCallCaller() {
        \\    var stack = forwardedCallTarget.call(undefined);
        \\    return stack + "";
        \\}
        \\var forwardedNestedStack = forwardedCallCaller();
        \\var forwardedNestedFirst = forwardedNestedStack.indexOf("\n");
        \\var forwardedNestedSecond = forwardedNestedStack.indexOf("\n", forwardedNestedFirst + 1);
        \\assert.sameValue(forwardedNestedStack.indexOf("    at forwardedCallTarget"), 0);
        \\assert.sameValue(forwardedNestedStack.slice(forwardedNestedFirst + 1).indexOf("    at call (native)"), 0);
        \\assert.sameValue(forwardedNestedStack.slice(forwardedNestedSecond + 1).indexOf("    at forwardedCallCaller"), 0);
        \\var applyStack;
        \\try {
        \\    Array.prototype.map.apply([], [null]);
        \\} catch (error) {
        \\    applyStack = error.stack;
        \\}
        \\assert.sameValue(applyStack.indexOf("    at map (native)\n    at apply (native)"), 0);
        \\var rawErrorStack;
        \\try {
        \\    String.fromCharCode(Symbol());
        \\} catch (error) {
        \\    rawErrorStack = error.stack;
        \\}
        \\assert.sameValue(rawErrorStack.indexOf("    at fromCharCode (native)"), 0);
        \\var nestedRawErrorStack;
        \\try {
        \\    [][Symbol.iterator]().next.call({});
        \\} catch (error) {
        \\    nestedRawErrorStack = error.stack;
        \\}
        \\assert.sameValue(nestedRawErrorStack.indexOf("    at next (native)\n    at call (native)"), 0);
        \\var arrayConstructStack;
        \\try { new Array(-1); } catch (error) { arrayConstructStack = error.stack; }
        \\assert.sameValue(arrayConstructStack.indexOf("    at Array (native)"), 0);
        \\var regexpConstructStack;
        \\try { new RegExp("["); } catch (error) { regexpConstructStack = error.stack; }
        \\assert.sameValue(regexpConstructStack.indexOf("    at RegExp (native)"), 0);
        \\var regexpCallStack;
        \\try { RegExp("["); } catch (error) { regexpCallStack = error.stack; }
        \\assert.sameValue(regexpCallStack.indexOf("    at RegExp (native)"), 0);
        \\assert.sameValue(regexpCallStack.indexOf("    at <anonymous> (native)"), -1);
        \\var stringConstructStack;
        \\try { new String(Symbol()); } catch (error) { stringConstructStack = error.stack; }
        \\assert.sameValue(stringConstructStack.indexOf("    at String (native)"), 0);
        \\var dateConstructStack;
        \\try { new Date(Symbol()); } catch (error) { dateConstructStack = error.stack; }
        \\assert.sameValue(dateConstructStack.indexOf("    at Date (native)"), 0);
        \\Error.prepareStackTrace = function(_, sites) {
        \\    return sites.map(function(site) {
        \\        return [site.getFunctionName(), site.isNative()];
        \\    });
        \\};
        \\function outerMapBacktrace() {
        \\    return [1].map(function callback() {
        \\        return new Error("cross-machine").stack;
        \\    })[0];
        \\}
        \\var crossMachineSites = outerMapBacktrace();
        \\assert.sameValue(crossMachineSites[0][0], "callback");
        \\assert.sameValue(crossMachineSites[0][1], false);
        \\assert.sameValue(crossMachineSites[1][0], "map");
        \\assert.sameValue(crossMachineSites[1][1], true);
        \\assert.sameValue(crossMachineSites[2][0], "outerMapBacktrace");
        \\assert.sameValue(crossMachineSites[2][1], false);
        \\Error.prepareStackTrace = undefined;
        \\Error.prepareStackTrace = function(error, sites) {
        \\    assert.sameValue(sites[0].getFunctionName(), "map");
        \\    assert.sameValue(sites[0].getFileName(), null);
        \\    assert.sameValue(sites[0].getLineNumber(), null);
        \\    assert.sameValue(sites[0].getColumnNumber(), null);
        \\    assert.sameValue(sites[0].isNative(), true);
        \\    assert.sameValue(sites[1].getFunctionName(), "call");
        \\    assert.sameValue(sites[1].isNative(), true);
        \\    assert.sameValue(sites[2].isNative(), false);
        \\    return "native:map:call";
        \\};
        \\try {
        \\    Array.prototype.map.call([], null);
        \\} catch (error) {
        \\    assert.sameValue(error.stack, "native:map:call");
        \\}
        \\Error.prepareStackTrace = undefined;
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error stack preserves construction frames across delayed access" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function makeError() {
        \\    return new Error("x");
        \\}
        \\var err = makeError();
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(err, "stack"), false);
        \\function readStack(error) {
        \\    return error.stack;
        \\}
        \\var stack = readStack(err);
        \\assert.sameValue(typeof stack, "string");
        \\assert.sameValue(stack.indexOf("at makeError") >= 0, true);
        \\assert.sameValue(stack.indexOf("at readStack") < 0, true);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "eval SyntaxError carries construction stack" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Pins the createNamedError stack capture: the SyntaxError materialized
    // for a failed `eval` parse used to carry no call sites, so a delayed
    // `.stack` read fell back to the reader's frames and lost the
    // construction frame ("at evalThrower" was absent before the fix).
    const result = try js.eval(
        \\function evalThrower() {
        \\    try { eval("]"); } catch (e) { return e; }
        \\    return null;
        \\}
        \\var evalErr = evalThrower();
        \\assert.sameValue(evalErr instanceof SyntaxError, true);
        \\var evalStack = evalErr.stack;
        \\assert.sameValue(typeof evalStack, "string");
        \\assert.sameValue(evalStack.length > 0, true);
        \\assert.sameValue(evalStack.indexOf("at evalThrower") >= 0, true);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "TypeError thrown via message helper carries stack exactly once" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Pins the throw*Message relocation: the TypeError thrown for calling a
    // non-callable keeps its construction stack ("at typeThrower"), and the
    // frame appears exactly once (no double attach from the former
    // shell-level capture plus the primitive-level capture).
    const result = try js.eval(
        \\function typeThrower() {
        \\    try { (0)(); } catch (e) { return e; }
        \\    return null;
        \\}
        \\var typeErr = typeThrower();
        \\assert.sameValue(typeErr instanceof TypeError, true);
        \\var typeStack = typeErr.stack;
        \\assert.sameValue(typeof typeStack, "string");
        \\assert.sameValue(typeStack.length > 0, true);
        \\assert.sameValue(typeStack.indexOf("at typeThrower") >= 0, true);
        \\assert.sameValue(typeStack.indexOf("at typeThrower"), typeStack.lastIndexOf("at typeThrower"));
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error prepareStackTrace formats captured frames lazily" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var calls = 0;
        \\Error.prepareStackTrace = function() {
        \\    calls++;
        \\    return "early";
        \\};
        \\function makeError() {
        \\    return new Error("x");
        \\}
        \\var err = makeError();
        \\assert.sameValue(calls, 0);
        \\Error.prepareStackTrace = function(error, sites) {
        \\    calls++;
        \\    assert.sameValue(error, err);
        \\    assert.sameValue(sites[0].getFunctionName(), "makeError");
        \\    return "late:" + sites[0].getFunctionName();
        \\};
        \\assert.sameValue(err.stack, "late:makeError");
        \\assert.sameValue(calls, 1);
        \\assert.sameValue(err.stack, "late:makeError");
        \\assert.sameValue(calls, 1);
        \\Error.prepareStackTrace = undefined;
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error stack setter rejects non-string stack values" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var err = new Error("x");
        \\assert.throws(TypeError, function() {
        \\    err.stack = 123;
        \\});
        \\assert.throws(TypeError, function() {
        \\    Object.getOwnPropertyDescriptor(Error.prototype, "stack").set.call(err);
        \\});
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(err, "stack"), false);
        \\assert.sameValue(typeof err.stack, "string");
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error stack copied accessor setter writes without recursion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var err = new Error("x");
        \\Object.defineProperty(err, "stack", Object.getOwnPropertyDescriptor(Error.prototype, "stack"));
        \\assert.throws(TypeError, function() {
        \\    err.stack = 123;
        \\});
        \\err.stack = "updated";
        \\var desc = Object.getOwnPropertyDescriptor(err, "stack");
        \\assert.sameValue(desc.value, "updated");
        \\assert.sameValue(desc.writable, true);
        \\assert.sameValue(err.stack, "updated");
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error stack copied accessor setter writes through proxy without recursion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var proxy = new Proxy(new Error("x"), {});
        \\Object.defineProperty(proxy, "stack", Object.getOwnPropertyDescriptor(Error.prototype, "stack"));
        \\proxy.stack = "updated";
        \\var desc = Object.getOwnPropertyDescriptor(proxy, "stack");
        \\assert.sameValue(desc.value, "updated");
        \\assert.sameValue(desc.writable, true);
        \\assert.sameValue(proxy.stack, "updated");
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error stack reentrant formatting is capped to captured frames" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var previousLimit = Error.stackTraceLimit;
        \\Error.stackTraceLimit = 1;
        \\var calls = 0;
        \\Error.prepareStackTrace = function(error, sites) {
        \\    calls++;
        \\    sites.length = 3;
        \\    sites[2] = sites[0];
        \\    return error.stack;
        \\};
        \\var stack = new Error("x").stack;
        \\Error.prepareStackTrace = undefined;
        \\Error.stackTraceLimit = previousLimit;
        \\var frames = String(stack).split("\n").filter(function(line) {
        \\    return line.indexOf("    at ") === 0;
        \\});
        \\assert.sameValue(calls, 1);
        \\assert.sameValue(frames.length, 1);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Array fill respects proxy prototypes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var calls = [];
        \\var array = new Array(3);
        \\Object.setPrototypeOf(array, new Proxy(Array.prototype, {
        \\    set: function(target, key, value, receiver) {
        \\        calls.push(String(key) + ":" + value);
        \\        return Reflect.set(target, key, value, receiver);
        \\    }
        \\}));
        \\Array.prototype.fill.call(array, 7);
        \\assert.sameValue(calls.join(","), "0:7,1:7,2:7");
        \\assert.sameValue(array.join(","), "7,7,7");
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Error.prepareStackTrace exceptions produce null stack" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\Error.prepareStackTrace = function() {
        \\    throw new TypeError("prep");
        \\};
        \\assert.sameValue(new Error("x").stack, null);
        \\Error.prepareStackTrace = undefined;
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine runtime-strict file eval matches QuickJS CLI script surface" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileWithOutputModeRuntimeStrict(
        \\function strictThis() { return this === undefined; }
        \\function cliLocalFunction() {}
        \\print(this === undefined);
        \\print(strictThis());
        \\var desc = Object.getOwnPropertyDescriptor(globalThis, "cliLocalFunction");
        \\print(desc === undefined);
        \\print(cliLocalFunction.name);
        \\var roProto = {};
        \\Object.defineProperty(roProto, "locked", { value: 1, writable: false, configurable: true });
        \\var roObj = Object.create(roProto);
        \\try { roObj.locked = 2; print(false); } catch (e) { print(e instanceof TypeError); }
        \\try { missingQuickJsCliStrict = 1; print(false); } catch (e) { print(e instanceof ReferenceError); }
        \\var capture;
        \\eval("var evalCreated = 5; capture = function(){ return evalCreated; };");
        \\print(evalCreated);
        \\print(delete evalCreated);
        \\try { print(capture()); } catch (e) { print(e instanceof ReferenceError); }
    , &stream, .script, "runtime-strict-file.js", true);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\ntrue\ntrue\ncliLocalFunction\ntrue\ntrue\n5\ntrue\ntrue\n", stream.buffered());
}

test "runtime-strict eval overrides parse-time mapped arguments subtype" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [96]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileWithOutputModeRuntimeStrict(
        \\function forcedArguments(value) {
        \\  const before = arguments[0];
        \\  value = 7;
        \\  arguments[0] = 9;
        \\  let callee = "no-throw";
        \\  try { arguments.callee; } catch (error) { callee = error.name; }
        \\  print(before, value, arguments[0], callee);
        \\}
        \\forcedArguments(5);
    , &output, .script, "runtime-strict-arguments.js", true);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("5 7 9 TypeError\n", output.buffered());
}

test "Engine strict script top-level this remains the global object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\"use strict";
        \\print(this === globalThis);
        \\function strictThis() { return this === undefined; }
        \\print(strictThis());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\ntrue\n", stream.buffered());
}

test "Engine direct eval publishes Annex B block functions" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\eval("{ function annexBEvalGlobalFn() { return 'global'; } }");
        \\assert.sameValue(annexBEvalGlobalFn(), "global");
        \\delete globalThis.annexBEvalGlobalFn;
        \\
        \\var init, changed, localAfter, functionAfter;
        \\(function() {
        \\  eval("init = annexBEvalLocalFn; annexBEvalLocalFn = 123; changed = annexBEvalLocalFn; { function annexBEvalLocalFn() { return 'local'; } } localAfter = annexBEvalLocalFn();");
        \\  functionAfter = annexBEvalLocalFn();
        \\}());
        \\assert.sameValue(init, undefined);
        \\assert.sameValue(changed, 123);
        \\assert.sameValue(localAfter, "local");
        \\assert.sameValue(functionAfter, "local");
        \\assert.throws(ReferenceError, function() { annexBEvalLocalFn; });
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine direct eval Annex B block function updates same-name parameter" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var init, after;
        \\(function(f) {
        \\  eval("init = f; { function f() {} } after = f;");
        \\}(123));
        \\print(init);
        \\print(typeof after);
        \\print(after());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("123\nfunction\nundefined\n", stream.buffered());
}

test "Engine eval exit releases frame var-ref cycles before cycle collection" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\{
        \\    let self = function() { return self; };
        \\}
    );
    result.free(js.runtime);

    try std.testing.expectEqual(@as(usize, 0), js.runtime.runObjectCycleRemoval());
}

test "Engine eval supports Annex B escape and unescape code-unit semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(escape('\u0100\u0101\u0102'), '%u0100%u0101%u0102');
        \\assert.sameValue(escape('\ufffd\ufffe\uffff'), '%uFFFD%uFFFE%uFFFF');
        \\assert.sameValue(escape('\ud834\udf06'), '%uD834%uDF06');
        \\assert.sameValue(escape('{|}~\x7f\x80'), '%7B%7C%7D%7E%7F%80');
        \\assert.sameValue(unescape('%0%FE00'), '%0\xfe00');
        \\assert.sameValue(escape(unescape('%u0100')), '%u0100');
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval supports Annex B Date setYear ordering" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var dt = new Date(0);
        \\var called = 0;
        \\var value = { valueOf: function() { called++; dt.setTime(NaN); return 1; } };
        \\var result = dt.setYear(value);
        \\assert.sameValue(called, 1);
        \\assert.notSameValue(result, NaN);
        \\assert.sameValue(result, dt.getTime());
        \\assert.sameValue(dt.getYear(), 1);
        \\assert.throws(TypeError, function() { dt.setYear(Symbol("x")); });
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval supports Annex B String HTML wrappers and trim aliases" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue("_".big(), "<big>_</big>");
        \\assert.sameValue(String.prototype.big.call(0x2A), "<big>42</big>");
        \\assert.sameValue("x".anchor('a"b'), '<a name="a&quot;b">x</a>');
        \\assert.sameValue(String.prototype.trimLeft, String.prototype.trimStart);
        \\assert.sameValue(String.prototype.trimLeft.name, "trimStart");
        \\assert.sameValue(Number.isNaN("x"), false);
        \\assert.sameValue(Number.isFinite(1), true);
        \\assert.sameValue(Number.isFinite("1"), false);
        \\assert.sameValue(isFinite("1"), true);
        \\assert.sameValue(isFinite(Infinity), false);
        \\assert.sameValue(Math.trunc(-1.9), -1);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval TypeError with evaluated arguments does not double free constants" {
    {
        var js = try helpers.TestEngine.init(std.testing.allocator);
        defer js.deinit();
        try std.testing.expectError(error.TypeError, js.eval("const obj = {}; obj.missing(\"a\", \"a\");"));
    }
    {
        var js = try helpers.TestEngine.init(std.testing.allocator);
        defer js.deinit();
        try std.testing.expectError(error.TypeError, js.eval("RegExp.test(\"a\", \"a\");"));
    }
}

test "vm call handler accepts allocator-backed argument lists" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    helpers.registerStandardGlobalsBare(rt);
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("wide-call");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    const print_key = try rt.internAtom("print");
    defer rt.atoms.free(print_key);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try bytes.append(rt.memory.allocator, op.get_var);
    var print_ref: [2]u8 = undefined;
    std.mem.writeInt(u16, &print_ref, 0, .little);
    try bytes.appendSlice(rt.memory.allocator, &print_ref);
    function.var_ref_names = try rt.memory.alloc(core.Atom, 1);
    function.var_ref_names[0] = rt.atoms.dup(print_key);
    var arg: i32 = 1;
    while (arg <= 40) : (arg += 1) {
        try bytes.append(rt.memory.allocator, op.push_i32);
        try bytes.appendSlice(rt.memory.allocator, std.mem.asBytes(&arg));
    }
    try bytes.append(rt.memory.allocator, op.call);
    const argc: u16 = 40;
    try bytes.appendSlice(rt.memory.allocator, std.mem.asBytes(&argc));
    try helpers.setCodeAndStackSize(&function, bytes.items);

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    var vm_instance = engine.exec.Vm.initWithOutput(ctx, &stream);
    defer vm_instance.deinit();
    const result = try vm_instance.run(&function);
    defer result.free(rt);

    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(std.testing.allocator);
    var expected_arg: i32 = 1;
    while (expected_arg <= 40) : (expected_arg += 1) {
        if (expected_arg != 1) try expected.append(std.testing.allocator, ' ');
        var int_buf: [16]u8 = undefined;
        const printed = try std.fmt.bufPrint(&int_buf, "{d}", .{expected_arg});
        try expected.appendSlice(std.testing.allocator, printed);
    }
    try expected.append(std.testing.allocator, '\n');

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(expected.items, stream.buffered());
}

test "Engine API eval and job queue are wired" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval("1 2");
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    helpers.job_counter = 0;
    try js.runtime.job_queue.enqueueFunc(js.context, countJob, &.{});
    try js.runtime.job_queue.enqueueFunc(js.context, countJob, &.{});
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 2), helpers.job_counter);

    helpers.job_counter = 0;
    var i: usize = 0;
    while (i < 16) : (i += 1) try js.runtime.job_queue.enqueueFunc(js.context, countJob, &.{});
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 16), helpers.job_counter);

    helpers.job_counter = 0;
    try js.runtime.job_queue.enqueueFunc(js.context, countJobArgs, &.{ core.JSValue.int32(2), core.JSValue.int32(3) });
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 5), helpers.job_counter);

    helpers.job_counter = 0;
    try js.runtime.job_queue.enqueueFunc(js.context, countJobArgs, &.{
        core.JSValue.int32(1),
        core.JSValue.int32(2),
        core.JSValue.int32(3),
        core.JSValue.int32(4),
        core.JSValue.int32(5),
    });
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 15), helpers.job_counter);

    try std.testing.expectError(error.TooManyJobArgs, js.runtime.job_queue.enqueueFunc(js.context, countJobArgs, &.{
        core.JSValue.int32(1),
        core.JSValue.int32(2),
        core.JSValue.int32(3),
        core.JSValue.int32(4),
        core.JSValue.int32(5),
        core.JSValue.int32(6),
    }));
    try std.testing.expectEqual(@as(usize, 0), js.runtime.job_queue.jobs.len);
}

test "job queue enqueue propagates allocator failure" {
    var buffer: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var account = core.memory.MemoryAccount.init(fixed.allocator());
    var queue = engine.exec.jobs.Queue.init(&account);
    defer queue.deinit();

    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    try std.testing.expectError(error.OutOfMemory, queue.enqueueFunc(js.context, countJob, &.{}));
    try std.testing.expectEqual(@as(usize, 0), queue.jobs.len);
}

test "job queue keeps symbol arguments rooted until release" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var queue = engine.exec.jobs.Queue.init(&rt.memory);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-job-queue-symbol");
    const symbol_value = try rt.symbolValue(symbol_atom);
    try queue.enqueueFunc(ctx, countJob, &.{symbol_value});
    symbol_value.free(rt);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    queue.deinit();
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "job queue symbol roots preserve weak map values" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var queue = engine.exec.jobs.Queue.init(&rt.memory);

    const weak_map = try core.Object.create(rt, core.class.ids.weakmap, null);
    defer weak_map.value().free(rt);

    const value = try core.Object.create(rt, core.class.ids.object, null);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-job-queue-weak-key");
    const weak_key = try rt.symbolValue(symbol_atom);
    try engine.exec.collection_ops.setWeakMapEntry(rt, weak_map, weak_key, value.value());

    const queued_key = weak_key.dup();
    try queue.enqueueFunc(ctx, countJob, &.{queued_key});
    queued_key.free(rt);
    weak_key.free(rt);
    value.value().free(rt);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    if (!core.memory.force_gc_on_allocation_enabled) {
        try std.testing.expectEqual(@as(usize, 1), weak_map.weakCollectionEntries().len);
        try std.testing.expectEqual(&value.header, weak_map.weakCollectionEntries()[0].value.refHeader().?);
    } else {
        // TODO(S3): weak-collection liveness under forced GC.
    }

    queue.deinit();
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
    try std.testing.expectEqual(@as(usize, 0), weak_map.weakCollectionEntries().len);
}

test "Engine eval executes simple variable assignment and print" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("let value = 5; value = value + 7; print(value);", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("12\n", stream.buffered());
}

test "Engine eval preserves global lexical write fast path semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let g = 0;
        \\g = 1;
        \\function setGlobal() { g = g + 2; }
        \\setGlobal();
        \\print(g);
        \\const c = 1;
        \\try { c = 2; } catch (e) { print(e.name, c); }
        \\let shadow = "global";
        \\function localShadow() { let shadow = "local"; shadow = "changed"; return shadow; }
        \\print(localShadow(), shadow);
        \\let withTarget = { g: 10 };
        \\with (withTarget) { g = 11; }
        \\print(g, withTarget.g);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\nTypeError 1\nchanged global\n3 11\n", stream.buffered());
}

test "Engine eval preserves selected with references during updates" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function updateDeletedProperty() {
        \\  var x = 0;
        \\  var scope = { get x() { delete this.x; return 2; } };
        \\  with (scope) { x *= 3; }
        \\  print(scope.x, x);
        \\}
        \\updateDeletedProperty();
        \\var probes = 0, outer = { x: 7 }, inner, flag = true;
        \\with (outer) {
        \\  with (inner = {
        \\    x: 4,
        \\    get [Symbol.unscopables]() {
        \\      probes++;
        \\      return { x: flag = !flag };
        \\    }
        \\  }) { x++; }
        \\}
        \\print(probes, outer.x, inner.x, flag);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("6 0\n1 7 5 false\n", stream.buffered());
}

test "Engine destructuring snapshots with binding references before property reads" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var log = [];
        \\var sourceKey = { toString: function() { log.push('sourceKey'); return 'p'; } };
        \\var source = { get p() { log.push('get source'); return undefined; } };
        \\var env = new Proxy({}, { has: function(_, key) { log.push('binding::' + key); return false; } });
        \\var defaultValue = 0;
        \\var varTarget;
        \\with (env) { var { [sourceKey]: varTarget = defaultValue } = source; }
        \\print(varTarget, log.join('|'));
        \\log = [];
        \\var target = { selected: 'old' };
        \\var selected = 'local';
        \\var selectedSource = { get p() { log.push('get selected'); return 9; } };
        \\var selectedEnv = new Proxy(target, {
        \\  has: function(_, key) { log.push('has:' + key); return key === 'selected'; }
        \\});
        \\with (selectedEnv) { var { p: selected } = selectedSource; }
        \\print(selected, target.selected, log.join('|'));
        \\(function() {
        \\  var [x, readX] = [1, function() { return x; }];
        \\  print(x, readX());
        \\})();
        \\(function() {
        \\  var [readY, { p: y }] = [function() { return y; }, { p: 13 }];
        \\  print(y, readY());
        \\})();
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "0 binding::source|binding::sourceKey|sourceKey|binding::varTarget|get source|binding::defaultValue\n" ++
            "local 9 has:selectedSource|has:selected|get selected|has:selected\n" ++
            "1 1\n13 13\n",
        stream.buffered(),
    );
}

test "Engine with destructuring assignment reaches const fallback at runtime" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function fallback() {
        \\  const x = 0;
        \\  with ({}) ({ x } = { x: 1 });
        \\}
        \\let caught = false;
        \\try { fallback(); } catch (error) { caught = error instanceof TypeError; }
        \\assert.sameValue(caught, true);
        \\function dynamicBinding() {
        \\  const x = 0;
        \\  const scope = { x: 2 };
        \\  with (scope) ({ x } = { x: 3 });
        \\  return [x, scope.x];
        \\}
        \\const values = dynamicBinding();
        \\assert.sameValue(values[0], 0);
        \\assert.sameValue(values[1], 3);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine eval preserves assignment references across direct eval" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function simpleAssignment() {
        \\  var x = 0;
        \\  var inner = (function() {
        \\    x = (eval("var x;"), 1);
        \\    return x;
        \\  })();
        \\  print(inner, x);
        \\}
        \\function compoundAssignment() {
        \\  var x = 3;
        \\  var inner = (function() {
        \\    x *= (eval("var x = 2;"), 4);
        \\    return x;
        \\  })();
        \\  print(inner, x);
        \\}
        \\function initializerAssignment() {
        \\  var x = 0;
        \\  var inner = (function() {
        \\    var value = (x = (eval("var x;"), 1));
        \\    return [x, value];
        \\  })();
        \\  print(inner[0], inner[1], x);
        \\}
        \\function templateAssignment() {
        \\  var x = 3;
        \\  var inner = (function() {
        \\    x += `${eval("var x = 2;")}`;
        \\    return x;
        \\  })();
        \\  print(inner, x);
        \\}
        \\simpleAssignment();
        \\compoundAssignment();
        \\initializerAssignment();
        \\templateAssignment();
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "undefined 1\n2 12\nundefined 1 1\n2 3undefined\n",
        stream.buffered(),
    );
}

test "Engine arrow eval preserves assignment references across direct eval" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function outer() {
        \\  var x = 0;
        \\  var simple = () => { x = (eval("var x;"), 1); return x; };
        \\  print(simple(), x);
        \\  x = 3;
        \\  var compound = () => { x *= (eval("var x = 2;"), 4); return x; };
        \\  print(compound(), x);
        \\  x = 0;
        \\  var initializer = () => {
        \\    var value = (x = (eval("var x;"), 1));
        \\    return [x, value];
        \\  };
        \\  var initialized = initializer();
        \\  print(initialized[0], initialized[1], x);
        \\  x = 3;
        \\  var template = () => { x += `${eval("var x = 2;")}`; return x; };
        \\  print(template(), x);
        \\}
        \\outer();
        \\const parameterEval = (
        \\  p = eval("var arguments = 'parameter'"),
        \\  readParameterArguments = () => arguments
        \\) => {
        \\  var arguments = "body";
        \\  return [arguments, readParameterArguments()];
        \\};
        \\const parameterEvalResult = parameterEval();
        \\assert.sameValue(parameterEvalResult[0], "body");
        \\assert.sameValue(parameterEvalResult[1], "parameter");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "undefined 1\n2 12\nundefined 1 1\n2 3undefined\n",
        stream.buffered(),
    );
}

test "Engine direct eval captures the caller arguments binding" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function direct(value) { return eval("arguments[0]"); }
        \\function throughArrow(value) { return (() => eval("arguments[0]"))(); }
        \\function replace(value) {
        \\  var old = arguments;
        \\  var read = eval("arguments[0]");
        \\  eval("arguments = ['replaced']");
        \\  return [read, arguments[0], old === arguments];
        \\}
        \\function parameterShadow(arguments) {
        \\  eval("arguments = 'updated'");
        \\  return arguments;
        \\}
        \\function parameterClosure(h = () => arguments) {
        \\  var arguments = 0;
        \\  return arguments === h();
        \\}
        \\function parameterClosureNoInit(h = () => arguments) {
        \\  var arguments;
        \\  var before = [void 0 === arguments, h() === arguments];
        \\  arguments = 0;
        \\  return [before[0], before[1], arguments === h()];
        \\}
        \\var closed1, closed2, closedBody;
        \\function parameterEvalClosed(
        \\  _ = (eval("var scoped = 'inside'"), closed1 = function() { return scoped; }),
        \\  __ = closed2 = function() { return scoped; }
        \\) { closedBody = function() { return scoped; }; }
        \\var open1, open2;
        \\function parameterEvalOpen(
        \\  _ = open1 = function() { return opened; },
        \\  __ = (eval("var opened = 'inside'"), open2 = function() { return opened; })
        \\) {}
        \\var replaced = replace(41);
        \\parameterEvalClosed();
        \\parameterEvalOpen();
        \\print(direct(41), throughArrow(42));
        \\print(replaced[0], replaced[1], replaced[2], parameterShadow('old'));
        \\print(closed1(), closed2(), closedBody());
        \\print(open1(), open2());
        \\var noInit = parameterClosureNoInit();
        \\print(parameterClosure(), noInit[0], noInit[1], noInit[2]);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "41 42\n41 replaced false updated\ninside inside inside\ninside inside\nfalse false true false\n",
        stream.buffered(),
    );
}

test "Engine arguments writes prefer the current function binding over outer lexical bindings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let arguments = 'outer';
        \\function ordinary() {
        \\  arguments = 'ordinary';
        \\  return arguments;
        \\}
        \\function parameterDefault(value = (arguments = 'parameter')) {
        \\  return value + ' ' + arguments;
        \\}
        \\function parameterArrow(value = () => (arguments = 'parameter-arrow')) {
        \\  return value() + ' ' + arguments;
        \\}
        \\function explicitParameter(arguments = 'old', value = (arguments = 'new')) {
        \\  return arguments;
        \\}
        \\function destructuredParameter({ arguments } = { arguments: 'old' }, value = (arguments = 'new')) {
        \\  return arguments;
        \\}
        \\var arrow = () => {
        \\  arguments = 'arrow';
        \\  return arguments;
        \\};
        \\print(ordinary(), arguments);
        \\print(parameterDefault(), arguments);
        \\print(parameterArrow(), arguments);
        \\print(explicitParameter(), destructuredParameter());
        \\print(arrow(), arguments);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "ordinary outer\nparameter parameter outer\nparameter-arrow parameter-arrow outer\nold new\narrow arrow\n",
        stream.buffered(),
    );
}

test "Engine direct eval shares top-level lexical cells across nested closures" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let x = 500;
        \\function direct() { return eval("x"); }
        \\function write() { eval("x = 501"); }
        \\var nested = eval("() => eval('x')");
        \\var env = { x: 9000, [Symbol.unscopables]: { x: true } };
        \\function makeAdder() {
        \\  with (env) return eval("y => eval('x + y')");
        \\}
        \\var catchValue = 'global';
        \\var catchLog = '';
        \\function catchEval() {
        \\  try { throw 8; } catch (catchValue) {
        \\    eval("var catchValue = 42");
        \\    catchLog += catchValue;
        \\  }
        \\  catchValue = 'local';
        \\  catchLog += catchValue;
        \\}
        \\function preserveEvalVar() {
        \\  eval("var saved = 1");
        \\  eval("var saved");
        \\  return saved;
        \\}
        \\print(direct(), nested());
        \\write();
        \\print(x, makeAdder()(10));
        \\catchEval();
        \\print(catchValue, catchLog);
        \\print(preserveEvalVar());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("500 500\n501 511\nglobal 42local\n1\n", stream.buffered());
}

test "Engine constructor parameter defaults use the initialized this binding" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\class A {
        \\  #x = 'hello';
        \\  constructor(value = this.#x) { this.value = value; }
        \\}
        \\var a = new A();
        \\print(a.value);
        \\class B extends A {
        \\  constructor() { super(); print('value' in this, this.value); }
        \\}
        \\new B();
        \\class C extends A {
        \\  constructor(value = this) { super(value); }
        \\}
        \\try { new C(); } catch (error) { print(error.name); }
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("hello\ntrue hello\nReferenceError\n", stream.buffered());
}

test "Engine eval assigns contextual await bindings in sloppy scripts" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [16]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var await = 0;
        \\await = 1;
        \\print(await);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n", stream.buffered());
}

test "Engine eval creates non-configurable enumerable global var bindings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(delete __globalVar);
        \\var __globalVar = "defined";
        \\print(__globalVar);
        \\print(delete __globalVar, delete this["__globalVar"]);
        \\var seen = false;
        \\for (var key in this) { if (key === "__globalVar") seen = true; }
        \\print(seen);
        \\var first = 1, second = first + 1, third;
        \\print(first, second, third);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ndefined\nfalse false\ntrue\n1 2 undefined\n", stream.buffered());
}

test "Engine eval executes object property assignment through quick parser" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("const obj = { x: 1 }; obj.x = obj.x + 2; print(obj.x);", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\n", stream.buffered());
}

test "Engine eval executes parenthesized literal postfix through quick parser" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("const obj = { x: 1 }; print(({ y: obj.x + 2 }).y); print(([3, 4])[1]);", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\n4\n", stream.buffered());
}

test "Engine eval executes compound assignment and update statements through quick parser" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("let x = 10; x += 5; x -= 3; x *= 2; x /= 4; x %= 5; x++; x--; print(x);", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n", stream.buffered());
}

test "Engine eval executes console.log with many arguments" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("console.log(1,2,3,4,5,6,7,8,9,10);", &stream);
    defer result.free(js.runtime);
    const output = stream.buffered();
    try std.testing.expectEqualStrings("1 2 3 4 5 6 7 8 9 10\n", output);
}

test "Engine eval routes host output through global function calls" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(1);
        \\console.log("x");
        \\const out = print;
        \\out(2 + 3, typeof out);
        \\const logger = console.log;
        \\logger("ok");
        \\const c = console;
        \\c.log("alias");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\nx\n5 function\nok\nalias\n", stream.buffered());
}

test "Engine eval preserves local numeric add host output semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let a = 1;
        \\let b = 2;
        \\print(a + b);
        \\let max = 2147483647;
        \\print(max + 1);
        \\let oldPrint = print;
        \\print = function(x) { globalThis.seen = "custom:" + x; };
        \\print(a + b);
        \\oldPrint(globalThis.seen);
        \\print = oldPrint;
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\n2147483648\ncustom:3\n", stream.buffered());
}

test "Engine eval preserves collection read host output semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let map = new Map();
        \\map.set("a", 1);
        \\print(map.get("a"));
        \\print(map.has("a"));
        \\let key = {};
        \\let weak = new WeakMap();
        \\weak.set(key, 2);
        \\print(weak.get(key));
        \\print(weak.has(key));
        \\let set = new Set();
        \\set.add("s");
        \\print(set.has("s"));
        \\let weakSetKey = {};
        \\let weakSet = new WeakSet();
        \\weakSet.add(weakSetKey);
        \\print(weakSet.has(weakSetKey));
        \\let oldGet = Map.prototype.get;
        \\Map.prototype.get = function(k) { return "custom:" + k; };
        \\print(map.get("a"));
        \\Map.prototype.get = oldGet;
        \\map.get = function(k) { return "own:" + k; };
        \\print(map.get("a"));
        \\delete map.get;
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\ntrue\n2\ntrue\ntrue\ntrue\ncustom:a\nown:a\n", stream.buffered());
}

test "runtime teardown preserves closure capture metadata until objects are destroyed" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // Keeping a captured closure on a builtin prototype while constructing a
    // lifetime-linked weak holder perturbs the intrusive GC-list order. Runtime
    // teardown must not use that incidental order to destroy the closure's FB
    // before the closure consumes FB.var_refs_len and frees its capture array.
    const result = try js.eval(
        \\function assert(value) { if (value !== true) throw 1; }
        \\var calls = 0;
        \\var originalSet = WeakMap.prototype.set;
        \\WeakMap.prototype.set = function(value) {
        \\    calls++;
        \\    return originalSet.call(this, value);
        \\};
        \\var map = new WeakMap([]);
        \\assert(map instanceof WeakMap);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "cycle teardown preserves restored strong counts for weakly referenced keys" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // Each key is both strongly retained by a result record and weakly retained
    // by the map. A cycle pass may visit the key before the map; the key must
    // keep its restored strong refcount until those result properties release
    // it, instead of being converted to an rc-zero weak husk prematurely.
    const result = try js.eval(
        \\var first = {};
        \\var second = {};
        \\var results = [];
        \\var originalSet = WeakMap.prototype.set;
        \\WeakMap.prototype.set = function(key, value) {
        \\    results.push({ receiver: this, key: key, value: value });
        \\    return originalSet.call(this, key, value);
        \\};
        \\var map = new WeakMap([[first, 42], [second, 43]]);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval preserves regexp UTF-16 test host output semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let re = new RegExp("\u00e9+", "");
        \\print(re.test("\u00e9\u00e9"));
        \\print(re.test("\u0100\u00e9"));
        \\print(re.test("\u0100"));
        \\let oldTest = RegExp.prototype.test;
        \\RegExp.prototype.test = function(input) { return input.length + ":" + (this === re); };
        \\print(re.test("\u00e9\u00e9"));
        \\RegExp.prototype.test = oldTest;
        \\re.test = function(input) { return input.charCodeAt(0); };
        \\print(re.test("\u00e9\u00e9"));
        \\delete re.test;
        \\print(re.test("aa"));
        \\let execOverride = /a+b/;
        \\let seenExec = "";
        \\execOverride.exec = function(input) { seenExec = input + ":" + (this === execOverride); return null; };
        \\print(execOverride.test("aaab"));
        \\print(seenExec);
        \\let globalRe = /a+b/g;
        \\print(globalRe.test("aaab"), globalRe.lastIndex);
        \\print(globalRe.test("x"), globalRe.lastIndex);
        \\let stickyRe = /a/y;
        \\stickyRe.lastIndex = 1;
        \\print(stickyRe.test("ba"), stickyRe.lastIndex);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\ntrue\nfalse\n2:true\n233\nfalse\nfalse\naaab:true\ntrue 4\nfalse 0\ntrue 2\n", stream.buffered());
}

test "Engine eval prepared RegExp call observes same-site property changes" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let re = /a+b/;
        \\function hit(input) { return re.test(input); }
        \\print(hit("aaab"));
        \\RegExp.prototype.test = function(input) { return "patched:" + input + ":" + (this === re); };
        \\print(hit("aaab"));
        \\re.test = function(input) { return "own:" + input; };
        \\print(hit("aaab"));
        \\delete re.test;
        \\print(hit("aaab"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\npatched:aaab:true\nown:aaab\npatched:aaab:true\n", stream.buffered());
}

test "Engine eval preserves dense array join host output semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let tab = [3, 1, 2];
        \\tab.sort();
        \\print(tab.join(","));
        \\let oldJoin = Array.prototype.join;
        \\Array.prototype.join = function(separator) { return "custom:" + separator + ":" + this.length; };
        \\print(tab.join("|"));
        \\Array.prototype.join = oldJoin;
        \\tab.join = function(separator) { return "own:" + separator; };
        \\print(tab.join(","));
        \\delete tab.join;
        \\tab[0] = { toString: function() { globalThis.seenJoinObject = "object"; return "obj"; } };
        \\print(tab.join(","));
        \\print(globalThis.seenJoinObject);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1,2,3\ncustom:|:3\nown:,\nobj,2,3\nobject\n", stream.buffered());
}

test "Engine eval preserves dense array pop host output semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let tab = [1, 2];
        \\print(tab.pop());
        \\print(tab.length);
        \\let oldPop = Array.prototype.pop;
        \\Array.prototype.pop = function() { return "custom:" + this.length; };
        \\print(tab.pop());
        \\Array.prototype.pop = oldPop;
        \\tab.pop = function() { return "own:" + this.length; };
        \\print(tab.pop());
        \\delete tab.pop;
        \\let accessorTab = [1];
        \\Object.defineProperty(accessorTab, "0", { get: function() { globalThis.seenPopGetter = "getter"; return 9; }, configurable: true });
        \\print(accessorTab.pop());
        \\print(accessorTab.length);
        \\print(globalThis.seenPopGetter);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2\n1\ncustom:1\nown:1\n9\n0\ngetter\n", stream.buffered());
}

test "Engine eval preserves ordinary array pop fast path semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let a = [1, 2, 3];
        \\let x = a.pop();
        \\print(x, a.length, a.join(","));
        \\let extra = [1, 2];
        \\print(extra.pop(0), extra.length, extra.join(","));
        \\let b = [1];
        \\b.length = 2;
        \\print(b.pop(), b.length);
        \\Object.prototype[1] = 7;
        \\let c = [1];
        \\c.length = 2;
        \\print(c.pop(), c.length);
        \\delete Object.prototype[1];
        \\let d = [1, 2];
        \\Object.defineProperty(d, "1", { value: 2, configurable: false });
        \\try {
        \\    print(d.pop());
        \\} catch (e) {
        \\    print(e.name, d.length, d[1]);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3 2 1,2\n2 1 1\nundefined 1\n7 1\nTypeError 2 2\n", stream.buffered());
}

test "empty native array pop fast arm preserves observable length writes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var frozen = Object.freeze([]);
        \\var frozenError;
        \\try { frozen.pop(); } catch (error) { frozenError = error; }
        \\assert.sameValue(frozenError.name, "TypeError");
        \\assert.sameValue(frozenError.message, "'length' is read-only");
        \\
        \\var log = [];
        \\var target = [];
        \\var proxy = new Proxy(target, {
        \\    get: function(target, key, receiver) {
        \\        if (key === "length") log.push("get");
        \\        return Reflect.get(target, key, receiver);
        \\    },
        \\    set: function(target, key, value, receiver) {
        \\        if (key === "length") log.push("set:" + value);
        \\        return Reflect.set(target, key, value, receiver);
        \\    }
        \\});
        \\assert.sameValue(Array.prototype.pop.call(proxy), undefined);
        \\assert.sameValue(log.join(","), "get,set:0");
        \\assert.sameValue(target.length, 0);
        \\
        \\var gets = 0;
        \\var sets = [];
        \\var ordinary = {
        \\    get length() { gets++; return 0; },
        \\    set length(value) { sets.push(value); }
        \\};
        \\assert.sameValue(Array.prototype.pop.call(ordinary), undefined);
        \\assert.sameValue(gets, 1);
        \\assert.sameValue(sets.join(","), "0");
        \\
        \\class SubArray extends Array {}
        \\var subclass = new SubArray();
        \\assert.sameValue(subclass.pop(), undefined);
        \\assert.sameValue(subclass.length, 0);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "array pop length write removes elements added by the last-element getter" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var array = [];
        \\array.length = 1;
        \\Object.defineProperty(array, "0", {
        \\    configurable: true,
        \\    get: function() {
        \\        array[5] = 9;
        \\        return 7;
        \\    }
        \\});
        \\assert.sameValue(array.pop(), 7);
        \\assert.sameValue(array.length, 0);
        \\assert.sameValue(0 in array, false);
        \\assert.sameValue(5 in array, false);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "array pop reports read-only length after deleting a configurable last element" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var array = [7];
        \\Object.defineProperty(array, "length", { writable: false });
        \\var thrown;
        \\try { array.pop(); } catch (error) { thrown = error; }
        \\assert.sameValue(thrown.name, "TypeError");
        \\assert.sameValue(thrown.message, "'length' is read-only");
        \\assert.sameValue(array.length, 1);
        \\assert.sameValue(0 in array, false);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine eval preserves simple closure call host output semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function counter() { let n = 0; return function () { n++; return n; }; }
        \\let next = counter();
        \\print(next());
        \\print(next());
        \\let oldPrint = print;
        \\print = function(x) { globalThis.seenClosureCall = "[" + x + "]"; };
        \\print(next());
        \\oldPrint(globalThis.seenClosureCall);
        \\print = oldPrint;
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n2\n[3]\n", stream.buffered());
}

test "Engine eval preserves one-shot array literal host output semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function lengthOnly() {
        \\  let tab = [1, 2];
        \\  print(tab.length);
        \\}
        \\print(lengthOnly() === undefined);
        \\function valueAndLength() {
        \\  let tab = [2];
        \\  print(tab[0]);
        \\  print(tab.length);
        \\}
        \\print(valueAndLength() === undefined);
        \\let oldPrint = print;
        \\print = function(x) { globalThis.seen = (globalThis.seen || "") + "[" + x + "]"; };
        \\let tab = [2];
        \\print(tab[0]);
        \\print(tab.length);
        \\oldPrint(globalThis.seen);
        \\print = oldPrint;
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2\ntrue\n2\n1\ntrue\n[2][1]\n", stream.buffered());
}

test "Engine eval preserves one-shot array named property host output semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let tab = [1];
        \\tab.a = 9;
        \\print(tab.a);
        \\let oldPrint = print;
        \\print = function(x) { oldPrint("custom:" + x); };
        \\let tab2 = [1];
        \\tab2.a = 8;
        \\print(tab2.a);
        \\print = oldPrint;
        \\let seen = 0;
        \\Object.defineProperty(Array.prototype, "guarded", {
        \\  set: function(v) { seen = v + 1; },
        \\  get: function() { return seen; },
        \\  configurable: true
        \\});
        \\let tab3 = [1];
        \\tab3.guarded = 7;
        \\print(tab3.guarded);
        \\delete Array.prototype.guarded;
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("9\ncustom:8\n8\n", stream.buffered());
}

test "Engine eval preserves typed array constructor length host output semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function lengthOnly() {
        \\  let tab = new Int32Array(new ArrayBuffer(16));
        \\  print(tab.length);
        \\}
        \\print(lengthOnly() === undefined);
        \\let oldPrint = print;
        \\print = function(x) { globalThis.seen = "print:" + x; };
        \\let tab = new Int32Array(new ArrayBuffer(16));
        \\print(tab.length);
        \\oldPrint(globalThis.seen);
        \\print = oldPrint;
        \\let OldTA = Int32Array;
        \\Int32Array = function(buffer) { this.length = 99; };
        \\let fake = new Int32Array(new ArrayBuffer(16));
        \\print(fake.length);
        \\Int32Array = OldTA;
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("4\ntrue\nprint:4\n99\n", stream.buffered());
}

test "Engine eval preserves Int32Array indexed read fast path semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let a = new Int32Array(2);
        \\a[0] = 7;
        \\a[1] = -3;
        \\print(a[0], a[1], a[2]);
        \\Object.prototype[0] = 9;
        \\let b = new Int32Array(0);
        \\print(b[0]);
        \\delete Object.prototype[0];
        \\let c = new Int32Array(1);
        \\c.buffer.transfer();
        \\print(c[0]);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("7 -3 undefined\nundefined\nundefined\n", stream.buffered());
}

test "Engine eval executes simple template interpolation" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("const x = 10; const y = 20; print(`${x} + ${y} = ${x + y}`);", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("10 + 20 = 30\n", stream.buffered());
}

test "Engine eval template interpolation calls object toString" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        "const x = { toString(){ return 'custom'; } }; print(`${x}`);",
        &stream,
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("custom\n", stream.buffered());
}

test "Engine eval executes simple arrays and map" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("const arr = [1, 2, 3]; print(arr); print(arr.length); print(arr[0]); print(arr.map(x => x * 2));", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1,2,3\n3\n1\n2,4,6\n", stream.buffered());
}

test "Engine eval executes simple functions and arrows" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [160]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function add(a, b) { return a + b; }
        \\print(add(2, 3));
        \\const double = x => x * 2;
        \\print(double(21));
        \\function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); }
        \\print(fact(6));
        \\const mul = (a, b) => { return a * b; };
        \\print(mul(3, 4));
        \\function varArguments() { return typeof arguments; var arguments = 1; }
        \\print(varArguments(42));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("5\n42\n720\n12\nobject\n", stream.buffered());
}

test "strict plain calls preserve this arguments eval captures and backtraces" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function strictZero() {
        \\    "use strict";
        \\    assert.sameValue(this, undefined);
        \\    return arguments.length;
        \\}
        \\assert.sameValue(strictZero(), 0);
        \\function strictArgs(value) {
        \\    "use strict";
        \\    arguments[0] = 9;
        \\    return value;
        \\}
        \\assert.sameValue(strictArgs(1), 1);
        \\function strictArgumentsIdentity() { "use strict"; return arguments === arguments; }
        \\assert.sameValue(strictArgumentsIdentity(1), true);
        \\function strictOriginalArgs(value) {
        \\    "use strict";
        \\    value = 17;
        \\    return arguments[0];
        \\}
        \\assert.sameValue(strictOriginalArgs(1), 1);
        \\function strictEval() {
        \\    "use strict";
        \\    eval("var hidden = 1");
        \\    return typeof hidden;
        \\}
        \\assert.sameValue(strictEval(), "undefined");
        \\function makeStrictClosure() {
        \\    var captured = 4;
        \\    return function strictClosure() { "use strict"; return captured; };
        \\}
        \\assert.sameValue(makeStrictClosure()(), 4);
        \\function strictStack() { "use strict"; return new Error("x").stack; }
        \\assert.sameValue(strictStack().indexOf("    at strictStack"), 0);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "strict arguments preserve qjs intrinsic metadata and dense element semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const savedValues = Array.prototype.values;
        \\Array.prototype.values = function patchedValues() { throw new Error("observable lookup"); };
        \\try {
        \\    function capture(a, b, c) {
        \\        "use strict";
        \\        return { args: arguments, parameter: a };
        \\    }
        \\    const record = capture(1, 2, 3);
        \\    const args = record.args;
        \\    assert.sameValue(args[Symbol.iterator], savedValues);
        \\    assert.sameValue(JSON.stringify(args), '{"0":1,"1":2,"2":3}');
        \\    const keys = Reflect.ownKeys(args);
        \\    assert.sameValue(keys.length, 6);
        \\    assert.sameValue(keys[0], "0");
        \\    assert.sameValue(keys[1], "1");
        \\    assert.sameValue(keys[2], "2");
        \\    assert.sameValue(keys[3], "length");
        \\    assert.sameValue(keys[4], "callee");
        \\    assert.sameValue(keys[5], Symbol.iterator);
        \\    const lengthDesc = Object.getOwnPropertyDescriptor(args, "length");
        \\    assert.sameValue(lengthDesc.value, 3);
        \\    assert.sameValue(lengthDesc.writable, true);
        \\    assert.sameValue(lengthDesc.enumerable, false);
        \\    assert.sameValue(lengthDesc.configurable, true);
        \\    const iteratorDesc = Object.getOwnPropertyDescriptor(args, Symbol.iterator);
        \\    assert.sameValue(iteratorDesc.value, savedValues);
        \\    assert.sameValue(iteratorDesc.writable, true);
        \\    assert.sameValue(iteratorDesc.enumerable, false);
        \\    assert.sameValue(iteratorDesc.configurable, true);
        \\    const calleeDesc = Object.getOwnPropertyDescriptor(args, "callee");
        \\    assert.sameValue(calleeDesc.get, calleeDesc.set);
        \\    assert.sameValue(calleeDesc.enumerable, false);
        \\    assert.sameValue(calleeDesc.configurable, false);
        \\    let calleeThrew = false;
        \\    try { void args.callee; } catch (error) { calleeThrew = error instanceof TypeError; }
        \\    assert.sameValue(calleeThrew, true);
        \\    args.length = 1;
        \\    assert.sameValue(Array.prototype.join.call(args, "-"), "1");
        \\    args[0] = 9;
        \\    assert.sameValue(record.parameter, 1);
        \\    assert.sameValue(args[0], 9);
        \\    assert.sameValue(delete args[0], true);
        \\    assert.sameValue(0 in args, false);
        \\    Object.defineProperty(args, "1", { value: 7, writable: false, enumerable: false, configurable: false });
        \\    assert.sameValue(args[1], 7);
        \\    assert.sameValue(Object.keys(args).join(","), "2");
        \\    Object.freeze(args);
        \\    const frozen = Object.getOwnPropertyDescriptor(args, "2");
        \\    assert.sameValue(frozen.value, 3);
        \\    assert.sameValue(frozen.writable, false);
        \\    assert.sameValue(frozen.enumerable, true);
        \\    assert.sameValue(frozen.configurable, false);
        \\    assert.sameValue(Object.isFrozen(args), true);
        \\} finally {
        \\    Array.prototype.values = savedValues;
        \\}
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "mapped arguments use var-ref indexed storage and detach on descriptor changes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function mapped(first, second) {
        \\    const args = arguments;
        \\    first = 5;
        \\    assert.sameValue(args[0], 5);
        \\    args[1] = 7;
        \\    assert.sameValue(second, 7);
        \\    const keys = Reflect.ownKeys(args);
        \\    assert.sameValue(keys[0], "0");
        \\    assert.sameValue(keys[1], "1");
        \\    assert.sameValue(keys[2], "length");
        \\    assert.sameValue(keys[3], "callee");
        \\    assert.sameValue(keys[4], Symbol.iterator);
        \\    const initial = Object.getOwnPropertyDescriptor(args, "0");
        \\    assert.sameValue(initial.value, 5);
        \\    assert.sameValue(initial.writable, true);
        \\    assert.sameValue(initial.enumerable, true);
        \\    assert.sameValue(initial.configurable, true);
        \\    assert.sameValue(delete args[0], true);
        \\    first = 8;
        \\    assert.sameValue(0 in args, false);
        \\    assert.sameValue(args[0], undefined);
        \\    Object.defineProperty(args, "1", { enumerable: false });
        \\    second = 9;
        \\    assert.sameValue(args[1], 9);
        \\    assert.sameValue(Object.getOwnPropertyDescriptor(args, "1").enumerable, false);
        \\    Object.defineProperty(args, "1", { writable: false });
        \\    second = 10;
        \\    assert.sameValue(args[1], 9);
        \\    return args;
        \\}
        \\const mappedArgs = mapped(1, 2);
        \\assert.sameValue(Object.keys(mappedArgs).length, 0);
        \\function mappedArgumentsIdentity() {
        \\    assert.sameValue(arguments, arguments);
        \\    arguments.callee = 1;
        \\    assert.sameValue(arguments.callee, 1);
        \\}
        \\mappedArgumentsIdentity({ callee: "argument" });
        \\function annexBArgumentsBinding() {
        \\    const outer = arguments;
        \\    {
        \\        assert.sameValue(arguments(), undefined);
        \\        function arguments() {}
        \\        assert.sameValue(arguments(), undefined);
        \\    }
        \\    assert.sameValue(arguments, outer);
        \\}
        \\annexBArgumentsBinding();
        \\function extra(first) {
        \\    const args = arguments;
        \\    args[1] = 6;
        \\    return args[1];
        \\}
        \\assert.sameValue(extra(1, 2), 6);
        \\function duplicate(value, value) {
        \\    const args = arguments;
        \\    value = 7;
        \\    assert.sameValue(args[0], 1);
        \\    assert.sameValue(args[1], 7);
        \\    args[0] = 8;
        \\    assert.sameValue(value, 7);
        \\    args[1] = 9;
        \\    assert.sameValue(value, 9);
        \\}
        \\duplicate(1, 2);
        \\function frozen(value) {
        \\    const args = arguments;
        \\    Object.freeze(args);
        \\    value = 4;
        \\    const desc = Object.getOwnPropertyDescriptor(args, "0");
        \\    assert.sameValue(args[0], 1);
        \\    assert.sameValue(desc.writable, false);
        \\    assert.sameValue(desc.configurable, false);
        \\    assert.sameValue(Object.isFrozen(args), true);
        \\}
        \\frozen(1);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "resident generators preserve mapped arguments parameter aliases" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function* mappedGenerator(first, second, third, missing) {
        \\    arguments[0] = 32;
        \\    arguments[1] = 54;
        \\    arguments[2] = 333;
        \\    yield first;
        \\    yield second;
        \\    yield third;
        \\    yield missing;
        \\}
        \\const iterator = mappedGenerator(23, 45, 33);
        \\assert.sameValue(iterator.next().value, 32);
        \\assert.sameValue(iterator.next().value, 54);
        \\assert.sameValue(iterator.next().value, 333);
        \\assert.sameValue(iterator.next().value, undefined);
        \\assert.sameValue(iterator.next().done, true);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "implicit arguments runtime rescue preserves mapped aliases" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function annexRead(value) {
        \\  { function arguments() {} }
        \\  return arguments[0];
        \\}
        \\function annexAliasFromArguments(value) {
        \\  { function arguments() {} }
        \\  arguments[0] = 5;
        \\  return value;
        \\}
        \\function annexAliasFromParameter(value) {
        \\  { function arguments() {} }
        \\  value = 7;
        \\  return arguments[0];
        \\}
        \\function annexCaptured(first, second) {
        \\  { function arguments() {} }
        \\  const read = () => first;
        \\  arguments[0] = 5;
        \\  second = 7;
        \\  return read() + ":" + arguments[1];
        \\}
        \\function* annexGenerator(value) {
        \\  { function arguments() {} }
        \\  yield arguments[0];
        \\}
        \\print(annexRead(42));
        \\print(annexAliasFromArguments(42));
        \\print(annexAliasFromParameter(42));
        \\print(annexCaptured(1, 2));
        \\print(annexGenerator(9).next().value);
        \\try { print(annexRead(43)); } catch (error) { print("caught", error.name); }
        \\print("after");
    , &output);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("42\n5\n7\n5:7\n9\n43\nafter\n", output.buffered());
}

test "resident mapped arguments share one open bare arg slot" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const setup = try js.eval(
        \\function* mappedArgStorage(first) {
        \\  globalThis.__mappedArgArguments = arguments;
        \\  yield first;
        \\  first += 1;
        \\  yield first;
        \\}
        \\globalThis.__mappedArgGenerator = mappedArgStorage(41);
        \\__mappedArgGenerator.next();
    );
    defer setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const generator_key = try js.runtime.internAtom("__mappedArgGenerator");
    defer js.runtime.atoms.free(generator_key);
    const generator_value = global.getProperty(generator_key);
    defer generator_value.free(js.runtime);
    const generator = try property_ops.expectObject(generator_value);
    const state = generator.generatorExecutionState();
    const arg_slot = &state.storage.frame.args[0];

    const arguments_key = try js.runtime.internAtom("__mappedArgArguments");
    defer js.runtime.atoms.free(arguments_key);
    const arguments_value = global.getProperty(arguments_key);
    defer arguments_value.free(js.runtime);
    const arguments = try property_ops.expectObject(arguments_value);
    const argument_refs = arguments.argumentsVarRefs();
    try std.testing.expectEqual(@as(usize, 1), argument_refs.len);
    const cell = argument_refs[0] orelse return error.TypeError;

    try std.testing.expectEqual(@as(?i32, 41), arg_slot.asInt32());
    try std.testing.expect(core.VarRef.fromValue(arg_slot.*) == null);
    try std.testing.expect(cell.is_open);
    try std.testing.expect(cell.pvalue == arg_slot);
    var identity_matches: usize = 0;
    for (state.storage.frame.open_var_refs) |maybe_ref| {
        if (maybe_ref == cell) identity_matches += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), identity_matches);

    const resumed = try js.eval(
        \\const step = __mappedArgGenerator.next();
        \\assert.sameValue(step.value, 42);
        \\assert.sameValue(step.done, false);
    );
    defer resumed.free(js.runtime);
    try std.testing.expect(arg_slot == &generator.generatorExecutionState().storage.frame.args[0]);
    try std.testing.expect(cell.pvalue == arg_slot);
    try std.testing.expectEqual(@as(?i32, 42), arg_slot.asInt32());
}

test "generic arg opcodes preserve mapped aliases in a bare resident slot" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const setup = try js.eval(
        \\function* genericArgStorage(a, b, c, d, fifth) {
        \\  globalThis.__genericArgArguments = arguments;
        \\  arguments[4] = 50;
        \\  yield fifth;
        \\  fifth = 51;
        \\  yield arguments[4];
        \\  yield (fifth = 52);
        \\  return arguments[4];
        \\}
        \\globalThis.__genericArgGenerator = genericArgStorage(1, 2, 3, 4, 5);
        \\const first = __genericArgGenerator.next();
        \\assert.sameValue(first.value, 50);
        \\assert.sameValue(first.done, false);
    );
    defer setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const generator_key = try js.runtime.internAtom("__genericArgGenerator");
    defer js.runtime.atoms.free(generator_key);
    const generator_value = global.getProperty(generator_key);
    defer generator_value.free(js.runtime);
    const generator = try property_ops.expectObject(generator_value);
    const fifth_slot = &generator.generatorExecutionState().storage.frame.args[4];
    try std.testing.expectEqual(@as(?i32, 50), fifth_slot.asInt32());
    try std.testing.expect(core.VarRef.fromValue(fifth_slot.*) == null);

    const completion = try js.eval(
        \\let step = __genericArgGenerator.next();
        \\assert.sameValue(step.value, 51);
        \\assert.sameValue(step.done, false);
        \\step = __genericArgGenerator.next();
        \\assert.sameValue(step.value, 52);
        \\assert.sameValue(step.done, false);
        \\step = __genericArgGenerator.next();
        \\assert.sameValue(step.value, 52);
        \\assert.sameValue(step.done, true);
    );
    defer completion.free(js.runtime);
    try std.testing.expect(completion.isUndefined());
}

test "generator mapped arguments closures and direct eval share one alias across resumes" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function* aliasedGenerator(argument) {
        \\  globalThis.__aliasedArguments = arguments;
        \\  globalThis.__aliasedRead = function() { return argument; };
        \\  globalThis.__aliasedWrite = function(value) { argument = value; };
        \\  arguments[0] = 20;
        \\  yield __aliasedRead();
        \\  eval('argument = 30');
        \\  yield arguments[0];
        \\  argument = 40;
        \\  yield __aliasedRead();
        \\}
        \\globalThis.__aliasedGenerator = aliasedGenerator(10);
        \\let step = __aliasedGenerator.next();
        \\assert.sameValue(step.value, 20);
        \\assert.sameValue(__aliasedRead(), 20);
        \\__aliasedArguments[0] = 25;
        \\assert.sameValue(__aliasedRead(), 25);
        \\step = __aliasedGenerator.next();
        \\assert.sameValue(step.value, 30);
        \\assert.sameValue(__aliasedRead(), 30);
        \\__aliasedWrite(35);
        \\assert.sameValue(__aliasedArguments[0], 35);
        \\step = __aliasedGenerator.next();
        \\assert.sameValue(step.value, 40);
        \\assert.sameValue(__aliasedArguments[0], 40);
        \\step = __aliasedGenerator.next();
        \\assert.sameValue(step.done, true);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "async mapped arguments and closures retain one alias across await" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\async function mappedAsync(argument) {
        \\  const read = function() { return argument; };
        \\  arguments[0] = 55;
        \\  print('before', read());
        \\  const awaited = await Promise.resolve(argument);
        \\  print('after', arguments[0], read(), awaited);
        \\  return read();
        \\}
        \\mappedAsync(10).then(
        \\  function(value) { print('resolved', value); },
        \\  function(error) { print('rejected', error.name); }
        \\);
    , &stream);
    defer result.free(js.runtime);
    try js.runJobs();

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "before 55\nafter 55 55 55\nresolved 55\n",
        stream.buffered(),
    );
}

test "cycle collection closes escaped generator arg aliases before releasing resident backing" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const setup = try js.eval(
        \\var __argCycleHolder;
        \\function* argCycle(argument) {
        \\  const self = __argCycleHolder;
        \\  globalThis.__argCycleArguments = arguments;
        \\  globalThis.__argCycleRead = function() { return argument; };
        \\  globalThis.__argCycleWrite = function(value) { argument = value; };
        \\  yield 0;
        \\  return self;
        \\}
        \\__argCycleHolder = argCycle(41);
        \\__argCycleHolder.next();
    );
    defer setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const arguments_key = try js.runtime.internAtom("__argCycleArguments");
    defer js.runtime.atoms.free(arguments_key);
    const arguments_value = global.getProperty(arguments_key);
    defer arguments_value.free(js.runtime);
    const arguments = try property_ops.expectObject(arguments_value);
    const refs = arguments.argumentsVarRefs();
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    const cell = refs[0] orelse return error.TypeError;
    try std.testing.expect(cell.is_open);
    try std.testing.expectEqual(@as(?i32, 41), cell.varRefValue().asInt32());

    const release = try js.eval("__argCycleHolder = null;");
    release.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    try std.testing.expect(!cell.is_open);
    try std.testing.expectEqual(@as(?i32, 41), cell.varRefValue().asInt32());

    const escaped = try js.eval(
        \\assert.sameValue(__argCycleRead(), 41);
        \\__argCycleArguments[0] = 52;
        \\assert.sameValue(__argCycleRead(), 52);
        \\__argCycleWrite(63);
        \\assert.sameValue(__argCycleArguments[0], 63);
    );
    defer escaped.free(js.runtime);
    try std.testing.expect(escaped.isUndefined());
}

test "generator completion closes escaped arg aliases before releasing resident backing" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const setup = try js.eval(
        \\function* completingArgAlias(argument) {
        \\  globalThis.__completedArgArguments = arguments;
        \\  globalThis.__completedArgRead = function() { return argument; };
        \\  yield 0;
        \\  return argument;
        \\}
        \\globalThis.__completedArgGenerator = completingArgAlias(41);
        \\__completedArgGenerator.next();
    );
    defer setup.free(js.runtime);

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const generator_key = try js.runtime.internAtom("__completedArgGenerator");
    defer js.runtime.atoms.free(generator_key);
    const generator_value = global.getProperty(generator_key);
    defer generator_value.free(js.runtime);
    const generator = try property_ops.expectObject(generator_value);

    const arguments_key = try js.runtime.internAtom("__completedArgArguments");
    defer js.runtime.atoms.free(arguments_key);
    const arguments_value = global.getProperty(arguments_key);
    defer arguments_value.free(js.runtime);
    const arguments = try property_ops.expectObject(arguments_value);
    const cell = arguments.argumentsVarRefs()[0] orelse return error.TypeError;
    try std.testing.expect(cell.is_open);

    const completion = try js.eval(
        \\const step = __completedArgGenerator.next();
        \\assert.sameValue(step.value, 41);
        \\assert.sameValue(step.done, true);
    );
    defer completion.free(js.runtime);
    try std.testing.expect(!cell.is_open);
    try std.testing.expect(generator.generatorExecutionState().storage.isEmpty());

    const escaped = try js.eval(
        \\__completedArgArguments[0] = 52;
        \\assert.sameValue(__completedArgRead(), 52);
    );
    defer escaped.free(js.runtime);
    try std.testing.expect(escaped.isUndefined());
}

test "get_length preserves qjs own-property-before-exotic ordering and actions" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const own = { length: 3 };
        \\assert.sameValue(own.length, 3);
        \\const inherited = Object.create({ length: 4 });
        \\assert.sameValue(inherited.length, 4);
        \\const self = {};
        \\self.length = self;
        \\assert.sameValue(self.length, self);
        \\function strictLength(value) {
        \\    "use strict";
        \\    return arguments.length;
        \\}
        \\assert.sameValue(strictLength(1), 1);
        \\function mappedLength(value) {
        \\    return arguments.length;
        \\}
        \\assert.sameValue(mappedLength(1), 1);
        \\function mappedComputedDescriptor(value) {
        \\    const args = arguments;
        \\    const key = "0";
        \\    Object.defineProperty(args, key, { configurable: false });
        \\    args[key] = 2;
        \\    assert.sameValue(value, 2);
        \\    assert.sameValue(args[key], 2);
        \\    const desc = Object.getOwnPropertyDescriptor(args, key);
        \\    assert.sameValue(desc.value, 2);
        \\    assert.sameValue(desc.writable, true);
        \\    assert.sameValue(desc.enumerable, true);
        \\    assert.sameValue(desc.configurable, false);
        \\}
        \\mappedComputedDescriptor(1);
        \\const typed = new Uint8Array(2);
        \\assert.sameValue(typed.length, 2);
        \\assert.sameValue(typed.byteLength, 2);
        \\assert.sameValue(typed.byteOffset, 0);
        \\const typedPrototypeImpostor = Object.create(typed);
        \\let typedBrandRejected = false;
        \\try {
        \\    void typedPrototypeImpostor.length;
        \\} catch (error) {
        \\    typedBrandRejected = error instanceof TypeError;
        \\}
        \\assert.sameValue(typedBrandRejected, true);
        \\const customPrototypeTyped = new Uint8Array(2);
        \\Object.setPrototypeOf(customPrototypeTyped, { length: 15, byteLength: 16, byteOffset: 17 });
        \\assert.sameValue(customPrototypeTyped.length, 15);
        \\assert.sameValue(customPrototypeTyped.byteLength, 16);
        \\assert.sameValue(customPrototypeTyped.byteOffset, 17);
        \\assert.sameValue(Reflect.get(customPrototypeTyped, "length"), 15);
        \\const nullPrototypeTyped = new Uint8Array(2);
        \\Object.setPrototypeOf(nullPrototypeTyped, null);
        \\assert.sameValue(nullPrototypeTyped.length, undefined);
        \\assert.sameValue(nullPrototypeTyped.byteLength, undefined);
        \\assert.sameValue(nullPrototypeTyped.byteOffset, undefined);
        \\assert.sameValue(Reflect.get(nullPrototypeTyped, "length"), undefined);
        \\Object.defineProperty(typed, "length", { value: 9, configurable: true });
        \\assert.sameValue(typed.length, 9);
        \\let typedGetterCount = 0;
        \\Object.defineProperty(typed, "length", {
        \\    configurable: true,
        \\    get() {
        \\        typedGetterCount++;
        \\        return 12;
        \\    },
        \\});
        \\assert.sameValue(typed.length, 12);
        \\const lengthKey = "length";
        \\assert.sameValue(typed[lengthKey], 12);
        \\assert.sameValue(Reflect.get(typed, lengthKey), 12);
        \\assert.sameValue(typedGetterCount, 3);
        \\Object.defineProperty(typed, "byteLength", {
        \\    configurable: true,
        \\    get() { return 13; },
        \\});
        \\assert.sameValue(typed.byteLength, 13);
        \\assert.sameValue(Reflect.get(typed, "byteLength"), 13);
        \\Object.defineProperty(typed, "byteOffset", { configurable: true, value: 14 });
        \\assert.sameValue(typed.byteOffset, 14);
        \\assert.sameValue(Reflect.get(typed, "byteOffset"), 14);
        \\let getterCount = 0;
        \\let getterReceiver;
        \\const accessorPrototype = {
        \\    get length() {
        \\        getterCount++;
        \\        getterReceiver = this;
        \\        return 5;
        \\    },
        \\};
        \\const accessor = Object.create(accessorPrototype);
        \\assert.sameValue(accessor.length, 5);
        \\assert.sameValue(getterCount, 1);
        \\assert.sameValue(getterReceiver, accessor);
        \\const accessorAlias = { get length() { return this; } };
        \\assert.sameValue(accessorAlias.length, accessorAlias);
        \\const undefinedAccessor = {};
        \\Object.defineProperty(undefinedAccessor, "length", { get: undefined });
        \\assert.sameValue(undefinedAccessor.length, undefined);
        \\const thrownMarker = {};
        \\const throwingAccessor = { get length() { throw thrownMarker; } };
        \\try {
        \\    void throwingAccessor.length;
        \\    throw new Error("unreachable");
        \\} catch (thrown) {
        \\    assert.sameValue(thrown, thrownMarker);
        \\}
        \\let trapCount = 0;
        \\let trapReceiver;
        \\const proxy = new Proxy({}, {
        \\    get(target, key, receiver) {
        \\        trapCount++;
        \\        trapReceiver = receiver;
        \\        return key === "length" ? 6 : Reflect.get(target, key, receiver);
        \\    },
        \\});
        \\assert.sameValue(proxy.length, 6);
        \\assert.sameValue(trapCount, 1);
        \\assert.sameValue(trapReceiver, proxy);
        \\let targetGetterReceiver;
        \\const proxyTarget = {};
        \\Object.defineProperty(proxyTarget, "length", {
        \\    configurable: true,
        \\    get() {
        \\        targetGetterReceiver = this;
        \\        return 7;
        \\    },
        \\});
        \\const noTrapProxy = new Proxy(proxyTarget, {});
        \\assert.sameValue(noTrapProxy.length, 7);
        \\assert.sameValue(targetGetterReceiver, noTrapProxy);
        \\const frozenTarget = {};
        \\Object.defineProperty(frozenTarget, "length", { value: 1, writable: false, configurable: false });
        \\try {
        \\    void new Proxy(frozenTarget, { get() { return 2; } }).length;
        \\    throw new Error("unreachable");
        \\} catch (error) {
        \\    assert.sameValue(error instanceof TypeError, true);
        \\}
        \\const revocable = Proxy.revocable({}, {});
        \\revocable.revoke();
        \\try {
        \\    void revocable.proxy.length;
        \\    throw new Error("unreachable");
        \\} catch (error) {
        \\    assert.sameValue(error instanceof TypeError, true);
        \\}
        \\function mappedAccessor(value) {
        \\    const args = arguments;
        \\    Object.defineProperty(args, "length", {
        \\        configurable: true,
        \\        get() { return 11; },
        \\    });
        \\    return args.length;
        \\}
        \\assert.sameValue(mappedAccessor(1), 11);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "missing-argument plain calls preserve parameter and arguments ownership" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function sloppyMissing(first, second) {
        \\    assert.sameValue(arguments.length, 0);
        \\    assert.sameValue(arguments.hasOwnProperty("0"), false);
        \\    assert.sameValue(arguments.hasOwnProperty("1"), false);
        \\    first = 7;
        \\    second = 8;
        \\    assert.sameValue(arguments.hasOwnProperty("0"), false);
        \\    assert.sameValue(arguments.hasOwnProperty("1"), false);
        \\    return first + second;
        \\}
        \\assert.sameValue(sloppyMissing(), 15);
        \\function sloppyPartial(first, second) {
        \\    assert.sameValue(arguments.length, 1);
        \\    first = 7;
        \\    second = 8;
        \\    assert.sameValue(arguments[0], 7);
        \\    assert.sameValue(arguments.hasOwnProperty("1"), false);
        \\    return first + second;
        \\}
        \\assert.sameValue(sloppyPartial(1), 15);
        \\function strictPartial(first, second) {
        \\    "use strict";
        \\    first = 7;
        \\    second = 8;
        \\    assert.sameValue(arguments.length, 1);
        \\    assert.sameValue(arguments[0], 1);
        \\    assert.sameValue(arguments.hasOwnProperty("1"), false);
        \\    return first + second;
        \\}
        \\assert.sameValue(strictPartial(1), 15);
        \\function captureMissing(value) {
        \\    return function readCaptured() { return value; };
        \\}
        \\assert.sameValue(captureMissing()(), undefined);
        \\function evalMissing(value) {
        \\    return eval("value");
        \\}
        \\assert.sameValue(evalMissing(), undefined);
        \\const marker = {};
        \\function keepActual(first, second) { return first; }
        \\assert.sameValue(keepActual(marker), marker);
        \\function escapeMapped(first, second) { return arguments; }
        \\const mapped = escapeMapped(marker);
        \\assert.sameValue(mapped.length, 1);
        \\assert.sameValue(mapped[0], marker);
        \\assert.sameValue(mapped.hasOwnProperty("1"), false);
        \\function escapeStrict(first, second) {
        \\    "use strict";
        \\    first = 9;
        \\    return arguments;
        \\}
        \\const unmapped = escapeStrict(marker);
        \\assert.sameValue(unmapped.length, 1);
        \\assert.sameValue(unmapped[0], marker);
        \\assert.sameValue(unmapped.hasOwnProperty("1"), false);
        \\try {
        \\    (function throwMissing(first, second) { throw first; })(marker);
        \\} catch (thrown) {
        \\    assert.sameValue(thrown, marker);
        \\}
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "inline calls release lazily materialized arguments state" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const setup = try js.eval(
        \\function readArguments(value) {
        \\    return arguments.length + value;
        \\}
        \\assert.sameValue(readArguments(1), 2);
    );
    setup.free(js.runtime);
    const exercise =
        \\(function exerciseArgumentsCalls() {
        \\    let total = 0;
        \\    for (let i = 0; i < 256; i++) total += readArguments(i);
        \\    assert.sameValue(total, 32896);
        \\})();
    ;
    const warmup = try js.eval(exercise);
    warmup.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval(exercise);
    result.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "inline empty leaf abrupt teardown releases pending operands" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const setup = try js.eval(
        \\function throwWithPendingOperand() {
        \\    return {} + null.missing;
        \\}
        \\function exerciseEmptyLeafThrow() {
        \\    for (let i = 0; i < 256; i++) {
        \\        try { throwWithPendingOperand(); } catch (error) {}
        \\    }
        \\}
        \\exerciseEmptyLeafThrow();
    );
    setup.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval("exerciseEmptyLeafThrow()");
    result.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "inline empty leaf warm constructor preserves miss fallback and ownership" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const rt = js.runtime;
    const ctx = js.context;
    const global = try engine.exec.zjs_vm.contextGlobal(ctx);

    const setup = try js.eval("globalThis.__warmEmptyLeaf = function () { return 1; };");
    setup.free(rt);
    const leaf_name = try rt.internAtom("__warmEmptyLeaf");
    defer rt.atoms.free(leaf_name);
    const callable = global.getProperty(leaf_name);
    defer callable.free(rt);
    const resolved = inline_calls.resolveInlineFunction(global, callable) orelse
        return error.InvalidFunctionBytecode;
    try std.testing.expect(resolved.view.flags.simple_inline_empty_leaf);

    var l0_function = try helpers.makeFunction(rt, &.{op.return_undef});
    defer l0_function.deinit(rt);
    var l0_frame = engine.exec.frame.Frame.init(&l0_function);
    defer l0_frame.deinit(&rt.memory, rt);
    var l0_stack = engine.exec.stack.Stack.init(&rt.memory, rt.stackSize());
    defer l0_stack.deinit(rt);
    var catch_target: ?usize = null;
    const l0 = inline_calls.L0State{ .level = .{
        .frame = &l0_frame,
        .stack = &l0_stack,
        .catch_target = &catch_target,
    } };
    var machine = inline_calls.Machine.init(ctx, null, global, &l0);
    defer machine.deinit();
    const initial_call_depth = ctx.call_depth;

    // A fresh Machine has neither Entry nor arena backing. The speculative
    // arm must miss without consuming the source or changing call depth.
    try l0_stack.pushOwned(callable.dup());
    var region_start = l0_stack.topPtr() - 1;
    l0_stack.setTopPtr(region_start);
    const l0_resume_pc = l0_frame.function.code.ptr + l0_frame.pc;
    try std.testing.expect(machine.tryPushEmptyLeafCallFast(false, global, &l0_stack, resolved.view, region_start, l0_resume_pc) == null);
    try std.testing.expectEqual(initial_call_depth, ctx.call_depth);
    try std.testing.expect(!region_start[0].isUndefined());

    const first = try machine.pushEmptyLeafCall(false, global, &l0_stack, resolved.view, region_start);
    try std.testing.expect(first.isEmptyLeaf());
    machine.popReturnedEmptyLeaf();
    try std.testing.expectEqual(initial_call_depth, ctx.call_depth);
    const steady_bytes = rt.memory.allocated_bytes;

    // Entry and arena chunks are now warm. A second exact call must publish
    // the same leaf shape without touching the allocator.
    try l0_stack.pushOwned(callable.dup());
    region_start = l0_stack.topPtr() - 1;
    l0_stack.setTopPtr(region_start);
    const alloc_calls = rt.memory.alloc_calls;
    const create_calls = rt.memory.create_calls;
    const warm = machine.tryPushEmptyLeafCallFast(false, global, &l0_stack, resolved.view, region_start, l0_resume_pc) orelse
        return error.Unexpected;
    try std.testing.expect(warm.isEmptyLeaf());
    try std.testing.expectEqual(alloc_calls, rt.memory.alloc_calls);
    try std.testing.expectEqual(create_calls, rt.memory.create_calls);
    machine.popReturnedEmptyLeaf();
    try std.testing.expectEqual(steady_bytes, rt.memory.allocated_bytes);

    // An oversized operand window cannot use the active arena chunk. The fast
    // miss is pure and the authoritative constructor owns/frees heap backing.
    var oversized = resolved.view.*;
    oversized.stack_size = core.VmStackArena.chunk_slots;
    try l0_stack.pushOwned(callable.dup());
    region_start = l0_stack.topPtr() - 1;
    l0_stack.setTopPtr(region_start);
    try std.testing.expect(machine.tryPushEmptyLeafCallFast(false, global, &l0_stack, &oversized, region_start, l0_resume_pc) == null);
    try std.testing.expectEqual(initial_call_depth, ctx.call_depth);
    const heap_entry = try machine.pushEmptyLeafCall(false, global, &l0_stack, &oversized, region_start);
    try std.testing.expect(!heap_entry.isEmptyLeaf());
    var continuation = machine.popReturnedFrame();
    continuation.deinit(rt);
    try std.testing.expectEqual(steady_bytes, rt.memory.allocated_bytes);

    // The same miss under a hard memory cap must restore depth/watermark and
    // release the source slot, leaving the warmed Machine reusable.
    try l0_stack.pushOwned(callable.dup());
    region_start = l0_stack.topPtr() - 1;
    l0_stack.setTopPtr(region_start);
    rt.setMemoryLimit(rt.memory.allocated_bytes);
    const failed = machine.pushEmptyLeafCall(false, global, &l0_stack, &oversized, region_start);
    rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, failed);
    try std.testing.expectEqual(initial_call_depth, ctx.call_depth);
    try std.testing.expect(region_start[0].isUndefined());
    try std.testing.expectEqual(steady_bytes, rt.memory.allocated_bytes);
}

test "method call empty leaf binds receiver as this and balances refcounts" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const setup = try js.eval(
        \\Object.defineProperty(String.prototype, "__leafThis", {
        \\    value: function () { return this; },
        \\    configurable: true,
        \\});
        \\function exerciseMethodEmptyLeaf() {
        \\    const stable = { m() { return 1; }, self() { return this; } };
        \\    let total = 0;
        \\    for (let i = 0; i < 256; i++) {
        \\        total += stable.m();
        \\        if (stable.self() !== stable) throw new Error("stable this mismatch");
        \\        const fresh = { self() { return this; } };
        \\        if (fresh.self() !== fresh) throw new Error("fresh this mismatch");
        \\        const boxed = "abc".__leafThis();
        \\        if (typeof boxed !== "object" || String(boxed) !== "abc")
        \\            throw new Error("primitive receiver coercion mismatch");
        \\    }
        \\    assert.sameValue(total, 256);
        \\}
        \\exerciseMethodEmptyLeaf();
    );
    setup.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval("exerciseMethodEmptyLeaf()");
    result.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "method call empty leaf abrupt teardown releases receiver" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const setup = try js.eval(
        \\function exerciseMethodEmptyLeafThrow() {
        \\    for (let i = 0; i < 256; i++) {
        \\        const recv = { boom() { return null.missing; } };
        \\        try { recv.boom(); } catch (error) {}
        \\    }
        \\}
        \\exerciseMethodEmptyLeafThrow();
    );
    setup.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval("exerciseMethodEmptyLeafThrow()");
    result.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "method empty leaf warm constructor moves receiver ownership" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const rt = js.runtime;
    const ctx = js.context;
    const global = try engine.exec.zjs_vm.contextGlobal(ctx);

    const setup = try js.eval("globalThis.__warmMethodLeafRecv = { m() { return 1; } };");
    setup.free(rt);
    const holder_name = try rt.internAtom("__warmMethodLeafRecv");
    defer rt.atoms.free(holder_name);
    const receiver = global.getProperty(holder_name);
    defer receiver.free(rt);
    const receiver_object = object_ops.objectFromValue(receiver) orelse
        return error.Unexpected;
    const method_name = try rt.internAtom("m");
    defer rt.atoms.free(method_name);
    const callable = receiver_object.getProperty(method_name);
    defer callable.free(rt);
    const resolved = inline_calls.resolveInlineFunction(global, callable) orelse
        return error.InvalidFunctionBytecode;
    try std.testing.expect(resolved.view.flags.simple_inline_empty_leaf);

    var l0_function = try helpers.makeFunction(rt, &.{op.return_undef});
    defer l0_function.deinit(rt);
    var l0_frame = engine.exec.frame.Frame.init(&l0_function);
    defer l0_frame.deinit(&rt.memory, rt);
    var l0_stack = engine.exec.stack.Stack.init(&rt.memory, rt.stackSize());
    defer l0_stack.deinit(rt);
    var catch_target: ?usize = null;
    const l0 = inline_calls.L0State{ .level = .{
        .frame = &l0_frame,
        .stack = &l0_stack,
        .catch_target = &catch_target,
    } };
    var machine = inline_calls.Machine.init(ctx, null, global, &l0);
    defer machine.deinit();
    const initial_call_depth = ctx.call_depth;
    const baseline_rc = receiver_object.header.meta().rc;

    // Fresh Machine: the speculative arm must miss without consuming either
    // slot of the [receiver, callable] region or changing call depth.
    try l0_stack.pushOwned(receiver.dup());
    try l0_stack.pushOwned(callable.dup());
    var region_start = l0_stack.topPtr() - 2;
    l0_stack.setTopPtr(region_start);
    const l0_resume_pc = l0_frame.function.code.ptr + l0_frame.pc;
    try std.testing.expect(machine.tryPushEmptyLeafCallFast(true, global, &l0_stack, resolved.view, region_start, l0_resume_pc) == null);
    try std.testing.expectEqual(initial_call_depth, ctx.call_depth);
    try std.testing.expect(!region_start[0].isUndefined());
    try std.testing.expect(!region_start[1].isUndefined());

    // Authoritative constructor: receiver moves into the frame's owned raw
    // `this` (region slot cleared, no extra refcount), and the empty-leaf
    // return epilogue releases exactly that moved reference.
    const first = try machine.pushEmptyLeafCall(true, global, &l0_stack, resolved.view, region_start);
    try std.testing.expect(first.isEmptyLeaf());
    try std.testing.expect(first.frame.this_value.same(receiver));
    try std.testing.expect(first.frame.ownership.this_value == .owned);
    try std.testing.expect(region_start[0].isUndefined());
    try std.testing.expectEqual(baseline_rc + 1, receiver_object.header.meta().rc);
    machine.popReturnedEmptyLeaf();
    try std.testing.expectEqual(baseline_rc, receiver_object.header.meta().rc);
    try std.testing.expectEqual(initial_call_depth, ctx.call_depth);
    const steady_bytes = rt.memory.allocated_bytes;

    // Warm hit: same leaf shape, allocation-free, same ownership movement.
    try l0_stack.pushOwned(receiver.dup());
    try l0_stack.pushOwned(callable.dup());
    region_start = l0_stack.topPtr() - 2;
    l0_stack.setTopPtr(region_start);
    const alloc_calls = rt.memory.alloc_calls;
    const create_calls = rt.memory.create_calls;
    const warm = machine.tryPushEmptyLeafCallFast(true, global, &l0_stack, resolved.view, region_start, l0_resume_pc) orelse
        return error.Unexpected;
    try std.testing.expect(warm.isEmptyLeaf());
    try std.testing.expect(warm.frame.this_value.same(receiver));
    try std.testing.expect(warm.frame.ownership.this_value == .owned);
    try std.testing.expectEqual(alloc_calls, rt.memory.alloc_calls);
    try std.testing.expectEqual(create_calls, rt.memory.create_calls);
    try std.testing.expectEqual(baseline_rc + 1, receiver_object.header.meta().rc);
    machine.popReturnedEmptyLeaf();
    try std.testing.expectEqual(baseline_rc, receiver_object.header.meta().rc);
    try std.testing.expectEqual(steady_bytes, rt.memory.allocated_bytes);

    // Setup failure must restore depth/watermark and release BOTH region
    // slots — receiver and callable — leaving the warmed Machine reusable.
    var oversized = resolved.view.*;
    oversized.stack_size = core.VmStackArena.chunk_slots;
    try l0_stack.pushOwned(receiver.dup());
    try l0_stack.pushOwned(callable.dup());
    region_start = l0_stack.topPtr() - 2;
    l0_stack.setTopPtr(region_start);
    rt.setMemoryLimit(rt.memory.allocated_bytes);
    const failed = machine.pushEmptyLeafCall(true, global, &l0_stack, &oversized, region_start);
    rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, failed);
    try std.testing.expectEqual(initial_call_depth, ctx.call_depth);
    try std.testing.expect(region_start[0].isUndefined());
    try std.testing.expect(region_start[1].isUndefined());
    try std.testing.expectEqual(baseline_rc, receiver_object.header.meta().rc);
    try std.testing.expectEqual(steady_bytes, rt.memory.allocated_bytes);
}

test "inline call teardown releases every escaped storage shape" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    helpers.registerStandardGlobalsBare(rt);
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try engine.exec.zjs_vm.contextGlobal(ctx);

    var l0_function = try helpers.makeFunction(rt, &.{op.return_undef});
    defer l0_function.deinit(rt);
    var l0_frame = engine.exec.frame.Frame.init(&l0_function);
    defer l0_frame.deinit(&rt.memory, rt);
    var l0_stack = engine.exec.stack.Stack.init(&rt.memory, rt.stackSize());
    defer l0_stack.deinit(rt);
    var catch_target: ?usize = null;
    const l0 = inline_calls.L0State{ .level = .{
        .frame = &l0_frame,
        .stack = &l0_stack,
        .catch_target = &catch_target,
    } };
    var machine = inline_calls.Machine.init(ctx, null, global, &l0);
    defer machine.deinit();

    var function = try helpers.makeFunction(rt, &.{op.return_undef});
    defer function.deinit(rt);
    function.simple_inline_eligible = true;
    var fb = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    defer fb.deinit(rt);
    var unused_var_refs: [1]*core.VarRef = undefined;
    const target = inline_calls.InlineTarget{
        .var_refs = &unused_var_refs,
        .callable = core.JSValue.undefinedValue(),
        .fb = &fb,
        .view = &function,
        .this_value = core.JSValue.undefinedValue(),
        .new_target = core.JSValue.undefinedValue(),
    };

    // Warm the Machine's Entry chunk and the VM stack-arena chunk; neither is
    // per-call storage, so take the balance baseline only after this call.
    try l0_stack.pushOwned(core.JSValue.undefinedValue());
    l0_stack.setLen(0);
    _ = try machine.pushCall(global, &l0_stack, &target, l0_stack.topPtr(), 0, .plain);
    var continuation = machine.popFrame();
    continuation.deinit(rt);
    const baseline_bytes = rt.memory.allocated_bytes;

    try l0_stack.pushOwned(core.JSValue.undefinedValue());
    l0_stack.setLen(0);
    var entry = try machine.pushCall(global, &l0_stack, &target, l0_stack.topPtr(), 0, .plain);
    _ = try entry.frame.ensureCold(&rt.memory);
    continuation = machine.popFrame();
    continuation.deinit(rt);
    try std.testing.expectEqual(baseline_bytes, rt.memory.allocated_bytes);

    try l0_stack.pushOwned(core.JSValue.undefinedValue());
    l0_stack.setLen(0);
    entry = try machine.pushCall(global, &l0_stack, &target, l0_stack.topPtr(), 0, .plain);
    _ = try entry.frame.allocOwnedStorage(&rt.memory, 1);
    continuation = machine.popFrame();
    continuation.deinit(rt);
    try std.testing.expectEqual(baseline_bytes, rt.memory.allocated_bytes);

    try l0_stack.pushOwned(core.JSValue.undefinedValue());
    l0_stack.setLen(0);
    entry = try machine.pushCall(global, &l0_stack, &target, l0_stack.topPtr(), 0, .plain);
    try entry.stack.reserveAdditional(entry.stack.capacity + 1);
    continuation = machine.popFrame();
    continuation.deinit(rt);
    try std.testing.expectEqual(baseline_bytes, rt.memory.allocated_bytes);

    // A window larger than one arena chunk uses the setup-time heap fallback.
    function.stack_size = core.VmStackArena.chunk_slots;
    try l0_stack.pushOwned(core.JSValue.undefinedValue());
    l0_stack.setLen(0);
    _ = try machine.pushCall(global, &l0_stack, &target, l0_stack.topPtr(), 0, .plain);
    continuation = machine.popFrame();
    continuation.deinit(rt);
    try std.testing.expectEqual(baseline_bytes, rt.memory.allocated_bytes);
}

test "inline operand Stack keeps limit and ownership flags in one word" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(engine.exec.stack.Stack));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(inline_calls.Machine.ArgsSource));
    if (core.value.nan_boxing) {
        try std.testing.expectEqual(@as(usize, 136), @sizeOf(engine.exec.frame.Frame));
        try std.testing.expectEqual(@as(usize, 248), @sizeOf(inline_calls.Entry));
    }
}

test "method calls preserve receiver arguments eval captures and abrupt ownership" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const receiver = { value: 4 };
        \\receiver.sloppy = function sloppy(first, second) {
        \\    assert.sameValue(this, receiver);
        \\    assert.sameValue(arguments.length, 1);
        \\    first = 7;
        \\    second = 8;
        \\    assert.sameValue(arguments[0], 7);
        \\    assert.sameValue(arguments.hasOwnProperty("1"), false);
        \\    return this;
        \\};
        \\assert.sameValue(receiver.sloppy(1), receiver);
        \\receiver.strict = function strict(first, second) {
        \\    "use strict";
        \\    assert.sameValue(this, receiver);
        \\    first = 7;
        \\    second = 8;
        \\    assert.sameValue(arguments.length, 1);
        \\    assert.sameValue(arguments[0], 1);
        \\    assert.sameValue(arguments.hasOwnProperty("1"), false);
        \\    return this;
        \\};
        \\assert.sameValue(receiver.strict(1), receiver);
        \\receiver.capture = function capture(value) {
        \\    return () => this;
        \\};
        \\assert.sameValue(receiver.capture()(), receiver);
        \\receiver.evalThis = function evalThis(value) {
        \\    return eval("this");
        \\};
        \\assert.sameValue(receiver.evalThis(), receiver);
        \\receiver.escape = function escape(first, second) { return arguments; };
        \\const escaped = receiver.escape(receiver);
        \\assert.sameValue(escaped.length, 1);
        \\assert.sameValue(escaped[0], receiver);
        \\assert.sameValue(escaped.hasOwnProperty("1"), false);
        \\receiver.thrower = function thrower(first, second) { throw this; };
        \\try {
        \\    receiver.thrower(receiver);
        \\} catch (thrown) {
        \\    assert.sameValue(thrown, receiver);
        \\}
        \\let getterReceiver;
        \\const accessor = {
        \\    get method() {
        \\        getterReceiver = this;
        \\        return function selected() { return this; };
        \\    }
        \\};
        \\assert.sameValue(accessor.method(), accessor);
        \\assert.sameValue(getterReceiver, accessor);
        \\const proxy = new Proxy(receiver, {});
        \\assert.sameValue(proxy.capture()(), proxy);
        \\String.prototype.strictReceiver = function strictReceiver() {
        \\    "use strict";
        \\    return this;
        \\};
        \\assert.sameValue("x".strictReceiver(), "x");
        \\delete String.prototype.strictReceiver;
        \\Number.prototype.sloppyReceiver = function sloppyReceiver() {
        \\    return Object.getPrototypeOf(this) === Number.prototype && this.valueOf();
        \\};
        \\assert.sameValue((4).sloppyReceiver(), 4);
        \\delete Number.prototype.sloppyReceiver;
        \\Number.prototype.arrowReceiver = function arrowReceiver() {
        \\    return () => this;
        \\};
        \\const readArrowReceiver = (5).arrowReceiver();
        \\const arrowBox = readArrowReceiver();
        \\assert.sameValue(Object.getPrototypeOf(arrowBox), Number.prototype);
        \\assert.sameValue(arrowBox.valueOf(), 5);
        \\assert.sameValue(readArrowReceiver(), arrowBox);
        \\delete Number.prototype.arrowReceiver;
        \\Number.prototype.evalReceiver = function evalReceiver() {
        \\    return eval("this");
        \\};
        \\const evalBox = (6).evalReceiver();
        \\assert.sameValue(Object.getPrototypeOf(evalBox), Number.prototype);
        \\assert.sameValue(evalBox.valueOf(), 6);
        \\delete Number.prototype.evalReceiver;
        \\function sloppyViaCall() { return this; }
        \\const callBox = sloppyViaCall.call(7);
        \\assert.sameValue(Object.getPrototypeOf(callBox), Number.prototype);
        \\assert.sameValue(callBox.valueOf(), 7);
        \\assert.sameValue(sloppyViaCall.call(null), globalThis);
        \\assert.sameValue(sloppyViaCall.call(undefined), globalThis);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "primitive prototype lookup preserves raw receiver and exotic prototype semantics" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const dataKey = "__zjs_primitive_data_probe__";
        \\const inheritedKey = "__zjs_primitive_inherited_probe__";
        \\const strictGetterKey = "__zjs_primitive_strict_getter_probe__";
        \\const sloppyGetterKey = "__zjs_primitive_sloppy_getter_probe__";
        \\const proxyKey = "__zjs_primitive_proxy_probe__";
        \\const staticDataKey = "__zjs_primitive_static_data_probe__";
        \\const staticGetterKey = "__zjs_primitive_static_getter_probe__";
        \\const staticProxyKey = "__zjs_primitive_static_proxy_probe__";
        \\const originalNumberParent = Object.getPrototypeOf(Number.prototype);
        \\const intrinsicBigInt = BigInt;
        \\const intrinsicSymbol = Symbol;
        \\const bigintPrototype = BigInt.prototype;
        \\const symbolPrototype = Symbol.prototype;
        \\const symbolValue = Symbol("s");
        \\try {
        \\    Number.prototype[dataKey] = 11;
        \\    Boolean.prototype[dataKey] = 12;
        \\    String.prototype[dataKey] = 13;
        \\    bigintPrototype[dataKey] = 14;
        \\    symbolPrototype[dataKey] = 15;
        \\    Object.prototype[inheritedKey] = 16;
        \\    Number.prototype[staticDataKey] = 19;
        \\    assert.sameValue((1)[dataKey], 11);
        \\    assert.sameValue(true[dataKey], 12);
        \\    assert.sameValue("x"[dataKey], 13);
        \\    assert.sameValue((1n)[dataKey], 14);
        \\    assert.sameValue(symbolValue[dataKey], 15);
        \\    assert.sameValue((2)[inheritedKey], 16);
        \\    assert.sameValue("x"[inheritedKey], 16);
        \\    assert.sameValue((2).__zjs_primitive_static_data_probe__, 19);
        \\    globalThis.BigInt = function ReplacementBigInt() {};
        \\    globalThis.Symbol = function ReplacementSymbol() {};
        \\    assert.sameValue((1n)[dataKey], 14);
        \\    assert.sameValue(symbolValue[dataKey], 15);
        \\    Object.defineProperty(Number.prototype, strictGetterKey, {
        \\        configurable: true,
        \\        get: function primitiveStrictGetter() {
        \\            "use strict";
        \\            return this;
        \\        },
        \\    });
        \\    Object.defineProperty(Number.prototype, sloppyGetterKey, {
        \\        configurable: true,
        \\        get: function primitiveSloppyGetter() {
        \\            return Object.getPrototypeOf(this) === Number.prototype && this.valueOf();
        \\        },
        \\    });
        \\    Object.defineProperty(Number.prototype, staticGetterKey, {
        \\        configurable: true,
        \\        get: function primitiveStaticGetter() {
        \\            "use strict";
        \\            return this;
        \\        },
        \\    });
        \\    assert.sameValue((3)[strictGetterKey], 3);
        \\    assert.sameValue((4)[sloppyGetterKey], 4);
        \\    assert.sameValue((5).__zjs_primitive_static_getter_probe__, 5);
        \\    const parent = Object.create(originalNumberParent);
        \\    parent[inheritedKey] = 17;
        \\    Object.setPrototypeOf(Number.prototype, parent);
        \\    assert.sameValue((5)[inheritedKey], 17);
        \\    let seenReceiver;
        \\    let trapCount = 0;
        \\    const proxy = new Proxy(parent, {
        \\        get(target, key, receiver) {
        \\            trapCount++;
        \\            if (key === proxyKey || key === staticProxyKey) {
        \\                seenReceiver = receiver;
        \\                return 18;
        \\            }
        \\            return Reflect.get(target, key, receiver);
        \\        },
        \\    });
        \\    Object.setPrototypeOf(Number.prototype, proxy);
        \\    assert.sameValue((6)[proxyKey], 18);
        \\    assert.sameValue(seenReceiver, 6);
        \\    assert.sameValue(trapCount, 1);
        \\    assert.sameValue((6).__zjs_primitive_static_proxy_probe__, 18);
        \\    assert.sameValue(seenReceiver, 6);
        \\    assert.sameValue(trapCount, 2);
        \\    assert.sameValue((7).__zjs_primitive_missing_probe__, undefined);
        \\    String.prototype[0] = "prototype";
        \\    assert.sameValue("a"[0], "a");
        \\    assert.sameValue("a".length, 1);
        \\} finally {
        \\    globalThis.BigInt = intrinsicBigInt;
        \\    globalThis.Symbol = intrinsicSymbol;
        \\    Object.setPrototypeOf(Number.prototype, originalNumberParent);
        \\    delete Number.prototype[dataKey];
        \\    delete Boolean.prototype[dataKey];
        \\    delete String.prototype[dataKey];
        \\    delete bigintPrototype[dataKey];
        \\    delete symbolPrototype[dataKey];
        \\    delete Object.prototype[inheritedKey];
        \\    delete Number.prototype[strictGetterKey];
        \\    delete Number.prototype[sloppyGetterKey];
        \\    delete Number.prototype[staticDataKey];
        \\    delete Number.prototype[staticGetterKey];
        \\    delete String.prototype[0];
        \\}
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "computed named reads preserve prototype accessors proxies and operand ownership" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const dataKey = "__zjs_computed_data_probe__";
        \\const getterKey = "__zjs_computed_getter_probe__";
        \\const emptyGetterKey = "__zjs_computed_empty_getter_probe__";
        \\const throwingGetterKey = "__zjs_computed_throwing_getter_probe__";
        \\const proxyKey = "__zjs_computed_proxy_probe__";
        \\const selfKey = "__zjs_computed_self_probe__";
        \\const prototype = {};
        \\prototype[dataKey] = 11;
        \\const object = Object.create(prototype);
        \\assert.sameValue(object[dataKey], 11);
        \\let getterReceiver;
        \\let getterCount = 0;
        \\Object.defineProperty(prototype, getterKey, {
        \\    configurable: true,
        \\    get() {
        \\        getterReceiver = this;
        \\        getterCount++;
        \\        return 12;
        \\    },
        \\});
        \\assert.sameValue(object[getterKey], 12);
        \\assert.sameValue(getterReceiver, object);
        \\assert.sameValue(getterCount, 1);
        \\Object.defineProperty(prototype, emptyGetterKey, {
        \\    configurable: true,
        \\    get: undefined,
        \\});
        \\assert.sameValue(object[emptyGetterKey], undefined);
        \\Object.defineProperty(prototype, throwingGetterKey, {
        \\    configurable: true,
        \\    get() { throw new Error("computed getter sentinel"); },
        \\});
        \\let caughtMessage;
        \\try {
        \\    object[throwingGetterKey];
        \\} catch (error) {
        \\    caughtMessage = error.message;
        \\}
        \\assert.sameValue(caughtMessage, "computed getter sentinel");
        \\let proxyReceiver;
        \\let proxyCount = 0;
        \\const proxy = new Proxy(prototype, {
        \\    get(target, key, receiver) {
        \\        proxyReceiver = receiver;
        \\        proxyCount++;
        \\        if (key === proxyKey) return 13;
        \\        return Reflect.get(target, key, receiver);
        \\    },
        \\});
        \\const proxyObject = Object.create(proxy);
        \\assert.sameValue(proxyObject[proxyKey], 13);
        \\assert.sameValue(proxyReceiver, proxyObject);
        \\assert.sameValue(proxyCount, 1);
        \\object[selfKey] = object;
        \\assert.sameValue(object[selfKey], object);
        \\object[dataKey] = dataKey;
        \\assert.sameValue(object[dataKey], dataKey);
        \\assert.sameValue(Object.create(null)[dataKey], undefined);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "static named getter and proxy fast paths preserve receivers throws and invariants" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const prototype = {};
        \\let getterReceiver;
        \\let getterCount = 0;
        \\Object.defineProperty(prototype, "__zjs_static_getter_probe__", {
        \\    get() {
        \\        getterReceiver = this;
        \\        getterCount++;
        \\        return 21;
        \\    },
        \\});
        \\const object = Object.create(prototype);
        \\assert.sameValue(object.__zjs_static_getter_probe__, 21);
        \\assert.sameValue(getterReceiver, object);
        \\assert.sameValue(getterCount, 1);
        \\Object.defineProperty(prototype, "__zjs_static_throw_probe__", {
        \\    get() { throw new Error("static getter sentinel"); },
        \\});
        \\let getterThrow;
        \\try {
        \\    object.__zjs_static_throw_probe__;
        \\} catch (error) {
        \\    getterThrow = error.message;
        \\}
        \\assert.sameValue(getterThrow, "static getter sentinel");
        \\let primitiveReceiver;
        \\Object.defineProperty(Number.prototype, "__zjs_static_primitive_probe__", {
        \\    configurable: true,
        \\    get: function staticPrimitiveGetter() {
        \\        "use strict";
        \\        primitiveReceiver = this;
        \\        return 22;
        \\    },
        \\});
        \\assert.sameValue((1).__zjs_static_primitive_probe__, 22);
        \\assert.sameValue(primitiveReceiver, 1);
        \\delete Number.prototype.__zjs_static_primitive_probe__;
        \\let forwardedReceiver;
        \\const forwardedTarget = {};
        \\Object.defineProperty(forwardedTarget, "__zjs_static_forward_probe__", {
        \\    get() {
        \\        forwardedReceiver = this;
        \\        return 23;
        \\    },
        \\});
        \\const forwardedProxy = new Proxy(forwardedTarget, {});
        \\assert.sameValue(forwardedProxy.__zjs_static_forward_probe__, 23);
        \\assert.sameValue(forwardedReceiver, forwardedProxy);
        \\let handlerGetterReceiver;
        \\const handler = {};
        \\Object.defineProperty(handler, "get", {
        \\    get() {
        \\        handlerGetterReceiver = this;
        \\        return function (target, key, receiver) {
        \\            assert.sameValue(receiver, trappedProxy);
        \\            return 24;
        \\        };
        \\    },
        \\});
        \\const trappedProxy = new Proxy({}, handler);
        \\assert.sameValue(trappedProxy.__zjs_static_trap_probe__, 24);
        \\assert.sameValue(handlerGetterReceiver, handler);
        \\const frozenTarget = {};
        \\Object.defineProperty(frozenTarget, "frozen", {
        \\    value: 25,
        \\    writable: false,
        \\    configurable: false,
        \\});
        \\assert.sameValue(new Proxy(frozenTarget, { get() { return 25; } }).frozen, 25);
        \\let frozenRejected = false;
        \\try {
        \\    new Proxy(frozenTarget, { get() { return 26; } }).frozen;
        \\} catch (error) {
        \\    frozenRejected = error instanceof TypeError;
        \\}
        \\assert.sameValue(frozenRejected, true);
        \\const mutationTarget = { marker: 1 };
        \\const mutationProxy = new Proxy(mutationTarget, {
        \\    get(target, key) {
        \\        Object.defineProperty(target, key, {
        \\            value: 1,
        \\            writable: false,
        \\            configurable: false,
        \\        });
        \\        return 2;
        \\    },
        \\});
        \\let mutationRejected = false;
        \\try {
        \\    mutationProxy.marker;
        \\} catch (error) {
        \\    mutationRejected = error instanceof TypeError;
        \\}
        \\assert.sameValue(mutationRejected, true);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "proxy bytecode get continuation does not require spare operand capacity" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function readX(object) { return object.x; }
        \\const proxy = new Proxy({ x: 1 }, {
        \\    get(target, key, receiver) {
        \\        return Reflect.get(target, key, receiver);
        \\    },
        \\});
        \\assert.sameValue(readX(proxy), 1);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "for-of bytecode next continuation preserves result and abrupt semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let events = [];
        \\let step = 0;
        \\function tailStep() {
        \\    if (step++ === 0) {
        \\        return {
        \\            get done() { events.push("done:false"); return false; },
        \\            get value() { events.push("value"); return 7; },
        \\        };
        \\    }
        \\    return {
        \\        get done() { events.push("done:true"); return true; },
        \\        get value() { throw new Error("done value was read"); },
        \\    };
        \\}
        \\const tailIterator = {
        \\    [Symbol.iterator]() { return this; },
        \\    next() { "use strict"; return tailStep(); },
        \\};
        \\let sum = 0;
        \\for (const value of tailIterator) sum += value;
        \\assert.sameValue(sum, 7);
        \\assert.sameValue(events.join(","), "done:false,value,done:true");
        \\
        \\let nextCalls = 0;
        \\let closeCalls = 0;
        \\const throwingIterator = {
        \\    [Symbol.iterator]() { return this; },
        \\    next() {
        \\        if (nextCalls++ === 0) return { value: 3, done: false };
        \\        throw new Error("next sentinel");
        \\    },
        \\    return() { closeCalls++; return { done: true }; },
        \\};
        \\let caught = false;
        \\try {
        \\    for (const value of throwingIterator) assert.sameValue(value, 3);
        \\} catch (error) {
        \\    caught = error.message === "next sentinel";
        \\}
        \\assert.sameValue(caught, true);
        \\assert.sameValue(closeCalls, 0);
        \\
        \\let arrowStep = 0;
        \\const arrowIterator = {
        \\    [Symbol.iterator]() { return this; },
        \\    next: () => arrowStep++ === 0
        \\        ? { value: 11, done: false }
        \\        : { done: true },
        \\};
        \\let arrowSum = 0;
        \\for (const value of arrowIterator) arrowSum += value;
        \\assert.sameValue(arrowSum, 11);
        \\
        \\let inheritedStep = 0;
        \\const inheritedResult = Object.create({ value: 13 });
        \\inheritedResult.done = false;
        \\const inheritedIterator = {
        \\    [Symbol.iterator]() { return this; },
        \\    next() { return inheritedStep++ === 0 ? inheritedResult : { done: true }; },
        \\};
        \\let inheritedSum = 0;
        \\for (const value of inheritedIterator) inheritedSum += value;
        \\assert.sameValue(inheritedSum, 13);
        \\
        \\let proxyStep = 0;
        \\let proxyReads = [];
        \\const proxyResult = new Proxy({ value: 17, done: false }, {
        \\    get(target, key, receiver) {
        \\        proxyReads.push(key);
        \\        return Reflect.get(target, key, receiver);
        \\    },
        \\});
        \\const proxyIterator = {
        \\    [Symbol.iterator]() { return this; },
        \\    next() { return proxyStep++ === 0 ? proxyResult : { done: true }; },
        \\};
        \\let proxySum = 0;
        \\for (const value of proxyIterator) proxySum += value;
        \\assert.sameValue(proxySum, 17);
        \\assert.sameValue(proxyReads.join(","), "done,value");
        \\
        \\let paddedStep = 0;
        \\const paddedIterator = {
        \\    [Symbol.iterator]() { return this; },
        \\    next(unused) {
        \\        "use strict";
        \\        assert.sameValue(unused, undefined);
        \\        assert.sameValue(arguments.length, 0);
        \\        return paddedStep++ === 0 ? { value: 19, done: false } : { done: true };
        \\    },
        \\};
        \\let paddedSum = 0;
        \\for (const value of paddedIterator) paddedSum += value;
        \\assert.sameValue(paddedSum, 19);
        \\
        \\let cachedStep = 0;
        \\const cachedMethodIterator = {
        \\    [Symbol.iterator]() { return this; },
        \\    next() {
        \\        this.next = null;
        \\        return cachedStep++ === 0 ? { value: 23, done: false } : { done: true };
        \\    },
        \\};
        \\let cachedMethodSum = 0;
        \\for (const value of cachedMethodIterator) cachedMethodSum += value;
        \\assert.sameValue(cachedMethodSum, 23);
        \\assert.sameValue(cachedMethodIterator.next, null);
        \\
        \\const falloffIterator = {
        \\    [Symbol.iterator]() { return this; },
        \\    next() {},
        \\};
        \\let sawTypeError = false;
        \\try {
        \\    for (const value of falloffIterator) {}
        \\} catch (error) {
        \\    sawTypeError = error instanceof TypeError;
        \\}
        \\assert.sameValue(sawTypeError, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "computed proxy bytecode trap continuations preserve nested calls throws and invariants" {
    engine.exec.standard_globals.registerStandardGlobalsDefault();
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const key = ["__zjs_computed_", "proxy_probe__"].join("");
        \\let trapCount = 0;
        \\let seenTarget;
        \\let seenKey;
        \\let seenReceiver;
        \\const basicTarget = {};
        \\const basicProxy = new Proxy(basicTarget, {
        \\    get(target, propertyKey, receiver) {
        \\        trapCount++;
        \\        seenTarget = target;
        \\        seenKey = propertyKey;
        \\        seenReceiver = receiver;
        \\        return 31;
        \\    },
        \\});
        \\for (let i = 0; i < 3; i++) {
        \\    assert.sameValue(basicProxy[key], 31);
        \\}
        \\assert.sameValue(trapCount, 3);
        \\assert.sameValue(seenTarget, basicTarget);
        \\assert.sameValue(seenKey, key);
        \\assert.sameValue(seenReceiver, basicProxy);
        \\const falloffProxy = new Proxy({}, {
        \\    get() {},
        \\});
        \\for (let i = 0; i < 3; i++) {
        \\    assert.sameValue(falloffProxy[key], undefined);
        \\}
        \\let throwCount = 0;
        \\const throwingProxy = new Proxy({}, {
        \\    get() { throw new Error("computed proxy sentinel"); },
        \\});
        \\for (let i = 0; i < 3; i++) {
        \\    try {
        \\        throwingProxy[key];
        \\    } catch (error) {
        \\        assert.sameValue(error.message, "computed proxy sentinel");
        \\        throwCount++;
        \\    }
        \\}
        \\assert.sameValue(throwCount, 3);
        \\let innerCount = 0;
        \\let outerCount = 0;
        \\const innerProxy = new Proxy({}, {
        \\    get() {
        \\        innerCount++;
        \\        return 32;
        \\    },
        \\});
        \\const outerProxy = new Proxy({}, {
        \\    get() {
        \\        outerCount++;
        \\        return innerProxy[key];
        \\    },
        \\});
        \\for (let i = 0; i < 3; i++) {
        \\    assert.sameValue(outerProxy[key], 32);
        \\}
        \\assert.sameValue(innerCount, 3);
        \\assert.sameValue(outerCount, 3);
        \\const frozenTarget = {};
        \\Object.defineProperty(frozenTarget, key, {
        \\    value: 33,
        \\    writable: false,
        \\    configurable: false,
        \\});
        \\const correctFrozenProxy = new Proxy(frozenTarget, {
        \\    get() { return 33; },
        \\});
        \\for (let i = 0; i < 3; i++) {
        \\    assert.sameValue(correctFrozenProxy[key], 33);
        \\}
        \\const rejectedFrozenProxy = new Proxy(frozenTarget, {
        \\    get() { return 34; },
        \\});
        \\let frozenRejected = 0;
        \\for (let i = 0; i < 3; i++) {
        \\    try {
        \\        rejectedFrozenProxy[key];
        \\    } catch (error) {
        \\        if (error instanceof TypeError) frozenRejected++;
        \\    }
        \\}
        \\assert.sameValue(frozenRejected, 3);
        \\function tailWrongFrozenValue() { return 34; }
        \\const tailRejectedProxy = new Proxy(frozenTarget, {
        \\    get() { return tailWrongFrozenValue(); },
        \\});
        \\let tailRejected = 0;
        \\for (let i = 0; i < 3; i++) {
        \\    try {
        \\        tailRejectedProxy[key];
        \\    } catch (error) {
        \\        if (error instanceof TypeError) tailRejected++;
        \\    }
        \\}
        \\assert.sameValue(tailRejected, 3);
        \\const catchingProxy = new Proxy({}, {
        \\    get() {
        \\        try {
        \\            return rejectedFrozenProxy[key];
        \\        } catch (error) {
        \\            assert.sameValue(error instanceof TypeError, true);
        \\            return 35;
        \\        }
        \\    },
        \\});
        \\for (let i = 0; i < 3; i++) {
        \\    assert.sameValue(catchingProxy[key], 35);
        \\}
        \\const mutationTarget = { marker: 1 };
        \\const mutationProxy = new Proxy(mutationTarget, {
        \\    get(target, propertyKey) {
        \\        Object.defineProperty(target, propertyKey, {
        \\            value: 36,
        \\            writable: false,
        \\            configurable: false,
        \\        });
        \\        return 37;
        \\    },
        \\});
        \\let mutationRejected = 0;
        \\for (let i = 0; i < 3; i++) {
        \\    try {
        \\        mutationProxy[key];
        \\    } catch (error) {
        \\        if (error instanceof TypeError) mutationRejected++;
        \\    }
        \\}
        \\assert.sameValue(mutationRejected, 3);
        \\const targetAlias = {};
        \\const targetAliasProxy = new Proxy(targetAlias, {
        \\    get(target) { return target; },
        \\});
        \\const receiverAliasProxy = new Proxy({}, {
        \\    get(target, propertyKey, receiver) { return receiver; },
        \\});
        \\const keyAliasProxy = new Proxy({}, {
        \\    get(target, propertyKey) { return propertyKey; },
        \\});
        \\for (let i = 0; i < 3; i++) {
        \\    assert.sameValue(targetAliasProxy[key], targetAlias);
        \\    assert.sameValue(receiverAliasProxy[key], receiverAliasProxy);
        \\    assert.sameValue(keyAliasProxy[key], key);
        \\}
        \\const paddedProxy = new Proxy({}, {
        \\    get(target, propertyKey, receiver, missing) {
        \\        assert.sameValue(missing, undefined);
        \\        return 38;
        \\    },
        \\});
        \\const snapshotPaddedProxy = new Proxy({}, {
        \\    get: function (target, propertyKey, receiver, missing) {
        \\        "use strict";
        \\        assert.sameValue(arguments.length, 3);
        \\        assert.sameValue(arguments[0], target);
        \\        assert.sameValue(arguments[1], propertyKey);
        \\        assert.sameValue(arguments[2], receiver);
        \\        assert.sameValue(missing, undefined);
        \\        target = null;
        \\        assert.notSameValue(arguments[0], target);
        \\        return 39;
        \\    },
        \\});
        \\for (let i = 0; i < 3; i++) {
        \\    assert.sameValue(paddedProxy[key], 38);
        \\    assert.sameValue(snapshotPaddedProxy[key], 39);
        \\}
        \\let handlerLookupCount = 0;
        \\const accessorHandler = {};
        \\Object.defineProperty(accessorHandler, "get", {
        \\    get() {
        \\        handlerLookupCount++;
        \\        return function () { return 40; };
        \\    },
        \\});
        \\const accessorHandlerProxy = new Proxy({}, accessorHandler);
        \\for (let i = 0; i < 3; i++) {
        \\    assert.sameValue(accessorHandlerProxy[key], 40);
        \\}
        \\assert.sameValue(handlerLookupCount, 3);
        \\let descriptorCount = 0;
        \\const descriptorTarget = new Proxy({}, {
        \\    getOwnPropertyDescriptor(target, propertyKey) {
        \\        descriptorCount++;
        \\        return Reflect.getOwnPropertyDescriptor(target, propertyKey);
        \\    },
        \\});
        \\const descriptorProxy = new Proxy(descriptorTarget, {
        \\    get() { return 41; },
        \\});
        \\for (let i = 0; i < 3; i++) {
        \\    assert.sameValue(descriptorProxy[key], 41);
        \\}
        \\assert.sameValue(descriptorCount, 3);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Phase 7: arrow and method tail calls reuse inline frames for deep recursion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    // Each recursion goes 40000 deep — past both the native-recursion limit
    // (`max(16, stack_limit/16384)`) and the inline-frame storage cap
    // (`max_chunks * entries_per_chunk` = 8192), so it only completes if the
    // tail call REUSES the inline frame rather than pushing a new one (Phase 7).
    // test262 has no coverage for deep tail recursion at the arrow or method
    // position, so this is the self-built fixture. Arrows gained inline
    // eligibility (lexical this/new.target routed through the shared frame-setup
    // boxing primitive); `tail_call_method` reuses the frame with the receiver
    // as `this` (mutual `even`/`odd` and self `loop`).
    const result = try js.evalWithOutput(
        \\const arrowTail = (n, acc) => n === 0 ? acc : arrowTail(n - 1, acc + 1);
        \\print(arrowTail(40000, 0));
        \\const machine = {
        \\  even(n) { return n === 0 ? "even" : this.odd(n - 1); },
        \\  odd(n) { return n === 0 ? "odd" : this.even(n - 1); },
        \\};
        \\print(machine.even(40000));
        \\const counter = { loop(n, acc) { return n === 0 ? acc : this.loop(n - 1, acc + n); } };
        \\print(counter.loop(40000, 0));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("40000\neven\n800020000\n", stream.buffered());
}

test "Phase 7: inlined arrow keeps lexical this and ignores any receiver" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    // An arrow captures `this` lexically; once it is inline-eligible, the shared
    // frame setup must still bind the lexical `this` (not the plain-call default
    // or the method receiver). `bound.call(other)`/`carrier.m()` must not change
    // the arrow's `this`.
    const result = try js.evalWithOutput(
        \\const lex = { tag: "LEX" };
        \\function make() { return () => this.tag; }
        \\const bound = make.call(lex);
        \\print(bound());
        \\print(bound.call());
        \\const carrier = { tag: "CARRIER", m: bound };
        \\print(carrier.m());
        \\const obj = { name: "outer", run() { const a = () => this.name; return a(); } };
        \\print(obj.run());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("LEX\nLEX\nLEX\nouter\n", stream.buffered());
}

test "arrow direct eval reads captured this and new.target" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function Replacement() {}
        \\function Factory() {
        \\    const expectedThis = this;
        \\    return () => [eval("this") === expectedThis, eval("new.target")];
        \\}
        \\const read = Reflect.construct(Factory, [], Replacement);
        \\const observed = read.call({ ignored: true });
        \\assert.sameValue(observed[0], true);
        \\assert.sameValue(observed[1], Replacement);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "arrow super property call keeps the enclosing method receiver" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let derivedInstance;
        \\class Base {
        \\    method() {
        \\        assert.sameValue(this, derivedInstance);
        \\        return 42;
        \\    }
        \\}
        \\class Derived extends Base {
        \\    makeArrow() { return () => super.method(); }
        \\}
        \\derivedInstance = new Derived();
        \\const callSuper = derivedInstance.makeArrow();
        \\assert.sameValue(callSuper(), 42);
        \\assert.sameValue(callSuper.call({ ignored: true }), 42);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "forwarded call releases ignored arrow thisArg" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const setup = try js.eval(
        \\const strictArrowForCall = (function () {
        \\    "use strict";
        \\    return () => 0;
        \\})();
        \\strictArrowForCall.call({ marker: 0 });
    );
    setup.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();
    const baseline_objects = js.runtime.gc.liveCount();

    const result = try js.eval(
        \\for (let i = 0; i < 256; i++) {
        \\    strictArrowForCall.call({ marker: i });
        \\}
    );
    result.free(js.runtime);
    _ = js.runtime.runObjectCycleRemoval();

    try std.testing.expectEqual(baseline_objects, js.runtime.gc.liveCount());
}

test "function inherited data lookup preserves own and exotic semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function target() {}
        \\var intrinsicCall = Function.prototype.call;
        \\assert.sameValue(target.call, intrinsicCall);
        \\assert.sameValue(target.bind(null).call, intrinsicCall);
        \\
        \\var ownReads = 0;
        \\var ownCall = function ownCall() {};
        \\Object.defineProperty(target, "call", {
        \\    configurable: true,
        \\    get: function() { ownReads++; return ownCall; }
        \\});
        \\assert.sameValue(target.call, ownCall);
        \\assert.sameValue(ownReads, 1);
        \\delete target.call;
        \\
        \\var inheritedCall = function inheritedCall() {};
        \\var proto = { call: inheritedCall };
        \\Object.setPrototypeOf(target, proto);
        \\assert.sameValue(target.call, inheritedCall);
        \\
        \\var inheritedReads = 0;
        \\Object.defineProperty(proto, "call", {
        \\    configurable: true,
        \\    get: function() { inheritedReads++; return ownCall; }
        \\});
        \\assert.sameValue(target.call, ownCall);
        \\assert.sameValue(inheritedReads, 1);
        \\
        \\var proxyReads = 0;
        \\var proxyProto = new Proxy({ call: inheritedCall }, {
        \\    get: function(object, key, receiver) {
        \\        if (key === "call") proxyReads++;
        \\        return Reflect.get(object, key, receiver);
        \\    }
        \\});
        \\Object.setPrototypeOf(target, proxyProto);
        \\assert.sameValue(target.call, inheritedCall);
        \\assert.sameValue(proxyReads, 1);
        \\
        \\var grandparentCall = function grandparentCall() {};
        \\Object.setPrototypeOf(target, Object.create({ call: grandparentCall }));
        \\assert.sameValue(target.call, grandparentCall);
        \\
        \\function strictFunction() { "use strict"; }
        \\assert.throws(TypeError, function() { return strictFunction.caller; });
        \\assert.throws(TypeError, function() { return strictFunction.arguments; });
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "Engine eval Function.prototype.toString returns source or native text" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [768]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function f(x) { return x; }
        \\print(f.toString());
        \\function /* a */ g /* b */ ( /* c */ y /* d */ ) /* e */ { /* f */ return y; /* g */ }
        \\print(g.toString());
        \\const arrow = y => y + 1;
        \\print(arrow.toString());
        \\print(print.toString());
        \\try { Function.prototype.toString.call({}); } catch (e) { print(e.name); }
        \\try { String({ toString: Function.prototype.toString }); } catch (e) { print(e.name); }
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "function f(x) { return x; }\n" ++
            "function /* a */ g /* b */ ( /* c */ y /* d */ ) /* e */ { /* f */ return y; /* g */ }\n" ++
            "y => y + 1\n" ++
            "function print() {\n    [native code]\n}\n" ++
            "TypeError\n" ++
            "TypeError\n",
        stream.buffered(),
    );
}

test "Engine eval Function.prototype.toString emits syntactic native names" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var native = " {\n    [native code]\n}";
        \\var invalid = Object.getOwnPropertyDescriptor(RegExp, "$&").get.toString();
        \\assert.sameValue(invalid, "function get()" + native);
        \\assert.sameValue(invalid.indexOf("get $&"), -1);
        \\var valid = Object.getOwnPropertyDescriptor(RegExp, "input").get.toString();
        \\assert.sameValue(valid, "function get input()" + native);
        \\var computed = Object.getOwnPropertyDescriptor(Array, Symbol.species).get.toString();
        \\assert.sameValue(computed, "function get [Symbol.species]()" + native);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "Engine eval Function.prototype.toString returns method and class source" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [1280]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const method = { /* before */ f /* a */ ( /* b */ ) /* c */ { /* d */ } /* after */ }.f;
        \\print(method.toString());
        \\const asyncComputed = { async /* a */ [ /* b */ "g" /* c */ ] /* d */ ( /* e */ ) /* f */ { /* g */ } }.g;
        \\print(asyncComputed.toString());
        \\const asyncGeneratorComputed = { async /* a */ * /* b */ [ /* c */ "h" /* d */ ] /* e */ ( /* f */ ) /* g */ { /* h */ } }.h;
        \\print(asyncGeneratorComputed.toString());
        \\function B() {}
        \\const C = class /* a */ A /* b */ extends /* c */ B /* d */ { /* e */ constructor /* f */ ( /* g */ ) /* h */ { /* i */ } /* j */ };
        \\print(C.toString());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "f /* a */ ( /* b */ ) /* c */ { /* d */ }\n" ++
            "async /* a */ [ /* b */ \"g\" /* c */ ] /* d */ ( /* e */ ) /* f */ { /* g */ }\n" ++
            "async /* a */ * /* b */ [ /* c */ \"h\" /* d */ ] /* e */ ( /* f */ ) /* g */ { /* h */ }\n" ++
            "class /* a */ A /* b */ extends /* c */ B /* d */ { /* e */ constructor /* f */ ( /* g */ ) /* h */ { /* i */ } /* j */ }\n",
        stream.buffered(),
    );
}

test "Engine eval releases arrow destructuring iterator closures cleanly" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var doneCallCount = 0;
        \\var iter = {};
        \\iter[Symbol.iterator] = function() {
        \\  return {
        \\    next: function() { return { value: null, done: false }; },
        \\    return: function() { doneCallCount = doneCallCount + 1; return {}; }
        \\  };
        \\};
        \\var f = ([x]) => { print(doneCallCount); };
        \\f(iter);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n", stream.buffered());
}

test "Engine eval preserves one-shot object missing field host output semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let obj = { a: 1 };
        \\print(obj.b === undefined);
        \\let obj2 = { a: 1 };
        \\print(obj2.a === undefined);
        \\let oldPrint = print;
        \\print = function(x) { oldPrint("custom:" + x); };
        \\let obj3 = { a: 1 };
        \\print(obj3.b === undefined);
        \\print = oldPrint;
        \\{
        \\  let undefined = 1;
        \\  let obj4 = { a: 1 };
        \\  print(obj4.b === undefined);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\nfalse\ncustom:true\nfalse\n", stream.buffered());
}

test "Engine eval preserves local string substring host output semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let s = "abcdef";
        \\print(s.substring(4, 1));
        \\print(s.substring(2));
        \\print(s.substring());
        \\let oldSubstring = String.prototype.substring;
        \\String.prototype.substring = function(start, end) {
        \\  return "custom:" + this + ":" + start + ":" + end;
        \\};
        \\print(s.substring(4, 1));
        \\String.prototype.substring = oldSubstring;
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("bcd\ncdef\nabcdef\ncustom:abcdef:4:1\n", stream.buffered());
}

test "String index-read native records preserve primitive fast paths and observable coercion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let log = "";
        \\const receiver = { toString() { log += "s"; return "A😀Z"; } };
        \\const index = { valueOf() { log += "i"; return 1; } };
        \\print(String.prototype.charCodeAt.call(receiver, index));
        \\print(String.prototype.at.call(receiver, -1));
        \\print(String.prototype.codePointAt.call(receiver, index));
        \\print(log);
        \\for (const method of ["charCodeAt", "at", "codePointAt"]) {
        \\  try { String.prototype[method].call(null, 0); }
        \\  catch (error) { print(method, error.name); }
        \\  try { String.prototype[method].call("x", Symbol()); }
        \\  catch (error) { print(method + "-index", error.name); }
        \\}
        \\print(String.prototype.charCodeAt.call(42, 1));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "55357\nZ\n128512\nsissi\n" ++
            "charCodeAt TypeError\ncharCodeAt-index TypeError\n" ++
            "at TypeError\nat-index TypeError\n" ++
            "codePointAt TypeError\ncodePointAt-index TypeError\n50\n",
        stream.buffered(),
    );
}

test "mod cold handler preserves fmod and ToNumeric fallbacks" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const out = [];
        \\const show = value => Object.is(value, -0) ? "-0" : String(value);
        \\for (const pair of [[5.5, 2], [5, 2.5], [-4, 2], [4, -2],
        \\                       [1, 0], [Infinity, 2], [2, Infinity], [NaN, 2]]) {
        \\  out.push(show(pair[0] % pair[1]));
        \\}
        \\let log = "";
        \\const left = { valueOf() { log += "l"; return 8.5; } };
        \\const right = { valueOf() { log += "r"; return 3; } };
        \\out.push(show(left % right), log, String(12345678901234567890n % 97n));
        \\function* generator() { yield "pause"; return 9.5 % 2; }
        \\const iterator = generator();
        \\out.push(iterator.next().value, show(iterator.next().value));
        \\try { 1 % Symbol(); } catch (error) { out.push(error.name); }
        \\print(out.join("|"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "1.5|0|-0|0|NaN|NaN|2|NaN|2.5|lr|3|pause|1.5|TypeError\n",
        stream.buffered(),
    );
}

test "Engine eval preserves ASCII string integer literal concat semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print("a" + 1);
        \\print("a" + -1);
        \\print("" + 12345);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("a1\na-1\n12345\n", stream.buffered());
}

test "Engine eval preserves resolve-label peephole semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function probe(v, u) {
        \\  let x = 0;
        \\  let y;
        \\  y = (x = v);
        \\  const z = x && y && 9;
        \\  function fn() {}
        \\  function early() { return; print("dead"); }
        \\  early();
        \\  print([x, y, z, x === null, u === undefined,
        \\    typeof u === "undefined", typeof fn === "function",
        \\    typeof Math.abs === "function",
        \\    typeof new Proxy(fn, {}) === "function"].join(","));
        \\}
        \\probe(3, undefined);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3,3,9,false,true,true,true,true,true\n", stream.buffered());
}

test "Engine generator return keeps finally rethrow control marker" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var obj = { foo: "not modified" };
        \\function* g() {
        \\  try { obj.foo = yield; }
        \\  finally { return 1; }
        \\}
        \\var iter = g();
        \\iter.next();
        \\var resumed = iter.return(45);
        \\assert.sameValue(obj.foo, "not modified");
        \\assert.sameValue(resumed.value, 1);
        \\assert.sameValue(resumed.done, true);
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "generator parameter eval cells close before body resume" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var x = 'outside';
        \\var first, second, body;
        \\function* g(
        \\  _ = (eval('var x = "inside";'), first = function() { return x; }),
        \\  __ = second = function() { return x; }
        \\) { body = function() { return x; }; }
        \\g().next();
        \\var y = 'outside';
        \\var restParam, restBody;
        \\function* h(...[_ = (eval('var y = "inside";'), restParam = function() { return y; })]) {
        \\  restBody = function() { return y; };
        \\}
        \\h().next();
        \\print(first(), second(), body(), restParam(), restBody());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("inside inside inside inside inside\n", stream.buffered());
}

test "generator return runs an add_loc-terminated finally to its stop boundary" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Regression: op_add_loc_cold lacked the local_fast_blocked publishing arm
    // (its register-resident body ends in `cont`, which skips coldNext's
    // maybeStop). A `.return()`-driven finally resume arms stop_before_pc =
    // finally_range.stop, and the peephole fuses the finally body's trailing
    // `s += 1` into add_loc — the finally range's LAST op. Blowing past the
    // stop boundary executed the post-finally `s += 100; yield s` eagerly and
    // it.return(42) threw instead of returning {value: 42, done: true}.
    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function* g() {
        \\  var s = 0;
        \\  try { yield 1; } finally { s += 1; }
        \\  s += 100;
        \\  yield s;
        \\}
        \\var it = g();
        \\var first = it.next();
        \\var second = it.return(42);
        \\var third = it.next();
        \\print(first.value, first.done, second.value, second.done, third.value, third.done);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1 false 42 true undefined true\n", stream.buffered());
}

test "generator default argument stores release refcounted stack values" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\var f = function*(x = arguments[2], y = arguments[3], z) {};
        \\f(undefined, undefined, 'third', 'fourth').next();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "spread super brands derived instances before class field initializers" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // Regression: super(...args) compiles to op.apply is_new=1, whose handler
    // skipped the private-method brand install that op.call_constructor
    // performs — `this.#m()` in a field initializer then threw TypeError.
    const result = try js.evalWithOptions(
        \\(function () {
        \\  class A { constructor(a, b) { this.s = (a | 0) + (b | 0); } }
        \\  class B extends A {
        \\    #m() { return this.s + 7; }
        \\    v = this.#m();
        \\    constructor(...args) { super(...args); }
        \\  }
        \\  return new B(1, 2).v;
        \\})();
    ,
        .{ .filename = "<repl>" },
    );
    defer result.free(js.runtime);

    try std.testing.expectEqual(@as(?i32, 10), result.asInt32());
}

test "started generator resumes preserve unmapped arguments from parked locals" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function* strictGenerator(value) {
        \\  "use strict";
        \\  const first = arguments;
        \\  value = 17;
        \\  yield;
        \\  const shorthand = { arguments };
        \\  assert.sameValue(shorthand.arguments, first);
        \\  assert.sameValue(shorthand.arguments[0], 1);
        \\  yield;
        \\  assert.sameValue(arguments, first);
        \\  assert.sameValue(arguments[0], 1);
        \\}
        \\const strictIterator = strictGenerator(1);
        \\strictIterator.next();
        \\strictIterator.next();
        \\strictIterator.next();
        \\function* defaultGenerator(value = 3) {
        \\  const first = eval("arguments");
        \\  value = 19;
        \\  yield;
        \\  assert.sameValue(eval("arguments"), first);
        \\  assert.sameValue(eval("arguments")[0], 2);
        \\}
        \\const defaultIterator = defaultGenerator(2);
        \\defaultIterator.next();
        \\defaultIterator.next();
        \\function* restGenerator(...values) {
        \\  const first = arguments;
        \\  values[0] = 23;
        \\  yield;
        \\  assert.sameValue(arguments, first);
        \\  assert.sameValue(arguments[0], 4);
        \\}
        \\const restIterator = restGenerator(4);
        \\restIterator.next();
        \\restIterator.next();
        \\function* lateArguments(first) {
        \\  yield;
        \\  assert.sameValue(arguments.length, 3);
        \\  assert.sameValue(arguments[0], 5);
        \\  assert.sameValue(arguments[2], 7);
        \\}
        \\const lateIterator = lateArguments(5, 6, 7);
        \\lateIterator.next();
        \\lateIterator.next();
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
}

test "iterator results reuse the realm shape without intermediate property growth" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);

    const warm = try engine.exec.call_runtime.createIteratorResult(js.runtime, global, core.JSValue.int32(1), false);
    warm.free(js.runtime);
    const alloc_calls = js.runtime.memory.alloc_calls;
    const create_calls = js.runtime.memory.create_calls;
    const result = try engine.exec.call_runtime.createIteratorResult(js.runtime, global, core.JSValue.int32(2), true);
    defer result.free(js.runtime);

    // One GC object plus its final two-entry property array. In particular,
    // there is no intermediate one-entry property allocation.
    try std.testing.expectEqual(alloc_calls + 1, js.runtime.memory.alloc_calls);
    try std.testing.expectEqual(create_calls + 1, js.runtime.memory.create_calls);
    const object = try core.Object.expect(result);
    try std.testing.expectEqual(@as(?i32, 2), object.asDataAt(0).?.asInt32());
    try std.testing.expect(object.asDataAt(1).?.asBool().?);
}

test "bytecode closures reuse the final function-prototype shape" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.evalWithOptions(
        "(function () { function make() { return function () {}; } return [make(), make()]; })()",
        .{ .filename = "<repl>" },
    );
    defer result.free(js.runtime);
    const functions = try core.Object.expect(result);
    const first_value = functions.getProperty(core.atom.atomFromUInt32(0));
    defer first_value.free(js.runtime);
    const second_value = functions.getProperty(core.atom.atomFromUInt32(1));
    defer second_value.free(js.runtime);
    const first = try core.Object.expect(first_value);
    const second = try core.Object.expect(second_value);
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);

    try std.testing.expectEqual(first.getPrototype(), second.getPrototype());
    try std.testing.expectEqual(first.shape_ref, second.shape_ref);
    try std.testing.expectEqual(global, first.bytecodeFunctionRealmGlobalPtr().?);
    try std.testing.expectEqual(global, second.bytecodeFunctionRealmGlobalPtr().?);
    try std.testing.expect(!first.flags.is_borrowed_reference_holder);
    try std.testing.expect(!second.flags.is_borrowed_reference_holder);
}

test "generator creation avoids a second payload copy of rooted input slices" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);

    const argument = (try core.Object.create(js.runtime, core.class.ids.object, null)).value();
    defer argument.free(js.runtime);
    const argument_setup = try js.eval("globalThis.__argumentGenerator = function* () {};");
    argument_setup.free(js.runtime);
    const argument_key = try js.runtime.internAtom("__argumentGenerator");
    defer js.runtime.atoms.free(argument_key);
    const argument_generator = global.getProperty(argument_key);
    defer argument_generator.free(js.runtime);
    const argument_values = [_]core.JSValue{argument};

    const warm_argument = try engine.exec.call_runtime.callValueOrBytecode(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        argument_generator,
        &argument_values,
        null,
        null,
    );
    warm_argument.free(js.runtime);
    const warm_no_argument = try engine.exec.call_runtime.callValueOrBytecode(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        argument_generator,
        &.{},
        null,
        null,
    );
    // Keep one final-prototype root Shape live. A qjs-style detached generator
    // construction then needs two fixed creates (public Object + compact
    // payload) and one variable allocation containing execution state + stack;
    // it must not allocate a temporary null-prototype Shape or stack buffer.
    defer warm_no_argument.free(js.runtime);

    var alloc_calls = js.runtime.memory.alloc_calls;
    var create_calls = js.runtime.memory.create_calls;
    const no_argument_result = try engine.exec.call_runtime.callValueOrBytecode(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        argument_generator,
        &.{},
        null,
        null,
    );
    no_argument_result.free(js.runtime);
    const no_argument_alloc_count = js.runtime.memory.alloc_calls - alloc_calls;
    const no_argument_create_count = js.runtime.memory.create_calls - create_calls;
    try std.testing.expectEqual(@as(usize, 2), no_argument_create_count);
    try std.testing.expectEqual(@as(usize, 1), no_argument_alloc_count);

    alloc_calls = js.runtime.memory.alloc_calls;
    create_calls = js.runtime.memory.create_calls;
    const argument_result = try engine.exec.call_runtime.callValueOrBytecode(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        argument_generator,
        &argument_values,
        null,
        null,
    );
    argument_result.free(js.runtime);
    const argument_alloc_count = js.runtime.memory.alloc_calls - alloc_calls;
    const argument_create_count = js.runtime.memory.create_calls - create_calls;
    // Args/locals/var-ref windows enlarge the same variable-sized execution
    // allocation; the construction root borrows the caller slice until those
    // resident windows have been initialized and parked.
    try std.testing.expectEqual(no_argument_alloc_count, argument_alloc_count);
    try std.testing.expectEqual(no_argument_create_count, argument_create_count);

    const capture_setup = try js.eval("globalThis.__captureGenerator = (function () { var captured = {}; return function* () { yield captured; }; })();");
    capture_setup.free(js.runtime);
    const capture_key = try js.runtime.internAtom("__captureGenerator");
    defer js.runtime.atoms.free(capture_key);
    const capture_generator = global.getProperty(capture_key);
    defer capture_generator.free(js.runtime);
    const warm_capture = try engine.exec.call_runtime.callValueOrBytecode(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        capture_generator,
        &.{},
        null,
        null,
    );
    defer warm_capture.free(js.runtime);

    alloc_calls = js.runtime.memory.alloc_calls;
    create_calls = js.runtime.memory.create_calls;
    const no_capture_result = try engine.exec.call_runtime.callValueOrBytecode(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        argument_generator,
        &.{},
        null,
        null,
    );
    no_capture_result.free(js.runtime);
    const no_capture_alloc_count = js.runtime.memory.alloc_calls - alloc_calls;
    const no_capture_create_count = js.runtime.memory.create_calls - create_calls;

    alloc_calls = js.runtime.memory.alloc_calls;
    create_calls = js.runtime.memory.create_calls;
    const capture_result = try engine.exec.call_runtime.callValueOrBytecode(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        capture_generator,
        &.{},
        null,
        null,
    );
    capture_result.free(js.runtime);
    const capture_alloc_count = js.runtime.memory.alloc_calls - alloc_calls;
    const capture_create_count = js.runtime.memory.create_calls - create_calls;
    try std.testing.expectEqual(no_capture_alloc_count, capture_alloc_count);
    try std.testing.expectEqual(no_capture_create_count, capture_create_count);
}

test "Engine generator return propagates an explicit finally throw" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var syncError = new Error('sync');
        \\function* syncGenerator() {
        \\  try { yield 1; } finally { throw syncError; }
        \\}
        \\var syncIterator = syncGenerator();
        \\syncIterator.next();
        \\try {
        \\  syncIterator.return('sent');
        \\  print('sync-resolved');
        \\} catch (error) {
        \\  print('sync-rejected', error === syncError);
        \\}
        \\var asyncError = new Error('async');
        \\async function* asyncGenerator() {
        \\  try { yield 1; } finally { throw asyncError; }
        \\}
        \\var asyncIterator = asyncGenerator();
        \\asyncIterator.next().then(function() {
        \\  return asyncIterator.return('sent');
        \\}).then(function() {
        \\  print('async-resolved');
        \\}, function(error) {
        \\  print('async-rejected', error === asyncError);
        \\  return asyncIterator.next();
        \\}).then(function(result) {
        \\  print('async-closed', result.value, result.done);
        \\});
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "sync-rejected true\nasync-rejected true\nasync-closed undefined true\n",
        stream.buffered(),
    );
}

test "Engine eval preserves simple for-in mutation semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let obj = { a: 1, b: 2, c: 3 };
        \\let keys = "";
        \\for (var k in obj) {
        \\  keys += k;
        \\  if (k === "a") delete obj.b;
        \\}
        \\print(keys);
        \\let obj2 = { a: 1, b: 2 };
        \\keys = "";
        \\for (var k in obj2) {
        \\  keys += k;
        \\  if (k === "a") {
        \\    delete obj2.b;
        \\    obj2.b = 3;
        \\  }
        \\}
        \\print(keys);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("ac\nab\n", stream.buffered());
}

test "Engine runJobs preserves pending JS exceptions for callers" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    js.context.preserve_uncaught_exception = true;

    const setup = try js.eval("var __zjs_timer_throw = function() { throw new Error('timer boom'); };");
    defer setup.free(js.runtime);
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const callback_key = try js.runtime.internAtom("__zjs_timer_throw");
    defer js.runtime.atoms.free(callback_key);
    const callback = global.getProperty(callback_key);
    defer callback.free(js.runtime);

    try js.event_loop.enqueueTimer(@ptrCast(js.context), 1, callback, 0, false);

    try js.runJobs();
    try std.testing.expect(js.context.hasException());

    var exception = try js.takeExceptionInfo();
    defer exception.deinit();
}

test "host module graph syntax diagnostics do not write to program output" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const modules = [_]HostFixtureModule{
        .{
            .specifier = "./bad.js",
            .path = "/fixture/bad.js",
            .source = "export const = ;",
            .kind = .esm,
        },
    };
    const host = HostFixture{ .modules = &modules };
    const hooks = hostHooks(&host);

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expectError(
        error.SyntaxError,
        js.evalFileModuleGraphWithHostHooks(
            "import './bad.js';",
            &stream,
            "/fixture/main.mjs",
            hooks,
            std.testing.allocator,
        ),
    );
    try std.testing.expectEqualStrings("", stream.buffered());
}

test "host commonjs wrapper passes directory dirname" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const modules = [_]HostFixtureModule{
        .{
            .specifier = "./lib/dep.cjs",
            .path = "/fixture/lib/dep.cjs",
            .source =
            \\module.exports = {
            \\  filename: __filename,
            \\  dirname: __dirname,
            \\};
            ,
            .kind = .commonjs,
        },
    };
    const host = HostFixture{ .modules = &modules };
    const hooks = hostHooks(&host);

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithHostHooks(
        \\import info from './lib/dep.cjs';
        \\assert.sameValue(info.filename, '/fixture/lib/dep.cjs');
        \\assert.sameValue(info.dirname, '/fixture/lib');
    ,
        &stream,
        "/fixture/main.mjs",
        hooks,
        std.testing.allocator,
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("", stream.buffered());
}

test "module graph evaluates block var declarations as module bindings" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const registry = engine.exec.standard_globals;
    registry.configureRuntime(js.runtime);

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(
        \\if (true) {
        \\  var proto = {};
        \\  print(typeof proto);
        \\  print(proto !== null);
        \\}
    ,
        &output,
        "block-var-module.mjs",
        std.testing.io,
        std.testing.allocator,
        2048,
    );
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("object\ntrue\n", output.buffered());
}

test "module evaluation does not skip a body-leading function expression" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const registry = engine.exec.standard_globals;
    registry.configureRuntime(js.runtime);

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(
        \\print((function () { return 42; })());
    ,
        &output,
        "module-leading-function-expression.mjs",
        std.testing.io,
        std.testing.allocator,
        2048,
    );
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("42\n", output.buffered());
}

test "module top-level await resumes in Promise reaction FIFO order" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const registry = engine.exec.standard_globals;
    registry.configureRuntime(js.runtime);

    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(
        \\var actual = [];
        \\Promise.resolve(0)
        \\  .then(() => actual.push("tick 1"))
        \\  .then(() => actual.push("tick 2"))
        \\  .then(() => actual.push("tick 3"))
        \\  .then(() => actual.push("tick 4"))
        \\  .then(() => print("done:" + actual.join(",")));
        \\await 1;
        \\actual.push("await 1");
        \\await 2;
        \\actual.push("await 2");
        \\await 3;
        \\actual.push("await 3");
        \\await 4;
        \\actual.push("await 4");
    ,
        &output,
        "module-tla-promise-fifo.mjs",
        std.testing.io,
        std.testing.allocator,
        4096,
    );
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings(
        "done:tick 1,await 1,tick 2,await 2,tick 3,await 3,tick 4,await 4\n",
        output.buffered(),
    );
}

test "module await reaction keeps its position on the awaited Promise" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const registry = engine.exec.standard_globals;
    registry.configureRuntime(js.runtime);

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(
        \\let resolveAwaited;
        \\const awaited = new Promise((resolve) => resolveAwaited = resolve);
        \\const actual = [];
        \\awaited.then(() => actual.push("before"));
        \\Promise.resolve().then(() => {
        \\  awaited.then(() => actual.push("after"));
        \\  resolveAwaited();
        \\});
        \\await awaited;
        \\actual.push("module");
        \\Promise.resolve().then(() => print(actual.join(",")));
    ,
        &output,
        "module-await-reaction-position.mjs",
        std.testing.io,
        std.testing.allocator,
        4096,
    );
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("before,module,after\n", output.buffered());
}

test "async module dependency does not preempt an independent sibling" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const registry = engine.exec.standard_globals;
    registry.configureRuntime(js.runtime);

    const dir = ".zig-cache/module-async-sibling-order-test";
    const main_path = dir ++ "/main.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dir ++ "/b.mjs",
        .data = "globalThis.__moduleOrder = globalThis.__moduleOrder || [];\n" ++
            "globalThis.__moduleOrder.push('b-start');\n" ++
            "await 0;\n" ++
            "globalThis.__moduleOrder.push('b-end');\n",
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dir ++ "/a.mjs",
        .data = "import './b.mjs';\nglobalThis.__moduleOrder.push('a');\n",
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dir ++ "/c.mjs",
        .data = "globalThis.__moduleOrder = globalThis.__moduleOrder || [];\n" ++
            "globalThis.__moduleOrder.push('c');\n",
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = main_path,
        .data = "import './a.mjs';\n" ++
            "import './c.mjs';\n" ++
            "print(globalThis.__moduleOrder.join(','));\n",
    });

    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(source);
    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalFileModuleGraphWithOutput(
        source,
        &output,
        main_path,
        std.testing.io,
        std.testing.allocator,
        4096,
    );
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("b-start,c,b-end,a\n", output.buffered());
}

test "import bytes module creates immutable ArrayBuffer backing store" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const dir = ".zig-cache/module-import-bytes-immutable-test";
    const bytes_path = dir ++ "/payload.bin";
    const main_path = dir ++ "/main.mjs";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = bytes_path, .data = "ABC" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = main_path, .data =
        \\import value from "./payload.bin" with { type: "bytes" };
        \\print(value instanceof Uint8Array);
        \\print(value.buffer instanceof ArrayBuffer);
        \\print(value.length);
        \\print(value[0]);
        \\print(value.buffer.immutable);
        \\print(Object.hasOwn(value.buffer, "immutable"));
        \\try { value.buffer.resize(0); print("resize-ok"); } catch (e) { print(e.name); }
        \\try { value.buffer.transfer(); print("transfer-ok"); } catch (e) { print(e.name); }
    });

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, std.testing.allocator, .limited(2048));
    defer std.testing.allocator.free(source);
    const result = try js.evalFileModuleGraphWithOutput(source, &output, main_path, std.testing.io, std.testing.allocator, 2048);
    defer result.free(js.runtime);

    try std.testing.expectEqualStrings("true\ntrue\n3\n65\ntrue\nfalse\nTypeError\nTypeError\n", output.buffered());
}

const HostFixtureModule = struct {
    specifier: []const u8,
    path: []const u8,
    source: []const u8,
    kind: helpers.TestEngine.HostHooks.ModuleKind,
};

const HostFixture = struct {
    modules: []const HostFixtureModule,

    fn findBySpecifierOrPath(self: HostFixture, specifier: []const u8) ?HostFixtureModule {
        for (self.modules) |module| {
            if (std.mem.eql(u8, module.specifier, specifier) or std.mem.eql(u8, module.path, specifier)) return module;
        }
        return null;
    }

    fn findByPath(self: HostFixture, path: []const u8) ?HostFixtureModule {
        for (self.modules) |module| {
            if (std.mem.eql(u8, module.path, path)) return module;
        }
        return null;
    }
};

fn hostHooks(host: *const HostFixture) helpers.TestEngine.HostHooks {
    return .{
        .ptr = @constCast(host),
        .resolveModule = resolveFixtureModule,
        .loadModule = loadFixtureModule,
    };
}

fn resolveFixtureModule(
    ptr: *anyopaque,
    specifier: []const u8,
    referrer: ?[]const u8,
    allocator: std.mem.Allocator,
) anyerror!helpers.TestEngine.HostHooks.ResolvedModule {
    _ = referrer;
    const host: *const HostFixture = @ptrCast(@alignCast(ptr));
    const module = host.findBySpecifierOrPath(specifier) orelse return error.ModuleNotFound;
    return .{
        .specifier = try allocator.dupe(u8, specifier),
        .path = try allocator.dupe(u8, module.path),
        .kind = module.kind,
    };
}

fn loadFixtureModule(
    ptr: *anyopaque,
    resolved: helpers.TestEngine.HostHooks.ResolvedModule,
    allocator: std.mem.Allocator,
) anyerror!helpers.TestEngine.HostHooks.LoadedModule {
    const host: *const HostFixture = @ptrCast(@alignCast(ptr));
    const module = host.findByPath(resolved.path) orelse return error.ModuleNotFound;
    return .{
        .source = module.source,
        .path = try allocator.dupe(u8, module.path),
        .kind = module.kind,
        .owned = false,
    };
}

// Bootstrap-integration tests relocated from src/exec/{call,zjs_vm}.zig during
// Phase 6b-3 STEP 7B. They build a bare `core.JSRuntime` and install the
// standard globals through `rt.installStandardGlobals`; the helper wires the
// exec-owned bootstrap seam before installation.

test "host global bootstrap installs and tears down builtin plus host domains" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    _ = try global.ensureRealmPayload(rt);
    defer global.value().free(rt);

    try helpers.installHostGlobalsBare(rt, global);
}

test "engine eval host globals and throw intrinsic tear down cleanly" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    _ = try global.ensureRealmPayload(rt);
    defer global.value().free(rt);

    try helpers.installHostGlobalsBare(rt, global);

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);

    const value = try engine.exec.eval_entry.eval(ctx, "print(1);", .{ .output = &output });
    defer value.free(rt);

    try std.testing.expect(value.isUndefined());
    try std.testing.expectEqualStrings("1\n", output.buffered());
}

const ReflectActiveRootSymbolProbe = struct {
    rt: *core.JSRuntime,
    atom_id: u32,
    saw_symbol: bool = false,
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
        self.saw_symbol = self.rt.atoms.name(self.atom_id) != null;
    }
};

fn reflectTestSetArrayIndex(rt: *core.JSRuntime, array: *core.Object, index: u32, value: core.JSValue) !void {
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(index), core.Descriptor.data(value, true, true, true));
    if (array.arrayLength() <= index) array.setArrayLength(index + 1);
}

test "reflect construct roots argument list while resolving prototype" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    // `reflectConstruct` routes builtin construction (Array, like Date/RegExp/
    // String) through the internal record table, so the realm globals must be
    // installed to wire `rt.internal_builtins` before the construct record is
    // reachable.
    const realm_global = try core.Object.create(rt, core.class.ids.object, null);
    _ = try realm_global.ensureRealmPayload(rt);
    defer realm_global.value().free(rt);
    engine.exec.standard_globals.configureRuntime(rt);
    try rt.installStandardGlobals(realm_global);

    const target = try core.function.nativeFunction(rt, "Array", 1);
    defer target.free(rt);
    const new_target = try core.function.nativeFunction(rt, "Array", 1);
    defer new_target.free(rt);
    const new_target_object = engine.exec.call.thisObject(new_target) orelse return error.TypeError;
    try new_target_object.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(core.JSValue.int32(1), true, false, true));

    const args_object = try core.Object.createArray(rt, null);
    var args_alive = true;
    defer if (args_alive) args_object.value().free(rt);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-reflect-construct-argument-root");
    const symbol_value = try rt.symbolValue(symbol_atom);
    try reflectTestSetArrayIndex(rt, args_object, 0, symbol_value);
    symbol_value.free(rt);

    const saved_trigger_fn = rt.memory.trigger_gc_fn;
    const saved_trigger_ctx = rt.memory.trigger_gc_ctx;
    var probe = ReflectActiveRootSymbolProbe{
        .rt = rt,
        .atom_id = symbol_atom,
    };
    rt.memory.trigger_gc_fn = ReflectActiveRootSymbolProbe.trigger;
    rt.memory.trigger_gc_ctx = &probe;
    defer {
        rt.memory.trigger_gc_fn = saved_trigger_fn;
        rt.memory.trigger_gc_ctx = saved_trigger_ctx;
    }

    var globals = [_]engine.exec.globals.Slot{};
    const reflect_args = [_]core.JSValue{ target, args_object.value(), new_target };
    const result = try engine.exec.reflect_ops.reflectConstruct(ctx, &reflect_args, globals[0..]);
    var result_alive = true;
    defer if (result_alive) result.free(rt);

    try std.testing.expect(!probe.trace_failed);
    try std.testing.expect(probe.saw_symbol);

    args_object.value().free(rt);
    args_alive = false;
    result.free(rt);
    result_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

// ===========================================================================
// Branch-to-end fall-off forms. The register-resident dispatch carries no
// fall-off bounds check (qjs-aligned), so the jump-aware epilogues MUST
// terminate every branch-to-end path with a real return op and the pipeline
// MUST plant the trailing op.return sentinel for the eval-completion form.
// Each test pins the observable completion value; a regression surfaces as
// the sentinel popping an empty operand stack (garbage completion / UB).
// ===========================================================================

test "if-throw fall-off form returns undefined (if_false8 branch-to-end)" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function fallOffIfThrow(x) { if (x) throw 1; }
        \\assert.sameValue(fallOffIfThrow(false), undefined);
        \\var threw = false;
        \\try { fallOffIfThrow(true); } catch (e) { threw = (e === 1); }
        \\assert.sameValue(threw, true);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "if-return fall-off form returns undefined on the fall-through leg" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function fallOffIfReturn(x) { if (x) return 1; }
        \\assert.sameValue(fallOffIfReturn(true), 1);
        \\assert.sameValue(fallOffIfReturn(false), undefined);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "else-return goto-to-end form returns undefined on the taken if leg" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function fallOffElseReturn(x) { if (x) { 1; } else return 2; }
        \\assert.sameValue(fallOffElseReturn(true), undefined);
        \\assert.sameValue(fallOffElseReturn(false), 2);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "nested-block branch-to-end survives trailing scope cleanup lowering" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Parser-phase target points at the block's leave_scope/close_loc run;
    // lowering removes it, leaving the resolved target == code_end. The
    // epilogue's jump-to-end scan must treat the trailing cleanup run as an
    // end target and still append the terminator.
    const result = try js.eval(
        \\function fallOffNestedBlock(c) { { let x; if (c) throw 1; } }
        \\assert.sameValue(fallOffNestedBlock(false), undefined);
        \\function fallOffCaptured(c) { { let x = 1; if (c) throw 2; var probe = function () { return x; }; } return probe(); }
        \\assert.sameValue(fallOffCaptured(false), 1);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "arrow block body branch-to-end returns undefined" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var fallOffArrow = (x) => { if (x) throw 3; };
        \\assert.sameValue(fallOffArrow(false), undefined);
        \\var fallOffArrowReturn = (x) => { if (x) return 4; };
        \\assert.sameValue(fallOffArrowReturn(true), 4);
        \\assert.sameValue(fallOffArrowReturn(false), undefined);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "generator branch-to-end completes with undefined value" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function* fallOffGen(x) { if (x) throw 4; yield 1; }
        \\var it = fallOffGen(false);
        \\assert.sameValue(it.next().value, 1);
        \\var r = it.next();
        \\assert.sameValue(r.done, true);
        \\assert.sameValue(r.value, undefined);
        \\function* fallOffGenNoYield(x) { if (x) throw 5; }
        \\var r2 = fallOffGenNoYield(false).next();
        \\assert.sameValue(r2.done, true);
        \\assert.sameValue(r2.value, undefined);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
}

test "eval L0 completion falls off onto the op.return sentinel" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Direct/indirect eval bodies end with `scope_get_var <ret>` and fall off
    // the end; the trailing sentinel returns the completion riding the stack.
    const result = try js.eval(
        \\assert.sameValue(eval("if (false) throw 5;"), undefined);
        \\assert.sameValue(eval("1 + 2"), 3);
        \\assert.sameValue(eval("{ let x; if (false) throw 6; }"), undefined);
    );
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    // Script completion (<repl> return_completion form) rides the same
    // sentinel fall-off at the top level.
    const repl_undef = try js.evalWithOptions("if (false) throw 7;", .{ .filename = "<repl>" });
    defer repl_undef.free(js.runtime);
    try std.testing.expect(repl_undef.isUndefined());

    const repl_value = try js.evalWithOptions("40 + 2", .{ .filename = "<repl>" });
    defer repl_value.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 42), repl_value.asInt32());
}

test "module top-level branch-to-end gets a terminator (no fall-off)" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\if (false) throw 9;
    );
    defer result.free(js.runtime);
}
