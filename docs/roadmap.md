# zjs / fun 统一路线图

版本:1.7  
日期:2026-08-26  
状态:执行总纲候选。v1.7 = 治理收敛版(BASE-DOC-NORM 正文归一化 +
BASE-ROADMAP-LINT 机器化;权威矩阵、DAG 闭合、Gate 闭合、Registry
机器化),无新增设计。转 **approved execution baseline** 的硬条件
见 §0.3。

**机器可读 source of truth**:
[`docs/roadmap/work-items.yaml`](roadmap/work-items.yaml)——本文的
ID 表、DAG 与状态是它的视图;一致性由
[`tools/docs/roadmap_lint.py`](../tools/docs/roadmap_lint.py) 在 CI
校验(ID 唯一/前置存在/无环/状态一致/gate 有卡/spike 有 policy/
authority 存在/双向 ID 引用/退役短语扫描)。

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
[ ] BASE-DOC-NORM 完成(正文无相反裁决;退役短语 lint 绿)
[ ] BASE-ROADMAP-LINT 进入 CI
[ ] BASE-G0 完成(tracing 公开 ref、yardstick 冻结、
    gc_merge_policy.json、四份 spike policy 落地)
[ ] Canonical DAG 只含硬依赖;所有节点在 Registry;隐藏前置有 ID
    或入 acceptance checklist
[ ] G1-FEEDBACK 与 G1-JIT 分离;PERF-JIT-SPIKE 定义完成(已在 v1.7)
[ ] FN-M0D freeze blockers 完成分类(FNABI v0.5)
[ ] HR-P2A/P2B 拆分(hot-reload v1.5)
[ ] STATUS.md 登记当前 roadmap 版本与 approval 状态
```

## 1. Canonical DAG(仅硬依赖;交付偏好与测量排队不在此图)

```
治理
  BASE-DOC-NORM ──→ BASE-ROADMAP-LINT
  BASE-G0 ──→ 所有正式 evidence

性能证据(四 spike 技术独立)
  BASE-G0 ──→ PERF-T-SPIKE ──→ G1-TYPED
  BASE-G0 ──→ PERF-DYN-SPIKE ──→ G1-FEEDBACK
  BASE-G0 + PERF-VMABI ──→ PERF-JIT-SPIKE ──→ G1-JIT
  BASE-G0 ──→ PERF-N-SPIKE ──→ G1-AOT
  G1-JIT + G1-AOT ──→ BACKEND-ORDER

Typed
  G1-TYPED=implement 或 G1-AOT=eligible ──→ PERF-TYPED-IR
  G1-TYPED=implement + PERF-TYPED-IR + PERF-SHAPE-ID
    + PERF-OPCODE-SPACE ──→ PERF-T1

动态反馈
  G1-FEEDBACK≠disabled + PERF-SHAPE-ID + PERF-SIDECAR ──→ PERF-P05
  (acceptance checklist:08-17 IC 否证对账、GC 线同桌评审)

JIT / AOT(两 backend;typed 与反馈对 JIT 只是可选增强)
  G1-JIT=eligible + PERF-VMABI ──→ PERF-JIT
  PERF-P05 ──optional──→ PERF-JIT
  PERF-TYPED-IR ──optional──→ PERF-JIT
  G1-AOT=eligible + PERF-TYPED-IR + PERF-VMABI ──→ PERF-AOT

FNABI
  FN-M0D ──→ FN-M0F ←── FN-M0I
  FN-M0F + PERF-OPCODE-SPACE ──→ FN-M1A
  FN-M1A + PERF-SHAPE-ID ──→ FN-M1B     (M1B/M1C 并行分支,
  FN-M1A + PERF-SIDECAR  ──→ FN-M1C      先后按产品价值排)
  FN-M1A + FN-M1B + FN-M1C ──→ FN-M2 ──→ FN-M3 ──→ FN-M4 ──→ FN-M5
  FN-M5 + PERF-JIT ──→ FN-M6

Hot Reload / 调试
  HR-P1 ──→ HR-P2A
  HR-P2A + SER-SNAPSHOT ──→ HR-P2B
  HR-P2A + PERF-SIDECAR ──→ HR-P3
  DBG-W2:无硬前置

序列化
  SER-CORE ──→ SER-ARTIFACT / SER-SNAPSHOT / SER-MESSAGE

进程 / 运行时生命周期
  SER-MESSAGE ──→ PROC-D3
  PROC-D3 + SER-ARTIFACT ──→ PROC-D4 ──→ PROC-D6
  PROC-D5A:无硬前置
  RT-LIFECYCLE ──→ PROC-D5B
  (RT-LIFECYCLE 同为 HR-P2A 与 FNABI shutdown 的共享原语)
  GC-MERGE ──→ PROC-D7(checklist:契约修订、分档裁决、负载表)

GC
  BASE-G0 ──→ GC-GAP ──→ G1-GC
  G1-GC=continue ──→ GC-P3 ──→ GC-MERGE
```

incubator(不在 active DAG):PERF-ASM-1A/PERF-ASM-1B(evolution
Phase 1A/1B;激活=iOS 执行窗口打开+GC 表示定型);P2 eval 缓存
(typed plan v1.1,fun 真实负载达线后回归)。

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

parallel marking = pause/扩展性选项,非吞吐补救。吞吐三角三选一
在 G1-GC 裁,论证存 process ledger §20.2a。Track B 定性:最大架构
风险退休项与表示定型点,非产品交付解锁器。

**PERF-SHAPE-ID 合同形态(已裁)**:双域——动态可变 shape 用 u64
identity/version(mutation/relocation/ABA);typed/NativeClass 的
immutable canonical shape 允许 pinned-pointer guard(生命周期钉住、
无 transition、不跨 Runtime、teardown 前统一失效)。T-spike 双臂
对比,不预设全场景走 u64。

## 3. Now / Next / Later

**Now(遵守 §4 WIP)**
```
owner-decision: BASE-G0(完成后进 FN-M0D)
implementation: HR-P1 · FN-M0I(仅非争议骨架,不执行 freeze)
(BASE-DOC-NORM/BASE-ROADMAP-LINT 随本版落地)
```

**证据购买(implementation slot 释放后;测量队列串行)**
```
GC-GAP → PERF-T-SPIKE → PERF-DYN-SPIKE → PERF-JIT-SPIKE
       → PERF-N-SPIKE
各 gate 出数即裁,互不等待
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
PROC-D3→D4→D6、GC-MERGE→PROC-D7、FN-M2..M6。

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
(每项:type/state/activation/hard_prerequisites/deliverables/
acceptance/authority)。全部 ID:

```
治理     BASE-DOC-NORM BASE-ROADMAP-LINT BASE-G0
gates    G1-GC G1-TYPED G1-FEEDBACK G1-JIT G1-AOT BACKEND-ORDER
性能     PERF-T-SPIKE PERF-DYN-SPIKE PERF-JIT-SPIKE PERF-N-SPIKE
         PERF-VMABI PERF-OPCODE-SPACE PERF-SHAPE-ID PERF-SIDECAR
         PERF-TYPED-IR PERF-T1 PERF-P05 PERF-JIT PERF-AOT
GC       GC-GAP GC-P3 GC-MERGE
序列化   SER-CORE SER-ARTIFACT SER-SNAPSHOT SER-MESSAGE
fun 面   HR-P1 HR-P2A HR-P2B HR-P3 DBG-W2
         FN-M0D FN-M0I FN-M0F FN-M1A FN-M1B FN-M1C
         FN-M2 FN-M3 FN-M4 FN-M5 FN-M6
运行时   RT-LIFECYCLE PROC-D3 PROC-D4 PROC-D5A PROC-D5B
         PROC-D6 PROC-D7
```

状态速览(与 yaml 同步;lint 校验一致性):**now** = HR-P1、
FN-M0I、BASE-DOC-NORM、BASE-ROADMAP-LINT;**ready** = BASE-G0、
FN-M0D、四 spike 中三个(PERF-JIT-SPIKE 等 PERF-VMABI)、
PERF-VMABI、PERF-OPCODE-SPACE、PERF-SIDECAR、SER-CORE、DBG-W2、
PROC-D5A、RT-LIFECYCLE、GC-GAP;其余 gated/blocked/later 见 yaml。
