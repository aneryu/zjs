const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");

pub const Vm = struct {
    ctx: *core.Context,
    stack: stack_mod.Stack,
    output: ?*std.Io.Writer = null,
    last_source_line: u32 = 0,

    pub fn init(ctx: *core.Context) Vm {
        return .{
            .ctx = ctx,
            .stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.stack_limit),
        };
    }

    pub fn initWithOutput(ctx: *core.Context, output: *std.Io.Writer) Vm {
        return .{
            .ctx = ctx,
            .stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.stack_limit),
            .output = output,
        };
    }

    pub fn deinit(self: *Vm) void {
        self.stack.deinit(self.ctx.runtime);
    }

    pub fn run(self: *Vm, function: *const bytecode.Bytecode) !core.Value {
        var frame = frame_mod.Frame.init(function);
        defer frame.deinit(&self.ctx.runtime.memory, self.ctx.runtime);

        while (frame.pc < function.code.len) {
            const op = function.code[frame.pc];
            frame.pc += 1;
            switch (op) {
                bytecode.emitter.known.push_i32 => try self.pushI32(function, &frame),
                bytecode.emitter.known.push_const => try self.pushConst(function, &frame),
                bytecode.emitter.known.undefined_value => try self.stack.push(core.Value.undefinedValue()),
                bytecode.emitter.known.null_value => try self.stack.push(core.Value.nullValue()),
                bytecode.emitter.known.push_false => try self.stack.push(core.Value.boolean(false)),
                bytecode.emitter.known.push_true => try self.stack.push(core.Value.boolean(true)),
                bytecode.emitter.known.return_undef => return core.Value.undefinedValue(),
                bytecode.emitter.known.source_loc => try self.sourceLoc(function, &frame),
                178 => {},
                197...205 => try self.stack.push(core.Value.int32(@as(i32, op) - 198)),
                240...251 => try self.binaryInt(op),
                bytecode.emitter.known.host_print => try self.hostPrint(),
                253...255 => try self.compareInt(op),
                224...229 => try self.unaryInt(op),
                else => return self.throwUnsupported(op),
            }
        }
        if (self.stack.peek()) |value| return value;
        return core.Value.undefinedValue();
    }

    fn pushI32(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const value = readInt(i32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        try self.stack.push(core.Value.int32(value));
    }

    fn pushConst(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const index = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const value = function.constants.get(index) orelse return self.throwUnsupported(bytecode.emitter.known.push_const);
        defer value.free(self.ctx.runtime);
        try self.stack.push(value);
    }

    fn sourceLoc(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        _ = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        self.last_source_line = readInt(u32, function.code[frame.pc + 4 .. frame.pc + 8]);
        frame.pc += 8;
    }

    fn binaryInt(self: *Vm, op: u8) !void {
        const b = try self.stack.pop();
        defer b.free(self.ctx.runtime);
        const a = try self.stack.pop();
        defer a.free(self.ctx.runtime);
        const lhs = a.asInt32() orelse return self.throwUnsupported(op);
        const rhs = b.asInt32() orelse return self.throwUnsupported(op);
        const out = switch (op) {
            240 => lhs * rhs,
            241 => @divTrunc(lhs, rhs),
            242 => @rem(lhs, rhs),
            243 => lhs + rhs,
            244 => lhs - rhs,
            245 => lhs << @intCast(rhs & 31),
            246 => lhs >> @intCast(rhs & 31),
            247 => @as(i32, @bitCast(@as(u32, @bitCast(lhs)) >> @intCast(rhs & 31))),
            248 => lhs & rhs,
            249 => lhs ^ rhs,
            250 => lhs | rhs,
            251 => powI32(lhs, rhs),
            else => unreachable,
        };
        try self.stack.push(core.Value.int32(out));
    }

    fn compareInt(self: *Vm, op: u8) !void {
        const b = try self.stack.pop();
        defer b.free(self.ctx.runtime);
        const a = try self.stack.pop();
        defer a.free(self.ctx.runtime);
        const lhs = a.asInt32() orelse return self.throwUnsupported(op);
        const rhs = b.asInt32() orelse return self.throwUnsupported(op);
        const out = switch (op) {
            253 => lhs < rhs,
            254 => lhs <= rhs,
            255 => lhs > rhs,
            else => false,
        };
        try self.stack.push(core.Value.boolean(out));
    }

    fn unaryInt(self: *Vm, op: u8) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const n = value.asInt32() orelse return self.throwUnsupported(op);
        const out = switch (op) {
            224 => -n,
            225 => n,
            226, 228 => n - 1,
            227, 229 => n + 1,
            else => unreachable,
        };
        try self.stack.push(core.Value.int32(out));
    }

    fn hostPrint(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        if (self.output) |writer| {
            try printValue(writer, value);
            try writer.print("\n", .{});
        }
        try self.stack.push(core.Value.undefinedValue());
    }

    fn throwUnsupported(self: *Vm, op: u8) error{UnsupportedOpcode} {
        _ = self.ctx.throwValue(core.Value.int32(op));
        return error.UnsupportedOpcode;
    }
};

fn printValue(writer: *std.Io.Writer, value: core.Value) !void {
    if (value.asInt32()) |int_value| {
        try writer.print("{d}", .{int_value});
    } else if (value.asBool()) |bool_value| {
        try writer.print("{s}", .{if (bool_value) "true" else "false"});
    } else if (value.isUndefined()) {
        try writer.print("undefined", .{});
    } else if (value.isNull()) {
        try writer.print("null", .{});
    } else if (value.isString()) {
        try printString(writer, value);
    } else {
        try writer.print("[object Object]", .{});
    }
}

fn printString(writer: *std.Io.Writer, value: core.Value) !void {
    const header = value.refHeader() orelse return writer.print("[string]", .{});
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.data) {
        .latin1 => |bytes| try writer.print("{s}", .{bytes}),
        .utf16 => |units| {
            for (units) |unit| {
                if (unit <= 0x7f) {
                    try writer.writeByte(@intCast(unit));
                } else {
                    try writer.print("\\u{x}", .{unit});
                }
            }
        },
    }
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn powI32(lhs: i32, rhs: i32) i32 {
    if (rhs < 0) return 0;
    var out: i32 = 1;
    var i: i32 = 0;
    while (i < rhs) : (i += 1) out *= lhs;
    return out;
}

const std = @import("std");
