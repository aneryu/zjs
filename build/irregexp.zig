//! Static C++ library for the standalone V8 Irregexp interpreter + bytecode
//! compiler. Linked into every engine-bearing module so JS compile/exec can
//! call the C ABI in `vendor/irregexp/zjs_irregexp.h`.
const std = @import("std");

const cxx_flags = [_][]const u8{
    "-std=c++20",
    "-fno-exceptions",
    "-fno-rtti",
    "-DCOMPILING_IRREGEXP_FOR_EXTERNAL_EMBEDDER",
    "-Wno-unused-parameter",
    "-Wno-unused-variable",
    "-Wno-sign-compare",
    "-Wno-missing-field-initializers",
};

const cxx_files = [_][]const u8{
    "vendor/irregexp/RegExpShim.cpp",
    "vendor/irregexp/zjs_irregexp.cpp",
    "vendor/irregexp/imported/regexp-ast.cc",
    "vendor/irregexp/imported/regexp-bytecodes.cc",
    "vendor/irregexp/imported/regexp-bytecode-generator.cc",
    "vendor/irregexp/imported/regexp-bytecode-iterator.cc",
    "vendor/irregexp/imported/regexp-bytecode-peephole.cc",
    "vendor/irregexp/imported/regexp-compiler.cc",
    "vendor/irregexp/imported/regexp-compiler-tonode.cc",
    "vendor/irregexp/imported/regexp-error.cc",
    "vendor/irregexp/imported/regexp-interpreter.cc",
    "vendor/irregexp/imported/regexp-macro-assembler.cc",
    "vendor/irregexp/imported/regexp-parser.cc",
    "vendor/irregexp/imported/regexp-stack.cc",
};

pub const Libs = struct {
    follow: *std.Build.Step.Compile,
    fast: *std.Build.Step.Compile,
    debug: *std.Build.Step.Compile,
};

pub fn addLibraries(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Libs {
    const fast = addLibrary(b, "zjs_irregexp_fast", target, .ReleaseFast);
    const debug = addLibrary(b, "zjs_irregexp_dev", target, .Debug);
    const follow = switch (optimize) {
        .ReleaseFast => fast,
        .Debug => debug,
        else => addLibrary(b, "zjs_irregexp", target, optimize),
    };
    return .{
        .follow = follow,
        .fast = fast,
        .debug = debug,
    };
}

pub fn addLibrary(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const root = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    root.addIncludePath(b.path("vendor"));
    root.addCSourceFiles(.{
        .files = &cxx_files,
        .flags = &cxx_flags,
        .language = .cpp,
    });
    return b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = root,
    });
}

pub fn link(module: *std.Build.Module, lib: *std.Build.Step.Compile) void {
    module.linkLibrary(lib);
    module.link_libcpp = true;
}
