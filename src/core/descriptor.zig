//! ECMAScript property descriptors at the Object internal-method boundary.
//!
//! Descriptors borrow their JSValue fields; tracing keeps the referenced heap
//! values alive. Presence bits distinguish absent from explicit `undefined`,
//! matching QuickJS `JSPropertyDescriptor` near quickjs.c:1014. This compact
//! core value type may be imported by higher layers but depends only on core
//! property/value representations.

const property = @import("property.zig");
const JSValue = @import("value.zig").JSValue;

pub const Kind = enum {
    generic,
    data,
    accessor,
};

pub const Descriptor = struct {
    kind: Kind = .generic,
    value: JSValue = JSValue.undefinedValue(),
    value_present: bool = false,
    getter: JSValue = JSValue.undefinedValue(),
    getter_present: bool = false,
    setter: JSValue = JSValue.undefinedValue(),
    setter_present: bool = false,
    writable: ?bool = null,
    enumerable: ?bool = null,
    configurable: ?bool = null,

    pub fn data(value: JSValue, writable: bool, enumerable: bool, configurable: bool) Descriptor {
        return .{
            .kind = .data,
            .value = value,
            .value_present = true,
            .writable = writable,
            .enumerable = enumerable,
            .configurable = configurable,
        };
    }

    pub fn accessor(getter: JSValue, setter: JSValue, enumerable: bool, configurable: bool) Descriptor {
        return .{
            .kind = .accessor,
            .getter = getter,
            .getter_present = true,
            .setter = setter,
            .setter_present = true,
            .enumerable = enumerable,
            .configurable = configurable,
        };
    }

    pub fn generic(enumerable: ?bool, configurable: ?bool) Descriptor {
        return .{
            .kind = .generic,
            .enumerable = enumerable,
            .configurable = configurable,
        };
    }

    pub fn fromSlot(flags: property.Flags, slot: property.Slot) Descriptor {
        if (flags.deleted) return .{};
        return switch (flags.kind) {
            .data => .{
                .kind = .data,
                .value = slot.data,
                .value_present = true,
                .writable = flags.writable,
                .enumerable = flags.enumerable,
                .configurable = flags.configurable,
            },
            .accessor => .{
                .kind = .accessor,
                .getter = slot.accessor.getterValue(),
                .getter_present = true,
                .setter = slot.accessor.setterValue(),
                .setter_present = true,
                .enumerable = flags.enumerable,
                .configurable = flags.configurable,
            },
            // JS_PROP_VARREF surfaces as a data descriptor over the cell value
            // (qjs exposes global lexicals via *pr->u.var_ref->pvalue).
            .var_ref => .{
                .kind = .data,
                .value = slot.var_ref.varRefValue(),
                .value_present = true,
                .writable = !slot.var_ref.is_const,
                .enumerable = flags.enumerable,
                .configurable = flags.configurable,
            },
            // Callers must materialize an `.auto_init` slot before
            // converting it to a descriptor (`Object.getOwnProperty`
            // and the like trigger materialization on the slot itself
            // before reaching `fromSlot`). Reaching this arm would
            // mean a `.data`-shaped entry was promised but the slot
            // is still a placeholder.
            .auto_init => unreachable,
        };
    }

    /// Retained as a source-compatible no-op for embedders written against the
    /// former reference-counted descriptor API.
    pub fn destroy(_: Descriptor, _: anytype) void {}
};
