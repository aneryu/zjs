//! QCP-1 configuration signature: one canonical, deterministic string naming
//! the six settings the switch ruling makes load-bearing, plus the comptime
//! assertion every engine-bearing artifact runs against it.
//!
//! WHY THIS EXISTS. The defect class it closes is "a gate reports green about
//! a configuration it never ran". `zig build test-altrepr -Dzjs_compiler=v2`
//! spawned a child `zig build` that started from the *defaults*, so it ran the
//! legacy compiler and reported green for v2. Forwarding the option set fixes
//! that one instance; a signature makes the whole class unexpressible, because
//! every artifact can now state which configuration it was compiled for and
//! that statement is checked, at compile time, against the configuration the
//! build graph asked for.
//!
//! THE DESIGN RULE that makes it worth anything: every component below is read
//! from the declaration the ENGINE ITSELF CONSUMES, never from the `-D` string
//! sitting next to it.
//!
//!   * `compiler` is derived from `Parser.dual_compare_enabled` and
//!     `Parser.single_backend_is_v2` — the exact two declarations
//!     `Parser.compile` branches on to pick its backend.
//!   * `layout` is `resolve_labels.default_layout` — the exact comptime
//!     constant `compiler_v2.compileFunctionV2` hands to `resolve_labels.run`
//!     (compiler_v2/root.zig).
//!   * `repr` is `core.value.nan_boxing`, the constant JSValue is laid out
//!     from.
//!   * `optimize` is `builtin.mode` of the module this file was compiled
//!     into — the engine module of the artifact asking. See the note below on
//!     why the optimize mode belongs in a *correctness* signature at all.
//!   * `force_gc` is `core.memory.force_gc_on_allocation_enabled`, the
//!     constant the allocation path is gated on; `ownership_audit` is
//!     `core.atom.ownership_audit_enabled`, the constant the atom table's
//!     quarantine field exists under.
//!
//! A signature recomputed here from `@import("build_options")` would agree
//! with itself even if the compiled code ignored the option, and would attest
//! nothing at all. Because these are the consumed declarations instead, a
//! drift between what build.zig believes and what the compiled code does makes
//! this string differ from the build graph's expectation, and both
//! `zig build config-signature-check` (against the shipped binary) and
//! `attest()` below (at compile time, in every engine-bearing artifact) fail
//! loudly.
//!
//! WHY `optimize` IS A CORRECTNESS COMPONENT, NOT A PERFORMANCE KNOB. A parent
//! build that asks for ReleaseSafe while the child actually builds Debug
//! produces an identical `compiler`/`layout`/`repr` triple and reads as green.
//! But the optimize mode decides whether the Debug and ReleaseSafe oracles
//! exist at all: whether `std.debug.assert` is live, whether safety checks
//! trap, and whether ReleaseFast genuinely strips the validation paths. It is
//! therefore what decides whether a release gate measured a production binary
//! or a safety build. Every artifact reports its OWN mode: a Debug test
//! artifact says `optimize=Debug`, the release candidate says
//! `optimize=ReleaseFast`.
//!
//! ORDER is fixed by `component_order` below, not by any map iteration, so the
//! string is stable across builds, platforms and Zig versions.

const std = @import("std");
const builtin = @import("builtin");

const parser = @import("parser.zig");
const resolve_labels = @import("compiler_v2/resolve_labels.zig");
const core_atom = @import("core/atom.zig");
const core_memory = @import("core/memory.zig");
const core_value = @import("core/value.zig");

/// Bumped when the component set or the encoding changes, so an old
/// expectation can never silently match a new meaning.
///
/// v1 -> v2 added `optimize`. The bump is deliberate rather than cosmetic: a
/// historical `zjs-config-v1:...` string recorded in a report or a dossier
/// named five settings and said nothing about the optimize mode, so it must
/// not be readable as complete proof now that the field set has grown. A v1
/// string handed to `-Dzjs_expect_config` fails on the version component
/// instead of matching a v2 build on its first five fields.
pub const version = "zjs-config-v2";

/// The canonical component order: the ruling's five (compiler, layout, value
/// representation, force-GC, ownership audit) with `optimize` inserted after
/// the representation, next to the other two things that decide what machine
/// code exists.
pub const component_order = [_][]const u8{
    "compiler",
    "layout",
    "repr",
    "optimize",
    "force_gc",
    "ownership_audit",
};

/// Compiler mode, read off the dispatch decision `Parser.compile` makes.
pub const compiler: []const u8 = if (parser.Parser.dual_compare_enabled)
    "dual"
else if (parser.Parser.single_backend_is_v2)
    "v2"
else
    "legacy";

/// Final bytecode layout, read off the constant compiler-v2 lowers with.
pub const layout: []const u8 = @tagName(resolve_labels.default_layout);

/// JSValue representation, read off the constant `core/value.zig` builds from.
pub const repr: []const u8 = if (core_value.nan_boxing) "nan_boxed" else "tagged";

/// Optimize mode of the module this file was compiled into. Read from
/// `builtin.mode` — the mode the compiler actually used — rather than from
/// build.zig's resolved `-Doptimize` option, for the same reason as every
/// other component: an option that never reached the compilation must not be
/// able to describe it.
pub const optimize: []const u8 = @tagName(builtin.mode);

/// Force-GC instrumentation, read off the constant the allocator is gated on.
pub const force_gc: []const u8 = if (core_memory.force_gc_on_allocation_enabled) "on" else "off";

/// Atom-ownership audit tier, read off the constant the atom table carries its
/// quarantine slot under.
pub const ownership_audit: []const u8 = if (core_atom.ownership_audit_enabled) "on" else "off";

/// The component values, in `component_order`.
pub const component_values = [component_order.len][]const u8{
    compiler,
    layout,
    repr,
    optimize,
    force_gc,
    ownership_audit,
};

/// The canonical signature of this artifact's configuration, e.g.
/// `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`.
pub const signature: []const u8 = blk: {
    var out: []const u8 = version;
    var sep: []const u8 = ":";
    for (component_order, component_values) |name, value| {
        out = out ++ sep ++ name ++ "=" ++ value;
        sep = ",";
    }
    break :blk out;
};

/// The configuration this compilation ACTUALLY has, read from the consumption
/// points listed in the file header. Spelled as a function so the assertion
/// below reads as a comparison between two independently produced facts rather
/// than a constant compared against a constant.
pub fn actualEffectiveConfig() []const u8 {
    return signature;
}

/// What the build graph says this artifact's configuration should be:
/// `-Dzjs_expect_config` when the caller supplied one, otherwise build.zig's
/// own belief, with this artifact's optimize mode substituted in either case.
pub const expected_config: []const u8 = @import("build_options").zjs_expect_config;

/// Fail the COMPILATION when the configuration this artifact actually has is
/// not the configuration the build graph requested.
///
/// This is a compile-time assertion on purpose. A runtime check only fires for
/// artifacts someone remembers to run, and only for the code paths a test
/// happens to reach; a drift in the compiler backend or the bytecode layout
/// must not be able to produce a runnable binary at all.
///
/// The message names all four things a reader needs to act: which artifact,
/// what was expected, what is actually compiled, and which fields differ.
pub fn assertExpectedConfig(
    comptime artifact: []const u8,
    comptime actual: []const u8,
    comptime expect: []const u8,
) void {
    comptime {
        if (std.mem.eql(u8, actual, expect)) return;
        @compileError("zjs configuration drift: this artifact is not compiled for the configuration the build graph requested." ++
            "\n  artifact: " ++ artifact ++
            "\n  expected: " ++ expect ++
            "\n  actual:   " ++ actual ++
            "\n  differing fields:" ++ differingFields(actual, expect) ++
            "\n(expected = what build.zig requested, from -Dzjs_expect_config or its own resolved options;" ++
            "\n actual = what this compilation consumes, read from src/config_signature.zig's declarations.)\n");
    }
}

/// The one call every engine-bearing artifact makes:
/// `comptime { config_signature.attest("<artifact>"); }`.
pub fn attest(comptime artifact: []const u8) void {
    assertExpectedConfig(artifact, actualEffectiveConfig(), expected_config);
}

const Parsed = struct {
    version: []const u8,
    names: []const []const u8,
    values: []const []const u8,

    fn find(comptime self: Parsed, comptime name: []const u8) ?[]const u8 {
        for (self.names, self.values) |candidate, value| {
            if (std.mem.eql(u8, candidate, name)) return value;
        }
        return null;
    }
};

/// Split `<version>:<name>=<value>,...` for diagnostics only. Deliberately
/// tolerant: it is handed a string that is already known to be wrong, and a
/// malformed expectation must still produce a readable message.
fn parseSignature(comptime text: []const u8) Parsed {
    comptime {
        @setEvalBranchQuota(10_000);
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse
            return .{ .version = text, .names = &.{}, .values = &.{} };
        var names: []const []const u8 = &.{};
        var values: []const []const u8 = &.{};
        var rest: []const u8 = text[colon + 1 ..];
        while (rest.len != 0) {
            const comma = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
            const field = rest[0..comma];
            const eq = std.mem.indexOfScalar(u8, field, '=') orelse field.len;
            names = names ++ [_][]const u8{field[0..eq]};
            values = values ++ [_][]const u8{if (eq == field.len) "" else field[eq + 1 ..]};
            rest = if (comma == rest.len) "" else rest[comma + 1 ..];
        }
        return .{ .version = text[0..colon], .names = names, .values = values };
    }
}

fn differingFields(comptime actual: []const u8, comptime expect: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000);
        const a = parseSignature(actual);
        const e = parseSignature(expect);
        var out: []const u8 = "";
        if (!std.mem.eql(u8, a.version, e.version)) {
            out = out ++ "\n    version: expected " ++ e.version ++ ", actual " ++ a.version;
        }
        for (a.names, a.values) |name, value| {
            const expected_value = e.find(name) orelse {
                out = out ++ "\n    " ++ name ++ ": expected <field absent>, actual " ++ value;
                continue;
            };
            if (!std.mem.eql(u8, expected_value, value)) {
                out = out ++ "\n    " ++ name ++ ": expected " ++ expected_value ++ ", actual " ++ value;
            }
        }
        for (e.names, e.values) |name, value| {
            if (a.find(name) == null) {
                out = out ++ "\n    " ++ name ++ ": expected " ++ value ++ ", actual <field absent>";
            }
        }
        if (out.len == 0) out = "\n    (none: the strings differ only in spelling or field order)";
        return out;
    }
}

test "config_signature: attests the configuration the build graph requested" {
    // Detection lives in `attest()`, which fails the COMPILATION, so by the
    // time this test runs the two strings are already known to agree. What it
    // still buys: a green test run says, in its own output, which
    // configuration it was green about.
    try std.testing.expectEqualStrings(expected_config, actualEffectiveConfig());
    std.debug.print("\nzjs config signature: {s}\n", .{signature});
}

test "config_signature: is canonical, ordered, and fully populated" {
    try std.testing.expect(std.mem.startsWith(u8, signature, version ++ ":"));
    var it = std.mem.splitScalar(u8, signature[version.len + 1 ..], ',');
    for (component_order) |name| {
        const field = it.next() orelse return error.MissingComponent;
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse return error.MalformedComponent;
        try std.testing.expectEqualStrings(name, field[0..eq]);
        try std.testing.expect(field[eq + 1 ..].len != 0);
    }
    try std.testing.expect(it.next() == null);
}

test "config_signature: the optimize component is this artifact's own mode" {
    // The component that makes a Debug artifact distinguishable from a
    // ReleaseFast one. Reading it from `builtin.mode` here and asserting it
    // against `builtin.mode` would be circular, so assert the property that
    // actually matters: the mode reported is the mode this compilation runs
    // its safety checks under.
    const safety_on = switch (builtin.mode) {
        .Debug, .ReleaseSafe => true,
        .ReleaseFast, .ReleaseSmall => false,
    };
    try std.testing.expectEqual(safety_on, std.debug.runtime_safety);
    try std.testing.expectEqualStrings(@tagName(builtin.mode), optimize);
}

test "config_signature: drift diagnostics name the differing fields" {
    // The failure text is the deliverable of `assertExpectedConfig`, so pin
    // its content here. `assertExpectedConfig` itself cannot be tested by
    // calling it (it is a `@compileError`), but `differingFields` is the part
    // that has to stay readable.
    const wrong_compiler = comptime differingFields(
        "zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=Debug,force_gc=off,ownership_audit=off",
        "zjs-config-v2:compiler=legacy,layout=short,repr=tagged,optimize=Debug,force_gc=off,ownership_audit=off",
    );
    try std.testing.expectEqualStrings("\n    compiler: expected legacy, actual v2", wrong_compiler);

    const wrong_layout_and_mode = comptime differingFields(
        "zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=Debug,force_gc=off,ownership_audit=off",
        "zjs-config-v2:compiler=v2,layout=plain,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off",
    );
    try std.testing.expectEqualStrings(
        "\n    layout: expected plain, actual short" ++
            "\n    optimize: expected ReleaseFast, actual Debug",
        wrong_layout_and_mode,
    );

    const stale_v1 = comptime differingFields(
        "zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=Debug,force_gc=off,ownership_audit=off",
        "zjs-config-v1:compiler=v2,layout=short,repr=tagged,force_gc=off,ownership_audit=off",
    );
    try std.testing.expectEqualStrings(
        "\n    version: expected zjs-config-v1, actual zjs-config-v2" ++
            "\n    optimize: expected <field absent>, actual Debug",
        stale_v1,
    );
}
