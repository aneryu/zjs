# zjs 指令集设计：全部信息与待裁决项

**PERF-OPCODE-SPACE**（roadmap owner-decision 槽，最高优先级前置项）。

> **单一现行文本**（现状 / 方案 / 裁决 / 设计）。本文取代并合并了
> `opcode-space-survey.md`、`opcode-audit.md`、`opcode-redesign.md` 三份
> （已删除，内容全部并入）。配套两份**只放资料、不放结论**的附属文件：
>
> | 文件 | 内容 |
> |---|---|
> | [`opcode-engines.md`](opcode-engines.md) | 四引擎指令集设计逐个记录 + 逐语义域对照矩阵 |
> | [`opcode-audit-table.md`](opcode-audit-table.md) | zjs 逐 opcode 原始数据（频次 / size / fmt / 发射方式） |
>
> 正文里的数字**全部是已按实现核对后的现行值**。被推翻的中间估计不出现在
> 正文，集中记在**附录 B 修订史**——那些错误的形态本身是有价值的教训，
> 但它们的数字绝不能被当成现行结论读到。

跨引擎事实全部读自本地源码检出，不是回忆：V8 15.4（`/home/aneryu/v8`）、
JSC（`/home/aneryu/WebKit`）、Hermes（`/home/aneryu/hermes`）、
QuickJS 2026-06-04（`/home/aneryu/quickjs`）。日期：2026-08-27。

---

## 0. 一页摘要

**起因**：typed 家族要 20–40 个新 opcode 编号，FNABI 的 `CALL_NATIVE_*`
要约 25 个，合计 **45–65**；开工时我们只有 **2 个空闲编号**。

**做过的事**：调研四引擎的扩容/回收机制 → owner 裁「按 V8 模式回收」 →
逐条审计全部 251 个 opcode → 逐族按实现核对 → 落地 9 个编号的回收
（现 **245 在用 / 11 空闲**）。

**然后 owner 令扩大范围**：不要逐个抠编号，**参照 V8/JSC/Hermes 把整套
指令集重新设计**，并升为最高优先级前置项，增量回收暂停。

**扩大范围后的第一个发现，也是全文最重的一条**：前面所有工作共享一个
**从未被检验的前提——机器模型不变**。读三家源码当场推翻：

> **JSC 和 Hermes 是纯三地址寄存器机，V8 是累加器+寄存器机。
> zjs 和 QuickJS 是五者里仅有的两台栈机。**

由此得到两个量化结论：

1. **58 个编号 + 约三分之一的全部动态指令（两套采集口径下 34.1% / 37.6%），
   是「因为我们是栈机」才存在的开销。**
   其中槽位搬运一项就占 33.6%（另一口径 36.1%），而这些指令
   **不做任何语义工作**——只是把值搬到栈顶好让下一条指令够得着。
2. **编号荒本身就是栈机的症状。** Hermes 只有 8 个类型化变体
   （算术 `AddN`/`SubN`/`MulN`/`DivN` + 跳转 `JLessN` 等四个），
   因为 `Add r,r,r` 本来就带着操作数，
   类型特化只需省掉检查、不需重新解决寻址。**我们估的 20–40 个 typed
   编号，很可能是在为「栈机里没法把操作数写进指令」重复付费。**

**同时修正了一条被冻结引用的结论**（详见 §6.4）：`~20.7 cyc/iter ≈
3 cyc/dispatch` 的三骨架实测，在 typed plan 三处被引为「dispatch 地板，
解释器轨不可动」。那个实验是同一程序过三种骨架——**它钉死的是「每次派发
多贵」，对「派发多少次」一个字没说**。`总开销 = 次数 × 单次成本`，只证到
底了后一个乘数。

**三个方案**：A（不动机器模型，做声明纪律+规范化）/ B（改纯寄存器机）/
C（混合，已有两份独立反证，不推荐）。**§1 的四项裁决已于 2026-08-27
（第三次）全部裁定**：生成器先行，生成器落地后复议 spike，回收清单维持
冻结。A/B 分叉本身尚未裁——它等证据。

**⚠️ 裁决后的一轮复审改了两件事，读 §2/§6 前必须先知道**（详见 §9）：

1. **编号荒作为方案 B 的动机基本消解。**需求侧的 45–65 从未被审计过；
   审计后约 **10–25**（FNABI 的 25 是签名矩阵组合填充，而「任意签名组合
   自动生成专用 opcode」是 FNABI 自己的**非目标 #11**，且每个新 handler
   族都要过在册的 I-cache 外部性硬门）。供给侧则是弹性的——§6.1 的 33 是
   保守值不是天花板，机制上限 100+。⇒ **方案 B 的立论从此只剩周期账。**
2. **周期账有一个比 spike 便宜一个数量级的仪器还没用**：tail-call 骨架让
   每个 opcode 都是独立函数符号，**一次 PMU 采样就能得到逐 handler 周期
   归因**，即方案 B 解释器收益的**一阶上界**（§9.5 E1）。而 §1.5 查出的
   **K4 准入条件正好要这个证据**。

---

## 1. 裁决记录（owner 裁定 2026-08-27 第三次，四项全部表态）

| # | 事项 | 裁定 |
|---|---|---|
| 1 | 单一声明源 + 生成器 | **批准**，排在裁决 2/3 表态之后开工。2/3 均已表态，故它是**下一件开工的事** |
| 2 | register-vs-stack spike | **缓议**：等裁决 1 的生成器落地后复议买不买。方案 B 保持可评估（未被裁决 3 封死） |
| 3 | qjs 代码级忠实对齐 | **降为工具**：qjs 仍是性能尺（bench-v8）与差分对拍参照，解释器核心不再要求逐行可对照 |
| 4 | 增量回收清单 | **(a) 全部继续暂停**，等重设计定案 |

执行次序由此确定：**声明源+生成器 → 复议裁决 2 →（若买且出数）方案
A/B 分叉裁决**。以下各小节保留裁决时的原始论证，逐项标注裁定。

### 裁决 1：是否照批「第一步」——单一声明源 + 生成器

**裁定：批准（次序在 2/3 表态之后；2/3 已表态，即为下一件开工的事）。**

**内容**：把指令集改成 JSC 那样「在一处声明、其余全部生成」（§3.3a）。

**建议：照批，且不必等裁决 2–3。**理由三条：

- **三个方案下都是净收益**：方案 A 需要它；方案 B 更需要（新指令集同样要
  声明，从零声明比改现有的六处手写容易得多）；方案 C 也需要。
- **它治的是正在流血的伤口**：我们每加一个 opcode 要在**六个地方**手写
  （id 常量、`opcode_info` 行、栈效应 switch、handler 表、若干扫描器名单、
  测试）。§5.2 第 3 条记录的缺陷类——降级 `put_super_value` 会让
  `super.x = v` 的函数**悄悄变得可内联，而且没有任何测试会变红**——就是
  这个的产物。这是已确认的真实机制，不是假设。
- **零风险**：不消耗编号预算，不改变任何语义，可完全在测试保护下增量做。

### 裁决 2：是否买「机器模型」的证据

**裁定：缓议——生成器落地后复议。方案 B 保持可评估。**

**内容**：一个受控的 register-vs-stack 派发 spike，预注册 policy，回答
唯一一个问题：**把槽位搬运折进操作数，在真实负载上能兑现多少周期？**

**最小形态**：取 2–3 个热函数（建议 raytrace / earley-boyer 的热循环），
手工把字节码改写成三地址形式，配一个只覆盖这几条指令的 register handler
集，A/B 测周期与指令数。

**为什么必须先买**：我们自己的帐本上，**手写 asm 省 16% 指令兑现 0.0%
时间**（同一张三骨架表里）。「约三分之一的**派发**减少」与「同比例的
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
> 保留条款里与本议题相关的是 **K3：QuickJS differential oracle（语义
> 正确性参照）不变**——而**机器模型改变不影响 K3**，差分 oracle 比的是
> 可观察行为，不是字节码形态。
>
> ⇒ **方案 B 不需要退役任何东西。**「降为工具」这条裁定是在复述一个
> 2026-08-24 就已生效的状态，而不是新开一个口子。

### 裁决 4：增量回收清单的处置

**裁定：(a) 全部继续暂停，等重设计定案。**

暂停中的剩余清单：`make_*_ref` 4→1（省 3）、TDZ 9→3（省 6）、13 个降级。

选项：(a) 继续全部暂停等重设计定案；(b) 允许其中**纯降级**的部分继续跑以
缓解编号压力（机制已验证、风险最低）；(c) 全部恢复。

**建议 (a)**，除非 FN-M1A 或 typed 在裁决 2 出数前就要开工。理由：方案 B
一旦成立，TDZ 那 ~70 处改动点白付；`make_*_ref` 的形态在寄存器机里完全
不同（§4.2）。

### 1.5 裁决后浮现的一条硬门：K4（四项裁定均未计入）

核对裁决 3 时顺带查出的。上述过渡记录的**保留条款 K4** 指向
`architecture.md` §8「Stack Bytecode VM Status」，其中有一条**仍然生效、
且正好管这次议题**的准入条件：

> Re-evaluate the bytecode architecture only when the semantic gates are
> stable, hot spots in call / property / array / string have been converged
> with qjs mechanisms, and **PMU evidence shows operand traffic / dispatch
> as the main bottleneck.**

同章 §1 还有一条现行立场：*"There is no evidence supporting a rewrite to a
register/accumulator VM"*。

**它不与任何一条裁定冲突，但它规定了裁决 2 复议时必须拿出什么：**

> **方案 B 不是一个可以直接裁的分叉，而是一次有明文准入条件的「重估」。
> K4 的第三条准入条件——「PMU 证据显示 operand traffic / dispatch 是主
> 瓶颈」——正是 §9 的 E1 要产出的东西。**

注意 K4 的措辞点名了 **operand traffic / dispatch** 两项，恰好就是寄存器机
攻击的两项。**这条门是为这个问题写的。**⇒ E1 不只是「更便宜的证据」，
它是**合规路径上的必经一步**，且它不建 A/B、只读现役引擎，因此不触碰
裁决 2 的「缓议」。

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

**zjs 是五者里最挤的**，而且挤得有原因——我们加了 QuickJS 没有的 22 个
融合指令。墙是真的并且已经在挡路：**T-spike 原型需要两个编号只拿到一个**，
所以属性**写**留在了通用路径上。

已知的未来需求——**⚠️ 下面这两个数字是需求方自报，从未被审计过；
§9.1 审计后它们塌了一半**：

- FNABI `CALL_NATIVE_*`：**约 25 个**（`fun-native-plugin-design.md:213`）
- typed 特化族 T1–T4：**20–40 个**（`type-directed-optimization-plan.md:527`）

**合计 45–65，供给 11。**——**修订见 §9.1：修剪后约 10–25，而供给是
弹性的（33 起步，机制上限 100+）。编号荒作为方案 B 的动机基本消解。**

### 2.2 动态执行账

剖析构建（`ZJS_PROFILE_ALL=1 zjs-profile --profile-opcodes`，该环境变量
解除了 profiler 的 40 行上限）跑 15 个 zoo 基准——richards、deltablue、
crypto、raytrace、navier-stokes、earley-boyer、regexp、splay、pdfjs、
typescript、box2d、code-load、gbemu、mandreel、zlib：

```
观测到的 opcode 执行总数:              41,888,384,774
终流 opcode:                            254
与短指令共享编号的 temp opcode:          19  (从不出现在终流)
至少执行过一次:                         156
从未执行:                                79
执行过但 < 0.0001%:                      23
=> 频次 <= 0.0001% 的冷池:              102
```

**按「是不是栈机专属开销」分类**（这是本文最重要的一张表）：

| 类别 | 编号数 | 执行次数 | 占全部动态指令 | 寄存器机里的对应物 |
|---|---:|---:|---:|---|
| **槽位搬运** `get/put/set_{loc,arg,var_ref}{0..3,8,宽}` | **48** | 140.6 亿 | **33.6%**〔另一口径 36.1%〕 | **消失**——变成指令的操作数字段 |
| **融合指令** `get_loc0_field`/`get_var_field`/… | 22 | 98.2 亿 | 23.45% | **不消失**，但变成自然形态而非手造特例 |
| **栈洗牌** `dup`/`swap`/`insert2,3`/`perm3,4`/`rot3l`/`nip*` | 9 | 1.29 亿 | 0.31% | 消失（只留一条 `mov`） |
| `drop` | 1 | 0.85 亿 | 0.20% | 消失 |
| 其余 | ~164 | 178.9 亿 | 42.71% | 大体一一对应 |

**编号侧**：**58 个编号**（槽位搬运 48 + 栈洗牌 9 + `drop` 1，占在用编号
的 24%）用于「因为是栈机才需要」的事。

**执行侧的诚实口径**：
- **真正会消失的是约三分之一**（槽位搬运 + 洗牌 + drop）：本表口径 **34.1%**，
  第二套采集口径复现得 **37.6%**。**方向与量级在两套口径下都成立，但不要
  引用到小数点后两位**——见附录 C 的采集口径说明。
- 融合的 **23.45% 不会消失**——`get_loc0_field` 在寄存器机里就是
  `GetNamedProperty rdst, r0, name`，同样一次派发。**不要把它算进收益。**

> **口径注（2026-08-27 复核修正）**：百分比是**采集口径依赖的**，两套
> harness 给出 34.1% 与 37.6%（附录 C）。以下修正的是另一件事——本表初版
> 写的是「66 编号 / 31.66%」，
> 两个数都不对。id 数错在把 24 个融合算进「会消失」的编号里（融合不消失），
> 同时**漏掉了整个 `set_*` 族**（`set_loc`×6、`set_arg`×5、`set_var_ref`×3
> 共 14 条）；百分比错在同一个 `set_*` 遗漏。现值由脚本从
> `src/bytecode.zig`（编号）与附录数据表（执行数）分别取，两侧不再混用。

### 2.3 融合指令逐条定价

我们比 QuickJS 多的 22 个全是融合指令，每一个都在挣钱，只有一个例外：

| 融合指令 | 执行次数 | 占比 |
|---|---:|---:|
| push_0_or | 3,768,876,208 | 9.00% |
| get_loc8_push_2 | 816,208,860 | 1.95% |
| put_loc8_get_loc8 | 600,756,243 | 1.43% |
| get_loc8_push_1 | 599,826,174 | 1.43% |
| push_2_sar | 470,159,471 | 1.12% |
| sar_get_array_el | 456,529,784 | 1.09% |
| push_0_shr | 395,847,723 | 0.95% |
| eq_if_false8 | 280,044,525 | 0.67% |
| cmp_if_false8 | 277,096,862 | 0.66% |
| get_loc0_field | 216,054,046 | 0.52% |
| push_this_put_loc0 | 108,967,999 | 0.26% |
| get_loc2_field | 74,268,031 | 0.18% |
| get_field2_call_method | 63,527,185 | 0.15% |
| get_var_field | 24,552,997 | 0.06% |
| get_loc2_field2 | 21,890,348 | 0.05% |
| get_field_field2 | 21,334,593 | 0.05% |
| **put_loc0_get_loc0** | **8** | **0.000%** |

`put_loc0_get_loc0` 就是我们的 `Ldr*`：一个编号、一个 handler、一份
I-cache 足迹，买到 419 亿次里的 8 次执行。

### 2.4 与 QuickJS 的差集

```
zjs = QuickJS(244) − 15 个已回收 + 22 个自加融合 = 251 → 现 245
```

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
| — | （冷平面） | 降级 | 111 | 2364/0 |
| M-1 | `with_*` 五个 | **合并** → `dyn_env_probe` | 114–117 | 2365/0 + test262 0/49778 |

`with_*` 合并的详情见 §5.1c。另有一次改名：`plus` → `to_number`（原因见
§8）。

---

## 3. 五引擎对照

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

### 3.1 机器模型 ← 最重要的一条

| 引擎 | 模型 | 二元加法的形态 | 出处 |
|---|---|---|---|
| **JSC** | 纯寄存器（三地址） | `add dst, lhs, rhs`，全部 `VirtualRegister` | `bytecode/BytecodeList.rb:1312` |
| **Hermes** | 纯寄存器（三地址） | `DEFINE_OPCODE_3(Add, Reg8, Reg8, Reg8)` | `BCGen/HBC/BytecodeList.def:210` |
| **V8 Ignition** | 累加器 + 寄存器文件 | 结果隐式进累加器；`Ldar`/`Star` 搬运 | `interpreter/bytecodes.h:87,110` |
| QuickJS | **栈机** | `get_loc a; get_loc b; add; put_loc c` | `quickjs-opcode.h` |
| **zjs** | **栈机**（继承自 QuickJS） | 同上 | `src/bytecode.zig` |

Hermes 的操作数直方图把这件事说得最清楚：180 条指令共
**446 个 `Reg8` 操作数**（220 条指令里），其次才是 `UInt8`(52)、`UInt32`(40)。
**它的指令绝大多数在寻址寄存器。**

三家里两家是**纯**寄存器机；V8 是混合，为了**编码密度**付 `Ldar`/`Star`
的派发。我们的问题是派发次数不是密度 ⇒ **纯寄存器模型才是对的参照，
不是 V8 的累加器模型。**

**这条事实的直接后果**：「借鉴 V8/JSC/Hermes 的 opcode 设计」这句话里有
一半对栈机根本不适用。**必须先把两半分开**，否则会把「他们不需要某类
指令」误读成「那类指令是冗余的」——附录 B 记录的两次机制判错（super 族
和类命名族）就是没先分这一刀。

### 3.2 我们的 frame 已经是一个寄存器文件

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
| **zjs** | **每个宽度一个手写编号，且不成体系** | `get_loc0/1/2/3` + `get_loc8` + `get_loc` 六个编号做同一件事的三种宽度；`put_loc`/`get_arg`/`put_arg`/`get_var_ref`/`put_var_ref` 各来一遍 = §2.2 那 32 个编号 |

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
| QuickJS / zjs | 66 个短 opcode（`push_0`、`get_loc0`…）+ 我们加的融合 |

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
| TDZ 检查变体 | 9 | **0** | 4 | 2 | 3 | 合并可省 **~6**，但成本最高 |
| Reference 具体化 | 6 | **0** | 0 | 0 | 0 | 合并可省 **3**（不是 6） |
| `with` 专用访问 | 5 | 120 | 0 | 0 | 0 | **已合并，省 4** ✅ |
| super | 4 | **0** | 1 | 0 | 0 | 靠**降级**拿 4（不是重设计） |
| 类定义/命名 | 6 | 1,662,159 | 0 | 1 | 4 | 靠**降级**拿 5（不是重设计） |
| 栈洗牌 | 9 | 128,992,268 | 0 | 0 | 0 | 5 个可降级；**不可重设计**（除非换机器模型） |
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

**真正的结构差异不是数量，是组合方式**：我们的 9 条是「检查 × 访问」的
笛卡尔积（3 种检查语义 × get/put/set 三种访问形式），它们的 2~4 条是
**纯检查**，对任何访问形式复用。

**对栈机要换一种分解方式**。寄存器机的 `ThrowIfHole <reg>` 直接读寄存器、
不动栈，所以「load + check + store」是自然的。我们是栈机，照抄会让写侧从
`put_loc_check idx`（3 字节）膨胀成 `get_loc; throw_if_uninit; drop;
put_loc`（4 条指令 10 字节）。适合栈机的形态是**不碰栈的原地检查**：

```
check_tdz_loc <idx>        // size 3, pop 0, push 0：局部槽为哨兵则抛
check_tdz_var_ref <idx>    // 闭包变量版
```

于是 `get_loc_check idx` → `check_tdz_loc idx; get_loc idx`（2 条 6 字节），
扩张是 3→6 字节而不是 3→10。

**成本**：三个成本因子全中——3 个走尺寸预言机路径、`put_loc_check_init`
有 15 处测试引用、`set_loc_uninitialized` 有 14 处，合计**约 70 个改动点**，
且动的是 `let`/`const` 的正确性基础。

### 4.2 Reference 具体化（6 个编号，0 次执行）

`make_loc_ref`、`make_arg_ref`、`make_var_ref`、`make_var_ref_ref`、
`get_ref_value`、`put_ref_value`。

三家确实一个都没有，但**「所以我们能省 6 个」是错的**。读实现
（`parser.zig:4879` `needs_reference`、`bytecode.zig:6640-6710`
`scope_make_ref` 的下降）后的事实：这一族只在**静态解析不出的作用域
变量**上触发——`with` 块和直接 `eval` 里的复合赋值/自增。规范要求引用
只求值一次，所以必须把「已解析到的基址」保存下来。

**寄存器机把它留在寄存器里；我们是栈机、只能把 (scope, name) 对压到栈上
——`make_*_ref` 做的正是这件事。它不是一个可以删掉的多余概念，而是同一
件事在栈机上的形态。**

可省的是**变体数**：四个 `make_*_ref` 只在「引用的是 arg / local /
var_ref / var_ref_ref 哪一种槽」上不同，是「flag 操作数吃掉变体」的标准
场景。**4 → 1，净省 3。**

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

⇒ 这一族能拿到 4 个编号，但**靠降级**（全部 0 次执行）。

### 4.5 类定义/命名（6 个编号）——**同样是降级**

`set_name` 独占 166 万次（**保留**），其余五个 0~39 次。

「改 flag 操作数」在 V8 成立，因为它有一条通用 `DefineKeyedOwn` 可以挂
flag；**我们的 `define_class`/`define_method` 语义并不重合于某条通用指令，
硬合并要先造出那条通用指令。** ⇒ 5 个靠降级。

### 4.6 栈洗牌（9 个编号，0.31%）

`dup`(8964 万)、`insert3`(3514 万)、`insert2`(255 万)、`perm3`(166 万)
**保留**；`nip`、`perm4`、`swap`、`rot3l`（均 0 次）、`nip_catch`(43 次)
**可降级**。

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
`new X()` 加一个二级分支——**正是 typed OO 负载的形状**。其余 20 个自由。

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

**冷池总量**：84 个编号可降级（全部 ≤ 0.003%）。**一个平面 id 带 256 个
子槽**，所以把 84 个 opcode 降到一个 id 后面净赚 **83 个编号**。机制上
没有理由畏首畏尾；成本是每个 opcode 的工程量加一次那些 opcode 永远不会
察觉的二级分支。

---

## 5. 三种改造机制及其实测成本

### 5.1 三种机制

#### (a) 退役（delete/merge away）

彻底删掉。零运行时成本，V8 报告**可能改善 I-cache**。

**前提是编译器再也发不出它。**这个判定**只能靠读，不能靠 grep**：字面
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

#### (b) 降级到冷平面（cold but live）

编号释放，但指令长一个字节、handler 多一次间接。**对冷 opcode 是对的，
对热 opcode 是错的**（§3.4a 的成本画像）。

**载体**：zjs 已有 `using`（id 244，fmt `.u8`，size 2），子表 `using_sub` 现
装载 **16 个**降级来的 opcode（子槽 3–18）。两个事实让它成为正确的载体：

- `pipeline_stack_size` **已经**处理「栈效应取决于子字节」的载体
  （`if (op == opcode.op.using)` → `using_sub.stackPop/stackPush`）。
  那是引擎里唯一一处按 opcode id 读 n_pop/n_push 的地方，所以不需要新机制。
- `using_ops.execVm` 已经在冷壳里按子字节 switch，而**每个降级目标今天都
  只有冷壳**——没有一个要放弃常驻快 handler。

`add_base` 已从 16 抬到 64，开出子槽 15..63（49 个空位）。子编码是单次
编译内部的事，**不是 artifact 格式变更**。

**⚠️ 载体约束**：一个载体只能吸收 `(size, fmt)` 相同的 opcode，因为
`Info.size` 必须保持纯表查（每个解码器、atom 扫描器、验证器、反汇编器都
依赖这一点）。栈效应**不**构成约束，因为有上面那张子表。

**两步法**（中间可验）：

```
步骤 A — 停止发射（编号仍占用）
  1. 给 using_sub 加 pub const <op>: u8 = <空闲子槽>
  2. 加 stackPop / stackPush 臂，从该 opcode 的 opcode_info 行抄 n_pop/n_push
  3. 加 using_ops.execVm 的 switch 臂，调用冷 handler 原来调的同一个函数
  4. 改写发射点：Emitter.op(s, op.X) → Emitter.opU8(s, op.using, using_sub.X)
  5. zig build test —— 任何钉住旧编码的测试在这里失败，且失败会自报家门

步骤 B — 释放编号
  6. 从 op 里删掉 pub const X: u8 = N;
  7. 把 opcode_info 行改名 unused_N（size 1, pop 0, push 0, fmt none）
     —— 行必须保留，否则表索引会移位
  8. 删掉 t[op.X] 冷表条目
  9. zig build test
```

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
对象）与 QuickJS 输出逐字符相同。

### 5.2 三条成本因子（改造前必查）

**成本不由频次决定，由「这条 opcode 被测试和工具钉得多紧」决定。**

**(1) 经过预计算尺寸的写入器。** 私有字段族（`get_private_field`、
`put_private_field`、`define_private_field`、`private_in`）不走
`Emitter.op`，而是走 `rules.writeLoweredPrivateField`，其调用方用
`rules.loweredPrivateFieldSize` **预先算好字节长度**。改它们意味着编码
和尺寸预言机要同时改——**这正是静默 off-by-one 藏身的地方**。

**(2) 被字节偏移断言钉死。** `compiler.s2g4` 测试把发射流钉到 `code_len`、
`expectLabel` 目标、`code[22..24]` 切片和 `last_opcode_pos`。
`check_ctor`、`init_ctor`、`add_brand` 位于构造器流的头部，降级它们会让
后面每个偏移移位一格，需要约 36 处协调的数值更新。**用算术 +1 批量改是
典型的盲目机械编辑，会静默削弱一个 QuickJS 忠实性测试**——必须从实际
发射的字节重算 pin，并逐条审阅 diff。

**(3) 按 opcode 身份匹配的扫描器。← 最隐蔽，因为它不会让测试变红**

`bytecode.zig` 的 `scanSmallInlineEligible` 走一遍字节码，**按 opcode
身份**拒绝含某些指令的函数参与小函数内联，`put_super_value` 在那张拒绝
表里。一旦它被降级成 `{using, sub}`，身份匹配就看不见它了——含
`super.x = v` 的函数会**悄悄变得可内联**，而这不是任何人想要的语义变化，
**也不会有测试报错**（行为差异只在优化覆盖面上）。

> **规则：把一条 opcode 降级进冷平面，会让每一个按 opcode 身份做模式匹配
> 的扫描器失明，除非同步教会它看子字节。**

修法是给载体 opcode 加一个分支去查 `code[pc + 1]`，**而不是把整个载体
加进拒绝表**——后者会顺带把含无害栈洗牌（已在平面里的 16 个）的函数一起
排除掉。

### 5.3 已验证的波次排序

按**测试耦合度**排，不按频次：

| 波次 | 选择规则 | 例子 |
|---|---|---|
| 1' | 走普通 `Emitter.op`，且不出现在任何被钉死的流里 | `set_proto`、`check_brand` |
| 2' | 被钉死的流里的 opcode，pin 从实际发射字节重算 | `check_ctor`、`init_ctor`、`add_brand`、`set_home_object`、`get_super*` |
| 3' | 走尺寸预言机的 opcode | 私有字段族 |

已释放 9 个（42、16、76、72、111 靠降级，114–117 靠合并），**每一步套件
全绿**。「84 个编号是冷的」这个判断仍然成立，但**每个编号的成本不均匀**。

---

## 6. 三个方案

### 6.1 方案 A：机器模型不变，做声明纪律 + 系统化规范化

内容 = §3.3（a)(b)(c) 三条 + §5 剩下的回收清单。

**编号账要算清楚**：
- 已核对的回收清单：`make_*_ref` 省 3 + TDZ 省 6 + 降级 13 = **22 个**。
  245 − 22 = **223 在用 / 33 空闲**。
- **⚠️ 初稿在这里犯了一个错**：它说「这 33 个够不上 45–65」，把 33 当成
  方案 A 的**上限**。但 §4.7 自己算过：冷池 84 个全降级净赚 **83**。
  **33 是「已逐条核对过的保守值」，不是天花板。方案 A 的供给是弹性的
  ——33 起步，机制上限 100+。**配上 §9.1 修剪后的需求（10–25），装得下。
- 若真要动槽位搬运族那 32 个编号，代价是实的：`get_loc0..3` 之所以存在，
  是因为操作数已经融进 opcode，取指时不必再读一个字节（QuickJS
  `OP_get_loc0..3` 的原意）。折成「一条 `get_loc` + 自动宽度」会丢掉这层
  密度与取指优化。**但按修订后的账，方案 A 不必走到这一步。**
- 但会彻底消除「身份匹配扫描器」缺陷类；后续每加一个 opcode 的成本从六处
  手写降到一处声明。

**不改变的**：动态指令数不变，派发次数不变，那约三分之一的纯搬运指令还在。

**风险**：编号仍然紧张，typed 家族一旦超出估计就再次触顶；24 条融合指令
作为「模拟寄存器寻址」的债务保留。

**规模**：以已落地的两次为标尺（降级 5 个 / 合并 4 个），外加一个生成器。
**中等，可增量交付，每步可验。**

### 6.2 方案 B：改成纯寄存器机（对齐 JSC/Hermes）

**收益**：
- 消掉**约三分之一**的动态派发（34.1% / 37.6%，两套采集口径；见 §6.4 的重要限定）。
- 释放约 **66** 个编号；typed 变体退化成 Hermes 那种「同布局兄弟指令」，
  需求从 20–40 降到个位数。
- 消掉 24 条融合指令这笔债（与 V8 删 `Ldr*` 的结论一致）。
- **消掉每次槽位读的引用计数对**（§9.3）。这一项初稿完全漏了，而且它
  **不受「指令幻影定律」保护**——RC 是带依赖链的内存写，不是能被乱序核
  吸收的臂内算术。

**代价**：
- **编译器的操作数分配要从栈纪律改为槽位分配——全案最大的一块。**
- `src/exec/` 的 **481 处** `stack.pop/push/peek` 调用点。
- `src/parser.zig` 的 **331 处**发射点。
- **6721 行**的热派发文件重写。
- 22–24 条融合指令全部作废重来。
- **异常路径要重做**（§9.3）：栈机 throw 时按已知栈深退栈即可；寄存器机
  + RC 需要活跃槽位图（或保守扫描）才能正确释放。这是真实工程量，初稿
  的代价清单漏了。

⚠️ **收益必须先定价，不能假设**（§6.4）。

### 6.3 方案 C：混合——热指令带寄存器操作数

即「每条二元运算都可以直接读槽位」，本质是**一次一条地变成寄存器机**。

**已有两份独立反证**：
1. V8 加了 5 条 `Ldr*` 融合，半年后全删（`f633218b624`）。
2. 我们自己的 24 条融合里，`put_loc0_get_loc0` 在 419 亿次执行中跑了 **8 次**。

方案 C 就是我们过去两年一直在做的事。它能拿到局部收益（融合族确实占
22.25% 的执行），但它**按 opcode 逐条付编号**，正好撞上 §2.1 的编号荒，
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
「指令幻影定律」在派发骨架这一层的实例。所以**那约三分之一的派发减少绝不能
直接换算成同比例的周期减少**。区别在于：asm 省掉的是**臂内**指令（被乱序
核吸收），方案 B 省掉的是**整条指令连同它的间接跳转、栈读写和引用计数**。
两者是否同命，**只能测**（裁决 2）。

---

## 7. 冲突与约束

方案 B 与下列已生效的东西**直接冲突**，不能默默推进：

1. **「qjs 代码级忠实对齐」——冲突已解除**：裁决 3（2026-08-27）已将其
   降为工具，qjs 仍是性能尺，逐行对照不再约束解释器核心。（裁前这是
   最重的一项。）
2. **22–24 条融合指令**：方案 B 下是纯负债，且它们是过去多轮性能战役
   （EB / RayTrace / pdfjs 线）的产物。
3. **typed plan 的 T1**（typed interpreter slots）在寄存器机里形态不同；
   PERF-T-SPIKE 的原型（op254/255 guarded direct-slot）也是按栈机形态搭的。
4. **SER-ARTIFACT** 的字节码版本化（已加为它的硬前置）。
5. **FN-M1A** 需要的 ~25 个 `CALL_NATIVE_*` 编号：方案 B 下这些指令的形态
   要重新设计（三地址调用约定）。
6. **表示契约**：`JSValue` 的 16 字节承诺不受影响（寄存器文件存的还是
   `JSValue`），但**帧内 unboxing** 的推迟条款需要在寄存器语境下复核。
7. **`call_constructor` 在任何波次里都排除**（§4.7 限定一）。
8. **Tier C 名单永不降级**（§4.7 限定四）。
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
| `make_var_ref_ref` | 两个 ref 叠词 | 随 4→1 合并一起消失 |

---

## 9. 复审补入（2026-08-27，四个实质缺口 + 证据阶梯）

裁决记录（§1）成文后的一轮复审，指出本文有一个**结构性盲区**：
**供给侧 251 个 opcode 逐条定价，需求侧的 45–65 却照单全收、从未审计。**
外加两个就在自家代码里、会实质改变方案 B 定价的事实。下列各条均已回源
核对。

### 9.1 需求侧审计：45–65 → 约 10–25

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

**typed 的 20–40**：本文 §0 第 2 条已经论证这是栈机笛卡尔积税（Hermes 只
有 4 个类型化变体，因为 `Add r,r,r` 本就带操作数），**却仍把 20–40 原样
记在需求侧**。按本文自己的逻辑修剪，这个数在方案 A 下也应显著下降。

**两头修剪后：需求约 10–25，不是 45–65。**结合 §6.1 修订后的弹性供给
（33 起步，上限 100+），**编号荒作为方案 B 的动机基本消解**。

> **这不等于方案 B 死了，而是说：方案 B 的立论从此只剩周期账。**
> 编号账撑不起它，K4（§1.5）要的也正是周期证据。

### 9.2 FNABI 已经是一座三地址孤岛

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

### 9.3 引用计数：收益与成本两侧都漏了

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

### 9.4 GC 线与本裁决有一条未定价的耦合

方案 B 在 **tracing GC 下比在 RC 下便宜得多**：无 RC 对、退栈平凡、槽覆写
就是一次写加屏障。而 **G2-GC-MERGE 正在并行推进**。

⇒ **分叉裁决应把目标 GC 模型列为显式输入。**理想时序是等 GC 合入判决出来
再裁分叉，否则 E2 要为两个世界各测一遍。

### 9.5 证据阶梯：E1 / E1.5 / E2

本文原来只设计了一个仪器（手工改写 spike）。但假设可以**分解定价**：

```
每条被消灭的搬运指令的成本 = 派发（~3 cyc，三骨架已钉死）
                          + 栈往返（store + load）
                          + RC 对（堆值，§9.3）
```

#### E1（几乎免费，先做）——逐 handler 周期归因

**tail-call 派发让每个 opcode 都有独立的 handler 函数**：`callconv(.c)`、
`align(16)`（部分 `align(64)`）、`linksection(op_handler_section)`
（`src/exec/tailcall_dispatch.zig:5,314,364`）。在 zoo 套件上跑一次 PMU
采样，**per-handler 周期归因就是现成的逐 opcode 周期账**。

> **⚠️ 但「按符号名归因」这条路已实测走不通，方法已改（2026-08-27 验证）。**
> 详见 §9.5.1——初稿写的方法会在最要紧的那一块上失效。

43 个搬运/洗牌/drop handler 的周期占比 = **方案 B 解释器收益的一阶上界**。
**上界小，方案 B 以一次剖析的价格死掉；上界大，才轮到买 E2。**

- **它不违反裁决 2 的「缓议」**——不搭 A/B，只是读现役引擎。
- **它正是 K4 第三条准入条件要的东西**（§1.5）。

⚠️ **本项目在符号级归因上有前科，必须按既有纪律做**：「perf 符号合并不可
信，须自己映射 IP」「SPE 占比不可靠，只信 addr2line」「共享冷体符号归因
必须配出线口计数器或 IP→addr2line」。**热 handler 是独立非内联函数、
带对齐 pin、在专用 section，是这条纪律下最有利的情形；但冷壳 handler
共享函数体**（`tailcall_dispatch_colds.zig` 经 `linksection` 包装器落段），
**必须单独处理，不能混进同一张归因表。**

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

⚠️ 实做限定：`JSValue` 是 16 字节 = **两个 GPR**（§7.2 固定寄存器约定、
`:600`）。handler 现签名已有 4 参（pc, sp, var_buf, vm），加一档 TOS 变
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

- **SER-ARTIFACT**：它是 **build cache**（registry `acceptance:` 写明
  "feeds Build Cache"，authority = hot-reload 设计 §27.10），要的**不是
  ISA 稳定而是失效检测**。生成器的声明表可以 comptime 派生 **ISA 指纹**
  （`src/config_signature.zig` 的 `attest()` 机制已在，配置签名先例现成），
  拿它做版本键后，SER-ARTIFACT 的硬前置可以从「重设计定案」降为
  **「声明表落地」**。
- **FN-M1A**：按 §9.1，它只需 **2–3 个**签名变体，**现有 11 个空闲编号
  装得下**，不碰暂停中的回收清单（裁决 4 的冻结不受影响）。若产品线等
  不起，**这是合规的先行通道。**

---

## 10. 声明源与生成器的设计（裁决 1，下一件开工的事）

§9.6 只给了三条要求，没有设计。本节补上。

### 10.1 目标与非目标

**目标**：把「一条 opcode 的定义」从**六处手写**收敛成**一处声明**，其余
全部 comptime 派生。六处是：`op` 常量、`opcode_info` 行、栈效应特例
switch、handler 表接线、若干扫描器名单、测试。

**非目标（明确不做）**：
- **不做外部代码生成**。JSC 用 Ruby 生成 C++，那是它的语言环境决定的。
  我们有 comptime，用它就没有构建步骤、没有生成文件漂移、没有「改了
  .rb 忘了重跑」这类故障。`engine-evolution-plan.md` §3.3 把手写 `.S`
  定为需 owner 认可的显式例外，外部 codegen 同理。
- **不自动分配 id**。id 必须在声明里显式写死——测试 pin 和 artifact 稳定
  都依赖它，自动分配会让插入一条新指令悄悄移动所有后续编号。
- **本阶段不改任何编码、不改任何语义。**（见 §10.5 阶段 1 的等价断言。）

### 10.2 提前验证的结果：声明表必须表达三件事（2026-08-27 实测）

设计初稿写完后对全表做了机械核对，挖出三个初稿没覆盖的编码形态。**这三条
不是推测，是脚本跑出来的**——每一条都会在实现时变成 bug。

#### (a) 22% 的指令把操作数烧在 opcode id 里

对 244 条终流指令做 `size == 1 + Σ operand.width` 核对：
**244 条中 20 条不成立**，而且不成立得完全成系统：

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

⇒ **`Operand` 必须支持 `width = 0` 且 `value = id − base` 的编码。**没有它，
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

### 10.3 声明的形状

```zig
const Decl = struct {
    name: []const u8,
    id: u8,                       // 显式，永不自动分配
    phase: Phase = .final,        // final | temp（178..196 相位复用区）
    operands: []const Operand,    // ← size 与 fmt 由它派生，不再手写
    stack: StackEffect,
    handler: HandlerBinding,
    traits: Traits = .{},
    /// §10.2b：融合指令只占自己 1 个字节，尾跳进后一条指令的 handler。
    /// 声明它是为了让生成器能绑定热/冷两个形态并保住「两条之间可停」。
    fusion: ?struct { prefix_of: u8, cold_does_first_half: bool } = null,
    metadata: ?MetadataShape = null,   // 预留给 PERF-SIDECAR
};

const Operand = struct {
    kind: Kind,
    /// ⚠️ 与 kind 正交（§10.2a 实测）：`loc8` 是 local/1B，`loc` 是 local/2B。
    /// `.burned_in` = 0 字节，值 = id − base，覆盖 53 条指令（22%）。
    width: Width,                 // burned_in | u8 | u16 | u32 | i8 | i16 | i32
    flow: Flow = .read,           // read | write | read_write  ← 抄 V8

    const Kind = enum {
        // 与机器模型无关的
        atom, constant, label, imm, count, flags, sub_opcode,
        // 槽位寻址：一等公民（FNABI 横竖需要，§9.2）
        local_slot, arg_slot, var_ref_slot,
        // 若分叉裁向方案 B，这里加 register / register_out，
        // 换的是声明内容，不是声明机器
    };
};

const StackEffect = union(enum) {
    fixed: struct { pop: u8, push: u8 },
    /// 效应写在某个操作数字节里（`using` 冷平面、`dyn_env_probe` 已在用）
    from_operand: struct { byte_index: u8, decode: *const fn (u8) ?struct { pop: u8, push: u8 } },
};
```

**三点说明**：

1. **`flow` 抄 V8**（`Reg` / `RegOut` / `RegInOut`，`bytecode-operands.h`）。
   有了它，每条指令的读写集是**派生的**，不必另写一张表——这对将来的
   JIT lowering 和 typed 分析都是白拿的。
2. **`local_slot` / `arg_slot` / `var_ref_slot` 是一等操作数种类**，不是
   「u16 而已」。FNABI 的三地址调用（§9.2）横竖要它；而它一旦存在，
   方案 B 的 ISA 就能用**同一个声明机器**表达出来。
3. **`metadata` 槽预留但不实现**。JSC 把内联缓存/profile 做成指令声明的
   一部分（49 条带 `metadata:`），这正是 PERF-SIDECAR 要建的东西。现在
   只留字段，不建机制。

### 10.4 派生什么，以及 comptime 断言什么

**派生（comptime，零运行时成本）**：

| 产物 | 来源 |
|---|---|
| `op.<name>` 常量 | `id` |
| `opcode_info[id]` 的 `size` | `1 + Σ operand.width` |
| `opcode_info[id]` 的 `fmt` | 操作数序列的形状 |
| `opcode_info[id]` 的 `n_pop` / `n_push` | `stack.fixed`（`from_operand` 的行填默认值） |
| `computeStackSize` 的操作数取值分支 | `stack.from_operand` 的声明集合 |
| 冷/热 handler 表接线 | `handler` |
| **扫描器集合**（`inline_forbidden` 等） | `traits` → comptime bitset |
| 反汇编器的操作数打印 | `operands` |
| 带 atom / 带 label 的指令集合 | `operands` 里出现 `.atom` / `.label` |
| **ISA 指纹**（供 SER-ARTIFACT，§9.7） | 整张表的 comptime 哈希 |

**comptime 断言（写错就编译不过）**：

```
1. id 唯一（final 相位内）
2. 相位不相交：temp 与 short 只在 178..196 重叠，且同 id 不能同相位
3. 表密度：0..255 每个 id 要么有声明，要么显式列在 unused 名单里
4. size 自洽：声明的 size == 1 + Σ operand.width
5. handler 存在：声明绑定的 handler 符号真的存在
6. 载体子槽唯一（`using_sub` 及未来的其他载体）
7. from_operand 的 byte_index 落在该指令的操作数范围内
8. 布局相等（抄 Hermes 的 ASSERT_EQUAL_LAYOUT）：
   声明为「同布局兄弟」的两条指令，操作数序列逐字段相同
```

第 8 条现在就有用：`dyn_env_probe` 与将来 `make_*_ref` 合并后的形态是
同一类；typed 变体（若走方案 A）也需要它。

### 10.5 迁移路径：五个阶段，每步套件必须绿

**关键安全性质在阶段 1**：先让声明表**只**派生 `opcode_info`，并 comptime
断言它与现有手写表**逐字段相同**。这一步零行为改变，而那条断言就是
「声明写对了」的证明。**不先做这一步就改别的，等于用没验证过的表去替换
验证过的表。**

| 阶段 | 内容 | 验收 |
|---|---|---|
| **1** | 加声明表，派生 `opcode_info`，**comptime 断言 == 现有手写表** | 编译通过即证明忠实；`zig build test` 绿 |
| **2** | 派生 `op.<name>` 常量，删手写常量 | 套件绿 |
| **3** | **派生扫描器集合**（`traits` → bitset），改写 `scanSmallInlineEligible` / `isForwardForbiddenOp` 等消费它 | 套件绿 + test262 |
| **4** | 派生 handler 表接线与 `computeStackSize` 的操作数分支 | 套件绿 + test262 |
| **5** | 删掉手写 `opcode_info` 与阶段 1 的等价断言 | 套件绿 + test262 |

**阶段 3 是最有价值的一步**，因为它结构性地消灭了 §5.2(3) 的缺陷类：
`inline_forbidden` 成为声明字段后，**降级或合并一条 opcode 时不可能忘记
更新扫描器**——扫描器消费的是从声明派生的集合，不是一张人手维护的名单。
那个「降级 `put_super_value` 会让 `super.x = v` 悄悄变可内联、且无测试
变红」的缺陷，在阶段 3 之后无法再发生。

**阶段 4 的一条限定**：热 handler 岛的对齐 pin 与 `linksection` 必须保持
逐字节不变——它是 §9.5 E1 的前提，也是既有的 I-cache 调优成果。接线可以
生成，**布局不能动**。这一步要配一次 `objdump` 对照。

### 10.6 与三个方案的关系

- **方案 A**：声明源是它的主要交付物之一，剩下的回收清单在它之上执行会
  便宜得多（每条 opcode 的改动从六处降到一处）。
- **方案 B**：新 ISA 同样要声明。**从零声明比改现有的六处手写容易**，而且
  §10.2 的 `Operand.Kind` 已经为寄存器种类留了位置——换的是声明内容，
  不是声明机器。
- **方案 C**：也需要它（每个融合变体都是一条声明）。

⇒ **它是三个方案的公共前缀，这就是它可以先于分叉裁决开工的理由。**

### 10.7 顺带解锁 SER-ARTIFACT

声明表的 comptime 哈希 = **ISA 指纹**。`src/config_signature.zig` 的
`attest()` 已有配置签名的先例，机制现成。

SER-ARTIFACT 是 **build cache**（registry `acceptance` 写明 "feeds Build
Cache"），**要的是失效检测而不是 ISA 稳定**——拿 ISA 指纹做版本键，指令集
变了缓存自然失效、重建即可。⇒ 它的硬前置可以从「重设计定案」降为
**「声明表落地」**，即阶段 1 完成即可解锁。

---

## 附录 A：源码坐标索引

> 四引擎的**完整**设计记录与更细的坐标在
> [`opcode-engines.md`](opcode-engines.md)；下表只列本文正文引用到的。

**zjs**

| 事实 | 坐标 |
|---|---|
| opcode 表（id / size / n_pop / n_push / fmt） | `src/bytecode.zig` `opcode_info` |
| 相位复用区 | `src/bytecode.zig` `op_temp_start = 178`, `op_temp_count = 19` |
| 冷平面载体与子表 | `src/bytecode.zig` `using_sub`（`add_base` 16→64） |
| 唯一按 id 读栈效应处 | `src/bytecode.zig` `pipeline_stack_size`（`using` / `dyn_env_probe` 两个分支） |
| 按身份匹配的扫描器 | `src/bytecode.zig` `scanSmallInlineEligible`；`src/exec/small_inline.zig` `isForwardForbiddenOp` |
| 尺寸预言机路径 | `rules.loweredPrivateFieldSize` / `rules.writeLoweredPrivateField` |
| 字节偏移 pin | `compiler.s2g4` 测试 |
| Reference 族触发条件 | `src/parser.zig:4879` `needs_reference`；`src/bytecode.zig:6640-6710` |
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
| 指令定义 | `include/hermes/BCGen/HBC/BytecodeList.def`（180 条 `DEFINE_OPCODE_n`） |
| 三地址 `Add` | `:210`；`AddN` `:213` |
| `Mov`/`MovLong` | `:168` / `:171` |
| 操作数直方图 | Reg8 376 / UInt8 52 / UInt32 40 / UInt16 29 / Addr32 5 / Reg32 2 |
| 布局相等断言（15 对） | `ASSERT_EQUAL_LAYOUT{1,2,3,4}` |
| Long 变体（18 个） | `*Long` 后缀 |
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
| 419 亿次执行、逐 opcode 频次 | 附录数据表（15 zoo 基准，`ZJS_PROFILE_ALL=1`） |
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

机制本身是对的（子常量、栈臂、冷壳子臂、发射点改写全部编译并运行），但
撞上成本因子 (1)(2)（§5.2）。**我用算术 +1 批量改字节偏移 pin，破坏了
`readInt` 断言。**回滚到单条试点。教训已写进 §5.3 的波次排序规则。

### B.5 前缀/wide 平面曾是本工作项的主方案

roadmap 原文把 PERF-OPCODE-SPACE 描述为「wide/prefix planes」。读源码后
退出范围：**V8 和 JSC 的前缀机制根本不扩展 opcode 编号，只扩展操作数
宽度**（§3.5）。买不到一个新编号，还要付第二次间接跳转和 handler 三倍化。

---

## 附录 C：逐 opcode 数据表，以及它的采集口径

见 [`opcode-audit-table.md`](opcode-audit-table.md)——247 条有读数的
opcode，每行含 id / 名字 / size / fmt / n_pop-n_push / 执行次数 / 占比 /
发射方式 / 处置。

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
