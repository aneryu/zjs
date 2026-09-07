//! CLI `print` / `console.log` value inspector: the QuickJS `JS_PrintValue`
//! dump (quickjs.c:13678-14432) reproduced byte for byte, so a benchmark
//! driver or a test262 harness line reads the same under both shells.
//!
//! Scope mirrors `js_print` (quickjs-libc.c:4063): a top-level *string*
//! argument is written raw by the caller; every other value comes here.
//! Defaults are `JS_PrintValueSetDefaultOptions` (quickjs.c:14401):
//! depth 2, strings cut at 1000 characters, 100 items per container,
//! enumerable properties only, no `raw_dump`.
//!
//! Cold path: only the CLI output builtins reach it. No allocation except
//! the BigInt decimal text.

const std = @import("std");
const core = @import("../core/root.zig");
const gc_audit_print = @import("../core/gc_audit_print.zig");
const value_ops = @import("value_ops.zig");
const date_ops = @import("date_ops.zig");
const regexp_adapter = @import("regexp_adapter.zig");
const error_stack_ops = @import("error_stack_ops.zig");
const dtoa = @import("../libs/number_format.zig");

pub const Error = std.Io.Writer.Error || error{OutOfMemory};

/// `JS_PRINT_MAX_DEPTH` (quickjs.c:13678): the print stack bound.
const max_stack_depth: usize = 8;
/// `JS_PrintValueSetDefaultOptions` (quickjs.c:14401-14407).
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

    fn putUnicodeEscape(self: *State, value: u64) Error!void {
        var hex_buf: [16]u8 = undefined;
        try self.puts("\\u");
        try self.puts(gc_audit_print.hexPad(value, 4, &hex_buf));
    }
};

fn makeState(ctx: *core.JSContext, global: *core.Object, output: ?*std.Io.Writer, writer: *std.Io.Writer) State {
    return .{ .rt = ctx.runtime, .ctx = ctx, .global = global, .output = output, .writer = writer };
}

/// Entry point for one non-string `print` argument (`JS_PrintValue`,
/// quickjs.c:14440, with the default options).
pub fn printValue(ctx: *core.JSContext, global: *core.Object, output: ?*std.Io.Writer, writer: *std.Io.Writer, value: core.JSValue) Error!void {
    var state = makeState(ctx, global, output, writer);
    try printValueRec(&state, value);
}

/// One `print` / `console.log` argument (`js_print`, quickjs-libc.c:4063):
/// a top-level string is written raw; every other value is `JS_PrintValue`.
pub fn printHostArgument(ctx: *core.JSContext, global: *core.Object, output: ?*std.Io.Writer, writer: *std.Io.Writer, value: core.JSValue) Error!void {
    var state = makeState(ctx, global, output, writer);
    if (value.isString()) return printRawString(&state, value);
    try printValueRec(&state, value);
}

/// `js_print_float64` (quickjs.c:13713): `js_dtoa` free format with
/// `JS_DTOA_MINUS_ZERO`, i.e. Number::toString except that -0 keeps its sign.
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

    fn len(self: Units) usize {
        return switch (self) {
            .latin1 => |bytes| bytes.len,
            .utf16 => |units| units.len,
        };
    }

    fn at(self: Units, index: usize) u16 {
        return switch (self) {
            .latin1 => |bytes| bytes[index],
            .utf16 => |units| units[index],
        };
    }
};

/// `js_print_string1` (quickjs.c:13736-13791): pretty-print the first `len`
/// units with `sep` as the quote to escape.
fn printUnits(s: *State, units: Units, len: usize, sep: u16) Error!void {
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
        if (c == sep) {
            try s.putc('\\');
            try s.putc(@intCast(c));
            continue;
        }
        if (c >= 32 and c <= 126) {
            try s.putc(@intCast(c));
            continue;
        }
        if (c < 32 or (c >= 0x7f and c <= 0x9f)) {
            try s.putUnicodeEscape(c);
            continue;
        }
        if (std.unicode.utf16IsHighSurrogate(@intCast(c))) {
            if (i + 1 >= len) {
                try s.putUnicodeEscape(c);
                continue;
            }
            const c1: u32 = units.at(i + 1);
            if (!std.unicode.utf16IsLowSurrogate(@intCast(c1))) {
                try s.putUnicodeEscape(c);
                continue;
            }
            i += 1;
            c = 0x10000 + (((c & 0x3ff) << 10) | (c1 & 0x3ff));
        } else if (std.unicode.utf16IsLowSurrogate(@intCast(c))) {
            try s.putUnicodeEscape(c);
            continue;
        }
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(c), &utf8) catch unreachable;
        try s.puts(utf8[0..n]);
    }
}

fn unitsOfString(body: *const core.string.String) Units {
    return switch (body.resolveData()) {
        .latin1 => |bytes| .{ .latin1 = bytes },
        .utf16 => |units| .{ .utf16 = units },
    };
}

/// `js_print_string` (quickjs.c:13812-13829): quoted, escaped, cut at
/// `max_string_length` with the `... N more characters` tail.
fn printString(s: *State, value: core.JSValue) Error!void {
    const body = value.asStringBody() orelse return s.puts("<invalid string tag>");
    body.ensureFlat(s.rt) catch return error.OutOfMemory;
    const units = unitsOfString(body);
    const total = units.len();
    const shown = @min(total, default_max_string_length);
    try s.putc('"');
    try printUnits(s, units, shown, '"');
    try s.putc('"');
    if (total > default_max_string_length) {
        const n = total - default_max_string_length;
        try s.printf("... {d} more character{s}", .{ n, if (n > 1) "s" else "" });
    }
}

/// `js_print_raw_string` (quickjs.c:13831): the string text as-is.
fn printRawString(s: *State, value: core.JSValue) Error!void {
    const body = value.asStringBody() orelse return;
    body.ensureFlat(s.rt) catch return error.OutOfMemory;
    switch (body.resolveData()) {
        .latin1 => |bytes| {
            for (bytes) |byte| {
                if (byte < 0x80) {
                    try s.putc(byte);
                } else {
                    try s.puts(&[_]u8{ 0xc0 | (byte >> 6), 0x80 | (byte & 0x3f) });
                }
            }
        },
        .utf16 => |units| {
            var it = std.unicode.Utf16LeIterator.init(units);
            while (it.nextCodepoint() catch null) |codepoint| {
                var utf8: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(codepoint, &utf8) catch continue;
                try s.puts(utf8[0..n]);
            }
        },
    }
}

/// `is_ascii_ident` (quickjs.c:13843): bare key or quoted key.
fn isAsciiIdent(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes, 0..) |c, i| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$' or
            (c >= '0' and c <= '9' and i > 0);
        if (!ok) return false;
    }
    return true;
}

/// `js_print_atom` (quickjs.c:13857-13877). Atom names are stored as UTF-8;
/// the quoted arm re-encodes to UTF-16 units so the escaper sees what qjs
/// sees (`\u00xx` for U+007F..U+009F, raw UTF-8 above).
fn printAtom(s: *State, atom_id: core.Atom) Error!void {
    if (core.atom.isTaggedInt(atom_id)) return s.printf("{d}", .{core.atom.atomToUInt32(atom_id)});
    if (atom_id == core.atom.null_atom) return s.puts("<null>");
    try printNameBytes(s, s.rt.atoms.name(atom_id) orelse "");
}

/// The bare-or-quoted tail of `js_print_atom` on a UTF-8 name.
fn printNameBytes(s: *State, bytes: []const u8) Error!void {
    if (isAsciiIdent(bytes)) return s.puts(bytes);
    try s.putc('"');
    var units_buf: [256]u16 = undefined;
    if (std.unicode.utf8ToUtf16Le(&units_buf, bytes)) |n| {
        try printUnits(s, .{ .utf16 = units_buf[0..n] }, n, '"');
    } else |_| {
        // Longer or malformed names: escape byte-wise without the surrogate
        // pairing; the byte view still quotes and escapes every ASCII case.
        try printUnits(s, .{ .latin1 = bytes }, bytes.len, '"');
    }
    try s.putc('"');
}

/// `rt->class_array[class_id].class_name` through `js_print_atom`. The zjs
/// class table names only the classes of `standard_classes`; the rest carry
/// the qjs `js_async_class_def` / WeakRef / FinalizationRegistry names here,
/// Proxy is registered under `Object` in qjs (quickjs.c JS_CLASS_PROXY), and
/// the zjs-only classes take the obvious name (not verified against qjs).
fn printClassName(s: *State, class_id: core.class.ClassId) Error!void {
    if (class_id != core.class.ids.proxy) {
        if (s.rt.classes.className(class_id)) |name_atom| {
            if (name_atom != core.atom.null_atom) return printAtom(s, name_atom);
        }
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
        core.class.ids.dom_exception => "DOMException",
        core.class.ids.call_site => "CallSite",
        core.class.ids.raw_json => "RawJSON",
        core.class.ids.std_file => "FILE",
        core.class.ids.disposable_stack => "DisposableStack",
        core.class.ids.async_disposable_stack => "AsyncDisposableStack",
        else => return s.puts("<null>"),
    };
    try printNameBytes(s, fallback);
}

/// `js_print_comma` (quickjs.c:13903): 0 = first item, 1 = `, `, 2 = the
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

/// `js_print_more_items` (quickjs.c:13918).
fn printMoreItems(s: *State, comma_state: *u8, n: usize) Error!void {
    try printComma(s, comma_state);
    try s.printf("... {d} more item{s}", .{ n, if (n > 1) "s" else "" });
}

/// `get_prop_string` (quickjs.c:7504): an own plain data string property, or
/// the same one level up the prototype (the Error `name` case).
fn ownOrProtoDataString(object: *const core.Object, atom_id: core.Atom) ?core.JSValue {
    var owner: ?*const core.Object = object;
    var hops: usize = 0;
    while (owner) |current| : (hops += 1) {
        if (current.findProperty(atom_id)) |index| {
            // zjs keeps the intrinsic prototypes' `name` (and a function's
            // `prototype`) as lazy auto_init slots where qjs has a plain
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

/// `js_print_regexp` (quickjs.c:13926-13990): the pattern with `/`, line
/// terminators and the `[/]` bracket case escaped, then the flag letters in
/// the `lre` bit order (g i m s u y d, then bit 7 — which is the named-groups
/// bit — printed as `v`; the real unicode-sets bit is never shown. That is
/// what qjs prints, so it is what this prints).
fn printRegExp(s: *State, object: *const core.Object) Error!void {
    const bytecode = object.regexpCompiledBytecode();
    const source_value = object.regexpSource();
    if (bytecode.len == 0 or source_value == null) return s.puts("[uninitialized_regexp]");
    const body = source_value.?.asStringBody() orelse return s.puts("[uninitialized_regexp]");
    body.ensureFlat(s.rt) catch return error.OutOfMemory;
    const units = unitsOfString(body);
    const n = units.len();
    try s.putc('/');
    if (n == 0) {
        try s.puts("(?:)");
    } else {
        var bra = false;
        var i: usize = 0;
        while (i < n) {
            var c: u32 = units.at(i);
            i += 1;
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
    const flags = regexp_adapter.flagBitsFromBytecode(bytecode);
    const letters = [_]u8{ 'g', 'i', 'm', 's', 'u', 'y', 'd', 'v' };
    for (letters, 0..) |letter, bit| {
        if ((flags >> @intCast(bit)) & 1 != 0) try s.putc(letter);
    }
}

/// `js_putc` on a code unit: qjs writes the unit's low byte; a non-ASCII
/// unit is emitted as UTF-8 instead of a stray byte.
fn putUnitRaw(s: *State, c: u32) Error!void {
    if (c < 0x80) return s.putc(@intCast(c));
    var utf8: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(c), &utf8) catch return;
    try s.puts(utf8[0..n]);
}

/// `js_print_error` (quickjs.c:13992-14026): `Name: message` then the
/// `stack` text on its own line, trailing newline dropped.
fn printError(s: *State, object: *const core.Object) Error!void {
    if (ownOrProtoDataString(object, core.atom.ids.name)) |name| {
        try printRawString(s, name);
    } else {
        try s.puts("Error");
    }
    if (ownOrProtoDataString(object, core.atom.ids.message)) |message| {
        const body = message.asStringBody();
        if (body != null and body.?.len() != 0) {
            try s.puts(": ");
            try printRawString(s, message);
        }
    }
    // zjs keeps `stack` as a native accessor on Error.prototype (V8 shape)
    // where qjs stores an own data property; the accessor's answer is the
    // same captured text, so read it through the native getter when no own
    // data `stack` shadows it.
    const stack_value: ?core.JSValue = ownOrProtoDataString(object, core.atom.ids.stack) orelse blk: {
        const got = error_stack_ops.errorStackGetter(s.ctx, s.output, s.global, @constCast(object).value()) catch break :blk null;
        break :blk if (got.isString()) got else null;
    };
    if (stack_value) |stack| {
        try s.putc('\n');
        const body = stack.asStringBody() orelse return;
        body.ensureFlat(s.rt) catch return error.OutOfMemory;
        const units = unitsOfString(body);
        var len = units.len();
        if (len > 0 and units.at(len - 1) == '\n') len -= 1;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const c: u32 = units.at(i);
            if (std.unicode.utf16IsHighSurrogate(@intCast(c)) and i + 1 < len and
                std.unicode.utf16IsLowSurrogate(@intCast(units.at(i + 1))))
            {
                const c1: u32 = units.at(i + 1);
                try putUnitRaw(s, 0x10000 + (((c & 0x3ff) << 10) | (c1 & 0x3ff)));
                i += 1;
            } else {
                try putUnitRaw(s, c);
            }
        }
    }
}

fn isTypedArrayClass(class_id: core.class.ClassId) bool {
    return class_id >= core.class.ids.uint8c_array and class_id <= core.class.ids.float64_array;
}

/// The `rt->class_array[class_id].call != NULL && class_id != JS_CLASS_PROXY`
/// test (quickjs.c:14106): every class qjs registers with a call handler.
fn isCallableClass(class_id: core.class.ClassId) bool {
    return switch (class_id) {
        core.class.ids.c_function,
        core.class.ids.bytecode_function,
        core.class.ids.bound_function,
        core.class.ids.c_function_data,
        core.class.ids.c_closure,
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

/// `js_print_object` (quickjs.c:14028-14267).
fn printObject(s: *State, object: *const core.Object) Error!void {
    var comma_state: u8 = 0;
    var is_array = false;
    const class_id = object.class_id;

    if (class_id == core.class.ids.array) {
        is_array = true;
        try s.puts("[ ");
        if (object.flags.fast_array) {
            const len: usize = object.arrayLength();
            const elements = object.arrayElements();
            const shown = @min(elements.len, default_max_item_count);
            for (elements[0..shown]) |element| {
                try printComma(s, &comma_state);
                try printValueRec(s, element);
            }
            if (shown < elements.len) try printMoreItems(s, &comma_state, elements.len - shown);
            if (elements.len < len) {
                const n = len - elements.len;
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
                var i: usize = 0;
                while (i < shown) : (i += 1) {
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
            if (name.asStringBody().?.len() == 0) {
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
        const payload = object.collectionPayloadBorrowed().?;
        try printClassName(s, class_id);
        try s.printf("({d}) {{ ", .{payload.active_count});
        var shown: usize = 0;
        for (payload.entries) |entry| {
            if (!entry.active) continue;
            try printComma(s, &comma_state);
            try printValueRec(s, entry.key);
            if (class_id == core.class.ids.map) {
                try s.puts(" => ");
                try printValueRec(s, entry.value);
            }
            shown += 1;
            if (shown >= default_max_item_count) break;
        }
        if (shown < payload.active_count) try printMoreItems(s, &comma_state, payload.active_count - shown);
    } else if (class_id == core.class.ids.regexp) {
        try printRegExp(s, object);
        comma_state = 2;
    } else if (class_id == core.class.ids.date and dateIsoText(s, object)) {
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
    const prop_count = object.shapeProps().len;
    var index: usize = 0;
    while (index < prop_count) : (index += 1) {
        const flags = object.propFlagsAt(index);
        if (flags.deleted) continue;
        if (!flags.enumerable) continue;
        // A String wrapper's index characters are string-exotic properties
        // in qjs (never shape properties); zjs materialises them as shape
        // entries, so they are hidden here to keep `String {  }`.
        if (class_id == core.class.ids.string and core.atom.isTaggedInt(object.propAtomAt(index))) continue;
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
                    try printValueRec(s, cell.valueRef());
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

/// The `JS_CLASS_DATE` arm (quickjs.c:14153): `get_date_string(..., 0x23)`
/// — toISOString without side effects; a NaN time value falls back to the
/// generic `Date {  }` dump. Returns false when nothing was written.
fn dateIsoText(s: *State, object: *const core.Object) bool {
    const text = date_ops.isoStringForInspector(s.rt, object) catch return false;
    const value = text orelse return false;
    printRawString(s, value) catch return true;
    return true;
}

fn printStackIndex(s: *State, object: *const core.Object) ?usize {
    for (s.print_stack[0..s.level], 0..) |entry, i| {
        if (entry == object) return i;
    }
    return null;
}

/// `js_print_value` (quickjs.c:14278-14399).
fn printValueRec(s: *State, value: core.JSValue) Error!void {
    if (value.asInt32()) |int_value| {
        var buf: [32]u8 = undefined;
        return s.puts(dtoa.formatInt32(&buf, int_value));
    }
    if (value.asBool()) |b| return s.puts(if (b) "true" else "false");
    if (value.isNull()) return s.puts("null");
    if (value.isUndefined()) return s.puts("undefined");
    if (value.isUninitialized()) return s.puts("uninitialized");
    if (value.asFloat64()) |d| return printFloat64(s, d);
    if (value.asShortBigInt()) |small| {
        var buf: [32]u8 = undefined;
        try s.puts(dtoa.formatInt64(&buf, small));
        return s.putc('n');
    }
    if (value.isBigInt()) {
        var big = value_ops.cloneBigIntValue(s.rt, value) catch return error.OutOfMemory;
        defer big.deinit();
        const text = big.formatBase10Alloc(s.rt.memory.allocator) catch return error.OutOfMemory;
        defer s.rt.memory.allocator.free(text);
        try s.puts(text);
        return s.putc('n');
    }
    if (value.isString()) return printString(s, value);
    if (value.isSymbol()) {
        try s.puts("Symbol(");
        try printAtom(s, value.asSymbolAtom() orelse core.atom.null_atom);
        return s.putc(')');
    }
    if (value.isObject()) {
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
