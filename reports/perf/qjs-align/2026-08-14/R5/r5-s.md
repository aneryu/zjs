# R5-S BUDGET — get/put_loc · push/dup/swap · dispatch 边界

lane: R5-S / CPU 8 / 诊断批，src 只读  
日期：2026-08-14  
config: `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`  
zjs pad0 `12bc8b8a…cf3309d` / qjs labels `394d453d…381a1f` / qjs pinned `b76d1542…1171364d`  
zjs-profile（只供频次）`b2b612f3…2d04d5`

## 结论先行

1. **S 家族热路径 zjs 静态指令更少，不是赤字源。**  
   `get_loc0` 12 vs 18、`get_loc8` 14 vs 21、`dup` 12 vs 16、`drop` 10 vs 17、`get_arg0` 14 vs 19、`get_var_ref0` 15 vs 21、`push_0` 12 vs 13。
2. **每次 dispatch 的「重建税」= 0。**  
   pc/sp/var_buf 常驻 x0/x1/x2，热 handler 不从 `vm.*` 重载。qjs 每次 `get_loc0` 从 `[x29,#-248]` 重载 `var_buf`（quickjs.c:18589 的 `var_buf[0]` 是 C 局部，GCC 把它溢到 fp 槽）。
3. **dispatch 尾本身 zjs 更短：** 5 insn（`ldrb [x0,#1]!` / `adrp+add` / `ldr` / `br`）vs qjs SWITCH 8–10 insn（`mov pc`、两次 `add` 拼表、`mov sp`、`ldrb`、两个 `mov`、`ldr`、`br`）。含在上表 Δ 里。
4. **R4-U zlib「dispatch 68.9%」作废为分类伪影。**  
   `bucket_from_perf.py` 把一切 `tailcall_dispatch.*` 打进 dispatch；qlab 把 `label_OP_get_loc*` / `goto` / `push` 也打进 dispatch。zlib 真实谱是 S 59% + A 34% + P 7% + C **0.0%**。
5. **闭合（insn 轴）：** zlib 全谱 opcode z/q = **0.9980**（4.019G / 4.027G），PMU insn z/q = **0.9355**。S+A 热路径 Σ(freq×Δinsn) 为负、量级 ~数 G，与「zjs 少退役 6.5% 指令」同向。  
   **周期轴不闭合、也不该用 insn 预算闭合：** cycles 1.086、IPC 0.861。残差是 256 个 `align(64)` handler 的 I-cache/BTB，不是少写几条指令能收回的。
6. 裁决：S 热体全部 **ZJS-ADVANTAGE（勿破坏）**。dispatch 形态 **ARCHITECTURAL**（musttail 分函数 vs qjs 单 `JS_CallInternal` computed-goto）。无 FAITHFUL-FIXABLE 过门槛项。

## 1. 频次（zjs-profile `--profile-opcodes`，fixed-work ÷16）

S 占全 zoo 的 42–59%。zlib 最极端（4.019G opcode，C≈0）。

| bench | S 份额 | 头部 S |
|---|---:|---|
| zlib | 59.1% | get_loc8 13.4 / push_0 12.8 / put_loc8 5.5 / push_2 4.6 / push_1 3.8 / get_var_ref0 3.8 |
| raytrace | 47.4% | get_loc0 10.1 / get_arg0 6.5 / get_arg1 4.8 / put_loc0 3.6 / push_0 3.6 / push_this 3.5 |
| typescript | 45.1% | get_loc0 8.9 / get_arg0 5.3 / get_loc8 4.2 / get_var_ref0 3.1 / push_this 2.8 |
| deltablue | 42.2% | get_loc0 14.2 / push_this 8.0 / put_loc0 8.0 / get_arg0 3.1 / get_loc2 3.0 |

覆盖家族 ~90% 的头部已全部对照。

## 2. 热路径并排（含 qjs SWITCH 尾）

方法：从 handler 入口跟 **int/简单值** 臂到第一条 dispatch `br`。冷臂 `br` 到 `cold_table`（zjs `+0x988`）不算热体。qjs 空 `label_OP_call0` 一类已并入共享尾；`push_0..7` 共享 `label_OP_push_0` @ `0x253dc`（13 insn，用 `w10-0xb3` 当立即数）。

### 样张 `get_loc0`（S 频次第一档）

zjs `opLoc get/c0` 12 insn：

```
ldp  x8, x9, [x2]          // var_buf[0]，x2 常驻
cmn  x9, #0xa              // tag >= -9 ?
b.ls skip_rc
ldur w10, [x8, #-4]
add  w10, #1
stur w10, [x8, #-4]
stp  x8, x9, [x1], #16     // push
ldrb w8, [x0, #1]!         // next op，pc++
adrp+add table
ldr  x4, [x9, x8, lsl #3]
br   x4
```

qjs `label_OP_get_loc0`（quickjs.c:18589 `*sp++ = JS_DupValue(ctx, var_buf[0]); BREAK`）18 insn：

```
ldur x1, [x29, #-248]      // 每次重载 var_buf   ← zjs 不需要
add  x2, x19, #0x10
ldp  x1, x0, [x1]
cmn  w0, #0xa
b.ls skip
ldur w3, [x1, #-4] / +1 / stur
mov  x8, x28
stp  x1, x0, [x19]
add  x0, x20, #0xb70 / #0x630   // 拼 dispatch 表
mov  x19, x2
ldrb w1, [x8], #1
mov  x10, w1 / mov x28, x8      // 维持 opcode/pc 惯例
ldr  / br
```

qjs 为什么多 6 条：① `var_buf` 不在寄存器（溢到 fp）；② SWITCH 要重写 x19/x28/x10。两边 RC 协议同形（`cmn tag,#10` + header-4）。

### 预算表

| opcode | freq 锚点 | z hot | q hot | Δinsn | 归类 | 裁决 |
|---|---|---:|---:|---:|---|---|
| get_loc0 | RT 10% / DB 14% | 12 | 18 | −6 | 栈访问 + dispatch 尾 | **ZJS-ADVANTAGE** |
| get_loc8 | zlib 13.4% | 14 | 21 | −7 | 同上 + `pc[1]` 解码 | **ZJS-ADVANTAGE** |
| put_loc0 | DB 8% | 18 | 19 | −1 | RC free + `vm.ctx.rt` 多一跳 | 近平；zjs 多 `ldr [x3]; ldr [x8,#2080]` |
| put_loc8 | zlib 5.5% | 20 | 22 | −2 | 同上 | **ZJS-ADVANTAGE** |
| dup | 各 2% | 12 | 16 | −4 | RC + dispatch | **ZJS-ADVANTAGE** |
| drop | | 10 | 17 | −7 | RC free + dispatch | **ZJS-ADVANTAGE** |
| push_0..7 | zlib 12.8+4.6+3.8 | 12 | 13 | −1 | zjs 小整数表；qjs `w10-0xb3` | 近平 |
| get_arg0 | RT 6.5% | 14 | 19 | −5 | 同 get_loc，arg 窗 | **ZJS-ADVANTAGE** |
| get_var_ref0 | zlib 3.8% | 15 | 21 | −6 | `vm.var_refs_base`（x3+#72）vs qjs `[fp,#16120]` | **ZJS-ADVANTAGE** |
| goto8 | | 10 | 13 | −3 | 相对跳 + dispatch | **ZJS-ADVANTAGE** |
| if_false8 简单值 | zlib 1.9% | ~14 | 22 | −8 | 含两侧 interrupt_counter（qjs:7877 / zjs `ctx+2160`） | **ZJS-ADVANTAGE** |
| dispatch 尾（已含上列） | 每次 | 5 | 8–10 | −3..−5 | handler ABI | **ZJS-ADVANTAGE** 静态 |

`put_loc` 的 `vm.ctx → rt` 是 `replaceOwnedDuringActiveBytecode` 的自由参数，不是 16B 表示税。两边都是 16 字节 tagged（qjs.h:56–65，64-bit **不** 开 `JS_NAN_BOXING`）。

## 3. ABI 对照（READFWD 产物精神，本批直接反汇编）

| 状态 | qjs computed-goto 常驻 | zjs handler `callconv(.c)` |
|---|---|---|
| pc | x28 | x0 |
| sp | x19 | x1 |
| var_buf | **溢到 [fp−248]**，每 op 重载 | **x2 常驻** |
| ctx / 表基 | x20 / x22 | 表 = adrp PC-rel；ctx = `[x3]` |
| 上一 opcode | x10（`call0..3` 用 `w10-0xec` 算 argc，quickjs.c:18179） | 不保留 |
| 其余 | 单帧 C 局部 | `*Vm` @ x3 |

READFWD 已证：再往 x4–x7 塞 forwarding 会拉长 FP↔GP 链。本批 **不** 重开 readfwd。  
量化：热 loc/arith **0 次** 从 vm 重建 pc/sp/var_buf。`enterEntry` 的 6 个 `vm.*` 店只在 call/return 写，见 R5-C。

## 4. 闭合度

- zlib opcode 数 0.9980（±0.2%）。S 头部 z−q 的 `get_loc8/put_loc8/set_loc8` 互换约 8M，是 `set` vs `put` 发射差，不是漏跑。
- Σ(freq×Δinsn) 对 zlib S 约 −5e9 量级，相对 qjs 89.6G insn 为 −6% 左右，落在 PMU insn −6.45% 的 ±15% 内。
- **周期超出 +8.6% 不在本家族指令预算里。** 归因：musttail 256-way `br` + 每 handler `align(64)` 的 I-cache/BTB。qjs 整本 `JS_CallInternal` 一个函数。这是 ARCHITECTURAL，与 D1–D9 封的「无主 stall 单点」不冲突——这里有名字：分派形态。

## 5. 不要做

- 不要给 `JSString` 加 capacity。  
- 不要把 loc handler 改回单函数大 switch。  
- 不要按 R4-U 的 68.9% 去「修 dispatch 桶」。  
- 不要动 get_loc 热体去「对齐」qjs 的 fp 重载。
