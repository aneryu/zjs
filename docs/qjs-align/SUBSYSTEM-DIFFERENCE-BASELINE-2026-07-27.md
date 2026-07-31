# zjs / QuickJS 子系统差异基线（2026-07-27）

本文按子系统及其生产调用路径记录当前 zjs 与 pinned QuickJS 的实现差异，
作为后续语义对齐、表示收敛和性能归因的基线。它不是“完成度百分比”，也不把
目录名相似、单个绿色门禁或历史性能结果当成实现等价。

## 1. 基线、范围与证据规则

### 1.1 冻结版本

| 项目 | 本文基线 |
| --- | --- |
| zjs | `32e881db1ae0010123f1f5d1652418db58671c41` |
| QuickJS | `/home/aneryu/quickjs`，`04be246001599f5995fa2f2d8c91a0f198d3f34c` |
| QuickJS `VERSION` | `2026-06-04` |
| Zig | `0.16.0` |
| 目标 | 当前 64-bit Linux 主机，zjs 默认 16-byte `JSValue` |
| zjs 构建 | `zig build zjs --seed 0 --summary all`，ReleaseFast |
| qjs 构建 | pinned checkout 的 `make qjs` |

QuickJS 文件和行号均指向上述 commit。zjs 后续若修改任一相关子系统，应先把
新 commit、门禁和测量追加到新的 dated baseline，而不是悄悄改写本文的历史
结果。

### 1.2 证据等级

本文使用以下证据标签：

- **S（source）**：同时检查了 zjs 当前生产源码和 pinned QuickJS 源码。
- **B（binary）**：用当前两个 Release 二进制执行了同一最小探针。
- **T（test）**：执行了仓库门禁、目标 test262 slice 或同一 runner 的外部引擎
  对照。
- **M（measurement）**：固定二进制、绑核并校验输出后测量；结果仍须区分
  核心、VM 和整进程。
- **H（hypothesis）**：由布局、调用链或 profile 提出的候选，尚未用隔离 A/B
  证明。H 不能写成性能结论。

“zjs 与 qjs 输出不同”不自动等于“zjs 错”。本文把差异分成四类：

1. **应对齐 qjs**：qjs 行为属于参考机制，且没有当前规范/门禁反证。
2. **保留 zjs 的当前规范行为**：pinned qjs 有已证实的规范偏差，zjs 不应为
   表面一致而回退。
3. **产品/宿主策略**：不属于 ECMAScript 核心语义，需要单独确定产品合同。
4. **待最小化确认**：目前只有可观察差异，没有足够证据裁决。

### 1.3 本文不证明什么

- test262 绿色只证明 `test262.conf` 选中的边界，不证明整个 ECMAScript 或
  QuickJS C API 等价。
- 两个对象尺寸相同不证明字段顺序、尾随数据、分配次数或缓存局部性相同。
- 单次 microbenchmark 不证明宏基准归因。
- zjs 比 qjs 更快的某个用例不证明该 fast path 可以保留；若机制不是 QuickJS
  已有机制，它仍是对齐策略债。
- QuickJS 本身失败的测试不能作为 zjs→qjs 落后项。

## 2. 结论摘要

1. **当前选定的语言语义覆盖已经很宽，但不是“零已知项”。** 2026-07-27
   报告为 49,775 个选中/跳过项：44,541 passed、25 known failed、0
   unexpected、5,209 feature-skipped。README 和 `COMPATIBILITY.md` 中
   “known file 为空”的旧口径已过时。
2. **当前 25 个 known failure 不是已证实的 zjs→pinned-qjs 差异。** 用 zjs
   runner、同一 harness/config 和 pinned qjs 外部引擎重跑这 25 项，结果为
   `25/25 errors, passed 0`。它们仍是 test262 兼容债，但不能拿来衡量 qjs
   对齐差距。
3. **热点物理布局已经显著接近 qjs。** 默认 64-bit `JSValue`、64-byte
   `Object`、56-byte `Shape`、8-byte `ShapeProperty`、96-byte
   `FunctionBytecode` core header 和 16-byte GC intrusive header 均已对齐
   关键尺寸；但 Shape FAM 顺序、数组 length 存放、TypedArray payload、
   BigInt 表示、FunctionBytecode 尾扩展仍不同。
4. **当前没有 property inline cache。** `src/core/ic.zig` 和
   `-Dzjs_enable_ic` 均不存在；`src/exec/property_ic.zig` 现在是非缓存的直接
   shape/property 快路集合，两个保留的 cached 入口恒 miss。任何仍把 IC
   写成当前能力的文档或性能归因都无效。
5. **仍有 QuickJS 没有的运行时机制。** 主要包括 simple-field constructor
   直接跳过字节码体及其 runtime memo、若干 runtime string caches、
   iterator-next side cache、fused-local rope accumulator、FunctionBytecode
   leaf/call 分类和 zjs-only hot extension。它们必须逐项裁决为“必要的 Zig
   承载差异”或“应删除的非 QJS fast path”，不能笼统算作已对齐。
6. **整进程性能差距主要仍在 VM/调用/对象胶水，不在所有算法核心。** 当前
   指示性 micro/hotpath 中多数用例 zjs/qjs 为 1.24–1.58；484 个 RegExp
   直连核心用例却是 0 mismatch，单次总执行时间约为 qjs libregexp 的
   0.84 倍。不能再用整机 regexp 分数推断 matcher 核心慢。
7. **优先级最高的不是再发明 fast path。** 应先清理非 QJS 机制策略债，
   固化行为差异回归，补齐模块异步 SCC/序列化/embedding 边界的产品决定，
   然后用 PMU 和分层 harness 归因 call/property/typed-array/BigInt。

## 3. 子系统映射总表

| 子系统 | QuickJS 主实现 | zjs 主实现及生产调用者 | 当前判断 | 主要风险 |
| --- | --- | --- | --- | --- |
| 值表示 | `quickjs.h`, `quickjs.c` value macros | `core/value.zig`；所有 VM/builtin/binding | 默认布局高度对齐，alternate 编码不同 | 双表示腐化、plugin ABI |
| runtime/context | `JSRuntime`, `JSContext` | `core/runtime.zig`, `core/context.zig`; `root.zig`, `binding/` | 产品能力更多，状态更大 | 热字段局部性、宿主合同 |
| allocator/RC/GC | qjs allocator + cycle removal | `core/memory.zig`, `core/gc.zig`; 所有分配/析构 | RC/循环回收骨架已对齐，记账/恢复机制更多 | OOM 次序、额外 side tables |
| weak lifecycle | weakref list/count | runtime weak-id 双表、holder list、deferred free | 语义目标一致，表示显著不同 | side-table 成本、重入 |
| string/atom | `JSString` 同时可作 atom body | `core/string.zig`, `core/atom.zig`; coercion/property/regexp | flat/rope 接近，atom 身份分离 | 缓存与 accumulator 非 qjs |
| object/shape/property | `JSObject`, `JSShape`, `JSProperty` | `core/object.zig`, `shape.zig`, `property.zig`; `vm_property*` | 关键尺寸对齐，无 IC | FAM 顺序、tombstone、Proxy 次序 |
| Array | object union fast array + length property | `DenseArrayStorage`, `core/array.zig`, `exec/array_ops.zig` | dense/sparse 模型接近 | length 双状态、sort 算法差异 |
| ArrayBuffer/TypedArray | inline object union cache + linked `JSTypedArray` | out-of-line payload + buffer view list | 现代能力更多，额外间接层 | 每元素 load chain、resize/detach |
| parser | `JSParseState` monolith | `parser.zig` monolith | 形态接近，zjs 加 TS erasure | early-error 边界、源码位置 |
| bytecode/finalize | `JSFunctionDef` → packed FB | `bytecode.zig` FunctionDef/pipeline/FB | opcode 主体对齐，4 个 using opcode 扩展 | zjs-only flags/tail、旧 adapter |
| VM/call/eval | recursive `JS_CallInternal`, C stack locals | `zjs_vm`, `Machine`, `FrameSlab`, tail dispatch | 语义接近，执行形态不同 | leaf 分类、帧税、direct-eval overlay |
| modules | `JSModuleDef` 含 link/eval SCC 状态 | `core/module.zig`, `exec/module*.zig`, `runtime/modules.zig` | 功能通过当前 gate，状态分布不同 | TLA SCC、loader、无序列化 |
| Promise/jobs | generic `JSJobEntry` + promise records | typed `core/jobs.zig` union + exec promise ops | 更强 OOM 事务性 | entry 体积、retry 状态机 |
| generator/iterator | detached stack frames + iterator helper payloads | heap resident frame + typed payloads | 大部分当前语义对齐 | iterator close 与 side cache |
| builtins | `JSCFunctionListEntry` + cproto/magic | per-domain `InternalRecord` + typed dispatch | 结构方向接近，表面有扩展 | 通用 dispatch 税、表面漂移 |
| RegExp | `libregexp.c`/`libunicode.c` | `libs/regexp.zig` + exec adapter | 核心当前 484/484 输出一致 | wrapper/VM/字符串成本 |
| BigInt | FAM two's-complement limbs | wrapper + sign/magnitude limb slice | 语义覆盖宽，物理表示不对齐 | 双分配、缓存与算术局部性 |
| number/dtoa | `dtoa.c` | `libs/number_format.zig` | 算法直接移植 | JSValue/string glue |
| host/CLI/API | qjs/qjsc/quickjs-libc/C API | Zig API、CLI、runtime helpers/plugins | 产品定位不同 | 误称 drop-in、缺 AOT/serialization |
| runner/validation | qjs test262 runner/config | richer Zig runner/report/external engine | zjs 工具更强 | config 边界不可直接横比 |

## 4. 产品、构建、CLI 与公开 API

### 4.1 CLI 表面（B/S）

zjs 当前提供：

```text
zjs [-d] [-T] [--profile-opcodes] [--perf-json] [--leak-check]
    [--memory-limit n] [--stack-size n] [-I file] -e <script>
zjs ... [-m] <file.js>
```

pinned qjs 还提供 `-h/-i/--script/--strict/--std/--no-unhandled-rejection/
--strip-source/-q` 等入口。两者的 `print` 也不是同一产品合同：

- zjs 默认走 ECMAScript 风格字符串转换。
- qjs CLI inspector 会把 BigInt 打印成 `3n`，并以 inspector 格式打印数组和
  对象；`String(3n)` 在两个引擎中一致。

因此所有跨引擎 benchmark 必须先校验 stdout，但不能把 `print` 格式差异误判为
BigInt 或对象语义差异。

zjs 对 `.ts/.mts/.cts/.tsx` 走 lexer 的 TypeScript syntax erasure。它不是
TypeScript 类型检查器，也没有承诺 source-map 或 `tsc` 等价。`-T` 是运行时
trace 选项，不是“启用 TypeScript”。

### 4.2 embedding/API（S）

QuickJS 的公开边界是 C API：runtime/context/value、class/exotic callback、
module loader、promise rejection tracker、interrupt、shared buffer callback、
对象序列化/反序列化及 `qjsc` AOT 工作流。

zjs 是 Zig-first API：

- `src/root.zig` 暴露 runtime/context/value 和模块化 namespace。
- `binding/` 提供 handle scope、persistent/weak handle、typed native object
  factory、FFI/plugin 指纹。
- `runtime/` 提供 event loop、文件模块图、cleanup、buffer 和 plugin 策略。

zjs 不是 QuickJS C API 的 drop-in replacement。当前没有与
`JS_WriteObject` / `JS_ReadObject` / `JS_EvalFunction` / `qjsc` 等价的公开
字节码序列化与加载链。这不是普通“漏一个 builtin”，而是 embedding、worker
消息和预编译产品能力的边界决定。

### 4.3 CLI teardown 策略（S）

正常 zjs CLI 路径允许进程退出交给 OS 回收；完整 runtime destroy 主要由
`--leak-check` 和测试路径强制执行。这与 qjs CLI 的常规显式 teardown 不同。
它不改变单脚本语言结果，但会影响：

- CLI 退出时的 finalizer/宿主资源可见性；
- RSS/析构时间 benchmark；
- “能运行完”与“runtime 可安全复用/销毁”的判定。

后续性能报告必须同时说明是否包含 teardown；泄漏和生命周期验收不能用默认
CLI happy path 代替 embedding destroy 测试。

## 5. `JSValue`、runtime/context 与 handle

### 5.1 默认表示（S/T）

64-bit 默认模式中，zjs 与 qjs 都使用 16-byte payload + signed tag，核心 tag
语义和 immediate/reference 分类对应。zjs 通过访问器封装字段，并在编译期断言
`@sizeOf(JSValue) == 16`。

zjs 还永久支持 `-Dzjs_nan_boxing=true` 的 8-byte alternate representation：

- zjs 使用 48-bit payload window 的自定义 dense encoding。
- QuickJS narrow/NaN-boxing 布局是高 32-bit tag + 低 32-bit payload 的体系。

所以 alternate 模式是**语义与所有权守卫**，不是 bit-for-bit QuickJS ABI。
触及 value 表示时必须执行 `test-altrepr`，并在 64-bit stage-close 以显式
NaN-boxing 跑 test262。

### 5.2 runtime/context 差异（S）

共同点：

- 单 runtime/owner thread 变异；
- runtime 持 atom/class/shape/GC/job/module loader/exception/interrupt 状态；
- context/realm 隔离 global 与 intrinsic。

zjs 增加了 QuickJS core runtime 没有的宿主状态：

- `MemoryAccount`、external-memory token、硬限制、trace/profile；
- handle/root provider、active value roots；
- deferred native/class/weak cleanup；
- runtime plugin/external host-function registry；
- `VmStackArena`、host completion event、opcode profile；
- 多组字符串和 iterator side cache。

这些能力对 Zig embedding 有价值，但也让 `JSRuntime` 远大于 qjs runtime，并使
每次 call/property/string 路径可能触达更多 cache line。不能只比较 `JSObject`
尺寸就断言内存模型已经完全对齐。

### 5.3 handles（S）

QuickJS 主要依赖显式 `JS_DupValue`/`JS_FreeValue` 和 C 栈帧扫描/约定。zjs
另外提供：

- `HandleScope` / local handle；
- `Persistent`；
- weak persistent；
- root provider 和显式 `ValueRootFrame`。

这是公开 embedding 扩展，不应为结构对齐而直接删除。后续优化的约束是：宿主
安全边界保留，但 VM 内部不可把每个临时值重新走通用 handle 注册。

## 6. allocator、引用计数、循环回收与 weak lifecycle

### 6.1 物理前缀和 RC（S）

两边当前关键布局：

| 结构 | qjs | zjs |
| --- | --- | --- |
| allocator/GC metadata prefix | `JSMallocBlockHeader` 8 B | `gc.Metadata` 8 B |
| intrusive GC header | `JSGCObjectHeader` 16 B | `GCObjectHeader` 16 B |
| flat string RC prefix | `__js_rc` 4 B | `StringHeader` 4 B |
| object refcount | allocator block header | `Metadata.rc`，位于 payload-4 |

zjs 的 metadata 与 small-object slab header 叠合，并保存 slab class/GC flags；
大对象和 FAM 也经 `MemoryAccount` 统一记账。逻辑 memory limit 因而可能与 qjs
基于 allocator usable size 的精确触发边界不同，即使用户传入同一个字节数。

### 6.2 collector（S/T）

两者都是：

- 非原子 RC 负责大多数即时释放；
- intrusive GC list；
- zero-ref 收集；
- trial-deletion 风格循环识别与释放；
- 非移动、单线程。

zjs 当前 HEAD 已把 zero-ref/cycle partition、sibling edge release 和 weak-husk
次序继续向 qjs 收敛。`gc.Policy` 中虽然保留
`enable_concurrent_mark/sweep/selective_evacuation` 字段，但默认均为 false，
当前也没有可工作的 concurrent/generational collector。文档和产品材料不得把
这些 policy 字段写成已实现能力。

### 6.3 zjs 的附加安全/恢复机制（S）

zjs 额外维护：

- external memory token 和 RSS/cgroup policy；
- OOM injection corpus 与 same-runtime recovery canary；
- 延迟 finalizer/weak free 队列；
- host/root-provider roots；
- allocation profile 和 force-GC 测试模式。

这些差异意味着严格对齐时应比较“用户可见顺序、所有权和失败恢复”，而不是要求
两个 runtime 在第 N 次底层 malloc 同时 OOM。

### 6.4 weak identity（S）

QuickJS 用 `weakref_count`、weakref header/list 和对象地址生命周期配合。zjs
给 weakly-held object 分配单调递增 `weak_id`，runtime 保存：

- object address → weak id；
- weak id → live object；
- weak-holder intrusive list；
- cleanup identity set 和 deferred weak frees。

优点是避免地址复用 ABA，并把 live identity 查询变为 O(1)；成本是两个 hash
table、注册/注销和 teardown 重入状态。该差异属于明确的安全/embedding 设计，
优化前必须用 weak-heavy RSS、allocation count 和 GC-cycle profile 定量，不能
仅凭字段数决定回退。

## 7. string、atom、Unicode

### 7.1 flat string 与 rope（S）

共同点：

- latin1/UTF-16 两种 flat payload；
- flat `String` body 12 B，前置 4 B RC；
- concatenation 可形成 rope，按阈值 flatten/rebalance；
- Unicode helpers 与 regexp 共用表/算法。

主要结构差异：

- qjs 的 `JSAtomStruct` 就是带 atom metadata/hash chain 的 `JSString` body；
  atom→string 可以直接 dup 同一个 body。
- zjs 的 `AtomTable.DynamicAtom` 与 `String` 分离，保存 bytes/map/refcount，并
  可惰性 materialize 一个 string，string 用弱 `atom_id` 回指。

该分离降低了 core string 对 atom table 的耦合，但增加 atom↔string 转换、
side cache 和双份 metadata 的风险。

### 7.2 当前 runtime string caches（S）

zjs runtime 当前持有：

- 128 个 single-byte strings；
- empty string；
- recent two-code-unit string；
- 4-way recent atom strings；
- 256 个 `%XX` strings；
- 256 个 small-int strings。

需要区分：

- empty/atom-string 复用在 qjs 中有“atom body 本身就是 string”的对应机制；
- single-byte、two-unit、`%XX`、small-int 的 runtime cache 在 pinned qjs
  没有同形机制，qjs 相应路径通常新分配 flat string。

后四类是明确的对齐策略债。保留它们需要单独的产品决定和真实性能证据；否则
它们不能作为“比 qjs 快”的合法依据。

### 7.3 fused-local accumulator（S）

zjs `StringRope` 可附带 `RopeTailState`，由 fused `add_loc` accumulator 在
`s = s + x` 类循环中追加可增长 tail。qjs 有 rope 和 `StringBuffer`，但没有
这个挂在 JS rope 上、由局部更新识别驱动的 sidecar。

它已经进入生产语义路径，因此应列为 P0 机制审计项：

1. 用 bytecode 对照确认哪些源码形态会触发；
2. 覆盖 alias、getter/valueOf 重入、closure capture、异常和 OOM；
3. 隔离测量 rope 核心、VM dispatch、RSS；
4. 若无 qjs 对应机制，按项目的“不要加 qjs 没有的 fast path”原则移除，而非
   继续扩大识别范围。

## 8. object、shape、property、Proxy

### 8.1 关键布局（S/T）

| 结构 | qjs 64-bit | zjs 默认 |
| --- | ---: | ---: |
| `JSObject` / `Object` | 64 B | 64 B |
| `JSShape` / `Shape` fixed header | 56 B | 56 B |
| `JSShapeProperty` / `shape.Property` | 8 B | 8 B |
| `JSProperty` / `property.Entry` | 16 B | 16 B（默认 16-byte value） |
| class union | 24 B | 24 B |

zjs `Object` 的 bytecode-function 与 RegExp 数据已经进入 24-byte union；
Map/Proxy/native function/iterator/Promise 等许多 class 仍以 union 中一个 payload
pointer 指向独立分配。尺寸相同不代表 class object 的分配数相同。

### 8.2 Shape FAM 顺序（S）

两边都把 property hash buckets 和 `ShapeProperty` 放在 Shape 同一 FAM
allocation，但顺序不同：

```text
qjs: [56-B Shape][hash buckets][ShapeProperty array]
zjs: [56-B Shape][Shape Property array][hash buckets]
```

zjs 这样做使 `props()` 位于固定偏移，qjs 使 hash buckets 位于固定偏移。
总字节数可相同，但 property scan、hash probe 和 relocate 的 cache locality
不同。任何调序提案都必须以代表性 shape size 分桶测量，不能只看一条汇编。

### 8.3 deletion/tombstone（S）

两边删除属性时都会留下可复用/待 compact 的 slot，并维护 deleted count；
并非每次 delete 都物理移动后续属性。差异主要在 rebuild/compact 门槛、shape
relocation 和 zjs 的显式 owner/registry 协调。后续不要再基于“qjs 每删一次就
compact”这一错误假设做优化。

### 8.4 当前没有 inline cache（S）

当前事实：

- `src/core/ic.zig` 不存在；
- build 没有 `zjs_enable_ic` option；
- FunctionBytecode 没有 `ic_slots/ic_site_ids/ic_sites`；
- `property_ic.cachedDataPropertyValueForFastPath` 恒返回 `null`；
- `cachedSetObjectDataPropertyForPutFastPath` 恒返回 `false`。

`src/exec/property_ic.zig` 的名称是历史残留。它仍提供有价值的 ordinary own/proto
data-property、global slot 和 simple-put 直接 lookup，但这些是每次执行的
shape/hash 快路，不是 per-site cache。性能报告必须把
`prop_read_mono_loop` 当作 property-walk sentinel，而不是 IC hit benchmark。

### 8.5 当前可观察对象/Proxy 差异（B）

| 探针 | zjs | qjs | 裁决 |
| --- | --- | --- | --- |
| `Object.defineProperties` 的 Proxy traps | `ownKeys,gopd:a,get:a,gopd:b,get:b` | `ownKeys,gopd:a,gopd:b,get:a,get:b` | zjs 符合当前算法的逐 key descriptor/get 次序；不要为 qjs 批处理回退 |
| sealed array 上失败的 `Reflect.defineProperty(a,"3",...)` | `false`，length 仍 1 | `false`，length 变 4 | qjs 在 validation 前更新 length；保留 zjs |
| `toReversed` Proxy | `get:length,get:1,get:0` | 额外 `has:1,has:0` | zjs 对应直接 Get；保留 zjs 并加回归 |
| array iterator，length=`2**40` | 正常产生索引 0、1 | 立即 done | qjs 32-bit clamp；保留 zjs ToLength |
| bound function own keys | `name,length` | `length,name` | 应最小化；很可能是 zjs 属性创建次序债 |
| bound function `toString`，重定义 name | `function() { ... }` | `function custom() { ... }` | builtin/native string 允许实现差异；先定产品合同 |
| side-effect comparator 的 sort 调用序列 | 与 qjs 不同 | 与 zjs 不同 | 稳定结果通过；调用序列未规范固定，不作为默认对齐目标 |

对象修复的原则是：普通内部路径尽量镜像 qjs，但不能复制已由规范算法和
test262 反证的 qjs bug。

## 9. Array

### 9.1 表示（S）

qjs fast array union 保存 allocated `size`、element pointer 和 dense `count`；
可见 `.length` 是 shape/property slot。

zjs `DenseArrayStorage` 在同一 24-byte union 中保存：

- values pointer；
- dense count；
- capacity；
- visible length；
- padding。

zjs 选择把 length 镜像成 scalar，避免为普通 array 读取 property slot；因此
必须永久维护 `length >= count` 和 property/exotic 边界。这是相同对象尺寸下的
真实表示差异。

两边都在连续 append/read/write 时用 dense storage，遇到高位稀疏、descriptor、
accessor 等情况退到 shape property。zjs 最近的 sparse own-int read/write、
append/grow 和 prototype writable-data set 已按 qjs 操作路径收敛。

### 9.2 算法差异（B/S）

当前 sort 使用不同的比较调度。对 `[5,3,4,1,2]`：

```text
zjs: 5:3,4:1,3:1,3:4,5:4,1:2,3:2
qjs: 5:3,5:4,3:4,5:1,4:1,3:1,5:2,4:2,3:2,1:2
```

只要稳定排序结果和 comparator 规定满足规范，这不是默认 bug；但 comparator
带 mutation/exception 时仍要以 test262 和最小 probe 固化 completion/side
effect 边界。

## 10. ArrayBuffer、TypedArray、DataView、Atomics

### 10.1 qjs 结构（S）

qjs：

- `JSArrayBuffer` 保存 byte/max length、detached/shared、data、view list 和
  free callback；
- `JSTypedArray` 在 buffer view list 中，保存 object/buffer/offset/length/
  `track_rab`；
- `JSObject.u.array` 同时缓存 typed-array data pointer 和 live count。

每元素热路径可以从 object union 直接取得 ptr/count。

### 10.2 zjs 结构（S）

zjs：

- `BufferPayload` 是 out-of-line payload；
- 32-byte inline byte storage，小 buffer 不另分 data allocation；
- external deinit/token、shared-store atomic RC、immutable flag；
- intrusive `first_view` list；
- `TypedArrayPayload` 也是 out-of-line，缓存 `live_length` 和 `data`，并有
  buffer prev/next/backing pointer。

detach/resize/release 会 invalidate 或更新所有 view cache。该机制补上了 qjs
object union ptr/count 的效果，但元素访问仍多 payload load，buffer/view 本身
也多独立对象或状态。

### 10.3 产品扩展（S/B）

zjs 当前另外实现：

- immutable ArrayBuffer、`sliceToImmutable`、`transferToImmutable`；
- `Atomics.waitAsync` 及跨线程 host completion；
- `import bytes` 使用 buffer 边界。

这些能力在 pinned qjs config 中被跳过，不应作为 qjs 缺失 bug；它们需要独立
规范门禁。

### 10.4 性能假设（H）

当前 whole-process typed-array read/write 约为 qjs 的 1.38/1.51 倍。可能来源：

- out-of-line payload/data/live-length load chain；
- value coercion 与 typed builtin dispatch；
- buffer view-list 安全检查；
- CLI/startup 固定成本。

不能据此直接把 `live_length` 再复制进 Object，或绕过 detach/immutable/
resizable 校验。正确下一步是 direct typed-array kernel + VM element opcode +
whole-process 三层测量，并记录 instruction/allocation/load attribution。

## 11. parser、语法与 TypeScript erasure

### 11.1 parser 形态（S）

QuickJS 的 lexer/parser/emitter 主要集中在 `quickjs.c`，`JSParseState` 贯穿产生式。
zjs 的 `parser.zig` 同样是单体 parser/emitter。这种单体性本身不是应拆分的
架构缺陷；强拆会把 parse state 跨文件穿线，且不会自动改善语义或性能。

zjs 额外支持按扩展名启用 TypeScript range marking/erasure。该路径的风险：

- type-only/import/export/class syntax 与 JS early error 交叉；
- erased range 后的 line/column 和 ASI；
- TSX token ambiguity；
- OOM 时 interval 所有权。

### 11.2 当前 25 known 中的 parser 相关项（T）

7 个 Annex B call-expression assignment-target 文件在 zjs 中是 early
`SyntaxError`；pinned qjs 在相同 runner 中也失败。另 13 个旧 assignment /
compound-assignment 文件和 3 个 SpiderMonkey staging lexical/function 文件
也不是当前已证实 zjs→qjs 差异。

这不表示可以忽略它们：若目标是更广 test262/spec 兼容，应建立独立 issue；
若目标是 QuickJS 忠实对齐，不应把它们放入“落后 qjs”优先级。

## 12. bytecode、finalize 与 `FunctionBytecode`

### 12.1 opcode 对应（S）

zjs 的 QuickJS opcode metadata 顺序保持 pinned qjs 主表，并在 real opcode
尾部增加 4 个 explicit-resource-management opcode：

```text
244 using_create_stack
245 using_add_resource
246 using_dispose_stack
247 using_dispose_stack_for_throw
```

metadata table 因 tail/temp/short opcode entries 为 263 个 qjs entries + 4 个
zjs entries。扩展是功能差异，不应插入 qjs opcode 中间破坏已有 ID。

两边都定义 `tail_call` / `tail_call_method` opcode；默认 source compiler 当前
都产生普通 call+return，而不是产品级 proper-tail-call lowering。zjs
`test262.conf` 明确跳过 35 个 `tail-call-optimization` 测试。VM 支持手写/
内部 tail opcode 不等于源码 PTC 已支持。

### 12.2 `FunctionBytecode` 布局（S/T）

QuickJS 的 `JSFunctionBytecode` 在当前 64-bit build 中是 128 bytes：
`debug` 字段从 offset 96 开始，占固定 32 bytes；`has_debug` 决定内容是否有效，
不缩小 C struct。zjs 把前 96 bytes 固定为 align-8、字段 offset 对应的 core
header，并把 debug 改成可选 inline tail。两边都把 bytecode、cpool、vardefs、
closure vars 组织为 self pointers/FAM，并由 GC 管理 realm 与 constants。

zjs 进一步有：

- debug info 是 optional 32-byte inline tail；生产通常启用；
- code 末尾再放 8-byte `FunctionBytecodeHotExtension`：
  `call_facts + script_or_module`；
- `call_facts_mirror` 放进 qjs header 的 padding hole；
- `ExecutionFlags` 记录 mapped arguments、simple inline eligibility、
  empty/exact/capture leaf kind、module 与 plain-call rejection；
- legacy non-escaping adapter 仍以负 `byte_code_len` sentinel 存在于测试/边界
  路径。

因此 production 常见 fixed/tail 开销不是“只有 96 B”：在 pools/code 之外至少
有 96 core + 32 debug + 8 zjs extension。核心 offset 对齐与完整 allocation
等价必须分开陈述。

### 12.3 编译期载体（S）

QuickJS：`JSFunctionDef` 中 DynBuf 经 resolve/optimize/finalize 后一次 packed
到 `JSFunctionBytecode`。

zjs：`FunctionDef` 经 `bytecode.zig` pipeline，最终 packed 到 canonical
`FunctionBytecode`；module record 的 `func_obj` 也持 canonical function
object/FB，不再把 legacy `Bytecode` 作为生产 module root。

当前 active 文档中“module root 仍是 legacy Bytecode”和“FunctionBytecode 有
IC slots”的描述均已失效。

## 13. VM、frame、call、eval、exception

### 13.1 执行形态（S）

QuickJS `JS_CallInternal`：

- C 函数内保存 `JSStackFrame`；
- 常规调用递归进入 `JS_CallInternal`；
- args/locals/operand 常从 C stack `alloca` 或 async heap state 取得；
- switch/computed-goto handler 在同一 C 函数中直接访问 locals。

zjs：

- `zjs_vm.zig` + `tailcall_dispatch.zig`/opcode shards；
- `Frame`/`FrameSlab` 和 runtime `VmStackArena`；
- `Machine` 在同一 dispatch loop push/pop 多个 bytecode frame；
- generator/async suspend 时把 resident frame 所有权移入 heap payload；
- Zig error 与 runtime pending exception 共同传播；
- backtrace frame/source location 显式维护。

same-Machine inline frame 是为避免 Zig/native recursion 和重复分配形成的承载
差异，不应简单删除；但它必须保持与 qjs 每次 call 的 stack limit、interrupt、
realm、argument padding、exception/finally 和 frame teardown 次序一致。

### 13.2 非 qjs 调用机制（S）

当前 zjs 还发布并消费：

- empty/exact-args/capture/padded-args leaf 分类；
- forwarded `Function.prototype.call` leaf；
- narrow leaf frame constructor/return epilogue；
- `simple-field constructor` 模式识别，直接建对象和写字段，跳过函数字节码体；
- runtime 单条 `simple_ctor_memo`，以 FB 地址缓存最多 8 个字段模式。

pinned qjs 没有扫描 constructor bytecode 并直接跳过函数体的机制，也没有上述
FB leaf metadata。即使 probe 与 test262 当前绿色，它们仍违反“只采用 qjs
已有 fast path”的默认纪律，必须列为 P0 审计/删除候选。尤其不能以
simple-constructor benchmark 的优势证明它们正确。

### 13.3 call 性能（M/H）

当前 whole-process hotpath：

| case | zjs/qjs |
| --- | ---: |
| `fib_rec` | 1.33 |
| `call_body_loop` | 1.35 |
| `method_call_loop` | 1.29 |
| `alloc_call_loop` | 1.28 |

这些 case 特意避开最窄的函数体 fusion，说明通用 frame/call 固定税仍约
28–35%。下一步应按 qjs `JS_CallInternal` 的实际步骤分解：

1. callable/class/realm resolution；
2. stack-limit/interrupt；
3. args pad/copy；
4. frame publish；
5. handler entry/return；
6. RC teardown。

先以 instructions/allocations/load-chain 归因，再做一刀一 A/B；不要再新增
body pattern cache。

### 13.4 eval/VarRef（S/B）

`VarRef` 的 open `pvalue` 与 detached owned `value` 总体向 qjs 收敛，zjs 另有
所有权 bits 和 typed helpers。direct eval 当前关键 lvalue probe 与 qjs 一致。

机制仍不同：

- qjs 编译 direct eval 时把可见 caller bindings capture 成 closure refs；
- zjs 部分路径使用 caller frame overlay/name pre-scan。

这会影响 eval-heavy 性能、binding shadow/redeclaration 和 OOM rollback。它是
语义风险区，但不是当前普通 call hotpath 的默认优化入口。

## 14. modules、dynamic import 与序列化

### 14.1 record/state 差异（S）

QuickJS `JSModuleDef` 同时保存：

- requests/imports/exports/star exports；
- module namespace、function/C init；
- link/eval DFS index/ancestor/stack；
- async parent modules；
- pending async dependencies；
- async-evaluation timestamp；
- cycle root；
- promise capability/resolving functions；
- cached evaluation exception、import.meta/private value。

zjs `ModuleRecord` 保存 definition/request/import/export/namespace/func_obj、
link DFS、TLA flag 和 cached exception；async evaluation continuation、parent/
pending/cycle/promise 等状态更多分布在 `exec/module_graph.zig` 的图和 job/
Promise 状态中，而不是逐字段镜像在 record。

当前 TLA、dynamic import 和 live-binding 的选定门禁通过，只能说明行为覆盖；
分散状态仍增加 SCC error propagation、重复 import、cycle root promise identity
和 teardown/OOM 的验证负担。

### 14.2 zjs 模块扩展（S/T）

zjs 当前启用：

- arbitrary module namespace names；
- import attributes；
- JSON module；
- import text；
- import bytes；
- runtime file module graph。

pinned qjs config 跳过其中若干 proposal。它们应继续由对应 test262/host fixture
验证，不应通过模仿 qjs 的 skip 来“对齐”。

### 14.3 缺少的 qjs 产品能力（S）

zjs 没有公开等价的：

- C module init ABI；
- `JS_WriteObject`/`JS_ReadObject` bytecode/object serialization；
- `JS_ResolveModule`/`JS_EvalFunction` 预编译装载；
- `qjsc`。

是否补齐取决于产品目标。若需要 worker、snapshot 或 AOT，这一项应高于微小
VM 优化；若只定位 Zig embedded source evaluator，应明确写进 LIMITATIONS，
不要以“未来可能”模糊合同。

## 15. Promise、jobs、generator、iterator、weak collections

### 15.1 job queue（S）

qjs `JSJobEntry` 是 `realm + job_func + argc + argv[]` 的通用 FAM，promise
reaction 等状态主要在 Promise/函数对象记录中。

zjs `core/jobs.zig` 用 tagged union 区分：

- generic；
- promise/reaction/thenable/settlement；
- dynamic import；
- Atomics waiter；
- finalization。

zjs entry 显式保存 phase、symbol root mask，并允许预留队列后 no-fail commit，
以避免 OOM retry 重复调用用户代码。代价是 entry/dispatch 更大。该差异属于
正确性和恢复能力设计，优化必须保留 once-guard 与 transactional publication。

### 15.2 generator/async（S/B）

QuickJS async/generator state 在 heap 中保存 detached `JSStackFrame` 和其后
args/locals/stack/var_refs。zjs resident Frame 在 suspend 时转移其 storage
ownership，resume 再装回；普通同步 frame 才优先使用 runtime arena。

当前 async-generator yield/await Promise 的目标 probe 已与 qjs 对齐。不能把
generator frame 强塞回借用 arena，否则 suspend 必须复制并重写内部指针。

### 15.3 iterator close 差异（B）

| 探针 | zjs | qjs | 当前裁决 |
| --- | --- | --- | --- |
| `Iterator.prototype.flatMap` active inner 的 `.return()` | inner 一次，再 outer | inner 两次，再 outer | qjs double-close；保留 zjs 并回归 |
| spread 中 iterator `.next()` 自身抛错 | 不调用 `.return()` | 调用 `.return()` | 待按精确算法/当前 test262 最小化，不先站队 |

zjs 还在 runtime side table 缓存某些 iterator object 的 `next`。qjs 通常在一次
IteratorRecord/operation 中保存 next method，没有同形的跨操作 object side
cache。该缓存必须证明所有 mutation/proxy/invalidation 路径，或按非 qjs
机制移除。

## 16. builtins 与全局表面

### 16.1 实现结构（S）

qjs 把每域 `JSCFunctionListEntry` 放在 C method bodies 附近，通过 function
object 中 `realm/cproto/magic/function pointer` 分发。

zjs 已移除旧 `src/builtins/` 层：

- `core/host_function.zig` 定义 `NativeCProto`/typed pointer variant/
  `InternalRecord`；
- `exec/internal_builtins.zig` 聚合 per-domain table；
- `exec/standard_globals.zig` 按固定顺序安装；
- `exec/builtin_dispatch.zig` 做 typed native dispatch；
- 各域 method body 在 `exec/*_ops.zig`。

总体方向接近 qjs，但某些域仍经 name/magic/switch 和通用 coercion glue。应按
实际 record/cproto 逐域测量，不再恢复独立 builtin layer。

### 16.2 当前 global own-key 差异（B）

当前同一探针：

- zjs global own keys：76；
- qjs global own keys：68。

qjs-only：

- global `Symbol.toStringTag` own symbol；
- `__loadScript`。

zjs-only：

- `AsyncDisposableStack`；
- `DOMException`；
- `DisposableStack`；
- `SuppressedError`；
- `TypedArray`；
- `atob` / `btoa`；
- `gc`；
- `navigator`；
- `queueMicrotask`。

prototype/static 表面还包括：

| zjs-only 当前表面 | qjs-only 当前表面 |
| --- | --- |
| `Array.fromAsync` | `Function.prototype.fileName/lineNumber/columnNumber` |
| immutable ArrayBuffer accessors/methods | `Set.groupBy` |
| `Atomics.waitAsync` |  |
| `Promise.allKeyed/allSettledKeyed` |  |
| RegExp legacy statics (`$1`…`$9` 等) |  |
| `Iterator.zip/zipKeyed`、`Iterator.prototype[Symbol.dispose]` |  |

key 存在只证明表面，不证明 descriptor、realm、species、side effect 和异常次序。
每个产品扩展都应在 compatibility 文档标明来源：现行标准、proposal、legacy
compat 或 zjs host helper。

## 17. RegExp

### 17.1 实现（S）

qjs 使用 `libregexp.c` + `libunicode.c`；zjs 在 `libs/regexp.zig` 中实现 parser/
compiler/matcher，并由 `exec/regexp_*` 处理 JS object、lastIndex、species、
legacy statics 和字符串转换。

当前报告中：

- `built-ins/RegExp`：1,879 passed、0 failed、0 known；
- `RegExpStringIteratorPrototype`：17 passed。

### 17.2 直连核心对照（M/T）

命令：

```sh
taskset -c 19 env \
  QUICKJS_DIR=/home/aneryu/quickjs \
  JAVASCRIPT_ZOO_DIR=/home/aneryu/javascript-zoo \
  tools/regexp-direct-demo/run.sh
```

从 JavaScript Zoo `bench/regexp.js` 提取 484 个 case；每 case compile 100 次、
exec 1,000 次、warmup 20。当前单次结果：

| phase | match-count mismatch | zjs total / qjs total | per-case ratio geomean |
| --- | ---: | ---: | ---: |
| compile | 0 | 0.9518 | 0.9496 |
| exec | 0 | 0.8393 | 0.5617 |

这是直连 facade/libregexp 核心的单次绑核测量，不是稳定发布分数；它足以否定
“当前 regexp 整机慢，所以 matcher 核心一定慢”的归因。后续应分别测：

1. compile/matcher direct；
2. `RegExp.prototype.test/exec` object wrapper；
3. VM call/property/string conversion；
4. whole process。

### 17.3 可观察差异（B）

- `RegExp.prototype.compile` 对 subclass receiver：zjs 抛 TypeError，qjs 接受并
  编译；zjs 当前选择 enabled `legacy-regexp` test262 行为。
- `RegExp.escape` 对 Latin1/C0/DEL 的输出：zjs 符合当前 proposal/test262
  精确转义，pinned qjs 有过度转义。
- 删除实例 `@@match` 后调用相关路径：两边都 TypeError，但 message 不同。

前两项不应为 qjs 表面一致而回退；error message 若进入产品合同，应单独列出。

## 18. BigInt、number/dtoa、Date、JSON

### 18.1 BigInt（S）

qjs heap BigInt：

- 单次 FAM allocation；
- `len + tab[]`；
- 规范化 two's-complement limbs；
- 1 Mi-bit 上限。

zjs heap BigInt：

- GC `core.BigInt` wrapper；
- wrapper 中 `libs.bigint.BigInt`；
- sign + magnitude `[]u64`；
- allocator 字段；
- limbs 通常是第二次 allocation；
- 同样执行 1 Mi-bit 上限。

这是当前最显著的数值表示差异之一。它可能影响 allocation count、RSS、cache
locality、negative arithmetic 和 formatting，但在做表示重写前必须先建立：

- 使用 `String(result)` 而不是 CLI inspector 的跨引擎等价输出；
- short-bigint 与 heap-bigint 分桶；
- add/mul/div/shift/format direct core；
- VM/operator whole path；
- OOM injection 与 max-size boundary。

当前通用 BigInt benchmark 因 qjs `print` 输出带 `n` 而被工具标记不兼容；这
不是 BigInt 算术失败，也不能填一个虚构性能数字。

### 18.2 number formatting（S/M）

`libs/number_format.zig` 是 Bellard `dtoa.c` 的 Zig port，flags、table 和临时
算法接近。当前 whole-process `float_toString` 仍约 1.29 倍，优先怀疑 dispatch、
JSValue/string allocation 和 glue；在 direct dtoa harness 证明前，不应重写
核心算法。

### 18.3 Date/JSON（S/T）

zjs Date/JSON 是 Zig 实现，不是直接调用 qjs C。当前相应 test262 目录广泛
通过，但以下仍是专门边界：

- host timezone/DST 数据与缓存；
- JSON reviver/replacer 的属性次序和递归 stack limit；
- `JSON.parse` source context；
- cross-realm error/prototype；
- OOM 中途发布。

它们应按目录/行为测试判断，不因“都是标准库”而与其他 builtins 合并归因。

## 19. test262 与兼容边界

### 19.1 当前报告（T）

`reports/test262-latest/` 由本文基线 HEAD 于 2026-07-27 15:41 +08:00
重新生成：

| bucket | count |
| --- | ---: |
| passed | 44,541 |
| unexpected failed | 0 |
| known failed | 25 |
| feature skipped | 5,209 |
| 合计 | 49,775 |

known-error buckets：

- SyntaxError 7；
- TypeError 2；
- Test262Error 15；
- Empty output 1。

feature skips：

| feature | skipped |
| --- | ---: |
| Temporal | 4,602 |
| source-phase-imports | 230 |
| import-defer | 229 |
| ShadowRealm | 64 |
| tail-call-optimization | 35 |
| decorators | 24 |
| host-gc-required | 15 |
| Intl.Era-monthcode | 10 |

### 19.2 25 known 的真实边界（T）

分类：

- 7 个 Annex B call-expression assignment target；
- 13 个旧 assignment/compound-assignment；
- 1 个 dynamic import text async completion；
- 1 个 assign-to-global-undefined；
- 3 个 SpiderMonkey staging function/lexical-environment。

对照命令：

```sh
awk '{ print "-f"; print $0 }' test262_errors.txt |
  xargs ./zig-out/bin/run-test262 \
    -t 8 -c test262.conf -e /dev/null \
    --engine /home/aneryu/quickjs/qjs
```

结果：

```text
run-test262: prepared 25/25 tests
Result: 25/25 errors, passed 0
```

结论仅为：这 25 项不是当前已证实的 zjs→pinned-qjs 差异。不能推导两个引擎
错误类型/原因逐字一致，也不能推导这些 test262 债无需修。

### 19.3 config 不同，不能直接横比 pass count（S）

zjs 当前启用、pinned qjs config 跳过的 11 个 feature：

- arbitrary-module-namespace-names；
- `Array.fromAsync`；
- `Atomics.waitAsync`；
- await-dictionary；
- explicit-resource-management；
- immutable-arraybuffer；
- import-bytes；
- import-text；
- joint-iteration；
- legacy-regexp；
- nonextensible-applies-to-private。

pinned qjs 启用而 zjs 跳过 `host-gc-required`。两边还选择了不同 staging
re-include 集合。因此“zjs passed 数更高/更低”都不能直接解释为实现领先/落后。

## 20. 当前性能基线

### 20.1 测量纪律

本节的当前 whole-process 数字：

- 当前两份 Release 二进制；
- `taskset -c 19`；
- 每 case 3 次 warmup、9 次 timed process run；
- 工具先比较 stdout/stderr/exit code；
- 表中 `zjs/qjs`，小于 1 表示 zjs 快；
- 是 process wall-time average ratio，不是 PMU 仲裁。

命令模板：

```sh
taskset -c 19 bun tools/compare/run_microbench.js \
  --zjs zig-out/bin/zjs \
  --qjs /home/aneryu/quickjs/qjs \
  --suite microbench --warmup 3 --iters 9
```

### 20.2 当前代表性 micro（M）

| case | zjs/qjs |
| --- | ---: |
| int sum | 1.50 |
| JSON roundtrip | 1.34 |
| property create | 1.37 |
| Array push | 1.42 |
| TypedArray read | 1.38 |
| TypedArray write | 1.51 |
| sort | 1.44 |
| regexp ASCII | 1.47 |
| one concat | 1.41 |
| float toString | 1.29 |
| concat loop | 1.31 |
| cached regexp test | 0.85 |
| selected-case geomean | 1.34 |
| startup baseline | 1.28 |

### 20.3 当前 hotpath（M）

| case | zjs/qjs |
| --- | ---: |
| regexp cached loop | 0.84 |
| sparse array length | 1.28 |
| Map set/get | 1.24 |
| global write | 1.58 |
| monomorphic property read | 1.44 |
| recursive fib | 1.33 |
| non-fused call body | 1.35 |
| method call | 1.29 |
| call + allocation | 1.28 |
| geomean | 1.28 |
| startup baseline | 1.32 |

解释：

- 大多数热路径已从历史的多倍差距收敛到约 1.24–1.58；
- global write/property read/call 仍是通用执行税；
- regexp cached loop 已快于 qjs，与 direct core 结果方向一致；
- whole-process 数字不能区分 startup、VM 和算法核心，必须用下一层 harness
  继续归因。

### 20.4 2026-07-26 Octane 快照（历史 M，不代表当前 HEAD）

已退役的 2026-07-26 Octane 执行记录（可从 git 历史恢复）包含一份
CPU19/PMU 快照；分数比 zjs/qjs（越大越快）为：

| crypto | earley | raytrace | gbemu | richards | deltablue | navier | splay | box2d |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0.67 | 0.54 | 0.43 | 0.65 | 0.78 | 0.76 | 0.64 | 0.31 | 0.71 |

当前 HEAD 在该快照后还有 typed-array/GC/constructor 等变化，所以这些只能
说明宏观热点形状和历史上限，不能作为当前发布分数。

### 20.5 不可继续使用的 checked qjs baseline

`reports/perf/baseline/*-vs-quickjs` 生成于 2026-06-13，参照是 QuickJS-ng
0.15 + mimalloc，zjs 当时默认 8-byte representation，并含后来已删除的 IC/
fusion 口径。它们可作历史材料，但不是本文 pinned Bellard QuickJS 的当前
baseline。后续应：

- 保留 zjs self-baseline 作为回归门；
- 为 pinned qjs 重新生成并记录 commit/binary hash/CPU/representation；
- 不在同一图表混用两种 QuickJS 实现。

## 21. 差异优先级与后续路线

### P0：先消除错误基线与非 QJS 机制风险

1. **文档事实一致性**
   - 移除 active docs 的 IC/`zjs_enable_ic`/legacy module root 叙述；
   - 把 test262 known=25 和 skip boundary 写准；
   - 明确 PTC 未启用。
2. **非 QJS fast path 审计**
   - simple-field constructor body bypass + `simple_ctor_memo`；
   - fused-local rope accumulator；
   - single-byte/two-unit/percent/small-int runtime string caches；
   - iterator-next persistent side cache；
   - FB leaf/capture/forwarded classifications及 narrow epilogues。
3. **行为差异回归**
   - bound function own-key order；
   - spread `.next()` throw 是否 IteratorClose；
   - `defineProperties`、sealed array、`toReversed`、large length iterator、
     flatMap double-close 固化为“不要复制 qjs bug”的测试。
4. **输出/宿主合同**
   - `print` inspector vs ToString；
   - CLI teardown；
   - qjs-only `__loadScript` 与 zjs web/host globals。

P0 的目标不是一次删除所有结构差异，而是让每个保留差异都有明确类别、回归和
理由，杜绝以 benchmark 为唯一正当性。

### P1：正确性/产品能力的结构收敛

1. **module async SCC**：将 qjs `async_parent/pending/timestamp/cycle_root/
   capability` 与 zjs 分散 state 做字段级生命周期图，补 cycle rejection、
   repeated import、OOM publication 和 teardown tests。
2. **bytecode serialization/AOT 决策**：若产品需要 worker/snapshot/qjsc，
   先定 public contract；否则写入 limitations，停止半实现。
3. **BigInt 表示**：只有 direct/core/VM/RSS 证明双分配是瓶颈后，评估
   single-allocation FAM + two's-complement，要求所有 max-size/OOM/alternate
   repr 门禁。
4. **TypedArray 表示**：按 object→payload→data/count 的 load chain 归因，
   只采用 qjs 已有 ptr/count cache 机制；保留 detach/resize view invalidation。
5. **eval capture**：把 overlay 与 qjs compile-time VarRef 的语义/成本列成
   testcase matrix，再决定是否收敛。

### P2：性能优化，必须先有分层归因

优先测量顺序：

1. call admission/frame publish/return/RC；
2. global write 与普通 property walk；
3. typed-array element load/store；
4. builtin typed cproto dispatch；
5. Map string key；
6. BigInt；
7. GC-heavy splay。

每个候选必须：

- 找到 qjs 源码对应机制；
- 保留同一个语义 probe；
- 固定 baseline/candidate/qjs 二进制；
- CPU pin + load check + 交错样本；
- instructions 为主要仲裁，cycles/time 为现实信号；
- 先 changed-area tests，再 checkpoint/production gate；
- 不允许新增 IC、opaque memo、fixture-specific cache 或测试弱化。

### 明确不做

- 不因为 qjs 有可见 bug 而让 zjs 回退；
- 不恢复 property IC；
- 不把单个 microbench 的胜利推广为新 fast path；
- 不把 `gc.Policy` dormant fields 当成 concurrent/generational roadmap；
- 不以拆 `parser.zig` 或改 register VM 代替当前有证据的 call/property 工作；
- 不用旧 QuickJS-ng baseline 评价当前 pinned QuickJS 对齐。

## 22. 建议的持续维护方式

### 22.1 每次语义变更

1. 最小 zjs red probe；
2. pinned qjs 同脚本；
3. 相关 test262 slice；
4. 把差异分类为 qjs-reference、spec-exception、host-policy 或 unresolved；
5. regression test 中记录关键操作次序，不只记录最终值。

### 22.2 每次表示/所有权变更

至少记录：

- fixed header/FAM/side allocation；
- owner 与 borrowed edge；
- RC/GC/weak trace；
- OOM transaction；
- default + alternate representation；
- same-runtime recovery；
- 对应 qjs struct/function。

### 22.3 每次性能变更

按层级报告：

```text
direct algorithm/core
    ↓
object/builtin adapter
    ↓
VM opcode/call path
    ↓
whole process
    ↓
macro workload
```

只有上下层同时移动，才能把收益归到目标机制；若 direct core 已领先而 whole
process 落后，应继续查 glue/VM，不重写核心。

### 22.4 本基线的复核命令

```sh
git rev-parse HEAD
git -C /home/aneryu/quickjs rev-parse HEAD
cat /home/aneryu/quickjs/VERSION
zig version

zig build zjs --seed 0 --summary all
make -C /home/aneryu/quickjs qjs

zig build test262-gate --seed 0 --summary all
jq . reports/test262-latest/test262-buckets.json
jq . reports/test262-latest/test262-skipped-features.json

awk '{ print "-f"; print $0 }' test262_errors.txt |
  xargs ./zig-out/bin/run-test262 \
    -t 8 -c test262.conf -e /dev/null \
    --engine /home/aneryu/quickjs/qjs

taskset -c 19 env \
  QUICKJS_DIR=/home/aneryu/quickjs \
  JAVASCRIPT_ZOO_DIR=/home/aneryu/javascript-zoo \
  tools/regexp-direct-demo/run.sh

git diff --check
```

## 23. 当前事实入口

后续复核优先看生产源码和可执行配置：

- 值/GC/runtime：`src/core/value.zig`, `gc.zig`, `memory.zig`, `runtime.zig`
- string/atom：`src/core/string.zig`, `atom.zig`
- object/shape/property/array/typed array：
  `src/core/object.zig`, `shape.zig`, `property.zig`, `array.zig`,
  `typed_array.zig`
- parser/bytecode：`src/parser.zig`, `src/bytecode.zig`
- VM/call：`src/exec/zjs_vm.zig`, `tailcall_dispatch.zig`,
  `inline_calls.zig`, `frame.zig`, `call_runtime.zig`
- modules/jobs：`src/core/module.zig`, `jobs.zig`,
  `src/exec/module.zig`, `module_graph.zig`
- builtins：`src/exec/standard_globals.zig`, `internal_builtins.zig`,
  `builtin_dispatch.zig`, 各 `*_ops.zig`
- RegExp/BigInt/number：`src/libs/regexp.zig`, `bigint.zig`,
  `number_format.zig`
- 产品/API：`src/root.zig`, `src/binding/`, `src/runtime/`, `src/cli/`
- 验证边界：`test262.conf`, `test262_errors.txt`,
  `reports/test262-latest/`
- QuickJS：`quickjs.c`, `quickjs.h`, `quickjs-opcode.h`,
  `libregexp.c`, `libunicode.c`, `dtoa.c`

若这些入口与其他设计文档冲突，以当前源码、配置和执行证据为准。
