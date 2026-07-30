# P6-00 — `bigint/mul-multilimb` 归因：**计划中的第一刀没有目标**

- **日期**：2026-07-29
- **HEAD**：`c3c614ea`
- **性质**：只做归因，未改代码
- **结论**：**「双分配 / pointer chasing」前提在本基准上不成立** ——
  两侧都只做一次分配。真正的 zjs-only 成本是**结果缓冲区清零**与**分配器**

---

## 1. 基线复现

```text
bigint/mul-multilimb   zjs 20.587 ns/op   qjs 9.724 ns/op   = 2.12x
```

（PRD 记的 1.77x 来自另一轮，量级一致。）

## 2. 计划前提的检验：两侧都是一次分配

### zjs

```zig
// libs/bigint.zig:586
pub fn mulAlloc(allocator, lhs, rhs) !BigInt {
    try checkLimbCount(lhs.limbs.len + rhs.limbs.len);
    const limbs = try allocator.alloc(Limb, lhs.limbs.len + rhs.limbs.len);  // 唯一一次分配
    @memset(limbs, 0);
    …
}
```

`BigInt` 是**值结构** `{ negative: bool, limbs: []Limb, allocator }`，
按值返回，**没有独立的对象分配**。

### qjs

```c
// quickjs.c:11865
r = js_bigint_new(ctx, a->len + b->len);   // 唯一一次 js_malloc（FAM）
mp_mul_basecase(r->tab, a->tab, a->len, b->tab, b->len);
```

`js_bigint_new` 就是 `js_malloc(sizeof(JSBigInt) + len * sizeof(js_limb_t))` ——
**本来就是 FAM，也只有一次分配**，且**不清零**。

两侧 limb 宽度相同（`JS_LIMB_BITS 64` / zjs `Limb = u64`）。

> **因此 P6-01 原定的「HeapBigInt wrapper + limbs 单次 FAM 分配」
> 在这个基准上没有目标可打。** 那个方案针对的是 JS 层 BigInt 的对象/limb 双分配，
> 而 direct 基准直接测 `libs/bigint.mulAlloc` vs `js_bigint_mul`，两者都已是单次分配。

## 3. 实际差异所在

### 3.1 profile

| zjs 20.587 ns/op | 占比 | | qjs 9.724 ns/op | 占比 |
|---|---:|---|---|---:|
| `libs.bigint.mulAlloc` | 58.86% | | `js_bigint_mul` | 51.46% |
| **`malloc`** | **25.56%** | | *（无独立 malloc 符号）* | — |
| **`compiler_rt.memset`** | **7.58%** | | *（无 memset）* | — |
| `_int_free` | 5.46% | | | |
| kernel | 2.48% | | `direct_bigint_loop` | 33.92% |
| | | | kernel | 14.5% |

`mulAlloc` 内部行级归因：

| 行 | 占 `mulAlloc` | 内容 |
|---|---:|---|
| `bigint.zig:598` | 73.29% | 内层 `a*b + limbs[index] + carry` |
| `bigint.zig:591` | 21.81% | `checkLimbCount` + 紧随的分配调用点（行归属有平滑） |
| `bigint.zig:776` | 4.90% | `normalize` 的尾零扫描 |

### 3.2 操作数规模决定了成本构成

```text
lhs      127 bits -> 2 limbs
rhs       97 bits -> 2 limbs
product  223 bits -> 4 limbs
```

**内层乘法只有 4 次迭代。** 在这个尺寸上，
**每次操作的固定成本（分配、清零、释放）而不是乘法核心**主导。

### 3.3 两处真正的 zjs-only 成本

**① 结果缓冲区清零**（`memset` 7.58%）

zjs：
```zig
@memset(limbs, 0);
for (lhs.limbs, 0..) |a, i| {
    for (rhs.limbs, 0..) |b, j| {
        const current = a * b + limbs[index] + carry;   // 每个元素都读-改-写
```

qjs（`quickjs.c:11401`）：
```c
static void mp_mul_basecase(result, op1, op1_size, op2, op2_size) {
    result[op1_size] = mp_mul1(result, op1, op1_size, op2[0], 0);   // 第一趟：只写
    for (i = 1; i < op2_size; i++) {                                 // 之后才累加
        r = mp_add_mul1(result + i, op1, op1_size, op2[i]);
```

**qjs 的第一趟是纯写入，因此不需要预清零，也少一趟读-改-写。**
zjs 用「先清零 + 全程累加」实现同一算法，多付一次 memset 与第一趟的读。

**② 分配器**（`malloc` 25.56% + `_int_free` 5.46% ≈ **31%**）

zjs direct bench 使用 `init.gpa`；qjs 使用 `js_malloc`。
qjs 侧在同一阈值下**没有独立的 malloc 符号**。
⚠️ 这是 **harness 的分配器差异，不是 BigInt 表示差异**，
不应算作 BigInt 的实现债 —— 但它确实占了 zjs 侧近三分之一的时间，
在解读 2.12x 时必须扣除或单独说明。

## 4. 对 P6-01 的作用域修正

```text
原定：HeapBigInt wrapper + limbs 单次 FAM 分配
      -> 本基准上两侧均已是单次分配，无目标

建议：镜像 qjs 的 mp_mul_basecase 首趟写入
      P0  @memset(limbs, 0) + 全程累加
      P1  第一趟 (i == 0) 纯写入，其后累加；删除 @memset
```

该刀的性质符合全部约束：

- **是 qjs 机制对齐**（逐行镜像 `mp_mul_basecase`），不是新增特化；
- 不改 sign-magnitude、不改 limb 类型/宽度、不改乘法算法、不改 GC；
- 只改**写入拓扑**，不改表示；
- 单机制、边界清晰、可逐条对照 `quickjs.c:11401-11413`。

预期收益上界：memset 7.58% + 第一趟读的一部分。
⚠️ 按第 3 刀更正后的口径，这是**局部显式成本估计，不是收益上界** ——
实测很可能低于 7.58%。

## 5. 未解决 / 需要单独处理

| 项 | 占比 | 性质 |
|---|---:|---|
| 分配器（`malloc` + `_int_free`） | ~31% | harness 层（`init.gpa` vs `js_malloc`），非 BigInt 表示 |
| `checkLimbCount` + 分配调用点 | mulAlloc 的 21.81% | 行归属平滑，需指令级拆分才能分离两者 |
| JS 层 BigInt 是否真的双分配 | 未测 | **原 P6-01 方案的正当目标在这里，不在 direct 基准** |

⚠️ **建议同时新增一个 JS 层 BigInt 基准**来回答第三项 ——
如果 JS 层确实是「对象 + limb 数组」双分配，那么原方案在那里成立，
只是不该用 `bigint/mul-multilimb` 来验证它。

## 6. 限制

- 只 profile 了单一操作数规模（2×2 limbs）；大操作数下乘法核心占比会上升，
  结论可能反转，**未采样**；
- 行级归因存在平滑，`checkLimbCount` 与分配调用点未分离；
- 未测 `bigint/add`、`div`、`compare`、`toString`；
- 分配器差异未量化到「若两侧同分配器则差距为多少」。
