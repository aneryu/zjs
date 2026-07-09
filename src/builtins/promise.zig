//! Promise builtins surface.
//!
//! The engine-core construction primitives (constructWithPrototype,
//! fulfilled/rejectedWithPrototype, markHandled, enqueueReaction, the legacy
//! Promise.* static helpers, withResolvers) now live in `core/promise.zig`
//! (QuickJS keeps these in the engine core, and they carry zero exec/builtins
//! dependency). This module re-exports them for the builtins install/registry
//! paths and keeps the name->id mapping used during global installation.

const core = @import("../core/root.zig");
const promise_ops = @import("../exec/promise_ops.zig");

const core_promise = core.promise;

pub const LegacyStaticMethod = promise_ops.LegacyStaticMethod;
pub const legacyStaticMethodId = promise_ops.legacyStaticMethodId;

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
