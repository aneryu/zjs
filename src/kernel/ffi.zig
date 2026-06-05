const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/root.zig");
const PropNameID = @import("prop_name.zig").PropNameID;

pub const abi_version: u32 = 1;
pub const magic: u32 = 0x5a_4a_53_46; // ZJSF
pub const supported_features: u64 =
    featureBit(.zig_slice_views) |
    featureBit(.js_bytes_store) |
    featureBit(.opaque_host_object) |
    featureBit(.prop_name_id);

pub const Feature = enum(u6) {
    zig_slice_views = 0,
    js_bytes_store = 1,
    opaque_host_object = 2,
    prop_name_id = 3,
};

pub fn featureBit(comptime feature: Feature) u64 {
    return @as(u64, 1) << @intFromEnum(feature);
}

pub const Endian = enum(u8) {
    little = 0,
    big = 1,
};

pub const Target = extern struct {
    arch: u32,
    os: u32,
    abi: u32,
    pointer_bits: u16,
    endian: Endian,
    reserved: [5]u8 = @splat(0),

    pub fn native() Target {
        return .{
            .arch = @intFromEnum(builtin.target.cpu.arch),
            .os = @intFromEnum(builtin.target.os.tag),
            .abi = @intFromEnum(builtin.target.abi),
            .pointer_bits = builtin.target.ptrBitWidth(),
            .endian = switch (builtin.target.cpu.arch.endian()) {
                .little => .little,
                .big => .big,
            },
        };
    }

    pub fn eql(self: Target, other: Target) bool {
        return self.arch == other.arch and
            self.os == other.os and
            self.abi == other.abi and
            self.pointer_bits == other.pointer_bits and
            self.endian == other.endian;
    }
};

pub const DescriptorHeader = extern struct {
    magic: u32 = magic,
    abi_version: u32 = abi_version,
    target: Target = Target.native(),
    js_value_size: u16 = @sizeOf(core.JSValue),
    js_value_align: u16 = @alignOf(core.JSValue),
    js_value_layout_hash: u64 = js_value_layout_hash,
    descriptor_size: u32,
    feature_flags: u64 = 0,
};

pub const ValidationError = error{
    BadMagic,
    UnsupportedAbiVersion,
    TargetMismatch,
    JSValueLayoutMismatch,
    DescriptorTooSmall,
    UnsupportedFeatureFlags,
    MissingBindingName,
    MissingBindingCall,
    MissingHostObjectName,
    InvalidHostTypeId,
    MissingHostObjectFinalizer,
    MissingPropName,
};

pub fn validateHeader(header: *const DescriptorHeader, comptime Descriptor: type, supported: u64) ValidationError!void {
    if (header.magic != magic) return error.BadMagic;
    if (header.abi_version != abi_version) return error.UnsupportedAbiVersion;
    if (!header.target.eql(Target.native())) return error.TargetMismatch;
    if (header.js_value_size != @sizeOf(core.JSValue) or
        header.js_value_align != @alignOf(core.JSValue) or
        header.js_value_layout_hash != js_value_layout_hash)
    {
        return error.JSValueLayoutMismatch;
    }
    if (header.descriptor_size < @sizeOf(Descriptor)) return error.DescriptorTooSmall;
    if ((header.feature_flags & ~supported) != 0) return error.UnsupportedFeatureFlags;
}

pub const BorrowedBytes = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,

    pub fn from(data: []const u8) BorrowedBytes {
        return .{
            .ptr = if (data.len == 0) null else data.ptr,
            .len = data.len,
        };
    }

    pub fn slice(self: BorrowedBytes) []const u8 {
        const ptr = self.ptr orelse return &.{};
        return ptr[0..self.len];
    }
};

pub const MutableBytes = extern struct {
    ptr: ?[*]u8 = null,
    len: usize = 0,

    pub fn from(data: []u8) MutableBytes {
        return .{
            .ptr = if (data.len == 0) null else data.ptr,
            .len = data.len,
        };
    }

    pub fn slice(self: MutableBytes) []u8 {
        const ptr = self.ptr orelse return &.{};
        return ptr[0..self.len];
    }
};

pub const JSValueSlice = extern struct {
    ptr: ?[*]const core.JSValue = null,
    len: usize = 0,

    pub fn from(values: []const core.JSValue) JSValueSlice {
        return .{
            .ptr = if (values.len == 0) null else values.ptr,
            .len = values.len,
        };
    }

    pub fn slice(self: JSValueSlice) []const core.JSValue {
        const ptr = self.ptr orelse return &.{};
        return ptr[0..self.len];
    }
};

pub const StringPolicy = enum(u32) {
    utf8_borrow = 1,
    utf8_copy = 2,
    c_string_borrow = 3,
    c_string_copy = 4,
};

pub const StringLifetime = enum(u32) {
    borrow = 1,
    copy = 2,
};

pub const StringDescriptor = extern struct {
    policy: StringPolicy,
};

pub fn stringUtf8(lifetime: StringLifetime) StringDescriptor {
    return .{
        .policy = switch (lifetime) {
            .borrow => .utf8_borrow,
            .copy => .utf8_copy,
        },
    };
}

pub fn cString(lifetime: StringLifetime) StringDescriptor {
    return .{
        .policy = switch (lifetime) {
            .borrow => .c_string_borrow,
            .copy => .c_string_copy,
        },
    };
}

pub const BytesPolicy = enum(u32) {
    copy = 1,
    owned = 2,
    shared = 3,
};

pub const BytesDeinitFn = *const fn (context: ?*anyopaque, bytes: MutableBytes) callconv(.c) void;

pub const OwnedBytesOptions = extern struct {
    deinit: BytesDeinitFn,
    context: ?*anyopaque = null,
};

pub const BytesLifetime = union(enum) {
    copy,
    owned: OwnedBytesOptions,
    shared,
};

pub const Bytes = struct {
    pub fn owned(options: OwnedBytesOptions) BytesLifetime {
        return .{ .owned = options };
    }
};

pub const BytesDescriptor = extern struct {
    policy: BytesPolicy,
    deinit: ?BytesDeinitFn = null,
    context: ?*anyopaque = null,
};

pub fn bytes(lifetime: BytesLifetime) BytesDescriptor {
    return switch (lifetime) {
        .copy => .{ .policy = .copy },
        .owned => |options| .{
            .policy = .owned,
            .deinit = options.deinit,
            .context = options.context,
        },
        .shared => .{ .policy = .shared },
    };
}

pub const HostTypeId = extern struct {
    value: u64 = 0,

    pub fn fromInt(value: u64) HostTypeId {
        return .{ .value = value };
    }

    pub fn named(comptime name: []const u8) HostTypeId {
        if (name.len == 0) @compileError("zjs.ffi.HostTypeId.named requires a non-empty name");
        const value = comptime hostTypeHash(name);
        return .{ .value = value };
    }

    pub fn isValid(self: HostTypeId) bool {
        return self.value != 0;
    }
};

pub const OpaqueHostObject = extern struct {
    ptr: ?*anyopaque = null,
    type_id: HostTypeId = .{},

    pub fn from(ptr: *anyopaque, type_id: HostTypeId) OpaqueHostObject {
        return .{
            .ptr = ptr,
            .type_id = type_id,
        };
    }
};

pub const HostTraceVisitor = extern struct {
    context: ?*anyopaque = null,
    visit_value: ?*const fn (context: ?*anyopaque, value: *core.JSValue) callconv(.c) void = null,

    pub fn value(self: *HostTraceVisitor, slot: *core.JSValue) void {
        const visit = self.visit_value orelse return;
        visit(self.context, slot);
    }
};

pub const HostObjectFinalizer = *const fn (context: ?*anyopaque, object: OpaqueHostObject) callconv(.c) void;
pub const HostObjectTracer = *const fn (context: ?*anyopaque, object: OpaqueHostObject, visitor: *HostTraceVisitor) callconv(.c) void;

pub const HostObjectOwner = enum(u32) {
    host = 1,
    js = 2,
};

pub const HostObjectOptions = struct {
    owner: HostObjectOwner = .js,
    finalizer: ?HostObjectFinalizer = null,
    tracer: ?HostObjectTracer = null,
    context: ?*anyopaque = null,
};

pub const HostObjectDescriptor = extern struct {
    name: BorrowedBytes = .{},
    type_id: HostTypeId = .{},
    owner: HostObjectOwner = .js,
    finalizer: ?HostObjectFinalizer = null,
    tracer: ?HostObjectTracer = null,
    context: ?*anyopaque = null,
};

pub fn hostObject(comptime name: []const u8, type_id: HostTypeId, options: HostObjectOptions) HostObjectDescriptor {
    return .{
        .name = BorrowedBytes.from(name),
        .type_id = type_id,
        .owner = options.owner,
        .finalizer = options.finalizer,
        .tracer = options.tracer,
        .context = options.context,
    };
}

pub const PropNameDescriptor = extern struct {
    name: BorrowedBytes = .{},
};

pub fn propName(comptime name: []const u8) PropNameDescriptor {
    return .{ .name = BorrowedBytes.from(name) };
}

pub const ResolvedPropNames = struct {
    runtime: *core.JSRuntime,
    ids: []PropNameID,

    pub fn deinit(self: *ResolvedPropNames) void {
        const rt = self.runtime;
        for (self.ids) |id| id.release(rt);
        rt.memory.free(PropNameID, self.ids);
        self.* = .{
            .runtime = rt,
            .ids = &.{},
        };
    }
};

pub fn resolvePropNames(rt: *core.JSRuntime, descriptors: []const PropNameDescriptor) !ResolvedPropNames {
    const ids = try rt.memory.alloc(PropNameID, descriptors.len);
    errdefer rt.memory.free(PropNameID, ids);
    var initialized: usize = 0;
    errdefer {
        for (ids[0..initialized]) |id| id.release(rt);
    }

    for (descriptors, 0..) |descriptor, index| {
        try validatePropName(descriptor);
        ids[index] = try PropNameID.internStatic(rt, descriptor.name.slice());
        initialized += 1;
    }

    return .{
        .runtime = rt,
        .ids = ids,
    };
}

pub const Status = enum(u32) {
    ok = 0,
    pending_exception = 1,
    out_of_memory = 2,
    type_error = 3,
    range_error = 4,
    unsupported = 5,
    syntax_error = 6,
    generic_error = 7,
};

pub const CallFrame = extern struct {
    ctx: ?*anyopaque = null,
    this_value: core.JSValue = core.JSValue.undefinedValue(),
    args: JSValueSlice = .{},
    result: core.JSValue = core.JSValue.undefinedValue(),
    error_status: Status = .ok,
};

pub const Trampoline = *const fn (frame: *CallFrame) callconv(.c) Status;
pub const DescriptorExport = *const fn () callconv(.c) ?*const PluginDescriptor;
pub const descriptor_symbol: [:0]const u8 = "zjs_plugin_descriptor";

pub const ZigCall = struct {
    ctx: *core.JSContext,
    this_value: core.JSValue,
    args: []const core.JSValue,

    pub fn fromFrame(frame: *const CallFrame) error{TypeError}!ZigCall {
        const raw_ctx = frame.ctx orelse return error.TypeError;
        return .{
            .ctx = @ptrCast(@alignCast(raw_ctx)),
            .this_value = frame.this_value,
            .args = frame.args.slice(),
        };
    }
};

pub fn trampoline(comptime call: anytype) Trampoline {
    comptime validateTrampolineSignature(@TypeOf(call));
    return struct {
        fn invoke(frame: *CallFrame) callconv(.c) Status {
            return invokeTrampoline(call, frame);
        }
    }.invoke;
}

pub fn binding(comptime name: []const u8, comptime call: anytype) BindingDescriptor {
    return .{
        .name = BorrowedBytes.from(name),
        .feature_flags = featureBit(.zig_slice_views),
        .call = trampoline(call),
    };
}

pub const BindingDescriptor = extern struct {
    name: BorrowedBytes = .{},
    feature_flags: u64 = 0,
    call: ?Trampoline = null,
};

pub const PluginDescriptor = extern struct {
    header: DescriptorHeader = .{ .descriptor_size = @sizeOf(PluginDescriptor) },
    name: BorrowedBytes = .{},
    binding_count: u32 = 0,
    bindings: ?[*]const BindingDescriptor = null,
    host_object_count: u32 = 0,
    host_objects: ?[*]const HostObjectDescriptor = null,
    prop_name_count: u32 = 0,
    prop_names: ?[*]const PropNameDescriptor = null,

    pub fn bindingSlice(self: *const PluginDescriptor) []const BindingDescriptor {
        const ptr = self.bindings orelse return &.{};
        return ptr[0..self.binding_count];
    }

    pub fn hostObjectSlice(self: *const PluginDescriptor) []const HostObjectDescriptor {
        const ptr = self.host_objects orelse return &.{};
        return ptr[0..self.host_object_count];
    }

    pub fn propNameSlice(self: *const PluginDescriptor) []const PropNameDescriptor {
        const ptr = self.prop_names orelse return &.{};
        return ptr[0..self.prop_name_count];
    }
};

pub fn Plugin(comptime plugin_name: []const u8, comptime entries: anytype) type {
    const Entries = @TypeOf(entries);
    const info = switch (@typeInfo(Entries)) {
        .@"struct" => |struct_info| struct_info,
        else => @compileError("zjs.ffi.Plugin bindings must be a tuple, for example .{ zjs.ffi.binding(\"read\", read) }"),
    };
    if (!info.is_tuple) @compileError("zjs.ffi.Plugin bindings must be a tuple, for example .{ zjs.ffi.binding(\"read\", read) }");
    const binding_count = info.fields.len;

    return struct {
        pub const bindings: [binding_count]BindingDescriptor = blk: {
            var table: [binding_count]BindingDescriptor = undefined;
            for (entries, 0..) |entry, index| {
                table[index] = entry;
            }
            break :blk table;
        };

        pub const descriptor_value = PluginDescriptor{
            .header = .{
                .descriptor_size = @sizeOf(PluginDescriptor),
                .feature_flags = supported_features,
            },
            .name = BorrowedBytes.from(plugin_name),
            .binding_count = @intCast(binding_count),
            .bindings = if (binding_count == 0) null else &bindings,
        };

        pub fn descriptor() *const PluginDescriptor {
            return &descriptor_value;
        }

        pub fn descriptorExport() callconv(.c) ?*const PluginDescriptor {
            return descriptor();
        }
    };
}

pub fn validatePlugin(descriptor: *const PluginDescriptor) ValidationError!void {
    try validateHeader(&descriptor.header, PluginDescriptor, supported_features);
    if (descriptor.binding_count != 0 and descriptor.bindings == null) return error.DescriptorTooSmall;
    if (descriptor.host_object_count != 0 and descriptor.host_objects == null) return error.DescriptorTooSmall;
    if (descriptor.prop_name_count != 0 and descriptor.prop_names == null) return error.DescriptorTooSmall;
    for (descriptor.bindingSlice()) |entry| {
        if (entry.name.len == 0 or entry.name.ptr == null) return error.MissingBindingName;
        if (entry.call == null) return error.MissingBindingCall;
    }
    for (descriptor.hostObjectSlice()) |entry| {
        try validateHostObject(entry);
    }
    for (descriptor.propNameSlice()) |entry| {
        try validatePropName(entry);
    }
}

pub fn validateHostObject(descriptor: HostObjectDescriptor) ValidationError!void {
    if (descriptor.name.len == 0 or descriptor.name.ptr == null) return error.MissingHostObjectName;
    if (!descriptor.type_id.isValid()) return error.InvalidHostTypeId;
    if (descriptor.owner == .js and descriptor.finalizer == null) return error.MissingHostObjectFinalizer;
}

pub fn validatePropName(descriptor: PropNameDescriptor) ValidationError!void {
    if (descriptor.name.len == 0 or descriptor.name.ptr == null) return error.MissingPropName;
}

pub const LoadError = std.DynLib.Error || ValidationError || error{
    MissingDescriptorSymbol,
    NullDescriptor,
};

pub const LoadedPlugin = struct {
    lib: std.DynLib,
    descriptor: *const PluginDescriptor,

    pub fn open(path: []const u8) LoadError!LoadedPlugin {
        var lib = try std.DynLib.open(path);
        errdefer lib.close();
        const get_descriptor = lib.lookup(DescriptorExport, descriptor_symbol) orelse return error.MissingDescriptorSymbol;
        const descriptor = try descriptorFromExport(get_descriptor);
        return .{
            .lib = lib,
            .descriptor = descriptor,
        };
    }

    pub fn deinit(self: *LoadedPlugin) void {
        self.lib.close();
        self.* = undefined;
    }

    pub fn bindings(self: *const LoadedPlugin) []const BindingDescriptor {
        return self.descriptor.bindingSlice();
    }
};

pub fn descriptorFromExport(get_descriptor: DescriptorExport) LoadError!*const PluginDescriptor {
    const descriptor = get_descriptor() orelse return error.NullDescriptor;
    try validatePlugin(descriptor);
    return descriptor;
}

pub fn statusFromError(err: anyerror) Status {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.TypeError => .type_error,
        error.RangeError => .range_error,
        error.SyntaxError => .syntax_error,
        error.PendingException => .pending_exception,
        error.Unsupported => .unsupported,
        else => .generic_error,
    };
}

fn invokeTrampoline(comptime call: anytype, frame: *CallFrame) Status {
    const result = invokeZig(call, frame) catch |err| {
        const status = statusFromError(err);
        frame.result = core.JSValue.exception();
        frame.error_status = status;
        return status;
    };
    frame.result = result;
    frame.error_status = .ok;
    return .ok;
}

fn invokeZig(comptime call: anytype, frame: *CallFrame) anyerror!core.JSValue {
    const Call = @TypeOf(call);
    const info = @typeInfo(Call).@"fn";

    if (info.params.len == 1) {
        const Param = info.params[0].type orelse @compileError("zjs.ffi.trampoline parameters must have concrete types");
        if (Param == *CallFrame) {
            const status = @call(.auto, call, .{frame});
            frame.error_status = status;
            return frame.result;
        }
        if (Param == ZigCall) {
            return resultToValue(@call(.auto, call, .{try ZigCall.fromFrame(frame)}));
        }
    }

    if (info.params.len == 3) {
        const Ctx = info.params[0].type orelse @compileError("zjs.ffi.trampoline parameters must have concrete types");
        const This = info.params[1].type orelse @compileError("zjs.ffi.trampoline parameters must have concrete types");
        const Args = info.params[2].type orelse @compileError("zjs.ffi.trampoline parameters must have concrete types");
        if (Ctx == *core.JSContext and This == core.JSValue and Args == []const core.JSValue) {
            const zig_call = try ZigCall.fromFrame(frame);
            return resultToValue(@call(.auto, call, .{ zig_call.ctx, zig_call.this_value, zig_call.args }));
        }
    }

    unreachable;
}

fn resultToValue(result: anytype) anyerror!core.JSValue {
    const Result = @TypeOf(result);
    if (Result == core.JSValue) return result;
    return switch (@typeInfo(Result)) {
        .void => core.JSValue.undefinedValue(),
        .error_union => resultToValue(try result),
        .bool => core.JSValue.boolean(result),
        .int, .comptime_int => integerToValue(result),
        .float, .comptime_float => core.JSValue.float64(@floatCast(result)),
        else => @compileError("unsupported zjs.ffi.trampoline return type: " ++ @typeName(Result)),
    };
}

fn integerToValue(value: anytype) core.JSValue {
    if (std.math.cast(i32, value)) |int| return core.JSValue.int32(int);
    return core.JSValue.float64(@floatFromInt(value));
}

fn validateTrampolineSignature(comptime Call: type) void {
    const info = @typeInfo(Call).@"fn";
    if (info.calling_convention != .auto and info.calling_convention != .@"inline") {
        @compileError("zjs.ffi.trampoline expects a Zig function; the generated adapter owns the C calling convention");
    }

    if (info.params.len == 1) {
        const Param = info.params[0].type orelse @compileError("zjs.ffi.trampoline parameters must have concrete types");
        if (Param == *CallFrame) {
            if (info.return_type != Status) @compileError("raw zjs.ffi CallFrame trampoline must return zjs.ffi.Status");
            return;
        }
        if (Param == ZigCall) {
            validateTrampolineReturn(info.return_type);
            return;
        }
    }

    if (info.params.len == 3) {
        const Ctx = info.params[0].type orelse @compileError("zjs.ffi.trampoline parameters must have concrete types");
        const This = info.params[1].type orelse @compileError("zjs.ffi.trampoline parameters must have concrete types");
        const Args = info.params[2].type orelse @compileError("zjs.ffi.trampoline parameters must have concrete types");
        if (Ctx == *core.JSContext and This == core.JSValue and Args == []const core.JSValue) {
            validateTrampolineReturn(info.return_type);
            return;
        }
    }

    @compileError(
        "unsupported zjs.ffi.trampoline signature; use fn (zjs.ffi.ZigCall) !JSValue, " ++
            "fn (*JSContext, JSValue, []const JSValue) !JSValue, or raw fn (*zjs.ffi.CallFrame) callconv(.zig) zjs.ffi.Status",
    );
}

fn validateTrampolineReturn(comptime Return: ?type) void {
    const R = Return orelse @compileError("zjs.ffi.trampoline function must return a value");
    _ = resultToValueFromType(R);
}

fn resultToValueFromType(comptime T: type) void {
    if (T == core.JSValue) return;
    switch (@typeInfo(T)) {
        .void, .bool, .int, .comptime_int, .float, .comptime_float => return,
        .error_union => |err| return resultToValueFromType(err.payload),
        else => @compileError("unsupported zjs.ffi.trampoline return type: " ++ @typeName(T)),
    }
}

pub const js_value_layout_hash = jsValueLayoutHash();

fn jsValueLayoutHash() u64 {
    var hasher = std.hash.Fnv1a_64.init();
    hashInt(&hasher, @sizeOf(core.JSValue));
    hashInt(&hasher, @alignOf(core.JSValue));
    hashInt(&hasher, @offsetOf(core.JSValue, "payload"));
    hashInt(&hasher, @offsetOf(core.JSValue, "tag"));
    hashInt(&hasher, @offsetOf(core.JSValue, "padding"));
    hashInt(&hasher, @sizeOf(@TypeOf(@as(core.JSValue, undefined).payload)));
    hashInt(&hasher, @sizeOf(@TypeOf(@as(core.JSValue, undefined).tag)));
    return hasher.final();
}

fn hashInt(hasher: *std.hash.Fnv1a_64, value: anytype) void {
    var remaining: u64 = @intCast(value);
    var index: usize = 0;
    while (index < @sizeOf(u64)) : (index += 1) {
        hasher.update(&.{@truncate(remaining)});
        remaining >>= 8;
    }
}

fn hostTypeHash(comptime name: []const u8) u64 {
    @setEvalBranchQuota(2000);
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update("zjs.host-type.v1:");
    hasher.update(name);
    const value = hasher.final();
    return if (value == 0) 1 else value;
}

test "FFI descriptor validates current target and JSValue layout" {
    const descriptor = PluginDescriptor{
        .header = .{
            .descriptor_size = @sizeOf(PluginDescriptor),
            .feature_flags = featureBit(.zig_slice_views),
        },
        .name = BorrowedBytes.from("plugin"),
    };
    try validatePlugin(&descriptor);
}

test "FFI descriptor rejects unsupported features" {
    var descriptor = PluginDescriptor{
        .header = .{
            .descriptor_size = @sizeOf(PluginDescriptor),
            .feature_flags = @as(u64, 1) << 63,
        },
    };
    try std.testing.expectError(error.UnsupportedFeatureFlags, validatePlugin(&descriptor));
    descriptor.header.feature_flags = 0;
    descriptor.header.js_value_size += 1;
    try std.testing.expectError(error.JSValueLayoutMismatch, validatePlugin(&descriptor));
}

test "FFI descriptor validates binding names and trampolines" {
    const Impl = struct {
        fn noop(call: ZigCall) void {
            _ = call;
        }
    };
    var valid_binding = binding("valid", Impl.noop);
    var descriptor = PluginDescriptor{
        .header = .{
            .descriptor_size = @sizeOf(PluginDescriptor),
        },
        .binding_count = 1,
        .bindings = @ptrCast(&valid_binding),
    };
    try validatePlugin(&descriptor);
    try std.testing.expectEqual(@as(usize, 1), descriptor.bindingSlice().len);

    valid_binding.name = .{};
    try std.testing.expectError(error.MissingBindingName, validatePlugin(&descriptor));

    valid_binding.name = BorrowedBytes.from("valid");
    valid_binding.call = null;
    try std.testing.expectError(error.MissingBindingCall, validatePlugin(&descriptor));
}

test "FFI string lifetime descriptors are explicit" {
    try std.testing.expectEqual(StringPolicy.utf8_borrow, stringUtf8(.borrow).policy);
    try std.testing.expectEqual(StringPolicy.utf8_copy, stringUtf8(.copy).policy);
    try std.testing.expectEqual(StringPolicy.c_string_borrow, cString(.borrow).policy);
    try std.testing.expectEqual(StringPolicy.c_string_copy, cString(.copy).policy);
}

test "FFI bytes lifetime descriptors carry ownership finalizer without copying" {
    const State = struct {
        calls: usize = 0,
        ptr: ?[*]u8 = null,
        len: usize = 0,

        fn deinit(context: ?*anyopaque, view: MutableBytes) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            const slice = view.slice();
            self.ptr = if (slice.len == 0) null else slice.ptr;
            self.len = slice.len;
        }
    };

    try std.testing.expectEqual(BytesPolicy.copy, bytes(.copy).policy);
    try std.testing.expectEqual(BytesPolicy.shared, bytes(.shared).policy);

    var state = State{};
    var backing = [_]u8{ 1, 2, 3, 4 };
    const descriptor = bytes(Bytes.owned(.{
        .deinit = State.deinit,
        .context = &state,
    }));
    try std.testing.expectEqual(BytesPolicy.owned, descriptor.policy);
    try std.testing.expect(descriptor.deinit != null);

    descriptor.deinit.?(descriptor.context, MutableBytes.from(&backing));
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expect(state.ptr == &backing);
    try std.testing.expectEqual(@as(usize, 4), state.len);
}

test "FFI host object descriptors validate type id and required finalizer" {
    const Hooks = struct {
        fn finalize(context: ?*anyopaque, object: OpaqueHostObject) callconv(.c) void {
            _ = context;
            _ = object;
        }
    };

    var descriptor = hostObject("HostFile", HostTypeId.named("test.HostFile"), .{
        .owner = .js,
        .finalizer = Hooks.finalize,
    });
    try validateHostObject(descriptor);

    var plugin = PluginDescriptor{
        .header = .{
            .descriptor_size = @sizeOf(PluginDescriptor),
            .feature_flags = featureBit(.opaque_host_object),
        },
        .host_object_count = 1,
        .host_objects = @ptrCast(&descriptor),
    };
    try validatePlugin(&plugin);
    try std.testing.expectEqual(@as(usize, 1), plugin.hostObjectSlice().len);

    descriptor.name = .{};
    try std.testing.expectError(error.MissingHostObjectName, validatePlugin(&plugin));

    descriptor.name = BorrowedBytes.from("HostFile");
    descriptor.type_id = .{};
    try std.testing.expectError(error.InvalidHostTypeId, validatePlugin(&plugin));

    descriptor.type_id = HostTypeId.named("test.HostFile");
    descriptor.finalizer = null;
    try std.testing.expectError(error.MissingHostObjectFinalizer, validatePlugin(&plugin));

    descriptor.owner = .host;
    try validatePlugin(&plugin);
}

test "FFI opaque host object finalizer and tracer preserve pointer identity" {
    const type_id = HostTypeId.named("test.TraceHost");
    const State = struct {
        finalize_calls: usize = 0,
        trace_calls: usize = 0,
        seen_object: ?*anyopaque = null,
        seen_type: HostTypeId = .{},
        slot: core.JSValue = core.JSValue.int32(7),
        slot_visits: usize = 0,

        fn finalize(context: ?*anyopaque, object: OpaqueHostObject) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.finalize_calls += 1;
            self.seen_object = object.ptr;
            self.seen_type = object.type_id;
        }

        fn trace(context: ?*anyopaque, object: OpaqueHostObject, visitor: *HostTraceVisitor) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.trace_calls += 1;
            self.seen_object = object.ptr;
            self.seen_type = object.type_id;
            visitor.value(&self.slot);
        }

        fn visitValue(context: ?*anyopaque, value: *core.JSValue) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (value == &self.slot) self.slot_visits += 1;
        }
    };

    var state = State{};
    const object = OpaqueHostObject.from(@ptrCast(&state), type_id);
    const descriptor = hostObject("TraceHost", type_id, .{
        .owner = .js,
        .finalizer = State.finalize,
        .tracer = State.trace,
        .context = &state,
    });

    var visitor = HostTraceVisitor{
        .context = &state,
        .visit_value = State.visitValue,
    };
    descriptor.tracer.?(descriptor.context, object, &visitor);
    descriptor.finalizer.?(descriptor.context, object);

    try std.testing.expectEqual(@as(usize, 1), state.trace_calls);
    try std.testing.expectEqual(@as(usize, 1), state.finalize_calls);
    try std.testing.expectEqual(@as(usize, 1), state.slot_visits);
    try std.testing.expect(state.seen_object == @as(*anyopaque, @ptrCast(&state)));
    try std.testing.expectEqual(type_id.value, state.seen_type.value);
}

test "FFI prop name descriptors validate and resolve to interned PropNameID" {
    var prop_names = [_]PropNameDescriptor{
        propName("alpha"),
        propName("beta"),
    };
    var plugin = PluginDescriptor{
        .header = .{
            .descriptor_size = @sizeOf(PluginDescriptor),
            .feature_flags = featureBit(.prop_name_id),
        },
        .prop_name_count = prop_names.len,
        .prop_names = @ptrCast(&prop_names),
    };
    try validatePlugin(&plugin);
    try std.testing.expectEqual(@as(usize, 2), plugin.propNameSlice().len);

    prop_names[1] = .{};
    try std.testing.expectError(error.MissingPropName, validatePlugin(&plugin));
    prop_names[1] = propName("beta");

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    var resolved = try resolvePropNames(rt, plugin.propNameSlice());
    defer resolved.deinit();

    try std.testing.expectEqualStrings("alpha", resolved.ids[0].debugName(rt).?);
    try std.testing.expectEqualStrings("beta", resolved.ids[1].debugName(rt).?);

    const object = try core.Object.create(rt, core.class.ids.object, null);
    const object_value = object.value();
    defer object_value.free(rt);
    try resolved.ids[0].defineDataProperty(rt, object, core.Descriptor.data(core.JSValue.int32(42), true, true, true));
    const stored = resolved.ids[0].getProperty(object);
    defer stored.free(rt);
    try std.testing.expectEqual(@as(i32, 42), stored.asInt32().?);
}

test "FFI byte and value descriptors are zero-copy views" {
    var backing = [_]u8{ 1, 2, 3 };
    const ro = BorrowedBytes.from(&backing);
    var rw = MutableBytes.from(&backing);
    try std.testing.expect(ro.slice().ptr == &backing);
    try std.testing.expect(rw.slice().ptr == &backing);
    rw.slice()[1] = 9;
    try std.testing.expectEqual(@as(u8, 9), backing[1]);

    const values = [_]core.JSValue{ core.JSValue.int32(1), core.JSValue.boolean(true) };
    const view = JSValueSlice.from(&values);
    try std.testing.expect(view.slice().ptr == &values);
    try std.testing.expectEqual(@as(i32, 1), view.slice()[0].asInt32().?);
}

test "FFI trampoline adapts C ABI frame to ZigCall without copying args" {
    const Impl = struct {
        fn add(call: ZigCall) !core.JSValue {
            if (call.args.len != 2) return error.TypeError;
            return core.JSValue.int32(call.args[0].asInt32().? + call.args[1].asInt32().?);
        }
    };

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var args = [_]core.JSValue{ core.JSValue.int32(2), core.JSValue.int32(5) };
    var frame = CallFrame{
        .ctx = ctx,
        .args = JSValueSlice.from(&args),
    };

    const status = trampoline(Impl.add)(&frame);
    try std.testing.expectEqual(Status.ok, status);
    try std.testing.expectEqual(Status.ok, frame.error_status);
    try std.testing.expectEqual(@as(i32, 7), frame.result.asInt32().?);
    try std.testing.expect(frame.args.slice().ptr == &args);
}

test "FFI trampoline supports explicit context signature and maps errors" {
    const Impl = struct {
        fn argc(ctx: *core.JSContext, this_value: core.JSValue, args: []const core.JSValue) !usize {
            _ = ctx;
            _ = this_value;
            return args.len;
        }

        fn fail(call: ZigCall) !core.JSValue {
            _ = call;
            return error.TypeError;
        }
    };

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var args = [_]core.JSValue{ core.JSValue.boolean(true), core.JSValue.undefinedValue() };
    var frame = CallFrame{
        .ctx = ctx,
        .this_value = core.JSValue.int32(9),
        .args = JSValueSlice.from(&args),
    };

    try std.testing.expectEqual(Status.ok, trampoline(Impl.argc)(&frame));
    try std.testing.expectEqual(@as(i32, 2), frame.result.asInt32().?);

    frame.result = core.JSValue.undefinedValue();
    try std.testing.expectEqual(Status.type_error, trampoline(Impl.fail)(&frame));
    try std.testing.expectEqual(Status.type_error, frame.error_status);
    try std.testing.expect(frame.result.isException());
}

test "FFI Plugin builds descriptor table with generated trampolines" {
    const Impl = struct {
        fn noop(call: ZigCall) void {
            _ = call;
        }
    };
    const TestPlugin = Plugin("test-plugin", .{
        binding("noop", Impl.noop),
    });

    const descriptor = TestPlugin.descriptor();
    try validatePlugin(descriptor);
    try std.testing.expectEqualStrings("test-plugin", descriptor.name.slice());
    try std.testing.expectEqual(@as(u32, 1), descriptor.binding_count);
    const bindings = descriptor.bindings.?;
    try std.testing.expectEqualStrings("noop", bindings[0].name.slice());
    try std.testing.expect(bindings[0].call != null);
}

test "FFI descriptor export validates generated plugin descriptor" {
    const Impl = struct {
        fn noop(call: ZigCall) void {
            _ = call;
        }
    };
    const TestPlugin = Plugin("exported-test-plugin", .{
        binding("noop", Impl.noop),
    });
    const descriptor = try descriptorFromExport(TestPlugin.descriptorExport);
    try std.testing.expect(descriptor == TestPlugin.descriptor());
    try std.testing.expectEqualStrings("exported-test-plugin", descriptor.name.slice());
}

test "FFI descriptor export rejects null descriptor" {
    const Export = struct {
        fn get() callconv(.c) ?*const PluginDescriptor {
            return null;
        }
    };
    try std.testing.expectError(error.NullDescriptor, descriptorFromExport(Export.get));
}

test "FFI LoadedPlugin reports missing dynamic library" {
    try std.testing.expectError(error.FileNotFound, LoadedPlugin.open("zig-cache/zjs-missing-plugin-do-not-create.so"));
}
