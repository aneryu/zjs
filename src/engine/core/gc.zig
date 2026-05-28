const std = @import("std");
const memory = @import("memory.zig");
const bigint = @import("bigint.zig");
const object = @import("object.zig");
const string = @import("string.zig");

pub const RefKind = enum {
    string,
    object,
    big_int,
    function_bytecode,
};

pub const ObjectKind = enum {
    object,
    function_bytecode,
    module,
    shape,
    string,
};

pub const Phase = enum {
    none,
    decref,
    remove_cycles,
    deinit,
};

pub const Header = struct {
    kind: RefKind,
    ref_count: usize = 1,

    gc_next: ?*Header = null,
    gc_prev: ?*Header = null,
    mark: u8 = 0, // 0 = unmarked/live, 1 = decref'd, etc.
    gc_obj_type: ObjectKind = .object,
    destroy_fn: ?*const fn (header: *Header, ctx: ?*anyopaque) void = null,
    destroy_ctx: ?*anyopaque = null,

    pub fn retain(self: *Header) void {
        std.debug.assert(self.ref_count > 0);
        self.ref_count += 1;
    }
};

pub const GCObjectHeader = Header;
pub const ObjectHeader = Header;

pub const Registry = struct {
    pub const Stats = struct {
        collections: usize = 0,
        freed_objects: usize = 0,
        freed_bytecodes: usize = 0,
    };

    memory: *memory.MemoryAccount,

    // Unified double-linked intrusive list of all GC-tracked objects
    gc_obj_list_head: ?*GCObjectHeader = null,
    gc_obj_list_tail: ?*GCObjectHeader = null,

    phase: Phase = .none,
    stats: Stats = .{},

    pub fn init(account: *memory.MemoryAccount) Registry {
        return .{
            .memory = account,
        };
    }

    pub fn deinit(self: *Registry, rt: anytype) void {
        self.phase = .deinit;
        while (self.gc_obj_list_tail) |header| {
            self.unlinkFrom(&self.gc_obj_list_head, &self.gc_obj_list_tail, header);
            if (header.destroy_fn) |destroy_fn| {
                if (header.destroy_ctx) |ctx| {
                    destroy_fn(header, ctx);
                }
            } else {
                switch (header.kind) {
                    .string => string.String.destroyFromHeader(rt, header),
                    .object => object.Object.destroyFromHeader(rt, header),
                    .big_int => bigint.BigInt.destroyFromHeader(rt, header),
                    .function_bytecode => unreachable,
                }
            }
        }
        self.gc_obj_list_head = null;
        self.gc_obj_list_tail = null;
        self.phase = .none;
    }

    pub fn linkTo(self: *Registry, head_ptr: *?*GCObjectHeader, tail_ptr: *?*GCObjectHeader, header: *GCObjectHeader) void {
        _ = self;
        header.gc_prev = tail_ptr.*;
        header.gc_next = null;
        if (tail_ptr.*) |tail| {
            tail.gc_next = header;
        } else {
            head_ptr.* = header;
        }
        tail_ptr.* = header;
    }

    pub fn unlinkFrom(self: *Registry, head_ptr: *?*GCObjectHeader, tail_ptr: *?*GCObjectHeader, header: *GCObjectHeader) void {
        _ = self;
        if (header.gc_prev) |prev| {
            prev.gc_next = header.gc_next;
        } else {
            head_ptr.* = header.gc_next;
        }
        if (header.gc_next) |next| {
            next.gc_prev = header.gc_prev;
        } else {
            tail_ptr.* = header.gc_prev;
        }
        header.gc_prev = null;
        header.gc_next = null;
    }

    pub fn add(self: *Registry, header: *GCObjectHeader) !void {
        header.ref_count = 1;
        header.mark = 0;
        header.destroy_fn = null;
        header.destroy_ctx = null;
        self.linkTo(&self.gc_obj_list_head, &self.gc_obj_list_tail, header);
    }

    pub fn unlinkObject(self: *Registry, header: *GCObjectHeader) void {
        if (header.mark == 0) {
            if (header.gc_prev != null or header.gc_next != null or self.gc_obj_list_head == header) {
                self.unlinkFrom(&self.gc_obj_list_head, &self.gc_obj_list_tail, header);
            }
        }
    }

    pub fn retainObject(_: *Registry, header: *GCObjectHeader) void {
        header.retain();
    }

    pub fn releaseObject(self: *Registry, header: *GCObjectHeader) bool {
        std.debug.assert(header.ref_count > 0);
        header.ref_count -= 1;
        if (header.ref_count != 0) return false;

        if (header.mark == 0) {
            self.unlinkFrom(&self.gc_obj_list_head, &self.gc_obj_list_tail, header);
            if (header.destroy_fn) |destroy_fn| {
                if (header.destroy_ctx) |ctx| {
                    destroy_fn(header, ctx);
                }
                return true;
            }
        }
        return true;
    }

    pub fn releaseCallbackOwnedObjects(self: *Registry) void {
        while (true) {
            var current = self.gc_obj_list_tail;
            var released = false;
            while (current) |header| {
                const prev = header.gc_prev;
                if (header.destroy_fn) |destroy_fn| {
                    if (header.destroy_ctx) |ctx| {
                        if (header.ref_count == 1) {
                            self.unlinkFrom(&self.gc_obj_list_head, &self.gc_obj_list_tail, header);
                            destroy_fn(header, ctx);
                            released = true;
                            break;
                        }
                    }
                }
                current = prev;
            }
            if (!released) return;
        }
    }

    pub fn liveCount(self: Registry) usize {
        var count: usize = 0;
        var current = self.gc_obj_list_head;
        while (current) |header| {
            count += 1;
            current = header.gc_next;
        }
        return count;
    }
};

pub fn retain(header: *Header) void {
    header.ref_count += 1;
}

pub fn release(rt: anytype, header: *Header) void {
    std.debug.assert(header.ref_count > 0);
    header.ref_count -= 1;
    if (header.ref_count != 0) return;

    if (header.mark == 0) {
        if (rt.gc.phase == .deinit and header.kind == .object) return;
        rt.gc.unlinkObject(header);
        switch (header.kind) {
            .string => string.String.destroyFromHeader(rt, header),
            .object => object.Object.destroyFromHeader(rt, header),
            .big_int => bigint.BigInt.destroyFromHeader(rt, header),
            .function_bytecode => unreachable,
        }
    }
}
