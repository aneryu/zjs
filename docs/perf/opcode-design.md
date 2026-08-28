# zjs opcode 精简设计与裁决记录

**PERF-OPCODE-SPACE**（roadmap owner-decision 槽，最高优先级前置项）。

> **现行目标（owner，2026-08-27）**：在**不改变栈式机器模型**的前提下，
> 精简 final-form 的物理 opcode id 数量。register VM、E1/E2、TOS caching
> 与消灭动态搬运指令均不在本轮范围内；相关材料保留为停议证据，不构成工作项。
>
> **执行权威**：§11（精简方案）；**批量 carrier 前置**：§10（单一声明源与逻辑/物理
> 编码描述）；**事实与机制**：§2、§4、§5、§8；**停议材料**：§3、
> §6.2–§6.4、§7、§9.2–§9.5。若停议材料与 §0/§11 冲突，以 §0/§11 为准。
>
> 本文取代并合并了
> `opcode-space-survey.md`、`opcode-audit.md`、`opcode-redesign.md` 三份
> （已删除，内容全部并入）。配套两份**只放资料、不放结论**的附属文件：
>
> | 文件 | 内容 |
> |---|---|
> | [`opcode-engines.md`](opcode-engines.md) | 四引擎指令集设计逐个记录 + 逐语义域对照矩阵 |
> | [`opcode-audit-table.md`](opcode-audit-table.md) | zjs 逐 opcode 原始数据（频次 / size / fmt / 发射方式） |
>
> `opcode-audit-table.md` 是采样快照，不是执行清单；其处置列在 §11.2 的
> 逐条审计完成前只产候选，不产判决。被推翻的估计集中在附录 B。

跨引擎事实全部读自本地源码检出，不是回忆：V8 15.4（`/home/aneryu/v8`）、
JSC（`/home/aneryu/WebKit`）、Hermes（`/home/aneryu/hermes`）、
QuickJS 2026-06-04（`/home/aneryu/quickjs`）。日期：2026-08-27。

---

## 0. 一页摘要

**目标只有一个**：减少 final-form 物理 opcode id；不以减少动态指令数、
切换寄存器 VM 或追平其他引擎的编号数为成功标准。

**现状**：工作开始时 254 在用 / 2 空闲；已经回收 9 个，现为
**245 在用 / 11 空闲**（§2.1、§2.5）。需求侧复审只把 FNABI 的首发需求
从约 25 修正为 2–3；typed 文档的 20–40 尚未被自己的证据门修订。因此
保守容量预算是 **22–43 个**，不是早期的 45–65，也不是无依据的 10–25
（§9.1）。

**本轮复审推翻了旧 §11 的核心假设**：不能在分相 decoder/effect API
建立前，就在 parser/中间优化阶段把新候选从 `op.X` 直接改成
`{carrier, sub}`。旧方案会让 peephole、CFG、catch-depth、atom/label
所有权和 inline eligibility 丢失逻辑 opcode 身份。现行迁移边界是：

> **编译器内部保留逻辑 opcode，直到 `resolve_labels` 完成所有匹配；
> 每个 final-form writer 才选择 direct id 或 `{carrier, sub}`。运行时
> `small_inline` 若重写 final bytecode，也必须 logical decode 后再走同一 encoder。**

因此本方案不是“把很多 handler 塞进一个 switch”这么简单，而是把
**逻辑指令身份**与**物理 8-bit 编码**分开。final-form 的 id 可以回收，
parser/lowered stream 既可沿用旧 direct id，也必须兼容已经落地的
`{using, sub}`，未来扩展再用 compiler-only carrier；项目已有 temp/short
同 id、按 phase 解码的先例。

**当前计划（§11）与裁决状态（owner 复审 2026-08-27，全文见 §11.7）**：

| 期界 | 物理编号目标 | 裁决状态 |
|---|---:|---|
| 基线 | 245/11 | 已验证 |
| 第一检查点 | ≤228/≥28 | **已批准（D5）**；到达后强制复盘 |
| 容量目标 | ≤212/≥44 | **暂缓为条件性目标（D6）**：typed/FNABI 提交具名 demand ledger 后才推进，不是无条件 KPI |
| 设计上界 | ≤196/≥60 | **非规范 envelope（D6）**：仅留在 rationale，不进里程碑表 |

第一步不是批量降级，而是完成 §10 的声明/解码基础；唯一确定亏损的融合
`put_loc0_get_loc0` 可独立并行退役（R0，已批准）。基础完成后再用一个普通冷
opcode 做 late-encoding 试点；试点通过后单独切换剩余声明派生产物，只有
这一步也过门，才扩大候选池。

**状态（owner 二轮复审 2026-08-27，D1–D12）**：架构原则**已批准**（D1）；
**R0 与 F0a0 已落地**（`6ea4c927` / `e9aaf765`，244/12）。**§10.8 已于
2026-08-27 冻结**（P0-1…P0-6 + 不变量 5、6 逐条确认，外加合同 5a
`Effects.branch_stack`），**F0a1 由此解除暂停并成为当前工作**。冻结前需
先闭合的四个基础模型——lowered form → final form（D10）、
logical operand → 物理编码（P0-2）、纯 spec → exec handler 绑定（P0-3）、
物理槽位 alias/quarantine/free 生命周期（D11）。F0b–F0d 仍按 §10.8 的逐片 gate 评审；
F0e 只批设计方向；C0 及以后继续暂停。裁决 4 的“暂停执行”现对 R0/F0a0/
F0a1 解除。机器模型证据线（§6.2–§6.4、§9.2–§9.5）继续
缓议（D8），且不是本方案前置。

---

## 1. 裁决记录与现行状态

| # | 事项 | 现行状态 |
|---|---|---|
| 1 | 单一声明源 + 生成器 | **已批准**；按 §10 修订后的逻辑/物理描述实现，是批量精简的前置 |
| 2 | register-vs-stack spike | **缓议且移出当前范围**；不阻塞 §11 |
| 3 | qjs 代码级忠实对齐 | **降为工具**；qjs 仍是性能尺与差分参照，不约束内部编码 |
| 4 | 增量回收 | **部分解除**：R0 与 F0a0 获准实施（D3/D9）；其余包按 §11.7 逐项开闸，不得把“目标确认”解读为整体实现授权 |
| 5 | 架构复审 D1–D8（2026-08-27） | **已裁**，全文见 §11.7；§10.8 合同冻结是 F0a1+ 的硬前置（D2/D9） |
| 6 | 二轮复审 D9–D12（2026-08-27） | **已裁**：F0a 收窄为 F0a0/F0a1；final form selection 与 physical encoding 拆分；alias 成为正式槽位状态；profile 以 form 为主键。**§10.8 已于 2026-08-27 冻结**——P0-1…P0-6 与不变量 5、6 经 owner 逐条确认，外加冻结时补入的合同 5a（`Effects.branch_stack`）。F0a1 由此解除暂停 |

现行次序：**R0 ✅ ∥ F0a0 ✅ → §10.8 冻结 ✅（2026-08-27）→ F0a1（当前）→
F0b–F0d（逐片评审，gate 见 §10.8 末表）→ C0 → G0（§10 阶段 5 的声明源
切换，净 0）→ C1 → 28 个空闲检查点（强制复盘）→（demand ledger 触发后）
44 个空闲容量目标**。F0e 只批设计方向，实现后置到新增逻辑指令或 28 检查点
之前，不是 C0 前置。60 不进 normative 里程碑。裁决 2 不在这条路径上。
以下小节保留裁决时的论证；与本段冲突时，本段为准。

### 裁决 1：是否照批「第一步」——单一声明源 + 生成器

**裁定：批准；它现在是 §11 F0 的第一项前置。**

**内容**：把指令集改成 JSC 那样「在一处声明、其余全部生成」（§3.3a）。

**建议：照批，且不必等裁决 2–3。**理由三条：

- **三个方案下都是净收益**：方案 A 需要它；方案 B 更需要（新指令集同样要
  声明，从零声明比改现有的六处手写容易得多）；方案 C 也需要。
- **它治的是正在流血的伤口**：我们每加一个 opcode 要在**六个地方**手写
  （id 常量、`opcode_info` 行、栈效应 switch、handler 表、若干扫描器名单、
  测试）。§5.2 第 3 条记录的缺陷类——降级 `put_super_value` 会让
  `super.x = v` 的函数**悄悄变得可内联，而且没有任何测试会变红**——就是
  这个的产物。这是已确认的真实机制，不是假设。
- **零行为变化目标，不是零实现风险**：前两阶段不消耗编号、不改编码，但
  三域 decoder/effect 的迁移面很大，必须靠 §10 的等价断言增量证明。

### 裁决 2：是否买「机器模型」的证据

**裁定：缓议，且不属于当前 opcode 精简目标。**以下内容仅作停议记录。

**内容**：一个受控的 register-vs-stack 派发 spike，预注册 policy，回答
唯一一个问题：**把槽位搬运折进操作数，在真实负载上能兑现多少周期？**

**最小形态**：取 2–3 个热函数（建议 raytrace / earley-boyer 的热循环），
手工把字节码改写成三地址形式，配一个只覆盖这几条指令的 register handler
集，A/B 测周期与指令数。

**为什么必须先买**：我们自己的帐本上，**手写 asm 省 16% 指令兑现 0.0%
时间**（同一张三骨架表里）。「43%–55% 的**派发**减少」（§2.2a）与「同比例的
**周期**减少」是两回事。押注对象是整个解释器加编译器后端，不能假设。

**policy 必写**：`target_workloads` 要按 PERF-T-SPIKE 的教训写死——
08-26 那次 FAIL 判定就是首轮选错负载（混浮点串行链把机制完全掩盖），
08-27 撤回。

### 裁决 3：「qjs 代码级忠实对齐」的地位

**裁定：降为工具。**qjs 仍是性能尺（bench-v8）与差分对拍参照；解释器
核心不再要求逐行可对照。方案 B 由此进入可评估状态。

> **⚠️ 裁决后核对：这条裁定比它看上去便宜——它不是新的偏离，而是与一份
> 已批准记录一致。**初稿把它写成一个待表态的开放问题，并说「寄存器机
> 终结这套方法」。**这个论证是错的**：约束型条款早已退役。
>
> [`qjs_alignment_charter_transition.md`](../qjs_alignment_charter_transition.md)
> 状态 **RATIFIED**（owner，2026-08-24，决议 D1-A），退役了三条**约束型**
> 条款——R1「qjs 没有的 fast path 必须删」、R2 property IC 移除决议、
> R3「IC/fusion = 换赛道作弊」判——并在 §5 明文：
>
> > 今后引用 qjs 实现仍是**诊断与设计参考的推荐做法**，只是**不再是变更
> > 的合法性条件**。`qjs:N` 注释保留原样——它们记录的是机制出处，不是
> > 持续义务。
>
> 保留条款里与本议题相关的是 **K3：QuickJS differential 基建不变**——而
> **机器模型改变不影响差分工具**，它比较的是可观察行为，不是字节码形态。
> 按仓库现行 spec-first 规则，最终裁决权属于 ECMA-262/test262；QuickJS
> 只是比较实现，出现已证实偏离时记录 divergence，不反向改成 QuickJS 行为。
>
> ⇒ **方案 B 不需要退役任何东西。**「降为工具」这条裁定是在复述一个
> 2026-08-24 就已生效的状态，而不是新开一个口子。

### 裁决 4：增量回收清单的处置

**现行裁定（2026-08-27 二轮复审更新）：R0 与 F0a0 已解除暂停（D3/D9），
其余包继续暂停。**原清单的数字与机制已经被本轮读码推翻：`make_*_ref`
不能按旧方案无成本 4→1；TDZ 也不能拆成两条纯检查指令。§11 以逻辑/物理
身份分离重新给出方案。

后续包的解除条件：§10.8 冻结（P0-1…P0-6 修订经 owner 确认），然后
F0a1/F0b–F0d 按 §10.8 末表的合同 gate 逐片评审，并且 §10 的
effect/decoder 基础满足对应包的前置。任何时候都只能**逐包恢复**，
不是把 84 个冷池一次性全部降级。

### 1.5 K4（仅约束停议中的机器模型线）

以下仅记录裁决 2 将来若重开时的合规路径，**不是 §11 前置**。上述过渡记录的
保留条款 K4 指向 `architecture.md` §8「Stack Bytecode VM Status」：

> Re-evaluate the bytecode architecture only when the semantic gates are
> stable, hot spots in call / property / array / string have been converged
> with qjs mechanisms, and **PMU evidence shows operand traffic / dispatch
> as the main bottleneck.**

同章 §1 还有一条现行立场：*"There is no evidence supporting a rewrite to a
register/accumulator VM"*。

**它不与任何一条裁定冲突，但它规定了裁决 2 复议时必须拿出什么：**

> **方案 B 不是一个可以直接裁的分叉，而是一次有明文准入条件的「重估」。
> K4 的第三条准入条件——「PMU 证据显示 operand traffic / dispatch 是主
> 瓶颈」——可由 §9 的 E1 产出。**

注意 K4 的措辞点名了 **operand traffic / dispatch**。若裁决 2 重开，E1
会是进入机器模型重估的必需证据；当前不重开，因此不执行也不阻塞精简。

**但 K4 是三条准入条件，E1 只答第三条。**另外两条必须单独盘点，否则
E1 出数再漂亮也开不了门：

| # | K4 条件 | 状态 | 依据 / 缺口 |
|---|---|---|---|
| 1 | semantic gates are stable | **满足** | test262 0/49778，单测 2365/0，四门长期绿 |
| 2 | call / property / array / string 热点已与 qjs 机制收敛 | **⚠️ 未判定** | 需要一次简短的收敛盘点或 owner 表态。已知素材：`bench-v8-status.md` 的公开记分、1017 条实现差异审计里 CONFIRMED-EXEC 的剩余项、call/property 线历次战役的结论。**这是本文唯一一条需要 owner 表态才能推进的前置。** |
| 3 | PMU 证据显示 operand traffic / dispatch 是主瓶颈 | **待测** | 即 E1（§9.5） |

⇒ **E1 可以与条件 2 的盘点并行**，但两者都到位之前，K4 不开。

---

## 2. 现状：实测事实

### 2.1 编号账

| 引擎 | 在用 | 空闲 | 备注 |
|---|---:|---:|---|
| **zjs** | **245** | **11** | 逐 id 核过：`opcode_info` 里 0–253 有行，其中 9 行是 `unused_N`；254/255 在 main 上没有表行。255 是无效 opcode 测试喂的字节，254 被 T-spike 原型占用（分支上）。本次工作开始时是 254/2 |
| QuickJS | 244 | 12 | 我们的上游形态 |
| V8 Ignition | **210** | 46 | 193 独立 handler + 1 `V_TSA` + 16 `Star0..15` |
| Hermes | **220** | 36 | 180 `DEFINE_OPCODE_n` + 40 由 `DEFINE_JUMP_n` 展开 |
| JSC | **194** bytecode（+85 LLInt helper id = 279 OpcodeID） | 60 | `static_assert(NUMBER_OF_BYTECODE_IDS < 255)`；194 由 135 个声明点生成 |

本文“在用”按**已保留的物理 id**计数，包含不可执行的 `invalid` 哨兵；因此
245/11 等价于 244 条可执行 final opcode + 1 条 `invalid` + 11 个空位。

**zjs 是五者里最挤的**，而且挤得有原因——我们加了 QuickJS 没有的 22 个
融合指令。墙是真的并且已经在挡路：**T-spike 原型需要两个编号只拿到一个**，
所以属性**写**留在了通用路径上。

早期未来需求账如下；§9.1 只完成了 FNABI 的首发审计，typed 仍是需求方
自报预算：

- FNABI `CALL_NATIVE_*`：旧稿**约 25 个**（`fun-native-plugin-design.md:213`）
- typed 特化族 T1–T4：**20–40 个**（`type-directed-optimization-plan.md:527`）

**旧合计 45–65，供给 11。**修订见 §9.1：FNABI 首发改为 2–3，typed
仍保留 20–40，故保守容量预算为 **22–43**。它要求做物理编号精简，但不要求
改变机器模型。

### 2.2 动态执行账

剖析构建（`ZJS_PROFILE_ALL=1 zjs-profile --profile-opcodes`，该环境变量
解除了 profiler 的 40 行上限）跑 15 个 zoo 基准——richards、deltablue、
crypto、raytrace、navier-stokes、earley-boyer、regexp、splay、pdfjs、
typescript、box2d、code-load、gbemu、mandreel、zlib：

```
观测到的 opcode 执行总数:              41,888,384,774
终流物理表行（id 0..253）:               254
额外的 temp logical rows:                19  (与短指令复用 id，不出现在终流)
采样表标为至少执行过一次:                156
采样表标为从未执行:                       79
执行过但 < 0.0001%:                      23
=> 频次 <= 0.0001% 的冷池:              102
```

这里的 254 是**物理命名空间宽度**，不是当前 245 个已保留 id；19 是声明表中
额外的 temp logical rows，也不是从 254 再扣。156/79 来自仍含历史身份的采样
快照，不能相加推导当前编号账；当前账只认 §2.1，候选频次在 F0 按 logical
profile 重采。

**按「是不是栈机专属开销」分类**（供停议机器模型线参考；现行 §11 只用它
排除热项，不据此改变机器模型）：

| 类别 | 编号数 | 执行次数 | 占全部动态指令 | 寄存器机里的对应物 |
|---|---:|---:|---:|---|
| **槽位搬运** `get/put/set_{loc,arg,var_ref}{0..3,8,宽}` | **48** | 140.6 亿 | **33.6%**〔另一口径 36.1%〕 | **消失**——变成指令的操作数字段 |
| **融合指令**（按前缀半件事分解，见 §2.2a） | 22 | 98.2 亿 | 23.45% | **大部分也消失**——只有 2.7pp 是真语义工作 |
| **栈洗牌** `dup`/`swap`/`insert2,3`/`perm3,4`/`rot3l`/`nip*` | 9 | 1.29 亿 | 0.31% | 消失（只留一条 `mov`） |
| `drop` | 1 | 0.85 亿 | 0.20% | 消失 |
| 其余 | ~164 | 178.9 亿 | 42.71% | 大体一一对应 |

**编号侧**：**58 个编号**（槽位搬运 48 + 栈洗牌 9 + `drop` 1，占在用编号
的 24%）用于「因为是栈机才需要」的事。

**执行侧的诚实口径**（⚠️ 本节初版对融合家族判错，见 §2.2a）：
- **必定消失：约 43%**——48 族 + 洗牌 + drop（本表口径 34.1%，第二套采集
  口径 37.6%）**加上 9.3% 的「前缀是纯槽位搬运」的融合指令**。
- **大概率消失：再 11.3%**——前缀是常量物化的融合，加素的 `push_*`。
- **确实保留：2.7%**——前缀做真语义工作的六条融合。
- **量级结论：栈机专属派发在 43%–55% 之间，不是初版说的 34%–38%。**

### 2.2a 融合家族必须按「前缀半件事」分解，不能整块判「不消失」

初版写的是「融合的 23.45% 不会消失，不要把它算进收益」。**这句话只对
2.7pp 成立。**

理由在 §10.2b 已经写清了，只是没有回头用到这里：**融合指令是前缀替换
——它只占自己 1 个字节、只做前半件事，后一条指令原样留在流里。**所以
419 亿账本里记在融合 opcode 名下的执行次数，**就是那前半件事的执行次数**。
于是判「消不消失」要看的是**前缀半件事是什么**：

| 前缀半件事 | 条数 | 占全部动态指令 | 寄存器机下 |
|---|---:|---:|---|
| **纯槽位搬运** `get_var_ref0_get_loc8`(2.55%)、`get_loc8_push_2`(1.95%)、`put_loc8_get_loc8`(1.43%)、`get_loc8_push_1`(1.43%)、`get_loc8_push_i8`(0.96%)、`get_loc0_field`(0.52%)、`push_this_put_loc0`、`get_loc2_field`、`get_loc2_field2`、`put_loc0_get_loc0` | 10 | **9.33%** | **消失**，与 48 族同性质 |
| **常量物化** `push_0_or`(9.00%)、`push_2_sar`(1.12%)、`push_0_shr`(0.95%)、`push_i8_add`(0.26%) | 4 | **11.32%** | **大部分消失**——JSC 的 `Fits` 把常量映射进寄存器索引区（narrow 的 16..127），`x \| 0` 根本不需要 push；V8 为同一目的备了 12 条 Smi 立即数二元指令。残留取决于寄存器压力与常量是否循环不变 |
| **真语义工作** `sar_get_array_el`、`eq_if_false8`、`cmp_if_false8`、`get_field2_call_method`、`get_var_field`、`get_field_field2` | 6 | **2.68%** | **保留** |
| 合计 | 20 | 23.33% | 与表中 23.45% 自洽（差值是 `get_length` 等） |

**这个错误会传染**：E1 的被测集初版按「融合不消失」把这 10 条纯搬运前缀
排除在外，等于把 9.3% 的纯搬运派发放在判决之外——照 kill 规则可能在被测集
外还躺着 9% 时就把方案 B 杀掉。**policy 已改为三层：Tier 1（48+9+drop+
10 条纯搬运前缀 = 68 个 handler）进判决，Tier 2（常量物化）只报告不进
判决。**

> **口径注（2026-08-27 复核修正）**：百分比是**采集口径依赖的**，两套
> harness 给出 34.1% 与 37.6%（附录 C）。以下修正的是另一件事——本表初版
> 写的是「66 编号 / 31.66%」，
> 两个数都不对。id 数错在把 24 个融合算进「会消失」的编号里（融合不消失），
> 同时**漏掉了整个 `set_*` 族**（`set_loc`×6、`set_arg`×5、`set_var_ref`×5
> 共 16 条；32 + 16 = 48 才闭合。48 = loc 18 + arg 15 + var_ref 15）；百分比错在同一个 `set_*` 遗漏。现值由脚本从
> `src/bytecode.zig`（编号）与附录数据表（执行数）分别取，两侧不再混用。

### 2.3 融合指令逐条定价

现行分类账记 22 个融合/专用融合 id；下表列 20 条定价主表（2026-08-27
复核补入 `get_var_ref0_get_loc8`、`get_loc8_push_i8`、`push_i8_add`），
完整名单与分类必须在 §11 F0 从声明表重新生成。当前唯一可独立下结论的
负收益项是：

| 融合指令 | 执行次数 | 占比 |
|---|---:|---:|
| push_0_or | 3,768,876,208 | 9.00% |
| get_var_ref0_get_loc8 | 1,068,564,830 | 2.55% |
| get_loc8_push_2 | 816,208,860 | 1.95% |
| put_loc8_get_loc8 | 600,756,243 | 1.43% |
| get_loc8_push_1 | 599,826,174 | 1.43% |
| push_2_sar | 470,159,471 | 1.12% |
| sar_get_array_el | 456,529,784 | 1.09% |
| get_loc8_push_i8 | 402,546,496 | 0.96% |
| push_0_shr | 395,847,723 | 0.95% |
| eq_if_false8 | 280,044,525 | 0.67% |
| cmp_if_false8 | 277,096,862 | 0.66% |
| get_loc0_field | 216,054,046 | 0.52% |
| push_this_put_loc0 | 108,967,999 | 0.26% |
| push_i8_add | 107,068,282 | 0.26% |
| get_loc2_field | 74,268,031 | 0.18% |
| get_field2_call_method | 63,527,185 | 0.15% |
| get_var_field | 24,552,997 | 0.06% |
| get_loc2_field2 | 21,890,348 | 0.05% |
| get_field_field2 | 21,334,593 | 0.05% |
| **put_loc0_get_loc0** | **8** | **0.000%** |

未列入主表但审计表已有读数的还有 `call_method_apply_fwd`；主表 20 行加它
与“22”仍差一项（§2.2a 的占比差值指向 `get_length` 一类），因此 F0 关闭该
口径前，不引用“除一条外全部挣钱”作为执行依据。

`put_loc0_get_loc0` 就是我们的 `Ldr*`：一个编号、一个 handler、一份
I-cache 足迹，买到 419 亿次里的 8 次执行。

### 2.4 与 QuickJS 的差集

```
QuickJS 差集口径：244 − 15 个历史差异 + 22 个自加融合 = 251
现役编号口径：   254 个在用起点 − 9 个已回收 = 245
```

两行回答不同问题，不能用 `251 → 245` 相减解释回收数。

**QuickJS 有而我们没有的 15 个**（历次回收的战果）：`dup1/2/3`、
`insert4`、`is_undefined`、`perm5`、`rot3r/4l/5l`、`swap2`、`typeof_is_*`
（并入 `using` 平面），加上退役的 `nip1`、降级的 `check_ctor_return` /
`set_proto`。

### 2.5 已落地的回收（9 个编号，全部四门绿）

| 波次 | opcode | 机制 | 释放编号 | 验收 |
|---|---|---|---:|---|
| pilot | `check_ctor_return` | 降级 | 42 | 2364/0 |
| A-1 | `nip1` | **退役**（真死代码） | 16 | 2364/0 |
| 1' | `set_proto` | 降级 | 76 | 2364/0 |
| — | `put_super_value` | 降级 | 72 | 2364/0 |
| — | `to_object` | 降级 | 111 | 2364/0 |
| M-1 | `with_*` 五个 | **合并** → `dyn_env_probe` | 114–117 | 2365/0 + test262 0/49778 |

`with_*` 合并的详情见 §5.1c。另有一次改名：`plus` → `to_number`（原因见
§8）。

---

## 3. 五引擎对照（设计资料；机器模型结论停议）

> **完整的逐引擎设计记录与逐语义域对照矩阵，见
> [`opcode-engines.md`](opcode-engines.md)。**本节只保留做决策要用的部分。
>
> 那份对照带来一条修正本节框架的结论：**他们不是「普遍更省」，而是把编号
> 花在别处。**寻址相关三行（局部搬运 + 作用域变量 + 栈洗牌）JSC 花
> **8** 个编号、我们花 **72**；但属性访问两行 JSC 花 **29**、Hermes 花
> **32**，都**比我们的 17 多**（它们每条带内联缓存 metadata / 宽度变体），
> JSC 在 generator/async 上花 14 条而我们只花 6 条。
>
> ⇒ **他们把编号花在优化上，我们把编号花在寻址上。**这比「我们臃肿」精确
> 得多，也更有行动指向。

### 3.1 机器模型（停议背景，不是当前分叉）

| 引擎 | 模型 | 二元加法的形态 | 出处 |
|---|---|---|---|
| **JSC** | 纯寄存器（三地址） | `add dst, lhs, rhs`，全部 `VirtualRegister` | `bytecode/BytecodeList.rb:1312` |
| **Hermes** | 纯寄存器（三地址） | `DEFINE_OPCODE_3(Add, Reg8, Reg8, Reg8)` | `BCGen/HBC/BytecodeList.def:210` |
| **V8 Ignition** | 累加器 + 寄存器文件 | 结果隐式进累加器；`Ldar`/`Star` 搬运 | `interpreter/bytecodes.h:87,110` |
| QuickJS | **栈机** | `get_loc a; get_loc b; add; put_loc c` | `quickjs-opcode.h` |
| **zjs** | **栈机**（继承自 QuickJS） | 同上 | `src/bytecode.zig` |

Hermes 的操作数直方图把这件事说得最清楚：220 条展开后的指令
（180 条 `DEFINE_OPCODE_n` + `DEFINE_JUMP_n` 展开）以
`Reg8` 为绝对主力；精确数量以 [`opcode-engines.md`](opcode-engines.md)
的同一采集脚本为准，本文不再维护另一份易漂移的副本。
**它的指令绝大多数在寻址寄存器。**

三家里两家是**纯**寄存器机；V8 是混合，为了**编码密度**付 `Ldar`/`Star`
的派发。若未来重开裁决 2，纯寄存器模型才是机器模型对照；**这不是当前
精简方案的结论**。

**这条事实的直接后果**：「借鉴 V8/JSC/Hermes 的 opcode 设计」这句话里有
一半对栈机根本不适用。**必须先把两半分开**，否则会把「他们不需要某类
指令」误读成「那类指令是冗余的」——附录 B 记录的两次机制判错（super 族
和类命名族）就是没先分这一刀。

### 3.2 我们的 frame 已经是一个寄存器文件（停议背景）

这决定了迁移的难度层级。`frame.locals`、`frame.args`、`frame.var_refs`
**已经是可索引的数组**，运行时数据布局本来就是寄存器文件的样子——缺的
只是让指令去寻址它。要改的是三处：

1. **指令编码**：操作数里带槽号（`loc8`/`loc`/`arg`/`var_ref` 这些格式
   我们已经有，只是目前只用在专门的搬运指令上）。
2. **编译器的操作数分配**：从栈纪律改为槽位分配。**这是全案最大的一块。**
3. **handler 读操作数而非弹栈**：`src/exec/` 现有 **481 处**
   `stack.pop/push/peek` 调用点；`src/parser.zig` 有 **331 处**发射点；
   热派发文件 6721 行。

### 3.3 他们怎么组织指令集

#### (a) JSC：在一个 DSL 里声明一次，其余全部生成 ← 最直接可用的一条

`bytecode/BytecodeList.rb` 是唯一真源，`generator/main.rb` 从它生成
`Bytecodes.h`、`BytecodeStructs.h`、LLInt 偏移、metadata 布局、以及三套
宽度的发射器。

数字：**194 个 opcode id 只有 135 个声明点**（125 个 `op :` + 10 个
`op_group`）。`op_group` 的语义：

```ruby
op_group :BinaryOp,
    [ :eq, :neq, :stricteq, :nstricteq, :less, :lesseq, :greater,
      :greatereq, :below, :beloweq, :mod, :pow, :urshift ],
    args: { dst: VirtualRegister, lhs: VirtualRegister, rhs: VirtualRegister }
```

十三个变体**各自保留独立的 opcode id**（派发仍然直接，没有二次间接跳转），
但只声明一次，共享同一个 struct 布局、同一份 metadata 形状、同一个生成出
来的访问器类。

**这条是 JSC 与我们「合并」思路的关键分歧**：
- **合并**（我们做的 `with_*` 5→1）：省编号，但把区别推进运行时 `switch`。
- **JSC**：保留编号（派发更直接），但消除维护面。

**编号充裕时 JSC 的取舍更好，编号紧张时才轮到合并。而编号是否紧张，
取决于机器模型（§2.1 + §2.2）。**

#### (b) 宽度策略：三家三种答案，没有一种是我们现在这样

| 引擎 | 做法 | 出处 |
|---|---|---|
| V8 | `Wide`/`ExtraWide` 两个真 bytecode，把**紧随其后那条指令的全部可缩放操作数**放大 2×/4× | `bytecodes.h:678-719` |
| JSC | 生成器自动三套：`emit<Narrow>` 装不下退 `Wide16`，再退 `Wide32` | `generator/Opcode.rb:234-238` |
| Hermes | **手写 18 个 `*Long` 变体**（`MovLong`、`GetByIdLong`…） | `BytecodeList.def` |
| **zjs** | **每个宽度一个手写编号，且不成体系** | `get_loc0/1/2/3` + `get_loc8` + `get_loc` 六个编号做同一件事的三种宽度；`put_loc`/`get_arg`/`put_arg`/`get_var_ref`/`put_var_ref` 各来一遍，`set_*` 三族再来一遍 = §2.2 那 48 个编号 |

⚠️ **重要限定**：前缀平面**扩的是操作数宽度，不是编号空间**——它买不到
一个新编号（§3.5）。这里借鉴的是「宽度不该由人手动切成多个 opcode」，
**不是「用前缀解决编号荒」**。

#### (c) Hermes：布局相等断言 + 极少的类型化变体

`ASSERT_EQUAL_LAYOUT3(Add, AddN)` 等 **15 对**断言，编译期钉住「这两条
指令逐字段同布局」。换来的是：解释器可以把类型化变体当作通用变体的原地
替换，反优化只是改一个字节。

**Hermes 只有 8 个类型化变体**：算术四个 `AddN`/`SubN`/`MulN`/`DivN`，
跳转四个 `JLessN`/`JNotLessN`/`JLessEqualN`/`JNotLessEqualN`。

**对 typed plan 的意义**：Hermes 的「类型化字节码」比我们设计的便宜得多
——不是一个新指令族，是同布局的兄弟指令。而它之所以能这么便宜，正是因为
`Add r,r,r` 本来就带着操作数，特化只需省掉检查。

### 3.4 他们怎么省编号

#### 四种扩容/回收机制

**(a) 一个编号后面挂二级命名空间——所有引擎都在用**

| 引擎 | 载体 | 装载 | 二级派发成本 |
|---|---|---|---|
| QuickJS | `OP_special_object` (u8) | 7 个特殊对象 | 二级 `switch`，失去直接线索化 |
| QuickJS | `OP_define_method` (atom+u8 flags) | 6 种组合 | flag 测试 |
| Hermes | `CallBuiltin` (UInt8) | **82 个 builtin**，自带 `static_assert(_count <= 256)` | 数组索引 + 间接调用——**被本来就要做的调用吸收** |
| V8 | `InvokeIntrinsic` (u8) / `CallRuntime` (u16) | 第二个 256/65536 命名空间 | 一次额外间接 |
| **zjs（已在用）** | `using`（id 244，u8 子操作数） | **已吸收 16 个冷 op**（子槽 3–18；子槽 0–2 是 `using` 自己的 create/dispose/dispose_throw） | 二级 switch |

V8 在源码注释里明确把这当作逃生阀
（`interpreter-generator.cc:2679`）：
> `// TODO(neis): Turn this into an intrinsic when we're running out of bytecodes.`

**成本画像才是设计教训**：Hermes 几乎不付钱，因为二级派发落在它本来就要
做的调用上；QuickJS 和 zjs 付一次真实的二级分支。**所以这个机制对冷
opcode 是对的，对热 opcode 是错的。**

**(b) 退役或合并冷 opcode——V8 反复做**（从 V8 git history 核实）

| commit | 内容 |
|---|---|
| `3b6773ba3d1` | 删 `ToBoolean`，并入 `JumpIfToBoolean*` |
| `e06d57b05de` | 删 `TestNotEqualsStrict`（parser 发 `TestEqualsStrict` + not） |
| `f633218b624` | 删**全部** `Ldr*`，改用 Star lookahead——*"we get some small wins … probably due to reduced icache pressure since there are less bytecode handlers"* |
| `a8176a530c3` | 删 `Nop` |

零运行时成本，而且**可能改善 I-cache**。这是最便宜的编号来源。

**(c) 相位作用域的编号复用——QuickJS 的手法，zjs 已继承**

QuickJS 用互补的宏定义把 `quickjs-opcode.h` 包含两次，于是 19 个临时
opcode 与前 19 个短 opcode 占用**相同编号**（178–196）；哪个含义生效由
编译相位决定，运行时痕迹只有 `short_opcode_info(op)` 里的索引偏移
（`quickjs.c:22176-22186`）。zjs 有同样的结构（`op_temp_start = 178`,
`op_temp_count = 19`）。**这一条我们已经榨干**；再扩要找到另一对可证明
opcode 集不相交的相位。

**(d) wide 平面里的两字节 opcode id——JSC 搭好了脚手架但从未启用**

JSC 的生成器已经把 opcode id 宽度按平面参数化（`OpcodeSize.h:76-97`）：
`Traits` 可以声明 `maxOpcodeIDWidth = Wide16`，此后 wide16/wide32 指令
携带 **2 字节** opcode id 而 narrow 保持 1 字节。发射侧的 `Fits` 检查已
允许 wide 平面的 id 到 65535（`generator/Opcode.rb:226-250`）。今天
`JSOpcodeTraits::maxOpcodeIDWidth = Narrow`，处于休眠。

**这是唯一一个真正扩展*编号*的工业级设计，而连 JSC 自己都没打开。**
需要几千个 opcode 时它是对的参照；为了四十个则是过度设计。

#### 三种正统设计手法（各有源码或 commit 证据）

1. **flag 操作数吃掉变体。** V8 把 `StaGlobalSloppy` + `StaGlobalStrict`
   合成 `StaGlobal`（commit `e8a0a3717c3`，理由：feedback vector 已经是
   language mode 的权威来源）；JSC 的 `ECMAMode`、`ResolveType`（13 值）、
   `GetPutInfo`、`PutByIdFlags`、`PrivateFieldPutKind` 全是这个模式。
2. **哨兵值吃掉检查型 opcode。** TDZ 三家一致；V8 更把 `ForOfNext` 的
   done 输出也用 hole 表示，省掉一个输出寄存器（commit `02a725e2a07`）。
3. **折进相邻指令的操作数。** Hermes 把 `set_proto` 折进
   `NewObjectWithParent`、把 home object 折进 `CreateBaseClass` 的输出、
   把 strict 折进 `DelByVal`；V8 把 `StackCheck` 折进 `JumpLoop`
   （commit `6c1e09aebe9`：*"Now that it is implicit in function entry and
   loop iteration, there is no need for an explicit bytecode"*）、把
   `OsrPoll` 折进 `Jump`。

第三条尤其值得注意：**Hermes 处理 `set_proto` 的方式，正是我们用降级
解决的同一个问题的另一种解法——它根本不让这条指令存在。**

### 3.5 前缀平面的真实成本（为什么它退出了范围）

- **V8**：带前缀的指令要走**两次间接跳转**而不是一次（前缀 handler 做
  完整的第二次派发）。handler 三倍化（215 个 opcode 对应 522 个 handler
  builtin）；派发表 768 × 8 B = 6 KB。wide handler 里每次保存/重载帧内
  字节码偏移都要 ±1 修正（`interpreter-assembler.cc:100-116`）。
- **JSC**：从生成的汇编实测——narrow 派发是 5 条指令，wide16 前缀
  handler 是 7 条、wide32 是 9 条，**外加一次额外间接分支**，而且所有
  wide16 指令共享同一个间接跳转点，对分支预测器不利。每个 handler 存在
  三份：`LLIntAssembly.h` 有 7.67 MB、582 个 opcode 标签。

对 zjs 而言——整个派发设计围绕间接跳转地板和一座手调 handler 岛构建——
**handler 三倍化是一个巨大且已被充分理解的风险**。

### 3.6 大家把编号花在哪（校准用）

| 引擎 | 最大的编号消费者 |
|---|---|
| V8 | 16 个 `Star0..Star15`（**用真实网站字节码体积 −8~9% 论证**，16 个编号共用**一个** handler）、12 个 Smi 算术特化、12 个常量池跳转变体 |
| Hermes | 宽度变体：`Long`/`Short` 后缀占 **39/220 = 17.7%**；光跳转就 **45 个编号**（20 个逻辑跳转各配短/长两种地址宽度，加 5 条特殊形式）。设计文档自承取舍：*"we are trading off with an increasing number of opcodes to handle different operand widths … We believe that we are able to avoid opcode explosion by generating the code smartly."* |
| JSC | **完全没有**烧进操作数的短指令形式。改用 `Fits<VirtualRegister, Narrow>` 把 locals/args/constants **重映射**进 −128..127，让多数指令自然装进 narrow（`Fits.h:117-155`）。编号花在融合的 compare+jump 组（14 个 `BinaryJmp`）。 |
| QuickJS / zjs | 66 个寻址/常量短 opcode（口径不同于 §2.2 的 58 个栈机专属 id）+ 我们加的融合 |

**JSC 是有趣的异类：它用重映射操作数值来买 narrow 编码，而不是靠铸造
opcode。**

### 3.7 反向借鉴：他们有而我们没有的

| 来源 | 机制 | 为什么值得看 |
|---|---|---|
| JSC | **checkpoints**（`iterator_open`/`iterator_next`/`instanceof`/`*_varargs` 在 `BytecodeList.rb` 声明 `checkpoints:`） | 融合 opcode 无法中途 deopt 的通用解法：一条 bytecode 内部有多个可恢复点。「语义多步、编码一步」同时保住 OSR |
| JSC | `call_ignore_result` | 语句位置的调用不需要 dst 寄存器和 value profile |
| Hermes | `AddN`/`SubN`/`JLessN`… | 类型推断证明是数字后的免检版本——**typed 路线在字节码层的形态** |
| Hermes | `GetOwnBySlotIdx` | 编译期已知槽号的直接读写，**T-spike 想做的事的终局形态** |
| Hermes | `StoreNPToEnvironment` | 存非指针值免写屏障——我们有 GC 屏障，直接可借鉴 |
| Hermes | `TypeOfIs` 位集 + `JmpTypeOfIs` | 一条指令表达 `typeof x === "object" \|\| typeof x === "function"` |
| V8 | `Star0..Star15` | 用真实网站字节码体积 −8~9% 论证的编号投资 |
| V8 | Smi 立即数二元族（12 条） | `x + 3` 不必先 push 常量 |

Hermes 的 `JLessN` 注释还提供了一条我们做 `cmp_if_false8` 类融合时必须
回应的论证（`BytecodeList.def:977-981`）：*"Since NaN comparisons always
return false, 'not less' != 'greater or equal'"*——取反跳转不能靠 `not` +
`JmpTrue` 合成，必须成对存在。

---

## 4. 逐族审计（全部按实现核对）

**方法**：三个数据源，缺一不可——(1) 动态频次（419 亿次剖析）；
(2) **发射路径逐条确认谁产生这个字节**；(3) 跨引擎对照**读实现而非匹配
名字**。

七个族，我们花 43 个编号，别人花 0–4 个，其中**四个族执行次数精确为 0**：

| 族 | zjs 编号 | 执行次数 | V8 | JSC | Hermes | 核对后的结论 |
|---|---:|---:|---:|---:|---:|---|
| TDZ 检查变体 | 9 | **0** | 4 | 2 | 3 | 语义载体 9→3 可省 **6**；旧“纯检查”分解作废 |
| Reference 具体化 | 6 | **0** | 0 | 0 | 0 | 逻辑语义保留；按物理编码格式分组打包 |
| `with` 专用访问 | 5 | 120 | 0 | 0 | 0 | **已合并，省 4** ✅ |
| super | 4 | **0** | 1 | 0 | 0 | `put_super_value` 已降级；其余 3 仅作候选 |
| 类定义/命名 | 6 | 1,662,159 | 0 | 1 | 4 | `set_name` 保留；其余 5 仅作候选 |
| 栈洗牌 | 9 | 128,992,268 | 0 | 0 | 0 | 需先补 catch/identity/resident 审计，不预记收益 |
| 一元 `+` 等 | 4 | 602 | 3 | 4 | 2 | **0**——`plus` 就是我们的 ToNumber（已改名） |

### 4.1 TDZ 检查变体（9 个编号，0 次执行）

`get_loc_check`、`get_loc_checkthis`、`put_loc_check`、`put_loc_check_init`、
`set_loc_check`、`set_loc_uninitialized`、`get_var_ref_check`、
`put_var_ref_check`、`put_var_ref_check_init`。

三家**不是「只有一条检查 op」**，各自的检查型 opcode 数量是：

- V8 **4 条**：`ThrowReferenceErrorIfHole`、`ThrowSuperNotCalledIfHole`、
  `ThrowSuperAlreadyCalledIfNotHole`、`ThrowIfNotSuperConstructor`
  （`bytecodes.h:484-488`），配 `LdaTheHole` 哨兵。
- JSC **2 条**：`check_tdz` + `is_empty` 谓词。
- Hermes **3 条**：`ThrowIfEmpty`、`ThrowIfUndefined`、
  `ThrowIfThisInitialized`。

**旧结论“拆成两条纯检查 op”不成立。**实现里至少有下列不可丢失的差异：

- `get_loc_checkthis` 不在当前 realm 物化错误，而是返回
  `DerivedThisUninitialized` 交给 caller realm；
- `put_loc_check` 同时执行 TDZ 与 const-write 检查；
- `put_loc_check_init` 只对 derived `this` 执行 once-only 检查，普通 lexical
  init 允许覆盖；
- `put_var_ref_check` 与 `put_var_ref_check_init` 的谓词方向相反，且
  `put_var_ref` 的“初始化写”身份会影响 const 许可。

所以 `check_tdz; put` 既改变异常形态，也会改变 const/init 语义。正确的
9→3 是**物理编码合并、逻辑语义不合并**：

```
checked_loc     <kind:u8, idx:u16>  // get / get_this / put / set / init
checked_var_ref <kind:u8, idx:u16>  // get / put / init
set_loc_uninitialized <idx:u16>     // 保留独立 reset 语义
```

两个载体的 handler 按 `kind` 进入今天同一条语义臂，包括 caller-realm、
const 与 init 规则；每条仍单派发。物理上 9→3，净省 6；代价是载体形式
3→4 字节。把 `set_loc_uninitialized` 也塞进载体理论上可到 9→2，但没有
额外需求，不为多省一个 id 扩大正确性面。

**成本**：约 70 个既有触点只是下界；还必须覆盖 CFG、catch/error 传播、
parser/lowered 匹配和 final decoder。它因此排在 §11 最后一包。

### 4.2 Reference 具体化（6 个编号，0 次执行）

`make_loc_ref`、`make_arg_ref`、`make_var_ref`、`make_var_ref_ref`、
`get_ref_value`、`put_ref_value`。

三家确实一个都没有，但**「所以我们能省 6 个」是错的**。读实现
（`parser.zig` 的 `needs_reference`、`bytecode.zig` 的
`loweredScopeMakeRefSize` / `writeLoweredScopeMakeRef`）后的事实：
这一族只在**静态解析不出的作用域
变量**上触发——`with` 块和直接 `eval` 里的复合赋值/自增。规范要求引用
只求值一次，所以必须把「已解析到的基址」保存下来。

**寄存器机把它留在寄存器里；我们是栈机、只能把 (scope, name) 对压到栈上
——`make_*_ref` 做的正是这件事。它不是一个可以删掉的多余概念，而是同一
件事在栈机上的形态。**

可省的是**物理 id，不是逻辑语义**。旧结论“4→1、净省 3、零尺寸代价”
不成立：三个 opcode 是 `atom_u16`（size 7），`make_var_ref` 是 `atom`
（size 5），两种既有布局都没有空闲字节放 kind。硬合成一条必须填充或变长。

现行方案按布局分组：三个 `atom_u16` 进同一物理载体（3→1，净省 2）；
`make_var_ref` 只有在与其他 `atom` 候选共享载体时才产生净收益。
`get_ref_value`/`put_ref_value` 可进入无操作数冷平面，但
`resolve_variables`/`resolve_labels` 多处按它们及 `perm4`/`rot3l` 的逻辑
身份匹配，因此必须采用 §5.1b 的 **late final encoding**，不能在 parser
发射时改成 carrier。

### 4.3 `with` 专用访问（5 个编号，120 次执行）——**已落地**

三家的一致做法：**只保留一条「建 with 作用域」的指令**（V8
`CreateWithContext`、JSC `push_with_scope`），之后 with 块内的变量访问
一律走通用动态查找，用操作数上的枚举值区分（JSC 的 `ResolveType` 有
13 个值）。Hermes 更彻底——**`with` 语句直接不支持**，
`SemanticResolver.cpp:757` 编译期报错。

**我们的落地形态不是「退化到通用查找」而是「合并成一条带 kind 的探测
指令」**，详见 §5.1c。

### 4.4 super（4 个编号，0 次执行）——**机制是降级，不是重设计**

`get_super`、`get_super_value`、`put_super_value`、`set_home_object`。

- 写侧三家零个：JSC 用 `put_by_id_with_this`/`put_by_val_with_this`，
  Hermes 用 `PutByValWithReceiver`，V8 走 runtime 调用。
- `get_super_value` 三家用通用 `*_with_this` / `WithReceiver` 形式——
  **但我们没有那种形式**，要引入就得新增一个 opcode，净省为 0。
  **我们的 `get_super_value` 就是我们的 with-receiver 读。**
- `set_home_object` 三家确实都没有，但它们的替代（context slot / 私有
  属性 `@homeObject` / 折进 `CreateBaseClass`）**都需要动表示层**。

⇒ 这一族是降级候选，不是已核准的 4 个收益；每条仍须过 §11.2 的完整
effect/consumer 审计。

### 4.5 类定义/命名（6 个编号）——**同样是降级**

`set_name` 独占 166 万次（**保留**），其余五个 0~39 次。

「改 flag 操作数」在 V8 成立，因为它有一条通用 `DefineKeyedOwn` 可以挂
flag；**我们的 `define_class`/`define_method` 语义并不重合于某条通用指令，
硬合并要先造出那条通用指令。** ⇒ 其余五个只能作为降级候选，不能预记收益。

### 4.6 栈洗牌（9 个编号，0.31%）

`dup`(8964 万)、`insert3`(3514 万)、`insert2`(255 万)、`perm3`(166 万)
**保留**。其余不能只按频次判：

- `swap` 虽在该 corpus 为 0，仍有 resident 快 handler，不进普通冷池；
- `nip` 会改变 catch-depth，`nip_catch` 会恢复 catch 状态，二者不是普通
  fixed-stack 指令；
- `perm4`/`rot3l` 被 reference 与 post-update peephole 按身份匹配。

后三类只有在 §10 生成 logical effect/trait、并采用 late final encoding 后
才可重新评估。

**三家为零是执行模型差异，不是冗余**——换掉它得先换执行模型，那是另一个
量级的决定（§6）。（`using` 平面已吸收过 `insert4`/`rot5l`/`perm5`/`dup2`/`swap2`/`rot3r`/
`rot4l`/`dup3`/`dup1` 九个同类——它们是平面上 16 个降级 opcode 里的九个。）

### 4.7 冷池的其余部分与几条重要限定

**机械初判**（频次 + 发射方式）：

```
keep（热/温）                    146
keep（短指令族，算术生成）          6
demote（冷，普通发射路径）          86
demote（冷，走尺寸预言机/下降路径）  13
```

**⚠️ 限定一：`call_constructor` 必须排除。** `class/private/super` 组看
起来是 0.063%，够冷可以降级。逐条看：

```
call_constructor         26,593,289   0.06349%
define_method                    39   0.00000%
private_symbol / check_ctor / init_ctor / check_brand / add_brand /
get_super / define_class / set_home_object / set_proto / ...   全部为 0
```

`call_constructor` 占该组 26,593,328 次里的 26,593,289 次。降它等于给每个
`new X()` 加一个二级分支——**正是 typed OO 负载的形状**。其余成员仅作候选。

**⚠️ 限定二：读写不对称。** `get_var_ref*`（5 个编号）占全部执行的
**4.46%**，`put_var_ref*`（5 个编号）是 **0.000%**。捕获变量的读比写多
四个数量级。

**⚠️ 限定三：宽/短变体要分开看。** 有些宽形式冷而短孪生兄弟热，只有冷的
那个是候选：

| 冷（可降级） | 热（保留） |
|---|---|
| `push_const` 25,524 | `push_const8` 9,550,185 |
| `fclosure` 10,557 | `fclosure8` 2,642,022 |
| `call` 1,144,018 | `call1` 48,048,859 |

但**不是所有宽形式都冷**——`get_loc`(266M)、`put_loc`(180M)、
`get_arg`(128M)、`get_var_ref`(242M) 全都活着，保留。

**⚠️ 限定四（最重要的一条纪律）：基准语料是同步的、CPU 密集的、老式 JS，
而 fun 是一个运行时。**下列 opcode 在基准里读数为零，但**禁止降级**：

- async/generator：`await`、`yield`、`yield_star`、`async_yield_star`、
  `for_await_of_*`、`return_async`、`initial_yield`
- iterator/for-of：`for_of_*`、`iterator_*`（基准早于 for-of）
- `throw`、`catch`

**降级它们等于用一份不代表产品的证据，去给产品最在乎的负载加税。**

**84 是频次筛出的候选池上界，不是可执行清单。**上面的机械初判有
86+13=99 个 demote 候选；排除产品路径后得到 84，而配套审计表又保留了
历史/过时处置。三者不能混作同一个“已核准数量”。

候选只有同时满足下列条件才可记入收益：final-form 有真实发射；所有
compiler-phase matcher 保留逻辑身份；各域 consumer 能解出 stack/control/
catch effect 与 operand offset；没有代表性缺口；放弃 resident handler 的成本
过门。§11 因此按“已验证收益 / 候选预算”分开记账。

---

## 5. 三种改造机制及其实测成本

### 5.1 三种机制

#### (a) 退役（delete/merge away）

真死指令彻底删掉，零运行时成本，V8 报告**可能改善 I-cache**。融合指令
merge away 则恢复为原基础序列，会多回一次被融合掉的 dispatch；必须单独
计价。R0 的 `put_loc0_get_loc0` 只有 8 次实测命中，所以可进入 bench 门，
但不能把“几乎为零”写成“零”。

**共同前提是编译器再也发出该 direct id。**这个判定**只能靠读，不能靠 grep**：字面
搜索 `op.X` 报出 45 个候选，几乎全是假阳性，有两种成因——

- **算术生成的短指令**：`push_4`、`get_loc1`、`call1`、`get_arg2` 由
  `op.push_0 + val` / `op.get_loc0 + idx` 生成，没有字面引用。其中若干条
  跑几亿次（`get_loc1` 一条就 900,764,620 次）。
- **间接发射的 opcode**：`check_brand`、私有字段族由 `bytecode.zig` 自己
  的下降代码写入（`output[out_idx.*] = opcode.op.check_brand`），只搜
  `parser.zig` 和 `src/compiler/` 永远看不见。

**读完之后只有 `nip1` 幸存**：一个 handler、一行表、一个实现函数、一个
peephole 分类 switch——**没有任何地方写这个字节**，419 亿次执行 0 次。
已退役。

#### (b) 降级到物理冷平面（cold but live）

编号释放，但 final 指令通常长一个 sub 字节，handler 多一次二级选择。
**对冷 opcode 才成立，对热 opcode 错。**

旧做法在没有统一 phase decoder 的情况下，直接在 parser/下降 writer 里把
`op.X` 改成 `{using, sub}`。这会在优化完成前抹掉逻辑身份，迫使每个
peephole、CFG 与尺寸预言机自行理解 carrier；它正是本轮复审发现的错误边界。

现行设计分两个职责层：

```
parser/lowered byte stream:
  direct 或已落地 using/compiler carrier
  --phase decoder--> LogicalOpcode.X + 原 payload

final-form writer:
  LogicalOpcode.X + 原 payload
  --encoder--> direct(X) 或 carrier + tag(X) + 原 payload
```

转换只发生在 **final-form writer 边界**：主编译路径是 `resolve_labels`；
运行时 `exec/small_inline.zig` 的 `rewriteBody` 也会生成派生 final bytecode，
必须先按 final 域解 logical instruction，再走同一个 encoder。旧 id 可以继续
作为 compiler-only 编码参与匹配，同时从 final 物理命名空间释放；项目已有
temp/short 在 178..196 复用同 id、由 phase 选择 decode table 的先例。
未来 logical id 超过 compiler direct-byte 容量时走 §10 的 `compiler_ext`，
不能假设 final 回收会自动给中间流腾位。

兼容现状不等于继续扩大旧做法：parser 与 `resolve_variables` 今天已经会直接
发出若干 `{using, sub}`。F0 必须先把这些 landed carrier 声明为 parser/lowered
域的合法 encoding 并解回原 LogicalOpcode；**从 C0 起的新降级**才统一采用
late final encoding，不再新增 parser-time carrier。

zjs 已有无 payload 载体 `using`（id 244，size 2）。带 payload 的 opcode
按**原 payload 布局**分别使用 `cold_atom`、`cold_atom_u16` 等载体，sub
固定放在 payload 前。一个物理载体只能吸收同一 final layout 的成员；不同
成员可以有不同 stack/control/catch effect，但必须由 sub-declaration 派生，
不能再靠 `Info` 的 carrier 默认行猜。

**三步法**：

```
A — 声明（不改编码）
  1. 声明 logical opcode、CarrierDecl、三域 canonical/alias encoding、
     payload 与完整 effects
  2. 让 parser/lowered/final decoder、scanner traits、operand offset 全部派生
  3. 与现有 direct/landed-carrier 编码逐字段等价断言，套件全绿

B — late-encoding 试点（旧 id 仍是 final 保留位）
  4. final canonical emit 改为 carrier+sub；旧 direct 转 executable_alias
     （handler 表项保留，进 decode fingerprint；§10.3 PhysicalSlotState）
  5. 证明 final artifact 的所有消费者解回同一 logical identity/effects
  6. 语义、字节码尺寸与性能门全绿

C — 释放物理 id
  7. 删旧 final alias（decode fingerprint 随之改变）、将该 id 标为
     quarantined_unused；compiler 域保留 logical row
  8. 断言 final artifact 不再出现旧 direct id
  9. 单条关账后才迁下一条
```

B 状态只是迁移检查点：旧 id 仍占账，不能宣称“已回收”，也不能作为该包的
release 终态；只有 C 完成后才增加空闲数。

禁止把“全仓搜到 matcher 后逐个教它看 `code[pc+1]`”当长期方案；消费方应统一
调用 generated `decodeLogicalAt` / `atomOperandOffset` / effect API。

#### (c) 合并（merge）——第三种机制，2026-08-27 新识别

**把若干只在「跑哪个操作」上不同的 opcode 折成一条，用它本来就带着的
操作数指明操作。编号释放，零尺寸代价，零派发代价。**

**前提窄但可机械检查，三条必须同时成立**：

1. **handler 已经共用同一个函数体。**（如果代码里已经承认这些 opcode 是
   同一段代码，那么 opcode 身份就没在做值做不到的事。）
2. **编译器已经把区别当作一个值持有。**（枚举 → opcode id → 运行时再
   还原回枚举 = 一次穿过 opcode 空间的往返，合并就在等着发生。）
3. **既有操作数里有空位。**（第 3 条不成立时合并仍可行但要付一个字节，
   那就不比降级好了。）

**第 1 或第 2 条不成立时，这些 opcode 是真正不同的指令，合并只是把一个
`switch` 挪个地方**——§4.4/§4.5 核对 super 与类命名两族时正是如此：
它们要合并进的那条「通用形式」**在我们的指令集里根本不存在**。

**已落地的实例：`with_*` 5 → 1**

新 opcode `dyn_env_probe`（id 113，size 10，`atom_label_u8`，与旧形式逐
字节同布局）。名字取自编译器自己的词汇（`emitDynamicEnvProbe` /
`needsDynamicEnvProbes`）——旧名 `with_*` 也不准确，这一族同时服务 `with`
对象与 eval 变量对象。

操作数第 9 字节（原 `is_with` 布尔）改为 flags：

```
bit 0..2  kind   0=read 1=delete 2=put 3=get_ref 4=make_ref
bit 3     is_with
bit 4..7  保留，必须为 0
```

`read` + 非 with 编码为 0，**与旧 `with_get_var` 的 `is_with=false` 逐
字节相同**——两处按字节钉死指令流的测试因此只改 opcode 名，期望数组一字
未动。

**核对时才发现的一件事：同一语义轴有两套编码。** `with_put_var` 的第 9
字节不是布尔而是三值枚举 `WithPutMode`{`var_object_probe`=0,
`selected_reference`=1, `with_probe`=2}；另外四个是布尔{0,1}。**同一个
「是不是 with 环境」的轴，put 编码成 0/2，其余编码成 0/1。**更进一步，
`selected_reference` **没有任何发射点**——唯一的写入者取值自一个只返回
另外两个的函数。**这个死分支正是编码分叉的原因**，合并时一并删除。

**这条只有读实现才看得到**：审计表里五者的 `fmt` 同为 `atom_label_u8`、
`size` 同为 10，从表上看不出第 9 字节含义不同。

**成本转移而非消除**：`put` 是 2/1，其余四个是 1/0，跳转边栈高还三分
（read/delete +1、get_ref/make_ref +2、put −1）。信息表一 id 一行，所以
栈效应必须一并搬进操作数——**复用了 `using` 冷平面的既有机制**，是第二个
用户而非新机制。新增单测钉住「表里的行 = 四个非 put kind 的效应」防漂移。

**验收**：`zig build test` 2365/0；`zig build test262-check` 0/49778；
手工对拍六种形态（read/put/delete/复合赋值/`@@unscopables` 屏蔽/eval 变量
对象）与 QuickJS 输出逐字符相同。该对拍是补充证据；语义 verdict 仍以
ECMA-262/test262 为准。

### 5.2 七类成本因子（改造前必查）

**成本不由频次决定，由「这条 opcode 被测试和工具钉得多紧」决定。**

**(1) 经过预计算尺寸的写入器。** `get_private_field`、
`put_private_field`、`private_in` 会从 `rules.writeLoweredPrivateField`
写出，调用方先用 `loweredPrivateFieldSize` 算长度；同一 writer 还会写
`nip`、`swap`、`rot3l`。`define_private_field` 则由 parser 直接发射，
不属于该 writer。两条路径都要核，不能把族名当发射方式。

**(2) 被字节偏移断言钉死。** `compiler.s2g4` 测试把发射流钉到 `code_len`、
`expectLabel` 目标、`code[22..24]` 切片和 `last_opcode_pos`。
`check_ctor`、`init_ctor`、`add_brand` 位于构造器流的头部，降级它们会让
后面每个偏移移位一格，需要约 36 处协调的数值更新。**用算术 +1 批量改是
典型的盲目机械编辑，会静默削弱一个 QuickJS 忠实性测试**——必须从实际
发射的字节重算 pin，并逐条审阅 diff。

**(3) 按 opcode 身份匹配的扫描器。← 最隐蔽，因为它不会让测试变红**

> **✅ 已于 F0b 结构性消灭（2026-08-27）。**两张手写名单
> （`scanSmallInlineEligible` 的拒绝表、`isForwardForbiddenOp`）都已改为
> 消费声明里的 `inline_policy` / `forward_policy`；冷平面居民各自声明自己
> 的 policy，载体被问的是**它的居民**而不是被特判。删名单前先用 comptime
> 断言证明「派生集合与手写名单逐条相同」，三条注入验证该断言会开火。
> **以下保留为该缺陷的病历，不再是待办。**

`bytecode.zig` 的 `scanSmallInlineEligible` 走一遍字节码，**按 opcode
身份**拒绝含某些指令的函数参与小函数内联，`put_super_value` 在那张拒绝
表里。一旦它被降级成 `{using, sub}`，身份匹配就看不见它了——含
`super.x = v` 的函数会**悄悄变得可内联**，而这不是任何人想要的语义变化，
**也不会有测试报错**（行为差异只在优化覆盖面上）。

> **规则：final consumer 必须按 logical opcode/effect 判断，不能按物理
> carrier id 判断。**

修法是统一 decode API；把整个 carrier 加进拒绝表会误伤其他 sub，散落地读
`code[pc+1]` 又会制造下一批手写名单。

**(4) 优化阶段的身份与宽度。** `undefined`、`post_dec`、`put_var_ref`、
`push_const`/`fclosure` 等都参与 `resolve_labels` 的匹配或短化。提前改 carrier
会让优化静默消失；late final encoding 是硬前置。

**(5) opcode 身份之外的 effect。** `nip` 改 catch-depth，`nip_catch` 恢复
catch 状态，`throw_error`/`ret` 是 terminal，`eval`/`apply_eval` 是
direct-eval；
atom carrier 又把 atom 从 `pc+1` 移到 `pc+2`。声明必须表达
stack/control/catch effect 与 operand offset，只有 stackPop/stackPush 不够。

**(6) post-final writer 与 runtime operand ABI。**`small_inline.rewriteBody`
消费并重新发射 final bytecode；tail-call `publish()` 又把 operand cursor
固定在物理 opcode 后一字节，部分 helper 用 `pc[0]` 或 `frame.pc-1/-size`
恢复 kind/site。carrier 必须让这些路径 logical decode/re-encode，并显式传
instruction/site pc。`vm_property*`、`vm_gen_async`、`eval_ops`、`vm_call`
等还有运行时相邻指令 lookahead；它们必须用 generated logical matcher 与
decoded `next_pc`。只改 `resolve_labels` 不闭环。

**(7) 可观测性。**当前 profiler 用物理 `u8` id 索引 256 项表；carrier sub
会被聚合，逻辑 id 超过 255 还会截断。若不先生成 logical profile view，
“降级后继续按频次挑下一条”的证据链会在第一包后失效。

### 5.3 已验证的波次排序

本节只记录既有回收的成本经验，不再充当现行执行顺序；当前包顺序见 §11.4。

按**测试耦合度**排，不按频次：

| 波次 | 选择规则 | 例子 |
|---|---|---|
| 1' | 走普通 `Emitter.op`，且不出现在任何被钉死的流里 | `set_proto`（已落地的历史例） |
| 2' | 被钉死的流里的 opcode，pin 从实际发射字节重算 | `check_ctor`、`init_ctor`、`add_brand`、`set_home_object`、`get_super*` |
| 3' | 走尺寸预言机的 opcode | 私有字段族 |

已释放 9 个（42、16、76、72、111 靠降级，114–117 靠合并），**每一步套件
全绿**。84 只仍成立为频次筛选上界；能否降级由 §11.2 的完整记录决定。

---

## 6. 方案对照（方案 A 现行；B/C 停议）

### 6.1 方案 A：机器模型不变，做声明纪律 + 系统化规范化

这是现行方案，具体执行权威为 §11：

1. 栈 VM 与热 opcode 保持不变；
2. §10 建立单一声明源，并分开 LogicalOpcode 与 final physical encoding；
3. 退役无价值 opcode；其余冷而活的逻辑指令在 final 边界打包进 carrier；
4. TDZ 等族只合并物理编码，不折叠可观察语义。

先以 **≥28 个空闲**作为机制检查点（已批准，到达后强制复盘）；**≥44**
是需求触发的条件性容量目标（D6）；60 只是非规范 envelope。每个数字都
必须逐条审计后才能记账，不能再用“84 个冷池”直接推导 83 个收益。

**不改变的**：动态指令数、栈机寻址、22 条融合中 R0 之外的 21 条与热 handler。
主要风险是冷指令多一个字节/二级选择，以及分相 decoder 漏传 effect；§10
和 §11 的架构正是为消除后一类风险。

### 6.2 方案 B：改成纯寄存器机（停议，不是当前目标）

**收益**：
- 消掉 **43%–55%** 的动态派发（48 族+洗牌+drop 为 34.1%/37.6% 两套口径，
  前缀为纯槽位搬运的融合再加 9.3%，常量物化 11.3% 大概率消失；
  见 §2.2a 与 §6.4 的重要限定）。
- 释放约 **58** 个栈机专属编号（§2.2）；typed 变体退化成 Hermes 那种「同布局兄弟指令」，
  需求从 20–40 降到个位数。
- 消掉 22 条融合指令这笔债（与 V8 删 `Ldr*` 的结论一致）。
- **消掉每次槽位读的引用计数对**（§9.3）。这一项初稿完全漏了，而且它
  **不受「指令幻影定律」保护**——RC 是带依赖链的内存写，不是能被乱序核
  吸收的臂内算术。

**代价**：
- **编译器的操作数分配要从栈纪律改为槽位分配——全案最大的一块。**
- `src/exec/` 的 **481 处** `stack.pop/push/peek` 调用点。
- `src/parser.zig` 的 **331 处**发射点。
- **6721 行**的热派发文件重写。
- 22 条融合指令全部作废重来。
- **异常路径要重做**（§9.3）：栈机 throw 时按已知栈深退栈即可；寄存器机
  + RC 需要活跃槽位图（或保守扫描）才能正确释放。这是真实工程量，初稿
  的代价清单漏了。

⚠️ **收益必须先定价，不能假设**（§6.4）。

### 6.3 方案 C：混合——热指令带寄存器操作数（停议）

即「每条二元运算都可以直接读槽位」，本质是**一次一条地变成寄存器机**。

**已有两份独立反证**：
1. V8 加了 5 条 `Ldr*` 融合，半年后全删（`f633218b624`）。
2. 我们自己的 22 条融合里，`put_loc0_get_loc0` 在 419 亿次执行中跑了 **8 次**。

方案 C 就是我们过去两年一直在做的事。它能拿到局部收益（融合族约占
23% 的执行；精确口径见 §2.2），但它**按 opcode 逐条付编号**，正好撞上 §2.1 的编号荒，
而且永远拿不到「消灭槽位搬运」的那三分之一。**列出以备完整，不推荐。**

### 6.4 派发地板：冻结的那个数字，测的是「每次派发多贵」，不是「派发多少次」

2026-08-24 的三骨架实测（`engine-evolution-plan.md:205-213`）：

| 骨架 | insn/iter | cyc/iter |
|---|---:|---:|
| 手写 asm（LuaJIT 式，寄存器全钉、每臂手排） | 58.07 | 20.77 |
| labeled switch（单函数，threading 保持） | 67.07 | 20.68 |
| tail-call（现役形态，叶臂零 prologue） | 69.07 | 20.66 |

三种骨架同坐 **~20.7 cyc/iter ≈ 3 cyc/dispatch**；**asm 省 16% 指令兑现
0.0% 时间**。这个结论在 `type-directed-optimization-plan.md:159/410/490`
被冻结引用为「**dispatch 地板，解释器轨不可动**」，并且是 native-first
论证的第一个顺风条件。

**但这个实验测的是同一个程序在三种骨架下的表现——它固定了每次派发的
成本，对派发的次数一个字都没说。**

```
派发总开销 = 派发次数 × 每次派发成本
             ↑ 方案 B    ↑ 三骨架实验已证到底
```

这不是推翻那次实测，而是指出它**没有覆盖的那一半**。「解释器轨拿不到
dispatch 收益」这个读法只对**每次派发的成本**成立。

⚠️ **同一份帐本也给出反向警告**：手写 asm 省 16% 指令兑现 0.0% 时间，正是
「指令幻影定律」在派发骨架这一层的实例。所以**那 43%–55% 的派发减少（§2.2a）
绝不能直接换算成同比例的周期减少**。区别在于：asm 省掉的是**臂内**指令（被乱序
核吸收），方案 B 省掉的是**整条指令连同它的间接跳转、栈读写和引用计数**。
两者是否同命，**只能测**（裁决 2）。

---

## 7. 机器模型分叉的冲突与约束（停议材料）

方案 B 与下列已生效的东西**直接冲突**，不能默默推进：

1. **「qjs 代码级忠实对齐」——冲突已解除**：裁决 3（2026-08-27）已将其
   降为工具，qjs 仍是性能尺，逐行对照不再约束解释器核心。（裁前这是
   最重的一项。）
2. **22 条融合指令**：方案 B 下是纯负债，且它们是过去多轮性能战役
   （EB / RayTrace / pdfjs 线）的产物。
3. **typed plan 的 T1**（typed interpreter slots）在寄存器机里形态不同；
   PERF-T-SPIKE 的原型（op254/255 guarded direct-slot）也是按栈机形态搭的。
4. **SER-ARTIFACT** 的字节码版本化（已加为它的硬前置）。
5. **FN-M1A** 需要的 ~25 个 `CALL_NATIVE_*` 编号：方案 B 下这些指令的形态
   要重新设计（三地址调用约定）。
6. **表示契约**：`JSValue` 的 16 字节承诺不受影响（寄存器文件存的还是
   `JSValue`），但**帧内 unboxing** 的推迟条款需要在寄存器语境下复核。
7. **`call_constructor` 在任何波次里都排除**（§4.7 限定一）。
8. **Tier C 名单永不降级**（完整名单见 §11.6；§4.7 限定四只是摘要）。
9. **FNABI 已经是一座三地址孤岛**（§9.2）——机器模型的岔路口不是纯假设，
   项目已经为自己最热的未来路径跨过去了一半。
10. **目标 GC 模型是分叉裁决的显式输入**（§9.4）——方案 B 在 tracing GC
    下比在 RC 下便宜得多，而 G2-GC-MERGE 正在并行推进。

**下游硬依赖本项的工作项**（roadmap DAG）：PERF-T1、FN-M1A、PERF-P05、
PERF-JIT、PERF-ASM-1A、SER-ARTIFACT。

---

## 8. 方法论：六次「名字不等于设计」

这是本次工作最有价值的副产物，因为**每一次都差点把一条错误的建议送进
执行队列**。

| # | 错误 | 纠正方式 | 类型 |
|---|---|---|---|
| 1 | `call_constructor` 被组级 0.063% 掩盖 | 逐条看频次 | 分类器 |
| 2 | 短指令「无发射点」 | 读到 `op.push_0 + val` 的算术生成 | 分类器 |
| 3 | 私有字段族「无发射点」 | 读到 `bytecode.zig` 内部的下降写入 | 分类器 |
| 4 | `and`/`or`/`catch`「无发射点」 | Zig 关键字要写成 `op.@"and"` | 分类器 |
| 5 | **`plus`「三家都没有」** | **读实现：那就是 ToNumber 的别名** | **跨引擎对照** |
| 6 | **Reference 族「三家都没有所以能省 6」** | **读实现：栈机形态必需，只能省变体数** | **跨引擎对照** |

**前四次是分类器的问题，后两次是跨引擎对照的问题——而且后者更危险，
因为它会把一条「删掉这个 opcode」的建议送进执行队列。**

由此立的三条规矩：

1. **频次表加 grep 只产候选，不产判决。** 每一条退役/降级都需要有人读
   发射路径。
2. **跨引擎对照必须按语义读实现，不能按名字匹配。** 任何「三家都没有 X」
   的论断，在动手前都要重做一次实现核对。
3. **我们自己的名字如果不表达语义，就是在给这种错误提供燃料。**
   第 5 次误判的根源就是名字：QuickJS 叫它 `OP_plus`，我们照抄；按名字
   对照时「三家都没有 plus」成立，按语义读实现才发现三家的 `ToNumber`
   就是它。**已改名 `plus` → `to_number`**（opcode 常量处保留了 QuickJS
   原名的说明）。

**同类改名候选**（尚未做，供后续一并处理）：

| 现名 | 问题 | 建议 |
|---|---|---|
| `get_field2` | `2` 实为「保留 receiver」 | `get_field_keep_recv` |
| `fclosure` | qjs 缩写 | `create_closure` |
| `special_object` | 语义是「按种类加载特殊对象」 | `load_special` |
| `make_var_ref_ref` | 两个 ref 叠词 | 若 §11 C2 通过，以 logical 名保留、物理 direct 名消失 |

---

## 9. 需求审计与机器模型停议证据

§9.1、§9.6、§9.7 支持现行精简轨道；§9.2–§9.5 只服务裁决 2/K4，
不构成 §11 的前置或工作项。

裁决记录（§1）成文后的一轮复审，指出本文有一个**结构性盲区**：
**供给侧 251 个 opcode 逐条定价，需求侧的 45–65 却照单全收、从未审计。**
外加两个就在自家代码里、会实质改变方案 B 定价的事实。下列各条均已回源
核对。

### 9.1 需求侧审计：45–65 → 保守容量预算 22–43

**FNABI 的 ~25 个**：出处是 `fun-native-plugin-design.md:213`，形态是签名
矩阵（`CALL_NATIVE_I32_I32_TO_I32` 这类，参数类型 × 返回类型的组合）。
leaf 调用热路径确实撑得起独立编号——marshalling 占主导，二级派发**不会**
被吸收，所以 §3.4a「冷用平面、热用真编号」的教训在这里指向「给真编号」。
**但 25 是组合填充，不是实测需求**，而且有两条自家条款直接反对预留：

- **FNABI 非目标 #11 明文**：「任意签名组合自动生成专用 VM opcode」
  **不在 v1 范围内**（`fun-native-plugin-design.md:322`）。预留 25 个正是
  为这条被排除的能力买单。
- **M2 验收门明文**：「新增 `CALL_NATIVE_*` handler 家族通过 dispatch
  布局 / I-cache 外部性 A/B（全 corpus，冻结基线交错测量）——新 handler
  取指外部性是**在册硬门**」（`:3256`）。**这就是「按需铸造」的机制**：
  每个新签名族都要独立过门，本来就不可能成批铸。

⇒ 首发只需 FN-M1A 用的 **2–3 个**签名，其余凭负载证据逐个铸。生成器落地
后铸一个变体是一行声明的事。

**typed 的 20–40 不能在本文里擅自下调。**Hermes 变体少的主要原因是
`Add r,r,r` 已经带三个寄存器操作数；现行方案明确保留栈 VM，所以不能拿
寄存器机的笛卡尔积消失来修剪栈机需求。T2/T3/T4 各自有 spike/频次门，
将来可能少铸，但在 `type-directed-optimization-plan.md` 自己修订预算前，
本项必须保留 **20–40**。

⇒ 当前可辩护的容量预算是 **FNABI 2–3 + typed 20–40 = 22–43**。它低于
旧 45–65，但高于此前写入本文的无依据 10–25。§11 的 44 个空闲可覆盖该
上限，但按 D6 只在 typed/FNABI 提交具名 demand ledger 后推进——不为
未经命名的 40 个潜在 opcode 提前给产品路径加 carrier tax。编号压力仍然
支持物理精简，却不足以支持机器模型分叉，后者仍须过 K4。

### 9.2 FNABI 已经是一座三地址孤岛（停议材料）

`fun-native-plugin-design.md` §17.1 的编码草案，逐字如下：

```text
CALL_NATIVE_I32_I32_TO_I32
    dst
    arg0
    arg1
    native_binding_slot
```

**这是三地址形式，带 dst。**同文 §3.1 的性能目标里还有一条：
**「typed leaf fixed-arity call 不构造 `argc/argv`」**——即禁止把参数
物化成栈上的连续区。

⇒ **机器模型的岔路口不是假设，项目已经为自己最热的未来路径跨过去了一半。**
无论分叉怎么裁：

- 槽位操作数的**编码格式**是必做项；
- 最小限度的「把表达式物化进槽位」的**编译器支持**是必做项。

这有两个后果：**(1)** 削弱了方案 B「编译器操作数分配是全案最大一块」的
吓阻力——那一块的一部分横竖要做；**(2)** **分叉如果不裁，就会以方案 C
的形态悄悄发生**（一次一个签名族地长出寄存器操作数），而方案 C 有两份
独立反证（§6.3）。

### 9.3 引用计数：收益与成本两侧都漏了（停议材料）

读实现（`src/exec/value_slot.zig:10`、`src/exec/slot_ops.zig:51`）：

```zig
pub inline fn loadOwned(slot: *const core.JSValue) core.JSValue {
    return slot.*.dup();          // ← 每次读槽位 = 一次 incref
}
// execGetLoc:
stack.pushOwnedAssumeCapacity(value_slot.loadOwned(&frame.locals[idx]));
```

**堆值每读一次就 incref 一次**，消费方弹栈再 decref。这改变两边的账：

**收益侧被低估。**寄存器机按**借用**读操作数，整对 RC 消失。而 RC 是带
依赖链的**内存写**——**恰恰是「指令幻影定律」洗不掉的那类成本**。§6.4 的
反向警告（asm 省 16% 指令兑现 0.0%）省的是**臂内可被乱序核吸收的算术**，
性质不同。**纯派发次数的逻辑算不到这一块。**

**成本侧也被低估。**§6.2 的代价清单漏了**异常路径**：栈机 throw 时按已知
栈深退栈即可；寄存器机 + RC 需要**活跃槽位图**（或保守扫描）才能在 throw
时正确释放。这是真实工程量。

⇒ **推论写进 spike policy 的效度要求：register handler 必须实现真实的
借用/所有权纪律，否则数字是虚构的。**

### 9.4 GC 线与机器模型分叉的未定价耦合（停议材料）

方案 B 在 **tracing GC 下比在 RC 下便宜得多**：无 RC 对、退栈平凡、槽覆写
就是一次写加屏障。而 **G2-GC-MERGE 正在并行推进**。

⇒ **分叉裁决应把目标 GC 模型列为显式输入。**理想时序是等 GC 合入判决出来
再裁分叉，否则 E2 要为两个世界各测一遍。

### 9.5 证据阶梯：E1 / E1.5 / E2（停议材料）

本文原来只设计了一个仪器（手工改写 spike）。但假设可以**分解定价**：

```
每条被消灭的搬运指令的成本 = 派发（~3 cyc，三骨架已钉死）
                          + 栈往返（store + load）
                          + RC 对（堆值，§9.3）
```

#### E1（停议材料；非现行前置）——逐 handler 周期归因

**tail-call 派发让每个 opcode 都有独立的 handler 函数**：`callconv(.c)`、
`align(16)`（部分 `align(64)`）、`linksection(op_handler_section)`
（`src/exec/tailcall_dispatch.zig:5,314,364`）。在 zoo 套件上跑一次 PMU
采样，**per-handler 周期归因就是现成的逐 opcode 周期账**。

> **⚠️ 但「按符号名归因」这条路已实测走不通，方法已改（2026-08-27 验证）。**
> 详见 §9.5.1——初稿写的方法会在最要紧的那一块上失效。

Tier 1 的 **68** 个 handler（48 槽位搬运 + 9 洗牌 + `drop` + 10 条前缀为纯
槽位搬运的融合，见 §2.2a）的周期占比 = **方案 B 解释器收益的一阶上界**。
**上界小，方案 B 以一次剖析的价格死掉；上界大，才轮到买 E2。**

- **它不违反裁决 2 的「缓议」**——不搭 A/B，只是读现役引擎。
- **它正是 K4 第三条准入条件要的东西**（§1.5）。

⚠️ **本项目在符号级归因上有前科，必须按既有纪律做**：「perf 符号合并不可
信，须自己映射 IP」「SPE 占比不可靠，只信 addr2line」。**热 handler 是独立
非内联函数、带对齐 pin、在专用 section，是这条纪律下最有利的情形。**

> **已撤回的一条警告**：初稿写「冷壳 handler 共享函数体，必须单独成桶」。
> **实测证伪**——每个 `coldStd(body)` 实例是 comptime 独立的（`nip`/`perm4`/
> `rot3l` 解析到三个不同的 `coldStd__struct_*.h`）。真实的共享只有 §9.5.1
> 列的 15 组，且没有一组跨越被测/参照边界。

⚠️ 第二条限定：**handler 周期 ≠ 该指令的全部成本**，也 ≠ 移除后能省的
周期。E1 给的是**上界**，不是估计值。

#### 9.5.1 E1 的方法已实测确定（不是按符号名）

**初稿写的「按 handler 符号名归因」会在最要紧的地方失效。**实测：

`get_loc*` 族是全部动态指令的最大单块，但它的 handler **在符号表里叫
`exec.tailcall_dispatch.opLoc__struct_108206.h`**——因为它由 comptime 工厂
`opLoc(kind, idx_src)` 生成，返回匿名 `struct { fn h }.h`。**符号存在、
地址各不相同（无 ICF 合并），但名字不表明它服务哪个 opcode。**

**已验证可行的方法（零引擎改动）**：

```
1. 从二进制里定位派发表：扫描 8 字节对齐窗口，找连续 256 个指向
   .text.zjs.op_handlers 段（vma 0x1070000, size 0x284a0）的指针
2. 自校验：拿 73 个具名 handler（op_<name> 形式）交叉核对表项
   —— 实测偏移 0x3cb088 命中 72/73，唯一"不符"是 id 14 指向
   op_drop_fast 而非 op_drop，即热表本就该用的特化版
3. nm -S 给出每个 handler 的 (地址, 尺寸)，含匿名 comptime 实例
4. 采样 IP 落进 [entry, entry+size) 即完成归因
```

**这个方法自带校验步骤**（第 2 步），正是在册纪律要求的——不是相信
perf 的符号化，而是拿已知量交叉核对。

**归因分辨率（实测）**：

```
245 个在用 opcode  ->  216 个不同的 handler 入口
   可逐条归因           201 条
   只能按组归因          44 条（15 组）
   无法反查到符号          0 条
   分辨率 = 216/245 = 88%
```

最大的几个共享组：`push_0..7`+`push_minus1`(9)、`put_arg*`(5)、
`set_arg*`(5)、`make_*_ref`(3)。

⭐ **关键有效性检查：没有任何共享组跨越「被测集 / 参照集」的边界。**
`put_arg*`/`set_arg*` 整组在被测集内，`push_N`/`make_*_ref` 整组在参照集内。
⇒ **对 E1 要回答的问题（被测集的周期占比），88% 的分辨率不构成任何损失。**

#### E1.5（生成器落地后顺手）——TOS caching

Ertl 栈缓存（CPython 3.11+ 同款）。在 tail-call 骨架里结构自然：栈顶值
作为追加参数对乘寄存器，冷路径沿用现有 publish 纪律。**不动 ISA、不动
编译器、artifact 兼容**，单独吃掉「栈往返」这一分量。

- 它若兑现，**本身就是方案 A 的交付物**；
- 若不兑现（幻影定律再现），**廉价地杀掉方案 B 的一半前提**。

**项目里已有它的成本模型**：`engine-evolution-plan.md` §8.3 定义了
「basic block 内缓存 TOS/top-2（**16B/档**，收益折算）；branch target、
helper call、safepoint 前 flush；不做跨块分配」——但那是给 **baseline
JIT 的 v1** 写的，**放到解释器骨架里是新的放置，成本模型可直接搬。**

⚠️ 实做限定：`JSValue` 是 16 字节 = **两个 GPR**（见
`vm-value-representation-contract.md`）。handler 现签名已有 4 参
（pc, sp, var_buf, vm），加一档 TOS 变
6 个——AArch64 的 x0–x7 装得下，但**每个 handler 都要改，且受 musttail
约束**（在册前科：`noinline` 破 musttail）。生成器把 handler 签名变成
**生成物**之后，这个实验才是机械改动——**这反过来支持「生成器先行」的
裁序（裁决 1）。**

#### E2（手工改写 spike）——只在仍有歧义时买

即裁决 2 缓议中的那个 spike。**只有 E1/E1.5 之后仍有歧义才买**，此时它要
回答的只剩「消灭派发次数 + RC 对」这个**残差**，问题更锐、误差更小。

#### 程序要求

沿用 `policies/spikes/` 的预注册惯例，**在 E1 出数之前**把分叉的 kill/keep
阈值写死。6721 行重写这种量级的决定，**两个方向的事后合理化风险都大**
（PERF-T-SPIKE 的 FAIL→撤回就是先例）。

### 9.6 生成器（裁决 1）的三条设计要求

以下是第一轮要求；§10 已在其上补入 logical/final encoding、control/catch
effect 与 operand offset，实际实现以 §10 为准。

1. **用 Zig comptime 做单一声明源，不要照抄 JSC 的外部代码生成。**
   一张 comptime 声明表派生 `op` 常量、`opcode_info`、栈效应、handler
   绑定、扫描器名单——**无构建步骤、无生成文件漂移**，符合
   `engine-evolution-plan.md` §3.3 的「first-class Zig project」纪律
   （该章把手写 `.S` 定为需 owner 认可的显式例外，外部 codegen 同理）。
   **id 必须显式声明**（不可自动分配，保测试 pin 和 artifact 稳定）；
   comptime 断言唯一性、表密度、temp 相位不相交。
2. **属性随声明走。** `inline_forbidden` 这类扫描器属性成为**声明字段**，
   `scanSmallInlineEligible` 消费生成的集合——**§5.2(3) 那个「降级后扫描器
   失明、且无测试变红」的缺陷类被结构性消灭，而不是靠人记得。**
3. **操作数描述符做成模型中立。** 槽位操作数种类是一等公民（FNABI 横竖
   需要，§9.2），栈效应作为**派生**元数据字段。这样若分叉裁向 B，
   **换的是声明内容，不是声明机器。**

### 9.7 两个不必等分叉的下游解锁

- **SER-ARTIFACT**：声明表派生的 bytecode decode fingerprint 是它的
  **格式组件**，F0a1 完成才可交付（D9）；完整 cache key 还需要
  producer/consumer 两侧 semantic epoch，见 §10.7 的拆分。
- **FN-M1A**：按 §9.1，它只需 **2–3 个**签名变体，现有 11 个空闲编号
  已装得下；§11 达到 44 个空闲的容量目标后可覆盖仍在册的 typed 上限。
  它不需要等待机器模型分叉。

---

## 10. 声明源与分相 decoder 设计（裁决 1，批量精简前置）

§9.6 只给了三条要求，没有设计。本节补上。

### 10.1 目标与非目标

**目标**：把逻辑指令、parser/lowered/final 三域编码、完整 effect 与消费方
trait 收敛成**一处声明**，其余 comptime 派生。它不仅减少六处手写，更是
§5.1b late final encoding 能安全释放物理 id 的前置。

**非目标（明确不做）**：
- **不做外部代码生成**。JSC 用 Ruby 生成 C++，那是它的语言环境决定的。
  我们有 comptime，用它就没有构建步骤、没有生成文件漂移、没有「改了
  .rb 忘了重跑」这类故障。`engine-evolution-plan.md` §3.3 把手写 `.S`
  定为需 owner 认可的显式例外，外部 codegen 同理。
- **不自动分配 id**。id 必须在声明里显式写死——测试 pin 和 artifact 稳定
  都依赖它，自动分配会让插入一条新指令悄悄移动所有后续编号。
- **前两阶段不改任何编码、不改任何语义。**（见 §10.5 的等价断言。）

### 10.2 提前验证的结果：声明表必须表达四件事（2026-08-27 实测）

设计初稿写完后对全表与消费方做了机械核对，挖出四类必须显式表达的事实。
**它们不是命名偏好；漏任一类都会在实现时变成 bug。**

#### (a) 22% 的指令把操作数烧在 opcode id 里

245 个在用 final id 中排除 `invalid` 后，对 244 条可执行指令做
`size == 1 + Σ operand.width` 核对：**244 条中 20 条不成立**，而且
不成立得完全成系统：

| fmt | 条数 | 实际形态 |
|---|---:|---|
| `loc8` / `const8` / `label8` / `label16` | 16 | **kind 与 width 不同轴**：`loc8` 是「local，1 字节」，`loc` 是「local，2 字节」 |
| `npopx` | 4 | `call0..call3`，**参数个数烧进 opcode id**，0 操作数字节 |

进一步普查「0 字节但语义上有操作数」的指令：

| fmt | 条数 | 例子 |
|---|---:|---|
| `none_loc` | 16 | `get_loc0..3`、`put_loc0..3`、`set_loc0..3`、`get_loc0_field`… |
| `none_arg` | 12 | `get_arg0..3`、`put_arg0..3`、`set_arg0..3` |
| `none_var_ref` | 12 | `get_var_ref0..3`… |
| `none_int` | 9 | `push_0..7`、`push_minus1` |
| `npopx` | 4 | `call0..3` |
| **合计** | **53** | **占在用指令的 22%** |

⇒ **`Operand` 必须支持零字节来源**：值烧死在声明里
（`OperandSource.fixed`，§10.3/P0-2），现有 direct 形式的历史压缩关系由
`LegacyEmbeddedEncoding` 单独断言（direct_id − base_id == 声明值）——
物理 id 不是语义 operand 的权威来源。没有它，
生成器无法回答「哪些指令读局部变量」——而那正是扫描器 trait 和将来任何
寄存器机翻译都要问的问题。

#### (b) 融合指令是「前缀替换」，不吃掉后一条指令

`get_loc0_field` 的 `size` 是 **1**，`fmt` 是 `none_loc`——它**不带 atom**。
读 handler（`tailcall_dispatch.zig:3278`）看清了机制：

```zig
pub fn op_get_loc0_field(pc, sp, var_buf, vm) ... {
    sp[0] = value_slot.loadOwned(&var_buf[0]);
    return @call(.always_tail, op_get_field, .{ pc + 1, sp + 1, var_buf, vm });
}
```

**它只占自己那 1 个字节，后面那条 `get_field` 原样留在指令流里**，handler
直接尾跳进它的 handler。冷壳版 `op_get_loc0_field_cold` 只做前半，然后
`coldNext` 落到那条幸存的 `get_field` 上——**这样「在两条指令之间停下」
仍然成立**（调试器/L0 需要）。

⇒ 好处是解码器按 size 走一遍就自然正确，不需要「操作数来自下一条指令」
这种非局部概念。**但声明必须表达「本指令是 X 的融合前缀」**，因为：
handler 要绑定热/冷两个形态、冷壳只做前半、任何配对分析都要知道这个关系。

#### (c) `fmt → 操作数序列` 的映射已经存在

`opcode.Format.describe()`（`bytecode.zig:1143`）已经把每个 fmt 映射成
操作数种类序列，`operandSize()` 给宽度。**声明表可以直接以它为基础**，
只需补上 (a) 的 0 宽度编码与 (b) 的融合关系。这降低了阶段 1 的风险。

#### (d) 逻辑身份、物理编码与 effect 必须分开

本轮对 §11 的读码复核又发现五类仅靠 `Info(size/fmt/pop/push)` 表达不了的
事实：

- 同一个 logical opcode 在 parser/lowered 可以是 direct 或 compiler carrier，
  在 final 又可选择另一组 direct/carrier 编码；
- `nip`/`nip_catch`、`throw_error`/`ret`、`eval`/`apply_eval` 分别带 catch、
  terminal/continuation、direct-eval effect，`return`/`return_undef` 还独有
  balanced-exit 检查；
- carrier 在原 payload 前插入 sub，atom 从 `pc+1` 移到 `pc+2`，现有
  `has_atom: bool` 无法表达 offset；`using.add` 又把 hint 直接编码进 sub，
  不能在 payload 重复写一次；
- tail-call 冷壳的 `publish()` 把 `frame.pc` 设到物理 opcode 后一字节，
  共享 handler 还会用 `pc[0]` 区分逻辑变体；payload carrier 因此不能原样
  调旧物理 handler。`getVar` 等 helper 还用 `frame.pc-1` 反推 IC 的
  `site_pc`，插入 tag 后会误指向 sub。必须生成“消费 tag、显式传
  instruction/site pc 与 logical kind、校正 operand cursor”的适配层；
- profiling build 目前用 `pc[0]` 索引 256 项计数器。carrier 若仍这样计数，
  所有 sub 会聚成一行——现有 `using` 的 0–18 已经如此——后续候选就失去
  频次证据；新增逻辑指令超过 255 后，`u8` profile key 也不再够。profile
  名称、dispatch/slow/IC 计数与 dump 行必须改由 LogicalOpcode 派生。
  `core.OpcodeProfile` 的固定 256 项布局又是已导出的诊断合同，不能悄悄扩容：
  本项保留它作为 physical compatibility view，另加 profiling-build-only 的
  generated logical sidecar；现有字段/JSON 不改义，新 logical section 才供
  C1 定价。不得借 opcode 精简顺手破坏该公共合同。

⇒ 声明源必须派生 `decodeLogicalAt`、完整 effect 和 operand offset；
只生成 opcode_info 与 stack effect 不足以支撑精简。

### 10.3 声明的形状

```zig
const Decl = struct {
    /// form 粒度（§10.8 合同 1）：`get_loc0`/`get_loc8`/`get_loc` 是三个
    /// row；宽度规范化是未来独立工作项，F0 不顺手做。
    logical: LogicalOpcode,       // 即 LogicalForm；不等于 final 物理 id
    family: SemanticFamily,       // 派生分组，不替代 form 身份（§10.8 合同 1，D12）
    name: []const u8,
    encodings: PhaseEncodings,    // 各域 canonical emit + 临时 decode aliases
    payload: []const Operand,     // 不含 carrier tag；offset 由所在域编码派生
    effects: Effects,
    /// P0-3：符号化 handler 身份，不是 exec 函数指针——声明源被 parser/
    /// compiler/exec 共同导入，持有 concrete Handler 会造成 import cycle。
    /// exec 层 `resolveHandler(key)` 绑定（§10.8 合同 4）。
    handler_key: ?HandlerKey = null, // 可执行 final row 必填；compiler-only 为 null
    traits: Traits = .{},         // 缺省仅限 compiler-only row（§10.8 不变量 5）
    /// §10.2b：融合指令只占自己 1 个字节，尾跳进后一条指令的 handler。
    /// 声明它是为了让生成器能绑定热/冷两个形态并保住「两条之间可停」。
    /// ⚠️ 后继**可能不止一个**：`op_get_loc8_push_i8` 按 `pc[2]` 尾跳进
    /// `push_i8` 或 `push_i8_add`（`tailcall_dispatch.zig:6698-6703`），
    /// 所以是集合不是单值。
    fusion: ?struct { tails_into: []const LogicalOpcode, cold_does_first_half: bool } = null,
    metadata: ?MetadataShape = null,   // 预留给 PERF-SIDECAR
};

const PhaseEncodings = struct {
    parser: PhaseEncoding = .{},
    lowered: PhaseEncoding = .{},
    final: PhaseEncoding = .{},
};

const PhaseEncoding = struct {
    emit: ?Encoding = null,       // null = 该 logical row 不在此域发射
    /// 只供迁移窗口读旧流；encoder 永不选择 alias。
    decode_aliases: []const Encoding = &.{},
};

const CarrierDecl = struct {
    key: CarrierId,
    ids: struct { parser: ?u8, lowered: ?u8, final: ?u8 },
    tag_width: Width,
    payload: union(enum) {
        /// tag 吃掉 from_operand 后，所有成员剩余的物理 payload 必须逐字段相同。
        shared: []const Operand,
        per_logical,              // 仅 compiler_ext：先读 tag，再按 logical 解 payload
    },
    adapter_key: ?CarrierAdapterKey, // 符号化，exec 层解析；compiler-only carrier 为 null
    /// P1-5：§11.4 C2 的 CarrierCompatibilityClass 落进 schema，成员
    /// requirement 与 carrier 逐项 comptime 断言一致。C2 前必须填实；
    /// F0 的 synthetic fixture 可占位。
    relocation_policy: RelocationPolicy,
    ownership_policy: OwnershipPolicy,
    operand_cursor_policy: OperandCursorPolicy,
    site_pc_policy: SitePcPolicy,
    adapter_abi: AdapterAbiKey,
};

const Encoding = union(enum) {
    direct: u8,
    carrier: struct {
        key: CarrierId,
        tag: TagEncoding,
    },
};

const TagEncoding = union(enum) {
    fixed: u16,                   // width 由 CarrierDecl 唯一决定
    /// 覆盖 `using.add_base + hint`。operand 的值编码进 tag，本身不再
    /// 作为 payload 字节重复发射；decoder 从 tag 还原该 logical operand，
    /// 范围与来源都由声明验证。
    from_operand: struct {
        operand_index: u8,
        base: u16,
        min: u32,
        max: u32,
    },
};

/// P0-4 / D11：每个 final 物理 id 的槽位状态是声明的一部分，alias 不再
/// 只是 PhaseEncoding 的附属列表。规则：encoder 永不选择任何 alias；
/// `executable_alias` 必须保留 direct handler 表项（decoder、validator、
/// dispatch 三方一致接受）；`decoder_only_alias` 仅供迁移测试解码，
/// production artifact validator 必须拒绝；decode fingerprint 覆盖全部
/// executable encoding，删除 alias 必然改变 fingerprint（§10.7）；
/// `quarantined_unused` 与 `reusable_free` 解码都拒绝，仅账本状态不同
/// （§11.0 生命周期）。
const PhysicalSlotState = union(enum) {
    reserved_invalid,
    canonical_direct: LogicalOpcode,
    carrier: CarrierId,
    executable_alias: LogicalOpcode,
    decoder_only_alias: LogicalOpcode,
    quarantined_unused,
    reusable_free,
};

const Operand = struct {
    kind: Kind,
    /// 仅 slot/register 类必填；atom/label/imm/count/flags 等为 null。
    flow: ?Flow = null,           // read | write | read_write  ← 抄 V8
    /// P0-2：逻辑 operand 的值来源**显式声明**。物理 id 不是权威来源——
    /// id 正是本轮要回收/重配的东西。`fixed` 覆盖 §10.2a 的 53 条
    /// 零字节指令（22%）。
    source: OperandSource,

    const Kind = enum {
        // 与机器模型无关的
        atom, constant, label, imm, count, flags, sub_opcode,
        // 槽位寻址：一等公民（FNABI 横竖需要，§9.2）
        local_slot, arg_slot, var_ref_slot,
        // 若分叉裁向方案 B，这里加 register / register_out，
        // 换的是声明内容，不是声明机器
    };
};

const OperandSource = union(enum) {
    /// 从 payload 字节读。width 与 kind 正交（§10.2a 实测：`loc8` 是
    /// local/1B，`loc` 是 local/2B）。
    payload: struct { index: u8, width: Width }, // u8|u16|u32|i8|i16|i32
    /// 值烧死在声明里：`get_loc0` 的 slot operand = fixed(0)，
    /// `push_2` = fixed(2)。fusion form 的隐含 slot/constant 同样走 fixed。
    fixed: u32,
};

/// P0-2：legacy direct 编码的历史压缩关系（get_loc0..3 连续排布等）
/// **单独声明、单独断言**。权威方向是「Decl 声明 operand = fixed(0)，
/// 断言 direct_id − base_id == 0」；不是「用 direct_id − base 反推语义
/// operand」——否则 id 一旦 alias/carrier/重配，逻辑 decoder 失去定义。
const LegacyEmbeddedEncoding = struct {
    operand_index: u8,
    base_id: u8,
    base_value: u32,
};

const Effects = struct {
    // §10.8 不变量 5：这些缺省只是草案示意。可执行 row 逐项显式；迁移期
    // 由旧表生成 mirror，G0 后缺项编译失败（断言 16）。
    /// fall-through 的栈效应。
    stack: StackEffectExpr,
    /// 合同 5a（冻结时补入，owner 确认 2026-08-27）：**跳转边目标处的栈高
    /// 相对 fall-through 的差**。绝大多数跳转在目标处与 fall-through 同高
    /// （`null`），但实测有两条不是——`gosub` 是常量 +1，`dyn_env_probe`
    /// 是取决于操作数的三值（read/delete +1、get_ref/make_ref +2、put −1）。
    /// 冻结前的模型没有地方放它，F0a1/F0b 实现时必然撞上。复用同一套封闭
    /// 表达式，因此是补充不是新机制。
    branch_stack: ?StackEffectExpr = null,
    control: ControlFlow = .fallthrough,
    catch: CatchEffect = .none,
    continuation: bool = false,   // `ret` 可同时 terminal + continuation
    direct_eval: bool = false,
    checks_balanced_exit: bool = false, // `return` / `return_undef`
};

/// P0-6：不用任意函数指针——它无法做 comptime 等价断言、无法进 canonical
/// fingerprint、把 effect 逻辑藏回任意 Zig 代码、还会生成间接调用。动态
/// effect 种类不多，用封闭表达式：`dyn_env_probe`/`using` sub 走
/// operand_table，call argc 走 affine。求值宽度为 u32（`npop_u16` 的
/// 参数数目不截断，说明 5）；派生产物是直接 switch/table。
const StackEffectExpr = union(enum) {
    fixed: struct { pop: u32, push: u32 },
    operand_table: struct {
        operand_index: u8,
        rows: []const struct { value: u32, pop: u32, push: u32 },
    },
    affine: struct {
        operand_index: u8,
        pop_base: i16,
        pop_scale: i16,
        push_base: i16,
        push_scale: i16,
    },
};

const EdgeStackDeltaExpr = union(enum) {
    fixed: i16,
    operand_table: struct {
        operand_index: u8,
        rows: []const struct { value: u32, delta: i16 },
    },
    affine: struct { operand_index: u8, base: i16, scale: i16 },
};

const ControlFlow = union(enum) {
    fallthrough,
    terminal,
    branch: struct {
        label_operand: u8,
        taken_stack_delta: EdgeStackDeltaExpr,
        has_fallthrough: bool,
    },
};

const CatchEffect = union(enum) {
    none,
    push,
    /// `drop`=0、`nip`=-1、`iterator_close`=+2，相对执行后的 stack level。
    maybe_pop: struct { post_stack_offset: i8 },
    restore,
};
```

`invalid` 不是可发射的 LogicalOpcode。final 物理表把 id 0 单列为
`reserved_invalid`，decoder/validator 必须拒绝它；它只在 245/11 的“已保留
物理 id”账本中占一格，不能获得普通 handler/effect/profile 行。

**七点说明**：

1. **不是一个 phase-1 域，而是 parser / lowered / final 三个域。**
   `compiler/cfg.zig` 读 parser Builder，`resolve_variables` 产出 lowered
   stream，`resolve_labels` 产出 final；`small_inline.rewriteBody` 消费并重写
   final，仍属于 final 域。每个消费方必须选择自己的 decode table，不能把
   CFG 归进 final consumer。
2. **`logical` 与各域 `encoding` 是本次修订的核心。**form 是身份主键：
   peephole、carrier economics 与 profile 都用精确 form；`SemanticFamily`
   只是**派生分组，不替代 form 身份**（D12）——宽度无关的 scanner policy
   可从 family 继承，JIT lowering 以 family 为入口再读 operand/traits，
   effect/inline policy 最终仍落到具体 form。只有该域 writer/decoder 看
   byte id。降级不再要求重写所有 matcher。parser/lowered encoding 必须
   同时声明现役 direct 与已落地的 `using` carrier；这条兼容路径不授权
   新增 early carrier。`emit` 是该域唯一规范写法；`decode_aliases` 只
   服务 B→C 迁移窗口（alias 的槽位状态与执行语义见 `PhysicalSlotState`），
   例如 C0 已改发 `{using, sub.to_propkey}`、但 id 112 尚保留为
   executable_alias。释放 id 时必须先删 alias。
3. **`flow` 抄 V8**（`Reg` / `RegOut` / `RegInOut`，`bytecode-operands.h`）。
   有了它，每条指令的读写集是**派生的**，不必另写一张表——这对将来的
   JIT lowering 和 typed 分析都是白拿的。
4. **`local_slot` / `arg_slot` / `var_ref_slot` 是一等操作数种类**，不是
   「u16 而已」；这样 compiler carrier、FNABI 与 scanner 才能共享同一
   份读写描述。只有这些寻址类（及未来 register 类）必须填 `flow`；atom、
   label、立即数等不伪装成“read”。
5. **effect 是正交字段。**`ret` 同时是 terminal 与 continuation；
   `eval`/`apply_eval` 是 fallthrough + direct_eval；`gosub`/`dyn_env_probe`
   的 taken edge 有独立 stack delta；只有两种 return 要检查 balanced exit。
   不能用单一枚举互斥这些性质。动态 pop/push 用 u32，不能把 `npop_u16`
   的参数数目截成 u8。
6. **`metadata` 槽预留但不实现**。JSC 把内联缓存/profile 做成指令声明的
   一部分（49 条带 `metadata:`），这正是 PERF-SIDECAR 要建的东西。现在
   只留字段，不建机制。
7. **`handler_key` 绑定逻辑语义入口，不绑定“假定 `pc[0]` 就是原 id”的
   物理壳，也不跨层持有 exec 函数指针**（P0-3：声明源被 parser/compiler/
   exec 共同导入，concrete `Handler` 会形成 import cycle 或迫使编译器
   引入执行层）。exec 层 `resolveHandler(key)` 解析，direct adapter 与
   carrier adapter 都由它派生；后者先消费 tag，把 `frame.pc` 对齐到原
   payload，并把 instruction/site pc 与 logical kind 显式传给共享语义体。
   不得靠伪造 `pc`、让 helper 回读 carrier id，或继续用 `frame.pc-1/-size`
   猜指令起点来恢复语义。

`CarrierDecl` 与 logical `Decl` 同属这一个 comptime 声明源。它集中占有
carrier 的各域物理 id、tag width、payload 纪律和物理 dispatch；logical row
只引用 `CarrierId`，不能各自重复填写 opcode/width。`using` 是三域共享、
空 payload 的 carrier；`compiler_ext` 是仅 parser/lowered 可见、按 logical
row 解 payload 的 carrier；C2 的各个 final carrier 则必须声明唯一 shared
payload layout。F0 只落 carrier registry 与 synthetic/test-only 描述，
**不占 final 物理 id**；生产 final carrier 必须在 C2 与至少两个合格成员
原子落地，并把该新 id 计入 `N−1` 净收益。这样既不需要伪造一个可执行
LogicalOpcode，也不会让“基础设施”先吃掉本来要释放的编号。

**编译器命名空间也必须扩容。**回收的旧 id 仍可能被 parser/lowered stream
用作旧 LogicalOpcode；未来 22–43 条新逻辑指令不能假设那里也有同样的空位。
现行最小设计是在 parser/lowered 域预留一个 `compiler_ext` carrier
（可用 final 未占的 254，tag 为 u16 logical id），提供 65,536 个仅编译期
逻辑槽；final 的 254 仍是独立命名空间。若实现选择结构化 IR 替代 byte
stream，也必须交付同等的容量证明，不能只计算 final 256 格。
因为 `compiler_ext` 可承载不同 payload，旧的 `sizeOfPhase1(op_id)` 纯表查询
不能再解它；阶段 2 必须先把所有 compiler reader 迁到带 `(code, pc)` 的
分相 decoder，writer 则从 logical declaration 直接取得输出尺寸。

### 10.4 派生什么，以及 comptime 断言什么

**派生（comptime，无外部生成步骤、无运行时初始化）**。carrier 的额外
decode/dispatch 成本仍按 §11.2/§11.5 单独计价，不能用“comptime”把它抹掉：

| 产物 | 来源 |
|---|---|
| `LogicalOpcode.<name>`、carrier registry 与三域编码表 | `logical` / `encodings` / `CarrierDecl` |
| `decodeParserAt` / `decodeLoweredAt` / `decodeFinalAt` | 对应域 canonical encoding + decode aliases |
| `matchesLogicalAt` / decoded `next_pc` | 对应域 decoder；direct 目标仍编译成直接比较，carrier 目标才读 tag |
| `encodedSize(phase, logical, payload)` 与 decoded size/fmt | `payload` + carrier tag width；供 output capacity、jump relaxation 与 inline budget 共用 |
| atom/label/slot operand offset | `payload` + 对应域 encoding，不再假设 `pc+1` |
| stack/control/catch/edge/return-balance effect | `effects`；carrier 按 tag 解 logical row |
| 冷/热 handler、operand-cursor adapter 与 final carrier 接线 | logical `handler_key` + `CarrierDecl.adapter_key`，由 exec 层 `resolveHandler` 绑定（P0-3） |
| profiling logical key、名称、dispatch/slow/IC 表与 dump | final decoder + LogicalOpcode 表；新增 sidecar，保留现有 256 项 physical view |
| scanner 集合（inline/forward forbidden、continuation 等） | `traits` / `effects` |
| 反汇编器的逻辑名与操作数打印 | `decodeLogicalAt` + `payload` |
| **bytecode decode fingerprint**（SER-ARTIFACT 的格式组件，§10.7） | final 物理编码表 **+ 全部 executable alias**（P0-4）的**显式 canonical 序列化**再 comptime 哈希；不得哈希 struct 原始内存、slice/函数指针或声明地址 |

**comptime 断言（写错就编译不过）**：

```
1. logical identity 与 CarrierId 唯一；每域每个物理 id 只属于一个 direct row
   或一个 CarrierDecl，二者不冲突
2. canonical 与 alias 编码在各域都只能解到一个 logical row；encoder 永不发
   alias；现役 carrier 的每个已占用 tag（含 `using` 0–18 全部居民）都必须
   归属恰好一个 logical row——冷平面居民没有自己的声明行，本条断言无从查起
3. production final carrier 的 tag width 固定为 u8，`compiler_ext` 为 u16；
   fixed tag 不重复，range 不重叠且落在声明的 tag width 内
4. `using.add_base + hint` 与 fixed sub 不相撞；hint 范围完整验证
5. final 表密度：0..255 每个 id 恰有一个 `PhysicalSlotState`——
   canonical_direct / carrier / reserved_invalid / executable_alias /
   decoder_only_alias / quarantined_unused / reusable_free（P0-4）
6. size 自洽：direct = 1 + payload；fixed-tag carrier = 1 + tag + payload；
   from-operand tag 与 `OperandSource.fixed` 的 operand 不占 payload 字节；
   `LegacyEmbeddedEncoding` 断言 direct_id − base_id == 声明的 fixed 值
7. 物理编码 round-trip 在 **final form 层**闭合（P0-1）：
   `planPhysicalEncoding(form, operands)` 的输出 decode 回同一 form；
   `selectFinalForm` 的 form 替换发生在 encode 之前，不参与本断言；
   每个 alias decode 也回到其声明的 form
8. 既有 production carrier（`using`）≥1 成员；**新建** production carrier
   ≥2 已落地成员且净收益 > 0（与 §11.0 停止规则一致，P1-6）；
   synthetic/test carrier 显式标 `test_only`，不进 production 表；
   final carrier 只容纳 shared layout；`per_logical` carrier 不得有 final id
9. 每个可执行 final row 恰有一个 `HandlerKey`，exec 层 `resolveHandler`
   对每个 key 恰好解析一次；carrier adapter key 与 direct key 分开；
   compiler-only row 无 key（P0-3）；final CarrierDecl 另有物理 dispatch；
   每个可到达 row 的 stack/control/catch/edge/return-balance effect 完整
10. atom/label offset 落在 payload 内；carrier tag 自动平移
11. final emit 与 aliases 都为空的 compiler-only row 不可能进入 final
    artifact；存在 final alias 时必须同时有 canonical final emit
12. `compiler_ext` 可往返所有现役 logical id，并覆盖新增 43 条的容量上界
13. profiling key 不截成 u8；logical 名称/各计数表对每个 LogicalOpcode
    恰有一行，现有 256 项 physical 诊断合同未被静默改义
14. 布局相等（抄 Hermes 的 ASSERT_EQUAL_LAYOUT）：
   声明为「同布局兄弟」的两条指令，操作数序列逐字段相同
15. slot/register operand 必须有 flow；非寻址 operand 的 flow 必须为 null
16. fail-closed（§10.8 不变量 5）：可执行 final row 的 inline/forward policy、
    may_call_user_code、may_throw、may_suspend、safepoint、control、catch
    逐项显式；G0 后缺项编译失败，缺省形态只属于 compiler-only row
17. effect expression 封闭（P0-6）：operand_table 覆盖该 operand 的全部
    合法值，malformed tag/value 显式拒绝；表达式无函数指针、可 canonical
    序列化进 fingerprint
18. alias 语义（P0-4/D11）：executable_alias 保留 direct handler 表项且
    decoder/validator/dispatch 三方一致；decoder_only_alias 不得通过
    production artifact validator；encoder 不选择任何 alias；decode
    fingerprint 覆盖全部 executable encoding，删 alias 必然改变 fingerprint
```

第 14 条现在就有两处用途：`dyn_env_probe` 的 kind 变体要共享一套 payload
布局；将来的 `make_loc_ref`/`make_arg_ref`/`make_var_ref_ref` 也必须逐字段
同布局才能共用 `cold_atom_u16`。typed 变体（若走方案 A）同样需要该断言。

### 10.5 迁移路径：五个阶段，每步套件必须绿

**关键安全性质在阶段 1–3**：先证明声明忠实，再把所有消费方迁到各自域的
logical decode，最后才允许一个 opcode 使用 carrier。批量回收不得
越过这三阶段。

F0 是伞形前置，不是一笔 mega-diff。按 D4/D9 的批准粒度拆成六个独立评审
片，与本节阶段的映射如下；每片都在编码不变时交付 artifact-equivalence
证据。gate 列引用 §10.8 的合同（1–4）与不变量（5–6）编号（P1-4）：

| 片 | 内容 | 对应阶段 | 授权与 gate |
|---|---|---|---|
| **F0a0** | **物理** opcode 表镜像、机械生成编号账、现表等价断言（不含 logical 层新概念） | 阶段 1（物理半） | **已批准，立即可做（D9）** |
| **F0a1** | LogicalOpcode/Operand/Effects/fingerprint 声明 | 阶段 1（logical 半） | 暂缓；gate = 合同 1 + 不变量 5、6 |
| **F0b** | `DecodedHeader`/`DecodedInstruction` 与全部 reader 迁移 | 阶段 2（reader） | **进行中**：decode 层已落地（`headerAt`/`operandAt`/`targetOfLabel`/`stackEffect`/`matchesFormAt`），已完整迁移的 consumer = `pipeline_stack_size`、`FinalArtifactValidator`（两者现共用同一个 header）。gate = 合同 1、2 + 不变量 5 |
| **F0c** | `selectFinalForm` + `planPhysicalEncoding` 与所有 final writer 收口；final carrier registry 与 synthetic final-carrier fixture | 阶段 2/3（writer） | 暂缓；gate = 合同 1、3、4 + 不变量 5 |
| **F0d** | logical profiler sidecar（form 主键，D12）、runtime lookahead 迁移、raw-access CI gate | 阶段 2（runtime 切片） | 暂缓；gate = 合同 1、2 + 不变量 5 |
| **F0e** | parser/lowered `compiler_ext`：u16 logical tag、per-logical payload decode | 阶段 3（独立于 C0 前置） | 设计方向已批（D9）；实现暂不开始，须在新增逻辑指令或 28 空闲检查点前落地；gate = 合同 1、2 + 不变量 5 |

C0 以 F0a–F0d 完成为前置；F0e **不是** C0 前置。五个阶段本身：

| 阶段 | 内容 | 验收 |
|---|---|---|
| **1** | 声明所有现役 logical/direct、parser/lowered `using` carrier 与 `reserved_invalid`，派生只读镜像，逐字段断言等于现表 | 编译证明忠实；`zig build test` |
| **2** | 派生三域 decoder、logical matcher/next-pc、operand offset、effects、traits；CFG/optimizer、`pipeline_stack_size`/`FinalArtifactValidator`、`publishExecutionFlags`/small-inline、反汇编器/profiler/runtime lookahead 分别改用对应域 API，编码仍不变 | 套件 + test262 + bench；三域 direct/carrier round-trip 全覆盖；final artifact/sidecar（新增 logical profile section 除外）逐字段相同 |
| **3** | 加 final carrier registry 与不占生产 id 的 synthetic final-carrier fixture（F0c；`compiler_ext` 属 F0e，独立后置，**不是 C0 前置**，P1-3）；`resolve_labels.run`/`runForPackedFinalize` 及 `small_inline.rewriteBody` 等 final writer 的新建/改写指令走 `selectFinalForm` + `planPhysicalEncoding`（§10.8 合同 3）；原样复制按 `CopyDisposition` 逐条 decode 验证 | standalone/packed-finalize 两路径 + compiler `layout=short/plain` A/B + malformed carrier + 43 个 synthetic logical id fixture；F0 自身 final-id Δ=0（若 R0 已落地则为 244/12，否则 245/11） |
| **4** | 用 `to_propkey` 做单成员 final carrier 试点：迁移窗口内旧 direct id 转 `executable_alias`，过门后删 alias 并释放 id；R0 可与阶段 1–3 独立并行 | §11.5 全门；final artifact 无旧 direct id |
| **5** | C0 过门后，把剩余 op 常量、`opcode_info` 与既有 direct-handler 表切到派生产物，删除重复手写表；此后 C1/C2/S1 的 ISA 接线只改声明（测试/证据照常更新） | artifact equivalence + objdump + bench 单独过门；不得与首批 C1 混测 |

阶段 2 是最有价值的一步，因为它结构性消灭 §5.2(3) 的缺陷类；scanner
消费 logical trait/effect，不再消费散落的物理 id 名单。

**封口不能只靠“已迁移所有 consumer”的人工声明**——现存大量 `code[pc]`、
`op.X` 物理匹配、`emitByte(op.X)`、raw `emitSlice`、`sizeOf(opcode)`、
`frame.pc-1/-size`。F0d 必须交付**机器可执行的 raw-access CI gate**：

1. final writer 的 raw byte emit 只能位于 encoder 模块；
2. 对 final bytecode 的 `op.X` 物理比较只能位于 generated matcher 或显式
   allowlist；
3. `code[pc + N]` 的 operand 读取只能位于 decoder/adapter；
4. CI 脚本扫描违规位置；allowlist 每项注明原因与移除阶段。

**生成 handler 表时的一条限定**：热 handler 岛的对齐 pin 与 `linksection`
必须保持逐字节不变——这是既有的 I-cache 布局合同，与停议中的 E1 是否执行
无关。接线可以
生成，**布局不能动**。这一步要配一次 `objdump` 对照。

### 10.6 与现行精简方案的关系

§10 不再只是“三个机器模型方案的公共前缀”，而是 §11 的安全前置：
R0 退役可以独立审查；C0 试点必须完成 F0a–F0d（阶段 1–3 中除 `compiler_ext`
外），任何 carrier 批量迁移还必须完成阶段 5 的 G0 切换。机器模型未来若
重开仍可复用声明，但不是当前设计理由。

### 10.7 SER-ARTIFACT：只解锁“解码指纹”组件，不是完整 cache key

声明表派生 **bytecode decode fingerprint**，覆盖 physical id、carrier
id/tag、operand width/order、endianness、canonical encoding、相关
value/target ABI，**以及全部 executable_alias**（P0-4/P1-7）。指纹描述
的是“这个 build 接受并能执行哪些编码”，不只是“它发射哪些编码”——否则
build A 接受旧 direct alias、build B 删除该 alias 时 canonical emit 未变、
指纹不变，A 产的旧 artifact 被 B 当作兼容缓存载入后 B 已无法解码执行。
删除 executable alias 必然改变指纹；`decoder_only_alias` 不出现在
production artifact 中（断言 18），不进 production 指纹。哈希输入必须是
**显式 canonical 序列化**——不得哈希 Zig struct 原始内存、slice 指针、
函数指针或声明地址。`src/config_signature.zig` 的 `attest()` 已有签名
先例，机制现成。

但 decode fingerprint **不能直接充当完整 build-cache 键**（一轮复审已
裁，二轮 P1-7 补全 consumer 侧）。物理编码完全不变时，以下变化同样要求
作废缓存：

- **producer 侧**（`compiler_semantics_epoch`）：lowering 语义、
  peephole/fusion 规则、TDZ/const 生成规则、compiler bug 修复、
  source ownership/relocation 规则；
- **consumer 侧**（`runtime_bytecode_semantics_epoch`）：handler 对同一
  编码的运行时解释变化——同一 byte 序列、不同语义。两个 epoch 可合并为
  一个手工维护的 `bytecode_semantics_epoch`；关键是 producer 与 consumer
  两侧都被覆盖。

现有 config signature 覆盖 compiler identity、layout、representation、
optimize、force-GC、ownership audit，**不覆盖这类 semantic epoch**。
完整键必须是：

```
artifact_cache_key =
    source_content_key
  + compiler_semantics_epoch          (producer 侧)
  + bytecode_decode_fingerprint       (canonical emit + executable alias)
  + runtime_bytecode_semantics_epoch  (consumer 侧；可与 producer 合并)
  + config_signature
```

⇒ fingerprint 组件属 F0a1 交付物（D9 之后不在立即可做的 F0a0 内）；
SER-ARTIFACT 的完整缓存有效性还需要两侧 semantic epoch 纪律，不得仅凭
ISA 哈希宣称已解决。

### 10.8 实施合同 addendum（D2/D9；**已冻结 2026-08-27**）

一轮复审（D2）要求先补全并冻结本节，F0b 起的实现才获批。二轮复审
（D9–D12）进一步裁定：本节由**四个核心 ABI 合同**加**两个跨切面不变量**
组成（P1-4，不再笼统称“四个合同”）。

> **冻结记录（owner 确认 2026-08-27）**：P0-1…P0-6 与不变量 5、6 **逐条
> 确认，本节冻结**，外加冻结前提出的一处补充——**`Effects` 增加
> `branch_stack`**（见合同 5a）。**F0a1 由此解除暂停**；F0b–F0e 仍按本节
> 末表逐片评审。冻结**不**解冻 C0 及以后、不承诺 44 空闲容量目标、不重开
> 机器模型（D8 停议不变）。
>
> 确认时逐条核实的证据：P0-2 的 53 条（22%）零字节指令为本仓实测；P0-3
> 的 import 方向为实测（49 个 `src/exec/*.zig` 导入 `bytecode.zig`，反向
> 为 0，环成立）；P0-5 的同族冷热差为本仓普查（`push_const` 25,524 vs
> `push_const8` 9,550,185）；P0-6 的封闭表达式充分性为实测（引擎中全部
> 动态栈效应形态——`npop`/`npop_u16`/`npopx`/`using` sub/`dyn_env_probe`
> ——均可归约为 `fixed`/`operand_table`/`affine`）；不变量 5 由 F0a0 实测
> 的「嵌套容器惰性分析导致断言只在 test 构建开火」直接支持。

必须先闭合的四个基础模型：

```
lowered form    → final form                  （合同 3，D10）
logical operand → physical operand 编码       （合同 1 + §10.3 OperandSource）
纯 opcode spec  → exec handler 绑定           （合同 4，P0-3）
物理槽位        → alias/quarantine/free 生命周期（§10.3 PhysicalSlotState，D11）
```

#### 合同 1：LogicalOpcode 粒度 = form；family 是派生视图

`get_loc0`、`get_loc8`、`get_loc` 是**三个** logical row（form 粒度），
不是一个 semantic row 的三组编码。理由：若一个 row 的 final encoding 由
slot 值、layout mode、jump distance、shortening、fusion context 共同决定，
`PhaseEncoding.emit: ?Encoding` 的单值合同就不成立；保留 form 粒度可以
不在 F0 顺手重写 QuickJS 式 shortening 模型。宽度变体的统一规范化是
未来独立工作项，不属于本轮。

每条声明同时给出（已并入 §10.3 的 `Decl`）：

```zig
logical: LogicalOpcode,   // 即 LogicalForm，enum(u16) 显式赋值
family: SemanticFamily,   // get_loc / put_loc / call / branch / ...
```

**form 是身份主键，family 只是生成的聚合视图（D12/P0-5）。**同族不同
form 的冷热可差几个数量级（§2.2：`push_const` 25,524 次 vs
`push_const8` 9,550,185 次）；若 profile 只按 family 聚合，C1/C2 将无法
给具体物理 id 定价。分角色：

- peephole：精确 form；
- carrier economics / profile：精确 form——
  `logical_form_count[LogicalOpcode]` 是原始计数，`family_count` 是
  生成的 rollup 视图；
- 宽度无关的 scanner policy：可从 family 继承；
- effect/inline policy：最终仍落到具体 form；
- JIT lowering：以 family 为入口，再读 operand/traits。

**burned-in operand 来源显式化（P0-2）**：见 §10.3 `OperandSource`
（`fixed`/`payload`）与 `LegacyEmbeddedEncoding`。权威方向固定为
「声明给值（`get_loc0` 的 operand = fixed(0)），legacy 断言验证
direct_id − base_id == 声明值」；物理 id 永远不是语义 operand 的来源，
id 正是要回收/重配的东西。decode 时 fixed operand 还原为实际值（合同 2）。

**Logical id 稳定性（P1-2，已定案）**：`LogicalOpcode = enum(u16)`
显式赋值，删除保留 tombstone；不再保留“ordinal 仅限进程内”的备选。
理由：`compiler_ext` 把它编进（进程内）byte stream；profiler 需要稳定键；
malformed fixture 需要稳定值；debug dump 与差分测试要求跨提交可比；对约
250–300 个 form，显式 id 的维护成本很低。即便 `compiler_ext` 明确不落盘，
也不依赖 enum 声明顺序。

#### 合同 2：`DecodedHeader`/`DecodedInstruction` —— 结构化返回值 + 性能合同

只定义 decoder 函数名不够；consumer 不得自行读 `code[pc + 1]`。但也
不能让每个 runtime lookahead、stack-size walker、scanner 都构造通用
operand 容器（P1-1）。冻结为两层：

```zig
const DecodedHeader = struct {
    domain: Domain,           // parser | lowered | final
    form: LogicalOpcode,
    family: SemanticFamily,
    encoding: Encoding,       // 实际命中的编码
    canonical: bool,          // false = 命中 alias（语义见断言 18）
    instruction_pc: u32,
    payload_pc: u32,
    next_pc: u32,
    layout: *const OperandLayout,
};

fn decodeHeaderAt(domain: Domain, code: []const u8, pc: u32) !DecodedHeader;
// parser 域单列（2026-08-28 修订，见下方实现回报）：混合流的 temp/final
// 消歧需要 atom ledger 作为输入，域所需的外部状态是签名的一部分。
// 严格 phase-1 视图（lowered + label/line_num 拒绝 + atom 验证）同座。
fn headerAtParser(code: []const u8, atoms: []const Atom, pc: u32, atom_index: u32) !DecodedHeader;
fn headerAtPhase1(code: []const u8, atoms: []const Atom, pc: u32, atom_index: u32) !DecodedHeader;
/// burned-in（OperandSource.fixed）与被 tag 吸收的 operand 均由此还原。
fn decodeOperand(h: DecodedHeader, comptime index: usize, comptime T: type) !T;

/// 全展开视图：仅冷消费者（反汇编器/validator/dump/差分工具）使用，
/// 由上面两层组合生成。
const DecodedInstruction = struct { header: DecodedHeader, operands: OperandValues };
```

**性能与存储硬约束（P1-1）**：零堆分配；不复制 atom/label ledger；
`OperandValues` 为有界内联存储（最大 operand 数由声明表 comptime 得出），
带 atom/label/slot 的 typed accessor 与显式 signed/unsigned 表示；
direct form 的 `matchesFormAt` 保持一次 byte compare，carrier form 才读
tag；热路径（matcher、lookahead、stack walker）只用 `DecodedHeader` +
按需 `decodeOperand`，不构造全量 `OperandValues`。

- atom/label/slot offset 一律从 decoded result 或声明派生；
- alias 命中必须可识别，不得与 canonical 混同；
- 验收即“没有半迁移”：接了 decoder 却仍手工读 payload 的 consumer 记
  F0b 失败。

> **实现回报（F0b，2026-08-28）：header 的字段表与「一次查表」硬约束**
>
> 上面的 `DecodedHeader` 有九个字段。按字面实现，F0b 在编译路上**多执行
> 4.44% 指令，CodeLoad 掉 3.95%**。归因做完后要改两处，都是量出来的。
>
> **（一）字段表收缩为三个，其余降为访问器或 comptime 参数。**
> 实现为 `{ form, instruction_pc, size }` 共 8 字节；`domain` 是 comptime
> 参数（consumer 静态知道自己在哪个域），`payload_pc`/`next_pc`/`canonical`/
> `family`/`layout` 是访问器，各自一次算术或一次查表。理由不是简洁：九
> 字段的 header 在遍历循环里全程活着，编译器把它**溢出到栈**——`perf
> annotate` 在迁移后的栈计算里看到 `str x9,[sp,#32]` 和 `ldr x2,[sp,#40]`
> 位列最热，而未迁移版本一条溢出都没有（它只保持一个字节和一个指针活着）。
> 被去掉的字段全部可由一次算术还原，所以失去的只有溢出。
>
> **（二）新增硬约束：每条指令一次查表。**
> 这是回归的主体。被替换的面向字节的代码从**一行**紧凑行上读走 `size`、
> `n_pop`、`n_push`；迁移后的路径取了**四张表**——`headerAt` 里
> `finalCompactInfo` 加 `physical.stateOf`，`stackEffect` 里
> `dynamic_by_form` 再加一次 `finalCompactInfo`。其中最贵的是
> `dynamic_by_form`：它是「可选 tagged union」的数组、按最宽形态定尺寸，
> 于是**常见情形付一次宽加载，只为得知自己无事可做**。
>
> 修法不动 F0b 的性质，键仍是 form：按 form 建一张 4 字节窄行表
> （`size`/`pop`/`push`/`flags`，`flags` 携带 claimed 与 dynamic 两位），
> 一次加载答完 header 与静态栈效应两个问题，胖表只在 `flags` 说它动态时
> 才查。附带结果是 `stackEffect` 的 `domain` 参数变成死参数并被删除——
> **form 已经携带了域**（lowered 专属 form 住在 300+），这本身是「form
> 而非物理 id 才是正确主键」的一个小确证。
>
> 另有三个放大器，各自独立且都已修：验证器从内联变为独立函数（单独占
> 72M 指令，而内联的旧版量不出来）⇒ 标 `inline`，且注明这是承重的不是
> 提示；验证器对每条指令跑一遍 slot 循环，只为问旧版用两次 fmt 比较就
> 答完的两个问题 ⇒ 答案在 comptime 预算进 layout（`atom_slot`/
> `var_ref_slot`），问题仍以 form 为键；`headerAt` 读的是 24 字节的诊断行
> `Info` 而非 4 字节的 `CompactInfo`——而 `Info` 自己的注释就写着别让
> 验证器为这四个字段跨它跨步。
>
> **结果**（core 8，交错 ABBA，三轮独立复现）：
>
> | | 编译路定工作量指令 | CodeLoad | Richards |
> |---|---|---|---|
> | F0b 前 | 3149.7M | — | — |
> | F0b 按字面实现 | 3289.7M（+4.44%） | −3.95% | −0.93% |
> | 修复后 | 3177.6M（+0.89%） | −1.64% | +0.12%（持平） |
>
> 残余可归因的只有栈遍历那一趟的 +14M（+0.44%），分数上的 −1.64% 大于
> 它，按已登记的规矩（单建 A/B 差 <300M 先疑布局）余量主要是代码布局。
> **代价局限在编译路**：运行时重的基准已回到持平。CodeLoad 是全套里编译
> 最密集的一个，所以这 1.64% 是最坏情形而非典型值。
>
> **实现回报（F0b resolve_labels 之后，2026-08-28）：parser 域的签名
> 装不进本合同。** CFG 迁移摸底发现，parser 域消费的是**混合流**——
> Builder 阶段的 temp id 范围（178–196）里可以合法地混着已选定的 final
> short opcode，现行 `cfg.tempInstruction` 靠 **atom-ledger 比对**消歧
> （temp 解释的操作数与账本游标处的 atom 相等 ⇒ temp，否则 final）。
> 因此 parser 域的 decode 需要 `(code, atoms_ledger, pc, atom_index)`
> 四个输入，`decodeHeaderAt(domain, code, pc)` 的统一签名对它不成立——
> **消歧所需的外部状态是域定义的一部分，不是实现细节**。CFG/
> resolve_variables 迁移（F0b 剩余）动工前，需先把 parser 域入口的形状
> 定进本合同：建议 `headerAtParser(code, ledger, pc, atom_index)` 单列，
> 且两张私有表（`temp_decode_info`/`phase1_decode_info`，现从
> `sizeOf`/`formatOf` 生成）改由声明派生。
>
> 归因过程中的两条附带记录：
>
> - 我假设「有解码行 ⇒ 槽已认领」并写断言去验，**断言把假设证伪了**：
>   十个已回收槽按设计保留着「规范死形状」的行（§F0a0 账本第 1150 行的
>   要求），所以 `finalCompactInfo(id) != null` 只等于 `id < op_count`，
>   `stateOf` 那次检查是唯一挡住这十个 id 的东西，不能当冗余删掉。
> - 重排 `headerAt` 时把 `@enumFromInt` 挪到了校验之前。已回收 id 在
>   `LogicalOpcode` 里没有 tag，于是**恰好在不变量 5 要拒绝的那批输入上**
>   构成非法行为。单测抓住了。现在索引以数值算出、行验过之后才转枚举。

#### 合同 3：final form selection 与 physical encoding 是两个阶段（D10）

一轮草案的单一 `planEncoding` 同时做 `get_loc0/get_loc8/get_loc` 选择、
`goto8/goto16/goto` 选择、short/plain、fusion replacement，与合同 1 的
form 粒度直接冲突（P0-1）：lowered 输入 row 是 `get_loc(idx=0)`、输出
物理 id 是 `op.get_loc0`，decode 回来是 `get_loc0`——encode/decode
不可能回到同一 row。职责拆分：

```zig
// 阶段 A —— 语义层 form 替换：shortening、宽度选择、jump form 选择
//（含 relaxation goto8→goto16→goto）、fusion/peephole replacement。
// 输出一个新的 final LogicalOpcode form。
fn selectFinalForm(
    input: DecodedInstruction,
    context: FinalizeContext,
) !FinalInstruction;

const FinalInstruction = struct {
    form: LogicalOpcode,      // final form；断言 7 的 round-trip 在此层闭合
    operands: OperandValues,
};

// 阶段 B —— 同一 final form 的物理编码：只在 direct 与 carrier+tag 之间
// 选择，不再改 form；alias 永不参与 emit。
fn planPhysicalEncoding(instruction: FinalInstruction) !EncodingPlan;

const EncodingPlan = struct {
    physical: Encoding,
    encoded_size: u32,
    operand_layout: EncodedOperandLayout,
    relocation_plan: RelocationPlan,
};
```

- `EncodingPlan.canonical` 已删除：encoder 只能发 canonical encoding，
  恒为 true 的字段不表达信息。raw-copy 资格改由独立的 `CopyDisposition`
  表达——final writer 对已逐条 decode 验证、canonical 且无需 relocation
  的完整指令可原样复制，其余走阶段 A + B；
- output capacity、jump relaxation 与实际 writer 消费**同一个** plan
  （或同一个纯 selector）；`encodedSize` 与 `emitInstruction` 不得各自
  维护一套条件分支；
- short/plain layout 影响的是阶段 A 的 form 选择输入（`LayoutContext`
  并入 `FinalizeContext`），阶段 B 对同一 form 在两种 layout 下的物理
  编码结果一致可断言。

#### 合同 4：`handler_key` 纯数据 spec + exec 侧绑定 + `InstructionContext`

这是实现风险最大的部分。现役 tail-call ABI
`fn (pc, sp, var_buf, vm) callconv(.c) Outcome` 带 musttail、零本地
non-tail call、handler island 对齐与 source-order 合同；大量共享 handler
直接用 `pc[0]` 判逻辑语义（checked local、var-ref、binary/compare/unary、
make-slot-ref、define-class、for-of/for-await、field/global）。carrier 下
`pc[0]` 是 carrier id、`pc[1]` 是 tag、payload 后移、`frame.pc - 1` 不再
是 instruction pc、共享 handler 无法从原 id 恢复 kind——“生成 adapter”
不是简单接线。

**模块分层（P0-3）**：现依赖方向是 exec 导入 `bytecode.zig`（tail-call
dispatcher `@import("../bytecode.zig")` 并在其上组装 handler 表）。共享
声明源若直接持有 concrete `Handler` 指针，就形成
`opcode spec → exec handlers → opcode spec` 的 import cycle，即使侥幸能
编译也会迫使 parser/compiler 引入执行层。一轮草案的
`HandlerBinding{direct_exact: ?Handler, ...}` 因此废弃，冻结为纯数据
spec + exec 侧解析：

```zig
// opcode spec（parser/compiler/bytecode/exec 均可导入）：
// Decl.handler_key: ?HandlerKey（§10.3）——符号化 handler 身份。
const HandlerKey = enum { get_loc, checked_loc, binary, to_propkey, ... };

// exec 层单独解析（如 exec/opcode_handlers.zig）：
fn resolveHandler(key: HandlerKey) Handler {
    return switch (key) {
        .get_loc => op_get_loc,
        .checked_loc => h_checkedloc,
        // ...
    };
}

const InstructionContext = struct {
    form: LogicalOpcode,
    instruction_pc: u32,
    payload_pc: u32,
    next_pc: u32,
    site_pc: u32,
    operands: OperandValues,
};
```

comptime 断言（已并入 §10.4 断言 9）：每个可执行 logical row 恰有一个
`HandlerKey`；每个 key 在 exec 层恰好解析一次；compiler-only row 无
key；carrier adapter key（`CarrierDecl.adapter_key`）与 direct key 分开。

纪律（逐条发生，不得在 F0 批量重构 244 条 handler）：

1. F0/G0 不改未迁移 hot direct handler 的函数体或 ABI；
2. 生成表只经 `resolveHandler` 引用现有 handler，不改变指针集合与
   handler island 布局；
3. carrier adapter 只为迁移成员生成；
4. adapter 调用显式 semantic helper（传 `InstructionContext`），不把
   carrier `pc` 传给依赖 `pc[0]` 的旧 handler；
5. direct handler 与 carrier semantic helper 的分离逐条发生；
   `BuiltTable.keep`（回收槽位后保留 handler geometry）先例沿用。

#### 合同 5a：跳转边栈高（冻结时补入，owner 确认 2026-08-27）

冻结前的 `Effects` 只有 fall-through 的 `stack`，没有位置放**跳转边目标处
的栈高**。扫过栈计算的全部 `seed` 调用后：8 条跳转（`goto`/`goto8`/
`goto16`/`if_true`/`if_false`/`if_true8`/`if_false8`/`catch`）在目标处与
fall-through 同高，但**两条不是**——

| opcode | 目标处栈高 | 形态 |
|---|---|---|
| `gosub` | `stack_len + 1` | 常量 |
| `dyn_env_probe` | +1 / +2 / −1 | **取决于操作数**（read/delete、get_ref/make_ref、put） |

所以 `Effects` 增加 `branch_stack: ?StackEffectExpr`：`gosub` 是
`fixed(+1)`，`dyn_env_probe` 是 `operand_table`，同高的跳转是 `null`。
**复用 P0-6 的同一套封闭表达式，是补充不是新机制。**

不补的后果是确定的：F0a1/F0b 实现时撞上，届时「已冻结」的合同要重开。

> **实现回报（F0a1 第三部分，2026-08-27）**：`operand_table` 的「覆盖全部
> 取值」在两条动态指令上含义不同，冻结时没写清，实现时才显形——
>
> - **`using` 的 sub 操作数是范围语义**：`sub >= add_base`(64) 一律 pop 2，
>   不是枚举。手写表要 256 行且与权威重复。⇒ 覆盖 = 全部 256 个取值，
>   **行由 comptime 从权威生成**，迁移期不写进声明，G0 时移入。
> - **`dyn_env_probe` 的 flags 只有 10 个取值可解码**，其余 246 个被
>   decoder 拒绝。⇒ 覆盖 = **decoder 接受的取值集**，断言形式是「decoder
>   与 effect 表在『哪十个』上必须一致」。
>
> 结论：**断言 17 的「全部取值」应读作「该操作数的*接受集*」**，接受集由
> decoder 定义（有 decoder 时）或为整个宽度空间（无 decoder 时）。这不改
> P0-6 的封闭集，只是把它的覆盖语义讲准。

#### 不变量 5：fail-closed —— 忘写声明必须编译失败

`traits: Traits = .{}` 与 effect 隐式缺省会部分重现本文正在修的缺陷类：
新增/迁移一条 opcode 时忘写 `inline_forbidden`，编译照过，优化覆盖静默
变化。单一声明源只消除“多处名单”，不消除“忘记声明”。规则：

- 可执行 logical row 的 `inline_policy`、`forward_policy`、
  `may_call_user_code`、`may_throw`、`may_suspend`、`safepoint`、
  `control`、`catch` **不设隐式允许缺省**，逐项显式填写；
- 迁移期可由旧表/旧 scanner 自动生成 mirror；G0 后新增 opcode 缺字段 =
  编译失败（§10.4 断言 16）；
- 缺省形态只保留给 compiler-only synthetic row。

#### 不变量 6：fingerprint / cache-key 纪律

decode fingerprint ≠ artifact_cache_key。fingerprint 覆盖 canonical
emit + 全部 executable alias；完整 cache key 另需 producer/consumer
两侧 semantic epoch。全文见 §10.7。

#### 实施 gate（P1-4；取代“冻结四合同后 F0b–F0e 一起开闸”）

本节冻结后各片仍按下表逐片评审（与 §10.5 分片表一致）：

| 片 | 需要冻结的合同/不变量 |
|---|---|
| F0a1 | 1、5a、5、6 |
| F0b | 1、2、5 |
| F0c | 1、3、4、5 |
| F0d | 1、2、5 |
| F0e | 1、2、5 |

---

## 11. 物理 opcode 精简方案 v2（owner 已按 §11.7 D1–D12 有条件批准）

> 本节取代旧 §11 v1 的执行清单。目标是减少 **final-form 物理 id**；
> LogicalOpcode 可以继续存在于编译器内部。实施授权按 §11.7：R0 与 F0a0
> 立即可做（D3/D9）；F0a1 起以 §10.8 冻结为硬前置，之后按其末表逐片
> gate（D2/D9）。机器模型、E1/E2 与 TOS caching 明确不在本节范围内（D8）。

### 11.0 目标、账本与停止规则

| 期界 | 在用/空闲 | 状态 |
|---|---:|---|
| 基线 | **245/11** | 已由 final opcode 表核对 |
| R0 后 | **244/12** | **已实施**（`6ea4c927`）；套件 2367/0、test262 0/49778；bench 见下注 |
| C0 后 | **243/13** | 一个 late-encoding carrier 试点 |
| G0 后 | **243/13** | 声明源最终切换；净 0，与 C1 性能分开计 |
| 第一检查点 | **≤228/≥28** | **已批准（D5）**：验证机制并覆盖已审计近端需求；到达后强制复盘 |
| 容量目标（条件性） | **≤212/≥44** | **暂缓（D6）**：typed/FNABI 提交具名 `OpcodeDemandLedger` 并证明未来两个 milestone 需求超过现有空位后，才继续推进 |
| 设计上界（非规范） | **≤196/≥60** | 仅保留为 rationale envelope，不进 normative 里程碑；逐条审计前不得承诺 |

> **R0 落地注（2026-08-27）**：§11.4 要求的「首轮保留不可达 handler 本体
> 以维持 island 几何」**做不到**——comptime 引用只强制分析不强制保留（实测
> 链接器剥离，island `0x284a0`→`0x28260`），改用被引用的 Handler 数组 +
> `doNotOptimizeAway` 仍未保住，且会在冷表构建里塞进循环（为保对照反而给
> 热路径加活）。故本体明删，源码与二进制一致，island −576 B。
>
> 因 island 已变，§11.5 第 6 条的 bench 从「以后再决定」变为当下必需。
> **已按 owner「简单跑一下」的口径做冒烟对照**（n=10，绑核 19，双向交错，
> 未做 A/A 噪声区间、未加 flock、未查孤儿）：**两个顺序给出相反符号**
> ——P 先跑得 −0.51%、C 先跑得 +0.65%，合并中位数比 1.0018（+0.18%），
> 而 parent 臂自身极差 2.49%。⇒ **无可检出效应**，且这轮数据本身是
> 「只跑单向会得出假结论」的实例（单跑任一轮都会报出 ±0.5% 的假效应）。
> ⚠️ 这是冒烟检查，**不构成 §11.5 第 6 条的正式验收**（缺 A/A 噪声区间、
> 缺对 245/11 project-root 的比较、缺测量合同的 flock/孤儿检查）。

**停止规则**：到达 28 个空闲后**强制复盘并暂停**；向 44 推进只由具名
demand ledger 触发（D6），不是本项的无条件完成定义。若继续只为追平其他
引擎数字，或会增加热路径成本/扩大语义面，则停止。60 是非规范 envelope，
不是 KPI。除已存在的 `using` 外，不得先占一个 production carrier id
再等待成员；新 carrier 必须与至少两个合格成员同包落地，包后净收益 > 0。

**物理 id 生命周期**（单条回滚承诺的前提，见 §11.5；状态定义即 §10.3
`PhysicalSlotState`，D11）：

```
occupied → executable_alias（迁移窗口；handler 表项保留，进 decode fingerprint）
         [或 decoder_only_alias：仅迁移测试解码，production validator 拒绝]
→ quarantined_unused → reusable_free → reassigned
```

回收的 id 至少在包验收关账并通过 28 空闲复盘前保持 `quarantined_unused`；
此期间恢复旧 direct encoding 即可完成单 LogicalOpcode 回滚。删除 alias
必然改变 decode fingerprint（§10.7）。一旦
`reassigned`（空位被 FNABI/typed 新 opcode 占用），回滚粒度升级为：连带
新 opcode 一起回滚、或提升 artifact/ISA epoch、或重新分配另一个空位。

`using_sub` 现用 0–18，19–63 有 45 个 sub 空位；容量足够，但**容量不是
正确性证明**。新 payload carrier 每个占一个物理 id，组内 `N` 个逻辑成员
的净收益是 `N−1`；无 payload 的 `using` 已存在，迁入一条净省一条。

### 11.1 v1 复核结论：哪些账可以保留，哪些必须作废

**可保留：**

1. **`put_loc0_get_loc0`(253) 可退役。**唯一生产者是
   `resolve_labels` 的融合规则；419 亿次里只执行 8 次。停产后直接释放，
   不需要 carrier。
2. **`nop` 必须排除。**它是 match-barrier 保留信号，又参与
   `nop|insert3|perm4|rot3l + put_ref_value` 的一字节模式。
3. **旧预算 envelope 的算术可复算**：R0 +1、含 C0 的无 payload 池最多
   +30、C2 最多 +12、S1 +6，合计 +49，245→196。§11.4 首批只承诺审到
   28 空闲；+49 是候选上界，不是已验证结果。

**必须作废：**

1. **“P1/P2 不等生成器”错误。**`nip` 有 catch effect，`throw_error`/`ret`
   是 terminal，`eval`/`apply_eval` 是 direct-eval；没有 §10 的 logical decoder
   就不能安全打包。
2. **“九条 P1 都是普通 Emitter.op”错误。**私有字段 writer 会直接写
   `nip`/`swap`/`rot3l` 并预计算尺寸；`swap`、`undefined` 等还有 resident
   handler，不能按零频次直接降级。
3. **“define_private_field 属尺寸预言机”错误。**它由 parser 直接发射；
   `get/put/private_in` 才走 `writeLoweredPrivateField`。
4. **“TDZ = 纯 check + 普通访问”错误。**它丢 caller-realm、const 与 init
   语义；正确形态见 §4.1 的 semantic carrier。
5. **“make_*_ref 降级比 4→1 多赚 1”不是同口径比较。**三个
   `atom_u16` 自身净省 2；额外收益来自与 `private_symbol`/`delete_var`
   共用另一个 `atom` carrier。
6. **旧“需求 10–25”作废。**它用寄存器机形态下调了仍运行在栈机上的 typed
   预算。现行保守预算为 22–43；28 只是首个机制检查点，44 为需求触发的
   条件性容量目标（D6）。
7. 审计表仍有已知漂移：`put_super_value`/`to_object` 已回收，
   `invalid`/`nop` 不应标 demote，id 139 已是 `to_number`，
   `push_const`/`fclosure` 的 size/fmt 不应为 0/`?`。

### 11.2 候选成为收益前必须有一行完整记录

`opcode-audit-table.md` 需要从“频次表”升级为“处置证据表”。每条候选至少
记录：

| 字段 | 必答问题 |
|---|---|
| logical identity | 它在 parser、scope/private lowering、resolve_variables、resolve_labels、runtime lookahead 由谁产生/匹配？ |
| final encoding | canonical 是 direct 还是哪个 `(carrier, sub)`；迁移 alias 何时删除、旧 id 何时关账；原 payload layout 是什么？ |
| effects | stack、control、catch、direct-eval、continuation、balanced-exit 是否完整？ |
| semantics | caller/current realm、const/init、所有权与可观察错误是否仍进入原语义体？ |
| operands | atom/label/slot 的 final offset；instruction/site pc 如何传递；谁 retain/free/relocate/validate？ |
| execution | 两套 corpus 的 **logical-opcode** 频次，且必须按 workload 分层：`aggregate_share`、`max_single_workload_share`、`p95_workload_share`、`representative_product_share`。carrier eligibility 主要看 `max_single_workload_share`——总占比极低的 opcode 可能在单一 workload 中占 3%–10%；是否属于 async/module/class 等代表性缺口？ |
| dispatch | cold-only 还是 resident；共享 handler 还是专用 handler？ |
| economics | 组内净省几条、每次多几字节、是否损失既有短化/融合？ |
| verdict | keep / retire / carrier candidate / landed，并附源码坐标与验证证据 |

**频次 + grep 只能生成候选。**只有这行填满且 source review 通过，才能把
编号记进“已回收”；找不到直接发射点也不能推导 retire，因为算术生成和
lowering writer 已多次制造假阴性。

### 11.3 编码架构

1. **逻辑身份活到优化结束。**parser、scope/private lowering、
   `resolve_variables`、peephole 与 parser CFG 都通过各自域 decoder 看
   LogicalOpcode 和原 payload。decoder 必须同时接受现役 direct 与已经落地的
   parser/lowered `{using, sub}`；后者是兼容输入，不是新降级的发射模板。
2. **每一条 final 发射路径都走同一个 instruction-level encoder。**
   `copyDefault`、shortener、fusion/peephole replacement、prologue 和
   `putShortCode`，以及 `small_inline.rewriteBody` 新建或改写的指令，都统一
   提交 `(logical, payload)`，encoder 再产出 direct 或 carrier。低层
   `emitByte`/`emitSlice` 仍可在 encoder 内写 tag/payload；small-inline 也可
   原样复制一条已经 final-decode、确认是 canonical 且无需 relocation 的完整
   指令。不能对不透明 byte slice 做事后 opcode rewrite，否则
   label/source/atom relocation 与 jump relaxation 都要重算。
   `resolve_labels.run` 与 `runForPackedFinalize` 必须共享这条路径；
   form 选择与物理编码的唯一决策入口是 §10.8 合同 3 的
   `selectFinalForm` + `planPhysicalEncoding`。
3. **消费方按域解逻辑身份。**parser CFG/`resolve_variables`/`resolve_labels`
   分别用 parser/lowered decoder；`pipeline_stack_size`、`FinalArtifactValidator`、
   `publishExecutionFlags`/small-inline、反汇编器，以及 `vm_property*`/
   `vm_gen_async`/`eval_ops`/`vm_call` 等运行时 lookahead 用 final decoder/
   matcher。任何一方都不得自行 switch carrier、按物理 id 误判相邻模式，
   或假设 atom 在 `pc+1`。
4. **parser、lowered、final 是三个编码命名空间。**降级后旧数值可继续
   compiler-only；final 同数值可以 unused 或另配 direct。`compiler_ext`
   的 u16 logical tag 为未来 43 条逻辑指令提供容量证明。
5. **runtime 语义不合并。**无 payload carrier 可按 sub 直达原语义体；payload
   carrier 必须先消费 tag、把 `frame.pc` 对齐到原 payload，再把
   instruction/site pc 与 logical kind 显式传给语义体，不能原样调用依赖
   `pc[0]`、`frame.pc-1/-size` 或旧 operand cursor 的物理 handler。
   tail-call dispatch table 与 `using_ops.execVm`/新增 carrier adapter 都由
   同一声明接线；adapter 与语义体之间按 §10.8 合同 4 的
   `InstructionContext` 传递；TDZ 这类 semantic carrier 也必须保留每个
   kind 的原错误与所有权纪律。
6. **编号回收与 handler-island 重排分开验证。**第一步可先取消旧 direct
   table 映射、但把旧 handler 留作不可达 geometry keep，以隔离编码变化；
   是否删函数体、改变对齐/地址布局是后一项独立的 objdump + bench A/B，
   不影响该物理 id 已经释放。

### 11.4 包顺序

**F0 — 事实与基础（净 0，所有 carrier 的硬前置；按 D4/D9 分片授权）**

F0 按 §10.5 的表拆成 **F0a0/F0a1 + F0b–F0e** 六个独立评审片：F0a0
（物理表镜像/编号账/现表等价断言）**已批准立即开始（D9）**；F0a1
（LogicalOpcode/Operand/Effects/fingerprint 声明）在 §10.8 冻结后先行；
F0b（`DecodedHeader` + reader 迁移）、F0c（`selectFinalForm` +
`planPhysicalEncoding` + final writer 收口）、F0d（logical profiler、
runtime lookahead、raw-access CI gate）按 §10.8 末表的合同 gate 逐片
评审；F0e（`compiler_ext`）设计方向已批、实现暂不开始、**不是 C0 前置**
（P1-3），须在新增逻辑指令或 28 空闲检查点前落地。各片共同要求：

- 同步审计表的已知漂移，并从 final 表机械生成编号账；F0 自身断言
  final-id Δ=0，不把 245/11 写成会与并行 R0 冲突的实现常量；
- 完成 §10 阶段 1–3（`compiler_ext` 除外，属 F0e）：三域声明/decoder、
  完整 effects/operand offset、final carrier registry 与不占
  production id 的 synthetic fixture；
- parser/lowered decoder 覆盖并逐条往返现有 `using` sub；新增 early-carrier
  发射在 F0 后禁止；
- 把 runtime 相邻指令 lookahead 迁到 generated logical matcher/decoded
  `next_pc`，direct 目标的生成代码保持原直接比较；
- 把 `resolve_labels` 与 `small_inline.rewriteBody` 等所有 final 发射 helper
  收口到 instruction-level encoder（唯一决策入口 = §10.8 合同 3 的
  `selectFinalForm` + `planPhysicalEncoding`），并以 §10.5 的 raw-access
  CI gate 证明新建/改写指令没有 raw opcode byte 绕过；原样复制按
  `CopyDisposition` 限于已 decode、canonical、无需 relocation 的整条
  final 指令；output capacity、jump relaxation 与 inline byte budget
  消费同一个 `EncodingPlan`；
- `pipeline_stack_size` 与 `FinalArtifactValidator` 改按 decoded logical row
  读取 size/effect/atom offset；standalone 与 packed-finalize 共用同一证明；
- tail-call dispatch/`using_ops.execVm`/carrier adapter 的每个可达 sub 都由
  声明生成并拒绝未声明 tag；
- F0 单独与其 parent 比较 corpus 的 bytecode、atom/source owner、stack size、
  execution flags 与 small-inline 派生体，除新增 logical profile section 外
  必须逐字段相同；F0、R0 各自过门并集成后，才冻结 C0 的 parent 基线；
- 加三域 direct 编码全表 round-trip、43 个 synthetic logical id 容量测试与
  malformed carrier fixtures；
- profiler 按 logical sub 拆开现有 `using` 后，重跑两套 corpus，刷新 C1/C2
  候选频次；不得继续拿聚合的物理 `using` 行给单个 sub 定价。

R0 不使用 carrier，已批准（D3/D9）与 F0a0 并行开发/评审；落地时后合入者
按 source-generated 账本 rebase，不能各自硬编码 245/11。C0 及之后必须等
F0a–F0d 与 R0 都完成；F0e 可后置到新增逻辑指令或 28 检查点之前。

**R0 — 退役亏损融合（净 +1 → 244/12）**

- 停止 `put_loc0 + get_loc0` → `put_loc0_get_loc0` 的融合；
- 删除热/冷 table 接线与 final direct row；该融合从不进入 compiler stream，
  无需保留 compiler encoding；
- 首次落地保留不可达的 handler geometry keep；确认 handler island 与基线
  一致后，再用独立 bench A/B 决定是否删除 64-byte 对齐的函数体；
- 原“emit and execute”测试改为证明不再发射，同时保留等价行为测试。

**C0 — 单成员 late-encoding 试点（净 +1 → 243/13）**

- **默认候选** `to_propkey`（D7）：无 payload、现为 cold handler、当前
  finalizer 路径最终落到 `copyDefault`，无 control/catch effect。**最终
  选择由 F0d 刷新后的 representative logical profile 决定**，不是预先
  固定的判决；
- `to_propkey` 继续使用当前 direct parser/lowered encoding，phase decoder
  解为 `LogicalOpcode.to_propkey`；只有 final stream 变成 `{using,
  sub.to_propkey}`；
- **语义门（D7）**：`ToPropertyKey` 可执行用户代码并抛异常，不能只按
  “fallthrough、无 control/catch effect”验收。fixture 必须覆盖：
  primitive 与 Symbol；`@@toPrimitive`；`valueOf`/`toString` 重入；
  coercion 抛错并被当前 catch 捕获；backtrace/source pc；small-inline
  重写后的指令；physical profile 仍记 `using` 而 logical sidecar 单独记
  `to_propkey`；malformed/unknown sub 拒绝；
- 迁移窗口内 final id 112 转 `executable_alias`（D11：handler 表项保留、
  decoder/validator/dispatch 三方一致接受、进 decode fingerprint）；所有
  门通过后删除 alias（fingerprint 随之改变）、标 `quarantined_unused`
  （§11.0 生命周期），届时才记净 +1。任一门失败就把 direct 恢复为
  canonical（carrier 删除或降为临时 alias），不占用新 id；
- 试点目标是验证架构，不是追求这一条的收益。任何 final consumer 仍按
  物理 id 写死即判失败，先修基础再重试。

**G0 — 声明源最终切换（净 0 → 仍为 243/13）**

- 执行 §10 阶段 5：剩余 op 常量、`opcode_info`、direct-handler tables 与
  scanner 集合改由同一声明派生，删除重复手写源；
- C0 落地后的 final encoding 与通用 alias 支持保持不变，production artifact
  必须逐字段相同；
- 单独做 objdump + bench A/B；若 native layout 或性能过门失败，先修 G0，
  不把回归摊进下一批 demotion；
- 物理 carrier 改用中性内部名（如 `ext0`/`cold0`），logical 名保留
  `using_create`/`using_dispose`/…；id 244 与字节编码不变。纯内部命名，
  避免 explicit-resource-management 与后续迁入的无关冷组长期混淆；
- G0 通过后再冻结 C1 parent；从此 C1/C2/S1 每条的 ISA 接线只改
  logical/carrier declaration（另加测试/证据），不维护平行手写表。

**C1 — 无 payload 冷组（G0 后；先做到 28 空闲检查点，需再净省 15）**

按以下顺序挑，不预先批准整组：

1. 0 执行、cold-only、fallthrough、无代表性缺口；
2. 0 执行但有 size writer / identity matcher；
3. 次冷、cold-only；
4. 有 resident handler、control/catch effect 或产品 corpus 缺口的成员不进
   本包。

旧 envelope 在无 payload 平面有约 30 条候选；R0+C0 后只需其中再有 15 条
通过完整审计，即到 **228/28**。到达后关账并**强制复盘（D5）**，不因
“还有 sub 空位”盲目迁；向 44 推进只由 typed/FNABI 的具名
`OpcodeDemandLedger` 触发（D6）。
`set_name_computed`、`define_array_el`、`append`、`is_undefined_or_null`
可作为首批审计对象；这不是预先的 demote 判决。

旧 v1 的其余无 payload 名单不被静默带入 C1。`check_ctor`/`init_ctor`/
`add_brand`/`get_super*`/`set_home_object`、private-field 族、
`get_ref_value`/`put_ref_value`/`perm4`/`rot3l` 等只进入**复盘候选队列**，
逐条填完 §11.2 后再决定；`nip`、`swap`、`undefined`、`import` 已因
effect/resident/代表性问题从首批排除。

**C2 — payload carrier（28 空闲复盘后，由 demand ledger 触发的容量缺口启动）**

旧清单按布局得到以下候选预算：

| final carrier | 候选成员 | 最大净收益 |
|---|---|---:|
| `cold_atom_u16` | `make_loc_ref`、`make_arg_ref`、`make_var_ref_ref` | +2 |
| `cold_atom` | `private_symbol`、`delete_var`、`make_var_ref` | +2 |
| `cold_atom_u8` | `throw_error`、`define_method`、`define_class`、`define_class_computed` | +3 |
| `cold_var_ref` | `get_var_undef`、`put_var_init`、`put_var_ref`、`set_var_ref` | +3 |
| `cold_u16` | `rest`、`apply`、`apply_eval` | +2 |

合计最大 +12。**分组资格不止 payload layout**（2026-08-27 复审）；每组
必须定义并证明完整的 **CarrierCompatibilityClass**：

```
CarrierCompatibilityClass =
    物理 payload layout
  + relocation policy
  + atom/constant ownership policy
  + operand cursor 约定
  + instruction/site-pc 约定
  + adapter ABI
```

组内以上六项必须一致；stack/control/catch effect 可按 logical row 不同。
特别是 `cold_atom_u8` 的 `throw_error`/`define_method`/`define_class*`
字节布局相同，但 terminal/error 路径、helper ABI、ownership 与可观察重入
差异很大——必须证明它们共享的是 carrier 壳，不是被迫共用一段含糊的语义
handler。每组还须整体证明 generated atom offset、instruction/site pc、
operand-cursor/logical-kind adapter、terminal/direct-eval effect 与 optimizer
short/fusion 不变；少于两名合格成员的组取消，因为净收益 ≤0。`push_const`/`fclosure`
不在本包：它们先在 finalizer 变成 const8，且大模块尺寸证据不足。

**S1 — TDZ semantic carrier（最后，净 +6）**

- `checked_loc <kind, idx>` 覆盖五种 local checked 语义；
- `checked_var_ref <kind, idx>` 覆盖三种 var-ref checked 语义；
- `set_loc_uninitialized` 保持 direct；
- 9 个物理 id → 3，逻辑操作与 handler 语义全部保留。

44 个空闲可由 C1 余量、C2、S1 中成本最低的组合达到，不要求固定全收。
S1 完成后能否到 196/60，仍取决于 C1/C2 实际过门数量；不得倒推要求它们全收。

设计上界的唯一合法汇总是：

```
R0 1 + 无 payload 全 envelope 30（含 C0） + C2 12 + S1 6 = 49
245 - 49 = 196 在用 / 60 空闲
```

任一候选未过门，实际终点就按同数回退；不得从 196 反推补入更热的 opcode。

### 11.5 验收与回滚

每条迁移的回滚粒度是一个 LogicalOpcode——**仅在旧 id 处于 `reassigned`
之前成立**（§11.0 生命周期）：回收 id 至少保持 `quarantined_unused` 到
包验收关账与 28 空闲复盘；空位一旦被新 opcode 占用，回滚升级为连带回滚、
epoch 提升或重配空位。每个包都必须满足：

1. parser/lowered/final 三域的 canonical direct/carrier encode/decode
   round-trip，以及所有 decode alias 的单向 round-trip；包括全部现役
   parser/lowered `using` sub；
2. final artifact 中旧 direct id 计数为 0；parser/lowered 中出现不算失败；
3. profiling build 仍按 LogicalOpcode **form** 分行计数（D12：
   `logical_form_count` 是主键，family 只是生成的 rollup 视图），carrier
   sub 不得聚合或丢失；
4. targeted compiler/bytecode/exec tests + GUIDE B.6 对应最低覆盖档；
5. 包边界 `zig build test`、`zig build test262-check` 全绿；
6. bench-v8 对 immediate parent、245/11 project-root 都交错三次；C1 及以后
   另与 G0 carrier-root 比较以归因。**门槛以测量噪声为单位，不以裸点值**：
   任何包合入前，先用同一构建做 A/A 交错测量，把该机器/该套件的噪声区间
   记进包验收记录；超出噪声区间即失败，噪声区间宽于 1% 时必须先收敛测量
   方法而不是放宽门。F0 各片因 artifact 逐字节相同，运行时预期是
   **统计零**（可归因的只剩引擎二进制布局漂移，由第 10/11 条捕捉），
   不享受 1% 空间。1% 中位数上限只适用于 C 包，且是对 245/11
   project-root 的**累计中止线**——触线即停止后续包，不能在每条或 28/44
   检查点重置；本方案设计收益为 0，任何真实回归都是净亏，1% 不是可花费
   的预算；
7. corpus 总字节码同时报告 parent delta 与 245/11 project-root cumulative
   delta，任一口径 +0.3% 预警；另报 p95 单函数膨胀，防总量掩盖长尾；
8. `pipeline_stack_size`/`FinalArtifactValidator` 的 payload-carrier atom-offset、
   IC site-pc identity、CFG terminal/direct-eval、catch-depth、runtime
   adjacent-pattern matching 各有至少一个 fixture；standalone/packed-finalize
   与 compiler `layout=short`/`-Dzjs_compiler_layout=plain` 都必须覆盖，且禁止
   用“整 carrier 一律 forbidden”掩盖缺失 trait；
9. 按 `docs/qcp1_switch_decision.md` §9 核对 layout-sensitive compiler 变更；
   production attestation 仍是 `layout=short`，plain 只作 A/B，不改变发布配置；
10. objdump 对照 handler island；旧 handler body 的删除与 id/encoding 迁移
   分开 A/B，不把地址重排噪声混进 carrier 判定。direct-form
   `matchesFormAt` 与 runtime lookahead 的生成 matcher 另有**反汇编
   fixture**：证明对 direct 目标仍编译为一次 byte compare、无间接调用
   （P1-1 的 codegen 证据，合同文本不能替代对生成代码的核对）；
11. **编译器开销与 F0 的 decoder/encoder 改造同包计量**（它影响每一条
    字节码，不只是被降级的冷 opcode）：`resolve_variables`、
    `resolve_labels`、packed-finalize 的 ns/byte；大型 TypeScript/module
    编译耗时；峰值临时内存；compiler `.text`/`.rodata` 增量；Zig
    comptime/build time 增量。opcode runtime bench 全绿不能替代这组数字；
    判定同样以第 6 条的 A/A 噪声区间为单位。

#### F0b 关账（2026-08-28）

第 6 条要求 bench-v8 **对 immediate parent 与 project-root 两个口径都**
交错测量。下面两小节按这两个口径分列；先是对 immediate parent
（`ef7fc62a`）的单基准账，再是对 project-root 的全套账。

##### 口径一：对 immediate parent（`ef7fc62a`）

按第 6 条先做 A/A：同一构建两份拷贝、core 8 交错、各 n=12，中位偏差
**±0.29%**，合并 CV 0.21%，臂内极差 0.75%——带宽在 1% 以内，测量方法
按第 6 条可用，不需要先收敛。

| 条 | 项 | 结果 |
|---|---|---|
| 6 | 运行时（Richards，交错 n=10/臂） | **+0.12%**，在 ±0.29% 带内 = 统计零 ✅ |
| 11 | 编译路（CodeLoad，交错 n=12/臂，三轮独立复现） | **−1.64%**，**带外 5.6 倍** → **owner 接受（2026-08-28，见下）** |
| 11 | 编译路定工作量指令 | +0.89%（未修版 +4.44%） |
| 5 | `zig build test` | 2371 通过 / 0 失败 ✅ |
| 5 | `zig build test262-check` | 0/49778 错误，44584 通过 ✅ |
| 7 | corpus 字节码 delta | **0**（F0b 不改发射，artifact 逐字节相同） |
| 10 | handler island | 164448→164512（+64B，非 F0b 目标区） |

第 11 条的判定单位是 A/A 噪声区间，而 −1.64% 明确在带外。**这不是一个
可以由实施者自行吸收的数**，按第 6 条「超出噪声区间即失败」的字面，F0b
的编译器开销项未过门，需 owner 就以下事实作一次裁定：

- 代价**只落在编译路**，且 CodeLoad 是全套里编译最密集的一个，即 1.64%
  是最坏情形而非典型值；运行时基准已回到统计零。
- 换到的是 §5.2(3) 缺陷类的结构性关闭：三张手写身份名单撤销、三个
  consumer 不可能再对指令布局各执一词，而这一条是 §11.0 记的 F0b 全部
  收益所在。
- 残余里可归因到工作量的只有 +0.44%（栈遍历那一趟的 +14M 指令），其余
  按已登记的规矩先疑代码布局。继续磨的边际收益低，且第 6 条明言本方案
  设计收益为 0、1% 不是可花费的预算——所以不应把它当作「还能优化掉」
  而先合入。

另需记入：合同 2 的 header 字段表与「每条指令一次查表」硬约束按实现回报
修订（见 §10.8 合同 2），修订本身是这次归因的产物。

###### 残余的微架构归因，与五次归零的尝试（2026-08-28 第二轮）

第一轮把残余记成「按已登记规矩先疑代码布局」。第二轮把它量了出来，
**推测升级为测量**（core 16，`perf stat -r3`，定工作量编译负载）：

| 事件 | parent | 当前 | Δ |
|---|---|---|---|
| instructions | 3149.8M | 3175.2M | +0.81% |
| cycles | 943.9M | 956.9M | +1.38% |
| branch-misses | 17.879M | 17.897M | **持平** |
| **L1-icache-load-misses** | **22.91M** | **24.28M** | **+6.0%** |
| L1-dcache-load-misses | 8.73M | 8.94M | +2.4% |

**+1.14M 次 icache 缺失 × 约 10 周期 ≈ 11M 周期，正好覆盖 10.6M 的周期
缺口。** 分支预测持平排除了「form 上的 switch 变差」这一假设。足迹来源
用 `nm -S` 定位：`computeStackSizeForCurrentBytecode` 从 **2976 → 4596
字节（+54%）**，另有新增的 `layout_table` 26.8KB（数据，不进 icache）。

**结论：残余不是「做多了工作」，是「多了代码」。** 编译路是 I-cache
受限的，所以对这条路而言**加代码比加指令更贵**——这也解释了为什么分数
差（−1.6%）是指令差（+0.8%）的两倍。

五次尝试，全部归零或变差，逐条记下以免重试：

| # | 尝试 | 结果 |
|---|---|---|
| 1 | 内联 `headerAt` | **+21.3M 指令**（多调用点膨胀） |
| 2 | 内联 `stackEffect` | 指令 −2.4M 而**周期 +5.9M、icache +0.92M** |
| 3 | 取消验证器的 `inline` | +20.5M 指令、+6.8M 周期 |
| 4 | 用行表位门控那 26.8KB 的 layout 查表 | 周期**逐 M 相同**（该表本就常驻 L1D） |
| 5 | 把 `invalid` 检查折进行表位 | 周期相同，且**破坏直接形态往返（P0-1）** |

第 2 条是**指令幻影定律的反向实例**：省了指令却付了周期，机制是 icache。
已登记的先例都是「减指令收益为零」，这是第一次量到「减指令为负」，
所以本条线此后的判定一律**以周期与 icache 为准，不以指令数**。

第 5 条不是性能问题而是分层问题：`invalid`（id 0）是往返测试的成员，
解码器的职责是**如实报告字节里是什么**，判断它允不允许是验证器的事。
那个改动让解码器对它撒谎，收益为零而代价是 F0b 存在的理由之一，
按设计理由撤回，不是按测试失败撤回。

**这是本设计的地板。** 再压需要让解码层比它替换掉的字节查表**更小**，
而它在做严格更多的事——结构上做不到。第 11 条那笔编译路代价因此是
**要么接受、要么放弃 F0b 的结构收益**，不存在「再优化掉」的第三条路。

###### owner 裁决（2026-08-28）：接受，附边界条件

owner 在完整评估（真实价格 = 编译路最坏情形 −1.3~−1.6%、运行时 0；
综合 0.9996 中的抵消是布局噪声的偶然，不作为接受依据）后裁定**接受**，
理由按权重：价格封顶、已知、到底；买到的是 C 包 id 迁移的安全前置
（`put_super_value` 前科：身份匹配失明是测试原理上抓不到的缺陷类）；
产品暴露面小且随 AOT/eval-cache 路线单调缩小；回退的代价不对称。

**接受范围只覆盖 F0b parts 1–4 已迁的三个消费者。** 附带三条边界：

1. **后续每个消费者迁移各自付费过门**：定工作量 cycles + L1i（不以
   指令数——本关账「五次归零」一节的直接教训），交错 ABBA，A/A 带为尺。
2. **累计停止线：CodeLoad 对 `b1ab5200` 累计不得超过 −2.5%**，触线即
   停在上一个消费者。§11.5 明文「停在 F0b 是特性不是失败」，部分迁移
   是合法终态。
3. **运行时 lookahead 的迁移性质不同**（碰解释器热路径），P1-1 的
   反汇编 fixture（direct 目标保持一次 byte compare）是硬门，合同文本
   不能替代对生成代码的核对。

`resolve_labels.walk` 本身是编译路最热函数之一（~140M 指令），其迁移
**不在本次接受的价格内**，按上述第 1、2 条单独关账。

###### resolve_labels 迁移关账（2026-08-28，`727ea835`）

按上述条件过门。判据读数（定工作量，同场交错 A/A 带，n=16/臂）：
**cycles −0.12%（带 ±0.07%，方向为好）**；L1i +1.24%（带 ±0.25%，真实）
但周期账闭合——+0.30M 缺失 ≈ +3M 周期，对面指令 −8M ≈ −2.4M 周期，净
−1.1M 正是读数；指令 −0.25%（comptime 派生偏移删掉了 readU32At 每跳转
一次的 checked-add + 边界证明）。**结论：本迁移在编译路上是净零到微赚，
不占用余量。**

**停止线当日不可判，以周期代账**：CodeLoad 分数仪器下午失去分辨率——
**基线臂自身一分钟内漂 3.3%**（36103→34906）、迁移前臂与自己早晨的
定值矛盾 5pp，而同窗口周期计数 CV 0.32%；频率钉在 3.89 GHz，非热降频。
按测量合同，分辨不了效应的仪器不出裁决数字。周期代账：F0b 关账 −1.64%
+ 本次 −0.12% ≈ **累计 −1.5%，在 −2.5% 线内**。⚠️ **分数复测挂起**：
下一个干净窗口跑三臂 ABBA 收口，若与周期账矛盾再升级。

###### CFG/resolve_variables 迁移关账（2026-08-28，`9225f1d7`）

parser/phase-1 两域按修订后的合同 2 落地（签名带 atom ledger）。过门读数
（**同树对照臂**，n=16/臂交错）：**cycles ±0.00%（带 ±0.03%，完全持平）**、
insn +0.35%（Header→TempInstruction 接缝的真实成本）、L1i +5.63% 出带但
**零周期代价**——按 resolve_labels 先例判通过（周期是度量，L1i 是解释）。

三条方法记录，都够资格进档案：

1. **F0b 教训的微缩重演**：cfg 的手写表快，是因为重映射/side-table 拒绝/
   claimed 判定全部**烧在表里**；第一版实现把它们展开成逐指令运算，
   `resolve_variables.run` +29M 指令。修法=按物理 id 烧 4 字节 DomainRow
   域表，决策 comptime 从声明解出。「一次查表」硬约束适用于**每个域**。
2. **对照臂必须同树构建**：最初三次修复追的 +27M 指令有 16M 根本不存在
   ——「迁移前」臂用的是历史二进制，与被测臂还差着当天 decode 层的全部
   改动。同树对照（只回退 cfg.zig 重建）给出真实差 +11M、周期死平。
   **对照臂永远从同一棵树构建，不从当天早些时候捞。**
3. **不变量 5 的 comptime 版**：域表生成先 `@enumFromInt` 再判断，
   在 id 16（reclaimed）上构建期爆炸。判断改按数值比较。同一缺陷第三次
   出现（headerAt 运行时版、此处 comptime 版），模式固定：**先验证、
   后转枚举**。

两张手写表按「删除前证明」规矩处理：comptime 断言逐 id 证明派生视图与
手写表相同（注入两类故障均开火），表降级为断言的对照基线，G0 时撤。

###### 反汇编器与运行时 lookahead 关账（2026-08-28，`d1df1cf8`/`1ef2c53b`）——**F0b 消费者清单至此闭合**

**反汇编器**：decode-first + 单字节容错回退（反汇编器必须能渲染损坏流，
回退恰好在 decoder 正确拒绝处继续走）。fmt 巨 switch（约 110 行 20 个
格式）换成 layout 逐槽循环，且**打得更多**——烧入操作数（`get_loc0` 的
slot 0）从前没有字节可读，现在从声明打出。冷路径无性能门；`.text`
净 −4KB。

**运行时 lookahead**（P1-1 硬门）：全部集中在 `vm_property.zig`。
**形状分毫未动**——direct 匹配保持一次 byte compare，结构化 decode
不进这些路径。改变的是数字的出处：**72 处手写魔数**（烧入 idx、next_pc
步长、边界 size、consume 宽度）改为 comptime 从声明派生
（`sizeOfForm`/`burnedOperandOf`）。数字全都是对的，但从前没有任何东西
把它们连到定义它们的声明上——重编码一个 form 会把每个 matcher 变成
静默错解码器；现在变成编译错误。两个注释级假设升格为构建断言
（序列匹配的 pc+1 步进依赖六个 form 恒 1 字节；`decodeFieldAtom` 步长
依赖 get_field 族恒 atom 尺寸）。

P1-1 证据（裁决要求生成代码核对，合同文本不算）：
**`.text.zjs.op_handlers` 逐字节相同（164448 == 164448）**、定工作量
指令 −0.005%（统计零）、周期 +0.29% 在指令零 + handler island 不变下
判为布局（.text 因 dump 重写移动了 4KB）。

**F0b 消费者清单闭合**：栈遍历、验证器、内联扫描器、resolve_labels、
CFG、resolve_variables、反汇编器、运行时 lookahead 全部就位。余项一条：
CFG 的身份谓词（isUnconditionalTerminal 等）仍收物理 id——它们匹配的
是控制流 op（最不可能降级的集合），form 化留作 F0c 生成 matcher 的
输入，不作为 F0b 未完成项。

迁移本身的两条附带产出：`FormRow` 新增 atom/label/index-width 三类
声明派生位（`label_bit` 让 validateProductCode 拒绝「未获准的整类带
label form」而非手维护格式黑名单）；语义收紧——旧 reader 接受任何有
表行的 id（含十个已回收 id 的规范死行），headerAt 拒绝之，S3/S4 流里
的退役 opcode 现在是 InvalidBytecode。

##### 口径二：对 project-root —— **opcode 线整体持平**

第 6 条的第二个口径问的是累计账，而这才是判定这条线有没有变坏的那个数。
基线取 **`b1ab5200`**（= `78d77089^`，opcode 线第一个代码改动之前）；
`git log -- src/ tools/` 核过，`b1ab5200..94063da6` 区间内**每一个改动代码
的提交都是 opcode 工作**，没有其他线掺入。仪器用仓库自己的
`tools/perf/bench_v8/run_benchv8_compare.py --baseline`（serial 协议、
core 18、ABBA、8 样本/引擎），不自造。证据：
`reports/evidence/PERF-OPCODE-SPACE/`。

**综合 Score（version 9）比值 0.9996**，而同仪器同构建的 A/A 给出
**0.9986（带 ±0.14%）**——A/B 偏差 −0.04% 在带内。**判持平：opcode 线
整体没有性能退化。**

| 基准 | A/B | A/A 噪声带 | 判定 |
|---|---|---|---|
| CodeLoad | **0.9866** | ±0.49% | 带外，**有机制**（口径一那笔） |
| RegExp | 0.9873 | ±0.28% | 带外，但复测不稳（见下） |
| DeltaBlue | 0.9879 | ±0.28% | 带外，约 −0.4%，无机制 |
| EarleyBoyer | 1.0109 | ±0.38% | 带外**正向**，无机制 |
| Typescript | 1.0077 | ±0.05% | 带外**正向**，无机制 |
| PdfJS | 1.0065 | ±0.13% | 带外**正向**，无机制 |
| SplayLatency | 1.0146 | ±4.69% | 带内（该指标双峰，噪声本就大） |
| 其余九项 | 0.999–1.005 | — | 带内 |

**只有 CodeLoad 一条既超带又有机制。** 其余超带项按第 10 条处理——它正是
为「不把地址重排噪声混进判定」而写的：

- **DeltaBlue** 用三臂 n=20/臂、含同轮 A/A 对照（A/A −0.07%）复测为
  −0.54%，再以 `ef7fc62a` 切段，**−0.34% 落在前半段**（回收 id、
  with 族 5→1、R0、F0a），F0b 只占 −0.03%。
- **RegExp 在这个效应尺度上超出仪器分辨率**：两次独立复测给出 −0.89% 与
  −1.66%，切段读数是「前半段 +1.88%、F0b −3.47%」。**记为未解决，不记为
  一个数**——已登记的先例是同一改动两个顺序给出相反符号。
- 同一次 A/B 里另有四项**往上**走了 0.65~1.46%，同样说不出机制。
  **正负混杂、无机制、在综合分上相抵归零，是 handler island 的布局签名**：
  前半段的改动全在删或并 handler（退役 nip1、降级 set_proto、回收 5 个
  id、with 族 5→1、R0 删融合），每删一个，其余 handler 的地址就整体移位。

这一口径**改变了口径一那笔账的分量而不改变它的判定**：CodeLoad 的
−1.34%（本口径）/ −1.64%（对 parent）仍然超带、仍然有机制、仍然是第 11 条
未过门的那一项；但它在整条线的累计账上被其余基准抵消，综合持平。
两件事都要摆给 owner，不能只报其中一件。

F0 额外证明 production artifact（新增 logical profile section 除外）逐字段
不变；R0 额外证明“不再发射”；C0 额外遍历所有 final-phase consumer；G0
额外证明派生表与旧手写表逐字段相同，并单独关账 native layout；S1 额外跑
test262 `let`/`const`/`class` 相关切片，并差分 derived-this、double-super、
closure const write 与普通 lexical overwrite。

**随时可停是本方案的特性，不是失败模式**：每个包独立关账，任何一包
触门就停在上一包的终态，已落地的包不需要回滚。特别地，停在 F0（甚至
F0b）意味着运行时风险为零、声明源与 decoder 的维护收益已全部落袋、
carrier 线一条未迁——没有 alias 或迁移窗口欠账（R0 只在账本留一格
`quarantined_unused`）。C 包只在 §11.7 授权与 demand 证据就位时才重启，
不因“基础设施已建好”而自动继续。

### 11.6 明确排除

- register/accumulator VM、TOS caching、E1/E2；
- 48 条槽位搬运、`drop` 与 R0 后剩余的融合（现账 22−1=21）；
- `invalid`、`nop`；
- `call_constructor` 与有 resident 热 handler、但无代表性收益证据的 opcode；
- async/generator/iterator/module 动态路径：`throw`、`catch`、`gosub`、
  `return_async`、`yield*`、`await`、`for_of*`、`for_await_of*`、
  `iterator_*`、`import`；
- 单成员 payload 组（载体成本抵消收益）；
- 仅因某个 corpus 为 0、仅因别的引擎没有同名指令、或仅因 sub 空间有余量
  而发起的降级。

### 11.7 owner 裁决（2026-08-27 两轮，复审对象 `main@f43a78e9`）

一轮总裁定：**有条件批准总体架构，不按复审前文本直接解除实施暂停。**

> **D1 — 批准。**Logical instruction/form 与 parser、lowered、final
> physical encoding 分离；逻辑身份至少存活到全部优化与 label resolution
> 完成。
>
> **D2 — 条件批准。**§10 实施前补充并冻结 `LogicalForm/SemanticFamily`、
> `DecodedInstruction`、`EncodingPlan`、carrier `InstructionContext` 四个
> 合同（§10.8）。
>
> **D3 — 批准。**R0 可与 F0a 并行实施；`put_loc0_get_loc0` 退役。
>
> **D4 — 分阶段批准。**立即批准 F0a；F0b–F0e 分别评审。任何 production
> carrier 仍须等待所有 final consumer 与 writer 完成迁移。
>
> **D5 — 批准。**28 个空闲为第一检查点。到达后强制复盘。
>
> **D6 — 暂缓。**44 个空闲改为需求触发的容量目标；typed/FNABI 必须先提交
> 具名 demand ledger。60 仅保留为非规范性 envelope。
>
> **D7 — 批准。**C0 默认候选为 `to_propkey`，但最终选择须由刷新后的
> representative logical profile 决定，并补齐 coercion/throw/backtrace
> fixture。
>
> **D8 — 批准。**register VM、TOS caching、E1/E2 继续保持在本工作项范围外。

二轮复审不推翻 D1–D8，追加 D9–D12，并对当轮文本判定：D1 架构原则
**通过**；R0 **通过**；物理表镜像与编号账 **通过**；**§10.8 冻结未通
过**；**完整 F0a 未通过**；F0b/F0c/F0d 继续暂停。P0-1…P0-6 的修订已并
入 §10.3/§10.4/§10.7/§10.8，待 owner 确认后冻结：

> **D9 — 收窄 F0a 授权。**立即可实施的只有物理 opcode 表镜像、编号账和
> 现表等价断言（F0a0）。LogicalOpcode/Operand/Effects/fingerprint 声明
> （F0a1）等待 form selection、embedded operand、effect expression 与
> 模块分层冻结。
>
> **D10 — 编码职责拆分。**final form selection 与 physical encoding 是
> 两个阶段。shortening、jump width 和 fusion 产生新的 final
> LogicalOpcode form；physical encoder 只在 direct/carrier 之间选择
> （§10.8 合同 3）。
>
> **D11 — alias 是正式物理槽位状态。**区分 executable alias 与
> decoder-only alias；前者保留 handler 并进入 decode fingerprint，后者
> 不得通过 production validator（§10.3 `PhysicalSlotState`、断言 18）。
>
> **D12 — profile 以 form 为主键。**每个 LogicalOpcode form 独立计数，
> SemanticFamily 仅作为生成的聚合视图（§10.8 合同 1）。

一轮复审同时留下两项**非阻塞跟进**：

1. **文档再拆分**：normative 主文（架构/schema/包序/验收）与 rationale
   （机器模型、E1/E2、历史错误、方案对照、修订史）分离到
   `opcode-rationale.md`，主文控制在可一次完整 review 的规模；当前
   “停议材料若冲突以 §0/§11 为准”的阅读规则本身就是风险。
2. **性能证据补齐**：按 workload 的 `max_single_workload_share` 分层
   （已并入 §11.2）与编译器开销计量（已并入 §11.5(11)）在 F0 期间落地。

---

## 附录 A：源码坐标索引

> 四引擎的**完整**设计记录与更细的坐标在
> [`opcode-engines.md`](opcode-engines.md)；下表只列本文正文引用到的。

**zjs**

| 事实 | 坐标 |
|---|---|
| opcode 表（id / size / n_pop / n_push / fmt） | `src/bytecode.zig` `opcode_info` |
| 相位复用区 | `src/bytecode.zig` `op_temp_start = 178`, `op_temp_count = 19` |
| 冷平面载体与子表 | `src/bytecode.zig` `using_sub`（`add_base` 历史上由 16 抬到 64） |
| 现役 parser/lowered early carrier | `src/parser.zig` 的 `Emitter.opU8(... op.using ...)`；`src/compiler/resolve_variables.zig` 的 `using_sub.is_undefined` |
| 现有按 sub 读动态栈效应处（尚不覆盖 control/catch） | `src/bytecode.zig` `pipeline_stack_size`（`using` / `dyn_env_probe` 两个分支） |
| final atom 固定偏移假设 | `src/bytecode.zig:7860` `FinalArtifactValidator.validateKnownInstruction`（`pipeline_stack_size` 容器内的**非 pub 嵌套 struct**，`main@f43a78e9` 实存；顶层符号搜索会漏，二轮 P2 已核） |
| standalone/packed-finalize 入口 | `src/compiler/resolve_labels.zig` `run` / `runForPackedFinalize` |
| 按身份匹配的扫描器 | `src/bytecode.zig` `scanSmallInlineEligible`；`src/exec/small_inline.zig` `isForwardForbiddenOp` |
| post-final bytecode writer | `src/exec/small_inline.zig` `rewriteBody` / `emitByte` / `emitSlice` |
| handler operand/site-pc 假设 | `tailcall_dispatch.Vm.publish`；`vm_property_globals.getVar` 的 `frame.pc - 1` |
| runtime final-stream lookahead | `vm_property.zig`、`vm_property_globals.zig`、`vm_gen_async.zig`、`eval_ops.zig`、`vm_call.zig`、`builtin_dispatch.zig` |
| 现有物理 id profiler | `src/exec/vm_profile.zig` `noteDispatch`；`src/core/profile.zig` 256 项 `count` |
| 尺寸预言机路径 | `rules.loweredPrivateFieldSize` / `rules.writeLoweredPrivateField` |
| 字节偏移 pin | `compiler.s2g4` 测试 |
| Reference 族触发条件 | `src/parser.zig` `needs_reference`；`src/bytecode.zig` `loweredScopeMakeRefSize` / `writeLoweredScopeMakeRef` |
| 冷壳子派发 | `using_ops.execVm` |

**V8 15.4**（`/home/aneryu/v8`）

| 事实 | 坐标 |
|---|---|
| bytecode 列表 / 累加器语义 | `src/interpreter/bytecodes.h`（`BYTECODE_LIST_WITH_UNIQUE_HANDLERS`，193 条；`Ldar` :87、`Star` :110） |
| 前缀平面 | `bytecodes.h:678-719`；`interpreter-assembler.cc:1433-1461`；`interpreter.h:105-114` |
| wide handler 的 ±1 偏移修正 | `interpreter-assembler.cc:100-116` |
| TDZ 检查 op（4 条） | `bytecodes.h:484-488` |
| 「编号快用完就转 intrinsic」 | `interpreter-generator.cc:2679` |
| 退役 commit | `3b6773ba3d1` / `e06d57b05de` / `f633218b624` / `a8176a530c3` |
| 合并 commit | `e8a0a3717c3`（StaGlobal）/ `02a725e2a07`（hole 表示 done）/ `6c1e09aebe9`（StackCheck 折进 JumpLoop） |

**JSC**（`/home/aneryu/WebKit/Source/JavaScriptCore`）

| 事实 | 坐标 |
|---|---|
| 指令集 DSL 单一真源 | `bytecode/BytecodeList.rb`（125 `op :` + 10 `op_group` = 135 声明点 → 194 id） |
| 三地址二元运算 | `BytecodeList.rb:1290`（`BinaryOp`）、`:1312`（`ProfiledBinaryOpWithOperandTypes`） |
| `mov` | `BytecodeList.rb:1284` |
| 生成器 | `generator/main.rb`、`Opcode.rb`、`OpcodeGroup.rb`、`Fits.rb` |
| 自动宽度选择 | `generator/Opcode.rb:234-238` |
| 休眠的 2 字节 id | `OpcodeSize.h:76-97`；`generator/Opcode.rb:226-250` |
| 操作数重映射（代替短指令） | `Fits.h:117-155` |
| 三份 handler 的体积 | `LLIntAssembly.h` 7.67 MB / 582 标签 |
| checkpoints | `BytecodeList.rb` 里声明 `checkpoints:` 的 op |

**Hermes**（`/home/aneryu/hermes`）

| 事实 | 坐标 |
|---|---|
| 指令定义 | `include/hermes/BCGen/HBC/BytecodeList.def`（180 条 `DEFINE_OPCODE_n` + 20 条 `DEFINE_JUMP_n` × 2 = **220**） |
| 三地址 `Add` | `:210`；`AddN` `:213` |
| `Mov`/`MovLong` | `:168` / `:171` |
| 操作数直方图 | Reg8 446 / UInt8 52 / UInt32 40 / UInt16 29 / Addr32 25 / Addr8 22 / Reg32 2（含 `DEFINE_JUMP_n` 展开） |
| 布局相等断言（15 对） | `ASSERT_EQUAL_LAYOUT{1,2,3,4}` |
| Long 变体（38 个，含跳转宏自动配对） | `*Long` 后缀 |
| `with` 不支持 | `SemanticResolver.cpp:757` |
| NaN 与取反跳转的论证 | `BytecodeList.def:977-981` |

**QuickJS**（`/home/aneryu/quickjs`）

| 事实 | 坐标 |
|---|---|
| opcode 定义与两次包含 | `quickjs-opcode.h` |
| 相位复用的运行时痕迹 | `quickjs.c:22176-22186` `short_opcode_info(op)` |

**测量**

| 数字 | 出处 |
|---|---|
| 419 亿次执行、逐 opcode 频次 | 附录数据表（15 zoo 基准，`ZJS_PROFILE_ALL=1`；⚠️ 占比口径依赖，见附录 C） |
| 每次槽位读做一次 incref | `src/exec/value_slot.zig:10` `loadOwned` = `slot.*.dup()`；`src/exec/slot_ops.zig:51` |
| 每个 opcode 是独立函数符号（E1 的前提） | `src/exec/tailcall_dispatch.zig:5,314,364`（`callconv(.c)` + `align(16/64)` + `linksection(op_handler_section)`）；冷壳共享体见 `tailcall_dispatch_colds.zig:8-10` |
| K4 门：字节码架构重估的三条准入条件 | `docs/architecture.md` §8「Stack Bytecode VM Status」末段；保留条款出处 `qjs_alignment_charter_transition.md` K4 |
| qjs 对齐宪章 R1-R3 退役、K1-K5 保留 | `docs/qjs_alignment_charter_transition.md`（RATIFIED，owner 2026-08-24） |
| FNABI 三地址编码草案 | `docs/fun-native-plugin-design.md` §17.1 |
| FNABI 非目标 #11「任意签名组合自动生成专用 VM opcode」 | `docs/fun-native-plugin-design.md:322` |
| 新 handler 族的 I-cache 外部性硬门 | `docs/fun-native-plugin-design.md:3256`（M2 验收门） |
| TOS caching 成本模型（16B/档） | `docs/engine-evolution-plan.md` §8.3（原为 baseline JIT v1） |
| 「first-class Zig project」纪律 | `docs/engine-evolution-plan.md` §3.3 |
| ~20.7 cyc/iter ≈ 3 cyc/dispatch；asm 省 16% insn 兑现 0.0% | `engine-evolution-plan.md:205-213`（2026-08-24 三骨架实测） |
| 指令幻影定律 | measurement-contracts 第 8 条；2026-08-07 起多次复现 |
| 481 处栈操作 / 331 处发射点 / 6721 行热派发 | `grep -c`，`src/exec/*.zig`、`src/parser.zig`、`src/exec/tailcall_dispatch.zig` |

---

## 附录 B：修订史——被推翻的估计，以及推翻它们的方式

**保留这一节的唯一理由是错误的形态可复用。这里的数字全部作废，不得引用。**

### B.1 「26 个编号可靠语义重设计省下」→ 实为 13 重设计 + 13 降级

审计初版按跨引擎名字对照估出六族共约 26 个编号可省，且认为其中大部分来自
语义重设计。owner 令「全部完整核对一遍」后逐族读实现：

| 族 | 初版估计 | 核对后 | 差异原因 |
|---|---:|---:|---|
| `with` | 4 | **4** | ✅ 唯一完全成立的 |
| TDZ | 7~8 | 6 | 三家是 2~4 条纯检查 op，不是 0~1 |
| Reference | 6 | 3 | 栈机形态必需，只能合并变体 |
| super | 4 | 4 | **机制判错**：是降级不是重设计 |
| 类命名 | 4 | 5 | **机制判错**：是降级不是重设计 |
| `plus` | 1 | **0** | 整条作废 |

**六族里：一族完全成立、两族数字降了、两族机制判错、一族整个作废。**
总数巧合地接近，但**构成完全不同**。

### B.2 「152 个 opcode 从未进过 top-40」

早期用 profiler 默认的 40 行上限当代理，把「温而不热」的 opcode 与真正的
冷 opcode 混为一谈，还错排了 19 个 temp opcode。解除上限后的精确普查见
§2.2。

### B.3 「45 个零发射点候选」

字面搜索的产物，几乎全是假阳性（§5.1a）。读完只有 `nip1` 幸存。

### B.4 wave 1 批量降级被回滚

runtime 的 carrier/sub 机制可行，但“在 emitter 直接改编码”的迁移边界不完整；
当时先撞上成本因子 (1)(2)（§5.2）：**用算术 +1 批量改字节偏移 pin，破坏了
`readInt` 断言。**本轮又确认它还会漏 logical identity 与 effect（B.6）。
因此回滚是正确的；现行替代为 late final encoding。

### B.5 前缀/wide 平面曾是本工作项的主方案

roadmap 原文把 PERF-OPCODE-SPACE 描述为「wide/prefix planes」。读源码后
退出范围：**V8 和 JSC 的前缀机制根本不扩展 opcode 编号，只扩展操作数
宽度**（§3.5）。买不到一个新编号，还要付第二次间接跳转和 handler 三倍化。

### B.6 旧 §11「按 emitter 直接降级」→ late final encoding

旧 §11 v1 把候选在 parser/下降 writer 阶段直接改成 `{carrier, sub}`，并把
stack effect 当成载体唯一需要动态化的属性。逐源码复核发现该方案会破坏
peephole/CFG 的 logical identity，并漏掉 catch、terminal、direct-eval、
atom offset 与 caller-realm/const/init 语义。

现行 §11 v2 把 LogicalOpcode 保留到优化结束，只在 final-form writer 边界
选择物理编码；§10 同步把完整 effect 与 operand offset 纳入声明。旧 v1 的
245→196 只能保留为候选预算上界，不能再当已批准执行账。

---

## 附录 C：逐 opcode 数据表，以及它的采集口径

见 [`opcode-audit-table.md`](opcode-audit-table.md)——247 条历史 identity
有采样行，每行含 id / 名字 / size / fmt / n_pop-n_push / 执行次数 / 占比 /
发射方式 / 处置。**247 不是当前在用数**：快照仍保留后来降级的
`put_super_value`/`to_object` 两行；当前 245/11 只由 final 表生成，见 §2.1。

### ⚠️ 百分比是采集口径依赖的（2026-08-27 复现后补）

用第二套 harness（`tools/perf/bench_v8/driver.js`，**它跳过 zlib**）复现：

| | 本表（zoo 口径） | 复现（bench_v8 driver） |
|---|---:|---:|
| opcode 执行总数 | 41,888,384,774 | 14,685,087,888 |
| 有读数的 opcode | 247 | 170 |
| 槽位搬运 | 33.6% | **36.1%** |
| 槽位+洗牌+drop | **34.1%** | **37.6%** |

单条 opcode 最大相差约 ±2.5pp。⇒ **正文引用此表的百分比，一律读作
「两套口径的区间」，不要引用到小数点后两位。**方向与量级两套口径都成立。

**已立欠账**：本表生成时的精确命令未记录（只写了「15 个 zoo 基准 +
`ZJS_PROFILE_ALL=1`」），因此**本表严格意义上不可复现**。下次重做普查必须
把完整命令行与 harness 版本写进表头。E1（§9.5）的 policy 已经要求记录
binary sha256 与 merge-base，正是为了不再犯这条。
