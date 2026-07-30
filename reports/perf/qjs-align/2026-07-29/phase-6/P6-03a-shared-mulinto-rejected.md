# P6-03a — 共享 caller-storage 乘法 API：**负结果，关闭**

- **日期**：2026-07-29
- **P0**：`a2e27824`（代码等同 `641793d3`）
- **裁决**：**拒绝**。四种结构形态均超出自身 ±0.5% 中性门禁
- **产出**：无生产代码；P6-03c 改为自带循环副本

---

## 1. 目标与门禁

抽出 `mulInto(output: []Limb, lhs, rhs) MulResult`，让 `mulAlloc` 与未来的
FAM 路径共用同一算法。门禁：direct size matrix 变化在 **±0.5%** 内，
结果逐位一致。

## 2. 四种形态的实测

| 形态 | max \|change\| | 最差形状 | 其余超阈值形状数 |
|---|---:|---|---:|
| v1 `pub fn mulInto`（重新切片 `output[0..total]`） | **+2.36%** | `4x4` | 8/10 |
| v2 `pub inline fn mulInto` | **+4.40%** | `4x2` | 9/10 |
| v3 `inline fn mulIntoExact` 接受精确长度，两侧各切一次 | **+2.77%** | `4x2` | 6/10 |
| v4 v3 + `mulAlloc` 保留原 `normalize(...)` 调用 | **+3.19%** | `1x8` | 8/10 |

全部形态**结果逐位一致**（3000 组随机差分零不匹配、跨引擎 diff 相同、
poison 测试通过、`test-core` 298 全过）—— 拒绝的理由纯粹是性能。

## 3. 为什么不继续攻 codegen

- `nm` 显示 v1 中 `mulInto` **本来就已被内联**（无独立符号），
  所以回退不是调用开销；**强制 `inline` 反而最差（+4.40%）**；
- **回退的形状在各形态之间漂移**（v3 是 `2x4`/`4x2` 最差，v4 变成 `1x8`/`8x1`）。
  这更像小热函数内部的 codegen/布局敏感，而不是某项可定位的新增成本；
- 继续试 comptime 参数、不同返回结构、更多 inline/noinline 组合，
  很可能只是在**搜索一次有利的编译结果**，而非解决稳定机制。

⚠️ 这与 P4-01c「调用路径对布局不敏感 ≤0.24%」不矛盾：
那次扰动是整块 `.text` 平移、所有符号同步移动，**不覆盖函数内部结构变化**这一类。

## 4. 为什么不接受非中性抽取

若带着 2%–4% 的抽取回退进入 P6-03c，最终只能得到

```text
FAM 收益 − 共享抽取回退 = 净结果
```

无法回答「双分配本身值多少」，也可能误判一次本来值得的 FAM 改造。
这正是设置该门禁要避免的。

## 5. 改用的方案

P6-03c 的 FAM 路径**自带一份 basecase 循环**，`mulAlloc` 逐字节不动：

```text
mulAlloc                 -> allocator-owned limb slice
createHeapMulInline      -> 最终 heap FAM
```

两者都是通用 basecase multiplication，只在 destination ownership 与生命周期上不同。
这不是新增语义快路，也不是 benchmark-specific bypass，
而是**有意的 codegen isolation** —— 与仓库既有的「热臂绝不共享（含模板层）」纪律一致。

约 20 行重复由**行为锁定**治理，而不是共享抽象：

1. 双向注释指向对方，注明 deliberately duplicated；
2. lockstep 差分测试：同一 lhs/rhs → external 结果与 inline FAM 结果的
   sign / len / 全部 limbs 完全一致；
3. 复用 poison 分配器、3000 组随机差分、Python 与 pinned QJS 对照。

## 6. 保留价值

本结果与编译器版本绑定。若将来 Zig 版本变化，可重测这四种形态；
但它**不阻塞** FAM 改造。

## 7. 限制

- 只在 ReleaseFast、单一 build instance 上测量（回退幅度 2.4%–4.4% 远超
  build-instance spread ~0.5%，结论不受影响）；
- 未做指令级归因来解释每种形态的具体回退来源；
- 未尝试 comptime 参数化或拆成两个特化实例。
