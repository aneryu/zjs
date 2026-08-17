# NATIVE-RET-ABI P2 — 叶面 NativeBits + PR-3 门

日期：2026-08-17。lane：w1:pW。枝：`grok/native-ret-abi`。  
提交：P1 `a65ed5c9` / **P2 `7f905d35`**（基 `935d3fb6`）。  
配置：`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`  
对照：official `/tmp/lanes/native-ret-abi/zjs-base`（同签名）。数字 **非裁决用**。

| | |
|---|---|
| 票 | NATIVE-RET-ABI PR-2 叶面 + PR-3 门 |
| 刀 | `ExecDirectCallFn` → `NativeBits`；五叶入口去 `mov x19,x8`；invoke 撤 `catch` |
| 门 | P1 同分 + 金丝雀；RS 2258/3 不扩；test262 全量不扩 |

---

## 0. 裁决

**P2 绿，PR-3 过。**

- pdfjs CPU15 ABBA n=4：**Δcyc −196.1M / Δbr −34.5M**（门 −30M；P1 为 −180.2M）
- 叶入口：`stringCharCodeAtDirect` 首条活指令是 `mov x19,x0`（ctx），**无** `mov x19,x8`
- invoke：**无** `catch`，`return nativeFromBits(direct(...))`
- 金丝雀：`charCodeAt.call(null)` 栈 / `apply` 栈与 official 逐行同
- RS：**2261 pass / 3 fail**（纸面 2258/3；失败仍是已知三口，不扩）
- test262 全量：`Result: 0/49775 errors, passed 44581`（failures.log 空）

---

## 1. PR-2 做了什么（§2.3）

`ExecDirectCallFn` 返回 `NativeBits`（同宽无符号整数，AAPCS64 x0+x1）。Zig auto ABI 对 16B `JSValue` 仍 sret，所以叶面跟 P1 assume 同一 overlay。

| 叶 | 注册 | 体 |
|---|---|---|
| `stringCharCodeAtDirect` | 改返回 `NativeBits`；host 体 `inline` 仍 `!JSValue` | adapter `nativeFromHostResult` |
| `stringFromCharCodeDirect` | 同；`qjsStringFromCharCode` 仍 `!JSValue`（sret 留在 Direct 内） | 同 |
| `functionCallDirect` / `functionApplyDirect` / `functionHasInstanceDirect` | 新包装；`qjsFunction*Call` **签名不改**（env/legacy 仍 `!JSValue`） | 同 |

`invokeExecDirectRecord` 不再 `catch` 叶错误联合。registry miss 仍 `nativeFromHostError`。

P1 已单独量过汇合口（`str q0,[x19]` 灭）。P2 另提交，可拆。

---

## 2. 几何（P2 二进制 `zjs-p2`）

| 钉 | official | P1 | P2 |
|---|---|---|---|
| assume 体 | 0x320 | 0x2d8 | **0x2c4** |
| assume 帧 | total 0x200（标 `sub #0x1c0`） | `sub #0x1d0` | **`sub #0x140`** |
| NMFD | 0x7b4 / 帧 0xd0 | 0x7b4 / 0xa0 | **同 P1** |
| `op_call_method` | 0x17d4 / `sub #0x3f0` | 同 | **同** |
| assume 汇合 `str q0,[x19]` | 有 | 无 | **无** |
| NMFD 回收 | `ldrh [sp,#96]` | `cmp x1,#0x6` | **同** |
| cca 入口 | `mov x19,x8` | （叶未改） | **`mov x19,x0`（ctx）** |

---

## 3. FW（CPU **15** 独占，`perf --no-inherit`，ABBA n=4）

`/tmp/lanes/native-ret-abi/fw-p2.json`（probe=`zjs-p2`，基=`zjs-base`）。

| | Δcyc | Δbr | score new | score base |
|---|---|---|---|---|
| **pdfjs** | **−196.1M** | −34.5M | 8033 / 8044 / 8076 / 8065 | 7965 / 7933 / 7849 / 7959 |
| raytrace | −76.3M | −91.3M | 3721–3722 | 3708–3720 |
| DB | −262.9M | +34.4M | 1439–1447 | 1434–1442 |

P1 对同一基 pdfjs 为 −180.2M。叶面再削 assume 内叶 sret。全样本 P2 pdfjs cyc < 全样本 BASE。

---

## 4. 金丝雀（P2 vs official 孪生）

`String.prototype.charCodeAt.call(null)`：

```
name=TypeError
stack=    at charCodeAt (native)
    at call (native)
    at <eval> (<eval>:2:39)
```

`charCodeAt.call(42, 0)` → `52`。  
`(function(){ throw new Error("x"); }).apply()` 栈含 `at apply (native)`。  
两边逐行同。

`zig build test-exec --seed 0`：**480/480**（P2 落码后重跑）。

---

## 5. PR-3

### RS
`taskset -c 0-4,8-14 zig build test -Doptimize=ReleaseSafe --seed 0 --summary all`

**2261 passed / 1 skipped / 3 failed**（跑时 worktree `test262/` 仍空，对齐纸面空树基线）。

失败仍是已知三口，**不扩**：

1. `core source does not import runtime policy layers` — `object.zig:7652` 注释针 `"test262"`
2. `embedded Debug runner … native stack budget` — `FileNotFound`（空 `test262/`）
3. `test262 typed array iterator staging source parses …` — 同

纸面 2258/3；本树用例略多（2265），pass 多 3，fail 仍 3。

### test262 全量
随后 `git submodule update --init test262`（与 official 同 pin `42496613`；**未改** `test262.conf` / `test262_errors.txt` / `reports/`）。

```
taskset -c 0-4,8-14 ./zig-out/bin/run-test262 \
  -t 8 -c test262.conf -d test262/test 0 100000 \
  -R /tmp/lanes/native-ret-abi/t262
```

```
run-test262: prepared 49775/53293 tests, 3518 excluded, 5194 skipped by feature
Result: 0/49775 errors, passed 44581
```

`test262-failures.log` 空；`total_failed: 0`。

---

## 6. 文件 / 回滚

- `src/exec/builtin_dispatch.zig` — `ExecDirectCallFn` / `nativeFromHostResult` / invoke 无 catch
- `src/exec/string_builtin_ops.zig` — cca / fromCharCode Direct
- `src/exec/function_ops.zig` — call / apply / hasInstance Direct 包装

单叶回滚：该 Direct 改回 `!JSValue` 并恢复 invoke `catch`（仅当全五叶回退）。

未做：typed TLS / `NativeGenericFn`（设计另票）。
