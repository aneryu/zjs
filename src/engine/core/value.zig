const gc = @import("gc.zig");

pub const Tag = struct {
    pub const first: i64 = -9;
    pub const big_int: i64 = -9;
    pub const symbol: i64 = -8;
    pub const string: i64 = -7;
    pub const string_rope: i64 = -6;
    pub const module: i64 = -3;
    pub const function_bytecode: i64 = -2;
    pub const object: i64 = -1;
    pub const int: i64 = 0;
    pub const boolean: i64 = 1;
    pub const null_value: i64 = 2;
    pub const undefined_value: i64 = 3;
    pub const uninitialized: i64 = 4;
    pub const catch_offset: i64 = 5;
    pub const exception: i64 = 6;
    pub const short_big_int: i64 = 7;
    pub const float64: i64 = 8;
};

const Payload = union(enum) {
    none,
    int32: i32,
    bool: bool,
    float64: f64,
    short_big_int: i32,
    ref: *gc.Header,
};

pub const Value = struct {
    tag: i64,
    payload: Payload,

    pub fn int32(v: i32) Value {
        return .{ .tag = Tag.int, .payload = .{ .int32 = v } };
    }

    pub fn float64(v: f64) Value {
        return .{ .tag = Tag.float64, .payload = .{ .float64 = v } };
    }

    pub fn boolean(v: bool) Value {
        return .{ .tag = Tag.boolean, .payload = .{ .bool = v } };
    }

    pub fn shortBigInt(v: i32) Value {
        return .{ .tag = Tag.short_big_int, .payload = .{ .short_big_int = v } };
    }

    pub fn string(header: *gc.Header) Value {
        return .{ .tag = Tag.string, .payload = .{ .ref = header } };
    }

    pub fn nullValue() Value {
        return .{ .tag = Tag.null_value, .payload = .none };
    }

    pub fn undefinedValue() Value {
        return .{ .tag = Tag.undefined_value, .payload = .none };
    }

    pub fn uninitialized() Value {
        return .{ .tag = Tag.uninitialized, .payload = .none };
    }

    pub fn exception() Value {
        return .{ .tag = Tag.exception, .payload = .none };
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

    pub fn isNull(self: Value) bool {
        return self.tag == Tag.null_value;
    }

    pub fn isUndefined(self: Value) bool {
        return self.tag == Tag.undefined_value;
    }

    pub fn isException(self: Value) bool {
        return self.tag == Tag.exception;
    }

    pub fn isUninitialized(self: Value) bool {
        return self.tag == Tag.uninitialized;
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

    pub fn isModule(self: Value) bool {
        return self.tag == Tag.module;
    }

    pub fn asInt32(self: Value) ?i32 {
        return switch (self.payload) {
            .int32 => |v| v,
            else => null,
        };
    }

    pub fn dup(self: Value) Value {
        if (self.refHeader()) |header| gc.retain(header);
        return self;
    }

    pub fn free(self: Value, rt: anytype) void {
        if (self.refHeader()) |header| gc.release(rt, header);
    }

    fn refHeader(self: Value) ?*gc.Header {
        return switch (self.payload) {
            .ref => |header| header,
            else => null,
        };
    }
};
