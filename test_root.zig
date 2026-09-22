//! Engine Zig-test root. This file sits at the repository root so one
//! module can see both `src/` unit tests and `tests/` integration tests.
//! Production CLI and embedders still compile `src/root.zig`.
const src = @import("src/root.zig");

pub const native = src.native;
pub const platform_clock = src.platform_clock;
pub const core = src.core;
pub const sort_erased = src.sort_erased;
pub const parser = src.parser;
pub const simple_token = src.simple_token;
pub const bytecode = src.bytecode;
pub const exec = src.exec;
pub const libs = src.libs;
pub const runtime = src.runtime;
pub const compiler = src.compiler;
pub const test262_host = @import("test262_host");

pub const Runtime = src.Runtime;
pub const Context = src.Context;
pub const Value = src.Value;
pub const Call = src.Call;
pub const EventLoop = src.EventLoop;

pub const GCStats = src.GCStats;
pub const GCDetailedStats = src.GCDetailedStats;
pub const GCPauseDistribution = src.GCPauseDistribution;
pub const RuntimeOptions = src.RuntimeOptions;
pub const MicrotaskPolicy = src.MicrotaskPolicy;
pub const MicrotaskScope = src.MicrotaskScope;
pub const MicrotaskExceptionHandler = src.MicrotaskExceptionHandler;
pub const RuntimeMemoryUsage = src.RuntimeMemoryUsage;
pub const OpcodeProfile = src.OpcodeProfile;
pub const default_stack_size = src.default_stack_size;
pub const default_gc_threshold = src.default_gc_threshold;
pub const opcode_profile_build_enabled = src.opcode_profile_build_enabled;
pub const activateOpcodeProfile = src.activateOpcodeProfile;

pub const RuntimeError = src.RuntimeError;
pub const HostError = src.HostError;
pub const JSRuntime = src.JSRuntime;
pub const JSContext = src.JSContext;
pub const borrowContext = src.borrowContext;
pub const globalObjectPtr = src.globalObjectPtr;
pub const JSValue = src.JSValue;
pub const Object = src.Object;
pub const Descriptor = src.Descriptor;
pub const Atom = src.Atom;
pub const JSValueHandle = src.JSValueHandle;
pub const LocalHandle = src.LocalHandle;
pub const HandleScope = src.HandleScope;
pub const WeakPersistent = src.WeakPersistent;
pub const WeakPersistentValue = src.WeakPersistentValue;
pub const NativePin = src.NativePin;
pub const JSString = src.JSString;
pub const JSBytes = src.JSBytes;
pub const SharedArrayBufferRef = src.SharedArrayBufferRef;
pub const GCPolicy = src.GCPolicy;
pub const EvalOptions = src.EvalOptions;
pub const EvalTiming = src.EvalTiming;
pub const DataPropertyOptions = src.DataPropertyOptions;
pub const printSmallInlineProbe = src.printSmallInlineProbe;

test {
    _ = src;
    if (@import("build_options").zjs_unified_test_suite) {
        // File-imports from the test root are what Zig 0.16 collects.
        // Integration suites live under tests/; package unit suites are
        // also pulled here so `--test-filter` can see them.
        _ = @import("tests/engine.zig");
        _ = @import("src/compiler/tests.zig");
        _ = @import("src/parser/tests.zig");
        _ = @import("src/bytecode/tests.zig");
        _ = @import("src/libs/number_format.zig");
        _ = @import("src/libs/unicode.zig");
    }
}
