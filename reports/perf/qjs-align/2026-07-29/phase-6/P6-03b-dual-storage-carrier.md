# P6-03b — heap BigInt external / inline 双存储 carrier

- **日期**：2026-07-29
- **P0**：`958307e3`　**P1**：`42077357`
- **性质**：表示重构。**所有生产创建路径仍为 external，分配拓扑与乘法算法完全不变**
- **裁决**：**通过**。指令数中性（−0.88%），JS 层出现**可复现的非指令性收益**（cycles −7.0~−9.2%）
- **原始数据**：`P6-03b-results.json`

---

## 1. 改了什么

两笔提交，每一笔都独立可编译、独立过门禁：

| 提交 | 内容 |
|---|---|
| `3ef9730d` | 15 个消费者改走存储访问器（`negative` / `limbs` / `limbsMut` / `borrowedValue` / `initExternalFromOwned` / `addInPlaceExternal`），**表示未变**，访问器逐个是内嵌值的直读 |
| `42077357` | 把内嵌的 `libs.bigint.BigInt` 换成显式字段，`core/bigint.zig` 单文件 |

⚠️ **提交顺序与 PRD 给的两个标题相反**。PRD 的顺序（先引入存储、再改消费者）无法让第一笔编译通过：
删掉 `.value` 字段的同一刻，11 个文件里的消费者全部失效。倒过来之后每一笔都能单独构建、
单独跑门禁，表示变更也被压进一个文件，bisect 与归因都更干净。

### 新表示

```zig
header: gc.Header,        // 16
limbs_ptr: ?[*]Limb,      //  8   零值为 null（两种存储模式都不持有 limb）
allocator: std.mem.Allocator, // 16
len: u32,                 //  4   归一化后的活 limb 数
capacity: u32,            //  4   已分配 limb 数
flags: packed struct(u8) { negative, inline_storage, reserved: u6 },
```

`limbs_ptr` 同时解析两种模式，因此**所有读路径都不分支**；
只有构造、就地变更、capacity 访问、销毁四处知道差别。

为什么不能继续内嵌 `libs.bigint.BigInt`：它持有自己的切片并在 `deinit` 里释放，
而指向 FAM 尾部的视图**绝不能被 deinit 或 realloc**。所以字段搬到这里，
库值只通过 `borrowedValue` 以显式借用的形式交出去。

`capacity` 必须与 `len` 分开：inline 乘积按 `lhs.len + rhs.len` 分配，
归一化后可能少一个 limb，**按 `len` 释放就会还错尺寸**。

## 2. 静态门禁

| 项 | 结果 | |
|---|---|---|
| `@sizeOf(BigInt)` | **56**，与旧表示一致（comptime 焊死） | ✓ |
| `@alignOf(BigInt)` | 8（comptime 焊死） | ✓ |
| `@offsetOf(header)` | 0（comptime 焊死） | ✓ |
| FAM 尾部 limb 对齐 | `56 % @alignOf(Limb) == 0`（comptime 焊死） | ✓ |
| slab class | payload 56 → `totalBlockSize` 64 → **同一 block 尺寸类**，未变 | ✓ |
| `max_limbs <= maxInt(u32)` | comptime 焊死 | ✓ |

## 3. 分配拓扑（未变）

gdb 静默断点，`N = 0 / 1 / 200`，2×2 limbs，与 P6-02 同法：

| 语义入口 | N=0 | N=1 | N=200 | per op |
|---|---:|---:|---:|---:|
| `core.bigint.BigInt.createFromOwned` | 0 | 1 | 200 | **+1** |
| `libs.bigint.mulAlloc` | 0 | 1 | 200 | **+1** |
| BigInt 的 `createWithFam` | — | — | — | **0** |

第三行是**符号级证据而非计数**：`createInlineUninitialized` 是 `pub`，
但 `nm zig-out/bin/zjs` 里**不存在**它、也不存在 BigInt 的 `createWithFam` 实例化 ——
Zig 不为未被引用的函数发码，所以「生产路径全部仍是 external」是可从二进制直接验证的，
不依赖运行时计数。

```text
zjs = 2 allocations/op（wrapper + limbs），与 P6-02 完全一致
```

⚠️ 与 P6-02 的表格相比 `createFromOwned` 的 N=0 基线是 0 而不是 4：
P6-02 用的探针脚本在 `N=0` 时也会构造若干 BigInt，本轮脚本不会。**斜率一致，才是门禁项。**

## 4. inline 存储的 slab / standalone 销毁

`createInlineUninitialized` + `publishInline` 目前**只有测试可达**，
但它必须在 P6-03c 开始用之前就是活的、且释放尺寸正确。

测试覆盖 capacity `{0, 1, 2, 4, 55, 56, 57, 64}`：

- **边界是断言出来的不是假设的**：测试用 `SmallObjectSlab.canUse` 直接验证
  `56 → slab-backed`、`57 → standalone`（slab payload 上限 504 = 512 − 8 字节块头），
  未来改 `block_sizes` 或 wrapper 尺寸都会立刻让它失败，而不是悄悄退化成只测 slab；
- 每个形态都 publish `capacity − 1`（inline 乘积归一化掉前导零的真实形态，
  也正是「按 `len` 释放」会出错的形态），再验证 `capacitySliceMut().len` 仍是 `capacity`；
- FAM 尾部起始地址 == `@intFromPtr(self) + @sizeOf(BigInt)` 且 limb 对齐；
- 每次销毁后 `MemoryAccount.allocated_bytes` 回到 baseline；
- `capacity = 0` 的 null-`limbs_ptr` 形态、`len == capacity` 形态、
  `max_limbs + 1` 的 `BigIntTooLarge` 拒绝都在内。

**故障注入验证**：把 `destroyFromHeader` 的 inline 臂从 `capacity × 8` 改成 `len × 8`，
测试立即 abort（`reached unreachable code`）。这条断言不是装饰。

## 5. 性能：四组合 + 八实例谱系

### 5.1 JS 层（`same_runtime`，两侧各 2 实例、4 轮交错、每轮 3 样本）

| case | P0 | P1 | **P1/P0** | 四组合区间 | P1/qjs（P0） |
|---|---:|---:|---:|---|---:|
| `bigint_mul_2x2` | 1.1856 ms | 1.0889 ms | **0.9184** | [0.9084, 0.9287] | 1.5496（1.6872） |
| `bigint_mul_1x8` | 1.1968 | 1.0990 | **0.9183** | [0.9079, 0.9290] | 1.1909（1.2968） |
| `bigint_mul_8x1` | 1.1969 | 1.0989 | **0.9181** | [0.9070, 0.9294] | 1.4529（1.5825） |
| `bigint_mul_8x8` | 1.8094 | 1.7630 | 0.9744 | [0.9641, 0.9848] | 1.1600（1.1906） |
| `bigint_mul_16x16` | 3.9797 | 3.9234 | 0.9859 | [0.9819, 0.9899] | 1.0178（1.0324） |
| **`local_arith_loop`（对照）** | 5.9991 | 5.9981 | **0.9998** | [0.9996, 1.0001] | 0.9254（0.9256） |

**四组合全部同号**，且非 BigInt 对照 `local_arith_loop` 是 0.9998 ——
不是全局构建运气。

**顺序对称性**：P1 的 `1x8` = 1.0990 ms，`8x1` = 1.0989 ms，**差 0.01%**（门槛 ≤1%）。✓

### 5.2 八实例指令 / 周期谱系（`bigint_mul_2x2`，两侧各 4 个独立构建）

| 实例 | insn (G) | cyc (G) | | 实例 | insn (G) | cyc (G) |
|---|---:|---:|---|---|---:|---:|
| p0a | 10.5799 | 1.9297 | | p1a | 10.4871 | 1.7897 |
| p0b | 10.5714 | 1.9665 | | p1b | 10.4871 | 1.7858 |
| p0c | 10.5715 | 1.9673 | | p1c | 10.4872 | 1.7930 |
| p0d | 10.5798 | 1.9276 | | p1d | 10.4872 | 1.7926 |

```text
insn   P0 [10.5714, 10.5799]   P1 [10.4871, 10.4872]   worst P1/P0 0.9920  best 0.9912
cyc    P0 [ 1.9276,  1.9673]   P1 [ 1.7858,  1.7930]   worst P1/P0 0.9302  best 0.9077
```

P0 **两个 codegen 状态清晰可见**（`{p0a,p0d}` 1.928–1.930 G 与 `{p0b,p0c}` 1.966–1.967 G，
指令数也差 0.08%）—— 正是 build bistability 的形态，幅度约 2.0%。
P1 的四个实例落在 1.786–1.793 G 的同一状态。

⚠️ **P1 只观察到一个状态。**不能断言 P1 没有第二个更慢的状态；
能断言的是**在 8 个独立构建里，最差的 P1/P0 也是 0.9302**，
远在 P0 自身 2.0% 的布局摆幅之外。

### 5.3 归因：**这不是指令数收益**

指令数只降 0.88%，cycles 却降 7.2%。扩展事件集（p0a → p1a）：

| 事件 | p0a | p1a | Δ |
|---|---:|---:|---:|
| instructions | 10.5797 G | 10.4871 G | −0.88% |
| cycles | 1.9242 G | 1.7859 G | **−7.19%** |
| **L1-dcache-loads** | **4.6697 G** | **4.4146 G** | **−5.46%** |
| branches | 1.8083 G | 1.8250 G | +0.93% |
| branch-misses | 527,755 | 257,595 | −51%（**绝对量可忽略**：命中率 0.029%，省下约 0.14% cycles） |
| cache-misses | 64,309 | 58,152 | 两侧都可忽略 |
| stalled-cycles-frontend | 35.0 M | 14.4 M | 占 cycles 1.8% |
| stalled-cycles-backend | 599.8 M | 597.0 M | 基本持平 |

本轮共 8,000,000 次乘法（400 iterations × 20000）：

```text
少 2.551 亿次 L1 load   ≈ 每次乘法少 32 次 load
少 1.383 亿 cycles      ≈ 每次乘法少 17 cycles
少 9260 万条指令        ≈ 每次乘法少 11.6 条指令
```

**机制：per-access 的冗余 load 被删掉，不是工作量减少。**
旧表示每个读点都要物化内嵌 `libs.bigint.BigInt` 的 40 字节
（切片 ptr + len，加 `std.mem.Allocator` 的 ptr + vtable，加符号位）；
新访问器只 load 各站点真正需要的字段 —— `negative()` 是 1 字节，
`limbs()` 是 `limbs_ptr` + `len`。分支数反而**增加** 0.93%（`len == 0` 的空切片判别），
但 load 少了 5.46%。

⚠️ 按本项目既有口径（「insn 赢 ≠ 时间赢」「allocation-removal 才动 macro」），
**这是一个 memory-traffic 收益，不是 allocation 收益，也不是 insn 收益**。
它应当记为 P6-03b 的**观察到的副产品**，不是 P6-03 的目标 ——
P6-03 的目标（把两次分配并成一次 FAM）**仍未开始兑现**，那是 P6-03c 的事。

### 5.4 direct-core（`bigint/mul-multilimb`，四组合）

```text
insn  P1/P0 = 1.0001（四组合一致）
cyc   P1/P0 = 0.9939 ~ 0.9948
```

`src/libs/bigint.zig` 在 `958307e3..42077357` 之间**逐字节未变**，指令数 +0.01% 与之相符。
cycles 的 −0.5~−0.6% 略微越过 ±0.5% 的中性带，方向有利，
在测量代码源码完全相同的前提下**只能归因于二进制布局**，不构成机制主张。

## 6. 唯一 mutable consumer 的行为

`src/exec/value_ops.zig:789-799`，`binaryBigInt` 里 `op == add && rc == 1` 的就地加法臂，
是全仓唯一会变更已发布 BigInt 的地方。

改造形态：

```zig
pub fn addInPlaceExternal(self: *BigInt, other: libs.bigint.BigInt) !void {
    std.debug.assert(!self.flags.inline_storage);   // inline 存储扛不住 realloc
    var owned = self.externalOwnedValue();
    defer self.initExternalFromOwned(owned);        // 错误路径也重新收养
    try owned.addInPlace(other);
}
```

`addInPlace` 可以 realloc（换指针）、改长度、改符号，也可以把值清空（相抵为零时走 `deinit`）——
`defer` 让这四种结果全部被重新收养，**失败的扩容也不会留下悬空指针**。

### ⚠️ 但这条臂在 JS 层测不到

三个探针脚本（重复加、相抵归零、符号翻转、跨 limb 进位、临时值作左操作数）
在 P1 与 **P0** 上用同一方法探测：

| 断点 | bi_inplace | bi_inplace2 | bi_smoke |
|---|---:|---:|---:|
| `binaryBigInt` | 511 | 609 | 1006 |
| 就地加法臂（`value_ops.zig:798` / P0 `:800`） | **0** | **0** | **0** |

**P0 同样是 0**，所以这是**既有的休眠臂，不是 P6-03b 造成的**。
原因在 `vm_arith.binaryVm`：`op.add` 走 `toPrimitiveForAddition`，
它返回一个被 `defer .free` 持有的 owned 值，于是调用栈槽与该临时值同时持有引用，
`rc == 1` 永远不成立。

**处置**：不在 P6-03b 内修 —— 它与存储 carrier 无关，且改动会动到 `+` 的所有权协议。
记为独立待办。当前它的正确性由构造保证（assert + defer 重收养）与类型系统覆盖，
**没有 JS 层覆盖**，这一点必须明说。

## 7. 正确性门禁

| 门禁 | 结果 |
|---|---|
| test262 | **0/49775 errors**（passed 44541，known 25） |
| test-core / parser / bytecode / exec / builtins / runtime / runner | 300 / 463 / 188 / 388 / 193 / 72 / 43，全绿 |
| test-oom | 14 通过 |
| test-altrepr（另一种 JSValue 表示） | 1989 通过 |
| ReleaseSafe `test-core` | 300 通过 |
| force-GC `test-core` + BigInt 冒烟 | 300 通过；输出与常规构建逐字节相同 |
| 跨引擎随机差分 3702 行（mul/add/sub/div/mod/pow/位运算/移位/一元/比较/toString 2·8·10·16·36/asIntN/Number） | **与 pinned qjs 逐字节相同** |
| 就地加法专项探针（相抵归零 / 符号翻转 / 跨 limb 进位 / 变更后再读） | 与 qjs 逐字节相同 |
| poison-allocator basecase 乘法测试 | 通过 |
| carrier 单元测试 + 故障注入 | 通过；注入即 abort |

### 一处既有跨引擎分歧（与本刀无关）

`BigInt.asUintN` —— pinned qjs `04be2460` 返回带符号值
（`BigInt.asUintN(64, -1n)` 给 `-1`），zjs 给规范正确的 `18446744073709551615`。
这是 `docs/qjs-align/FIX-PLAN-2026-07-02.md` D10 里**有意为之的修正**，
在 P0 上同样存在，本轮差分对比时单独识别，未计为回归。

## 8. 裁决与限制

| 门槛 | 实测 | |
|---|---|---|
| wrapper 尺寸不变、slab class 不变 | 56 B / 同类 | ✓ |
| 分配拓扑不变（`mulAlloc` +1、`createFromOwned` +1、`createWithFam` 0） | 一致 | ✓ |
| JS BigInt 无 ≥1% 的稳定回退 | **无回退**（全部为 −1.4%~−8.2% 的收益） | ✓ |
| direct-core 无 ≥0.5% 的稳定变化 | insn +0.01%；cyc −0.5~−0.6%（布局，源码逐字节相同） | △ |
| `1x8` / `8x1` 差异 ≤1% | **0.01%** | ✓ |
| 正确性全套 | 全绿 | ✓ |

**通过，可进入 P6-03c。**

限制：

- **P1 只采到一个 codegen 状态**（4 个实例全部落在同一点）。
  不能断言 P1 不存在更慢的第二状态；只能断言 8 个实例的最差组合仍是 0.9302；
- 5.3 的机制解释（per-access 冗余 load）由 PMU load 计数支持，
  **未做指令级 diff 确认到底是哪些 load 被删** —— 符号占比在两侧不可比
  （`createFromOwned` 18.58% → 7.83%、`value_ops.binary` 20.27% → 8.64%，
  同时 `mulAlloc` 8.98% → 15.29%，是内联边界移动，不是这些函数各自变快那么多）；
- inline 存储仍**零生产可达**，只有测试在跑；它在 P6-03c 之前的价值仅是「不是死代码」；
- 只测了 `mul`；`add`/`sub`/`div`/`pow` 的分配拓扑仍未验证（P6-02 遗留项，未推进）；
- 就地加法臂无 JS 层覆盖（见 §6）。

## 9. P6-03c 的边界（不变）

```text
createHeapMulInline：自带一份 basecase 循环，直接写入 FAM 尾部
只接：canonical heap × heap
保持：sign-magnitude、64-bit limb、P6-01 首行覆写、P6-01c 短操作数作外层、
      normalization 语义、JS 可观察行为
不得动：libs/bigint.zig 的 mulAlloc（逐字节不变，用作 lockstep 差分基准）
```

⚠️ P6-03b 已经先行拿到 JS 层 −8.2%（2×2）。
**P6-03c 的收益必须相对 `42077357` 重新测量**，不得与 P6-02 的基线相减。
