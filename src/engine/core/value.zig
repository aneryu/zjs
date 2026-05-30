const gc = @import("gc.zig");

pub const Tag = struct {
    pub const first: i32 = -9;
    pub const big_int: i32 = -9;
    pub const symbol: i32 = -8;
    pub const string: i32 = -7;
    pub const string_rope: i32 = -6;
    pub const module: i32 = -3;
    pub const function_bytecode: i32 = -2;
    pub const object: i32 = -1;
    pub const int: i32 = 0;
    pub const boolean: i32 = 1;
    pub const null_value: i32 = 2;
    pub const undefined_value: i32 = 3;
    pub const uninitialized: i32 = 4;
    pub const catch_offset: i32 = 5;
    pub const exception: i32 = 6;
    pub const short_big_int: i32 = 7;
    pub const float64: i32 = 8;
};

pub const Value = extern struct {
    payload: u64,
    tag: i32,
    padding: i32 = 0,

    pub fn int32(v: i32) Value {
        return .{ .payload = payloadFromI32(v), .tag = Tag.int };
    }

    pub fn float64(v: f64) Value {
        return .{ .payload = @bitCast(v), .tag = Tag.float64 };
    }

    pub fn boolean(v: bool) Value {
        return .{ .payload = if (v) 1 else 0, .tag = Tag.boolean };
    }

    pub fn shortBigInt(v: i64) Value {
        return .{ .payload = @bitCast(v), .tag = Tag.short_big_int };
    }

    pub fn bigInt(header: *gc.Header) Value {
        return .{ .payload = @intFromPtr(header), .tag = Tag.big_int };
    }

    pub fn string(header: *gc.Header) Value {
        return .{ .payload = @intFromPtr(header), .tag = Tag.string };
    }

    pub fn stringRope(header: *gc.Header) Value {
        return .{ .payload = @intFromPtr(header), .tag = Tag.string_rope };
    }

    pub fn symbol(atom_id: u32) Value {
        return .{ .payload = atom_id, .tag = Tag.symbol };
    }

    pub fn object(header: *gc.Header) Value {
        return .{ .payload = @intFromPtr(header), .tag = Tag.object };
    }

    pub fn module(header: *gc.Header) Value {
        return .{ .payload = @intFromPtr(header), .tag = Tag.module };
    }

    pub fn functionBytecode(header: *gc.GCObjectHeader) Value {
        return .{ .payload = @intFromPtr(header), .tag = Tag.function_bytecode };
    }

    pub fn nullValue() Value {
        return .{ .payload = 0, .tag = Tag.null_value };
    }

    pub fn undefinedValue() Value {
        return .{ .payload = 0, .tag = Tag.undefined_value };
    }

    pub fn uninitialized() Value {
        return .{ .payload = 0, .tag = Tag.uninitialized };
    }

    pub fn catchOffset(offset: i32) Value {
        return .{ .payload = payloadFromI32(offset), .tag = Tag.catch_offset };
    }

    pub fn exception() Value {
        return .{ .payload = 0, .tag = Tag.exception };
    }

    pub fn isNumber(self: Value) bool {
        return self.tag == Tag.int or self.tag == Tag.float64;
    }

    pub fn isBigInt(self: Value) bool {
        return self.tag == Tag.big_int or self.tag == Tag.short_big_int;
    }

    pub fn isBool(self: Value) bool {
        return self.tag == Tag.boolean;
    }

    pub fn isString(self: Value) bool {
        return self.tag == Tag.string or self.tag == Tag.string_rope;
    }

    pub fn isSymbol(self: Value) bool {
        return self.tag == Tag.symbol;
    }

    pub fn isObject(self: Value) bool {
        return self.tag == Tag.object;
    }

    pub fn isNull(self: Value) bool {
        return self.tag == Tag.null_value;
    }

    pub fn isUndefined(self: Value) bool {
        return self.tag == Tag.undefined_value;
    }

    pub fn isUninitialized(self: Value) bool {
        return self.tag == Tag.uninitialized;
    }

    pub fn isCatchOffset(self: Value) bool {
        return self.tag == Tag.catch_offset;
    }

    pub fn isException(self: Value) bool {
        return self.tag == Tag.exception;
    }

    pub fn isModule(self: Value) bool {
        return self.tag == Tag.module;
    }

    pub fn isFunctionBytecode(self: Value) bool {
        return self.tag == Tag.function_bytecode;
    }

    pub inline fn requiresRefCount(self: Value) bool {
        switch (self.tag) {
            Tag.big_int, Tag.string, Tag.string_rope, Tag.object, Tag.module, Tag.function_bytecode => return true,
            else => return false,
        }
    }

    pub fn asInt32(self: Value) ?i32 {
        if (self.tag == Tag.int) return payloadAsI32(self.payload);
        return null;
    }

    pub fn asFloat64(self: Value) ?f64 {
        if (self.tag == Tag.float64) return @bitCast(self.payload);
        return null;
    }

    pub fn asBool(self: Value) ?bool {
        if (self.tag == Tag.boolean) return self.payload != 0;
        return null;
    }

    pub fn asSymbolAtom(self: Value) ?u32 {
        if (self.tag == Tag.symbol) return @truncate(self.payload);
        return null;
    }

    pub fn asShortBigInt(self: Value) ?i64 {
        if (self.tag == Tag.short_big_int) return @bitCast(self.payload);
        return null;
    }

    pub fn asCatchOffset(self: Value) ?i32 {
        if (self.tag == Tag.catch_offset) return payloadAsI32(self.payload);
        return null;
    }

    pub fn refHeader(self: Value) ?*gc.Header {
        return switch (self.tag) {
            Tag.big_int, Tag.string, Tag.string_rope, Tag.object, Tag.module => ptrFromPayload(gc.Header, self.payload),
            else => null,
        };
    }

    pub fn objectHeader(self: Value) ?*gc.GCObjectHeader {
        return switch (self.tag) {
            Tag.function_bytecode => ptrFromPayload(gc.GCObjectHeader, self.payload),
            else => null,
        };
    }

    pub fn dup(self: Value) Value {
        if (!self.requiresRefCount()) return self;
        if (self.refHeader()) |header| gc.retain(header);
        if (self.objectHeader()) |header| header.retain();
        return self;
    }

    pub fn free(self: Value, rt: anytype) void {
        if (!self.requiresRefCount()) return;
        if (rt.gc.phase == .deinit) {
            switch (self.tag) {
                Tag.object, Tag.module, Tag.function_bytecode => return,
                else => {},
            }
        }
        if (rt.opcode_profile) |prof| prof.recordValueFree();
        if (self.refHeader()) |header| gc.release(rt, header);
        if (self.objectHeader()) |header| gc.release(rt, header);
    }

    pub fn same(self: Value, other: Value) bool {
        if (self.tag != other.tag) return false;
        return switch (self.tag) {
            Tag.null_value, Tag.undefined_value, Tag.uninitialized, Tag.exception => true,
            Tag.int, Tag.symbol, Tag.catch_offset, Tag.boolean, Tag.float64, Tag.short_big_int, Tag.big_int, Tag.string, Tag.string_rope, Tag.module, Tag.object, Tag.function_bytecode => self.payload == other.payload,
            else => unreachable,
        };
    }
};

fn payloadFromI32(value: i32) u64 {
    const bits: u32 = @bitCast(value);
    return bits;
}

fn payloadAsI32(payload: u64) i32 {
    const bits: u32 = @truncate(payload);
    return @bitCast(bits);
}

fn ptrFromPayload(comptime T: type, payload: u64) ?*T {
    if (payload == 0) return null;
    return @ptrFromInt(payload);
}
