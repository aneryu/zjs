//! Promise builtins surface.
//!
//! The engine-core construction primitives (constructWithPrototype,
//! fulfilled/rejectedWithPrototype, markHandled, enqueueReaction, the legacy
//! Promise.* static helpers, withResolvers) now live in `core/promise.zig`
//! (QuickJS keeps these in the engine core, and they carry zero exec/builtins
//! dependency). This module re-exports them for the builtins install/registry
//! paths and keeps the name->id mapping used during global installation.

const core = @import("../core/root.zig");
const std = @import("std");

const core_promise = core.promise;

pub const LegacyStaticMethod = core.host_function.builtin_method_ids.promise.LegacyStaticMethod;

pub fn legacyStaticMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "resolve")) return @intFromEnum(LegacyStaticMethod.resolve);
    if (std.mem.eql(u8, name, "all")) return @intFromEnum(LegacyStaticMethod.all);
    if (std.mem.eql(u8, name, "race")) return @intFromEnum(LegacyStaticMethod.race);
    if (std.mem.eql(u8, name, "reject")) return @intFromEnum(LegacyStaticMethod.reject);
    if (std.mem.eql(u8, name, "allSettled")) return @intFromEnum(LegacyStaticMethod.all_settled);
    if (std.mem.eql(u8, name, "any")) return @intFromEnum(LegacyStaticMethod.any);
    if (std.mem.eql(u8, name, "try")) return @intFromEnum(LegacyStaticMethod.try_);
    if (std.mem.eql(u8, name, "withResolvers")) return @intFromEnum(LegacyStaticMethod.with_resolvers);
    return null;
}

// Engine-core primitives, re-exported from core/promise.zig.
pub const construct = core_promise.construct;
pub const constructWithPrototype = core_promise.constructWithPrototype;
pub const fulfilledWithPrototype = core_promise.fulfilledWithPrototype;
pub const rejectedWithPrototype = core_promise.rejectedWithPrototype;
pub const rejectedWithUnhandledPrototype = core_promise.rejectedWithUnhandledPrototype;
pub const staticCall = core_promise.staticCall;
pub const staticCallWithPrototype = core_promise.staticCallWithPrototype;
pub const markHandled = core_promise.markHandled;
pub const withResolvers = core_promise.withResolvers;
pub const enqueueReaction = core_promise.enqueueReaction;
