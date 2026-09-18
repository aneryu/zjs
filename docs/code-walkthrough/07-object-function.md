# 07 — 函数对象、native 与 realm（`src/core/object.zig`）

bytecode 臂（`u.func`）、native `FunctionPayload`、`FunctionRarePayload`（source、Promise 能力、iterator 标记、callsite 不在此而在 ordinary）、Realm 边、home object、module captures。

bytecode 与 native 互斥：`functionPayload()` 对 bytecode class 返回 null。cold 字段走 aux cell（bytecode，a 类）或 `payload.rare`（native）。`home_or_aux` 低位 tag=1 表示 aux 指针，否则是 home object。

---


### `Object.functionSourceSlot` (`src/core/object.zig:5159`)

- **签名**：`pub fn functionSourceSlot(self: *Object, rt: *JSRuntime) !*?JSValue`。
- **作用**：确保 rare payload 后借用 source 槽。
- **实现**：try ensureFunctionRarePayload，再返回字段地址。
- **所有权 / 错误 / 调用**：即使只需要槽地址也可能分配并失败；裸写不执行值屏障或其他语义校验。

### `Object.functionSource` (`src/core/object.zig:5163`)

- **签名**：`pub fn functionSource(self: *const Object) ?JSValue`。
- **作用**：取回挂在函数对象上的源码文本，`Function.prototype.toString` 对「native 函数但带源码」这一类就靠它返回真正的源文本而不是 `[native code]`。（造这类对象的 `function_ops.sourceFunction` 已删；树内现在只有测试夹具经 `functionSourceSlot` 写这个槽。）
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针；取到就返回 `payload.source`（`?JSValue`，通常是一个字符串值），两臂都落空返回 null。`call.zig` 的 `functionToStringValue` 拿到 null 时退回 `nativeFunctionSourceValue` 合成 `[native code]` 文本。
- **所有权 / 错误 / 调用**：无分配、无 error set；返回的 `?JSValue` 是 rare payload 的借用，调用方不得释放——它的存活靠 `FunctionRarePayload.traceChildEdges` 的 `source` 边，`destroy` 只把槽置 null。调用方：`exec/call.zig:1937`、`exec/call.zig:2017`（`Function.prototype.toString`）、`exec/function_ops.zig:404`（读不到源码就 `error.TypeError`）。

### `Object.hostFunctionKindSlot` (`src/core/object.zig:5168`)

- **签名**：`pub fn hostFunctionKindSlot(self: *Object) *i32`。
- **作用**：借用 native function 的 host_function_kind 字段槽。
- **实现**：断言非 bytecode function；有 function payload 返回字段地址，否则断言 function kind 后 unreachable。
- **所有权 / 错误 / 调用**：不分配或同步其他元数据；直接写入须由调用者保持 id/cache/atom 等合同。

### `Object.hostFunctionKind` (`src/core/object.zig:5175`)

- **签名**：`pub fn hostFunctionKind(self: *const Object) i32`。
- **作用**：查询 native function 的 host_function_kind。
- **实现**：bytecode function 直接返回 0；否则有 function payload 则读取 native 字段，缺失返回 0。
- **所有权 / 错误 / 调用**：只读元数据，不解码、调用或更新缓存。

### `Object.nativeFunctionIdSlot` (`src/core/object.zig:5181`)

- **签名**：`pub fn nativeFunctionIdSlot(self: *Object) *i32`。
- **作用**：借用 native function 的 native_function_id 字段槽。
- **实现**：断言非 bytecode function；有 function payload 返回字段地址，否则断言 function kind 后 unreachable。
- **所有权 / 错误 / 调用**：不分配或同步其他元数据；直接写入须由调用者保持 id/cache/atom 等合同。

### `Object.nativeFunctionId` (`src/core/object.zig:5188`)

- **签名**：`pub fn nativeFunctionId(self: *const Object) i32`。
- **作用**：查询 native function 的 native_function_id。
- **实现**：bytecode function 直接返回 0；否则有 function payload 则读取 native 字段，缺失返回 0。
- **所有权 / 错误 / 调用**：只读元数据，不解码、调用或更新缓存。

### `Object.setNativeBuiltinIdAndRecord` (`src/core/object.zig:5194`)

- **签名**：`pub fn setNativeBuiltinIdAndRecord(self: *Object, rt: *JSRuntime, native_id: i32) void`。
- **作用**：同时安装 native builtin id 和解析得到的调用记录缓存。
- **实现**：先写 nativeFunctionIdSlot；decodeNativeBuiltinId 成功则按 domain/id 查询 rt.internalBuiltinRecord，否则 record=null；最后写 nativeEntrySlot。
- **所有权 / 错误 / 调用**：不分配或报告未知 id 错误；nativeEntrySlot 要求 c_function。直接改 id 裸槽不会自动同步缓存，需使用此组合操作或由调用者维护。

### `Object.nativeEntrySlot` (`src/core/object.zig:5208`)

- **签名**：`pub fn nativeEntrySlot(self: *Object) *?*const native_entry.NativeEntry`。
- **作用**：借用 C-function 的 call_cache 槽。
- **实现**：断言 class==c_function；有 function payload 返回 native.call_cache 地址，否则断言 kind 后 unreachable。
- **所有权 / 错误 / 调用**：不查 builtin 注册表，也不分配或拥有 NativeEntry；写入者保证记录存活及与 id 的一致性。

### `Object.nativeEntry` (`src/core/object.zig:5215`)

- **签名**：`pub fn nativeEntry(self: *const Object) ?*const native_entry.NativeEntry`。
- **作用**：查询 C-function 的调用记录缓存。
- **实现**：非 c_function 返回 null，否则委托 nativeEntryAssumeCFunction。
- **所有权 / 错误 / 调用**：缓存未填充时不自动解析 id，不 retain entry。

### `Object.nativeEntryAssumeCFunction` (`src/core/object.zig:5221`)

- **签名**：`pub fn nativeEntryAssumeCFunction(self: *const Object) ?*const native_entry.NativeEntry`。
- **作用**：查询已证明为 C-function 的 call_cache。
- **实现**：有 function payload 返回 native.call_cache，否则 null。
- **所有权 / 错误 / 调用**：本函数不再次校验 class；只借用 NativeEntry 指针，不执行调用。

### `Object.nativeCallTarget` (`src/core/object.zig:5236`)

- **签名**：`pub fn nativeCallTarget(self: *const Object) ?NativeCallTarget`。
- **作用**：同时借用 native entry 与其 RealmContext。
- **实现**：非 c_function、缺 function payload、call_cache 为空或 native.realm.borrow() 为空均返回 null；否则返回 NativeCallTarget{entry,realm}。
- **所有权 / 错误 / 调用**：NativeCallTarget 是两个非空借用指针的记录，不拥有额外 RealmRef；不根据 id 回填缓存。

### `Object.nativeCallTargetAssumeCFunction` (`src/core/object.zig:5248`)

- **签名**：`pub inline fn nativeCallTargetAssumeCFunction(self: *const Object) ?NativeCallTarget`。
- **作用**：取得已证明 C-function 的 entry/realm 对。
- **实现**：从 function payload 读取非空 call_cache 和 realm.borrow，任一缺失返回 null，否则组合返回。
- **所有权 / 错误 / 调用**：省略 class 检查，调用方承担 c_function 前提；无 retain、分配或 registry 查找。

### `Object.isHostEntryFunction` (`src/core/object.zig:5257`)

- **签名**：`pub fn isHostEntryFunction(self: *const Object) bool`。
- **作用**：按 entry/id/host-kind 字段识别 embedder native function。
- **实现**：要求 c_function、nativeEntry 非空、nativeFunctionId==0 且 hostFunctionKind==0。
- **所有权 / 错误 / 调用**：不检查 prototype 或 realm，返回 true 本身不等价于可构造。

### `Object.installNativeEntry` (`src/core/object.zig:5265`)

- **签名**：`pub fn installNativeEntry(self: *Object, entry: *const native_entry.NativeEntry) void`。
- **作用**：给 C-function 安装借用的 NativeEntry。
- **实现**：断言 c_function，直接写 nativeEntrySlot。
- **所有权 / 错误 / 调用**：不把 nativeFunctionId 或 hostFunctionKind 清零，不分配或 retain；“plain host function”其他字段由构造方保证。

### `Object.functionIteratorWrapMethodSlot` (`src/core/object.zig:5270`)

- **签名**：`pub fn functionIteratorWrapMethodSlot(self: *Object, rt: *JSRuntime) !*u8`。
- **作用**：确保 rare payload 后借用 iterator_wrap_method 槽。
- **实现**：try ensureFunctionRarePayload，再返回字段地址。
- **所有权 / 错误 / 调用**：即使只需要槽地址也可能分配并失败；裸写不执行值屏障或其他语义校验。

### `Object.functionIteratorWrapMethod` (`src/core/object.zig:5274`)

- **签名**：`pub fn functionIteratorWrapMethod(self: *const Object) u8`。
- **作用**：辨认 `%WrapForValidIteratorPrototype%` 上的 `next` / `return`，`Iterator.from()` 包装迭代器的方法调用据此分发。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.iterator_wrap_method`，无 payload 时返回 0。编码由 `object_ops.tagIteratorWrapPrototypeMethod` 在建原型时写入：1 = `next`，2 = `return`；`iterator_ops` 的包装调用先用期望值比对，不等就返回 null 让通用调用路径接手。
- **所有权 / 错误 / 调用**：无分配、无 error set；rare payload 缺失与 `iterator_wrap_method == 0` 不可区分，0 就代表「不是 wrap 方法」。树内唯一调用方 `exec/iterator_ops.zig:3294`，写入端是 `functionIteratorWrapMethodSlot`。

### `Object.nativeDispatchNameSlot` (`src/core/object.zig:5279`)

- **签名**：`pub fn nativeDispatchNameSlot(self: *Object) *atom.Atom`。
- **作用**：借用 native function 的 native_dispatch_name 字段槽。
- **实现**：断言非 bytecode function；有 function payload 返回字段地址，否则断言 function kind 后 unreachable。
- **所有权 / 错误 / 调用**：不分配或同步其他元数据；直接写入须由调用者保持 id/cache/atom 等合同。

### `Object.nativeDispatchName` (`src/core/object.zig:5286`)

- **签名**：`pub fn nativeDispatchName(self: *const Object) atom.Atom`。
- **作用**：查询 native function 的 native_dispatch_name。
- **实现**：bytecode function 直接返回 atom.null_atom；否则有 function payload 则读取 native 字段，缺失返回 atom.null_atom。
- **所有权 / 错误 / 调用**：只读元数据，不解码、调用或更新缓存。

### `Object.installedRealmRegExpLegacyStatics` (`src/core/object.zig:5295`)

- **签名**：`pub inline fn installedRealmRegExpLegacyStatics(self: *Object, rt: *JSRuntime) ?*RegExpLegacyStatics`。
- **作用**：查询已安装 RegExp intrinsic 的 realm legacy snapshot。
- **实现**：contextForGlobalIncludingConstructing(self) 不存在或 regexp_constructor cache 为 null 则返回 null；否则返回 ctx.regexp_legacy_statics。
- **所有权 / 错误 / 调用**：即使 constructor 已缓存，statics 仍可能尚未分配；不创建 context 或 statics。

### `Object.ensureInstalledRealmRegExpLegacyStatics` (`src/core/object.zig:5301`)

- **签名**：`pub fn ensureInstalledRealmRegExpLegacyStatics(self: *Object, rt: *JSRuntime) !?*RegExpLegacyStatics`。
- **作用**：按需创建已安装 RegExp intrinsic 的 legacy snapshot。
- **实现**：先查 context 和 regexp_constructor cache，缺任一返回 null；已有 statics 则复用，否则 createRuntime、默认初始化并写回 context。
- **所有权 / 错误 / 调用**：仅最后分配步骤可能失败，失败不安装指针；所有者为 realm context，并非 self 的独立 payload。

### `Object.arrayBuiltinMarkerSlot` (`src/core/object.zig:5311`)

- **签名**：`pub fn arrayBuiltinMarkerSlot(self: *Object, rt: *JSRuntime) !*ArrayBuiltinMarker`。
- **作用**：确保 rare payload 后借用 array_builtin_marker 槽。
- **实现**：try ensureFunctionRarePayload，再返回字段地址。
- **所有权 / 错误 / 调用**：即使只需要槽地址也可能分配并失败；裸写不执行值屏障或其他语义校验。

### `Object.arrayBuiltinMarker` (`src/core/object.zig:5315`)

- **签名**：`pub fn arrayBuiltinMarker(self: *const Object) ArrayBuiltinMarker`。
- **作用**：查询 function rare payload 的 array_builtin_marker。
- **实现**：有 functionRarePayloadConst 返回字段，否则 .none。
- **所有权 / 错误 / 调用**：无分配、无 error set；payload 缺失即 `.none`，所以读不出标记只说明没打过标。调用方 16 处，主要是 `exec/array_ops.zig:3611`、`exec/call_runtime.zig:2251`、`exec/construct.zig:147` 这类构造/species 快路径准入。

### `Object.typedArrayBuiltinMarker` (`src/core/object.zig:5320`)

- **签名**：`pub fn typedArrayBuiltinMarker(self: *const Object) TypedArrayBuiltinMarker`。
- **作用**：查询 function rare payload 的 typed_array_builtin_marker。
- **实现**：有 functionRarePayloadConst 返回字段，否则 .none。
- **所有权 / 错误 / 调用**：无分配、无 error set；payload 缺失即 `.none`。生产调用方只有 `exec/array_ops.zig:5900` 与 `:5905`（TypedArray 原型方法识别），另外 4 处在 `exec/standard_globals.zig` 的测试块里。

### `Object.internalCallableTag` (`src/core/object.zig:5325`)

- **签名**：`pub fn internalCallableTag(self: *const Object) host_function.InternalCallableTag`。
- **作用**：查询 function rare payload 的 internal_callable_tag。
- **实现**：有 functionRarePayloadConst 返回字段，否则 .none。
- **所有权 / 错误 / 调用**：无分配、无 error set；payload 缺失与未打标签都返回 `.none`。调用方：`exec/call.zig:216`、`exec/call_runtime.zig:850`/`:859`、`exec/promise_ops.zig:3963`；只有写入端 `setInternalCallableTag` 会 ensure payload 并断言 class。

### `Object.setInternalCallableTag` (`src/core/object.zig:5330`)

- **签名**：`pub fn setInternalCallableTag(self: *Object, rt: *JSRuntime, tag: host_function.InternalCallableTag) !void`。
- **作用**：设置 function rare payload 的内部调用标签。
- **实现**：tag 非 none 时按 usesCallerRealm 选择期望 c_function_data 或 c_function 并断言 class；随后确保 rare payload 并写 tag。
- **所有权 / 错误 / 调用**：none 也会 ensure/可能分配；这里不通过 native builtin id 推导或同步其他 marker。

### `Object.arrayIteratorKind` (`src/core/object.zig:5338`)

- **签名**：`pub fn arrayIteratorKind(self: *const Object) u8`。
- **作用**：辨认 `Array.prototype` 与 `%TypedArray%.prototype` 上的 `keys` / `values` / `entries`，调用时直接跳到内建迭代器构造而不必按名字匹配。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.array_iterator_kind`，无 payload 时 0。取值在 `standard_globals` 的方法表里按名字 comptime 烘焙：1=`keys`、2=`values`、3=`entries`（表尾还有 `array_iterator_kind <= 3` 的断言）；`iterator_ops.arrayIteratorMethod` 见到 0 或越界值即返回 null 退回通用路径。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 返回 0，与「kind 0」同形。生产调用方只有 `exec/iterator_ops.zig:1089`，另两处在 `exec/standard_globals.zig` 的测试块。

### `Object.isIteratorIdentityFunction` (`src/core/object.zig:5343`)

- **签名**：`pub fn isIteratorIdentityFunction(self: *const Object) bool`。
- **作用**：辨认 `%IteratorPrototype%[Symbol.iterator]` 那个「return this」恒等函数，`for...of` 取迭代器时识破它就能免掉一次真实调用。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.iterator_identity` 这个 bool，无 payload 时 false。该标志由 `standard_globals` 里的 `iterator_identity_method` 描述符在安装 `%IteratorPrototype%` 时置上，运行期不会被 JS 代码改写。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 即 false。树内唯一调用方 `exec/call_runtime.zig:2936`，写入端 `addIteratorIdentityFunction`。

### `Object.isArrayIteratorNextFunction` (`src/core/object.zig:5348`)

- **签名**：`pub fn isArrayIteratorNextFunction(self: *const Object) bool`。
- **作用**：辨认未被篡改的 `%ArrayIteratorPrototype%.next`，数组 `for...of`、展开、`Array.from` 等快路径的准入条件之一。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.array_iterator_next`，无 payload 时 false。典型用法见 `iterator_ops.fastArrayForOfNext`：先确认迭代器 `class_id == array_iterator`，再用本判别确认栈上缓存的 `next` 还是原装的，然后才允许直接读元素而不走属性查找与调用。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 即 false，快路径因此只会保守地退回慢路。调用方 4 处：`exec/iterator_ops.zig:642`、`exec/call_runtime.zig:2871`、`exec/builtin_glue.zig:561`、`exec/array_ops.zig:6382`。

### `Object.isGeneratorNextFunction` (`src/core/object.zig:5353`)

- **签名**：`pub fn isGeneratorNextFunction(self: *const Object) bool`。
- **作用**：辨认未被篡改的 `%GeneratorPrototype%.next`，同步生成器 `for...of` 的快路径准入条件。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.generator_next`，无 payload 时 false。写入口是 `addGeneratorNextFunction`。快路径（`iterator_ops` 里配对 `class_id == generator` 的那段）确认后直接调 `call_runtime.syncGeneratorStep` 续跑协程，绕开属性查找与通用调用。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 即 false。树内唯一调用方 `exec/iterator_ops.zig:767`，写入端 `addGeneratorNextFunction`。

### `Object.addGeneratorNextFunction` (`src/core/object.zig:5358`)

- **签名**：`pub fn addGeneratorNextFunction(self: *Object, rt: *JSRuntime) !void`。
- **作用**：标记 function rare payload 为 generator-next。
- **实现**：确保 rare payload 后置 generator_next=true。
- **所有权 / 错误 / 调用**：ensure 可失败；不生成函数体、检查 class 语义或注册 builtin。

### `Object.isThrowTypeErrorIntrinsicFunction` (`src/core/object.zig:5363`)

- **签名**：`pub fn isThrowTypeErrorIntrinsicFunction(self: *const Object) bool`。
- **作用**：辨认 `%ThrowTypeError%` 这个唯一的内建 thrower——它被装成 `Function.prototype` 上 `caller`/`arguments` 的 getter 兼 setter，规范要求同一 realm 内是同一个函数对象。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.throw_type_error_intrinsic`，无 payload 时 false。`object_ops.isThrowTypeErrorIntrinsicObject` 是唯一的转发者；配套的 `installFunctionPrototypeThrowTypeErrorAccessors` 用同一个 thrower 值同时充当 get 与 set。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 即 false。树内唯一调用方 `exec/object_ops.zig:2357`。

### `Object.isAsyncIteratorAsyncDisposeFunction` (`src/core/object.zig:5368`)

- **签名**：`pub fn isAsyncIteratorAsyncDisposeFunction(self: *const Object) bool`。
- **作用**：辨认 `%AsyncIteratorPrototype%[Symbol.asyncDispose]`，`await using` 在异步迭代器上触发处置时靠它进入内建实现。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.async_iterator_async_dispose`，无 payload 时 false。`disposable_ops.asyncIteratorAsyncDispose` 以它作守卫：为假立即返回 null 表示「不是我管的函数」；为真才去读 receiver 的 `return` 方法并把结果包成 promise。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 即 false。树内唯一调用方 `exec/disposable_ops.zig:710`。

### `Object.isAsyncGeneratorPrototypeMethod` (`src/core/object.zig:5373`)

- **签名**：`pub fn isAsyncGeneratorPrototypeMethod(self: *const Object) bool`。
- **作用**：辨认 `%AsyncGeneratorPrototype%` 上的 `next`/`return`/`throw`，异步生成器的请求入队走内建路径而非通用 native 分发。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.async_generator_method`，无 payload 时 false。`promise_ops.isAsyncGeneratorPrototypeMethod` 只是带 `rt` 参数（未使用）的转发壳。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 即 false。直接调用方是 `exec/promise_ops.zig:3206` 的同名包装，`exec/call_runtime.zig:1183`–`1225` 的 6 处再经它判定并改走 `asyncGeneratorRejectedTypeError`——TypeError 在这里变成 rejected promise 而不是抛出。

### `Object.iteratorHelperMethod` (`src/core/object.zig:5378`)

- **签名**：`pub fn iteratorHelperMethod(self: *const Object) u8`。
- **作用**：辨认 `%IteratorHelperPrototype%` 上的 `next` / `return`，迭代器辅助方法（`map`/`filter`/`take`/`drop`/`flatMap`/`zip` 等产生的 helper 对象）的驱动入口。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.iterator_helper_method`，无 payload 时 0。编码 1=`next`、2=`return`：`iterator_ops` 里两个分发函数各自比对自己那个常量，不等即返回 null；比对通过后再校验 receiver 的 `class_id == iterator_helper` 并用 `generatorExecuting` 标志挡住重入。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 返回 0 即「不是 helper 方法」。调用方 `exec/iterator_ops.zig:2823`（编号 1）与 `:2990`（编号 2）。

### `Object.asyncFromSyncIteratorMethod` (`src/core/object.zig:5383`)

- **签名**：`pub fn asyncFromSyncIteratorMethod(self: *const Object) u8`。
- **作用**：辨认 `%AsyncFromSyncIteratorPrototype%` 上的 `next`/`return`/`throw`——`for await...of` 套在同步迭代器上时生成的那层内部包装。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.async_from_sync_iterator_method`，无 payload 时 0。`promise_ops` 的分发按 1/2/3 三值 switch 到 `asyncFromSyncIteratorNext` / `Return` / `Throw`；0 返回 null（不是这类函数），其余值落到 `else => null`。分发前先要求 receiver 的 `class_id == async_from_sync_iterator` 并取出 `iteratorTargetSlot` 里的同步迭代器。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 返回 0。树内唯一调用方 `exec/promise_ops.zig:3228`。

### `Object.disposableStackMethod` (`src/core/object.zig:5388`)

- **签名**：`pub fn disposableStackMethod(self: *const Object) u8`。
- **作用**：辨认 `DisposableStack.prototype` 上的各个方法，`using` 相关调用据此直接进内建实现。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.disposable_stack_method`，无 payload 时 0。编码与 `disposable_ops.DisposableStackMethod` 枚举一致：1=`use`、2=`adopt`、3=`defer`、4=`dispose`、5=`move`、6=`disposed` getter（前五个在 `standard_globals` 的原型表按名字烘焙，getter 的 6 在单独的元数据项里给出）。`disposableStackMethodCall` 见 0 返回 null，见到无法解码的值抛 `TypeError`。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 返回 0。生产调用方只有 `exec/disposable_ops.zig:81`，另两处在 `exec/standard_globals.zig` 的测试块。

### `Object.asyncDisposableStackMethod` (`src/core/object.zig:5393`)

- **签名**：`pub fn asyncDisposableStackMethod(self: *const Object) u8`。
- **作用**：辨认 `AsyncDisposableStack.prototype` 上的各个方法，`await using` 相关调用据此进内建实现。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.async_disposable_stack_method`，无 payload 时 0。编码同 `AsyncDisposableStackMethod`：1=`use`、2=`adopt`、3=`defer`、4=`disposeAsync`、5=`move`、6=`disposed` getter——与同步版的唯一差别是 4 号是 `disposeAsync`。分发函数对 4 号特判（先走 `asyncDisposableStackDisposeAsync`，它自己校验 receiver），其余先过 `asyncDisposableStackReceiver` 的 class 检查。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 返回 0。生产调用方只有 `exec/disposable_ops.zig:395`，另两处在 `exec/standard_globals.zig` 的测试块。

### `Object.addArrayBuiltinMarker` (`src/core/object.zig:5398`)

- **签名**：`pub fn addArrayBuiltinMarker(self: *Object, rt: *JSRuntime, marker: ArrayBuiltinMarker) !bool`。
- **作用**：尝试登记 array_builtin_marker，拒绝覆盖不同的既有非空值。
- **实现**：marker 为 .none 则直接 true；否则 ensure rare payload 后委托 setArrayBuiltinMarker。
- **所有权 / 错误 / 调用**：空输入是无操作，不清旧值。ensure 可失败；冲突返回 false 并保留原字段，不校验标记是否适合实际函数体。

### `Object.addTypedArrayBuiltinMarker` (`src/core/object.zig:5404`)

- **签名**：`pub fn addTypedArrayBuiltinMarker(self: *Object, rt: *JSRuntime, marker: TypedArrayBuiltinMarker) !bool`。
- **作用**：尝试登记 typed_array_builtin_marker，拒绝覆盖不同的既有非空值。
- **实现**：marker 为 .none 则直接 true；否则 ensure rare payload 后委托 setTypedArrayBuiltinMarker。
- **所有权 / 错误 / 调用**：空输入是无操作，不清旧值。ensure 可失败；冲突返回 false 并保留原字段，不校验标记是否适合实际函数体。

### `Object.addIteratorIdentityFunction` (`src/core/object.zig:5410`)

- **签名**：`pub fn addIteratorIdentityFunction(self: *Object, rt: *JSRuntime) !bool`。
- **作用**：设置 rare payload 的 iterator_identity 标志。
- **实现**：确保 rare payload，置字段 true，返回 true。
- **所有权 / 错误 / 调用**：ensure 可失败；成功路径无冲突检查或 false 分支，也不执行该功能。

### `Object.addArrayIteratorNextFunction` (`src/core/object.zig:5416`)

- **签名**：`pub fn addArrayIteratorNextFunction(self: *Object, rt: *JSRuntime) !bool`。
- **作用**：设置 rare payload 的 array_iterator_next 标志。
- **实现**：确保 rare payload，置字段 true，返回 true。
- **所有权 / 错误 / 调用**：ensure 可失败；成功路径无冲突检查或 false 分支，也不执行该功能。

### `Object.addThrowTypeErrorIntrinsicFunction` (`src/core/object.zig:5422`)

- **签名**：`pub fn addThrowTypeErrorIntrinsicFunction(self: *Object, rt: *JSRuntime) !void`。
- **作用**：同时标记 ThrowTypeError intrinsic 的布尔标志与调用标签。
- **实现**：确保 rare payload 后置 throw_type_error_intrinsic=true，internal_callable_tag=throw_type_error_intrinsic。
- **所有权 / 错误 / 调用**：不调用 setInternalCallableTag 的 class 断言，也不执行抛错；调用方保证对象适用。

### `Object.addAsyncIteratorAsyncDisposeFunction` (`src/core/object.zig:5428`)

- **签名**：`pub fn addAsyncIteratorAsyncDisposeFunction(self: *Object, rt: *JSRuntime) !bool`。
- **作用**：设置 rare payload 的 async_iterator_async_dispose 标志。
- **实现**：确保 rare payload，置字段 true，返回 true。
- **所有权 / 错误 / 调用**：ensure 可失败；成功路径无冲突检查或 false 分支，也不执行该功能。

### `Object.addAsyncGeneratorPrototypeMethod` (`src/core/object.zig:5434`)

- **签名**：`pub fn addAsyncGeneratorPrototypeMethod(self: *Object, rt: *JSRuntime) !bool`。
- **作用**：设置 rare payload 的 async_generator_method 标志。
- **实现**：确保 rare payload，置字段 true，返回 true。
- **所有权 / 错误 / 调用**：ensure 可失败；成功路径无冲突检查或 false 分支，也不执行该功能。

### `Object.addIteratorHelperMethod` (`src/core/object.zig:5440`)

- **签名**：`pub fn addIteratorHelperMethod(self: *Object, rt: *JSRuntime, method_id: u8) !bool`。
- **作用**：尝试登记 iterator_helper_method 方法编号。
- **实现**：method_id==0 直接 true；否则 ensure rare payload；旧字段非零且不同则 false，否则写入并 true。
- **所有权 / 错误 / 调用**：零输入不清旧字段；冲突不修改该字段，分配失败传播。

### `Object.addAsyncFromSyncIteratorMethod` (`src/core/object.zig:5448`)

- **签名**：`pub fn addAsyncFromSyncIteratorMethod(self: *Object, rt: *JSRuntime, method_id: u8) !bool`。
- **作用**：尝试登记 async_from_sync_iterator_method 方法编号。
- **实现**：method_id==0 直接 true；否则 ensure rare payload；旧字段非零且不同则 false，否则写入并 true。
- **所有权 / 错误 / 调用**：零输入不清旧字段；冲突不修改该字段，分配失败传播。

### `Object.addDisposableStackMethod` (`src/core/object.zig:5456`)

- **签名**：`pub fn addDisposableStackMethod(self: *Object, rt: *JSRuntime, method_id: u8) !bool`。
- **作用**：尝试登记 disposable_stack_method，拒绝覆盖不同的既有非空值。
- **实现**：method_id 为 0 则直接 true；否则 ensure rare payload 后委托 setDisposableStackMethod。
- **所有权 / 错误 / 调用**：空输入是无操作，不清旧值。ensure 可失败；冲突返回 false 并保留原字段，不校验标记是否适合实际函数体。

### `Object.addAsyncDisposableStackMethod` (`src/core/object.zig:5462`)

- **签名**：`pub fn addAsyncDisposableStackMethod(self: *Object, rt: *JSRuntime, method_id: u8) !bool`。
- **作用**：尝试登记 async_disposable_stack_method，拒绝覆盖不同的既有非空值。
- **实现**：method_id 为 0 则直接 true；否则 ensure rare payload 后委托 setAsyncDisposableStackMethod。
- **所有权 / 错误 / 调用**：空输入是无操作，不清旧值。ensure 可失败；冲突返回 false 并保留原字段，不校验标记是否适合实际函数体。

### `Object.addCollectionMethodOwnerClass` (`src/core/object.zig:5468`)

- **签名**：`pub fn addCollectionMethodOwnerClass(self: *Object, rt: *JSRuntime, owner_class: class.ClassId) !bool`。
- **作用**：尝试登记 collection_method_owner_class，拒绝覆盖不同的既有非空值。
- **实现**：owner_class 为 class.invalid_class_id 则直接 true；否则 ensure rare payload 后委托 setCollectionMethodOwnerClass。
- **所有权 / 错误 / 调用**：空输入是无操作，不清旧值。ensure 可失败；冲突返回 false 并保留原字段，不校验标记是否适合实际函数体。

### `Object.setArrayBuiltinMarker` (`src/core/object.zig:5474`)

- **签名**：`fn setArrayBuiltinMarker(payload: *FunctionRarePayload, marker: ArrayBuiltinMarker) bool`。
- **作用**：在既有 rare payload 上设置 array_builtin_marker。
- **实现**：旧字段非 .none 且与 marker 不同则 false；否则赋值并 true。
- **所有权 / 错误 / 调用**：不分配，空输入也按同一冲突规则比较；该私有 helper 与 add 包装的空输入无操作语义不同。

### `Object.setTypedArrayBuiltinMarker` (`src/core/object.zig:5480`)

- **签名**：`fn setTypedArrayBuiltinMarker(payload: *FunctionRarePayload, marker: TypedArrayBuiltinMarker) bool`。
- **作用**：在既有 rare payload 上设置 typed_array_builtin_marker。
- **实现**：旧字段非 .none 且与 marker 不同则 false；否则赋值并 true。
- **所有权 / 错误 / 调用**：不分配，空输入也按同一冲突规则比较；该私有 helper 与 add 包装的空输入无操作语义不同。

### `Object.setArrayIteratorKind` (`src/core/object.zig:5486`)

- **签名**：`fn setArrayIteratorKind(payload: *FunctionRarePayload, kind: u8) bool`。
- **作用**：设置 rare payload 的 array_iterator_kind。
- **实现**：旧字段非零且不等于 kind 则 false，否则写 kind 并 true。
- **所有权 / 错误 / 调用**：不分配，不校验 kind 的枚举域；既有非零字段不能用零清除。

### `Object.setDisposableStackMethod` (`src/core/object.zig:5492`)

- **签名**：`fn setDisposableStackMethod(payload: *FunctionRarePayload, method_id: u8) bool`。
- **作用**：在既有 rare payload 上设置 disposable_stack_method。
- **实现**：旧字段非 0 且与 method_id 不同则 false；否则赋值并 true。
- **所有权 / 错误 / 调用**：不分配，空输入也按同一冲突规则比较；该私有 helper 与 add 包装的空输入无操作语义不同。

### `Object.setAsyncDisposableStackMethod` (`src/core/object.zig:5498`)

- **签名**：`fn setAsyncDisposableStackMethod(payload: *FunctionRarePayload, method_id: u8) bool`。
- **作用**：在既有 rare payload 上设置 async_disposable_stack_method。
- **实现**：旧字段非 0 且与 method_id 不同则 false；否则赋值并 true。
- **所有权 / 错误 / 调用**：不分配，空输入也按同一冲突规则比较；该私有 helper 与 add 包装的空输入无操作语义不同。

### `Object.setCollectionMethodOwnerClass` (`src/core/object.zig:5504`)

- **签名**：`fn setCollectionMethodOwnerClass(payload: *FunctionRarePayload, owner_class: class.ClassId) bool`。
- **作用**：在既有 rare payload 上设置 collection_method_owner_class。
- **实现**：旧字段非 class.invalid_class_id 且与 owner_class 不同则 false；否则赋值并 true。
- **所有权 / 错误 / 调用**：不分配，空输入也按同一冲突规则比较；该私有 helper 与 add 包装的空输入无操作语义不同。

### `Object.collectionMethodOwnerClass` (`src/core/object.zig:5510`)

- **签名**：`pub fn collectionMethodOwnerClass(self: *const Object) class.ClassId`。
- **作用**：查询 function rare payload 的 collection_method_owner_class。
- **实现**：有 functionRarePayloadConst 返回字段，否则 class.invalid_class_id。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 返回 `class.invalid_class_id`（不是 0），调用方以此当「没记过 owner」。调用方：`exec/call_runtime.zig:799`、`exec/collection_ops.zig:2251`、`exec/array_ops.zig:1428`；写入端 `setCollectionMethodOwnerClass` 只允许记一次，冲突返回 false。

### `Object.setFunctionBytecodeValue` (`src/core/object.zig:5515`)

- **签名**：`pub fn setFunctionBytecodeValue(self: *Object, rt: *JSRuntime, next_value: JSValue) !void`。
- **作用**：将 FunctionBytecode 安装到字节码函数对象。
- **实现**：输入不是 FunctionBytecode 值或取不到 header 则 InvalidBytecode；断言接收者 class 和 header kind，转换为 FunctionBytecode 指针，写入 arm 并执行 owner 到 fb 的屏障。
- **所有权 / 错误 / 调用**：不分配、不复制执行记录，也不校验完整字节码内容；当前没有 RC 消耗/释放操作。替换 fb 时不会调整已有 capture 表，调用方必须维持其长度合同。

### `Object.bytecodeFunctionStoragePtr` (`src/core/object.zig:5534`)

- **签名**：`pub inline fn bytecodeFunctionStoragePtr(self: *Object) *BytecodeFunctionStorage`。
- **作用**：借用字节码函数的 inline storage arm。
- **实现**：断言字节码函数 class 与 function payload kind，返回 bytecodeArm 地址。
- **所有权 / 错误 / 调用**：不分配或验证 fb/captures 已就绪；返回可变借用，裸写不自动维护屏障或 tagged-pointer 合同。

### `Object.bytecodeFunctionStoragePtrConst` (`src/core/object.zig:5540`)

- **签名**：`pub inline fn bytecodeFunctionStoragePtrConst(self: *const Object) *const BytecodeFunctionStorage`。
- **作用**：借用字节码函数的 inline storage arm。
- **实现**：断言字节码函数 class 与 function payload kind，返回 bytecodeArm 地址。
- **所有权 / 错误 / 调用**：不分配或验证 fb/captures 已就绪；返回只读借用。

### `Object.functionBytecode` (`src/core/object.zig:5546`)

- **签名**：`pub fn functionBytecode(self: *const Object) ?JSValue`。
- **作用**：查询字节码函数对象持有的 FunctionBytecode 值。
- **实现**：非字节码函数 class 或 arm 中 fb 为空则 null，否则用 fb.header 构造对应 JSValue。
- **所有权 / 错误 / 调用**：不为 generator 派生 current function，不复制或建立 GC 根。

### `Object.generatorFunctionBytecode` (`src/core/object.zig:5556`)

- **签名**：`pub fn generatorFunctionBytecode(self: *const Object) ?JSValue`。
- **作用**：从 generator 保存的 current function 推导字节码。
- **实现**：无 current 则 null；current 已是 FunctionBytecode 直接返回；否则 Object.expect 失败或 current_object==self 则 null，最后查询 current_object.functionBytecode()。
- **所有权 / 错误 / 调用**：只解析这一层，不递归解包 bound/proxy 等 callable；不分配或创建 execution。

### `Object.generatorFunctionRealmGlobalPtr` (`src/core/object.zig:5569`)

- **签名**：`pub fn generatorFunctionRealmGlobalPtr(self: *const Object) ?*Object`。
- **作用**：从 generator 当前字节码的 realm 查询 global。
- **实现**：依次 generatorFunctionBytecode、functionBytecodeFromValue、realmContext，任一步缺失返回 null，最后返回 realm.global。
- **所有权 / 错误 / 调用**：不直接检查 done；运行别名仍保留 execution 的 pending-completion 阶段仍可能得到 global。只有执行记录已释放等导致当前函数不可取得时才随之返回 null。

### `Object.functionProxyRevokeTargetSlot` (`src/core/object.zig:5576`)

- **签名**：`pub fn functionProxyRevokeTargetSlot(self: *Object, rt: *JSRuntime) !*?JSValue`。
- **作用**：借出 revoke 闭包里那个「被撤销的 Proxy」捕获槽——`Proxy.revocable()` 返回的 `revoke` 函数把目标存在这里。
- **实现**：`ensureFunctionRarePayload` 的两条臂：bytecode class 首次调用时 `createPayloadCell(BytecodeFunctionAux)` 建 a 类 payload cell、把原 `home_or_aux` 里的 home object 搬进 `aux.home_object` 再打上 tag，并 `rememberOwnerForBulkWrite` 记下这条新边；native class 则 `rt.createRuntime(FunctionRarePayload)` 零初始化后挂到 `payload.rare`。没有 function payload 的对象返回 `error.TypeError`；拿到 payload 后返回 `&payload.proxy_revoke_target` 这个 `*?JSValue`。写入方 `reflect_ops` 建 revoke 函数时用 `setOptionalValueSlot` 经此槽存 proxy；`revokeProxy` 反过来用 `takeOptionalValueSlot` 取走并清空，因此第二次 revoke 拿到 null 直接返回 undefined，正是「revoke 幂等」的实现处。
- **所有权 / 错误 / 调用**：`ensureFunctionRarePayload` 会分配：bytecode 臂首次调用铸一枚 `BytecodeFunctionAux` 的 `.payload` GC cell（由 sweep 回收，`rememberOwnerForBulkWrite` 补上新边），native 臂 `rt.createRuntime(FunctionRarePayload)` 挂进 `FunctionPayload.rare`、由 `destroyFunctionPayload` 释放；error set = 分配 OOM + 非函数对象的 `error.TypeError`，沿 `try` 上抛后在 builtin 边界由 `materializeRuntimeError` 变成 JS 异常。rare payload 建好后不再搬移，返回的槽指针在对象存活期内有效。槽本身是 GC 边（`FunctionRarePayload.traceChildEdges` 的 `proxy_revoke_target`），直接 `slot.* =` 不跑分代屏障，所以 `exec/reflect_ops.zig:297` 用 `setOptionalValueSlot` 写入、`:307` 再取走清空。

### `Object.functionPromiseCapabilitySlot` (`src/core/object.zig:5580`)

- **签名**：`pub fn functionPromiseCapabilitySlot(self: *const Object) ?JSValue`。
- **作用**：读出 GetCapabilitiesExecutor（`new Promise(executor)` 内部那个收集 resolve/reject 的执行器）捕获的 capability 记录对象。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.promise_capability_slot`，无 payload 时 null。`call.zig` 的 `promiseCapabilityExecutorCall` 以它作守卫：null 返回 null（不是执行器）；非 null 则取出 capability 对象，若其 resolve/reject 已被填过就抛 `TypeError`（规范的「executor 只能被调一次」），否则把两个实参写进去。
- **所有权 / 错误 / 调用**：不分配、不执行 Promise/异步算法或建立根；functionPromiseCapabilitySlot 虽以 Slot 命名，返回的是 optional 值而非字段地址。

### `Object.functionPromiseResolvingTarget` (`src/core/object.zig:5585`)

- **签名**：`pub fn functionPromiseResolvingTarget(self: *const Object) ?JSValue`。
- **作用**：读出一对 resolve/reject 函数所捕获的目标 Promise，是 CreateResolvingFunctions 产物的身份标记。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.promise_resolving_target`，无 payload 时 null。写入点在 `core/promise.zig` 的 `createResolvingFunction`（连同 `.promise_resolving` 内部可调用标签一起装配）。调用侧先用它判身份：null 即非 resolving 函数，返回 null；非 null 但目标 `class_id != promise` 则按规范静默返回 undefined。
- **所有权 / 错误 / 调用**：无分配、无 error set；返回的是 rare payload 借用的 `?JSValue`，存活靠 payload 的 trace 边，调用方不释放。调用方：`core/promise.zig:199`（null → `error.TypeError`）、`exec/call.zig:402` 与 `exec/promise_ops.zig:922`（null 当「不是 resolving 函数」返回 null）。

### `Object.functionPromiseResolvingState` (`src/core/object.zig:5590`)

- **签名**：`pub fn functionPromiseResolvingState(self: *const Object) ?JSValue`。
- **作用**：读出 resolve/reject 这一对函数共享的 `alreadyResolved` 状态对象——两者共用同一个记录，所以先调用的那个能把后调用的那个变成 no-op。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.promise_resolving_state`，无 payload 时 null。这个状态是 `createResolvingFunction` 建的一个普通对象，其 `promiseAlreadyResolvedSlot` 初始为 false。`promise_ops` 的 resolving 调用把它和目标 promise 一起交给 `resolvePromiseWithState`；已确认是 resolving 函数却取不到 state 时抛 `TypeError`（内部不变量被破坏）。
- **所有权 / 错误 / 调用**：无分配、无 error set；返回的是 rare payload 借用的 `?JSValue`，存活靠 payload 的 trace 边，调用方不释放。生产调用方 `core/promise.zig:201` 与 `exec/promise_ops.zig:925` 都把 null 直接变 `error.TypeError`——resolving 函数一定同时有 target 和 state，缺一即内部不变量被破坏；`exec/promise_ops.zig:1299` 在测试块里用 `.?` 直接解包。

### `Object.functionPromiseResolvingRejectSlot` (`src/core/object.zig:5595`)

- **签名**：`pub fn functionPromiseResolvingRejectSlot(self: *Object, rt: *JSRuntime) !*bool`。
- **作用**：借出「这个函数是 reject 而不是 resolve」的方向位——同一对函数只靠这一个 bool 区分。
- **实现**：`ensureFunctionRarePayload` 的两条臂：bytecode class 首次调用时 `createPayloadCell(BytecodeFunctionAux)` 建 a 类 payload cell、把原 `home_or_aux` 里的 home object 搬进 `aux.home_object` 再打上 tag，并 `rememberOwnerForBulkWrite` 记下这条新边；native class 则 `rt.createRuntime(FunctionRarePayload)` 零初始化后挂到 `payload.rare`。没有 function payload 的对象返回 `error.TypeError`；随后返回 `&payload.promise_resolving_reject`。`createResolvingFunction` 按参数一次写死；`call.zig` 造 `Promise.withResolvers` 那对函数时则显式写 false / true 各一次。
- **所有权 / 错误 / 调用**：`ensureFunctionRarePayload` 会分配：bytecode 臂首次调用铸一枚 `BytecodeFunctionAux` 的 `.payload` GC cell（由 sweep 回收，`rememberOwnerForBulkWrite` 补上新边），native 臂 `rt.createRuntime(FunctionRarePayload)` 挂进 `FunctionPayload.rare`、由 `destroyFunctionPayload` 释放；error set = 分配 OOM + 非函数对象的 `error.TypeError`，沿 `try` 上抛后在 builtin 边界由 `materializeRuntimeError` 变成 JS 异常。rare payload 建好后不再搬移，返回的槽指针在对象存活期内有效。标量槽不是 GC 边，调用方直接 `.* =` 即可，无屏障义务。调用方：`core/promise.zig:177`、`exec/promise_ops.zig:348`、`exec/call.zig:544`/`:547`（建 resolve/reject 对时各写一次）。

### `Object.functionPromiseResolvingReject` (`src/core/object.zig:5599`)

- **签名**：`pub fn functionPromiseResolvingReject(self: *const Object) bool`。
- **作用**：读出上述方向位，决定这次调用是兑现还是拒绝目标 Promise。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.promise_resolving_reject`，无 payload 时 false。`call.zig` 的快路径直接把它写进目标的 `promiseIsRejectedSlot`；完整路径把它当作 `resolvePromiseWithState` 的 `reject` 实参。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 返回 false，即默认按 resolve 臂处理。调用方 `exec/call.zig:406`、`exec/promise_ops.zig:934`。

### `Object.functionPromiseCombinatorState` (`src/core/object.zig:5604`)

- **签名**：`pub fn functionPromiseCombinatorState(self: *const Object) ?JSValue`。
- **作用**：读出 `Promise.all` / `allSettled` / `any` 为每个元素生成的回调所共享的聚合状态对象（存放结果数组、剩余计数、capability）。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.promise_combinator_state`，无 payload 时 null。状态由 `promise_ops.promiseCombinatorState`（keyed 变体再补一个 keys 数组）建出，元素回调在 `promiseCombinatorCallback` 里经 `setFunctionPromiseCombinatorState` 挂上。分发时取不到 state 就抛 `TypeError`——此时 mode 已非 0，缺 state 属内部不变量破坏。
- **所有权 / 错误 / 调用**：无分配、无 error set；返回的是 rare payload 借用的 `?JSValue`，存活靠 payload 的 trace 边，调用方不释放。调用方 `exec/promise_ops.zig:1762`、`exec/call.zig:455`，两处都把 null 变 `error.TypeError`。

### `Object.functionPromiseCombinatorModeSlot` (`src/core/object.zig:5609`)

- **签名**：`pub fn functionPromiseCombinatorModeSlot(self: *Object, rt: *JSRuntime) !*u8`。
- **作用**：借出组合子元素回调的模式位，`promiseCombinatorCallback` 在造回调时写入。
- **实现**：`ensureFunctionRarePayload` 的两条臂：bytecode class 首次调用时 `createPayloadCell(BytecodeFunctionAux)` 建 a 类 payload cell、把原 `home_or_aux` 里的 home object 搬进 `aux.home_object` 再打上 tag，并 `rememberOwnerForBulkWrite` 记下这条新边；native class 则 `rt.createRuntime(FunctionRarePayload)` 零初始化后挂到 `payload.rare`。没有 function payload 的对象返回 `error.TypeError`；返回 `&payload.promise_combinator_mode`。写入的是 `PromiseCombinatorCallbackMode` 的 `@intFromEnum`，与同一函数里写的 state / index / called 三个槽构成这个回调的全部捕获状态。
- **所有权 / 错误 / 调用**：`ensureFunctionRarePayload` 会分配：bytecode 臂首次调用铸一枚 `BytecodeFunctionAux` 的 `.payload` GC cell（由 sweep 回收，`rememberOwnerForBulkWrite` 补上新边），native 臂 `rt.createRuntime(FunctionRarePayload)` 挂进 `FunctionPayload.rare`、由 `destroyFunctionPayload` 释放；error set = 分配 OOM + 非函数对象的 `error.TypeError`，沿 `try` 上抛后在 builtin 边界由 `materializeRuntimeError` 变成 JS 异常。rare payload 建好后不再搬移，返回的槽指针在对象存活期内有效。标量槽不是 GC 边，调用方直接 `.* =` 即可，无屏障义务。树内唯一调用方 `exec/promise_ops.zig:2052`，在建 combinator 回调时写入 `@intFromEnum(mode)`。

### `Object.functionPromiseCombinatorMode` (`src/core/object.zig:5613`)

- **签名**：`pub fn functionPromiseCombinatorMode(self: *const Object) u8`。
- **作用**：读出元素回调属于哪一种组合子语义，决定这次结算往结果数组里写什么。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.promise_combinator_mode`，无 payload 时 0。分发端按 `PromiseCombinatorCallbackMode` 解码：1=`all` 的 resolve、2/3=`allSettled` 的 fulfill/reject（要额外造一条 `{status,value|reason}` 记录）、4=`any` 的 reject；0 表示「不是组合子回调」返回 null，其他值抛 `TypeError`。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 返回 0。调用方 `exec/promise_ops.zig:1747`、`exec/call.zig:444`，据此 switch 出 all/allSettled/any 的回调语义。

### `Object.functionPromiseCombinatorIndexSlot` (`src/core/object.zig:5618`)

- **签名**：`pub fn functionPromiseCombinatorIndexSlot(self: *Object, rt: *JSRuntime) !*u32`。
- **作用**：借出该元素回调在结果数组中的下标槽。
- **实现**：`ensureFunctionRarePayload` 的两条臂：bytecode class 首次调用时 `createPayloadCell(BytecodeFunctionAux)` 建 a 类 payload cell、把原 `home_or_aux` 里的 home object 搬进 `aux.home_object` 再打上 tag，并 `rememberOwnerForBulkWrite` 记下这条新边；native class 则 `rt.createRuntime(FunctionRarePayload)` 零初始化后挂到 `payload.rare`。没有 function payload 的对象返回 `error.TypeError`；返回 `&payload.promise_combinator_index`（u32）。由 `promiseCombinatorCallback` 在迭代输入 iterable 时按序写入，之后不再改动。
- **所有权 / 错误 / 调用**：`ensureFunctionRarePayload` 会分配：bytecode 臂首次调用铸一枚 `BytecodeFunctionAux` 的 `.payload` GC cell（由 sweep 回收，`rememberOwnerForBulkWrite` 补上新边），native 臂 `rt.createRuntime(FunctionRarePayload)` 挂进 `FunctionPayload.rare`、由 `destroyFunctionPayload` 释放；error set = 分配 OOM + 非函数对象的 `error.TypeError`，沿 `try` 上抛后在 builtin 边界由 `materializeRuntimeError` 变成 JS 异常。rare payload 建好后不再搬移，返回的槽指针在对象存活期内有效。标量槽不是 GC 边，调用方直接 `.* =` 即可，无屏障义务。树内唯一调用方 `exec/promise_ops.zig:2054`。

### `Object.functionPromiseCombinatorIndex` (`src/core/object.zig:5622`)

- **签名**：`pub fn functionPromiseCombinatorIndex(self: *const Object) u32`。
- **作用**：读出该回调负责的结果槽下标，保证并发完成的元素仍按输入顺序落位。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.promise_combinator_index`，无 payload 时 0。分发端把它直接交给 `setArrayIndex` 写进 state 里的结果数组——注意 0 既是「第一个元素」也是默认值，所以本值只在 mode 已确认非 0 之后才被读取。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 返回 0，与「第 0 个元素」同形，因此只在已确认是 combinator 回调后才读。调用方 `exec/promise_ops.zig:1767`、`exec/call.zig:459`。

### `Object.functionPromiseCombinatorCalledSlot` (`src/core/object.zig:5627`)

- **签名**：`pub fn functionPromiseCombinatorCalledSlot(self: *Object, rt: *JSRuntime) !*bool`。
- **作用**：借出该元素回调的「已被调用过」一次性闸门位。
- **实现**：`ensureFunctionRarePayload` 的两条臂：bytecode class 首次调用时 `createPayloadCell(BytecodeFunctionAux)` 建 a 类 payload cell、把原 `home_or_aux` 里的 home object 搬进 `aux.home_object` 再打上 tag，并 `rememberOwnerForBulkWrite` 记下这条新边；native class 则 `rt.createRuntime(FunctionRarePayload)` 零初始化后挂到 `payload.rare`。没有 function payload 的对象返回 `error.TypeError`；返回 `&payload.promise_combinator_called`。`promiseCombinatorCallback` 建回调时显式写 false（不依赖 `FunctionRarePayload` 的默认值），分发端首次进入时写 true。
- **所有权 / 错误 / 调用**：`ensureFunctionRarePayload` 会分配：bytecode 臂首次调用铸一枚 `BytecodeFunctionAux` 的 `.payload` GC cell（由 sweep 回收，`rememberOwnerForBulkWrite` 补上新边），native 臂 `rt.createRuntime(FunctionRarePayload)` 挂进 `FunctionPayload.rare`、由 `destroyFunctionPayload` 释放；error set = 分配 OOM + 非函数对象的 `error.TypeError`，沿 `try` 上抛后在 builtin 边界由 `materializeRuntimeError` 变成 JS 异常。rare payload 建好后不再搬移，返回的槽指针在对象存活期内有效。标量槽不是 GC 边，调用方直接 `.* =` 即可，无屏障义务。调用方：`exec/promise_ops.zig:2055`（建回调时置 false）、`exec/promise_ops.zig:1760` 与 `exec/call.zig:453`（首次进入时置 true，实现 already-called 幂等）。

### `Object.functionPromiseCombinatorCalled` (`src/core/object.zig:5631`)

- **签名**：`pub fn functionPromiseCombinatorCalled(self: *const Object) bool`。
- **作用**：读出上述闸门位，实现规范里「同一个 resolve 元素函数只生效一次」的要求（thenable 可以重复回调）。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.promise_combinator_called`，无 payload 时 false。分发端在解出 mode 之后、动状态之前检查：已 true 就直接返回 undefined，否则立刻置 true 再继续写结果数组与递减计数。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 返回 false。调用方 `exec/promise_ops.zig:1759`、`exec/call.zig:452`：为 true 就直接返回 undefined，是 already-called 早退。

### `Object.functionPromiseFinallyPayload` (`src/core/object.zig:5636`)

- **签名**：`pub fn functionPromiseFinallyPayload(self: *const Object) ?JSValue`。
- **作用**：读出 `Promise.prototype.finally` 续跑闭包捕获的值——`.return_value` 模式下是要原样返回的兑现值，`.throw_reason` 模式下是要重新抛出的拒因。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.promise_finally_payload`，无 payload 时 null。`promiseFinallyCallback` 只在传入非 null 时才经 `setFunctionPromiseFinallyPayload` 写入；分发端在 `.return_value` / `.throw_reason` 两个分支里取不到就抛 `TypeError`，`.throw_reason` 取到后 `ctx.throwValue(payload)` 并返回 `error.JSException`。
- **所有权 / 错误 / 调用**：无分配、无 error set；返回的是 rare payload 借用的 `?JSValue`，存活靠 payload 的 trace 边，调用方不释放。调用方 `exec/promise_ops.zig:3524`、`:3551`、`:3555`，null 一律 `error.TypeError`。

### `Object.functionPromiseFinallyCallback` (`src/core/object.zig:5641`)

- **签名**：`pub fn functionPromiseFinallyCallback(self: *const Object) ?JSValue`。
- **作用**：读出 `finally(onFinally)` 里用户传进来的那个回调，供 fulfill/reject 两个包装闭包在转发结果前先调用它。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.promise_finally_callback`，无 payload 时 null。只有 `.fulfill` / `.reject` 两种模式的闭包会带这个槽；分发端取不到即抛 `TypeError`，取到后以 undefined 作 this、零实参调用，再把结果喂给 `Promise.resolve`。
- **所有权 / 错误 / 调用**：无分配、无 error set；返回的是 rare payload 借用的 `?JSValue`，存活靠 payload 的 trace 边，调用方不释放。树内唯一调用方 `exec/promise_ops.zig:3561`（null → `error.TypeError`）。

### `Object.functionPromiseFinallyConstructor` (`src/core/object.zig:5646`)

- **签名**：`pub fn functionPromiseFinallyConstructor(self: *const Object) ?JSValue`。
- **作用**：读出 `finally` 捕获的构造器（SpeciesConstructor 的结果），用来把 `onFinally` 的返回值包成 promise，从而实现「thenable 会被等待」的语义。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.promise_finally_constructor`，无 payload 时 null。与 callback 槽一样只出现在 `.fulfill` / `.reject` 闭包上；分发端取到后交给 `promiseStaticCall(..., .resolve, ...)`，随后再造一个 `.return_value` 或 `.throw_reason` 的续跑闭包接在它后面。
- **所有权 / 错误 / 调用**：无分配、无 error set；返回的是 rare payload 借用的 `?JSValue`，存活靠 payload 的 trace 边，调用方不释放。树内唯一调用方 `exec/promise_ops.zig:3562`（null → `error.TypeError`）。

### `Object.functionPromiseFinallyModeSlot` (`src/core/object.zig:5651`)

- **签名**：`pub fn functionPromiseFinallyModeSlot(self: *Object, rt: *JSRuntime) !*u8`。
- **作用**：借出 finally 闭包的模式位，`promiseFinallyCallback` 造闭包时第一件事就是写它。
- **实现**：`ensureFunctionRarePayload` 的两条臂：bytecode class 首次调用时 `createPayloadCell(BytecodeFunctionAux)` 建 a 类 payload cell、把原 `home_or_aux` 里的 home object 搬进 `aux.home_object` 再打上 tag，并 `rememberOwnerForBulkWrite` 记下这条新边；native class 则 `rt.createRuntime(FunctionRarePayload)` 零初始化后挂到 `payload.rare`。没有 function payload 的对象返回 `error.TypeError`；返回 `&payload.promise_finally_mode`，写入的是 `PromiseFinallyCallbackMode` 的 `@intFromEnum`。同一个工厂函数按模式决定闭包的 `length`（`.fulfill`/`.reject` 为 1，其余为 0）并选择性写入 payload/callback/constructor 三个槽。
- **所有权 / 错误 / 调用**：`ensureFunctionRarePayload` 会分配：bytecode 臂首次调用铸一枚 `BytecodeFunctionAux` 的 `.payload` GC cell（由 sweep 回收，`rememberOwnerForBulkWrite` 补上新边），native 臂 `rt.createRuntime(FunctionRarePayload)` 挂进 `FunctionPayload.rare`、由 `destroyFunctionPayload` 释放；error set = 分配 OOM + 非函数对象的 `error.TypeError`，沿 `try` 上抛后在 builtin 边界由 `materializeRuntimeError` 变成 JS 异常。rare payload 建好后不再搬移，返回的槽指针在对象存活期内有效。标量槽不是 GC 边，调用方直接 `.* =` 即可，无屏障义务。树内唯一调用方 `exec/promise_ops.zig:3493`。

### `Object.functionPromiseFinallyMode` (`src/core/object.zig:5655`)

- **签名**：`pub fn functionPromiseFinallyMode(self: *const Object) u8`。
- **作用**：读出这是四种 finally 闭包中的哪一种，决定本次调用是「先跑 onFinally」还是「直接还原原始结果」。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.promise_finally_mode`，无 payload 时 0。分发端按 `PromiseFinallyCallbackMode` 解码：1=`fulfill`、2=`reject`、3=`return_value`、4=`throw_reason`；0 返回 null（不是 finally 闭包），其他值抛 `TypeError`。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 返回 0。树内唯一调用方 `exec/promise_ops.zig:3540`，switch 成 `PromiseFinallyCallbackMode`。

### `Object.functionAsyncDisposeStackSlot` (`src/core/object.zig:5660`)

- **签名**：`pub fn functionAsyncDisposeStackSlot(self: *Object, rt: *JSRuntime) !*?JSValue`。
- **作用**：借出 `AsyncDisposableStack` 处置续跑闭包所捕获的栈对象槽。
- **实现**：`ensureFunctionRarePayload` 的两条臂：bytecode class 首次调用时 `createPayloadCell(BytecodeFunctionAux)` 建 a 类 payload cell、把原 `home_or_aux` 里的 home object 搬进 `aux.home_object` 再打上 tag，并 `rememberOwnerForBulkWrite` 记下这条新边；native class 则 `rt.createRuntime(FunctionRarePayload)` 零初始化后挂到 `payload.rare`。没有 function payload 的对象返回 `error.TypeError`；返回 `&payload.async_dispose_stack`（`*?JSValue`）。`disposable_ops.asyncDisposableStackContinuation` 用 `setOptionalValueSlot` 经此槽存入 stack，同时写 `.async_disposable_stack_continuation` 内部可调用标签和 rejected 方向位。
- **所有权 / 错误 / 调用**：`ensureFunctionRarePayload` 会分配：bytecode 臂首次调用铸一枚 `BytecodeFunctionAux` 的 `.payload` GC cell（由 sweep 回收，`rememberOwnerForBulkWrite` 补上新边），native 臂 `rt.createRuntime(FunctionRarePayload)` 挂进 `FunctionPayload.rare`、由 `destroyFunctionPayload` 释放；error set = 分配 OOM + 非函数对象的 `error.TypeError`，沿 `try` 上抛后在 builtin 边界由 `materializeRuntimeError` 变成 JS 异常。rare payload 建好后不再搬移，返回的槽指针在对象存活期内有效。槽是 GC 边（`async_dispose_stack`），直接写不跑分代屏障，唯一调用方 `exec/disposable_ops.zig:542` 因此走 `setOptionalValueSlot`。

### `Object.functionAsyncDisposeStack` (`src/core/object.zig:5664`)

- **签名**：`pub fn functionAsyncDisposeStack(self: *const Object) ?JSValue`。
- **作用**：读出上述被捕获的 `AsyncDisposableStack`，每 await 完一个处置器就靠它回到同一个栈继续处置下一个。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.async_dispose_stack`，无 payload 时 null。`asyncDisposableStackContinuationCall` 以它作守卫：null 返回 null；非 null 但 `class_id != async_disposable_stack` 抛 `TypeError`；通过后调 `asyncDisposableStackContinueOrReject` 继续排空。
- **所有权 / 错误 / 调用**：无分配、无 error set；返回的是 rare payload 借用的 `?JSValue`，存活靠 payload 的 trace 边，调用方不释放。树内唯一调用方 `exec/disposable_ops.zig:556`，null 当「不是这个闭包」返回 null 而不是报错。

### `Object.functionAsyncDisposeRejectedSlot` (`src/core/object.zig:5669`)

- **签名**：`pub fn functionAsyncDisposeRejectedSlot(self: *Object, rt: *JSRuntime) !*bool`。
- **作用**：借出续跑闭包的方向位槽——同一个 stack 会配一对闭包，分别挂在 await 的 onFulfilled 与 onRejected 上。
- **实现**：`ensureFunctionRarePayload` 的两条臂：bytecode class 首次调用时 `createPayloadCell(BytecodeFunctionAux)` 建 a 类 payload cell、把原 `home_or_aux` 里的 home object 搬进 `aux.home_object` 再打上 tag，并 `rememberOwnerForBulkWrite` 记下这条新边；native class 则 `rt.createRuntime(FunctionRarePayload)` 零初始化后挂到 `payload.rare`。没有 function payload 的对象返回 `error.TypeError`；返回 `&payload.async_dispose_rejected`，由 `asyncDisposableStackContinuation` 的 `rejected` 参数一次写定。
- **所有权 / 错误 / 调用**：`ensureFunctionRarePayload` 会分配：bytecode 臂首次调用铸一枚 `BytecodeFunctionAux` 的 `.payload` GC cell（由 sweep 回收，`rememberOwnerForBulkWrite` 补上新边），native 臂 `rt.createRuntime(FunctionRarePayload)` 挂进 `FunctionPayload.rare`、由 `destroyFunctionPayload` 释放；error set = 分配 OOM + 非函数对象的 `error.TypeError`，沿 `try` 上抛后在 builtin 边界由 `materializeRuntimeError` 变成 JS 异常。rare payload 建好后不再搬移，返回的槽指针在对象存活期内有效。标量槽不是 GC 边，调用方直接 `.* =` 即可，无屏障义务。树内唯一调用方 `exec/disposable_ops.zig:543`，与上一行的 stack 槽成对写入。

### `Object.functionAsyncDisposeRejected` (`src/core/object.zig:5673`)

- **签名**：`pub fn functionAsyncDisposeRejected(self: *const Object) bool`。
- **作用**：读出方向位，决定这次续跑是正常继续还是要把 await 到的拒因并入处置错误。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.async_dispose_rejected`，无 payload 时 false。分发端据此构造 `rejection`：为真时取首个实参（缺省 undefined）作拒因，为假则传 null 表示无异常，再交给 `asyncDisposableStackContinueOrReject`。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 返回 false。树内唯一调用方 `exec/disposable_ops.zig:559`，与上面的 stack 一起读。

### `Object.functionAsyncContinuationSlot` (`src/core/object.zig:5678`)

- **签名**：`pub fn functionAsyncContinuationSlot(self: *Object, rt: *JSRuntime) !*?JSValue`。
- **作用**：借出异步续跑闭包的捕获槽，存的是「await 完成后要回到谁」——异步生成器对象，或 async-from-sync 包装里的同步迭代器。
- **实现**：`ensureFunctionRarePayload` 的两条臂：bytecode class 首次调用时 `createPayloadCell(BytecodeFunctionAux)` 建 a 类 payload cell、把原 `home_or_aux` 里的 home object 搬进 `aux.home_object` 再打上 tag，并 `rememberOwnerForBulkWrite` 记下这条新边；native class 则 `rt.createRuntime(FunctionRarePayload)` 零初始化后挂到 `payload.rare`。没有 function payload 的对象返回 `error.TypeError`；返回 `&payload.async_function_continuation`（`*?JSValue`）。两处写入方：`async_generator.resolveFunction` 存 generator 对象（同时写 rejected 位与 action 码），`promise_ops.asyncFromSyncIteratorCloseWrap` 存同步迭代器（配 `.async_from_sync_iterator_close_wrap` 标签）。
- **所有权 / 错误 / 调用**：`ensureFunctionRarePayload` 会分配：bytecode 臂首次调用铸一枚 `BytecodeFunctionAux` 的 `.payload` GC cell（由 sweep 回收，`rememberOwnerForBulkWrite` 补上新边），native 臂 `rt.createRuntime(FunctionRarePayload)` 挂进 `FunctionPayload.rare`、由 `destroyFunctionPayload` 释放；error set = 分配 OOM + 非函数对象的 `error.TypeError`，沿 `try` 上抛后在 builtin 边界由 `materializeRuntimeError` 变成 JS 异常。rare payload 建好后不再搬移，返回的槽指针在对象存活期内有效。槽是 GC 边（`async_function_continuation`），直接写不跑分代屏障；生产调用方 `exec/async_generator.zig:183` 与 `exec/promise_ops.zig:3294` 都经 `setOptionalValueSlot` 写入（`src/tests/core.zig:10519` 是测试里的直写）。

### `Object.functionAsyncContinuation` (`src/core/object.zig:5682`)

- **签名**：`pub fn functionAsyncContinuation(self: *const Object) ?JSValue`。
- **作用**：读出上述续跑目标，是这类内部闭包的身份标记兼捕获数据。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.async_function_continuation`，无 payload 时 null。`async_generator.asyncGeneratorResolveFunctionCall` 以它作守卫：null 返回 null 表示不是这类闭包；非 null 则转成 generator 对象（失败抛 `TypeError`），再连同 rejected 位与 action 码一起决定怎么恢复协程。
- **所有权 / 错误 / 调用**：无分配、无 error set；返回的是 rare payload 借用的 `?JSValue`，存活靠 payload 的 trace 边，调用方不释放。调用方 `exec/promise_ops.zig:3305`、`exec/async_generator.zig:509`，null 都表示「不是续跑闭包」，返回 null 退回通用路径。

### `Object.functionAsyncContinuationRejectedSlot` (`src/core/object.zig:5687`)

- **签名**：`pub fn functionAsyncContinuationRejectedSlot(self: *Object, rt: *JSRuntime) !*bool`。
- **作用**：借出续跑闭包的方向位槽——同一个 action 会造正反两个闭包，分别接到 await 的兑现与拒绝侧。
- **实现**：`ensureFunctionRarePayload` 的两条臂：bytecode class 首次调用时 `createPayloadCell(BytecodeFunctionAux)` 建 a 类 payload cell、把原 `home_or_aux` 里的 home object 搬进 `aux.home_object` 再打上 tag，并 `rememberOwnerForBulkWrite` 记下这条新边；native class 则 `rt.createRuntime(FunctionRarePayload)` 零初始化后挂到 `payload.rare`。没有 function payload 的对象返回 `error.TypeError`；返回 `&payload.async_function_rejected`。`async_generator.resolveFunction` 用 `is_reject` 参数写入，`asyncGeneratorAwait` 随即用 false / true 各造一个闭包挂上同一个 promise。
- **所有权 / 错误 / 调用**：`ensureFunctionRarePayload` 会分配：bytecode 臂首次调用铸一枚 `BytecodeFunctionAux` 的 `.payload` GC cell（由 sweep 回收，`rememberOwnerForBulkWrite` 补上新边），native 臂 `rt.createRuntime(FunctionRarePayload)` 挂进 `FunctionPayload.rare`、由 `destroyFunctionPayload` 释放；error set = 分配 OOM + 非函数对象的 `error.TypeError`，沿 `try` 上抛后在 builtin 边界由 `materializeRuntimeError` 变成 JS 异常。rare payload 建好后不再搬移，返回的槽指针在对象存活期内有效。标量槽不是 GC 边，调用方直接 `.* =` 即可，无屏障义务。树内唯一调用方 `exec/async_generator.zig:184`。

### `Object.functionAsyncContinuationRejected` (`src/core/object.zig:5691`)

- **签名**：`pub fn functionAsyncContinuationRejected(self: *const Object) bool`。
- **作用**：读出方向位，决定 await 回来后是把值送回协程还是把异常抛进协程。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.async_function_rejected`，无 payload 时 false。在 `asyncGeneratorResolveFunctionCall` 里与 action 码组合使用，例如 `.awaiting_return` 分支下它决定 `settleHead` 的最后一个参数是兑现还是拒绝。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 返回 false。树内唯一调用方 `exec/async_generator.zig:511`。

### `Object.functionAsyncGeneratorActionSlot` (`src/core/object.zig:5696`)

- **签名**：`pub fn functionAsyncGeneratorActionSlot(self: *Object, rt: *JSRuntime) !*u8`。
- **作用**：借出异步生成器续跑闭包的动作码槽，区分这次 await 是替哪一步等的。
- **实现**：`ensureFunctionRarePayload` 的两条臂：bytecode class 首次调用时 `createPayloadCell(BytecodeFunctionAux)` 建 a 类 payload cell、把原 `home_or_aux` 里的 home object 搬进 `aux.home_object` 再打上 tag，并 `rememberOwnerForBulkWrite` 记下这条新边；native class 则 `rt.createRuntime(FunctionRarePayload)` 零初始化后挂到 `payload.rare`。没有 function payload 的对象返回 `error.TypeError`；返回 `&payload.async_generator_action`，写入 `ResolveAction` 的 `@intFromEnum`。这是 zjs 对 qjs `js_async_generator_resolve_function` magic 值的改编（见字段上的 `quickjs.c:21670` 注释）：qjs 把部分 await 编进函数体字节码，zjs 用额外的 action 值承载。
- **所有权 / 错误 / 调用**：`ensureFunctionRarePayload` 会分配：bytecode 臂首次调用铸一枚 `BytecodeFunctionAux` 的 `.payload` GC cell（由 sweep 回收，`rememberOwnerForBulkWrite` 补上新边），native 臂 `rt.createRuntime(FunctionRarePayload)` 挂进 `FunctionPayload.rare`、由 `destroyFunctionPayload` 释放；error set = 分配 OOM + 非函数对象的 `error.TypeError`，沿 `try` 上抛后在 builtin 边界由 `materializeRuntimeError` 变成 JS 异常。rare payload 建好后不再搬移，返回的槽指针在对象存活期内有效。标量槽不是 GC 边，调用方直接 `.* =` 即可，无屏障义务。树内唯一调用方 `exec/async_generator.zig:185`。

### `Object.functionAsyncGeneratorAction` (`src/core/object.zig:5700`)

- **签名**：`pub fn functionAsyncGeneratorAction(self: *const Object) u8`。
- **作用**：读出动作码，决定 await 完成后走异步生成器状态机的哪一条恢复路径。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.async_generator_action`，无 payload 时 0。`@enumFromInt` 成 `ResolveAction` 后 switch：0=`none` 返回 null，1=`await_resume`（表达式 await 续跑），2=`yield_operand`（yield 操作数先被 await），4=`awaiting_return`（`return()` 请求的收尾——该分支按 qjs 的实际行为结算队首并置 `completed`，且刻意不再 resume_next）。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 返回 0。树内唯一调用方 `exec/async_generator.zig:512` 直接 `@enumFromInt` 成 `ResolveAction`，所以 0 必须是合法枚举值（`ResolveAction.none`），默认值与枚举是一条绑定的约束。

### `Object.functionAsyncFromSyncUnwrapDoneSlot` (`src/core/object.zig:5705`)

- **签名**：`pub fn functionAsyncFromSyncUnwrapDoneSlot(self: *Object, rt: *JSRuntime) !*u8`。
- **作用**：借出 async-from-sync 解包闭包的 done 位槽。
- **实现**：`ensureFunctionRarePayload` 的两条臂：bytecode class 首次调用时 `createPayloadCell(BytecodeFunctionAux)` 建 a 类 payload cell、把原 `home_or_aux` 里的 home object 搬进 `aux.home_object` 再打上 tag，并 `rememberOwnerForBulkWrite` 记下这条新边；native class 则 `rt.createRuntime(FunctionRarePayload)` 零初始化后挂到 `payload.rare`。没有 function payload 的对象返回 `error.TypeError`；返回 `&payload.async_from_sync_unwrap_done`。`promise_ops.asyncFromSyncIteratorUnwrap` 写的是 `if (done) 2 else 1`——刻意避开 0，好让读侧拿 0 当「不是这类闭包」的哨兵。
- **所有权 / 错误 / 调用**：`ensureFunctionRarePayload` 会分配：bytecode 臂首次调用铸一枚 `BytecodeFunctionAux` 的 `.payload` GC cell（由 sweep 回收，`rememberOwnerForBulkWrite` 补上新边），native 臂 `rt.createRuntime(FunctionRarePayload)` 挂进 `FunctionPayload.rare`、由 `destroyFunctionPayload` 释放；error set = 分配 OOM + 非函数对象的 `error.TypeError`，沿 `try` 上抛后在 builtin 边界由 `materializeRuntimeError` 变成 JS 异常。rare payload 建好后不再搬移，返回的槽指针在对象存活期内有效。标量槽不是 GC 边，调用方直接 `.* =` 即可，无屏障义务。树内唯一调用方 `exec/promise_ops.zig:3447`（写 1/2 编码 done 位）。

### `Object.functionAsyncFromSyncUnwrapDone` (`src/core/object.zig:5709`)

- **签名**：`pub fn functionAsyncFromSyncUnwrapDone(self: *const Object) u8`。
- **作用**：读出 done 位，决定把 await 到的值重新包成 `{ value, done: false }` 还是 `{ value, done: true }` 的迭代结果对象。
- **实现**：读路径统一是 `functionRarePayloadConst()` 的两条臂：bytecode function 走 `home_or_aux` 低位 tag 指向的 `BytecodeFunctionAux.rare`，native function 走 `FunctionPayload.rare` 指针，返回 `payload.async_from_sync_unwrap_done`，无 payload 时 0。`asyncFromSyncIteratorUnwrapCall` 见 0 返回 null，见 1/2 之外的值抛 `TypeError`，否则取首个实参（缺省 undefined）交给 `createIteratorResult`，`done` 实参就是 `mode == 2`。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 返回 0，与写入端的 1/2 编码互补（0 = 没标过）。树内唯一调用方 `exec/promise_ops.zig:3457`。

### `Object.functionCaptures` (`src/core/object.zig:5714`)

- **签名**：`pub fn functionCaptures(self: *const Object) []*var_ref_mod.VarRef`。
- **作用**：借用已填充完成的字节码函数捕获表。
- **实现**：非字节码函数返回空；否则委托 arm.captureSlice()。
- **所有权 / 错误 / 调用**：captureSlice 在 Debug/ReleaseSafe 检查长度匹配 fb 且每项非空，再按非空 VarRef 指针解释；调用方不能用它读取构造中的 nullable 表。返回可变指针项 slice，修改须维护 GC 协议。

### `Object.moduleCaptureSlots` (`src/core/object.zig:5722`)

- **签名**：`pub fn moduleCaptureSlots(self: *const Object) []const ?*var_ref_mod.VarRef`。
- **作用**：借用构造/链接阶段的 nullable capture 表。
- **实现**：非字节码函数返回空，否则返回 arm.captureSlots()。
- **所有权 / 错误 / 调用**：emptyVarRefs sentinel 或无 fb 时为空；其他情况长度由 fb.closureVarCount 决定。此接口只读项，模块修改使用 replace/clear helpers，不分配或 seal。

### `Object.allocateNullCaptureSlots` (`src/core/object.zig:5736`)

- **签名**：`pub inline fn allocateNullCaptureSlots(self: *Object, rt: *JSRuntime, count: usize) !void`。
- **作用**：为字节码函数安装一次全 null 的 capture 表。
- **实现**：class 错、无 fb、count 不等于 closureVarCount 或 var_refs 不是空 sentinel 都返回 InvalidBytecode；count 零返回，否则创建 payload slice cell、全部置 null、安装指针并 remember owner。
- **所有权 / 错误 / 调用**：分配失败前不安装；非零表不允许二次分配，零长度仍保留 sentinel，可重复通过。表本身由 GC 回收，不手动 free；填充时须维护各 VarRef 边。

### `Object.allocateNullModuleCaptureSlots` (`src/core/object.zig:5753`)

- **签名**：`pub fn allocateNullModuleCaptureSlots(self: *Object, rt: *JSRuntime, count: usize) !void`。
- **作用**：安装模块链接用的全 null capture 表。
- **实现**：直接委托 allocateNullCaptureSlots。
- **所有权 / 错误 / 调用**：共享 count/fb/sentinel 验证与 GC 存储合同；不创建独立的 module 表或 seal 状态。

### `Object.mutableCaptureSlots` (`src/core/object.zig:5758`)

- **签名**：`pub inline fn mutableCaptureSlots(self: *Object) []?*var_ref_mod.VarRef`。
- **作用**：借用字节码函数的可变 nullable capture 表。
- **实现**：断言字节码函数 class，返回 arm.captureSlots()。
- **所有权 / 错误 / 调用**：不分配、不验证全部已填充；写槽不会自动执行屏障，调用方负责构造窗口和发布协议。

### `Object.replaceModuleCaptureSlotOwned` (`src/core/object.zig:5765`)

- **签名**：`pub fn replaceModuleCaptureSlotOwned( self: *Object, index: usize, cell: *var_ref_mod.VarRef, ) !void`。
- **作用**：替换模块 capture 表的一个 VarRef 指针。
- **实现**：非字节码函数或 index>=captureSlots.len 返回 InvalidBytecode；否则 slots[index]=cell。
- **所有权 / 错误 / 调用**：错误时不改槽；当前实现不 retain/release、不执行 owner 屏障，也不验证该位置属于 import。Owned 是调用协议名称，不代表本函数做 RC。

### `Object.clearModuleImportCaptureSlot` (`src/core/object.zig:5780`)

- **签名**：`pub fn clearModuleImportCaptureSlot(self: *Object, index: usize) !void`。
- **作用**：把指定模块 capture 槽恢复为 null。
- **实现**：验证字节码函数 class 和索引范围，失败 InvalidBytecode，否则置 null。
- **所有权 / 错误 / 调用**：不校验它是否真是 import 槽，也不执行 RC release；可供链接回滚使用。

### `Object.sealModuleCaptures` (`src/core/object.zig:5791`)

- **签名**：`pub fn sealModuleCaptures(self: *const Object) !void`。
- **作用**：验证模块 capture 表已完整填充。
- **实现**：要求字节码函数 class、fb 存在、slot 数等于 closureVarCount 且每项非 null，否则 InvalidBytecode。
- **所有权 / 错误 / 调用**：不分配、不设置 sealed 标志、不检查每个 VarRef 的语义；回滚后可以重新验证同一表。

### `Object.functionHomeObject` (`src/core/object.zig:5801`)

- **签名**：`pub fn functionHomeObject(self: *const Object) ?*Object`。
- **作用**：查询字节码函数的 HomeObject。
- **实现**：非字节码函数返回 null；有带 tag 的 aux 则返回 aux.home_object；否则 home_or_aux 为空返回 null，非空断言 tag 位为零后转换为 Object 指针。
- **所有权 / 错误 / 调用**：只借用指针，不沿 prototype 查找或分配 aux。

### `Object.setFunctionHomeObject` (`src/core/object.zig:5810`)

- **签名**：`pub fn setFunctionHomeObject(self: *Object, _: *JSRuntime, home_object: ?*Object) !void`。
- **作用**：替换字节码函数的 HomeObject 强边。
- **实现**：断言字节码函数 class，相同指针直接返回；已有 aux 写 aux.home_object，否则把 direct Object 指针或 null 写 home_or_aux。
- **所有权 / 错误 / 调用**：当前 rt 未使用，无分配、RC 操作、GC 屏障或实际 error 分支；调用方负责写入时点的 GC 协议，不能据强边语义推断此 helper 自带屏障。

### `Object.setCallSiteMetadata` (`src/core/object.zig:5821`)

- **签名**：`pub fn setCallSiteMetadata( self: *Object, rt: *JSRuntime, file: JSValue, function_name: JSValue, line: i32, column: i32, is_native: bool, ) !void`。
- **作用**：安装 call-site 元数据并屏障两个 JSValue 字段。
- **实现**：先 ensureOrdinaryPayload，写 file、function_name、line、column，置 is_callsite=true 和 callsite_is_native，再分别屏障 function/file。
- **所有权 / 错误 / 调用**：ensure 可失败，调用方在分配窗口保护输入；function_name 可以是函数 Object，不保证是名字字符串。这里不校验行列范围或捕获调用栈。

### `Object.isCallSite` (`src/core/object.zig:5852`)

- **签名**：`pub fn isCallSite(self: *const Object) bool`。
- **作用**：查询 ordinary payload 的 is_callsite。
- **实现**：有 ordinaryPayloadConst 返回字段，否则 false。
- **所有权 / 错误 / 调用**：无分配、无 error set；ordinary payload 缺失即 false，所以「不是 call site」与「还没建 payload」同形。调用方 `exec/exception_ops.zig:434`（CallSite 方法的 receiver 校验）、`exec/string_ops.zig:709`（格式化时跳过非 site 元素）；写入端 `setCallSiteMetadata` 负责 ensure payload 并补两条分代屏障。

### `Object.callSiteFile` (`src/core/object.zig:5857`)

- **签名**：`pub fn callSiteFile(self: *const Object) ?JSValue`。
- **作用**：查询 ordinary payload 的 callsite_file。
- **实现**：有 ordinaryPayloadConst 返回字段，否则 null。
- **所有权 / 错误 / 调用**：无分配、无 error set；返回 OrdinaryPayload 借用的 `?JSValue`，存活靠 `callsite_file` 这条 trace 边，调用方不释放。调用方 `exec/exception_ops.zig:444`（null → JS `null`）、`exec/error_stack_ops.zig:229`。

### `Object.callSiteFunctionName` (`src/core/object.zig:5862`)

- **签名**：`pub fn callSiteFunctionName(self: *const Object) ?JSValue`。
- **作用**：查询 ordinary payload 的 callsite_function。
- **实现**：有 ordinaryPayloadConst 返回字段，否则 null。
- **所有权 / 错误 / 调用**：无分配、无 error set；返回借用 `?JSValue`，且按 `setCallSiteMetadata` 的注释它可能是被调函数对象而不是名字字符串，调用方要自己兜底。调用方 `exec/exception_ops.zig:443`、`exec/error_stack_ops.zig:217`。

### `Object.callSiteLine` (`src/core/object.zig:5867`)

- **签名**：`pub fn callSiteLine(self: *const Object) i32`。
- **作用**：查询 ordinary payload 的 callsite_line。
- **实现**：有 ordinaryPayloadConst 返回字段，否则 1。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 的默认值是 1 而不是 0。调用方 `exec/exception_ops.zig:445`（native 帧改报 `null`）、`exec/string_ops.zig:725`。

### `Object.callSiteColumn` (`src/core/object.zig:5872`)

- **签名**：`pub fn callSiteColumn(self: *const Object) i32`。
- **作用**：查询 ordinary payload 的 callsite_column。
- **实现**：有 ordinaryPayloadConst 返回字段，否则 1。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 的默认值同样是 1。调用方 `exec/exception_ops.zig:446`（native 帧改报 `null`）、`exec/string_ops.zig:725`。

### `Object.callSiteIsNative` (`src/core/object.zig:5877`)

- **签名**：`pub fn callSiteIsNative(self: *const Object) bool`。
- **作用**：查询已标记为 call-site 的 native 标志。
- **实现**：有 ordinary payload 时返回 is_callsite && callsite_is_native，否则 false。
- **所有权 / 错误 / 调用**：不会从保存的函数或代码位置重新推导 native 属性。

### `Object.setErrorStack` (`src/core/object.zig:5882`)

- **签名**：`pub fn setErrorStack(self: *Object, rt: *JSRuntime, stack_value: JSValue) !void`。
- **作用**：保存已生成的 stack 值并清除 sites 表示。
- **实现**：确保 ordinary payload 后写 error_stack，清 error_stack_sites 和 site_count，随后对 stack 值屏障。
- **所有权 / 错误 / 调用**：不要求值为字符串、不生成栈文本；ensure 可能分配失败。只是断开旧字段边，无 RC release。

### `Object.errorStack` (`src/core/object.zig:5898`)

- **签名**：`pub fn errorStack(self: *const Object) ?JSValue`。
- **作用**：查询 ordinary payload 的 error_stack。
- **实现**：有 ordinaryPayloadConst 返回字段，否则 null。
- **所有权 / 错误 / 调用**：无分配、无 error set；返回借用 `?JSValue`（trace 边 `error_stack` 维持存活）。唯一生产调用方 `exec/error_stack_ops.zig:248`：取到就当 `stack` 字符串直接返回，取不到才改读 `errorStackSites`；写入端 `setErrorStack` 会把 sites 清零，两种表示互斥。

### `Object.setErrorStackSites` (`src/core/object.zig:5903`)

- **签名**：`pub fn setErrorStackSites(self: *Object, rt: *JSRuntime, sites_value: JSValue) !void`。
- **作用**：保存 captured sites 表示并清除已生成 stack 值。
- **实现**：确保 ordinary payload，清 error_stack，写 sites_value，按 capturedStackSiteCount 保存计数，再屏障该值。
- **所有权 / 错误 / 调用**：不遍历或验证每个 site；计数为安装时快照，sites 后续变动不会自动同步。分配期间的输入保护由调用方负责。

### `Object.errorStackSites` (`src/core/object.zig:5915`)

- **签名**：`pub fn errorStackSites(self: *const Object) ?JSValue`。
- **作用**：查询 ordinary payload 的 error_stack_sites。
- **实现**：有 ordinaryPayloadConst 返回字段，否则 null。
- **所有权 / 错误 / 调用**：无分配、无 error set；返回借用 `?JSValue`（trace 边 `error_stack_sites`）。唯一调用方 `exec/error_stack_ops.zig:249`，拿到后连同 `errorStackSiteCount()` 交给 `formatCapturedErrorStackValue` 现场格式化。

### `Object.errorStackSiteCount` (`src/core/object.zig:5920`)

- **签名**：`pub fn errorStackSiteCount(self: *const Object) usize`。
- **作用**：查询 ordinary payload 的 error_stack_site_count。
- **实现**：有 ordinaryPayloadConst 返回字段，否则 0。
- **所有权 / 错误 / 调用**：无分配、无 error set；缺 payload 返回 0。计数由 `setErrorStackSites` 调 `capturedStackSiteCount` 一次算好（非数组即 0），读取端不重算、也不校验与 sites 数组是否仍一致。唯一调用方 `exec/error_stack_ops.zig:250`。

### `Object.capturedStackSiteCount` (`src/core/object.zig:5925`)

- **签名**：`fn capturedStackSiteCount(sites_value: JSValue) usize`。
- **作用**：从普通 Array 值读取可记录的 site 数。
- **实现**：objectFromValue 失败返回 0；Object 是 Array 则返回 arrayLength，否则 0。
- **所有权 / 错误 / 调用**：不执行 ToLength、Proxy trap 或普通 length getter，不数有效元素，也不验证内容是 call-site。

### `Object.promiseReactionOnFulfilledSlot` (`src/core/object.zig:5930`)

- **签名**：`pub fn promiseReactionOnFulfilledSlot(self: *Object, rt: *JSRuntime) !*?JSValue`。
- **作用**：借用 reaction 的 on_fulfilled 槽。
- **实现**：有 private reaction payload 则返回其字段；否则 ensureOrdinaryPayload 后返回 promise_reaction_on_fulfilled。
- **所有权 / 错误 / 调用**：fallback 可能分配并失败；不验证 callback 可调用性，裸写不自动执行屏障。

### `Object.promiseReactionOnFulfilled` (`src/core/object.zig:5936`)

- **签名**：`pub fn promiseReactionOnFulfilled(self: *const Object) ?JSValue`。
- **作用**：查询 reaction 的 on_fulfilled 值。
- **实现**：优先 private reaction payload，其次 ordinary payload 的对应字段，均无则 null。
- **所有权 / 错误 / 调用**：不创建 payload、调用回调或排 job。

### `Object.setPromiseReactionOnFulfilled` (`src/core/object.zig:5942`)

- **签名**：`pub fn setPromiseReactionOnFulfilled(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void`。
- **作用**：设置 reaction 的 OnFulfilled optional 值。
- **实现**：先 try 对应 promiseReactionOnFulfilledSlot(rt)，再委托 setOptionalValueSlot 写值和非空值屏障。
- **所有权 / 错误 / 调用**：取槽可能创建 ordinary payload 并失败；resolve/reject 还要求 external tag。不调用存入的函数或排 job。

### `Object.promiseReactionOnRejectedSlot` (`src/core/object.zig:5946`)

- **签名**：`pub fn promiseReactionOnRejectedSlot(self: *Object, rt: *JSRuntime) !*?JSValue`。
- **作用**：借用 reaction 的 on_rejected 槽。
- **实现**：有 private reaction payload 则返回其字段；否则 ensureOrdinaryPayload 后返回 promise_reaction_on_rejected。
- **所有权 / 错误 / 调用**：fallback 可能分配并失败；不验证 callback 可调用性，裸写不自动执行屏障。

### `Object.promiseReactionOnRejected` (`src/core/object.zig:5952`)

- **签名**：`pub fn promiseReactionOnRejected(self: *const Object) ?JSValue`。
- **作用**：查询 reaction 的 on_rejected 值。
- **实现**：优先 private reaction payload，其次 ordinary payload 的对应字段，均无则 null。
- **所有权 / 错误 / 调用**：不创建 payload、调用回调或排 job。

### `Object.setPromiseReactionOnRejected` (`src/core/object.zig:5958`)

- **签名**：`pub fn setPromiseReactionOnRejected(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void`。
- **作用**：设置 reaction 的 OnRejected optional 值。
- **实现**：先 try 对应 promiseReactionOnRejectedSlot(rt)，再委托 setOptionalValueSlot 写值和非空值屏障。
- **所有权 / 错误 / 调用**：取槽可能创建 ordinary payload 并失败；resolve/reject 还要求 external tag。不调用存入的函数或排 job。

### `Object.promiseReactionResolveSlot` (`src/core/object.zig:5962`)

- **签名**：`pub fn promiseReactionResolveSlot(self: *Object, rt: *JSRuntime) !*?JSValue`。
- **作用**：借用 external reaction capability 的 resolve 槽。
- **实现**：有 private reaction payload 则断言 capability.external 并返回字段；否则 ensure ordinary payload，断言其 capability.external 后返回字段。
- **所有权 / 错误 / 调用**：不会把 intrinsic capability 转成 external；fallback 可分配失败，调用方保证 tag，并为裸写维护屏障。

### `Object.promiseReactionResolve` (`src/core/object.zig:5972`)

- **签名**：`pub fn promiseReactionResolve(self: *const Object) ?JSValue`。
- **作用**：查询 reaction external capability 的 resolve。
- **实现**：优先 private reaction payload，其次 ordinary payload；对应 union 为 external 则返回字段，intrinsic 或无 payload 则 null。
- **所有权 / 错误 / 调用**：返回 null 不代表 reaction 没有 intrinsic 目标；不执行 Promise 结算。

### `Object.setPromiseReactionResolve` (`src/core/object.zig:5984`)

- **签名**：`pub fn setPromiseReactionResolve(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void`。
- **作用**：设置 reaction 的 Resolve optional 值。
- **实现**：先 try 对应 promiseReactionResolveSlot(rt)，再委托 setOptionalValueSlot 写值和非空值屏障。
- **所有权 / 错误 / 调用**：取槽可能创建 ordinary payload 并失败；resolve/reject 还要求 external tag。不调用存入的函数或排 job。

### `Object.promiseReactionRejectSlot` (`src/core/object.zig:5988`)

- **签名**：`pub fn promiseReactionRejectSlot(self: *Object, rt: *JSRuntime) !*?JSValue`。
- **作用**：借用 external reaction capability 的 reject 槽。
- **实现**：有 private reaction payload 则断言 capability.external 并返回字段；否则 ensure ordinary payload，断言其 capability.external 后返回字段。
- **所有权 / 错误 / 调用**：不会把 intrinsic capability 转成 external；fallback 可分配失败，调用方保证 tag，并为裸写维护屏障。

### `Object.promiseReactionReject` (`src/core/object.zig:5998`)

- **签名**：`pub fn promiseReactionReject(self: *const Object) ?JSValue`。
- **作用**：查询 reaction external capability 的 reject。
- **实现**：优先 private reaction payload，其次 ordinary payload；对应 union 为 external 则返回字段，intrinsic 或无 payload 则 null。
- **所有权 / 错误 / 调用**：返回 null 不代表 reaction 没有 intrinsic 目标；不执行 Promise 结算。

### `Object.setPromiseReactionReject` (`src/core/object.zig:6010`)

- **签名**：`pub fn setPromiseReactionReject(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void`。
- **作用**：设置 reaction 的 Reject optional 值。
- **实现**：先 try 对应 promiseReactionRejectSlot(rt)，再委托 setOptionalValueSlot 写值和非空值屏障。
- **所有权 / 错误 / 调用**：取槽可能创建 ordinary payload 并失败；resolve/reject 还要求 external tag。不调用存入的函数或排 job。

### `Object.promiseReactionIntrinsicCapability` (`src/core/object.zig:6014`)

- **签名**：`pub fn promiseReactionIntrinsicCapability(self: *const Object) ?IntrinsicPromiseReaction`。
- **作用**：查询 reaction capability 的 intrinsic 分支。
- **实现**：优先 private reaction payload，否则 ordinary payload，无两者返回 null；capability 为 intrinsic 返回记录，为 external 返回 null。
- **所有权 / 错误 / 调用**：按值返回 target/self_error_global 记录，不转移所有权、不 settle Promise 或建立根。

### `Object.setPromiseReactionIntrinsicCapability` (`src/core/object.zig:6029`)

- **签名**：`pub fn setPromiseReactionIntrinsicCapability(self: *Object, rt: *JSRuntime, target: JSValue, self_error_global: JSValue) void`。
- **作用**：安装 intrinsic capability 并屏障其两条值边。
- **实现**：取得现有 capability 地址，覆盖成 intrinsic{target,self_error_global}，分别执行 owner 到两个值的屏障。
- **所有权 / 错误 / 调用**：不分配，必须已有 reaction/ordinary payload；可覆盖原 external 分支，但不调用原 resolve/reject，也不验证 target 类型。

### `Object.clearPromiseReactionIntrinsicCapability` (`src/core/object.zig:6038`)

- **签名**：`pub fn clearPromiseReactionIntrinsicCapability(self: *Object) void`。
- **作用**：清除已消费的 intrinsic capability。
- **实现**：取得现有 capability 槽，断言当前为 intrinsic，再改成默认空 external 分支。
- **所有权 / 错误 / 调用**：不 settle 或转移 target 到队列；调用方须先完成结算/转交。本函数只是断开该记录的边。

### `Object.promiseReactionCapabilityPtr` (`src/core/object.zig:6044`)

- **签名**：`fn promiseReactionCapabilityPtr(self: *Object) *object_payloads.PromiseReactionCapability`。
- **作用**：借用现有 reaction capability union。
- **实现**：优先 private reaction payload 的 capability，其次 ordinary payload 的 promise_reaction_capability，均无则 unreachable。
- **所有权 / 错误 / 调用**：不创建或转换 payload，不校验当前 union tag。

### `Object.promiseAlreadyResolvedSlot` (`src/core/object.zig:6050`)

- **签名**：`pub fn promiseAlreadyResolvedSlot(self: *Object, rt: *JSRuntime) !*bool`。
- **作用**：确保 ordinary payload 后借用 promise_already_resolved 槽。
- **实现**：try ensureOrdinaryPayload，返回字段地址。
- **所有权 / 错误 / 调用**：可能分配并失败；裸写不自动屏障、验证函数或推进 Promise 算法。

### `Object.promiseAlreadyResolved` (`src/core/object.zig:6055`)

- **签名**：`pub fn promiseAlreadyResolved(self: *const Object) bool`。
- **作用**：查询 ordinary payload 的 promise_already_resolved。
- **实现**：有 ordinary payload 返回字段，否则 false。
- **所有权 / 错误 / 调用**：不分配或执行结算，只读存储字段。

### `Object.promiseCapabilityResolveSlot` (`src/core/object.zig:6060`)

- **签名**：`pub fn promiseCapabilityResolveSlot(self: *Object, rt: *JSRuntime) !*?JSValue`。
- **作用**：确保 ordinary payload 后借用 promise_capability_resolve 槽。
- **实现**：try ensureOrdinaryPayload，返回字段地址。
- **所有权 / 错误 / 调用**：可能分配并失败；裸写不自动屏障、验证函数或推进 Promise 算法。

### `Object.promiseCapabilityResolve` (`src/core/object.zig:6065`)

- **签名**：`pub fn promiseCapabilityResolve(self: *const Object) ?JSValue`。
- **作用**：查询 ordinary payload 的 promise_capability_resolve。
- **实现**：有 ordinary payload 返回字段，否则 null。
- **所有权 / 错误 / 调用**：不分配或执行结算，只读存储字段。

### `Object.promiseCapabilityRejectSlot` (`src/core/object.zig:6070`)

- **签名**：`pub fn promiseCapabilityRejectSlot(self: *Object, rt: *JSRuntime) !*?JSValue`。
- **作用**：确保 ordinary payload 后借用 promise_capability_reject 槽。
- **实现**：try ensureOrdinaryPayload，返回字段地址。
- **所有权 / 错误 / 调用**：可能分配并失败；裸写不自动屏障、验证函数或推进 Promise 算法。

### `Object.promiseCapabilityReject` (`src/core/object.zig:6075`)

- **签名**：`pub fn promiseCapabilityReject(self: *const Object) ?JSValue`。
- **作用**：查询 ordinary payload 的 promise_capability_reject。
- **实现**：有 ordinary payload 返回字段，否则 null。
- **所有权 / 错误 / 调用**：不分配或执行结算，只读存储字段。

### `Object.setPromiseCapability` (`src/core/object.zig:6080`)

- **签名**：`pub fn setPromiseCapability(self: *Object, rt: *JSRuntime, next_resolve: ?JSValue, next_reject: ?JSValue) !void`。
- **作用**：同时设置普通 capability record 的 resolve/reject 字段。
- **实现**：依次取得两个可能 ensure ordinary payload 的槽，之后写两个 optional 值，并分别对非空值执行 self owner 屏障。
- **所有权 / 错误 / 调用**：不验证函数可调用性或执行结算；取槽失败前不写新值，但 ensure 自身可能留下 payload/存储变化。输入存活保护由调用方负责。

### `Object.promiseCombinatorResolveSlot` (`src/core/object.zig:6094`)

- **签名**：`pub fn promiseCombinatorResolveSlot(self: *Object, rt: *JSRuntime) !*?JSValue`。
- **作用**：确保 ordinary payload 后借用 promise_combinator_resolve 槽。
- **实现**：try ensureOrdinaryPayload，返回字段地址。
- **所有权 / 错误 / 调用**：可能分配并失败；裸写不自动屏障、验证函数或推进 Promise 算法。

### `Object.promiseCombinatorResolve` (`src/core/object.zig:6099`)

- **签名**：`pub fn promiseCombinatorResolve(self: *const Object) ?JSValue`。
- **作用**：查询 ordinary payload 的 promise_combinator_resolve。
- **实现**：有 ordinary payload 返回字段，否则 null。
- **所有权 / 错误 / 调用**：不分配或执行结算，只读存储字段。

### `Object.setPromiseCombinatorResolve` (`src/core/object.zig:6104`)

- **签名**：`pub fn setPromiseCombinatorResolve(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void`。
- **作用**：设置 combinator 的 Resolve optional 值。
- **实现**：try 取得对应 Slot(rt)，再 setOptionalValueSlot 写入并对非空值执行 owner 屏障。
- **所有权 / 错误 / 调用**：取槽可能分配失败；不验证 callable/array 类型或推进 combinator 状态。

### `Object.promiseCombinatorRejectSlot` (`src/core/object.zig:6108`)

- **签名**：`pub fn promiseCombinatorRejectSlot(self: *Object, rt: *JSRuntime) !*?JSValue`。
- **作用**：确保 ordinary payload 后借用 promise_combinator_reject 槽。
- **实现**：try ensureOrdinaryPayload 后返回字段地址。
- **所有权 / 错误 / 调用**：可能分配并失败；直接写槽不维护屏障、计数约束或执行 Promise 算法。

### `Object.promiseCombinatorReject` (`src/core/object.zig:6113`)

- **签名**：`pub fn promiseCombinatorReject(self: *const Object) ?JSValue`。
- **作用**：查询 ordinary payload 的 promise_combinator_reject。
- **实现**：有 ordinaryPayloadConst 返回字段，否则 null。
- **所有权 / 错误 / 调用**：不创建 payload 或从队列计算状态，只读取字段。

### `Object.setPromiseCombinatorReject` (`src/core/object.zig:6118`)

- **签名**：`pub fn setPromiseCombinatorReject(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void`。
- **作用**：设置 combinator 的 Reject optional 值。
- **实现**：try 取得对应 Slot(rt)，再 setOptionalValueSlot 写入并对非空值执行 owner 屏障。
- **所有权 / 错误 / 调用**：取槽可能分配失败；不验证 callable/array 类型或推进 combinator 状态。

### `Object.promiseCombinatorValuesSlot` (`src/core/object.zig:6122`)

- **签名**：`pub fn promiseCombinatorValuesSlot(self: *Object, rt: *JSRuntime) !*?JSValue`。
- **作用**：确保 ordinary payload 后借用 promise_combinator_values 槽。
- **实现**：try ensureOrdinaryPayload 后返回字段地址。
- **所有权 / 错误 / 调用**：可能分配并失败；直接写槽不维护屏障、计数约束或执行 Promise 算法。

### `Object.promiseCombinatorValues` (`src/core/object.zig:6127`)

- **签名**：`pub fn promiseCombinatorValues(self: *const Object) ?JSValue`。
- **作用**：查询 ordinary payload 的 promise_combinator_values。
- **实现**：有 ordinaryPayloadConst 返回字段，否则 null。
- **所有权 / 错误 / 调用**：不创建 payload 或从队列计算状态，只读取字段。

### `Object.setPromiseCombinatorValues` (`src/core/object.zig:6132`)

- **签名**：`pub fn setPromiseCombinatorValues(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void`。
- **作用**：设置 combinator 的 Values optional 值。
- **实现**：try 取得对应 Slot(rt)，再 setOptionalValueSlot 写入并对非空值执行 owner 屏障。
- **所有权 / 错误 / 调用**：取槽可能分配失败；不验证 callable/array 类型或推进 combinator 状态。

### `Object.promiseCombinatorKeysSlot` (`src/core/object.zig:6136`)

- **签名**：`pub fn promiseCombinatorKeysSlot(self: *Object, rt: *JSRuntime) !*?JSValue`。
- **作用**：确保 ordinary payload 后借用 promise_combinator_keys 槽。
- **实现**：try ensureOrdinaryPayload 后返回字段地址。
- **所有权 / 错误 / 调用**：可能分配并失败；直接写槽不维护屏障、计数约束或执行 Promise 算法。

### `Object.promiseCombinatorKeys` (`src/core/object.zig:6141`)

- **签名**：`pub fn promiseCombinatorKeys(self: *const Object) ?JSValue`。
- **作用**：查询 ordinary payload 的 promise_combinator_keys。
- **实现**：有 ordinaryPayloadConst 返回字段，否则 null。
- **所有权 / 错误 / 调用**：不创建 payload 或从队列计算状态，只读取字段。

### `Object.setPromiseCombinatorKeys` (`src/core/object.zig:6146`)

- **签名**：`pub fn setPromiseCombinatorKeys(self: *Object, rt: *JSRuntime, next_value: ?JSValue) !void`。
- **作用**：设置 combinator 的 Keys optional 值。
- **实现**：try 取得对应 Slot(rt)，再 setOptionalValueSlot 写入并对非空值执行 owner 屏障。
- **所有权 / 错误 / 调用**：取槽可能分配失败；不验证 callable/array 类型或推进 combinator 状态。

### `Object.promiseCombinatorRemainingSlot` (`src/core/object.zig:6150`)

- **签名**：`pub fn promiseCombinatorRemainingSlot(self: *Object, rt: *JSRuntime) !*i32`。
- **作用**：确保 ordinary payload 后借用 promise_combinator_remaining 槽。
- **实现**：try ensureOrdinaryPayload 后返回字段地址。
- **所有权 / 错误 / 调用**：可能分配并失败；直接写槽不维护屏障、计数约束或执行 Promise 算法。

### `Object.promiseCombinatorRemaining` (`src/core/object.zig:6155`)

- **签名**：`pub fn promiseCombinatorRemaining(self: *const Object) i32`。
- **作用**：查询 ordinary payload 的 promise_combinator_remaining。
- **实现**：有 ordinaryPayloadConst 返回字段，否则 0。
- **所有权 / 错误 / 调用**：不创建 payload 或从队列计算状态，只读取字段。

### `Object.functionRealmGlobalSlot` (`src/core/object.zig:6160`)

- **签名**：`pub fn functionRealmGlobalSlot(self: *Object, rt: *JSRuntime) !*?JSValue`。
- **作用**：确保 function rare payload 后借用 legacy realm_global 字段槽。
- **实现**：断言 function kind，再 ensureFunctionRarePayload 并返回 realm_global 地址。
- **所有权 / 错误 / 调用**：可能分配失败；该字段与 FunctionBytecode/native RealmRef 的实际 realm 来源不同，裸写不会同步二者或执行屏障。

### `Object.functionRealmGlobal` (`src/core/object.zig:6165`)

- **签名**：`pub fn functionRealmGlobal(self: *const Object) ?JSValue`。
- **作用**：查询 rare payload 中保存的 realm_global 值。
- **实现**：有 rare payload 返回字段，否则 null。
- **所有权 / 错误 / 调用**：不等同于 functionRealmGlobalPtr 的实际 class 分派；不会从 fb/native realm 派生值。

### `Object.setFunctionRealmGlobalPtr` (`src/core/object.zig:6170`)

- **签名**：`pub fn setFunctionRealmGlobalPtr(self: *Object, rt: *JSRuntime, realm_global: ?*Object) !void`。
- **作用**：校验字节码 realm 或为真正 C-function 安装 realm。
- **实现**：字节码函数先取已有 bytecode realm global，缺失 InvalidBuiltinRegistry，与输入不同 InvalidBytecode，相同仅返回；c_function 要求非空 global 且 runtime 能找到包含构造中 context，再 setNativeFunctionRealm。其他 class 无操作。
- **所有权 / 错误 / 调用**：不写 rare.realm_global。c_function_data 等 caller-semantics 对象不会从此获得 realm；不创建 RealmContext。

### `Object.setFunctionRealmGlobalPtrIfNull` (`src/core/object.zig:6186`)

- **签名**：`pub fn setFunctionRealmGlobalPtrIfNull(self: *Object, rt: *JSRuntime, realm_global: ?*Object) !void`。
- **作用**：仅在 native realm 缺失时安装，字节码函数始终校验。
- **实现**：字节码 class 直接委托 setFunctionRealmGlobalPtr；c_function 只有 nativeFunctionRealm()==null 才委托，其他情况返回。
- **所有权 / 错误 / 调用**：已有 native realm 时忽略不同或 null 输入；名字中的 IfNull 不豁免字节码函数的 realm 一致性校验。

### `Object.borrowedReferenceHolderIndex` (`src/core/object.zig:6196`)

- **签名**：`pub fn borrowedReferenceHolderIndex(self: *const Object) ?usize`。
- **作用**：解码 borrowed-holder 缓存索引。
- **实现**：有 function payload 则将 lo/mid/hi 拼成 24 位整数，非零返回减一；否则或编码零时尝试 weak holder link 的 u32 index，同样零为空、非零减一。
- **所有权 / 错误 / 调用**：只读缓存，不验证 runtime 侧表实际位置或 registered 标志；大索引可能因编码限制没有缓存。

### `Object.setBorrowedReferenceHolderIndex` (`src/core/object.zig:6208`)

- **签名**：`pub fn setBorrowedReferenceHolderIndex(self: *Object, index: ?usize) void`。
- **作用**：写入 borrowed-holder 的可选缓存索引。
- **实现**：function payload 使用 index+1 的三字节编码，要求 index<maxInt(u24)，超限或 null 编为零并返回；否则尝试 weak link，以 u32 编码，要求 index<maxInt(u32)，无 link 无操作。
- **所有权 / 错误 / 调用**：不注册/移除 holder、不改侧表；超出可编码范围不报错，而是放弃缓存以供查找路径回退。

### `Object.bytecodeFunctionRealmGlobalPtr` (`src/core/object.zig:6229`)

- **签名**：`pub fn bytecodeFunctionRealmGlobalPtr(self: *const Object) ?*Object`。
- **作用**：从字节码函数的 realm 取得 global。
- **实现**：bytecodeFunctionRealmContext 为空返回 null，否则 realm.global。
- **所有权 / 错误 / 调用**：只借用指针，不读取 rare.realm_global，也不创建 realm。

### `Object.bytecodeFunctionRealmContext` (`src/core/object.zig:6234`)

- **签名**：`pub fn bytecodeFunctionRealmContext(self: *const Object) ?*context_mod.RealmContext`。
- **作用**：借用附着 FunctionBytecode 的 realm context。
- **实现**：非字节码 class 或 arm.fb 为空返回 null，否则 fb.realmContext()。
- **所有权 / 错误 / 调用**：共享字节码记录决定 realm，closure 不单独解析 caller context。

### `Object.setNativeFunctionRealm` (`src/core/object.zig:6244`)

- **签名**：`pub fn setNativeFunctionRealm(self: *Object, realm: *context_mod.RealmContext) void`。
- **作用**：为真正 C-function 保存 RealmRef 边。
- **实现**：断言 c_function，要求 function payload；相同 realm 返回，否则构造 RealmRef.retain(realm)，deinit 旧字段，再写新值。
- **所有权 / 错误 / 调用**：当前 RealmRef.retain 只封装指针、deinit 只置 null，不计 RC 或同步销毁旧 realm；本函数没有显式 GC 屏障。realm 的追踪可达性由拥有者/调用协议保证。

### `Object.forgetNativeFunctionRealmForTest` (`src/core/object.zig:6255`)

- **签名**：`pub fn forgetNativeFunctionRealmForTest(self: *Object) void`。
- **作用**：测试专用接口，抹掉真正 C-function 的 native realm 边，用于构造 teardown 最终臂的不变量场景。
- **实现**：非 test 构建触发 `@compileError("test-only")`；断言 class_id==c_function，取 function payload（缺失 unreachable），调用 payload.native.realm.deinit()。
- **所有权 / 错误 / 调用**：RealmRef 是普通 traced 指针，deinit 只把指针置 null，不销毁 RealmContext；无 error 返回。唯一调用方是 src/tests/exec.zig 的单测。


### `Object.nativeFunctionRealm` (`src/core/object.zig:6265`)

- **签名**：`pub fn nativeFunctionRealm(self: *const Object) ?*context_mod.RealmContext`。
- **作用**：查询真正 C-function 的 realm。
- **实现**：非 c_function 返回 null，否则委托 nativeFunctionRealmAssumeCFunction。
- **所有权 / 错误 / 调用**：c_function_data 不在这里拥有 construction realm；不使用 rare.realm_global。

### `Object.nativeFunctionRealmAssumeCFunction` (`src/core/object.zig:6271`)

- **签名**：`pub fn nativeFunctionRealmAssumeCFunction(self: *const Object) ?*context_mod.RealmContext`。
- **作用**：借用已证明 C-function 的 native realm。
- **实现**：缺 function payload 返回 null，否则 native.realm.borrow()。
- **所有权 / 错误 / 调用**：不再次检查 class，不 retain 或分配；调用方保证 C-function 前提。

### `Object.nativeFunctionRealmGlobalPtr` (`src/core/object.zig:6276`)

- **签名**：`pub fn nativeFunctionRealmGlobalPtr(self: *const Object) ?*Object`。
- **作用**：借用 C-function realm 的 global。
- **实现**：nativeFunctionRealm 缺失返回 null，否则 realm.global。
- **所有权 / 错误 / 调用**：不推导调用方 global，也不设置 realm。

### `Object.functionRealmGlobalPtr` (`src/core/object.zig:6281`)

- **签名**：`pub fn functionRealmGlobalPtr(self: *const Object) ?*Object`。
- **作用**：按 callable class 查询实际 realm global。
- **实现**：字节码函数走 bytecodeFunctionRealmGlobalPtr，c_function 走 nativeFunctionRealmGlobalPtr，其余 null。
- **所有权 / 错误 / 调用**：不递归解包 bound/proxy，不读取 rare.realm_global；其他 callable 的 realm 由相应调用语义处理。

## 覆盖核对

- 清单函数数（本文件分到）: 166（`src/core/object.zig` 全文件 873）
- 本文标题覆盖: 166
- 未覆盖: 无
