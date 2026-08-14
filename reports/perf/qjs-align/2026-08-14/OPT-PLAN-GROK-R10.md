# OPT-R10 计划 — 删特化、上通用（单批不下凹）

日期：2026-08-14。状态：**定稿；排在 R9 之后开工**（同文件足迹，避免冲突；
R9 的帧瘦身先落地也缩小本批需要回收的量）。
依据：通用性原则（PARITY-LEDGER 宪法）+ 用户裁定「classifySimpleFieldConstructor
过度设计应删除，换通用方式，参考其他引擎」。

## 0. 目标与验收总纲

一批内完成一删一立，**包级 zoo 不下凹**：

- **删**：`classifySimpleFieldConstructor` 全套——分类器、FB memo 槽、
  `CallFacts.execution.simple_field_ctor` 位、writer（`call_runtime.zig:2868`）、
  两个调用点（`:2288`/`:2370`）、`simple_ctor_bypass_enabled`/`memo_enabled` comptime 开关与
  `-Dzjs_dossier_simple_ctor` 构建选项、相关测试。落实 08-11 裁定。
- **立**：`constructor-allocation-profile`（PERF-MECHANISM-LEDGER 首条目，
  按通用性原则四条件逐条核证）。
- **验收**：删+立合并后 3-pad zoo 逐基准 lineage：geomean 不低于删前基线；
  **EB/crypto/splay（bypass 受益者）逐项对照 bypass-off 定价基线**——
  画像必须回收其中多数；四资产不回退；gate 0/49775；ReleaseSafe。

删除侧的准确回收目标 = bypass-off 定价实验（在途，`/tmp/bypass-ab/zoo.json`），
结果出来后填入 §3。

## 1. Phase 0 — 画像机制设计简报（grok，只读，driver 批准后动工）

对照 JSC `ObjectAllocationProfile`/`op_create_this`（WebKit 源）与 zjs 现状，产出：

1. 画像存放：FunctionBytecode 加画像槽（初始 shape 指针 + 槽容量；
   注意 12B/16B 结构对齐纪律，qjs 孪生结构不可破——画像挂 FB 而非 Object/Shape）；
2. 学习协议：首次构造后记录最终 shape 的槽数与初始 shape；失配（原型改、
  shape 演化分歧）时退回原路径并按 JSC 语义重新学习或钝化；
3. 分配路径：`prepareSameMachineConstructor*` 的 instance 创建按画像容量预留
  （消 ctor 中途的属性存储扩容/搬迁），初始 shape 直取缓存；
4. **等价证明面清单**：GC 在部分初始化窗口的扫描安全（预留槽的初始化协议）、
   构造中途异常/Proxy 逃逸时的对象状态、枚举顺序、`Object.keys(this)` 在 ctor 内的读、
   `Reflect.construct` 异 new_target、derived class；
5. **通用性自证**：机制路径上不得出现任何按字节码模式匹配的判断
   （lint 复核：删除后 `classifySimple|simple_field_ctor|simple_ctor` 全仓零命中）。

## 2. Phase 1 — 实施（grok，两 commit：先删后立）

- commit 1（删）：纯删除 + 测试迁移（原 bypass 语义测试改为对照真路径行为不变）；
- commit 2（立）：画像机制 + 新增等价测试（§1.4 清单逐项）+ 学习/钝化的单元测试。
- 契约：一改动一 commit、ReleaseSafe 必验（帧/分配红线）、lint=0、
  AWAIT-MEASURE 协议、difftest 语义抽样 ≥5 例（含构造中途抛异常形态）。

## 3. Phase 2 — 验收（driver）

| 对照 | 判据 |
|---|---|
| 删后（commit 1 单独） | 应复现 bypass-off 定价（校验删除干净） |
| 删+立（包） | ≥ 删前基线；EB/crypto/splay 回收 ≥ bypass-off 损失的 2/3；raytrace 方向 ≥0（G 形首次受益） |
| gate / ReleaseSafe / lint | 全绿 |

**bypass-off 定价基线（2026-08-14 实测，CPU19，8 samples）**：
geomean **0.9953**（删除总价 −0.47%）；**损失高度集中：EB −9.08%**、
zlib −1.09%、splay −0.83%、raytrace −0.25%（确认：bypass 与 raytrace 无关）、crypto 无感。

**⚠️ 回收方程改写（Phase 0 review R1 的宏观印证）**：回收负担 ≈ 单一基准 EB
（sc_Pair 2 字段 ctor）。`initial_prop_size=4` ⇒ 容量画像对 ≤4 字段构造器回收≈0，
只剩「存储分配熔合」一笔（~10-20cyc/次）——**对 EB −9.1% 而言杯水车薪**。
capacity-profile 单独扛不起「不下凹」验收线。见 §5 修订。

## 5. 修订（2026-08-14，bypass-off 定价后）

通用替代的主力应换为 **`small-function-inlining`**（PERF-MECHANISM 第二条目，待申报）：
字节码级小函数/构造体内联 + **inline-frame 栈重建元数据**（V8/JSC 的标准做法，
保 Error.stack 可观察等价——内联体内的 put_field 语义原样保留含 setter 拦截，
只消调用+帧）。一个通用机制同时覆盖：EB 的 sc_Pair 体（回收删除损失）、
raytrace G 形的 initialize 调用（~0.34 内层调用常数）、deltablue 71% 短 accessor 链。
capacity-profile 降级为包内次要项（或按 R1 预检结果裁掉）。

**用户已裁：方案甲**（2026-08-14）——先建 small-function-inlining（申报→设计→实施），
删除与它同包落地，「不下凹」承诺保住。~~方案乙~~。

**实施状态（2026-08-14 深夜）**：申报已批（`4d295a60`，六修订写回）；
`grok/opt-r10` @ `a4e489c7`：delete `45dc3640` → profile `a55cfb1e`（降级）→
**v1 构造器体展开 `327a1655`**（只开 `call_constructor`；几何发表位／M=8 克隆／
extra locals 改写／`InlinedSite.pc_map` 差量映射／栈重建含 setter-throw 测例）→
批复测例 `a4e489c7`。test-exec 448/448（Debug）。
**driver 三问批复**：①立即 rebase 到 main（含 R9-N）并重测 delete-only 新对照线；
②**v1 只吃 EB**，`call_method`（deltablue）另开 v1.1——「leftover 体栈溢」写一页诊断
进简报附录，不在包压力下修；③整包不交付，序列=grok rebase+重测+AWAIT-MEASURE →
driver 跑 R-5 包验收 → 过线才合。

**R-5 第一轮终判（2026-08-14，@2cd1a927）：FAIL——内联未触发。**
case：N2 1.322 / N3 1.205（门 ≤1.05，≈delete-only 线）；头对头 pkg/delete-only N3 = **1.0274**
（比纯删还慢=只付探测成本）。合规面全绿（gate 0/49775 / ReleaseSafe / lint 0）——
非语义问题，机制未接通。诊断方向已下达（eligible 位/M 计数 key/特化安装/预算门）。
**新协议**：grok AWAIT-MEASURE 前必须自跑目标 case 性能冒烟（头对头 vs delete-only，
数字进回执；N3 ≤0.90 才够格提验收）——语义测试绿≠机制生效。
zoo 未跑（case 门先死，省下 CPU19）。main 侧 ReleaseSafe 套件自身失败（exit 1），
grok 报的 3 残留失败 pre-existing 分类成立方向，细节待补。

**排程注记（用户裁定 2026-08-14）：布局工程批不自动执行——队列行进到它时暂停，交用户决断。**

**R-5 第二轮前的 driver 定案（2026-08-14）——「删 OSR 不修 OSR」**：
grok BLOCKED 于 same-invocation jump 的 JSContext 泄漏。driver 评估：该 jump 是被
N3 case 形态（单次 `main(5e6)` 大循环）逼出的伪需求——**已核实 earley-boyer.js:991-993**，
最热 `new sc_Pair` 位于 `sc_cons(car,cdr)` 两行函数体内，每次构造=caller 全新进入，
**next-entry 特化对真靶足够**。定案：①删 jump+spare-locals（泄漏整体消失，帧尺寸须验证回原状）；
②泄漏存档附录 B「OSR hazard」不修不查；③case 载具修正 N2f/N3f（循环入函数、贴 EB 形态、
重定 delete-only 对照线、门 ≤1.05）；原 N2/N3 标注「OSR 场景 v1 不覆盖」；
④冒烟 N3f 头对头 ≤0.90 才回传；⑤R-1 16KB floor 批准；
⑥回传后 driver 先跑 **EB 单基准 A/B（真门，EB 收回 ≥2/3）**，过了才进全套 zoo。

## 4. 队列衔接

R9（真帧瘦身+apply 段）→ **R10（本批）** → R11 EB 命名桶 → R12 TS RC/frame →
布局工程批（SEQUENCED-LAST）。
`grok/opt-r6-k` 已拒收留档；DECISION-BRIEF-path-A-B 由通用性原则收编
（后续 B 类候选按 PERF-MECHANISM-LEDGER 四条件逐个申报）。
