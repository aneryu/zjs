//! Helpers shared by more than one exec integration file.
const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const core = zjs.core;
const helpers = @import("../harness.zig");
const bytecode = zjs.bytecode;
const property_ops = zjs.exec.property_ops;

pub const makeFixture = helpers.makeFixture;
pub const runFixture = helpers.runFixture;
pub const createTailOpcodeFixture = helpers.createTailOpcodeFixture;

pub const InterruptTestState = struct {
    hits: usize = 0,
    stop: bool = false,

    pub fn run(_: *core.JSRuntime, userdata: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(userdata.?));
        self.hits += 1;
        return self.stop;
    }
};

pub const CrossRealmNativeProbe = struct {
    seen_realm: ?*core.RealmContext = null,
    seen_global: ?*core.Object = null,
};

pub fn crossRealmNativeProbe(ptr: *anyopaque, call: core.host_function.ExternalCall) anyerror!core.JSValue {
    const probe: *CrossRealmNativeProbe = @ptrCast(@alignCast(ptr));
    const global = call.realm.global orelse return error.InvalidBuiltinRegistry;
    probe.seen_realm = call.realm;
    probe.seen_global = global;

    const key = try call.realm.runtime.internAtom("__native_realm_mutation");
    try global.defineOwnProperty(
        call.realm.runtime,
        key,
        core.Descriptor.data(core.JSValue.int32(1), .all),
    );
    return error.TypeError;
}

pub fn derivedThisLocalIndex(function: *const bytecode.FunctionBytecode) ?usize {
    for (function.varDefs(), 0..) |vd, idx| {
        if (vd.var_name == core.atom.ids.this_) return idx;
    }
    return null;
}

pub fn globalFunctionBytecode(js: *helpers.TestEngine, name: []const u8) !*const bytecode.FunctionBytecode {
    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const name_atom = try js.runtime.internAtom(name);
    const function_value = try global.getProperty(name_atom);
    const function_object = try property_ops.expectObject(function_value);
    const stored_bytecode = function_object.functionBytecode() orelse return error.InvalidFunctionBytecode;
    return engine.exec.call_runtime.functionBytecodeFromValue(stored_bytecode) orelse error.InvalidFunctionBytecode;
}

pub fn finalOpcodeCount(code: []const u8, wanted: u8) !usize {
    var count: usize = 0;
    var pc: usize = 0;
    while (pc < code.len) {
        const op_id = code[pc];
        const size = bytecode.opcode.sizeOf(op_id);
        if (size == 0 or pc + size > code.len) return error.InvalidFunctionBytecode;
        if (op_id == wanted) count += 1;
        pc += size;
    }
    return count;
}

pub fn expectRejectedPromiseNamedError(
    js: *helpers.TestEngine,
    promise_value: core.JSValue,
    expected_name: []const u8,
    expected_message: []const u8,
) !void {
    const promise = try core.Object.expect(promise_value);
    try std.testing.expect(promise.promiseIsRejected());
    core.promise.markHandled(js.context, promise);
    const reason = promise.promiseResult() orelse return error.TestUnexpectedResult;
    const reason_object = try core.Object.expect(reason);
    const name_atom = try js.runtime.internAtom("name");
    const message_atom = try js.runtime.internAtom("message");
    const name = try reason_object.getProperty(name_atom);
    const message = try reason_object.getProperty(message_atom);
    try helpers.expectStringValueBytes(name, expected_name);
    try helpers.expectStringValueBytes(message, expected_message);
}

pub fn testNativeCallback(
    realm: *core.JSContext,
    comptime name: []const u8,
    comptime body: core.host_function.NativeGenericFn,
) !core.JSValue {
    const entry = try realm.runtime.allocNativeEntry(
        engine.exec.native_legacy.genericEntry(body, 0),
    );
    const function_value = try core.function.nativeFunction(realm, name, 0);
    const function_object = try core.Object.expect(function_value);
    function_object.installNativeEntry(entry);
    return function_value;
}
