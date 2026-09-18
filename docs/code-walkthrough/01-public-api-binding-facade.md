# 01 — binding 聚合、PropName、PropertySite、NativeCallPlan

`src/binding/root.zig` 是 binding 层聚合边界：允许暴露 core/binding 声明，禁止依赖 CLI。嵌入方应走 `src/root.zig`，不要直接 import 本目录以外的 core/exec。

---

## `src/binding/root.zig`

几乎全是类型别名。句柄、字符串、字节视图的生命周期与 core 相同，本文件不加一层所有权。

### 类型与 re-export

| 名字 | 来源 | 备注 |
| --- | --- | --- |
| `JSRuntime` / `JSValue` / `Object` | core | `Object` 是真对象，不是公共 opaque。 |
| `GCStats` / `GCPauseDistribution` | core | `gcStats()` / `gcPauseDistribution()` 的快照。 |
| `JSContext` / `CallSite` | `context.zig` | 门面 + native→JS 站点。 |
| `JSValueHandle` / `LocalHandle` / `HandleScope` / `WeakPersistent` / `WeakPersistentValue` | core | 公共别名在 `zjs.value.*`。 |
| `RuntimeOptions` / `RuntimeMemoryUsage` / `ContextOptions` / `Eval*` / `DataPropertyOptions` / `PropertyAccessOptions` / `PropertyDescriptor` / `FunctionCallOptions` / `ErrorOptions` / `ScriptEvalOptions` / `SharedArrayBufferRef` / `OpcodeProfile` | core | 选项与统计。 |
| `default_stack_size` / `default_gc_threshold` | `core.runtime` | 默认栈与 GC 阈值。 |
| `native` | `native.zig` | `zjs.native`。 |
| `prop_name` / `PropNameID` | `prop_name.zig` | 公共拼写 `zjs.host.PropName`。 |
| `property_site` / `PropertySite` | `property_site.zig` | |
| `binding` | `binding.zig` | 公共 `zjs.host.NativeBinding`。 |
| `JSString` / `JSBytes` | `JSValue.String` / `Bytes` | `string` / `bytes` 命名空间再包一层。 |
| `bytes.BytesError` | `JSValue.Bytes.Error` | |

测试钉住：句柄别名不是包装（`JSValue.Scope == HandleScope` 等）、`PropNameID` 是 4 字节 struct、本模块**没有** `NativePin` / `Atom` / `pinValueForNative`。

### `activateOpcodeProfile` (`src/binding/root.zig:66`)

- **签名**：`pub fn activateOpcodeProfile(profile: ?*OpcodeProfile) ?*OpcodeProfile`。
- **作用**：把 opcode 剖析器接到给定缓冲区（或关掉）。
- **实现**：`return core.profile.activate(profile);`
- **所有权 / 错误 / 调用**：设置线程局部活动指针并返回此前的指针，不拥有、清空或释放 profile。公共 `root.activateOpcodeProfile` 会先安装 opcode 名称提供者再调这里；本函数不安装该提供者，也不检查构建是否启用计数，不能给未编入计数的产物补上采样。

---

## `src/binding/prop_name.zig`

嵌入方面向的稳定属性名 id，背后是 Runtime atom。`internStatic` 给宿主 pin atom，必须对**同一个** Runtime `release`（TGC S3 §2.5 `host_pins`）。extern 32-bit 表示是插件 ABI 的一部分，故意不暴露 core `Atom`。

### 类型

`GetPropertyError`：与 `Object.getProperty` 同一 error set（当前等于 `core.errors.RuntimeError`）。

`PropNameID`：`extern struct { value: u32 = 0 }`。结构本身不保存 Runtime 身份或所有权标志；复制 id 不会增加 pin，默认值也不是通过 intern 获得的名字。

### `PropNameID.internStatic` (`src/binding/prop_name.zig:25`)

- **签名**：`pub fn internStatic(rt: *core.JSRuntime, name: []const u8) !PropNameID`。
- **作用**：把字节 intern 成 atom，并记一笔宿主 pin，让 tracer 看不见的句柄仍能保住 atom。
- **实现**：`rt.internAtom(name)`，然后 `rt.atoms.pinForHost(id)`，返回 `{ .value = id }`。
- **所有权 / 错误 / 调用**：intern 可能 OOM，输入字节只在调用期间借用，“Static”不要求输入具有静态存储期。动态 atom 增加 host pin；预定义 atom 和整数编码 atom 不需要该计数。每次成功取得的拥有型 id 须对应一次 release；`PropertySite.initAtom` 独立持有自己的 pin。

### `PropNameID.release` (`src/binding/prop_name.zig:34`)

- **签名**：`pub fn release(self: PropNameID, rt: *core.JSRuntime) void`。
- **作用**：丢掉这次 host pin。
- **实现**：`rt.atoms.unpinForHost(raw(self))`。
- **所有权 / 错误 / 调用**：必须使用 intern 时的 Runtime。按值接收 self，不清空原 id，也不记录已释放状态；不能重复释放或将复制件当作独立所有者。动态 atom 的 pin 使用饱和递减，重复释放仍可能消耗其他持有者的 pin；unpin 不立即回收字符串。

### `PropNameID.eql` (`src/binding/prop_name.zig:38`)

- **签名**：`pub fn eql(self: PropNameID, other: PropNameID) bool`。
- **作用**：比较两个 id 的整数值。
- **实现**：`self.value == other.value`。
- **所有权 / 错误 / 调用**：没有 Runtime 参数或归属验证，跨 Runtime 的相等整数不证明名字相同。只应比较同一 Runtime 中仍有效的 id。

### `PropNameID.defineDataProperty` (`src/binding/prop_name.zig:42`)

- **签名**：`pub fn defineDataProperty(self: PropNameID, rt: *core.JSRuntime, object: *core.Object, descriptor: core.Descriptor) !void`。
- **作用**：用已 intern 的名定义自有属性，直接传入调用方提供的描述符。
- **实现**：`object.defineOwnProperty(rt, raw(self), descriptor)`。
- **所有权 / 错误 / 调用**：尽管名字含 Data，本包装不限制 descriptor 为数据描述符，也不替调用方选择属性标志；定义规则和错误由 core 决定。id、对象和 Runtime 必须属于同一 Runtime，接口不为此提供身份校验。

### `PropNameID.getProperty` (`src/binding/prop_name.zig:46`)

- **签名**：`pub fn getProperty(self: PropNameID, object: *core.Object) GetPropertyError!core.JSValue`。
- **作用**：按已 intern 名读取核心属性存储，可沿原型链查找；不是执行层的完整 JavaScript `[[Get]]`。
- **实现**：`object.getProperty(raw(self))`；accessor 槽返回保存的 getter 值，不执行 getter；缺失返回 undefined，auto-init 可物化，未初始化的 var-ref 可返回 ReferenceError。
- **所有权 / 错误 / 调用**：不 intern、不增加 atom pin，也不为结果建立 GC 根；error set 直接取自 core 方法。需要执行 JavaScript getter / Proxy 语义时应使用 context 属性接口或 PropertySite。

### `PropNameID.debugName` (`src/binding/prop_name.zig:50`)

- **签名**：`pub fn debugName(self: PropNameID, rt: *core.JSRuntime) ?[]const u8`。
- **作用**：调试用的 atom 字节视图。
- **实现**：`rt.atoms.name(raw(self))`。
- **所有权 / 错误 / 调用**：动态名字切片借用 atom 表，须保证 atom 和 Runtime 仍存活；预定义名字来自静态存储。整数编码 atom 即使有效也返回 null，接口不会把整数格式化为十进制字符串。

### `raw` (`src/binding/prop_name.zig:55`)

- **签名**：`fn raw(id: PropNameID) core.Atom`。
- **作用**：取出底层 atom id。
- **实现**：`return id.value;`（`Atom` 就是 u32）。
- **所有权 / 错误 / 调用**：内部方法都走它，避免把 `Atom` 写进公开字段语义。

---

## `src/binding/property_site.zig`

`zjs.PropertySite`：宿主侧「解析一次」的属性访问（native-boundary §8.3 / §9.4）。`JSContext.getProperty(obj, "field")` 每次 intern + 从头走对象；循环读同一字段时，本类型持有一条与 VM `get_field` 相同的 `PropSiteCache`，用接收者 `Shape.identity` 守卫。

读取先尝试主 own / 一层原型 / native-getter 缓存臂，再尝试第二种 own 布局；写入只缓存可写的自有数据槽。未命中走执行层 `getValueProperty` / 严格 `setValuePropertyWithThrow`。缓存捕获使用 VM 的逻辑：不能表示的对象布局或超过 u16 的槽索引可立即退休；初次填充、后续覆盖和 auto-init 延迟捕获的计数规则不同，不能把 miss_budget=4 理解为每次慢路径都会计一次。非对象和已退休站点不再尝试捕获。

缓存靠 Runtime 内的 shape identity 和相关 class/prototype 守卫失效，不需要宿主手动清理缓存。缓存项只有整数，但整个站点还借用 context 和 global 指针；它不自行持有 realm 的生命周期。名字通过 atom host pin 保活，站点须在 context/runtime 销毁前 deinit，且只用于所属 Runtime 的对象和线程。

### 类型

`PropertySite` 字段：

| 字段 | 含义 |
| --- | --- |
| `ctx` | 创建时的 `JSContext`，站点绑在这个 realm。 |
| `global` | 普通属性走查用的 realm global，init 时解析一次。 |
| `name` | interned `Atom`，直到 `deinit` 都 pin 着。 |
| `read` / `write` | 两条独立 `PropSiteCache`。读可缓存只读 own / 原型槽，写不行；共用一条会在读写之间抖动。 |

### `PropertySite.init` (`src/binding/property_site.zig:81`)

- **签名**：`pub fn init(ctx: *JSContext, name: []const u8) !PropertySite`。
- **作用**：intern 属性名并 pin，站点绑到 `ctx` 的 realm。
- **实现**：`rt.internAtom(name)` → `pinForHost`；`errdefer unpin`；`global = try ctx.globalObject()`。cache 字段用默认空。
- **所有权 / 错误 / 调用**：intern 与 globalObject 可能失败；pinForHost 本身返回 void。调用方 `defer site.deinit()`。线程必须是 runtime owner。

### `PropertySite.initAtom` (`src/binding/property_site.zig:92`)

- **签名**：`pub fn initAtom(ctx: *JSContext, name: PropNameID) !PropertySite`。
- **作用**：宿主已经 intern 过的名再建站点。站点自己再 pin 一次，调用方的 id 可独立 `release`。
- **实现**：`pinForHost(name.value)` + `errdefer unpin`；不 intern。
- **所有权 / 错误 / 调用**：对动态 atom 独立增加 pin，`globalObject` 仍可能失败并回退该 pin。调用方须提供同一 Runtime 中仍有效的 PropNameID；id 不携带 Runtime 身份，方法不会检出跨 Runtime 的误用。

### `PropertySite.deinit` (`src/binding/property_site.zig:99`)

- **签名**：`pub fn deinit(self: *PropertySite) void`。
- **作用**：放掉 host pin，站点作废。
- **实现**：`unpinForHost(self.name)`，然后 `self.* = undefined`。
- **所有权 / 错误 / 调用**：通过保存的 context 访问创建时的 Runtime，因此须先销毁站点、再销毁 context。方法不是幂等的，不能重复 deinit，也不能复制活跃站点后分别 deinit。缓存只有整数，无须逐项释放。

### `PropertySite.propName` (`src/binding/property_site.zig:106`)

- **签名**：`pub fn propName(self: *const PropertySite) PropNameID`。
- **作用**：把站点的 interned 名借给 `PropNameID` 操作。
- **实现**：`return .{ .value = self.name };`
- **所有权 / 错误 / 调用**：不额外 pin。返回的 id 生命周期仍由站点的 pin 撑着，不能对这份借用 id 调用 release 来消耗站点拥有的 pin。

### `PropertySite.get` (`src/binding/property_site.zig:112`)

- **签名**：`pub inline fn get(self: *PropertySite, obj: JSValue) !JSValue`。
- **作用**：`obj[name]`。守卫命中是 identity 比较 + 索引加载；否则慢路径并记一次 capture。
- **实现**：`objectFromValue` 成功则：主 `guard_key` 命中且 `proto_key==0` → 直接 `loadSlotAsIntPair` own 槽；否则 `readIndirectArm`；再试 `secondary_guard_key`（第二种 own 布局，无 recapture）。都未中 → `getSlow`。
- **所有权 / 错误 / 调用**：返回值按普通 getter 规则，宿主栈上的 `obj`/结果靠 conservative scan。JS 异常从慢路径冒出。

### `PropertySite.set` (`src/binding/property_site.zig:133`)

- **签名**：`pub inline fn set(self: *PropertySite, obj: JSValue, value: JSValue) !void`。
- **作用**：严格 `Set`：`obj[name] = value`。对象拒绝的写（只读槽、不可扩展、无 setter 的 accessor）抛 TypeError，宿主看到 `error.JSException` 且异常挂在 context。
- **实现**：写臂还要 `class_id` 再检查（mapped `arguments` 必须走 binding；Shape 不钉 class）。命中则 `storeSlotAsIntPair` + `generationalBarrierValue`（这条臂不走 `setOrDefineOwnDataProperty*` 漏斗，自己补 old-to-young barrier）。否则 `setSlow`。
- **所有权 / 错误 / 调用**：站点自身不保存 value；写入成功后对象槽建立对应的 GC 边，快速路径的 barrier 记到接收者 header。慢路径可能执行 setter / Proxy 并失败，返回成功不一定表示创建了自有槽。

### `PropertySite.readIndirectArm` (`src/binding/property_site.zig:160`)

- **签名**：`noinline fn readIndirectArm(self: *PropertySite, object: *Object, receiver: JSValue) ?JSValue`。
- **作用**：outline 的 `.proto` / `.native_getter` 臂，避免把额外守卫塞进 `get` 热帧。
- **实现**：`class_id` 不符或没有 proto 或 holder identity ≠ `proto_key` → null。`state == site_proto` 则从 holder 槽 load。否则当 native getter：从守卫槽重读 accessor（`defineProperty` 可换 getter 而不动 shape flag，所以 **不**缓存 `NativeEntry`），`nativeAccessorTarget`；`sig==0`（非 typed）→ null；否则 `invokeTypedGetterFast`。
- **所有权 / 错误 / 调用**：守卫、native 目标或 receiver 匹配失败时返回 null，继而走普通查找；是否重新捕获仍取决于站点未退休。typed getter 直接调用支持的 self→f64 / self→i32 leaf 目标，返回 JSValue，不走普通 JS getter 调用路径。

### `PropertySite.getSlow` (`src/binding/property_site.zig:180`)

- **签名**：`noinline fn getSlow(self: *PropertySite, obj: JSValue) !JSValue`。
- **作用**：未命中时的普通 `[[Get]]`，并在可 capture 时填 read cache。
- **实现**：对象且 `siteCapturable(&self.read)` 则 `captureFieldSite(..., true)`。然后 `object_ops.getValueProperty(ctx.core, null, global, obj, name, ...)`。
- **所有权 / 错误 / 调用**：捕获发生在实际查找之前，查找失败不会回滚缓存变化。实际走查可执行 JS accessor / Proxy；错误原样上浮，output 参数为 null。

### `PropertySite.setSlow` (`src/binding/property_site.zig:189`)

- **签名**：`noinline fn setSlow(self: *PropertySite, obj: JSValue, value: JSValue) !void`。
- **作用**：写未命中时的严格 `[[Set]]`，并 capture 写站点。
- **实现**：可 capture 则 `capturePutSite`。然后 `setValuePropertyWithThrow(..., true)`，丢掉 bool 结果（throw 路径已把拒绝变成异常）。
- **所有权 / 错误 / 调用**：TypeError 作为 JS 异常挂在 context。

### `Getter.get` (`src/binding/property_site.zig:267`)

- **签名**：`fn get(_: *core.JSContext, _: JSValue, _: *const core.NativeEntry) callconv(.c) JSValue`。
- **作用**：宽对象（>u16 槽）测试用的 native getter，恒返回 `int32(1)`。
- **实现**：忽略参数，`return JSValue.int32(1)`。
- **所有权 / 错误 / 调用**：经 `createFunction` 装到 `wideGetter`，再 `defineProperty` 到 `wide.target` / `p65535`。不是公共 API。

---

## `src/binding/native_call_plan.zig`

本文件定义私有 NativeCallPlan 数据形状及 FNABI 描述符到 spec 的映射；插件 ABI 位于 `src/abi/fun_native_abi.zig` 与生成的 C 头。源码注释提出 builtin/plugin 共用 schema 和每 Runtime 一个 application realm 的 v1 设计约束，但此文件没有注册、执行或 realm 数量检查逻辑，不能把这些注释当作已接入运行路径的证明。

### 类型与常量

| 名字 | 含义 |
| --- | --- |
| `one_runtime_one_application_realm` | 值为 true 的设计限制标记；本文件不据此检查或创建 realm。 |
| `PlanError` | `DescriptorTooSmall` / `NonZeroReserved` / `UnknownCallKind` / `UnknownSignature` / `UnknownMarshalPolicy` / `MissingTarget`。 |
| `NativeCallPlanSpec` | 规范化元组：`call_kind` / `signature` / `marshal_policy` / `flags`。 |
| `NativeCallPlan` | 当前仅包含 spec 的结构，没有 handler、执行方法或计划缓存。 |
| `ConstValue` | 常量导出的数据表示：i32 / f64 / bool / 借用的 UTF-8 字节切片；此文件不实现模块物化。 |
| `NativeExportRegistration` | 私有注册输入形状：name 字节、kind、plan_spec、target 和可选 state / class_spec / const_value；构造结构本身不 intern、不复制字节、不校验字段组合。 |
| `NativeModuleRegistration` | `module_name` + `exports` 切片。源码注释把消费者 `registerNativeModule` 划入 FN-M1A；当前树只有该注册数据形状，没有这个注册入口的实现。 |

### `NativeCallPlanSpec.fromFunctionDescriptor` (`src/binding/native_call_plan.zig:49`)

- **签名**：`pub fn fromFunctionDescriptor(desc: *const abi.FunFunctionDescriptorV1) PlanError!NativeCallPlanSpec`。
- **作用**：检查描述符的基本字段，并复制出调用计划所需的四字段 spec；不是完整的 native 注册或代码指针验证。
- **实现**：`struct_size < sizeof(V1)` → `DescriptorTooSmall`（更大的 size 是更新的 minor，多出来的字段忽略）。`reserved0 != 0` → `NonZeroReserved`。`callKindIsValid` / `signatureIsValid` 失败 → 对应 Unknown。`marshal_policy` 必须是 `canonical`。`target == null` → `MissingTarget`。通过则拷四个字段。
- **所有权 / 错误 / 调用**：无分配，不持有 desc 或 target，不调用代码。flags 原样保留，未检查未知 flag 位或 call_kind/signature 的组合是否合法。较大的 struct_size 只被接受，不证明它确实来自更新的 minor；调用方仍须提供可读的描述符内存，长度字段不验证指针可读范围。

### `callKindIsValid` (`src/binding/native_call_plan.zig:70`)

- **签名**：`pub fn callKindIsValid(kind: abi.FunCallKind) bool`。
- **作用**：call kind 是否落在 v1 闭区间。
- **实现**：`kind >= leaf_static and kind <= async_entry`。
- **所有权 / 错误 / 调用**：`fromFunctionDescriptor` 使用。

### `signatureIsValid` (`src/binding/native_call_plan.zig:74`)

- **签名**：`pub fn signatureIsValid(id: abi.FunSignatureId) bool`。
- **作用**：签名 id 是否在 dense 表范围内。
- **实现**：`id >= signatures[0].id and id <= signatures[last].id`，只检查表的首尾边界，不逐项搜索。
- **所有权 / 错误 / 调用**：正确性依赖签名表有序且 id 连续；若未来表出现空洞，仅凭这个函数不能拒绝洞中的 id。它也不验证该签名是否匹配目标函数的真实调用约定。

### `callbackForTest` (`src/binding/native_call_plan.zig:122`)

- **签名**：`fn callbackForTest() callconv(.c) void`。
- **作用**：测试描述符的非空 `target`。
- **实现**：空函数体。
- **所有权 / 错误 / 调用**：仅 `validDescriptor`。

### `validDescriptor` (`src/binding/native_call_plan.zig:124`)

- **签名**：`fn validDescriptor() abi.FunFunctionDescriptorV1`。
- **作用**：造一份合法 v1 描述符（leaf_static、signature 4 = F64_TO_F64、canonical marshal、reserved0=0）。
- **实现**：字面量 struct，`target = &callbackForTest`。
- **所有权 / 错误 / 调用**：单元测试的肯定/否定行都从这份拷再改坏。
