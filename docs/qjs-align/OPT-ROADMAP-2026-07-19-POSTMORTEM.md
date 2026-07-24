# OPT-ROADMAP-2026-07-19 复盘：为什么没有得到显著收益（2026-07-24）

结论先行：该 roadmap 执行期（07-19→07-24，169 commits）的**净性能效果是大幅负值**，
且被其全部门禁掩盖。修复战役（post_inc/poll/TDZ/class-plan/FAM/budget 系列，
07-24）用 ~300 行代码收回了大部分损失并在六项基准反超 qjs。本文归因过程性根因，
并给出已转化为永久约束的修正。

## 1. 净结果账（不可辩驳的测量）

同脚本、同 qjs 冻结尺（sha256 `b76d1542…`）、CPU19 绑核 insn best-of-5：

| 探针 | e73e8a0c（07-18，roadmap 开始前） | e4fea92e（07-24，roadmap 收口） | 净效果 |
|---|---:|---:|---|
| call-const-zero-arg-10m | 4.416G = **0.93x qjs（反超）** | 7.568G = 1.60x | **+71%** |
| allocation-empty-object-2m | 1.865G = 1.36x | 2.482G = 1.80x | **+33%** |
| P_ifobj（cyc 比） | 0.83x（反超） | 2.53x | **+205%** |
| L0 空循环 | ~12.4G | 34.1G | **+175%** |

回归阶梯（git bisect 实建定位）：`fde49b15`(+42% call-const，全局 let 循环
post_inc 冷路径)、`281e1314`(+223 insn/iter alloc，per-alloc class-table 税)、
`3cd28eaa`/`a11f99d3`(poll/tail-stack 重构，热臂 spill)。与此同时 roadmap 的
P1c resident 刀（0.79x/0.73x candidate/baseline）是真实收益——但它是在
**已中毒的 baseline** 上量的，净额远小于重构列车的损失。

## 2. 根因一：裁决协议的作用域漏洞（最核心）

§8 五条件裁决 + §9 验证档位设计严密——但只约束「**候选**」（perf 刀）。
造成回归的四个提交全部标为 `refactor:`/`fix:`（忠实性/正确性列车），
**只过正确性门禁，从不进 §8**。§0 把「忠实采用 QuickJS 机制」列为第一优先级，
客观上给了忠实性重构在 cycles 上的免检通道。结果：门禁不对称——正确性五重
门禁（test262/checkpoint/OOM/force-GC/ReleaseSafe）滴水不漏，性能门禁只盖住
标签为 perf 的少数提交。

## 3. 根因二：全部性能证据是相对测量，无绝对锚点滚动

A0 症状矩阵只在 07-19/20 冻结一次；此后所有证据都是 candidate/baseline 配对
（相对差）。回归累积在**每一对的 baseline 侧**，配对测量在结构上不可见。
RegExp Zoo score 由 regexp 引擎主导、对解释器 per-op 税不敏感；「46 锚点」
是正确性锚点。于是 60%+ 的全局漂移在五天里对每一层证据都隐形。

## 4. 根因三：半忠实——对齐了形态，没对齐成本模型

qjs 的每个形态背后有配套的执行成本模型；只搬形态不搬成本模型 = 严格变差：

- `fde49b15` 把 `let` 循环 `i++` 的发码对齐为 qjs 的 `post_inc+put_loc_check+drop`
  （形态正确），但 qjs 靠 `CASE(OP_post_inc)` 的内联 int 快腿（quickjs.c:20009）
  消化它，zjs 的 post_inc 绑在 coldStd→postUpdateVm 帧化慢路径——**发码忠实 +
  执行不忠实 = 每迭代 ~190 insn**。修复（op_post_inc_dec 快 handler）本应与
  发码对齐同一提交落地。
- `3cd28eaa` 对齐了 counter lifetime（per-realm），但 qjs 的 poll 是寄存器驻留
  循环里的 3 条指令；zjs 实现带 publish+错误联合，给每个跳转热臂加 spill。
- `a11f99d3` 对齐了 entry-poll 次序，每调用 +54 insn。
- `281e1314` 对齐了 class 生命周期管理（动态类 pin/generation），但把这套机构
  压到每次分配上，而 qjs 对一切类都是 `rt->class_array` 直读零记账。

**教训格式化：忠实性对齐必须成对交付——「qjs 发什么」与「qjs 用什么成本执行它」
是同一个机制的两半。**

## 5. 根因四：巨型 squash 列车不可性能二分

`281e1314` 单提交 23K 插入（W1b3–W1d 累计），`fde49b15` ~10K（parser 6360 行）。
回归定位到提交后无法再内部二分，修复只能绕道新机制（plan 缓存/Construction 旁路）
而非精准回滚病灶 hunk。性能敏感面上的列车必须以可二分粒度落地。

## 6. 根因五：症状识别正确，机制映射错位

A0 矩阵其实**测到了** post_inc 27.7 的症状；IMPL-DIVERGENCE-2026-07-11 早已写明
「发码层已收敛，gap 全在 per-op 成本」。但 roadmap 把主攻方向映射到构造/发射/
carrier 归一化（M-HOIST/M-EMIT/W1b3 Realm），对 per-op handler 成本模型着墨最少。
修复战役的实际杠杆（五把 20-60 行的 handler/缓存刀）全部落在后者。

## 7. 该保留的东西

roadmap 并非全盘失败：no-cheating 前置审计、正确性硬化（test262 债清偿、
direct-eval/super/auto-init 真 bug）、§11 永久约束（本身质量很高）、探针与
证据文化都是净资产。失败的专指性能维度与其过程保障。

## 8. 转化为永久约束（已入 memory，后续 roadmap 必须继承）

1. **全局锚点滚动复测**：任何触碰 exec/core/parser 热路径的提交——不论标签是
   perf/refactor/fix——必须附带微型绝对锚点集（call-const、L0 空循环、
   allocation-empty 的 insn 绝对值，~30 秒），相对上一提交漂移 >2% 即停车归因。
2. **重构即候选**：§8 五条件对热路径重构同样生效；「忠实性」不豁免 cycles 证据。
3. **成对忠实**：对齐 qjs 形态的提交必须同时对齐该形态的执行成本模型，或在同
   一提交内给出成本恒等证明。
4. **可二分粒度**：性能敏感面禁止 >2K 行的 squash；列车按步落地且每步过锚点。
5. **配对测量报告基线漂移**：candidate/baseline 证据包必须附 baseline 对最近
   锚点的绝对读数，使中毒基线可见。
