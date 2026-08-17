# NATIVE-THIN-P0 — 旗 + comptime 拒 + post-L1 普查

日期：2026-08-17。lane：w1:pW。**P0 按 NATIVE-THIN-TIER PR-0。**  
枝 `grok/native-thin-p0` 基 `main@9deb9f45`。CPU **15**。数字 **非裁决用**。

| | |
|---|---|
| 设计 | `/tmp/lanes/NATIVE-THIN-TIER.md`（APPROVED + 修正 B-R1） |
| 码 | 本枝 commit（见下） |
| z / RF | `/home/aneryu/zjs/zig-out/bin/zjs` **main@9deb9f45**（w41 L1） |
| FW | `/tmp/census/det/pdfjs.js` |
| 原始 | `/tmp/lanes/native-thin-p0/` |
| 配置 | `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off` |

B-R1（司机附修，写入本笔记）：若 P1 金丝雀单独 FW **<30M**，可用 **P1+P3 探针支**（measurement-only，不合入）合并测量裁决整层去留。P1 壳仍付 assume **0x1c0**，大头在 P3 短路，不在台阶上误杀。

---

## 0. 结论（给司机放行 P1 用）

| 项 | 裁决 |
|---|---|
| P0 码 | **交货。** `thin_leaf` 字段 + comptime 拒 + 单测。**零 dispatch 接线、零行为。** |
| dump (1) 金丝雀 **调用**份额 | 无 uprobe（tracefs 无权限）。不能报精确 retired-call。NMFD n ≈ **28–30M**（338M / ~12 cyc，与 L.md 同量级）。金丝雀是 post-L1 最大 `exec_direct` 体（Direct **58M**），但那是 **③ 体**，不是 ② 壳。 |
| dump (2) P1 可退役指令 | **否，<30M。** assume 里 7 参 marshall ~**6M**；Direct `sub #0x110` 帧 / SROA 后的 spill 含在 58M 体里，抽 mid-29 只能削其中一小截。**不要把 P1 当刀。** |
| 金丝雀 ② 壳份额 | 壳（NMFD **338** + assume **318** = **656M**）仍由 **全部** NMFD 调用付。P1 **不吃** assume 0x1c0。P3 才跳过 assume。 |
| **P1 放行建议** | 按设计书：**P1 = 协议落地**，无 ≥30M 刀门。普查支持「单独 P1 FW 会 <30M」。整层去留走 **B-R1：P1+P3 探针支**，不要在 P1 台阶误杀。 |
| 闭集审计 | 预判成立。够格：`charCodeAt` 热路径。不够格：apply / call / hasInstance / `fromCharCode`。无第二条 thin-noalloc 员。 |

验尺：`zig build test-exec --seed 0` **478/478**。`git diff --check` 过。NMFD 仍 **0x7b4** / 帧 **0xd0**；assume 体 **0x320** / 帧 **0x1c0**。`exec_direct` 仍在 `[rec,#32]`（单测钉死）。

---

## 1. P0 码（零行为）

| 文件 | 做了什么 |
|---|---|
| `src/core/host_function.zig` | `InternalRecord` / `InternalEntry` 在 `exec_direct` **之后**加 `thin_leaf: ?*const anyopaque = null`。注释钉 #32。 |
| `src/exec/builtin_dispatch.zig` | `ThinLeafFn` + `thinLeafFunction`。**不**进 `WithEnvironment` / NMFD / assume。 |
| `src/exec/internal_builtins.zig` | `denseRecords` 抄字段；`thin_leaf_allowlist = &.{}`；`thinLeafRejectReason` → `@compileError`。拒：`forwards_call` / construct / 无 `exec_direct` 孪生 / 非允许名单。 |
| `string_builtin_ops.zig` / `function_ops.zig` | 现有五条 `exec_direct` 断言 `thin_leaf == null`。 |

单测：

- `InternalRecord.exec_direct` offset == 32，`thin_leaf` 在其后
- 允许名单空；全表无 record 挂 `thin_leaf`；`exec_direct` 恰 5 条
- denylist 四因（`forwards_call` / constructor / missing twin / not on allowlist）
- `thinLeafFunction` 擦除指针相等
- `Function.call` 仍 `forwards_call` 且无 thin；apply / hasInstance / charCodeAt / fromCharCode 无 thin

回滚：删字段；无人读。

---

## 2. dump (1) — NMFD callee 直方图

尺：CPU 15 独占，`--no-children`，`armv8_pmuv3_1`，period 200003。  
`stat`：12.576G cyc / 59.218G insn / 11.304G br。分 7433（cg 那场）。

**不能报精确 call count**（`perf probe` 要 tracefs，本环境无 sudo）。下面是 exclusive 时间 + dwarf CG 时间份额。CG **不是** 调用次数：`apply` 栈下含用户 JS，样本被放大。

| 桶 | exclusive cyc M | exclusive br M | CG samples under NMFD/assume | 备注 |
|---|---:|---:|---:|---|
| **charCodeAt** `stringCharCodeAtDirect` | **57.9** | 40.7 | 297 | 金丝雀体（③）。env 孪生 `stringCharCodeAtCall` = 0（L1 已切走） |
| **fromCharCode** Direct | 16.3 | 13.6 | 556 | 不够格 thin（分配 + ToPrimitive） |
| fromCharCode 体 `qjsStringFromCharCode` | 69.2 | 67.8 | （含上） | ③ |
| **apply** `qjsFunctionApplyCall` | **0.0** | 1.1 | 2094 | 重入；CG 是用户 JS。pdfjs 几乎不热 |
| **hasInstance** Direct | **0.0** | 0.0 | 0 | pdfjs 不走 |
| **TLS** `callTypedInternalRecordDirect` | 39.0 | 32.8 | 3655 | 余量 |
| TLS `stringCall` | 8.8 | 7.9 | 300 | 余量（indexOf 等） |
| **NMFD** | **338** | 276 | shell_only 3055 | ② |
| **assume** | **318** | 233 | | ② |
| 其它 under-shell | | | 141 | |
| **② 壳 Σ** | **656** | 509 | under_shell 10098 / 62936 | vs 旧 RESID 690，同形 |

`Function.prototype.call` 是 `forwards_call`，**不进 NMFD**，不在本表。

n 估计：NMFD 338M / ~12 cyc ≈ **28M**（L.md ~30M）。金丝雀 n 不能从 58M 体反推成「一半调用」——体含 flatten / 下标，cyc/call 未知。

---

## 3. dump (2) — assume / NMFD / Direct 指令归因

官方 RF assume @ `0x1439348`，体 **0x320**，帧 **`sub #0x1c0`**。NMFD @ `0x1235a40`，尺寸 **0x7b4**（`0x12361f4-0x1235a40`），帧 **`#0xd0`**，墓碑 `cbnz` 仍在（`1235a48`）。`bl assume` @ `1235cc4`。

### assume 分段（占 assume 本地样本 % → ×318M）

| 段 | 址 | cyc % | ≈ M | 退役？ |
|---|---|---:|---:|---|
| 建帧 + preflight + realm ldr | `1439348`–`1439428` | **52.8** | **168** | **P1 不吃。** P3 跳过整个 assume 才吃。含 `tbnz wzr` 死跳、`cmp sp,limit; b.cs` 总采取 |
| `ldr x12,[x5,#32]; cbz TLS` | `1439428`/`143942c` | 2.0 | 6 | P1 会再多一条 `cbz thin_leaf`（税） |
| exec_direct：`NativeBacktraceScope` + 7 参 mov + `blr x12` | `1439438`–`14394d8` | **15.0** | **48** | v1 **留 sf**。P1 只瘦 7 参 mov（~6M）+ `callable_realm` 检查 |
| TLS 臂 + `bl typed` | `14394d8`– | **28.1** | **89** | 非金丝雀。typed 符号另 39M |
| `blr x12` 本条 | `1439490` | 0.44 | 1.4 | 叶入口 |
| `bl callTyped…` 本条 | `1439560` | 0.06 | 0.2 | TLS 入口 |
| `materializeRuntimeError` | | 0.00 | 0 | 热不走 |

`exec_direct` 仍是 `[rec,#32]`，与 L.md / 本 P0 offset 钉一致。

### 金丝雀 Direct（`stringCharCodeAtDirect` @ `0x13c0f34`，284 cyc 样本，58M）

| 段 | 观察 |
|---|---|
| `sub sp,#0x110` + 6×`stp` callee-save | 帧 **0x110**。源码仍拼 13 字段 `NativeCall` 再喂 `stringPrimitiveIndexRead`（已内联进本符号） |
| 热路径 | `isString` 标检查 → 立即数下标 → code unit。`toStringCheckObject` 回落在冷址（`+0x264` / `+0x298`） |
| flatten | `bl StringRope.flatten` 热可见（档内例外） |
| P1 可退役 | **抽出 mid-29、禁止再拼 `NativeCall`**，削 0x110 帧 / spill。不是 58M 整包。预算 **<30M** |

### P1 vs P3 可退役（金丝雀）

| | 吃什么 | ≥30M？ |
|---|---|---|
| **P1 协议** | 7 参 cast/mov + Direct `NativeCall` 帧 | **否** |
| **P3 短路** | 金丝雀调用上整段 assume（含 168M 前言 + 48M sf/`blr`） | **可能**（f×318M）。f 未钉，必须探针 |
| P1 当刀 | — | **不开** |

---

## 4. 闭集审计（设计预判，P0 核实）

| record | `exec_direct` | pdfjs | v1 thin？ |
|---|---|---|---|
| `String.charCodeAt` | 是 | Direct 58M，热 | **热路径够格** |
| `String.fromCharCode` | 是 | Direct 16 + 体 69 | **否**（分配 + ToPrimitive） |
| `Function.prototype.apply` | 是 | ~0 | **否**（重入） |
| `Function.prototype.call` | 是 | 不进 NMFD | **否**（`forwards_call`） |
| `Function[@@hasInstance]` | 是 | 0 | **否** |

无第二条 thin-noalloc 员。P2 不挡 P3。

---

## 5. 验尺

| 尺 | 结果 |
|---|---|
| `zig build test-exec --seed 0` | **478/478**（taskset 0-4,8-14） |
| `git diff --check` | 过 |
| 几何 | NMFD **0x7b4** / 帧 **0xd0** / 墓碑 `cbnz`；assume **0x320** / **0x1c0**；`call_method` 未动 |
| `#32` | 单测 + RF `ldr [x5,#32]` 仍是 `exec_direct` |
| 行为 | 无人挂 `thin_leaf`；dispatch 不读该字段 |
| 未改 | `test262.conf` / reports / `tools/perf` / 岛 / 0x3f0 |

---

## 6. 下一步（等司机）

1. **P1 协议**（设计书原文）：inline `callThinLeafRecord` + `charCodeAt` 金丝雀。**不是刀。** 壳仍付 0x1c0。
2. 按 **B-R1**：P1 单独 FW 预期 <30M 时，开 **P1+P3 探针支**（不合入）量整层；大头在 P3 短路。
3. 不要用 dump (1) 的 CG 样本当 call count，不要用 Direct 58M 当 P1 预算。

原始：`/tmp/lanes/native-thin-p0/{stat,census,exclusive,z-cyc,z-br}.json` + `ann-cyc-{assume,nmfd,cca-direct}.txt`。
