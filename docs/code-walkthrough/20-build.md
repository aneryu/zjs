# 20 — 构建图（`build.zig` / `build/*.zig`）

本册覆盖构建入口与 `build/` 下每一个命名函数、每一个 `b.step` 注册，以及无函数文件里的类型与表。权威仍是源码；门禁义务见 [`docs/verification-policy.md`](../verification-policy.md)，步骤关系见 [`docs/testing-graph.md`](../testing-graph.md)。

Zig 钉 0.16.0。`build.zig` 把图种子钉成 `0`（可用 `-Dzjs_test_seed` 覆盖），这样测试 runner 参数稳定、磁盘缓存可命中。

一次 `zig build` 只有一种 `-Doptimize`（Zig 默认 Debug）。发货显式传 `-Doptimize=ReleaseFast`。图里不再同时钉 Debug CLI 和 ReleaseFast CLI。

## 文件地图

| 文件 | 职责 |
| --- | --- |
| [`build.zig`](../../build.zig) | 读 CLI 选项、算配置签名、组装 `Ctx`，依次调用四个 `add*` |
| [`build/config.zig`](../../build/config.zig) | `Ctx`、签名字符串、每模块一份 `addOptions`、Debug 强制 LLVM、Run 步 CPU 钉 |
| [`build/artifacts.zig`](../../build/artifacts.zig) | 引擎模块与 CLI 产物：`zjs` / `zjs-size` / `zjs-profile` / `run-test262` |
| [`build/tests.zig`](../../build/tests.zig) | 统一套件、`check`、smoke、OOM、embedding、leak-census |
| [`build/perf.zig`](../../build/perf.zig) | `perf-benchmark`；**不是**门禁 |
| [`build/gates.zig`](../../build/gates.zig) | `quick-gate` / `checkpoint-gate` / `engine-production-gate`、test262 |

调用顺序（`build` 末尾）：

```
artifacts.addEngineArtifacts(ctx)
tests.addTestGraph(ctx, artifacts)
perf.addPerfSteps(ctx, artifacts)
gates.addGates(ctx, artifacts, test_graph)
```

---

## 类型（`build/config.zig`）

### `Ctx` (`build/config.zig:7`)

传给每个 `add*` 的共享袋：同一套 option 对象、解析后的 target/optimize、Run 步 CPU 列表。存在的理由是「每个 helper 看到的是同一批对象」——否则 `artifacts.zig` / `tests.zig` / `gates.zig` 各自重建一份 `Step.Options`，同名选项会变成互不相等的缓存身份。字段：

| 字段 | 含义 |
| --- | --- |
| `b` | `*std.Build` |
| `target` / `optimize` | 顶层 `-Dtarget` / `-Doptimize` |
| `engine_inputs` | 一份选项形状；profile 另开 `enable_opcode_profile`，OOM 另开 `oom_injection` |
| `engine_options` | 跟随 `-Doptimize` 的那份 `Step.Options`（公共模块与主 CLI 引擎共用） |
| `gate_run_cpus` | Run 步 `taskset` 列表；空字符串 = 不钉 |

### `EngineOptionInputs` (`build/config.zig:42`)

每个引擎模块收到的 options 形状——一个形状，所以某个模块不可能被悄悄喂一个子集。字段：

| 字段 | 含义 |
| --- | --- |
| `enable_opcode_profile` | 编进每 opcode 分发 scope；只有 `zjs-profile` 打开 |
| `compiler_layout` | 布局代号，透传给引擎 |
| `oom_coverage` | OOM 覆盖层开关 |
| `oom_injection` | 把 block heap 的 superblock/extent 后备与小对象 slab arena 的补给改走 `MemoryAccount.backing_allocator`，让 tracing 收集器挪进这些池子的分配对 `std.testing.checkAllAllocationFailures` 与 fail-at-N 分配器可见。这是 OOM 层的注入面，不改语义：字节记账与内存上限行为两边一样 |
| `force_gc` / `ownership_audit` | 诊断开关 |
| `gc_roots_diag` | R3 根诊断构建；默认 false，只有 diag 产物开（它同时决定 `omit_frame_pointer`） |

`oom_injection` 默认 `false`：**包括** `zig build test`。它曾经以 `builtin.is_test` 为键，结果改掉了整份单测的分配器拓扑，每个测试量的都是发货构建根本没有的堆；现在只有 `test-oom` 这一步打开它。

---

## `build.zig`

### `build` (`build.zig:8`)

- **签名**：`pub fn build(b: *std.Build) void`。
- **作用**：读构建选项、钉图种子、装配 `Ctx`，再把产物/测试/perf/门禁挂进同一张图。
- **实现**：
  1. `standardTargetOptions` / `standardOptimizeOption`。
  2. `-Dzjs_test_seed`（默认 0）写入 `b.graph.random_seed`，抵消 Zig CLI 随机 `--seed` 对缓存的破坏。
  3. 开关：`zjs_enable_opcode_profile`、`zjs_compiler_layout`（只允许 `short`/`plain`，否则 `exit(1)`）、`zjs_oom_coverage`、`zjs_force_gc`、`zjs_ownership_audit`、`zjs_gc_roots_diag`。
  4. 一份 `addEngineOptions`。所有 CLI 与测试跟随这次的 `-Doptimize`。
  5. 填 `Ctx.gate_run_cpus = config.gateRunCpus(b)`，依次 `addEngineArtifacts` / `addTestGraph` / `addPerfSteps` / `addGates`。
- **所有权 / 错误 / 调用**：不返回 error；非法 layout / 畸形签名 `std.process.exit(1)`。调用方是 Zig 构建 runner。不分配引擎堆。

注册的顶层步骤全部由四个 `add*` 发出，见下列各节。`b.getInstallStep()` 依赖 `zjs` 的 install。

---

## `build/config.zig` 函数

### `gateRunCpus` (`build/config.zig:22`)

- **签名**：`pub fn gateRunCpus(b: *std.Build) []const u8`。
- **作用**：可选地决定图里 **Run** 步（单元测试、test262）钉在哪组 CPU 上。默认不钉。
- **实现**：分辨率：`-Dgate-run-cpus` → 环境 `ZJS_GATE_RUN_CPUS` → `ZJS_BUILD_CPUS` → 默认空字符串（不钉）。真正的 `taskset` 包在同文件的 `runArtifactOnCpus`，且仅 Linux。
- **所有权 / 错误 / 调用**：返回的切片来自 option/environ/字面量，构建图持有。`addTestGraph` / `addGates` 经 `Ctx.gate_run_cpus` 使用。

### `runArtifactOnCpus` (`build/config.zig:32`)

- **签名**：`pub fn runArtifactOnCpus(b: *std.Build, cpus: []const u8, exe: *std.Build.Step.Compile) *std.Build.Step.Run`。
- **作用**：Linux 上用 `taskset -c <cpus>` 包一层 Run；空列表或非 Linux 退回 `addRunArtifact`。
- **实现**：`addSystemCommand(.{ "taskset", "-c", cpus })` 然后 `addArtifactArg(exe)`，step 名 `run {exe} (cpus …)`。
- **所有权 / 错误 / 调用**：`addTestGraph` 的统一/gc-stress/stress/fast 以及 `addGates` 的 test262 执行使用。放在 `config.zig` 是为了打断 `tests.zig` ↔ `gates.zig` 的互相 `@import`。

### `EngineOptionInputs.withOomInjection` (`build/config.zig:64`)

- **签名**：`pub fn withOomInjection(self: EngineOptionInputs, oom_injection: bool) EngineOptionInputs`。
- **作用**：打开/关上「块堆与 slab 走 `MemoryAccount.backing_allocator`」——OOM 注入面，不是语义开关。
- **实现**：同样的值拷贝。
- **所有权 / 错误 / 调用**：仅 `addTestGraph` 的 `test-oom` 引擎模块传 `true`。

### `addEngineOptions` (`build/config.zig:71`)

- **签名**：`pub fn addEngineOptions(b: *std.Build, in: EngineOptionInputs) *std.Build.Step.Options`。
- **作用**：给一个引擎模块创建**自己的** `addOptions` 对象。
- **实现**：写入 `zjs_enable_opcode_profile`、`zjs_compiler_layout`、`zjs_oom_coverage`、`zjs_oom_injection`、`zjs_force_gc`、`zjs_ownership_audit`、`zjs_gc_roots_diag`。
- **所有权 / 错误 / 调用**：返回的 Options 由构建图持有，经 `addOptions("build_options", …)` / `addImport("build_options", …)` 接到模块。

### `forceLlvmBackendOnDebug` (`build/config.zig:127`)

- **签名**：`pub fn forceLlvmBackendOnDebug(compile: *std.Build.Step.Compile) void`。
- **作用**：Debug 产物强制 LLVM。self-hosted stage2 降不了 `@call(.always_tail)` 和 NMFD `.space` tombstone；也防止将来 aarch64 Debug 默认切 self-hosted 后本地 always_tail 静默坏掉。Release* 不改（它们已经默认 LLVM）。
- **实现**：`if (compile.root_module.optimize == .Debug) compile.use_llvm = true;`。
- **所有权 / 错误 / 调用**：每个引擎 Compile 步创建后立刻调用。无错误。

---

## `build/artifacts.zig`

### `Artifacts` (`build/artifacts.zig:4`)

`addEngineArtifacts` 的返回形状，门禁和测试图要拿的句柄。三对 `*_exe` / `install_*`：`zjs`、`zjs-profile`、`run-test262`。

不出现在这个结构里的产物：公共 `addModule("zjs")`（给下游 `@import("zjs")`，embedding 自建根）、`zjs-size`，以及各 `internal_*_mod`——它们只经由自己的 `b.step` 消费。

### `Cli` (`build/artifacts.zig:13`)

`addCli` 的返回对：`exe` + `install`。不导出。

### `applyHotLayout` (`build/artifacts.zig:18`)

- **签名**：`fn applyHotLayout(b: *std.Build, target: std.Build.ResolvedTarget, exe: *std.Build.Step.Compile) void`。
- **作用**：aarch64+ELF 上把 dispatch Handler 收进 `.text.zjs.op_handlers`。
- **实现**：其它目标不挂链接脚本。
- **所有权 / 错误 / 调用**：仅 `addCli(..., hot_layout=true)`：`zjs` / `zjs-size` / `zjs-profile`。

### `addInternalEngine` (`build/artifacts.zig:26`)

- **签名**：`fn addInternalEngine(ctx: config.Ctx, options: *std.Build.Step.Options, omit_frame_pointer: bool) *std.Build.Module`。
- **作用**：建一份 `src/internal_root.zig` 引擎模块并挂上该产物自己的 options。优化模式一律 `ctx.optimize`。
- **实现**：`createModule` + `addOptions("build_options", options)`。
- **所有权 / 错误 / 调用**：模块由构建图持有。`addEngineArtifacts` 调两次（主引擎、profile）。

### `addCli` (`build/artifacts.zig:42`)

- **签名**：`fn addCli(ctx: config.Ctx, name: []const u8, root_source: []const u8, engine: *std.Build.Module, hot_layout: bool) Cli`。
- **作用**：CLI 可执行 + install：根 `root_source`，`import("zjs")` = `engine`，优化模式 `ctx.optimize`。
- **实现**：`forceLlvmBackendOnDebug`；`hot_layout` 时 `applyHotLayout`。
- **所有权 / 错误 / 调用**：`zjs` / `zjs-size` / `zjs-profile` 用 `src/cli/zjs.zig`；`run-test262` 用 `src/cli/run_test262.zig`。

### `addInstallStep` (`build/artifacts.zig:65`)

- **签名**：`fn addInstallStep(b: *std.Build, name: []const u8, desc: []const u8, install: *std.Build.Step.InstallArtifact) void`。
- **作用**：注册「编并安装」步骤，依赖该 `InstallArtifact`。
- **实现**：`b.step(name, desc).dependOn(&install.step)`。
- **所有权 / 错误 / 调用**：四个 CLI 步骤各调一次。默认 `install` 另依赖 `zjs`。

### `omitFramePointer` (`build/artifacts.zig:70`)

- **签名**：`fn omitFramePointer(optimize: std.builtin.OptimizeMode, keep_frame_pointer: bool) bool`。
- **作用**：ReleaseFast/Small 默认省帧指针（诊断构建除外）；Debug/ReleaseSafe 保留。
- **实现**：`switch` 两臂。
- **所有权 / 错误 / 调用**：仅 `addEngineArtifacts`。

### `addEngineArtifacts` (`build/artifacts.zig:77`)

- **签名**：`pub fn addEngineArtifacts(ctx: config.Ctx) Artifacts`。
- **作用**：创建全部引擎承载 CLI/模块，并注册安装步骤。全部跟随 `-Doptimize`。
- **实现**：按产物分述——
  1. **`zjs` 模块**（`src/root.zig`）。`addModule`，不进返回值。
  2. **`internal_mod`**：`internal_root`，`omit_frame_pointer` 见上。
  3. **`zjs` exe**：CLI import 上述模块，热布局。步骤 `zjs`；默认 `install` 依赖它。
  4. **`zjs-size`**：同一引擎模块的第二安装名，避免后续 `ReleaseSmall` 覆盖已装的 `zjs`。步骤 `zjs-size`。
  5. **`zjs-profile`**：同一优化模式，但 `enable_opcode_profile=true`。步骤 `zjs-profile`。
  6. **`run-test262`**：import `internal_mod`。步骤 `run-test262`。
- **所有权 / 错误 / 调用**：返回的指针由构建图持有。`addTestGraph` / `addPerfSteps` / `addGates` 消费。非法配置在 `build` 里已退出。

**本函数注册的步骤**：`zjs`、`zjs-size`、`zjs-profile`、`run-test262`；并让默认 install 依赖 `zjs`。

---

## `build/tests.zig`

### `TestGraph` (`build/tests.zig:5`)

`addTestGraph` 的返回形状，六个 `*std.Build.Step`：

| 字段 | 步骤 | 说明 |
| --- | --- | --- |
| `test_step` | `test` | 统一套件 |
| `stress_step` | `test-stress` | 长跑压力层。**刻意不挂在 `test_step` 下**：按 `docs/verification-policy.md`，每次改动的收口只跑 `zig build test`，压力层的时间成本归 production / CI / merge-batch 门 |
| `gc_stress_step` | `test-gc-stress` | 同一套件在全部 GC 诊断开关下再跑一遍，约 1 分钟，所以能搭 checkpoint-gate |
| `smoke_step` | `smoke` | 当前 `-Doptimize` 下的 `zjs` + `zjs-profile` |
| `embedding_step` | `test-embedding` | 公共 API 嵌入示例 |
| `check_embedding_step` | `check-embedding` | `embedding_step` 的 sema-only 孪生（公共根能组装、comptime 钉成立），checkpoint-gate 依赖这个而不是再编一次引擎 |

### `addZjsTest` (`build/tests.zig:21`)

- **签名**：`fn addZjsTest(ctx: build_config.Ctx, name: []const u8, root_module: *std.Build.Module, filters: []const []const u8) *std.Build.Step.Compile`。
- **作用**：一份 Debug 强制 LLVM 的 `addTest`，使用 Zig 默认 test runner。
- **实现**：`ctx.b.addTest` + `forceLlvmBackendOnDebug`。不设 `test_runner`。
- **所有权 / 错误 / 调用**：统一套件、smoke、embedding / check-embedding、oom、`check` 都走这里。`test-fast` / `test-stress` / `test-leak-census` 传入非空 `filters`。只有 `test-leak-census` 在返回后改挂 `tools/leak_census_runner.zig`。

### `runUnifiedTests` (`build/tests.zig:36`)

- **签名**：`fn runUnifiedTests(ctx: build_config.Ctx, exe: *std.Build.Step.Compile, gc_stress: bool) *std.Build.Step.Run`。
- **作用**：给统一测试二进制挂一个 Run 步。
- **实现**：`runArtifactOnCpus`。`gc_stress` 时加 `ZJS_GC_STRESS=1`、`ZJS_GC_VERIFY_MINOR=fatal`、`ZJS_MINOR_AUDIT=fatal`。
- **所有权 / 错误 / 调用**：`test` 与 `test-gc-stress` 各调一次；`test-fast` 在有子串时也走这里。

### `addSmokeStep` (`build/tests.zig:50`)

- **签名**：`fn addSmokeStep(ctx: build_config.Ctx, artifacts: artifacts_mod.Artifacts) *std.Build.Step`。
- **作用**：根 `tests/smoke_test.zig` 的冒烟步骤，options 里是被测 CLI 的 install 路径。
- **实现**：写入 `zjs` 与 `zjs-profile` 路径，`smoke_profile_checks=true`。Run 依赖对应 install。
- **所有权 / 错误 / 调用**：`addTestGraph` 调一次，注册 `smoke`。

### `addTestGraph` (`build/tests.zig:71`)

- **签名**：`pub fn addTestGraph(ctx: build_config.Ctx, artifacts: artifacts_mod.Artifacts) TestGraph`。
- **作用**：挂上编辑循环、checkpoint、夜间仪器要用的全部测试 Compile/Run 步。
- **实现**：按注册的步骤分述——

#### 统一套件 `test` / `test-fast` / `test-gc-stress` / `test-stress`

- 根 `src/internal_root.zig`，跟随 `-Doptimize`，自己的 options。Zig 默认 test runner，单进程。
- `-Dtest-filter`：另编一份带 DWARF 的诊断选择。
- `-Dtest-strip` 默认：全量 true、filter 时 false。
- `test-fast`：编译期 `--test-filter`，来自 `b.args`，另加 `zjs.pull_test_modules` 让空匹配失败；无子串则 `addFail`。
- `test-gc-stress`：同一二进制，GC 诊断环境。checkpoint 依赖。stress 测试靠 `SkipZigTest` 自己退出。
- `test-stress`：同一根、编译期 filter `stress.`，`ZJS_RUN_STRESS=1`。merge/production 依赖。

#### smoke

- `smoke`：当前模式的 `zjs` 与 `zjs-profile` 路径，`smoke_profile_checks=true`。`quick-gate` 与 `checkpoint-gate` 都依赖它。

#### leak-census / embedding / oom / check

- `test-leak-census`：同一根，编译期 filter `exec.tests.` + `zjs.leak_census.anchor`，`tools/leak_census_runner.zig` 跑两遍，`ZJS_LEAK_CENSUS=1`。夜间仪器，不是 checkpoint 依赖。
- `test-embedding`：独立公共 `src/root.zig` 模块（不 attest）+ `tests/embedding_examples.zig`，跟随 `-Doptimize`。engine-production-gate 依赖。options 模块引擎与测试根共享（内容相同则 Zig 只生成一个文件，一个文件只能做一个模块根）。
- `check-embedding`：同一 `root_module`，sema-only。checkpoint 用它代替第二次引擎编译。
- `test-oom`：`internal_root` + `withOomInjection(true)`，根 `tests/oom.zig`。跟随 `-Doptimize`。夜间。
- `check`：与统一套件共享 `unified_tests.root_module`，sema-only。**不是门禁**。见 [`docs/testing-graph.md`](../testing-graph.md)。

- **所有权 / 错误 / 调用**：返回 `TestGraph`。`test-fast` 空子串在配置期 `addFail`。

**本函数注册的步骤**：`test`、`test-fast`、`test-gc-stress`、`test-stress`、`smoke`、`test-leak-census`、`test-embedding`、`check-embedding`、`test-oom`、`check`。

---

## `build/perf.zig`

### `addPerfSteps` (`build/perf.zig:4`)

- **签名**：`pub fn addPerfSteps(ctx: config.Ctx, artifacts: artifacts_mod.Artifacts) void`。
- **作用**：挂本地诊断入口。明确隔离于所有验证门禁。
- **实现**：注册以下步骤——
  - `perf-benchmark`：当前 `zjs --perf-json tests/perf/microbench.js`。
- **所有权 / 错误 / 调用**：不返回。失败由各 Run 步非零退出。无门禁 `dependOn` 这些步骤。

---

## `build/gates.zig`

### `addGates` (`build/gates.zig:6`)

- **签名**：`pub fn addGates(ctx: config.Ctx, artifacts: artifacts_mod.Artifacts, test_graph: tests_mod.TestGraph) void`。
- **作用**：把配置签名、test262 和三级 gate 收进图。
- **实现**：

Run 步骤：

- **`test262-check`**：`run-test262 -c test262.conf -d test262/test 0 100000 -R reports/test262-latest -v`，`expectStdOutMatch("Result: 0/")`。check 模式不继承 stdio。`-v` 让失败用例打到 stdout，以免只写进下次绿会覆盖的 log。跟随这次的 `-Doptimize`；发货语料由 mise/CI 传 `-Doptimize=ReleaseFast`。

Gate 聚合：

| 步骤 | 依赖 |
| --- | --- |
| `quick-gate` | `smoke` |
| `checkpoint-gate` | `test` + `test-gc-stress` + `smoke` + `check-embedding`。不跑 test262 / OOM / stress |
| `engine-production-gate` | `test` + stress + **smoke** + **test-embedding** 全跑 + test262。发布调用传 `-Doptimize=ReleaseFast`。 |

- **所有权 / 错误 / 调用**：不返回。mise 以 `-j32` 启动这些 gate，避免 runner 默认 `cpu_count-1` 把互不依赖的编译内联到主线程。失败即步骤失败。

**本函数注册的步骤**：`test262-check`、`quick-gate`、`checkpoint-gate`、`engine-production-gate`。

---

## 覆盖核对

- 清单函数数: 18（`build.zig` 1 + `build/artifacts.zig` 6 + `build/config.zig` 5 + `build/gates.zig` 1 + `build/perf.zig` 1 + `build/tests.zig` 4）
- 本文标题覆盖的 `fn`：`build`、`gateRunCpus`、`runArtifactOnCpus`、`withOomInjection`、`addEngineOptions`、`forceLlvmBackendOnDebug`、`applyHotLayout`、`addInternalEngine`、`addCli`、`addInstallStep`、`omitFramePointer`、`addEngineArtifacts`、`addZjsTest`、`runUnifiedTests`、`addSmokeStep`、`addTestGraph`、`addPerfSteps`、`addGates`（18）
- 无函数文件：无
- 未覆盖: 无
