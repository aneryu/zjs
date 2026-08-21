const std = @import("std");

const internal = @import("internal_root.zig");

pub const public_api = internal.public_api;
pub const binding_root = internal.binding_root;
pub const platform_clock = internal.platform_clock;
pub const core = internal.core;
pub const parser = internal.parser;
pub const simple_token = internal.simple_token;
pub const bytecode = internal.bytecode;
pub const exec = internal.exec;
pub const libs = internal.libs;
pub const runtime = internal.runtime;
pub const compiler = internal.compiler;
pub const config_signature = internal.config_signature;
pub const printSmallInlineProbe = internal.printSmallInlineProbe;

pub const RuntimeError = internal.RuntimeError;
pub const HostError = internal.HostError;
pub const JSRuntime = internal.JSRuntime;
pub const JSContext = internal.JSContext;
pub const JSValue = internal.JSValue;
pub const Descriptor = internal.Descriptor;
pub const Atom = internal.Atom;
pub const JSValueHandle = internal.JSValueHandle;
pub const LocalHandle = internal.LocalHandle;
pub const HandleScope = internal.HandleScope;
pub const WeakPersistent = internal.WeakPersistent;
pub const WeakPersistentValue = internal.WeakPersistentValue;
pub const NativePin = internal.NativePin;
pub const RuntimeMemoryUsage = internal.RuntimeMemoryUsage;
pub const PropNameID = internal.PropNameID;
pub const JSString = internal.JSString;
pub const JSBytes = internal.JSBytes;
pub const binding = internal.binding;
pub const ffi = internal.ffi;
pub const GCPolicy = internal.GCPolicy;
pub const GCStats = internal.GCStats;
pub const EvalOptions = internal.EvalOptions;
pub const EvalTiming = internal.EvalTiming;
pub const DataPropertyOptions = internal.DataPropertyOptions;
pub const ExternalFunctionOptions = internal.ExternalFunctionOptions;
pub const ExternalHostCall = internal.ExternalHostCall;
pub const ExternalHostCallFn = internal.ExternalHostCallFn;
pub const ExternalHostFinalizer = internal.ExternalHostFinalizer;

// PUBLIC-SURFACE MIRROR: names that exist only on the unified root, or that
// intentionally disagree with internal_root (see the exception table below).
pub const Object = internal.public_api.object.Object;
pub const RuntimeOptions = internal.public_api.RuntimeOptions;
pub const ContextOptions = internal.public_api.context.Options;
pub const EvalMode = internal.public_api.context.EvalMode;
pub const PropertyAccessOptions = internal.public_api.context.PropertyAccessOptions;
pub const PropertyDescriptor = internal.public_api.context.PropertyDescriptor;
pub const FunctionCallOptions = internal.public_api.context.FunctionCallOptions;
pub const ErrorOptions = internal.public_api.context.ErrorOptions;
pub const ScriptEvalOptions = internal.public_api.context.ScriptEvalOptions;
pub const SharedArrayBufferRef = internal.public_api.object.SharedArrayBufferRef;
pub const OpcodeProfile = internal.public_api.OpcodeProfile;
pub const default_stack_size = internal.public_api.default_stack_size;
pub const default_gc_threshold = internal.public_api.default_gc_threshold;
pub const activateOpcodeProfile = internal.public_api.activateOpcodeProfile;
pub const value = internal.public_api.value;
pub const host = internal.public_api.host;
pub const object = internal.public_api.object;
pub const context = internal.public_api.context;
pub const module = internal.public_api.module;
pub const job = internal.public_api.job;

// QCP-1: the unified suite proves its OWN effective configuration at compile
// time. It follows -Doptimize, so `zig build test` reports `optimize=Debug`
// and `zig build test -Doptimize=ReleaseSafe` reports `optimize=ReleaseSafe` --
// the distinction that decides whether the run had the assert oracle at all.
comptime {
    config_signature.attest("unified-tests (src/all_tests.zig)");
}

fn refAllDeclsRecursive(comptime Container: type, comptime visited: anytype) void {
    @setEvalBranchQuota(200000);
    if (!@import("builtin").is_test) return;

    // Avoid infinite recursion on cycles
    inline for (visited) |V| {
        if (V == Container) return;
    }

    const new_visited = visited ++ .{Container};

    inline for (comptime std.meta.declarations(Container)) |decl| {
        _ = &@field(Container, decl.name);
        const DeclType = @TypeOf(@field(Container, decl.name));
        switch (@typeInfo(DeclType)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => {
                refAllDeclsRecursive(DeclType, new_visited);
            },
            .type => {
                const T = @field(Container, decl.name);
                switch (@typeInfo(T)) {
                    .@"struct", .@"union", .@"enum", .@"opaque" => {
                        refAllDeclsRecursive(T, new_visited);
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

/// Names on both roots that are allowed to be different types. Start with
/// Object; any other identity failure found in implementation is recorded
/// here with its cause rather than forced onto the internal spelling.
const internal_decl_exceptions = [_][]const u8{
    "Object", // public Object is an opaque facade; internal Object has create
};

fn isInternalDeclException(comptime name: []const u8) bool {
    inline for (internal_decl_exceptions) |exception| {
        if (std.mem.eql(u8, exception, name)) return true;
    }
    return false;
}

test "all_tests is a superset of internal_root" {
    const all = @This();
    inline for (@typeInfo(internal).@"struct".decls) |decl| {
        try std.testing.expect(@hasDecl(all, decl.name));
        if (comptime isInternalDeclException(decl.name)) {
            try std.testing.expect(@TypeOf(@field(all, decl.name)) != @TypeOf(@field(internal, decl.name)) or
                @field(all, decl.name) != @field(internal, decl.name));
        } else {
            try std.testing.expect(@field(all, decl.name) == @field(internal, decl.name));
        }
    }
}

test {
    refAllDeclsRecursive(internal.public_api, .{});
    std.testing.refAllDecls(@import("tests/engine_production.zig"));
    std.testing.refAllDecls(@import("tests/oom_cap.zig"));
    std.testing.refAllDecls(@import("tests/embedding_examples.zig"));
    std.testing.refAllDecls(@import("tests/core.zig"));
    std.testing.refAllDecls(@import("tests/bytecode.zig"));
    std.testing.refAllDecls(@import("tests/parser.zig"));
    std.testing.refAllDecls(@import("tests/exec.zig"));
    std.testing.refAllDecls(@import("tests/builtins.zig"));
    std.testing.refAllDecls(runtime);

    // Relative imports for files that are not module roots
    std.testing.refAllDecls(@import("tests/gc_stress.zig"));
    std.testing.refAllDecls(@import("cli/zjs.zig"));
    std.testing.refAllDecls(@import("cli/run_test262.zig"));
}
