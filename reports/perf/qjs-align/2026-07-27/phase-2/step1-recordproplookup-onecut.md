# Phase 2 / 第 1 步 — `profile.recordPropLookup` one-cut 归因

- **日期**：2026-07-28
- **裁决**：**关闭调查**。TLS profiling guard 不构成可测的性能税。
- **实验开关**：已移除，不留 dormant config。

## 候选

```text
P0  当前实现：core/object.zig 的 getProperty / hasProperty 各调用一次
    profile.recordPropLookup；active_profile == null 时仍付 TLS load + branch
P1  编译期移除这两个调用点，其余 property/global lookup 代码逐字不动
```

## One-cut 纯度

源码差异仅控制两个 `recordPropLookup` 调用点。目标热符号中 TLS 访问按预期消失，
`getProperty` 的局部代码体相应收缩：

| build | `hasProperty` | `getProperty` |
|---|---|---|
| P0 | 90 insns，TLS load = 1 | 216 insns，TLS load = 1 |
| P1 | 91 insns，TLS load = 0 | 196 insns，TLS load = 0 |

⚠️ **全局二进制差异不用于纯度证明**：compiler 两态会引发上千个无关 body diff
（实测 1522 个，样例全为 `Io.*`），与本 one-cut 无关。

## 动态 reachability（gdb 双断点计数）

| 探针 | 迭代数 | `getProperty` 命中 |
|---|---|---|
| `global_write_loop` | 300 | **23**（常量级，来自启动初始化） |
| `property_lookup/own-data` | 200 (+20 warmup) | 220 |
| `property_lookup/own-data` | 400 (+20 warmup) | 420 |

`global_write_loop` 的热循环**不经过**本次 one-cut；direct 层每次迭代精确命中一次。

## 结果

`P1/P0`，`< 1` 表示 P1 更快。

| 指标 | geomean | 方向 | per-binary IQR |
|---|---:|---|---|
| same-runtime `global_write_loop` | 1.0004 | 单实例 | 0.33% / 1.61% |
| direct wall ns/op | 1.0201 | 3/4 | 2.78%–4.89% |
| direct instructions | 1.0025 | **4/4** | 0.18%–0.81% |
| direct cycles | 1.0011 | 2/4 | 8.96%–10.47% |

IPC：P0 1.591 / 1.585，P1 1.583 / 1.598 —— 无变化。

**实例数限制**：`zjs-same-runtime` 在此 target 组合下构建确定（P0 五次、P1 三次 signature 全同），
只能取得一个 codegen instance，故该层无法做四组合；direct 层两侧各两个 instance，做完整四组合。

## 判读

- **收益不存在**：唯一低噪声指标（instructions，IQR < 1%）显示 P1 **多** 0.25% 指令，4/4 一致；
  wall 与 cycles 的差异均小于各自 IQR。
- **量级解释**：`getProperty` 静态体积 216 条指令，但 direct 每次迭代总指令仅约 82 条
  （`16429446 / 200000`），实际走的是远短于函数体的快速路径，TLS load 占比极小。
  删除后 LLVM 的寄存器分配/内联变化抵消并反超了那点收益。
- **两个解释被排除**：`global_write_loop ≈ 1.715x` 的原因不在此（reachability + 实测 +0.04% 双重确认）；
  direct 层"instructions 更少但 wall 更慢"的冲突也不由它解释（P1 的 instructions 反而更多）。

## 后续

不重构 profiling carrier。直接进入第 2 步：消除 global closure-variable 线性扫描。
