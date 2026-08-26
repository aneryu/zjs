# zjs 类型导向优化方案（TypeScript type lint 静态轴）

Version: 0.9（P2 eval 缓存 Octane ROI 证伪,降级 incubator）
Date: 2026-08-26
Status: DRAFT — 待 owner 评审

Review note（0.8 → 0.9）：**P2 eval CompilationCache 的 Octane 收益
断言被基准源码证伪**——`tools/perf/bench_v8/suite/code-load.js:1510-1524`
的 `cacheBust()` 每次迭代 `salt++` 并用 salt 派生 hash 全局重命名
`goog`/`jQuery` 标识符,**每次 eval 的源串都不同**(Octane 作者特意
设计以击败编译缓存);源码键控缓存在 CodeLoad 上命中率恒 0,
"V8 2.37x 主体=缓存命中"归因不成立(真实来源=惰性解析/preparse/
扫描器)。zlib 的 eval 每套件仅初始化一次,收益边际。**P2 处置:
Octane 预期归零、"全案最高 ROI"撤销、转入 incubator——仅当 fun
真实负载证明重复源码率、预计命中率与编译时间占比达到立项线后,
重新进入 roadmap。**"T5 对冲"逻辑(TS 解析让编译变贵)保留为
incubator 的立项理由之一。ROI 首位移交 T-spike/N-spike。正文
§三/§8 中 P2 各表述以本 note 为准,下方原文保留并加标注。
其余 0.9 修订同批登记于 process-model-design.md §20.2a(L1 seal、
多态臂、u64 identity、侧车解耦),待下轮正文修订吸收。

Review note（0.7 → 0.8）：**owner 定向（2026-08-25）："AOT 不如
直接 native 化"——原生 AOT 升为主线**，v0.7 的"字节码 AOT 先行"
解读作废（对同日早前表述的误读，两条合读的本意 = 字节码 AOT 达
不到 native 效果）。§5.1 重构：主线 = **TS → typed bytecode（IR/
兜底）→ Zig 源码发射 → 交 zig 编译器 → 静态链接进 fun 应用**；
v0.7 新增的离线字节码优化管线（15-25 人日）**取消**——内联/寄存
器分配/未装箱 FP 由 LLVM 在发射源码上代劳；字节码 AOT 降级为
轻量子项（动态加载模块的预编译容器 + dev 模式兜底）。spike 阶段
增加 **N-spike 原生臂**（手写目标形态 Zig + 链 zjs runtime 实测），
主线量级用实测定。§8 ROI 与执行序列同步重排。

Review note（0.6 → 0.7，已被 0.8 部分作废）：曾按"字节码 AOT
先行"重构 §5.1 并引入离线优化管线；该结构保留在版本历史中，
若原生路线受阻可回退参照。

Review note（0.5 → 0.6）：基于本地 Hermes 源码（2026 main，含完整
Static Hermes）的两轮深挖，新增 §10 设计对账与计划补全：T1 获直接
先例（SH `GetOwnBySlotIdx` 字节码 + 预建单态 HiddenClass + 冻结防
untyped 写，与本方案同构）；发现 SH 两个已自认的健全性缺口（typed
函数入口不检查、checked cast 只到 tag 粒度）——zjs 的 L0 层与
shape-identity guard 是差异化优势；S6 AOT 新增 C/Zig 源码发射备选
路线（SH 实证，成本远低于 MacroAssembler）；GC 协作/异常/调用约定
三个 S6 设计决策点入文；fun 模块格式（开放问题 5）获 HBC 设计
清单实质化；T1 put 侧新增 nonPointer 免写屏障位（tracing GC 协同）。

Review note（0.4 → 0.5）：**owner 确认 AOT 为未来方向（2026-08-25）**，
新增 §5.1 AOT 展望：typed bytecode（T1-T4）= AOT 后端的输入 IR，
Phase 2 baseline emitter 离线运行即 AOT 编译器；iOS "解释器即上限"
的天花板由 typed AOT 突破。连带修订：T-spike 杀标波及范围收窄
（spike 只裁决解释器级特化；F3/F5 类型摄入基建由 AOT 方向独立
支撑）；§8 ROI 决策要点与执行序列（增 S6）同步更新；帧内/寄存器
unboxing 与"堆字段 unboxing 推迟"条款的边界精确化。

Review note（0.3 → 0.4）：新增 §8 效果预估与 ROI（份额法三档口径、
跨引擎锚点封顶、成本人日粗估、ROI 排序与决策要点）；原 §8 开放
问题顺延为 §9。

Review note（0.2 → 0.3，可落地性/效果真实性对抗审查）：**新增
§1.5 与 2026-08-17 IC 否证实验的对账**（本仓库曾实测否决位点
side-cache IC——静态槽位与它的本质区别 = 常量入操作数、热路径零
侧表装载，"旁挂缓存 miss 税"不适用；但该否证留下的纪律具约束力：
一切纸面收益必须按实测快臂单价折算）；**修复 proto-slot 健全性
bug**（单 receiver guard 挡不住 holder 形状变异致槽位漂移——L0 改
双 guard，L1/L2 改原型 auto-seal + 单 guard）；**新增预期效果与
置信度表**（明说：静态轴对 untyped 负载收益=0；T2/T3/T4 按
"常数 insn 税被 OoO 吸收"先例降级）；**新增 T-spike 强制验证门**
（S2 内 2-3 天垂直原型，未过杀标即改道）；**F2 依赖修正**（typed
站点运行时不消费侧表，静态轴与 Phase 0.5 交付解耦）。

Review note（0.1 → 0.2，自审）：修补一处健全性漏洞（§T1：免 guard
范围收窄到 own-slot——导出类的原型对 untyped 世界可达，proto-slot
读在 L1/L2 下仍须 guard，直到 Phase 3 dependency registry）；shape
身份改为 identity==version 单字段设计（guard 降至 1 load + 1 cmp）；
限定可擦除语法子集；新增类型→特化映射规则、opcode 空间预算风险、
Static Hermes 对标、test262/子集语义测试验收项、字节码缓存开放问题。
Position: 本文是 [engine-evolution-plan.md](engine-evolution-plan.md) v0.4
（已批准）的**姊妹方案**，不修改其任何阶段与裁决。v0.4 建设的是动态
反馈轴（运行时发现类型/形状 → 反馈槽 → baseline JIT → IC）；本文提案
静态类型轴（TypeScript type lint 在编译期证明类型/形状 → 特化字节码，
零预热）。两轴共享同一块基建（§4），静态轴的每一项都让动态轴的
对应项变便宜或变得不必要。

下游消费方（2026-08-25 注）：FNABI
（[fun-native-plugin-design.md](fun-native-plugin-design.md) v0.3，
2026-08-25 采纳）是 F1/F2/F4 与 T3 schema 的下游消费方，其里程碑
M1 挂在本计划 S1 交付之后——S1 滑期会连带阻塞第三个计划。

---

## 一、立项依据：2026-08-25 Octane v9 模块级归因

证据档案：[perf/bench-v8-status.md](perf/bench-v8-status.md) 五引擎
快照（zjs 4521 / qjs 4704 / Hermes 6246 / V8-jitless 5448 /
JSC-jitless 5096，main 上见 2026-08-25 合并 commit；原始快照 commit
`84537d3f` 属 pre-squash 谱系，已不可达）+ 同日 perf/PMU 归因。要点：

1. **属性访问是唯一贯穿全部垫底基准的头号模块**：get/put_field 家族
   占 Richards 48.6% / Box2D 45.7%（op_get_field 单符号 34.5%）/
   DeltaBlue 43.6% / Typescript 36.5% 的采样时间。annotate 显示
   23.3% 周期烧在 shape 哈希桶装载后的 load-use stall——每次执行
   重付探测，own-hit 全路径 47 指令（`src/exec/tailcall_dispatch.zig:3415`
   → `src/exec/vm_property_field.zig:346-468`）。
2. **调用/帧第二**（10-38%），超量清单已逐条对账（Entry/arena/预算
   记账/Vm 6 标量重发布，`src/exec/inline_calls.zig:1967-2098`）。
3. **纯解释模式的机制上界已被三家实证**：JSC LLInt（structureID 单
   比较 + 偏移装载，~29 insn 含 dispatch）、Hermes（HiddenClass 指针
   比较，~15-20 insn）、V8 jitless（map 比较 + Smi handler）在同样
   "无 JIT"约束下对 zjs 拿到 1.35-2.2x 整基准优势。
4. **Hermes 的分解实验直接标定了静态轴的价值**：其 AOT 优化管线
   （Inlining/TypeInference/免检指令/闭包提升）贡献 RayTrace
   -O/-O0 = 1.88x——而它为此付出运行时按次编译税（CodeLoad 0.29x）。
   zjs 的机会：**类型事实由 lint 工具离线证明，运行时编译器保持
   单遍**——拿 Hermes 的收益，不付 Hermes 的启动税（zjs CodeLoad
   现胜 qjs 1.05x，此优势为验收红线，§7）。

dispatch 骨架不在本文范围：三骨架 ~20.7 cyc/iter 地板已实测冻结
（v0.4 §2.4 免测清单）。静态轴打破地板的方式不是更快的跳转，而是
**更少的 dispatch 次数 ×更少的每 op 工作**。

### 1.5 与 2026-08-17 IC 否证实验的对账（0.3 新增，评审关键）

本仓库 2026-08-17 曾实测否决位点 IC（PERF-MECHANISM-LEDGER #3 =
REJECTED-ARCHIVE）：目标形做到 33 insn / ic_base 单载 / 两比，仍在
TS 终门 FAIL。尸检定理：**zjs 属性快臂实测已 2-3 cyc 单探，任何
旁挂带 miss 税的缓存付不起差价**；教科书"10 cyc/hit"高估一档。
本方案必须回答"为什么这次不一样"，答案分三层：

1. **静态槽位不是 side-cache**。被否的形态是运行时侧表：热路径要
   多付一次 ic_base 装载（自身有 D-cache miss 税）+ 两次比较。
   typed 站点的 expected identity 与 slot index 是**编译期常量，
   直接编进字节码操作数**——热路径零侧表装载、零学习、零预热，
   guard 数据随取指自然到达。"旁挂缓存 miss 税"这个否决理由对
   静态形态在机制上不成立。L1/L2 的 own-slot 免 guard 形态更是
   连比较都没有，是该实验从未测过的形态。
2. **该实验的验收场与本方案的主战场不同**。08-17 的终门在 TS——
   而同日五封条把 TS 落后判为 call/return architectural（残差闭合
   96.3%）。在 call 瓶颈的基准上验属性机制，测不出属性机制的
   效果。本归因显示属性时间占比最高的是 Box2D 45.7% / Richards
   48.6% / DeltaBlue 43.6%，该实验未在这些场上给出否证。
3. **但否证留下的纪律对本方案具约束力**：同日五层自底向上结论
   "zjs 在 L0-L4 与 qjs 实现级齐平或更优"意味着对 qjs 的既有
   落后不能靠属性机制翻盘（那是 L1I 墙/call 语义/壳单价的账）；
   一切纸面 insn 节省必须按**实测快臂单价**折算后才可立项——
   这就是 §6.2 T-spike 强制门的由来。跨引擎 1.35-2.2x 优势同样
   不可全额记在 IC 头上（JSC/Hermes 同时在字节码编码、调用机器、
   编译器优化多轴上不同），只能作为机会上界。

## 二、类型信息管线与信任分级（核心设计决策）

### 2.1 输入形态

- zjs parser 扩展 TS 语法：解析类型注解并保留到编译器可见的位置
  （运行语义 = 类型剥离后的 JS，与 tsc/Node type-stripping 对齐）。
  这是独立可交付项（T-gate 0），也让 zjs 可直接执行 .ts。
  **范围限定为可擦除语法子集**（erasableSyntaxOnly，与 Node
  `--experimental-strip-types` 同界）：enum / namespace / 装饰器 /
  参数属性有运行时语义，不属于类型剥离，v1 显式拒绝（lint 前置
  转换或降级为普通 JS 模块）。
- type lint 工具（fun 工具链侧）对模块出具**资格证书
  （certificate）**：声明"该模块的注解在子集 S 下健全"，绑定
  源码 hash + lint 版本 + zjs 配置签名（复用 `zjs-config` 签名机制，
  v0.4 §5.3）。证书缺失/过期/不匹配 ⇒ 静默降级（见分级）。

### 2.2 信任分级（每模块粒度）

| 级别 | 语义 | 特化形态 | 违反后果 |
| --- | --- | --- | --- |
| **L0 hint**（默认） | 注解仅是提示，无健全性要求 | 特化 op 带 1 条廉价 guard（tag / shape identity，§4.1），fail → 原 op 通用路径 | 无——性能回退，语义不变 |
| **L1 checked** | lint 证明模块内健全；边界（untyped 调用方、JSON、FFI）插检查 | 模块内特化免 guard；边界处 1 次检查 | 边界 TypeError |
| **L2 trusted** | 零检查（仅 fun 内部核心库显式 opt-in） | 全免 guard | UB（lint 层负全责） |

L0 是无条件安全的起点：guard 是 1 条比较，仍远胜现役全动态路径
（47 insn 哈希探测）。**任何 untyped/无证书代码的行为与今天逐位
一致**——特化 opcode 只增不改，strip 类型后差分 oracle 必须逐位
等价（§7）。

## 三、静态轴优化项（按归因模块映射）

### T1 类型化属性访问（对 36-49% 的头号模块，最大单项）

`class C { x: number; y: number }`（typed class / interface 字面量）
⇒ 编译期确定完整 shape 布局（slot 0,1,…）：

- 对象创建走**预建 shape**（编译期注册，不走运行时 transition 链）；
- `obj.x` 发射 `get_field_slot`：L0 = shape identity 单比较（1 load
  + 1 cmp，§4.1）→ `prop_values[slot]` 直读（≈ JSC LLInt Default
  模式的静态预填版）；L1/L2 的 **own-slot** 读免 guard 直接偏移装载
  （比 JSC/Hermes 的 IC 还少一次比较——静态轴独有形态）；
- put 侧同理；typed class 的方法在原型上 ⇒ 方法读发射 proto-slot
  直达（免链走查——Richards/DeltaBlue 的主要负载形态）；
- **proto-slot 健全性规则（0.3 修正）**：receiver 的 identity guard
  证明的是 receiver 自身布局与其 proto **指针**，但挡不住 holder
  （原型对象）自身的形状变异——原型上加/删属性会使已缓存的 slot
  index 指向错误槽位（值替换如 monkey-patch 方法体是数据写，slot
  读天然拿到新值，无需失效）。因此：**L0 下 proto-slot 用双 guard**
  （receiver identity + holder identity，2 load + 2 cmp，仍远胜链
  走查）；**L1/L2 下 typed class 的原型在类定义时 auto-seal**
  （一次性 shape 定格，此后 add/delete/reconfigure 被引擎拒绝、
  值写照常）⇒ 单 receiver guard 即健全。auto-seal 是可观察语义
  （`Object.isSealed` 为 true），属子集 S 的显式 opt-in 条款，
  不进 L0；
- **免 guard 范围规则**：完全免 guard 仅限 L1/L2 的 own-slot；
  原型突变的全免 guard 化需失效登记（Phase 3 dependency
  registry），不提前；
- **编码与退化设计（0.3 新增）**：`get_field_slot` 热编码不携带
  atom——操作数 = 函数级 shape 引用表索引（u8/u16）+ slot（u8），
  期望 identity 经该表取得；guard-fail 冷路径经 per-function
  站点→atom 恢复表走通用查找。同一站点连续 fail 超阈值 ⇒ 原地
  改写回通用 `get_field`（字节码为函数私有可写，单线程窗口），
  杜绝"病理站点每次白付 guard"的负收益形态；
- 逃逸语义：typed 对象被动态改形（加/删属性、换 proto）⇒ guard
  因 identity 变更自然 fail 回通用路；L1/L2 的 own-slot 免 guard
  前提由 lint 禁逃逸（子集 S 条款：typed class 实例不得 delete/
  动态扩展/换 proto——违者降级该类为 L0）。

### T2 类型化算术与比较

number-proven 操作数 ⇒ `add_num / sub_num / mul_num / div_num` 与
`lt_num_if_false8` 类融合免检指令（Hermes `AddN/JLessN` 同构，
`BytecodeList.def:213-228, 982-997`；其 -O 收益的主要构成之一）。
TS 只有 number 无 int：int32 特化不做静态断言，留给动态轴
（baseline JIT 的 profile）。

### T3 类型化调用

- 已知签名（argc、leaf 资格）⇒ 编译期直接选定帧构造策略，跳过
  运行时 leaf 判别链（现役每次调用重做的多级 bit 判别，
  `tailcall_dispatch.zig:1530-1616`）；
- 模块内 callee identity 编译期已知 ⇒ `call_direct`（函数索引直达，
  免 callee 解析）；
- **typed FFI**：类型签名就是 NativeCallDescriptor（v0.4 §9.1）的
  静态实例 ⇒ native direct call 可以在解释器阶段提前兑现，不等
  Phase 3。对 fun GUI runtime（Canvas/WebGPU/FS）价值最大。

### T4 类型化数组

`number[]` ⇒ dense double 存储臂与免 tag 检查的 `get/put_array_el`
特化；`T[]`（T 为 typed class）⇒ 元素 shape 已知，读后属性访问
链式特化。

### 类型 → 特化映射规则（0.2 新增）

| 注解形态 | 特化 |
| --- | --- |
| 具体原始类型（number/string/boolean）、typed class | T1-T4 按级别特化 |
| optional（`x?: T`）、union、`any`/`unknown`、泛型参数 | **不特化**，保持通用 op（optional 破坏固定槽布局，union 无单一快路） |
| 交叉类型、条件类型等高阶形态 | 不特化（lint 可归约到具体类型的除外，由证书携带归约结果） |

泛型在 v1 一律按擦除处理，不做单态化。

### T5 编译器内类型传播（保持单遍）

zjs 字节码编译器内做**局部**类型传播（从注解出发沿表达式树下推，
选择 T1-T4 特化 opcode）；不做全量推断——推断/检查是 lint 工具的
离线工作。红线：运行时编译保持单遍，CodeLoad 不回归（Hermes 的
反面教材：重前端按次付费 = 0.29x）。

### 明确不做

- 不做 register bytecode（维持 v0.4 §17 既有裁决；T2 的融合指令在
  栈机上同样成立）；
- 不做 zjs 内置完整 TS 检查器（检查归 lint 工具）；
- 不在本阶段做 typed field unboxing（f64 内联存储改变值表示，属
  [vm-value-representation-contract.md](vm-value-representation-contract.md)
  修订项，与 tracing GC 换代排序后再议——先收割不动表示就有的
  收益）。

### 预期效果与置信度（0.3 新增，对抗校准）

先说清最重要的一条：**静态轴对 untyped 负载（Octane 全套、一般 JS
生态）收益 = 0**——特化只作用于带注解且过 lint 的代码。untyped
负载的改善只能来自动态轴（Phase 0.5/2/3），而动态轴的解释器级收益
已被 08-17 实验压缩到"原型链命中缓存 + 多态站点 + 作为 Phase 2
输入"（v0.4 §6.2 与 §1.5 的一致结论）。静态轴的效果主张全部落在
**typed 代码（fun 的自有负载）**上。

| 项 | 机制上省什么 | 纸面估计（typed 场） | 置信度与依据 | 杀标 |
| --- | --- | --- | --- | --- |
| T1 own-slot | 免 atom 解码（~9 insn）+ 免哈希探测（~10-18 insn）；依赖装载链 4→2 | 属性密集基准 +10-20% | **中**。annotate 证明 stall 存在（23.3% 于桶装载后比较）；但 08-17 尸检定理警告实测快臂单价可能远低于纸面（2-3 cyc 单探）——净赢面必须 spike 实测 | T-spike：own-slot 形态在属性密集 typed 微基准上 < +8% ⇒ 静态属性赌注死，轴收缩至 FFI/eval-cache |
| T1 proto-slot（双 guard/seal+单 guard） | 免整条原型链走查（每层一次探测） | 方法读密集（Richards/DeltaBlue 形态）+10-25% | **中偏高**。链走查是逐层依赖装载，缩短链的收益比 own-hit 更难被 OoO 吸收；JSC ProtoLoad 模式的存在性佐证 | 同上 spike 场含方法读负载 |
| T2 免检算术 | 每 op 免 2-4 insn 可预测 tag 检查 | 低个位数 | **低**。「五分歧对抗定价 5/5 证伪：常数 insn 税多被 OoO 吸收」在册先例直接适用；且 L4 已判与 qjs 同构 | 频次普查 + 单族 A/B，不达噪声带 2x 即弃 |
| T3 帧策略静态化 | 免 leaf 判别链（可预测分支为主） | 低个位数 | **低**。v0.4 已勘误 call 差距在"帧语义机器，换骨架删不掉"；判别链是其中最可预测的部分 | 同上 |
| T3 typed FFI 直调 | 免通用 wrapper/装拆箱 | fun GUI 负载显著；Octane 无感 | **中**。机制同 v0.4 §9.1（已立项方向），静态签名只是提前兑现；量级无实测 | 以 fun 真实负载立验收，不用 Octane |
| T4 typed 数组 | 免元素 tag 检查（unboxing 已推迟） | 低个位数 | **低**。真收益在 unboxed 存储，本阶段明确不做——v1 T4 是薄项，可降为 T2 的附属 | 并入 T2 杀标 |
| P2 eval 缓存（非静态轴） | 免重复 parse+codegen | ~~CodeLoad 单项显著~~ **0.9 证伪:cacheBust() 使命中恒 0,Octane 预期归零,转 incubator(见头部 note)** | ~~高~~ 证伪 | 以 fun 真实负载重立项 |

综合结论：**本方案的效果核心押在 T1 一项上**（typed 属性访问，
两种形态），T2/T3/T4 是搭车项（基建摊销后的低成本尝试，各自带
杀标）；若 T-spike 杀标触发，静态轴的存活范围收缩为 typed FFI +
eval 缓存 + "类型作为 Phase 2 baseline JIT 的免预热输入"（此项
不依赖解释器级兑现，是静态轴的保底价值）。

## 四、共享基建：静态轴与 Phase 0.5 是同一块地基

v0.4 Phase 0.5（已批准解锁）要建：per-site side table（按 pc 索引，
canonical bytecode 不改）+ monomorphic shape cache（shape 指针 +
槽偏移 + 版本）+ 失效版本号。本文归因（2026-08-25 Octane v9 五引擎
快照，[perf/bench-v8-status.md](perf/bench-v8-status.md)）补充了两个
工程事实：

1. **shape 现无稳定身份**：rc==1 原地变异（追加/tombstone/换
   proto/compact，`src/core/shape.zig:395-599`）+ relocate 换址
   （ABA）。**0.2 定案设计：identity == version 单字段**——shape
   增设一个 u32（或 u64）`identity` 字段，创建时与每次原地变异时
   都从全局单调计数器取新值；缓存只存 identity，不存指针。guard
   = 1 load + 1 cmp（与 JSC structureID 比较同级），id 永不复用
   ⇒ 天然防 ABA，relocate 免疫（identity 随对象搬走）。这同时是
   Phase 0.5 反馈槽与 T1 guard 的共同依据；字段布局需与 tracing
   GC 的 shape 处理共同评审（shape 是 GC 对象）。
2. **归因对 Phase 0.5 §6.2 收益校准的补充（0.3 措辞收敛）**：
   annotate 证明 own-hit 每次仍付哈希桶 load-use stall（Box2D
   34.5% 单符号、23% 周期在桶装载后的比较）——但 08-17 尸检定理
   （§1.5）警告该 stall 的**可回收量**必须实测：side-cache 形态
   已被否，v0.4 "own 站点赢面≈0"对动态轴维持有效；本文只主张
   **静态槽位形态**（零侧表）在该 stall 上有机会，量级交 T-spike
   裁决。proto-hit 缓存的赢面两轴共识（v0.4 §6.2 亦认）。验收锚
   建议从 pdfjs/typescript/box2d 扩为 + Richards/DeltaBlue
   （proto 方法读密集）。

静态轴在此基建上的增量只有：预建 shape 注册表 + certificate 摄入 +
特化 opcode 家族。**先做 Phase 0.5 不是绕路，是静态轴的第一步。**

## 五、与已批准阶段的汇合关系

| v0.4 阶段 | 静态轴的输入 |
| --- | --- |
| Phase 0.5 反馈槽 | typed site 出生即单态、免预热（类型作 seed）；共享 metadata/版本基建 |
| Phase 2 baseline JIT | 静态类型 ⇒ 直接发射免 guard 快路，不等反馈变热；guard 数量下降 = 代码体积与 bailout 双降 |
| Phase 3 IC/native direct | typed site 免 IC；typed FFI 提前到解释器 |
| Phase 4 deopt | L0 guard fail 走"原地降级回通用 op"，不需要 snapshot——静态轴在解释器阶段不引入 deopt 复杂度 |
| 表示契约 | unboxing 推迟条款（§3 不做清单；帧内例外见 §5.1） |
| **AOT（0.5 新增，owner 确认方向）** | typed bytecode 即 AOT IR；Phase 2 emitter 离线运行即 AOT 编译器（§5.1） |

### 5.1 AOT 主线：直接原生化，经由 Zig 源码发射（0.8 定向）

**主线管线**：

```text
TS → typed bytecode（T1-T4 特化 op 承载类型事实 = 编译 IR + 兜底执行形态）
   → Zig 源码发射（每函数一个 Zig fn，特化 op 展开为直接槽读/FP 运算，
     通用 op 展开为现有 runtime helper 调用）
   → 交 zig 编译器（LLVM：内联/寄存器分配/未装箱 FP 全部代劳）
   → 静态链接进 fun 应用二进制（无 dylib、无签名议题、LTO 跨 helper 内联）
   → 运行时兜底：动态特性/untyped 互操作/eval 走解释器
```

**为什么 native-first 对 zjs 成立（三个顺风条件）**：

1. **收益结构性、不受 §1.5 尸检争议影响**——解释器级特化的赢面
   被"OoO 吸收/快臂 2-3 cyc"压着，而原生化消灭的是 dispatch 地板
   （20.7 cyc/iter，解释器轨不可动）与装箱搬运本身，typed OO
   2~4x / 数值核 5~10x 的量级不依赖那场争论的结论；
2. **Zig 源码发射把后端成本砍到最低**（Static Hermes 实证路线：
   发 C 交系统 cc，自身零 codegen）——zjs 的 runtime helper 本来
   就是 Zig（无 SH 的镜像结构体/-fno-strict-aliasing 风险），且
   **fun 应用本身即 Zig 构建**：生成源直接进应用构建图静态链接；
3. **GC/异常集成有现成基建**：保守栈扫描（trace_stw 线）让原生帧
   的根可见性零协议成本起步（SH 须逐函数 SHLocals shadow-stack）；
   异常沿用状态返回模型（不引 setjmp）。

**v0.7 离线字节码优化管线取消**：AST 级内联/闭包优化/作用域拍平
（估 15-25 人日）在原生主线下由 LLVM 对发射源码代劳，不再自建。
若原生路线受阻回退字节码主线，v0.7 的该节设计从版本历史恢复。

**字节码 AOT 降级为轻量子项**：typed bytecode 仍是编译 IR 与
dev 模式/动态加载的执行形态；fun 模块容器（§10.5 HBC 清单）保留
为动态加载模块的预编译分发（免运行时 parse，CodeLoad 类收益），
但不再承载优化管线。

**N-spike（0.8 新增，原生臂验证门）**：在 T-spike 之外增加原生
臂——**手写"codegen 应当发射的 Zig"**（richards-typed 微基准
一个模块），链接 zjs runtime 实测 vs 解释器。3-5 人日，产出：
(a) 原生臂在 zjs 上的真实倍数（对 2~4x 纸面的首个实测锚点）；
(b) GC/异常/边界集成的真实工程形态与坑清单。**主线量级与 v1
范围以 N-spike 数据定稿**——与 T-spike 同为"先证效果再建管线"
纪律的执行。

**边界与互操作**（沿用既有设计）：typed↔untyped 边界 = §2.2 L1
检查；typed 函数入口检查必做（SH 缺口，§10.2）；原生帧调解释器
（untyped callee）与解释器调原生（typed 导出）双向走现有 call
边界协议扩展，N-spike 覆盖最小闭环。

### 5.2 JS↔native 边界性能（0.8 新增，owner 提出）

原生主线的净收益由**边界穿越密度**调制——历史实测已证边界是真实
成本中心（raytrace 归因：native 边界 46.3M 次/次均超 qjs、86% 为
apply 形态；v0.4 §2.4(c) bl 形态对照：现役冷契约 +10 cyc/冷事件）。
边界分类与定价目标：

| 穿越 | 形态 | 成本定位 |
| --- | --- | --- |
| native→native（typed 模块内/间） | 直接 Zig call，LLVM 可内联 | 最廉，主收益区 |
| native→runtime helper（通用 op 兜底） | 直接 Zig call（helper 本即 Zig，无 ABI 转换） | bl 税级（实测 ~0.7 cyc/bl，v0.4 §2.4） |
| native→解释器（typed 调 untyped 函数） | 建解释器帧 + 入 dispatch | **最贵穿越，密度决定 AOT 净收益** |
| 解释器→native（untyped 调 typed 导出） | 入口 stub；L1 边界检查所在地 | 中；检查成本与 stub 合并支付 |
| FFI（→宿主 API） | typed FFI 直调（T3/NativeCallDescriptor） | fun GUI 主战场；历史 apply 教训的解药 |

设计规则五条：

1. **JSValue 为跨界通货，零值 marshaling**——堆可见值在 native
   帧内仍持 JSValue 表示（未装箱仅限帧内局部，§5.1 精确化），
   对象引用跨界零转换、零拷贝；
2. **整模块编译消灭模块内穿越**（SH 路线）：untyped 函数也编成
   "展开的通用 helper 调用序列"式原生码，使 native→解释器只
   发生在动态加载/eval 边界；代价 = 体积，入选择性 AOT 策略；
3. **边界密度是静态可测量**：lint/certificate 报告 typed 模块热
   路径对 untyped callee 的引用密度，超阈值出降级警告——边界税
   在构建期可见，不等运行时发现；
4. **穿越成本入 N-spike 实测**：native→interp、interp→native
   单次穿越 cyc 与往返 ping-pong 微基准；对齐 v0.4 §15 第 4 类
   "Native crossing"分层基准（generic wrapper / descriptor /
   direct call / batched API）——该基准类别已在批准计划内，本
   方案将其提前到 spike 期；
5. **异常/GC/调试跨界**：状态返回模型天然可组合；保守扫描覆盖
   native 帧（§5.1）；帧链带 kind 标记保 backtrace/debugger 与
   混合栈遍历正确。

相对 Phase 2 JIT 的边际成本：离线驱动器、arm64e 合规（PAC/BTI，
v0.4 §7.2 已有条款）、typed↔untyped 边界互操作（复用 §2.2 L1 的
边界检查设计——Static Hermes 经验中最难的部分，本方案的信任分级
正是为此形状设计的）。AOT 比 JIT 模式更简单的部分：无 tiering/
OSR/并发编译/运行时补丁。**emitter 共享说明**：v0.4 "解释器与 JIT
不共享 emitter"的禁令是解释器↔JIT 之间的；JIT 与 AOT 是同一
emitter 的两种驱动方式，不冲突——建议 Phase 2 立项时把"emitter
可离线运行"列为设计约束。

**类型在 AOT 的兑现（对照解释器兑现）**：属性访问 = 一条带偏移
load/store 机器指令；算术 = 未装箱 double 驻 FP 寄存器跨表达式
流动；调用 = 直接 native call 走寄存器传参；**dispatch 地板
（~20.7 cyc/iter，解释器轨不可动）整体消失**；**帧内/寄存器
unboxing 自然成立**——精确化：AOT 帧内未装箱局部值是编译器局部
事务，边界处装回 JSValue，不改变堆上表示，因此**不违反"堆字段
unboxing 推迟"条款**（堆字段 unboxing 仍按表示契约推迟）。

**量级（纸面，业界 tier 锚点）**：typed OO 代码 2~4x（baseline-JIT
级代码质量）；数值核心（unboxed FP 循环）5~10x 逼近原生；untyped
代码 AOT 收益小——**类型覆盖率直接决定 AOT 的值域**。

**iOS 战略修订**：v0.4 §3.2 "iOS 禁 JIT → 解释器即产品上限"由
typed AOT 突破——离线编译、零运行时代码生成、W^X 硬执行天然合规、
可签名分发。iOS 性能上限从"解释器 + IC"改写为"解释器 + typed
AOT 原生码"。

**代价**：原生码体积远大于字节码（Static Hermes 已知痛点）——
对策 = 选择性 AOT（仅热 typed 模块，字节码兜底常青）；动态特性
仍需运行时兜底；边界互操作工程量前置计价。

**对 T-spike 杀标的连带修订**：spike 只裁决**解释器级**特化的
兑现；spike 未过 ⇒ 解释器特化形态（F4 新 opcode 的解释器收益）
搁置，但 **F3 类型摄入与 F5 shape 注册作为 AOT IR 基建由 AOT
方向独立支撑**，时序改挂 Phase 2 窗口——静态轴不再存在"全死"
分支，最坏情形 = 解释器期收益为零、价值全部后置到 AOT/JIT 期。

## 六、前置工作清单与执行序列

### 6.1 前置工作清单（0.2 详列）

按"不做则类型轴无法落地/收益不实"分级。**硬前置**（阻塞项）：

| # | 前置项 | 为什么阻塞 | 状态与出处 |
| --- | --- | --- | --- |
| F1 | **shape identity 字段**（§4.1 设计） | 一切 per-site 缓存（Phase 0.5 反馈槽、T1 guard）的健全性依据；现状 rc==1 原地变异 + relocate ABA 使指针比对不可靠 | 未开工；设计已定案于 §4.1，需与 tracing GC 侧共同评审 |
| F2 | **per-site metadata 侧表** | **仅动态轴（Phase 0.5 反馈槽）的载体**。0.3 修正：typed 站点的 guard 数据是编译期常量、编进操作数，运行时**不消费侧表**（这正是 §1.5 免于"miss 税"否证的机制根据）——T1 对 F2 无硬依赖，静态轴与 Phase 0.5 交付解耦；仅站点毒化计数、atom 恢复表等冷路径设施可复用其挂载点 | = Phase 0.5 交付物（v0.4 §6.1，已批准） |
| F3 | **TS 语法解析（strip，可擦除子集）** | 引擎读不到注解则静态轴不存在 | 未开工，独立可交付（T-gate 0） |
| F4 | **opcode id 空间盘点与扩展方案** | short 区 178-253 已被 temp 区+融合 op 占用（`bytecode.zig:348-424`）；T1-T4 预计需 20-40 个新 id，现平面放不下 | 未开工；候选=回收 temp 区/二级平面（前缀 op，参照 JSC wide 前缀）/复用 `using` 前缀机制，T-gate 0 内定案 |
| F5 | **编译期 shape 注册机制**（typed class 声明 → shape 描述随字节码携带 → 首次执行物化） | T1 的"预建 shape"需要编译器能描述布局；现状 shape 全部运行时构建 | 未开工。**翻案说明**：zoo-r0 曾否决 `object_from_shape`（eligible literals ≪ G1 bar）——那是对 untyped 动态字面量的可证明率裁决；typed class 是显式声明，可证明率 100%，前提不同，旧裁决不适用 |
| F6 | **测量尺修复（S0）** | −7~8pp 系统性偏移未归因前，类型轴所有 A/B 都在漂移的尺上；若是真回归须先修复，否则收益账不可信 | **已交付（2026-08-25 同批）**：偏移裁决为参考二进制漂移（qjs 同源 GCC-13→GCC-16），非 zjs 回归（[perf/bench-v8-status.md](perf/bench-v8-status.md)）；残余工作=每条发布记录钉参考二进制指纹（hash+compiler） |

**强烈建议的前置优化**（非阻塞，但先做能让类型轴收益更实/施工更安全）：

| # | 项 | 理由 |
| --- | --- | --- |
| P1 | **门禁扩容**：refactor gate 从 v7 的 8 基准扩到含 pdfjs/typescript/box2d/gbemu | v7 门禁盲区已让这一族无守卫滑坡数周；类型轴施工期（大量编译器/解释器改动）必须有全谱守卫。**已交付（2026-08-25）**：A/B 门禁随 Octane 2.0 扩到 16 项（`docs/refactor-policy.md:40-45`） |
| P2 | **eval CompilationCache**（V8 四元组 key） | ~~CodeLoad 头顶 2.37x 的独立收益~~(0.9 证伪:cacheBust 使命中恒 0)+ **T5 的对冲**逻辑保留为 incubator 立项理由——TS 解析与类型传播会让编译变贵;是否立项以 fun 真实负载定 |
| P3 | **原型链命中缓存先行落地**（Phase 0.5 范围内提前排序） | 归因显示 Richards/DeltaBlue 的方法读（proto-hit）是最大单项负载；且 T1 的 proto-slot 形态（带 guard）与它是同一机制——动态版先落地，typed 版只是预填 |
| P4 | **tracing GC 合入窗口协调** | ~~`gc/tracing` 四门全绿待合入~~ **降级（2026-08-25）**：当日发现此前四门是在 major 从不触发的收集器上量的（`f10855c6`、`756a1d07`），合入窗口前须重新过门；F1 动 shape 布局、F2 引入新 GC 可达结构（缓存持 shape 引用），两个大改动不应同时在飞——建议 GC 重新过门合入或明确冻结窗口后再动 F1/F2 |
| P5 | **zlib indirect-eval 修复** | 正确性欠账（Octane 第 17 项跳过中）；与类型轴无依赖，但 eval 语义修复与 P2 同域，可顺路 |

**明确不做的"前置"**（防止浪费）：通用哈希探测路径的微优化
（cache line 布局调整等）——F1+T1/Phase 0.5 落地后该路径退居冷路，
在将死的路径上投资无意义；调用路径 Vm 重发布削减——v0.4 §2.1 已
勘误为"帧语义机器成本，换骨架删不掉"，T3 的静态判别是更高杠杆的
同靶改法。

### 6.2 执行序列

```text
S0  F6 测量尺裁决 + P1 门禁扩容（~1 天，一切 A/B 的前提）
    —— **两项均已交付（2026-08-25，见 §6.1 F6/P1 状态列）**
S1  = Phase 0 + 0.5（已批准）：VmExecState ABI、helper 频率仪器、
    F1 shape identity、F2 side table、property/call 反馈槽
    （P3 原型链命中缓存优先排序；P4 与 gc/tracing 合入协调窗口）
    ├─ 验收：pdfjs/typescript/box2d + Richards/DeltaBlue 可归因提升
    ├─ 并行：S2 的设计工作（T-gate 0 不依赖 S1 实现，只依赖其评审）
    ├─ 并行小项：~~P2 eval CompilationCache(0.9 转 incubator)~~；P5 zlib 修复
S2  T-gate 0（设计门）：F3 TS 语法解析 + F4 opcode 空间方案 +
    F5 shape 注册机制 + certificate 格式 + 信任分级 + 子集 S 条款
    → owner 评审后开工
    ├─ **T-spike（强制验证门，0.3 新增；0.5 修订波及范围）**：
    │   2-3 天垂直原型——手工预建 shape + 手发 get_field_slot
    │   （own-slot 与 proto-slot 双形态），在属性密集 typed 微
    │   基准 + 一个移植循环上按测量契约 A/B。杀标见 §三效果表；
    │   未过 ⇒ **解释器级特化搁置**（F4 解释器收益档），但 F3/F5
    │   作为 AOT IR 基建由 AOT 方向独立支撑、时序改挂 Phase 2
    │   窗口（§5.1）。这是 §1.5 尸检纪律（"纸面奖金按实测快臂
    │   单价折算"）的制度化——先证效果，再建管线。
S3  T1 typed 属性（先 L0 全程 guard）＋ typed 基准尺建立
    （Octane 子集 typed 移植 raytrace/richards/deltablue + fun
    真实 workload；对照含 Hermes -O——同命题最近对标）
S4  T2 算术免检族 + T3 调用特化 + T4 数组；逐族频次立项、A/B 过门
S5  Phase 2 baseline JIT（按 v0.4，消费动态反馈 + 静态类型双源）
S6  原生 AOT（0.8 主线）：N-spike（§5.1，与 T-spike 同期）过门后
    → Zig 源码发射编译器 v1（typed 子集直接槽读/FP 运算 + 通用
    op 走 runtime helper + 静态链接进 fun 应用）→ 边界互操作闭环；
    字节码容器（§10.5）降为动态加载模块的预编译子项
```

## 七、验收、红线与风险

**尺**：untyped 尺 = Octane v9 全套（静态轴改动对 untyped 代码
必须零回归——特化 op 只增不改）；typed 尺 = S3 新建（typed 变体与
untyped 原版同程序对照，报告"类型带来的加速比"）；红线 =
CodeLoad ≥ 现状（单遍编译不动摇）、SplayLatency/MandreelLatency
双第二不丢（GC 换代协同条款）。

**差分 oracle 与正确性**：任何 .ts 程序，strip 类型后在纯动态路径
重跑，可观察行为必须逐位一致（L2 模块除外，其一致性由 lint 负责），
进 CI；test262 双构建（特化 on/off）0 回归；子集 S 需要一套引擎侧
语义一致性小测试（typed 声明 + 逃逸/降级/guard-fail 各路径）。

| 风险 | 控制 |
| --- | --- |
| **纸面收益不兑现**（08-17 尸检先例：33 insn 目标形仍 FAIL） | T-spike 强制门前置于全部管线建设；效果表逐项带杀标；跨引擎倍数只作机会上界不作收益承诺 |
| TS 类型系统不健全（any/cast/边界） | 信任分级；L0 默认全 guard；L1 边界检查 + own-slot 限定（§T1 免 guard 范围规则）；L2 仅 fun 内部显式 opt-in |
| certificate 与源码漂移 | hash + 版本 + 配置签名绑定；不匹配静默降 L0 |
| 特化 opcode 膨胀 I-cache（前端税是现役短板） | 每族按动态频次立项（.short 层既有纪律）；A/B 含 L1I/前端 stall 指标 |
| opcode id 空间不足 | F4 前置定案（回收 temp 区 / 前缀二级平面）；无方案不开工 T1 |
| typed/untyped 双路径语义漂移 | strip 差分 oracle 进 CI；特化 op 语义定义为"通用 op + 已证前提"，不独立发明语义 |
| 与 tracing GC / 表示契约相撞 | unboxing 推迟；F1 identity 字段与 tracing GC 共同评审；P4 合入窗口协调 |
| L2 模块被滥用为攻击面 | L2 仅可来自可信构建产物，装载路径受 [LIMITATIONS.md](../LIMITATIONS.md) 的 Security Boundary 节约束；untrusted 源一律 ≤ L0 |
| AOT 原生码体积膨胀（Static Hermes 已知痛点） | 选择性 AOT：仅热 typed 模块编原生，字节码兜底常青；体积入 S6 验收指标 |
| 生态兼容（zjs 变成"另一个方言"） | L0 下注解纯提示、无语义；子集 S 只约束 L1/L2 的 opt-in 模块 |

## 八、效果预估与 ROI（0.4 新增，纸面口径）

**方法**：份额法（实测模块时间占比 × 该模块的机制可省比例），三档
口径——保守=08-17 尸检世界（OoO 吸收大部分纸面节省）、基准、乐观=
延迟链主导世界（annotate stall 证据支持）；一切上限用跨引擎实测
锚点封顶（如 Box2D 乐观档 1.30 ≤ JSC-jitless 实测 1.34）。成本为
单维护者人日粗估。**全表数字是纸面估计，T-spike 之前不构成承诺。**

### 8.1 分尺效果预估

**Octane（untyped 尺）——静态轴恒为 0，只有动态轴与独立项**：

| 项 | 单基准效果 | 综合分效果（^1/17） | 置信 |
| --- | --- | --- | --- |
| P2 eval 缓存 | ~~CodeLoad ×1.5~2.2~~ ≈0(0.9 证伪) | ~~+2~4%~~ ≈0 | ~~高~~ 证伪 |
| Phase 0.5（原型链缓存+多态） | Richards/DeltaBlue +3~6% | +0.5~1.5% | 中低（解释器级；主价值=Phase 2 输入） |
| T2/T3/T4 对 untyped | 0 | 0 | — |

**fun typed 负载（OO 密集，Richards/DeltaBlue/Box2D 形态）**：

| 项 | 保守 | 基准 | 乐观（锚点封顶） |
| --- | --- | --- | --- |
| T1（own+proto slot，份额 36-49% × 可省 15%/35%/50%） | +6~8% | **+15~20%** | +23~30%（≤JSC 1.34-1.70 锚） |
| T2 免检算术 | 0 | +1~2% | +3% |
| T3 帧策略静态化 | 0 | +1~3% | +5% |
| T4 数组（无 unboxing） | 0 | +1% | +2% |
| **静态轴合计（乘算）** | **+6~8%** | **+18~26%** | **+35%** |

T1 份额法细账：own-hit 47→~29 insn（免 atom 解码 9 + 探测 18，
换 identity guard ~5 + 槽读 2）、依赖装载链 4-5→2-3；proto-hit
另免逐层链走查。typed FFI 直调不在此表（Octane 无感、fun 负载
未实测，按产品价值单列）。**Phase 2 放大器**：静态类型让 baseline
JIT 直接发免 guard 机器码，typed 代码在 Phase 2 的收益系数高于
untyped——静态轴投资在 JIT 时代复利，不重复计价。

### 8.2 成本与 ROI 排序

| 项 | 成本（人日） | 效果 | ROI 判决 |
| --- | --- | --- | --- |
| S0 测量尺裁决+门禁扩容 | 1-2 | 保全所有后续 A/B | 无穷（风险口径） |
| **P2 eval 缓存** | 3-5 | ~~Octane 综合 +2~4%~~ **0.9 证伪归零,转 incubator** | ~~全案最高,先做~~ **撤销;ROI 首位移交 T/N-spike** |
| **T-spike** | 2-3 | 把 T1 的 35-55 人日投资决策从纸面变实测 | **信息购买，第二优先** |
| Phase 0.5 全量 | 15-20 | Octane +0.5~1.5% + Phase 2 必需输入 | 单看解释器级偏低；战略必需（v0.4 已如此定价） |
| F1+F3+F4+F5+T1（spike 过门后） | 35-55（F3 TS 语法 10-20 为大头） | typed 负载 +15~20%（基准档） | 取决于 fun 热代码的 typed 占比——占比高则为产品主杠杆 |
| T2/T3/T4 | 各 2-8 | typed +1~3%/项 | 低，仅作基建摊销后的搭车项 |
| P5 zlib 修复 | 2-4 | 正确性+第 17 项分数 | 正确性义务 |
| （对照）Phase 2 baseline JIT | ~2-3 月 | 预期 1.5~2x 量级 | 大投入大回报；静态轴是其减险器 |

**AOT 期效果（0.8 修订，原生主线）**：typed OO 2~4x、数值核心
5~10x（纸面），**净值由 JS↔native 边界密度调制（§5.2），锚点由
N-spike 实测定**；字节码容器子项保留动态加载模块免 parse 的
CodeLoad 类收益（无优化管线）。v0.7 的字节码优化管线估算
（typed 1.3~1.5x）随主线切换作废，存版本历史备回退。

**决策要点（0.8 修订）**：(1) P2 + T-spike + **N-spike** 合计
≤13 人日，先行——两个 spike 分别为解释器臂与原生臂定锚，主线
量级以实测定稿；
(2) 静态轴主投资（~40 人日）的开工条件放宽：AOT 已确认为方向 ⇒
F3/F5（类型摄入 + shape 注册，~20 人日）**无论 spike 结果都要建**
（AOT IR 基建），spike 只裁决 F4/T1 解释器形态那 ~20 人日的时序
（过门=现在做，未过=价值后置到 Phase 2/AOT 期）；(3) fun 热路径
typed 占比（owner 掌握）决定的不再是"做不做"而是"解释器期做多深"；
(4) 静态轴不存在全死分支——最坏情形 = 解释器期收益为零，价值
全部后置到 AOT/JIT 期兑现。

## 九、开放问题（owner 裁决项）

1. lint 工具归属与子集 S 的定义权（fun 工具链 or zjs 仓库）；
2. certificate 载体（源内 pragma / 侧车文件 / 打包进 fun 的模块
   格式）；
3. typed 尺的构成（Octane typed 移植 vs fun workload 优先；建议
   对照组含 Hermes -O——Static Hermes 是同命题的最近先例，其
   typed AOT 走原生编译，zjs 走解释器特化，差异化定位值得在尺上
   显式呈现）；
4. zlib indirect-eval 缺口修复排期（P5，正确性欠账）；
5. 编译产物缓存：特化字节码（含证书指纹入 cache key）是否进 fun
   模块格式——摊销 T5 编译成本、启动收益大，但引入缓存失效面，
   建议 S3 后评估（若走 AOT，该格式自然扩展为 AOT 产物容器）；
6. P4 的具体排序：`gc/tracing` 合入 main 与 F1/F2 开工的先后；
7. AOT 产物形态与分发（0.5 新增）：原生码打包进 fun 应用 vs 独立
   编译产物；选择性 AOT 的模块选择策略（全 typed 模块 vs profile
   驱动的热模块子集）；iOS 排期与 v0.4 §3.2 窗口的对齐。

## 十、Hermes/Static Hermes 设计对账与计划补全（0.6 新增）

依据：本地 Hermes 源码（2026 main）两轮深挖——Static Hermes 类型
编译核心（FlowChecker ~1.2 万行、typed class 布局、shermes C 后端、
边界语义）与 HBC 分发格式/值表示谱系。Static Hermes 是本方案同命题
的唯一工业级先例，以下逐项对账。

### 10.1 T1 获得直接先例（可行性从推测升为实证）

- **SH 的 typed class = 预建单态 HiddenClass + 编译期槽位 + 普通
  JSObject 存储**（`HiddenClass::createForTypedObject`：无 parent、
  无 transition 链、一类一终态 class）——与本方案"预建 shape +
  slot 访问"逐点同构，且证明**不需要新对象模型**，复用既有对象
  存储即可。
- **解释器级槽位 opcode 已有先例**：SH 的同一 typed IR 同时下降到
  C 原生、字节码（`PrLoad → GetOwnBySlotIdx` opcode）与 JIT 三个
  后端混跑——T1 的 `get_field_slot` 解释器形态与"typed bytecode
  作为 AOT IR"管线（§5.1）都有实证支撑。
- **补全 T1-a（final 方法直呼）**：SH 中 final/私有/overload 方法
  **不占布局槽**，编译期直接解析为函数调用——typed class 的方法
  调用可跳过属性读+callee 解析两步。对 Richards 形态（方法调用
  密集）这是 T1+T3 的合成增强；子集 S 增加 `final` 语义（或 lint
  证明无覆写即视同 final）。
- **补全 T1-b（实例级 seal，L2）**：SH 用 `markAsTyped()` =
  frozen+sealed+noExtend 冻结**实例**，untyped 读正常（HiddenClass
  属性表在，泛用路径与 IC 都工作）、写被拒。zjs L2 采用较温和的
  **seal**（禁加/删/重配置，值写照常——slot index 稳定只需 seal
  不需 freeze），比 SH 对渐进互操作更友好；L0/L1 靠 guard 不需要
  实例封印。
- **补全 T1-c（nonPointer 免写屏障位）**：SH 的 `PrStore` 带编译期
  `nonPointer` 标志（新旧值都非指针 ⇒ 免写屏障），环境写另有
  `StoreNPToEnvironment` 专用 op。zjs 的 typed put 侧同样携带该
  位——**RC 期无收益，tracing GC 落地后免屏障红利自动兑现**，与
  gc/tracing 的屏障设计共同评审（P4 议程追加）。

### 10.2 SH 的两个自认健全性缺口 = zjs 的差异化机会

- **缺口一：typed 函数入口不检查**。untyped 代码调 typed 函数时，
  参数按注解直接信任（SH 文档明列为未来工作）。zjs L1 从第一版
  就含调用边界检查（§2.2），此项为**必做不可省**——先例的洞就是
  我们的验收条款。
- **缺口二：checked cast 只到 tag 粒度**。SH 的 `any → class C`
  运行时只验"是对象"，名义类身份不验（其 v2 计划才补运行时类型
  描述符）。**zjs 的 shape-identity guard 天然就是名义级检查**
  （identity 绑定精确布局）——我们的 L0/L1 检查强度达到 SH v2 的
  目标形态，这一点写入与 Static Hermes 的差异化定位（§9 开放问题
  3 的对照组叙事）。
- SH 无 L0 hint 层（信任模型只有"全程序证明 + any 边界 tag cast"
  两态）——zjs 的 L0（带 guard 的渐进特化、violation 零语义后果）
  是先例没有的形态，也是对"部分类型化真实代码"更现实的形态。

### 10.3 子集 S 条款的先例输入（T-gate 0 直接取材）

SH typed 语言的收紧清单可按需采纳：对象类型 exact 且**属性有序**
（"与类型声明同序，编译器才能给出极致访问效率"）；全局对象属性
类型注解不健全 ⇒ 强制 any（SH 靠 IIFE 包裹顶层——zjs/fun 走 ES
模块作用域天然规避，子集 S 明文"只有模块作用域绑定可特化"）；
narrowing 不做完整 refinement，只做使用点空值检查；typed 数组无
hole、越界 throw（SH FastArray 语义，对应 T4）；catch 参数恒 any。
泛型=AST 克隆单态化（SH 实付的成本提醒：本方案 v1 擦除不单态化的
决策再次确认）。

### 10.4 S6 AOT 的三个设计决策点（SH 实证输入）

1. **后端形态（新增备选）**：SH 发 **C 源码交系统 cc**（自身零
   codegen；"未装箱驻 FP 寄存器"完全靠 cc 内联优化兑现，代价 =
   `-fno-strict-aliasing` 与镜像结构体契约）。zjs 对应物 = **发
   Zig 源码交 zig cc**——成本远低于把 Phase 2 MacroAssembler 改
   离线，且 zjs 的 runtime helper 本来就是 Zig（无镜像结构体
   问题，先例的最大风险项在 zjs 侧天然消失）。S6 改为两条备选
   （Zig 源码发射 vs Phase 2 emitter 离线），T-spike 后按 Phase 2
   排期定。
2. **GC 协作**：SH 用逐函数 SHLocals shadow-stack 注册 GC 可见
   locals（指针/非指针在寄存器分配期分类，非指针不进扫描集）。
   zjs 独有替代项：**tracing GC 已有保守栈扫描基建**（trace_stw
   线），AOT 帧可先靠保守扫描零协议成本起步，shadow-stack 仅在
   保守扫描的精度/开销不达标时引入——两方案都入 S6 设计门。
3. **异常与调用约定**：SH 用 setjmp/longjmp（每含 try 函数至多一
   个 setjmp）；调用约定**未特化**（实参仍走 VM 寄存器栈，自认
   "yet"）——zjs S6 v1 同样不特化调用约定（先拿 direct call +
   槽位访问 + 免检算术的钱），异常沿用 zjs 现有状态返回模型
   （qjs 系），不引 setjmp。

### 10.5 fun 模块格式（§9 开放问题 5 实质化，HBC 清单）

若 fun 模块格式装编译产物，直接采纳的 HBC 设计事实：**对齐契约
≤4B + packed 头**（mmap 零拷贝）；**两级 small/overflow 表**控制
常驻页；**字符串 kinds RLE + 编译期预算 identifier hash**（加载
路径不摸字符串内容）+ 惰性 identifier（SymbolID 指进 mmap，首用
才物化）；**版本严格相等拒载**（编译器与运行时成对发布，certificate
的 hash 绑定与之同构）；**产物不含任何运行时值位型**（堆表示可
配置而产物不变——zjs 产物同样禁止编入 JSValue 位型）；**缓存槽
"命名编译期定死、内容运行时私有"**（函数头只带 read/write cache
计数，本体运行时清零分配——AOT 产物与堆状态零耦合，zjs 的 F2/
T1 元数据采同一模型）；**类型承诺以最小可验证元数据分发**（SH
函数头的 NumberRegCount/NonPtrRegCount 5 位计数，JIT 据此整段钉
FP/GP 寄存器——zjs typed bytecode 的分发形态照此设计：带槽位
计数与寄存器类计数，不带完整类型注解）；OTA 需求出现时用**同
容器可逆 delta 形态**（绝对偏移差分化），不设计第二种文件格式。

### 10.6 检查器归属的一致性确认

SH 自写 checker 而非复用 Flow/tsc 的结构性原因：checker 是编译
管线一级公民——在检查期直接产出布局槽位（`layoutSlotIR`）、
checked cast 位置、builtin 直呼表。zjs 的分工（lint 只证健全，
zjs 编译器从显式注解**确定性重推**布局）之所以可行，恰因映射
规则（§三）限定"只特化显式注解、推断产物不特化"——推断结果
无法被单遍编译器复现，这条限定是 lint/编译器分工的成立前提，
升格为设计不变量：**certificate 不携带布局，布局永远由 zjs
编译器从注解确定性导出**（同源码同配置必同布局，产物缓存的
一致性依据）。
