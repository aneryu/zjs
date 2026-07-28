# Phase 2 / 第 2 步 — `put_var` cell 直写内联快路

- **日期**：2026-07-28
- **裁决**：**合入**（明确成功档：4/4 且改善 ≥ 3%）
- **实现 commit**：`3e1bbb30`
- **分类**：`qjs-mechanism alignment`（移除 QuickJS 从未有过的 zjs-only per-write 调用帧），**不是**新的 benchmark specialization

---

## 路线修正的由来

原计划第 2 步是"消除 global closure-variable 线性扫描"。**该前提被 profile 否定**：
三处 `for (function.closureVar())` 全扫描确实存在，但都在声明/启动期
（`evalFunctionDeclaresGlobalVar`、`validateGlobalVarDeclarations`、
`instantiateGlobalVarDeclarationCells`），steady-state 写循环碰不到。

实际热点由 profile 给出：

| | zjs | qjs |
|---|---|---|
| 全局写形态 | `putVar` 独立符号，**29.68%** | 全在 `JS_CallInternal` 内（100%，无独立符号） |
| 该函数静态体积 | **13398 字节** | 内联在解释器循环 |
| 每次写固定开销 | `sub sp, #0x110`（272B 帧）+ 7 对 `stp`（14 寄存器） | 无函数调用开销 |

`putVar` 一个 `noinline` 函数承担 cell 直写、lexical TDZ、const 违规、
global-object set、eval bindings 全部分支，而热循环只走最短的那条。

## One-cut 定义

```text
P0  opcode → coldStd → noinline putVar → 272B 帧 → cell 快路写入 → return
P1  opcode → inline cell guard → hit: 直接写入
                              → miss: 调用原 outlined putVar
```

采用**最小归因版**（inline precheck + `putVar` 原样保留）。miss 严格无副作用：
所有 guard 在 `stack.pop()` 之前执行，`frame.pc` 仅在 hit 时推进，
outlined `putVar` 看到的状态与改动前完全一致。
**代价**：miss 会重复一次 guard —— 该成本未单独测量，因为慢路在目标 workload 中命中为零。

**Call-site matrix**：`putVar` 只有一个生产调用点（`tailcall_dispatch_colds.zig:103`），
内联点无歧义。

## 纯度证明

**动态**（gdb 断点计数）：500 次循环写入 → `putVar` 慢路调用 **0 次**。

**慢路哨兵**（全部仍走原逻辑，语义正确）：

| 探针 | 结果 |
|---|---|
| `const c=1; c=2` | `TypeError` |
| sloppy 未声明 `x=1` | 成功 |
| strict 未声明 | `ReferenceError` |
| global accessor setter | setter 触发 |

**反汇编**：`putVar` 从 profile 中完全消失（改动前 29.68%），逻辑内联进 `coldStd`
（10.60% → 38.34%）。⚠️ profile 百分比是相对量，**不作为收益证明**。
全局二进制 diff 同样不用于纯度证明（compiler 两态制造上千无关差异）。

## 结果

两个 codegen instance/侧，四个跨实例组合，10 轮平衡交错。

### 目标

| workload | P0 | P1 | 四组合 | geomean | 方向 |
|---|---|---|---|---:|---|
| `global_write_loop` | 1.5407 / 1.5178 ms | **1.3222 / 1.2781 ms** | 0.8582 0.8711 0.8295 0.8421 | **0.8501** | **4/4** |

per-binary IQR 0.05%–0.69%，`checksums=1`。

### 非目标 sentinel

| workload | geomean | 方向 | 判读 |
|---|---:|---|---|
| `prop_read_mono_loop` | 1.0004 | 2/4 | 中性 |
| `fib_rec` | 0.9999 | 2/4 | 中性 |

### 三个数字的证据角色（不可混用）

```text
Causal within-zjs improvement:   P1/P0 = 0.8501, 4/4
Current absolute zjs/qjs status: 1.4319  (p25 1.4317 / p75 1.4420)
Historical Phase-0 baseline:     1.7150
```

后两者来自不同轮次、不同 build instance 与环境，**不得相除**后声称差额全部来自本次改动
（`1.7150 × 0.8501 ≈ 1.458`，与实测 1.4319 有差异，正说明轮次间存在其他变化）。

## 门禁

`test` / `test262-gate` / `test-oom` / `smoke` / `test -Doptimize=ReleaseSafe` /
`test-core -Dzjs_force_gc=true` / `perf-self-check`（paired geomean 1.00，validation failures 0）/
`zig fmt --check` / `git diff --check` —— 全部通过。

## 下一刀的候选（由改动后 profile 给出）

`op.put_var` **仍走 cold 分派**：`coldStd` 现占 38.34%，其内部序言 5.2%、尾声 2.6%，
每次写入仍建立 128 字节栈帧 + 8 个寄存器保存（较原 272B/14 寄存器减半，未消除）。

直接上界估算：`38.34% × 7.8% ≈ 3.0% overall`。这只是采样估算，不含 call/return 依赖、
主循环与 wrapper 间的寄存器传递、wrapper 的 stack traffic、I-cache/BTB 影响，
以及编译器无法跨 `noinline` 边界调度的成本。

**预期低个位数收益，不应再期待 15%。**
