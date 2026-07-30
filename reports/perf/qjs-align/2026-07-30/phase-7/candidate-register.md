# Phase 7 候选登记表

登记那些**在别条线里被意外撞到、但尚未具备立项条件**的信号。登记不等于排期；
每条都写明缺什么，避免后来者把它当成已就绪的目标直接下刀。

## P7-60 logical-not opcode attribution

**登记日期**：2026-07-30
**来源**：P7-41 的一处对照缺陷修正（见 `P7-41-builtin-bridge.md` §2.4）

首轮 `every` 的 direct-loop 对照写成 `if (!cb_true(…))`，净差异常偏低。专门探针显示
**一次逻辑 NOT 在 zjs 约 18.17 cycles，qjs 约 3.06 cycles**，符号
`exec.vm_value.logicalNot`，**没有快速 op handler**。改成无取反的对照后，`every` 的
`zjs_specific_bridge_tax` 从 +10.29 移到 +25.99，与其余三个干净 rung 一致。

信号质量高：量级大、形状孤立、与 Array builtin 语义无关。但**当前只有一个意外 probe**，
立项前至少还缺四项：

- **JS 类型语义矩阵**。`!x` 的成本可能强依赖操作数类型（boolean / int / double / string /
  object / undefined / null）。单点探针无法区分「`ToBoolean` 本身贵」与「只对某些类型贵」。
- **same-runtime 的 P0/P1 稳定基线**。现有数字来自 P7-41 的诊断探针，不是按本战役采样纪律
  （偶数样本、ABBA、每侧两个冷缓存构建、全组合）测出来的。
- **实际 Pareto 总贡献**。18.17 vs 3.06 是**每次操作**的差；在真实脚本里 `!` 出现多少次未知。
  按当前排序规则，必须用**绝对 cycles 总贡献**（每次差 × 实际次数）而不是比值来排。
- **归因边界**。尚未区分这笔成本是**函数调用边界**（缺快速 handler 导致落到通用路径）
  还是 **`ToBoolean` 语义本身**昂贵。两者对应完全不同的一刀。

**当前状态（2026-07-30 更新，本条已画像完毕）**：四项前置全部补齐，见
`P7-60-logical-not/P7-60-logical-not.md`。结论与登记时的担心相反：

```text
genuine unfaithful divergence, and NOT dynamically cold
→ escalate (not deferred)
```

- **类型矩阵**：21 格 × 两次独立扫描。qjs 严格按 `quickjs.c:19096` 的 tag 判据分两档
  （immediate 18.0 insn / 2.7–2.9 cyc；其余 38–48 insn / 4.8–6.4 cyc）；**zjs 是一条平线**
  87–137 insn / 18.3–25.0 cyc，与类型无关。差值最大的恰是 qjs 有内联臂的四个 immediate tag
  （**+18.00 cyc** 均值），最小的是 qjs 也付调用的 object（+12.5）。
- **same-runtime 基线**：`ab4fc64b`、6 样本 ABBA、两次冷构建逐字节相同。复现 P7-41 探针
  为 **20.27 vs 3.13 cyc**（指令数 91.05 / 18.01 逐位复现）。
- **绝对 Pareto 贡献**：动态计数（临时 tag 计数器，已还原）。`microbench`(75) /
  `p0_sentinel`(48) / `named_eval` / `bootstrap` 全 **0**；`wrapped` 的 5 个非零条目**就是
  P7-41 的探针本身**；但 **16 个产品型负载全部非零，其中 11 个每轮 >10⁵ 次** ——
  `earley-boyer` 2.06×10⁷ 次 = **1.53% cycles / 364.9 M**、`mandreel` **1.35%**、
  `raytrace` **1.03%**、`splay` 0.77%、`zlib` 275 M。比 P7-51A 那条 deferred 项
  （唯一产品负载 ≈8.9 k cycles 全程）大四到五个数量级。
- **归因边界**：**是冷 dispatch 协议，不是 `ToBoolean`**。定周期 ×3 per-symbol 拆分给
  `toBoolean` 只有 **1.58 cyc（7%）**；同一引擎的 `op_if_false8` 做同语义判断，内联时
  33 insn / 4.3 cyc、被路由进 `cold_table` 时 121 insn / 22.6 cyc，冷路由税
  **+88 insn / +18.3 cyc** ≈ `op.lnot` 的全部成本。

**一刀的形状**：给 `op.lnot` 一个快 handler，immediate 臂复用引擎里已有的
`JSValue.asBranchImmediateBool`（`value.zig:450`，本身就是 `quickjs.c:19096` 的逐字镜像、
已被 `op_if_false8` 使用），complex 类型原封不动落回现有冷 handler。
**注意**：按字面的「最大阶段 ≥40%」判据本线落在「关闭」一侧（最大阶段 31%），
dossier §6.3 论证该判据的前提（各阶段可独立删）在此不成立，并把取舍交回协调者。
`splay` 不在受益面内（94.3% object 操作数，忠实 immediate 臂不覆盖）。

**执行结果（2026-07-30，P7-61）**：一刀已实施、已计量、**已按阈值回退**，见
`P7-61-lnot-hot-handler/P7-61-lnot-hot-handler.md`。

```text
immediate  +86.1% .. +91.2% cyc/op, +80.9% .. +85.7% insn/op   (4/4)
product    geomean +0.83%; earley-boyer +1.39% / mandreel +1.16% / raytrace +0.84%
splay      -0.04%（如预测，中性）
FAIL       complex types -2.17% .. -5.64% whole-case，稳定复现
           → 触发「complex types regress >= 1%」回退条款
decision = REVERT（机制不入库；字节码形态钉子保留）
```

病因是**确定性的 +8.00 insn/op**：热 handler 未命中后要**再间接跳一次**才能到达原本
一跳可达的冷壳。绝对值只有 +0.51 … +2.17 cyc/次，按语料加权在真实负载里最多值
`splay` 的 0.04%（模型与实测吻合到 0.27pp，五个负载全中），但合成口径超阈值。

**重启条件（任一成立）**：

- 采用**专用冷 handler + 直接尾调**的形状（`op_add_loc_cold` 的写法）消掉那 8 条指令，
  并当轮证明 immediate 热臂 codegen 未被扰动（`op_compare_cold` 有 +37 insn 的前科）；
- 或协调者把 complex 判据从合成口径改为**语料加权口径**，此时四条产品门槛全过。

**明确不批准**：顺手补 plain-object 快臂（qjs 的 lnot 快臂没有，那是第二个机制），
或把 lnot 与其它被冷路由的 opcode 打成一刀。

## same-flags property replacement should gate shape COW（deferred alignment fix）

**登记日期**：2026-07-30
**来源**：P7-50 归因 + P7-51A 事件普查（`P7-51A-redefine-census.md`）

状态：

```text
correct alignment opportunity
but dynamically cold in current representative corpus
→ deferred
```

`Object.replaceProperty` 在 `next_flags == old_flags` 时仍无条件调用
`ensureUniqueShapeForMutation`，函数对象 shape 被 hash-cons 共享，于是白克隆并销毁一整个
Shape。qjs 的 `js_update_property_flags`（`quickjs.c:10332`）把 shape prepare 与 flags 写入
**都**放在 `flags != (*pprs)->flags` 之内。**机制方向已核验为不忠实偏差，单事件成本 423.6 cycles，
一刀形状也已预批准** —— 唯一缺的是动态频次。

普查结果：除三个合成 NamedEvaluation case 外，170 个语料条目合计仅 **6 次**事件，
单条最大 1 次；`gbemu` 整轮 **21 次 ≈ 8.9k cycles**，而 builtin bridge 在 10 万次 callback 下
是 **2.74M cycles**。因此**不得**因为机制方向正确就抢在 P7-42 之前。

**重启条件（任一成立）**：

- 真实产品 workload 中出现高频 same-flags + shared-shape replacement；
- 在某个 Pareto case 中贡献超过约 10%；
- NamedEvaluation 赋值成为实际热点；
- 对其余 14 个 `ensureUniqueShapeForMutation` 调用点的**独立**普查发现高频同类路径
  （P7-51A 只统计了 `replaceProperty`，其结论不可外推到那些调用点）。

现在**不实现**，也**不继续扩大普查范围**。

## 已从候选转为结论或关闭的条目

- **SmallObjectSlab empty-arena retention** → P7-00 裁决 `does not generalise → permanently close`，
  机制与 qjs 逐项相同，不开 P7-01。
- **进程内存快照固定税** → 已由 P7-31 落地（`e94649c9`），gbemu +8.49%～+8.97%。
- **TypedArray 构造残余约 2x** → P7-30 判为分散（view wrapper 2.57x / zero fill 4.28x /
  plain construct 2.03x / out-of-line buffer 1.99x），本轮不追。
- **`array_map_callback = 2.618x`** → P7-40 证明不复现（过期二进制 + 非绑核采样两项混杂），
  权威值 cycles 1.364x；P7-20 的第 1 名与 17.2% 份额已作废。

## builtin→bytecode 回调桥的 driver 重入重派生（P7-42）

**登记日期**：2026-07-30
**来源**：P7-42 逐阶段归因（`P7-42-bridge-phase-attribution.md`）

状态：

```text
named redundant work inside a confirmed tax
but bounded at 18-29% of that tax
→ deferred, below the 40% one-cut threshold
```

P7-42 把 P7-41 的共享桥税（本树 canonical 重测 **27.26 cyc/回调**，P7-41 为 27.43）拆成
十四个每回调必经阶段，最大单一阶段 `S7c_vm_cache_rebuild` 只有 **6.98 cyc = 25.6%**，
其余十个落在 3.3–6.4 的带里 → 生产路线按停止条件关闭。

唯一点得出名字的冗余：`tryPushNativeBoundaryLeafArgsFast` 把 `*Entry`、callee `fb`、
参数/操作数窗口基址与新帧的 `pc == 0` 全部**写进内存后丢弃**，紧接着 `runTC` 经
`machine.depth → machine.top → entry.frame → frame.function → byteCode()` 把同一组值
重派生一遍（`S7c` 31 insn 中约三分之一，加上 `S7d` 的 `pc/sp/var_buf` 与可证恒为 false 的
`local_fast_blocked`）。事件画像与之吻合：税是**非内存**后端阻塞
（`stall_backend +31.19`、`stall_backend_mem +0.04`、`l1d_cache_refill 0`、`br_mis_pred 0`）。

**上限 5–8 cyc/回调 = 税的 18–29%**，因此**现在不实现**。

**重启条件（任一成立）**：

- 一刀门槛从 40% 下调，或桥税本身在某个 Pareto case 中的绝对份额上升；
- 有独立证据表明 `runTC` 入口的重派生同样支配非回调 driver 入口（脚本入口 /
  generator 恢复 / 构造器完成），使同一改动的受益面超出 builtin 回调；
- driver activation 的搬家（把回调驱动改成 continuation）被单独立项并证明可逆。

**明确不批准**：把 `S7a`…`S7e` 打成一刀（同时改 driver activation、Machine level 派生
与返回 outcome），或把 fence / Machine / roots / return 四层凑成 27 cycles。
