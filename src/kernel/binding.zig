const std = @import("std");
const core = @import("../core/root.zig");
const JSBytes = @import("bytes.zig").JSBytes;
const JSString = @import("string.zig").JSString;
const PropNameID = @import("prop_name.zig").PropNameID;

pub const BindingError = error{
    NotInstalled,
    TypeError,
};

const MethodRuntime = struct {
    runtime: *core.JSRuntime,
    class_id: core.ClassId,
    prototype: core.JSValueHandle,

    fn deinit(ptr: *anyopaque) void {
        const self: *MethodRuntime = @ptrCast(@alignCast(ptr));
        self.prototype.deinit();
        self.runtime.memory.destroy(MethodRuntime, self);
    }
};

pub fn method(comptime name: []const u8, comptime call: anytype) Method(@TypeOf(call)) {
    return .{
        .name = name,
        .call = call,
    };
}

pub fn Method(comptime Call: type) type {
    return struct {
        name: []const u8,
        call: Call,
    };
}

pub const Properties = struct {
    pub fn static(comptime entries: anytype) Static(@TypeOf(entries)) {
        return .{ .entries = entries };
    }

    pub fn Static(comptime Entries: type) type {
        return struct {
            pub const zjs_binding_static_properties = true;
            entries: Entries,
        };
    }
};

pub const TraceVisitor = struct {
    inner: *core.class.PayloadVisitor,

    pub inline fn value(self: *TraceVisitor, value_slot: *core.JSValue) void {
        self.inner.value(@ptrCast(value_slot));
    }

    pub inline fn object(self: *TraceVisitor, object_slot: *?*core.Object) void {
        self.inner.object(@ptrCast(object_slot));
    }
};

pub const Storage = union(enum) {
    inline_value,
    external_ptr: ExternalPtr,

    pub const inlineValue: Storage = .inline_value;

    pub fn externalPtr(options: ExternalPtr) Storage {
        return .{ .external_ptr = options };
    }

    pub const ExternalPtr = struct {
        owner: Owner = .js,
    };

    pub const Owner = enum {
        js,
        host,
    };
};

pub fn JSObject(comptime Payload: type, comptime spec: anytype) type {
    const SpecType = @TypeOf(spec);
    const storage_spec = comptime specStorage(SpecType, spec);
    if (storage_spec == .inline_value and @sizeOf(Payload) == 0) {
        @compileError("zjs.binding.JSObject inline_value payload must have non-zero size");
    }
    if (comptime payloadRequiresTrace(Payload) and !hasField(SpecType, "trace")) {
        @compileError("zjs.binding.JSObject payload contains GC-visible fields; declare .trace explicitly");
    }
    if (comptime payloadRequiresTrace(Payload) and storageNeedsPayloadDeinit(storage_spec) and !hasField(SpecType, "deinit")) {
        @compileError("zjs.binding.JSObject JS-owned payload contains GC-visible fields; declare .deinit explicitly");
    }

    const Arg = newArgType(Payload, storage_spec);

    return struct {
        pub const PayloadType = Payload;
        pub const storage = storage_spec;

        const Self = @This();

        pub const Binding = struct {
            runtime: *core.JSRuntime,
            class_id: core.ClassId,
            prototype: *core.Object,

            pub fn new(self: Binding, data: Arg) !core.JSValue {
                return Self.newWithBinding(self, data);
            }

            pub fn payload(self: Binding, value: core.JSValue) ?*Payload {
                return Self.payloadFromBinding(self, value);
            }
        };

        const RuntimeState = struct {
            runtime: *core.JSRuntime,
            static_property_names: []PropNameID,

            fn create(rt: *core.JSRuntime) !*RuntimeState {
                const state = try rt.memory.create(RuntimeState);
                errdefer rt.memory.destroy(RuntimeState, state);

                var names: []PropNameID = &.{};
                const count = comptime staticPropertyCount();
                if (count != 0) {
                    names = try rt.memory.alloc(PropNameID, count);
                }
                errdefer if (names.len != 0) rt.memory.free(PropNameID, names);

                var initialized: usize = 0;
                errdefer {
                    for (names[0..initialized]) |id| id.release(rt);
                }
                try internStaticPropertyNames(rt, names, &initialized);
                std.debug.assert(initialized == names.len);

                state.* = .{
                    .runtime = rt,
                    .static_property_names = names,
                };
                return state;
            }

            fn finalize(ptr: *anyopaque) void {
                const state: *RuntimeState = @ptrCast(@alignCast(ptr));
                const rt = state.runtime;
                for (state.static_property_names) |id| id.release(rt);
                if (state.static_property_names.len != 0) {
                    rt.memory.free(PropNameID, state.static_property_names);
                }
                rt.memory.destroy(RuntimeState, state);
            }
        };

        pub fn install(ctx: *core.JSContext) !void {
            const rt = ctx.runtimePtr();
            try installRuntime(rt);
            const class_id = installedClassId(rt) orelse return error.NotInstalled;
            if (ctx.classPrototypeObject(class_id) != null) return;

            const prototype = try core.Object.create(rt, core.class.ids.object, null);
            const prototype_value = prototype.value();
            errdefer prototype_value.free(rt);
            try installStaticProperties(ctx, prototype, class_id, installedRuntimeState(rt, class_id));
            try ctx.setClassPrototype(class_id, prototype);
            prototype_value.free(rt);
        }

        fn installRuntime(rt: *core.JSRuntime) !void {
            if (installedClassId(rt)) |_| return;
            const class_id = rt.newClassId(core.class.invalid_class_id);
            var runtime_state: ?*RuntimeState = null;
            if (comptime staticPropertyCount() != 0) {
                runtime_state = try RuntimeState.create(rt);
            }
            errdefer if (runtime_state) |state| RuntimeState.finalize(@ptrCast(state));
            try rt.classes.register(class_id, .{
                .class_name = className(),
                .binding_identity = classIdentity(),
                .binding_data = if (runtime_state) |state| @ptrCast(state) else null,
                .binding_data_finalizer = if (runtime_state != null) RuntimeState.finalize else null,
                .payload_kind = .none,
                .inline_payload_size = inlinePayloadSize(),
                .inline_payload_align = inlinePayloadAlign(),
                .payload_finalizer = if (needsPayloadFinalizer()) payloadFinalizer else null,
                .payload_mark = if (hasTraceHook()) payloadMark else null,
            });
        }

        pub fn binding(ctx: *core.JSContext) BindingError!Binding {
            const rt = ctx.runtimePtr();
            const class_id = installedClassId(rt) orelse return error.NotInstalled;
            const prototype = ctx.classPrototypeObject(class_id) orelse return error.NotInstalled;
            return .{
                .runtime = rt,
                .class_id = class_id,
                .prototype = prototype,
            };
        }

        pub fn new(ctx: *core.JSContext, data: Arg) !core.JSValue {
            const bound = try binding(ctx);
            return bound.new(data);
        }

        pub fn payload(ctx: *core.JSContext, value: core.JSValue) BindingError!?*Payload {
            const bound = try binding(ctx);
            return bound.payload(value);
        }

        fn installedClassId(rt: *core.JSRuntime) ?core.ClassId {
            return rt.classes.findByIdentity(classIdentity());
        }

        fn installedRuntimeState(rt: *core.JSRuntime, class_id: core.ClassId) ?*RuntimeState {
            if (comptime staticPropertyCount() == 0) return null;
            const record = rt.classes.record(class_id) orelse return null;
            const data = record.binding_data orelse return null;
            return @ptrCast(@alignCast(data));
        }

        fn classIdentity() []const u8 {
            return @typeName(Self);
        }

        fn newWithBinding(bound: Binding, data: Arg) !core.JSValue {
            const object = try core.Object.create(bound.runtime, bound.class_id, bound.prototype);
            errdefer core.Object.destroyFromHeader(bound.runtime, &object.header);
            const payload_ptr = try installPayload(bound.runtime, object, data);
            _ = payload_ptr;
            return object.value();
        }

        fn payloadFromBinding(bound: Binding, value: core.JSValue) ?*Payload {
            return payloadFromClassAndPrototype(bound.class_id, bound.prototype, value);
        }

        fn payloadFromClassAndPrototype(class_id: core.ClassId, prototype: *core.Object, value: core.JSValue) ?*Payload {
            const object = objectFromValue(value) orelse return null;
            if (object.class_id != class_id) return null;
            if (object.getPrototype() != prototype) return null;
            const raw = object.externalClassPayload() orelse return null;
            return @ptrCast(@alignCast(raw));
        }

        fn installPayload(rt: *core.JSRuntime, object: *core.Object, data: Arg) !*Payload {
            switch (storage_spec) {
                .inline_value => {
                    const raw = object.externalClassPayload() orelse return error.TypeError;
                    const payload_ptr: *Payload = @ptrCast(@alignCast(raw));
                    payload_ptr.* = data;
                    return payload_ptr;
                },
                .external_ptr => |options| switch (options.owner) {
                    .js => {
                        const payload_ptr = try rt.memory.create(Payload);
                        payload_ptr.* = data;
                        object.installExternalClassPayload(@ptrCast(payload_ptr));
                        return payload_ptr;
                    },
                    .host => {
                        object.installExternalClassPayload(@ptrCast(data));
                        return data;
                    },
                },
            }
        }

        fn payloadFinalizer(runtime: *anyopaque, object: *anyopaque, class_payload: *core.class.Payload) void {
            _ = object;
            const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
            switch (storage_spec) {
                .inline_value => {
                    const payload_ptr = externalPayload(class_payload) orelse return;
                    callDeinit(payload_ptr);
                    class_payload.* = .none;
                },
                .external_ptr => |options| switch (options.owner) {
                    .js => {
                        const payload_ptr = externalPayload(class_payload) orelse return;
                        callDeinit(payload_ptr);
                        rt.memory.destroy(Payload, payload_ptr);
                        class_payload.* = .none;
                    },
                    .host => {},
                },
            }
        }

        fn payloadMark(runtime: *anyopaque, object: *anyopaque, class_payload: *core.class.Payload, visitor: *core.class.PayloadVisitor) void {
            _ = runtime;
            _ = object;
            if (comptime hasTraceHook()) {
                const payload_ptr = externalPayload(class_payload) orelse return;
                var typed_visitor = TraceVisitor{ .inner = visitor };
                spec.trace(payload_ptr, &typed_visitor);
            } else {
                unreachable;
            }
        }

        fn installStaticProperties(ctx: *core.JSContext, prototype: *core.Object, class_id: core.ClassId, runtime_state: ?*RuntimeState) !void {
            if (comptime !hasField(SpecType, "properties")) return;
            const state = runtime_state orelse return error.NotInstalled;
            const properties = spec.properties;
            if (comptime isStaticProperties(@TypeOf(properties))) {
                try installStaticPropertyEntries(ctx, prototype, class_id, state, properties.entries);
                return;
            }
            try installStaticPropertyEntries(ctx, prototype, class_id, state, properties);
        }

        fn installStaticPropertyEntries(ctx: *core.JSContext, prototype: *core.Object, class_id: core.ClassId, runtime_state: *RuntimeState, comptime properties: anytype) !void {
            const PropsType = @TypeOf(properties);
            switch (@typeInfo(PropsType)) {
                .@"struct" => |info| {
                    if (!info.is_tuple) @compileError("zjs.binding.JSObject properties must be zjs.binding.Properties.static(.{ zjs.binding.method(\"read\", read) })");
                    inline for (properties, 0..) |entry, index| {
                        try installStaticProperty(ctx, prototype, class_id, runtime_state.static_property_names[index], entry);
                    }
                },
                else => @compileError("zjs.binding.JSObject properties must be zjs.binding.Properties.static(.{ zjs.binding.method(\"read\", read) })"),
            }
        }

        fn installStaticProperty(ctx: *core.JSContext, prototype: *core.Object, class_id: core.ClassId, key: PropNameID, comptime entry: anytype) !void {
            const EntryType = @TypeOf(entry);
            if (comptime !hasField(EntryType, "name") or !hasField(EntryType, "call")) {
                @compileError("zjs.binding.JSObject property entries must use zjs.binding.method(name, fn)");
            }
            const Stub = MethodStub(entry);
            const function_value = try createMethodFunction(ctx, class_id, prototype, entry.name, callbackLength(entry.call), Stub.call);
            defer function_value.free(ctx.runtimePtr());

            try key.defineDataProperty(ctx.runtimePtr(), prototype, core.Descriptor.data(function_value, true, false, true));
        }

        fn staticPropertyCount() comptime_int {
            if (comptime !hasField(SpecType, "properties")) return 0;
            const properties = spec.properties;
            if (comptime isStaticProperties(@TypeOf(properties))) {
                return staticPropertyEntryCount(properties.entries);
            }
            return staticPropertyEntryCount(properties);
        }

        fn staticPropertyEntryCount(comptime properties: anytype) comptime_int {
            const PropsType = @TypeOf(properties);
            switch (@typeInfo(PropsType)) {
                .@"struct" => |info| {
                    if (!info.is_tuple) @compileError("zjs.binding.JSObject properties must be zjs.binding.Properties.static(.{ zjs.binding.method(\"read\", read) })");
                    return info.fields.len;
                },
                else => @compileError("zjs.binding.JSObject properties must be zjs.binding.Properties.static(.{ zjs.binding.method(\"read\", read) })"),
            }
        }

        fn internStaticPropertyNames(rt: *core.JSRuntime, names: []PropNameID, initialized: *usize) !void {
            if (comptime !hasField(SpecType, "properties")) return;
            const properties = spec.properties;
            if (comptime isStaticProperties(@TypeOf(properties))) {
                try internStaticPropertyEntryNames(rt, names, initialized, properties.entries);
                return;
            }
            try internStaticPropertyEntryNames(rt, names, initialized, properties);
        }

        fn internStaticPropertyEntryNames(rt: *core.JSRuntime, names: []PropNameID, initialized: *usize, comptime properties: anytype) !void {
            const PropsType = @TypeOf(properties);
            switch (@typeInfo(PropsType)) {
                .@"struct" => |info| {
                    if (!info.is_tuple) @compileError("zjs.binding.JSObject properties must be zjs.binding.Properties.static(.{ zjs.binding.method(\"read\", read) })");
                    inline for (properties) |entry| {
                        const EntryType = @TypeOf(entry);
                        if (comptime !hasField(EntryType, "name") or !hasField(EntryType, "call")) {
                            @compileError("zjs.binding.JSObject property entries must use zjs.binding.method(name, fn)");
                        }
                        names[initialized.*] = try PropNameID.internStatic(rt, entry.name);
                        initialized.* += 1;
                    }
                },
                else => @compileError("zjs.binding.JSObject properties must be zjs.binding.Properties.static(.{ zjs.binding.method(\"read\", read) })"),
            }
        }

        fn createMethodFunction(
            ctx: *core.JSContext,
            class_id: core.ClassId,
            prototype: *core.Object,
            name: []const u8,
            length: i32,
            call: core.host_function.ExternalCallFn,
        ) !core.JSValue {
            const rt = ctx.runtimePtr();
            var prototype_handle = try rt.createPersistentValue(prototype.value());
            errdefer prototype_handle.deinit();

            const runtime = try rt.memory.create(MethodRuntime);
            var runtime_owned = true;
            errdefer if (runtime_owned) {
                runtime.prototype.deinit();
                rt.memory.destroy(MethodRuntime, runtime);
            };
            runtime.* = .{
                .runtime = rt,
                .class_id = class_id,
                .prototype = prototype_handle,
            };
            prototype_handle = .{};

            const function_object = try core.Object.create(rt, core.class.ids.c_function, null);
            errdefer function_object.value().free(rt);
            try defineFunctionMetadata(rt, function_object, name, length);
            try function_object.setFunctionRealmGlobalPtr(rt, try ctx.globalObject());

            const external_id = try rt.registerExternalHostFunction(.{
                .ptr = @ptrCast(runtime),
                .call = call,
                .finalizer = MethodRuntime.deinit,
            });
            runtime_owned = false;

            function_object.hostFunctionKindSlot().* = core.host_function.ids.external_host;
            function_object.externalHostFunctionIdSlot().* = external_id;
            return function_object.value();
        }

        fn defineFunctionMetadata(rt: *core.JSRuntime, function_object: *core.Object, name: []const u8, length: i32) !void {
            const name_value = (try core.string.String.createAscii(rt, name)).value();
            defer name_value.free(rt);
            try function_object.defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.data(name_value, false, false, true));
            try function_object.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(length), false, false, true));
        }

        fn MethodStub(comptime entry: anytype) type {
            const Call = @TypeOf(entry.call);
            const info = @typeInfo(Call).@"fn";
            comptime validateMethodSignature(info);

            return struct {
                fn call(ptr: *anyopaque, host_call: core.host_function.ExternalCall) anyerror!core.JSValue {
                    const runtime: *MethodRuntime = @ptrCast(@alignCast(ptr));
                    const prototype = objectFromValue(runtime.prototype.get()) orelse return error.TypeError;
                    const self_payload = payloadFromClassAndPrototype(runtime.class_id, prototype, host_call.this_value) orelse return error.TypeError;
                    return invoke(entry.call, self_payload, host_call);
                }
            };
        }

        fn invoke(comptime call: anytype, self_payload: *Payload, host_call: core.host_function.ExternalCall) anyerror!core.JSValue {
            const Call = @TypeOf(call);
            const info = @typeInfo(Call).@"fn";
            if (comptime methodHasUtf8Param(info)) {
                const ctx = callContext(host_call);
                var stack_allocator = std.heap.stackFallback(4096, ctx.runtimePtr().memory.allocator);
                const allocator = stack_allocator.get();
                return try invokeWithAllocator(call, info, self_payload, host_call, allocator);
            }
            return try invokeWithAllocator(call, info, self_payload, host_call, null);
        }

        fn invokeWithAllocator(
            comptime call: anytype,
            comptime info: std.builtin.Type.Fn,
            self_payload: *Payload,
            host_call: core.host_function.ExternalCall,
            utf8_allocator: ?std.mem.Allocator,
        ) anyerror!core.JSValue {
            const Call = @TypeOf(call);
            const Args = std.meta.ArgsTuple(Call);
            var args_tuple: Args = undefined;
            var utf8_initialized = [_]bool{false} ** info.params.len;
            defer {
                inline for (info.params, 0..) |param, index| {
                    const Param = param.type orelse @compileError("zjs.binding method parameters must have concrete types");
                    if (Param == JSString.Utf8 and utf8_initialized[index]) {
                        args_tuple[index].deinit();
                    }
                }
            }

            var js_index: usize = 0;
            inline for (info.params, 0..) |param, index| {
                const Param = param.type orelse @compileError("zjs.binding method parameters must have concrete types");
                args_tuple[index] = try callbackArg(Param, self_payload, host_call, &js_index, utf8_allocator);
                if (Param == JSString.Utf8) utf8_initialized[index] = true;
            }
            return try resultToValue(@call(.auto, call, args_tuple));
        }

        fn validateMethodSignature(comptime info: std.builtin.Type.Fn) void {
            if (info.params.len == 0) @compileError("zjs.binding method must take self as its first parameter");
            const SelfParam = info.params[0].type orelse @compileError("zjs.binding method self parameter must have a concrete type");
            if (!isSelfParam(SelfParam)) @compileError("zjs.binding method first parameter must be *T or *const T");
            inline for (info.params[1..]) |param| {
                const Param = param.type orelse @compileError("zjs.binding method parameters must have concrete types");
                _ = callbackParamKind(Param);
            }
        }

        fn externalPayload(class_payload: *core.class.Payload) ?*Payload {
            return switch (class_payload.*) {
                .external => |raw| @ptrCast(@alignCast(raw)),
                .none => null,
            };
        }

        fn callDeinit(data: *Payload) void {
            if (comptime hasField(SpecType, "deinit")) {
                spec.deinit(data);
            }
        }

        fn className() []const u8 {
            if (comptime hasField(SpecType, "name")) return spec.name;
            return @typeName(Payload);
        }

        fn needsPayloadFinalizer() bool {
            return switch (storage_spec) {
                .inline_value => hasField(SpecType, "deinit"),
                .external_ptr => |options| options.owner == .js,
            };
        }

        fn hasTraceHook() bool {
            return comptime hasField(SpecType, "trace");
        }

        fn inlinePayloadSize() u32 {
            return switch (storage_spec) {
                .inline_value => @intCast(@sizeOf(Payload)),
                .external_ptr => 0,
            };
        }

        fn inlinePayloadAlign() u16 {
            return switch (storage_spec) {
                .inline_value => @intCast(@alignOf(Payload)),
                .external_ptr => 1,
            };
        }

        const CallbackParamKind = enum {
            self_mut,
            self_const,
            context,
            raw_call,
            rest_values,
            value,
            boolean,
            integer,
            float,
            string,
            string_utf8,
            bytes,
            bytes_ro,
            bytes_rw,
        };

        fn callbackLength(comptime call: anytype) i32 {
            const info = @typeInfo(@TypeOf(call)).@"fn";
            comptime validateMethodSignature(info);
            var count: i32 = 0;
            inline for (info.params[1..]) |param| {
                const Param = param.type orelse @compileError("zjs.binding method parameters must have concrete types");
                switch (callbackParamKind(Param)) {
                    .value, .boolean, .integer, .float, .string, .string_utf8, .bytes, .bytes_ro, .bytes_rw => count += 1,
                    .context, .raw_call, .rest_values => {},
                    .self_mut, .self_const => {},
                }
            }
            return count;
        }

        fn callbackArg(
            comptime Param: type,
            self_payload: *Payload,
            host_call: core.host_function.ExternalCall,
            js_index: *usize,
            utf8_allocator: ?std.mem.Allocator,
        ) anyerror!Param {
            switch (comptime callbackParamKind(Param)) {
                .self_mut => return self_payload,
                .self_const => return self_payload,
                .context => return @ptrCast(@alignCast(host_call.ctx)),
                .raw_call => return host_call,
                .rest_values => {
                    const rest = host_call.args[js_index.*..];
                    js_index.* = host_call.args.len;
                    return rest;
                },
                .value => {
                    const value = try nextValue(host_call.args, js_index);
                    return value;
                },
                .boolean => {
                    const value = try nextValue(host_call.args, js_index);
                    return value.asBool() orelse error.TypeError;
                },
                .integer => {
                    const value = try nextValue(host_call.args, js_index);
                    const raw = value.asInt32() orelse return error.TypeError;
                    return std.math.cast(Param, raw) orelse error.RangeError;
                },
                .float => {
                    const value = try nextValue(host_call.args, js_index);
                    if (value.asFloat64()) |float| return @floatCast(float);
                    if (value.asInt32()) |int| return @floatFromInt(int);
                    return error.TypeError;
                },
                .string => {
                    const value = try nextValue(host_call.args, js_index);
                    return JSString.fromValue(value) orelse error.TypeError;
                },
                .string_utf8 => {
                    const allocator = utf8_allocator orelse unreachable;
                    const value = try nextValue(host_call.args, js_index);
                    return JSString.Utf8.fromValue(allocator, value);
                },
                .bytes => {
                    const value = try nextValue(host_call.args, js_index);
                    return JSBytes.fromValue(value);
                },
                .bytes_ro => {
                    const value = try nextValue(host_call.args, js_index);
                    const bytes = try JSBytes.fromValue(value);
                    return bytes.slice();
                },
                .bytes_rw => {
                    const value = try nextValue(host_call.args, js_index);
                    const bytes = try JSBytes.fromValue(value);
                    if (bytes.isShared()) return error.TypeError;
                    return bytes.sliceMut();
                },
            }
        }

        fn nextValue(args: []const core.JSValue, index: *usize) !core.JSValue {
            if (index.* >= args.len) return error.TypeError;
            const value = args[index.*];
            index.* += 1;
            return value;
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
                else => @compileError("unsupported zjs.binding method return type: " ++ @typeName(Result)),
            };
        }

        fn integerToValue(value: anytype) core.JSValue {
            if (std.math.cast(i32, value)) |int| return core.JSValue.int32(int);
            return core.JSValue.float64(@floatFromInt(value));
        }

        fn isSelfParam(comptime Param: type) bool {
            return switch (@typeInfo(Param)) {
                .pointer => |ptr| ptr.size == .one and ptr.child == Payload,
                else => false,
            };
        }

        fn callbackParamKind(comptime Param: type) CallbackParamKind {
            if (Param == *core.JSContext) return .context;
            if (Param == core.host_function.ExternalCall) return .raw_call;
            if (Param == core.JSValue) return .value;
            if (Param == bool) return .boolean;
            if (Param == JSString) return .string;
            if (Param == JSString.Utf8) return .string_utf8;
            if (Param == JSBytes) return .bytes;
            if (Param == []const u8) return .bytes_ro;
            if (Param == []u8) return .bytes_rw;
            switch (@typeInfo(Param)) {
                .pointer => |ptr| {
                    if (ptr.size == .one and ptr.child == Payload) {
                        return if (ptr.is_const) .self_const else .self_mut;
                    }
                    if (ptr.size == .slice and ptr.is_const and ptr.child == core.JSValue) {
                        return .rest_values;
                    }
                },
                .int, .comptime_int => return .integer,
                .float, .comptime_float => return .float,
                else => {},
            }
            @compileError("unsupported zjs.binding method parameter type: " ++ @typeName(Param));
        }

        fn methodHasUtf8Param(comptime info: std.builtin.Type.Fn) bool {
            inline for (info.params) |param| {
                const Param = param.type orelse @compileError("zjs.binding method parameters must have concrete types");
                if (Param == JSString.Utf8) return true;
            }
            return false;
        }

        fn callContext(host_call: core.host_function.ExternalCall) *core.JSContext {
            return @ptrCast(@alignCast(host_call.ctx));
        }
    };
}

test {
    _ = Storage;
    _ = Properties;
    _ = JSObject;
}

fn specStorage(comptime SpecType: type, comptime spec: SpecType) Storage {
    if (comptime hasField(SpecType, "storage")) {
        const storage: Storage = spec.storage;
        return storage;
    }
    @compileError("zjs.binding.JSObject spec must declare .storage explicitly");
}

fn newArgType(comptime Payload: type, comptime storage: Storage) type {
    return switch (storage) {
        .inline_value => Payload,
        .external_ptr => |options| switch (options.owner) {
            .js => Payload,
            .host => *Payload,
        },
    };
}

fn hasField(comptime T: type, comptime field_name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| {
            if (std.mem.eql(u8, field.name, field_name)) break true;
        } else false,
        else => false,
    };
}

fn isStaticProperties(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "zjs_binding_static_properties"),
        else => false,
    };
}

fn payloadRequiresTrace(comptime Payload: type) bool {
    return typeRequiresTrace(Payload, 0);
}

fn storageNeedsPayloadDeinit(comptime storage: Storage) bool {
    return switch (storage) {
        .inline_value => true,
        .external_ptr => |options| options.owner == .js,
    };
}

fn typeRequiresTrace(comptime T: type, comptime depth: u8) bool {
    if (typeIsGcVisible(T)) return true;
    if (depth >= 6) return false;
    return switch (@typeInfo(T)) {
        .optional => |info| typeRequiresTrace(info.child, depth + 1),
        .array => |info| typeRequiresTrace(info.child, depth + 1),
        .pointer => |info| switch (info.size) {
            .one => typeIsGcVisible(info.child),
            .slice => typeIsGcVisible(info.child),
            else => false,
        },
        .@"struct" => |info| inline for (info.fields) |field| {
            if (typeRequiresTrace(field.type, depth + 1)) break true;
        } else false,
        else => false,
    };
}

fn typeIsGcVisible(comptime T: type) bool {
    return T == core.JSValue or
        T == core.Object or
        T == core.JSValueHandle or
        T == core.WeakPersistentValue;
}

fn objectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    if (header.kind != .object) return null;
    return @fieldParentPtr("header", header);
}

test "JSObject detects payloads that require explicit tracing" {
    const HoldsValue = struct {
        value: core.JSValue,
    };
    const HoldsOptionalObject = struct {
        object: ?*core.Object,
    };
    const HoldsPersistent = struct {
        handle: core.JSValueHandle,
    };
    const HoldsWeak = struct {
        weak: ?core.WeakPersistentValue,
    };
    const HoldsHandleSlice = struct {
        handles: []core.JSValueHandle,
    };
    const Plain = struct {
        value: usize,
        ptr: *usize,
    };

    try std.testing.expect(payloadRequiresTrace(HoldsValue));
    try std.testing.expect(payloadRequiresTrace(HoldsOptionalObject));
    try std.testing.expect(payloadRequiresTrace(HoldsPersistent));
    try std.testing.expect(payloadRequiresTrace(HoldsWeak));
    try std.testing.expect(payloadRequiresTrace(HoldsHandleSlice));
    try std.testing.expect(!payloadRequiresTrace(Plain));
}

test "JSObject detects JS-owned payloads that require explicit deinit" {
    try std.testing.expect(storageNeedsPayloadDeinit(.inline_value));
    try std.testing.expect(storageNeedsPayloadDeinit(Storage.externalPtr(.{ .owner = .js })));
    try std.testing.expect(!storageNeedsPayloadDeinit(Storage.externalPtr(.{ .owner = .host })));
}

test "JSObject payload explicit deinit releases persistent value roots" {
    const Payload = struct {
        handle: core.JSValueHandle,
        deinit_count: *usize,
    };
    const Hooks = struct {
        fn trace(payload: *Payload, visitor: *TraceVisitor) void {
            _ = payload;
            _ = visitor;
        }

        fn deinit(payload: *Payload) void {
            payload.handle.deinit();
            payload.deinit_count.* += 1;
        }
    };
    const ObjectType = JSObject(Payload, .{
        .name = "KernelBindingPersistentHandlePayload",
        .storage = Storage{ .external_ptr = .{ .owner = .js } },
        .trace = Hooks.trace,
        .deinit = Hooks.deinit,
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    try ObjectType.install(ctx);
    const binding = try ObjectType.binding(ctx);

    const held = try core.Object.create(rt, core.class.ids.object, null);
    const held_value = held.value();
    var handle = try rt.createPersistentValue(held_value);
    defer handle.deinit();
    held_value.free(rt);
    try std.testing.expectEqual(@as(usize, 1), rt.persistentRootCountForTest());

    var deinit_count: usize = 0;
    const value = try binding.new(.{
        .handle = handle,
        .deinit_count = &deinit_count,
    });
    handle = .{};

    value.free(rt);
    rt.drainDeferredClassPayloadFinalizers();
    try std.testing.expectEqual(@as(usize, 1), deinit_count);
    try std.testing.expectEqual(@as(usize, 0), rt.persistentRootCountForTest());
}

test "JSObject installs class and owns js external payload" {
    const Payload = struct {
        value: u32,
        deinit_count: *usize,
    };
    const Hooks = struct {
        fn deinit(payload: *Payload) void {
            payload.deinit_count.* += 1;
        }
    };
    const ObjectType = JSObject(Payload, .{
        .name = "KernelBindingOwnedPayload",
        .storage = Storage{ .external_ptr = .{ .owner = .js } },
        .deinit = Hooks.deinit,
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    try ObjectType.install(ctx);
    const binding = try ObjectType.binding(ctx);
    try std.testing.expectEqual(binding.class_id, rt.classes.findByName("KernelBindingOwnedPayload").?);

    var deinit_count: usize = 0;
    const value = try binding.new(.{
        .value = 42,
        .deinit_count = &deinit_count,
    });
    const payload = binding.payload(value).?;
    try std.testing.expectEqual(@as(u32, 42), payload.value);

    value.free(rt);
    rt.drainDeferredClassPayloadFinalizers();
    try std.testing.expectEqual(@as(usize, 1), deinit_count);
}

test "JSObject can wrap host-owned external payload" {
    const Payload = struct {
        value: u32,
    };
    const ObjectType = JSObject(Payload, .{
        .name = "KernelBindingHostPayload",
        .storage = Storage{ .external_ptr = .{ .owner = .host } },
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    try ObjectType.install(ctx);
    const binding = try ObjectType.binding(ctx);

    var payload = Payload{ .value = 7 };
    const value = try binding.new(&payload);
    defer value.free(rt);

    const stored = binding.payload(value).?;
    try std.testing.expect(stored == &payload);
    stored.value = 11;
    try std.testing.expectEqual(@as(u32, 11), payload.value);
}

test "JSObject class identity is independent from class name" {
    const PayloadA = struct {
        value: i32,
    };
    const PayloadB = struct {
        value: i32,
    };
    const ObjectA = JSObject(PayloadA, .{
        .name = "KernelBindingDuplicateName",
        .storage = Storage.inlineValue,
    });
    const ObjectB = JSObject(PayloadB, .{
        .name = "KernelBindingDuplicateName",
        .storage = Storage.inlineValue,
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    try ObjectA.install(ctx);
    try ObjectB.install(ctx);
    const binding_a = try ObjectA.binding(ctx);
    const binding_b = try ObjectB.binding(ctx);
    try std.testing.expect(binding_a.class_id != binding_b.class_id);

    const value_a = try binding_a.new(.{ .value = 1 });
    defer value_a.free(rt);
    const value_b = try binding_b.new(.{ .value = 2 });
    defer value_b.free(rt);

    try std.testing.expectEqual(@as(i32, 1), binding_a.payload(value_a).?.value);
    try std.testing.expectEqual(@as(i32, 2), binding_b.payload(value_b).?.value);
    try std.testing.expect(binding_a.payload(value_b) == null);
    try std.testing.expect(binding_b.payload(value_a) == null);
}

test "JSObject binding is realm-local even when runtime class is installed" {
    const Payload = struct {
        value: i32,
    };
    const ObjectType = JSObject(Payload, .{
        .name = "KernelBindingRealmLocalPayload",
        .storage = Storage.inlineValue,
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx_a = try core.JSContext.create(rt);
    defer ctx_a.destroy();
    const ctx_b = try core.JSContext.create(rt);
    defer ctx_b.destroy();

    try ObjectType.install(ctx_a);
    const binding_a = try ObjectType.binding(ctx_a);
    try std.testing.expectError(error.NotInstalled, ObjectType.binding(ctx_b));
    try std.testing.expectError(error.NotInstalled, ObjectType.new(ctx_b, .{ .value = 2 }));

    try ObjectType.install(ctx_b);
    const binding_b = try ObjectType.binding(ctx_b);
    try std.testing.expectEqual(binding_a.class_id, binding_b.class_id);
    try std.testing.expect(binding_a.prototype != binding_b.prototype);

    const value_a = try binding_a.new(.{ .value = 1 });
    defer value_a.free(rt);
    const value_b = try binding_b.new(.{ .value = 2 });
    defer value_b.free(rt);

    try std.testing.expectEqual(@as(i32, 1), binding_a.payload(value_a).?.value);
    try std.testing.expectEqual(@as(i32, 2), binding_b.payload(value_b).?.value);
    try std.testing.expect(binding_a.payload(value_b) == null);
    try std.testing.expect(binding_b.payload(value_a) == null);
    try std.testing.expect((try ObjectType.payload(ctx_a, value_b)) == null);
    try std.testing.expect((try ObjectType.payload(ctx_b, value_a)) == null);
}

test "JSObject prototype methods enforce realm-local binding" {
    const Payload = struct {
        value: i32,

        fn touch(self: *@This()) i32 {
            self.value += 1;
            return self.value;
        }
    };
    const ObjectType = JSObject(Payload, .{
        .name = "KernelBindingRealmLocalMethodPayload",
        .storage = Storage.inlineValue,
        .properties = Properties.static(.{
            method("touch", Payload.touch),
        }),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx_a = try core.JSContext.create(rt);
    defer ctx_a.destroy();
    const ctx_b = try core.JSContext.create(rt);
    defer ctx_b.destroy();

    try ObjectType.install(ctx_a);
    try ObjectType.install(ctx_b);
    const binding_a = try ObjectType.binding(ctx_a);
    const binding_b = try ObjectType.binding(ctx_b);

    const value_a = try binding_a.new(.{ .value = 10 });
    defer value_a.free(rt);
    const value_b = try binding_b.new(.{ .value = 20 });
    defer value_b.free(rt);

    const touch_key = try rt.internAtom("touch");
    defer rt.atoms.free(touch_key);
    const touch_a = objectFromValue(value_a).?.getProperty(touch_key);
    defer touch_a.free(rt);

    try std.testing.expectError(error.JSException, ctx_a.callFunction(touch_a, &.{}, .{ .this_value = value_b }));
    ctx_a.clearException();
    try std.testing.expectEqual(@as(i32, 20), binding_b.payload(value_b).?.value);

    const result = try ctx_a.callFunction(touch_a, &.{}, .{ .this_value = value_a });
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 11), result.asInt32().?);
    try std.testing.expectEqual(@as(i32, 11), binding_a.payload(value_a).?.value);
}

test "JSObject method prototype roots release with external host records" {
    const Payload = struct {
        marker: u8,

        fn touch(self: *@This()) void {
            _ = self;
        }
    };
    const ObjectType = JSObject(Payload, .{
        .name = "KernelBindingMethodPrototypeRoot",
        .storage = Storage.inlineValue,
        .properties = Properties.static(.{
            method("touch", Payload.touch),
        }),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    try std.testing.expectEqual(@as(usize, 0), rt.persistentRootCountForTest());
    try ObjectType.install(ctx);
    try std.testing.expectEqual(@as(usize, 1), rt.persistentRootCountForTest());

    rt.clearExternalHostFunctions();
    rt.drainDeferredNativeCleanups();
    try std.testing.expectEqual(@as(usize, 0), rt.persistentRootCountForTest());
}

test "JSObject install does not export constructors to the global object" {
    const Payload = struct {
        value: i32,
    };
    const ObjectType = JSObject(Payload, .{
        .name = "KernelBindingNoGlobalConstructor",
        .storage = Storage.inlineValue,
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    try ObjectType.install(ctx);
    const global = try ctx.globalObject();
    const name_atom = try rt.internAtom("KernelBindingNoGlobalConstructor");
    defer rt.atoms.free(name_atom);
    try std.testing.expect(!global.hasOwnProperty(name_atom));

    const binding = try ObjectType.binding(ctx);
    const value = try binding.new(.{ .value = 1 });
    defer value.free(rt);
    try std.testing.expectEqual(@as(i32, 1), binding.payload(value).?.value);
}

test "JSObject inline_value stores payload in object allocation and finalizes synchronously" {
    const Payload = struct {
        value: u32,
        deinit_count: *usize,
    };
    const Hooks = struct {
        fn deinit(payload: *Payload) void {
            payload.deinit_count.* += 1;
        }
    };
    const ObjectType = JSObject(Payload, .{
        .name = "KernelBindingInlinePayload",
        .storage = .inline_value,
        .deinit = Hooks.deinit,
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    try ObjectType.install(ctx);
    const binding = try ObjectType.binding(ctx);

    var deinit_count: usize = 0;
    const value = try binding.new(.{
        .value = 42,
        .deinit_count = &deinit_count,
    });
    const object = objectFromValue(value).?;
    const payload = binding.payload(value).?;
    try std.testing.expectEqual(@as(u32, 42), payload.value);

    const object_start = @intFromPtr(object);
    const object_end = object_start + object.allocationSize(rt);
    const payload_start = @intFromPtr(payload);
    try std.testing.expect(payload_start >= object_start + @sizeOf(core.Object));
    try std.testing.expect(payload_start + @sizeOf(Payload) <= object_end);

    value.free(rt);
    try std.testing.expectEqual(@as(usize, 1), deinit_count);
}

test "JSObject inline_value trace hook marks typed payload slots" {
    const Payload = struct {
        value_slot: core.JSValue,
    };
    const Hooks = struct {
        fn trace(payload: *Payload, visitor: *TraceVisitor) void {
            visitor.value(&payload.value_slot);
        }

        fn deinit(payload: *Payload) void {
            payload.value_slot = core.JSValue.undefinedValue();
        }
    };
    const ObjectType = JSObject(Payload, .{
        .name = "KernelBindingInlineTracePayload",
        .storage = .inline_value,
        .trace = Hooks.trace,
        .deinit = Hooks.deinit,
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    try ObjectType.install(ctx);
    const binding = try ObjectType.binding(ctx);
    const value = try binding.new(.{ .value_slot = core.JSValue.int32(7) });
    defer value.free(rt);
    const object = objectFromValue(value).?;
    const payload = binding.payload(value).?;

    const Visitor = struct {
        expected: *core.JSValue,
        visits: usize = 0,

        pub fn visitValue(self: *@This(), value_ptr: *core.JSValue) void {
            if (value_ptr == self.expected) self.visits += 1;
        }
    };
    var visitor = Visitor{ .expected = &payload.value_slot };
    object.traceChildEdgesNoFail(rt, &visitor);
    try std.testing.expectEqual(@as(usize, 1), visitor.visits);
}

test "JSObject trace hook marks typed payload slots" {
    const Payload = struct {
        value_slot: core.JSValue,
        object_slot: ?*core.Object = null,
    };
    const Hooks = struct {
        fn trace(payload: *Payload, visitor: *TraceVisitor) void {
            visitor.value(&payload.value_slot);
            visitor.object(&payload.object_slot);
        }
    };
    const ObjectType = JSObject(Payload, .{
        .name = "KernelBindingTracePayload",
        .storage = Storage{ .external_ptr = .{ .owner = .host } },
        .trace = Hooks.trace,
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    try ObjectType.install(ctx);
    const binding = try ObjectType.binding(ctx);

    var payload = Payload{ .value_slot = core.JSValue.int32(123) };
    var class_payload = core.class.Payload{ .external = @ptrCast(&payload) };

    const State = struct {
        value_slot: *core.JSValue,
        object_slot: *?*core.Object,
        value_visits: usize = 0,
        object_visits: usize = 0,

        fn visitValue(context: *anyopaque, value_ptr: *anyopaque) void {
            const state: *@This() = @ptrCast(@alignCast(context));
            const visited: *core.JSValue = @ptrCast(@alignCast(value_ptr));
            if (visited == state.value_slot) state.value_visits += 1;
        }

        fn visitObject(context: *anyopaque, object_ptr: *anyopaque) void {
            const state: *@This() = @ptrCast(@alignCast(context));
            const visited: *?*core.Object = @ptrCast(@alignCast(object_ptr));
            if (visited == state.object_slot) state.object_visits += 1;
        }
    };
    var state = State{
        .value_slot = &payload.value_slot,
        .object_slot = &payload.object_slot,
    };
    var visitor = core.class.PayloadVisitor{
        .context = @ptrCast(&state),
        .visit_value = State.visitValue,
        .visit_object = State.visitObject,
    };

    try std.testing.expect(rt.classes.markPayload(binding.class_id, @ptrCast(rt), @ptrCast(ctx), &class_payload, &visitor));
    try std.testing.expectEqual(@as(usize, 1), state.value_visits);
    try std.testing.expectEqual(@as(usize, 1), state.object_visits);
}

test "JSObject installs prototype method with typed self and arguments" {
    const Payload = struct {
        total: i32,

        fn add(self: *@This(), amount: i32, enabled: bool) !i32 {
            if (!enabled) return error.TypeError;
            self.total += amount;
            return self.total;
        }
    };
    const ObjectType = JSObject(Payload, .{
        .name = "KernelBindingMethodPayload",
        .storage = Storage.externalPtr(.{ .owner = .js }),
        .properties = Properties.static(.{
            method("add", Payload.add),
        }),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    try std.testing.expectError(error.NotInstalled, ObjectType.binding(ctx));
    try std.testing.expectError(error.NotInstalled, ObjectType.new(ctx, .{ .total = 10 }));
    try ObjectType.install(ctx);
    const binding = try ObjectType.binding(ctx);
    const value = try binding.new(.{ .total = 10 });
    defer value.free(rt);

    const object = objectFromValue(value).?;
    const add_key = try rt.internAtom("add");
    defer rt.atoms.free(add_key);
    const add_value = object.getProperty(add_key);
    defer add_value.free(rt);

    const add_object = objectFromValue(add_value).?;
    const length_value = add_object.getProperty(core.atom.ids.length);
    defer length_value.free(rt);
    try std.testing.expectEqual(@as(i32, 2), length_value.asInt32().?);

    const result = try ctx.callFunction(add_value, &.{
        core.JSValue.int32(5),
        core.JSValue.boolean(true),
    }, .{ .this_value = value });
    defer result.free(rt);

    try std.testing.expectEqual(@as(i32, 15), result.asInt32().?);
    try std.testing.expectEqual(@as(i32, 15), binding.payload(value).?.total);
}

test "JSObject keeps static property names in runtime binding state" {
    const method_name = "runtimeCachedMethodName";
    const Payload = struct {
        fn runtimeCachedMethodName(self: *@This()) void {
            _ = self;
        }
    };
    const ObjectType = JSObject(Payload, .{
        .name = "KernelBindingCachedPropertyNames",
        .storage = Storage.externalPtr(.{ .owner = .js }),
        .properties = Properties.static(.{
            method(method_name, Payload.runtimeCachedMethodName),
        }),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);

    const method_atom = try rt.internAtom(method_name);
    defer rt.atoms.free(method_atom);

    try ObjectType.install(ctx);
    const binding = try ObjectType.binding(ctx);
    ctx.destroy();

    const before_unregister = rt.atoms.refCount(method_atom).?;
    try std.testing.expect(before_unregister >= 2);
    rt.classes.unregisterDynamic(binding.class_id);
    try std.testing.expectEqual(before_unregister - 1, rt.atoms.refCount(method_atom).?);
}

test "JSObject typed method borrows utf8 string and byte slices" {
    const Payload = struct {
        label_len: usize = 0,
        label_borrowed: bool = true,
        input_sum: u32 = 0,

        fn mix(self: *@This(), label: JSString.Utf8, input: []const u8, output: []u8) !i32 {
            self.label_len = label.slice().len;
            self.label_borrowed = label.isBorrowed();
            var sum: u32 = 0;
            for (input) |byte| sum += byte;
            self.input_sum = sum;
            output[0] = input[1];
            return @intCast(output.len);
        }
    };
    const SharedState = struct {
        allocator: std.mem.Allocator,
        calls: usize = 0,

        fn deinit(context: ?*anyopaque, bytes: []u8) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.allocator.free(bytes);
        }
    };
    const ObjectType = JSObject(Payload, .{
        .name = "KernelBindingStringBytesPayload",
        .storage = Storage.externalPtr(.{ .owner = .js }),
        .properties = Properties.static(.{
            method("mix", Payload.mix),
        }),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    try ObjectType.install(ctx);
    const binding = try ObjectType.binding(ctx);
    const value = try binding.new(.{});
    defer value.free(rt);

    const label = (try core.string.String.createUtf8(rt, "é")).value();
    defer label.free(rt);

    const input_object = try core.Object.create(rt, core.class.ids.array_buffer, null);
    const input_value = input_object.value();
    defer input_value.free(rt);
    const input_backing = try rt.memory.alloc(u8, 3);
    @memcpy(input_backing, &[_]u8{ 1, 2, 3 });
    try input_object.installByteStorage(rt, input_backing);

    const output_object = try core.Object.create(rt, core.class.ids.array_buffer, null);
    const output_value = output_object.value();
    defer output_value.free(rt);
    const output_backing = try rt.memory.alloc(u8, 2);
    @memcpy(output_backing, &[_]u8{ 9, 9 });
    try output_object.installByteStorage(rt, output_backing);

    const object = objectFromValue(value).?;
    const mix_key = try rt.internAtom("mix");
    defer rt.atoms.free(mix_key);
    const mix_value = object.getProperty(mix_key);
    defer mix_value.free(rt);

    const result = try ctx.callFunction(mix_value, &.{
        label,
        input_value,
        output_value,
    }, .{ .this_value = value });
    defer result.free(rt);

    const payload = binding.payload(value).?;
    try std.testing.expectEqual(@as(i32, 2), result.asInt32().?);
    try std.testing.expectEqual(@as(usize, 2), payload.label_len);
    try std.testing.expect(!payload.label_borrowed);
    try std.testing.expectEqual(@as(u32, 6), payload.input_sum);
    try std.testing.expectEqual(@as(u8, 2), output_backing[0]);

    var shared_state = SharedState{ .allocator = std.testing.allocator };
    const shared_backing = try std.testing.allocator.alloc(u8, 2);
    @memcpy(shared_backing, &[_]u8{ 7, 8 });
    var shared_store = core.JSValue.Bytes.Store.shared(shared_backing, .{
        .deinit = SharedState.deinit,
        .context = &shared_state,
    });
    errdefer shared_store.release();
    const shared_output_value = try ctx.arrayBuffer(&shared_store);
    defer shared_output_value.free(rt);

    const global = try ctx.globalObject();
    try std.testing.expectError(error.JSException, ctx.callFunction(mix_value, &.{
        label,
        input_value,
        shared_output_value,
    }, .{ .this_value = value, .realm_global = global }));
    var shared_exception = ctx.takeException();
    defer shared_exception.free(rt);
    try expectErrorObjectProperty(ctx, shared_exception, "name", "TypeError");
    try std.testing.expectEqual(@as(usize, 0), shared_state.calls);

    const shared_view_object = try core.Object.create(rt, core.class.ids.object, null);
    const shared_view_value = shared_view_object.value();
    defer shared_view_value.free(rt);
    try shared_view_object.ensureTypedArrayPayload(rt);
    try shared_view_object.setOptionalValueSlot(rt, shared_view_object.typedArrayBufferSlot(), shared_output_value.dup());
    shared_view_object.typedArrayByteOffsetSlot().* = 0;
    shared_view_object.typedArrayElementSizeSlot().* = 1;
    shared_view_object.typedArrayFixedLengthSlot().* = 2;
    shared_view_object.typedArrayKindSlot().* = 2;

    try std.testing.expectError(error.JSException, ctx.callFunction(mix_value, &.{
        label,
        input_value,
        shared_view_value,
    }, .{ .this_value = value, .realm_global = global }));
    var shared_view_exception = ctx.takeException();
    defer shared_view_exception.free(rt);
    try expectErrorObjectProperty(ctx, shared_view_exception, "name", "TypeError");
    try std.testing.expectEqual(@as(usize, 0), shared_state.calls);
}

test "JSObject typed method errors become pending JS exceptions" {
    const Payload = struct {
        value: i32 = 0,

        fn narrow(self: *@This(), amount: u8) i32 {
            _ = self;
            return amount;
        }

        fn failCustom(self: *@This()) !void {
            _ = self;
            return error.BindingCustomFailure;
        }

        fn failType(self: *@This()) !void {
            _ = self;
            return error.TypeError;
        }

        fn failSyntax(self: *@This()) !void {
            _ = self;
            return error.SyntaxError;
        }
    };
    const ObjectType = JSObject(Payload, .{
        .name = "KernelBindingErrorPayload",
        .storage = Storage.externalPtr(.{ .owner = .js }),
        .properties = Properties.static(.{
            method("narrow", Payload.narrow),
            method("failCustom", Payload.failCustom),
            method("failType", Payload.failType),
            method("failSyntax", Payload.failSyntax),
        }),
    });

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    try ObjectType.install(ctx);
    const global = try ctx.globalObject();
    const binding = try ObjectType.binding(ctx);
    const value = try binding.new(.{});
    defer value.free(rt);

    const object = objectFromValue(value).?;
    const narrow_value = try objectProperty(rt, object, "narrow");
    defer narrow_value.free(rt);
    try std.testing.expectError(error.JSException, ctx.callFunction(narrow_value, &.{
        core.JSValue.int32(300),
    }, .{ .this_value = value, .realm_global = global }));
    var range_exception = ctx.takeException();
    defer range_exception.free(rt);
    try expectErrorObjectProperty(ctx, range_exception, "name", "RangeError");
    try expectErrorObjectProperty(ctx, range_exception, "message", "");

    const custom_value = try objectProperty(rt, object, "failCustom");
    defer custom_value.free(rt);
    try std.testing.expectError(error.JSException, ctx.callFunction(custom_value, &.{}, .{ .this_value = value, .realm_global = global }));
    var custom_exception = ctx.takeException();
    defer custom_exception.free(rt);
    try expectErrorObjectProperty(ctx, custom_exception, "name", "Error");
    try expectErrorObjectProperty(ctx, custom_exception, "message", "BindingCustomFailure");

    const type_value = try objectProperty(rt, object, "failType");
    defer type_value.free(rt);
    try std.testing.expectError(error.JSException, ctx.callFunction(type_value, &.{}, .{ .this_value = value, .realm_global = global }));
    var type_exception = ctx.takeException();
    defer type_exception.free(rt);
    try expectErrorObjectProperty(ctx, type_exception, "name", "TypeError");
    try expectErrorObjectProperty(ctx, type_exception, "message", "");

    const syntax_value = try objectProperty(rt, object, "failSyntax");
    defer syntax_value.free(rt);
    try std.testing.expectError(error.JSException, ctx.callFunction(syntax_value, &.{}, .{ .this_value = value, .realm_global = global }));
    var syntax_exception = ctx.takeException();
    defer syntax_exception.free(rt);
    try expectErrorObjectProperty(ctx, syntax_exception, "name", "SyntaxError");
    try expectErrorObjectProperty(ctx, syntax_exception, "message", "");
}

fn objectProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8) !core.JSValue {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    return object.getProperty(key);
}

fn expectErrorObjectProperty(ctx: *core.JSContext, value: core.JSValue, property_name: []const u8, expected: []const u8) !void {
    const rt = ctx.runtimePtr();
    const object = objectFromValue(value) orelse return error.TypeError;
    const property_value = try objectProperty(rt, object, property_name);
    defer property_value.free(rt);
    const bytes = try ctx.toOwnedUtf8(property_value, std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(expected, bytes);
}
