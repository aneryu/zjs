//! Bundled print/console formatting and installation.
const zjs = @import("zjs");
const core = zjs.core;
const std = @import("std");
const builtin_dispatch = zjs.exec.builtin_dispatch;
const exception_ops = zjs.exec.exception_ops;
const value_ops = zjs.exec.value_ops;
const HostError = zjs.HostError;

const console_descriptor: core.property.AutoInit = .{
    .name = "console",
    .length = 0,
    .materialize_host = materializeConsole,
};

pub fn install(ctx: *core.JSContext, global: *core.Object) !void {
    try defineOutput(ctx.runtime, global, global, "print");
    try global.defineAutoInitPropertyFromDescriptor(ctx.runtime, core.atom.predefinedId("console", .string).?, core.property.Flags.data(.all), global, &console_descriptor);
}

fn defineOutput(rt: *core.JSRuntime, target: *core.Object, global: *core.Object, name: []const u8) !void {
    return defineOutputWithEntry(rt, target, global, name, &output_host_entry);
}

fn defineOutputWithEntry(rt: *core.JSRuntime, target: *core.Object, global: *core.Object, name: []const u8, entry: *const core.NativeEntry) !void {
    const key = try rt.internAtom(name);
    var roots = core.runtime.rootAtoms(.{&key});
    roots.activate(rt);
    defer roots.deactivate(rt);
    try target.defineHostAutoInitPropertyWithEntry(rt, key, name, 1, core.property.Flags.data(.all), core.host_function.ids.output, false, global, entry);
}

fn materializeConsole(header: *core.gc.Header) !core.JSValue {
    const ctx: *core.JSContext = @alignCast(@fieldParentPtr("header", header));
    const rt = ctx.runtime;
    // Exact slots: a collection inside `defineOutput` may move both objects.
    var roots: core.runtime.ExactValueRoots(1) = .{};
    roots.activate(rt) catch return error.InvalidBuiltinRegistry;
    defer roots.deactivate();
    const global = ctx.global orelse return error.InvalidBuiltinRegistry;
    roots.storage[0] = (try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.object, zjs.exec.object_ops.objectPrototypeFromGlobal(rt, global), 3)).value();
    const Method = struct { name: []const u8, entry: *const core.NativeEntry };
    for ([_]Method{
        .{ .name = "log", .entry = &output_host_entry },
        .{ .name = "warn", .entry = &error_output_host_entry },
        .{ .name = "error", .entry = &error_output_host_entry },
    }) |method| {
        const console = core.Object.fromHeader(roots.storage[0].refHeader().?);
        try defineOutputWithEntry(rt, console, ctx.global orelse return error.InvalidBuiltinRegistry, method.name, method.entry);
    }
    return roots.storage[0];
}

pub const tests = if (@import("builtin").is_test) struct {
    pub fn case0() !void {
        const Factory = struct {
            var attempts: usize = 0;
            fn first(_: *core.gc.Header) zjs.RuntimeError!core.JSValue {
                attempts += 1;
                if (attempts == 1) return error.OutOfMemory;
                return core.JSValue.int32(41);
            }
            fn second(_: *core.gc.Header) zjs.RuntimeError!core.JSValue {
                return core.JSValue.int32(42);
            }
        };
        Factory.attempts = 0;
        const rt = try zjs.Runtime.create(std.testing.allocator, .{});
        defer rt.destroy();
        const ctx = try zjs.Context.create(rt, .{});
        defer ctx.destroy();
        const global = try zjs.globalObjectPtr(ctx);
        const first_key = try rt.internAtom("first");
        const second_key = try rt.internAtom("second");
        var keys = core.runtime.rootAtoms(.{ &first_key, &second_key });
        keys.activate(rt);
        defer keys.deactivate(rt);
        const first: core.property.AutoInit = .{ .name = "host", .length = 0, .materialize_host = Factory.first };
        const second: core.property.AutoInit = .{ .name = "host", .length = 0, .materialize_host = Factory.second };
        try global.defineAutoInitPropertyFromDescriptor(rt, first_key, core.property.Flags.data(.method), global, &first);
        try global.defineAutoInitPropertyFromDescriptor(rt, second_key, core.property.Flags.data(.method), global, &second);
        try std.testing.expectError(error.OutOfMemory, global.getProperty(first_key));
        try std.testing.expectEqual(@as(?i32, 42), (try global.getProperty(second_key)).as(.int));
        try std.testing.expectEqual(@as(?i32, 41), (try global.getProperty(first_key)).as(.int));
        try std.testing.expectEqual(@as(?i32, 41), (try global.getProperty(first_key)).as(.int));
        try std.testing.expectEqual(@as(usize, 2), Factory.attempts);
    }
} else struct {};

/// `console.warn` / `console.error` write to stderr, after flushing stdout so
/// the two streams keep their program order on a shared terminal.
pub const error_output_host_entry: core.NativeEntry = .{
    .target = core.NativeEntry.code(&errorOutputHostThunk),
    .kind = .managed,
    .arity = 1,
};

fn errorOutputHostThunk(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    argv: [*]const core.JSValue,
    argc: u32,
    entry: *const core.NativeEntry,
    func_obj: ?*core.Object,
) callconv(.c) core.JSValue {
    _ = this_value;
    _ = entry;
    _ = func_obj;
    const global = ctx.global orelse return builtin_dispatch.hostErrorToValue(ctx, null, error.InvalidBuiltinRegistry);
    if (builtin_dispatch.vmCallerView(ctx).output) |stdout_writer| {
        stdout_writer.flush() catch |err| return builtin_dispatch.hostErrorToValue(ctx, global, err);
    }
    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(std.Io.Threaded.global_single_threaded.io(), &buffer);
    // Prints go to stderr; user code reached while printing (an inspected
    // getter, Error.prepareStackTrace) keeps the invocation's own writer.
    const result = hostOutputValues(ctx, global, builtin_dispatch.vmCallerView(ctx).output, &stderr_writer.interface, argv[0..argc]) catch |err|
        return builtin_dispatch.hostErrorToValue(ctx, global, err);
    stderr_writer.interface.flush() catch |err| return builtin_dispatch.hostErrorToValue(ctx, global, err);
    return result;
}

/// NB2: `print` and `console.log` share one static managed entry.
/// The host output writer is the active invocation's (`vmCallerView`), so
/// no registry, no per-runtime record, no environment.
pub const output_host_entry: core.NativeEntry = .{
    .target = core.NativeEntry.code(&outputHostThunk),
    .kind = .managed,
    .arity = 1,
};

fn outputHostThunk(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    argv: [*]const core.JSValue,
    argc: u32,
    entry: *const core.NativeEntry,
    func_obj: ?*core.Object,
) callconv(.c) core.JSValue {
    _ = this_value;
    _ = entry;
    _ = func_obj;
    const global = ctx.global orelse return builtin_dispatch.hostErrorToValue(ctx, null, error.InvalidBuiltinRegistry);
    const output = builtin_dispatch.vmCallerView(ctx).output;
    const result = hostOutputValues(ctx, global, output, output, argv[0..argc]) catch |err|
        return builtin_dispatch.hostErrorToValue(ctx, global, err);
    return result;
}

/// Print `values` to `destination`. `caller_output` is the writer user code
/// run during printing uses for its own print() calls.
fn hostOutputValues(
    ctx: *core.JSContext,
    global: *core.Object,
    caller_output: ?*std.Io.Writer,
    destination: ?*std.Io.Writer,
    values: []const core.JSValue,
) HostError!core.JSValue {
    const global_value = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .borrowed = values }, .{ .borrowed = &global_value } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    if (destination) |writer| {
        for (0..values.len) |i| {
            if (i != 0) writer.writeByte(' ') catch |err|
                return exception_ops.throwHostError(ctx, global, err);
            // qjs js_print (quickjs-libc.c:4063): a string argument is
            // written raw; everything else is the JS_PrintValue inspector
            // dump (`{ a: 1 }`, `[Function f]`, `Error: msg` + stack).
            printHostArgument(ctx, global, caller_output, writer, values[i]) catch |err|
                return exception_ops.throwHostError(ctx, global, err);
        }
        writer.writeByte('\n') catch |err|
            return exception_ops.throwHostError(ctx, global, err);
    }
    return core.JSValue.undefinedValue();
}

// ----- Value printer (print / console inspector) -----
// CLI `print` / `console.log` value inspector: the QuickJS `JS_PrintValue`
// dump reproduced byte for byte, so a benchmark
// driver or a test262 harness line reads the same under both shells.
//
// Scope mirrors `js_print` (quickjs-libc.c:4063): a top-level *string*
// argument is written raw by the caller; every other value comes here.
// Defaults are `JS_PrintValueSetDefaultOptions`:
// depth 2, strings cut at 1000 characters, 100 items per container,
// enumerable properties only, no `raw_dump`.
//
// Cold path: only the CLI output builtins reach it. Allocation is limited to
// cold cases: the BigInt decimal text, atom names and UTF-16 name buffers
// longer than 256 bytes, a Date's ISO string, and, for an Error receiver,
// whatever `exception_ops.errorStackGetter` materializes (a freshly built
// `stack` string, and a re-entrant `Error.prepareStackTrace` call when the
// host installed one).
const value_format = core.value_format;
const date_ops = zjs.exec.date_ops;
const regexp_adapter = zjs.exec.regexp_ops;
const dtoa = zjs.libs.number_format;
pub const Error = std.Io.Writer.Error || error{OutOfMemory};
const max_stack_depth: usize = 8;
const default_max_depth: usize = 2;
const default_max_string_length: usize = 1000;
const default_max_item_count: usize = 100;
const State = struct {
    rt: *core.JSRuntime,
    ctx: *core.JSContext,
    global: *core.Object,
    output: ?*std.Io.Writer,
    writer: *std.Io.Writer,
    level: usize = 0,
    print_stack: [max_stack_depth]*const core.Object = undefined,

    fn puts(self: *State, text: []const u8) Error!void {
        try self.writer.writeAll(text);
    }

    fn putc(self: *State, byte: u8) Error!void {
        try self.writer.writeByte(byte);
    }

    fn printf(self: *State, comptime fmt: []const u8, args: anytype) Error!void {
        try self.writer.print(fmt, args);
    }

    fn putUnicodeEscape(self: *State, value: u16) Error!void {
        const digits = value_format.hex4(value);
        try self.puts("\\u");
        try self.puts(&digits);
    }
};
fn makeState(ctx: *core.JSContext, global: *core.Object, output: ?*std.Io.Writer, writer: *std.Io.Writer) State {
    return .{ .rt = ctx.runtime, .ctx = ctx, .global = global, .output = output, .writer = writer };
}

/// One `print` / `console.log` argument (`js_print`, quickjs-libc.c:4063):
/// a top-level string is written raw; every other value is `JS_PrintValue`.
pub fn printHostArgument(ctx: *core.JSContext, global: *core.Object, output: ?*std.Io.Writer, writer: *std.Io.Writer, value: core.JSValue) Error!void {
    const snapshots = [_]core.JSValue{ global.value(), value };
    const slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &snapshots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    var state = makeState(ctx, global, output, writer);
    if (value.isString()) return printRawString(&state, value);
    try printValueRec(&state, value);
}

/// `js_print_float64`: `js_dtoa` free format with
/// `minus_zero`, i.e. Number::toString except that -0 keeps its sign.
fn printFloat64(s: *State, d: f64) Error!void {
    if (std.math.isNan(d)) return s.puts("NaN");
    if (std.math.isPositiveInf(d)) return s.puts("Infinity");
    if (std.math.isNegativeInf(d)) return s.puts("-Infinity");
    if (d == 0) return s.puts(if (std.math.isNegativeZero(d)) "-0" else "0");
    var buf: [64]u8 = undefined;
    try s.puts(core.value_format.formatFiniteNumberAssumeCapacity(&buf, d));
}

/// One UTF-16 code unit source for `js_print_string1`; the same escaper
/// serves flat strings and atom names.
const Units = union(enum) {
    latin1: []const u8,
    utf16: []const u16,
    /// The caller roots this value. Re-read the current representation after
    /// every write: a writer can reenter and materialize a rope.
    string: core.JSValue,

    fn len(self: Units) usize {
        return switch (self) {
            .latin1 => |bytes| bytes.len,
            .utf16 => |units| units.len,
            .string => |value| core.string.stringValueLenUnchecked(value),
        };
    }

    fn at(self: Units, index: usize) u16 {
        return switch (self) {
            .latin1 => |bytes| bytes[index],
            .utf16 => |units| units[index],
            .string => |value| core.string.stringValueCodeUnitAtUnchecked(value, index),
        };
    }
};
/// Escape and print the first `len` units for a `"`-quoted string.
fn printUnits(s: *State, units: Units, len: usize) Error!void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        var c: u32 = units.at(i);
        const escaped: ?u8 = switch (c) {
            '\t' => 't',
            '\r' => 'r',
            '\n' => 'n',
            0x08 => 'b',
            0x0c => 'f',
            '\\' => '\\',
            else => null,
        };
        if (escaped) |e| {
            try s.putc('\\');
            try s.putc(e);
            continue;
        }
        if (c == '"') {
            try s.putc('\\');
            try s.putc(@intCast(c));
            continue;
        }
        if (c >= 32 and c <= 126) {
            try s.putc(@intCast(c));
            continue;
        }
        if (c < 32 or (c >= 0x7f and c <= 0x9f)) {
            try s.putUnicodeEscape(@intCast(c));
            continue;
        }
        if (std.unicode.utf16IsHighSurrogate(@intCast(c))) {
            if (i + 1 >= len) {
                try s.putUnicodeEscape(@intCast(c));
                continue;
            }
            const c1: u32 = units.at(i + 1);
            if (!std.unicode.utf16IsLowSurrogate(@intCast(c1))) {
                try s.putUnicodeEscape(@intCast(c));
                continue;
            }
            i += 1;
            c = 0x10000 + (((c & 0x3ff) << 10) | (c1 & 0x3ff));
        } else if (std.unicode.utf16IsLowSurrogate(@intCast(c))) {
            try s.putUnicodeEscape(@intCast(c));
            continue;
        }
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(c), &utf8) catch unreachable;
        try s.puts(utf8[0..n]);
    }
}

/// `js_print_string`: quoted, escaped, cut at
/// `max_string_length` with the `... N more characters` tail.
fn printString(s: *State, value: core.JSValue) Error!void {
    const units = Units{ .string = value };
    const total = units.len();
    const shown = @min(total, default_max_string_length);
    try s.putc('"');
    try printUnits(s, units, shown);
    try s.putc('"');
    if (total > default_max_string_length) {
        const n = total - default_max_string_length;
        try s.printf("... {d} more character{s}", .{ n, if (n > 1) "s" else "" });
    }
}

/// `js_print_raw_string`: the string text as-is.
fn printRawString(s: *State, value: core.JSValue) Error!void {
    std.debug.assert(value.isString());
    const snapshot = [_]core.JSValue{value};
    const slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &snapshot }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(s.rt);
    defer roots.deactivate(s.rt);
    const units = Units{ .string = value };
    var index: usize = 0;
    while (index < units.len()) try putUnitRaw(s, nextCodePoint(units, &index));
}

/// The code point at `index.*`, pairing a surrogate pair, and advance past
/// it. A lone surrogate is returned as is.
fn nextCodePoint(units: Units, index: *usize) u32 {
    const unit: u32 = units.at(index.*);
    index.* += 1;
    if (std.unicode.utf16IsHighSurrogate(@intCast(unit)) and index.* < units.len()) {
        const low: u32 = units.at(index.*);
        if (std.unicode.utf16IsLowSurrogate(@intCast(low))) {
            index.* += 1;
            return 0x10000 + (((unit & 0x3ff) << 10) | (low & 0x3ff));
        }
    }
    return unit;
}

/// `is_ascii_ident`: bare key or quoted key.
fn isAsciiIdent(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes, 0..) |c, i| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$' or
            (c >= '0' and c <= '9' and i > 0);
        if (!ok) return false;
    }
    return true;
}

/// `js_print_atom`. Atom names are stored as UTF-8;
/// the quoted arm re-encodes to UTF-16 units so the escaper sees what qjs
/// sees (`\u00xx` for U+007F..U+009F, raw UTF-8 above).
fn printAtom(s: *State, atom_id: core.Atom) Error!void {
    if (atom_id.isTaggedInt()) return s.printf("{d}", .{atom_id.toUInt32()});
    if (atom_id == core.atom.null_atom) return s.puts("<null>");
    const name = s.rt.atoms.name(atom_id) orelse "";
    var buffer: [256]u8 = undefined;
    if (name.len <= buffer.len) {
        @memcpy(buffer[0..name.len], name);
        return printNameBytes(s, buffer[0..name.len]);
    }
    const snapshot = try s.rt.nativeAllocator().dupe(u8, name);
    defer s.rt.nativeAllocator().free(snapshot);
    try printNameBytes(s, snapshot);
}

/// The bare-or-quoted tail of `js_print_atom` on a UTF-8 name.
fn printNameBytes(s: *State, bytes: []const u8) Error!void {
    if (isAsciiIdent(bytes)) return s.puts(bytes);
    try s.putc('"');
    // `wtf8ToWtf16Le` does not bound its output; UTF-16 never needs more
    // units than the UTF-8 input has bytes.
    var stack_units: [256]u16 = undefined;
    const allocator = s.rt.nativeAllocator();
    const units_buf = if (bytes.len <= stack_units.len)
        stack_units[0..bytes.len]
    else
        try allocator.alloc(u16, bytes.len);
    defer if (units_buf.ptr != &stack_units) allocator.free(units_buf);
    // Atom names are WTF-8: a lone surrogate prints as its `\uXXXX` escape.
    if (std.unicode.wtf8ToWtf16Le(units_buf, bytes)) |n| {
        try printUnits(s, .{ .utf16 = units_buf[0..n] }, n);
    } else |_| {
        // Malformed names: escape byte-wise without the surrogate pairing;
        // the byte view still quotes and escapes every ASCII case.
        try printUnits(s, .{ .latin1 = bytes }, bytes.len);
    }
    try s.putc('"');
}

/// `rt->class_array[class_id].class_name` through `js_print_atom`. The zjs
/// class table names only the classes of `standard_classes`; the rest carry
/// the qjs `js_async_class_def` / WeakRef / FinalizationRegistry names here,
/// Proxy is registered under `Object` in qjs (quickjs.c JS_CLASS_PROXY), and
/// the zjs-only classes take the obvious name (not verified against qjs).
fn printClassName(s: *State, class_id: core.class.ClassId) Error!void {
    if (s.rt.classes.className(class_id)) |name_atom| {
        if (name_atom != core.atom.null_atom) return printAtom(s, name_atom);
    }
    const fallback: []const u8 = switch (class_id) {
        core.class.ids.proxy, core.class.ids.global_object, core.class.ids.module_ns => "Object",
        core.class.ids.promise => "Promise",
        core.class.ids.promise_resolve_function => "PromiseResolveFunction",
        core.class.ids.promise_reject_function => "PromiseRejectFunction",
        core.class.ids.async_function => "AsyncFunction",
        core.class.ids.async_function_resolve => "AsyncFunctionResolve",
        core.class.ids.async_function_reject => "AsyncFunctionReject",
        core.class.ids.async_from_sync_iterator => "",
        core.class.ids.async_generator_function => "AsyncGeneratorFunction",
        core.class.ids.async_generator => "AsyncGenerator",
        core.class.ids.weak_ref => "WeakRef",
        core.class.ids.finalization_registry => "FinalizationRegistry",
        core.class.ids.call_site => "CallSite",
        core.class.ids.raw_json => "RawJSON",
        core.class.ids.disposable_stack => "DisposableStack",
        core.class.ids.async_disposable_stack => "AsyncDisposableStack",
        else => return s.puts("<null>"),
    };
    try printNameBytes(s, fallback);
}

/// `js_print_comma`: 0 = first item, 1 = `, `, 2 = the
/// `[Function f]` / regexp / error heads that open ` { ` only if a property
/// follows.
fn printComma(s: *State, comma_state: *u8) Error!void {
    switch (comma_state.*) {
        0 => {},
        1 => try s.puts(", "),
        else => try s.puts(" { "),
    }
    comma_state.* = 1;
}

/// `js_print_more_items`.
fn printMoreItems(s: *State, comma_state: *u8, n: usize) Error!void {
    try printComma(s, comma_state);
    try s.printf("... {d} more item{s}", .{ n, if (n > 1) "s" else "" });
}

/// `get_prop_string`: an own plain data string property, or
/// the same one level up the prototype (the Error `name` case).
fn ownOrProtoDataString(object: *const core.Object, atom_id: core.Atom) ?core.JSValue {
    var owner: ?*const core.Object = object;
    var hops: usize = 0;
    while (owner) |current| : (hops += 1) {
        if (current.findProperty(atom_id)) |index| {
            // zjs keeps the intrinsic prototypes' `name` as a lazy auto_init
            // slot where qjs has a plain
            // value; materialising through the own read is the same
            // data-property answer qjs sees.
            const value = if (current.isAutoInitAt(index))
                current.getProperty(atom_id) catch return null
            else
                current.asDataAt(index) orelse return null;
            if (!value.isString()) return null;
            return value;
        }
        if (hops == 1) return null;
        owner = current.getPrototype();
    }
    return null;
}

/// `js_print_regexp`: the pattern with `/`, line
/// terminators and the `[/]` bracket case escaped, then the flag letters in
/// the `lre` bit order (g i m s u y d, then `v` for unicode-sets).
fn printRegExp(s: *State, object: *const core.Object) Error!void {
    const regexp_bc = object.regexpCompiledBytecode();
    const source = object.regexpSource() orelse return s.puts("[uninitialized_regexp]");
    if (regexp_bc.len == 0 or !source.isString()) return s.puts("[uninitialized_regexp]");
    const snapshot = [_]core.JSValue{source};
    const slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &snapshot }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(s.rt);
    defer roots.deactivate(s.rt);
    const units = Units{ .string = source };
    const flags = regexp_adapter.flagsFromBytecode(regexp_bc);
    const n = units.len();
    try s.putc('/');
    if (n == 0) {
        try s.puts("(?:)");
    } else {
        var bra = false;
        var i: usize = 0;
        while (i < n) {
            var c = nextCodePoint(units, &i);
            var c2: ?u32 = null;
            switch (c) {
                '\\' => {
                    if (i < n) {
                        c2 = units.at(i);
                        i += 1;
                    }
                },
                ']' => bra = false,
                '[' => {
                    if (!bra) {
                        if (i < n and units.at(i) == ']') {
                            c2 = units.at(i);
                            i += 1;
                        }
                        bra = true;
                    }
                },
                '\n' => {
                    c = '\\';
                    c2 = 'n';
                },
                '\r' => {
                    c = '\\';
                    c2 = 'r';
                },
                '/' => {
                    if (!bra) {
                        c = '\\';
                        c2 = '/';
                    }
                },
                else => {},
            }
            try putUnitRaw(s, c);
            if (c2) |unit| try putUnitRaw(s, unit);
        }
    }
    try s.putc('/');
    const letters = [_]struct { byte: u8, field: std.meta.FieldEnum(regexp_adapter.Flags) }{
        .{ .byte = 'g', .field = .global },
        .{ .byte = 'i', .field = .ignore_case },
        .{ .byte = 'm', .field = .multiline },
        .{ .byte = 's', .field = .dot_all },
        .{ .byte = 'u', .field = .unicode },
        .{ .byte = 'y', .field = .sticky },
        .{ .byte = 'd', .field = .indices },
        .{ .byte = 'v', .field = .unicode_sets },
    };
    inline for (letters) |letter| {
        if (@field(flags, @tagName(letter.field))) try s.putc(letter.byte);
    }
}

/// `js_putc` on a code point: qjs writes the unit's low byte; a non-ASCII
/// code point is emitted as UTF-8 instead of a stray byte, and a lone
/// surrogate as U+FFFD.
fn putUnitRaw(s: *State, c: u32) Error!void {
    if (c < 0x80) return s.putc(@intCast(c));
    var utf8: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(c), &utf8) catch return s.puts("\u{FFFD}");
    try s.puts(utf8[0..n]);
}

/// `js_print_error`: `Name: message` then the
/// `stack` text on its own line, trailing newline dropped.
fn printError(s: *State, object: *const core.Object) Error!void {
    var values = [_]core.JSValue{ core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(s.rt);
    defer roots.deactivate(s.rt);
    if (ownOrProtoDataString(object, core.atom.ids.name)) |name| {
        try printRawString(s, name);
    } else {
        try s.puts("Error");
    }
    if (ownOrProtoDataString(object, core.atom.ids.message)) |message| {
        values[0] = message;
        if (core.string.stringValueLenUnchecked(message) != 0) {
            try s.puts(": ");
            try printRawString(s, values[0]);
        }
    }
    // zjs keeps `stack` as a native accessor on Error.prototype (V8 shape)
    // where qjs stores an own data property; the accessor's answer is the
    // same captured text, so read it through the native getter when no own
    // data `stack` shadows it.
    const stack_value: ?core.JSValue = ownOrProtoDataString(object, core.atom.ids.stack) orelse blk: {
        const got = exception_ops.errorStackGetter(s.ctx, s.output, s.global, @constCast(object).value()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                // A throwing stack formatter must not leave its exception
                // pending behind the printer: print the error without it.
                // An uncatchable interrupt stays pending for the caller.
                if (s.ctx.hasException() and !s.ctx.exceptionIsUncatchable()) s.ctx.clearException();
                break :blk null;
            },
        };
        break :blk if (got.isString()) got else null;
    };
    if (stack_value) |stack| {
        values[1] = stack;
        try s.putc('\n');
        const units = Units{ .string = values[1] };
        var len = units.len();
        if (len > 0 and units.at(len - 1) == '\n') len -= 1;
        var i: usize = 0;
        while (i < len) try putUnitRaw(s, nextCodePoint(units, &i));
    }
}

fn isTypedArrayClass(class_id: core.class.ClassId) bool {
    return class_id >= core.class.ids.uint8c_array and class_id <= core.class.ids.float64_array;
}

/// The `rt->class_array[class_id].call != NULL && class_id != JS_CLASS_PROXY`
/// test: every class qjs registers with a call handler.
fn isCallableClass(class_id: core.class.ClassId) bool {
    return switch (class_id) {
        core.class.ids.c_function,
        core.class.ids.bytecode_function,
        core.class.ids.bound_function,
        core.class.ids.c_function_data,
        core.class.ids.generator_function,
        core.class.ids.async_function,
        core.class.ids.async_generator_function,
        core.class.ids.promise_resolve_function,
        core.class.ids.promise_reject_function,
        core.class.ids.async_function_resolve,
        core.class.ids.async_function_reject,
        => true,
        else => false,
    };
}

/// `js_print_object`.
fn printObject(s: *State, object: *const core.Object) Error!void {
    var comma_state: u8 = 0;
    var is_array = false;
    const class_id = object.class_id;

    if (class_id == core.class.ids.array) {
        is_array = true;
        try s.puts("[ ");
        if (object.flags.fast_array) {
            // Printing an element can run JS (Error.prepareStackTrace), which
            // may grow, shrink or de-densify this array: re-read the storage
            // for every element instead of iterating a stale slice.
            var shown: usize = 0;
            while (shown < default_max_item_count) : (shown += 1) {
                const elements = object.arrayElements();
                if (shown >= elements.len) break;
                try printComma(s, &comma_state);
                try printValueRec(s, elements[shown]);
            }
            const count = object.arrayElements().len;
            const len: usize = object.arrayLength();
            if (shown < count) try printMoreItems(s, &comma_state, count - shown);
            if (count < len) {
                const n = len - count;
                try printComma(s, &comma_state);
                try s.printf("<{d} empty item{s}>", .{ n, if (n > 1) "s" else "" });
            }
        }
    } else if (isTypedArrayClass(class_id)) {
        const payload = object.typedArrayPayloadFast();
        const count: usize = if (payload) |p| p.live_length else 0;
        try printClassName(s, class_id);
        try s.printf("({d}) [ ", .{count});
        is_array = true;
        const shown = @min(count, default_max_item_count);
        if (payload) |p| {
            if (p.data) |data| {
                const size: usize = p.element_size;
                for (0..shown) |i| {
                    const ptr = data + i * size;
                    try printComma(s, &comma_state);
                    switch (class_id) {
                        core.class.ids.uint8c_array, core.class.ids.uint8_array => try s.printf("{d}", .{ptr[0]}),
                        core.class.ids.int8_array => try s.printf("{d}", .{@as(i8, @bitCast(ptr[0]))}),
                        core.class.ids.int16_array => try s.printf("{d}", .{std.mem.readInt(i16, ptr[0..2], .little)}),
                        core.class.ids.uint16_array => try s.printf("{d}", .{std.mem.readInt(u16, ptr[0..2], .little)}),
                        core.class.ids.int32_array => try s.printf("{d}", .{std.mem.readInt(i32, ptr[0..4], .little)}),
                        core.class.ids.uint32_array => try s.printf("{d}", .{std.mem.readInt(u32, ptr[0..4], .little)}),
                        core.class.ids.big_int64_array => try s.printf("{d}", .{std.mem.readInt(i64, ptr[0..8], .little)}),
                        core.class.ids.big_uint64_array => try s.printf("{d}", .{std.mem.readInt(u64, ptr[0..8], .little)}),
                        core.class.ids.float16_array => try printFloat64(s, @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, ptr[0..2], .little))))),
                        core.class.ids.float32_array => try printFloat64(s, @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, ptr[0..4], .little))))),
                        core.class.ids.float64_array => try printFloat64(s, @bitCast(std.mem.readInt(u64, ptr[0..8], .little))),
                        else => unreachable,
                    }
                }
            }
        }
        if (shown < count) try printMoreItems(s, &comma_state, count - shown);
    } else if (isCallableClass(class_id)) {
        try s.puts("[Function ");
        if (ownOrProtoDataString(object, core.atom.ids.name)) |name| {
            if (core.string.stringValueLenUnchecked(name) == 0) {
                try s.puts("(anonymous)");
            } else {
                try printRawString(s, name);
            }
        } else {
            try s.puts("(anonymous)");
        }
        try s.putc(']');
        comma_state = 2;
    } else if ((class_id == core.class.ids.map or class_id == core.class.ids.set) and object.collectionPayloadBorrowed() != null) {
        try printClassName(s, class_id);
        try s.printf("({d}) {{ ", .{object.collectionPayloadBorrowed().?.active_count});
        // Printing a key or value can run JS that mutates this collection,
        // reallocating (and freeing) its entry array: index it afresh after
        // every nested print, and read the value only after the key printed.
        var shown: usize = 0;
        var index: usize = 0;
        while (shown < default_max_item_count) : (index += 1) {
            const entries = object.collectionPayloadBorrowed().?.entries.items;
            if (index >= entries.len) break;
            if (!entries[index].active) continue;
            try printComma(s, &comma_state);
            try printValueRec(s, entries[index].key);
            if (class_id == core.class.ids.map) {
                try s.puts(" => ");
                const current = object.collectionPayloadBorrowed().?.entries.items;
                try printValueRec(s, if (index < current.len and current[index].active) current[index].value else core.JSValue.undefinedValue());
            }
            shown += 1;
        }
        const active_count = object.collectionPayloadBorrowed().?.active_count;
        if (shown < active_count) try printMoreItems(s, &comma_state, active_count - shown);
    } else if (class_id == core.class.ids.regexp) {
        try printRegExp(s, object);
        comma_state = 2;
    } else if (class_id == core.class.ids.date and try dateIsoText(s, object)) {
        comma_state = 2;
    } else if (class_id == core.class.ids.error_) {
        try printError(s, object);
        comma_state = 2;
    } else {
        if (class_id != core.class.ids.object) {
            try printClassName(s, class_id);
            try s.putc(' ');
        }
        try s.puts("{ ");
    }

    // Shape properties in shape order; enumerable only (show_hidden is off).
    var shown: usize = 0;
    var index: usize = 0;
    // A nested print can run JS that reshapes this object; bound every step
    // by the current shape, not a count read before the loop.
    while (index < object.shapeProps().len) : (index += 1) {
        const flags = object.propFlagsAt(index);
        if (flags.deleted) continue;
        if (!flags.enumerable) continue;
        // A String wrapper's index characters are string-exotic properties
        // in qjs (never shape properties); zjs materialises them as shape
        // entries, so they are hidden here to keep `String {  }`.
        if (class_id == core.class.ids.string and object.propAtomAt(index).isTaggedInt()) continue;
        if (shown < default_max_item_count) {
            try printComma(s, &comma_state);
            try printAtom(s, object.propAtomAt(index));
            try s.puts(": ");
            switch (flags.kind) {
                .accessor => {
                    const accessor = object.asAccessorAt(index).?;
                    if (accessor.getter != null and accessor.setter != null) {
                        try s.puts("[Getter/Setter]");
                    } else if (accessor.setter != null) {
                        try s.puts("[Setter]");
                    } else {
                        try s.puts("[Getter]");
                    }
                },
                .var_ref => {
                    const cell = object.asVarRefAt(index).?;
                    try printValueRec(s, cell.varRefValue());
                },
                .auto_init => try s.puts("[autoinit]"),
                .data => try printValueRec(s, object.asDataAt(index).?),
            }
        }
        shown += 1;
    }
    if (shown > default_max_item_count) try printMoreItems(s, &comma_state, shown - default_max_item_count);

    if (!is_array) {
        if (comma_state != 2) try s.puts(" }");
    } else {
        try s.puts(" ]");
    }
}

/// The `JS_CLASS_DATE` arm: `get_date_string(..., 0x23)`
/// — toISOString without side effects; a NaN time value falls back to the
/// generic `Date {  }` dump. Returns false when nothing was written.
fn dateIsoText(s: *State, object: *const core.Object) Error!bool {
    const text = date_ops.isoStringForInspector(s.rt, object) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    try printRawString(s, text orelse return false);
    return true;
}

fn printStackIndex(s: *State, object: *const core.Object) ?usize {
    for (s.print_stack[0..s.level], 0..) |entry, i| {
        if (entry == object) return i;
    }
    return null;
}

/// `js_print_value`.
fn printValueRec(s: *State, value: core.JSValue) Error!void {
    // Recursive inspection can invoke Error.prepareStackTrace or a host
    // writer. Keep both the value and raw Object snapshots stable.
    const snapshot = [_]core.JSValue{value};
    const slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &snapshot }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(s.rt);
    defer roots.deactivate(s.rt);
    if (value.as(.int)) |int_value| {
        var buf: [32]u8 = undefined;
        return s.puts(dtoa.formatInt32(&buf, int_value));
    }
    if (value.as(.boolean)) |b| return s.puts(if (b) "true" else "false");
    if (value.is(.null_value)) return s.puts("null");
    if (value.is(.undefined_value)) return s.puts("undefined");
    if (value.is(.uninitialized)) return s.puts("uninitialized");
    if (value.as(.float64)) |d| return printFloat64(s, d);
    if (value.as(.short_big_int)) |small| {
        var buf: [32]u8 = undefined;
        try s.puts(dtoa.formatInt64(&buf, small));
        return s.putc('n');
    }
    if (value.isBigInt()) {
        var big = core.value_format.BigIntView.init(s.rt.nativeAllocator(), value) catch return error.OutOfMemory;
        defer big.deinit();
        const text = big.int.formatBase10Alloc(s.rt.nativeAllocator(), null) catch return error.OutOfMemory;
        defer s.rt.nativeAllocator().free(text);
        try s.puts(text);
        return s.putc('n');
    }
    if (value.isString()) return printString(s, value);
    if (value.is(.symbol)) {
        try s.puts("Symbol(");
        try printAtom(s, value.asSymbolAtom() orelse core.atom.null_atom);
        return s.putc(')');
    }
    if (value.is(.object)) {
        const header = value.refHeader() orelse return s.puts("[Object]");
        const object = core.Object.fromHeader(header);
        if (printStackIndex(s, object)) |idx| {
            try s.printf("[circular {d}]", .{idx});
        } else if (s.level < default_max_depth) {
            s.print_stack[s.level] = object;
            s.level += 1;
            defer s.level -= 1;
            try printObject(s, object);
        } else {
            try s.putc('[');
            try printClassName(s, object.class_id);
            try s.putc(']');
        }
        return;
    }
    try s.puts("[unknown tag]");
}
