# 决策简报：寄存器承载 operand stack 顶部（register-resident stack caching）

日期 2026-08-13　zjs `53734c2a`　对照 QuickJS `04be2460`
本文自足。**§0 是已下达的裁决；§1–§6 是证据；§7–§9 是裁决据以成立的技术分析与执行计划。**

---

## 0. 裁决（已下达，2026-08-13）

> **Decision: HOLD — measurement spike approved, production ABI change not approved.**
>
> Register-resident stack caching is considered an implementation-level representation
> optimization and is therefore compatible with the faithful-reimplementation boundary,
> provided it is generic, bytecode-preserving, and does not introduce opcode-pair
> specialization or semantic bypasses.
>
> The current evidence does not establish operand stack store-to-load forwarding as the
> dominant source of the dependent-chain cost. Before changing the production handler ABI,
> first measure dynamic cache-depth coverage and validate the exact generated ABI with
> one- and two-slot forwarding prototypes.
>
> A full implementation will be reconsidered only if it demonstrates broad multi-benchmark
> coverage, at least 1% full-zoo geomean improvement, no material throughput regressions,
> and mechanically verifiable ownership/publication invariants.

**边界上允许，工程上暂缓。** 批准一个有明确停止条件的测量型 spike，
不批准现在进入全量 handler ABI 改造。

---

## 1. 现象的准确表述

⚠️ 本文的初版摘要**比证据走得远**，已按裁决更正。正确表述是：

> **zjs 在独立数值链上吞吐更高，但在串行依赖链上没有转化为收益；
> operand-stack forwarding 是候选原因之一，尚未建立因果。**

能确定的只有「存在约 7–8 cycles 的**非算术**解释器成本」，
**不能确定它主要就是栈往返**——其中 store→load、tag 处理、分派、其它各占多少，没有测过。

---

## 2. 背景：这个项目的约束

zjs 是 QuickJS 的**忠实 Zig 重实现**。硬约束：

- 唯一性能标尺是 QuickJS；不拿 zjs 旧版本当尺。
- 不得引入 QuickJS 没有的 fast path / bypass / 特化（有 lint 强制）。
  先例：`constructSimpleFieldConstructor` 这条 zjs-only 构造快路径被裁定必须删除，
  即使删了分数会变差。
- 忠实性优先于数字。
- 最终裁决指标是 **zoo（Octane）分数**，不是 cycles。

当前：zoo throughput geomean **0.9137**（15 基准），距追平 9.4%。

### 2.1 规则措辞需要修订（裁决要求）

现行表述「不得引入 QuickJS 没有的机制」无法自洽解释 zjs **现有**的 musttail threaded
dispatch。应改为：

> **不得引入 QuickJS 没有的语义机制、快捷语义路径或工作量绕过；
> 允许不改变逻辑执行模型的代码生成、状态承载和布局优化。**

---

## 3. 触发问题的基准

`navier-stokes` 分数 **0.971**，是落后基准里最接近 1.0 的。热循环
（`navier-stokes.js:576`）：

```js
lastX = x[currentRow] = (x0[currentRow] + a*(lastX + x[++currentRow] + x[++lastRow] + x[++nextRow])) * invC;
```

`lastX` 跨迭代自依赖，整条循环在关键路径上。数组是 plain `new Array(size)`。

### 定工作量 PMU（8 samples ABBA，绑 CPU 19，`--iteration-divisor 16`）

| 计数器 | z/q | 说明 |
|---|---:|---|
| instructions | **0.9645** | zjs 少执行 3.6% 指令 |
| cycles | **1.0562** | 却多花 5.6% 周期 |
| stall_backend | 1.5566 | +205.8M |
| **stall_backend_mem** | 1.1191 | **+0.43M，占超出 0.5%** |
| stall_frontend | 1.0114 | +0.69M，0.7% |
| br_mis_pred_retired | 1.0044 | +704，0.0% |

**超出 +92.3M cycles 的 100% 是非访存后端停顿。**

---

## 4. 受控实验：吞吐 vs 延迟

8 samples ABBA，绑 CPU 19，减同形状空循环。每条算术运算：

| | zjs | qjs | z/q |
|---|---:|---:|---:|
| **串行**（单链自依赖，延迟受限） | **10.53** | **10.14** | **1.038** |
| **独立**（四条并行链，吞吐受限） | **6.74** | **8.61** | **0.783** |

纯整数对照（`s = (s+a) & b`，全程 int32）：

| | zjs | qjs | z/q |
|---|---:|---:|---:|
| 串行 | 13.71 | 14.47 | **0.948** |
| 独立 | 13.98 | 16.32 | **0.857** |

边际斜率（固定循环次数，只改每次 loc 往返内的算术条数 2/4/8）：

| | 每条算术边际 cyc |
|---|---|
| 浮点 | zjs **11.33** vs qjs **10.66** |
| 整数 | zjs **6.50** vs qjs **5.88** |

**每条算术 zjs 只慢 0.6 cyc，浮点整数一致——不是浮点特有缺陷。**
（拟合截距为负，模型不纯线性，截距不可解释，只用斜率。）

串行绝对成本两边都约 10 cyc/运算，而 `fadd` 本身 2–3 cyc
⇒ **约 7–8 cyc 是非算术的解释器成本，两边都付。其构成未测。**

---

## 5. 反汇编：两个引擎的浮点臂形状几乎相同

**zjs**（`opBinary__struct_116935.hnd`）：
```
ldur x11, [x1,#-32]  ; GP 载 payload
fmov d0, x11         ; GP → FP
ldr  x10, [x8]       ; 第二个操作数
fmov d1, x10         ; GP → FP
fadd d0, d0, d1
stur d0, [x1,#-32]   ; FP 存回 payload
stur x9, [x1,#-24]   ; 存 tag
ldrb w9, [x0,#1]! ; br x4
```
**qjs**（`CASE(OP_add)` 浮点臂，`quickjs.c:19710-19722`）：
```
fmov d1, x2          ; GP → FP
fmov d0, x0          ; GP → FP
fadd d0, d0, d1
stur x0, [x19,#-24]  ; 存 tag
stur d0, [x19,#-16]  ; FP 存回 payload
ldrb w1, [x8],#1 ; br x0
```
**qjs 做的是一模一样的事。** 两边都是 16 字节 JSValue（payload + tag），都经栈往返。

⚠️ 更正：初版称「QuickJS 的 computed goto 做不到 stack cache」——**错误**。
Computed-goto 解释器完全可以手工维护 TOS locals。准确表述：

> **QuickJS 当前实现没有跨 CASE 保留显式 stack cache；
> zjs 的 musttail handler ABI 提供了更容易控制和验证的跨 handler 状态通道。**

---

## 6. 今天在这条线上被证伪的六个假设

同一天，「找到机制了」翻车六次，每次都是「指令序列看着对得上、数字也吻合」：

| 假设 | 证伪方式 | 结果 |
|---|---|---|
| 调用边界成本可靠删指令拿回 | 逐项分解定价 | 上限 geomean **+0.234%** |
| RayTrace cache-miss 2.89x 值 25% 差距 | 核实 PMU 事件语义 | 那是 **L1 refill，99.8% L2 命中**，真 LL miss 仅 15.2K，值 0.047% |
| `Vm.pc` 重发布形成 3–5 级关键路径链 | 双探针 + 阳性控制（强塞链能检出 +2.32 cyc） | 生产代码**没有那条链**，上限 **0.000%** |
| 帧复用记账是每次调用的税 | 出线口计数器 | 普通 `op_call2` 对复用状态读写**全为 0**；删掉 zoo 三 pad 全败 |
| 跨域 `fmov` 是 zjs 特有成本 | 反汇编 qjs | **qjs 做同样的事** |
| zjs 的链比 qjs 长 4.5 cyc | 拆出绝对值 | 实际只长 **4%**；4.5 是「串行化惩罚之差」，被误读 |

---

## 7. Q1 裁决：边界

**原则上不越界，但必须定义为通用的物理表示优化，而不是局部 opcode 快路径。**

合格的 stack cache 必须满足：

1. QuickJS stack bytecode、逻辑栈效果、异常顺序、RC ownership、interrupt 与
   observable call 边界**全部不变**。
2. 缓存转换由 opcode 的 **stack effect** 驱动，**不是**手写 `add → get_loc → mul`
   之类的 opcode-pair 特化。
3. **不增加新 opcode、不做 fusion、不依赖运行时 profile、不对特定值形状设 bypass。**
4. 在 cold helper、调用、异常、返回、挂起、native re-entry、frame 切换等边界
   **恢复 canonical stack 状态**。
5. 关闭优化后，执行模型仍是同一套 QuickJS-aligned stack machine。

在此定义下，它与「把 `pc/sp/var_buf` 放进 handler 参数寄存器、用 musttail 拆分 handler」
属于同一层级：改变的是解释器状态的**物理承载方式**，而非语言或 opcode 语义。

**但如果生产实现只让 `add/mul/get_loc` 识别缓存、或按前一条 opcode 选专用 handler，
它就实质上成了隐式 fusion／superinstruction，落入已排除的「换赛道优化」。**

---

## 8. Q2 裁决：原型该怎么做

### 8.1 一个 slot 很可能不够

`s = s * a + b` 的 stack effect：
```
get_loc s
get_loc a
mul            → cache0 = s*a
get_loc b      → cache0 必须变成 b，s*a 被挤下沉到内存
add            → 立刻又把 s*a 读回来
put_loc s
```
除非引入「缓存任意深度 slot 而不只是 TOS」的状态机，
**单个 slot 无法消掉这条关键往返**。两个 slot 可以覆盖，但立刻带来三个问题：

**(a) 寄存器压力必须用反汇编确认，不能推断。**
非 NaN-boxing 的 `JSValue` 是 16 字节（payload + 64-bit tag）。
现有 handler 已占用四个参数寄存器；两个 JSValue 再要四个 64-bit lane。
在 AArch64 上这可能恰好吃满剩余整数参数寄存器，其它 ABI 上可能更早进入栈传参。

**(b) aggregate 传参不保证浮点 payload 留在 FP 寄存器。** 很可能只是把
```
store d0 → memory ;  load xN → fmov d0, xN
```
换成
```
fmov xN, d0 ; tail-call ; fmov d0, xN
```
即**消除了 memory dependency 但保留 FP↔GP 跨域移动**。可能仍更快，
但收益绝不等于「完全省掉 7–8 cycles」。必须分别测：generic `JSValue` carrier、
payload/tag split carrier、是否产生额外 spill、producer 与 consumer 间是否仍有 `fmov` 依赖。

**(c) 原型不能只含 `add/mul/get_loc`。** 微基准每个表达式末尾都有 `put_loc`，
真正的跨表达式依赖是 `add result → put_loc s → get_loc s`；
纯 TOS cache 最多优化 operand stack 中间值，**不能自动消除 local slot 的 store→load**。
navier-stokes 还包含 array get/set、索引自增、dup、local load/store。
只实现三个 opcode，会在未支持 handler 处频繁 flush，
**测出的数字既不是可实现收益、也不是可靠上限**。

### 8.2 批准的原型顺序

**第一步：动态 stack-cache 模拟**（不改任何 handler）。
记录热路径的 opcode **edge** 与 stack effect，模拟 0/1/2-slot cache，统计：
- 可消除的 JSValue load/store 数
- 每次 flush 的原因
- cache depth 分布
- control-flow join 是否需要 canonicalize
- **各 benchmark 的覆盖率，而不只是 navier-stokes**

⚠️ 现有 opcode profiler 主要是单 opcode 计数；这里需要 **edge trace 或至少 hot
basic-block trace**。

**第二步：独立的 ABI/codegen harness**，只回答机器码问题：
1-slot 与 2-slot；**memory 始终 authoritative 的 read-forwarding cache**；
延迟写回的真正 write-back cache；aggregate JSValue 与 split payload/tag；
dependent / independent / empty-dispatch 三类 workload；
handler frame size、spill、code size 与 `fmov` 序列。

⭐ **read-forwarding 版本尤其重要**：仍然把结果写入 stack，只把同一个值通过 ABI
转发给下一 handler。它**不改变 RC、unwind 或 stack publication**，
却能单独判断「打断 store→load dependency」值多少钱。
**只有它明确为正，才有理由承担延迟写回的正确性复杂度。**

**第三步：生产形态的 closed-trace prototype。**
至少覆盖目标热 basic block 中的**全部** stack producer/consumer，
包括 `put_loc` 与 navier 实际出现的 array/property opcode。

---

## 9. 正确性风险模型（已按裁决更正）

⚠️ 初版称「寄存器中的 JSValue 对 GC 栈扫描不可见」——**与本仓库架构不符，已作废。**
**已核实**（本次逐条查证）：

| 断言 | 核实结果 |
|---|---|
| 无对 VM 操作数栈的 tracing 扫描 | ✅ `gc.zig`/`runtime.zig` 无 `traceStack`/`scanStack`/`rootStack` |
| 保活靠 refcount-on-push | ✅ `stack.zig:137` `push` 做 `if (value.requiresRefCount()) value.dup()` |
| push / pushOwned 合同不同 | ✅ `stack.zig:143` `pushOwned` 直接接管、不 dup |
| live prefix 由 `top_ptr` 决定、deinit 遍历释放 | ✅ `stack.zig:120-135` |
| `ValueRootFrame` 不是通用 per-frame tracing root | ✅ 仅出现在 `function_ops`/`vm_regexp`/`eval_ops`/`object_ops` 的具体调用点 |

**真正的风险是 RC ownership 与 canonical stack publication 失配**：

- 缓存值的 ownership 是否仍由逻辑栈持有
- stale memory slot 会不会在 teardown 时**重复 free**
- pop 后未清理的物理 slot 会不会被**错误视为 live**
- cold helper 之前是否正确发布逻辑 `sp`
- stack grow / reallocation（`Stack.reserveAdditional` 会重写 `self.values`）后缓存是否仍一致
- exception / catch / return / generator suspend / native re-entry 时是否完整 materialize
- refcount 归零与 finalizer 时序是否与原执行模型一致

**一个 write-back cache 实际上会重写「什么是 live stack」这一核心不变量，
而不只是改变参数 ABI。** 风险严重程度不变，只是模型从「GC 看不到寄存器」
改成「RC ownership 与 canonical publication 可能失配」。

⚠️ 本仓库有先例：构造帧的 `teardown.simple` 只在 ReleaseSafe 才 abort，
test262 全量与所有语义测试都没抓到。

---

## 10. Q3 裁决：优先级

**完整实现排在 PdfJS 宏观缺口与 call tax 之后；有限测量 spike 可以现在做。**

算术很直接：
- navier-stokes **0.971 → 1.000**，15 项 zoo geomean 只提升约 **0.20%**
- 即使 **→ 1.050**，geomean 也只提升约 **0.52%**

**不足以为整个解释器引入一个长期的 stack-cache 状态机。**
它必须证明不是 navier 特型优化，而是覆盖多个主要 benchmark。

相比之下并列的两项覆盖面更大：
- **PdfJS 未解释缺口约 137M cycles**，对应当前最大单项落后（0.778）；
  两侧 opcode 数几乎相同（z/q 0.9973），现有调用/属性/opcode 模型全部解释不了。
- 每次 JS→JS 调用 **12.46 cyc 的无主后端停顿**，已被六条独立诊断证明弥散、无单点，
  但覆盖面更广。

### go / no-go 门槛

| 阶段 | 门槛 |
|---|---|
| **模拟** | 至少**两个非 navier** benchmark 也有显著可消除的 stack traffic |
| **codegen** | dependent chain 改善 **≥10–15%**；independent throughput 与 empty dispatch 回退 **≤1%**；热点 handler 不新增 spill/frame |
| **集成** | 完整 zoo geomean 提升 **≥1%**，无稳定单项回退 |
| **正确性** | ReleaseSafe、全量 test262、OOM、RC/GC stress、异常、generator/async、stack grow、递归与 native re-entry 全通过；并新增「**logical stack = materialized prefix + cache**」不变量验证 |

1% 的主线门槛不是因为更小的收益没价值，而是因为这是一个会**渗透所有 handler、
所有 continuation seam、所有 ownership 边界**的永久性复杂度。

---

## 11. 复算材料

- 语料：`cases/`（本目录）、`/tmp/eb12cases/navier-fixed-d16.js`（sha256 前缀 `8f6cf45ecae6672f`）
- 原始 CSV：`navier-micro-float.csv`、`navier-micro-int.csv`、`navier-micro-slope.csv`、`navier-stall-breakdown.csv`
- PMU：`navier-fixed-pmu.json`
- 测量纪律：`reports/perf/qjs-align/measurement-contracts.md`（11 条，每条都有实际事故来源）
- 本轮全部诊断：`reports/perf/qjs-align/2026-08-12/` 与 `2026-08-13/`
