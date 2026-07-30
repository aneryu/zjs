# P3-11 — Return 控制字段触达审计

- **日期**：2026-07-28
- **测量 HEAD**：`39a4ba79`（P3-10 已合入）
- **性质**：**只做画像，未改任何生产代码**
- **原始数据**：`P3-11-results.json`
- **结论**：**情况 B** —— 没有单一 continuation 字段突出，但普通返回每次执行**分层的特殊状态判别**，合计 2.39% of `fib_rec`

---

## 0. 当前绝对定位

```text
fib_rec           1.3157x QJS      (P3-10 前 1.3489)
call_body_loop    1.1398x
method_call_loop  1.1471x
```

---

## A. Epilogue family 命中表

12 个探针，各 200 次内层调用（`fib` 465、`countdown` 201），
计数点为 `op_return` 中各臂的入口地址与四个实体符号。
每行的 `generic=1` 是顶层 `run()` 自身。

| workload | `op_return` | `op_return_undef` | leaf:empty | leaf:exact | leaf:fwd | **generic** | ctor | tail-chain | generalTeardown | contDisp |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `empty` | 202 | 0 | **200** | 0 | 0 | 1 | 0 | 0 | 0 | 0 |
| `identity` | 202 | 0 | 0 | **200** | 0 | 1 | 0 | 0 | 0 | 0 |
| `countdown` | 203 | 0 | 0 | **201** | 0 | 1 | 0 | 0 | 0 | 0 |
| `fib` | 467 | 0 | 0 | 0 | 0 | **466** | 0 | 0 | 0 | 0 |
| `closure` | 202 | 0 | 0 | 0 | 0 | **201** | 0 | 0 | 0 | 0 |
| `method` | 202 | 0 | 0 | 0 | 0 | **201** | 0 | 0 | 0 | 0 |
| `arguments` | 202 | 0 | 0 | 0 | 0 | **201** | 0 | 0 | 0 | 0 |
| `native`（`f.call`） | 202 | 0 | 0 | 0 | 0 | **201** | 0 | 0 | 0 | 0 |
| `throw` | 2 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | **200** | 0 |
| `ctor` | 152 | **50** | 0 | 0 | 0 | 1 | **150** | 0 | **150** | 0 |
| `proxy`（数据 trap） | 402 | 0 | 0 | **200** | 0 | 1 | 0 | 0 | 0 | 0 |
| `forof`（数组） | 2 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 0 |
| **`special`**（JS trap + 自定义迭代器 + derived ctor） | 392 | 50 | 0 | 0 | 0 | 241 | 50 | 0 | 50 | **240** |

### 读法

1. **Leaf family** = `empty` / `identity` / `countdown` / `proxy`。
   这解释了 P3-10 中它们保持中性 —— 它们的返回根本不进 `popFrameMode`。
2. **Generic ordinary family** = `fib` / `closure` / `method` / `arguments` / `native`。
   ⚠️ `native`（`f.call(…)`）走 **generic**，不是 forwarded-leaf。
   **`leaf:forwarded` 在全部 13 个探针中命中为 0** ——
   该家族在本轮所有形态下没有生产消费者（不等于无消费者，但需要单独定位）。
3. **throw** 完全不经过 `op_return`：200 次抛出全部走 `deinitGeneralResources` 的 unwind 路径。
4. **constructor** 分两路：`popConstructorReturn` 150（普通构造器）
   + `op_return_undef` 50（derived constructor）。
5. **`op_post_call_continuation`（非 `.next` continuation）在前 12 个探针中全为 0**，
   包括 Proxy、for-of、native forwarding 与 constructor。
   只有专门构造的 `special` 探针（Proxy 的 **JS getter trap** + **自定义 `next()`** 的
   for-of + derived ctor）才命中 **240 次**。

## B. Entry 字段 → 消费者矩阵

Entry 布局（默认 16 字节 JSValue 表示，`sizeOf(Entry) = 256`）：

| 字段 | offset/size | setup 写/次 | generic return 读/次 | leaf return 读 | special 读 | 普通路径动态值 | 分类 |
|---|---|---:|---:|---|---|---|---|
| `frame`（含 pc/this/locals/args/…） | 0 / 152 | 每次（一次性） | 每次 | 每次 | 每次 | 动态 | **必需** |
| `frame.planned_stack_bytes` | 140 / 4 | 每次 | 每次 | — | 每次 | 动态 | **必需** |
| `frame.ownership` | 144 / 1 | 每次 | 每次 | — | 每次 | 恒 `.borrowed/.owned` 组合 | 必需（释放判别） |
| `frame.cold` | 128 / 8 | 每次（null） | 每次（`canUseSimpleTeardown`） | — | 每次 | **恒 null** | **判别税** |
| `stack` | 152 / 40 | 每次 | 部分（leaf 臂的 `len()`） | 每次 | 每次 | 动态 | **必需** |
| `catch_target` | 192 / 16 | 每次（null） | 每次（caller 恢复） | 每次 | 每次 | 动态 | **必需** |
| `arena_mark` | 208 / 16 | 每次 | 每次 | 每次 | 每次 | 动态 | **必需** |
| `native_caller` | 224 / 16 | **不写**（setup 注明留空） | **不读** | leaf 臂复用为 resume 记录 | ctor/forwarded 读 | — | 重叠存储，无普通税 |
| `prev` | 240 / 8 | 每次 | 每次 | 每次 | 每次 | 动态 | **必需** |
| **`continuation_payload`** | 248 / 4 | **每次写 0** | **每次加载** | 否 | 每次 | **恒 0** | **写入+加载均为死值**（见 §B.1） |
| `teardown` | 252 / 1 | 每次写 `{.simple=true}` | **每次加载 + 5 次位测试** | 每次 | 每次 | 恒 `.simple` | **判别税** |
| **`return_action`** | 253 / 1 | **每次写 `.next`** | **每次加载 + 测试** | 否 | 每次 | **恒 `.next`** | **判别税** |
| `profile_guard` | 252 / **0** | 零尺寸 | — | — | — | — | 无成本 |
| tail-chain budget | 覆盖 224 | 仅 tail replacement | **不读**（P3-10 已移出） | — | 仅 tail | — | 已处理 |

### B.1 `continuation_payload` 在普通路径上是死值（反汇编实证）

```text
125e0c4:  ldr  w24, [x21, #248]     ; continuation_payload —— 无条件加载
125e0c8:  ldrb w25, [x21, #253]     ; return_action
…
125eaf4:  cbz  w25, 125eb0c         ; return_action == .next -> 快路，w24 从此不再被读
125eafc:  strb w25, [x19, #219]     ; 仅非 .next 路径：vm.return_action
125eb04:  str  w24, [x19, #212]     ; 仅非 .next 路径：vm.return_payload
```

`w24` 在 `.next` 分支上**一次都没有被使用**。ReleaseFast 下
`std.debug.assert(continuation.payload == 0)` 已消失，加载纯属
`takeContinuation()` 按值返回结构体的产物。

### B.2 普通返回的判别链（逐条来自反汇编）

```text
ldrsb w8, [x21, #252]         ; teardown 字节，一次加载
tbnz  w8, #2   -> empty_leaf 臂
tbz   w8, #3   -> 跳过 exact_args_leaf（置位时还要 ldp [x21,#160] 读 stack 求 len）
tbz   w8, #4   -> 跳过 forwarded_leaf
tbnz  w8, #31  -> constructor_completion（ldrsb 符号扩展，bit7→bit31）
tbnz  w8, #5   -> tail_chain（P3-10 新增的外联出口）
ldrb  w25, [x21, #253]        ; return_action
…popFrameMode / deinitReturned 内部：
tbz   w8, #0                  ; teardown.simple
cbnz  x8                      ; frame.cold != null
tbnz  w8, #3 / tbnz w9, #6    ; canUseSimpleTeardown 余下两项
if teardown.has_native_caller ; inline_calls.zig:624
if teardown.constructor_completion  ; inline_calls.zig:630（第二次）
if frame.ownership.this_value == .owned
if frame.ownership.current_function == .owned
if frame.open_var_refs.len != 0
```

**普通返回在做真正的释放之前，要执行 1 次字节加载 + 至少 12 次条件测试**，
其中 `constructor_completion` 被测两次。

## C. Generic return 采样细分

`op_return` 的行级采样按阶段聚合（P3-10 后的当前二进制）。

| 阶段 | `fib_rec` 占 ret | 占 workload | `call_body_loop` 占 ret | 占 workload |
|---|---:|---:|---:|---:|
| 无行信息（内联产物 + 序言/尾声） | 28.51% | 6.24% | 22.55% | 3.06% |
| RC decref（在释放内部） | 15.79% | 3.45% | 12.17% | 1.65% |
| live-value 释放 | 11.65% | 2.55% | 12.84% | 1.74% |
| **特殊状态判别** | **10.91%** | **2.39%** | **7.76%** | **1.05%** |
| frame/top 恢复 | 10.12% | 2.21% | 8.90% | 1.21% |
| 其余每行 <0.8% | 7.16% | 1.57% | 17.27% | 2.34% |
| 深度/字节记账（P3-10 后仅剩单轮） | 6.07% | 1.33% | 4.90% | 0.66% |
| handler 序言/尾声 | 4.23% | 0.93% | 4.87% | 0.66% |
| arena restore | 2.74% | 0.60% | 3.45% | 0.47% |
| 结果压栈 | 1.47% | 0.32% | 3.49% | 0.47% |
| **continuation 解码** | **1.34%** | **0.29%** | 1.81% | 0.25% |

`op_return` 占 `fib_rec` 21.87%、占 `call_body_loop` 13.57%。

⚠️ 「无行信息」28.5% 无法进一步拆解，如实保留，不摊派到其他阶段。
⚠️ 采样占比是局部显式成本估计，不是收益上界（沿用第 3 刀更正口径）。

### 判别税内部最大的单项

`inline_calls.zig:624`（`if (self.teardown.has_native_caller)`）单行占
`op_return` 的 **6.22%**，即 **1.36% of `fib_rec`** —— 一条位测试。
该行是判别桶内最大的一项，值得在下一刀中单独留意（可能是分支预测或
`teardown` 字节的重复加载点，本轮未做微架构确认）。

## D. 下一刀裁决

按 §「下一刀选择规则」逐条比对：

| 规则 | 判定 |
|---|---|
| **情况 A**：默认 continuation 税最集中，相关 load/branch ≥ 2% of `fib_rec` | **不成立** —— continuation 解码仅 **0.29%**。setup 的两条写入与 return 的一次加载+测试确实每次发生，且 `return_action` 恒 `.next`、`continuation_payload` 恒 0 且在 `.next` 路径为死值，但**总量远未达 2%** |
| **情况 B**：无单一 continuation 字段突出，但 generic return 每次检查 constructor / tail / native forwarding / special teardown / profile mode | **成立** —— 判别税 **2.39% of `fib_rec`**，且分散在 12 次以上条件测试中，`constructor_completion` 被测两次 |
| 情况 C：主要成本仍是 arena/top/caller-region restore | 不成立（frame/top 恢复 2.21%、arena 0.60%，且属必要控制面） |
| 情况 D：没有任何字段或分支达到约 2% | 不成立（判别税 2.39%） |

### 建议的 P3-12

> **把普通返回的分层特殊状态判别收敛为一次 mode 测试**，
> 而不是逐条删 branch，也不是只删 `return_action` / `continuation_payload` 两条写入。

目标形态：

```text
ordinary mode  ->  一次测试即可确定：simple teardown + .next continuation +
                   无 constructor / native / forwarded / tail 状态
extended mode  ->  一个 cold 指针或 mode 值，承载
                   proxy_get / for_of_next / constructor / native forwarding /
                   forwarded-leaf / tail-chain
```

`return_action` 与 `continuation_payload` 应作为该 mode 的一部分一起隐式化
（`ordinary mode` 蕴含 `.next` + payload 0），这样才能同时拿掉
setup 的两条写入、return 的加载与测试，以及判别链中的若干位测试。

### 必须同时记录的天花板

```text
可移除上限（判别税 2.39% + continuation 解码 0.29%）≈ 2.68% of fib_rec
fib_rec 1.3157x  ->  乐观预期约 1.281x
退出线 1.20x     ->  仍差约 7%
```

即使 P3-12 完全达到预期，**`fib_rec ≤ 1.20x` 仍不可达**。
`op_return` 中剩余的 RC decref + live-value 释放（3.45% + 2.55%）、
frame/top 恢复（2.21%）、深度记账（1.33%）、arena restore（0.60%）
都是显式 Machine 帧栈的必要控制面。

因此建议在 P3-12 完成后**直接进入结构级 hold point**（P3-14 / P3-15 或转向 BigInt），
不要继续把余下的 0.3%–0.6% 项做成多刀 —— 这正是规则中警告的模式。

## E. Positive probes（已全部建立）

| 待冷化的特殊状态 | 正向消费者 | 命中 |
|---|---|---:|
| `return_action` / `continuation_payload`（`proxy_get`） | Proxy + **JS getter trap** | `op_post_call_continuation` 240（与 for-of 合计） |
| `return_action`（`for_of_next`） | 自定义 `[Symbol.iterator]` 的 `next()` | 同上 |
| `constructor_completion` | 普通 ctor / 返回 primitive / 返回 object / derived | `popConstructorReturn` 150 + `op_return_undef` 50 |
| `tail_chain` | 合成 bytecode 测试（parser 从不发射 tail_call） | `popTailChainFrameMode` 10（P3-10 已验证） |
| `has_native_caller` / forwarded-leaf | **本轮未找到生产消费者** | `leaf:forwarded` = 0（13/13 探针） |
| throw / unwind | throw + catch + 恢复后继续调用 | `deinitGeneralResources` 200 |

⚠️ **`leaf:forwarded` 与 `has_native_caller` 的正向消费者缺口是 P3-12 的前置条件**：
在把它们移出普通路径之前，必须先定位真实消费者（`Function.prototype.call`
的某个具体形态、或宿主 forwarding），否则无法区分「普通路径不需要它」
与「该机制已无消费者」。`native`（`f.call`）走的是 generic 而非 forwarded-leaf，
说明该家族的触发条件比预期窄。

## F. 方法学与限制

- 全部为动态计数 + 反汇编 offset 映射，未加诊断构建，未改源码；
- 计数点为 `op_return` 内两份判别链的臂入口地址（编译器为两条进入路径各生成一份），
  两份地址已合并计数；
- 「无行信息」28.5% 未拆解；
- `inline_calls.zig:624` 单行 6.22% 的成因（分支预测 / 重复加载）未做微架构确认；
- Table C 的阶段归属按源码行判断，边界为判断而非定义；
- `op_return_undef` 与 unwind 路径未做行级细分。
