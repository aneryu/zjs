# Fun Native Plugin 技术设计

版本：0.4（第一批：M1 里程碑纵向拆分,与 roadmap v1.5 对齐）  
日期：2026-08-26  
状态：评审修订版；完成 M0 后冻结 FNABI v1。**v0.4 第一批修订**:§33 的
M1 拆为 M1A/M1B/M1C(见该节),消除「M1 整体硬依赖 F1/F2/F4」——M1A
静态直调不需要 per-site 侧表,更早取得 plugin/builtin 同 NativeEntry 的
端到端证明。全局工作项 ID:FN-M0/FN-M1A/FN-M1B/FN-M1C/FN-M2..M6
(FN-M2 起对应本文 M2-M6 原编号)。**v0.4 剩余批次(开放欠账,见
process-model-design.md §20.2/§20.2a)**:class id 分配规则新章、无在飞
资源快速销毁路径与 finalizer 三态、循环事件通道原语(tsfn 对应物)、
外部内存计价必填、§18.1 handle-scope 留门措辞、§22.7 side-by-side
启用前提清单、epoch 作用域条款。  
适用范围：fun runtime、zjs VM、Fun Native ABI、Zig Native SDK、native package 构建与分发体系  
规范性引用：[vm-value-representation-contract.md](vm-value-representation-contract.md)（v1，normative）、[type-directed-optimization-plan.md](type-directed-optimization-plan.md)（v0.8）、[engine-evolution-plan.md](engine-evolution-plan.md)、[runtime-plugin-abi.md](runtime-plugin-abi.md)（deprecated，见 §28.1）

---

## 0. 版本变更

相对 0.2，本版按 2026-08-25 评审与 owner 四项裁决完成以下修订：

1. **移除 `FunValue`**（owner 裁决）：公开 ABI 不引入独立值类型，managed 边界直接使用 zjs `JSValue`（16 字节 extern tagged，`{ payload: u64, tag: i64 }`）。Value ABI 版本锚定表示契约版本与 `JSValue.abi_encoding_revision`。
2. **现行 `runtime-plugin-abi.md` 标记 deprecated**（owner 裁决）：FNABI 是继任者；zjs 内 `Plugin.load`/dlopen loader 随 M3 移交 fun 并移除。新增 §28.1 退役条款。
3. **时序挂钩 type-directed 计划**（owner 裁决）：M0（纯合同层）与 type-directed S0/S1 并行；M1 起硬依赖 S1 交付物（F1 shape identity、F2/Phase 0.5 侧表、F4 opcode 空间方案），共享基建只建一次；`NativeCallPlan` 与 T3 `NativeCallDescriptor` 归一为单一 schema。
4. **v1 不强制存量 builtin 全量迁移**（owner 裁决）：builtin/plugin 等价性验收改为「参照 builtin 对拍集」；存量迁移拆为独立分批计划，各批自带 zoo A/B、test262 与 I-cache 门禁。
5. 新增 §2.1「现状对账与前置依赖」：明确 quickening/IC/shape identity 为待建能力而非既有能力，列出交付载体。
6. guard/quicken 缓存的 callee/entry/type identity 增加**纪元/版本验证**强制条款（表示契约 §5.2；在册 ABA 前科）；补 quicken 同宽度编码约束与多态站点 backoff。
7. 补 arity 语义（缺参/多参）、native getter/setter 的 v1 状态、finalizer 队列 drain 时机（不得在 STW 停顿内执行插件代码）、Closing 态在飞调用的错误路径。
8. descriptor 结构消除隐式 padding（显式 reserved 字段并强制置零）；补 `FunPluginInitContextV1` 与 `NativeExportRegistration` 定义骨架并列入 M0 验收。
9. 多 runtime 共享 NativeImage 时 image 级全局数据的线程风险写入插件作者合同（§21.1）。
10. conservative native root 扫描的平台覆盖（现仅 AArch64-Linux）列为 tracing 权威期 × §32.6 平台矩阵的显式依赖。

11. 对抗性复审补丁：等价命题限定到「注册到统一 NativeEntry 的 builtin」（§1/§9/M6，消除与裁决 4 的残留冲突）；删除 0.2 的 `VALUE0-4` 签名家族（引用了未定义的「fixed Value」调用类别，fixed 参数的 JSValue 形态统一走 managed fixed）；C 头拼写条款（`zjs_JSValue` tag + 可关闭 `JSValue` 别名，防与 quickjs.h 撞名）；§19.5 补 RC/tracing 两形态析构时序合同；M0 验收扩为「全部前向引用 ABI 类型定案或显式 opaque」；§12.6/§32.2/§32.5 补验零、arity、非零 reserved 测试项。

0.2 的收敛内容（职责拆分、机器签名与 JS 语义分离、三类 Host capability、三层 artifact identity、纵向切片等）全部保留。

本文中的“必须”“不得”表示 FNABI v1 的强制要求；“应”表示默认实现要求；“可”表示兼容的可选能力。

---

## 1. 摘要

本文设计一套面向 fun 的高性能 Native Plugin 机制。其核心原则是：

> **Native Plugin 不是第二套 VM 调用机制，而是将 native package 构建、分发、加载并规范化为 zjs `NativeEntry` 的机制。**

完整链路为：

```text
Native package source
  ↓
Fun Native SDK / build adapter
  ↓
Native artifact
  ↓
fun artifact resolver / loader
  ↓
经过复制与验证的 NativeModuleRegistration
  ↓
zjs NativeEntry / NativeType / NativeFunction
  ↓
CALL_NATIVE_*
  ↓
Native target
```

对于相同的函数签名、JavaScript 语义和调用模式，plugin NativeFunction 与**注册到统一 NativeEntry 的** builtin NativeFunction 必须使用（0.3 裁决：存量未迁移 builtin 不在此命题内，见 §33）：

- 相同的 JS Function 对象类型。
- 相同的 `NativeEntry` 表示。
- 相同的 `NativeCallPlan`。
- 相同的 bytecode handler 或 JIT lowering。
- 相同的参数检查、unbox、receiver unwrap、异常和 GC 路径。
- 相同的 native target calling convention。

执行热路径不得根据 builtin/plugin 来源分支。但 fun 与 zjs 必须在冷路径保留 artifact、image、package、export、代码地址范围和生命周期 owner，用于保活、hot reload、profiler、stack trace、crash symbolication 与诊断。

因此，本设计追求的是：

> **执行路径等价，而不是抹除来源和生命周期信息。**

---

## 2. 背景与问题

传统 Native Plugin、FFI 或 compatibility ABI 常见路径如下：

```text
JS call
  ↓
JS Function
  ↓
Plugin wrapper
  ↓
argc / argv
  ↓
动态 signature 解析
  ↓
通用 dispatcher / libffi
  ↓
Native function
```

该模型的问题包括：

- 每次调用都可能检查 function kind、解析 signature 或进入通用 dispatcher。
- 固定参数仍通过 `argc + argv` 传递，primitive 需要重复 box/unbox。
- `this` 通常通过 opaque handle 或哈希表映射到 native object。
- 所有函数无条件建立 handle scope、exception frame 和 reentry bookkeeping。
- builtin 与 plugin 各自维护一套调用 ABI，plugin 永远多一层。
- 同一个 native package 在不同项目、workspace 或 runtime 版本下反复编译。
- 桌面、Android 和 iOS 形成不同的插件编程模型。
- loader、package manager 和 VM 执行逻辑互相耦合，ABI 很难稳定。

fun 不采用该模型。Native Plugin 必须直接建立在 zjs 的 NativeFunction、NativeObject、NativeType、bytecode quickening、inline cache 和 synthetic ESM module 能力之上。**注意：上述能力中 quickening、IC/guard 与 shape identity 在当前 zjs 中尚不存在，属于本方案的前置依赖而非既有事实**，交付载体见 §2.1。

### 2.1 现状对账与前置依赖（0.3 新增）

截至 2026-08-25 的 zjs 现状、与本方案假设的差距及交付载体：

| 本方案假设的能力 | zjs 现状 | 交付载体 |
|---|---|---|
| `JSValue` 16 字节 extern tagged、非搬移堆、调用内地址稳定 | **已成立**：表示契约 v1 硬承诺（§1.1/§1.2），`src/core/value.zig` 实物含 `abi_encoding_revision` | 直接引用，本方案是契约的登记利益方 |
| ESM module graph / synthetic module | 已有（`src/exec/module_graph.zig`） | 直接使用 |
| 统一 NativeEntry / typed native call | 无；builtin 走内部注册，现行 plugin ABI 为 `CallFrame` 形态（已 deprecated，§28.1） | 本方案 M1/M2 |
| bytecode quickening 与 per-site 缓存 | 无运行时 quicken 机制 | type-directed Phase 0.5 侧表（F2）+ 本方案 M2 |
| shape/prototype/callee identity guard | 无 IC；shape 无稳定身份（rc==1 原地变异 + relocate ABA，指针比对不 sound） | type-directed **F1 shape identity + F5 编译期 shape 注册**（硬前置） |
| 新 opcode 编码空间（~25 个 `CALL_NATIVE_*`） | short 区 178-253 已满，20-40 个新 id 现平面放不下 | type-directed **F4 opcode 空间方案**（二级平面/前缀 op，T-gate 0 定案） |
| conservative native root 扫描（tracing 权威期 managed 调用的根基础） | 仅 AArch64-Linux 实装；x86_64-linux/windows、aarch64-windows/macos 在显式未实现清单 | tracing 权威期前按 §32.6 平台矩阵补齐（跨计划工程量，显式列账） |

规范性引用关系：值与 GC 承诺以 `vm-value-representation-contract.md` 为准（修改协议 = 先改契约递增版本，再动任一线代码）；共享基建与时序以 `type-directed-optimization-plan.md` §六 执行序列为准（见 §33）；`runtime-plugin-abi.md` 的退役见 §28.1。

---

## 3. 设计目标

### 3.1 性能目标

对于同一个 native 实现，分别注册为 builtin 和 plugin 时，二者必须满足：

- 使用同一种 `NativeFunction`。
- 使用同一种 `NativeEntry`。
- 使用同一种 signature-specific handler。
- 热路径不读取 package、artifact、descriptor 或 dynamic library metadata。
- 热路径不执行 symbol lookup、signature string parsing 或 plugin kind 判断。
- typed leaf fixed-arity call 不构造 `argc/argv`。
- typed leaf call 不建立 general handle scope、JS call frame 或 exception frame。
- NativeObject method 通过固定偏移读取 `native_ptr`，不使用哈希表。
- SDK 生成的 C ABI typed thunk 直接作为 `NativeEntry.target`，不得再经过运行时 generic wrapper。

leaf typed call 的目标路径为：

```text
load JS argument
  ↓
JS semantic check
  ↓
unbox
  ↓
call typed native target
  ↓
box result
  ↓
continue VM dispatch
```

### 3.2 ABI 稳定目标

以下变化在公开 ABI 未变化时，不得要求 typed leaf plugin 重新编译：

- fun runtime 版本升级。
- zjs GC 内部实现变化。
- zjs module loader、scheduler、bytecode layout 或 IC layout变化。
- fun package manager、daemon 或构建器内部重构。

只有插件实际依赖的 ABI 层发生变化时，才允许失配：

```text
Plugin ABI
Fast Call ABI
Value ABI，可选
Target ABI
OS / libc / CRT deployment contract
CPU feature baseline
```

### 3.3 构建复用目标

同一 native package 在以下场景不得重复调用编译器：

- 被多个 fun 项目引用。
- 被同一项目的多个 workspace 引用。
- 删除项目本地构建目录后重新安装。
- fun runtime 升级，但已锁定 artifact 仍兼容。
- 多个进程并发安装相同 package。
- 已存在匹配的本地 CAS artifact 或 registry prebuilt。

### 3.4 开发体验目标

Zig 插件作者只编写业务函数、类型和导出声明，不手写：

- `argc/argv` 解析。
- primitive 类型检查与 box/unbox。
- C ABI thunk。
- constructor、method、getter/setter 和 finalizer glue。
- plugin/module/export descriptor。
- dynamic/static symbol visibility。
- TypeScript `.d.ts`。
- Android/iOS/desktop 平台差异代码。

### 3.5 生命周期与可诊断性目标

系统必须能够准确回答：

- 当前 NativeFunction 来自哪个 package、artifact、image 和 export。
- 哪个 `PluginInstance` 仍被 NativeObject、AsyncToken 或 buffer lease 保活。
- runtime shutdown 卡在哪个阶段。
- hot reload 后旧对象仍绑定哪个 image。
- native crash 地址属于哪个 artifact 和 build provenance。

---

## 4. 非目标

FNABI v1 不包含：

1. 第三方插件动态注册 VM intrinsic、bytecode opcode 或 optimizing JIT lowering。
2. plugin 与 `Math.abs` 等 VM intrinsic 完全等价。
3. 运行时安全 `dlclose`。
4. 将 native plugin 作为恶意代码沙箱运行。
5. native worker thread 直接访问 JS object、`JSValue`、Promise 或 callback。
6. 任意 C/C++ ABI 自动适配、libffi 或 Node-API 作为 canonical fast path。
7. 任意 JS object 跨边界零成本。
8. C++ exception、Rust panic、Zig panic 或其他语言异常跨越 FNABI 边界。
9. 32 位或 big-endian target。
10. 多 application realm 的独立 plugin state。
11. 任意签名组合自动生成专用 VM opcode。
12. `i64/u64` 与 JS Number 的隐式无损映射。
13. source build 的强安全沙箱；native package 和构建脚本均视为可信代码。

---

## 5. 术语

| 术语 | 定义 |
|---|---|
| JSValue | zjs 唯一值类型：16 字节 extern tagged（`{ payload: u64, tag: i64 }`，align 8），布局由表示契约 v1 冻结；引擎内部、嵌入 API 与 FNABI managed 边界共用同一类型，不存在 FunValue/PluginValue 中间表示 |
| Native package | 包含 native 源码、manifest、SDK 依赖和可选 JS wrapper 的 fun package |
| Native artifact | 某个 target、ABI、优化模式和 CPU baseline 下的已编译产物及 sidecar metadata |
| Artifact digest | 对最终产物内容计算的 BLAKE3 digest，用于 CAS 和 lockfile |
| NativeImage | artifact 在进程中的一次装载结果；包含代码地址、descriptor 和 loader handle |
| PluginDescriptor | image 暴露的稳定 FNABI descriptor |
| PluginInstance | 每个 `(zjs Runtime, NativeImage)` 创建的 runtime-local plugin state |
| NativeModuleRegistration | fun 验证 descriptor 后传给 zjs 的私有、规范化注册结构 |
| NativeBindingOwner | zjs 内部生命周期 owner，保活 PluginInstance 和 NativeImage |
| NativeEntry | zjs 内部统一的 native target 表示 |
| NativeCallPlan | zjs 内部预计算的 call kind、signature、marshalling 和 flags |
| NativeType | zjs 内部 NativeClass 类型身份及 method/finalizer metadata |
| NativeObject | 带 `NativeType` 与 `native_ptr` 的一等 JS object |
| AsyncToken | zjs 管理 Promise 状态、完成一次性和 runtime epoch 的异步令牌 |
| Buffer lease | 延长 ArrayBuffer/TypedArray backing store 生命周期并约束 detach/resize 的租约 |

---

## 6. “Builtin 等价”的精确定义

fun 中区分三类执行能力：

| 类型 | 实现方式 | Plugin 是否等价 |
|---|---|---:|
| JS Function | 创建 JS frame 并执行 bytecode | 不适用 |
| Native Function | 通过 `NativeEntry` 调用 native target | 是 |
| VM Intrinsic | bytecode/JIT 直接 lower 为机器指令 | v1 否 |

例如，若 `nativeAdd` 是普通 native builtin，则 plugin 可以使用同一 `NativeEntry` 和 `CALL_NATIVE_I32_I32_TO_I32` 达到相同执行边界。

若 `Math.abs` 已被 lower 为：

```text
ABS_F64
```

它不再是普通 native function call。允许第三方 plugin 注册同类 intrinsic 会将插件 ABI 与 compiler、bytecode 和 JIT internals 绑定，因此不属于 v1。

“等价”具体表示：

1. 同一 JS 可观察语义。
2. 同一调用类别和调用约定。
3. 同一参数检查与结果转换。
4. 同一 handler 或 JIT lowering。
5. 同一异常、GC 与 reentry policy。
6. 同一 receiver unwrap 路径。
7. plugin 不多出来源判断、descriptor dispatch 或 runtime wrapper。

“等价”不表示：

- VM 删除 package/image provenance。
- plugin 可以使用私有 intrinsic。
- plugin target 与 builtin target 的业务实现本身相同。
- 动态库加载和静态链接过程相同。

最终原则是：

> **构建与加载阶段区分 builtin 和 plugin；steady-state dispatch 不根据来源分支；冷路径始终保留 provenance 与 lifetime owner。**

---

## 7. 总体架构

### 7.1 四层结构

```text
┌──────────────────────────────────────────────────────────┐
│ fun-native-abi                                           │
│ 稳定 C ABI、descriptor、signature ID、flags、layout tests │
└──────────────────────┬───────────────────────────────────┘
                       │
          ┌────────────┴────────────┐
          │                         │
          ▼                         ▼
┌───────────────────┐      ┌──────────────────────────────┐
│ zjs               │      │ fun                          │
│ VM 执行与 JS 语义  │      │ package/build/load/lifecycle │
└─────────┬─────────┘      └──────────────┬───────────────┘
          │                                │
          └────────────┬───────────────────┘
                       ▼
             ┌─────────────────────┐
             │ Fun Native Zig SDK  │
             │ comptime binding 生成│
             └─────────────────────┘
```

依赖规则：

- `fun-native-abi` 不依赖 fun 或 zjs runtime。
- zjs 可依赖 `fun-native-abi` 的生成常量和 C layout，但不得依赖 package/build/loader。
- fun 依赖 `fun-native-abi`，并通过私有 source-level API 调用 zjs。
- Zig SDK 依赖具体版本的 `fun-native-abi`，但不依赖完整 fun runtime 源码。

### 7.2 构建与执行数据流

```text
package source
  ↓
Zig SDK 生成 typed thunk + descriptor + .d.ts
  ↓
fun build adapter
  ↓
artifact + artifact.json + provenance.json
  ↓
local CAS / registry prebuilt
  ↓
platform loader / static registry
  ↓
复制并验证 PluginDescriptor
  ↓
创建 PluginInstance
  ↓
构造 NativeModuleRegistration
  ↓
zjs.registerNativeModule(...)
  ↓
NativeFunction / NativeType / NativeEntry
  ↓
ESM binding / property IC
  ↓
CALL_NATIVE_*
  ↓
typed native target
```

### 7.3 v1 模块和 Realm 模型

FNABI v1 冻结以下约束：

- 一个 native artifact 对应一个 native ESM module。
- 一个 package 可以通过 JS wrapper 重新组织或重导出该 native module。
- 一个 fun runtime 对外暴露一个 application realm。
- `PluginInstance` 是每个 `(Runtime, NativeImage)` 一份。
- JS constructor、prototype、NativeFunction 和 ESM binding 由 zjs 在 application realm 内创建。
- zjs 内部若存在辅助 realm，不得直接 import 第三方 Native Plugin。

该约束避免 v1 引入 per-realm native state ABI。未来如需多 realm，可在不改变 `NativeEntry` 执行模型的前提下增加 `NativeModuleInstance` 生命周期层。

---

## 8. 组件职责边界

### 8.1 `fun-native-abi` 负责什么

`fun-native-abi` 是最小、独立版本化的二进制合同层，负责：

- Plugin ABI major/minor 常量。
- Fast Call ABI 版本。
- Value ABI 版本。
- C calling convention 和 target contract。
- descriptor、Host table、view、status 和 callback 的 C layout。
- export kind、call kind、signature、marshal policy 和 flag ID。
- dynamic descriptor symbol 规则。
- static registration symbol 规则。
- C/Zig binding 生成。
- C/Zig `sizeof`、`alignof`、`offsetof` golden tests。
- ABI compatibility fixtures 和 malformed descriptor test corpus。

它不得包含：

- `NativeEntry`、JSObject 或 GC 内部布局。
- package name resolution、semver、lockfile 或 registry 逻辑。
- `dlopen`、scheduler 或 event loop 实现。
- Zig 用户业务 API 的高级包装。

物理组织上建议独立 repository；若首期暂放 monorepo，也必须具有独立版本号、发布产物和兼容性测试。

### 8.2 zjs 负责什么

zjs 完全负责 VM 内执行与 JavaScript 语义：

1. `NativeEntry`、`NativeCallPlan`、`NativeFunction`、`NativeType`、`NativeObject` 的私有布局。
2. `CALL_NATIVE_*` handler、quickening、IC、dequicken 与 JIT lowering。
3. JS 参数类型检查、number range 检查、box/unbox 和返回值语义。
4. Native method 的 receiver、property holder、prototype chain 和 entry identity guard。
5. synthetic native ESM module、binding table 和 bytecode relocation。
6. managed native frame、handle scope、exception、reentry 和 JS call。
7. `JSValue` 公开布局承诺（经表示契约）、local/persistent/weak handle 的实现。
8. StringView、BufferView、ArrayBuffer、TypedArray、external buffer 和 lease 的 VM 侧实现。
9. NativeObject ownership、dispose、finalizer queue 和 type identity。
10. AsyncToken 的 Promise capability、exactly-once 状态、runtime epoch 和 JS-thread completion。
11. runtime close 时停止新 native 调用、释放 JS roots、执行 finalizer 和报告 drain 状态。
12. builtin/plugin 对照 benchmark 的 VM 侧路径验证。

zjs 不负责：

- `dlopen` / `LoadLibraryEx`（目标态；存量 loader 的过渡与退役见 §28.1）。
- package、manifest、registry、prebuilt、CAS 或编译器调用。
- artifact 签名、provenance 或平台打包。
- fun daemon、Program 或 worker orchestration。

### 8.3 fun 负责什么

fun 完全负责 native package 的编排与平台集成：

1. package、semver、lockfile 和 module specifier resolution。
2. Native SDK 选择、build adapter、toolchain、sysroot 和 native dependency lock。
3. recipe/build/artifact identity、全局 CAS、并发构建锁和 compiler object cache。
4. registry prebuilt 下载、签名/hash 验证和 compatible artifact 选择。
5. desktop dynamic loader、Android `.so` materialization、iOS static registry 和 app final link。
6. Process-wide `NativeImage` registry 和 artifact hash 去重。
7. descriptor symbol 获取、边界验证、metadata 复制和规范化。
8. 每个 `(Runtime, NativeImage)` 的 `PluginInstance` 创建、begin-shutdown 和销毁。
9. init host、async host、runtime target info 和 diagnostic sink 的组装。
10. event loop/wakeup/completion queue 的平台调度。
11. worker cancellation、runtime shutdown orchestration 和超时诊断。
12. profiler、stack trace、crash symbolication 所需的 package/artifact/export 映射。
13. `fun native inspect`、`doctor`、`rebuild`、cache GC 和 provenance 查询。

fun 不得：

- 读取或修改 zjs 私有 `NativeEntry` 字段。
- 自己实现 JS 参数转换、property lookup 或 NativeObject unwrap。
- 为 plugin 增加独立于 zjs builtin 的调用 trampoline。
- 将 package/version/artifact 判断放入 `CALL_NATIVE_*` 热路径。

### 8.4 Zig SDK 负责什么

Zig SDK 负责从用户声明生成稳定 ABI glue：

- 推导 call kind、machine signature 和 JS marshal policy。
- 生成 typed `callconv(.c)` thunk。
- 生成 function/class/method/getter/setter/finalizer descriptor。
- 生成 NativeClass constructor 和 ownership glue。
- 生成 dynamic descriptor symbol 与 unique static symbol。
- 生成 export visibility 和 dead-strip anchor。
- 生成 TypeScript `.d.ts`。
- 对 unsupported type、panic/unwind 风险和非法 ownership 在编译期报错。
- 对无法进入 fast path 的 API 要求显式使用 `fun.managed` 或 `fun.async`。

SDK 不得静默把 unsupported typed API 降级为 generic `argc/argv`。

### 8.5 职责矩阵

| 能力 | `fun-native-abi` | zjs | fun | Zig SDK |
|---|---:|---:|---:|---:|
| 公开 C layout / ID | 主责 | 消费 | 消费 | 消费/生成 |
| NativeEntry 私有布局 | 否 | 主责 | 否 | 否 |
| JS 参数语义 | 仅声明 policy ID | 主责 | 否 | 推导/声明 |
| CALL_NATIVE / IC / JIT | 否 | 主责 | 否 | 否 |
| NativeObject / GC / handles | 仅公开 opaque API | 主责 | 生命周期协调 | 生成 glue |
| package/module resolution | 否 | 接收最终 module ID | 主责 | 否 |
| dynamic/static loading | symbol 规则 | 否 | 主责 | 生成 symbol |
| PluginInstance | lifecycle ABI | drain hook | 主责 | 生成 callbacks |
| async Promise 状态 | token ABI | 主责 | 调度/唤醒 | 生成 glue |
| 构建与 CAS | 否 | 否 | 主责 | build integration |
| prebuilt 与签名 | 否 | 否 | 主责 | 否 |
| `.d.ts` | 类型规则 | 否 | 发布/消费 | 主责 |

### 8.6 zjs 与 fun 的唯一运行时边界

fun 向 zjs 传递的不是原始 plugin descriptor pointer，而是已复制、已验证的私有结构：

```zig
pub const NativeModuleRegistration = struct {
    module_id: ModuleId,
    owner: *NativeBindingOwner,
    exports: []const NativeExportRegistration,
    diagnostics: NativeDiagnosticsRef,
};

// 0.3 补充：NativeExportRegistration 是 fun↔zjs 边界上最承重的结构，
// 最终形状是 M0 交付物。示意骨架（字段名以 M0 定案为准）：
pub const NativeExportRegistration = struct {
    name: Atom,                       // 已 intern 的 export 名
    kind: ExportKind,                 // function / class / const_*
    plan_spec: NativeCallPlanSpec,    // call kind + signature + marshal policy
                                      //   + flags（fun 已规范化，zjs 据此建
                                      //   NativeCallPlan，与 type-directed T3
                                      //   NativeCallDescriptor 同一 schema）
    target: NativeCodePtr,
    state: ?*anyopaque,
    class_spec: ?*const NativeClassRegistration, // 仅 kind == class
    const_value: ?ConstValue,                    // 仅 kind == const_*
};
```

zjs 暴露私有 source-level API：

```zig
pub fn registerNativeModule(
    runtime: *Runtime,
    registration: *const NativeModuleRegistration,
) RegisterNativeError!*NativeModuleHandle;
```

该接口：

- 不属于 FNABI。
- 可随 fun 与 zjs 一起重新编译。
- 不跨第三方二进制边界。
- 不包含 package manager 或 loader 类型。
- 不允许 fun 构造或访问 `NativeEntry` 内存布局。

---

## 9. 代码与仓库组织建议

推荐结构：

```text
fun-native-abi/
├── schema/
│   ├── signatures.zig
│   ├── flags.zig
│   └── descriptors.zig
├── include/
│   └── fun_native_v1.h
├── zig/
│   └── abi.zig
└── tests/
    ├── layout-c/
    ├── layout-zig/
    └── malformed-descriptors/

fun-native-sdk-zig/
├── src/
│   ├── plugin.zig
│   ├── function.zig
│   ├── class.zig
│   ├── async.zig
│   └── dts.zig
└── build.zig

zjs/
└── src/native/
    ├── entry.zig
    ├── call_plan.zig
    ├── function.zig
    ├── object.zig
    ├── handles.zig
    ├── buffer.zig
    ├── async_token.zig
    └── bytecode.zig

fun/
└── src/native/
    ├── resolver.zig
    ├── loader.zig
    ├── image.zig
    ├── instance.zig
    ├── registration.zig
    ├── build.zig
    ├── cas.zig
    ├── prebuilt.zig
    ├── platform/
    └── diagnostics.zig
```

zjs core builtin 可直接使用 zjs 内部 descriptor builder；fun builtin module 应通过同一个 `NativeModuleRegistration` 接口注册。凡注册到统一 NativeEntry 的 builtin 必须与 plugin 生成相同的 `NativeCallPlan` 和 `NativeEntry`；存量未迁移 builtin 见 §33。

---

## 10. 统一的 NativeEntry 模型

### 10.1 VM 私有结构

建议 zjs 内部结构为：

```zig
const NativeCodePtr = *const fn () callconv(.c) void;

const NativeEntry = struct {
    target: NativeCodePtr,
    state: ?*anyopaque,

    call_plan: *const NativeCallPlan,
    owner_type: ?*NativeType,

    // 仅用于保活、诊断与冷路径，不进入 steady-state handler。
    owner: *NativeBindingOwner,
};

const NativeFunction = struct {
    object: JSObject,
    entry: *const NativeEntry,
};
```

约束：

- `NativeEntry` 创建后不可变。
- `target` 必须是函数指针，不得存为数据指针 `*anyopaque`。
- `state` 仅用于 stateful function；static leaf 为 null；method 的 receiver 使用 `self`，不通过 `state` 传递。
- `call_plan` 预计算 call kind、signature、marshal policy、throwing/reentry flags。
- `owner_type` 只用于 NativeClass method/getter/setter。
- `owner` 保活 PluginInstance 和 NativeImage，但 specialized handler 不得读取它。

### 10.2 Builtin 与 plugin 注册

```text
zjs builtin descriptor
  ↓
NativeExportRegistration
  ↓
NativeEntry

fun plugin descriptor
  ↓ fun copy + validate + normalize
NativeExportRegistration
  ↓
NativeEntry
```

完成 `NativeEntry` 创建后，执行路径不再区分来源。

### 10.3 冷路径 provenance

以下数据不得放入 steady-state call branch，但必须可从 `NativeBindingOwner` 或 diagnostics side table 查询：

- package name/version。
- module ID/export name。
- artifact digest/build ID。
- NativeImage/code address range。
- dynamic library/static archive identity。
- Plugin ABI/Fast Call ABI/Value ABI。
- source provenance、toolchain、target 和 dependency digest。
- hot reload generation。

---

## 11. ABI 分层与版本

### 11.1 Plugin ABI

Plugin ABI 负责：

- descriptor 布局。
- module/export 注册。
- PluginInstance 生命周期。
- NativeClass descriptor。
- Host table 和 opaque context。
- feature negotiation 与 extension discovery。

版本：

```text
FUN_PLUGIN_ABI_MAJOR
FUN_PLUGIN_ABI_MINOR
```

规则：

- Major 表示不兼容变更。
- Minor 只允许 append-only 扩展。
- 所有可扩展 struct 以 `struct_size` 开头。
- loader 只读取 `struct_size` 覆盖范围内的字段。
- 未识别的 optional flag 必须忽略；未识别的 required feature 必须拒绝加载。

### 11.2 Fast Call ABI

Fast Call ABI 负责：

- C calling convention。
- typed leaf function prototype。
- fixed-arity managed prototype。
- `state` / `self` 参数位置。
- primitive 宽度和返回方式。
- signature ID。

版本：

```text
FUN_FAST_CALL_ABI
```

Fast Call ABI 不定义 JS `Number` 到 `i32` 的具体转换语义；该语义由 marshal policy 定义。

### 11.3 Value ABI

**0.3 裁决：不存在独立的 FunValue 类型。** Value ABI 冻结的是 zjs `JSValue` 本身的公开布局：

- `JSValue` 的 16 字节 extern tagged 表示：`{ payload: u64, tag: i64 }`，align 8（表示契约 v1 硬承诺 §1.1，`src/core/value.zig` 实物）。
- tag 常量空间（object/int/boolean/null/undefined/float64/exception 等）。
- exception sentinel 约定。
- managed entry 中 raw value 的单次调用生命周期与地址稳定性（依托表示契约 §1.2 非搬移承诺）。

版本：

```text
FUN_VALUE_ABI = (表示契约版本, JSValue.abi_encoding_revision)
```

zjs 已有 `JSValue.abi_encoding_revision`（进 plugin ABI fingerprint）；FNABI 直接复用该机制，不另设编号。规则：

- typed leaf plugin 不依赖 Value ABI，descriptor 中 `value_abi = 0`。
- managed（含 fixed 参数形态）或直接处理 `JSValue` 的 plugin 必须声明具体版本。
- `JSValue` 字段布局、tag 语义（`abi_encoding_revision` bump）或单次调用地址稳定性变化时必须 bump Value ABI——且按契约流程**先修订表示契约递增版本，再动代码**。FNABI 自本方案批准起是表示契约的登记利益方：未来任何搬移/压缩堆提案必须把 FNABI 迁移成本计入。

### 11.4 v1 Target Contract

FNABI v1 仅支持：

```text
64-bit pointer
little-endian
8-bit byte
二补码整数
IEEE-754 f32/f64
平台标准 C ABI
```

公开 ABI 中：

- 不使用 C `long`、`size_t`、`wchar_t` 或未定宽 enum 作为跨平台字段。
- 长度使用 `uint32_t` 或 `uint64_t`。
- boolean 使用固定宽度整数，不使用 C `bool`。
- 复合 view 不按值传给 fast target，统一传 `const T*` 或 `T*`。**唯一例外是 `JSValue`**：16 字节、两寄存器（SysV/AAPCS64），与 QuickJS `JSValue` 同形状，managed 边界按值传递与返回。
- 不使用 C variadic function。
- 所有公开结构**不得含隐式 padding**：编译器会插垫的位置必须写显式 `reservedN` 字段；生成方必须置零，v1 loader 校验为零（后续 minor 若启用某 reserved 字段，须同时定义其非零语义）。防未初始化内存跨界与 metadata hash 不确定。

### 11.5 兼容性 tuple

artifact 是否可加载由以下 tuple 判断：

```text
Plugin ABI major/minor compatibility
Fast Call ABI
Value ABI，可选
Target triple / object format
OS deployment baseline
libc / CRT contract
CPU feature baseline
required host features/extensions
```

不得直接使用 fun runtime version 或 zjs commit 作为兼容性条件。

---

## 12. Plugin Descriptor

### 12.1 公共基础类型

示意 C ABI：

```c
#include <stdint.h>

/* 0.3：不存在 FunValue。managed 边界直接使用 zjs JSValue。
 * 布局与 src/core/value.zig 逐字段一致（表示契约 v1），由
 * fun-native-abi golden test 对 zjs 实物钉死。tag 为 8 字节宽
 * （qjs 同形；窄 i32 tag 有 store-forwarding stall 在册前科）。 */
typedef struct zjs_JSValue {
    uint64_t payload;
    int64_t tag;
} zjs_JSValue;

/* 同一类型的无前缀别名。与其他头（如 quickjs.h 的 JSValue）撞名时，
 * 定义 FUN_NATIVE_NO_JSVALUE_ALIAS 关闭别名、改用 zjs_JSValue 拼写。
 * 这只是 C 命名空间拼写，不是独立值类型（0.3 裁决：只有 JSValue）。 */
#ifndef FUN_NATIVE_NO_JSVALUE_ALIAS
typedef zjs_JSValue JSValue;
#endif

typedef uint32_t FunStatus;
typedef uint16_t FunExportKind;
typedef uint16_t FunCallKind;
typedef uint16_t FunSignatureId;
typedef uint16_t FunMarshalPolicyId;

typedef void (*FunNativeCodePtr)(void);

typedef struct FunUtf8RefV1 {
    const char* data;
    uint32_t length;
    uint32_t reserved0;   /* 显式尾垫，置零 */
} FunUtf8RefV1;

typedef struct FunFunctionDescriptorV1 {
    uint32_t struct_size;

    FunCallKind call_kind;
    FunSignatureId signature;
    FunMarshalPolicyId marshal_policy;
    uint16_t reserved0;

    uint32_t flags;
    FunNativeCodePtr target;
} FunFunctionDescriptorV1;

typedef struct FunExportDescriptorV1 {
    uint32_t struct_size;
    uint32_t reserved0;   /* 显式垫，置零 */

    FunUtf8RefV1 name;
    FunExportKind kind;
    uint16_t metadata_kind;
    uint32_t reserved1;   /* 显式垫，置零 */

    const void* metadata;
    uint32_t metadata_size;
    uint32_t reserved2;
} FunExportDescriptorV1;

typedef struct FunPluginDescriptorV1 {
    uint32_t struct_size;

    uint16_t plugin_abi_major;
    uint16_t plugin_abi_minor;
    uint16_t fast_call_abi;
    uint16_t value_abi;
    uint32_t reserved0;   /* 显式垫，置零 */

    uint64_t required_features;
    uint64_t optional_features;

    FunUtf8RefV1 package_name;
    FunUtf8RefV1 module_name;
    FunUtf8RefV1 build_id;

    const FunExportDescriptorV1* exports;
    uint32_t export_count;
    uint32_t reserved1;

    FunStatus (*create_instance)(
        const struct FunPluginInitContextV1* context,
        void** out_instance
    );

    void (*begin_shutdown)(void* instance);
    void (*destroy_instance)(void* instance);
} FunPluginDescriptorV1;

/* 0.3 补定义（原 0.2 前向引用未定义；最终形状是 M0 交付物）。 */
typedef struct FunPluginInitContextV1 {
    uint32_t struct_size;
    uint32_t reserved0;

    const struct FunPluginInitHostV1* init_host;
    void* host_context;   /* host 侧 opaque，回调时原样传回 */
    const struct FunRuntimeTargetInfoV1* target_info;
    const struct FunErrorSinkV1* error_sink;
} FunPluginInitContextV1;
```

说明：

- `FunNativeCodePtr` 是通用函数指针，不得替换为 `void*`。
- zjs 在调用前将其转换为 descriptor 所声明的准确函数类型。
- `package_name` 和 `module_name` 用于校验与诊断，不作为 package resolution 的权威来源；权威来源是 fun lockfile 与 resolver。
- `metadata` 必须由 `kind + metadata_kind + metadata_size` 解释，不允许无类型、无长度扩展。
- `create_instance` 使用 `FunStatus + out_instance`，错误文本通过 init context error sink 同步复制。
- `begin_shutdown` 可为 null；非 null 时必须幂等、不得调用 JS、不得抛异常。
- `destroy_instance` 必须 non-null、nothrow，并且只在所有 runtime-owned reference drain 后调用一次。

### 12.2 Status 与错误返回

`FunStatus` 至少定义：

```text
FUN_STATUS_OK
FUN_STATUS_INVALID_ARGUMENT
FUN_STATUS_OUT_OF_MEMORY
FUN_STATUS_UNSUPPORTED
FUN_STATUS_CANCELLED
FUN_STATUS_INTERNAL
```

规则：

- status 为固定宽度整数常量，不使用未定宽 C enum。
- `create_instance` 返回非 OK 时，`out_instance` 必须保持 null。
- 人类可读错误通过当前 context 的 error sink 同步提交，host 必须立即复制。
- plugin 不得返回指向临时栈、thread-local 或随后释放内存的错误字符串。
- managed call 的业务错误优先映射为 JS exception；`FunStatus` 主要用于 ABI/host 操作失败。

所有 Host function table 均以以下字段开头：

```c
uint32_t struct_size;
uint16_t abi_major;
uint16_t abi_minor;
```

未知尾部字段通过 `struct_size` 忽略；required major 不匹配时拒绝使用。

### 12.3 Export metadata

v1 至少定义：

```text
FUN_EXPORT_FUNCTION
FUN_EXPORT_CLASS
FUN_EXPORT_CONST_I32
FUN_EXPORT_CONST_F64
FUN_EXPORT_CONST_BOOL
FUN_EXPORT_CONST_UTF8
```

其中：

- function metadata 使用 `FunFunctionDescriptorV1`。
- class metadata 使用 `FunClassDescriptorV1`，内部包含 constructor、methods、getters、setters、ownership 与 finalizer descriptor。
- 所有 method/getter/setter descriptor 都是 typed、sized、append-only struct。
- 常量在 module instantiate 时由 zjs 创建，不形成 native call。

### 12.4 动态和静态入口

桌面动态库只公开一个标准 symbol：

```c
FUN_NATIVE_EXPORT
const FunPluginDescriptorV1*
fun_native_plugin_v1(void);
```

加载流程：

```text
dlopen / LoadLibraryEx
  ↓
lookup fun_native_plugin_v1
  ↓
调用一次 descriptor function
  ↓
复制并验证全部 descriptor metadata
  ↓
create PluginInstance
  ↓
转换为 NativeModuleRegistration
```

每个 export 不单独 `dlsym`。

静态平台使用唯一 symbol，避免多个 archive 冲突：

```text
fun_native_plugin_v1_<artifact-prefix>
```

SDK 同时生成 host-side registry entry 和 dead-strip anchor。

### 12.5 Descriptor 内存生命周期

- descriptor、target 和 callback 地址在 NativeImage 生命周期内有效。
- fun 必须将名称、flags、counts、typed metadata 和 diagnostics 字段复制到 host-owned memory。
- zjs 不得长期保存指向 plugin descriptor data section 的普通 metadata pointer。
- target/finalizer/callback 仍指向 image code，必须由 `NativeBindingOwner` 保活 image。
- host 不得使用自己的 allocator 释放 plugin 分配的内存；跨边界 payload 必须携带由原分配方实现的 release callback。

### 12.6 Loader 验证

fun 至少验证：

- struct size 与 ABI major/minor。
- target contract、Fast Call ABI 与可选 Value ABI。
- required features/extensions。
- export count 和 metadata count 上限。
- UTF-8、名称长度和重复 export。
- export kind、signature、marshal policy 和 flag 组合。
- required target 非 null。
- class method 名称和 ownership 配置。
- metadata size 与 kind 一致。
- reserved/显式垫片字段全部为零（§11.4 验零条款）。
- dynamic dependency 和 code address provenance。

该验证用于发现损坏、构建错误和版本失配，不是恶意 native code 的安全边界。

---

## 13. Host API 与 capability isolation

### 13.1 三类 Host capability

Host API 必须拆为三类：

```text
FunPluginInitHostV1
FunManagedHostV1
FunAsyncHostV1
```

#### Init Host

仅在 `create_instance` 中提供，可包含：

- 日志与 diagnostic sink。
- runtime/target/feature query。
- monotonic time。
- async host 获取。
- 可选的 host-owned shared payload allocator。

Init Host 不得包含：

- JS value 创建。
- object/property 操作。
- JS call/reentry。
- exception、Promise 或 handle API。
- GC 或 NativeObject API。

因此 leaf state 即使保存 init context，也无法获得 JS/GC capability。

#### Managed Host

只通过当前有效的 `FunCallContextV1*` 使用，包含：

- value/string/object/array API。
- local、persistent 和 weak handle。
- JS call 与 constructor call。
- exception。
- Promise。
- NativeObject 创建与 unwrap helper。
- ArrayBuffer/TypedArray/view/lease。

所有 managed function 必须接收 `FunCallContextV1*` 或从该 context 获取的 scoped token。离开 native call 后 context 立即失效。

0.3 明确：`FunCallContextV1` 对 plugin 是 **opaque 类型**——只经指针传递，plugin 不得解引用或依赖其大小。AsyncToken 与 `FunBufferLease` 的 C 句柄同为 opaque 指针类型。全部前向引用 ABI 类型在 M0 定案或显式声明 opaque（见 §33 M0 验收门）。

#### Async Host

为 thread-safe、无 JS object 的最小表，只允许：

- retain/release AsyncToken。
- 查询 cancellation。
- 提交 completion payload。
- 提交 native error。
- 唤醒 runtime completion queue。
- 释放 thread-safe buffer lease 或 native payload。

Async Host 不包含任何 JS value/object API。

### 13.2 Extension discovery

可选能力通过 versioned extension table 获取：

```text
extension_id + minimum_version
  ↓
opaque table pointer + struct_size
```

插件必须在加载或 init 阶段解析 extension，不得在 leaf hot path 动态查询。

### 13.3 Debug enforcement

zjs debug 构建维护当前 native call mode：

```text
none
leaf
managed
finalizer
async-completion
```

在 leaf、finalizer 或 worker thread 调用 Managed Host 时必须 trap，并输出 package、export、runtime 和 thread 信息。

该机制防止误用，但不能限制恶意 native code直接调用系统 API。

---

## 14. Native Call 分类

### 14.1 Leaf Static Entry

用于短时间、无 JS/GC capability 的 primitive/POD 运算：

```c
int32_t add(int32_t a, int32_t b);
double sin_like(double value);
void write_buffer(const FunBufferViewV1* view);
```

约束：

- 不接收 VM、Host 或 CallContext。
- 不创建 JS object/string/Promise。
- 不调用 JS。
- 不抛 JS exception。
- 不持有 `JSValue`。
- 不分配 JS heap。
- 不建立 general handle scope 或 reentry frame。
- 目标必须有界、短时；长时间计算应使用 async worker。

### 14.2 Leaf Stateful Entry

用于需要 per-runtime module state、但不操作 JS 的函数：

```c
void step_state(void* state, double dt);
int32_t process(
    void* state,
    const FunBufferViewV1* input
);
```

`state` 为当前 `PluginInstance` 或 SDK 生成的 module state pointer。

### 14.3 Leaf Method Entry

用于 NativeObject 高频方法：

```c
void world_step(void* self, double dt);
double world_time(void* self);
void world_write_transforms(
    void* self,
    const FunBufferViewV1* output
);
```

zjs 在进入 target 前完成：

- JavaScript property/method guard。
- receiver shape、prototype chain 和 NativeType guard。
- disposed 检查。
- NativeObject unwrap。
- 固定偏移读取 `native_ptr`。
- 参数转换。

插件只接收 `void* self`，不接收 JS `this`。

### 14.4 Managed Fixed Entry

用于需要 JS/GC capability、但参数数量固定的函数：

```c
JSValue fn0(FunCallContextV1* context);
JSValue fn1(FunCallContextV1* context, JSValue arg0);
JSValue fn2(
    FunCallContextV1* context,
    JSValue arg0,
    JSValue arg1
);
```

stateful 和 method 版本分别在 context 后增加 `void* state` 或 `void* self`。

固定参数优先支持 0～4 个参数。该路径仍避免 `argc/argv` 数组，但会建立 managed native frame、必要的 handle scope 和 exception state。

### 14.5 Managed Generic Entry

仅用于 variadic、参数数量较高或高度动态的 API：

```c
JSValue fn(
    FunCallContextV1* context,
    uint32_t argc,
    const JSValue* argv
);
```

generic entry 是显式 fallback，不是 SDK 对 unsupported typed API 的静默降级。

### 14.6 Async Entry

异步 API 的 start 阶段在 JS thread 执行：

```text
JS call
  ↓
zjs 创建 Promise + AsyncToken
  ↓
managed async start target
  ↓
plugin worker / system callback
  ↓
FunAsyncHostV1.submit(...)
  ↓
fun runtime completion queue
  ↓
zjs 在 JS thread resolve/reject
```

start target 可以读取参数并创建 native job，但 worker 不得保留 raw `JSValue`。复杂结果应以 native payload 提交，再由 JS-thread completion adapter 转为 JS value。

---

## 15. Fast Signature 与 JavaScript 语义

### 15.1 两层定义

每个 fast export 同时声明：

```text
machine signature
JS marshal policy
```

machine signature 决定 native C prototype；marshal policy 决定 JS 输入接受范围、错误类型和转换方式。

二者组合后生成 zjs 内部 `NativeCallPlan`。quickening 选择已知组合对应的 specialized handler，steady-state 不执行 signature 或 policy switch。

### 15.2 v1 精选 signature

首版建议支持：

```text
VOID -> VOID
I32 -> I32
I32, I32 -> I32
F64 -> F64
F64, F64 -> F64
F64 -> VOID
BOOL -> BOOL
STATE, F64 -> VOID
SELF -> F64
SELF, F64 -> VOID
SELF, F64, F64 -> VOID
BUFFER -> VOID
STATE, BUFFER -> I32
SELF, BUFFER -> VOID
MANAGED_VALUE0 ... MANAGED_VALUE4
GENERIC
ASYNC_VALUE0 ... ASYNC_VALUE4
```

0.3 修订：0.2 清单中的 `VALUE0 ... VALUE4`（无 context 的「fixed Value」类别）已移除——该调用类别全文未定义，且无 context 意味着不能调用任何 Host API，用途存疑。fixed 参数的 `JSValue` 形态统一走 `MANAGED_VALUE0-4`（§14.4）；v2 如需更轻量变体再独立立项。

实际 ID 由单一 schema 生成，zjs handler、C header、Zig SDK、ABI fixture 和 benchmark 共同消费，禁止手工复制。

### 15.3 canonical marshal policy

| Zig/native 类型 | 默认 JS 语义 | 失败行为 |
|---|---|---|
| `i32` | 必须是 JS Number，数学值为整数且在 int32 范围；无论当前 Value 是 int32 tag 还是 double 表示都接受 | 非 Number 为 `TypeError`；非整数或越界为 `RangeError` |
| `u32` | 必须是 JS Number，整数且在 uint32 范围 | 同上 |
| `f64` | 接受任意 JS Number，包括 int32 表示、NaN 和 ±Infinity | 非 Number 为 `TypeError` |
| boolean | 仅接受真正的 JS boolean，不执行 `ToBoolean` | `TypeError` |
| string view | 仅接受 JS string，不隐式 `ToString` | `TypeError` |
| buffer view | 仅接受 descriptor 声明的 ArrayBuffer/TypedArray/DataView 类型 | `TypeError`、detached error 或 capacity error |
| NativeObject self | 必须是对应 NativeType 且未 disposed | `TypeError` 或 disposed error |
| `JSValue` | 接受任意 JS value | 由 managed target 自行处理 |

因此，zjs 不得使用“当前恰好是 int32 immediate”作为 `i32` 的完整 JS 语义。int32 tag 只能作为 fast observed case；double 表示但数学值为 int32 的 Number 必须得到相同结果。

### 15.4 显式 coercion

`ToInt32`、`ToNumber`、`ToString`、`ToBoolean` 等可观察 coercion 不属于 leaf 默认语义。插件作者若需要 coercion，必须：

- 显式选择相应 marshal policy；或
- 使用 `fun.managed` 调用 Host API。

coercion 可能执行用户代码、抛异常或触发 GC，因此不得被错误标记为 leaf nothrow。

### 15.5 错误与返回值

- leaf typed entry 不返回 JS exception sentinel。
- leaf 参数检查由 zjs 在调用前完成。
- leaf target 若可能失败，应改为 managed/fallible API，而不是跨 ABI unwind。
- `i64/u64` 默认使用 BigInt managed API；不得隐式通过 JS Number。
- nullable、optional 和 union 必须由 SDK 显式声明，不根据 null pointer 猜测。

### 15.6 Arity 语义（0.3 新增）

- **缺参**：按普通 JS 语义以 `undefined` 参与 marshal。typed policy 下 `undefined` 不是合法 Number/boolean/string/buffer，因此通常抛 `TypeError`——这是 marshal 规则的自然结果，不是独立的 arity 检查。
- **多参**：忽略（与普通 JS 函数一致），不构成错误，不影响 fast path。
- **错误顺序**：leaf marshal 从左到右检查，抛第一个失败参数的错误。因 leaf 禁 coercion，检查过程无可观察副作用，该顺序是完整语义。
- 可选参数/默认值不属于 typed leaf；需要者显式声明 optional policy 或改用 managed。

---

## 16. 生成的 typed thunk

用户 Zig 函数通常使用 Zig calling convention：

```zig
fn add(a: i32, b: i32) i32 {
    return a + b;
}
```

SDK 生成：

```zig
fn generatedAdd(
    a: i32,
    b: i32,
) callconv(.c) i32 {
    return add(a, b);
}
```

`generatedAdd` 本身就是 `NativeEntry.target`。

性能承诺是：

- 不存在运行时 generic wrapper。
- 不存在 signature parser 或 dispatcher。
- Release 构建中业务函数应被内联进 typed thunk。
- 若未内联，验收工具必须识别额外 native call，并将其视为 SDK/codegen 性能问题。
- 注册到统一 NativeEntry 的 builtin（至少含 §31.1 参照对拍集与全部新增 builtin）必须通过同类 typed thunk 或等价内部生成器注册，不得保留更快的私有 ABI；存量 builtin 的迁移节奏见 §33（0.3 裁决：v1 不强制全量迁移）。

因此“无 wrapper”精确定义为：

> **无运行时通用 wrapper；允许并要求构建期生成一个准确 C ABI 的 typed entry thunk。**

---

## 17. zjs 调用路径

### 17.1 静态 ESM import

```js
import { add } from "@fun/physics";
const result = add(a, b);
```

fun resolver 将 package import 解析为已加载 native module。zjs module instantiate 创建 runtime-local native binding table：

```text
NativeBindingTable
  slot 0 -> NativeEntry(add)
  slot 1 -> NativeType(World)
```

bytecode 使用 relocation slot：

```text
CALL_NATIVE_I32_I32_TO_I32
    dst
    arg0
    arg1
    native_binding_slot
```

bytecode cache 只能序列化 `native_binding_slot` 和 module relocation，不得序列化裸 `NativeEntry*` 或 target address。module instantiate/link 时重新填充 runtime-local table。

### 17.2 动态函数调用

```js
const fn = module.add;
fn(a, b);
```

第一次执行普通 `CALL`：

```text
callee is NativeFunction
  ↓
记录 exact callee identity / NativeEntry identity
  ↓
验证 call plan
  ↓
quicken 为 CALL_NATIVE_*
```

仅使用 shape guard 不足，因为多个 NativeFunction 可具有相同 shape 但不同 target。guard 必须包含 callee identity 或 `NativeEntry` identity。

identity 变化、callee 被替换或 hot reload 绑定变化时 dequicken。

0.3 强制条款（表示契约 §5.2；在册前科：M2 资格链缓存同址重分配 ABA 判不 sound）：

- **quicken 站点缓存的 callee/`NativeEntry`/`NativeType` identity 是非持有引用**——表示契约只保地址不保生命周期，RC 立即释放与 tracing 延迟回收下都存在 dangling/ABA。**裸指针比较不构成 guard；命中必须经版本/纪元验证后才可比较或解引用**。实现载体 = type-directed F1 identity 字段 + Phase 0.5 侧表的版本机制，FNABI 不自建平行方案。静态 ESM binding slot 例外：binding table 经 `NativeBindingOwner` 强持有，槽内引用是持有引用。
- 站点缓存所在的侧表须向 shadow tracer 边审计登记为「非 GC 边」（契约 §5.2 原文要求）。
- **编码宽度**：zjs 字节码为变长编码。quicken 必须同宽度原地改写，或经侧表间接（站点 id → 缓存记录）；不得依赖改变指令长度的重写。
- **多态 backoff**：同一站点 dequicken 达到上限（建议 N=2）后进入 megamorphic 状态，不再尝试 quicken，走通用 `CALL` 慢路，防 quicken/dequicken 震荡。

### 17.3 Native method

```js
world.step(dt);
```

融合 method call 的 guard 至少包含：

- receiver shape。
- receiver NativeType identity。
- disposed state。
- property holder identity/shape。
- prototype chain version 或完整 chain guard。
- 最终 NativeFunction/NativeEntry identity。

以下操作必须使 fast path 失效：

```js
world.step = other;
World.prototype.step = other;
Object.setPrototypeOf(world, otherPrototype);
delete World.prototype.step;
```

失效后回退到普通 property lookup + call，不得跳过 JavaScript 属性语义。

SDK 可提供显式 `sealed` native class 模式，将 method 定义为 non-configurable 并冻结 prototype，从而减少 guard；默认 class 仍遵守普通 JS class method 语义。

本节全部 shape/prototype 版本 guard 依赖 type-directed F1（shape identity 字段）与 F5（编译期 shape 注册）交付；identity 比较同样受 §17.2 的纪元验证条款约束。

0.3 补充——**native getter/setter 的 v1 状态**：§12.3/§19 descriptor 支持 getter/setter，但其调用点是属性访问（`GET_FIELD`/`PUT_FIELD`），不是 `CALL`。v1 中 native getter/setter 经属性访问慢路进入统一的 NativeEntry 调用（语义完整、无 fast path 承诺）；将其融合进属性 IC fast path 属 engine plan Phase 3 范围，不在 FNABI v1 性能验收内。高频访问器应改用显式 method（`world.time()` 而非 `world.time`）。

### 17.4 Handler 示例

```zig
const entry = native_bindings[slot];
const a = try toExactI32(values[arg0]);
const b = try toExactI32(values[arg1]);

const target: *const fn (
    i32,
    i32,
) callconv(.c) i32 = @ptrCast(entry.target);

values[dst] = Value.fromI32(target(a, b));
```

steady-state handler 不执行：

- module/export lookup。
- descriptor lookup。
- dynamic symbol lookup。
- builtin/plugin 判断。
- signature string parsing。
- `argc/argv` 构造。
- Host API lookup。

### 17.5 JIT

未来 baseline/optimizing JIT 可对稳定 call site：

- 直接嵌入 target address。
- 使用 near-call trampoline。
- 对 receiver type、entry identity 和 image generation 建立 guard。
- guard 失败时 deopt。

builtin 和 plugin 使用相同策略。v1 不为了消除一次稳定 indirect branch 强制引入 executable-memory stub，也不开放第三方 intrinsic ABI。

---

## 18. JSValue、Handle、GC 与 Reentry

### 18.1 JSValue

managed entry 直接使用 zjs `JSValue`（§11.3、§12.1）：公开类型与 zjs 内部值类型是**同一类型、同一布局**（表示契约 v1）。禁止引入独立的 PluginValue/FunValue 中间表示，也不存在边界转换。

规则：

1. plugin 不得直接解引用 heap reference（tag 判别可本地做，heap payload 只能经 Host API）。
2. raw `JSValue` 默认只在当前 managed call 内有效。
3. 当前调用的 arguments 和 Host API 返回值由 native frame/handle scope 保持存活。
4. 跨调用保存必须转换为 persistent handle。
5. worker thread 不得保存 raw `JSValue`。
6. 调用内地址稳定性由表示契约 §1.2 **非搬移承诺**（sticky-mark-bit，无 copy/compaction）背书。`JSValue` 布局、tag 语义或该稳定性承诺变化时，先修订表示契约、bump Value ABI（§11.3），FNABI 作为登记利益方参与评审。
7. typed leaf entry 不接触 `JSValue`，不受 Value ABI 影响。

### 18.2 Local 与 persistent handle

Managed Host 至少提供：

```text
FunLocal
FunPersistent
FunWeak
```

- `FunLocal` 只在当前 `FunCallContext` 有效。
- `FunPersistent` 跨调用保活 JS value，必须显式 release。
- `FunWeak` 不阻止回收，回调由 zjs 在 runtime thread 调度。
- SDK 高级 API 默认返回 local handle wrapper，减少 raw value 误用。

### 18.3 Leaf call

leaf target 期间：

- 不建立 managed handle scope。
- 不准备 JS reentry。
- 不调用 Host API。
- 不检查 pending exception。
- 不在 target 内触发 JS allocation 或 managed safepoint。
- receiver 和参数仍由当前 VM register frame 保活。

VM 可在 bytecode 边界处理 interrupt/GC。leaf target 必须短时有界，不能长期阻塞 runtime thread。

### 18.4 Managed call

managed call 根据 `NativeCallPlan` 建立：

- native frame。
- 必要的 local handle scope。
- exception state。
- reentry bookkeeping。
- call mode debug state。

`NOTHROW` managed handler 可省略返回后的 pending-exception 检查，但仅当 SDK 和 descriptor 能静态证明 target 不调用 throwing Host API。

### 18.5 Exception 与 unwind

- 参数转换错误由 zjs 创建正确 realm 的 JS exception。
- managed target 可设置 pending exception 或返回 exception sentinel。
- leaf target 不允许抛 JS exception。
- C++ exception、Rust/Zig panic 等必须在 SDK thunk 内转为 process abort、native status 或 JS exception；不得 unwind 进入 zjs。


---

## 19. NativeObject 与 NativeClass

### 19.1 VM 内部对象模型

`NativeObject` 是 zjs 的一等对象类型：

```text
NativeObject
├── JSObject header
├── NativeType*
├── native_ptr
├── ownership/disposed bits
├── optional owner edge / shared lease
└── NativeBindingOwner*
```

该布局完全属于 zjs 私有实现，不进入 FNABI。plugin 只能获得：

```text
void* self
```

### 19.2 NativeType

每个 NativeClass 在 runtime/application realm 中对应一个 `NativeType`：

```text
NativeType
├── runtime-local type identity
├── NativeBindingOwner
├── constructor entry
├── method/getter/setter entries
├── prototype/constructor objects
├── ownership policy
├── finalizer/release callbacks
└── diagnostics metadata
```

约束：

- type identity 必须区分 NativeImage generation。
- hot reload 后 image A 与 image B 的同名 class 具有不同 NativeType identity。
- `instanceof`、method receiver check 和 unwrap 都以 runtime-local identity 为准。
- plugin 不得伪造或比较 zjs 内部 `NativeType*`。

### 19.3 Constructor

NativeClass constructor 默认是 managed entry，因为它通常需要：

- 检查参数并产生可观察错误。
- 分配 native object。
- 创建 JS wrapper。
- 设置 ownership、owner edge 或 shared lease。
- 处理 Zig error union。
- 在正确 realm 创建 prototype-linked object。

SDK 可生成固定参数 managed constructor，不要求 generic `argc/argv`。

constructor 必须遵守普通 JavaScript construct semantics，包括：

- 不可构造函数被 `new` 调用时的错误。
- construct call 与 ordinary call 的区分。
- `new.target` 和 subclassing policy。
- 返回非 primitive object 时的构造语义。

v1 可将 generated NativeClass 标记为不可 subclass，以减少复杂度；若允许 subclass，必须由 zjs 完整实现 ordinary constructor 语义，不能由 plugin 自行猜测。

### 19.4 所有权模型

v1 支持：

| 模式 | VM 行为 | Plugin 要求 |
|---|---|---|
| owned | wrapper dispose/finalize 时调用 destructor | destructor 必须幂等或由 disposed bit 保证只调用一次 |
| borrowed | wrapper 不释放 native object，但持有 owner edge 或 native lease | 不允许仅靠文档假设外部 pointer 永远有效 |
| shared | wrapper 持有 retain/release token | retain/release 必须线程与生命周期语义明确 |

borrowed object 必须二选一：

1. 保存一个强 JS owner edge，例如 child wrapper 保活 parent NativeObject；或
2. 保存 plugin 提供的 native lease，lease release callback 由原分配方执行。

禁止创建没有 owner edge/lease 的长期 borrowed wrapper。

### 19.5 Dispose 与 finalizer

每个 NativeObject 必须有 `alive/disposed` 状态：

```text
alive
  ↓ explicit dispose 或 GC finalizer
finalizing
  ↓ destructor/release
 disposed
```

规则：

- `dispose()` 必须幂等。
- dispose 后 `native_ptr` 不得继续使用。
- method/getter/setter fast path 必须包含 disposed guard。
- dispose 后调用 method 应抛稳定的 disposed error。
- GC finalizer 发现已 disposed 时不得重复释放。
- finalizer 首版固定在所属 runtime thread 执行。
- finalizer 不得调用 JS、抛异常或创建新的 persistent handle。
- finalizer 应短时、nonblocking；重型关闭应由显式 `dispose()` 或 async close 完成。
- finalizer function pointer 与 PluginInstance 必须由 `NativeBindingOwner` 保活。
- **执行时机（0.3 新增，覆盖两种 GC 形态）**：RC 权威期（当前 shipped default），refcount 归零在归零点**同步**执行 destructor（qjs 同形）；tracing 权威期，finalizer 不得在 GC STW 停顿内执行——插件代码时长不可控，会把停顿撑成无界，GC 只负责入队，finalizer queue 在 runtime thread 的字节码边界/顶层 drain 点排空，诊断接口须能报告积压。**插件不得依赖两种形态间的析构时序差**——这是插件作者合同的一部分。

### 19.6 NativeObject 与 PluginInstance 保活

`NativeObject` 不仅保活 NativeImage，还必须保活对应 PluginInstance。原因是 destructor、shared release、native allocator 或 object state 可能依赖 per-runtime module state。

最小引用关系为：

```text
NativeObject
  └── NativeBindingOwner
        ├── PluginInstance
        └── NativeImage
```

仅“默认不 dlclose”不足以保证 instance state 仍有效。

---

## 20. String、Buffer、TypedArray 与零拷贝

### 20.1 StringView

公开 ABI 使用固定宽度结构并通过指针传递：

```c
typedef struct FunStringViewV1 {
    const void* data;
    uint64_t code_unit_length;
    uint16_t encoding;
    uint16_t flags;
    uint32_t reserved0;
} FunStringViewV1;
```

encoding 至少包括：

```text
LATIN1
UTF16
UTF8_EXPLICIT
```

规则：

- 默认不强制转换 UTF-8。
- native API 能接受 Latin-1/UTF-16 时直接借用 zjs 字符串存储。
- flattening 在进入 target 前完成。
- borrowed view 仅当前 native call 有效。
- 需要跨调用持有时必须复制或创建 persistent string handle。
- leaf string API 不允许执行隐式 `ToString`。
- 空字符串可使用 null data + zero length，具体规则由 ABI 固定。

### 20.2 BufferView

```c
typedef struct FunBufferViewV1 {
    void* data;
    uint64_t byte_length;
    uint64_t byte_offset;

    uint16_t element_type;
    uint16_t flags;
    uint32_t reserved0;
} FunBufferViewV1;
```

flags 至少表达：

```text
READ_ONLY        （缺省即可写，不设独立 WRITABLE 位）
SHARED
RESIZABLE
BORROWED
RETAINED
TRANSFERRED
```

复合 view 不按值传递给 fast target：

```c
void fn(const FunBufferViewV1* input);
void fn(void* self, FunBufferViewV1* output);
```

### 20.3 三种生命周期

| 模式 | 生命周期 | 语义 |
|---|---|---|
| borrowed | 当前 native call | zjs 在调用期间保证 backing store 地址有效 |
| retained | 显式 lease 生命周期 | plugin 持有 `FunBufferLease`，runtime 保活/pin backing store |
| transferred | 所有权转移 | 原 owner 失去访问权，接收方负责最终 release |

规则：

- borrowed fast path 应在常见固定 backing store 上零分配。
- retained lease 可以有引用计数或 bookkeeping 成本，不属于逐元素调用路径。
- 若 resizable/growable backing store 无法稳定 pin，zjs 必须拒绝 retained zero-copy，而不是静默复制。
- API 只有在 descriptor 明确允许 copy 时，才可 fallback 到复制路径；zero-copy API 不得悄悄复制。
- detached buffer 必须在调用前报错。
- writable output 必须校验 readonly、容量、alignment 和 element type。
- SharedArrayBuffer 的数据竞争由 plugin API 合同负责；zjs 只保证 backing store 生命周期和内存模型要求。

### 20.4 External ArrayBuffer

plugin 可创建 external ArrayBuffer，但必须提供：

- data pointer。
- byte length。
- release callback。
- release payload。
- callback thread policy。
- optional memory accounting size。

zjs 负责：

- 将 external memory 计入 GC pressure/accounting。
- 在 runtime thread 或约定线程执行 release。
- 防止 runtime close 后 callback 访问已销毁 PluginInstance。
- 通过 `NativeBindingOwner` 保活 release code 与 instance。

### 20.5 高频 API 设计原则

graphics、physics、audio、ML 等场景优先使用：

- TypedArray bulk input/output。
- shared command buffer。
- ring buffer。
- structure-of-arrays。
- 每 frame 一次 batch。

不推荐：

```js
for (const body of bodies) {
  mesh.position.x = body.x();
  mesh.position.y = body.y();
  mesh.position.z = body.z();
}
```

推荐：

```js
world.step(dt);
world.writeTransforms(transformBuffer);
```

Native Plugin ABI 可以消除单次 crossing 的通用开销，但不能消除大量细粒度 crossing 本身的成本。

---

## 21. 并发与异步

### 21.1 Thread ownership

默认规则：

- `PluginInstance` 归属于一个 zjs runtime。
- JS-visible plugin 调用始终从该 runtime thread 进入。
- runtime-confined NativeObject 只能在所属 runtime thread unwrap/use。
- leaf target 是否使用内部线程由 plugin 决定，但 target 返回前必须满足其同步语义。
- native worker thread 不得访问 JS object、raw `JSValue`、CallContext 或 runtime-confined NativeObject。
- **image 级全局数据（0.3 新增，插件作者合同）**：同一 NativeImage 可同时服务多个 runtime（各自 PluginInstance，可能在不同线程，见 §22.1/§22.2）。image 内的 `var` 全局、TLS 与静态构造在所有 instance 间共享，SDK 与 runtime 均无法防护——插件作者必须把可变全局视为跨线程共享数据（加锁或消除）；per-runtime 状态一律放 `PluginInstance` state。

### 21.2 AsyncToken 状态机

zjs 内部至少维护：

```text
Pending
  ├── Completed(value/error)
  ├── Cancelled
  └── RuntimeClosed
```

所有终态均为 exactly-once。第二次 completion 必须：

- 被拒绝并记录 diagnostic；
- 仍正确释放第二个 payload；
- 不得再次 resolve/reject Promise。

AsyncToken 包含或关联：

- Promise capability。
- runtime identity 与 generation/epoch。
- PluginInstance owner。
- cancellation state。
- completion-once atomic state。
- payload release policy。

### 21.3 Worker 提交结果

worker 只提交 native payload：

```text
AsyncToken
Result kind
Payload pointer/size
JS-thread completion adapter
Payload release callback
```

复杂结果的推荐流程：

```text
worker 生成 native Result
  ↓
submit payload
  ↓
runtime thread 调用 generated completion adapter
  ↓
Managed Host 创建 JS value
  ↓
resolve/reject Promise
  ↓
release payload
```

worker 不直接构造 JS value。

### 21.4 Cancellation

- JS AbortSignal、runtime close 或 explicit cancel 可设置 token cancellation。
- plugin worker 通过 Async Host 查询 cancellation。
- cancellation 默认是 cooperative，不保证强制停止 native code。
- `begin_shutdown` 必须请求 plugin 停止接受新 job 并取消在途 work。
- plugin 必须保证 worker 最终不再访问已销毁 instance。

### 21.5 fun 与 zjs 的异步职责

zjs 负责：

- Promise 和 token 状态。
- exactly-once。
- runtime epoch 检查。
- JS-thread completion adapter。
- resolve/reject 与异常语义。

fun 负责：

- thread-safe completion queue。
- event loop wakeup。
- 将 completion 调度回正确 runtime thread。
- runtime shutdown 时协调 drain/cancel。
- 平台 worker/system callback integration。

### 21.6 Runtime close 后的 completion

若 completion 到达时 runtime 已关闭：

- 不再执行 JS completion adapter。
- 不 resolve/reject Promise。
- 必须执行 native payload release callback。
- 必须 release AsyncToken 和 PluginInstance owner。
- 应记录 late-completion 计数和 package/export 信息。

### 21.7 高频 Native → JS 事件

高频事件必须使用：

- batching。
- ring buffer。
- shared buffer。
- 每 frame 一次通知。
- 单个 pending wakeup 合并。

不得为每个底层事件创建独立 JS callback task。

---

## 22. Runtime 生命周期与 Hot Reload

### 22.1 Process-wide NativeImage

相同 artifact digest 在一个进程中只装载一次：

```text
NativeImage
├── artifact digest
├── loader handle / static identity
├── copied descriptor metadata
├── code address range
├── dependency handles
├── build provenance
└── refcount / hot-reload generation
```

fun 维护 process-wide image registry。并发加载相同 digest 必须合并。

### 22.2 Per-runtime PluginInstance

每个 `(Runtime, NativeImage)` 创建一份：

```text
PluginInstance
├── module state
├── init/async host references
├── runtime identity
├── async job/token accounting
├── native resource accounting
└── lifecycle state
```

同一 image 可被多个 runtime 共享，但 instance 不共享。

### 22.3 NativeBindingOwner

zjs 中的以下实体必须保活 owner：

- NativeFunction。
- NativeType 与 constructor/prototype。
- NativeObject。
- persistent/weak native callback。
- external ArrayBuffer finalizer。
- retained buffer lease。
- AsyncToken。
- bytecode/native binding table。

owner 最终保活 PluginInstance 与 NativeImage。

### 22.4 Shutdown 状态机

完整状态机：

```text
Active
  ↓ runtime close / image retirement
Closing
  - 禁止新 import、constructor、async token 和 plugin job
  - 普通已进入调用允许完成
  - 在飞 managed call 申请新 AsyncToken/NativeObject/persistent
    handle 时，Host API 返回明确的 shutting-down 错误
    （FUN_STATUS_CANCELLED 或映射为 JS exception），
    不得静默成功，也不得未定义行为（0.3 新增）
  ↓
Cancelling
  - 调用 begin_shutdown(instance)
  - 标记所有 AsyncToken cancelled
  - 请求 worker/system callback 停止
  ↓
Draining
  - 处理或丢弃在途 completion
  - 释放 payload、buffer lease、persistent handle
  - 等待 plugin 不再访问 runtime-confined state
  ↓
Finalizing
  - zjs 在 runtime thread 执行 NativeObject/external buffer finalizer
  - 清理 NativeType、module binding 和 weak callbacks
  ↓
Destroying
  - 确认 owner 引用只剩 shutdown owner
  - 调用 destroy_instance(instance)
  ↓
Destroyed
```

强制顺序：

1. 禁止新工作。
2. 发起 cancellation。
3. drain async completion 与 payload。
4. 执行 JS/native wrapper finalizer。
5. 释放 persistent handle 和 buffer lease。
6. 销毁 PluginInstance。
7. 最后释放 NativeImage 引用。

不得先销毁 PluginInstance，再执行 NativeObject finalizer。

### 22.5 Shutdown 卡住处理

native code 无法安全强制终止。fun 应提供：

- outstanding token/job/object/lease 统计。
- package/export/job diagnostic。
- configurable graceful shutdown timeout。
- 超时后记录并由上层决定继续等待、终止 worker process 或直接结束进程。

不得声称可在同一进程内安全 kill 任意失控 native thread。

### 22.6 默认不卸载

v1：

```text
load once
默认 never dlclose
```

原因：

- target/finalizer/callback 地址被长期保存。
- old NativeObject 可继续存在。
- async completion 可能晚到。
- plugin-owned thread 或 TLS 可能仍使用 image。
- hot reload image 的 native type/layout 不兼容。

`PluginInstance` 仍应在 runtime close 后销毁；“不 dlclose”只保留 image code，不等于泄漏 runtime state。

### 22.7 Hot Reload

开发模式使用 side-by-side image：

```text
artifact digest A -> NativeImage A -> PluginInstance A
artifact digest B -> NativeImage B -> PluginInstance B
```

规则：

- 新 import 绑定 B。
- 已存在 JS Function、NativeType、NativeObject 和 AsyncToken 继续绑定 A。
- A/B type identity 不兼容。
- 不迁移 native object pointer、module state 或 Promise。
- A 的 instance 在其 owner 全部 drain 后销毁。
- v1 不自动 `dlclose` A。

---

## 23. Zig SDK 与 Binding Generation

### 23.1 示例

```zig
const fun = @import("fun_native");

fn add(a: i32, b: i32) i32 {
    return a + b;
}

const World = struct {
    native_world: *NativeWorld,

    fn init() !World {
        return .{
            .native_world = try createWorld(),
        };
    }

    fn deinit(self: *World) void {
        destroyWorld(self.native_world);
    }

    fn step(self: *World, dt: f64) void {
        stepWorld(self.native_world, dt);
    }

    fn writeTransforms(
        self: *World,
        output: fun.BufferView(.writable),
    ) void {
        writeWorldTransforms(
            self.native_world,
            output.data,
            output.byte_length,
        );
    }
};

pub const plugin = fun.plugin(.{
    .name = "@fun/physics",

    .exports = .{
        fun.leaf("add", add),

        fun.class("World", World, .{
            .constructor = World.init,
            .destructor = World.deinit,
            .ownership = .owned,

            .methods = .{
                fun.leafMethod("step", World.step),
                fun.leafMethod(
                    "writeTransforms",
                    World.writeTransforms,
                ),
            },
        }),
    },
});
```

JavaScript：

```js
import { add, World } from "@fun/physics";

const result = add(1, 2);

using world = new World();
world.step(1 / 60);
world.writeTransforms(transformBuffer);
```

`using`/dispose 支持取决于 zjs 对 Explicit Resource Management 的实现；即使不支持，SDK 仍应暴露显式 `dispose()`。

### 23.2 SDK 自动生成

- C ABI typed entry thunk。
- machine signature ID。
- JS marshal policy ID。
- function/class/export descriptor。
- constructor/method/getter/setter/finalizer glue。
- NativeObject ownership metadata。
- dynamic descriptor symbol。
- static unique symbol 和 registration anchor。
- visibility/linker configuration。
- TypeScript declaration。
- debug export map。
- ABI conformance metadata。

### 23.3 编译期诊断

以下情况必须编译失败：

- 未支持的 Zig 参数/返回类型被用于 `fun.leaf`。
- leaf function 返回 error union、optional 或可能 panic 的未处理路径。
- 复合 struct 试图按值跨 fast ABI。
- NativeClass 缺少 ownership/finalizer 合同。
- borrowed object 没有 owner edge/lease 声明。
- async worker closure 捕获 raw `JSValue` 或 `FunCallContext`。
- static symbol 不唯一。
- plugin required Value ABI 与使用的 API 不一致。

### 23.4 显式 managed/async

无法映射到 fast path 时，作者必须明确写：

```zig
fun.managed("createScene", createScene)
fun.async("loadAsset", loadAsset)
```

SDK 不得仅为了“编译通过”自动选择 generic entry。

### 23.5 TypeScript declaration

`.d.ts` 应在 package 发布或 prepublish 阶段生成并随 package 一起分发。编辑器获取类型信息不应要求为当前平台先编译 native artifact。

build 时仍应重新验证 `.d.ts` 与 descriptor schema 一致，防止发布产物漂移。

---

## 24. Package Manifest 与 Module Resolution

### 24.1 Manifest

```json
{
  "name": "@fun/physics",
  "version": "1.2.0",
  "exports": {
    ".": "./src/index.ts"
  },
  "types": "./dist/index.d.ts",
  "fun": {
    "native": {
      "module": "@fun/physics",
      "build": "native/build.zig",
      "sdk": "^1.0.0",
      "prebuild": true
    }
  }
}
```

lockfile 必须解析并固定：

- package version。
- exact Native SDK version/digest。
- native dependency graph。
- target contract。
- selected artifact digest 或 build recipe。

### 24.2 一个 artifact 一个 module

v1 不允许一个 descriptor 包含多个独立 ESM module。`exports` 数组就是该 module 的 export namespace。

理由：

- descriptor 模型简单。
- package 与 artifact identity 清晰。
- PluginInstance state 与 module state 一一对应。
- static registration 和 hot reload 更容易推理。

未来若确有需求，可在 Plugin ABI v2 增加 `modules + module_count`，不改变 `NativeEntry`。

### 24.3 JS wrapper

package 可使用 JS wrapper：

```js
import { add, World } from "fun-native:self";

export { add, World };

export function createDefaultWorld() {
  return new World({ gravity: [0, -9.8, 0] });
}
```

`fun-native:self` 由 fun resolver 映射到当前 package lockfile 对应的 native artifact。用户通常仍 import package name：

```js
import { World } from "@fun/physics";
```

### 24.4 Authority

module resolution 的权威来源是：

```text
package graph + lockfile + resolver
```

plugin descriptor 中的 `package_name/module_name` 仅用于一致性检查和诊断。不得允许动态库通过自报名称劫持其他 package 的 module binding。

### 24.5 构建约束

- 不使用任意 `postinstall` shell script 作为 canonical 构建方式。
- fun 调用受控 native build adapter。
- build input 必须可枚举。
- native dependency 必须进入 lockfile。
- 构建默认禁网。
- package 必须显式标记包含 native code。
- native build 仍是可信代码执行，禁网不等于安全沙箱。

推荐目录：

```text
package/
├── package.json
├── src/
│   └── index.ts
├── dist/
│   └── index.d.ts
└── native/
    ├── build.zig
    ├── build.zig.zon
    └── src/
        └── plugin.zig
```

---

## 25. 构建系统与全局缓存

### 25.1 三种 identity

单一 `artifact_key` 无法同时表达“可复用 recipe”“精确构建环境”和“最终内容”。v1 使用三种 identity。

#### Recipe Key

表示源码和目标合同相同、可查找兼容 artifact 的语义 recipe：

```text
recipe_key = BLAKE3(
    cache_schema_version
  + canonical_native_manifest
  + source_merkle_root
  + native_dependency_lock_digest
  + resolved_native_sdk_digest
  + binding_codegen_schema_version
  + target_triple
  + object_format
  + deployment_baseline
  + libc_or_crt_contract
  + plugin_abi
  + fast_call_abi
  + required_value_abi
  + optimize_mode
  + cpu_feature_baseline
  + canonical_build_options
)
```

Recipe Key 不包含当前 fun runtime version、zjs commit 或当前 bundled compiler version。

#### Build Key

表示可重现的具体构建环境：

```text
build_key = BLAKE3(
    recipe_key
  + toolchain_digest
  + sysroot_digest
  + build_adapter_version
  + normalized_environment_digest
)
```

#### Artifact Digest

表示最终内容：

```text
artifact_digest = BLAKE3(
    normalized_binary_and_resource_bytes
  + canonical_artifact_metadata_without_digest_or_signature
)
```

lockfile 优先固定 artifact digest；CAS 以 artifact digest 为主键。

### 25.2 为什么 toolchain 不进入 Recipe Key

runtime 或 bundled compiler 升级后，已有兼容二进制仍应复用。若 toolchain 进入唯一查找 key，则每次 compiler 变化都会 miss。

因此：

- Recipe Key 可映射到多个由不同 toolchain 生成的 artifact。
- Build Key 用于精确 provenance 和重现。
- Artifact Digest 用于内容完整性和 lockfile 固定。
- fun 只选择满足 target/ABI/deployment/signature policy 的候选 artifact。

### 25.3 查找顺序

```text
1. lockfile artifact_digest 命中且验证通过
  ↓ 未命中
2. recipe index 中存在可信、兼容 artifact
  ↓ 未命中
3. registry prebuilt
  ↓ 未命中
4. 使用 lockfile 解析出的 SDK/toolchain recipe 源码构建
  ↓
5. 写入 CAS，并更新 build/recipe index
```

fun runtime 捆绑的新 SDK/编译器不得覆盖 package lockfile 已解析的 SDK，也不得因此强制重编译旧 artifact。

### 25.4 CAS 布局

```text
$FUN_CACHE_HOME/native/
├── blobs/blake3/<artifact-digest>/
│   ├── artifact
│   ├── artifact.json
│   ├── provenance.json
│   ├── exports.json
│   └── debug/
├── recipe/<recipe-key>/index.json
├── build/<build-key>.json
├── locks/<recipe-key>.lock
└── tmp/<build-id>/
```

`artifact.json` 至少记录：

- artifact digest。
- recipe/build key。
- target/deployment/libc/CRT/CPU baseline。
- ABI tuple 和 required features。
- dynamic dependencies。
- exported module/package diagnostics。
- debug symbol mapping。
- file list、size 和 integrity digest。

### 25.5 并发构建

对同一个 Recipe Key：

- 只允许一个 builder 持有构建锁。
- 其他进程先等待 compatible artifact 出现，而不是固定等待某个 Build Key。
- 构建输出写临时目录。
- 完成 ABI validation、smoke load 和 hash 后 atomic rename。
- 失败不得留下可被 resolver 选中的半成品。
- lock 必须带 PID、start time 和 owner nonce，支持 stale recovery。

该机制不依赖 fun daemon；daemon 仅可优化调度和复用进程内状态。

### 25.6 Compiler object cache

最终 artifact CAS 与 compiler object cache 分离：

```text
Artifact CAS
  └── 输入完全匹配时不调用 linker/compiler

Compiler Object Cache
  └── 源码变化或重建时复用中间结果
```

不得把 compiler object cache hit 误报为“未重新编译 artifact”。

### 25.7 Cache GC

fun 应维护：

- lockfile/reference pin。
- recent-use timestamp。
- artifact size。
- build/recipe reverse index。
- registry origin 和 re-download capability。

GC 删除 blob 前必须原子更新索引，不能留下指向不存在 artifact 的 recipe entry。

---

## 26. Registry Prebuilt

### 26.1 安装流程

```text
解析 package + lockfile + target
  ↓
检查 exact artifact digest
  ↓ 未命中
检查 local recipe candidates
  ↓ 未命中
查询 registry prebuilt manifest
  ↓ 未命中
源码构建
  ↓
验证并写入 CAS
```

### 26.2 Prebuilt 维度

至少包括：

```text
OS
architecture
object format
minimum OS version
deployment target
libc / CRT baseline
Android minSdk / NDK ABI
Plugin ABI
Fast Call ABI
Value ABI，可选
required host features
CPU feature baseline
optimize mode
```

Linux 不能只写 `gnu`；必须记录 glibc baseline 或 musl contract。Windows 必须记录 MSVC CRT contract。macOS/iOS 必须记录 deployment target。Android 必须记录 ABI 与 minSdk。

### 26.3 CPU variants

默认发布保守 baseline，可附加：

```text
baseline
x86_64-v2
avx2
armv8-a
armv8.2-a
```

fun 选择最高兼容版本。用户显式执行：

```bash
fun native rebuild --cpu=native
```

生成的本地优化 artifact 必须进入独立 CAS blob，不覆盖通用版本。

### 26.4 完整性与信任

registry prebuilt 必须验证：

- artifact digest。
- manifest signature。
- publisher/registry identity。
- ABI/deployment metadata。
- dependency file digest。
- revocation status。

验证失败时不得尝试加载；可按 policy fallback 到源码构建。

---

## 27. 平台策略

### 27.1 macOS、Linux、Windows

使用：

```text
.dylib
.so
.dll
```

要求：

- POSIX 使用 local symbol scope 和 eager relocation policy，例如 `RTLD_LOCAL | RTLD_NOW`。
- Windows 使用安全的 `LoadLibraryEx` 搜索策略，不依赖当前工作目录。
- dependent library 必须由 artifact manifest 声明并 materialize 到受控目录。
- rpath/runpath/install-name 必须规范化并进入 artifact validation。
- 应用打包时从 CAS materialize，不重新编译。
- macOS hardened runtime/code signing 信息进入 provenance 和 package pipeline。

### 27.2 Android

使用 ABI-specific `.so`：

```text
arm64-v8a
x86_64
```

流程：

```text
CAS artifact
  ↓
APK/AAB jniLibs materialization
  ↓
platform loader
  ↓
standard PluginDescriptor
  ↓
NativeEntry
```

artifact contract 必须包含 minSdk、NDK ABI、STL/runtime dependency policy。plugin API 不因 Android 改写。

### 27.3 iOS

iOS 不依赖运行时动态插件下载或 `dlopen`。SDK 生成：

- `libplugin.a`。
- unique descriptor symbol。
- host registry record。
- linker anchor / no-dead-strip metadata。

App 构建生成：

```text
fun_register_static_plugins()
```

流程：

```text
CAS libplugin.a
  ↓
App final link
  ↓
static registry
  ↓
PluginDescriptor
  ↓
NativeModuleRegistration
  ↓
NativeEntry
```

iOS 需要 app relink，但 plugin archive 本身在 recipe 未变化时不重新编译。

### 27.4 Static symbol uniqueness

每个 static artifact 使用由 artifact/package identity 派生的 symbol，例如：

```text
fun_native_plugin_v1_a1b2c3d4
```

host generated registry 显式引用 symbol，避免 archive 被 dead-strip，也避免多个 package 导出同名 `fun_native_plugin_v1`。

---

## 28. FFI、Node-API 与 Native Plugin

fun 保留三层能力：

| 机制 | 场景 | 执行路径 |
|---|---|---|
| `fun:ffi` | 临时调用已有 C library | generic FFI/libffi/生成绑定 |
| Node-API compatibility | 兼容现有 `.node` 生态 | managed compatibility adapter |
| Fun Native Plugin | fun 原生插件生态 | NativeEntry typed/fixed fast path |

规则：

- `fun:ffi` 不生成或冒充 canonical plugin descriptor。
- Node-API addon 可在加载后映射为 managed `NativeEntry`，但不能反向决定 FNABI 设计。
- compatibility adapter 的额外 handle/exception/dispatcher 成本应被独立标记。
- fun builtin module 和 Native Plugin 必须共享 zjs native execution core。
- zjs ECMAScript intrinsic 可保留内部 lowering，但不得被宣称为 plugin 可等价能力。

### 28.1 现行 runtime-plugin-abi 的退役（0.3 新增，owner 裁决）

zjs 现行 dynamic plugin ABI（`docs/runtime-plugin-abi.md`：`Plugin.load`/`install`、`zjs.ffi.CallFrame`/`HostServices`/`Status`、`OpaqueHostObject`/`HostTypeId`）自本方案批准起 **deprecated**：

1. 现行 ABI 冻结：不再扩展，只收关键正确性修复；其文档头部标注 deprecated 并指向本方案。
2. FNABI 是唯一继任者。`OpaqueHostObject`/`HostTypeId` 语义由 `NativeObject`/`NativeType` 承接；`CallFrame` trampoline 形态对应 FNABI managed generic entry。
3. **M3 动态 loader 落地后，zjs 内 `dlopen`/loader 与 install 路径移交 fun 并从 zjs 删除**，兑现 §8.2「zjs 不负责 dlopen」。在此之前现行 ABI 维持可用，避免真空期。
4. 表示契约 v1 硬承诺中的「plugin ABI fingerprint 不变」指向现行 ABI，须按契约流程同步修订（先改契约递增版本，再动代码），修订内容 = fingerprint 承诺过渡到 FNABI 的 ABI tuple（§11.5）。
5. 迁移窗口内，同一动态库不得同时导出旧 descriptor 与 `fun_native_plugin_v1`；新旧 loader 各自检测到另一套 symbol 时拒绝加载并报迁移提示。
6. 若存在存量第三方插件，随 M3 发布迁移指南；无存量则窗口结束后直接删除旧路径与文档。

---

## 29. 安全模型

### 29.1 Trust boundary

Native Plugin 与宿主进程拥有相同权限：

- 可读写进程内存。
- 可调用系统 API。
- 可创建线程、文件和网络连接。
- 可使进程崩溃或破坏 GC invariant。

因此 runtime permission API、Host capability table 和 descriptor validation 都不是对恶意 native code 的安全边界。

### 29.2 必须措施

- package manifest 明确标记 native code。
- 安装/首次构建显示 native code trust 提示或受组织 policy 管理。
- lockfile 固定 package、SDK、dependencies 与 artifact digest。
- prebuilt 验证签名和内容 hash。
- source build 默认禁网。
- 禁止隐式任意 postinstall shell script。
- build provenance 记录 SDK、toolchain、sysroot、target 和依赖。
- loader 使用安全 library search path。
- 其他 symbol 默认隐藏。
- descriptor 进行完整一致性验证。
- ABI fuzz 覆盖非法 size/count/pointer/flags/signature/duplicate export。
- 支持组织级 native package/publisher allowlist。

### 29.3 内存和异常边界

- 跨模块内存由原分配方释放。
- 不允许宿主 `free()` plugin allocator 返回的 pointer，除非明确使用共享 allocator API。
- callback payload 必须携带 release callback。
- exception/panic 不得跨 ABI unwind。
- finalizer/destructor 必须 nothrow。
- thread-local state、global constructor 和 dependent library 同样属于 plugin 信任范围。

### 29.4 Build sandbox 限制

受控 build adapter、禁网和输入枚举能提升可重复性与降低误用，但不能将任意 Zig build script 变为安全沙箱。高安全场景应在隔离 worker/container/VM 中构建，再只分发签名 artifact。

---

## 30. 可观测性与诊断

fun 应维护 code address 到 artifact/export 的映射：

```text
PC address
  ↓
NativeImage code range
  ↓
artifact digest / package / module / export
  ↓
build provenance / debug symbols
```

至少提供：

```bash
fun native inspect @fun/physics
fun native inspect --artifact <digest>
fun native doctor
fun native cache status
fun native cache gc
fun native rebuild --cpu=native
```

`inspect` 应显示：

- resolved package/version。
- recipe/build/artifact identity。
- ABI tuple。
- target/deployment/CPU baseline。
- exports、call kind、signature、marshal policy。
- dynamic dependencies。
- local/registry/source-build origin。
- signature/provenance verification。
- 当前进程 image/instance/refcount。

profiler 与 tracing 至少标记：

```text
package
module
export
call kind
artifact digest prefix
builtin/plugin origin，仅作为 attribution
```

origin 只用于诊断，不参与热路径 dispatch。

runtime shutdown diagnostic 应显示 outstanding：

- NativeObject。
- persistent/weak handles。
- AsyncToken/job。
- buffer lease/external buffer。
- late completion。
- PluginInstance lifecycle state。

---

## 31. 性能验收标准

### 31.1 Builtin/plugin 路径一致性

选择同一个 target 实现，分别注册为 builtin 与 plugin：

```text
builtin add
plugin add
```

必须验证：

- 生成相同 machine signature 和 marshal policy。
- 生成相同 `NativeCallPlan`。
- 使用相同 `CALL_NATIVE_*` handler。
- 参数检查、unbox 和 box 指令序列一致。
- 二者都通过 `NativeEntry.target` 调用。
- plugin handler 不读取 owner/provenance/loader metadata。
- plugin 不增加额外来源分支。

### 31.2 Typed thunk

Release artifact 反汇编必须验证：

- target 是准确的 C ABI thunk。
- thunk 内无 generic dispatcher。
- 用户业务函数被内联，或额外 call 被明确报告。
- 无 `argc/argv` array。
- 无 signature switch。
- 无 Host API lookup。

### 31.3 Leaf call

对于：

```js
add(a, b);
```

steady-state 要求：

- 零 JS heap allocation。
- 不创建 `argc/argv`。
- 不创建 general handle scope。
- 不创建 JS call frame。
- 不检查 pending exception。
- 不查询 module/export/symbol/descriptor。
- JS number 语义正确，不依赖当前 internal tag。

### 31.4 Native method

对于：

```js
world.step(dt);
```

要求：

- receiver/property/prototype/type guard 完整。
- NativeObject unwrap 无哈希表。
- `native_ptr` 固定偏移读取。
- disposed 检查可融合。
- 不创建 bound function。
- target 直接接收 `self + primitive`。
- prototype/method mutation 后正确 deopt。

### 31.5 Buffer bulk call

要求：

- fixed backing store 的 borrowed view 不复制数据。
- common path 不分配 JS heap。
- detached/readonly/capacity 检查正确。
- retained/transfer 成本单独测量。
- 不将逐元素 crossing 伪装成 bulk benchmark。

### 31.6 构建复用

以下场景编译器调用次数必须为零：

1. 两个项目安装相同 lockfile artifact。
2. 项目本地目录删除但 global CAS 保留。
3. fun runtime/toolchain 升级，但 lockfile artifact 兼容。
4. 多进程并发安装，已有 builder 成功产出。
5. registry prebuilt 已下载并写入 CAS。

### 31.7 Benchmark 指标

至少覆盖：

- zero-argument leaf。
- one-argument `f64`。
- two-argument exact `i32`，同时测试 int32-tag 与 double-represented integer。
- dynamic NativeFunction call。
- NativeObject method。
- fixed managed Value call。
- TypedArray borrowed/retained bulk call。
- async start/completion。
- builtin/plugin 对照。

指标：

```text
cycles/call
instructions/call
branch misses
L1I/L1D misses
JS heap allocations
native allocations
p50/p99 latency
late completion count
cache hit rate
compiler invocation count
```

机器路径、反汇编和 perf counter 是主要验收依据，wall-clock 平均值仅作为补充。

---

## 32. 正确性与测试策略

### 32.1 ABI conformance

- C 与 Zig `sizeof/alignof/offsetof` golden test。
- 每个 supported target 的 compile-only ABI fixture。
- function pointer prototype fixture。
- struct append-only compatibility test。
- old plugin/new runtime 与 new plugin/old-minor-runtime matrix。
- Value ABI required/optional matrix。

### 32.2 JS 语义测试

至少覆盖：

- `i32` 对 int32 tag 和 double integer 表示结果一致。
- NaN、Infinity、-0、边界整数和越界。
- boolean/string 不发生隐式 coercion。
- user-defined `valueOf/toString` 不在 leaf path 被调用。
- property override、prototype mutation、`setPrototypeOf`、delete 后 method deopt。
- extracted method、`.call()`、`.apply()` 和错误 receiver。
- constructor ordinary/construct call 差异。
- disposed object、double dispose 和 finalizer。
- arity 语义：缺参 → `undefined` → marshal `TypeError`；多参忽略；marshal 错误从左到右顺序（§15.6）。

### 32.3 GC 与 Handle 测试

- managed call 内多次分配与 GC。
- persistent/weak handle 创建释放。
- runtime close 时仍有 handle。
- NativeObject owner edge。
- external buffer finalizer。
- retained buffer lease 与 detach/resize race。

### 32.4 Async 与 race 测试

- complete exactly once。
- duplicate completion。
- cancel-before-start、cancel-during-work、complete-vs-cancel race。
- runtime close 后 late completion。
- hot reload A/B completion 隔离。
- worker 仍运行时 shutdown。
- payload release 在所有路径 exactly once。

所有 race test 应在 TSAN 或等价工具下运行。

### 32.5 Loader 与 fuzz

- malformed struct size/count/name length。
- duplicate export/class method。
- unknown required feature。
- target/signature/marshal mismatch。
- null target/callback。
- invalid metadata kind/size。
- 非零 reserved/padding 字段。
- dependent library 缺失。
- static symbol collision。
- CAS corruption 和 signature mismatch。

### 32.6 Platform matrix

至少覆盖：

```text
macOS arm64 / x86_64
Linux glibc arm64 / x86_64
Linux musl x86_64
Windows x86_64 MSVC
Android arm64-v8a / x86_64
iOS arm64 static
```

---

## 33. 实现阶段与 fun/zjs 拆分

实现按纵向可验收切片推进，不先孤立完成全部 VM 或 loader。

**时序总纲（0.3 裁决）**：M0 是纯合同层（schema/layout test/文档），不碰引擎，与 type-directed 计划的 S0/S1 **并行**推进；**M1 起硬依赖 S1 交付物**——F1 shape identity、F2/Phase 0.5 per-site 侧表、F4 opcode 空间方案——FNABI 不自建平行的 shape/侧表/opcode 基建，共享基建只建一次。`NativeCallPlan` 与 type-directed T3 的 `NativeCallDescriptor` 归一为**单一 schema**（§15.2 的 ID 生成源），两个计划共同消费。与 `gc/tracing` 合入窗口的协调遵循 type-directed P4 条款：shape/字节码大改不与 GC 合入同时在飞。

### M0：冻结合同与生成源

目标：建立唯一 ABI source of truth，禁止实现漂移。

`fun-native-abi`：

- 定义 target contract。
- 定义 Plugin/Fast/Value ABI 版本。
- 定义 descriptor、Host table、signature 和 marshal schema。
- 生成 C/Zig binding。
- 建立 layout golden tests。

zjs：

- 定义私有 `NativeCallPlan` 与 schema 映射接口（与 T3 `NativeCallDescriptor` 归一，单一 schema）。
- 确认 `JSValue` 公开布局与表示契约 v1 / `abi_encoding_revision` 绑定，golden test 对 `src/core/value.zig` 实物。
- 明确一个 runtime/一个 application realm 限制。

fun：

- 定义 artifact sidecar schema。
- 定义 `NativeModuleRegistration` 私有接口。
- 定义 package manifest 与 lockfile 字段。

Zig SDK：

- 建立最小 typed thunk/descriptor generator skeleton。

验收门：

- C/Zig layout 全部一致，且全部公开结构验证无隐式 padding。
- 全部前向引用 ABI 类型定案或显式声明 opaque：`FunPluginInitContextV1`、`NativeExportRegistration`、`FunCallContextV1`、AsyncToken 句柄、`FunBufferLease`、三张 Host table 及 `FunPluginInitHostV1`/`FunRuntimeTargetInfoV1`/`FunErrorSinkV1`。
- C 头 `JSValue` 拼写定案（`zjs_JSValue` tag + 可关闭别名，§12.1）。
- 表示契约修订完成评审：「plugin ABI fingerprint」承诺过渡到 FNABI ABI tuple（§28.1 第 4 条）。
- ABI 兼容规则和 v1 freeze decision 通过评审。
- 不允许在 M0 前发布第三方可依赖的 FNABI v1。

### M1：最小静态端到端链路(v0.4 拆为 M1A/M1B/M1C)

v0.3 曾把 M1 整体前置于 type-directed S1(F1+F2+F4 全就绪)。v0.4
按需求实质拆三段——三种 export 对基建的依赖不同,不应互相等待:

**M1A(FN-M1A)静态 NativeEntry 端到端**——`add(i32,i32)->i32` 与
`managedCreateObject()->object`。**只依赖最小 opcode 编码方案**
(`CALL_NATIVE_*` 的编码位置),不需要 F1 shape identity、不需要
F2/Phase 0.5 侧表。这是第一个「plugin 与 builtin 走同一 NativeEntry」
的端到端证明,可与 typed 主线并行。

**M1B(FN-M1B)NativeClass 方法**——`World.step(f64)->void`。
依赖 **F1 shape identity**(method guard 与纪元验证的依据)。

**M1C(FN-M1C)动态 call quickening**——依赖 **F2/Phase 0.5 侧表**
(quicken 站点载体)。M1A/M1B 的静态直调不经此路径。

依赖边:`FN-M0 → FN-M1A → FN-M1B → FN-M1C`(交付序);硬依赖仅
`F1 → FN-M1B`、`F2 → FN-M1C`。

目标不变:不做动态库/CAS,先证明 builtin/plugin 执行边界一致。

三个 export:

```text
add(i32, i32) -> i32          (M1A)
managedCreateObject() -> object   (M1A)
World.step(f64) -> void       (M1B)
```

zjs：

- `NativeEntry`、`NativeFunction`、最小 `NativeType/NativeObject`。
- `CALL_NATIVE_I32_I32_TO_I32`。
- fixed managed call。
- Native method handler。
- exact callee 与 method guard。

fun：

- 编译期 static registry。
- descriptor copy/validate/normalize。
- 最小 PluginInstance lifecycle。
- 调用 `zjs.registerNativeModule`。

SDK：

- 生成三个 export 的 typed/managed/class glue。
- 生成 unique static symbol。

验收门：

- builtin/plugin 使用相同 NativeCallPlan 和 handler。
- 反汇编无 plugin-specific wrapper/branch。
- prototype mutation 正确 deopt。
- plugin static descriptor 不直接泄漏到 zjs。

### M2：完成 zjs Native Execution Core

zjs：

- 扩展 v1 精选 signatures。
- 实现 canonical marshal policy。
- static ESM binding table 与 bytecode relocation。
- dynamic call quickening/dequickening（含 §17.2 纪元验证/同宽度/backoff 条款）。
- method/property/prototype guards（骑 F1/F5）。
- NativeClass constructor/getter/setter/dispose/finalizer。
- managed frame、local/persistent/weak handle。
- **参照 builtin 对拍集**（0.3 裁决，替代「全量迁移」）：选取代表性 builtin——leaf、managed、native method 各至少一对——以同一实现双注册为 builtin 与 plugin，作为 §31.1 等价性验收的常驻 fixture。
- 存量 builtin 私有注册路径盘点成册，作为独立迁移计划的输入。

fun：

- 扩展规范化 registration builder。
- 增加 diagnostics metadata 映射。

SDK：

- 完整 function/class codegen。
- `.d.ts` 生成。

验收门：

- JS 语义测试全绿。
- 参照对拍集证明 plugin 可达路径与 builtin 路径生成相同 `NativeCallPlan`、相同 handler、逐指令一致。
- 新增 `CALL_NATIVE_*` handler 家族通过 dispatch 布局/I-cache 外部性 A/B（全 corpus，冻结基线交错测量）——新 handler 取指外部性是在册硬门。
- bytecode cache 不保存进程 pointer。

**存量 builtin 迁移（独立分批计划，不在 FNABI v1 关键路径上）**：迁移是收益项（统一路径、typed fast path 惠及 builtin）而非 FNABI 正确性前提。分批推进，每批自带三门：zoo A/B（冻结基线、交错测量，验收尺分辨率 ±0.684% 约束下按批打包裁决）、全量 test262 oracle、新增/改动 handler 的 I-cache 外部性门。任何一批回归即该批回滚，不阻塞 FNABI 主线。

### M3：动态 Loader 与正式 SDK

fun：

- macOS/Linux/Windows loader。
- Process-wide NativeImage registry。
- descriptor symbol lookup、copy、validation。
- per `(Runtime, Image)` PluginInstance。
- dependency/search-path policy。
- static backend 与 dynamic backend 统一到同一 registration。

SDK：

- dynamic symbol/visibility。
- static unique symbol/dead-strip anchor。
- compile-time diagnostics。
- export map 与 provenance metadata。

zjs：

- 完成 NativeBindingOwner retain/release hook。
- profiler/export attribution hook。

验收门：

- dynamic/static artifact 对 zjs 生成完全相同 registration。
- malformed descriptor 不导致未定义读取。
- 同 digest 并发 load 只创建一个 NativeImage。

### M4：Buffer、Async 与完整生命周期

zjs：

- StringView、BufferView、lease、external ArrayBuffer。
- AsyncToken、Promise capability、exactly-once、runtime epoch。
- finalizer queue 和 complete shutdown drain API。

fun：

- thread-safe completion queue 和 wakeup。
- begin_shutdown/cancel/drain/destroy orchestration。
- late completion 和 outstanding resource diagnostics。

SDK：

- buffer type/flags codegen。
- async start/worker/completion adapter。
- ownership/release callback glue。

验收门：

- ASAN/TSAN/race tests 通过。
- runtime close 后 payload exactly-once release。
- 不存在 PluginInstance 先于 object/token/lease 销毁。

### M5：构建、CAS、Prebuilt 与移动平台

fun：

- recipe/build/artifact 三层 identity。
- 全局 CAS、recipe/build index、并发锁和 GC。
- registry prebuilt、签名/hash/revocation。
- lockfile artifact pin。
- Android packaging。
- iOS archive/static registry/final link。
- Windows dependent DLL materialization。
- build provenance 与 native trust policy。

SDK/build adapter：

- reproducible build inputs。
- target/deployment/CPU baseline 输出。
- publish-time `.d.ts` 和 prebuilt manifest。

验收门：

- 所有构建复用场景 compiler invocation 为零。
- runtime/compiler 升级不改变已锁定 artifact 选择。
- Android/iOS/desktop 最终均进入相同 NativeModuleRegistration。

### M6：JIT 优化

zjs：

- NativeEntry call-site profiling。
- direct target patching。
- exact entry/image generation guard。
- NativeObject method direct call。
- typed argument speculation 与 deopt。

fun：

- 向 profiler/symbolizer 提供稳定 code range 和 artifact metadata。
- hot reload 时通知 JIT retirement/deopt。

验收门：

- 注册到统一 NativeEntry 的 builtin 与 plugin JIT lowering 完全一致。
- image A/B hot reload 不发生错误 direct call。
- 不开放第三方 intrinsic ABI。

---

## 34. FNABI v1 冻结决策

完成 M0 后，以下内容冻结：

1. VM 内不存在独立 `PluginFunction` 类型。
2. builtin 和 plugin 都转换为 zjs 私有 `NativeEntry`。
3. steady-state dispatch 不根据 builtin/plugin 来源分支。
4. provenance 与 lifetime owner 保留在冷路径。
5. 一个 native artifact 对应一个 native ESM module。
6. 一个 fun runtime 对外暴露一个 application realm。
7. dynamic plugin 只公开一个标准 descriptor symbol。
8. static plugin 使用 artifact-unique descriptor symbol 和 generated registry。
9. function pointer 与 data pointer 分离。
10. 公开字符串字段均带长度。
11. export metadata 必须 typed、sized。
12. 复合 fast 参数通过指针传递，不按值跨编译器 ABI；唯一例外是 16 字节 `JSValue` 按值传递与返回。
13. v1 target 为 64-bit little-endian 标准 C ABI。
14. Fast Call ABI 与 JS marshal policy 分离。
15. `i32` 语义不依赖 zjs 当前 int32/double 内部表示。
16. leaf entry 不接收 VM、Managed Host 或 CallContext。
17. init、managed、async Host capability 分离。
18. fixed parameters 优先使用 typed signature 或 managed fixed（`JSValue`）形态。
19. generic `argc/argv` 只作为显式 fallback。
20. generated typed C ABI thunk 本身就是 target。
21. NativeObject 由 zjs 固定偏移 unwrap 为 `void* self`。
22. NativeObject 必须保活 PluginInstance 和 NativeImage。
23. borrowed object 必须有 owner edge 或 lease。
24. finalizer 在 runtime thread 执行，nothrow、nonblocking。
25. managed entry 通过 versioned Host table 工作。
26. 公开值类型 = zjs `JSValue`（16 字节 extern tagged，表示契约 v1）；不存在独立 FunValue/PluginValue；typed leaf 不依赖它。
27. native worker 不得访问 JS 或 raw `JSValue`。
28. AsyncToken completion exactly once。
29. runtime close 后 late payload 必须释放但不得触碰 JS。
30. bytecode cache 不保存 NativeEntry/target 裸地址。
31. method fast path 必须守护普通 JS property/prototype 语义。
32. 默认不 `dlclose`。
33. hot reload 使用 side-by-side image/type/instance。
34. cache 使用 Recipe Key、Build Key 和 Artifact Digest。
35. package lockfile 解析出的 SDK 决定 build recipe，runtime bundled SDK 不得强制替换。
36. 安装优先 exact artifact、本地 recipe candidate、registry prebuilt，最后源码构建。
37. TypedArray/ArrayBuffer 支持显式 borrowed/retained/transferred zero-copy contract。
38. zero-copy API 不得静默复制。
39. Android 使用打包 `.so`，iOS 使用静态 archive，但都转换为相同 registration。
40. Node-API、FFI 和 VM intrinsic 不属于 canonical FNABI fast path。
41. guard/quicken 缓存的 callee/entry/type identity 必须经纪元/版本验证；裸指针比较不构成 guard（表示契约 §5.2）。
42. 现行 `runtime-plugin-abi.md` deprecated，由 FNABI 继任；M3 后 zjs 不含平台 loader（§28.1）。
43. v1 不要求存量 builtin 全量迁移；builtin/plugin 等价性以参照对拍集为常驻验收，存量迁移走独立分批计划。
44. FNABI M1 起挂 type-directed S1 之后；shape identity/侧表/opcode 空间/call descriptor schema 与 type-directed 计划共享，不重复建设。

---

## 35. v1 之后的扩展方向

可在后续版本评估：

- 多 application realm 的 per-realm NativeModuleInstance。
- 安全 image unload 与 executable code retirement。
- 更多 typed signatures 和 `f32/SIMD`。
- BigInt/i64/u64 specialized ABI。
- sandboxed out-of-process native service。
- C、Rust、C++ SDK。
- GPU/shared-memory 专用 extension table。
- ahead-of-time direct call relocation。
- plugin capability declaration与组织审计；仍不作为恶意代码安全边界。
- stable profiling/debug metadata standard。
- 搬移/压缩堆（若未来提出）：必须先修订表示契约与 Value ABI，并解决 managed 边界 raw `JSValue` 的地址稳定性（handle 化或调用期 pin）；FNABI 是该讨论的登记利益方（§11.3/§18.1）。

这些扩展不得破坏 v1 的核心边界：fun 负责 package/artifact/lifecycle，zjs 负责 JS/VM 执行，公开 ABI 只冻结跨二进制边界的合同。

---

## 36. 最终调用模型

普通 JS Function：

```text
CALL
  ↓
JS Function
  ↓
JS frame
  ↓
bytecode
```

Native builtin：

```text
CALL_NATIVE_*
  ↓
NativeEntry
  ↓
typed native target
```

Native plugin：

```text
CALL_NATIVE_*
  ↓
NativeEntry
  ↓
typed native target
```

完整结构：

```text
                       zjs builtin descriptor
                               │
                               ▼
JS call ────────────────► NativeEntry ────────────────► Native target
                               ▲
                               │
                    NativeModuleRegistration
                               ▲
                               │
                 fun loader / static registry
                               ▲
                               │
                     FNABI PluginDescriptor
```

最终原则：

> **fun 负责将 native package 解析、构建、验证并实例化为 NativeModuleRegistration；zjs 负责将 registration 转换为 NativeEntry 并执行。构建和加载阶段保留 plugin provenance，steady-state 调用阶段只按 NativeCallPlan 执行，不按来源分支。**

该设计同时获得：

- 与 native builtin 等价的 VM boundary。
- 稳定且最小的公开二进制 ABI。
- zjs GC、bytecode、IC 和 scheduler 的内部演进空间。
- fun package/build/daemon/loader 的独立演进空间。
- 跨 fun 版本和跨项目的 artifact 复用。
- NativeClass 高频 method 的直接调用路径。
- TypedArray/ArrayBuffer 的显式零拷贝合同。
- desktop、Android 与 iOS 的统一插件编程模型。
- Zig comptime 级低样板开发体验。
- 可推理、可测试、可诊断的 async 与 shutdown 生命周期。
