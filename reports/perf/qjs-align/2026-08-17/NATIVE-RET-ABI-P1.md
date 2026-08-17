# NATIVE-RET-ABI P1 — 链内三环（叶留 P2）

日期：2026-08-17。lane：w1:pW。枝：`grok/native-ret-abi` @ `935d3fb6` + 本提交。  
配置：`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`  
对照基：official `/home/aneryu/zjs/zig-out/bin/zjs`（同签名，NMFD 0x7b4 / assume 0x320 / 帧 `sub #0x1c0` + `stp #-64`）。  
数字 **非裁决用**。

| | |
|---|---|
| 票 | NATIVE-RET-ABI PR-0+PR-1 |
| 刀 | NMFD↔assume 24B `HostError!JSValue` sret → `NativeBits`（x0+x1） |
| 基 | `935d3fb6`（w43 salvage；无 thin_leaf） |
| 叶 | **未改**（P2） |

---

## 0. 裁决

**P1 立刀。P2 已接且更绿。**  
P1 pdfjs Δcyc **−180.2M**；P2（对同一 official 基）**−196.1M / Δbr −34.5M**。  
符号账：assume 汇合口 `str q0,[x19]` **消失**；NMFD `bl assume` 后 `cmp x1,#0x6`。  
test-exec **480/480**（P1 与 P2）。几何：NMFD **0x7b4**，`op_call_method` **0x3f0** 不涨。  
提交：`a65ed5c9` P1 / `7f905d35` P2。

---

## 1. 做了什么

### PR-0
`builtin_dispatch.zig`：`NativeValue = JSValue`，`nativeOk` / `nativeExc` / `nativeIsExc`（Debug `isException()==hasException()`），`nativeFromHostError`（`noinline`，只许叶/helper 边界），`nativeHostError`（uncatchable → `Interrupted`）。

### PR-1 三环
| 函数 | 今日 → P1 |
|---|---|
| `callResolvedNativeMethodAssumeCFunction` | `!JSValue` sret → **`NativeBits`**（`u128` overlay，Zig auto ABI 走 x0+x1） |
| `callInternalRecordDirectAssumeCFunction` | `!JSValue` → `NativeValue` |
| `callExecDirectRecord` / `invokeExecDirectRecord` | `!JSValue` → `NativeValue`；叶仍 `!JSValue`，**只在 invoke** `catch nativeFromHostError` |
| NMFD 接收 | `ldrh [sp,#96]; cbz` → `nativeIsExc` / `cmp x1,#6` → `handleCatchable(nativeHostError)` |
| `callResolvedExecDirect` / `WithEnvironment` exec_direct | **改接收**：`nativeAsHostResult` 把 NativeValue 收成 `!JSValue` |

**为何 `NativeBits` 而不是直接返回 `JSValue`：** Zig auto ABI 对 16B extern `JSValue` **仍 sret**（`add x0,sp,#0x48; bl assume; str q0,[x19]`）。`@bitCast` 成同宽无符号整数后，return 在 x0+x1。这是设计书写的 AAPCS64 合同，不是新机制。

P1 链上禁裸 `return error.*`（`AssumeCFunction` / `callExecDirect` / `invoke` / assume 包装）。  
Interrupt：`materializeRuntimeError` 短接保留；`nativeHostError` 在 `!JSValue` 接回处还原 `error.Interrupted`（test-exec 三个 Machine 金丝雀因此绿）。

---

## 2. 几何

| 钉 | official | P1 | 守法 |
|---|---|---|---|
| assume 体 | **0x320** | **0x2d8** | 缩 |
| assume 帧 | `stp #-64` + `sub #0x1c0` = **total 0x200**（标 0x1c0） | `sub #0x1d0`（callee 0x40 + locals **0x190**） | **total/locals 均缩**。`sub` 立即数 0x1d0 是 prologue 折叠，不是物化灌进热帧 |
| NMFD 体 | **0x7b4** | **0x7b4** | 墓碑 `.space 0x2a8`→**0x294**（live 0x50c→0x520）垫回 |
| NMFD 帧 | 0xd0 | **0xa0** | 缩（少 24B sret 槽） |
| `op_call_method` | 0x17d4 / `sub #0x3f0` | **同** | 不涨 |

P1 若把 setup 收成单 adapter 点（flag+三判），assume 反而胀到 0x1e0 / 多溅 x23–x28。**已回退**三路 early-return。

---

## 3. 符号账（热路径）

official assume 汇合：
```
mov x19, x0          ; NMFD sret
add x8, sp, #0x58    ; 叶 sret
blr leaf
ldr q0,[x8]; str q0,[x19]; str [x19,#16]
```

P1 NMFD：
```
mov x0, x19          ; ctx，无 sret
bl assume
cmp x1, #0x6         ; Tag.exception
```

P1 assume：**无** `str q0,[x19]`。叶仍 `add x8,sp,#…` / `blr`（P2）。

---

## 4. 验尺

编：`taskset -c 0-4,8-14 zig build zjs --seed 0`。  
测：CPU **15** 独占，`perf stat --no-inherit`，ABBA n=4。快照 `/tmp/lanes/native-ret-abi/{zjs-base,zjs-p1,fw.json,fw.py}`。

### pdfjs（立刀门 Δcyc ≤ −30M）

| | cyc mean | br mean | score |
|---|---|---|---|
| BASE | 12,705.5M | 11,370.2M | 7920 / 7915 / 7844 / 7801 |
| P1 | 12,525.2M | 11,375.7M | 7978 / 7988 / 7965 / 7980 |
| Δ | **−180.2M** | +5.5M | 全样本 P1 cyc < 全样本 BASE |

**过门。** 对 BASE 最快一枪（12,623M）仍约 −98M。

### 哨

| | Δcyc | Δbr | score |
|---|---|---|---|
| raytrace | +129.5M | **−130.0M** | 3705–3709 vs 3702–3723（重叠） |
| DB | **−99.2M** | +59.8M | 1439–1443 vs 1435–1441 |

raytrace 周期微涨、分支大降、分重叠 — 记噪声，不挡 P1（门在 pdfjs）。

### 单元
`zig build test-exec --seed 0`：**480 passed**（含 Interrupted 三金丝雀；首轮漏 `nativeHostError` 时 3 fail，已修）。

`git diff --check`：过。

---

## 5. 文件

- `src/exec/builtin_dispatch.zig` — NativeValue/Bits + 三环 + 接收 adapter
- `src/exec/vm_call.zig` — NMFD 接 NativeBits；墓碑 0x294；assume 返回 Bits

叶 / `ExecDirectCallFn` / typed TLS：**未动**。

---

## 6. 回滚

assume / NMFD 改回 `!JSValue`；墓碑改回 `0x2a8`。

---

## 7. PR-2 叶面（已做）

`ExecDirectCallFn` → `NativeBits`。五叶注册面：
- `stringCharCodeAtDirect` / `stringFromCharCodeDirect`（体仍 `!JSValue`，Direct 包装）
- `functionCallDirect` / `functionApplyDirect` / `functionHasInstanceDirect`（共享 `qjsFunction*Call` 仍 `!JSValue`）

invoke 不再 `catch` 叶错误联合。`fromCharCode` 对 `qjsStringFromCharCode` 的 sret 留在 Direct 内。

### P2 几何
| | P1 | P2 |
|---|---|---|
| assume 体 | 0x2d8 | **0x2c4** |
| assume 帧 | `sub #0x1d0` | **`sub #0x140`**（叶 sret 槽出 assume） |
| NMFD | 0x7b4 / 帧 0xa0 | **同** |
| 0x3f0 | 不涨 | **不涨** |
| cca 入口 | （P1 仍 `mov x19,x8`） | **`mov x19,x0`（ctx）**，无 sret dest |

### P2 FW（official vs p2，CPU15 ABBA n=4，`/tmp/lanes/native-ret-abi/fw-p2.json`）

| | Δcyc | Δbr | score |
|---|---|---|---|
| pdfjs | **−196.1M** | −34.5M | 8033–8076 vs 7849–7965 |
| raytrace | −76.3M | −91.3M | 3713–3722 vs 3708–3720 |
| DB | −262.9M | +34.4M | 1439–1447 vs 1434–1442 |

P1 的 raytrace +129M 哨在 P2 翻绿。

### 金丝雀
`String.prototype.charCodeAt.call(null)`：`TypeError` 栈  
`at charCodeAt (native)` / `at call (native)` / `at <eval>` — **与 official 逐行同**。  
`charCodeAt.call(42,0)` → `52` 同。

test-exec P2：**480/480**。`git diff --check` 过。

### 未做
PR-3 RS + test262 全量（设计：P1 几何稳才跑；driver 尺）。typed TLS / `NativeGenericFn` 不动。
