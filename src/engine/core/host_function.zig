const std = @import("std");
const Object = @import("object.zig").Object;
const Value = @import("value.zig").Value;

pub const ids = struct {
    pub const output = 1;
    pub const test262_same_value = 2;
    pub const test262_assert = 4;
    pub const test262_not_same_value = 5;
    pub const test262_throws = 6;
    pub const test262_compare_array = 13;
    pub const test262_create_realm = 14;
    pub const test262_detach_array_buffer = 20;
    pub const test262_is_html_dda = 21;
    pub const test262_eval_script = 22;
    pub const test262_agent_start = 31;
    pub const test262_agent_broadcast = 32;
    pub const test262_agent_receive_broadcast = 33;
    pub const test262_agent_report = 34;
    pub const test262_agent_get_report = 35;
    pub const test262_agent_leaving = 36;
    pub const test262_agent_sleep = 37;
    pub const test262_agent_monotonic_now = 38;
    pub const std_gc = 44;
    pub const test262_agent_set_timeout = 110;
    pub const external_host = 119;
};

pub const ExternalCall = struct {
    ctx: *anyopaque,
    output: ?*std.Io.Writer,
    global: ?*Object,
    func_obj: *Object,
    this_value: Value,
    args: []const Value,
};

pub const ExternalCallFn = *const fn (ptr: *anyopaque, call: ExternalCall) anyerror!Value;
pub const ExternalFinalizer = *const fn (ptr: *anyopaque) void;

pub const ExternalRecord = struct {
    ptr: *anyopaque,
    call: ExternalCallFn,
    finalizer: ?ExternalFinalizer = null,
};
