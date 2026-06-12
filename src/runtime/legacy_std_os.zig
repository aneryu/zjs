//! Legacy qjs:std / qjs:os host globals and OS glue.

const std = @import("std");
const builtin = @import("builtin");

const core = @import("../core/root.zig");
const call = @import("../exec/call.zig");

const HostFunction = call.HostFunction;
const createNamedHostFunctionValue = call.createNamedHostFunctionValue;
const createStdFileValue = call.createStdFileValue;
const defineIntProperty = call.defineIntProperty;
const defineObjectProperty = call.defineObjectProperty;
const defineStringProperty = call.defineStringProperty;

extern "c" fn execve(file: [*:0]const u8, argv: [*:null]?[*:0]u8, envp: [*:null]?[*:0]u8) c_int;

pub fn stdin() *std.c.FILE {
    return @extern(**std.c.FILE, .{ .name = if (builtin.os.tag == .macos) "__stdinp" else "stdin" }).*;
}
pub fn stdout() *std.c.FILE {
    return @extern(**std.c.FILE, .{ .name = if (builtin.os.tag == .macos) "__stdoutp" else "stdout" }).*;
}
pub fn stderr() *std.c.FILE {
    return @extern(**std.c.FILE, .{ .name = if (builtin.os.tag == .macos) "__stderrp" else "stderr" }).*;
}

pub const execvpe = if (builtin.os.tag == .macos) execvpe_mac else execvpe_linux;

const execvpe_linux = if (builtin.os.tag != .macos) struct {
    extern "c" fn execvpe(file: [*:0]const u8, argv: [*:null]?[*:0]u8, envp: [*:null]?[*:0]u8) c_int;
}.execvpe else undefined;

fn execvpe_mac(file: [*:0]const u8, argv: [*:null]?[*:0]u8, envp: [*:null]?[*:0]u8) callconv(.c) c_int {
    const file_span = std.mem.span(file);
    const errno_noent: c_int = @intCast(@intFromEnum(std.posix.E.NOENT));
    const errno_notdir: c_int = @intCast(@intFromEnum(std.posix.E.NOTDIR));
    const errno_acces: c_int = @intCast(@intFromEnum(std.posix.E.ACCES));
    const errno_nametoolong: c_int = @intCast(@intFromEnum(std.posix.E.NAMETOOLONG));

    if (file_span.len == 0) {
        std.c._errno().* = errno_noent;
        return -1;
    }
    if (std.mem.indexOfScalar(u8, file_span, '/') != null) {
        return execve(file, argv, envp);
    }

    const path_env = std.c.getenv("PATH");
    const path = if (path_env) |p| std.mem.span(p) else "/bin:/usr/bin";
    var buf: [4096:0]u8 = undefined;
    var saw_acces = false;
    var saw_nametoolong = false;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) {
            if (file_span.len >= buf.len) {
                saw_nametoolong = true;
                continue;
            }
            @memcpy(buf[0..file_span.len], file_span);
            buf[file_span.len] = 0;
        } else {
            if (dir.len + 1 + file_span.len >= buf.len) {
                saw_nametoolong = true;
                continue;
            }
            @memcpy(buf[0..dir.len], dir);
            buf[dir.len] = '/';
            @memcpy(buf[dir.len + 1 .. dir.len + 1 + file_span.len], file_span);
            buf[dir.len + 1 + file_span.len] = 0;
        }
        _ = execve(&buf, argv, envp);
        const err = std.c._errno().*;
        if (err == errno_acces) {
            saw_acces = true;
            continue;
        }
        if (err == errno_noent or err == errno_notdir) continue;
        return -1;
    }
    std.c._errno().* = if (saw_acces) errno_acces else if (saw_nametoolong) errno_nametoolong else errno_noent;
    return -1;
}

pub fn installLegacyStdOsGlobals(ctx: *core.JSContext) !void {
    const rt = ctx.runtimePtr();
    const global = try ctx.globalObject();

    const std_object = try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.object, null, legacy_std_object_property_count);
    const std_value = std_object.value();
    defer std_value.free(rt);
    try installLegacyStdObject(rt, global, std_object);
    try defineObjectProperty(rt, global, "std", std_value);

    const os_object = try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.object, null, legacy_os_object_property_count);
    const os_value = os_object.value();
    defer os_value.free(rt);
    try installLegacyOsObject(rt, os_object);
    try defineObjectProperty(rt, global, "os", os_value);
}

const legacy_std_object_property_count: usize = 20 + 3 + 1 + 3;
const legacy_os_object_property_count: usize = 41 + 1 + 7 + 10 + 1 + 17;
const legacy_std_error_property_count: usize = 11;

fn installLegacyStdObject(rt: *core.JSRuntime, global: *core.Object, target: *core.Object) !void {
    const functions = [_]struct { name: []const u8, kind: HostFunction }{
        .{ .name = "loadFile", .kind = .std_load_file },
        .{ .name = "writeFile", .kind = .std_write_file },
        .{ .name = "exists", .kind = .std_exists },
        .{ .name = "exit", .kind = .std_exit },
        .{ .name = "getenv", .kind = .std_getenv },
        .{ .name = "setenv", .kind = .std_setenv },
        .{ .name = "unsetenv", .kind = .std_unsetenv },
        .{ .name = "getenviron", .kind = .std_getenviron },
        .{ .name = "gc", .kind = .std_gc },
        .{ .name = "evalScript", .kind = .std_eval_script },
        .{ .name = "loadScript", .kind = .std_load_script },
        .{ .name = "open", .kind = .std_open },
        .{ .name = "fdopen", .kind = .std_fdopen },
        .{ .name = "tmpfile", .kind = .std_tmpfile },
        .{ .name = "popen", .kind = .std_popen },
        .{ .name = "puts", .kind = .std_puts },
        .{ .name = "printf", .kind = .std_printf },
        .{ .name = "sprintf", .kind = .std_sprintf },
        .{ .name = "strerror", .kind = .std_strerror },
        .{ .name = "urlGet", .kind = .std_url_get },
    };
    for (functions) |entry| {
        try defineLegacyHostFunction(rt, target, entry.name, entry.kind);
    }

    try defineIntProperty(rt, target, "SEEK_SET", std.c.SEEK.SET);
    try defineIntProperty(rt, target, "SEEK_CUR", std.c.SEEK.CUR);
    try defineIntProperty(rt, target, "SEEK_END", std.c.SEEK.END);
    try defineLegacyStdErrorObject(rt, target);
    try defineLegacyStdFileValue(rt, global, target, "in", stdin(), false, true);
    try defineLegacyStdFileValue(rt, global, target, "out", stdout(), false, true);
    try defineLegacyStdFileValue(rt, global, target, "err", stderr(), false, true);
}

fn installLegacyOsObject(rt: *core.JSRuntime, target: *core.Object) !void {
    const functions = [_]struct { name: []const u8, kind: HostFunction }{
        .{ .name = "getenv", .kind = .os_getenv },
        .{ .name = "getcwd", .kind = .os_getcwd },
        .{ .name = "chdir", .kind = .os_chdir },
        .{ .name = "remove", .kind = .os_remove },
        .{ .name = "rename", .kind = .os_rename },
        .{ .name = "open", .kind = .os_open },
        .{ .name = "close", .kind = .os_close },
        .{ .name = "read", .kind = .os_read },
        .{ .name = "write", .kind = .os_write },
        .{ .name = "seek", .kind = .os_seek },
        .{ .name = "mkdir", .kind = .os_mkdir },
        .{ .name = "readdir", .kind = .os_readdir },
        .{ .name = "stat", .kind = .os_stat },
        .{ .name = "lstat", .kind = .os_lstat },
        .{ .name = "realpath", .kind = .os_realpath },
        .{ .name = "symlink", .kind = .os_symlink },
        .{ .name = "readlink", .kind = .os_readlink },
        .{ .name = "utimes", .kind = .os_utimes },
        .{ .name = "setTimeout", .kind = .os_set_timeout },
        .{ .name = "clearTimeout", .kind = .os_clear_timeout },
        .{ .name = "setInterval", .kind = .os_set_interval },
        .{ .name = "clearInterval", .kind = .os_clear_interval },
        .{ .name = "exec", .kind = .os_exec },
        .{ .name = "waitpid", .kind = .os_waitpid },
        .{ .name = "getpid", .kind = .os_getpid },
        .{ .name = "pipe", .kind = .os_pipe },
        .{ .name = "kill", .kind = .os_kill },
        .{ .name = "dup", .kind = .os_dup },
        .{ .name = "dup2", .kind = .os_dup2 },
        .{ .name = "isatty", .kind = .os_isatty },
        .{ .name = "ttyGetWinSize", .kind = .os_tty_get_win_size },
        .{ .name = "ttySetRaw", .kind = .os_tty_set_raw },
        .{ .name = "setReadHandler", .kind = .os_set_read_handler },
        .{ .name = "setWriteHandler", .kind = .os_set_write_handler },
        .{ .name = "signal", .kind = .os_signal },
        .{ .name = "cputime", .kind = .os_cputime },
        .{ .name = "exePath", .kind = .os_exe_path },
        .{ .name = "now", .kind = .os_now },
        .{ .name = "sleepAsync", .kind = .os_sleep_async },
        .{ .name = "mkdtemp", .kind = .os_mkdtemp },
        .{ .name = "mkstemp", .kind = .os_mkstemp },
    };
    for (functions) |entry| {
        try defineLegacyHostFunction(rt, target, entry.name, entry.kind);
    }

    try defineStringProperty(rt, target, "platform", builtinPlatformName());
    try defineIntProperty(rt, target, "O_RDONLY", osFlagValue(.{ .ACCMODE = .RDONLY }));
    try defineIntProperty(rt, target, "O_WRONLY", osFlagValue(.{ .ACCMODE = .WRONLY }));
    try defineIntProperty(rt, target, "O_RDWR", osFlagValue(.{ .ACCMODE = .RDWR }));
    try defineIntProperty(rt, target, "O_APPEND", osFlagValue(.{ .APPEND = true }));
    try defineIntProperty(rt, target, "O_CREAT", osFlagValue(.{ .CREAT = true }));
    try defineIntProperty(rt, target, "O_EXCL", osFlagValue(.{ .EXCL = true }));
    try defineIntProperty(rt, target, "O_TRUNC", osFlagValue(.{ .TRUNC = true }));
    try defineIntProperty(rt, target, "S_IFMT", std.c.S.IFMT);
    try defineIntProperty(rt, target, "S_IFIFO", std.c.S.IFIFO);
    try defineIntProperty(rt, target, "S_IFCHR", std.c.S.IFCHR);
    try defineIntProperty(rt, target, "S_IFDIR", std.c.S.IFDIR);
    try defineIntProperty(rt, target, "S_IFBLK", std.c.S.IFBLK);
    try defineIntProperty(rt, target, "S_IFREG", std.c.S.IFREG);
    try defineIntProperty(rt, target, "S_IFSOCK", std.c.S.IFSOCK);
    try defineIntProperty(rt, target, "S_IFLNK", std.c.S.IFLNK);
    try defineIntProperty(rt, target, "S_ISGID", std.c.S.ISGID);
    try defineIntProperty(rt, target, "S_ISUID", std.c.S.ISUID);
    try defineIntProperty(rt, target, "WNOHANG", std.c.W.NOHANG);
    try defineIntProperty(rt, target, "SIGINT", @intFromEnum(std.c.SIG.INT));
    try defineIntProperty(rt, target, "SIGABRT", @intFromEnum(std.c.SIG.ABRT));
    try defineIntProperty(rt, target, "SIGFPE", @intFromEnum(std.c.SIG.FPE));
    try defineIntProperty(rt, target, "SIGILL", @intFromEnum(std.c.SIG.ILL));
    try defineIntProperty(rt, target, "SIGSEGV", @intFromEnum(std.c.SIG.SEGV));
    try defineIntProperty(rt, target, "SIGTERM", @intFromEnum(std.c.SIG.TERM));
    try defineIntProperty(rt, target, "SIGQUIT", @intFromEnum(std.c.SIG.QUIT));
    try defineIntProperty(rt, target, "SIGPIPE", @intFromEnum(std.c.SIG.PIPE));
    try defineIntProperty(rt, target, "SIGALRM", @intFromEnum(std.c.SIG.ALRM));
    try defineIntProperty(rt, target, "SIGUSR1", @intFromEnum(std.c.SIG.USR1));
    try defineIntProperty(rt, target, "SIGUSR2", @intFromEnum(std.c.SIG.USR2));
    try defineIntProperty(rt, target, "SIGCHLD", @intFromEnum(std.c.SIG.CHLD));
    try defineIntProperty(rt, target, "SIGCONT", @intFromEnum(std.c.SIG.CONT));
    try defineIntProperty(rt, target, "SIGSTOP", @intFromEnum(std.c.SIG.STOP));
    try defineIntProperty(rt, target, "SIGTSTP", @intFromEnum(std.c.SIG.TSTP));
    try defineIntProperty(rt, target, "SIGTTIN", @intFromEnum(std.c.SIG.TTIN));
    try defineIntProperty(rt, target, "SIGTTOU", @intFromEnum(std.c.SIG.TTOU));
}

fn defineLegacyHostFunction(rt: *core.JSRuntime, target: *core.Object, name: []const u8, kind: HostFunction) !void {
    const function_value = try createNamedHostFunctionValue(rt, name, kind);
    defer function_value.free(rt);
    try defineObjectProperty(rt, target, name, function_value);
}

fn defineLegacyStdErrorObject(rt: *core.JSRuntime, target: *core.Object) !void {
    const object = try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.object, null, legacy_std_error_property_count);
    const object_value = object.value();
    defer object_value.free(rt);

    try defineIntProperty(rt, object, "EINVAL", @intFromEnum(std.posix.E.INVAL));
    try defineIntProperty(rt, object, "EIO", @intFromEnum(std.posix.E.IO));
    try defineIntProperty(rt, object, "EACCES", @intFromEnum(std.posix.E.ACCES));
    try defineIntProperty(rt, object, "EEXIST", @intFromEnum(std.posix.E.EXIST));
    try defineIntProperty(rt, object, "ENOSPC", @intFromEnum(std.posix.E.NOSPC));
    try defineIntProperty(rt, object, "ENOSYS", @intFromEnum(std.posix.E.NOSYS));
    try defineIntProperty(rt, object, "EBUSY", @intFromEnum(std.posix.E.BUSY));
    try defineIntProperty(rt, object, "ENOENT", @intFromEnum(std.posix.E.NOENT));
    try defineIntProperty(rt, object, "EPERM", @intFromEnum(std.posix.E.PERM));
    try defineIntProperty(rt, object, "EPIPE", @intFromEnum(std.posix.E.PIPE));
    try defineIntProperty(rt, object, "EBADF", @intFromEnum(std.posix.E.BADF));
    try defineObjectProperty(rt, target, "Error", object_value);
}

fn defineLegacyStdFileValue(
    rt: *core.JSRuntime,
    global: *core.Object,
    target: *core.Object,
    name: []const u8,
    file: *std.c.FILE,
    is_popen: bool,
    is_stdio: bool,
) !void {
    const value = try createStdFileValue(rt, global, file, is_popen, is_stdio);
    defer value.free(rt);
    try defineObjectProperty(rt, target, name, value);
}

fn builtinPlatformName() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "darwin",
        .windows => "win32",
        .freebsd => "freebsd",
        .openbsd => "openbsd",
        .netbsd => "netbsd",
        else => "unknown",
    };
}

fn osFlagValue(value: std.c.O) i32 {
    return @intCast(@as(u32, @bitCast(value)));
}
