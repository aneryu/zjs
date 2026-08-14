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

（bypass-off 定价基线：______ 待 `/tmp/bypass-ab/zoo.json` 填入。）

## 4. 队列衔接

R9（真帧瘦身+apply 段）→ **R10（本批）** → R11 EB 命名桶 → R12 TS RC/frame →
布局工程批（SEQUENCED-LAST）。
`grok/opt-r6-k` 已拒收留档；DECISION-BRIEF-path-A-B 由通用性原则收编
（后续 B 类候选按 PERF-MECHANISM-LEDGER 四条件逐个申报）。
