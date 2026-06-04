const core = @import("../core/root.zig");
const builtins = @import("../builtins/root.zig");
const bytecode_opcode = @import("../bytecode/opcode.zig");
const function_bytecode = @import("../bytecode/function.zig");
const closure_mod = @import("closure.zig");
const construct_mod = @import("construct.zig");
const frame_mod = @import("frame.zig");
const globals_mod = @import("globals.zig");
const json_vm = @import("json_ops.zig");
const property_ops = @import("property_ops.zig");
const value_ops = @import("value_ops.zig");
const shared_vm = @import("shared.zig");
const dtoa = @import("../libs/dtoa.zig");
const std = @import("std");
const exceptions = @import("exceptions.zig");
const HostError = exceptions.HostError;
const PrintError = HostError || error{InvalidRadix};

fn hostResult(result: anytype) HostError!switch (@typeInfo(@TypeOf(result))) {
    .error_union => |info| info.payload,
    else => @compileError("hostResult expects an error union"),
} {
    return result catch |err| return @errorCast(err);
}

const libc = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("dirent.h");
    @cInclude("grp.h");
    @cInclude("limits.h");
    @cInclude("signal.h");
    @cInclude("poll.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("sys/types.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/resource.h");
    @cInclude("sys/time.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn fdopen(fd: c_int, mode: [*:0]const u8) ?*std.c.FILE;
extern "c" fn tmpfile() ?*std.c.FILE;
extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*std.c.FILE;
extern "c" fn pclose(stream: *std.c.FILE) c_int;
extern "c" fn fflush(stream: *std.c.FILE) c_int;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
extern "c" fn feof(stream: *std.c.FILE) c_int;
extern "c" fn ferror(stream: *std.c.FILE) c_int;
extern "c" fn clearerr(stream: *std.c.FILE) void;
extern "c" fn fileno(stream: *std.c.FILE) c_int;
extern "c" fn fgetc(stream: *std.c.FILE) c_int;
extern "c" fn fputc(c: c_int, stream: *std.c.FILE) c_int;
const builtin = @import("builtin");

pub fn stdin() *std.c.FILE {
    return @extern(**std.c.FILE, .{ .name = if (builtin.os.tag == .macos) "__stdinp" else "stdin" }).*;
}
pub fn stdout() *std.c.FILE {
    return @extern(**std.c.FILE, .{ .name = if (builtin.os.tag == .macos) "__stdoutp" else "stdout" }).*;
}
pub fn stderr() *std.c.FILE {
    return @extern(**std.c.FILE, .{ .name = if (builtin.os.tag == .macos) "__stderrp" else "stderr" }).*;
}

extern "c" fn snprintf(buffer: [*]u8, size: usize, format: [*:0]const u8, ...) c_int;
extern "c" fn strerror(errnum: c_int) [*:0]u8;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn lseek(fd: c_int, offset: c_long, whence: c_int) c_long;

const execvpe = if (builtin.os.tag == .macos) execvpe_mac else execvpe_linux;

const execvpe_linux = if (builtin.os.tag != .macos) struct {
    extern "c" fn execvpe(file: [*:0]const u8, argv: [*:null]?[*:0]u8, envp: [*:null]?[*:0]u8) c_int;
}.execvpe else undefined;

fn execvpe_mac(file: [*:0]const u8, argv: [*:null]?[*:0]u8, envp: [*:null]?[*:0]u8) callconv(.c) c_int {
    const file_span = std.mem.span(file);
    const errno_noent: c_int = @intCast(@intFromEnum(std.posix.E.NOENT));
    const errno_notdir: c_int = @intCast(@intFromEnum(std.posix.E.NOTDIR));
    const errno_acces: c_int = @intCast(@intFromEnum(std.posix.E.ACCES));
    const errno_nametoolong: c_int = @intCast(@intFromEnum(std.posix.E.NAMETOOLONG));

    if (file_span.len == 0) {
        std.c._errno().* = errno_noent;
        return -1;
    }
    if (std.mem.indexOfScalar(u8, file_span, '/') != null) {
        return execve(file, argv, envp);
    }

    const path_env = std.c.getenv("PATH");
    const path = if (path_env) |p| std.mem.span(p) else "/bin:/usr/bin";
    var buf: [4096:0]u8 = undefined;
    var saw_acces = false;
    var saw_nametoolong = false;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) {
            if (file_span.len >= buf.len) {
                saw_nametoolong = true;
                continue;
            }
            @memcpy(buf[0..file_span.len], file_span);
            buf[file_span.len] = 0;
        } else {
            if (dir.len + 1 + file_span.len >= buf.len) {
                saw_nametoolong = true;
                continue;
            }
            @memcpy(buf[0..dir.len], dir);
            buf[dir.len] = '/';
            @memcpy(buf[dir.len + 1 .. dir.len + 1 + file_span.len], file_span);
            buf[dir.len + 1 + file_span.len] = 0;
        }
        _ = execve(&buf, argv, envp);
        const err = std.c._errno().*;
        if (err == errno_acces) {
            saw_acces = true;
            continue;
        }
        if (err == errno_noent or err == errno_notdir) continue;
        return -1;
    }
    std.c._errno().* = if (saw_acces) errno_acces else if (saw_nametoolong) errno_nametoolong else errno_noent;
    return -1;
}

extern "c" fn execve(file: [*:0]const u8, argv: [*:null]?[*:0]u8, envp: [*:null]?[*:0]u8) c_int;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn mkstemp(template: [*:0]u8) c_int;
extern "c" fn signal(signum: c_int, handler: usize) usize;

var os_pending_signals: u64 = 0;

fn osSignalHandler(sig: c_int) callconv(.c) void {
    if (sig >= 0 and sig < 64) os_pending_signals |= @as(u64, 1) << @intCast(sig);
}

pub fn returnThis(this_value: core.JSValue) core.JSValue {
    return this_value.dup();
}

/// QuickJS source map: JS_CallInternal() dispatches callable objects after the
/// VM has prepared callee/argument values. This Zig slice currently owns the
/// host callables installed for the CLI-visible global object.
pub fn installHostGlobals(rt: *core.JSRuntime, global: *core.Object) !void {
    try global.reserveOwnPropertyCapacityAssumingPlain(rt, 99);
    try definePredefinedHostFunction(rt, global, "print", .output);
    try installStandardGlobals(rt, global);
    try defineGlobalThisProperty(rt, global);
    try defineNumberConstantPropertyAssumingNew(rt, global, "NaN", std.math.nan(f64));
    try defineNumberConstantPropertyAssumingNew(rt, global, "Infinity", std.math.inf(f64));
    try defineConstantPropertyAssumingNew(rt, global, "undefined", core.JSValue.undefinedValue());

    try defineConsoleObject(rt, global);
}

pub fn installTest262Globals(rt: *core.JSRuntime, global: *core.Object) !void {
    try definePredefinedHostConstructorFunction(rt, global, "Test262Error", .test262_error);
    try definePredefinedHostFunction(rt, global, "verifyProperty", .test262_verify_property);
    try definePredefinedHostFunction(rt, global, "verifyCallableProperty", .test262_verify_callable_property);
    try definePredefinedHostFunction(rt, global, "verifyNotWritable", .test262_verify_not_writable);
    try definePredefinedHostFunction(rt, global, "verifyNotEnumerable", .test262_verify_not_enumerable);
    try definePredefinedHostFunction(rt, global, "verifyConfigurable", .test262_verify_configurable);
    try definePredefinedHostFunction(rt, global, "isConstructor", .test262_is_constructor);
    try defineHostFunction(rt, global, "setTimeout", .test262_agent_set_timeout);
    try defineAssertObject(rt, global);
}

fn installStandardGlobals(rt: *core.JSRuntime, global: *core.Object) !void {
    try builtins.registry.installStandardGlobals(rt, global);
}

fn defineConsoleObject(rt: *core.JSRuntime, global: *core.Object) !void {
    const key = predefinedStringAtom("console");
    try global.defineConsoleAutoInitProperty(rt, key, core.property.Flags.data(true, true, true), @intFromEnum(HostFunction.output));
}

fn defineAssertObject(rt: *core.JSRuntime, global: *core.Object) !void {
    const key = predefinedStringAtom("assert");
    try global.defineAssertAutoInitProperty(rt, key, core.property.Flags.data(true, true, true), @intFromEnum(HostFunction.test262_assert));
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
        if (proxy.proxyTarget() != null and shared_vm.proxyTargetIsCallable(callee)) {
            return shared_vm.callProxyApply(ctx, output, global orelse return error.TypeError, callee, proxy, this_value, args, null, null);
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
        return shared_vm.callValueOrBytecode(ctx, output, global orelse return error.TypeError, this_value, callee, args, null, null);
    }
    if (object.class_id == core.class.ids.c_closure) {
        const closure_kind = closure_mod.closureKind(ctx.runtime, callee) catch 0;
        if (closure_kind == 51) {
            const encoded = try closure_mod.closureValue(ctx.runtime, callee);
            return construct_mod.constructCollectionClosure(ctx.runtime, encoded, globals);
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
        } else if (isNegativeZero(float_value)) {
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
        try printString(writer, value);
    } else if (value.isObject()) {
        const header = value.refHeader() orelse return writer.writeAll("[object Object]");
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (isFunctionClass(object_value.class_id)) {
            try printNativeFunction(rt, writer, object_value);
        } else if (object_value.class_id == core.class.ids.array_buffer) {
            try writer.writeAll("[object ArrayBuffer]");
        } else if (object_value.class_id == core.class.ids.promise) {
            try writer.writeAll("[object Promise]");
        } else if (object_value.is_array) {
            try printArray(rt, writer, object_value);
        } else {
            try writer.writeAll("[object Object]");
        }
    } else {
        try writer.writeAll("[object Object]");
    }
}

pub fn forEachArrayPrint(rt: *core.JSRuntime, output: ?*std.Io.Writer, array_value: core.JSValue) !core.JSValue {
    const array = try expectArray(array_value);
    if (output) |writer| {
        var index: u32 = 0;
        while (index < array.length) : (index += 1) {
            const item = array.getProperty(core.atom.atomFromUInt32(index));
            defer item.free(rt);
            try printValue(rt, writer, item);
            try writer.print("\n", .{});
        }
    }
    return core.JSValue.undefinedValue();
}

const HostFunction = enum(i32) {
    output = core.host_function.ids.output,
    test262_same_value = core.host_function.ids.test262_same_value,
    test262_error = 3,
    test262_assert = core.host_function.ids.test262_assert,
    test262_not_same_value = core.host_function.ids.test262_not_same_value,
    test262_throws = core.host_function.ids.test262_throws,
    test262_verify_property = 7,
    test262_verify_callable_property = 8,
    test262_is_constructor = 9,
    test262_verify_not_writable = 10,
    test262_verify_not_enumerable = 11,
    test262_verify_configurable = 12,
    test262_compare_array = core.host_function.ids.test262_compare_array,
    test262_create_realm = core.host_function.ids.test262_create_realm,
    test262_eval_script = core.host_function.ids.test262_eval_script,
    std_load_file = 23,
    std_write_file = 24,
    std_exists = 25,
    std_exit = 39,
    std_getenv = 40,
    std_setenv = 41,
    std_unsetenv = 42,
    std_getenviron = 43,
    std_gc = 44,
    std_eval_script = 45,
    std_load_script = 46,
    std_open = 47,
    std_fdopen = 48,
    std_tmpfile = 49,
    std_popen = 50,
    std_file_close = 51,
    std_file_puts = 52,
    std_file_flush = 53,
    std_file_tell = 54,
    std_file_seek = 55,
    std_file_eof = 56,
    std_file_fileno = 57,
    std_file_error = 58,
    std_file_clearerr = 59,
    std_file_read = 60,
    std_file_write = 61,
    std_file_getline = 62,
    std_file_read_as_string = 63,
    std_file_read_as_array_buffer = 64,
    std_file_get_byte = 65,
    std_file_put_byte = 66,
    std_strerror = 67,
    std_puts = 68,
    std_printf = 69,
    std_sprintf = 70,
    std_file_printf = 71,
    std_url_get = 72,
    os_open = 73,
    os_close = 74,
    os_seek = 75,
    os_read = 76,
    os_write = 77,
    os_mkdir = 78,
    os_readdir = 79,
    os_stat = 80,
    os_lstat = 81,
    os_realpath = 82,
    os_symlink = 83,
    os_readlink = 84,
    os_utimes = 85,
    os_set_timeout = 86,
    os_set_interval = 87,
    os_clear_timeout = 88,
    os_clear_interval = 89,
    os_exec = 90,
    os_waitpid = 91,
    os_getpid = 92,
    os_pipe = 93,
    os_kill = 94,
    os_dup = 95,
    os_dup2 = 96,
    os_isatty = 97,
    os_tty_get_win_size = 98,
    os_tty_set_raw = 99,
    os_set_read_handler = 100,
    os_set_write_handler = 101,
    os_signal = 102,
    os_cputime = 103,
    os_exe_path = 104,
    os_now = 105,
    os_sleep_async = 106,
    os_mkdtemp = 107,
    os_mkstemp = 108,
    os_getenv = 26,
    os_getcwd = 27,
    os_chdir = 28,
    os_remove = 29,
    os_rename = 30,
    test262_agent_start = core.host_function.ids.test262_agent_start,
    test262_agent_broadcast = core.host_function.ids.test262_agent_broadcast,
    test262_agent_receive_broadcast = core.host_function.ids.test262_agent_receive_broadcast,
    test262_agent_report = core.host_function.ids.test262_agent_report,
    test262_agent_get_report = core.host_function.ids.test262_agent_get_report,
    test262_agent_leaving = core.host_function.ids.test262_agent_leaving,
    test262_agent_sleep = core.host_function.ids.test262_agent_sleep,
    test262_agent_monotonic_now = core.host_function.ids.test262_agent_monotonic_now,
    test262_agent_set_timeout = core.host_function.ids.test262_agent_set_timeout,
    test262_detach_array_buffer = core.host_function.ids.test262_detach_array_buffer,
    test262_is_html_dda = core.host_function.ids.test262_is_html_dda,
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
    @intFromEnum(HostFunction.test262_agent_set_timeout),
    @intFromEnum(HostFunction.external_host),
);

const host_function_records: [max_host_function_id + 1]?HostFunctionRecord = records: {
    var records = [_]?HostFunctionRecord{null} ** (max_host_function_id + 1);
    records[@intFromEnum(HostFunction.output)] = .{ .length = 1, .call = hostCallOutput };
    records[@intFromEnum(HostFunction.test262_assert)] = .{ .length = 1, .call = hostCallAssertTrue };
    records[@intFromEnum(HostFunction.test262_same_value)] = .{ .length = 2, .call = hostCallAssertSameValue };
    records[@intFromEnum(HostFunction.test262_not_same_value)] = .{ .length = 2, .call = hostCallAssertNotSameValue };
    records[@intFromEnum(HostFunction.test262_throws)] = .{ .length = 2, .call = hostCallAssertThrows };
    records[@intFromEnum(HostFunction.test262_error)] = .{ .length = 1, .call = hostCallTest262Error };
    records[@intFromEnum(HostFunction.test262_verify_property)] = .{ .length = 3, .call = hostCallVerifyProperty };
    records[@intFromEnum(HostFunction.test262_verify_callable_property)] = .{ .length = 4, .call = hostCallVerifyCallableProperty };
    records[@intFromEnum(HostFunction.test262_is_constructor)] = .{ .length = 1, .call = hostCallIsConstructor };
    records[@intFromEnum(HostFunction.test262_verify_not_writable)] = .{ .length = 2, .call = hostCallVerifyNotWritable };
    records[@intFromEnum(HostFunction.test262_verify_not_enumerable)] = .{ .length = 2, .call = hostCallVerifyNotEnumerable };
    records[@intFromEnum(HostFunction.test262_verify_configurable)] = .{ .length = 2, .call = hostCallVerifyConfigurable };
    records[@intFromEnum(HostFunction.test262_compare_array)] = .{ .length = 2, .call = hostCallCompareArray };
    records[@intFromEnum(HostFunction.test262_create_realm)] = .{ .length = 0, .call = hostCallCreateRealm };
    records[@intFromEnum(HostFunction.test262_eval_script)] = .{ .length = 1, .call = hostCallEvalScript };
    records[@intFromEnum(HostFunction.test262_detach_array_buffer)] = .{ .length = 1, .call = hostCallDetachArrayBuffer };
    records[@intFromEnum(HostFunction.test262_is_html_dda)] = .{ .length = 0, .call = hostCallIsHtmlDda };
    records[@intFromEnum(HostFunction.std_load_file)] = .{ .length = 1, .call = hostCallStdLoadFile };
    records[@intFromEnum(HostFunction.std_write_file)] = .{ .length = 2, .call = hostCallStdWriteFile };
    records[@intFromEnum(HostFunction.std_exists)] = .{ .length = 1, .call = hostCallStdExists };
    records[@intFromEnum(HostFunction.std_exit)] = .{ .length = 1, .call = hostCallStdExit };
    records[@intFromEnum(HostFunction.std_getenv)] = .{ .length = 1, .call = hostCallStdGetenv };
    records[@intFromEnum(HostFunction.std_setenv)] = .{ .length = 1, .call = hostCallStdSetenv };
    records[@intFromEnum(HostFunction.std_unsetenv)] = .{ .length = 1, .call = hostCallStdUnsetenv };
    records[@intFromEnum(HostFunction.std_getenviron)] = .{ .length = 1, .call = hostCallStdGetenviron };
    records[@intFromEnum(HostFunction.std_gc)] = .{ .length = 0, .call = hostCallStdGc };
    records[@intFromEnum(HostFunction.std_eval_script)] = .{ .length = 1, .call = hostCallStdEvalScript };
    records[@intFromEnum(HostFunction.std_load_script)] = .{ .length = 1, .call = hostCallStdLoadScript };
    records[@intFromEnum(HostFunction.std_open)] = .{ .length = 2, .call = hostCallStdOpen };
    records[@intFromEnum(HostFunction.std_fdopen)] = .{ .length = 2, .call = hostCallStdFdopen };
    records[@intFromEnum(HostFunction.std_tmpfile)] = .{ .length = 0, .call = hostCallStdTmpfile };
    records[@intFromEnum(HostFunction.std_popen)] = .{ .length = 2, .call = hostCallStdPopen };
    records[@intFromEnum(HostFunction.std_file_close)] = .{ .length = 0, .call = hostCallStdFileClose };
    records[@intFromEnum(HostFunction.std_file_puts)] = .{ .length = 1, .call = hostCallStdFilePuts };
    records[@intFromEnum(HostFunction.std_file_flush)] = .{ .length = 0, .call = hostCallStdFileFlush };
    records[@intFromEnum(HostFunction.std_file_tell)] = .{ .length = 0, .call = hostCallStdFileTell };
    records[@intFromEnum(HostFunction.std_file_seek)] = .{ .length = 2, .call = hostCallStdFileSeek };
    records[@intFromEnum(HostFunction.std_file_eof)] = .{ .length = 0, .call = hostCallStdFileEof };
    records[@intFromEnum(HostFunction.std_file_fileno)] = .{ .length = 0, .call = hostCallStdFileFileno };
    records[@intFromEnum(HostFunction.std_file_error)] = .{ .length = 0, .call = hostCallStdFileError };
    records[@intFromEnum(HostFunction.std_file_clearerr)] = .{ .length = 0, .call = hostCallStdFileClearerr };
    records[@intFromEnum(HostFunction.std_file_read)] = .{ .length = 1, .call = hostCallStdFileRead };
    records[@intFromEnum(HostFunction.std_file_write)] = .{ .length = 1, .call = hostCallStdFileWrite };
    records[@intFromEnum(HostFunction.std_file_getline)] = .{ .length = 0, .call = hostCallStdFileGetline };
    records[@intFromEnum(HostFunction.std_file_read_as_string)] = .{ .length = 0, .call = hostCallStdFileReadAsString };
    records[@intFromEnum(HostFunction.std_file_read_as_array_buffer)] = .{ .length = 0, .call = hostCallStdFileReadAsArrayBuffer };
    records[@intFromEnum(HostFunction.std_file_get_byte)] = .{ .length = 0, .call = hostCallStdFileGetByte };
    records[@intFromEnum(HostFunction.std_file_put_byte)] = .{ .length = 1, .call = hostCallStdFilePutByte };
    records[@intFromEnum(HostFunction.std_strerror)] = .{ .length = 1, .call = hostCallStdStrerror };
    records[@intFromEnum(HostFunction.std_puts)] = .{ .length = 1, .call = hostCallStdPuts };
    records[@intFromEnum(HostFunction.std_printf)] = .{ .length = 1, .call = hostCallStdPrintf };
    records[@intFromEnum(HostFunction.std_sprintf)] = .{ .length = 1, .call = hostCallStdSprintf };
    records[@intFromEnum(HostFunction.std_file_printf)] = .{ .length = 1, .call = hostCallStdFilePrintf };
    records[@intFromEnum(HostFunction.std_url_get)] = .{ .length = 1, .call = hostCallStdUrlGet };
    records[@intFromEnum(HostFunction.os_open)] = .{ .length = 2, .call = hostCallOsOpen };
    records[@intFromEnum(HostFunction.os_close)] = .{ .length = 1, .call = hostCallOsClose };
    records[@intFromEnum(HostFunction.os_seek)] = .{ .length = 3, .call = hostCallOsSeek };
    records[@intFromEnum(HostFunction.os_read)] = .{ .length = 4, .call = hostCallOsRead };
    records[@intFromEnum(HostFunction.os_write)] = .{ .length = 4, .call = hostCallOsWrite };
    records[@intFromEnum(HostFunction.os_mkdir)] = .{ .length = 1, .call = hostCallOsMkdir };
    records[@intFromEnum(HostFunction.os_readdir)] = .{ .length = 1, .call = hostCallOsReaddir };
    records[@intFromEnum(HostFunction.os_stat)] = .{ .length = 1, .call = hostCallOsStat };
    records[@intFromEnum(HostFunction.os_lstat)] = .{ .length = 1, .call = hostCallOsLstat };
    records[@intFromEnum(HostFunction.os_realpath)] = .{ .length = 1, .call = hostCallOsRealpath };
    records[@intFromEnum(HostFunction.os_symlink)] = .{ .length = 2, .call = hostCallOsSymlink };
    records[@intFromEnum(HostFunction.os_readlink)] = .{ .length = 1, .call = hostCallOsReadlink };
    records[@intFromEnum(HostFunction.os_utimes)] = .{ .length = 3, .call = hostCallOsUtimes };
    records[@intFromEnum(HostFunction.os_set_timeout)] = .{ .length = 2, .call = hostCallOsSetTimeout };
    records[@intFromEnum(HostFunction.os_set_interval)] = .{ .length = 2, .call = hostCallOsSetInterval };
    records[@intFromEnum(HostFunction.os_clear_timeout)] = .{ .length = 1, .call = hostCallOsClearTimeout };
    records[@intFromEnum(HostFunction.os_clear_interval)] = .{ .length = 1, .call = hostCallOsClearTimeout };
    records[@intFromEnum(HostFunction.os_exec)] = .{ .length = 1, .call = hostCallOsExec };
    records[@intFromEnum(HostFunction.os_waitpid)] = .{ .length = 2, .call = hostCallOsWaitpid };
    records[@intFromEnum(HostFunction.os_getpid)] = .{ .length = 0, .call = hostCallOsGetpid };
    records[@intFromEnum(HostFunction.os_pipe)] = .{ .length = 0, .call = hostCallOsPipe };
    records[@intFromEnum(HostFunction.os_kill)] = .{ .length = 2, .call = hostCallOsKill };
    records[@intFromEnum(HostFunction.os_dup)] = .{ .length = 1, .call = hostCallOsDup };
    records[@intFromEnum(HostFunction.os_dup2)] = .{ .length = 2, .call = hostCallOsDup2 };
    records[@intFromEnum(HostFunction.os_isatty)] = .{ .length = 1, .call = hostCallOsIsatty };
    records[@intFromEnum(HostFunction.os_tty_get_win_size)] = .{ .length = 1, .call = hostCallOsTtyGetWinSize };
    records[@intFromEnum(HostFunction.os_tty_set_raw)] = .{ .length = 1, .call = hostCallOsTtySetRaw };
    records[@intFromEnum(HostFunction.os_set_read_handler)] = .{ .length = 2, .call = hostCallOsSetReadHandler };
    records[@intFromEnum(HostFunction.os_set_write_handler)] = .{ .length = 2, .call = hostCallOsSetWriteHandler };
    records[@intFromEnum(HostFunction.os_signal)] = .{ .length = 2, .call = hostCallOsSignal };
    records[@intFromEnum(HostFunction.os_cputime)] = .{ .length = 0, .call = hostCallOsCputime };
    records[@intFromEnum(HostFunction.os_exe_path)] = .{ .length = 0, .call = hostCallOsExePath };
    records[@intFromEnum(HostFunction.os_now)] = .{ .length = 0, .call = hostCallOsNow };
    records[@intFromEnum(HostFunction.os_sleep_async)] = .{ .length = 1, .call = hostCallOsSleepAsync };
    records[@intFromEnum(HostFunction.os_mkdtemp)] = .{ .length = 0, .call = hostCallOsMkdtemp };
    records[@intFromEnum(HostFunction.os_mkstemp)] = .{ .length = 0, .call = hostCallOsMkstemp };
    records[@intFromEnum(HostFunction.os_getenv)] = .{ .length = 1, .call = hostCallOsGetenv };
    records[@intFromEnum(HostFunction.os_getcwd)] = .{ .length = 0, .call = hostCallOsGetcwd };
    records[@intFromEnum(HostFunction.os_chdir)] = .{ .length = 1, .call = hostCallOsChdir };
    records[@intFromEnum(HostFunction.os_remove)] = .{ .length = 1, .call = hostCallOsRemove };
    records[@intFromEnum(HostFunction.os_rename)] = .{ .length = 2, .call = hostCallOsRename };
    // test262 agent functions are dynamically registered
    records[@intFromEnum(HostFunction.test262_agent_set_timeout)] = .{ .length = 2, .call = hostCallTest262AgentSetTimeout };
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
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ProcessExit => error.ProcessExit,
        error.ReferenceError => error.ReferenceError,
        error.RangeError => error.RangeError,
        error.SyntaxError => error.SyntaxError,
        error.TypeError => error.TypeError,
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
        @intFromEnum(HostFunction.std_load_file)...@intFromEnum(HostFunction.std_exists),
        @intFromEnum(HostFunction.dstr_get)...@intFromEnum(HostFunction.dstr_elide),
        @intFromEnum(HostFunction.os_getenv)...@intFromEnum(HostFunction.os_rename),
        @intFromEnum(HostFunction.std_exit)...@intFromEnum(HostFunction.os_mkstemp),
        @intFromEnum(HostFunction.dstr_require_iterator),
        @intFromEnum(HostFunction.using_create_disposable_stack)...@intFromEnum(HostFunction.using_dispose_async_stack_for_throw),
        @intFromEnum(HostFunction.external_host),
        => true,
        else => false,
    };
}

fn installTest262Namespace(rt: *core.JSRuntime, global: *core.Object) !void {
    const key = predefinedStringAtom("$262");
    try global.defineTest262NamespaceAutoInitProperty(rt, key, core.property.Flags.data(true, true, true), global);
}

fn definePredefinedHostFunction(rt: *core.JSRuntime, target: *core.Object, comptime name: []const u8, kind: HostFunction) !void {
    try defineHostFunctionWithAtom(rt, target, predefinedStringAtom(name), name, kind, false, null);
}

fn definePredefinedHostConstructorFunction(rt: *core.JSRuntime, target: *core.Object, comptime name: []const u8, kind: HostFunction) !void {
    try defineHostFunctionWithAtom(rt, target, predefinedStringAtom(name), name, kind, true, null);
}

fn defineHostFunction(rt: *core.JSRuntime, target: *core.Object, name: []const u8, kind: HostFunction) !void {
    const key = try temporaryStringAtom(rt, name);
    defer freeTemporaryStringAtom(rt, key);
    try defineHostFunctionWithAtom(rt, target, key, name, kind, false, null);
}

fn defineHostConstructorFunction(rt: *core.JSRuntime, target: *core.Object, name: []const u8, kind: HostFunction) !void {
    const key = try temporaryStringAtom(rt, name);
    defer freeTemporaryStringAtom(rt, key);
    try defineHostFunctionWithAtom(rt, target, key, name, kind, true, null);
}

fn defineHostFunctionWithRealm(rt: *core.JSRuntime, target: *core.Object, name: []const u8, kind: HostFunction, realm_global: ?*core.Object) !void {
    const key = try temporaryStringAtom(rt, name);
    defer freeTemporaryStringAtom(rt, key);
    try defineHostFunctionWithAtom(rt, target, key, name, kind, false, realm_global);
}

fn defineHostFunctionWithAtom(
    rt: *core.JSRuntime,
    target: *core.Object,
    key: core.Atom,
    name: []const u8,
    kind: HostFunction,
    host_function_prototype: bool,
    realm_global: ?*core.Object,
) !void {
    try target.defineHostAutoInitProperty(
        rt,
        key,
        name,
        hostFunctionLength(kind),
        core.property.Flags.data(true, true, true),
        @intFromEnum(kind),
        host_function_prototype,
        realm_global,
    );
}

fn predefinedStringAtom(comptime name: []const u8) core.Atom {
    return comptime core.atom.predefinedId(name, .string).?;
}

fn temporaryStringAtom(rt: *core.JSRuntime, name: []const u8) !core.Atom {
    return core.atom.predefinedId(name, .string) orelse try rt.internAtom(name);
}

fn freeTemporaryStringAtom(rt: *core.JSRuntime, atom_id: core.Atom) void {
    if (core.atom.isConst(atom_id) or core.atom.isTaggedInt(atom_id)) return;
    rt.atoms.free(atom_id);
}

fn createHostFunction(rt: *core.JSRuntime, kind: HostFunction) !*core.Object {
    const function_object = try core.Object.create(rt, core.class.ids.c_function, null);
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

pub fn createStdModuleFunction(rt: *core.JSRuntime, name: []const u8) !core.JSValue {
    const kind: HostFunction = if (std.mem.eql(u8, name, "loadFile"))
        .std_load_file
    else if (std.mem.eql(u8, name, "writeFile"))
        .std_write_file
    else if (std.mem.eql(u8, name, "exists"))
        .std_exists
    else if (std.mem.eql(u8, name, "exit"))
        .std_exit
    else if (std.mem.eql(u8, name, "getenv"))
        .std_getenv
    else if (std.mem.eql(u8, name, "setenv"))
        .std_setenv
    else if (std.mem.eql(u8, name, "unsetenv"))
        .std_unsetenv
    else if (std.mem.eql(u8, name, "getenviron"))
        .std_getenviron
    else if (std.mem.eql(u8, name, "gc"))
        .std_gc
    else if (std.mem.eql(u8, name, "evalScript"))
        .std_eval_script
    else if (std.mem.eql(u8, name, "loadScript"))
        .std_load_script
    else if (std.mem.eql(u8, name, "open"))
        .std_open
    else if (std.mem.eql(u8, name, "fdopen"))
        .std_fdopen
    else if (std.mem.eql(u8, name, "tmpfile"))
        .std_tmpfile
    else if (std.mem.eql(u8, name, "popen"))
        .std_popen
    else if (std.mem.eql(u8, name, "strerror"))
        .std_strerror
    else if (std.mem.eql(u8, name, "puts"))
        .std_puts
    else if (std.mem.eql(u8, name, "printf"))
        .std_printf
    else if (std.mem.eql(u8, name, "sprintf"))
        .std_sprintf
    else if (std.mem.eql(u8, name, "urlGet"))
        .std_url_get
    else
        return error.TypeError;
    return createNamedHostFunctionValue(rt, name, kind);
}

pub fn createOsModuleFunction(rt: *core.JSRuntime, name: []const u8) !core.JSValue {
    const kind: HostFunction = if (std.mem.eql(u8, name, "getenv"))
        .os_getenv
    else if (std.mem.eql(u8, name, "getcwd"))
        .os_getcwd
    else if (std.mem.eql(u8, name, "chdir"))
        .os_chdir
    else if (std.mem.eql(u8, name, "remove"))
        .os_remove
    else if (std.mem.eql(u8, name, "rename"))
        .os_rename
    else if (std.mem.eql(u8, name, "open"))
        .os_open
    else if (std.mem.eql(u8, name, "close"))
        .os_close
    else if (std.mem.eql(u8, name, "seek"))
        .os_seek
    else if (std.mem.eql(u8, name, "read"))
        .os_read
    else if (std.mem.eql(u8, name, "write"))
        .os_write
    else if (std.mem.eql(u8, name, "mkdir"))
        .os_mkdir
    else if (std.mem.eql(u8, name, "readdir"))
        .os_readdir
    else if (std.mem.eql(u8, name, "stat"))
        .os_stat
    else if (std.mem.eql(u8, name, "lstat"))
        .os_lstat
    else if (std.mem.eql(u8, name, "realpath"))
        .os_realpath
    else if (std.mem.eql(u8, name, "symlink"))
        .os_symlink
    else if (std.mem.eql(u8, name, "readlink"))
        .os_readlink
    else if (std.mem.eql(u8, name, "utimes"))
        .os_utimes
    else if (std.mem.eql(u8, name, "setTimeout"))
        .os_set_timeout
    else if (std.mem.eql(u8, name, "setInterval"))
        .os_set_interval
    else if (std.mem.eql(u8, name, "clearTimeout"))
        .os_clear_timeout
    else if (std.mem.eql(u8, name, "clearInterval"))
        .os_clear_interval
    else if (std.mem.eql(u8, name, "exec"))
        .os_exec
    else if (std.mem.eql(u8, name, "waitpid"))
        .os_waitpid
    else if (std.mem.eql(u8, name, "getpid"))
        .os_getpid
    else if (std.mem.eql(u8, name, "pipe"))
        .os_pipe
    else if (std.mem.eql(u8, name, "kill"))
        .os_kill
    else if (std.mem.eql(u8, name, "dup"))
        .os_dup
    else if (std.mem.eql(u8, name, "dup2"))
        .os_dup2
    else if (std.mem.eql(u8, name, "isatty"))
        .os_isatty
    else if (std.mem.eql(u8, name, "ttyGetWinSize"))
        .os_tty_get_win_size
    else if (std.mem.eql(u8, name, "ttySetRaw"))
        .os_tty_set_raw
    else if (std.mem.eql(u8, name, "setReadHandler"))
        .os_set_read_handler
    else if (std.mem.eql(u8, name, "setWriteHandler"))
        .os_set_write_handler
    else if (std.mem.eql(u8, name, "signal"))
        .os_signal
    else if (std.mem.eql(u8, name, "cputime"))
        .os_cputime
    else if (std.mem.eql(u8, name, "exePath"))
        .os_exe_path
    else if (std.mem.eql(u8, name, "now"))
        .os_now
    else if (std.mem.eql(u8, name, "sleepAsync"))
        .os_sleep_async
    else if (std.mem.eql(u8, name, "mkdtemp"))
        .os_mkdtemp
    else if (std.mem.eql(u8, name, "mkstemp"))
        .os_mkstemp
    else
        return shared_vm.createOsModuleNativeFunction(rt, name) orelse return error.TypeError;
    return createNamedHostFunctionValue(rt, name, kind);
}

fn createNamedHostFunctionValue(rt: *core.JSRuntime, name: []const u8, kind: HostFunction) !core.JSValue {
    const function_object = try createHostFunction(rt, kind);
    errdefer function_object.value().free(rt);
    try defineStringPropertyAssumingNew(rt, function_object, "name", name);
    try defineIntPropertyAssumingNew(rt, function_object, "length", hostFunctionLength(kind));
    return function_object.value();
}

fn ensureHostConstructorPrototype(rt: *core.JSRuntime, global: *core.Object, name: []const u8) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const value = global.getProperty(key);
    defer value.free(rt);
    const function_object = thisObject(value) orelse return error.TypeError;
    const prototype = try core.Object.create(rt, core.class.ids.object, null);
    var prototype_raw_owned = true;
    errdefer if (prototype_raw_owned) core.Object.destroyFromHeader(rt, &prototype.header);
    const prototype_value = prototype.value();
    prototype_raw_owned = false;
    defer prototype_value.free(rt);
    try defineObjectPropertyAssumingNew(rt, function_object, "prototype", prototype_value);
}

fn defineObjectProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, true, true, true));
}

fn defineObjectPropertyAssumingNew(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnPropertyAssumingNew(rt, key, core.Descriptor.data(value, true, true, true));
}

fn defineGlobalThisProperty(rt: *core.JSRuntime, global: *core.Object) !void {
    const key = try rt.internAtom("globalThis");
    defer rt.atoms.free(key);
    try global.defineOwnPropertyAssumingNew(rt, key, core.Descriptor.data(global.value(), true, false, true));
}

fn defineIntProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: i32) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(value), true, true, true));
}

fn defineIntPropertyAssumingNew(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: i32) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnPropertyAssumingNew(rt, key, core.Descriptor.data(core.JSValue.int32(value), true, true, true));
}

fn defineNumberProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: f64) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value_ops.numberToValue(value), true, true, true));
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
    try defineConstantPropertyAssumingNew(rt, object, name, value_ops.numberToValue(value));
}

fn defineStringProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: []const u8) !void {
    const string_value = try value_ops.createStringValue(rt, value);
    defer string_value.free(rt);
    try defineObjectProperty(rt, object, name, string_value);
}

fn defineStringPropertyAssumingNew(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: []const u8) !void {
    const string_value = try value_ops.createStringValue(rt, value);
    defer string_value.free(rt);
    try defineObjectPropertyAssumingNew(rt, object, name, string_value);
}

fn hostFunctionLength(kind: HostFunction) i32 {
    return hostFunctionRecord(kind).length;
}

fn promiseObjectFromValue(value: core.JSValue) ?*core.Object {
    const object = thisObject(value) orelse return null;
    if (object.class_id != core.class.ids.promise) return null;
    return object;
}

fn expectCallableObject(value: core.JSValue) ?*core.Object {
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
    function_object.functionPromiseCombinatorCalledSlot().* = true;

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

fn activeGlobalObject(rt: *core.JSRuntime, global: ?*core.Object, globals: []globals_mod.Slot) !?*core.Object {
    if (global) |global_object| return global_object;
    const global_value = try globals_mod.getByName(rt, globals, "globalThis");
    defer global_value.free(rt);
    return thisObject(global_value);
}

fn functionPrototypeFromGlobal(rt: *core.JSRuntime, global: ?*core.Object) ?*core.Object {
    const global_object = global orelse return null;
    const ctor_key = rt.internAtom("Function") catch return null;
    defer rt.atoms.free(ctor_key);
    const ctor_value = global_object.getProperty(ctor_key);
    defer ctor_value.free(rt);
    const ctor_object = thisObject(ctor_value) orelse return null;
    return constructorPrototype(rt, ctor_object);
}

fn createPromiseBuiltinFunction(rt: *core.JSRuntime, global: ?*core.Object, name: []const u8, length: i32) !core.JSValue {
    const function = try builtins.function.nativeFunction(rt, name, length);
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
        promise_val = try builtins.promise.constructWithPrototype(ctx.runtime, constructorPrototype(ctx.runtime, constructor_object));
        resolve_val = try createPromiseBuiltinFunction(ctx.runtime, active_global, "", 1);
        reject_val = try createPromiseBuiltinFunction(ctx.runtime, active_global, "", 1);
        const resolve_object = thisObject(resolve_val) orelse return error.TypeError;
        const reject_object = thisObject(reject_val) orelse return error.TypeError;
        try resolve_object.setFunctionPromiseResolvingTarget(ctx.runtime, promise_val.dup());
        resolve_object.functionPromiseResolvingRejectSlot().* = false;
        try reject_object.setFunctionPromiseResolvingTarget(ctx.runtime, promise_val.dup());
        reject_object.functionPromiseResolvingRejectSlot().* = true;
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

    const constructor_value = try builtins.function.nativeFunction(rt, "Promise", 1);
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
    try std.testing.expect(!resolve_object.functionPromiseResolvingRejectSlot().*);
    try std.testing.expect(reject_object.functionPromiseResolvingRejectSlot().*);

    constructor_value.free(rt);
    constructor_alive = false;
    _ = rt.runObjectCycleRemoval();
}

fn getValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    receiver: core.JSValue,
    key: core.Atom,
) !core.JSValue {
    const receiver_value = try objectStaticToObjectValue(ctx.runtime, global, receiver);
    defer receiver_value.free(ctx.runtime);
    const object = try expectObjectArg(receiver_value);
    var cursor: ?*core.Object = object;
    while (cursor) |current| : (cursor = current.getPrototype()) {
        const desc = current.getOwnProperty(key) orelse continue;
        defer desc.destroy(ctx.runtime);
        return switch (desc.kind) {
            .data => desc.value.dup(),
            .generic => core.JSValue.undefinedValue(),
            .accessor => if (desc.getter.isUndefined())
                core.JSValue.undefinedValue()
            else blk: {
                if (try activeGlobalObject(ctx.runtime, global, globals)) |active_global| {
                    break :blk try shared_vm.callValueOrBytecode(ctx, output, active_global, receiver_value, desc.getter, &.{}, null, null);
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
        return shared_vm.getValueProperty(ctx, output, global_object, receiver, key, null, null);
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
        const desc = try shared_vm.proxyAwareOwnPropertyDescriptor(ctx, output, global_object, object, key, null, null);
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
        const iterator = try builtins.string.iterator(ctx.runtime, iterable);
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
            const iterator = try builtins.string.iterator(ctx.runtime, iterable);
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
    if (array.length <= index) array.length = index + 1;
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

    const record_value = try createPromiseSettlementRecord(rt, false, core.JSValue.symbol(symbol_atom));
    var record_alive = true;
    defer if (record_alive) record_value.free(rt);
    const record = thisObject(record_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_atom = try rt.internAtom("value");
    defer rt.atoms.free(value_atom);
    const value = record.getProperty(value_atom);
    defer value.free(rt);
    try std.testing.expect(value.same(core.JSValue.symbol(symbol_atom)));

    record_value.free(rt);
    record_alive = false;
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

    const symbol_atom = try rt.atoms.newValueSymbol("gc-promise-combinator-state-resolve-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
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
    callback_object.functionPromiseCombinatorModeSlot().* = @intFromEnum(mode);
    try callback_object.setFunctionPromiseCombinatorState(rt, state.value().dup());
    callback_object.functionPromiseCombinatorIndexSlot().* = index;
    callback_object.functionPromiseCombinatorCalledSlot().* = false;
    return callback;
}

fn promiseThenOrCatchCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    promise: *core.Object,
    method_name: []const u8,
    args: []const core.JSValue,
) !core.JSValue {
    const is_catch = std.mem.eql(u8, method_name, "catch");
    const promise_proto = promise.getPrototype();
    const result_value = if (promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
    defer result_value.free(ctx.runtime);

    if (promise.promiseResultSlot().* == null) {
        return builtins.promise.constructWithPrototype(ctx.runtime, promise_proto);
    }

    if (is_catch) {
        if (!promise.promiseIsRejected()) {
            return builtins.promise.fulfilledWithPrototype(ctx.runtime, result_value, promise_proto);
        }
        if (args.len == 0 or !isCallableObjectValue(args[0])) {
            return builtins.promise.rejectedWithPrototype(ctx.runtime, result_value, promise_proto);
        }
        builtins.promise.markHandled(ctx, promise);
        const callback_result = callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, core.JSValue.undefinedValue(), args[0], &.{result_value}) catch |err| {
            const reason = try promiseErrorValue(ctx, try activeGlobalObject(ctx.runtime, global, globals), err);
            defer reason.free(ctx.runtime);
            return builtins.promise.rejectedWithPrototype(ctx.runtime, reason, promise_proto);
        };
        defer callback_result.free(ctx.runtime);
        return builtins.promise.fulfilledWithPrototype(ctx.runtime, callback_result, promise_proto);
    }

    const callback_index: usize = if (promise.promiseIsRejected()) 1 else 0;
    if (args.len <= callback_index or !isCallableObjectValue(args[callback_index])) {
        if (promise.promiseIsRejected()) {
            return builtins.promise.rejectedWithPrototype(ctx.runtime, result_value, promise_proto);
        }
        return builtins.promise.fulfilledWithPrototype(ctx.runtime, result_value, promise_proto);
    }
    if (promise.promiseIsRejected()) builtins.promise.markHandled(ctx, promise);
    const callback_result = callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, core.JSValue.undefinedValue(), args[callback_index], &.{result_value}) catch |err| {
        const reason = try promiseErrorValue(ctx, try activeGlobalObject(ctx.runtime, global, globals), err);
        defer reason.free(ctx.runtime);
        return builtins.promise.rejectedWithPrototype(ctx.runtime, reason, promise_proto);
    };
    defer callback_result.free(ctx.runtime);
    return builtins.promise.fulfilledWithPrototype(ctx.runtime, callback_result, promise_proto);
}

fn isPromiseStaticBuiltinCallee(
    rt: *core.JSRuntime,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    function_object: *core.Object,
    name: []const u8,
) !bool {
    const active_global = try activeGlobalObject(rt, global, globals);
    const global_object = active_global orelse return false;
    const ctor_key = try rt.internAtom("Promise");
    defer rt.atoms.free(ctor_key);
    const ctor_value = global_object.getProperty(ctor_key);
    defer ctor_value.free(rt);
    const ctor_object = thisObject(ctor_value) orelse return false;
    const method_key = try rt.internAtom(name);
    defer rt.atoms.free(method_key);
    const method_value = ctor_object.getProperty(method_key);
    defer method_value.free(rt);
    return builtins.object.sameValue(method_value, function_object.value());
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
    const name = try nativeFunctionDispatchName(ctx.runtime, function_object);
    defer ctx.runtime.memory.allocator.free(name);

    if (try callNativeFunctionRecord(ctx, output, global, globals, this_value, function_object, args, null, null)) |value| return value;

    if (promiseStaticId(name)) |mode| {
        if (mode == 2 or mode == 3 or mode == 5 or mode == 6) {
            if (try isPromiseStaticBuiltinCallee(ctx.runtime, global, globals, function_object, name)) {
                const receiver = thisObject(this_value) orelse return error.TypeError;
                if (!isCallableObjectValue(this_value)) return error.TypeError;
                if (try constructorNameEql(ctx.runtime, receiver, "Promise")) {
                    return promiseCombinatorCall(
                        ctx,
                        output,
                        global,
                        globals,
                        this_value,
                        receiver,
                        args,
                        switch (mode) {
                            2 => .all,
                            3 => .race,
                            5 => .all_settled,
                            6 => .any,
                            else => unreachable,
                        },
                    );
                }
            }
        }
    }

    if (std.mem.eql(u8, name, "then") or std.mem.eql(u8, name, "catch")) {
        if (promiseObjectFromValue(this_value)) |promise| {
            return promiseThenOrCatchCall(ctx, output, global, globals, promise, name, args);
        }
    }

    if (std.mem.eql(u8, name, "get [Symbol.species]")) return this_value.dup();
    if (std.mem.eql(u8, name, "construct")) return reflectConstruct(ctx.runtime, args, globals);
    if (std.mem.eql(u8, name, "get size")) {
        const owner_class = function_object.collectionMethodOwnerClass();
        if (owner_class == core.class.invalid_class_id) return error.TypeError;
        const receiver = thisObject(this_value) orelse return error.TypeError;
        if (receiver.class_id != owner_class) return error.TypeError;
        return builtins.collection.methodCall(ctx.runtime, this_value, 14, &.{}) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            else => err,
        };
    }
    if (std.mem.eql(u8, name, "fromCharCode")) {
        const global_object = global orelse shared_vm.objectRealmGlobal(function_object) orelse ctx.global orelse return error.TypeError;
        return shared_vm.qjsStringFromCharCode(ctx, output, global_object, args);
    }
    if (std.mem.eql(u8, name, "fromCodePoint")) {
        return builtins.string.fromCodePoint(ctx.runtime, args) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            else => err,
        };
    }
    if (try constructorNameEql(ctx.runtime, function_object, "String")) {
        if (args.len == 0) return value_ops.createStringValue(ctx.runtime, "");
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(ctx.runtime.memory.allocator);
        try value_ops.appendValueString(ctx.runtime, &buffer, args[0]);
        return value_ops.createStringValue(ctx.runtime, buffer.items);
    }

    if (try constructorNameEql(ctx.runtime, function_object, "Object")) {
        if (args.len >= 1) {
            if (args[0].isObject()) return args[0].dup();
            if (!args[0].isNull() and !args[0].isUndefined()) {
                const class_id: core.class.ClassId = if (args[0].isString())
                    core.class.ids.string
                else if (args[0].isNumber())
                    core.class.ids.number
                else if (args[0].asBool() != null)
                    core.class.ids.boolean
                else if (args[0].isBigInt())
                    core.class.ids.big_int
                else if (args[0].isSymbol())
                    core.class.ids.symbol
                else
                    core.class.ids.object;
                if (class_id != core.class.ids.object) return primitiveWrapper(ctx.runtime, class_id, args[0], primitivePrototypeFromGlobal(ctx.runtime, global, class_id));
            }
        }
        const object = try core.Object.create(ctx.runtime, core.class.ids.object, null);
        return object.value();
    }
    if (try constructorNameEql(ctx.runtime, function_object, "Array")) {
        return builtins.array.constructConstructorWithPrototype(ctx.runtime, args, null);
    }
    if (core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*)) |native_ref| {
        if (native_ref.domain == .date and native_ref.id == @intFromEnum(builtins.date.ConstructorMethod.construct)) {
            return builtins.date.call(ctx.runtime, args);
        }
    }
    if (try constructorNameEql(ctx.runtime, function_object, "Date")) {
        return builtins.date.call(ctx.runtime, args);
    }
    if (try constructorNameEql(ctx.runtime, function_object, "RegExp")) {
        const active_global = global orelse return error.TypeError;
        return shared_vm.qjsRegExpFunctionCall(ctx, output, active_global, args, null, null);
    }
    if (try constructorNameEql(ctx.runtime, function_object, "String")) {
        if (args.len == 0) return value_ops.createStringValue(ctx.runtime, "");
        return value_ops.toStringValue(ctx.runtime, args[0]);
    }
    if (try constructorNameEql(ctx.runtime, function_object, "Number")) {
        if (args.len == 0) return core.JSValue.int32(0);
        if (args[0].isSymbol()) return error.TypeError;
        return value_ops.numberToValue(try value_ops.toIntegerOrInfinity(ctx.runtime, args[0]));
    }
    if (try constructorNameEql(ctx.runtime, function_object, "Boolean")) {
        return core.JSValue.boolean(args.len >= 1 and value_ops.isTruthy(args[0]));
    }
    if (try constructorNameEql(ctx.runtime, function_object, "Symbol")) {
        const description = if (args.len >= 1 and !args[0].isUndefined())
            try toStringBytesForSymbol(ctx, output, global, args[0])
        else
            try ctx.runtime.memory.allocator.dupe(u8, builtins.symbol.undefined_description);
        defer ctx.runtime.memory.allocator.free(description);
        const symbol_atom = try ctx.runtime.atoms.newValueSymbol(description);
        return core.JSValue.symbol(symbol_atom);
    }
    if (try constructorNameEql(ctx.runtime, function_object, "DOMException")) {
        const active_global = global orelse function_object.functionRealmGlobalPtr() orelse return error.TypeError;
        return shared_vm.throwTypeErrorMessage(ctx, active_global, "constructor requires 'new'");
    }
    if (try constructorNameEql(ctx.runtime, function_object, "BigInt")) {
        const input = if (args.len >= 1) args[0] else core.JSValue.int32(0);
        var bigint = try value_ops.toBigIntValue(ctx.runtime, input);
        defer bigint.deinit();
        return value_ops.createBigIntValue(ctx.runtime, bigint);
    }
    if (try constructorNameEql(ctx.runtime, function_object, "TypedArray")) return error.TypeError;
    if (std.mem.eql(u8, name, "get description")) return symbolDescription(ctx.runtime, this_value);
    if (std.mem.eql(u8, name, "[Symbol.toPrimitive]") and (this_value.isSymbol() or (this_value.isObject() and (try expectObjectArg(this_value)).class_id == core.class.ids.symbol))) {
        return symbolPrimitiveValue(ctx.runtime, this_value);
    }
    if (std.mem.eql(u8, name, "get __proto__")) return objectProtoGetter(ctx.runtime, global, this_value);
    if (std.mem.eql(u8, name, "set __proto__")) return objectProtoSetter(ctx.runtime, this_value, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
    if (std.mem.eql(u8, name, "DisposableStack")) return error.TypeError;
    if (std.mem.eql(u8, name, "AsyncDisposableStack")) return error.TypeError;
    if (std.mem.eql(u8, name, "AggregateError")) {
        if (try activeGlobalObject(ctx.runtime, global, globals)) |global_object| {
            const constructor_global = function_object.functionRealmGlobalPtr() orelse global_object;
            return shared_vm.qjsAggregateErrorConstructWithPrototype(ctx, output, constructor_global, constructorPrototype(ctx.runtime, function_object), args, null, null);
        }
    }
    if (std.mem.eql(u8, name, "SuppressedError")) {
        if (try activeGlobalObject(ctx.runtime, global, globals)) |global_object| {
            return shared_vm.qjsSuppressedErrorConstructWithPrototype(ctx, output, global_object, constructorPrototype(ctx.runtime, function_object), args, null, null);
        }
    }
    if (construct_mod.isErrorConstructorName(name)) {
        if (try activeGlobalObject(ctx.runtime, global, globals)) |global_object| {
            return shared_vm.qjsErrorConstructWithPrototype(ctx, output, global_object, name, constructorPrototype(ctx.runtime, function_object), args, null, null);
        }
        return construct_mod.constructErrorObject(ctx.runtime, name, function_object.value(), constructorPrototype(ctx.runtime, function_object), args);
    }
    if (std.mem.eql(u8, name, "isError")) return errorIsError(args);
    if (std.mem.eql(u8, name, "revoke")) return revokeProxy(ctx.runtime, function_object);
    if (std.mem.eql(u8, name, "sumPrecise")) {
        if (global) |global_object| return shared_vm.qjsMathSumPrecise(ctx, output, global_object, args, null, null);
        return error.TypeError;
    }
    if (builtins.math.methodId(name)) |method| {
        if (global) |global_object| return shared_vm.qjsMathCall(ctx, output, global_object, method, args);
        const number = builtins.math.call(method, args) catch return error.TypeError;
        return value_ops.numberToValue(number);
    }
    if (std.mem.eql(u8, name, "parseInt")) {
        if (global) |global_object| return shared_vm.qjsGlobalParseInt(ctx, output, global_object, args, null, null);
        const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const radix = if (args.len >= 2) args[1] else null;
        return value_ops.numberToValue(try builtins.number.parseIntValue(ctx.runtime, input, radix));
    }
    if (std.mem.eql(u8, name, "parseFloat")) {
        if (global) |global_object| return shared_vm.qjsGlobalParseFloat(ctx, output, global_object, args, null, null);
        const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        return value_ops.numberToValue(try builtins.number.parseFloatValue(ctx.runtime, input));
    }
    if (std.mem.eql(u8, name, "isNaN")) {
        if (thisObject(this_value)) |receiver| {
            if (try constructorNameEql(ctx.runtime, receiver, "Number")) {
                const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
                return core.JSValue.boolean(value.isNumber() and std.math.isNan(value_ops.numberValue(value) orelse std.math.nan(f64)));
            }
        }
        const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const number = try value_ops.toNumberValue(ctx.runtime, input);
        defer number.free(ctx.runtime);
        return core.JSValue.boolean(std.math.isNan(value_ops.numberValue(number) orelse std.math.nan(f64)));
    }
    if (std.mem.eql(u8, name, "isFinite")) {
        if (thisObject(this_value)) |receiver| {
            if (try constructorNameEql(ctx.runtime, receiver, "Number")) {
                const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
                return core.JSValue.boolean(value.isNumber() and std.math.isFinite(value_ops.numberValue(value) orelse std.math.nan(f64)));
            }
        }
        const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const number = try value_ops.toNumberValue(ctx.runtime, input);
        defer number.free(ctx.runtime);
        return core.JSValue.boolean(std.math.isFinite(value_ops.numberValue(number) orelse std.math.nan(f64)));
    }
    if (std.mem.eql(u8, name, "isInteger")) {
        const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        return core.JSValue.boolean(numberIsInteger(value));
    }
    if (std.mem.eql(u8, name, "isSafeInteger")) {
        const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        if (!numberIsInteger(value)) return core.JSValue.boolean(false);
        const number = value_ops.numberValue(value) orelse return core.JSValue.boolean(false);
        return core.JSValue.boolean(@abs(number) <= 9007199254740991.0);
    }
    if (uriCallId(name)) |mode| {
        const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        return builtins.uri.call(ctx.runtime, mode, input) catch |err| switch (err) {
            error.TypeError, error.URIError => err,
            else => err,
        };
    }
    if (std.mem.eql(u8, name, "escape")) {
        const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        return builtins.uri.escape(ctx.runtime, input);
    }
    if (std.mem.eql(u8, name, "unescape")) {
        const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        return builtins.uri.unescape(ctx.runtime, input);
    }
    if (std.mem.eql(u8, name, "btoa")) return globalBtoa(ctx, global, args);
    if (std.mem.eql(u8, name, "atob")) return globalAtob(ctx, global, args);
    if (std.mem.eql(u8, name, "queueMicrotask")) return globalQueueMicrotask(ctx, global, args);
    if (std.mem.eql(u8, name, "gc")) return globalGc(ctx);
    if (std.mem.eql(u8, name, "get userAgent")) return value_ops.createStringValue(ctx.runtime, builtins.registry.navigator_user_agent);
    if ((this_value.isUndefined() or this_value.isNull()) and std.mem.eql(u8, name, "isArray")) return core.JSValue.boolean(args.len >= 1 and try builtins.array.isArrayValue(args[0]));
    if (std.mem.eql(u8, name, "from")) {
        if (try typedArrayStaticFrom(ctx.runtime, this_value, args)) |value| return value;
        return arrayFrom(ctx.runtime, args);
    }
    if (std.mem.eql(u8, name, "of")) {
        if (try typedArrayStaticOf(ctx.runtime, this_value, args)) |value| return value;
    }
    if (std.mem.eql(u8, name, "for")) return symbolFor(ctx, output, global, args);
    if (std.mem.eql(u8, name, "keyFor")) return symbolKeyFor(ctx.runtime, args);

    if (thisObject(this_value)) |receiver| {
        if (shared_vm.isCallableValue(this_value)) {
            if (std.mem.eql(u8, name, "call")) {
                if (args.len < 1) return error.TypeError;
                return callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, args[0], this_value, args[1..]);
            }
            if (std.mem.eql(u8, name, "bind")) {
                const bound_this = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
                const bound_args = if (args.len >= 1) args[1..] else &.{};
                return createBoundFunction(ctx, output, global, globals, this_value, bound_this, bound_args);
            }
            if (std.mem.eql(u8, name, "hasOwnProperty")) return objectHasOwnProperty(ctx, output, global, receiver, args);
            if (std.mem.eql(u8, name, "propertyIsEnumerable")) return objectPropertyIsEnumerable(ctx, output, global, receiver, args);
            if (std.mem.eql(u8, name, "toString")) return functionToStringValue(ctx.runtime, this_value);
            if (std.mem.eql(u8, name, "valueOf")) return this_value.dup();
            if (receiver.class_id == core.class.ids.c_closure) return error.TypeError;
            if (try constructorNameEql(ctx.runtime, receiver, "Promise")) {
                if (promiseStaticId(name)) |mode| {
                    if (mode == 7) {
                        const promise_proto = constructorPrototype(ctx.runtime, receiver);
                        const callback = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
                        const callback_args = if (args.len >= 1) args[1..] else args[0..0];
                        const result = callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, core.JSValue.undefinedValue(), callback, callback_args) catch {
                            const reason = core.JSValue.undefinedValue();
                            return builtins.promise.rejectedWithPrototype(ctx.runtime, reason, promise_proto);
                        };
                        defer result.free(ctx.runtime);
                        return builtins.promise.fulfilledWithPrototype(ctx.runtime, result, promise_proto);
                    }
                    const payload: ?core.JSValue = if (args.len >= 1) args[0] else null;
                    return builtins.promise.staticCallWithPrototype(ctx, mode, payload, constructorPrototype(ctx.runtime, receiver), global) catch |err| switch (err) {
                        error.TypeError => error.TypeError,
                        else => err,
                    };
                }
            }
            if (try constructorNameEql(ctx.runtime, receiver, "BigInt")) {
                if (bigIntStaticUnsigned(name)) |unsigned| {
                    if (args.len < 2) return error.TypeError;
                    return value_ops.asN(ctx.runtime, args[0], args[1], unsigned) catch |err| switch (err) {
                        error.TypeError, error.RangeError => err,
                        else => err,
                    };
                }
            }
            if (try constructorNameEql(ctx.runtime, receiver, "Proxy")) {
                if (std.mem.eql(u8, name, "revocable")) return proxyRevocable(ctx.runtime, global, args);
            }
            if (try constructorNameEql(ctx.runtime, receiver, "Number")) {
                if (std.mem.eql(u8, name, "isNaN")) {
                    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
                    return core.JSValue.boolean(value.isNumber() and std.math.isNan(value_ops.numberValue(value) orelse std.math.nan(f64)));
                }
                if (std.mem.eql(u8, name, "isFinite")) {
                    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
                    return core.JSValue.boolean(value.isNumber() and std.math.isFinite(value_ops.numberValue(value) orelse std.math.nan(f64)));
                }
                if (std.mem.eql(u8, name, "isInteger")) {
                    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
                    return core.JSValue.boolean(numberIsInteger(value));
                }
                if (std.mem.eql(u8, name, "isSafeInteger")) {
                    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
                    if (!numberIsInteger(value)) return core.JSValue.boolean(false);
                    const number = value_ops.numberValue(value) orelse return core.JSValue.boolean(false);
                    return core.JSValue.boolean(@abs(number) <= 9007199254740991.0);
                }
            }
            if (try constructorNameEql(ctx.runtime, receiver, "Date")) {
                if (dateStaticId(name)) |method| {
                    return builtins.date.staticCall(ctx.runtime, method, args) catch |err| switch (err) {
                        error.TypeError => error.TypeError,
                        else => err,
                    };
                }
            }
            if (try constructorNameEql(ctx.runtime, receiver, "String")) {
                if (std.mem.eql(u8, name, "fromCharCode")) {
                    const global_object = global orelse shared_vm.objectRealmGlobal(function_object) orelse ctx.global orelse return error.TypeError;
                    return shared_vm.qjsStringFromCharCode(ctx, output, global_object, args);
                }
                if (std.mem.eql(u8, name, "fromCodePoint")) {
                    return builtins.string.fromCodePoint(ctx.runtime, args) catch |err| switch (err) {
                        error.TypeError => error.TypeError,
                        else => err,
                    };
                }
            }
            if (try constructorNameEql(ctx.runtime, receiver, "Array")) {
                if (std.mem.eql(u8, name, "isArray")) return core.JSValue.boolean(args.len >= 1 and try builtins.array.isArrayValue(args[0]));
                if (std.mem.eql(u8, name, "from")) return arrayFrom(ctx.runtime, args);
            }
            if (try constructorNameEql(ctx.runtime, receiver, "Error")) {
                if (std.mem.eql(u8, name, "captureStackTrace")) {
                    if (try activeGlobalObject(ctx.runtime, global, globals)) |global_object| {
                        return shared_vm.qjsErrorCaptureStackTrace(ctx, output, global_object, args);
                    }
                    return error.TypeError;
                }
            }
            if (try constructorNameEql(ctx.runtime, receiver, "Map")) {
                if (std.mem.eql(u8, name, "groupBy")) return builtins.collection.groupBy(ctx.runtime, args, globals, constructorPrototype(ctx.runtime, receiver)) catch |err| switch (err) {
                    error.TypeError => error.TypeError,
                    else => err,
                };
            }
            return error.TypeError;
        }

        if (shared_vm.isCallSiteObject(ctx.runtime, receiver)) {
            if (try shared_vm.qjsCallSiteMethod(ctx.runtime, receiver, name)) |value| return value;
        }
        if (receiver.is_array and isArrayMethodName(name)) {
            return callArrayMethod(ctx.runtime, output, globals, this_value, name, args);
        }
        if (std.mem.eql(u8, name, "stringify")) {
            const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const replacer = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
            const space = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
            return builtins.json.stringify(ctx.runtime, value, replacer, space) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                else => err,
            };
        }
        if (std.mem.eql(u8, name, "parse")) {
            const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const parsed = try (builtins.json.parse(ctx.runtime, global, value) catch |err| switch (err) {
                error.SyntaxError => error.SyntaxError,
                error.TypeError => error.TypeError,
                else => err,
            });
            return parsed;
        }
        if (std.mem.eql(u8, name, "rawJSON")) {
            const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return builtins.json.rawJSON(ctx.runtime, value) catch |err| switch (err) {
                error.SyntaxError => error.SyntaxError,
                error.TypeError => error.TypeError,
                else => err,
            };
        }
        if (std.mem.eql(u8, name, "isRawJSON")) {
            return core.JSValue.boolean(args.len >= 1 and builtins.json.isRawJSON(args[0]));
        }
        if (receiver.class_id == core.class.ids.map or receiver.class_id == core.class.ids.set or
            receiver.class_id == core.class.ids.weakmap or receiver.class_id == core.class.ids.weakset)
        {
            if (collectionMethodId(name)) |method| {
                const owner_class = function_object.collectionMethodOwnerClass();
                if (owner_class != core.class.invalid_class_id) {
                    if (receiver.class_id != owner_class) return error.TypeError;
                }
                return builtins.collection.methodCallWithGlobals(ctx.runtime, this_value, method, args, globals) catch |err| switch (err) {
                    error.TypeError => error.TypeError,
                    else => err,
                };
            }
        }
        if (receiver.class_id == core.class.ids.weak_ref and std.mem.eql(u8, name, "deref")) {
            return receiver.weakRefDeref(ctx.runtime);
        }
        if (receiver.class_id == core.class.ids.finalization_registry and std.mem.eql(u8, name, "register")) {
            return finalizationRegistryRegister(ctx.runtime, receiver, args);
        }
        if (receiver.class_id == core.class.ids.finalization_registry and std.mem.eql(u8, name, "unregister")) {
            return finalizationRegistryUnregister(ctx.runtime, receiver, args);
        }
        if ((receiver.class_id == core.class.ids.map_iterator or receiver.class_id == core.class.ids.set_iterator) and std.mem.eql(u8, name, "next")) {
            return builtins.collection.methodCall(ctx.runtime, this_value, 13, args) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                else => err,
            };
        }
        if (receiver.class_id == core.class.ids.array_iterator) {
            if (std.mem.eql(u8, name, "next")) {
                return builtins.array.methodCall(ctx.runtime, this_value, 20, args) catch |err| switch (err) {
                    error.TypeError => error.TypeError,
                    else => err,
                };
            }
            if (std.mem.eql(u8, name, "values")) return this_value.dup();
        }
        if (receiver.class_id == core.class.ids.string_iterator and std.mem.eql(u8, name, "next")) {
            return builtins.string.iteratorNext(ctx.runtime, this_value) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                else => err,
            };
        }
        if (receiver.class_id == core.class.ids.string) {
            return callStringMethod(ctx.runtime, this_value, name, args);
        }
        if (receiver.class_id == core.class.ids.number or receiver.class_id == core.class.ids.boolean or
            receiver.class_id == core.class.ids.big_int or receiver.class_id == core.class.ids.symbol)
        {
            const primitive = (receiver.objectData() orelse return error.TypeError).dup();
            defer primitive.free(ctx.runtime);
            return callPrimitiveMethod(ctx.runtime, primitive, name, args);
        }
        regexp_dispatch: {
            if (receiver.class_id != core.class.ids.regexp) break :regexp_dispatch;
            if (regexpAccessorName(name)) |accessor_name| {
                return builtins.regexp.accessor(ctx.runtime, this_value, accessor_name) catch |err| switch (err) {
                    error.TypeError => error.TypeError,
                    else => err,
                };
            }
            if (regexpMethodId(name)) |method| {
                const native_method = regexpNativePrototypeMethodId(function_object) orelse break :regexp_dispatch;
                if (native_method != method) break :regexp_dispatch;
                const arg: ?core.JSValue = if (method == 1 or args.len == 0) null else args[0];
                return builtins.regexp.methodCall(ctx.runtime, this_value, method, arg) catch |err| switch (err) {
                    error.TypeError => error.TypeError,
                    else => err,
                };
            }
        }
        if (receiver.class_id == core.class.ids.dataview) {
            if (dataViewGetId(name)) |method| {
                return builtins.buffer.dataViewGet(ctx.runtime, this_value, method, args) catch |err| switch (err) {
                    error.TypeError => error.TypeError,
                    error.RangeError => error.RangeError,
                    else => err,
                };
            }
            if (dataViewSetId(name)) |method| {
                return builtins.buffer.dataViewSet(ctx.runtime, this_value, method, args) catch |err| switch (err) {
                    error.TypeError => error.TypeError,
                    error.RangeError => error.RangeError,
                    else => err,
                };
            }
        }
        if (receiver.class_id == core.class.ids.promise and (std.mem.eql(u8, name, "then") or std.mem.eql(u8, name, "catch"))) {
            return core.JSValue.undefinedValue();
        }
        if (std.mem.eql(u8, name, "hasOwnProperty")) return objectHasOwnProperty(ctx, output, global, receiver, args);
        if (std.mem.eql(u8, name, "propertyIsEnumerable")) return objectPropertyIsEnumerable(ctx, output, global, receiver, args);
        if (std.mem.eql(u8, name, "toString")) {
            if (isFunctionClass(receiver.class_id) or receiver.class_id == core.class.ids.bytecode_function or receiver.is_proxy) {
                return functionToStringValue(ctx.runtime, this_value);
            }
            if (receiver.class_id == core.class.ids.error_) return errorToString(ctx.runtime, this_value);
            return objectToString(ctx.runtime, this_value);
        }
        if (std.mem.eql(u8, name, "valueOf")) return this_value.dup();
    } else if (this_value.isNumber() or this_value.isBool() or this_value.isBigInt() or this_value.isSymbol()) {
        return callPrimitiveMethod(ctx.runtime, this_value, name, args);
    } else if (this_value.isString()) {
        return callStringMethod(ctx.runtime, this_value, name, args);
    }

    if (std.mem.eql(u8, name, "defineProperty")) return reflectDefineProperty(ctx.runtime, args);
    if (std.mem.eql(u8, name, "get")) return reflectGet(ctx.runtime, args);
    if (std.mem.eql(u8, name, "set")) return reflectSet(ctx, output, global, args);
    if (std.mem.eql(u8, name, "has")) return reflectHas(ctx, output, global, globals, args);
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
    return switch (native_ref.domain) {
        .math => {
            if (native_ref.id == 37) {
                if (global) |global_object| return try shared_vm.qjsMathSumPrecise(ctx, output, global_object, args, caller_function, caller_frame);
                return error.TypeError;
            }
            if (global) |global_object| return try shared_vm.qjsMathCall(ctx, output, global_object, native_ref.id, args);
            const number = builtins.math.call(native_ref.id, args) catch return error.TypeError;
            return value_ops.numberToValue(number);
        },
        .number => try callNumberNativeFunctionRecord(ctx, output, global, this_value, native_ref.id, args, caller_function, caller_frame),
        .string => try callStringNativeFunctionRecord(ctx, output, global, this_value, native_ref.id, args, caller_function, caller_frame),
        .date => try callDateNativeFunctionRecord(ctx, output, global, this_value, function_object, native_ref.id, args, caller_function, caller_frame),
        .array => try callArrayNativeFunctionRecord(ctx, output, global, this_value, function_object, native_ref.id, args),
        .regexp => try callRegExpNativeFunctionRecord(ctx, output, global, this_value, function_object, native_ref.id, args),
        .collection => try callCollectionNativeFunctionRecord(ctx, output, global, globals, this_value, function_object, native_ref.id, args, caller_function, caller_frame),
        .buffer => try callBufferNativeFunctionRecord(ctx, this_value, native_ref.id, args),
        .uri => try callUriNativeFunctionRecord(ctx, output, global, native_ref.id, args, caller_function, caller_frame),
        .performance => try callPerformanceNativeFunctionRecord(ctx, native_ref.id),
        .json => try callJsonNativeFunctionRecord(ctx, output, global, native_ref.id, args, caller_function, caller_frame),
        .atomics => {
            if (global) |global_object| return try shared_vm.qjsAtomicsCallForNativeRecord(ctx, output, global_object, native_ref.id, args, caller_function, caller_frame);
            return error.TypeError;
        },
        .reflect => try callReflectNativeFunctionRecord(ctx, output, global, globals, native_ref.id, args, caller_function, caller_frame),
        .object => try callObjectNativeFunctionRecord(ctx, output, global, globals, this_value, native_ref.id, args, caller_function, caller_frame),
        .primitive => {
            const active_global = global orelse shared_vm.objectRealmGlobal(function_object) orelse ctx.global orelse return error.TypeError;
            return @as(?core.JSValue, try shared_vm.qjsPrimitivePrototypeMethod(ctx, output, active_global, function_object, this_value, native_ref.id, args, caller_function, caller_frame));
        },
        .function => try callFunctionNativeFunctionRecord(ctx, this_value, native_ref.id),
        .error_object => try callErrorNativeFunctionRecord(ctx, output, global, this_value, function_object, native_ref.id, args, caller_function, caller_frame),
        .iterator => try callIteratorNativeFunctionRecord(ctx, output, global, this_value, function_object, native_ref.id, args, caller_function, caller_frame),
    };
}

fn callFunctionNativeFunctionRecord(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    id: u32,
) HostError!?core.JSValue {
    return switch (id) {
        @intFromEnum(builtins.function.PrototypeMethod.to_string) => @as(?core.JSValue, try shared_vm.qjsFunctionToStringCall(ctx, this_value)),
        else => error.TypeError,
    };
}

fn callErrorNativeFunctionRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const function_bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    return switch (id) {
        @intFromEnum(builtins.error_.PrototypeMethod.to_string) => blk: {
            const active_global = global orelse shared_vm.objectRealmGlobal(function_object) orelse ctx.global orelse return error.TypeError;
            break :blk @as(?core.JSValue, try shared_vm.qjsErrorToStringCall(ctx, output, active_global, this_value, caller_function, caller_frame));
        },
        @intFromEnum(builtins.error_.PrototypeMethod.stack_getter) => blk: {
            const active_global = global orelse shared_vm.objectRealmGlobal(function_object) orelse ctx.global orelse return error.TypeError;
            break :blk @as(?core.JSValue, try shared_vm.qjsErrorStackGetter(ctx, output, active_global, this_value));
        },
        @intFromEnum(builtins.error_.PrototypeMethod.stack_setter) => blk: {
            const active_global = global orelse shared_vm.objectRealmGlobal(function_object) orelse ctx.global orelse return error.TypeError;
            break :blk @as(?core.JSValue, try shared_vm.qjsErrorStackSetter(ctx, output, active_global, this_value, function_object, args, caller_function, caller_frame));
        },
        else => error.TypeError,
    };
}

fn callIteratorNativeFunctionRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const function_bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    const active_global = global orelse shared_vm.objectRealmGlobal(function_object) orelse ctx.global orelse return error.TypeError;
    if (try shared_vm.qjsIteratorCallForNativeRecord(ctx, output, active_global, this_value, id, args, caller_function, caller_frame)) |value| return value;
    return error.TypeError;
}

fn callObjectNativeFunctionRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    this_value: core.JSValue,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const function_bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    if (global) |global_object| return try shared_vm.qjsObjectCallForNativeRecord(ctx, output, global_object, this_value, id, args, caller_function, caller_frame);
    if (builtins.object.prototypeMethodOrdinal(id)) |method| {
        return objectPrototypeMethodCall(ctx, output, global, globals, method, this_value, args);
    }
    const name = builtins.object.staticMethodName(id) orelse return error.TypeError;
    return callObjectStatic(ctx, output, global, globals, name, args) catch |err| switch (err) {
        error.TypeError => error.TypeError,
        else => err,
    };
}

fn callReflectNativeFunctionRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const function_bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    if (global) |global_object| return try shared_vm.qjsReflectCallForNativeRecord(ctx, output, global_object, id, args, caller_function, caller_frame);
    const reflect_mod = builtins.reflect_proxy;
    return switch (id) {
        @intFromEnum(reflect_mod.StaticMethod.define_property) => try reflectDefineProperty(ctx.runtime, args),
        @intFromEnum(reflect_mod.StaticMethod.get) => try reflectGet(ctx.runtime, args),
        @intFromEnum(reflect_mod.StaticMethod.set) => try reflectSet(ctx, output, global, args),
        @intFromEnum(reflect_mod.StaticMethod.has) => try reflectHas(ctx, output, global, globals, args),
        @intFromEnum(reflect_mod.StaticMethod.construct) => try reflectConstruct(ctx.runtime, args, globals),
        @intFromEnum(reflect_mod.StaticMethod.apply) => try reflectApply(ctx, output, global, globals, args),
        else => error.TypeError,
    };
}

fn callJsonNativeFunctionRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const function_bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const json_mod = builtins.json;
    return switch (id) {
        @intFromEnum(json_mod.StaticMethod.is_raw_json) => core.JSValue.boolean(args.len >= 1 and json_mod.isRawJSON(args[0])),
        @intFromEnum(json_mod.StaticMethod.raw_json) => {
            const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return json_mod.rawJSON(ctx.runtime, value) catch |err| switch (err) {
                error.SyntaxError => error.SyntaxError,
                error.TypeError => error.TypeError,
                else => err,
            };
        },
        @intFromEnum(json_mod.StaticMethod.parse) => {
            if (global) |global_object| {
                if (try json_vm.qjsJsonParseCall(ctx, output, global_object, args, caller_function, caller_frame)) |value| return value;
                return error.TypeError;
            }
            const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return json_mod.parse(ctx.runtime, global, value) catch |err| switch (err) {
                error.SyntaxError => error.SyntaxError,
                error.TypeError => error.TypeError,
                else => err,
            };
        },
        @intFromEnum(json_mod.StaticMethod.stringify) => {
            if (global) |global_object| {
                if (try json_vm.qjsJsonStringifyCall(ctx, output, global_object, args, caller_function, caller_frame)) |value| return value;
                return error.TypeError;
            }
            const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const replacer = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
            const space = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
            return json_mod.stringify(ctx.runtime, value, replacer, space) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                else => err,
            };
        },
        else => error.TypeError,
    };
}

fn callPerformanceNativeFunctionRecord(ctx: *core.JSContext, id: u32) !core.JSValue {
    return switch (id) {
        1 => core.JSValue.float64(performanceNowMs() - ctx.runtime.performance_time_origin_ms),
        else => error.TypeError,
    };
}

fn callUriNativeFunctionRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const function_bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (global) |global_object| {
        return shared_vm.qjsUriCallForNativeRecord(ctx, output, global_object, id, args, caller_function, caller_frame);
    }
    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    return builtins.uri.call(ctx.runtime, id, input) catch |err| switch (err) {
        error.TypeError, error.URIError => err,
        else => err,
    };
}

fn callNumberNativeFunctionRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    this_value: core.JSValue,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const function_bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const number_mod = builtins.number;
    return switch (id) {
        @intFromEnum(number_mod.StaticMethod.parse_int) => {
            if (global) |global_object| return shared_vm.qjsGlobalParseInt(ctx, output, global_object, args, caller_function, caller_frame);
            const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const radix = if (args.len >= 2) args[1] else null;
            return value_ops.numberToValue(try number_mod.parseIntValue(ctx.runtime, input, radix));
        },
        @intFromEnum(number_mod.StaticMethod.parse_float) => {
            if (global) |global_object| return shared_vm.qjsGlobalParseFloat(ctx, output, global_object, args, caller_function, caller_frame);
            const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return value_ops.numberToValue(try number_mod.parseFloatValue(ctx.runtime, input));
        },
        @intFromEnum(number_mod.StaticMethod.is_nan) => {
            const active_global = global orelse return error.TypeError;
            return shared_vm.qjsGlobalIsNaNOrFinite(ctx, output, active_global, this_value, args, true);
        },
        @intFromEnum(number_mod.StaticMethod.is_finite) => {
            const active_global = global orelse return error.TypeError;
            return shared_vm.qjsGlobalIsNaNOrFinite(ctx, output, active_global, this_value, args, false);
        },
        @intFromEnum(number_mod.StaticMethod.is_integer) => {
            const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return core.JSValue.boolean(numberIsInteger(value));
        },
        @intFromEnum(number_mod.StaticMethod.is_safe_integer) => {
            const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            if (!numberIsInteger(value)) return core.JSValue.boolean(false);
            const number = value_ops.numberValue(value) orelse return core.JSValue.boolean(false);
            return core.JSValue.boolean(@abs(number) <= 9007199254740991.0);
        },
        @intFromEnum(number_mod.PrototypeMethod.to_string),
        @intFromEnum(number_mod.PrototypeMethod.to_locale_string),
        @intFromEnum(number_mod.PrototypeMethod.to_fixed),
        @intFromEnum(number_mod.PrototypeMethod.to_exponential),
        @intFromEnum(number_mod.PrototypeMethod.to_precision),
        => {
            const active_global = global orelse return error.TypeError;
            return shared_vm.qjsNumberPrototypeMethod(ctx, output, active_global, this_value, id, args, null, null);
        },
        else => error.TypeError,
    };
}

fn callStringNativeFunctionRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    this_value: core.JSValue,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const function_bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const active_global = global orelse return error.TypeError;
    return switch (id) {
        @intFromEnum(builtins.string.ConstructorMethod.call) => shared_vm.qjsStringFunctionCall(ctx, output, active_global, args, caller_function, caller_frame),
        @intFromEnum(builtins.string.StaticMethod.from_char_code) => shared_vm.qjsStringFromCharCode(ctx, output, active_global, args),
        @intFromEnum(builtins.string.StaticMethod.from_code_point) => shared_vm.qjsStringFromCodePoint(ctx, output, active_global, args),
        else => {
            const method_id = builtins.string.decodePrototypeMethodId(id) orelse return error.TypeError;
            return shared_vm.qjsStringPrototypeMethod(ctx, output, active_global, this_value, method_id, args, null, null);
        },
    };
}

fn callDateNativeFunctionRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const function_bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (id == @intFromEnum(builtins.date.ConstructorMethod.construct)) {
        return builtins.date.call(ctx.runtime, args);
    }
    if (id == @intFromEnum(builtins.date.PrototypeMethod.to_primitive)) {
        const active_global = global orelse shared_vm.objectRealmGlobal(function_object) orelse ctx.global orelse return error.TypeError;
        return shared_vm.qjsDateToPrimitiveNativeRecord(ctx, output, active_global, this_value, args, caller_function, caller_frame);
    }
    if (id == @intFromEnum(builtins.date.StaticMethod.utc)) {
        const active_global = global orelse return error.TypeError;
        var coerced_args: [7]core.JSValue = undefined;
        var coerced_len: usize = 0;
        defer {
            for (coerced_args[0..coerced_len]) |value| value.free(ctx.runtime);
        }
        while (coerced_len < args.len and coerced_len < coerced_args.len) : (coerced_len += 1) {
            coerced_args[coerced_len] = try shared_vm.toNumberForDateMethod(ctx, output, active_global, args[coerced_len], null, null);
        }
        return builtins.date.staticCall(ctx.runtime, id, coerced_args[0..coerced_len]) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            else => err,
        };
    }
    if (builtins.date.decodePrototypeMethodId(id)) |method_id| {
        const active_global = global orelse return error.TypeError;
        return shared_vm.qjsDatePrototypeMethod(ctx, output, active_global, this_value, method_id, args, caller_function, caller_frame) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            else => err,
        };
    }
    return builtins.date.staticCall(ctx.runtime, id, args) catch |err| switch (err) {
        error.TypeError => error.TypeError,
        else => err,
    };
}

fn callArrayNativeFunctionRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    const active_global = global orelse return error.TypeError;
    return switch (id) {
        @intFromEnum(builtins.array.StaticMethod.is_array) => core.JSValue.boolean(args.len >= 1 and try builtins.array.isArrayValue(args[0])),
        @intFromEnum(builtins.array.StaticMethod.from) => {
            if (try shared_vm.qjsArrayFromCall(ctx, output, active_global, this_value, function_object.value(), args, null, null)) |value| return value;
            return error.TypeError;
        },
        @intFromEnum(builtins.array.StaticMethod.of) => {
            if (try shared_vm.qjsArrayOfCall(ctx, output, active_global, this_value, function_object.value(), args, null, null)) |value| return value;
            return error.TypeError;
        },
        else => {
            if (try shared_vm.qjsArrayPrototypeNativeRecord(ctx, output, active_global, this_value, function_object, id, args, null, null)) |value| return value;
            return error.TypeError;
        },
    };
}

fn callRegExpNativeFunctionRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    if (id == @intFromEnum(builtins.regexp.ConstructorMethod.construct)) {
        const active_global = global orelse return error.TypeError;
        return shared_vm.qjsRegExpFunctionCall(ctx, output, active_global, args, null, null);
    }
    if (id == @intFromEnum(builtins.regexp.StaticMethod.escape)) return builtins.regexp.escape(ctx.runtime, args);
    if (builtins.regexp.legacyAccessorMethodFromId(id)) |method| {
        const active_global = global orelse return error.TypeError;
        return shared_vm.qjsRegExpLegacyAccessor(ctx, output, active_global, this_value, function_object, method, args, null, null);
    }
    if (builtins.regexp.accessorNameFromId(id)) |accessor_name| {
        const active_global = global orelse return error.TypeError;
        if (try shared_vm.qjsRegExpAccessor(ctx, output, active_global, this_value, function_object.value(), accessor_name, null, null)) |value| return value;
        return builtins.regexp.accessor(ctx.runtime, this_value, accessor_name) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            else => err,
        };
    }
    const method_id = builtins.regexp.decodePrototypeMethodId(id) orelse return error.TypeError;
    return callRegExpPrototypeNativeFunctionRecord(ctx, output, global, this_value, function_object, method_id, args);
}

fn callRegExpPrototypeNativeFunctionRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    method_id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    return switch (method_id) {
        1 => {
            const active_global = global orelse return error.TypeError;
            return shared_vm.qjsRegExpToString(ctx, output, active_global, this_value, null, null);
        },
        2 => {
            const active_global = global orelse return error.TypeError;
            if (try shared_vm.qjsRegExpTestMethod(ctx, output, active_global, this_value, args, null, null)) |value| return value;
            return error.TypeError;
        },
        3 => {
            const active_global = global orelse return error.TypeError;
            if (try shared_vm.qjsRegExpExecMethod(ctx, output, active_global, this_value, args, null, null)) |value| return value;
            return error.TypeError;
        },
        4 => {
            const active_global = global orelse return error.TypeError;
            if (try shared_vm.qjsRegExpSymbolSearch(ctx, output, active_global, this_value, args, null, null)) |value| return value;
            return error.TypeError;
        },
        5 => {
            const active_global = global orelse return error.TypeError;
            if (try shared_vm.qjsRegExpSymbolMatch(ctx, output, active_global, this_value, args, null, null)) |value| return value;
            return error.TypeError;
        },
        6 => {
            const active_global = global orelse return error.TypeError;
            if (try shared_vm.qjsRegExpSymbolMatchAll(ctx, output, active_global, this_value, args, null, null)) |value| return value;
            return error.TypeError;
        },
        7 => {
            const active_global = global orelse return error.TypeError;
            if (try shared_vm.qjsRegExpSymbolReplace(ctx, output, active_global, this_value, args, null, null)) |value| return value;
            return error.TypeError;
        },
        8 => {
            const active_global = global orelse return error.TypeError;
            if (try shared_vm.qjsRegExpSymbolSplit(ctx, output, active_global, this_value, args, null, null)) |value| return value;
            return error.TypeError;
        },
        9 => {
            const active_global = function_object.functionRealmGlobalPtr() orelse global orelse return error.TypeError;
            if (try shared_vm.qjsRegExpCompile(ctx, output, active_global, this_value, args, null, null)) |value| return value;
            return error.TypeError;
        },
        else => error.TypeError,
    };
}

fn callCollectionNativeFunctionRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    this_value: core.JSValue,
    function_object: *core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const function_bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (id == @intFromEnum(builtins.collection.StaticMethod.group_by)) {
        return collectionGroupByNativeRecord(ctx, output, global, globals, this_value, args, caller_function, caller_frame);
    }
    const active_global = global orelse return collectionNativeRecordWithoutGlobal(ctx, globals, this_value, function_object, id, args);
    if (try shared_vm.qjsCollectionNativeRecord(ctx, output, active_global, this_value, function_object, id, args, caller_function, caller_frame)) |value| return value;
    return error.TypeError;
}

fn collectionGroupByNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const function_bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const receiver = thisObject(this_value) orelse return error.TypeError;
    if (!try constructorNameEql(ctx.runtime, receiver, "Map")) return error.TypeError;
    const prototype = constructorPrototype(ctx.runtime, receiver);
    if (global) |active_global| {
        if (try shared_vm.qjsMapGroupByRecord(ctx, output, active_global, args, prototype, caller_function, caller_frame)) |value| return value;
        return error.TypeError;
    }
    return builtins.collection.groupBy(ctx.runtime, args, globals, prototype) catch |err| switch (err) {
        error.TypeError => error.TypeError,
        else => err,
    };
}

fn collectionNativeRecordWithoutGlobal(
    ctx: *core.JSContext,
    globals: []globals_mod.Slot,
    this_value: core.JSValue,
    function_object: *core.Object,
    id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    const receiver = thisObject(this_value) orelse return error.TypeError;
    const owner_class = function_object.collectionMethodOwnerClass();
    if (owner_class != core.class.invalid_class_id) {
        if (receiver.class_id != owner_class) return error.TypeError;
    }
    return switch (id) {
        @intFromEnum(builtins.collection.PrototypeMethod.set),
        @intFromEnum(builtins.collection.PrototypeMethod.get),
        @intFromEnum(builtins.collection.PrototypeMethod.has),
        @intFromEnum(builtins.collection.PrototypeMethod.delete),
        @intFromEnum(builtins.collection.PrototypeMethod.clear),
        @intFromEnum(builtins.collection.PrototypeMethod.add),
        @intFromEnum(builtins.collection.PrototypeMethod.keys),
        @intFromEnum(builtins.collection.PrototypeMethod.values),
        @intFromEnum(builtins.collection.PrototypeMethod.entries),
        @intFromEnum(builtins.collection.PrototypeMethod.for_each),
        @intFromEnum(builtins.collection.PrototypeMethod.get_or_insert),
        @intFromEnum(builtins.collection.PrototypeMethod.get_or_insert_computed),
        @intFromEnum(builtins.collection.PrototypeMethod.size_getter),
        @intFromEnum(builtins.collection.PrototypeMethod.difference),
        @intFromEnum(builtins.collection.PrototypeMethod.intersection),
        @intFromEnum(builtins.collection.PrototypeMethod.is_disjoint_from),
        @intFromEnum(builtins.collection.PrototypeMethod.is_subset_of),
        @intFromEnum(builtins.collection.PrototypeMethod.is_superset_of),
        @intFromEnum(builtins.collection.PrototypeMethod.symmetric_difference),
        @intFromEnum(builtins.collection.PrototypeMethod.union_),
        => builtins.collection.methodCallWithContext(ctx, this_value, id, args, globals) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            else => err,
        },
        else => error.TypeError,
    };
}

fn callBufferNativeFunctionRecord(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    if (try shared_vm.qjsBufferNativeRecord(ctx, this_value, id, args)) |value| return value;
    return error.TypeError;
}

pub fn hostCreateRealm(rt: *core.JSRuntime) HostError!core.JSValue {
    const realm = try core.Object.create(rt, core.class.ids.object, null);
    errdefer realm.value().free(rt);
    const realm_global = try core.Object.create(rt, core.class.ids.object, null);
    var realm_global_owned = true;
    errdefer if (realm_global_owned) realm_global.value().free(rt);
    realm_global.is_global = true;
    try builtins.registry.installStandardGlobals(rt, realm_global);
    try defineGlobalThisProperty(rt, realm_global);
    try tagRealmEval(rt, realm_global);
    try tagRealmFunctionConstructor(rt, realm_global);
    try tagRealmRegExpAccessorErrors(rt, realm_global);
    try defineObjectProperty(rt, realm, "global", realm_global.value());
    realm_global.value().free(rt);
    realm_global_owned = false;
    try defineHostFunctionWithRealm(rt, realm, "evalScript", .test262_eval_script, realm_global);
    return realm.value();
}

fn hostDetachArrayBuffer(rt: *core.JSRuntime, args: []const core.JSValue) HostError!core.JSValue {
    if (args.len < 1) return error.TypeError;
    return builtins.buffer.detachArrayBuffer(rt, args[0]);
}

fn tagRealmEval(rt: *core.JSRuntime, realm_global: *core.Object) !void {
    const eval_key = try rt.internAtom("eval");
    defer rt.atoms.free(eval_key);
    const eval_value = realm_global.getProperty(eval_key);
    defer eval_value.free(rt);
    const eval_object = expectObjectArg(eval_value) catch return;
    const slot = eval_object.functionRealmGlobalSlot();
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
        const desc = proto.getOwnProperty(key) orelse continue;
        defer desc.destroy(rt);
        if (desc.kind != .accessor or desc.getter.isUndefined()) continue;
        const getter_object = expectObjectArg(desc.getter) catch continue;
        const slot = getter_object.functionRealmTypeErrorConstructorSlot();
        try getter_object.setOptionalValueSlot(rt, slot, type_error_value.dup());
    }
}

fn reflectConstruct(rt: *core.JSRuntime, args: []const core.JSValue, globals: []globals_mod.Slot) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    if (!isConstructorValue(rt, args[0])) return error.TypeError;
    const target = thisObject(args[0]) orelse return error.TypeError;
    const target_name = nativeFunctionName(rt, target) catch null;
    defer if (target_name) |name| rt.memory.allocator.free(name);
    const new_target = if (args.len >= 3) args[2] else args[0];
    if (!isConstructorValue(rt, new_target)) return error.TypeError;
    if (isDateConstructorRecord(target)) {
        var construct_args = ReflectConstructArguments{};
        try construct_args.init(rt, args[1]);
        defer construct_args.deinit();
        const prototype = try reflectConstructPrototype(rt, "Date", new_target, args[0]);
        return builtins.date.constructWithPrototype(rt, construct_args.values, prototype);
    }
    if (target_name) |name| {
        if (std.mem.eql(u8, name, "Array")) {
            if (args.len < 2) return error.TypeError;
            var construct_args = ReflectConstructArguments{};
            try construct_args.init(rt, args[1]);
            defer construct_args.deinit();
            const prototype = try reflectConstructPrototype(rt, name, new_target, args[0]);
            return builtins.array.constructConstructorWithPrototype(rt, construct_args.values, prototype);
        }
        if (std.mem.eql(u8, name, "Iterator")) {
            if (builtins.object.sameValue(new_target, args[0])) return error.TypeError;
            const prototype = try reflectConstructPrototype(rt, name, new_target, args[0]);
            const instance = try core.Object.create(rt, core.class.ids.object, prototype);
            errdefer core.Object.destroyFromHeader(rt, &instance.header);
            return instance.value();
        }
        if (std.mem.eql(u8, name, "Number")) {
            var construct_args = ReflectConstructArguments{};
            try construct_args.init(rt, args[1]);
            defer construct_args.deinit();
            const primitive = if (construct_args.values.len >= 1) blk: {
                if (construct_args.values[0].isSymbol()) return error.TypeError;
                break :blk value_ops.numberToValue(try value_ops.toIntegerOrInfinity(rt, construct_args.values[0]));
            } else core.JSValue.int32(0);
            const prototype = try reflectConstructPrototype(rt, name, new_target, args[0]);
            return primitiveWrapper(rt, core.class.ids.number, primitive, prototype);
        }
        if (std.mem.eql(u8, name, "Date")) {
            var construct_args = ReflectConstructArguments{};
            try construct_args.init(rt, args[1]);
            defer construct_args.deinit();
            const prototype = try reflectConstructPrototype(rt, name, new_target, args[0]);
            return builtins.date.constructWithPrototype(rt, construct_args.values, prototype);
        }
        if (std.mem.eql(u8, name, "FinalizationRegistry")) {
            var construct_args = ReflectConstructArguments{};
            try construct_args.init(rt, args[1]);
            defer construct_args.deinit();
            const cleanup_callback = if (construct_args.values.len >= 1) construct_args.values[0] else return error.TypeError;
            if (!isCallableObjectValue(cleanup_callback)) return error.TypeError;
            const prototype = try reflectConstructPrototype(rt, name, new_target, args[0]);
            const instance = try core.Object.create(rt, core.class.ids.finalization_registry, prototype);
            errdefer core.Object.destroyFromHeader(rt, &instance.header);
            try instance.setOptionalValueSlot(rt, instance.finalizationRegistryCleanupCallbackSlot(), cleanup_callback.dup());
            return instance.value();
        }
        if (std.mem.eql(u8, name, "WeakRef")) {
            var construct_args = ReflectConstructArguments{};
            try construct_args.init(rt, args[1]);
            defer construct_args.deinit();
            const target_value = if (construct_args.values.len >= 1) construct_args.values[0] else return error.TypeError;
            if (!canBeHeldWeakly(rt, target_value)) return error.TypeError;
            const prototype = try reflectConstructPrototype(rt, name, new_target, args[0]);
            return construct_mod.weakRefWithPrototype(rt, target_value, prototype);
        }
        if (collectionConstructorId(name)) |kind| {
            const prototype = try reflectConstructPrototype(rt, name, new_target, args[0]);
            return builtins.collection.constructWithPrototype(rt, kind, prototype) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                else => err,
            };
        }
        if (construct_mod.typedArrayElement(name)) |element| {
            var construct_args = ReflectConstructArguments{};
            try construct_args.init(rt, args[1]);
            defer construct_args.deinit();
            const prototype = try reflectConstructPrototype(rt, name, new_target, args[0]);
            const global_object = try activeGlobalObject(rt, null, globals);
            return construct_mod.constructTypedArrayValue(rt, prototype, element, construct_args.values, global_object);
        }
    }

    {
        const prototype = try reflectConstructPrototype(rt, target_name orelse "Object", new_target, args[0]);
        const instance = try core.Object.create(rt, core.class.ids.object, prototype);
        errdefer core.Object.destroyFromHeader(rt, &instance.header);
        return instance.value();
    }
}

fn reflectApply(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 3) return error.TypeError;
    if (!shared_vm.isCallableValue(args[0])) return error.TypeError;
    var apply_args = ReflectConstructArguments{};
    try apply_args.init(ctx.runtime, args[2]);
    defer apply_args.deinit();
    return callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, args[1], args[0], apply_args.values);
}

const ValueSliceRoot = struct {
    rt: ?*core.JSRuntime = null,
    slices: [1]core.runtime.ValueRootSlice = undefined,
    frame: core.runtime.ValueRootFrame = .{},

    fn init(self: *ValueSliceRoot, rt: *core.JSRuntime, values: *[]core.JSValue) void {
        self.rt = rt;
        self.slices[0] = .{ .mutable = values };
        self.frame = .{
            .previous = rt.active_value_roots,
            .slices = &self.slices,
        };
        rt.active_value_roots = &self.frame;
    }

    fn deinit(self: *ValueSliceRoot) void {
        const rt = self.rt orelse return;
        rt.active_value_roots = self.frame.previous;
        self.rt = null;
    }
};

const ReflectConstructArguments = struct {
    rt: ?*core.JSRuntime = null,
    values: []core.JSValue = &.{},
    root: ValueSliceRoot = .{},

    fn init(self: *ReflectConstructArguments, rt: *core.JSRuntime, value: core.JSValue) !void {
        self.values = try reflectConstructArgumentList(rt, value);
        self.rt = rt;
        self.root.init(rt, &self.values);
    }

    fn deinit(self: *ReflectConstructArguments) void {
        const rt = self.rt orelse return;
        self.root.deinit();
        freeReflectConstructArgumentList(rt, self.values);
        self.* = .{};
    }
};

fn reflectConstructArgumentList(rt: *core.JSRuntime, value: core.JSValue) ![]core.JSValue {
    const object = try expectObjectArg(value);
    if (!object.is_array) return error.TypeError;
    const out = try rt.memory.alloc(core.JSValue, object.length);
    errdefer rt.memory.free(core.JSValue, out);
    var rooted_out: []core.JSValue = out[0..0];
    var out_root = ValueSliceRoot{};
    out_root.init(rt, &rooted_out);
    defer out_root.deinit();
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |item| item.free(rt);
    }
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        out[index] = object.getProperty(core.atom.atomFromUInt32(index));
        initialized += 1;
        rooted_out = out[0..initialized];
    }
    return out;
}

fn freeReflectConstructArgumentList(rt: *core.JSRuntime, values: []core.JSValue) void {
    for (values) |value| value.free(rt);
    if (values.len != 0) rt.memory.free(core.JSValue, values);
}

fn isConstructorValue(rt: *core.JSRuntime, value: core.JSValue) bool {
    if (!value_ops.isFunctionObject(value)) return false;
    const object = thisObject(value) orelse return false;
    if (object.proxyTarget()) |target| return isConstructorValue(rt, target);
    if (isDateConstructorRecord(object)) return true;
    return switch (object.class_id) {
        core.class.ids.c_function => {
            const name = nativeFunctionName(rt, object) catch return false;
            defer rt.memory.allocator.free(name);
            return isBuiltinConstructorName(name);
        },
        core.class.ids.bytecode_function,
        core.class.ids.c_closure,
        core.class.ids.bound_function,
        => true,
        else => false,
    };
}

fn isDateConstructorRecord(object: *core.Object) bool {
    const native_ref = core.function.decodeNativeBuiltinId(object.nativeFunctionIdSlot().*) orelse return false;
    return native_ref.domain == .date and native_ref.id == @intFromEnum(builtins.date.ConstructorMethod.construct);
}

fn reflectConstructPrototype(rt: *core.JSRuntime, target_name: []const u8, new_target: core.JSValue, target: core.JSValue) !?*core.Object {
    if (thisObject(new_target)) |new_target_object| {
        const prototype_value = new_target_object.getProperty(core.atom.ids.prototype);
        defer prototype_value.free(rt);
        if (prototype_value.isObject()) {
            const header = prototype_value.refHeader() orelse return null;
            return @fieldParentPtr("header", header);
        }
        var realm_source = new_target_object;
        while (true) {
            if (realm_source.class_id == core.class.ids.bound_function) {
                realm_source = boundFunctionTargetObject(realm_source) orelse break;
                continue;
            }
            if (realm_source.proxyTarget()) |target_value| {
                realm_source = thisObject(target_value) orelse break;
                continue;
            }
            break;
        }
        const realm_key = try realmPrototypeKey(rt, target_name);
        defer rt.memory.allocator.free(realm_key);
        const realm_proto_key = try rt.internAtom(realm_key);
        defer rt.atoms.free(realm_proto_key);
        const realm_proto_value = realm_source.getProperty(realm_proto_key);
        defer realm_proto_value.free(rt);
        if (realm_proto_value.isObject()) {
            const header = realm_proto_value.refHeader() orelse return null;
            return @fieldParentPtr("header", header);
        }
    }
    const target_object = expectCallableObject(target) orelse return null;
    return constructorPrototype(rt, target_object);
}

const ActiveRootSymbolProbe = struct {
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
        var visitor = core.runtime.RootVisitor{
            .context = self,
            .visit_value = @This().visitValue,
            .visit_object = @This().visitObject,
        };
        self.rt.traceActiveRoots(&visitor) catch {
            self.trace_failed = true;
        };
    }

    fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (slot.asSymbolAtom()) |atom_id| {
            if (atom_id == self.atom_id) self.saw_symbol = true;
        }
    }

    fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void {
        _ = context;
        _ = slot;
    }
};

test "reflect construct roots argument list while resolving prototype" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const target = try builtins.function.nativeFunction(rt, "Array", 1);
    defer target.free(rt);
    const new_target = try builtins.function.nativeFunction(rt, "Array", 1);
    defer new_target.free(rt);
    const new_target_object = thisObject(new_target) orelse return error.TypeError;
    try new_target_object.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(core.JSValue.int32(1), true, false, true));

    const args_object = try core.Object.createArray(rt, null);
    var args_alive = true;
    defer if (args_alive) args_object.value().free(rt);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-reflect-construct-argument-root");
    try setArrayIndex(rt, args_object, 0, core.JSValue.symbol(symbol_atom));

    const saved_trigger_fn = rt.memory.trigger_gc_fn;
    const saved_trigger_ctx = rt.memory.trigger_gc_ctx;
    var probe = ActiveRootSymbolProbe{
        .rt = rt,
        .atom_id = symbol_atom,
    };
    rt.memory.trigger_gc_fn = ActiveRootSymbolProbe.trigger;
    rt.memory.trigger_gc_ctx = &probe;
    defer {
        rt.memory.trigger_gc_fn = saved_trigger_fn;
        rt.memory.trigger_gc_ctx = saved_trigger_ctx;
    }

    var globals = [_]globals_mod.Slot{};
    const reflect_args = [_]core.JSValue{ target, args_object.value(), new_target };
    const result = try reflectConstruct(rt, &reflect_args, globals[0..]);
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

fn realmPrototypeKey(rt: *core.JSRuntime, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(rt.memory.allocator, "__realm_{s}_proto", .{name});
}

fn callArrayMethod(
    rt: *core.JSRuntime,
    output: ?*std.Io.Writer,
    globals: []globals_mod.Slot,
    receiver: core.JSValue,
    name: []const u8,
    args: []const core.JSValue,
) HostError!core.JSValue {
    if (std.mem.eql(u8, name, "toString")) return value_ops.toStringValue(rt, receiver);
    if (std.mem.eql(u8, name, "forEach")) return forEachArrayPrint(rt, output, receiver);
    if (std.mem.eql(u8, name, "map")) return arrayMapCallback(rt, receiver, args, globals);
    if (std.mem.eql(u8, name, "join")) return arrayJoinCall(rt, receiver, args);
    if (arrayMethodId(name)) |method| {
        return switch (method) {
            1, 2, 4, 5 => builtins.array.methodCall(rt, receiver, method, &.{}),
            else => builtins.array.methodCall(rt, receiver, method, args),
        } catch |err| switch (err) {
            error.TypeError => error.TypeError,
            else => err,
        };
    }
    return error.TypeError;
}

fn isArrayMethodName(name: []const u8) bool {
    return std.mem.eql(u8, name, "toString") or
        std.mem.eql(u8, name, "forEach") or
        std.mem.eql(u8, name, "map") or
        std.mem.eql(u8, name, "join") or
        arrayMethodId(name) != null;
}

fn callObjectStatic(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    name: []const u8,
    args: []const core.JSValue,
) !core.JSValue {
    const rt = ctx.runtime;
    if (std.mem.eql(u8, name, "assign")) {
        if (args.len < 1) return error.TypeError;
        const target_value = try objectStaticToObjectValue(rt, global, args[0]);
        errdefer target_value.free(rt);
        const target = try expectObjectArg(target_value);
        for (args[1..]) |source_arg| {
            if (source_arg.isNull() or source_arg.isUndefined()) continue;
            const source_value = try objectStaticToObjectValue(rt, global, source_arg);
            defer source_value.free(rt);
            const source = try expectObjectArg(source_value);
            const keys = try source.ownKeys(rt);
            defer core.Object.freeKeys(rt, keys);
            for (keys) |key| {
                const desc = source.getOwnProperty(key) orelse continue;
                defer desc.destroy(rt);
                if (desc.enumerable != true) continue;
                const value = try objectAssignGet(ctx, output, global, globals, source_value, desc);
                defer value.free(rt);
                try objectAssignSet(ctx, output, global, globals, target_value, target, key, value);
            }
        }
        return target_value;
    }
    if (std.mem.eql(u8, name, "create")) {
        if (args.len < 1) return error.TypeError;
        const proto: ?*core.Object = if (args[0].isNull())
            null
        else
            try expectObjectArg(args[0]);
        const object = try core.Object.create(rt, core.class.ids.object, proto);
        errdefer core.Object.destroyFromHeader(rt, &object.header);
        object.null_prototype = args[0].isNull();
        if (args.len >= 2 and !args[1].isUndefined()) {
            try definePropertiesFromObject(rt, object, args[1]);
        }
        return object.value();
    }
    if (std.mem.eql(u8, name, "is")) {
        const lhs = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const rhs = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
        return core.JSValue.boolean(builtins.object.sameValue(lhs, rhs));
    }
    if (std.mem.eql(u8, name, "keys")) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(rt, global, args[0]);
        defer object_value.free(rt);
        return builtins.object.ownEntriesArray(rt, object_value, .keys);
    }
    if (std.mem.eql(u8, name, "values")) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(rt, global, args[0]);
        defer object_value.free(rt);
        return builtins.object.ownEntriesArray(rt, object_value, .values);
    }
    if (std.mem.eql(u8, name, "entries")) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(rt, global, args[0]);
        defer object_value.free(rt);
        return builtins.object.ownEntriesArray(rt, object_value, .entries);
    }
    if (std.mem.eql(u8, name, "getOwnPropertyDescriptor")) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(rt, global, args[0]);
        defer object_value.free(rt);
        const object = try expectObjectArg(object_value);
        const key_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
        const key = try atomFromPropertyKey(rt, key_value);
        defer rt.atoms.free(key);
        var desc = object.getOwnProperty(key) orelse return core.JSValue.undefinedValue();
        materializeMappedArgumentsDescriptorValue(rt, object, key, &desc);
        defer desc.destroy(rt);
        return descriptorObject(rt, desc);
    }
    if (std.mem.eql(u8, name, "getOwnPropertyDescriptors")) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(rt, global, args[0]);
        defer object_value.free(rt);
        const object = try expectObjectArg(object_value);
        const keys = try object.ownKeys(rt);
        defer core.Object.freeKeys(rt, keys);
        const out = try core.Object.create(rt, core.class.ids.object, null);
        errdefer core.Object.destroyFromHeader(rt, &out.header);
        for (keys) |key| {
            var desc = object.getOwnProperty(key) orelse continue;
            materializeMappedArgumentsDescriptorValue(rt, object, key, &desc);
            defer desc.destroy(rt);
            const desc_value = try descriptorObject(rt, desc);
            defer desc_value.free(rt);
            try out.defineOwnProperty(rt, key, core.Descriptor.data(desc_value, true, true, true));
        }
        return out.value();
    }
    if (std.mem.eql(u8, name, "getOwnPropertyNames")) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(rt, global, args[0]);
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
    if (std.mem.eql(u8, name, "getOwnPropertySymbols")) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(rt, global, args[0]);
        defer object_value.free(rt);
        const object = try expectObjectArg(object_value);
        const keys = try object.ownKeys(rt);
        defer core.Object.freeKeys(rt, keys);
        const out = try core.Object.createArray(rt, null);
        errdefer core.Object.destroyFromHeader(rt, &out.header);
        for (keys) |key| {
            if (rt.atoms.kind(key) != .symbol) continue;
            try out.defineOwnProperty(rt, core.atom.atomFromUInt32(out.length), core.Descriptor.data(core.JSValue.symbol(key), true, true, true));
        }
        return out.value();
    }
    if (std.mem.eql(u8, name, "hasOwn")) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(rt, global, args[0]);
        defer object_value.free(rt);
        const object = try expectObjectArg(object_value);
        const key_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
        const key = try atomFromPropertyKey(rt, key_value);
        defer rt.atoms.free(key);
        if (object.getOwnProperty(key)) |desc| {
            desc.destroy(rt);
            return core.JSValue.boolean(true);
        }
        return core.JSValue.boolean(false);
    }
    if (std.mem.eql(u8, name, "getPrototypeOf")) {
        if (args.len < 1) return error.TypeError;
        const object_value = try objectStaticToObjectValue(rt, global, args[0]);
        defer object_value.free(rt);
        const object = try expectObjectArg(object_value);
        if (object.getPrototype()) |prototype| return prototype.value().dup();
        return core.JSValue.nullValue();
    }
    if (std.mem.eql(u8, name, "setPrototypeOf")) {
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
    if (std.mem.eql(u8, name, "isExtensible")) {
        const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const object = thisObject(target_value) orelse return core.JSValue.boolean(false);
        return core.JSValue.boolean(object.isExtensible());
    }
    if (std.mem.eql(u8, name, "preventExtensions")) {
        const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const object = thisObject(target_value) orelse return target_value.dup();
        object.preventExtensions();
        return target_value.dup();
    }
    if (std.mem.eql(u8, name, "seal")) {
        const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const object = thisObject(target_value) orelse return target_value.dup();
        try object.seal(rt);
        return target_value.dup();
    }
    if (std.mem.eql(u8, name, "isSealed")) {
        const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const object = thisObject(target_value) orelse return core.JSValue.boolean(true);
        return core.JSValue.boolean(try objectIsSealed(rt, object));
    }
    if (std.mem.eql(u8, name, "isFrozen")) {
        const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const object = thisObject(target_value) orelse return core.JSValue.boolean(true);
        return core.JSValue.boolean(try objectIsFrozen(rt, object));
    }
    if (std.mem.eql(u8, name, "freeze")) {
        const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        const object = thisObject(target_value) orelse return target_value.dup();
        try object.freeze(rt);
        return target_value.dup();
    }
    if (std.mem.eql(u8, name, "defineProperty")) {
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
    if (std.mem.eql(u8, name, "defineProperties")) {
        if (args.len < 2) return error.TypeError;
        const object = try expectObjectArg(args[0]);
        try definePropertiesFromObject(rt, object, args[1]);
        return object.value().dup();
    }
    return error.TypeError;
}

fn objectStaticToObjectValue(rt: *core.JSRuntime, global: ?*core.Object, value: core.JSValue) !core.JSValue {
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
    return primitiveWrapper(rt, class_id, value, primitivePrototypeFromGlobal(rt, global, class_id));
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
    if (target.getOwnProperty(key)) |desc| {
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
            if (prototype.getOwnProperty(key)) |desc| {
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
        const desc = object.getOwnProperty(key) orelse continue;
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
        const desc = object.getOwnProperty(key) orelse continue;
        defer desc.destroy(rt);
        if (desc.kind == .data and desc.writable == true) return false;
    }
    return true;
}

fn objectPrototypeMethodCall(
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
            const receiver_value = try objectStaticToObjectValue(ctx.runtime, global, this_value);
            defer receiver_value.free(ctx.runtime);
            const receiver = try expectObjectArg(receiver_value);
            const method_value = receiver.getProperty(to_string_key);
            defer method_value.free(ctx.runtime);
            return callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, receiver_value, method_value, &.{});
        },
        3 => objectPrototypeValueOf(ctx.runtime, global, this_value),
        4 => objectPrototypeHasOwn(ctx.runtime, global, this_value, args),
        5 => objectPrototypeIsPrototypeOf(ctx.runtime, global, this_value, args),
        6 => objectPrototypePropertyIsEnumerable(ctx.runtime, global, this_value, args),
        7 => objectPrototypeDefineAccessor(ctx.runtime, global, this_value, args, true),
        8 => objectPrototypeDefineAccessor(ctx.runtime, global, this_value, args, false),
        9 => objectPrototypeLookupAccessor(ctx.runtime, global, this_value, args, true),
        10 => objectPrototypeLookupAccessor(ctx.runtime, global, this_value, args, false),
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

fn objectPrototypeValueOf(rt: *core.JSRuntime, global: ?*core.Object, receiver: core.JSValue) !core.JSValue {
    return objectStaticToObjectValue(rt, global, receiver);
}

fn objectPrototypeHasOwn(rt: *core.JSRuntime, global: ?*core.Object, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const key = try atomFromPropertyKey(rt, key_value);
    defer rt.atoms.free(key);
    const receiver_value = try objectStaticToObjectValue(rt, global, receiver);
    defer receiver_value.free(rt);
    const object = try expectObjectArg(receiver_value);
    if (object.getOwnProperty(key)) |desc| {
        desc.destroy(rt);
        return core.JSValue.boolean(true);
    }
    return core.JSValue.boolean(false);
}

fn objectPrototypePropertyIsEnumerable(rt: *core.JSRuntime, global: ?*core.Object, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const key = try atomFromPropertyKey(rt, key_value);
    defer rt.atoms.free(key);
    const receiver_value = try objectStaticToObjectValue(rt, global, receiver);
    defer receiver_value.free(rt);
    const object = try expectObjectArg(receiver_value);
    const desc = object.getOwnProperty(key) orelse return core.JSValue.boolean(false);
    defer desc.destroy(rt);
    return core.JSValue.boolean(desc.enumerable orelse false);
}

fn objectPrototypeIsPrototypeOf(rt: *core.JSRuntime, global: ?*core.Object, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const value_object = thisObject(value) orelse return core.JSValue.boolean(false);
    const receiver_value = try objectStaticToObjectValue(rt, global, receiver);
    defer receiver_value.free(rt);
    const object = try expectObjectArg(receiver_value);
    var proto = value_object.getPrototype();
    while (proto) |candidate| : (proto = candidate.getPrototype()) {
        if (candidate == object) return core.JSValue.boolean(true);
    }
    return core.JSValue.boolean(false);
}

fn objectPrototypeDefineAccessor(rt: *core.JSRuntime, global: ?*core.Object, receiver: core.JSValue, args: []const core.JSValue, getter: bool) !core.JSValue {
    const receiver_value = try objectStaticToObjectValue(rt, global, receiver);
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

fn objectPrototypeLookupAccessor(rt: *core.JSRuntime, global: ?*core.Object, receiver: core.JSValue, args: []const core.JSValue, getter: bool) !core.JSValue {
    const receiver_value = try objectStaticToObjectValue(rt, global, receiver);
    defer receiver_value.free(rt);
    const object = try expectObjectArg(receiver_value);
    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const key = try atomFromPropertyKey(rt, key_value);
    defer rt.atoms.free(key);
    var cursor: ?*core.Object = object;
    while (cursor) |current| : (cursor = current.getPrototype()) {
        const desc = current.getOwnProperty(key) orelse continue;
        defer desc.destroy(rt);
        if (desc.kind != .accessor) return core.JSValue.undefinedValue();
        return if (getter) desc.getter.dup() else desc.setter.dup();
    }
    return core.JSValue.undefinedValue();
}

fn objectProtoGetter(rt: *core.JSRuntime, global: ?*core.Object, receiver: core.JSValue) !core.JSValue {
    const receiver_value = try objectStaticToObjectValue(rt, global, receiver);
    defer receiver_value.free(rt);
    const object = try expectObjectArg(receiver_value);
    if (object.getPrototype()) |prototype| return prototype.value().dup();
    return core.JSValue.nullValue();
}

fn objectProtoSetter(rt: *core.JSRuntime, receiver: core.JSValue, prototype_value: core.JSValue) !core.JSValue {
    if (receiver.isNull() or receiver.isUndefined()) return error.TypeError;
    const object = thisObject(receiver) orelse return core.JSValue.undefinedValue();
    const prototype: ?*core.Object = if (prototype_value.isNull())
        null
    else
        thisObject(prototype_value) orelse return core.JSValue.undefinedValue();
    object.setPrototype(rt, prototype) catch |err| switch (err) {
        error.PrototypeCycle, error.NotExtensible => return error.TypeError,
        else => return err,
    };
    return core.JSValue.undefinedValue();
}

fn isCallableObjectValue(value: core.JSValue) bool {
    const object = thisObject(value) orelse return false;
    return object.class_id == core.class.ids.c_function or
        object.class_id == core.class.ids.c_closure or
        object.class_id == core.class.ids.bound_function or
        object.class_id == core.class.ids.bytecode_function;
}
fn proxyRevocable(rt: *core.JSRuntime, global: ?*core.Object, args: []const core.JSValue) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit(rt);
    const rooted_args = rooted_args_buffer.values;
    var root_slices = [_]core.runtime.ValueRootSlice{
        rooted_args_buffer.slice(),
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .slices = &root_slices,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    _ = try expectObjectArg(rooted_args[0]);
    _ = try expectObjectArg(rooted_args[1]);

    const object = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &object.header);

    const proxy = try core.Object.create(rt, core.class.ids.object, null);
    var proxy_raw_owned = true;
    errdefer if (proxy_raw_owned) core.Object.destroyFromHeader(rt, &proxy.header);
    proxy.is_proxy = true;
    try proxy.ensureProxyPayload(rt);
    try proxy.setOptionalValueSlot(rt, proxy.proxyTargetSlot(), rooted_args[0].dup());
    try proxy.setOptionalValueSlot(rt, proxy.proxyHandlerSlot(), rooted_args[1].dup());
    try defineObjectProperty(rt, object, "proxy", proxy.value());
    proxy_raw_owned = false;
    proxy.value().free(rt);
    const revoke = try builtins.function.nativeFunction(rt, "revoke", 0);
    defer revoke.free(rt);
    const revoke_object = thisObject(revoke) orelse return error.TypeError;
    const empty_name = try core.string.String.createAscii(rt, "");
    const empty_name_value = empty_name.value();
    defer empty_name_value.free(rt);
    try revoke_object.defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.data(empty_name_value, false, false, true));
    if (functionPrototypeFromGlobal(rt, global)) |function_proto| {
        try revoke_object.setPrototype(rt, function_proto);
    }
    try revoke_object.setOptionalValueSlot(rt, revoke_object.functionProxyRevokeTargetSlot(), proxy.value().dup());
    try defineObjectProperty(rt, object, "revoke", revoke);
    return object.value();
}


fn reflectHas(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    const object = try expectObjectArg(args[0]);
    const key = try property_ops.propertyKeyAtom(ctx.runtime, args[1]);
    defer ctx.runtime.atoms.free(key);
    return core.JSValue.boolean(try reflectHasProperty(ctx, output, global, globals, object, key));
}

fn reflectHasProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    object: *core.Object,
    atom_id: core.Atom,
) HostError!bool {
    if (object.proxyTarget() != null) return proxyReflectHasProperty(ctx, output, global, globals, object, atom_id);
    if (try typedArrayReflectHas(ctx.runtime, object, atom_id)) |has| return has;
    if (object.hasOwnProperty(atom_id)) return true;

    var current = object.getPrototype();
    while (current) |proto| : (current = proto.getPrototype()) {
        if (proto.proxyTarget() != null) return proxyReflectHasProperty(ctx, output, global, globals, proto, atom_id);
        if (try typedArrayReflectHas(ctx.runtime, proto, atom_id)) |has| return has;
        if (proto.hasOwnProperty(atom_id)) return true;
    }
    return false;
}

fn proxyReflectHasProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    proxy: *core.Object,
    atom_id: core.Atom,
) !bool {
    const target_value = proxy.proxyTarget() orelse return error.TypeError;
    const target = try expectObjectArg(target_value);
    const handler_value = proxy.proxyHandler() orelse return error.TypeError;
    const has_atom = try ctx.runtime.internAtom("has");
    defer ctx.runtime.atoms.free(has_atom);
    const trap = try getValueProperty(ctx, output, global, globals, handler_value, has_atom);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) return reflectHasProperty(ctx, output, global, globals, target, atom_id);
    const key_value = try proxyTrapKeyValue(ctx.runtime, atom_id);
    defer key_value.free(ctx.runtime);
    const result = try callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, handler_value, trap, &.{ target_value, key_value });
    defer result.free(ctx.runtime);
    return try validateProxyHasResult(ctx.runtime, target, atom_id, value_ops.isTruthy(result));
}

fn proxyTrapKeyValue(rt: *core.JSRuntime, atom_id: core.Atom) !core.JSValue {
    if ((rt.atoms.kind(atom_id) orelse .string) == .symbol) return core.JSValue.symbol(atom_id);
    return rt.atoms.toStringValue(rt, atom_id);
}

fn validateProxyHasResult(rt: *core.JSRuntime, target: *core.Object, atom_id: core.Atom, result: bool) !bool {
    if (result) return true;
    if (target.getOwnProperty(atom_id)) |desc| {
        defer desc.destroy(rt);
        if (desc.configurable == false) return error.TypeError;
        if (!target.isExtensible()) return error.TypeError;
    }
    return false;
}

fn typedArrayReflectHas(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !?bool {
    switch (try typedArrayCanonicalNumericIndex(rt, atom_id)) {
        .none => return null,
        .invalid => return false,
        .index => |index| {
            const length = builtins.buffer.typedArrayLength(rt, object) catch return false;
            return index < length;
        },
    }
}

const TypedArrayCanonicalIndex = union(enum) {
    none,
    invalid,
    index: u32,
};

fn typedArrayCanonicalNumericIndex(rt: *core.JSRuntime, atom_id: core.Atom) !TypedArrayCanonicalIndex {
    if (core.array.arrayIndexFromAtom(&rt.atoms, atom_id)) |index| return .{ .index = index };
    if ((rt.atoms.kind(atom_id) orelse return .none) != .string) return .none;
    const name = rt.atoms.name(atom_id) orelse return .none;
    if (name.len == 0) return .none;
    if (std.mem.eql(u8, name, "-0")) return .invalid;
    const number: f64 = if (std.mem.eql(u8, name, "NaN"))
        std.math.nan(f64)
    else if (std.mem.eql(u8, name, "Infinity"))
        std.math.inf(f64)
    else if (std.mem.eql(u8, name, "-Infinity"))
        -std.math.inf(f64)
    else
        std.fmt.parseFloat(f64, name) catch return .none;
    var buffer: [64]u8 = undefined;
    const printed = if (std.math.isNan(number))
        "NaN"
    else if (std.math.isPositiveInf(number))
        "Infinity"
    else if (std.math.isNegativeInf(number))
        "-Infinity"
    else
        try value_ops.formatFiniteNumber(&buffer, number);
    if (!std.mem.eql(u8, name, printed)) return .none;
    if (!std.math.isFinite(number) or @trunc(number) != number or number < 0 or number > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return .invalid;
    return .{ .index = @intFromFloat(number) };
}

fn reflectDefineProperty(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    if (args.len < 3) return error.TypeError;
    const object = try expectObjectArg(args[0]);
    const key = try property_ops.propertyKeyAtom(rt, args[1]);
    defer rt.atoms.free(key);
    const desc_object = try expectObjectArg(args[2]);
    const desc = try descriptorFromObject(rt, desc_object);
    defer desc.destroy(rt);
    if (builtins.buffer.isTypedArrayObject(object)) {
        if (try typedArrayReflectDefineOwnProperty(rt, object, key, desc)) |ok| return core.JSValue.boolean(ok);
    }
    object.defineOwnProperty(rt, key, desc) catch |err| switch (err) {
        error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return core.JSValue.boolean(false),
        error.InvalidLength => return error.RangeError,
        else => return err,
    };
    return core.JSValue.boolean(true);
}

fn typedArrayReflectDefineOwnProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, desc: core.Descriptor) !?bool {
    return try builtins.buffer.typedArrayDefineOwnProperty(rt, object, atom_id, desc);
}

fn reflectGet(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    const object = try expectObjectArg(args[0]);
    const key = try property_ops.propertyKeyAtom(rt, args[1]);
    defer rt.atoms.free(key);
    return object.getProperty(key);
}

fn reflectSet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (global) |global_object| {
        if (try shared_vm.qjsReflectSetCall(ctx, output, global_object, args, null, null)) |value| {
            return value;
        }
    }
    if (args.len < 1) return error.TypeError;
    const set_value = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const object = try expectObjectArg(args[0]);
    const key_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const key = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
    defer ctx.runtime.atoms.free(key);
    object.setProperty(ctx.runtime, key, set_value) catch |err| switch (err) {
        error.ReadOnly, error.AccessorWithoutSetter, error.NotExtensible, error.IncompatibleDescriptor => return core.JSValue.boolean(false),
        error.InvalidLength => return error.RangeError,
        else => return err,
    };
    return core.JSValue.boolean(true);
}

fn arrayMapCallback(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue, globals: []globals_mod.Slot) !core.JSValue {
    if (args.len != 1) return error.TypeError;
    var rooted_receiver = receiver;
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit(rt);
    const rooted_args = rooted_args_buffer.values;
    var mapped_root = core.JSValue.undefinedValue();
    var mapped_value_root = core.JSValue.undefinedValue();
    var callback_arg_buf = [_]core.JSValue{core.JSValue.undefinedValue()};
    var callback_args: []core.JSValue = callback_arg_buf[0..];
    var root_slices = [_]core.runtime.ValueRootSlice{
        rooted_args_buffer.slice(),
        .{ .mutable = &callback_args },
    };
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_receiver },
        .{ .value = &mapped_root },
        .{ .value = &mapped_value_root },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .slices = &root_slices,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const array = builtins.array.expectArray(rooted_receiver) catch return error.TypeError;
    const mapped = try core.Object.createArray(rt, null);
    mapped_root = mapped.value();
    errdefer {
        const failed_mapped = mapped_root;
        mapped_root = core.JSValue.undefinedValue();
        failed_mapped.free(rt);
    }
    var index: u32 = 0;
    while (index < array.length) : (index += 1) {
        const item = array.getProperty(core.atom.atomFromUInt32(index));
        callback_args[0] = item;
        var item_owned = true;
        errdefer if (item_owned) {
            callback_args[0] = core.JSValue.undefinedValue();
            item.free(rt);
        };
        const mapped_value = closure_mod.call(rt, rooted_args[0], callback_args, globals) catch {
            callback_args[0] = core.JSValue.undefinedValue();
            item.free(rt);
            item_owned = false;
            return error.TypeError;
        };
        callback_args[0] = core.JSValue.undefinedValue();
        item.free(rt);
        item_owned = false;
        mapped_value_root = mapped_value;
        var mapped_value_owned = true;
        errdefer if (mapped_value_owned) {
            mapped_value_root = core.JSValue.undefinedValue();
            mapped_value.free(rt);
        };
        try mapped.defineOwnProperty(rt, core.atom.atomFromUInt32(index), core.Descriptor.data(mapped_value, true, true, true));
        mapped_value_root = core.JSValue.undefinedValue();
        mapped_value.free(rt);
        mapped_value_owned = false;
    }
    return mapped_root;
}

fn arrayJoinCall(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    if (args.len > 1) return error.TypeError;
    if (args.len == 1) return builtins.array.join(rt, receiver, args[0]) catch return error.TypeError;
    const comma = try core.string.String.createUtf8(rt, ",");
    const comma_value = comma.value();
    defer comma_value.free(rt);
    return builtins.array.join(rt, receiver, comma_value) catch return error.TypeError;
}

fn arrayFrom(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    if (args.len < 1) return error.TypeError;
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit(rt);
    const rooted_args = rooted_args_buffer.values;
    var out_root = core.JSValue.undefinedValue();
    var next_root = core.JSValue.undefinedValue();
    var value_root = core.JSValue.undefinedValue();
    var root_slices = [_]core.runtime.ValueRootSlice{
        rooted_args_buffer.slice(),
    };
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &out_root },
        .{ .value = &next_root },
        .{ .value = &value_root },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .slices = &root_slices,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const source = try expectObjectArg(rooted_args[0]);
    if (source.class_id == core.class.ids.set or source.class_id == core.class.ids.map) {
        const iterator = try builtins.collection.methodCall(rt, source.value(), if (source.class_id == core.class.ids.set) 8 else 9, &.{});
        defer iterator.free(rt);
        const iterator_args = [_]core.JSValue{iterator};
        return arrayFrom(rt, &iterator_args);
    }
    if (source.class_id == core.class.ids.map_iterator or source.class_id == core.class.ids.set_iterator) {
        const out = try core.Object.createArray(rt, null);
        out_root = out.value();
        errdefer {
            const failed_out = out_root;
            out_root = core.JSValue.undefinedValue();
            failed_out.free(rt);
        }
        while (true) {
            const next = try builtins.collection.methodCall(rt, source.value(), 13, &.{});
            next_root = next;
            var next_owned = true;
            errdefer if (next_owned) {
                next_root = core.JSValue.undefinedValue();
                next.free(rt);
            };
            const next_object = try expectObjectArg(next);
            const done = next_object.getProperty(core.atom.predefinedId("done", .string).?);
            const is_done = done.asBool() == true;
            done.free(rt);
            if (is_done) {
                next_root = core.JSValue.undefinedValue();
                next.free(rt);
                next_owned = false;
                break;
            }
            const value = next_object.getProperty(core.atom.predefinedId("value", .string).?);
            value_root = value;
            var value_owned = true;
            errdefer if (value_owned) {
                value_root = core.JSValue.undefinedValue();
                value.free(rt);
            };
            try out.defineOwnProperty(rt, core.atom.atomFromUInt32(out.length), core.Descriptor.data(value, true, true, true));
            value_root = core.JSValue.undefinedValue();
            value.free(rt);
            value_owned = false;
            next_root = core.JSValue.undefinedValue();
            next.free(rt);
            next_owned = false;
        }
        return out_root;
    }
    if (!source.is_array) return error.TypeError;
    return source.value().dup();
}

fn typedArrayStaticFrom(rt: *core.JSRuntime, this_value: core.JSValue, args: []const core.JSValue) !?core.JSValue {
    const ctor = thisObject(this_value) orelse return null;
    if (ctor.typedArrayElementSize() == 0 or ctor.typedArrayKind() == 0) return null;
    const source_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const source = thisObject(source_value) orelse return try typedArrayConstructFromValues(rt, ctor, &.{});
    const length: u32 = if (source.is_array) source.length else blk: {
        const length_value = source.getProperty(core.atom.ids.length);
        defer length_value.free(rt);
        const length_i32 = length_value.asInt32() orelse 0;
        if (length_i32 < 0) return error.RangeError;
        break :blk @intCast(length_i32);
    };
    var values = try rt.memory.alloc(core.JSValue, length);
    errdefer rt.memory.free(core.JSValue, values);
    var rooted_values: []core.JSValue = values[0..0];
    var values_root = ValueSliceRoot{};
    values_root.init(rt, &rooted_values);
    defer values_root.deinit();
    var initialized: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) values[i].free(rt);
    }
    while (initialized < length) : (initialized += 1) {
        values[initialized] = source.getProperty(core.atom.atomFromUInt32(@intCast(initialized)));
        rooted_values = values[0 .. initialized + 1];
    }
    const out = try typedArrayConstructFromValues(rt, ctor, values);
    for (values) |*value| {
        value.free(rt);
        value.* = core.JSValue.undefinedValue();
    }
    rooted_values = &.{};
    rt.memory.free(core.JSValue, values);
    return out;
}

test "typedArrayStaticFrom roots collected values while reading array-like source" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctor_value = try builtins.function.nativeFunction(rt, "Int8Array", 3);
    defer ctor_value.free(rt);
    const ctor = thisObject(ctor_value) orelse return error.TypeError;
    ctor.typedArrayElementSizeSlot().* = 1;
    ctor.typedArrayKindSlot().* = 1;

    const source = try core.Object.create(rt, core.class.ids.object, null);
    var source_alive = true;
    defer if (source_alive) source.value().free(rt);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-typed-array-static-from-prefix-root");
    try source.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(core.JSValue.symbol(symbol_atom), true, true, true));
    try source.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(2), true, false, true));
    try source.defineAutoInitProperty(rt, core.atom.atomFromUInt32(1), "lazyTypedArrayFromValue", 0, core.property.Flags.data(true, true, true));

    const saved_trigger_fn = rt.memory.trigger_gc_fn;
    const saved_trigger_ctx = rt.memory.trigger_gc_ctx;
    var probe = ActiveRootSymbolProbe{
        .rt = rt,
        .atom_id = symbol_atom,
    };
    rt.memory.trigger_gc_fn = ActiveRootSymbolProbe.trigger;
    rt.memory.trigger_gc_ctx = &probe;
    defer {
        rt.memory.trigger_gc_fn = saved_trigger_fn;
        rt.memory.trigger_gc_ctx = saved_trigger_ctx;
    }

    const from_args = [_]core.JSValue{source.value()};
    try std.testing.expectError(error.TypeError, typedArrayStaticFrom(rt, ctor_value, &from_args));
    try std.testing.expect(!probe.trace_failed);
    try std.testing.expect(probe.saw_symbol);

    source.value().free(rt);
    source_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn typedArrayStaticOf(rt: *core.JSRuntime, this_value: core.JSValue, args: []const core.JSValue) !?core.JSValue {
    const ctor = thisObject(this_value) orelse return null;
    if (ctor.typedArrayElementSize() == 0 or ctor.typedArrayKind() == 0) return null;
    return try typedArrayConstructFromValues(rt, ctor, args);
}

fn typedArrayConstructFromValues(rt: *core.JSRuntime, ctor: *core.Object, values: []const core.JSValue) !core.JSValue {
    var rooted_values_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, values);
    defer rooted_values_buffer.deinit(rt);
    const rooted_values = rooted_values_buffer.values;
    var root_slices = [_]core.runtime.ValueRootSlice{
        rooted_values_buffer.slice(),
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .slices = &root_slices,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    if (rooted_values.len > std.math.maxInt(u32)) return error.RangeError;
    const byte_length = try std.math.mul(u32, @intCast(rooted_values.len), ctor.typedArrayElementSize());
    const backing_buffer = try builtins.buffer.arrayBufferConstruct(rt, core.JSValue.int32(@intCast(byte_length)));
    defer backing_buffer.free(rt);
    const object_value = try builtins.buffer.typedArrayConstructWithOptions(
        rt,
        ctor.typedArrayElementSize(),
        ctor.typedArrayKind(),
        backing_buffer,
        &.{backing_buffer},
        constructorPrototype(rt, ctor),
    );
    errdefer object_value.free(rt);
    const object = try expectObjectArg(object_value);
    for (rooted_values, 0..) |value, index| {
        _ = try builtins.buffer.typedArraySetIndex(rt, object, @intCast(index), value);
    }
    return object_value;
}

test "typedArrayConstructFromValues roots direct symbol values while creating backing buffer" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctor_value = try builtins.function.nativeFunction(rt, "Int8Array", 3);
    defer ctor_value.free(rt);
    const ctor = thisObject(ctor_value) orelse return error.TypeError;
    ctor.typedArrayElementSizeSlot().* = 1;
    ctor.typedArrayKindSlot().* = 1;

    const symbol_atom = try rt.atoms.newValueSymbol("gc-typed-array-construct-values-symbol");
    const values = [_]core.JSValue{
        core.JSValue.symbol(symbol_atom),
    };

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try std.testing.expectError(error.TypeError, typedArrayConstructFromValues(rt, ctor, &values));
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn callStringMethod(rt: *core.JSRuntime, receiver: core.JSValue, name: []const u8, args: []const core.JSValue) !core.JSValue {
    if (std.mem.eql(u8, name, "valueOf")) {
        if (receiver.isObject()) {
            const header = receiver.refHeader() orelse return error.TypeError;
            const object: *core.Object = @fieldParentPtr("header", header);
            if (object.class_id == core.class.ids.string) {
                return (object.objectData() orelse return error.TypeError).dup();
            }
        }
        if (receiver.isString()) return receiver.dup();
        return error.TypeError;
    }
    if (std.mem.eql(u8, name, "charAt")) {
        const index = if (args.len >= 1) args[0] else core.JSValue.int32(0);
        return builtins.string.charAtValue(rt, receiver, index) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            else => err,
        };
    }
    if (std.mem.eql(u8, name, "[Symbol.iterator]")) {
        return builtins.string.iterator(rt, receiver) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            else => err,
        };
    }
    if (stringMethodId(name)) |method| {
        return builtins.string.methodCall(rt, receiver, method, args) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            else => err,
        };
    }
    return error.TypeError;
}

fn callPrimitiveMethod(rt: *core.JSRuntime, receiver: core.JSValue, name: []const u8, args: []const core.JSValue) !core.JSValue {
    if (receiver.isNumber() and std.mem.eql(u8, name, "toFixed")) return builtins.number.toFixed(rt, receiver, args);
    if (receiver.isNumber() and std.mem.eql(u8, name, "toExponential")) return builtins.number.toExponential(rt, receiver, args);
    if (receiver.isNumber() and std.mem.eql(u8, name, "toPrecision")) return builtins.number.toPrecision(rt, receiver, args);
    if (receiver.isNumber() and std.mem.eql(u8, name, "toString")) return builtins.number.toStringMethod(rt, receiver, args);
    if (receiver.isSymbol() and std.mem.eql(u8, name, "[Symbol.toPrimitive]")) return receiver.dup();
    if (std.mem.eql(u8, name, "valueOf")) return receiver.dup();
    if (args.len != 0) return error.TypeError;
    if (std.mem.eql(u8, name, "toString")) return value_ops.toStringValue(rt, receiver);
    return error.TypeError;
}

fn numberIsInteger(value: core.JSValue) bool {
    const number = value_ops.numberValue(value) orelse return false;
    return std.math.isFinite(number) and @floor(number) == number;
}

fn primitiveWrapper(rt: *core.JSRuntime, class_id: core.class.ClassId, primitive: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    if (class_id == core.class.ids.string) return builtins.string.constructWithPrototype(rt, &.{primitive}, prototype);
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

    const symbol_atom = try rt.atoms.newValueSymbol("gc-call-wrapper-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const wrapper_value = try primitiveWrapper(rt, core.class.ids.symbol, core.JSValue.symbol(symbol_atom), null);
    var wrapper_alive = true;
    defer if (wrapper_alive) wrapper_value.free(rt);
    const wrapper = property_ops.expectObject(wrapper_value) catch return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = wrapper.objectData() orelse return error.TypeError;
    try std.testing.expect(stored.same(core.JSValue.symbol(symbol_atom)));

    wrapper_value.free(rt);
    wrapper_alive = false;
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

fn boundFunctionTargetObject(object: *core.Object) ?*core.Object {
    const target = object.boundTarget() orelse return null;
    return thisObject(target);
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
    if (target_object.functionRealmGlobal()) |realm_value| try object.setOptionalValueSlot(rt, object.functionRealmGlobalSlot(), realm_value.dup());
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
        try object.writeValueSliceBarrier(rt, rooted_owned_bound_args);
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
    const target = try builtins.function.nativeFunction(rt, "target", 0);
    defer target.free(rt);

    const this_atom = try rt.atoms.newValueSymbol("gc-bound-this-symbol");
    const arg_atom = try rt.atoms.newValueSymbol("gc-bound-arg-symbol");
    const bound_args = [_]core.JSValue{core.JSValue.symbol(arg_atom)};
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
        core.JSValue.symbol(this_atom),
        &bound_args,
    );
    var bound_alive = true;
    defer if (bound_alive) bound_value.free(rt);
    const bound = thisObject(bound_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(this_atom) != null);
    try std.testing.expect(rt.atoms.name(arg_atom) != null);
    try std.testing.expect(bound.boundThis().?.same(core.JSValue.symbol(this_atom)));
    try std.testing.expectEqual(@as(usize, 1), bound.boundArgs().len);
    try std.testing.expect(bound.boundArgs()[0].same(core.JSValue.symbol(arg_atom)));

    bound_value.free(rt);
    bound_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(this_atom) == null);
    try std.testing.expect(rt.atoms.name(arg_atom) == null);
}

test "callValueWithThisGlobalsAndGlobal roots inline args before bound argument merge" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const target = try builtins.function.nativeFunction(rt, "get [Symbol.species]", 0);
    defer target.free(rt);

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
    const args = [_]core.JSValue{core.JSValue.symbol(arg_atom)};

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
            var visitor = core.runtime.RootVisitor{
                .context = self,
                .visit_value = @This().visitValue,
                .visit_object = @This().visitObject,
            };
            self.rt.traceActiveRoots(&visitor) catch {
                self.trace_failed = true;
            };
        }

        fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (slot.asSymbolAtom()) |atom_id| {
                if (atom_id == self.atom_id) self.saw_arg = true;
            }
        }

        fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void {
            _ = context;
            _ = slot;
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
    const combined = try boundFunctionArgs(ctx.runtime, object, args);
    defer freeBoundArgs(ctx.runtime, combined);
    return callValueWithThisGlobalsAndGlobal(ctx, output, global, globals, bound_this, target, combined);
}

fn freeBoundArgs(rt: *core.JSRuntime, args: []core.JSValue) void {
    for (args) |arg| arg.free(rt);
    if (args.len != 0) rt.memory.free(core.JSValue, args);
}

fn boundFunctionArgs(rt: *core.JSRuntime, object: *core.Object, args: []const core.JSValue) ![]core.JSValue {
    const bound_args = object.boundArgs();
    const bound_count = bound_args.len;
    if (bound_count == 0 and args.len == 0) return &.{};
    const combined = try rt.memory.alloc(core.JSValue, bound_count + args.len);
    errdefer rt.memory.free(core.JSValue, combined);
    var filled: usize = 0;
    errdefer {
        var index: usize = 0;
        while (index < filled) : (index += 1) combined[index].free(rt);
    }
    for (bound_args, 0..) |arg, index| {
        combined[index] = arg.dup();
        filled += 1;
    }
    for (args, 0..) |arg, arg_index| {
        combined[bound_count + arg_index] = arg.dup();
        filled += 1;
    }
    return combined;
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

fn errorToString(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue {
    const object = try expectObjectArg(receiver);
    const name_value = object.getProperty(core.atom.ids.name);
    defer name_value.free(rt);
    var name_string = if (name_value.isUndefined())
        try value_ops.createStringValue(rt, "Error")
    else
        try value_ops.toStringValue(rt, name_value);
    defer name_string.free(rt);

    const message_atom = core.atom.predefinedId("message", .string).?;
    const message_value = object.getProperty(message_atom);
    defer message_value.free(rt);
    var message_string = if (message_value.isUndefined())
        try value_ops.createStringValue(rt, "")
    else
        try value_ops.toStringValue(rt, message_value);
    defer message_string.free(rt);

    var name_bytes = std.ArrayList(u8).empty;
    defer name_bytes.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &name_bytes, name_string);
    var message_bytes = std.ArrayList(u8).empty;
    defer message_bytes.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &message_bytes, message_string);

    if (name_bytes.items.len == 0) return value_ops.createStringValue(rt, message_bytes.items);
    if (message_bytes.items.len == 0) return value_ops.createStringValue(rt, name_bytes.items);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(rt.memory.allocator);
    try out.appendSlice(rt.memory.allocator, name_bytes.items);
    try out.appendSlice(rt.memory.allocator, ": ");
    try out.appendSlice(rt.memory.allocator, message_bytes.items);
    return value_ops.createStringValue(rt, out.items);
}

fn errorIsError(args: []const core.JSValue) core.JSValue {
    if (args.len < 1) return core.JSValue.boolean(false);
    const object = thisObject(args[0]) orelse return core.JSValue.boolean(false);
    return core.JSValue.boolean(object.class_id == core.class.ids.error_);
}

fn finalizationRegistryRegister(rt: *core.JSRuntime, receiver: *core.Object, args: []const core.JSValue) !core.JSValue {
    const target = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const held_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const unregister_token = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    if (!canBeHeldWeakly(rt, target)) return error.TypeError;
    if (builtins.object.sameValue(target, held_value)) return error.TypeError;
    if (!unregister_token.isUndefined() and !canBeHeldWeakly(rt, unregister_token)) return error.TypeError;
    if (builtins.object.sameValue(target, receiver.value())) return core.JSValue.undefinedValue();
    try finalizationRegistryAppendCell(rt, receiver, target, held_value, unregister_token);
    return core.JSValue.undefinedValue();
}

fn finalizationRegistryUnregister(rt: *core.JSRuntime, receiver: *core.Object, args: []const core.JSValue) !core.JSValue {
    const token = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (!canBeHeldWeakly(rt, token)) return error.TypeError;
    return core.JSValue.boolean(receiver.unregisterFinalizationRegistryCells(rt, token));
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

fn canBeHeldWeakly(rt: *core.JSRuntime, value: core.JSValue) bool {
    if (value.isObject()) return true;
    if (value.asSymbolAtom()) |atom_id| {
        return rt.atoms.kind(atom_id) == .symbol and builtins.symbol.registryKey(&rt.atoms, atom_id) == null;
    }
    return false;
}

fn objectHasOwnProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    receiver: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    const rt = ctx.runtime;
    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const key = try atomFromPropertyKey(rt, key_value);
    defer rt.atoms.free(key);
    const desc = if (global) |global_object|
        try shared_vm.proxyAwareOwnPropertyDescriptor(ctx, output, global_object, receiver, key, null, null)
    else
        receiver.getOwnProperty(key);
    if (desc) |own_desc| {
        own_desc.destroy(rt);
        return core.JSValue.boolean(true);
    }
    return core.JSValue.boolean(false);
}

fn objectPropertyIsEnumerable(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    receiver: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    const rt = ctx.runtime;
    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const key = try atomFromPropertyKey(rt, key_value);
    defer rt.atoms.free(key);
    const desc = if (global) |global_object|
        try shared_vm.proxyAwareOwnPropertyDescriptor(ctx, output, global_object, receiver, key, null, null)
    else
        receiver.getOwnProperty(key);
    if (desc) |own_desc| {
        defer own_desc.destroy(rt);
        return core.JSValue.boolean(own_desc.enumerable orelse false);
    }
    return core.JSValue.boolean(false);
}

fn symbolFor(ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, args: []const core.JSValue) !core.JSValue {
    const rt = ctx.runtime;
    const key = if (args.len >= 1)
        try toStringBytesForSymbol(ctx, output, global, args[0])
    else
        try rt.memory.allocator.dupe(u8, "undefined");
    defer rt.memory.allocator.free(key);
    const registered = try std.fmt.allocPrint(rt.memory.allocator, "{s}{s}", .{ builtins.symbol.registry_prefix, key });
    defer rt.memory.allocator.free(registered);
    const atom_id = try rt.atoms.internRegisteredValueSymbol(registered);
    return core.JSValue.symbol(atom_id);
}

fn toStringBytesForSymbol(ctx: *core.JSContext, output: ?*std.Io.Writer, global: ?*core.Object, value: core.JSValue) ![]u8 {
    if (value.isSymbol()) return error.TypeError;
    const global_object = global orelse return stringBytes(ctx.runtime, value);
    const string_value = try shared_vm.toStringForAnnexB(ctx, output, global_object, value, null, null);
    defer string_value.free(ctx.runtime);
    return stringBytes(ctx.runtime, string_value);
}

fn symbolKeyFor(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const atom_id = value.asSymbolAtom() orelse return error.TypeError;
    const key = builtins.symbol.registryKey(&rt.atoms, atom_id) orelse return core.JSValue.undefinedValue();
    return value_ops.createStringValue(rt, key);
}

fn symbolDescription(rt: *core.JSRuntime, this_value: core.JSValue) !core.JSValue {
    const primitive = try symbolPrimitiveValue(rt, this_value);
    defer primitive.free(rt);
    const atom_id = primitive.asSymbolAtom() orelse return error.TypeError;
    const desc = builtins.symbol.description(&rt.atoms, atom_id) orelse return core.JSValue.undefinedValue();
    return value_ops.createStringValue(rt, desc);
}

fn symbolPrimitiveValue(rt: *core.JSRuntime, this_value: core.JSValue) !core.JSValue {
    if (this_value.isSymbol()) return this_value.dup();
    if (!this_value.isObject()) return error.TypeError;
    const object = try expectObjectArg(this_value);
    if (object.class_id != core.class.ids.symbol) return error.TypeError;
    const primitive = (object.objectData() orelse return error.TypeError).dup();
    if (!primitive.isSymbol()) {
        primitive.free(rt);
        return error.TypeError;
    }
    return primitive;
}

fn defaultObjectTag(object: *core.Object) []const u8 {
    if (object.is_array) return "[object Array]";
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

fn nativeFunctionName(rt: *core.JSRuntime, function_object: *core.Object) ![]u8 {
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
    if (object.is_proxy) {
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
        if (object.functionSourceSlot().*) |source| return source.dup();
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
/// in tight test262 loops; avoiding the per-call `ArrayList(u8)` alloc and
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
    const header = value.refHeader() orelse return null;
    if (!value.isString()) return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
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
    if (prefer_dispatch_name) {
        const dispatch_atom = function_object.nativeDispatchName();
        if (dispatch_atom != core.atom.null_atom) {
            const dispatch_name = try rt.atoms.toStringValue(rt, dispatch_atom);
            if (dispatch_name.isString()) return dispatch_name;
            dispatch_name.free(rt);
        }
    }
    const name_value = function_object.getProperty(core.atom.ids.name);
    if (!name_value.isString()) {
        name_value.free(rt);
        return error.TypeError;
    }
    return name_value;
}

fn functionBytecodeFromValue(value: core.JSValue) ?*const function_bytecode.FunctionBytecode {
    const header = value.objectHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn functionBytecodeToStringValue(
    rt: *core.JSRuntime,
    bytecode: *const function_bytecode.FunctionBytecode,
    object: ?*core.Object,
) !core.JSValue {
    if (bytecode.source) |source| return value_ops.createStringValue(rt, source);
    if (object) |function_object| {
        if (function_object.functionSourceSlot().*) |source| return source.dup();
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
    return shared_vm.isSimpleIdentifierName(name) or isNativeFunctionComputedPropertyName(name);
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
    if (!object.is_proxy or object.proxyHandler() == null) return false;
    const target = object.proxyTarget() orelse return false;
    return isFunctionToStringCallable(target);
}

fn collectionMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "set")) return 1;
    if (std.mem.eql(u8, name, "get")) return 2;
    if (std.mem.eql(u8, name, "has")) return 3;
    if (std.mem.eql(u8, name, "delete")) return 4;
    if (std.mem.eql(u8, name, "clear")) return 5;
    if (std.mem.eql(u8, name, "add")) return 6;
    if (std.mem.eql(u8, name, "keys")) return 7;
    if (std.mem.eql(u8, name, "values")) return 8;
    if (std.mem.eql(u8, name, "entries")) return 9;
    if (std.mem.eql(u8, name, "forEach")) return 10;
    if (std.mem.eql(u8, name, "getOrInsert")) return 11;
    if (std.mem.eql(u8, name, "getOrInsertComputed")) return 12;
    if (std.mem.eql(u8, name, "difference")) return 15;
    if (std.mem.eql(u8, name, "intersection")) return 16;
    if (std.mem.eql(u8, name, "isDisjointFrom")) return 17;
    if (std.mem.eql(u8, name, "isSubsetOf")) return 18;
    if (std.mem.eql(u8, name, "isSupersetOf")) return 19;
    if (std.mem.eql(u8, name, "symmetricDifference")) return 20;
    if (std.mem.eql(u8, name, "union")) return 21;
    return null;
}

fn arrayMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "filter")) return 1;
    if (std.mem.eql(u8, name, "reduce")) return 2;
    if (std.mem.eql(u8, name, "some")) return 4;
    if (std.mem.eql(u8, name, "every")) return 5;
    if (std.mem.eql(u8, name, "indexOf")) return 6;
    if (std.mem.eql(u8, name, "includes")) return 7;
    if (std.mem.eql(u8, name, "lastIndexOf")) return 8;
    if (std.mem.eql(u8, name, "at")) return 9;
    if (std.mem.eql(u8, name, "slice")) return 10;
    if (std.mem.eql(u8, name, "splice")) return 11;
    if (std.mem.eql(u8, name, "reverse")) return 12;
    if (std.mem.eql(u8, name, "push")) return 13;
    if (std.mem.eql(u8, name, "pop")) return 14;
    if (std.mem.eql(u8, name, "concat")) return 15;
    if (std.mem.eql(u8, name, "sort")) return 16;
    if (std.mem.eql(u8, name, "values")) return 17;
    if (std.mem.eql(u8, name, "keys")) return 18;
    if (std.mem.eql(u8, name, "entries")) return 19;
    return null;
}

fn stringMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "substring")) return 1;
    if (std.mem.eql(u8, name, "toUpperCase")) return 2;
    if (std.mem.eql(u8, name, "toLocaleUpperCase")) return 2;
    if (std.mem.eql(u8, name, "toLowerCase")) return 3;
    if (std.mem.eql(u8, name, "toLocaleLowerCase")) return 3;
    if (std.mem.eql(u8, name, "indexOf")) return 4;
    if (std.mem.eql(u8, name, "lastIndexOf")) return 28;
    if (std.mem.eql(u8, name, "includes")) return 5;
    if (std.mem.eql(u8, name, "startsWith")) return 6;
    if (std.mem.eql(u8, name, "endsWith")) return 7;
    if (std.mem.eql(u8, name, "localeCompare")) return 36;
    if (std.mem.eql(u8, name, "repeat")) return 33;
    if (std.mem.eql(u8, name, "padStart")) return 34;
    if (std.mem.eql(u8, name, "padEnd")) return 35;
    if (std.mem.eql(u8, name, "normalize")) return 37;
    if (std.mem.eql(u8, name, "isWellFormed")) return 38;
    if (std.mem.eql(u8, name, "toWellFormed")) return 39;
    if (std.mem.eql(u8, name, "trim")) return 8;
    if (std.mem.eql(u8, name, "trimLeft")) return 21;
    if (std.mem.eql(u8, name, "trimStart")) return 21;
    if (std.mem.eql(u8, name, "trimRight")) return 22;
    if (std.mem.eql(u8, name, "trimEnd")) return 22;
    if (std.mem.eql(u8, name, "toString")) return 9;
    if (std.mem.eql(u8, name, "concat")) return 10;
    if (std.mem.eql(u8, name, "anchor")) return 11;
    if (std.mem.eql(u8, name, "big")) return 12;
    if (std.mem.eql(u8, name, "blink")) return 13;
    if (std.mem.eql(u8, name, "bold")) return 14;
    if (std.mem.eql(u8, name, "fixed")) return 15;
    if (std.mem.eql(u8, name, "fontcolor")) return 16;
    if (std.mem.eql(u8, name, "fontsize")) return 17;
    if (std.mem.eql(u8, name, "italics")) return 18;
    if (std.mem.eql(u8, name, "link")) return 19;
    if (std.mem.eql(u8, name, "small")) return 20;
    if (std.mem.eql(u8, name, "strike")) return 23;
    if (std.mem.eql(u8, name, "sub")) return 24;
    if (std.mem.eql(u8, name, "substr")) return 25;
    if (std.mem.eql(u8, name, "sup")) return 26;
    if (std.mem.eql(u8, name, "split")) return 27;
    if (std.mem.eql(u8, name, "charCodeAt")) return 29;
    if (std.mem.eql(u8, name, "at")) return 30;
    if (std.mem.eql(u8, name, "codePointAt")) return 31;
    if (std.mem.eql(u8, name, "slice")) return 32;
    if (std.mem.eql(u8, name, "search")) return 40;
    if (std.mem.eql(u8, name, "match")) return 41;
    if (std.mem.eql(u8, name, "replaceAll")) return 42;
    return null;
}

fn regexpAccessorName(name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, "get ")) return null;
    const accessor = name["get ".len..];
    if (std.mem.eql(u8, accessor, "source") or
        std.mem.eql(u8, accessor, "flags") or
        std.mem.eql(u8, accessor, "global") or
        std.mem.eql(u8, accessor, "ignoreCase") or
        std.mem.eql(u8, accessor, "multiline") or
        std.mem.eql(u8, accessor, "dotAll") or
        std.mem.eql(u8, accessor, "unicode") or
        std.mem.eql(u8, accessor, "sticky") or
        std.mem.eql(u8, accessor, "hasIndices") or
        std.mem.eql(u8, accessor, "unicodeSets")) return accessor;
    return null;
}

fn dateStaticId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "UTC")) return 1;
    if (std.mem.eql(u8, name, "parse")) return 2;
    if (std.mem.eql(u8, name, "now")) return 3;
    return null;
}

fn uriCallId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "encodeURI")) return 1;
    if (std.mem.eql(u8, name, "encodeURIComponent")) return 2;
    if (std.mem.eql(u8, name, "decodeURI")) return 3;
    if (std.mem.eql(u8, name, "decodeURIComponent")) return 4;
    return null;
}

fn regexpMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "toString")) return 1;
    if (std.mem.eql(u8, name, "test")) return 2;
    if (std.mem.eql(u8, name, "exec")) return 3;
    return null;
}

fn regexpNativePrototypeMethodId(function_object: *core.Object) ?u32 {
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*) orelse return null;
    if (native_ref.domain != .regexp) return null;
    return builtins.regexp.decodePrototypeMethodId(native_ref.id);
}

fn promiseStaticId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "resolve")) return 1;
    if (std.mem.eql(u8, name, "all")) return 2;
    if (std.mem.eql(u8, name, "race")) return 3;
    if (std.mem.eql(u8, name, "reject")) return 4;
    if (std.mem.eql(u8, name, "allSettled")) return 5;
    if (std.mem.eql(u8, name, "any")) return 6;
    if (std.mem.eql(u8, name, "try")) return 7;
    if (std.mem.eql(u8, name, "withResolvers")) return 8;
    return null;
}

fn bigIntStaticUnsigned(name: []const u8) ?bool {
    if (std.mem.eql(u8, name, "asIntN")) return false;
    if (std.mem.eql(u8, name, "asUintN")) return true;
    return null;
}

fn dataViewGetId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "getInt8")) return 1;
    if (std.mem.eql(u8, name, "getUint8")) return 2;
    if (std.mem.eql(u8, name, "getInt16")) return 3;
    if (std.mem.eql(u8, name, "getUint16")) return 4;
    if (std.mem.eql(u8, name, "getInt32")) return 5;
    if (std.mem.eql(u8, name, "getUint32")) return 6;
    if (std.mem.eql(u8, name, "getFloat16")) return 11;
    if (std.mem.eql(u8, name, "getFloat32")) return 7;
    if (std.mem.eql(u8, name, "getFloat64")) return 8;
    if (std.mem.eql(u8, name, "getBigInt64")) return 9;
    if (std.mem.eql(u8, name, "getBigUint64")) return 10;
    return null;
}

fn dataViewSetId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "setInt8")) return 1;
    if (std.mem.eql(u8, name, "setUint8")) return 2;
    if (std.mem.eql(u8, name, "setInt16")) return 3;
    if (std.mem.eql(u8, name, "setUint16")) return 4;
    if (std.mem.eql(u8, name, "setInt32")) return 5;
    if (std.mem.eql(u8, name, "setUint32")) return 6;
    if (std.mem.eql(u8, name, "setFloat16")) return 11;
    if (std.mem.eql(u8, name, "setFloat32")) return 7;
    if (std.mem.eql(u8, name, "setFloat64")) return 8;
    if (std.mem.eql(u8, name, "setBigInt64")) return 9;
    if (std.mem.eql(u8, name, "setBigUint64")) return 10;
    return null;
}

fn collectionConstructorId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "Map")) return 1;
    if (std.mem.eql(u8, name, "Set")) return 2;
    if (std.mem.eql(u8, name, "WeakMap")) return 3;
    if (std.mem.eql(u8, name, "WeakSet")) return 4;
    return null;
}

fn thisObject(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn constructorNameEql(rt: *core.JSRuntime, object: *core.Object, expected: []const u8) !bool {
    const name_value = nativeFunctionNameValue(rt, object, true) catch return false;
    defer name_value.free(rt);
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &buffer, name_value);
    return std.mem.eql(u8, buffer.items, expected);
}

fn constructorPrototype(rt: *core.JSRuntime, object: *core.Object) ?*core.Object {
    const prototype_value = object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    if (!prototype_value.isObject()) return null;
    const header = prototype_value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn revokeProxy(rt: *core.JSRuntime, function_object: *core.Object) !core.JSValue {
    const proxy_slot = function_object.functionProxyRevokeTargetSlot();
    const proxy_value = function_object.takeOptionalValueSlot(proxy_slot) orelse return core.JSValue.undefinedValue();
    defer proxy_value.free(rt);
    const proxy = thisObject(proxy_value) orelse return core.JSValue.undefinedValue();
    proxy.clearOptionalValueSlot(rt, proxy.proxyHandlerSlot());
    return core.JSValue.undefinedValue();
}

fn expectArray(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (!object.is_array) return error.TypeError;
    return object;
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

fn hostCallOutput(call: HostCall) HostError!core.JSValue {
    return hostOutputValues(call.ctx.runtime, call.output, call.args);
}

fn hostCallStdLoadFile(call: HostCall) HostError!core.JSValue {
    const path = try hostStringArg(call.ctx.runtime, call.args, 0);
    defer call.ctx.runtime.memory.allocator.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(hostIo(), path, call.ctx.runtime.memory.allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return core.JSValue.nullValue(),
        else => |e| return e,
    };
    defer call.ctx.runtime.memory.allocator.free(bytes);
    return value_ops.createStringValue(call.ctx.runtime, bytes);
}

fn hostCallStdWriteFile(call: HostCall) HostError!core.JSValue {
    const path = try hostStringArg(call.ctx.runtime, call.args, 0);
    defer call.ctx.runtime.memory.allocator.free(path);
    const data = try hostStringArg(call.ctx.runtime, call.args, 1);
    defer call.ctx.runtime.memory.allocator.free(data);
    try std.Io.Dir.cwd().writeFile(hostIo(), .{ .sub_path = path, .data = data });
    return core.JSValue.undefinedValue();
}

fn hostCallStdExists(call: HostCall) HostError!core.JSValue {
    const path = try hostStringArg(call.ctx.runtime, call.args, 0);
    defer call.ctx.runtime.memory.allocator.free(path);
    std.Io.Dir.cwd().access(hostIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return core.JSValue.boolean(false),
        else => |e| return e,
    };
    return core.JSValue.boolean(true);
}

fn hostCallStdExit(call: HostCall) HostError!core.JSValue {
    call.ctx.exit_code = try hostExitCodeArg(call.ctx.runtime, call.args);
    return error.ProcessExit;
}

fn hostCallStdGetenv(call: HostCall) HostError!core.JSValue {
    const name = try hostStringArg(call.ctx.runtime, call.args, 0);
    defer call.ctx.runtime.memory.allocator.free(name);
    return getenvValue(call.ctx.runtime, name);
}

fn hostCallStdSetenv(call: HostCall) HostError!core.JSValue {
    const name = try hostStringArg(call.ctx.runtime, call.args, 0);
    defer call.ctx.runtime.memory.allocator.free(name);
    const value = try hostStringArg(call.ctx.runtime, call.args, 1);
    defer call.ctx.runtime.memory.allocator.free(value);
    const name_z = try call.ctx.runtime.memory.allocator.dupeZ(u8, name);
    defer call.ctx.runtime.memory.allocator.free(name_z);
    const value_z = try call.ctx.runtime.memory.allocator.dupeZ(u8, value);
    defer call.ctx.runtime.memory.allocator.free(value_z);
    if (setenv(name_z.ptr, value_z.ptr, 1) != 0) return error.SystemError;
    return core.JSValue.undefinedValue();
}

fn hostCallStdUnsetenv(call: HostCall) HostError!core.JSValue {
    const name = try hostStringArg(call.ctx.runtime, call.args, 0);
    defer call.ctx.runtime.memory.allocator.free(name);
    const name_z = try call.ctx.runtime.memory.allocator.dupeZ(u8, name);
    defer call.ctx.runtime.memory.allocator.free(name_z);
    if (unsetenv(name_z.ptr) != 0) return error.SystemError;
    return core.JSValue.undefinedValue();
}

fn hostCallStdGetenviron(call: HostCall) HostError!core.JSValue {
    const rt = call.ctx.runtime;
    const object = try core.Object.create(rt, core.class.ids.object, null);
    errdefer object.value().free(rt);

    var index: usize = 0;
    while (std.c.environ[index]) |entry_z| : (index += 1) {
        const entry = std.mem.span(entry_z);
        const split = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const name = entry[0..split];
        const env_value = entry[split + 1 ..];
        const value = try value_ops.createStringValue(rt, env_value);
        defer value.free(rt);
        try defineObjectProperty(rt, object, name, value);
    }
    return object.value();
}

fn hostCallStdGc(call: HostCall) HostError!core.JSValue {
    return globalGc(call.ctx);
}

fn hostCallStdEvalScript(call: HostCall) HostError!core.JSValue {
    const active_global = try activeGlobalObject(call.ctx.runtime, call.global, call.globals) orelse return error.TypeError;
    const source = try hostStringArgOrUndefined(call.ctx.runtime, call.args, 0);
    defer call.ctx.runtime.memory.allocator.free(source);
    return try hostResult(qjsEvalGlobalScriptSource(call.ctx, call.output, active_global, source, "<evalScript>"));
}

fn hostCallStdLoadScript(call: HostCall) HostError!core.JSValue {
    const active_global = try activeGlobalObject(call.ctx.runtime, call.global, call.globals) orelse return error.TypeError;
    const path = try hostStringArgOrUndefined(call.ctx.runtime, call.args, 0);
    defer call.ctx.runtime.memory.allocator.free(path);
    const source = std.Io.Dir.cwd().readFileAlloc(hostIo(), path, call.ctx.runtime.memory.allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            const message = try std.fmt.allocPrint(call.ctx.runtime.memory.allocator, "could not load '{s}'", .{path});
            defer call.ctx.runtime.memory.allocator.free(message);
            return try hostResult(shared_vm.throwReferenceErrorMessage(call.ctx, active_global, message));
        },
        else => |e| return e,
    };
    defer call.ctx.runtime.memory.allocator.free(source);
    return try hostResult(qjsEvalGlobalScriptSource(call.ctx, call.output, active_global, source, path));
}

fn hostCallStdOpen(call: HostCall) HostError!core.JSValue {
    const active_global = try activeGlobalObject(call.ctx.runtime, call.global, call.globals) orelse return error.TypeError;
    const path = try hostStringArgOrUndefined(call.ctx.runtime, call.args, 0);
    defer call.ctx.runtime.memory.allocator.free(path);
    const mode = try hostStringArgOrUndefined(call.ctx.runtime, call.args, 1);
    defer call.ctx.runtime.memory.allocator.free(mode);
    if (!validStdOpenMode(mode)) return try hostResult(shared_vm.throwTypeErrorMessage(call.ctx, active_global, "invalid file mode"));
    const path_z = try call.ctx.runtime.memory.allocator.dupeZ(u8, path);
    defer call.ctx.runtime.memory.allocator.free(path_z);
    const mode_z = try call.ctx.runtime.memory.allocator.dupeZ(u8, mode);
    defer call.ctx.runtime.memory.allocator.free(mode_z);
    const file = std.c.fopen(path_z.ptr, mode_z.ptr);
    try setStdErrorObject(call.ctx.runtime, call.args, if (file == null) currentErrno() else 0);
    return try stdFileOrNull(call.ctx.runtime, active_global, file, false);
}

fn hostCallStdFdopen(call: HostCall) HostError!core.JSValue {
    const active_global = try activeGlobalObject(call.ctx.runtime, call.global, call.globals) orelse return error.TypeError;
    const fd = try hostInt32Arg(call.ctx.runtime, call.args, 0);
    const mode = try hostStringArgOrUndefined(call.ctx.runtime, call.args, 1);
    defer call.ctx.runtime.memory.allocator.free(mode);
    if (!validStdFdopenMode(mode)) return try hostResult(shared_vm.throwTypeErrorMessage(call.ctx, active_global, "invalid file mode"));
    const mode_z = try call.ctx.runtime.memory.allocator.dupeZ(u8, mode);
    defer call.ctx.runtime.memory.allocator.free(mode_z);
    const file = fdopen(fd, mode_z.ptr);
    try setStdErrorObject(call.ctx.runtime, call.args, if (file == null) currentErrno() else 0);
    return try stdFileOrNull(call.ctx.runtime, active_global, file, false);
}

fn hostCallStdTmpfile(call: HostCall) HostError!core.JSValue {
    const active_global = try activeGlobalObject(call.ctx.runtime, call.global, call.globals) orelse return error.TypeError;
    const file = tmpfile();
    try setStdErrorObject(call.ctx.runtime, call.args, if (file == null) currentErrno() else 0);
    return try stdFileOrNull(call.ctx.runtime, active_global, file, false);
}

fn hostCallStdPopen(call: HostCall) HostError!core.JSValue {
    const active_global = try activeGlobalObject(call.ctx.runtime, call.global, call.globals) orelse return error.TypeError;
    const command = try hostStringArgOrUndefined(call.ctx.runtime, call.args, 0);
    defer call.ctx.runtime.memory.allocator.free(command);
    const mode = try hostStringArgOrUndefined(call.ctx.runtime, call.args, 1);
    defer call.ctx.runtime.memory.allocator.free(mode);
    if (!(std.mem.eql(u8, mode, "r") or std.mem.eql(u8, mode, "w"))) return try hostResult(shared_vm.throwTypeErrorMessage(call.ctx, active_global, "invalid file mode"));
    const command_z = try call.ctx.runtime.memory.allocator.dupeZ(u8, command);
    defer call.ctx.runtime.memory.allocator.free(command_z);
    const mode_z = try call.ctx.runtime.memory.allocator.dupeZ(u8, mode);
    defer call.ctx.runtime.memory.allocator.free(mode_z);
    const file = popen(command_z.ptr, mode_z.ptr);
    try setStdErrorObject(call.ctx.runtime, call.args, if (file == null) currentErrno() else 0);
    return try stdFileOrNull(call.ctx.runtime, active_global, file, true);
}

fn hostCallStdStrerror(call: HostCall) HostError!core.JSValue {
    const err = try hostInt32Arg(call.ctx.runtime, call.args, 0);
    return value_ops.createStringValue(call.ctx.runtime, std.mem.span(strerror(err)));
}

fn hostCallStdPuts(call: HostCall) HostError!core.JSValue {
    for (call.args) |arg| {
        const text = try hostStringFromValue(call.ctx.runtime, arg);
        defer call.ctx.runtime.memory.allocator.free(text);
        if (call.output) |writer| {
            try writer.writeAll(text);
            try writer.flush();
        } else {
            _ = std.c.fwrite(text.ptr, 1, text.len, stdout());
            _ = fflush(stdout());
        }
    }
    return core.JSValue.undefinedValue();
}

fn hostCallStdPrintf(call: HostCall) HostError!core.JSValue {
    const bytes = try formatPrintfBytes(call);
    defer call.ctx.runtime.memory.allocator.free(bytes);
    if (call.output) |writer| {
        try writer.writeAll(bytes);
        try writer.flush();
        return core.JSValue.int32(@intCast(bytes.len));
    }
    const written = std.c.fwrite(bytes.ptr, 1, bytes.len, stdout());
    _ = fflush(stdout());
    return core.JSValue.int32(@intCast(written));
}

fn hostCallStdSprintf(call: HostCall) HostError!core.JSValue {
    const bytes = try formatPrintfBytes(call);
    defer call.ctx.runtime.memory.allocator.free(bytes);
    return value_ops.createStringValue(call.ctx.runtime, bytes);
}

fn hostCallStdUrlGet(call: HostCall) HostError!core.JSValue {
    const rt = call.ctx.runtime;
    const active_global = try activeGlobalObject(rt, call.global, call.globals) orelse return error.TypeError;
    const url = try hostStringArgOrUndefined(rt, call.args, 0);
    defer rt.memory.allocator.free(url);
    const binary = try stdUrlGetBoolOption(rt, call.args, "binary");
    const full = try stdUrlGetBoolOption(rt, call.args, "full");

    const command = try stdUrlGetCurlCommand(rt, url);
    defer rt.memory.allocator.free(command);
    const read_mode: [:0]const u8 = "r";
    const file = popen(command.ptr, read_mode.ptr) orelse {
        return try hostResult(shared_vm.throwTypeErrorMessage(call.ctx, active_global, "could not start curl"));
    };
    defer _ = pclose(file);

    var response_headers = std.ArrayList(u8).empty;
    defer response_headers.deinit(rt.memory.allocator);
    var status: i32 = 0;
    var valid_response = try stdUrlGetReadHeaders(rt, file, &response_headers, &status);
    if (!full and (status < 200 or status >= 300)) valid_response = false;

    var response = core.JSValue.nullValue();
    if (valid_response) {
        const body = try stdUrlGetReadBody(rt, file);
        defer rt.memory.allocator.free(body);
        response = if (binary)
            try stdArrayBufferFromBytes(rt, active_global, body)
        else
            try value_ops.createStringValue(rt, body);
    }
    var response_owned = true;
    errdefer if (response_owned) response.free(rt);

    if (!full) return response;

    const object = try core.Object.create(rt, core.class.ids.object, null);
    errdefer object.value().free(rt);
    try defineObjectProperty(rt, object, "response", response);
    response.free(rt);
    response_owned = false;

    if (valid_response) {
        const headers_value = try value_ops.createStringValue(rt, response_headers.items);
        defer headers_value.free(rt);
        try defineObjectProperty(rt, object, "responseHeaders", headers_value);
        try defineIntProperty(rt, object, "status", status);
    }

    return object.value();
}

fn hostCallStdFileClose(call: HostCall) HostError!core.JSValue {
    const file_object = try stdFileObject(call);
    if (file_object.stdFileIsStdio()) {
        const active_global = try activeGlobalObject(call.ctx.runtime, call.global, call.globals) orelse return error.TypeError;
        return try hostResult(shared_vm.throwTypeErrorMessage(call.ctx, active_global, "cannot close stdio"));
    }
    const rc = file_object.closeStdFileWithResult();
    return core.JSValue.int32(rc);
}

fn hostCallStdFilePuts(call: HostCall) HostError!core.JSValue {
    const file_object = try stdFileObject(call);
    const file = file_object.stdFile().?;
    for (call.args) |arg| {
        const text = try hostStringFromValue(call.ctx.runtime, arg);
        defer call.ctx.runtime.memory.allocator.free(text);
        if (file_object.stdFileIsStdio() and file == stdout() and call.output != null) {
            try call.output.?.writeAll(text);
        } else {
            _ = std.c.fwrite(text.ptr, 1, text.len, file);
        }
    }
    return core.JSValue.undefinedValue();
}

fn hostCallStdFilePrintf(call: HostCall) HostError!core.JSValue {
    const file_object = try stdFileObject(call);
    const file = file_object.stdFile().?;
    const bytes = try formatPrintfBytes(call);
    defer call.ctx.runtime.memory.allocator.free(bytes);
    if (file_object.stdFileIsStdio() and file == stdout() and call.output != null) {
        try call.output.?.writeAll(bytes);
        return core.JSValue.int32(@intCast(bytes.len));
    }
    const written = std.c.fwrite(bytes.ptr, 1, bytes.len, file);
    return core.JSValue.int32(@intCast(written));
}

fn hostCallStdFileFlush(call: HostCall) HostError!core.JSValue {
    const file = try stdFileHandle(call);
    _ = fflush(file);
    return core.JSValue.undefinedValue();
}

fn hostCallStdFileTell(call: HostCall) HostError!core.JSValue {
    const file = try stdFileHandle(call);
    const pos = ftell(file);
    return core.JSValue.int32(@intCast(pos));
}

fn hostCallStdFileSeek(call: HostCall) HostError!core.JSValue {
    const file = try stdFileHandle(call);
    const pos = try hostInt64Arg(call.ctx.runtime, call.args, 0);
    const whence = try hostInt32Arg(call.ctx.runtime, call.args, 1);
    const rc = fseek(file, @intCast(pos), whence);
    return core.JSValue.int32(if (rc < 0) -currentErrno() else rc);
}

fn hostCallStdFileEof(call: HostCall) HostError!core.JSValue {
    const file = try stdFileHandle(call);
    return core.JSValue.boolean(feof(file) != 0);
}

fn hostCallStdFileFileno(call: HostCall) HostError!core.JSValue {
    const file = try stdFileHandle(call);
    return core.JSValue.int32(fileno(file));
}

fn hostCallStdFileError(call: HostCall) HostError!core.JSValue {
    const file = try stdFileHandle(call);
    return core.JSValue.boolean(ferror(file) != 0);
}

fn hostCallStdFileClearerr(call: HostCall) HostError!core.JSValue {
    const file = try stdFileHandle(call);
    clearerr(file);
    return core.JSValue.undefinedValue();
}

fn hostCallStdFileRead(call: HostCall) HostError!core.JSValue {
    const file = try stdFileHandle(call);
    const buffer = stdFileArrayBufferArg(call.args, 0) orelse return error.TypeError;
    const range = try stdFileRange(call.ctx.runtime, call.args, buffer.len);
    const n = std.c.fread(buffer.ptr + range.pos, 1, range.len, file);
    return core.JSValue.int32(@intCast(n));
}

fn hostCallStdFileWrite(call: HostCall) HostError!core.JSValue {
    const file = try stdFileHandle(call);
    if (call.args.len >= 1 and call.args[0].isString()) {
        const text = try hostStringFromValue(call.ctx.runtime, call.args[0]);
        defer call.ctx.runtime.memory.allocator.free(text);
        const range = try stdFileRange(call.ctx.runtime, call.args, text.len);
        const n = std.c.fwrite(text.ptr + range.pos, 1, range.len, file);
        return core.JSValue.int32(@intCast(n));
    }
    const buffer = stdFileArrayBufferArg(call.args, 0) orelse return error.TypeError;
    const range = try stdFileRange(call.ctx.runtime, call.args, buffer.len);
    const n = std.c.fwrite(buffer.ptr + range.pos, 1, range.len, file);
    return core.JSValue.int32(@intCast(n));
}

fn hostCallStdFileGetline(call: HostCall) HostError!core.JSValue {
    const file = try stdFileHandle(call);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(call.ctx.runtime.memory.allocator);
    while (true) {
        const c = fgetc(file);
        if (c == -1) {
            if (bytes.items.len == 0) return core.JSValue.nullValue();
            break;
        }
        if (c == '\n') break;
        try bytes.append(call.ctx.runtime.memory.allocator, @intCast(c));
    }
    return value_ops.createStringValue(call.ctx.runtime, bytes.items);
}

fn hostCallStdFileReadAsString(call: HostCall) HostError!core.JSValue {
    const bytes = try readRemainingFileBytes(call);
    defer call.ctx.runtime.memory.allocator.free(bytes);
    return value_ops.createStringValue(call.ctx.runtime, bytes);
}

fn hostCallStdFileReadAsArrayBuffer(call: HostCall) HostError!core.JSValue {
    const bytes = try readRemainingFileBytes(call);
    defer call.ctx.runtime.memory.allocator.free(bytes);
    const active_global = try activeGlobalObject(call.ctx.runtime, call.global, call.globals) orelse return error.TypeError;
    const proto = shared_vm.constructorPrototypeFromGlobal(call.ctx.runtime, active_global, "ArrayBuffer");
    const buffer_value = try builtins.buffer.arrayBufferConstructLength(call.ctx.runtime, bytes.len, null, proto);
    const object = expectObjectArg(buffer_value) catch unreachable;
    @memcpy(object.byteStorageSlot().*[0..bytes.len], bytes);
    return buffer_value;
}

fn hostCallStdFileGetByte(call: HostCall) HostError!core.JSValue {
    const file = try stdFileHandle(call);
    return core.JSValue.int32(fgetc(file));
}

fn hostCallStdFilePutByte(call: HostCall) HostError!core.JSValue {
    const file = try stdFileHandle(call);
    const byte = try hostInt32Arg(call.ctx.runtime, call.args, 0);
    return core.JSValue.int32(fputc(byte, file));
}

fn hostCallOsGetenv(call: HostCall) HostError!core.JSValue {
    const name = try hostStringArg(call.ctx.runtime, call.args, 0);
    defer call.ctx.runtime.memory.allocator.free(name);
    return getenvValue(call.ctx.runtime, name);
}

fn getenvValue(rt: *core.JSRuntime, name: []const u8) HostError!core.JSValue {
    const name_z = try rt.memory.allocator.dupeZ(u8, name);
    defer rt.memory.allocator.free(name_z);
    const value = std.c.getenv(name_z.ptr) orelse return core.JSValue.undefinedValue();
    return value_ops.createStringValue(rt, std.mem.span(value));
}

fn hostCallOsGetcwd(call: HostCall) HostError!core.JSValue {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try hostResult(std.process.currentPath(hostIo(), &buffer));
    return value_ops.createStringValue(call.ctx.runtime, buffer[0..len]);
}

fn hostCallOsChdir(call: HostCall) HostError!core.JSValue {
    const path = try hostStringArg(call.ctx.runtime, call.args, 0);
    defer call.ctx.runtime.memory.allocator.free(path);
    try hostResult(std.process.setCurrentPath(hostIo(), path));
    return core.JSValue.undefinedValue();
}

fn hostCallOsRemove(call: HostCall) HostError!core.JSValue {
    const path = try hostStringArg(call.ctx.runtime, call.args, 0);
    defer call.ctx.runtime.memory.allocator.free(path);
    const path_z = try call.ctx.runtime.memory.allocator.dupeZ(u8, path);
    defer call.ctx.runtime.memory.allocator.free(path_z);
    const rc = libc.remove(path_z.ptr);
    return core.JSValue.int32(if (rc < 0) -currentErrno() else rc);
}

fn hostCallOsRename(call: HostCall) HostError!core.JSValue {
    const old_path = try hostStringArg(call.ctx.runtime, call.args, 0);
    defer call.ctx.runtime.memory.allocator.free(old_path);
    const new_path = try hostStringArg(call.ctx.runtime, call.args, 1);
    defer call.ctx.runtime.memory.allocator.free(new_path);
    const old_path_z = try call.ctx.runtime.memory.allocator.dupeZ(u8, old_path);
    defer call.ctx.runtime.memory.allocator.free(old_path_z);
    const new_path_z = try call.ctx.runtime.memory.allocator.dupeZ(u8, new_path);
    defer call.ctx.runtime.memory.allocator.free(new_path_z);
    const rc = libc.rename(old_path_z.ptr, new_path_z.ptr);
    return core.JSValue.int32(if (rc < 0) -currentErrno() else rc);
}

fn hostCallOsOpen(call: HostCall) HostError!core.JSValue {
    const path = try hostStringArg(call.ctx.runtime, call.args, 0);
    defer call.ctx.runtime.memory.allocator.free(path);
    const flags = try hostInt32Arg(call.ctx.runtime, call.args, 1);
    const mode = if (call.args.len >= 3 and !call.args[2].isUndefined())
        try hostInt32Arg(call.ctx.runtime, call.args, 2)
    else
        0o666;
    const path_z = try call.ctx.runtime.memory.allocator.dupeZ(u8, path);
    defer call.ctx.runtime.memory.allocator.free(path_z);
    const fd = open(path_z.ptr, flags, @as(c_uint, @intCast(mode)));
    return core.JSValue.int32(if (fd < 0) -currentErrno() else fd);
}

fn hostCallOsClose(call: HostCall) HostError!core.JSValue {
    const fd = try hostInt32Arg(call.ctx.runtime, call.args, 0);
    const rc = close(fd);
    return core.JSValue.int32(if (rc < 0) -currentErrno() else rc);
}

fn hostCallOsSeek(call: HostCall) HostError!core.JSValue {
    const fd = try hostInt32Arg(call.ctx.runtime, call.args, 0);
    const pos = try hostInt64Arg(call.ctx.runtime, call.args, 1);
    const whence = try hostInt32Arg(call.ctx.runtime, call.args, 2);
    const rc = lseek(fd, @intCast(pos), whence);
    return int64ResultValue(if (rc < 0) -@as(i64, currentErrno()) else @intCast(rc));
}

fn hostCallOsRead(call: HostCall) HostError!core.JSValue {
    return hostCallOsReadWrite(call, false);
}

fn hostCallOsWrite(call: HostCall) HostError!core.JSValue {
    return hostCallOsReadWrite(call, true);
}

fn hostCallOsReadWrite(call: HostCall, is_write: bool) HostError!core.JSValue {
    const active_global = try activeGlobalObject(call.ctx.runtime, call.global, call.globals) orelse return error.TypeError;
    const fd = try hostInt32Arg(call.ctx.runtime, call.args, 0);
    const buffer = stdFileArrayBufferArg(call.args, 1) orelse return error.TypeError;
    const pos = try hostResult(value_ops.toIndexUsize(call.ctx.runtime, if (call.args.len >= 3) call.args[2] else core.JSValue.undefinedValue()));
    const len = try hostResult(value_ops.toIndexUsize(call.ctx.runtime, if (call.args.len >= 4) call.args[3] else core.JSValue.undefinedValue()));
    if (pos > buffer.len or len > buffer.len - pos) {
        return try hostResult(shared_vm.throwRangeErrorMessage(call.ctx, active_global, "read/write array buffer overflow"));
    }
    const rc = if (is_write)
        write(fd, buffer.ptr + pos, len)
    else
        read(fd, buffer.ptr + pos, len);
    return int64ResultValue(if (rc < 0) -@as(i64, currentErrno()) else @intCast(rc));
}

fn hostCallOsMkdir(call: HostCall) HostError!core.JSValue {
    const path = try hostStringArg(call.ctx.runtime, call.args, 0);
    defer call.ctx.runtime.memory.allocator.free(path);
    const mode = if (call.args.len >= 2 and !call.args[1].isUndefined())
        try hostInt32Arg(call.ctx.runtime, call.args, 1)
    else
        0o777;
    const path_z = try call.ctx.runtime.memory.allocator.dupeZ(u8, path);
    defer call.ctx.runtime.memory.allocator.free(path_z);
    const rc = libc.mkdir(path_z.ptr, @intCast(mode));
    return core.JSValue.int32(if (rc < 0) -currentErrno() else rc);
}

fn hostCallOsReaddir(call: HostCall) HostError!core.JSValue {
    const rt = call.ctx.runtime;
    const path = try hostStringArg(rt, call.args, 0);
    defer rt.memory.allocator.free(path);
    const path_z = try rt.memory.allocator.dupeZ(u8, path);
    defer rt.memory.allocator.free(path_z);

    const out = try core.Object.createArray(rt, null);
    const out_value = out.value();
    defer out_value.free(rt);
    var err: i32 = 0;
    if (libc.opendir(path_z.ptr)) |dir| {
        defer _ = libc.closedir(dir);
        while (true) {
            std.c._errno().* = 0;
            const entry = libc.readdir(dir) orelse {
                err = currentErrno();
                break;
            };
            const raw_name = entry.*.d_name[0..];
            const name_len = std.mem.indexOfScalar(u8, raw_name, 0) orelse raw_name.len;
            const name = raw_name[0..name_len];
            const value = try value_ops.createStringValue(rt, name);
            defer value.free(rt);
            try setArrayIndex(rt, out, out.length, value);
        }
    } else {
        err = currentErrno();
    }
    return makeOsResultPair(rt, out_value, err);
}

fn hostCallOsStat(call: HostCall) HostError!core.JSValue {
    return hostCallOsStatCommon(call, false);
}

fn hostCallOsLstat(call: HostCall) HostError!core.JSValue {
    return hostCallOsStatCommon(call, true);
}

fn hostCallOsStatCommon(call: HostCall, is_lstat: bool) HostError!core.JSValue {
    const rt = call.ctx.runtime;
    const path = try hostStringArg(rt, call.args, 0);
    defer rt.memory.allocator.free(path);
    const path_z = try rt.memory.allocator.dupeZ(u8, path);
    defer rt.memory.allocator.free(path_z);
    var st: libc.struct_stat = undefined;
    const rc = if (is_lstat) libc.lstat(path_z.ptr, &st) else libc.stat(path_z.ptr, &st);
    if (rc < 0) return makeOsResultPair(rt, core.JSValue.nullValue(), currentErrno());
    const object = try core.Object.create(rt, core.class.ids.object, null);
    const object_value = object.value();
    defer object_value.free(rt);
    try defineNumberProperty(rt, object, "dev", @floatFromInt(st.st_dev));
    try defineNumberProperty(rt, object, "ino", @floatFromInt(st.st_ino));
    try defineIntProperty(rt, object, "mode", @intCast(st.st_mode));
    try defineNumberProperty(rt, object, "nlink", @floatFromInt(st.st_nlink));
    try defineNumberProperty(rt, object, "uid", @floatFromInt(st.st_uid));
    try defineNumberProperty(rt, object, "gid", @floatFromInt(st.st_gid));
    try defineNumberProperty(rt, object, "rdev", @floatFromInt(st.st_rdev));
    try defineNumberProperty(rt, object, "size", @floatFromInt(st.st_size));
    try defineNumberProperty(rt, object, "blocks", @floatFromInt(st.st_blocks));
    try defineNumberProperty(rt, object, "atime", timespecMs(statAtime(st)));
    try defineNumberProperty(rt, object, "mtime", timespecMs(statMtime(st)));
    try defineNumberProperty(rt, object, "ctime", timespecMs(statCtime(st)));
    return makeOsResultPair(rt, object_value, 0);
}

fn hostCallOsRealpath(call: HostCall) HostError!core.JSValue {
    const rt = call.ctx.runtime;
    const path = try hostStringArg(rt, call.args, 0);
    defer rt.memory.allocator.free(path);
    const path_z = try rt.memory.allocator.dupeZ(u8, path);
    defer rt.memory.allocator.free(path_z);
    var buffer: [4096:0]u8 = undefined;
    const resolved = libc.realpath(path_z.ptr, &buffer);
    if (resolved == null) return makeOsStringResultPair(rt, "", currentErrno());
    return makeOsStringResultPair(rt, std.mem.span(@as([*:0]const u8, @ptrCast(resolved.?))), 0);
}

fn hostCallOsSymlink(call: HostCall) HostError!core.JSValue {
    const rt = call.ctx.runtime;
    const target = try hostStringArg(rt, call.args, 0);
    defer rt.memory.allocator.free(target);
    const linkpath = try hostStringArg(rt, call.args, 1);
    defer rt.memory.allocator.free(linkpath);
    const target_z = try rt.memory.allocator.dupeZ(u8, target);
    defer rt.memory.allocator.free(target_z);
    const linkpath_z = try rt.memory.allocator.dupeZ(u8, linkpath);
    defer rt.memory.allocator.free(linkpath_z);
    const rc = libc.symlink(target_z.ptr, linkpath_z.ptr);
    return core.JSValue.int32(if (rc < 0) -currentErrno() else rc);
}

fn hostCallOsReadlink(call: HostCall) HostError!core.JSValue {
    const rt = call.ctx.runtime;
    const path = try hostStringArg(rt, call.args, 0);
    defer rt.memory.allocator.free(path);
    const path_z = try rt.memory.allocator.dupeZ(u8, path);
    defer rt.memory.allocator.free(path_z);
    var buffer: [4096]u8 = undefined;
    const rc = libc.readlink(path_z.ptr, &buffer, buffer.len - 1);
    if (rc < 0) return makeOsStringResultPair(rt, "", currentErrno());
    const len: usize = @intCast(rc);
    return makeOsStringResultPair(rt, buffer[0..len], 0);
}

fn hostCallOsUtimes(call: HostCall) HostError!core.JSValue {
    const rt = call.ctx.runtime;
    const path = try hostStringArg(rt, call.args, 0);
    defer rt.memory.allocator.free(path);
    const atime = try hostInt64Arg(rt, call.args, 1);
    const mtime = try hostInt64Arg(rt, call.args, 2);
    const path_z = try rt.memory.allocator.dupeZ(u8, path);
    defer rt.memory.allocator.free(path_z);
    var times = [_]libc.struct_timeval{ timevalFromMs(atime), timevalFromMs(mtime) };
    const rc = libc.utimes(path_z.ptr, &times);
    return core.JSValue.int32(if (rc < 0) -currentErrno() else rc);
}

fn hostCallOsSetTimeout(call: HostCall) HostError!core.JSValue {
    return hostCallOsSetTimer(call, false);
}

fn hostCallOsSetInterval(call: HostCall) HostError!core.JSValue {
    return hostCallOsSetTimer(call, true);
}

fn hostCallOsSetTimer(call: HostCall, repeats: bool) HostError!core.JSValue {
    const active_global = try activeGlobalObject(call.ctx.runtime, call.global, call.globals) orelse return error.TypeError;
    const callback = if (call.args.len >= 1) call.args[0] else core.JSValue.undefinedValue();
    if (!shared_vm.isCallableValue(callback)) return try hostResult(shared_vm.throwTypeErrorMessage(call.ctx, active_global, "not a function"));
    var delay = try hostInt64Arg(call.ctx.runtime, call.args, 1);
    if (delay < 1) delay = 1;
    const id = call.ctx.next_os_timer_id;
    call.ctx.next_os_timer_id += 1;
    if (call.ctx.next_os_timer_id > 9007199254740991) call.ctx.next_os_timer_id = 1;
    try hostResult(shared_vm.enqueueOsTimer(call.ctx, id, callback, @intCast(delay), repeats));
    return int64ResultValue(id);
}

fn hostCallOsClearTimeout(call: HostCall) HostError!core.JSValue {
    const timer_id = try hostInt64Arg(call.ctx.runtime, call.args, 0);
    shared_vm.clearOsTimer(call.ctx, timer_id);
    return core.JSValue.undefinedValue();
}

fn hostCallOsExec(call: HostCall) HostError!core.JSValue {
    const rt = call.ctx.runtime;
    const argv = try osExecArgv(rt, call.args);
    defer argv.deinit(rt);
    if (argv.items.len < 1) return error.TypeError;

    var block = true;
    var use_path = true;
    var file: ?[]u8 = null;
    defer if (file) |value| rt.memory.allocator.free(value);
    var cwd: ?[]u8 = null;
    defer if (cwd) |value| rt.memory.allocator.free(value);
    var env = OsExecEnv.empty;
    defer env.deinit(rt);
    var std_fds = [_]i32{ 0, 1, 2 };
    var uid: u32 = std.math.maxInt(u32);
    var gid: u32 = std.math.maxInt(u32);
    var groups: [64]libc.gid_t = undefined;
    var group_count: i32 = -1;

    if (call.args.len >= 2 and !call.args[1].isUndefined() and !call.args[1].isNull()) {
        const options = try expectObjectArg(call.args[1]);
        block = try osBoolOption(rt, options, "block", true);
        use_path = try osBoolOption(rt, options, "usePath", true);
        file = try osOptionalStringOption(rt, options, "file");
        cwd = try osOptionalStringOption(rt, options, "cwd");
        if (try osOptionalIntOption(rt, options, "stdin")) |fd| std_fds[0] = fd;
        if (try osOptionalIntOption(rt, options, "stdout")) |fd| std_fds[1] = fd;
        if (try osOptionalIntOption(rt, options, "stderr")) |fd| std_fds[2] = fd;
        env = try osOptionalEnvOption(rt, options, "env");
        if (try osOptionalIntOption(rt, options, "uid")) |value| uid = @bitCast(value);
        if (try osOptionalIntOption(rt, options, "gid")) |value| gid = @bitCast(value);
        if (try osOptionalGroupsOption(rt, options, "groups", &groups)) |count| group_count = count;
    }

    const cwd_z = if (cwd) |dir| try rt.memory.allocator.dupeZ(u8, dir) else null;
    defer if (cwd_z) |value| rt.memory.allocator.free(value);
    const file_z = if (file) |path| try rt.memory.allocator.dupeZ(u8, path) else null;
    defer if (file_z) |value| rt.memory.allocator.free(value);
    const exec_file_ptr = if (file_z) |path| path.ptr else argv.items[0].ptr;

    const pid = libc.fork();
    if (pid < 0) return error.TypeError;
    if (pid == 0) {
        var i: usize = 0;
        while (i < std_fds.len) : (i += 1) {
            if (std_fds[i] != @as(i32, @intCast(i))) {
                if (libc.dup2(std_fds[i], @intCast(i)) < 0) libc._exit(127);
            }
        }
        const fd_max = libc.sysconf(libc._SC_OPEN_MAX);
        if (fd_max > 3) {
            var fd: c_int = 3;
            while (fd < fd_max) : (fd += 1) _ = libc.close(fd);
        }
        if (cwd_z) |dir| {
            if (libc.chdir(dir.ptr) < 0) libc._exit(127);
        }
        if (group_count != -1) {
            if (libc.setgroups(@intCast(group_count), &groups) < 0) libc._exit(127);
        }
        if (uid != std.math.maxInt(u32)) {
            if (libc.setuid(uid) < 0) libc._exit(127);
        }
        if (gid != std.math.maxInt(u32)) {
            if (libc.setgid(gid) < 0) libc._exit(127);
        }
        if (env.c_envp) |envp| {
            if (use_path) {
                _ = execvpe(exec_file_ptr, @ptrCast(argv.c_argv.ptr), @ptrCast(envp.ptr));
            } else {
                _ = execve(exec_file_ptr, @ptrCast(argv.c_argv.ptr), @ptrCast(envp.ptr));
            }
        } else {
            if (use_path) {
                _ = libc.execvp(exec_file_ptr, @ptrCast(argv.c_argv.ptr));
            } else {
                _ = libc.execv(exec_file_ptr, @ptrCast(argv.c_argv.ptr));
            }
        }
        libc._exit(127);
    }
    if (!block) return core.JSValue.int32(pid);
    var status: c_int = 0;
    while (true) {
        const rc = libc.waitpid(pid, &status, 0);
        if (rc == pid) break;
        if (rc < 0) return core.JSValue.int32(-currentErrno());
    }
    if (libc.WIFEXITED(status)) return core.JSValue.int32(libc.WEXITSTATUS(status));
    if (libc.WIFSIGNALED(status)) return core.JSValue.int32(-libc.WTERMSIG(status));
    return core.JSValue.int32(status);
}

fn hostCallOsWaitpid(call: HostCall) HostError!core.JSValue {
    const pid = try hostInt32Arg(call.ctx.runtime, call.args, 0);
    const options = try hostInt32Arg(call.ctx.runtime, call.args, 1);
    var status: c_int = 0;
    var rc = libc.waitpid(pid, &status, options);
    if (rc < 0) {
        rc = -currentErrno();
        status = 0;
    }
    const array = try core.Object.createArray(call.ctx.runtime, null);
    errdefer array.value().free(call.ctx.runtime);
    try setArrayIndex(call.ctx.runtime, array, 0, core.JSValue.int32(rc));
    try setArrayIndex(call.ctx.runtime, array, 1, core.JSValue.int32(status));
    return array.value();
}

fn hostCallOsGetpid(call: HostCall) HostError!core.JSValue {
    _ = call;
    return core.JSValue.int32(libc.getpid());
}

fn hostCallOsPipe(call: HostCall) HostError!core.JSValue {
    var fds: [2]c_int = undefined;
    if (libc.pipe(&fds) < 0) return core.JSValue.nullValue();
    var fds_owned = true;
    errdefer if (fds_owned) {
        _ = libc.close(fds[0]);
        _ = libc.close(fds[1]);
    };
    const array = try core.Object.createArray(call.ctx.runtime, null);
    errdefer array.value().free(call.ctx.runtime);
    try setArrayIndex(call.ctx.runtime, array, 0, core.JSValue.int32(fds[0]));
    try setArrayIndex(call.ctx.runtime, array, 1, core.JSValue.int32(fds[1]));
    fds_owned = false;
    return array.value();
}

fn hostCallOsKill(call: HostCall) HostError!core.JSValue {
    const pid = try hostInt32Arg(call.ctx.runtime, call.args, 0);
    const sig = try hostInt32Arg(call.ctx.runtime, call.args, 1);
    const rc = libc.kill(pid, sig);
    return core.JSValue.int32(if (rc < 0) -currentErrno() else rc);
}

fn hostCallOsDup(call: HostCall) HostError!core.JSValue {
    const fd = try hostInt32Arg(call.ctx.runtime, call.args, 0);
    const rc = libc.dup(fd);
    return core.JSValue.int32(if (rc < 0) -currentErrno() else rc);
}

fn hostCallOsDup2(call: HostCall) HostError!core.JSValue {
    const fd = try hostInt32Arg(call.ctx.runtime, call.args, 0);
    const fd2 = try hostInt32Arg(call.ctx.runtime, call.args, 1);
    const rc = libc.dup2(fd, fd2);
    return core.JSValue.int32(if (rc < 0) -currentErrno() else rc);
}

fn hostCallOsIsatty(call: HostCall) HostError!core.JSValue {
    const fd = try hostInt32Arg(call.ctx.runtime, call.args, 0);
    return core.JSValue.boolean(libc.isatty(fd) != 0);
}

fn hostCallOsTtyGetWinSize(call: HostCall) HostError!core.JSValue {
    const fd = try hostInt32Arg(call.ctx.runtime, call.args, 0);
    var ws: libc.struct_winsize = undefined;
    if (libc.ioctl(fd, libc.TIOCGWINSZ, &ws) == 0 and ws.ws_col >= 4 and ws.ws_row >= 4) {
        const array = try core.Object.createArray(call.ctx.runtime, null);
        errdefer array.value().free(call.ctx.runtime);
        try setArrayIndex(call.ctx.runtime, array, 0, core.JSValue.int32(ws.ws_col));
        try setArrayIndex(call.ctx.runtime, array, 1, core.JSValue.int32(ws.ws_row));
        return array.value();
    }
    return core.JSValue.nullValue();
}

threadlocal var original_termios: ?libc.struct_termios = null;

fn hostCallOsTtySetRaw(call: HostCall) HostError!core.JSValue {
    const fd = try hostInt32Arg(call.ctx.runtime, call.args, 0);
    const enable = if (call.args.len >= 2) (call.args[1].asBool() orelse true) else true;

    if (!enable) {
        if (original_termios) |orig| {
            _ = libc.tcsetattr(fd, libc.TCSANOW, &orig);
            original_termios = null;
        }
        return core.JSValue.undefinedValue();
    }

    var tty = std.mem.zeroes(libc.struct_termios);
    _ = libc.tcgetattr(fd, &tty);
    if (original_termios == null) {
        original_termios = tty;
    }
    tty.c_iflag &= ~@as(@TypeOf(tty.c_iflag), libc.IGNBRK | libc.BRKINT | libc.PARMRK | libc.ISTRIP | libc.INLCR | libc.IGNCR | libc.ICRNL | libc.IXON);
    tty.c_oflag |= @as(@TypeOf(tty.c_oflag), libc.OPOST);
    tty.c_lflag &= ~@as(@TypeOf(tty.c_lflag), libc.ECHO | libc.ECHONL | libc.ICANON | libc.IEXTEN);
    tty.c_cflag &= ~@as(@TypeOf(tty.c_cflag), libc.CSIZE | libc.PARENB);
    tty.c_cflag |= @as(@TypeOf(tty.c_cflag), libc.CS8);
    tty.c_cc[@intCast(libc.VMIN)] = 1;
    tty.c_cc[@intCast(libc.VTIME)] = 0;
    _ = libc.tcsetattr(fd, libc.TCSANOW, &tty);
    return core.JSValue.undefinedValue();
}

fn hostCallOsSetReadHandler(call: HostCall) HostError!core.JSValue {
    return hostCallOsSetRwHandler(call, false);
}

fn hostCallOsSetWriteHandler(call: HostCall) HostError!core.JSValue {
    return hostCallOsSetRwHandler(call, true);
}

fn hostCallOsSetRwHandler(call: HostCall, write_handler: bool) HostError!core.JSValue {
    const active_global = try activeGlobalObject(call.ctx.runtime, call.global, call.globals) orelse return error.TypeError;
    const fd = try hostInt32Arg(call.ctx.runtime, call.args, 0);
    const callback = if (call.args.len >= 2) call.args[1] else core.JSValue.undefinedValue();
    if (callback.isNull()) {
        clearOsRwHandler(call.ctx, fd, write_handler);
        return core.JSValue.undefinedValue();
    }
    if (!shared_vm.isCallableValue(callback)) return try hostResult(shared_vm.throwTypeErrorMessage(call.ctx, active_global, "not a function"));
    try setOsRwHandler(call.ctx, fd, write_handler, callback);
    return core.JSValue.undefinedValue();
}

fn hostCallOsSignal(call: HostCall) HostError!core.JSValue {
    const active_global = try activeGlobalObject(call.ctx.runtime, call.global, call.globals) orelse return error.TypeError;
    const sig: u32 = @bitCast(try hostInt32Arg(call.ctx.runtime, call.args, 0));
    if (sig >= 64) return try hostResult(shared_vm.throwRangeErrorMessage(call.ctx, active_global, "invalid signal number"));
    const callback = if (call.args.len >= 2) call.args[1] else core.JSValue.undefinedValue();
    if (callback.isNull() or callback.isUndefined()) {
        clearOsSignalHandler(call.ctx, sig);
        _ = signal(@intCast(sig), if (callback.isNull()) 0 else 1);
        return core.JSValue.undefinedValue();
    }
    if (!shared_vm.isCallableValue(callback)) return try hostResult(shared_vm.throwTypeErrorMessage(call.ctx, active_global, "not a function"));
    try setOsSignalHandler(call.ctx, sig, callback);
    _ = signal(@intCast(sig), @intFromPtr(&osSignalHandler));
    return core.JSValue.undefinedValue();
}

fn hostCallOsCputime(call: HostCall) HostError!core.JSValue {
    _ = call;
    var ru: libc.struct_rusage = undefined;
    if (libc.getrusage(libc.RUSAGE_SELF, &ru) != 0) return core.JSValue.int32(0);
    return int64ResultValue(@as(i64, @intCast(ru.ru_utime.tv_sec)) * 1_000_000 + @as(i64, @intCast(ru.ru_utime.tv_usec)));
}

fn hostCallOsExePath(call: HostCall) HostError!core.JSValue {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const rc = libc.readlink("/proc/self/exe", &buffer, buffer.len);
    if (rc < 0) return core.JSValue.undefinedValue();
    return value_ops.createStringValue(call.ctx.runtime, buffer[0..@intCast(rc)]);
}

fn hostCallOsNow(call: HostCall) HostError!core.JSValue {
    _ = call;
    const ns = std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake).raw.toNanoseconds();
    return int64ResultValue(@intCast(@divTrunc(ns, 1000)));
}

fn hostCallOsSleepAsync(call: HostCall) HostError!core.JSValue {
    const delay = try hostInt64Arg(call.ctx.runtime, call.args, 0);
    const delay_ms: u64 = if (delay > 0) @intCast(delay) else 0;
    const promise_value = try builtins.promise.constructWithPrototype(call.ctx.runtime, null);
    errdefer promise_value.free(call.ctx.runtime);
    try hostResult(shared_vm.enqueueOsTimer(call.ctx, -1, promise_value, delay_ms, false));
    return promise_value;
}

fn hostCallOsMkdtemp(call: HostCall) HostError!core.JSValue {
    return hostCallOsMkTemp(call, true);
}

fn hostCallOsMkstemp(call: HostCall) HostError!core.JSValue {
    return hostCallOsMkTemp(call, false);
}

fn hostCallOsMkTemp(call: HostCall, dir: bool) HostError!core.JSValue {
    const rt = call.ctx.runtime;
    const pattern = if (call.args.len >= 1 and !call.args[0].isUndefined())
        try hostStringFromValue(rt, call.args[0])
    else
        try rt.memory.allocator.dupe(u8, "tmpXXXXXX");
    defer rt.memory.allocator.free(pattern);
    const suffix = "XXXXXX";
    const needs_suffix = pattern.len < suffix.len or !std.mem.eql(u8, pattern[pattern.len - suffix.len ..], suffix);
    const with_suffix = if (needs_suffix)
        try std.mem.concat(rt.memory.allocator, u8, &.{ pattern, suffix })
    else
        try rt.memory.allocator.dupe(u8, pattern);
    defer rt.memory.allocator.free(with_suffix);
    const temp_z = try rt.memory.allocator.dupeZ(u8, with_suffix);
    defer rt.memory.allocator.free(temp_z);
    const err_or_fd: i32 = if (dir) blk: {
        break :blk if (mkdtemp(temp_z.ptr) == null) -currentErrno() else 0;
    } else blk: {
        const fd = mkstemp(temp_z.ptr);
        break :blk if (fd < 0) -currentErrno() else fd;
    };
    var fd_owned = !dir and err_or_fd >= 0;
    errdefer if (fd_owned) {
        _ = libc.close(err_or_fd);
    };
    const result = try makeOsStringResultPair(rt, std.mem.span(temp_z.ptr), err_or_fd);
    fd_owned = false;
    return result;
}

fn setOsSignalHandler(ctx: *core.JSContext, sig: u32, callback: core.JSValue) !void {
    for (ctx.os_signal_handlers) |*handler| {
        if (handler.sig != sig) continue;
        try handler.setCallback(ctx.runtime, callback);
        return;
    }
    const index = ctx.os_signal_handlers.len;
    try ctx.ensureOsSignalHandlerCapacity(index + 1);
    const handler = try core.OsSignalHandler.init(ctx, sig, callback);
    ctx.os_signal_handlers = ctx.os_signal_handlers.ptr[0 .. index + 1];
    ctx.os_signal_handlers[index] = handler;
}

fn clearOsSignalHandler(ctx: *core.JSContext, sig: u32) void {
    var index: usize = 0;
    while (index < ctx.os_signal_handlers.len) : (index += 1) {
        if (ctx.os_signal_handlers[index].sig != sig) continue;
        ctx.removeOsSignalHandlerAt(index);
        return;
    }
}

pub fn runNextOsSignalHandler(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool {
    if (os_pending_signals == 0) return false;
    for (ctx.os_signal_handlers) |handler| {
        const mask = @as(u64, 1) << @intCast(handler.sig);
        if ((os_pending_signals & mask) == 0) continue;
        os_pending_signals &= ~mask;
        const callback = handler.callback.dup();
        defer callback.free(ctx.runtime);
        const result = try hostResult(shared_vm.callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), callback, &.{}, null, null));
        result.free(ctx.runtime);
        return true;
    }
    return false;
}

fn setOsRwHandler(ctx: *core.JSContext, fd: i32, write_handler: bool, callback: core.JSValue) !void {
    for (ctx.os_rw_handlers) |*handler| {
        if (handler.fd != fd) continue;
        try handler.setCallback(ctx.runtime, write_handler, callback);
        return;
    }
    const index = ctx.os_rw_handlers.len;
    try ctx.ensureOsRwHandlerCapacity(index + 1);
    var handler = core.OsRwHandler{
        .fd = fd,
    };
    errdefer handler.deinit(ctx.runtime);
    try handler.setCallback(ctx.runtime, write_handler, callback);
    ctx.os_rw_handlers = ctx.os_rw_handlers.ptr[0 .. index + 1];
    ctx.os_rw_handlers[index] = handler;
}

fn clearOsRwHandler(ctx: *core.JSContext, fd: i32, write_handler: bool) void {
    var index: usize = 0;
    while (index < ctx.os_rw_handlers.len) : (index += 1) {
        if (ctx.os_rw_handlers[index].fd != fd) continue;
        ctx.os_rw_handlers[index].clearCallback(ctx.runtime, write_handler);
        if (ctx.os_rw_handlers[index].read_callback.isNull() and ctx.os_rw_handlers[index].write_callback.isNull()) {
            ctx.removeOsRwHandlerAt(index);
        }
        return;
    }
}

fn makeOsResultPair(rt: *core.JSRuntime, value: core.JSValue, err: i32) !core.JSValue {
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const array = try core.Object.createArray(rt, null);
    errdefer array.value().free(rt);
    try setArrayIndex(rt, array, 0, rooted_value);
    try setArrayIndex(rt, array, 1, core.JSValue.int32(err));
    return array.value();
}

fn openFdCountForTest() !usize {
    const path = if (builtin.os.tag == .macos) "/dev/fd" else "/proc/self/fd";
    var dir = try std.Io.Dir.openDirAbsolute(hostIo(), path, .{ .iterate = true });
    defer dir.close(hostIo());

    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(hostIo())) |_| count += 1;
    return count;
}

fn dirHasAnyFileForTest(path: []const u8) !bool {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, path, .{ .iterate = true });
    defer dir.close(std.testing.io);

    var it = dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        if (entry.kind == .file) return true;
    }
    return false;
}

test "makeOsResultPair roots direct symbol value while creating result array" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-os-result-pair-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const pair_value = try makeOsResultPair(rt, core.JSValue.symbol(symbol_atom), 0);
    var pair_alive = true;
    defer if (pair_alive) pair_value.free(rt);
    const pair = thisObject(pair_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value = pair.getProperty(core.atom.atomFromUInt32(0));
    defer value.free(rt);
    try std.testing.expect(value.same(core.JSValue.symbol(symbol_atom)));

    pair_value.free(rt);
    pair_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}



fn makeOsStringResultPair(rt: *core.JSRuntime, value: []const u8, err: i32) !core.JSValue {
    const string_value = try value_ops.createStringValue(rt, value);
    defer string_value.free(rt);
    return makeOsResultPair(rt, string_value, err);
}

fn timespecMs(value: libc.struct_timespec) f64 {
    return @as(f64, @floatFromInt(value.tv_sec)) * 1000 + @as(f64, @floatFromInt(@divTrunc(value.tv_nsec, 1000000)));
}

fn statAtime(st: libc.struct_stat) libc.struct_timespec {
    if (@hasField(libc.struct_stat, "st_atim")) {
        return st.st_atim;
    } else {
        return st.st_atimespec;
    }
}

fn statMtime(st: libc.struct_stat) libc.struct_timespec {
    if (@hasField(libc.struct_stat, "st_mtim")) {
        return st.st_mtim;
    } else {
        return st.st_mtimespec;
    }
}

fn statCtime(st: libc.struct_stat) libc.struct_timespec {
    if (@hasField(libc.struct_stat, "st_ctim")) {
        return st.st_ctim;
    } else {
        return st.st_ctimespec;
    }
}

fn timevalFromMs(value: i64) libc.struct_timeval {
    return .{
        .tv_sec = @intCast(@divTrunc(value, 1000)),
        .tv_usec = @intCast(@mod(value, 1000) * 1000),
    };
}

const OsExecArgv = struct {
    items: [][:0]u8,
    c_argv: []?[*:0]u8,

    fn deinit(self: OsExecArgv, rt: *core.JSRuntime) void {
        for (self.items) |item| rt.memory.allocator.free(item);
        rt.memory.allocator.free(self.items);
        rt.memory.allocator.free(self.c_argv);
    }
};

fn osExecArgv(rt: *core.JSRuntime, args: []const core.JSValue) HostError!OsExecArgv {
    if (args.len < 1) return error.TypeError;
    const source = try expectObjectArg(args[0]);
    const length_value = source.getProperty(core.atom.ids.length);
    defer length_value.free(rt);
    const length = try hostResult(value_ops.toIndexUsize(rt, length_value));
    if (length < 1 or length > 65535) return error.TypeError;
    const out = try rt.memory.allocator.alloc([:0]u8, length);
    errdefer rt.memory.allocator.free(out);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |item| rt.memory.allocator.free(item);
    }
    var index: usize = 0;
    while (index < length) : (index += 1) {
        const item = source.getProperty(core.atom.atomFromUInt32(@intCast(index)));
        defer item.free(rt);
        const text = try hostStringFromValue(rt, item);
        defer rt.memory.allocator.free(text);
        out[index] = try rt.memory.allocator.dupeZ(u8, text);
        initialized += 1;
    }
    const c_argv = try rt.memory.allocator.alloc(?[*:0]u8, length + 1);
    errdefer rt.memory.allocator.free(c_argv);
    for (out, 0..) |item, idx| c_argv[idx] = item.ptr;
    c_argv[length] = null;
    return .{ .items = out, .c_argv = c_argv };
}

const OsExecEnv = struct {
    items: ?[][:0]u8,
    c_envp: ?[]?[*:0]u8,

    const empty: OsExecEnv = .{ .items = null, .c_envp = null };

    fn deinit(self: OsExecEnv, rt: *core.JSRuntime) void {
        if (self.items) |items| {
            for (items) |item| rt.memory.allocator.free(item);
            rt.memory.allocator.free(items);
        }
        if (self.c_envp) |envp| rt.memory.allocator.free(envp);
    }
};

fn osOptionalEnvOption(rt: *core.JSRuntime, options: *core.Object, name: []const u8) HostError!OsExecEnv {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const value = options.getProperty(key);
    defer value.free(rt);
    if (value.isUndefined()) return OsExecEnv.empty;
    const object = try expectObjectArg(value);
    const keys = try hostResult(object.ownKeys(rt));
    defer core.Object.freeKeys(rt, keys);
    var items = std.ArrayList([:0]u8).empty;
    errdefer {
        for (items.items) |item| rt.memory.allocator.free(item);
        items.deinit(rt.memory.allocator);
    }
    for (keys) |env_key| {
        if (rt.atoms.kind(env_key) != .string) continue;
        const desc = object.getOwnProperty(env_key) orelse continue;
        defer desc.destroy(rt);
        if (desc.enumerable != true) continue;
        const name_value = try rt.atoms.toStringValue(rt, env_key);
        defer name_value.free(rt);
        const env_name = try hostStringFromValue(rt, name_value);
        defer rt.memory.allocator.free(env_name);
        const env_value_raw = object.getProperty(env_key);
        defer env_value_raw.free(rt);
        const env_value = try hostStringFromValue(rt, env_value_raw);
        defer rt.memory.allocator.free(env_value);
        const pair = try std.fmt.allocPrint(rt.memory.allocator, "{s}={s}", .{ env_name, env_value });
        defer rt.memory.allocator.free(pair);
        const item = try rt.memory.allocator.dupeZ(u8, pair);
        errdefer rt.memory.allocator.free(item);
        try items.append(rt.memory.allocator, item);
    }
    const owned = try items.toOwnedSlice(rt.memory.allocator);
    errdefer {
        for (owned) |item| rt.memory.allocator.free(item);
        rt.memory.allocator.free(owned);
    }
    const c_envp = try rt.memory.allocator.alloc(?[*:0]u8, owned.len + 1);
    errdefer rt.memory.allocator.free(c_envp);
    for (owned, 0..) |item, idx| c_envp[idx] = item.ptr;
    c_envp[owned.len] = null;
    return .{ .items = owned, .c_envp = c_envp };
}

fn osBoolOption(rt: *core.JSRuntime, options: *core.Object, name: []const u8, default: bool) HostError!bool {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const value = options.getProperty(key);
    defer value.free(rt);
    if (value.isUndefined()) return default;
    return value_ops.isTruthy(value);
}

fn osOptionalStringOption(rt: *core.JSRuntime, options: *core.Object, name: []const u8) HostError!?[]u8 {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const value = options.getProperty(key);
    defer value.free(rt);
    if (value.isUndefined()) return null;
    const out = try hostStringFromValue(rt, value);
    return out;
}

fn osOptionalIntOption(rt: *core.JSRuntime, options: *core.Object, name: []const u8) HostError!?i32 {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const value = options.getProperty(key);
    defer value.free(rt);
    if (value.isUndefined()) return null;
    const number = try hostResult(value_ops.toIntegerOrInfinity(rt, value));
    if (!std.math.isFinite(number) or std.math.isNan(number)) return 0;
    const integer = if (number < 0) -@floor(@abs(number)) else @floor(number);
    const wrapped: u32 = @intFromFloat(@mod(integer, 4294967296));
    return @bitCast(wrapped);
}

fn osOptionalGroupsOption(rt: *core.JSRuntime, options: *core.Object, name: []const u8, out: *[64]libc.gid_t) HostError!?i32 {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const value = options.getProperty(key);
    defer value.free(rt);
    if (value.isUndefined()) return null;
    const source = try expectObjectArg(value);
    const length_value = source.getProperty(core.atom.ids.length);
    defer length_value.free(rt);
    const length = try hostResult(value_ops.toIndexUsize(rt, length_value));
    var count: usize = 0;
    var index: usize = 0;
    while (index < length) : (index += 1) {
        const item = source.getProperty(core.atom.atomFromUInt32(@intCast(index)));
        defer item.free(rt);
        if (item.isUndefined()) continue;
        if (count == out.len) return error.RangeError;
        const number = try hostResult(value_ops.toIntegerOrInfinity(rt, item));
        if (!std.math.isFinite(number) or std.math.isNan(number)) return error.TypeError;
        const integer = if (number < 0) -@floor(@abs(number)) else @floor(number);
        const wrapped: u32 = @intFromFloat(@mod(integer, 4294967296));
        out[count] = @intCast(wrapped);
        count += 1;
    }
    return @intCast(count);
}



fn hostCallTest262AgentSetTimeout(call: HostCall) HostError!core.JSValue {
    return hostCallOsSetTimer(call, false);
}

fn hostIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn stdFileOrNull(rt: *core.JSRuntime, global: *core.Object, maybe_file: ?*std.c.FILE, is_popen: bool) !core.JSValue {
    const file = maybe_file orelse return core.JSValue.nullValue();
    return createStdFileValue(rt, global, file, is_popen, false);
}

fn closeStdFileHandle(file: *std.c.FILE, is_popen: bool) void {
    if (is_popen) {
        _ = pclose(file);
    } else {
        _ = std.c.fclose(file);
    }
}

pub fn createStdFileValue(rt: *core.JSRuntime, global: ?*core.Object, file: *std.c.FILE, is_popen: bool, is_stdio: bool) !core.JSValue {
    var file_owned = !is_stdio;
    errdefer if (file_owned) {
        closeStdFileHandle(file, is_popen);
    };

    const object = try core.Object.create(rt, core.class.ids.std_file, if (global) |global_object| stdFilePrototype(rt, global_object) else null);
    errdefer object.value().free(rt);
    object.stdFileSlot().* = file;
    object.stdFileIsPopenSlot().* = is_popen;
    object.stdFileIsStdioSlot().* = is_stdio;
    file_owned = false;
    return object.value();
}


fn stdFileObject(call: HostCall) HostError!*core.Object {
    const active_global = try activeGlobalObject(call.ctx.runtime, call.global, call.globals) orelse return error.TypeError;
    const object = thisObject(call.this_value) orelse {
        _ = try hostResult(shared_vm.throwTypeErrorMessage(call.ctx, active_global, "invalid file handle"));
        return error.TypeError;
    };
    if (object.class_id != core.class.ids.std_file or object.stdFile() == null) {
        _ = try hostResult(shared_vm.throwTypeErrorMessage(call.ctx, active_global, "invalid file handle"));
        return error.TypeError;
    }
    return object;
}

fn stdFileHandle(call: HostCall) HostError!*std.c.FILE {
    return (try stdFileObject(call)).stdFile().?;
}

const FileRange = struct {
    pos: usize,
    len: usize,
};

fn stdFileRange(rt: *core.JSRuntime, args: []const core.JSValue, size: usize) HostError!FileRange {
    var pos: usize = 0;
    if (args.len > 1) pos = try hostResult(value_ops.toIndexUsize(rt, args[1]));
    var len: usize = 0;
    if (args.len > 2) len = try hostResult(value_ops.toIndexUsize(rt, args[2]));
    if (pos > size) pos = size;
    if (args.len < 3) len = size - pos;
    if (len > size - pos) len = size - pos;
    return .{ .pos = pos, .len = len };
}

fn stdFileArrayBufferArg(args: []const core.JSValue, index: usize) ?[]u8 {
    if (index >= args.len) return null;
    const object = thisObject(args[index]) orelse return null;
    if (object.class_id != core.class.ids.array_buffer) return null;
    if (object.arrayBufferDetached()) return null;
    return object.byteStorage();
}

fn readRemainingFileBytes(call: HostCall) HostError![]u8 {
    const file = try stdFileHandle(call);
    const max_size = if (call.args.len >= 1 and !call.args[0].isUndefined())
        try hostResult(value_ops.toIndexUsize(call.ctx.runtime, call.args[0]))
    else
        std.math.maxInt(usize);
    var bytes = std.ArrayList(u8).empty;
    errdefer bytes.deinit(call.ctx.runtime.memory.allocator);
    var remaining = max_size;
    while (remaining != 0) : (remaining -= 1) {
        const c = fgetc(file);
        if (c == -1) break;
        try bytes.append(call.ctx.runtime.memory.allocator, @intCast(c));
    }
    return bytes.toOwnedSlice(call.ctx.runtime.memory.allocator);
}

fn stdUrlGetBoolOption(rt: *core.JSRuntime, args: []const core.JSValue, name: []const u8) !bool {
    if (args.len < 2 or args[1].isUndefined() or args[1].isNull()) return false;
    const options = try expectObjectArg(args[1]);
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const value = options.getProperty(key);
    defer value.free(rt);
    return !value.isUndefined() and value_ops.isTruthy(value);
}

fn stdUrlGetCurlCommand(rt: *core.JSRuntime, url: []const u8) ![:0]u8 {
    var command = std.ArrayList(u8).empty;
    errdefer command.deinit(rt.memory.allocator);
    try command.appendSlice(rt.memory.allocator, "curl -s -i -- '");
    for (url) |byte| {
        switch (byte) {
            '\'' => try command.appendSlice(rt.memory.allocator, "'\\''"),
            '[', ']', '{', '}', '\\' => {
                try command.append(rt.memory.allocator, '\\');
                try command.append(rt.memory.allocator, byte);
            },
            else => try command.append(rt.memory.allocator, byte),
        }
    }
    try command.append(rt.memory.allocator, '\'');
    return command.toOwnedSliceSentinel(rt.memory.allocator, 0);
}

fn stdUrlGetReadHeaders(rt: *core.JSRuntime, file: *std.c.FILE, response_headers: *std.ArrayList(u8), status: *i32) !bool {
    const status_line = try stdUrlGetReadLine(rt, file) orelse return false;
    defer rt.memory.allocator.free(status_line);
    status.* = stdUrlGetStatusCode(status_line) orelse return false;

    while (true) {
        const line = try stdUrlGetReadLine(rt, file) orelse return false;
        defer rt.memory.allocator.free(line);
        if (stdUrlGetBlankHeaderLine(line)) break;
        try response_headers.appendSlice(rt.memory.allocator, line);
        try response_headers.append(rt.memory.allocator, '\n');
    }
    return true;
}

fn stdUrlGetReadLine(rt: *core.JSRuntime, file: *std.c.FILE) !?[]u8 {
    var line = std.ArrayList(u8).empty;
    errdefer line.deinit(rt.memory.allocator);
    while (true) {
        const c = fgetc(file);
        if (c == -1) {
            if (line.items.len == 0) {
                line.deinit(rt.memory.allocator);
                return null;
            }
            break;
        }
        if (c == '\n') break;
        try line.append(rt.memory.allocator, @intCast(c));
    }
    const out = try line.toOwnedSlice(rt.memory.allocator);
    return out;
}

fn stdUrlGetStatusCode(line: []const u8) ?i32 {
    const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    var index = first_space + 1;
    while (index < line.len and line[index] == ' ') : (index += 1) {}
    var value: i32 = 0;
    var digits: usize = 0;
    while (index < line.len and std.ascii.isDigit(line[index])) : (index += 1) {
        value = value * 10 + @as(i32, @intCast(line[index] - '0'));
        digits += 1;
    }
    return if (digits == 0) null else value;
}

fn stdUrlGetBlankHeaderLine(line: []const u8) bool {
    return line.len == 0 or (line.len == 1 and line[0] == '\r');
}

fn stdUrlGetReadBody(rt: *core.JSRuntime, file: *std.c.FILE) ![]u8 {
    var bytes = std.ArrayList(u8).empty;
    errdefer bytes.deinit(rt.memory.allocator);
    while (true) {
        const c = fgetc(file);
        if (c == -1) break;
        try bytes.append(rt.memory.allocator, @intCast(c));
    }
    return bytes.toOwnedSlice(rt.memory.allocator);
}

fn stdArrayBufferFromBytes(rt: *core.JSRuntime, global: *core.Object, bytes: []const u8) !core.JSValue {
    const proto = shared_vm.constructorPrototypeFromGlobal(rt, global, "ArrayBuffer");
    const buffer_value = try builtins.buffer.arrayBufferConstructLength(rt, bytes.len, null, proto);
    const object = expectObjectArg(buffer_value) catch unreachable;
    if (bytes.len != 0) @memcpy(object.byteStorageSlot().*[0..bytes.len], bytes);
    return buffer_value;
}

fn formatPrintfBytes(call: HostCall) HostError![]u8 {
    const rt = call.ctx.runtime;
    const active_global = try activeGlobalObject(rt, call.global, call.globals) orelse return error.TypeError;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(rt.memory.allocator);
    if (call.args.len == 0) return out.toOwnedSlice(rt.memory.allocator);

    const format = try hostStringFromValue(rt, call.args[0]);
    defer rt.memory.allocator.free(format);

    var arg_index: usize = 1;
    var index: usize = 0;
    while (index < format.len) {
        const literal_start = index;
        while (index < format.len and format[index] != '%') : (index += 1) {}
        if (index > literal_start) try out.appendSlice(rt.memory.allocator, format[literal_start..index]);
        if (index >= format.len) break;

        var fmt_buf: [64:0]u8 = undefined;
        var fmt_len: usize = 0;
        fmt_buf[fmt_len] = '%';
        fmt_len += 1;
        index += 1;

        while (index < format.len and isPrintfFlag(format[index])) : (index += 1) {
            if (fmt_len >= fmt_buf.len - 1) return printfInvalidFormat(call, active_global);
            fmt_buf[fmt_len] = format[index];
            fmt_len += 1;
        }

        if (index < format.len and format[index] == '*') {
            const width = try printfInt32Argument(call, active_global, &arg_index);
            const width_text = try std.fmt.bufPrint(fmt_buf[fmt_len .. fmt_buf.len - 1], "{d}", .{width});
            fmt_len += width_text.len;
            index += 1;
        } else {
            while (index < format.len and std.ascii.isDigit(format[index])) : (index += 1) {
                if (fmt_len >= fmt_buf.len - 1) return printfInvalidFormat(call, active_global);
                fmt_buf[fmt_len] = format[index];
                fmt_len += 1;
            }
        }

        if (index < format.len and format[index] == '.') {
            if (fmt_len >= fmt_buf.len - 1) return printfInvalidFormat(call, active_global);
            fmt_buf[fmt_len] = '.';
            fmt_len += 1;
            index += 1;
            if (index < format.len and format[index] == '*') {
                const precision = try printfInt32Argument(call, active_global, &arg_index);
                const precision_text = try std.fmt.bufPrint(fmt_buf[fmt_len .. fmt_buf.len - 1], "{d}", .{precision});
                fmt_len += precision_text.len;
                index += 1;
            } else {
                while (index < format.len and std.ascii.isDigit(format[index])) : (index += 1) {
                    if (fmt_len >= fmt_buf.len - 1) return printfInvalidFormat(call, active_global);
                    fmt_buf[fmt_len] = format[index];
                    fmt_len += 1;
                }
            }
        }

        var long_modifier = false;
        if (index < format.len and format[index] == 'l') {
            long_modifier = true;
            if (fmt_len >= fmt_buf.len - 1) return printfInvalidFormat(call, active_global);
            fmt_buf[fmt_len] = 'l';
            fmt_len += 1;
            index += 1;
        }

        if (index >= format.len) return printfInvalidFormat(call, active_global);
        const spec = format[index];
        index += 1;
        if (fmt_len >= fmt_buf.len - 1) return printfInvalidFormat(call, active_global);
        fmt_buf[fmt_len] = spec;
        fmt_len += 1;
        fmt_buf[fmt_len] = 0;
        const fmt_z: [*:0]const u8 = fmt_buf[0..].ptr;

        switch (spec) {
            '%' => try out.append(rt.memory.allocator, '%'),
            'c' => {
                const code = try printfInt32Argument(call, active_global, &arg_index);
                var encoded: [4]u8 = undefined;
                const codepoint: u21 = if (code < 0 or code > 0x10ffff) 0xfffd else @intCast(code);
                const len = std.unicode.utf8Encode(codepoint, &encoded) catch 0;
                try out.appendSlice(rt.memory.allocator, encoded[0..len]);
            },
            'd', 'i', 'o', 'u', 'x', 'X' => {
                const value = try printfInt64Argument(call, active_global, &arg_index);
                if (long_modifier)
                    try appendCFormatInt64(rt, &out, fmt_z, value)
                else
                    try appendCFormatInt32(rt, &out, fmt_z, @as(i32, @truncate(value)));
            },
            's' => {
                const text = try printfStringArgument(call, active_global, &arg_index);
                defer rt.memory.allocator.free(text);
                try appendCFormatString(rt, &out, fmt_z, text);
            },
            'e', 'f', 'g', 'a', 'E', 'F', 'G', 'A' => {
                const value = try printfDoubleArgument(call, active_global, &arg_index);
                try appendCFormatDouble(rt, &out, fmt_z, value);
            },
            else => return printfInvalidFormat(call, active_global),
        }
    }
    return out.toOwnedSlice(rt.memory.allocator);
}

fn isPrintfFlag(byte: u8) bool {
    return byte == '0' or byte == '#' or byte == '+' or byte == '-' or byte == ' ' or byte == '\'';
}

fn printfInvalidFormat(call: HostCall, global: *core.Object) HostError {
    _ = try hostResult(shared_vm.throwTypeErrorMessage(call.ctx, global, "invalid conversion specifier in format string"));
    return error.TypeError;
}

fn printfMissingArgument(call: HostCall, global: *core.Object) HostError {
    _ = try hostResult(shared_vm.throwReferenceErrorMessage(call.ctx, global, "missing argument for conversion specifier"));
    return error.ReferenceError;
}

fn printfInt32Argument(call: HostCall, global: *core.Object, arg_index: *usize) HostError!i32 {
    if (arg_index.* >= call.args.len) return printfMissingArgument(call, global);
    const value = try hostInt32Arg(call.ctx.runtime, call.args, arg_index.*);
    arg_index.* += 1;
    return value;
}

fn printfInt64Argument(call: HostCall, global: *core.Object, arg_index: *usize) HostError!i64 {
    if (arg_index.* >= call.args.len) return printfMissingArgument(call, global);
    const value = try hostInt64Arg(call.ctx.runtime, call.args, arg_index.*);
    arg_index.* += 1;
    return value;
}

fn printfDoubleArgument(call: HostCall, global: *core.Object, arg_index: *usize) HostError!f64 {
    if (arg_index.* >= call.args.len) return printfMissingArgument(call, global);
    const value = if (call.args[arg_index.*].isNumber())
        value_ops.numberValue(call.args[arg_index.*]).?
    else blk: {
        const number_value = try value_ops.toNumberValue(call.ctx.runtime, call.args[arg_index.*]);
        defer number_value.free(call.ctx.runtime);
        break :blk value_ops.numberValue(number_value) orelse std.math.nan(f64);
    };
    arg_index.* += 1;
    return value;
}

fn printfStringArgument(call: HostCall, global: *core.Object, arg_index: *usize) HostError![]u8 {
    if (arg_index.* >= call.args.len) return printfMissingArgument(call, global);
    const text = try hostStringFromValue(call.ctx.runtime, call.args[arg_index.*]);
    arg_index.* += 1;
    return text;
}

fn appendCFormatInt32(rt: *core.JSRuntime, out: *std.ArrayList(u8), fmt: [*:0]const u8, value: i32) !void {
    var buffer: [256]u8 = undefined;
    const len = snprintf(buffer[0..].ptr, buffer.len, fmt, @as(c_int, value));
    if (try appendSnprintfStackResult(rt, out, &buffer, len)) return;
    const dynamic = try rt.memory.allocator.alloc(u8, @as(usize, @intCast(len)) + 1);
    defer rt.memory.allocator.free(dynamic);
    const dynamic_len = snprintf(dynamic.ptr, dynamic.len, fmt, @as(c_int, value));
    try appendSnprintfDynamicResult(rt, out, dynamic, dynamic_len);
}

fn appendCFormatInt64(rt: *core.JSRuntime, out: *std.ArrayList(u8), fmt: [*:0]const u8, value: i64) !void {
    var buffer: [256]u8 = undefined;
    const len = snprintf(buffer[0..].ptr, buffer.len, fmt, @as(c_longlong, value));
    if (try appendSnprintfStackResult(rt, out, &buffer, len)) return;
    const dynamic = try rt.memory.allocator.alloc(u8, @as(usize, @intCast(len)) + 1);
    defer rt.memory.allocator.free(dynamic);
    const dynamic_len = snprintf(dynamic.ptr, dynamic.len, fmt, @as(c_longlong, value));
    try appendSnprintfDynamicResult(rt, out, dynamic, dynamic_len);
}

fn appendCFormatDouble(rt: *core.JSRuntime, out: *std.ArrayList(u8), fmt: [*:0]const u8, value: f64) !void {
    var buffer: [256]u8 = undefined;
    const len = snprintf(buffer[0..].ptr, buffer.len, fmt, value);
    if (try appendSnprintfStackResult(rt, out, &buffer, len)) return;
    const dynamic = try rt.memory.allocator.alloc(u8, @as(usize, @intCast(len)) + 1);
    defer rt.memory.allocator.free(dynamic);
    const dynamic_len = snprintf(dynamic.ptr, dynamic.len, fmt, value);
    try appendSnprintfDynamicResult(rt, out, dynamic, dynamic_len);
}

fn appendCFormatString(rt: *core.JSRuntime, out: *std.ArrayList(u8), fmt: [*:0]const u8, value: []const u8) !void {
    const value_z = try rt.memory.allocator.dupeZ(u8, value);
    defer rt.memory.allocator.free(value_z);
    var buffer: [256]u8 = undefined;
    const len = snprintf(buffer[0..].ptr, buffer.len, fmt, value_z.ptr);
    if (try appendSnprintfStackResult(rt, out, &buffer, len)) return;
    const dynamic = try rt.memory.allocator.alloc(u8, @as(usize, @intCast(len)) + 1);
    defer rt.memory.allocator.free(dynamic);
    const dynamic_len = snprintf(dynamic.ptr, dynamic.len, fmt, value_z.ptr);
    try appendSnprintfDynamicResult(rt, out, dynamic, dynamic_len);
}

fn appendSnprintfStackResult(rt: *core.JSRuntime, out: *std.ArrayList(u8), buffer: *[256]u8, len: c_int) !bool {
    if (len < 0) return error.SystemError;
    const used: usize = @intCast(len);
    if (used >= buffer.len) return false;
    try out.appendSlice(rt.memory.allocator, buffer[0..used]);
    return true;
}

fn appendSnprintfDynamicResult(rt: *core.JSRuntime, out: *std.ArrayList(u8), buffer: []const u8, len: c_int) !void {
    if (len < 0) return error.SystemError;
    const used: usize = @intCast(len);
    try out.appendSlice(rt.memory.allocator, buffer[0..used]);
}

fn stdFilePrototype(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    if (global.cachedRealmValue(.std_file_prototype)) |existing| {
        if (thisObject(existing)) |proto| return proto;
    }

    const proto = core.Object.create(rt, core.class.ids.object, null) catch return null;
    var proto_owned = true;
    defer if (proto_owned) proto.value().free(rt);
    const names = [_]struct { name: []const u8, kind: HostFunction }{
        .{ .name = "close", .kind = .std_file_close },
        .{ .name = "puts", .kind = .std_file_puts },
        .{ .name = "printf", .kind = .std_file_printf },
        .{ .name = "flush", .kind = .std_file_flush },
        .{ .name = "tell", .kind = .std_file_tell },
        .{ .name = "seek", .kind = .std_file_seek },
        .{ .name = "eof", .kind = .std_file_eof },
        .{ .name = "fileno", .kind = .std_file_fileno },
        .{ .name = "error", .kind = .std_file_error },
        .{ .name = "clearerr", .kind = .std_file_clearerr },
        .{ .name = "read", .kind = .std_file_read },
        .{ .name = "write", .kind = .std_file_write },
        .{ .name = "getline", .kind = .std_file_getline },
        .{ .name = "readAsString", .kind = .std_file_read_as_string },
        .{ .name = "readAsArrayBuffer", .kind = .std_file_read_as_array_buffer },
        .{ .name = "getByte", .kind = .std_file_get_byte },
        .{ .name = "putByte", .kind = .std_file_put_byte },
    };
    for (names) |entry| {
        const method = createNamedHostFunctionValue(rt, entry.name, entry.kind) catch return null;
        defer method.free(rt);
        defineObjectProperty(rt, proto, entry.name, method) catch return null;
    }
    const cached = global.cachedRealmValueSlot(rt, .std_file_prototype) catch return null;
    global.setOptionalValueSlot(rt, cached, proto.value().dup()) catch return null;
    proto.value().free(rt);
    proto_owned = false;
    return proto;
}


fn setStdErrorObject(rt: *core.JSRuntime, args: []const core.JSValue, err: c_int) !void {
    if (args.len < 3) return;
    const object = thisObject(args[2]) orelse return;
    try defineIntProperty(rt, object, "errno", err);
}

fn currentErrno() c_int {
    return @intCast(@intFromEnum(std.c.errno(-1)));
}

fn validStdOpenMode(mode: []const u8) bool {
    for (mode) |byte| {
        if (std.mem.indexOfScalar(u8, "rwa+bx", byte) == null) return false;
    }
    return true;
}

fn validStdFdopenMode(mode: []const u8) bool {
    for (mode) |byte| {
        if (std.mem.indexOfScalar(u8, "rwa+", byte) == null) return false;
    }
    return true;
}

fn performanceNowMs() f64 {
    const ns = std.Io.Clock.Timestamp.now(hostIo(), .awake).raw.toNanoseconds();
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn hostStringArg(rt: *core.JSRuntime, args: []const core.JSValue, index: usize) HostError![]u8 {
    if (index >= args.len) return error.TypeError;
    return hostStringFromValue(rt, args[index]);
}

fn hostStringArgOrUndefined(rt: *core.JSRuntime, args: []const core.JSValue, index: usize) HostError![]u8 {
    const value = if (index < args.len) args[index] else core.JSValue.undefinedValue();
    return hostStringFromValue(rt, value);
}

fn hostInt32Arg(rt: *core.JSRuntime, args: []const core.JSValue, index: usize) HostError!i32 {
    const value = if (index < args.len) args[index] else core.JSValue.undefinedValue();
    const number = try hostResult(value_ops.toIntegerOrInfinity(rt, value));
    if (!std.math.isFinite(number) or std.math.isNan(number)) return 0;
    const integer = if (number < 0) -@floor(@abs(number)) else @floor(number);
    const wrapped: u32 = @intFromFloat(@mod(integer, 4294967296));
    return @bitCast(wrapped);
}

fn hostInt64Arg(rt: *core.JSRuntime, args: []const core.JSValue, index: usize) HostError!i64 {
    const value = if (index < args.len) args[index] else core.JSValue.undefinedValue();
    const number = try hostResult(value_ops.toIntegerOrInfinity(rt, value));
    if (!std.math.isFinite(number) or std.math.isNan(number)) return 0;
    const integer = if (number < 0) -@floor(@abs(number)) else @floor(number);
    return @intFromFloat(integer);
}

fn int64ResultValue(value: i64) core.JSValue {
    if (value >= std.math.minInt(i32) and value <= std.math.maxInt(i32)) {
        return core.JSValue.int32(@intCast(value));
    }
    return value_ops.numberToValue(@floatFromInt(value));
}

fn hostStringFromValue(rt: *core.JSRuntime, value: core.JSValue) HostError![]u8 {
    var bytes = std.ArrayList(u8).empty;
    errdefer bytes.deinit(rt.memory.allocator);
    try hostResult(value_ops.appendValueString(rt, &bytes, value));
    return bytes.toOwnedSlice(rt.memory.allocator);
}

fn hostExitCodeArg(rt: *core.JSRuntime, args: []const core.JSValue) HostError!u8 {
    if (args.len == 0) return 0;
    const number = try hostResult(value_ops.toIntegerOrInfinity(rt, args[0]));
    if (!std.math.isFinite(number) or std.math.isNan(number)) return 0;
    const integer = if (number < 0) -@floor(@abs(number)) else @floor(number);
    const wrapped = @mod(integer, 256);
    return @intFromFloat(wrapped);
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
    var encoded = try hostResult(shared_vm.encodeBase64Bytes(ctx.runtime, bytes.items, .base64, false));
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
    var decoded = shared_vm.decodeBase64Bytes(ctx.runtime, bytes.items, .base64, .loose) catch |err| switch (err) {
        error.SyntaxError => return throwInvalidCharacter(ctx, global, "The string to be decoded is not correctly encoded"),
        else => |other| return other,
    };
    defer decoded.deinit(ctx.runtime.memory.allocator);
    const string = try core.string.String.createAscii(ctx.runtime, decoded.items);
    return string.value();
}

const Latin1StringError = error{ InvalidCharacter, TypeError } || std.mem.Allocator.Error;

fn stringToLatin1Bytes(rt: *core.JSRuntime, value: core.JSValue, max_unit: u16) Latin1StringError!std.ArrayList(u8) {
    const header = value.refHeader() orelse return error.TypeError;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(rt.memory.allocator);
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
    const error_value = try createDOMExceptionValue(ctx.runtime, error_global, "InvalidCharacterError", message);
    _ = ctx.throwValue(error_value);
    return error.InvalidCharacterError;
}

fn createDOMExceptionValue(rt: *core.JSRuntime, global: *core.Object, name: []const u8, message: []const u8) !core.JSValue {
    const ctor_key = try rt.internAtom("DOMException");
    defer rt.atoms.free(ctor_key);
    const ctor_value = global.getProperty(ctor_key);
    defer ctor_value.free(rt);
    if (!ctor_value.isObject()) return try hostResult(shared_vm.createNamedError(rt, global, name, message));
    const proto_value = expectObjectArg(ctor_value) catch return try hostResult(shared_vm.createNamedError(rt, global, name, message));
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
    if (!shared_vm.isCallableValue(callback)) return try hostResult(shared_vm.throwTypeErrorMessage(ctx, active_global, "not a function"));
    try hostResult(shared_vm.enqueuePendingMicrotask(ctx, callback));
    return core.JSValue.undefinedValue();
}

fn globalGc(ctx: *core.JSContext) core.JSValue {
    _ = ctx.runtime.runObjectCycleRemoval();
    return core.JSValue.undefinedValue();
}

fn hostCallAssertSameValue(call: HostCall) HostError!core.JSValue {
    return hostAssertSameValue(call.args);
}

fn hostCallAssertTrue(call: HostCall) HostError!core.JSValue {
    return hostAssertTrue(call.args);
}

fn hostCallAssertNotSameValue(call: HostCall) HostError!core.JSValue {
    return hostAssertNotSameValue(call.args);
}

fn hostCallAssertThrows(call: HostCall) HostError!core.JSValue {
    return hostAssertThrows(call.ctx, call.output, call.globals, call.args);
}

fn hostCallTest262Error(call: HostCall) HostError!core.JSValue {
    _ = call;
    return error.Test262Error;
}

fn hostCallVerifyProperty(call: HostCall) HostError!core.JSValue {
    return hostVerifyProperty(call.ctx.runtime, call.args, false);
}

fn hostCallVerifyCallableProperty(call: HostCall) HostError!core.JSValue {
    return hostVerifyProperty(call.ctx.runtime, call.args, true);
}

fn hostCallIsConstructor(call: HostCall) HostError!core.JSValue {
    return hostIsConstructor(call.ctx.runtime, call.args);
}

fn hostCallVerifyNotWritable(call: HostCall) HostError!core.JSValue {
    return hostVerifyPropertyFlag(call.ctx.runtime, call.args, .not_writable);
}

fn hostCallVerifyNotEnumerable(call: HostCall) HostError!core.JSValue {
    return hostVerifyPropertyFlag(call.ctx.runtime, call.args, .not_enumerable);
}

fn hostCallVerifyConfigurable(call: HostCall) HostError!core.JSValue {
    return hostVerifyPropertyFlag(call.ctx.runtime, call.args, .configurable);
}

fn hostCallCompareArray(call: HostCall) HostError!core.JSValue {
    return hostCompareArray(call.ctx.runtime, call.args);
}

fn hostCallCreateRealm(call: HostCall) HostError!core.JSValue {
    return hostCreateRealm(call.ctx.runtime);
}

fn hostCallEvalScript(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(qjsTest262EvalScript(call.ctx, call.output, global, call.func_obj, call.args));
}

fn hostCallDstrGet(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(shared_vm.qjsDestructuringGet(call.ctx, call.output, global, call.args));
}

fn hostCallDstrElide(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(shared_vm.qjsDestructuringElide(call.ctx, call.output, global, call.args));
}

fn hostCallDstrRest(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(shared_vm.qjsDestructuringRest(call.ctx, call.output, global, call.args));
}

fn hostCallDstrObjectRest(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(shared_vm.qjsDestructuringObjectRest(call.ctx, call.output, global, call.args));
}

fn hostCallDstrClose(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(shared_vm.qjsDestructuringClose(call.ctx, call.output, global, call.args));
}

fn hostCallDstrRequireIterator(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(shared_vm.qjsDestructuringRequireIterator(call.ctx, call.output, global, call.args));
}

fn hostCallUsingCreateDisposableStack(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(shared_vm.qjsUsingCreateDisposableStack(call.ctx, global));
}

fn hostCallUsingAddSyncResource(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(shared_vm.qjsUsingAddSyncResource(call.ctx, call.output, global, call.args));
}

fn hostCallUsingDisposeSyncStack(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(shared_vm.qjsUsingDisposeSyncStack(call.ctx, call.output, global, call.args));
}

fn hostCallUsingDisposeSyncStackForThrow(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(shared_vm.qjsUsingDisposeSyncStackForThrow(call.ctx, call.output, global, call.args));
}

fn hostCallUsingCreateAsyncDisposableStack(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(shared_vm.qjsUsingCreateAsyncDisposableStack(call.ctx, global));
}

fn hostCallUsingAddAsyncResource(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(shared_vm.qjsUsingAddAsyncResource(call.ctx, call.output, global, call.args));
}

fn hostCallUsingDisposeAsyncStack(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(shared_vm.qjsUsingDisposeAsyncStack(call.ctx, call.output, global, call.args));
}

fn hostCallUsingDisposeAsyncStackForThrow(call: HostCall) HostError!core.JSValue {
    const global = call.global orelse call.func_obj.functionRealmGlobalPtr() orelse return error.TypeError;
    return try hostResult(shared_vm.qjsUsingDisposeAsyncStackForThrow(call.ctx, call.output, global, call.args));
}

fn hostCallDetachArrayBuffer(call: HostCall) HostError!core.JSValue {
    return hostDetachArrayBuffer(call.ctx.runtime, call.args);
}

fn hostCallIsHtmlDda(call: HostCall) HostError!core.JSValue {
    _ = call;
    return core.JSValue.nullValue();
}

fn hostAssertSameValue(values: []const core.JSValue) HostError!core.JSValue {
    if (values.len < 2) return error.TypeError;
    if (!@import("../builtins/root.zig").object.sameValue(values[0], values[1])) return error.Test262Error;
    return core.JSValue.undefinedValue();
}

fn hostAssertTrue(values: []const core.JSValue) HostError!core.JSValue {
    if (values.len < 1 or values[0].asBool() != true) return error.Test262Error;
    return core.JSValue.undefinedValue();
}

fn hostAssertNotSameValue(values: []const core.JSValue) HostError!core.JSValue {
    if (values.len < 2) return error.TypeError;
    if (@import("../builtins/root.zig").object.sameValue(values[0], values[1])) return error.Test262Error;
    return core.JSValue.undefinedValue();
}

fn hostAssertThrows(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    globals: []globals_mod.Slot,
    values: []const core.JSValue,
) !core.JSValue {
    if (values.len < 2) return error.TypeError;
    const expected = thisObject(values[0]) orelse return error.Test262Error;
    const expected_name = try nativeFunctionName(ctx.runtime, expected);
    defer ctx.runtime.memory.allocator.free(expected_name);
    const result = callValueWithThisAndGlobals(ctx, output, globals, core.JSValue.undefinedValue(), values[1], &.{}) catch |err| {
        if (errorNameMatchesConstructor(err, expected_name)) {
            ctx.clearException();
            return core.JSValue.undefinedValue();
        }
        return error.Test262Error;
    };
    defer result.free(ctx.runtime);
    return error.Test262Error;
}

fn hostVerifyProperty(rt: *core.JSRuntime, values: []const core.JSValue, callable: bool) HostError!core.JSValue {
    const desc_index: usize = if (callable) 4 else 2;
    if ((!callable and values.len <= desc_index) or (callable and values.len < 4)) return error.TypeError;
    const object = try expectObjectArg(values[0]);
    const key = try atomFromPropertyKey(rt, values[1]);
    defer rt.atoms.free(key);

    var original = object.getOwnProperty(key) orelse if (object.is_global and value_ops.atomNameEql(rt, key, "globalThis")) core.Descriptor.data(object.value().dup(), true, false, true) else {
        if (values[desc_index].isUndefined()) return core.JSValue.boolean(true);
        return error.Test262Error;
    };
    materializeMappedArgumentsDescriptorValue(rt, object, key, &original);
    defer original.destroy(rt);

    if (callable) {
        const actual = object.getProperty(key);
        defer actual.free(rt);
        if (!value_ops.isFunctionObject(actual)) return error.Test262Error;
        const expected_name = try stringBytes(rt, values[2]);
        defer rt.memory.allocator.free(expected_name);
        const function_object = thisObject(actual) orelse return error.Test262Error;
        const actual_name = try nativeFunctionName(rt, function_object);
        defer rt.memory.allocator.free(actual_name);
        if (!std.mem.eql(u8, expected_name, actual_name)) return error.Test262Error;
        const expected_length = values[3].asInt32() orelse return error.Test262Error;
        const length_value = function_object.getProperty(core.atom.ids.length);
        defer length_value.free(rt);
        if (length_value.asInt32() != expected_length) return error.Test262Error;
        if (values.len <= desc_index or values[desc_index].isUndefined()) return core.JSValue.boolean(true);
    }

    const expected_object = try expectObjectArg(values[desc_index]);
    try verifyDescriptorObject(rt, original, expected_object);
    return core.JSValue.boolean(true);
}

fn hostIsConstructor(rt: *core.JSRuntime, values: []const core.JSValue) HostError!core.JSValue {
    if (values.len < 1) return error.TypeError;
    const object = thisObject(values[0]) orelse return core.JSValue.boolean(false);
    if (!value_ops.isFunctionObject(values[0])) return core.JSValue.boolean(false);
    const name = nativeFunctionName(rt, object) catch return core.JSValue.boolean(false);
    defer rt.memory.allocator.free(name);
    return core.JSValue.boolean(isBuiltinConstructorName(name));
}

const VerifyFlag = enum {
    not_writable,
    not_enumerable,
    configurable,
};

fn hostVerifyPropertyFlag(rt: *core.JSRuntime, values: []const core.JSValue, flag: VerifyFlag) HostError!core.JSValue {
    if (values.len < 2) return error.TypeError;
    const object = try expectObjectArg(values[0]);
    const key = try atomFromPropertyKey(rt, values[1]);
    defer rt.atoms.free(key);
    const desc = object.getOwnProperty(key) orelse return error.Test262Error;
    defer desc.destroy(rt);
    switch (flag) {
        .not_writable => if (desc.kind == .data and (desc.writable orelse false)) return error.Test262Error,
        .not_enumerable => if (desc.enumerable orelse false) return error.Test262Error,
        .configurable => if (!(desc.configurable orelse false)) return error.Test262Error,
    }
    return core.JSValue.undefinedValue();
}

fn hostCompareArray(rt: *core.JSRuntime, values: []const core.JSValue) HostError!core.JSValue {
    if (values.len < 2) return error.TypeError;
    const actual = try expectObjectArg(values[0]);
    const expected = try expectObjectArg(values[1]);
    if (!actual.is_array or !expected.is_array) return error.Test262Error;
    if (actual.length != expected.length) return error.Test262Error;
    var index: u32 = 0;
    while (index < actual.length) : (index += 1) {
        const key = core.atom.atomFromUInt32(index);
        const lhs = actual.getProperty(key);
        defer lhs.free(rt);
        const rhs = expected.getProperty(key);
        defer rhs.free(rt);
        if (!builtins.object.sameValue(lhs, rhs)) return error.Test262Error;
    }
    return core.JSValue.undefinedValue();
}

fn verifyDescriptorObject(rt: *core.JSRuntime, actual: core.Descriptor, expected: *core.Object) !void {
    if (try expectedHas(rt, expected, "value")) {
        const expected_value = try expectedValue(rt, expected, "value");
        defer expected_value.free(rt);
        if (!builtins.object.sameValue(actual.value, expected_value)) return error.Test262Error;
    }
    if (try expectedHas(rt, expected, "writable")) {
        const writable_value = try expectedValue(rt, expected, "writable");
        defer writable_value.free(rt);
        const expected_writable = writable_value.asBool() orelse return error.Test262Error;
        if (actual.writable != expected_writable) return error.Test262Error;
    }
    if (try expectedHas(rt, expected, "enumerable")) {
        const enumerable_value = try expectedValue(rt, expected, "enumerable");
        defer enumerable_value.free(rt);
        const expected_enumerable = enumerable_value.asBool() orelse return error.Test262Error;
        if (actual.enumerable != expected_enumerable) return error.Test262Error;
    }
    if (try expectedHas(rt, expected, "configurable")) {
        const configurable_value = try expectedValue(rt, expected, "configurable");
        defer configurable_value.free(rt);
        const expected_configurable = configurable_value.asBool() orelse return error.Test262Error;
        if (actual.configurable != expected_configurable) return error.Test262Error;
    }
    if (try expectedHas(rt, expected, "get")) {
        const expected_getter = try expectedValue(rt, expected, "get");
        defer expected_getter.free(rt);
        if (!builtins.object.sameValue(actual.getter, expected_getter)) return error.Test262Error;
    }
    if (try expectedHas(rt, expected, "set")) {
        const expected_setter = try expectedValue(rt, expected, "set");
        defer expected_setter.free(rt);
        if (!builtins.object.sameValue(actual.setter, expected_setter)) return error.Test262Error;
    }
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
        if (cell.varRefValueSlot().*) |stored| stored.dup() else core.JSValue.undefinedValue()
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

fn varRefCellFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_payload_kind != .var_ref) return null;
    return object;
}

fn descriptorFromObject(rt: *core.JSRuntime, object: *core.Object) !core.Descriptor {
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

    const descriptor_value = try descriptorObject(
        rt,
        core.Descriptor.data(core.JSValue.symbol(symbol_atom), true, true, true),
    );
    var descriptor_alive = true;
    defer if (descriptor_alive) descriptor_value.free(rt);
    const descriptor = thisObject(descriptor_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_key = try rt.internAtom("value");
    defer rt.atoms.free(value_key);
    const stored = descriptor.getProperty(value_key);
    defer stored.free(rt);
    try std.testing.expect(stored.same(core.JSValue.symbol(symbol_atom)));

    descriptor_value.free(rt);
    descriptor_alive = false;
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

fn stringBytes(rt: *core.JSRuntime, value: core.JSValue) ![]u8 {
    if (!value.isString()) return error.TypeError;
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &buffer, value);
    return buffer.toOwnedSlice(rt.memory.allocator);
}

fn defineBoolProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: bool) !void {
    try defineObjectProperty(rt, object, name, core.JSValue.boolean(value));
}

fn expectObjectArg(value: core.JSValue) !*core.Object {
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
        (std.mem.eql(u8, err_name, "Test262Error") and std.mem.eql(u8, constructor_name, "Error")) or
        (std.mem.eql(u8, err_name, "SyntaxError") and std.mem.eql(u8, constructor_name, "SyntaxError")) or
        (std.mem.eql(u8, err_name, "RangeError") and std.mem.eql(u8, constructor_name, "RangeError")) or
        (std.mem.eql(u8, err_name, "EvalError") and std.mem.eql(u8, constructor_name, "EvalError")) or
        (std.mem.eql(u8, err_name, "ReferenceError") and std.mem.eql(u8, constructor_name, "ReferenceError")) or
        (std.mem.eql(u8, err_name, "Test262Error") and std.mem.eql(u8, constructor_name, "Test262Error")) or
        (std.mem.eql(u8, err_name, "Test262Error") and !isBuiltinConstructorName(constructor_name));
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

fn isBuiltinConstructorName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Object") or
        std.mem.eql(u8, name, "Function") or
        std.mem.eql(u8, name, "AsyncFunction") or
        std.mem.eql(u8, name, "GeneratorFunction") or
        std.mem.eql(u8, name, "AsyncGeneratorFunction") or
        std.mem.eql(u8, name, "Array") or
        std.mem.eql(u8, name, "String") or
        std.mem.eql(u8, name, "Number") or
        std.mem.eql(u8, name, "Boolean") or
        std.mem.eql(u8, name, "Symbol") or
        std.mem.eql(u8, name, "BigInt") or
        std.mem.eql(u8, name, "Date") or
        std.mem.eql(u8, name, "RegExp") or
        std.mem.eql(u8, name, "Error") or
        std.mem.eql(u8, name, "SuppressedError") or
        std.mem.eql(u8, name, "EvalError") or
        std.mem.eql(u8, name, "RangeError") or
        std.mem.eql(u8, name, "ReferenceError") or
        std.mem.eql(u8, name, "SyntaxError") or
        std.mem.eql(u8, name, "TypeError") or
        std.mem.eql(u8, name, "URIError") or
        std.mem.eql(u8, name, "Test262Error") or
        std.mem.eql(u8, name, "Iterator") or
        std.mem.eql(u8, name, "DisposableStack") or
        std.mem.eql(u8, name, "AsyncDisposableStack") or
        std.mem.eql(u8, name, "Promise") or
        std.mem.eql(u8, name, "Map") or
        std.mem.eql(u8, name, "Set") or
        std.mem.eql(u8, name, "WeakMap") or
        std.mem.eql(u8, name, "WeakSet") or
        std.mem.eql(u8, name, "ArrayBuffer") or
        std.mem.eql(u8, name, "DataView");
}

fn printArray(rt: *core.JSRuntime, writer: *std.Io.Writer, object: *core.Object) PrintError!void {
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        if (index != 0) try writer.writeByte(',');
        const value = object.getProperty(core.atom.atomFromUInt32(index));
        defer value.free(rt);
        try printValue(rt, writer, value);
    }
}

fn printString(writer: *std.Io.Writer, value: core.JSValue) !void {
    const header = value.refHeader() orelse return writer.writeAll("[string]");
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| try writer.writeAll(bytes),
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

fn isNegativeZero(value: f64) bool {
    return value == 0 and std.math.signbit(value);
}

fn printNativeFunction(rt: *core.JSRuntime, writer: *std.Io.Writer, object: *core.Object) !void {
    if (object.functionSourceSlot().*) |source| {
        try printString(writer, source);
        return;
    }

    const name_key = try rt.internAtom("name");
    defer rt.atoms.free(name_key);
    const name_value = object.getProperty(name_key);
    defer name_value.free(rt);

    try writer.print("function ", .{});
    if (name_value.isString()) try printString(writer, name_value);
    try writer.print("() {{\n    [native code]\n}}", .{});
}

pub fn qjsTest262EvalScript(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len == 0) return core.JSValue.undefinedValue();
    if (!args[0].isString()) return error.TypeError;
    const eval_global = shared_vm.objectRealmGlobal(function_object) orelse global;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(ctx.runtime.memory.allocator);
    try shared_vm.appendSourceStringUtf8(ctx.runtime, &source, args[0]);
    return qjsEvalGlobalScriptSource(ctx, output, eval_global, source.items, "<evalScript>");
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

    var compiled = try frontend.parser.parse(ctx.runtime, source, .{ .mode = .script, .filename = filename, .strict = false, .return_completion = true });
    defer compiled.deinit();
    if (compiled.syntax_error != null) return error.SyntaxError;
    var nested_stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.runtime.stack_size);
    defer nested_stack.deinit(ctx.runtime);
    return zjs_vm.runWithArgsState(ctx, &nested_stack, &compiled.function, global.value(), &.{}, &.{}, output, global, true, false, false, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, null, null, null, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), false, false, core.JSValue.undefinedValue(), true, false) catch |err| {
        return shared_vm.normalizeEvalRuntimeError(err);
    };
}

test "host global bootstrap installs and tears down builtin plus host domains" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    global.is_global = true;
    defer global.value().free(rt);

    try installHostGlobals(rt, global);
}

