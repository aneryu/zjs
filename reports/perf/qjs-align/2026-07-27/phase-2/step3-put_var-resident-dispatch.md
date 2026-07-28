# Phase 2 / 第 3 步 — `put_var` 脱离 `coldStd`，进入主分派

- **日期**：2026-07-28
- **裁决**：**合入**（`P1/P0 = 0.7184`，4/4，远优于 ≤0.98 门槛）
- **实现 commit**：`672ff4ed`
- **分类**：`qjs-mechanism alignment`（移除 zjs-only 的 per-write wrapper，非新增 specialization）

---

## 1. 这一刀切的是什么

第 2 刀把 cell 直写快路放进了 `coldStd` shell 内部。opcode 因此仍然**整条走冷分派**：

```text
P0   dispatch_table[put_var] = coldStd shell
       publish(frame.pc, stack.top_ptr)      两次内存发布
       sub sp, #0x80                          128B 帧
       stp ×3 + str x30                       7 个寄存器保存
       function.byteCode() 空指针检查（含 byteCodeSlow 调用边）
       inline cell 快路：load + 4 guards + stack.pop() + frame.pc += 2 + store
       coldNext: 越界检查 + maybeStop + 重读 frame.pc + 重读 topPtr + 间接跳转

P1   dispatch_table[put_var] = op_put_var（常驻）
       decode（读 pc，不碰 frame.pc）
       4 guards，全寄存器，无栈流量
       hit  → store + 直接 br 到下一 handler
       miss → br 到未改动的 cold shell（状态一字节未动）
```

`coldStd` 本身没有被内联，其他 cold opcode 一个没动，dispatch table 未重排，
opcode 编号与编码未变，ownership / RC / 异常发布顺序未变。

## 2. 动手前的 reachability 证明

gdb 断点计数，无源码插桩。计数器先自证：循环放大 10 倍后计数同步放大。

| | N=500 | N=5000 |
|---|---:|---:|
| `op.put_var` 执行 | 501 | 5001 |
| put_var 走 `coldStd` shell | 501 | 5001 |
| `putVar` 慢路 | 0 | 0 |

`N+1` 中的 `+1` 是顶层 `var g = 0` 的初始化写。**改动前 100% 的全局写都在建 wrapper 帧。**

改动后（同一探针）：

| | N=500 | N=5000 |
|---|---:|---:|
| `op.put_var` 执行 | 501 | 5001 |
| put_var 走 `coldStd` shell | **0** | **0** |
| `putVar` 慢路 | 0 | 0 |
| checksum | 499 | 4999 |

## 3. 慢路仍然是慢路

| 探针 | 常驻 handler | cold shell | `putVar` | 输出 |
|---|---:|---:|---:|---|
| `const c=1; c=2` | 1 | 1 | 1 | `TypeError`，`c===1` |
| 全局 `let` TDZ | 1 | 1 | 1 | `ReferenceError` |
| strict 未声明赋值 | 1 | 1 | 1 | `ReferenceError` |
| global accessor setter | 3 | 1 | 1 | setter 触发，值 42 |
| `eval("var ev=1")` 后写 | 2 | 0 | 0 | `ev===7` |

改动前后逐行相同（前者的 shell 列为 1/1/1/3/2）。差值恰好是：**写通臂离开了 shell，
其余每一条臂仍然落在那里**。`eval_binding` 两侧都走写通臂 —— 它本来就不是慢路探针，
如实记录而不是当作慢路证据。

## 4. 反汇编纯度

不做全局 diff（编译器两态制造上千无关差异）。改为**同态配对下的逐符号体积普查**：
用 `Io.File.Reader.getSize` 把四个二进制划成两个编译器态，
再套用 `state_exclusions.json` 的匿名编号排除。

两个编译器态**各自独立**给出同一结果：

| 符号 | P0 | P1 |
|---|---:|---:|
| `exec.tailcall_dispatch.op_put_var` | 不存在 | **308 字节**（新增） |
| put_var `coldStd` shell | 716 字节 | **424 字节** |
| `exec.vm_property_globals.putVar` | 3400 | 3400 |
| `exec.tailcall_dispatch.op_get_var` | 380 | 380 |
| 其余全部命名符号 | — | **体积全部不变** |
| 643 个编译器编号符号 | — | 多重集仅差 `{−716, +424}` |

⚠️ 排除策略会隐藏 `__struct_N` 名字的符号，而 cold shell 正是这种名字。
因此被排除的那 643 个符号单独按体积多重集核对了一遍，否则过滤器会藏起真实改动。

**主循环体积净增 +16 字节**（+308 常驻，−292 shell）。没有冷代码被带进热路径：
`putVar` 3400 字节原样留在外面，TDZ / const / global-object / eval 各臂都在其中。

### 这条证据链能声称什么、不能声称什么

> Code-size localization and dynamic reachability confirm the intended hot/cold
> movement. Full-body binary equivalence is not claimed because the pinned
> compiler produces two codegen states.

「其余符号体积不变」**不能**证明其正文一定不变。支撑本次性能归因的是组合证据：
源码 one-cut 只移动 `put_var` 分派、两个 compiler state 下观察到相同的体积变化、
匿名符号的多重集补查、动态 reachability 计数、checksum 一致、以及完整语义门禁。

## 5. 结果

两个 codegen 实例/侧，四个跨实例组合，10 轮平衡交错，`--iterations 40 --warmup 5`。

### 目标

| workload | P0 | P1 | 四组合 | geomean | 方向 |
|---|---|---|---|---:|---|
| `global_write_loop` | 1.3225 / 1.2752 ms | **0.9373 / 0.9287 ms** | 0.7087 0.7350 0.7022 0.7283 | **0.7184** | **4/4** |

per-binary IQR 0.20% / 0.40%（P0）、0.36% / 1.86%（P1），`checksums=1`。

### 非目标哨兵

| workload | geomean | 方向 | 判读 |
|---|---:|---|---|
| `prop_read_mono_loop` | 0.9981 | 4/4 | 中性 |
| `local_arith_loop` | 0.9990 | 4/4 | 中性 |
| `fib_rec` | 0.9997 | 2/4 | 中性 |

三者全部落在 ±0.2% 内，无一达到 1% 回退线。`local_arith_loop` 是本轮新增的
attribution sentinel（纯 local 算术 + 循环分派，不入 policy，见 cases/README）：
它专门用来抓「为省一个 wrapper 而扰动整体分派」，结论是没有扰动。

### 事前估计与实测的差距

改动前的估计是 `coldStd 38.34% × (序言 5.2% + 尾声 2.6%) ≈ 3.0%`，实测 28%。

那个数字应当被称作 **wrapper 的局部显式成本估计，而不是边界成本上界**。
`perf annotate` 中序言/尾声的采样占比只覆盖样本**直接归属到这些指令**的成本，
不覆盖跨调用边界的寄存器分配变化、额外 spill/reload、状态发布与重新读取、
调用返回依赖、编译器无法跨边界调度，以及 I-cache / BTB 与代码放置变化。

真正被移除的是整个 cold dispatch 边界造成的
**VM-state publication/reload dependency and loss of register residency**：

```text
主循环中的寄存器态
→ 发布 frame.pc / top_ptr 等状态
→ 调用 coldStd
→ 冷函数重新装载状态
→ 返回后再次恢复主循环
```

`op_add_loc` 的注释记录过同一类效应。⚠️ 本 dossier **不**断言已证明具体的
store-to-load forwarding —— 那需要确认具体 store/load 的地址、宽度与动态依赖，
本轮没有做这项微架构测量。

## 6. 三个数字的证据角色（沿用第 2 刀的口径，不可混用）

```text
Causal within-zjs improvement:   P1/P0 = 0.7184, 4/4
Current absolute zjs/qjs status: 1.0574  (p1-try1 1.0572 / p1-try2 1.0577)
Historical Phase-0 baseline:     1.7150
```

绝对定位单独测得（qjs median 0.8868 ms，8 轮交错）。`global_write_loop`
这一形态**已基本对齐 pinned qjs**：`1.7150 → 1.4319 → 1.0574`。
三个数来自不同轮次，不得相除后把差额全部归给某一刀。

## 7. Profile：改动前后

| | P0 | P1 |
|---|---|---|
| put_var `coldStd` shell | **40.96%**（第一位） | 不在榜 |
| `op_put_var`（常驻） | 不存在 | **29.71%**（第一位） |
| `opLocCheckWithInt32SlotMove` | 9.79% + 7.08% | 13.81% + 5.15% |
| `op_if_false8` | 12.08% | 12.75% |
| `op_dup` | 9.18% | 12.18% |

⚠️ 百分比是相对量。总时间下降 28%，所以 29.71% 折回原始总量约为 21%，
即 put_var 归属时间的绝对降幅约 48%，而非 `40.96 → 29.71` 这一表面差。

## 8. 已测量的残余

常驻 handler 的 hit 臂上仍有 **48 字节帧 + 5 个寄存器保存/恢复**，原因是
drop-to-zero 释放本身是一个调用点。逐指令 annotate：这些帧指令合计占该 handler
样本的 **7.34%**，即总运行时约 **2.2%**。

同源的 `opLoc(.put)` 常驻 handler 从同样的源码形态得到了**完全无帧**的 hit 臂
（帧被 shrink-wrap 进 destroy 尾块），因此这是寄存器分配结果而非结构地板。
本刀按「第一版只做机械迁移」的约束**没有去追**，如实记录为残余。

目标 workload 写的是 int，因此 refcount 递减臂与 destroy 调用采样均为 0 —
上述 2.2% 是纯粹的 wrapper 残留，不是释放逻辑的成本。

⚠️ `op_put_var` 改动后仍占 profile 的 29.71%，**不代表还有接近 30% 的可优化空间**。
这个 workload 几乎专门执行 `put_var`，优化后它仍是第一热点是正常的组成效应。
把 2.2% 全部消除，最多把 `1.0574x` 压到接近 `1.03x`。

```text
Optional: outline drop-to-zero release from op_put_var hit path
Trigger: only revisit if the same frame pattern affects multiple hot opcodes
```

不为一个已经接近 QJS 的 microbench 立即实施 —— 它会牵涉 drop-to-zero 释放路径、
ownership 与 RC、寄存器分配，以及该调用点能否完全冷化，风险高于前两刀。

## 9. 门禁

测量前：`test-exec` / `test-bytecode` / `test-core` / `test262-smoke` / `zig fmt --check`
/ `git diff --check` —— 全绿。

合入前：`test` / `test262-gate` / `test-oom` / `smoke` /
`test -Doptimize=ReleaseSafe`（1986 passed，0 failed）/
`test-core -Dzjs_force_gc=true`（297 passed，0 failed）/
`perf-self-check`（compatible 75/75，validation failures 0，paired geomean 1.00）
—— 全部 RC=0。

## 10. 已知限制

- 只采样 `pad=0`，未做多 pad lineage；
- 未使用外部 PMU 作为裁决门槛，主指标是 same-runtime 内部计时；
- 两个 build instance 不构成配对的 compiler state，比较取四个跨实例组合；
- 逐符号**规范化正文哈希**在本仓库不可用作纯度判据（同一 variant 的两次构建即有
  2194 个符号正文不同），本 dossier 因此改用**体积**作为过滤器，并对被排除的
  编译器编号符号单独做多重集核对；
- 慢路臂的绝对成本未测量：目标 workload 中慢路命中为零；
- 未做微架构层测量（具体 store/load 地址、宽度、动态依赖），因此收益归因到
  VM-state publication/reload 与寄存器驻留丢失这一机制层，不下探到 forwarding 断言。
