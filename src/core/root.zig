//! Internal aggregation root for the engine's dependency-low core layer.
//!
//! This file re-exports core identities and embedding option types without
//! adding ownership: lifetime contracts remain with their defining modules.
//! It is the sanctioned import surface for exec/runtime/binding and the public
//! facade, while check_deps forbids core implementations from depending back
//! on parser, exec, runtime, binding, builtins, or CLI. QuickJS has no matching
//! translation unit; this is zjs's layer boundary.

pub const subsystem_name = "core_runtime";

const builtin = @import("builtin");

pub const value = @import("value.zig");
pub const value_semantics = @import("value_semantics.zig");
pub const value_format = @import("value_format.zig");
pub const value_string = @import("value_string.zig");
pub const number = @import("number.zig");
pub const list = @import("list.zig");
pub const gc = @import("gc.zig");
/// Slot-under-RC protocol. Default `rc` erases the module so production
/// `.text` does not grow a unused Slot Implementation.
pub const gc_slot = if (builtin.is_test or gc.shadow_tracer_enabled)
    @import("gc_slot.zig")
else
    struct {
        pub const stats_enabled = false;
    };
/// Shadow write audit of Slot-bypassing heap stores. Default `rc` erases the
/// module so production `.text` does not grow observer symbols.
pub const gc_write_audit = if (builtin.is_test or gc.shadow_tracer_enabled)
    @import("gc_write_audit.zig")
else
    struct {
        pub const enabled = false;
        pub fn reset() void {}
        pub fn snapshot() Snapshot {
            return .{};
        }
        pub fn format(_: anytype) !void {}
        pub const Snapshot = struct {
            slot_writes: usize = 0,
            pub fn hits(_: Snapshot) usize {
                return 0;
            }
        };
    };
pub const atom = @import("atom.zig");
pub const string = @import("string.zig");
pub const bigint = @import("bigint.zig");
pub const class = @import("class.zig");
pub const shape = @import("shape.zig");
pub const global_slots = @import("global_slots.zig");
pub const function = @import("function.zig");
pub const function_bytecode = @import("../bytecode.zig").function_bytecode;
pub const module = @import("module.zig");
pub const property = @import("property.zig");
pub const promise = @import("promise.zig");
pub const jobs = @import("jobs.zig");
pub const json = @import("json.zig");
pub const regexp = @import("regexp.zig");
pub const uri = @import("uri.zig");
pub const symbol = @import("symbol.zig");
pub const host_function = @import("host_function.zig");
pub const descriptor = @import("descriptor.zig");
pub const object = @import("object.zig");
pub const var_ref = @import("var_ref.zig");
pub const array = @import("array.zig");
pub const collection = @import("collection.zig");
pub const typed_array = @import("typed_array.zig");
pub const typed_array_names = @import("typed_array_names.zig");
pub const error_names = @import("error_names.zig");
pub const errors = @import("errors.zig");
pub const runtime = @import("runtime.zig");
pub const context = @import("context.zig");
pub const exception = @import("exception.zig");
pub const memory = @import("memory.zig");
pub const profile = @import("profile.zig");
/// Imported only when `-Dzjs_gc=shadow`. Default `rc` builds see an empty
/// namespace so the observer is not part of the production compile.
pub const gc_shadow = if (gc.shadow_tracer_enabled) @import("gc_shadow.zig") else struct {
    pub const enabled = false;
};
/// Live page-radix address registry. Default production `rc` erases the
/// module so the allocation hot path does not grow a registry Implementation.
pub const gc_address_registry = if (gc.address_registry_enabled)
    @import("gc_address_registry.zig")
else
    struct {
        pub const enabled = false;
    };
/// Measured size-class table and publication histogram. Default production
/// `rc` erases the module.
pub const gc_space = if (gc.space_model_enabled)
    @import("gc_space.zig")
else
    struct {
        pub const enabled = false;
    };
/// Logical 64 KiB window sweep machine and four debt quantities. Default
/// production `rc` erases the module.
pub const gc_sweep_model = if (gc.sweep_model_enabled)
    @import("gc_sweep_model.zig")
else
    struct {
        pub const enabled = false;
    };
/// 64 KiB block heap. Default production `rc` and default tests erase it;
/// `-Dzjs_gc=trace_stw` is the only consumer.
pub const gc_block_heap = if (gc.block_heap_enabled)
    @import("gc_block_heap.zig")
else
    struct {
        pub const enabled = false;
    };
/// Imported only when `-Dzjs_gc=trace_stw`. Default `rc` builds see an empty
/// namespace so the reclaiming tracer is not part of the production compile.
pub const gc_trace_stw = if (gc.trace_stw_enabled) @import("gc_trace_stw.zig") else struct {
    pub const enabled = false;
    pub const Report = struct {
        ephemeron_values_shaded: usize = 0,
        census_ns: u64 = 0,
    };
    pub var last_report: Report = .{};
    /// Present so callers need no `comptime` guard; the `rc` build has no
    /// whole-heap census to switch off.
    pub var detailed_reports: bool = false;
};

pub const JSValue = value.JSValue;
pub const JSString = JSValue.String;
pub const JSBytes = JSValue.Bytes;
pub const Tag = value.Tag;
pub const Atom = atom.Atom;
pub const AtomTable = atom.AtomTable;
pub const ClassId = class.ClassId;
pub const Shape = shape.Shape;
pub const FunctionRecord = function.FunctionRecord;
pub const FunctionBytecode = function_bytecode.FunctionBytecode;
pub const ModuleRecord = module.ModuleRecord;
pub const Object = object.Object;
pub const VarRef = var_ref.VarRef;
pub const Descriptor = descriptor.Descriptor;
pub const JSRuntime = runtime.JSRuntime;
pub const VmStackArena = runtime.VmStackArena;
pub const JSContext = context.JSContext;
pub const RealmContext = context.RealmContext;
pub const RealmRef = context.RealmRef;
pub const JSValueHandle = runtime.JSValueHandle;
pub const LocalHandle = runtime.LocalHandle;
pub const HandleScope = runtime.HandleScope;
pub const WeakPersistentCallback = runtime.WeakPersistentCallback;
pub const WeakPersistent = runtime.WeakPersistent;
pub const WeakPersistentValue = runtime.WeakPersistentValue;
pub const NativePin = runtime.NativePin;
pub const RuntimeOptions = runtime.RuntimeOptions;
pub const RuntimeMemoryUsage = runtime.MemoryUsage;
pub const DynamicImportLoader = runtime.DynamicImportLoader;
pub const DynamicImportLoaderScope = runtime.DynamicImportLoaderScope;
pub const DynamicImportCallback = context.DynamicImportCallback;
pub const ContextOptions = context.ContextOptions;
pub const GCPolicy = gc.Policy;
pub const GCStats = gc.Stats;
pub const GCPauseDistribution = gc.PauseDistribution;
pub const EvalMode = context.EvalMode;
pub const EvalOptions = context.ContextEvalOptions;
pub const EvalTiming = context.ContextEvalTiming;
pub const DataPropertyOptions = context.DataPropertyOptions;
pub const PropertyAccessOptions = context.PropertyAccessOptions;
pub const PropertyDescriptor = context.PropertyDescriptor;
pub const ExternalFunctionOptions = context.ExternalFunctionOptions;
pub const FunctionCallOptions = context.FunctionCallOptions;
pub const ErrorOptions = context.ErrorOptions;
pub const ScriptEvalOptions = context.ScriptEvalOptions;
pub const SharedArrayBufferRef = context.SharedArrayBufferRef;
pub const ExternalHostCall = host_function.ExternalCall;
pub const ExternalHostCallFn = host_function.ExternalCallFn;
pub const ExternalHostFinalizer = host_function.ExternalFinalizer;
pub const BacktraceFrame = context.BacktraceFrame;
pub const ActiveBacktraceFrame = context.ActiveBacktraceFrame;
pub const ActiveBacktraceSnapshot = context.ActiveBacktraceSnapshot;
pub const BacktraceLocation = context.BacktraceLocation;
pub const BacktraceLocationResolver = context.BacktraceLocationResolver;
pub const OpcodeProfile = profile.OpcodeProfile;
