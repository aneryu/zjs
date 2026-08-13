# D8-SPE：调用边界后端停顿的逐指令诊断

日期：2026-08-13  
zjs：`e31af460d94c5c368a243f37afbf15d4cefed392`  
qjs：`04be2460`  
裁决：**NO-GO（第四个 no-go）**

## 结论

SPE 有检出能力，但没有在 `A_direct_call` 找到一条 zjs 独有的长延迟指令或关键链。
阳性控制把同一条串行 `ldr x0,[x0]` 从 4 KiB 热环的 ISSUE 中位数 235 明确拉到
64 MiB 随机环的 17,986.5，而相邻 `subs`/`b.ne` 始终只有 4–5；所以后面的零不是
“仪器看不见”。

生产路径的结果相反：zjs 调用/返回边界最热的单条指令只占边界 ISSUE weight 的
**0.83%**，前 12 条合计也只有 **6.69%**。热点不是一条长 load，而是散在
function resolution、frame zero-fill、RC/free、frame length/restore 和 threaded
dispatch 上的许多短链。zjs 的边界指令 ISSUE 平均值是 call-entry 14.14、return 16.72；
qjs 对应各段为 14.3–19.7，**qjs 并不靠更低的单指令 ISSUE latency 获胜**。

逐条反汇编能证明其中若干条在等前一条 load/ALU/flags，但 SPE 记录没有 source-operand
ready reason、issue-queue reason 或 execution-port id；`store` 的 ISSUE 等待也不能在
address recurrence 与 store/issue resource 之间唯一判别。因此本轮只能排除“少数长依赖
主导”，不能把剩余停顿诚实二分为“依赖多少、端口多少”。**12.46 cyc/call 是弥散的，
没有单点可打。**

EB 定工作量复测命中同一批 exact IP，且仍是这些短链；微基准机制确实进入宏观路径，
但没有变成单一宏观长链。没有被定位且可约的正成本，所以没有可开工的第一刀。

## 测量条件与边界

- production build：Zig 0.16.0，`zig build zjs --seed 0 --summary all` 成功；配置为
  `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`。
- SHA-256：zjs `2327f3cd40132199fe0c3e92a1ea7f9a06a849117c4c615eb9abdb99109f0c31`；
  qjs `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d`。
- CPU 5，MIDR `0x410fd851`，`armv8_pmuv3_1`；全部 workload 和 `perf record` 都由
  `taskset -c 5` 约束；无 flock。CPU 5 上测量并行度 = 1。主机其它核的并行度没有记录，
  所以本报告不使用或跨会话比较 wall-clock 绝对值。
- SPE：`arm_spe_0/period=65521/u`，固定 prime period，避免 `-F` 与紧密循环别名；
  每组 8 samples，ABBA。所有正式采集 `Total Lost Samples=0`，无 AUX-loss/decoder warning。
- `perf script` 的普通 synthesized sample 只暴露 Linux decoder 的 `record->latency`
  （TOTAL），且事件没有 `PERF_SAMPLE_WEIGHT_STRUCT`，所以 `ins_lat` 字段会被 perf 拒绝。
  本轮直接解析 `perf report -D` 的原始 AUX packet；每条 record 同时取
  `LAT ... ISSUE`、`LAT ... TOT`、`LAT ... XLAT`，再用 perf mmap 还原 PIE 地址。
- 下面的 `ISSUE weight` 是 sample 的 ISSUE counter 求和，适合排序 IP，**不是可相加的
  stalled cycles**。不同指令的等待会重叠，绝不能把 weight 除频次后冒充 12.46 的分解。
- `A_direct_call` 的 instructions/cycles/stall 采用任务输入的同 commit、8-sample ABBA
  已定事实，不重复测；本轮只新增 SPE 定位证据。
- 原始/汇总细节见 `D8-SPE-EVIDENCE.json`。

## Q1 — SPE 阳性控制

临时 C harness 建一个单 load 串行指针环，动态次数固定 16,777,216：

```asm
400a78: ldr  x0, [x0]
400a7c: subs x1, x1, #1
400a80: b.ne 400a78
```

hot 为 64 cache lines（4 KiB），cold 为固定 seed 随机排列的 1,048,576 lines
（64 MiB）。8+8 profiles，顺序 `H C C H` 重复四次。

| | target `ldr` records | ISSUE median-of-run-medians | MAD | TOTAL median | XLAT mean |
|---|---:|---:|---:|---:|---:|
| hot 4 KiB | 35,073 | **235.0** | 0.0 | 239.0 | 1.00 |
| cold 64 MiB | 34,801 | **17,986.5** | 553.0 | 18,292.75 | 24.68 |

相邻 `subs` 的 ISSUE median 是 4/4，`b.ne` 是 4/5（hot/cold）。cold 把 ISSUE
拉高 **76.5x**，且几乎全部 weight 落在唯一相关 load；instrument 对已知长依赖敏感。
临时 harness 与 parser 在报告落盘后已删除。

## Q2 — `A_direct_call` 逐指令延迟归因

### 作用域与双向零检查

每侧 8 profiles，顺序 `z q q z` 重复四次。`call1.js` 每轮 3,000,000 个 inner calls；
stdout 都是 `8999997000000`。

- zjs 只纳入具体 `opCall(.one)` mapped symbol 与 `op_return` symbol；得到 140,575 records。
- qjs 只纳入 `JS_CallInternal` 内 qjs:17787-17878、18175-18202、18266-18271、
  20699-20710 的 scoped IP；得到 60,522 records。
- 负控选两侧的 constructor block。bytecode dump 证明 `call1`/`flat1` 都没有 constructor
  opcode；zjs `op_call_constructor` 和 qjs `JS_CallConstructorInternal` 在两份语料中均为
  **0 records / 0 weight**。这是两侧当前的地址/行映射泄漏地板。

下表按边界内 sampled ISSUE weight 排序。最外层 frame 用于归属，最内层 frame 解释机制。

### zjs 前 12 条

|#|IP|指令|最外层 frame / 最内层 frame|records|ISSUE weight / 边界份额|ISSUE med/p90|TOT mean|XLAT|
|---:|---|---|---|---:|---:|---:|---:|---:|
|1|`0x127c6f0`|`str q0,[x9],#16`|`opCall...h` tailcall_dispatch.zig:1494 / `setupSimpleInlineEntryImpl` inline_calls.zig:1720|729|17,475 / **0.83%**|24/27|26.02|1.00|
|2|`0x127bdf8`|`b.ne 0x127bc50`|`opCall...h` tailcall_dispatch.zig:1385 / `resolveInlineFunctionFromObject` inline_calls.zig:184|399|12,702 / 0.60%|32/37|32.83|—|
|3|`0x127bdf4`|`ccmp x8,x27,#0,ne`|同上|390|11,997 / 0.57%|30/36|31.76|—|
|4|`0x127441c`|`subs w8,w8,#1`|`op_return` tailcall_dispatch.zig:1310 / `releaseCommonRefCount` value.zig:859|388|11,340 / 0.54%|29/34|30.23|—|
|5|`0x1274450`|`adds x25,x8,x9,lsr #4`|`op_return` tailcall_dispatch.zig:1310 / `deinitOrdinarySimpleResources` inline_calls.zig:791|399|11,311 / 0.53%|28/32|29.68|—|
|6|`0x1274454`|`b.eq 0x12744b0`|`op_return` tailcall_dispatch.zig:1310 / `deinitOrdinarySimpleResources` inline_calls.zig:792|372|11,246 / 0.53%|30/34|31.23|—|
|7|`0x127444c`|`sub x9,x9,x10`|`op_return` tailcall_dispatch.zig:1310 / `Stack.len` stack.zig:78|417|11,180 / 0.53%|27/30|27.81|—|
|8|`0x1274478`|`b.cc 0x1274464`|`op_return` tailcall_dispatch.zig:1310 / `JSValue.free` value.zig:638|374|10,989 / 0.52%|29/34|30.38|—|
|9|`0x1274408`|`and w8,w8,#7`|`op_return` tailcall_dispatch.zig:1310 / `JSValue.free` value.zig:640|399|10,881 / 0.51%|27/32|28.27|—|
|10|`0x1274424`|`b.ne 0x1274430`|`op_return` tailcall_dispatch.zig:1310 / `releaseCommonRefCount` value.zig:860|363|10,862 / 0.51%|30/34|30.92|—|
|11|`0x127446c`|`b.eq 0x12744b0`|`op_return` tailcall_dispatch.zig:1310 / `deinitOrdinarySimpleResources` inline_calls.zig:792|364|10,822 / 0.51%|30/34|30.73|—|
|12|`0x1273b68`|`cbnz x0,0x1273b74`|`op_return` tailcall_dispatch.zig:1310 / `FunctionBytecode.byteCode` bytecode.zig:2230|383|10,635 / 0.50%|28/31|28.77|—|

前 12 条合计只有 **6.69%**。不存在接近阳性控制形状的单 IP concentration。

### qjs 前 12 条

|#|IP|指令|最外层/最内层 frame|records|ISSUE weight / 边界份额|ISSUE med/p90|TOT mean|XLAT|
|---:|---|---|---|---:|---:|---:|---:|---:|
|1|`0x223f4`|`b.ls 0x223e0`|`JS_CallInternal` qjs:20706 / `JS_FreeValue` quickjs.h:689|386|17,877 / **1.67%**|47/50|47.31|—|
|2|`0x22518`|`mov x4,x23`|`JS_CallInternal` qjs:17823|430|16,699 / 1.56%|39/43|39.83|—|
|3|`0x21f70`|`add x0,x19,w0,uxth #4`|`JS_CallInternal` qjs:17864|331|15,516 / 1.45%|47/52|48.19|—|
|4|`0x22514`|`mov x3,x21`|`JS_CallInternal` qjs:17823|395|15,475 / 1.45%|39/44|40.18|—|
|5|`0x22148`|`mov x4,x0`|`JS_CallInternal` qjs:18191|419|14,628 / 1.37%|35/40|35.91|—|
|6|`0x22158`|`cmp w1,#6`|`JS_CallInternal` qjs:18193|424|14,583 / 1.36%|34/39|35.39|—|
|7|`0x22208`|`str x13,[x19],#16`|`JS_CallInternal` qjs:18200|733|14,497 / 1.35%|19/26|21.82|1.00|
|8|`0x22160`|`b.eq 0x27f64`|`JS_CallInternal` qjs:18193|407|14,319 / 1.34%|35/40|36.18|—|
|9|`0x2218c`|`mov x22,x1`|`JS_CallInternal` qjs:18197|427|14,010 / 1.31%|32/37|33.81|—|
|10|`0x22154`|`mov x3,x1`|`JS_CallInternal` qjs:18191|394|13,903 / 1.30%|35/40|36.29|—|
|11|`0x21f6c`|`add x19,x1,w9,uxth #4`|`JS_CallInternal` qjs:17863|308|13,711 / 1.28%|45/49|45.79|—|
|12|`0x223b8`|`sub x19,x19,#16`|`JS_CallInternal` qjs:18267|417|13,486 / 1.26%|32/35|33.34|—|

qjs 前 12 条合计 **16.69%**，且 med 多数比 zjs 更高；qjs 的优势不是某条对应指令
latency 更短。它用一个 `JS_CallInternal` C 活动记录执行 qjs:17746-20710，而 zjs 把
call/return/frame/dispatch 分散在多个 tail-call handler；这是动态工作面差异，不是 SPE
发现的一条 zjs-only 长等待。

## Q3 — 热停顿指令在等什么

| 指令/短链 | 能证明的等待 | SPE 依据 | 不能证明的部分 |
|---|---|---|---|
|`0x127bdec ldr [x8,#176] → cmp → ccmp → b.ne`|后 3 条有真寄存器/flags 依赖；load 是链头|ISSUE median 25→30→30→32；load TOT−ISSUE 4.2、XLAT=1|不能把 7-cycle age 增量解释成 7 stalled cycles；它与其它 in-flight op 重叠|
|`0x1274414 ldr → 4418 ldur RC → 441c subs → 4420 stur → 4424 b.ne`|`subs` 等 RC load，store/branch 等 `subs` 结果/flags|18→23→29→23→30；两个 load 的 XLAT=1，completion 增量约 5–6|不是 cache miss 长链；store queue 是否参与不可见|
|`0x1274444 ldr + 4448 ldp → 444c sub → 4450 adds → 4454 b.eq`|两条 load 可并行；后三条是长度计算/flags 链|17/16→27→28→30；load XLAT=1|无法从 SPE 判断 ALU issue-port 还是 operand-ready 谁占主导|
|`0x1274470 ldr → cmn → 4478 b.cc`|branch 等 compare flags，compare 等 slot tag load|ISSUE 21→（未取足稳定样本）→29；load XLAT=1|无长 load；无 branch miss 信号|
|`0x127c6f0 str-postindex → subs → b.ne` zero-fill loop|地址 `x9` 是 store recurrence；branch 等 `subs` flags|三条 ISSUE 24/23/24；store TOT−ISSUE 2.05、XLAT=1|SPE 无 store-buffer occupancy/port id，不能区分 address recurrence 与 store/issue resource|
|`0x1273b64 ldr byte_code → 3b68 cbnz`|branch 等 byte-code pointer load|branch ISSUE median 28；相邻 load/branch，未见长 total/XLAT|这是 reload/return 路径短链，不是 D7 已否掉的 callee 首分派 pc store→load|

这些是“在等什么”的最大可信粒度：相邻数据依赖是真实的，但没有任何一节呈现正控的
长 latency 分布。store-buffer 和具体执行端口没有相应 SPE packet，不能靠猜测填表。

## Q4 — 依赖延迟还是端口争用

**SPE 不能在本二进制上把两者唯一分开。** 可以下的严格结论只有：

1. 不是少数长 memory/translation dependency：热点 load 的 XLAT 约 1，TOT−ISSUE 通常
   4–10；上游 `stall_backend_mem` 也只有 +0.03 cyc/call。
2. 确实有多条 2–5 节的寄存器/flags 短依赖；反汇编和 ISSUE age 梯度都支持这一点。
3. 同时，独立 load、ALU、branch、store 的 ISSUE age 广泛抬高，符合共享 issue/resource
   backpressure；但 SPE 没有告诉我们是哪一个 port/queue，所以“端口争用”只能是兼容解释，
   不是已定位事实。
4. qjs 的单指令 ISSUE age 往往更高，却总 cycles 更低，进一步说明不能用某条 sample
   latency 直接解释跨引擎 12.46。

裁决口径因此是：**排除单一长依赖；剩余是弥散短依赖与资源等待的不可分混合。**

## Q5 — 12.46 cyc 的关键路径

不存在一条可画成 `12.46 = a+b+c` 的关键链。能画出的只是重叠流水阶段：

```text
call handler
  ├─ callable/realm eligibility: load → cmp → ccmp → branch
  ├─ frame allocation/setup: capacity checks + zero-fill store recurrence
  ├─ activation publication + code_ptr → opcode → handler  (D7: ≤0.536 cyc, qjs 也有)
  └─ callee body
       └─ return teardown
            ├─ value tag/RC: load → decrement → store → branch
            ├─ locals/args free loops: load → tag checks → optional RC
            ├─ stack/frame length and arena restore
            └─ caller code_ptr → opcode → handler
```

这些分支并行、相互覆盖，SPE ISSUE weight 也重叠。前 12 条 zjs IP 只占 6.69%，就是
“弥散而非单点”的直接量化。把它们相加成 12.46 会违反守恒。

## Q6 — 宏观验证（EarleyBoyer fixed d16）

语料 SHA-256：`258d3bcaf64b009251186cc7dd2b7d3d0a85c0e3674a437d243faf2fb2b40c17`。
8 profiles/engine，ABBA；stdout 格式逐轮校验。SPE 会改变 benchmark 自报的 wall score，
因此只验证正整数输出，不把 score 当本轮性能数字。

| scope | records | ISSUE mean | TOTAL mean |
|---|---:|---:|---:|
| zjs call-entry symbols | 298,502 | 14.89 | 18.20 |
| zjs `op_return` | 211,398 | 14.41 | 17.32 |
| qjs callee prologue | 185,730 | 17.87 | 21.99 |
| qjs call opcode | 76,063 | 12.75 | 14.92 |
| qjs cleanup | 47,801 | 14.40 | 17.03 |

exact-IP 复核：

- resolve chain `0x127bdec/df0/df4/df8`：微基准 ISSUE median
  `25/30/30/32`；EB `25/29/30/32`。
- zero-fill `0x127c6f0/6f4/6f8`：微基准 `24/23/24`；EB `23/36/37`。
  EB frame-size mixture 增加 loop-carried等待，但仍无长 load/XLAT。
- RC chain `0x1274414/18/1c/20/24`：微基准 `18/22/29/23/30`；
  EB `14/18/23/18/23`。
- locals free loop `0x1274470/78`：微基准 `21/29`；EB `17/22`。

因此宏观路径确实走微基准所隔离的机制；但成立的是“许多短链”，不是“某条长链”。

## 机制分解、可约性与定价边界

本轮任务要求纯定位；下表只做守恒，不把 sample weight 伪装成 cycles。

| 成分 | cyc/call | 频次 | 绝对贡献 | 可约性 |
|---|---:|---:|---:|---|
| 已知 memory backend | +0.03 | micro 3.0M calls/run | 0.09M cyc/run | 上游已排除为主体；本轮不重测 |
| D7 首分派 generic chain | ≤0.536 sensitivity | 同上 | ≤1.608M cyc/run | **不可约**；qjs:17767-17778 同为 computed goto，且是语义无效直达上界 |
| SPE 找到的单一长依赖 | **0 located** | 0 | 0 | 没有该机制 |
| 多条短 load/ALU/flags 链 | 未辨识 | 每 call 多处 | 未辨识 | 混有 qjs 对应工作和 zjs activation/ownership 工作；不能整体标可约 |
| store/issue/port resource wait | 未辨识 | 未辨识 | 未辨识 | SPE 无 port/queue 归因，不能定性为可约 |
| 12.46 扣 memory 后的未归因余额 | **12.43** | micro 3.0M calls/run | **37.29M cyc/run** | 这是待解释预算，不是可实现收益 |

不可约参照机制仍是 qjs:17746-17878 的单 C 活动记录与 computed goto、
qjs:18175-18202 的 call、qjs:20699-20710 的 cleanup；zjs 的 tail-call threaded handler
必须跨 `callconv(.c)` 边界发布/恢复 activation。但本轮没有证据允许把每一条 spill、RC 或
store 都宣布为架构必然，也没有一个 qjs-faithful 可删节点。

### 可实现上限

**严格可实现上限：未定，不能给一个诚实的百分比。** SPE 没找到可约节点，ISSUE weight
又不能相加成 cycles。可入账的已定位收益是 **0 Mcyc / Zoo +0.000%**；这表示“当前没有
候选”，不是声称物理上 12.43 永远不可约。

仅为说明未归因预算的规模，若违反证据边界、假设 12.46 全部可消，沿用 D7 已登记频次：

| benchmark | calls | 未归因预算 | 占 zjs cycles |
|---|---:|---:|---:|
| EarleyBoyer | 15.028M | 187.249M cyc | 2.7635% |
| RayTrace | 8.459M | 105.399M cyc | 2.4626% |

全 15 项同样投影约是 Zoo geomean `+2.226%`（0.9110→0.9313），与任务给的约 +2.2%
一致；**这是理论未归因预算，不是可实现上限，也不作为 go 依据。**

## Go / no-go、被否掉的假设与清理

**NO-GO。没有第一刀。** 这条战线按任务约定封板：工具看得到长依赖，但生产路径没有
单点；工具又不能给端口归属。继续靠源码猜一个 port 或删一个 handler 内指令，会重犯
“指令赢、周期不兑现”。

| 被否掉的假设 | 数字 |
|---|---|
| SPE 对调用边界没有检出能力 | 正控同一 `ldr` ISSUE 235→17,986.5（76.5x），邻指令不动 |
| 12.46 集中在一条 zjs long-latency load | zjs top-1 仅 0.83%，top-12 仅 6.69%；热点 load XLAT≈1 |
| qjs 靠对应指令 issue 更早获胜 | qjs 多个 top med 32–47，高于 zjs 24–32 |
| 微基准机制未进入宏观路径 | EB exact IP 均有样本；关键短链 median 形态复现 |
| SPE 已证明是某个执行端口 | 原始 packet 无 port/queue/source-ready reason；不能证明 |
| ISSUE weight 可以加成 12.46 | sample 等待相互重叠，且 qjs weight/指令更高而总 cycles 更低 |

临时 C harness 和 Python raw-packet parser 已删除；没有源码原型。最终检查记录：
`git diff --exit-code`、`git diff --check`、`git diff --stat` 均为空；`git status --short`
只列本任务新建的 `D8-SPE-DIAGNOSIS.md` 与 `D8-SPE-EVIDENCE.json`。
