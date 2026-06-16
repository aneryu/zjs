//! Exec-side selector for the `Reflect.*` static dispatch. Reflect methods are
//! VM-level operations (property interception, proxy traps, internal
//! [[Get]]/[[Set]]/[[Construct]]) implemented by exec ops, so the slow-path
//! dispatcher `call_runtime.qjsReflectCallForNativeRecord` switches on this
//! `StaticMethod` selector without naming `builtins`. The selector itself is a
//! shared id space owned by `core.host_function.builtin_method_ids.reflect`;
//! this module re-exports it so exec depends on core rather than builtins.
//!
//! The record handler that registers the `Reflect.*` statics and the
//! `Proxy.revocable` helper on the runtime table (`reflectCall`,
//! `internal_entries`, `methodId`) stays in `builtins/reflect_proxy.zig`: it is
//! a builtin method body reached through the `rt.internal_builtins` table
//! dispatch (builtins -> exec is the Phase 6 client model), not a VM primitive.

const core = @import("../core/root.zig");

pub const StaticMethod = core.host_function.builtin_method_ids.reflect.StaticMethod;
