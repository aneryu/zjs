# 01 — CLI / 测试用的 binding 门面

`src/root.zig` 是 CLI 与仓内测试走的门面；真正的 eval / `native.managed` 在 `src/binding/`。`src/internal_root.zig` 给 CLI / test262 / 仓内测试用。旁路文件（配置签名、布局垫片、GC 快照、平台时钟）挂在编译根上。

`PropertySite`、`PropNameID`、`NativeBinding`、`zjs.native.leaf` / `Class`、binding 层 `CallSite` 已删除。native → JS 重复调用走 `exec/call_site.zig`；属性 IC 只留在 VM `PropSiteCache`。

## 入口地图（一页）

```
CLI / 仓内测试
    │  const zjs = @import("zjs");
    ▼
src/root.zig                          门面（导出、包装与部分宿主操作实现）
    JSRuntime / JSContext / JSValue   ← binding/root.zig ← core
    zjs.native                        ← binding/native.zig（仅 managed）
    zjs.host                          ← defineScriptArgs 等 CLI 形全局助手
    zjs.value                         ← 立即数构造、句柄别名、String/Bytes
    zjs.object                        ← opaque Object + Buffer 零拷贝借阅
    zjs.context / module / job        ← 调用 / 模块图 / Promise job 排水
    zjs.runtime                       ← runtime/root.zig（事件循环；18 册）
    │
    ▼
src/binding/root.zig                  binding 聚合边界（禁止依赖 CLI）
    context.zig     JSContext 门面：create / eval / defineFunction
    native.zig      comptime thunk → 不可变 NativeEntry（VM 当内建分发）
    │
    ▼
src/core/  JSRuntime / JSContext / JSValue / NativeEntry / atoms / GC
src/exec/  eval_entry / call_site / object_ops / builtin_dispatch / zjs_vm
```

一次最短嵌入：

```zig
const rt = try zjs.JSRuntime.create(allocator);
defer rt.destroy();
const ctx = try zjs.JSContext.create(rt);
defer ctx.destroy();
const result = try ctx.eval("1 + 2", .{});
_ = result;
```

所有权要点（契约正文，这里只钉位置）：

| 想做的事 | 入口 | 拥有文件 |
| --- | --- | --- |
| 造 Runtime / Realm | `JSRuntime.create` / `JSContext.create` | core；门面在 `binding/context.zig` |
| 跑脚本 | `JSContext.eval` / `evalScriptSource` | `binding/context.zig` → `exec/eval_entry.zig` |
| 注册宿主函数 | `zjs.native.managed` + `defineFunction` | `binding/native.zig` + `context.zig` |
| native → JS | `JSContext.callFunction` | `binding/context.zig` → `exec/call_site.zig` |
| 跨调用保住值 | `zjs.value.Persistent` / `Scope` / `Local` | core 句柄；root 只起别名 |
| 排 Promise job | `zjs.job.drain` 或 `JSContext.runJobs` | `root.zig` / `context.zig` |

`JSContext.destroy` 清理该 context 的 Atomics waiters、撤销宿主持有的 realm 根，并释放公共门面分配；core realm 的回收由 GC 决定，并非在这里立即销毁。`Call.ctx` 是 `borrowCore` 出来的非拥有门面，禁止 `deinit` 或 `destroy`。

## 分册目录

| 文件 | 覆盖 |
| --- | --- |
| [01-public-api-root.md](01-public-api-root.md) | `src/root.zig`：value / host / object / Buffer / context / module / job |
| [01-public-api-companions.md](01-public-api-companions.md) | `internal_root.zig`、`config_signature.zig`、`dossier_pad.zig`、`gc_representation.zig`、`platform_clock.zig` |
| [01-public-api-binding-facade.md](01-public-api-binding-facade.md) | `binding/root.zig` |
| [01-public-api-context.md](01-public-api-context.md) | `binding/context.zig`：`JSContext` |
| [01-public-api-native.md](01-public-api-native.md) | `binding/native.zig`：`Call` / `managed` |

## 本册不讲什么

- `JSRuntime` / `JSValue` 的方法体在 core（06 / 10 册）。root 只 re-export 类型。
- `zjs.runtime` 事件循环在 18 册。
- 叶签名是引擎私有 `LeafSig`（`src/core/native_entry.zig`），给内建 `native_legacy` 用，不再有 `zjs.native.leaf`。

## 覆盖核对

本册按源文件拆分逐项解释；测试及测试内嵌套函数不属于本次核查范围，部分旧分册仍保留这些条目。

旧检查器按名称在 Markdown 中搜索，可能把其他文件的同名函数或普通正文当作覆盖，也可能把未知路径当作零函数文件。因此旧有的“397 / 397、未覆盖无”不能证明覆盖完整。覆盖需要同时核对源文件与函数身份，语义准确性还需要对照函数体和调用链；不能从文本命中数推导。检查器修复不在本次仅评估和修正文档的范围内。
