# NATIVE-RET-ABI — 内部 native 链镜像 qjs 返回模型

日期：2026-08-17。lane：w1:pW。**设计先行，本票不落码。**  
pQ L1 更正：q 不是 nanbox uint64。64-bit QuickJS 本构建是 **16B `JSValue` 走 x0+x1**，失败用 `JS_EXCEPTION` 哨兵 tag；真正的 Error 在 `ctx` 上。z 壳 walk 把 107M `str q0 [x19]` 记成 tagged vs nanbox，**归因错**。真身 = Zig `HostError!JSValue` 错误联合（24B）逼 **sret**。

| | |
|---|---|
| 票 | NATIVE-RET-ABI（忠实刀，解封壳 walk 该行） |
| z RF | `/home/aneryu/zjs/zig-out/bin/zjs` official（NMFD **0x7b4** / 帧 **0xd0**，assume **0x320** / 帧 **0x1c0**） |
| 对照 | `/tmp/lanes/PDFJS-SHELL-UNITCOST.md` §B.16（解封）；qjs `quickjs.c:17562` / `JS_EXCEPTION` |
| 数字 | **非裁决用**。107M 是壳 walk 上 assume 汇合口份额 |
| 宪 | assume 帧 **不得涨过 0x1c0**；NMFD **0x7b4** 墓碑；`op_call_method` **0x3f0** |

---

## 0. 裁决（请批）

**内部 native 链（NMFD↔assume↔exec_direct 终端，随后叶）改返回裸 `JSValue`（AAPCS64：x0+x1）。失败 = `JSValue.exception()`（`Tag.exception`，已有 `value.zig:292`），Error 只在 throw 点 `throwValue` 挂到 `rt.current_exception`。**

这是对齐 qjs，不是新机制。`throwValue` **已经**返回 `JSValue.exception()`（`context.zig:1041–1048`）。链上却用 `!JSValue` 再包装一次，多出 sret。

**不**改：NMFD 自己对 handler 的 `!NativeFastDispatchResult`；construct 全量 env；TLS `nativeCall` 形参；`repr=tagged`。

---

## 1. ① 走链：谁在付 sret

official RF disasm（`/tmp/lanes/native-ret-abi/*.s`）。`HostError!JSValue` 布局：`[JSValue 16B | error u16 @+16]` = **24B** → 间接返回。

```
op_call_method  帧 0x3f0
  bl NMFD
    add x0, sp, #0x50          ; 24B sret 槽
    bl assume                  ; Zig 把 sret 放进 x0
    ldrh w23, [sp, #96]        ; sret+16 = error
    cbz  → 成功
  assume  帧 0x1c0
    mov x19, x0                ; 保存 NMFD 的 sret
    add x8, sp, #0x58          ; 叶的 24B sret（AAPCS x8）
    mov x0..x7, 7 参
    blr x12                    ; ExecDirectCallFn
    ldrh w22, [sp, #104]       ; 叶 sret+16
    cbz → ldur q0,[sp,#88] / b 汇合口
  汇合口 1439a50:
    ldr q0,[x8]; str q0,[x19]  ; 16B JSValue  → NMFD 槽   ★ 107M
    ldr x8,[x8,#16]; str x8,[x19,#16]
    ret
  叶 stringCharCodeAtDirect
    mov x19, x8                ; 再存一份 sret
    … 体 …
    str q0,[x19] / strh error
  叶 fromCharCodeDirect
    mov x19, x8
    add x0, sp, #8
    bl qjsStringFromCharCode   ; 第三跳 sret
    再 copy 回 x19
```

| 环 | 符号 | sret 方向 | 热 insn | 本环税 |
|---|---|---|---|---|
| **① NMFD → assume** | `nativeMethodFastDispatch` `12363a4` / `63c4` / `63c8` | x0 = `[sp,#0x50]` 24B | `add x0`; `bl`; `ldrh+cbz` | 槽 + 回收时读 error。assume 汇合口 **写回 x19 = 107M** |
| **② assume → 终端/叶** | assume `1439adc` `x8=[sp,#0x58]`；`blr x12` | AAPCS **x8** 24B | 7×mov + x8 + `ldrh+cbz` | 第二份 24B 槽；成功再 `ldur q0` 搬一次 |
| **③ 叶 → 更深 helper** | `fromCharCodeDirect`→`qjsStringFromCharCode` | 又一次 x0/x8 sret | 小 | 仅部分叶 |
| typed 臂 | `bl callTypedInternalRecordDirect` | 同 ② | 冷于金丝雀 | L1 后 pdfjs 几乎空 |

`callExecDirectRecord` / `invokeExecDirectRecord` **无独立符号**（inline 进 assume）。叶面 `stringCharCodeAtDirect` 入口 `mov x19,x8` 钉死 x8=sret。

qjs `js_call_c_function`：`blr` 之后 `x0+x1` 就是 `JSValue`，`return ret_val`（可为 `JS_EXCEPTION`）。**无 24B 槽、无第二份 copy。**

---

## 2. ② 设计

### 2.1 合同（对齐 qjs:294 `JS_EXCEPTION` / `JS_IsException`）

```zig
/// Native-chain return. 16B, AAPCS64 x0+x1. Failure iff tag==exception
/// and rt.current_exception is set (throwValue already does both).
pub const NativeValue = core.JSValue;

inline fn nativeOk(v: core.JSValue) NativeValue { return v; }
inline fn nativeExc() NativeValue { return core.JSValue.exception(); }

/// Debug/ReleaseSafe: isException() iff ctx.hasException().
inline fn nativeIsExc(ctx: *core.JSContext, v: NativeValue) bool {
    const exc = v.isException();
    std.debug.assert(exc == ctx.hasException());
    return exc;
}
```

Throw 点（已有 message helper 的继续用）：

```zig
return ctx.throwValue(try exception_ops.createNamedError(ctx, global, "TypeError", msg));
// throwValue 已：挂 current_exception + return JSValue.exception()
```

今日 `return error.TypeError` 且靠 `materializeRuntimeError` 补消息的路径：迁到 throw 点，或过渡期用

```zig
fn nativeFromHostError(ctx, global, err) NativeValue {
    materializeRuntimeError(ctx, global, err) catch {};
    return nativeExc();
}
```

只许留在 **叶/helper 边界**，不许再出现在 NMFD↔assume。

### 2.2 三环签名（P1，先链内）

| 函数 | 今日 | P1 |
|---|---|---|
| `callResolvedNativeMethodAssumeCFunction` | `HostError!JSValue`（x0=sret） | `NativeValue`（x0+x1） |
| `callInternalRecordDirectAssumeCFunction` | 同 | 同 |
| `callExecDirectRecord` / `invokeExecDirectRecord` | `HostError!JSValue` | `NativeValue`；叶仍 `!JSValue` 时 **只在 invoke 里** `catch nativeFromHostError` |
| NMFD 对 assume 的接收 | `ldrh [sp,#96]; cbz` | `result.isException()` → `handleCatchableRuntimeError(..., error.JSException)`（`exceptions.zig:63` 已有；`tryCatchInFrame` 已认 pending） |
| `callResolvedExecDirect` / DINM / `InRealm` | `!JSValue` | P1 一并改接收，避免第三套 ABI |

`ExecDirectCallFn` **P1 暂不改**（叶面 P2）。invoke 仍 `blr` 旧 sret 叶，但 assume **不再**把 24B 写进 NMFD。

P1 热路径：

```
NMFD:
  result = assume(...)          ; x0+x1
  if (result.isException()) { pop; handleCatchable(JSException); ... }
  pop; push result

assume:
  preflight; realm
  v = invokeExecDirect(...)     ; P1 仍可能内部 sret 一次
  if (v.isException()) { sf pop; return v }   ; 不再 materialize
  sf pop; return v              ; ret 直接 x0+x1，无 str q0 [x19]
```

**杀掉的就是汇合口 `str q0,[x19]` + `str x8,[x19,#16]`（107M）。**

### 2.3 叶面（P2）

```zig
pub const ExecDirectCallFn = *const fn (...) NativeValue;
```

`stringCharCodeAtDirect` / `fromCharCodeDirect` / apply / hasInstance / call：入口不再 `mov x19,x8`，成功 `x0+x1`，失败先 `throw*` 再 `return exception()`。

`qjsStringFromCharCode` 若仍 `!JSValue`，Direct 里一次 adapter，不把 sret 传出 assume。

TLS `NativeGenericFn` / `callTypedInternalRecordDirect` **P2 不动**（L1 后 pdfjs 热臂空）。另票。

### 2.4 不改的面

- `throwValue` / `Tag.exception` / `hasException` — 已是 q 形
- construct `callConstructRecordImpl` 的 env（可后跟同一 NativeValue，不堵 P1）
- `forwards_call` miss NMFD
- 岛 / leftover / 254/255

### 2.5 几何

| 钉 | P1 预期 | 守法 |
|---|---|---|
| assume 帧 0x1c0 | **应缩**（少 sret 目的寄存器 + 24B 槽） | **禁止涨**。缩了 **不**灌回 NMFD |
| NMFD 0x7b4 | 少 `[sp,#0x50]` 槽，体可能缩 | 墓碑 `.space` 重算垫回 0x7b4 |
| NMFD 帧 0xd0 | 可能微缩 | 不要求；0x3f0 不涨 |
| `op_call_method` 0x3f0 | 不传新活指针 | 禁 rec 跨 bl |

P1 若 assume 帧涨：立刻停，查是否把 `isException` 物化/Error copy 拉进热 prologue。

---

## 3. 分期

| PR | 做 | 验 | 回滚 |
|---|---|---|---|
| **PR-0** | `NativeValue` 别名 + `nativeOk/Exc/IsExc` + Debug 断言。零接线 | test-exec | 删辅助 |
| **PR-1 链内三环** | assume / AssumeCFunction / ExecDirect 终端 / NMFD 接收改 NativeValue。叶仍 `!JSValue`，invoke 适配 | pdfjs cyc+br **≥30M**；raytrace + **DB** 哨；`test-exec`；几何三钉；`git diff --check` | assume 改回 `!JSValue` |
| **PR-2 叶面** | `ExecDirectCallFn` + 现闭集五叶（charCodeAt/fromCharCode/apply/call/hasInstance） | 同分 + 金丝雀 `Error.stack` / 非 string `this` 孪生 | 单叶改回 adapter |
| **PR-3** | RS + **test262 全量**（driver 尺）。P1 过且几何稳才跑全量 | 基线 2258/3 不扩 | — |

禁止 P1+P2 捆一发（要能单独量 107M 汇合口是否消失）。

---

## 4. ④ 验尺

| 尺 | 钉 |
|---|---|
| pdfjs | CPU **15**，独占，`--no-children`，ABBA。**Δcyc ≤ −30M** 才承认刀立。编 `taskset -c 0-4,8-14` |
| 符号账 | assume 汇合口 `str q0 [x19]` 应从热路径消失；NMFD 无 `ldrh [sp,#96]` |
| 哨 | raytrace、**DB**（动返回 ABI / call 几何） |
| 单元 | `zig build test-exec --seed 0` |
| 几何 | assume 帧 ≤0x1c0；NMFD 0x7b4；`call_method` 0x3f0 |
| RS | 2258 pass / 3 fail 基线不扩 |
| test262 | PR-3 全量，**不改** `test262.conf` |
| 夹具 | 叶 TypeError（非 string `charCodeAt`）栈上仍有 native 帧；`throwValue` 后 `isException()==hasException()` |

---

## 5. 风险

| 风险 | 严重 | 缓解 |
|---|---|---|
| throw 点漏 materialize → `exception` tag 无 pending | 致命 | Debug `nativeIsExc`；裸 `return error.*` 在 P1 链上编译期扫（只许 adapter） |
| Interrupt / uncatchable | 高 | 照抄今日 `materializeRuntimeError` 对 `Interrupted` 的短接（`builtin_dispatch.zig` 现注释） |
| assume 帧涨 | 致命 | 几何门；涨则停 |
| `isException` 热路径多一条 tag 比 | 中 | 对位 q `JS_IsException`；替换今日 `ldrh+cbz`，不是新税 |
| 叶仍 sret（P1） | 中 | 故意。P2 再削。P1 只吃 107M 汇合口 |
| probe 枝 thin 路径 | — | **本刀对着 official/main**，不带 thin 短路 |

---

## 6. Alternatives

| | 为何否 |
|---|---|
| 只改 assume 为 `extern` C ABI、叶不动也不改终端 | 叶仍 x8 sret，assume 仍要搬 24B，汇合口还在 |
| 全引擎废除 `HostError!JSValue` | 范围爆炸（parser/GC/绑定）。本刀只 native **热链** |
| 把 Error 码塞进 exception payload、不挂 `current_exception` | 不齐 q；`tryCatchInFrame` 已认 pending |

---

## References

- official：NMFD `@1236140` `add x0,sp,#0x50` / `bl assume` / `ldrh [sp,#96]`；assume `@14399b8` `mov x19,x0` / `add x8,sp,#0x58` / `blr` / 汇合 `str q0,[x19]`
- `src/core/value.zig:292` `exception()`；`:352` `isException`；`Tag.exception=6`
- `src/core/context.zig:1041` `throwValue` → 已返回 `exception()`
- `src/exec/exceptions.zig:63` `JSException`
- qjs `JS_EXCEPTION` / `JS_IsException`；`js_call_c_function` 17563–17689
- 解封：`PDFJS-SHELL-UNITCOST.md` 行「sret / tagged vs nanbox」
