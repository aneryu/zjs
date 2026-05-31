//! Z-GE (Garbage Engine) Core Implementation
//! Governing Layer: third_party/zjs/src/engine/core/gc.zig
//! Following Z-GE Architecture Contract v1.0

const std = @import("std");
const builtin = @import("builtin");
const memory = @import("memory.zig");
const bigint = @import("bigint.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const bytecode_function = @import("../bytecode/function.zig");

/// 6.2 BlockHeader / GcKind definition
pub const RefKind = enum(u8) {
    string = 0,
    object = 1,
    big_int = 2,
    function_bytecode = 3,
};

pub const GcKind = RefKind;
pub const ObjectKind = enum(u8) {
    object = 0,
    function_bytecode = 1,
    module = 2,
    shape = 3,
    string = 4,
};

pub const Phase = enum {
    none,
    decref,
    remove_cycles,
    deinit,
    cycle,
};

pub const BlockFlags = packed struct(u8) {
    mark: bool = false,
    in_cycle_list: bool = false,
    finalizing: bool = false,
    immortal: bool = false,
    reserved: u4 = 0,
};

/// Z-GE v1.0 8-byte BlockHeader
pub const BlockHeader = extern struct {
    size_class: u16 align(8) = 0,
    kind: GcKind,
    flags: BlockFlags = .{},
    rc: i32 = 1,

    comptime {
        std.debug.assert(@sizeOf(BlockHeader) == 8);
    }

    pub fn retain(self: *BlockHeader) void {
        std.debug.assert(self.rc > 0);
        self.rc += 1;
    }
};

pub const Header = BlockHeader;
pub const GCObjectHeader = Header;
pub const ObjectHeader = Header;

/// 11.2 GcNode definition
pub const GcColor = enum(u8) {
    white = 0,
    gray = 1,
    black = 2,
};

pub const GcNode = extern struct {
    prev: ?*GcNode = null,
    next: ?*GcNode = null,
    tmp_rc: i32 = 0,
    color: GcColor = .white,
    _pad: [3]u8 = .{ 0, 0, 0 },

    pub fn init() GcNode {
        return .{};
    }
};

/// 19. GE Stats
pub const GeStats = struct {
    rc_inc: usize = 0,
    rc_dec: usize = 0,
    zero_ref_drains: usize = 0,

    cycle_gc_count: usize = 0,
    cycle_gc_time_ns: u64 = 0,
    cycles_collected: usize = 0,

    allocated_bytes: usize = 0,
    peak_allocated_bytes: usize = 0,
    collections: usize = 0,
    freed_objects: usize = 0,
};

/// Z-GE Registry
pub const Registry = struct {
    memory: *memory.MemoryAccount,

    // GcNode 链表头与尾，仅串联可能参与循环检测的 GcCandidate (如 Object, FunctionBytecode)
    gc_obj_list_head: ?*GcNode = null,
    gc_obj_list_tail: ?*GcNode = null,

    phase: Phase = .none,
    stats: GeStats = .{},

    // Reusable structures for cycle detection
    visited: std.AutoHashMap(usize, void),
    preserved: std.AutoHashMap(usize, void),
    free_set: std.AutoHashMap(usize, void),
    preserved_bytecodes: std.AutoHashMap(usize, void),
    object_worklist: std.ArrayList(*object.Object),
    bytecode_worklist: std.ArrayList(*bytecode_function.FunctionBytecode),

    pub fn init(account: *memory.MemoryAccount) Registry {
        return .{
            .memory = account,
            .visited = std.AutoHashMap(usize, void).init(account.persistent_allocator),
            .preserved = std.AutoHashMap(usize, void).init(account.persistent_allocator),
            .free_set = std.AutoHashMap(usize, void).init(account.persistent_allocator),
            .preserved_bytecodes = std.AutoHashMap(usize, void).init(account.persistent_allocator),
            .object_worklist = std.ArrayList(*object.Object).empty,
            .bytecode_worklist = std.ArrayList(*bytecode_function.FunctionBytecode).empty,
        };
    }

    pub fn deinit(self: *Registry, rt: anytype) void {
        self.phase = .deinit;

        // 释放可能存活的所有 Candidate 对象
        while (self.gc_obj_list_tail) |node| {
            self.unlinkNode(node);
            const h = headerFromGcNode(node);
            h.flags.finalizing = true;
            if (h.kind == .object) {
                object.Object.destroyFromHeader(rt, h);
            } else if (h.kind == .function_bytecode) {
                bytecode_function.destroyFromHeader(rt, h);
            }
        }

        self.gc_obj_list_head = null;
        self.gc_obj_list_tail = null;

        self.visited.deinit();
        self.preserved.deinit();
        self.free_set.deinit();
        self.preserved_bytecodes.deinit();
        self.object_worklist.deinit(self.memory.persistent_allocator);
        self.bytecode_worklist.deinit(self.memory.persistent_allocator);

        self.phase = .none;
    }

    pub fn add(self: *Registry, h: *GCObjectHeader) !void {
        h.rc = 1;
        h.flags = .{};

        if (h.kind == .object) {
            const obj: *object.Object = @alignCast(@fieldParentPtr("header", h));
            obj.gc._pad[0] = @intFromEnum(h.kind);
            self.linkNode(&obj.gc);
        } else if (h.kind == .function_bytecode) {
            const fb: *bytecode_function.FunctionBytecode = @alignCast(@fieldParentPtr("header", h));
            fb.gc._pad[0] = @intFromEnum(h.kind);
            self.linkNode(&fb.gc);
        }
    }

    pub fn unlinkObject(self: *Registry, h: *GCObjectHeader) void {
        if (h.kind == .object) {
            const obj: *object.Object = @alignCast(@fieldParentPtr("header", h));
            self.unlinkNode(&obj.gc);
        } else if (h.kind == .function_bytecode) {
            const fb: *bytecode_function.FunctionBytecode = @alignCast(@fieldParentPtr("header", h));
            self.unlinkNode(&fb.gc);
        }
    }

    pub fn retainObject(self: *Registry, h: *GCObjectHeader) void {
        _ = self;
        h.retain();
    }

    pub fn releaseObject(self: *Registry, h: *GCObjectHeader) bool {
        std.debug.assert(h.rc > 0);
        h.rc -= 1;
        self.stats.rc_dec += 1;

        if (h.rc == 0) {
            self.unlinkObject(h);
            return true;
        }
        return false;
    }

    pub fn linkNode(self: *Registry, node: *GcNode) void {
        node.prev = self.gc_obj_list_tail;
        node.next = null;
        if (self.gc_obj_list_tail) |tail| {
            tail.next = node;
        } else {
            self.gc_obj_list_head = node;
        }
        self.gc_obj_list_tail = node;
        node.color = .white;
    }

    pub fn unlinkNode(self: *Registry, node: *GcNode) void {
        if (self.gc_obj_list_head != node and node.prev == null) return;

        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            self.gc_obj_list_head = node.next;
        }
        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            self.gc_obj_list_tail = node.prev;
        }
        node.prev = null;
        node.next = null;
    }

    pub fn liveCount(self: Registry) usize {
        var count: usize = 0;
        var current = self.gc_obj_list_head;
        while (current) |node| {
            count += 1;
            current = node.next;
        }
        return count;
    }

    pub fn releaseCallbackOwnedObjects(self: *Registry) void {
        _ = self;
    }
};

/// 6.3 Header 反查与转换辅助
pub inline fn headerFromPayload(ptr: *anyopaque) *BlockHeader {
    const addr = @intFromPtr(ptr);
    return @ptrFromInt(addr - @sizeOf(BlockHeader));
}

pub inline fn checkedHeaderFromPayload(rt: anytype, ptr: *anyopaque) *BlockHeader {
    _ = rt;
    const h = headerFromPayload(ptr);
    if (builtin.mode == .Debug) {
        std.debug.assert(h.rc >= 0);
    }
    return h;
}

pub inline fn payloadFromHeader(h: *BlockHeader) *anyopaque {
    const addr = @intFromPtr(h);
    return @ptrFromInt(addr + @sizeOf(BlockHeader));
}

pub inline fn objectFromGcNode(node: *GcNode) *object.Object {
    return @alignCast(@fieldParentPtr("gc", node));
}

pub inline fn headerFromGcNode(node: *GcNode) *BlockHeader {
    const kind: RefKind = @enumFromInt(node._pad[0]);
    switch (kind) {
        .object => {
            const obj: *object.Object = @alignCast(@fieldParentPtr("gc", node));
            return &obj.header;
        },
        .function_bytecode => {
            const fb: *bytecode_function.FunctionBytecode = @alignCast(@fieldParentPtr("gc", node));
            return &fb.header;
        },
        else => unreachable,
    }
}

/// 9.1 统一的非原子 retain/release/dup/free 路径
pub fn retain(header: *Header) void {
    header.retain();
}

pub fn release(rt: anytype, header: *Header) void {
    std.debug.assert(header.rc > 0);
    header.rc -= 1;
    rt.gc.stats.rc_dec += 1;

    if (header.rc == 0) {
        if (rt.gc.phase == .deinit and header.kind == .object) return;
        rt.gc.unlinkObject(header);

        // 10.1 静态 kind switch 派发销毁
        switch (header.kind) {
            .string => string.String.destroyFromHeader(rt, header),
            .object => object.Object.destroyFromHeader(rt, header),
            .big_int => bigint.BigInt.destroyFromHeader(rt, header),
            .function_bytecode => bytecode_function.destroyFromHeader(rt, header),
        }
    }
}
