# zjs / fun 统一路线图

版本:1.6  
日期:2026-08-26  
状态:执行总纲候选(领域文档已同步:evolution v0.5 / typed v1.0 /
FNABI v0.4 / hot-reload v1.4 / process v0.4;G0 落地后转
approved execution baseline)  
v1.5 = 外部复审 8.2/10 后修订:领域文档同步、PERF-DYN-SPIKE 补位、
Gate 1 拆四独立 gate、DAG 补全并与测量队列分离、GC 统计合同闭合、
全局 ID 贯彻。v1.6 = 增设 §5 工作项登记册(每 ID 一张卡片,本图
成为自足单入口;登记册是摘要+指针,不产生新裁决,子文档仍为规范
权威)。

## 0. Authority / Scope / Baseline

**权威层级**(高者胜出;冲突即缺陷,发现即修):

```
可执行仓库状态 / STATUS.md
  > roadmap.md 的状态、排序、依赖与裁决
    > 领域设计文档的语义与实现规范
      > backlog.md 的已定价实现队列
        > 历史评审记录(process-model-design.md §20 系列为账本)
```

- 领域文档定「怎么做」;本图定「是否做、何时做、等待什么」。
- 本图作出新裁决时,须在**同一 commit** 同步受影响领域文档。
- 视角:统一路线图(zjs+fun);fun 侧工作项入图排序,规范以热更/
  FNABI 文档为权威;backlog.md 属地不变。
- **测量基线警示**:BASE-G0 完成前,一切吞吐/pause 数字是本地决策
  输入,不是可公开复现的项目事实。BASE-G0 只阻塞**证据线的官方
  结果**,不阻塞产品线(HR-P1/FN-M0 不依赖 reference binary 或
  tracing commit)。

**全局工作项 ID 表**(跨文档讨论一律用 ID):

```
BASE-G0        测量冻结(qjs/suite/binary 指纹、tracing 可解析
               commit、evidence ID、margin、gc_merge_policy.json)
GC-GAP         全量口径 RC vs tracing A/B
GC-P3          lazy sweep + 吞吐税回收
PERF-T-SPIKE   typed slot 解释器收益(含多态臂)
PERF-DYN-SPIKE 动态反馈最小证据(定义见 §2)
PERF-N-SPIKE   原生 Zig AOT 形态(边界成本+GC/异常闭环)
PERF-VMABI     VmExecState/HelperDescriptor/异常与中断协议/
               GC slot 抽象(evolution Phase 0)
PERF-SHAPE-ID  shape 稳定身份(typed F1)
PERF-SIDECAR   SidecarCore 容器协议 + 站点侧表载体(typed F2 载体)
PERF-TYPED-IR  类型证书/typed metadata/布局引用(typed F3/F5)
PERF-P05       解释器级反馈槽(evolution Phase 0.5)
PERF-JIT       baseline JIT backend
PERF-AOT       原生 AOT backend(Zig 源码发射)
SER-CORE       序列化编码内核 spec + 三 profile 边界
SER-ARTIFACT   字节码 artifact profile(=热更 W1)
SER-SNAPSHOT   状态快照 profile(热更 §27.9/§15)
SER-MESSAGE    进程消息 profile(SC 值器+三通道)
HR-P1/P2/P3    热更阶段 1/2/3
FN-M0/M1A/M1B/M1C/M2..M6  FNABI 里程碑(v0.4 §33)
DBG-W2         最小 CDP backend
PROC-D3/D4/D5/D6/D7       进程模型交付(process v0.4 §16.3)
```

## 1. Canonical DAG(硬依赖,完整列出;交付序/测量序不在此图)

```
产品线(无 BASE-G0 依赖)
  HR-P1 ──→ HR-P2
  FN-M0 ──→ FN-M1A ──→ FN-M1B ──→ FN-M1C     (交付序)
  DBG-W2(独立,WIP 有空位即可启动)

证据线(三 spike 技术上互相独立;串行只是测量队列,见 §4)
  BASE-G0 ──→ GC-GAP / PERF-T-SPIKE / PERF-DYN-SPIKE /
              PERF-N-SPIKE 的官方结果

基础设施
  PERF-VMABI ───────────────→ PERF-JIT
  动态反馈(经 G1-JIT)─────→ PERF-JIT
  PERF-SHAPE-ID ─┬──────────→ PERF-P05
                 └──────────→ FN-M1B
  PERF-SIDECAR ──┬──────────→ PERF-P05
                 ├──────────→ FN-M1C
                 └──────────→ HR-P3(bytecode metadata 侧车)
  PERF-TYPED-IR ────────────→ PERF-AOT
  PERF-TYPED-IR ──optional──→ PERF-JIT(增强,不是硬前置)
  08-17 IC 否证对账 ────────→ PERF-P05

序列化
  SER-CORE ─┬─→ SER-ARTIFACT ──→ 热更 Build Cache;
            │                     PROC-D4 闭包 spawn(+atom 重映射)
            ├─→ SER-SNAPSHOT ───→ HR-P2
            └─→ SER-MESSAGE ────→ PROC-D3

进程模型
  SER-MESSAGE ──→ PROC-D3 ──→ PROC-D4 ──→ PROC-D6
  PROC-D3 另前置:多 Runtime 验收面第二批(TSan gate、并发
    collect)+ 表示契约弱引用注册表立项
  PROC-D5:无硬前置
  PROC-D7:GC 合入 + 契约修订 + comptime 分档裁决 + 真实负载表

GC / 契约
  GC-GAP ──→ G1-GC ──→ GC-P3 ──→ 四门重 gate ──→ 契约修订
    ──→ 合入 main ──→ PROC-D7 / evolution Phase 1B
  轻进程共享段、堆外共享段 → 表示契约新类别(先改契约再动代码)
  typed S6 容器评估 ──→ SER-CORE 冻结前完成
  iOS AOT ──→ aarch64-macos/iOS conservative 扫描器(契约 §6)
  PERF-P05 失效钩子 ──→ 与 GC 线同桌评审一次成文(契约 §5.2)
```

## 2. Current decisions and gates

**四个独立 gate(v1.5 拆分;各自出数各自裁,互不屏障)**:

```
GC-GAP        → G1-GC:    继续 GC-P3 | time-box 补一轮 | 暂停换代保留分支
PERF-T-SPIKE  → G1-TYPED: 解释器 T1 现在做 | 仅保留 IR | 暂停静态特化
PERF-DYN-SPIKE→ G1-JIT:   动态反馈值得建 → JIT eligible | 后置
PERF-N-SPIKE  → G1-AOT:   AOT eligible | 后置
G1-JIT + G1-AOT → backend ordering(轻量裁决):
                  JIT first | AOT first | 禁并行 | 两者均后置
```

**PERF-DYN-SPIKE 定义**(v1.5 新增,填补「G1-JIT 无证据来源」的
闭环缺口——此前动态反馈证据要等 PERF-P05,而 P05 又等 G1-JIT,循环):

```
- 最小 per-site feedback + proto-hit 单态臂 + 至少一个二态 PIC 臂
- 滑动窗口 poison/backoff(不用「连续 fail」阈值)
- disposable 最小 side table(不等 PERF-SIDECAR,只买证据)
- 场:Richards / DeltaBlue / Box2D(untyped)
- 记录:hit/miss/megamorphic 分布、每站点净 cycles
- 回答:动态轴解释器期是否有净收益;feedback 是否值得为 JIT 建设;
  08-17 side-cache 否证是否在 proto-hit/多态场景被突破
```

**GC 合入 gate(三态;统计合同在 BASE-G0 冻结为
`gc_merge_policy.json`,gate 引用它,不引用待测 artifact)**:

```
primary:  candidate/rc paired log-ratio 的单侧 95% 非劣效置信下界
          (non-inferiority,不是 equivalence)
margin:   BASE-G0 冻结(refactor-policy 0.995 只是输入——它按旧
          v7 八项校准;新增 Octane cases 的 envelope 须由独立
          RC-vs-RC 重复实验先建立)
looks:    n=8 → UNRESOLVED 则 n=16 → n=32 终局,不再加样
sequential control: 预冻结 alpha-spending 或 sequentially-valid
          confidence sequence(optional stopping 错误率受控)
critical cases: 名单预冻结;composite 与单 case 的多重比较规则成文

PASS = 置信下界 ≥ margin
       且无关键 case 超出自身 envelope
       且正确性四门全绿
       且 pause/heap envelope 达 GC 文档生产目标
       且 activation canary 全过:
         major_cycles>0;应触发 minor 的 workload minor_cycles>0;
         collector mode/policy digest 一致;growth factor 一致;
         测量/测试/候选发布配置一致;pause timer 不含 census
       且至少一个预注册 benefit metric 明确改善
         (major pause p99 / cumulative STW p99 / mutator 吞吐 /
          cycle-heavy 完成时间 / 内存峰值)——绝对目标保安全,
         改善指标证明换代价值
UNRESOLVED = 区间跨 margin → 按 looks 加样,不作 GO/NO-GO
FAIL = 区间明确低于 margin,或 pause/内存/canary 失败
```

- parallel marking 定位:pause/扩展性选项,非吞吐补救。
- 吞吐三角三选一(重谈内存包络 / parallel marking 提计划项 /
  判据分层)在 G1-GC 用 GC-GAP 数据裁,论证存 process §20.2a。
- Track B 定性:最大架构风险退休项与表示定型点,非产品交付解锁器;
  以自身 gate 决定去留。

**已裁决登记**:P2 eval 缓存=incubator(typed 1.0 已同步);
SidecarCore 只冻容器协议,payload section 独立演进;
FN-M1A 不等 typed S1(FNABI v0.4 已同步);
PERF-P05 不再「批准立即执行」(evolution v0.5 已同步)。

## 3. Now / Next / Then / Later

**Now**
```
产品线:HR-P1(用户可见交付)∥ FN-M0(合同层)
BASE-G0(解锁证据线官方结果;不阻塞产品线)
证据线(BASE-G0 后,按 §4 测量队列出官方数):
  GC-GAP → PERF-T-SPIKE → PERF-DYN-SPIKE → PERF-N-SPIKE
```

**各 gate 出数即裁**(G1-GC 不等 N-spike;DBG-W2/SER-CORE/FN-M1A
只受 WIP 限制,不受任何 gate 技术阻塞)。

**Next**
```
SER-CORE spec · PERF-SIDECAR spec · FN-M1A · DBG-W2 ·
HR-P2(SER-SNAPSHOT 窄实现)· PROC-D5(可随时)
```

**Then**
```
PERF-P05(G1-JIT 后,前置见 DAG)· FN-M1B(等 PERF-SHAPE-ID)·
FN-M1C(等 PERF-SIDECAR)· SER-ARTIFACT → Build Cache ·
SER-MESSAGE → PROC-D3 → PROC-D4 · HR-P3
```

**Later**
```
PERF-JIT / PERF-AOT 按 backend ordering 推进 · PROC-D6 ·
GC 满足完整 gate 后合入 · PROC-D7(负载表通过后立项)·
动态 rebind / work stealing
```

## 4. WIP limits and execution protocol

**WIP 冻结(单维护者)**:
```
最多 1 个 owner-decision item(spec 评审/gate 裁决)
最多 2 个 implementation items
最多 1 个后台 measurement item
```
- **spike 占 1 个 implementation slot**(它们含真实原型实现),
  官方 A/B 期间同时占 measurement slot——HR-P1+FN-M0 占满两个
  implementation slot 时,spike 须等其一交付切片后释放。
- 「agent 可并行」不是扩大 WIP 的理由。

**测量队列(资源串行,非技术依赖——三 spike 互相独立)**:
```
1. GC-GAP   2. PERF-T-SPIKE   3. PERF-DYN-SPIKE   4. PERF-N-SPIKE
```
官方 A/B 串行执行,守 [perf/README.md](perf/README.md) measurement
contract(权威策略 `tools/compare/measurement_policy.json` +
BASE-G0 产出的 `gc_merge_policy.json`);官方读数前必查孤儿+亲和。

**欠账入口**:各文档修订义务在
[process-model-design.md §20.2/§20.2a](process-model-design.md);
动工规则:先改文档递增版本,再动代码。论证、评审史、业界对照不在
本图——每个结论一行+指针。

## 5. 工作项登记册(自足摘要;规范以「权威」列为准)

状态词:**now**=当前开工 · **ready**=前置已满足待 WIP 空位 ·
**gated**=等某 gate 裁决 · **blocked**=硬前置未交付 · **later**=远期。

### 5.1 基线与 GC

| ID | 是什么 | 交付物 · 验收 | 硬前置 | 状态 | 权威 |
|---|---|---|---|---|---|
| BASE-G0 | 测量冻结 | qjs/suite/binary 指纹、tracing 可解析 ref、`gc_merge_policy.json`(margin/looks/canary)、evidence ID 体系;验收=证据线官方数字可独立复现 | 无 | **now**(owner 件) | 本图 §0/§2 |
| GC-GAP | 全量 bench-v8 口径 RC vs tracing A/B | gap 数 + 六基准四行账(mutator Δ/mark 总时/sweep 总时/float bytes);供 G1-GC 与吞吐三角裁决 | BASE-G0(官方数) | ready(非官方口径 1.29 已有) | tracing-gc-pause-plan(分支) |
| GC-P3 | lazy sweep + versioned marks + 吞吐税回收 | 进 GC 合入 gate 三态(§2);incremental sweep trigger 已 fire | G1-GC 裁「继续」 | gated | tracing-gc-pause-plan §5 |

### 5.2 性能主线

| ID | 是什么 | 交付物 · 验收 | 硬前置 | 状态 | 权威 |
|---|---|---|---|---|---|
| PERF-T-SPIKE | typed slot 解释器收益 spike | T-gate 0 判定;**必含多态臂**(基类引用×子类实例交替)与 guard 双形态对比(identity 字段 vs 钉住 shape 指针比较) | BASE-G0(官方数) | ready | typed v1.0 §六 S2 |
| PERF-DYN-SPIKE | 动态反馈最小证据(v1.5 新增) | per-site feedback+单态臂+二态 PIC+滑动窗口 poison,disposable side table;Richards/DeltaBlue/Box2D untyped;hit/miss/megamorphic+每站点净 cycles;回答 08-17 否证是否被突破 | BASE-G0 | ready | 本图 §2(定义);evolution v0.5 引用 |
| PERF-N-SPIKE | 原生 Zig AOT 形态 spike | 手写目标形态+链 runtime 实测;穿越成本微基准(native↔interp 单次+ping-pong);含病理大函数样本 | BASE-G0 | ready | typed v1.0 §5.1/§8 |
| PERF-VMABI | VM 执行 ABI(evolution Phase 0) | VmExecState/HelperDescriptor/异常与中断协议/GC slot 抽象;验收=evolution §5.6 | 无 | ready | evolution v0.5 §五 |
| PERF-SHAPE-ID | shape 稳定身份(typed F1) | u64 identity(u32 回绕=ABA)+预建 shape 钉住;失效钩子与 GC 线同桌评审成文 | G1-TYPED 或 FN-M1B 需求触发 | gated | typed v1.0 §4.1+契约 §5.2 |
| PERF-SIDECAR | SidecarCore 容器协议 + 站点侧表载体 | section ID/owner namespace/lifetime/mutability/序列化规则/失效版本/per-function 查找;验收=四方评审(IC/typed/热更 §27.6/轻进程) | 无(spec 件) | ready(裁决队列) | 本图 §2;热更 §27.6;evolution §9.2 |
| PERF-TYPED-IR | 类型证书/typed metadata/布局引用(F3/F5) | certificate 绑依赖闭包指纹;类型事实走 metadata 侧车非 F4 opcode | G1-AOT 裁 eligible | gated | typed v1.0(1.0 收回无条件开工) |
| PERF-P05 | 解释器级反馈槽(Phase 0.5) | evolution §六;命中须经纪元验证 | G1-JIT+PERF-SIDECAR+PERF-SHAPE-ID+08-17 IC 否证对账+GC 线同桌评审 | gated | evolution v0.5 头部+§六 |
| PERF-JIT | baseline JIT backend(直接机器码) | 硬输入=canonical bytecode+动态反馈+PERF-VMABI;typed 仅可选增强 | backend ordering | later | evolution v0.5 §八 |
| PERF-AOT | 原生 AOT backend(Zig 源码发射→静态链接) | S6 设计门须记:Zig 无 `#line` 调试断链、保守扫描派生指针风险、iOS conservative ABI 前置 | PERF-TYPED-IR+backend ordering | later | typed v1.0 §5.1/§10 |

### 5.3 序列化

| ID | 是什么 | 交付物 · 验收 | 硬前置 | 状态 | 权威 |
|---|---|---|---|---|---|
| SER-CORE | 编码内核 spec + 三 profile 边界 | framing/section directory/varint/atom 表原语/图遍历钩子/版本空间/fuzz 基建;验收=三方评审通过(含 typed 开放问题 5 评估、SC 需求在场) | 无 | ready(裁决队列) | process v0.4 §13;热更冻结项 21 v1.4 注 |
| SER-ARTIFACT | 字节码 artifact profile(=热更 W1) | mmap 只读/确定性/严格版本拒载/atom 重映射;验收=往返性质测试+fuzz+热更 §38 测试行;接 Build Cache | SER-CORE | blocked | 热更 §27.10;typed §10.5 容器清单为素材 |
| SER-SNAPSHOT | 状态快照 profile | schema 演进/best-effort vs required/诊断;消费方 HR-P2 | SER-CORE | blocked | 热更 §27.9/§15 |
| SER-MESSAGE | 进程消息 profile | SC 全集+单消息 identity+transfer+三通道零拷贝+单拷贝 wire+pid 标签;消费方 PROC-D3 | SER-CORE;transfer 语义(rc 走 SharedBufferStore) | blocked | process v0.4 §4/§13 |

### 5.4 fun 面(热更 / FNABI / 调试)

| ID | 是什么 | 交付物 · 验收 | 硬前置 | 状态 | 权威 |
|---|---|---|---|---|---|
| HR-P1 | HostCore+Disposable Session+Sequential Reload | fun 侧主导,zjs 零新增(引擎能力对账「今天即成立」);验收=热更 §38 阶段 1 行 | 无 | **now**(产品线) | 热更 v1.4 §12/§37 |
| HR-P2 | snapshot/restore 状态保留 | 用 SER-SNAPSHOT 窄实现,挂 Core 不另造格式;欠账:`state` 默认值改「声明钩子即 best-effort」 | HR-P1+SER-CORE | blocked | 热更 §14/§15 |
| HR-P3 | ESM HMR+registry 多版本化 | registry 层重构=引擎侧主活 | PERF-SIDECAR | blocked | 热更 §16-§21 |
| FN-M0 | ABI schema+C/Zig golden layout+生成器 source of truth | 纯合同层;完成后冻结 FNABI v1;验收=FNABI §33 M0 门 | 无 | **now**(产品线) | FNABI v0.4 §33 |
| FN-M1A | 静态 NativeEntry 端到端(add/managedCreateObject) | 验收=builtin/plugin 同 NativeCallPlan、反汇编无 plugin wrapper;**不等 F1/F2** | FN-M0+最小 opcode 编码 | ready(Next) | FNABI v0.4 §33 M1A |
| FN-M1B | NativeClass 方法(World.step) | method guard 经纪元验证 | PERF-SHAPE-ID | blocked | FNABI v0.4 §33 M1B |
| FN-M1C | 动态 call quickening | dequicken 上限进 megamorphic | PERF-SIDECAR | blocked | FNABI v0.4 §33 M1C |
| FN-M2..M6 | Native Execution Core→Loader/SDK→Buffer/Async/生命周期→构建/CAS/移动→JIT 优化 | 链式;M4 前须定案循环事件通道原语(tsfn 对应物,v0.4 欠账) | 前段交付 | later | FNABI v0.4 §33 |
| DBG-W2 | 最小 CDP backend | 独立工作项,不等 HMR;热更阶段 6 依赖它 | 无(WIP 有空位即启) | ready(Next) | 热更 §37 W2 |

### 5.5 进程模型

| ID | 是什么 | 交付物 · 验收 | 硬前置 | 状态 | 权威 |
|---|---|---|---|---|---|
| PROC-D3 | 跨 Runtime 投递+邮箱+pid intern | selective receive(v1 禁并发未决)+Erlang 式背压+mailbox_overflow 归因;验收=TSan+能力尺(含 microtask 饥饿基准) | SER-MESSAGE+多 Runtime 验收面第二批+契约弱引用注册表立项 | blocked | process v0.4 §6/§8 |
| PROC-D4 | spawn/exit/link/monitor/call | 捕获检查可变即拒;call reply 直达 Promise;kill 双径 | PROC-D3;闭包 spawn 另需 SER-ARTIFACT+atom 重映射 | blocked | process v0.4 §7/§9/§10 |
| PROC-D5 | 调度池+预算 kill+per-thread Io | turn=单 job+轮转量子;静态亲和+负载观测+演进判据 | 无 | ready(可随时) | process v0.4 §5 |
| PROC-D6 | supervisor 库+register/whereis | one_for_one/one_for_all 起步;restart intensity+退避为默认行为 | PROC-D4 | blocked | process v0.4 §10.1 |
| PROC-D7 | 轻进程(共享不朽段) | 117KB→29KB;立项第一件事=comptime 分档裁决(checkpoint 必触发) | GC 合入+契约修订+分档裁决+真实负载表 | blocked | process v0.4 §15 |
