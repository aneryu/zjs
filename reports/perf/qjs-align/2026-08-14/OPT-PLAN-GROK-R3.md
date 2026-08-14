# OPT-R3 计划 — grok 第三批：四大赤字基准的 JS 函数级归因扫荡（诊断批）

日期：2026-08-14。制定者：driver。执行者：grok。状态：**定稿，待派发**。

## 0. 为什么是这个方向（战略语境）

追平假设已**清零**（PARITY-LEDGER §存活假设）：call/frame 固定税、readfwd、tail_call、
concat 对齐四条全部 CLOSED。按治理规则，路径 A/B 架构决策到期——但**裁决缺证据**：
四大赤字基准（pdfjs 1.61pp / earley-boyer 1.49pp / typescript 1.24pp / deltablue 0.93pp，
合计约 70% 净赤字）**从未做过 JS 函数级归因**。

方法依据：08-12 战役引擎机制级归因 22 候选仅 1 落地；改问「**哪个 JS 函数慢**」立刻命中
RayTrace 的 `this.initialize.apply(this,arguments)` 包装体（占两侧全部 opcode 14.6%），
消融三 pad +5.2~5.6% 零翻转，落地 `fb680e41`（RayTrace 0.754→0.783，geomean +0.24pp）。
**该方法只用过这一次。**

本批产出 = 每基准一份机制命名报告（不是修复）。它同时服务两个下游：
路径 A 还有多少可挖（决定 A/B 裁决），以及 OPT-R4 修复批的候选清单。

## 1. Lane 划分与公共契约

| lane | benchmark | CPU | worktree/分支 |
|---|---|---|---|
| R3-P | pdfjs | 5 | `worktree-grok-r3-pdfjs` / `grok/opt-r3-pdfjs` |
| R3-T | typescript | 6 | `worktree-grok-r3-ts` / `grok/opt-r3-ts` |
| R3-E | earley-boyer | 7 | `worktree-grok-r3-eb` / `grok/opt-r3-eb` |
| R3-D | deltablue | 8 | `worktree-grok-r3-db` / `grok/opt-r3-db` |

继承 OPT-R2 §1 全部契约（禁碰账本／lint／`[PROGRESS]`／zsh 用 `bash -c`），外加本批特有：

1. **本批是诊断批，`src/` 只读**。基准 JS 拷到 `/tmp/r3-<bench>/cases/` 里改；
   引擎二进制用 worktree 自建（先 `zig build zjs`，防 stale 二进制）+ 固定 qjs
   `/home/aneryu/quickjs/qjs`。发现的修复候选**只登记不实施**。
2. **诊断测量授权**（修订 R2 的全面禁令，依据「诊断并行、测量串行」裁定）：
   grok 可在**自己被分配的核**上跑消融 A/B 与普查——同一对照的两侧必须**同核交错**（ABBA），
   每侧 ≥8 samples；**CPU 19 保留给 driver**，不得触碰。
   所有诊断数字标注「非裁决用」；任何将写进机制候选的数字由 driver 在 CPU 19 复测。
3. **排名可用单 pad，结论必须三 pad**：进报告「已命名机制」表的头部发现，
   消融差分须在 pads 0/3/7 三谱系**零翻转**（RayTrace 标准）。
   历史教训：单 pad bootstrap 会骗人（slowprop 15 项里 9 项换 pad 翻号）。
4. **Octane 时间盒**：跨引擎只比**分数**（自报 score），不比 wall；
   消融差分的量 = (zjs 分数变化%) − (qjs 分数变化%)，两引擎跑**同一份**改过的 JS。

## 2. 方法（四 lane 相同，先读样本再动手）

**Phase 0 — 方法装载（只读，半小时）**：读
`reports/perf/qjs-align/2026-08-13/D11-OUTCOME.md`（JS 级归因的成功样本）、
`reports/perf/qjs-align/2026-08-12/RAYTRACE-ATTRIBUTION.md` 与 `EARLEY-BOYER-ATTRIBUTION.md`
（报告模板与已知结论）、复用 `2026-08-12/` 里 `*-ipf-*.json` 对应的普查管线（先找生成它们的命令）。

**Phase 1 — 逐 JS 函数普查**：两引擎各自按 JS 函数拆 opcode/耗时占比，
输出并排表：函数 × (zjs 份额, qjs 份额, 份额差)。**按绝对超出排序**，
不按百分比（历史教训：profile 13.32% 的符号直接定价只有 0.96x）。
标出「包装体/胶水」形态（apply 包装、accessor 链、临时对象构造、参数搬运）。

**Phase 2 — 源码消融差分**：对 top 候选逐个做 ≥3 种消融写法
（删除该形态／替换为直调／预计算），两引擎跑同一份改过的 JS，
量 = zjs 增益 − qjs 增益。**消融失败先换写法再放弃**（复现失败三写法规则同源）。
头部发现上三 pad 确认（契约 3）。

**Phase 3 — 连回机制并定价**：把消融确认的形态映射到引擎机制
（zjs `file:line` × qjs `file:line`），按 PARITY-LEDGER 量纲换算预计 zoo 价值
（单基准 +1% = +0.066pp）。产出表：

```
机制 | 涉及 JS 函数 | 绝对超出 | 消融证据(三 pad) | 路径A可修? | 预计 pp
```

**成功判据**：每 lane ≥1 条「路径 A 可修、预计 ≥0.15pp」的命名机制；
若诚实扫完为空，报告「该基准 JS 级干净」——这本身是路径 B 裁决的证据，同样算完成。

## 3. 各 lane 的已知结论与禁区（防重掉坑，任务书原样携带）

**全 lane 已封板（不得重启，若归因指向封板区只登记「独立路径再确认」）**：
调用边界弥散停顿（六诊断封板）／布局彩票／NaN-boxing 与浮点调度／
tail_call 发射（−4.5% 上界，08-14）／rope 表示层（H2 收案）。

- **R3-P pdfjs**：已命名 dispatch +150M / string+regexp +70M / call +62M，
  但赤字 60% 量级未具名——本 lane 主目标就是命名它。zjs 领先区（arith/alloc/frontend/RC）勿碰。
- **R3-T typescript**：已命名 return teardown 10.10x +189M（⚠️ IMPL-TEARDOWN 实现尝试已负过一次，
  归因可指向、修复方案须新机制）与 slow property resolver 3.24x +180M（X-10 删除已兑现 +1.71%，
  剩余部分待 JS 级定位）。fixed-work 1.081x cyc vs zoo 0.83 的落差指向时间盒协议——普查时留意
  GC 相位与重复运行结构。
- **R3-E earley-boyer**：引擎级三桶已命名（闭包+var_ref +223M / GC 环收集 +193M /
  构造 bypass 准入税 +182M）——本 lane 目标是把它们**定位到具体 JS 函数**并给出可消融形态。
  ⛔ fclosure 常驻 handler 已落地且 zoo 效应为零，不要再投。
- **R3-D deltablue**：tail_call 已排除出主嫌疑（CLOSED），调用边界 595.6M 的解释权空缺。
  deltablue 是纯 OO 形态（constraint 链上全是短方法调用）——重点看方法链/accessor
  形态在两侧的每次成本差，以及是否存在 RayTrace 式包装体。

## 4. 交付与 driver 验收

- 每 lane：`/tmp/r3-<bench>/REPORT.md`（Phase 1 并排表 + Phase 2 消融记录含原始数字 +
  Phase 3 机制表）+ `cases/` 全部消融 JS + `[PROGRESS]` 流水。
- driver：抽验消融可复现（亲跑 ≥2 条）→ 头部候选 CPU 19 复测 → 汇总四份报告
  写 OPT-R4 修复批计划 + 把「路径 A 剩余空间」证据打包提交用户做 A/B 裁决。
- 预计耗时：每 lane 1–1.5 天（普查半天、消融一天）；四 lane 并行。

## 5. 结果表（执行后填写）

| lane | phase | 状态 | 头部发现 |
|---|---|---|---|
| （待执行） | | | |
