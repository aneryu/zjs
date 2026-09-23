# zjs / fun 统一路线图

版本:2.0；执行基线批准于 2026-08-26，工作项状态快照更新于 2026-09-06。
本文记录计划范围、依赖和决策；它不证明当前实现已交付。

**机器可读登记册**：[work-items.yaml](roadmap/work-items.yaml)。
§1/§5 是登记册的手维护摘要。GC 合入等历史结果见
[STATUS.md](../STATUS.md)；当前验证义务只由
[verification-policy.md](verification-policy.md)定义，已于 2026-09-18
废止的测量协议、预注册阈值和性能门槛不再约束执行。

## 0. Authority / Scope / Baseline

### 0.1 权威矩阵(按关注点划分,冲突只在同一关注点内比较)

| 关注点 | 权威来源 |
|---|---|
| 实现事实 | source、build graph、测试结果 |
| 发布与兼容状态 | `STATUS.md`、`COMPATIBILITY.md`、perf status |
| 是否实施、何时实施、硬依赖、产品决策 | `roadmap.md` + `work-items.yaml` |
| 验证与合并/发布门禁 | [verification-policy.md](verification-policy.md) |
| API、ABI、内存模型、语义合同 | 各领域规范文档(normative) |
| 已定价实现任务 | `backlog.md` |
| 历史论证与复盘 | process ledger(§20 系列)、git history |

- 本图可以裁决「PERF-P05 现在不做」;不能修改反馈槽的内存模型。
- 领域文档定义「做时怎么做」;不能自行把 gated 项改成立即执行。
- 本图作出新裁决时,须**同一 commit** 同步受影响领域文档正文
  (不是页首覆盖注,是单一现行正文)。
- 视角:统一路线图(zjs+fun);backlog.md 属地不变。

### 0.2 测量基线

BASE-G0 于 2026-08-26 完成；当时的二进制、编译器、套件和产物指纹在
`reports/evidence/BASE-G0/manifest.json`，tracing 基线 tag 为
`frozen/gc-tracing-2026-08-26`。这是历史证据，不能证明当前版本性能。
旧 `policies/` 文件已退役，原协议可从 Git 历史恢复；新调查按
[性能工作流](perf/README.md)保存与结论相称的证据。

### 0.3 基线批准记录

2026-08-26 的批准包含文档/Registry 规范化、BASE-G0、独立的
G1-FEEDBACK/G1-JIT 决策、FN-M0D 与 HR-P2 分拆，以及当时的分支规则。
详细批准清单保留在本文件 Git 历史。`roadmap-lint` 已退役；远端分支
保护和最新 CI 状态需按任务实时核实。

## 1. Canonical DAG(仅硬依赖与 activation,交付偏好与测量排队不在此图)

```
# hard dependencies (A + B -> C); gate conditions listed as activation
GC-GAP -> G1-GC
PERF-T-SPIKE -> G1-TYPED
PERF-DYN-SPIKE -> G1-FEEDBACK
PERF-JIT-SPIKE -> G1-JIT
PERF-N-SPIKE -> G1-AOT
G1-JIT + G1-AOT -> BACKEND-ORDER
GC-P3 -> G2-GC-MERGE
PERF-VMABI -> PERF-JIT-SPIKE
PERF-TYPED-IR + PERF-SHAPE-ID + PERF-OPCODE-SPACE -> PERF-T1
PERF-SHAPE-ID + PERF-SIDECAR + PERF-OPCODE-SPACE -> PERF-P05
PERF-VMABI + PERF-OPCODE-SPACE -> PERF-JIT
PERF-TYPED-IR + PERF-VMABI -> PERF-AOT
PERF-OPCODE-SPACE -> PERF-ASM-1A
PERF-ASM-1A + GC-MERGE -> PERF-ASM-1B
GC-MERGE -> VM-CONTRACT-GC
SER-CORE + PERF-OPCODE-SPACE -> SER-ARTIFACT
SER-CORE -> SER-SNAPSHOT
SER-CORE + SER-TRANSFER -> SER-MESSAGE
HR-P1 + RT-LIFECYCLE -> HR-P2A
HR-P2A + SER-SNAPSHOT -> HR-P2B
HR-P2A + PERF-SIDECAR -> HR-P3
FN-M0D + FN-M0I -> FN-M0F
FN-M0F + PERF-OPCODE-SPACE -> FN-M1A
FN-M1A + PERF-SHAPE-ID -> FN-M1B
FN-M1A + PERF-SIDECAR -> FN-M1C
FN-M1A + FN-M1B + FN-M1C -> FN-M2
FN-M2 -> FN-M3
FN-M3 + RT-LIFECYCLE -> FN-M4
FN-M4 -> FN-M5
FN-M5 + PERF-JIT -> FN-M6
SER-MESSAGE + GC-MULTIRT-GATE + VM-WEAK-REGISTRY -> PROC-D3
PROC-D3 + SER-ARTIFACT -> PROC-D4
RT-LIFECYCLE -> PROC-D5B
PROC-D4 -> PROC-D6
GC-MERGE -> PROC-D7

# activation conditions (non-DAG unlocks)
PERF-T-SPIKE: BASE-G0.done
PERF-DYN-SPIKE: BASE-G0.done
PERF-JIT-SPIKE: BASE-G0.done
PERF-N-SPIKE: BASE-G0.done
PERF-SHAPE-ID: G1-TYPED=implement | FN-M1A.done[nativeclass_slice_selected]
PERF-TYPED-IR: G1-TYPED=implement | G1-AOT=eligible
PERF-T1: G1-TYPED=implement
PERF-P05: G1-FEEDBACK≠disabled
PERF-JIT: G1-JIT=eligible & BACKEND-ORDER≠both_later
PERF-AOT: G1-AOT=eligible & BACKEND-ORDER≠both_later
GC-GAP: BASE-G0.done
GC-P3: G1-GC=continue
PROC-D7: G1-LIGHT-PROCESS-WORKLOAD=exists
```

以下为叙述性注释(非权威,权威=上方 DAG 与 yaml):

- 四 spike 技术独立;串行只是测量队列(§4)。JIT/AOT 是两 backend,
  typed 与反馈对 PERF-JIT 只是可选增强(不入硬依赖)。
- FN-M1B/FN-M1C 是并行分支,先后按产品价值排。
- RT-LIFECYCLE 是共享生命周期原语,消费者=PROC-D5B、HR-P2A、FN-M4
  (v1.8 起三条边全部入 DAG,防三线各自实现)。
- GC 链(v1.8 三拆:G2-GC-MERGE → VM-CONTRACT-GC → GC-MERGE)在
  v2.0 已按事实倒置:GC-MERGE 已完成(owner 2026-09-03 裁决,
  `f005aee7`),VM-CONTRACT-GC 现在硬依赖 GC-MERGE、是合入后的契约
  修订欠账;PROC-D7/PERF-ASM-1B 依赖的合入动作已满足。
- incubator(不在 active DAG):PERF-ASM-1A/PERF-ASM-1B(激活=
  iOS 执行窗口+GC 表示定型);P2 eval 缓存(typed v1.2,fun 真实
  负载达线后回归)。

## 2. Gates

**G1-FEEDBACK**(PERF-DYN-SPIKE 出数后裁,输出是**机制 profile**
不是 PASS/FAIL):

```yaml
selected_feedback_profile:
  mode: disabled | collect_only | monomorphic | pic2
  poison_policy: sliding_window
  polymorphic_arms: 0 | 2
  site_metadata_budget: <bytes/site>
```
若仅 PIC2 赢,须先修订 evolution 的 Phase 0.5 规范再实施。

**G1-JIT**(PERF-JIT-SPIKE 出数后裁:eligible | redesign | later)。
PERF-JIT-SPIKE 最小范围:8–12 个高频 opcode,覆盖数值循环/
call-heavy/property load/helper bailout/exception return/GC
safepoint;必须报告 steady-state speedup、compile latency、code
bytes/bytecode byte、entry/exit 成本、bailout 成本、break-even
hotness、code retirement、RW→RX 与 icache flush。核心决策量:

```
break_even_count = compile_cost /
                   (interpreter_cost_per_iter - jit_cost_per_iter)
```
break-even 须落在真实 workload 的热度范围内才有产品价值。

**G1-TYPED / G1-AOT / G1-GC / BACKEND-ORDER**:见
work-items.yaml 各决策卡。结论须有可复现证据，不得在出数后选择性
报告指标；已退役的预注册 policy 文件不再是开工前置。

**GC 合入记录**：G2-GC-MERGE 的候选/rc 非劣效协议未执行、无
verdict，已被 2026-09-03 owner「完成 tracing GC 与对象模型适配」裁决
取代。GC-P3/GC-MERGE 已完成；当前守卫见
[GC invariants](gc-invariants.md)，门禁见验证政策。

GC-PARALLEL-MARK 仍是计划项；S4b 并行标记曾落地、后在 TGC 合入时
撤回，不能当作已有实现。旧吞吐/停顿和内存包络论证保留在 Git 历史，
重开时须对当前机制重新取证。VM-CONTRACT-GC 是合入后的契约修订项。

**PERF-SHAPE-ID 合同形态(已裁)**:双域——动态可变 shape 用 u64
identity/version(mutation/relocation/ABA;**计数器作用域=
per-Runtime**,v1.8:artifact 只存引用表索引,identity 比较仅同
Runtime 内有效);typed/NativeClass 的 immutable canonical shape
允许 pinned-pointer guard(生命周期钉住、无 transition、不跨
Runtime、teardown 前统一失效)。T-spike 双臂对比,不预设全场景走 u64。

**v1.8 新增裁决**:①**FNABI finalizer 三态=方案 B**——插件
destructor reason-independent 幂等,无 FunFinalizeReason;三态只
控制 runtime 的调度/等待/堆外收尾,退出策略归 begin_shutdown/
CancellationToken/AsyncOperation(FNABI v0.6 已裁,process v0.6
同步撤回合同扩展要求);②**side-by-side NativeImage 移入 post-v1
incubator**——v1 = plugin artifact 变化→Worker Restart 单线,
FN-M0F 不冻结 side-by-side 语义(FNABI §22.7 v0.6);③GC 链曾拆为统计门、契约修订与合入动作，v2.0 的现行依赖见 §1;④三个隐藏前置升正式工作项:SER-TRANSFER、
GC-MULTIRT-GATE、VM-WEAK-REGISTRY;PROC-D7 的价值门升为
G1-LIGHT-PROCESS-WORKLOAD。

## 3. Now / Next / Later

**Now(遵守 §4 WIP)**
```
owner-decision: PERF-OPCODE-SPACE(driver 会话)**已升为最高优先级
                前置项**(owner 裁决 2026-08-27 第二次):范围从
                「编号/命名空间方案」扩为**整套指令集重新设计**,参照
                V8/JSC/Hermes。⏸ **增量回收执行暂停**,停在 9 个编号
                (245 在用/11 空闲);剩余清单仍作输入保留但不执行。
                **单一现行文本 = `docs/perf/opcode-design.md`**(已合并
                取代 08-27 的三份工作文档;逐条数据在
                opcode-audit-table.md)。**§1 四项已全部裁定(owner 裁决
                2026-08-27 第三次)**:①声明源+生成器批准,是下一件开工
                的事;②register-vs-stack spike 缓议,生成器落地后复议
                (方案 B 保持可评估);③qjs 代码级对齐**降为工具**——
                仍是性能尺,逐行对照不再约束解释器核心;④回收清单维持
                全暂停。下游凡是编码/编译/
                序列化/手写 opcode 的项现在都硬依赖本项:PERF-T1、
                FN-M1A、PERF-P05、PERF-JIT、PERF-ASM-1A、SER-ARTIFACT。
                FN-M0F 已裁并冻结(2026-08-26,FNABI v0.8+表示契约 v2)
implementation: (GC-P3 已 done,v2.0:GC 线 2026-09-05 在 main 收官,
                槽位释放;owner 2026-09-05 裁决 TS/AOT「顺延不取消」,
                先清 GC 余项与迭代效率,两者 2026-09-06 均已关门)
                PERF-T-SPIKE **重开**(driver 会话):08-26 的 FAIL 判定
                08-27 撤回——受控 demo 证明首轮负载(混浮点)会完全
                掩盖该机制,属性密集负载重测得 +8.9%/+15.7%,越过
                杀标;⚠️多态站点各轮均倒退 6.4%。**G1-TYPED 退回
                blocked**,待真实套件读数(须先把站点索引从 u8 扩到
                u16);证据 reports/evidence/PERF-T-SPIKE/
measurement:    (该快照中为空；下一项调查是 PERF-T-SPIKE。旧预注册
                policy 阈值已于 2026-09-18 退役)
```

GC/driver 的双会话分工随 `gc/tracing` 分支退役，不再适用。
HR-P1 的 GC 耦合前置已在 2026-09-05 收敛；其余调度按登记册和 WIP
安排。旧 GC-GAP 数字与修正过程见 Git 历史及
[归因勘误](../reports/evidence/GC-GAP/ERRATA-2026-08-29.md)，不作为现行基线。

**证据购买(implementation slot 释放后;测量队列串行)**
```
GC-GAP → PERF-T-SPIKE → PERF-DYN-SPIKE → PERF-JIT-SPIKE
       → PERF-N-SPIKE
各 gate 出数即裁,互不等待;四份 spike 阈值曾预注册后随
2026-09-18 测量政策退役从树中移除(从 git 历史恢复)
```

**Gate 后分叉(不预设完整路径必做)**
```
T-spike 过 → PERF-T1;Feedback 过 → PERF-P05;
JIT-spike 过 → PERF-JIT;N-spike 过 → PERF-AOT;
JIT/AOT 双 eligible 时按产品价值排序:
  产品覆盖率 × 热路径占比 × 实测 speedup ÷ owner 人日
  − 体积/构建时间/边界成本/平台限制
```

**并行可启(WIP 有空位)**:SER-CORE、PERF-SIDECAR、DBG-W2、
PROC-D5A、RT-LIFECYCLE。(PERF-OPCODE-SPACE 已不在此列——它占
owner-decision 槽且是最高优先级前置项,见上。)

**Later**:SER 三 profile 下游、FN-M1A→M1B/M1C、HR-P2A/P2B/P3、
PROC-D3→D4→D6、VM-CONTRACT-GC(合入后欠账)→PROC-D7、
FN-M2..M6。SER-TRANSFER/GC-MULTIRT-GATE/VM-WEAK-REGISTRY 随 WIP
空位安插(均 ready);G1-LIGHT-PROCESS-WORKLOAD 的负载表调查可
提前做。

## 4. WIP limits and execution protocol

```
最多 1 个 owner-decision item
最多 2 个 implementation items(spike 占 implementation slot)
最多 1 个后台 measurement item(spike 官方 A/B 期兼占)
```

调查取证遵循 [perf/README.md](perf/README.md)，避免共享资源干扰。
测量与 ablation 政策已于 2026-09-18 退役；上述 WIP 是计划调度约定，
不是测量或合并门禁。

欠账入口:[process ledger §20.2/§20.2a](process-model-design.md);
动工规则:先改文档递增版本,再动代码。WIP 限额由 owner 执行,不再
走 CI lint。

## 5. 工作项登记册

登记册的完整数据在 [`work-items.yaml`](roadmap/work-items.yaml)
(schema v2:type/state/wip_slot/activation/hard_prerequisites/
deliverables/acceptance/authority;gate 声明 verdicts)。

```
治理       BASE-DOC-NORM BASE-ROADMAP-LINT BASE-G0
gates    G1-GC G1-TYPED G1-FEEDBACK G1-JIT G1-AOT BACKEND-ORDER G2-GC-MERGE G1-LIGHT-PROCESS-WORKLOAD
性能       PERF-T-SPIKE PERF-DYN-SPIKE PERF-JIT-SPIKE PERF-N-SPIKE PERF-VMABI PERF-OPCODE-SPACE PERF-SHAPE-ID PERF-SIDECAR PERF-TYPED-IR PERF-T1 PERF-P05 PERF-JIT PERF-AOT PERF-ASM-1A PERF-ASM-1B
GC       GC-GAP GC-P3 VM-CONTRACT-GC GC-MERGE GC-PARALLEL-MARK GC-MULTIRT-GATE
序列化      SER-CORE SER-TRANSFER SER-ARTIFACT SER-SNAPSHOT SER-MESSAGE
fun 面    HR-P1 HR-P2A HR-P2B HR-P3 DBG-W2 FN-M0D FN-M0I FN-M0F FN-M1A FN-M1B FN-M1C FN-M2 FN-M3 FN-M4 FN-M5 FN-M6
运行时/进程   RT-LIFECYCLE VM-WEAK-REGISTRY PROC-D3 PROC-D4 PROC-D5A PROC-D5B PROC-D6 PROC-D7
```

```
now        PERF-T-SPIKE PERF-OPCODE-SPACE
ready      G1-LIGHT-PROCESS-WORKLOAD PERF-DYN-SPIKE PERF-N-SPIKE PERF-VMABI PERF-SIDECAR VM-CONTRACT-GC SER-CORE SER-TRANSFER HR-P1 DBG-W2 RT-LIFECYCLE GC-PARALLEL-MARK GC-MULTIRT-GATE VM-WEAK-REGISTRY PROC-D5A
gated      PERF-SHAPE-ID PERF-TYPED-IR PERF-T1 PERF-P05 PERF-JIT PERF-AOT
blocked    G1-TYPED G1-FEEDBACK G1-JIT G1-AOT BACKEND-ORDER PERF-JIT-SPIKE SER-ARTIFACT SER-SNAPSHOT SER-MESSAGE HR-P2A HR-P2B HR-P3 FN-M1A FN-M1B FN-M1C PROC-D3 PROC-D4 PROC-D5B PROC-D6 PROC-D7
later      FN-M2 FN-M3 FN-M4 FN-M5 FN-M6
incubator  PERF-ASM-1A PERF-ASM-1B
done       BASE-DOC-NORM BASE-ROADMAP-LINT BASE-G0 G1-GC G2-GC-MERGE GC-GAP GC-P3 GC-MERGE FN-M0D FN-M0I FN-M0F
```
