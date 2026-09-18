# 01 — `JSObject`：宿主对象绑定

`src/binding/binding.zig` 把 comptime payload 规格收成 realm-local 的 class 安装与 typed 方法适配。存储策略决定 JS 还是宿主拥有 external payload；类型扫描检测到 GC 可见字段时，强制显式 `trace`，JS 拥有的还要 `deinit`。扫描有深度和类型限制，未报错不代表 payload 没有需要追踪的引用。返回的 Binding 视图默认借 Realm，除非 `retain`。公共拼写：`zjs.host.NativeBinding`。

方法 stub 与 payload 查找按 class id 和直接原型指针匹配。正常安装到不同 realm 的原型不同，因此默认拒绝其他 realm 的包装；这不是不可变的创建 realm 身份检查，修改实例原型也会改变是否匹配。

---

## 类型与 error

| 名字 | 含义 |
| --- | --- |
| `BindingError` | `NotInstalled`（runtime/realm 还没 install）、`TypeError`。 |
| `HostCall` | 方法适配器看到的 per-call 视图：`realm`、`this_value`、`args`。NB2 `Call` 的子集。 |
| `MethodRuntime` | 每个方法函数对象的 `entry.state`：`runtime` + `class_id`。teardown 时 `deinit` 释放这块。 |
| `Properties` | `static(entries)` 包一层带 `zjs_binding_static_properties` 标记的类型。 |
| `TraceVisitor` | 把 core `PayloadVisitor` 收成 typed：`value(*JSValue)` / `object(*?*Object)`。 |
| `Storage` | `inline_value` 或 `external_ptr`。`Owner`：`.js` / `.host`。 |
| `JSObject(Payload, spec)` | 生成的类类型。`spec` 必须有 `.storage`；类型扫描命中 GC 可见字段则强制 `.trace`，此时 JS-owned 还强制 `.deinit`。`inline_value` 禁止零尺寸 payload。 |
| `JSObject.Binding` | 借来的 realm 视图：`realm` + `class_id`。prototype 每次从 realm 表解析，避免握着裸 `*Object` 活过 context。 |
| `JSObject.OwnedBinding` | `RealmRef` + pin realm header。`deinit` 时 unpin + `RealmRef.deinit`。 |
| `RuntimeState` | 每 runtime：intern 好的静态属性名 `[]PropNameID`。class 表 `binding_data` 持有，finalizer 里 release。 |
| `CallbackParamKind` | 方法参数分类：self / context / raw_call / rest_values / value / bool / integer / float / string / utf8 / bytes / bytes_ro / bytes_rw。 |

`new` 的参数类型：inline 与 JS-owned external 是 `Payload` 值；host-owned 是 `*Payload`。

---

## 工厂与存储

### `MethodRuntime.deinit` (`src/binding/binding.zig:35`)

- **签名**：`fn deinit(ptr: *anyopaque) void`。
- **作用**：runtime 销毁时释放一块 `MethodRuntime`。
- **实现**：ptrCast 后 `runtime.memory.destroy`。
- **所有权 / 错误 / 调用**：经 `registerNativeEntryFinalizer` 登记。与 payload `deinit` 不是一回事。

### `method` (`src/binding/binding.zig:41`)

- **签名**：`pub fn method(comptime name: []const u8, comptime call: anytype) Method(@TypeOf(call))`。
- **作用**：写 `Properties.static(.{ method("read", read) })` 这种条目。
- **实现**：返回 `{ .name, .call }`。
- **所有权 / 错误 / 调用**：纯编译期：返回按值的聚合，`name` 是编译期字符串字面量、`call` 是函数值，都不分配也不需要释放；无 error set（形状错的条目由 `JSObject` 侧的 `@compileError` 拦截，不在这里）。调用方是嵌入方写的 spec，树内在 `src/binding/binding.zig:1110` 等测试 spec 与 `src/tests/embedding_examples.zig:525` 出现。

### `Method` (`src/binding/binding.zig:48`)

- **签名**：`pub fn Method(comptime Call: type) type`。
- **作用**：方法条目的类型构造器。
- **实现**：`struct { name: []const u8, call: Call }`。
- **所有权 / 错误 / 调用**：纯编译期类型构造器：只产出类型，不产生值也不分配，无 error set。唯一调用方是 `method`（`src/binding/binding.zig:41`）的返回类型位置；`JSObject` 侧靠字段名 `name` / `call` 结构化识别条目，并不 `@TypeOf` 比对这个类型。

### `Properties.static` (`src/binding/binding.zig:56`)

- **签名**：`pub fn static(comptime entries: anytype) Static(@TypeOf(entries))`。
- **作用**：把 tuple 标成静态属性表。
- **实现**：`return .{ .entries = entries };`
- **所有权 / 错误 / 调用**：纯编译期：把 tuple 原样装进 `.entries`，值语义、不分配、无 error set。`Static(Entries)` 带的 `zjs_binding_static_properties` 标记声明才是识别点（`isStaticProperties`），`staticPropertyEntryCount` 等 comptime 助手据此决定读 `.entries` 还是读 spec 本身。

### `Properties.Static` (`src/binding/binding.zig:60`)

- **签名**：`pub fn Static(comptime Entries: type) type`。
- **作用**：带 `zjs_binding_static_properties = true` 的包装类型。
- **实现**：struct 含 `entries: Entries`。
- **所有权 / 错误 / 调用**：`isStaticProperties` 靠这个 decl。

### `TraceVisitor.value` (`src/binding/binding.zig:71`)

- **签名**：`pub inline fn value(self: *TraceVisitor, value_slot: *core.JSValue) void`。
- **作用**：把 payload 里的 `JSValue` 槽交给 tracer。
- **实现**：`self.inner.value(@ptrCast(value_slot))`。
- **所有权 / 错误 / 调用**：供用户 trace 钩子访问真实 payload 槽，不创建独立持久根。visitor 和槽指针必须在本次遍历期间有效，不应把 visitor 保存到回调结束之后。

### `TraceVisitor.object` (`src/binding/binding.zig:75`)

- **签名**：`pub inline fn object(self: *TraceVisitor, object_slot: *?*core.Object) void`。
- **作用**：把可选对象槽交给 tracer。
- **实现**：`self.inner.object(@ptrCast(object_slot))`。
- **所有权 / 错误 / 调用**：同上。

### `Storage.externalPtr` (`src/binding/binding.zig:84`)

- **签名**：`pub fn externalPtr(options: ExternalPtr) Storage`。
- **作用**：构造 `external_ptr` 存储策略。
- **实现**：`return .{ .external_ptr = options };`
- **所有权 / 错误 / 调用**：`owner` 默认 `.js`。

### `JSObject` (`src/binding/binding.zig:98`)

- **签名**：`pub fn JSObject(comptime Payload: type, comptime spec: anytype) type`。
- **作用**：生成宿主类类型：install/new/payload、Binding/OwnedBinding、方法 stub。
- **实现**：读 `specStorage`；inline 零尺寸 compile error；`payloadRequiresTrace` 则必须有 `.trace`；JS-owned 且需 trace 则必须 `.deinit`。内部 `class_id_slot` 进程全局。
- **所有权 / 错误 / 调用**：`zjs.host.NativeBinding.JSObject`。install 是 realm-local。

---

## Binding / OwnedBinding

### `Binding.prototype` (`src/binding/binding.zig:128`)

- **签名**：`pub fn prototype(self: Binding) ?*core.Object`。
- **作用**：从 realm class-prototype 表取原型。
- **实现**：`self.realm.classPrototypeObject(self.class_id)`。
- **所有权 / 错误 / 调用**：借用 realm 表中的对象，槽为空或不是对象时返回 null；前提是 realm 本身仍存活。Binding 不保活 realm，悬空指针不会被此方法安全转换成 null。

### `Binding.retain` (`src/binding/binding.zig:134`)

- **签名**：`pub fn retain(self: Binding) !OwnedBinding`。
- **作用**：宿主状态要活过当前 context 时，把借用视图升级成拥有。
- **实现**：`gc.pinHeader(&realm.header)`（escaping holder 不是 traced parent），再 `RealmRef.retain`。
- **所有权 / 错误 / 调用**：pin 可能失败，成功后须配对 OwnedBinding.deinit。真正保活来自 GC pin；当前 RealmRef.retain 只是保存指针，不再增加 realm 引用计数。OwnedBinding 仍不得活过 Runtime 销毁。

### `Binding.new` (`src/binding/binding.zig:144`)

- **签名**：`pub fn new(self: Binding, data: Arg) !core.JSValue`。
- **作用**：在这个 realm 里 new 一个包装对象。
- **实现**：`Self.newWithBinding(self, data)`。
- **所有权 / 错误 / 调用**：返回的 JSValue 按普通根规则。

### `Binding.payload` (`src/binding/binding.zig:148`)

- **签名**：`pub fn payload(self: Binding, value: core.JSValue) ?*Payload`。
- **作用**：从包装取出 payload；realm/class/prototype 不符则 null。
- **实现**：`payloadFromBinding`。
- **所有权 / 错误 / 调用**：不拥有或 pin payload。检查依据当前直接原型，而非创建 realm；原型被改动可能使原实例不再匹配。返回指针不能在包装或宿主存储失效后继续使用。

### `OwnedBinding.deinit` (`src/binding/binding.zig:159`)

- **签名**：`pub fn deinit(self: *OwnedBinding) void`。
- **作用**：unpin realm header 并放下 RealmRef。
- **实现**：`borrow()` 成功则 `unpinHeader`；`realm.deinit()`。
- **所有权 / 错误 / 调用**：撤销本次 pin 并清空 RealmRef；实际回收由其他根、heap 边及后续 GC 决定，不保证立即发生。同一实例重复 deinit 不再 unpin，但复制活跃 OwnedBinding 不会新增 pin，不能分别释放复制件。

### `OwnedBinding.borrow` (`src/binding/binding.zig:164`)

- **签名**：`pub fn borrow(self: OwnedBinding) BindingError!Binding`。
- **作用**：再得到一份借用视图。
- **实现**：`RealmRef.borrow()` 空 → `NotInstalled`。
- **所有权 / 错误 / 调用**：不额外 pin，不检查 class/prototype 是否仍安装；返回的借用依赖这个 OwnedBinding 或其他存活保证，不能脱离它单独长期保存。

### `OwnedBinding.new` (`src/binding/binding.zig:171`)

- **签名**：`pub fn new(self: OwnedBinding, data: Arg) !core.JSValue`。
- **作用**：经 borrow 再 new。
- **实现**：`Self.newWithBinding(try self.borrow(), data)`。
- **所有权 / 错误 / 调用**：RealmRef 已清空时返回 NotInstalled；该判断不是探测已释放内存。成功 borrow 后仍可能因原型缺失或实例分配失败返回错误。

### `OwnedBinding.payload` (`src/binding/binding.zig:175`)

- **签名**：`pub fn payload(self: OwnedBinding, value: core.JSValue) ?*Payload`。
- **作用**：borrow 失败当 null。
- **实现**：`borrow() catch return null` 再 `payloadFromBinding`。
- **所有权 / 错误 / 调用**：返回**借用**指针：指向对象的 external/inline payload，生命周期跟着 JS 对象，调用方不得释放。null 有两个互不区分的来源——realm 已失效（`borrow()` 的 `error.NotInstalled` 被 `catch return null` 吞掉）与 `value` 不是本 class/本 prototype 的实例（`payloadFromClassAndPrototype`，`src/binding/binding.zig:304`）。整个 `OwnedBinding` 族树内没有生产调用方，只有 `src/binding/binding.zig:1088` 的 pin 测试用；注意它与同名的 `Binding.payload`（`:148`）不同，后者不做 borrow。

---

## 安装与 payload

### `RuntimeState.create` (`src/binding/binding.zig:185`)

- **签名**：`fn create(rt: *core.JSRuntime) !*RuntimeState`。
- **作用**：分配 runtime 绑定状态并 intern 全部静态属性名。
- **实现**：`memory.create`；按 `staticPropertyCount` alloc 名数组；`internStaticPropertyNames`，失败时 release 已 intern 的。
- **所有权 / 错误 / 调用**：创建失败时按已初始化数量释放名字 pin，再释放数组和 state；成功后由 installRuntime 转交给 class 记录。名字仅按静态条目收集，不在此创建方法函数或安装原型。

### `RuntimeState.finalize` (`src/binding/binding.zig:210`)

- **签名**：`fn finalize(ptr: *anyopaque) void`。
- **作用**：release 所有 PropNameID，释放数组和 state。
- **实现**：扫 `static_property_names` `release(rt)`，free，`destroy(RuntimeState)`。
- **所有权 / 错误 / 调用**：由 class 记录清理或注册失败回退调用。释放后 state 指针失效，方法不具备重复调用的幂等保护。

### `JSObject.install` (`src/binding/binding.zig:221`)

- **签名**：`pub fn install(ctx: *core.JSContext) !void`。
- **作用**：确保 runtime 已注册 class，并在这个 realm 装 prototype（幂等）。
- **实现**：先 installRuntime；已有对象型 class prototype 则返回。否则创建原型为 null 的普通对象，安装静态属性后才写入 class-prototype 表，不创建全局构造器。
- **所有权 / 错误 / 调用**：另一个 realm 需独立安装。runtime 注册先发生，后续属性安装或设置原型失败不注销 class，也不撤销已登记的方法 entry/finalizer；重复调用已有原型时不会刷新其成员。

### `JSObject.installRuntime` (`src/binding/binding.zig:232`)

- **签名**：`fn installRuntime(rt: *core.JSRuntime) !void`。
- **作用**：每 runtime 一次：分配 class id、可选 RuntimeState、`classes.register`。
- **实现**：已有 identity 则返回。`getOrAllocate` class id；有静态属性则 `RuntimeState.create`。`ensureContextClassPrototypeCapacity`。register：名字、`binding_identity=@typeName(Self)`（同名不同 Payload 仍不同 id）、payload 尺寸/对齐、finalizer/mark 钩子。
- **所有权 / 错误 / 调用**：注册失败会 finalize 新 RuntimeState，但 class id 分配及已扩大的 context 表容量不回滚。零静态条目时不创建 RuntimeState；这里不安装任一 realm 的原型。

### `JSObject.binding` (`src/binding/binding.zig:254`)

- **签名**：`pub fn binding(ctx: *core.JSContext) BindingError!Binding`。
- **作用**：这个 realm 的借用视图。
- **实现**：runtime 未注册或本 realm 无 prototype → `NotInstalled`。
- **所有权 / 错误 / 调用**：不 retain realm。

### `JSObject.new` (`src/binding/binding.zig:264`)

- **签名**：`pub fn new(ctx: *core.JSContext, data: Arg) !core.JSValue`。
- **作用**：`binding(ctx).new(data)` 快捷方式。
- **实现**：如上。
- **所有权 / 错误 / 调用**：未 install → NotInstalled。

### `JSObject.payload` (`src/binding/binding.zig:269`)

- **签名**：`pub fn payload(ctx: *core.JSContext, value: core.JSValue) BindingError!?*Payload`。
- **作用**：经当前 realm binding 取 payload。
- **实现**：`binding` 失败上浮；找到则 `?*Payload`。
- **所有权 / 错误 / 调用**：当前 realm 未安装时返回 NotInstalled；已安装但对象品牌或原型不匹配时返回 null，不是 TypeError。判断采用当前原型，不记录对象的出生 realm。

### `JSObject.installedClassId` (`src/binding/binding.zig:274`)

- **签名**：`fn installedClassId(rt: *core.JSRuntime) ?core.ClassId`。
- **作用**：按 `classIdentity()` 在 class 表里找。
- **实现**：`rt.classes.findByIdentity`。
- **所有权 / 错误 / 调用**：未 register 则 null。

### `JSObject.installedRuntimeState` (`src/binding/binding.zig:278`)

- **签名**：`fn installedRuntimeState(rt: *core.JSRuntime, class_id: core.ClassId) ?*RuntimeState`。
- **作用**：取出 binding_data。无静态属性则永远 null。
- **实现**：`classes.record` → `binding_data` ptrCast。
- **所有权 / 错误 / 调用**：install 原型时传入。

### `JSObject.classIdentity` (`src/binding/binding.zig:285`)

- **签名**：`fn classIdentity() []const u8`。
- **作用**：稳定身份，独立于显示名。
- **实现**：`@typeName(Self)`。
- **所有权 / 错误 / 调用**：同名不同 JSObject 实例仍可共存。

### `JSObject.newWithBinding` (`src/binding/binding.zig:289`)

- **签名**：`fn newWithBinding(bound: Binding, data: Arg) !core.JSValue`。
- **作用**：按 binding 的 class/prototype 造对象并安装 payload。
- **实现**：无 prototype → NotInstalled；`Object.create(class_id, prototype)`；`errdefer destroyFromHeader`；`installPayload`。
- **所有权 / 错误 / 调用**：安装 payload 失败时显式销毁刚分配的包装对象；未安装时不会消费 data。输入值型 payload 的复制是浅拷贝，所含宿主资源如何转移仍由存储策略和 deinit 约定决定，不会自动深拷贝。

### `JSObject.payloadFromBinding` (`src/binding/binding.zig:299`)

- **签名**：`fn payloadFromBinding(bound: Binding, value: core.JSValue) ?*Payload`。
- **作用**：加上当前 realm prototype 再查。
- **实现**：无 prototype → null；`payloadFromClassAndPrototype`。
- **所有权 / 错误 / 调用**：方法 stub 也走 class+prototype 那层。

### `JSObject.payloadFromClassAndPrototype` (`src/binding/binding.zig:304`)

- **签名**：`fn payloadFromClassAndPrototype(class_id: core.ClassId, prototype: *core.Object, value: core.JSValue) ?*Payload`。
- **作用**：品牌检查：对象、class_id、**getPrototype() == prototype**、再 `externalClassPayload`。
- **实现**：任一项失败 null。
- **所有权 / 错误 / 调用**：不沿原型链、不解开 Proxy、不检查 Runtime 或单独的 realm 身份；必须直接原型指针相等。返回借用 payload，不注册根。

### `JSObject.installPayload` (`src/binding/binding.zig:312`)

- **签名**：`fn installPayload(rt: *core.JSRuntime, object: *core.Object, data: Arg) !*Payload`。
- **作用**：按存储策略把 payload 放进对象。
- **实现**：`inline_value`：写进 `externalClassPayload` 指向的 inline 区。`external_ptr.js`：`memory.create` 拷值，`installExternalClassPayload`。`external_ptr.host`：直接装调用方指针，不拷。
- **所有权 / 错误 / 调用**：inline 无 payload 槽返回 TypeError；JS-owned external 额外分配一个 Payload 并浅拷贝 data。host-owned 不复制，也不自动 deinit/free，宿主须保证指针在包装访问或 trace 期间有效。值型 Payload 含有指针时不会递归复制其指向的数据。

### `JSObject.payloadFinalizer` (`src/binding/binding.zig:335`)

- **签名**：`fn payloadFinalizer(runtime: *anyopaque, object: *anyopaque, class_payload: *core.class.Payload) void`。
- **作用**：对象死亡时跑用户 deinit，并按策略释放存储。
- **实现**：inline：`callDeinit`，payload 置 null。js external：deinit + `memory.destroy`。host：什么都不做（宿主自己管）。
- **所有权 / 错误 / 调用**：tracer 下在 collection 时跑；inline 同步在对象析构里，无 defer 队列。

### `JSObject.payloadMark` (`src/binding/binding.zig:356`)

- **签名**：`fn payloadMark(runtime: *anyopaque, object: *anyopaque, class_payload: *core.class.Payload, visitor: *core.class.PayloadVisitor) void`。
- **作用**：GC 标记 payload 里的 JS 边。
- **实现**：有 `.trace` 则 `spec.trace(payload, TraceVisitor)`；否则 `unreachable`（没有 hook 时不会登记 mark）。
- **所有权 / 错误 / 调用**：payload 为空直接返回；有 trace 时传入临时 TraceVisitor 的指针，不由框架自动枚举全部字段。宿主必须覆盖实际 GC 边，包括可达的宿主容器；是否已声明 trace 不证明其实现完整。

---

## 静态属性与方法 stub

### `JSObject.installStaticProperties` (`src/binding/binding.zig:368`)

- **签名**：`fn installStaticProperties(ctx: *core.JSContext, prototype: *core.Object, class_id: core.ClassId, runtime_state: ?*RuntimeState) !void`。
- **作用**：把 spec.properties 装到原型。
- **实现**：无 `.properties` 则返回。需要 RuntimeState。`Properties.static` 则拆 `.entries`，否则把 properties 当 tuple。
- **所有权 / 错误 / 调用**：缺少 properties 字段时直接返回；显式空 tuple 或空 Static 包装仍会先要求 RuntimeState。当前 installRuntime 对零条目不创建 state，因此显式空表会在这里返回 NotInstalled，并不等价于省略字段。

### `JSObject.installStaticPropertyEntries` (`src/binding/binding.zig:379`)

- **签名**：`fn installStaticPropertyEntries(ctx: *core.JSContext, prototype: *core.Object, class_id: core.ClassId, runtime_state: *RuntimeState, comptime properties: anytype) !void`。
- **作用**：按 tuple 下标对齐 `static_property_names[index]` 装每一条。
- **实现**：必须是 tuple struct，否则 compile error。
- **所有权 / 错误 / 调用**：名字已按相同顺序 intern。逐项安装，后续失败不撤销此前属性或方法注册；没有重复名字检查，重名条目交由正常属性定义规则处理。

### `JSObject.installStaticProperty` (`src/binding/binding.zig:392`)

- **签名**：`fn installStaticProperty(ctx: *core.JSContext, prototype: *core.Object, class_id: core.ClassId, key: PropNameID, comptime entry: anytype) !void`。
- **作用**：为一条 `method(name, fn)` 造函数并 define 到原型（writable、非 enumerable、configurable）。
- **实现**：条目必须有 `name`/`call`。`MethodStub(entry)` → `createMethodFunction` → `key.defineDataProperty`。
- **所有权 / 错误 / 调用**：函数创建先于属性定义，定义失败不撤销已注册的 NativeEntry/MethodRuntime。虽然称 static properties，这里支持的是含 name/call 的方法条目，不是任意常量属性或 accessor 描述符。

### `JSObject.staticPropertyCount` (`src/binding/binding.zig:403`)

- **签名**：`fn staticPropertyCount() comptime_int`。
- **作用**：静态属性条数。
- **实现**：无 properties → 0；否则 `staticPropertyEntryCount`。
- **所有权 / 错误 / 调用**：决定是否分配 RuntimeState。

### `JSObject.staticPropertyEntryCount` (`src/binding/binding.zig:412`)

- **签名**：`fn staticPropertyEntryCount(comptime properties: anytype) comptime_int`。
- **作用**：tuple 字段数。
- **实现**：非 tuple compile error。
- **所有权 / 错误 / 调用**：comptime_int，不分配、无运行期 error set；非 tuple 是 `@compileError`。唯一调用方是同文件 `:407` / `:409` 的包装（先剥 `Properties.static` 的 `.entries`，再落到本函数），计数用于给 `RuntimeState.static_property_names` 定长。

### `JSObject.internStaticPropertyNames` (`src/binding/binding.zig:423`)

- **签名**：`fn internStaticPropertyNames(rt: *core.JSRuntime, names: []PropNameID, initialized: *usize) !void`。
- **作用**：把 spec 里的名字 intern 进 `names`，并推进 `initialized`（供 errdefer release）。
- **实现**：拆 static wrapper 后交给 `internStaticPropertyEntryNames`。
- **所有权 / 错误 / 调用**：`RuntimeState.create`。

### `JSObject.internStaticPropertyEntryNames` (`src/binding/binding.zig:433`)

- **签名**：`fn internStaticPropertyEntryNames(rt: *core.JSRuntime, names: []PropNameID, initialized: *usize, comptime properties: anytype) !void`。
- **作用**：逐条 `PropNameID.internStatic(rt, entry.name)`。
- **实现**：校验条目形状。
- **所有权 / 错误 / 调用**：每次成功 intern 后才增加 initialized；失败保留此前数量，由 RuntimeState.create 的 errdefer 释放已取得的 pin。本方法不自行回滚，不去重名字，也不检查传入数组是否足够大；调用方按条目数分配。

### `JSObject.createMethodFunction` (`src/binding/binding.zig:451`)

- **签名**：`fn createMethodFunction( ctx: *core.JSContext, class_id: core.ClassId, name: []const u8, length: i32, method_spec: native.Spec, ) !core.JSValue`。
- **作用**：分配 `MethodRuntime` 当 entry.state，登记 finalizer，alloc NativeEntry，造 native 函数对象。
- **实现**：先 register finalizer 再松 `runtime_owned`（失败也能 teardown）。`template.state = runtime`，`arity = max(length,0)`。需要 `cached_function_proto`。`installNativeEntry`。
- **所有权 / 错误 / 调用**：finalizer 注册前失败立即销毁 MethodRuntime；注册成功后 ownership 标志关闭，后续 entry/函数创建失败仍保留该注册，留给 Runtime 清理。记录只存 runtime 和 class_id，不保留 prototype 根。arity 需能转换为 u8，超过范围不是返回式参数校验；cached_function_proto 缺失返回 InvalidBuiltinRegistry。

### `JSObject.MethodStub` (`src/binding/binding.zig:481`)

- **签名**：`fn MethodStub(comptime entry: anytype) type`。
- **作用**：为一条方法生成 `native.managed(call)` 包装。
- **实现**：`validateMethodSignature`。内嵌 `call(*native.Call)`：从 `Call.state(MethodRuntime)` 取 class_id，用**当前 callee realm** 的 prototype 做品牌检查，失败 TypeError；再 `invoke`。
- **所有权 / 错误 / 调用**：当前 this 的 class 和直接 prototype 必须匹配 callee realm 表，不检验不可变的创建 realm 身份；查找失败时不调用宿主方法。适配器使用 managed 路径，不因为参数为数字就自动改成 typed leaf。

### `MethodStub.call` (`src/binding/binding.zig:489`)

- **签名**：`fn call(c: *native.Call) anyerror!core.JSValue`。
- **作用**：managed thunk 看到的用户函数：品牌检查 + 调 typed 适配。
- **实现**：见 MethodStub。`error.TypeError` 在缝上变成 JS TypeError。
- **所有权 / 错误 / 调用**：`c.ctx` 是 callee realm。

### `JSObject.invoke` (`src/binding/binding.zig:498`)

- **签名**：`fn invoke(comptime call: anytype, self_payload: *Payload, host_call: HostCall) anyerror!core.JSValue`。
- **作用**：若有 `JSString.Utf8` 参数则准备 stackFallback allocator。
- **实现**：有 utf8 → 4KiB stackFallback 到 runtime allocator；否则 allocator=null。转 `invokeWithAllocator`。
- **所有权 / 错误 / 调用**：4 KiB 是本次调用的栈后备缓冲，不是硬性长度上限；不足时可使用 runtime allocator 并失败。临时 Utf8 在 invokeWithAllocator 退出前 deinit，回调不能保存其字节供调用结束后使用。

### `JSObject.invokeWithAllocator` (`src/binding/binding.zig:510`)

- **签名**：`fn invokeWithAllocator( comptime call: anytype, comptime info: std.builtin.Type.Fn, self_payload: *Payload, host_call: HostCall, utf8_allocator: ?std.mem.Allocator, ) anyerror!core.JSValue`。
- **作用**：按参数类型填 `ArgsTuple`，调用用户函数，把结果收成 JSValue。
- **实现**：inline 填每个 `callbackArg`；utf8 槽记入 `utf8_initialized` 以便 defer deinit。`@call(.auto, call, args_tuple)` → `resultToValue`。
- **所有权 / 错误 / 调用**：转换按形参顺序进行，任一转换失败则不调用宿主方法，已成功初始化的 Utf8 仍被释放；宿主返回错误或结果转换失败也走同一清理。只自动清理 Utf8 临时包装，不为所有参数类别创建独立所有权或持久根。错误沿 anyerror 进入 managed 映射。

### `JSObject.validateMethodSignature` (`src/binding/binding.zig:539`)

- **签名**：`fn validateMethodSignature(comptime info: std.builtin.Type.Fn) void`。
- **作用**：第一参数必须是 `*Payload`/`*const Payload`；其余参数必须是已知 kind。
- **实现**：空 params / 非 self / 未知类型 → compile error。
- **所有权 / 错误 / 调用**：MethodStub 与 callbackLength 共用；这里只验证参数类别，不校验返回值转换，也不要求 rest_values 位于最后、context/raw_call 只出现一次，后续 self 参数同样会按 self 类别接受。

### `JSObject.externalPayload` (`src/binding/binding.zig:549`)

- **签名**：`fn externalPayload(class_payload: *core.class.Payload) ?*Payload`。
- **作用**：从 class payload 槽取出 typed 指针。
- **实现**：空槽 null，否则 ptrCast。
- **所有权 / 错误 / 调用**：供 finalizer/mark 使用，只将非空槽转换成 Payload 指针，不检查实际类型、长度或存活状态；正确性依赖对应 class 的存储约定。

### `JSObject.callDeinit` (`src/binding/binding.zig:554`)

- **签名**：`fn callDeinit(data: *Payload) void`。
- **作用**：有 `.deinit` 就调用户钩子。
- **实现**：`hasField(..., "deinit")` 则 `spec.deinit(data)`。
- **所有权 / 错误 / 调用**：只调用显式提供的钩子，不反射查找 Payload.deinit，也不自动销毁嵌套资源。是否调用及是否另行释放 Payload 堆块由 payloadFinalizer 的存储分支决定；host-owned 分支不会调用此钩子。

### `JSObject.className` (`src/binding/binding.zig:560`)

- **签名**：`fn className() []const u8`。
- **作用**：class 表显示名。
- **实现**：有 `.name` 用它，否则 `@typeName(Payload)`。
- **所有权 / 错误 / 调用**：与 `classIdentity` 独立。

### `JSObject.needsPayloadFinalizer` (`src/binding/binding.zig:565`)

- **签名**：`fn needsPayloadFinalizer() bool`。
- **作用**：要不要登记 payload_finalizer。
- **实现**：inline 看有没有 `.deinit`；external js 恒 true；host false。
- **所有权 / 错误 / 调用**：installRuntime。

### `JSObject.hasTraceHook` (`src/binding/binding.zig:572`)

- **签名**：`fn hasTraceHook() bool`。
- **作用**：spec 是否声明 `.trace`。
- **实现**：`hasField(SpecType, "trace")`。
- **所有权 / 错误 / 调用**：仅按字段存在性决定是否登记 payload_mark，不验证 trace 是否覆盖全部 GC 边，也不自动推导 trace 实现。

### `JSObject.inlinePayloadSize` (`src/binding/binding.zig:576`)

- **签名**：`fn inlinePayloadSize() u32`。
- **作用**：inline 时告诉 class 表 payload 字节。
- **实现**：inline → `@sizeOf(Payload)`，external → 0。
- **所有权 / 错误 / 调用**：对象分配把 payload 放在 Object 体后。

### `JSObject.inlinePayloadAlign` (`src/binding/binding.zig:583`)

- **签名**：`fn inlinePayloadAlign() u16`。
- **作用**：inline 对齐；external 用 1。
- **实现**：`@alignOf(Payload)` 或 1。
- **所有权 / 错误 / 调用**：不分配、无 error set。唯一调用方 `src/binding/binding.zig:248`：把结果填进 `rt.classes.register` 的 `inline_payload_align`，GC 据此决定对象体内嵌 payload 的对齐；`external_ptr` 返回 1，表示类表里不预留内嵌空间（payload 由宿主或 JS 侧另行持有）。

### `JSObject.callbackLength` (`src/binding/binding.zig:607`)

- **签名**：`fn callbackLength(comptime call: anytype) i32`。
- **作用**：JS `length`：只数会消耗 JS 实参的参数（value/bool/int/float/string/bytes），不计 context/raw_call/rest/self。
- **实现**：扫 params[1..]。
- **所有权 / 错误 / 调用**：装到函数对象。

### `JSObject.callbackArg` (`src/binding/binding.zig:622`)

- **签名**：`fn callbackArg( comptime Param: type, self_payload: *Payload, host_call: HostCall, js_index: *usize, utf8_allocator: ?std.mem.Allocator, ) anyerror!Param`。
- **作用**：从 JS 实参窗口 marshal 一个 Zig 参数。
- **实现**：self → payload 指针；context → realm；raw_call → HostCall；rest_values → 剩余切片并耗尽 index；value 原样；bool/`asBool`；integer `asInt32` + `std.math.cast`（溢出 RangeError）；float 接受 f64 或 int32；string `JSString.fromValue`；utf8 `JSString.Utf8.fromValue(allocator, value)`；bytes `JSBytes.fromValue`；`[]const u8` 只读 slice；`[]u8` 要求非 shared 的 `sliceMut`，shared → TypeError。缺参 TypeError。
- **所有权 / 错误 / 调用**：不执行 JS 的 ToBoolean、ToNumber 或 ToString；整数参数只接受 int32 表示，即使 float64 表示的数值是整数也拒绝。context 参数借用 `*core.JSContext`。`[]const u8` 是二进制视图，不是字符串转换；它可以引用 shared 数据，const 不保证底层不变。bytes 参数不在这里建立 pin 或重入保护，回调若重入并 detach/resize 底层 buffer，借用指针可能在回调结束前失效；不得保存为长期引用。直接接收 `JSBytes` 也不经过 `[]u8` 分支的 shared 拒绝检查。

### `JSObject.nextValue` (`src/binding/binding.zig:685`)

- **签名**：`fn nextValue(args: []const core.JSValue, index: *usize) !core.JSValue`。
- **作用**：取下一个 JS 实参。
- **实现**：越界 TypeError 且不推进 index，否则取出并 `index.* += 1`；后续类型转换失败时，index 已推进。缺参不会补成 undefined。
- **所有权 / 错误 / 调用**：`callbackArg`。

### `JSObject.resultToValue` (`src/binding/binding.zig:692`)

- **签名**：`fn resultToValue(result: anytype) anyerror!core.JSValue`。
- **作用**：把 Zig 返回值收成 JSValue。
- **实现**：已是 JSValue 原样；void → undefined；error union 递归 `try`；bool/int/float box；其它 compile error。
- **所有权 / 错误 / 调用**：用户 `error.TypeError` 等在这里解开，交给 managed 调用入口映射。不会自动把字符串、指针或 optional 转成 JS 值，也不为原样返回的 JSValue 创建持久根。

### `JSObject.integerToValue` (`src/binding/binding.zig:705`)

- **签名**：`fn integerToValue(value: anytype) core.JSValue`。
- **作用**：整数能进 i32 则 int32，否则 float64。
- **实现**：先 `std.math.cast(i32, value)`，失败则 `@floatFromInt` 转成 f64。
- **所有权 / 错误 / 调用**：`resultToValue`；大整数可能丢失精度，不自动生成 BigInt。

### `JSObject.isSelfParam` (`src/binding/binding.zig:710`)

- **签名**：`fn isSelfParam(comptime Param: type) bool`。
- **作用**：是否单指针且 child 是 Payload。
- **实现**：`@typeInfo` pointer size==.one。
- **所有权 / 错误 / 调用**：不区分 const；const 在 `callbackParamKind` 里分。

### `JSObject.callbackParamKind` (`src/binding/binding.zig:717`)

- **签名**：`fn callbackParamKind(comptime Param: type) CallbackParamKind`。
- **作用**：参数类型 → 分类；未知 `@compileError`。
- **实现**：精确匹配 `*core.JSContext` / HostCall / JSValue / bool / JSString / Utf8 / JSBytes / `[]const u8` / `[]u8`；单指针 child==Payload → self_mut/self_const；const 的 JSValue slice → rest_values；int/float kind。这里的 context 不是公共 binding Context 包装。
- **所有权 / 错误 / 调用**：comptime，不分配、无运行期 error set；不认识的参数类型是 `@compileError`，所以没有运行期回退臂。三处调用方都在本文件：`:545` 只做早期形状校验（丢弃结果），`:613` 与 `:629` 是真正按 kind 生成 marshal 代码的分支。

### `JSObject.methodHasUtf8Param` (`src/binding/binding.zig:743`)

- **签名**：`fn methodHasUtf8Param(comptime info: std.builtin.Type.Fn) bool`。
- **作用**：是否需要 utf8 allocator。
- **实现**：任一参数是 `JSString.Utf8`。
- **所有权 / 错误 / 调用**：`invoke` 分支。

### `JSObject.callContext` (`src/binding/binding.zig:751`)

- **签名**：`fn callContext(host_call: HostCall) *core.JSContext`。
- **作用**：取出 realm 指针给 stackFallback 用。
- **实现**：`host_call.realm`。
- **所有权 / 错误 / 调用**：只读 `host_call.realm` 字段，不分配、不 retain、无 error set；返回的 `*core.JSContext` 是调用期内借用的。唯一调用方 `invoke`（`src/binding/binding.zig:502`），且只在方法带 `JSString.Utf8` 参数时走到——拿 realm 是为了取 `runtimePtr().memory.allocator` 给 `stackFallback(4096)`，该 arena 在 `invoke` 返回时随栈退出，不跨调用存活。

---

## 文件级 comptime 助手

### `specStorage` (`src/binding/binding.zig:763`)

- **签名**：`fn specStorage(comptime SpecType: type, comptime spec: SpecType) Storage`。
- **作用**：强制 spec 含 struct 字段 `.storage`；同名 declaration 不算字段。
- **实现**：有字段则读出，否则 compile error。
- **所有权 / 错误 / 调用**：`JSObject` 开头。

### `newArgType` (`src/binding/binding.zig:771`)

- **签名**：`fn newArgType(comptime Payload: type, comptime storage: Storage) type`。
- **作用**：`new` 的参数类型。
- **实现**：inline/js → Payload；host → `*Payload`。
- **所有权 / 错误 / 调用**：comptime 类型选择，不分配、无 error set。唯一调用方 `src/binding/binding.zig:111`（定义 `Arg`）。它编码的正是所有权分工：`inline_value` 与 `external_ptr{.owner=.js}` 取按值 `Payload`（引擎复制/接管，销毁由对象 teardown 负责），`external_ptr{.owner=.host}` 取 `*Payload`（引擎只存裸指针，宿主自己保证存活与释放）。

### `hasField` (`src/binding/binding.zig:781`)

- **签名**：`fn hasField(comptime T: type, comptime field_name: []const u8) bool`。
- **作用**：struct 是否有该字段。
- **实现**：inline 扫 fields。
- **所有权 / 错误 / 调用**：trace/deinit/name/storage/properties。

### `isStaticProperties` (`src/binding/binding.zig:790`)

- **签名**：`fn isStaticProperties(comptime T: type) bool`。
- **作用**：检查静态属性表的标记 declaration 是否存在。
- **实现**：仅 struct 使用 `@hasDecl(T, "zjs_binding_static_properties")`，其他类型返回 false。
- **所有权 / 错误 / 调用**：不验证标记值，也不验证类型确实来自 `Properties.Static`；即使标记为 false 仍命中。后续读取 `.entries` 时才要求该字段可用。

### `payloadRequiresTrace` (`src/binding/binding.zig:797`)

- **签名**：`fn payloadRequiresTrace(comptime Payload: type) bool`。
- **作用**：用有限的类型扫描判断是否强制提供 trace 钩子。
- **实现**：`typeRequiresTrace(Payload, 0)`。
- **所有权 / 错误 / 调用**：返回 true 且缺 `.trace` 则 compile error。返回 false 不是无 GC 引用的证明，实际引用仍由宿主正确追踪。

### `storageNeedsPayloadDeinit` (`src/binding/binding.zig:801`)

- **签名**：`fn storageNeedsPayloadDeinit(comptime storage: Storage) bool`。
- **作用**：JS 是否拥有 payload 寿命。
- **实现**：inline true；external.js true；host false。
- **所有权 / 错误 / 调用**：与 trace 一起决定是否强制 `.deinit`。

### `typeRequiresTrace` (`src/binding/binding.zig:808`)

- **签名**：`fn typeRequiresTrace(comptime T: type, comptime depth: u8) bool`。
- **作用**：有限扫描 optional、array、struct 和部分指针类型中的 GC 可见类型。
- **实现**：先检查当前类型是否直接 GC 可见，因此深度达到 6 时直接命中仍返回 true；否则深度 ≥6 返回 false。optional、array、struct 字段递归并增加深度；one/slice 指针只检查 child 是否直接 GC 可见，不递归扫描 child 的字段。
- **所有权 / 错误 / 调用**：comptime 启发式检查。指向含 JSValue 的 struct 的指针、这种 struct 的 slice、union，以及 many/C 指针等可能不命中；仍需按实际持有的引用实现 trace。

### `typeIsGcVisible` (`src/binding/binding.zig:826`)

- **签名**：`fn typeIsGcVisible(comptime T: type) bool`。
- **作用**：`JSValue` / `Object` / `JSValueHandle` / `WeakPersistentValue`。
- **实现**：类型相等。
- **所有权 / 错误 / 调用**：`*Object` 本身不是，但 `?*Object` 经 optional 递归会命中 `Object`。

---

## 测试钩子（清单里的私有函数）

这些不是公共 API，清单扫描到测试里的嵌套函数，仍按四段记下。

### `Hooks.trace` (`src/binding/binding.zig:876`)

- **签名**：`fn trace(payload: *Payload, visitor: *TraceVisitor) void`。
- **作用**：persistent-handle payload 测试的空 trace（真正根在 handle 里）。
- **实现**：忽略参数。
- **所有权 / 错误 / 调用**：强制声明 trace 因为 payload 含 `JSValueHandle`。

### `Hooks.deinit` (`src/binding/binding.zig:881`)

- **签名**：`fn deinit(payload: *Payload) void`。
- **作用**：`handle.deinit()` 并增加计数，证明 collection 时跑用户 deinit。
- **实现**：如上。
- **所有权 / 错误 / 调用**：对象死后 `drainDeferredClassPayloadFinalizers`。

### `Hooks.deinit` (`src/binding/binding.zig:930`)

- **签名**：`fn deinit(payload: *Payload) void`。
- **作用**：JS-owned u32 payload 的计数 finalizer。
- **实现**：`deinit_count.* += 1`。
- **所有权 / 错误 / 调用**：`runObjectCycleRemoval` 后断言 1。

### `Payload.touch` (`src/binding/binding.zig:1101`)

- **签名**：`fn touch(self: *@This()) i32`。
- **作用**：realm-local 方法品牌：A 的方法调 B 的 this 必须 TypeError。
- **实现**：`self.value += 1; return self.value;`
- **所有权 / 错误 / 调用**：经 `method("touch", ...)` 安装。

### `Payload.touch` (`src/binding/binding.zig:1145`)

- **签名**：`fn touch(self: *@This()) void`。
- **作用**：证明方法记录不额外 pin prototype。
- **实现**：忽略 self。
- **所有权 / 错误 / 调用**：install 前后 persistentRootCount 为 0。

### `Hooks.deinit` (`src/binding/binding.zig:1202`)

- **签名**：`fn deinit(payload: *Payload) void`。
- **作用**：inline payload 同步 finalizer 计数。
- **实现**：`deinit_count.* += 1`。
- **所有权 / 错误 / 调用**：inline 在对象析构内跑，无 defer 队列。

### `Hooks.trace` (`src/binding/binding.zig:1248`)

- **签名**：`fn trace(payload: *Payload, visitor: *TraceVisitor) void`。
- **作用**：inline 槽 `visitor.value(&payload.value_slot)`。
- **实现**：如上。
- **所有权 / 错误 / 调用**：`traceChildEdgesNoFail` 断言 visits==1。

### `Hooks.deinit` (`src/binding/binding.zig:1252`)

- **签名**：`fn deinit(payload: *Payload) void`。
- **作用**：把 inline 槽写成 undefined。
- **实现**：`payload.value_slot = undefinedValue()`。
- **所有权 / 错误 / 调用**：与 trace 配对。

### `Visitor.visitValue` (`src/binding/binding.zig:1278`)

- **签名**：`pub fn visitValue(self: *@This(), value_ptr: *core.JSValue) void`。
- **作用**：对象边访问器：指针等于 expected 则计数。
- **实现**：指针比较。
- **所有权 / 错误 / 调用**：`traceChildEdgesNoFail`。

### `Hooks.trace` (`src/binding/binding.zig:1293`)

- **签名**：`fn trace(payload: *Payload, visitor: *TraceVisitor) void`。
- **作用**：同时 mark value 槽与 object 槽。
- **实现**：`visitor.value` + `visitor.object`。
- **所有权 / 错误 / 调用**：`classes.markPayload`。

### `State.visitValue` (`src/binding/binding.zig:1321`)

- **签名**：`fn visitValue(context: *anyopaque, value_ptr: *anyopaque) void`。
- **作用**：core PayloadVisitor 的 value 回调。
- **实现**：ptrCast 到 State，比较槽指针。
- **所有权 / 错误 / 调用**：C 风格 visitor。

### `State.visitObject` (`src/binding/binding.zig:1327`)

- **签名**：`fn visitObject(context: *anyopaque, object_ptr: *anyopaque) void`。
- **作用**：object 槽回调。
- **实现**：同 visitValue。
- **所有权 / 错误 / 调用**：断言 object_visits==1。

### `Payload.add` (`src/binding/binding.zig:1352`)

- **签名**：`fn add(self: *@This(), amount: i32, enabled: bool) !i32`。
- **作用**：typed self + 参数；`enabled==false` → TypeError；length 应为 2。
- **实现**：`self.total += amount`。
- **所有权 / 错误 / 调用**：`callFunction` 传入 int32/bool。

### `Payload.runtimeCachedMethodName` (`src/binding/binding.zig:1397`)

- **签名**：`fn runtimeCachedMethodName(self: *@This()) void`。
- **作用**：静态属性名活在 runtime binding state：context destroy 后 atom 仍可解析，直到 `unregisterDynamic`。
- **实现**：空。
- **所有权 / 错误 / 调用**：方法名字符串等于 `"runtimeCachedMethodName"`。

### `Payload.mix` (`src/binding/binding.zig:1433`)

- **签名**：`fn mix(self: *@This(), label: JSString.Utf8, input: []const u8, output: []u8) !i32`。
- **作用**：utf8 借用 + 只读/可写字节切片；shared ArrayBuffer 作 output 必须 TypeError。
- **实现**：记下 label 长度/是否 borrowed，对 input 求和，`output[0]=input[1]`，返回 output.len。
- **所有权 / 错误 / 调用**：Utf8 在适配器里 deinit。

### `SharedState.deinit` (`src/binding/binding.zig:1447`)

- **签名**：`fn deinit(context: ?*anyopaque, bytes: []u8) void`。
- **作用**：shared store 的释放回调；测试断言共享失败路径不会调用它。
- **实现**：计数 + `allocator.free(bytes)`。
- **所有权 / 错误 / 调用**：`Bytes.Store.shared`。

### `Payload.narrow` (`src/binding/binding.zig:1539`)

- **签名**：`fn narrow(self: *@This(), amount: u8) i32`。
- **作用**：int32 300 不能进 u8 → RangeError（空 message）。
- **实现**：返回 amount。
- **所有权 / 错误 / 调用**：错误映射测试。

### `Payload.failCustom` (`src/binding/binding.zig:1544`)

- **签名**：`fn failCustom(self: *@This()) !void`。
- **作用**：未知 error 名 → `Error: BindingCustomFailure`。
- **实现**：`return error.BindingCustomFailure`。
- **所有权 / 错误 / 调用**：缝映射。

### `Payload.failType` (`src/binding/binding.zig:1549`)

- **签名**：`fn failType(self: *@This()) !void`。
- **作用**：`error.TypeError` → 空消息 TypeError。
- **实现**：`return error.TypeError`。
- **所有权 / 错误 / 调用**：引擎哨兵。

### `Payload.failSyntax` (`src/binding/binding.zig:1554`)

- **签名**：`fn failSyntax(self: *@This()) !void`。
- **作用**：`error.SyntaxError` → 空消息 SyntaxError。
- **实现**：`return error.SyntaxError`。
- **所有权 / 错误 / 调用**：同上。

### `objectProperty` (`src/binding/binding.zig:1608`)

- **签名**：`pub fn objectProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8) !core.JSValue`。
- **作用**：测试助手：intern 名再 getProperty。
- **实现**：`internAtom` + `object.getProperty`。
- **所有权 / 错误 / 调用**：错误映射测试取方法。

### `expectErrorObjectProperty` (`src/binding/binding.zig:1613`)

- **签名**：`fn expectErrorObjectProperty(ctx: *JSContext, value: core.JSValue, property_name: []const u8, expected: []const u8) !void`。
- **作用**：断言异常对象的 name/message。
- **实现**：`objectProperty` + `toOwnedUtf8` + `expectEqualStrings`。
- **所有权 / 错误 / 调用**：测试 allocator。

### `createTestRuntime` (`src/binding/binding.zig:1622`)

- **签名**：`fn createTestRuntime() !*core.JSRuntime`。
- **作用**：造已配置 standard globals 物化回调的测试 runtime。
- **实现**：`JSRuntime.create` + `configureRuntime` + 设置 `materialize_context_global_cb`。
- **所有权 / 错误 / 调用**：各 JSObject 测试。

### `binding.cb` (`src/binding/binding.zig:1626`)

- **签名**：`fn cb(c: *core.JSContext) anyerror!*core.Object`。
- **作用**：测试 runtime 的 global 物化：`zjs_vm.contextGlobal`。
- **实现**：try 该函数。
- **所有权 / 错误 / 调用**：与 `ensureStandardGlobalsRegistered` 的 cb 同形。
