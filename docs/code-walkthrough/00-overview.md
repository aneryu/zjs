# 00 — zjs 源码总览

本册不逐函数展开（那是 01–20 册的工作）。这里把引擎当成一条流水线讲清楚：代码从哪里进、值怎么表示、谁拥有堆、字节码怎么跑、各目录各管什么。读完应能在 `src/` 里定位任意行为。

## 1. 这是什么项目

zjs 是 **QuickJS 的 Zig 重写**，已经从「对照镜像」变成独立引擎：

- **语义权威**：ECMA-262，用仓库内 `test262/` 与 `test262.conf` 验证。
- **对照实现**：pinned QuickJS。行为与 spec 冲突时跟 spec，并记录分叉。
- **工程目标**：Zig 习惯（显式 error set、显式所有权、模块边界），而不是保留 C 形状。
- **性能标尺**：vendored bench-v8 / Octane。
- **不是**：Node/Deno/Bun、浏览器、敌意代码沙箱、libquickjs C ABI 的 drop-in。

生产配置签名（编译期钉死）：

```
zjs-config-v3:compiler=v2,layout=short,repr=tagged,gc_layout=obj64_m,optimize=ReleaseFast,force_gc=off,ownership_audit=off
```

`compiler=v2` 是**唯一**编译器的身份名，不是目录名。`layout=short` 是发布布局。

## 2. 分层与依赖方向

```
embedder / CLI / tests
        │
        ▼
 src/root.zig          公共嵌入面（JSRuntime / JSContext / JSValue / native / CallSite）
 src/binding/          把 core 类型收成稳定 API（句柄、NativeEntry thunk、PropertySite）
        │
        ▼
 src/core/             值、对象、形状、属性、GC、Runtime/Context   ← 禁止依赖 parser/exec/runtime/CLI
        ▲
        │
 src/parser.zig  →  src/compiler/  →  src/bytecode.zig  →  src/exec/  →  src/runtime/
   词法+语法+发射      变量/标签/布局         载体与 opcode 表         VM+内建+模块         事件循环
```

`tools/architecture/check_deps.js` 强制：`core` 不能依赖 CLI 策略、test262 glue、插件加载器、事件循环。

三个旁路文件：

- `simple_token.zig`：QuickJS `simple_next_token` 那种前瞻用的 token 子集。
- `config_signature.zig`：编译期配置签名证明。
- `dossier_pad.zig`：布局谱系的 padding 仪器；`pad=0` 什么都不发。

`src/internal_root.zig` 聚合 CLI / test262 / 仓内测试，**不是**公共嵌入契约。

## 3. 一次 `eval` 走多远

以嵌入代码为例：

```zig
const rt = try zjs.JSRuntime.create(allocator);
const ctx = try zjs.JSContext.create(rt);
const result = try ctx.eval("let x = 1 + 2; x;", .{});
```

实际路径（名字以当前树为准）：

1. **`JSContext.eval`**（`binding/context.zig`）把源文、文件名、eval 标志收成内部调用。
2. **`eval_entry`**（`exec/eval_entry.zig`）决定 script vs module、直接 vs 间接 eval、strict、new.target 等宿主标志。
3. **`parser.compile`**（`parser.zig`）词法 + 语法 + 作用域 + 发射临时字节码。TypeScript 只做语法擦除，不是类型检查。
4. **compiler 管线**（`compiler/`）
   - `builder.zig`：临时指令流、标签槽、重定位。
   - `resolve_variables.zig`：变量解析与活性。
   - `resolve_labels.zig`：最终布局、跳转穿线。生产布局 `short`，`plain` 只是 A/B 诊断。
5. **`bytecode.zig`** 把 `FunctionDef` 收成 GC 管理的 `FunctionBytecode`（96 字节核心头 + packed 常量/变量/闭包/code + 可选 debug 尾 + zjs 自己的 call-facts 尾）。
6. **`zjs_vm.run`**（`exec/zjs_vm.zig`）为根函数造一个真实的函数对象，准备 `this` / var refs / 全局对象，进入 `tailcall_dispatch`。
7. **opcode 处理**落在 `vm_*.zig` 与 `vm_property_*.zig`；值级运行时在 `*_ops.zig`；内建表在 `*_builtin_ops.zig`，经 `builtin_dispatch.zig`。
8. 返回值是 `JSValue`。出了引擎边界必须用 handle（`Local` / `Persistent`），不能把裸 `JSValue` 活过一次调用。

CLI `zjs -e` / `zjs file.js` 走同一条编译-执行链，外面包 `src/cli/zjs.zig` 与 `runtime/event_loop.zig` 的任务排空。

## 4. 值：16 字节 tagged `JSValue`

`src/core/value.zig` 里 `JSValue` 是 `extern struct { repr: Repr }`，其中 `Repr` 为 `extern struct { payload: u64, tag: i64 }`，正好 16 字节、8 字节对齐。这是**语义**上对齐 QuickJS，不是 bit 级 ABI 兼容。

tag 是有符号整数。堆对象走负 tag（object / function_bytecode / module / string 族 / bigint / symbol）；立即数走非负（int32、bool、null、undefined、float64、short bigint、exception 哨兵等）。`cycleMarkHeader` / `isTracerOwned` 用 `[Tag.symbol, Tag.object]` 区间识别需要追踪的值；保留的 `requiresRefCount` 只是历史命名的堆值分类谓词。

重要后果：

- 值按位复制；存活靠堆边、root frame、native pin，不再靠引用计数。`JSValue.dup` / `JSValue.free` 方法已删除，不能按旧 RC API 调用。
- 短 bigint 直接躺在 payload 里；放不下的进 `core/bigint.zig` 的 GC 管理堆对象 `BigInt`（limb 算术来自 `libs/bigint.zig`）。
- 字符串有 intern / rope；对外句柄是 `JSString` / `JSBytes`（`string_view.zig` / `bytes_view.zig`）。

## 5. 对象、形状、属性

`object.zig` 是对象模型的大文件（当前约 11k 行、800+ 函数）：分配、class payload、exotic 方法、GC header 互转、各种 arm（array / bytecode / regexp / async …）。

配套：

- `shape.zig`：隐藏类。属性添加走 shape 转移，不是每次都哈希。
- `property.zig`：属性存储与标志（writable/enumerable/configurable、accessor、AUTOINIT 等）。
- `object_payloads.zig`：各 class 的 payload 布局。
- `class.zig`：内建与宿主 class id。
- `function.zig` / `host_function.zig` / `native_entry.zig`：JS 函数、C 风格原生函数、不可变 `NativeEntry`（VM 对内建和宿主函数走同一条 native 分发）。

属性快路径包括 `exec/property_direct.zig` 的无用户代码探测，以及 `vm_property_field.zig` 的站点 inline cache。`PropSiteCache` 由 VM 字段站点和宿主 `PropertySite` 共用：own-data 最多缓存两种 shape identity，另有单层原型数据与 native getter 分支；miss 后允许重新捕获，达到预算后退为 `.mega`。缓存存 identity/slot 等标量，不持有对象指针；shape 变更通过新的 identity 使旧缓存失效。

## 6. GC：非移动、分代、增量 STW tracer

引用计数已退役。现生产收集器：

- **非移动** tracing GC，sticky mark bit 分代，增量标记，停世界。
- `gc_block_heap.zig`：2 MiB superblock、64 KiB block、size-class cell、四张 bitmap（alloc / mark / doomed / finalizerBits）。
- `gc_trace_stw.zig`：minor / major、condemn、sweep。
- `gc_conservative.zig`：生产路径扫 native 栈与寄存器，补充始终存在的精确根（句柄、容器与 VM 活窗口等）。`-Dzjs_gc_roots_diag=true` 还会链接已声明的标量 root frame，用于衡量保守扫描额外保活的对象；它不是精确根的总开关。
- `gc_address_registry.zig`：页基数地址 → 分配物，给 conservative 查找。
- 普通对象死亡是 bitmap 操作；只有 `needs_finalizer` 种群跑析构。

VM 操作数栈与局部从 `VmStackArena` 按帧切，不逐值挂 root。exec 的 `ActiveInvocationTrace` 把语义活窗口暴露给 core，而不让 core 学会 VM 布局。生产默认只链容器/窗口的 value-root frame（`value_root_link_containers_only`）。

`JSRuntime` **单线程所有权**：创建、变异、收集、销毁都在 owner 线程。跨线程调用在宿主边界以 `error.WrongRuntimeThread` 拒绝。

## 7. 字节码 VM

zjs **已经是**栈式字节码解释器，没有迁到寄存器机的证据支持。

- 指令集以 QuickJS 为基础，现由 `opcode_logical.zig` 统一描述逻辑指令；物理编码还包括 short、融合指令与 `ext0` 子编码，不能当作 QuickJS opcode 编号表末尾简单追加几个指令。
- 热路径：`tailcall_dispatch.zig` 里每个 handler 以尾分发结束，避免巨型 switch 撑爆栈帧。冷路径 outline 到 `vm_*.zig` / `tailcall_dispatch_colds.zig`。
- 同步帧优先从 runtime arena 切成 `[args | locals | operand | var-ref metadata]`。generator/async 帧要跨 suspend 存活，用可转移的驻留存储。
- 严格模式的普通调用尾 `return f(...)` 折成 `tail_call`，复用调用者帧（相对 pinned QuickJS 的文档化分叉；方法位置的尾调用仍不在范围内）。

命名约定（`exec/`）：

- `vm_X.zig`：吃操作数栈/帧的 opcode handler。
- `X_ops.zig`：吃 runtime+值的运行时/内建实现。
- `X_builtin_ops.zig`：从 `X_ops.zig` 拆出的 native-record 表。
- `*Vm` 后缀：同一操作的栈-VM 入口变体。
- `throw<Kind>Message` / `throw<Reason><Kind>`：带消息的抛错；裸 `return error.Xxx` 只留给消息已在别处挂上、或用户代码到不了的路径。

## 8. 模块、Promise、事件循环

- 模块记录在 `core/module.zig`（core 层身份）；链接、求值、图在 `exec/module.zig` 与 `module_graph.zig`。
- `MODULE_NS` 延迟导出走 `module_auto_init.zig` 的不可变 `AutoInitModuleOwner` 回调，不把 Runtime 引进这条叶子契约。
- Promise 抽象操作在 `exec/promise_ops.zig`；对象状态在 `core/promise.zig`；任务队列原语在 `core/jobs.zig`。
- 宿主事件循环只在 `runtime/event_loop.zig`：定时器、fd/signal、job draining。Atomics waiter 清理由 exec 做，再从 `runtime/root.zig` re-export。

动态插件加载器已删除（2026-09-06）。宿主函数经 `zjs.native` 注册成不可变 `NativeEntry`，VM 当内建分发；native→JS 走 `zjs.CallSite`。Fun Native ABI 在 `src/abi/`，加载器在外部 `fun` 仓。

## 9. 库、CLI、测试

- `src/libs/`：regexp 引擎、unicode 表与属性、bigint、dtoa/number format。这些是移植/生成代码，函数名常保留上游拼写。
- `src/cli/zjs.zig`：CLI。`run_test262*.zig` 把 test262 跑法拆开：options / config / names / metadata / known errors / source / host / reporter。
- `src/tests/`：Zig 单测与集成入口；`tests/fixtures/` 是 harness 与覆盖夹具。
- `build.zig` + `build/`：产物、配置、gates、perf、测试步骤。Zig 钉 0.16.0。

## 10. 怎样用后面的分册

按要改的层打开对应册，用 `_inventory.tsv` 搜函数名，跳到 `` (`file.zig:LINE`) `` 标题。

| 我想改… | 打开 |
| --- | --- |
| 嵌入 API、句柄、host function | 01 |
| 语法 / TS 擦除 / 发射 | 02–03 |
| 变量解析、跳转、short layout | 04–05 |
| tag、字符串、数字 | 06 |
| 对象布局、exotic | 07–08 |
| 泄漏、暂停、分代 | 09–10 |
| opcode 变慢 / 分发 | 11–12 |
| 调用约定、construct、eval | 13 |
| `[[Get]]`/`[[Set]]`、shape 未命中 | 14 |
| Array/String 内建 | 15 |
| Promise / 模块循环 | 16–17 |
| 定时器、CLI、test262 已知失败 | 18 |
| `\p{…}`、BigInt 算术 | 19 |
| 构建开关、测试目标 | 20 |

核对覆盖时以各册文末「覆盖核对」与清单为准。源码与文档冲突，信源码。
