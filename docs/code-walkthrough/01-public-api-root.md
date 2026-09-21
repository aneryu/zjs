# 01 — `src/root.zig`：唯一引擎模块

`@import("zjs")` 的根。嵌入方用 `Runtime` / `Context` / `Value` / `Call` / `EventLoop`。生产 `zjs`、`run-test262`、OOM 测试和引擎 Zig 单测都编这个文件。CLI 测试把它当独立 `zjs` 模块 import。它再导出仓内宿主要用的层（`core` / `exec` / `parser`），并实现 CLI 安装的 `scriptArgs`；不再包装第二套值构造命名空间，也没有 `public_api` 别名。`$262` 宿主是独立模块 `test262_host`（`src/cli/run_test262_host.zig`）。

`CallSite` / `PropertySite` / `NativeBinding` / `zjs.value` / `zjs.object` / `zjs.module` / `zjs.job` 已从本文件删除。

---

## 类型与 re-export

| 名字 | 含义 |
| --- | --- |
| `Runtime` / `Context` / `Value` / `Call` / `EventLoop` | 嵌入名。`Runtime`/`Value` 来自 core，`Context` 来自 `js_context.zig`，`Call` 来自 `native.zig`。 |
| `JSRuntime` / `JSContext` / `JSValue` | 与上一行同一批类型，给仓内测试和 CLI 用。 |
| `native` | `src/native.zig`。 |
| `runtime` | `event_loop.zig`：宿主事件循环。 |
| `core` / `exec` / `parser` / `compiler` / `bytecode` / `libs` | 整层模块。 |
| `testing` | 仓内夹具（`is_test` 才编）。`$262` 宿主不从本文件导出。 |
| `GCStats` / `GCPauseDistribution` / `RuntimeOptions` / `RuntimeMemoryUsage` / `OpcodeProfile` | 统计与选项。CLI `--gc-stats` / `--profile-opcodes` 用。 |
| `default_stack_size` / `default_gc_threshold` | 默认限额。 |
| `opcode_profile_build_enabled` | `-Dzjs_enable_opcode_profile`。CLI 在 false 时对 `--profile-opcodes` fail-close。 |

---

## `activateOpcodeProfile` (`src/root.zig`)

- **签名**：`pub fn activateOpcodeProfile(profile: ?*OpcodeProfile) ?*OpcodeProfile`。
- **作用**：给剖析器装 opcode 名提供者并激活缓冲区。
- **实现**：`core.profile.setOpcodeNameProvider(exec.opcodeName)`，再 `core.profile.activate`。
- **所有权 / 错误 / 调用**：返回此前的线程局部活动 profile，供调用方恢复。此包装不检查 `opcode_profile_build_enabled`。

---

## `printSmallInlineProbe` (`src/root.zig`)

- **签名**：`pub fn printSmallInlineProbe() void`。
- **作用**：按环境开关输出 small-inline 探测计数，供内部 CLI 使用。
- **实现**：调用 `exec.small_inline.printProbe`；当前助手仅在 `ZJS_INLINE_PROBE` 存在且非空时通过 `std.debug.print` 输出 prep、take 和整数百分比。
- **所有权 / 错误 / 调用**：本包装只转发，不返回 I/O 错误。

---

## 不再从本文件导出

值构造用 `Value.int32` 等；句柄用 `Runtime.enterHandleScope` / `createPersistentValue`；字节存储用 `Value.Bytes.Store`；模块图与 job 排空分别走 `exec/module_graph.zig` 与 `Context.runJobs`。`run-test262` 通过同一模块上的 `core` / `exec` / `parser` 使用这些层，`$262` 走独立的 `test262_host` 模块，不经过已删包装。
