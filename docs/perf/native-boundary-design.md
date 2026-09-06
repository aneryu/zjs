# JS↔native 边界整体设计（NB2，v0.1，2026-09-06，driver；待 owner 裁决）

owner 指令：「继续优化 native boundary，但不应该小修，应该整体设计一下，
要是所有 JS 引擎中最好的」；「fun 的调用完整按照我们的方式来，不要作为
约束，只需要设计好接口」。

本稿是**整体设计**，不是补丁清单：先定义「最好」的可测含义（§0），把五个
引擎的边界机制按形态拆开对照（§1），从中提炼出 zjs 该走的原则（§2），
然后给出对象模型、机器 ABI、VM 侧路径、再入路径、宿主对象、公开接口的
函数级规格（§3–§9），最后是删除清单、与既有契约的对账、验收尺、分阶段
计划和待裁决项（§10–§14）。落地规格到函数与字段粒度，派发前不再需要
第二份设计。

前置文档：`native-boundary-eval-2026-09-06.md`（测评 + P1–P4 已落地，
本稿 §附录 A 引用其 §6.1 读数作为起点）、`fun-native-plugin-design.md`
（FNABI v0.8，本稿 §11 列出偏离项）、`vm-value-representation-contract.md`
v3（JSValue 16 B、非搬移、保守扫描为生产设计）、`hermes-parity-plan.md`
（W1 属性缓存，本稿 §8 依赖它）。

---

## 0. 「最好」的定义与目标读数

「所有 JS 引擎中最好」在解释器引擎上有可测的含义：**JS → native 与
native → JS 两个方向、每一种穿越形态的每次穿越成本（cycles，减去循环骨架）不高于 qjs / Hermes / V8-jitless /
JSC-jitless 四者中的最小值**，并且提供三种任何解释器都没有的形态：
解释器内的类型化叶调用（V8 Fast API 只在优化编译器里有）、宿主侧缓存
调用点（JSC `CachedCall` 只对引擎内部开放）、属性缓存里的原生访问器
（JSC `CustomGetterSetter` 有，但 qjs / Hermes 没有）。

目标表（每次穿越 cycles；「现」= P1–P4 后的 09-06 读数；「最佳对手」=
四引擎最小值；「解释器目标」= 本设计的工程估算，§4/§5 给出指令级推导，
验收时以实测替换；「JIT 目标」= §15 预留结构下 baseline JIT 内联快臂后的
估算，对手列同为 JIT 引擎的 jitless 读数，因为**双向都要最大性能：JIT
之后边界仍是同一套 `NativeEntry`/`CallSite`，只是发射方式变了**）：

**方向一：JS → native**

| 形态 | 现 | 最佳对手 | 解释器目标 | JIT 目标 | 机制 |
|---|---:|---:|---:|---:|---|
| `abs(i)` 自由调用（builtin 叶） | 33 | 20 (V8) | **≤ 18** | ≤ 8 | K1 叶：tag 检查 + 直接 C 调用 + 装箱；JIT 内联 tag 检查与装箱、`blr target` |
| `Math.abs(i)` 方法形 | 61 | 34 (V8) | **≤ 30** | ≤ 10 | 同上 + 方法臂；JIT 经 IC 省属性查找 |
| `max(i,1,2)` 变参 | 29 | 34 (qjs) | ≤ 25 | ≤ 15 | K0 managed，argv 就地 |
| `charCodeAt` | 64 | 41 (V8) | ≤ 40 | ≤ 15 | K2 方法叶（self=string） |
| `hasOwnProperty("k")` | 83 | 42 (V8) | ≤ 60 | ≤ 40 | K0；属性查找占大头，边界外 |
| `push/pop` | 78 | 43 (Hermes) | ≤ 50 | ≤ 30 | K0 exec-direct 形 |
| `f.call(null,i)` | 114 | 64 (V8) | ≤ 60 | ≤ 30 | 转发臂重做（§5.4） |
| `f.apply(null,args)` | 227 | 97 (V8) | ≤ 100 | ≤ 60 | 同上 |
| 宿主 `host_add(i,1)`（managed） | 56 | 35 (qjs) | **≤ 30** | ≤ 20 | K0 |
| 宿主 `host_add(i,1)`（typed 叶） | — | 无对手 | **≤ 15** | **≤ 6** | K1；JIT = guard + 2 次拆箱 + `blr` + 装箱 |
| 宿主 `host_noop()` | 54 | 22 (qjs) | ≤ 20 / 叶 ≤ 10 | ≤ 5 | K0 / K1 |
| 宿主函数作方法 `host.add(i,1)` | 78 | ≈35 (qjs) | ≤ 35 / 叶 ≤ 20 | ≤ 8 | 与自由调用同一条臂 |
| `world.step(dt)`（原生对象方法，typed） | 无 | 无对手（JSC DOMJIT 仅 JIT） | **≤ 20** | **≤ 8** | K2：固定偏移 unwrap + 叶 |
| `world.time`（原生 getter） | 无 | 无对手 | ≤ get_field 缓存命中 + 10 | ≤ 6 | Slot kind `native_accessor` + IC 臂（§8）；JIT 照抄 JSC `CustomAccessorGetter` 序列 |

**方向二：native → JS**

| 形态 | 现 | 最佳对手 | 解释器目标 | JIT 目标 | 机制 |
|---|---:|---:|---:|---:|---|
| 宿主 → JS `callFunction(cb,[i])` | 137 | 48 (qjs) | **≤ 40** | ≤ 25 | CallSite + 常驻 Vm（§6）；JIT 臂 = 压 Entry + `blr code` |
| 宿主 → JS 0 参 | 120 | 28 (qjs) | ≤ 30 | ≤ 20 | 同上 |
| forEach 回调 | 114 | 69 (qjs) | **≤ 60** | ≤ 25 | 常驻 `Vm` + CallSite（§6） |
| reduce 回调 | 159 | 55 (V8) | **≤ 60** | ≤ 25 | 同上 |
| map 回调 | 204 | 56 (V8) | ≤ 90 | ≤ 35 | 同上 + 结果写回 |
| sort 比较器 | 140 | 65 (V8) | ≤ 70 | ≤ 30 | 同上 |
| replace 回调（每次匹配） | 2491 | 468 (V8) | ≤ 900 | ≤ 500 | CallSite 缓存 + 匹配数组构造走 vm_stack scratch（正则引擎本身另账） |

「解释器目标」列是未 quicken 路径；§5.5 的调用点 quickening 落地后叶
调用再降到 12–14、managed 到 ~20（D2 复议）。

读数尺：`tools/perf/native_boundary` 两套语料（§12 扩充），ABBA、CPU 19、
host lock，与 09-06 协议一致。

---

## 1. 五引擎机制对照（证据）

按形态拆开看，没有一个引擎在所有形态上都最好；每种形态的赢家和赢法：

### 1.1 JS → native：宿主函数签名与参数到达方式

| 引擎 | 签名 | 参数如何到达 | 每次调用固定税 |
|---|---|---|---|
| QuickJS | 13 种 `cproto`（generic / magic / f_f / f_f_f / getter / setter / …），`JSValue f(ctx, this_val, argc, argv)` | `argv` 直接指向调用者操作数栈（`OP_call` 不拷贝，`quickjs.c:18182-18202`）；`argc < length` 时 `alloca` 补 `undefined` | C 栈上 `JSStackFrame` 5 个字段 + realm 切换（`ctx = p->u.cfunc.realm`）+ 栈溢出检查（`js_call_c_function`）；C API `JS_Call` 走 `JS_CALL_FLAG_COPY_ARGV`，每参 `JS_DupValue`（`:17828-17851`） |
| JSC | `EncodedJSValue f(JSGlobalObject*, CallFrame*)` 两参（`runtime/NativeFunction.h:33-41`） | 参数就在 JS 帧里，`callFrame->uncheckedArgument(i)`（`interpreter/CallFrameInlines.h:130-165`） | LLInt `nativeCallTrampoline`（`llint/LowLevelInterpreter64.asm:2723-2757`）：`CodeBlock[cfr]=0`、写 `vm.topCallFrame`、调用、**唯一的后检查是 `btpnz VM::m_exception`**；无栈检查、无 callee-saved 溢出、无 handle scope（保守栈扫描 `heap/MachineStackMarker.cpp:44-53`） |
| Hermes | `CallResult<HermesValue> f(void* ctx, Runtime&)`（`include/hermes/VM/Callable.h:666-668`；`NativeArgs` 在被调方内 `runtime.getCurrentFrame().getNativeArgs()` 取） | `NativeArgs` 两字：指向寄存器栈的反向迭代器 + argc（`NativeArgs.h:29-80`） | `_nativeCall`（`Callable.h:730-765`）：`ScopedNativeDepthTracker` + `setCurrentFrameToTopOfStack` + 调用 + `restoreStackAndPreviousFrame`；帧 = 寄存器栈上 7 个元数据寄存器；native 若分配后持指针须经 `Handle`（Hades 搬移）；`CallResult` 带状态字 |
| V8（解释器） | `void f(const FunctionCallbackInfo&)`（`include/v8-function-callback.h:351`） | 4 个隐式 slot + 参数由 `CallApiCallback` 桩在栈上摆好（`builtins-x64.cc:4732-4858`） | Exit frame、HandleScope 开关（内联 3 条指令 + 关闭检查，`macro-assembler-x64.cc:4952-5029`）、异常槽检查；`Fast API` 只在 TurboFan/Maglev（`GetFastApiCallTarget` 仅两处调用者，均在编译器；Ignition 无此路径） |
| Bun（Zig↔JSC） | 与 JSC 完全相同：`fn(*JSGlobalObject, *CallFrame) callconv(.c) JSValue`（`src/jsc/host_fn.zig:1-10`） | Zig 侧按 JSC 帧偏移直接切 `[]const JSValue`（`src/jsc/CallFrame.zig`） | 零：Zig 函数指针就是 `NativeFunction`（`bindings.cpp:6135-6156`）；`error.JSError → .zero` 编译期映射（`host_fn.zig:16-46`） |

结论：**「参数就地、值按寄存器、无 handle scope、异常靠返回值哨兵 +
挂起异常」是 qjs / JSC / Bun 三家共同的形状**，也是最便宜的；Hermes 和
V8 的额外税全部来自搬移 GC / 精确根（GCScope、HandleScope）。zjs 的
GC 是非搬移 + 生产保守扫描（表示契约 v3 §1.2/§4），已经具备走 JSC 形状
的前提，但目前 ABI 1 还在付 `HostError!JSValue` 24 B sret、
`NativeCallEnvironment`、`ValueRootFrame` 的税（eval R4）。

### 1.2 类型化 / 免装箱调用

| 引擎 | 机制 | 解释器能用吗 |
|---|---|---|
| V8 | `CFunction` + `CTypeInfo`（int32/uint32/int64/float/double/bool/pointer/`FastOneByteString`），编译器做类型检查，失败走慢路；不能分配、不能抛，异常靠 isolate 挂起后检查 | **否**，仅 TurboFan/Maglev |
| JSC | `DOMJIT::Signature`（≤ 2 参，`SpeculatedType` 标注）+ `Intrinsic` | **否**，LLInt 忽略 |
| Hermes | Static Hermes `NativeCallInst`（`IR/Instrs.h:6350-6402`）：编译期把 `extern "C"` 签名直接降成 C 调用（`BCGen/SH/SH.cpp:2515-2554`），`double` = 一条 NaN-box 拆箱 `_sh_ljs_get_double`、≤6 字节整数 = 一次 `(double)` 转换（`:2601-2641`），无帧、无 `SHRuntime*`；旧路径 `CallBuiltin` 走 `builtins_[]` 数组免属性查找但仍传 `NativeArgs` | 仅 AOT；`CallBuiltin` 解释器可用但不免装箱 |
| QuickJS | `f_f` / `f_f_f`：`double f(double)`，`JS_ToFloat64` 在中心 switch 里 | 是，但只有两种签名，且每次仍走 `js_call_c_function` 全税 |

结论：**解释器内的类型化叶调用没有任何引擎做完整**；qjs 的 `f_f` 证明
了可行且便宜。zjs 已有 FNABI §15 的签名 schema（`src/abi/fun_native_abi.zig`
`signatures` 表，M0I 落地）和 6–8 个 `exec_direct` 实现。把「VM 侧做
tag 检查 + 直接 C 调用 + 装箱」做成通用机制，是本设计最大的差异化点。

### 1.3 native → JS（宿主发起 / builtin 回调）

| 引擎 | 每次调用 | 重复调用优化 |
|---|---|---|
| QuickJS | `JS_Call` → `JS_CallInternal`：栈溢出检查、`alloca` var/stack buf、`JSStackFrame` 初始化，一次 291 insn / 48 cyc | 无；sort / replace / forEach 每次全价 |
| JSC | `JSC::call` → `Interpreter::executeCallImpl`（`Interpreter.cpp:1263-1335`）：`VMEntryScope`、递归/权限检查、`ProtoCallFrame`、`doVMEntry`（`LowLevelInterpreter64.asm:177-311`：存 VMEntryRecord、栈检查、逐参拷贝循环、`makeCall`） | **`CachedCall`**（`interpreter/CachedCall.h:43-114`）：`VMEntryScope`、编译、链接、`ProtoCallFrame` 一次做完，`call()` = `vmEntryToJavaScript(entry, &vm, &protoCallFrame)`（`InterpreterInlines.h:100-127`）；≤6 参再走 `vmEntryToJavaScriptWith0..6Arguments` 免缓冲（`:129-160`）；`Array.prototype.sort`（`ArrayPrototype.cpp:982`）/ `String.prototype.replace`（`StringPrototype.cpp:378`）用它 |
| Hermes | `Callable::executeCall0..4`：`ScopedNativeCallFrame` 在寄存器栈上压帧，无 C 栈递归 | 固定元数入口本身就是优化 |
| V8 | `Execution::Call` → `Invoke`：`VMState<JS>`、`SaveContext`、`JSEntry` 桩保存全部 callee-saved、StackHandler、直接句柄→间接句柄转换循环（`TODO(42203211)`） | 引擎内 Torque `Call(...)` 是普通 builtin→builtin 调用，零税；嵌入者无缓存机制 |
| Bun | `Bun__JSValue__call`：`MarkedArgumentBuffer` 两次拷参 + `getCallData` + `profiledCall` 全价 | 无 |

结论：**JSC `CachedCall` 是嵌入侧最好的形状，但 JSC 没有把它开放给嵌入
者；zjs 已有 `SyncInternalCallSite`（引擎内）和 P4 的常驻 `HostInvocation`，
缺的是：把两者合成一个公开的 `CallSite`、`runTC` 序言不再每次构造 `Vm`
（84 insn）、返回臂直达。** 做完后宿主 → JS 与 builtin 回调是同一条路。

### 1.4 宿主对象与访问器

| 引擎 | 宿主对象身份 | 原生 getter/setter |
|---|---|---|
| QuickJS | `class_id` + `p->u.opaque`（`JS_GetOpaque2` 一次比较） | `JS_CGETSET_DEF`：**一个 `JS_CLASS_C_FUNCTION` 对象**，每次经 `js_call_c_function` getter cproto |
| JSC | `ClassInfo` + `JSCell` 子类 | **`CustomGetterSetter`**（`runtime/CustomGetterSetter.h:36-83`）：`GetValueFunc = EncodedJSValue(JSGlobalObject*, EncodedJSValue, PropertyName)` 3 寄存器直接调用、无帧（`PropertySlot.h:98-102`），IC 里 `CustomAccessorGetter` access case = 溢出保存 + 3 次寄存器移动 + call + 一次 `m_exception` 检查（`InlineCacheCompiler.cpp:3265-3392`）；`Intrinsic`/`DOMJIT` 在 `useJIT()==false` 时**未使用**（`VM.cpp:901-916`） |
| Hermes | `DecoratedObject` + `hostObjectClass` | JSI `HostObject::get(SymbolID)`：走 exotic 全路径 + 每个 key 一个 `ManagedValue` |
| Bun | 生成的 `JSXxx` cell + `m_ctx` `void*`（`offsetOfWrapped()`），方法 = downcast + 一个字段读 + 3 寄存器尾调 Zig | codegen 出 `CustomGetterSetter`，不抛的 getter 直接内联调用 |

结论：**Bun/JSC 形状最好**：`self` 固定偏移、方法直接以 `self` 进 Zig、
访问器不是函数对象而是 IC 可缓存的 slot。zjs 今天没有原生类概念
（公开面只有 `NativeObject = object.Object` 别名），FNABI §19 已设计了
NativeObject/NativeType 但 §17.3 把 getter/setter 留在慢路。本设计把它
并进 W1 属性缓存。

### 1.5 GC 根与异常

| 引擎 | native 侧根 | 异常约定 |
|---|---|---|
| QuickJS | 引用计数；无根问题 | `JS_EXCEPTION` tag 哨兵 + `rt->current_exception` |
| JSC | 保守栈扫描；`MarkedArgumentBuffer` 只为堆缓冲 | 空 `JSValue` + `vm.exception()`；`ThrowScope` release 免费 |
| Hermes | `GCScope` / `Handle<>` 必需 | `ExecutionStatus::EXCEPTION` + `thrownValue_` |
| V8 | `HandleScope`（`V8_ENABLE_DIRECT_HANDLE` + 保守扫描时 `DirectHandle` 退化为裸字，`Escape()` 变成 `return value`） | `isolate->exception` 槽 vs `TheHole` |
| zjs 现状 | 生产保守扫描（`gc_conservative.zig`，`conservative_on = !host_quiescent`）；`ValueRootFrame` 只对 slice/atom 生效（`runtime.zig:519,575-604`） | `HostError!JSValue` 错误联合 **与** `ctx.hasException()` 双轨，`nativeIsExc` 断言两者一致（`builtin_dispatch.zig:47-51`） |

结论：**zjs 的 GC 已经是 JSC/V8-direct-handle 的模型**，边界不应再有任何
handle scope、`ValueRootFrame`、`Persistent` 的每次调用开销；异常只留
哨兵一轨。V8 用 `static_assert` 把 direct handle 和保守扫描绑死
（`handles.h:383-386`），zjs 应在契约里写同样一条。

---

## 2. 设计原则

每条都对应 §1 的证据，并且是 §3–§9 规格的硬约束：

- **原则 1：一种函数对象**。builtin、宿主函数、插件函数、访问器都是
  `NativeEntry`（FNABI §10），函数对象只存一个 `*const NativeEntry`；
  稳态路径不按来源分支。（现状：`c_function` + `InternalRecord` +
  `external_host_record` 蹦床 + 注册表按 id 查找 = 三次间接。）
- **原则 2：值按寄存器过界，零 marshaling**。`JSValue` 16 B 两寄存器
  按值传递与返回（`callconv(.c)` 下 AArch64 x0:x1 / x86-64 rax:rdx），
  `argv` 指向 VM 操作数窗口，不拷贝、不 `alloca`。（qjs / JSC / Bun。）
- **原则 3：异常只有一轨**：返回 `JSValue.exception` 哨兵 ⇔
  `ctx.hasException()`。跨界不传 Zig 错误联合；Zig 侧错误集在 SDK thunk
  里编译期映射为哨兵。
- **原则 4：native 侧无 handle scope、无根帧**。调用期间参数由操作数
  窗口保活（`traceStack` 已覆盖），native 局部变量由保守扫描保活；跨调用
  持有走 pin 账本（`Persistent`）。契约：**保守扫描是本设计的前提，任何
  取消保守扫描的提案必须先重做本边界**（对应 V8 `handles.h:383`）。
- **原则 5：帧按需**。叶调用零帧；managed 调用只压 2 字的 backtrace
  标记；不建 `NativeCallEnvironment`，不存取 `active_native_call`。
- **原则 6：类型检查在 VM 侧，目标函数只见原生类型**。叶签名的 tag 检查、
  拆箱、装箱由 VM 的按签名生成的 handler 做，目标是纯 C ABI thunk
  （FNABI §16「无运行时 wrapper」）。
- **原则 7：再入靠常驻状态 + 缓存调用点**。一个 Machine、一个预构造
  `Vm`、一个解析过的 `CallSite`；每次调用只做「压 Entry、跑到边界、弹」。
- **原则 8：宿主对象 = 固定偏移 self + IC 可缓存的原生访问器**。
- **原则 9：公开接口是 comptime 生成的 thunk，不是运行时框架**。
  `zjs.native.leaf(f)` / `managed(f)` / `Class(spec)` 在编译期把 Zig 函数
  变成 `NativeEntry`；无 arena、无 scope、无每参数格式化。
- **原则 10：opcode 按证据加**。opcode 账 243/13（`opcode-design.md` §0）。
  D2 复议（owner 2026-09-06 晚）后允许为调用点 quickening 新增指令，
  方案与预算见 §5.5：5 条 quickened 调用指令 + 编译期分配的 u8 cache
  index，与 W1 属性缓存同一形态，quickened 状态同时就是 JIT 的反馈槽。

---

## 3. 对象模型

### 3.1 `NativeEntry`（VM 私有，不可变，48 B）

```zig
// src/core/native_entry.zig（新）
pub const NativeEntry = extern struct {
    /// 目标 C ABI 函数指针（叶 thunk / managed thunk / getter / setter / ctor）。
    target: *const fn () callconv(.c) void,
    /// 叶签名 tag 检查失败时的 managed 后备（builtin 的 ToNumber 语义走这里；
    /// 插件 canonical policy 下为 null ⇒ VM 抛 TypeError/RangeError）。
    fallback: ?ManagedFn,
    /// stateful / 闭包数据；builtin 为 null；magic 走 `magic` 字段。
    state: ?*anyopaque,
    kind: Kind,          // u8 @24，见 §4
    flags: Flags,        // u8 @25：is_constructor / forwards_call / has_self / …
    sig: u16,            // @26 叶签名 id（FNABI schema `signatures[].id`），managed 为 0
    arity: u8,           // @28 JS `length`，同时是 argv 补 undefined 的上界
    effect: Effect,      // u8 @29：JIT 调度标注（§15 R2）；解释器只读其中 nothrow
    class_id: u16,       // @30 K2 method_self：receiver 必须是的 NativeType class id；否则 0
    magic: u16,          // @32 builtin magic（qjs `magic`），thunk 经 entry 读
    builtin_id: u16,     // @34 静态 builtin 表下标（宿主 = 0）；JIT intrinsic 识别用（§15 R9）
    name: atom.Atom,     // u32 @36，backtrace / `name` 属性
    /// 冷路径 provenance（FNABI §10.3）；handler 不得读。
    owner: ?*anyopaque,  // @40
};
comptime { assert(@sizeOf(NativeEntry) == 48); }
/// 与 HelperDescriptor（engine-evolution-plan §5.5）同一语义；叶 = 全 0。
pub const Effect = packed struct(u8) {
    may_throw: bool, may_alloc: bool, may_reenter_js: bool, reads_heap: bool, writes_heap: bool, _pad: u3 = 0,
};
```

所有偏移由 `tools/gen_vm_offsets.zig` 生成进 `vm_offsets.inc`（engine
plan §5.3 规则 1），JIT 与解释器同源；结构是 `extern struct` 正因为它是
未来机器码的直接输入（§15 R1）。

- builtin 的 entry 由 `internal_builtins.zig` 的 comptime 表**静态生成**
  （`const entries: [N]NativeEntry`），进程级只读、不分配、不追踪。
- 宿主/插件 entry 由 `JSRuntime.native_entries`（arena）分配，生命周期
  由 owner（runtime 或 `NativeBindingOwner`）管，**不随函数对象回收**；
  hot-reload 世代校验按 FNABI §17.2（entry 指针是非持有引用，函数对象
  持 owner 引用保活 —— 与今天 `external_host_functions` 注册表同样的
  所有权，只是去掉 id 间接）。
- `NativeEntry` 取代 `InternalRecord`（`host_function.zig:203-236`）、
  `ExternalRecord`（`:79-83`）、`external_host_record` 蹦床
  （`builtin_dispatch.zig:255-315`）、`call_cache` 惰性填充。

### 3.2 函数对象 payload

`FunctionPayload.NativeFields`（`object_payloads.zig:1098-1153`，40 B）改为：

```zig
pub const NativeFields = extern struct {
    realm: RealmRef,                 // 8：qjs `p->u.cfunc.realm`
    entry: *const NativeEntry,       // 8：唯一的调用描述
    state_override: ?*anyopaque,     // 8：同一 entry 多实例时的 per-object state（c_function_data 形）
    typed_array_element_size: u32,   // 保留
    typed_array_kind: u8,            // 保留
    _pad: [11]u8,
};
```

删除 `call_cache` / `host_function_kind` / `native_function_id` /
`external_host_function_id` / `native_dispatch_name`。`nativeCallTarget`
（`object.zig:5118-5129`）变成一次 payload 读：`{ entry, realm }`。
`c_function_data` 类（`class.zig:78`）保留其 `JSValue[]` 数据 payload，
调用走 K0 且 `state_override` 指向数据数组。

### 3.3 builtin 表的迁移方式（零手工改写）

现有 ~700 个 builtin 以 `InternalEntry`（`host_function.zig:269-283`）声明
`cproto + native_function`。迁移不是逐个改函数，而是 comptime 适配器：

```zig
// internal_builtins.zig 的表构建器
fn entryFromInternal(comptime e: InternalEntry) NativeEntry {
    return switch (e.cproto) {
        .generic        => managedThunkFromLegacy(e.native_function.?.generic),   // 生成 K0 thunk：把 (ctx,this,argv,argc,entry) 转成旧签名，错误联合→哨兵
        .generic_magic  => managedThunkFromLegacyMagic(...),                      // magic 经 entry.magic
        .f_f            => leafEntry(.F64_TO_F64, e.native_function.?.f_f, fallback = e.fallback_function),
        .f_f_f          => leafEntry(.F64_F64_TO_F64, ...),
        .getter/.setter => accessorEntry(...),
        .constructor*   => ctorEntry(...),
        .iterator_next  => managedThunkFromLegacyIterNext(...),
    };
}
```

第一阶段所有 builtin 经适配器进 `NativeEntry`（语义不变，付一次内联
的签名转换，比今天的 `dispatchTypedRecord` switch 便宜）；之后按频次把
热 builtin 改写成原生 K0/K1 签名（§13 阶段 B/E）。已有的 8 个
`exec_direct` 实现（eval §6.2）改成 K0 签名（去掉 `output/global/caller_*`
参数，见 §4.1）。

---

## 4. 调用种类与机器 ABI（Fast Call ABI v2）

所有 target 都是 `callconv(.c)`；`JSValue` 按值两寄存器；返回 `JSValue`
直接在 x0:x1（Zig `callconv(.c)` 对 16 B extern struct 的返回遵循 C ABI，
不再需要 `NativeBits` 的 `@bitCast` 绕行；内部保留 `NativeBits` 别名兼容）。

### 4.1 K0 `managed`：一种通用签名

```zig
pub const ManagedFn = *const fn (
    ctx: *JSContext,          // x0：callee 的 realm（qjs 语义，由 payload.realm 预解析）
    this: JSValue,            // x1:x2
    argv: [*]const JSValue,   // x3：指向操作数窗口；argv[0..max(argc, entry.arity)] 可读
    argc: u32,                // w4
    entry: *const NativeEntry,// x5：magic / state / name 经它读；state_override 时由 handler 替换为 override
) callconv(.c) JSValue;
```

6 个整型寄存器，无栈溢出（对比 `ExecDirectCallFn` 8 参 10 寄存器）。
`this` 按值：qjs 同形（`this_val` 两寄存器）；不走 `argv[-1]` 是因为
op_call 形的窗口里没有 receiver 槽。

**argv 补齐规则**（替代 qjs 的 `alloca arg_buf`）：handler 在
`argc < entry.arity` 时把窗口 `[argc, arity)` 就地写 `undefined`。窗口顶
就是栈顶（`setTopPtr(sp)` 之后），需要的头寸 = `arity - argc` 槽；
`Stack.reserveAdditional`（`stack.zig:240`）只在稀有分支调用。thunk 因而
可以无分支读 `argv[i]`（i < arity）。**多余参数照 JS 语义忽略**。

**FNABI §14.4 的 `fn0..fn4(ctx, a0..)` 固定元数形态降级为 SDK 层便利**：
`zjs.native.managed(fn(*Call) …)` 的 `Call.arg(i)` 就是 `argv[i]`，编译期
展开为一条 load；不再另设 5 种机器签名（D1）。

### 4.2 K1 `leaf(sig)`：类型化叶调用

target 是纯 C 原型，由签名 id 决定，例如
`I32_I32_TO_I32 = fn(i32, i32) callconv(.c) i32`、
`F64_TO_F64 = fn(f64) callconv(.c) f64`、`STATE_F64_TO_VOID = fn(*anyopaque, f64) callconv(.c) void`、
`BUFFER_TO_I32 = fn(*const BufferView) callconv(.c) i32`。签名清单来自
`src/abi/fun_native_abi.zig` 的 schema（唯一来源，FNABI §15.2）；本设计
新增 `SELF_*` 家族（§4.3）与 `STRING_VIEW` 家族（§4.6）。

VM 侧 handler 按签名 comptime 生成（`vm_native.zig`，§5.2）：

1. 对每个参数按 marshal policy 检查 tag 并拆箱：
   - `i32`：`tag == int` → 直接；`tag == float64` 且 `f == @trunc(f)` 且在
     范围内 → `@intFromFloat`；否则 → `fallback`（有）/ `RangeError`/`TypeError`（无）。
   - `f64`：`tag == float64` → 直接；`tag == int` → `@floatFromInt`；否则 → fallback / TypeError。
   - `bool`：`tag == boolean`；否则 fallback / TypeError。
   - `self` / `state` / view：见 §4.3、§4.6。
2. 直接 `bl target`（参数进 w/x/d 寄存器）。
3. 装箱返回值：`i32` → int tag；`f64` → 若可精确表示为 int32 则 int tag
   否则 float64（qjs `js_float64` 的 `JS_NewFloat64` 同规则）；`void` → undefined。
4. 写结果槽、`setLen`。

**叶调用不做**：interrupt tick、栈溢出预检、backtrace 标记、realm 切换、
异常检查（target 不可能抛）。这就是 ≤ 15 cyc 的来源：约 20–25 条指令，
一次间接调用。

叶 target 的合同（FNABI §14.1 原文）：不接触 `JSValue`、不分配、不调用
JS、不抛、有界短时。**builtin 也可以是叶**：`Math.abs` = `leaf(F64_TO_F64,
mathAbs, fallback = mathAbsGeneric)`；非 Number 参数走 fallback 保留
`ToNumber` 语义（今天 `f_f` 的 `primitiveF64Arg` + `callInternalRecordFallback`
已是这个结构，`builtin_dispatch.zig:882-921`）。

### 4.3 K2 `method_self(sig)`：原生对象方法

receiver 是 `NativeObject`（§8.1）。handler 在 K1 之前多做：

1. `this.tag == object` 且 `obj.class_id == entry.class_id`（一次比较；
   NativeType id 即 class id，FNABI §19.2a）；否则 fallback / TypeError。
2. `self = obj.payload.native.self`（固定偏移一次读）；`self == null`
   ⇒ disposed ⇒ TypeError。
3. 其余同 K1，`self` 作为第一个参数（`fn(*Self, f64) callconv(.c) void`）。

managed 变体 `method_managed`：`fn(ctx, self: *anyopaque, this, argv, argc, entry) JSValue`（7 寄存器）。

内建的 String/Array 方法同样可用 K2 形：`charCodeAt` = `method_self(class=string_wrapper|primitive string …)`
—— 对原始值 receiver 的 K2 变体 `prim_self`：receiver tag 检查代替
class_id 检查，`self` = string 指针。这把今天 `stringCharCodeAtDirect`
的 exec_direct 手写检查变成签名驱动。

### 4.4 K3 `accessor`：原生 getter / setter

```zig
pub const GetterFn = *const fn (ctx: *JSContext, this: JSValue) callconv(.c) JSValue;
pub const SetterFn = *const fn (ctx: *JSContext, this: JSValue, value: JSValue) callconv(.c) JSValue; // 返回 undefined 或哨兵
// typed 变体（K2 形）：fn(self: *Self) callconv(.c) f64 / fn(self: *Self, v: f64) callconv(.c) void
```

调用点不是 `call` 而是属性访问；进入方式见 §8.2。builtin 的 `getter/
setter/getter_magic/setter_magic` cproto 经适配器进这里。

### 4.5 K4 `constructor`

```zig
pub const CtorFn = *const fn (ctx, new_target: JSValue, argv, argc, entry) callconv(.c) JSValue;
```

`flags.is_constructor` 决定 `new` 是否合法；`constructor_or_func` 用
`new_target.tag == undefined` 区分（qjs 同）。K4 走 managed 税。

### 4.6 视图参数（零拷贝）

`BufferView` / `StringView` 按 FNABI §20 定义（`const T*` 传指针）；handler
在调用前做 detached / 类型检查并在栈上构造 view，调用后不做清理
（borrowed 生命周期 = 本次调用；retained/transfer 走 managed Host API）。

### 4.7 每种的固定税（合同）

| kind | interrupt tick | 栈预检 | backtrace 标记 | realm 切换 | 异常检查 | 根 |
|---|---|---|---|---|---|---|
| K1 leaf / K2 typed | 否 | 否 | 否 | 否 | 否 | 窗口 |
| K0 managed / K2 managed / K4 | **否**（qjs `js_call_c_function` 不 poll；poll 在字节码回边与函数入口） | 是（1 比较） | 是（2 store + 2 restore） | 是（payload 预解析，1 load） | 是（1 tag 比较） | 窗口 + 保守扫描 |
| K3 getter | 否 | 是 | 是 | 是 | 是 | 同上 |

今天 `nativePlainFastDispatch` 的 interrupt tick（`vm_call.zig:671-675`）
在本设计里删除（D7）。

---

## 5. JS → native：VM 侧路径规格

### 5.1 `op_call` / `op_call_method` 的 native 臂

两条 opcode 的 native 臂（`tailcall_dispatch.zig:1637-1651`、`:1829-1843`）
统一为一次调用：

```zig
// op_call：窗口 = [callee, args...]，this = undefined
if (func_obj.class_id == .c_function) {
    vm.stack.setTopPtr(sp);
    return vm_native.dispatch(vm, func_obj, region_base, argc, .no_receiver);
}
// op_call_method：窗口 = [receiver, callee, args...]
    return vm_native.dispatch(vm, func_obj, region_base, argc, .receiver);
```

`bound_function` / `c_closure` 不进这条臂（保持慢路）。`forwards_call`
（`Function.prototype.call/apply`）在 §5.4 处理。

### 5.2 `vm_native.dispatch`（新文件 `src/exec/vm_native.zig`，取代 `vm_call.nativePlainFastDispatch` / `nativeMethodFastDispatch` / `builtin_dispatch.callRecordFromVmInRealm` / `dispatchTypedRecord`）

```zig
/// 解释器与未来 JIT 共用的 helper：参数是执行状态（engine plan §5.3 `VmExecState` 的
/// native-call 子集），不是解释器私有的 `*Vm`（§15 R4）。
pub noinline fn dispatch(st: *VmExecState, func_obj: *Object, region_base: usize, argc: u32, comptime shape: Shape) align(32) VmHelperStatus {
    const nf = func_obj.nativeFields();               // 1 load 基址
    const entry = nf.entry;                           // 1 load
    const this_value = if (shape == .receiver) window[region_base] else undefined;
    const argv = window + region_base + (if (shape == .receiver) 2 else 1);
    switch (entry.kind) {                             // jump table；每臂 comptime 生成
        .managed => return callManaged(st, entry, nf, this_value, argv, argc, region_base),
        inline else => |k| return callTyped(k, st, entry, nf, this_value, argv, argc, region_base),  // 按 sig 展开
    }
}
```

解释器的 `Vm` 提供 `execState()` 视图（`sp/fp/var_base/function/ctx`
已是 `Vm` 字段，只是换名暴露）；返回值按 engine plan §5.4 的
`VmHelperStatus` 映射到现役 `Outcome`（`continue_execution → next`、
`exception → coldNext`）。

`callManaged` 逐步：

1. `if (argc < entry.arity) padUndefined(vm, argv, argc, entry.arity)`（冷）。
2. `ctx = nf.realm.ptr`（1 load；跨 runtime 断言在 Debug）。
3. 栈预检：`@frameAddress() < rt.hot.native_stack_limit` → 冷路 `throwCFunctionStackOverflow`。
4. backtrace 标记：栈上 `ActiveBacktraceFrame{ .function_value = func_obj }` 压入
   `realm.active_backtrace`（2 store），`defer` 弹（1 store）。
5. `result = entry.target_as_managed(ctx, this_value, argv, argc, entry_or_override)`。
6. `if (result.tag == .exception) return nativeFailure(vm, region_base)`（冷：`popOwnedStackRegion` + `handleCatchableRuntimeError`，即今天的 `nativeDispatchFailure`）。
7. `stack.setLen(region_base)`；`push(result)` 或丢弃（`dropUnusedCallResult` 语义保留）。

指令预算（AArch64，估）：分派 ~12、步骤 1–4 ~14、调用序列 ~6、步骤 6–7 ~8
→ ~40 insn，~20–25 cyc（qjs 35）。

`callTyped(sig)`：§4.2 的 1–4 步，无 2–4；预算 ~22 insn，~12–15 cyc。

### 5.3 与 `execCall` 慢路的关系

`.miss` 不再存在：所有 `c_function` 都有 entry；慢路只剩
`bound_function`、`c_closure`、Proxy、非可调用（`execCall` 现有分支保留，
`callNativeCallableObject` 的 `.resolved_record/.host_function/.name_dispatch`
三臂删除，`callNativeCallableByName` 及 `array_ops.arrayMethodFastCall`
的名字匹配链整体删除 —— eval R2 的缺陷根源）。根路径（宿主 API 经
`callValueOrBytecodeRoot` 调 native，如 `ctx.callFunction(nativeFn)`）走
同一个 `callManaged` 的 rooted 版本 `callManagedRooted(ctx, entry, this, args)`
（args 是宿主切片，作为 `.slices` 根登记 —— 这是唯一保留 `ValueRootFrame`
的地方）。

### 5.4 `f.call` / `f.apply`

`Function.prototype.call/apply` 是 `flags.forwards_call` 的 managed entry；
今天走「转发臂 + `setupFallbackInlineEntry` + `op_return_slow`」（eval §6.3）。
本设计：在 `dispatch` 里 `forwards_call` 是 `entry.kind == .forward_call/.forward_apply`
两个专用臂：直接把窗口重排（call：把 `[recv=f, callee=call, this, args...]`
改写成 `[this, f, args...]` 后按 `op_call_method` 的字节码臂继续；apply：
展开数组到窗口后同上），不经任何 native target。目标 ≤ 60 / ≤ 100 cyc。

---

### 5.5 调用点 quickening（D2 复议方案）

**编码**：所有调用指令在编译期带一个 u8 `cache_idx`（按函数分配，255 =
无缓存；与 W1 的 get_field/put_field 同一规则）：`call0..3 idx`（1 → 2 B）、
`call argc:u16 idx`（3 → 4 B）、`call_method argc:u16 idx`（3 → 4 B）。
`get_field2_call_method` 融合不变（其后的 `call_method` 自带 idx）。
代价：每个调用点 +1 B 字节码（CodeLoad 影响待量，估 < 0.5%）。

**站点缓存**（`FunctionBytecode.call_sites: []CallSiteCache`，与 W1 的
属性缓存条目同一分配，即 §15 R10 的反馈槽）：

```zig
pub const CallSiteCache = extern struct {
    entry: ?*const NativeEntry,   // 单态目标；null = 空
    handler: ?*const NativeArm,   // 按 (kind, sig) comptime 生成的臂；quicken 时从 entry 推出
    misses: u8, state: u8 /* empty / mono / mega */, _pad: [6]u8,
};  // 24 B
```

**5 条新指令**（13 → 8 空闲）：

| 指令 | 来源 | 编码 | 命中臂 |
|---|---|---|---|
| `call_leaf1 idx` | `call1` 且 callee 是 K1 元数 1 | 2 B | guard → `slot.handler`（sig 臂：tag 检查、拆箱、`blr target`、装箱）|
| `call_leaf2 idx` | `call2` 且 K1 元数 2 | 2 B | 同上 |
| `call_native argc idx` | `call` 且 K0/K4 | 4 B | guard → 内联 §5.2 `callManaged` 步骤 1–7 |
| `call_method_native argc idx` | `call_method` 且 K0/K3/K4 | 4 B | 同上，带 receiver |
| `call_method_leaf argc idx` | `call_method` 且 K1/K2（`Math.abs(x)`、`str.charCodeAt(i)`、`world.step(dt)`）| 4 B | guard → `slot.handler` |

`call0/call3` 与 1–2 参以外的形态不 quicken，仍走 §5.2 的未 quicken
快路（本身已达 qjs 水平）。

**guard**（命中臂前三步）：`callee.tag == object`、`obj.class_id ==
c_function`、`obj.nativeFields.entry == slot.entry`。**不能**用「对象指针
== 缓存指针」代替：函数对象可被回收、地址被另一个 c_function 复用，只有
从活对象读出的 entry 指针才可信（表示契约 §5.2 的 ABA 条款）。entry
指针本身不需要纪元：**`NativeEntry` 在 runtime 生命周期内永不释放，
退休 = 原地改 `kind = .retired`**（tombstone，48 B/条），退休臂抛
「native function retired」；所以命中 = 目标仍是活的。纪元（§15 R6）
只服务 JIT 代码块里嵌入的 `target` 常量。

**quicken / dequicken 协议**（FNABI §17.2 条款的落地）：

1. 未 quicken 的 `call*` native 臂在 `dispatch` 成功返回后，若 `idx != 255`
   且 `slot.state == empty`：写 `slot = { entry, handlerFor(entry) }`，
   `state = mono`，把 opcode 字节原地改写为对应 quickened 形（同宽）。
2. quickened 臂 guard 失败：`misses += 1`，走通用路径；`misses >= 2` →
   opcode 改写回基础形，`state = mega`，此站点永不再 quicken（防震荡）。
3. quickened 臂 guard 失败但 `misses < 2`：只走通用路径，不改写。
4. 站点缓存不是 GC 边（entry 不是 GC 对象）；`FunctionBytecode` 释放时
   随之释放。

**收益估算**（AArch64，`abs(i)` 叶）：未 quicken 路径 = opcode 臂 5 +
`dispatch` 调用与序言 ~10 + 分派 5 + 叶臂 13 ≈ 33 insn；quickened =
guard 8 + `blr handler` 1 + 叶臂 13 ≈ 22 insn，**省约 11 insn ≈ 4–6 cyc**
（18 → 12–14）；managed 形省一层 `dispatch` 调用，25 → ~20。这是
解释器能拿到的最后一段，再往下就是 JIT 内联（≤ 8）。

**判决实验**（按机制刀政策，先 ≤ 30 min 实验再花编号）：阶段 B 末在
`leaf2` / `abs` / `method_typed` 三例上 A/B quickened 与未 quicken，
**每例 ≥ 3 cyc 才提交这 5 个编号**；不达线则只保留 cache_idx 编码与
反馈槽（JIT 仍需要），指令回收。

## 6. native → JS：`CallSite` 与常驻 `Vm`

### 6.1 三条现有路径合一

今天有三条：`JSContext.callFunction` → `callFromHost`（P4 常驻 Machine）、
builtin 的 `SyncInternalCallSite`、根路径 `callValueOrBytecodeRoot`。本设计
只留一种解析产物 `CallSite`，两种进入方式（有活动 invocation / 无）：

```zig
// src/exec/call_site.zig（新；公开为 zjs.CallSite）
pub const CallSite = struct {
    ctx: *JSContext,
    callee: JSValue,             // pin：init 时经 pin 账本持有，deinit 释放
    this_value: JSValue,         // 同上
    route: Route,                // 解析产物（见下）
    pub fn init(ctx: *JSContext, callee: JSValue, this_value: JSValue) !CallSite;
    pub fn deinit(self: *CallSite) void;
    pub fn call(self: *CallSite, args: []const JSValue) JSValue;      // 哨兵 = 异常
    pub inline fn call0(self) JSValue; call1(self, a0) JSValue; call2(...) JSValue;   // 免切片
    pub fn callWithThis(self, this_value, args) JSValue;              // JSON reviver 形
};
const Route = union(enum) {
    bytecode: struct { func: *FunctionBytecode, closure: *Object, frame_words: u32, arg_count: u8, flags },  // 已验证可 inline 进 Machine
    native: *const NativeEntry,                                       // callee 是 native：直接 callManagedRooted
    jit: struct { code: JitEntryFn, func: *FunctionBytecode, closure: *Object, frame_words: u32 },  // 预留（§15 R7）：同一 Entry 压栈，pc 换成机器码入口
    generic: void,                                                    // bound/proxy/…：走 callValueOrBytecodeRoot
};
// CallSite 另存解析时的 rt.native_entry_epoch（§15 R6），call 时一次比较。
```

`init` 做一次的事（今天每次 `callFromHost` 都做的）：callee 类判定、
`resolveInlineFunction`、realm 匹配（`ctx.global == callee realm`）、
pin。`call` 每次做的事：

1. `inv = rt.active_invocation orelse acquire+publish HostInvocation`（P4 已有；
   publish 只在无活动 invocation 时）。
2. `pollInterrupt`（进入 JS 前一次，qjs `JS_CallInternal` 入口同）。
3. `machine.pushNativeBoundaryArgs(route, this, args)`：压 Entry、拷 args
   到新帧（`tryPushNativeBoundaryCopiedArgsFast`，`inline_calls.zig:3382`）。
4. `runUntilNativeBoundary(machine)`（§6.2）。
5. 结果在 `vm.return_value`；异常 → 哨兵。

### 6.2 常驻 `Vm`：`runTC` 序言归零

`zjs_vm.runTC`（`zjs_vm.zig:688-713`）每次进入构造 24 字段的 `Vm`（84 insn）。
改为 **`Machine` 内嵌一个 `Vm`**（`machine.vm: tailcall_dispatch.Vm`），
`ctx/rt/global/output/machine/active_dispatch_tbl/resident_tail_tbl/
property_tail_tbl` 在 `Machine` 创建或 re-target 时写一次；每次进入只
刷新 `function/frame/stack/code_base/catch_target/var_refs_base`（6 store）
再 `runDispatchLoop(&machine.vm)`。`Vm` 布局不变（其字段顺序是测过的，
`tailcall_dispatch.zig:96-221`），只是存放位置从 C 栈搬到 Machine。
嵌套进入（native boundary 内再进 JS）时同一个 `Vm` 被复用：进入前保存
6 个易变字段到 `NativeBoundaryScope`，返回时恢复（已有 `NativeBoundaryValidation`
快照的位置）。

### 6.3 返回臂

P4 已加 `popAndResume` 的 `.native_boundary` 臂（`tailcall_dispatch.zig:1202-1208`）。
补：`op_return_undef` / 生成器 `yield` 边界 / 异常 unwind 到 fence 三处
也直达 `.native_returned`，不经 `op_return_slow`。

### 6.4 builtin 回调统一

`array_ops` 等的 `SyncInternalCallSite`（`call_runtime.zig:737-849`）
改名/合并为 `CallSite`（同一类型；引擎内 `init` 用 `initInternal` 跳过
pin，因为 callee 已在窗口根里）。`call` 的每次 `activeInvocation(rt) ==
route.invocation` 校验保留（1 比较）。预算：压帧 ~25 insn + 进入 ~15 +
执行 + 返回臂 ~15 → 宿主 → JS ≤ 40 cyc（qjs 48），builtin 回调 ≤ 60（qjs 67）。

### 6.5 递归与栈

宿主 → JS → native → JS 的 C 栈递归不可避免（宿主在 C 栈上）；每层
`call` 做一次 `checkNativeStackOverflow`。引擎内 builtin → JS 不递归 C 栈
（`.native_boundary` 段机制不变）。

---

## 7. 契约条款（写入表示契约 v4 与 FNABI v0.9）

- **C1 值**：`JSValue` 16 B 按值两寄存器；返回值 x0:x1。（不变）
- **C2 根**：native 目标运行期间，其参数由 VM 操作数窗口保活；native
  局部由保守扫描保活；**保守扫描是本边界的前提**（对应 V8
  `static_assert(conservative_stack_scanning)`）。`Persistent` 只用于跨调用。
  堆上的 `JSValue` 数组（native 自管内存）仍须经 `ValueRootFrame.slices`
  或 pin —— 与今天规则相同（`runtime.zig:555-558`）。
- **C3 异常**：哨兵 ⇔ `ctx.hasException()`；native 目标只能通过
  `ctx.throw*` 设置挂起异常并返回哨兵；不得 unwind 进 VM。
- **C4 argv 有效范围**：`argv[0..max(argc, arity)]`，多余忽略，缺省 `undefined`。
- **C5 叶合同**：K1/K2 typed 不接触 JSValue、不分配、不调 JS、不抛、有界。
- **C6 realm**：`ctx` = callee 构造 realm（`c_function`），`c_function_data`
  沿用调用者 realm（qjs 语义，`finalCallableRealmView` 的现规则）。
- **C7 backtrace**：managed 调用在 `Error().stack` 中可见（`at name (native)`），
  叶调用不可见（D6）。
- **C8 interrupt**：native 调用本身不 poll；进入 JS（CallSite）时 poll 一次。
- **C9 entry 生命周期**：`NativeEntry` 由 owner 持有，至少活到最后一个
  引用它的函数对象被回收；builtin entry 进程级不可变。
- **C10 线程**：entry 与函数对象绑定 Runtime（FNABI §21.1）；CallSite 只能
  在其 Runtime 的 carrier 线程上调用。

---

## 8. 宿主对象与原生访问器

### 8.1 `NativeObject`

新增 class 家族 `native_object`（class id 由 `NativeType` 注册分配，FNABI
§19.2a 的静态槽规则）与 payload：

```zig
pub const NativePayload = extern struct {
    self: ?*anyopaque,           // 固定偏移；null = disposed（Bun `m_ctx`、qjs `u.opaque`）
    type_: *const NativeType,    // finalizer / owner / 名称；handler 不读（class_id 已够）
};
```

`NativeType { class_id, name, finalize: ?fn(*anyopaque) callconv(.c) void, owner, size_hint }`。
`Object.nativeSelf(obj) ?*anyopaque` = 一次 class 家族检查 + 一次 load。
finalizer 在 sweep 时于 runtime 线程调用（FNABI §19.5）。

### 8.2 原生访问器 slot 与 IC 臂（依赖 W1）

`property.Flags.kind` 是 2 bit 且已满（data/accessor/var_ref/auto_init，
`property.zig:22-27`）。不扩位（Shape 的 `flags:u6` 与 qjs 布局对齐），
改为：**`accessor` kind 的 Slot 允许 getter/setter 头指针指向一个
`NativeAccessorCell`**（不是函数对象）：

```zig
// property.Slot.accessor 现为 { getter: ?*gc.Header, setter: ?*gc.Header }
// 新：header kind = .native_accessor 的 cell：
pub const NativeAccessorCell = struct { header: gc.Header, get: ?GetterFn, set: ?SetterFn, typed_sig: u16, class_id: u16 };
```

- 慢路 `getProperty` 遇到 accessor slot：`header.kind == .native_accessor`
  → 直接 `get(ctx, this)`；否则原路（调用 getter 函数对象）。
- **W1 的 get_field 缓存条目**（shape identity + slot + proto arm）加一个
  `kind` 位：`native_getter`。命中时：`cell = slot.getter`，`result =
  cell.get(ctx, this)`（或 typed：class_id 检查 + self + `fn(*Self) f64` + 装箱）。
  这就是 JSC `CustomAccessorGetter` access case 的形状。
- `put_field` 同理 `native_setter`。
- `Object.defineProperty` 观察到的是普通 accessor 描述符：`get`/`set`
  返回时**惰性物化**一个 K3 函数对象（qjs `JS_CGETSET_DEF` 的对象在这里
  才创建），物化后 cell 记住它以保持同一性。
- builtin 的 `getter/setter` cproto 全部改走这条（`Map.prototype.size`、
  `RegExp.prototype.flags`、TypedArray `length` 等），这些今天每次都建
  `NativeCallEnvironment`。

W1 尚未落地时（阶段 D 之前），§8.2 只做慢路部分；IC 臂作为 W1 的验收项
之一（§11 对账）。

### 8.3 宿主对象方法

`world.step(dt)`：`op_call_method` → callee 是 K2 entry（`class_id = World`）
→ §4.3。方法函数对象挂在原型上，普通属性语义（可被覆盖/删除），不需要
额外 guard：guard 就是「取到的 callee 是这个 entry」+ K2 的 class_id 检查。
这比 FNABI §17.3 列的六项 guard 少，因为我们不做 call-site quickening
（原则 10）；quickening 版本再加 shape/proto guard。

---

## 9. 公开 Zig 接口（`zjs.native`，嵌入者与 fun 的唯一入口）

### 9.1 注册

```zig
const zjs = @import("zjs");

// 叶：签名由 Zig 函数类型推导（i32/u32/f64/bool/void/*State/*Self/*const BufferView/StringView）；
// 不在 schema 内的类型 = 编译错误，不静默降级（FNABI §23.3/§23.4）。
fn add(a: i32, b: i32) i32 { return a +% b; }
try ctx.defineFunction("add", zjs.native.leaf(add), .{});

// 叶 + 后备（builtin 风格的 ToNumber 语义）：
try ctx.defineFunction("abs", zjs.native.leafWithFallback(absF64, absManaged), .{});

// managed：只接受 fn(*zjs.native.Call) E!JSValue，E 必须是显式错误集（anyerror = 编译错误）；
// 错误名在编译期映射：JSException→哨兵（已挂起）、TypeError/RangeError/SyntaxError/ReferenceError/URIError/EvalError→对应构造器、其余→Error(@errorName)。
fn log(call: *zjs.native.Call) error{ JSException, TypeError }!zjs.JSValue {
    const s = try call.ctx.toString(call.arg(0));   // toString 失败已挂起异常 → error.JSException
    std.debug.print("{s}\n", .{s.bytes()});
    return zjs.JSValue.undefinedValue();
}
try ctx.defineFunction("log", zjs.native.managed(log), .{ .length = 1 });

// 带状态：
fn tick(state: *Counter, dt: f64) void { state.t += dt; }
try ctx.defineFunction("tick", zjs.native.leafWithState(tick, &counter), .{});
```

```zig
pub const Call = struct {
    ctx: *JSContext, this: JSValue, argv: [*]const JSValue, argc: u32, entry: *const NativeEntry,
    pub inline fn arg(self: *const Call, i: usize) JSValue;          // i < entry.arity：无分支；否则 argc 检查
    pub inline fn state(self: *const Call, comptime T: type) *T;
    pub fn throwTypeError(self: *const Call, comptime fmt: []const u8, args: anytype) error{JSException};
    pub fn throwRangeError(...); pub fn throwError(name, ...);
    // 值构造/读取直接用 zjs.value.* 与 ctx.*（无 scope、无 Persistent）
};
```

thunk 生成规则（`zjs.native.managed`）：

```zig
pub fn managed(comptime f: anytype) Spec {
    const Thunk = struct {
        fn thunk(ctx: *JSContext, this: JSValue, argv: [*]const JSValue, argc: u32, entry: *const NativeEntry) callconv(.c) JSValue {
            var call = Call{ .ctx = ctx, .this = this, .argv = argv, .argc = argc, .entry = entry };
            return f(&call) catch |e| return mapError(ctx, e);   // switch 在编译期按 f 的错误集展开
        }
    };
    return .{ .kind = .managed, .target = &Thunk.thunk, .arity = arityOf(f) };
}
```

`Spec` 是编译期常量（可放进 comptime 表），`defineFunction` 把它变成
运行时 `NativeEntry`（宿主）或直接引用静态 entry（builtin）。

### 9.2 原生类

```zig
const World = zjs.native.Class(.{
    .name = "World",
    .Self = WorldState,
    .constructor = WorldState.create,                 // fn(*Call) E!*WorldState
    .finalize = WorldState.destroy,                   // fn(*WorldState) void
    .methods = .{
        .step = WorldState.step,                      // fn(*WorldState, f64) void        → K2 typed
        .query = WorldState.query,                    // fn(*WorldState, *Call) E!JSValue → K2 managed
    },
    .getters = .{ .time = WorldState.time },          // fn(*WorldState) f64             → K3 typed
    .setters = .{ .gravity = WorldState.setGravity }, // fn(*WorldState, f64) void
});
const world_class = try ctx.defineClass(World, .{ .global_name = "World" });
const obj = try world_class.create(ctx, state_ptr);   // JSValue
const st: ?*WorldState = World.unwrap(obj);           // class_id 检查 + 固定偏移
```

### 9.3 再入

```zig
var site = try zjs.CallSite.init(ctx, handler_value, this_value);   // 解析一次，pin
defer site.deinit();
for (events) |ev| {
    const r = site.call1(zjs.value.int32(ev.code));
    if (r.isException()) { /* ctx.takeException() */ }
}
```

`JSContext.callFunction` 保留为便利包装（内部临时 `CallSite`），文档
标注「高频用 CallSite」。

### 9.4 属性访问（宿主侧）

`zjs.host.PropName`（预 intern 的 atom）保留；新增 `zjs.PropertySite`：
`init(ctx, name)` + `get(obj) JSValue` / `set(obj, v)`，内部带一个
单条目 shape 缓存（与 W1 条目同形），让宿主读 JS 对象字段也享有 IC。

### 9.5 旧宿主 API：不保留、不过渡（D8 裁决）

`defineGlobalFunction` / `createExternalFunction` / `zjs.host.Call` /
`zjs.host.Function` / `zjs.host.Finalizer` / `ExternalCall` 在阶段 A
**直接删除**，公开面快照同 commit 更新；`zjs_boundary_bench.zig`、测试
helper 与 fun 在同一窗口迁到 §9.1–9.3（fun 的 `NativeFunction.wrap`
整层删除，由 `zjs.native.managed/leaf` 取代）。不提供适配器。

---

## 10. 删除清单

| 删除 | 替代 |
|---|---|
| `ExternalCall` / `ExternalCallFn` / `ExternalRecord` / `registerExternalHostFunction` 注册表 / `external_host_record` / `externalHostDirect` / `throwExternalHostError`（`host_function.zig:68-83`、`runtime.zig:2967-3000`、`builtin_dispatch.zig:255-344`）+ 公开 `defineGlobalFunction` / `createExternalFunction` / `zjs.host.Call/Function/Finalizer/FunctionOptions`（阶段 A，无过渡，D8） | `NativeEntry` + `zjs.native.managed` |
| `InternalRecord` / `InternalRecordTable` / `NativeCProto` 12 种 / `dispatchTypedRecord` / `callTypedInternalRecordDirect` / `callInternalRecordDirectWithEnvironment` / `NativeCallEnvironment` / `active_native_call` / `nativeCall()` 重建 | `NativeEntry.kind` + `vm_native.dispatch` + `Call` 参数显式传递 |
| `ExecDirectCallFn` 8 参 ABI | K0 签名 |
| `HostError!JSValue` builtin ABI（迁移完成后） | `callconv(.c) JSValue` 哨兵 |
| `ValueRootFrame` 在 native 调用路径上的使用（`callTypedInternalRecordDirect:821-827`） | 窗口根 + 保守扫描；仅宿主切片保留 |
| `callNativeCallableByName` / `arrayMethodFastCall` 名字匹配 / `native_dispatch_name` | entry 身份 |
| `NativeBacktraceScope` | 内联 2 字标记 |
| `runtime/plugin.zig` + `binding/ffi.zig` `CallFrame`/`Trampoline`（已 deprecated 2026-08-25） | FNABI loader（fun 侧）→ `NativeEntry` |
| `HostInvocation` 与 `SyncInternalCallSite` 双轨 | `CallSite` |
| `nativePlainFastDispatch` / `nativeMethodFastDispatch` / `callRecordFromVmInRealm` 及其 `.space` 布局墓碑 | `vm_native.dispatch` |

净效果预期：`builtin_dispatch.zig`（~950 行）+ `call.zig` 宿主臂 + `plugin.zig`
+ `ffi.zig` 的大部分 → 减少约 2,000 行；`vm_native.zig` 新增约 600 行
（多数是 comptime 生成）。

---

## 11. 与既有契约的对账（偏离项）

| 文档 | 条款 | 本设计 | 性质 |
|---|---|---|---|
| FNABI §14.4 / 冻结项 18 | managed fixed `fn0..fn4(ctx, a0..)` 是机器 ABI | 机器 ABI 只有 `(ctx, this, argv, argc, entry)`；fixed 是 SDK 层 | **偏离**，D1 |
| FNABI §14.1 / §15 | 叶签名清单与 marshal policy | 沿用；新增 `SELF_*`、`STRING_VIEW`、叶 fallback | 扩展 |
| FNABI §17.2 / 冻结项 41 | call-site quickening + 纪元校验 | §5.5 落地 quickening；guard 用活对象的 entry 指针而非纪元，entry 退休 = tombstone（纪元只管 JIT 代码块） | 落地，机制微调 |
| FNABI §17.3 0.3 补充 | native getter/setter v1 走慢路 | 进 W1 IC | **提前**，D3 |
| FNABI §18.1 规则 2/3 | managed 调用有 handle scope | **无** handle scope，根靠窗口 + 保守扫描 | 收紧（更简单） |
| FNABI 冻结项 43 | v1 不要求存量 builtin 全量迁移 | 全量经 comptime 适配器迁移（零手工） | **偏离**，D5 |
| FNABI §28.1 / 冻结项 42 | 旧 plugin ABI 由 fun 在 M3 后接管 | 现在删除 zjs 内 loader | D4 |
| 表示契约 v3 §4 | 保守扫描为生产设计 | 升为边界前提（C2） | 加强 |
| 表示契约 §5.2 | 侧表缓存非持有引用 | `CallSite.route`、`PropertySite` 缓存遵守 | 遵守 |
| hermes-parity-plan W1 | get_field 缓存条目 = shape identity + slot + proto arm | +`native_getter/native_setter` kind 位 | 依赖，需在 W1 规格里加一行 |
| opcode-design §0 | 243/13 | +5 quickened 调用指令（§5.5，判决实验达线才提交）+ 调用指令 +1 B cache_idx | **偏离**，D2 复议已批方向 |
| engine-evolution-plan §5.3/§5.5/§7.3 | `VmExecState` / `HelperDescriptor` / publish 点 | native-call helper 以 `VmExecState` 为参数、登记 `HelperDescriptor`；`effect` 与之同语义（§15 R2/R4） | 消费；NB2 先落其 native-call 子集（D9） |
| FNABI §33 M6 / §17.5 | JIT：call-site profiling、direct target patching、entry/image generation guard、typed speculation + deopt | R1/R3/R6/R10 现在预留结构；不发 stub | 提前预留，不提前实现 |
| public-api-contract | 168 个 JSRuntime 公开名 / 89 个 JSValue | 新增 `zjs.native.*`、`zjs.CallSite`、`zjs.PropertySite`；删旧 host 名（一个周期后） | 需更新快照测试 |

---

## 12. 验收尺

语料扩充（`tools/perf/native_boundary`）：

- A 组（跨引擎）不变，用于对手读数。
- B 组（嵌入面）新增：`leaf2`（`add(i,1)` 叶）、`leaf_state`、`method_typed`
  （`world.step(i)`）、`method_managed`、`getter_native`（`s += world.time`）、
  `getter_typed`、`site1`（`CallSite.call1`）、`site0`、`prop_site`
  （宿主读 JS 对象字段）；qjs 对照臂：`JS_NewCFunction` / `JS_CGETSET_DEF`
  / `JS_Call` / `JS_GetPropertyStr`。
- **反汇编验收**（FNABI §31.2/§31.3 的机器路径证据）：每种 kind 的 handler
  反汇编存证，`callTyped` 无 argc/argv 构造、无 switch、无 env；`managed`
  thunk 无 arena/scope。
- 门：`zig build test`、`mise run batch-gate`、test262 0 回归、Octane
  `mise run perf-screen` ≥ 0.95 回归门（perf-line 政策）。
- 验收线：§0 目标表的「目标」列；未达者按形态单列欠账，不阻塞其他形态。

---

## 13. 实施阶段

| 阶段 | 内容 | 产出可测项 | 估 |
|---|---|---|---|
| **A** | `NativeEntry`（含 R1/R2/R9 字段）+ `NativeFields` 改造 + builtin comptime 适配器 + `VmExecState` native-call 子集（R4，D9）+ `vm_native.dispatch`（K0/K4）+ `native_entry_epoch`（R6）+ `zjs.native.managed` + 删除 §10 前 7 行（含公开旧宿主 API，D8）+ harness/测试/fun 同窗口迁移 | host2/host0/hostm2 ≤ 30/20/35；builtin 读数不劣化；反汇编存证 | 5–7 人日 |
| **B** | K1/K2 叶 + 签名 schema 扩展（含 R3 `MachineSig` 列）+ `zjs.native.leaf/leafWithState` + Math/String 热 builtin 改叶 + 调用指令 cache_idx 编码与 `CallSiteCache` + §5.5 判决实验 → 5 条 quickened 指令 | abs ≤ 18、charCodeAt ≤ 40、leaf2 ≤ 15 | 4–6 人日 |
| **C** | `CallSite`（Route 含 `jit` 臂占位与 epoch，R6/R7）+ Machine 内嵌 `Vm` + 返回臂补齐 + builtin 回调合流 + `f.call/apply` 臂 + R5 标记 `extern` 化 | site1 ≤ 40、reduce ≤ 60、sort ≤ 70、f.call ≤ 60 | 5–8 人日 |
| **D** | `NativeObject`/`NativeType` + `zjs.native.Class` + 原生访问器 cell（R8 `extern`）+ 慢路；W1 落地后加 IC 臂 + R10 槽格式 | method_typed ≤ 20、getter_native ≤ IC+10 | 4–6 人日（+W1 协同 1–2） |
| **E** | 删除 ABI 1；FNABI v0.9 + 表示契约 v4 修订（旧 host API 与 plugin ABI 已在 A 删除） | 公开面快照更新；fun 端到端读数 | 3–4 人日 |

A → B → C 可串行由 driver 亲做（`driver-implements-directly` 政策）；
D 与 C 可并行（不同文件族）；E 收尾。总计约 4–5 周。每阶段末跑重门一次
（reduced-gates 政策）。

---

## 14. 裁决记录与待裁项（每项：问题 / 选项 / 得失 / 建议）

**owner 裁决（2026-09-06 晚）**：D0 = C（交错：NB2 A/B → W1 → NB2 C/D）；
D1 批；**D2 复议：允许新增字节码指令** → 方案见 §5.5（5 条 quickened
调用指令 + cache_idx 编码，判决实验达线才提交编号），方案本身待 owner
过目；D3 批；D4 批；D5 批；D6 批；D7 批；**D8 改为不保留、不过渡**
（§9.5 硬切，阶段 A 删旧 API，fun 同窗口迁）；D9 批。以下保留原始
论证供追溯。

**D0 是否现在开工。** 本设计约 4–5 周 driver 时间，与 Hermes 对标线的
W1（属性缓存）、E1（寄存器机归因）争同一个人。选项：A 边界先做（fun 的
两种主形态今天仍是 qjs 的 1.6–2.9×，是产品可感知的）；B W1/E1 先做
（Octane 综合分）；C 交错（NB2 阶段 A/B 先做，再 W1，再 NB2 C/D，因为
D 依赖 W1）。建议 **C**。

**D1 managed 机器签名只留一种。** FNABI 冻结了 0–4 参五种 C 原型
（每个参数按值进寄存器）；本设计只留 `(ctx, this, argv, argc, entry)` 一种，
「固定参数」变成 SDK 编译期便利。得：引擎只维护一条 handler、一种 thunk
生成器；速度不损失，因为参数本来就连续躺在 VM 栈上，读 `argv[i]` 是一条
load，而按值传 16 B 的值超过两个参数就要溢出到栈。失：偏离已冻结的
FNABI 第 18 条，要出 v0.9 修订；插件作者看到一种原型而非五种（更简单）。
建议 **批**。

**D2 第一阶段不加 opcode。** 把调用指令改写成专用 `call_native`
每次可省约 2–3 cycle（在 15–25 的预算里），但要花 2–4 个编号（账上只剩
13 个），且指令集重设计和 JIT 会再做一遍同样的事。得：不花编号、不做
两遍。失：每次调用慢 2–3 cycle，直到 JIT/指令集重设计。建议 **批**。

**D3 原生 getter/setter 进属性缓存。** FNABI 说 v1 里原生访问器走慢路
（每次读 `world.time` 是一次完整调用，比普通字段慢约 10×），高频要写成
方法 `world.time()`。本设计把它做成缓存能直接调用的特殊槽（JSC/Bun 的
做法）。得：宿主对象的属性和普通字段一样快，API 不必为性能扭曲成方法。
失：W1 属性缓存规格加一个臂（约 1–2 天）；本设计选了不改属性标志位布局
的实现方式，所以不动 qjs 对齐的 6 位 flags。建议 **批**，慢路先做，缓存
臂随 W1 落。

**D4 现在删旧插件 loader。** `runtime/plugin.zig` + `ffi.zig` 的 `.so`
插件 ABI 已于 08-25 宣告弃用，fun 零引用（已核对），zjs 内只剩导出和
测试夹具。得：少约 1,000 行、少一套要保持一致的 ABI、少一个 harness 臂。
失：若有第三方靠它加载 `.so`（目前没有）会断。建议 **批**。

**D5 存量 builtin 全部迁到新入口，旧 ABI 最终删除。** 约 700 个内建
函数是按旧签名（返回错误联合）写的。本设计用编译期适配器自动包装，
不逐个手改；FNABI 第 43 条原本说 v1 不要求全量迁。得：只剩一条路径，
删掉约 950 行分派层，所有 builtin 都走便宜路径，不再有「这个函数在哪条
路上」的问题。失：一次性影响 700 个函数，回归靠 test262（0/49778 门）
兜底；适配器本身要写对。建议 **批**，阶段 A 用适配器，阶段 E 删旧 ABI。

**D6 叶调用不出现在 `Error().stack`。** qjs 里每个 C 函数在栈追踪里
都是一帧；叶调用为了省 4–6 cycle 不压这一帧。实际不可观察：叶调用期间
不可能运行任何 JS，也不可能抛异常，所以没有任何时刻能采到这一帧；带
fallback 的叶在走 fallback 时仍压帧。得：叶调用预算达标。失：无。
建议 **批**。

**D7 native 调用本身不做中断检查。** 中断检查是超时 / Ctrl-C / 宿主取消
的机制：一个计数器在特定点递减，归零时检查。今天 zjs 在每次 native
调用都减一次（P3 加的），qjs 不做，只在 JS 循环回边和函数入口做。JS 循环
里调 native 仍然每圈在回边检查，所以响应性不变。得：每次调用省 2–3 cycle。
失：一个 native 函数自己内部死循环时不会被中断——qjs 同样如此，正则
引擎等长耗时内建自带检查。建议 **批**。

**D8 fun 改用 `zjs.native.*`，旧 `defineGlobalFunction` 保留一个周期。**
你已定 fun 按我们的方式来；这里只裁过渡方式。选项：保留一个发布周期
（fun 逐个函数迁，不需要一次性大改），或硬切（zjs 升级时 fun 必须已迁完）。
得/失：保留 = 旧路径多活约 3 周、多一个适配器；硬切 = 简单但两仓要同步
发布。建议 **保留一个周期**。

**D9 先落 `VmExecState` 的 native-call 子集。** `VmExecState` 是
引擎演进计划里「解释器和未来 JIT 共用的执行状态描述」，字段已写死但
尚未实现、也没排期。本设计的调用 helper 要以它为参数才算 JIT 就绪
（§15 R4）。选项 (a) 阶段 A 顺手实现它的子集（+1–2 天），作为
PERF-VMABI 的第一片；(b) 等 PERF-VMABI 整体做完再开工边界。得/失：
(a) 不被未排期项目卡住，若将来字段变动由版本常量在编译期报错；(b) 无
返工风险但边界工作无限期后置。建议 **(a)**。

---

## 15. JIT 预留：边界与 JIT 一体设计

owner（2026-09-06）：「如果后续要加 JIT，那么结合在一起，需要提前预留设计」。
本节把 baseline JIT（engine-evolution-plan Phase 2，`PERF-VMABI →
PERF-JIT-SPIKE → G1-JIT → PERF-JIT`）和未来 optimizing tier 在边界上
需要的东西列成 R1–R10，每条都指出：本设计在哪个结构里**现在**就预留、
JIT 到来时怎么用、对应哪家引擎的证据。原则：**JIT 不引入第二套边界；
它只是把 §5/§6 的 handler 从「解释器调用的 helper」变成「内联进机器码
的序列」**，`NativeEntry`、`CallSite`、`native_accessor` cell 三个结构
是两个 tier 的共同输入（engine plan 四层图里「Native direct calls」正是
解释器与 baseline JIT 共享的一层）。

### 15.1 JIT 到来时的边界形态

baseline JIT 对一个单态 native 调用点发射（AArch64 示意）：

```
; guard：callee 身份（反馈槽/IC 记录的函数对象或 entry 指针）
ldr  x8, [callee_obj, #off(nativeFields.entry)]
cmp  x8, #imm(entry)              ; 或 ldr x9,=entry ; cmp
b.ne slow_call                    ; 慢路 = bl vm_native.dispatch（helper）
; K1 叶（sig I32_I32_TO_I32）内联：tag 检查 + 拆箱 + 直接调用 + 装箱
ldr  x0, [window, #0]  ; a0 tag/payload 已在寄存器则省
cmp  tag0, #TAG_INT ; b.ne fallback
cmp  tag1, #TAG_INT ; b.ne fallback
bl   target                       ; 地址嵌入常量（direct target patching，FNABI M6）
mov  tag, #TAG_INT ; stp payload, tag, [dst]
; K0 managed：bl callManaged 或内联 §5.2 步骤 1–7（写 backtrace 标记、bl target、cmp tag,#TAG_EXC）
```

optimizing tier 再加类型推测：参数已知为 double 时省 tag 检查直接进
`d0`（V8 Fast API / JSC DOMJIT 的做法），`fallback` 成为 deopt 点；
`effect` 标注为纯的叶调用可 CSE / hoist（JSC `DOMJIT::Effect`、V8
`SideEffectType`）。

native → JS 方向：`CallSite.Route.jit` 臂让宿主和 builtin 回调直接
`blr` 进机器码；帧仍是 Machine 的 `Entry/Frame/Stack`（engine plan
「解释器与 baseline JIT 共享 frame layout」），所以 `.native_boundary`
返回、`traceStack`、backtrace 都不需要按 tier 分支。

### 15.2 预留清单 R1–R10

| # | 预留 | 现在落在哪 | JIT 怎么用 | 证据 |
|---|---|---|---|---|
| **R1** | `NativeEntry` 是 `extern struct`，偏移由 `tools/gen_vm_offsets.zig` 生成，地址稳定（arena 内不搬、不复用） | §3.1 | 机器码按固定偏移读 `target/kind/sig/class_id`，或把 `target` 嵌成常量并做 direct patching | JSC `NativeExecutable::offsetOfNativeFunctionFor`、Bun `offsetOfWrapped()`、engine plan §5.3 规则 1 |
| **R2** | `NativeEntry.effect: Effect{may_throw, may_alloc, may_reenter_js, reads_heap, writes_heap}`，与 `HelperDescriptor{can_gc, can_throw, can_reenter_js}` 同一语义；叶 = 全 0；Debug 在 thunk 出口断言声明与实际一致（helper 入口断言文化） | §3.1 | 决定调用前后是否 publish/reload、是否发异常检查、是否 safepoint、能否 CSE/hoist | JSC `DOMJIT::Effect`（`domjit/DOMJITEffect.h:30-73`）、V8 `SideEffectType` + `NoProfiling` 协议、engine plan §5.5 |
| **R3** | 签名 schema（`fun_native_abi.zig` `signatures`）每条附 `MachineSig{ args: [N]ArgClass(i32/i64/f64/ptr/view), ret: RetClass }` | §4.2；schema 加一列，不另建表 | 推测后直接把值放 `w/x/d` 寄存器调用；`ArgClass` 决定拆箱序列 | V8 `CTypeInfo`（`v8-fast-api-calls.h:222-296`）、JSC `DOMJIT::Signature` `SpeculatedType arguments[]`、Static Hermes `convertToNativeArg`（`SH.cpp:2601-2641`） |
| **R4** | `vm_native.dispatch / callManaged / callTyped` 以 `*VmExecState` 为参数、返回 `VmHelperStatus`，不依赖解释器 `*Vm`；三者登记 `HelperDescriptor` | §5.2 | baseline JIT 第一天就能 `bl` 这些 helper（慢路 / 未内联形态）；之后按 kind 逐个内联快臂 | engine plan §5.3–5.5；Hermes `NativeFunction::_jitCallImpl`（`Callable.cpp:1199-1227`）就是「JIT 调同一个 helper」 |
| **R5** | managed 调用的 backtrace 标记是 `extern struct ActiveBacktraceFrame` 固定布局（2 字 + 链指针）；JIT 帧沿用 Machine `Frame/Stack` 布局；JIT 机器帧内的寄存器溢出由保守扫描覆盖 | §4.7 / §5.2 步骤 4 | 机器码写同样两字；unwinder / `Error().stack` / `traceStack` 不分 tier | JSC native 帧 `CodeBlock=0` 统一走栈（`LowLevelInterpreter64.asm:2725`）、V8 `V8_ENABLE_DIRECT_HANDLE` ⇒ 保守扫描（`handles.h:383-386`） |
| **R6** | `JSRuntime.native_entry_epoch: u32`：owner 退休任何 entry / NativeType 时 +1；`CallSite.route` 记录解析时 epoch，`call` 时一比较；缓存的 entry 指针是非持有引用（表示契约 §5.2） | §6.1 | JIT 代码块记录编译时 epoch，不等 = 整块作废（watchpoint 形）；hot reload 经此通知 JIT retirement（FNABI M6） | FNABI §17.2 纪元校验、冻结项 41、M6「exact entry/image generation guard」 |
| **R7** | `CallSite.Route.jit` 臂：`{ code: JitEntryFn, func, closure, frame_words }`，与 `bytecode` 臂共用 Entry 压栈；tier transition 是 publish 点 | §6.1 | 宿主 / builtin 回调直接 `blr code`；返回仍走 `.native_boundary` | JSC `CachedCall.m_addressForCall` 缓存的就是 JIT 入口（`CachedCall.h:108`）、Hermes `getJITCompiled()` 分支（`StaticH.cpp:431`） |
| **R8** | `NativeAccessorCell` 是 `extern struct` 固定偏移；IC 条目的 `native_getter/native_setter` 位与 W1 条目同布局 | §8.2 | IC 快臂内联：溢出保存 + 3 寄存器 + `bl get` + 一次异常检查 | JSC `CustomAccessorGetter`（`InlineCacheCompiler.cpp:3265-3392`）、V8 `LoadHandler::kNativeDataProperty → CallApiGetter` 尾调 |
| **R9** | `NativeEntry.builtin_id`（静态表下标）稳定；builtin 表顺序进 ABI 指纹 | §3.1 | JIT 按 id 识别 `Math.abs/floor/…` 做 intrinsic 化（省调用），不需要第三方 intrinsic ABI | JSC `Intrinsic`（`Intrinsic.h`，`DFGByteCodeParser.cpp:2902`）、Hermes `CallBuiltin` + `builtins_[]`；FNABI 冻结项 40 |
| **R10** | 反馈槽 = §5.5 `CallSiteCache{entry, handler, misses, state}`，与 W1 属性缓存条目同一分配 | §5.5 已是真实采集（quickening 状态） | baseline JIT 编译时读槽：`mono` 站点直接发 guard + 内联臂，`mega` 发 helper 调用 | engine plan §8.5 JitMeta 挂载策略、V8 `CallIC` feedback |

### 15.3 现在不做的

- 不发可执行内存 stub / trampoline（FNABI §17.5）。
- 解释器级 call-site quickening 按 §5.5 做（D2 复议），但不发可执行内存。
- 不给第三方开放 intrinsic ABI（冻结项 40）；R9 只对 builtin 表。
- 不为 JIT 改 `JSValue` 表示（表示契约 v3 §1.1 硬承诺）。

### 15.4 与 PERF-VMABI 的关系（D9）

R4 要求 native-call helper 以 `VmExecState` 为参数，而 `VmExecState`
是 PERF-VMABI（engine plan Phase 0）的交付物，roadmap 上它是
`PERF-JIT-SPIKE` 的前置、与本设计无依赖边。两条路：

- (a) NB2 阶段 A 先落 `VmExecState` 的 native-call 子集（`sp/fp/var_base/
  function/ctx/exit_*`，engine plan §5.3 原样字段，`VM_ABI_VERSION`
  照写），作为 PERF-VMABI 的第一片交付；PERF-VMABI 后续补全其余 helper。
- (b) 等 PERF-VMABI 整体落地后再做 NB2 阶段 A。

建议 (a)：字段定义已在 engine plan 里写死，NB2 只是第一个消费者，
不会产生双轨；(b) 会把边界工作押在一个尚未排期的项目后面。

### 15.5 JIT 目标读数

§0 两张表的「JIT 目标」列即本节的验收预期：JS → native 叶 ≤ 6–8 cyc
（guard + 拆箱 + `blr` + 装箱，与 V8 TurboFan Fast API 同量级）、
managed ≤ 20、宿主 → JIT 代码 ≤ 25、builtin 回调 ≤ 25–35。这些数字在
G1-JIT 裁决时用 PERF-JIT-SPIKE 的原型重新标定。

---

## 16. 执行进度与读数（2026-09-06 夜，owner「并行开工」后）

已合入 main（按顺序）：A2 `67036eaa`（NativeEntry 取代 InternalRecord，
comptime 适配器让 700 个 builtin 零改动进入）、lane H `a5e47aee`（语料 +9
臂，qjs 对手读数）、A3 `4a669610`（`zjs.native.managed` / `Call` / `Spec` /
`Options`、`defineFunction` / `createFunction`、每函数 NativeEntry；旧 host
API、外部注册表、runtime plugin ABI 全删，D4/D8）、lane Q `2c6a231c`
（cache_idx 编码 + `CallSiteCache`）、A4 `69a5ada1`/`7df5dcb7`
（`vm_native.dispatch` 单一分派、D7 去 tick、8 个 exec_direct 体改 K0）、
B1 `2762bd29`（`zjs.native.leaf/leafWithState`，9 种签名，schema 追加
`STATE_I32_TO_I32`）、B2 `d60d7491`（叶臂前置）、lane C `ad7b0bc6`
（CallSite + Machine 内嵌 Vm）、**B3 `84d5e28b`（op_call*/op_call_method
内联叶臂）**、`080cb682`（callFunction 去根帧，site 臂走 CallSite）。
每步 `zig build test` 24/24；A2/A3/lane C 合入点 `mise run batch-gate`
全绿；test262 0/49778。

### 16.1 读数（cycles / insn 每次穿越，4 样本 ABBA，CPU 19；对手 = qjs）

| 形态 | 09-06 下午（P1–P4） | 现在 | qjs | 目标 | 状态 |
|---|---:|---:|---:|---:|---|
| `abs(i)` 自由调用 | 33 / 219 | **2 / 53** | 26 / 122 | ≤ 18 | ✅ 超 |
| `Math.abs(i)` 方法形 | 61 / 302 | **18 / 102** | 49 / 194 | ≤ 30 | ✅ |
| 宿主 typed 叶 `add(i,1)` | — | **7 / 83** | 34 / 165 | ≤ 15 | ✅ |
| 宿主 typed 叶 + state | — | **11 / 77** | 27 / 117 | — | ✅ |
| 宿主 managed `host_add` | 56 / 319 | 39 / 252 | 34 / 165 | ≤ 30 | 差 5 |
| 宿主 managed 0 参 | 54 / 294 | 35 / 224 | 22 / 88 | ≤ 20 | 差 13 |
| 宿主函数作方法 `host.add` | 78 / 395 | 61 / 294 | ≈35 | ≤ 35 | 含属性读取 |
| `world.query(i)` managed 方法 | — | 56 / 272 | 52 / 202 | — | 到线 |
| `max(i,1,2)` | 29 | 33 | 34 | ≤ 25 | 到线 |
| `charCodeAt` | 64 | **27 / 187**（lane K） | 57 / 352 | ≤ 40 | ✅ |
| `codePointAt` / `charAt` / `at`（lane K 新增语料） | 69 / 230 / 118 | **27 / 77 / 83** | 58 / 90 / 95 | — | charAt/at 余量 = 单字符串分配 |
| `hasOwnProperty` | 83 | 90 | 99 | ≤ 60 | 属性查找 |
| `push/pop` | 78 | 76 | 83 | ≤ 50 | 到线 |
| `f.call` / `f.apply` | 114 / 227 | 117 / 217 | 81 / 135 | ≤ 60 / 100 | 待 §5.4 |
| forEach / reduce / map / sort 回调 | 114/159/204/140 | **99/98/182/109** | 69/67/148/78 | ≤ 60/60/90/70 | lane R 精简帧后（reduce 803→503 insn） |
| 宿主 → JS 一次性 `callFunction` | 137 / 614 | **73 / 412** | 48 / 297 | ≤ 40 | lane R（host 缓存精简帧） |
| 宿主 → JS `CallSite.call1` | — | **65 / 331** | 48 / 297 | ≤ 40 | lane R 精简帧 |
| 宿主 → JS 0 参 | 120 | **61 / 53** | 28 | ≤ 30 | 同上 |
| 宿主读 JS 字段 `prop_site` | — | 61 / 373 | 46 / 314 | — | 待 PropertySite |

### 16.2 D2 判决实验结论

§5.5 的两种形态都做了：(a) `CallSiteCache` 守卫（slot.entry + state）
内联叶臂 → `abs(i)` 72 insn；(b) **直接读活对象 entry 并测 kind** 内联叶臂
→ 53 insn。(b) 更好，因为 (a) 的守卫本来就要读同一个 entry 指针，再多走
slot 链。**结论：叶形态不需要新 opcode，也不需要调用点缓存**；managed
形态的 +2 cyc（kind 探测）和 `call_native` 专用指令能省的量级相同（≈ 2–3
cyc），不值 5 个编号。lane Q 落地的 cache_idx 操作数（+5.84% 字节码、
CodeLoad −1.1%）解释器目前不用，只为 JIT 反馈槽（§15 R10）保留——
**去留待 owner**。

### 16.3 还欠的（按收益排）

1. **再入精简帧**——lane R 已落地 `inline_calls.LeanFrame`（站点持有、
   一次初始化的 Entry：几何/所有权/teardown 固定，每次调用只做 carve、
   参数 pinned 拷贝、窗口指针、一次深度/字节预算、链接；fence 返回臂
   `popReturnedLean` = arena restore + 预算回退 + 解链）、`op_return` 的
   返回值改两条独立 `ldr`（合并成 `ldp` 的 16 B 访问在 add 只写 payload
   字后不能转发）、reduce 的 dense fast-array 元素臂、host 调用的 publish /
   unpublish 收到链表两写、`callFixedInto` 定元数臂。读数：CallSite.call1
   81→65、0 参 72→53、一次性 73/61、forEach 116→99、reduce 148→98、sort
   126→109（qjs 48/28/69/67/78）。**仍高于目标（40/30/60/60/70）**，余量
   归因（cycles 份额，site1）：`callFixedInto` 50%（序言/尾声 28 insn +
   0x270 栈帧、scope + publish + carve + 12 个窗口字段 + publishPushedEntry
   9 store + 首指令三级依赖链）、`op_return` 16%（序言 7 store + 每次返回
   的 `pending_call_region` TLS 探针 ~10 insn + 分类）、`add` 17%、bench
   循环 8%；builtin 回调另付 `NativeBoundaryScope` 快照 32 insn + 段视图
   backtrace 节点 ~16 insn。零分支预测失误（0.01/次），IPC 5.0 vs qjs 6.1：
   差距是依赖链长度，不再是指令数。下一刀：把 `Vm` 每级字段在 host 空闲
   机上跨调用保留（省 publishPushedEntry）、`retreatToCallRegion` 改为把
   窗口挂在 Entry 而非 threadlocal（省 op_return 的 TLS 探针）、把 lean
   返回臂做成不需要保存 callee-saved 寄存器的独立 handler。
2. ~~`charCodeAt` 等原始值方法的 K2 `prim_self` 叶（§4.3）~~ —— lane K 落地
   （分支 nb2/k2）：`Kind.method_leaf` + schema 追加 `STRING_I32_TO_I32` /
   `STRING_I32_TO_STRING`（C 原型同为 `fn(*const String, i32) i32`，负值 =
   走 fallback），`InternalEntry.prim_leaf` 声明，旧 handler 原样成为
   `fallback`；`op_call_method` 内联臂多一个 `.method_leaf` 分支（臂体
   `invokeMethodLeafFastEntry` 出线，op_call_method 0x2078 → 0x1ff4）。
   charCodeAt 65 → 27 cyc（qjs 57）、codePointAt 69 → 27、charAt 230 → 77
   （qjs 90）、at 118 → 83（qjs 95）。charAt / at 的余量是每次
   `createLatin1` 单字符串分配（≈ 50 cyc）：运行时级单码元字符串缓存
   （qjs 无，V8/JSC 有 single-character string table）是下一刀。
   Number.prototype 未加：toString/toFixed 都要分配且不是热形态。
3. `f.call` / `f.apply` 窗口重排臂（§5.4）。
4. managed 0 参 35 vs 22：`callRecordFromVmInRealm` 的预检 + backtrace
   标记 + realm 读 + thunk 参数整理；`coldNext` 改直达 `next`。
5. ~~阶段 D：`NativeObject` / `zjs.native.Class`~~（lane D 落地，§16.4）；
   `native_accessor` cell 的 IC 臂随 W1（§16.4 记录了 cell 的替代形态）。
6. 文档：`docs/public-api-contract.md`、`embedding-cookbook.md`、
   `api-boundary.md` 仍写着旧 host API / plugin surface，待改写为
   `zjs.native`。

### 16.4 lane D：`NativeObject` / `zjs.native.Class` / K2 / K3（2026-09-06 夜）

落地（branch `nb2/class`）：

- **`NativeObject`**（§8.1）：`src/core/native_object.zig`。实例 = 动态 class id
  的普通对象，payload arm 字（`Object` 头后固定偏移 24）= 不透明 `self`
  （null = disposed）；`ObjectFlags.is_native_object` 一位标家族，
  `Object.nativeSelf` = 一位测试 + 一次 load，`nativeSelfAssumeClass`
  = 一次 load（K2 已比过 class id）。`NativeType { class_id, name,
  finalize, owner }` 由 `registerType` 每 runtime 分配一次，挂在 class
  record（`Record.native_type`，class 表在最终 sweep 之后释放它）；
  finalizer 走既有 class `payload_finalizer` 通道（sweep / teardown，
  runtime 线程）。class id 来自进程级 `ClassIdSlot`（每个 comptime
  Class 一个静态槽，跨 runtime / reload 复用，hot-reload §0.2）。
- **`zjs.native.Class(spec)`**（§9.2）+ `JSContext.defineClass(C, .{
  .global_name })` → `C.Handle { create(ctx, *Self) !JSValue, unwrap,
  dispose, prototype }`，`C.unwrap(value) ?*Self`。方法 / 访问器是原型
  上的普通属性（writable / configurable / 非枚举，qjs `JS_CFUNC_DEF` /
  `JS_CGETSET_DEF` 形）；构造器是拥有 `prototype` 的 host entry（现有
  `constructExternalHostFunction` 路径，`new.target.prototype` 原样继承，
  子类 `class Sub extends World` 直接可用）。
- **K2**：`method_leaf`（`fn (*Self, i32) i32` 等 7 个 `SELF_*` 形，schema
  追加 `SELF_I32_TO_I32` / `SELF_TO_I32` / `SELF_I32_TO_VOID` /
  `SELF_TO_VOID` = 27–30，header 已再生）与 `method_managed`（`fn (*Self,
  *Call) E!JSValue`）两臂进 `builtin_dispatch.invokeEntry` /
  `callRecordFromVmInRealm`；`op_call_method` 的内联叶臂加了
  `.method_leaf` 分支（receiver class id 比较 + `self` load + K1 marshal）。
- **K3**：typed getter / setter（`fn (*Self) f64|i32`、`fn (*Self, f64|i32)
  void`）是 `sig != 0` 的 `.getter` / `.setter` entry，VM 侧 typed 臂做
  class 检查 + unwrap + 装箱，叶合同（无预检 / 无 backtrace 标记）；
  managed 形走 `GetterFn` thunk。慢路直达：`op_get_field` 的 own-miss
  尾（`ordinaryAccessorGetterAfterOwnMiss` 一次重探 + 原地调用，不再经
  cached_getter / 通用 call / coldNext）、`op_get_field_property_tail`、
  `object_ops` 原型链读、`call_runtime.callAccessorSetter`。
- **`NativeAccessorCell` 的裁决**：没有做「非对象 header 进 accessor
  slot」的 cell。理由：`Accessor.getterValue()` 的 ~12 个消费点（描述符、
  defineProperty 校验、四条 exec 读路径、typed-array / RegExp 内建判别）
  都把 getter 当可调用对象取 `Object.fromHeader`，一个漏改点就是 UB，而
  test262 覆盖不到嵌入类；cell 要带的字段（get/set 指针、typed sig、
  class_id）`NativeEntry` 本来就全有 —— **K3 函数对象就是 cell**，同一性
  与描述符物化不需要任何额外机制（`getOwnPropertyDescriptor(...).get`
  两次读同一对象，见测试）。W1 的 `native_getter` 缓存位可以直接读
  `entry.kind == .getter` / `entry.sig`。
- 顺手：`op_get_var_field` 的冷腿先跑 `op_get_var` 同款全局对象 own-data
  探针再直入 `op_get_field`（此前每次 `globalObj.field` 都走
  `getVar` 瀑布 + coldNext；`op_get_var` 本体字节不变 0x160）；
  `is_native_object` receiver 进 `getFieldFast` 阶段 1 /
  `atomPropertyValueForFastPath` / `ordinaryDataPropertyLookup` 的
  ordinary 准入集（同 plain object，无 exotic）。

读数（`sample_embed.py` 4 样本 ABBA，CPU 19；`reports/evidence/
NATIVE-BOUNDARY/embed-after-lane-d-2026-09-06.csv`）：

| 形态 | zjs insn / cyc | qjs | 目标 | 备注 |
|---|---:|---:|---:|---|
| `world.step(i)` K2 typed | 150 / 28 | 236 / 60 | ≤ 20 | 含 `world` 全局查找 + 原型探针；qjs 的 2.1× |
| `world.query(i)` K2 managed | 312 / 67 | 202 / 53 | ≤ 52 | 比同 managed 的 own 属性形（56）多一次原型探针 |
| `world.time` K3 managed | 288 / 62 | 195 / 53 | get_field+10 | `callRecordFromVmInRealm` 预检 + backtrace + thunk |
| `world.time` K3 typed | 247 / 50 | 195 / 53 | get_field+10 | VM 侧 typed 臂，叶合同 |

未到目标的账：K2 typed 的 28 里 `op_get_var`（`world` 全局对象属性）+
`op_get_field2`（原型探针）占大头，`Math.abs(i)` 方法形 18 的差就是那
次原型探针；K3 的 ~50 里两次 shape 探针（own miss 走 + accessor 重探）
+ 全局查找 ≈ 30，剩下是 typed 臂 ≈ 15 —— 再往下要 W1 的 IC 臂
（shape identity + slot + `native_getter` 位）。

### 16.5 并行第二轮合并后读数（2026-09-06 深夜，main `26b38359`）

五条 lane（R 再入精简帧、K 原始值方法叶、F call/apply 转发臂、D 原生类与
访问器、Docs）全部合入，`mise run batch-gate` 全绿，test262 0/49778。
每次穿越 cycles / insn，4 样本 ABBA，CPU 19；括号内 qjs。

| 方向 / 形态 | 09-06 下午 | 现在 | qjs | 目标 |
|---|---:|---:|---:|---:|
| JS→native `abs(i)` 叶 | 34 | **2** / 53 | 27 / 122 | ≤ 18 ✅ |
| JS→native `Math.abs(i)` | 60 | **17** / 105 | 50 / 194 | ≤ 30 ✅ |
| JS→native `charCodeAt` | 64 | **26** / 189 | 56 / 352 | ≤ 40 ✅ |
| JS→native `charAt` / `at` / `codePointAt` | 223 / 120 / 71 | 76 / 83 / 25 | 90 / 94 / 58 | — ✅ |
| JS→native `max(i,1,2)` | 31 | 32 | 34 | ≤ 25 |
| JS→native `hasOwnProperty` / `push,pop` | 86 / 78 | 90 / 80 | 99 / 83 | 属性查找账 |
| JS→native `f.call` / `f.apply` | 114 / 228 | **90 / 112** | 82 / 136 | ≤ 60 / 100 |
| JS→native 宿主 typed 叶 / +state | — | **7 / 11** | 35 / 28 | ≤ 15 ✅ |
| JS→native 宿主 managed `host_add` / 0 参 | 56 / 54 | 40 / 36 | 35 / 23 | ≤ 30 / 20 |
| JS→native 原生类 typed 方法 `world.step(i)` | — | **35** / 187 | 59 / 236 | ≤ 20 |
| JS→native 原生类 managed 方法 | — | 66 | 53 | ≤ 52 |
| JS→native 原生 typed getter / managed getter | — | **50 / 59** | 53 / 53 | IC+10（待 W1） |
| native→JS `callFunction(cb,[i])` / 0 参 | 137 / 120 | **75 / 62** | 48 / 28 | ≤ 45 / 30 |
| native→JS `CallSite.call1` / `call0` | — | **66 / 54** | 48 / 28 | ≤ 40 / 30 |
| native→JS forEach / reduce / map / sort 回调 | 115 / 159 / 203 / 141 | **100 / 99 / 184 / 111** | 69 / 67 / 148 / 79 | ≤ 60 / 60 / 90 / 70 |
| native→JS replace 回调（每次匹配） | 2453 | 2256 | 1304 | — |

JS→native 方向：叶形态全部领先四引擎（`abs` 2 cyc 是 V8-jitless 20 的十分
之一），managed 与 qjs 持平（40 vs 35），原生类 typed 方法 35 领先 qjs 60 但
未到 20。native→JS 方向：从 2.5–3× qjs 收到 1.3–1.9×，仍未到目标；lane R
归因是依赖链长度（IPC 5.0 vs 6.1），下一刀见 §16.3 第 1 项的三条。

## 附录 A. 起点读数（eval §6.1，2026-09-06 P1–P4 后）

见 `native-boundary-eval-2026-09-06.md` §6.1；§0 目标表「现」列即该表的
「后」列。

## 附录 B. 指令预算推导示例（K1 `abs(i)`，AArch64）

```
op_call 臂:   ldr callee; tag cmp; ldr class_id; cmp c_function; b       (5)
dispatch:     ldr nf; ldr entry; ldrb kind; adr+br jump table              (5)
callTyped:    ldr argv[0] tag; cmp int; b.ne float_arm; scvtf d0            (4)
              ldr target; blr                                               (2)
              fcvtzs / fcmp exact-int; box int or f64; str result; setLen  (6)
              b next                                                        (1)
                                                                    ≈ 23 insn
```

当前（P1–P4 后）`abs(i)` 219 insn / 33 cyc 的余量在 `callRecordFromVmInRealm`
的预检、backtrace、`dispatchTypedRecord` switch、`primitiveF64Arg`、
`numberToValue` 各层；上表是把它们全部按签名折进一条直线后的形状。
