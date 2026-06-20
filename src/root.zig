const std = @import("std");

const zjs_binding = @import("binding/root.zig");
pub const runtime = @import("runtime/public.zig");
const zjs_core = @import("core/root.zig");
const zjs_exec = @import("exec/root.zig");
const zjs_builtins = @import("builtins/root.zig");
const CoreObject = zjs_binding.Object;

pub const JSRuntime = zjs_binding.JSRuntime;
pub const JSContext = zjs_binding.JSContext;
pub const ffi = zjs_binding.ffi;
pub const JSValue = zjs_binding.JSValue;
pub const RuntimeOptions = zjs_binding.RuntimeOptions;
pub const RuntimeMemoryUsage = zjs_binding.RuntimeMemoryUsage;
pub const OpcodeProfile = zjs_binding.OpcodeProfile;
pub const default_stack_size = zjs_binding.default_stack_size;
pub const default_gc_threshold = zjs_binding.default_gc_threshold;

pub fn activateOpcodeProfile(profile: ?*OpcodeProfile) ?*OpcodeProfile {
    zjs_core.profile.setOpcodeNameProvider(zjs_exec.opcodeName);
    return zjs_binding.activateOpcodeProfile(profile);
}

pub const value = struct {
    pub const Value = zjs_binding.JSValue;
    pub const Scope = zjs_binding.HandleScope;
    pub const Local = zjs_binding.LocalHandle;
    pub const Ref = zjs_binding.JSValueHandle;
    pub const Persistent = zjs_binding.JSValueHandle;
    pub const WeakRef = zjs_binding.WeakPersistentValue;
    pub const Weak = zjs_binding.WeakPersistentValue;
    pub const String = zjs_binding.JSString;
    pub const Bytes = zjs_binding.JSBytes;

    pub fn undefinedValue() Value {
        return Value.undefinedValue();
    }

    pub fn nullValue() Value {
        return Value.nullValue();
    }

    pub fn boolean(v: bool) Value {
        return Value.boolean(v);
    }

    pub fn int32(v: i32) Value {
        return Value.int32(v);
    }

    pub fn float64(v: f64) Value {
        return Value.float64(v);
    }

    pub fn numberFromU64(v: u64) Value {
        if (v <= @as(u64, @intCast(std.math.maxInt(i32)))) {
            return Value.int32(@intCast(v));
        }
        return Value.float64(@floatFromInt(v));
    }

    pub fn numberFromI64(v: i64) Value {
        if (v >= std.math.minInt(i32) and v <= std.math.maxInt(i32)) {
            return Value.int32(@intCast(v));
        }
        return Value.float64(@floatFromInt(v));
    }

    /// Create a JS BigInt from a signed 64-bit integer. Demotes to an inline
    /// short BigInt when the value fits the short range; otherwise allocates a
    /// heap BigInt. Precise: no precision loss across the full i64 range.
    pub fn bigIntFromI64(runtime_ptr: *JSRuntime, v: i64) !Value {
        return zjs_exec.value_ops.createBigIntI128(runtime_ptr, v);
    }

    /// Create a JS BigInt from an unsigned 64-bit integer. u64::MAX (~1.8e19)
    /// fits i128, so widening to i128 is lossless; values above i64::MAX
    /// allocate a heap BigInt. Do NOT widen via i64 (would truncate the top bit).
    pub fn bigIntFromU64(runtime_ptr: *JSRuntime, v: u64) !Value {
        return zjs_exec.value_ops.createBigIntI128(runtime_ptr, @as(i128, v));
    }

    pub fn createString(runtime_ptr: *JSRuntime, bytes: []const u8) !Value {
        return zjs_exec.value_ops.createStringValue(runtime_ptr, bytes);
    }

    pub fn appendRawString(runtime_ptr: *JSRuntime, out: *std.ArrayList(u8), v: Value) !void {
        try zjs_exec.value_ops.appendRawString(runtime_ptr, out, v);
    }

    pub fn appendString(runtime_ptr: *JSRuntime, out: *std.ArrayList(u8), v: Value) !void {
        try zjs_exec.value_ops.appendValueString(runtime_ptr, out, v);
    }

    pub fn toOwnedString(runtime_ptr: *JSRuntime, v: Value) ![]u8 {
        var buffer = std.ArrayList(u8).empty;
        errdefer buffer.deinit(runtime_ptr.memory.allocator);
        if (v.isString()) {
            try appendRawString(runtime_ptr, &buffer, v);
        } else {
            try appendString(runtime_ptr, &buffer, v);
        }
        return buffer.toOwnedSlice(runtime_ptr.memory.allocator);
    }

    pub fn toIntegerOrInfinity(runtime_ptr: *JSRuntime, v: Value) !f64 {
        return zjs_exec.value_ops.toIntegerOrInfinity(runtime_ptr, v);
    }

    pub fn isTruthy(v: Value) bool {
        return zjs_exec.value_ops.isTruthy(v);
    }
};

pub const host = struct {
    pub const Call = zjs_binding.ExternalHostCall;
    pub const Function = zjs_binding.ExternalHostCallFn;
    pub const Finalizer = zjs_binding.ExternalHostFinalizer;
    pub const FunctionOptions = zjs_binding.ExternalFunctionOptions;
    pub const NativeClass = zjs_binding.binding.JSObject;
    pub const NativeBinding = zjs_binding.binding;
    pub const NativeObject = object.Object;
    pub const PropName = zjs_binding.PropNameID;

    pub fn defineScriptArgs(ctx: *JSContext, args: []const []const u8) !void {
        try object.defineStringArrayGlobal(ctx, "scriptArgs", args);
    }

    pub fn defineArgvGlobals(ctx: *JSContext, argv0: []const u8, exec_argv: []const []const u8) !void {
        const rt = ctx.runtimePtr();
        const global = object.fromCore(try ctx.globalObject());
        try object.defineStringProperty(rt, global, "argv0", argv0);
        try object.defineStringArrayGlobal(ctx, "execArgv", exec_argv);
    }

    pub fn evalGlobalScriptSource(
        ctx: *JSContext,
        output: ?*std.Io.Writer,
        global: *object.Object,
        source: []const u8,
        filename: []const u8,
    ) !value.Value {
        return evalGlobalScriptSourceCore(ctx, output, object.toCore(global), source, filename);
    }

    pub fn evalGlobalScriptValue(
        ctx: *JSContext,
        output: ?*std.Io.Writer,
        global: *object.Object,
        source_value: value.Value,
        filename: []const u8,
    ) !value.Value {
        if (!source_value.isString()) return error.TypeError;
        const source = try value.toOwnedString(ctx.runtimePtr(), source_value);
        defer ctx.runtimePtr().memory.allocator.free(source);
        return evalGlobalScriptSource(ctx, output, global, source, filename);
    }

    fn evalGlobalScriptSourceCore(
        ctx: *JSContext,
        output: ?*std.Io.Writer,
        global: *CoreObject,
        source: []const u8,
        filename: []const u8,
    ) !value.Value {
        return zjs_exec.call.qjsEvalGlobalScriptSource(&ctx.core, output, global, source, filename);
    }

    fn evalGlobalScriptValueCore(
        ctx: *JSContext,
        output: ?*std.Io.Writer,
        global: *CoreObject,
        source_value: value.Value,
        filename: []const u8,
    ) !value.Value {
        if (!source_value.isString()) return error.TypeError;
        const source = try value.toOwnedString(ctx.runtimePtr(), source_value);
        defer ctx.runtimePtr().memory.allocator.free(source);
        return evalGlobalScriptSourceCore(ctx, output, global, source, filename);
    }
};

pub const object = struct {
    pub const Object = opaque {};
    pub const Builder = struct {};
    pub const Template = struct {};
    pub const MemoryAccount = zjs_core.memory.MemoryAccount;
    pub const SharedArrayBufferRef = zjs_binding.SharedArrayBufferRef;
    pub const String = zjs_core.string.String;

    fn fromCore(obj: *CoreObject) *Object {
        return @ptrCast(obj);
    }

    fn toCore(obj: *Object) *CoreObject {
        return @ptrCast(@alignCast(obj));
    }

    fn optionalToCore(obj: ?*Object) ?*CoreObject {
        return if (obj) |some| toCore(some) else null;
    }

    fn coreFromValue(v: value.Value) ?*CoreObject {
        if (!v.isObject()) return null;
        const header = v.refHeader() orelse return null;
        if (header.kind != .object) return null;
        return @fieldParentPtr("header", header);
    }

    pub fn toValue(obj: *Object) value.Value {
        return toCore(obj).value();
    }

    pub fn arrayLength(obj: *Object) u32 {
        return toCore(obj).arrayLength();
    }

    pub fn promiseResult(obj: *Object) ?value.Value {
        return toCore(obj).promiseResult();
    }

    pub fn promiseIsRejected(obj: *Object) bool {
        return toCore(obj).promiseIsRejected();
    }

    pub const OwnDataProperty = struct {
        name: []const u8,
        value: value.Value,
        enumerable: bool,
    };

    pub fn forEachOwnDataProperty(
        rt: *JSRuntime,
        obj: *Object,
        visitor_context: anytype,
        comptime visitor: anytype,
    ) !void {
        // Property storage is split across two parallel arrays: the shape
        // (`shapeProps()[i]`) carries the per-property flags + atom_id, while
        // `properties[i].slot` carries the value union. (Mirrors the core
        // accessor `Object.getOwnDataPropertyValueAt`.)
        const core_obj = toCore(obj);
        const shape_props = core_obj.shapeProps();
        for (shape_props, 0..) |shape_prop, i| {
            const flags = zjs_core.property.Flags.fromBits(shape_prop.flags);
            if (flags.deleted or flags.accessor) continue;
            const stored = switch (core_obj.properties[i].slot) {
                .data => |value_slot| value_slot,
                else => continue,
            };
            const name = rt.atoms.name(shape_prop.atom_id) orelse continue;
            try visitor(visitor_context, OwnDataProperty{
                .name = name,
                .value = stored,
                .enumerable = flags.enumerable,
            });
        }
    }

    pub const Buffer = struct {
        pub fn isTypedArrayObject(obj: *Object) bool {
            return zjs_builtins.buffer.isTypedArrayObject(toCore(obj));
        }

        pub fn typedArrayByteLength(rt: *JSRuntime, obj: *Object) !usize {
            return zjs_builtins.buffer.typedArrayByteLength(rt, toCore(obj));
        }

        pub fn ownedBytesFromObject(rt: *JSRuntime, obj: *Object) ![]u8 {
            const bytes = value.Bytes.fromObject(toCore(obj)) catch |err| return bufferViewError(err);
            return rt.memory.allocator.dupe(u8, bytes.slice());
        }

        pub fn createUint8ArrayFromBytes(rt: *JSRuntime, global: *Object, bytes: []const u8) !value.Value {
            return zjs_exec.array_ops.createUint8ArrayFromBytes(rt, toCore(global), bytes);
        }

        /// Consumes bytes allocated by `rt.memory` on success and failure.
        pub fn createUint8ArrayFromOwnedBytes(rt: *JSRuntime, global: *Object, bytes: []u8) !value.Value {
            var bytes_owned = true;
            errdefer if (bytes_owned) rt.memory.free(u8, bytes);

            if (bytes.len > @as(usize, @intCast(std.math.maxInt(i32)))) return error.RangeError;
            const buffer_proto = try constructorPrototypeObject(rt, global, "ArrayBuffer");
            const buffer_value = try zjs_builtins.buffer.arrayBufferConstructLength(rt, 0, null, optionalToCore(buffer_proto));
            var buffer_owned = true;
            errdefer if (buffer_owned) buffer_value.free(rt);

            const buffer = fromValue(buffer_value) orelse return error.TypeError;
            const buffer_core = toCore(buffer);
            try buffer_core.installByteStorage(rt, bytes);
            bytes_owned = false;

            const typed_array_proto = try constructorPrototypeObject(rt, global, "Uint8Array");
            buffer_owned = false;
            return zjs_builtins.buffer.typedArrayConstructFullBufferOwned(rt, 1, 2, buffer_value, buffer_core, optionalToCore(typed_array_proto));
        }

        fn bufferViewError(err: value.Bytes.Error) anyerror {
            return switch (err) {
                error.TypeError, error.Detached, error.OutOfBounds, error.InvalidStore, error.ReadOnly => error.TypeError,
            };
        }

        /// What backing-store shape a borrow descriptor was derived from. Lets a
        /// host distinguish a whole ArrayBuffer from a TypedArray/DataView window
        /// (which carry a non-zero `byte_offset` into the backing store) without
        /// leaking core object types.
        pub const BorrowKind = enum { array_buffer, typed_array, data_view };

        /// A zero-copy, kind-aware borrow of a buffer object's live backing store
        /// (B3). `ptr`/`len` point DIRECTLY at the backing []u8 — no dupe. The
        /// borrow is valid only while the source object is kept alive AND not
        /// detached/resized; see `BorrowGuard` (pins against GC) and
        /// `checkStillValid` (re-validates against detach). For a TypedArray or
        /// DataView, `byte_offset` is the window's offset within the backing
        /// ArrayBuffer and `len` is the window's byte length.
        pub const Borrow = struct {
            ptr: [*]const u8,
            mut_ptr: ?[*]u8 = null,
            len: usize,
            kind: BorrowKind,
            byte_offset: usize = 0,
            shared: bool = false,

            /// Read-only view of the borrowed backing store.
            pub fn slice(self: Borrow) []const u8 {
                return self.ptr[0..self.len];
            }

            /// Mutable view of the borrowed backing store, or `error.ReadOnly`
            /// when the source is an immutable ArrayBuffer.
            pub fn sliceMut(self: Borrow) error{ReadOnly}![]u8 {
                const ptr = self.mut_ptr orelse return error.ReadOnly;
                return ptr[0..self.len];
            }

            /// True iff the borrow is mutable (the backing store is writable and
            /// native writes are visible to JS).
            pub fn isMutable(self: Borrow) bool {
                return self.mut_ptr != null;
            }

            /// True iff the backing store is a SharedArrayBuffer.
            pub fn isShared(self: Borrow) bool {
                return self.shared;
            }
        };

        /// A zero-copy READ-ONLY borrow of a buffer object's live backing store
        /// (B3). Unlike `Borrow`, this type carries NO mutable pointer and exposes
        /// NO `sliceMut` — it is the type that backs the host-facing `Bytes`
        /// newtype. Because the type physically has no write entry point, a host
        /// function that receives a read-only `Bytes` cannot reach a writable view
        /// even by reaching through the wrapper's field: `b.borrow.sliceMut()` and
        /// `b.borrow.mut_ptr` are both compile errors here (the method/field do not
        /// exist). This is the type-level guarantee that read-only is read-only.
        pub const ReadonlyBorrow = struct {
            ptr: [*]const u8,
            len: usize,
            kind: BorrowKind,
            byte_offset: usize = 0,
            shared: bool = false,

            /// Read-only view of the borrowed backing store.
            pub fn slice(self: ReadonlyBorrow) []const u8 {
                return self.ptr[0..self.len];
            }

            /// True iff the backing store is a SharedArrayBuffer.
            pub fn isShared(self: ReadonlyBorrow) bool {
                return self.shared;
            }
        };

        /// A safe, scoped pin handle for a borrow (B3). Pinning prevents the GC
        /// from freeing the source object — and, for a TypedArray/DataView, the
        /// BACKING ArrayBuffer object that actually owns the bytes — for the
        /// duration of the host call. It is NOT a raw `NativePin`: the extension
        /// receives only `release()`. Pin protects against GC collection; it does
        /// NOT protect against an explicit JS `detach`/`resize` (re-derive +
        /// `checkStillValid` for that — see `borrow_scope` docs).
        pub const BorrowGuard = struct {
            view_pin: ?zjs_core.NativePin = null,
            buffer_pin: ?zjs_core.NativePin = null,

            /// Release every pin held by this guard (idempotent). Called at the
            /// end of the borrow scope (host-call return).
            pub fn release(self: *BorrowGuard) void {
                if (self.view_pin) |*pin| pin.release();
                if (self.buffer_pin) |*pin| pin.release();
                self.view_pin = null;
                self.buffer_pin = null;
            }
        };

        /// Classify a buffer object's borrow kind (ArrayBuffer / TypedArray /
        /// DataView). Returns TypeError for any other object.
        fn borrowKind(core_obj: *CoreObject) !BorrowKind {
            if (core_obj.class_id == zjs_core.class.ids.array_buffer or
                core_obj.class_id == zjs_core.class.ids.shared_array_buffer)
                return .array_buffer;
            if (core_obj.class_id == zjs_core.class.ids.dataview) return .data_view;
            if (zjs_builtins.buffer.isTypedArrayObject(core_obj)) return .typed_array;
            return error.TypeError;
        }

        /// Resolve the backing ArrayBuffer core object for a TypedArray/DataView,
        /// or the object itself for an ArrayBuffer. The bytes physically live in
        /// this object, so it is the one a borrow must pin.
        fn backingBufferCore(core_obj: *CoreObject) ?*CoreObject {
            if (core_obj.class_id == zjs_core.class.ids.array_buffer or
                core_obj.class_id == zjs_core.class.ids.shared_array_buffer)
                return core_obj;
            const buffer_value = core_obj.typedArrayBuffer() orelse return null;
            return coreFromValue(buffer_value);
        }

        /// B3 public zero-copy borrow entry: produce a kind-aware `Borrow` that
        /// points DIRECTLY at `obj`'s live backing store (no copy), distinguishing
        /// ArrayBuffer / TypedArray / DataView byteOffset/byteLength. Detach is
        /// rejected up front (`error.TypeError`, via `bufferViewError`). The
        /// returned borrow is valid only while the source stays alive and is not
        /// detached/resized — pair it with `pinForBorrow` for GC safety.
        pub fn borrowBytes(rt: *JSRuntime, obj: *Object) !Borrow {
            _ = rt;
            const core_obj = toCore(obj);
            const kind = borrowKind(core_obj) catch |err| return err;
            const bytes = value.Bytes.fromObject(core_obj) catch |err| return bufferViewError(err);
            const byte_offset = switch (kind) {
                .array_buffer => 0,
                .typed_array, .data_view => core_obj.typedArrayByteOffset(),
            };
            return .{
                .ptr = bytes.ptr,
                .mut_ptr = bytes.mut_ptr,
                .len = bytes.len,
                .kind = kind,
                .byte_offset = byte_offset,
                .shared = bytes.isShared(),
            };
        }

        /// B3 read-only zero-copy borrow entry: like `borrowBytes`, but returns a
        /// `ReadonlyBorrow` that carries NO mutable pointer and NO `sliceMut`. Use
        /// this to back a read-only `Bytes` so the borrow physically cannot be
        /// upgraded to a write. Same lifetime contract as `borrowBytes` (valid
        /// only while the source stays alive + undetached; pair with
        /// `pinForBorrow`). Detach is rejected up front (`error.TypeError`).
        pub fn borrowBytesReadonly(rt: *JSRuntime, obj: *Object) !ReadonlyBorrow {
            const full = try borrowBytes(rt, obj);
            return .{
                .ptr = full.ptr,
                .len = full.len,
                .kind = full.kind,
                .byte_offset = full.byte_offset,
                .shared = full.shared,
            };
        }

        /// Pin the source object (and, for a TypedArray/DataView, its backing
        /// ArrayBuffer object) so neither can be GC-freed for the borrow scope.
        /// Returns a safe `BorrowGuard`; the caller MUST `release()` it at scope
        /// end. Pin does NOT freeze the backing store against an explicit JS
        /// detach/resize — use `checkStillValid` after any reentrant step.
        pub fn pinForBorrow(rt: *JSRuntime, obj: *Object) !BorrowGuard {
            const core_obj = toCore(obj);
            var guard = BorrowGuard{};
            errdefer guard.release();

            // Pin the view object itself.
            guard.view_pin = try zjs_core.runtime.pinHeaderForNative(rt, &core_obj.header);

            // For a TypedArray/DataView, the bytes live in the backing buffer
            // object; pin THAT too (pinning only the view leaves bytes collectable).
            if (backingBufferCore(core_obj)) |backing| {
                if (backing != core_obj) {
                    guard.buffer_pin = try zjs_core.runtime.pinHeaderForNative(rt, &backing.header);
                }
            }
            return guard;
        }

        /// The backing ArrayBuffer Value for a TypedArray/DataView, or the
        /// object's own Value for an ArrayBuffer. Useful for host code that wants
        /// to detach/resize/inspect the actual byte owner (the bytes physically
        /// live in this buffer). Returns null for a non-buffer object. The
        /// returned Value is NOT dup'd (it aliases the live slot).
        pub fn backingArrayBufferValue(obj: *Object) ?value.Value {
            const core_obj = toCore(obj);
            const backing = backingBufferCore(core_obj) orelse return null;
            return backing.value();
        }

        /// Detach the backing ArrayBuffer of `obj` (an ArrayBuffer, or the
        /// backing buffer of a TypedArray/DataView), freeing its storage and
        /// marking it detached. After this, any borrow of `obj` throws Detached.
        /// No-op (returns) for a non-buffer object. This is the public,
        /// kind-aware detach a host uses to invalidate outstanding borrows.
        pub fn detachBackingBuffer(rt: *JSRuntime, obj: *Object) void {
            const core_obj = toCore(obj);
            const backing = backingBufferCore(core_obj) orelse return;
            backing.detachByteStorage(rt);
        }

        /// Re-validate a previously taken borrow against detach (B3 lifetime
        /// safety). After any step that could re-enter JS (a callback) — which
        /// might detach or resize the backing buffer — call this with the SAME
        /// source object; it returns `error.Detached` if the buffer was detached
        /// (the old `Borrow.ptr` is then dead) and otherwise a freshly derived,
        /// currently-valid `Borrow`. Resize is covered because the fresh borrow
        /// reads the current backing pointer/length. The OLD borrow must not be
        /// used after a may-reenter step without going through this check.
        pub fn checkStillValid(rt: *JSRuntime, obj: *Object) !Borrow {
            return borrowBytes(rt, obj);
        }
    };

    pub fn createPlain(rt: *JSRuntime) !*Object {
        return fromCore(try CoreObject.create(rt, zjs_core.class.ids.object, null));
    }

    pub fn createError(rt: *JSRuntime, prototype: ?*Object) !*Object {
        return fromCore(try CoreObject.create(rt, zjs_core.class.ids.error_, optionalToCore(prototype)));
    }

    pub fn createArray(rt: *JSRuntime, prototype: ?*Object) !*Object {
        return fromCore(try CoreObject.createArray(rt, optionalToCore(prototype)));
    }

    pub fn createArrayValue(rt: *JSRuntime, prototype: ?*Object) !value.Value {
        return toValue(try createArray(rt, prototype));
    }

    pub fn createArrayBuffer(rt: *JSRuntime, prototype: ?*Object) !*Object {
        return fromCore(try CoreObject.create(rt, zjs_core.class.ids.array_buffer, optionalToCore(prototype)));
    }

    pub fn fromValue(v: value.Value) ?*Object {
        return if (coreFromValue(v)) |obj| fromCore(obj) else null;
    }

    pub fn isCallableValue(v: value.Value) bool {
        const obj = coreFromValue(v) orelse return false;
        return obj.class_id == zjs_core.class.ids.c_function or
            obj.class_id == zjs_core.class.ids.bytecode_function or
            obj.class_id == zjs_core.class.ids.c_closure or
            obj.class_id == zjs_core.class.ids.bound_function;
    }

    pub fn isPromiseObject(obj: *Object) bool {
        return toCore(obj).class_id == zjs_core.class.ids.promise;
    }

    pub fn isPromiseValue(v: value.Value) bool {
        const obj = fromValue(v) orelse return false;
        return isPromiseObject(obj);
    }

    /// True iff `v` is a genuine JS Array (the `Array.isArray` brand), following
    /// proxy chains to their ultimate target. This is NOT `isObject`: a plain
    /// object `{}`, an array-like `{0:1, length:1}`, and a TypedArray all return
    /// false. A revoked proxy reports as not-array (callers that need the spec's
    /// revoked-proxy TypeError must check it separately). Delegates to the
    /// engine-core proxy-aware predicate (`core.array.isArrayValue`) so marshalling
    /// fast paths share one source of truth with `Array.isArray`; allocation-free.
    pub fn isArray(v: value.Value) bool {
        return zjs_core.array.isArrayValue(v) catch false;
    }

    pub fn isArrayBufferObject(obj: *Object) bool {
        return toCore(obj).class_id == zjs_core.class.ids.array_buffer;
    }

    pub fn isTypedArrayObject(obj: *Object) bool {
        return zjs_builtins.buffer.isTypedArrayObject(toCore(obj));
    }

    pub fn typedArrayByteLength(rt: *JSRuntime, obj: *Object) !usize {
        return zjs_builtins.buffer.typedArrayByteLength(rt, toCore(obj));
    }

    pub fn arrayBufferConstructLength(rt: *JSRuntime, len: usize, proto: ?*Object) !value.Value {
        return zjs_builtins.buffer.arrayBufferConstructLength(rt, len, null, optionalToCore(proto));
    }

    pub fn typedArrayConstructFullBufferOwned(
        rt: *JSRuntime,
        element_size: usize,
        kind: u8,
        buffer_value: value.Value,
        buffer: *Object,
        prototype: ?*Object,
    ) !value.Value {
        return zjs_builtins.buffer.typedArrayConstructFullBufferOwned(rt, @intCast(element_size), kind, buffer_value, toCore(buffer), optionalToCore(prototype));
    }

    fn atomFromUInt32(index: u32) zjs_core.Atom {
        return zjs_core.atom.atomFromUInt32(index);
    }

    pub fn getProperty(rt: *JSRuntime, obj: *Object, name: []const u8) !value.Value {
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        return toCore(obj).getProperty(key);
    }

    pub fn getOwnIndexPropertyValue(rt: *JSRuntime, obj: *Object, index: u32) ?value.Value {
        const desc = toCore(obj).getOwnProperty(atomFromUInt32(index)) orelse return null;
        if (!desc.value_present) {
            desc.destroy(rt);
            return null;
        }
        return desc.value;
    }

    pub fn defineValueProperty(rt: *JSRuntime, obj: *Object, name: []const u8, v: value.Value) !void {
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        try toCore(obj).defineOwnProperty(rt, key, zjs_core.Descriptor.data(v, true, true, true));
    }

    pub fn defineHiddenValueProperty(rt: *JSRuntime, obj: *Object, name: []const u8, v: value.Value) !void {
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        try toCore(obj).defineOwnProperty(rt, key, zjs_core.Descriptor.data(v, false, false, false));
    }

    pub fn defineAccessorProperty(
        rt: *JSRuntime,
        obj: *Object,
        name: []const u8,
        getter: value.Value,
        setter: value.Value,
    ) !void {
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        try toCore(obj).defineOwnProperty(rt, key, zjs_core.Descriptor.accessor(getter, setter, true, true));
    }

    pub fn defineStringProperty(rt: *JSRuntime, obj: *Object, name: []const u8, bytes: []const u8) !void {
        const string_value = try value.createString(rt, bytes);
        defer string_value.free(rt);
        try defineValueProperty(rt, obj, name, string_value);
    }

    pub fn defineHiddenStringProperty(rt: *JSRuntime, obj: *Object, name: []const u8, bytes: []const u8) !void {
        const string_value = try value.createString(rt, bytes);
        defer string_value.free(rt);
        try defineHiddenValueProperty(rt, obj, name, string_value);
    }

    pub fn defineIntProperty(rt: *JSRuntime, obj: *Object, name: []const u8, v: u16) !void {
        try defineValueProperty(rt, obj, name, value.int32(@intCast(v)));
    }

    pub fn defineHiddenIntProperty(rt: *JSRuntime, obj: *Object, name: []const u8, v: u16) !void {
        try defineHiddenValueProperty(rt, obj, name, value.int32(@intCast(v)));
    }

    pub fn defineStringArrayGlobal(ctx: *JSContext, name: []const u8, items: []const []const u8) !void {
        if (items.len == 0) {
            try defineEmptyArrayGlobal(ctx, name);
            return;
        }

        const rt = ctx.runtimePtr();
        const global = fromCore(try ctx.globalObject());
        const array_prototype = cachedArrayPrototype(global) orelse try constructorPrototypeObject(rt, global, "Array");
        const array = fromCore(try CoreObject.createArrayWithOwnPropertyCapacity(rt, optionalToCore(array_prototype), items.len));
        const array_value = toValue(array);
        errdefer array_value.free(rt);
        const array_core = toCore(array);
        for (items, 0..) |item, index| {
            const item_value = try value.createString(rt, item);
            array_core.defineOwnProperty(rt, atomFromUInt32(@intCast(index)), zjs_core.Descriptor.data(item_value, true, true, true)) catch |err| {
                item_value.free(rt);
                return err;
            };
            item_value.free(rt);
        }
        array_core.setArrayLength(@intCast(items.len));
        try defineValueProperty(rt, global, name, array_value);
        array_value.free(rt);
    }

    fn cachedArrayPrototype(global: *Object) ?*Object {
        const stored = toCore(global).cachedRealmValue(.array_prototype) orelse return null;
        return fromCore(coreFromValue(stored) orelse return null);
    }

    fn defineEmptyArrayGlobal(ctx: *JSContext, name: []const u8) !void {
        const rt = ctx.runtimePtr();
        const global = fromCore(try ctx.globalObject());
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        const flags = zjs_core.property.Flags.data(true, true, true);
        try toCore(global).defineEmptyArrayAutoInitProperty(rt, key, flags, toCore(global));
    }

    pub fn constructorPrototypeObject(rt: *JSRuntime, global: *Object, name: []const u8) !?*Object {
        const key = try rt.internAtom(name);
        defer rt.atoms.free(key);
        const constructor_value = toCore(global).getProperty(key);
        defer constructor_value.free(rt);
        const constructor = coreFromValue(constructor_value) orelse return null;
        const prototype_value = constructor.getProperty(zjs_core.atom.ids.prototype);
        defer prototype_value.free(rt);
        return fromValue(prototype_value);
    }

    pub fn appendArrayValue(rt: *JSRuntime, array: *Object, v: value.Value) !void {
        const array_core = toCore(array);
        try array_core.defineOwnProperty(
            rt,
            atomFromUInt32(array_core.arrayLength()),
            zjs_core.Descriptor.data(v, true, true, true),
        );
    }
};

test "public object appendArrayValue maintains array length once" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const array = try object.createArray(rt, null);
    const array_value = object.toValue(array);
    defer array_value.free(rt);

    try object.appendArrayValue(rt, array, value.int32(1));
    try object.appendArrayValue(rt, array, value.int32(2));

    try std.testing.expectEqual(@as(u32, 2), object.arrayLength(array));
    const first = object.getOwnIndexPropertyValue(rt, array, 0).?;
    defer first.free(rt);
    const second = object.getOwnIndexPropertyValue(rt, array, 1).?;
    defer second.free(rt);
    try std.testing.expectEqual(@as(?i32, 1), first.asInt32());
    try std.testing.expectEqual(@as(?i32, 2), second.asInt32());
}

test "public host defineScriptArgs materializes empty array on first read" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try JSContext.create(rt);
    defer ctx.destroy();

    try host.defineScriptArgs(ctx, &.{"stale"});
    try host.defineScriptArgs(ctx, &.{});
    try host.defineScriptArgs(ctx, &.{});
    const result = try ctx.eval(
        \\var desc = Object.getOwnPropertyDescriptor(globalThis, "scriptArgs");
        \\desc.writable === true &&
        \\desc.enumerable === true &&
        \\desc.configurable === true &&
        \\Array.isArray(desc.value) &&
        \\desc.value.length === 0 &&
        \\Object.getPrototypeOf(scriptArgs) === Array.prototype &&
        \\(scriptArgs.push("ok"), scriptArgs.length === 1 && scriptArgs[0] === "ok") &&
        \\delete globalThis.scriptArgs &&
        \\!("scriptArgs" in globalThis);
    , .{});
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "public Buffer helpers create and copy Uint8Array bytes" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try JSContext.create(rt);
    defer ctx.destroy();

    const global = try context.globalObject(ctx);
    const value_from_copy = try object.Buffer.createUint8ArrayFromBytes(rt, global, "abc");
    defer value_from_copy.free(rt);
    const typed_array = object.fromValue(value_from_copy).?;
    const copied = try object.Buffer.ownedBytesFromObject(rt, typed_array);
    defer rt.memory.allocator.free(copied);
    try std.testing.expectEqualStrings("abc", copied);

    const owned = try rt.memory.alloc(u8, 3);
    @memcpy(owned, "xyz");
    const value_from_owned = try object.Buffer.createUint8ArrayFromOwnedBytes(rt, global, owned);
    defer value_from_owned.free(rt);
    const owned_typed_array = object.fromValue(value_from_owned).?;
    const copied_owned = try object.Buffer.ownedBytesFromObject(rt, owned_typed_array);
    defer rt.memory.allocator.free(copied_owned);
    try std.testing.expectEqualStrings("xyz", copied_owned);
}

test "public object isArray brands real arrays only" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try JSContext.create(rt);
    defer ctx.destroy();

    // A genuine Array is branded true.
    const array = try object.createArray(rt, null);
    const array_value = object.toValue(array);
    defer array_value.free(rt);
    try std.testing.expect(object.isArray(array_value));

    // A plain object is NOT an array.
    const plain = try object.createPlain(rt);
    const plain_value = object.toValue(plain);
    defer plain_value.free(rt);
    try std.testing.expect(!object.isArray(plain_value));

    // A TypedArray (Uint8Array) is an object but NOT an Array brand.
    const global = try context.globalObject(ctx);
    const typed = try object.Buffer.createUint8ArrayFromBytes(rt, global, "abc");
    defer typed.free(rt);
    try std.testing.expect(!object.isArray(typed));

    // Non-object primitives are never arrays.
    try std.testing.expect(!object.isArray(value.int32(7)));
    try std.testing.expect(!object.isArray(value.undefinedValue()));
}

test "public Buffer borrowBytes views ArrayBuffer live store without copying" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try JSContext.create(rt);
    defer ctx.destroy();

    const global = try context.globalObject(ctx);
    // A Uint8Array over a fresh ArrayBuffer; borrow the ArrayBuffer itself.
    const ta_val = try object.Buffer.createUint8ArrayFromBytes(rt, global, &.{ 1, 2, 3, 4 });
    defer ta_val.free(rt);
    const ta = object.fromValue(ta_val).?;

    // Borrowing the TypedArray gives a typed_array kind with offset 0, len 4.
    var borrow = try object.Buffer.borrowBytes(rt, ta);
    try std.testing.expectEqual(object.Buffer.BorrowKind.typed_array, borrow.kind);
    try std.testing.expectEqual(@as(usize, 0), borrow.byte_offset);
    try std.testing.expectEqual(@as(usize, 4), borrow.len);
    try std.testing.expect(borrow.isMutable());
    try std.testing.expect(!borrow.isShared());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, borrow.slice());

    // Zero-copy proof: mutate through the borrow, observe it from a fresh borrow
    // (same backing store) — no dupe was made.
    const mut = try borrow.sliceMut();
    mut[0] = 9;
    const reborrow = try object.Buffer.borrowBytes(rt, ta);
    try std.testing.expectEqual(@as(u8, 9), reborrow.slice()[0]);
    try std.testing.expectEqual(borrow.ptr, reborrow.ptr); // identical pointer.
}

test "public Buffer borrowBytes carries TypedArray byte offset and length" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const Object = zjs_core.Object;
    const class_ids = zjs_core.class.ids;
    const buffer = try Object.create(rt, class_ids.array_buffer, null);
    const buffer_value = buffer.value();
    defer buffer_value.free(rt);
    const backing = try rt.memory.alloc(u8, 6);
    @memcpy(backing, &[_]u8{ 0, 1, 2, 3, 4, 5 });
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

    const borrow = try object.Buffer.borrowBytes(rt, object.fromCore(view));
    try std.testing.expectEqual(object.Buffer.BorrowKind.typed_array, borrow.kind);
    try std.testing.expectEqual(@as(usize, 2), borrow.byte_offset);
    try std.testing.expectEqual(@as(usize, 4), borrow.len);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 4, 5 }, borrow.slice());
}

test "public Buffer borrowBytes detach is rejected up front" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try JSContext.create(rt);
    defer ctx.destroy();

    const global = try context.globalObject(ctx);
    const ta_val = try object.Buffer.createUint8ArrayFromBytes(rt, global, &.{ 7, 8 });
    defer ta_val.free(rt);
    const ta = object.fromValue(ta_val).?;

    // Take an initial borrow, then detach the backing buffer.
    _ = try object.Buffer.borrowBytes(rt, ta);
    // Detach via the backing ArrayBuffer object.
    const ta_core: *zjs_core.Object = @ptrCast(@alignCast(ta));
    const backing_value = ta_core.typedArrayBuffer().?;
    const backing: *zjs_core.Object = @fieldParentPtr("header", backing_value.refHeader().?);
    backing.detachByteStorage(rt);

    // A fresh borrow after detach must fail (the old ptr is dead).
    try std.testing.expectError(error.TypeError, object.Buffer.borrowBytes(rt, ta));
    try std.testing.expectError(error.TypeError, object.Buffer.checkStillValid(rt, ta));
}

test "public Buffer borrowBytes resize invalidates the old pointer" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const Object = zjs_core.Object;
    const class_ids = zjs_core.class.ids;
    const buffer = try Object.create(rt, class_ids.array_buffer, null);
    const buffer_value = buffer.value();
    defer buffer_value.free(rt);
    const backing = try rt.memory.alloc(u8, 4);
    @memcpy(backing, &[_]u8{ 1, 2, 3, 4 });
    try buffer.installByteStorage(rt, backing);
    // Mark resizable (max_byte_length non-null) so resize is permitted.
    buffer.arrayBufferMaxByteLengthSlot().* = 16;

    const before = try object.Buffer.borrowBytes(rt, object.fromCore(buffer));
    const old_ptr = before.ptr;

    // Resize reallocates the backing store (frees the old allocation).
    _ = try zjs_builtins.buffer.arrayBufferResizeLength(rt, buffer_value, 8);

    // The held borrow now dangles; re-deriving yields a DIFFERENT pointer/length.
    const after = try object.Buffer.checkStillValid(rt, object.fromCore(buffer));
    try std.testing.expect(after.ptr != old_ptr);
    try std.testing.expectEqual(@as(usize, 8), after.len);
}

test "public Buffer borrowBytes immutable ArrayBuffer denies sliceMut" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const Object = zjs_core.Object;
    const class_ids = zjs_core.class.ids;
    const buffer = try Object.create(rt, class_ids.array_buffer, null);
    const buffer_value = buffer.value();
    defer buffer_value.free(rt);
    const backing = try rt.memory.alloc(u8, 3);
    @memcpy(backing, &[_]u8{ 1, 2, 3 });
    try buffer.installByteStorage(rt, backing);
    buffer.arrayBufferImmutableSlot().* = true;

    const borrow = try object.Buffer.borrowBytes(rt, object.fromCore(buffer));
    try std.testing.expect(!borrow.isMutable());
    try std.testing.expectError(error.ReadOnly, borrow.sliceMut());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, borrow.slice());
}

test "public Buffer borrowBytesReadonly carries no mutable pointer" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try JSContext.create(rt);
    defer ctx.destroy();

    const global = try context.globalObject(ctx);
    const ta_val = try object.Buffer.createUint8ArrayFromBytes(rt, global, &.{ 1, 2, 3, 4 });
    defer ta_val.free(rt);
    const ta = object.fromValue(ta_val).?;

    const ro = try object.Buffer.borrowBytesReadonly(rt, ta);
    // The read-only borrow sees the same live bytes as the mutable borrow but has
    // NO write entry point at all (no mut_ptr field, no sliceMut method).
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, ro.slice());
    try std.testing.expectEqual(object.Buffer.BorrowKind.typed_array, ro.kind);
    try std.testing.expect(!ro.isShared());
    comptime {
        if (@hasField(object.Buffer.ReadonlyBorrow, "mut_ptr"))
            @compileError("ReadonlyBorrow must not carry a mut_ptr field");
        if (@hasDecl(object.Buffer.ReadonlyBorrow, "sliceMut"))
            @compileError("ReadonlyBorrow must not expose sliceMut");
    }

    // Detach is still rejected up front (same lifetime contract as borrowBytes).
    object.Buffer.detachBackingBuffer(rt, ta);
    try std.testing.expectError(error.TypeError, object.Buffer.borrowBytesReadonly(rt, ta));
}

test "public Buffer pinForBorrow keeps source alive and releases cleanly" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try JSContext.create(rt);
    defer ctx.destroy();

    const global = try context.globalObject(ctx);
    const ta_val = try object.Buffer.createUint8ArrayFromBytes(rt, global, &.{ 5, 6, 7 });
    defer ta_val.free(rt);
    const ta = object.fromValue(ta_val).?;

    const baseline = rt.persistentRootCountForTest();
    var guard = try object.Buffer.pinForBorrow(rt, ta);
    // The view AND its backing ArrayBuffer are pinned (two distinct objects).
    try std.testing.expect(guard.view_pin != null);
    try std.testing.expect(guard.buffer_pin != null);

    // Borrow + mutate under the pin; mutation is visible (live store).
    const borrow = try object.Buffer.borrowBytes(rt, ta);
    (try borrow.sliceMut())[1] = 99;
    const reborrow = try object.Buffer.borrowBytes(rt, ta);
    try std.testing.expectEqual(@as(u8, 99), reborrow.slice()[1]);

    guard.release();
    guard.release(); // idempotent.
    // Pins released: no leaked persistent roots from the borrow scope.
    try std.testing.expectEqual(baseline, rt.persistentRootCountForTest());
}

pub const context = struct {
    pub const Options = zjs_binding.ContextOptions;
    pub const EvalMode = zjs_binding.EvalMode;
    pub const EvalOptions = zjs_binding.EvalOptions;
    pub const EvalTiming = zjs_binding.EvalTiming;
    pub const DataPropertyOptions = zjs_binding.DataPropertyOptions;
    pub const PropertyAccessOptions = zjs_binding.PropertyAccessOptions;
    pub const PropertyDescriptor = zjs_binding.PropertyDescriptor;
    pub const ErrorOptions = zjs_binding.ErrorOptions;
    pub const ScriptEvalOptions = zjs_binding.ScriptEvalOptions;
    pub const FunctionCallOptions = struct {
        this_value: ?value.Value = null,
        output: ?*std.Io.Writer = null,
        realm_global: ?*object.Object = null,
    };

    pub fn globalObject(ctx: *JSContext) !*object.Object {
        return object.fromCore(try ctx.globalObject());
    }

    pub fn callFunction(
        ctx: *JSContext,
        callee: value.Value,
        args: []const value.Value,
        options: @This().FunctionCallOptions,
    ) !value.Value {
        return ctx.callFunction(callee, args, .{
            .this_value = options.this_value,
            .output = options.output,
            .realm_global = object.optionalToCore(options.realm_global),
        });
    }
};

pub const module = struct {
    const module_graph = @import("exec/module_graph.zig");
    pub const Key = module_graph.HostHooks.ResolvedModule;
    pub const Source = module_graph.HostHooks.LoadedModule;
    pub const Host = module_graph.HostHooks;
    pub const ResolveResult = module_graph.HostHooks.ResolvedModule;
    pub const LoadResult = module_graph.HostHooks.LoadedModule;

    pub fn evalFileGraphWithHost(
        ctx: *JSContext,
        source_text: []const u8,
        output: *std.Io.Writer,
        filename: []const u8,
        host_hooks: Host,
        allocator: std.mem.Allocator,
    ) !value.Value {
        return module_graph.evalFileModuleGraphWithHostHooks(ctx.runtimePtr(), &ctx.core, source_text, output, filename, host_hooks, allocator);
    }

    fn moduleResolutionError(err: anyerror) anyerror {
        return switch (err) {
            error.ModuleNotFound => error.ModuleNotFound,
            error.PermissionDenied => error.PermissionDenied,
            else => err,
        };
    }
};

pub const compile = struct {
    pub const SourceKind = module.Host.ModuleKind;
    pub const Options = struct {};
    pub const Cache = struct {};
};

pub const @"error" = struct {
    pub const Info = struct {
        message: []const u8,
        stack: ?[]const u8 = null,
        path: ?[]const u8 = null,
        line: ?u32 = null,
        column: ?u32 = null,
        kind: Kind = .runtime,
    };
    pub const Kind = enum {
        syntax,
        reference,
        type,
        range,
        uri,
        eval,
        runtime,
    };
    pub const Span = struct {
        start: usize,
        end: usize,
    };
};

pub const job = struct {
    pub const DrainOptions = struct {
        budget: ?usize = null,
    };
    pub const DrainResult = struct {
        jobs_drained: usize,
        has_more: bool,
    };

    pub fn drain(ctx: *JSContext, options: DrainOptions) !DrainResult {
        _ = options;
        const had_work = ctx.peekPendingPromiseJobSequence() != null;
        try ctx.runJobs(null);
        return DrainResult{
            .jobs_drained = if (had_work) 1 else 0,
            .has_more = ctx.peekPendingPromiseJobSequence() != null,
        };
    }
};

test {
    _ = zjs_binding;
    _ = runtime;
}

test "public root exposes only the explicit runtime surface" {
    try std.testing.expect(!@hasDecl(@This(), "internal"));
    try std.testing.expect(!@hasDecl(@This(), "core"));
    try std.testing.expect(!@hasDecl(@This(), "exec"));
    try std.testing.expect(!@hasDecl(@This(), "kernel"));
    try std.testing.expect(!@hasDecl(@This(), "low"));
    try std.testing.expect(!@hasDecl(@This(), "ContextOptions"));
    try std.testing.expect(!@hasDecl(@This(), "EvalOptions"));
    try std.testing.expect(!@hasDecl(@This(), "EvalMode"));
    try std.testing.expect(!@hasDecl(@This(), "EvalTiming"));
    try std.testing.expect(!@hasDecl(@This(), "ScriptEvalOptions"));

    try std.testing.expect(@hasDecl(runtime, "EventLoop"));
    try std.testing.expect(@hasDecl(runtime, "EventLoopOptions"));
    try std.testing.expect(@hasDecl(runtime, "EventLoopRunResult"));
    try std.testing.expect(@hasDecl(runtime, "runUntilIdle"));
    try std.testing.expect(@hasDecl(runtime, "cleanupAtomicsWaitersForContext"));
    try std.testing.expect(@hasDecl(runtime, "wakeAtomicsWaitersForRuntimes"));
    try std.testing.expect(@hasDecl(runtime, "detachArrayBuffer"));
    try std.testing.expect(@hasDecl(runtime, "evalFileModuleGraphWithOutput"));
    try std.testing.expect(@hasDecl(runtime, "resolveModuleSpecifier"));
    try std.testing.expect(@hasDecl(runtime, "Plugin"));
    try std.testing.expect(@hasDecl(runtime, "PluginInstallOptions"));
    try std.testing.expect(@typeInfo(object.Object) == .@"opaque");
    try std.testing.expect(!@hasDecl(object.Object, "value"));
    try std.testing.expect(!@hasDecl(@This(), "JSValueHandle"));
    try std.testing.expect(!@hasDecl(@This(), "LocalHandle"));
    try std.testing.expect(!@hasDecl(@This(), "HandleScope"));
    try std.testing.expect(!@hasDecl(@This(), "WeakPersistent"));
    try std.testing.expect(!@hasDecl(@This(), "WeakPersistentValue"));
    try std.testing.expect(!@hasDecl(@This(), "DataPropertyOptions"));
    try std.testing.expect(!@hasDecl(@This(), "PropertyAccessOptions"));
    try std.testing.expect(!@hasDecl(@This(), "PropertyDescriptor"));
    try std.testing.expect(!@hasDecl(@This(), "ExternalFunctionOptions"));
    try std.testing.expect(!@hasDecl(@This(), "FunctionCallOptions"));
    try std.testing.expect(!@hasDecl(@This(), "ErrorOptions"));
    try std.testing.expect(!@hasDecl(@This(), "SharedArrayBufferRef"));
    try std.testing.expect(!@hasDecl(@This(), "ExternalHostCall"));
    try std.testing.expect(!@hasDecl(@This(), "ExternalHostCallFn"));
    try std.testing.expect(!@hasDecl(@This(), "ExternalHostFinalizer"));
    try std.testing.expect(!@hasDecl(@This(), "PropNameID"));
    try std.testing.expect(!@hasDecl(@This(), "JSString"));
    try std.testing.expect(!@hasDecl(@This(), "JSBytes"));
    try std.testing.expect(!@hasDecl(@This(), "binding"));

    try std.testing.expect(!@hasDecl(runtime, "event_loop"));
    try std.testing.expect(!@hasDecl(runtime, "plugin"));
    try std.testing.expect(!@hasDecl(runtime, "modules"));
    try std.testing.expect(!@hasDecl(runtime, "cleanup"));
    try std.testing.expect(!@hasDecl(runtime, "buffer"));
    try std.testing.expect(!@hasDecl(runtime, "Engine"));
    try std.testing.expect(!@hasDecl(runtime, "BorrowedValue"));
    try std.testing.expect(!@hasDecl(runtime, "OwnedValue"));
    try std.testing.expect(!@hasDecl(object, "Kind"));
}
