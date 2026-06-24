# 调用机制对齐 — 状态 & 待办（2026-06-23）

> 上位：`QJS-FAITHFUL-ALIGN.md`。本文件记录调用机制（轴 2）的对齐状态、**关键 perf 再诊断**、以及**暂时无法完全对齐、留待后续统一攻克**的项。

## 当前状态

- **Approach B（递归 dispatchLoop）**已实现，门控在 `-Dzjs_recursive_dispatch`（默认 OFF）。
  - 设计：给正典 `dispatchLoop` 加 comptime `recurse: bool` 特化，**复用同一套已验证 opcode 处理器**（recurse=true 编译消除 Machine refresh/switched-reload，OP_return 直接返回值 = qjs `goto done`）。`recurseInlineCall` trampoline 的递归目标从被退役的 `dispatchRecursive` 改为 `dispatchLoopRecursive`。
  - 放弃了复活的独立 `dispatchRecursive`（3040 行分歧副本）+ `tailcall_dispatch.zig`（已删）。
- **默认（Machine）路径**：test262 **0/49775**（已验证基线——**绝不可回退**）。
- **递归路径**：从 42→5 个 test262 回归（修了 cluster B 错误传播 + 大部分构造簇）。剩 5 个边界 case（见下「待办」）。

## ⭐ 关键发现 — perf 再诊断（已纠正先前错误）

- **C 递归 perf 中性**：纯调用 insn/call **1599 → 1544**（fib ~不变）。
- **先前「switched-reload（inline-Machine 共享循环的 per-level 重载）是 15× 根源」的诊断是错的**——实测它只占 ~4%。
- **真正的杠杆 = 整条调用机器比 qjs 的内联 `JS_CallInternal` 序列重 ~15-19×**（perf annotate 实证，绑核）：
  - `setupInlineEntry` **~448 insn/call**（qjs prologue ~30）—— 单项最大。
  - 外加 `FrameSlab.carve`、`execCall`、`resolveInlineTarget`、`recurseInlineCall`、`teardownInlineEntry`、`returnTop`。
  - qjs 实测 **104 insn/call**，zjs **1544**。g 函数体内 dispatch 本身已对齐（131<154）。
- **这个 lean 在 Machine 结构上同样能做**（`setupInlineEntry` 两路径共享）——**不依赖 C 递归**。C 递归的价值是结构忠实 + 修了 cluster B（cluster B 本只在递归路径坏）。

## 待办（暂无法完全对齐，后续统一攻克）

1. **递归路径构造/super 边界 case（22 个，flag-on 时）**：subclass/{binding,builtins,derived-class-return-override-with-this,private-class-field-on-nonextensible-return-override}、derivedConstructor*、superCallThisInit、uninitializedThisError、this-access-restriction、extendBuiltinConstructors、destructuring/{order,order-super}、Promise/then/ctor-custom、Iterator map/reduce、PrivateName、TypedArray detached 等。根因：内联递归构造路由窄（`setupInlineConstructorEntry` 仅同 realm 字节码类构造），未覆盖 custom/builtin/proxy/bound/跨 realm 构造 + destructuring-with-super 求值顺序。**Machine/默认路径正确处理全部这些**（已 recurse-gate，默认 test262 **0/49775** + unit 1219 验证干净）。完整清单见 `-Dzjs_recursive_dispatch=true` 的 test262-failures.log。
2. **「设递归为默认」被 (1) 阻塞**——直接设默认会把这 5 个带进默认。保持 flag-gated，待 (1) 解决后再设默认（或给这 5 类做 Machine fallback）。
3. **调用机器 perf lean**（`setupInlineEntry` + plumbing → qjs 极简 prologue）—— 真正的 15× perf 杠杆。多函数大工程，留待统一攻克。

## 下一步

- 优先：lean 调用机器（perf 杠杆），从 `setupInlineEntry` → qjs 极简 prologue 起步（两路径都受益）。
- 忠实目标：qjs `JS_CallInternal`（prologue quickjs.c:17826-17871 / OP_call 递归 18182-18200 / epilogue 20699-20710）。
