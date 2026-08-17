# PDFJS-SHELL-UNITCOST — NMFD+assume+sf vs `js_call_c_function` 逐指令

日期：2026-08-17。lane：w1:pW。**只析不改。** CPU **15**。数字 **非裁决用**。

| | |
|---|---|
| z | `/home/aneryu/zjs/zig-out/bin/zjs` official RF（`ee4ba9cc` docs；NMFD **0x7b4** / 帧 **0xd0**，assume **0x320** / 帧 **0x1c0**） |
| q | `/home/aneryu/quickjs/qjs`（`js_call_c_function` @ `0x4e394`，**0x45c** / 帧 **80+0x80**） |
| FW | `/tmp/census/det/pdfjs.js` |
| 原始 | `/tmp/lanes/pdfjs-shell-unitcost/` |
| 配置 | `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,…` |
| 对照 | NATIVE-WALK / RESID / NATIVE-THIN-TIER / NATIVE-THIN-PROBE（B-R1 NO-GO） |

**本尺（n=1 exclusive，`--no-children`）**

| | z | q | z/q |
|---|---:|---:|---:|
| cycles | 12.584G | 10.120G | 1.243 |
| insn | 59.442G | 55.360G | 1.074 |
| br | 11.366G | 9.385G | 1.211 |
| 分 | 7946 | 9914 | |

| 符号 | %cyc | M | %br |
|---|---:|---:|---:|
| NMFD | 2.48 | **312** | 2.57 |
| assume | 2.60 | **327** | 2.36 |
| **z 壳 Σ** | | **639** | |
| q `js_call_c_function` | 1.31 | **133** | 1.18 |

n ≈ **29M** native（与 L/P0 同量级；NMFD 312/11 ≈ 28M）。

| | cyc/call |
|---|---:|
| z 壳（NMFD+assume）/ 29M | **22.0** |
| q `js_call_c` / 29M | **4.6** |
| 司机口令 z~23 vs q~5 | **对上** |

`stringCharCodeAtDirect` 63M / q `js_string_charCodeAt` 66M —— 体不是本账。

---

## 0. 终判

### ① 几何宪法内有无 ≥30M 密度刀？

**无。**

最大三块看起来像「密度」的，都不是宪法允许的删除：

| 块 | M | 为什么不是刀 |
|---|---:|---|
| NMFD 成功路径 `popOwnedStackRegion` + 可能的 `drop`/`push` | **197**（NMFD 的 63%） | **RC 收栈**，q 做在 `JS_CallInternal` 里、**不进** 133M。搬走 ≠ 删掉。不是 native 协议。 |
| assume 成功 sret + 拆 0x1c0 + `ret`（`str q0 [x19]` 26% 汇合到 `1439a50`） | **107** | Zig `HostError!JSValue` **sret** + 16B tagged。q 是 `JS_NAN_BOXING` **uint64 走 x0**。把 assume 灌回 NMFD 消 sret = **0x1c0→0x1d0 宪**。改 `repr` 不是本战役。 |
| rec resolve / payload 旗 | **28** | 已是 K1 assume 路径。再把 `rec` 从 handler 传入 = **0x3f0→0x400**。28&lt;30。 |

其余逐步都 &lt;30M，且各有宪/对称钉死（见 §3 封条）。

B-R1 已证：另开 outlined 瘦终端跳过 assume，壳 1:1 换房东（thin_term 84 vs 迁出 assume 86）。**再切 hop 不是密度刀。**

### ② 签 pdfjs 壳封条

**签。** ② 前言对 pdfjs 不再立「再瘦协议」刀。壳单价 22 vs 4.6 是 **两跳 + sret + 16B tagged + NMFD 代收 RC** 的结构差，不是一条能在 0x7b4 / 0x1c0 / 0x3f0 / 留 sf 里剪掉的 ≥30M 退役跳。

---

## 1. 对位（谁跟谁比）

```
q:  OP_call_method 在 JS_CallInternal
      poll / 弹栈 / 压结果     ← 不进 133M
      hook = js_call_c_function  ← 本账
        建 sf · realm · overflow · cproto br · blr · 拆 sf · ret

z:  op_call_method 帧 0x3f0     ← G，本账不立
      bl NMFD                   ← 本账
        墓碑 · 0xd0 · rec · poll · bl assume
        assume 返回后 popOwned · drop/push · ret
      assume（.text.zjs.nmfd_term）← 本账
        0x1c0 · preflight · realm · sf · 7 参 · blr · sret
```

q 的 `js_call_c` 是 **一个函数、寄存器返回、nanbox 8B、函数指针在 `JSObject.u.cfunc`**。  
z 必须 **NMFD 与 assume 拆开**（0x1c0 宪），返回是 **error union + tagged 16B sret**，record 在 **payload memo**，弹栈 RC **写在 NMFD 里**。

所以 22 vs 4.6 **不是**「同一函数慢 4 倍」，是 **记账边界 + ABI + 表示** 三件事叠在符号上。

把 NMFD 里 197M RC 从壳里拿掉（它在 q 的解释器里）：z 协议核 ≈ assume 327 + NMFD 入口 115 = **442M / 29 ≈ 15.2 cyc/call**，仍是 q 的 **3.3×**。assume 单独 11.3 vs q 4.6 = **2.5×** —— 这才是 `js_call_c` 的对位物。

---

## 2. 逐步账本

n=29M。M = 本尺 exclusive × 段内份额。insn = 热路径静态条数（不是函数全长；NMFD 全 323 含墓碑洞与冷 miss）。

### A. NMFD（312M，帧 0xd0，尺寸 0x7b4）

| # | 步 | z 址 / 热 insn | cyc 份额 | ≈M | q 对位 | 差从哪来 | 可再瘦？ |
|---|---|---|---:|---:|---|---|---|
| 1 | 墓碑 `cbnz` | `1236140–48`，3 | 1.5% | **4.8** | 无 | 岛外 tombstone。从不采取 | **不。** 砍了 0x7b4 塌（K 首案） |
| 2 | 建帧 0xd0 + 取 argc/region | `614c–619c`，20 | 8.7% | **27** | 在 `JS_CallInternal`（argv 已是指针） | 9 参 outlined；要自己切 `receiver\|func\|args` | 再瘦会把活推回 0x3f0 |
| 3 | rec resolve（memo / payload） | `619c–61e8`，19 | 9.0% | **28** | `p->u.cfunc.c_function` **1 ldr** | z 要 `nativeRecordAssumeCFunction` + 冷填 cache（`object.zig:5986`）。q 指针就在对象上 | **不。** 传入 rec = 0x3f0→0x400。28&lt;30 |
| 4 | `pc+=2` + poll tick | `61e8–621c`，13 | 6.3% | **20** | poll 在 `JS_CallInternal`，**不进** 133M | 义务对称；房子不同 | **不。** 必须在进用户代码前 poll（qjs 同） |
| 5 | `bl assume` + 7/9 参 marshall | `639c–63c8`，11 | 3.7% | **11** | 无第二跳 | outlined hop。灌回 NMFD = 0x1c0 宪 | **不。** B-R1 换跳板不赚钱 |
| 6 | 异常检查 `cbz` | `63c8–6448` | 1.1% | **3** | 返回值即 `JS_EXCEPTION` | Zig `!T` 要单独看 error 码 | 跟 sret 同一 ABI，不单立 |
| 7 | **成功 popOwned + drop/push + epilogue** | `6448–664c`，126（含循环） | **63%** | **197** | `JS_CallInternal` 弹栈 / `JS_FreeValue` | z 把 RC 写进 NMFD；`ldp [x27,#8]` 一条 **23% NMFD** | **不属协议刀。** 搬走仍付。RC 战役另开 |

NMFD 热入口到 `bl assume`：**66 insn**，约 **91M / 3.1 cyc/call**。其余是 hop 回来之后的税。

### B. assume（327M，帧 0x1c0，体 0x320，`.text.zjs.nmfd_term`）

| # | 步 | z 址 / 热 insn | cyc 份额 | ≈M | q 对位 | 差从哪来 | 可再瘦？ |
|---|---|---|---:|---:|---|---|---|
| 8 | 建帧 0x1c0 + `tbnz wzr` | `14399b8–99e0`，10 | 6.4% | **21** | 同函数里 `sub #0x80`（8 insn / 24M） | z 第二份大帧；死 `tbnz wzr` ~3M（L 已否） | **不。** 0x1c0 宪；死跳 &lt;30 |
| 9 | preflight `cmp sp,limit` | `99e0–9a10`，12 | 1.7% | **6** | `js_check_stack_overflow`（qjs:**17580**），2 insn / 3M，`b.cc` 从不 | 对称。z 多几条 `mul length` | **不。** qjs always-check |
| 10 | realm / payload 旗 | `9a10–9a48`，14 | 5.8% | **19** | `ctx = p->u.cfunc.realm` **一 ldr**（17586） | z 对象旗 + payload 走（`nativeFunctionRealmAssumeCFunction`） | 再省会错 realm |
| 11 | `ldr [rec,#32]; cbz TLS` | `9a78–9aa0`，10 | 8.4% | **28** | 无（无 TLS 臂） | exec_direct vs TLS。L1 后金丝雀走 fallthrough | 删 TLS 臂会弄死非 direct |
| 12 | **sf push** + 7 参 marshall | `9aa0–9b00`，24 | 11.9% | **39** | 链 `JSStackFrame` ~11 insn / 27M | z `NativeBacktraceScope` 更肥（resolver 指针 + `is_native` + active 位）。7 参 = `ExecDirectCallFn`（output+caller 对） | **不丢 sf**（B-R1 / Alt-5）。7 参是孪生契约 |
| 13 | `blr exec_direct` | `9b00`，1 | 0.9% | **3** | `blr x25`（generic_magic）1.6M | 同形 | 留 |
| 14 | `cbz` 错误 + `materializeRuntimeError` | `9b08–9b48` | 3.3% | **11** | 叶返回 `JS_EXCEPTION`，无单独 materialize | Zig sentinel → JS Error 要在 sf **仍链着**时做（`builtin_dispatch.zig:335`） | **不。** 栈迹语义 |
| 15 | TLS 臂 | `9b48–9c20` | 3.8% | **12** | 无 | 非金丝雀 | 不是本壳刀 |
| 16 | **sf pop + 汇合 sret** | `9c20` `b 9a50`；`str q0 [x19]` **26%** | 24.9%+32.7% 汇合 | **81+107 有重叠；sret 汇合口 ≈107** | `rt->current_stack_frame = prev; return ret_val` 在 **x0**（nanbox 8B），29% / 38M | ① 16B tagged `str q0` vs 8B `x0`；② `!JSValue` sret 指回 NMFD 栈；③ 第二份 `ldp` 拆帧 | **不。** 消 sret = 内联 assume = 宪。改 tagged = altrepr 战役 |

assume 热到 `blr`：**84 insn / ~115M / 4.0 cyc/call**（已贵过整个 q `js_call_c` 的到-blr）。  
q 热到 `blr`：**52 insn / 86M / 3.0 cyc/call**，然后同一函数里拆 sf+ret（38M）。

### C. q `js_call_c_function`（133M，quickjs.c:**17562–17689**）

| # | 步 | 热 insn | ≈M | 采取 |
|---|---|---:|---:|---|
| 1 | 建帧 80+0x80 | 8 | 24 | 每发 |
| 2 | 取 `p` / `cproto` / `length` / `rt` | 11 | 14 | 每发 |
| 3 | `cmp sp,limit; b.cc` | 2 | 3 | **从不** |
| 4 | 链 sf + `ctx = realm` | 11 | 27 | 每发 |
| 5 | `cmp length,argc; b.gt` pad | 2 | 3 | **从不**（热） |
| 6 | `cmp cproto,#12; br` 表 | 11 | 12 | 采取 |
| 7 | generic_magic `blr` | 7 | 2 | 采取（fromCharCode 等）；generic 另 8M |
| 8 | 拆 sf + `ldp`×5 + `ret` | 18 | 38 | 每发 |
| — | 其它 cproto / pad / ToFloat64 | 207 | 9 | 冷 |

热路径退役跳：**2 从不采取 + 1 表 br**（NATIVE-WALK 仍成立）。  
无 TLS、无 memo 表、无第二 `bl`、无 sret、无 NMFD 级 RC 循环。

---

## 3. 封条（每步为何不可再瘦）

| 步 | 钉 |
|---|---|
| 墓碑 `cbnz` + `.space 0x2a8` | **0x7b4 岛外墓碑。** 体缩必须垫回。L3 / K 返工。4.8M 且从不采取 |
| NMFD 帧 0xd0 / 9 参 | 再减参就要 handler 多活指针 → **0x3f0** |
| rec 在 NMFD 内 resolve | handler 不跨 `bl` 传 rec（**0x3f0→0x400**）。memo 已是 assume |
| poll 在 NMFD | 对位 q `JS_CallInternal` 的 poll。不能进叶之后 |
| `bl assume` 拆开 | **0x1c0→0x1d0 宪。** 灌 env/sf 进 NMFD 已禁。B-R1 换终端不赚钱 |
| assume 帧 0x1c0 | 同一宪。死 `tbnz wzr` &lt;30 |
| preflight | qjs:**17580** always。热从不溢 |
| realm ldr | qjs:17586。z 布局多几枪，但必须切到 C_FUNCTION 构造 realm |
| `cbz exec_direct` | TLS 客户还在（typed 39M）。不能删臂 |
| **sf push/pop** | qjs 每个 C 函数都链 `JSStackFrame`。丢 = `Error.stack` / `CallSite.isNative` 破。Alt-5 / B-R1 v1 **留 sf** |
| 7 参 marshall | `ExecDirectCallFn` 孪生要 `output`+caller 对。叶 3 参探针已证不够付 hop |
| `blr` | 对位物，留 |
| 异常 / materialize | 必须在 sf 链着时把 sentinel 变成 Error |
| **sret `str q0`** | 消它 = 内联或改 `!T`/tagged。前者宪，后者 allepr。不是壳内刀 |
| NMFD `popOwned` 197M | **RC**。q 在解释器付。不是 ② 协议再瘦 |

宪法清单（本封条引用，不新立）：

- 不灌 assume / env store 进 NMFD（0x1c0→0x1d0）
- NMFD 尺寸 **0x7b4**（墓碑）
- `op_call_method` 帧 **0x3f0**
- `forwards_call` miss NMFD
- 留 `NativeBacktraceScope`
- `repr=tagged` 是生产表示

---

## 4. 密度差从哪来（一句话）

| 来源 | 大约 | 能否在宪内删 |
|---|---|---|
| NMFD 代收 RC（q 在解释器） | ~197M / ~7 cyc | 否（搬家） |
| 第二跳 + 0x1c0 帧 + sret 16B | ~110–130M / ~4 cyc | 否（宪 + ABI） |
| rec memo vs `u.cfunc` 一 ldr | ~28M / ~1 cyc | 否（0x3f0） |
| sf 实现更肥 + 7 参 vs 6 参 C | ~10–20M | 否（sf 语义 / 孪生 ABI） |
| tagged 16B vs q **nanbox 8B** | 含在 sret/RC 里 | 否（生产 repr） |
| 墓碑 + 死跳 + TLS 冷臂 | &lt;20M | 否 / 不够门 |

协议核对位（assume 11.3 vs q 4.6）：差在 **outlined hop 的帧与 sret**，不是某一条从未采取的 ≥30M 跳。

---

## 5. 与 B-R1 的衔接

探针把金丝雀从 assume 迁到 `callResolvedThinLeaf`（仍 preflight+sf，帧 0x190）：assume −86、thin_term +84。本账解释了为什么是 1:1——**贵的是 sf+帧+sret 形，不是 assume 这个符号名。**

下一张嘴若还在 ②，只能是 **另一场**：丢 sf（语义票）、改 tagged、或 RC 收栈。都不是本封条允许的密度刀。

---

## References

- z `src/exec/vm_call.zig` NMFD（`1c9972ab` 形：墓碑 0x2a8、无 P3 短路）`:709`；`resolvedNativeMethodRecordAssumeCFunction` `:627`；`dropUnusedCallResult` `:900`
- z `src/exec/builtin_dispatch.zig` `preflightCFunctionCallAssumeCFunction` `:415`；`NativeBacktraceScope`；`ExecDirectCallFn`；`materializeRuntimeError` `:335`
- z `src/core/object.zig` `nativeRecordAssumeCFunction` `:5986`
- q `quickjs.c:17562–17689` `js_call_c_function`；`quickjs.h` `JS_NAN_BOXING` → `typedef uint64_t JSValue`
- 原始 annotate / s：`/tmp/lanes/pdfjs-shell-unitcost/`
