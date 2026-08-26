# zjs / fun 统一路线图

版本:1.5  
日期:2026-08-26  
状态:执行总纲候选(领域文档已同步:evolution v0.5 / typed v1.0 /
FNABI v0.4 / hot-reload v1.4 / process v0.4;G0 落地后转
approved execution baseline)  
v1.5 = 外部复审 8.2/10 后修订:领域文档同步、PERF-DYN-SPIKE 补位、
Gate 1 拆四独立 gate、DAG 补全并与测量队列分离、GC 统计合同闭合、
全局 ID 贯彻。

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
