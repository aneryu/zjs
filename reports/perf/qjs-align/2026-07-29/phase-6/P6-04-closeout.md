# P6-04 — BigInt 除法主线**正式关闭**

- **日期**：2026-07-30
- **起点**：`ca31bb9c`（P6-04a 基线）　**终点**：`5fdb3fc3`（含 d3 档案）
- **裁决**：**关闭。**一个数量级错误的算法路径已收敛为普通的实现常数差距。
  剩余的 `div_8x4 = 2.58x` **已经换了归属**，不再在 BigInt 内处理

> **归因更正（2026-07-30，依据 `phase-7/P7-00-allocator-churn/`）**
>
> 本档案原将 `div_8x4` 的剩余成本记为
>
> ```text
> div_8x4 residual = SmallObjectSlab arena churn
> ```
>
> 该表述不准确，正确表述是
>
> ```text
> div_8x4 residual =
> shared immediate-empty-arena policy
> × zjs-specific transient scratch class occupancy
> ```
>
> 前半段是**两侧共享**的 allocator policy：arena 4096 / arena 头 40 B / block 头 8 B /
> `block_sizes` 表 / 类映射公式 / 每 arena 块数 / 空 arena 立即释放臂（`quickjs.c:1626-1630`）
> 与后端 glibc `malloc` 逐项相同，实测 qjs 的 churn 率相同或更高。后半段才是 zjs-only：
> `bigint.zig:742` 的 `u = alloc(Limb, na + 1)` 在 `na = 8` 时为 72 B 载荷 → **80 B class**，
> 该类在 zjs 中没有其他驻留租户；qjs 的对应临时对象是 10-limb `JSBigInt`（88 B 载荷）
> → **96 B class**，该类有驻留。**这是 BigInt 表示与尺寸类占用的偶合，不是 allocator 缺陷。**
>
> P7-00 已证明该偶合不具备跨类型普遍性，因此**不能升级为 allocator 政策修改**：
> 下文第 5、7 节提出的 `SmallObjectSlab empty-arena retention` 路线
> **已于 2026-07-30 永久关闭，P7-01 不开**。原位对照（保留 411 个 `Uint8Array(72)`
> 填充 80 B class，不改除法一行）量得该项值 834 insn / 147 cyc / **37.7 ns 每次除法**，
> 占 `div_8x4` 全部 zjs−qjs 差距的 **39.9%**（96.0 ns → 57.6 ns）。
>
> BigInt 主线**维持关闭**。411 驻留对象是因果证明而非可部署方案；填充特定 class、
> 依 free-list 历史选路、全局保留 empty arena、BigInt 专用常驻对象四类修复分别
> 把尺寸类偶然性写进算法、让同一输入依赖运行时历史、主动偏离 qjs、或仍是人为维持
> allocator 状态。**只有出现不依赖 size class 与 allocator 历史的方案**——例如有严格
> 容量上限、可重入语义清楚的通用临时 workspace，且跨多个 BigInt 形态稳定获益——
> 才值得重开。当前没有这个前提。

---

## 1. 结果

| JS case | 起点 | **现在** |
|---|---:|---:|
| `bigint_div_8x1` | 255x | **1.93x** |
| `bigint_div_8x4` | 243x | **2.58x** |
| `bigint_div_16x8` | 209x | **1.21x** |
| `bigint_mod_8x4` | 152x | **1.54x** |

## 2. 最终因果链（固定表述）

```text
P6-04a
逐 bit shift/subtract 被确认：
工作量随 numerator bit length 增长，
allocations ≈ 2.5 × numerator bits

P6-04b
单 limb divisor 改为高位到低位线性扫描：
8×1 direct 改善 75x，JS 改善 110x

P6-04c
多 limb 改为 normalized Algorithm-D 式逐 limb division：
28x–272x 改善，allocation O(bits) → O(1)

P6-04d1
reciprocal quotient estimate：
每 quotient digit 的 __udivti3 降为每 operation 一次

P6-04d2a
去掉两个只读 input magnitude clones：
multi-limb 6→4 allocations，随后按需结果构造降到 3

P6-04d2c
scratch merge 被拒绝：
收益由 transient slab arena 状态决定，
无稳定静态 crossover

P6-04d3
融合 multiply-subtract borrow chain：
per-limb instructions −47.6%，cycles −18.3%
```

（`P6-04d2b`「只物化被请求的结果」并入 d2a 那一行的后半句：`4 → 3`。）

### 方法结论

> **先去除复杂度错误，再处理固定成本；
> 不因为某个局部拓扑在几个 case 上有收益，就把 allocator 状态偶然性写入算法。**

这也符合既定方向中「不继续叠加叶子绕行，而是消除通用路径固定税」的纪律。

## 3. 逐形态归属

| case | 当前 | 归属 |
|---|---:|---|
| `div_16x8` | **1.21x** | 大尺寸核心算法**已基本对齐，停止** |
| `mod_8x4` | **1.54x** | 已进入可接受范围；d3 在 JS 层中性说明其剩余成本**不在 multiply-subtract** |
| `div_8x1` | **1.93x** | 单 limb 已是线性扫描，剩余是**固定分配与 JS publication** |
| `div_8x4` | **2.58x** | 唯一仍超 2x 的主要形态；**d2c sweep 已证**继续调 BigInt scratch 拓扑会落入 `SmallObjectSlab` size-class 彩票，**不应在 BigInt 内部规避**。<br>**2026-07-30 更正**：其剩余成本 = 共享的 immediate-empty-arena policy × zjs-only 的 scratch 尺寸类占用（`u` → 无驻留的 80 B class），**不是** zjs 的 churn 机制劣于 qjs；见文首归因更正与 `phase-7/P7-00-allocator-churn/` |

⚠️ **不得因为 `div_8x4` 仍为 2.58x 而把 P6-04 拆成更多算术小刀。**
剩余问题已经换了归属。

## 4. 已登记 follow-up：**不再进入 BigInt 主线**

| 项 | 不做的理由 |
|---|---|
| `addBackAt` 同款融合 carry 链 | 10192 个 quotient digit 中只命中 24 次，动态占比过低 |
| reciprocal 阈值 3 → 2 | 可能有小收益（实测盈亏平衡约 1.6 商位），但不是剩余主要差距 |
| `addInPlaceExternal` 的 `rc==1` 臂 | JS 层零命中，属 ownership/死路径问题，不是当前热点 |
| division result FAM | 可能降低小尺寸固定成本，但会再次与 slab class、short-result collapse、dual storage 交织，**当前缺少足够收益证据** |
| scratch merge 的任何阈值 / padding / allocator-history 路由 | **已永久否决**（`P6-04d2c-scratch-merge.md` §11） |

以上保留为 issue，**不占下一阶段主线**。

## 5. ~~真正值得继续的：独立 allocator 课题~~ —— **已于 2026-07-30 永久关闭**

> 本节的判断在当时是合理的，但已被 P7-00 推翻：churn 是**两侧共享**的行为，
> qjs 的 churn 率相同或更高，因此不存在可对齐的 allocator 缺陷。
> **不开 P7-01。**下面的原文保留以便审计，不再作为路线。

```text
SmallObjectSlab empty-arena retention
```

当前 policy 在某 size class 的最后一个 live block 被释放时**立即销毁整个 arena**。
对「分配一个临时值，在同一次操作末尾全部释放」的 workload：

```text
addArena → 使用一个或少量 block → releaseEmptyArena
→ 下一次操作再次 addArena
```

d2c 已证明这一行为可以占：

```text
4×4 merged   addArena 12.45%
8×8 split    addArena  9.45%
```

**但它是 allocator 的通用行为，不是 BigInt 特有债务。**

## 6. 执行顺序

```text
1. 合入并关闭 P6-04d3 dossier          ← 已完成（bdbd617d / 5fdb3fc3）
2. 生成 Phase 6 全局性能快照            ← 见 phase-6-closeout-snapshot/
3. 根据当前而非历史差距重新排序
4. 若 allocator churn 跨类型成立，进入 P7-00
5. 否则转向快照中最大的下一项
```

快照的目的**不是刷新 policy baseline** —— 经过 global write、call/return、
BigInt mul/div 的多轮改动，原始优先级已经失效，需要重新排序。

## 7. ~~若 allocator churn 成为下一大项：`P7-00` 的前置条件~~ —— **已执行，结论为否**

> P7-00 已按本节的前置条件执行完毕，裁决 **does not generalise → permanently close**：
> 跨类型扫描（21 个短命分配尺寸）显示两侧都 churn 且 qjs 相同或更高，
> 普通对象分配两侧都不 churn。**本节末尾「若跨类型审计显示 churn 只出现在少数合成形态，
> 关闭 allocator 路线」的条件已经成立，路线关闭。**下面的原文保留以便审计。

第一阶段**只画像，不改释放策略**。矩阵至少覆盖：

- 多个 size class：16 B – 512 B；
- BigInt、String、普通 raw payload、GC object 等**不同类型**；
- 单对象循环、burst 分配、交替 size class；
- 每轮释放到零 / 保留一个 live object；
- `balanced` / `throughput` / `low_rss` 三种 policy。

记录：

```text
alloc/free/op        addArena/op        releaseEmptyArena/op
backing malloc/free/op                 committed arena bytes
logical allocated bytes                RSS
runtime destroy 后残留
```

**只有在多个无关类型和多个 size class 上都确认 churn**，才实验
「每 class 最多保留一个 empty arena + 全 runtime 有界总 reserve」——
**而不是为 `div_8x4` 单独调 class**。

方案的硬条件：

```text
至少三个无关 workload 明显改善
多个 size class 同方向
steady state 不再每 op add/release arena
reserve 有严格字节上限
low_rss mode 可保持零 reserve
runtime destroy 释放全部 arena
全局性能哨兵无稳定回退 >=1%
```

若跨类型审计显示 churn 只出现在少数合成形态，**关闭 allocator 路线**，
按 Phase 6 快照选择下一个子系统。

## 8. 本主线留下的可复用资产

```text
基准        bigint/{div,mod}-size-AxB[sN]、bigint/div-rel-{lt,eq,q1,exact}
            JS: bigint_div_8x1 / 8x4 / 16x8、bigint_mod_8x4
成本模型     per digit ≈ 58.7 + 11.13 · nb 指令（启用 reciprocal）
            固定 ≈ 47 ns（d2.5 测，d3 后未重标定）
纪律        helper 必须 noinline（P6-04b §3.3 实测）
            per-limb 收益上界按 **指令占比** 估，不按 cycle 占比（P6-04d1 §6）
            crossover 非单调即关闭，不搜索 benchmark-shaped 阈值（P6-04d2c §11）
永久哨兵     small-shape dispatcher/codegen sensitivity sentinels
                div-size-6x4（P6-04d1，现已 −7.1% 优于回退前）
                mod-size-2x1（P6-04c，现已远优于回退前）
测试资产     kernel lockstep（subMul vs 定义式参考，500 000 组）
            算法八项计数纯度对照（digits/corrections/add-back/clamp/submul/三种估算）
            multi-limb 除法 OOM fail-index sweep（兼拓扑锁）
            定向向量：qhat 修正 ×1/×2/×3、clamp、三条 add-back、全 64 shift
            20 000 组跨引擎随机差分（1–64 limb）
```
