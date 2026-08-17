# RET-ABI-TYPED — post-w44 壳复走 + typed 臂 NativeBits

日期：2026-08-17。lane：w1:pW。枝：`grok/ret-abi-typed` @ `e21cb4c5`（基 `main@0f721021`）。  
配置：`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`  
对照：w44 official `/tmp/lanes/ret-abi-typed/zjs-w44`（同 pin 签名）。数字 **非裁决用**。

| | |
|---|---|
| ① | post-w44 pdfjs ② 壳新账（NMFD 312 / assume 残段现值） |
| ② | typed TLS 臂延 NativeBits（`callTypedInternalRecordDirect`） |
| 门 | pdfjs FW ≥30M；四资产哨；RS / test262 |

---

## 0. 裁决

**① 壳：RET-ABI 已吃掉 assume 的 107M sret 汇合。现值 NMFD ~288M / assume ~175M（纸面 312 / 327）。② 剩的大头仍是 NMFD 代收 RC，不是 typed。**

**② 刀：立。** assume 面向的 typed 调度改 `NativeBits`（x0+x1）。pdfjs CPU15 ABBA n=4 **Δcyc −47.7M**（门 −30M）。regexp / DB 哨更绿。`NativeGenericFn` **未改类型**（叶仍 `anyerror!JSValue`；改全表是另一闭集）。

---

## 1. post-w44 壳复走（①）

纸面（`PDFJS-SHELL-UNITCOST`，RET-ABI 前）：NMFD **312M** / assume **327M** / 壳 Σ **639M** vs q `js_call_c` **133M**。n≈29M，单价 22 vs 4.6。

本尺：w44 official `perf record` cycles，pdfjs，CPU **15** exclusive `--no-inherit`。Event count **12.350G**（伴随 stat 12.424G / 分 8041）。

| 符号 | 纸面 % / M | w44 % | w44 M | Δ |
|---|---:|---:|---:|---:|
| NMFD | 2.48 / **312** | 2.33 | **288** | −24 |
| assume | 2.60 / **327** | 1.42 | **175** | **−152** |
| **壳 Σ** | **639** | | **463** | **−176** |
| typed `callTypedInternalRecordDirect` | （未单列） | **0.23** | **28** | — |
| cca Direct | 63（体） | 0.64 | 79 | 体，非壳 |

assume −152M 对上 P1+P2 立刀（−180 / −196；census n=1 vs ABBA）。NMFD 仍 ~288：成功路径 `popOwned` + push/drop，**RC 收栈**，q 做在 `JS_CallInternal`、不进 133M。

**② 还剩多少：** 463 − 133 ≈ **330M** 结构差。拆开：

| 残段 | 现值 | 还能不能立 ≥30M 壳刀 |
|---|---:|---|
| NMFD RC 收栈 | ~288 的大部 | **否**（宪：⑦ RC 不搬进 native 协议） |
| assume 残（preflight / realm / sf / 7 参 / 叶 blr） | ~175 | 本票 typed 再削一截（见下） |
| typed 调度 sret 回 assume | **28** | 单独不够 30；但灌在 assume 帧上的汇合可连带 |

L1 后 pdfjs **exec_direct 热、typed 冷（0.23%）**。typed 不是 ② 的主矿。regexp 相反（typed 密），本刀在那儿更肥。

---

## 2. 设计（② typed 臂）

镜像 `js_call_c_function` 对 cproto 表的直返：`ret_val = func(...)` 是 `JSValue`，不是 24B 错误联合。

| | 今日 (w44) | 本票 |
|---|---|---|
| `callTypedInternalRecordDirect`（assume 面向） | `HostError!JSValue` sret；`str q0,[x19]` ×14 | **`NativeBits`** x0+x1 |
| assume typed 臂 | `WithEnvironment` `catch` 再包一次 | `callTypedRecordWithEnvironment` 直返 NativeValue |
| `NativeGenericFn` / 其余 cproto 指针 | `anyerror!JSValue` | **不改**（叶 P2-typed，全表不是闭集） |
| 公共 `callInternalRecordDirect` / construct | `!JSValue` | **不改**（保留 `error.TypeError` 哨） |

adapter 只在 assume 面向的 typed 调度里：`typedFromAnyError` / `typedFail` → `nativeFromHostError`。公共 host 终端另留 `callTypedInternalRecordDirectHost`（原 switch），避免 `Map.set` 无 `this` 的测试从 `TypeError` 变成 `JSException`。

几何钉：assume **禁涨**；NMFD **0x7b4**；`op_call_method` **0x3f0**。typed 仍 outlined，不灌回 NMFD。

---

## 3. 几何

| | w44 | typed |
|---|---|---|
| assume | 0x2c4 / `sub #0x140` | **0x218 / `sub #0x110`** |
| NMFD | 0x7b4 / 0xa0 | **同** |
| `op_call_method` | 0x17d4 / 0x3f0 | **同** |
| typed（assume 面） | 0x648 + `str q0,[x19]`×14 | **0x5c0，无 sret dest** |
| typed host | （同一符号） | 0x648 `…DirectHost`（公共 API） |

---

## 4. FW（CPU **15**，ABBA n=4，`--no-inherit`）

`/tmp/lanes/ret-abi-typed/fw.json`。probe=`zjs-typed` vs `zjs-w44`。

| | Δcyc | Δbr | score new | score w44 |
|---|---:|---:|---|---|
| **pdfjs** | **−47.7M** | +12.9M | 8041–8078 | 8022–8036 |
| raytrace | −68.4M | +20.0M | 3704–3734 | 3705–3724 |
| DB | −469.0M | −11.0M | 1444 | 1430–1442 |
| regexp | **−505.1M** | −6.5M | 942–950 | 918–926 |

pdfjs **过 −30M 门**。四资产哨均未恶化。regexp 是 typed 密资产，账对得上。

---

## 5. 单元 / RS / test262

- `test-exec`：**480/480**
- RS：`2263 passed / 1 skipped / 1 failed`。唯一失败仍是 `object.zig:7652` 注释针 `"test262"`。空树 FileNotFound×2 因本票 `test262/` 已 init（同 pin `42496613`）而消失。**fail 不扩**（纸面 2258/3 → 2263/1）。
- test262 全量：`Result: 0/49775 errors, passed 44581`。未改 `test262.conf` / `reports/`。

---

## 6. 文件 / 回滚

- `src/exec/builtin_dispatch.zig` — assume 面向 `callTypedInternalRecordDirect` → NativeBits；host 孪生保留
- 提交 `e21cb4c5`

回滚：assume typed 改回走 `WithEnvironment` 的 `!JSValue`。

未做：把 `NativeGenericFn` 本身改成 NativeBits（全 cproto 叶面）。typed 在 pdfjs 仅 28M，那一刀要另立闭集。
