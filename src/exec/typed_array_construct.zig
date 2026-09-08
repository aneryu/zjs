//! ArrayBuffer / SharedArrayBuffer argument-coercing construction primitives.
//!
//! QuickJS source map: the `js_array_buffer_constructor` /
//! `js_shared_array_buffer_constructor` option-reading paths. Unlike the pure
//! view-construction primitives in `core/typed_array.zig`, these read the
//! `maxByteLength` option off a user-supplied options object via a property
//! lookup (`Get(options, "maxByteLength")`), which is spec-observable and the
//! kind of options access that can reach user code, so the conservative
//! placement keeps them one level above core, in exec, on top of the core
//! ArrayBuffer storage primitives. They are reached only through the construct
//! path (`exec/construct.zig`, the `new_array_buffer` / `new_shared_array_buffer`
//! family); `exec/buffer_ops.zig` re-exports them under their original names for
//! the install/test side.

const core = @import("../core/root.zig");

const typed_array_core = core.typed_array;

pub fn arrayBufferConstructArgs(rt: *core.JSRuntime, args: []const core.JSValue, prototype: ?*core.Object) !core.JSValue {
    return bufferConstructArgs(rt, args, prototype, false);
}

pub fn sharedArrayBufferConstructArgs(rt: *core.JSRuntime, args: []const core.JSValue, prototype: ?*core.Object) !core.JSValue {
    return bufferConstructArgs(rt, args, prototype, true);
}

/// Leftover ArrayBuffer / SharedArrayBuffer construct-args walk. The two
/// copies were 505/505 B and 98.6% the same; comptime identity was only
/// the final core constructor. Take `shared` at runtime. Does not fold
/// `createArrayBufferWithPrototype` / `sharedArrayBufferConstructLength`.
noinline fn bufferConstructArgs(
    rt: *core.JSRuntime,
    args: []const core.JSValue,
    prototype: ?*core.Object,
    shared: bool,
) !core.JSValue {
    const byte_length = if (args.len >= 1) try typed_array_core.toIndexUsize(rt, args[0]) else @as(usize, 0);
    var max_byte_length: ?usize = null;
    if (args.len >= 2 and !args[1].isUndefined() and args[1].isObject()) {
        const options = try typed_array_core.expectObject(args[1]);
        const key = core.atom.ids.maxByteLength;
        const max_value = try options.getProperty(key);
        if (!max_value.isUndefined()) {
            const max = try typed_array_core.toIndexUsize(rt, max_value);
            if (max < byte_length) return error.RangeError;
            max_byte_length = max;
        }
    }
    if (shared) {
        return typed_array_core.sharedArrayBufferConstructLength(rt, byte_length, max_byte_length, prototype);
    }
    return typed_array_core.createArrayBufferWithPrototype(rt, byte_length, max_byte_length, prototype);
}
