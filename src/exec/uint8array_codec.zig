//! Uint8Array base64/hex codecs: `Uint8Array.fromBase64`/`fromHex`,
//! `setFromBase64`/`setFromHex` and `toBase64`/`toHex`, plus the byte-level
//! encoders the host `btoa`/`atob` globals share.

const core = @import("../core/root.zig");
const bytecode = @import("../bytecode.zig");
const frame_mod = @import("frame.zig");
const std = @import("std");
const unicode_lib = @import("../libs/unicode.zig");
const exception_ops = @import("exception_ops.zig");
const object_ops = @import("object_ops.zig");
const property_ops = @import("property_ops.zig");
const string_ops = @import("string_ops.zig");
const value_ops = @import("value_ops.zig");

const atomicsBufferObject = object_ops.atomicsBufferObject;
const defineValueProperty = object_ops.defineValueProperty;
const getValueProperty = object_ops.getValueProperty;
const throwTypeErrorMessage = exception_ops.throwTypeErrorMessage;
const uint8ArrayStringBytes = string_ops.uint8ArrayStringBytes;
const valueTruthy = value_ops.valueTruthy;

pub fn uint8ArrayCodecCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    name: []const u8,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (std.mem.eql(u8, name, "fromHex")) {
        var bytes = try uint8ArrayStringBytes(ctx.runtime, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
        defer bytes.deinit(ctx.runtime.nativeAllocator());
        var decoded = try decodeHexBytes(ctx.runtime, bytes.items, true);
        defer decoded.deinit(ctx.runtime.nativeAllocator());
        return try createUint8ArrayFromBytes(ctx.runtime, global, decoded.items);
    }
    if (std.mem.eql(u8, name, "fromBase64")) {
        var bytes = try uint8ArrayStringBytes(ctx.runtime, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
        defer bytes.deinit(ctx.runtime.nativeAllocator());
        const options = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
        // Mirrors js_uint8array_from_base64: GetOptionsObject
        // runs after the string check, before any option Get.
        try uint8ArrayCheckOptionsObject(options);
        const alphabet = try uint8ArrayBase64Alphabet(ctx, output, global, options, caller_function, caller_frame);
        const last_chunk_handling = try uint8ArrayBase64LastChunkHandling(ctx, output, global, options, caller_function, caller_frame);
        var decoded = try decodeBase64Bytes(ctx.runtime, bytes.items, alphabet, last_chunk_handling);
        defer decoded.deinit(ctx.runtime.nativeAllocator());
        return try createUint8ArrayFromBytes(ctx.runtime, global, decoded.items);
    }
    if (std.mem.eql(u8, name, "toHex")) {
        const object = try expectUint8ArrayObject(this_value);
        const bytes = try uint8ArrayViewBytes(ctx, global, object);
        var encoded = try encodeHexBytes(ctx.runtime, bytes);
        defer encoded.deinit(ctx.runtime.nativeAllocator());
        return try value_ops.createStringValue(ctx.runtime, encoded.items);
    }
    if (std.mem.eql(u8, name, "toBase64")) {
        const object = try expectUint8ArrayObject(this_value);
        const options = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        // Mirrors js_uint8array_to_base64: GetOptionsObject
        // runs after the receiver check, before any option Get.
        try uint8ArrayCheckOptionsObject(options);
        const alphabet = try uint8ArrayBase64Alphabet(ctx, output, global, options, caller_function, caller_frame);
        const omit_padding = try uint8ArrayOmitPadding(ctx, output, global, options, caller_function, caller_frame);
        const bytes = try uint8ArrayViewBytes(ctx, global, object);
        var encoded = try encodeBase64Bytes(ctx.runtime, bytes, alphabet, omit_padding);
        defer encoded.deinit(ctx.runtime.nativeAllocator());
        return try value_ops.createStringValue(ctx.runtime, encoded.items);
    }
    if (std.mem.eql(u8, name, "setFromHex")) {
        const object = try expectUint8ArrayObject(this_value);
        const source_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
        var source = try uint8ArrayStringBytes(ctx.runtime, source_value);
        defer source.deinit(ctx.runtime.nativeAllocator());
        const target = try uint8ArrayViewBytes(ctx, global, object);
        const result = try decodeHexInto(source.items, core.string.stringValueLen(source_value), target);
        return try uint8ArrayCodecResult(ctx, result.read, result.written);
    }
    if (std.mem.eql(u8, name, "setFromBase64")) {
        const object = try expectUint8ArrayObject(this_value);
        var source = try uint8ArrayStringBytes(ctx.runtime, if (args.len >= 1) args[0] else core.JSValue.undefinedValue());
        defer source.deinit(ctx.runtime.nativeAllocator());
        const options = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
        // Mirrors js_uint8array_set_from_base64:
        // GetOptionsObject runs after the receiver and string checks, before
        // any option Get.
        try uint8ArrayCheckOptionsObject(options);
        const alphabet = try uint8ArrayBase64Alphabet(ctx, output, global, options, caller_function, caller_frame);
        const last_chunk_handling = try uint8ArrayBase64LastChunkHandling(ctx, output, global, options, caller_function, caller_frame);
        const target = try uint8ArrayViewBytes(ctx, global, object);
        const result = try decodeBase64Into(ctx.runtime, source.items, alphabet, last_chunk_handling, target);
        return try uint8ArrayCodecResult(ctx, result.read, result.written);
    }
    return null;
}

const Uint8ArrayBase64Alphabet = enum { base64, base64url };
const Uint8ArrayBase64LastChunkHandling = enum { loose, strict, stop_before_partial };
const Uint8ArrayCodecProgress = struct { read: usize, written: usize };

/// Mirrors check_options_object, the GetOptionsObject step
/// shared by toBase64 / fromBase64 / setFromBase64: options must be undefined
/// or an Object, anything else is a TypeError ("options must be an object").
/// The hex entry points take no options and never run this check.
fn uint8ArrayCheckOptionsObject(options: core.JSValue) !void {
    if (options.is(.undefined_value)) return;
    if (!options.is(.object)) return error.NotAnObject;
}

pub fn expectUint8ArrayObject(value: core.JSValue) !*core.Object {
    const object = try property_ops.expectObject(value);
    if (!core.typed_array.isTypedArrayObject(object) or object.typedArrayKind() != .uint8) return error.NotAUint8Array;
    return object;
}

const base64_alphabet_ids = [_]core.host_function.name_id.Entry{
    .{ .name = "base64", .id = @intFromEnum(Uint8ArrayBase64Alphabet.base64) },
    .{ .name = "base64url", .id = @intFromEnum(Uint8ArrayBase64Alphabet.base64url) },
};

const base64_last_chunk_ids = [_]core.host_function.name_id.Entry{
    .{ .name = "loose", .id = @intFromEnum(Uint8ArrayBase64LastChunkHandling.loose) },
    .{ .name = "strict", .id = @intFromEnum(Uint8ArrayBase64LastChunkHandling.strict) },
    .{ .name = "stop-before-partial", .id = @intFromEnum(Uint8ArrayBase64LastChunkHandling.stop_before_partial) },
};

fn uint8ArrayBase64Alphabet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    options: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !Uint8ArrayBase64Alphabet {
    const id = try uint8ArrayBase64NamedOption(
        ctx,
        output,
        global,
        options,
        caller_function,
        caller_frame,
        core.atom.ids.alphabet,
        @intFromEnum(Uint8ArrayBase64Alphabet.base64),
        &base64_alphabet_ids,
    );
    return @enumFromInt(id);
}

fn uint8ArrayBase64LastChunkHandling(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    options: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !Uint8ArrayBase64LastChunkHandling {
    const id = try uint8ArrayBase64NamedOption(
        ctx,
        output,
        global,
        options,
        caller_function,
        caller_frame,
        core.atom.ids.lastChunkHandling,
        @intFromEnum(Uint8ArrayBase64LastChunkHandling.loose),
        &base64_last_chunk_ids,
    );
    return @enumFromInt(id);
}

/// Leftover Uint8Array base64 named-option admission. The two public
/// names share get-property + stringify + table match; comptime identity
/// is only the atom, default, and table. Does not fold `omitPadding`.
noinline fn uint8ArrayBase64NamedOption(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    options: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    key: core.Atom,
    default_id: u32,
    table: []const core.host_function.name_id.Entry,
) !u32 {
    if (!options.is(.object)) return default_id;
    const value = try getValueProperty(ctx, output, global, options, key, caller_function, caller_frame);
    if (value.is(.undefined_value)) return default_id;
    var text = try uint8ArrayStringBytes(ctx.runtime, value);
    defer text.deinit(ctx.runtime.nativeAllocator());
    return core.host_function.name_id.lookup(text.items, table) orelse error.InvalidOptionValue;
}

fn uint8ArrayOmitPadding(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    options: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (!options.is(.object)) return false;
    const key = core.atom.ids.omitPadding;
    const value = try getValueProperty(ctx, output, global, options, key, caller_function, caller_frame);
    return valueTruthy(value);
}

pub fn createUint8ArrayFromBytes(rt: *core.JSRuntime, global: *core.Object, bytes: []const u8) !core.JSValue {
    const ctx = rt.contextForGlobal(global) orelse return error.InvalidBuiltinRegistry;
    const buffer_proto = ctx.classPrototypeObject(core.class.ids.array_buffer) orelse return error.InvalidBuiltinRegistry;
    const buffer_value = try core.typed_array.arrayBufferConstructLength(rt, bytes.len, null, buffer_proto);
    const buffer = try property_ops.expectObject(buffer_value);
    if (bytes.len != 0) @memcpy(buffer.byteStorage()[0..bytes.len], bytes);
    const prototype = ctx.classPrototypeObject(core.class.ids.uint8_array) orelse return error.InvalidBuiltinRegistry;
    return try core.typed_array.typedArrayConstructFullBufferOwned(rt, 1, .uint8, buffer_value, buffer, prototype);
}

/// GetUint8ArrayBytes / the setFrom* target: the view's bytes, or a
/// TypeError when its buffer is detached or has shrunk below the view.
fn uint8ArrayViewBytes(ctx: *core.JSContext, global: *core.Object, object: *core.Object) ![]u8 {
    if (try core.typed_array.typedArrayDetached(object) or try core.typed_array.typedArrayOutOfBounds(object)) {
        _ = try throwTypeErrorMessage(ctx, global, "ArrayBuffer is detached or resized");
        unreachable;
    }
    const length = try core.typed_array.typedArrayLength(ctx.runtime, object);
    const buffer = try atomicsBufferObject(object);
    const start = object.typedArrayByteOffset();
    return buffer.byteStorage()[start..][0..length];
}

/// `{ read, written }`, an ordinary object from %Object.prototype%.
fn uint8ArrayCodecResult(ctx: *core.JSContext, read: usize, written: usize) !core.JSValue {
    const rt = ctx.runtime;
    const object = try core.Object.create(rt, core.class.ids.object, ctx.classPrototypeObject(core.class.ids.object));
    errdefer core.Object.destroyFromHeader(rt, object.gcHeader());
    try defineValueProperty(rt, object, core.atom.ids.read, core.JSValue.int32(@intCast(read)));
    try defineValueProperty(rt, object, core.atom.ids.written, core.JSValue.int32(@intCast(written)));
    return object.value();
}

fn decodeHexBytes(rt: *core.JSRuntime, source: []const u8, reject_odd: bool) !std.ArrayList(u8) {
    if (reject_odd and source.len % 2 != 0) return error.SyntaxError;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(rt.nativeAllocator());
    var index: usize = 0;
    while (index + 1 < source.len) : (index += 2) {
        const hi = hexNibble(source[index]) orelse return error.SyntaxError;
        const lo = hexNibble(source[index + 1]) orelse return error.SyntaxError;
        try out.append(rt.nativeAllocator(), (hi << 4) | lo);
    }
    return out;
}

/// FromHex into `target`. `unit_len` is the string's length in UTF-16 code
/// units: the spec's odd-length check (step 3) counts those, not UTF-8 bytes.
/// Up to the first non-ASCII character the byte and unit indices agree, and
/// that character is a non-hexit, so the pair walk can stay on the bytes.
fn decodeHexInto(source: []const u8, unit_len: usize, target: []u8) !Uint8ArrayCodecProgress {
    if (unit_len % 2 != 0) return error.SyntaxError;
    var read: usize = 0;
    var written: usize = 0;
    while (read < source.len and written < target.len) {
        const hi = hexNibble(source[read]) orelse return error.SyntaxError;
        const lo = hexNibble(source[read + 1]) orelse return error.SyntaxError;
        target[written] = (hi << 4) | lo;
        read += 2;
        written += 1;
    }
    return .{ .read = read, .written = written };
}

fn encodeHexBytes(rt: *core.JSRuntime, bytes: []const u8) !std.ArrayList(u8) {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(rt.nativeAllocator());
    for (bytes) |byte| {
        try out.append(rt.nativeAllocator(), unicode_lib.asciiLowerHexDigitChar(byte >> 4));
        try out.append(rt.nativeAllocator(), unicode_lib.asciiLowerHexDigitChar(byte & 0x0f));
    }
    return out;
}

pub fn hexNibble(byte: u8) ?u8 {
    return unicode_lib.asciiHexDigitValueByte(byte);
}

pub fn decodeBase64Bytes(
    rt: *core.JSRuntime,
    source: []const u8,
    alphabet: Uint8ArrayBase64Alphabet,
    last_chunk_handling: Uint8ArrayBase64LastChunkHandling,
) !std.ArrayList(u8) {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(rt.nativeAllocator());
    _ = try decodeBase64Internal(rt, source, alphabet, last_chunk_handling, &out, null);
    return out;
}

fn decodeBase64Into(
    rt: *core.JSRuntime,
    source: []const u8,
    alphabet: Uint8ArrayBase64Alphabet,
    last_chunk_handling: Uint8ArrayBase64LastChunkHandling,
    target: []u8,
) !Uint8ArrayCodecProgress {
    return decodeBase64Internal(rt, source, alphabet, last_chunk_handling, null, target);
}

/// FromBase64 (Uint8Array base64 proposal), step for step. Decoded bytes go to
/// `out` or, for setFromBase64, straight into `target` (whose length is
/// maxLength); on error the bytes already decoded stay written.
fn decodeBase64Internal(
    rt: *core.JSRuntime,
    source: []const u8,
    alphabet: Uint8ArrayBase64Alphabet,
    last_chunk_handling: Uint8ArrayBase64LastChunkHandling,
    out: ?*std.ArrayList(u8),
    target: ?[]u8,
) !Uint8ArrayCodecProgress {
    const max_length: usize = if (target) |bytes| bytes.len else std.math.maxInt(usize);
    var sink: Base64Sink = .{ .rt = rt, .out = out, .target = target };
    if (max_length == 0) return .{ .read = 0, .written = 0 };
    var chunk: [4]u8 = undefined;
    var chunk_len: usize = 0;
    var read: usize = 0;
    var index: usize = 0;
    while (true) {
        index = skipAsciiWhitespace(source, index);
        if (index == source.len) {
            if (chunk_len > 0) switch (last_chunk_handling) {
                .stop_before_partial => return .{ .read = read, .written = sink.written },
                .loose => {
                    if (chunk_len == 1) return error.SyntaxError;
                    try sink.putFinal(chunk, chunk_len, false);
                },
                .strict => return error.SyntaxError,
            };
            return .{ .read = source.len, .written = sink.written };
        }
        const char = source[index];
        index += 1;
        if (char == '=') {
            if (chunk_len < 2) return error.SyntaxError;
            index = skipAsciiWhitespace(source, index);
            if (chunk_len == 2) {
                if (index == source.len) {
                    if (last_chunk_handling == .stop_before_partial) return .{ .read = read, .written = sink.written };
                    return error.SyntaxError;
                }
                if (source[index] == '=') index = skipAsciiWhitespace(source, index + 1);
            }
            if (index < source.len) return error.SyntaxError;
            try sink.putFinal(chunk, chunk_len, last_chunk_handling == .strict);
            return .{ .read = source.len, .written = sink.written };
        }
        const value = base64Value(char, alphabet) orelse return error.SyntaxError;
        // Another character could only decode past a full target.
        const remaining = max_length - sink.written;
        if ((remaining == 1 and chunk_len == 2) or (remaining == 2 and chunk_len == 3)) {
            return .{ .read = read, .written = sink.written };
        }
        chunk[chunk_len] = value;
        chunk_len += 1;
        if (chunk_len == 4) {
            try sink.put(&.{
                (chunk[0] << 2) | (chunk[1] >> 4),
                ((chunk[1] & 0x0f) << 4) | (chunk[2] >> 2),
                ((chunk[2] & 0x03) << 6) | chunk[3],
            });
            chunk_len = 0;
            read = index;
            if (sink.written == max_length) return .{ .read = read, .written = sink.written };
        }
    }
}

fn skipAsciiWhitespace(source: []const u8, start: usize) usize {
    var index = start;
    while (index < source.len and unicode_lib.isAsciiWhitespaceByte(source[index])) index += 1;
    return index;
}

const Base64Sink = struct {
    rt: *core.JSRuntime,
    out: ?*std.ArrayList(u8),
    target: ?[]u8,
    written: usize = 0,

    fn put(self: *Base64Sink, bytes: []const u8) !void {
        if (self.target) |target| {
            @memcpy(target[self.written..][0..bytes.len], bytes);
        } else if (self.out) |list| {
            try list.appendSlice(self.rt.nativeAllocator(), bytes);
        }
        self.written += bytes.len;
    }

    /// DecodeFinalBase64Chunk: 2 or 3 sextets give 1 or 2 bytes; strict
    /// mode rejects nonzero leftover bits.
    fn putFinal(self: *Base64Sink, chunk: [4]u8, chunk_len: usize, throw_on_extra_bits: bool) !void {
        std.debug.assert(chunk_len == 2 or chunk_len == 3);
        const first = (chunk[0] << 2) | (chunk[1] >> 4);
        if (chunk_len == 2) {
            if (throw_on_extra_bits and chunk[1] & 0x0f != 0) return error.SyntaxError;
            return self.put(&.{first});
        }
        if (throw_on_extra_bits and chunk[2] & 0x03 != 0) return error.SyntaxError;
        return self.put(&.{ first, ((chunk[1] & 0x0f) << 4) | (chunk[2] >> 2) });
    }
};

pub fn encodeBase64Bytes(rt: *core.JSRuntime, bytes: []const u8, alphabet: Uint8ArrayBase64Alphabet, omit_padding: bool) !std.ArrayList(u8) {
    const table = if (alphabet == .base64) "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" else "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(rt.nativeAllocator());
    var index: usize = 0;
    while (index < bytes.len) : (index += 3) {
        const rem = bytes.len - index;
        const b0 = bytes[index];
        const b1 = if (rem > 1) bytes[index + 1] else 0;
        const b2 = if (rem > 2) bytes[index + 2] else 0;
        try out.append(rt.nativeAllocator(), table[b0 >> 2]);
        try out.append(rt.nativeAllocator(), table[((b0 & 0x03) << 4) | (b1 >> 4)]);
        if (rem > 1) {
            try out.append(rt.nativeAllocator(), table[((b1 & 0x0f) << 2) | (b2 >> 6)]);
        } else if (!omit_padding) {
            try out.append(rt.nativeAllocator(), '=');
        }
        if (rem > 2) {
            try out.append(rt.nativeAllocator(), table[b2 & 0x3f]);
        } else if (!omit_padding) {
            try out.append(rt.nativeAllocator(), '=');
        }
    }
    return out;
}

fn base64Value(byte: u8, alphabet: Uint8ArrayBase64Alphabet) ?u8 {
    if (byte >= 'A' and byte <= 'Z') return byte - 'A';
    if (byte >= 'a' and byte <= 'z') return byte - 'a' + 26;
    if (byte >= '0' and byte <= '9') return byte - '0' + 52;
    if (alphabet == .base64 and byte == '+') return 62;
    if (alphabet == .base64 and byte == '/') return 63;
    if (alphabet == .base64url and byte == '-') return 62;
    if (alphabet == .base64url and byte == '_') return 63;
    return null;
}
