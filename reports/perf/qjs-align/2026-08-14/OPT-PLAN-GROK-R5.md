# OPT-R5 计划 — grok 第五批：逐 opcode 机器码对照战役（quickjs.c 为参照）

日期：2026-08-14。制定者：driver。执行者：grok。状态：**定稿，待派发**。

## 0. 用户裁定与本批定位

**用户终局目标（新裁定，入宪）：zoo 每一项 ≥1.0**，不是 geomean 追平。
路线指示：**再多参考 quickjs 的代码做分析**——已排除的方向不重走，
剩余空间要靠更深的 qjs 代码对照挖。路径 B 简报 **PARKED**（本批穷尽 qjs 参照分析后再议）。

**本批抓手 = 一个从未系统分解过的账面事实**：
RayTrace opcode 数 1.0013x 持平而机器指令数 **1.27x**——zjs 平均每 opcode 多执行 ~27% 指令；
EB insn 1.16x、TS 内层 1.215x、zlib dispatch+call=净超出 111%。
**指令数逐条可数、布局免疫（三 pad 离散 0.014-0.031pp）、且从未被封板**
——六诊断封的是「无主后端 stall 残差」，不是指令数分解。
历史只做过零星点（lnot/is_null/put_field 冷路/add_loc），从未按家族×频次全量对照。

当前每项赤字（`6d8295ce` 基线 + 后续两批微增）：

```
raytrace 0.777  pdfjs 0.785  earley-boyer 0.799  typescript 0.830  deltablue 0.870
richards 0.904  zlib 0.920   box2d 0.922         mandreel ~0.929   splay 0.943   gbemu 0.968
资产（勿回退）：crypto 1.058  navier 1.061  code-load 1.104  regexp 1.130
```

## 1. 方法（四 lane 相同，逐 opcode 四步）

1. **频次加权**：zoo 全套 per-opcode 动态频次（复用既有 census 管线），
   本家族 opcode 按「频次 × 已测/估计 Δ成本」排序，取头部直到覆盖家族超出的 ~90%。
2. **成本差实测**：per-opcode cyc/insn 差（qjs 侧编 `OPCODE_ASM_LABEL` 构建；
   ⚠️ 必含共享标签尾——只取 CASE 行会读出假 7.12x 的教训；zjs 侧用既有 per-op 归因）。
3. **机器码逐指令对照（本批核心）**：对头部 opcode，zjs handler 反汇编 vs qjs 对应 arm
   反汇编并排；**每一条 zjs 多出的指令都要归类**：
   `refcount 协议 / 值表示搬运 / 操作数栈访问模式 / vm.* 状态发布 / handler 边界 ABI
   （musttail 四参转递、状态重建）/ GC 门 / 边界检查 / 冷臂内联在热体`。
   每类给出 qjs 参照行号（qjs:NNNN）与「qjs 为什么不需要这条指令」的机制解释。
4. **裁决**：每个归类三选一——
   **FAITHFUL-FIXABLE**（qjs 有更便宜的同语义做法，给出具体方向）/
   **ARCHITECTURAL**（musttail/callconv 结构性，写明精确到指令的原因）/
   **ZJS-ADVANTAGE**（zjs 更省，标记勿动）。

**闭合判据**：家族指令预算表 Σ(频次×Δinsn) 落在该家族实测超出 **±15%** 内；
每个主要 Δ 类都有 qjs:NNNN 参照。残差是发现不是终点（R4 宪法沿用）。

## 2. Lane 划分（按 opcode 家族 × 基准锚点）

| lane | 家族 | 锚点基准 | CPU | 特别任务 |
|---|---|---|---|---|
| **R5-C** | call / call_method / return / 帧建拆 | deltablue·richards·raytrace | 5 | **重启「边界状态耦合」**：08-10 命名的「vm.* 每调用改写 14 次 vs qjs 调用不变 C 栈槽」从未在指令级对照与试修（stall 封板≠此项封板）。逐字段列 vm.* 的 14 次改写，对照 qjs 同点的寄存器/栈槽承载，逐条判 FAITHFUL-FIXABLE 与否 |
| **R5-P** | get/put_field · get/put_array_el · 原型链走查 | typescript·earley-boyer | 6 | TS 内层 +132M 的 other 顶符号（RC destroy/trace、`pushExactSimpleFrame`）纳入；**zjs 已领先的读路径标 ZJS-ADVANTAGE 勿破坏** |
| **R5-A** | 算术 / 比较 / 分支 / 位运算 | zlib·mandreel·box2d·gbemu | 7 | **含 zlib per-opcode 分解**（R4-U 升级项：dispatch+call=111%）——zlib 是单热循环，opcode 谱最窄，最可能出「少数 opcode × 高频」的集中修复面 |
| **R5-S** | get/put_loc · push/dup/swap 栈移动 + **dispatch 边界本身** | 全部 | 8 | 全 zoo 频次第一的家族。边界 ABI 对照：qjs computed-goto 跨 arm 常驻哪些寄存器状态（sp/pc/var_buf/…），zjs 每 handler 经 x0-x3 重建哪些（参照 readfwd 产物 `READFWD-HARNESS-artifacts/` 的 ABI 审计）；量化「每次 dispatch 的重建税」×全 zoo dispatch 次数 |

## 3. 契约（继承 R3/R4 全部，加三条）

1. 诊断批，`src/` 只读；qjs 源在 `/home/aneryu/quickjs/`（pinned `04be2460`）可读可实验构建
   （`OPCODE_ASM_LABEL` 等工装打开属于诊断构建，不动 pinned 产物二进制）。
2. **VERIFIED-LEDGER 强制对照**（R4 契约第 6 条原样有效）：§4.2 常量差
   （属性/数组容量增长、shape/atom hash 初始尺寸——它们直接改变热路径的 resize 频次）、
   §4.4 zjs-only 机制、178 条微观相同。
3. 已封板清单原样有效，但**明确豁免：指令数分解不在任何封板范围内**；
   若 R5-C 的边界状态对照给出 FAITHFUL-FIXABLE 结论，与 stall 封板不冲突
   （封的是「继续找无主 stall 单点」，不是「不许减指令」）。
   测量纪律照旧（各自核、ABBA≥8、CPU19 归 driver、凭据绑 sha256、`bash -c`）。

## 4. 交付与后续

- 每 lane `/tmp/r5-<lane>/BUDGET.md`：家族指令预算表（opcode × 频次 × Δinsn × 归类 × 裁决）
  + 反汇编并排样张 + qjs:NNNN 参照 + 闭合度声明。
- driver：抽验 ≥2 opcode 的反汇编对照 → 汇总四表 → 产出 **R6 修复批**
  （FAITHFUL-FIXABLE 按「预计指令削减 × 频次」排序，按基准锚点组包，向「每项 ≥1.0」推进）；
  ARCHITECTURAL 残差逐条枚举后，才是 B 简报重启的诚实输入。
- 预计每 lane 1.5-2 天，四 lane 并行。

## 5. 结果表（执行后填写）

| lane | 状态 | 闭合度 | 头部 FAITHFUL-FIXABLE |
|---|---|---|---|
| （待执行） | | | |
