# 17 — JSON / Date / Math / Number

JSON.parse 有简单 ASCII 快路径与忠实 WTF-16 下降；有 reviver 时并行建 parse-record。Date setter 先抓 `[[DateValue]]` 再 coerce 参数。Math 叶子 cproto 走无环境 f64 调用，miss 才 ToNumber。Number.prototype 格式化走 dtoa。



## `src/exec/json_ops.zig` — JSON.parse / stringify

对照 `js_json_obj` / `JS_ParseJSON` / `js_json_stringify`。记录表四条：isRawJSON、parse、rawJSON、stringify。

parse：无 reviver 可走 ASCII `SimpleJsonParser`；否则 `JsonUnitParser` 按 **代码单元**（WTF-16）递归下降，与 qjs 一样允许字符串里的孤立代理项。有 reviver 时并行建 `JsonParseRecord` 树（`context.source`、first-key-wins）。深度受 native stack guard。

stringify：replacer/gap/propertyList；循环检测 `objectInStack`；简单无选项路径可走 `jsonStringifySimpleNoOptions`。

### 类型

- `JsonParseRecord`：primitive/array/object 联合；primitive 缓存源文本 span。
- `JsonRecordRoots` / `JsonPendingRecordRoots`：native 树上的 atom/JSValue 根（TGC S3）。
- `JsonUnitParser(T)` / `SimpleJsonParser`：两套解析器。
- `StringifyOptions` / `JsonStringifyVmOptions`。


### `jsonEntry` (`src/exec/json_ops.zig:65`)

- **签名**：`fn jsonEntry( comptime name: []const u8, comptime length: u8, comptime id: u32, comptime handler: anytype, ) core.host_function.InternalEntry`。
- **作用**：为 `internal_entries` 里的一条 `JSON.*` 方法生成声明表项；`isRawJSON`/`parse`/`rawJSON`/`stringify` 四条都由它拼出。
- **实现**：填 `InternalEntry` 的 `name`/`length`/`id`，`cproto` 固定为 `.generic_magic`，`native_function` 由 `builtin_dispatch.genericMagicFunction(handler)` 包出。
- **所有权 / 错误 / 调用**：全 comptime 求值，不分配；只被 `internal_entries` 这张声明表使用。

### `jsonIsRawJsonCall` (`src/exec/json_ops.zig:80`)

- **签名**：`fn jsonIsRawJsonCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`JSON.isRawJSON` 的 NativeEntry 处理函数：判断第一个参数是不是 `JSON.rawJSON` 造出的 raw_json 对象。
- **实现**：先 `nativeCall` 恢复 `NativeCall`；失败则 `error.TypeError`。随后直接返回 `core.JSValue.boolean(args.len >= 1 and isRawJSON(args[0]))`：不读 magic，也不取 realm。
- **所有权 / 错误 / 调用**：不分配、不取 realm、不回调 JS：只看参数的 class id，返回立即数布尔。`HostError` 里实际会用到的只有 `nativeCall` 返回 null 时那条裸 `error.TypeError`（记录被当成别的调用形状使用），由上层 `materializeRuntimeError` 补 JS 异常。没有具名调用方：`internal_entries` 的 `isRawJSON` 那条用 `genericMagicFunction(&jsonIsRawJsonCall)` 指向它。

### `jsonRawJsonCall` (`src/exec/json_ops.zig:90`)

- **签名**：`fn jsonRawJsonCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`JSON.rawJSON` 的 NativeEntry 处理函数：把参数文本包成密封的 raw_json 对象。
- **实现**：先 `nativeCall` 恢复 `NativeCall`；失败则 `error.TypeError`。可观察调用再取 `callableRealm`，断言 realm 与 ctx 一致。非字符串参数先经 `string_ops.toStringForAnnexB` 转成字符串，再交给 `rawJSON`；后者的 `error.SyntaxError` 就地转成 `exception_ops.throwSyntaxErrorMessage(..., "invalid rawJSON string")`，其余 error 原样上抛。 关键调用：`builtin_dispatch.callableRealm`、`string_ops.toStringForAnnexB`、`rawJSON`。
- **所有权 / 错误 / 调用**：`args` 借用；非字符串参数经 `toStringForAnnexB` 得到的是新建字符串（`owned_input` 只是本地句柄，交给 GC 管理、不手工释放），返回的 raw_json 对象同样是 owned、归调用方。错误：`nativeCall` 失败是裸 `error.TypeError`；`rawJSON` 的 `error.SyntaxError` 就地 `throwSyntaxErrorMessage` 挂上「invalid rawJSON string」再返回 error，其余 error 原样上传；`callableRealm` 与 `toStringForAnnexB` 抛出时异常已挂好。没有具名调用方，只作为 `rawJSON` 记录的 handler。

### `jsonParseRecordCall` (`src/exec/json_ops.zig:112`)

- **签名**：`fn jsonParseRecordCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`JSON.parse` 的 NativeEntry 处理函数：定出 realm/global 后转给 `jsonParseCall`。
- **实现**：先 `nativeCall` 恢复 `NativeCall`；失败则 `error.TypeError`。有 `callable_realm` 时用它的 global（断言 realm 与 ctx 一致）；没有时只允许模块加载器那种没有 C 函数载体的合成复用——`func_obj != null` 或 `global == null` 都返回 `error.InvalidBuiltinRegistry`。 关键调用：`jsonParseCall`；返回 null 时收成 `error.TypeError`。
- **所有权 / 错误 / 调用**：自身不分配；`args` 借用，返回的是 `jsonParseCall` 建出的 owned 值。错误：`nativeCall` 失败与 `jsonParseCall` 返回 null 都是裸 `error.TypeError`；两种环境不一致（有函数对象却没有 callable realm、既无函数对象也无 global）返回裸 `error.InvalidBuiltinRegistry`——刻意不让调用方权威悄悄兜底。除了作为 `JSON.parse` 记录的 handler，它还是 JSON 模块加载器那条合成调用的落点（`src/exec/module.zig:1283` 用 `callInternalRecord` 带 global、不带函数对象）。

### `jsonStringifyRecordCall` (`src/exec/json_ops.zig:138`)

- **签名**：`fn jsonStringifyRecordCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`JSON.stringify` 的 NativeEntry 处理函数：取 callable realm 后转给 `jsonStringifyCall`。
- **实现**：先 `nativeCall` 恢复 `NativeCall`；失败则 `error.TypeError`。 可观察调用再取 `callableRealm`，断言 realm 与 ctx 一致。 可返回 `error.TypeError`。 关键调用：`builtin_dispatch.callableRealm`、`jsonStringifyCall`。
- **所有权 / 错误 / 调用**：自身不分配；返回的是 `jsonStringifyCall` 建出的 owned 字符串（或 undefined）。错误：`nativeCall` 失败与 `jsonStringifyCall` 返回 null 都是裸 `error.TypeError`，`callableRealm` 失败时异常已挂好。与 parse 那条不同，它**不**接受没有函数对象的合成调用——`callableRealm` 是无条件的。没有具名调用方，只作为 `stringify` 记录的 handler。

### `stringify` (`src/exec/json_ops.zig:152`)

- **签名**：`pub fn stringify(rt: *core.JSRuntime, value: core.JSValue, replacer: core.JSValue, space: core.JSValue) !core.JSValue`。
- **作用**：不经 VM 的 `JSON.stringify`：只用运行时（无 ctx/global）把值序列化成 JSON 字符串。
- **实现**：`undefined` 直接返回 undefined。先由 `stringifyPropertyList` 算出 replacer 属性名列表（数组 replacer 才有，用 `isArrayObject` 判定 `has_property_list`；列表另用 `rootAtomList` 钉住），`stringifyGap` 算出缩进串，再用一个字节缓冲和对象栈跑 `appendJsonValue`；缓冲为空（值被省略）返回 undefined，否则 `createJsonStringValue`。注意这条路径不支持函数 replacer，也不调 `toJSON`。 关键调用：`stringifyPropertyList`、`stringifyGap`、`appendJsonValue`、`createJsonStringValue`。 用 `ValueRootFrame` / `rootValues` 钉住跨分配窗口的值。
- **所有权 / 错误 / 调用**：三个入参先进 `rootValues` 帧（后面处处是分配点即回收点）。`property_list` 由 `stringifyPropertyList` 分配、`defer freePropertyList` 释放，并另用 `rootAtomList` 钉住（TGC S3 §4 class B：native `[]Atom` 跨分配窗口）；`gap` / `buffer` / `stack` 三个 `ArrayList` 各自 `defer deinit`。返回的是 `createJsonStringValue` 新建的 owned 字符串，或 undefined（整个值被省略时）。error set 是 `JsonStringifyError`（OOM、`InvalidAtom`、`TypeError`、`StackOverflow`），**全是裸 error**——这条路径只有 `rt` 没有 ctx，不可能挂 pending exception。树内没有调用方：它是留给嵌入方的裸 runtime `JSON.stringify` 入口，VM 路径走的是 `jsonStringifyCall`。

### `parse` (`src/exec/json_ops.zig:182`)

- **签名**：`pub fn parse(rt: *core.JSRuntime, global: ?*core.Object, value: core.JSValue) !core.JSValue`。
- **作用**：不经 VM 的 `JSON.parse` 主体：把输入值解析成 JS 值，`JSON.parse` 无 reviver 时走的就是这条。
- **实现**：先把入参 root 住，`appendJsonInputString` 把它摊成 UTF-8 字节；先试 ASCII 整段快路径 `parseSimpleJsonValue`，返回非 null 就直接用。快路径 miss 后若原值本身是字符串，按 `resolveData()` 的 latin1 / utf16 两臂分别实例化 `jsonParseFull(u8)` / `jsonParseFull(u16)`；原值不是字符串（已被强转过）则走 `jsonParseFullFromBytes`。
- **所有权 / 错误 / 调用**：字节缓冲函数内释放；返回值是普通 GC 值。语法错误以 `error.SyntaxError` 上传，由 `materializeRuntimeError` 变成 JS `SyntaxError`。调用方：`jsonParseCall` 的无 reviver 分支，以及 `src/tests/exec.zig` 的裸 runtime 解析用例。

### `JsonParseWithRecord.deinit` (`src/exec/json_ops.zig:207`)

- **签名**：`fn deinit(self: *JsonParseWithRecord, rt: *core.JSRuntime) void`。
- **作用**：释放 `parseWithRecord` 交出来的那一对结果里的记录树，并把值槽清成 undefined。
- **实现**：`self.record.deinit(rt)` 递归释放整棵树（primitive 的 source 字节、array/object 的子数组），再把 `self.value` 写成 undefined；**不**释放那个 JS 值——它已经交给调用方，由 GC 管。
- **所有权 / 错误 / 调用**：只负责 native 记录树那一半。树内目前没有调用方：`jsonParseCall`（1637）与同文件单测（2638）都直接对 `record` 调 `JsonParseRecord.deinit` 并自己处理值槽，这个方法是 `JsonParseWithRecord` 这个 `pub` 类型给外部调用方配的释放器。

### `parseWithRecord` (`src/exec/json_ops.zig:219`)

- **签名**：`pub fn parseWithRecord(rt: *core.JSRuntime, global: ?*core.Object, value: core.JSValue) !JsonParseWithRecord`。
- **作用**：有 reviver 时的 `JSON.parse` 解析入口：解析的同时并行建出 `JsonParseRecord` 树，因此绝不走无记录的 ASCII 快路径。
- **实现**：值是字符串时按 `resolveData()` 的 latin1 / utf16 臂调 `jsonParseFullWithRecord(u8/u16)`；不是字符串时先 `appendJsonInputString` 摊成字节、`String.createUtf8` 造出真字符串，走同样两臂。对照 qjs js_json_parse 的 reviver 分支（带活 `pr` 调 JS_ParseJSON3，quickjs.c:49834）。
- **所有权 / 错误 / 调用**：返回的 `value` 与 `record` 都归调用方：record 树用 `JsonParseRecord.deinit` 释放，值单独处理。生产侧调用方是 `jsonParseCall` 的 reviver 分支（另有同文件的 TGC S3-d 单测）。

### `jsonParseFullWithRecord` (`src/exec/json_ops.zig:242`)

- **签名**：`fn jsonParseFullWithRecord(comptime T: type, rt: *core.JSRuntime, global: ?*core.Object, units: []const T) !JsonParseWithRecord`。
- **作用**：在某个码元宽度上跑一遍「值 + 记录树」的完整解析，并做「尾部只剩空白」的严格检查。
- **实现**：建 `JsonUnitParser(T)`，先把 `JsonPendingRecordRoots`（head 指向 parser 的 `pending_records` 链）挂上再解析；`skipWhitespace` + `parseValueRecord(&record)`。`errdefer record.deinit(rt)` 声明在这次 `try` **之后**（树要等它成功才存在），因此覆盖的是随后那次「尾部只剩空白」检查：返回前再跳一次空白，`parser.index != parser.units.len` 即 `error.SyntaxError`，此时已建成的记录树由该 errdefer 释放。
- **所有权 / 错误 / 调用**：返回的 `JsonParseWithRecord` 归调用方：`record` 须用 `JsonParseRecord.deinit` 释放，`value` 单独处理。`pending_roots` 只在本栈帧内注册/注销。唯一调用方是 `parseWithRecord` 的两条码元臂。

### `jsonParseFullFromBytes` (`src/exec/json_ops.zig:260`)

- **签名**：`fn jsonParseFullFromBytes(rt: *core.JSRuntime, global: ?*core.Object, bytes: []const u8) !core.JSValue`。
- **作用**：非字符串输入（已强转成 UTF-8 字节）的解析入口：先造出真字符串，再按码元走忠实解析。
- **实现**：`String.createUtf8` 建串，按 `resolveData()` 分发到 `jsonParseFull(u8)` / `jsonParseFull(u16)`。
- **所有权 / 错误 / 调用**：中间字符串是 GC 值，不手工释放。调用方：`parse` 的非字符串臂，以及 `rawJSON` 里那次「解析一遍确认合法且不是对象」的校验。

### `jsonParseFull` (`src/exec/json_ops.zig:275`)

- **签名**：`fn jsonParseFull(comptime T: type, rt: *core.JSRuntime, global: ?*core.Object, units: []const T) !core.JSValue`。
- **作用**：qjs JSON 解析器的忠实主体：在给定码元宽度上递归下降解析整段文本并返回值。
- **实现**：建无记录的 `JsonUnitParser(T)`，`skipWhitespace` → `parseValue` → 再 `skipWhitespace`，尾部还有残余（`parser.index != parser.units.len`）即 `error.SyntaxError`。递归深度由 `parseValueRecord` 里的 native stack guard 兜住，深嵌套报成可捕获的 SyntaxError（json_next_token js_check_stack_overflow，quickjs.c:23440,23483）；字符串里的孤立代理项按 WTF-16 原样保留。
- **所有权 / 错误 / 调用**：`parser` 在栈上，自身不分配；返回的是 owned JS 值（对象/数组/字符串/立即数），调用方不手工释放。error set `JsonParseError`：尾部残余与深嵌套都是 `error.SyntaxError`，其余是建对象/建串的 OOM 与定义属性的错误集——**都是裸 error**，这条路径没有 ctx，落成 JS SyntaxError 是上层 `materializeRuntimeError` 的事。两条码元臂的调用方：`parse`（197-198）与 `jsonParseFullFromBytes`（267-268）。

### `JsonParseRecord.recordValue` (`src/exec/json_ops.zig:315`)

- **签名**：`fn recordValue(self: *const JsonParseRecord) core.JSValue`。
- **作用**：取出记录节点在解析时缓存下来的值——三种 tag 共用的读取器。
- **实现**：`switch (self.*)` 三臂分别返回 primitive / array / object 的 `value` 字段（三种 tag 的第一个字段都是这个缓存值）。
- **所有权 / 错误 / 调用**：只读借用，不复制也不 retain；这些值在 walk 期间由 `JsonRecordRoots` 报成根，所以一直存活。调用方：`jsonInternalizeProperty` 的同值守卫（1734），以及同文件 TGC S3-d 单测读被遮蔽记录的那一处（2661）。

### `JsonParseRecord.findObjectEntry` (`src/exec/json_ops.zig:325`)

- **签名**：`fn findObjectEntry(self: *const JsonParseRecord, atom: core.Atom) ?*const JsonParseRecord`。
- **作用**：在对象记录里按键 atom 找子记录——命中的是**首次**出现的那一条。
- **实现**：只对 `.object` tag 有效（其它 tag 直接 null）：顺序扫 `entries` 比 atom，命中就返回该 entry 的 `record` 指针。重复键在解析时各占一条 entry 且保序，所以这里拿到的是**首次**出现的值——与属性表里「最后一次胜出」的值不同，同值守卫因此会把 `source` 丢掉，这正是 qjs json_parse_record_find（quickjs.c:49430）的行为。
- **所有权 / 错误 / 调用**：返回的是指向记录树内部的借用指针，生命周期跟着树走（由 `jsonParseCall` 的 `defer` 释放）。调用方：`jsonInternalizeProperty` 的非数组分支（1769），以及同文件 TGC S3-d 单测（2660）。

### `JsonParseRecord.arrayElement` (`src/exec/json_ops.zig:337`)

- **签名**：`fn arrayElement(self: *const JsonParseRecord, index: usize) ?*const JsonParseRecord`。
- **作用**：在数组记录里按下标取子记录，取不到给 null。
- **实现**：只对 `.array` tag 有效：下标在 `elements` 范围内就返回该元素的指针，越界或 tag 不符返回 null——后者确实会发生，reviver 把数组换成别的东西之后记录就与实际值对不上了。
- **所有权 / 错误 / 调用**：返回指向记录树内部的借用指针，生命周期跟着树走。唯一调用方是 `jsonInternalizeProperty` 的数组分支（1745）。

### `JsonParseRecord.deinit` (`src/exec/json_ops.zig:352`)

- **签名**：`fn deinit(self: *JsonParseRecord, rt: *core.JSRuntime) void`。
- **作用**：递归释放整棵记录树占的 native 内存。
- **实现**：按 tag 分三臂：primitive 释放非空的 `source` 字节；array 先逐个 `deinit` 元素再释放 `elements` 数组；object 先逐条 `deinit` entry 里的子记录再释放 `entries` 数组。对照 json_free_parse_record（quickjs.c:49459）。
- **所有权 / 错误 / 调用**：只释放 native 内存：缓存的 `value` 与 entry 的 atom 都不在这里释放——tracing GC 下它们由 `JsonRecordRoots` / `JsonPendingRecordRoots` 报根，函数上那条 rc 时代的注释已改实。调用方：`jsonParseCall` 的 `defer`（1637）、`jsonParseFullWithRecord` 的 errdefer（254）、`parseObject` / `parseArray` 的 errdefer 与 append 失败路径（613 一带）、`JsonParseWithRecord.deinit`（209）、同文件单测（2638）。

### `JsonRecordRoots.traceRecord` (`src/exec/json_ops.zig:394`)

- **签名**：`fn traceRecord(record: *JsonParseRecord, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void`。
- **作用**：递归把一棵 parse-record 树上缓存的 JSValue 与键 atom 报告给 GC。
- **实现**：按节点 tag 分三臂：primitive 只报 `p.value`；array 报 `a.value` 后递归每个 element；object 报 `o.value`，再对每条 entry 先 `visitor.atomRoot(entry.atom)` 再递归子记录。值是**就地**报告（传 `&p.value` 这样的槽地址）而不是快照，移动式收集器可以改写它们。
- **所有权 / 错误 / 调用**：不分配。`RootTraceError` 是 GC 内部的遍历错误，直接传回 visitor，不变成 JS 异常。被 `JsonRecordRoots.traceRoots` 与 `JsonPendingRecordRoots.traceRoots` 共用。

### `JsonRecordRoots.traceRoots` (`src/exec/json_ops.zig:411`)

- **签名**：`fn traceRoots(context: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void`。
- **作用**：`JsonRecordRoots` 的 RootProvider 回调：树已交接过来时把整棵树报给 GC。
- **实现**：把 `context` 还原成 `*JsonRecordRoots`；`self.record` 还是 null（parse 尚未返回、或已在释放前被清空）就直接返回，否则 `traceRecord`。
- **所有权 / 错误 / 调用**：由 runtime 的 root provider 数组在标记时回调；不分配。`self.record` 的赋值与清空由 `jsonParseCall` 负责，清空与 `deinit` 写在同一条语句序列里。

### `JsonRecordRoots.provider` (`src/exec/json_ops.zig:417`)

- **签名**：`fn provider(self: *JsonRecordRoots) core.runtime.RootProvider`。
- **作用**：把 `self` 包成 runtime 认的 `RootProvider`（context 指针 + trace 函数指针）。
- **实现**：返回 `.{ .context = @ptrCast(self), .trace = traceRoots }`。注册与注销要求逐字段相等的同一个值，所以 `activate`/`deactivate` 都经由它构造。
- **所有权 / 错误 / 调用**：不分配；`context` 借用调用方栈上的 `JsonRecordRoots`，其存活期不得短于注册期。只被本类型的 `activate`/`deactivate` 调用。

### `JsonRecordRoots.activate` (`src/exec/json_ops.zig:421`)

- **签名**：`fn activate(self: *JsonRecordRoots) !void`。
- **作用**：把这棵记录树的根提供者挂进 runtime。
- **实现**：`core.runtime.value_root_frames_enabled` 关时 comptime 直接返回；否则 `registerRootProvider(self.provider())` 成功后置 `registered = true`。它被刻意安排在 parse **之前**调用（此时 `record` 仍是 null）：注册本身会让 provider 数组增长，而一次分配就是一个回收点，不能让已经建好的树暴露在那个点上。
- **所有权 / 错误 / 调用**：注册失败（分配失败）时 `registered` 保持 false，`deactivate` 因此是幂等的。调用方 `jsonParseCall` 用 `defer` 配对注销。

### `JsonRecordRoots.deactivate` (`src/exec/json_ops.zig:427`)

- **签名**：`fn deactivate(self: *JsonRecordRoots) void`。
- **作用**：注销这棵记录树的根提供者。
- **实现**：开关关或 `registered` 为 false 时直接返回；否则 `unregisterRootProvider(self.provider())` 并清 `registered`。
- **所有权 / 错误 / 调用**：不分配、不失败；与 `activate` 严格配对，由 `jsonParseCall` 的 `defer` 触发。

### `JsonPendingRecordRoots.traceRoots` (`src/exec/json_ops.zig:467`)

- **签名**：`fn traceRoots(context: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void`。
- **作用**：RootProvider 回调：把递归栈上每个「在建」object/array 帧里的半成品记录报给 GC。
- **实现**：沿 `head` 从最内层帧往外遍历 `JsonPendingRecordFrame`：`entries` 列表里每条先 `visitor.atomRoot(entry.atom)` 再 `JsonRecordRoots.traceRecord`；`elements` 列表逐个 `traceRecord`；`pending` 槽——子记录已填好、但还没 append 进列表的那一瞬——也报一次。
- **所有权 / 错误 / 调用**：不分配。帧由 `parseObject` / `parseArray` 自己压栈出栈，整轮递归只注册一次 provider；按帧注册会让 `registerRootProvider` 的去重扫描随嵌套深度变成平方。

### `JsonPendingRecordRoots.provider` (`src/exec/json_ops.zig:484`)

- **签名**：`fn provider(self: *JsonPendingRecordRoots) core.runtime.RootProvider`。
- **作用**：把 `self` 包成 runtime 认的 `RootProvider`（context 指针 + trace 函数指针）。
- **实现**：返回 `.{ .context = @ptrCast(self), .trace = traceRoots }`；注册/注销共用它以保证两次传入的值逐字段相等。
- **所有权 / 错误 / 调用**：不分配；`context` 借用 `jsonParseFullWithRecord` 栈上的 `JsonPendingRecordRoots`。

### `JsonPendingRecordRoots.activate` (`src/exec/json_ops.zig:488`)

- **签名**：`fn activate(self: *JsonPendingRecordRoots) !void`。
- **作用**：解析开始前，把「在建帧链」的根提供者挂进 runtime。
- **实现**：开关关时 comptime 返回；否则 `registerRootProvider(self.provider())` 后置 `registered`。链头是 parser 的 `pending_records` 字段，注册时链还是空的。
- **所有权 / 错误 / 调用**：失败时 `registered` 保持 false；调用方 `jsonParseFullWithRecord` 用 `defer deactivate()` 配对。

### `JsonPendingRecordRoots.deactivate` (`src/exec/json_ops.zig:494`)

- **签名**：`fn deactivate(self: *JsonPendingRecordRoots) void`。
- **作用**：注销「在建帧链」的根提供者。
- **实现**：开关关或没注册过直接返回；否则 `unregisterRootProvider(self.provider())` 并清 `registered`。
- **所有权 / 错误 / 调用**：不分配、不失败；与 `activate` 配对，解析返回（含出错）时都会执行。

### `JsonUnitParser` (`src/exec/json_ops.zig:502`)

- **签名**：`fn JsonUnitParser(comptime T: type) type`。
- **作用**：返回按代码单元（`u8` latin1 / `u16` utf16）递归下降的 JSON 解析器类型，忠实移植 qjs `json_next_token` / `json_parse_value`。
- **实现**：返回的 `struct` 持有 `rt`/`global`/`units`/`index` 以及 in-flight `pending_records` 链。嵌套方法：`peek`/`skipWhitespace`/`parseValue`/`parseValueRecord`/`parseObject`/`parseArray`/`parseString`/`parseNumber`。深度受 `checkNativeStackOverflow`；孤立代理项合法。有 `record` 时并行建 `JsonParseRecord` 树。
- **所有权 / 错误 / 调用**：解析出的 JSValue 由调用方拥有；record 树由 `JsonParseRecord.deinit` 释放。SyntaxError 在过深或尾随垃圾时抛出。

### `JsonUnitParser.peek` (`src/exec/json_ops.zig:513`)

- **签名**：`fn peek(self: *const Self) ?T`。
- **作用**：看一眼光标处的码元，越界给 null。
- **实现**：`self.index >= self.units.len` 返回 null，否则返回 `self.units[self.index]`；不推进光标。
- **所有权 / 错误 / 调用**：不分配、不失败；本解析器所有扫描循环（`skipWhitespace`、`parseValueRecord` 的分派、`parseNumber` 的文法扫描）的基元。

### `JsonUnitParser.skipWhitespace` (`src/exec/json_ops.zig:518`)

- **签名**：`fn skipWhitespace(self: *Self) void`。
- **作用**：跳过 JSON 语法允许的四种空白。
- **实现**：循环 `switch`，只认 `' '` / `\t` / `\n` / `\r` 并推进 `index`，遇到别的字符立即 return。JSON 不承认其他 Unicode 空白，所以这里刻意不查 `unicode` 表。
- **所有权 / 错误 / 调用**：不分配、不失败。被 `jsonParseFull` / `jsonParseFullWithRecord` 的首尾检查与各递归体调用。

### `JsonUnitParser.expectLiteral` (`src/exec/json_ops.zig:527`)

- **签名**：`fn expectLiteral(self: *Self, comptime text: []const u8) !void`。
- **作用**：消费一段 comptime 已知的字面量（`true`/`false`/`null`），对不上就 `error.SyntaxError`。
- **实现**：先查剩余长度，再 `inline for` 逐字节比对；全中才把 `index` 推进 `text.len`。 可返回 `error.SyntaxError`。
- **所有权 / 错误 / 调用**：不分配，只推进 `self.index`；`text` 是 comptime 字面量、不涉及所有权。`error.SyntaxError` 是裸 error，落成 JS SyntaxError 由上层负责。调用方：`parseValueRecord` 的 `true` / `false` / `null` 三臂（555、559、563）。

### `JsonUnitParser.parseValue` (`src/exec/json_ops.zig:535`)

- **签名**：`fn parseValue(self: *Self) JsonParseError!core.JSValue`。
- **作用**：无记录地解析一个 JSON 值。
- **实现**：直接转调 `parseValueRecord(null)`——有记录与无记录两条路共用同一个递归体，只差记录槽是否填。
- **所有权 / 错误 / 调用**：纯转发，不分配、不建根；error set 与 `parseValueRecord` 完全相同。唯一调用方 `jsonParseFull`（282）——也就是所有「不需要记录树」的解析入口。

### `JsonUnitParser.parseValueRecord` (`src/exec/json_ops.zig:543`)

- **签名**：`fn parseValueRecord(self: *Self, record: ?*JsonParseRecord) JsonParseError!core.JSValue`。
- **作用**：解析一个 JSON 值；`record` 非空时同步填好它对应的 parse-record 节点。
- **实现**：入口先 `self.rt.checkNativeStackOverflow(0)`，超深就 `error.SyntaxError`（qjs 把深嵌套报成可捕获的 SyntaxError）。跳空白后按首单元分派：`{` / `[` 直接 return `parseObject` / `parseArray`（容器记录由它们自己填），`"`→`parseString`，`t`/`f`/`n`→`expectLiteral`，`-` 与 `0`...`9`→`parseNumber`，其余 `error.SyntaxError`。叶子返回前若 `record` 非空，用 `recordSourceSpan(start, self.index)` 把 [start,index) 的原始码元存成 primitive 记录（字符串含两侧引号）。 关键调用：`self.parseObject`、`self.parseArray`、`self.parseString`、`self.expectLiteral`、`self.parseNumber`、`self.recordSourceSpan`。 对照 quickjs.c:49484,49373。
- **所有权 / 错误 / 调用**：自身不分配（叶子的 `source` 由 `recordSourceSpan` 分配，随后归记录树）；返回 owned JS 值。`record` 指向**调用方栈上**的槽——`jsonParseFullWithRecord` 的局部 `record`，或 `parseObject` / `parseArray` 的 `child_slot_storage`——本函数只负责填。error set `JsonParseError`，全是裸 error：栈过深与文法错误都是 `error.SyntaxError`。调用方：`parseValue`（538）、`jsonParseFullWithRecord`（252），以及 `parseObject`（644）/ `parseArray`（704）的递归。

### `JsonUnitParser.recordSourceSpan` (`src/exec/json_ops.zig:578`)

- **签名**：`fn recordSourceSpan(self: *Self, start: usize, end: usize) ![]u8`。
- **作用**：把源文本的 [start,end) 码元切片编码成 WTF-8 字节，作为 primitive 记录的 `source`。
- **实现**：`T == u16` 时整片交给 `appendWtf8FromUnits`；latin1 则逐个单元加宽成 `[1]u16` 再走同一编码器，使 >= 0x80 的字节输出两字节形式。 关键调用：`appendWtf8FromUnits`。
- **所有权 / 错误 / 调用**：返回 `toOwnedSlice` 出来的堆字节，归 `JsonParseRecord`；最终由 `JsonParseRecord.deinit` 释放。

### `JsonUnitParser.parseObject` (`src/exec/json_ops.zig:594`)

- **签名**：`fn parseObject(self: *Self, record: ?*JsonParseRecord) JsonParseError!core.JSValue`。
- **作用**：解析 `{ ... }`：建对象并逐键写入属性，带记录时同时攒出 entry 列表。
- **实现**：吃掉 `{` 后 `core.Object.create`（原型取自 `objectPrototypeFromGlobal`）并把对象值 root 住。带记录时备好 `entries` 列表与释放用的 errdefer，再压一个 `JsonPendingRecordFrame`（声明在 errdefer 之后，保证出栈先于 free）。`}` 立即收尾则交出空 entries。循环体：键必须以 `"` 开头，`parseKeyAtom` 拿到的裸 atom 用 `rootAtoms` 钉住（随后的递归解析会自由分配），冒号后递归 `parseValueRecord(child_slot)`；**先** append 记录 entry（append 失败就地 `slot.deinit`）**再** `defineJsonParseDataProperty`，这样后续任何失败都被 `entries` 的 errdefer 覆盖、不会漏掉 `child_slot_storage`。重复键各占一条 entry 且保序（json_parse_record_add，quickjs.c:49405；对象记录本身对照 quickjs.c:49508）。`}` 收尾时 `toOwnedSlice` 交出 entries，`,` 继续，其他字符 `error.SyntaxError`。
- **所有权 / 错误 / 调用**：新建的对象值进 `ValueRootFrame` 钉住（后面的键解析、递归、属性定义全是分配点）；键 atom 是裸 id，另用 `rootAtoms` 钉住。带记录时 `entries` 是 native `ArrayList`：errdefer 先逐条 `deinit` 子记录再 `deinit` 列表，同时压一个 `JsonPendingRecordFrame`，让 `JsonPendingRecordRoots` 在整个递归期间报这些已建好的 entry（重复键的首次出现值只被 entries 持有，见该类型的注释）。声明顺序是刻意的：`pending_frame` 的 `defer` 出栈必须先于 `entries` 的 errdefer 释放。成功时 `toOwnedSlice` 把 entries 交给记录节点，之后归记录树。error 全是裸 error。唯一调用方 `parseValueRecord` 的 `{` 臂（551）。

### `JsonUnitParser.parseArray` (`src/exec/json_ops.zig:669`)

- **签名**：`fn parseArray(self: *Self, record: ?*JsonParseRecord) JsonParseError!core.JSValue`。
- **作用**：解析 `[ ... ]`：建数组并按序写入元素，带记录时同时攒出 element 列表。
- **实现**：吃掉 `[` 后 `createArray`（原型取自 `arrayPrototypeFromGlobal`）并 root 住。带记录时备 `elements` 列表并压 `JsonPendingRecordFrame`——数组元素不会被覆写、本来就经数组可达，这个帧是为嵌套 object 元素可能产生的重复键孤儿准备的（json_parse_record_init_array，quickjs.c:49571）。循环体递归 `parseValueRecord`，同样**先** append 元素记录**再**写数组：优先 `appendDenseArrayLiteralIndex`，返回 false 才回落 `defineOwnProperty`（数组是解析器自己新建的，回落撞不上 AUTOINIT 属性，所以错误集能 `@errorCast` 收窄）。`]` 收尾 `toOwnedSlice`，`,` 继续，其他 `error.SyntaxError`。
- **所有权 / 错误 / 调用**：与 `parseObject` 同构：新建数组值进 `ValueRootFrame`，`elements` 列表由 errdefer 释放并经 `JsonPendingRecordFrame` 报根，成功时 `toOwnedSlice` 交给记录节点。差别在于数组元素不会被覆写、本来就经数组可达，这个帧只为「嵌套 object 元素里的重复键孤儿」准备。error 全是裸 error（`defineOwnProperty` 那次 `@errorCast` 只是把宽错误集收窄，不改变语义）。唯一调用方 `parseValueRecord` 的 `[` 臂（552）。

### `JsonUnitParser.parseKeyAtom` (`src/exec/json_ops.zig:733`)

- **签名**：`fn parseKeyAtom(self: *Self) !core.Atom`。
- **作用**：读一个 JSON 字符串键并 intern 成 atom。
- **实现**：`parseStringUnits` 解出 UTF-16 码元，`appendWtf8FromUnits` 编码成 atom 用的 WTF-8 字节，再 `rt.internAtom`；两个临时列表都在函数内释放。 关键调用：`self.parseStringUnits`、`appendWtf8FromUnits`、`self.rt.internAtom`。
- **所有权 / 错误 / 调用**：两个临时 `ArrayList` 都 `defer deinit`，函数内释放干净。返回的 atom 按本文件的约定是**裸 id**（源码注释原话），所以调用方 `parseObject` 拿到后立刻用 `rootAtoms` 钉住——随后的递归解析会自由分配。error：`parseStringUnits` 的 `error.SyntaxError` 与两处 OOM。唯一调用方 `parseObject`（633）。

### `JsonUnitParser.parseString` (`src/exec/json_ops.zig:743`)

- **签名**：`fn parseString(self: *Self) !core.JSValue`。
- **作用**：解析一个 JSON 字符串字面量，建成 JS 字符串值。
- **实现**：`parseStringUnits` 把转义解完写进临时 `ArrayList(u16)`，再 `String.createUtf16` 建值；临时列表在函数内释放。孤立代理项原样保留（WTF-16），与 qjs 一致。
- **所有权 / 错误 / 调用**：临时 `ArrayList(u16)` `defer deinit`；返回的是 `String.createUtf16` 新建的 owned 字符串值。error：`parseStringUnits` 的裸 `error.SyntaxError`，以及建串的 OOM / `StringTooLong`。唯一调用方 `parseValueRecord` 的 `"` 臂（553）。

### `JsonUnitParser.parseStringUnits` (`src/exec/json_ops.zig:752`)

- **签名**：`fn parseStringUnits(self: *Self, out: *std.ArrayList(u16)) !void`。
- **作用**：把一段 JSON 字符串字面量的内容解成 UTF-16 码元追加进 `out`。
- **实现**：吃掉开引号后逐单元扫：`"` 结束；`\` 进转义 `switch`——`"` / `\` / `/` 原样，`b`/`f`/`n`/`r`/`t` 映到 0x08/0x0c/0x0a/0x0d/0x09，`u` 再取四个 `jsonHexDigit` 拼成裸 u16 直接 append（**不做**代理配对校验，所以孤立代理能活下来），其余转义字符 `error.SyntaxError`；裸控制字符（< 0x20）非法；普通单元原样写出（`u8` 源单元隐式加宽进 `ArrayList(u16)`，原先那对 `if (T == u8) … else …` 逐字相同的分支已合并成一句）。文本提前结束同样 `error.SyntaxError`。对照 qjs js_parse_string 的 JSON 模式。
- **所有权 / 错误 / 调用**：只往调用方给的 `out` 追加，不持有它、也不分配自己的缓冲。error：文法错误的裸 `error.SyntaxError` 与 `out.append` 的 OOM。调用方：`parseKeyAtom`（738）与 `parseString`（748）。

### `JsonUnitParser.parseNumber` (`src/exec/json_ops.zig:792`)

- **签名**：`fn parseNumber(self: *Self) !core.JSValue`。
- **作用**：按 JSON 的严格数字文法读一个数，定成 int32 或 float64。
- **实现**：按 JSON 严格数字文法扫描：可选 `-`、整数部分 `0 | [1-9][0-9]*`、可选小数部分（`.` 后至少一位）、可选指数（`e`/`E` 加可选符号、至少一位），任一处不满足即 `error.SyntaxError`。扫描完把码元拷成 ASCII 再定值：没有小数/指数时先试 `core.value_format.parseAsciiInt(i64, ...)`，落在 i32 范围且不是 `-0` 就返回 `int32`，否则 `float64`；其余交 `std.fmt.parseFloat`，失败为 `error.SyntaxError`。 关键调用：`core.value_format.parseAsciiInt`、`std.fmt.parseFloat`。
- **所有权 / 错误 / 调用**：`ascii` 临时列表 `defer deinit`；返回的是立即数（int32 或 float64），不建 GC 对象。error：文法错误与 `parseFloat` 失败都是裸 `error.SyntaxError`，外加 `ensureTotalCapacity` 的 OOM。唯一调用方 `parseValueRecord` 的 `-` / 数字臂（566）。

### `jsonHexDigit` (`src/exec/json_ops.zig:848`)

- **签名**：`fn jsonHexDigit(unit: anytype) ?u16`。
- **作用**：把一个十六进制码元换算成 0..15，非十六进制给 null。
- **实现**：三段 `switch`：`'0'...'9'` 减 `'0'`，`'a'...'f'` 与 `'A'...'F'` 减基后加 10，其余 null。参数是 `anytype`，latin1（u8）与 utf16（u16）两种 parser 实例共用。
- **所有权 / 错误 / 调用**：不分配、不失败。唯一调用方是 `parseStringUnits` 的 `\u` 转义臂，连取四次。

### `appendWtf8FromUnits` (`src/exec/json_ops.zig:859`)

- **签名**：`fn appendWtf8FromUnits(rt: *core.JSRuntime, out: *std.ArrayList(u8), units: []const u16) !void`。
- **作用**：把 UTF-16 码元序列编码成 WTF-8 字节——atom 名与 parse-record `source` 使用的字节编码。
- **实现**：逐个码元编码：高代理后面紧跟低代理时合成补充平面码点，孤立代理按自身三字节形式输出（WTF-8，而非 UTF-8 的替换字符）；随后按 <0x80 / <0x800 / <0x10000 / 更大四档写 1..4 字节。 关键调用：`out.append`。
- **所有权 / 错误 / 调用**：只往调用方的 `out` 追加，`units` 只读借用，自己不持有缓冲。唯一的 error 是 `out.append` 的 OOM。调用方：`recordSourceSpan` 的两条臂（584、590）与 `parseKeyAtom`（741）。

### `rawJSON` (`src/exec/json_ops.zig:889`)

- **签名**：`pub fn rawJSON(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue`。
- **作用**：`JSON.rawJSON` 的实现体：校验文本确实是一个合法的 JSON **非对象**值，再包成密封的 raw_json 对象。
- **实现**：先把入参、待建对象、文本三个槽一起 root 住，`appendJsonInputString` 把值摊成 UTF-8 字节——它的 `error.TypeError` 在输入是对象时改判成 `error.SyntaxError`。随后三道校验：字节为空、或首尾任一字节是 `isRawJsonEdgeWhitespace` 的空白，都是 `error.SyntaxError`；再用 `jsonParseFullFromBytes(rt, null, bytes)` 整段解析一遍，解出对象也是 `error.SyntaxError`（rawJSON 只收非对象值）。全过后 `core.Object.create(raw_json class, null 原型)` 建对象、`createJsonStringValue` 把字节建成字符串、`defineData(..., core.atom.ids.rawJSON, text, true)` 写成不可写不可配置但可枚举的字段，最后 `object.seal(rt)` 密封并返回。 用 `ValueRootFrame` / `rootValues` 钉住跨分配窗口的值。
- **所有权 / 错误 / 调用**：三个值（入参、对象、文本）一起进 `ValueRootFrame`，`bytes` 缓冲 `defer deinit`。返回的是新建并 `seal` 过的 owned 对象。错误：`appendJsonInputString` 的 `error.TypeError` 在对象输入时被**改判**成 `error.SyntaxError`（qjs 对摊不平的对象报语法错），首尾空白、以及校验解析出的是对象，也都是 `error.SyntaxError`——这些裸 error 由 `jsonRawJsonCall` 落成带消息的 JS SyntaxError。中途那次 `jsonParseFullFromBytes` 纯为校验，产物立刻丢弃交给 GC。唯一调用方 `jsonRawJsonCall`（105）。

### `isRawJsonEdgeWhitespace` (`src/exec/json_ops.zig:928`)

- **签名**：`fn isRawJsonEdgeWhitespace(byte: u8) bool`。
- **作用**：判断一个字节是不是 JSON 空白，用于 `rawJSON` 的首尾字符检查。
- **实现**：四路 `or`：`' '` / `\t` / `\n` / `\r`。
- **所有权 / 错误 / 调用**：不分配。唯一调用方是 `rawJSON`：文本首尾只要是空白就按规范报 `error.SyntaxError`。

### `isRawJSON` (`src/exec/json_ops.zig:932`)

- **签名**：`pub fn isRawJSON(value: core.JSValue) bool`。
- **作用**：判断一个值是不是 `JSON.rawJSON` 造出的 raw_json 对象。
- **实现**：先 `refHeader()` 取堆头（非堆值直接 false），再确认 `is(.object)`，最后比 `object.class_id == core.class.ids.raw_json`——`rawJSON` 造出的对象用的正是这个 class id。
- **所有权 / 错误 / 调用**：只读不分配。文件内唯一调用方是 `jsonIsRawJsonCall`（`JSON.isRawJSON`，87）；两条序列化路径判 raw 片段时并不经过它，而是直接比 `object.class_id == core.class.ids.raw_json`（990、2413）。它是 `pub`，也留给嵌入方用。

### `createSimpleJsonAsciiStringValue` (`src/exec/json_ops.zig:939`)

- **签名**：`fn createSimpleJsonAsciiStringValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue`。
- **作用**：ASCII 快路径的建串：把借用的输入字节直接建成 ASCII 字符串值。
- **实现**：一行 `String.createAscii(rt, bytes).value()`。快路径只接受无转义的纯 ASCII 串（由 `parseSimpleStringBytes` 保证），所以既不用 UTF-8 解码也不用处理转义，照抄字节即可——这正是快路径比忠实解析器省的那一段。
- **所有权 / 错误 / 调用**：`bytes` 借自输入文本；返回的是新建的 owned 字符串值（内容已复制，不再指向输入缓冲）。error 只有建串的 OOM / `StringTooLong`。唯一调用方 `SimpleJsonParser.parseValue` 的 `"` 臂（1103）。

### `appendJsonValue` (`src/exec/json_ops.zig:943`)

- **签名**：`fn appendJsonValue(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue, array_slot: bool, stack: *std.ArrayList(*core.Object), options: StringifyOptions, depth: usize) JsonStringifyError!void`。
- **作用**：非 VM `stringify` 的值序列化递归体：把一个值写成 JSON 文本追加进缓冲。
- **实现**：入口 `checkNativeStackOverflow` 报 `error.StackOverflow`，然后一串 if/else 按值形态分：`undefined`/symbol 在数组槽写 `null`、在对象槽写空串（空串就是「省略」的信号）；`null` 与非有限数写 `null`；int32 走 `number_format.formatInt64`，`0` 特判成 `'0'`，其余 f64 走 `formatFiniteNumberAssumeCapacity`；bool 写字面量；字符串走 `appendJsonStringValue` 转义；BigInt 直接 `error.TypeError`。对象再分：raw_json 取 `rawJSON` 属性原样写出；`isCallableJsonOmittedObject` 命中按 undefined 处理；Number/String/Boolean 包装对象取 `jsonPrimitiveWrapperValue` 后**同深度**递归；数组走 `appendJsonArray`，其余走 `appendJsonObject`。这条路径不调 `toJSON`、也不认函数 replacer。
- **所有权 / 错误 / 调用**：入口就把 `value` 与两个中间值（raw / primitive）进 `rootValues` 帧——递归里处处是分配点。只往调用方的 `buffer` 追加，`stack` 也只是借用。error set `JsonStringifyError`：递归过深是 `error.StackOverflow`、裸 BigInt 是 `error.TypeError`，其余是 OOM / `InvalidAtom`——全是裸 error（这条路径没有 ctx）。调用方：`stringify`（176）、包装对象臂的自递归（997）、`appendJsonArray`（1026）、`appendJsonObject`（1066）。

### `appendJsonArray` (`src/exec/json_ops.zig:999`)

- **签名**：`fn appendJsonArray(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), object: *core.Object, stack: *std.ArrayList(*core.Object), options: StringifyOptions, depth: usize) JsonStringifyError!void`。
- **作用**：非 VM `stringify` 的数组分支：把数组写成 `[...]`。
- **实现**：先 `objectInStack` 查环，命中即 `error.TypeError`（循环引用）；把对象压进 `stack`、`defer` 弹出。逐个下标取值优先走 `getDenseArrayElementValue`，dense 槽缺失才回落 `getProperty(atomFromUInt32(index))`；每个元素以 `array_slot = true` 递归 `appendJsonValue`，因此洞和 undefined 都写成 `null`。`options.gap` 非空时每个元素前换行并 `appendIndent(depth + 1)`，非空数组收尾再换行缩进到 `depth`。长度取的是 `object.arrayLength()`。
- **所有权 / 错误 / 调用**：`stack` 借用：压入自己、`defer` 弹出，构成循环检测；每个元素值再用 `rootValues` 钉一层。只往 `buffer` 追加，不持有它。error：循环引用是裸 `error.TypeError`，其余是 OOM。唯一调用方 `appendJsonValue` 的数组臂（999）。

### `appendJsonObject` (`src/exec/json_ops.zig:1026`)

- **签名**：`fn appendJsonObject(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), object: *core.Object, stack: *std.ArrayList(*core.Object), options: StringifyOptions, depth: usize) JsonStringifyError!void`。
- **作用**：非 VM `stringify` 的对象分支：把对象写成 `{...}`。
- **实现**：同样先 `objectInStack` 查环再压栈。键源二选一：有 replacer 属性列表用 `options.property_list`，否则 `object.ownKeys(rt)`（并 `defer freeKeys`）。逐键跳过公开 symbol；取值优先 `getOwnDataPropertyValue`，不是自有数据属性才 `getProperty`；值为 undefined / symbol，或是被 `isCallableJsonOmittedObject` 判成可调用的对象，则整条属性省略。真正写出时用 `emitted` 标志决定是否先补逗号，键名走 `appendJsonAtomName` 转义，分隔符按 gap 取 `":"` 或 `": "`，值以 `array_slot = false` 递归。gap 非空且写出过属性时收尾换行缩进。
- **所有权 / 错误 / 调用**：`ownKeys` 分配出来的键数组由 `defer core.Object.freeKeys` 释放（有 replacer 属性列表时根本不去取）；每个属性值用 `rootValues` 钉住；`stack` 的压入/弹出与 `appendJsonArray` 相同。error：循环引用是裸 `error.TypeError`，其余是 OOM / `InvalidAtom`。唯一调用方 `appendJsonValue` 的对象兜底臂（1001）。

### `SimpleJsonParser.parse` (`src/exec/json_ops.zig:1072`)

- **签名**：`fn parse(self: *SimpleJsonParser) !?core.JSValue`。
- **作用**：ASCII 快路径解析器的入口：整段解析成功才返回值，任何不支持的形态返回 null 让调用方回退。
- **实现**：跳空白后 `parseValue`；`error.UnsupportedSimpleJson` 就地转成 `return null`（不是错误，是回退信号），其他错误照常上传。解析完再跳空白，尾部还有残余同样返回 null——把「尾部垃圾」的判决交给忠实解析器去报 SyntaxError。
- **所有权 / 错误 / 调用**：不持有堆资源；返回的是 GC 值。唯一调用方 `parseSimpleJsonValue`。

### `SimpleJsonParser.parseValue` (`src/exec/json_ops.zig:1085`)

- **签名**：`fn parseValue(self: *SimpleJsonParser) SimpleJsonError!core.JSValue`。
- **作用**：ASCII 快路径的值分派：只处理 ASCII 无转义字符串、i32 整数、字面量与由它们组成的对象/数组。
- **实现**：先 `checkNativeStackOverflow`（超深 `error.SyntaxError`），跳空白后按首字节分派：`{`/`[` 转 `parseObject`/`parseArray`，`"` 走 `parseSimpleStringBytes` + `createSimpleJsonAsciiStringValue`，`t`/`f`/`n` 用 `consumeLiteral` 认字面量，`-` 与数字走 `parseInt32Number`；任何不认识的形态返回 `error.UnsupportedSimpleJson` 让上层回退到忠实解析器。 关键调用：`self.parseObject`、`self.parseArray`、`self.parseSimpleStringBytes`、`createSimpleJsonAsciiStringValue`、`self.consumeLiteral`、`self.parseInt32Number`。
- **所有权 / 错误 / 调用**：自身不分配 native 缓冲；返回 owned 值（字符串/对象/数组）或立即数。error set `SimpleJsonError`，其中 **`error.UnsupportedSimpleJson` 不是失败而是「快路径不认这个形态」的信号**：`SimpleJsonParser.parse` 把它翻成 null，`parse` 于是整段回落到忠实解析器；栈过深的 `error.SyntaxError` 才是真错误。已经建了一半的对象/数组在回退时直接丢弃，交给 GC。调用方：`SimpleJsonParser.parse`（1083）以及 `parseObject` / `parseArray` 的递归。

### `SimpleJsonParser.parseObject` (`src/exec/json_ops.zig:1104`)

- **签名**：`fn parseObject(self: *SimpleJsonParser) !core.JSValue`。
- **作用**：ASCII 快路径的对象分支：建对象并逐键写属性，遇到任何超出快路径的形态就回退。
- **实现**：吃掉 `{` 后按「空对象 0 槽 / 非空预留 4 槽」建对象，再循环读 `"key"` `:` value：键走 `parseSimpleStringBytes` + `internAtom`（并用 `rootAtoms` 钉住），值递归 `parseValue` 后 `defineJsonParseDataProperty` 写入，遇 `}` 收尾、遇 `,` 继续，其他形态 `error.UnsupportedSimpleJson`。 关键调用：`core.Object.createWithOwnPropertyCapacity`、`self.parseSimpleStringBytes`、`self.rt.internAtom`、`self.parseValue`、`object.defineJsonParseDataProperty`。 用 `ValueRootFrame` / `rootValues` 钉住跨分配窗口的值。
- **所有权 / 错误 / 调用**：新建对象值进 `ValueRootFrame`，键 atom 用 `rootAtoms`、元素值另开一层 `rootValues`（`defineJsonParseDataProperty` 会分配）。不分配 native 缓冲——键文本是输入字节的借用切片。error：形态不认走 `error.UnsupportedSimpleJson` 让整段回退（半成品对象交给 GC），其余是建对象与定义属性的错误集。唯一调用方 `SimpleJsonParser.parseValue` 的 `{` 臂（1099）。

### `SimpleJsonParser.parseArray` (`src/exec/json_ops.zig:1155`)

- **签名**：`fn parseArray(self: *SimpleJsonParser) SimpleJsonError!core.JSValue`。
- **作用**：ASCII 快路径的数组分支：建数组并按序写入元素。
- **实现**：`[` 后立即 `createArray` 并 root 住；紧跟 `]` 就返回空数组。循环递归 `parseValue`，元素值另开一层 `rootValues` 钉住，随后 `appendDenseArrayLiteralIndex` 写 dense 槽，返回 false 才回落 `defineOwnProperty`（数组是本解析器新建的，撞不上 AUTOINIT，故 `@errorCast` 收窄错误集）。`]` 收尾、`,` 继续，其他一律 `error.UnsupportedSimpleJson` 回退。
- **所有权 / 错误 / 调用**：新建数组值与每个元素值都用 `rootValues` 钉住；不分配 native 缓冲。error 与 `parseObject` 同样：不认的形态一律 `error.UnsupportedSimpleJson` 触发整段回退，半成品数组交给 GC。唯一调用方 `SimpleJsonParser.parseValue` 的 `[` 臂（1100）。

### `SimpleJsonParser.parseSimpleStringBytes` (`src/exec/json_ops.zig:1185`)

- **签名**：`fn parseSimpleStringBytes(self: *SimpleJsonParser) ![]const u8`。
- **作用**：ASCII 快路径的字符串读取：只认无转义的纯 ASCII 串，直接借用输入字节。
- **实现**：吃掉开引号后扫到下一个 `"`，直接返回输入字节的借用切片（零拷贝）；遇到 `\`、控制字符（< 0x20）或非 ASCII（>= 0x80）以及未闭合都返回 `error.UnsupportedSimpleJson`，转交忠实解析器。
- **所有权 / 错误 / 调用**：返回的切片借自 `self.bytes`，不分配也不释放；调用方须在源文本存活期内用完。

### `SimpleJsonParser.parseInt32Number` (`src/exec/json_ops.zig:1200`)

- **签名**：`fn parseInt32Number(self: *SimpleJsonParser) !core.JSValue`。
- **作用**：ASCII 快路径的数字读取：只认能落进 i32 的整数，见到小数/指数就回退。
- **实现**：只认 i32 范围内的整数：前导 `-`、`0` 后不许再跟数字、非零首位不许是 `0`；后面出现 `.`/`e`/`E` 一律 `error.UnsupportedSimpleJson`。文本恰为 `-0` 时返回 `float64(-0.0)`，其余交 `core.value_format.parseAsciiInt(i32, ...)`，溢出/失败同样回退。 关键调用：`unicode.isAsciiDigitByte`、`core.value_format.parseAsciiInt`。
- **所有权 / 错误 / 调用**：不分配，只在输入字节上推进光标；返回立即数。`error.UnsupportedSimpleJson` 是回退信号而不是 JS 错误（小数点、指数、前导零、`parseAsciiInt` 溢出都走它），所以它永远不会变成 JS 异常。唯一调用方 `SimpleJsonParser.parseValue` 的数字臂（1108）。

### `SimpleJsonParser.skipWhitespace` (`src/exec/json_ops.zig:1221`)

- **签名**：`fn skipWhitespace(self: *SimpleJsonParser) void`。
- **作用**：跳过 JSON 的四种空白（字节版）。
- **实现**：`while (self.peek())` 循环，只对 `' '` / `\t` / `\n` / `\r` 推进 `index`，其他字节立即 return。
- **所有权 / 错误 / 调用**：不分配、不失败；快路径各解析体在每个语法位置前调它。

### `SimpleJsonParser.consumeLiteral` (`src/exec/json_ops.zig:1230`)

- **签名**：`fn consumeLiteral(self: *SimpleJsonParser, text: []const u8) bool`。
- **作用**：试着吃掉一段字面量（`true`/`false`/`null`），成功才推进光标。
- **实现**：先查剩余长度，再 `std.mem.eql` 比一整段；相等则 `index += text.len` 并返回 true，否则原地不动返回 false。
- **所有权 / 错误 / 调用**：不分配、不失败。调用方是 `SimpleJsonParser.parseValue` 的 `t`/`f`/`n` 三臂，返回 false 即 `error.UnsupportedSimpleJson` 回退。

### `SimpleJsonParser.consumeByte` (`src/exec/json_ops.zig:1237`)

- **签名**：`fn consumeByte(self: *SimpleJsonParser, byte: u8) bool`。
- **作用**：试着吃掉一个指定字节，成功才推进光标。
- **实现**：`peek()` 不等于目标就返回 false，相等则 `index += 1` 返回 true。
- **所有权 / 错误 / 调用**：不分配、不失败。既被 `expectByte` 包成「必须匹配」，也被 `parseObject`/`parseArray` 直接用作「可选匹配」（例如试探 `}` / `]`）。

### `SimpleJsonParser.expectByte` (`src/exec/json_ops.zig:1243`)

- **签名**：`fn expectByte(self: *SimpleJsonParser, byte: u8) !void`。
- **作用**：要求下一个字节正是 `byte`，否则让快路径回退。
- **实现**：薄包装 `consumeByte`，不匹配则 `error.UnsupportedSimpleJson`。
- **所有权 / 错误 / 调用**：不分配；唯一的 error 是 `error.UnsupportedSimpleJson`——快路径的回退信号，不会变成 JS 异常。调用方：`parseObject` 的 `{` / `:` / `,`、`parseArray` 的 `[` / `,`、`parseSimpleStringBytes` 的开引号。

### `SimpleJsonParser.peek` (`src/exec/json_ops.zig:1247`)

- **签名**：`fn peek(self: *const SimpleJsonParser) ?u8`。
- **作用**：看一眼光标处的字节，越界给 null。
- **实现**：`self.index >= self.bytes.len` 返回 null，否则 `self.bytes[self.index]`；不推进光标。
- **所有权 / 错误 / 调用**：不分配、不失败；快路径全部扫描循环的基元。

### `parseSimpleJsonValue` (`src/exec/json_ops.zig:1253`)

- **签名**：`fn parseSimpleJsonValue(rt: *core.JSRuntime, global: ?*core.Object, bytes: []const u8) !?core.JSValue`。
- **作用**：ASCII 快路径的对外包装：在给定字节上跑一遍 `SimpleJsonParser`。
- **实现**：栈上构造 `SimpleJsonParser{ .rt, .global, .bytes }` 并 `parser.parse()`；返回 null 表示「这段 JSON 超出快路径」。
- **所有权 / 错误 / 调用**：不分配。调用方：`parse`（正式路径）与同文件的 ASCII 数字分类单测。

### `objectPrototypeFromGlobal` (`src/exec/json_ops.zig:1272`)

- **签名**：`fn objectPrototypeFromGlobal(rt: *core.JSRuntime, global: ?*core.Object) ?*core.Object`。
- **作用**：给解析出的 JSON 对象定原型：按「realm class 表 → realm 缓存槽 → 全局 `Object.prototype`」三级取 `Object.prototype`。
- **实现**：`global` 为 null 直接 null（裸 runtime 解析出无原型对象）。先 `rt.contextForGlobal` 找到 realm 再 `ctx.classPrototypeObject(object)`；miss 则查 realm 缓存槽 `.object_prototype`；再 miss 才退到 `constructorPrototypeFromGlobal(rt, global, "Object")` 这条嵌入方兜底。
- **所有权 / 错误 / 调用**：只借用不拥有，返回的是 realm 里活着的原型对象。调用方：`JsonUnitParser.parseObject` 与 `SimpleJsonParser.parseObject`。

### `arrayPrototypeFromGlobal` (`src/exec/json_ops.zig:1281`)

- **签名**：`fn arrayPrototypeFromGlobal(rt: *core.JSRuntime, global: ?*core.Object) ?*core.Object`。
- **作用**：给解析出的 JSON 数组定原型：同样三级取 `Array.prototype`。
- **实现**：与 `objectPrototypeFromGlobal` 同构，只是查的是 `core.class.ids.array` / 缓存槽 `.array_prototype` / 构造器名 `"Array"`。
- **所有权 / 错误 / 调用**：只借用不拥有。调用方：两个解析器的 `parseArray`。

### `cachedRealmObject` (`src/exec/json_ops.zig:1290`)

- **签名**：`fn cachedRealmObject(rt: *core.JSRuntime, global: ?*core.Object, slot: core.object.RealmValueSlot) ?*core.Object`。
- **作用**：从 global 上的 realm 值缓存槽里取一个对象。
- **实现**：`global` 为 null 返回 null；`global_object.cachedRealmValue(rt, slot)` 取出 JSValue，再用 `core.value_semantics.objectFromValue` 把它还原成 `*core.Object`（不是对象就是 null）。
- **所有权 / 错误 / 调用**：只借用；缓存槽归 realm。调用方：`objectPrototypeFromGlobal` / `arrayPrototypeFromGlobal` 的第二级。

### `constructorPrototypeFromGlobal` (`src/exec/json_ops.zig:1300`)

- **签名**：`fn constructorPrototypeFromGlobal(rt: *core.JSRuntime, global: ?*core.Object, name: []const u8) ?*core.Object`。
- **作用**：最后一级原型兜底：从 global 上按名字找构造器再取它的 `prototype`，只在 realm class 表和缓存都没发布时用得上。
- **实现**：`rt` 参数未用；名字经 `core.atom.predefinedId(name, .string)` 变成预定义 atom（不是预定义名就 null），`getOwnDataObjectBorrowed` 取构造器、再取它的 `prototype` 自有数据属性；任何一步落空返回 null。注意这两次取值都只看**自有数据**属性，不会触发访问器。
- **所有权 / 错误 / 调用**：只借用不拥有、不分配。活的 realm 里 `JSON.parse` 的结果对象不应走到这条路上。

### `objectInStack` (`src/exec/json_ops.zig:1310`)

- **签名**：`fn objectInStack(stack: []const *core.Object, object: *core.Object) bool`。
- **作用**：非 VM `stringify` 的循环引用检测：线性查这个对象是否已在序列化栈上。
- **实现**：对 `stack` 逐个比指针相等。序列化深度通常很浅，没有用哈希表。
- **所有权 / 错误 / 调用**：只读不分配。调用方：`appendJsonArray` / `appendJsonObject`，命中即 `error.TypeError`（`Converting circular structure to JSON`）。

### `isCallableJsonOmittedObject` (`src/exec/json_ops.zig:1317`)

- **签名**：`fn isCallableJsonOmittedObject(object: *core.Object) bool`。
- **作用**：判断这个对象是不是「可调用因而被 JSON 省略」的那一类。
- **实现**：把所有函数载体 class 列全：`c_function`、`c_function_data`、`isAsyncFunctionResumeClass`、`c_closure`、`isBytecodeFunctionClass`（覆盖普通/generator/async/async-generator 四种字节码函数）、`bound_function`。同文件单测逐个 class id 验证过这张表不漏。
- **所有权 / 错误 / 调用**：只读不分配。调用方：`appendJsonValue` 与 `appendJsonObject`——命中后在数组槽写 `null`、在对象槽整条省略。

### `isArrayObject` (`src/exec/json_ops.zig:1345`)

- **签名**：`fn isArrayObject(value: core.JSValue) bool`。
- **作用**：判断一个值是不是数组对象，用来决定 replacer 是否提供属性名列表。
- **实现**：`refHeader()` + `is(.object)` 双查后取 `object.isArray()`；这是对象内部的数组标志，不做 proxy 穿透（非 VM 路径不支持 proxy replacer）。
- **所有权 / 错误 / 调用**：只读不分配。唯一调用方是 `stringify`，用它填 `StringifyOptions.has_property_list`。

### `stringifyPropertyList` (`src/exec/json_ops.zig:1352`)

- **签名**：`fn stringifyPropertyList(rt: *core.JSRuntime, replacer: core.JSValue) ![]core.Atom`。
- **作用**：非 VM 路径的 replacer 数组处理：把数组元素规范成去重后的属性名 atom 列表。
- **实现**：先把 replacer root 住；`refHeader()` / `is(.object)` / `object.isArray()` 三查有一不中就返回静态空切片 `&.{}`（非数组 replacer 在这条路径上不产生属性列表）。是数组则按 `object.arrayLength()` 逐下标 `object.getProperty(atomFromUInt32(index))` 取元素（每个元素另开一层 `rootValues`），交 `stringifyPropertyListAtom` 规范成 atom：返回 null 跳过，`atomListContains` 判重复也跳过，否则 `list.append`。最后 `list.toOwnedSlice` 交出。 用 `ValueRootFrame` / `rootValues` 钉住跨分配窗口的值。
- **所有权 / 错误 / 调用**：返回 `toOwnedSlice` 的 atom 数组，归调用方，由 `freePropertyList` 释放；列表在构建期用 `rootAtomList` 钉住（`getProperty` 可能触到 JS 访问器）。调用方是 `stringify`。

### `stringifyPropertyListAtom` (`src/exec/json_ops.zig:1388`)

- **签名**：`fn stringifyPropertyListAtom(rt: *core.JSRuntime, value: core.JSValue) !?core.Atom`。
- **作用**：把 replacer 数组里的一个元素规范成属性名 atom：字符串/数字直接 intern，String/Number 包装对象拆出内部值后重来，其余给 null 表示跳过。
- **实现**：字符串走 `String.internAtom`；int32 用 `formatInt64` 打成十进制再 `rt.internAtom`；f64 先特判 NaN / ±Infinity / `0` 的规范拼写，其余 `formatFiniteNumberAssumeCapacity`，再 intern。对象只认 String 与 Number 两个 class（Boolean 不算，符合 spec 对 replacer 数组的规定），取 `jsonPrimitiveWrapperValue` 后**递归**自己一次；其它值一律 null。
- **所有权 / 错误 / 调用**：`rooted_value` 与 `primitive` 进 `rootValues` 帧（intern 会分配）。返回的 atom 是裸 id，由调用方 `stringifyPropertyList` 收进列表并用 `rootAtomList` 钉住。error 只有 intern 的 OOM / `InvalidAtom`。调用方：`stringifyPropertyList`（1388）与自己的包装对象递归（1432）。

### `stringifyGap` (`src/exec/json_ops.zig:1426`)

- **签名**：`fn stringifyGap(rt: *core.JSRuntime, space: core.JSValue) !std.ArrayList(u8)`。
- **作用**：非 VM 路径的 space 处理：把数值/字符串（含 Number/String 包装对象）折成最多 10 个字符的缩进串。
- **实现**：数值臂把 `space` 夹到 [0,10] 后填等量空格；字符串臂追加其 UTF-8 字节，超过 10 字节直接截断（`out.items[0..10]`）。Number/String 包装对象先经 `jsonPrimitiveWrapperValue` 取内部值再走对应臂。 关键调用：`jsonPrimitiveWrapperValue`、`out.appendNTimes`、`core.string.appendValueUtf8`。 用 `ValueRootFrame` / `rootValues` 钉住跨分配窗口的值。
- **所有权 / 错误 / 调用**：返回的 `std.ArrayList(u8)` 归调用方（`stringify` 里 `defer gap.deinit`）。

### `atomListContains` (`src/exec/json_ops.zig:1468`)

- **签名**：`fn atomListContains(list: []const core.Atom, atom: core.Atom) bool`。
- **作用**：replacer 属性名去重用的线性查找。
- **实现**：逐个比 atom id 相等。列表一般很短，没有建索引。
- **所有权 / 错误 / 调用**：只读不分配。唯一调用方是 `stringifyPropertyList` 的去重判断（VM 路径的对应物是 `jsonAtomListContains`）。

### `freePropertyList` (`src/exec/json_ops.zig:1475`)

- **签名**：`fn freePropertyList(rt: *core.JSRuntime, list: []core.Atom) void`。
- **作用**：释放 `stringifyPropertyList` 交出来的 atom 数组。
- **实现**：非空才 `rt.memory.allocator.free(list)`——空列表是 `&.{}` 这个静态空切片，不能拿去 free。
- **所有权 / 错误 / 调用**：只释放 native 数组本身；列表里的 atom 不在这里处理（使用期间由 `rootAtomList` 报成根）。唯一调用方是 `stringify` 的 `defer`（163）。

### `appendIndent` (`src/exec/json_ops.zig:1479`)

- **签名**：`fn appendIndent(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), gap: []const u8, depth: usize) !void`。
- **作用**：非 VM `stringify` 的缩进输出：把 gap 串重复 `depth` 次写进缓冲。
- **实现**：朴素 `while` 循环 `appendSlice(gap)`，`depth` 为 0 时什么也不写。
- **所有权 / 错误 / 调用**：只可能返回分配失败。调用方：`appendJsonArray` / `appendJsonObject` 的换行分支（VM 路径的对应物是 `jsonAppendIndent`）。

### `defineData` (`src/exec/json_ops.zig:1484`)

- **签名**：`fn defineData(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue, enumerable: bool) !void`。
- **作用**：往对象上定义一条 writable=false、configurable=false 的数据属性，`rawJSON` 用它写 `rawJSON` 字段。
- **实现**：把对象值和属性值一起 root 住（`defineOwnProperty` 会分配 shape/属性表），再 `defineOwnProperty(atom_id, Descriptor.data(value, false, enumerable, false))`——三个 bool 依次是 writable / enumerable / configurable，只有 enumerable 由参数控制。
- **所有权 / 错误 / 调用**：值归对象，不在此释放。唯一调用方是 `rawJSON`：写完字段紧接着 `object.seal(rt)`。

### `appendJsonInputString` (`src/exec/json_ops.zig:1494`)

- **签名**：`fn appendJsonInputString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) !void`。
- **作用**：把 `JSON.parse` / `JSON.rawJSON` 的输入值在裸 runtime（无 VM、不能回调 JS）下摊成 UTF-8 字节。
- **实现**：按值形态逐条判：字符串走 `core.string.appendValueUtf8`；symbol 直接 `error.TypeError`；null / undefined / bool 写各自字面量文本；int32 走 `formatInt64`，f64 的 `0` 特判成 `'0'`、其余走 `formatFiniteNumberAssumeCapacity`；BigInt 走 `appendBigIntBase10`。对象只认 String/Number/Boolean/BigInt/Symbol 包装器——`jsonPrimitiveWrapperValue` 取出内部数据后递归一次；取不到或是别的对象一律 `error.TypeError`（不会去调 `toString`/`valueOf`）。
- **所有权 / 错误 / 调用**：只往调用方缓冲追加，不拥有它。`error.TypeError` 在 `rawJSON` 里被改判成 `error.SyntaxError`（对象输入），在 `parse` 里则原样上抛。调用方：`parse`、`parseWithRecord`、`rawJSON`。

### `JsonStringifyPropertyList.deinit` (`src/exec/json_ops.zig:1557`)

- **签名**：`fn deinit(self: JsonStringifyPropertyList, rt: *core.JSRuntime) void`。
- **作用**：释放 VM 路径 replacer 属性名列表占的 native 数组。
- **实现**：无条件 `rt.memory.allocator.free(self.items)`；`items` 的默认值是长度 0 的 `&.{}`，free 一个空切片是合法的——所以这里不需要非 VM 路径 `freePropertyList` 那次非空判断。
- **所有权 / 错误 / 调用**：只释放数组，atom 本身不在这里处理。唯一调用方是 `jsonStringifyCall` 的 `defer property_list.deinit(ctx.runtime)`（1890）。

### `deinitLengthIndexAtom` (`src/exec/json_ops.zig:1568`)

- **签名**：`fn deinitLengthIndexAtom(_: *core.JSRuntime, _: anytype) void`。
- **作用**：length-index atom 的占位释放钩子。
- **实现**：空函数：两个参数都丢弃，什么也不做（这类 atom 无需单独释放），只为让调用点保留对称的 `defer`。
- **所有权 / 错误 / 调用**：空函数：不分配也不释放，因为 `propertyAtomFromLengthIndex` 给出的下标 atom 不需要单独释放。三个调用点（`jsonInternalizeProperty` 的数组臂 1744、`jsonStringifyPropertyList` 的逐下标循环 2173、`jsonAppendArray` 2476）仍保留 `defer` 调它，这样将来若那种 atom 改成需要释放，只改这一处。

### `jsonParseCall` (`src/exec/json_ops.zig:1570`)

- **签名**：`pub fn jsonParseCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) !?core.JSValue`。
- **作用**：`JSON.parse` 的 VM 侧主体：把参数强转成字符串、解析，有 reviver 时再走一遍 internalize 树。
- **实现**：五个值（input/reviver/text/parsed/holder）一起 root 住。`toStringForAnnexB` 先把第一个参数变成字符串（可能回调 JS，因而要带 caller 帧）。reviver 不可调用时直接 `parse` 返回。有 reviver 则：先 `JsonRecordRoots.activate()`（**在解析之前**，此时还没有树可报——注册那次数组增长本身是个回收点），`parseWithRecord` 建出值+记录树后再把 `record_roots.record` 指向它；`defer` 里先把 provider 的指针清空再 `deinit` 树，保证「还在报」与「已释放」不重叠。随后建一个 holder 对象，把解析结果定义到空串键 `""` 上，构造 reviver 的 `CallSite`，交给 `jsonInternalizeProperty` 从根键开始走。对照 qjs js_json_parse 带活 `pr` 调 JS_ParseJSON3（quickjs.c:49834）。
- **所有权 / 错误 / 调用**：记录树是 native 内存，由本函数的 `defer` 释放；解析出的值交给 holder 后本地槽立刻清成 undefined。返回 null 会被 `jsonParseRecordCall` 收成 `error.TypeError`。调用方：`jsonParseRecordCall`（`JSON.parse` 入口）与 exec/module.zig 的 JSON 模块加载器。

### `jsonInternalizeProperty` (`src/exec/json_ops.zig:1674`)

- **签名**：`pub fn jsonInternalizeProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, holder_value: core.JSValue, key: core.Atom, reviver: core.JSValue, reviver_call: *CallSite, record: ?*const JsonParseRecord, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) HostError!core.JSValue`。
- **作用**：reviver walk 的递归体：对 `holder[key]` 先深入孩子、再带 `context` 调用一次 reviver，返回它的结果。
- **实现**：对照 internalize_json_property（quickjs.c:49708）。每个属性**只做一次** [[Get]]（quickjs.c:49722）取出 `value`。同值守卫（quickjs.c:49740）：记录里缓存的解析期值若与当前值 `sameValue` 不符（walk 中途被改，或重复键下记录的是首次出现值而属性是最后一次），就把 `active_record` 置空，于是这一支不再带 `source`。值是对象时分两路：数组按 `length`（经 `toLengthIndex`）逐下标递归，子记录取 `rec.arrayElement(index)`；非数组则**一次性**快照自有 string 键（`objectRestOwnKeys` + 逐个 `objectRestOwnPropertyDescriptor` 过滤可枚举、跳过公开 symbol），之后按这张定死的名单遍历——reviver 中途删/改属性不改变访问哪些名字（json#9 的 `del-mut` 用例要求被删的 `c` 仍被访问），子记录取 `rec.findObjectEntry(child_key)`。最后把 key 变成字符串值，只有「当前值不是对象」且记录还活着时才让 `jsonReviverContext` 造带 `source` 的 context（quickjs.c:49784），再 `reviver_call.callWithThis(holder, {key, value, context})`。
- **所有权 / 错误 / 调用**：五个值（holder、reviver、value、key_value、context）进 `rootValues` 帧。非数组分支里 `objectRestOwnKeys` 的键数组 `defer core.Object.freeKeys`，快照出的 `enumerable_keys` 是本地 `ArrayList`、`defer deinit`。`record` 只是指向记录树的借用指针，树由 `jsonParseCall` 持有与释放。返回的是 reviver 的返回值（owned，归调用方）。error set `HostError`：[[Get]]、descriptor 探测、reviver 调用都可能执行用户代码，它们抛出时 JS 异常已挂在 ctx 上、上传时收成 `error.JSException`；`toLengthIndex` 这类协助函数的裸 error 由上层 `materializeRuntimeError` 补。调用方：`jsonParseCall` 的根调用（1657）与 `jsonInternalizeChild` 的递归（1807）。

### `jsonInternalizeChild` (`src/exec/json_ops.zig:1763`)

- **签名**：`pub fn jsonInternalizeChild( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, holder_value: core.JSValue, holder: *core.Object, key: core.Atom, reviver: core.JSValue, reviver_call: *CallSite, record: ?*const JsonParseRecord, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) HostError!void`。
- **作用**：reviver walk 的一个孩子：递归求值后按结果「删属性」或「重新定义属性」。
- **实现**：internalize_json_property 循环体的忠实搬运（quickjs.c:49762-49782）。先递归 `jsonInternalizeProperty`（那一层自己做唯一的一次 [[Get]]，这里**不**预取）；返回 undefined 就 `deleteValueProperty`，否则 `jsonCreateDataProperty` 写回。holder 值、reviver 与 revived 三者全程 root。
- **所有权 / 错误 / 调用**：三个值（holder、reviver、revived）进 `rootValues` 帧；自身不分配。`record` 是借用指针。error set `HostError`，全部来自递归、`deleteValueProperty` 与 `jsonCreateDataProperty`——这三处都可能跑用户代码（proxy trap / 访问器），抛出时异常已挂好。调用方：`jsonInternalizeProperty` 的数组臂（1746）与对象臂（1770）。

### `jsonReviverContext` (`src/exec/json_ops.zig:1794`)

- **签名**：`fn jsonReviverContext(rt: *core.JSRuntime, global: *core.Object, record: ?*const JsonParseRecord) !core.JSValue`。
- **作用**：造 reviver 的第三个参数 `context` 对象：只有原始值且记录存活时才带 `source`。
- **实现**：先建一个以 realm `Object.prototype` 为原型的普通对象；`record` 非空且 tag 是 `primitive` 时，把记录里存的源文本 span（WTF-8 字节）用 `value_ops.createStringValue` 建成字符串，定义成可写/可枚举/可配置的 `source` 属性；其他 tag 什么也不加，于是 context 是个空对象。对照 quickjs.c:49784-49792 的 primitive source 分支。
- **所有权 / 错误 / 调用**：返回的对象是 GC 值；`p.source` 字节仍归记录树，这里只是复制成字符串。唯一调用方是 `jsonInternalizeProperty`，`record` 已由它的同值守卫筛过。

### `jsonCreateDataProperty` (`src/exec/json_ops.zig:1815`)

- **签名**：`pub fn jsonCreateDataProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, holder_value: core.JSValue, holder: *core.Object, key: core.Atom, value: core.JSValue, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) HostError!void`。
- **作用**：reviver 把结果写回 holder 的那一步：CreateDataProperty，失败静默吞掉。
- **实现**：holder 是 proxy 时走 `object_ops.createDataPropertyOrThrow`，并把它的 `error.TypeError` 吞成 return（规范这一步的失败不抛）。普通对象直接 `defineOwnProperty(Descriptor.data(value, true, true, true))`，`IncompatibleDescriptor` / `NotExtensible` / `ReadOnly` 三种拒绝同样静默返回，其余错误上传。
- **所有权 / 错误 / 调用**：值归 holder。唯一调用方是 `jsonInternalizeChild` 的非 undefined 分支。

### `jsonStringifyCall` (`src/exec/json_ops.zig:1845`)

- **签名**：`pub fn jsonStringifyCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) !?core.JSValue`。
- **作用**：`JSON.stringify` 的 VM 侧主体：处理 replacer/space、建 holder，再驱动序列化。
- **实现**：取 value/replacer/space 三个参数并 root。replacer 与 space 都是 undefined 时先试 `jsonStringifySimpleNoOptions` 快路径，返回非 null 就直接用。否则：`jsonStringifyPropertyList` 算数组 replacer 的属性名列表、`jsonStringifyGap` 算缩进串；replacer 可调用时在栈上初始化一个 `CallSite` 并放进 `JsonStringifyVmOptions`。建 holder 对象，把值定义到空串键上，开缓冲与循环检测栈，从根键 `jsonSerializeProperty`。缓冲为空表示值被省略，返回 undefined；否则 `createJsonStringValue`。
- **所有权 / 错误 / 调用**：property list、gap、buffer、stack 全部由本函数 `defer` 释放。返回 null 会被 `jsonStringifyRecordCall` 收成 `error.TypeError`。唯一调用方是 `jsonStringifyRecordCall`。

### `jsonStringifySimpleNoOptions` (`src/exec/json_ops.zig:1944`)

- **签名**：`fn jsonStringifySimpleNoOptions(rt: *core.JSRuntime, global: *core.Object, value: core.JSValue) SimpleJsonStringifyError!?core.JSValue`。
- **作用**：无 replacer 无 space 时的整段快路径：不建 holder、不走 VM 属性协议就把值序列化出来。
- **实现**：开局部缓冲与循环栈，调一次 `jsonAppendSimpleValue`，按三态结果收尾：`.appended` → `createJsonStringValue`；`.omitted` → undefined（值被省略）；`.fallback` → null，让 `jsonStringifyCall` 退回完整路径重来。
- **所有权 / 错误 / 调用**：缓冲与栈函数内释放；回退时已写进缓冲的内容随缓冲一起丢弃。唯一调用方是 `jsonStringifyCall` 的快路径判断。

### `jsonAppendSimpleValue` (`src/exec/json_ops.zig:1956`)

- **签名**：`fn jsonAppendSimpleValue( rt: *core.JSRuntime, global: *core.Object, buffer: *std.ArrayList(u8), value: core.JSValue, array_slot: bool, stack: *std.ArrayList(*core.Object), ) SimpleJsonStringifyError!SimpleJsonResult`。
- **作用**：快路径的值序列化递归体：能确定「不需要回调 JS」时就地写出，否则报 `.fallback`。
- **实现**：入口 `checkNativeStackOverflow` → `error.StackOverflow`（对应 qjs js_json_to_str 的 JS_ThrowStackOverflow，quickjs.c:50075；经 `runtimeErrorInfo` 变成可捕获的 InternalError）。随后逐形态判：undefined / symbol 在数组槽写 `null` 返回 `.appended`，否则返回 `.omitted`；null、字符串、bool、int32、其他数值（非有限写 `null`、`0` 写 `'0'`）都直接写出。BigInt 返回 `.fallback`（留给完整路径去抛 TypeError）。非对象的剩余形态写 `null`。对象：可调用 → `.fallback`；原型链上有 `toJSON`、有 exotic 方法或是 proxy（`jsonSimplePrototypeChainHasNoToJSON` 判）→ `.fallback`；否则数组走 `jsonAppendSimpleArray`、对象走 `jsonAppendSimpleObject`。
- **所有权 / 错误 / 调用**：`buffer` 与 `stack` 都借自 `jsonStringifySimpleNoOptions`，本函数只追加/压弹不拥有。返回的是 `.appended` / `.omitted` / `.fallback` 三态而不是错误——`.fallback` 是「这条路走不通，请用完整路径重来」的信号，唯一真正的错误是分配失败、深递归的 `error.StackOverflow` 和循环引用的 `error.TypeError`。调用方：`jsonStringifySimpleNoOptions`，以及 `jsonAppendSimpleArray` / `jsonAppendSimpleObject` 的递归。

### `jsonSimplePrototypeChainHasNoToJSON` (`src/exec/json_ops.zig:2018`)

- **签名**：`fn jsonSimplePrototypeChainHasNoToJSON(object: *core.Object) bool`。
- **作用**：快路径准入检查：整条原型链上都没有 `toJSON`、也没有 exotic/proxy 行为。
- **实现**：从对象自身沿 `getPrototype()` 往上走，任一层 `hasExoticMethods()` 或 `isProxy()` 即 false；任一层 `hasOwnProperty(toJSON)` 也是 false（哪怕它不可调用——快路径不做进一步判断，直接回退）。走到 null 原型返回 true。
- **所有权 / 错误 / 调用**：只读不分配、不触发访问器。唯一调用方是 `jsonAppendSimpleValue` 的对象分支。

### `jsonAppendSimpleArray` (`src/exec/json_ops.zig:2029`)

- **签名**：`fn jsonAppendSimpleArray( rt: *core.JSRuntime, global: *core.Object, buffer: *std.ArrayList(u8), object: *core.Object, stack: *std.ArrayList(*core.Object), ) SimpleJsonStringifyError!SimpleJsonResult`。
- **作用**：快路径的数组分支：只服务「纯 dense、无命名索引属性」的数组。
- **实现**：先记下缓冲起点 `start` 以便回滚。准入三查：有 exotic 方法或元素存储不是 `.dense` → `.fallback`；`arrayLength()` 超过实际 dense 槽数（有洞/被截断）→ `.fallback`；shape 上任何未删除的属性只要能解成数组下标（`arrayIndexFromAtom`）→ `.fallback`。`jsonObjectInStack` 命中即 `error.TypeError`（循环引用）。随后压栈、写 `[`、逐槽递归：`.omitted` 补 `null`（数组洞语义），`.fallback` 则把缓冲截回 `start` 并把回退传上去。全程无 gap（快路径只在无 space 时启用）。
- **所有权 / 错误 / 调用**：`buffer` / `stack` 借用；压栈用 `defer` 弹出，写坏的缓冲用 `errdefer buffer.shrinkRetainingCapacity(start)` 和显式的 `shrinkRetainingCapacity` 回滚到进入时的长度，所以回退不会留下半截文本。唯一调用方是 `jsonAppendSimpleValue` 的数组分支。

### `jsonAppendSimpleObject` (`src/exec/json_ops.zig:2068`)

- **签名**：`fn jsonAppendSimpleObject( rt: *core.JSRuntime, global: *core.Object, buffer: *std.ArrayList(u8), object: *core.Object, stack: *std.ArrayList(*core.Object), ) SimpleJsonStringifyError!SimpleJsonResult`。
- **作用**：快路径的对象分支：只服务 class 为普通 object、属性全是自有数据属性的对象。
- **实现**：准入：有 exotic 方法、是 proxy，或 `class_id != object` → `.fallback`；`jsonObjectInStack` 命中 → `error.TypeError`。压栈后直接遍历 `object.shapeProps()`（不建 ownKeys 快照）：跳过已删除/不可枚举的槽、公开 symbol 与私有 atom；遇到能解成数组下标的键、访问器属性、或 `asDataAt` 取不出数据值，就把缓冲截回 `start` 返回 `.fallback`。每条属性先记 `property_start`，写完 `"key":` 再递归值——`.omitted` 时把缓冲截回 `property_start` 抹掉刚写的键；`.appended` 才置 `emitted`。逗号由 `emitted` 控制，故省略的属性不会留下空洞逗号。
- **所有权 / 错误 / 调用**：`buffer` / `stack` 借用，回滚规则同 `jsonAppendSimpleArray`，另外多一个 `property_start` 用于抹掉「键已写出但值被省略」的半条属性。直接读 `shapeProps()` / `asDataAt()` 意味着全程不触发访问器、不分配 ownKeys 快照。唯一调用方是 `jsonAppendSimpleValue` 的对象分支。

### `jsonStringifyPropertyList` (`src/exec/json_ops.zig:2122`)

- **签名**：`pub fn jsonStringifyPropertyList( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, replacer: core.JSValue, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) !JsonStringifyPropertyList`。
- **作用**：VM 路径的数组 replacer 处理：按规范把元素规范成去重后的属性名 atom 列表。
- **实现**：`isArrayValue` 不成立就返回空的 `JsonStringifyPropertyList{}`（`has_property_list = false`）。否则按 `length` 属性（经 `toLengthIndex`）逐下标 `getValueProperty` 取元素——都是可观察的 [[Get]]，可能触发 proxy/访问器；每个元素交 `jsonStringifyPropertyListAtom` 规范成 atom，返回 null（不是 string/number/包装器）就跳过，`jsonAtomListContains` 判重复也跳过。最终 `toOwnedSlice` 并置 `has_property_list = true`——空数组 replacer 因此也会让结果变成 `{}`，与「没有 replacer」不同。
- **所有权 / 错误 / 调用**：返回的 `items` 归调用方，用 `JsonStringifyPropertyList.deinit` 释放；出错时 errdefer 释放列表。调用方：`jsonStringifyCall`。

### `jsonStringifyPropertyListAtom` (`src/exec/json_ops.zig:2164`)

- **签名**：`fn jsonStringifyPropertyListAtom( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) !?core.Atom`。
- **作用**：把一个 replacer 数组元素规范成属性名 atom；不是 string/number/其包装对象则返回 null 表示忽略。
- **实现**：先做准入判断：`isString()`、`value_ops.numberValue(...) != null`、或 `jsonIsStringOrNumberObject`（String/Number 包装对象），三者全不中直接 null。命中后统一 `toStringForAnnexB` 转成字符串（包装对象在这里才触发可观察的 `toString`），再 `string_object.internAtom` 得到 atom。
- **所有权 / 错误 / 调用**：atom 由 runtime 的 atom 表拥有。唯一调用方是 `jsonStringifyPropertyList` 的逐元素循环。

### `jsonIsStringOrNumberObject` (`src/exec/json_ops.zig:2188`)

- **签名**：`fn jsonIsStringOrNumberObject(value: core.JSValue) bool`。
- **作用**：判断值是不是 String 或 Number 包装对象——replacer 数组元素的准入条件之一。
- **实现**：`object_ops.objectFromValue` 取对象（非对象返回 false），再比 `class_id` 是否为 `string` / `number`。不查原型链、不做 proxy 穿透。
- **所有权 / 错误 / 调用**：只读不分配。唯一调用方是 `jsonStringifyPropertyListAtom` 的准入判断。

### `jsonAtomListContains` (`src/exec/json_ops.zig:2193`)

- **签名**：`fn jsonAtomListContains(items: []const core.Atom, atom: core.Atom) bool`。
- **作用**：VM 路径 replacer 属性名列表的去重查找。
- **实现**：逐个比 atom id 相等的线性扫描。
- **所有权 / 错误 / 调用**：只读不分配。唯一调用方是 `jsonStringifyPropertyList`（非 VM 路径的对应物是 `atomListContains`）。

### `jsonStringifyGap` (`src/exec/json_ops.zig:2200`)

- **签名**：`pub fn jsonStringifyGap( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, space: core.JSValue, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) !std.ArrayList(u8)`。
- **作用**：VM 路径的 `space` 参数处理：算出每层缩进用的 gap 字节串（最多 10）。
- **实现**：先拆包装对象并**递归**：Number 包装走 `toPrimitiveForNumber` + `toNumberValue`，String 包装走 `toStringForAnnexB`，Boolean 包装取内部值，各自再调自己一次。原始字符串：按 `resolveData()` 取前 10 个码元——latin1 直接按码点补成 1-2 字节 UTF-8；utf16 先把「切在代理对中间」的尾巴退一位（孤立高代理无法输出），再逐单元编码，成对代理合成码点，孤立代理跳过。数值：`@floor` 后夹到 [0,10] 个空格。其他形态给空 gap。
- **所有权 / 错误 / 调用**：返回的 `std.ArrayList(u8)` 归调用方释放（`jsonStringifyCall` 用 `defer gap.deinit`）。包装对象分支会回调 JS，因而要带 caller 帧。

### `jsonSerializeProperty` (`src/exec/json_ops.zig:2284`)

- **签名**：`pub fn jsonSerializeProperty( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, buffer: *std.ArrayList(u8), holder_value: core.JSValue, holder: *core.Object, key: core.Atom, array_slot: bool, stack: *std.ArrayList(*core.Object), options: JsonStringifyVmOptions, depth: usize, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) HostError!void`。
- **作用**：SerializeJSONProperty：取 `holder[key]`、依次施加 `toJSON` 与函数 replacer，再写出结果。
- **实现**：入口 `checkNativeStackOverflow` → `error.StackOverflow`（qjs js_json_to_str JS_ThrowStackOverflow，quickjs.c:50075，经 `runtimeErrorInfo` 变成 InternalError）。一次 `getValueProperty` 取值、`atoms.toStringValue` 把键变成字符串值。值是对象或 BigInt 时取 `toJSON` 属性，可调用就以该值为 this 调一次并用返回值替换。随后若 `options.replacer_call` 存在，以 holder 为 this 调 replacer（参数 key、value）再替换。最后交 `jsonAppendValue` 写出。注意 `holder` 形参本身在这里被显式丢弃（`_ = holder;`），属性访问一律走 `holder_value`。
- **所有权 / 错误 / 调用**：五个值（holder、replacer、value、key_value、toJSON）进 `rootValues` 帧；只往调用方的 `buffer` 追加，`stack` 借用。error set `HostError`：递归过深是**裸** `error.StackOverflow`（由 `runtimeErrorInfo` 变成 InternalError「stack overflow」），而 [[Get]]、`toJSON` 调用与 replacer 调用都可能跑用户代码，它们抛出时异常已挂好。调用方：`jsonStringifyCall` 的根属性（1923）、`jsonAppendArray` 的每个下标（2477）、`jsonAppendObject` 的每个键（2526）。

### `jsonAppendValue` (`src/exec/json_ops.zig:2339`)

- **签名**：`pub fn jsonAppendValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, buffer: *std.ArrayList(u8), value: core.JSValue, array_slot: bool, stack: *std.ArrayList(*core.Object), options: JsonStringifyVmOptions, depth: usize, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) !void`。
- **作用**：VM 路径的值写出：把已经过 `toJSON`/replacer 的值序列化进缓冲。
- **实现**：undefined / symbol 在数组槽写 `null`、否则写空串（空串即省略信号）；null 写 `null`；字符串走 `appendJsonStringValue`；bool 写字面量；数值非有限写 `null`、`0` 写 `'0'`、其余 `formatFiniteNumberAssumeCapacity`；裸 BigInt 直接 `error.TypeError`。对象分支按顺序判：raw_json 取 `rawJSON` 属性原样写出（不转义）；可调用写成省略/`null`；Number 包装走 `toPrimitiveForNumber` + `toNumberValue` 后同深度递归；String 包装走 `toStringForAnnexB` 后递归；Boolean 与 BigInt 包装取内部值递归（BigInt 递归后仍会撞上 TypeError）；`isArrayValue` 真走 `jsonAppendArray`，否则 `jsonAppendObject`。非对象的剩余形态写 `null`。
- **所有权 / 错误 / 调用**：五个值进 `rootValues` 帧；只往调用方的 `buffer` 追加。raw_json 臂那个 `raw_bytes` 临时列表 `defer deinit`，其余不分配 native 内存。error：裸 BigInt 是裸 `error.TypeError`；包装对象臂的 `toPrimitiveForNumber` / `toStringForAnnexB` 会跑用户代码，抛出时异常已挂好；其余是 OOM。调用方：`jsonSerializeProperty` 的收尾（2361）、自己的包装对象递归（2424、2427、2430、2433）。

### `jsonAppendArray` (`src/exec/json_ops.zig:2419`)

- **签名**：`pub fn jsonAppendArray( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, buffer: *std.ArrayList(u8), value: core.JSValue, object: *core.Object, stack: *std.ArrayList(*core.Object), options: JsonStringifyVmOptions, depth: usize, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) !void`。
- **作用**：VM 路径的数组写出：按 `length` 逐下标序列化成 `[...]`。
- **实现**：`jsonObjectInStack` 命中即 `error.TypeError`（循环引用），否则压栈并 `defer` 弹出。长度取自可观察的 `length` [[Get]] + `toLengthIndex`。逐下标经 `propertyAtomFromLengthIndex` 造键、以 `array_slot = true` 调 `jsonSerializeProperty`——所以每个元素都会各自过一遍 `toJSON` 与 replacer，被省略的元素写成 `null`。gap 非空时元素前换行 + `jsonAppendIndent(depth + 1)`，非空数组收尾再换行缩进到 `depth`。
- **所有权 / 错误 / 调用**：`rooted_value` 进 `rootValues` 帧；`stack` 压入自己、`defer` 弹出做循环检测；下标 atom 配一个 `deinitLengthIndexAtom` 的空 `defer` 保持对称。只往 `buffer` 追加。error：循环引用是裸 `error.TypeError`；`length` 的 [[Get]]、`toLengthIndex` 与每个元素的序列化都可能跑用户代码。唯一调用方 `jsonAppendValue` 的数组臂（2435）。

### `jsonAppendObject` (`src/exec/json_ops.zig:2461`)

- **签名**：`pub fn jsonAppendObject( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, buffer: *std.ArrayList(u8), value: core.JSValue, object: *core.Object, stack: *std.ArrayList(*core.Object), options: JsonStringifyVmOptions, depth: usize, caller_function: ?*const Bytecode, caller_frame: ?*Frame, ) !void`。
- **作用**：VM 路径的对象写出：按属性名列表或自有可枚举 string 键序列化成 `{...}`。
- **实现**：同样先查环、压栈。没有 replacer 属性列表时 `objectRestOwnKeys` 取键并逐个 `objectRestOwnPropertyDescriptor` 过滤出可枚举的（跳过公开 symbol），有列表则直接用列表。每条属性先把值序列化进**独立的子缓冲** `child`：长度为 0 表示该属性被省略，回滚 `buffer` 到 `before` 并 continue；否则按 `emitted` 补逗号、按 gap 换行缩进，写 `key` 与 `":"`/`": "` 分隔符，再把子缓冲整段接上。用子缓冲而不是直接写主缓冲，是因为「是否省略」只有序列化完才知道。gap 非空且写出过属性时收尾换行缩进。
- **所有权 / 错误 / 调用**：`rooted_value` 进 `rootValues` 帧，`stack` 压/弹同数组。`objectRestOwnKeys` 的键数组 `defer core.Object.freeKeys`（有属性列表时不取），`enumerable_keys` 与每条属性的子缓冲 `child` 各自 `defer deinit`——子缓冲是这条路径唯一的额外分配，用来判断属性是否被省略。error：循环引用是裸 `error.TypeError`；键枚举、descriptor 探测与每条属性的序列化都可能跑用户代码。唯一调用方 `jsonAppendValue` 的对象兜底臂（2437）。

### `jsonPrimitiveWrapperValue` (`src/exec/json_ops.zig:2526`)

- **签名**：`pub fn jsonPrimitiveWrapperValue(object: *core.Object) ?core.JSValue`。
- **作用**：取原始值包装对象（String/Number/Boolean/BigInt/Symbol）的内部数据槽。
- **实现**：一个 `switch` 覆盖 string / number / boolean / big_int / symbol 五个 class，直接返回 `objectData()`（槽为空即 null）；其他 class 一律 null。只读内部槽，不走属性查找、不回调 JS。
- **所有权 / 错误 / 调用**：返回的是借用的内部值；函数体没有 error 源也不用 runtime，所以签名已从 `!?JSValue` / 带 `rt` 收成 `?JSValue`。非 VM 路径原先那份逐字重复的私有副本 `primitiveValue` 已删，两条路径合并到这里，调用方共 7 处（`jsonStringifyGap`、`jsonAppendValue` 与非 VM 侧的 stringify 分支）。

### `jsonObjectInStack` (`src/exec/json_ops.zig:2538`)

- **签名**：`pub fn jsonObjectInStack(items: []const *core.Object, object: *core.Object) bool`。
- **作用**：VM 路径的循环引用检测：线性查对象是否已在序列化栈上。
- **实现**：逐个比指针相等。
- **所有权 / 错误 / 调用**：只读不分配。调用方：`jsonAppendArray`、`jsonAppendObject`、`jsonAppendSimpleArray`、`jsonAppendSimpleObject`；命中一律 `error.TypeError`。

### `jsonAppendIndent` (`src/exec/json_ops.zig:2545`)

- **签名**：`pub fn jsonAppendIndent(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), gap: []const u8, depth: usize) !void`。
- **作用**：VM 路径的缩进输出：把 gap 串重复 `depth` 次写进缓冲。
- **实现**：朴素 `while` 循环 `appendSlice(gap)`；`depth` 为 0 什么也不写。
- **所有权 / 错误 / 调用**：只可能返回分配失败。调用方：`jsonAppendArray` / `jsonAppendObject` 的换行分支。

### `S3DupKeyMajorProbe.trigger` (`src/exec/json_ops.zig:2560`)

- **签名**：`fn trigger(context: ?*anyopaque, size: usize) void`。
- **作用**：测试探针的分配回调：在解析中途的分配点强行跑一次 major GC 并计数。
- **实现**：`active` 为假直接返回；否则先把 `rt.memory.trigger_gc_fn/ctx` 摘掉（防重入）、`defer` 复位，再 `tryRunObjectCycleRemovalWithValueRoots(null, .engine_active)`，比较前后的 `gc.block_heap.mark_epoch`，变了就 `majors += 1`。
- **所有权 / 错误 / 调用**：只被同文件的 TGC S3-d 单测挂到 `rt.memory.trigger_gc_fn` 上；吞掉 GC 的错误，不进生产路径。


## `src/exec/date_ops.zig` — Date

构造、静态/原型记录、历法。VM 可观察的 ToNumber 留在显式调用环境；记录体尽量吃已强制转换的参数。对照 `set_date_field`（quickjs.c:55253）、构造（55403）、parse（55907）、`@@toPrimitive`（55964）。

setter 先经 `captureDateValueMs`（getTime 记录）抓 `[[DateValue]]`，再 coerce 字段——规范要求 t 在参数副作用之前捕获。`Date.UTC`/`parse`/`now` 走 `callDateStaticBody`。


### 类型

- `DateToPrimitiveHint`：`string` / `number` 两个成员，`dateToPrimitiveHint` 把 hint 字符串解码成它；`"default"` 归到 `.string`，qjs 的非标准 `"integer"` 归到 `.number`。
- `StaticMethod` / `ConstructorMethod` / `PrototypeMethod`：从 `core.host_function.builtin_method_ids.date` 再导出的记录 id 枚举（放在引擎核心，好让 VM 分派器不 import 本模块也能判构造 id）。`StaticMethod` 的 1/2/3 同时就是 `staticCall` 的选择子。
- `ExtendedPrototypeMethod`（enum(u32)，138..148）：只存在于 builtins 侧的记录 id，接在 `PrototypeMethod` id 空间之后——getUTCDay、七个 `setUTC*`、三个 `toLocale*`。QuickJS 给每个名字单独一条 JS_CFUNC_MAGIC_DEF 并用 `is_local` magic 位区分，这里改成独立 id，只有本文件产生和解码它们。
- `SetterSpan`（`{ first: usize, end: usize, is_local: bool }`）：`set_date_field` magic 的解码结果——覆盖字段区间 `[first, end)` 与「本地还是 UTC」。`setterSpan` 是 selector → span 的查表函数，`setDateFieldBody` 是消费方。
- `date_construct_ref`：常量 `NativeBuiltinRef{ .domain = .date, .id = ConstructorMethod.construct }`，`constructDateRecord` 用它进构造记录。
- `internal_entries`：comptime 生成的 `.date` domain 声明 + 分派表，全部指向同一个 `dateCall`，靠 `magic`（== id）区分。其中两条 `name` 为空的记录（`set_year_with_captured_ms` / `set_parts_with_captured_ms`）不装成 JS 属性，只能从引擎内部到达。
- `PosixTm` / `WindowsTm` / `HostTimeT`：宿主 `struct tm` 的 ABI 钉。`PosixTm` 是 glibc/musl 的十一字段布局（含 POSIX.1-2024 要求的 `tm_gmtoff` 与 `tm_zone`），`WindowsTm` 是 CRT 的九字段布局；`HostTimeT` 在 Windows 上固定 i64，其他平台取 `std.c.time_t`。配套 `extern "c"` 声明：`localtime_r` / `gmtime` / `localtime` / `mktime`。
- `TzAbbr`（`{ name, offset }`）与表 `js_tzabbr`：宽松日期解析认得的时区缩写及其分钟偏移（对照 quickjs.c:55722）。
- 历法常量表：`month_days`（12 个月的天数）、`month_names` / `day_names`（各 3 字节一组的英文缩写串，由 `monthName` / `dayName` 切片取用）。

### `constructDateRecord` (`src/exec/date_ops.zig:43`)

- **签名**：`fn constructDateRecord( ctx: *core.JSContext, prototype: ?*core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：把「已强制转换的参数 + 已解析的实例原型」交给记录表跑内建 Date 构造体。
- **实现**：用文件顶部固定的 `date_construct_ref`（domain `.date`、id `ConstructorMethod.construct`）调 `builtin_dispatch.callConstructRecord`，ctx 之外的函数对象/调用者帧一律传 null——这条构造记录只读 `args` 与 `new_target`。表返回 null 视作 `error.TypeError`。
- **所有权 / 错误 / 调用**：返回新建的 Date 对象值。唯一调用方是 `dateConstructWithPrototype` 的四条分支（0 参 / 1 参的 Date、字符串、数值 / 多参）。

### `callDateBody` (`src/exec/date_ops.zig:61`)

- **签名**：`pub fn callDateBody( ctx: *core.JSContext, this_value: core.JSValue, decoded_method_id: u32, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：把一个 Date **原型方法体**（参数已 coerce）经记录表的「无函数对象」臂跑一遍。
- **实现**：`decoded_method_id` 是内建 date body switch 用的 1..34 旧选择子，先经 `date_method_ids.encodePrototypeMethodId` 重编码成 `PrototypeMethod` 记录 id，再 `callInternalRecord`（func_obj、global、caller 帧全传 null，于是落进 `dateCall` 的引擎内部臂 → `dateInternalBodyCall` → `methodCallArgs`）。表返回 null 视作 `error.TypeError`。
- **所有权 / 错误 / 调用**：参数借用、返回值归调用方。调用方：`captureDateValueMs`（id 1 = getTime）、`dateSetTime`（id 24 = setTime）、`dateConstructWithPrototype` 的 Date-参数分支。

### `callDateStaticBody` (`src/exec/date_ops.zig:74`)

- **签名**：`pub fn callDateStaticBody( ctx: *core.JSContext, static_method_id: u32, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：把 `Date.UTC` / `Date.parse` / `Date.now` 的静态方法体（参数已 coerce）经记录表跑一遍。
- **实现**：`static_method_id` 直接就是 `StaticMethod` 枚举值 1/2/3，也正是 `staticCall` 的选择子，因此不需要再编码；`this` 传 undefined，func_obj/global/caller 帧传 null，同样走引擎内部臂。表返回 null 视作 `error.TypeError`。
- **所有权 / 错误 / 调用**：调用方：`dateStaticCall`（`Date.UTC` 的 VM 强转臂）。

### `captureDateValueMs` (`src/exec/date_ops.zig:85`)

- **签名**：`fn captureDateValueMs(ctx: *core.JSContext, this_value: core.JSValue) !f64`。
- **作用**：把 Date 实例的 `[[DateValue]]` 抓成 f64——规范要求 `t` 在 setter 参数副作用之前捕获。
- **实现**：用 `callDateBody(ctx, this_value, 1, &.{})` 走记录表的 `getTime` 体，再 `value_ops.numberValue`；取不到数就返回 NaN。 关键调用：`callDateBody`。
- **所有权 / 错误 / 调用**：不分配、不建根：`callDateBody` 跑的是 `getTime` body，结果是纯数值。error 只来自那次表调用（this 不是 Date 时 `methodCallArgs` 的 `expectDateObject` 给 `error.TypeError`）；数值取不出来按 NaN 而不是报错。调用方：`dateSetYear`（140）与 `dateCapturedSetterCall`（197），两处都必须在 coerce 参数之前调它——这正是它存在的理由。

### `callDateSetYearWithCapturedMs` (`src/exec/date_ops.zig:93`)

- **签名**：`fn callDateSetYearWithCapturedMs( ctx: *core.JSContext, this_value: core.JSValue, captured_ms: f64, year_number: f64, ) !core.JSValue`。
- **作用**：把 `setYear` 的「已捕获时间值 + 已 coerce 年份」经记录表的 captured-setter 臂跑一遍。
- **实现**：记录 id 取 `PrototypeMethod.set_year_with_captured_ms`；两个 f64 打包成 `args[0] = 捕获 ms`、`args[1] = 年份` 传进 `callInternalRecord`，由 `dateInternalBodyCall` 原样拆出来喂给 `setYearNumber`。
- **所有权 / 错误 / 调用**：这条记录在 `internal_entries` 里名字为空、不装成 JS 属性，只能从引擎内部到达。唯一调用方是 `dateSetYear`。

### `callDateSetPartsWithCapturedMs` (`src/exec/date_ops.zig:108`)

- **签名**：`fn callDateSetPartsWithCapturedMs( ctx: *core.JSContext, this_value: core.JSValue, decoded_method_id: u32, captured_ms: f64, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：把日期分量 setter（解码 id 25..31）的「已捕获时间值 + 解码后的 setter id + 已 coerce 字段」经记录表的 captured-setter 臂跑一遍。
- **实现**：记录 id 取 `PrototypeMethod.set_parts_with_captured_ms`。定长 `[6]core.JSValue` 打包：`[0]` 捕获 ms、`[1]` int32 的解码 setter id、`[2..]` 字段参数（`@memcpy`，最多 4 个，超出丢弃——按 `setterSpan` 各 setter 最多也只有 4 个字段）。`dateInternalBodyCall` 按同一布局拆包后调 `methodCallArgsWithCapturedMs`。
- **所有权 / 错误 / 调用**：同样是无名的引擎内部记录。唯一调用方是 `dateCapturedSetterCall`。

### `dateSetYear` (`src/exec/date_ops.zig:129`)

- **签名**：`pub fn dateSetYear( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Date.prototype.setYear` 的 VM 侧强转臂：先抓时间值再 coerce 年份，然后跑纯 body。
- **实现**：this 不是 Date 对象就返回 null（交给别的分派路径）。先 `captureDateValueMs` 抓 `[[DateValue]]`——规范要求 `t` 在参数副作用之前捕获；缺参按 undefined，`toNumberForDateMethod` 在 VM 环境里 coerce（可能跑用户 `valueOf`），取不到数按 NaN；最后 `callDateSetYearWithCapturedMs`。
- **所有权 / 错误 / 调用**：参数借用。返回 null 表示「this 不是 Date」，由调用方（Annex B setYear 的分派点）决定如何报错。

### `dateSetTime` (`src/exec/date_ops.zig:147`)

- **签名**：`pub fn dateSetTime( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Date.prototype.setTime` 的 VM 侧强转臂：coerce 时间参数后跑纯 body。
- **实现**：this 不是 Date 对象返回 null。不需要捕获旧时间值（setTime 整体覆盖），缺参按 undefined 走 `toNumberForDateMethod`，再 `callDateBody(ctx, this_value, 24, &.{time_value})`——24 是 setTime 的旧选择子，body 里的 `setTime` 会做 `timeClip`。
- **所有权 / 错误 / 调用**：参数借用。返回 null 表示 this 不是 Date。

### `dateStaticCall` (`src/exec/date_ops.zig:163`)

- **签名**：`pub fn dateStaticCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, method_id: u32, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Date.UTC` 的 VM 侧强转臂：在调用者环境里逐个 ToNumber 后跑纯静态体。
- **实现**：只认 `method_id == 1`（`Date.UTC`），其余一律返回 null 交给别的路径；命中后在 VM 环境里最多 coerce 前 7 个参数（`toNumberForDateMethod`），再把已强转的参数交给 `callDateStaticBody`。 关键调用：`coercion_ops.toNumberForDateMethod`、`callDateStaticBody`。
- **所有权 / 错误 / 调用**：`coerced_args` 是栈上的 `[7]core.JSValue`，不分配。返回 null 表示「不是 `Date.UTC`」，调用方 `call_runtime.zig` 会接着把 `parse`/`now` 交给 `callDateStaticBody`。

### `dateCapturedSetterCall` (`src/exec/date_ops.zig:183`)

- **签名**：`pub fn dateCapturedSetterCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, method_id: u32, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：日期分量 setter（setMilliseconds..setFullYear）的 VM 侧强转臂：先抓时间值，再按字段数精确 coerce。
- **实现**：只接 `method_id` 25..31（setMilliseconds..setFullYear）且 this 是 Date 对象，否则返回 null。先 `captureDateValueMs` 抓时间值，再按 selector 查出字段数（25→1、26→2、27→3、28→4、29→1、30→2、31→3），**只**coerce 前 `min(args.len, field_count)` 个参数——多余参数的 `valueOf` 不许跑——最后交 `callDateSetPartsWithCapturedMs`。 关键调用：`captureDateValueMs`、`coercion_ops.toNumberForDateMethod`、`callDateSetPartsWithCapturedMs`。 对照 quickjs.c:55265。
- **所有权 / 错误 / 调用**：`coerced_args` 是栈上的 `[4]core.JSValue`，不分配。返回 null 表示「不是 25..31 的 setter」或「this 不是 Date」，由调用方 `object_ops.datePrototypeMethod` 继续往下试（最终落到 `methodCallArgs` 或抛「not a Date object」）。

### `dateToJsonCall` (`src/exec/date_ops.zig:221`)

- **签名**：`pub fn dateToJsonCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Date.prototype.toJSON` 的实现体：非有限时间值给 null，否则调 this 上的 `toISOString`。
- **实现**：this 是 null/undefined 直接 `error.TypeError`。先 `toPrimitiveForNumber`（hint number）取原始值——注意这一步对任意对象都跑，不要求 this 是 Date；结果是数且非有限就返回 JS `null`。随后 `getValueProperty` 取 `toISOString`（可观察的 [[Get]]），不可调用 `error.TypeError`，可调用则以 this 为 receiver 无参调用并原样返回。
- **所有权 / 错误 / 调用**：`args` 被显式丢弃（规范里的 key 参数未用）。返回值即 `toISOString` 的结果，归调用方。

### `dateConstructWithPrototype` (`src/exec/date_ops.zig:245`)

- **签名**：`pub fn dateConstructWithPrototype( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, prototype: ?*core.Object, args: []const core.JSValue, ) !core.JSValue`。
- **作用**：`new Date(...)` 的 VM 侧强转臂：按参数个数完成规范要求的强制转换，再交构造记录。
- **实现**：0 参直接进记录（body 用当前时间）。1 参分两路：参数是对象时——是 Date 实例就 `callDateBody(..., 1, ...)` 取它的时间值再构造（不走 `valueOf`），否则 `toPrimitiveForAddition`（hint default）取原始值，字符串原样传给记录去 `parseDateString`，BigInt 抛 `TypeError`「cannot convert bigint to number」（对应 qjs JS_ToFloat64Free 的行为），其余 `toNumberValue`；参数不是对象时同样按 字符串 / BigInt / 数值 三分。>= 2 参则在 VM 环境里最多 coerce 前 7 个参数（`toNumberForDateMethod`，caller 帧传 null）再交记录，由 `constructDateFromParts` 按**本地**时间合成。
- **所有权 / 错误 / 调用**：`args` 借用，`coerced_args` 是栈上的 `[7]core.JSValue`；返回的是记录新建的 Date 对象值（owned，归调用方），本函数不注册显式 GC 根。错误：bigint 参数就地 `throwTypeErrorMessage`（挂好 JS 异常再返回 `error.TypeError`）；`toPrimitiveForAddition` / `toNumberForDateMethod` 会回调 JS，它们抛出时异常已挂好；记录返回 null 被 `constructDateRecord` 收成裸 `error.TypeError`。唯一调用方是 `class_init_ops.zig:151` 的 `Date` 构造臂。

### `dateToPrimitiveCall` (`src/exec/date_ops.zig:284`)

- **签名**：`pub fn dateToPrimitiveCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Date.prototype[Symbol.toPrimitive]` 的实现体：按 hint 决定 `toString`/`valueOf` 的先后。
- **实现**：this 不是对象先抛 `TypeError`「not an object」。hint 经 `dateToPrimitiveHint` 解码，解不出（非字符串或非法词）抛 `TypeError`「invalid hint」。`.string` 与 `.number` 分别以 `string_first = true/false` 调 `dateOrdinaryToPrimitive`。
- **所有权 / 错误 / 调用**：`args` 借用；返回的是用户 `toString`/`valueOf` 的结果（可能是新建字符串），归调用方。两处 `throwTypeErrorMessage`（this 不是对象、hint 非法）先把 JS 异常挂上再返回 `error.TypeError`；`dateOrdinaryToPrimitive` 那条 `error.TypeError` 则是**裸**的，消息由上层 `materializeRuntimeError` 补。调用方：`dateCall` 的 `PrototypeMethod.to_primitive` 臂（517）——该方法作为独立记录安装在 `standard_globals.zig:542`。

### `dateToPrimitiveHint` (`src/exec/date_ops.zig:304`)

- **签名**：`fn dateToPrimitiveHint(value: core.JSValue) ?DateToPrimitiveHint`。
- **作用**：把 `@@toPrimitive` 的 hint 字符串解码成内部枚举。
- **实现**：非字符串 hint 直接 null（调用方报 TypeError）；`"string"`/`"default"` → `.string`，`"number"`/`"integer"` → `.number`（`integer` 是 qjs 的非标准扩展），其余 null。 关键调用：`string_ops.stringValueUnitsEqualBytes`。 对照 quickjs.c:55964。
- **所有权 / 错误 / 调用**：纯函数，不分配、不回调 JS（`stringValueUnitsEqualBytes` 只比码元）。唯一调用方是 `dateToPrimitiveCall`：返回 null 就抛 TypeError「invalid hint」。

### `dateOrdinaryToPrimitive` (`src/exec/date_ops.zig:314`)

- **签名**：`fn dateOrdinaryToPrimitive( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, string_first: bool, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：OrdinaryToPrimitive 的 Date 版：按给定顺序试 `toString` / `valueOf`，都拿不到原始值就 TypeError。
- **实现**：`string_first` 为真时先 `toString` 后 `valueOf`，否则反序。每一步都走 `object_ops.callObjectToPrimitiveMethod`——它负责取方法、判可调用、调用并检查结果是否是原始值，返回 null 表示这一步不作数（方法不存在/不可调用/返回对象）。两步都落空返回 `error.TypeError`。
- **所有权 / 错误 / 调用**：不分配；`callObjectToPrimitiveMethod` 会真的调用用户的 `toString` / `valueOf`，它们抛出的异常原样上传。两步都拿不到原始值时返回**不带** pending exception 的 `error.TypeError`。唯一调用方 `dateToPrimitiveCall` 的两条 hint 臂（299-300）。

### `dateEntry` (`src/exec/date_ops.zig:440`)

- **签名**：`fn dateEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：为 `.date` domain 的记录表生成一条普通（非构造）记录项。
- **实现**：填 `name`/`length`/`id`，`magic` 直接取 `id`，`cproto` 为 `.generic_magic`，`native_function` 是 `genericMagicFunction(&dateCall)`——整个 domain 共用一个记录处理函数，靠 magic 区分。
- **所有权 / 错误 / 调用**：全 comptime 求值，不分配。只被 `internal_entries` 这张声明表使用；其中两条 `name` 为空的项是引擎内部的 captured-setter 记录，不会被安装成 JS 属性。

### `dateConstructorEntry` (`src/exec/date_ops.zig:453`)

- **签名**：`fn dateConstructorEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：为 `.date` domain 生成那条唯一的 Date 构造器记录项。
- **实现**：同 `dateEntry`，但 `cproto` 是 `.constructor_or_func_magic`、指针用 `constructorOrFunctionMagic(&dateCall)`，好让 `new Date(...)` 走构造分派进 `dateCall` 的构造臂。
- **所有权 / 错误 / 调用**：全 comptime 求值，不分配。`internal_entries` 里只有 `"Date"` 这一条用它。

### `dateCall` (`src/exec/date_ops.zig:469`)

- **签名**：`fn dateCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`.date` domain 唯一的记录处理函数：构造器、静态方法、`@@toPrimitive` 与全部原型方法都从这里按 magic 分流。
- **实现**：先 `nativeCall` 恢复 `NativeCall`；失败则 `error.TypeError`。有 `func_obj` 时取 `callableRealm` 并断言 realm 与 ctx 一致，否则沿用 `host_call.global`。随后按 `magic`（== domain 内 id）依次分派：构造 id 上看 `is_constructor`，是就 `constructWithPrototype(rt, args, new_target)`，否则 `Date(...)` 作函数返回当前时间字符串；`func_obj == null and global == null and !is_constructor` 是引擎内部臂，参数已 coerce，直接 `dateInternalBodyCall`（故意绕开 `object_ops.datePrototypeMethod` 以免递归回本记录）；接着是 `@@toPrimitive`、`Date.UTC`（最多 coerce 7 个参数）、`Date.parse`（VM 环境里 ToString 后 `parseDateString`）、扩展原型 id（`dateExtendedPrototypeCall`）、普通原型 id（`object_ops.datePrototypeMethod`），都不匹配则落到 `staticCall`。 关键调用：`builtin_dispatch.callableRealm`、`dateInternalBodyCall`、`coercion_ops.toNumberForDateMethod`、`string_ops.toStringForAnnexB`、`parseDateString`、`object_ops.datePrototypeMethod`。 对照 quickjs.c:55907。
- **所有权 / 错误 / 调用**：自身不分配；`args` / `this_value` 借自调用帧，返回值（数值、新建字符串或新建 Date 对象）归调用方。error set `HostError`：`nativeCall` 失败、缺 `callable_global`、`staticCall` 与 `datePrototypeMethod` 的 `error.TypeError` 都是裸 error，靠上层补 JS 异常；引擎内部臂还可能上传裸 `error.RangeError`（`toISOString` 遇 NaN 时间值），把它翻成「Date value is NaN」的地方是 `object_ops.zig:1178`，不在这里。它没有具名调用方：`internal_entries` 的全部 52 条都通过 `genericMagicFunction(&dateCall)`（构造器那条是 `constructorOrFunctionMagic`）指向它。

### `dateInternalBodyCall` (`src/exec/date_ops.zig:565`)

- **签名**：`fn dateInternalBodyCall(rt: *core.JSRuntime, id: u32, this_value: core.JSValue, args: []const core.JSValue) HostError!core.JSValue`。
- **作用**：引擎内部表调用的纯方法体入口：没有函数对象、参数已 coerce 时按记录 id 直接跑对应 body。
- **实现**：`set_year_with_captured_ms`：从 `args[0]`/`args[1]` 取捕获的 ms 与年份跑 `setYearNumber`；`set_parts_with_captured_ms`：`args[0]`=捕获 ms、`args[1]`=解码后的 setter id、`args[2..]`=字段参数，跑 `methodCallArgsWithCapturedMs`；扩展 id / 普通原型 id 解码后跑 `methodCallArgs`；其余（`StaticMethod` 的 1/2/3）跑 `staticCall`。结果统一 `@errorCast` 成 `HostError`。 关键调用：`setYearNumber`、`methodCallArgsWithCapturedMs`、`methodCallArgs`、`staticCall`。
- **所有权 / 错误 / 调用**：不分配；`args` 借用（captured-setter 臂直接在上面切片取 `args[2..]`），返回值归调用方。`@errorCast` 只是把纯 body 的窄 error set 收进 `HostError`：这些 `TypeError` / `RangeError` 都是**裸**的，本函数只拿到 `rt`、没有 ctx，也就不可能挂 pending exception。唯一到达方式是 `dateCall` 的 `func_obj == null and global == null and !is_constructor` 臂（512）。

### `dateExtendedPrototypeCall` (`src/exec/date_ops.zig:595`)

- **签名**：`fn dateExtendedPrototypeCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, method_id: u32, args: []const core.JSValue, ) HostError!core.JSValue`。
- **作用**：builtins 本地扩展记录 id（setUTC* / getUTCDay / toLocale*）的强制转换臂。
- **实现**：`setterSpan` 命中（setUTC* 系列）时先 `expectDateObject` + `dateValue` 捕获时间值（任一失败就抛 `TypeError`「not a Date object」），再只 coerce `min(args.len, span.end - span.first)` 个参数，交 `setDateFieldBody`；其余 id 直接跑 `methodCallArgs`，其 `error.TypeError` 转成同样的消息。 关键调用：`setterSpan`、`expectDateObject`、`dateValue`、`coercion_ops.toNumberForDateMethod`、`setDateFieldBody`、`methodCallArgs`。 注释对照 quickjs.c:55253。
- **所有权 / 错误 / 调用**：`coerced_args` 在栈上，不分配；返回的字符串/数值归调用方。两类错误处理不同：`expectDateObject` / `dateValue` 与 `methodCallArgs` 的 `error.TypeError` 都就地 `throwTypeErrorMessage`（挂好「not a Date object」再返回 error），`methodCallArgs` 的其它 error 原样上传；`toNumberForDateMethod` 会回调 JS，异常由它挂好。唯一调用方是 `dateCall` 的扩展 id 臂（542）。

### `prototypeMethodId` (`src/exec/date_ops.zig:628`)

- **签名**：`pub fn prototypeMethodId(name: []const u8) ?u32`。
- **作用**：把安装期看到的 `Date.prototype` 方法名映射到 `.date` domain 的记录 id。
- **实现**：一串 `std.mem.eql` 线性比对，命中即返回对应 `PrototypeMethod` 或 `ExtendedPrototypeMethod` 的枚举值（setUTC* / getUTCDay / toLocale* 三组落在扩展枚举上）；`toGMTString` 与 `toUTCString` 共用同一个 id（Annex B 别名）；全不匹配返回 null。
- **所有权 / 错误 / 调用**：纯函数，不分配。只在属性安装期按名字查一次，不在热路径上，所以没有建哈希表。

### `decodeExtendedPrototypeMethodId` (`src/exec/date_ops.zig:685`)

- **签名**：`fn decodeExtendedPrototypeMethodId(id: u32) ?u32`。
- **作用**：把扩展记录 id 映回旧的 body 选择子（延续 1..34 空间）：35 getUTCDay、36..42 setUTC*、43..45 toLocale*。
- **实现**：11 条 comptime 常量的 `switch`：138 getUTCDay → 35，139..145 的七个 setUTC* → 36..42，146..148 的三个 toLocale* → 43..45，其余 null。它与引擎核心的 `decodePrototypeMethodId` 是两张互不重叠的表，合起来盖满 body 用的 1..45 选择子空间。
- **所有权 / 错误 / 调用**：纯查表，不分配、不失败。两个调用方都在本文件：`dateCall`（540，决定是否转 `dateExtendedPrototypeCall`）与 `dateInternalBodyCall`（577，决定用哪个 body 选择子）。

### `call` (`src/exec/date_ops.zig:704`)

- **签名**：`pub fn call(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue`。
- **作用**：`Date(...)` 当普通函数调用：忽略参数，返回当前时间的 toString 文本。
- **实现**：丢弃 `args`，`getDateStringValue(rt, currentTimeMs(), 0x13)`（fmt=1 toString、part=3 日期+时间）。
- **所有权 / 错误 / 调用**：返回新建的字符串值（owned，归调用方）。唯一的 error 是 `getDateStringValue` 里 `String.createUtf8` 的 OOM——fmt=1 不会走到那条 `error.RangeError`。唯一调用方是 `dateCall` 构造 id 臂里 `is_constructor == false` 的那条（495），也就是 `Date(...)` 当普通函数调用。

### `construct` (`src/exec/date_ops.zig:711`)

- **签名**：`pub fn construct(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue`。
- **作用**：`Date` 构造的无原型入口：等价于原型取 null 的 `constructWithPrototype`。
- **实现**：直接 `constructWithPrototype(rt, args, null)`。
- **所有权 / 错误 / 调用**：返回新对象值。正式构造路径带原型（`dateCall` 的构造臂传 `new_target`），这条 `pub` 无原型入口供不关心原型的引擎内部/测试调用点使用。

### `constructWithPrototype` (`src/exec/date_ops.zig:715`)

- **签名**：`pub fn constructWithPrototype(rt: *core.JSRuntime, args: []const core.JSValue, prototype: ?*core.Object) !core.JSValue`。
- **作用**：Date 构造的纯 body：建对象并按参数个数算出 `[[DateValue]]`。
- **实现**：建一个 `class.ids.date` 对象（失败有 errdefer 销毁），再按参数个数定 `[[DateValue]]`：>= 2 个走 `constructDateFromParts`（本地时间）；恰 1 个时字符串走 `parseDateString`、Date 实例复制其时间值、其余 `toNumber` 后 `timeClip`（symbol/bigint 取不到数就 `error.TypeError`）；0 个用 `currentTimeMs()`。 可返回 `error.TypeError`。 关键调用：`core.Object.create`、`constructDateFromParts`、`setDateValue`、`parseDateString`、`dateValue`、`timeClip`。
- **所有权 / 错误 / 调用**：新建 `class.ids.date` 对象；后面任何一步失败都由 `errdefer core.Object.destroyFromHeader` 销毁它，成功则把这份 owned 引用随返回值交给调用方。`[[DateValue]]` 写的是 objectData 槽里的 f64 立即数，不涉及引用释放或写屏障。error：`Object.create` 的 OOM、`toNumber` 取不到数（symbol/bigint）与 `dateValue` 的裸 `error.TypeError`、`parseDateString` 的 OOM。调用方：`dateCall` 的构造臂（494，`new_target` 当原型）与无原型入口 `construct`（712）。

### `staticCall` (`src/exec/date_ops.zig:738`)

- **签名**：`pub fn staticCall(rt: *core.JSRuntime, method: u32, args: []const core.JSValue) !core.JSValue`。
- **作用**：`Date.UTC` / `Date.parse` / `Date.now` 三个静态方法的纯 body 分发器：selector 1/2/3 就是 `StaticMethod` 的枚举值。
- **实现**：按 selector 分派：1 → `utc`（UTC 组字段）、2 → `parse`、3 → `currentTimeMs()`，其余 `error.TypeError`。 关键调用：`utc`、`parse`。
- **所有权 / 错误 / 调用**：不分配（`utc` / `parse` 自己也只用栈上的字段数组），三条臂返回的都是数值。错误：未知 selector 返回裸 `error.TypeError`，`utc` 里参数取不到数（symbol/bigint）同样是裸 `error.TypeError`。调用方：`dateCall` 的 `Date.UTC` 臂（526）、兜底臂（551），以及引擎内部臂经 `dateInternalBodyCall`（585）。

### `methodCall` (`src/exec/date_ops.zig:749`)

- **签名**：`pub fn methodCall(rt: *core.JSRuntime, object_value: core.JSValue, method: u32) !core.JSValue`。
- **作用**：Date 原型方法体的无参便捷入口：把 selector 直接跑成结果。
- **实现**：转调 `methodCallArgs(rt, object_value, method, &.{})`——无参方法（getter 与各 `to*String`）的便捷形式。
- **所有权 / 错误 / 调用**：不分配。生产路径上的原型方法都经 `methodCallArgs`；这条 `pub` 无参形式只剩 `src/tests/exec.zig` 的构造用例在用（取 `getTime`，selector 1）。

### `methodCallArgs` (`src/exec/date_ops.zig:753`)

- **签名**：`pub fn methodCallArgs(rt: *core.JSRuntime, object_value: core.JSValue, method: u32, args: []const core.JSValue) !core.JSValue`。
- **作用**：Date 原型方法体的总入口：按旧的 1..45 选择子跑对应的 getter / setter / `to*String`，参数必须已经 coerce 过。
- **实现**：先 `expectDateObject` + `dateValue` 取出 `[[DateValue]]`（任一失败即 `error.TypeError`）。`setterSpan` 命中（25..31 与 36..42）就直接跑 `setDateFieldBody` 的原始参数版（`toNumber` 在那里面做）。其余按 selector：1/2 是 getTime/valueOf，直接回时间值；24 是 `setTime`；3..9 与 19 是本地 getter（get_date_field 的 n=0..6 与 getDay 的 n=7），12..18 与 35 是 UTC 孪生，22 是 getYear（n=0 且减 1900）；10/11/20/21/33/34/43/44/45 各对应一个 `getDateStringValue` magic（toISOString 0x23、toJSON 同 magic 但 NaN 给 JS null、toString 0x13、toUTCString 0x03、toDateString 0x11、toTimeString 0x12、toLocale* 0x33/0x31/0x32）；23 是 `setYear`；32 是 getTimezoneOffset（NaN 原样，否则 `getTimezoneOffsetForTime`）；其余 `error.TypeError`。对照 quickjs.c:55225、55996。
- **所有权 / 错误 / 调用**：`args` 借用；`to*String` 返回新建字符串（owned），其余臂返回数值。error：`expectDateObject` / `dateValue` / 未知 selector 的裸 `error.TypeError`，以及 `getDateStringValue` 在 toISOString（fmt=2）遇 NaN 时间值时的裸 `error.RangeError`——落成 JS 异常是上层（`object_ops.zig:1177-1178`）的事。调用方：`dateInternalBodyCall` 的两条解码臂（578、581）、`dateExtendedPrototypeCall` 的非 setter 臂（617）、无参便捷入口 `methodCall`（754）。

### `methodCallArgsWithCapturedMs` (`src/exec/date_ops.zig:792`)

- **签名**：`pub fn methodCallArgsWithCapturedMs(object_value: core.JSValue, method: u32, captured_ms: f64, args: []const core.JSValue) !core.JSValue`。
- **作用**：captured-setter 记录的分量 setter body：用调用方**先前**抓到的 `[[DateValue]]`（而不是现读）跑 `set_date_field`。
- **实现**：`expectDateObject` 校验 this，`setterSpan(method)` 解出字段区间（不是 setter 选择子就 `error.TypeError`），再把 `captured_ms` 连同已 coerce 的参数交 `setDateFieldBody`，`argc` 取 `args.len`。与 `methodCallArgs` 的 setter 臂唯一的差别就是时间值的来源：这里不调 `dateValue` 重读，所以参数 `valueOf` 里改掉的 `[[DateValue]]` 不会被看见——规范要求 t 在参数副作用之前捕获。
- **所有权 / 错误 / 调用**：不分配；`args` 借用，返回新时间值（数值）。error：`expectDateObject` 与非 setter selector 的裸 `error.TypeError`，以及 `setDateFieldBody` 里 `toNumber` 取不到数时的同名 error。唯一调用方是 `dateInternalBodyCall` 的 `set_parts_with_captured_ms` 臂（575），数据由 `dateCapturedSetterCall` → `callDateSetPartsWithCapturedMs` 打包进来。

### `setterSpan` (`src/exec/date_ops.zig:803`)

- **签名**：`fn setterSpan(method: u32) ?SetterSpan`。
- **作用**：把 setter 选择子解码成 `set_date_field` 的 (first_field, end_field, is_local) 区间；不是 setter 返回 null。
- **实现**：查表：25..31 是本地 setter（setMilliseconds 6..7、setSeconds 5..7、setMinutes 4..7、setHours 3..7、setDate 2..3、setMonth 1..3、setFullYear 0..3），36..42 是对应的 setUTC* 孪生（同区间、`is_local = false`），其余 null。
- **所有权 / 错误 / 调用**：纯常量查表，不分配、不失败。三个调用方：`dateExtendedPrototypeCall`（604，判断扩展 id 是不是 setUTC*）、`methodCallArgs`（760，原始参数 setter 臂）、`methodCallArgsWithCapturedMs`（798，null 即 `error.TypeError`）。

### `setDateFieldBody` (`src/exec/date_ops.zig:826`)

- **签名**：`fn setDateFieldBody(object: *core.Object, captured_ms: f64, args: []const core.JSValue, argc: usize, span: SetterSpan) !core.JSValue`。
- **作用**：`set_date_field` 的共享 body：把已捕获的时间值拆成字段、写入 setter 覆盖的那几个、再合回时间值。
- **实现**：先 `getDateFields(captured_ms, ..., span.is_local, span.first == 0)` 解出 9 个字段并记下是否成功（`res1`）；随后无条件 coerce 前 `min(args.len, span.end - span.first)` 个参数（副作用必须发生），任一非有限值把 `res` 置 false 并 `@trunc` 后写入 `fields[span.first + i]`。`res1` 为假（原时间值是 NaN）直接返回 NaN；否则只有 `res and argc > 0` 才用 `setDateFields` 重算，`argc == 0` 也会把日期设成 NaN。最后 `setDateValue` 落盘并返回新时间值。 可返回 `error.TypeError`。 关键调用：`getDateFields`、`toNumber`、`setDateFields`、`setDateValue`。 注释对照 quickjs.c:55253。
- **所有权 / 错误 / 调用**：`fields` 是栈上的 `[9]f64`，不分配；新时间值经 `setDateValue` 写回 `object` 的 objectData 槽，返回的就是同一个数值。唯一的 error 是 `toNumber` 取不到数（symbol/bigint 参数）时的裸 `error.TypeError`——它发生在部分字段已写进本地 `fields` 之后，但那时还没落盘，所以 `[[DateValue]]` 不会被改到一半。四个调用方：`dateExtendedPrototypeCall`（615）、`methodCallArgs`（763）、`methodCallArgsWithCapturedMs`（799）、`setYearNumberOnObject`（873）。

### `setYear` (`src/exec/date_ops.zig:849`)

- **签名**：`fn setYear(object: *core.Object, ms: f64, args: []const core.JSValue) !core.JSValue`。
- **作用**：Annex B `setYear` 的纯 body（原始参数版）：取出年份后交给共享的年份写入路径。
- **实现**：缺参按 NaN，有参走 `toNumber`（symbol/BigInt 返回 null → `error.TypeError`），再 `setYearNumberOnObject(rt, object, ms, year_number)`。
- **所有权 / 错误 / 调用**：只被 `methodCallArgs` 的选择子 23 调到；VM 路径走的是 `dateSetYear` → captured-setter 记录 → `setYearNumber`。

### `setYearNumber` (`src/exec/date_ops.zig:854`)

- **签名**：`pub fn setYearNumber(object_value: core.JSValue, captured_ms: f64, year_number: f64) !core.JSValue`。
- **作用**：captured-setter 记录的 `setYear` body：校验 this 是 Date 后写入年份。
- **实现**：`expectDateObject` 拿到对象（不是 Date 即 `error.TypeError`），再转 `setYearNumberOnObject`，捕获的 ms 与已 coerce 的年份原样传下去。
- **所有权 / 错误 / 调用**：唯一调用方是 `dateInternalBodyCall` 的 `set_year_with_captured_ms` 臂（由 `dateSetYear` 打包进来）。

### `setYearNumberOnObject` (`src/exec/date_ops.zig:862`)

- **签名**：`fn setYearNumberOnObject(object: *core.Object, ms: f64, year_number: f64) !core.JSValue`。
- **作用**：Annex B `setYear` 的共享写入体：两位数年份映到 1900..1999，再走一次 `set_date_field`。
- **实现**：有限年份先 `@trunc`，落在 [0,100) 的映射到 1900..1999，再以 `{first=0, end=1, is_local=true}` 跑一次 `setDateFieldBody`（argc 固定为 1）。 关键调用：`setDateFieldBody`。 注释对照 quickjs.c:56030。
- **所有权 / 错误 / 调用**：不分配；写入由 `setDateFieldBody` 完成（落到 objectData 槽）。年份进来时已是 f64，本函数不再 coerce，因此自身没有 error 源——`setDateFieldBody` 里的 `toNumber` 对 `float64` 一定成功。两个调用方：`setYear`（855，原始参数路径）与 `setYearNumber`（860，captured-setter 记录路径）。

### `setTime` (`src/exec/date_ops.zig:872`)

- **签名**：`fn setTime(object: *core.Object, args: []const core.JSValue) !core.JSValue`。
- **作用**：`Date.prototype.setTime` 的纯 body：整体覆盖 `[[DateValue]]`。
- **实现**：缺参按 NaN，有参 `toNumber`（取不到数 `error.TypeError`），`timeClip` 后 `setDateValue` 写进内部槽，返回 `numberResult(next_ms)`。不读旧时间值、不碰其他字段。
- **所有权 / 错误 / 调用**：不分配；`timeClip` 之后经 `setDateValue` 写进 objectData 槽，返回同一个数值。缺参按 NaN，不报错；`toNumber` 对 symbol/bigint 返回 null → 裸 `error.TypeError`。唯一调用方是 `methodCallArgs` 的 selector 24（767）；VM 路径由 `dateSetTime` 先 coerce 再经记录表进来。

### `getDateFieldValue` (`src/exec/date_ops.zig:881`)

- **签名**：`fn getDateFieldValue(ms: f64, n: usize, is_local: bool, is_get_year: bool) core.JSValue`。
- **作用**：从时间值解出第 n 个日历字段（`is_get_year` 时做 getYear 的 −1900 偏移）。
- **实现**：`getDateFields` 失败（时间值 NaN）返回 NaN，否则取 `fields[n]`，getYear 再减 1900，最后 `numberResult` 收窄。 注释对照 quickjs.c:55225。
- **所有权 / 错误 / 调用**：`fields` 在栈上，不分配、没有 error set——NaN 时间值走「返回 NaN」而不是报错。注意它并非无副作用的纯计算：`is_local` 时会经 `getDateFields` 调宿主 `localtime_r`。唯一调用方是 `methodCallArgs` 的各 getter 臂（769-775）。

### `utc` (`src/exec/date_ops.zig:889`)

- **签名**：`fn utc(args: []const core.JSValue) !core.JSValue`。
- **作用**：`Date.UTC` 的纯 body：把最多 7 个已 coerce 的字段按 **UTC** 合成时间值。
- **实现**：无参返回 NaN；否则字段默认 `{0,0,1,0,0,0,0}`，最多吃 7 个参数（`toNumber`，取不到数即 `error.TypeError`），交 `setDateFieldsChecked(..., is_local = false)`。 可返回 `error.TypeError`。 对照 quickjs.c:55480。
- **所有权 / 错误 / 调用**：`fields` 是栈上的 `[7]f64`，不分配。参数取不到数（symbol/bigint）即裸 `error.TypeError`；无参返回 NaN 不算错误。唯一调用方是 `staticCall` 的 selector 1（744）。

### `constructDateFromParts` (`src/exec/date_ops.zig:901`)

- **签名**：`fn constructDateFromParts(args: []const core.JSValue) !f64`。
- **作用**：多参 `new Date(y, m, ...)` 的字段合成：按本地时间把最多 7 个字段合回时间值。
- **实现**：与 `utc` 同形：默认字段 `{0,0,1,0,0,0,0}`、最多 7 个参数经 `toNumber`，但 `setDateFieldsChecked` 传 `is_local = true`——多参构造用的是**本地**时间。 可返回 `error.TypeError`。 对照 quickjs.c:55442。
- **所有权 / 错误 / 调用**：`fields` 是栈上的 `[7]f64`，不分配。参数里出现 symbol/BigInt 时 `toNumber` 返回 null → `error.TypeError`。唯一调用方是 `constructWithPrototype` 的 `args.len >= 2` 分支。

### `parse` (`src/exec/date_ops.zig:913`)

- **签名**：`fn parse(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue`。
- **作用**：`Date.parse` 的纯 body：把（已 coerce 的）参数当日期字符串解析成时间值。
- **实现**：缺参按 undefined。参数已是字符串直接 `parseDateString`；是**对象**直接给 NaN——VM 路径上的 ToString 由 `dateCall` 的 `StaticMethod.parse` 臂先做掉了，能走到这里的对象说明调用方没做强转，此处不再回调 JS；其余原始值用 `value_ops.toStringValue` 就地转成字符串再解析。对照 js_Date_parse（quickjs.c:55907）。
- **所有权 / 错误 / 调用**：返回数值；中途 `value_ops.toStringValue` 可能新建字符串，那是 GC 值、不手工释放。本函数不回调 JS——对象直接判 NaN 正是为了这条不变量。剩下的 error 只有 `toStringValue` 的 OOM（`parseDateString` 自身不分配）。唯一调用方是 `staticCall` 的 selector 2（745）。

### `getTimezoneOffsetForTime` (`src/exec/date_ops.zig:963`)

- **签名**：`fn getTimezoneOffsetForTime(time_ms: i64) i32`。
- **作用**：问宿主 OS：给定时刻（ms since epoch）的 UTC 与本地时间差，单位分钟。
- **实现**：先把毫秒截成秒。Windows 臂把同一时刻分别按 `gmtime`/`localtime` 解释再 `mktime` 相减；POSIX 臂在 32 位 `time_t` 上先把秒数夹到 i32 范围，再 `localtime_r` 取 `tm_gmtoff`，返回 `-tm_gmtoff / 60`。取不到时间结构时返回 0。 关键调用：`gmtime`、`localtime`、`mktime`、`localtime_r`。
- **所有权 / 错误 / 调用**：不分配、没有 error set——取不到时间结构一律返回 0。POSIX 臂的 `PosixTm` 是栈上的 `extern struct`，用的是 `localtime_r` 而不是 `localtime`，所以不依赖 CRT 的全局静态缓冲；Windows 臂的 `gmtime` / `localtime` 返回的才是 CRT 静态缓冲的借用指针，那里每取一次就立刻 `mktime` 掉、不跨调用持有。调用方：`getDateFields`（1055）、`setDateFields`（1144）、`methodCallArgs` 的 getTimezoneOffset（791）。

### `floorDiv` (`src/exec/date_ops.zig:997`)

- **签名**：`fn floorDiv(a: i64, b: i64) i64`。
- **作用**：向 −∞ 取整的整数除法：C 的 `/` 向零截断，而历法算术要的是向下取整。
- **实现**：一行 `@divFloor(a, b)`；qjs 的 floor_div（quickjs.c:55020）没有内建只好手写补偿，这里直接用 Zig 的内建。
- **所有权 / 错误 / 调用**：纯整数运算，不分配、不失败（调用点传的除数都是 4/100/400/3652425 这类正常量，不会除零）。调用方：`daysFromYear` 的三段闰年修正（1007-1008）与 `yearFromDays` 的初值估算（1021）。

### `daysFromYear` (`src/exec/date_ops.zig:1002`)

- **签名**：`fn daysFromYear(y: i64) i64`。
- **作用**：从 1970-01-01 数到 `y` 年 1 月 1 日的天数（1970 之前为负）。
- **实现**：`365 * (y - 1970)` 加三段闰年修正 `floorDiv(y-1969,4) - floorDiv(y-1901,100) + floorDiv(y-1601,400)`；三个偏移量的选法保证 1970 之前的年份也按向下取整算（与 quickjs.c:55053 同式）。
- **所有权 / 错误 / 调用**：纯整数运算，不分配、不失败。调用方：`yearFromDays` 的校正循环（1025）与 `setDateFields` 的 MakeDay（1112）。

### `daysInYear` (`src/exec/date_ops.zig:1008`)

- **签名**：`fn daysInYear(y: i64) i64`。
- **作用**：某一年的天数：平年 365、闰年 366。
- **实现**：把格里历三条闰年规则当 0/1 相加：`365 + (y%4==0) - (y%100==0) + (y%400==0)`（quickjs.c:55059）。取余用 `@rem` 而不是 `@mod`，对负年份而言「余数为 0」的判断同样成立。
- **所有权 / 错误 / 调用**：纯整数运算，不分配、不失败。调用方：`yearFromDays`（1028、1030）、`getDateFields` 给 2 月补天（1075）、`setDateFields` 的 MakeDay（1116）。

### `yearFromDays` (`src/exec/date_ops.zig:1015`)

- **签名**：`fn yearFromDays(days: *i64) i64`。
- **作用**：把「1970 以来的天数」换算成年份，同时把 `days` 就地改写成该年内的第几天。
- **实现**：先用平均年长估一个年份：`floorDiv(d * 10000, 3652425) + 1970`（3652425 = 400 年 146097 天 × 25）。随后循环校正：`d1 = d - daysFromYear(y)` 为负就退一年并加回 `daysInYear(y)`，否则比较 `d1` 与当年天数——小于就把 `days.*` 写成 `d1` 结束，不小于就减掉一年份并 `y += 1`。源码注释说明初值很准，通常只迭代一两次（quickjs.c:55064）。
- **所有权 / 错误 / 调用**：双输出：返回值是年份，而 `days: *i64` 被**就地改写**（进来是「1970 起的天数」，出去是「年内序号」）。不分配、不失败。唯一调用方 `getDateFields`（1070）依赖这个约定。

### `getDateFields` (`src/exec/date_ops.zig:1041`)

- **签名**：`fn getDateFields(dval: f64, fields: *[9]f64, is_local: bool, force: bool) bool`。
- **作用**：把时间值分解成 `[y, mon(0 起), d, h, m, s, ms, wd, tz]` 九个字段。
- **实现**：NaN 时间值在 `force` 未置时返回 false，置了则按 0 分解；`is_local` 时先用 `getTimezoneOffsetForTime` 把时刻挪到本地。之后逐级取模拆出 ms/s/min/h、用 `@mod(days + 4, 7)` 求星期、`yearFromDays` 求年，再按 `month_days`（闰年给 2 月补天）扣出月和日。 注释对照 quickjs.c:55090。
- **所有权 / 错误 / 调用**：`fields` 是**调用方**提供的 `[9]f64`，本函数只写不持有，自身不分配。返回 `false` 表示「时间值是 NaN 且 `force` 未置」，此时 `fields` 的内容不可用——三个调用点都先看返回值。没有 error set；但 `is_local` 时会经 `getTimezoneOffsetForTime` 调宿主 `localtime_r`。调用方：`setDateFieldBody`（832）、`getDateFieldValue`（887）、`getDateStringValue`（1191）。

### `timeClip` (`src/exec/date_ops.zig:1088`)

- **签名**：`fn timeClip(value: f64) f64`。
- **作用**：spec 的 TimeClip：把时间值夹进 ±8.64e15 的合法区间，超出即 NaN。
- **实现**：区间内返回 `@trunc(value) + 0.0`——加 0 是为了把 −0 折成 +0；区间外返回 NaN，NaN 输入也自动走这条（两个比较都为假）。对照 quickjs.c:55214。
- **所有权 / 错误 / 调用**：纯 f64 运算，不分配、不失败。调用方：`constructWithPrototype` 的单参数值臂（728）、`setTime`（878）、`setDateFields` 的收口（1146）。

### `setDateFields` (`src/exec/date_ops.zig:1096`)

- **签名**：`fn setDateFields(fields: *const [7]f64, is_local: bool) f64`。
- **作用**：MakeDay/MakeTime/MakeDate：把 7 个字段合回时间值。
- **实现**：先算 MakeDay：`ym = y + floor(m/12)`、月份取正余数，`ym` 越出 [−271821, 275760] 直接 NaN；再按 `daysFromYear` + 逐月累加得天数。MakeTime 用一个 `*volatile f64` 中转分/秒/毫秒的加法，保证求值顺序、阻止 FMA（与 qjs 一致）；MakeDate 同样经 volatile 相加。结果非有限即 NaN，`is_local` 时再加上该时刻的时区偏移，最后 `timeClip`。 注释对照 quickjs.c:55153。
- **所有权 / 错误 / 调用**：`fields` 是只读借用（`*const [7]f64`），不分配、不失败——所有异常情况都以 NaN 返回。`is_local` 时会调宿主时区函数。那个 `*volatile f64` 中转量是**语义**要求而不是优化：它固定住加法的求值顺序并阻止编译器合成 FMA，qjs 在同一处有相同处理与 fp-evaluation-order 的 test262 备注。调用方：`setDateFieldBody`（847）、`setDateFieldsChecked`（1158）、`dateParseBytes`（1334）。

### `setDateFieldsChecked` (`src/exec/date_ops.zig:1146`)

- **签名**：`fn setDateFieldsChecked(fields: *[7]f64, is_local: bool) f64`。
- **作用**：`set_date_fields_checked`：7 个字段先检查再截断，两位数年份补 1900，然后合成时间值。
- **实现**：7 个字段逐个检查：非有限直接 NaN，否则 `@trunc`；其中年份落在 [0,100) 时加 1900。随后交 `setDateFields`。 注释对照 quickjs.c:55206。
- **所有权 / 错误 / 调用**：就地改写调用方的 `fields` 数组（截断、年份补 1900），不分配。调用方：`utc`（`is_local = false`）与 `constructDateFromParts`（`is_local = true`）。

### `dayName` (`src/exec/date_ops.zig:1159`)

- **签名**：`fn dayName(wd: usize) []const u8`。
- **作用**：按星期序号取三字母英文缩写。
- **实现**：在常量串 `day_names`（`"SunMonTueWedThuFriSat"`）里取 `wd * 3` 起的 3 字节切片，不做越界检查——调用方给的是 `getDateFields` 算出的 0..6。
- **所有权 / 错误 / 调用**：返回的是静态常量的借用切片，不分配。调用方：`writeDateString` 的日期部分。

### `monthName` (`src/exec/date_ops.zig:1163`)

- **签名**：`fn monthName(mon: usize) []const u8`。
- **作用**：按月份序号取三字母英文缩写。
- **实现**：在常量串 `month_names`（`"JanFeb...Dec"`）里取 `mon * 3` 起的 3 字节切片；`mon` 是 0..11。
- **所有权 / 错误 / 调用**：返回静态常量的借用切片，不分配。调用方：`writeDateString` 的日期部分。

### `writeYearPadded4` (`src/exec/date_ops.zig:1170`)

- **签名**：`fn writeYearPadded4(w: *std.Io.Writer, y: i64) !void`。
- **作用**：把年份按 `snprintf("%0*d", 4 + (y < 0))` 的规则写进 writer：负号要算进 4 位宽度里。
- **实现**：负年份先写 `-` 再以 `{d:0>4}` 打印 `-y` 的**无符号**值，非负直接 `{d:0>4}`。之所以都先转成 `u64`：Zig 0.16 的 `std.fmt` 对有符号整数做零填充时会额外打出一个 `+`。
- **所有权 / 错误 / 调用**：只往调用方给的 `*std.Io.Writer` 写，不分配。error set 就是 writer 的容量错误；因为 `getDateStringValue` 给的是 64 字节固定缓冲、所有形态都放得下，所以那里直接 `catch unreachable`。三个调用点都在 `writeDateString` 的日期部分：fmt 0（1240）、fmt 1（1245）、fmt 3（1260）。

### `getDateStringValue` (`src/exec/date_ops.zig:1182`)

- **签名**：`fn getDateStringValue(rt: *core.JSRuntime, ms: f64, magic: u32) !core.JSValue`。
- **作用**：按 magic 的 fmt/part 把时间值渲染成 Date 字符串值。
- **实现**：magic 高 4 位是 fmt（0 toUTCString / 1 toString / 2 toISOString / 3 toLocale*），低 4 位是 part（1 日期、2 时间、3 两者）；`is_local` 取 `fmt & 1`。字段解不出来（NaN）时 fmt==2 报 `error.RangeError`，其余返回 "Invalid Date"。正常路径把字段转成整数后用固定 64 字节缓冲的 `std.Io.Writer` 交 `writeDateString`（长度是本地不变量，故 `catch unreachable`），再建字符串。 可返回 `error.RangeError`。 关键调用：`getDateFields`、`writeDateString`、`core.string.String.createUtf8`。 注释对照 quickjs.c:55290。
- **所有权 / 错误 / 调用**：64 字节缓冲在栈上，`String.createUtf8` 另复制一份；返回的是新建字符串值（owned，归调用方）。`error.RangeError` 只在 fmt == 2（toISOString）且时间值为 NaN 时出现，而且是**裸** error——翻成「Date value is NaN」的 JS 异常在 `object_ops.zig:1178`；其余 fmt 遇 NaN 返回字符串「Invalid Date」而不报错。另有 `createUtf8` 的 OOM。调用方：`call`（706）、`methodCallArgs` 的九个 `to*String` 臂（777-785）、`isoStringForInspector`（1749）。

### `writeDateString` (`src/exec/date_ops.zig:1216`)

- **签名**：`fn writeDateString( w: *std.Io.Writer, fmt: u32, part: u32, y: i64, mon: usize, d: u32, h: u32, m: u32, s: u32, msec: u32, wd: usize, initial_tz: i64, ) std.Io.Writer.Error!void`。
- **作用**：把已拆好的日历字段按 fmt/part 拼成 Date 的各种文本形态（toUTCString / toString / toISOString / toLocale*）。
- **实现**：两段独立开关。`part & 1` 写日期：fmt 0 是「Www, dd Mmm yyyy 」，fmt 1 是「Www Mmm dd yyyy」（part == 3 再补空格），fmt 2 是 ISO 年（0..9999 四位、负年 `-` 加六位、超 9999 `+` 加六位）接 `-MM-ddT`，fmt 3 是「MM/dd/yyyy」（part == 3 补「, 」）。`part & 2` 写时间：fmt 0 是「hh:mm:ss GMT」，fmt 1 在其后接 `±HHMM` 时区（先定符号再对 `tz` 取绝对值），fmt 2 是「hh:mm:ss.mmmZ」，fmt 3 是 12 小时制「hh:mm:ss AM/PM」（`@rem(h + 11, 12) + 1` 把 0 点映成 12）。对照 qjs get_date_string（quickjs.c:55290）。
- **所有权 / 错误 / 调用**：只往调用方的 writer 写，不分配；`initial_tz` 复制进本地 `tz` 后才改写，不影响调用方。error set 是 `std.Io.Writer.Error`：所有形态都短于 64 字节，因此唯一调用方 `getDateStringValue`（1212）直接 `catch unreachable`——这是本地不变量，不是引擎级的错误传输。

### `parseDateString` (`src/exec/date_ops.zig:1288`)

- **签名**：`fn parseDateString(value: core.JSValue) !f64`。
- **作用**：把一个 JS 字符串值折成 127 字节的 ASCII 缓冲，再交给日期字符串解析器。
- **实现**：非字符串直接 NaN。把码元拷进 128 字节缓冲并截到 127 字节：latin1 直接 memcpy，utf16 里 > 255 的单元按 U+2212 → `'-'`、其余 → `'x'` 折叠。补 NUL 后交 `dateParseBytes`。 关键调用：`dateParseBytes`。 注释对照 quickjs.c:55926。
- **所有权 / 错误 / 调用**：128 字节缓冲在栈上，不分配，输入串只被借用。不抛日期相关错误——解析失败就是 NaN。调用方：`dateCall` 的 `Date.parse` 臂、纯 body `parse`、以及 `constructWithPrototype` 的字符串参数分支。

### `dateParseBytes` (`src/exec/date_ops.zig:1311`)

- **签名**：`fn dateParseBytes(sp: [:0]const u8) f64`。
- **作用**：在 NUL 结尾的 ASCII 缓冲上跑两个日期解析器并做字段上限校验，返回时间值。
- **实现**：先试 `jsDateParseIsostring`，不成再试 `jsDateParseOtherstring`；任一成功后按 `field_max = {0,11,31,24,59,59}` 校验 1..5 号字段，并特判 24:00:00.000 之外的 24 点为非法。合法时把字段转 f64 交 `setDateFields(&fields1, is_local)`，再减去 `fields[8] * 60000` 的时区偏移；否则 NaN。 关键调用：`jsDateParseIsostring`、`jsDateParseOtherstring`、`setDateFields`。
- **所有权 / 错误 / 调用**：`fields` / `fields1` 都在栈上，不分配，也没有 error set——解析失败一律返回 NaN。两个解析器通过 `*[9]i32` 与 `*bool` 就地写出字段与「是否本地时间」。唯一调用方 `parseDateString`（1313），由它保证缓冲以 NUL 结尾。

### `stringSkipChar` (`src/exec/date_ops.zig:1336`)

- **签名**：`fn stringSkipChar(sp: [:0]const u8, pp: *usize, c: u8) bool`。
- **作用**：光标处正好是字符 `c` 就吃掉它，否则原地不动。
- **实现**：比 `sp[pp.*]`：相等则 `pp.* += 1` 返回 true，不等返回 false 且不动光标（quickjs.c:55495）。靠 `[:0]` 的 NUL 哨兵兜底，串尾读到 0 不会越界。
- **所有权 / 错误 / 调用**：通过 `pp: *usize` 就地推进调用方的光标，只读 `sp`，不分配、不失败。调用方：`stringGetTzOffset` 的可选 `:`（1455）、`jsDateParseIsostring` 的 `-` / `T` / `:`（1527-1545）、`jsDateParseOtherstring` 的时间冒号（1634、1638）。

### `stringSkipSpaces` (`src/exec/date_ops.zig:1345`)

- **签名**：`fn stringSkipSpaces(sp: [:0]const u8, pp: *usize) u8`。
- **作用**：跳过连续的 ASCII 空格，返回停下来的那个字符。
- **实现**：只认 `' '` 一种字符（不是通用空白），循环推进 `pp.*` 到非空格为止并返回它；串尾返回 NUL（quickjs.c:55505）。
- **所有权 / 错误 / 调用**：就地推进调用方光标，不分配、不失败。唯一调用方是 `jsDateParseOtherstring` 的主循环条件（1616）——返回 0 就是到了串尾、循环结束。

### `stringSkipSeparators` (`src/exec/date_ops.zig:1356`)

- **签名**：`fn stringSkipSeparators(sp: [:0]const u8, pp: *usize) u8`。
- **作用**：跳过宽松日期格式里的分隔符 `-` `/` `.` `,`。
- **实现**：循环吃掉这四种字符并返回停下来的字符（quickjs.c:55513）。
- **所有权 / 错误 / 调用**：就地推进调用方光标，不分配、不失败；返回值在唯一调用点被丢弃——`jsDateParseOtherstring` 每轮末尾（1690）只借它推进光标。

### `stringSkipUntil` (`src/exec/date_ops.zig:1368`)

- **签名**：`fn stringSkipUntil(sp: [:0]const u8, pp: *usize, stoplist: []const u8) u8`。
- **作用**：一路吃字符直到遇上 `stoplist` 里的某个字符或串尾。
- **实现**：用 `std.mem.indexOfScalar` 判停；额外的 `c != 0` 条件是刻意对齐 C 的 `strchr`——它也会匹配 NUL 终止符，所以串尾必停（quickjs.c:55521）。
- **所有权 / 错误 / 调用**：就地推进调用方光标，`stoplist` 只读借用，不分配、不失败。两个调用点都在 `jsDateParseOtherstring`：月名之后跳到下一个有意义的字符（1663，停表「0123456789 -/(」）、跳过整个无关单词（1688，停表「 -/(」）。

### `stringGetDigits` (`src/exec/date_ops.zig:1379`)

- **签名**：`fn stringGetDigits(sp: [:0]const u8, pp: *usize, pval: *i32, min_digits: usize, max_digits: usize) bool`。
- **作用**：按位数上下限读一个十进制整数字段（年、月、时、分…）。
- **实现**：从光标处连读数字累加 `v = v*10 + d`；`v >= 100000000` 直接失败（qjs 那条「人为限制 9 位」）；`max_digits` 非 0 时读满即停。读到的位数少于 `min_digits` 就返回 false。成功才写 `pval.*` 并推进 `pp.*`（quickjs.c:55529）。
- **所有权 / 错误 / 调用**：失败时既不改调用方光标也不写 `pval`，因此调用方可以放心地拿它试探下一种文法；成功才同时写这两个出参。不分配、不失败（用 bool 表示成败而不是 error）。调用方：`stringGetTzOffset`（1442、1457）、`jsDateParseIsostring` 的年/月/日/时/分/秒（1519-1546）、`jsDateParseOtherstring` 的数字与时间分支。

### `stringGetMilliseconds` (`src/exec/date_ops.zig:1400`)

- **签名**：`fn stringGetMilliseconds(sp: [:0]const u8, pp: *usize, pval: *i32) bool`。
- **作用**：读可选的小数秒，截断成毫秒。
- **实现**：光标处必须是 `.` 或 `,` 才处理；随后逐位 `msec += digit * mul`，`mul` 从 100 起每位除 10——第四位之后乘数已是 0，等价于截断到毫秒；最多读 9 位。只有真读到数字才写 `pval.*` 并推进光标，即「没有数字就不吃掉那个分隔符」。恒返回 true（quickjs.c:55552）。
- **所有权 / 错误 / 调用**：就地写调用方的 `pval` 与光标，不分配、不失败；返回值恒为 true，两个调用点（`jsDateParseIsostring` 1547、`jsDateParseOtherstring` 1640）都用 `_ =` 丢弃它。

### `upperAscii` (`src/exec/date_ops.zig:1424`)

- **签名**：`fn upperAscii(c: u8) u8`。
- **作用**：ASCII 小写转大写，其余字节原样返回。
- **实现**：`c >= 'a' and c <= 'z'` 时 `c - 'a' + 'A'`，否则原样（quickjs.c:55577）。只处理 ASCII 就够了——日期缓冲在 `parseDateString` 里已经把非 ASCII 码元折成了 `'x'`。
- **所有权 / 错误 / 调用**：纯函数，不分配、不失败。调用方：`matchLiteral`（1477，两边各过一遍）与 `findAbbrev`（1490）——两处的大小写不敏感匹配全靠它。

### `stringGetTzOffset` (`src/exec/date_ops.zig:1429`)

- **签名**：`fn stringGetTzOffset(sp: [:0]const u8, pp: *usize, tzp: *i32, strict: bool) bool`。
- **作用**：读时区偏移 `Z` / `±HH` / `±HHmm` / `±HH:mm`，换算成分钟。
- **实现**：首字符必须是 `+` / `-` / `Z`，否则失败；`Z` 直接给 0。数字段用 `stringGetDigits(min 1, max 0)` 读：strict 模式只接受 2 位或 4 位；位数超过 4 时反复 `/100` 砍到 4 位以内（对齐 qjs 的容错）；超过 2 位时低两位是分钟，否则分钟另看可选的 `:mm`——strict 模式下没有 `:` 就失败，即不接受 `±HH`。`hh > 23` 或 `mm > 59` 失败。最后 `tz = hh*60 + mm`，符号不是 `+` 就取反（quickjs.c:55581）。
- **所有权 / 错误 / 调用**：整个解析跑在本地副本 `p` 上，失败不改调用方光标；成功才一并写 `pp.*` 与 `tzp.*`。不分配、不失败。调用方：`jsDateParseIsostring` 的尾部偏移（1553，strict = true）与 `jsDateParseOtherstring` 的两处（1620、1644，strict = false）。

### `matchLiteral` (`src/exec/date_ops.zig:1469`)

- **签名**：`fn matchLiteral(sp: [:0]const u8, pp: *usize, s: []const u8) bool`。
- **作用**：大小写不敏感地匹配一个关键字，匹配成功才吃掉它。
- **实现**：逐字符 `upperAscii` 比对，全中才推进 `pp.*` 返回 true；中途不等立刻返回 false 且不动光标。串尾由 NUL 兜底（NUL 与任何字母都不相等）（quickjs.c:55622）。
- **所有权 / 错误 / 调用**：成功才就地推进调用方光标，`s` 只读借用，不分配、不失败。调用方：`stringGetTzAbbr` 遍历缩写表时（1585）与 `jsDateParseOtherstring` 的 AM/PM 分支（1664、1667）。

### `findAbbrev` (`src/exec/date_ops.zig:1480`)

- **签名**：`fn findAbbrev(sp: [:0]const u8, p: usize, list: []const u8, count: usize) ?usize`。
- **作用**：在「每 3 字节一条」的缩写表里做大小写不敏感查找，返回命中的条目序号。
- **实现**：外层遍历 `count` 条，内层比 3 个字符：比到第三个（`i == 2`）还相等就命中返回 `n`，任一不等换下一条。它**不**推进光标——那是调用方 `stringGetMonth` 自己 `pp.* += 3`（quickjs.c:55635）。
- **所有权 / 错误 / 调用**：只读 `sp` 与 `list`，不分配、不失败，也不改任何出参。唯一调用方 `stringGetMonth`（1499：表是 `month_names`、count 12）。

### `stringGetMonth` (`src/exec/date_ops.zig:1493`)

- **签名**：`fn stringGetMonth(sp: [:0]const u8, pp: *usize, pval: *i32) bool`。
- **作用**：认三字母英文月名，写出 1..12 的月份号。
- **实现**：`findAbbrev(sp, pp.*, month_names, 12)` 命中就写 `pval.* = n + 1` 并把光标推进 3，未命中返回 false 且不动光标（quickjs.c:55649）。注意写的是 **1 起**的月份，`jsDateParseOtherstring` 在收尾处统一减 1 变成 0 起。
- **所有权 / 错误 / 调用**：命中才写调用方的 `pval` 与光标，不分配、不失败。唯一调用方是 `jsDateParseOtherstring` 的月名分支（1661）。

### `jsDateParseIsostring` (`src/exec/date_ops.zig:1503`)

- **签名**：`fn jsDateParseIsostring(sp: [:0]const u8, fields: *[9]i32, is_local: *bool) bool`。
- **作用**：按 ISO-8601（也就是 `toISOString` 产出的形态）解析日期字符串。
- **实现**：`fields` 先初始化成 1970-01-01T00:00:00.000（只有 `fields[2]` 是 1，其余 0），`is_local` 置 false。年份两种写法：`±` 开头要求恰 6 位（`-000000` 被拒），否则恰 4 位。随后是可选的 `-MM`（月份 < 1 失败，读完减 1 变 0 起）与可选的 `-dd`。遇 `T` 就把 `is_local` 置 true——不带偏移的日期时间按**本地**时间解释，而纯日期形态保持 UTC；时/分读不全时把 `fields[3]` 写成 100 并返回 true，让上层的字段上限校验去拒。可选的 `:ss` 后再读可选小数秒。串尾若还有字符，就必须是合法时区偏移（strict），并把 `is_local` 清回 false。最后要求恰好停在串尾（quickjs.c:55662）。
- **所有权 / 错误 / 调用**：只读 `sp`，结果通过 `fields: *[9]i32` 与 `is_local: *bool` 就地写出；不分配、不失败（bool 表示成败）。失败时 `fields` 可能已被部分改写——唯一调用方 `dateParseBytes`（1319）在 `or` 的下一臂里让 `jsDateParseOtherstring` 从头重新初始化全部字段，所以不构成问题。

### `stringGetTzAbbr` (`src/exec/date_ops.zig:1578`)

- **签名**：`fn stringGetTzAbbr(sp: [:0]const u8, pp: *usize, offset: *i32) bool`。
- **作用**：认时区缩写（GMT / UTC / EST / CEST…）并给出分钟偏移。
- **实现**：顺序遍历 `js_tzabbr` 表，逐条用 `matchLiteral` 试；命中就写 `offset.*` 返回 true（光标由 `matchLiteral` 推进）。表序照抄 qjs：`UTC` 必须排在 `UT` 前面，否则「UTC」会被「UT」抢先匹配掉（quickjs.c:55747）。
- **所有权 / 错误 / 调用**：命中才写调用方的 `offset` 与光标，不分配、不失败。唯一调用方是 `jsDateParseOtherstring`（1670），命中后它把 `is_local` 置 false。

### `adjustTwoDigitYear` (`src/exec/date_ops.zig:1588`)

- **签名**：`fn adjustTwoDigitYear(v: i32) i32`。
- **作用**：宽松日期格式里的两位数年份补全：`< 100` 加 1900，`< 50` 再加 100。
- **实现**：无分支的两次条件加：`v + (v < 100 ? 1900 : 0) + (v < 50 ? 100 : 0)`——于是 0..49 → 2000..2049，50..99 → 1950..1999，>= 100 原样返回。
- **所有权 / 错误 / 调用**：纯函数。调用方：`jsDateParseOtherstring` 的年份识别分支。

### `jsDateParseOtherstring` (`src/exec/date_ops.zig:1595`)

- **签名**：`fn jsDateParseOtherstring(sp: [:0]const u8, fields: *[9]i32, is_local: *bool) bool`。
- **作用**：宽松日期解析：`toString` / `toUTCString` 以及各种人类写法（月名、斜杠日期、时区缩写、AM/PM、括号短语）。
- **实现**：字段先初始化成 2001-01-01、`is_local = true`，暂时判不出用途的数字攒进 `num[3]`。主循环每轮先跳空格，然后分支：`+` / `-` 开头——已经读到时间就当时区偏移（`is_local` 清 false），否则当带符号年份；数字开头——后面跟 `:` 就是时间（时:分[:秒[.毫秒]]，紧随的 `±` 再试一次时区），否则按「多于 2 位」或「不像日号（< 1 或 > 31）且还没有年份」判成年份（两位数经 `adjustTwoDigitYear` 补全），再不然攒进 `num`（满 3 个即失败）；其余依次试月名（之后 `stringSkipUntil` 跳到下一个数字/分隔符）、AM/PM（要求已有时间）、时区缩写、括号短语（按层数配对，未闭合失败）、右括号（直接失败），最后是「跳过一个单词」——只在还什么都没读到时允许。每轮末尾跳分隔符。收尾按 `num_index`（0..3）连同 `has_year` / `has_mon` 把攒下的数字派给年/月/日：3 个是「月 日 年」（年补两位），2 个按是否已有年/月分三种派法，1 个看有没有月名。月或日 < 1 失败；最后月份减 1 变 0 起（quickjs.c:55758）。
- **所有权 / 错误 / 调用**：只读 `sp`，结果写进调用方的 `fields` 与 `is_local`；本地状态（`num`、三个 has_ 标志、`num_index`）都在栈上，不分配、不失败（bool 表示成败）。唯一调用方 `dateParseBytes`（1320），只有在 ISO 解析失败之后才会试这条。

### `expectDateObject` (`src/exec/date_ops.zig:1724`)

- **签名**：`fn expectDateObject(value: core.JSValue) !*core.Object`。
- **作用**：校验一个值确实是 Date 实例并取出其 `*core.Object`，否则 `error.TypeError`。
- **实现**：`refHeader()` 取堆头（非堆值 `error.TypeError`），确认 `is(.object)`，再要求 `class_id == core.class.ids.date`；三关都过才返回 `*core.Object`。
- **所有权 / 错误 / 调用**：只借用不拥有。`error.TypeError` 在 `dateExtendedPrototypeCall` 里被改写成带消息的「not a Date object」，在 `methodCallArgs` 路径上则由上层统一转 JS 异常。

### `setDateValue` (`src/exec/date_ops.zig:1732`)

- **签名**：`fn setDateValue(object: *core.Object, ms: f64) void`。
- **作用**：把时间值写进 Date 对象的内部数据槽（`[[DateValue]]`）。
- **实现**：取 `object.objectDataSlot()` 直接存 `float64(ms)`。
- **所有权 / 错误 / 调用**：不分配；直接拿 `object.objectDataSlot()` 写一个 f64 立即数——槽里原来也是数值，所以没有旧值释放、也不需要写屏障。函数体没有 error 源，签名已从 `!void` 收成 `void`，未用的 `*JSRuntime` 首参也去掉了。调用方：`constructWithPrototype` 的三处、`setDateFieldBody`、`setTime`（原先的一行转发壳 `defineDateValue` 已删）。

### `isoStringForInspector` (`src/exec/date_ops.zig:1740`)

- **签名**：`pub fn isoStringForInspector(rt: *core.JSRuntime, object: *const core.Object) !?core.JSValue`。
- **作用**：CLI print 检视钩子：无副作用地给出 Date 的 toISOString 文本。
- **实现**：`dateValue` 失败或时间值为 NaN 时返回 null（调用方退回通用对象转储），否则 `getDateStringValue(rt, ms, 0x23)`。 关键调用：`getDateStringValue`。 注释对照 quickjs.c:14153。
- **所有权 / 错误 / 调用**：返回新建的字符串值（owned，归调用方）。`dateValue` 的 `error.TypeError` 被就地 `catch return null` 吞掉——检视器不能因为对象形状异常而抛异常；fmt=2 遇 NaN 的 `error.RangeError` 路径也被前面那次 NaN 判断挡掉了，于是剩下的 error 只有 `String.createUtf8` 的 OOM。唯一调用方 `print_inspector.zig:627`，它同样把 error 收成「不按 Date 打印」。

### `dateValue` (`src/exec/date_ops.zig:1746`)

- **签名**：`fn dateValue(object: *const core.Object) !f64`。
- **作用**：读出 Date 对象内部数据槽里的时间值；槽空或不是数就 `error.TypeError`。
- **实现**：`object.objectData()` 取内部数据槽（空即 `error.TypeError`），再用本文件的 `numberValue` 取 f64（不是 int32/float64 同样 `error.TypeError`）。不走属性查找。
- **所有权 / 错误 / 调用**：只读。调用方：`methodCallArgs`、`dateExtendedPrototypeCall`、`constructWithPrototype` 的 Date-参数分支、`isoStringForInspector`。

### `dateObjectFromValue` (`src/exec/date_ops.zig:1751`)

- **签名**：`fn dateObjectFromValue(value: core.JSValue) ?*core.Object`。
- **作用**：把一个值当成 Date 实例取出 `*core.Object`，不是 Date 就返回 null（不抛）。
- **实现**：与 `expectDateObject` 同三关（堆头、isObject、class_id == date），只是失败返回 null 而不是 error。
- **所有权 / 错误 / 调用**：只借用。唯一调用方是 `constructWithPrototype` 的单参分支——`new Date(d)` 要复制 `d` 的时间值而不是走它的 `valueOf`。

### `numberValue` (`src/exec/date_ops.zig:1759`)

- **签名**：`fn numberValue(value: core.JSValue) ?f64`。
- **作用**：把 int32 / float64 的 JSValue 取成 f64，其它类型返回 null。
- **实现**：`is(.int)` 时把 int32 转 f64，`is(.float64)` 时直接取，其余（含字符串、对象、NaN-box 之外的类型）返回 null。
- **所有权 / 错误 / 调用**：纯函数。文件内被 `dateValue` 与 `toNumber` 用作数值取值的第一关。

### `numberResult` (`src/exec/date_ops.zig:1765`)

- **签名**：`fn numberResult(value: f64) core.JSValue`。
- **作用**：回填数值结果：能无损表示成 i32（有限、整数、非 −0）就返回 int32，否则 float64。
- **实现**：四条件同时成立才回 int32：有限、`@floor(value) == value`、落在 i32 范围内、不是负零；否则 `float64`。负零必须保持 float64，因为 int32 表示不出它。
- **所有权 / 错误 / 调用**：纯函数。所有返回数值的 date body（getter、setter 的新时间值、`Date.UTC`、getTimezoneOffset）都经它收口。

### `toNumber` (`src/exec/date_ops.zig:1772`)

- **签名**：`fn toNumber(value: core.JSValue) ?f64`。
- **作用**：Date 纯函数体内部用的非 VM ToNumber：只处理不会回调 JS 的原始值。
- **实现**：symbol 与 bigint 返回 null，调用方据此抛 TypeError（对应 qjs `JS_ToFloat64` 的 "cannot convert bigint to number"）；数字直接取值，布尔 → 1/0，null → 0，undefined → NaN；字符串先经 `appendStringValueAscii` 写进 128 字节栈缓冲，去掉首尾空白后空串为 0，其余 `std.fmt.parseFloat`，失败为 NaN。 关键调用：`numberValue`、`appendStringValueAscii`、`std.fmt.parseFloat`。
- **所有权 / 错误 / 调用**：128 字节的 `scratch` 在栈上、用完即弃，不分配。`null` 是「这个值不能在无 VM 的路径上取数」的哨兵（symbol / bigint），各调用点统一翻成 `error.TypeError`，对应 qjs `JS_ToFloat64` 的「cannot convert bigint to number」。字符串分支不回调 JS，也不处理非 ASCII——`appendStringValueAscii` 失败就整体判 NaN。调用方：`constructWithPrototype`（728）、`setDateFieldBody`（839）、`setYear`（854）、`setTime`（877）、`utc`（900）、`constructDateFromParts`（912）。

### `appendStringValueAscii` (`src/exec/date_ops.zig:1793`)

- **签名**：`fn appendStringValueAscii(writer: *std.Io.Writer, value: core.JSValue) !void`。
- **作用**：把字符串值按 ASCII 写进固定 writer，供无 VM 的 `toNumber` 解析数字文本。
- **实现**：非字符串值静默返回（什么也不写）。latin1 直接 `writeAll` 整段；utf16 逐单元检查 `> 0x7f` 即 `error.TypeError`（非 ASCII 不可能是合法数字文本），否则窄化成字节写出。
- **所有权 / 错误 / 调用**：只往调用方给的固定缓冲 writer 写，不分配。唯一调用方是 `toNumber` 的字符串分支：写满 128 字节缓冲或遇非 ASCII 都会失败，此时 `toNumber` 直接判 NaN。

### `currentTimeMs` (`src/exec/date_ops.zig:1806`)

- **签名**：`fn currentTimeMs() f64`。
- **作用**：取宿主当前时间（epoch 毫秒）。
- **实现**：`std.c.gettimeofday`，秒 × 1000 加上微秒截断成的毫秒；调用失败返回 0。
- **所有权 / 错误 / 调用**：不分配、不失败：`gettimeofday` 返回非 0 时给 0 而不是报错。它是本文件唯一的「当前时间」来源，三个调用点：`call`（706，`Date()` 作函数）、`constructWithPrototype` 的 0 参分支（731）、`staticCall` 的 `Date.now`（746）。


## `src/exec/math_ops.zig` — Math

`internal_entries` 与实现并列，对照 `js_math_funcs`。一元/二元用 cproto `.f_f` / `.f_f_f` 叶子 + `mathOpCall` fallback（完整 ToNumber）。min/max 另有 `mathMinMaxDirect`：参数已是 int32/float64 时走 qjs `js_math_min_max` 快路径。

`Math.random` 是每 realm 的 xorshift64star（quickjs.c:47362）。`Math.sumPrecise` 用 bigint 精确和再圆回 f64。


### 类型

本文件没有自定义 struct / enum / error set——`Math` 是命名空间不是类，方法没有 `this`、没有实例状态，所以「类型」这一层全部借自引擎核心。需要记住的是这几样：

- 数值常量 `PI` / `E` / `LN10` / `LN2` / `LOG2E` / `LOG10E` / `SQRT1_2` / `SQRT2`：`std.math` 同名常量的再导出，`standard_globals.zig` 安装 `Math` 命名空间时直接读它们定义同名属性。
- 方法 id 空间：一组裸 `u32`（1..36 是数值方法，7/8 是 min/max，9 是 random；`sum_precise_method_id = 37` 是唯一有名字的常量）。id 同时就是记录的 `magic`，`preparedOpCall` / `call` / `mathUnaryInvoke` 的 switch 都按它分派——没有枚举，所以新增方法要同时改这几张 switch，`mathUnaryNative` 里那句 `@compileError("unsupported unary Math cproto id")` 是唯一的编译期守卫。
- `internal_entries`：`.math` domain 的声明 + 分派表，顺序即属性定义顺序。表项分四种形状：`.f_f` 一元叶子（`mathUnaryEntry`）、`.f_f_f` 二元叶子（`mathBinaryEntry`）、`.generic_magic` 共享记录（`mathOpEntry`，含 min/max 额外挂的 `managed` exec-direct 臂）、以及 `sumPrecise` 那条独立 handler。叶子项的 `fallback_function` 一律是 `mathOpCall`。
- `core.host_function.NativeF64Fn` / `NativeF64F64Fn`：叶子函数指针类型，`mathUnaryNative` / `mathBinaryNative` 按 comptime id 生成实例。
- `bignum.BigInt`（`libs/bigint.zig`）：`Math.sumPrecise` 的精确求和把每个 f64 换算成「值 × 2^1074」的整数后用它累加，再 `scaledIntegerToF64` 圆回 f64。
- 文件内别名：`HostError`（= `exceptions.HostError`）、`toPrimitiveForNumber` / `toUint32Number`（= `coercion_ops` 同名函数）。

### `mathOpEntry` (`src/exec/math_ops.zig:75`)

- **签名**：`fn mathOpEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：为记录表生成一条「只走共享记录处理函数、没有 f64 叶子」的 `Math.*` 项（`hypot`/`random`/`imul`/`clz32` 以及 min/max 的底座）。
- **实现**：转发 `mathEntryWithHandler(name, length, id, &mathOpCall)`：整个数值 `Math.*` 家族共用这一个记录处理函数。
- **所有权 / 错误 / 调用**：全 comptime 求值，不分配。使用者：`internal_entries` 里的 `hypot` / `random` / `imul` / `clz32`，以及 `mathMinMaxEntry` 拿它当底座。

### `mathMinMaxEntry` (`src/exec/math_ops.zig:82`)

- **签名**：`fn mathMinMaxEntry(comptime name: []const u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：为 `Math.min` / `Math.max` 生成记录项：共享记录 + 一条 exec-direct 热臂。
- **实现**：先 `mathOpEntry(name, 2, id)` 造出共享记录，再把 `entry.managed` 指到 `mathMinMaxDirect`，给 min/max 加一条 exec-direct 热臂。 注释对照 quickjs.c:46952。
- **所有权 / 错误 / 调用**：全 comptime 求值，不分配。只被 `internal_entries` 的 `min` / `max` 两条使用；同文件单测断言这两条的 generic handler 是 `mathOpCall`、`managed` 是 `mathMinMaxDirect`。

### `mathMinMaxDirect` (`src/exec/math_ops.zig:93`)

- **签名**：`noinline fn mathMinMaxDirect( ctx: *core.JSContext, this_value: core.JSValue, argv: [*]const core.JSValue, argc: u32, entry: *const core.NativeEntry, _: ?*core.Object, ) callconv(.c) core.JSValue`。
- **作用**：`Math.min` / `Math.max` 的 exec-direct 臂（`js_call_c_function` 形状）：参数已是 int32/float64 时走 qjs `js_math_min_max`（quickjs.c:46952）；否则退回 `preparedOpCall` 的完整 ToNumber。
- **实现**：忽略 `this`。`is_max = entry.magic == 8`（qjs magic：8=max，7=min）。`mathMinMaxNumberFast` 命中即返回。miss 时无 global → `hostErrorToValue(InvalidBuiltinRegistry)`，否则 `hostResultToValue(preparedOpCall(..., 8 or 7, args))`。ToPrimitive/ToNumber 顺序与异常留在 generic 路径。
- **所有权 / 错误 / 调用**：`mathMinMaxEntry` 把它填进 `InternalEntry.managed`。返回值已是 JS Number / exception sentinel。

### `mathMinMaxNumberFast` (`src/exec/math_ops.zig:116`)

- **签名**：`pub fn mathMinMaxNumberFast(args: []const core.JSValue, is_max: bool) ?core.JSValue`。
- **作用**：`Math.min`/`Math.max` 的纯数值快路径：参数全是 int32/float64 时直接出结果，否则返回 null 让调用方走 ToNumber。
- **实现**：无参返回 ∓Infinity（max 取 −inf、min 取 +inf）。首参是 int32 时先用 `@max`/`@min` 折整数前缀，全程都是 int32 就返回 `int32`；遇到第一个非 int32 参数转 f64 继续走浮点臂。浮点臂按 qjs 规则：一旦结果已是 NaN 就不再更新（NaN 粘滞），否则用带 ±0 规则的 `fmax`/`fmin`。任何既非 int32 也非 float64 的参数（布尔、null、undefined、字符串、对象…）立即返回 null。结果经 `value_ops.numberToValue` 收窄，整值 double 会塌回 int32。 注释对照 quickjs.c:46952。
- **所有权 / 错误 / 调用**：纯函数：只读借来的 `args` 切片，不分配、不回调 JS，所以没有 error set——miss 用 `null` 表示。唯一生产调用方是同文件的 `mathMinMaxDirect`（math_ops.zig:104），另有本文件单测逐条比对 qjs `js_math_min_max` 的语义。

### `mathEntryWithHandler` (`src/exec/math_ops.zig:149`)

- **签名**：`fn mathEntryWithHandler( comptime name: []const u8, comptime length: u8, comptime id: u32, comptime handler: anytype, ) core.host_function.InternalEntry`。
- **作用**：构造一条走 `generic_magic` 记录处理函数的 `Math.*` `InternalEntry`。
- **实现**：填 `name`/`length`/`id`，`magic` 取同一个 `id`，`cproto` 为 `.generic_magic`，`native_function` 是 `genericMagicFunction(handler)`。
- **所有权 / 错误 / 调用**：comptime 求值的表项构造器，不分配、不失败。调用方：`mathOpEntry`（75，数值家族统一用 `mathOpCall`），以及 `internal_entries` 里 `sumPrecise` 那条直接指定自己 handler 的表项（72）。

### `mathUnaryEntry` (`src/exec/math_ops.zig:165`)

- **签名**：`fn mathUnaryEntry(comptime name: []const u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：为一元数值 `Math.*`（abs/floor/sqrt/sin/log2…）生成 `.f_f` 叶子记录项。
- **实现**：`length = 1`、`magic = id`，`cproto` 是 `.f_f`，`native_function` 直接挂 `mathUnaryNative(id)` 这个 f64→f64 叶子；`fallback_function` 指向 `mathOpCall`，参数不是纯数值时由它跑完整 ToNumber。
- **所有权 / 错误 / 调用**：全 comptime 求值，不分配。`internal_entries` 里 28 条一元方法用它；`mathUnaryNative(id)` 里的 `@compileError` 保证新增 id 必须同步登记，否则编译期就失败。

### `mathBinaryEntry` (`src/exec/math_ops.zig:177`)

- **签名**：`fn mathBinaryEntry(comptime name: []const u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：为二元数值 `Math.*`（`pow`、`atan2`）生成 `.f_f_f` 叶子记录项。
- **实现**：`length = 2`、`magic = id`，`cproto` 是 `.f_f_f`，`native_function` 挂 `mathBinaryNative(id)`（f64,f64→f64 叶子），`fallback_function` 同样是 `mathOpCall`。
- **所有权 / 错误 / 调用**：全 comptime 求值，不分配。`internal_entries` 里只有 `pow`（id 6）与 `atan2`（id 17）两条用它，`mathBinaryNative` 对其他 id 直接 `@compileError`。

### `mathUnaryNative` (`src/exec/math_ops.zig:189`)

- **签名**：`fn mathUnaryNative(comptime id: u32) core.host_function.NativeF64Fn`。
- **作用**：为某个 unary Math id 生成 `.f_f` 叶子函数指针。
- **实现**：先在表位点用 comptime `switch` 校验 id 属于允许的一元集合（1,2,3,4,5,10..16,18..23,25..28,31..36），不在就 `@compileError`；再返回一个把固定 `id` 转发给 `mathUnaryInvoke` 的闭包。
- **所有权 / 错误 / 调用**：comptime 工厂：返回的是 comptime `struct` 内静态函数的指针，没有运行时分配、没有闭包环境，也没有 error set——非法 id 是 `@compileError` 而不是运行期失败。调用方：`mathUnaryEntry`（172）把它填进 `native_function.f_f`，以及本文件那个「一元 id 共用一份实现」的单测。

### `mathUnaryNative.invoke` (`src/exec/math_ops.zig:198`)

- **签名**：`fn invoke(value: f64) f64`。
- **作用**：comptime 闭包：把固定 `id` 转交给共享的 `mathUnaryInvoke`。
- **实现**：`return mathUnaryInvoke(id, value)`。非法 id 在 `mathUnaryNative` 表位点 `@compileError`。
- **所有权 / 错误 / 调用**：leaf，不抛、不分配。`native_function.f_f` 指向这里。

### `mathUnaryInvoke` (`src/exec/math_ops.zig:204`)

- **签名**：`noinline fn mathUnaryInvoke(id: u32, value: f64) f64`。
- **作用**：所有 unary Math cproto 的共享数值体：`id` 运行时分发，让 leftover typed 副本共用一份实现。
- **实现**：`switch (id)`：1 `@abs`、2 `@floor`、3 `@ceil`、4 `mathRound`、5 `@sqrt`、10 `exp`、11–13 `@sin/@cos/@tan`、14–16 `acos/asin/atan`、18–20 `acosh/asinh/atanh`、21 `@log`、22 trunc（NaN/0/非有限原样返回；负则 `-@floor(@abs)` 否则 `@floor`）、23 `cbrt`、25 `cosh`、26 `expm1`、27 f16 往返、28 f32 往返、31 `log1p`、32 `log2`、33 `@log10`、34 `mathSign`、35 `sinh`、36 `tanh`。其它 `unreachable`（表位点已拦住）。
- **所有权 / 错误 / 调用**：纯 f64→f64，无 JS 异常。生产路径上 `mathUnaryNative.invoke` 是唯一调用方；另有同文件那个「一元 id 共用一份实现」的单测直接按 id 调它（778）。

### `mathBinaryNative` (`src/exec/math_ops.zig:238`)

- **签名**：`fn mathBinaryNative(comptime id: u32) core.host_function.NativeF64F64Fn`。
- **作用**：为某个 binary Math id 生成 `.f_f_f` 叶子函数指针。
- **实现**：返回一个 comptime 闭包，`switch (id)`：6 → `mathPow`，17 → `std.math.atan2`，其它 `@compileError`。
- **所有权 / 错误 / 调用**：与 `mathUnaryNative` 同形：comptime 工厂，返回静态函数指针，不分配、不失败，非法 id 在编译期就报错。唯一调用方是 `mathBinaryEntry`（184）。

### `mathBinaryNative.invoke` (`src/exec/math_ops.zig:240`)

- **签名**：`fn invoke(lhs: f64, rhs: f64) f64`。
- **作用**：comptime 闭包体：把固定 `id` 映到对应的二元数值实现。
- **实现**：`switch (id)`：6 `mathPow(lhs, rhs)`、17 `std.math.atan2(lhs, rhs)`，其余在编译期报错。
- **所有权 / 错误 / 调用**：leaf，不抛、不分配；`native_function.f_f_f` 指向这里。

### `xorshift64star` (`src/exec/math_ops.zig:255`)

- **签名**：`fn xorshift64star(state: *u64) u64`。
- **作用**：`Math.random` 的伪随机数内核：就地推进调用方给的 64 位状态，并返回本次的随机位。
- **实现**：qjs `xorshift64star`（quickjs.c:47362）的逐字移植：对 `state.*` 依次做 `^= x >> 12`、`^= x << 25`、`^= x >> 27` 并写回，返回值再与常数 `0x2545F4914F6CDD1D` 做回绕乘（`*%`）。移位量与乘数都必须与 qjs 一致，改了就等于换掉 `Math.random` 的整条序列。
- **所有权 / 错误 / 调用**：通过指针就地改写调用方持有的状态（生产里就是 `ctx.random_state`），自身不分配、无 error set。唯一调用方 `mathRandom`（267）。

### `mathRandom` (`src/exec/math_ops.zig:266`)

- **签名**：`fn mathRandom(ctx: *core.JSContext) f64`。
- **作用**：`Math.random`：推进本 realm 的 xorshift64star 状态并产出 [0,1) 的 double。
- **实现**：`xorshift64star(&ctx.random_state)` 取 64 位，把高 52 位塞进指数为 0x3ff 的尾数得到 [1.0, 2.0)，再减 1。 注释对照 quickjs.c:47383。
- **所有权 / 错误 / 调用**：读写 `ctx.random_state` 这份 per-JSContext 状态，不分配、不失败——因此同一 realm 的序列可复现、不同 realm 互不干扰。调用方：`mathOpCall` 的裸 runtime 臂（282，它必须在转给 `call` 之前先拦下 magic 9，因为 `call` 拿不到 per-runtime 状态）与 `preparedOpCall` 的 id 9（312）。

### `mathOpCall` (`src/exec/math_ops.zig:272`)

- **签名**：`fn mathOpCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：数值 `Math.*`（id 1..36）的共享记录处理函数，也是各 f64 叶子的 `fallback_function`：参数不是纯数值时从这里走完整 ToNumber。
- **实现**：先 `nativeCall` 恢复 `NativeCall`；失败则 `error.TypeError`。`func_obj == null and global == null` 是裸 runtime 的算法复用臂：magic 9 直接 `mathRandom`，其余交只认原始值的 `call`（失败统一成 `error.TypeError`）。否则定 realm——有 `func_obj` 就取 `callableRealm` 并断言 realm 与 ctx 一致，没有就用 `host_call.global`（为 null 则 `error.TypeError`）——再转给 `preparedOpCall`。 关键调用：`builtin_dispatch.callableRealm`、`mathRandom`、`call`、`preparedOpCall`。
- **所有权 / 错误 / 调用**：自身不分配，`args` 借自调用方的调用帧，返回的 Number 是立即数、不需要 GC 根。error set 是 `HostError`：`nativeCall` 失败、裸 runtime `call` 失败、拿不到 global 三处返回**不带** pending exception 的 `error.TypeError`，由上层 `materializeRuntimeError` 补出 JS 异常；`callableRealm` / `preparedOpCall` 路径上的失败则已经把异常挂在 ctx 上，上传时收成 `error.JSException`。它没有普通意义上的调用方：一面被 `mathEntryWithHandler` 包成 `.generic_magic` 记录（hypot/random/imul/clz32/min/max），一面是全部 f64 叶子表项的 `fallback_function`。

### `preparedOpCall` (`src/exec/math_ops.zig:304`)

- **签名**：`pub fn preparedOpCall(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, id: u32, args: []const core.JSValue) HostError!core.JSValue`。
- **作用**：realm 路径上的标量 `Math.*` 计算（id 1..36）：记录处理函数与 opcode 辅助函数共用的入口。
- **实现**：一个大 `switch (id)`，每个臂用 `mathArg` 在 VM 环境里按需 ToNumber 后算出 f64：1 abs、2 floor、3 ceil、4 round、5 sqrt、6 pow、7/8 `mathMinMax`、9 `mathRandom`、10..23 指数/三角/双曲/cbrt、24 clz32（`toUint32Number` + `@clz`）、25..28（cosh/expm1/f16round/fround）、29 `mathHypot`、30 `mathImul`、31..36（log1p/log2/log10/sign/sinh/tanh），未知 id `error.TypeError`；结果统一经 `value_ops.numberToValue` 收窄。opcode 辅助函数故意直接调它而不过记录表的函数指针——间接调用会让最热的标量 Math 退化约 5%。 可返回 `error.TypeError`。 关键调用：`mathArg`、`mathMinMax`、`mathHypot`、`mathRandom`、`value_ops.numberToValue`。
- **所有权 / 错误 / 调用**：不分配（`value_ops.numberToValue` 产出的是立即数），`args` 借用。未知 id 返回裸 `error.TypeError`；其余错误都来自 `mathArg` → `toMathNumber`，抛出前 JS 异常已挂好。树内调用方只有本文件的 `mathOpCall`（291）与 `mathMinMaxDirect`（106）；`pub` 是留给 opcode 辅助函数绕开记录表的契约，当前树里还没有本文件之外的调用点——函数头注释已按这个事实改实。

### `mathArg` (`src/exec/math_ops.zig:350`)

- **签名**：`pub fn mathArg(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, index: usize) !f64`。
- **作用**：取第 `index` 个参数并在 VM 环境里转成 f64；缺参为 NaN。
- **实现**：`index >= args.len` 直接返回 NaN（对应 spec 的 undefined→NaN），否则 `toMathNumber`。 关键调用：`toMathNumber`。
- **所有权 / 错误 / 调用**：不分配、不建根；缺参返回 NaN 是正常返回不是错误。所有 error 都来自 `toMathNumber`：bigint/symbol 的 TypeError 在那里已挂好 JS 异常，`valueOf`/`@@toPrimitive` 回调抛出的异常原样上传。调用方：`preparedOpCall` 每个臂的取参点（一元取 index 0，`pow`/`atan2`/`imul` 再取 index 1）。

### `toMathNumber` (`src/exec/math_ops.zig:355`)

- **签名**：`pub fn toMathNumber(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue) !f64`。
- **作用**：`Math.*` 参数的 ToNumber：走完整的可观察强制转换，并把 bigint / symbol 变成带消息的 TypeError。
- **实现**：先 `toPrimitiveForNumber`（可能回调 JS 的 `valueOf`/`@@toPrimitive`）；得到 bigint 抛「cannot convert bigint to number」、symbol 抛「cannot convert symbol to number」，都落成 `error.TypeError`；其余经 `value_ops.toNumberValue`，取不出数值时为 NaN。 可返回 `error.TypeError`。 关键调用：`toPrimitiveForNumber`、`exception_ops.throwTypeErrorMessage`、`value_ops.toNumberValue`。
- **所有权 / 错误 / 调用**：不分配。抛异常时先 `throwTypeErrorMessage` 把 JS 异常挂上，再返回 `error.TypeError`。调用方：`mathArg`（`preparedOpCall` 的每个参数取值点）、`mathMinMax` 的慢臂、`mathHypot`。

### `mathMinMax` (`src/exec/math_ops.zig:369`)

- **签名**：`pub fn mathMinMax(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, is_max: bool) !f64`。
- **作用**：`Math.min`/`Math.max` 的 realm 路径实现（含两参与全原始值快路径）。
- **实现**：恰两个参数时先试快路径：都是 int32 就整数比较（两个 0 统一返回 +0），都是 number 就按 NaN 优先、±0 规则的 `fmax`/`fmin`。无参返回 ∓Infinity。随后 `mathMinMaxPrimitiveFast` 再试一次全原始值折叠；都不成才逐个 `toMathNumber`（可观察）折叠，NaN 一旦出现就粘滞。 关键调用：`primitiveMathNumber`、`mathMinMaxPrimitiveFast`、`toMathNumber`、`fmax`、`fmin`。
- **所有权 / 错误 / 调用**：不分配。慢臂的 `toMathNumber` 会回调 JS，所以参数强转严格按下标顺序发生、前一个参数的 `valueOf` 抛异常就不会再碰后面的参数；异常在 `toMathNumber` 内挂好后以 Zig error 上传。唯一调用方是 `preparedOpCall` 的 id 7/8。

### `mathMinMaxPrimitiveFast` (`src/exec/math_ops.zig:404`)

- **签名**：`pub fn mathMinMaxPrimitiveFast(args: []const core.JSValue, is_max: bool) ?f64`。
- **作用**：全部参数都是可无副作用取数的原始值时，直接折出 min/max，否则 null。
- **实现**：以 ∓Infinity 起手逐个 `primitiveMathNumber`，任一参数取不到数就返回 null（交给可观察路径）；折叠同样是 NaN 粘滞 + `fmax`/`fmin` 的 ±0 规则。
- **所有权 / 错误 / 调用**：纯函数，只读借来的 `args`，不分配、不回调 JS，没有 error set；`null` 表示「至少有一个参数需要可观察强转」。调用方：`mathMinMax`（386）和裸 runtime `call` 的 id 7/8（654-655，那里把 null 收成 `error.TypeError`）。

### `primitiveMathNumber` (`src/exec/math_ops.zig:420`)

- **签名**：`pub fn primitiveMathNumber(value: core.JSValue) ?f64`。
- **作用**：无副作用地把原始值取成 f64：int32/float64 直取，布尔 → 1/0，null → 0，undefined → NaN；字符串、对象、symbol、bigint 返回 null。
- **实现**：五条顺序判断：`is(.int)` 转 f64、`is(.float64)` 直取、`as(.boolean)` 给 1/0、null 给 0、undefined 给 NaN；都不中（字符串、对象、symbol、bigint）返回 null。全程不回调 JS，因此可以用在快路径上。
- **所有权 / 错误 / 调用**：纯函数。调用方：`mathMinMax` 的双参快臂与 `mathMinMaxPrimitiveFast`——返回 null 就意味着必须退回可观察的 `toMathNumber` 路径。

### `fmin` (`src/exec/math_ops.zig:429`)

- **签名**：`pub fn fmin(a: f64, b: f64) f64`。
- **作用**：qjs `js_fmin`：带符号零规则的 min——两个零时按位或（−0 优先），否则取较小者。
- **实现**：两个操作数都等于 0 时（含 ±0 混合）把两者的位模式**按位或**再重解释成 f64——符号位只要有一个是 1 结果就是 −0，这正是 min 要的；否则 `a < b ? a : b`（NaN 由调用方的 sticky 规则先处理）。
- **所有权 / 错误 / 调用**：纯函数。调用方：`mathMinMaxNumberFast`、`mathMinMax`、`mathMinMaxPrimitiveFast` 三条 min/max 路径。

### `fmax` (`src/exec/math_ops.zig:434`)

- **签名**：`pub fn fmax(a: f64, b: f64) f64`。
- **作用**：qjs `js_fmax`：带符号零规则的 max——两个零时按位与（+0 优先），否则取较大者。
- **实现**：两个操作数都等于 0 时把位模式**按位与**——符号位要两个都是 1 才是 −0，于是 +0 胜出；否则 `a < b ? b : a`。
- **所有权 / 错误 / 调用**：纯函数。调用方与 `fmin` 相同的三条 min/max 路径。

### `mathPow` (`src/exec/math_ops.zig:439`)

- **签名**：`pub fn mathPow(a: f64, b: f64) f64`。
- **作用**：`Math.pow` / `**` 的 f64 内核：补上 spec 与 C `pow` 不一致的那个特例。
- **实现**：先补 spec 的特例：底数绝对值为 1 而指数非有限时返回 NaN；其余交 `std.math.pow`。
- **所有权 / 错误 / 调用**：纯函数、不失败。文件内三个调用点：`mathBinaryNative` 的 id 6 叶子、`preparedOpCall` 的 id 6、裸 runtime 的 `call` 的 id 6。

### `mathRound` (`src/exec/math_ops.zig:444`)

- **签名**：`pub fn mathRound(a: f64) f64`。
- **作用**：`Math.round`：半数向 +∞ 取整（与 `@round` 的半数远离零不同），按位实现以保住 ±0 与巨大数。
- **实现**：直接在 IEEE 位模式上做：指数 < 1023（|x| < 1）时，只有 exponent == 1022 且不是 −0.5 的那档进位成 ±1，其余只留符号位（结果 ±0）；指数 < 1075（尚有小数位）时按 `(one >> 1) -% sign_bit` 加上半个 ulp 再清掉小数位——负数的 −0.5 偏置正是「半数向 +∞」；指数更大者本就是整数，原样返回。
- **所有权 / 错误 / 调用**：纯 f64 位运算，不分配、不失败。三个调用点都在本文件，正好是 `Math.round` 的三条路径：`mathUnaryInvoke` 的 id 4（f64 叶子）、`preparedOpCall` 的 id 4（realm 路径）、`call` 的 id 4（裸 runtime 路径）。

### `mathHypot` (`src/exec/math_ops.zig:463`)

- **签名**：`pub fn mathHypot(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue) !f64`。
- **作用**：`Math.hypot` 的 realm 路径实现：逐参数 ToNumber 后累积平方和的根。
- **实现**：无参返回 0；单参返回 `@abs`；其余依次 `toMathNumber` 后两两 `std.math.hypot` 累积。 关键调用：`toMathNumber`、`std.math.hypot`。
- **所有权 / 错误 / 调用**：不分配。注意累积是两两 `hypot` 串联而不是先求平方和，因此中间不会溢出；参数强转按顺序发生，前面的 `valueOf` 抛异常会中断后面的。调用方：`preparedOpCall` 的 id 29。

### `mathImul` (`src/exec/math_ops.zig:474`)

- **签名**：`pub fn mathImul(lhs: f64, rhs: f64) i32`。
- **作用**：`Math.imul` 的内核：两个操作数按 ToUint32 截断后做 32 位回绕乘法。
- **实现**：两个操作数各经 `toUint32Number` 转 uint32，做回绕乘法（`*%`），结果按位重解释成 i32。
- **所有权 / 错误 / 调用**：纯函数、不失败。调用方：`preparedOpCall` 与裸 runtime `call` 的 id 30（两处都把 i32 结果再转回 f64）。

### `mathSign` (`src/exec/math_ops.zig:479`)

- **签名**：`pub fn mathSign(value: f64) f64`。
- **作用**：`Math.sign` 的内核：保号返回 NaN / ±0 / ±1。
- **实现**：NaN 与 ±0 原样返回（保号），负数 −1，正数 1。
- **所有权 / 错误 / 调用**：纯函数。调用方：`mathUnaryInvoke`、`preparedOpCall`、`call` 三处的 id 34。

### `mathSumPreciseCall` (`src/exec/math_ops.zig:486`)

- **签名**：`fn mathSumPreciseCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`Math.sumPrecise` 的 NativeEntry 处理函数：取 callable realm 后转给 `mathSumPrecise`。
- **实现**：先 `nativeCall` 恢复 `NativeCall`，失败即 `error.TypeError`；随后 `callableRealm` 取 realm 并断言与 ctx 一致（这条方法要遍历可迭代对象、必然回调 JS，所以必须有 realm，不设裸 runtime 臂）；最后把 args 与 caller 的 bytecode/frame 一起交给 `mathSumPrecise`。它是表里唯一不共用 `mathOpCall` 的数值方法，记录 id 是 `sum_precise_method_id`（37）。
- **所有权 / 错误 / 调用**：自身不分配。error set `HostError`：`nativeCall` 失败返回裸 `error.TypeError`，`callableRealm` 与 `mathSumPrecise` 的失败则异常已挂在 ctx 上。没有具名调用方——它只作为 `internal_entries` 里 `sumPrecise`（id 37）那条记录的 `.generic_magic` handler 被 `builtin_dispatch` 调进来。

### `mathSumPrecise` (`src/exec/math_ops.zig:505`)

- **签名**：`pub fn mathSumPrecise( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame, ) HostError!core.JSValue`。
- **作用**：`Math.sumPrecise`：遍历可迭代对象，用 bigint 精确求和再一次性圆回 f64。
- **实现**：无参先抛 TypeError。取迭代器后逐项 `iteratorStepValue`：非数字项先 `iteratorCloseValue` 再抛 TypeError「not a number」；NaN / ±Infinity / ±0 只记标志，有限值进 `finite_values`。收尾按 spec 短路：见过 NaN 或正负无穷同时出现 → NaN，单边无穷 → 对应无穷；没有有限值时，见过 +0 返回 0、否则 −0。否则 `exactF64Sum` 求和，和为 0 且只见过 −0 时返回 −0，其余 `numberToValue`。 关键调用：`iterator_ops.iteratorForValue`、`iterator_ops.iteratorStepValue`、`iterator_ops.iteratorCloseValue`、`exactF64Sum`。
- **所有权 / 错误 / 调用**：`finite_values` 用 `ctx.runtime.memory.allocator` 分配，`defer deinit` 保证异常路径一并释放；迭代器句柄与每一步的值只活在 Zig 栈上，本函数不注册 `ValueRootFrame` 之类的显式 GC 根。错误：缺参、非数字项由 `exception_ops.throwTypeErrorMessage` 挂好 JS 异常后返回（非数字项**先** `iteratorCloseValue` 再抛，对应 spec 的 IteratorClose 顺序），迭代过程中 JS 自己抛的异常原样上传。调用方：记录 handler `mathSumPreciseCall`，以及按名字分派的兼容回退 `call_runtime.callNativeCallableByName`（src/exec/call_runtime.zig:1094）。

### `exactF64Sum` (`src/exec/math_ops.zig:560`)

- **签名**：`pub fn exactF64Sum(allocator: std.mem.Allocator, values: []const f64) !f64`。
- **作用**：把一串有限 f64 精确相加（放大成整数的 bigint 累加），再圆回最近的 f64。
- **实现**：逐个 `exactF64ScaledInteger` 转成「乘了 2^1074」的整数 bigint 累加到 `total`（每步换掉旧的 total 并释放），最后 `scaledIntegerToF64` 还原。 关键调用：`exactF64ScaledInteger`、`total.add`、`scaledIntegerToF64`。
- **所有权 / 错误 / 调用**：`total` 与每个 `term` 都是本函数持有的 `bignum.BigInt`：`term` 用 `defer deinit`，`total` 在每次 `add` 之后显式释放旧值再换成新值，函数出口还有 `defer total.deinit()`——返回的是 f64，没有任何堆对象交给调用方。error：BigInt 分配的 OOM，以及 `scaledIntegerToF64` 的 `error.TypeError`。唯一调用方 `mathSumPrecise`（553）。

### `exactF64ScaledInteger` (`src/exec/math_ops.zig:575`)

- **签名**：`pub fn exactF64ScaledInteger(allocator: std.mem.Allocator, number: f64) !bignum.BigInt`。
- **作用**：把一个 f64 无损表示成整数 bigint：值 × 2^1074。
- **实现**：拆位模式取符号、指数、尾数：次正规数（exponent_bits == 0）尾数不补隐含位、指数取 −1074，正规数补上 2^52 并取 `exponent_bits - 1023 - 52`。尾数为 0 直接返回 0，否则左移 `exponent + 1074` 位。 关键调用：`bignum.BigInt.fromIntAlloc`、`base.shl`。
- **所有权 / 错误 / 调用**：返回的 `BigInt` 归调用方，须 `deinit`；`exactF64Sum` 里用 `defer` 释放。

### `scaledIntegerToF64` (`src/exec/math_ops.zig:590`)

- **签名**：`pub fn scaledIntegerToF64(allocator: std.mem.Allocator, value: bignum.BigInt) !f64`。
- **作用**：把 `exactF64ScaledInteger` 那套「× 2^1074」的整数 bigint 圆回最近的 f64。
- **实现**：零直接 0。取绝对值与位长：位长 ≤ 52 说明结果是次正规数，尾数即数值本身；否则指数取 `bit_len - 1 - 1074`，超过 1023 返回 ±Infinity。截出高 53 位当有效数字，再按 `shouldRoundScaledIntegerUp` 做「就近偶数」进位；进位溢出成 2^53 时右移一位、指数加一并重新查上溢。最后拼回符号/指数/尾数位。 可返回 `error.TypeError`。 关键调用：`value.cloneWithAllocator`、`magnitude.shr`、`shouldRoundScaledIntegerUp`。
- **所有权 / 错误 / 调用**：只借用 `value`：先 `cloneWithAllocator` 出 `magnitude` 再去掉符号，绝不写回调用方的 BigInt；`magnitude` 与 `top_int` 各自 `defer deinit`。`error.TypeError` 表示 `toUsize` 装不下（正常路径不会发生：位长已裁到 ≤53），此外是克隆/移位的 OOM。唯一调用方 `exactF64Sum`（570）。

### `shouldRoundScaledIntegerUp` (`src/exec/math_ops.zig:630`)

- **签名**：`pub fn shouldRoundScaledIntegerUp(magnitude: bignum.BigInt, shift: usize, significand: u64) bool`。
- **作用**：round-half-to-even 判定：截断掉的低位是否应该让有效数字进 1。
- **实现**：最高被截位（`shift - 1`）为 0 不进位；为 1 时若有效数字是奇数就进位，否则再扫更低位，只要还有 1（即严格大于半个 ulp）就进位，全 0（正好半个）保持偶数不进位。
- **所有权 / 错误 / 调用**：只读地 `testBit` 借来的 `magnitude`，不分配、不失败。唯一调用方 `scaledIntegerToF64`（613）。注意判「是否恰好半个 ulp」要从低位往上扫，因此最坏是 O(shift) 位——`Math.sumPrecise` 的量级下可以接受。

### `call` (`src/exec/math_ops.zig:645`)

- **签名**：`pub fn call(id: u32, args: []const core.JSValue) !f64`。
- **作用**：裸 runtime（无 realm global）的 `Math.*` 标量回退：只接受原始值参数，不回调 JS。
- **实现**：只认原始值：前两个参数经 `numberValue` 取数（缺参为 NaN），再按 `id` 走与 `preparedOpCall` 同构的 switch。差别是 7/8 用 `mathMinMaxPrimitiveFast`（miss 即 `error.TypeError`）、29 用 `mathHypotPrimitive`，而 9（random）需要 per-runtime 状态，已被 `mathOpCall` 提前接走，这里一律 `error.TypeError`——绝不返回假常量。 关键调用：`numberValue`、`mathMinMaxPrimitiveFast`、`mathHypotPrimitive`。
- **所有权 / 错误 / 调用**：不分配、不回调 JS。唯一调用方是 `mathOpCall` 的 `func_obj == null and global == null` 裸 runtime 臂；错误在那里被统一收成 `error.TypeError`。

### `exp` (`src/exec/math_ops.zig:692`)

- **签名**：`pub fn exp(value: f64) f64`。
- **作用**：`Math.exp`，但对 ±1 给出与常量 `E` 完全一致的结果。
- **实现**：`value == 1` 返回 `E`、`value == -1` 返回 `1.0 / E`，其余 `@exp`。
- **所有权 / 错误 / 调用**：纯 f64 叶子，不分配、不失败。三个调用点是 `Math.exp` 的三条路径的 id 10：`mathUnaryInvoke`、`preparedOpCall`、`call`。

### `log2` (`src/exec/math_ops.zig:698`)

- **签名**：`pub fn log2(value: f64) f64`。
- **作用**：`Math.log2`，2 的整数次幂走精确整数指数。
- **实现**：`exactPowerOfTwoExponent` 命中就直接返回该指数（避免库函数的 1ulp 误差），否则 `@log2`。
- **所有权 / 错误 / 调用**：纯 f64 叶子，不分配、不失败。调用点同样是三条路径的 id 32（`mathUnaryInvoke` / `preparedOpCall` / `call`）；它自己只依赖同文件的 `exactPowerOfTwoExponent`。

### `mathHypotPrimitive` (`src/exec/math_ops.zig:703`)

- **签名**：`fn mathHypotPrimitive(args: []const core.JSValue) !f64`。
- **作用**：`Math.hypot` 的裸 runtime 版：取数只认原始值，不做可观察强转。
- **实现**：与 `mathHypot` 同形，但取数用只认原始值的 `numberValue`：无参 0、单参 `@abs`、其余 `std.math.hypot` 累积。 关键调用：`numberValue`、`std.math.hypot`。
- **所有权 / 错误 / 调用**：不分配。参数里出现字符串/对象等需要 ToNumber 的值时 `numberValue` 直接 `error.TypeError`。唯一调用方是 `call` 的 id 29。

### `exactPowerOfTwoExponent` (`src/exec/math_ops.zig:711`)

- **签名**：`fn exactPowerOfTwoExponent(value: f64) ?i32`。
- **作用**：判断一个正的有限 f64 是否恰是 2 的整数次幂，是则给出指数。
- **实现**：非正或非有限返回 null。次正规数（exponent_bits == 0）要求尾数恰有一个置位（`fraction & (fraction - 1) == 0`），指数为 `@ctz(fraction) - 1074`；正规数要求尾数为 0，指数为 `exponent_bits - 1023`。
- **所有权 / 错误 / 调用**：纯位运算，不分配、不失败。唯一调用方 `log2`（697）。

### `numberValue` (`src/exec/math_ops.zig:725`)

- **签名**：`fn numberValue(value: core.JSValue) !f64`。
- **作用**：裸 runtime 路径的取数：只接受不需要回调 JS 的原始值。
- **实现**：int32/float64 直取，布尔 → 1/0，null → 0，undefined → NaN；字符串、对象、symbol、bigint 一律 `error.TypeError`。 可返回 `error.TypeError`。
- **所有权 / 错误 / 调用**：纯函数、不分配。这里的 `error.TypeError` 只是「这个值需要可观察强转」的哨兵：裸 runtime 路径没有 realm 可以抛真正的 JS 异常，所以 `mathOpCall` 在 282-283 把它统一收成 `error.TypeError`。调用方：`call`（645-646）与 `mathHypotPrimitive`（703、705）。它与同文件的 `primitiveMathNumber` 语义相同、只是用 error 而不是 `null` 表示 miss，别混用。


## `src/exec/number_ops.zig` — Number 记录与格式化

纯解析从 `core.number` 再导出。本文件拥有 `.number` 记录表和 `Number.prototype` 格式化（toString/toFixed/toExponential/toPrecision），dtoa 走 `libs/number_format.zig`。`Number(...)` 作函数在 `builtin_glue.numberFunctionCall`。


### 类型

- `StaticMethod` / `PrototypeMethod`：从 `core.host_function.builtin_method_ids.number` 再导出的记录 id 枚举。`StaticMethod` 覆盖 `parseInt` / `parseFloat` / `isNaN` / `isFinite` / `isInteger` / `isSafeInteger`（前四个同时也是四个**全局**函数的 id），`PrototypeMethod` 覆盖 `toString` / `toLocaleString` / `toFixed` / `toExponential` / `toPrecision`。id 同时用作记录的 `magic`。
- `internal_entries`：`.number` domain 的声明 + 分派表，11 条全是 `.generic_magic`，全部指向同一个 `numberCall`。
- 纯解析原语的再导出：`parseIntValue` / `parseFloatValue` / `parseIntLatin1Bytes` / `parseFloatLatin1Bytes`，实体在 `core/number.zig`——它们不碰 VM，裸 runtime 调用点用得上。
- dtoa 格式标志（`libs/number_format.zig`）：`JS_DTOA_FORMAT_FREE` / `JS_DTOA_FORMAT_FIXED` / `JS_DTOA_FORMAT_FRAC` 选格式，`JS_DTOA_EXP_ENABLED` / `JS_DTOA_EXP_DISABLED` 决定是否允许指数记法；四个格式化体就是靠这几位的组合区分的。
- 错误成员：`error.InvalidRadix` / `error.RangeError` / `error.TypeError` 来自 `core/errors.zig` 的共享错误集，由格式化体抛出、在 `numberPrototypeMethod` 统一翻译成带消息的 JS RangeError / TypeError。本文件自身没有定义 struct 或 enum。
- 文件内别名：`HostError`（= `exceptions.HostError`）、`dtoa`（= `libs/number_format.zig`）。

### `staticMethodId` (`src/exec/number_ops.zig:33`)

- **签名**：`pub fn staticMethodId(name: []const u8) ?u32`。
- **作用**：把 `Number.parseInt` 这类静态方法名映射到 `.number` domain 的记录 id。
- **实现**：六条 `std.mem.eql` 线性比对：`parseInt` / `parseFloat` / `isNaN` / `isFinite` / `isInteger` / `isSafeInteger` 各映到 `StaticMethod` 的对应成员，其余 null。注意四个全局函数（`parseInt`/`parseFloat`/`isNaN`/`isFinite`）与 `Number.*` 同名静态共用这些 id。
- **所有权 / 错误 / 调用**：纯函数，不分配。调用方是 `standard_globals.zig` 的安装期：`.number_static` 那条臂用它给方法记录填 `native_builtin_id`。

### `prototypeMethodId` (`src/exec/number_ops.zig:43`)

- **签名**：`pub fn prototypeMethodId(name: []const u8) ?u32`。
- **作用**：把 `Number.prototype` 方法名映射到 `.number` domain 的记录 id。
- **实现**：五条 `std.mem.eql`：`toString` / `toLocaleString` / `toFixed` / `toExponential` / `toPrecision` 映到 `PrototypeMethod` 成员，其余 null（`valueOf` 不在这张表里，它在 `primitive_ops.zig`）。
- **所有权 / 错误 / 调用**：纯函数。调用方同样是 `standard_globals.zig` 的方法安装路径。

### `numberEntry` (`src/exec/number_ops.zig:74`)

- **签名**：`fn numberEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry`。
- **作用**：为 `.number` domain 的记录表生成一条表项（6 个静态 + 5 个原型方法共 11 条）。
- **实现**：填 `name`/`length`/`id`，`magic` 取同一个 `id`，`cproto` 为 `.generic_magic`，`native_function` 是 `genericMagicFunction(&numberCall)`——表里 11 条记录共用一个处理函数。
- **所有权 / 错误 / 调用**：全 comptime 求值，不分配。只被 `internal_entries` 使用；其中 `parseInt`/`parseFloat`/`isNaN`/`isFinite` 四条同时也是四个全局函数的记录来源。

### `numberCall` (`src/exec/number_ops.zig:90`)

- **签名**：`fn numberCall( native_ctx: *core.JSContext, native_this: core.JSValue, native_args: []const core.JSValue, native_magic: i32, ) HostError!core.JSValue`。
- **作用**：`.number` domain 唯一的记录处理函数：全局 `parseInt`/`parseFloat`/`isNaN`/`isFinite`、`Number.*` 静态断言与 `Number.prototype` 格式化都从这里按 magic 分流。
- **实现**：先 `nativeCall` 恢复 `NativeCall`；失败则 `error.TypeError`。有 `func_obj` 时取 `callableRealm` 并断言 realm 与 ctx 一致，否则用算法侧给的 `host_call.global`（Number 原型胶水会在 coerce 之后不带函数对象地复用这些记录）。随后按 `magic` 分派：`parseInt`/`parseFloat` 有 global 就走 `builtin_glue.globalParseInt`/`globalParseFloat`（VM 可观察），没有则退到只认原始值的 `parseIntValue`/`parseFloatValue`；`isNaN`/`isFinite` 必须有 global，转 `builtin_glue.globalIsNaNOrFinite`（末参 true=isNaN）；`isInteger` 用 `numberIsInteger`，`isSafeInteger` 再加 `@abs(number) <= 9007199254740991.0`；五个原型方法转 `numberPrototypeMethod`；未知 id `error.TypeError`。 关键调用：`builtin_dispatch.callableRealm`、`builtin_glue.globalParseInt`、`builtin_glue.globalParseFloat`、`builtin_glue.globalIsNaNOrFinite`、`parseIntValue`、`parseFloatValue`、`numberPrototypeMethod`。
- **所有权 / 错误 / 调用**：自身不分配，`this_value` / `args` 借自调用帧；返回值要么是立即数，要么是下游新建的 owned 字符串（GC 值，调用方不手工释放）。error set `HostError`：`nativeCall` 失败、`isNaN`/`isFinite` 缺 global、未知 id 三处返回**不带** pending exception 的 `error.TypeError`，靠上层 `materializeRuntimeError` 补 JS 异常；`callableRealm`、`builtin_glue.*`、`numberPrototypeMethod` 抛出时异常已挂在 ctx 上。它没有具名调用方：11 条 `internal_entries` 全部通过 `genericMagicFunction(&numberCall)` 指向它，exec 侧的 `Number.prototype.*` 也是经 `object_ops.numberPrototypeMethod`（src/exec/object_ops.zig:1402）用 `callInternalRecord` 走记录表进来的。

### `numberPrototypeMethod` (`src/exec/number_ops.zig:161`)

- **签名**：`fn numberPrototypeMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, this_value: core.JSValue, id: u32, args: []const core.JSValue, ) HostError!core.JSValue`。
- **作用**：`Number.prototype.{toString,toLocaleString,toFixed,toExponential,toPrecision}` 的方法体：先 coerce 接收者与位数参数，再转交纯格式化函数。
- **实现**：先 `object_ops.primitivePrototypeThisValue(rt, this_value, 1)` 把接收者收成数字原始值，失败抛 TypeError「not a number」。除 `toLocaleString` 外都用 `coercion_ops.coerceOptionalNumberMethodArgument`（VM 可观察的 ToNumber）先把位数参数算好，再塞进一个单元素数组代替原 `args`。随后按 id 调 `toStringMethod`/`toFixed`/`toExponential`/`toPrecision`（`toLocaleString` 走 `toStringMethod` 且不带参数）。纯函数体的 error 在这里落成消息：`TypeError` →「not a number」、`InvalidRadix` →「radix must be between 2 and 36」、`RangeError` →「invalid number of digits」。 关键调用：`object_ops.primitivePrototypeThisValue`、`coercion_ops.coerceOptionalNumberMethodArgument`、`toStringMethod`、`toFixed`、`toExponential`、`toPrecision`。
- **所有权 / 错误 / 调用**：`coerced_storage` 是栈上的单元素数组，`method_args` 借它或原 `args`，本函数不分配；返回值是下游格式化体新建的 owned 字符串值。错误分两层：`primitivePrototypeThisValue` 的 `error.TypeError` 以及纯格式化体的 `TypeError` / `InvalidRadix` / `RangeError` 在这里被 `throw*Message` 落成带消息的 JS 异常（其余 error 原样上传，包括 OOM）；`coerceOptionalNumberMethodArgument` 会回调 JS，它抛出时异常已经挂好。唯一调用方是 `numberCall` 的五个原型方法臂（147）；exec 要走到这里必须经 `object_ops.numberPrototypeMethod` → `builtin_dispatch.callInternalRecord`（src/exec/object_ops.zig:1427），那里还负责把历史遗留的小 id 1..5 翻成 `PrototypeMethod` 枚举值。

### `numberIsInteger` (`src/exec/number_ops.zig:197`)

- **签名**：`fn numberIsInteger(value: core.JSValue) bool`。
- **作用**：`Number.isInteger` 的判定：值是数字、有限且 `@floor(x) == x`。
- **实现**：`value_ops.numberValue` 取不到数（非 int32/float64）直接 false；否则要求有限且 `@floor(number) == number`。不做 ToNumber，所以字符串 `"1"` 也是 false，符合规范。
- **所有权 / 错误 / 调用**：纯函数。调用方：`numberCall` 的 `is_integer` 与 `is_safe_integer` 两臂（后者再加 `@abs(number) <= 2^53-1` 的判断）。

### `toString` (`src/exec/number_ops.zig:202`)

- **签名**：`fn toString(buf: []u8, value: f64) ![]const u8`。
- **作用**：把 f64 按 Number::toString 的十进制规则格式化进调用方缓冲。
- **实现**：整体转调 `dtoa.formatNumber(buf, value)`——`libs/number_format.zig` 里那份忠实 js_dtoa 端口的十进制自由格式（含 NaN / ±Infinity / 指数形态的规范拼写），错误集原样透传。
- **所有权 / 错误 / 调用**：返回的切片指向**调用方**给的 `buf`，本函数不分配、不建 JS 值，生命周期归调用方。两个调用点都给 64 字节栈缓冲（足够容纳最长的十进制形态，因此都 `catch unreachable`）：`toStringMethod` 与 `numberStringValue`。本仓库内没有其他调用点，可见性已从 `pub` 收成文件私有。

### `toFixed` (`src/exec/number_ops.zig:206`)

- **签名**：`pub fn toFixed(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：`Number.prototype.toFixed` 的纯格式化体：把已强转的接收者与位数按定点格式渲染成字符串值。
- **实现**：接收者取不到数就 `error.TypeError`；位数参数经 `integerDigitsArgument` 饱和后必须落在 [0,100]，否则 `error.RangeError`。`@abs(number) >= 1e21` 时改用 `JS_DTOA_FORMAT_FREE`（即退回普通 toString 形态），否则 `JS_DTOA_FORMAT_FRAC`，最后交 `dtoaStringValue`。 可返回 `error.RangeError`, `error.TypeError`。 关键调用：`integerDigitsArgument`、`dtoaStringValue`。
- **所有权 / 错误 / 调用**：返回新建的 ASCII 字符串值，归调用方。`error.RangeError` 在 `numberPrototypeMethod` 里被翻成「invalid number of digits」的 JS RangeError，`error.TypeError` 翻成「not a number」。唯一调用方是 `numberPrototypeMethod`。

### `toExponential` (`src/exec/number_ops.zig:215`)

- **签名**：`pub fn toExponential(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：`Number.prototype.toExponential` 的纯格式化体：按指数形式渲染，位数参数缺省时用自动位数。
- **实现**：接收者取不到数就 `error.TypeError`。位数参数先无条件 coerce（副作用要发生），NaN/±Infinity 直接走 `numberStringValue`。参数为 undefined 时用 `JS_DTOA_FORMAT_FREE`、位数置 0（自动位数）；否则校验 [0,100] 后位数加一（有效数字 = 小数位 + 1），用 `JS_DTOA_FORMAT_FIXED`。两条路都叠上 `JS_DTOA_EXP_ENABLED`。 可返回 `error.RangeError`, `error.TypeError`。 关键调用：`integerDigitsArgument`、`numberStringValue`、`dtoaStringValue`。
- **所有权 / 错误 / 调用**：返回新建的 ASCII 字符串值。错误翻译同 `toFixed`。唯一调用方是 `numberPrototypeMethod`。

### `toPrecision` (`src/exec/number_ops.zig:231`)

- **签名**：`pub fn toPrecision(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：`Number.prototype.toPrecision` 的纯格式化体：按有效数字位数渲染，参数缺省时退回普通 toString。
- **实现**：接收者取不到数就 `error.TypeError`。参数缺省或 undefined 时等价于普通 toString（`numberStringValue`）；NaN/±Infinity 同样走 `numberStringValue`——都在范围检查之前，所以 `(NaN).toPrecision(0)` 不报 RangeError。其余要求精度落在 [1,100]，再以 `JS_DTOA_FORMAT_FIXED` 交 `dtoaStringValue`。 可返回 `error.RangeError`, `error.TypeError`。 关键调用：`integerDigitsArgument`、`numberStringValue`、`dtoaStringValue`。
- **所有权 / 错误 / 调用**：返回新建的 ASCII 字符串值。错误翻译同 `toFixed`。唯一调用方是 `numberPrototypeMethod`。

### `toStringMethod` (`src/exec/number_ops.zig:240`)

- **签名**：`pub fn toStringMethod(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue`。
- **作用**：`Number.prototype.toString` / `toLocaleString` 的纯格式化体：按 radix 把数渲染成字符串值。
- **实现**：接收者取不到数就 `error.TypeError`。radix 经 `integerDigitsArgument` 取（默认 10，且像 qjs `js_get_radix`/`JS_ToInt32Sat` 那样先饱和再做范围检查，避免 `@intFromFloat` 在 Debug/ReleaseSafe 上 panic），不在 [2,36] 就 `error.InvalidRadix`。radix 10 或非有限值走 64 字节栈缓冲的 `toString`；其余按 `radixMaxLen` 算出长度、在堆缓冲上跑 `dtoa.formatRadix`（`JS_DTOA_FORMAT_FREE | JS_DTOA_EXP_DISABLED`），这是忠实 js_dtoa 端口，保证结果能唯一还原该 double。 可返回 `error.InvalidRadix`, `error.TypeError`。 关键调用：`integerDigitsArgument`、`toString`、`dtoa.radixMaxLen`、`dtoa.formatRadix`、`core.string.String.createAscii`。 对照 quickjs.c:44975,44989。
- **所有权 / 错误 / 调用**：返回新建的 ASCII 字符串值；radix != 10 时用的堆缓冲在函数内释放。`error.InvalidRadix` 由 `numberPrototypeMethod` 翻成「radix must be between 2 and 36」的 JS RangeError。调用方：`numberPrototypeMethod` 的 `to_string` 与 `to_locale_string` 两臂（后者固定传空参数列表）。

### `numberStringValue` (`src/exec/number_ops.zig:273`)

- **签名**：`fn numberStringValue(rt: *core.JSRuntime, number: f64) !core.JSValue`。
- **作用**：把 f64 按默认十进制格式化并建成 ASCII 字符串值。
- **实现**：64 字节栈缓冲跑 `toString`（长度是本地不变量，故 `catch unreachable`），再 `String.createAscii`。 关键调用：`toString`、`core.string.String.createAscii`。
- **所有权 / 错误 / 调用**：栈缓冲只在函数内活；返回的是新建的 owned ASCII 字符串值（GC 值，调用方不手工释放）。唯一剩下的 error 是 `String.createAscii` 的 OOM，由上层 `materializeRuntimeError` 变成 JS 异常。调用方：`toExponential` 的非有限值臂（223）与 `toPrecision` 的缺参 / 非有限值臂（237、239）。

### `dtoaStringValue` (`src/exec/number_ops.zig:280`)

- **签名**：`fn dtoaStringValue(rt: *core.JSRuntime, number: f64, n_digits: i32, flags: i32) !core.JSValue`。
- **作用**：按给定位数与 dtoa flags 格式化并建成 ASCII 字符串值。
- **实现**：768 字节栈缓冲跑 `dtoa.formatDtoaChecked`（容量足够，故 `catch unreachable`），再 `String.createAscii`。 关键调用：`dtoa.formatDtoaChecked`、`core.string.String.createAscii`。
- **所有权 / 错误 / 调用**：768 字节栈缓冲用完即弃；返回新建的 owned ASCII 字符串值。唯一可能的 error 是 `String.createAscii` 的 OOM——`formatDtoaChecked` 的容量不足在这里被断成 `unreachable`（缓冲按最坏的 100 位小数 + 指数形态取的）。调用方：`toFixed`（216）、`toExponential`（232）、`toPrecision`（241）。

### `integerDigitsArgument` (`src/exec/number_ops.zig:287`)

- **签名**：`fn integerDigitsArgument(rt: *core.JSRuntime, args: []const core.JSValue, default: i32) !i32`。
- **作用**：把可选的位数/radix 参数取成饱和到 i32 的整数。
- **实现**：缺参或 undefined 返回 `default`；symbol/bigint 直接 `error.TypeError`；其余经 `core.number.toNumber` 后：NaN 与 ±0 归 0，±Infinity 归 i32 的最小/最大值，其余 `@trunc` 后夹到 i32 范围。 可返回 `error.TypeError`。 关键调用：`core.number.toNumber`。
- **所有权 / 错误 / 调用**：不分配、不建根。`error.TypeError` 只用于 symbol / bigint 参数，由 `numberPrototypeMethod` 落成「not a number」。`core.number.toNumber` 不带 ctx、不回调 JS（字符串 / 包装对象走 `appendValueString` + `parseJsNumber`，中途的字节缓冲在它内部释放），真正可观察的 ToNumber 已经由 `numberPrototypeMethod` 提前做过。调用方：`toFixed`、`toExponential`、`toPrecision` 三个格式化体（默认值 0）与 `toStringMethod`（默认值 10，取 radix）。

## 覆盖核对

- 清单函数数: 234（`src/exec/date_ops.zig` 80 + `src/exec/json_ops.zig` 100 + `src/exec/math_ops.zig` 40 + `src/exec/number_ops.zig` 14）
- 本文标题覆盖: 234
- 未覆盖: 无
