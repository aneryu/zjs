# 13 — `c_closure` 测试夹具

`closure.zig` **不是**字节码闭包构造（那在 core 函数表示与 VM 捕获）。这里是集合适配器与测试用的合成 `c_closure`：状态存在普通属性 `__closure_kind` / `__closure_value` / `__closure_b` / `__closure_c`。`call.zig` 在 `class_id == c_closure` 时转到 `callWithThis`。

`LogMode`：`initial` / `again`，控制 `appendLog` 是否写 `a=`。

---

### `create` (`src/exec/closure.zig:32`)

- **签名**：`pub fn create(rt: *core.JSRuntime, kind: i32, value: i32, b: i32, c: i32) !core.JSValue`。
- **作用**：造一个带四元组状态的 `c_closure` 对象。
- **实现**：`Object.create(c_closure)`；四个 `defineIntProperty`。失败 `destroyFromHeader`。
- **所有权 / 错误 / 调用**：返回拥有的对象值。调用方：`construct.zig:764` 的 `constructFunctionValue`（kind 13）、本文件的 `iteratorFactory`（`closure.zig:300`/`309` 造 next/return）与 `iteratorNextValueGetterThrows`（`337` 造 kind 12 的抛错 getter），以及测试树多处。

### `call` (`src/exec/closure.zig:40`)

- **签名**：`pub fn call(rt: *core.JSRuntime, closure_value: core.JSValue, args: []const core.JSValue, globals: []globals_mod.Slot) !core.JSValue`。
- **作用**：无 this 调用。
- **实现**：`callWithThis(..., undefined, ...)`。
- **所有权 / 错误 / 调用**：纯转发：不分配、不建根，`args`/`globals` 都是借用的切片。error set 与 `callWithThis` 相同（未知 kind → `error.TypeError`，其余为分配错误），不在这里变成 JS 异常。引擎代码里唯一调用方是 `src/exec/construct.zig:996`（取集合 adder 时调 accessor getter）；此外 `src/tests/` 下的单测直接用它驱动夹具。

### `callWithThis` (`src/exec/closure.zig:44`)

- **签名**：`pub fn callWithThis(rt: *core.JSRuntime, closure_value: core.JSValue, this_value: core.JSValue, args: []const core.JSValue, globals: []globals_mod.Slot) !core.JSValue`。
- **作用**：按 `__closure_kind` 分发夹具行为。
- **实现**：大 switch。代表项：1 返回捕获 int；2 自增；3 捕获+arg；5 记 log；6 乘法；7–12 各种 error；13/14 undefined/null；15 字符串长度；16 even/odd；17 回显 arg0；19/30/40 等改 globals 计数/数组；41–45/52 iterator next 变体；46 iterator 工厂；47 WeakMap adder 记录；49 断言 expects 队列；56–58 Set forEach 变异；其余 `TypeError`。
- **所有权 / 错误 / 调用**：args/globals 借用。堆字符串/数组新建则拥有。`error.JSException` 表示测试期望的突然完成。



### `expectClosure` (`src/exec/closure.zig:73`)

- **签名**：`fn expectClosure(value: core.JSValue) !*core.Object`。
- **作用**：断言 `c_closure` 对象。
- **实现**：非 object / 错 class → `TypeError`。
- **所有权 / 错误 / 调用**：返回借用的 `*Object`（值仍由调用方的 JSValue 持有），不 retain、不建根。非对象或 class 不是 `c_closure` 一律 `error.TypeError`。调用方是本文件的 `callWithThis`（`closure.zig:34`）与 `closureKind`（`243`）。

### `defineIntProperty` (`src/exec/closure.zig:81`)

- **签名**：`fn defineIntProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: i32) !void`。
- **作用**：intern 名后定义可写数据属性。
- **实现**：`Descriptor.data(int32, true, true, true)`。
- **所有权 / 错误 / 调用**：`rt.internAtom` 得到的 atom 由 `AtomTable` 持有，调用方不负责释放；写入的是立即 int32，没有可被 GC 移动的值，因此不需要根帧（对照 `defineValueProperty` 就要建根）。error set 为分配错误。调用方是本文件的 `create`（四处，`closure.zig:22`-`25`）、`callWithThis` 的状态更新臂（`44`）、`iteratorNextDoneIfConsumed` 的一次性标记（`347`）与两个集合 size 写回函数（`776`、`809`）。

### `getIntProperty` (`src/exec/closure.zig:86`)

- **签名**：`fn getIntProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8) !i32`。
- **作用**：读 int 属性。
- **实现**：非 int32 → `TypeError`。
- **所有权 / 错误 / 调用**：只读，intern 的 atom 归 `AtomTable`；返回立即数不涉及所有权。非 int32 → `error.TypeError`，属性读错误（`PropertyReadError`）上抛。调用方全在本文件的 `callWithThis` 各 kind 臂与 `closureKind`。














### `setGlobalMapString` (`src/exec/closure.zig:92`)

- **签名**：`fn setGlobalMapString(rt: *core.JSRuntime, globals: []globals_mod.Slot, key_int: i32, bytes: []const u8) !void`。
- **作用**：改全局 `map` 里 int 键的字符串值。
- **实现**：WeakMap 转 `setGlobalWeakMapString`；Map 扫 entries 或 `appendUnindexedCollectionEntryAndDefineSize`。
- **所有权 / 错误 / 调用**：kind 38/39。

### `setGlobalWeakMapString` (`src/exec/closure.zig:110`)

- **签名**：`fn setGlobalWeakMapString(rt: *core.JSRuntime, globals: []globals_mod.Slot, map_object: *core.Object, key_int: i32, bytes: []const u8) !void`。
- **作用**：WeakMap 键来自全局 `obj{N}`。
- **实现**：`collection.setWeakMapEntry`。
- **所有权 / 错误 / 调用**：新建的字符串值所有权交给 `collection.setWeakMapEntry`（进 WeakMap 条目）；键值从全局槽或 `globalThis` 借来，不 retain。`key_name_buf` 是栈上 32 字节，`bufPrint` 用 `catch unreachable`（`obj{d}` 不可能溢出）。error set 为分配/属性读错误。唯一调用方是本文件 `setGlobalMapString` 的 WeakMap 分支（`closure.zig:642`）。







### `appendUnindexedCollectionEntryAndDefineSize` (`src/exec/closure.zig:134`)

- **签名**：`fn appendUnindexedCollectionEntryAndDefineSize(rt: *core.JSRuntime, object: *core.Object, entry: core.object.CollectionEntry) !void`。
- **作用**：追加未建索引的 collection 条目并更新 `size`。
- **实现**：`appendCollectionEntryUnindexed`；失败 `rollbackLastUnindexedCollectionEntry`；清 index。
- **所有权 / 错误 / 调用**：defineIntProperty 失败回滚。

### `rollbackLastUnindexedCollectionEntry` (`src/exec/closure.zig:148`)

- **签名**：`fn rollbackLastUnindexedCollectionEntry(object: *core.Object, index: usize) void`。
- **作用**：截掉刚追加的尾条目。
- **实现**：断言 `index+1==len`；置 inactive；缩 slice；active_count--。
- **所有权 / 错误 / 调用**：errdefer。




### `getGlobalObjectProperty` (`src/exec/closure.zig:121`)

- **签名**：`fn getGlobalObjectProperty(rt: *core.JSRuntime, globals: []globals_mod.Slot, name: []const u8) !core.JSValue`。
- **作用**：`globalThis[name]`。
- **实现**：`getGlobalThisObject` + intern + getProperty。
- **所有权 / 错误 / 调用**：返回的是属性槽里的值，按借用处理（不 retain），调用方要么立刻用掉要么自己建根。intern 的 atom 归 `AtomTable`。error set：`getGlobalThisObject` 的 `TypeError` + 分配/属性读错误。调用方 `setGlobalWeakMapString`（`closure.zig:662`）与 `appendToGlobalArray`（`835`）。

### `getGlobalThisObject` (`src/exec/closure.zig:127`)

- **签名**：`fn getGlobalThisObject(rt: *core.JSRuntime, globals: []globals_mod.Slot) !*core.Object`。
- **作用**：从槽取 `globalThis` 对象。
- **实现**：非 object `TypeError`。
- **所有权 / 错误 / 调用**：返回借用的 `*Object`（由全局槽持有），不 retain、不建根。槽里不是对象 → `error.TypeError`。调用方是本文件 `callWithThis` 的 globalThis 臂（`closure.zig:223`）与 `getGlobalObjectProperty`（`842`）。



## 覆盖核对

- 清单函数数: 38
- 未覆盖: 无
