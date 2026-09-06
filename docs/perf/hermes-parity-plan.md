# Hermes 对标方案调整稿（v0.1，2026-09-06，driver 草案，待 owner 裁决）

前提（owner 2026-09-06 口头指示）：**原生 AOT 从计划里去掉；性能目标改为
尽可能逼近 Hermes 的非 AOT 版本**。本稿把 typed plan（`type-directed-
optimization-plan.md` v1.2 + §十一 校准批）按这个目标重新排序，只列
"改什么、依据是什么"，不重写正文。

## 1. 两条新证据

### 1.1 T-spike 定价的机制 = Hermes 的 GetById 缓存，不是"类型化"

读 `spike/perf-t-main:src/exec/tspike.zig` 与 Hermes
`lib/VM/Interpreter.cpp:1885-1932`（`GET_BY_ID_IMPL`）：

| | Hermes GetById | zjs T-spike |
|---|---|---|
| 站点条目 | `ReadPropertyCacheEntry{clazz, slot, negMatchClazz}`，per-CodeBlock 数组 | `Entry{guard_key, proto_key, slot_index, state}`，进程级 256 表 |
| 索引 | 指令自带 u8 cache index | 指令自带 u8 site（`.atom_u8` 形式） |
| 命中臂 | clazz 指针比较 → `getNamedSlotValueUnsafe` | shape identity 比较 → `prop_values[slot]` |
| 一级原型 | `negMatchClazz == receiver` 且 `clazz == parent.clazz` | receiver key + proto key 双 guard |
| miss | 慢路径**覆盖**条目 | 永久锁单态（poly_stress −9.8% 全由此来） |
| 类型信息 | 无 | **无**（capture 在首次执行时动态取） |

所以 §三"静态轴对 untyped 负载收益 = 0"对这个机制不成立：它就是
Phase 0.5 的动态属性缓存，Octane 全套可用；杀标 +8% 已在 prop_dense
（+11.8%）与 own_slot（+8.0% 机制臂）上清线（`tspike-main-rerun-
2026-09-06.md` §5）。08-17 IC 否证与它的和解已由 §1.5 写明（TS 是
call 瓶颈场，属性密集场未被否证），PERF-DYN-SPIKE 政策要求的"书面
对账"条件由此满足。

### 1.2 Hermes 领先的构成：解释器本体 1.18×，优化器 1.15×（综合）

在 09-06 五引擎快照的同一协议下（CPU 19、host lock、ABBA、3 样本、
中位数）跑 Hermes 三种编译档；`base` 是用 `-Xcustom-opt` 拼出的
"单遍编译器等价档"（simplemem2reg / simplestackpromotion /
frameloadstoreopts / scopeelimination / dce / simplifycfg：局部变量进
寄存器、未捕获变量不进环境，**没有** inlining / typeinference / CSE /
objectstackpromotion）。证据：`reports/evidence/HERMES-SPLIT/`。

| Suite | zjs | H -O0 | H base | H -O | base/zjs | O/base | O/zjs |
|---|---:|---:|---:|---:|---:|---:|---:|
| Richards | 1899 | 2335 | 2796 | 2916 | **1.47** | 1.04 | 1.54 |
| DeltaBlue | 1560 | 2039 | 2569 | 2609 | **1.65** | 1.02 | 1.67 |
| Crypto | 2548 | 2191 | 2981 | 3961 | 1.17 | **1.33** | 1.55 |
| RayTrace | 3833 | 5202 | 5940 | 9803 | **1.55** | **1.65** | 2.56 |
| EarleyBoyer | 4143 | 6726 | 9814 | 11881 | **2.37** | 1.21 | 2.87 |
| RegExp | 879 | 1104 | 1121 | 1119 | 1.28 | 1.00 | 1.27 |
| Splay | 4910 | 5973 | 6289 | 6788 | 1.28 | 1.08 | 1.38 |
| SplayLatency | 14207 | 14732 | 15590 | 16508 | 1.10 | 1.06 | 1.16 |
| NavierStokes | 4555 | 4086 | 4986 | 6706 | 1.09 | **1.34** | 1.47 |
| PdfJS | 9480 | 11923 | 14396 | 17042 | **1.52** | 1.18 | 1.80 |
| Mandreel | 2489 | 1690 | 2356 | 2847 | 0.95 | 1.21 | 1.14 |
| MandreelLatency | 16956 | 3877 | 14793 | 17190 | 0.87 | 1.16 | 1.01 |
| Gameboy | 15181 | 11884 | 15509 | 17360 | 1.02 | 1.12 | 1.14 |
| CodeLoad | 34450 | 11769 | 11064 | 10937 | 0.32 | 0.99 | 0.32 |
| Box2D | 7824 | 10779 | 13568 | 16042 | **1.73** | 1.18 | 2.05 |
| zlib | 4890 | 3439 | 3439 | 3438 | 0.70 | 1.00 | 0.70 |
| Typescript | 24792 | 32272 | 40920 | 48061 | **1.65** | 1.17 | 1.94 |
| **Score** | 5678 | 5276 | 6712 | 7717 | **1.18** | **1.15** | 1.36 |

读法：

- Hermes CLI 默认 = `-O`（7695 vs 7717），快照里的 Hermes 一直是带
  优化器的。`-O0` 是稻草人（所有变量进堆环境、无寄存器分配），不能当
  "解释器"读。
- **OO 基准（Richards/DeltaBlue/EB/Box2D/TS/PdfJS）的差距 1.5–2.4× 几乎
  全在解释器本体**，优化器只再加 1.02–1.2×。数值基准（Crypto/NS/
  Mandreel/Gameboy）相反：解释器持平或 1.1×，优化器加 1.2–1.34×。
  RayTrace 两边都吃（1.55 × 1.65）。
- typeinference 单独加 +0.6%、inlining 单独加 +0.2%（`hermes-custom-
  arms`）：优化器的 1.15× 是 inlining + TI + CSE + objectstackpromotion
  叠加出来的，不能拆开立项。
- zjs 领先的三项（CodeLoad 3.1×、zlib 1.4×、Mandreel）是 Hermes 运行时
  跑优化器的税，与解释器无关。

## 2. 方案调整（逐条，对照 typed plan §6.2 序列）

| # | 原条目 | 调整 | 依据 |
|---|---|---|---|
| A1 | S6 原生 AOT、PERF-N-SPIKE、G1-AOT | **移出计划**（归档，不删文档） | owner 指示 |
| A2 | S5 Phase 2 baseline JIT | 顺延到 §3 W5 之后，不在本轮 | 目标是非 AOT Hermes，Hermes 本身无 JIT |
| A3 | F3 TS 语法解析 / 信任分级 / certificate 作为**性能**前置 | 解除。TS type lint 保留为产品线，不再是性能杠杆的前置 | §1.1：拿到收益的机制不消费类型 |
| A4 | G1-TYPED（implement / ir_only / pause） | 改读为 **G1-FEEDBACK 的证据输入**，裁决 profile = `monomorphic`（带 miss 覆盖 + 一级原型臂）；PERF-DYN-SPIKE 的三臂实验**不再另做**（T-spike 重跑即其单态臂，multi-arm 站点见 W1 未测项） | §1.1；dyn-spike 政策的书面对账条件由 §1.5 满足 |
| A5 | PERF-T1（typed slots） | 与 PERF-P05 **合并为一项**：Hermes 形态的属性缓存（读 + 写），不区分 typed / untyped 站点 | 同一机制 |
| A6 | 尺 | 五引擎快照增加固定臂 **`hermes-base`**（§1.2 六个 pass），作为解释器对标尺；`hermes -O` 保留为总目标尺。`run_benchv8_multiengine.py` 的 `ENGINE_EXTRA_ARGS` 加一个 `hermes_base` 键（flag 固定，不暴露 CLI） | 每一刀都要能回答"离 Hermes 解释器还差多少" |
| A7 | PERF-OPCODE-SPACE 的 E1（PMU 归因，`policies/spikes/perf-opcode-e1-v1.json` status=proposed） | **立即批阈值并跑**：无引擎改动，方法已在发行二进制上验证；它裁决本稿最大的一项 W2 | §1.2 OO 差距 1.5–2.4×，属性缓存最多解释其中 ~10 个点（§3 W1），余下要么在寄存器机要么在调用/GC |
| A8 | §八 效果表（typed 场 +15~20%） | 作废。新口径 = 对 `hermes-base` 的逐项比值，目标见 §3 | 尺换了 |

## 3. 工作流与预期（按证据强度排序）

| # | 工作流 | 机制 | 预期（对 zjs 现值） | 成本 | 证据强度 |
|---|---|---|---|---|---|
| W1 | **属性缓存（Hermes 形态）** = PERF-P05+T1 合并 | get_field/put_field 带 u8 cache index（按函数分配，255 = 无缓存）；条目 = shape identity（u64，PERF-SHAPE-ID，spike 已有 Shape 64 B）+ slot + proto key；miss 覆盖；一级原型臂；补 get_loc+cached get_field 融合；写缓存 | OO 基准 +5~10%，综合 +2~4% | 5–8 人日 | **高**：机制已按测量契约定价（+8~12% 属性密集场，insn −8%）；未测项 = Octane 尺度（站点索引拓宽）、2-arm 站点 |
| W2 | **寄存器机 / 指令集重设计**（PERF-OPCODE-SPACE 裁决 2 的主体） | 43–55% 动态指令是栈机搬运（opcode-design 中心发现）；Hermes/JSC 三地址寄存器机 | OO 基准上限 = 剩余的 1.3–2×；实值待 E1 | E1 1–2 人日 → E2 spike 1–2 周 → 全量数月 | **中**：份额有普查，周期占比未测（K4 门） |
| W3 | 调用路径 | Hermes call = 寄存器窗口，无 arguments 拷贝；zjs "帧语义机器"（TS/Richards 的 call 瓶颈） | 并入 W2，不单独立项 | — | 随 W2 |
| W4 | 分配 / 年轻代吞吐 | EB 对 hermes-base **2.37×**（对 qjs 也 0.85），Splay 1.28×（已知 STOP 账） | EB 单项 +30~50% 上限 | 先归因 1 人日 | **低**：R13 说 EB 份额在 tracing main 上全变，须重测 |
| W5 | 字节码优化器（IR + inlining + TI + CSE + object stack promotion） | Hermes -O 对 base 的 1.15×；数值基准 1.2–1.34×，RayTrace 1.65× | 综合 +10~15% | 多遍 IR 是新基建，1–2 月 | **高但贵**；CodeLoad ≥ qjs 红线要求按热度分层或离线（fun 模块格式 §10.5）——"去掉 AOT"是否含离线字节码编译，需 owner 明确 |

执行序：**W1 ∥ E1 ∥ W4 归因**（三项互不依赖，合计 ~2 周）→ 以 E1 读数裁 W2 是否开 spike → W5 放在 W2 裁决之后（IR 设计要和指令集定型对齐，避免做两次）。

## 4. 对 Hermes 解释器还有哪些差异未定价

- 值表示：HermesValue 8 B NaN-box（堆内 SmallHermesValue 4 B）对 zjs 16 B
  tagged。08-17 "nanbox 永闭"是 qjs-faithful 宪章下的裁决，宪章已退役
  （evolution §3.4）；OO 基准的对象足迹与缓存行占用是 W2 之后的下一个
  表示层议题，本稿不立项，只登记。
- GC：Hades 分代 + 并发老年代。zjs tracing GC 的 minor 产出与 EB/Splay
  的关系见 W4。
- 字符串：Hermes 字符串表 + 8 位存储。RegExp 1.28× 差距可能与此有关，未归因。

## 5. 复现

```
# Hermes 三档（default / -O0 / -O）
python3 reports/evidence/HERMES-SPLIT/hermes_olevels.py 3
# Hermes 定制档（base / base+typeinference / base+inlining）
python3 reports/evidence/HERMES-SPLIT/hermes_arms.py 3
```
两脚本都在 `tools/perf/bench_v8` 的 combined 套件上跑，CPU 19，须在
`flock -x /tmp/zjs-host-heavy.lock` 下执行。zjs 列取自
`bench-v8-status.md` 09-06 快照（同协议；Hermes -O 两日读数 7702 / 7717
互证）。
