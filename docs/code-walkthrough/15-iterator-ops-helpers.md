# 15 — `iterator_ops.zig`：zip、Iterator Helpers、step 原语

从 `IteratorZipCompletion` 到文件末尾。helper 的 next 失败必须 IteratorClose 内层迭代器，且不能让 close 的异常盖住原错误（`IteratorZipCompletion`）。

### `IteratorZipCompletion.initNormal` (`src/exec/iterator_ops.zig:1535`)

- **签名**：`pub fn initNormal() IteratorZipCompletion`。
- **作用**：空 completion：无错误、无已捕获异常。
- **实现**：返回 `.{}`：`err = null`、`exception = JSValue.uninitialized()`。
- **所有权 / 错误 / 调用**：不分配、无 error：返回一个全零值结构。`exception` 字段是 `uninitialized()` 哨兵而非 GC 根——后续 `capture`（:1545）在 `:1550` 从 `ctx.takeException()` 接过来的异常值只存在这个栈上结构里，靠调用方的 `defer completion.deinit(rt)`（:2741、:2799）在作用域结束前把它清成 `uninitialized`，或先由 `restore` 重新 `ctx.throwValue` 交还给 context。调用方 `initThrow`（:1540）与 zip 的两处关闭路径 `src/exec/iterator_ops.zig:2740,2798`。

### `IteratorZipCompletion.initThrow` (`src/exec/iterator_ops.zig:1539`)

- **签名**：`pub fn initThrow(ctx: *core.JSContext, err: anytype) IteratorZipCompletion`。
- **作用**：从当前 ctx 异常和 Zig error 构造 completion。
- **实现**：薄封装，主体转发到 `IteratorZipCompletion.initNormal`、`completion.capture`。
- **所有权 / 错误 / 调用**：不分配：返回的是栈上结构，但它**接管了 ctx 的 pending 异常**——`capture` 里的 `ctx.takeException()` 把异常值从 context 上摘下来存进 `completion.exception`，此后 ctx 变成无异常状态，close 才能干净地跑用户 `return()`。因此每个调用方都必须配 `defer completion.deinit(rt)` 与最终的 `restore`，否则异常就丢了。无 error set（返回值不是 error union）。调用方 4 处，全是善后函数的第一行：`iterator_ops.zig:2104`（`iteratorZipCloseAllAndPropagate`）、`:2149`（`iteratorCloseWithCompletionAndPropagate`）、`:2165`（`iteratorHelperCloseWithCompletionAndPropagate`）、`:2645`（`iteratorZipCompleteAbrupt`）。

### `IteratorZipCompletion.capture` (`src/exec/iterator_ops.zig:1545`)

- **签名**：`pub fn capture(self: *IteratorZipCompletion, ctx: *core.JSContext, err: anytype) void`。
- **作用**：记下 Zig error 与已 take 的 JS 异常。
- **实现**：若已存过 exception 先把它丢回 `uninitialized`（只保留最新一次），`self.err = @errorCast(err)`；ctx 上有 pending 异常时 `takeException()` 取走存进 `self.exception`（取走后 ctx 的异常标志被清，close 才能干净地跑）。
- **所有权 / 错误 / 调用**：所有权转移点：`ctx.takeException()` 把 JS 异常值的唯一「context 引用」搬进 `self.exception`（结构体是栈上值，异常值本身靠调用栈保活——TGC 下 `ValueRootFrame` 不覆盖它，但 `restore` 之前不会有分配以外的路径丢掉它）。若之前已存过异常，旧的直接被 `uninitialized` 覆盖丢弃（只保留最新一次）。不分配、无 error。调用方 `iterator_ops.zig:1541`（`initThrow`）与 `:2041`（`iteratorZipCloseWithCompletion` 在 completion 还没记过错误时补记）。

### `IteratorZipCompletion.restore` (`src/exec/iterator_ops.zig:1553`)

- **签名**：`pub fn restore(self: *const IteratorZipCompletion, ctx: *core.JSContext) void`。
- **作用**：清掉当前异常再 throw 回保存的值。
- **实现**：先 `clearException()` 丢掉 close 期间新产生的异常，再把保存的 `exception`（若有）`throwValue` 回 ctx。
- **所有权 / 错误 / 调用**：所有权交回点：先 `clearException` 丢掉 close 期间新产生的异常（这就是「二次错误不覆盖原异常」的实现），再把存下的值 `throwValue` 还给 ctx；还回去之后 `self.exception` 仍是同一个值，靠调用方随后的 `deinit` 清成 `uninitialized`（`restore` 声明为 `*const`，自己不清）。不分配、无 error。调用方是 zip/helper 的全部善后路径共 10 处：`iterator_ops.zig:2045`、`:2107`、`:2113`、`:2152`、`:2169`、`:2172`、`:2652`、`:2657`、`:2746`、`:2804`。

### `IteratorZipCompletion.deinit` (`src/exec/iterator_ops.zig:1558`)

- **签名**：`pub fn deinit(self: *IteratorZipCompletion, _: *core.JSRuntime) void`。
- **作用**：清空保存的异常与 error 字段；本结构不持有堆内存，`rt` 参数未使用。
- **实现**：`exception` 置回 `uninitialized`，`err` 置 null（runtime 参数写成 `_`）。
- **所有权 / 错误 / 调用**：只把 `exception` 置回 `uninitialized`、`err` 置 null——本结构不持有堆内存，`rt` 参数因此写成 `_`（RC 时代这里要 free 异常值）。**它不负责把异常还给 ctx**：`defer deinit` 之前必须先 `restore`，否则异常被静默丢弃。不分配、无 error。调用方是四个善后函数的 `defer`（`iterator_ops.zig:2105`、`:2150`、`:2166`、`:2646`）与 `iteratorZipHelperNext`/`Return` 里两处局部 completion。

### `iteratorZipCall` (`src/exec/iterator_ops.zig:1573`)

- **签名**：`pub fn iteratorZipCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, keyed: bool, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Iterator.zip` / `Iterator.zipKeyed` 入口：解析 options，收集各路迭代器/next/padding（keyed 时还有 keys），造出 zip helper。
- **实现**：`ValueRootBuffer.initCopy` 把 args 复制成受 root 的切片，另有五个受 root 的局部值（iters/nexts/pads/keys/padding）。无参 → `error.TypeError`；`args[0]` 必须是对象。`iteratorZipModeFromOptions` 解析 mode；`.longest` 且给了 options 时再 Get `padding`，非 undefined 就必须是对象。随后建 `iters` / `nexts` / `pads` 三个普通对象（keyed 时再加 `keys`），各自挂 `errdefer destroyFromHeader`。非 keyed 走 `iteratorForValue` + `iteratorZipNextMethod` 后交 `iteratorZipCollectIndexed`；keyed 直接 `iteratorZipCollectKeyed`。收集出的 `count` 超过 `maxInt(i32)` → `error.RangeError`；否则 `iteratorZipCreateHelper` 建 helper。
- **所有权 / 错误 / 调用**：返回 owned 的 zip helper（调用方 `iteratorStaticCall` 直接交给 JS）。GC：`args` 先被 `ValueRootBuffer.initCopy` 复制成受 root 的切片（`defer deinit` 释放这块 `rt.memory` 缓冲），另五个局部值挂 `ValueRootFrame`——因为收集阶段会调用户 `next()`/getter。iters/nexts/pads/keys 四个辅助对象各挂 `errdefer destroyFromHeader`，成功后所有权移交 helper 的槽。错误：无参/首参非对象/mode 非法给 `error.TypeError`，路数超 `maxInt(i32)` 给 `error.RangeError`（两者都是无消息的 sentinel，由 native 缝的 `createSentinelError` 落成 JS 异常）；收集阶段的失败已在 `iteratorZipCollect*` 里经 `iteratorZipCloseAllAndPropagate` 关掉已建迭代器并保住原异常，这里只负责把 error 继续上抛。调用方 `iterator_ops.zig:3220`/`:3221`（`iteratorStaticCall` 的 `zip` 与 `zip_keyed` 两臂）。

### `iteratorZipModeFromOptions` (`src/exec/iterator_ops.zig:1685`)

- **签名**：`pub fn iteratorZipModeFromOptions( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, options: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !IteratorZipMode`。
- **作用**：解析 zip 的 `options.mode`：undefined → shortest，三个字符串之一 → 对应模式，其余一律 TypeError。
- **实现**：`options` 是 undefined 直接 `.shortest`；不是对象 → `error.TypeError`；Get `mode`，undefined → `.shortest`；随后用 `string_ops.stringValueUnitsEqualBytes` 依次比 `"shortest"`/`"longest"`/`"strict"`；都不匹配 → `error.TypeError`。
- **所有权 / 错误 / 调用**：不分配、不持有：只读 `options.mode` 并按字节比较，返回一个枚举。error set：非对象 options 与三个字符串都不匹配时给 `error.TypeError`（裸 sentinel，本函数不挂消息），加上 Get `mode` 时用户 getter 抛的异常。唯一调用方 `iterator_ops.zig:1615`（`iteratorZipCall` 解析 options 的第一步，早于任何迭代器建立，所以这里失败不需要 close 任何东西）。

### `iteratorZipCollectIndexed` (`src/exec/iterator_ops.zig:1704`)

- **签名**：`pub fn iteratorZipCollectIndexed( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterables_iterator: core.JSValue, iterables_next: core.JSValue, iters: *core.Object, nexts: *core.Object, pads: *core.Object, padding: core.JSValue, mode: IteratorZipMode, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !usize`。
- **作用**：`Iterator.zip` 的收集阶段：遍历 iterables 迭代器，把每个元素展平成 (iterator, next) 存进 iters/nexts，并按 mode 填好 pads。
- **实现**：主循环调 iterables 的 `next()`，结果必须是对象，读 `done` 为真就结束，否则读 `value` 交给 `iteratorZipFlattenableRecord` 展平，按 `count` 下标存进 iters/nexts 后 `count += 1`；这一路上的任何失败都转 `iteratorZipCloseAllAndPropagate`（展平失败时还把 iterables 迭代器本身作为 extra 一并关闭）。若 mode 是 `.longest`：padding 非 undefined/null 时另起一个 padding 迭代器，取最多 `count` 个值填进 pads，中途 done 就停并把剩余位置填 `undefined`；若 padding 迭代器未耗尽则 `iteratorZipClose` 关掉它。`.longest` 但 padding 是 undefined/null 时把 pads 全部填成 `undefined`；非 longest 模式整段跳过，pads 一个槽都不写。返回 `count`。
- **所有权 / 错误 / 调用**：收集到的 (iterator, next) 通过 `iteratorZipStoreIndex` 移交给调用方传入的 iters/nexts 对象（它们最终归 helper）；本函数不自建长期对象，返回的只是路数 `count`。错误处理是本函数的主体：主循环与 padding 循环里**每一个**可失败调用都 `catch` 转 `iteratorZipCloseAllAndPropagate`，由它关掉已建的 `count` 路、恢复原异常再把原 error 返回——展平失败那一处还额外把 iterables 迭代器本身作为 `extra_iterator` 一并关闭；padding 循环失败时先把 `padding_iterator` 局部置 undefined，避免同一个迭代器被关两次。error set：`error.TypeError`（结果非对象/展平失败）与透传的用户异常、OOM。唯一调用方 `iterator_ops.zig:1652`（`iteratorZipCall` 的非 keyed 臂）。

### `iteratorZipCollectKeyed` (`src/exec/iterator_ops.zig:1794`)

- **签名**：`pub fn iteratorZipCollectKeyed( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterables: *core.Object, iters: *core.Object, nexts: *core.Object, pads: *core.Object, keys: *core.Object, padding: core.JSValue, mode: IteratorZipMode, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !usize`。
- **作用**：`Iterator.zipKeyed` 的收集阶段：按 own enumerable 键收集迭代器，同时记下键与各自的 padding。
- **实现**：`objectRestOwnKeys` 取 own key（用完 `freeKeys`）。逐键 `proxyAwareOwnPropertyDescriptor`：描述符缺失或 `enumerable != true` 跳过；Get 到的值是 undefined 也跳过；否则 `iteratorZipFlattenableRecord` 展平，`proxyTrapKeyValue` 把 atom 变成 key 值，按 `count` 存进 iters/nexts/keys 后 `count += 1`；失败一律走 `iteratorZipCloseAllAndPropagate`。mode 为 `.longest` 时再逐位从 padding 对象里按 key `getValueProperty` 取 pad（padding 为 undefined/null 时填 `undefined`）。返回 `count`。
- **所有权 / 错误 / 调用**：与 `iteratorZipCollectIndexed` 同样的所有权形状：记录存进调用方给的 iters/nexts/keys/pads，返回路数。`objectRestOwnKeys` 的键表由本函数 `defer freeKeys` 释放。失败一律走 `iteratorZipCloseAllAndPropagate`（这里不传 `extra_iterator`：keyed 版没有外层 iterables 迭代器，源是普通对象的 own key 走查）。error set：proxy `ownKeys`/gopd/getter 抛的用户异常、展平的 `error.TypeError`、`propertyKeyAtom` 与 OOM。唯一调用方 `iterator_ops.zig:1666`（`iteratorZipCall` 的 keyed 臂）。

### `iteratorZipFlattenableRecord` (`src/exec/iterator_ops.zig:1857`)

- **签名**：`pub fn iteratorZipFlattenableRecord( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !IteratorZipRecord`。
- **作用**：zip 版 GetIteratorFlattenable：把一个 iterable 解析成 `{iterator, next}` 记录。
- **实现**：值必须是对象。Get `@@iterator`：非 undefined/null 时必须可调用，调用结果必须是对象，用它作 iterator；undefined/null 时直接把值自身当 iterator。随后 `iteratorZipNextMethod` 取 `next`，组成 `IteratorZipRecord`。
- **所有权 / 错误 / 调用**：返回的 `IteratorZipRecord` 两个字段都是值（iterator 可能就是入参自身），所有权交给调用方，由它 `iteratorZipStoreIndex` 存进 iters/nexts；本函数不建根——注意它会调用户 `@@iterator` 与 Get `next`，中间产生的 iterator 只靠调用方的 root frame 与实参保活。error set：非对象、`@@iterator` 不可调用、调用结果非对象给 `error.TypeError`，其余是用户代码透传。调用方 `iterator_ops.zig:1734`（indexed 收集）与 `:1823`（keyed 收集）；`array_ops.zig:6363` 有一个同名转发壳，但**当前树里没有任何代码调用它**（alias wall 的残留）。

### `iteratorZipNextMethod` (`src/exec/iterator_ops.zig:1879`)

- **签名**：`pub fn iteratorZipNextMethod( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterator_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：取 zip 用的 `next` 方法：先试对象上缓存的 next，没有再走一次属性读取。
- **实现**：值不是对象 → `error.TypeError`；`iterator.cachedIteratorNext(rt)` 命中直接返回；否则 `getValueProperty(iterator, "next")`（不做可调用性检查，留给实际调用点）。
- **所有权 / 错误 / 调用**：返回 `next` 方法值，交调用方存进 nexts 对象或本地使用；命中 `cachedIteratorNext` 时返回的是迭代器对象槽里缓存的那一份（借用，不是新读的）。error set：非对象给 `error.TypeError`，另有 Get `next` 的用户 getter 异常。**不做可调用性检查**，留到真正调用点。调用方 `iterator_ops.zig:1650`（zip 的 iterables 迭代器）、`:1747`（padding 迭代器）、`:1875`（`iteratorZipFlattenableRecord`）。

### `iteratorZipCreateHelper` (`src/exec/iterator_ops.zig:1894`)

- **签名**：`pub fn iteratorZipCreateHelper( rt: *core.JSRuntime, global: *core.Object, iters: *core.Object, nexts: *core.Object, pads: *core.Object, keys: ?*core.Object, count: usize, mode: IteratorZipMode, keyed: bool, ) !core.JSValue`。
- **作用**：用收集好的 iters/nexts/pads(/keys) 造出 zip helper 对象。
- **实现**：五个局部值进 ValueRootFrame。以 `iteratorHelperPrototype` 为原型建 `iterator_helper` 对象（`errdefer destroyFromHeader`），`kind` 写 7(zip)/8(zip_keyed)，`index` 写 `count`（zip helper 用 index 槽存路数），`zip_mode` 写 mode，`zip_state = 0`，`zip_alive = count`；装上 `next`(1)/`return`(2) 方法；再把 iters/nexts/pads 依次写进 `iteratorTargetSlot` / `iteratorZipNextsSlot` / `iteratorZipPadsSlot`（写完就把局部 root 置 undefined），keyed 时另写 `iteratorZipKeysSlot`。
- **所有权 / 错误 / 调用**：把调用方建好的 iters/nexts/pads/keys 四个对象的所有权收进 helper 的四个槽（`setOptionalValueSlot`，带屏障；写一个就把对应局部 root 置 undefined，避免重复根）；返回 owned 的 helper。helper 发布前失败由 `errdefer destroyFromHeader` 兜——注意此时 iters 等已建对象不再被显式销毁，交给 GC。五个局部值全程挂 `ValueRootFrame`，因为建原型、建对象、装 `next`/`return` 方法都可能触发回收。error 只有 OOM 与 `iteratorHelperPrototype` 的透传。唯一调用方 `iterator_ops.zig:1682`（`iteratorZipCall` 的最后一步）。

### `iteratorZipStoreIndex` (`src/exec/iterator_ops.zig:1947`)

- **签名**：`pub fn iteratorZipStoreIndex(rt: *core.JSRuntime, object: *core.Object, index: usize, value: core.JSValue) !void`。
- **作用**：把值按下标 `defineOwnProperty` 进 zip 的辅助对象（iters/nexts/pads/keys）。
- **实现**：先 `rootValues` 钉住待存的值（defineOwnProperty 可能分配、触发 GC），再 `defineOwnProperty(atomFromUInt32(index), Descriptor.data(value, true, true, true))`。
- **所有权 / 错误 / 调用**：值的所有权交给属性槽（`defineOwnProperty` 自持一份）；`rooted_value` 先上 `ValueRootFrame` 是因为 `defineOwnProperty` 会分配、可能触发回收，而入参此刻可能没有别的根——本文件两条 GC 单测（`iterator_ops.zig:1979`、`:2004`）就是专门验证这一点的。error 只有 OOM。生产调用方 10 处，全在收集阶段：`iterator_ops.zig:1737`/`:1738`（indexed 存 iterator/next）、`:1772`/`:1781`/`:1786`（pads）、`:1830`–`:1832`（keyed 存 iterator/next/key）、`:1847`/`:1849`（keyed 的 pads）。

### `iteratorZipGetIndex` (`src/exec/iterator_ops.zig:2017`)

- **签名**：`pub fn iteratorZipGetIndex(object: *core.Object, index: usize) core.JSValue`。
- **作用**：按下标读 zip 辅助对象的槽位，缺失时返回 `undefined`。
- **实现**：`object.getOwnDataPropertyValue(atomFromUInt32(index)) orelse JSValue.undefinedValue()`，只读自有数据属性、不走原型与 getter。
- **所有权 / 错误 / 调用**：返回的是辅助对象自有数据槽里的**借用**值（`getOwnDataPropertyValue`，不走原型、不触发 getter），槽没被 `iteratorZipSetIndex` 覆盖之前它一直有效；缺失时返回 `undefined`。不分配、无 error set（返回裸 `JSValue`）。调用方：`iterator_ops.zig:1840`（keyed 的 pad 取 key）、`:2062`（`iteratorZipCloseAllWithCompletion` 逐路取迭代器）、`:2625`（`iteratorZipPutResult` 取 key）、`:2703`/`:2706`/`:2711`（`iteratorZipHelperNext` 取 iter/pad/next）、`:2757`（longest 的 pad），另有两条单测。

### `iteratorZipSetIndex` (`src/exec/iterator_ops.zig:2021`)

- **签名**：`pub fn iteratorZipSetIndex(rt: *core.JSRuntime, object: *core.Object, index: usize, value: core.JSValue) !void`。
- **作用**：按下标覆写 zip 辅助对象已有的槽位（用于把已关闭的迭代器位置置空）。
- **实现**：`rootValues` 钉住值后 `object.setProperty(atomFromUInt32(index), value)`（与 `iteratorZipStoreIndex` 的 define 不同，这里是赋值）。
- **所有权 / 错误 / 调用**：覆写已有槽位（`setProperty` 而非 define），旧值失去这条边、新值由槽接管；zip 用它把已关闭或刚失败的那一路置成 `undefined`，兑现「同一个迭代器只 close 一次」。`rooted_value` 上 root frame 的理由同 `iteratorZipStoreIndex`（`setProperty` 可能分配）。error：OOM 与 `setProperty` 的属性错误。调用方 `iterator_ops.zig:2063`（关闭循环里先置空再 close）、`:2649`（`iteratorZipCompleteAbrupt` 置空刚失败的那路）、`:2735`（`iteratorZipHelperNext` 里某路 done 后置空）。

### `iteratorZipCloseWithCompletion` (`src/exec/iterator_ops.zig:2030`)

- **签名**：`pub fn iteratorZipCloseWithCompletion( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, completion: *IteratorZipCompletion, iterator_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) void`。
- **作用**：关闭一个 zip 内层迭代器，并保证 close 自身的失败不会盖掉 completion 里已记下的原始异常。
- **实现**：`iteratorZipClose` 成功时什么也不做。失败时：completion 还没记过错误就 `capture`（连同 ctx 上的异常一起取走），已经记过则把新异常 `clearException` 丢掉；随后 `completion.restore(ctx)` 把原异常放回 ctx。
- **所有权 / 错误 / 调用**：返回 `void`、不产生新错误：close 失败时，若 completion 还没记过错误就 `capture`（顺带把 ctx 上的新异常取走），否则直接 `clearException` 丢掉二次异常，最后 `restore` 把原异常放回 ctx。迭代器值是借用的，调用方负责在调用前把槽置空。**注意**：成功路径不调用 `restore`，所以原异常此时仍寄存在 completion 里，由调用方在收尾时统一 `restore`。调用方 `iterator_ops.zig:2065`（`iteratorZipCloseAllWithCompletion` 的逐路关闭）、`:2111`（`iteratorZipCloseAllAndPropagate` 的 extra 迭代器）、`:2151`（`iteratorCloseWithCompletionAndPropagate`）。

### `iteratorZipCloseAllWithCompletion` (`src/exec/iterator_ops.zig:2049`)

- **签名**：`pub fn iteratorZipCloseAllWithCompletion( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, completion: *IteratorZipCompletion, iters: *core.Object, count: usize, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：从高到低逐个关闭 iters 里还活着的迭代器，每个关闭前先把槽位置空。
- **实现**：`index` 从 `count` 递减到 0：`iteratorZipGetIndex` 取出迭代器，先 `iteratorZipSetIndex(undefined)` 置空槽（一次性语义），undefined/null 跳过，否则 `iteratorZipCloseWithCompletion`。只有置空槽的 `setProperty` 会把 error 往上抛。
- **所有权 / 错误 / 调用**：从高到低逐路关闭：先 `iteratorZipSetIndex(undefined)` 把槽位置空（所有权移出，保证一次性语义），再 `iteratorZipCloseWithCompletion`。close 自身的失败被 completion 吞掉，所以本函数的 error set **只有置空槽的 `setProperty` 能抛**（OOM 等）——这也是调用方对它单独 `catch` 的原因。调用方 `iterator_ops.zig:2106`（`iteratorZipCloseAllAndPropagate`）、`:2651`（`iteratorZipCompleteAbrupt`）、`:2742`（`iteratorZipHelperNext` 的 shortest 收尾）、`:2800`（`iteratorZipHelperReturn`）。

### `iteratorZipClose` (`src/exec/iterator_ops.zig:2069`)

- **签名**：`pub fn iteratorZipClose( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterator_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：zip 路径上的 IteratorClose：取 `return` 并调用。
- **实现**：Get `return`；undefined/null 直接返回；不可调用 → `error.TypeError`；否则 `callValueOrBytecodeSyncInternalOutlined(iterator, return, &.{})`，**不**校验返回值是不是对象（与 `forof_ops.closeIteratorFromVmImpl` 的差别）。
- **所有权 / 错误 / 调用**：迭代器借用，`return()` 的返回值取完即弃且**不校验是不是对象**（与 `forof_ops.closeIteratorFromVmImpl` 的差别，后者非对象要报 TypeError）。error set：`return` 不可调用给 `error.TypeError`，加上用户 `return()` 抛的异常；调用方多数把它交给 completion 机制吞掉。调用方：`iterator_ops.zig:2039`（`iteratorZipCloseWithCompletion`）、`:1775`（收集阶段关 padding 迭代器）、`:2307`/`:2311`/`:2315`（`iteratorPredicateCall` 的 every/some/find 提前退出——这三处是 `try`，close 的失败会直接顶替返回值上抛）。

### `iteratorZipCloseAllAndPropagate` (`src/exec/iterator_ops.zig:2093`)

- **签名**：`pub fn iteratorZipCloseAllAndPropagate( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iters: *core.Object, count: usize, err: IteratorZipError, extra_iterator: ?core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) IteratorZipError`。
- **作用**：收集/步进出错时的统一善后：关闭所有已建迭代器（可选再关一个 extra），恢复原异常并把原 error 返回出去。
- **实现**：用 `initThrow` 把传入的 err 与 ctx 上的异常一起装进 completion（defer `deinit`）。`iteratorZipCloseAllWithCompletion` 若抛（置空槽失败），先 `restore` 原异常再返回该 close error。随后若给了 `extra_iterator` 再 `iteratorZipCloseWithCompletion` 关一个。最后 `completion.restore(ctx)`，返回 `completion.err orelse err`。
- **所有权 / 错误 / 调用**：返回类型是 `IteratorZipError` 而不是 error union：它**总是**返回一个 error，调用方写成 `return iteratorZipCloseAllAndPropagate(...)`。语义是「关掉已建的 count 路（可选再关一个 extra），把原异常放回 ctx，再把原 error 交还」；只有关闭循环本身抛错（置空槽失败）时才改为返回那个 close error。completion 由 `defer deinit` 清理。调用方是 `iteratorZipCollectIndexed`/`iteratorZipCollectKeyed` 里的 18 处 `catch`（`iterator_ops.zig:1722`–`:1845`），覆盖收集阶段每一个可失败调用。

### `iteratorCloseWithCompletionAndPropagate` (`src/exec/iterator_ops.zig:2140`)

- **签名**：`pub fn iteratorCloseWithCompletionAndPropagate( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterator_value: core.JSValue, err: IteratorZipError, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) IteratorZipError`。
- **作用**：单个迭代器版的善后：close 后恢复原异常，返回原 error（helper 的参数校验失败、回调抛出都走这里）。
- **实现**：`initThrow` 装原 err + ctx 异常（defer `deinit`），`iteratorZipCloseWithCompletion` 关一个迭代器，`completion.restore(ctx)`，返回 `completion.err orelse err`。
- **所有权 / 错误 / 调用**：同样是「恒返回 error」的善后函数（单迭代器版）：`initThrow` 接管 ctx 异常 → `iteratorZipCloseWithCompletion` 关一个迭代器（失败被吞）→ `restore` 放回原异常 → 返回 `completion.err orelse err`。迭代器值借用，不消费。调用方分两类：本文件 6 处 helper 参数校验/回调失败（`iterator_ops.zig:2266`、`:2302`（every/find/forEach/some）、`:2334`、`:2371`（reduce）、`:2476`（map/filter/flatMap 建 helper）、`:2493`（take/drop 建 helper）），以及 `builtin_glue.zig:579`–`:606` 的 7 处——Map/Set 等集合从 iterable 灌数据时，adder 或元素读失败都要先 IteratorClose 再上抛。

### `iteratorHelperCloseWithCompletionAndPropagate` (`src/exec/iterator_ops.zig:2156`)

- **签名**：`fn iteratorHelperCloseWithCompletionAndPropagate( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, helper: *core.Object, err: anytype, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) IteratorZipError`。
- **作用**：helper 路径的善后：关闭 helper（含 inner 迭代器）后恢复原异常并返回原 error。
- **实现**：`initThrow` 装原 err + ctx 异常（defer `deinit`）。`iteratorHelperClose` 失败时把新异常 `clearException` 丢掉、`restore` 原异常后返回该 close error；成功则 `restore` 后返回 `completion.err orelse err`。
- **所有权 / 错误 / 调用**：helper 版善后，恒返回 error：`iteratorHelperClose` 会连内层迭代器一起关；close 失败时先 `clearException` 吞掉二次异常、`restore` 原异常，然后返回那个 close error（这一点与 `iteratorCloseWithCompletionAndPropagate` 不同，后者的 close 失败完全被吞）。文件私有，唯一调用方 `iterator_ops.zig:2918`——`iteratorHelperNext` 里 map/filter/flatMap 的用户回调抛出时。

### `iteratorPrototypeMethodCall` (`src/exec/iterator_ops.zig:2176`)

- **签名**：`pub fn iteratorPrototypeMethodCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, args: []const core.JSValue, method_id: u32, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Iterator.prototype` 上各 helper 方法的 id 分发入口。
- **实现**：单个 `switch (method_id)`：`to_array` → `iteratorToArrayCall`；`every`/`find`/`for_each`/`some` → `iteratorPredicateCall` 带对应 `IteratorPredicateKind`；`reduce` → `iteratorReduceCall`；`map`/`filter`/`flat_map` → `iteratorCreateCallbackHelper`；`take`/`drop` → `iteratorCreateLimitHelper`；`dispose` → `iteratorDisposeCall`；未知 id 返回 `null`，交给上层继续级联。
- **所有权 / 错误 / 调用**：纯分发：自己不分配、不建根，返回值的所有权由各臂决定（数组/布尔/helper 对象/undefined）；`null` 表示「不是本域方法」，让上层 builtin 级联继续往下试，不是错误。error 全是各臂透传。调用方两处，其实是同一条路径：`object_ops.zig:2159` 的同名转发壳，以及 `iterator_ops.zig:3205`（`iteratorCallForNativeRecord` 通过那个壳调进来）。

### `iteratorDisposeCall` (`src/exec/iterator_ops.zig:2203`)

- **签名**：`fn iteratorDisposeCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Iterator.prototype[@@dispose]`：对 receiver 调一次 `return()`，恒返回 undefined。
- **实现**：Get `return`：undefined/null 直接返回 `undefined`（无 return 不是错误）；不可调用 → `error.TypeError`；否则无参调用并丢弃结果，返回 `undefined`（不校验结果是不是对象）。
- **所有权 / 错误 / 调用**：receiver 借用；`return()` 的结果取完即弃、不校验类型；恒返回 `undefined`（立即数，无所有权）。error set：`return` 不可调用给 `error.TypeError`，加上用户 `return()` 的异常——**不做 IteratorClose 善后**，因为它本身就是 close。唯一调用方 `iterator_ops.zig:2198`（`iteratorPrototypeMethodCall` 的 `dispose` 臂，即 `Iterator.prototype[@@dispose]`）。

### `iteratorToArrayCall` (`src/exec/iterator_ops.zig:2219`)

- **签名**：`fn iteratorToArrayCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Iterator.prototype.toArray`：把迭代器耗尽收成一个数组。
- **实现**：receiver 必须是对象，Get `next` 且必须可调用，包成一个常驻 `CallSite.initInternal`（整轮循环复用同一调用点）。建结果数组（原型取 realm Array.prototype，`errdefer destroyFromHeader`）。循环 `iteratorStepWithSyncCall`：done 时 `setArrayLength(index)` 并返回数组，否则按 `index` `defineOwnProperty(writable/enumerable/configurable)` 写入。next 抛出时错误直接上抛，不再 close（迭代器自己已经异常完成）。
- **所有权 / 错误 / 调用**：返回 owned 的结果数组；发布前失败由 `errdefer destroyFromHeader` 回收。整轮循环复用同一个 `CallSite`（`initInternal` 是栈上结构，不分配）。**这里刻意不做 IteratorClose**：`next()` 抛出时迭代器已经异常完成，spec 不要求再 `return()`，所以 error 直接上抛。error set：receiver 非对象、`next` 不可调用给 `error.TypeError`，加上 `next()`/`done`/`value` 的用户异常与 OOM。唯一调用方 `iterator_ops.zig:2187`（`iteratorPrototypeMethodCall` 的 `to_array` 臂）。

### `iteratorPredicateCall` (`src/exec/iterator_ops.zig:2254`)

- **签名**：`fn iteratorPredicateCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, args: []const core.JSValue, kind: IteratorPredicateKind, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`every` / `find` / `forEach` / `some` 四个 helper 的共同实现。
- **实现**：receiver 必须是对象；缺回调或回调不可调用 → `iteratorCloseWithCompletionAndPropagate(TypeError)`（先关迭代器再抛）。Get `next` 且必须可调用，`next` 与回调各建一个常驻 `CallSite`（回调 this 为 undefined）。循环 `iteratorStepWithSyncCall`：done 时按 kind 返回 `every → true`、`some → false`、`find`/`for_each → undefined`。否则用 `(value, index)` 调回调，回调抛出走 `iteratorCloseWithCompletionAndPropagate`；结果 `valueTruthy` 后按 kind 处理：`every` 遇假、`some` 遇真、`find` 遇真都先 `iteratorZipClose` 关掉迭代器再返回 false/true/当前值，`for_each` 不做提前退出。
- **所有权 / 错误 / 调用**：返回值按 kind 不同是布尔立即数或 `step.value`（后者是 `next()` 结果里 Get 出来的值，交调用方）。所有权关键在关闭责任的分工：**参数校验失败与回调抛出**走 `iteratorCloseWithCompletionAndPropagate`（先关迭代器、保住原异常再上抛），**提前退出**（every 遇假 / some 遇真 / find 命中）走 `try iteratorZipClose`（正常完成，close 的失败会顶替返回值上抛），而 `next()` 自己抛出时不 close。error set：`error.TypeError`（receiver 非对象、缺回调、`next` 不可调用）与用户代码透传。唯一调用方 `iterator_ops.zig:2188`/`:2189`/`:2190`/`:2192`（`iteratorPrototypeMethodCall` 的 every/find/for_each/some 四臂；中间的 `:2191` 是 reduce）。

### `iteratorReduceCall` (`src/exec/iterator_ops.zig:2323`)

- **签名**：`fn iteratorReduceCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`Iterator.prototype.reduce`：带或不带初值地折叠迭代器。
- **实现**：receiver 必须是对象；缺回调或不可调用 → `iteratorCloseWithCompletionAndPropagate(TypeError)`。Get `next` 且必须可调用，`next` 与回调各建常驻 `CallSite`。没给初值时先取一步作累加器（第一步就 done → `error.TypeError`，即空迭代器无初值），并把下标从 1 起算；给了初值则用 `args[1]`、下标从 0 起算。随后循环：done 返回累加器，否则用 `(accumulator, value, index)` 调回调（抛出走 `iteratorCloseWithCompletionAndPropagate`），结果成为新累加器。
- **所有权 / 错误 / 调用**：累加器是纯局部值：每轮被回调返回值覆盖，最后作为返回值交给调用方；期间没有额外的根——回调的返回值在下一次 `next()` 之前一直只由这个局部持有（TGC 下这是保守扫描覆盖的栈槽）。关闭责任同 `iteratorPredicateCall`：缺回调与回调抛出走 `iteratorCloseWithCompletionAndPropagate`，`next()` 抛出直接上抛。空迭代器且无初值给 `error.TypeError`（裸 sentinel，无消息，与 ES 的 "Reduce of empty iterator with no initial value" 只在语义上对齐）。唯一调用方 `iterator_ops.zig:2191`（`reduce` 臂）。

### `iteratorStepFromNextResult` (`src/exec/iterator_ops.zig:2383`)

- **签名**：`noinline fn iteratorStepFromNextResult( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, next_result: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !IteratorStep`。
- **作用**：把已经拿到的 `next()` 结果对象解码成 `{value, done}`，供 `iteratorStepWithNext` / `iteratorStepWithSyncCall` 共用，避免两套 leftover Get。
- **实现**：`rootValues` 钉住 `next_result`。非对象 → `error.TypeError`。Get `done`；truthy 则返回 `{undefined, done=true}`（不再 Get value）。否则 Get `value`，`done=false`。comptime 身份只在「怎么调用 next」；本函数吃已产出的结果。
- **所有权 / 错误 / 调用**：`next_result` 由调用方交进来，本函数用 `rootValues` 把它钉住（两次 Get 之间可能触发回收），返回的 `value` 是 Get 的结果、所有权归调用方；`done` 为真时不再 Get `value`（省一次属性读，也避免多余的用户可见副作用）。error set：结果非对象给 `error.TypeError`，加上 `done`/`value` getter 的用户异常。`noinline` 是刻意的（把两条 step 路径的 leftover 合并成一份代码）。调用方只有本文件两处：`iterator_ops.zig:2428`（`iteratorStepWithNext`）与 `:2440`（`iteratorStepWithSyncCall`）。

### `iteratorStepWithNext` (`src/exec/iterator_ops.zig:2418`)

- **签名**：`pub inline fn iteratorStepWithNext( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterator_value: core.JSValue, next_method: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !IteratorStep`。
- **作用**：用给定的 `next` 方法走一步：调用后交给 `iteratorStepFromNextResult` 解码。
- **实现**：`callValueOrBytecodeRoot(iterator, next, &.{})` 后 `iteratorStepFromNextResult`。`inline`，供 `forOfNext` 的慢路径使用。
- **所有权 / 错误 / 调用**：不持有任何东西：`next()` 的结果直接交给 `iteratorStepFromNextResult`，返回的 `IteratorStep` 里的 value 归调用方。`inline`，与 `iteratorStepWithSyncCall` 的唯一差别是「怎么调 next」——这里走 `callValueOrBytecodeRoot`（会为字节码 callee 建一次性 Machine/根）。error 全是透传。调用方两处：`iterator_ops.zig:532`（`forOfNext` 的通用慢路径）与 `call_runtime.zig:2916`。

### `iteratorStepWithSyncCall` (`src/exec/iterator_ops.zig:2431`)

- **签名**：`inline fn iteratorStepWithSyncCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, next_call: *CallSite, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !IteratorStep`。
- **作用**：用一个已建好的常驻 `CallSite` 走一步（循环里复用调用点，省去每步重建）。
- **实现**：`next_call.call(&.{})` 后 `iteratorStepFromNextResult`。`inline`，helper 的各循环都用它。
- **所有权 / 错误 / 调用**：同上，不持有任何东西；差别是复用调用方建好的常驻 `CallSite`（栈上结构，循环里省掉每步的调用点重建）。error 全由 `next_call.call` 与 `iteratorStepFromNextResult` 透传。`inline`，9 处调用全在本文件的 helper 循环里：`iterator_ops.zig:2245`（toArray）、`:2292`（predicate）、`:2360`/`:2367`（reduce）、`:2461`（`iteratorStepWithSyncValues`）、`:2864`/`:2875`/`:2881`/`:2910`（helper 的 take/drop/map 系）。

### `iteratorStepWithSyncValues` (`src/exec/iterator_ops.zig:2443`)

- **签名**：`fn iteratorStepWithSyncValues( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterator_value: core.JSValue, next_method: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !IteratorStep`。
- **作用**：由 (iterator, next) 两个值临时建一个 `CallSite` 再走一步（inner 迭代器这种一次性场景用）。
- **实现**：`CallSite.initInternal(iterator, next)` 后转 `iteratorStepWithSyncCall`。
- **所有权 / 错误 / 调用**：为「一次性」场景（inner 迭代器每轮换一个）临时建 `CallSite` 再走一步：`CallSite.initInternal` 是栈上初始化，不分配、无所有权。error 全部透传。调用方 `iterator_ops.zig:2838`（concat 的 inner 步进）与 `:2905`（flatMap 的 inner 步进）——两处的 inner 迭代器都来自 helper 的 `iteratorDataSlot`，是借用。

### `iteratorCreateCallbackHelper` (`src/exec/iterator_ops.zig:2464`)

- **签名**：`fn iteratorCreateCallbackHelper( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, args: []const core.JSValue, kind: IteratorHelperKind, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`map` / `filter` / `flatMap`：校验回调后建带 callback 的 helper 对象。
- **实现**：receiver 必须是对象；缺回调或不可调用 → `iteratorCloseWithCompletionAndPropagate(TypeError)`（按 spec 先关 receiver 再抛）。否则 `iteratorCreateHelper(kind, callback = args[0], limit = null)`。
- **所有权 / 错误 / 调用**：返回 owned 的 helper（实际由 `iteratorCreateHelper` 铸出）。所有权要点是**失败时的 close 责任**：缺回调或回调不可调用时按 spec 先 `iteratorCloseWithCompletionAndPropagate` 关掉 receiver 再抛 TypeError，而不是直接返回错误。receiver 与 callback 都是借用，进 helper 槽后由 helper 持有。error set：`error.TypeError` 加 `iteratorCreateHelper` 的透传（Get `next` 的用户异常、OOM）。调用方 `iterator_ops.zig:2193`/`:2194`/`:2197`（map/filter/flatMap 三臂）。

### `iteratorCreateLimitHelper` (`src/exec/iterator_ops.zig:2481`)

- **签名**：`fn iteratorCreateLimitHelper( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, args: []const core.JSValue, kind: IteratorHelperKind, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：`take` / `drop`：把参数转成计数后建带 limit 的 helper 对象。
- **实现**：receiver 必须是对象；`iteratorLimitArgument` 失败（NaN/负数 → RangeError，或 ToNumber 抛出）时走 `iteratorCloseWithCompletionAndPropagate` 先关 receiver 再抛。成功则 `iteratorCreateHelper(kind, callback = undefined, limit)`。
- **所有权 / 错误 / 调用**：同 `iteratorCreateCallbackHelper`：`iteratorLimitArgument` 失败（RangeError 或 `ToNumber`/`@@toPrimitive` 抛出）时先关 receiver 再把原 error 抛出去，所以用户可见的错误顺序是「先跑 `return()` 再抛」。limit 只是个 `usize`，没有所有权。error set：`error.RangeError`/`error.TypeError` 与用户代码透传。调用方 `iterator_ops.zig:2195`/`:2196`（take/drop 两臂）。

### `iteratorLimitArgument` (`src/exec/iterator_ops.zig:2498`)

- **签名**：`fn iteratorLimitArgument( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, args: []const core.JSValue, ) !usize`。
- **作用**：把 `take`/`drop` 的参数转成非负整数计数（Infinity 记作 usize 上限）。
- **实现**：缺参按 undefined 处理；对象先 `toPrimitiveForNumber`，再 `toNumberValue` 取数（float 优先，否则由 int32 转 f64）。NaN → `error.RangeError`；非有限 → `maxInt(usize)`；`trunc` 后为负 → `error.RangeError`；否则 `@intFromFloat`。`receiver` 参数未使用。
- **所有权 / 错误 / 调用**：只做数值转换，不分配、不持有（`receiver` 形参未用）。error set：NaN 与负数给 `error.RangeError`（裸 sentinel，`createSentinelError` 会造一个空 message 的 RangeError），另有 `toPrimitiveForNumber`/`toNumberValue` 里用户 `valueOf`/`@@toPrimitive` 抛的异常；`Infinity` **不报错**而是折成 `maxInt(usize)`（等价于无限配额）。唯一调用方 `iterator_ops.zig:2492`（`iteratorCreateLimitHelper`），它负责失败时的 IteratorClose。

### `iteratorCreateHelper` (`src/exec/iterator_ops.zig:2520`)

- **签名**：`fn iteratorCreateHelper( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, kind: IteratorHelperKind, callback: core.JSValue, limit: ?usize, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, comptime getValueProperty: anytype, ) !core.JSValue`。
- **作用**：各 helper 的公共构造：取 receiver 的 `next`，建 `iterator_helper` 对象并填好 target/kind/index/next/callback 槽。
- **实现**：receiver、callback 与取到的 next 都进 `rootValues`。receiver 必须是对象，用 comptime 注入的 `getValueProperty` 取 `next`（不校验可调用性，留到 helper 的 next 里）。以 `iteratorHelperPrototype` 为原型建 `iterator_helper`（`errdefer destroyFromHeader`），写 `iteratorTargetSlot = receiver`、`kind`、`index = limit orelse 0`（take/drop 用 index 槽存剩余计数，map/filter/flatMap 用它当回调下标）、`iteratorNextSlot = next`；callback 非 undefined 时写 `iteratorCallbackSlot`。
- **所有权 / 错误 / 调用**：返回 owned 的 helper：receiver 进 `iteratorTargetSlot`、取到的 `next` 进 `iteratorNextSlot`、非 undefined 的 callback 进 `iteratorCallbackSlot`，三处都走 `setOptionalValueSlot`（带屏障、槽自持）；发布前失败由 `errdefer destroyFromHeader` 回收。GC：receiver/callback/next 全程挂 `ValueRootFrame`，因为 Get `next` 会跑用户 getter、建原型与建对象都可能触发回收（`iterator_ops.zig:2595` 那条单测正是用直接 function-bytecode 的 callback 验证这条根）。error set：receiver 非对象给 `error.TypeError`，加上 Get `next` 的用户异常与 OOM。调用方 `iterator_ops.zig:2478`（callback 系）与 `:2495`（limit 系）。

### `iteratorZipPutResult` (`src/exec/iterator_ops.zig:2617`)

- **签名**：`fn iteratorZipPutResult( rt: *core.JSRuntime, results: *core.Object, keys: ?*core.Object, index: usize, value: core.JSValue, ) !void`。
- **作用**：把某一路的结果写进本轮 zip 的结果容器：keyed 用对应 key 作属性名，否则用下标。
- **实现**：有 `keys` 时先 `iteratorZipGetIndex(keys, index)` 取 key 值、`propertyKeyAtom` 转 atom，再 `defineOwnProperty(writable/enumerable/configurable)`；没有 keys 则直接按 `atomFromUInt32(index)` 定义。
- **所有权 / 错误 / 调用**：把某一路的值写进本轮结果容器，所有权交给属性槽；`keys` 非空时 key 值取自 keys 辅助对象的借用槽，经 `propertyKeyAtom` 转成 atom。error：`propertyKeyAtom` 对非法 key 的 `error.TypeError`（keyed 模式下 key 来自 `proxyTrapKeyValue`，正常情况必是 string/symbol）与 `defineOwnProperty` 的 OOM。文件私有，调用方全在 `iteratorZipHelperNext`：`iterator_ops.zig:2707`（槽已空时填 pad）、`:2728`（正常值）、`:2758`（longest 的 pad）。

### `iteratorZipCompleteAbrupt` (`src/exec/iterator_ops.zig:2633`)

- **签名**：`fn iteratorZipCompleteAbrupt( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, helper: *core.Object, iters: *core.Object, count: usize, current_index: ?usize, err: IteratorZipError, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) IteratorZipError`。
- **作用**：zip helper 步进中途出错的统一善后：标记 helper 死亡、关闭所有路、清空槽位并保住原异常。
- **实现**：`initThrow` 装原 err + ctx 异常（defer `deinit`），`zip_alive = 0`；若给了 `current_index` 先把该路槽位置空（它刚刚异常完成，不该再 close）。`iteratorZipCloseAllWithCompletion` 关掉其余路——它抛则 `restore` 后返回该 close error。随后 `iteratorHelperClear` 清掉 helper 的所有值槽、`zip_state = 3`（已完成），`restore` 原异常，返回 `completion.err orelse err`。
- **所有权 / 错误 / 调用**：zip helper 步进中途出错的统一善后，恒返回 error。所有权动作有三步：`zip_alive = 0` 先把 helper 标死；`current_index` 非空时把刚失败那一路的槽置空（它已异常完成，不该再 `return()`）；`iteratorZipCloseAllWithCompletion` 关掉其余路后 `iteratorHelperClear` 清掉 helper 的全部值槽、`zip_state = 3`。原异常由 completion 保管并在最后 `restore`。注意关闭循环抛错时会**跳过** `iteratorHelperClear`，直接返回那个 close error（helper 的槽保持原样，但 state 仍是 2/未完成）。调用方 6 处，全在 `iteratorZipHelperNext`（`iterator_ops.zig:2713`–`:2762`）。

### `iteratorZipHelperNext` (`src/exec/iterator_ops.zig:2661`)

- **签名**：`fn iteratorZipHelperNext( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, helper: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：zip / zipKeyed helper 的 `next`：各路走一步，按 mode 合成一轮结果。
- **实现**：先走 `zip_state` 状态机：0/1（未开始/已产出过）置 2 表示本次执行中；2（重入）→ `error.TypeError`；3（已完成）→ 直接 done 结果；其它值 → TypeError。target 槽为空也直接 done。取出 iters/nexts/pads（keyed 再取 keys）、mode、`alive` 与路数 `count`，结果容器非 keyed 是数组、keyed 是普通对象。逐路：槽位已空时非 longest → TypeError，longest 则填 pad。否则调该路 `next()`，结果必须是对象，读 `done`：未 done 时 strict 模式下若已有别路 done 就 TypeError，否则读 `value` 写进结果、`values += 1`；已 done 则 `alive -= 1`、`dones += 1`、槽位置空并回写 `zip_alive`，再按 mode 分支——shortest 关掉所有路、清 helper、`state = 3` 并返回 done；longest 在 `alive < 1` 时只 `iteratorHelperClear` + `state = 3` 返回 done（各路都已耗尽，不再 close），否则填 pad；strict 在已有值产出时 TypeError。循环结束后若 `values == 0` 同样清 helper、`state = 3` 返回 done；否则非 keyed 结果 `setArrayLength(count)`，`state = 1`，返回 `createIteratorResult(results, false)`。各路 `next()` 调用与结果解码的失败都走 `iteratorZipCompleteAbrupt`。
- **所有权 / 错误 / 调用**：返回 owned 的迭代结果对象（`createIteratorResult` 铸）；每轮的 results 容器（数组或普通对象）也是新建的，写进结果对象后由它持有。iters/nexts/pads/keys 都是从 helper 槽读出的借用对象指针，各路的值经 `iteratorZipPutResult` 转给 results。状态机本身就是重入保护：`zip_state = 2` 期间再次进来给 `error.TypeError`。error set：`error.TypeError`（重入、槽缺失、strict 模式路数不齐、某路结果非对象）与用户 `next()`/getter 的异常——各路 `next()`/结果解码的失败都先经 `iteratorZipCompleteAbrupt` 关掉其余路并清 helper；而 `iteratorZipPutResult`/`iteratorZipSetIndex`/`iteratorHelperClear` 这几个 `try` 的 OOM 是直接上抛的，不走善后。唯一调用方 `iterator_ops.zig:2833`（`iteratorHelperNext` 的 zip/zip_keyed 臂）。

### `iteratorZipHelperReturn` (`src/exec/iterator_ops.zig:2779`)

- **签名**：`fn iteratorZipHelperReturn( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, helper: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：zip / zipKeyed helper 的 `return`：关掉所有路并把 helper 置成已完成。
- **实现**：`zip_state` 为 0（未开始）直接置 3；1（产出过）置 2 防重入；2 → `error.TypeError`；3 → 直接 done 结果。随后若 target 槽还在：`iteratorZipCloseAllWithCompletion` 关掉 `count`（存在 index 槽里）路，`iteratorHelperClear` 清槽、`state = 3`，completion 里记了错就 `restore` 后上抛，否则返回 done 结果；target 已空则只清槽、置 3 并返回 done 结果。
- **所有权 / 错误 / 调用**：返回 owned 的 done 结果对象。所有权：把 `iteratorIndexSlot` 里存的路数当 count，`iteratorZipCloseAllWithCompletion` 逐路置空并 close，随后 `iteratorHelperClear` 清掉 helper 的全部值槽、`zip_state = 3`——helper 从此不再持有任何迭代器。close 期间的错误由局部 completion 收着，最后 `restore` 后作为 error 上抛（此时 helper 已经清干净了）。error set：状态机重入给 `error.TypeError`，其余是用户 `return()` 的异常与 OOM。唯一调用方 `iterator_ops.zig:2996`（`iteratorHelperReturn` 的 zip 臂，且在重入检查之前分流）。

### `iteratorHelperNext` (`src/exec/iterator_ops.zig:2814`)

- **签名**：`pub fn iteratorHelperNext( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, function_object: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：Iterator Helper 对象的 `next`：按 helper kind 分派 zip / concat / take / drop / map / filter / flatMap 的一步。
- **实现**：函数对象的 `iteratorHelperMethod()` 不是 1 就返回 `null` 让上层继续级联；receiver 必须是 `iterator_helper` 类；`generatorExecuting()` 为真（重入）→ `error.TypeError`，否则置位并 `defer` 复位。target 槽为空直接 done 结果。按 kind：zip/zip_keyed 转 `iteratorZipHelperNext`。concat 循环：有 inner 就先步进 inner，未 done 就产出，done 则 `iteratorHelperClearInner`；否则从 records 数组按 `index*2`/`index*2+1` 取 item 与其 `@@iterator` 方法，`index` 加一后调用方法拿到 inner 迭代器并 `iteratorHelperSetInnerFromIterator`；`index >= arrayLength()/2` 时清 helper 并 done。take：`index` 槽是剩余配额，为 0 时 `iteratorHelperClose` 再 done，否则减一后走一步，done 则清 helper。drop：先把 `index` 槽当待丢弃计数循环消耗（中途 done 就清 helper 并 done），再走一步。map/filter/flatMap：取 `next` 与 callback 各建常驻 `CallSite`；flatMap 每轮先排空 inner；走一步，done 则清 helper 并 done；否则取 `index` 作回调下标并加一，调 `callback(value, index)`（抛出走 `iteratorHelperCloseWithCompletionAndPropagate`）；map 直接产出映射值，flatMap 用 `iteratorHelperSetInner` 装上新 inner 后继续，filter 按 `valueTruthy` 决定产出原值还是继续。
- **所有权 / 错误 / 调用**：返回 owned 的迭代结果对象，或 `null` 表示「这个函数对象不是 helper 的 `next`」（让 `call_runtime` 的级联继续，不是错误）。重入保护用 `generatorExecutingSlot` 置位 + `defer` 复位，重入给 `error.TypeError`。所有权动作集中在各臂的收尾：耗尽时 `iteratorHelperClear` 清掉 target/next/callback/inner 全部槽（helper 不再持有源迭代器），concat/flatMap 换 inner 前 `iteratorHelperClearInner`，take 的配额用尽走 `iteratorHelperClose`（会真的 `return()` 源迭代器）。error set：`error.TypeError`（receiver 不是 helper、重入、槽缺失）与用户 `next()`/回调抛的异常——只有 map/filter/flatMap 的**回调**失败会先 `iteratorHelperCloseWithCompletionAndPropagate` 关 helper，源 `next()` 失败则直接上抛。唯一调用方 `call_runtime.zig:1181`。

### `iteratorHelperSetInner` (`src/exec/iterator_ops.zig:2931`)

- **签名**：`fn iteratorHelperSetInner( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, helper: *core.Object, mapped: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：flatMap 的内层安装：把回调返回值解析成迭代器后装进 helper 的 inner 槽。
- **实现**：回调结果必须是对象；Get `@@iterator`，undefined/null 时直接把该对象当迭代器，否则必须可调用、调用结果必须是对象；随后转 `iteratorHelperSetInnerFromIterator`。
- **所有权 / 错误 / 调用**：解析出的 inner 迭代器随即交给 `iteratorHelperSetInnerFromIterator` 写进 helper 槽，本函数自己不持有、不建根（中间的 `@@iterator` 调用结果只由局部持有）。error set：mapped 非对象、`@@iterator` 不可调用或调用结果非对象给 `error.TypeError`，加上用户代码透传。文件私有，唯一调用方 `iterator_ops.zig:2922`（`iteratorHelperNext` 的 flatMap 臂，在回调返回值上执行 GetIteratorFlattenable）。

### `iteratorHelperSetInnerFromIterator` (`src/exec/iterator_ops.zig:2954`)

- **签名**：`fn iteratorHelperSetInnerFromIterator( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, helper: *core.Object, inner_iterator: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：把一个已解析好的 inner 迭代器与它的 `next` 写进 helper 的 inner 槽（concat / flatMap 共用）。
- **实现**：inner 必须是对象，Get 它的 `next`，然后**裸槽写** `iteratorDataSlot` 与 `iteratorInnerNextSlot`——绕开 `setOptionalValueSlot` 的屏障，所以手动补两次 `gc.generationalBarrier`：这是唯一一处非一次性初始化的迭代器 payload 写，flatMap 会让长寿 helper 反复指向新的 inner 迭代器，每次都是 old→young 边。
- **所有权 / 错误 / 调用**：这是本文件唯一一处**绕过 `setOptionalValueSlot` 的裸槽写**：inner 迭代器与它的 `next` 直接写进 `iteratorDataSlot`/`iteratorInnerNextSlot`，因此手动补两次 `gc.generationalBarrier(helper.gcHeader(), …cycleMarkHeader())`。原因写在源码注释里：flatMap 会让一个长寿 helper 反复指向新的 inner 迭代器，每次都是 old→young 边，不是一次性初始化。旧的 inner 值被直接覆盖（调用方保证之前已 `iteratorHelperClearInner` 或已 close）。error set：inner 非对象给 `error.TypeError`，加 Get `next` 的用户异常。调用方 `iterator_ops.zig:2853`（concat 取到下一条 inner）与 `:2951`（`iteratorHelperSetInner`）。

### `iteratorHelperReturn` (`src/exec/iterator_ops.zig:2981`)

- **签名**：`pub fn iteratorHelperReturn( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, function_object: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：Iterator Helper 对象的 `return`：关掉内层与源迭代器并返回 done 结果。
- **实现**：函数对象的 `iteratorHelperMethod()` 不是 2 就返回 `null`；receiver 必须是 `iterator_helper`。kind 是 zip/zip_keyed 时转 `iteratorZipHelperReturn`（**在重入检查之前**）。其余 kind：`generatorExecuting()` 为真 → `error.TypeError`，否则置位并 `defer` 复位，`iteratorHelperClose` 后返回 `createIteratorResult(undefined, true)`。
- **所有权 / 错误 / 调用**：返回 owned 的 done 结果对象，或 `null` 表示不是 helper 的 `return`。关键顺序：zip/zip_keyed 在**重入检查之前**就分流给 `iteratorZipHelperReturn`（zip 有自己的 `zip_state` 状态机，不用 `generatorExecuting` 那套）；其余 kind 置 executing 位后 `iteratorHelperClose` 关内层与源迭代器并清空全部值槽。error set：receiver 不是 helper、重入给 `error.TypeError`，加上用户 `return()` 抛的异常。唯一调用方 `call_runtime.zig:1221`。

### `iteratorHelperClose` (`src/exec/iterator_ops.zig:3005`)

- **签名**：`fn iteratorHelperClose( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, helper: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：关闭 helper：先关内层迭代器，再关源迭代器，最后清空所有值槽。
- **实现**：先 `iteratorHelperCloseInner`。kind 是 concat 时 target 槽存的是 records 数组而不是迭代器，所以只 `iteratorHelperClear` 就返回。否则取 target 槽（为空直接返回），`iteratorCloseValue` 关它；无论成功失败都 `iteratorHelperClear` 清槽，失败时把 close 的 error 上抛。
- **所有权 / 错误 / 调用**：helper 放弃它持有的一切：先 `iteratorHelperCloseInner` 关内层，再按 kind 分——concat 的 target 槽装的是 records 数组而不是迭代器，所以只 `iteratorHelperClear` 不 close；其余 kind 取 target 槽 `iteratorCloseValue`。无论 close 成功与否都执行 `iteratorHelperClear`（槽必被清空），失败时把 close 的 error 上抛给调用方。error set：`iteratorCloseValue` 的 `error.TypeError` 与用户 `return()` 异常。文件私有，调用方 `iterator_ops.zig:2167`（`iteratorHelperCloseWithCompletionAndPropagate`）、`:2860`（take 配额耗尽）、`:3001`（`iteratorHelperReturn`）。

### `iteratorHelperClear` (`src/exec/iterator_ops.zig:3026`)

- **签名**：`fn iteratorHelperClear(rt: *core.JSRuntime, helper: *core.Object) !void`。
- **作用**：清空 helper 的全部值槽（含 inner），让 helper 进入耗尽状态。
- **实现**：先 `iteratorHelperClearInner`，再依次 `clearOptionalValueSlot` 掉 target、next、callback、zip nexts、zip pads、zip keys 六个槽。
- **所有权 / 错误 / 调用**：所有权终点：`clearOptionalValueSlot` 把 target/next/callback/zipNexts/zipPads/zipKeys 六个槽加上 inner 两个槽全部置空——TGC 下这不是 release，只是断边，被清掉的迭代器/回调失去这条根后由 GC 回收。**只清槽，不 close**：调用方必须先把该关的迭代器关掉。声明为 `!void` 但 `clearOptionalValueSlot` 不会失败，推断出的 error set 为空。14 处调用遍布 helper 的每个耗尽/中止出口（`iterator_ops.zig:2655`、`:2743`、`:2753`、`:2769`、`:2801`、`:2809`、`:2845`、`:2866`、`:2877`、`:2883`、`:2912`、`:3015`、`:3020`、`:3023`）。

### `iteratorHelperCloseInner` (`src/exec/iterator_ops.zig:3036`)

- **签名**：`fn iteratorHelperCloseInner( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, helper: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：关闭 flatMap / concat 的内层迭代器并清掉 inner 槽。
- **实现**：inner 槽为空直接返回；否则 `iteratorCloseValue`，无论成败都 `iteratorHelperClearInner`，失败时把 error 上抛。
- **所有权 / 错误 / 调用**：inner 槽为空时直接返回（concat/flatMap 之外的 kind 永远走这条）。关掉 inner 后无论成败都 `iteratorHelperClearInner` 清槽，失败时把 error 上抛——所以「inner 被清空」是无条件的后置条件，不会留下一个已 close 却仍被 helper 指着的迭代器。error set：`iteratorCloseValue` 的 `error.TypeError` 与用户 `return()` 异常。文件私有，唯一调用方 `iterator_ops.zig:3013`（`iteratorHelperClose` 的第一步）。

### `iteratorHelperClearInner` (`src/exec/iterator_ops.zig:3052`)

- **签名**：`fn iteratorHelperClearInner(rt: *core.JSRuntime, helper: *core.Object) !void`。
- **作用**：清掉 helper 的 inner 迭代器与 inner next 两个槽。
- **实现**：对 `iteratorDataSlot` 与 `iteratorInnerNextSlot` 各调一次 `clearOptionalValueSlot`。
- **所有权 / 错误 / 调用**：只把 `iteratorDataSlot` 与 `iteratorInnerNextSlot` 两个槽置空（断边，不是 release、不 close）；`clearOptionalValueSlot` 不会失败，`!void` 的推断 error set 为空。调用方 5 处：`iterator_ops.zig:2840`（concat inner 耗尽）、`:2907`（flatMap inner 耗尽）、`:3027`（`iteratorHelperClear`）、`:3046`/`:3049`（`iteratorHelperCloseInner` 的成败两路）。

### `testIteratorGetValuePropertyOptional` (`src/exec/iterator_ops.zig:3057`)

- **签名**：`fn testIteratorGetValuePropertyOptional( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, key: core.Atom, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：单测替身：跳过完整属性解析，`expectObject` 后直接 `getProperty` 读自有属性（非对象 → TypeError）。
- **实现**：忽略 ctx/output/global/caller 参数；`property_ops.expectObject(value)` 失败转 `error.TypeError`，成功则 `object.getProperty(key)`。
- **所有权 / 错误 / 调用**：无：测试替身，不分配、不建根，`error.TypeError` 只是把 `expectObject` 的失败转个名。生产无调用方——只被 `iterator_ops.zig:2595` 那条单测当 comptime 注入喂给 `iteratorCreateHelper`（生产路径传的是 `object_ops.getValueProperty`）。

### `iteratorCloseValue` (`src/exec/iterator_ops.zig:3075`)

- **签名**：`pub fn iteratorCloseValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterator_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !void`。
- **作用**：helper 路径的 IteratorClose：取 `return` 并调用（结果不校验是否对象）。
- **实现**：Get `return`；undefined/null 直接返回；不可调用 → `error.TypeError`；否则 `callValueOrBytecodeRoot(iterator, return, &.{})` 并丢弃结果。与 `iteratorZipClose` 的差别只在用 `callValueOrBytecodeRoot` 而不是 `...SyncInternalOutlined`。
- **所有权 / 错误 / 调用**：迭代器借用；`return()` 的返回值丢弃且不校验类型（与 `forof_ops.closeIteratorFromVmImpl` 的差别）。error set：`return` 不可调用给 `error.TypeError`，加用户 `return()` 的异常，调用方自行决定吞还是抛。与 `iteratorZipClose` 的唯一区别是用 `callValueOrBytecodeRoot`（为字节码 callee 建一次性 Machine）而不是 `...SyncInternalOutlined`。调用方共 21 处：本文件 `:3019`/`:3045`（helper close）、`array_ops.zig` 10 处（`:775`/`:779`/`:785`/`:792` 与 `:4527`–`:4551` 的 6 处，`Array.from`/`Array.fromAsync` 在回调或转换失败时关源迭代器）、`call_runtime.zig:2730`–`:2747` 的 5 处（生成器/async 边界）、`promise_ops.zig` 3 处（async-from-sync 包装器关内层同步迭代器）、`math_ops.zig:526`。

### `iteratorForValue` (`src/exec/iterator_ops.zig:3090`)

- **签名**：`pub fn iteratorForValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, source_value: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !core.JSValue`。
- **作用**：把任意值解析成迭代器：字符串与内建迭代器直通，其余走 GetIterator 并缓存 `next`。
- **实现**：字符串（原始值或 String 对象）→ `core.object.stringIterator`。已经是 `array_iterator` / `string_iterator` / `generator` / `async_generator` 类的对象直接原样返回（跳过 @@iterator 调用）。否则 `getIteratorMethod` 取 `@@iterator`，不可调用就 `throwTypeErrorMessage("value is not iterable")`；调用后结果必须是对象，再 `cacheIteratorNextMethod` 把 `next` 缓存到迭代器上供后续步进复用。
- **所有权 / 错误 / 调用**：返回的迭代器由调用方拥有——但注意三种来源：字符串走 `core.object.stringIterator` 新建；已是 array/string iterator 或 (async)generator 的对象**原样返回入参**（调用方拿到的是同一个值，不能假定是新对象）；其余调 `@@iterator` 得到新迭代器，并用 `cacheIteratorNextMethod` 把 `next` 缓存进迭代器对象的槽（后续 `iteratorStepValue`/`iteratorZipNextMethod` 直接命中缓存，避免重复属性读）。error set：不可迭代时 `throwTypeErrorMessage("value is not iterable")` 挂消息后返回，其余是 `@@iterator` 调用、结果类型检查的 `error.TypeError` 与用户异常。调用方：`iterator_ops.zig:1649`/`:1744`（zip 的 iterables 与 padding）、`object_builtin_ops.zig:867`/`:910`（`Object.fromEntries` 等）、`collection_ops.zig:2164`、`math_ops.zig:512`、`vm_gen_async.zig:562`/`:566`（yield* 与 for-await）。

### `iteratorStepValue` (`src/exec/iterator_ops.zig:3128`)

- **签名**：`pub fn iteratorStepValue( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterator_value: core.JSValue, ) !IteratorValueDone`。
- **作用**：ES IteratorStep 的独立版本：对一个迭代器无参调一次 `next()`，返回 `{value, done}`。
- **实现**：receiver 必须是对象；`next` 优先取缓存 `cachedIteratorNext`，否则 Get `next`；不可调用 → `error.TypeError`。`callValueOrBytecodeRoot(iterator, next, &.{})` 的结果必须是对象——这里刻意没有按类分派：对**同步**协议来说 Promise 和 RegExp 都只是普通对象（在 job 队列之外拆 Promise 会观测到它的内部状态）。先读 `done`，`value_ops.isTruthy` 为真就返回 `{undefined, true}`，否则读 `value` 返回 `{value, false}`。
- **所有权 / 错误 / 调用**：返回的 `{value, done}` 里的 value 是 Get 的结果，归调用方；迭代器与 `next` 都是借用（`cachedIteratorNext` 命中时用的是迭代器槽里那份）。**失败时不做 IteratorClose**——调用方（`collection_ops` 的集合构造、`builtin_glue` 的 addEntries）自己决定要不要 close。error set：receiver 非对象、`next` 不可调用、`next()` 结果非对象给 `error.TypeError`，加上用户 `next`/getter 的异常。调用方 10 处：`collection_ops.zig:1955`–`:2183` 的 7 处（Map/Set/WeakMap 构造与 `groupBy` 类操作）、`math_ops.zig:523`、`builtin_glue.zig:586`、`call_runtime.zig:2802`。

### `iteratorStepResult` (`src/exec/iterator_ops.zig:3153`)

- **签名**：`pub fn iteratorStepResult( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterator_value: core.JSValue, next_arg: core.JSValue, ) !IteratorStepResult`。
- **作用**：带参数版的一步：调 `next(next_arg)`，返回结果对象本身加上 `{value, done}`。
- **实现**：与 `iteratorStepValue` 同形（缓存 next / 可调用性 / 结果必须是对象），但把 `next_arg` 作为唯一实参传下去，并把 `next()` 的结果对象一并返回。注意取 value 的条件与 `iteratorStepValue` 相反：只有 `done` 为真时才 Get `value`，`done` 为假时 value 留 `undefined`（调用方自己从 `result` 上读）。
- **所有权 / 错误 / 调用**：比 `iteratorStepValue` 多交出一样东西：`next()` 的**结果对象本身**（`.result`），因为调用方要把它整个转给 JS。另一处差异是取值条件相反——只有 `done` 为真才 Get `value`（done 时的 value 是返回值），`done` 为假时 `.value` 留 `undefined`，调用方自己从 `.result` 上读。迭代器/next 借用，不 close。error set 同 `iteratorStepValue`。唯一调用方 `vm_gen_async.zig:568`（`yield*` 委托：把 inner 迭代器的结果对象原样再 yield 出去）。

### `iteratorCallForNativeRecord` (`src/exec/iterator_ops.zig:3178`)

- **签名**：`pub fn iteratorCallForNativeRecord( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, id: u32, args: []const core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：先 intrinsic：ArrayIterator.next / Generator.next|return|throw；再 accessor；再 static from/concat/zip；最后 prototype helper。
- **实现**：两个 `switch` 加两次级联。第一个 switch 命中 `IntrinsicMethod` 四个 id：`array_iterator_next` → `arrayIteratorNext`，`generator_next`/`generator_return`/`generator_throw` → `call_runtime.generator*`，后三者返回 `null` 就地转 `error.TypeError`。第二个 switch 把 constructor/toStringTag 的 getter/setter 四个 accessor id 交给 `object_ops.iteratorPrototypeAccessor`。都不命中则先 `iteratorStaticCall`（from/concat/zip/zipKeyed），有值就返回；最后落到 `object_ops.iteratorPrototypeMethodCall`，由它的返回值（含 `null`）决定。
- **所有权 / 错误 / 调用**：分发器：不分配、不建根，返回值所有权由各臂决定；`null` 表示 id 不属于本域的任何 handler，调用方据此报 TypeError 或继续级联。分发顺序是热度排序：intrinsic（ArrayIterator.next、Generator.next/return/throw）→ accessor → static（from/concat/zip/zipKeyed）→ prototype helper，其中 accessor 与 prototype 两段刻意走 `object_ops` 的同名转发壳（那里负责挂 `throwTypeErrorMessage` 的消息）。error set：generator 三臂拿到 `null` 时就地转 `error.TypeError`，其余透传。调用方两处：`iterator_builtin_ops.zig:124`（`.iterator` 域 record handler）与 `array_ops.zig:192`（方法级联在 receiver 的 native id 属于 `.iterator` 域时先来这里试一把）。

### `iteratorStaticCall` (`src/exec/iterator_ops.zig:3208`)

- **签名**：`pub fn iteratorStaticCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, method_id: u32, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Iterator` 构造器上的静态方法分发：from / concat / zip / zipKeyed。
- **实现**：`switch (method_id)`：`from` → `iteratorFromCall`；`concat` → `string_ops.iteratorConcatCall`（它再带三个 comptime 参数转回本文件的 `iteratorConcatCall`）；`zip` / `zip_keyed` → `iteratorZipCall(keyed = false/true)`；其它 id 返回 `null`。
- **所有权 / 错误 / 调用**：纯 switch 分发，不分配；返回值归调用方，`null` 表示不是静态方法 id（调用方继续往 prototype 段级联）。`concat` 臂特意绕到 `string_ops.iteratorConcatCall`——那只是个补齐三个 comptime 参数的壳，最终回到本文件的 `iteratorConcatCall`。error 全部透传。唯一调用方 `iterator_ops.zig:3204`（`iteratorCallForNativeRecord`）。

### `iteratorFromSourceForIteratorFrom` (`src/exec/iterator_ops.zig:3226`)

- **签名**：`pub fn iteratorFromSourceForIteratorFrom( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, source: core.JSValue, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !IteratorFromResult`。
- **作用**：先 GetIteratorFlattenable（字符串必走 @@iterator）；再对**解析后的 iterator** 做 OrdinaryHasInstance(%Iterator%)，不是对 source。
- **实现**：先 GetIteratorFlattenable（字符串必走 @@iterator）；再对**解析后的 iterator** 做 OrdinaryHasInstance(%Iterator%)，不是对 source。具体：`getIteratorMethod` 取 `@@iterator`；字符串直接调用它拿迭代器；对象 source 在方法为 undefined/null 时就把 source 自身当迭代器，方法存在则必须可调用且调用结果必须是对象。随后 `object_ops.iteratorIsOnIteratorPrototypeChain(resolved)` 为真就返回 `.{ .iterator = resolved }`（不包装）；否则 Get 它的 `next`，返回 `wrap = true` 的三元组。源码注释记了这两处历史 bug：实例判定曾对 source 做、且只有 source 无 @@iterator 时才会包装。错误：error.TypeError。
- **所有权 / 错误 / 调用**：返回的 `IteratorFromResult` 里 `iterator` 可能就是入参 source 自身（无 `@@iterator` 的对象直通），也可能是 `@@iterator` 调用出来的新对象；`next_method` 只在 `wrap = true` 时有值，两者都交给调用方 `iteratorFromCall` 转给 `wrapIteratorFromIterator`。本函数不建根、不 close（GetIteratorFlattenable 阶段的失败按 spec 不需要 IteratorClose）。error set：source 非对象、`@@iterator` 不可调用、调用结果非对象给 `error.TypeError`，加用户代码透传。唯一调用方 `iterator_ops.zig:1351`（`iteratorFromCall`）。

### `iteratorWrapMethodCall` (`src/exec/iterator_ops.zig:3280`)

- **签名**：`noinline fn iteratorWrapMethodCall( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, function_object: *core.Object, kind: IteratorWrapKind, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Iterator.from` 包装器的 `next` / `return`：校验 wrap 方法 id 后，对内层 iterator 调对应方法，结果必须是对象。
- **实现**：`functionIteratorWrapMethod()` 必须等于 kind（next=1 / return=2），否则返回 `null` 让上层继续级联。receiver 必须是 `JS_CLASS_ITERATOR_WRAP`，内层 `iteratorTargetSlot` 不可空。next：优先用缓存的 `iteratorNext()`，否则 Get `next` 且必须可调用。return：Get `return`；缺失则 `createIteratorResult(undefined, true)`；存在则必须可调用。然后 `callValueOrBytecodeRoot(iterator, method, &.{})`；结果非对象 → TypeError。outlined leftover：两个 public `inline` 包装只传 kind。
- **所有权 / 错误 / 调用**：返回的结果对象由调用方拥有；`null` 表示这个函数对象不是本 wrap 方法（继续级联，不是错误）。内层 iterator 与 `next`（可能来自 wrapper 的 `iteratorNext()` 缓存槽）都是借用；`return` 缺失时不报错，直接现造一个 `createIteratorResult(undefined, true)` 交出去。error set：receiver 不是 `iterator_wrap`、方法不可调用、调用结果非对象给 `error.TypeError`，加用户方法抛的异常。`noinline` 是为合并 next/return 两份 leftover，调用方只有两个 `inline` 壳：`iterator_ops.zig:3329`/`:3341`。

### `iteratorWrapNext` (`src/exec/iterator_ops.zig:3320`)

- **签名**：`pub inline fn iteratorWrapNext( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, function_object: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Iterator.from` 包装器的 `next`：以 `.next` kind 转发 `iteratorWrapMethodCall`。
- **实现**：单行 `return iteratorWrapMethodCall(ctx, output, global, receiver, function_object, .next, caller_function, caller_frame)`，除 kind 外参数原样透传。
- **所有权 / 错误 / 调用**：纯转发，不分配、不加 error（全部由 `iteratorWrapMethodCall` 决定，包括 `null` 的级联语义）。`inline` 且只传 `.next`，是为了让共享实现保持单份。唯一调用方 `call_runtime.zig:1182`（native 方法级联里与 `iteratorHelperNext` 并列的一臂）。

### `iteratorWrapReturn` (`src/exec/iterator_ops.zig:3332`)

- **签名**：`pub inline fn iteratorWrapReturn( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, receiver: core.JSValue, function_object: *core.Object, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame, ) !?core.JSValue`。
- **作用**：`Iterator.from` 包装器的 `return`：以 `.return_` kind 转发 `iteratorWrapMethodCall`。
- **实现**：单行 `return iteratorWrapMethodCall(ctx, output, global, receiver, function_object, .return_, caller_function, caller_frame)`，除 kind 外参数原样透传。
- **所有权 / 错误 / 调用**：同 `iteratorWrapNext`，只是 kind 为 `.return_`：对内层迭代器取 `return` 并调用，缺 `return` 时由共享实现直接返回 done 结果。唯一调用方 `call_runtime.zig:1222`。

### `createIteratorResult` (`src/exec/iterator_ops.zig:3353`)

- **签名**：`pub noinline fn createIteratorResult(rt: *core.JSRuntime, global: ?*core.Object, value: core.JSValue, done: bool) !core.JSValue`。
- **作用**：ES `CreateIterResultObject`（7.4.14）的唯一实现：造带 `value` / `done` 数据属性的普通对象。
- **实现**：`rootValues` 钉住 `value`（安装槽自己再取一份引用，参数保持借用）。`createPlainObjectReserved2`：有 `global` 则原型是 realm 的 `%Object.prototype%`；`global == null` 造 null-prototype 结果——这是 bare-runtime 偏差，必须由调用方写明，不能碰巧走到。`errdefer destroyFromHeader`。然后 `defineOwnPropertyAssumingNew` 写 `value` 与 `done`（均为 writable/enumerable/configurable）。iterator result 不是 JSContext 五件初始 Shape 之一，对齐 qjs `js_create_iterator_result` 的普通对象 + 两次 transition。
- **所有权 / 错误 / 调用**：返回 owned 的结果对象；`value` 保持**借用**，写进属性槽时槽自持一份，因此调用方不必先 root（本函数内部 `rootValues` 钉住它跨过建对象与两次 define）。`global == null` 时造 null 原型的结果对象，这是 bare-runtime 的已知偏差（历史上 Map/Set 与 String 迭代器就因为这个让 `result.hasOwnProperty` 抛错），所以每个传 null 的调用点都要自己写明。error 只有 OOM，失败由 `errdefer destroyFromHeader` 兜。调用方共 48 处、遍布 Array/String/collection/generator/promise/helper/wrap 的所有 `next`：本文件 27 处（`:1122`–`:3309`，Array Iterator 与全部 helper 出口）、`call_runtime.zig` 9 处（`:3830`–`:4433`，生成器与 async 结果）、`string_ops.zig` 5 处（`:3196`–`:3225`）、`promise_ops.zig` 2 处，以及 `collection_ops.zig:774`、`array_builtin_ops.zig:767`、`closure.zig:356`、`async_generator.zig:152`、`string_builtin_ops.zig:2136` 各一处。

### `closeIteratorForFromEntriesAbrupt` (`src/exec/iterator_ops.zig:3380`)

- **签名**：`pub fn closeIteratorForFromEntriesAbrupt( ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, iterator_value: core.JSValue, ) !void`。
- **作用**：`Object.fromEntries` 等宿主侧遍历异常完成时的 IteratorClose：取 `return` 并调用。
- **实现**：Get `return`；undefined/null 直接返回；不可调用 → `error.TypeError`；否则 `callValueOrBytecodeRoot(iterator, return, &.{})` 并丢弃结果（不校验结果是不是对象）。caller function/frame 一律传 null。
- **所有权 / 错误 / 调用**：迭代器借用，`return()` 结果丢弃、不校验类型；caller function/frame 一律传 null（宿主侧调用，没有字节码帧）。error set：`return` 不可调用给 `error.TypeError`，加用户 `return()` 的异常；**12 处调用点全都写在 `catch |err| { … }` 块体内**（它跑在已经有 pending 异常的路径上），但调用本身一律是 `try`：close 自己失败时会顶替原 error 上抛。调用方 12 处：`object_builtin_ops.zig:874`–`:976`（`Object.fromEntries` 每一步失败都关一次源迭代器）与 `collection_ops.zig:2179`/`:2188`/`:2193`。

## 覆盖核对

- 清单函数数（本文件分到）: 59（`src/exec/iterator_ops.zig` 全文件 114）
- 本文标题覆盖: 59
- 未覆盖: 无
