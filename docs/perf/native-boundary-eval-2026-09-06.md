# JS↔native 边界测评与方案（v0.1，2026-09-06，driver；待 owner 裁决）

owner 目标：**最大程度优化 JS↔native 的性能**。本稿分三部分：测评方法与
读数、归因（四条根因）、方案（按收益 × 确定性 / 成本排序）。所有读数
都是每次穿越的 insn / cycles（中位数，ABBA，CPU 19，host lock），证据
在 `reports/evidence/NATIVE-BOUNDARY/`，语料与采样器在
`tools/perf/native_boundary/`。

## 1. 测评

### 1.1 两套语料

**A. 跨引擎（builtin 形态）**：五引擎都只能通过 builtin 暴露 native，
所以用 builtin 调用给边界定价。每例 = `main` 内一个局部循环 + 一种形态，
减去 `ctrl`（`s += i` 的循环骨架）再除以 N 得到每次穿越的成本；C 组
（native → JS 回调）再除以每轮回调次数。

**B. 嵌入面（fun 的真实形态）**：`zjs-boundary-bench`（Zig，走公开
embedding API）对 `qjs-boundary-bench`（C，走 QuickJS C API），同一段
JS 循环：

| case | zjs 路径 | qjs 路径 |
|---|---|---|
| builtin | `abs(i)`（`Math.abs` 提升为局部） | 同 |
| host2 | `host_add(i, 1)`，`defineGlobalFunction` 注册的 2 参 host 函数 | `JS_NewCFunction` |
| host0 | `host_noop()`，0 参 host 函数 | 同 |
| hostm2 | **同一个 host 函数作为方法调用 `host.add(i, 1)`** | （未做） |
| plugin2 | `plugin.add(i, 1)`，走已弃用的 runtime plugin ABI（`Plugin.load` + `CallFrame` trampoline） | — |
| n2j1 | 宿主循环里 `JSContext.callFunction(cb, [i])`，cb = `function (x) { return x + 1 }` | `JS_Call` |
| n2j0 | 同上，0 参、空函数 | 同 |

### 1.2 读数 A：跨引擎，每次穿越 insn / cycles

| case | zjs | qjs | Hermes | V8 jitless | JSC jitless | qjs/zjs cyc | Hermes/zjs | V8/zjs |
|---|---|---|---|---|---|---:|---:|---:|
| N1 `abs(i)` 提升后自由调用 | 359 / 72 | 122 / 27 | 165 / 23 | 110 / 20 | 196 / 37 | **0.37** | 0.33 | 0.27 |
| N1m `Math.abs(i)` 方法形 | 377 / 79 | 194 / 50 | 227 / 40 | 214 / 34 | 305 / 56 | 0.63 | 0.50 | 0.43 |
| N2 `max(i,1,2)` 变参 | 535 / 109 | 180 / 34 | 332 / 49 | 259 / 37 | 280 / 49 | **0.31** | 0.44 | 0.34 |
| N3 `str.charCodeAt(i&7)` | 398 / 68 | 352 / 56 | 520 / 76 | 288 / 41 | 295 / 52 | 0.83 | 1.12 | 0.60 |
| N4 `o.hasOwnProperty("k")` | 771 / 149 | 613 / 98 | 573 / 82 | 305 / 42 | 316 / 58 | 0.66 | 0.55 | 0.28 |
| N5 `a.push(i); a.pop()` | 439 / 87 | 518 / 83 | 270 / 43 | 460 / 76 | 264 / 49 | 0.95 | 0.49 | 0.87 |
| N6 `f.call(null, i)` | 737 / 112 | 412 / 81 | 84 / 13 | 395 / 64 | 314 / 58 | 0.72 | **0.12** | 0.57 |
| N7 `f.apply(null, args)` | 1241 / 233 | 850 / 136 | 995 / 180 | 658 / 97 | 861 / 145 | 0.58 | 0.77 | 0.42 |
| C1 forEach 回调 | 667 / 122 | 523 / 69 | 572 / 100 | 473 / 81 | 968 / 152 | 0.56 | 0.83 | 0.67 |
| C2 reduce 回调 | 874 / 168 | 498 / 67 | 539 / 93 | 316 / 55 | 888 / 141 | **0.40** | 0.55 | 0.32 |
| C3 map 回调 | 1125 / 216 | 1046 / 148 | 607 / 107 | 354 / 56 | 981 / 174 | 0.68 | 0.49 | 0.26 |
| C4 sort 比较器 | 1176 / 272 | 583 / 78 | 1091 / 179 | 415 / 65 | 242 / 43 | **0.29** | 0.66 | 0.24 |
| C5 replace 回调 | 10529 / 2491 | 8122 / 1300 | 6104 / 1225 | 2545 / 468 | 3059 / 652 | 0.52 | 0.49 | 0.19 |

### 1.3 读数 B：嵌入面，每次穿越 insn / cycles

| case | zjs | qjs (C API) | qjs/zjs cyc |
|---|---|---|---:|
| builtin | 362 / 71 | 96 / 21 | 0.30 |
| host2 | 475 / 90 | 165 / 35 | 0.39 |
| host0 | 483 / 85 | 88 / 23 | 0.27 |
| **hostm2**（host 函数作方法） | **4087 / 593** | — | ≈ **0.06**（对 qjs host2） |
| plugin2（弃用 plugin ABI） | 4244 / 625 | — | — |
| **n2j1**（宿主 → JS） | **1556 / 392** | 291 / 48 | **0.12** |
| n2j0 | 1417 / 344 | 185 / 29 | 0.08 |

读法：zjs 整体与 qjs 持平（Octane 0.97），但**边界是 zjs 最弱的一层**。
JS → native 叶调用 2.5–3.7×、native → JS 回调 1.5–2.5×、**宿主注册的
函数作方法调用 17×、宿主发起的 JS 回调 8×**。fun 的 GUI 事件 → JS
handler、JS → 插件 API 正是后两种形态。

## 2. 归因（perf record，instructions 份额 → 每次穿越 insn）

### R1. 自由调用形 `f(...)` 的 opcode 没有 native 臂

`op_call` / `opCall`（`tailcall_dispatch.zig:1489`）只认 bytecode 目标；
native 目标 miss 后走 `execCall` → `callValueOrBytecodeDispatchAfterInterruptPoll`
→ `callNativeCallableObject` → `callTypedInternalRecordDirect` 四层
（`call_runtime.zig:78 / 1079 / 1017`、`builtin_dispatch.zig:688`）。N1 的
359 insn 里这四层占 62%；host2 / host0 同构（`execCall` +
`callNativeCallableObject` + `callHostFunction` + `hostCallExternalHostFunction`
占 68%）。`op_call_method` 有 native 臂（`tailcall_dispatch.zig:1798`），
所以 N1m 方法形（79 cyc）反而比 N1 自由形（72 cyc 但 insn 更多、qjs 差距
更大）路径短——qjs 两种形态都是 `js_call_c_function` 一层（27 / 50 cyc）。

### R2. 宿主函数是第三种 ABI，对快路径不可见；作方法调用时走**按名字匹配链**

宿主/插件函数注册为 `external_host`（`core/host_function.zig:25`），调用
约定 `ExternalCallFn = fn(ptr, ExternalCall) anyerror!JSValue`（最宽的
错误联合）；它不在 internal record 表里，`op_call_method` 的 native 臂
（`resolvedNativeMethodRecordAssumeCFunction`）miss，落到
`vm_call.callMethod`（`vm_call.zig:678`）：`fastNativeMethodCall` miss →
**`array_ops.arrayMethodFastCall` 逐个用 `nativeFunctionNameForVmEquals`
比较函数名（at / reduce / slice / splice / push / pop / shift / … 数十个）**
→ 最后 `callValueOrBytecodeRootPreRootedAfterInterruptPoll`。hostm2 的
4087 insn 里 `nativeFunctionNameForVmBorrowed` 19%、`mem.eqlBytes` 5%、
`array_ops.*Call` 合计 ~30%。plugin2 在此之上再加一层 C ABI `CallFrame`
trampoline（`InstalledBinding.call`，`runtime/plugin.zig:271`）。

这是缺陷级问题：**任何以 `obj.method()` 形式暴露的宿主 API，每次调用都
付几十次字符串比较**。

### R3. 宿主发起的 native → JS 走全新 Machine

`JSContext.callFunction` → `callValueOrBytecodeRoot` → `callFunctionObjectBytecode`
→ `runWithArgsState`（`zjs_vm.zig:402`）：每次新建 frame arena mark、
`Frame`、`Machine`、根 `MachineBacktraceView` + `ActiveBacktraceFrame`、
`ActiveInvocation`，再进 `runTC`。n2j1 的 1556 insn：
`runWithCallEnvAfterInterruptPoll` 28%、`initFreshEntryFrame` 12%、
`callFunctionBytecodeModeState…` 10%、`Machine.deinit` 2.5%、
`FrameSlab.carve` 2.4%。qjs `JS_Call` = `JS_CallInternal` 一次 291 insn。

引擎内 builtin → 回调走的是另一条路（`SyncInternalCallSite`，同一
Machine 上 push Entry、`.native_boundary` 返回，无 C 栈递归，
`call_runtime.zig:614 / 697`），好得多但仍 2×：C2 每回调 168 cyc，
其中 `SyncInternalCallSite.call` 31%、`runTC` 入口 20%、
`op_return_slow` 8% 的 insn。

### R4. ABI 1 的每次调用固定税

builtin 主 ABI 返回 `HostError!JSValue`（24 B sret），调用前后有
`ValueRootFrame` activate/deactivate（`builtin_dispatch.zig:712-718`，因为
`setTopPtr(sp)` 把参数窗口弹到栈顶之上，tracing GC 看不到它们）、
`NativeBacktraceScope`、`NativeCallEnvironment` 存取、interrupt poll、
realm 切换、栈预检。对照：只有 6 个 builtin 走 ABI 2（`exec_direct`，
`NativeBits` x0+x1 返回，无 env、无 root frame）——它们正是表里最接近
qjs 的：`charCodeAt` 68 vs 56、`push/pop` 87 vs 83。

（C4 sort 的 272 cyc 另有 `stableArraySortEntries` 每次分配
ArrayList + HashMap + `SmpAllocator.alloc` 的账，属排序实现，不属边界，
单列。）

## 3. 方案（最佳路径）

原则沿用 FNABI §5.2 规则 1「JSValue 为跨界通货、零 marshaling」和
§3.1「builtin 与 plugin 同一种 NativeEntry、同一种 handler、热路径不读
descriptor」。**核心一句话：让宿主函数成为与 builtin 完全同一种函数
对象，然后把 builtin 的快路径做到 qjs 水平。**

| # | 工作 | 机制 | 预期（每次穿越 cyc） | 成本 | 确定性 |
|---|---|---|---|---|---|
| **P1** | **宿主/插件函数统一为 `c_function` + record**（FNABI §10 NativeEntry 的最小落地） | `createExternalFunction` / plugin install 产出的对象带 `InternalRecord` 等价物（call kind + target + state），`op_call_method` 的 native 臂直接命中；`arrayMethodFastCall` 改为按 record 身份判定，**删除按名字匹配链** | hostm2 593 → ~90（host2 水平）；plugin2 同 | 3–5 人日 | **高**：builtin 已在走这条路 |
| **P2** | **`op_call` / `opCall` 加 native 臂** | 镜像 `op_call_method:1798` 的 c_function 臂（resolve record → NMFD），`f()` 形不再经 `execCall` 四层 | N1 72 → ~50；host2 90 → ~55；host0 85 → ~40 | 1–2 人日 | 高 |
| **P3** | **ABI 2 成为默认 native 约定 + 固定元数入口** | = FNABI §14.4 Managed Fixed Entry / §14.1 Leaf Static Entry：`fn0..fn4(ctx, this, a0..a3) NativeBits`，参数进寄存器、无 args slice；调用期间**不把参数窗口弹出栈顶**（qjs 做法），从而不需要 `ValueRootFrame`；leaf 声明 = 无 env / 无 backtrace scope；`HostError!JSValue` 只留给冷路径 | builtin N1m 79 → ~55、N2 109 → ~45；host ~55 → ~40（qjs 35） | 3–5 人日基建 + builtin 逐族迁移 | 中高：6 个 exec_direct 已证形态 |
| **P4** | **宿主 → JS 常驻再入** | `JSContext.CallSite.init(cb)` + `.call(args)`：缓存目标解析（同 `SyncInternalCallSite`），宿主线程持一个常驻 `Machine` / 根 invocation，回调只 push Entry + `.native_boundary` 返回，不再每次建 Frame/Machine/backtrace；同时给 `SyncInternalCallSite.call` + `runTC` 入口 + `op_return_slow` 做 insn 级修剪 | n2j1 392 → ~90；C2 回调 168 → ~100（qjs 48 / 67） | 5–8 人日 | 中：`.native_boundary` 机制已有，缺的是宿主侧的常驻根 |
| P5 | typed leaf 解包（i32/f64 直传）+ 批量 API | FNABI §14.1、§15 marshal policy | 叶调用再省 10–20 cyc；批量把 N 次穿越变 1 次 | P1–P3 之后 | 中 |

执行序：**P1 → P2 → P3 → P4**。P1 是缺陷修复级的收益（17× → 2.5×），
P2 一两天，P3 是 builtin 与 host 共享的地基，P4 解 fun 事件回调。
P1+P2 之后 fun 的两种主形态（JS → 插件方法、宿主 → JS handler）分别
到 ~90 / 392 cyc；P3+P4 之后到 ~40 / ~90，即 qjs 的 1.1–1.9×。

**尺**：`tools/perf/native_boundary` 两套语料进 refactor gate；验收线 =
每例 cycles ≤ 1.1× qjs（B 套用 C API 对照），Hermes / V8-jitless 只作
上界参考（N6 `f.call` Hermes 13 cyc 是编译器把 `.call` 直接降成调用，
不是边界机制）。

**不做**：先建 FNABI 全套 descriptor / loader / capability 机制再谈性能
（热路径不读它们，先把 NativeEntry 与三条快路径做对）；不引入 FunValue
（规则 1）；sort 的分配账另立项。

## 4. 复现

```
zig build zjs -Doptimize=ReleaseFast
zig build perf-native-boundary-build -Doptimize=ReleaseFast     # zjs-boundary-bench + plugin fixture
cc -O2 -I$HOME/quickjs -o /tmp/qjs-boundary-bench tools/perf/native_boundary/qjs_boundary_bench.c $HOME/quickjs/libquickjs.a -lm -lpthread
flock -x /tmp/zjs-host-heavy.lock python3 tools/perf/native_boundary/sample.py --samples 4 --cpu 19 --out nb.csv \
  zjs=zig-out/bin/zjs qjs=$HOME/quickjs/qjs hermes=... "v8=... --jitless" "jsc=... --useJIT=false"
python3 tools/perf/native_boundary/sample.py --report nb.csv
flock -x /tmp/zjs-host-heavy.lock python3 tools/perf/native_boundary/sample_embed.py --samples 4 --cpu 19 --out embed.csv \
  --zjs zig-out/bin/zjs-boundary-bench --qjs /tmp/qjs-boundary-bench --plugin zig-out/lib/libzjs-runtime-plugin-fixture.so
python3 tools/perf/native_boundary/sample_embed.py --report embed.csv
```
zjs `a30170700f…`（main `bbb3f454` ReleaseFast，fresh cache），qjs GCC-16
尺 `5e965b35…`，Hermes / d8 / jsc 与五引擎快照同二进制。

## 6. 实施结果（2026-09-06 下午，P1–P4 + 两条并行 lane，未 commit）

owner 裁决「重点优化这部分」后当日落地。门：`zig build test` 24/24、
`mise run batch-gate`（merge-gate 70/70，含 test262 / stress / gc-stress /
smoke / architecture）全绿。证据：`reports/evidence/NATIVE-BOUNDARY/
*-after-p1p4-2026-09-06.csv`，同协议（ABBA 4 样本、CPU 19、host lock）。

### 6.1 读数：每次穿越 cycles（insn），前 → 后，qjs 对照

| case | 前 | 后 | qjs | 后/qjs |
|---|---:|---:|---:|---:|
| `abs(i)` 自由调用 | 72 (359) | **33 (219)** | 26 | 1.27 |
| `Math.abs(i)` 方法形 | 79 (377) | 61 (302) | 49 | 1.24 |
| `max(i,1,2)` 变参 | 109 (535) | **29 (207)** | 34 | 0.85 |
| `charCodeAt` | 68 | 64 | 56 | 1.14 |
| `hasOwnProperty("k")` | 149 (771) | **83 (469)** | 99 | 0.84 |
| `push/pop` | 87 | 78 | 83 | 0.94 |
| `f.call(null,i)` | 112 | 114 | 81 | 1.41 |
| `f.apply(null,args)` | 233 | 227 | 136 | 1.67 |
| forEach 回调 | 122 | 114 | 69 | 1.65 |
| reduce 回调 | 168 | 159 | 67 | 2.37 |
| map 回调 | 216 | 204 | 148 | 1.38 |
| sort 比较器 | 272 | **140** | 78 | 1.79 |
| 宿主 `host_add(i,1)` | 90 (475) | **56 (319)** | 35 | 1.60 |
| 宿主 `host_noop()` | 85 (483) | **54 (294)** | 22 | 2.45 |
| **宿主函数作方法 `host.add(i,1)`** | **593 (4087)** | **78 (395)** | ≈35 | 2.2 |
| 弃用 plugin ABI `plugin.add(i,1)` | 625 (4244) | **118 (553)** | — | — |
| **宿主 → JS `callFunction(cb,[i])`** | **392 (1556)** | **137 (614)** | 48 | 2.85 |
| 宿主 → JS 0 参 | 344 (1417) | **120 (555)** | 28 | 4.3 |

fun 的两种主形态：JS → 插件方法 17× → 2.2×，宿主 → JS handler 8× → 2.9×。

### 6.2 落地的机制（按方案编号）

- **P1** `src/exec/builtin_dispatch.zig`：`external_host_record`——所有宿主/插件函数共享的一条 `InternalRecord`（exec_direct 蹦床 `externalHostDirect` 从函数对象的 external id 取注册表项，`throwExternalHostError` 迁到此处）；`Object.installExternalHostFunction(rt, id)` 统一六处写入点（context/binding/plugin/promise_ops/auto-init/tests helper），记录挂到 `call_cache`，`op_call_method` 的 native 臂直接命中，名字匹配链再也不会被宿主函数走到。`JSRuntime.external_host_record` 由 standard_globals 注册。ExecDirect ABI 增加 `func_obj: ?*Object` 参数（7 个已有 direct 实现同步）。
- **P2** `tailcall_dispatch.zig` `opCall`：一次 unpack 后按 class 分支（bytecode → inline resolver，`c_function` → `vm_call.nativePlainFastDispatch`），`f()` 形不再经 execCall 四层。
- **P3** `builtin_dispatch.callRecordFromVm / callRecordFromVmInRealm`：VM 侧 native 调用核心合成一层（预检不用 checked mul、`nativeCallTarget` 一次取 record+realm、backtrace 帧直接 push、无 ValueRootFrame——操作数窗口本就是 `traceStack` 的根、结果只转一次 NativeBits）；两个 dispatcher（NMFD / plain）改为 inline tick + 外联慢腿 `pollInterruptSlowLeg` + 外联 `nativeDispatchFailure`。typed cproto switch 抽成 `dispatchTypedRecord` 供两条终端共用。
- **P4** 新文件 `src/exec/host_invocation.zig`：runtime 常驻的 `HostInvocation`（Machine + 惰性 L0 + 根 backtrace view + ActiveInvocation），**只在一次调用期间发布**为 `rt.active_invocation`；`call_runtime.callFromHost` 用与 builtin 回调同一条 `.native_boundary` 路径进入被调函数；`JSContext.callFunction` 先走它，不合格再回根路径；runtime `deinit` 经 `host_invocation_retire` 回收（`Machine.deinitStorage(rt)` 不经已销毁的 ctx）。`popAndResume` 增加 native-boundary 返回臂（不再绕 `op_return_slow`）。
- **Lane D**（并行子代理）：`Math.min/max`、`Object.prototype.hasOwnProperty` 的 exec_direct 快臂（`math_ops.zig`、`object_builtin_ops.zig`、`property_ops.propertyKeyAtomIfReady`）。
- **Lane C**（并行子代理）：`array_ops.zig` sort 比较器路径——临时数组走 `vm_stack` scratch、dense 数组直接读写 fast-array 槽、比较器结果 int32 直判、ping-pong merge；原 profile 里的 HashMap 是 gc_address_registry 的 slab arena 抖动，不是 sort 的数据结构。

### 6.3 还欠的

| 项 | 现状 | 下一刀 |
|---|---|---|
| 宿主 → JS 2.9× | `callFunction` 244 insn（路由解析 ~25、boundary scope + push ~80）+ `runTC` 序言 84（每次构造 `Vm`）+ 返回 ~50 | 嵌入侧 `CallSite` 缓存目标解析；`Vm` 序言瘦身；这两项对 builtin 回调（2.4×）同样有效 |
| 宿主函数 1.6× | `callExternalHostRecord` 45 + `ExternalCall` 按值传 56 B + `anyerror!JSValue` sret | FNABI §14.4 固定元数入口（`fn0..fn4`，JSValue 进寄存器，NativeBits 返回）作为新公开 API；旧 API 保留 |
| ExecDirect 10 个寄存器参数 | this_value + slice + caller 双指针溢出到栈 | 收成 (ctx, func_obj, this, args, *CallerRef) 7 寄存器 |
| `f.call` / `f.apply` 1.4–1.7× | 转发臂 + `setupFallbackInlineEntry` + `op_return_slow` | 单独立项 |
| builtin ABI 1 家族 | 典型 +70~95 insn（env + typed switch + f_f 的 numberToValue） | 按频次逐族迁到 exec_direct |
| Octane 回归读数 | 未跑（batch-gate 的 fixed-work smoke 通过） | `mise run perf-screen` |
