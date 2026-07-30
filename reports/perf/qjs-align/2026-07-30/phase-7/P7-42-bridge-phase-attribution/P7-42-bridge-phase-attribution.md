# P7-42：builtin→bytecode 回调桥的逐阶段归因

- 日期：2026-07-30
- 性质：仅剖析（profiling-only），不改生产代码，止于裁决
- 基线：`0e4ee496`，分支 `perf/qjs-align-p7-builtin-bridge-phase`
- 依据：`P7-41-builtin-bridge/`（本条线只拆它那约 27 cycles，不重证桥的存在）
- 对照引擎：pinned Bellard QuickJS `04be2460`，二进制 sha256 `b76d1542…`（与 P7-20 / P7-40 / P7-41 同一文件）
- 数据产物：`P7-42-results.json`，原始采集件在 `raw/`
- 工具：`tools/perf/builtin_bridge/`（`run_phase_stat.py` 扩展事件采集、`run_phase_record.py` 定周期采样、
  `stage_map.py` 地址→行→阶段归属、`count_stages.py` gdb 精确命中、`analyze_phase.py`、
  `gen_phase_cases.py`、`stages_bridge.json` 阶段表、`build_results.py`）

## 0. 计量身份（每个报数都出自这一套）

| 项 | 值 |
|---|---|
| 基线 commit | `0e4ee496`（唯一基线；P7-41 的绝对值不作本线 P0） |
| zjs 冷缓存构建 A1 sha256 | `6cfceba7c10bc98405ce68e9b39160f6740e72981bcf154ea4cc0d785d7e8832` |
| zjs 冷缓存构建 A2 sha256 | `6cfceba7c10bc98405ce68e9b39160f6740e72981bcf154ea4cc0d785d7e8832` |
| 两次冷构建是否逐字节相同 | **是** |
| qjs sha256 | `b76d1542…`（`04be2460`） |
| 核 / PMU | CPU 19（`Cortex-X925`，`armv8_pmuv3_1`），20 核 big.LITTLE，事件一律带 PMU 前缀 |
| 计时与 `perf record` | `flock -x` + `taskset -c 19`；构建取 `flock -s`；objdump / gdb / `perf script` 不计时不取锁 |
| ABBA | 每 case 每引擎偶数样本（6 或 4），`first_position_balanced: true`（四份采集件全为真） |
| `git diff 0e4ee496 -- src/` | **空**（0 行）。全程未加诊断计数器，未强制 `noinline`，未用 `git stash` |

**A1 与 A2 逐字节相同**，所以本树没有构建 bistability 可报（与 P7-41 同一情形，那次是
`77178af4…`；本线二进制不同是因为树不同）。噪声尺改用**同一二进制上两次独立的完整计时扫描**
（T1 / T2）：四个 rung 的 canonical 口径两次复现极差 **0.07 … 0.76 cyc/回调**。

## 1. 裁决

```text
Decision:
    shared bridge tax confirmed,
    but distributed across required control state;
    no one-cut.
```

**先在本树重测被分解的量。** canonical（scaffold-corrected）口径，四个无结果写 rung × 两次
复现的中位：

| 口径 | 本树 `0e4ee496` / `6cfceba7…` | P7-41 |
|---|---:|---:|
| `spec` | 30.37 | ~30.5 |
| `slope` | 29.34 | — |
| **`scaffold_corrected`（canonical）** | **27.26** | **27.43** |

差 0.17 cyc/回调。**下文所有 per-stage 份额都按本树的 27.26 归一**，40% 门槛因此是
**10.91 cyc/回调**。

**逐阶段表（zjs builtin 侧，四族中位；`ctl` 是同一阶段在镜像直接循环对照里的读数）：**

| 阶段 | hits/回调 | insn/回调 | **cyc/回调** | IPC | stall/回调 | %tax | ctl cyc |
|---|---:|---:|---:|---:|---:|---:|---:|
| `S7c_vm_cache_rebuild` | 1.0000 | 31.1 | **6.98** | 4.46 | 2.22 | **25.6%** | 0.00 |
| `S10_return_to_builtin` | 1.0000 | 41.1 | **6.39** | 6.44 | 3.36 | 23.4% | 0.00 |
| `S9_fence_restore` | 1.0000 | 29.1 | **6.00** | 4.85 | 3.38 | 22.0% | 0.00 |
| `S4_frame_admission` | 1.0000 | 32.3 | **5.25** | 6.15 | 2.35 | 19.2% | 0.00 |
| `S7e_dispatch_entry_and_outcome` | 1.0000 | 19.5 | **5.01** | 3.88 | 1.89 | 18.4% | 0.00 |
| `S6_entry_publication` | 1.0000 | 24.2 | **4.82** | 5.02 | 1.83 | 17.7% | 0.00 |
| `S5_argument_staging` | 4.0000 ¹ | 20.7 | **3.87** | 5.36 | 1.61 | 14.2% | 0.00 |
| `S8_special_return` | 1.0000 | 14.2 | **3.68** | 3.86 | 1.69 | 13.5% | 0.00 |
| `S7b_driver_frame_save_restore` | 1.0000 | 15.4 | **3.46** | 4.44 | 1.54 | 12.7% | 0.00 |
| `S7a_fence_depth_check_and_driver_call` | 1.0000 | 14.7 | **3.30** | 4.44 | 1.71 | 12.1% | 0.00 |
| `S7d_run_prologue` | 1.0001 ² | 14.0 | **3.28** | 4.27 | 0.95 | 12.0% | 0.00 |
| `S1_callsite_entry_and_poll` | 1.0000 | 18.4 | **2.75** | 6.69 | 1.21 | 10.1% | 0.00 ³ |
| `S2_fence_scope_construct` | 1.0000 | 11.2 | **1.67** | 6.74 | 0.73 | 6.1% | 0.00 |
| `S3_fence_publish` | 1.0000 | 9.3 | **1.38** | 6.73 | 0.61 | 5.1% | 0.00 |
| `X11b_fallback_call_cold` | **0.0000** | 6.6 | 0.86 | 7.66 | 0.46 | — | 0.00 |
| `X11a_fallback_args_hoisted` | 1.0000 | 0.8 | 0.12 | 7.07 | 0.06 | — | 0.00 |
| `X11c_owned_copy_leg` | 0.0000 | 0.0 | 0.00 | — | 0.00 | — | 0.00 |
| （非桥）`C9_callback_return_handler` | — | 89.3 | 25.21 | 3.54 | 11.01 | — | **21.05** |
| （非桥）`C0_builtin_loop_and_element_read` | — | 122.6 | 15.08 | 8.13 | 7.13 | — | 0.00 |
| （非桥）`C90_leaf_return_arms` | 0.0000 | 1.8 | 0.43 | 4.20 | 0.16 | — | **3.94** |

¹ `S5` 是唯一命中数不是 1 的阶段：`inline_calls.zig:3456` 的 dup 循环每回调 4.0000 次
（循环头 + 三个实参）。
² `S7d` 的 1.0001 是每进程一次的 driver 入口（对照里同一探针读 0.0001/回调）。
³ `S1` 在对照的被映射符号里是 0，但**直接 bytecode 调用在它自己的 `op_call` 里也 poll 一次
中断**，所以 `S1` 的 2.75 高估了它的桥专属部分（§7）。

**最大单一阶段是 `S7c_vm_cache_rebuild`，6.98 cyc/回调 = 税的 25.6%，低于 10.91 的门槛；
其余十个桥阶段落在 3.3 … 6.4 的带里。** 这正是任务给定的关闭条件（「若最大阶段低于约
11 cycles，或若干阶段各承担 3–7 cycles，则关闭生产路线」）。

### 1.1 把 S7 五个子阶段并起来算 80.8%，为什么仍然不能立项

按任务给出的八阶段粒度，第 6 阶段（bytecode frame admission/setup … callee dispatch）里
的 driver 重入是最大的一块：`S7a`+`S7b`+`S7c`+`S7d`+`S7e` = **22.04 cyc/回调 = 税的 80.8%**，
94.6 insn/回调，四族一致（forEach 22.42 / some 22.10 / every 21.88 / filter(false) 21.39，
族间极差 4.7%），对照里逐项为 0。
它满足份额与通用性，但**不满足单机制**，逐条说明：

- `S7b`（3.46）是**一次独立 driver activation 的 ABI 代价**：`runTC` 内联了整个 `run()`，
  其活跃区间使这一帧要保存/恢复大量 callee-saved 寄存器。删它意味着把解释器循环相对
  native 边界搬家（把 builtin 调用改成 driver continuation），不是删工作。
- `S7c`（6.98，31 insn）里**大约三分之二是十个 `Vm` 字段的 store**，任何 driver 入口都必须写；
  只有重派生的那些 load 是冗余的。
- `S7d`（3.28）是 `run()` 的 prologue，与引擎里**每一个** driver 入口逐字共用（脚本入口、
  generator 恢复、构造器完成）。改它就改到了非桥路径。
- `S7a`（3.30）承载 fence-depth 有界错误合同（`runActiveInvocationAfterNativeBoundaryError`），
  不是派生态。
- `S7e`（5.01）是 `next()` 调用加 outcome switch；直接 bytecode 调用付等价的 dispatch，
  所以这是桥专属的**位置**而非桥专属的**工作**。

把这五块打成一刀 = 同时改动 driver activation、Machine level 派生、以及返回 outcome 路径 ——
正是本战役反复被叮的「热点符号已定，但符号内可消除的机制未定就下刀」。

### 1.2 S7c 里到底哪一部分是冗余的（能点名的那一段，以及它的上限）

`SyncInternalCallSite.call` 走到 `runActiveInvocationUntilNativeBoundary` 时，
`tryPushNativeBoundaryLeafArgsFast` **刚刚把 Entry 写完并把 `*Entry` 返回给调用方，
而调用方把它丢掉**（`if (machine.tryPushNativeBoundary…(…) == null)`）。紧接着
`runTC` 又从内存把同一组值全部重派生一遍：

| `runTC` / `run` 重派生的东西 | 上一步刚写过它的地方 |
|---|---|
| `machine.depth` → 分支 → `machine.top` → `&entry.frame` / `&entry.stack` / `&entry.catch_target`（`Machine.loadCurrentLevel`） | `entry.prev = self.top; self.top = entry; self.depth += 1`（`inline_calls.zig:3492-3494`） |
| `level.frame.function` | `entry.frame.function = function`，且 `function` = `route.target.fb`，**在 100 次回调间是循环不变量** |
| `func.byteCode().ptr`（两次 load + 一次 null 分支，`bytecode.zig:1952`） | 同上，由 per-builtin-call 缓存的 `InlineTarget` 决定，同样循环不变 |
| `pc = code_base + vm.frame.pc` | 新帧的 `pc` 是常量 0 |
| `sp = vm.reloadSp()` → `stack.topPtr()` | `Stack.initArenaWindow(…, stack_window)` 刚设的空窗口 |
| `var_buf = vm.frame.locals.ptr` | `entry.frame.locals = stack_window[0..0]` |
| `local_fast_blocked = machine.depth == 0 and l0.stop_before_pc != null` | 回调处 `depth = fence_depth + 1 ≥ 1`，**可证恒为 false** |

这些值在 push 结束时全部在寄存器里，随后被写进内存又立刻读回 —— 与 §2 的事件画像
完全吻合：税是**非内存**的后端阻塞（store-to-load forwarding 链），不是 cache miss。

但可消除的上限就到这里：`S7c`（6.98）里必须保留的十个 store，加上 `S7d`（3.28）里
`pc/sp/var_buf` 三个局部变量本身。**乐观估计可回收 5–8 cyc/回调 = 税的 18–29%**，
仍在 40% 门槛之下。所以本线不把它记成候选一刀，只把这段冗余写进
`candidate-register.md` 作为将来若门槛下调时的第一顺位素材。

### 1.3 本线明确不主张的事

不主张 native fence 对同步回调是冗余的（`S2`+`S3`+`S9` 合计 9.05 cyc，逐项 1/回调，
其中最大的一项 `S9` 占 22.0%，仍在门槛下）；不主张 Machine 状态不必保存；不主张 `special_return` 可绕过
（`S8` 3.68）；不主张回调实参可以借用（`S5` 3.87，且下面 §5 用真实计时独立量到整套
实参窗口机制是 5.4 cyc）；不主张 native caller / backtrace 状态不必要。这五件事都被量了，
**没有一件被证明可删**。

## 2. 税的事件类别：全部是非内存后端阻塞

P7-41 §7.2 留下的账：那是 IPC 差还是指令差，没有采 stall / miss 事件。本线补上。
下表是 `builtin − mirrored control` 每回调差值再作 `zjs − qjs`（即 `zjs_specific`，
与 §1 的 `spec` 口径同定义），四个 rung 各一列：

| 事件 | forEach | some | every | filter(false) | 中位 |
|---|---:|---:|---:|---:|---:|
| `cpu_cycles` | +27.70 | +33.76 | +28.66 | +33.05 | **+30.85** |
| **`stall_backend`** | +27.28 | +34.13 | +28.25 | +34.41 | **+31.19** |
| `stall_backend_mem` | +0.04 | +0.09 | +0.05 | +0.03 | +0.04 |
| `stall_frontend` | −0.42 | −0.82 | −0.91 | −0.05 | −0.62 |
| `inst_retired` | +45.94 | +51.75 | +51.94 | +58.80 | +51.85 |
| `l1d_cache`（= `mem_access`） | +21.75 | +25.79 | +22.90 | +25.06 | +23.98 |
| `l1d_cache_refill` | 0.00 | 0.00 | 0.00 | 0.00 | **0.00** |
| `ll_cache_miss_rd` | 0.00 | −0.00 | 0.00 | −0.00 | **0.00** |
| `br_retired` | −23.52 | −22.60 | −21.55 | −22.77 | −22.69 |
| `br_mis_pred_retired` | 0.00 | 0.00 | 0.00 | 0.00 | **0.00** |

三条要读出来的：

1. **`stall_backend` 与 `cpu_cycles` 几乎逐格相等**（+31.19 对 +30.85）。这笔税就是后端阻塞周期。
2. **`stall_backend_mem` 是 +0.04，`l1d_cache_refill` 与 `ll_cache_miss_rd` 是 0，
   `br_mis_pred_retired` 是 0。** 所以既不是 cache miss，也不是分支误预测 —— 是非内存的
   后端资源/依赖阻塞。桥每回调多做 +24 次 L1D 访问（全部命中），少 22.7 次 retired branch。
3. 指令确实多 +51.85/回调，但按对照的 IPC（约 6）折算只值 8.6 cyc；剩下约 22 cyc 是纯 IPC 损失。
   **所以「不是指令数差」和「指令也多了」两句话都对**：多的指令外加更差的 IPC。

这条结论直接决定了归因的读法：阻塞可以记在依赖链末端的消费者、记在一次 load 的使用者、
或者记在一条分支上，**不一定记在造成它的那条指令上**。所以 §1 的 cyc 列是归因不是账本。

## 3. 阶段是从二进制里读出来的，不是预设的

桥几乎全是 `inline fn`，阶段边界**没有符号**。留下来的是 DWARF 行表：每份内联副本都还带行记录。
`stage_map.py` 因此走三步：`objdump -d -l` 得到「每条指令 → file:line」的精确映射；
把地址装进一张显式的 file:line 区间表（`stages_bridge.json`，随本报告入库）；
再把 `perf script` 的 IP 直方图装进同一批桶。

真实链条（`forEach(cb_noop)`，dense、无洞、无结果写）：

```
qjsArrayIterationModeCall__anon_85061        (C0：C 循环 + dense 取元素 + 三值实参元组)
└─ SyncInternalCallSite.call                 [noinline, 367 静态指令]
   ├─ pollInterrupt                                              → S1
   ├─ activeInvocation(rt) == route.invocation                   → S1
   ├─ Machine.nativeBoundarySimpleEligible(&route.target)        → S1
   ├─ NativeBoundaryScope.init  + MachineBacktraceView.segment   → S2
   ├─ NativeBoundaryScope.push                                   → S3
   ├─ Machine.tryPushNativeBoundaryCopiedArgsFast
   │  └─ tryPushNativeBoundaryLeafArgsFast
   │     ├─ qjsBytecodeFrameAllocaSize / tryCommitInlineCallDepthBytesRt
   │     │  / entryAt / vm_stack.carveActiveMarked                → S4
   │     ├─ 三个实参 dup 进参数窗口 + 尾部清零                    → S5
   │     └─ Entry 发布（frame / stack 窗口 / teardown / 链接）     → S6
   ├─ runActiveInvocationUntilNativeBoundary                     → S7a
   │  └─ runTC                                                   → S7b（activation）
   │     ├─ currentLevel / frame.function / byteCode / 十个 Vm store → S7c
   │     ├─ run() prologue（tbl / local_fast_blocked / pc / sp / var_buf） → S7d
   │     └─ next(...) + outcome switch                           → S7e
   │        └─ op_return_undef | op_return  ← 回调体本体（C9，对照也有）
   │           └─ popAndResume：hasSpecialReturn → isNativeBoundaryReturn
   │              → popReturnedNativeBoundary → .native_returned  → S8
   ├─ NativeBoundaryScope.finish → popBacktrace                  → S9
   └─ 结果交还 + 调用点寄存器恢复                                 → S10
```

**符号作用域是必需的，不是洁癖。** 共用内联辅助（`Vm.next`、`FunctionBytecode.byteCode`、
`Machine.loadCurrentLevel`、`Stack.topPtr`、`JSValue.dup`）在被映射的多个符号里都出现；
第一版无作用域的表把 `op_return_undef` 里的 `next`/`byteCode` 样本算给了 driver 重入，
`bytecode.zig:1952` 一行就吃到 4.11% 的指令。表改成 per-symbol 作用域后消失。
同理，**`op_return` 必须与 `op_return_undef` 一起映射**：`forEach` 的 noop 回调走
`op_return_undef`，而 `some`/`every`/`filter` 的谓词回调走 `op_return`，只映射前者会让
三族的整列返回成本变成 0。

## 4. 动态命中：gdb 精确计数，四族逐项 1/回调，对照逐项 0

gdb 行断点配不可达 ignore 计数（`ignore N 2e9`），跑到底后 `info breakpoints` 给精确命中数。
用行断点而不是符号断点，因为桥几乎全被内联：没有符号，但每份内联副本都还有行记录，
gdb 报一个 `<MULTIPLE>` 位置集并给跨副本合计。每格 = 命中数 / 10 000 次回调：

| 探针（file:line） | forEach | some | every | filter(f) | 四个对照 | `forEach(cb_a0)` |
|---|---:|---:|---:|---:|---:|---:|
| `call_runtime.zig:753`（poll） | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 0.0000 | 1.0000 |
| `call_runtime.zig:756`（active-invocation 校验） | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 0.0000 | 1.0000 |
| `inline_calls.zig:1019`（fence scope init） | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 0.0000 | 1.0000 |
| `inline_calls.zig:1024`（backtrace view segment） | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 0.0000 | 1.0000 |
| `inline_calls.zig:1041`（fence publish） | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 0.0000 | 1.0000 |
| `inline_calls.zig:3325`（fast-push 分派） | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 0.0000 | 1.0000 |
| `inline_calls.zig:3361`（**empty-leaf** 腿） | **0** | **0** | **0** | **0** | 0.0000 | **1.0000** |
| `inline_calls.zig:3434`（**exact-args-leaf** 腿） | **1.0000** | **1.0000** | **1.0000** | **1.0000** | 0.0000 | **0** |
| `inline_calls.zig:3456`（实参 dup 循环） | 4.0000 | 4.0000 | 4.0000 | 4.0000 | 0.0000 | **0** |
| `inline_calls.zig:3465` / `:3492`（Entry 发布 / 链接） | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 0.0000 | 0 |
| `zjs_vm.zig:813`（driver 调用） | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 0.0000 | 1.0000 |
| `zjs_vm.zig:776`（Vm 缓存重建） | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 0.0000 | 1.0000 |
| `tailcall_dispatch.zig:4302`（run prologue） | 1.0001 | 1.0001 | 1.0001 | 1.0001 | 0.0001 | 1.0001 |
| `tailcall_dispatch.zig:1198`（`popReturnedNativeBoundary`） | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 0.0000 | 1.0000 |
| `inline_calls.zig:1100`（fence restore） | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 0.0000 | 1.0000 |
| `call_runtime.zig:758`（交还 builtin） | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 0.0000 | 1.0000 |
| `call_runtime.zig:770`（**authoritative fallback**） | **0** | **0** | **0** | **0** | 0.0000 | **0** |
| `call_runtime.zig:760` / `:555`（owned-copy / cold push） | 0 | 0 | 0 | 0 | 0.0000 | 0 |
| `inline_calls.zig:1053`（fence 错误路径） | 0 | 0 | 0 | 0 | 0.0000 | 0 |
| `inline_calls.zig:4488`（对照的 exact-args-leaf **返回**） | **0** | **0** | **0** | **0** | **1.0000** | 0 |

即：**桥的每个阶段在四族上恰好 1.0000/回调、在四个对照上恰好 0.0000**（`run` prologue
的 0.0001 是每进程一次的 driver 入口），而对照的 leaf 返回臂反过来 —— 对照 1.0000、
builtin 0。冷腿与错误腿全 0。`cb_a0`（声明零形参）把 push 腿从 exact-args 翻到 empty-leaf、
把 dup 循环归零，与 `bytecode.zig:12645-12671` 的 `empty_leaf_geometry`（要求 `arg_count == 0`）
逐字一致。

**仪器自检（任务要求：先在「被计的东西确定存在」的 case 上验证再相信零）。** 双向都验了：

- `call_runtime.zig:770` 这条 19 指令的 fallback 块 gdb 读 **0 命中**，但采样仍把
  **0.86 cyc / 6.6 insn 每回调**记到它头上 → 这就是**归因泄漏地板，约 ±1 cyc/阶段**。
  §1 表里除 `S3`（1.38）以外每个阶段都远在地板之上，且**没有任何阶段接近 11 cyc**。
- 反方向：`C90_leaf_return_arms` 在对照里 gdb 1.0000/回调、在 builtin 里 0，采样读
  对照 3.94 cyc、builtin 0.43 cyc。仪器两个方向都跟得上。

## 5. 一次真实计时的单机制差分：实参窗口

采样归因需要一把独立的尺。回调**声明**的形参个数会切换 push 腿（0 → `EmptyFast`，
不 carve 参数窗口、不 dup 任何实参；>0 → `LeafArgsFast`，carve `arg_count` 宽的窗口并
dup `min(3, arity)` 个值），而 builtin **始终**递三个实参，所以 ABI 逐字不变。
只看 builtin 侧（对照侧在 arity 0/1/2 会走 bytecode 的 padded-argc 腿，不干净，见 §7）：

| callback arity | zjs builtin cyc/回调（T1 / T2） | zjs builtin insn/回调 |
|---|---:|---:|
| 0（`function cb_a0() {}`） | 95.98 / 96.05 | 454.6 |
| 1 | 99.42 / 99.08 | 490.7 |
| 2 | 99.26 / 99.60 | 504.6 |
| 3（= canonical `cb_noop`） | 101.29 / 101.48 | 532.7 |

`a3 − a0` = **+5.4 cyc / +78 insn**：这是「参数窗口 carve + 三次 dup + 尾清零 + 更宽帧」
整套机制的真实计时代价。`some` 上同一对是 `104.8 → 111.1` = **+6.3 cyc / +78 insn**。
采样给 `S5_argument_staging` 3.87 cyc（其余落在 `S4`/`S6` 因帧变宽的增量里），
**两把独立的尺一致**。这既校准了采样，也把「回调实参可以借用」这条从假设变成一个
上限已知的量：整套实参机制只值 5.4–6.3 cyc/回调，即税的 20–23%。

## 6. 为什么桥阶段合计 58.5 cyc 而税只有 27.3

不能把 §1 的 cyc 列加起来当账本，两个原因，第二个是数量级的：

1. 采样归因的地板是 ±1 cyc/阶段（§4）。
2. **builtin 路径同时也不付 bytecode 循环脚手架。** 本树实测（`s_loop` 减 `s0_loop`）：
   qjs **31.11**、zjs **28.79** cyc/元素。

对上账（`forEach`，每回调）：

| | zjs builtin | zjs 对照 |
|---|---:|---:|
| 回调体返回 handler（`C9` + `C90`） | 25.35 | 25.26 |
| builtin C 循环 + dense 取元素（`C0`） | 12.66 | 0 |
| **桥（`S1`…`S10` + `X11`）** | **58.78** | 0 |
| 对照的循环脚手架 + `op_call` + `op_get_array_el` | 0 | 72.06 |
| 其余（`C8` / 未映射） | 3.74 | 0 |
| **进程合计** | **100.53** | **97.32** |

也就是说：**zjs 的桥（58.78）加它的 C 循环（12.66）= 71.44，与对照里「含 28.79 cyc/元素
脚手架的整套 bytecode 调用 + 取元素」的 72.06 只差 0.62 cyc** —— 桥连本带利地把脚手架红利
吃光了。进程层面 zjs builtin 只比自己的 JS 循环贵 3.21 cyc，其中 −0.62 来自上面这一对，
余下约 +3.7 落在 `C8` 与未映射余项里。而 qjs 的 builtin 比它自己的 JS 循环**便宜
24.56 cyc**（它把 31.11 的脚手架存进了口袋）。

`27.77 = 3.21 − (−24.56)`。**这笔税的真正含义不是「zjs 多做了 27 cycles 的某件事」，
而是「zjs 的桥机制吃掉了走 C 循环本该拿到的那份脚手架红利」。** 这也是为什么按绝对
阶段成本除以差分税会得到 80%+ 这种数字：那个除法混了两个不同的量。§1 的 `%tax` 列
按任务口径给出，但结论**同时**用四族一致性与 `builtin − 对照` 差分列作支撑，不靠份额相加。

## 7. 采样周期与工作负载周期的混叠（一个必须记下来的坑）

第一轮 record 用了 `perf -F 49999`（自适应周期）。这个工作负载的内层周期约 100 cycles，
自适应后的周期锁到了它的近似倍数上，样本堆到单条指令：

| | `q_every`（-F） | `q_foreach`（-F） | 定周期后 |
|---|---:|---:|---:|
| `tailcall_dispatch.zig:4309`（`bl next` 返回点）占进程 cycles | **20.09%** | 0.74% | — |
| `S7` 桶读数（cyc/回调） | **43.99** | 22.29 | 21.78 / 22.29 |
| cycles 样本总数 | 98 767 | 66 286 | — |

同一条指令在两族之间差 27 倍，不可能是物理现象。改用**固定且互质的周期**
（cycles 50021 / 65599 / 82657，instructions 249989 / 300007 / 350003，
stalls 24011 / 30011 / 36011）后，同一阶段跨三个周期的读数极差 **≤3%**，四族之间
`S7` 落在 21.55 … 22.04。**`-F` 在周期性极强的微观工作负载上不可用**；本报告所有采样
数字都出自定周期，且每族每事件的 min/max 都在 `P7-42-results.json` 里。

## 8. 本条线没有建立的东西

1. **没有 per-stage 账本。** cyc 列是采样归因；乱序核把后端阻塞记在依赖链末端的消费者
   而不是制造者身上。桥阶段合计 58.62（四族中位）而净税 27.26，两者的差已由 §6 定量解释，但
   **不得把 cyc 列相加当作 27 cycles 的分解**。
2. **没有测任何候选改动能真正回收多少。** 本线未改 `src/`、未建任何变体、未计时任何变体。
3. **`S7c` 里「必须保留的十个 store」与「可删的重派生 load」的比例是静态读反汇编得到的，
   不是实测拆分。**
4. **`S1` 的桥专属部分被高估。** 它在对照的被映射符号里是 0，但直接 bytecode 调用在
   `op_call` 里也 poll 一次中断；那次 poll 不是桥专属的。本线没有单独量 `op_call` 侧的 poll。
5. **只覆盖四个无结果写的 dense Array builtin。** `map`、`filter(true)`、`reduce`、
   `find*`、TypedArray 回调、sparse / holey receiver、跨 realm 回调都没测。
6. **arity sweep 的对照侧不干净。** arity 0/1/2 的对照把三个实参递给更窄的被调用方，
   走 bytecode 的 padded-argc 腿（对照读数 114.8–116.0 对 arity 3 的 99.0）。该 sweep
   只作 builtin 侧的单机制差分，其对照列已入库但不作 rung。
7. **`S5` 是唯一命中数不为 1 的桥阶段**（4.0000/回调 = 循环头 + 三次迭代）；其余全为 1.0000。
8. **ARM SPE 在本机可用（`arm_spe_0`，cpumask 0-19）但未使用。** 全部归因基于非精确
   PMU 采样，泄漏地板已在 §4 量出（0.86 cyc / 6.6 insn 记到一个可证不执行的块上）。
9. **没有主张 fence、Machine 保存、`special_return`、实参所有权、native-caller / backtrace
   状态中的任何一项是冗余的。** 五者都被量了，没有一项被证明可删。
10. **没有做任何一刀。** 按任务边界停在裁决。

## 9. 交给其他线的东西

- **给 call 线**：`S7c` + `S7d` 那段重派生（§1.2）是本线唯一点得出名字的冗余工作，
  上限 5–8 cyc/回调（税的 18–29%），机制是「把 push 刚返回的 `*Entry` 与缓存
  `InlineTarget` 里循环不变的 `fb` / `code_base` 递给 driver 入口，而不是经
  `machine.depth → machine.top → entry.frame → function → byteCode()` 重新走一遍」。
  低于本线门槛，已登记为 deferred，不立项。
- **给测量方法线**：`-F` 自适应周期在周期性微观负载上会与内层周期混叠（§7）；
  file:line 归因表必须按符号作用域（§3）；`perf` 的 per-stage 归因地板要用一个
  「gdb 证明为 0 命中」的块现场量出来（§4）。三条都已固化在
  `tools/perf/builtin_bridge/` 的工具里。
- **下一条线**：P7-60 `logicalNot`（已在 `candidate-register.md` 登记；P7-41 §6 量到
  一个作用在可变局部上的 `!` 在 zjs 是 91.13 insn / 18.66 cyc 每元素，qjs 是 17.96 / 3.07）。

## 附：`raw/` 里文件名的含义

| 文件 | 用途 |
|---|---|
| `P7-42-stat-A1.json` | 扩展事件（stall / miss / branch）差分，`b_*` 对 `c_*`，§2 的来源 |
| `P7-42-stat-q-A1.json` | 长 `q_*` case 的绝对每回调总量，把采样份额换成 cyc/insn/stall 的基准 |
| `P7-42-timing-T1/T2.json` | 两次独立完整计时扫描：canonical 税重测（§1）+ arity sweep（§5） |
| `P7-42-counts-A1.json` | gdb 精确命中（§4） |
| `P7-42-stagemap3-*-A1.json`、`P7-42-phase3-A1.json` | **权威**逐阶段归因（定周期 ×3，S7 已拆五份） |
| `P7-42-stagemap-SUPERSEDED-singleS7-*` / `P7-42-phase-SUPERSEDED-singleS7-A1.json` | 同样的定周期数据，但 S7 还是单桶；被 `*3*` 取代，保留以便核对拆分前后合计相等 |
| `P7-42-stagemap-DISCARDED-Ffreq-aliased-*` / `P7-42-phase-DISCARDED-Ffreq-aliased-A1.json` | **被判废**的 `-F 49999` 自适应周期采集，§7 混叠证据，不得用于任何结论 |
