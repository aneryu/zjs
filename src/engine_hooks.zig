//! Fixed internal hooks for one engine module.
//!
//! Build code wires this file back onto the same module that compiles
//! `src/root.zig` or `test_root.zig`. Core reaches it as `@import("engine_hooks")`
//! and does not import exec. The import inside `JSRuntime` initialization is
//! deferred to that function so this file can name `engine.core` while core is
//! still loading.

const engine = @import("zjs");

const hooks: engine.core.runtime.EngineHooks = .{
    .run_microtask = engine.exec.promise_ops.runRuntimeMicrotask,
    .install_standard_globals = engine.exec.standard_globals.installStandardGlobals,
    .materialize_builtin_namespace = engine.exec.standard_globals.materializeBuiltinNamespace,
    .materialize_context_global = engine.exec.zjs_vm.contextGlobal,
    .internal_builtins = &engine.exec.standard_globals.internal_builtins.table,
    .standard_global_own_property_capacity = engine.exec.standard_globals.standardGlobalOwnPropertyCapacity(),
};

pub fn get() *const engine.core.runtime.EngineHooks {
    return &hooks;
}
