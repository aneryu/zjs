# L1-REPR-DIVERGENCE — 04be2460 引用件 JSValue 真形 + 对齐账

日期：2026-08-17。**只析不改。** CPU15（避 5/6/7/19）。数字非裁决。
改令：暂停「qjs 没有的新机制」；repr 按「镜像 quickjs.c / 引用件」当忠实域。
四条件申报 **不做**（令面：这是忠实对齐——能否成立由 §1 真形决定）。

| | |
|---|---|
| 引用件 | `/tmp/zjs-zoo-current-20260810.WfI7vw/qjs-04be2460` ≡ `/home/aneryu/quickjs/qjs`（`cmp` 相同，BuildID `c569967b…`） |
| 源钉 | `04be246001599f5995fa2f2d8c91a0f198d3f34c`（`/home/aneryu/quickjs` HEAD） |
| z 生产 | `repr=tagged` 16B · `/home/aneryu/zjs/zig-out/bin/zjs` |
| z 备选 | 本轮 `/tmp/l1-nanbox/bin/zjs` `repr=nan_boxed`（分析件） |
| 反汇编 | `/tmp/lanes/l1-repr/` |

---

## 0. 一句话

**04be2460 引用件是 16B tagged `{u, tag}`，不是 NaN-boxing uint64。** 与生产 z 同形。壳 walk 把 `js_call_c` 的 **x0+x1 两寄存器返回** 误写成「uint64 走 x0」。

因此：**z 默认 tagged = 已经在镜像本机 64-bit qjs 的表示选择**（`quickjs.h:63-65`，`#ifndef JS_PTR64` 才开 `JS_NAN_BOXING`）。把 z 翻成 nanbox 是**新的**忠实偏离，不是闭合偏离。

§2 收益账按真形重算：对引用件「搬运减半 / sret 消失」两条都不成立。

---

## 1. ① Ground truth — 04be2460 JSValue 何形

五件钉名/同源 `qjs`（含 zoo 目录里的 `qjs-04be2460`）DWARF 全是 **16**。`qjs-04be2460` 与 `/home/aneryu/quickjs/qjs` **byte-identical**。

### 1.1 源 + DWARF

`quickjs.h:63-65`：

```
#ifndef JS_PTR64
#define JS_NAN_BOXING
#endif
```

64-bit 不定义 `JS_NAN_BOXING`，走 `quickjs.h:229-232`：

```
typedef struct JSValue {
    JSValueUnion u;   /* offset 0 */
    int64_t tag;      /* offset 8 */
} JSValue;            /* size 16 */
```

引用件 DWARF：

```
DW_AT_name        : JSValue
DW_AT_byte_size   : 16
DW_AT_decl_line   : 229          /* 正是 tagged 结构，不是 147 的 uint64_t */
  member u    location 0
  member tag  location 8
```

`sizeof` 探针（同一头文件）：`sizeof(JSValue)=16`，`JS_NAN_BOXING=0`，`JS_PTR64=1`。

R5-S 已写过同一句（`r5-s.md:94`）：「两边都是 16 字节 tagged（qjs.h:56–65，64-bit **不** 开 `JS_NAN_BOXING`）。」

### 1.2 objdump：不是 NaN-box 的四条签名

NaN-box（`JS_NAN_BOXING`，`quickjs.h:145-151`）热路径应出现：`typedef uint64_t`、`tag = v >> 32`、单 `ldr`/`str`、`sp ± 8`。引用件 **一条都没有**。

| 探针 | 04be2460 实测 | 若是 8B nanbox 该看见 |
|---|---|---|
| `JS_CallInternal` `ldp` | **381** | 近 0（一字 `ldr`） |
| 同上 `cmn …, #0xa`（RC：`(unsigned)tag >= (unsigned)(-9)`） | **200** | 0；改 `lsr #32` + 区间 |
| 同上 `lsr #32` / `#0x20` | **0** | 每条 tag 判别 |
| 槽步 `add/sub #0x10` | 57 / 100 | `#0x8` |
| `JS_FreeValue` | `cmn w2, #0xa` @ `1c120` | tag 在 **x2** = 第三参 = 16B 结构体后半（x0=ctx, x1=payload, x2=tag） |
| `OP_get_loc0` `0x23e84` | `ldp x1,x0,[x1]; cmn w0,#0xa; stp x1,x0,[x19]; add x2,x19,#0x10` | `ldr; lsr#32; str; add #8` |
| `js_call_c_function` `blr` 后 | `mov x2,x1` @ `4e464` 再 `ret` | 叶只活 **x0**，不必救 x1 |

`OP_get_loc0` 全文（`quickjs.c:18589` → `0x23e84`）：

```
ldp  x1, x0, [x1]        ; 16B 值
cmn  w0, #0xa            ; tag 半字，RC
b.ls skip
ldur w3, [x1, #-4] / +1 / stur
stp  x1, x0, [x19]       ; 16B 写 sp
add  x2, x19, #0x10      ; 槽 +16
br   table
```

与 z `op_dup` `0x1074bc0` **逐步同构**（`ldp; cmn #0xa; rc++; stp; +16`）。

`js_call_c` 热返回不是「uint64 走 x0」：

```
4e460  blr  x25            ; C 函数按 AAPCS64 返回 16B → x0+x1
4e464  mov  x2, x1         ; 必须把第二寄存器挪开
4e46c  mov  x1, x2
4e4a8  ret                 ; 调用方收 x0+x1
```

### 1.3 壳 walk 为何写错

`/tmp/lanes/PDFJS-SHELL-UNITCOST.md` §0：「q 是 `JS_NAN_BOXING` uint64 走 x0」。
对照 `4e464 mov x2,x1`：walk 看见 `ret` 前 x0 有值，**没把 x1 第二半算进 ABI**。z 侧 `str q0 [x19]` 是 `HostError!JSValue` **sret**，对比物应是 q 的 **x0+x1**，不是 8B x0。

107M 仍是真税（sret 协议）。归因「16B vs 8B nanbox」不成立。

### 1.4 忠实域结论

64-bit qjs 的机制选择就是 **tagged 16B**。z 生产 `repr=tagged` 已经对齐引用件。
`quickjs.h` 里的 `JS_NAN_BOXING` 是 **非 JS_PTR64** 的另一套，本引用件未编译进去。
z 的 `-Dzjs_nan_boxing` 还是 **自定义 48-bit prefix**，即便翻开也 **不是** qjs 高 32-bit tag 的 bit ABI（`docs/architecture.md:50-51`）。

---

## 2. ② z→NaN-box「收益」账（按真形重算）

对照物 = **04be2460 16B tagged**，不是想象中的 8B q。
z nanbox 数字来自 `/tmp/l1-nanbox/bin/zjs`（本轮可链）。

### 2.1 四消费面

| 面 | 令面预期（相对「8B q」） | 相对 **04be2460 真形** | 相对 z tagged |
|---|---|---|---|
| 值搬运 | 减半（`ldp`→`ldr`） | q 自己就是 `ldp`/`stp`。z nanbox 变 `ldr`/`str` 是**偏离**引用件 | `dup` 12→**16** insn（省 1 store，加 4 前缀解码） |
| sret 消失 | 8B 可走 x0 | q 走 **x0+x1**，本就无 sret。z nanbox assume **仍 sret**（帧 0x1c0→0x1b0） | 107M **不灭** |
| 帧宽 | 槽 16→8 | q 槽 16。z 半宽 = 操作数栈与 q **不再同宽** | `Entry` 256→248（−8B）；相对 q 64B 帧可忽略 |
| 比较/RC | 更短？ | q 是 `cmn tag,#0xa` / `orr` 两 tag。nanbox 是 `add+lsr#48+cmp`，**更长** | `get_field` 0x324→0x344；`if_false8` 钉址碎 |

int `add`：q `0x23958` 与 z tagged `op_add_loc` 都是 `orr` 两 tag + sxtw。nanbox 热臂多 float 前缀 + NaN canonicalize + `csel`（D12 串行惩罚 2.99→**9.99**）。

### 2.2 五落后案预期（翻 nanbox 相对今日 tagged，对照引用件）

| 案 | 命名税 | 翻 nanbox 预期 |
|---|---|---|
| pdfjs | sret + NMFD RC + 0x3f0 | sret 仍在 → **~0**。壳 22 vs 4.6 不动 |
| EB | L1I 墙 | handler 变长（`get_field`/`if_false8`）→ **负** |
| TS | call/return | 搬运已与 q 同构；本尺 insn≈1.00 → **<0.3pp，可 0** |
| box2d | BIN / 浮点 IPC | D12 FP 链变长 → **负** |
| splay | ⑦ RC | q 同样 `cmn #0xa`；nanbox RC 测更贵 → **0 或负** |

CPU15 n=1（tagged z vs 04be2460，`/tmp/lanes/l1-valuerepr/pmu.log`）：`mem_access` z/q = 1.11–1.18，**不是 2.0**。宽度假说在真形下先死。

---

## 3. ③ 实现代价面（若仍要翻 `repr=nan_boxed`）

这是「改 z 的备选表示」，**不是**「补上引用件有而 z 没有的机制」。

### 3.1 键与骨架

| 件 | 现状 |
|---|---|
| `-Dzjs_nan_boxing` | 有。64-bit 默认 false（与 qjs `#ifndef JS_PTR64` 同一政策） |
| 签名 `repr=` | `tagged` / `nan_boxed` |
| `value.zig` `NanBox` | 完整 48-bit 自定义箱。**≠** qjs `v>>32` |
| `test-altrepr` | 子构建翻 repr + expect_config |
| 本轮 `layout=short` + nanbox | **能链**（D12 时短布局断言过不了，今日已过，但岛漂） |

### 3.2 多少处按 16B / 已分叉

| 类 | 规模 | 翻开关时 |
|---|---|---|
| `@sizeOf(JSValue)` 参数化（stack/frame/arena/cpool/FFI `js_value_size`） | ~40 调用点 | 自动跟 8。栈/局部变密 |
| `value.zig` `if (comptime nan_boxing)` | **16** 处（make/hasTag/payload/tagOf/RC/dup/free/float/eq…） | 已写好 |
| `loadSlotAsIntPair` / `storeSlotAsIntPair` | 热路径几十处经这对入口 | 8B 时退回标量拷（已分支） |
| `asInt32Pair` / `has_fast_int32_slot_move` | arith / loc 快臂 | nanbox **关掉** payload-only 快移 |
| `Entry` comptime 钉 | tagged **256** / nanbox **248**（`inline_calls.zig:893`） | 已分叉 |
| `emptyLeafResumeWords` | tagged  overlay `native_caller`；nanbox overlay `_stride_padding` | 已分叉 |
| `jobs.zig` D1a 尺寸钉 | wide/narrow 两套 pin | 已分叉 |
| FFI `abi_encoding_revision` | tagged=1 / nanbox=3；`js_value_size` 进插件头 | 插件要重编 |
| 岛几何 / `if_false8` 钉 | 今日 tagged 钉 `0x1074880` | nanbox 址漂、体变长（已测） |

**硬编码「永远 16B」且无 nanbox 分支的生产断言：** `emptyLeafResume` 的 tagged 臂（`JSValue == 2*usize`）只在 `!nan_boxing` 下编译。没有发现「一翻开关就编不过」的残留钉——骨架是齐的。

### 3.3 GC / RC / 判别改写面

| 路径 | tagged（= q 04be） | nanbox（z 自定义） |
|---|---|---|
| RC 判定 | `(unsigned)tag >= (unsigned)(-9)` → `cmn ,#0xa` | prefix ∈ `[refcount_min, max]`：`add/lsr#48/cmp` |
| `dup`/`free` | 同一区间再 `retain`/`release` | 同，另有 deinit-skip 前缀尾 |
| `isObject` | `tag == -1` | prefix == `prefixOf(object)` |
| 两 int | `tag\|tag == 0` | 双 `bits>>48 == int_prefix` |
| float | `tag == 8`，payload 即 IEEE | 未装箱的 IEEE；热路径要 canonicalize |
| GC 头 | 在对象上，不在 JSValue 里 | 同；值宽不影响 mark 拓扑 |
| 短 bigint | 满 64-bit | **48-bit** 窗口（`short_big_int_bits`）——语义容量缩小 |

RC/GC 不用重写算法，要换的是 **每个值上的判别指令序列**。这正是热臂变长的来源。

---

## 4. ④ 旧「红鲱鱼」复审

**08-07 apply/arguments 定价**（`OUTCOME.md` / `10e8d4f9`）：

- 测的是 callshapes 每操作 cyc。>1.4× 全在 E0/C/D/G。次数与 q 相等。
- E0 差 468 insn，摊在物化壳（mapped/strict、template、`createFromShape`、`CellSliceRoot`），最大单项 6.9%。
- 同文否「float 稠密写贵在 boxing」（int/float 同价）。
- 当时两侧已是 16B。**宽度 A/B 解释不了 468 insn。** 红鲱鱼成立，边界=那一簇单价。

**08-13 D12** 才是真 repr A/B：nanbox 串行惩罚 3→10。否的是「压成 8B 就解决 FP 链」，不是 04be 的形。

**今日五落后项：** 壳 / L1I / call-return / BIN / RC。按 §1 真形，没有一项的主税是「z 16B / q 8B」。红鲱鱼 **扩适用**：连「对齐 nanbox = 忠实」这句也是红鲱鱼——引用件没有那套箱。

---

## 5. ⑤ 分期与杀门

这不是「补忠实缺口」的施工分期。引用件缺口 **不存在**。

| 期 | 做什么 | 过门 |
|---|---|---|
| **P0 收真形**（本文件） | 钉 04be2460 = 16B tagged；更正壳 walk 的 x0 误写 | objdump 四条签名（§1.2）任何人可复验 |
| **不立「默认改 nanbox」** | 与引用件同形已满足「镜像 64-bit quickjs.c」 | — |
| 若用户仍要做表示实验（非忠实） | 另立项，不叫对齐 | 下列杀门任一红即停 |

**若仍开实验，杀门（先于任何合入）：**

1. 必须先书面解释：`ldp`×381、`cmn #0xa`×200、`lsr #32`×0、`JS_FreeValue` 用 **w2**、dwarf line 229，如何是「NaN-box uint64」。解释不了 → 停。
2. `op_dup` / `get_arg0_fast` 热臂 insn：nanbox **≤** tagged（本轮 16>12、18>14 → 已红）。
3. `if_false8` 同址；`get_field` ≤ 0x324（本轮 0x344 / 址漂 → 已红）。
4. D12 `dep.js` 串行惩罚 nanbox ≤ tagged（历史 10>3 → 已红）。
5. pdfjs assume 汇合口 107M 必须消失（本轮 nanbox 仍 sret → 已红）。
6. box2d / navier / 四资产 3-pad 不得同号负。

P0 之后没有 P1 施工。壳 107M 若要砍，对象是 **`HostError!JSValue` sret → 与 q 一样 x0+x1 + exception tag**（错误模型/native ABI），不是翻 repr。

---

## 6. 请收

- 产物：`/tmp/lanes/L1-REPR-DIVERGENCE.md`（取代前稿 `MECH-L1-VALUEREPR.md` 的「新机制」框）
- 真形件：`qjs-04be2460` ≡ `/home/aneryu/quickjs/qjs`，反汇编 `/tmp/lanes/l1-repr/`
- 合 main：无
- 候组包：无
- 忠实偏离：在 JSValue 宽度/tag 形上 **无**（z tagged = 04be2460 tagged）
