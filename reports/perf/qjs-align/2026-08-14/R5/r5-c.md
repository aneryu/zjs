# R5-C BUDGET — call / call_method / return / 帧建拆

lane: R5-C / CPU 5 / 诊断批，src 只读  
日期：2026-08-14  
锚点：deltablue · richards · raytrace。  
特别任务：08-10「vm.* 每调用改写 14 次 vs qjs 调用不变 C 栈槽」指令级对照。

## 结论先行

1. **14 次写已逐字段对上。全部是 musttail 单 `*Vm` 的发布/恢复，qjs 对应物是 `JS_CallInternal` 的 C 局部（quickjs.c:17750–17872）。** 6 个进 callee + 6 个回 caller + `syncPc` + `setTopPtr`。
2. **`syncPc` / `sf->cur_pc` 不是超额：** qjs CASE(OP_call) 同样 `sf->cur_pc = pc`（quickjs.c:18190，反汇编 `str x26,[x0,#48]`）。
3. **真正的结构性差价是「谁付 C 帧」。**  
   - qjs：CASE 本身无帧（~20 insn 到 `bl JS_CallInternal` @ `label_OP_call0` 0x254ec），**嵌套**一次完整 `JS_CallInternal` 前言（alloca、sf、var_buf、pc）。返回是 C `ret`，caller CASE 的 x19/x28 原封不动。  
   - zjs：`op_call*` / `op_call_method` **自己就是**带 96B callee-saved + `sub sp,#0x220/#0x3f0` 的 C 函数，因为同一函数里有 `bl execCall` / `bl callMethod` 冷臂。leaf 成功臂也付了这帧。然后 `enterEntry` 再写 6 个 `vm.*`，return 再写 6 个。
4. **FAITHFUL-FIXABLE：** 给 leaf/exact 再切一个 **frame-zero 克隆**（与 `get_loc0` 同形：无 `stp x29`，只做 resolve + 6 store + `br` 进 callee）。qjs 的 CASE 在 `bl` 之前就是这个形状。冷臂留在现在的有帧 handler。  
   这与 H3/stall 封板不冲突：减的是 **指令和 spill**，不是找无主 stall。
5. return：qjs 是 `ldp` 结果 + 释放 leftover + **落到 `JS_CallInternal` 的 `done`**（不是 dispatch）。zjs 必须 `pop` + 6 store + `br` 回 caller 下一 opcode。恢复那 6 个 store = ARCHITECTURAL。
6. RayTrace 的 apply/arguments/ctor 仍是旧账（`special_object` + `call_constructor`），本批不重开 D11。deltablue `call_method` 8.4% opcode；`tail_call_method` z=0 / q=已知，H3 已 CLOSED。

## 1. 频次

| bench | C 份额 | 头部 C | opcode z/q |
|---|---:|---|---:|
| deltablue | **16.8%** | call_method 8.4 / return 6.6 / return_undef 1.6 | 1.0190（无 tail_call*） |
| raytrace | 8.8% | call_method 3.2 / return_undef 2.7 / return 1.6 | 1.0013；qjs 多 246,738 次 `tail_call_method`，zjs 拆成 call_method+return |
| richards | 8.3% | call_method 4.1 / return 3.6 | 1.0161 |
| typescript | 8.0% | call_method 4.3 / return 2.0 | 1.0069 |
| zlib | **0.0%** | — | 0.9980 |

C 不是 zlib 的事。deltablue/raytrace/richards 的 C 头部覆盖家族 90%。

## 2. 十四次写（call + return）

`Vm` 布局（`tailcall_dispatch.zig:93`）与反汇编 `[x3,#imm]` 一致：

| # | 字段 | 偏移 | 何时 | qjs 对应 | qjs 为什么不写共享槽 | 裁决 |
|---|---|---:|---|---|---|---|
| 1 | `function` | 8 | enterEntry | `JSFunctionBytecode *b` 17753 / 17826 | C 局部，嵌套调用另开一帧 | ARCHITECTURAL |
| 2 | `frame` | 24 | enterEntry | `JSStackFrame sf_s, *sf` 17754 | 同上，sf 在 callee 的 C 栈 | ARCHITECTURAL |
| 3 | `stack` | 32 | enterEntry | `JSValue *sp` 17757 | 寄存器 x19 | ARCHITECTURAL（zjs 还要给 helper 看 `stack.top`） |
| 4 | `code_base` | 56 | enterEntry | `pc = b->byte_code_buf` 17868 | 寄存器 x28 | ARCHITECTURAL |
| 5 | `var_refs_base` | 72 | enterEntry | `var_refs = p->u.func.var_refs` **17844** | C 局部；zjs 这面镜子已经是对 qjs 的对齐 | 写是 ARCHITECTURAL；**读**是 ZJS-ADVANTAGE（R5-S get_var_ref0） |
| 6 | `catch_target` | （frame 后） | enterEntry | 无热路径对应；异常走 sf | 热 opcode 不读 | ARCHITECTURAL；**可延后**到第一条会抛的 op |
| 7 | `frame.pc` | frame+8 | `syncPc` 在 CASE 头 | `sf->cur_pc = pc` **18190** | 同样一条 str | 同价，不是超额 |
| 8 | `stack.top_ptr` | stack+16 | `setTopPtr` / `str [x26,#16]` | 只改 x19 | helper / 回溯要内存里的 top | 热 leaf 若能证明下一条只用 x1：**可省**（小） |
| 9–14 | 1–6 的镜像 | 同 | `reloadAfterPop` / leaf return `1128–1133` | **无**。qjs `return` 走 `done`，C `ret`，caller 的 b/sf/sp/pc/var_refs **还在寄存器里** | 这 6 条是 musttail 的税 | ARCHITECTURAL |

08-10 的「14」= 进 8 + 出 6。stall 诊断封的是「继续找无主后端停顿」，**不**封「不许少写这 14 条里的死字段」。

`local_fast_blocked` / `active_dispatch_tbl` 只在 L0 stop 切，zoo 热路径不付。

## 3. 机器码样张

### qjs `call0..3`（四标签同一地址 `0x254ec`）

```
mov  x26, x28
sub  w27, w10, #0xec        // argc = opcode - OP_call0   (18179)
sub  x28, x19, w27, sxtw #4 // argv
str  x26, [sf, #48]         // sf->cur_pc = pc            (18190)
bl   JS_CallInternal        // 18191
; 释放 argv、*sp++ = ret、SWITCH
```

`call` / `tail_call` @ `0x25db8`：`ldrh argc; b call0+8`。  
`JS_CallInternal` 前言（17787 poll、17846 alloca、17860 填 undefined、17868 pc、17870 链 sf）是 **另一次 C 前言**，代价在 callee，不在 CASE。

### zjs `op_call1` @ `0x127be80`

```
stp  x29,x30,[sp,#-96]!
stp  x28…x19                    // 96B 总是
sub  sp, #0x220                 // 冷臂 execCall 的槽
ldr  [x3,#24]/[#56]
str  x9, [x8,#8]                // syncPc  (#7)
; resolveInlineFunction…
; miss → bl execCall → ret Outcome
; hit  → enterEntry 6×str → br next
```

`op_call_method` 同样前言，`sub sp,#0x3f0`，miss `bl callMethod`。

**FAITHFUL-FIXABLE 形状：**  
`op_call1_leaf` / `op_call_method_leaf`：无 stp、无大 sp，只做  
`resolve`（已是寄存器）+ `enterEntry` 的 6 str + `br`。  
eligibility 已有 `simple_inline_empty_leaf` / `exact_args_leaf_kind`（`opCall` 1388–1474 行）。冷 miss 跳回现 handler。  
qjs 参照：CASE 在 `bl` 前就是 frameless。这不是 TCO，也不碰 H3 reuse。

预期：deltablue/richards/raytrace 的 `call_method`+`call1` 前言从 ~25 条 spill 降到 ~0。价值要三 pad 才许进 R6；本批只登记。

### qjs `return` @ `0x257ac`

```
ldp  x4,x3,[x19,#-16]!     // 结果
cbnz flags, slow
; 释放 leftover（local_buf..sp，20701）
; 落到 JS_CallInternal done —— C ret
```

zjs `op_return`：一进门 0x160 帧 + 多臂（ordinary / empty-leaf / exact-leaf / ctor）。ordinary 热臂 `popOrdinaryFrame` + `reloadAfterPop` 的 6 str + `br`。  
`return_undef` 与 `return` **同符号**（dispatch 表 alias），naive n_hot=256 是整函数，不是热臂。定价用 ordinary/leaf 臂，不要 256。

## 4. 闭合度

C 家族 **指令预算不能用「每 op Δinsn × 频次」直接对 PMU**，因为：

- qjs 的单位成本大半在 `JS_CallInternal` 前言/后记，**不在** `label_OP_call*` 的 20 insn；只取 CASE 行会重演 7.12× 假差。
- zjs 的单位成本在 handler 前言 spill + 14 store + callee 跑 + 恢复。

保守估计（只计可见差额）：

| 项 | 每 call z 多付 | 锚点次数 | 备注 |
|---|---:|---:|---|
| 96B+大 sp 前言 | ~20–30 insn | DB call_method 31.7M | FAITHFUL 克隆可删 |
| enter 6 store | 6 | 同 | ARCHITECTURAL |
| return 6 store | 6 | DB return 24.9M | ARCHITECTURAL |
| qjs 嵌套前言 | （qjs 付、zjs leaf 不付） | | zjs leaf 的对冲 |

方向：leaf 克隆若砍掉前言，DB 31.7M × 25 ≈ 0.8G insn，相对 DB FW ~5.7G cycles 不是直接换算，但量级够进「登记、组包后再 3-pad」。单条不够 0.3pp 门。

RayTrace 1.253 insn 主要仍是 apply/arguments/ctor（旧归因 49% call machinery），不是这 14 store。

## 5. 不要做

- 不要重开 H3 `tail_call` / reuse / 嵌套 `JS_CallInternal`。  
- 不要把 14 store 写成「无主 stall」。  
- 不要在有 `bl execCall` 的同一函数上指望编译器删掉 96B 帧。
