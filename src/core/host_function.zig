const std = @import("std");
const Object = @import("object.zig").Object;
const JSValue = @import("value.zig").JSValue;

pub const ids = struct {
    pub const output = 1;
    pub const external_host = 119;
};

pub const ExternalCall = struct {
    ctx: *anyopaque,
    output: ?*std.Io.Writer,
    global: ?*Object,
    func_obj: *Object,
    this_value: JSValue,
    args: []const JSValue,
};

pub const ExternalCallFn = *const fn (ptr: *anyopaque, call: ExternalCall) anyerror!JSValue;
pub const ExternalFinalizer = *const fn (ptr: *anyopaque) void;

pub const ExternalRecord = struct {
    ptr: *anyopaque,
    call: ExternalCallFn,
    finalizer: ?ExternalFinalizer = null,
};
