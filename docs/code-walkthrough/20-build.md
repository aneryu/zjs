# 20 — 构建图（`build.zig` / `build/*.zig`）

本册覆盖构建入口与 `build/` 下每一个 `pub fn`、每一个 `b.step` 注册，以及无函数文件里的类型与表。权威仍是源码；门禁义务见 [`docs/verification-policy.md`](../verification-policy.md)，步骤关系见 [`docs/testing-graph.md`](../testing-graph.md)。

Zig 钉 0.16.0。`build.zig` 把图种子钉成 `0`（可用 `-Dzjs_test_seed` 覆盖），这样测试 runner 参数稳定、磁盘缓存可命中。

## 文件地图

| 文件 | 职责 |
| --- | --- |
| [`build.zig`](../../build.zig) | 读 CLI 选项、算配置签名、组装 `Ctx`，依次调用四个 `add*` |
| [`build/config.zig`](../../build/config.zig) | `Ctx`、签名字符串、每模块一份 `addOptions`、Debug 强制 LLVM、Run 步 CPU 列表 |
| [`build/artifacts.zig`](../../build/artifacts.zig) | 引擎模块与 CLI 产物：`zjs` / `zjs-size` / `zjs-profile` / `zjs-dev` / `run-test262*` / `gen-abi-header` |
| [`build/tests.zig`](../../build/tests.zig) | 统一套件、分片、scoped 目标、`check`、smoke、OOM、embedding、leak-census |
| [`build/perf.zig`](../../build/perf.zig) | 诊断用性能步骤；**不是**门禁 |
| [`build/profiles.zig`](../../build/profiles.zig) | `perf-runtime-profiles` 的 opcode 精确钉表（无函数） |
| [`build/gates.zig`](../../build/gates.zig) | `quick-gate` / `checkpoint-gate` / `merge-gate` / `engine-production-gate`、test262、gate-smoke |

调用顺序（`build` 末尾）：

```
artifacts.addEngineArtifacts(ctx)
tests.addTestGraph(ctx, artifacts)
perf.addPerfSteps(ctx, artifacts)
gates.addGates(ctx, artifacts, test_graph)
```

---

## 类型（`build/config.zig`）

### `Ctx` (`build/config.zig:6`)

传给每个 `add*` 的共享袋：同一套 option 对象、签名三元组、解析后的 target/optimize、Run 步 CPU 列表。存在的理由是「每个 helper 看到的是同一批对象」——否则 `artifacts.zig` / `tests.zig` / `gates.zig` 各自重建一份 `Step.Options`，同名选项会变成互不相等的缓存身份。字段：

| 字段 | 含义 |
| --- | --- |
| `b` | `*std.Build` |
| `target` / `optimize` | 顶层 `-Dtarget` / `-Doptimize` |
| `engine_inputs` | 一份选项形状；各产物只改 `expect_config`（或 OOM 的 `oom_injection`） |
| `settings` | 图对配置的信念（喂 `configSignature`） |
| `expect_config` | 跟随 `-Doptimize` 的产物用（公共模块、统一套件、`zjs-size`） |
| `expect_config_debug` / `expect_config_fast` | 钉 Debug / ReleaseFast 的产物用 |
| `engine_options*` | 三份 `Step.Options`，禁止跨 Debug/Release 复用同一对象 |
| `gate_run_cpus` | Run 步 `taskset` 列表；空字符串 = 不钉 |

### `ConfigSettings` (`build/config.zig:48`)

QCP-1 配置字段，顺序与 `configSignature` 及 `src/config_signature.zig` 三方锁步——后两者是对同一字符串的两次独立计算，**它们不一致正是签名门要抓的东西**。五个字段：

| 字段 | 含义 |
| --- | --- |
| `compiler` | 编译器管线代号（当前恒为 `v2`） |
| `layout` | 字节码/对象布局代号 |
| `optimize` | `std.builtin.OptimizeMode`。在这里不是性能旋钮，而是「`std.debug.assert` 是否活着、safety 检查是否 trap、ReleaseFast 是否真的把校验路径删了」的证据字段：这个字段加进来之前，父进程要 ReleaseSafe 而子进程编了 Debug，三元组 compiler/layout/repr 完全相同，门禁读成绿 |
| `force_gc` | 强制 GC 的诊断开关 |
| `ownership_audit` | 所有权审计开关 |

结构体里**没有** `repr` 与 `gc_layout` 字段：8 字节 NaN-boxing 已删、Object 布局已定终态，`configSignature` 把它们写成字面量 `repr=tagged,gc_layout=obj64_m`；引擎那半边则从 `@sizeOf(JSValue)` 反推，留着这两个分量是为了让旧 v2 签名保持语义、也让负向漂移检查还有字段可证伪。

### `EngineOptionInputs` (`build/config.zig:129`)

每个引擎模块收到的 options 形状——一个形状，所以某个模块不可能被悄悄喂一个子集。字段：

| 字段 | 含义 |
| --- | --- |
| `enable_opcode_profile` | 编进每 opcode 分发 scope；只有 `zjs-profile` 打开 |
| `compiler_layout` | 布局代号，透传给引擎 |
| `expect_config` | 该产物应当 attest 的签名字符串——**唯一**允许产物间不同的字段（见 `withExpect`） |
| `oom_coverage` | OOM 覆盖层开关 |
| `oom_injection` | 把 block heap 的 superblock/extent 后备与小对象 slab arena 的补给改走 `MemoryAccount.backing_allocator`，让 tracing 收集器挪进这些池子的分配对 `std.testing.checkAllAllocationFailures` 与 fail-at-N 分配器可见。这是 OOM 层的注入面，不改语义：字节记账与内存上限行为两边一样 |
| `force_gc` / `ownership_audit` | 与 `ConfigSettings` 同名字段对应 |
| `dossier_layout_pad` | 布局 dossier 的填充字节数 |
| `gc_roots_diag` | R3 根诊断构建；默认 false，只有 diag 产物开（它同时决定 `omit_frame_pointer`） |

`oom_injection` 默认 `false`：**包括** `zig build test`。它曾经以 `builtin.is_test` 为键，结果改掉了整份单测的分配器拓扑，每个测试量的都是发货构建根本没有的堆；现在只有 `test-oom` 这一步打开它。

---

## `build.zig`

### `build` (`build.zig:8`)

- **签名**：`pub fn build(b: *std.Build) void`。
- **作用**：读构建选项、钉图种子、算出三份配置签名期望、装配 `Ctx`，再把产物/测试/perf/门禁挂进同一张图。
- **实现**：
  1. `standardTargetOptions` / `standardOptimizeOption`。
  2. `-Dzjs_test_seed`（默认 0）写入 `b.graph.random_seed`，抵消 Zig CLI 随机 `--seed` 对缓存的破坏。
  3. 开关：`zjs_enable_opcode_profile`、`zjs_compiler_layout`（只允许 `short`/`plain`，否则 `exit(1)`）、`zjs_oom_coverage`、`zjs_force_gc`、`zjs_ownership_audit`、`zjs_gc_roots_diag`、`zjs_dossier_layout_pad`。
  4. `compiler_name` 写死 `"v2"`（唯一编译器；签名里仍保留该字段以便负向漂移检测）。
  5. 用 `ConfigSettings` 算 `expect_config`；若有 `-Dzjs_expect_config`，只做形状检查（必须以 `zjs-config-` 开头且含 `:`），**不**在这里和自身信念比对——那会让「子 `zig build` 解析错模式」变成永远同意。值检查交给产物里的 `config_signature.attest`。
  6. 三份期望：跟随 `-Doptimize` 的原文、钉 Debug、钉 ReleaseFast（`pinnedExpectedConfig` 只替换 `,optimize=` 段）。
  7. 三份 `addEngineOptions`（follow / fast / dev）。
  8. 填 `Ctx.gate_run_cpus = config.gateRunCpus(b)`，依次 `addEngineArtifacts` / `addTestGraph` / `addPerfSteps` / `addGates`。
- **所有权 / 错误 / 调用**：不返回 error；非法 layout / 畸形签名 `std.process.exit(1)`。调用方是 Zig 构建 runner。不分配引擎堆。

注册的顶层步骤全部由四个 `add*` 发出，见下列各节。`b.getInstallStep()` 依赖生产 `zjs` 的 install。

---

## `build/config.zig` 函数

### `gateRunCpus` (`build/config.zig:36`)

- **签名**：`pub fn gateRunCpus(b: *std.Build) []const u8`。
- **作用**：决定图里 **Run** 步（测试分片、test262、gate-smoke）钉在哪组 CPU 上。`zig build` 本身由 mise 钉在编译池（默认大核 `5-8,15-18`）；Run 步需要更多核。
- **实现**：分辨率：`-Dgate-run-cpus` → 环境 `ZJS_GATE_RUN_CPUS` → `ZJS_BUILD_CPUS`（操作员收窄编译池时 run 池跟着收）→ 默认 `0-8,10-18`（躲开测量核 9/19）。空字符串表示不钉。真正的 `taskset` 包在 `gates.runArtifactOnCpus`，且仅 Linux。
- **所有权 / 错误 / 调用**：返回的切片来自 option/environ/字面量，构建图持有。`addTestGraph` / `addGates` 经 `Ctx.gate_run_cpus` 使用。

### `configSignature` (`build/config.zig:79`)

- **签名**：`pub fn configSignature(b: *std.Build, settings: ConfigSettings) []const u8`。
- **作用**：图侧独立算出与 `src/config_signature.zig` **同一套**确定性字符串。两边不一致时产物 **编译失败**（`attest`），而不是门禁绿了却跑了另一配置。
- **实现**：`b.fmt` 出 `zjs-config-v3:compiler={s},layout={s},repr=tagged,gc_layout=obj64_m,optimize={s},force_gc={on|off},ownership_audit={on|off}`。`repr`/`gc_layout` 不是选项：NaN-box 与旧 Object 头已删，但签名必须说出「这颗二进制是什么表示」，负向漂移才有字段可证伪。引擎侧 `repr` 来自 `@sizeOf(JSValue)`，不是字面量。
- **所有权 / 错误 / 调用**：分配在 builder arena。直接调用方只有 `build`（无 `-Dzjs_expect_config` 时）与 `pinnedExpectedConfig`；sidecar `zjs.config-signature` 写的是 `expect_config_fast`，即 `pinnedExpectedConfig` 的结果。

### `pinnedExpectedConfig` (`build/config.zig:110`)

- **签名**：`pub fn pinnedExpectedConfig( b: *std.Build, override: ?[]const u8, settings: ConfigSettings, mode: std.builtin.OptimizeMode, ) []const u8`。
- **作用**：给**钉死优化模式**的产物（`zjs`/`run-test262` = ReleaseFast，`zjs-dev`/scoped tests = Debug）生成期望签名：其它字段跟调用方走，只替换 `optimize=`。
- **实现**：无 override 时用 `settings` 但 `optimize=mode` 调 `configSignature`。有 override 时找 `,optimize=` … 下一个 `,`，把值换成 `@tagName(mode)`。畸形/过期 override **故意原样放过**，让产物 `attest` 报出版本和字段，而不是在 build.zig 里用「自己的意见」拒掉。
- **所有权 / 错误 / 调用**：跟随 `-Doptimize` 的产物**不**走这里（必须拿到调用方原文，子构建解析成 Debug 而父要 ReleaseSafe 才会红）。`build.zig` 为 Debug/Fast 各调一次。

### `EngineOptionInputs.withExpect` (`build/config.zig:153`)

- **签名**：`pub fn withExpect(self: EngineOptionInputs, expect_config: []const u8) EngineOptionInputs`。
- **作用**：复制一份 inputs，只改 `expect_config`，供钉模式产物使用。
- **实现**：`var out = self; out.expect_config = expect_config; return out;`。
- **所有权 / 错误 / 调用**：值类型拷贝。`build`、`addEngineArtifacts`（profile）、`addTestGraph`（scoped / embedding）调用。

### `EngineOptionInputs.withOomInjection` (`build/config.zig:159`)

- **签名**：`pub fn withOomInjection(self: EngineOptionInputs, oom_injection: bool) EngineOptionInputs`。
- **作用**：打开/关上「块堆与 slab 走 `MemoryAccount.backing_allocator`」——OOM 注入面，不是语义开关。
- **实现**：同样的值拷贝。
- **所有权 / 错误 / 调用**：仅 `addTestGraph` 的 `test-oom` 引擎模块传 `true`。

### `addEngineOptions` (`build/config.zig:166`)

- **签名**：`pub fn addEngineOptions(b: *std.Build, in: EngineOptionInputs) *std.Build.Step.Options`。
- **作用**：给一个引擎模块创建**自己的** `addOptions` 对象。跨 Debug/Release 复用同一对象会让测试二进制 attest 错 `optimize`（testing-graph 规则 C）。
- **实现**：写入 `zjs_enable_opcode_profile`、`zjs_compiler_layout`、`zjs_expect_config`、`zjs_oom_coverage`、`zjs_oom_injection`、`zjs_force_gc`、`zjs_ownership_audit`、`zjs_dossier_layout_pad`、`zjs_gc_roots_diag`。
- **所有权 / 错误 / 调用**：返回的 Options 由构建图持有，经 `addOptions("build_options", …)` / `addImport("build_options", …)` 接到模块。

### `forceLlvmBackendOnDebug` (`build/config.zig:185`)

- **签名**：`pub fn forceLlvmBackendOnDebug(compile: *std.Build.Step.Compile) void`。
- **作用**：Debug 产物强制 LLVM。self-hosted stage2 降不了 `@call(.always_tail)` 和 NMFD `.space` tombstone；也防止将来 aarch64 Debug 默认切 self-hosted 后本地 always_tail 静默坏掉。Release* 不改（它们已经默认 LLVM）。
- **实现**：`if (compile.root_module.optimize == .Debug) compile.use_llvm = true;`。
- **所有权 / 错误 / 调用**：每个引擎 Compile 步创建后立刻调用。无错误。

---

## `build/artifacts.zig`

### `Artifacts` (`build/artifacts.zig:4`)

`addEngineArtifacts` 的返回形状，门禁和测试图要拿的句柄：

- `engine_mod`：`b.addModule("zjs", ...)` 建的**公共**嵌入模块（根 `src/root.zig`，跟随 `-Doptimize`）——唯一一个用 `addModule` 而非 `createModule` 的，因为它是给下游 `@import("zjs")` 用的命名模块。
- `internal_fast_mod`：ReleaseFast 的 `src/internal_root.zig`，CLI 与 `run-test262` 共用。
- 五对 `*_exe` / `install_*`：`zjs`、`zjs-profile`、`zjs-dev`、`run-test262`、`run-test262-dev`（每个 exe 配一个 `InstallArtifact`）。

不出现在这个结构里的产物：`zjs-size`、`gen-abi-header`，以及 profile/dev 那几个 `internal_*_mod` 模块——它们只经由自己的 `b.step` 消费，没有下游要拿句柄。

### `addEngineArtifacts` (`build/artifacts.zig:19`)

- **签名**：`pub fn addEngineArtifacts(ctx: config.Ctx) Artifacts`。
- **作用**：创建全部引擎承载 CLI/模块，并注册安装步骤。生产 `zjs` **永远** ReleaseFast；体积实验走独立 `zjs-size`。
- **实现**：按产物分述——
  1. **`zjs` 模块**（`src/root.zig`，跟随 `-Doptimize`，`link_libc`，options = follow）。公共嵌入面。
  2. **`internal_fast_mod`**（`src/internal_root.zig`，ReleaseFast）。`omit_frame_pointer = !gc_roots_diag`：R3 根普查要帧指针给 native 帧链命名，诊断构建不发货。
  3. **`zjs` exe**：CLI `src/cli/zjs.zig` import 上述 fast 模块。aarch64+ELF 用 `src/exec/tail_hot_layout_aarch64.ld` 把 dispatch handler 收进 `.text.zjs.op_handlers`。install 时写入 sidecar `zig-out/bin/zjs.config-signature`（图的 Fast 期望）。步骤名 `zjs`；默认 `install` 依赖它。
  4. **`zjs-size`**：内部模块和 CLI **都**跟随 `-Doptimize`，期望签名原文。缓存身份与生产 `zjs` 分离。步骤 `zjs-size`。
  5. **`zjs-profile`**：Fast 引擎但 `enable_opcode_profile=true`（热表 comptime 包一层，见 `exec/vm_profile.zig`）。默认 `zjs` 不带 profiling 代码。同 L-1 linker script。步骤 `zjs-profile`。
  6. **`zjs-dev`**：Debug `internal_root` + Debug CLI。内循环 `smoke-dev` / `quick-gate` 用，避免每次编辑编 Fast 整引擎。步骤 `zjs-dev`。
  7. **`gen-abi-header`**：Debug exe `src/abi/gen_header.zig`，Run 步 `cwd=.`、`has_side_effects=true`（改 checked-in `src/abi/fun_native_abi.h`）。步骤 `gen-abi-header`。`check_deps.js` 把它登记为构建图根。
  8. **`run-test262`**：Fast，`src/cli/run_test262.zig` import `internal_fast_mod`。步骤 `run-test262`。
  9. **`run-test262-dev`**：Debug 孪生。步骤 `run-test262-dev`。
- **所有权 / 错误 / 调用**：返回的指针由构建图持有。`addTestGraph` / `addPerfSteps` / `addGates` 消费。非法配置在 `build` 里已退出。

**本函数注册的步骤**：`zjs`、`zjs-size`、`zjs-profile`、`zjs-dev`、`gen-abi-header`、`run-test262`、`run-test262-dev`；并让默认 install 依赖 `zjs`。

---

## `build/tests.zig`

### `TestGraph` (`build/tests.zig:6`)

`addTestGraph` 的返回形状，七个 `*std.Build.Step`：

| 字段 | 步骤 | 说明 |
| --- | --- | --- |
| `test_step` | `test` | 统一套件 |
| `stress_step` | `test-stress` | 长跑压力层。**刻意不挂在 `test_step` 下**：按 `docs/verification-policy.md`，每次改动的收口只跑 `zig build test`，压力层的时间成本归 production / CI / merge-batch 门 |
| `gc_stress_step` | `test-gc-stress` | 同一套件在全部 GC 诊断开关下再跑一遍，约 1 分钟，所以能搭 checkpoint-gate |
| `smoke_step` / `smoke_dev_step` | `smoke` / `smoke-dev` | Fast 与 Debug 两条冒烟 |
| `embedding_step` | `test-embedding` | 公共 API 嵌入示例 |
| `check_embedding_step` | `check-embedding` | `embedding_step` 的 sema-only 孪生（公共根能组装、comptime 钉成立），checkpoint-gate 依赖这个而不是再编一次 Debug 引擎 |

### `addTestGraph` (`build/tests.zig:23`)

- **签名**：`pub fn addTestGraph(ctx: build_config.Ctx, artifacts: artifacts_mod.Artifacts) TestGraph`。
- **作用**：挂上编辑循环、checkpoint、夜间仪器要用的全部测试 Compile/Run 步。
- **实现**：按注册的步骤分述——

#### 统一套件 `test` / `test-fast` / `test-gc-stress` / `test-stress`

- `addTest` 根 `src/all_tests.zig`，跟随 `-Doptimize`，自己的 `test_options`（**不**与 scoped Debug 共享）。
- `-Dtest-filter`：另编一份带 DWARF 的单进程诊断选择。
- `-Dtest-shards` 默认 16；有 filter 或显式 0/1 则 1。分片 Run 走 `runArtifactOnCpus`，参数 `--skip-prefix tests.stress.` 与 `--shard i/N`，`captureStdErr` 以免占 stderr 锁把分片串行化。
- `-Dtest-strip` 默认：全量 true、filter 时 false。
- test_runner = `tools/timing_test_runner.zig`。
- `addIncludePath(src)` 给 FNABI `@cImport`。
- `test-fast`：同一二进制加 `--require-tests --skip-prefix tests.stress. --filter`，后面接 `b.args`。换子串不改编译产物。
- `test-gc-stress`：同一二进制，环境 `ZJS_GC_STRESS=1`、`ZJS_GC_VERIFY_MINOR=fatal`、`ZJS_MINOR_AUDIT=fatal`，同样分片。checkpoint 依赖。
- `test-stress`：同一二进制 `--only-prefix tests.stress. --require-tests`，单进程。merge/production 依赖。

#### smoke

- `smoke`：根 `src/tests/smoke_test.zig`，options 里是 Fast `zjs` 与 `zjs-profile` 路径，`smoke_profile_checks=true`。依赖两份 install。
- `smoke-dev`：同一测试根，路径指向 `zjs-dev`，profile 路径空、`smoke_profile_checks=false`。`quick-gate` 只依赖它。

#### scoped 目标

本地 `ScopedTestConfig`（`build/tests.zig:254`，非 pub）表驱动：

| 步骤 | 根 | filter |
| --- | --- | --- |
| `test-core` | `src/core_tests.zig` | `tests.core.` |
| `test-parser` | `src/parser_tests.zig` | `tests.parser.` |
| `test-bytecode` | `src/bytecode_tests.zig` | `tests.bytecode.` |
| `test-exec` | `src/exec_tests.zig` | `tests.exec.` |
| `test-builtins` | `src/builtins_tests.zig` | `tests.builtins.` |
| `test-runtime` | `src/runtime_tests.zig` | `runtime.` |
| `test-runner` | `src/runner_tests.zig` | `cli.run_test262` |
| `test-compiler` | `src/compiler_tests.zig` | `compiler.` |

共用一份 Debug `internal_root` 模块 + `scoped_test_options`（期望是 Debug 签名）。每个 `addRunArtifact` 带 `--require-tests`（空选择失败）。原先 `ScopedTestConfig` 还有个 `needs_plugin_fixtures` 字段（只有 `test-runtime` 置 true）与一处 `if (config.needs_plugin_fixtures) {}` 空分支——插件加载器已删，两者都不产生任何效果，已一并清理。

另：`gc-representation-snapshot` 用同一 Debug 引擎模块编 `tools/gc/representation_snapshot.zig`。

#### leak-census / embedding / oom / check

- `test-leak-census`：根 `src/leak_census_tests.zig`，`--require-tests --repeat 2 --leak-census`。夜间仪器，不是 checkpoint 依赖。
- `test-embedding`：独立 Debug 公共 `src/root.zig` 模块（不 attest）+ `src/embedding_tests.zig`，filter `tests.embedding_examples.`。engine-production-gate 依赖。options 模块引擎与测试根共享（内容相同则 Zig 只生成一个文件，一个文件只能做一个模块根）。
- `check-embedding`：同一 `root_module`，sema-only（没人消费二进制 → `-fno-emit-bin`）。checkpoint / merge 用它代替第二次 Debug 引擎编译。
- `test-oom`：`internal_root` + `withOomInjection(true)`，根 `src/tests/oom.zig`。跟随 `-Doptimize`。夜间。
- `check`：与统一套件共享 `unified_tests.root_module`，sema-only。**不是门禁**，没有任何 `*-gate` 依赖它。证明 comptime 断言（签名、opcode ledger、FNABI `@cImport`）；不证明 LLVM lowering 或任何行为。

- **所有权 / 错误 / 调用**：返回 `TestGraph`。空 filter 由 runner `--require-tests` 失败。非法 shard 数被折成 1。

**本函数注册的步骤**：`test`、`test-fast`、`test-gc-stress`、`test-stress`、`smoke`、`smoke-dev`、`gc-representation-snapshot`、八个 `test-*` scoped、`test-leak-census`、`test-embedding`、`check-embedding`、`test-oom`、`check`。

---

## `build/profiles.zig`

无函数。`ProfileConfig`（`build/profiles.zig:1`）描述一条运行时 profile：步骤名 `name`、描述 `desc`、脚本名 `script`、期望 stdout、opcode 精确 max（`expect_opcodes`），以及 `expect_opcode_mins`（字段默认 `&.{}`；凡是钉了 max 的 profile 都配了同样一份 min——全零 profile 不得通过，2026-07-31 回归就是 `0 <= max` 真空）。

`runtime_profiles` 数组（`build/profiles.zig:12`）当前 9 条，全部按 2026-07-31 总 dispatch 计数（D0）重校准：

| `name`（也是 `zig build` 步骤名） | 脚本 | 钉的要点 |
| --- | --- | --- |
| `perf-uri-profile` | `uri_decode_4byte` | `get_var=988211` 等 |
| `perf-uri-component-profile` | `uri_component_decode_4byte` | 同 URI 形状 |
| `perf-prop-global-profile` | `prop_read_global_mono` | `get_field=1000000` |
| `perf-proto-global-profile` | `proto_read_global` | 同 get_field 形状 |
| `perf-prop-poly3-profile` | `prop_read_poly3_global` | `get_array_el`+`get_field`+`mod` |
| `perf-call2-global-profile` | `call2_loop_global` | `call2=1000000` |
| `perf-closure-call-global-profile` | `closure_call_loop_global` | 无 call2（闭包） |
| `perf-string-loop-profile` | `string_loop` | 一长串精确计数 |
| `perf-empty-loop-profile` | `empty_loop` | 无 opcode 钉（只跑通） |

`addPerfSteps` 对每条 `inline for` 出一个步骤，并汇总到 `perf-runtime-profiles`。

---

## `build/perf.zig`

### `addPerfSteps` (`build/perf.zig:5`)

- **签名**：`pub fn addPerfSteps(ctx: config.Ctx, artifacts: artifacts_mod.Artifacts) void`。
- **作用**：挂诊断/测量脚手架。明确隔离于所有验证门禁。
- **实现**：注册以下步骤——
  - `perf-jetstream-shell`：ReleaseFast `tools/perf/jetstream3/shell.zig` import `internal_fast_mod`。
  - `perf-benchmark`：生产 `zjs --perf-json tests/perf/microbench.js`。
  - `perf-bench-v8`：`python3 tools/perf/bench_v8/run_local.py` + zjs 产物。官方对比用测量机上的 `run_benchv8_compare.py`，永不进 CI。
  - `perf-runtime-profiles` 及上表各 `perf-*-profile`：`node tools/perf/run_runtime_profile.js` 打 `zjs-profile`，`--expect-total-opcodes-min 1` 防真空，再加每条 max/min。依赖 `install_zjs` 与 `install_zjs_profile`。
  - `perf-hotpath`：`bun tools/compare/run_microbench.js --suite hotpath --zjs-only`。
  - `perf-measurement-contract`：`bun tools/compare/test_measurement_contract.js`（无二进制、无测量锁）。
  - `perf-native-callback`：同一 microbench runner，`--suite native-callback --interleaved`。
  - `perf-same-runtime`：编 `tools/perf/same_runtime/zjs_same_runtime.zig`。
  - `perf-same-runtime-all`：再跑 `tools/perf/same_runtime/build_qjs_harness.sh`。
  - `perf-direct-build` / `perf-direct`：`zjs-direct-bench` + `tools/perf/direct/run_direct.sh`（可把 `b.args` 转下去）。
  - `perf-native-boundary-build`：`tools/perf/native_boundary/zjs_boundary_bench.zig`，只编，采样器另驱。
- **所有权 / 错误 / 调用**：不返回。失败由各 Run 步非零退出。无门禁 `dependOn` 这些步骤。

---

## `build/gates.zig`

### `runArtifactOnCpus` (`build/gates.zig:10`)

- **签名**：`pub fn runArtifactOnCpus(b: *std.Build, cpus: []const u8, exe: *std.Build.Step.Compile) *std.Build.Step.Run`。
- **作用**：Linux 上用 `taskset -c <cpus>` 包一层 Run，让门禁 Run 步用得上比编译池更多的核；空列表或非 Linux 退回 `addRunArtifact`。
- **实现**：`addSystemCommand(.{ "taskset", "-c", cpus })` 然后 `addArtifactArg(exe)`，step 名 `run {exe} (cpus …)`。
- **所有权 / 错误 / 调用**：`addTestGraph` 的统一/gc-stress/stress/fast 分片、`addGates` 的 test262 执行使用。

### `addGates` (`build/gates.zig:18`)

- **签名**：`pub fn addGates(ctx: config.Ctx, artifacts: artifacts_mod.Artifacts, test_graph: tests_mod.TestGraph) void`。
- **作用**：把架构检查、配置签名、test262、macro 完成性、fixed-work smoke 和四级 gate 收进图。
- **实现**：

架构检查（`addSystemCommand` + node）：

| 命令 | 何时跑 |
| --- | --- |
| `tools/architecture/check_deps.js` | checkpoint / merge / production |
| `check_oom_panics.js` | 同上 |
| `check_borrowed_atoms.js` | 同上 |
| `check_gc_slots.js` | 同上 |
| `check_compiler_stage_boundaries.js --source-only` | checkpoint（只要源码 `noinline`） |
| `check_compiler_stage_boundaries.js <zjs-bin>` | merge / production（再 `nm` 独立符号） |

其它 Run：

- **`test262-check`**：`run-test262 -c test262.conf -d test262/test 0 100000 -R reports/test262-latest -v`，`expectStdOutMatch("Result: 0/")`。check 模式不继承 stdio，避免占 stderr 锁与 smoke 串行。`-v` 让失败用例打到 stdout，以免只写进下次绿会覆盖的 log。
- **`macro-check`**：`python3 tools/perf/bench_v8/check_completes.py` + zjs，环境 `ZJS_GC_ARENA_AUDIT=1`。断言 vendored bench-v8 **跑完**（不是分数）——test262 太短，minor 晋升/写屏障几乎摸不到。**不挂在任何聚合步骤上**（`checkpoint-gate` / `merge-gate` / `engine-production-gate` 都不 `dependOn` 它）：聚合门上同一批 vendored workload 已由 `gate-smoke` 在图内跑，再并一份会把最长边直接翻倍；需要九个基准的全量扫时手动 `zig build macro-check`。源码注释已写明这条取舍。
- **`config-signature-check`**：`zjs --print-config-signature` 必须等于 Fast 期望 + `\n`。`smoke` 也依赖它。
- **`gate-smoke`**：`tools/perf/gate_smoke.sh` + 安装好的 zjs；位置参数 corpus（默认 `/tmp/gcgap-fixed`）、占位 CPU `5`、普通 run 次数（默认 1，`-Dgate-smoke-runs`）。并行 CPU 来自 `-Dgate-smoke-cpus` 否则 run 池，写入 `ZJS_GATE_PARALLEL_CPUS`。`expectStdOutMatch("fixed-work smoke: all clean")`。

Gate 聚合：

| 步骤 | 依赖 |
| --- | --- |
| `quick-gate` | `smoke-dev` |
| `checkpoint-gate` | `test` + `test-gc-stress` + `smoke-dev` + 源码侧架构五项 + `check-embedding`。不编 Fast `zjs`，不跑 test262 / OOM / stress |
| `merge-gate` | `test` + gc-stress + **stress** + smoke-dev + check-embedding + 架构（含 nm）+ config-signature + test262-check + gate-smoke。2 Fast（zjs、run-test262）+ 2 Debug（unified、zjs-dev）引擎编译 |
| `engine-production-gate` | `test` + stress + **smoke**（Fast+profile 合同）+ **test-embedding** 全跑 + 架构五项（stage boundaries 带 nm）+ test262。比 merge 多 profile smoke 与第二次 Debug 嵌入编译；**不依赖** gc-stress、gate-smoke、smoke-dev（config-signature 经 `smoke` 间接进来） |

- **所有权 / 错误 / 调用**：不返回。mise 以 `-j32` 启动这些 gate，避免 runner 默认 `cpu_count-1` 把互不依赖的 Fast 编译内联到主线程。失败即步骤失败。

**本函数注册的步骤**：`test262-check`、`macro-check`、`config-signature-check`、`quick-gate`、`checkpoint-gate`、`gate-smoke`、`merge-gate`、`engine-production-gate`。

---

## 覆盖核对

- 清单函数数: 13（`build.zig` 1 + `build/artifacts.zig` 1 + `build/config.zig` 7 + `build/gates.zig` 2 + `build/perf.zig` 1 + `build/tests.zig` 1）
- 本文标题覆盖的 `fn`：`build`、`gateRunCpus`、`configSignature`、`pinnedExpectedConfig`、`withExpect`、`withOomInjection`、`addEngineOptions`、`forceLlvmBackendOnDebug`、`addEngineArtifacts`、`addTestGraph`、`addPerfSteps`、`runArtifactOnCpus`、`addGates`（13）
- 无函数文件：`build/profiles.zig`（`ProfileConfig` + `runtime_profiles`）
- 未覆盖: 无
