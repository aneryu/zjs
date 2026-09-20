# 01 — `src/root.zig`：CLI / run-test262 门面

生产 `zjs` 与 `run-test262` 编的是 `src/internal_root.zig`，经 `public_api` 碰到本文件。下游 `@import("zjs")` 直接以本文件为根。它再导出那两个程序用到的类型，并实现 CLI 安装的 `scriptArgs`；不再包装 core Object、Buffer 借用、job 排空或第二套值构造命名空间。

`core` / `exec` 不作为这里的公开命名空间导出。`CallSite` / `PropertySite` / `NativeBinding` / `zjs.value` / `zjs.object` / `zjs.module` / `zjs.job` 已从本文件删除。

---

## 类型与 re-export

| 名字 | 含义 |
| --- | --- |
| `runtime` | `event_loop.zig`：宿主事件循环（`EventLoop` / `runUntilIdle`）。 |
| `JSRuntime` / `JSContext` / `JSValue` | `JSContext` 来自 `js_context.zig`；其余来自 core。 |
| `GCStats` / `GCPauseDistribution` / `RuntimeOptions` / `RuntimeMemoryUsage` / `OpcodeProfile` | 统计与选项。CLI `--gc-stats` / `--perf-json` / `--profile-opcodes` 用。 |
| `default_stack_size` / `default_gc_threshold` | 默认限额。 |
| `opcode_profile_build_enabled` | `-Dzjs_enable_opcode_profile`。CLI 在 false 时对 `--profile-opcodes` fail-close。 |
| `native` | `src/native.zig`。 |
| `host.defineScriptArgs` | 在 global 上定义 `scriptArgs` 字符串数组。 |
| `context.Options` / `EvalMode` / `EvalOptions` / `EvalTiming` | 从 core 再导出的求值选项。 |

---

## `activateOpcodeProfile` (`src/root.zig`)

- **签名**：`pub fn activateOpcodeProfile(profile: ?*OpcodeProfile) ?*OpcodeProfile`。
- **作用**：给剖析器装 opcode 名提供者并激活缓冲区。
- **实现**：`zjs_core.profile.setOpcodeNameProvider(zjs_exec.opcodeName)`，再 `zjs_core.profile.activate`。
- **所有权 / 错误 / 调用**：返回此前的线程局部活动 profile，供调用方恢复。此包装不检查 `opcode_profile_build_enabled`。

---

## `host.defineScriptArgs` (`src/root.zig`)

- **签名**：`pub fn defineScriptArgs(ctx: *JSContext, args: []const []const u8) !void`。
- **作用**：在 global 上定义 `scriptArgs` 字符串数组。CLI `-e` 与文件模式都走这里。
- **实现**：空切片安装延迟初始化的空数组属性（`defineEmptyArrayAutoInitProperty`）；非空切片先创建数组、逐项 `ctx.createString` 并设置 length，再定义全局属性。数组原型优先取 realm 缓存，缺失时查找全局 `Array.prototype`。
- **所有权 / 错误 / 调用**：全局属性和数组元素使用 writable/enumerable/configurable 数据属性。获取全局对象、分配及属性定义的错误向上传播。

---

## 不再从本文件导出

值构造用 `JSValue.int32` 等；句柄用 `JSRuntime.enterHandleScope` / `createPersistentValue`；字节存储用 `JSValue.Bytes.Store`；模块图与 job 排空分别走 `exec/module_graph.zig` 与 `JSContext.runJobs`。`run-test262` 本身通过 `internal_root` 使用 `core` / `exec` / `parser` / `test262_host`，不经过这些已删包装。
