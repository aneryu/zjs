# Phase 3.0 — 普通调用成本基线（P3-01 / P3-02）

- **日期**：2026-07-28
- **测量 HEAD**：`47b49015`
- **pinned QuickJS**：`04be2460`，VERSION 2026-06-04
- **绑核**：CPU 19（aarch64 big.LITTLE）
- **原始数据**：`baseline.json`
- **状态**：**Phase 3.0 完成，第一刀候选已由动态证据选定**

---

## 1. 当前 P0 退出线状态

```text
P0 policy-sentinel geomean (zjs/qjs) = 1.0716      退出线 <= 1.10   已满足
fib_rec                              = 1.3489      目标   <= 1.20   未满足
```

⚠️ **P0 geomean 已经在退出线内**。Phase 3 因此不是为了把 geomean 拉进 1.10，
而是为了消除 `fib_rec` 这一项以及它背后那类普通调用固定成本。

| workload | qjs | zjs（两实例） | zjs/qjs | 分组 |
|---|---:|---|---:|---|
| `prop_read_mono_loop` | 12.7595 ms | 11.0717 / 11.0871 | **0.8683** | P0 / sentinel |
| `typed_array_read` | 3.4304 | 3.3211 / 3.3237 | 0.9685 | P0 |
| `typed_array_write` | 3.6925 | 3.7668 / 3.7341 | 1.0157 | P0 |
| `global_write_loop` | 0.8873 | 0.9364 / 0.9381 | 1.0562 | P0 / sentinel |
| `method_call_loop` | 13.4009 | 15.4353 / 15.4823 | 1.1536 | P0 / call |
| `call_body_loop` | 10.4783 | 12.1313 / 12.0983 | 1.1562 | P0 / call |
| `fib_rec` | 3.2202 | 4.3463 / 4.3410 | **1.3489** | P0 / call |
| `local_arith_loop` | 6.4896 | 5.9940 / 5.9938 | 0.9236 | sentinel |

`global_write_loop` 复现了 Phase 2 收口值（1.0562 vs 1.0574，不同轮次）。

## 2. 九个 call workload

六个新增（`call_empty_0`、`call_identity_1`、`call_identity_4`、`call_8_locals`、
`call_arguments`、`call_throw`），三个复用现有 policy sentinel
（`fib_rec` = 递归、`method_call_loop` = call-method、`call_body_loop` = call-closure）。
新增的六个**不入 policy.json**，以免改变 P0 退出线组成。九个全部跨引擎逐字节同输出。

| workload | qjs ns/次 | zjs ns/次 | delta | zjs/qjs |
|---|---:|---:|---:|---:|
| `call_throw` | 29.49 | 73.40 | **+43.91** | **2.4891** |
| `call_arguments` | 81.88 | 129.14 | **+47.26** | **1.5771** |
| `call_identity_4` | 21.98 | 33.15 | **+11.17** | **1.5084** |
| `fib_rec`（每次 fib 调用） | 21.46 | 28.95 | +7.49 | 1.3489 |
| `call_identity_1` | 20.48 | 25.09 | +4.61 | 1.2253 |
| `call_empty_0` | 19.67 | 23.97 | +4.30 | 1.2186 |
| `call_body_loop` | 34.93 | 40.38 | +5.46 | 1.1562 |
| `method_call_loop` | 44.67 | 51.53 | +6.86 | 1.1536 |
| `call_8_locals` | 61.03 | 68.24 | +7.21 | 1.1181 |

⚠️ 每次成本含循环开销。`local_arith_loop` 显示 zjs 的循环本身**快于** qjs（0.9236），
因此上表的 delta 是**保守**的（真实调用差距更大）。

## 3. 核心发现：argc 3→4 存在一个台阶

argc 0..8 扫描（同一 workload 形态，只改参数个数）：

| argc | qjs ns/次 | zjs ns/次 | delta | qjs 增量 | zjs 增量 |
|---:|---:|---:|---:|---:|---:|
| 0 | 19.59 | 24.00 | +4.41 | — | — |
| 1 | 20.35 | 25.16 | +4.81 | 0.76 | 1.16 |
| 2 | 20.67 | 25.59 | +4.92 | 0.32 | 0.43 |
| 3 | 21.48 | 26.16 | +4.68 | 0.81 | 0.57 |
| **4** | 21.88 | **33.22** | **+11.34** | 0.39 | **7.06** |
| 5 | 22.52 | 33.71 | +11.19 | 0.65 | 0.49 |
| 6 | 23.16 | 34.29 | +11.13 | 0.64 | 0.58 |
| 8 | 24.98 | 35.28 | +10.30 | 1.81 | 0.98 |

**qjs 全程平滑（每参数约 0.5 ns）。zjs 在 3→4 处跳 +7.06 ns，其余每步约 0.5 ns。**
这不是「每参数成本高」，而是**一个特化边界**。

### 机制

`f(1,2,3)` 发 `OP_call3`，`f(1,2,3,4)` 发 `OP_call`（带 argc 操作数）。
`opCall` 的五个实例中，`.operand` 被**每一条快臂排除**
（`src/exec/tailcall_dispatch.zig`）：

```text
wire_exact_args_leaf   .one .two .three = true   .operand .zero = false
wire_padded_args_leaf  .zero .one .two .three = true   .operand = false
inline_exact           .one .two .three = true   .operand .zero = false
```

于是 argc≥4 落到 `pushAndEnter(..., inline_exact = false)` → 外联构造器。

### profile 佐证

| | argc=3 | argc=4 |
|---|---|---|
| `opCall` handler | 27.43% | 25.89% |
| `op_return` | 30.76% | 19.68% |
| **`Machine.pushExactSimpleFrame`** | **不在榜（已内联）** | **16.45%（独立外联符号）** |

`pushExactSimpleFrame` 单个实例 **1448 字节**，原生帧 **208 字节**。
每次普通调用一次 `bl`。**这与 Phase 2 的 `put_var → coldStd` 同构**：
同一个机制（VM-state publication/reload 与寄存器驻留丢失），换了一个位置。

## 4. 动态 call-site 计数（每 200 次调用）

| argc | `setupInlineEntry` | `FrameSlab.carve` | `allocHeap` | `execCall` | `Frame.ensureCold` |
|---:|---:|---:|---:|---:|---:|
| 0–5 | 1 | 1 | 0 | 1 | 0 |

每列的 `1` 是顶层 `run()` 自身那一次。**200 次内层调用全部不经过这些通用入口**，
也没有 heap fallback、没有 `FrameCold` 物化。换言之：普通调用的成本
**不在**通用 adapter、不在 arena grow、不在冷 side-struct，而在已经「快」的那条路本身。

## 5. Entry / Frame 布局（默认 16 字节 JSValue 表示）

```text
sizeOf(Entry) = 256
  Entry.frame                 off=  0  size=152
  Entry.stack                 off=152  size= 40
  Entry.catch_target          off=192  size= 16
  Entry.arena_mark            off=208  size= 16
  Entry.native_caller         off=224  size= 16
  Entry.prev                  off=240  size=  8
  Entry.continuation_payload  off=248  size=  4
  Entry.teardown              off=252  size=  1
  Entry.return_action         off=253  size=  1

sizeOf(Frame) = 152
  function 0 / pc 8 / this_value 16 / current_function 32 / locals 48 /
  args 64 / var_refs 80 / open_var_refs 96 / storage_values 112 /
  cold 128 / actual_arg_count 136 / planned_stack_bytes 140 / ownership 144
```

Entry 跨 **4 个 cache line**。热控制面（`prev` 240、`continuation_payload` 248、
`teardown` 252、`return_action` 253）全部挤在**第四条 line 的尾部**，
而 `frame` 前 64 字节在第一条 line —— 一次普通调用至少触达第 1、3、4 条 line。

### 无条件默认 continuation 写入（3.1A 假设成立）

`inline_calls.zig:1404-1405`，普通调用路径上无条件执行：

```zig
entry.return_action = .next;
entry.continuation_payload = 0;
```

两个字段相邻（248 / 253），后端很可能合并为一次 8 字节存储。
反汇编中另可见 `stp xzr, xzr, [x27, #192]`（`entry.catch_target = null`，16 字节）。

⚠️ **但按目前证据，3.1A 单独不足以解释 7 ns 台阶**：这是 1448 字节构造器里的
两三条存储。3.1A 应作为**便宜的验证刀**执行（确认 stores 是否是热成本），
不应期待它拿下台阶。

## 6. argv 审计的初步结论（P3-07）

`canBorrowSourceArgs` 在 `argc >= arg_count` 且 source 未被 moved 时返回 true，
`call_identity_4` 属于该形态 → **借用，不复制**。反汇编中确有一处
`str q1, [x22], #16` 后增量拷贝循环，但尚未定位其对象（args 转移 / locals 填充 /
operand region 搬运）。**该项标记为未完成**，需要在动手前用动态计数坐实
copy/dup/memmove 是否为 0，而不是据此推断。

## 7. 第一刀候选与理由

按 §4.6 优先级与实测证据：

```text
选定：普通（generic-argc）调用路径的外联帧构造器
理由：唯一被动态证据定位的单点，+7.06 ns/call，profile 中 16.45% 独立符号，
      且与 Phase 2 已验证成功的机制同构
```

**明确不做的事**：不把 `wire_exact_args_leaf` / `inline_exact` 直接打开到
`.operand`。那是加宽既有 leaf bypass，计划 §0.2 与 §8.3 已禁止，而且它会
把成本藏起来而不是消除 —— 普通路径仍然贵，只是不再有人走。

正确方向是让 `pushExactSimpleFrame` 这条**普通路径**本身变便宜（Phase 3.1 / 3.2），
然后用 argc 台阶是否收窄来**验证**：台阶收窄 = 普通路径真的变便宜；
台阶不变而只有 argc≥4 变快 = 又做了一次特化。

## 8. 待完成项

- `call_arguments`（+47 ns）与 `call_throw`（+44 ns）未做机制归因；
  两者都远大于普通调用固定税，但属于语义形态，不是 §2.1 退出线对象；
- setup/return 分段 profile（§4.4）未做；
- Entry 字段完整 writer/reader 消费者矩阵（§4.3）只完成布局与热控制面部分；
- argv copy 计数未坐实（见 §6）。

## 9. 方法学限制

- 两个 build instance 不构成配对 compiler state，比较取跨实例组合；
- 每次成本由 workload 总时间除以迭代数得到，含循环开销（已说明为保守方向）；
- profile 百分比是相对量，不作为收益证明；
- 临时布局探针（`@compileError` 打印偏移）未进入提交。
