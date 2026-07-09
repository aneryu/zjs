//! Transitional compatibility shim. Reflect/Proxy native records and
//! JS-visible method bodies live in `exec/reflect_proxy_ops.zig`.

const reflect_proxy_ops = @import("../exec/reflect_proxy_ops.zig");

pub const StaticMethod = reflect_proxy_ops.StaticMethod;
pub const internal_entries = reflect_proxy_ops.internal_entries;
pub const RevocableProxy = reflect_proxy_ops.RevocableProxy;

pub const methodId = reflect_proxy_ops.methodId;
pub const ownKeys = reflect_proxy_ops.ownKeys;
