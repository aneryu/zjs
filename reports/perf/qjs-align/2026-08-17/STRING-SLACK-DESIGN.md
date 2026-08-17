# STRING-SLACK-DESIGN — 字符串载荷余量经济对齐 qjs（只设计）

日期：2026-08-17。lane w1:pW。**只设计，不写码、不建枝。**  
普查：`/tmp/lanes/STRING-SLACK-CENSUS.md`（过门，pdfjs 上限 **2.0–4.3 G cyc**）。  
前序：`/tmp/lanes/CONCAT-INPLACE.md`（无 usable_size 止步）、P6-B REJECT、w24 记账。  
数字一律 **非裁决用**。

| | |
|---|---|
| q | `/home/aneryu/quickjs/qjs` `04be246`：`JS_ConcatStringInPlace` **4671**，`OP_add_loc` **19770**，`JS_ConcatString2` **4712**，`__js_malloc_usable_size` **1699** |
| z | `main@553840ab` RF。flat `String` 12B + 4B rc 前缀；载荷 `allocStringAlignedBytes` → `allocAlignedBytes` |
| 红线 | 禁 `String.capacity` 字段（H2）；禁改对象/Shape slab 表；禁把 inplace guard 写成 `rc≤3` 代替 RC 编排；禁 pdfjs 形态特判；⑦ / bypass / 2048 不在本族 |

---

## 0. 结论先行（请裁这五句）

1. **松弛定理改述：**「qjs malloc 松弛在 zjs slab **一律**不可移植」过宽。它只钉死 **对象/Shape 精确类**（P6-B：2→4 永跨类）。String 载荷已经走 `allocAlignedBytes`，**可以单独改几何请求 + usable 查询**，对象 slab 一字不动。
2. **pdfjs 的 2.32M 不是「共享」：** 钩子上 rc==2/3 是 `add_loc` `loadOwned` + `stringAddStrings` 再 `dup`。qjs:19770 对 `*pv` **只取指针、不 Dup**，所以看 `rc==1`。差 2.32M vs 20k 就在这条时序。
3. **分期不可颠倒：** ① RC 编排（独立可验，几乎零周期）→ ② 只改 String 几何类 + usable/destroy 契约（w24 雷区）→ ③ 原地臂镜像 4671。缺 ① 则 ③ 写成 `rc==1` 摸不到 pdfjs；缺 ② 则大块 1.88M 发无余量。
4. **上限不是落地承诺。** 2.0–4.3 G 是「6.85 GB lhs 拷贝全消失」的天花板。落地预期写在 §5：① 只翻 census；③ 才吃 G 档，保守申报 **1–2 G** 等 pad。
5. **驻留不是 GB。** 6.85 GB 是累计拷贝。几何余量驻留全 zoo 估 **十到几十 MB 峰值（pdfjs 主导）**，不是第二套堆。

---

## 1. 范围圈定：只 String 载荷改几何类

### 1.1 松弛定理边界（改述）

| 对象 | 走哪 | 尺寸谁定 | 就地？ |
|---|---|---|---|
| Object / Shape / 值数组 | `SmallObjectSlab` `block_sizes` 16…512 **8B 阶**（与 qjs 小块表同） | 精确 `classIndex(请求)` | **禁。** P6-B：跨类 = 永 miss。定理仍在 |
| **flat String FAM** | `allocStringAlignedBytes` → `allocAlignedBytes` | 今天按 `inlineAllocationLayout(len)` **精确请求**；slice.len=请求；`destroyFlat` 再用 **当前 len** 反推 | 今天无松弛可查。**本族只改这一条** |

对象 slab 的 `block_sizes`、`classIndex`、Object `destroy` **不在本设计改动面**。

### 1.2 几何类（令面序列）

```
16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512,
768, 1024, 1536, 2048, 3072, 4096, …   // 交替 ×1.5 / ×2，封顶 String.max_length 布局
```

这是 **String 请求的圆整表**，不是改对象 slab。

≤512：圆整后的尺寸 **仍可落入现有 slab 类**（现表更密：40/56/72…）。实现选「≥ geo(need) 的最小现成 slab 类」——不增对象类、不改 8B 阶表。  
\>512：今天走 backing **精确字节**，普查 1.88M 发无 slab 余量。这里 **新建 String 大块圆整**（上表 768+），`rawAlloc(geo)`；对象大块路径不动。

`createUninitialized`：

```
need = inlineAllocationLayout(tag, unit_count).total_size   // 含 4B rc + 12B + FAM(+NUL)
got  = stringGeoRound(need)
bytes = allocStringAlignedBytes(got, align)
// 只把前 `len` 个单元当有效载荷；NUL 仍写在 len 处
```

禁加 `capacity` 字段。松弛 = `usable(base) − 已用 FAM`，与 qjs `JSString` 无独立 capacity 同形。

### 1.3 `usableSize` 查询（CONCAT-INPLACE ① 的补完）

qjs `__js_malloc_usable_size` **1699–1724**：

- 小块：`js_malloc_block_sizes[idx] − sizeof(header)`
- 大块：`mf.js_malloc_usable_size(lb) − sizeof(large_header)`（libc）

z 小块公式 **已经在** `SmallObjectSlab.usablePayloadFromClass`（memory.zig:169，注 qjs:1722）。缺的是 **对外查询 + String 释放不再用 len 反推**。

拟 API（只给 String 热路径用，不改 Object destroy）：

```
MemoryAccount.usableSizeAligned(ptr, align) usize
  小块（header 可识别 / 指针落在 slab）：usablePayloadFromClass(headerClass)
  大块：libc malloc_usable_size(分配基) ；若 0 则退回「本次 geo 请求」
         （P2 大块按 geo 请求分配，退回值 = geo，仍够用）
```

`destroyFlat` / `freeAlignedBytes` 的 String 腿：

- **信块头 / usable，不信 `layout(len)`**
- 删掉 String 释放上 `classIndex(slice.len) == header` 断言（len 变大后必炸，CONCAT-INPLACE §①）
- 新增 `freeAlignedBytesFromHeader(ptr, align)` 更干净，对齐 `__js_free` 只看 header

---

## 2. 原地臂：镜像 `JS_ConcatStringInPlace` 4671

### 2.1 谓词（不宽不窄）

```
JS_ConcatStringInPlace(ctx, p1, op2)                    // qjs:4671
  op2 非 string                     → FALSE
  p2->len == 0                      → TRUE（no-op）
  js_rc(p1)->ref_count != 1         → FALSE
  size1 = js_malloc_usable_size(p1) // 1699 / 1886
  p1 wide:
    size1 >= sizeof(*p1) + ((p1->len+p2->len)<<1)
      p2 wide → memcpy u16；否则逐单元升宽写
  p1 narrow && p2 narrow:
    size1 >= sizeof(*p1) + p1->len + p2->len + 1
      memcpy + NUL
  p1 narrow && p2 wide              → FALSE（不就地 widen）
```

z 对位（P3，且 **必须 rc==1**，见 §3）：

| q | z |
|---|---|
| `p1` = `JSString*` | flat `*String`（`asStringBodyRaw`）；rope 走现成 tail 臂，本臂不碰 |
| `js_rc(p1)->rc==1` | `header().rc==1`（P1 之后自然成立） |
| `js_malloc_usable_size(p1)` | `usableSizeAligned(rc_prefix_base)` |
| `sizeof(*p1)+FAM` | `string_rc_prefix + @sizeOf(String) + 单元字节（latin1 +1 NUL）` |
| 不就地 widen | 同；census `widen_skip` |

intern / atom：qjs 靠 atom 表多持一份 → rc>1 进不来。z 另加 Debug `atom_id==none`（不进热谓词）。

**hash：** 4671 源码 **不清** `hash`。建议 z 仍 `hash_meta.hash = 0`（懒算哨兵）——比 qjs 多一处、防脏哈希；标「超 qjs 一处」，批后做。不做也能镜像源码。

### 2.2 两个调用点（不要接到错的）

| 点 | qjs | 谁赚 |
|---|---|---|
| **`OP_add_loc` 19766–19777** | 双方已是 string：`ConcatStringInPlace(GET_STRING(*pv), op2)`，**不 Dup lhs**；中则 `Free(op2)`；不中才 `ConcatString(Dup(*pv), op2)` + `set_value` | **pdfjs 主粮**：长 lhs + 1B，无短串门 |
| `JS_ConcatString2` 4712 | 仅短+短（`JS_ConcatString` 5070–5074：`p2≤SHORT` 且 `p1≤SHORT2`） | 小钱 |
| `OP_add` 19729 | `JS_ConcatString` 吃两栈槽；长串走 rope | 不是 pdfjs G 档 |

今天 z `tryAppendStringInPlace` **只认 rope tail**（value_ops.zig:1232），flat 直接 false，再 `startAccumulatorRope`。P3 在 **add_loc 双方 string、建 rope 之前** 插入 flat 臂，对齐 19770。成功则 **不** `startAccumulatorRope`。rope 门/短并/透传一字不改。

---

## 3. RC 编排：为什么累加器背 2–3，怎么回到 q 的 1

### 3.1 两边时序

**q `OP_add_loc` 字符串（19766–19777）**

```
pv = &var_buf[idx];          // 槽拥有唯一引用
op2 = sp[-1];  sp--;
if (ConcatStringInPlace(ctx, JS_VALUE_GET_STRING(*pv), op2))
    JS_FreeValue(ctx, op2);  // p1 是槽里的指针，rc 仍是 1
else
    set_value(pv, ConcatString(Dup(*pv), op2));
```

**z 今天 `addLocalString`（vm_arith.zig:663）**

```
lhs = loadOwned(slot);       // dup → rc≥2
defer lhs.free();
defer rhs.free();
tryAppendStringInPlace(lhs, rhs, max_rc=2);   // 已把「独占」放宽到 2
startAccumulatorRope / binary
  → stringAddStrings → a.dup()+b.dup()        // 再 +1 → rc==3
  → stringAddStringsOwned                     // 普查钩子打在这儿
```

`loadOwned` = `slot.dup()`（value_slot.zig:10）。槽那一份还在，所以钩子永远看不到 rc==1。

普查：pdfjs flat+flat **rc==1 = 23.8k（0.90%）**；**rc≤3 = 2.32M**。crypto 200k 几乎全是 rc==2。不是真共享。

### 3.2 P1 改法（令面：时序改成 q 形，让 rc==1 自然成立）

只动 **双方已是 string** 的 `add_loc` / 与 19770 同构的寄存器冷臂：

1. **禁止** `loadOwned` / `stringAddStrings` 的预 dup。
2. 向 concat 传入 **槽里的 `*String`（borrow）+ 已拥有的 rhs**。
3. 命中（P3 之后）：只 `free(rhs)`，槽指针不变。
4. 未命中：才 `ConcatString` 形——`addStringsOwned(slot.dup(), rhs)` + `replaceOwned`，对齐 `Dup(*pv)`。
5. rope 独占尾：同样用槽上 `rc==1` 判断，不要为 rope 再留 `max_ref_count=2` 的「槽+临时」借口（P1 一并收）。

`OP_add` / `op_add_strings`：栈已拥有两槽，`addStringsOwned` 已 consume，**不要再经 `stringAddStrings` 的 dup**。长串仍走现成 rope；P3 只在 `ConcatString2` 同位给短+短加 inplace。

`stringAddStrings`（强制转换 / 非双方 string 入口）保持 borrow→dup→owned，那是冷路径。

**不写 `rc≤3` guard。** 那是普查口径，不是 q 谓词。P1 的验收就是让 q 的 `rc==1` 在钩子上成立。

### 3.3 P1 杀门（独立，不依赖几何/原地）

- 复跑 census 工装（只读钩）：pdfjs `add_flat_flat_rc1` **≥ 2.0M**（现 24k），且 `add_flat_flat_rc_le3` 不得明显高于 rc1（通胀吃掉）。
- `test-exec` 字符串 `add` / `add_loc` / 闭包捕获同一串（rc>1 不得就地改）。
- FW pdfjs / splay：**允许近零**（P1 不吃拷贝）；insn 不得回退 > 噪声。
- 金丝雀：`s = s + "x"` 循环后 `s` 身份可变（q 就地改同一块）；另持 `t = s` 再追加不得改 `t`。

---

## 4. GC / 记账 / 驻留

### 4.1 w24 之雷（本族条款，写进 P2 必读）

w24-combined：`createWithFam` **按请求入账、按 usable 出账 → 拆机守恒炸**。修成两侧同一公式。

本族再犯的三种写法：

| 禁 | 为什么 |
|---|---|
| alloc 记 `layout(len)`，free 记 `layout(新 len)` | 就地加长后出账对不上 |
| alloc 记 geo/usable，free 仍 `classIndex(slice.len)` 且 slice.len=逻辑长 | Debug 断言炸；Release 可能走错类 |
| 恢复 `classIndex(请求)==header` 在 String 释放上 | CONCAT 已证：len 变则必裂 |

**条款：** String 的 `allocated_bytes` **入、出同一函数** `accountedMallocSize(usable 或 geo 请求, slab_class?)`。小块已是 `usable+MALLOC_OVERHEAD`（memory.zig:454，w24 后）。大块 P2 按 **geo 请求** 入账，free 按同一 geo/usable 出账，**不要**再加一层 libc usable 却只出账请求（那是 w24 的镜像）。

`old_space.live_bytes`：String 不是 GC 对象链表户（4B rc 前缀，无 16B BlockHeader）。P2 **不要**把 String 塞进 gc list。阈值只走 `allocated_bytes`。

### 4.2 驻留估算（余量字节，全 zoo）

普查 6.85 GB 是 **累计 lhs 拷贝**，不是堆上多出来的。

几何类平均浪费约 **¼–⅓ 请求**（×1.5/×2）。驻留 ≈ ¼ × 活 String 载荷。

| 凳 | 拷贝体积 | 活串形态 | 余量驻留（估） |
|---|---:|---|---|
| **pdfjs** | 6.85 GB | 少量/一条长累加器 + 页缓存；lhs 已 KB–MB | **峰值十到几十 MB**（一条 4 MB 串落在 6 MB 类 ≈ 2 MB；多页则线性） |
| splay | 143 MB | 大量 15–63 B | **0.3–3 MB**（万级活串 × 十几 B） |
| crypto / 其余 | <25 MB | 可忽略 | **<1 MB** |
| **全 zoo** | — | pdfjs 主导 | **≪ 100 MB 量级，不是 GB** |

GC：`allocated_bytes` 含余量 → 阈值略提前（更勤），与 qjs `malloc_size` 含 usable 同向。P2 哨要看 pdfjs 分数不因多 GC 变差。

OOM：`test-oom` 21/21 必须仍过；String 圆整多申请的是类内字节，不是新失败点，但注入点按 **got** 不是 **need**。

---

## 5. 分期、杀门、验尺

### 5.1 序

```
P1 RC 编排     ──独立可合──►  census rc1 翻身
        │
        ▼
P2 String 几何 + usable/destroy/账   ──对象 slab 不动──►  守恒 + 驻留
        │
        ▼
P3 JS_ConcatStringInPlace 4671 / add_loc 19770   ──才吃拷贝──►  pdfjs G 档
```

禁止：P3 先上（pdfjs 20k 发）；P3 用 `rc≤3` 跳过 P1；P2 改对象 `block_sizes`。

### 5.2 各期杀门

| 期 | 必过 | 杀 | 预期（非裁决） |
|---|---|---|---|
| **P1** | census pdfjs rc1≥2.0M；test-exec 字符串+捕获；RS 字符串；金丝雀「别名不改 / 累加器可改」 | rc1 仍 ~20k；捕获串被就地改；pdfjs insn 明显回退 | 周期近零；dup/free 略少 |
| **P2** | test-core 串/OOM；`allocated_bytes` 守恒金丝雀；P6 官方 5e6 **insn 不回退**（证明对象 slab 没动）；splay 不回退 | Debug 释放断言；守恒炸；P6 变差 | 驻留 +10–几十 MB；周期近零 |
| **P3** | P1+P2 门仍绿；test-exec+**test262 全量**；hash/NUL/widen 拒绝；**regexp / crypto / code-load insn 不回退**（rope 墙） | pdfjs 近零（说明没接到 19770）；splay 同号大跌；rope 变多 | pdfjs **申报 1–2 G cyc**（上限 2.0–4.3 G）；splay 次尺 0–0.3 G |

### 5.3 验尺

| 尺 | 角色 |
|---|---|
| **pdfjs** `/tmp/census/det/pdfjs.js` | **主尺**。P3 才看 G；P1/P2 只看不回退 + census |
| **splay** `/tmp/census/det/splay.js` | **次尺**。发数多、字节少；geo 命中 48%，防短串回归 |
| regexp / crypto / code-load | **资产哨**。rope 承重墙；insn 同号不回退 |
| P6 官方 5e6 | **对象 slab 哨**（P2 专用） |
| EB / box2d / 其余 zoo | 全资产轻哨（串流量≈0） |
| RS + test262 全量 | P3 必跑；P1/P2 至少 test-core/exec + 字符串 RS |

FW：CPU15，ABBA n≥4，数字非裁决。3-pad 归 driver。

### 5.4 落地预期（避免把上限当承诺）

```
上限（普查）     2.0–4.3 G cyc   = 6.85 GB × 0.3–1.0 c/B，封顶本凳 4.32 G
P3 申报         1–2 G cyc        = 余量顺序命中 < 独立事件 99%；usable 查询税；仍有 1.17M rope 不在本账
P1              ~0               = 只搬 RC
P2              ~0（或微负 GC）  = 只改几何/账
```

---

## 6. 不要做

- `String.capacity` / 预留槽字段（H2）。
- 改 `SmallObjectSlab.block_sizes` 或 Object/Shape 就地扩（P6 定理仍在）。
- 把 inplace 写成 `rc≤3`「认通胀」（普查口径，不是 q）。
- 动 rope `appendRopeTail` / 短并 / `createBalancedRopeOwned` 语义。
- 为 pdfjs 加名字/形态特判。
- 用「同一 `total_size` 里那几字节 padding」冒充 4671（CONCAT 已否）。
- P2 把 String 登记进 gc list。
- 重开 `grok/concat-inplace` 旧尖（无 usable、无 P1，已 REJECT）。

---

## 7. 请裁

| # | 裁什么 | 建议 |
|---|---|---|
| A | 定理改述（§1.1）是否接受 | **接受**：只放开 String 载荷 |
| B | P1 独立先合、用 census rc1 翻身当杀门 | **接受** |
| C | P3 必须 `rc==1`，禁止 `rc≤3` 捷径 | **接受** |
| D | hash 就地后清 0（超 qjs 一处） | 建议做 |
| E | P3 申报 1–2 G 而非 4.3 G | **接受** |
| F | 开枝名 | `grok/string-slack`，三 commit：`p1-rc` / `p2-geo` / `p3-inplace` |

批后按 §5 序实施。本文件不改 src。
