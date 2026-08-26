# zjs / fun 统一路线图

版本:1.9  
日期:2026-08-26  
状态:**approved execution baseline**(§0.3 硬条件 2026-08-26 全数
达成;owner 同日批复 qjs 尺裁定与 required-checks ruleset)。
v1.9 = BASE-G0 测量冻结完成(官方 qjs 尺裁定、三枚 zjs 冻结二进制、
套件逐 case 指纹、tracing 公开 tag、gc_merge_policy + 四份 spike
policy 预注册、evidence 登记册落地),无新增设计。v1.8 = 语义闭合 +
可执行 Registry。

**机器可读 source of truth**:
[`docs/roadmap/work-items.yaml`](roadmap/work-items.yaml)(schema v2)
——本文 §1/§5 的 ID 表、DAG 与状态是**生成区段**,由
[`tools/docs/render_roadmap.py`](../tools/docs/render_roadmap.py)
渲染;[`tools/docs/roadmap_lint.py`](../tools/docs/roadmap_lint.py)
在 CI 校验 schema/结构化 activation(verdict 须为 gate 声明的枚举)/
无环/状态一致/WIP 限额/双向 ID 引用/退役短语/生成区段无 diff。

## 0. Authority / Scope / Baseline

### 0.1 权威矩阵(按关注点划分,冲突只在同一关注点内比较)

| 关注点 | 权威来源 |
|---|---|
| 实现事实 | source、build graph、测试结果 |
| 发布与兼容状态 | `STATUS.md`、`COMPATIBILITY.md`、perf status |
| 是否实施、何时实施、硬依赖、gate | `roadmap.md` + `work-items.yaml` |
| API、ABI、内存模型、语义合同 | 各领域规范文档(normative) |
| 已定价实现任务 | `backlog.md` |
| 历史论证与复盘 | process ledger(§20 系列)、git history |

- 本图可以裁决「PERF-P05 现在不做」;不能修改反馈槽的内存模型。
- 领域文档定义「做时怎么做」;不能自行把 gated 项改成立即执行。
- 本图作出新裁决时,须**同一 commit** 同步受影响领域文档正文
  (不是页首覆盖注,是单一现行正文)——由退役短语 lint 兜底。
- 视角:统一路线图(zjs+fun);backlog.md 属地不变。

### 0.2 测量基线警示

BASE-G0 完成前,一切吞吐/pause 数字是本地决策输入,非可复现项目
事实。BASE-G0 只阻塞证据线**官方结果**,不阻塞产品线。BASE-G0 交付
定义(全量):

```
1. QuickJS: commit / compiler / build flags / binary SHA-256 /
   可复现构建 recipe
2. zjs: merge-base 与 candidate commit / binary SHA-256 / dirty=false
3. suite: Octane revision / 每 case source hash / skip policy
4. tracing: 公开可解析的 immutable tag 或 commit(不是本地分支名)
5. policies: measurement_policy.json hash / gc_merge_policy.json /
   四份 spike policy 文件(预注册 kill criteria:primary_metric /
   target_workloads / minimum_effect / maximum_regression /
   correctness_gates / size 与 cost limit / sample_protocol /
   pass-redesign-fail 三态)
6. evidence: reports/evidence/<ITEM>/ 目录;每份 manifest 含
   work_item / commits / binary_sha256 / toolchain / policy_sha256 /
   host / command / raw_artifacts / result / verdict / owner_decision
```

### 0.3 转 approved execution baseline 的硬条件

```
[x] BASE-DOC-NORM 完成(v1.8;退役短语 lint 绿)
[x] BASE-ROADMAP-LINT 进入 CI(af238c7c;v1.8 起含生成区段校验)
[x] BASE-G0 完成(v1.9;tracing 公开 tag `frozen/gc-tracing-2026-08-26`、
    yardstick 裁定=GCC-16 qjs、gc_merge_policy.json + 四份 spike
    policy 预注册、evidence 登记册;详见
    reports/evidence/BASE-G0/manifest.json)
[x] Canonical DAG 由 Registry 生成,只含硬依赖;隐藏前置全部有 ID
[x] G1-FEEDBACK 与 G1-JIT 分离;PERF-JIT-SPIKE 定义完成(v1.7)
[x] FN-M0D freeze blockers 完成分类(FNABI v0.5;finalizer 已裁 v0.6)
[x] HR-P2A/P2B 拆分(hot-reload v1.5)
[x] STATUS.md 登记当前 roadmap 版本与 approval 状态(v1.9)
[x] main branch ruleset(owner 批复 2026-08-26):
    `main-no-force-push`(禁 force-push/删除,无 bypass)+
    `main-required-checks`(required checks = roadmap-lint /
    linux-arm64 / linux-x86_64;repository-admin bypass=always,
    保全 owner 直推 main 的现行工作流;macOS/Windows smoke 维持
    advisory)
```

## 1. Canonical DAG(由 Registry 生成;仅硬依赖与 activation,
交付偏好与测量排队不在此图)

<!-- BEGIN GENERATED: DAG -->
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
PERF-SHAPE-ID + PERF-SIDECAR -> PERF-P05
PERF-VMABI -> PERF-JIT
PERF-TYPED-IR + PERF-VMABI -> PERF-AOT
PERF-ASM-1A + GC-MERGE -> PERF-ASM-1B
VM-CONTRACT-GC -> GC-MERGE
SER-CORE -> SER-ARTIFACT
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
VM-CONTRACT-GC: G2-GC-MERGE=pass
PROC-D7: G1-LIGHT-PROCESS-WORKLOAD=exists
```
<!-- END GENERATED: DAG -->

以下为叙述性注释(非权威,权威=上方生成区段与 yaml):

- 四 spike 技术独立;串行只是测量队列(§4)。JIT/AOT 是两 backend,
  typed 与反馈对 PERF-JIT 只是可选增强(不入硬依赖)。
- FN-M1B/FN-M1C 是并行分支,先后按产品价值排。
- RT-LIFECYCLE 是共享生命周期原语,消费者=PROC-D5B、HR-P2A、FN-M4
  (v1.8 起三条边全部入 DAG,防三线各自实现)。
- GC 链三拆(v1.8):G2-GC-MERGE(统计 gate)→ VM-CONTRACT-GC
  (契约修订,独立 review)→ GC-MERGE(合入动作);PROC-D7 依赖的
  是合入动作。
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
work-items.yaml 各 gate 卡。所有 spike 开工前须有预注册 policy
文件(§0.2 条 5),不得在结果出来后择优选指标。

**GC 合入 gate(gc_merge_policy.json 为准,本节为其规格)**:

```
primary safety: candidate/rc paired log-ratio 的单侧 95% 非劣效
  置信下界 ≥ 冻结 margin
primary benefit: 每次候选只预注册一个(如 P3 选 major pause p99
  或 cumulative STW p99);其余指标描述性报告或做多重比较校正
pause 统计:每 run 先聚合(p50/p95/p99/max/cumulative STW),
  比较用 run 级指标——GC event 不作独立样本(伪重复)
looks: n=8 → 16 → 32 终局;n=32 仍跨 margin = INCONCLUSIVE →
  不允许合入、保留分支,仅当测量环境或机制实质变化后重开
sequential control: 预冻结 alpha-spending / confidence sequence
activation canary(最小机制覆盖量,冻结在 policy 里):
  minimum_major_cycles_per_sample、minimum marked/allocated bytes、
  minimum swept bytes、minimum gc_active_time_share、每个 GC-heavy
  workload 的独立触发要求;collector mode/policy digest 一致;
  growth factor 一致;测量/测试/发布配置一致;pause timer 不含 census
正确性:四门全绿(单测双模式 + test262 双向)
```

吞吐三角已裁(2026-08-26,G1-GC/Option B,记录在
gc_merge_policy.json v2):**parallel marking 升正式计划项
(GC-PARALLEL-MARK,GC 会话车道)**,内存包络维持 growth 1.75x /
cycle peak-over-live 1.8(方案 A 定价证伪:1.75→2.5x 只赎回约 1/3
gap);分层判据(方案 C)弃,与「GC 打磨好才合入」常任裁决一致。
Track B 定性:最大架构风险退休项与表示定型点,非产品交付解锁器。

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
FN-M0F 不冻结 side-by-side 语义(FNABI §22.7 v0.6);③GC 链三拆:
G2-GC-MERGE(统计 gate)→VM-CONTRACT-GC(契约修订独立 review)→
GC-MERGE(合入动作);④三个隐藏前置升正式工作项:SER-TRANSFER、
GC-MULTIRT-GATE、VM-WEAK-REGISTRY;PROC-D7 的价值门升为
G1-LIGHT-PROCESS-WORKLOAD。

## 3. Now / Next / Later

**Now(遵守 §4 WIP)**
```
owner-decision: PERF-OPCODE-SPACE(driver 会话)。FN-M0F 已裁并冻结
                (2026-08-26,FNABI v0.8+表示契约 v2);FN-M1A 只剩等
                PERF-OPCODE-SPACE
implementation: GC-P3(GC 专属会话,分支 gc/tracing,不碰 main);
                driver 侧一槽**空置——owner 定夺中**(候选:
                PERF-T-SPIKE / HR-P1 / RT-LIFECYCLE 等,见讨论)
measurement:    (空;队列下一位 = PERF-T-SPIKE,占 implementation
                槽,开工前须批 policy 中 basis=proposed 阈值)
```

**双会话分工(2026-08-26 入册)**:GC 线(gc/tracing 分支、GC-P3、
两笔 GC-GAP 归因债、pause plan 文档)= GC 专属会话;其余全部
(治理/registry、FN/HR/SER 线、spike 与测量队列、evidence 登记册、
G2 合入 gate 的统计机器)= driver 会话。G1-GC 已裁 continue
(GC-GAP 账在案:fixed-work geomean 1.206、suite 0.832、splay pause
p99 6.87ms vs rc 42.4ms、splay RSS 3.63x;裁决时欠账=非劣效 margin
与吞吐三角答案,须在 G2 首个 look 前写入 gc_merge_policy.json)。
HR-P1 让出 WIP 槽排队(root-handle 与 GC 耦合,亦宜等 GC 线收敛)。

**证据购买(implementation slot 释放后;测量队列串行)**
```
GC-GAP → PERF-T-SPIKE → PERF-DYN-SPIKE → PERF-JIT-SPIKE
       → PERF-N-SPIKE
各 gate 出数即裁,互不等待;四份 spike policy 已预注册
(policies/spikes/,basis=proposed 的阈值开工前须 owner 批)
```

**Gate 后分叉(不预设完整路径必做)**
```
T-spike 过 → PERF-T1;Feedback 过 → PERF-P05;
JIT-spike 过 → PERF-JIT;N-spike 过 → PERF-AOT;
JIT/AOT 双 eligible 时按产品价值排序:
  产品覆盖率 × 热路径占比 × 实测 speedup ÷ owner 人日
  − 体积/构建时间/边界成本/平台限制
```

**并行可启(WIP 有空位)**:SER-CORE、PERF-SIDECAR、
PERF-OPCODE-SPACE、DBG-W2、PROC-D5A、RT-LIFECYCLE。

**Later**:SER 三 profile 下游、FN-M1A→M1B/M1C、HR-P2A/P2B/P3、
PROC-D3→D4→D6、G2-GC-MERGE→VM-CONTRACT-GC→GC-MERGE→PROC-D7、
FN-M2..M6。SER-TRANSFER/GC-MULTIRT-GATE/VM-WEAK-REGISTRY 随 WIP
空位安插(均 ready);G1-LIGHT-PROCESS-WORKLOAD 的负载表调查可
提前做。

## 4. WIP limits and execution protocol

```
最多 1 个 owner-decision item
最多 2 个 implementation items(spike 占 implementation slot)
最多 1 个后台 measurement item(spike 官方 A/B 期兼占)
```

测量队列串行,守 [perf/README.md](perf/README.md) measurement
contract + BASE-G0 policies;官方读数前必查孤儿+亲和。

欠账入口:[process ledger §20.2/§20.2a](process-model-design.md);
动工规则:先改文档递增版本,再动代码。CI 运行
`python3 tools/docs/roadmap_lint.py`;lint 失败=治理缺陷,与测试
失败同级。

## 5. 工作项登记册

登记册的完整数据在 [`work-items.yaml`](roadmap/work-items.yaml)
(schema v2:type/state/wip_slot/activation/hard_prerequisites/
deliverables/acceptance/authority;gate 声明 verdicts)。

<!-- BEGIN GENERATED: ID-LIST -->
```
治理       BASE-DOC-NORM BASE-ROADMAP-LINT BASE-G0
gates    G1-GC G1-TYPED G1-FEEDBACK G1-JIT G1-AOT BACKEND-ORDER G2-GC-MERGE G1-LIGHT-PROCESS-WORKLOAD
性能       PERF-T-SPIKE PERF-DYN-SPIKE PERF-JIT-SPIKE PERF-N-SPIKE PERF-VMABI PERF-OPCODE-SPACE PERF-SHAPE-ID PERF-SIDECAR PERF-TYPED-IR PERF-T1 PERF-P05 PERF-JIT PERF-AOT PERF-ASM-1A PERF-ASM-1B
GC       GC-GAP GC-P3 VM-CONTRACT-GC GC-MERGE GC-PARALLEL-MARK GC-MULTIRT-GATE
序列化      SER-CORE SER-TRANSFER SER-ARTIFACT SER-SNAPSHOT SER-MESSAGE
fun 面    HR-P1 HR-P2A HR-P2B HR-P3 DBG-W2 FN-M0D FN-M0I FN-M0F FN-M1A FN-M1B FN-M1C FN-M2 FN-M3 FN-M4 FN-M5 FN-M6
运行时/进程   RT-LIFECYCLE VM-WEAK-REGISTRY PROC-D3 PROC-D4 PROC-D5A PROC-D5B PROC-D6 PROC-D7
```
<!-- END GENERATED: ID-LIST -->

<!-- BEGIN GENERATED: STATUS -->
```
now        PERF-OPCODE-SPACE GC-P3
ready      G1-LIGHT-PROCESS-WORKLOAD PERF-T-SPIKE PERF-DYN-SPIKE PERF-N-SPIKE PERF-VMABI PERF-SIDECAR SER-CORE SER-TRANSFER HR-P1 DBG-W2 RT-LIFECYCLE GC-PARALLEL-MARK GC-MULTIRT-GATE VM-WEAK-REGISTRY PROC-D5A
gated      PERF-SHAPE-ID PERF-TYPED-IR PERF-T1 PERF-P05 PERF-JIT PERF-AOT VM-CONTRACT-GC
blocked    G1-TYPED G1-FEEDBACK G1-JIT G1-AOT BACKEND-ORDER G2-GC-MERGE PERF-JIT-SPIKE GC-MERGE SER-ARTIFACT SER-SNAPSHOT SER-MESSAGE HR-P2A HR-P2B HR-P3 FN-M1A FN-M1B FN-M1C PROC-D3 PROC-D4 PROC-D5B PROC-D6 PROC-D7
later      FN-M2 FN-M3 FN-M4 FN-M5 FN-M6
incubator  PERF-ASM-1A PERF-ASM-1B
done       BASE-DOC-NORM BASE-ROADMAP-LINT BASE-G0 G1-GC GC-GAP FN-M0D FN-M0I FN-M0F
```
<!-- END GENERATED: STATUS -->
