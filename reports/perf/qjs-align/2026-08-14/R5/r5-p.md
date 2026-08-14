# R5-P BUDGET — get/put_field · get/put_array_el · 原型链

lane: R5-P / CPU 6 / 诊断批，src 只读  
日期：2026-08-14  
锚点：typescript · earley-boyer。  
TS 内层 +132M 的 other 顶符号（RC destroy/trace、`pushExactSimpleFrame`）一并定性。

## 结论先行

1. **对象数据属性命中的 `get_field` 是 ZJS-ADVANTAGE，禁止破坏。**  
   形状哈希 + 读槽 + RC dup 结果 + RC free receiver + dispatch，zjs ≈31 insn，qjs `label_OP_get_field` 51 insn（quickjs.c 对应 `JS_GetPropertyInternal` 快前缀 + BREAK）。R3 已量过 EB 属性读 0.79×。
2. **`get_array_el` 快数组臂被 0x50  spill 帧拖住。**  
   一进门 `sub sp,#0x50; stp x30/x25…`，只因为零 RC 臂要 `bl destroyZeroRef`。qjs CASE（quickjs.c `OP_get_array_el`）无帧。zlib 5.3%、pdfjs 3.6%、EB 2.0%。  
   **FAITHFUL-FIXABLE：** 把零 RC 析构 outline，让 int-index 快数组走 `get_loc0` 那种 frame-zero。这是本家族唯一具体方向。
3. **TS +132M 的 other 不是 property。**  
   R4-C：property 两侧都是 ~37%。顶符号 `destroyRuntimeCycles` / `traceChildren` / `pushExactSimpleFrame` = RC/GC + **C 家族帧**。X-10 之后不再存在 +180M property 账。
4. 闭合：TS/EB 的 P 指令预算为负或近平，对不上「修 get_field 追平」。TS 内层 1.215× 归 C/teardown（禁区 IMPL-TEARDOWN）+ 分派 IPC，不归属性哈希。

## 1. 频次

| bench | P 份额 | 头部 P |
|---|---:|---|
| typescript | 29.0% | get_field 17.4 / get_field2 5.1 / put_field 4.4 |
| earley-boyer | 20.2% | get_field 8.8 / get_var 7.8 / get_array_el 2.0 |
| richards | 30.6% | get_field 16.0 / put_field 5.2 / get_field2 4.7 |
| deltablue | 29.7% | get_field 14.5 / get_field2 8.4 / put_field 1.6 |
| zlib | 7.1% | get_array_el 5.3 / put_array_el 1.8 |
| raytrace | 26.6% | get_field 15.9 / put_field 4.7 / get_field2 3.2 |

TS+EB+zlib 的 P 头部已覆盖家族 90%。

## 2. 热路径

### `get_field` 对象数据命中

zjs `op_get_field`：

```
ldur x8, [x1, #-8]          // 栈顶 tag
cmn  x8, #1
b.eq object                 // 非 object → property_tail_tbl[0]（x3+#96）
object:
ldur x8, [x1, #-16]         // obj
ldur w9, [x0, #1]           // atom（短）
ldr  x10, [obj, #24]        // shape
; hash 探测（与 qjs find_own_property 同形）
ldp  val                     // 命中槽
cmn  tag, #10 / RC ++
stp  结果覆盖 receiver
RC -- receiver；非 0 → dispatch 5
; RC==0 → property_tail[release]（br，不在热计数）
```

入口 3 + 哈希 ~20 + 槽/RC/dispatch ~8 ≈ **31**。  
qjs 51，含 BREAK 尾；探测失败走 `label_OP_goto+0x574` 慢臂（共享尾，本批已计入「含尾」原则——慢臂不进热预算）。

**qjs: 属性哈希** `quickjs.c` `JS_GetPropertyInternal` / CASE(OP_get_field) ≈ 19436 一带。zjs 不需要多出来的指令：少的是重复的寄存器整理和一次更胖的 miss 内联。

裁决：**ZJS-ADVANTAGE**。EB 属性读 −216M 旧账与此一致。

`get_field2` / `put_field` 同形（put 多写槽 + 旧值 RC）。静态热前缀同样在冷 `br` 处被 naive dump 截成 6–8，**不要用 z-index 的 6/8 当成本**。

### `get_array_el` 快数组（FAITHFUL-FIXABLE）

zjs 入口 **无条件** 开 0x50 帧，然后：

- tag==int → `+0x4c`：校验对象、`flags` 快数组位、`index < len`、`ldp` 元素、RC、`+0x218` 释放 receiver、dispatch。
- 否则 `br property_tail[atom_key]` 或 cold。

qjs CASE(OP_get_array_el)（quickjs.c 约 19520）：无帧，int + fast array 直接取。

零 RC 时 zjs `bl destroyZeroRef`——这是帧存在的唯一理由。热路径（RC>1，数组元素几乎都是）仍付 4×stp/ldp。

| 项 | zjs | qjs | 裁决 |
|---|---|---|---|
| 快数组命中体 | ~30 + **10 帧** | ~40 含 BREAK | 体近平 |
| 帧 | 0x50 总是 | 0 | **FAITHFUL-FIXABLE**：outline 零 RC，热臂 frame-zero |
| 非 int / 非快数组 | property_tail | 慢 CASE | 两边都有，不定价 |

zlib 212.9M 次。即便每呼省 8 insn × 213M ≈ 1.7G，相对 89.6G ≈ 1.9% insn；IPC 主导下 zoo 分数不确定，**登记、不够单独立项**（<0.3pp 门）。组包时跟 R5-C 的 leaf-call 去帧一起做。

### `get_var`（TS/EB 热）

qjs `label_OP_get_var`：`[fp,#16120]` 全局表 + atom + RC + BREAK，约 24–30 热 insn。  
zjs `op_get_var` 走独立 handler（本批未把 30 insn 热臂拆完）。R3 消融证明 TS 赤字不在字符/`get` 胶水。不标 FAITHFUL。

## 3. TS +132M other

R4-C 7 桶（生产二进制，fixed-work）：property 18112 / 48930 = 37%。qlab 无标签作废。  
`pushExactSimpleFrame` = R5-C 的 leaf/exact 构造，不是 P。  
`destroyRuntimeCycles` / `traceChildren` = RC/GC；TS dump 两侧 objects **380558**、GC **21=21**，§4.2 容量公式已证伪。  
**不要在 P 家族立「修 TS property」项。**

## 4. 闭合度

- TS opcode z/q 1.0069；EB 0.8807（EB 少跑 12%，另账：`is_null` 3.7% 等形态差，不是 P 漏计）。
- P 热 `get_field` Δinsn 为负。家族指令预算 **不能** 解释 TS 1.215× 内层税。
- 残差交给 C（帧/teardown）和 S 的分派 IPC。

## 5. 不要做

- 不要动 `get_field` 命中臂「对齐」qjs 的 51 insn。  
- 不要重开 slow-property / X-10。  
- 不要把 `pushExactSimpleFrame` 写成 property 税。
