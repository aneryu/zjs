# 08 — 函数对象、宿主 ABI、NativeEntry、NativeObject

覆盖 `function.zig`、`host_function.zig`、`native_entry.zig`、`native_object.zig`。

## `native_entry.zig` 类型

`NativeEntry` 是原生分发记录：48 字节、对齐 8 的 `extern struct`，大小、对齐和所有字段偏移均由 comptime assert 固定。它自身不管理分配或执行回调。

| 字段 / 类型 | 布局与用途 |
| --- | --- |
| target / fallback / state | 偏移 0/8/16；target 必填 CodePtr，fallback 默认 null 的 ManagedFn，state 默认 null 的 opaque 指针。fallback 用于外围分发的叶子失败回退，state 的寿命由注册方管理。 |
| kind / flags / sig | 偏移 24/25/26；kind 必填，Flags 为 packed u8，needs_env/forwards_call/pad_args 默认 false，其余五位为 0；sig(u16) 默认 0，选择 typed ABI。标志只声明要求，不自行建立环境或补参数。 |
| arity / effect / class_id | 偏移 28/29/30；arity(u8)=0，供 JS length 与参数补齐使用；Effect 为 packed u8，默认五个布尔字段 may_throw/may_alloc/may_reenter_js/reads_heap/writes_heap 均 true，其余三位 0；Effect.leaf 全 false，Effect.managed 为默认值。class_id(u16)=0，供需解包接收者的臂使用。 |
| magic / builtin_id / name / owner | 偏移 32/34/36/40；前两者 u16 默认 0，name 为 Atom 默认 null_atom，owner 为默认 null 的 opaque 来源指针。该结构不追踪指针或自行保持 atom 存活。 |
| Kind | enum(u8)：managed=0、constructor=1、constructor_or_func=2、getter=3、setter=4、leaf=5、method_leaf=6、method_managed=7、retired=255。8/9 未复用；call/apply 转发通过 Flags 与目标身份识别，不是独立 kind。 |
| ManagedFn / CtorFn | 均为 C 调用约定，接收 ctx、JSValue、argv 裸指针、u32 argc、entry、可空 func_obj，返回 JSValue；第二参数分别表示 this 和 new_target。只有声明类型相同的机器形状不足以证明二者语义可互换。 |
| GetterFn / SetterFn | C 调用约定，接收 ctx/this/entry；setter 在 entry 前追加 new_value，返回 JSValue。 |
| MethodManagedFn / CodePtr | 前者接收 ctx/opaque self/this/argv/argc/entry 并返回 JSValue；后者擦除为无参、返回 void 的 C 函数指针。必须按真实协议还原后调用，不能直接用 CodePtr 调用任意 target。 |
| SparseEntry / EntryTable | SparseEntry 包含 u32 id 和内嵌 NativeEntry；EntryTable 借用 dense 与 sparse 两个 const slice，默认均空。本类型不强制数据处于 comptime rodata，不复制或验证排序、重复 ID。 |
| retired_entry | target 为 retiredTrap、kind=retired，其余字段取 NativeEntry 默认值；填补 dense 表空洞。 |

运行时条目的生命周期由拥有者保证：内建表通常为静态数据；`JSRuntime.allocNativeEntry` 单独分配条目并把地址加入 native_entries 列表，并非此类型内建 arena。`retireNativeEntry` 原地写 retired 并增加 epoch，不释放；`clearExternalHostFunctions` 才释放 runtime 拥有的条目。正常使用期间缓存依赖该地址稳定合同，不能从 `*const` 推断内存绝对不可变或永不失效。`Effect` 是注解，字段值本身不构成 GC、异常或重入保护。

### `Kind.isConstructor` (`src/core/native_entry.zig:53`)

- **签名**：`pub inline fn isConstructor(self: Kind) bool`。
- **作用**：判断 kind 是否属于构造族。
- **实现**：仅 constructor 和 constructor_or_func 返回 true；其余 kind（包括 retired）返回 false。
- **所有权 / 错误 / 调用**：纯分类，不检查目标指针、签名或实际调用合法性。

### `NativeEntry.managed` (`src/core/native_entry.zig:170`)

- **签名**：`pub inline fn managed(self: *const NativeEntry) ManagedFn`。
- **作用**：把 target 转成 ManagedFn 函数指针。
- **实现**：assert kind 为 managed 或构造族，再 @ptrCast(target)。
- **所有权 / 错误 / 调用**：不调用目标、不验证实际机器签名；构造族旧适配器也使用此签名，new_target 经外围 native environment 传递。不能把 assert 当作可恢复的输入校验。

### `NativeEntry.ctor` (`src/core/native_entry.zig:175`)

- **签名**：`pub inline fn ctor(self: *const NativeEntry) CtorFn`。
- **作用**：把构造族条目的 target 转成 CtorFn。
- **实现**：先 assert kind.isConstructor()，再 @ptrCast。
- **所有权 / 错误 / 调用**：只改变指针类型，不把旧 ManagedFn 实现转换为以 new_target 为第二参数的语义；调用方必须保证目标采用 CtorFn 协议，kind 本身不足以证明。

### `NativeEntry.getter` (`src/core/native_entry.zig:183`)

- **签名**：`pub inline fn getter(self: *const NativeEntry) GetterFn`。
- **作用**：取得无 typed leaf 签名的 GetterFn。
- **实现**：assert kind==getter 且 sig==0，随后转换 target。
- **所有权 / 错误 / 调用**：sig 非零的 typed accessor 应由外围 typed 分发处理；此函数不解包接收者、不执行 getter，也不检查真实指针签名。

### `NativeEntry.setter` (`src/core/native_entry.zig:188`)

- **签名**：`pub inline fn setter(self: *const NativeEntry) SetterFn`。
- **作用**：取得无 typed leaf 签名的 SetterFn。
- **实现**：assert kind==setter 且 sig==0，随后转换 target。
- **所有权 / 错误 / 调用**：返回函数指针，不写属性或校验 new_value；typed accessor 不适用此转换。

### `NativeEntry.methodManaged` (`src/core/native_entry.zig:193`)

- **签名**：`pub inline fn methodManaged(self: *const NativeEntry) MethodManagedFn`。
- **作用**：把方法条目 target 转成 MethodManagedFn。
- **实现**：assert kind==method_managed 后 @ptrCast。
- **所有权 / 错误 / 调用**：该签名接受 opaque self，但本函数不解包 NativeObject、不验证 class 或 disposed 状态；这些由调用方完成。

### `NativeEntry.isConstructor` (`src/core/native_entry.zig:198`)

- **签名**：`pub inline fn isConstructor(self: *const NativeEntry) bool`。
- **作用**：查询条目是否标记为构造族。
- **实现**：委托 self.kind.isConstructor()。
- **所有权 / 错误 / 调用**：不判断普通调用是否应抛 TypeError，不检验 func_obj/new_target 或调用目标。

### `NativeEntry.code` (`src/core/native_entry.zig:205`)

- **签名**：`pub inline fn code(comptime f: anytype) CodePtr`。
- **作用**：在声明侧擦除函数指针类型。
- **实现**：接收 comptime anytype 参数 f，直接 @ptrCast 成 CodePtr。
- **所有权 / 错误 / 调用**：不接收 kind/sig，因此不能自行证明签名与条目匹配；合法 ABI 由注册构建器和调用方约束。也没有封装限制阻止外部直接填写 target。

### `EntryTable.get` (`src/core/native_entry.zig:239`)

- **签名**：`pub inline fn get(self: EntryTable, id: u32) ?*const NativeEntry`。
- **作用**：按域内 ID 返回借用条目指针。
- **实现**：id<dense.len 时只查该下标：retired 返回 null，否则返回其地址。仅在 id 超出 dense 时线性查 sparse，返回首个相同 id 的 entry 地址；无匹配返回 null。
- **所有权 / 错误 / 调用**：dense 的空洞不会继续查 sparse；sparse 命中不检查 retired，重复 ID 取第一项。返回地址依赖底层 slice 存储寿命，本函数不分配、不延长寿命。

### `retiredTrap` (`src/core/native_entry.zig:254`)

- **签名**：`fn retiredTrap() callconv(.c) void`。
- **作用**：提供 retired_entry 所需的非空 target。
- **实现**：函数体为 unreachable。
- **所有权 / 错误 / 调用**：只能作为不可调用的占位指针，不是返回 JS 异常的 handler；安全检查开启时误调用会触发不可达错误，关闭时也不保证正常陷阱语义。

### `testManaged` (`src/core/native_entry.zig:268`)

- **签名**：`fn testManaged(ctx: *JSContext, this: JSValue, argv: [*]const JSValue, argc: u32, entry: *const NativeEntry, func_obj: ?*Object) callconv(.c) JSValue`。
- **作用**：布局测试用的 ManagedFn：有参返回 argv[0]，否则 undefined。
- **实现**：忽略 ctx/this/entry/func_obj。
- **所有权 / 错误 / 调用**：仅 `test "managed target round-trips..."`。

## `native_object.zig` 类型

`NativeType` 保存 class_id、借用 name、可空 FinalizeFn 与分配所属 owner runtime；独立分配并挂在 class record 的 native_type/binding_data 上。对象只保存 opaque self 和 native 标志，不保存此类型指针。动态类完成注销或表销毁可释放 NativeType，长期借用者须遵守类定义生命周期。

`FinalizeFn` 为 `*const fn (self: *anyopaque) callconv(.c) void`；常规实例清理在 runtime 线程对未摘走的 self 调用。注册只安装 payload finalizer，没有 payload mark 回调，所以 opaque 数据中的 JS 引用需要另外建立受追踪的根。null payload 表示 self 已无；`takeNativeSelf` 只摘走指针，不自动调用 FinalizeFn。

### `NativeType.fromRecord` (`src/core/native_object.zig:37`)

- **签名**：`pub fn fromRecord(rt: *const JSRuntime, class_id: class.ClassId) ?*const NativeType`。
- **作用**：从指定 runtime 的已注册 class record 读取 NativeType。
- **实现**：recordPtr 找不到或 native_type 为空则返回 null；否则对 opaque 指针 @alignCast 后 @ptrCast。
- **所有权 / 错误 / 调用**：借用独立分配的 NativeType，不复制、不取得 pin，也不验证该指针内容；表扩容会移动 Record，但不会因此移动 NativeType。注销释放 binding_data 后此借用失效。

### `registerType` (`src/core/native_object.zig:47`)

- **签名**：`pub fn registerType(rt: *JSRuntime, class_id: class.ClassId, name: []const u8, finalize: ?FinalizeFn) !*const NativeType`。
- **作用**：将已提供的 class ID 注册为 NativeObject 类型。
- **实现**：已有 NativeType 就直接返回，不比较新 name/finalize；若已注册为其他类型则 DuplicateClass。否则分配并初始化 NativeType，预留各 context 原型槽，再登记 payload_kind=none、payloadFinalizer、destroyType 和 native_type/binding_data 指针。
- **所有权 / 错误 / 调用**：name 字节借用，须覆盖类型存活期；不分配 class ID。任意后续错误由 errdefer 释放临时 NativeType，但已完成的 context 容量扩展不回滚。已有类型分支不重新验证线程或 pending 注销状态。

### `destroyType` (`src/core/native_object.zig:70`)

- **签名**：`fn destroyType(data: *anyopaque) void`。
- **作用**：销毁 class 定义拥有的 NativeType 分配。
- **实现**：opaque data 转回 NativeType，使用其 owner.memory.destroy 释放。
- **所有权 / 错误 / 调用**：作为 binding_data_finalizer，可在动态类完成注销时或 class 表 teardown 时调用；不局限于最后一次全局 sweep。类的实例/构造/回调保护由 class.Table 负责，此函数不检查 pin 或逐实例 finalize，也不释放借用 name 字节。

### `payloadFinalizer` (`src/core/native_object.zig:78`)

- **签名**：`fn payloadFinalizer(runtime: *anyopaque, object: *anyopaque, payload: *class.Payload) void`。
- **作用**：清除实例持有的 opaque self，并调用可选宿主析构器。
- **实现**：payload 为空立即返回；否则保存 self 后先清空 payload，再按 obj.class_id 查 NativeType。有类型且 finalize 非空才调用 finalize(self)。
- **所有权 / 错误 / 调用**：清槽发生在 lookup 与回调之前，防止同一槽再次交出指针；无类型或无 finalize 也不会恢复槽或自动释放 self。正常路径依赖 class 表保护定义，不在此取得 pin。

### `create` (`src/core/native_object.zig:90`)

- **签名**：`pub fn create(rt: *JSRuntime, native_type: *const NativeType, prototype: ?*Object, self_ptr: *anyopaque) !*Object`。
- **作用**：创建指定 class/prototype 的对象并安装 self。
- **实现**：Object.create 成功后调用 installNativeSelf，保存 opaque 指针并设置 native 标志。
- **所有权 / 错误 / 调用**：Object.create 失败时 self 仍由调用方管理；成功后清理由类型 finalizer 或 takeNativeSelf 后的调用方负责。此处不核验 native_type.owner==rt、不比较目标 runtime 的注册记录，也不为任意 opaque self 增加 GC 扫描器。

### `unwrap` (`src/core/native_object.zig:98`)

- **签名**：`pub inline fn unwrap(val: JSValue, class_id: class.ClassId) ?*anyopaque`。
- **作用**：从 JSValue 中取出精确 class 的活 NativeObject self。
- **实现**：先用 value_semantics.objectFromValue 检查 object tag、非空 header 及 header kind（拒绝 VarRef 包装），再比较 class_id；成功调用 nativeSelfAssumeClass 读取 payload。
- **所有权 / 错误 / 调用**：不沿原型链、不解 Proxy、不做类型继承转换；已摘走 self 返回 null。调用方须提供 NativeObject 类 ID：同 ID 的非 native 对象会触发 nativeSelfAssumeClass 的断言，而不是此处保证返回 null。

## `function.zig` 类型

`NativeBuiltinDomain` 为enum(i32)：math/number/string/date/array/regexp/collection/buffer/uri/performance/json/atomics/reflect/object/primitive/function/error_object/iterator/host/promise/weak_ref依序1–21。编码stride为1024，合法局部编号约定为1–1023；编码器本身不执行该范围验证。

`HostGlobalMethod` 为enum(u32)：btoa=1、atob=2、queue_microtask=3、gc=4、navigator_user_agent_get=5、dom_exception_ctor_call=6、species_getter=7；CallSite的get_function/get_function_name/get_file_name/get_line_number/get_column_number/is_native依序8–13。

`navigator_user_agent = "quickjs-ng/0.14.0"`。

`NativeBuiltinRef`：`{domain, id}`。

### `nativeBuiltinId` (`src/core/function.zig:83`)

- **签名**：`pub fn nativeBuiltinId(domain: NativeBuiltinDomain, id: u32) i32`。
- **作用**：把domain与局部id编码为i32。
- **实现**：enum(domain)*1024 + intCast(id)。
- **所有权 / 错误 / 调用**：不验证id在1..1023；0无法正常decode，>=1024可跨域，超i32或相加溢出不是可恢复错误。有效编号范围由调用者保证。

### `decodeNativeBuiltinId` (`src/core/function.zig:87`)

- **签名**：`pub fn decodeNativeBuiltinId(encoded: i32) ?NativeBuiltinRef`。
- **作用**：解码受支持域中的非零局部编号。
- **实现**：encoded<=0返回null，商为domain、余数为local_id；余数<=0或域不在1..21返回null，否则返回NativeBuiltinRef。
- **所有权 / 错误 / 调用**：不检查局部编号是否在该域实际注册；成功解码不等于存在NativeEntry。

### `isAsciiBuiltinName` (`src/core/function.zig:119`)

- **签名**：`fn isAsciiBuiltinName(bytes: []const u8) bool`。
- **作用**：判断所有名字字节是否小于0x80。
- **实现**：遍历遇>=0x80则false，否则true。
- **所有权 / 错误 / 调用**：空串也true；控制字符和NUL也属此判据，不是标识符语法验证。

### `nativeFunctionWithClass` (`src/core/function.zig:126`)

- **签名**：`fn nativeFunctionWithClass( rt: *JSRuntime, class_id: class.ClassId, prototype: ?*Object, name: []const u8, length: i32, ) !JSValue`。
- **作用**：创建指定class、原型与两槽容量的函数对象并安装元数据。
- **实现**：createWithOwnPropertyCapacity后publishNativeFunctionMetadata，返回对象值。
- **所有权 / 错误 / 调用**：本体没有metadata失败时的errdefer destroy，未返回对象按GC协议处理；不安装realm或可调用entry，class前提由内部调用者保证。

### `nativeFunction` (`src/core/function.zig:141`)

- **签名**：`pub fn nativeFunction(realm: *RealmContext, name: []const u8, length: i32) !JSValue`。
- **作用**：使用realm缓存的Function.prototype创建C function。
- **实现**：缺cached_function_proto报InvalidBuiltinRegistry，否则调用WithPrototypeAndCapacity，容量2。
- **所有权 / 错误 / 调用**：不会回退查询全局Function属性；创建本身不赋native builtin ID或entry。

### `nativeFunctionWithPrototypeAndCapacity` (`src/core/function.zig:151`)

- **签名**：`pub fn nativeFunctionWithPrototypeAndCapacity( realm: *RealmContext, prototype: ?*Object, name: []const u8, length: i32, capacity: usize, ) !JSValue`。
- **作用**：创建带显式原型和realm边的C function。
- **实现**：断言capacity>=2，Object构造后setNativeFunctionRealm，再安装name/length/dispatch元数据。
- **所有权 / 错误 / 调用**：realm边在metadata分配前写入，但Object构造已经完成GC登记，不能称整个对象未发布。metadata失败无本地destroy；RealmRef不是RC计数。

### `publishNativeFunctionMetadata` (`src/core/function.zig:169`)

- **签名**：`fn publishNativeFunctionMetadata( rt: *JSRuntime, function_object: *Object, name: []const u8, length: i32, ) !void`。
- **作用**：按配置为元数据安装期间的函数对象加根。
- **实现**：value_root_frames_enabled为true时rootObjects保护holder，再调用Work；false直接Work。
- **所有权 / 错误 / 调用**：不无条件启用显式根帧；调用时传递的是原function_object，根用于保活，不宣称支持移动后自动更新该局部指针。

### `publishNativeFunctionMetadataWork` (`src/core/function.zig:185`)

- **签名**：`fn publishNativeFunctionMetadataWork( rt: *JSRuntime, function_object: *Object, name: []const u8, length: i32, ) !void`。
- **作用**：安装函数length/name并保存dispatch atom。
- **实现**：先定义length为不可写不可枚举可配置的int32；名字为空用emptyString，ASCII用createAscii，否则createUtf8，随后无条件取其 value（两支相同的死分支已折叠），同属性标志定义name。最后intern名字、shadeAtomIfMarking并写nativeDispatchNameSlot。
- **所有权 / 错误 / 调用**：前两属性用AssumingNew要求调用方保证新槽；失败可能已安装length/name，不回滚。name_value没有单独本地根帧，不能扩大包装根帧的覆盖范围；length不校验非负，dispatch写入不解析entry。

### `nativeDataFunctionWithPrototype` (`src/core/function.zig:215`)

- **签名**：`pub fn nativeDataFunctionWithPrototype( rt: *JSRuntime, prototype: ?*Object, name: []const u8, length: i32, ) !JSValue`。
- **作用**：创建不携构造realm边的native data function。
- **实现**：委托nativeFunctionWithClass(c_function_data,prototype,name,length)。
- **所有权 / 错误 / 调用**：显式原型不等于拥有该realm；执行时采用何种caller语义由native分派协议决定，此处不设置回调tag/entry。

### `nativeFunctionForGlobal` (`src/core/function.zig:224`)

- **签名**：`pub fn nativeFunctionForGlobal(rt: *JSRuntime, global: *Object, name: []const u8, length: i32) !JSValue`。
- **作用**：解析global所属realm后创建C function。
- **实现**：contextForGlobalIncludingConstructing找realm，要求其cached_function_proto，任一步缺失InvalidBuiltinRegistry，再容量2构造。
- **所有权 / 错误 / 调用**：允许构造中的realm被查到，不自行创建realm或读取global.Function属性。

### `defineNativeMethod` (`src/core/function.zig:240`)

- **签名**：`pub fn defineNativeMethod(realm: *RealmContext, target: *Object, name: []const u8, length: i32) !void`。
- **作用**：立即创建native data函数并安装为target自有方法。
- **实现**：要求realm的Function.prototype缓存；构造method后defineMethodData(name,method,true,false,true)。
- **所有权 / 错误 / 调用**：是立即构造，不是AUTOINIT placeholder。defineMethodData的根帧只在method构造之后启用，target在前段构造窗口的存活由调用者负责；失败不保证整过程回滚。

### `defineMethodData` (`src/core/function.zig:247`)

- **签名**：`fn defineMethodData( rt: *JSRuntime, target: *Object, name: []const u8, value: JSValue, writable: bool, enumerable: bool, configurable: bool, ) !void`。
- **作用**：根住目标和值后定义命名数据属性。
- **实现**：rootValues保护target_value/rooted_value，intern key，再rootAtoms保护key跨defineOwnProperty；defer撤销两个根帧。
- **所有权 / 错误 / 调用**：属性flags按参数，不强制新属性；intern/定义错误传播，无用户方法调用。调用方提供的name slice也需在intern期间有效。

## `host_function.zig` 类型

此文件提供 core/exec 之间的宿主协议和纯分发元数据；回调适配器、记录编译及实际 JS 操作由使用方实现。名称映射成功不等于对象仍持有原内建属性，也不证明记录已注册。

| 类型 / 常量 | 字段与契约 |
| --- | --- |
| `name_id.Entry`、`ids` | 表项为借用 name slice 与 u32 id；`ids.output=1` 是独立宿主编号。 |
| `InternalCallableTag` | enum(u8)：none=0、promise_resolving=1，2/3 留空；promise_capability_executor 至 array_from_async_continuation 为 4–13。usesCallerRealm 仅对 none 与 throw_type_error_intrinsic 返回 false。 |
| `ExternalCall` | 借用 realm、可空 output、func_obj、this_value、args。global 及其 slots 应取自同一 RealmContext；“原子视图”指集中携带 realm 权威来源，并非线程同步，也不要求所有 JS 值来自同一个 realm。 |
| `ExternalCallFn`、`ExternalFinalizer` | 前者接收 opaque userdata 与 ExternalCall，返回 anyerror!JSValue；后者接收 userdata、返回 void。协议本身不复制或自动清理 userdata。 |
| `CallbackError`、`CallbackCallFn` | 七种错误：JSException、OutOfMemory、Interrupted、ProcessExit、StackOverflow、Timeout、UnhandledPromiseRejection。回调接收 ctx/callback/this/args/可变 globals slice，返回该错误集或 JSValue。 |
| `CallbackHost` | ctx 与 call 默认 null，globals 默认空 slice；包装入口还可能因缺配置返回 TypeError，不从 runtime 当前 context 补全配置。 |
| `NativeCProto`、`NativeFunctionPtr` | enum(u8) 的十二个协议及同标签联合体：generic/magic、constructor/magic、constructor_or_func/magic、getter/setter 及各自 magic、f_f/f_f_f。构造族沿用 NativeGenericFn/MagicFn 的签名，单靠类型不提供独立 new_target 参数。 |
| `NativeGenericFn`、`NativeGenericMagicFn` | ctx、this 与借用 args，magic 版本追加 i32；返回 HostError!JSValue。这些是 Zig 函数指针，未声明 callconv(.c)。 |
| `NativeGetterFn`、`NativeSetterFn`、对应 MagicFn | getter 接收 ctx/this，setter 再接 value；magic 版本最后追加 i32。均返回 HostError!JSValue。 |
| `NativeF64Fn`、`NativeF64F64Fn` | 分别为一个或两个 f64 参数，返回 f64；没有 ctx 或错误联合体。 |
| `InternalEntry` | 声明记录：必填 name、u8 length、u32 域内 id；magic(u16)=0、forwards_call=false、cproto=generic，native_function/fallback_function/managed/prim_leaf 默认 null。这里没有内建校验函数保证 cproto 与 native_function 实际标签相同。 |
| `InternalEntry.PrimLeaf` | 借用 FNABI 签名名 sig 与擦除后的 CodePtr target；供编译记录时选择 primitive receiver 叶子臂。managed 是直接 K0 实现声明，prim_leaf 的 tag miss 可使用 managed/cproto 生成的 fallback；此结构自身不执行选择。 |

`builtin_method_ids` 的各组均为显式 u32 域内编号，不能跨域直接比较。以下列出本文件定义的编号块；块内有空洞时不能按范围推断枚举成员存在。

| 域 | 声明的编号组 |
| --- | --- |
| array | StaticMethod 1–4；PrototypeMethod 100–137；ConstructorMethod.construct=200。 |
| json | StaticMethod：is_raw_json=1、parse=2、raw_json=3、stringify=4。 |
| buffer | StaticMethod.is_view=1；ArrayBufferPrototypeMethod 101–106；SharedArrayBufferPrototypeMethod 201–202；DataViewGetMethod 301–311、DataViewSetMethod 321–331；四组 AccessorMethod 为 401–405、421–423、441–443、461–465；Uint8ArrayStaticMethod 501–502、Uint8ArrayPrototypeMethod 521–524；ConstructorMethod 901–902。 |
| reflect / error_object | reflect.StaticMethod 1–15（含 Proxy revoke 两项）；error_object.PrototypeMethod 1–3。 |
| collection | PrototypeMethod 1–21；ConstructorMethod 200–203。没有 collection.StaticMethod 枚举；lookup 的 ConstructorKind 1–4 是另一套选择编号。 |
| date | StaticMethod 1–3；ConstructorMethod=100；PrototypeMethod 101–135 为普通方法选择，136/137 为携带预先捕获毫秒值的内部 setter 选择。遗留编解码只涵盖 101–134。 |
| iterator | AccessorMethod 1–4；StaticMethod 101–104；PrototypeMethod 201–212；IntrinsicMethod 213–216 对应 array iterator next 与 generator next/return/throw。 |
| number / object | number 静态 1–6、原型 101–105；object 静态 1–23、ConstructorMethod.call=100。此文件未声明 object.PrototypeMethod。 |
| weak_ref | PrototypeMethod：deref=1、finrec_register=2、finrec_unregister=3。 |
| promise | LegacyStaticMethod 1–10（含 all_keyed、all_settled_keyed）；PrototypeMethod then/catch/finally=101–103。 |
| regexp | StaticMethod.escape=1；PrototypeMethod 101–109；AccessorMethod 201–210；LegacyAccessorMethod 301–306、311–319；ConstructorMethod.construct=1000。 |
| string | StaticMethod 1–3、ConstructorMethod.call=4；PrototypeMethod 在 100–145 中稀疏分布，iterator_next=144 不参与字符串遗留编解码，replace=145 则转换成遗留 44。 |

`builtin_method_id_lookup` 提供 string/array/collection/date/buffer/regexp/uri 的名称、编号与选择器转换，不访问运行时状态。string 的 legacy 常量分别为 split=27、normalize=37、search=40、match=41、replace_all=42、match_all=43、replace=44；不能统一用记录 ID 减 100 替代显式 switch。表内所有 name slice 及回传的名称均为借用，函数不分配。

### `name_id.lookup` (`src/core/host_function.zig:28`)

- **签名**：`pub noinline fn lookup(name: []const u8, table: []const Entry) ?u32`。
- **作用**：按名称在借用表中找域内 ID。
- **实现**：从首项起逐字节、区分大小写比较，返回首个相等项的 id；重复名称不报错，空表或无匹配返回 null。
- **所有权 / 错误 / 调用**：不分配、不 intern、不验证 id；表与字符串由调用方保持有效。

### `InternalCallableTag.usesCallerRealm` (`src/core/host_function.zig:58`)

- **签名**：`pub fn usesCallerRealm(self: InternalCallableTag) bool`。
- **作用**：给内部调用分发提供 realm 选择标志。
- **实现**：promise_resolving、promise_capability_executor、promise_combinator_element、promise_finally_callback，以及所列 async/iterator/generator/array_from_async 续体返回 true；none 和 throw_type_error_intrinsic 返回 false。
- **所有权 / 错误 / 调用**：纯枚举判据；本函数不读取对象、不切换 realm，也不验证调用上下文。实际采用该标志的分发器负责 realm 选择。

### `CallbackHost.callWithThis` (`src/core/host_function.zig:117`)

- **签名**：`pub fn callWithThis(self: CallbackHost, callback: JSValue, this_value: JSValue, args: []const JSValue) !JSValue`。
- **作用**：经已注入的回调适配器调用 callback，并显式传 this。
- **实现**：先要求 call 非空，再要求 ctx 非空；任一个缺失都返回 error.TypeError。否则原样传入 ctx、callback、this_value、args 和 globals，并返回适配器结果。
- **所有权 / 错误 / 调用**：自身可能产生 TypeError，此外传播 CallbackError 的七类错误；不验证 callback 可调用性、不建立根帧，也不校验 globals 与 ctx 的关联。参数借用，其执行语义由适配器提供。

### `CallbackHost.callValue` (`src/core/host_function.zig:123`)

- **签名**：`pub fn callValue(self: CallbackHost, callback: JSValue, args: []const JSValue) !JSValue`。
- **作用**：以 undefined 为 this 调用同一适配器。
- **实现**：构造 JSValue.undefinedValue()，直接委托 callWithThis。
- **所有权 / 错误 / 调用**：共享其缺失配置时的 TypeError 和适配器错误；不复制 args 或更改 CallbackHost。

### `isConstructorCProto` (`src/core/host_function.zig:188`)

- **签名**：`pub fn isConstructorCProto(cproto: NativeCProto) bool`。
- **作用**：判断一种 C 回调协议是否属于可构造的四个协议。
- **实现**：constructor、constructor_magic、constructor_or_func、constructor_or_func_magic 为 true；generic、getter/setter 和浮点叶子等其余协议为 false。
- **所有权 / 错误 / 调用**：不检查函数对象或 InternalEntry 的 managed 覆盖项；这只是对 cproto 的纯分类。

### `builtin_method_id_lookup.string.staticMethodId` (`src/core/host_function.zig:828`)

- **签名**：`pub fn staticMethodId(name: []const u8) ?u32`。
- **作用**：将 String 静态方法名转换为域内记录 ID。
- **实现**：逐字节精确匹配 fromCharCode、fromCodePoint、raw 并返回相应 StaticMethod 值；其余名称返回 null。
- **所有权 / 错误 / 调用**：纯映射，无分配或运行时表查询；返回的不是包含 NativeBuiltinDomain 编码的完整 ID。

### `builtin_method_id_lookup.string.prototypeMethodId` (`src/core/host_function.zig:835`)

- **签名**：`pub fn prototypeMethodId(name: []const u8) ?u32`。
- **作用**：把支持的 String 原型方法名映射到域内记录 ID。
- **实现**：显式名称比较链；toLocaleUpperCase 与 toUpperCase 共用 ID，toLocaleLowerCase 与 toLowerCase 共用 ID。未列出的名称（包括 substr、trimLeft、trimRight）返回 null。
- **所有权 / 错误 / 调用**：区分大小写且不做规范化；识别名称不保证对象上的当前属性仍指向该内建函数。

### `builtin_method_id_lookup.string.decodePrototypeMethodId` (`src/core/host_function.zig:871`)

- **签名**：`pub fn decodePrototypeMethodId(id: u32) ?u32`。
- **作用**：把字符串域的记录 ID 转为遗留分发编号。
- **实现**：显式 switch，而非统一加减偏移；charAt 为 0、concat 为 10、trimStart/End 为 21/22、split 为 27、normalize 为 37、search/match/replaceAll/matchAll/replace 为 40–44，其余已列方法按分支转换，未列返回 null。
- **所有权 / 错误 / 调用**：输入是域内记录编号；输出 0 是有效结果，不能当作无匹配。无 VM 调用或表注册检查。

### `builtin_method_id_lookup.string.encodePrototypeMethodId` (`src/core/host_function.zig:918`)

- **签名**：`pub fn encodePrototypeMethodId(decoded: u32) ?u32`。
- **作用**：把支持的遗留字符串方法编号转换回域内记录 ID。
- **实现**：对 decode 中列出的编号作反向 switch；包括 padStart/End 的 34/35、localeCompare 的 36、normalize 的 37 和 search 的 40。未列编号如 substr 的 25 返回 null。
- **所有权 / 错误 / 调用**：两函数在所列映射上互逆；源码旧注释把 pad/normalize/locale/search 描述为无记录，已与当前分支不符，应以 switch 为准。不验证记录是否已安装。

### `builtin_method_id_lookup.array.decodePrototypeMethodId` (`src/core/host_function.zig:958`)

- **签名**：`pub fn decodePrototypeMethodId(id: u32) ?u32`。
- **作用**：将部分 Array 原型记录编号转换为遗留分发编号。
- **实现**：filter/reduce 对应 1/2；some/every 对应 4/5；indexOf、includes、lastIndexOf、at、slice、splice、reverse、push、pop、concat、sort、values、keys、entries 依次对应 6–19。其他记录返回 null。
- **所有权 / 错误 / 调用**：这是部分映射，map、reduceRight、forEach 等枚举成员也可能返回 null；不能用它判断一个数组内建是否存在或可调用。

### `builtin_method_id_lookup.collection.constructorId` (`src/core/host_function.zig:1004`)

- **签名**：`pub fn constructorId(name: []const u8) ?u32`。
- **作用**：把构造名称映射到 ConstructorKind 的整数值。
- **实现**：精确匹配 Map、Set、WeakMap、WeakSet，依次返回 1–4，其他名称返回 null。
- **所有权 / 错误 / 调用**：只检查借用的名称字节，不验证函数对象；返回的 kind 不是构造记录 ID，也不是 ClassId。

### `builtin_method_id_lookup.collection.constructIdForKind` (`src/core/host_function.zig:1015`)

- **签名**：`pub fn constructIdForKind(kind: u32) ?u32`。
- **作用**：将集合构造 kind 转成域内构造记录 ID。
- **实现**：1、2、3、4 分别映射为 construct_map=200、construct_set=201、construct_weak_map=202、construct_weak_set=203；其他 u32 返回 null。
- **所有权 / 错误 / 调用**：纯转换，不构造对象，不查询已安装函数；构建完整 native builtin 引用还需要 collection 域。

### `builtin_method_id_lookup.collection.prototypeMethodId` (`src/core/host_function.zig:1049`)

- **签名**：`pub fn prototypeMethodId(name: []const u8) ?u32`。
- **作用**：查集合方法的域内记录编号。
- **实现**：线性查 prototype_method_ids；set/get/has/delete/clear/add/keys/values/entries/forEach/getOrInsert/getOrInsertComputed/next/get size 依次为 1–14；difference/intersection/isDisjointFrom/isSubsetOf/isSupersetOf/symmetricDifference/union 为 15–21。
- **所有权 / 错误 / 调用**：精确匹配，size 必须写成 get size；未知名称返回 null。此表不按接收者 class 过滤，也不读对象属性。

### `builtin_method_id_lookup.collection.legacyBasePrototypeMethodId` (`src/core/host_function.zig:1053`)

- **签名**：`fn legacyBasePrototypeMethodId(id: u32) ?u32`。
- **作用**：筛出遗留基本集合方法编号。
- **实现**：set 至 getOrInsertComputed 的十二个枚举值（1–12）原样返回；next、size、集合运算及其他编号返回 null。
- **所有权 / 错误 / 调用**：不改变编号，不访问运行时，是 legacyClosureMethodId 的内部过滤器。

### `builtin_method_id_lookup.collection.legacyClosureMethodId` (`src/core/host_function.zig:1072`)

- **签名**：`pub fn legacyClosureMethodId(name: []const u8) ?u32`。
- **作用**：将名称映射为遗留闭包支持的集合方法编号。
- **实现**：先 prototypeMethodId 查表，再接受基本方法 1–12；否则仅允许 iterator_next=13，其余返回 null。
- **所有权 / 错误 / 调用**：get size 和集合代数方法虽能在名称表中找到，也会在这里被排除；不创建闭包或验证接收者。

### `builtin_method_id_lookup.collection.fastPrototypeMethodIdForClass` (`src/core/host_function.zig:1081`)

- **签名**：`pub fn fastPrototypeMethodIdForClass(class_id: ClassId, name: []const u8) ?u32`。
- **作用**：按 class 和方法名筛选集合快路径候选编号。
- **实现**：Map/WeakMap 只接受 set/get/has/delete；Set/WeakSet 只接受 add/has/delete；其他 class 或名称返回 null。各组内部先查名称表，再过滤 ID。
- **所有权 / 错误 / 调用**：不查实例、原型或当前属性是否被覆盖；返回非 null 仅表示 class/name 组合满足此处条件，外围仍负责快路径其他前提。

### `builtin_method_id_lookup.date.staticMethodId` (`src/core/host_function.zig:1113`)

- **签名**：`pub fn staticMethodId(name: []const u8) ?u32`。
- **作用**：将 Date 静态方法名映射为域内编号。
- **实现**：UTC、parse、now 分别返回 1、2、3；逐字节区分大小写，其他名称返回 null。
- **所有权 / 错误 / 调用**：纯名称匹配，不执行日期解析或读取时钟。

### `builtin_method_id_lookup.date.decodePrototypeMethodId` (`src/core/host_function.zig:1125`)

- **签名**：`pub fn decodePrototypeMethodId(id: u32) ?u32`。
- **作用**：将支持的 Date 原型记录 ID 转成遗留编号。
- **实现**：显式 switch 对应 101–134 → 1–34，getTime 到 toTimeString；其他编号返回 null，包括 to_primitive=135、内部 captured setter 136/137、构造 100 和静态 1–3。
- **所有权 / 错误 / 调用**：并非所有 PrototypeMethod 枚举都可解码；不执行方法，也不判断某编号是否在运行时安装。

### `builtin_method_id_lookup.date.encodePrototypeMethodId` (`src/core/host_function.zig:1170`)

- **签名**：`pub fn encodePrototypeMethodId(decoded: u32) ?u32`。
- **作用**：把遗留 Date 方法编号转换回域内记录 ID。
- **实现**：显式 switch 对应 1–34 → 101–134，与 decode 的已定义映射互逆；0、35 及其他值返回 null。
- **所有权 / 错误 / 调用**：只返回整数，不包含域编码或对象状态；不产生 to_primitive 或 captured setter 的记录编号。

### `builtin_method_id_lookup.buffer.dataViewGetMethodId` (`src/core/host_function.zig:1219`)

- **签名**：`pub fn dataViewGetMethodId(name: []const u8) ?u32`。
- **作用**：查 DataView 的 get 方法记录 ID。
- **实现**：委托 dataViewGetOrSetMethodId(name, false)，支持 getInt8 至 getBigUint64 的十一种后缀，返回 301–311。
- **所有权 / 错误 / 调用**：包含 getFloat16；set 前缀、未知后缀或大小写不符返回 null，无分配。

### `builtin_method_id_lookup.buffer.dataViewSetMethodId` (`src/core/host_function.zig:1223`)

- **签名**：`pub fn dataViewSetMethodId(name: []const u8) ?u32`。
- **作用**：查 DataView 的 set 方法记录 ID。
- **实现**：委托 dataViewGetOrSetMethodId(name, true)，接受十一种 set 方法，返回相应 get ID 加 20，即 321–331。
- **所有权 / 错误 / 调用**：包含 setFloat16；get 前缀或未知名称返回 null，不执行写操作。

### `builtin_method_id_lookup.buffer.dataViewGetOrSetMethodId` (`src/core/host_function.zig:1231`)

- **签名**：`noinline fn dataViewGetOrSetMethodId(name: []const u8, is_set: bool) ?u32`。
- **作用**：统一解析 DataView get/set 方法名。
- **实现**：少于三个字节返回 null；前三字节须等于 is_set 指定的 set 或 get。后缀 Int8/Uint8/Int16/Uint16/Int32/Uint32/Float16/Float32/Float64/BigInt64/BigUint64 依次取 get ID 301–311；set 分支再加两枚举首项差值 20。
- **所有权 / 错误 / 调用**：仅 get 或 set 的空后缀也返回 null；精确比较且不分配。该偏移依赖当前枚举排列，不是由任意两个枚举自动建立映射。

### `builtin_method_id_lookup.buffer.arrayBufferAccessorMethodId` (`src/core/host_function.zig:1268`)

- **签名**：`pub fn arrayBufferAccessorMethodId(name: []const u8) ?u32`。
- **作用**：将访问器属性名映射为域内记录 ID。
- **实现**：`byteLength`=401、`detached`=402、`maxByteLength`=403、`resizable`=404、`immutable`=405；按名称逐字节匹配，其他名称返回 null。
- **所有权 / 错误 / 调用**：名称是属性名，不带 get 前缀；不调用 getter、不验证接收者或 buffer 状态。

### `builtin_method_id_lookup.buffer.sharedArrayBufferAccessorMethodId` (`src/core/host_function.zig:1277`)

- **签名**：`pub fn sharedArrayBufferAccessorMethodId(name: []const u8) ?u32`。
- **作用**：将访问器属性名映射为域内记录 ID。
- **实现**：`byteLength`=421、`maxByteLength`=422、`growable`=423；按名称逐字节匹配，其他名称返回 null。
- **所有权 / 错误 / 调用**：名称是属性名，不带 get 前缀；不调用 getter、不验证接收者或 buffer 状态。

### `builtin_method_id_lookup.buffer.dataViewAccessorMethodId` (`src/core/host_function.zig:1284`)

- **签名**：`pub fn dataViewAccessorMethodId(name: []const u8) ?u32`。
- **作用**：将访问器属性名映射为域内记录 ID。
- **实现**：`buffer`=441、`byteLength`=442、`byteOffset`=443；按名称逐字节匹配，其他名称返回 null。
- **所有权 / 错误 / 调用**：名称是属性名，不带 get 前缀；不调用 getter、不验证接收者或 buffer 状态。

### `builtin_method_id_lookup.buffer.typedArrayAccessorMethodId` (`src/core/host_function.zig:1291`)

- **签名**：`pub fn typedArrayAccessorMethodId(name: []const u8) ?u32`。
- **作用**：将访问器属性名映射为域内记录 ID。
- **实现**：`buffer`=461、`byteLength`=462、`byteOffset`=463、`length`=464、`[Symbol.toStringTag]`=465；按名称逐字节匹配，其他名称返回 null。
- **所有权 / 错误 / 调用**：名称是属性名，不带 get 前缀；不调用 getter、不验证接收者或 buffer 状态。这里的 [Symbol.toStringTag] 是字面字符串，不是 JS Symbol 值。

### `builtin_method_id_lookup.buffer.dataViewGetKindFromRecordId` (`src/core/host_function.zig:1300`)

- **签名**：`pub fn dataViewGetKindFromRecordId(id: u32) ?u32`。
- **作用**：把 DataView get 记录 ID 转为其元素类型选择编号。
- **实现**：301–306（Int8 至 Uint32）依次对应 1–6；Float16=307 对应 11，Float32/Float64/BigInt64/BigUint64=308–311 对应 7–10；其他 ID 返回 null。
- **所有权 / 错误 / 调用**：类型选择编号不是字节宽度，也不能按记录 ID 简单相减；get 与 set 只接受各自的记录范围，不做 buffer 越界、detach 或字节序检查。

### `builtin_method_id_lookup.buffer.dataViewSetKindFromRecordId` (`src/core/host_function.zig:1317`)

- **签名**：`pub fn dataViewSetKindFromRecordId(id: u32) ?u32`。
- **作用**：把 DataView set 记录 ID 转为其元素类型选择编号。
- **实现**：321–326（Int8 至 Uint32）依次对应 1–6；Float16=327 对应 11，Float32/Float64/BigInt64/BigUint64=328–331 对应 7–10；其他 ID 返回 null。
- **所有权 / 错误 / 调用**：类型选择编号不是字节宽度，也不能按记录 ID 简单相减；get 与 set 只接受各自的记录范围，不做 buffer 越界、detach 或字节序检查。

### `builtin_method_id_lookup.buffer.arrayBufferAccessorNameFromRecordId` (`src/core/host_function.zig:1334`)

- **签名**：`pub fn arrayBufferAccessorNameFromRecordId(id: u32) ?[]const u8`。
- **作用**：将访问器记录 ID 转回属性名称。
- **实现**：switch 反向映射 `byteLength`=401、`detached`=402、`maxByteLength`=403、`resizable`=404、`immutable`=405；其他编号返回 null。
- **所有权 / 错误 / 调用**：返回静态字符串的借用 slice，无分配、无需释放；不会查询对象当前属性。

### `builtin_method_id_lookup.buffer.sharedArrayBufferAccessorNameFromRecordId` (`src/core/host_function.zig:1345`)

- **签名**：`pub fn sharedArrayBufferAccessorNameFromRecordId(id: u32) ?[]const u8`。
- **作用**：将访问器记录 ID 转回属性名称。
- **实现**：switch 反向映射 `byteLength`=421、`maxByteLength`=422、`growable`=423；其他编号返回 null。
- **所有权 / 错误 / 调用**：返回静态字符串的借用 slice，无分配、无需释放；不会查询对象当前属性。

### `builtin_method_id_lookup.buffer.dataViewAccessorNameFromRecordId` (`src/core/host_function.zig:1354`)

- **签名**：`pub fn dataViewAccessorNameFromRecordId(id: u32) ?[]const u8`。
- **作用**：将访问器记录 ID 转回属性名称。
- **实现**：switch 反向映射 `buffer`=441、`byteLength`=442、`byteOffset`=443；其他编号返回 null。
- **所有权 / 错误 / 调用**：返回静态字符串的借用 slice，无分配、无需释放；不会查询对象当前属性。

### `builtin_method_id_lookup.buffer.typedArrayAccessorNameFromRecordId` (`src/core/host_function.zig:1363`)

- **签名**：`pub fn typedArrayAccessorNameFromRecordId(id: u32) ?[]const u8`。
- **作用**：将访问器记录 ID 转回属性名称。
- **实现**：switch 反向映射 `buffer`=461、`byteLength`=462、`byteOffset`=463、`length`=464、`[Symbol.toStringTag]`=465；其他编号返回 null。
- **所有权 / 错误 / 调用**：返回静态字符串的借用 slice，无分配、无需释放；不会查询对象当前属性。

### `builtin_method_id_lookup.regexp.accessorMethodId` (`src/core/host_function.zig:1399`)

- **签名**：`pub fn accessorMethodId(name: []const u8) ?u32`。
- **作用**：把 RegExp 访问器属性名映射为域内记录 ID。
- **实现**：线性查静态表：source/flags/global/ignoreCase/multiline/dotAll/unicode/sticky/hasIndices/unicodeSets 依次为 201–210；无匹配返回 null。
- **所有权 / 错误 / 调用**：精确匹配属性名，不接受 get 前缀；不读取正则对象或执行 getter。

### `builtin_method_id_lookup.regexp.accessorNameFromId` (`src/core/host_function.zig:1403`)

- **签名**：`pub fn accessorNameFromId(id: u32) ?[]const u8`。
- **作用**：将 RegExp 访问器记录编号转回名称。
- **实现**：switch 对 201–210 返回 source 至 unicodeSets 的对应名字，其他编号返回 null。
- **所有权 / 错误 / 调用**：返回静态字符串借用，不分配；与 accessorMethodId 的十个表项互逆，不包含 legacy accessor。

### `builtin_method_id_lookup.regexp.accessorNameFromGetterName` (`src/core/host_function.zig:1419`)

- **签名**：`pub fn accessorNameFromGetterName(name: []const u8) ?[]const u8`。
- **作用**：从规范形式的 getter 名得到访问器属性名。
- **实现**：先 accessorIdFromGetterName 检查前缀并查 ID，失败返回 null；成功再 accessorNameFromId 返回静态属性名称。
- **所有权 / 错误 / 调用**：返回值不是输入字符串的借用子串；无分配、不调用 getter。

### `builtin_method_id_lookup.regexp.accessorIdFromGetterName` (`src/core/host_function.zig:1425`)

- **签名**：`pub fn accessorIdFromGetterName(name: []const u8) ?u32`。
- **作用**：解析 get <accessor> 形式的函数名。
- **实现**：必须以精确的 get 加一个空格开头，然后将剩余全部字节交给 accessorMethodId；前缀不符或属性名未知返回 null。
- **所有权 / 错误 / 调用**：不 trim 空白、不接受大小写变体；get 末尾没有有效名称或含额外空白也不匹配。

### `builtin_method_id_lookup.regexp.legacyAccessorMethodFromId` (`src/core/host_function.zig:1430`)

- **签名**：`pub fn legacyAccessorMethodFromId(id: u32) ?LegacyAccessorMethod`。
- **作用**：把已知整数 ID 转成 LegacyAccessorMethod 枚举。
- **实现**：接受 301–306 的 input getter/setter、lastMatch、lastParen、leftContext、rightContext，以及 311–319 的九个 capture getter；其他值包括中间空洞返回 null。
- **所有权 / 错误 / 调用**：显式 switch 避免将任意整数强转为枚举；不读取或设置 legacy RegExp 状态。

### `builtin_method_id_lookup.regexp.legacyCaptureIndex` (`src/core/host_function.zig:1451`)

- **签名**：`pub fn legacyCaptureIndex(method: LegacyAccessorMethod) ?usize`。
- **作用**：将九个 capture getter 枚举映射为零基索引。
- **实现**：get_capture_1 至 get_capture_9 分别返回 0–8；input、lastMatch 等其他合法枚举值返回 null。
- **所有权 / 错误 / 调用**：0 是有效 capture 索引；本函数不检查实际匹配是否有对应捕获组。

### `builtin_method_id_lookup.uri.methodId` (`src/core/host_function.zig:1472`)

- **签名**：`pub fn methodId(name: []const u8) ?u32`。
- **作用**：将 URI 全局函数名映射成模式编号。
- **实现**：encodeURI、encodeURIComponent、decodeURI、decodeURIComponent 分别返回 1、2、3、4；其他名称返回 null。
- **所有权 / 错误 / 调用**：仅区分大小写的名称比较，不执行编码、解码或 URI 校验，也不核验当前全局绑定。

### `genericMagicHandler` (`src/core/host_function.zig:1539`)

- **签名**：`pub fn genericMagicHandler(entry: InternalEntry) ?NativeGenericMagicFn`。
- **作用**：从声明记录的 native_function 联合体中提取 generic_magic 回调。
- **实现**：native_function 为 null 时返回 null；否则只接受联合体实际标签 generic_magic，其余臂均返回 null。
- **所有权 / 错误 / 调用**：不检查 entry.cproto，也不优先解析 managed、prim_leaf 或 fallback_function；因此返回值不等同于最终 NativeEntry 会采用的执行目标。

## 覆盖核对

- 清单函数数: 69（`src/core/function.zig` 12 + `src/core/host_function.zig` 40 + `src/core/native_entry.zig` 11 + `src/core/native_object.zig` 6）
- 本文标题覆盖: 69
- 未覆盖: 无
