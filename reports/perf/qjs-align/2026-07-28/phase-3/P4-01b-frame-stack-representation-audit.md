# P4-01b — Frame / Stack 表示可行性审计

- **日期**：2026-07-29
- **测量 HEAD**：`126f58ba`
- **性质**：只做审计，未改代码
- **结论**：**空间存在，值得做**。乐观口径 `256 B → 128–136 B`，落在「值得」区间下沿
- **原始数据**：`P4-01b-results.json`

---

## 0. 对照基准：qjs 的帧是 64 字节

```c
typedef struct JSStackFrame {          // quickjs.c:407
    struct JSStackFrame *prev_frame;   //  8
    JSValue cur_func;                  //  8   (JSValue = uint64_t，NaN-boxed)
    JSValue *arg_buf;                  //  8
    JSValue *var_buf;                  //  8
    struct JSVarRef **var_refs;        //  8
    const uint8_t *cur_pc;             //  8
    int arg_count;                     //  4
    int js_mode;                       //  4
    JSValue *cur_sp;                   //  8
} JSStackFrame;                        // = 64 字节，恰好一条 cache line
```

**zjs `Entry` = 256 字节，四条线。**

qjs 帧里**没有**的东西，正是差额的构成：

| qjs 不存 | 它在哪里 |
|---|---|
| `this_obj` | `JS_CallInternal` 的 C 局部/参数 |
| arena mark | `alloca`，随原生栈自动回收 |
| catch target | C 控制流，无需帧内记录 |
| stack capacity / policy / allocator | `alloca` 尺寸编译期已知 |
| 各切片长度 | `b->var_count` / `b->arg_count` / `b->closure_var_count` |
| teardown / continuation / native caller | 不存在这些机制 |

⚠️ 其中 8 字节 JSValue 是表示层差异（zjs 默认 16 字节，另有 nan_boxing 备选），
不属于帧设计。

## 1. 逐字段审计

### 1.1 `Frame`（152 字节）

| 字段 | off | size | 每次调用写 | 普通返回读 | 可否推导 | 判定 |
|---|---:|---:|---|---|---|---|
| `function` | 0 | 8 | 是 | 是 | — | 保留（qjs 由 `cur_func` 推，zjs 缓存） |
| `pc` | 8 | 8 | 是 | 是 | — | 保留（qjs `cur_pc`） |
| `this_value` | 16 | 16 | 是 | 是（释放） | — | 保留；**qjs 根本不存**（C 局部） |
| `current_function` | 32 | 16 | 是 | 是（释放） | — | 保留（qjs `cur_func`，8 B） |
| `locals` | 48 | 16 | 是 | 是 | **len = `function.var_count`**（`initFrameLocals` 已断言） | **只留 ptr，−8** |
| `args` | 64 | 16 | 是 | 是 | **len = `max(actual_arg_count, function.arg_count)`** | **只留 ptr，−8** |
| `var_refs` | 80 | 16 | 是 | 是 | **len = `function.closureVarCount()`** | **只留 ptr，−8** |
| `open_var_refs` | 96 | 16 | 是 | 是（`len != 0` 测试） | **len = `frameOpenVarRefStorageCount(function)`** | **只留 ptr，−8**；fib 实测 0，可整体入 Extended |
| `storage_values` | 112 | 16 | 是 | 是（ownership） | 仅 heap fallback 非空；fib 实测 0 | **→ Extended，−16** |
| `cold` | 128 | 8 | 是（null） | 是 | — | 保留（一次测试） |
| `actual_arg_count` | 136 | 4 | 是 | 是 | — | 保留（qjs `arg_count`） |
| `planned_stack_bytes` | 140 | 4 | 是 | 是 | **= `qjsBytecodeFrameAllocaSize(...)`**，代码注释本就称重算是 Debug lockstep guard | **可推导，−4** |
| `ownership` | 144 | 1 | 是 | 是 | — | 保留 |

**Frame 152 → 约 100。**

### 1.2 `Stack`（40 字节）

| 字段 | size | 来源 | 判定 |
|---|---:|---|---|
| `memory` | 8 | `&rt.memory` —— **运行时全局** | **−8** |
| `policy` | 8 | `rt.vm_stack_arena_policy` —— **运行时全局**（`runtime.zig:896/1070/2743` 只在 runtime 级设置） | **−8** |
| `capacity` | 8 | arena 窗口 = `function.stack_size + 1` | **−8** |
| `values` | 8 | **= `locals.ptr + locals.len`** —— `deinitSimpleResources` / `deinitOrdinarySimpleResources` **已经断言此恒等式**（`inline_calls.zig:673/696`） | **−8** |
| `top_ptr` | 8 | sp | 保留（qjs `cur_sp`） |

**Stack 40 → 8。** 四个字段中三个是运行时全局或 bytecode 常量，
第四个的可推导性**代码里本来就写着断言**。

### 1.3 `Entry` 非 Frame 部分

| 字段 | size | 判定 |
|---|---:|---|
| `catch_target` | 16（`?usize`，实测 `@sizeOf(?usize)=16`） | 改哨兵 `usize` → 8，**−8** |
| `arena_mark` | 16（`{chunk: 8, used: 8}`） | 两半各可收窄至 u32 → 8，**−8** |
| `native_caller` | 16 | **→ Extended，−16** |
| `prev` | 8 | 保留（qjs `prev_frame`） |
| `continuation_payload` | 4 | **→ Extended，−4** |
| `teardown` | 1 | 保留 |
| `return_action` | 1 | **→ Extended，−1** |

## 2. Q1 — 256 字节里有多少是真正的动态状态

| 类别 | 字节 |
|---|---:|
| 可由 FunctionBytecode 推导（4 个切片长度 + `stack.capacity` + `planned_stack_bytes`） | **44** |
| 可由 Machine/runtime 推导（`stack.memory`、`stack.policy`） | **16** |
| 可由其它帧字段推导（`stack.values`，代码已断言） | **8** |
| 可移入 Extended（`storage_values`、`native_caller`、`continuation_payload`、`return_action`） | **37** |
| 可打包收窄（`catch_target` 16→8、`arena_mark` 16→8） | **16** |
| **合计可回收** | **约 121** |
| **真正不可约的动态状态** | **约 135** |

## 3. Q2 — PlainEntry 最低能到多少

```text
保守口径（长度全部推导 + 四项入 Extended + Stack 收缩 + 两项打包）
    function 8 + pc 8 + this_value 16 + current_function 16
  + locals.ptr 8 + args.ptr 8 + var_refs.ptr 8 + open_var_refs.ptr 8
  + cold 8 + actual_arg_count 4 + ownership 1
  + stack.top_ptr 8
  + catch_target 8 + arena_mark 8 + prev 8 + teardown 1
  ≈ 136 字节        （3 条 cache line，宽裕）

再把 open_var_refs.ptr 也入 Extended（fib 实测 0）
  ≈ 128 字节        （2 条 cache line，刚好）

再把 this_value 移出帧（qjs 正是这么做的：C 局部）
  ≈ 112 字节

若同时启用 nan_boxing（两个 JSValue 绑定 32 -> 16）
  ≈ 112 -> 96 字节
```

## 4. Q3 — 值不值得

判据：`256 → 128~160` 值得，`256 → 224` 不值得。

**实测落点 128–136，值得做**，但在「值得」区间的**下沿**：

- 保守口径 136 只到 3 条线，未达 2 线；
- 要进 2 线必须把 `open_var_refs` 也冷化；
- 要进 1 线（对齐 qjs 的 64 B）**不可能**，除非同时改 JSValue 表示
  并把 `this_value` / `catch_target` / `arena_mark` 全部移出帧 ——
  那已经是 native-recursive 的形态（qjs 正是靠 C 栈免掉这三样）。

## 5. 消费者矩阵（删除前必须逐项确认）

| 候选 | 已知消费者 | 状态 |
|---|---|---|
| `storage_values` | teardown 的 `releaseOwnedStorage`（仅 heap fallback 帧） | 需确认 GC/unwind 无其它读者 |
| `native_caller` | `releaseNativeCaller` + `resolveMachineBacktrace`（**可观察 `Error().stack`**） | **P3-11F 已完整定位**，必须整体保留在 Extended |
| 四个切片长度 | `core/object.zig:1071-1077` 存在整片交换 `frame.locals` / `frame.args` 的路径 | ⚠️ **未审计**，是长度推导的首要风险点 |
| `stack.capacity` | `values[0..capacity]` backing 视图、`setLen` / `setTopPtr` 断言、grow 路径 | 需确认 arena 窗口帧不走 grow |
| `stack.policy` / `memory` | 仅构造与 grow | 低风险 |
| `catch_target` 收窄 | 异常 unwind | 需确认哨兵值不与合法 pc 偏移冲突 |
| `arena_mark` 收窄 | `vm_stack.restore` | 需确认 chunk 数与 used 上限可入 u32 |

⚠️ **`core/object.zig` 的帧交换路径是本审计发现的最大未知项**：
若它整片交换 `frame.locals` / `frame.args`，长度就不是纯派生量，
必须先确认该路径的语义（generator/async 帧搬迁？）再决定。

## 6. 与前两次证伪的关系

Phase 3–4 至此三次修正，方向一致：

| 轮次 | 被证伪的归因 | 修正后 |
|---|---|---|
| P4-00 | Entry 四条线由特殊状态造成 | 特殊状态仅 22 B 且与热字段同线 |
| P4-01a | `op_return` 208 B 帧由 extended 链造成 | 属 ordinary + leaf 臂的寄存器压力 |
| **P4-01b** | —— | **剩余成本在普通路径自己携带的状态量：121 B 中有 68 B 是可推导或运行时全局的重复保存** |

**「zjs 每帧重复保存 bytecode 常量与运行时全局」是本次审计的核心发现**：
四个切片长度、`stack.capacity`、`planned_stack_bytes` 共 44 字节全部来自
FunctionBytecode；`stack.memory` / `stack.policy` 共 16 字节是运行时全局；
`stack.values` 8 字节的可推导性代码里已经写着断言。**68 字节是纯冗余。**

## 7. 建议

```text
P4-02  FrameLayout（先于 PlainEntry）
       把 44 B 的 bytecode 常量推导落地为 publication-time layout，
       把 16 B 的运行时全局从 Stack 移除，
       把 stack.values 改为 locals.ptr + var_count（断言已存在）
       —— 这 68 B 不需要新的 Entry 类型，也不改任何消费者语义

       前置：审计 core/object.zig:1071-1077 的帧交换路径

P4-03  PlainEntry（仅在 P4-02 兑现后）
       把 storage_values / native_caller / continuation / return_action
       共 37 B 移入 Extended，catch_target 与 arena_mark 收窄 16 B
```

理由：P4-02 的 68 字节**不需要双轨类型、不需要改 backtrace/unwind/GC 消费者**，
风险显著低于 PlainEntry，且它先落地后 PlainEntry 的剩余收益（53 B）
才能被单独归因。

⚠️ 空间存在不等于时间存在。P4-00 已证明普通返回触达全部四条线且热字段分散其上；
把 256 压到 136 是否兑现为 `fib_rec` 的时间收益，**必须实测，不得假定**。

## 8. 限制

- 切片长度的可推导性由源码断言与单点动态观测（fib）支持，**未做全形态验证**；
- `core/object.zig` 帧交换路径未审计，是长度推导的已知风险；
- `catch_target` / `arena_mark` 的收窄只做了尺寸算术，未验证取值范围；
- 未评估 nan_boxing 作为独立杠杆；
- 全部为静态审计，未做原型实现，因此**没有任何时间收益的实测支持**。
