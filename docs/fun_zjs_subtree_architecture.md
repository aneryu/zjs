# fun + zjs 代码组织与 Git Subtree 协同方案

版本：2026-05-28  
目标：设计一个用 Zig 编写的 Bun-like runtime：`fun`，并且只使用 `zjs` 作为 JavaScript 引擎。`zjs` 由同一维护者维护，因此允许在 runtime 开发过程中同步修改 engine。

---

## 1. 总结

建议使用 **Git subtree**，但不要把 subtree 当成架构边界。

推荐默认方案：

```text
fun/
  third_party/zjs/          # zjs 完整仓库，以 git subtree 引入
  src/js/                   # fun 面向 runtime 的 JS engine facade
  src/runtime/vm/           # fun runtime 与 zjs 的唯一深耦合层
  src/runtime/              # event loop、module loader、Web API、Node API
  src/tooling/              # CLI、resolver、bundler、package manager、test runner
```

也就是说：

```text
third_party/zjs/
  是 zjs 的真实源码 subtree，可以直接改、测试、再 push 回 zjs 仓库。

src/js/
  不是第二套 JS 引擎源码，而是 fun 对 zjs 的稳定入口层。

src/runtime/vm/
  是 fun runtime 和 zjs engine 的胶水层。只有这里可以理解 zjs 的底层 Value、Context、JobQueue、ModuleRecord 等细节。
```

一句话：

> 用 `git subtree` 管理 zjs 的历史和双向同步；用 `src/js` 和 `src/runtime/vm` 管理架构边界。

---

## 2. 为什么不是 submodule，也不是直接复制

### 2.1 不用 submodule

不推荐 `git submodule`，原因是：

- checkout、clone、CI 都要额外处理子模块初始化；
- 修改 zjs 后推回上游比 subtree 更烦；
- 对单人或小团队高频协同开发不友好；
- `fun` 的新贡献者需要理解两个 Git 状态。

`git subtree` 的优点是：zjs 的代码真实存在于 `fun` 仓库目录里；clone `fun` 后不需要额外初始化；也可以把 `third_party/zjs` 的改动 split/push 回 zjs 仓库。

### 2.2 不建议无历史直接 copy

直接复制最简单，但有两个明显问题：

- `git blame` 丢失，调 GC、parser、bytecode、module bug 时会很痛苦；
- 以后 zjs 仍作为独立仓库发布时，需要手工同步。

如果 zjs 确定永远不再作为独立仓库存在，可以直接迁移到 `src/js/`。但只要 zjs 还要保留独立仓库，subtree 更合适。

### 2.3 为什么先放 `third_party/zjs/`，而不是直接 `src/js/`

当前 zjs 仓库本身已有自己的 root：

```text
zjs/
  build.zig
  build.zig.zon
  README.md
  GUIDE.md
  LIMITATIONS.md
  src/engine/
  src/cli/
  src/tools/
  src/tests/
  tests/
  test262/
```

如果直接：

```sh
git subtree add --prefix=src/js zjs main
```

你会得到：

```text
src/js/
  build.zig
  README.md
  src/engine/
  src/cli/
  src/tools/
  ...
```

这不是理想的 fun 源码结构，因为真正的 engine 在 `src/js/src/engine/` 下面。

所以默认推荐：

```text
third_party/zjs/
```

保留 zjs 原始仓库结构，然后在 `fun/src/js/` 做 facade。

等 `fun` 和 `zjs` 的 API 稳定后，如果你决定让 `fun` monorepo 成为唯一 source of truth，再把 `third_party/zjs/src/engine` 扁平迁移到 `src/js`。那是第二阶段，不建议第一天就做。

---

## 3. 推荐仓库结构

```text
fun/
  build.zig
  build.zig.zon
  README.md
  LICENSE.md

  third_party/
    zjs/                              # git subtree：完整 zjs 仓库
      build.zig
      build.zig.zon
      README.md
      GUIDE.md
      LIMITATIONS.md
      COMPATIBILITY.md
      src/
        engine/
          root.zig
          core/
          frontend/
          bytecode/
          exec/
          builtins/
          libs/
        cli/
        tools/
        tests/
      tests/
      test262/
      test262.conf

  src/
    main.zig

    primitives/
      root.zig
      allocators/
      collections/
      string/
      unicode/
      hashing/
      threading/
      safety/
      ptr/
      time/

    diagnostics/
      root.zig
      SourceText.zig
      Span.zig
      Label.zig
      ErrorReport.zig
      StackTrace.zig
      SourceMap.zig

    js/
      root.zig                         # fun 对 zjs 的稳定 facade
      api.zig                          # fun 依赖的 engine-facing API 类型
      value.zig                        # runtime-facing Value wrapper
      exception.zig
      host.zig                         # host hook 类型 re-export / wrapper
      source.zig
      module.zig
      internal.zig                     # 只给 runtime/vm 使用的 zjs internal facade

    runtime/
      root.zig
      Runtime.zig

      vm/
        root.zig
        VM.zig                         # owns zjs engine instance
        Global.zig
        JSValue.zig
        NativeFunction.zig
        Exception.zig
        Promise.zig
        ModuleRecord.zig
        Microtask.zig
        bindings.zig

      scheduler/
        root.zig
        EventLoop.zig
        Task.zig
        Timer.zig
        DeferredTaskQueue.zig
        ImmediateQueue.zig

      async/
        root.zig
        posix_event_loop.zig
        windows_event_loop.zig
        io_task.zig
        file_task.zig
        net_task.zig

      modules/
        root.zig
        registry.zig
        loader.zig
        resolver_bridge.zig

        internal/
          root.zig
          bootstrap.zig
          errors.zig
          timers.zig
          module.zig

        fun/
          root.zig
          main.zig
          file.zig
          shell.zig
          test.zig

        node/
          root.zig
          fs.zig
          path.zig
          buffer.zig
          events.zig
          module.zig
          process.zig
          stream.zig
          http.zig
          url.zig

      api/
        root.zig
        console.zig
        timers.zig
        fetch.zig
        request.zig
        response.zig
        headers.zig
        url.zig
        blob.zig
        file.zig
        websocket.zig

      napi/
        root.zig
        env.zig
        value.zig
        module.zig
        callback.zig

    tooling/
      root.zig

      cli/
        root.zig
        fun.zig                         # fun CLI
        zjs.zig                         # 可选：重新暴露 zjs CLI
        run_test262.zig                 # 可选：重新暴露 test262 runner

      resolver/
        root.zig
        package_json.zig
        exports.zig
        imports.zig
        node_modules.zig
        conditions.zig

      transpiler/
        root.zig
        ts_strip.zig
        jsx.zig
        loader.zig
        sourcemap.zig

      bundler/
        root.zig
        graph.zig
        linker.zig
        chunk.zig
        tree_shaking.zig
        codegen.zig

      package_manager/
        root.zig
        install.zig
        lockfile.zig
        semver.zig
        registry.zig
        cache.zig
        tarball.zig

      test_runner/
        root.zig
        runner.zig
        expect.zig
        snapshot.zig
        reporter.zig

      watcher/
        root.zig
        watcher.zig

      http_server/
        root.zig
        dev_server.zig

      js_validation/
        root.zig                         # zjs smoke/test262 工具的 fun 集成层

    platform/
      root.zig
      common/
      posix/
      linux/
      darwin/
      windows/

    common/
      root.zig                           # 尽量保持为空；不要变成垃圾桶目录

  tests/
    js/
      adapter/
      engine_contract/
      smoke/
      test262/

    runtime/
      vm/
      scheduler/
      modules/
      api/
      napi/

    tooling/
      resolver/
      bundler/
      package_manager/
      transpiler/
      test_runner/

    integration/
      run/
      node_compat/
      web_api/
      fixtures/

  benches/
    js/
    runtime/
    tooling/

  docs/
    architecture/
      subtree.md
      layering.md
      js-host-boundary.md
      event-loop.md
      module-loading.md
      memory.md
      testing.md

    api/

  packages/
    fun-types/
    @types/fun/

  scripts/
```

---

## 4. 分层规则

### 4.1 允许的依赖方向

```text
src/primitives
  -> std only

third_party/zjs/src/engine
  -> zjs 自己的内部模块
  -> std / libc where needed
  -> 不依赖 fun runtime
  -> 不依赖 fun tooling

src/js
  -> third_party/zjs/src/engine
  -> primitives
  -> diagnostics

src/runtime/vm
  -> src/js
  -> 必要时通过 src/js/internal.zig 访问 zjs internal
  -> 不允许 runtime 其他目录直接 import zjs internal

src/runtime/modules
src/runtime/api
src/runtime/scheduler
  -> src/runtime/vm
  -> platform
  -> primitives
  -> diagnostics
  -> 不直接 import third_party/zjs

src/tooling
  -> primitives
  -> diagnostics
  -> platform
  -> runtime when needed
  -> js facade when needed

src/tooling/cli
  -> runtime
  -> tooling
```

### 4.2 禁止的依赖方向

```text
third_party/zjs/* -> src/runtime/*
third_party/zjs/* -> src/tooling/*
third_party/zjs/* -> src/js/*

src/runtime/modules/* -> third_party/zjs/src/engine/*
src/runtime/api/*     -> third_party/zjs/src/engine/*
src/tooling/cli/*     -> third_party/zjs/src/engine/*

src/primitives/* -> src/js/*
src/primitives/* -> src/runtime/*
src/primitives/* -> src/tooling/*
```

### 4.3 唯一深耦合层

只有这个目录允许知道 zjs 内部细节：

```text
src/runtime/vm/
```

其他 runtime 模块必须通过 `runtime/vm` 提供的抽象注册 native function、读写 JS value、创建 promise、抛异常、挂 global。

---

## 5. Git Subtree 工作流

### 5.1 初始化 subtree

```sh
git remote add zjs git@github.com:aneryu/zjs.git
git fetch zjs

git subtree add \
  --prefix=third_party/zjs \
  zjs main \
  -m "Import zjs as subtree"
```

推荐第一阶段 **不要加 `--squash`**。

原因：

- zjs 仍然是你维护的核心子系统，不是只读第三方包；
- 保留完整历史便于 `git blame`；
- GC、bytecode、parser、module、Promise job queue 这类 bug 经常需要追历史；
- 后续 `subtree split/push` 更容易保持可审计。

只有当 zjs 被当成普通 vendor dependency，并且你不关心 zjs 内部历史时，才考虑 `--squash`。

### 5.2 从 zjs 拉更新

```sh
git fetch zjs

git subtree pull \
  --prefix=third_party/zjs \
  zjs main \
  -m "Update zjs subtree"
```

如果你用了 squash，pull 时也要继续用 squash：

```sh
git subtree pull \
  --prefix=third_party/zjs \
  zjs main \
  --squash \
  -m "Update zjs subtree"
```

不要混用 squash 和非 squash 模式。

### 5.3 在 fun 里修改 zjs 后推回 zjs

先正常修改：

```text
third_party/zjs/src/engine/...
src/js/...
src/runtime/vm/...
```

提交时尽量拆分：

```sh
git add third_party/zjs
git commit -m "zjs: expose host module loader hook"

git add src/js src/runtime/vm
git commit -m "fun: wire runtime module loader into zjs host hook"
```

然后把 subtree 里的 zjs 改动推回 zjs 仓库：

```sh
git subtree push \
  --prefix=third_party/zjs \
  zjs main
```

如果不想直接推 main，可以先 split 出本地分支：

```sh
git subtree split \
  --prefix=third_party/zjs \
  --branch zjs-export

git push zjs zjs-export:fun-integration
```

然后在 zjs 仓库里开 PR 或 merge。

### 5.4 跨 zjs 和 fun 的改动如何提交

如果一次功能同时需要改 engine 和 runtime，不要把所有东西塞进一个提交。

推荐：

```text
commit 1:
  third_party/zjs/*
  只增加 zjs engine 能力，例如 host hook、Value lifetime 修复、Promise job queue 暴露

commit 2:
  src/js/*
  只更新 fun facade / wrapper

commit 3:
  src/runtime/vm/*
  只接线 zjs 能力到 Fun VM

commit 4:
  src/runtime/modules/* 或 src/runtime/api/*
  实现具体 runtime API，例如 fs、timer、fetch、Buffer
```

这样 `git subtree split --prefix=third_party/zjs` 时，commit message 和 diff 仍然有意义。

---

## 6. build.zig 模块组织

### 6.1 模块图

```text
zjs_engine_mod
  root: third_party/zjs/src/engine/root.zig

js_mod
  root: src/js/root.zig
  imports:
    zjs_engine_mod
    primitives
    diagnostics

runtime_mod
  root: src/runtime/root.zig
  imports:
    js_mod
    primitives
    diagnostics
    platform

tooling_mod
  root: src/tooling/root.zig
  imports:
    runtime_mod
    js_mod
    primitives
    diagnostics
    platform

fun_exe
  root: src/tooling/cli/fun.zig
  imports:
    runtime_mod
    tooling_mod

zjs_exe
  root: third_party/zjs/src/cli/qjs.zig
  imports:
    zjs_engine_mod
```

### 6.2 build.zig 示意

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zjs_enable_ic =
        b.option(bool, "zjs_enable_ic", "Enable zjs shape-keyed inline caches") orelse true;

    const engine_options = b.addOptions();
    engine_options.addOption(bool, "zjs_enable_ic", zjs_enable_ic);

    const primitives_mod = b.createModule(.{
        .root_source_file = b.path("src/primitives/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const diagnostics_mod = b.createModule(.{
        .root_source_file = b.path("src/diagnostics/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "primitives", .module = primitives_mod },
        },
    });

    const zjs_engine_mod = b.createModule(.{
        .root_source_file = b.path("third_party/zjs/src/engine/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zjs_engine_mod.addOptions("build_options", engine_options);

    const js_mod = b.createModule(.{
        .root_source_file = b.path("src/js/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zjs_engine", .module = zjs_engine_mod },
            .{ .name = "primitives", .module = primitives_mod },
            .{ .name = "diagnostics", .module = diagnostics_mod },
        },
    });

    const platform_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "primitives", .module = primitives_mod },
        },
    });

    const runtime_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "js", .module = js_mod },
            .{ .name = "primitives", .module = primitives_mod },
            .{ .name = "diagnostics", .module = diagnostics_mod },
            .{ .name = "platform", .module = platform_mod },
        },
    });

    const tooling_mod = b.createModule(.{
        .root_source_file = b.path("src/tooling/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "js", .module = js_mod },
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "primitives", .module = primitives_mod },
            .{ .name = "diagnostics", .module = diagnostics_mod },
            .{ .name = "platform", .module = platform_mod },
        },
    });

    const fun_cli_mod = b.createModule(.{
        .root_source_file = b.path("src/tooling/cli/fun.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "runtime", .module = runtime_mod },
            .{ .name = "tooling", .module = tooling_mod },
            .{ .name = "js", .module = js_mod },
        },
    });

    const fun_exe = b.addExecutable(.{
        .name = "fun",
        .root_module = fun_cli_mod,
    });
    b.installArtifact(fun_exe);

    const zjs_cli_mod = b.createModule(.{
        .root_source_file = b.path("third_party/zjs/src/cli/qjs.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "quickjs_zig_engine", .module = zjs_engine_mod },
        },
    });

    const zjs_exe = b.addExecutable(.{
        .name = "zjs",
        .root_module = zjs_cli_mod,
    });

    const zjs_step = b.step("zjs", "Build zjs CLI");
    zjs_step.dependOn(&b.addInstallArtifact(zjs_exe, .{}).step);

    const fun_step = b.step("fun", "Build fun CLI");
    fun_step.dependOn(&b.addInstallArtifact(fun_exe, .{}).step);

    addTests(b, target, optimize, .{
        .zjs_engine = zjs_engine_mod,
        .js = js_mod,
        .runtime = runtime_mod,
        .tooling = tooling_mod,
    });
}

const TestModules = struct {
    zjs_engine: *std.Build.Module,
    js: *std.Build.Module,
    runtime: *std.Build.Module,
    tooling: *std.Build.Module,
};

fn addTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mods: TestModules,
) void {
    _ = target;
    _ = optimize;

    const js_tests = b.addTest(.{
        .name = "test-js-adapter",
        .root_module = mods.js,
    });
    const run_js_tests = b.addRunArtifact(js_tests);

    const runtime_tests = b.addTest(.{
        .name = "test-runtime",
        .root_module = mods.runtime,
    });
    const run_runtime_tests = b.addRunArtifact(runtime_tests);

    const tooling_tests = b.addTest(.{
        .name = "test-tooling",
        .root_module = mods.tooling,
    });
    const run_tooling_tests = b.addRunArtifact(tooling_tests);

    const test_step = b.step("test", "Run fast tests");
    test_step.dependOn(&run_js_tests.step);
    test_step.dependOn(&run_runtime_tests.step);
    test_step.dependOn(&run_tooling_tests.step);
}
```

---

## 7. `src/js` facade 设计

`src/js` 的职责是让 fun runtime 不直接依赖 zjs 内部路径。

### 7.1 `src/js/root.zig`

```zig
pub const api = @import("api.zig");
pub const host = @import("host.zig");

pub const Engine = api.Engine;
pub const Source = api.Source;
pub const Completion = api.Completion;
pub const Exception = api.Exception;
pub const Value = @import("value.zig").Value;
```

### 7.2 `src/js/api.zig`

```zig
const std = @import("std");
const zjs = @import("zjs_engine");

pub const Source = struct {
    path: []const u8,
    bytes: []const u8,
};

pub const EvalKind = enum {
    script,
    module,
};

pub const Completion = union(enum) {
    normal: Value,
    exception: Exception,
};

pub const Exception = struct {
    message: []const u8,
    stack: ?[]const u8 = null,
};

pub const EvalError = error{
    OutOfMemory,
    HostError,
    ParserBug,
    BytecodeBug,
    InternalBug,
};

pub const Value = @import("value.zig").Value;

pub const Engine = struct {
    inner: zjs.Engine,

    pub fn init(allocator: std.mem.Allocator, host: Host) !Engine {
        return .{
            .inner = try zjs.Engine.init(allocator, .{
                .host = host.toZjsHost(),
            }),
        };
    }

    pub fn deinit(self: *Engine) void {
        self.inner.deinit();
    }

    pub fn eval(
        self: *Engine,
        source: Source,
        kind: EvalKind,
    ) EvalError!Completion {
        return switch (kind) {
            .script => self.evalScript(source),
            .module => self.evalModule(source),
        };
    }

    pub fn evalScript(self: *Engine, source: Source) EvalError!Completion {
        // Adapter into zjs API.
        _ = self;
        _ = source;
        return error.InternalBug;
    }

    pub fn evalModule(self: *Engine, source: Source) EvalError!Completion {
        // Adapter into zjs API.
        _ = self;
        _ = source;
        return error.InternalBug;
    }

    pub fn runJobs(self: *Engine) EvalError!void {
        try self.inner.runJobs();
    }
};

const Host = @import("host.zig").Host;
```

这只是结构示意。具体调用要按你当时的 zjs API 调整。

### 7.3 `src/js/internal.zig`

```zig
/// Internal zjs facade.
///
/// Only these directories may import this file:
/// - src/runtime/vm/
/// - tests/js/
/// - benches/js/
pub const zjs = @import("zjs_engine");

// 可选：只 re-export 需要的内部子模块。
// 不要在这里无脑暴露全部内部类型。
```

如果你以后把 zjs 从 `third_party/zjs` 扁平迁移到 `src/js`，`runtime/vm` 的 import 面仍然不需要大改。

---

## 8. zjs 内需要新增的 embedding API

因为 fun 和 zjs 一起维护，所以建议在 zjs 内部增加正式 embedding API，而不是让 fun runtime 到处调用 zjs 内部函数。

建议在 zjs 里新增：

```text
third_party/zjs/src/engine/api/
  Engine.zig
  Context.zig
  Value.zig
  Exception.zig
  Source.zig
  Completion.zig
  Options.zig
  root.zig

third_party/zjs/src/engine/host/
  Host.zig
  ModuleLoader.zig
  NativeFunction.zig
  PromiseRejectionTracker.zig
  JobQueue.zig
  ExternalBuffer.zig
  root.zig
```

### 8.1 Host hook

```zig
const std = @import("std");

pub const Host = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        resolveModule: *const fn (
            ptr: *anyopaque,
            specifier: []const u8,
            referrer: ?[]const u8,
            allocator: std.mem.Allocator,
        ) HostError!ResolvedModule,

        loadModule: *const fn (
            ptr: *anyopaque,
            resolved: ResolvedModule,
            allocator: std.mem.Allocator,
        ) HostError!LoadedModule,

        enqueuePromiseJob: *const fn (
            ptr: *anyopaque,
            job: PromiseJob,
        ) HostError!void,

        promiseRejectionTracker: *const fn (
            ptr: *anyopaque,
            rejection: PromiseRejection,
        ) void,

        nowNanoseconds: *const fn (ptr: *anyopaque) u64,
    };
};

pub const HostError = error{
    OutOfMemory,
    ModuleNotFound,
    PermissionDenied,
    Unsupported,
    RuntimeError,
};

pub const ResolvedModule = struct {
    specifier: []const u8,
    path: []const u8,
    kind: ModuleKind,
};

pub const LoadedModule = struct {
    source: []const u8,
    path: []const u8,
    kind: ModuleKind,
    owned: bool = false,
};

pub const ModuleKind = enum {
    esm,
    commonjs,
    json,
    wasm,
    builtin,
};

pub const PromiseJob = opaque {};
pub const PromiseRejection = opaque {};
```

### 8.2 为什么 host hook 必须在 zjs 层正式化

fun 需要这些能力：

```text
- resolve ESM
- resolve CommonJS
- resolve node_modules
- resolve package.json exports/imports
- load builtin modules
- load virtual modules
- handle dynamic import
- queue Promise jobs
- run microtasks after scheduler ticks
- track unhandled promise rejection
```

这些不能硬塞进 zjs 的 `exec/module.zig`。zjs 应该只实现 ECMAScript module semantics；fun runtime 实现 Node/Bun-style host semantics。

---

## 9. `runtime/vm` 设计

### 9.1 VM 持有 zjs engine

```zig
const std = @import("std");
const js = @import("js");
const Runtime = @import("../Runtime.zig");

const VM = @This();

allocator: std.mem.Allocator,
runtime: *Runtime,
engine: js.Engine,

pub const Options = struct {
    runtime: *Runtime,
};

pub fn init(allocator: std.mem.Allocator, options: Options) !VM {
    var self = VM{
        .allocator = allocator,
        .runtime = options.runtime,
        .engine = undefined,
    };

    const host = js.host.Host{
        .ptr = &self,
        .vtable = &host_vtable,
    };

    self.engine = try js.Engine.init(allocator, host);
    return self;
}

pub fn deinit(self: *VM) void {
    self.engine.deinit();
}

pub fn evalModule(self: *VM, source: js.Source) !js.Completion {
    return self.engine.eval(source, .module);
}

pub fn runMicrotasks(self: *VM) !void {
    try self.engine.runJobs();
}
```

### 9.2 VM 实现 zjs host hook

```zig
const host_vtable = js.host.Host.VTable{
    .resolveModule = resolveModule,
    .loadModule = loadModule,
    .enqueuePromiseJob = enqueuePromiseJob,
    .promiseRejectionTracker = promiseRejectionTracker,
    .nowNanoseconds = nowNanoseconds,
};

fn resolveModule(
    ptr: *anyopaque,
    specifier: []const u8,
    referrer: ?[]const u8,
    allocator: std.mem.Allocator,
) js.host.HostError!js.host.ResolvedModule {
    const self: *VM = @ptrCast(@alignCast(ptr));
    return self.runtime.modules.resolve(specifier, referrer, allocator);
}

fn loadModule(
    ptr: *anyopaque,
    resolved: js.host.ResolvedModule,
    allocator: std.mem.Allocator,
) js.host.HostError!js.host.LoadedModule {
    const self: *VM = @ptrCast(@alignCast(ptr));
    return self.runtime.modules.load(resolved, allocator);
}

fn enqueuePromiseJob(
    ptr: *anyopaque,
    job: js.host.PromiseJob,
) js.host.HostError!void {
    const self: *VM = @ptrCast(@alignCast(ptr));
    return self.runtime.scheduler.enqueueMicrotask(job);
}

fn promiseRejectionTracker(
    ptr: *anyopaque,
    rejection: js.host.PromiseRejection,
) void {
    const self: *VM = @ptrCast(@alignCast(ptr));
    self.runtime.reportPromiseRejection(rejection);
}

fn nowNanoseconds(ptr: *anyopaque) u64 {
    const self: *VM = @ptrCast(@alignCast(ptr));
    return self.runtime.scheduler.nowNanoseconds();
}
```

---

## 10. Runtime 设计

### 10.1 Runtime 持有 VM、scheduler、module loader

```zig
const std = @import("std");
const vm = @import("vm/root.zig");

const Runtime = @This();

allocator: std.mem.Allocator,
vm: vm.VM,
scheduler: Scheduler,
modules: ModuleLoader,

pub const Options = struct {
    cwd: []const u8,
    argv: []const []const u8 = &.{},
    enable_node_compat: bool = true,
};

pub fn init(allocator: std.mem.Allocator, options: Options) !Runtime {
    var rt = Runtime{
        .allocator = allocator,
        .scheduler = try Scheduler.init(allocator),
        .modules = try ModuleLoader.init(allocator, options.cwd),
        .vm = undefined,
    };

    rt.vm = try vm.VM.init(allocator, .{
        .runtime = &rt,
    });

    try rt.vm.installGlobals(options);
    return rt;
}

pub fn deinit(self: *Runtime) void {
    self.vm.deinit();
    self.modules.deinit();
    self.scheduler.deinit();
}

pub fn runEntry(self: *Runtime, path: []const u8) !void {
    const source = try self.modules.loadEntry(path);
    defer self.modules.freeSource(source);

    const completion = try self.vm.evalModule(.{
        .path = source.path,
        .bytes = source.bytes,
    });

    try self.vm.handleCompletion(completion);
    try self.drain();
}

fn drain(self: *Runtime) !void {
    while (try self.scheduler.tick()) {
        try self.vm.runMicrotasks();
    }
}
```

### 10.2 执行流程

```text
fun run entry.js
  -> CLI 解析参数
  -> Runtime.init
  -> Runtime.runEntry
  -> ModuleLoader.loadEntry
  -> VM.evalModule
  -> js.Engine.evalModule
  -> zjs exec/module
  -> host hook resolve/load dependency
  -> Runtime.modules.resolve/load
  -> zjs evaluate
  -> Runtime.scheduler.tick
  -> VM.runMicrotasks
  -> js.Engine.runJobs
```

---

## 11. 模块加载边界

### 11.1 zjs 负责

```text
- ECMAScript module record
- import/export binding
- module linking
- module evaluation
- dynamic import 的 ECMAScript job 语义
- top-level await 的 engine 语义
```

### 11.2 fun runtime 负责

```text
- file path resolution
- node_modules resolution
- package.json exports/imports
- conditions
- CommonJS wrapper
- JSON loader
- WASM loader
- builtin modules
- virtual modules
- cache
- watch mode invalidation
```

### 11.3 tooling/resolver 负责

```text
src/tooling/resolver/
  package_json.zig
  exports.zig
  imports.zig
  node_modules.zig
  conditions.zig
```

`runtime/modules/loader.zig` 可以调用 `tooling/resolver`，但 zjs 不能直接调用 resolver。zjs 只能通过 host hook 请求 resolved module。

---

## 12. Builtins 边界

### 12.1 zjs builtins

```text
third_party/zjs/src/engine/builtins/
  ECMAScript builtins:
    Object
    Function
    Array
    Promise
    RegExp
    Map
    Set
    TypedArray
    Iterator
    Error
    Date
```

zjs 可以保留 QuickJS-style `qjs:std` / `qjs:os`，但它们只服务 zjs CLI、test262 或 QuickJS parity，不作为 fun runtime 的公开 API 基础。

### 12.2 fun runtime APIs

```text
src/runtime/api/
  console
  timers
  fetch
  URL
  Request
  Response
  Headers
  Blob
  File
  WebSocket
```

### 12.3 Node compatibility

```text
src/runtime/modules/node/
  fs
  path
  buffer
  events
  module
  process
  stream
  http
  url
```

这些不能写进 zjs engine。

---

## 13. 错误模型

不要把 JS exception 和 Zig error 混在一起。

### 13.1 推荐模型

```zig
pub const Completion = union(enum) {
    normal: Value,
    exception: Exception,
};

pub const EvalError = error{
    OutOfMemory,
    HostError,
    ParserBug,
    BytecodeBug,
    InternalBug,
};
```

含义：

```text
throw new Error("x")
  -> Completion.exception

OOM
  -> error.OutOfMemory

zjs 内部 invariant broken
  -> error.InternalBug

module loader 的宿主失败
  -> error.HostError
```

### 13.2 为什么这样设计

JS `throw` 是语言层控制流。它可能被 `try/catch` 捕获，也可能变成 Promise rejection，也可能在 top-level module evaluation 中传播。

Zig error 只表示 Zig/host/engine 层的失败，例如 OOM、IO、内部 bug、host hook 失败。

---

## 14. 内存与 ownership 规则

### 14.1 全仓库规则

```text
- 可能分配的函数必须显式接收 std.mem.Allocator。
- 返回 owned memory 必须写清楚 caller frees。
- borrowed slice 必须写清有效期。
- free 必须使用同一个 allocator。
- error path 用 errdefer。
- 不允许 library code 偷偷使用全局 allocator。
- 不允许返回指向 stack 的 slice/pointer。
```

### 14.2 zjs 层

```text
- JS Value ownership 必须明确 retain/free 规则。
- GC、cycle collector、finalizer、weak edges、object graph 改动必须有 focused lifetime tests。
- zjs CLI 的 normal exit 可以允许 OS reclaim，但 embedding path 必须正常 deinit。
```

### 14.3 runtime 层

```text
- Runtime owns long-lived allocator。
- 每个 module load / request / transform 可以使用短生命周期 arena。
- Native host object 必须有明确 finalizer。
- JS object 持有 Zig resource 时必须经过 VM binding 层。
```

### 14.4 tooling 层

```text
- bundler graph、package manager cache 有明确 owner。
- transpiler/codegen 可使用 arena。
- source map 返回 owned memory 时必须标注 free responsibility。
```

---

## 15. 测试结构

```text
tests/
  js/
    adapter/
      facade_test.zig
      exception_test.zig
      value_lifetime_test.zig

    engine_contract/
      eval_basic_test.zig
      promise_microtask_test.zig
      esm_test.zig
      dynamic_import_test.zig
      native_function_test.zig
      module_loader_test.zig

    smoke/
      manifest.txt
      console.js
      promise.js
      module.js

    test262/
      README.md

  runtime/
    vm/
      native_function_test.zig
      promise_bridge_test.zig
      module_bridge_test.zig

    scheduler/
      timer_test.zig
      microtask_order_test.zig

    modules/
      esm_loader_test.zig
      cjs_loader_test.zig
      builtin_module_test.zig

    api/
      console_test.zig
      timers_test.zig
      fetch_test.zig

  tooling/
    resolver/
      package_exports_test.zig
      node_modules_test.zig

    bundler/
      graph_test.zig
      linker_test.zig

    package_manager/
      semver_test.zig
      lockfile_test.zig

  integration/
    run/
      simple_script_test.zig

    node_compat/
      fs_fixture_test.zig
      buffer_fixture_test.zig

    web_api/
      fetch_fixture_test.zig

    fixtures/
      esm/
      cjs/
      node_modules/
```

---

## 16. Build steps

推荐 build steps：

```text
zig build fun
  Build fun CLI.

zig build zjs
  Build zjs CLI from third_party/zjs.

zig build test-js
  Test src/js facade and zjs integration.

zig build test-zjs
  Run zjs unit tests imported from subtree.

zig build smoke-zjs
  Run zjs smoke fixtures.

zig build test262-gate
  Run zjs test262 gate. Not part of default fast test.

zig build test-runtime
  Test runtime/vm, scheduler, modules, API.

zig build test-tooling
  Test resolver, bundler, package manager, transpiler.

zig build test-integration
  Spawn zig-out/bin/fun and run fixture scripts.

zig build test
  Fast default:
    test-js
    test-runtime
    test-tooling
    selected integration tests

zig build test-all
  Slow full validation:
    test
    smoke-zjs
    test262-gate
    extended integration tests
```

Full test262 不应该默认跑在 `zig build test`，否则本地开发反馈太慢。语义修改、parser 修改、bytecode 修改、Promise/job queue 修改需要跑 focused test262 slice，再跑 full gate。

---

## 17. 迁移计划

### Phase 0：建立 fun skeleton

```text
- 创建 fun 仓库
- 建 src/primitives
- 建 src/diagnostics
- 建 src/js
- 建 src/runtime/vm
- 建 src/runtime
- 建 src/tooling
- 建 src/platform
```

### Phase 1：引入 zjs subtree

```sh
git remote add zjs git@github.com:aneryu/zjs.git
git fetch zjs

git subtree add \
  --prefix=third_party/zjs \
  zjs main \
  -m "Import zjs as subtree"
```

确认：

```sh
ls third_party/zjs
```

应看到：

```text
build.zig
build.zig.zon
README.md
src/engine
src/cli
src/tools
tests
test262.conf
```

### Phase 2：接通 build graph

目标命令：

```sh
zig build zjs --summary all
zig build fun --summary all
zig build test-js --summary all
```

第一阶段的 `fun` 可以只支持：

```sh
zig-out/bin/fun -e "console.log(1 + 2)"
zig-out/bin/fun path/to/file.js
```

### Phase 3：建立 `src/js` facade

```text
src/js/root.zig
src/js/api.zig
src/js/value.zig
src/js/exception.zig
src/js/host.zig
src/js/internal.zig
```

此时 fun runtime 只 import：

```zig
const js = @import("js");
```

不直接 import：

```zig
const zjs = @import("quickjs_zig_engine");
```

### Phase 4：建立 `runtime/vm`

```text
src/runtime/vm/VM.zig
src/runtime/vm/Global.zig
src/runtime/vm/NativeFunction.zig
src/runtime/vm/Promise.zig
src/runtime/vm/Microtask.zig
```

跑通：

```sh
zig-out/bin/fun -e "console.log(1 + 2)"
```

### Phase 5：把 zjs module loading 抽成 host hook

zjs 内新增：

```text
third_party/zjs/src/engine/host/
```

fun 实现：

```text
src/runtime/modules/loader.zig
src/tooling/resolver/
```

跑通：

```js
// main.js
import { value } from "./dep.js";
console.log(value);
```

### Phase 6：event loop + microtasks

目标：

```js
Promise.resolve().then(() => console.log("microtask"));
setTimeout(() => console.log("timer"), 0);
```

保证顺序和 runtime 设计一致。

### Phase 7：Node/Web API

优先级：

```text
1. console
2. process
3. timers
4. URL
5. Buffer
6. fs/path
7. fetch/Request/Response/Headers
8. stream
9. http
```

### Phase 8：tooling

```text
1. resolver
2. TS strip
3. JSX
4. bundler
5. package manager
6. test runner
```

---

## 18. 什么时候把 zjs 从 `third_party/zjs` 迁到 `src/js`

第一阶段不要迁。

满足这些条件后再考虑：

```text
- fun 的 Runtime/VM/Host hook 边界已经稳定。
- zjs 的 embedding API 已经稳定。
- zjs 独立仓库不再需要保持当前 root layout。
- 你愿意让 fun monorepo 成为 zjs 的 source of truth。
```

迁移后结构可以变成：

```text
fun/
  src/js/
    root.zig
    api/
    host/
    core/
    frontend/
    bytecode/
    exec/
    builtins/
    libs/
```

此时 zjs 独立仓库可以由 fun 导出：

```sh
git subtree split \
  --prefix=src/js \
  --branch zjs-export

git push zjs zjs-export:main
```

这时 `fun` 是 source of truth，`zjs` 是发布镜像。

---

## 19. 代码 review 规则

### 19.1 zjs 改动

必须说明：

```text
- 是否影响 JS 语义
- 是否影响 Value ownership
- 是否影响 GC/finalizer/weak edges
- 是否影响 bytecode format
- 是否影响 module linking/evaluation
- 是否影响 Promise job queue
- 需要跑哪些 focused tests
```

### 19.2 runtime/vm 改动

必须说明：

```text
- 是否新增 zjs internal dependency
- 是否改变 native function ABI
- 是否改变 exception formatting
- 是否改变 microtask drain timing
- 是否改变 JS Value lifetime
```

### 19.3 runtime API 改动

必须说明：

```text
- 对应 Web API、Node API、还是 Fun API
- 是否需要 builtin module entry
- 是否需要 typings
- 是否需要 integration fixture
```

### 19.4 tooling 改动

必须说明：

```text
- 是否影响 resolver
- 是否影响 bundler graph
- 是否影响 sourcemap
- 是否影响 watch mode
- 是否影响 package manager lockfile
```

---

## 20. Lint / import guard

Zig 本身不强制包可见性，所以建议加一个简单脚本检查非法 import。

规则：

```text
只有这些路径可以直接 import zjs engine module：
  src/js/
  src/runtime/vm/
  tests/js/
  benches/js/
  src/tooling/cli/zjs.zig
  src/tooling/js_validation/

禁止这些路径直接 import zjs engine module：
  src/runtime/api/
  src/runtime/modules/
  src/runtime/scheduler/
  src/tooling/bundler/
  src/tooling/package_manager/
  src/tooling/resolver/
```

简单脚本逻辑：

```sh
grep -R '@import("quickjs_zig_engine")\|@import("zjs_engine")' src tests benches \
  | grep -v '^src/js/' \
  | grep -v '^src/runtime/vm/' \
  | grep -v '^tests/js/' \
  | grep -v '^benches/js/' \
  | grep -v '^src/tooling/cli/zjs.zig' \
  | grep -v '^src/tooling/js_validation/'
```

如果有输出，CI 失败。

---

## 21. 推荐开发流程

### 21.1 修改 engine 能力

例如：为 module loader 增加 host hook。

```text
1. 修改 third_party/zjs/src/engine/host 或 exec/module。
2. 添加 zjs focused test。
3. 运行 zjs fast tests。
4. 提交：zjs: expose host module loader hook
5. 修改 src/js facade。
6. 修改 src/runtime/vm 接线。
7. 修改 runtime/modules loader。
8. 添加 fun integration test。
9. 提交：fun: wire module loader through zjs host hook
10. subtree push zjs 改动回 zjs 仓库。
```

### 21.2 修改 runtime API

例如：实现 `console.log`。

```text
1. 修改 src/runtime/api/console.zig。
2. 通过 src/runtime/vm/Global.zig 注册 global.console。
3. 不改 third_party/zjs，除非 zjs native function ABI 不够。
4. 添加 runtime/api test。
5. 添加 integration fixture。
```

### 21.3 修改 resolver

例如：支持 package exports。

```text
1. 修改 src/tooling/resolver/exports.zig。
2. 修改 src/runtime/modules/loader.zig 调用 resolver。
3. 不改 zjs。
4. 添加 resolver unit test。
5. 添加 integration fixture。
```

---

## 22. 风险与处理

### 风险 1：subtree commit 历史污染 fun log

处理：

```text
- 不要 squash zjs 初始导入，因为你需要历史。
- 日常看 log 时用路径过滤：
  git log -- src/runtime
  git log -- third_party/zjs/src/engine/core
- 如果未来 zjs 稳定且不再频繁调试历史，再考虑 squash 模式。
```

### 风险 2：跨目录提交导致 subtree split 后 commit message 不清楚

处理：

```text
- zjs 和 fun runtime 改动分开 commit。
- 如果必须一个 commit，commit message 写清楚 zjs 部分和 fun 部分。
- 合并前检查：
  git subtree split --prefix=third_party/zjs --branch zjs-export-test
  git log --oneline zjs-export-test -20
```

### 风险 3：runtime 到处依赖 zjs internal

处理：

```text
- 建 src/js facade。
- 建 src/runtime/vm 作为唯一 deep integration 层。
- 加 import guard CI。
```

### 风险 4：zjs CLI 和 fun runtime 的需求冲突

处理：

```text
- zjs CLI 使用 qjs-style host。
- fun runtime 使用 fun host。
- zjs engine 不直接内置 fun runtime semantics。
```

### 风险 5：test262 太慢

处理：

```text
- 默认 zig build test 不跑 full test262。
- 语义修改跑 focused slice。
- CI nightly 或 release gate 跑 full test262-gate。
```

---

## 23. 最终判断

用 `git subtree` 是合适的，但推荐这样理解：

```text
正确理解：
  subtree 是源码历史和同步机制。

错误理解：
  subtree 是架构边界。
```

最终推荐：

```text
第一阶段：
  third_party/zjs/      # subtree，完整保留 zjs 仓库
  src/js/               # facade
  src/runtime/vm/       # deep integration

第二阶段：
  如果 fun 成为 zjs source of truth：
    把 zjs engine 扁平迁移到 src/js/
    用 git subtree split --prefix=src/js 导出 zjs 独立仓库
```

这套方式的好处：

```text
- zjs 可以继续独立维护和验证。
- fun 可以高频修改 zjs。
- clone fun 不需要 submodule 初始化。
- 可以把 fun 里的 zjs 改动 push 回 zjs。
- runtime 不会直接长在 zjs internal 上。
- 以后可以平滑从 subtree-vendored 模式迁到 first-party src/js 模式。
```

---

## 24. 参考资料

- Git subtree documentation: https://github.com/git/git/blob/master/contrib/subtree/git-subtree.adoc
- zjs README: https://github.com/aneryu/zjs
- zjs LIMITATIONS.md: https://raw.githubusercontent.com/aneryu/zjs/main/LIMITATIONS.md
- zjs GUIDE.md: https://raw.githubusercontent.com/aneryu/zjs/main/GUIDE.md
