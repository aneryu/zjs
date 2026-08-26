# zjs / fun 统一路线图

版本:1.4  
日期:2026-08-26  
状态:执行总纲候选(v1.3 经外部评审 7/10 后按其 P0 清单重构:权威层级、
全局 ID、spike 前置化、FNABI M 拆分、D1 Core/profile 拆分、GC gate 三态化、
Track B 表述降级、五节结构;论证与历史移出本文)

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
- **本图作出新裁决时,须在同一 commit 同步修改受影响的领域文档**;
  不允许以欠账登记长期维持两个相反结论。
- 视角:**统一路线图**(zjs+fun)。fun 侧工作项(HR-P1 等)入图排序,
  其规范仍以热更/FNABI 文档为权威;backlog.md 属地不变。
- **测量基线警示**:G0 完成前,Track A「S0 尺已有」与 Track B 的全部
  吞吐/pause 数字是**本地决策输入,不是可公开复现的项目事实**
  (gc/tracing 未发布可解析 commit;Octane v9 参考二进制未经 owner
  裁决;无 owner-ruled published metric)。
- 全局工作项 ID:`PERF-*`(性能主线)/`GC-*`/`SER-*`(序列化)/
  `HR-*`(热更)/`FN-*`(FNABI)/`DBG-*`(调试)/`PROC-*`(进程模型)。
  跨文档讨论一律用全局 ID,不再裸用 S1/D1/M1/阶段 1。

## 1. Canonical DAG

```
证据线(官方 A/B 串行,防测量场污染)
  GC-GAP(全量 RC vs tracing 口径)
    → T-SPIKE(typed slot 解释器收益;含多态臂)
    → N-SPIKE(原生 Zig 形态;边界成本+GC/异常闭环)
  三者互不依赖 PERF-S1,只需 S0 最小测量基建

性能主线(Gate 1 裁决后才大规模开工)
  SidecarCore spec ──→ PERF-P05(反馈槽,仅动态反馈价值成立后)
  typed IR / ABI ──┬─→ Baseline JIT(直接发机器码)
                   └─→ Native AOT(Zig 源码发射)
  ── 两 backend 只共享上游 IR/lowering spec/runtime helper ABI/
     GC slot 抽象,不宣称共享同一 emitter;先后由 spike 定(§2 Gate 1)

GC 换代
  GC-GAP → GC-P3(lazy sweep;先拆六基准四行账)→ 四门重 gate
  → 表示契约修订 → 合入 main(gate 见 §2)

序列化(D1 = Core + 三 profile,共享编码内核不强制同一格式)
  SER-D1A  Core spec:framing/section directory/varint/atom 表原语/
           图遍历钩子/版本命名空间/fuzz 基建 + 三 profile 边界
           (Artifact:确定性/mmap/只读 · Snapshot:schema 演进/
           best-effort · Message:单消息 identity/transfer/零拷贝)
  SER-D1B  Artifact profile 实现 → 接热更 Build Cache
  SER-D2   Message profile(SC 值器+三通道;前置 transfer 语义,
           rc 基线走 SharedBufferStore)
  HR-P2 的 snapshot 走 Snapshot profile 窄实现,挂 Core 不另造格式

FNABI(M1 拆三段,更早拿到端到端证明)
  FN-M0   ABI schema + C/Zig golden layout + 生成器 source of truth
          (纯合同层,与一切并行)
  FN-M1A  静态 NativeEntry 端到端(add/managedCreateObject;
          只依赖最小 opcode 编码,不等 F1/F2)
  FN-M1B  NativeClass/World.step(依赖 F1 shape identity)
  FN-M2   动态 quickening/dequickening(依赖 F2 side table)

热更 / 调试
  HR-P1   HostCore+Disposable Session+Sequential Reload
          (fun 侧主导,zjs 引擎能力已具备;近期唯一用户可见交付)
  HR-P2   snapshot/restore(用 SER-Snapshot 窄实现)
  HR-P3   ESM HMR+registry 多版本化(依赖侧车)
  DBG-W2  最小 CDP backend(独立工作项,不等 HMR;快速扩张的
          runtime 需要 debugger 作为研发基础设施)

进程模型
  PROC-D2(=SER-D2)→ PROC-D3(投递/邮箱/pid;前置:多 Runtime
  验收面第二批+契约弱引用注册表立项)→ PROC-D4(spawn/link/
  monitor/call;闭包 spawn 另需 SER-D1B+atom 重映射)
  → PROC-D6(supervisor 库)
  PROC-D5(调度池/预算 kill/per-thread Io):无硬前置,随时可开工
  PROC-D7(轻进程):等 GC 合入+契约修订+分档裁决+真实负载表
```

其余跨泳道依赖沿 v1.2 表(iOS AOT←conservative ABI;PERF-P05←
SidecarCore+GC 线同桌评审;typed S6 容器评估←SER-D1A 冻结前)。

## 2. Current decisions and gates

**GC 合入 gate(三态,机械可判)**——owner 判据「整体性能指标不退化」
(2026-08-26)的可执行形态:

```
PASS:
  - bench-v8 composite 等价区间下界 ≥ 预先冻结的 non-inferiority
    margin(margin 在 G0 冻结,参考 refactor-policy 0.995 与新增
    case 的 dispersion envelope 实测)
  - 无关键 case 超出自身稳定 envelope
  - 正确性四门全绿(单测双模式+test262 双向)
  - pause(交互式 p50/p99)与 heap envelope 达 GC 文档生产目标
    ——升为 gate,不再只是随案记录(吞吐追平而 pause 无改善=换代
    无产品收益)
UNRESOLVED:区间跨越 margin → 自动加样本,不作 GO/NO-GO
FAIL:区间明确低于 margin,或 pause/内存 gate 失败
```

- parallel marking 重新定位:**pause/扩展性选项**,不是吞吐补救
  (降 wall-clock marking 不必然降总 CPU,也不消 mutator 屏障税)。
- 吞吐三角(增长因子 1.75 封顶 ⇒ mark×major 税有下限)的三选一
  裁决在 GC-GAP 出数后做,论证存 process §20.2a。
- **Track B 定性**:最大**架构风险退休项与表示定型点**(D7、Phase 1B、
  契约第三类生命周期在它后面),**不是当前最大产品交付解锁器**
  (C/D/E 基线=main(rc),仅 D7 等它)。GC 以自身 gate 决定
  继续/time-box/暂停,不因远期设计偏好获得无条件优先级。

**Gate 1(三个裁决,证据线出数后做;裁决前不大规模开工)**:

```
GC:     继续 P3 | 限时补一轮 | 暂停换代保留分支
Typed:  解释器 T1 现在做 | 只保留 AOT IR 基建 | 暂停静态特化
Native: AOT 先行 | JIT 先行 | 两者均后置
        (N-spike 高收益边界可控→AOT 先;T-spike 有收益而 N-spike
         边界/构建成本过高→typed 解释器先;动态反馈对真实 untyped
         热负载有效→baseline JIT 先;全为纸面→保留现解释器,投入
         转 FNABI/热更/runtime 产品能力)
```

**已裁决登记**:P2 eval 缓存=**incubator**(Octane ROI 证伪,typed
plan 0.9 已同步修订;fun 真实负载达重复源码率/命中率/编译占比立项线
后重新入图)。侧车冻结的是 **SidecarCore 容器协议**(section ID/owner
namespace/lifetime/mutability/序列化规则/失效版本/per-function 查找),
payload section(动态反馈/typed metadata/origin_module_instance_id/
共享字节码元数据)各自独立演进,不一次冻结全部。

## 3. Now / Next / Then / Later

**G0(执行基线修正,先于一切官方数字)**
```
冻结 QuickJS commit/compiler/binary SHA-256、zjs merge-base、
suite revision 与 case source hash;发布 gc/tracing 可解析
branch/tag/commit;保存 RC/tracing 原始 A/B artifact、GC counters、
pause histogram、heap envelope;冻结 non-inferiority margin;
本图数字逐一挂 evidence ID。
```

**Now:一条证据线+一条产品线**
```
证据线(官方 A/B 串行):GC-GAP → T-SPIKE → N-SPIKE
产品线(并行):HR-P1(用户可见交付)+ FN-M0(合同层)
```

**Gate 1** → 三裁决(见 §2)。

**Next(Gate 1 后)**
```
SidecarCore spec · SER-D1A(Core+三 profile 边界)·
HR-P2(Snapshot profile 窄实现)· FN-M1A(静态 NativeEntry
端到端)· DBG-W2(最小 CDP)· PROC-D5(可提前)
```

**Then**
```
PERF-P05(仅动态反馈价值成立后)· FN-M1B(等 F1)· FN-M2(等 F2)·
SER-D1B → 接 Build Cache · SER-D2 → PROC-D3 → PROC-D4 · HR-P3
```

**Later**
```
AOT/JIT 按 Gate 1 分叉推进 · PROC-D6 supervisor ·
GC 满足完整 gate 后合入 · PROC-D7(负载表通过后立项)·
动态 rebind/work stealing
```

## 4. WIP limits and execution protocol

**WIP 冻结(单维护者)**:
```
最多 1 个 owner-decision item(spec 评审/裁决)
最多 2 个 implementation items
最多 1 个后台 measurement item
```
「agent 可并行」不是扩大 WIP 的理由——设计整合、异常处理、验收与
合入最终消耗 owner 带宽。

**测量纪律**:官方 A/B 串行执行,守 [perf/README.md](perf/README.md)
whole-process measurement contract(权威策略
`tools/compare/measurement_policy.json`);官方读数前必查孤儿+亲和。

**欠账入口**:各文档修订义务在
[process-model-design.md §20.2/§20.2a](process-model-design.md);
动工规则:先改文档递增版本,再动代码。论证、评审史、业界对照均不在
本图——本图每个结论只留一行+指针。
