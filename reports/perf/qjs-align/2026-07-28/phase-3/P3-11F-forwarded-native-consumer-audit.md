# P3-11F — `forwarded_leaf` / `has_native_caller` 消费者定位

- **日期**：2026-07-28
- **测量 HEAD**：`dd2e4096`
- **性质**：**只做定位，未改任何代码**
- **裁决**：**情况 1 —— 两者都是活的生产机制，各有正向消费者**
- **原始数据**：`P3-11F-results.json`

---

## 0. P3-11 的缺口是探针形状错误，不是机制缺失

P3-11 报告「13/13 探针中 `leaf:forwarded` = 0，未找到生产消费者」。
从 producer 反向构造后，原因是**探针形状不满足 producer 的门**：

- 当时用的是 `f.call(null, i, 1)` —— `argc = 3` 且 `thisArg = null`；
- producer 要求 `argc <= 1` **且** `thisArg` 为 `undefined` **且**目标是
  已发布的零参 sloppy empty leaf。

三个条件全不满足。这正是计划中「不要先从名称猜测触发方式，应从实际 producer
反向构造正向 probe」所针对的错误。

同时，P3-11 说「`has_native_caller` 无生产消费者」也是**仪表缺口而非机制缺失**：
当时的计数表里根本没有 `pushForwardedCall` 与 `releaseNativeCaller` 两列。
那个 `native` 探针其实每次都设置了该位。

---

## 1. `forwarded_leaf` 完整数据流

```text
producer   Machine.finishForwardedEmptyLeafFrame        inline_calls.zig:3136
             ← Machine.tryPushForwardedEmptyLeafCallFast  inline_calls.zig:3157
             ← op_call_method 的 `.call` 臂                tailcall_dispatch.zig:1599-1606
门          argc <= 1  且  this_arg.isUndefined()  且
            target.call_facts.execution.simple_inline_empty_leaf
storage     Entry.teardown bit4（Entry+252）
consumers   popAndResume 的 forwarded-leaf 返回臂         tailcall_dispatch.zig:1169
            Entry.deinitForwardedLeafInline               inline_calls.zig:586
            Machine.popReturnedForwardedLeaf              inline_calls.zig:3460
            Entry.deinit 路由到 deinitGeneral             inline_calls.zig:474
            Entry.deinitReturned 同一路由                 inline_calls.zig:655
completion  零参 leaf 的窄 epilogue + 自有 native `call` 帧释放
```

**唯一 producer，唯一发布点。**

## 2. `has_native_caller` 完整数据流

```text
producers   (1) Machine.finishForwardedEmptyLeafFrame     inline_calls.zig:3135
                （与 forwarded_leaf 同时置位）
            (2) Machine.pushForwardedCall                 inline_calls.zig:3214
                ← pushForwardedAndEnter                   tailcall_dispatch.zig:861
                门：任何经 Function.prototype.call 转发到 bytecode 目标的调用
storage     Entry.teardown bit1 + Entry.native_caller（Entry+224，自有引用）
consumers   (a) Entry.releaseNativeCaller                 inline_calls.zig:448
                ← deinitReturned:624 / deinit:643        —— **所有权**
            (b) resolveMachineBacktrace                   inline_calls.zig:717
                —— **可观察 JS 语义**（见 §4）
            (c) leaf/tail 覆盖存储的断言（该字段存储被复用）
```

⚠️ `canUseSimpleTeardown`（:440）**不**测试 `has_native_caller` ——
它只看 `teardown.simple`、`frame.cold`、`ownership.storage`、`stack.isArenaWindow()`。
因此该位是在释放序列内部（:624）单独测试的，这解释了为什么
`fwd_generic` 等探针的 `deinitGeneralResources` 命中为 0。

## 3. 正向 probe 与命中（每探针 200 次调用，`generic=1` 为顶层 `run()`）

| probe | 形状 | leaf:fwd | generic | `pushForwardedCall` | `releaseNativeCaller` |
|---|---|---:|---:|---:|---:|
| `fwd_leaf` | `z.call()`，`z` 零参 leaf | **200** | 1 | 0 | 0 |
| `fwd_leaf_u` | `z.call(undefined)` | **200** | 1 | 0 | 0 |
| `fwd_leaf_this` | `z.call(o)`（thisArg 非 undefined） | 0 | 201 | **200** | **200** |
| `fwd_generic` | `g.call(undefined,i,1)` | 0 | 201 | **200** | **200** |
| `fwd_gen_null` | `g.call(null,i,1)` | 0 | 201 | **200** | **200** |
| `native`（P3-11 的旧探针） | `f.call(null,i,1)` | 0 | 201 | **200** | **200** |
| `fwd_apply` | `g.apply(null,[i,1])` | 0 | 1 | **0** | **0** |

### 读法

1. **`forwarded_leaf` 是活机制**，触发面很窄：只有零参 leaf + `undefined`/缺省 thisArg。
   thisArg 一旦是真实对象（`z.call(o)`）就退回通用转发。
2. **`has_native_caller` 是活机制且触发面很宽**：任何 `f.call(...)` 转发到 bytecode
   目标都会置位并在返回时释放。它在 P3-11 的 `native` 探针中一直是命中的。
3. **`apply` 完全不走转发路径**（`pushForwardedCall` = 0，`generic` = 1）——
   `Function.prototype.apply` 与 `call` 在 zjs 中是两条不同的路由。
   本轮不展开，记录为已知差异。

## 4. `has_native_caller` 的可观察语义（决定性）

它不只是所有权标记，还决定 `Error().stack` 的帧序：

```text
zjs                                  qjs
--- forwarded (inner.call) ---       --- forwarded (inner.call) ---
  at inner (…:1:36)                    at inner (…:1:36)
  at call (native)                     at call (native)
  at outer (…:2:20)                    at outer (…:2:20)
  at <eval>                            at <eval>

--- plain (inner()) ---              --- plain (inner()) ---
  at inner (…:1:36)                    at inner (…:1:36)
  at outer2 (…:6:21)                   at outer2 (…:6:21)
  at <eval>                            at <eval>
```

`at call (native)` 只在转发形态出现，**两个引擎逐行一致**。
`resolveMachineBacktrace` 正是用该位在遍历中插入这一合成帧
（qjs 帧序 `target -> call (native) -> caller`）。

**结论：这不是死状态，也不是仅测试可达的内部能力；它是与 pinned qjs 对齐的
可观察行为，冷化时必须完整保留。**

## 5. 裁决与对 P3-12 的约束

按 §「三种裁决」：**情况 1 —— 找到生产消费者**。两者都不进入死机制清理。

因此 P3-12 的 extended mode 必须包含，且 ordinary mode 必须不再逐项测试：

```text
extended return mode 成员：
    forwarded_leaf            （零参 leaf 转发，窄）
    has_native_caller         （任意 f.call 转发，宽；所有权 + backtrace）
    constructor_completion
    tail_chain
    return_action != .next    （proxy_get / for_of_next / constructor）
    非 simple teardown        （cold != null / owned storage / 非 arena stack）
```

ordinary mode 应蕴含以上全部为假，并因此蕴含
`return_action = .next` 与 `continuation_payload = 0`。

### 必须保留的正向门禁（P3-12 语义验收）

| 机制 | 正向 probe | 期望 |
|---|---|---|
| `forwarded_leaf` | `z.call()` / `z.call(undefined)`，`z` 零参 leaf | extended 命中 200，结果一致 |
| `has_native_caller`（所有权） | `g.call(thisArg, …)` 任意形态 | `releaseNativeCaller` 命中数不变 |
| **`has_native_caller`（backtrace）** | `inner.call(undefined)` 内取 `new Error().stack` | **`at call (native)` 帧仍在，帧序与 qjs 一致** |
| `constructor_completion` | 普通 / 返回 primitive / 返回 object / derived | 计数与结果不变 |
| `proxy_get` / `for_of_next` | Proxy JS getter trap + 自定义 `next()` | `op_post_call_continuation` 240 不变 |
| `tail_chain` | 合成 bytecode 测试 | `popTailChainFrameMode` 10 不变 |
| unwind | throw + catch + 恢复后继续调用 | `deinitGeneralResources` 200 不变 |

`fwd_leaf`、`fwd_leaf_this`、`fwd_generic`、`fwd_apply` 与 backtrace probe
为本轮新增，应纳入 P3-12 的语义门禁。

## 6. 对 P3-12 归因的影响

**没有死分支可删**，因此 P3-12 的收益全部来自「多种真实特殊 completion
收敛为一次 mode test」，不会混入死字段清理的收益。这正是本次前置审计的目的。

P3-11 给出的天花板不变：判别税 2.39% + continuation 解码 0.29% ≈ **2.68% of `fib_rec`**，
乐观预期 `1.3157x → 约 1.281x`，退出线 `1.20x` 仍需结构级改动。

## 7. 限制

- 只查 `forwarded_leaf` / `has_native_caller` / `native_caller` 三条数据流，
  未扩大到其他 teardown 位；
- `inline_calls.zig:624` 单行占 `op_return` 6.22% 的成因仍未做微架构确认
  （P3-11 已标注），本轮不涉及；
- `Function.prototype.apply` 不走转发路径这一差异只记录，未做归因；
- 未检查宿主 C API 直接进入 JS 再返回的路径是否另有 `has_native_caller` 生产者
  （已知的两个 producer 均在 `Function.prototype.call` 路由上）。
