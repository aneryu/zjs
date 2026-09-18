# 15 — `array_ops.zig`：迭代、搜索、slice/splice、mutating

从 `arrayAtCall` 到 `toIntegerOrInfinityForArrayMethod`。空洞：非 find 族用 `hasValueProperty` 跳过；find 族对缺席下标仍 Get（得到 `undefined` 并调用回调）。TypedArray 方法要求 TypedArray this，否则 TypeError。

### `arrayAtCall` (`src/exec/array_ops.zig:1324`)

- **签名**：`pub fn arrayAtCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, func: core.JSValue, args: []const core.JSValue, ) !?core.JSValue`。
- **作用**：`Array.prototype.at` / `%TypedArray%.prototype.at` 的 VM 快调用臂。
- **实现**：callee 必须是 `at` 这个 record id，否则退回按函数名比对；都对不上返回 `null` 让级联继续。nullish receiver 抛「Cannot convert undefined or null to object」，primitive 装箱。TypedArray 域的方法要求 TypedArray this 并查 detached/OOB。length：TA 用 `typedArrayLength`，Array 用 `arrayLength()`，否则 Get `length` + ToLength。下标经 ToPrimitive→ToNumber：NaN 当 0，±Infinity 直接 `undefined`，负数从尾部折算；越界返回 `undefined`，否则按下标 `[[Get]]`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 值，或 null 表示「不是我这条方法」让调用方继续往下找；`receiver`/`func`/`args` 是 VM 栈上的借用。不分配（`propertyAtomFromLengthIndex` 的 atom 由 `defer key.deinit` 退 pin），返回的元素值来自 `getValueProperty`。error set：`throwTypeErrorMessage`（它建好带消息的 TypeError、挂成 pending 异常后**返回 `error.TypeError`**，所以 `try` 之后的 `@as(?JSValue, ...)` 永远到不了）；`%TypedArray%.prototype.at` 打在非 TypedArray / detached / 越界上是裸 `error.TypeError`；长度与 index 的强制转换会跑用户代码并透传其异常。调用方三处：`arrayMethodFastCall`（`:196`）、`exec/call_runtime.zig:1275`、记录 hub `:243`。

### `arrayIterationModeFromRecordId` (`src/exec/array_ops.zig:1395`)

- **签名**：`inline fn arrayIterationModeFromRecordId(record_id: u32) ?ArrayIterationMode`。
- **作用**：把 `.array` 域的 record id 映射成 `ArrayIterationMode`；不属于迭代族的 id 返回 null。
- **实现**：对 for_each/map/filter/some/every/find/find_index/find_last/find_last_index 九个 id 做 `switch`，其余 `null`。
- **所有权 / 错误 / 调用**：无：`inline fn` 的 comptime 可折叠 id→mode 查表，不分配、无 error set、不跑用户代码。调用方 `arrayPrototypeNativeRecord`（`:235`）与 `arrayIterationCall`（`:1433`），两条路径靠它共享同一个 `arrayIterationModeCall` 实现。

### `arrayIterationModeIsFind` (`src/exec/array_ops.zig:1410`)

- **签名**：`inline fn arrayIterationModeIsFind(mode: ArrayIterationMode) bool`。
- **作用**：判断 mode 是否属于 find 族（`find`/`find_index`/`find_last`/`find_last_index`）——find 族不做 HasProperty 跳洞。
- **实现**：四个 mode 返回 true，其余 false。
- **所有权 / 错误 / 调用**：无：`inline` 纯 switch，不分配、无 error、不接触 JSValue 或 atom。唯一调用方 `arrayIterationCall`（`src/exec/array_ops.zig:1474`），把结果存成 `find_family` 供后面的洞判定复用。

### `arrayIterationCall` (`src/exec/array_ops.zig:1417`)

- **签名**：`pub fn arrayIterationCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：用 native record id 或函数名识别 forEach/map/filter/some/every/find*。
- **实现**：callee 不是 native callable 直接 `null`；`collectionMethodOwnerClass()` 是 Map/Set 时也返回 `null`（同名的集合方法不归这里）。用 native record id 或函数名识别 forEach/map/filter/some/every/find*。真正循环在 `arrayIterationModeCall`：TypedArray 方法要求 TypedArray this；map/filter 用 `arraySpeciesCreate` 造输出；非 find 族对普通数组先 `hasValueProperty` 跳洞；dense map 仅在 `index == fastArrayCount()` 时走无洞追加，否则稀疏化以保留空洞。对不上这个 builtin 时返回 `null`，让上层继续级联。
- **所有权 / 错误 / 调用**：返回 owned 值，或 null 表示「不是我这条方法」让调用方继续往下找；`receiver`/`func`/`args` 是 VM 栈上的借用。自身不分配，真正的工作全部转给 `arrayIterationModeCall`；名字回退分支的 `dispatch_name` 由 `defer dispatch_name.deinit` 释放。先按 record id 认，认不出再按函数名认，Map/Set 的同名方法在开头被 `collectionMethodOwnerClass` 挡掉。调用方 `arrayMethodFastCall`（`:195`）与 `exec/call_runtime.zig:1274`。

### `arrayIterationModeCall` (`src/exec/array_ops.zig:1463`)

- **签名**：`noinline fn arrayIterationModeCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, function_object: *core.Object, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, mode: ArrayIterationMode, ) !?core.JSValue`。
- **作用**：forEach/map/filter/some/every/find* 的真正循环：按 mode 决定是否跳洞、是否用 species 造输出、以及回调返回值如何消费。
- **实现**：nullish receiver 抛「Cannot convert undefined or null to object」，否则 primitive 装箱。TypedArray prototype 方法要求 TypedArray this，否则 `error.TypeError`。length：TA 走 `arrayMethodTypedArrayLength`，Array 走 `arrayLength()`，否则 Get `length` + ToLength。`args[0]` 必须可调用，否则「not a function」；`thisArg` 缺省 `undefined`。map 且 length > u32 最大值 → `error.RangeError`。TypedArray 的 map/filter 转 `typedArrayMapFilter`。map/filter 用 `arraySpeciesCreate` 造输出；dense map 仅当 `index == fastArrayCount()` 才走无检查 dense 追加，否则改走 index-define，输出变稀疏以保留空洞。find_last* 从尾往前。非 find 族对普通数组先 `hasValueProperty` 跳洞；find 族 Get 得到 `undefined` 仍调回调。dense 数组先 `getDenseArrayElementValue`。回调经 `CallSite.call3(item, index, receiver)`。终值：forEach `undefined`；map/filter 输出数组；some `false`；every `true`；find* `undefined` / `-1`。
- **所有权 / 错误 / 调用**：返回 owned 值：map/filter 返回 species 产出的输出对象（**可能是用户构造器造的任意对象**，所以后面用 `createDataPropertyOrThrow` 而不是直写），find 族返回借用自源数组的元素值，其余是立即数。`out_value` 只由 Zig 局部持有，依赖保守栈扫描而非显式根帧。error set：receiver 为 null/undefined 与 callback 不可调用走 `throwTypeErrorMessage`（带消息，返回 `error.TypeError`）；`%TypedArray%` 方法打在非 TypedArray 上是裸 `error.TypeError`；`map` 且 length > u32 上限 → `error.RangeError`；用户回调、species 构造、属性读写的异常一律原样透传。调用方 `arrayIterationCall`（`:1460`）与记录 hub `arrayPrototypeNativeRecord`（`:236`）。

### `typedArrayMapFilter` (`src/exec/array_ops.zig:1603`)

- **签名**：`pub fn typedArrayMapFilter( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver_value: core.JSValue, object: *core.Object, length: usize, mode: ArrayIterationMode, callback_call: *CallSite, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`%TypedArray%.prototype.map` / `filter` 的循环体（Array 版走 `arrayIterationModeCall`）。
- **实现**：TypedArray 输出走 `%TypedArray%.@@species`，与 Array 的 species 链分开。map：先按 length 造输出，再边调回调边 `typedArraySetIndex`，输出对象用一格 slice 窗口做成容器根（标量根在生产里不可靠）。filter：先把选中的元素攒进一块 rooted 缓冲，循环**结束后**才解析 species 构造器并按 `kept_count` 造输出，再逐个写入。跨越可分配/用户回调的值用 `rootValues` / ValueRootFrame 钉住。含循环：按 length 或迭代器步进处理元素。关键调用：`typedArraySpeciesConstructorForObject`、`typedArrayCreateWithLength`、`out_frame.activate`、`out_frame.deactivate`、`objectFromValue`、`typed_array.typedArrayGetIndex`、`callback_call.call3`、`lengthIndexValue`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 的 TypedArray 结果值；`receiver_value` / `object` / `callback_call` 都是调用方持有的借用，`callback_call` 指向调用方栈上的 `CallSite`。GC 是这里的重点：map 臂把 `out_value` 放进一个单元素窗口并以 `.mutable` 切片挂 `ValueRootFrame`（生产不为标量建根，只认容器），filter 臂 `rt.memory.alloc` 一块 `kept` 缓冲、用 `rooted_kept = kept[0..kept_count]` 只把已填部分暴露给 tracer，成功路径逐个清空后 free，失败路径由 `errdefer` 清空 + free。error set：species 构造与用户回调透传、结果不是对象 → `error.TypeError`、`typedArraySetIndex` 的 detached 错误。唯一调用方 `arrayIterationModeCall`（`:1506`）。

### `typedArrayCreateWithLength` (`src/exec/array_ops.zig:1686`)

- **签名**：`pub fn typedArrayCreateWithLength( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor_value: core.JSValue, requested_length: usize, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：ES `TypedArrayCreate`：用给定构造器造一条至少 `requested_length` 长的 TypedArray 并校验。
- **实现**：`constructValueOrBytecode(constructor, [length])` 之后三查：结果必须是对象、必须是 TypedArray、长度不得小于请求值，任一不满足即 `error.TypeError`；最后 `typedArrayRejectImmutableBuffer` 拒掉 immutable buffer。关键调用：`constructValueOrBytecode`、`lengthIndexValue`、`objectFromValue`、`object.isTypedArrayObject`、`object.typedArrayLength`、`object.typedArrayRejectImmutableBuffer`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 的结果视图；它调用的是**用户可控的 species 构造器**，所以随后三道校验（不是对象 / 不是 TypedArray / 长度不足）全部是 `error.TypeError`，还额外 `typedArrayRejectImmutableBuffer`。不分配本地缓冲、不建根。调用方五处：`typedArrayMapFilter` 的 map 臂（`:1617`）与 filter 臂（`:1674`）、`typedArraySliceSubarrayCall`（`:2349`）、`arrayByCopyCall`（`:4415`）、`typedArrayOfStaticCall`（`:4649`）。

### `arrayReduceCall` (`src/exec/array_ops.zig:1703`)

- **签名**：`pub fn arrayReduceCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, func: core.JSValue, args: []const core.JSValue, from_right: bool, ) !?core.JSValue`。
- **作用**：`Array.prototype.reduce` 与 `reduceRight`（`from_right` 选方向）的共用实现。
- **实现**：按 `from_right` 选 record id / 函数名（`@reduce` 或 `reduceRight`），对不上返回 `null`。nullish receiver 抛「Cannot convert undefined or null to object」；TypedArray 域方法要求 TypedArray this。`args[0]` 不可调用抛「not a function」；`args[1]` 在时作初值。`from_right` 且 `length > maxInt(u32)` 改走 `arrayReduceRightSparseLarge`。主循环按方向取下标：TypedArray 用 `typedArrayIndexValid` + `typedArrayGetIndex`，dense 数组先试 `getDenseArrayElementValue`。缺席下标（空洞）用 `HasProperty` 跳过，不把 `undefined` 当元素。无初值且一个元素都没有则抛「empty array」。回调经 `call4(acc, item, index, receiver)`。含循环：按 length 或迭代器步进处理元素。关键调用：`callableObjectFromValue`、`isArrayPrototypeRecord`、`call_mod.nativeFunctionNameForVmEquals`、`receiver.isNull`、`receiver.isUndefined`、`throwTypeErrorMessage`、`objectFromValue`、`primitiveObjectForAccess`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 值，或 null 表示「不是我这条方法」让调用方继续往下找；`receiver`/`func`/`args` 是 VM 栈上的借用。累加器 `accumulator` 只是 Zig 局部（借用，靠保守栈扫描活过用户回调），返回时所有权交给调用方。error set：receiver 为 null/undefined、callback 不可调用、空数组且无初值都走 `throwTypeErrorMessage`（带消息的 TypeError）；`%TypedArray%.prototype.reduce*` 打在非 TypedArray 上是裸 `error.TypeError`；用户回调与属性读取透传。`from_right` 且 length > u32 上限时整个转交 `arrayReduceRightSparseLarge`。调用方四处：`arrayMethodFastCall`（`:197`/`:198`）、`exec/call_runtime.zig:1276`/`:1277`、记录 hub `:241`/`:242`。

### `arrayReduceRightSparseLarge` (`src/exec/array_ops.zig:1802`)

- **签名**：`pub fn arrayReduceRightSparseLarge( ctx: *core.JSContext, object: *core.Object, receiver: core.JSValue, callback_call: *CallSite, has_initial: bool, initial: core.JSValue, length: usize, ) !core.JSValue`。
- **作用**：`reduceRight` 在 length 超过 `maxInt(u32)` 时的稀疏路径：只遍历实际存在的 own 索引键，不逐个下标空转。
- **实现**：`ownKeys` 取全部键，`propertyIndexFromLengthKey` 筛出 `< length` 的索引键收进列表，用 `sort_erased.heap` 按 index **降序**排，再逐个 `object.getProperty` 累加。无初值时第一个元素当累加器；一个元素都没有且无初值返回 `error.TypeError`。含循环：按 length 或迭代器步进处理元素。关键调用：`object.ownKeys`、`Object.freeKeys`、`indexed.deinit`、`propertyIndexFromLengthKey`、`array_list_erased.append`、`sort_erased.heap`、`lessThan`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 的累加结果。`object.ownKeys` 的键数组由 `defer core.Object.freeKeys` 释放，`indexed` 这块 `SparseIndexKey` 列表由 `defer indexed.deinit` 释放（两者都只装 atom 与索引，不是 GC 边，因此不需要根帧）。error set：没有元素且无初值 → 裸 `error.TypeError`（**与 `arrayReduceCall` 的带消息版本不同**），其余由 `getProperty` 与用户回调透传。唯一调用方 `arrayReduceCall`（`:1756`），只在 reduceRight 且 length > u32 上限时走到。

### `ArrayIterationMode.lessThan` (`src/exec/array_ops.zig:1821`)

- **签名**：`fn lessThan(_: void, a: SparseIndexKey, b: SparseIndexKey) bool`。
- **作用**：`arrayReduceRightSparseLarge` 内联的堆排序比较器。
- **实现**：`return a.index > b.index`——按索引**降序**，因为 reduceRight 从尾往前走。
- **所有权 / 错误 / 调用**：无：`sort_erased.heap` 的比较器，只比 `SparseIndexKey.index` 这个标量，不分配、无 error、不接触 JSValue。源码里它是写在 `arrayReduceRightSparseLarge`（`src/exec/array_ops.zig:1802`）那一次 `sort_erased.heap` 调用里的匿名 struct 成员（标题的 `ArrayIterationMode.` 只是分册的限定前缀），没有别的引用点；被排的 `indexed` 列表由该函数 `defer indexed.deinit` 释放。

### `arrayMethodTypedArrayLength` (`src/exec/array_ops.zig:1844`)

- **签名**：`pub fn arrayMethodTypedArrayLength(rt: *core.JSRuntime, object: *core.Object, is_typed_method: bool) !usize`。
- **作用**：给数组方法读 TypedArray 长度：detached 一律 TypeError；OOB（RAB 缩短）时 TypedArray 域方法 TypeError，Array 域方法返回 0。
- **实现**：三步：`typedArrayDetached` 为真 → `error.TypeError`；`typedArrayOutOfBounds` 为真时按 `is_typed_method` 分叉（`%TypedArray%` 方法 → `error.TypeError`，Array 泛型方法 → 返回 0）；都不成立才 `typedArrayLength` 取当前长度。
- **所有权 / 错误 / 调用**：返回长度数字，不分配、不建根。它是 detached 语义的分叉点：`%TypedArray%` 方法（`is_typed_method`）上越界视图报 `error.TypeError`，而 Array 泛型方法打在 TypedArray 上时越界一律折成长度 0。detached 两种情况都是 `error.TypeError`。调用方 12 处：本文件 9 处（`:1486`、`:1528`、`:1730`、`:2784`、`:2868`、`:3323`、`:4839`、`:6598`、`:6617`，iteration/reduce/copyWithin/fill/reverse/sort/join 各臂），以及 `exec/string_ops.zig:2960`、`:3337`、`:3350`（search/join 家族，经该文件别名）。

### `typedArraySearchScan` (`src/exec/array_ops.zig:1867`)

- **签名**：`pub fn typedArraySearchScan( rt: *core.JSRuntime, object: *core.Object, mode: TypedSearchMode, search_value: core.JSValue, start: usize, original_length: usize, ) !core.JSValue`。
- **作用**：搜索值只看 tag，不做 ToNumber。
- **实现**：搜索值只看 tag，不做 ToNumber。不能装进元素类型则立即未命中。u8 类用 memchr；整数类按 little-endian 读；浮点 NaN 只被 includes 命中，±0 互相匹配。RAB 在 fromIndex 的 valueOf 里缩小时，includes+undefined 可对越界窗口返回 true。QuickJS 坐标：quickjs.c:58114-58119、quickjs.c:58122-58129、quickjs.c:58131-58177。
- **所有权 / 错误 / 调用**：返回立即数（`includes` 是 boolean，其余是索引或 -1），全程不分配、不建根、**不跑任何用户代码**——搜索值只看 tag 不做强制转换，扫描直接在 `byteStorage()` 的借用字节切片上做。error set 只有 `typedArrayLength` / `typedArrayBufferObject` 透传的 detached 类错误。⚠️ 调用方必须保证 fromIndex 的强制转换已经跑完（它可能 resize RAB），所以本函数同时收 `start` 与 `original_length` 并按 `@min` 重新夹紧窗口。唯一调用方 `exec/string_ops.zig:2985`（`arraySearchCall` 的 TypedArray 臂）。

### `searchScanResult` (`src/exec/array_ops.zig:2001`)

- **签名**：`fn searchScanResult(mode: TypedSearchMode, res: ?usize) core.JSValue`。
- **作用**：把底层扫描给出的 `?usize` 下标折成三个 API 各自的返回值形状，`typedArraySearchScan` 的每一条出口都经过它。
- **实现**：`mode == .includes` 时只回 `res != null` 的布尔；`indexOf`/`lastIndexOf` 命中回 `lengthIndexValue(index)`、未命中回 `JSValue.int32(-1)`。因为提前返回（长度为 0、游标越界、搜索值类型与数组种类对不上等）全都走这里，「找不到」的编码只在这一处成形。
- **所有权 / 错误 / 调用**：无：纯映射函数（`?usize` → boolean 或索引立即数），不分配、无 error set。唯一使用者是 `typedArraySearchScan` 的全部返回点（未命中与各 class 分支共 10 余处）。

### `scanU8` (`src/exec/array_ops.zig:2006`)

- **签名**：`fn scanU8(bytes: []const u8, k: usize, stop: usize, forward: bool, v: u8) ?usize`。
- **作用**：`Int8Array` / `Uint8Array` / `Uint8ClampedArray` 的单字节扫描臂（元素宽度 1，下标即字节偏移）。
- **实现**：正向用 `std.mem.indexOfScalarPos(u8, bytes[0..stop], k, v)`（对应 qjs 对 u8 类走 memchr，quickjs.c:58192-58197）；反向从 `k` 往下逐字节比，到达 `stop`（含）停。命中返回元素下标，否则 null。
- **所有权 / 错误 / 调用**：无：在借用的字节切片上扫描，返回 `?usize`，不分配、无 error set、不跑用户代码。前向用 `std.mem.indexOfScalarPos`（对齐 qjs 的 memchr），反向自减循环以 `i == stop` 收尾——因此 `stop` 是**闭区间下界**，与前向的开区间上界不对称，改动时必须连着 `typedArraySearchScan` 里 k/stop 的换算一起看。唯一调用方 `typedArraySearchScan` 的 Int8/Uint8/Uint8Clamped 三臂。

### `scanElem` (`src/exec/array_ops.zig:2020`)

- **签名**：`fn scanElem(comptime T: type, bytes: []const u8, k: usize, stop: usize, forward: bool, v: T) ?usize`。
- **作用**：定宽整数元素的按位相等扫描臂，`T` 由调用方按数组种类实例化成 `i16`/`u16`/`i32`/`u32`/`i64`/`u64`。
- **实现**：按 `@sizeOf(T)` 步长用 `std.mem.readInt(..., .little)` 读元素比对；正向 `[k, stop)`，反向从 `k` 递减到 `stop`（含）。命中返回元素下标。
- **所有权 / 错误 / 调用**：无：comptime 按元素类型特化的扫描，读 `std.mem.readInt(.little)`，不分配、无 error set。字节切片借用自 buffer，调用期间不得有 GC/resize（调用方已在 `typedArraySearchScan` 里保证扫描前不再跑用户代码）。唯一调用方 `typedArraySearchScan` 的 i16/u16/i32/u32/i64/u64 六臂。

### `readFloat` (`src/exec/array_ops.zig:2037`)

- **签名**：`fn readFloat(comptime T: type, bytes: []const u8, index: usize) T`。
- **作用**：从 buffer 字节里按元素下标取出一个浮点值，供三个浮点扫描臂共用。
- **实现**：用 `std.meta.Int(.unsigned, @bitSizeOf(T))` 取同宽无符号整型，`std.mem.readInt(..., .little)` 从 `index * @sizeOf(T)` 处读出位模式，再 `@bitCast` 成 `T`。走整数读而不是解引用浮点指针，所以不要求字节切片满足浮点对齐；读的是原始位，NaN 的具体 payload 原样保留。
- **所有权 / 错误 / 调用**：无：纯读取工具（按位读出 `T` 宽度的无符号整数再 `@bitCast` 成浮点），不分配、无 error set、不做边界检查——越界由调用方的循环条件保证。调用方 `scanFloat16`、`scanFloat`、`scanFloatPredicate` 三处。

### `scanFloat16` (`src/exec/array_ops.zig:2043`)

- **签名**：`fn scanFloat16(mode: TypedSearchMode, bytes: []const u8, k: usize, stop: usize, forward: bool, d: f64) ?usize`。
- **作用**：`Float16Array` 的扫描臂：搜索值先要能无损往返 f16，NaN 与 ±0 另走谓词。
- **实现**：搜索值是 NaN 时只有 `includes` 会扫（谓词 `isNan`），`indexOf`/`lastIndexOf` 直接 null（quickjs.c:58249-58259）；`d == 0` 时用谓词 `e == 0`，+0/−0 互相命中（quickjs.c:58260-58268）。其余情况先看 `d` 能否无损往返 f16（`@floatCast` 回去要等于原值），不能就 null；能则按 f16 逐元素比对，正向 `[k, stop)`、反向递减到 `stop`（含）。
- **所有权 / 错误 / 调用**：无：不分配、无 error set；NaN 与 ±0 两种特例转给 `scanFloatPredicate`，普通值先检查能否无损往返 f16，不能就直接判未命中。唯一调用方 `typedArraySearchScan` 的 Float16 臂（`:1977`）。

### `TypedSearchMode.match` (`src/exec/array_ops.zig:2048`)

- **签名**：`fn match(e: f16) bool`。
- **作用**：浮点扫描谓词：NaN 或 ±0 等特殊相等。
- **实现**：薄封装，主体转发到 `math.isNan`。
- **所有权 / 错误 / 调用**：无：`scanFloat16` NaN 分支传给 `scanFloatPredicate` 的 comptime 比较闭包（`isNan`），不分配、无 error set；它只在 `mode == .includes` 时被用到——`indexOf`/`lastIndexOf` 按 spec 找不到 NaN，在上一层就返回 null 了。

### `TypedSearchMode.match` (`src/exec/array_ops.zig:2056`)

- **签名**：`fn match(e: f16) bool`。
- **作用**：浮点扫描谓词：NaN 或 ±0 等特殊相等。
- **实现**：`return e == 0`——+0 与 −0 都命中（f16 零值臂）。
- **所有权 / 错误 / 调用**：无：f16 零值谓词，纯比较，不分配、无 error。源码里它是 `scanFloat16`（`src/exec/array_ops.zig:2043`）`d == 0` 臂中那次 `scanFloatPredicate` 调用的匿名 struct 成员（同文件 `:2048` 还有一个同名的 NaN 版），标题前缀是分册限定名，没有别的调用点。

### `scanFloat` (`src/exec/array_ops.zig:2080`)

- **签名**：`fn scanFloat(comptime T: type, mode: TypedSearchMode, bytes: []const u8, k: usize, stop: usize, forward: bool, d: f64) ?usize`。
- **作用**：`Float32Array` / `Float64Array` 的扫描臂，`T` 同时决定元素宽度和要不要做 f32 往返判定。
- **实现**：NaN 只有 `includes` 会扫（谓词 `isNan`），其余 null（quickjs.c:58282-58292）。否则 `target = @floatCast(d)`：`T == f32` 时还要求往返回 f64 等于原值才扫（quickjs.c:58293），f64 直接扫（quickjs.c:58317-58324）；`+0.0 == -0.0` 天然互相命中。正向 `[k, stop)`、反向递减到 `stop`（含）。
- **所有权 / 错误 / 调用**：无：不分配、无 error set；`T` 是 comptime 参数（f32/f64）。NaN 与 ±0 走谓词扫描，f32 还要求目标值能无损往返，否则直接未命中。唯一调用方 `typedArraySearchScan` 的 Float32/Float64 两臂。

### `TypedSearchMode.match` (`src/exec/array_ops.zig:2085`)

- **签名**：`fn match(e: T) bool`。
- **作用**：浮点扫描谓词：NaN 或 ±0 等特殊相等。
- **实现**：薄封装，主体转发到 `math.isNan`。
- **所有权 / 错误 / 调用**：无：`scanFloat` NaN 分支的 comptime 比较闭包（按 `T` 特化的 `isNan`），不分配、无 error set，同样只服务 `includes`。

### `scanFloatPredicate` (`src/exec/array_ops.zig:2109`)

- **签名**：`fn scanFloatPredicate(comptime T: type, bytes: []const u8, k: usize, stop: usize, forward: bool, comptime match: fn (T) bool) ?usize`。
- **作用**：浮点扫描的谓词版，给两种「不能用相等判断」的情形用：`includes` 找 NaN（`==` 对 NaN 恒假）和找 0（要同时命中 +0 与 −0）。
- **实现**：按 comptime 谓词 `match` 逐元素扫：正向 `[k, stop)`，反向从 `k` 递减到 `stop`（含）；命中返回下标，否则 null。
- **所有权 / 错误 / 调用**：无：把比较谓词做成 comptime 参数的扫描骨架，不分配、无 error set。与 `scanU8`/`scanElem` 一样，前向 `stop` 是开区间上界、反向 `stop` 是闭区间下界。调用方 `scanFloat16`（两处特例分支）与 `scanFloat`（NaN 分支）。

### `arrayLastIndexSparseLarge` (`src/exec/array_ops.zig:2125`)

- **签名**：`pub fn arrayLastIndexSparseLarge( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, receiver: core.JSValue, args: []const core.JSValue, length: usize, search_value: core.JSValue, ) !core.JSValue`。
- **作用**：`lastIndexOf` 的稀疏路径：只看实际存在的 own 索引键，按下标降序找第一个严格相等的元素。
- **实现**：`arrayLastIndexStart` 折出独占上界，`ownKeys` + `propertyIndexFromLengthKey` 筛出 `< min(上界, length)` 的索引键，`sort_erased.heap` 按 index **降序**排，逐个 `[[Get]]` 后 `valuesStrictEqual` 比较；命中返回下标，全不中返回 `-1`。含循环：按 length 或迭代器步进处理元素。关键调用：`arrayLastIndexStart`、`object.ownKeys`、`Object.freeKeys`、`indexed.deinit`、`propertyIndexFromLengthKey`、`array_list_erased.append`、`sort_erased.heap`。
- **所有权 / 错误 / 调用**：返回索引立即数或 `int32(-1)`。`ownKeys` 的键数组由 `defer freeKeys` 释放，`indexed` 列表由 `defer indexed.deinit` 释放，二者都不是 GC 边。⚠️ 次序契约：`arrayLastIndexStart` 先跑（fromIndex 的用户强制转换在**收集键之前**），键快照因此是强制转换之后的状态。error set：强制转换、`getValueProperty` 的 getter 与 `valuesStrictEqual` 透传。唯一调用方 `exec/string_ops.zig:2988`（`arraySearchCall` 的大稀疏 lastIndexOf 臂）。

### `TypedSearchMode.lessThan` (`src/exec/array_ops.zig:2146`)

- **签名**：`fn lessThan(_: void, a: SparseIndexKey, b: SparseIndexKey) bool`。
- **作用**：`arrayLastIndexSparseLarge` 内联的堆排序比较器。
- **实现**：`return a.index > b.index`——按索引**降序**，lastIndexOf 从尾往前找。
- **所有权 / 错误 / 调用**：无：与 `:1821` 那个同形——`sort_erased.heap` 的标量比较器，不分配、无 error。源码位置是 `arrayLastIndexSparseLarge`（`src/exec/array_ops.zig:2125`）里那次排序调用的匿名 struct 成员，没有别的引用点。

### `arrayFirstIndexStart` (`src/exec/array_ops.zig:2157`)

- **签名**：`pub fn arrayFirstIndexStart( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, length: usize, ) !usize`。
- **作用**：把 `indexOf`/`includes` 的 `fromIndex`（`args[1]`）折成**闭区间**起始下标。
- **实现**：无该参数返回 0；NaN/−Infinity → 0，+Infinity 或 ≥ length → length；非负取截断值；负数按 `length + trunc(n)` 折算，仍 ≤ 0 则 0。关键调用：`toIntegerOrInfinityForArrayByCopy`、`math.isNan`、`math.isPositiveInf`、`math.isNegativeInf`、`@floatFromInt`、`@intFromFloat`、`@trunc`。
- **所有权 / 错误 / 调用**：返回起始索引（闭区间下界），不分配、不建根；会经 `toIntegerOrInfinityForArrayByCopy` 跑用户 ToPrimitive，调用方必须假定长度此后可能已变。无自有 error set，只透传强制转换的 `error.TypeError` 等。调用方 `exec/string_ops.zig:2984`、`:2999`（indexOf / includes 的 fromIndex）。

### `arrayLastIndexStart` (`src/exec/array_ops.zig:2176`)

- **签名**：`pub fn arrayLastIndexStart( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, length: usize, ) !usize`。
- **作用**：把 `lastIndexOf` 的 `fromIndex` 折成**独占上界**（扫描到的最大下标是返回值 −1），`typedArraySearchScan` 的 `start` 就按这个约定。
- **实现**：无该参数或 NaN/+Infinity 返回 length；−Infinity 返回 0；`n >= length-1` 返回 length；非负返回 `trunc(n) + 1`；负数按 `length + trunc(n)` 折算，< 0 则 0，否则 `+1`。关键调用：`toIntegerOrInfinityForArrayByCopy`、`math.isNan`、`math.isNegativeInf`、`math.isPositiveInf`、`@floatFromInt`、`@intFromFloat`、`@trunc`。
- **所有权 / 错误 / 调用**：返回的是**开区间上界**（`k + 1`），与 `arrayFirstIndexStart` 的闭区间下界不对称——`typedArraySearchScan` 与稀疏 lastIndexOf 都按这个约定换算。同样会跑用户 ToPrimitive，无自有 error set。调用方 `exec/string_ops.zig:2982`、`:2997` 与本文件 `arrayLastIndexSparseLarge`（`:2135`）。

### `arraySliceCall` (`src/exec/array_ops.zig:2196`)

- **签名**：`pub fn arraySliceCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, func: core.JSValue, args: []const core.JSValue, ) !?core.JSValue`。
- **作用**：默认 species 且源是 dense、切片完全落在 `fastArrayCount()` 内时，一次 `createArrayStorageSlice` + 整段复制后 adopt 成新数组的 dense 存储；否则 `arraySpeciesCreate` 后对每个下标 `arrayCopyPresentIndex`（缺席即跳过，保留空洞）。
- **实现**：默认 species 且源是 dense、切片完全落在 `fastArrayCount()` 内时，一次 `createArrayStorageSlice` + 整段复制（不是逐个 `[[Get]]`）；否则 `arraySpeciesCreate` 后对每个下标 `arrayCopyPresentIndex`（缺席即跳过，保留空洞）。空洞尾巴（count < length）禁止走 bulk copy。QuickJS 坐标：quickjs.c:42967-42971、quickjs.c:9601。输出数组经 `arraySpeciesCreate` / `@@species` 构造。跨越可分配/用户回调的值用 `rootValues` / ValueRootFrame 钉住。含循环：按 length 或迭代器步进处理元素。对不上这个 builtin 时返回 `null`，让上层继续级联。错误：error.TypeError、error.RangeError。
- **所有权 / 错误 / 调用**：返回 owned 值，或 null 表示「不是我这条方法」让调用方继续往下找；`receiver`/`func`/`args` 是 VM 栈上的借用。两条产出路径的所有权不同：dense 快路 `createArray` 后用 `rootValues` 把新数组挂成根（后面的 `createArrayStorageSlice` 会分配、可能 GC），再 `adoptDenseArrayElementsAssumingEmpty` 把新铸的 `.array_storage` cell 整块交给它；慢路由 `arraySpeciesCreate` 产出（可能是用户对象），逐个 `arrayCopyPresentIndex` 复制并**保留洞**。error set：receiver 为 null/undefined → 裸 `error.TypeError`，`count > u32` 上限 → `error.RangeError`，species 构造与属性读写透传。调用方 `arrayMethodFastCall`（`:209`）、`exec/call_runtime.zig:1288`、记录 hub `:256`。

### `typedArraySliceSubarrayCall` (`src/exec/array_ops.zig:2303`)

- **签名**：`pub fn typedArraySliceSubarrayCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, func: core.JSValue, args: []const core.JSValue, ) !?core.JSValue`。
- **作用**：`slice` 用 species 构造新 buffer 再拷元素；同类同布局走 memcpy/copyForwards（可能 alias）。
- **实现**：`slice` 用 species 构造新 buffer 再拷元素；同类同布局走 memcpy/copyForwards（可能 alias）。`subarray` 共享原 buffer，只改 byteOffset/length；auto-length 视图省略第三参数。detached / OOB 在 slice 入口即 TypeError。QuickJS 坐标：quickjs.c:58572-58575、quickjs.c:58519。TypedArray 输出走 `%TypedArray%.@@species`，与 Array 的 species 链分开。对不上这个 builtin 时返回 `null`，让上层继续级联。错误：error.TypeError、error.RangeError。
- **所有权 / 错误 / 调用**：返回 owned 值，或 null 表示「不是我这条方法」让调用方继续往下找；`receiver`/`func`/`args` 是 VM 栈上的借用。`dispatch_name` 由 `defer deinit` 释放。返回值来自 species 构造器（用户可控），因此结果不是 TypedArray 就 `error.TypeError`；subarray 臂把源 buffer 值原样传给构造器（新视图借用同一块 backing store，不拷贝），slice 臂在同类时按字节 `@memcpy`／重叠时 `copyForwards`。error set：非 TypedArray receiver 且调用的是 `%TypedArray%` 方法 → `error.TypeError`（否则 null）、detached/越界 → `error.TypeError`、`count > maxInt(i32)` 与 subarray 的偏移越界 → `error.RangeError`。调用方 `arrayMethodFastCall`（`:208`）与 `exec/call_runtime.zig:1287`。

### `typedArrayConstructorForObject` (`src/exec/array_ops.zig:2400`)

- **签名**：`pub fn typedArrayConstructorForObject(rt: *core.JSRuntime, global: *core.Object, object: *core.Object) !core.JSValue`。
- **作用**：按一个 TypedArray 实例的内部 kind 取回同名的全局构造器（`Float64Array` 等），用作 species 解析的默认值。
- **实现**：`typedArrayNameFromKind` 取名字，kind 不是已知种类 → `error.TypeError`；`rt.internAtom` 后从 `global` 上读同名属性，读出来不是对象 → TypeError。取的是当前 global 上的那个绑定而不是固化 intrinsic，所以脚本覆写全局构造器会被这里看见。
- **所有权 / 错误 / 调用**：返回 owned 的构造器值——取的是 `global` 上那个名字的**当前属性值**（`Uint8Array` 等可被用户改写），不是硬编码 intrinsic；`internAtom` 新建的 atom 由运行时 atom 表持有。error set：认不出 kind、或该全局属性不是对象 → `error.TypeError`。调用方 `typedArraySpeciesConstructorForObject`（`:2419`）与 `typedArrayCreateSameType`（`:5479`）。

### `typedArraySpeciesConstructorForObject` (`src/exec/array_ops.zig:2410`)

- **签名**：`pub fn typedArraySpeciesConstructorForObject( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, object: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：TypedArray 版的 SpeciesConstructor：给 `%TypedArray%.prototype.slice`/`subarray`/`filter`/`map` 这类要产出新视图的方法挑构造器。
- **实现**：默认值来自 `typedArrayConstructorForObject`（按实例 kind 取同名全局构造器），与 Array 的 species 链是两套。随后读 receiver 的 `constructor`：undefined 用默认；不是对象 → TypeError；是对象则再读它的 `Symbol.species`，undefined 或 null 仍用默认，其余原样返回。两次属性读都经 `getValueProperty` 并透传 `caller_function`/`caller_frame`，所以用户 getter 会执行、且保留调用方的内联缓存提示。与 `arrayBufferSpeciesConstructor` 不同，这里不对结果做 `isConstructorLike` 检查，交由构造现场去判。
- **所有权 / 错误 / 调用**：返回 owned 的构造器值：`constructor` 为 undefined 或其 `Symbol.species` 为 undefined/null 时回退默认构造器，否则用用户给的 species（**这里不校验它是不是构造器**，留给后面的 `typedArrayCreateWithLength` / `constructValueOrBytecode` 报错）。error set：`constructor` 不是对象、取不到 `Symbol.species` atom → `error.TypeError`，两次属性读的 getter 透传。调用方 `typedArrayMapFilter`（`:1616`、`:1673`）与 `typedArraySliceSubarrayCall`（`:2331`）。

### `fastDenseArraySplice` (`src/exec/array_ops.zig:2444`)

- **签名**：`fn fastDenseArraySplice( ctx: *core.JSContext, global: *core.Object, receiver: core.JSValue, object: *core.Object, length: usize, actual_start: usize, actual_delete_count: usize, insert_items: []const core.JSValue, new_length: usize, ) !?core.JSValue`。
- **作用**：dense/无观察快路径；条件不满足返回 null/false 回退。
- **实现**：分三段。**准入**（任一不满足即 `return null` 回退）：`objectFromValue(receiver)` 必须**就是** `object`（排除原始值包装与 proxy 间接）、`isArray() and isFastArray()`、无 exotic 方法且 `proxyTarget() == null`、`flags.length_writable and flags.extensible`、`canExtendFastArray()`（对应 qjs `can_extend_fast_array`，quickjs.c:9935-9944，也是它 splice 闸门 quickjs.c:43046 带的同一项；qjs 在这里不走原型链，因为给 `Array.prototype[i]` 赋值已经清掉了 `is_std_array_prototype`）。**重读 dense extent**：参数强制转换跑完之后才读 `fastArrayCount()`，要求 `count == length == arrayLength()`——`actual_start` / `actual_delete_count` 是按强制转换前的 length 算的，只有 extent 仍与之相符时才在界内，这一条同时挡掉带洞的尾巴与强制转换期间对 receiver 的改动；再校验 `new_count == new_length`、不超过 `max_array_length`、能 cast 成 u32；最后 `arrayHasDefaultSpecies` 必须给出默认 `Array.prototype`。**搬运**：`createArray` 建 `removed` 并立刻 `rootValues` 挂根（后面的 `createArrayStorageSlice` 与 `fastArrayEnsureCapacity` 会分配、会触发 GC），被删段整块拷进 `removed` 的 `.array_storage` cell 后 `adoptDenseArrayElementsAssumingEmpty`。此后不再分配，GC 观察不到半搬完的窗口。收缩臂（插入数 < 删除数）先 `copyForwards` 把尾巴下移，再 `setFastArrayCountAssumeCapacity` 降 count——降 count 就是退役超出新 extent 的那些别名槽（对应 qjs 直接赋 `p->u.array.count`，quickjs.c:43061-43064）。扩张臂先 `fastArrayEnsureCapacity`（可能重新分配缓冲），**先发布** count 与 length 再取窗口（qjs 在 quickjs.c:43069 重取 `arrp` 同理；count 与 length 必须同步移动才保住 `arrayElementsMut` 断言的 `length >= count`），`copyBackwards` 上移尾巴后把让出的空档填 `undefined`（qjs quickjs.c:43073-43074 同样填 JS_UNDEFINED），免得插入循环覆盖到仍活着的尾部别名。插入前 `rememberOwnerForBulkWrite` 补写屏障，然后逐槽写入 `insert_items`（对应 qjs 的 `set_value(&arrp[start+i], JS_DupValue(argv[i+2]))`，quickjs.c:43080-43081），最后 `setArrayLength` + `markIndexedProperties` 并返回 `removed`。
- **所有权 / 错误 / 调用**：返回 owned 的 removed 数组，或 null 表示不适用（非纯 dense 快数组、有 proxy/exotic、不可扩展、length 不可写、范围超出 dense 区、或 species 不是默认）——调用方回落 spec 逐元素路径。GC/所有权是这条路的核心：`removed` 建好后立刻 `rootValues` 挂根，因为随后的 `createArrayStorageSlice` 与 `fastArrayEnsureCapacity` 会分配；被删元素先整块拷进 `removed` 才动源数组；扩张臂把让出的空档填 undefined，免得插入循环覆盖到仍活着的尾部别名；插入前 `rt.gc.rememberOwnerForBulkWrite(object.gcHeader())` 补写屏障（`fastArrayValuesMut` 绕过了 append 的记忆点）。error set：只有分配 OOM 与 `arrayHasDefaultSpecies` 的透传。唯一调用方 `arraySpliceCallImpl`（`:2642`）。

### `arraySpliceCall` (`src/exec/array_ops.zig:2577`)

- **签名**：`pub fn arraySpliceCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, func: core.JSValue, args: []const core.JSValue, ) !?core.JSValue`。
- **作用**：`splice` 的快调用入口：callee 必须是 `splice` 的 record id 或同名函数，否则返回 `null` 让级联继续；命中后转 `arraySpliceCallImpl`。
- **实现**：对不上这个 builtin 时返回 `null`，让上层继续级联。关键调用：`callableObjectFromValue`、`isArrayPrototypeRecord`、`call_mod.nativeFunctionNameForVmEquals`、`arraySpliceCallImpl`。
- **所有权 / 错误 / 调用**：返回 owned 值，或 null 表示「不是我这条方法」让调用方继续往下找；`receiver`/`func`/`args` 是 VM 栈上的借用。自身只做身份识别（record id 优先、名字回退），实现全在 `arraySpliceCallImpl`。调用方三条：`arrayMethodFastCall`（`:207`）、`exec/call_runtime.zig:1286`、以及作为 `&arraySpliceCall` 进 `array_builtin_ops` 的 splice 记录（`array_builtin_ops.zig:210`）——注意那是**另一个同名函数**（`array_builtin_ops.arraySpliceCall`）的形参，本函数被记录路径用到的入口是下面的 `arraySpliceCallImpl`。

### `arraySpliceCallImpl` (`src/exec/array_ops.zig:2592`)

- **签名**：`pub fn arraySpliceCallImpl( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, args: []const core.JSValue, ) !?core.JSValue`。
- **作用**：`Array.prototype.splice` 的实现本体（record 分发与快调用共用）。
- **实现**：先按 own `length` 描述符排除不该接手的 receiver（只有 setter 的访问器、generic、非数组且 length 是可调用值都返回 `null`）。参数强制顺序：start → deleteCount（`args.len` 决定缺省：0 个参数删 0 个，1 个参数删到尾）；新长度超过 2^53−1 抛 TypeError。全部强制跑完后才试 `fastDenseArraySplice`（与 qjs quickjs.c:43040 同一位置），miss 才走 species + 逐元素路径：`arrayCopyPresentIndex` 取出删除段、`arrayMoveIndex` 移尾巴、超出部分 delete、插入段 `setValuePropertyOrThrow`，最后写 length；非数组 receiver 还要回读 length 确认写进去了，否则 TypeError。输出数组经 `arraySpeciesCreate` / `@@species` 构造。含循环：按 length 或迭代器步进处理元素。对不上这个 builtin 时返回 `null`，让上层继续级联。关键调用：`objectFromValue`、`primitiveObjectForAccess`、`object.getOwnProperty`、`object.isArray`、`setter.isUndefined`、`isCallableValue`、`object.arrayLength`、`getValueProperty`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回 owned 的 removed 数组（快路是新建 dense 数组，慢路来自 `arraySpeciesCreate`，可能是用户对象），或 null 表示 receiver 形态不适用（字符串、`length` 是 getter-only/generic 描述符、或 length 值本身是函数）。`verify_own_length_write` 那段是给非数组 array-like 收尾复核：写完 `length` 再读回来对不上就 `error.TypeError`。error set：`new_length` 超 2^53-1 → `error.TypeError`；`arrayCopyPresentIndex` / `arrayMoveIndex` / `deleteValuePropertyOrThrow` / `setValuePropertyOrThrow` 的 TypeError 透传；参数强制转换跑用户代码。调用方：`arraySpliceCall`（`:2589`）、记录 hub `:255`，以及 `builtin_glue.arraySpliceNativeRecord`（`builtin_glue.zig:46` 的 pub 别名，供 `array_builtin_ops` 的 splice 记录与直调臂使用）。

### `arrayCopyWithinCall` (`src/exec/array_ops.zig:2715`)

- **签名**：`pub fn arrayCopyWithinCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, func: core.JSValue, args: []const core.JSValue, ) !?core.JSValue`。
- **作用**：`Array.prototype.copyWithin` 与 `%TypedArray%.prototype.copyWithin` 的共用实现体：在同一个对象内部把一段元素搬到另一段。
- **实现**：先认人：record id 对不上就退一步比原生函数名 `"copyWithin"`，都不是就返回 `null` 让上层级联继续。`isTypedArrayPrototypeMethod` 把后面分成两条互不相干的路。TypedArray 路：receiver 必须是未 detach、未越界、buffer 非 immutable 的 TypedArray，先记下 `initial_length`，三个参数各自 `toIntegerOrInfinityForArrayByCopy`（用户 `valueOf` 可能顺手 resize RAB），强制跑完后重验 detach / 越界并把长度收成 `@min(initial_length, current_length)`；相对下标规范化后算 `count`，为 0 直接返回 receiver，否则换算成字节区间，区间重叠（`from_byte < to_byte < from_byte + byte_count`）用 `copyBackwards`、否则 `copyForwards` —— 全程是 buffer 内的原始字节搬运，不逐元素装箱。普通路：receiver 是基本值先 `primitiveObjectForAccess` 包装，String 对象返回 `null`；长度按 TypedArray / 数组 / 一般对象读 `length` 三种取法；`arrayRelativeIndex` 规范化 to/from/final，算出 count 与方向（重叠时改为从尾向前），再逐个 `arrayMoveIndex` 搬运，保留「源下标不存在就删掉目标下标」的可观测洞语义。
- **所有权 / 错误 / 调用**：返回 `receiver` 原值（原地操作，不新建对象），或 null 表示「不是我这条方法」让调用方继续往下找；`receiver`/`func`/`args` 是 VM 栈上的借用。TypedArray 臂在 `byteStorage()` 上直接 `copyForwards`/`copyBackwards`，重叠方向由 from/to 判定；泛型臂逐个 `arrayMoveIndex`（缺失索引会在目标上执行 delete，保住洞）。error set：`%TypedArray%` 臂的 detached/越界/immutable → `error.TypeError`；三个索引参数的强制转换跑用户代码后**重新读长度并 `@min` 夹紧**，之后的属性读写异常透传。调用方 `arrayMethodFastCall`（`:200`）、`exec/call_runtime.zig:1279`、记录 hub `:248`。

### `arrayFillCall` (`src/exec/array_ops.zig:2823`)

- **签名**：`pub fn arrayFillCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, func: core.JSValue, args: []const core.JSValue, ) !?core.JSValue`。
- **作用**：`Array.prototype.fill` 与 `%TypedArray%.prototype.fill` 的共用实现体：把 `[start, end)` 区间全部写成同一个值。
- **实现**：认人方式同 copyWithin，换成 record id `fill` 或函数名 `"fill"`。接着是 receiver 归一：typed 方法被调在非对象上直接 TypeError；基本值 `primitiveObjectForAccess` 包装；String 对象在 typed 方法下 TypeError、否则 `null`。TypedArray 路：detach / 越界 / immutable 三查后先记 `initial_length`，`typedArrayByCopyCoerceValue` 按元素种类强制填充值（BigInt64/BigUint64 数组要 BigInt，其余走 ToNumber），再算 start/final —— 这些强制都可能 resize，所以之后重验 detach / 越界并把 final 收到 `@min(final, current_length)`，最后一次 `core.typed_array.typedArrayFillRange` 批量填。普通路：长度三种取法；填充值只在 receiver 恰是非 BigInt 的 TypedArray 时先 ToNumber。随后是稠密快臂，条件相当紧：普通数组、无 exotic 方法、非 proxy、`arrayElementStorageMode() == .dense`、extensible、原型链无索引属性，且 `start <= fastArrayCount()`（否则像 `new Array(5).fill(7,2,4)` 这样起点落在稠密区之外，append 语义会把前导洞写错，源码注释点名了这个例子），`final` 还要不超过 u32 上界加一；命中后按 `canDefineDenseArrayDataPropertiesUnchecked` 分成直写与逐个判定两个循环。快臂没走完的部分落到统一的通用尾循环：`propertyAtomFromLengthIndex` + `setValuePropertyOrThrow`。
- **所有权 / 错误 / 调用**：返回 `receiver_object_value`（原地填充），或 null 表示「不是我这条方法」让调用方继续往下找；`receiver`/`func`/`args` 是 VM 栈上的借用。填充值 `value` 借用自参数，写进去后由目标持有；TypedArray 臂先 `typedArrayByCopyCoerceValue` 转成元素类型。dense 快路要求数组无 exotic/proxy、可扩展、原型链上没有索引属性且 `start` 落在 dense 区内，否则整段落回 `setValuePropertyOrThrow` 循环（快路中途失败也会带着 `index = dense_index` 接着走慢路）。error set：`%TypedArray%` 臂的 detached/越界/immutable/非 TypedArray → `error.TypeError`；索引强制转换与属性写透传。调用方 `arrayMethodFastCall`（`:201`）、`exec/call_runtime.zig:1280`、记录 hub `:249`。

### `arrayPrototypeChainHasNoIndexedProperties` (`src/exec/array_ops.zig:2923`)

- **签名**：`pub fn arrayPrototypeChainHasNoIndexedProperties(object: *core.Object) bool`。
- **作用**：判断原型链上有没有可能被索引写入观察到的东西——dense 快路径跳过原型链，只有这里返回 true 才安全。
- **实现**：从 `getPrototype()` 起逐级上走：任一祖先是 Proxy、带 exotic 方法，或 `flags.may_have_indexed_properties` 为真，就 false；走到链尾返回 true（不看自身对象）。关键调用：`object.getPrototype`、`candidate.proxyTarget`、`candidate.hasExoticMethods`、`candidate.getPrototype`。
- **所有权 / 错误 / 调用**：无：只读走原型链的谓词，不分配、无 error set、不跑用户代码（遇到 proxy 或 exotic 直接判 false）。它是多条 dense 写快路的准入条件——调用方 `arrayFillCall`（`:2897`）与 `fastDenseArrayUnshift`（`:3194`）；`src/tests/builtins.zig:110` 按源码文本计数钉住这两处，新增使用点需要同步那条计数断言。

### `arrayPushCall` (`src/exec/array_ops.zig:2933`)

- **签名**：`pub fn arrayPushCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, func: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`push` 的快调用入口：callee 必须是 `push` 的 record id 或同名函数，否则返回 `null` 让级联继续；命中后转 `arrayPushCallImpl`。
- **实现**：对不上这个 builtin 时返回 `null`，让上层继续级联。关键调用：`callableObjectFromValue`、`isArrayPrototypeRecord`、`call_mod.nativeFunctionNameForVmEquals`、`arrayPushCallImpl`。
- **所有权 / 错误 / 调用**：返回 owned 值，或 null 表示「不是我这条方法」让调用方继续往下找；`receiver`/`func`/`args` 是 VM 栈上的借用。自身只做身份识别，实现在 `arrayPushCallImpl`。调用方：`arrayMethodFastCall`（`:202`）、`exec/call_runtime.zig:1281`、记录 hub `:250`；`array_builtin_ops.zig:197` 里出现的 `&arrayPushCall` 是那个文件自己的同名 handler，不是本函数。

### `tryFastArrayPush` (`src/exec/array_ops.zig:2955`)

- **签名**：`pub inline fn tryFastArrayPush( rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue, ) !?i32`。
- **作用**：`Array.prototype.push` 的 dense 快臂：class 是 Array 的 fast array、`canExtendFastArray()`、length 可写且 `arrayLength() == dense count`。
- **实现**：逐条准入（非 Array class / 非 fast_array / 不可扩展 / length 不可写 / length ≠ count 都返回 `null`），再要求 `count + argc` 不溢出 u32 且 ≤ `maxInt(i32)`；通过后 `appendFastArrayPushValues` 一次追加，返回新 length。任一条件不满足返回 `null`，调用方走通用 ToObject/Set 路径。QuickJS 坐标：quickjs.c:42768-42788。
- **所有权 / 错误 / 调用**：`inline fn`，返回新长度或 null（不满足快路：非 fast array、不可扩展、length 不可写、length != count、新长度超 int32）。参数元素由 `appendFastArrayPushValues` 接管（它负责写屏障与容量增长），`receiver` 借用且靠调用方的活动帧保持为根——这是刻意对齐 qjs 不做 receiver dup/free 的形态。error set：只有 `appendFastArrayPushValues` 的 OOM。调用方 `arrayPushCallImpl`（`:2990`）与 `builtin_glue.tryFastArrayPush` 别名下的 `array_builtin_ops.arrayPushDirect`（`array_builtin_ops.zig:399`）。

### `arrayPushCallImpl` (`src/exec/array_ops.zig:2974`)

- **签名**：`pub fn arrayPushCallImpl( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Array.prototype.push` 的实现本体（record 分发与快调用共用）。
- **实现**：nullish receiver 抛「Cannot convert undefined or null to object」。`tryFastArrayPush` 命中就直接返回新 length（不装箱、不 dup receiver，对齐 qjs 在 `JS_ToObject` 之前就查直接 Array receiver）。miss 后装箱；string receiver 是 TypeError。Get `length` + ToLength，`length + argc` 超过 2^53−1 抛 TypeError。逐个参数 `ensureSettableForArrayBuiltin` 后 `setValuePropertyOrThrow`（JS_PROP_THROW，失败对 sloppy 调用者也抛），**最后**才 `ensureLengthWritableForArrayBuiltin` 并写回 length。receiver 装箱后仍不是对象时返回 `null`。含循环：按 length 或迭代器步进处理元素。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回新长度值（立即数），或 null（`objectFromValue` 落空的退化情形）。receiver 为 null/undefined 走 `throwTypeErrorMessage`（带消息的 TypeError）；字符串 receiver 是裸 `error.TypeError`；`length + args.len` 超 2^53-1 → `error.TypeError`；每个索引写之前先 `ensureSettableForArrayBuiltin`（只读属性 / 只有 getter / 不可扩展分别给 `error.TypeError` 与 `error.NotExtensible`），收尾还要 `ensureLengthWritableForArrayBuiltin`。调用方：`arrayPushCall`（`:2948`）与 `builtin_glue.arrayPushNativeRecord`（`builtin_glue.zig:43` 的 pub 别名）——后者正是 `array_builtin_ops` 的 push 记录与 NMFD 直调臂共用的实现。

### `arrayPopCall` (`src/exec/array_ops.zig:3017`)

- **签名**：`pub fn arrayPopCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, func: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`pop` 的快调用入口：callee 必须是 `pop` 的 record id 或同名函数，否则返回 `null` 让级联继续；命中后转 `arrayPopCallImpl`。
- **实现**：对不上这个 builtin 时返回 `null`，让上层继续级联。关键调用：`callableObjectFromValue`、`isArrayPrototypeRecord`、`call_mod.nativeFunctionNameForVmEquals`、`arrayPopCallImpl`。
- **所有权 / 错误 / 调用**：返回 owned 值，或 null 表示「不是我这条方法」让调用方继续往下找；`receiver`/`func`/`args` 是 VM 栈上的借用。只做身份识别，实现在 `arrayPopCallImpl`。调用方：`arrayMethodFastCall`（`:203`）、`exec/call_runtime.zig:1282`、记录 hub `:251`；`array_builtin_ops.zig:206` 的 `&arrayPopCall` 是那个文件自己的 handler。

### `arrayPopCallImpl` (`src/exec/array_ops.zig:3034`)

- **签名**：`pub fn arrayPopCallImpl( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Array.prototype.pop` 的实现本体（record 分发与快调用共用）。
- **实现**：装箱 receiver（string 是 TypeError，装箱后仍不是对象返回 `null`）；先试 `fastDenseArrayPop`、再试 `fastEmptyArrayPop`。通用路径：读 length（数组读槽，其余 Get + ToLength），length 为 0 时校验 length 可写后写 0 并返回 `undefined`。否则 Get 末元素、delete 它，再写 length：数组且 length 未被 getter 撑大时直接 `setArrayLength`（不可写则抛「'length' is read-only」，且删除已经可见），否则走通用 Set。关键调用：`objectFromValue`、`primitiveObjectForAccess`、`fastDenseArrayPop`、`fastEmptyArrayPop`、`object.isArray`、`object.arrayLength`、`getValueProperty`、`toLengthIndex`。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回被摘下元素的 owned 值（空数组给 undefined），或 null（`objectFromValue` 落空）。两条快路（`fastDenseArrayPop` / `fastEmptyArrayPop`）先试，失败才走 Get + Delete + 写 length 的可观察序列；写 length 时若数组仍是自身数组且未被 getter 撑大，直接 `setArrayLength` 改槽，否则走通用 set。error set：字符串 receiver → 裸 `error.TypeError`；`length` 不可写 → `throwTypeErrorMessage("'length' is read-only")`；delete/set 与用户 getter 透传。调用方：`arrayPopCall`（`:3031`）与 `builtin_glue.arrayPopNativeRecord`（`builtin_glue.zig:45` 的 pub 别名，供 pop 的专用记录用）。

### `fastDenseArrayPop` (`src/exec/array_ops.zig:3083`)

- **签名**：`fn fastDenseArrayPop(object: *core.Object) ?core.JSValue`。
- **作用**：dense/无观察快路径；条件不满足返回 null 回退。
- **实现**：要求是 Array、length 可写、fast array；`takeLastFullyDenseFastArrayElement` 只在 `count == length`（完全 dense）时才吐出末元素——有洞尾巴的数组返回 `null`，回退通用 pop。
- **所有权 / 错误 / 调用**：返回被摘下元素的 owned 值，或 null 表示不适用（非数组、length 不可写、非 fast array、或 length != count 的洞数组）。`takeLastFullyDenseFastArrayElement` 把元素从 dense 存储里摘出并同时降 count/length，所有权直接转给返回值。不分配、无 error set（纯谓词 + 摘取）。唯一调用方 `arrayPopCallImpl`（`:3045`）。

### `fastEmptyArrayPop` (`src/exec/array_ops.zig:3096`)

- **签名**：`fn fastEmptyArrayPop(ctx: *core.JSContext, global: *core.Object, object: *core.Object) !?core.JSValue`。
- **作用**：空数组 pop 的快臂；不是 Array 或 `arrayLength() != 0` 时返回 `null` 回退通用路径。
- **实现**：对应 qjs `js_array_pop` 的空数组腿：直接读写 own length 槽。length 不可写时抛「'length' is read-only」；否则 `setArrayLength(0)` 并返回 `undefined`。关键调用：`object.isArray`、`object.arrayLength`、`throwTypeErrorMessage`、`object.setArrayLength`、`JSValue.undefinedValue`。
- **所有权 / 错误 / 调用**：返回 undefined 立即数，或 null 表示不适用（不是数组或 length 非 0）。不分配；这是 pop 的空数组腿，只把 length 槽写回 0。error set：`length` 不可写时走 `throwTypeErrorMessage("'length' is read-only")`（带消息，返回 `error.TypeError`）。唯一调用方 `arrayPopCallImpl`（`:3046`）。

### `arrayShiftCall` (`src/exec/array_ops.zig:3105`)

- **签名**：`pub fn arrayShiftCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, func: core.JSValue, ) !?core.JSValue`。
- **作用**：`Array.prototype.shift` 的实现体：取走 0 号元素，其余整体前移一位，length 减一。
- **实现**：认人失败（record id 不是 `shift`、名字也不是 `"shift"`）返回 `null`。receiver 是基本值先 `primitiveObjectForAccess` 包装，String 对象直接 TypeError。随后先试 `fastDenseArrayShift`：完全稠密（`fastArrayCount() == arrayLength()`）且 length 可写的 fast array 才行，命中就在 `fastArrayValuesMut()` 上 `copyForwards` 下移、尾槽写 undefined、count 与 length 同步减一，返回原首元素。慢路：长度按数组 / 一般对象两种取法；`length == 0` 也不是空操作——仍要 `ensureLengthWritableForArrayBuiltin` 再把 `length` 写成 0（不可写时抛 TypeError），返回 undefined。否则读出 0 号元素，用 `arrayMoveIndex` 逐个把 `[1, length)` 下移（保留洞语义），`deleteValuePropertyOrThrow` 删掉原尾下标，最后写回 `length - 1` 并返回首元素。
- **所有权 / 错误 / 调用**：返回被摘下的首元素 owned 值，或 null 表示「不是我这条方法」让调用方继续往下找；`receiver`/`func`/`args` 是 VM 栈上的借用。先试 `fastDenseArrayShift` 的整块下移；慢路是 Get(0) + 逐个 `arrayMoveIndex` + delete 尾部 + 写 length 的可观察序列。error set：字符串 receiver → 裸 `error.TypeError`，`ensureLengthWritableForArrayBuiltin` 的 `error.TypeError`，属性读写与用户 getter 透传。调用方 `arrayMethodFastCall`（`:204`）、`exec/call_runtime.zig:1283`、记录 hub `:252`。

### `fastDenseArrayShift` (`src/exec/array_ops.zig:3149`)

- **签名**：`fn fastDenseArrayShift(object: *core.Object) ?core.JSValue`。
- **作用**：dense/无观察快路径；条件不满足返回 null 回退。
- **实现**：要求 Array、length 可写、fast array，且 `fastArrayCount() == arrayLength()`（完全 dense，有洞尾巴回退）。取下 `values[0]`，`copyForwards` 把 `[1, len)` 整体下移一格，末槽写 `undefined`，count 与 length 同步减一。关键调用：`object.isArray`、`object.isFastArray`、`object.fastArrayCount`、`object.arrayLength`、`object.fastArrayValuesMut`、`mem.copyForwards`、`JSValue.undefinedValue`。
- **所有权 / 错误 / 调用**：返回首元素的 owned 值，或 null（非数组、length 不可写、非 fast array、count != length 的洞数组、空数组）。整块 `copyForwards` 是**纯位移动**：每个引用的所有权随槽位平移，末槽写 undefined 后降 count/length 把原来的重复别名退休，全程不 dup/free、不分配、无 error set。唯一调用方 `arrayShiftCall`（`:3120`）。

### `fastDenseArrayUnshift` (`src/exec/array_ops.zig:3177`)

- **签名**：`fn fastDenseArrayUnshift( rt: *core.JSRuntime, receiver: core.JSValue, object: *core.Object, args: []const core.JSValue, ) !?usize`。
- **作用**：dense/无观察快路径；条件不满足返回 null/false 回退。
- **实现**：对应 qjs `JS_CopySubArray` 的 fast_array 分支（quickjs.c:41624-41647）。准入（任一不满足即 `return null`）：至少一个插入参数、`objectFromValue(receiver)` 就是该对象、`isArray() and isFastArray()`、无 exotic 方法且非 Proxy、`length_writable and extensible`、**原型链上没有索引属性**（`arrayPrototypeChainHasNoIndexedProperties`——dense 位移跳过原型链，链上若有索引访问器就会被普通 `[[Set]]` 观察到）、`arrayLength() == fastArrayCount()`（完全 dense）、新长度不超过 `max_array_length` 且能 cast 成 u32。搬运顺序与 splice 的扩张臂一致：先 `fastArrayEnsureCapacity`（可能重新分配缓冲），再 `setFastArrayCountAssumeCapacity` + `setArrayLength` 同步发布新 extent，然后取 `fastArrayValuesMut()`；`copyBackwards` 把原 `[0, length)` 整体上移 `insert_count` 格——这是纯位移，引用的所有权随槽走，不 dup 也不 free；`rememberOwnerForBulkWrite` 之后把参数逐个写进 `[0, insert_count)`（那里原来的位是已经搬走的别名，**不能 free**），最后 `markIndexedProperties` 并返回新长度。
- **所有权 / 错误 / 调用**：返回新长度或 null（任一准入条件不满足：receiver 不是该数组本体、非 fast array、有 exotic/proxy、length 不可写或不可扩展、原型链上有索引属性、count != length、新长度越界）。所有权：先 `fastArrayEnsureCapacity`（可能重新分配缓冲）再发布新 count/length，然后 `copyBackwards` 整块位移（引用随槽走，不 dup/free），最后把参数写进头部——`[0, insert_count)` 里原来的位是已经移走的别名，**不能 free**。写屏障：`rt.gc.rememberOwnerForBulkWrite(object.gcHeader())` 补上，因为这条路绕过了 `appendUninitializedFastArraySlot` 的记忆点。error set：只有扩容的 OOM。唯一调用方 `arrayUnshiftCall`（`:3250`）。

### `arrayUnshiftCall` (`src/exec/array_ops.zig:3233`)

- **签名**：`pub fn arrayUnshiftCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, func: core.JSValue, args: []const core.JSValue, ) !?core.JSValue`。
- **作用**：`Array.prototype.unshift` 的实现体：在头部插入若干元素，原有元素整体后移，返回新 length。
- **实现**：认人同族（record id `unshift` 或名字 `"unshift"`），失败 `null`；基本值 receiver 包装，String 对象 TypeError。先试 `fastDenseArrayUnshift` 快臂（条件与搬运细节见其自身条目），命中即 `lengthIndexValue(new_length)` 返回。慢路：长度按数组 / 一般对象取；溢出检查是 `insert_count > 9007199254740991 - length` 时抛 `error.TypeError`（spec 的 2^53−1 上限，抛的是 TypeError 不是 RangeError）。有参数时按规模分岔：`length <= 100000` 走从高下标往低的 `arrayMoveIndex` 逐个后移；更长的数组改走 `arrayUnshiftSparseLarge`（按自有键排序的稀疏搬运），避免为大 length 的稀疏数组空跑上百万次。之后逐个 `ensureSettableForArrayBuiltin` + `setValuePropertyOrThrow` 写入新头部。收尾无条件 `ensureLengthWritableForArrayBuiltin` 并写 `length = new_length`，返回新长度。
- **所有权 / 错误 / 调用**：返回新长度值，或 null 表示「不是我这条方法」让调用方继续往下找；`receiver`/`func`/`args` 是 VM 栈上的借用。慢路对 length ≤ 100000 用倒序 `arrayMoveIndex`，更大则转 `arrayUnshiftSparseLarge` 走键快照；插入前逐个 `ensureSettableForArrayBuiltin`，收尾 `ensureLengthWritableForArrayBuiltin` + 写 length。error set：字符串 receiver → 裸 `error.TypeError`；`length + args.len` 超 2^53-1 → `error.TypeError`；`error.NotExtensible`（不可扩展数组上新建索引）；属性读写与用户 getter 透传。调用方 `arrayMethodFastCall`（`:205`）、`exec/call_runtime.zig:1284`、记录 hub `:253`。

### `arrayReverseCall` (`src/exec/array_ops.zig:3289`)

- **签名**：`pub fn arrayReverseCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, func: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Array.prototype.reverse` 与 `%TypedArray%.prototype.reverse` 的共用实现体：原地反转（与产生副本的 `toReversed` 分开）。
- **实现**：认人失败（record id 不是 `reverse`、名字也不是 `"reverse"`）返回 `null`；receiver 是 null/undefined 直接 TypeError。TypedArray 方法要求 receiver 是未 detach、未越界、buffer 可写的 TypedArray，然后 `length / 2` 次 `typedArrayGetIndex`/`typedArraySetIndex` 对换两端 —— 没有洞、也不走属性查找。普通路长度有四种取法：TypedArray、数组、既非对象又非字符串按 0、其余读 `length`。快臂照抄 qjs `js_array_reverse`（quickjs.c:42836-42847）：extensible 的 fast array 且 `fastArrayCount() == length` 时直接在 `fastArrayValuesMut()` 上做裸指针对换，是纯 JSValue 置换、无 dup/free；`count == len` 这条正是用来挡住带尾洞的数组。通用循环则对每一对下标先各做一次 `hasValueProperty`，再按四种存在组合分别处理：都在就互换、只有上面在就 set 下面并删上面、只有下面在就删下面并 set 上面、都不在什么也不做 —— 这就是 spec 里 reverse 对洞的搬运规则。
- **所有权 / 错误 / 调用**：返回 `receiver_object_value`（原地反转），或 null 表示「不是我这条方法」让调用方继续往下找；`receiver`/`func`/`args` 是 VM 栈上的借用。fast-array 快路直接在 `fastArrayValuesMut()` 上交换指针位，是纯 JSValue 置换，不 dup/free、不分配；TypedArray 臂逐对 get/set 元素；泛型臂按 spec 处理「一侧是洞」的四种组合（写一侧、删另一侧）。error set：receiver 为 null/undefined 或不是对象 → 裸 `error.TypeError`；`%TypedArray%` 臂的 detached/越界/immutable → `error.TypeError`；属性读写与用户 getter 透传。调用方 `arrayMethodFastCall`（`:206`）、`exec/call_runtime.zig:1285`、记录 hub `:254`。

### `arrayUnshiftSparseLarge` (`src/exec/array_ops.zig:3394`)

- **签名**：`pub fn arrayUnshiftSparseLarge( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, object: *core.Object, length: usize, insert_count: usize, ) !void`。
- **作用**：`unshift` 在 `length > 100000` 时的稀疏搬运：只对实际存在的 own 索引（以及它们的目标位）做 move，而不是从 length 逐个倒着走。
- **实现**：`ownKeys` + `propertyIndexFromLengthKey` 收候选：既收 `index < length` 的源位，也收 `index - insert_count`（该目标位对应的源位）；按 `sort_erased.heap` **降序**排后去重，逐个 `arrayMoveIndex(index → index + insert_count, ensure_settable = true)`。含循环：按 length 或迭代器步进处理元素。关键调用：`object.ownKeys`、`Object.freeKeys`、`candidates.deinit`、`propertyIndexFromLengthKey`、`candidates.append`、`sort_erased.heap`、`lessThan`。
- **所有权 / 错误 / 调用**：无返回值。`ownKeys` 的键数组由 `defer freeKeys` 释放，`candidates` 索引列表由 `defer deinit` 释放（都不是 GC 边）。它对每个已存在的键既收集自身索引、也收集「被搬来的源索引」，降序去重后逐个 `arrayMoveIndex(..., ensure_settable = true)`，保证稀疏数组上不必遍历 0..length。error set：分配 OOM 与 `arrayMoveIndex` 透传（`error.TypeError` / `error.NotExtensible` / 用户 getter）。唯一调用方 `arrayUnshiftCall`（`:3273`），只在 length > 100000 时走到。

### `TypedSearchMode.lessThan` (`src/exec/array_ops.zig:3415`)

- **签名**：`fn lessThan(_: void, a: usize, b: usize) bool`。
- **作用**：`arrayUnshiftSparseLarge` 内联的堆排序比较器。
- **实现**：`return a > b`——按下标**降序**，先搬高位才不会覆盖尚未搬走的元素。
- **所有权 / 错误 / 调用**：无：比较的是裸 `usize` 下标（这里的列表不带 atom，是 `candidates: ArrayList(usize)`），不分配、无 error。源码位置是 `arrayUnshiftSparseLarge`（`src/exec/array_ops.zig:3394`）里那次 `sort_erased.heap` 的匿名 struct 成员，没有别的引用点。

### `arrayMoveIndex` (`src/exec/array_ops.zig:3435`)

- **签名**：`pub noinline fn arrayMoveIndex( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, object: *core.Object, from_index: usize, to_index: usize, ensure_settable: bool, ) !void`。
- **作用**：把数组下标 `from` 原地搬到 `to`：源在则 Get+Set，源缺席则 Delete 目标，空洞跟着走。
- **实现**：两端 `propertyAtomFromLengthIndex`。`hasValueProperty(from)` 为真则 Get，若 `ensure_settable` 先 `ensureSettableForArrayBuiltin(to)`，再 `setValuePropertyOrThrow`；否则 `deleteValuePropertyOrThrow(to)`。outlined 是为了让 shift/splice/copyWithin/unshift 共用同一 leftover（注释 knives 94/108），不折叠 skip-missing 的 `createDataPropertyOrThrow` 拷贝或 reverse 对换。
- **所有权 / 错误 / 调用**：无返回值；`noinline`，是 shift / unshift / splice 收缩与扩张 / copyWithin 共用的「搬一个索引」原语。两个 atom 各自 `defer key.deinit` 退 pin；元素值从源读出后由目标属性接管。源索引不存在时**对目标执行 delete**（洞跟着搬），这正是与 `arrayCopyPresentIndex`（跳过缺失）的区别。error set：`ensure_settable` 为真时 `ensureSettableForArrayBuiltin` 的 `error.TypeError` / `error.NotExtensible`，以及 has/get/set/delete 与用户代码的透传。调用方六处：`arraySpliceCallImpl`（`:2680`、`:2694`）、`arrayCopyWithinCall`（`:2809`）、`arrayShiftCall`（`:3138`）、`arrayUnshiftCall`（`:3270`）、`arrayUnshiftSparseLarge`（`:3423`）。

### `arrayCopyPresentIndex` (`src/exec/array_ops.zig:3468`)

- **签名**：`pub noinline fn arrayCopyPresentIndex( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, source_receiver: core.JSValue, source: *core.Object, from_index: usize, dest_value: core.JSValue, dest: *core.Object, to_index: usize, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：把源下标的**现存**元素 `CreateDataPropertyOrThrow` 到新数组目标下标；缺席直接 return，输出里仍是洞。
- **实现**：`hasValueProperty(from)` 失败即 return。Get 后对目标 `createDataPropertyOrThrow`。与 `arrayCopyIndex`（无 has 检查，缺席变 `undefined`）和 `arrayMoveIndex`（原地搬）区分。slice / concat 展开、splice 取出段走这条。outlined leftover（knives 94/108）；`concatAppendValue` 仍是独立调用方。
- **所有权 / 错误 / 调用**：无返回值；`noinline`，slice 与 splice-removed 共用的「跳过缺失的 CreateDataProperty 复制」原语。两个 atom 各自 `defer deinit`；源索引不存在就直接 return，让目标保住洞（与 `arrayMoveIndex` 的 delete 语义相反）。`caller_function` / `caller_frame` 只透传给 get 与 `createDataPropertyOrThrow`，用于内联缓存与栈回溯。error set：`createDataPropertyOrThrow` 在目标拒绝定义时给 `error.TypeError`，has/get 与用户代码透传。调用方 `arraySliceCall`（`:2285`）、`arraySpliceCallImpl`（`:2660`）与 `exec/string_ops.zig:3095`。

### `ensureSettableForArrayBuiltin` (`src/exec/array_ops.zig:3492`)

- **签名**：`pub fn ensureSettableForArrayBuiltin(ctx: *core.JSContext, object: *core.Object, atom_id: core.Atom) !void`。
- **作用**：写入某个索引前检查它是否可写；只读数据属性或只有 getter 的访问器给 TypeError，链上什么都没有且对象不可扩展给 NotExtensible。
- **实现**：`findPropertyDescriptor` 沿原型链找该 atom：找到 `.data` 且 `writable == false` → `error.TypeError`；找到 `.accessor` 且 setter 是 undefined → `error.TypeError`；其余找到即放行。链上完全没有时，这次写会新建 own 属性，于是 `!object.flags.extensible` → `error.NotExtensible`（对应 qjs `JS_CreateProperty` 的 not_extensible 分支，quickjs.c:10144）。
- **所有权 / 错误 / 调用**：无返回值、不分配；沿原型链 `findPropertyDescriptor` 找可写性。两种失败语义要分清：链上找到只读数据属性或只有 getter 的访问器 → `error.TypeError`；**链上什么都没找到且 receiver 不可扩展** → `error.NotExtensible`（对应 qjs `JS_CreateProperty` 的 not_extensible 分支），没有这条的话 sealed 数组的 push/unshift/splice 会静默丢值。两个 error 都是裸的，由上层边界补消息。调用方 `arrayPushCallImpl`（`:3008`）、`arrayUnshiftCall`（`:3279`）、`arrayMoveIndex`（`:3451`，仅 `ensure_settable` 为真时）。

### `ensureLengthWritableForArrayBuiltin` (`src/exec/array_ops.zig:3506`)

- **签名**：`pub fn ensureLengthWritableForArrayBuiltin(ctx: *core.JSContext, object: *core.Object) !void`。
- **作用**：写 `length` 之前检查它可不可写；不可写就抛 TypeError（这里不涉及 extensible）。
- **实现**：`object.getOwnProperty(length)`：own 描述符是 `.data` 且 `writable == false`、或是 setter 为 undefined 的 `.accessor`，都给 `error.TypeError`；没有 own `length` 描述符时直接放行。
- **所有权 / 错误 / 调用**：无返回值、不分配；只看 **own** `length` 描述符（不走原型链），只读数据属性或只有 getter 的访问器 → 裸 `error.TypeError`，没有 own `length` 则放行。它专门排在写 length 之前，保证「元素已改、length 写不动」时的抛出时机与 qjs 一致。调用方六处：`arrayCopyWithinCall`（`:2705`）、`arrayPushCallImpl`（`:3012`）、`arrayPopCallImpl`（`:3055`）、`arrayShiftCall`（`:3129`、`:3144`）、`arrayUnshiftCall`（`:3284`）。

### `arrayRelativeIndex` (`src/exec/array_ops.zig:3513`)

- **签名**：`pub fn arrayRelativeIndex(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, arg_index: usize, length: usize, default_value: usize) !usize`。
- **作用**：把相对下标（负从尾）夹到 [0, length]。
- **实现**：`args.len <= arg_index` 时直接返回 `default_value`；否则 `toPrimitiveForNumber` + `toNumberValue` 取出 f64（取不到按 NaN），再交给 `arrayRelativeIndexFromNumber(length, n, default_value)` 做夹紧。
- **所有权 / 错误 / 调用**：返回夹紧后的绝对索引，不分配、不建根；`args.len <= arg_index` 时直接给 `default_value`（唯一用到该参数的地方，`arrayRelativeIndexFromNumber` 里它被丢弃）。会跑 `toPrimitiveForNumber` + ToNumber，即用户 `valueOf` 可见，调用方必须假定长度此后可能已变。error set：强制转换透传（BigInt 的 `error.TypeError` 等）。调用方 13 处：slice/subarray/splice/copyWithin/fill/byCopy 各臂。

### `arrayRelativeIndexFromNumber` (`src/exec/array_ops.zig:3521`)

- **签名**：`pub fn arrayRelativeIndexFromNumber(length: usize, n: f64, default_value: usize) usize`。
- **作用**：把相对下标（负从尾）夹到 [0, length]；`default_value` 在函数体里被 `_ =` 丢弃（缺省值由 `arrayRelativeIndex` 在参数缺席时处理），NaN/−Infinity 一律给 0。
- **实现**：第一行 `_ = default_value`。NaN 与 −∞ → 0；+∞ → `length`；`@trunc` 后为负时按 `length + integer` 从尾部折回（≤0 给 0），非负时 `>= length` 给 `length`，其余原样转 usize。
- **所有权 / 错误 / 调用**：无：纯数值夹紧（NaN 与 -∞ → 0，+∞ 与超长 → length，负数从尾部折回），不分配、无 error set、不跑用户代码；`default_value` 参数在函数体第一行就被 `_ =` 丢弃——真正用到它的是 `arrayRelativeIndex` 的「参数缺席」分支。调用方 `arrayCopyWithinCall` 的 TypedArray 臂（`:2755`、`:2756`、`:2758`）与 `arrayRelativeIndex`（`:3518`）。

### `toIntegerOrInfinityForArrayMethod` (`src/exec/array_ops.zig:3537`)

- **签名**：`pub fn toIntegerOrInfinityForArrayMethod(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue) !f64`。
- **作用**：数组方法用的数值强制：ToPrimitive(number) → ToNumber，返回原始 f64（不截断、不夹取），取不到数值时给 NaN，由调用方自己判 NaN/±Infinity。
- **实现**：薄封装，主体转发到 `toPrimitiveForNumber`、`value_ops.toNumberValue`、`value_ops.numberValue`、`math.nan`。
- **所有权 / 错误 / 调用**：返回 f64（ToIntegerOrInfinity 的未夹紧结果，NaN 原样返回），不分配；会跑用户 ToPrimitive。无自有 error set，只透传强制转换的异常。唯一调用方 `arraySpliceCallImpl`（`:2627`）——splice 的 deleteCount 需要区分 NaN / 负数 / +∞ 三种情况，所以不能用夹紧过的 `arrayRelativeIndex`。

## 覆盖核对

- 清单函数数（本文件分到）: 57（`src/exec/array_ops.zig` 全文件 234）
- 本文标题覆盖: 57
- 未覆盖: 无
