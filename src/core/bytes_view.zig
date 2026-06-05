const std = @import("std");

pub fn JSBytes(comptime Value: type) type {
    return struct {
        ptr: [*]const u8,
        mut_ptr: ?[*]u8 = null,
        len: usize,
        shared: bool = false,

        const Self = @This();

        pub const Error = error{
            TypeError,
            Detached,
            OutOfBounds,
            InvalidStore,
            ReadOnly,
        };

        pub fn fromMutable(bytes: []u8) Self {
            return .{
                .ptr = bytes.ptr,
                .mut_ptr = bytes.ptr,
                .len = bytes.len,
            };
        }

        pub fn fromConst(bytes: []const u8) Self {
            return .{
                .ptr = bytes.ptr,
                .len = bytes.len,
            };
        }

        pub fn fromValue(value: Value) Error!Self {
            const object = objectFromValue(value) orelse return error.TypeError;
            return fromObject(object);
        }

        pub fn fromObject(object: anytype) Error!Self {
            if (isArrayBufferObject(object)) return fromArrayBufferObject(object);
            if (isDataViewObject(object)) return fromDataViewObject(object);
            if (isTypedArrayObject(object)) return fromTypedArrayObject(object);
            return error.TypeError;
        }

        pub fn slice(self: Self) []const u8 {
            return self.ptr[0..self.len];
        }

        pub fn sliceMut(self: Self) Error![]u8 {
            const ptr = self.mut_ptr orelse return error.ReadOnly;
            return ptr[0..self.len];
        }

        pub fn isShared(self: Self) bool {
            return self.shared;
        }

        pub const Store = struct {
            bytes: []u8,
            deinit_fn: ?DeinitFn = null,
            context: ?*anyopaque = null,
            is_shared: bool = false,

            pub const DeinitFn = *const fn (context: ?*anyopaque, bytes: []u8) void;

            pub const OwnedOptions = struct {
                deinit: DeinitFn,
                context: ?*anyopaque = null,
            };

            pub const SharedOptions = struct {
                deinit: ?DeinitFn = null,
                context: ?*anyopaque = null,
            };

            pub fn owned(bytes: []u8, options: OwnedOptions) Store {
                return .{
                    .bytes = bytes,
                    .deinit_fn = options.deinit,
                    .context = options.context,
                    .is_shared = false,
                };
            }

            pub fn shared(bytes: []u8, options: SharedOptions) Store {
                return .{
                    .bytes = bytes,
                    .deinit_fn = options.deinit,
                    .context = options.context,
                    .is_shared = true,
                };
            }

            pub fn view(self: Store) Self {
                return .{
                    .ptr = self.bytes.ptr,
                    .mut_ptr = self.bytes.ptr,
                    .len = self.bytes.len,
                    .shared = self.is_shared,
                };
            }

            pub fn toArrayBuffer(self: *Store, ctx: anytype) !Value {
                const deinit_fn = self.deinit_fn orelse return error.InvalidStore;
                const rt = ctx.runtimePtr();
                if (self.is_shared) return self.toSharedArrayBuffer(rt, deinit_fn);
                const Object = @import("object.zig").Object;
                const class_ids = @import("class.zig").ids;
                const object = try Object.create(rt, class_ids.array_buffer, null);
                errdefer Object.destroyFromHeader(rt, &object.header);
                try object.installExternalByteStorage(rt, self.bytes, deinit_fn, self.context);
                self.disarm();
                return object.value();
            }

            fn toSharedArrayBuffer(self: *Store, rt: anytype, deinit_fn: DeinitFn) !Value {
                const Object = @import("object.zig").Object;
                const object_mod = @import("object.zig");
                const class_ids = @import("class.zig").ids;
                const store = try object_mod.SharedBufferStore.createExternal(rt, self.bytes, deinit_fn, self.context);
                errdefer store.release();
                const object = try Object.create(rt, class_ids.shared_array_buffer, null);
                errdefer Object.destroyFromHeader(rt, &object.header);
                object.installSharedByteStorage(rt, store);
                self.disarm();
                return object.value();
            }

            pub fn release(self: *Store) void {
                if (self.deinit_fn) |deinit_fn| deinit_fn(self.context, self.bytes);
                self.disarm();
            }

            fn disarm(self: *Store) void {
                self.* = .{ .bytes = &.{} };
            }
        };

        fn fromArrayBufferObject(object: anytype) Error!Self {
            if (object.arrayBufferDetached()) return error.Detached;
            const class_ids = @import("class.zig").ids;
            const bytes = object.byteStorage();
            return .{
                .ptr = bytes.ptr,
                .mut_ptr = if (object.arrayBufferImmutable()) null else bytes.ptr,
                .len = bytes.len,
                .shared = object.class_id == class_ids.shared_array_buffer,
            };
        }

        fn fromTypedArrayObject(object: anytype) Error!Self {
            const buffer = typedArrayBufferObject(object) orelse return error.TypeError;
            if (buffer.arrayBufferDetached()) return error.Detached;
            const class_ids = @import("class.zig").ids;
            const byte_offset = object.typedArrayByteOffset();
            const buffer_bytes = buffer.byteStorage();
            if (byte_offset > buffer_bytes.len) return error.OutOfBounds;
            const len = if (object.typedArrayFixedLength()) |fixed| blk: {
                const element_size = object.typedArrayElementSize();
                const byte_len = std.math.mul(usize, fixed, element_size) catch return error.OutOfBounds;
                if (byte_len > buffer_bytes.len - byte_offset) return error.OutOfBounds;
                break :blk byte_len;
            } else buffer_bytes.len - byte_offset;
            const bytes = buffer_bytes[byte_offset .. byte_offset + len];
            return .{
                .ptr = bytes.ptr,
                .mut_ptr = if (buffer.arrayBufferImmutable()) null else bytes.ptr,
                .len = bytes.len,
                .shared = buffer.class_id == class_ids.shared_array_buffer,
            };
        }

        fn fromDataViewObject(object: anytype) Error!Self {
            const buffer = typedArrayBufferObject(object) orelse return error.TypeError;
            if (buffer.arrayBufferDetached()) return error.Detached;
            const class_ids = @import("class.zig").ids;
            const byte_offset = object.typedArrayByteOffset();
            const buffer_bytes = buffer.byteStorage();
            if (byte_offset > buffer_bytes.len) return error.OutOfBounds;
            const len = if (object.typedArrayKind() == 1)
                buffer_bytes.len - byte_offset
            else
                object.typedArrayFixedLength() orelse return error.TypeError;
            if (len > buffer_bytes.len - byte_offset) return error.OutOfBounds;
            const bytes = buffer_bytes[byte_offset .. byte_offset + len];
            return .{
                .ptr = bytes.ptr,
                .mut_ptr = if (buffer.arrayBufferImmutable()) null else bytes.ptr,
                .len = bytes.len,
                .shared = buffer.class_id == class_ids.shared_array_buffer,
            };
        }

        fn objectFromValue(value: Value) ?*@import("object.zig").Object {
            if (!value.isObject()) return null;
            const header = value.refHeader() orelse return null;
            if (header.kind != .object) return null;
            return @fieldParentPtr("header", header);
        }

        fn typedArrayBufferObject(object: anytype) ?*@import("object.zig").Object {
            const buffer_value = object.typedArrayBuffer() orelse return null;
            const buffer = objectFromValue(buffer_value) orelse return null;
            if (!isArrayBufferObject(buffer)) return null;
            return buffer;
        }

        fn isArrayBufferObject(object: anytype) bool {
            const class_ids = @import("class.zig").ids;
            return object.class_id == class_ids.array_buffer or object.class_id == class_ids.shared_array_buffer;
        }

        fn isTypedArrayObject(object: anytype) bool {
            return object.typedArrayBuffer() != null and object.typedArrayElementSize() != 0;
        }

        fn isDataViewObject(object: anytype) bool {
            const class_ids = @import("class.zig").ids;
            return object.class_id == class_ids.dataview;
        }
    };
}

test "JSBytes distinguishes immutable and mutable borrowed slices" {
    const core = @import("root.zig");
    var mutable_bytes = [_]u8{ 1, 2, 3 };
    const mutable = core.JSValue.Bytes.fromMutable(&mutable_bytes);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, mutable.slice());
    const writable = try mutable.sliceMut();
    writable[0] = 9;
    try std.testing.expectEqual(@as(u8, 9), mutable_bytes[0]);

    const readonly = core.JSValue.Bytes.fromConst("abc");
    try std.testing.expectEqualStrings("abc", readonly.slice());
    try std.testing.expectError(error.ReadOnly, readonly.sliceMut());
}

test "JSBytes.Store invokes owned deinit once" {
    const core = @import("root.zig");
    const State = struct {
        calls: usize = 0,

        fn deinit(context: ?*anyopaque, bytes: []u8) void {
            _ = bytes;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
        }
    };

    var backing = [_]u8{ 1, 2 };
    var state = State{};
    var store = core.JSValue.Bytes.Store.owned(&backing, .{
        .deinit = State.deinit,
        .context = &state,
    });
    store.release();
    store.release();

    try std.testing.expectEqual(@as(usize, 1), state.calls);
}

test "JSBytes.Store transfers owned bytes to ArrayBuffer without copying" {
    const core = @import("root.zig");
    const State = struct {
        allocator: std.mem.Allocator,
        calls: usize = 0,

        fn deinit(context: ?*anyopaque, bytes: []u8) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.allocator.free(bytes);
        }
    };

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var state = State{ .allocator = std.testing.allocator };
    const backing = try std.testing.allocator.alloc(u8, 4);
    @memcpy(backing, &[_]u8{ 4, 5, 6, 7 });
    var store = core.JSValue.Bytes.Store.owned(backing, .{
        .deinit = State.deinit,
        .context = &state,
    });

    const value = try ctx.arrayBuffer(&store);
    try std.testing.expect(store.bytes.len == 0);
    const bytes = try value.asBytes(ctx);
    try std.testing.expectEqualSlices(u8, &.{ 4, 5, 6, 7 }, bytes.slice());
    const mutable = try bytes.sliceMut();
    mutable[2] = 9;
    try std.testing.expectEqual(@as(u8, 9), backing[2]);

    value.free(rt);
    try std.testing.expectEqual(@as(usize, 1), state.calls);
}

test "JSBytes.Store ArrayBuffer detach releases owned bytes immediately" {
    const core = @import("root.zig");
    const State = struct {
        allocator: std.mem.Allocator,
        calls: usize = 0,

        fn deinit(context: ?*anyopaque, bytes: []u8) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.allocator.free(bytes);
        }
    };

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var state = State{ .allocator = std.testing.allocator };
    const backing = try std.testing.allocator.alloc(u8, 2);
    @memcpy(backing, &[_]u8{ 1, 2 });
    var store = core.JSValue.Bytes.Store.owned(backing, .{
        .deinit = State.deinit,
        .context = &state,
    });

    const value = try ctx.arrayBuffer(&store);
    defer value.free(rt);
    const object = testObjectFromValue(core.JSValue, value).?;
    object.detachByteStorage(rt);
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectError(error.Detached, value.asBytes(ctx));
}

test "JSBytes.Store transfers shared bytes to SharedArrayBuffer without copying" {
    const core = @import("root.zig");
    const State = struct {
        allocator: std.mem.Allocator,
        calls: usize = 0,

        fn deinit(context: ?*anyopaque, bytes: []u8) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.allocator.free(bytes);
        }
    };

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var state = State{ .allocator = std.testing.allocator };
    const backing = try std.testing.allocator.alloc(u8, 3);
    @memcpy(backing, &[_]u8{ 8, 9, 10 });
    var store = core.JSValue.Bytes.Store.shared(backing, .{
        .deinit = State.deinit,
        .context = &state,
    });

    const value = try ctx.arrayBuffer(&store);
    try std.testing.expect(store.bytes.len == 0);
    const object = testObjectFromValue(core.JSValue, value).?;
    try std.testing.expectEqual(@import("class.zig").ids.shared_array_buffer, object.class_id);
    try std.testing.expect(object.sharedByteStorageStore() != null);

    const bytes = try value.asBytes(ctx);
    try std.testing.expect(bytes.isShared());
    try std.testing.expectEqualSlices(u8, &.{ 8, 9, 10 }, bytes.slice());
    const mutable = try bytes.sliceMut();
    mutable[0] = 12;
    try std.testing.expectEqual(@as(u8, 12), backing[0]);
    object.detachByteStorage(rt);
    try std.testing.expect(!object.arrayBufferDetached());
    const after_detach = try value.asBytes(ctx);
    try std.testing.expect(after_detach.isShared());
    try std.testing.expectEqualSlices(u8, &.{ 12, 9, 10 }, after_detach.slice());

    value.free(rt);
    try std.testing.expectEqual(@as(usize, 1), state.calls);
}

test "JSBytes views ArrayBuffer storage without copying" {
    const core = @import("root.zig");
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try @import("object.zig").Object.create(rt, @import("class.zig").ids.array_buffer, null);
    const value = object.value();
    defer value.free(rt);
    const backing = try rt.memory.alloc(u8, 4);
    const initial = [_]u8{ 1, 2, 3, 4 };
    @memcpy(backing, &initial);
    try object.installByteStorage(rt, backing);

    const bytes = try value.asBytes(undefined);
    try std.testing.expect(!bytes.isShared());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, bytes.slice());
    const mutable = try bytes.sliceMut();
    mutable[1] = 9;
    try std.testing.expectEqual(@as(u8, 9), object.byteStorage()[1]);

    object.arrayBufferImmutableSlot().* = true;
    const readonly = try value.asBytes(undefined);
    try std.testing.expectError(error.ReadOnly, readonly.sliceMut());
}

test "JSBytes views TypedArray byte range without copying" {
    const core = @import("root.zig");
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const Object = @import("object.zig").Object;
    const class_ids = @import("class.zig").ids;
    const buffer = try Object.create(rt, class_ids.array_buffer, null);
    const buffer_value = buffer.value();
    defer buffer_value.free(rt);
    const backing = try rt.memory.alloc(u8, 6);
    const initial = [_]u8{ 0, 1, 2, 3, 4, 5 };
    @memcpy(backing, &initial);
    try buffer.installByteStorage(rt, backing);

    const view = try Object.create(rt, class_ids.object, null);
    const view_value = view.value();
    defer view_value.free(rt);
    try view.ensureTypedArrayPayload(rt);
    try view.setOptionalValueSlot(rt, view.typedArrayBufferSlot(), buffer_value.dup());
    view.typedArrayByteOffsetSlot().* = 2;
    view.typedArrayElementSizeSlot().* = 2;
    view.typedArrayFixedLengthSlot().* = 2;
    view.typedArrayKindSlot().* = 2;

    const bytes = try view_value.asBytes(undefined);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 4, 5 }, bytes.slice());
    const mutable = try bytes.sliceMut();
    mutable[0] = 8;
    try std.testing.expectEqual(@as(u8, 8), buffer.byteStorage()[2]);
}

test "JSBytes views DataView byte range without copying" {
    const core = @import("root.zig");
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const Object = @import("object.zig").Object;
    const class_ids = @import("class.zig").ids;
    const buffer = try Object.create(rt, class_ids.array_buffer, null);
    const buffer_value = buffer.value();
    defer buffer_value.free(rt);
    const backing = try rt.memory.alloc(u8, 5);
    const initial = [_]u8{ 10, 11, 12, 13, 14 };
    @memcpy(backing, &initial);
    try buffer.installByteStorage(rt, backing);

    const view = try Object.create(rt, class_ids.dataview, null);
    const view_value = view.value();
    defer view_value.free(rt);
    try view.setOptionalValueSlot(rt, view.typedArrayBufferSlot(), buffer_value.dup());
    view.typedArrayByteOffsetSlot().* = 1;
    view.typedArrayFixedLengthSlot().* = 3;
    view.typedArrayKindSlot().* = 0;

    const bytes = try view_value.asBytes(undefined);
    try std.testing.expectEqualSlices(u8, &.{ 11, 12, 13 }, bytes.slice());
}

fn testObjectFromValue(comptime Value: type, value: Value) ?*@import("object.zig").Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    if (header.kind != .object) return null;
    return @fieldParentPtr("header", header);
}
