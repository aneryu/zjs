# P6-02 — JS 层 BigInt allocation topology

- **日期**：2026-07-29
- **HEAD**：`4517af55`
- **性质**：只做测量，未改生产 BigInt 表示
- **裁决**：**双分配确认，wrapper 成本可测 → P6-03 有实际目标**
- **原始数据**：`P6-02-results.json`

---

## 1. 结构

```zig
// core/bigint.zig
pub const BigInt = struct {          // GC wrapper
    header: gc.Header,
    value: libs.bigint.BigInt,       // { negative, limbs: []Limb, allocator }
};
```

`createFromOwned` 做 `rt.memory.create(BigInt)`（wrapper），
`mulAlloc` 做 `allocator.alloc(Limb, n)`（limbs）—— 两次独立分配。
qjs 的 `js_bigint_new` 是 `js_malloc(sizeof(JSBigInt) + len*8)`，**一次 FAM**。

⚠️ 结构只是线索。以下全部以**动态计数**为准。

## 2. 动态计数（线性验证，`N = 0 / 1 / 200`，2×2 limbs）

| 语义入口 | N=0 | N=1 | N=200 | **per op** |
|---|---:|---:|---:|---:|
| `core.bigint.BigInt.createFromOwned`（wrapper） | 4 | 5 | 204 | **+1** |
| `libs.bigint.mulAlloc`（limbs） | 0 | 1 | 200 | **+1** |
| `libs.bigint.BigInt.cloneWithAllocator`（临时） | 2 | 3 | 3 | **+0** |
| `core.bigint.BigInt.destroyFromHeader`（finalize） | 2 | 2 | 201 | **+1** |
| **qjs `js_bigint_mul`** | 0 | 1 | 200 | **+1** |
| **qjs `js_bigint_new`** | 23 | 25 | 224 | **+1** |

**没有第三次分配。** `value_ops.zig:817` 用 `rt.memory.allocator`，
而 `createFromOwned` 比较的是 `accountedAllocator()`；两者若不同会触发克隆分支 ——
实测 `cloneWithAllocator` 每次操作 **+0**，该分支在乘法路径上不触发。

`destroyFromHeader` 在 N=200 时为 201：循环内释放 N−1 个旧结果，
最后一个 `r` 逃逸到 `String(r)` 后才释放，与预期一致，**不是少一次 free**。

```text
zjs  = 2 allocations/op  (wrapper + limbs)
qjs  = 1 allocation/op   (FAM)
```

## 3. JS 层跨引擎定位（每 run 20000 次乘法）

| case | qjs ns/mul | zjs ns/mul | zjs/qjs |
|---|---:|---:|---:|
| `2x2` | 35.17 | 59.98 | **1.7051** |
| `1x8` | 46.01 | 60.52 | 1.3152 |
| `8x1` | 37.85 | 60.49 | 1.5982 |
| `8x8` | 75.94 | 91.35 | 1.2029 |
| `16x16` | 192.72 | 199.85 | **1.0370** |

⚠️ zjs 的 `1x8`（60.52）与 `8x1`（60.49）一致 —— P6-01c 消除的顺序依赖在 JS 层同样成立。
qjs 侧仍不对称（46.01 vs 37.85）。

**差距随规模迅速摊薄（1.71x → 1.04x），说明它是固定成本主导。**

## 4. wrapper 成本

| 符号 | `2x2`（59.98 ns/mul） | `8x8`（91.35 ns/mul） |
|---|---:|---:|
| `core.bigint.BigInt.createFromOwned` | **15.01%** ≈ 9.0 ns | **10.65%** ≈ 9.7 ns |
| `libs.bigint.mulAlloc` | 9.16% ≈ 5.5 ns | 40.77% ≈ 37.2 ns |
| `MemoryAccount.freeAlignedBytes` | 6.79% | 4.42% |
| `gc.destroyZeroRefNow` | 3.85% | 2.52% |
| `exec.value_ops.binary` | 21.32% | 12.92% |

**wrapper 的绝对成本约 9–10 ns/mul，跨规模基本恒定** —— 典型的固定税形态，
而 `mulAlloc` 随规模从 5.5 ns 涨到 37.2 ns。

`2x2` 的跨引擎差是 24.8 ns，其中 wrapper 约 9.0 ns，**占差距约 36%**。

## 5. 门槛裁决

| 条件 | 实测 | |
|---|---|---|
| zjs wrapper allocations/op = 1 | 1 | ✓ |
| zjs limb allocations/op = 1 | 1 | ✓ |
| zjs temp allocations/op = 0 | 0 | ✓ |
| qjs combined allocation/op = 1 | 1 | ✓ |
| wrapper 成本 ≥ 约 5% 或小 case ≥ 1–2 ns/op | **15.01% / ≈9.0 ns** | ✓ |

**全部满足 → 启动 P6-03。**

## 6. 产品价值的正确定位

按预设的「小 case 明显、大 case 摊薄」条款，本项收益必须定位为：

> **small/medium BigInt fixed-cost optimization**

`16x16` 已经是 `1.0370x`，**不得外推为大整数乘法算法优化**。

## 7. P6-03 的边界（下一轮）

```text
实现：HeapBigInt header + trailing limbs（单次 FAM）
保持：sign-magnitude、64-bit limb、当前 basecase、
      P6-01 首行覆写、P6-01c 短操作数作外层、normalization 语义、
      JS 可观察行为
不得同时改：二补码表示、Karatsuba、GC 策略、limb 算法
```

## 8. 限制

- 只测 `mul`；`add`/`sub`/`div`/`pow` 的分配拓扑未测，但它们共用
  `createBigIntOwned` → `createFromOwned`，预期相同（**未验证**）；
- 分配字节数未逐次记录，只有分配**次数**；
- profile 百分比是相对量，wrapper 的 ns 估算由占比乘总量得到，非独立测量；
- 未把 JS 层与 direct-core 的绝对时间相减（两个 harness 的 allocator 与外围路径不同）。
