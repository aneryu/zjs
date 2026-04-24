const exception = @import("exception.zig");
const Runtime = @import("runtime.zig").Runtime;
const Value = @import("value.zig").Value;

pub const Context = struct {
    runtime: *Runtime,
    exception_slot: exception.ExceptionSlot = .{},
    stack_limit: usize = 0,
    class_prototypes: []Value = &.{},

    /// Returns an owned context. Caller must release it with `destroy`.
    pub fn create(rt: *Runtime) !*Context {
        const ctx = try rt.memory.create(Context);
        errdefer rt.memory.destroy(Context, ctx);
        const prototypes = try rt.memory.alloc(Value, rt.classes.records.len);
        errdefer rt.memory.free(Value, prototypes);
        ctx.* = .{
            .runtime = rt,
            .stack_limit = rt.stackSize(),
            .class_prototypes = prototypes,
        };
        @memset(ctx.class_prototypes, Value.nullValue());
        return ctx;
    }

    pub fn destroy(self: *Context) void {
        const rt = self.runtime;
        self.exception_slot.clear(rt);
        for (self.class_prototypes) |value| value.free(rt);
        if (self.class_prototypes.len != 0) rt.memory.free(Value, self.class_prototypes);
        rt.memory.destroy(Context, self);
    }

    pub fn throwValue(self: *Context, value: Value) Value {
        self.exception_slot.set(self.runtime, value);
        return Value.exception();
    }

    pub fn hasException(self: Context) bool {
        return self.exception_slot.hasException();
    }

    pub fn takeException(self: *Context) Value {
        return self.exception_slot.take();
    }

    pub fn clearException(self: *Context) void {
        self.exception_slot.clear(self.runtime);
    }

    pub fn classPrototypeSlotCount(self: Context) usize {
        return self.class_prototypes.len;
    }
};
