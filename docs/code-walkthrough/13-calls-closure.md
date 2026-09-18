# 13 — `c_closure` 测试夹具

`closure.zig` **不是**字节码闭包构造（那在 core 函数表示与 VM 捕获）。这里是集合适配器与测试用的合成 `c_closure`：状态存在普通属性 `__closure_kind` / `__closure_value` / `__closure_b` / `__closure_c`。`call.zig` 在 `class_id == c_closure` 时转到 `callWithThis`。

`LogMode`：`initial` / `again`，控制 `appendLog` 是否写 `a=`。

---

### `create` (`src/exec/closure.zig:19`)

- **签名**：`pub fn create(rt: *core.JSRuntime, kind: i32, value: i32, b: i32, c: i32) !core.JSValue`。
- **作用**：造一个带四元组状态的 `c_closure` 对象。
- **实现**：`Object.create(c_closure)`；四个 `defineIntProperty`。失败 `destroyFromHeader`。
- **所有权 / 错误 / 调用**：返回拥有的对象值。调用方：`construct.zig:764` 的 `constructFunctionValue`（kind 13）、本文件的 `iteratorFactory`（`closure.zig:300`/`309` 造 next/return）与 `iteratorNextValueGetterThrows`（`337` 造 kind 12 的抛错 getter），以及测试树多处。

### `call` (`src/exec/closure.zig:29`)

- **签名**：`pub fn call(rt: *core.JSRuntime, closure_value: core.JSValue, args: []const core.JSValue, globals: []globals_mod.Slot) !core.JSValue`。
- **作用**：无 this 调用。
- **实现**：`callWithThis(..., undefined, ...)`。
- **所有权 / 错误 / 调用**：纯转发：不分配、不建根，`args`/`globals` 都是借用的切片。error set 与 `callWithThis` 相同（未知 kind → `error.TypeError`，其余为分配错误），不在这里变成 JS 异常。引擎代码里唯一调用方是 `src/exec/construct.zig:996`（取集合 adder 时调 accessor getter）；此外 `src/tests/` 下的单测直接用它驱动夹具。

### `callWithThis` (`src/exec/closure.zig:33`)

- **签名**：`pub fn callWithThis(rt: *core.JSRuntime, closure_value: core.JSValue, this_value: core.JSValue, args: []const core.JSValue, globals: []globals_mod.Slot) !core.JSValue`。
- **作用**：按 `__closure_kind` 分发夹具行为。
- **实现**：大 switch。代表项：1 返回捕获 int；2 自增；3 捕获+arg；5 记 log；6 乘法；7–12 各种 error；13/14 undefined/null；15 字符串长度；16 even/odd；17 回显 arg0；19/30/40 等改 globals 计数/数组；41–45/52 iterator next 变体；46 iterator 工厂；47 WeakMap adder 记录；49 断言 expects 队列；56–58 Set forEach 变异；其余 `TypeError`。
- **所有权 / 错误 / 调用**：args/globals 借用。堆字符串/数组新建则拥有。`error.JSException` 表示测试期望的突然完成。

### `closureKind` (`src/exec/closure.zig:242`)

- **签名**：`fn closureKind(rt: *core.JSRuntime, closure_value: core.JSValue) !i32`。
- **作用**：读 `__closure_kind`。
- **实现**：`expectClosure` + `getIntProperty`。
- **所有权 / 错误 / 调用**：只读，不分配；`expectClosure` 的 `TypeError` 与 `getIntProperty` 的非 int32 `TypeError` 原样上抛。唯一调用方是本文件的 `callWithThis`（`closure.zig:35`）。

### `appendLog` (`src/exec/closure.zig:247`)

- **签名**：`pub fn appendLog(rt: *core.JSRuntime, globals: []globals_mod.Slot, mode: LogMode, a: i32, b: i32, c: i32, d: i32) !void`。
- **作用**：把 `a=/b=/c=/d=/x=10` 拼进全局 `log_str`。
- **实现**：已有 string 先 append；`initial` 才写 `a=`。写回 `setExistingByName`。
- **所有权 / 错误 / 调用**：临时 ArrayList。

### `expectClosure` (`src/exec/closure.zig:262`)

- **签名**：`fn expectClosure(value: core.JSValue) !*core.Object`。
- **作用**：断言 `c_closure` 对象。
- **实现**：非 object / 错 class → `TypeError`。
- **所有权 / 错误 / 调用**：返回借用的 `*Object`（值仍由调用方的 JSValue 持有），不 retain、不建根。非对象或 class 不是 `c_closure` 一律 `error.TypeError`。调用方是本文件的 `callWithThis`（`closure.zig:34`）与 `closureKind`（`243`）。

### `defineIntProperty` (`src/exec/closure.zig:270`)

- **签名**：`fn defineIntProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: i32) !void`。
- **作用**：intern 名后定义可写数据属性。
- **实现**：`Descriptor.data(int32, true, true, true)`。
- **所有权 / 错误 / 调用**：`rt.internAtom` 得到的 atom 由 `AtomTable` 持有，调用方不负责释放；写入的是立即 int32，没有可被 GC 移动的值，因此不需要根帧（对照 `defineValueProperty` 就要建根）。error set 为分配错误。调用方是本文件的 `create`（四处，`closure.zig:22`-`25`）、`callWithThis` 的状态更新臂（`44`）、`iteratorNextDoneIfConsumed` 的一次性标记（`347`）与两个集合 size 写回函数（`776`、`809`）。

### `getIntProperty` (`src/exec/closure.zig:275`)

- **签名**：`fn getIntProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8) !i32`。
- **作用**：读 int 属性。
- **实现**：非 int32 → `TypeError`。
- **所有权 / 错误 / 调用**：只读，intern 的 atom 归 `AtomTable`；返回立即数不涉及所有权。非 int32 → `error.TypeError`，属性读错误（`PropertyReadError`）上抛。调用方全在本文件的 `callWithThis` 各 kind 臂与 `closureKind`。

### `incrementGlobalInt` (`src/exec/closure.zig:281`)

- **签名**：`fn incrementGlobalInt(rt: *core.JSRuntime, globals: []globals_mod.Slot, name: []const u8) !void`。
- **作用**：全局槽 int +1。
- **实现**：`getByName` / `setExistingByName`。
- **所有权 / 错误 / 调用**：`globals` 是调用方借来的槽数组，函数只改槽内立即数，不分配、不建根。槽不存在或不是 int32 → `error.TypeError`（`getByName`/`setExistingByName` 的错误也一并上抛）。调用方是本文件 `callWithThis` 里的计数类 kind（`closure.zig:97`、`104`、`110` 等 10 处）。

### `iteratorFactory` (`src/exec/closure.zig:287`)

- **签名**：`fn iteratorFactory(rt: *core.JSRuntime, shape: i32) !core.JSValue`。
- **作用**：按 shape 造带 `next`/`return` 的 iterator 对象。
- **实现**：shape 1–6/8 选 next kind（41–45/52）；3–6/8 装 `return`（40 或 7=TypeError）。
- **所有权 / 错误 / 调用**：kind 46。

### `iteratorNextGlobalValue` (`src/exec/closure.zig:316`)

- **签名**：`fn iteratorNextGlobalValue(rt: *core.JSRuntime, closure: *core.Object, globals: []globals_mod.Slot, name: []const u8) !core.JSValue`。
- **作用**：第一次 next 吐全局槽，第二次 done。
- **实现**：`iteratorNextDoneIfConsumed` 后 `iteratorResult(globals[name], false)`。
- **所有权 / 错误 / 调用**：kind 43/44。

### `iteratorNextEmptyArray` (`src/exec/closure.zig:322`)

- **签名**：`fn iteratorNextEmptyArray(rt: *core.JSRuntime, closure: *core.Object) !core.JSValue`。
- **作用**：吐一个空数组。
- **实现**：同上，value 是新 Array。
- **所有权 / 错误 / 调用**：kind 45。

### `iteratorNextNull` (`src/exec/closure.zig:328`)

- **签名**：`fn iteratorNextNull(rt: *core.JSRuntime, closure: *core.Object) !core.JSValue`。
- **作用**：吐 null。
- **实现**：`iteratorResult(null, false)`。
- **所有权 / 错误 / 调用**：kind 52。

### `iteratorNextValueGetterThrows` (`src/exec/closure.zig:333`)

- **签名**：`fn iteratorNextValueGetterThrows(rt: *core.JSRuntime, closure: *core.Object) !core.JSValue`。
- **作用**：结果对象的 `value` 是会抛的 getter（kind 12）。
- **实现**：accessor 描述符 + `done=false`。
- **所有权 / 错误 / 调用**：kind 42。

### `iteratorNextDoneIfConsumed` (`src/exec/closure.zig:344`)

- **签名**：`fn iteratorNextDoneIfConsumed(rt: *core.JSRuntime, closure: *core.Object) !?core.JSValue`。
- **作用**：一次性 next：`__closure_value!=0` 则 `{done:true}`。
- **实现**：首次把 value 置 1 返回 null（继续吐元素）。
- **所有权 / 错误 / 调用**：各 next 变体。

### `iteratorResult` (`src/exec/closure.zig:355`)

- **签名**：`fn iteratorResult(rt: *core.JSRuntime, value: core.JSValue, done: bool) !core.JSValue`。
- **作用**：`CreateIterResultObject` 借用包装；调用方保留 `value` 引用。无 realm，结果无原型。
- **实现**：`iterator_ops.createIteratorResult(rt, null, value, done)`。
- **所有权 / 错误 / 调用**：文件内测试证明 FB 值在创建期间被 root。

### `createTestFunctionBytecodeValue` (`src/exec/closure.zig:396`)

- **签名**：`fn createTestFunctionBytecodeValue(rt: *core.JSRuntime, symbol_name: []const u8) !TestFunctionBytecodeValue`。
- **作用**：带 cpool 符号的 unpublished→published FB 夹具，用于 GC 根测试。
- **实现**：`createFixture` + `newValueSymbol` + `publishFixtureNoFail`。
- **所有权 / 错误 / 调用**：测试夹具：`errdefer if (!fb_published) fb.destroyUnpublishedFixture(rt)` 只保护发布前的窗口，发布后 FB 归运行时，由 `rt.destroy()` 回收；`takeSymbolValue` 把新符号的引用转进 cpool 槽，返回结构里的 `symbol_atom` 只是给测试拿来查存活的 id，不再是一份所有权。调用方是本文件两个 GC 根测试（`closure.zig:432`-`434`、`470`-`472`）。

### `expectObjectPropertySame` (`src/exec/closure.zig:411`)

- **签名**：`fn expectObjectPropertySame(rt: *core.JSRuntime, object: *core.Object, name: []const u8, expected: core.JSValue) !void`。
- **作用**：断言自有属性 `same`。
- **实现**：testing.expect。
- **所有权 / 错误 / 调用**：测试。

### `expectArrayIndexSame` (`src/exec/closure.zig:417`)

- **签名**：`fn expectArrayIndexSame(_: *core.JSRuntime, array: *core.Object, index: u32, expected: core.JSValue) !void`。
- **作用**：断言数组下标 `same`。
- **实现**：`atomFromUInt32`。
- **所有权 / 错误 / 调用**：测试。

### `arrayFromShape` (`src/exec/closure.zig:578`)

- **签名**：`fn arrayFromShape(rt: *core.JSRuntime, shape: i32) !core.JSValue`。
- **作用**：按整数 shape 造固定内容数组（0 空、1 `[1]`、23 `[2,3]`、101 `["a","b"]` 等）。
- **实现**：switch + `appendArrayValue`。未知 shape `TypeError`。
- **所有权 / 错误 / 调用**：kind 53。

### `appendArrayValue` (`src/exec/closure.zig:629`)

- **签名**：`fn appendArrayValue(rt: *core.JSRuntime, array: *core.Object, value: core.JSValue) !void`。
- **作用**：在 `arrayLength()` 处定义数据属性。
- **实现**：先 `rootValues` 再 define。非 array `TypeError`。
- **所有权 / 错误 / 调用**：分配点前必须 root。

### `setGlobalMapString` (`src/exec/closure.zig:639`)

- **签名**：`fn setGlobalMapString(rt: *core.JSRuntime, globals: []globals_mod.Slot, key_int: i32, bytes: []const u8) !void`。
- **作用**：改全局 `map` 里 int 键的字符串值。
- **实现**：WeakMap 转 `setGlobalWeakMapString`；Map 扫 entries 或 `appendUnindexedCollectionEntryAndDefineSize`。
- **所有权 / 错误 / 调用**：kind 38/39。

### `setGlobalWeakMapString` (`src/exec/closure.zig:657`)

- **签名**：`fn setGlobalWeakMapString(rt: *core.JSRuntime, globals: []globals_mod.Slot, map_object: *core.Object, key_int: i32, bytes: []const u8) !void`。
- **作用**：WeakMap 键来自全局 `obj{N}`。
- **实现**：`collection.setWeakMapEntry`。
- **所有权 / 错误 / 调用**：新建的字符串值所有权交给 `collection.setWeakMapEntry`（进 WeakMap 条目）；键值从全局槽或 `globalThis` 借来，不 retain。`key_name_buf` 是栈上 32 字节，`bufPrint` 用 `catch unreachable`（`obj{d}` 不可能溢出）。error set 为分配/属性读错误。唯一调用方是本文件 `setGlobalMapString` 的 WeakMap 分支（`closure.zig:642`）。

### `appendRecordToGlobalArray` (`src/exec/closure.zig:668`)

- **签名**：`fn appendRecordToGlobalArray(rt: *core.JSRuntime, globals: []globals_mod.Slot, name: []const u8, value: core.JSValue, key: core.JSValue, this_arg: core.JSValue) !void`。
- **作用**：造 `{value,key,thisArg}` 推进全局数组。
- **实现**：三值 root；this 为 undefined 则省略 thisArg。
- **所有权 / 错误 / 调用**：kind 21/23–25。测试覆盖 FB 字段根。

### `appendWeakMapAdderRecord` (`src/exec/closure.zig:684`)

- **签名**：`fn appendWeakMapAdderRecord(rt: *core.JSRuntime, globals: []globals_mod.Slot, key: core.JSValue, value: core.JSValue, this_arg: core.JSValue) !void`。
- **作用**：`{_this,key,value}` 记入 `results`。
- **实现**：同样三值 root。
- **所有权 / 错误 / 调用**：kind 47。

### `assertAndShiftExpected` (`src/exec/closure.zig:700`)

- **签名**：`fn assertAndShiftExpected(rt: *core.JSRuntime, globals: []globals_mod.Slot, actual: core.JSValue) !void`。
- **作用**：对照全局 `expects` 数组头并左移。
- **实现**：`sameValue` 失败 `JSException`；`truncateArrayElements` 再降 length，避免 `array_length < array_count`。
- **所有权 / 错误 / 调用**：kind 49 与 forEach 变异。

### `setForEachMutation` (`src/exec/closure.zig:725`)

- **签名**：`fn setForEachMutation(rt: *core.JSRuntime, globals: []globals_mod.Slot, args: []const core.JSValue, mode: SetForEachMutation) !core.JSValue`。
- **作用**：Set.forEach 回调里按模式增删。
- **实现**：先 `assertAndShiftExpected`；`add_after_begin` / `delete_then_readd` / `revisit_after_readd`。
- **所有权 / 错误 / 调用**：kind 56–58。args[2] 必须是 Set。

### `setAddInt` (`src/exec/closure.zig:748`)

- **签名**：`fn setAddInt(rt: *core.JSRuntime, set: *core.Object, value: i32) !void`。
- **作用**：若无则追加 int 条目。
- **实现**：扫 active entries。
- **所有权 / 错误 / 调用**：直接改集合 payload（`collectionEntriesSlot`）并由 `appendUnindexedCollectionEntryAndDefineSize` 负责 size 属性与失败回滚；本函数自己不分配、不建根（键是立即 int32）。调用方是本文件集合变异测试的 kind 臂（`closure.zig:733`、`734`、`738`、`742`）。

### `setDeleteInt` (`src/exec/closure.zig:756`)

- **签名**：`fn setDeleteInt(rt: *core.JSRuntime, set: *core.Object, value: i32) !void`。
- **作用**：按 int 键删除。
- **实现**：`removeUnindexedCollectionEntryAndDefineSize`。
- **所有权 / 错误 / 调用**：不分配；命中即转 `removeUnindexedCollectionEntryAndDefineSize`（那里带 errdefer 回滚），未命中静默返回。调用方是本文件的两处变异臂（`closure.zig:737`、`741`）。

### `appendUnindexedCollectionEntryAndDefineSize` (`src/exec/closure.zig:766`)

- **签名**：`fn appendUnindexedCollectionEntryAndDefineSize(rt: *core.JSRuntime, object: *core.Object, entry: core.object.CollectionEntry) !void`。
- **作用**：追加未建索引的 collection 条目并更新 `size`。
- **实现**：`appendCollectionEntryUnindexed`；失败 `rollbackLastUnindexedCollectionEntry`；清 index。
- **所有权 / 错误 / 调用**：defineIntProperty 失败回滚。

### `rollbackLastUnindexedCollectionEntry` (`src/exec/closure.zig:780`)

- **签名**：`fn rollbackLastUnindexedCollectionEntry(object: *core.Object, index: usize) void`。
- **作用**：截掉刚追加的尾条目。
- **实现**：断言 `index+1==len`；置 inactive；缩 slice；active_count--。
- **所有权 / 错误 / 调用**：errdefer。

### `removeUnindexedCollectionEntryAndDefineSize` (`src/exec/closure.zig:790`)

- **签名**：`fn removeUnindexedCollectionEntryAndDefineSize(rt: *core.JSRuntime, object: *core.Object, index: usize) !void`。
- **作用**：删条目并写 size；失败恢复。
- **实现**：先摘下再 `defineIntProperty`；errdefer 写回。
- **所有权 / 错误 / 调用**：就地把条目置空并递减 active 计数；`errdefer` 在 `defineIntProperty` 写 `size` 失败时把 `removed` 原样写回、恢复旧计数并再次 `clearCollectionIndex`，所以失败后集合仍自洽。不分配新对象（被清掉的 key/value 引用随槽一起丢弃）。唯一调用方 `setDeleteInt`（`closure.zig:760`）。

### `appendPairToGlobalArray` (`src/exec/closure.zig:813`)

- **签名**：`fn appendPairToGlobalArray(rt: *core.JSRuntime, globals: []globals_mod.Slot, name: []const u8, key: core.JSValue, value: core.JSValue) !void`。
- **作用**：`[key,value]` 推进全局数组。
- **实现**：两值 root。
- **所有权 / 错误 / 调用**：kind 30。

### `appendToGlobalArray` (`src/exec/closure.zig:827`)

- **签名**：`fn appendToGlobalArray(rt: *core.JSRuntime, globals: []globals_mod.Slot, name: []const u8, value: core.JSValue) !void`。
- **作用**：向全局数组追加。
- **实现**：槽 undefined 则从 `globalThis` 取属性。
- **所有权 / 错误 / 调用**：value 先 root。

### `getGlobalObjectProperty` (`src/exec/closure.zig:841`)

- **签名**：`fn getGlobalObjectProperty(rt: *core.JSRuntime, globals: []globals_mod.Slot, name: []const u8) !core.JSValue`。
- **作用**：`globalThis[name]`。
- **实现**：`getGlobalThisObject` + intern + getProperty。
- **所有权 / 错误 / 调用**：返回的是属性槽里的值，按借用处理（不 retain），调用方要么立刻用掉要么自己建根。intern 的 atom 归 `AtomTable`。error set：`getGlobalThisObject` 的 `TypeError` + 分配/属性读错误。调用方 `setGlobalWeakMapString`（`closure.zig:662`）与 `appendToGlobalArray`（`835`）。

### `getGlobalThisObject` (`src/exec/closure.zig:847`)

- **签名**：`fn getGlobalThisObject(rt: *core.JSRuntime, globals: []globals_mod.Slot) !*core.Object`。
- **作用**：从槽取 `globalThis` 对象。
- **实现**：非 object `TypeError`。
- **所有权 / 错误 / 调用**：返回借用的 `*Object`（由全局槽持有），不 retain、不建根。槽里不是对象 → `error.TypeError`。调用方是本文件 `callWithThis` 的 globalThis 臂（`closure.zig:223`）与 `getGlobalObjectProperty`（`842`）。

### `defineValueProperty` (`src/exec/closure.zig:854`)

- **签名**：`fn defineValueProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void`。
- **作用**：可写数据属性；定义前 root value。
- **实现**：intern + defineOwnProperty。
- **所有权 / 错误 / 调用**：与 `defineIntProperty` 的差别就在所有权：`value` 可能是堆值，先复制到 `rooted_value` 并用 `core.runtime.rootValues` 建 `ValueRootFrame`、`activate`/`defer deactivate`，因为随后的 `internAtom` 与 `defineOwnProperty` 都可能分配并触发 GC。属性表拿走一份引用，调用方原值仍由自己负责。调用方全在本文件：迭代器夹具（`closure.zig:301`、`310`、`340`）与记录构造（`678`-`680`、`694`-`696`）共 9 处。

### `appendIntField` (`src/exec/closure.zig:866`)

- **签名**：`fn appendIntField(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), label: []const u8, value: i32) !void`。
- **作用**：`label{d},` 追加到 log buffer。
- **实现**：`bufPrint` + `appendSlice`。
- **所有权 / 错误 / 调用**：`appendLog`。

## 覆盖核对

- 清单函数数: 38
- 未覆盖: 无
