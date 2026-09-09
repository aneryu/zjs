//! Rooted async completion records owned by a Machine, independent of callee arenas.
const std = @import("std");
const core = @import("../core/root.zig");
const Value = core.JSValue;

pub const Boundary = struct {
    promise: Value = Value.undefinedValue(),
    value: Value = Value.undefinedValue(),
    callee: Value = Value.undefinedValue(),
};
comptime {
    std.debug.assert(@sizeOf(Boundary) <= 96);
}

pub const Store = struct {
    first: Boundary = .{},
    chunks: ?*Chunk = null,
    count: u32 = 0,
    const per_chunk = 16;
    const Chunk = struct { next: ?*Chunk = null, slots: [per_chunk]Boundary = undefined };

    /// Reserve an initialized root before Promise/frame allocation. Overflow
    /// is allocated once per depth high water, never once per helper call.
    pub fn begin(self: *Store, rt: *core.JSRuntime, callee: Value) !u32 {
        const id = self.count;
        if (id == std.math.maxInt(u32)) return error.OutOfMemory;
        if (id != 0) {
            var link = &self.chunks;
            var remaining = (id - 1) / per_chunk;
            while (true) {
                if (link.* == null) {
                    const chunk = try rt.memory.create(Chunk);
                    chunk.* = .{};
                    link.* = chunk;
                }
                if (remaining == 0) break;
                link = &link.*.?.next;
                remaining -= 1;
            }
        }
        self.count += 1;
        self.at(id).* = .{ .callee = callee };
        return id;
    }
    pub fn at(self: *Store, id: u32) *Boundary {
        std.debug.assert(id < self.count);
        if (id == 0) return &self.first;
        var chunk = self.chunks.?;
        var remaining = (id - 1) / per_chunk;
        while (remaining != 0) : (remaining -= 1) chunk = chunk.next.?;
        return &chunk.slots[(id - 1) % per_chunk];
    }
    pub fn release(self: *Store, id: u32) void {
        std.debug.assert(self.count != 0 and id == self.count - 1);
        self.at(id).* = .{};
        self.count -= 1;
    }
    pub fn trace(self: *Store, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        for (0..self.count) |i| {
            const slot = self.at(@intCast(i));
            try visitor.value(&slot.promise);
            try visitor.value(&slot.value);
            try visitor.value(&slot.callee);
        }
    }
    pub fn deinit(self: *Store, rt: *core.JSRuntime) void {
        std.debug.assert(self.count == 0);
        var node = self.chunks;
        while (node) |chunk| {
            node = chunk.next;
            rt.memory.destroy(Chunk, chunk);
        }
        self.chunks = null;
    }
};

test "no-suspend async overflow allocation failure leaves published roots intact" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    var store = Store{};
    defer store.deinit(rt);
    const first = try store.begin(rt, Value.int32(7));
    store.at(first).promise = Value.int32(11);
    rt.setMemoryLimit(0);
    try std.testing.expectError(error.OutOfMemory, store.begin(rt, Value.int32(8)));
    rt.setMemoryLimit(null);
    try std.testing.expectEqual(@as(u32, 1), store.count);
    try std.testing.expect(store.chunks == null);
    try std.testing.expectEqual(@as(?i32, 7), store.at(first).callee.asInt32());
    try std.testing.expectEqual(@as(?i32, 11), store.at(first).promise.asInt32());
    store.release(first);
    try std.testing.expectEqual(@as(u32, 0), store.count);
    try std.testing.expect(store.first.promise.isUndefined() and store.first.callee.isUndefined());
}
