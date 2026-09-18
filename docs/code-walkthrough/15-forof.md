# 15 — `forof_ops.zig`：for-in 快照、catch-marker、unwind close

for-in 迭代器把 qjs `JSForInIterator` 映射到 `IteratorPayload`：

| qjs | zjs |
| --- | --- |
| `it->obj` | `payload.target` |
| `it->idx` | `payload.index` |
| `it->atom_count` | `payload.length` |
| `it->tab_atom` | `payload.atom_keys`（只存可枚举字符串键） |
| `it->is_array` | `payload.zip_mode` |
| `it->in_prototype_chain` | `payload.zip_state` |

已访问键做成迭代器对象自身的 null 属性（与 qjs `enum_obj` 相同）。非可枚举键在快照时就写入 visited，不再另存 `is_enumerable` 数组。

catch-marker 与普通 catch-offset 共享 tag，但 payload 小于等于 -2。

### `forInIsArraySlot` (`src/exec/forof_ops.zig:45`)

- **签名**：`pub fn forInIsArraySlot(iterator: *core.Object) *u8`。
- **作用**：for-in 迭代器上 qjs `it->is_array` 的别名，复用 `iteratorZipModeSlot`。
- **实现**：直接返回 `iterator.iteratorZipModeSlot()`。0=普通键快照，1=fast array，下标按 idx 即时生成。
- **所有权 / 错误 / 调用**：无分配、无 error set：返回的是迭代器 payload 里被 for-in 借用的 `zip_mode` u8 槽指针，标量槽不是 GC 边，调用方直接写不需要屏障；指针随迭代器对象存活，函数返回后不得跨对象析构持有。调用方：`forof_ops.zig:82`/`:97`（`createForInIterator` 初始化为 0、fast-array 档置 1）与 `iterator_ops.zig:893`、`:964`、`:972`（`forInNext` 读档、`forInPrepareProtoChainEnum` 把 fast-array 档转成键表后清 0）。

### `forInInProtoChainSlot` (`src/exec/forof_ops.zig:50`)

- **签名**：`pub fn forInInProtoChainSlot(iterator: *core.Object) *u8`。
- **作用**：for-in 迭代器上 qjs `it->in_prototype_chain` 的别名，复用 `iteratorZipStateSlot`。
- **实现**：直接返回 `iterator.iteratorZipStateSlot()`。0=仍在根对象快照，1=已进入原型链慢路径（visited 去重生效）。
- **所有权 / 错误 / 调用**：同 `forInIsArraySlot`：借用 payload 的 `zip_state` u8 槽，不分配、无 error、非 GC 边。调用方：`forof_ops.zig:83`（初始化 0）与 `iterator_ops.zig:864`、`:868`、`:904`（`forInNext` 判断是否已进原型链慢路径并在进入后置 1）。

### `createForInIterator` (`src/exec/forof_ops.zig:58`)

- **签名**：`pub fn createForInIterator( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object_value: core.JSValue, ) !core.JSValue`。
- **作用**：只快照根对象自己的可枚举字符串键；原型链由 `forInNext` 惰性走。
- **实现**：只快照根对象自己的可枚举字符串键；原型链由 `forInNext` 惰性走。先建 `for_in_iterator` 对象并把 kind/index/length/is_array/in_prototype_chain 清成 qjs 的初值。null/undefined 造空迭代器（第一次 next 即 done）。原始值先 `primitiveObjectForAccess` 转对象再写进 `iteratorTargetSlot`。fast array / typed array 且无其它可枚举 shape 属性时（`forInFastArrayCount`）只存元素个数、`is_array=1`，下标即时生成；否则 `forInSnapshotOwnStringKeys` 取键表，逐个 `shadeAtomIfMarking`（TGC S3 §2.3）后写进 `iteratorAtomKeysSlot`，键数超 u32 则 `error.OutOfMemory`。QuickJS 坐标：quickjs.c:16268、quickjs.c:16404、quickjs.c:16292-16297、quickjs.c:16301-16302、quickjs.c:16277-16279、quickjs.c:16315-16317。跨越可分配/用户回调的值用 `rootValues` / ValueRootFrame 钉住。对象分配后 `errdefer destroyFromHeader`，失败不泄漏。
- **所有权 / 错误 / 调用**：返回的迭代器对象由调用方拥有：唯一调用方 `iterator_ops.zig:283`（`forInStart`）立即 `pushOwned` 把它交给操作数栈；本函数内失败由 `errdefer destroyFromHeader` 回收，不泄漏。键表 `[]Atom` 由 `forInSnapshotOwnStringKeys` 用 `rt.memory` 分配，写进 `iteratorAtomKeysSlot` 后归迭代器（析构时释放），移入前逐个 `shadeAtomIfMarking` 给增量标记补边；`iterator_val`/`source_val` 跨 `primitiveObjectForAccess` 与可能触发 proxy trap 的快照期间挂在 `ValueRootFrame` 上。error set：分配失败与键数放不进 u32 的 `error.OutOfMemory`，以及 `primitiveObjectForAccess`、proxy `ownKeys`/gopd trap 上抛的 `error.TypeError` 等；它们经 `forInStart` → `forInStartVm` 交给 `call_runtime.handleCatchableRuntimeError`，在那里由 `createSentinelError` 变成 JS 异常压给 catch handler。

### `forInFastArrayCount` (`src/exec/forof_ops.zig:112`)

- **签名**：`fn forInFastArrayCount(rt: *core.JSRuntime, source: *core.Object) ?u32`。
- **作用**：判定 source 能否走 for-in 的 fast-array 档：能则返回元素个数（只存计数，下标即时生成），否则返回 null 走普通键快照。
- **实现**：typed array：扫 `shapeProps`，有任何未删除且可枚举的命名属性就返回 null（quickjs.c:16307），否则返回 `typedArrayLength`（失败记 0）。普通对象：必须 `isArray()` 且 `flags.fast_array`，且不是 proxy / 无 exotic 方法；再扫 `shapeProps`，遇到可枚举属性或残留的下标型 atom（稀疏遗留）都返回 null；最后返回 `arrayElements().len`（放不进 u32 则 null）。QuickJS 坐标：quickjs.c:16305-16317、quickjs.c:16307。
- **所有权 / 错误 / 调用**：纯查询：不分配、不改对象、无 error set（`typedArrayLength` 的失败被 `catch 0` 吞成 0 长度）。返回的是元素个数，不代表任何所有权。唯一调用方 `forof_ops.zig:94`（`createForInIterator`），返回 null 即回落普通键快照分支。

### `forInSnapshotOwnStringKeys` (`src/exec/forof_ops.zig:143`)

- **签名**：`pub fn forInSnapshotOwnStringKeys( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, iterator: *core.Object, ) ![]core.Atom`。
- **作用**：快照对象的自有可枚举字符串键（tab 顺序），并把非可枚举的字符串键就地写进迭代器的 visited 集，替代 qjs 的并行 is_enumerable 数组。
- **实现**：`objectRestOwnKeys` 取全部 own key（defer `freeKeys`），`out` 与 `all` 都登记进 `rootAtomSlots`（跨越可能触发 proxy trap 的逐键 [[GetOwnProperty]]，TGC S3 §4 class B）。逐键先按 `atoms.kind(key) != .string` 跳过 symbol，再用 `forInOwnKeyIsEnumerable` 判定：可枚举则 `appendAtom` 进 `out`，否则 `forInDefineVisited` 直接记进 visited 集。失败路径 `errdefer freeAtomList(out)`。对应 JS_GetOwnPropertyNamesInternal(JS_GPN_STRING_MASK | JS_GPN_SET_ENUM)，QuickJS 坐标：quickjs.c:16321、quickjs.c:16447、quickjs.c:16384、quickjs.c:16386-16390。
- **所有权 / 错误 / 调用**：返回的 `[]core.Atom` 是 `rt.memory` 的裸数组，所有权交调用方：`forof_ops.zig:101` 与 `iterator_ops.zig:881`（`forInNext` 的原型步进）把它移进 `iteratorAtomKeysSlot` 归迭代器，`iterator_ops.zig:970`（`forInPrepareProtoChainEnum`）则 `defer freeAtomList` 自己丢掉；数组只装 atom id，TGC 下没有逐个 retain/release 的义务，存活靠 `rootAtomSlots` 与随后的 shade。内部 `objectRestOwnKeys` 的全量键表由本函数 `defer freeKeys` 释放，`out` 与 `all` 在跨逐键 [[GetOwnProperty]]（可进 proxy trap）时登记进 `rootAtomSlots`，失败路径 `errdefer freeAtomList(out)`。error set：`error.OutOfMemory` 与 proxy trap 上抛的异常，原样向上传、不吞。

### `forInOwnKeyIsEnumerable` (`src/exec/forof_ops.zig:181`)

- **签名**：`fn forInOwnKeyIsEnumerable( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, key: core.Atom, ) !bool`。
- **作用**：判定一个 own key 是否可枚举（SET_ENUM 走查的逐键 is_enumerable）。
- **实现**：非 proxy 对象先读 shape 标志 `ownPropertyEnumerableKind`：`.enumerable`/`.not_enumerable` 直接出结果，`.descriptor` 落到慢路径（quickjs.c:8629）。proxy/exotic 或慢路径走完整 `proxyAwareOwnPropertyDescriptor`，让 gopd trap 的顺序与次数与 qjs 一致（quickjs.c:8674-8688）；描述符不存在按不可枚举处理（quickjs.c:8673），`desc.enumerable` 为 null 也按 false。
- **所有权 / 错误 / 调用**：不分配、不返回所有权：只从描述符里取一个 `enumerable` 位，`desc` 本身是栈上结构。error 全是 `proxyAwareOwnPropertyDescriptor` 的透传（gopd trap 抛的 JS 异常、`error.TypeError`、分配失败），本函数一律不吞。调用方都在本文件：`forof_ops.zig:168`（快照逐键判定）与 `:240`（`forInHasEnumerableStringKey` 的原型探测）。

### `forInDefineVisited` (`src/exec/forof_ops.zig:205`)

- **签名**：`pub fn forInDefineVisited(rt: *core.JSRuntime, iterator: *core.Object, key: core.Atom) !void`。
- **作用**：把一个键记进 visited 去重集：在迭代器对象自身上定义值为 `null` 的属性（qjs 的 enum_obj 手法）。
- **实现**：先 `existsOwnProperty` 去重（qjs 只在 dedup miss 后定义，也避免重定义这个不可配置标记），再 `defineOwnProperty(key, Descriptor.data(JSValue.nullValue(), false, true, false))`。QuickJS 坐标：quickjs.c:16469、quickjs.c:16386。
- **所有权 / 错误 / 调用**：不分配长期对象：visited 标记就是迭代器对象自身上一个值为 `null`、可枚举但不可写、不可配置的属性（`Descriptor.data` 的参数序是 `value, writable, enumerable, configurable`，对应 qjs 的 `JS_PROP_ENUMERABLE`），随迭代器一起回收。`existsOwnProperty` 的去重保证不会撞上「重定义不可配置属性」，所以剩下的 error 基本只有 `defineOwnProperty` 的 `error.OutOfMemory`。调用方：`forof_ops.zig:171`（快照里的非可枚举键就地入集）与 `iterator_ops.zig:909`（`forInNext` 原型链阶段记录已产出的键）、`:973`/`:977`（`forInPrepareProtoChainEnum` 用根对象快照种 visited 集）。

### `forInHasEnumerableStringKey` (`src/exec/forof_ops.zig:218`)

- **签名**：`pub fn forInHasEnumerableStringKey( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, object: *core.Object, ) !bool`。
- **作用**：探测某个（原型）对象是否至少拥有一个自有可枚举字符串键，供原型链枚举的 ENUM_ONLY 快筛。
- **实现**：typed array：长度非 0 即 true（元素都是可枚举下标键，quickjs.c:8656-8659）。proxy / 有 exotic 方法 / `module_ns` 类：构造再丢弃过滤后的 tab——`objectRestOwnKeys` 后对每个字符串键都跑 `forInOwnKeyIsEnumerable`，**不提前退出**，以复刻 qjs 的 trap 次数（quickjs.c:16369）。dense 元素非空的普通数组直接 true。最后扫 `shapeProps`，遇到未删除、可枚举、字符串 kind 的属性返回 true，否则 false。QuickJS 坐标：quickjs.c:16360-16369、quickjs.c:8626-8651。
- **所有权 / 错误 / 调用**：只返回 bool，不交出任何所有权：`objectRestOwnKeys` 的 tab 由本函数 `defer freeKeys` 释放。proxy `ownKeys` / gopd trap 抛的异常与 `error.OutOfMemory` 直接上抛、不吞（异常会沿 `forInNext` 冒到 `forInNextVm` 的 catch 分发）。唯一调用方 `iterator_ops.zig:953`（`forInPrepareProtoChainEnum` 的原型链快筛循环）。

### `iteratorCatchMarker` (`src/exec/forof_ops.zig:262`)

- **签名**：`pub fn iteratorCatchMarker(previous_target: i32) core.JSValue`。
- **作用**：把「进入 for-of 记录时的外层 catch target」编码成一个 iterator catch marker 值。
- **实现**：断言 `previous_target >= -1` 且 `<= maxInt(i32) - 3`。`previous_target == -1` 编码成 `minInt(i32)`，否则编码成 `minInt(i32) + previous_target + 1`，再包成 `JSValue.catchOffset`。结果落在 payload `< -2` 的区间，和普通 catch offset（`>= -1`）以及 async marker（`-2`）互不混淆。
- **所有权 / 错误 / 调用**：返回的是立即数 catch-offset `JSValue`，不是堆对象：没有所有权协议，调用方的 `pushOwned` 只是栈记账。无 error set（两条 `debug.assert` 只在 Debug 下守编码区间）。生产调用方唯一：`iterator_ops.zig:91`（`forOfStart` 压 for-of 记录第三槽），`forof_ops.zig:297` 在本文件测试块里。

### `iteratorCatchMarkerPreviousTarget` (`src/exec/forof_ops.zig:272`)

- **签名**：`pub fn iteratorCatchMarkerPreviousTarget(value: core.JSValue) ?i32`。
- **作用**：从 iterator catch marker 解回保存的外层 catch target；不是同步 marker 则返回 null。
- **实现**：取 `value.asCatchOffset()`，不是 catch-offset 返回 null；`encoded >= -2`（普通 catch offset 与 async marker）也返回 null；`encoded == minInt(i32)` 还原成 -1，其余还原成 `encoded - minInt(i32) - 1`。
- **所有权 / 错误 / 调用**：纯解码，不分配、无 error。生产里只有本文件 `forof_ops.zig:289`（`isIteratorCatchMarker`）调用，而且只用它「是否为 null」做判别——**编码进 marker 的外层 catch target 目前没有任何生产代码读回来**，只有 `forof_ops.zig:300`/`:305` 的测试断言往返一致。

### `asyncIteratorCatchMarker` (`src/exec/forof_ops.zig:279`)

- **签名**：`pub fn asyncIteratorCatchMarker() core.JSValue`。
- **作用**：返回 for-await 记录用的 async marker：payload 固定为 `-2` 的 catch-offset 值。
- **实现**：薄封装，主体转发到 `JSValue.catchOffset`。
- **所有权 / 错误 / 调用**：同 `iteratorCatchMarker`：立即数 catch-offset，无分配、无 error。调用方 `iterator_ops.zig:144`（`pushForAwaitRecord` 压第三槽）与 `:419`（`iteratorGetValueDone` 把被 `forAwaitOfNext` 清成 undefined 的 marker 槽重新写回 async marker）；`forof_ops.zig:302` 是测试。

### `isAsyncIteratorCatchMarker` (`src/exec/forof_ops.zig:283`)

- **签名**：`pub fn isAsyncIteratorCatchMarker(value: core.JSValue) bool`。
- **作用**：判断值是否是 payload == -2 的 async iterator marker。
- **实现**：`value.asCatchOffset()` 不存在时 false，否则与常量 `async_iterator_catch_offset`（-2）比较。
- **所有权 / 错误 / 调用**：纯判定，不分配、无 error、不消费栈。调用方 `iterator_ops.zig:1015`（`iteratorClose` 据此决定走 for-await 还是同步 IteratorClose）与本文件 `forof_ops.zig:289`（`isIteratorCatchMarker`）。

### `isIteratorCatchMarker` (`src/exec/forof_ops.zig:287`)

- **签名**：`pub fn isIteratorCatchMarker(value: core.JSValue) bool`。
- **作用**：判断值是否是任意一种 iterator 记录 marker（async 的 -2，或同步的 minInt..-3）。
- **实现**：`isAsyncIteratorCatchMarker(value) or iteratorCatchMarkerPreviousTarget(value) != null`。
- **所有权 / 错误 / 调用**：纯判定，不分配、无 error。它是「这三槽是不是 for-of 记录」的唯一判据，所以调用面很宽：`iterator_ops.zig:502`（`forOfIteratorIndex` 校验 depth 操作数）、`:1014`（`iteratorClose`）、本文件 `:402`（`isForOfRecordAt`）与 `:427`（`hasCatchMarkerAboveForOfRecord` 把嵌套迭代器 marker 排除出 catch 边界），以及 `vm_value.zig:235`/`:254`（`drop`/`nipCatch` 不把它当 catch 目标）、`array_ops.zig:120`（`popCatchMarker` 弹三槽记录），生产调用点共 7 处。

### `closeStackTopForOfIteratorForPendingError` (`src/exec/forof_ops.zig:307`)

- **签名**：`pub fn closeStackTopForOfIteratorForPendingError( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, stack: *stack_mod.Stack, ) !void`。
- **作用**：帧解绑/异常上抛前的兜底：对栈上所有「无 catch 边界」的 for-of 记录做 IteratorClose，再把原异常放回。
- **实现**：uncatchable 中断直接返回（不 take/rethrow，以免清掉不可捕获标志）。否则记下 OOM 标志、`takeException` 取走 pending 异常，然后用 `findTopClosableForOfRecordIndexBefore` 从栈顶往下逐个找「其上没有 catch 边界」的 for-of 记录：先把记录的 iterator 槽换成 `undefined`（IteratorClose 的一次性语义），再 `closeIteratorFromVm`，close 自身的失败与它留下的异常都被吞掉。循环完把原异常 `throwValue` 回去并按需 `markExceptionOutOfMemory`。（原先的 `...Internal` 实现层与它逐字相同，已折叠进来。）
- **所有权 / 错误 / 调用**：不分配；被关掉的迭代器槽写成 `undefined` 即放弃引用，由 GC 回收。虽然签名是 `!void`，但所有 close 失败都被 `catch {}` 吞掉，推断出的 error set 为空，调用方的 `try` 只是形式。调用方是异常上抛前的 11 个 unwind 点：`call_runtime.zig:117`/`:173`、`tailcall_dispatch.zig:679`/`:7237`、`vm_control.zig:111`、`vm_gen_async.zig:710`、`inline_calls.zig:5202`/`:5232`、`vm_property_field.zig:199`/`:231`/`:267`（后四处原先走 `...WithFrame` 壳，那个只多带一个从不被读的帧参数的入口已删）。

### `closeIteratorForAbruptCompletion` (`src/exec/forof_ops.zig:347`)

- **签名**：`pub fn closeIteratorForAbruptCompletion( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterator_value: core.JSValue, ) void`。
- **作用**：对单个迭代器做异常完成时的 IteratorClose，且不让 close 的失败顶掉已挂起的异常。
- **实现**：与 `...Internal` 同形但只针对一个给定迭代器：uncatchable 直接返回；记下 OOM 标志并 `takeException` 取走 pending 异常；`closeIteratorFromVm` 失败被吞、残留异常 `clearException`；最后 `throwValue` 恢复原异常并按需 `markExceptionOutOfMemory`。
- **所有权 / 错误 / 调用**：返回 `void`：不交出所有权、也不产生新错误——`closeIteratorFromVm` 的失败和它留下的异常都被吞掉，原 pending 异常（含 OOM 标志）原样恢复，uncatchable 中断直接返回。迭代器值是借用的，本函数不清任何栈槽（调用方自己管）。调用方全在 Promise combinator 的迭代循环：`promise_ops.zig:2257`、`:2263`、`:2267`、`:2291`（`Promise.all`/`allSettled`/`any`/`race` 在 resolve/then 失败时关掉源迭代器再 reject capability）。

### `findTopClosableForOfRecordIndexBefore` (`src/exec/forof_ops.zig:364`)

- **签名**：`fn findTopClosableForOfRecordIndexBefore(stack: *const stack_mod.Stack, before: usize) ?usize`。
- **作用**：在 `before` 以下从高到低找最近一个「其上没有 catch 边界」的 for-of 记录起始槽位。
- **实现**：`end = @min(before, stack.len())`，不足 3 槽直接 null；从 `end - 3` 向栈底逐槽回扫，命中 `isForOfRecordAt(index)` 且 `!hasCatchMarkerAboveForOfRecord(index)` 就返回该下标；扫到 0 仍未命中返回 null。
- **所有权 / 错误 / 调用**：纯扫描：只读 `stack.values`，不分配、不改栈、无 error。唯一调用方 `closeStackTopForOfIteratorForPendingError` 的关闭循环（，每关一个就把 `before` 收缩到该记录）。

### `isForOfRecordAt` (`src/exec/forof_ops.zig:378`)

- **签名**：`pub fn isForOfRecordAt(stack: *const stack_mod.Stack, index: usize) bool`。
- **作用**：判断从 `index` 起的三槽是否构成 for-of 记录（第三槽是 iterator catch marker）。
- **实现**：`index + 2 >= stack.len()` 时 false（三槽放不下），否则返回 `isIteratorCatchMarker(stack.values[index + 2])`。
- **所有权 / 错误 / 调用**：纯判定，不分配、无 error、不动栈。调用方都在本文件：`forof_ops.zig:391`（扫描器）、`:410`（`abandonForOfIteratorAtIndex` 的断言）、`abandonForOfIteratorAtDepth` 的合法性检查。

### `abandonForOfIteratorAtIndex` (`src/exec/forof_ops.zig:387`)

- **签名**：`pub fn abandonForOfIteratorAtIndex(stack: *stack_mod.Stack, index: usize) void`。
- **作用**：放弃指定槽位上的 for-of 迭代器：把 iterator 槽写成 `undefined`，后续不再对它 `return()`。
- **实现**：断言该处确实是 for-of 记录，再把 iterator 槽写成 `undefined`。对齐 qjs `js_for_of_next` 在 IteratorNext 异常完成时替换当前迭代器的做法，使后续 IteratorClose 不会对刚失败的迭代器再调 `return()`。
- **所有权 / 错误 / 调用**：所有权：把栈槽写成 `undefined` 就是放弃这一份迭代器引用——TGC 下没有 release 动作，值失去最后一个根后由 GC 回收，所以 RC 时代的 `*JSRuntime` 形参已从签名里去掉。无 error（越界由 `debug.assert` 在 Debug 下兜）。调用方：`iterator_ops.zig:519`（`forOfNext` 的 `errdefer`）、`:562`（`finishForOfNextResult` 的 `errdefer`）与本文件 `:419`。

### `abandonForOfIteratorAtDepth` (`src/exec/forof_ops.zig:396`)

- **签名**：`pub fn abandonForOfIteratorAtDepth(_: *core.JSRuntime, stack: *stack_mod.Stack, depth: u8) !void`。
- **作用**：按 depth 操作数定位记录后放弃该迭代器；定位失败即字节码非法。
- **实现**：`required = depth + 3`；栈深不足或 `stack.len() - required` 处不是 for-of 记录都返回 `error.InvalidBytecode`；否则转发 `abandonForOfIteratorAtIndex`。
- **所有权 / 错误 / 调用**：只按 depth 定位后转发，不分配、不交出所有权；`*JSRuntime` 首参本身不用（写成 `_`），保留是为了让 `tailcall_dispatch` / `inline_calls` 的 unwind 调用点维持统一形状。error set 只有 `error.InvalidBytecode`，而它**不在 `exception_ops.runtimeErrorInfo` 的映射表里**：`tryCatchInFrame` 认不出它就返回 false，所以它不会变成可被 JS `catch` 的异常，而是作为引擎错误逃出 dispatch 循环交给宿主。调用方：`inline_calls.zig:5200`/`:5230` 与 `tailcall_dispatch.zig:732`（for-of 体内 return/throw 前放弃当前迭代器）。

### `hasCatchMarkerAboveForOfRecord` (`src/exec/forof_ops.zig:404`)

- **签名**：`pub fn hasCatchMarkerAboveForOfRecord(stack: *const stack_mod.Stack, record_index: usize) bool`。
- **作用**：判断某个 for-of 记录之上是否还压着真正的 catch 边界（嵌套的 iterator marker 只是清理记录，不算边界）。
- **实现**：从 `record_index + 3` 扫到栈顶：非 catch-offset 的槽跳过；是 catch-offset 但 `isIteratorCatchMarker` 为真（嵌套迭代器记录）也跳过；否则返回 true。扫完返回 false。
- **所有权 / 错误 / 调用**：纯扫描，不分配、无 error。唯一调用方 `forof_ops.zig:391`（`findTopClosableForOfRecordIndexBefore`）：有真正的 catch 边界压在记录之上时，这个记录该由那个 catch 处理，pending-error 扫描不能抢着关。

### `closeIteratorFromVm` (`src/exec/forof_ops.zig:415`)

- **签名**：`pub fn closeIteratorFromVm( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterator_value: core.JSValue, ) !void`。
- **作用**：VM 侧 IteratorClose 的公开入口，直接转发 `closeIteratorFromVmImpl`。
- **实现**：单行 `try closeIteratorFromVmImpl(ctx, output, global, iterator_value)`，四个参数原样透传，自身不加任何判断。
- **所有权 / 错误 / 调用**：薄转发，不分配、自身不加 error，error set 全部来自 `closeIteratorFromVmImpl`（`return()` 抛的异常、`error.TypeError`）。调用方：`iterator_ops.zig:1022`（`iteratorClose` 的同步分支）、本文件 `:357`/`:378`（两条吞错的 unwind 路径，在那里错误被 `catch {}`）、`collection_ops.zig:2086`/`:2132`（Map/Set 构造从迭代器灌数据失败时关迭代器）。

### `closeIteratorFromVmImpl` (`src/exec/forof_ops.zig:424`)

- **签名**：`pub fn closeIteratorFromVmImpl( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterator_value: core.JSValue, ) !void`。
- **作用**：ES IteratorClose：取迭代器的 `return` 并调用，校验结果是对象。
- **实现**：`getValueProperty(iterator, "return")`；结果 undefined/null 直接返回（无 return 方法不是错误）；不可调用 → `error.TypeError`；否则 `callValueOrBytecodeRoot(iterator, return, &.{})`，返回值不是对象 → `error.TypeError`。
- **所有权 / 错误 / 调用**：迭代器值是借用的，本函数不接管、不释放；`return()` 的返回值取完类型检查就丢弃。error set：不可调用的 `return` 与非对象返回值给 `error.TypeError`，其余是 `getValueProperty` / `callValueOrBytecodeRoot` 透传的用户异常（已带 pending exception）——TypeError 由上层 `createSentinelError` 或 `throw*Message` 落成 JS 异常。调用方：本文件 `:439` 的公开壳，以及 `promise_ops.zig:2566`（`closeForAwaitIteratorFromVm`：for-await 记录同样走普通 IteratorClose，不 await `return()` 返回的 promise）。

## 覆盖核对

- 清单函数数: 22
- 本文标题覆盖: 22
- 未覆盖: 无
