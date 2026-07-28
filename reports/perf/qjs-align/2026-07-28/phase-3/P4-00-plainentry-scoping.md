# P4-00 — PlainEntry 立项前的作用域修正

- **日期**：2026-07-29
- **测量 HEAD**：`94b34df3`
- **性质**：只做度量与作用域判定，未改代码
- **结论**：**PlainEntry 的收益不可能来自「把特殊状态搬出 Entry」**。
  按原设想立项会做一件测不出收益的事。

---

## 0. 被检验的前提

P4 的立项理由是：

> 普通调用共享了所有特殊调用形态的控制结构；把 `return_action`、
> `continuation_payload`、`native_caller`、constructor、tail、profile 移进
> `ExtendedCallState`，普通 frame 就能落到 1–2 个 cache line。

前半句（控制流层面）已由 P3-11 / P3-12 证实并兑现。
**后半句（数据布局层面）需要单独验证，本轮验证结果是否定的。**

## 1. 普通返回实际触达的 Entry 字段

对 `op_return` 反汇编中经 Entry 指针（`x21`）的全部访问按字段归类
（`ldp`/`stp` 计双字段）：

| cache line | 字段 | 静态访问数 |
|---:|---|---:|
| **line0**（0–63） | `frame.this_value` 24、`frame.current_function` 14、`frame.locals` 12、`frame.function` 4、`frame.pc` 4 | **58** |
| **line1**（64–127） | `frame.args` 12、`frame.open_var_refs` 8 | **20** |
| **line2**（128–191） | `stack` 20、`frame.ownership` 14、`frame.planned_stack_bytes` 10、`frame.cold` 4 | **48** |
| **line3**（192–255） | `arena_mark` 24、`prev` 16、`teardown/return_action` 10、`native_caller` 10、`continuation_payload` 2 | **62** |

**普通返回触达全部四条 cache line，且 line3 访问最密集。**

## 2. 为什么搬走特殊状态换不到一条 cache line

拟移出 `ExtendedCallState` 的字段总共只有 **22 字节**：

```text
native_caller          224..239   16 B
continuation_payload   248..251    4 B
return_action          253         1 B
（constructor / tail 复用 native_caller 的存储，不额外占位）
```

它们全部落在 **line3**。而同一条线上还有：

```text
arena_mark   208..223   每次普通返回必读（24 次访问，line3 最高）
prev         240..247   每次普通返回必读（16 次）
catch_target 192..207   每次进入/恢复必写
teardown     252        分类要读
```

**line3 无法被消除。** 22 字节搬走后 Entry 从 256 降到约 234 字节，
仍然跨四条 cache line（>192）。

## 3. 真正的体积在哪里

| 组成 | 字节 | 说明 |
|---|---:|---|
| `Frame` 的五个 `[]T` 切片 | **80** | `locals`/`args`/`var_refs`/`open_var_refs`/`storage_values`，各 ptr+usize |
| 两个 JSValue 调用绑定 | 32 | `this_value` + `current_function`（默认表示各 16 B） |
| `Stack` | 40 | `memory`/`values`/`top_ptr`/`capacity`/`policy` 各 8 B |
| `arena_mark` | 16 | |
| `catch_target` | 16 | |
| 特殊完成状态 | 22 | ← 原方案唯一要动的部分 |
| 其余（function/pc/cold/argc/planned/ownership/prev） | 约 50 | |

**要把 Entry 压到 3 条线（≤192 B）必须动切片与 Stack；压到 2 条线（≤128 B）
还要动两个 JSValue 绑定。** 这是 Frame/Stack 表示层改造，
与「把特殊 completion 搬进 sidecar」是两件不同的工程。

粗算：五个切片的 `len` 若由 `usize` 改为 `u32`，省 20 B；
若其中若干可由 FunctionBytecode 的常量几何推导而不必逐帧存储，省得更多。

## 4. 与另一项结构成本的分工

P3-13 定位到的两个最大可结构性消除项，指向**不同的**改造：

| 项 | 成本 | 正确的改法 |
|---|---:|---|
| `op_return` 自身 208 字节原生帧 + 11 寄存器保存 | **0.75 ns/call**（12.72% of `op_return`） | **外联 extended 尾巴** —— 该帧由整条 extended 链的活跃值撑起，与 Entry 大小无关 |
| Entry 跨 4 条 cache line | 未单独量化 | **缩小 Frame/Stack 体积**，非搬移特殊状态 |

⚠️ 前者更便宜、已完整定界，且不依赖后者。

## 5. 建议的 P4 作用域修正

```text
原 P4-01：PlainEntry 双轨（PlainEntry + ExtendedCallState）
          → 主要动作是搬移 22 字节特殊状态
          → 本轮证明换不到 cache line，收益无来源

修正为：
  P4-01a  外联 extended return tail
          目标：op_return 6440 B / 208 B 帧显著缩小
          已知代价：leaf 臂变冷（目前 call_empty_0 −0.57%，4/4）
          性质：单机制 one-cut，风险可控

  P4-01b  Frame/Stack 体积缩减可行性评估
          先量：五个切片的 len 是否都必须逐帧存储
                Stack 的 capacity/policy/memory 是否可由 Machine 共享
          只有确认能把 Entry 压进 3 条线，PlainEntry 才有明确收益来源
```

**不建议**现在按原设想建立双轨 PlainEntry：它需要给 `machine.top` 引入
公共 header 或标签联合，改动 backtrace walker、unwinder、GC root walker、
driver 的每一个消费者，而本轮数据显示其主要动作（搬 22 字节）没有收益来源。

## 6. 对目标的影响

P3-13 的理论上限估算不变：

```text
return  5.91 ns -> 接近 qjs 1.54 ns    可拿约 4 ns
entry   9.55 ns -> 接近 qjs 7.45 ns    可拿约 1.5-2 ns
body    +1.10 ns                       不优先
```

但**这 4 ns 的主要来源需要重新指认**：不是 Entry 字段搬移，而是
（a）`op_return` 的原生帧与多臂共享，（b）Frame/Stack 的体积。
两者都比原方案更接近「qjs 的普通返回是 alloca 帧上的一次 C return」这一根因。

## 7. 限制

- 访问计数为**静态**（反汇编中出现的次数），非动态执行次数；
  它证明的是「哪些字段在普通返回的代码里被访问」，不是各自的动态频次；
- `opCall` 侧未做同样归类：其 Entry 指针寄存器在展开后不唯一，
  静态归属不可靠，本轮只报 `op_return`；
- Entry 跨 4 条线的**动态**代价（L1D miss / 行填充）未测量，
  本轮只证明了「搬走特殊状态不减少行数」这一必要条件不成立。
