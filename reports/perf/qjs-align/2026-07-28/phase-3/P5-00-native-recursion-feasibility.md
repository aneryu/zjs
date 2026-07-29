# P5-00 — Native-recursive prototype 的可行性与设计修正

- **日期**：2026-07-29
- **HEAD**：`fb3cd09f`
- **性质**：架构确认与设计修正，未改代码
- **结论**：**可行，但形态与原设想不同**。不需要第二个解释器；
  代价是 `op_return` 热路径要多一个每帧测试，且 `Frame` 不会消失

---

## 1. 关键架构事实：嵌套调用不长原生栈

```zig
// tailcall_dispatch.zig:4095
pub fn run(vm: *Vm) HostError!JSValue {
    while (true) {
        switch (next(pc, sp, var_buf, vm)) {
            .returned => { … },
            .threw    => return vm.pending_error,
            .tail     => { … },
        }
    }
}
```

`next` 尾调用 handler，handler 之间**全部 musttail**。
一次 `OP_call` 通过 `enterEntry` **尾调用**进被调者，`op_return` 再**尾调用**回调用者 ——
整棵 JS 调用树在**一次** `next(...)` 调用内跑完，原生栈不增长。

`run` 的循环只在**离开尾链**时才转一圈（`.returned` / `.threw` / `.tail`）。

**这就是 zjs 与 qjs 在 continuation 上的真正分歧点**：
qjs 每次 JS 调用递归进 `JS_CallInternal`，恢复靠 C return address；
zjs 每次 JS 调用留在同一条尾链上，恢复靠显式 Entry 状态。

## 2. 原设想需要修正的三处

### 2.1 不需要写第二个解释器

因为链上全是 musttail，**最终产生非尾 Outcome 的那个 handler 会把返回值
直接送回 `next` 的调用者**（中间帧都已被尾调用消掉）。

所以原生递归的形态是：

```zig
// OP_call 的 prototype 臂
fn runPlainBytecodeCall(vm: *Vm, …) HostError!JSValue {
    // 保存 caller 的 vm 字段到原生栈
    // 在原生栈上建 PlainStackFrame，slots 仍从 VmStackArena carve
    // 发布 callee 状态
    while (true) switch (next(callee_pc, callee_sp, callee_vb, vm)) {
        .returned => break,      // <- 被调者的 op_return 产生
        .threw    => …,
        .tail     => …,
    }
    // 从原生栈恢复 caller 的 vm 字段
    return value;
}
```

**复用现有 handler 表，无需第二套解释器。**

### 2.2 `op_return` 必须多一个每帧测试

`op_return` 目前只在 `machine.depth == 0` 时产生 `.returned`，
其余情况**尾调用回调用者**。prototype 帧需要它产生 `.returned` 而不是尾调用。

因此热路径要多一个「本帧是不是 prototype 帧」的测试。

⚠️ 这与 Phase 3 的方向相反 —— P3-12 刚把普通返回的判别从 12+ 次压到 1 次。
prototype 阶段可接受（用 build flag 隔离），但**若将来要成为默认路径，
这个测试必须被设计掉**，否则 native recursion 的收益会被它侵蚀。

### 2.3 `Frame` 不会消失，消失的是 `Entry`

每个 handler 都解引用 `vm.frame`、`vm.stack`、`vm.catch_target`、
`vm.function`、`vm.code_base`（`tailcall_dispatch.zig:460-464`）。
prototype 仍必须为被调者提供一个 `Frame` 与一个 `Stack`。

真正被消除的是 **`Entry` 的 Machine 层记录**：

```text
消失：prev / arena_mark（改用原生 defer）/ teardown / return_action /
      continuation_payload / native_caller / Machine 链接与 depth 记账
保留：Frame(152) + Stack(40) —— 改放原生栈
```

所以 P5 验证的**不是**「帧变小」，而是
**「continuation 与 caller 恢复交给原生 return address 是否更便宜」** ——
这正是它该验证的东西。

## 3. 每次调用的成本模型（用于预判）

| 项 | 当前（Entry 尾链） | prototype（原生递归） |
|---|---|---|
| caller 状态保存 | 写入 callee Entry，caller Entry 原地不动 | 原生栈保存 6 个 vm 字段 |
| callee 状态发布 | `enterEntry` 5 次写 | 同样 5 次写 |
| 返回 | `op_return` 尾调用回 caller handler + `reloadAfterPop` 重发布 | `next` 返回 `.returned`，原生 return 恢复 |
| Machine 记账 | depth±1、top 链接、arena_mark、teardown 判别 | 无（原生 defer 处理 arena） |
| 新增成本 | — | **每次调用一个原生栈帧** + `op_return` 每帧测试 |

**预期收益点正是 P3-13 量到的那 4.37 ns**（return：zjs 5.91 ns vs qjs 1.54 ns）。

## 4. 必须先解决的三个具体风险

| 风险 | 现状 | prototype 必须做的 |
|---|---|---|
| **原生栈溢出** | 当前 JS 递归深度不消耗原生栈；`fib(40)`、`countdown(100000)` 都安全 | 必须把 JS stack limit 映射到原生栈预算，否则深递归直接段错误 |
| **backtrace** | 走 `machine.top` → `entry.prev` 链 | prototype 帧不在该链上 → `Error().stack` 会丢帧。需要临时注册链（用户已同意「不重构 GC」，同理不重构 backtrace，只加注册） |
| **异常 unwind** | `catch_target` 在 Entry 里，`.threw` 沿尾链返回 | prototype 帧的 catch 目标在原生栈上；`.threw` 需在每层 `runPlainBytecodeCall` 里正确释放 arena 与值 |

`closure` 的 var-ref 生命周期按用户要求纳入第一轮门禁 —— 借用的 capture 数组
由 `frame.current_function` 保活，与是否在原生栈上无关，风险较低但必须实测。

## 5. 工作量与建议

这不是 one-cut。落到可测量的第一片，至少需要：

```text
1. PlainStackFrame 结构 + arena carve/restore（原生 defer）
2. runPlainBytecodeCall：保存/发布/运行/恢复
3. op_return 的 prototype-frame 产出 .returned
4. build flag 隔离 + 只让 normal/sync/same-realm/non-ctor 走
5. 原生栈预算与 JS stack limit 映射
6. backtrace 注册链
7. .threw 路径的每层清理
8. 四个 workload 的门禁（empty/identity/fib/countdown）
```

前 4 项才是最小可测切片，5–7 是**不能省的正确性前置**（深递归与异常在
现有测试套件里必然命中）。

## 6. 需要用户裁决的一点

原设想里「不改 exception model，先只跑 no throw」在这里**不成立**：
`test262-gate` 与 `test-oom` 必然让 prototype 帧上抛异常。
要么

- **(a)** prototype 只在一个独立 build flag 下启用，默认关闭，
  正确性门禁只跑针对性 probe（不跑全量 test262），先拿性能信号；
- **(b)** 一开始就把 `.threw` 路径做对，代价是工作量显著上升。

**建议 (a)**：P5 的问题是「native continuation 值不值」，
拿到 return 阶段的时间信号即可裁决；若信号为正再补 (b)。

## 7. 若 P5 关闭后的去向

用户已定：失败则回到 Frame representation，或转 BigInt。
结合 P4-01c 的结果（布局不敏感）与 P4-02.0（长度不可纯推导），
若 native recursion 也拿不回 return 的 4.37 ns，
则 `fib_rec ≈ 1.30x` 应被记为**当前调用模型的结构常数**，
转 BigInt（`mul-multilimb ≈ 1.77x`）是更高回报的选择。
