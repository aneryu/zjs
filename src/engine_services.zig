//! Fixed execution services for the engine compiled in this module.
//!
//! This is a source-level core/exec boundary, not a pluggable backend or a
//! Runtime resource. No installation, factory, mutable registry, or per-runtime
//! copy is needed. Context owns bootstrap transactions; jobs owns checkpoints.

const runtime = @import("runtime.zig");
const context = @import("core/context.zig");
const object = @import("core/object.zig");
const property = @import("core/property.zig");
const value = @import("core/value.zig");
const errors = @import("core/errors.zig");
const jobs = @import("core/jobs.zig");
const native_entry = @import("core/native_entry.zig");
const standard_globals = @import("exec/standard_globals.zig");
const vm = @import("exec/zjs_vm.zig");
const promises = @import("exec/promise_ops.zig");
const builtins = @import("exec/internal_builtins.zig");

// Preserve the former bootstrap callback error contracts. Callers retain
// their existing RuntimeError conversion and transaction rollback boundaries.
pub fn installStandardGlobals(ctx: *context.JSContext, global: *object.Object) anyerror!void {
    return standard_globals.installStandardGlobals(ctx, global);
}

pub fn materializeContextGlobal(ctx: *context.JSContext) anyerror!*object.Object {
    return vm.contextGlobal(ctx);
}

pub fn materializeBuiltinNamespace(rt: *runtime.JSRuntime, global: *object.Object, kind: property.AutoInitKind) anyerror!?value.JSValue {
    return standard_globals.materializeBuiltinNamespace(rt, global, kind);
}

pub fn runMicrotask(rt: *runtime.JSRuntime) errors.HostError!jobs.RunOneStatus {
    return promises.runRuntimeMicrotask(rt);
}

/// Records have static lifetime in this engine module, even before a Realm
/// exists. Host-domain, gap and out-of-range ids retain their null result.
pub fn internalBuiltinRecord(domain_index: usize, id: u32) ?*const native_entry.NativeEntry {
    if (domain_index >= builtins.table.len) return null;
    return builtins.table[domain_index].get(id);
}

pub fn standardGlobalOwnPropertyCapacity() usize {
    return standard_globals.standardGlobalOwnPropertyCapacity();
}
