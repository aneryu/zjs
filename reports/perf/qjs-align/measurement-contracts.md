# 测量合同（永久登记）

本文件登记**已经造成过错误结论**的测量陷阱及其强制对策。每一条都附来源，
以便后来者知道它不是预防性的洁癖，而是有过实际事故。

违反其中任何一条得到的数字，不得作为门禁或裁决依据。

## 1. 禁止用未限定作用域的 `file:line` 做阶段归属

**来源**：P7-42（`2026-07-30/phase-7/P7-42-bridge-phase-attribution/`）

按 `file:line` 聚合 `perf annotate` 样本会在**多个被映射符号之间泄漏**。P7-42 中
`Vm.next` / `byteCode()` / `loadCurrentLevel` 同时存在于若干映射符号里，未加作用域的阶段表
把 driver 再入的样本算进了 callback 返回处理。同类问题还有：`op_return` 必须与
`op_return_undef` 一起映射，否则返回路径的成本被系统性低估。

**对策**：阶段归属必须限定到具体 symbol 或 call chain，不能仅按行号聚合。并且要做
**双向零检查** —— 取一个 gdb 已证实命中数为 0 的代码块，确认它收集到的样本量即为泄漏地板
（P7-42 实测该地板约 ±1 cyc/阶段）。

## 2. 紧密周期负载禁止直接使用 `perf -F`

**来源**：P7-42

`perf -F` 的自动调频会与被测负载的内层周期产生**别名**。P7-42 的内层周期约 100 cycles，
同一个 `bl next` 采样点在一次自动调频记录中占进程 cycles 的 **20.09%**，在另一次记录中
只占 **0.74%**，把 driver 桶从真实值虚增到 43.99。

**对策**：改用**固定且与内层周期互质**的采样 period，并跨多次记录报告离散度
（P7-42 修正后离散度 ≤3%）。被弃的那一轮数据应以 `DISCARDED` 命名保留在语料中，
不要静默删除。

## 3. 样本数必须为偶数（ABBA 平衡）

**来源**：`run_direct.py --samples 5`；Phase 6 收口 same-runtime 快照（实得 3 次 qjs-first
对 2 次 zjs-first）

奇数样本在 ABBA 下顺序不平衡，已两次作废头条数字。

**对策**：正式采样样本数强制为偶数，并在产物中记录实际顺序序列。

## 4. 每侧至少两个冷缓存构建，全组合报告

**来源**：贯穿多条线；P7-10 的实测最极端

同源两次冷缓存构建可产出不同二进制。P7-10 中 `write_local` 的 `p0-a/p1-a` 组合读作
**+2.286% cycles**（看着像回退），而 `p0-b/p1-a` 只有 **+0.226%**，两个 P0 构建之间本身就差
**−2.014%**。**单侧单实例会给出一个自信的错误结论。**

**对策**：每侧两个冷缓存构建，报告全部四个组合。若某一侧两次构建**字节相同**（多次出现过），
那一对就是免费的噪声地板，应当明确引用；`sha256sum` 必须记录。

## 5. 先在"已知存在"的场景验证计数器，再信任零

**来源**：P7-30（`openat64`）

zjs 链接的是 glibc `openat64` 而非 `openat`。只拦 `openat` 的 `LD_PRELOAD` 计数器读到零，
一度得出"抑制无效"的**假结论**。

**对策**：任何计数仪器在用于证明"某事不发生"之前，必须先在该事**已知发生**的场景上
证明它能检出。P7-31 据此先在未改动的二进制上量到 1.0000/op，再去测改动后的 0.0000/op。

## 6. big.LITTLE 双 PMU：必须过滤 `<not counted>`

**来源**：贯穿 Phase 7

本机有两个 PMU（`armv8_pmuv3_0` / `armv8_pmuv3_1`）。`perf stat` 会为**未绑核所在**的那个 PMU
输出 `<not counted>` 行。不过滤会解析出垃圾数据。CPU 19 在 `armv8_pmuv3_1` 上。

## 7. 引用归档快照前必须校验其采样条件与二进制时效性

**来源**：P7-20 / P7-40

Phase 6 收口快照的 `meta.host.affinitySource = "unpinned"`（mask `0-19`，big.LITTLE），
且自带一条被忽略的 `affinityWarning`；其 zjs 二进制建于 `0f726fc0`，**不含**后来经合并进入
`main` 的 `63c409c0`。P7-20 只校验了 JSON 的数值结构，于是把一个受两项混杂污染的
`array_map_callback = 2.618` 当成 Pareto 第 1 名，占比 17.2%，后被作废。

**对策**：复用归档快照前，先读 `meta` 的绑核字段，并确认快照二进制相对当前分支的祖先关系。
归档快照的每-case 绝对值只能作为**该快照的历史统计**，当前路线排序必须用绑核后的当前二进制。

## 8. 指令数与周期数必须同测

**来源**：贯穿；P7-41 / P7-40 最典型

本仓库多次出现**指令持平甚至更少而周期更差**的情形（P7-41 的桥接税是纯 IPC 差：builtin IPC
7.37 对 5.26；P7-42 进一步证明它全部是**非内存**后端停顿 —— `stall_backend` +31.19 对
cycles +30.85，而 `stall_backend_mem` 仅 +0.04）。反之也有指令赢而时间不动的先例
（OoO 藏住变化）。

**对策**：任何性能声明同时报告 instructions 与 cycles；当两者方向不一致时，
必须采集 stall / miss 类事件才能下结论。

## 9. 频次裁决先于单事件成本

**来源**：P7-51A

一个机制方向已核验为不忠实偏差、单事件成本 423.6 cycles、一刀形状已预批准 ——
仍因**动态冷**而被否：除三个合成 case 外，170 个语料条目合计仅 6 次事件，`gbemu`
整轮 21 次约 8.9k cycles，而同期 builtin bridge 在 10 万次 callback 下是 2.74M cycles。

**对策**：任何候选在进入生产改动前，必须先给出**绝对贡献**（单事件成本 × 实际频次），
而不是比值或静态调用点数。「静态调用点多」不能证明动态覆盖面。

## 10. worktree 里没有 test262 语料，门禁必须实跑而非假定

**来源**：P7-61

`test262` 是 git submodule（`.gitmodules`，gitlink `160000`）。**`git worktree add` 不会初始化
submodule**，因此九个 worktree 中 `test262/test` 条目数**全为 0**，只有集成树 `/home/aneryu/zjs`
有语料。P7-61 的 `test-runner` 因此在缺语料上 2/45 失败，直到把集成树的语料以只读方式接入
（gitlink 保持干净）。

**已核实的好消息**：缺语料时门禁**响亮失败**（`run-test262-dev` 收到 SIGABRT，build 判失败），
**不会**静默以 0 个用例通过。因此任何形如 `Result: 0/49775 errors, passed 44541` 的报告都必须
来自真实语料，不可能是假绿。

**对策**：在 worktree 中跑 test262 前，先确认语料可用（`ls test262/test | wc -l` 非零）；
接入方式必须保持 gitlink 干净。凡在 worktree 中报告 test262 结果的产物，应记录语料来源。

## 11. `zjs_nan_boxing` 的默认值依赖目标平台，不是常量 false

**来源**：P7-61（更正 P7-60 §8.3）

`build.zig:21-22`：

```zig
const target_default_nan_boxing = target.result.ptrBitWidth() < 64;
const zjs_nan_boxing = b.option(bool, "zjs_nan_boxing", ...) orelse target_default_nan_boxing;
```

在 aarch64（64 位）上默认为 **false**，即**默认表示是 16 字节 payload+tag，NaN boxing 才是
alternate**。P7-60 §8.3 把两者说反了。任何涉及 JSValue 表示的结论都必须写明测的是哪一种，
并跑 `-Dzjs_nan_boxing=true` 门禁。

## 12. 分布型 trace 必须先用小工作量 pilot 验证收敛

**来源**：STACK-CACHE-SIM（2026-08-13）

对 **edge mix、shape mix、cache-depth、flush-reason** 这类**比例分布型** trace，
必须先用**缩小工作量的 pilot** 验证分布收敛。默认采用**单个完整样本 + 较高 iteration divisor**；
只有当关键归一化比例超过预设稳定性阈值时，才增加工作量或重复样本。
**不得直接沿用 PMU / cycles 实验的完整工作量与固定多样本模板。**

**事故**：STACK-CACHE-SIM 对确定性的归一化 edge 分布使用了完整的 `divisor=16` 工作量
和每基准 5–8 个样本。**所有观测到的决策指标 Δ = 0.0000** —— 重复的完整 trace
只增加了成本，没有增加任何信息。该任务因此耗时约 3 小时，
其中 15 个基准的 edge trace 是主要开销；而按本条款只需十几分钟。
（叠加后果：终止时 `final-data` 仅完成 9/15 的归约，另 6 个只剩不可互操作的
`pre-stack-identity` 旧方法学 trace，导致 full-Zoo 聚合无法归档。）

**可执行流程**：

1. 用 `divisor=256` 或同量级配置跑 **1 个** sample。
2. 再用不同起始条件或 `divisor=64` 跑第 2 个 pilot。
3. 比较：关键决策比例（如 A1/A2/B1/B2）、cache-depth 分布、flush-reason 分布、
   edge-distribution 距离。
4. 若关键决策指标差异低于阈值**且 GO/NO-GO 不翻转**，**停止采样**。
5. 只有不收敛时才增加 sample 或工作量。

**稳定性阈值**：

```
关键比例绝对差 <= 0.5 percentage point
dominant flush reason 不翻转
GO / NO-GO 不翻转
```

对更高维的 edge distribution，可附加 Jensen–Shannon divergence 或 total variation
distance，但**不作为所有任务的强制要求**。

⚠️ **推论**：绝对事件数**不得**跨样本直接合并；必须先按总 opcode、
总 stack read/write 或总 edge 数**归一化**再检查稳定性。
point estimate 取一个完整的 canonical sample，其余样本**只用于收敛证明**。
