# INSTANCEOF-PRICE — 7.9M 发单价（publish / 出岛 / q 形收尾）

**REJECT-ARCHIVE**（driver 2026-08-17）：主尺 Δcyc **+11.2M** 反向，岛体/帧双涨。勘察 ① `top_ptr` 承重 / ② 出岛必要 **入档保留**。instanceof 判定已在忠实地板。枝 `grok/instanceof-price` 已丢。

日期：2026-08-17。lane：w1:pW。原枝：`grok/instanceof-price` @ `ec0e0b1a`（基 `main@58e4f25c`）。  
对照：official RF `/home/aneryu/zjs/zig-out/bin/zjs`（`3afcbacd`，仅 docs 超前；`op_instanceof` 源与 58e4f25c **同文**）。  
配置：`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`  
主尺：`/tmp/lanes/eb-func/eb.d16.earley-only.js`。CPU **15** exclusive `--no-inherit`。数字 **非裁决用**。

n：census `instanceof` **7.93M**（`EB-INSTANCEOF.md`）。HASINST-DIRECT 已落地（默认 `@@hasInstance` 不再走 DINM）。

---

## 0. 裁决

| # | 问 | 答 |
|---|---|---|
| ① | z publish 集 vs q `cur_pc` 单写 | **每发多写 1 个字段。** q：`sf->cur_pc = pc`。z `publish`：`frame.pc` **+** `stack.top_ptr`。后者对位 q 的 `cur_sp`，而 q 在 CASE 运行中把 `cur_sp` 置空（`quickjs.c:17803`），GC 不靠它扫运行中的操作数栈。z 的 helper/GC 读 `Stack.top_ptr`，**热路径不能删**。试过拆成每臂 `setTopPtr` → 岛 `0x9ec→0xad4`，已回退。 |
| ② | noinline 出岛跳是否必要 | **必要。** handler 宪：岛内禁把 7 参 `ordinaryHasInstance`（体 0x544 / 帧 0xb0）内联进 `op_instanceof`。`completeOrdinaryInstanceof` 无 `linksection`，`bl` 出岛，避免 ohi 帧灌进 0x190 handler（0x1c0 宪同类）。不能为省一跳而胀岛。 |
| ③ | 忠实对齐 | **落地。** 出岛跳留下；completer 改 q 形：从寄存器 `sp` 取两操作数，成对 `free` + `sp[-2]=bool`，caller `cont(pc+1, sp-1)`（qjs:16015–16017 / 20416 `sp--`）。不再 `popOwnedStackRegion`。 |

**单价尺：** earley-only ABBA n=4，**Δins −25.5M**（方向稳），**Δcyc +11.2M**（噪声/未过 30M）。不是立刀门。语义/岛钉绿。

---

## 1. ① publish 集

### q（`quickjs.c:20412–20417`）

```
CASE(OP_instanceof):
    sf->cur_pc = pc;                 // 仅此一字
    if (js_operator_instanceof(ctx, sp)) goto exception;
    sp--;                            // 寄存器
    BREAK;
```

`js_operator_instanceof`（16005）用 **CASE 的局部 `sp`**：`op1=sp[-2]; op2=sp[-1]; … JS_FreeValue; sp[-2]=bool`。不写 `sf->cur_sp`。解释器进函数时 `sf->cur_sp = NULL`（17803），运行中 GC 不扫操作数槽。

### z（改前）

```
vm.publish(pc, sp);
  frame.pc  = (pc - code_base) + 1;   // ≈ cur_pc
  stack.setTopPtr(sp);                // ≈ cur_sp   ★ 多写
```

`completeOrdinaryInstanceof` 再用 `vm.stack.len()` 找回槽，然后 `popOwnedStackRegion`。

**每发多写：`stack.top_ptr`。** 7.93M 发 × 1 store。不是帧上再写 `var_buf` / catch / 其它。

删它会让 `ordinaryHasInstance` 里若走到 `getValueProperty(.prototype)` 的 GC 扫不到 lhs/rhs（z 靠 `top_ptr` 定 live 前缀）。EB 上该 Get **0%**，但一般路径不能省。

已有 `syncPc`（只写 `frame.pc`，注释即 q 的 `cur_pc`）。本票 **不** 在热路径只留 `syncPc`：Get 鉴定不依赖 `top_ptr`，但随后 Ordinary 要根。拆写入岛（见 §3 回退）。

---

## 2. ② 出岛跳

`op_instanceof` 在 `.text.zjs.op_handlers`（岛）。`completeOrdinaryInstanceof` **不在** 该 section → `.text`，`bl` 出岛。

为何必须 noinline：

- 岛 handler 宪：热路径上的大 `bl` 会把 callee 帧/spill 灌进 handler（`tailcall_dispatch.zig` 头注释；NMFD 0x1c0 宪同构）。
- `ordinaryHasInstance` 7 参、体 **0x544**、帧 **0xb0**。从 handler **直接** `bl ohi` 会涨 `op_instanceof` 帧。
- 现：handler `bl` completer（2 参）→ completer `bl` ohi。ohi 帧留在岛外。

短化而不胀岛：只能 **瘦 completer**，不能把 ohi 拉进岛。本票即此。

---

## 3. ③ 实施

`completeOrdinaryInstanceof(vm, has_instance, sp)`：

- 槽：`(sp-2)[0]` / `(sp-1)[0]`（q 局部 `sp`）
- 成功：`lhs.free; rhs.free; (sp-2)[0] = boolean` — **无** `popOwned`
- 失败：仍 `recoverOwnedInternalCallRegion`（需已 `publish` 的 `top_ptr`）
- 仍 noinline，帧 **0x80**

`op_instanceof` 成功：`cont(pc+1, sp-1)`（q `sp--`），不再 `reload topPtr`。

`vm.publish` 仍在 handler 入口（2 store）。曾拆成 `syncPc` + 每臂 `setTopPtr`：岛 `0x9ec→0xad4`，**回退**。

---

## 4. 岛 nm 钉

| 符号 | BASE | NEW | |
|---|---|---|---|
| `op_instanceof` | **0x9ec** / 帧 `sub #0x1c0` @ `1070ec0` | **0xa10** (+0x24) / `sub #0x1d0` @ **同址** | 岛内微涨 36B |
| `completeOrdinaryInstanceof` | 0x1b0 / 0x80 @ `11921dc` | **0x1c8** / **0x80** @ **同址** | 仍出岛 |
| `ordinaryHasInstance` | 0x544 @ `1191c98` | **同** | |
| `op_call_method` | 0x17d4 / **0x3f0** @ `108ca00` | **同址同尺** | |
| NMFD | 0x7b4 @ `1236100` | **同** | |

邻居地址未滑。completer 仍在岛外。

---

## 5. 验尺

### earley-only（主尺，CPU15 ABBA n=4）

`/tmp/lanes/instanceof-price/fw.json`

| | BASE mean | NEW mean | Δ |
|---|---:|---:|---:|
| cycles | 3,152.8M | 3,164.0M | **+11.2M** |
| insn | 13,758.5M | 13,733.0M | **−25.5M** |
| branches | 2,730.2M | 2,731.5M | +1.3M |

insn 全样本 NEW < BASE。cyc 交叉，均值微涨。**未过 30M cyc 立刀门。** 分两边 `EarleyBoyer: Infinity`（夹具如此）。

### 单元 / test262

- `test-exec`：**480/480**
- test262：`Result: 0/49775 errors, passed 44581`。未改 `test262.conf` / `reports/`。
- `git diff --check` 过。

---

## 6. 文件

`src/exec/tailcall_dispatch.zig` — `completeOrdinaryInstanceof` 收 q 形；`op_instanceof` 成功走 `sp-1`。

回滚：completer 改回 `stack.len()` + `popOwned`。
