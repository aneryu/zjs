# L2-PROPGEO-DIVERGENCE — z vs q 属性存储几何忠实差异

日期：2026-08-17。lane **w1:pS**。**只析不改。**  
用户裁：暂停「qjs 没有的新机制」；JSC inline-slots **停**（旧稿 `/tmp/lanes/MECH-L2-INLINESLOTS.md` 不作本单产物）。  
本单只问：**同一套 64B 对象 / 56B shape / 外挂 values 里，z 有没有比 q 多一级间接、多一载、更散。**

地面真：`/home/aneryu/quickjs/quickjs.c`（`JSObject` 990 / `JSShape` 974 / `JSProperty` 947 / `get_shape_prop` 5127 / `find_own_property` 6135 / `GET_FIELD_INLINE` 19107）。  
z：`src/core/{object,shape,property}.zig`；热臂 disasm+annotate `/tmp/lanes/eb-gf/{z,q}-get_field.s` `ann-*-cyc-gf.txt`（GETFIELD-MIX，不重测）。  
n：`/tmp/r5/census/*-z.json`。数字非裁决。

钉死宪：`@sizeOf(Object)==64`、`@sizeOf(Shape)==56`、shape FAM 贴在 `sh+1`、`initial_prop_size=2`、Slot/JSValue RF **16B**。

---

## 0. 判决

**热属性读没有「z 比 q 多一级堆间接」。**  
两边都是：

```
obj ──+24──► shape ──FAM──► hash / Property 字
    └──+32──► values[i]     （16B 槽）
```

指针级数 = **2**（shape* + values*），qjs `p->shape` / `p->prop` 同址（+24 / +32）。GETFIELD-MIX：EB 每发 **8.8 vs q 10.0 cyc**，跳数同 8。再砍「少一载」没有忠实对象。

**唯一真几何分叉：Shape FAM 两半的次序反了。**

| | qjs（地面真） | z（现） |
|---|---|---|
| FAM | **`[hash_table u32[]][JSShapeProperty[]]`** | **`[Property[]][hash u32[]]`** |
| 常址 | `hash_table` = `sh+56` | `props` = `sh+56` |
| 要算的 | `get_shape_prop` = hash 尾（用 **mask**） | `hashBuckets` = props 尾（用 **prop_size**） |

查找顺序是 **先 hash 再 Property 字**。q 的常址正好是先用的那半；z 的常址是命中后才用的那半，hash 基址每发要 `prop_size<<3`。这是 **ALU / 编址**，不是第三块堆。

对齐：把 FAM 翻回 hash-first = 回到 `get_shape_prop`。**不碰 64B/56B 钉**，只改 FAM 内序。是否值得立刀见 §4（annotate 上这笔 ALU 是 handler 内 ~1%，EB ≪30M cyc）。

其余（空 `{}` defer values、数组 `length` 走 `u.array`、0 基下标）是 z **更少**分配或更少算术，不是多一载。

---

## 1. 逐字段：三件套

### 1.1 `JSObject` 64B vs `Object` 64B

qjs `quickjs.c:990-1077`（aarch64，`JSGCObjectHeader` = `list_head` 16B；块前另有 8B `JSMallocBlockHeader`，与 z `gc_prefix` 8B 对位）：

| off | qjs | z | 同？ |
|---:|---|---|---|
| 0 | `header` 16B | `header` 16B | 同 |
| 16 | 位域（extensible / exotic / fast_array / HTMLDDA / …）+ `class_id` u16 | `weakref_count` u32 | **序不同** |
| 20 | `weakref_count` u32 | `class_id` u16 + `ObjectFlags` u16 | 打包不同，热读不碰 |
| **24** | **`shape*`** | **`shape_ref*`** | **同** |
| **32** | **`prop*`** | **`prop_values*`** | **同** |
| 40 | `u` 24B 类联合 | `u` 24B（`@offsetOf==40` 钉） | 同宽 |

位域：z 收成 `ObjectFlags` u16（多 `may_have_indexed` / `class_payload_kind` / `has_weak_id`），仍在 **同一 2 字节**，get_field 命中不载。

`u.array`：q `{size|typed*, values*, count}`；z `{values*, count, capacity, length, pad}`。多一个 **capacity** 字（q 的 size 近义）+ 把 **length 从 `prop[0]` 挪进联合**（见 §3.3）。普通对象 `get_field` 不走这里。

### 1.2 `JSShape` 56B vs `Shape` 56B

| 字段 | qjs | z | 同？ |
|---|---|---|---|
| header 16 | 是 | 是 | 同 |
| `is_hashed` | u8 | bool + 对齐垫 | 同义 |
| `hash` / `prop_hash_mask` / `prop_size` / `prop_count` / `deleted_prop_count` | 是 | 是 | 同 |
| `shape_hash_next` / `proto` | 是 | `registry_hash_next` / `proto` | 同 |
| **`sizeof` 钉 56** | 是 | comptime 钉 | **同** |
| FAM 起点 | `sh+1` | `sh+56` | 同 |
| **FAM 序** | **hash → props** | **props → hash** | **反** |
| 桶下标 | `atom & mask` | 同（`propertyBucketIndex` 丢掉 `shape_hash`） | 同 |
| 链下标 | **1 基**（0=空） | **0 基**（`0x3ffffff`=空） | 编址不同，级数同 |
| `Property` / `JSShapeProperty` | 8B：`hash_next:26|flags:6` + atom | `packed struct(u64)` 同 | 同 |

`get_shape_prop`（5127）：

```c
return (JSShapeProperty *)((uint32_t *)(sh + 1) + sh->prop_hash_mask + 1);
```

hash 在 `sh+56`，props 在 hash 表之后。z 注释写「analogue of get_shape_prop 常址」——**说反了**：q 的常址是 **hash**，z 的常址是 **props**。

### 1.3 `JSProperty` 16B vs `Entry.slot` 16B（RF）

untagged union：`value` / getset / var_ref / autoinit。z `Slot` comptime 钉 16B。`Entry` 只是壳，不涨宽。  
`p->prop[i]` ≡ `prop_values[i]`。无第三块「值描述符」。

---

## 2. 逐间接级：热 `get_field` 命中

GETFIELD-MIX：自身首桶 data、values 在、字段要 RC。两边 annotate 最热点都是 **哨兵/atom cmp ~17%**，不是多出来的指针。

| 级 | qjs CASE | z handler | 多一载？ |
|---:|---|---|---|
| 0 | `ldp` obj，atom 从 pc | 同 | 否 |
| 1 | `ldr shape [obj,#24]` | 同 | 否 |
| 2a 哈希 | `ldr mask`；`atom&mask`；**`ldr [shape+56+h*4]`** | `ldp mask, prop_size`；**`add props+size*8`**；`ldr [buckets+h*4]` | **否。** z 多 1 次用 `prop_size` 的 `add`（与 mask 同 `ldp`，不是多一次堆载） |
| 2b 字 | `get_shape_prop+(h-1)` 三次 `add` 后 `ldr` atom/flags | `ldr [props+i*8]`（props 基已在寄存器） | 否（算账对调：q 命中后算 props，z 查找前算 hash） |
| 3 | **`ldr values [obj,#32]`** | **同** | **否** |
| 3b | `lsl #4; sub #16`（1 基） | `add i<<4`（0 基） | q **多** 一个 `sub` |
| 4 | 槽 `ldr`×2 / RC | `ldp` + RC | 同级 |

**堆间接：obj→shape，obj→values，shape→FAM。z 没有第四块。**

`cbnz values`（z 0.65% handler）：q 命中时 `prop` 已分配，无此测。空 `{}` 走不到命中臂。是可预测 taken，不是多一级。

---

## 3. 每差异折税（既有 census，不重测）

纸面 n = R5 `get_field`（TS **53.58M**）。handler 内份额 × GETFIELD / TS-RESID 独占。

| 差异 | 形 | 折税 | 立刀？ |
|---|---|---|---|
| **FAM 序反** | 每发 1 次 `add`（`prop_size<<3`） | annotate **0.91%** handler cyc。EB 字段 549M ×0.91%≈**5M**；TS 字段独占 ~4.9G ×0.91%≈**45M cyc**（上沿，含 skid） | 翻序可对齐 q；**不破 56B/FAM 钉**。EB 不到 30M；TS 擦边且 F 后每发已 ≤q，翻序奖金是编址不是少一堆载 |
| values `ldr #32` | 两边都有 | 不能记成 z 超额 | 否（JSC 已停） |
| `cbnz values` | z 多 1 预测跳 | EB ~4M；TS ~30M 量级 | 否（空对象 defer 的残，命中恒真） |
| 1 基 `sub #16` | **q 多** | z 已更短 | 勿改回 1 基 |
| 空 `{}` defer values | z **少** 一次 32B 分配 | 负税 | 勿为齐 q 而预分配 |
| 数组 `length` 在 `u.array` | z `get_length` 不走哈希 | 已是快路径（对位 q 的数组臂） | 勿塞回 `prop[0]` 当「忠实」 |
| `u.array.capacity` | 多 4B | 不在 get_field | 否 |
| Flags / weakref 字段序 | 打包不同 | 命中不载 | 否 |
| `hasPropertyHash` | 源多一门 | 热形状有 hash，handler 未见独立税 | 否 |
| 慢路径 `findProperty` 防御守卫 | get_length TA 等 | 已另账（GBEMU-TA-NAMED） | 不是本几何 |

**结论：没有「多一级间接」可折成 ≥30M×可砍的忠实刀。** FAM 翻序是唯一对齐项，税是 ALU，且与当年「props-first 减 transition 探针 stall」的选择对冲。

---

## 4. 对齐可行性 vs 钉死宪

| 宪 | 拦什么 | 本差异 |
|---|---|---|
| **64B `Object`** | 涨头 / 嵌槽 | **不挡** FAM 翻序。挡的是已停的 JSC 涨头 |
| **56B `Shape`** | 加 generation / 改头 | **不挡** FAM 两半对调（仍贴 `sh+56`） |
| **FAM 存在** | values 再拆第三块、shape 再外挂一份 hash | 翻序仍是一块 FAM |
| **`initial_prop_size=2`** | 改回 4 | 与本差异无关 |
| **Slot 16B** | 缩槽 | 已与 q `JSProperty` 齐 |

若立「FAM hash-first」：

- 改 `famBase`/`hashBuckets`/`props`/`get_shape_size` 镜像 `get_shape_size`/`get_shape_prop`；
- `find_own` 编址改 1 基或保持 0 基但桶在 `sh+56`；
- 验尺：get_field 每发 insn/cyc **不得回退**（GETFIELD 已赢）；transition/P6 哨不得回吐当年 props-first 要压的 stall；
- **预期小。** 不是过线刀。

不要：为齐 q 给空对象预分配 values；把数组 length 搬回 `prop[0]`；涨 64B；重开 P6-B。

---

## 5. 不要做

- 不要把 `ldr [obj,#32]` 写成 z 多一载（q 同址同级）。  
- 不要复活 JSC inline-slots。  
- 不要为字段序（weakref / class_id）重排对象头（热指针已在 +24/+32）。  
- 不要改 src。

未碰 test262.conf / reports / tools/perf。
