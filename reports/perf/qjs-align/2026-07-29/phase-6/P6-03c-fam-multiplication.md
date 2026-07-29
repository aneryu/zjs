# P6-03c — heap 乘法结果直接写入 FAM

- **日期**：2026-07-29
- **P0**：`42077357`（P6-03b 的 carrier，乘法仍是 external limbs + wrapper）
- **P1**：`a7e599c2`（同 carrier，heap×heap 结果直接写入 inline FAM）
- **裁决**：**通过，明确成功**。allocation 2 → 1；`2×2` **−24.6%**、`8×8` **−15.3%**，
  全部 16 组合同向；这一次是**指令数收益**，与 cycles 近 1:1
- **原始数据**：`P6-03c-results.json`

---

## 1. 三段分解（按 PRD 要求）

```text
carrier accessor effect   42077357 / P6-02      = P6-03b
FAM allocation effect     a7e599c2 / 42077357   = 本刀，主裁决
累计                      a7e599c2 / P6-02
```

| shape | carrier（P6-03b） | **FAM（主裁决）** | 累计 |
|---|---:|---:|---:|
| `2×2` | 0.9184 | **0.7538** | 0.6923 |
| `1×8` | 0.9183 | **0.7539** | 0.6923 |
| `8×1` | 0.9181 | **0.7539** | 0.6921 |
| `8×8` | 0.9744 | **0.8469** | 0.8252 |
| `16×16` | 0.9859 | **0.9226** | 0.9096 |

## 2. 提交

| 提交 | 内容 |
|---|---|
| `aede7560` | `createMulInline` + lockstep 差分测试。**不路由** —— `nm zig-out/bin/zjs` 里没有该符号，本笔无法影响生产行为或性能 |
| `a7e599c2` | `op.mul` 的 heap×heap 路由 + 分配拓扑 / OOM / 上限测试。**唯一可能移动性能的一笔** |

⚠️ PRD 的第一笔标题是 `test(...)`，实现上它必须同时含构造器 —— 测试无法引用尚不存在的函数。
拆分点选在**路由**而非**实现**：第一笔对生产二进制零影响（符号级可验证），
所以第二笔的性能归因是干净的。

## 3. 动态分配拓扑（gdb 静默断点，N = 0 / 1 / 200，2×2 limbs）

| 入口 | P0 | P1 |
|---|---:|---:|
| `libs.bigint.mulAlloc` | 1/op | **0/op** |
| `core.bigint.BigInt.createFromOwned` | 1/op | **0/op** |
| `createInlineUninitialized`（→ `createWithFam`） | 0/op | **1/op** |

```text
zjs multiplication result = 1 allocation/op
qjs multiplication result = 1 allocation/op
```

### 字节与块

`2×2` 的乘积 capacity 4：

| | P0 | P1 |
|---|---|---|
| 分配次数 | 2 | **1** |
| payload | 56（wrapper）+ 32（limbs）= 88 B | 56 + 32 = **88 B** |
| 块尺寸类 | 64 B + 40 B = 104 B 的块 | **96 B 的块** |
| slab / standalone | slab + slab | **slab** |

`allocation_count`、`allocated_bytes` 的逐次断言写进了
`heap multiplication costs one allocation and one block`：
一次乘法 `allocation_count` 恰好 +1、`allocated_bytes` 恰好 +88，释放后逐字节归位。

边界形态由 `heap multiplication crosses the slab boundary into standalone blocks` 锁定：
`28×28`（capacity 56，payload 504）是最后一个 slab-eligible 乘积，
`28×29`（capacity 57，payload 512）是第一个 standalone 乘积，两者都是 1 次分配、干净释放。

⚠️ **peak RSS 反向**：见 §7。

## 4. 性能：两侧各 4 实例、全 16 组合

### 4.1 JS 层（`same_runtime`，3 轮交错、每轮 3 样本）

| case | P0 | P1 | 中位 | **geomean** | [min, max] | 全组合同向 | P1/qjs（P0） |
|---|---:|---:|---:|---:|---|---|---:|
| `2×2` | 1.0904 ms | 0.8185 ms | 0.7507 | **0.7538** | [0.7495, 0.7646] | ✓ | **1.1656**（1.5527） |
| `1×8` | 1.1003 | 0.8272 | 0.7518 | **0.7539** | [0.7498, 0.7624] | ✓ | **0.8969**（1.1930） |
| `8×1` | 1.1006 | 0.8272 | 0.7516 | **0.7539** | [0.7497, 0.7626] | ✓ | **1.0935**（1.4549） |
| `8×8` | 1.7705 | 1.4937 | 0.8437 | **0.8469** | [0.8405, 0.8598] | ✓ | **0.9826**（1.1647） |
| `16×16` | 3.9458 | 3.6351 | 0.9213 | **0.9226** | [0.9156, 0.9324] | ✓ | **0.9430**（1.0236） |
| `28×28` | 1.1404 | 1.1003 | 0.9649 | 0.9694 | [0.9578, 0.9904] | ✓ | 1.0182（1.0553） |
| `28×29` | 1.1915 | 1.1671 | 0.9795 | 0.9839 | [0.9708, **1.0061**] | ✗ | 1.0458（1.0677） |
| `29×29` | 1.2312 | 1.2024 | 0.9766 | 0.9808 | [0.9676, **1.0026**] | ✗ | 1.0413（1.0663） |
| **`local_arith_loop`（对照）** | 5.9983 | 5.9987 | 1.0001 | **1.0000** | [0.9995, 1.0004] | — | 0.9288（0.9288） |

- 主矩阵五个形态**全部 16 组合同向**；
- 两个 standalone 形态（`28×29` / `29×29`）各有一个组合略过 1.0（1.0061 / 1.0026），
  **落在两侧约 1.8% 的实例摆幅内**，geomean 仍是 0.984 / 0.981；
- **顺序对称性**：P1 的 `1×8` 827190.5 ns，`8×1` 827180.5 ns，差 **0.001%**（门槛 ≤1%）；
- 三个形态**反超 pinned qjs**：`1×8` 0.8969、`8×8` 0.9826、`16×16` 0.9430。

### 4.2 slab → standalone 边界：**没有悬崖**

| 步 | P0 | P1 |
|---|---:|---:|
| `28×28` → `28×29`（capacity 56 → 57） | +4.48% | **+6.07%** |
| `28×29` → `29×29`（57 → 58） | +3.33% | +3.03% |

P0 在这里**根本不跨界**：它的 limb 块 57×8 = 456 B（+8 B 块头 = 464 ≤ 512）仍在 slab，
wrapper 恒为 56 B。P1 的融合块 512 B（+8 = 520 > 512）才是第一次进入 standalone。
因此 **+6.07% 与 +4.48% 之差、约 1.6 个百分点，就是跨界本身的代价**，
而 `28×29` 的绝对值仍优于 P0（0.9839）。下一步 `57 → 58` 两侧同为 +3%，无二次台阶。

### 4.3 归因：**这一次是工作量减少**

`bigint_mul_2x2`，两侧各 4 实例：

| | insn geomean | cyc geomean |
|---|---:|---:|
| `2×2` | **0.7613** [0.7612, 0.7613] | 0.7542 [0.7491, 0.7652] |
| `8×8` | **0.8436** | 0.8469 |
| `16×16` | **0.9245** | 0.9197 |

**指令与 cycles 近 1:1**，与 P6-03b 形成对照（那一刀 insn −0.88%、cyc −7.2%）。
按本项目既有口径（「insn 赢 ≠ 时间赢」「allocation-removal 才动 macro」），
**P6-03b 是 memory-traffic 收益，P6-03c 是 allocation 收益**，两者机制不同、可叠加。

扩展事件（p0a → p1a，8,000,000 次乘法）：

| 事件 | p0a | p1a | Δ | 每次乘法 |
|---|---:|---:|---:|---:|
| instructions | 10.4870 G | 7.9833 G | −23.9% | **−313 条** |
| cycles | 1.7855 G | 1.3434 G | −24.8% | **−55 cyc** |
| L1-dcache-loads | 4.4203 G | 3.0101 G | −31.9% | −176 次 |
| branches | 1.8250 G | 1.4974 G | −18.0% | −41 次 |
| branch-misses | 282,340 | 48,402 | — | 两侧都可忽略 |
| stalled-cycles-frontend | 15.5 M | 2.7 M | 占 cycles 0.9% → 0.2% |
| stalled-cycles-backend | 589.4 M | 450.4 M | −23.6%，与总量同步 |

符号占比（`--percent-limit 2`）：P0 前十里的
`libs.bigint.mulAlloc` 14.23%、`MemoryAccount.allocAlignedBytesNoTrigger` 8.61%、
`core.bigint.BigInt.createFromOwned` 8.17%、`MemoryAccount.freeAlignedBytes` 7.76%
在 P1 的前十中**全部消失**；FAM 内核被内联进 `exec.value_ops.binary`（31.52%）。
⚠️ 内联边界移动了，占比不可逐项相减，只能读作「这四个分配相关符号不再是热点」。

### 4.4 direct-core（九形态，两侧各 4 实例，全 16 组合）

| case | insn geomean [min, max] | cyc geomean [min, max] |
|---|---|---|
| `mul-multilimb` | 0.9999 [0.9995, 1.0001] | 0.9950 [0.9888, 1.0019] |
| `mul-size-1x1` | 1.0001 [0.9998, 1.0004] | 1.0002 [0.9992, 1.0021] |
| `mul-size-2x2` | 0.9999 [0.9997, 1.0001] | 0.9980 [0.9950, 1.0004] |
| `mul-size-2x4` | 1.0000 [1.0000, 1.0001] | 1.0019 [0.9940, 1.0159] |
| `mul-size-4x2` | 1.0000 [0.9998, 1.0003] | 0.9989 [0.9954, 1.0051] |
| `mul-size-4x4` | 1.0000 [0.9998, 1.0002] | 0.9994 [0.9982, 1.0002] |
| `mul-size-8x8` | 1.0000 [0.9999, 1.0000] | 1.0000 [0.9979, 1.0014] |
| `mul-size-1x8` | 1.0000 [0.9997, 1.0002] | 0.9985 [0.9928, 1.0015] |
| `mul-size-8x1` | 1.0000 [0.9999, 1.0001] | 0.9982 [0.9924, 1.0010] |

`src/libs/bigint.zig` 未改，但**没有仅凭源码宣布中性**：
九个形态的指令数全部落在 0.9999–1.0001，cycles geomean 全部落在 ±0.5% 内。
代码放置与 compiler-state 的影响实测为零。

### 4.5 其他运算不回退（两侧各 4 实例，全 16 组合）

| case | P0 | P1 | geomean | [min, max] |
|---|---:|---:|---:|---|
| `add` | 2.5089 ms | 2.4994 | 0.9948 | [0.9896, 0.9971] |
| `sub` | 1.2595 | 1.2481 | 0.9925 | [0.9886, 0.9996] |
| `div` | 8.9664 | 8.9878 | 0.9999 | [0.9893, 1.0057] |
| `mod` | 8.9168 | 8.9338 | 0.9996 | [0.9905, 1.0041] |
| `pow` | 0.5889 | 0.5904 | **1.0020** | [0.9945, 1.0084] |
| `mul_then_add` | 1.6566 | 1.4926 | **0.9023** | [0.8970, 0.9101] |

`pow` 是唯一为正的 geomean（+0.20%，最差组合 +0.84%），**低于 1% 门槛**。
`mul_then_add` −9.8%：inline 乘积作为普通 BigInt 输入没有语义或性能异常，反而受益。

## 5. 正确性

| 门禁 | 结果 |
|---|---|
| test262 | **0/49775 errors**（passed 44541，known 25） |
| test-core / parser / bytecode / exec / builtins / runtime / runner | 305 / 463 / 188 / 388 / 193 / 72 / 43 全绿 |
| test-oom | 14 通过 |
| test-altrepr | 1992 通过 |
| ReleaseSafe `test-core` | **305 通过** |
| force-GC `test-core` | **305 通过**；force-GC 二进制的 chain 与 3702 行差分**均与 qjs 逐字节相同** |
| 跨引擎随机差分 3702 行 | **与 pinned qjs 逐字节相同** |
| chain 探针（inline×external / inline×inline / 60 次连乘 / 三种符号组合 / div·mod·pow·bitwise·compare·clone·Number·toString(36)·asIntN） | **与 qjs 逐字节相同** |
| poison-allocator basecase 测试 | 通过 |

### lockstep 差分测试

同一 lhs/rhs 同时跑 `libs.bigint.mulAlloc` 与 `createMulInline`，
要求 **negative、len、每一个 limb 完全相同**。覆盖：

- 有序形态 `1×2 2×1 2×2 1×8 8×1 3×5 5×3 4×4 8×8 16×16` 加边界 `28×28 28×29 29×29`；
- 5 种 limb 模式：全 `0xff`（最高 carry 非 0）、单高位（最高 carry 为 0，
  即 `len == capacity − 1`）、稀疏、交替位、低熵 ramp；
- **正负号四组合**；
- **存储四组合**：external×external、external×inline、inline×external、inline×inline；
- 400 组随机宽度（1–16 limbs）随机符号；
- 每次都验证 `capacity` 保持 `lhs.len + rhs.len`，且 `len ∈ {capacity−1, capacity}`；
- 每次乘法后 `allocated_bytes` 必须归位。

### 短结果折叠的忠实性（PRD 前提的一处修正）

⚠️ PRD 写「两个 canonical heap BigInt 不能表示为 short BigInt，因此乘积不需要 short-result collapse」。
**这个前提在本仓不成立**：parser 只把 i32 范围内的字面量折叠成 short（`parseBigIntI32`），
而 short BigInt 在默认表示下覆盖整个 i64 范围 ——
所以 `3000000000n` 是一个 **1 limb 的 heap BigInt**，
`3000000000n * 3000000000n = 9×10^18 < 2^63`，乘积**确实能表示为 short**。
qjs 对每个乘法结果都做 `JS_CompactBigInt`（quickjs.c:15054，`len == 1` 即折叠），
不折叠就是对齐偏离。

处理：`mulResultCannotCompactToShort` 把它变成**门而不是假设** —— 要求
`lhs.len + rhs.len >= 3`。归一化后 `p` limb 的值至少是 `2^(64(p−1))`，
故 `p`×`q` 的乘积占 `p+q−1` 或 `p+q` 个 limb；要求 `p+q ≥ 3` 即保证乘积至少 2 limb，
即至少 `2^64`，**永远不可能是 short**。那一个形态（1 limb × 1 limb）留在折叠路径上。

实测确认：`3000000000n * 3000000000n` 的 `createInlineUninitialized` 命中 **0 次**，
`mulAlloc` 1 次，`createFromOwned` **0 次**（结果被折叠成 short），输出与 qjs 相同。

**永久合同**（取代原 PRD 的表述）：

> heap 表示并不保证 magnitude 超过 short-BigInt 范围。
> FAM 路径必须在**能够静态证明结果不可能 compact 为 short** 时才启用，
> 否则沿用旧路径并执行 short-result collapse。

回归用例 `heap bigint multiplication still compacts a short-representable product`
（`src/tests/exec.zig`，在 `test-exec` 门禁内）永久保留
`3000000000n * 3000000000n`，外加边界两侧的 `2147483648n²`、`-3000000000n × 3000000000n`
与刚过门的 `4000000000n²`。

### OOM / memory limit / GC threshold

融合分配把上限检查和 GC 触发从 56 B 的 wrapper 移到了整个块，这是单分配模型的固有变化。
两个新测试把这条边界钉住：

- `heap multiplication reports its single allocation failure cleanly`：
  上限设成「够放一个 wrapper 但不够放整块」，乘法以 `OutOfMemory` 失败，
  `allocation_count` 与 `allocated_bytes` **逐字节不变** —— 单一失败点意味着失败不留任何残留；
- `heap multiplication rejects an oversize product before allocating`：
  超过 `max_limbs` 的乘积以 `BigIntTooLarge` 拒绝，**且在分配之前**。

外加 force-GC 全量、`test-oom` 注入、runtime destroy（测试全部在 `rt.destroy()` 前归零）。

## 6. 裁决

| 门槛 | 实测 | |
|---|---|---|
| allocation 2 → 1 | 1/op，与 qjs 相同 | ✓ |
| `2×2` 改善 ≥ 10% | **−24.6%** | ✓ |
| `8×8` 改善 ≥ 5% | **−15.3%** | ✓ |
| 全部组合一致同向 | 主矩阵五形态 16/16 同向；两个 standalone 边界形态各 1 个组合越 1.0（≤ +0.61%，在 1.8% 实例摆幅内） | ✓ / △ |
| `16×16` 无 ≥1% 稳定回退 | −7.7%（收益） | ✓ |
| `1×8` 与 `8×1` 差异 ≤ 1% | **0.001%** | ✓ |
| direct-core 无 ≥0.5% 稳定回退 | 九形态 insn 0.9999–1.0001，cyc geomean 全在 ±0.5% 内 | ✓ |
| `add/sub/div/pow/mul_then_add` 无 ≥1% 稳定回退 | 最差 `pow` +0.20%（组合最差 +0.84%） | ✓ |
| 正确性全套 | 全绿 | ✓ |

**明确成功。**

回退条件逐条检查：`2×2` −24.6%（非 <5%）；`8×8` −15.3%（非无收益）；
slab→standalone 边界为 +1.6 个百分点的一次台阶而非悬崖，且绝对值仍优于 P0；
dual-storage 消费者无系统性回退（`add/sub/div/mod/pow` 全在 ±1% 内）；
direct-core 无 ≥0.5% 稳定回退。**没有一条触发。**

## 7. 必须报告的两项负面观察

### 7.1 ~~peak RSS 上升 128–196 KB~~ —— **已被 P6-03e 推翻**

> ⚠️ **本节的原结论是错的。**它建立在每实例每形态各一次 `maxRSS` 测量上，
> 而 `maxRSS` 在本机的重复测量摆幅本身就有约 200 KB。
> `P6-03e-fam-rss-classification.md` 用**同进程 A/B**（旧拓扑在当前二进制里仍可达，
> 两条路径在同一进程内交替跑）证明：
>
> ```text
> slab-backed 乘积    两条路径 RSS 增量逐 KB 相同
> standalone 乘积     FAM +0 KB，旧拓扑 +116 KB —— FAM 更省
> 与迭代次数无关，逻辑账逐字节归零，major_gc_count 全程为 0
> ```
>
> 「非 BigInt 对照零差异」同样只是一次测量的巧合：一个**完全不产生 heap 乘积**的
> short-only 负载在同样八个实例上重测，差值照样存在。
>
> **FAM 拓扑对 peak RSS 中性或更优。**保留本节只为记录这次错误判断。

### 7.2 BigInt 除法/取模比 qjs 慢约 300 倍（既有问题，与本刀无关）

`bi_div` / `bi_mod` 探针（8 limb ÷ 8 limb）：

```text
zjs 8.99 ms / 500 次 = 18.0 µs 每次
qjs                    ≈ 58.6 ns 每次
比值 306.8x / 283.4x
```

P0 与 P1 的比值分别是 0.9999 / 0.9996，**本刀完全没有触碰它**。
这是本轮测量中最大的单点差距，远超乘法曾经的 1.7x，
建议单独立项（怀疑是逐位 shift-subtract 而非 qjs 的逐 limb `divrem`），**不在本刀范围内**。

## 8. 限制

- `28×29` / `29×29` 的 16 组合未全部同向（最差 +0.61% / +0.26%），
  与两侧 ~1.8% 的实例摆幅同量级，无法在当前样本量下区分「真实微回退」与「构建彩票」；
- 7.1 的 RSS 上升只有测量，没有确认的因果；
- 符号占比因内联边界移动不可逐项相减，4.3 的分项只作定性；
- `add`/`sub`/`div`/`mod`/`pow` 的**分配拓扑**仍未计数（只测了时间）——
  它们仍走 `createBigIntOwned`，预期仍是 2 allocations/op，**未验证**；
- FAM 路径只覆盖 `heap × heap`；`short × heap` / `heap × short` 仍是两次分配
  （先把 short 提升成一个临时库值，再走旧路），**未测其占比**；
- `1 limb × 1 limb` 的 heap 形态被 gate 排除，仍是 2 allocations/op。

## 9. 下一步的候选（不在本刀内）

```text
A. BigInt div/mod 约 300x —— 本轮最大单点差距，独立立项
B. short x heap / heap x short 的融合分配（需要一个不分配的 short 提升路径）
C. add/sub 的 FAM 化（结果长度上界已知，同样可以单次分配）
D. addInPlaceExternal 的 rc==1 臂在 JS 层零命中（P6-03b 记录的既有休眠臂）
```
