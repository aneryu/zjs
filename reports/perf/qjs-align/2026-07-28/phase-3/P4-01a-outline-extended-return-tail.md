# P4-01a — 外联 extended return tail：**负结果，已回退**

- **日期**：2026-07-29
- **P0**：`502f5165`（代码等同 `203fd2c0`）
- **裁决**：**回退**。主目标 `fib_rec` 零改善，两项 4/4 稳定回退
- **原始数据**：`P4-01a-results.json`

---

## 1. One-cut 定义

把 `popAndResume` 的 constructor 臂与 generic-continuation 尾巴移进一个外联孪生：

```text
P0   op_return / op_return_undef 各自内联展开：
         ordinary + 三个 leaf 臂 + constructor 臂 + generic continuation

P1   op_return / op_return_undef 各自内联展开：
         ordinary + 三个 leaf 臂
     其余尾调用 extendedReturnTail（两者共享）
```

`popAndResume` 改取 Handler 参数以满足 musttail —— 手交必须是尾调用，
否则该帧会在被调者重入 dispatch 链后一直存活。返回值经 `vm.return_value` 传递，
那本来就是 continuation 臂使用的转移槽。

## 2. 静态：代码确实变小了

两个编译器态各自独立给出同一结果：

| 符号 | P0 | P1 | Δ |
|---|---:|---:|---:|
| `op_return` | 6440 | **4680** | **−1760** |
| `op_return_undef` | 6272 | **4608** | **−1664** |
| `op_post_call_continuation` | 828 | 被吸收 | −828 |
| `extendedReturnTail` | 不存在 | 2024 | +2024 |
| 编译器编号符号 | — | — | **净 0** |
| **全二进制符号字节** | — | — | **−2228** |

`op_return` 的原生帧 `sub sp, #0xd0`（208 字节）→ `sub sp, #0xb0`（**176 字节**），
序言存储条数 6 条。

## 3. 语义：extended 侧完全保持

| probe | `pushForwardedCall` | `releaseNativeCaller` | `popConstructorReturn` | `op_post_call_continuation` | `deinitGeneralResources` | **`extendedReturnTail`** |
|---|---:|---:|---:|---:|---:|---:|
| `fwd_leaf`（`z.call()`） | 0 | 0 | 0 | 0 | 0 | **0**（leaf 臂仍内联） |
| `fwd_generic` | 200 | 200 | 0 | 0 | 0 | **200** |
| `special` | 0 | 0 | 50 | 240 | 50 | **290** |
| `ctor` | 0 | 0 | 150 | 0 | 150 | **150** |
| `throw` | 0 | 0 | 0 | 0 | 200 | **0** |

全部与 P3-11F / P3-13 基线逐项相同，输出一致，
`Error().stack` 的 `at call (native)` 帧保留。**外联本身是正确的。**

## 4. 结果

| 分组 | workload | geomean | 方向 |
|---|---|---:|---|
| **TARGET** | **`fib_rec`** | **1.0018 (+0.18%)** | 3/4 |
| TARGET | `call_body_loop` | 0.9951 (−0.49%) | 4/4 |
| TARGET | `method_call_loop` | 0.9968 (−0.32%) | 3/4 |
| BOUNDARY | **`call_arguments`** | **1.0092 (+0.92%)** | **4/4** |
| BOUNDARY | `call_throw` | 1.0007 | 3/4 |
| SENTINEL | `call_empty_0` | 0.9958 (−0.42%) | 4/4 |
| SENTINEL | `call_identity_1` | 1.0016 | 4/4 |
| SENTINEL | **`recursive_countdown_1`** | **1.0078 (+0.78%)** | **4/4** |
| SENTINEL | `global_write_loop` / `prop_read_mono_loop` | 1.0007 / 1.0009 | 中性 |

### 裁决

| 门槛 | 实测 | |
|---|---|---|
| `fib_rec` 改善 ≥ 1% | **+0.18%（无改善）** | ✗ |
| 结构成功（0.5%–1% 改善 + 帧明显缩小 + leaf 保持 + extended 正确冷化） | 主目标无改善 | ✗ |
| `call_body_loop` 不回退 | −0.49% | ✓ |
| leaf 不回退 | `call_empty_0` −0.42%，`call_identity_1` +0.16% | ✓ |
| 无稳定回退 | **`call_arguments` +0.92%、`recursive_countdown_1` +0.78%，均 4/4** | ✗ |

**回退。**

## 5. 被证伪的是什么

P3-13 把 `op_return` 的 208 字节原生帧（12.72% of `op_return`，0.75 ns/call）
归因给「一个 handler 同时承担 ordinary + extended return」。本刀把 extended
完全移出后：

```text
函数体   6440 -> 4680   −27%
原生帧    208 ->  176   −15%
fib_rec  改善            0%
```

**那个原生帧主要不是 extended 链撑起来的。** 三个 leaf 臂仍然内联，
它们各自要保活 caller 的 resume 记录、region 基址、caller entry 指针，
序言仍要保存 6 组寄存器。把 extended 拿走只削掉 32 字节。

因此 P3-13 中「outline extended tail → 拿回 0.75 ns/call」这一预期是**错的**，
本 dossier 更正它：`op_return` 的序言属于 **ordinary 路径 + leaf 臂**，
不属于 extended machinery。

### 为什么两项还回退了

- **`call_arguments` +0.92%（4/4）**：它的帧由 `setupInlineEntry` 构造
  （`entry.teardown = .{}`，`simple = false`），因此 `isOrdinaryReturn()` 为假、
  又不是 leaf、不是 constructor —— 每次返回都真的落进外联函数，多付一次调用。
  这是机制而非布局。
- **`recursive_countdown_1` +0.78%（4/4）**：走 exact-args leaf 臂，
  该臂仍内联，回退来自 `op_return` 缩小 1760 字节后的代码放置位移。

## 6. 对路线的影响

```text
P4-01a  outline extended return tail        -> 负结果，关闭
P4-01b  Frame/Stack 表示审计                 -> 现在是唯一未被证伪的方向
```

P3-13 列出的两个「最大可结构性消除项」现在都被重新指认过：

| 项 | P3-13 的归因 | 修正后 |
|---|---|---|
| `op_return` 208 字节原生帧 | 多臂共享 extended machinery | **ordinary + leaf 臂的寄存器压力**（本刀证伪） |
| Entry 跨 4 条 cache line | 特殊状态占线 | **Frame/Stack 体积**（P4-00 证伪） |

两次修正都指向同一处：**剩余成本在普通路径自己需要的状态量上**，
不在它与特殊形态的共享上。P3-11 / P3-12 已经把「共享」这条线走完了。

因此下一步应是 **P4-01b Frame/Stack 表示审计** ——
先量五个切片与 `Stack` 的五个字段中，哪些必须逐帧存储，
哪些可由 FunctionBytecode 的常量几何或 Machine 的当前状态推导。
在那之前不应再对 Return 的代码形态下刀。

## 7. 限制

- 未尝试「只外联 constructor 臂、保留 generic continuation 内联」等中间形态；
- `recursive_countdown_1` 的回退按代码放置记录，未做 pad lineage 证伪；
- `call_arguments` 落入 extended 是既有分类的后果（`setupInlineEntry` 不置 `simple`），
  本轮未评估让它归入 ordinary 是否安全。
