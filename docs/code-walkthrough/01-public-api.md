# 01 — 唯一引擎模块与宿主门面

`src/root.zig` 是 `@import("zjs")` 的唯一编译根。嵌入方用 `Runtime` / `Context` / `Value` / `Call` / `EventLoop`；真正的 eval / `defineFunction` 在 `src/js_context.zig` 与 `src/native.zig`。同一文件也 re-export 引擎各层，给 CLI / test262 / 仓内测试用。旁路文件（配置签名、布局垫片、GC 快照、平台时钟）挂在这个根上。

`PropertySite`、`PropNameID`、`NativeBinding`、`zjs.native.leaf` / `Class`、旧 binding 层 `CallSite` 已删除。native → JS 重复调用走 `exec/call_site.zig`；属性 IC 只留在 VM `PropSiteCache`。

## 入口地图（一页）

```
embedder / CLI / 仓内测试
    │  const zjs = @import("zjs");
    ▼
src/root.zig                          唯一引擎模块
    Runtime / Value                   ← core（公开别名；JS* 是同一类型）
    Context                           ← js_context.zig
    Call                              ← native.zig
    EventLoop                         ← event_loop.zig
    core / exec / parser / runtime    ← 仓内层 re-export
    Context.defineFunction            ← 直接收 fn (*Call)
    Context.defineScriptArgs          ← CLI `scriptArgs`
    │
    ▼
src/js_context.zig                    Context 门面：create / eval / defineFunction
src/native.zig                        comptime thunk → 不可变 NativeEntry
    │
    ▼
src/core/  JSRuntime / JSContext / JSValue / NativeEntry / atoms / GC
src/exec/  eval_entry / call_site / object_ops / builtin_dispatch / zjs_vm
```

一次最短嵌入：

```zig
const rt = try zjs.Runtime.create(.{ .allocator = allocator });
defer rt.destroy();
const ctx = try zjs.Context.create(rt, .{});
defer ctx.destroy();
const result = try ctx.eval("1 + 2", .{});
_ = result;
```

所有权要点（契约正文，这里只钉位置）：

| 想做的事 | 入口 | 拥有文件 |
| --- | --- | --- |
| 造 Runtime / Realm | `Runtime.create` / `Context.create` | core；门面在 `js_context.zig` |
| 跑脚本 | `Context.eval` / `evalScriptSource` | `js_context.zig` → `exec/eval_entry.zig` |
| 注册宿主函数 | `Context.defineFunction` | `native.zig` + `js_context.zig` |
| native → JS | `Context.callFunction` | `js_context.zig` → `exec/call_site.zig` |
| 跨调用保住值 | `rt.createPersistentValue` / `enterHandleScope` | core 句柄 |
| 排 Promise job | `Context.runJobs` / `EventLoop.runUntilIdle` | `js_context.zig` / `event_loop.zig` |

`Context.destroy` 清理该 context 的 Atomics waiters、撤销宿主持有的 realm 根，并释放公共门面分配；core realm 的回收由 GC 决定，并非在这里立即销毁。`Call.ctx` 是非拥有门面，禁止 `deinit` 或 `destroy`。

## 分册目录

| 文件 | 覆盖 |
| --- | --- |
| [01-public-api-root.md](01-public-api-root.md) | `src/root.zig`：嵌入名、层 re-export、`defineScriptArgs` |
| [01-public-api-companions.md](01-public-api-companions.md) | `platform_clock.zig` |
| [01-public-api-context.md](01-public-api-context.md) | `js_context.zig`：`JSContext` |
| [01-public-api-native.md](01-public-api-native.md) | `native.zig`：`Call` / `managed` |

## 本册不讲什么

- `Runtime` / `Value` 的方法体在 core（06 / 10 册）。root 只 re-export 类型。
- `EventLoop` 在 18 册。
- 叶签名是引擎私有 `LeafSig`（`src/core/native_entry.zig`），给内建 `native_legacy` 用，不再有 `zjs.native.leaf`。

## 覆盖核对

本册按源文件拆分逐项解释；测试及测试内嵌套函数不属于本次核查范围，部分旧分册仍保留这些条目。

旧检查器按名称在 Markdown 中搜索，可能把其他文件的同名函数或普通正文当作覆盖，也可能把未知路径当作零函数文件。因此旧有的“397 / 397、未覆盖无”不能证明覆盖完整。覆盖需要同时核对源文件与函数身份，语义准确性还需要对照函数体和调用链；不能从文本命中数推导。检查器修复不在本次仅评估和修正文档的范围内。
